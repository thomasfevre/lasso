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

final class LibrarySettingsController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var retentionPopup: NSPopUpButton?
    private var hotkeySettings: HotkeySettingsRow?
    private weak var storagePath: NSTextField?
    private weak var clearRecentsButton: NSButton?
    private weak var emptyRecentlyDeletedButton: NSButton?
    private let activeHotkey: () -> HotkeyChord
    private let updateHotkey: (HotkeyChord) -> Bool
    private let hotkeyEditingChanged: (Bool) -> Void
    private let openHistory: () -> Void
    private let openExtensionSetup: () -> Void
    private let didChangeStorageLocation: () -> Void

    init(activeHotkey: @escaping () -> HotkeyChord,
         updateHotkey: @escaping (HotkeyChord) -> Bool,
         hotkeyEditingChanged: @escaping (Bool) -> Void = { _ in },
         openHistory: @escaping () -> Void = {},
         openExtensionSetup: @escaping () -> Void = {},
         didChangeStorageLocation: @escaping () -> Void = {}) {
        self.activeHotkey = activeHotkey
        self.updateHotkey = updateHotkey
        self.hotkeyEditingChanged = hotkeyEditingChanged
        self.openHistory = openHistory
        self.openExtensionSetup = openExtensionSetup
        self.didChangeStorageLocation = didChangeStorageLocation
        super.init()
    }

    func show() {
        if window == nil { build() }
        hotkeySettings?.setChord(activeHotkey())
        selectCurrentRetention()
        storagePath?.stringValue = Store.defaultDirectory().path
        refreshCleanupControls()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 700, height: 460)
        panel.delegate = self
        window = panel
        let backdrop = GlassBackdrop()
        panel.contentView = backdrop

        let wordmark = label("Lasso", font: .systemFont(ofSize: 12, weight: .semibold), color: Glass.faint)
        let title = label("Settings", font: Glass.Font.heading(), color: Glass.ink)
        let history = LassoButton("", symbolName: "clock.arrow.circlepath", accessibilityLabel: "Open capture history", kind: .plain) {
            [weak self] in
            self?.hotkeySettings?.cancelRecording()
            self?.window?.orderOut(nil)
            self?.openHistory()
        }
        let header = row([wordmark, title, spacer(), history])

        let captureTitle = label("CAPTURE", font: sectionFont(), color: Glass.faint)
        let shortcutSettings = HotkeySettingsRow(
            chord: activeHotkey(),
            showsCard: false,
            onChange: updateHotkey,
            onRecordingChanged: hotkeyEditingChanged
        )
        hotkeySettings = shortcutSettings
        let permissionLabel = wrappingLabel("Screen Recording: \(Permissions.hasScreenRecording ? "Allowed" : "Needs permission") · Accessibility: \(Permissions.hasAccessibility ? "Allowed" : "Optional")")
        permissionLabel.textColor = Permissions.hasScreenRecording ? Glass.okGreen : Glass.amberHi
        let captureCard = card([captureTitle, shortcutSettings, permissionLabel])

        let libraryTitle = label("LIBRARY", font: sectionFont(), color: Glass.faint)
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: LibraryPreferences.choices.map(\.title))
        popup.target = self
        popup.action = #selector(changeRetention)
        popup.translatesAutoresizingMaskIntoConstraints = false
        retentionPopup = popup
        let retentionRow = row([label("Remove after", font: Glass.Font.body(), color: Glass.ink), spacer(), popup])
        let storageTitle = label("Storage", font: Glass.Font.caption(), color: Glass.muted)
        let path = wrappingLabel(Store.defaultDirectory().path)
        path.font = Glass.Font.mono()
        path.textColor = Glass.muted
        storagePath = path
        let changeFolder = LassoButton("Change folder", kind: .plain) { [weak self] in self?.changeStorageLocation() }
        let storageRow = row([storageTitle, spacer(), changeFolder])
        let libraryCard = card([libraryTitle, retentionRow, storageRow, path])

        let columns = NSStackView(views: [captureCard, libraryCard])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = Glass.Space.md
        columns.translatesAutoresizingMaskIntoConstraints = false
        captureCard.widthAnchor.constraint(equalTo: libraryCard.widthAnchor).isActive = true

        let extensionTitle = label("BROWSER EXTENSION", font: sectionFont(), color: Glass.faint)
        let extensionBody = wrappingLabel("Add richer DOM context to captures from web pages.")
        extensionBody.textColor = Glass.muted
        let extensionSetup = LassoButton("Set up browser extension", kind: .secondary) { [weak self] in
            self?.openExtensionSetup()
        }
        let extensionCard = card([row([extensionTitle, spacer(), extensionSetup]), extensionBody])

        let clear = LassoButton("Clear Recents", kind: .secondary) { [weak self] in self?.clearRecents() }
        let emptyTrash = LassoButton("Empty Recently Deleted", kind: .destructive) { [weak self] in
            self?.emptyRecentlyDeleted()
        }
        clearRecentsButton = clear
        emptyRecentlyDeletedButton = emptyTrash
        let close = LassoButton("Done", kind: .primary) { [weak self] in self?.window?.close() }
        let footer = row([clear, emptyTrash, spacer(), close])

        let root = NSStackView(views: [header, columns, extensionCard, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = Glass.Space.md
        root.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 42),
            root.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: Glass.Space.lg),
            root.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -Glass.Space.lg),
            root.bottomAnchor.constraint(lessThanOrEqualTo: backdrop.bottomAnchor, constant: -Glass.Space.lg),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            columns.widthAnchor.constraint(equalTo: root.widthAnchor),
            extensionCard.widthAnchor.constraint(equalTo: root.widthAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
            shortcutSettings.widthAnchor.constraint(equalTo: captureCard.widthAnchor, constant: -Glass.Space.lg * 2),
        ])
    }

    func windowWillClose(_ notification: Notification) {
        hotkeySettings?.cancelRecording()
    }

    func windowDidResignKey(_ notification: Notification) {
        hotkeySettings?.cancelRecording()
    }

    @objc private func changeRetention() {
        guard let index = retentionPopup?.indexOfSelectedItem, LibraryPreferences.choices.indices.contains(index) else { return }
        LibraryPreferences.setRetention(LibraryPreferences.choices[index].duration)
        do {
            try Store(directory: Store.defaultDirectory(), retention: LibraryPreferences.retention).applyRetention()
            refreshCleanupControls()
        }
        catch { NSAlert(error: error).runModal() }
    }

    private func changeStorageLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose a parent folder. Lasso will create a private Lasso folder inside it."
        guard panel.runModal() == .OK, let parent = panel.url else { return }

        let source = Store.defaultDirectory()
        let destination = StoreLocationMigration.libraryDirectory(in: parent)
        guard source.standardizedFileURL != destination.standardizedFileURL else { return }

        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Move the Lasso library?"
        confirm.informativeText = "Existing captures, annotations and the local database will move to \(destination.path). Lasso will reconnect the browser relay and active MCP sessions automatically."
        confirm.addButton(withTitle: "Move Library")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        do {
            try StoreLocationMigration.moveLibrary(from: source, to: destination)
            StoreLocationPreference.setConfiguredDirectory(destination)
            storagePath?.stringValue = destination.path
            didChangeStorageLocation()
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func clearRecents() {
        do {
            let store = try Store(directory: Store.defaultDirectory(), retention: LibraryPreferences.retention)
            let recentCount = try store.count(in: .recent)
            guard recentCount > 0 else {
                refreshCleanupControls()
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Move \(recentCount) Recent \(captureNoun(recentCount)) to Recently Deleted?"
            alert.informativeText = "You can restore \(recentCount == 1 ? "it" : "them") from the library before the retention window ends."
            alert.addButton(withTitle: "Move \(recentCount) to Recently Deleted")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try store.clearRecent()
            refreshCleanupControls()
        }
        catch { NSAlert(error: error).runModal() }
    }

    private func emptyRecentlyDeleted() {
        do {
            let store = try Store(directory: Store.defaultDirectory(), retention: LibraryPreferences.retention)
            let deletedCount = try store.count(in: .recentlyDeleted)
            guard deletedCount > 0 else {
                refreshCleanupControls()
                return
            }
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Permanently delete \(deletedCount) Recently Deleted \(captureNoun(deletedCount))?"
            alert.informativeText = "This removes \(deletedCount == 1 ? "its image and annotations" : "their images and annotations") immediately. This action cannot be undone."
            alert.addButton(withTitle: "Delete \(deletedCount) Permanently")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            try store.emptyRecentlyDeleted()
            refreshCleanupControls()
        } catch {
            refreshCleanupControls()
            NSAlert(error: error).runModal()
        }
    }

    private func refreshCleanupControls() {
        do {
            let store = try Store(directory: Store.defaultDirectory(), retention: LibraryPreferences.retention)
            let recentCount = try store.count(in: .recent)
            let deletedCount = try store.count(in: .recentlyDeleted)
            clearRecentsButton?.title = "Clear Recents (\(recentCount))"
            clearRecentsButton?.isEnabled = recentCount > 0
            emptyRecentlyDeletedButton?.title = "Empty Recently Deleted (\(deletedCount))"
            emptyRecentlyDeletedButton?.isEnabled = deletedCount > 0
        } catch {
            clearRecentsButton?.title = "Clear Recents"
            emptyRecentlyDeletedButton?.title = "Empty Recently Deleted"
        }
    }

    private func captureNoun(_ count: Int) -> String {
        count == 1 ? "capture" : "captures"
    }

    private func selectCurrentRetention() {
        let current = LibraryPreferences.retention.duration
        let fallback = Retention.default.duration
        let index = LibraryPreferences.choices.firstIndex { $0.duration == current }
            ?? LibraryPreferences.choices.firstIndex { $0.duration == fallback }
            ?? 0
        retentionPopup?.selectItem(at: index)
    }

    private func card(_ views: [NSView]) -> GlassCard {
        let card = GlassCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        let content = NSStackView(views: views)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = Glass.Space.sm
        content.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: Glass.Space.md),
            content.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: Glass.Space.md),
            content.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -Glass.Space.md),
            content.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -Glass.Space.md),
        ])
        return card
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Glass.Space.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
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

    private func sectionFont() -> NSFont { .systemFont(ofSize: 10, weight: .semibold) }
}
#endif
