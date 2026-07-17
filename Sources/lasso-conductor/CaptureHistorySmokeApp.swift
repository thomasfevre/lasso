#if os(macOS) && DEBUG
import AppKit
import LassoConductorCore

/// Debug-only, process-level smoke test for the History double-click path.
/// Enabled with `LASSO_UI_SMOKE_DOUBLE_CLICK=1`; never compiled into Release.
final class CaptureHistorySmokeApp: NSObject, NSApplicationDelegate {
    static let environmentKey = "LASSO_UI_SMOKE_DOUBLE_CLICK"
    private static let outputPrefix = "LASSO_UI_SMOKE_DOUBLE_CLICK"

    private let detail = CaptureDetailController()
    private var history: CaptureHistoryController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let history = CaptureHistoryController(detail: detail)
        self.history = history
        history.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.dispatchDoubleClick()
        }
    }

    private func dispatchDoubleClick() {
        guard let historyWindow = NSApp.windows.first(where: { $0.title == "Capture History" }),
              let collection = descendant(of: NSCollectionView.self, in: historyWindow.contentView),
              let first = collection.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)),
              let second = collection.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)) else {
            fail("History did not render two collection items")
        }
        let firstPoint = collection.convert(NSPoint(x: first.frame.midX, y: first.frame.midY), to: nil)
        let secondPoint = collection.convert(NSPoint(x: second.frame.midX, y: second.frame.midY), to: nil)
        sendClick(to: historyWindow, point: firstPoint, modifiers: [], clickCount: 1, eventNumber: 1)
        sendClick(to: historyWindow, point: secondPoint, modifiers: [.command], clickCount: 1, eventNumber: 2)
        let actions = descendants(of: NSButton.self, in: historyWindow.contentView)
        let shareEnabled = actions.first(where: { $0.title == "Share" })?.isEnabled == true
        let exportEnabled = actions.first(where: { $0.title == "Export" })?.isEnabled == true
        guard collection.selectionIndexPaths.count == 2,
              shareEnabled,
              exportEnabled else {
            fail("Selection=\(collection.selectionIndexPaths), Share=\(shareEnabled), Export=\(exportEnabled)")
        }
        let existingWindows = Set(NSApp.windows.map(\.windowNumber))
        sendClick(to: historyWindow, point: firstPoint, modifiers: [], clickCount: 2, eventNumber: 3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if NSApp.windows.contains(where: {
                $0.isVisible &&
                !existingWindows.contains($0.windowNumber) &&
                $0.title.hasPrefix("Capture ") &&
                Int($0.title.dropFirst("Capture ".count)) != nil
            }) {
                FileHandle.standardError.write(Data("\(Self.outputPrefix): PASS\n".utf8))
                exit(0)
            }
            self.fail("Double-click did not create a visible Capture detail; windows=\(NSApp.windows.map(\.title))")
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
    private static let outputPrefix = "LASSO_UI_SMOKE_SETTINGS"

    private var settings: LibrarySettingsController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = LibrarySettingsController(
            activeHotkey: { .defaultCapture },
            updateHotkey: { _ in true }
        )
        self.settings = settings
        settings.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }),
                  let content = window.contentView else {
                self.fail("Settings window did not open")
            }
            let buttons = self.descendants(of: NSButton.self, in: content)
            let expected = ["Clear Recents…", "Empty Recently Deleted…", "Done"]
            guard expected.allSatisfy({ title in buttons.contains(where: { $0.title == title }) }) else {
                self.fail("Missing cleanup controls: \(buttons.map(\.title))")
            }
            let frames = buttons
                .filter { expected.contains($0.title) }
                .map { $0.convert($0.bounds, to: content) }
            guard frames.allSatisfy({ content.bounds.contains($0) }),
                  !frames.indices.contains(where: { index in
                      frames.indices.contains(where: { other in
                          other > index && frames[index].intersects(frames[other])
                      })
                  }) else {
                self.fail("Cleanup controls overlap or escape the window: \(frames)")
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
#endif
