// SPE-570: Chrome refuses content-script injection into browser-owned pages and
// the Chrome Web Store. Keep this filter pure so the install/pairing injection
// path can be covered under node:test.

export function isInjectableUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    return false;
  }

  if (url.protocol !== "http:" && url.protocol !== "https:") return false;
  if (url.hostname === "chromewebstore.google.com") return false;
  if (url.hostname === "chrome.google.com" && url.pathname.startsWith("/webstore")) return false;
  return true;
}
