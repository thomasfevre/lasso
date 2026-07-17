// SPE-549: DOM Fingerprint extraction (ADR 0006). Pure, DOM-duck-typed so it runs
// both in the content script (real elements) and under node:test (plain-object
// fixtures). Given the element under the Gesture it produces a robust selector,
// role, text, nearby text, best-effort React component name, and bbox. Lasso
// never resolves file:line — the Agent does, from this Fingerprint.

/// Minimal CSS identifier escape for ids/classes (CSS.escape is absent in node).
function cssEscape(value) {
  return String(value).replace(/([^a-zA-Z0-9_-])/g, "\\$1");
}

const FIELD_LIMITS = {
  identifier: 64,
  selector: 256,
  role: 64,
  text: 200,
  nearbyText: 200,
  componentName: 128,
};

function safeIdentifier(value) {
  const text = String(value || "");
  return text.length <= FIELD_LIMITS.identifier && /^[a-zA-Z_][a-zA-Z0-9_-]*$/.test(text)
    ? text
    : null;
}

function safeTag(el) {
  const name = tag(el);
  return name.length <= FIELD_LIMITS.identifier && /^[a-z][a-z0-9-]*$/.test(name) ? name : "*";
}

function safeSelector(value, el) {
  const selector = String(value).replace(/\s+/g, " ").trim();
  return selector && selector.length <= FIELD_LIMITS.selector ? selector : safeTag(el);
}

function tag(el) {
  return (el.tagName || "").toLowerCase();
}

/// 1-based index of `el` among its same-tag siblings, for :nth-of-type. Returns 0
/// when it is the only one of its type (no suffix needed).
function nthOfType(el) {
  const parent = el.parentElement;
  if (!parent || !parent.children) return 0;
  const sameType = Array.from(parent.children).filter((c) => tag(c) === tag(el));
  if (sameType.length <= 1) return 0;
  return sameType.indexOf(el) + 1;
}

/// A selector that re-finds the element: shortcut to `#id` when present, else a
/// child-combinator path of tag + :nth-of-type, anchored at the nearest ancestor
/// id (or the document root).
export function buildSelector(el) {
  const ownId = safeIdentifier(el.id);
  if (ownId) return `#${cssEscape(ownId)}`;
  const parts = [];
  let node = el;
  while (node && node.tagName && tag(node) !== "html" && tag(node) !== "body") {
    const nodeId = safeIdentifier(node.id);
    if (nodeId) {
      parts.unshift(`#${cssEscape(nodeId)}`);
      return safeSelector(parts.join(" > "), el);
    }
    let part = safeTag(node);
    const idx = nthOfType(node);
    if (idx) part += `:nth-of-type(${idx})`;
    parts.unshift(part);
    node = node.parentElement;
  }
  return safeSelector(parts.join(" > "), el);
}

const IMPLICIT_ROLES = {
  a: "link",
  button: "button",
  input: "textbox",
  select: "combobox",
  textarea: "textbox",
  nav: "navigation",
  header: "banner",
  footer: "contentinfo",
  main: "main",
};

/// Explicit ARIA role, else a common implicit role from the tag.
export function roleOf(el) {
  const explicit = el.getAttribute && el.getAttribute("role");
  if (explicit) {
    const role = String(explicit).trim();
    if (role.length <= FIELD_LIMITS.role && /^[a-zA-Z0-9_-]+$/.test(role)) return role;
  }
  return IMPLICIT_ROLES[tag(el)] || null;
}

function clip(text, max = 200) {
  if (!text) return null;
  const trimmed = String(text).replace(/\s+/g, " ").trim();
  if (!trimmed) return null;
  return trimmed.length > max ? trimmed.slice(0, max) : trimmed;
}

function normalizedRect(rect) {
  if (!rect) return null;
  const left = Number(rect.left ?? rect.x);
  const top = Number(rect.top ?? rect.y);
  const width = Number(rect.width ?? Number(rect.right) - left);
  const height = Number(rect.height ?? Number(rect.bottom) - top);
  if (![left, top, width, height].every(Number.isFinite)) return null;
  return { left, top, right: left + width, bottom: top + height, width, height };
}

function intersects(a, b) {
  return a && b && a.width > 0 && a.height > 0 && b.width > 0 && b.height > 0
    && a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
}

function viewportRect(el) {
  const view = el?.ownerDocument?.defaultView || globalThis.window;
  const width = Number(view?.innerWidth);
  const height = Number(view?.innerHeight);
  if (!Number.isFinite(width) || !Number.isFinite(height)) return null;
  return normalizedRect({ x: 0, y: 0, width, height });
}

function computedStyleOf(el) {
  const view = el?.ownerDocument?.defaultView || globalThis.window;
  if (typeof view?.getComputedStyle === "function") return view.getComputedStyle(el);
  if (typeof globalThis.getComputedStyle === "function") return globalThis.getComputedStyle(el);
  return el?.style || {};
}

