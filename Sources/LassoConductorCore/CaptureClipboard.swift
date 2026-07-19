#if os(macOS)
import AppKit
import LassoCore

/// Writes one self-contained visual handoff. Chat inputs disagree about whether
/// to prefer text or an image when both are present; keeping the note, pins and
/// context inside the image makes one paste deterministic everywhere.
public enum CaptureClipboard {
    @discardableResult
    public static func write(capture: Capture, image: NSImage, to pasteboard: NSPasteboard) -> Bool {
        guard let png = CaptureExporter.handoffPNG(capture: capture, image: image) else {
            return false
        }

        let imageItem = NSPasteboardItem()
        guard imageItem.setData(png, forType: .png) else {
            return false
        }
        if let tiff = NSImage(data: png)?.tiffRepresentation {
            imageItem.setData(tiff, forType: .tiff)
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects([imageItem])
    }
}
#endif
