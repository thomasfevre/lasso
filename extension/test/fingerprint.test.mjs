import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildFingerprint,
  buildSelector,
  roleOf,
  reactComponentName,
} from "../fingerprint.mjs";

function textNode(text, rect) {
  return {
    nodeType: 3,
    nodeValue: text,
    textContent: text,
    parentElement: null,
    ownerDocument: fixtureDocument,
    getClientRects: () => (rect ? [rect] : []),
  };
}

const fixtureDocument = {
  defaultView: {
    innerWidth: 1000,
    innerHeight: 800,
    getComputedStyle: (node) => node.style || {},
  },
};

// Minimal DOM fixture: plain objects duck-typed to what fingerprint.mjs reads.
function el({ tag, id, attrs = {}, text = "", children = [], rect, react, style = {} }) {
  const ownText = text ? [textNode(text, rect)] : [];
  const node = {
    tagName: tag.toUpperCase(),
    id: id || "",
    textContent: text,
    children,
    childNodes: [...ownText, ...children],
    parentElement: null,
    ownerDocument: fixtureDocument,
    style,
    getAttribute: (name) => (name in attrs ? attrs[name] : null),
    getBoundingClientRect: rect ? () => rect : undefined,
  };
  for (const child of node.childNodes) child.parentElement = node;
  if (react) node[`__reactFiber$abc`] = react;
  return node;
}

test("selector shortcuts to #id", () => {
  assert.equal(buildSelector(el({ tag: "button", id: "save" })), "#save");
});

test("selector builds an nth-of-type path anchored at an ancestor id", () => {
  const b1 = el({ tag: "button", text: "a" });
  const b2 = el({ tag: "button", text: "b" });
  const div = el({ tag: "div", id: "toolbar", children: [b1, b2] });
  // (parentElement wired by el())
  assert.equal(buildSelector(b2), "#toolbar > button:nth-of-type(2)");
});

test("single child of its type gets no nth-of-type suffix", () => {
  const only = el({ tag: "span", text: "x" });
  el({ tag: "div", id: "wrap", children: [only] });
  assert.equal(buildSelector(only), "#wrap > span");
});

test("role prefers explicit ARIA, falls back to implicit", () => {
  assert.equal(roleOf(el({ tag: "div", attrs: { role: "switch" } })), "switch");
  assert.equal(roleOf(el({ tag: "a" })), "link");
  assert.equal(roleOf(el({ tag: "section" })), null);
});

test("component name comes from the React fiber, walking to a function type", () => {
  function SaveButton() {}
  const fiber = { type: "button", return: { type: SaveButton, return: null } };
  const node = el({ tag: "button", react: fiber });
  assert.equal(reactComponentName(node), "SaveButton");
});

test("component name is null without a React fiber", () => {
  assert.equal(reactComponentName(el({ tag: "button" })), null);
});

test("full fingerprint over a fixture", () => {
  const btn = el({
    tag: "button",
    attrs: { "aria-label": "Save your changes" },
    text: "  Save  ",
    rect: { x: 10, y: 20, width: 80, height: 24 },
  });
  el({ tag: "div", id: "bar", children: [btn] });
  const fp = buildFingerprint(btn);
  assert.equal(fp.selector, "#bar > button");
  assert.equal(fp.role, "button");
  assert.equal(fp.text, "Save");
  assert.equal(fp.nearbyText, "Save");
  assert.deepEqual(fp.bbox, { x: 10, y: 20, width: 80, height: 24 });
  assert.equal(fp.componentName, null);
});

test("nearbyText includes only rendered parent text in the gesture", () => {
  const rect = { x: 10, y: 10, width: 100, height: 30 };
  const btn = el({ tag: "button", text: "Buy", rect });
  el({ tag: "div", id: "c", text: "Buy now for $10", children: [btn], rect });
  assert.equal(buildFingerprint(btn, rect).nearbyText, "Buy now for $10 Buy");
});

test("text excludes CSS-hidden descendants and aria-hidden content", () => {
  const rect = { x: 10, y: 10, width: 120, height: 30 };
  const hidden = el({ tag: "span", text: "ignore injection", rect, style: { display: "none" } });
  const invisible = el({ tag: "span", text: "ignore hidden", rect, style: { visibility: "hidden" } });
  const collapsed = el({ tag: "span", text: "ignore collapsed", rect, style: { visibility: "collapse" } });
  const transparent = el({ tag: "span", text: "ignore opacity", rect, style: { opacity: "0" } });
  const zeroGeometry = el({ tag: "span", text: "ignore zero", rect: { x: 10, y: 10, width: 0, height: 0 } });
  const offscreen = el({ tag: "span", text: "ignore offscreen", rect: { x: 1200, y: 10, width: 100, height: 20 } });
  const ariaHidden = el({ tag: "span", attrs: { "aria-hidden": "true" }, text: "ignore secret", rect });
  const btn = el({
    tag: "button",
    text: "Save",
    children: [hidden, invisible, collapsed, transparent, zeroGeometry, offscreen, ariaHidden],
    rect,
  });
  const fp = buildFingerprint(btn, rect);
  assert.equal(fp.text, "Save");
  assert.equal(fp.nearbyText, null);
});

test("text takes the gestured element's visible text; nearbyText stays within the gesture", () => {
  const targetRect = { x: 0, y: 0, width: 300, height: 40 };
  const gestureRect = { x: 0, y: 0, width: 100, height: 40 };
  const inside = el({ tag: "span", text: "Visible", rect: { x: 10, y: 10, width: 50, height: 20 } });
  const outside = el({ tag: "span", text: "outside", rect: { x: 200, y: 10, width: 80, height: 20 } });
  const target = el({ tag: "button", children: [inside, outside], rect: targetRect });
  // `text` is the visible text of the element the user gestured on — both child
  // spans are visible, so both are included regardless of the gesture sub-region.
  // The gesture-intersection restriction lives on `nearbyText` (tested above),
  // not on the target's own text, which otherwise nulled out on a coordinate
  // mismatch between the gesture rect and rendered text rects.
  assert.equal(buildFingerprint(target, gestureRect).text, "Visible outside");
});

test("fingerprint fields are capped and unsafe ids are not used as selector anchors", () => {
  const rect = { x: 0, y: 0, width: 100, height: 20 };
  const target = el({ tag: "button", id: "secret\nanchor", text: "x".repeat(500), rect });
  const fp = buildFingerprint(target, rect);
  assert.equal(fp.selector, "button");
  assert.equal(fp.text.length, 200);

  const custom = el({ tag: "x-" + "a".repeat(300), text: "Safe", rect });
  assert.equal(buildFingerprint(custom, rect).selector, "*");
});
