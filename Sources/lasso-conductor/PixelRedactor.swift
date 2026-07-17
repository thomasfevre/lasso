#if os(macOS)
import AppKit
import CoreImage
import LassoCore

/// SPE-562 / SPE-580: replaces recognized secret text with opaque rectangles,
/// pairing with the pure `SecretRedactor` text pass. The caller supplies the OCR
/// lines used for Region Context so text and pixels cannot disagree because of
/// separate recognition passes.
@MainActor
enum PixelRedactor {
    struct Result {
        var png: Data
        var status: RedactionStatus
    }

    enum RedactionError: Error, CustomStringConvertible {
        case decode
        case render
        case encode

        var description: String {
            switch self {
            case .decode: return "pixel redaction could not decode the captured PNG"
            case .render: return "pixel redaction could not render opaque fills"
            case .encode: return "pixel redaction could not encode the redacted PNG"
            }
        }
    }

    /// Returns the original bytes only after OCR succeeded and found no secrets.
    /// Every decode/render/encode failure throws so persistence is blocked.
    static func redactSecrets(inPNG png: Data, observations: [RecognizedTextLine],
                              options: SecretRedactor.Options = .default) throws -> Result {
        guard let source = NSBitmapImageRep(data: png)?.cgImage
                ?? NSImage(data: png)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RedactionError.decode
        }
        let secretObservations = observations.filter {
            SecretRedactor.redact($0.text, options: options).didRedact
        }
        guard !secretObservations.isEmpty else {
            return Result(png: png, status: .none)
        }
        let width = source.width, height = source.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var rects: [CGRect] = []
        for observation in secretObservations {
            // Vision's boundingBox is normalized, bottom-left origin — the same
            // orientation as CoreImage's pixel space, so scale it directly. Pad a
            // little so anti-aliased glyph edges are covered.
            let b = observation.boundingBox
            let rect = CGRect(x: b.minX * CGFloat(width), y: b.minY * CGFloat(height),
                              width: b.width * CGFloat(width), height: b.height * CGFloat(height))
                .insetBy(dx: -4, dy: -4)
                .intersection(bounds)
                .integral
            // Fail closed on *any* collapsed rect. A secret detected but whose box
            // degenerated (e.g. clipped at the crop edge) must not be silently
            // skipped: the text path would still mark it redacted while the pixels
            // stayed legible — exactly the mismatch SPE-580 exists to prevent.
            guard !rect.isNull, rect.width >= 1, rect.height >= 1 else {
                throw RedactionError.render
            }
            rects.append(rect)
        }
        guard !rects.isEmpty else { throw RedactionError.render }
        return Result(png: try fill(rects, in: source), status: .redacted)
    }

    /// Composites fully opaque black fills over each padded secret region.
    private static func fill(_ rects: [CGRect], in source: CGImage) throws -> Data {
        let base = CIImage(cgImage: source)
        var composite = base
        for rect in rects {
            let fill = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
                .cropped(to: rect)
            composite = fill.composited(over: composite)
        }
        let context = CIContext()
        guard let out = context.createCGImage(composite, from: base.extent) else {
            throw RedactionError.render
        }
        guard let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else {
            throw RedactionError.encode
        }
        return png
    }
}
#endif
