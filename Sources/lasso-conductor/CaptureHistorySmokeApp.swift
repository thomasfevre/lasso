#if os(macOS) && DEBUG
import AppKit
import LassoCore
import LassoConductorCore

/// Debug-only visual harness for the real onboarding screens used by the site.
/// Set `LASSO_UI_SMOKE_ONBOARDING` to `welcome` or `permissions`.
final class OnboardingSmokeApp: NSObject, NSApplicationDelegate {
    static let environmentKey = "LASSO_UI_SMOKE_ONBOARDING"
    private static let outputPrefix = "LASSO_UI_SMOKE_ONBOARDING"

    private let screen: String
    private var onboarding: OnboardingController?

    init(screen: String) {
        self.screen = screen
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let onboarding = OnboardingController(
            relay: nil,
            activeHotkey: { .defaultCapture },
            updateHotkey: { _ in true }
        )
        self.onboarding = onboarding
        onboarding.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.prepareScreen()
        }
    }

    private func prepareScreen() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let content = window.contentView else {
            fail("Onboarding window did not open")
        }
        switch screen {
        case "welcome":
            capture(content)
        case "permissions":
            guard let start = descendants(of: NSButton.self, in: content)
                .first(where: { $0.title == "Set up Lasso" }) else {
                fail("Welcome screen did not render its setup action")
            }
            start.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak content] in
                guard let self, let content else { return }
                self.capture(content)
            }
        default:
            fail("Unsupported onboarding screen: \(screen)")
        }
    }

    private func capture(_ content: NSView) {
        if let error = SmokeScreenshot.writeIfRequested(of: content) { fail(error) }
        FileHandle.standardError.write(Data("\(Self.outputPrefix): PASS (\(screen))\n".utf8))
        exit(0)
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        let current = (root as? T).map { [$0] } ?? []
        return current + root.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(Self.outputPrefix): FAIL: \(message)\n".utf8))
        exit(1)
    }
}

/// Debug-only, process-level smoke test for the History double-click path.
/// Enabled with `LASSO_UI_SMOKE_DOUBLE_CLICK=1`; never compiled into Release.
final class CaptureHistorySmokeApp: NSObject, NSApplicationDelegate {
    static let environmentKey = "LASSO_UI_SMOKE_DOUBLE_CLICK"
    static let detailScreenshotEnvironmentKey = "LASSO_UI_SMOKE_DETAIL_SCREENSHOT"
    static let missingImageEnvironmentKey = "LASSO_UI_SMOKE_MISSING_IMAGE"
    private static let outputPrefix = "LASSO_UI_SMOKE_DOUBLE_CLICK"

