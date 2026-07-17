#if os(macOS)
import Foundation
import LassoConductorCore

enum HotkeyPreferences {
    private static let keyCodeKey = "LassoCaptureHotkeyKeyCode"
    private static let modifiersKey = "LassoCaptureHotkeyModifiers"

    static func load(from defaults: UserDefaults = .standard) -> HotkeyChord? {
        guard let keyCode = defaults.object(forKey: keyCodeKey) as? NSNumber,
              let modifiers = defaults.object(forKey: modifiersKey) as? NSNumber else {
            return nil
        }
        let chord = HotkeyChord(
            keyCode: keyCode.uint32Value,
            modifiers: HotkeyModifiers(rawValue: modifiers.uint32Value))
        return chord.validationError == nil ? chord : nil
    }

    static func save(_ chord: HotkeyChord, to defaults: UserDefaults = .standard) {
        guard let keyCode = chord.keyCode else { return }
        defaults.set(NSNumber(value: keyCode), forKey: keyCodeKey)
        defaults.set(NSNumber(value: chord.modifiers.rawValue), forKey: modifiersKey)
    }
}
#endif
