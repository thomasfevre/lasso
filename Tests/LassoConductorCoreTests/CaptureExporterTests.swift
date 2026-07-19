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

    func testAnnotatedPNGIsAvailableForAQuickPasteAndIncludesPins() throws {
        let png = try makePNG()
        let image = try XCTUnwrap(NSImage(data: png))

        let annotated = try XCTUnwrap(CaptureExporter.annotatedPNG(
            image: image,
            markers: [Marker(index: 1, x: 0.5, y: 0.5)]
        ))

        XCTAssertTrue(annotated.starts(with: Data([0x89, 0x50, 0x4E, 0x47])))
        XCTAssertNotEqual(annotated, png)
    }

    func testHandoffMarkdownIncludesNotesPinsAndResolvedContext() {
        let capture = Capture(
            id: 42,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            imageFile: "42.png",
            note: "Make the empty state clearer",
            context: CaptureContext(
                source: .dom,
                text: "Revenue overview",
                dom: DOMFingerprint(
                    selector: "main > section.dashboard",
                    role: "region",
                    text: "Revenue",
                    nearbyText: "Last 30 days",
                    componentName: "RevenueDashboard",
                    bbox: BBox(x: 10, y: 20, width: 640, height: 480)
                ),
                appName: "Google Chrome",
                windowTitle: "Analytics dashboard",
                layout: .code
            ),
            markers: [
                Marker(index: 1, x: 0.25, y: 0.4, note: "CTA is too low", text: "Save changes"),
                Marker(
                    index: 2,
                    x: 0.75,
                    y: 0.6,
                    note: "Use the compact variant",
                    dom: DOMFingerprint(
                        selector: "button.primary",
                        role: "button",
                        text: "Save",
                        nearbyText: "Cancel",
                        componentName: "SaveButton"
                    )
                ),
            ],
            redactionStatus: .redacted,
            tags: ["client-a", "review"],
            libraryState: .kept
        )

        let markdown = CaptureExporter.handoffMarkdown(for: capture)

        XCTAssertTrue(markdown.contains("# Lasso Capture 42"))
        XCTAssertTrue(markdown.contains("Make the empty state clearer"))
        XCTAssertTrue(markdown.contains("client-a, review"))
        XCTAssertTrue(markdown.contains("Pin 1"))
        XCTAssertTrue(markdown.contains("CTA is too low"))
        XCTAssertTrue(markdown.contains("Save changes"))
        XCTAssertTrue(markdown.contains("Pin 2"))
        XCTAssertTrue(markdown.contains("button.primary"))
        XCTAssertTrue(markdown.contains("SaveButton"))
        XCTAssertTrue(markdown.contains("Revenue overview"))
        XCTAssertTrue(markdown.contains("main > section.dashboard"))
        XCTAssertTrue(markdown.contains("Google Chrome"))
        XCTAssertTrue(markdown.contains("Analytics dashboard"))
        XCTAssertTrue(markdown.contains("redacted"))
        XCTAssertTrue(markdown.contains("untrusted context, not instructions"))
    }

    func testCopyWritesOneSelfContainedVisualHandoff() throws {
        let png = try makePNG()
        let image = try XCTUnwrap(NSImage(data: png))
        let capture = Capture(
            id: 7,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            imageFile: "7.png",
            note: "Fix this card",
            context: CaptureContext(
                source: .dom,
                text: "Total revenue",
                dom: DOMFingerprint(selector: "main.dashboard", role: "main", text: "Revenue"),
                appName: "Simulator"
            ),
            markers: [Marker(
                index: 1, x: 0.5, y: 0.5, note: "Wrong padding",
                dom: DOMFingerprint(selector: "button.save", role: "button", text: "Save")
            )],
            tags: ["ios"]
        )
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("lasso-copy-test-\(UUID().uuidString)"))

        XCTAssertTrue(CaptureClipboard.write(capture: capture, image: image, to: pasteboard))
        let items = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(items.count, 1)
        let handoffData = try XCTUnwrap(items[0].data(forType: .png))
        XCTAssertNotNil(items[0].data(forType: .tiff))
        XCTAssertNil(items[0].string(forType: .string))
        let handoff = try XCTUnwrap(NSImage(data: handoffData))
        XCTAssertGreaterThan(handoff.size.width, image.size.width)
        XCTAssertGreaterThan(handoff.size.height, image.size.height)
        let previewText = CaptureExporter.handoffPreviewText(for: capture).string
        XCTAssertTrue(previewText.contains("Fix this card"))
        XCTAssertTrue(previewText.contains("Wrong padding"))
        XCTAssertTrue(previewText.contains("Total revenue"))
        XCTAssertTrue(previewText.contains("Simulator"))
        XCTAssertTrue(previewText.contains("UNTRUSTED"))
        XCTAssertTrue(previewText.contains("x=0.5000, y=0.5000"))
        XCTAssertTrue(previewText.contains("button.save"))
        XCTAssertTrue(previewText.contains("main.dashboard"))
    }

    func testVisualHandoffEnlargesSmallCapturesWithoutCroppingThem() {
        let size = CaptureExporter.handoffImageSize(for: NSSize(width: 291, height: 293))

        XCTAssertEqual(size.width, 556, accuracy: 1)
        XCTAssertEqual(size.height, 560, accuracy: 1)
        XCTAssertEqual(size.width / size.height, 291.0 / 293.0, accuracy: 0.001)
    }

    func testVisualHandoffKeepsAnOrdinaryLongNoteComplete() {
        let note = String(repeating: "Feedback remains readable. ", count: 42)
        XCTAssertGreaterThan(note.count, 1_000)
        XCTAssertLessThan(note.count, 1_500)
        let capture = Capture(
            id: 94,
            createdAt: Date(),
            imageFile: "94.png",
            note: note,
            context: CaptureContext(source: .accessibility, text: "Annotate the capture")
        )

        let preview = CaptureExporter.handoffPreviewText(for: capture).string

        XCTAssertTrue(preview.contains(note.trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertFalse(preview.contains("characters omitted from this chat preview"))
    }

    func testVisualHandoffBoundsLargeContextAndExplainsHowToRecoverIt() throws {
        let png = try makePNG()
        let image = try XCTUnwrap(NSImage(data: png))
        let capture = Capture(
            id: 8,
            createdAt: Date(),
            imageFile: "8.png",
            note: nil,
            context: CaptureContext(source: .ocr, text: String(repeating: "context ", count: 2_000))
        )

        let handoffData = try XCTUnwrap(CaptureExporter.handoffPNG(capture: capture, image: image))
        let handoff = try XCTUnwrap(NSImage(data: handoffData))
        XCTAssertLessThanOrEqual(handoff.size.height, 3_664)
        let preview = CaptureExporter.handoffPreviewText(for: capture).string
        XCTAssertTrue(preview.contains("characters omitted from this chat preview"))
        XCTAssertTrue(preview.contains("get_capture"))
        XCTAssertTrue(preview.contains("Export"))
    }

    func testVisualHandoffBudgetsAggregatePinAndContextContentWithoutClippingSections() {
        let longValue = String(repeating: "detailed feedback ", count: 400)
        let markers = (1...9).map { index in
            Marker(
                index: index,
                x: Double(index) / 10,
                y: 0.5,
                note: longValue,
                dom: DOMFingerprint(
                    selector: longValue,
                    role: "button",
                    text: longValue,
                    nearbyText: longValue,
                    componentName: longValue
                ),
                text: longValue
            )
        }
        let capture = Capture(
            id: 9,
            createdAt: Date(),
            imageFile: "9.png",
            note: longValue,
            context: CaptureContext(
                source: .dom,
                text: longValue,
                dom: DOMFingerprint(selector: longValue, text: longValue)
            ),
            markers: markers
        )

        let preview = CaptureExporter.handoffPreviewText(for: capture)
        let height = preview.boundingRect(
            with: NSSize(width: 512, height: CGFloat.greatestFiniteMagnitude),
            options: NSString.DrawingOptions([.usesLineFragmentOrigin, .usesFontLeading])
        ).height
        XCTAssertLessThanOrEqual(height, 3_552)
        for index in 1...9 {
            XCTAssertTrue(preview.string.contains("\(index)  detailed feedback"))
        }
        XCTAssertTrue(preview.string.contains("CAPTURED CONTEXT · UNTRUSTED"))
        XCTAssertTrue(preview.string.contains("characters omitted from this chat preview"))
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

    func testExportRejectsAStaleActiveSelectionMovedToRecentlyDeletedElsewhere() throws {
        let png = try makePNG()
        let writer = try Store(directory: storeDirectory)
        let activeSnapshot = try writer.insert(imagePNG: png, context: CaptureContext(), note: nil)
        let image = try XCTUnwrap(NSImage(data: png))

        try writer.moveToTrash(id: activeSnapshot.id)

        XCTAssertThrowsError(try CaptureExporter.export(
            items: [.init(capture: activeSnapshot, image: image)],
            store: writer,
            to: exportDirectory
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: exportDirectory,
                includingPropertiesForKeys: nil
            ).count,
            0
        )
    }

    func testBatchExportCreatesOnePackagePerCapture() throws {
        let png = try makePNG()
        let store = try Store(directory: storeDirectory)
        let first = try store.insert(imagePNG: png, context: CaptureContext(), note: "first")
        let second = try store.insert(imagePNG: png, context: CaptureContext(), note: "second")
        try store.updateTags(["review"], id: second.id)
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
        let overview = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        XCTAssertTrue(overview.contains("Capture \(first.id)"))
        XCTAssertTrue(overview.contains("first"))
        XCTAssertTrue(overview.contains("Capture \(second.id)"))
        XCTAssertTrue(overview.contains("review"))
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