    private let detail = CaptureDetailController()
    private var history: CaptureHistoryController?
    private var didRequestSettings = false
    private var didRequestExtensionSetup = false
    private var didRequestCapture = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment[Self.missingImageEnvironmentKey] == "1" {
            prepareMissingImageFixture()
        }
        let history = CaptureHistoryController(
            detail: detail,
            openSettings: { [weak self] in self?.didRequestSettings = true },
            openExtensionSetup: { [weak self] in self?.didRequestExtensionSetup = true },
            startCapture: { [weak self] in self?.didRequestCapture = true })
        self.history = history
        history.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.dispatchDoubleClick()
        }
    }

    private func prepareMissingImageFixture() {
        do {
            let store = try Store(directory: Store.defaultDirectory(), access: .reader)
            guard let capture = try store.recent(limit: 2).first else {
                fail("Missing-image smoke requires a seeded capture")
            }
            try FileManager.default.removeItem(
                at: Store.defaultDirectory().appendingPathComponent(capture.imageFile)
            )
        } catch {
            fail("Could not prepare missing-image fixture: \(error)")
        }
    }

    private func dispatchDoubleClick() {
        guard let historyWindow = NSApp.windows.first(where: { $0.title == "Capture History" }),
              let collection = descendant(of: NSCollectionView.self, in: historyWindow.contentView),
              collection.numberOfSections > 0,
              collection.numberOfItems(inSection: 0) >= 2,
              let first = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)),
              let second = collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)) else {
            fail("History did not render two collection items")
        }
        guard let stateFilter = descendants(of: NSPopUpButton.self, in: historyWindow.contentView)
            .first(where: { $0.itemTitles.contains(where: { $0.hasPrefix("Recents (") }) }),
              stateFilter.itemTitles.contains("Recents (2)"),
              stateFilter.itemTitles.contains("Recently Deleted (0)") else {
            fail("History state filter is missing category counts")
        }
        if let error = SmokeScreenshot.writeIfRequested(of: historyWindow.contentView) { fail(error) }
        let firstPoint = collection.convert(NSPoint(x: first.frame.midX, y: first.frame.midY), to: nil)
        let secondPoint = collection.convert(NSPoint(x: second.frame.midX, y: second.frame.midY), to: nil)
        sendClick(to: historyWindow, point: firstPoint, modifiers: [], clickCount: 1, eventNumber: 1)
        sendClick(to: historyWindow, point: secondPoint, modifiers: [.command], clickCount: 1, eventNumber: 2)
        let actions = descendants(of: NSButton.self, in: historyWindow.contentView)
        let utilityIcons = actions.filter {
            ["Share selected captures", "Set up browser extension", "Open settings"].contains($0.toolTip ?? "")
        }
        let shareEnabled = utilityIcons.first(where: { $0.toolTip == "Share selected captures" })?.isEnabled == true
        let exportEnabled = actions.first(where: { $0.title == "Export" })?.isEnabled == true
        guard collection.selectionIndexPaths.count == 2,
              shareEnabled,
              exportEnabled,
              utilityIcons.count == 3,
              utilityIcons.allSatisfy({ abs($0.bounds.width - 36) < 0.01 && abs($0.bounds.height - 36) < 0.01 }) else {
            fail("Selection=\(collection.selectionIndexPaths), Share=\(shareEnabled), Export=\(exportEnabled)")
        }
        let thumbnails = descendants(of: CaptureGridItemView.self, in: historyWindow.contentView)
        guard thumbnails.count >= 2,
              thumbnails.allSatisfy({ $0.isAccessibilityElement() && $0.accessibilityRole() == .button }),
              thumbnails.allSatisfy({ ($0.accessibilityLabel() ?? "").hasPrefix("Capture ") }) else {
            fail("History thumbnails are missing accessible button labels")
        }
        if ProcessInfo.processInfo.environment[Self.missingImageEnvironmentKey] == "1",
           !thumbnails.contains(where: { ($0.accessibilityLabel() ?? "").contains("image unavailable") }) {
            fail("History did not preserve the capture whose image is unavailable")
        }
        let lastItemMaxX = max(first.frame.maxX, second.frame.maxX)
        let blankPointInCollection = NSPoint(
            x: min(collection.bounds.maxX - 20, lastItemMaxX + 40),
            y: first.frame.midY
        )
        guard !first.frame.contains(blankPointInCollection),
              !second.frame.contains(blankPointInCollection) else {
            fail("Could not find blank History space for deselection smoke")
        }
        let blankPoint = collection.convert(blankPointInCollection, to: nil)
        sendClick(to: historyWindow, point: blankPoint, modifiers: [], clickCount: 1, eventNumber: 3)
        guard collection.selectionIndexPaths.isEmpty,
              utilityIcons.first(where: { $0.toolTip == "Share selected captures" })?.isEnabled == false,
              actions.first(where: { $0.title == "Export" })?.isEnabled == false else {
            fail("Share or Export remained enabled after clicking empty History space")
        }
        sendClick(to: historyWindow, point: firstPoint, modifiers: [], clickCount: 1, eventNumber: 4)
        sendClick(to: historyWindow, point: firstPoint, modifiers: [.command], clickCount: 1, eventNumber: 5)
        guard collection.selectionIndexPaths.isEmpty,
              utilityIcons.first(where: { $0.toolTip == "Share selected captures" })?.isEnabled == false,
              actions.first(where: { $0.title == "Export" })?.isEnabled == false else {
            fail("Share or Export remained enabled after Command-click deselection")
        }
        sendClick(to: historyWindow, point: firstPoint, modifiers: [], clickCount: 1, eventNumber: 6)
        guard let settings = actions.first(where: { $0.toolTip == "Open settings" }) else {
            fail("History did not render an Open settings icon")
        }
        settings.performClick(nil)
        guard didRequestSettings else {
            fail("Open settings icon did not invoke its action")
        }
        guard let extensionSetup = actions.first(where: { $0.toolTip == "Set up browser extension" }) else {
            fail("History did not render a browser extension setup icon")
        }
        extensionSetup.performClick(nil)
        guard didRequestExtensionSetup else {
            fail("Browser extension setup icon did not invoke its action")
        }
        let existingWindows = Set(NSApp.windows.map(\.windowNumber))
        sendClick(to: historyWindow, point: firstPoint, modifiers: [], clickCount: 2, eventNumber: 7)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let detailWindow = NSApp.windows.first(where: {
                $0.isVisible &&
                !existingWindows.contains($0.windowNumber) &&
                $0.title.hasPrefix("Capture ") &&
                Int($0.title.dropFirst("Capture ".count)) != nil
            }) else {
                self.fail("Double-click did not create a visible Capture detail; windows=\(NSApp.windows.map(\.title))")
            }
            let expectedIconLabels = Set([
                "Newer capture",
                "Older capture",
                "Move to Recently Deleted",
                "Close",
            ])
            let iconButtons = self.descendants(of: NSButton.self, in: detailWindow.contentView)
                .filter { expectedIconLabels.contains($0.toolTip ?? "") }
            let nonCircularFrames = iconButtons.map(\.bounds).filter {
                abs($0.width - 36) > 0.01 || abs($0.height - 36) > 0.01
            }
            let trashIsRed = iconButtons
                .first(where: { $0.toolTip == "Move to Recently Deleted" })?
                .contentTintColor?
                .usingColorSpace(.deviceRGB)
                .map { $0.redComponent > $0.greenComponent && $0.redComponent > $0.blueComponent } == true
            guard iconButtons.count == expectedIconLabels.count, nonCircularFrames.isEmpty, trashIsRed else {
                self.fail("Icon buttons are not 36 x 36: \(iconButtons.map(\.bounds))")
            }
            guard let copyButton = self.descendants(of: NSButton.self, in: detailWindow.contentView)
                .first(where: { $0.title == "Copy" }) else {
                self.fail("Capture detail is missing its Copy action")
            }
            let expectsMissingImage = ProcessInfo.processInfo.environment[Self.missingImageEnvironmentKey] == "1"
            guard copyButton.isEnabled != expectsMissingImage else {
                self.fail("Copy action did not reflect image availability")
            }
            if let error = SmokeScreenshot.writeIfRequested(
                of: detailWindow.contentView,
                environmentKey: Self.detailScreenshotEnvironmentKey
            ) { self.fail(error) }
            self.detail.dismissForNewCapture()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if NSApp.windows.contains(where: {
                    $0.isVisible &&
                    $0.title.hasPrefix("Capture ") &&
                    Int($0.title.dropFirst("Capture ".count)) != nil
                }) {
                    self.fail("Capture detail remained visible after a new capture began; windows=\(NSApp.windows.map(\.title))")
                }
                self.verifyEmptyState()
            }
        }
    }

    private func verifyEmptyState() {
        let environment = ProcessInfo.processInfo.environment
        guard let override = environment["LASSO_STORE_DIR"], !override.isEmpty else {
            fail("Empty-state smoke requires a temporary LASSO_STORE_DIR")
        }
        let candidatePath = URL(fileURLWithPath: override)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let temporaryPath = FileManager.default.temporaryDirectory
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard candidatePath.hasPrefix(temporaryPath + "/") else {
            fail("Empty-state smoke requires a temporary LASSO_STORE_DIR")
        }
        do {
            let store = try Store(directory: Store.defaultDirectory())
            try store.clearRecent()
        } catch {
            fail("Could not prepare empty History state: \(error)")
        }
        history?.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard let historyWindow = NSApp.windows.first(where: { $0.title == "Capture History" }),
                  let content = historyWindow.contentView else {
                self.fail("History did not reopen for empty-state verification")
            }
            let buttons = self.descendants(of: NSButton.self, in: content)
            let labels = self.descendants(of: NSTextField.self, in: content).map(\.stringValue)
            guard let capture = buttons.first(where: { $0.title == "Capture a region" }),
                  labels.contains("No captures yet") else {
                self.fail("History did not render its useful empty state")
            }
            capture.performClick(nil)
            guard self.didRequestCapture else {
                self.fail("Empty-state capture action did not invoke its callback")
            }
            FileHandle.standardError.write(Data("\(Self.outputPrefix): PASS\n".utf8))
            exit(0)
        }
    }

    private func sendClick(to window: NSWindow, point: NSPoint, modifiers: NSEvent.ModifierFlags,
                           clickCount: Int, eventNumber: Int) {
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: clickCount,
            pressure: 0
        ) else {
            fail("Could not create a click event")
        }
        window.sendEvent(event)
    }

    private func descendant<T: NSView>(of type: T.Type, in root: NSView?) -> T? {
        guard let root else { return nil }
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: type, in: child) { return match }
        }
        return nil
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        return (root as? T).map { [$0] } ?? [] + root.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(Self.outputPrefix): FAIL: \(message)\n".utf8))
        exit(1)
    }
}

