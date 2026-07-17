import XCTest
@testable import LassoCore

// SPE-557: the clipboard prompt stub is a pure string builder, so its wording and
// note handling are unit-tested here (NSPasteboard/NSSound wiring is not).
final class CapturePromptTests: XCTestCase {
    func testStubWithNote() {
        XCTAssertEqual(CapturePrompt.clipboardStub(id: 42, note: "the save button"),
                       "Check the latest Lasso capture (id 42): the save button")
    }

    func testStubWithoutNote() {
        XCTAssertEqual(CapturePrompt.clipboardStub(id: 7, note: nil),
                       "Check the latest Lasso capture (id 7).")
    }

    func testBlankNoteTreatedAsAbsent() {
        XCTAssertEqual(CapturePrompt.clipboardStub(id: 3, note: "   \n "),
                       "Check the latest Lasso capture (id 3).")
    }

    func testNoteIsTrimmed() {
        XCTAssertEqual(CapturePrompt.clipboardStub(id: 5, note: "  hello  "),
                       "Check the latest Lasso capture (id 5): hello")
    }
}
