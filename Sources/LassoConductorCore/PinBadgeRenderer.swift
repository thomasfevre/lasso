#if os(macOS)
import AppKit
import LassoCore

/// One rendering contract for persisted pin badges in both the read-only
/// Capture detail and exported annotated images.
public enum PinBadgeRenderer {
    public static let detailDiameter: CGFloat = 26

    public static func exportDiameter(for imageSize: NSSize) -> CGFloat {
        max(28, min(imageSize.width, imageSize.height) * 0.05)
    }

    /// Marker coordinates are normalized from the image's top-left. AppKit
    /// drawing coordinates are bottom-left, so the vertical axis is inverted.
    public static func center(for marker: Marker, in imageRect: NSRect) -> CGPoint {
        CGPoint(
            x: imageRect.minX + CGFloat(marker.x) * imageRect.width,
            y: imageRect.maxY - CGFloat(marker.y) * imageRect.height
        )
    }

    public static func rect(centeredAt center: CGPoint, diameter: CGFloat) -> NSRect {
        NSRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
    }

    public static func draw(index: Int, in rect: NSRect, shadow: Bool) {
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
        if shadow {
            NSGraphicsContext.current?.cgContext.saveGState()
            NSGraphicsContext.current?.cgContext.setShadow(
                offset: CGSize(width: 0, height: -1),
                blur: 6,
                color: NSColor.black.withAlphaComponent(0.55).cgColor
            )
        }
        NSGradient(starting: indigoHigh, ending: indigoLow)?.draw(in: circle, angle: -60)
        if shadow { NSGraphicsContext.current?.cgContext.restoreGState() }

        NSColor.white.withAlphaComponent(0.9).setStroke()
        circle.lineWidth = max(1.5, rect.width * 0.058)
        circle.stroke()

        let text = "\(index)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: rect.width * 0.46, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 + 1),
            withAttributes: attributes
        )
    }

    private static let indigoHigh = NSColor(
        srgbRed: 0.290, green: 0.361, blue: 0.682, alpha: 1
    )
    private static let indigoLow = NSColor(
        srgbRed: 0.192, green: 0.247, blue: 0.494, alpha: 1
    )
}
#endif