/// Debug-only visual harness for the Settings layout. It keeps the real window
/// open so native UI automation can inspect the rendered controls.
final class LibrarySettingsSmokeApp: NSObject, NSApplicationDelegate {
    static let environmentKey = "LASSO_UI_SMOKE_SETTINGS"
    static let screenshotEnvironmentKey = "LASSO_UI_SMOKE_SCREENSHOT"
    private static let outputPrefix = "LASSO_UI_SMOKE_SETTINGS"

    private var settings: LibrarySettingsController?
    private var didRequestHistory = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = LibrarySettingsController(
            activeHotkey: { .defaultCapture },
            updateHotkey: { _ in true },
            openHistory: { [weak self] in self?.didRequestHistory = true }
        )
        self.settings = settings
        settings.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let content = window.contentView else {
                self.fail("Settings window did not open")
            }
            let buttons = self.descendants(of: NSButton.self, in: content)
            let expectedPrefixes = ["Clear Recents (", "Empty Recently Deleted (", "Set up browser extension", "Done"]
            guard expectedPrefixes.allSatisfy({ prefix in buttons.contains(where: { $0.title.hasPrefix(prefix) }) }) else {
                self.fail("Missing cleanup controls: \(buttons.map(\.title))")
            }
            let frames = buttons
                .filter { button in expectedPrefixes.contains(where: { button.title.hasPrefix($0) }) }
                .map { $0.convert($0.bounds, to: content) }
            guard frames.allSatisfy({ content.bounds.contains($0) }),
                  !frames.indices.contains(where: { index in
                      frames.indices.contains(where: { other in
                          other > index && frames[index].intersects(frames[other])
                      })
                  }) else {
                self.fail("Cleanup controls overlap or escape the window: \(frames)")
            }
            if let error = SmokeScreenshot.writeIfRequested(of: content) { self.fail(error) }
            guard let back = buttons.first(where: { $0.toolTip == "Open capture history" }) else {
                self.fail("Settings did not render a capture-history control")
            }
            back.performClick(nil)
            guard self.didRequestHistory else {
                self.fail("Back to History did not invoke its action")
            }
            FileHandle.standardError.write(Data("\(Self.outputPrefix): READY\n".utf8))
        }
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        let current = (root as? T).map { [$0] } ?? []
        return current + root.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(Self.outputPrefix): FAIL: \(message)\n".utf8))
        exit(1)
    }
}

