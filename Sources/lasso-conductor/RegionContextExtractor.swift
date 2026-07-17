#if os(macOS)
import AppKit
import Vision
import ApplicationServices
import LassoCore
import LassoConductorCore

struct RecognizedTextLine {
    var text: String
    var boundingBox: CGRect
}

struct RegionOCRResult {
    var selection: OCRTextSelection
    var observations: [RecognizedTextLine]
}

/// SPE-546: best-effort Region Context for a screen Capture. Runs Vision OCR over
/// the gestured region's pixels and reads the macOS Accessibility element under
/// the Gesture, then hands both to the pure `RegionContextResolver` to pick
/// `context.source` / `context.text`. Extraction is scoped to the region (OCR on
/// the cropped image, AX on the Gesture point) — never the whole screen.
@MainActor
enum RegionContextExtractor {
    /// `regionImage` is the un-annotated crop of the gestured region (OCR must not
    /// see the red marker rectangle). `gestureCenterGlobal` is the Gesture centre
    /// in AppKit global points (bottom-left origin).
    static func extract(ocr: OCRTextSelection, gestureCenterGlobal: CGPoint) -> CaptureContext {
        let ax = accessibilityText(at: gestureCenterGlobal)
        return RegionContextResolver.resolve(
            accessibilityText: ax,
            ocrText: ocr.text,
            layout: ocr.layoutHint
        )
    }

    /// SPE-560: per-pin text for a screen target. Tries the accessibility element
    /// under the pin's global point first (precise), then falls back to the closest
    /// line from the shared region OCR. `normalized` is the pin's [0,1] top-left
    /// point; `globalPoint` is the same pin in AppKit global points. Best-effort —
    /// returns nil when neither yields text.
    static func pinText(ocr: RegionOCRResult, normalized: CGPoint, globalPoint: CGPoint) -> String? {
        if let ax = accessibilityText(at: globalPoint) { return ax }
        let point = CGPoint(x: normalized.x, y: 1 - normalized.y)
        return ocr.observations
            .filter { $0.boundingBox.insetBy(dx: -0.2, dy: -0.2).contains(point) }
            .min { lhs, rhs in
                distanceSquared(from: lhs.boundingBox, to: point)
                    < distanceSquared(from: rhs.boundingBox, to: point)
            }?
            .text
    }

    private static func distanceSquared(from rect: CGRect, to point: CGPoint) -> CGFloat {
        let dx = rect.midX - point.x
        let dy = rect.midY - point.y
        return dx * dx + dy * dy
    }

    // MARK: - OCR (Vision)

    private struct VisionOCRPass {
        var observations: [OCRTextObservation]
        var recognizedLines: [RecognizedTextLine]
        var text: String?
    }

    /// Runs both variants because language correction can erase the camelCase and
    /// snake_case signals needed to recognize code. The pure classifier inspects
    /// the uncorrected observations; prose still selects corrected text, while
    /// code selects the indentation-preserving pass with corrected text fallback.
    static func recognize(_ image: CGImage) throws -> RegionOCRResult {
        let uncorrected = try performOCR(
            image,
            usesLanguageCorrection: false,
            preserveIndentation: true
        )
        let corrected = try performOCR(
            image,
            usesLanguageCorrection: true,
            preserveIndentation: false
        )
        let layout = TextLayoutClassifier.classify(uncorrected.observations)
        let selection = OCRTextPolicy.select(
            classifiedLayout: layout,
            correctedText: corrected.text,
            uncorrectedText: uncorrected.text
        )
        return RegionOCRResult(
            selection: selection,
            observations: uncorrected.recognizedLines + corrected.recognizedLines
        )
    }

    private static func performOCR(
        _ image: CGImage,
        usesLanguageCorrection: Bool,
        preserveIndentation: Bool
    ) throws -> VisionOCRPass {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let recognized = (request.results ?? []).compactMap { observation -> (String, CGRect)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (text, observation.boundingBox)
        }
        let observations = recognized.map {
            OCRTextObservation(text: $0.0, minX: Double($0.1.minX))
        }
        let lines = preserveIndentation ? indentedLines(recognized) : recognized.map(\.0)
        let joined = lines.joined(separator: "\n")
        let recognizedLines = recognized.map { RecognizedTextLine(text: $0.0, boundingBox: $0.1) }
        return VisionOCRPass(
            observations: observations,
            recognizedLines: recognizedLines,
            text: joined.isEmpty ? nil : joined
        )
    }

    /// Vision returns line boxes but not leading spaces. For code OCR, infer
    /// indentation from each normalized left edge and the median glyph width.
    private static func indentedLines(_ lines: [(String, CGRect)]) -> [String] {
        guard let leftEdge = lines.map({ $0.1.minX }).min() else { return [] }
        let widths = lines.compactMap { text, box -> CGFloat? in
            let count = text.count
            return count > 0 && box.width > 0 ? box.width / CGFloat(count) : nil
        }.sorted()
        guard !widths.isEmpty else { return lines.map(\.0) }
        let glyphWidth = widths[widths.count / 2]
        return lines.map { text, box in
            let columns = Int(((box.minX - leftEdge) / glyphWidth).rounded())
            return String(repeating: " ", count: min(max(columns, 0), 32)) + text
        }
    }

    // MARK: - Accessibility

    private static func accessibilityText(at globalPoint: CGPoint) -> String? {
        // Without the Accessibility grant AX calls fail silently; skip cleanly so
        // OCR still provides context.
        guard AXIsProcessTrusted() else { return nil }

        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        // AXUIElementCopyElementAtPosition takes top-left global (Quartz) coords.
        let quartz = flipToQuartz(globalPoint)
        guard AXUIElementCopyElementAtPosition(
            system, Float(quartz.x), Float(quartz.y), &element) == .success,
              let element else {
            return nil
        }

        // Value first (field contents), then the element's label/help text.
        for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let text = stringAttribute(element, attribute) { return text }
        }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let string = value as? String,
              !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return string
    }

    /// AppKit global (bottom-left) to Quartz global (top-left) via the shared
    /// `ScreenSpace` flip — the same global transform `WindowEnumerator` and the
    /// web path use, correct for every display (see `ScreenSpace.flipY`).
    private static func flipToQuartz(_ point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return ScreenSpace.topLeftPoint(fromBottomLeft: point, primaryHeight: primaryHeight)
    }
}
#endif
