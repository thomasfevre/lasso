#if os(macOS)
import AppKit
import ScreenCaptureKit

enum ConductorError: Error, CustomStringConvertible {
    case noDisplay
    case captureFailed(String)
    case encodeFailed

    var description: String {
        switch self {
        case .noDisplay: return "no matching ScreenCaptureKit display for the active screen"
        case .captureFailed(let m): return "screenshot failed: \(m)"
        case .encodeFailed: return "could not encode annotated PNG"
        }
    }
}

/// Captures a screen region as an annotated PNG using ScreenCaptureKit (the
/// modern, non-deprecated path; Screen Recording permission is required and will
/// also serve SPE-546). The whole active display is captured, then cropped to the
/// selection in device pixels, then a red rectangle is drawn just inside the crop
/// to mark the captured Region for the Agent.
/// `@MainActor` pins the `NSScreen` access (which is not `Sendable`) to the main
/// actor, matching how the capture flow is invoked from `ConductorApp`.
/// A captured region: the annotated PNG written to the Store, plus the
/// un-annotated crop kept for OCR (SPE-546) — text recognition must not see the
/// red marker rectangle.
struct CapturedRegion {
    let png: Data
    let regionImage: CGImage
}

@MainActor
enum RegionCapturer {
    /// `globalRect` is in AppKit global points (bottom-left origin); `screen` is
    /// the display it was drawn on.
    static func capture(globalRect: CGRect, screen: NSScreen) async throws -> CapturedRegion {
        guard let displayID = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            throw ConductorError.noDisplay
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ConductorError.noDisplay
        }

        let scale = screen.backingScaleFactor
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(scDisplay.width) * scale)
        config.height = Int(CGFloat(scDisplay.height) * scale)
        config.showsCursor = true // Keep the pointer so the Agent sees where the user was.

        let full: CGImage
        do {
            full = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        } catch {
            throw ConductorError.captureFailed(error.localizedDescription)
        }

        let cropped = try crop(full, globalRect: globalRect, screen: screen, scale: scale)
        guard let png = annotatedPNG(from: cropped) else { throw ConductorError.encodeFailed }
        return CapturedRegion(png: png, regionImage: cropped)
    }

    /// Converts the selection from global points to top-left device pixels within
    /// the display image and crops it.
    private static func crop(_ image: CGImage, globalRect: CGRect,
                             screen: NSScreen, scale: CGFloat) throws -> CGImage {
        let frame = screen.frame
        // x relative to the display's left; y measured from the display's top.
        let xPoints = globalRect.minX - frame.minX
        let yPointsFromTop = frame.maxY - globalRect.maxY

        var pixelRect = CGRect(x: xPoints * scale, y: yPointsFromTop * scale,
                               width: globalRect.width * scale, height: globalRect.height * scale)
        // Clamp to the image so an edge drag never produces an invalid crop.
        pixelRect = pixelRect.integral.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !pixelRect.isNull, pixelRect.width >= 1, pixelRect.height >= 1,
              let cropped = image.cropping(to: pixelRect) else {
            throw ConductorError.captureFailed("selection outside the display")
        }
        return cropped
    }

    /// Draws the source image then strokes a red rectangle inset by the line width
    /// so the marker sits inside the captured pixels.
    private static func annotatedPNG(from image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let lineWidth = max(2, CGFloat(min(width, height)) * 0.012)
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(lineWidth)
        ctx.stroke(CGRect(x: lineWidth / 2, y: lineWidth / 2,
                          width: CGFloat(width) - lineWidth, height: CGFloat(height) - lineWidth))

        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}
#endif
