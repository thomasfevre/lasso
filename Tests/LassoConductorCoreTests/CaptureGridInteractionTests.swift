#if os(macOS)
import AppKit
import XCTest
@testable import LassoConductorCore

final class CaptureGridInteractionTests: XCTestCase {
    func testClickThenCommandClickBuildsAMultiSelection() {
        let first = IndexPath(item: 0, section: 0)
        let second = IndexPath(item: 1, section: 0)

        let initial = CaptureGridInteraction.resolve(current: [], clicked: first, modifiers: [], clickCount: 1)
        let extended = CaptureGridInteraction.resolve(
            current: initial.selection,
            clicked: second,
            modifiers: [.command],
            clickCount: 1
        )

        XCTAssertEqual(extended.selection, [first, second])
        XCTAssertNil(extended.openItem)
    }

    func testCommandClickTogglesAnExistingSelection() {
        let first = IndexPath(item: 0, section: 0)
        let second = IndexPath(item: 1, section: 0)

        let result = CaptureGridInteraction.resolve(
            current: [first, second],
            clicked: first,
            modifiers: [.command],
            clickCount: 1
        )

        XCTAssertEqual(result.selection, [second])
    }

    func testCommandClickCanDeselectTheLastSelectedCapture() {
        let first = IndexPath(item: 0, section: 0)

        let result = CaptureGridInteraction.resolve(
            current: [first],
            clicked: first,
            modifiers: [.command],
            clickCount: 1
        )

        XCTAssertTrue(result.selection.isEmpty)
        XCTAssertNil(result.openItem)
    }

    func testDoubleClickOpensItemWithoutDestroyingItsBatchSelection() {
        let first = IndexPath(item: 0, section: 0)
        let second = IndexPath(item: 1, section: 0)

        let result = CaptureGridInteraction.resolve(
            current: [first, second],
            clicked: second,
            modifiers: [],
            clickCount: 2
        )

        XCTAssertEqual(result.selection, [first, second])
        XCTAssertEqual(result.openItem, second)
    }

    func testWindowDispatchDeliversClickMetadataToThumbnail() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = CaptureGridItemView(frame: window.contentView!.bounds)
        var received: (NSEvent.ModifierFlags, Int)?
        view.onClick = { received = ($0, $1) }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 100, y: 80),
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 2,
            pressure: 0
        ))

        window.sendEvent(event)

        XCTAssertTrue(received?.0.contains(.command) == true)
        XCTAssertEqual(received?.1, 2)
    }

    func testThumbnailAcceptsTheFirstClickThatActivatesAnAccessoryApp() {
        XCTAssertTrue(CaptureGridItemView().acceptsFirstMouse(for: nil))
    }
}
#endif
