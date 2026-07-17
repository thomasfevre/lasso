#if os(macOS)
import AppKit
import LassoCore
import LassoConductorCore

/// A native, Photos-inspired overview of the local Capture library. Captures
/// remain immutable here; selecting one opens the read-only detail inspector.
final class CaptureHistoryController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private enum ExportAction { case save, share }
    private struct Item {
        let capture: Capture
        let image: NSImage
    }
    private struct DayGroup {
        let date: Date
        let items: [Item]
    }

    private var window: NSWindow?
    private var collection: NSCollectionView?
    private var countLabel: NSTextField?
    private var zoomSlider: NSSlider?
    private var statePopup: NSPopUpButton?
    private var tagPopup: NSPopUpButton?
    private var searchField: NSSearchField?
    private var shareButton: LassoButton?
    private var exportButton: LassoButton?
    private var dayGroups: [DayGroup] = []
    private let detail: CaptureDetailController

    init(detail: CaptureDetailController) {
        self.detail = detail
        super.init()
    }

    func show() {
        if window == nil { buildWindow() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private var selectedState: CaptureLibraryState? {
        switch statePopup?.indexOfSelectedItem {
        case 1: return .recent
        case 2: return .kept
        case 3: return .recentlyDeleted
        default: return nil
        }
    }

    private var selectedTag: String? {
        guard let title = tagPopup?.titleOfSelectedItem, title != "All tags" else { return nil }
        return title
    }

    private func reload() {
        do {
            let store = try Store(directory: Store.defaultDirectory(), access: .reader)
            let availableTags = try store.activeTags()
            if let tagPopup {
                let previous = tagPopup.titleOfSelectedItem
                tagPopup.removeAllItems()
                tagPopup.addItems(withTitles: ["All tags"] + availableTags)
                if let previous, tagPopup.itemTitles.contains(previous) { tagPopup.selectItem(withTitle: previous) }
            }
            let captures = try store.searchCaptures(query: searchField?.stringValue ?? "", state: selectedState, tag: selectedTag)
            let items: [Item] = try captures.compactMap { capture in
                guard let image = NSImage(data: try store.imageData(for: capture)) else { return nil }
                return Item(capture: capture, image: image)
            }
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.capture.id, $0) })
            dayGroups = CaptureDayGrouping.grouped(captures).map { group in
                DayGroup(date: group.day, items: group.captureIDs.compactMap { byID[$0] })
            }
            countLabel?.stringValue = countDescription(items.count)
            collection?.reloadData()
            collection?.selectionIndexPaths = []
            updateActionButtons()
            applyZoom()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func buildWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = "Capture History"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.minSize = NSSize(width: 620, height: 460)
        window = panel

        let backdrop = GlassBackdrop()
        panel.contentView = backdrop
        let wordmark = label("Lasso", font: .systemFont(ofSize: 12, weight: .semibold), color: Glass.faint)
        let title = label("Capture history", font: Glass.Font.title(), color: Glass.ink)
        let count = label("", font: Glass.Font.caption(), color: Glass.muted)
        countLabel = count
        let titleStack = stack([wordmark, title, count], orientation: .vertical, spacing: Glass.Space.xs)

        let zoomOut = label("−", font: .systemFont(ofSize: 16, weight: .medium), color: Glass.muted)
        let zoomIn = label("+", font: .systemFont(ofSize: 16, weight: .medium), color: Glass.muted)
        let state = NSPopUpButton(frame: .zero, pullsDown: false)
        state.addItems(withTitles: ["All active", "Recents", "Kept", "Recently Deleted"])
        state.target = self
        state.action = #selector(changeFilter)
        statePopup = state
        let tag = NSPopUpButton(frame: .zero, pullsDown: false)
        tag.addItem(withTitle: "All tags")
        tag.target = self
        tag.action = #selector(changeFilter)
        tagPopup = tag
        let search = NSSearchField()
        search.placeholderString = "Search captures"
        search.target = self
        search.action = #selector(changeFilter)
        search.translatesAutoresizingMaskIntoConstraints = false
        search.widthAnchor.constraint(equalToConstant: 190).isActive = true
        searchField = search
        let slider = NSSlider(value: 174, minValue: 120, maxValue: 286, target: self, action: #selector(changeZoom))
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        zoomSlider = slider
        let close = LassoButton("Close", kind: .plain) { [weak self] in self?.window?.close() }
        let share = LassoButton("Share", kind: .secondary) { [weak self] in self?.exportSelection(.share) }
        let export = LassoButton("Export", kind: .primary) { [weak self] in self?.exportSelection(.save) }
        shareButton = share
        exportButton = export
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = stack([titleStack, headerSpacer, state, tag, search, zoomOut, slider, zoomIn, share, export, close], orientation: .horizontal, spacing: Glass.Space.sm)
        header.alignment = .centerY

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Glass.Space.sm
        layout.minimumLineSpacing = Glass.Space.sm
        layout.headerReferenceSize = NSSize(width: 1, height: 28)
        let collection = NSCollectionView()
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.delegate = self
        collection.dataSource = self
        collection.register(CaptureThumbnailItem.self, forItemWithIdentifier: CaptureThumbnailItem.identifier)
        collection.register(CaptureDayHeader.self,
                            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: CaptureDayHeader.identifier)
        self.collection = collection

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = collection
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let gridCard = GlassCard()
        gridCard.translatesAutoresizingMaskIntoConstraints = false
        gridCard.contentView.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: gridCard.contentView.topAnchor, constant: Glass.Space.sm),
            scroll.bottomAnchor.constraint(equalTo: gridCard.contentView.bottomAnchor, constant: -Glass.Space.sm),
            scroll.leadingAnchor.constraint(equalTo: gridCard.contentView.leadingAnchor, constant: Glass.Space.sm),
            scroll.trailingAnchor.constraint(equalTo: gridCard.contentView.trailingAnchor, constant: -Glass.Space.sm),
        ])

        let root = stack([header, gridCard], orientation: .vertical, spacing: Glass.Space.md)
        root.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 42),
            root.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: Glass.Space.lg),
            root.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -Glass.Space.lg),
            root.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -Glass.Space.lg),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            gridCard.widthAnchor.constraint(equalTo: root.widthAnchor),
            gridCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 280),
        ])
    }

    @objc private func changeZoom() { applyZoom() }
    @objc private func changeFilter() { reload() }

    private func applyZoom() {
        guard let layout = collection?.collectionViewLayout as? NSCollectionViewFlowLayout,
              let side = zoomSlider?.doubleValue else { return }
        // The slider changes tile density rather than scaling the screenshot
        // pixels independently, matching the familiar Photos grid interaction.
        layout.itemSize = NSSize(width: side, height: side * 0.76)
        layout.invalidateLayout()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { dayGroups.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        dayGroups[section].items.count
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: CaptureThumbnailItem.identifier, for: indexPath)
        guard let tile = item as? CaptureThumbnailItem else { return item }
        let entry = dayGroups[indexPath.section].items[indexPath.item]
        tile.configure(capture: entry.capture, image: entry.image) { [weak self, weak collectionView] modifiers, clickCount in
            self?.handleClick(at: indexPath, modifiers: modifiers, clickCount: clickCount, collection: collectionView)
        }
        return tile
    }

    private func handleClick(at indexPath: IndexPath, modifiers: NSEvent.ModifierFlags,
                             clickCount: Int, collection: NSCollectionView?) {
        guard let collection else { return }
        let result = CaptureGridInteraction.resolve(
            current: collection.selectionIndexPaths,
            clicked: indexPath,
            modifiers: modifiers,
            clickCount: clickCount
        )
        collection.selectionIndexPaths = result.selection
        refreshSelectionAppearance(in: collection)
        collection.window?.makeFirstResponder(collection)
        updateActionButtons()
        guard let openItem = result.openItem else { return }
        let ids = dayGroups.map { $0.items.map { $0.capture.id } }
        guard let captureID = CaptureHistoryOpening.captureID(at: openItem, dayGroups: ids) else { return }
        detail.show(captureID: captureID)
    }

    private func updateActionButtons() {
        let enabled = collection?.selectionIndexPaths.isEmpty == false
        for button in [shareButton, exportButton].compactMap({ $0 }) {
            button.isEnabled = enabled
            button.alphaValue = enabled ? 1 : 0.45
        }
    }

    private func refreshSelectionAppearance(in collection: NSCollectionView) {
        for item in collection.visibleItems() {
            guard let indexPath = collection.indexPath(for: item) else { continue }
            item.isSelected = collection.selectionIndexPaths.contains(indexPath)
        }
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let view = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: CaptureDayHeader.identifier, for: indexPath)
        (view as? CaptureDayHeader)?.configure(date: dayGroups[indexPath.section].date)
        return view
    }

    private func exportSelection(_ action: ExportAction) {
        guard let collection else { return }
        let selected = collection.selectionIndexPaths.compactMap { indexPath -> CaptureExporter.Item? in
            guard indexPath.section < dayGroups.count, indexPath.item < dayGroups[indexPath.section].items.count else { return nil }
            let item = dayGroups[indexPath.section].items[indexPath.item]
            return CaptureExporter.Item(capture: item.capture, image: item.image)
        }
        guard !selected.isEmpty else {
            let alert = NSAlert(); alert.messageText = "Select one or more captures first"; alert.runModal(); return
        }
        do {
            let destination: URL
            if action == .share {
                destination = FileManager.default.temporaryDirectory
            } else {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                panel.prompt = "Export"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                destination = url
            }
            let store = try Store(directory: Store.defaultDirectory(), access: .reader)
            let zip = try CaptureExporter.export(items: selected, store: store, to: destination)
            if action == .share {
                let picker = NSSharingServicePicker(items: [zip])
                picker.show(relativeTo: collection.bounds, of: collection, preferredEdge: .maxY)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([zip])
            }
        } catch {
            let alert = NSAlert(error: error); alert.runModal()
        }
    }

    private func countDescription(_ count: Int) -> String {
        count == 1 ? "1 capture" : "\(count) captures"
    }

    private func label(_ string: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = font
        field.textColor = color
        field.translatesAutoresizingMaskIntoConstraints = false
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
}

