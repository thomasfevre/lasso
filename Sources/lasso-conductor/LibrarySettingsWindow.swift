#if os(macOS)
import AppKit
import LassoCore
import LassoConductorCore

/// User-owned library preferences. The retention setting intentionally applies
/// to both Recent and Recently Deleted so there is one understandable duration.
enum LibraryPreferences {
    private static let retentionKey = "LassoLibraryRetentionSeconds"
    static let choices: [(title: String, duration: RetentionDuration)] = [
        ("1 hour", .oneHour),
        ("1 day", .oneDay),
        ("7 days", .sevenDays),
        ("30 days", .thirtyDays),
        ("90 days", .ninetyDays),
    ]

    static var retention: Retention {
        let stored = UserDefaults.standard.double(forKey: retentionKey)
        let duration = stored > 0
            ? RetentionDuration.persisted(seconds: stored)
            : Retention.default.duration
        return Retention(maxCaptures: 100, duration: duration)
    }

    static func setRetention(_ duration: RetentionDuration) {
        UserDefaults.standard.set(duration.seconds, forKey: retentionKey)
    }
}

final class LibrarySettingsController: NSObject {
    private var window: NSWindow?
    private var retentionPopup: NSPopUpButton?
    private var hotkeySettings: HotkeySettingsRow?
    private let activeHotkey: () -> HotkeyChord
    private let updateHotkey: (HotkeyChord) -> Bool

    init(activeHotkey: @escaping () -> HotkeyChord,
         updateHotkey: @escaping (HotkeyChord) -> Bool) {
        self.activeHotkey = activeHotkey
        self.updateHotkey = updateHotkey
        super.init()
    }

    func show() {
        if window == nil { build() }
        hotkeySettings?.setChord(activeHotkey())
        selectCurrentRetention()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 470),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        window = panel
        let backdrop = GlassBackdrop()
        panel.contentView = backdrop

        let wordmark = label("Lasso", font: .systemFont(ofSize: 12, weight: .semibold), color: Glass.faint)
        let title = label("Settings", font: Glass.Font.title(), color: Glass.ink)
        let captureTitle = label("CAPTURE", font: .systemFont(ofSize: 10, weight: .semibold), color: Glass.faint)
        let shortcutSettings = HotkeySettingsRow(chord: activeHotkey(), onChange: updateHotkey)
        hotkeySettings = shortcutSettings
        let permissionLabel = wrappingLabel("Screen Recording: \(Permissions.hasScreenRecording ? "Allowed" : "Needs permission") · Accessibility: \(Permissions.hasAccessibility ? "Allowed" : "Optional")")
        permissionLabel.textColor = Permissions.hasScreenRecording ? Glass.okGreen : Glass.amberHi
        let libraryTitle = label("LIBRARY", font: .systemFont(ofSize: 10, weight: .semibold), color: Glass.faint)
        let explanation = wrappingLabel("Recent captures and Recently Deleted items are removed after this duration. Kept captures stay until you delete them.")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: LibraryPreferences.choices.map(\.title))
        popup.target = self
        popup.action = #selector(changeRetention)
        popup.translatesAutoresizingMaskIntoConstraints = false
        retentionPopup = popup
        let row = NSStackView(views: [label("Remove after", font: Glass.Font.body(), color: Glass.ink), spacer(), popup])
        row.orientation = .horizontal; row.alignment = .centerY; row.translatesAutoresizingMaskIntoConstraints = false

        let pathTitle = label("STORAGE", font: .systemFont(ofSize: 10, weight: .semibold), color: Glass.faint)
        let path = wrappingLabel(Store.defaultDirectory().path)
        path.font = Glass.Font.mono(); path.textColor = Glass.muted
        let clear = LassoButton("Clear Recents…", kind: .secondary) { [weak self] in self?.clearRecents() }
        let emptyTrash = LassoButton("Empty Recently Deleted…", kind: .secondary) {
            [weak self] in self?.emptyRecentlyDeleted()
        }
        let close = LassoButton("Done", kind: .primary) { [weak self] in self?.window?.close() }
        let footer = NSStackView(views: [clear, emptyTrash, spacer(), close])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.translatesAutoresizingMaskIntoConstraints = false
        let root = NSStackView(views: [wordmark, title, captureTitle, shortcutSettings, permissionLabel, libraryTitle, explanation, row, pathTitle, path, footer])
        root.orientation = .vertical; root.alignment = .leading; root.spacing = Glass.Space.md; root.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 42),
            root.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: Glass.Space.lg),
            root.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -Glass.Space.lg),
            root.bottomAnchor.constraint(lessThanOrEqualTo: backdrop.bottomAnchor, constant: -Glass.Space.lg),
            shortcutSettings.widthAnchor.constraint(equalTo: root.widthAnchor),
            explanation.widthAnchor.constraint(equalTo: root.widthAnchor), path.widthAnchor.constraint(equalTo: root.widthAnchor),
            row.widthAnchor.constraint(equalTo: root.widthAnchor), footer.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
    }

    @objc private func changeRetention() {
        guard let index = retentionPopup?.indexOfSelectedItem, LibraryPreferences.choices.indices.contains(index) else { return }
        LibraryPreferences.setRetention(LibraryPreferences.choices[index].duration)
        do { try Store(directory: Store.defaultDirectory(), retention: LibraryPreferences.retention).applyRetention() }
        catch { NSAlert(error: error).runModal() }
    }

    private func clearRecents() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move all Recent captures to Recently Deleted?"
        alert.informativeText = "You can restore them from the library before the retention window ends."
        alert.addButton(withTitle: "Move to Recently Deleted")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try Store(directory: Store.defaultDirectory(), retention: LibraryPreferences.retention).clearRecent() }
        catch { NSAlert(error: error).runModal() }
    }

    private func emptyRecentlyDeleted() {
        do {
            let store = try Store(
                directory: Store.defaultDirectory(),
                retention: LibraryPreferences.retention
            )
            guard !(try store.captures(in: .recentlyDeleted, limit: 1)).isEmpty else {
                let empty = NSAlert()
                empty.messageText = "Recently Deleted is empty"
                empty.informativeText = "There are no captures to permanently delete."
                empty.runModal()
                return
            }

            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Permanently delete all Recently Deleted captures?"
            alert.informativeText = "This removes their images and annotations immediately. This action cannot be undone."
            alert.addButton(withTitle: "Delete Permanently")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try store.emptyRecentlyDeleted()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func selectCurrentRetention() {
        let current = LibraryPreferences.retention.duration
        let fallback = Retention.default.duration
        let index = LibraryPreferences.choices.firstIndex { $0.duration == current }
            ?? LibraryPreferences.choices.firstIndex { $0.duration == fallback }
            ?? 0
        retentionPopup?.selectItem(at: index)
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font; field.textColor = color; field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func wrappingLabel(_ text: String) -> NSTextField {
        let field = label(text, font: Glass.Font.body(), color: Glass.ink)
        field.maximumNumberOfLines = 0; field.lineBreakMode = .byWordWrapping
        return field
    }

    private func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view
    }
}
#endif
