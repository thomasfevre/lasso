import Foundation

/// AppKit-free modifier flags used by a capture shortcut. Their raw values are
/// deliberately Lasso-owned rather than Carbon/NSEvent values so the model can
/// be persisted and tested on every platform.
public struct HotkeyModifiers: OptionSet, Sendable, Equatable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let command = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let control = HotkeyModifiers(rawValue: 1 << 2)
    public static let shift = HotkeyModifiers(rawValue: 1 << 3)
    public static let supported: HotkeyModifiers = [.command, .option, .control, .shift]

    public var description: String {
        var value = ""
        if contains(.control) { value += "⌃" }
        if contains(.option) { value += "⌥" }
        if contains(.shift) { value += "⇧" }
        if contains(.command) { value += "⌘" }
        return value
    }
}

public enum HotkeyValidationError: Error, Sendable, Equatable {
    case missingKey
    case missingModifier
    case modifierOnly
    case unsupportedModifiers
    case systemReserved(String)

    public var message: String {
        switch self {
        case .missingKey, .modifierOnly:
            return "Press a non-modifier key together with at least one modifier."
        case .missingModifier:
            return "Include at least one modifier: Control, Option, Shift, or Command."
        case .unsupportedModifiers:
            return "The shortcut contains unsupported modifier keys."
        case .systemReserved(let shortcut):
            return "\(shortcut) is reserved by macOS. Choose another shortcut."
        }
    }
}

/// A macOS keyboard chord expressed only in stable primitive values. `keyCode`
/// is the hardware-independent virtual key code supplied by NSEvent/Carbon; it
/// is optional so the empty and modifier-only recorder states remain explicit.
public struct HotkeyChord: Sendable, Equatable, CustomStringConvertible {
    public var keyCode: UInt32?
    public var modifiers: HotkeyModifiers

    public init(keyCode: UInt32?, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Control-Option-Space avoids Finder's Option-Space Quick Look shortcut
    /// while remaining easy to trigger with one hand.
    public static let defaultCapture = HotkeyChord(
        keyCode: 49,
        modifiers: [.control, .option])

    public var validationError: HotkeyValidationError? {
        guard let keyCode else { return .missingKey }
        guard !Self.modifierKeyCodes.contains(keyCode) else { return .modifierOnly }
        // A function key (F1–F16) is allowed on its own — it is safe as a global
        // one-press trigger because it is not part of normal typing. Every other
        // key still needs a modifier so it doesn't hijack ordinary input.
        guard !modifiers.isEmpty || Self.functionKeyCodes.contains(keyCode) else {
            return .missingModifier
        }
        guard modifiers.rawValue & ~HotkeyModifiers.supported.rawValue == 0 else {
            return .unsupportedModifiers
        }

        if keyCode == 48, modifiers == [.command] {
            return .systemReserved(description)
        }
        if keyCode == 49, modifiers == [.command] {
            return .systemReserved(description)
        }
        // Finder uses Option-Space for Quick Look. Carbon registration can appear
        // to succeed, but Finder wins the event and Lasso never enters capture
        // mode, which makes the shortcut feel flaky rather than unavailable.
        if keyCode == 49, modifiers == [.option] {
            return .systemReserved(description)
        }
        return nil
    }

    public var description: String {
        guard let keyCode else { return modifiers.description }
        return modifiers.description + Self.keyName(for: keyCode)
    }

    private static let modifierKeyCodes: Set<UInt32> = [
        54, 55, // Command
        56, 60, // Shift
        57,     // Caps Lock
        58, 61, // Option
        59, 62, // Control
        63,     // Function
    ]

    /// F1–F16 virtual key codes. These may stand alone as a capture shortcut.
    private static let functionKeyCodes: Set<UInt32> = [
        122, 120, 99, 118, 96, 97, 98, 100, // F1–F8
        101, 109, 103, 111, 105, 107, 113, 106, // F9–F16
    ]

    /// Names for the virtual key codes emitted by macOS keyboards. Unknown
    /// codes remain readable instead of producing an empty menu label.
    private static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 22: return "6"
        case 23: return "5"
        case 24: return "="
        case 25: return "9"
        case 26: return "7"
        case 27: return "-"
        case 28: return "8"
        case 29: return "0"
        case 30: return "]"
        case 31: return "O"
        case 32: return "U"
        case 33: return "["
        case 34: return "I"
        case 35: return "P"
        case 36: return "Return"
        case 37: return "L"
        case 38: return "J"
        case 39: return "'"
        case 40: return "K"
        case 41: return ";"
        case 42: return "\\"
        case 43: return ","
        case 44: return "/"
        case 45: return "N"
        case 46: return "M"
        case 47: return "."
        case 48: return "Tab"
        case 49: return "Space"
        case 50: return "`"
        case 51: return "Delete"
        case 53: return "Escape"
        case 65: return "."
        case 67: return "*"
        case 69: return "+"
        case 71: return "Clear"
        case 75: return "/"
        case 76: return "Enter"
        case 78: return "-"
        case 81: return "="
        case 82: return "0"
        case 83: return "1"
        case 84: return "2"
        case 85: return "3"
        case 86: return "4"
        case 87: return "5"
        case 88: return "6"
        case 89: return "7"
        case 91: return "8"
        case 92: return "9"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 99: return "F3"
        case 100: return "F8"
        case 101: return "F9"
        case 103: return "F11"
        case 105: return "F13"
        case 106: return "F16"
        case 107: return "F14"
        case 109: return "F10"
        case 111: return "F12"
        case 113: return "F15"
        case 114: return "Help"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "Forward Delete"
        case 118: return "F4"
        case 119: return "End"
        case 120: return "F2"
        case 121: return "Page Down"
        case 122: return "F1"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key \(keyCode)"
        }
    }
}