private final class CaptureDayHeader: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("CaptureDayHeader")
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = Glass.muted
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(date: Date) {
        let formatter = DateFormatter(); formatter.dateStyle = .full; formatter.timeStyle = .none
        label.stringValue = formatter.string(from: date)
    }
}

private final class CaptureThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("CaptureThumbnailItem")

    override func loadView() { view = CaptureThumbnailView() }

    override var isSelected: Bool {
        didSet { (view as? CaptureThumbnailView)?.selected = isSelected }
    }

    func configure(capture: Capture, image: NSImage,
                   onClick: @escaping (NSEvent.ModifierFlags, Int) -> Void) {
        guard let thumbnail = view as? CaptureThumbnailView else { return }
        thumbnail.onClick = onClick
        thumbnail.selected = isSelected
        thumbnail.configure(capture: capture, image: image)
    }
}

private final class CaptureThumbnailView: CaptureGridItemView {
    private var image: NSImage?
    private var pinCount = 0
    private var label = ""
    var selected = false { didSet { needsDisplay = true } }

    func configure(capture: Capture, image: NSImage) {
        self.image = image
        pinCount = capture.markers.count
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        label = formatter.string(from: capture.createdAt)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds, xRadius: Glass.Radius.sm, yRadius: Glass.Radius.sm)
        (selected ? Glass.indigoHi.withAlphaComponent(0.24) : NSColor.white.withAlphaComponent(0.05)).setFill()
        rounded.fill()
        (selected ? Glass.amberHi.withAlphaComponent(0.95) : Glass.hairline(dark: true)).setStroke()
        rounded.lineWidth = selected ? 2 : 1
        rounded.stroke()

        let imageArea = bounds.insetBy(dx: 5, dy: 5)
        let captionHeight: CGFloat = 22
        let frame = NSRect(x: imageArea.minX, y: imageArea.minY + captionHeight,
                           width: imageArea.width, height: imageArea.height - captionHeight)
        if let image { image.draw(in: aspectFit(image.size, in: frame), from: .zero, operation: .sourceOver, fraction: 1) }
        let text = label as NSString
        text.draw(at: CGPoint(x: imageArea.minX + 2, y: imageArea.minY + 2), withAttributes: [
            .font: Glass.Font.caption(), .foregroundColor: Glass.muted,
        ])
        if pinCount > 0 {
            let badge = "\(pinCount)" as NSString
            let badgeRect = NSRect(x: frame.maxX - 27, y: frame.maxY - 25, width: 22, height: 20)
            NSColor.black.withAlphaComponent(0.7).setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 10, yRadius: 10).fill()
            badge.draw(at: CGPoint(x: badgeRect.midX - badge.size(withAttributes: [.font: Glass.Font.caption()]).width / 2,
                                   y: badgeRect.minY + 3), withAttributes: [
                .font: Glass.Font.caption(), .foregroundColor: Glass.amberHi,
            ])
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
