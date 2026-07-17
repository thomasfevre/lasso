import test from "node:test";
import assert from "node:assert/strict";

import { isInjectableUrl } from "../injectable-url.mjs";

test("accepts HTTP and HTTPS pages", () => {
  assert.equal(isInjectableUrl("https://example.com/docs"), true);
  assert.equal(isInjectableUrl("http://localhost:3000/"), true);
});

test("rejects browser and extension pages", () => {
  assert.equal(isInjectableUrl("chrome://extensions/"), false);
  assert.equal(isInjectableUrl("chrome-extension://abc/options.html"), false);
  assert.equal(isInjectableUrl("about:blank"), false);
  assert.equal(isInjectableUrl("file:///tmp/index.html"), false);
});

test("rejects current and legacy Chrome Web Store URLs", () => {
  assert.equal(isInjectableUrl("https://chromewebstore.google.com/detail/lasso/abc"), false);
  assert.equal(isInjectableUrl("https://chrome.google.com/webstore/detail/lasso/abc"), false);
});

test("rejects absent or malformed URLs", () => {
  assert.equal(isInjectableUrl(undefined), false);
  assert.equal(isInjectableUrl("not a url"), false);
});
