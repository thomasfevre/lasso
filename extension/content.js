// SPE-549: content-script half of the web path. Receives a Gesture bbox in
// top-left screen CSS pixels, translates it to a viewport point, resolves the
// element under it, and returns its DOM Fingerprint.
//
// Coordinate translation (ADR 0007): screenX/screenY and elementFromPoint both
// operate in CSS pixels, so devicePixelRatio is deliberately NOT applied here —
// it only matters for the Conductor's device-pixel screenshot. The browser
// content area's top-left in screen space is (screenX, screenY + chromeHeight),
// where chromeHeight = outerHeight - innerHeight (toolbars/tabs).

if (!globalThis.__lassoInjected) {
  globalThis.__lassoInjected = true;

  function screenToClient(bboxScreen) {
    const chromeHeight = window.outerHeight - window.innerHeight;
    const contentLeft = window.screenX;
    const contentTop = window.screenY + chromeHeight;
    return {
      x: bboxScreen.x - contentLeft,
      y: bboxScreen.y - contentTop,
      width: bboxScreen.width,
      height: bboxScreen.height,
    };
  }

  async function resolve(bboxScreen) {
    const gestureRect = screenToClient(bboxScreen);
    const point = {
      x: gestureRect.x + gestureRect.width / 2,
      y: gestureRect.y + gestureRect.height / 2,
    };
    if (point.x < 0 || point.y < 0 || point.x > window.innerWidth || point.y > window.innerHeight) {
      return null; // Gesture landed outside this window's content area.
    }
    const element = document.elementFromPoint(point.x, point.y);
    if (!element) return null;
    const { buildFingerprint } = await import(chrome.runtime.getURL("fingerprint.mjs"));
    return buildFingerprint(element, gestureRect);
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type !== "lasso-resolve") return false;
    resolve(message.bbox)
      .then((fingerprint) => sendResponse({ fingerprint }))
      .catch(() => sendResponse({ fingerprint: null }));
    return true; // async sendResponse
  });
}
