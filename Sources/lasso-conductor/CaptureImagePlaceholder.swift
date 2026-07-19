#if os(macOS)
import AppKit

enum CaptureImagePlaceholder {
    static func make(size: NSSize = NSSize(width: 640, height: 420)) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()

            let symbol = NSImage(
                systemSymbolName: "photo.badge.exclamationmark",
                accessibilityDescription: "Capture image unavailable"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 42, weight: .regular)
            )
            let symbolSize = NSSize(width: 56, height: 56)
            let symbolRect = NSRect(
                x: rect.midX - symbolSize.width / 2,
                y: rect.midY - 20,
                width: symbolSize.width,
                height: symbolSize.height
            )
            symbol?.draw(in: symbolRect)

            let message = "Image unavailable" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let textSize = message.size(withAttributes: attributes)
            message.draw(
                at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - 54),
                withAttributes: attributes
            )
            return true
        }
    }
}
#endif
