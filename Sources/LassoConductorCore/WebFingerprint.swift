import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import LassoCore

// SPE-549: the Conductor's half of the web path. The browser extension does the
// DOM work (element resolution + Fingerprint extraction, tested in JS); the
// Conductor translates the Gesture into screen coordinates the extension
// understands, then maps the extension's JSON reply back into the unified
// `DOMFingerprint` contract. Both steps are pure and unit-tested here.

public enum ScreenSpace {
    /// The single AppKit↔Quartz flip. AppKit global coordinates are bottom-left
    /// origin at the *primary* screen; Quartz global coordinates are top-left
    /// origin at the same primary screen. The two differ only by flipping y about
    /// the primary screen's height — and because both systems are anchored to the
    /// primary and every other display extends into the same continuous plane,
    /// this ONE global transform is correct for every display, including secondary
    /// screens above or left of primary (which yield y > primaryHeight in AppKit,
    /// hence negative Quartz y). It is not a primary-only mapping. The transform is
    /// its own inverse.
    public static func flipY(_ y: CGFloat, primaryHeight: CGFloat) -> CGFloat {
        primaryHeight - y
    }

    /// AppKit global point (bottom-left) to Quartz global point (top-left).
    public static func topLeftPoint(fromBottomLeft point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: flipY(point.y, primaryHeight: primaryHeight))
    }

    /// AppKit global rect (bottom-left origin) to top-left screen rect. Browser
    /// window geometry (`screenX` / `screenY`, `devicePixelRatio`) lives in this
    /// top-left CSS-pixel space, so the extension can translate the Gesture to a
    /// page point from it. Flips the rect's *max* y (its top edge in AppKit) to the
    /// rect's *min* y (its top edge in Quartz).
    public static func topLeftRect(fromBottomLeft rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: flipY(rect.maxY, primaryHeight: primaryHeight),
               width: rect.width, height: rect.height)
    }
}

public enum WebFingerprint {
    /// Maps the extension's JSON reply into a `DOMFingerprint`. A reply is only
    /// usable with a non-empty `selector` (the Agent's anchor); everything else is
    /// optional and degrades to nil — `componentName` is absent when the React
    /// DevTools hook is not present, exactly as the contract allows.
    public static func decode(_ json: [String: Any]) -> DOMFingerprint? {
        guard let selector = string(json["selector"]), !selector.isEmpty else { return nil }

        var bbox: BBox?
        if let b = json["bbox"] as? [String: Any],
           let x = number(b["x"]), let y = number(b["y"]),
           let w = number(b["width"]), let h = number(b["height"]) {
            bbox = BBox(x: x, y: y, width: w, height: h)
        }

        return DOMFingerprint(
            selector: selector,
            role: string(json["role"]),
            text: string(json["text"]),
            nearbyText: string(json["nearbyText"]),
            componentName: string(json["componentName"]),
            bbox: bbox)
    }

    private static func string(_ value: Any?) -> String? {
        guard let s = value as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }
}
