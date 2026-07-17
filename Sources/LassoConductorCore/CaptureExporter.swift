#if os(macOS)
import AppKit
import Foundation
import LassoCore

/// Creates a self-contained hand-off package without changing the stored Capture.
public enum CaptureExporter {
    public struct Item {
        public let capture: Capture
        public let image: NSImage

        public init(capture: Capture, image: NSImage) {
            self.capture = capture
            self.image = image
        }
    }

    public static func export(items: [Item], store: Store, to destination: URL) throws -> URL {
        guard !items.isEmpty else { throw StoreError.access("select at least one capture to export") }
        guard items.allSatisfy({ $0.capture.libraryState != .recentlyDeleted }) else {
            throw StoreError.access("Recently Deleted captures cannot be exported")
        }
        let root = destination.appendingPathComponent("Lasso export \(timestamp())-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for item in items {
            let capture = item.capture
            let package = root.appendingPathComponent("capture-\(capture.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let original = try store.imageData(for: capture)
            try original.write(to: package.appendingPathComponent("original.png"), options: .atomic)
            guard let annotated = annotatedPNG(image: item.image, markers: capture.markers) else {
                throw StoreError.imageWrite("could not render annotated preview")
            }
            try annotated.write(to: package.appendingPathComponent("annotated.png"), options: .atomic)
            try markdown(for: capture).data(using: .utf8)?.write(to: package.appendingPathComponent("README.md"), options: .atomic)
            try json(for: capture).write(to: package.appendingPathComponent("capture.json"), options: .atomic)
        }
        let overview = "# Lasso export\n\n\(items.count) immutable capture package(s). Each folder contains original.png, annotated.png, README.md, and capture.json.\n"
        try overview.data(using: .utf8)?.write(to: root.appendingPathComponent("README.md"), options: .atomic)
        let zip = destination.appendingPathComponent(root.lastPathComponent + ".zip")
        try zipDirectory(root, to: zip)
        return zip
    }

    private static func annotatedPNG(image: NSImage, markers: [Marker]) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        let imageRect = NSRect(origin: .zero, size: size)
        let diameter = PinBadgeRenderer.exportDiameter(for: size)
        for marker in markers.sorted(by: { $0.index < $1.index }) {
            let center = PinBadgeRenderer.center(for: marker, in: imageRect)
            PinBadgeRenderer.draw(
                index: marker.index,
                in: PinBadgeRenderer.rect(centeredAt: center, diameter: diameter),
                shadow: false
            )
        }
        out.unlockFocus()
        return out.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
    }

    private static func markdown(for capture: Capture) -> String {
        let pins = capture.markers.sorted { $0.index < $1.index }.map { marker in
            "- Pin \(marker.index): \(marker.note?.isEmpty == false ? marker.note! : "No note")"
        }.joined(separator: "\n")
        return "# Capture \(capture.id)\n\n- Captured: \(ISO8601DateFormatter().string(from: capture.createdAt))\n- App: \(capture.context.appName ?? "Unknown")\n- Window: \(capture.context.windowTitle ?? "Unknown")\n- Tags: \(capture.tags.joined(separator: ", "))\n\n## Note\n\n\(capture.note ?? "No note")\n\n## Pins\n\n\(pins.isEmpty ? "No pins" : pins)\n"
    }

    private static func json(for capture: Capture) throws -> Data {
        let value = ExportRecord(id: capture.id, createdAt: capture.createdAt, note: capture.note, tags: capture.tags, context: capture.context, markers: capture.markers)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private static func zipDirectory(_ root: URL, to zip: URL) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, zip.path]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw StoreError.imageWrite("could not create export zip") }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter.string(from: Date())
    }

    private struct ExportRecord: Codable {
        let id: Int64; let createdAt: Date; let note: String?; let tags: [String]
        let context: CaptureContext; let markers: [Marker]
    }
}
#endif
