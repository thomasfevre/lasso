#if os(macOS)
import AppKit
import Carbon.HIToolbox
import LassoConductorCore

enum GlobalHotkeyRegistrationError: LocalizedError {
    case missingKey
    case handler(OSStatus)
    case registration(OSStatus, HotkeyChord)

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "The shortcut does not contain a key."
        case .handler(let status):
            return "Lasso could not install its keyboard handler (error \(status))."
        case .registration(let status, let chord):
            return "macOS rejected \(chord.description) (error \(status)). It may already be used by another app."
        }
    }
}

/// A single app-wide hotkey via Carbon `RegisterEventHotKey`. Chosen over an
/// `NSEvent` global monitor / `CGEventTap` because it needs no Accessibility
/// permission and fires regardless of which app is focused. The C event handler
/// cannot capture context, so `self` is threaded through `userData`.
final class GlobalHotkey {
    private let onFire: () -> Void
    private let hotKeyID: EventHotKeyID
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(chord: HotkeyChord, onFire: @escaping () -> Void) throws {
        guard let keyCode = chord.keyCode else {
            throw GlobalHotkeyRegistrationError.missingKey
        }
        self.onFire = onFire
        // Multiple registrations briefly coexist while a replacement is being
        // attempted. Give each one its own ID and filter events so the old and
        // new callbacks cannot both fire during that transactional handoff.
        hotKeyID = EventHotKeyID(
            signature: OSType(0x4C41_5353),
            id: UInt32.random(in: 1...UInt32.max))

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }
                let instance = Unmanaged<GlobalHotkey>
                    .fromOpaque(userData).takeUnretainedValue()
                var eventID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &eventID)
                guard status == noErr,
                      eventID.signature == instance.hotKeyID.signature,
                      eventID.id == instance.hotKeyID.id else { return noErr }
                instance.onFire()
                return noErr
            },
            1, &spec, selfPtr, &handlerRef)
        guard installStatus == noErr else {
            throw GlobalHotkeyRegistrationError.handler(installStatus)
        }

        let registerStatus = RegisterEventHotKey(keyCode, chord.modifiers.carbonValue, hotKeyID,
                                                 GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            self.handlerRef = nil
            throw GlobalHotkeyRegistrationError.registration(registerStatus, chord)
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

private extension HotkeyModifiers {
    var carbonValue: UInt32 {
        var value: UInt32 = 0
        if contains(.command) { value |= UInt32(cmdKey) }
        if contains(.option) { value |= UInt32(optionKey) }
        if contains(.control) { value |= UInt32(controlKey) }
        if contains(.shift) { value |= UInt32(shiftKey) }
        return value
    }
}
#endif
