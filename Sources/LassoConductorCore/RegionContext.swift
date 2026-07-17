import Foundation
import LassoCore

// SPE-546: Region Context resolution. Extraction itself (Vision OCR, the macOS
// Accessibility API) is platform-specific and lives in the Conductor; this is the
// pure policy that turns best-effort extraction candidates into the unified
// `CaptureContext` (ADR 0004). Kept here so the source-selection rule unit-tests
// on any platform.
public enum RegionContextResolver {
    /// Builds the Region Context from the two extraction candidates over the
    /// gestured region.
    ///
    /// Accessibility text — read from the element under the Gesture, so it is
    /// structured and already de-noised — wins when present. OCR (recognized from
    /// the region's pixels) is the fallback. When neither yields anything, the
    /// source is `none` and `text` is nil, exactly as a blank region should read.
    /// Whitespace-only candidates count as empty.
    public static func resolve(
        accessibilityText: String?,
        ocrText: String?,
        layout: TextLayout? = nil
    ) -> CaptureContext {
        if let ax = normalized(accessibilityText) {
            return CaptureContext(source: .accessibility, text: ax)
        }
        if let ocr = normalized(ocrText, preservingWhitespace: layout == .code) {
            return CaptureContext(source: .ocr, text: ocr, layout: layout)
        }
        return CaptureContext(source: .none, text: nil)
    }

    /// Trims surrounding whitespace/newlines; returns nil for nil or blank input.
    private static func normalized(_ s: String?, preservingWhitespace: Bool = false) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return preservingWhitespace ? s : trimmed
    }
}
