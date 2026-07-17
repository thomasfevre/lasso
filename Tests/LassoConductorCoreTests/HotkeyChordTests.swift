import XCTest
@testable import LassoConductorCore

final class HotkeyChordTests: XCTestCase {
    func testDefaultChordIsOptionSpace() {
        XCTAssertEqual(HotkeyChord.defaultCapture.description, "⌥Space")
        XCTAssertNil(HotkeyChord.defaultCapture.validationError)
    }

    func testFunctionKeyAloneIsValid() {
        // F6 (key code 97) needs no modifier — a one-press global trigger.
        let chord = HotkeyChord(keyCode: 97, modifiers: [])

        XCTAssertNil(chord.validationError)
        XCTAssertEqual(chord.description, "F6")
    }

    func testNonFunctionBareKeyStillNeedsModifier() {
        // A letter on its own would hijack typing, so it stays rejected.
        let chord = HotkeyChord(keyCode: 1, modifiers: [])

        XCTAssertEqual(chord.validationError, .missingModifier)
    }

    func testDescriptionUsesStableModifierOrderAndReadableKeyNames() {
        let chord = HotkeyChord(
            keyCode: 0,
            modifiers: [.command, .shift, .option, .control])

        XCTAssertEqual(chord.description, "⌃⌥⇧⌘A")
    }

    func testMissingKeyIsRejected() {
        let chord = HotkeyChord(keyCode: nil, modifiers: [.control])

        XCTAssertEqual(chord.validationError, .missingKey)
    }

    func testBareKeyIsRejected() {
        let chord = HotkeyChord(keyCode: 0, modifiers: [])

        XCTAssertEqual(chord.validationError, .missingModifier)
    }

    func testModifierOnlyChordIsRejected() {
        // 59 is the macOS virtual key code for the left Control key.
        let chord = HotkeyChord(keyCode: 59, modifiers: [.control])

        XCTAssertEqual(chord.validationError, .modifierOnly)
    }

    func testUnknownModifierBitsAreRejected() {
        let chord = HotkeyChord(
            keyCode: 0,
            modifiers: HotkeyModifiers(rawValue: 1 << 12))

        XCTAssertEqual(chord.validationError, .unsupportedModifiers)
    }

    func testCommandTabIsRejectedAsSystemReserved() {
        let chord = HotkeyChord(keyCode: 48, modifiers: [.command])

        XCTAssertEqual(chord.validationError, .systemReserved("⌘Tab"))
    }

    func testCommandSpaceIsRejectedAsSystemReserved() {
        let chord = HotkeyChord(keyCode: 49, modifiers: [.command])

        XCTAssertEqual(chord.validationError, .systemReserved("⌘Space"))
    }

    func testOrdinaryModifiedKeyIsValid() {
        let chord = HotkeyChord(keyCode: 1, modifiers: [.control, .shift])

        XCTAssertNil(chord.validationError)
        XCTAssertEqual(chord.description, "⌃⇧S")
    }
}
