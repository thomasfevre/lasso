// lasso-conductor (SPE-545): the macOS Conductor. An always-on menu-bar agent
// that, on a global hotkey, shows a full-screen Overlay, captures the region the
// user drags over (the Gesture), and writes an annotated screenshot to the Store
// via LassoCore. OCR / Accessibility context is SPE-546; here the context source
// is `none`. All AppKit / ScreenCaptureKit code is macOS-only; on Linux this
// executable is a stub so the package keeps building there.
#if os(macOS)
import AppKit

let app = NSApplication.shared
#if DEBUG
if ProcessInfo.processInfo.environment[CaptureHistorySmokeApp.environmentKey] == "1" {
    let smoke = CaptureHistorySmokeApp()
    app.delegate = smoke
    app.setActivationPolicy(.regular)
    app.run()
    exit(0)
}
if ProcessInfo.processInfo.environment[LibrarySettingsSmokeApp.environmentKey] == "1" {
    let smoke = LibrarySettingsSmokeApp()
    app.delegate = smoke
    app.setActivationPolicy(.regular)
    app.run()
    exit(0)
}
#endif
let conductor = ConductorApp()
app.delegate = conductor
// Accessory: no Dock icon, no menu bar app menu. Lasso lives in the status bar.
app.setActivationPolicy(.accessory)
app.run()
#else
import Foundation

FileHandle.standardError.write(Data("lasso-conductor is macOS-only\n".utf8))
exit(1)
#endif
