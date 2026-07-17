#if os(macOS)
import AppKit
import XCTest
@testable import LassoConductorCore
import LassoCore

final class CaptureExporterTests: XCTestCase {
    private var storeDirectory: URL!
    private var exportDirectory: URL!

    override func setUpWithError() throws {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        storeDirectory = temporary.appendingPathComponent("lasso-export-store-" + UUID().uuidString, isDirectory: true)
        exportDirectory = temporary.appendingPathComponent("lasso-export-output-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDirectory)
        try? FileManager.default.removeItem(at: exportDirectory)
    }

    func testExportCreatesSelfContainedPackageWithOriginalAndAnnotatedCapture() throws {
        let png = try makePNG()
        let writer = try Store(directory: storeDirectory)
        let inserted = try writer.insert(
            imagePNG: png,
            context: CaptureContext(appName: "Safari", windowTitle: "Dashboard review"),
            note: "Check the empty state",
            markers: [Marker(index: 1, x: 0.5, y: 0.5, note: "CTA is too low")]
        )
        try writer.updateTags(["client-a", "review"], id: inserted.id)
        let capture = try XCTUnwrap(writer.capture(id: inserted.id))
        let image = try XCTUnwrap(NSImage(data: png))

        let zip = try CaptureExporter.export(
            items: [.init(capture: capture, image: image)],
            store: writer,
            to: exportDirectory
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))

        let unpacked = exportDirectory.appendingPathComponent("unpacked", isDirectory: true)
        try unzip(zip, to: unpacked)
        let root = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first)
        let package = root.appendingPathComponent("capture-\(capture.id)", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("capture.json").path))
        XCTAssertEqual(try Data(contentsOf: package.appendingPathComponent("original.png")), png)
        XCTAssertNotEqual(try Data(contentsOf: package.appendingPathComponent("annotated.png")), png)

        let json = try String(contentsOf: package.appendingPathComponent("capture.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("client-a"))
        XCTAssertTrue(json.contains("CTA is too low"))
    }

    func testExportRejectsRecentlyDeletedCapturesWithoutLeavingAStagingFolder() throws {
        let png = try makePNG()
        let store = try Store(directory: storeDirectory)
        let inserted = try store.insert(imagePNG: png, context: CaptureContext(), note: nil)
        try store.moveToTrash(id: inserted.id)
        let deleted = try XCTUnwrap(store.capture(id: inserted.id))
        let image = try XCTUnwrap(NSImage(data: png))

        XCTAssertThrowsError(try CaptureExporter.export(items: [.init(capture: deleted, image: image)], store: store, to: exportDirectory))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: exportDirectory, includingPropertiesForKeys: nil).count, 0)
    }

    func testBatchExportCreatesOnePackagePerCapture() throws {
        let png = try makePNG()
        let store = try Store(directory: storeDirectory)
        let first = try store.insert(imagePNG: png, context: CaptureContext(), note: "first")
        let second = try store.insert(imagePNG: png, context: CaptureContext(), note: "second")
        let image = try XCTUnwrap(NSImage(data: png))

        let zip = try CaptureExporter.export(
            items: [
                .init(capture: first, image: image),
                .init(capture: second, image: image),
            ],
            store: store,
            to: exportDirectory
        )
        let unpacked = exportDirectory.appendingPathComponent("unpacked", isDirectory: true)
        try unzip(zip, to: unpacked)
        let root = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("capture-\(first.id)/original.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("capture-\(second.id)/original.png").path))
    }

    func testExportCleansItsStagingFolderWhenAnItemCannotBeRead() throws {
        let png = try makePNG()
        let store = try Store(directory: storeDirectory)
        let first = try store.insert(imagePNG: png, context: CaptureContext(), note: nil)
        let missingImage = try store.insert(imagePNG: png, context: CaptureContext(), note: nil)
        try FileManager.default.removeItem(at: storeDirectory.appendingPathComponent(missingImage.imageFile))
        let image = try XCTUnwrap(NSImage(data: png))

        XCTAssertThrowsError(try CaptureExporter.export(
            items: [.init(capture: first, image: image), .init(capture: missingImage, image: image)],
            store: store,
            to: exportDirectory
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: exportDirectory, includingPropertiesForKeys: nil).count, 0)
    }

    private func makePNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 120, height: 80))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        return try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }

    private func unzip(_ zip: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, destination.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
#endif
