#if os(macOS)
import AppKit
import CoreGraphics
import ApplicationServices

/// Screen Recording (TCC) permission handling. The Conductor cannot capture
/// without it, so we request it up front and give the user a one-click path to
/// the exact Settings pane if it is missing (macOS only prompts once, so after a
/// refusal the deep link is the only way back).
enum Permissions {
    /// True if Screen Recording is already granted. Does not prompt.
    static var hasScreenRecording: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system prompt the first time; afterwards returns the current
    /// state without re-prompting. Call once at launch.
    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Opens System Settings directly on Privacy & Security > Screen Recording.
    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Accessibility (SPE-546)

    /// True if the Accessibility (AX) grant is present. The AX Region Context path
    /// degrades to OCR-only without it, so this is best-effort, not required.
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system Accessibility prompt once if not yet granted. Safe to call
    /// at launch; macOS only surfaces the prompt a single time.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Opens System Settings directly on Privacy & Security > Accessibility.
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
#endif
