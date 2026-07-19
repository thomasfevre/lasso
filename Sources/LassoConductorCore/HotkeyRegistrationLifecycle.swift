/// Tracks whether the app-wide capture shortcut is registered while a shortcut
/// recorder owns the keyboard. The recorder must release the Carbon hotkey
/// before listening so entering the current chord does not start a capture.
public struct HotkeyRegistrationLifecycle: Sendable {
    public private(set) var hasRegistration: Bool
    private var editingDepth = 0
    public var isEditing: Bool { editingDepth > 0 }
    /// A candidate can be registered while its sole recorder handles the key
    /// event. With two recorders, installing would reactivate the Carbon hotkey
    /// underneath the other active field, so the candidate must stay pending.
    public var installationAllowed: Bool { editingDepth <= 1 }

    public init(hasRegistration: Bool) {
        self.hasRegistration = hasRegistration
    }

    /// Returns true when the caller should release its global registration.
    @discardableResult
    public mutating func beginEditing() -> Bool {
        editingDepth += 1
        guard editingDepth == 1 else { return false }
        let shouldSuspend = hasRegistration
        hasRegistration = false
        return shouldSuspend
    }

    public func needsInstallation(candidate: HotkeyChord, active: HotkeyChord) -> Bool {
        candidate != active || !hasRegistration
    }

    public mutating func didInstall() {
        precondition(installationAllowed, "global hotkey cannot be installed while a recorder is active")
        hasRegistration = true
    }

    /// Returns true when editing ended without a successful replacement and the
    /// caller must restore the previously active shortcut.
    public mutating func endEditingNeedsRestore() -> Bool {
        guard editingDepth > 0 else { return false }
        editingDepth -= 1
        return editingDepth == 0 && !hasRegistration
    }
}
