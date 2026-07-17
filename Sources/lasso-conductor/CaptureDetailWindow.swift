#if os(macOS)
import AppKit
import LassoCore
import LassoConductorCore

/// Read-only inspector for a persisted Capture. It intentionally has no editing
/// affordances: a Capture is the immutable record created at annotation time.
final class CaptureDetailController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var canvas: CapturePreviewCanvas?
    private var titleLabel: NSTextField?
    private var subtitleLabel: NSTextField?
    private var noteLabel: NSTextField?
    private var pinStack: NSStackView?
    private var contextStack: NSStackView?
    private var contextButton: NSButton?
    private var tagsLabel: NSTextField?
    private var newerButton: LassoButton?
    private var olderButton: LassoButton?
    private var keepButton: LassoButton?
    private var trashButton: LassoButton?

    private var capturesByID: [Int64: Capture] = [:]
    private var timeline = CaptureTimeline(idsNewestFirst: [])
    private var currentID: Int64?
    private var contextExpanded = false

    func showLatest() {
        do {
            let store = try Store(directory: Store.defaultDirectory(), access: .reader)
            let captures = try store.recent(limit: 100)
            guard let latest = captures.first else {
                showNoCapturesAlert()
                return
            }
            capturesByID = CaptureDetailIndex.make(captures)
            timeline = CaptureTimeline(idsNewestFirst: captures.map(\.id))
            try show(captureID: latest.id, store: store)
        } catch {
            showError(error)
        }
    }

    func show(captureID: Int64) {
        do {
            let store = try Store(directory: Store.defaultDirectory(), access: .reader)
            let active = try store.recent(limit: 100)
            guard let selected = try store.capture(id: captureID) else { return }
            let captures = active + (try store.captures(in: .recentlyDeleted, limit: 1_000)) + [selected]
            capturesByID = CaptureDetailIndex.make(captures)
            // Deleted items can be opened only for restore/erase. They never
            // enter the active detail navigation timeline.
            timeline = CaptureTimeline(idsNewestFirst: active.map(\.id))
            try show(captureID: captureID, store: store)
        } catch {
            showError(error)
        }
    }

    private func show(captureID: Int64, store: Store) throws {
        guard let capture = capturesByID[captureID] else { return }
        guard let image = NSImage(data: try store.imageData(for: capture)) else {
            throw StoreError.imageRead("could not decode capture image")
        }
        if window == nil { buildWindow() }
        currentID = captureID
        render(capture, image: image)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Window

    private func buildWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1_060, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "Capture"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 760, height: 540)
        panel.delegate = self
        window = panel

        let backdrop = GlassBackdrop()
        panel.contentView = backdrop

        let wordmark = label("Lasso", font: .systemFont(ofSize: 12, weight: .semibold), color: Glass.faint)
        let title = label("", font: Glass.Font.title(), color: Glass.ink)
        titleLabel = title
        let subtitle = label("", font: Glass.Font.caption(), color: Glass.muted)
        subtitleLabel = subtitle
        let titleStack = stack([wordmark, title, subtitle], orientation: .vertical, spacing: Glass.Space.xs)

        let newer = LassoButton("", symbolName: "chevron.left", accessibilityLabel: "Newer capture",
                                kind: .secondary) { [weak self] in self?.navigateNewer() }
        let older = LassoButton("", symbolName: "chevron.right", accessibilityLabel: "Older capture",
                                kind: .secondary) { [weak self] in self?.navigateOlder() }
        let keep = LassoButton("Keep", kind: .secondary) { [weak self] in self?.toggleKeep() }
        keepButton = keep
        let trash = LassoButton("Move to Recently Deleted", kind: .plain) { [weak self] in self?.moveToTrash() }
        trashButton = trash
        newerButton = newer
        olderButton = older
        let close = LassoButton("", symbolName: "xmark", accessibilityLabel: "Close",
                               kind: .plain) { [weak self] in self?.window?.close() }
        let headerSpacer = flexibleSpacer()
        let header = stack([titleStack, headerSpacer, newer, older, keep, trash, close], orientation: .horizontal, spacing: Glass.Space.sm)
        header.alignment = .centerY

        let preview = CapturePreviewCanvas()
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.wantsLayer = true
        preview.layer?.cornerRadius = Glass.Radius.sm
        preview.layer?.cornerCurve = .continuous
        preview.layer?.masksToBounds = true
        preview.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 330).isActive = true
        canvas = preview
        let previewCard = GlassCard()
        previewCard.translatesAutoresizingMaskIntoConstraints = false
        previewCard.contentView.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: previewCard.contentView.topAnchor, constant: Glass.Space.sm),
            preview.bottomAnchor.constraint(equalTo: previewCard.contentView.bottomAnchor, constant: -Glass.Space.sm),
            preview.leadingAnchor.constraint(equalTo: previewCard.contentView.leadingAnchor, constant: Glass.Space.sm),
            preview.trailingAnchor.constraint(equalTo: previewCard.contentView.trailingAnchor, constant: -Glass.Space.sm),
        ])

        let noteHeader = label("CAPTURE NOTE", font: .systemFont(ofSize: 10, weight: .semibold), color: Glass.faint)
        let note = wrappingLabel("")
        noteLabel = note
        let tagsHeader = label("TAGS", font: .systemFont(ofSize: 10, weight: .semibold), color: Glass.faint)
        let tags = wrappingLabel("")
        tagsLabel = tags
        let editTags = LassoButton("Edit tags…", kind: .plain) { [weak self] in self?.editTags() }
        let tagsRow = stack([tags, editTags], orientation: .horizontal, spacing: Glass.Space.sm)
        tagsRow.alignment = .centerY
        let pinsHeader = label("PINS", font: .systemFont(ofSize: 10, weight: .semibold), color: Glass.faint)
        let pins = stack([], orientation: .vertical, spacing: Glass.Space.sm)
        pinStack = pins
        let contextHeader = NSButton(title: "Context", target: self, action: #selector(toggleContext))
        contextHeader.isBordered = false
        contextHeader.font = .systemFont(ofSize: 12, weight: .semibold)
        contextHeader.contentTintColor = Glass.muted
        contextHeader.alignment = .left
        contextHeader.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Toggle context")
        contextHeader.imagePosition = .imageTrailing
        contextHeader.imageScaling = .scaleProportionallyDown
        contextButton = contextHeader
        let context = stack([], orientation: .vertical, spacing: Glass.Space.xs)
        contextStack = context

        let inspectorRoot = stack([noteHeader, note, tagsHeader, tagsRow, pinsHeader, pins, contextHeader, context],
                                  orientation: .vertical, spacing: Glass.Space.sm)
        inspectorRoot.alignment = .leading
        let inspectorCard = GlassCard()
        inspectorCard.translatesAutoresizingMaskIntoConstraints = false
        inspectorCard.widthAnchor.constraint(equalToConstant: 276).isActive = true
        inspectorCard.contentView.addSubview(inspectorRoot)
        inspectorRoot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inspectorRoot.topAnchor.constraint(equalTo: inspectorCard.contentView.topAnchor, constant: Glass.Space.md),
            inspectorRoot.leadingAnchor.constraint(equalTo: inspectorCard.contentView.leadingAnchor, constant: Glass.Space.md),
            inspectorRoot.trailingAnchor.constraint(equalTo: inspectorCard.contentView.trailingAnchor, constant: -Glass.Space.md),
            inspectorRoot.bottomAnchor.constraint(lessThanOrEqualTo: inspectorCard.contentView.bottomAnchor, constant: -Glass.Space.md),
            note.widthAnchor.constraint(equalTo: inspectorRoot.widthAnchor),
            tagsRow.widthAnchor.constraint(equalTo: inspectorRoot.widthAnchor),
            pins.widthAnchor.constraint(equalTo: inspectorRoot.widthAnchor),
            context.widthAnchor.constraint(equalTo: inspectorRoot.widthAnchor),
        ])

        let body = stack([previewCard, inspectorCard], orientation: .horizontal, spacing: Glass.Space.md)
        body.alignment = .top
        previewCard.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewCard.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let root = stack([header, body], orientation: .vertical, spacing: Glass.Space.md)
        root.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 42),
            root.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: Glass.Space.lg),
            root.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -Glass.Space.lg),
            root.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -Glass.Space.lg),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            body.widthAnchor.constraint(equalTo: root.widthAnchor),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
    }

    // MARK: - Rendering

    private func render(_ capture: Capture, image: NSImage) {
        titleLabel?.stringValue = "Capture \(capture.id)"
        subtitleLabel?.stringValue = subtitle(for: capture)
        window?.title = "Capture \(capture.id)"
        canvas?.image = image
        canvas?.markers = capture.markers
        noteLabel?.stringValue = capture.note?.isEmpty == false ? capture.note! : "No note on this capture."
        noteLabel?.textColor = capture.note?.isEmpty == false ? Glass.ink : Glass.faint
        tagsLabel?.stringValue = capture.tags.isEmpty ? "No tags" : capture.tags.joined(separator: " · ")
        tagsLabel?.textColor = capture.tags.isEmpty ? Glass.faint : Glass.amberHi
        renderPins(capture.markers)
        renderContext(capture.context)
        contextStack?.isHidden = !contextExpanded
        contextButton?.image = NSImage(
            systemSymbolName: contextExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: "Toggle context"
        )
        let canNavigate = capture.libraryState != .recentlyDeleted
        newerButton?.isEnabled = canNavigate && timeline.newer(than: capture.id) != nil
        olderButton?.isEnabled = canNavigate && timeline.older(than: capture.id) != nil
        keepButton?.title = capture.libraryState == .kept ? "Unkeep" : "Keep"
        keepButton?.selected = capture.libraryState == .kept
        keepButton?.isHidden = capture.libraryState == .recentlyDeleted
        trashButton?.title = capture.libraryState == .recentlyDeleted ? "Restore / Erase…" : "Move to Recently Deleted"
    }

    private func renderPins(_ markers: [Marker]) {
        guard let pinStack else { return }
        pinStack.arrangedSubviews.forEach { pinStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        if markers.isEmpty {
            pinStack.addArrangedSubview(label("No pins on this capture.", font: Glass.Font.body(), color: Glass.faint))
            return
        }
        for marker in markers.sorted(by: { $0.index < $1.index }) {
            let number = PinBadgeView(index: marker.index)
            let text = wrappingLabel(marker.note?.isEmpty == false ? marker.note! : "Pin \(marker.index)")
            text.textColor = marker.note?.isEmpty == false ? Glass.ink : Glass.faint
            let row = stack([number, text], orientation: .horizontal, spacing: Glass.Space.sm)
            row.alignment = .centerY
            pinStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: pinStack.widthAnchor).isActive = true
        }
    }

    private func renderContext(_ context: CaptureContext) {
        guard let contextStack else { return }
        contextStack.arrangedSubviews.forEach { contextStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let entries: [(String, String?)] = [
            ("App", context.appName),
            ("Window", context.windowTitle),
            ("Source", context.source.rawValue),
        ]
        for (key, value) in entries where value?.isEmpty == false {
            let keyLabel = label(key, font: .systemFont(ofSize: 11, weight: .semibold), color: Glass.faint)
            let valueLabel = wrappingLabel(value!)
            valueLabel.font = Glass.Font.caption()
            let row = stack([keyLabel, valueLabel], orientation: .horizontal, spacing: Glass.Space.sm)
            row.alignment = .firstBaseline
            contextStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: contextStack.widthAnchor).isActive = true
            keyLabel.widthAnchor.constraint(equalToConstant: 52).isActive = true
        }
        if contextStack.arrangedSubviews.isEmpty {
            contextStack.addArrangedSubview(label("No contextual metadata.", font: Glass.Font.caption(), color: Glass.faint))
        }
    }

    @objc private func toggleContext() {
        contextExpanded.toggle()
        contextStack?.isHidden = !contextExpanded
        contextButton?.image = NSImage(
            systemSymbolName: contextExpanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: "Toggle context"
        )
    }

    private func navigateNewer() { navigate { $0.newer(than: $1) } }
    private func navigateOlder() { navigate { $0.older(than: $1) } }

    private func navigate(_ destination: (CaptureTimeline, Int64) -> Int64?) {
        guard let currentID, let destinationID = destination(timeline, currentID) else { return }
        do {
            let store = try Store(directory: Store.defaultDirectory(), access: .reader)
            try show(captureID: destinationID, store: store)
        } catch {
            showError(error)
        }
    }

    private func toggleKeep() {
        guard let currentID, let capture = capturesByID[currentID] else { return }
        do {
            let store = try Store(directory: Store.defaultDirectory(), retention: LibraryPreferences.retention)
            try store.setKept(capture.libraryState != .kept, id: currentID)
            show(captureID: currentID)
        } catch { showError(error) }
    }

    private func moveToTrash() {
        guard let currentID, let capture = capturesByID[currentID] else { return }
        if capture.libraryState == .recentlyDeleted {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Recently Deleted"
            alert.informativeText = "Restore this capture, or permanently erase it now."
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Erase Permanently")
            alert.addButton(withTitle: "Cancel")
            let result = alert.runModal()
            do {
                let store = try Store(directory: Store.defaultDirectory(), retention: LibraryPreferences.retention)
                if result == .alertFirstButtonReturn { try store.restore(id: currentID) }
                else if result == .alertSecondButtonReturn { try store.permanentlyErase(id: currentID) }
                else { return }
                window?.close()
            } catch { showError(error) }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move this capture to Recently Deleted?"
        alert.informativeText = "You can restore it before the retention window ends."
        alert.addButton(withTitle: "Move to Recently Deleted")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let store = try Store(directory: Store.defaultDirectory(), retention: LibraryPreferences.retention)
            try store.moveToTrash(id: currentID)
            let undo = NSAlert()
            undo.messageText = "Moved to Recently Deleted"
            undo.informativeText = "You can restore this capture until the retention window ends."
            undo.addButton(withTitle: "Undo")
            undo.addButton(withTitle: "Done")
            if undo.runModal() == .alertFirstButtonReturn {
                try store.restore(id: currentID)
                show(captureID: currentID)
            } else {
                window?.close()
            }
        } catch { showError(error) }
    }

    private func editTags() {
        guard let currentID, let capture = capturesByID[currentID] else { return }
        let alert = NSAlert()
        alert.messageText = "Edit tags"
        alert.informativeText = "Separate tags with commas."
        let field = NSTextField(string: capture.tags.joined(separator: ", "))
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let tags = field.stringValue.split(separator: ",").map { String($0) }
        do {
            let store = try Store(directory: Store.defaultDirectory(), retention: LibraryPreferences.retention)
            try store.updateTags(tags, id: currentID)
            show(captureID: currentID)
        } catch { showError(error) }
    }

    // MARK: - Small UI helpers

    private func subtitle(for capture: Capture) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let pinText = capture.markers.count == 1 ? "1 pin" : "\(capture.markers.count) pins"
        return "\(formatter.string(from: capture.createdAt)) · \(pinText)"
    }

    private func label(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func wrappingLabel(_ string: String) -> NSTextField {
        let field = label(string, font: Glass.Font.body(), color: Glass.ink)
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byWordWrapping
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return field
    }

    private func stack(_ views: [NSView], orientation: NSUserInterfaceLayoutOrientation,
                       spacing: CGFloat) -> NSStackView {
        let result = NSStackView(views: views)
        result.orientation = orientation
        result.alignment = .leading
        result.spacing = spacing
        result.translatesAutoresizingMaskIntoConstraints = false
        return result
    }

    private func flexibleSpacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    private func showNoCapturesAlert() {
        let alert = NSAlert()
        alert.messageText = "No captures yet"
        alert.informativeText = "Capture something first, then Lasso can show it here."
        alert.runModal()
    }

    private func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}

private final class PinBadgeView: NSView {
    private let index: Int

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        PinBadgeRenderer.draw(index: index, in: bounds, shadow: false)
    }
}

/// Draws an unmodified screenshot with its persisted pins. It has no event
/// handlers by design: viewing a capture must never mutate the saved record.
private final class CapturePreviewCanvas: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var markers: [Marker] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()
        guard let image else { return }
        let imageRect = aspectFit(image.size, in: bounds.insetBy(dx: 2, dy: 2))
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
        for marker in markers.sorted(by: { $0.index < $1.index }) {
            let center = PinBadgeRenderer.center(for: marker, in: imageRect)
            PinBadgeRenderer.draw(
                index: marker.index,
                in: PinBadgeRenderer.rect(
                    centeredAt: center,
                    diameter: PinBadgeRenderer.detailDiameter
                ),
                shadow: true
            )
        }
    }

    private func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}
#endif