function isVisibleElement(el, viewport) {
  for (let node = el; node; node = node.parentElement) {
    if (node.getAttribute?.("aria-hidden")?.trim().toLowerCase() === "true") return false;
    const style = computedStyleOf(node);
    if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse"
        || Number.parseFloat(style.opacity) === 0) return false;
    // Clip-based hiding: the classic screen-reader-only pattern
    // (clip:rect(0,0,0,0) / clip-path:inset(50%), usually with overflow:hidden and
    // a 1x1px box) keeps every property above passing, so a page could stash a
    // secret in a "visually hidden" node under the gesture. Reject clipped nodes.
    if (style.clipPath && style.clipPath !== "none") return false;
    if (style.clip && style.clip !== "auto" && style.clip !== "none") return false;
    if (typeof node.getBoundingClientRect === "function") {
      const rect = normalizedRect(node.getBoundingClientRect());
      if (!rect || rect.width <= 0 || rect.height <= 0 || (viewport && !intersects(rect, viewport))) {
        return false;
      }
      // The other sr-only variant: a ~1px box with overflow:hidden clipping the
      // content out of sight. A tiny box alone is fine (icons, rules), but tiny +
      // clipped overflow is the visually-hidden signature — reject it.
      const tiny = rect.width <= 1 || rect.height <= 1;
      const clipsOverflow = style.overflow === "hidden"
        || style.overflowX === "hidden" || style.overflowY === "hidden";
      if (tiny && clipsOverflow) return false;
    }
  }
  return true;
}

function textNodes(root) {
  const document = root?.ownerDocument;
  if (typeof document?.createTreeWalker === "function") {
    const walker = document.createTreeWalker(root, globalThis.NodeFilter?.SHOW_TEXT ?? 4);
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    return nodes;
  }
  const nodes = [];
  const walk = (node) => {
    for (const child of Array.from(node?.childNodes || [])) {
      if (child.nodeType === 3) nodes.push(child);
      else walk(child);
    }
  };
  walk(root);
  return nodes;
}

function textRects(node) {
  if (typeof node.getClientRects === "function") return Array.from(node.getClientRects());
  const document = node?.ownerDocument;
  if (typeof document?.createRange !== "function") return [];
  const range = document.createRange();
  try {
    range.selectNodeContents(node);
    return Array.from(range.getClientRects());
  } finally {
    range.detach?.();
  }
}

/// Visible text under `root`. Hidden subtrees (display/visibility/opacity/clip,
/// aria-hidden, off-viewport, sr-only) are excluded so a page can't smuggle
/// invisible prompt-injection text into the Fingerprint. When `requireIntersection`
/// is set, only text nodes whose rendered rects overlap the gesture qualify — used
/// for `nearbyText` to keep it local; the element's own `text` takes everything
/// visible, since the user gestured directly on that element.
function visibleTextOf(root, gestureRect, max, requireIntersection) {
  if (!root) return null;
  const region = normalizedRect(gestureRect);
  if (requireIntersection && !region) return null;
  const viewport = viewportRect(root);
  const chunks = [];
  for (const node of textNodes(root)) {
    if (!node.nodeValue?.trim() || !isVisibleElement(node.parentElement, viewport)) continue;
    if (requireIntersection) {
      const rendered = textRects(node).map(normalizedRect).filter(Boolean);
      if (!rendered.some((rect) => intersects(rect, region) && (!viewport || intersects(rect, viewport)))) {
        continue;
      }
    }
    chunks.push(node.nodeValue);
  }
  return clip(chunks.join(" "), max);
}

/// The gestured element's own text. `innerText` is the browser's own rendered,
/// visible text: it already excludes display:none, visibility:hidden, <script> and
/// <style>, which is the security goal (keep hidden/injection text out) and far
/// more reliable than re-deriving visibility by hand. Test fixtures have no
/// innerText, so fall back to the visible-text walk, then to textContent.
/// (Residual: innerText still includes clip-based "sr-only" text; DOM-derived
/// fields are marked untrusted to the agent to bound that.)
function elementText(el, gestureRect) {
  if (typeof el.innerText === "string" && el.innerText.trim()) {
    return clip(el.innerText, FIELD_LIMITS.text);
  }
  return visibleTextOf(el, gestureRect, FIELD_LIMITS.text, false)
    ?? clip(el.textContent, FIELD_LIMITS.text);
}

/// Text nearest the element that helps disambiguate repeated components. Only
/// rendered text intersecting the user's gesture is eligible.
function nearbyTextOf(el, gestureRect) {
  return visibleTextOf(el.parentElement, gestureRect, FIELD_LIMITS.nearbyText, true);
}

/// Best-effort React component name via the DevTools fiber attached to the node.
/// Absent when React (or the hook) is not present — the contract allows null.
export function reactComponentName(el) {
  const key = Object.keys(el).find(
    (k) => k.startsWith("__reactFiber$") || k.startsWith("__reactInternalInstance$"),
  );
  if (!key) return null;
  let fiber = el[key];
  // Walk up to the nearest function/class component (type is a function).
  let hops = 0;
  while (fiber && hops < 30) {
    const type = fiber.type;
    if (typeof type === "function") {
      const name = String(type.displayName || type.name || "").trim();
      return name.length <= FIELD_LIMITS.componentName && /^[a-zA-Z0-9_.$-]+$/.test(name)
        ? name
        : null;
    }
    fiber = fiber.return;
    hops += 1;
  }
  return null;
}

function bboxOf(el) {
  if (typeof el.getBoundingClientRect !== "function") return null;
  const r = el.getBoundingClientRect();
  return { x: r.x ?? r.left, y: r.y ?? r.top, width: r.width, height: r.height };
}

/// Assembles the Fingerprint for one element.
export function buildFingerprint(el, gestureRect = bboxOf(el)) {
  if (!el) return null;
  return {
    selector: buildSelector(el),
    role: roleOf(el),
    text: elementText(el, gestureRect),
    nearbyText: nearbyTextOf(el, gestureRect),
    componentName: reactComponentName(el),
    bbox: bboxOf(el),
  };
}