/// Debug-only process smoke for shortcut editing. It sends the currently active
/// chord through the real AppKit recorder and verifies the global registration
/// is reported suspended before the candidate reaches the update callback.
final class ShortcutSettingsSmokeApp: NSObject, NSApplicationDelegate {
    static let environmentKey = "LASSO_UI_SMOKE_SHORTCUT"
    private static let outputPrefix = "LASSO_UI_SMOKE_SHORTCUT"

    private var settings: LibrarySettingsController?
    private var globalShortcutEnabled = true
    private var transitions: [Bool] = []
    private var receivedChord: HotkeyChord?
    private var focusTransferWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = LibrarySettingsController(
            activeHotkey: { .defaultCapture },
            updateHotkey: { [weak self] chord in
                guard let self else { return false }
                guard !globalShortcutEnabled else {
                    fail("The global shortcut was still enabled while recording")
                }
                receivedChord = chord
                return true
            },
            hotkeyEditingChanged: { [weak self] editing in
                guard let self else { return }
                transitions.append(editing)
                globalShortcutEnabled = !editing
            })
        self.settings = settings
        settings.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.exerciseRecorder()
        }
    }

    private func exerciseRecorder() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let content = window.contentView,
              let recorder = descendants(of: NSControl.self, in: content).first(where: {
                  String(describing: type(of: $0)) == "HotkeyRecorder"
              }) else {
            fail("Shortcut recorder was not found")
        }

        let point = recorder.convert(NSPoint(x: recorder.bounds.midX, y: recorder.bounds.midY), to: nil)
        guard let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0) else {
            fail("Could not create shortcut cancellation input")
        }
        window.sendEvent(click)
        guard transitions == [true], !globalShortcutEnabled else {
            fail("Shortcut did not suspend before closing: \(transitions)")
        }
        window.close()
        guard transitions == [true, false], globalShortcutEnabled else {
            fail("Closing Settings did not restore the shortcut: \(transitions)")
        }

        settings?.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.exerciseAcceptedChord()
        }
    }

    private func exerciseAcceptedChord() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let content = window.contentView,
              let recorder = descendants(of: NSControl.self, in: content).first(where: {
                  String(describing: type(of: $0)) == "HotkeyRecorder"
              }) else {
            fail("Shortcut recorder was not found after reopening Settings")
        }
        let point = recorder.convert(NSPoint(x: recorder.bounds.midX, y: recorder.bounds.midY), to: nil)
        guard let click = NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0),
              let key = NSEvent.keyEvent(
                with: .keyDown, location: point, modifierFlags: [.control, .option],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ",
                isARepeat: false, keyCode: 49) else {
            fail("Could not create shortcut input events")
        }
        window.sendEvent(click)
        window.sendEvent(key)

        guard transitions == [true, false, true, false],
              receivedChord == .defaultCapture,
              globalShortcutEnabled else {
            fail("transitions=\(transitions), chord=\(String(describing: receivedChord)), enabled=\(globalShortcutEnabled)")
        }

        window.sendEvent(click)
        guard transitions == [true, false, true, false, true], !globalShortcutEnabled else {
            fail("Shortcut did not suspend before focus transfer: \(transitions)")
        }
        let focusTransferWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        self.focusTransferWindow = focusTransferWindow
        focusTransferWindow.makeKeyAndOrderFront(nil)
        window.resignKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            guard transitions == [true, false, true, false, true, false],
                  globalShortcutEnabled else {
                fail("Losing window focus did not restore the shortcut: \(transitions)")
            }
            FileHandle.standardError.write(Data("\(Self.outputPrefix): PASS\n".utf8))
            exit(0)
        }
    }

    private func descendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
        let current = (root as? T).map { [$0] } ?? []
        return current + root.subviews.flatMap { descendants(of: type, in: $0) }
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(Self.outputPrefix): FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private enum SmokeScreenshot {
    static func writeIfRequested(
        of view: NSView?,
        environmentKey: String = LibrarySettingsSmokeApp.screenshotEnvironmentKey
    ) -> String? {
        guard let view,
              let path = ProcessInfo.processInfo.environment[environmentKey],
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            return "Could not encode UI smoke screenshot"
        }
        do {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            return nil
        } catch {
            return "Could not write UI smoke screenshot: \(error)"
        }
    }
}
#endif
