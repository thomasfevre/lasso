#if os(macOS)
import AppKit
import ImageIO
import LassoCore
import LassoConductorCore

/// A native, Photos-inspired overview of the local Capture library. Captures
/// remain immutable here; selecting one opens the read-only detail inspector.
final class CaptureHistoryController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private enum ExportAction { case save, share }
    private struct Item {
        let capture: Capture
        let thumbnail: NSImage
        let imageAvailable: Bool
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
    private var emptyStateView: HistoryEmptyStateView?
    private var pendingZoomSide: Double?
    private var zoomUpdateScheduled = false
    private var dayGroups: [DayGroup] = []
    private let shareCoordinator = CaptureShareCoordinator()
    private let thumbnailCache = CaptureThumbnailCache()
    private let detail: CaptureDetailController
    private let openSettings: () -> Void
    private let openExtensionSetup: () -> Void
    private let startCapture: () -> Void

    init(detail: CaptureDetailController, openSettings: @escaping () -> Void = {},
         openExtensionSetup: @escaping () -> Void = {},
         startCapture: @escaping () -> Void = {}) {
        self.detail = detail
        self.openSettings = openSettings
        self.openExtensionSetup = openExtensionSetup
        self.startCapture = startCapture
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
            try refreshStatePopup(store: store)
            if let tagPopup {
                let previous = tagPopup.titleOfSelectedItem
                tagPopup.removeAllItems()
                tagPopup.addItems(withTitles: ["All tags"] + availableTags)
                if let previous, tagPopup.itemTitles.contains(previous) { tagPopup.selectItem(withTitle: previous) }
            }
            let captures = try store.searchCaptures(query: searchField?.stringValue ?? "", state: selectedState, tag: selectedTag)
            let loaded = CaptureHistoryLoading.resolved(captures) { capture in
                try thumbnailCache.image(
                    for: capture,
                    loadData: { try store.imageData(for: capture) }
                )
            }
            let items = loaded.map { result in
                Item(
                    capture: result.capture,
                    thumbnail: result.value ?? CaptureImagePlaceholder.make(),
                    imageAvailable: result.value != nil
                )
            }
            let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.capture.id, $0) })
            dayGroups = CaptureDayGrouping.grouped(captures).map { group in
                DayGroup(date: group.day, items: group.captureIDs.compactMap { byID[$0] })
            }
            let unavailable = items.filter { !$0.imageAvailable }.count
            countLabel?.stringValue = countDescription(items.count, unavailable: unavailable)
            collection?.reloadData()
            collection?.selectionIndexPaths = []
            updateActionButtons()
            updateEmptyState()
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
        search.sendsSearchStringImmediately = true
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
        let share = LassoButton("", symbolName: "square.and.arrow.up", accessibilityLabel: "Share selected captures",
                                kind: .secondary) { [weak self] in self?.exportSelection(.share) }
        let export = LassoButton("Export", kind: .primary) { [weak self] in self?.exportSelection(.save) }
        let extensionSetup = LassoButton("", symbolName: "puzzlepiece.extension", accessibilityLabel: "Set up browser extension",
                                         kind: .plain) { [weak self] in self?.openExtensionSetup() }
        let settings = LassoButton("", symbolName: "gearshape", accessibilityLabel: "Open settings",
                                   kind: .plain) { [weak self] in self?.openSettings() }
        shareButton = share
        exportButton = export
        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // The system titlebar already owns closing. Keeping navigation actions
        // here lets Settings remain the top-right control without crowding the
        // library tools.
        let header = stack([titleStack, headerSpacer, state, tag, search, zoomOut, slider, zoomIn, share, export, extensionSetup, settings], orientation: .horizontal, spacing: Glass.Space.sm)
        header.alignment = .centerY

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = Glass.Space.sm
        layout.minimumLineSpacing = Glass.Space.sm
        layout.headerReferenceSize = NSSize(width: 1, height: 28)
        let collection = HistoryCollectionView()
        collection.collectionViewLayout = layout
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.allowsEmptySelection = true
        collection.allowsMultipleSelection = true
        collection.delegate = self
        collection.dataSource = self
        collection.register(CaptureThumbnailItem.self, forItemWithIdentifier: CaptureThumbnailItem.identifier)
        collection.register(CaptureDayHeader.self,
                            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: CaptureDayHeader.identifier)
        self.collection = collection
        collection.onActivateSelection = { [weak self] in self?.openSelectedCapture() }

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = collection
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let gridCard = GlassCard()
        gridCard.translatesAutoresizingMaskIntoConstraints = false
        gridCard.contentView.addSubview(scroll)
        let emptyState = HistoryEmptyStateView()
        emptyState.isHidden = true
        emptyStateView = emptyState
        gridCard.contentView.addSubview(emptyState)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: gridCard.contentView.topAnchor, constant: Glass.Space.sm),
            scroll.bottomAnchor.constraint(equalTo: gridCard.contentView.bottomAnchor, constant: -Glass.Space.sm),
            scroll.leadingAnchor.constraint(equalTo: gridCard.contentView.leadingAnchor, constant: Glass.Space.sm),
            scroll.trailingAnchor.constraint(equalTo: gridCard.contentView.trailingAnchor, constant: -Glass.Space.sm),
            emptyState.centerXAnchor.constraint(equalTo: gridCard.contentView.centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: gridCard.contentView.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: gridCard.contentView.leadingAnchor, constant: Glass.Space.lg),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: gridCard.contentView.trailingAnchor, constant: -Glass.Space.lg),
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

    @objc private func changeZoom() {
        pendingZoomSide = zoomSlider?.doubleValue
        scheduleZoomUpdate()
    }
    @objc private func changeFilter() { reload() }

    private func updateEmptyState() {
        guard let emptyStateView else { return }
        let hasCaptures = dayGroups.contains { !$0.items.isEmpty }
        emptyStateView.isHidden = hasCaptures
        guard !hasCaptures else { return }

        let hasQuery = !(searchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasFilter = (statePopup?.indexOfSelectedItem ?? 0) > 0 || selectedTag != nil
        if hasQuery || hasFilter {
            emptyStateView.configure(
                symbolName: "line.3.horizontal.decrease.circle",
                title: "No matching captures",
                detail: "Try another search, tag, or library filter.",
                actionTitle: "Clear filters"
            ) { [weak self] in self?.clearFilters() }
        } else {
            emptyStateView.configure(
                symbolName: "viewfinder",
                title: "No captures yet",
                detail: "Capture a region and it will appear here with its pins, notes, and context.",
                actionTitle: "Capture a region"
            ) { [weak self] in
                self?.window?.orderOut(nil)
                self?.startCapture()
            }
        }
    }

    private func clearFilters() {
        searchField?.stringValue = ""
        statePopup?.selectItem(at: 0)
        tagPopup?.selectItem(at: 0)
        reload()
    }

    private func refreshStatePopup(store: Store) throws {
        guard let statePopup else { return }
        let selectedIndex = max(0, statePopup.indexOfSelectedItem)
        let recent = try store.count(in: .recent)
        let kept = try store.count(in: .kept)
        let deleted = try store.count(in: .recentlyDeleted)
        let all = recent + kept
        statePopup.removeAllItems()
        statePopup.addItems(withTitles: [
            "All active (\(all))",
            "Recents (\(recent))",
            "Kept (\(kept))",
            "Recently Deleted (\(deleted))",
        ])
        statePopup.selectItem(at: selectedIndex)
    }

    private func scheduleZoomUpdate() {
        guard !zoomUpdateScheduled else { return }
        zoomUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            guard let self else { return }
            self.zoomUpdateScheduled = false
            let side = self.pendingZoomSide
            self.pendingZoomSide = nil
            self.applyZoom(side: side)
        }
    }

    private func applyZoom(side requestedSide: Double? = nil) {
        guard let layout = collection?.collectionViewLayout as? NSCollectionViewFlowLayout,
              let sliderSide = zoomSlider?.doubleValue else { return }
        // The slider changes tile density rather than scaling the screenshot
        // pixels independently, matching the familiar Photos grid interaction.
        // Coalescing continuous slider events to the display cadence and using
        // whole-point sizes avoids repeated full layout passes that cannot be
        // presented between frames.
        let side = (requestedSide ?? sliderSide).rounded()
        let size = NSSize(width: side, height: (side * 0.76).rounded())
        guard layout.itemSize != size else { return }
        layout.itemSize = size
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
        tile.configure(
            capture: entry.capture,
            image: entry.thumbnail,
            imageAvailable: entry.imageAvailable
        ) { [weak self, weak collectionView] modifiers, clickCount in
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
        selectionDidChange(in: collection)
        collection.window?.makeFirstResponder(collection)
        guard let openItem = result.openItem else { return }
        let ids = dayGroups.map { $0.items.map { $0.capture.id } }
        guard let captureID = CaptureHistoryOpening.captureID(at: openItem, dayGroups: ids) else { return }
        detail.show(captureID: captureID)
    }

    private func updateActionButtons() {
        let enabled = collection?.selectionIndexPaths.isEmpty == false
        for button in [shareButton, exportButton].compactMap({ $0 }) {
            button.isEnabled = enabled
        }
    }

    func collectionView(_ collectionView: NSCollectionView,
                        didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange(in: collectionView)
    }

    func collectionView(_ collectionView: NSCollectionView,
                        didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionDidChange(in: collectionView)
    }

    private func selectionDidChange(in collection: NSCollectionView) {
        refreshSelectionAppearance(in: collection)
        updateActionButtons()
    }

    private func openSelectedCapture() {
        guard let indexPath = collection?.selectionIndexPaths.sorted(by: {
            ($0.section, $0.item) < ($1.section, $1.item)
        }).first,
              indexPath.section < dayGroups.count,
              indexPath.item < dayGroups[indexPath.section].items.count else { return }
        detail.show(captureID: dayGroups[indexPath.section].items[indexPath.item].capture.id)
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
        let selectedCaptures = collection.selectionIndexPaths.sorted(by: {
            ($0.section, $0.item) < ($1.section, $1.item)
        }).compactMap { indexPath -> Capture? in
            guard indexPath.section < dayGroups.count, indexPath.item < dayGroups[indexPath.section].items.count else { return nil }
            return dayGroups[indexPath.section].items[indexPath.item].capture
        }
        guard !selectedCaptures.isEmpty else {
            let alert = NSAlert(); alert.messageText = "Select one or more captures first"; alert.runModal(); return
        }
        do {
            let store = try Store(directory: Store.defaultDirectory(), access: .reader)
            let selected: [CaptureExporter.Item] = try selectedCaptures.map { capture in
                guard let image = NSImage(data: try store.imageData(for: capture)) else {
                    throw StoreError.imageRead("capture \(capture.id) image could not be decoded")
                }
                return CaptureExporter.Item(capture: capture, image: image)
            }
            let destination: URL
            if action == .share {
                destination = try TemporaryArtifactLease.shareDirectory()
            } else {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
                panel.prompt = "Export"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                destination = url
            }
            let zip = try CaptureExporter.export(items: selected, store: store, to: destination)
            if action == .share {
                shareCoordinator.present(archive: zip, relativeTo: collection.bounds, of: collection)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([zip])
            }
        } catch {
            let alert = NSAlert(error: error); alert.runModal()
        }
    }

    private func countDescription(_ count: Int, unavailable: Int = 0) -> String {
        let captures = count == 1 ? "1 capture" : "\(count) captures"
        guard unavailable > 0 else { return captures }
        let images = unavailable == 1 ? "1 image unavailable" : "\(unavailable) images unavailable"
        return "\(captures) · \(images)"
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
        label.stringValue = CaptureDisplayDate.dayHeader(date)
    }
}

private final class CaptureThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("CaptureThumbnailItem")

    override func loadView() { view = CaptureThumbnailView() }

    override var isSelected: Bool {
        didSet { (view as? CaptureThumbnailView)?.selected = isSelected }
    }

    func configure(capture: Capture, image: NSImage, imageAvailable: Bool,
                   onClick: @escaping (NSEvent.ModifierFlags, Int) -> Void) {
        guard let thumbnail = view as? CaptureThumbnailView else { return }
        thumbnail.onClick = onClick
        thumbnail.selected = isSelected
        thumbnail.configure(capture: capture, image: image, imageAvailable: imageAvailable)
    }
}

private final class CaptureThumbnailView: CaptureGridItemView {
    private var image: NSImage?
    private var pinCount = 0
    private var label = ""
    private let selectionBadge = NSImageView()
    var selected = false {
        didSet {
            selectionBadge.isHidden = !selected
            setAccessibilityValue(selected ? "Selected" : "Not selected")
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp("Select this capture. Press Return to open it.")

        selectionBadge.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        selectionBadge.contentTintColor = Glass.amberInk
        selectionBadge.imageScaling = .scaleProportionallyDown
        selectionBadge.wantsLayer = true
        selectionBadge.layer?.cornerRadius = 12
        selectionBadge.layer?.backgroundColor = Glass.amberHi.cgColor
        selectionBadge.layer?.borderWidth = 1
        selectionBadge.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        selectionBadge.isHidden = true
        selectionBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectionBadge)
        NSLayoutConstraint.activate([
            selectionBadge.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            selectionBadge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            selectionBadge.widthAnchor.constraint(equalToConstant: 24),
            selectionBadge.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(capture: Capture, image: NSImage, imageAvailable: Bool) {
        self.image = image
        pinCount = capture.markers.count
        label = CaptureDisplayDate.thumbnail(capture.createdAt)
        let pins = pinCount == 1 ? "1 pin" : "\(pinCount) pins"
        let availability = imageAvailable ? "" : ", image unavailable"
        setAccessibilityLabel("Capture \(capture.id), \(label), \(pins)\(availability)")
        needsDisplay = true
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?([], 2)
        return true
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
        if let image {
            let imageRect = aspectFit(image.size, in: frame)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(
                roundedRect: imageRect,
                xRadius: Glass.Radius.sm - 4,
                yRadius: Glass.Radius.sm - 4
            ).addClip()
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }
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

private final class HistoryCollectionView: NSCollectionView {
    var onActivateSelection: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onActivateSelection?()
            return
        }
        super.keyDown(with: event)
    }
}

private final class HistoryEmptyStateView: NSView {
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private var actionButton: LassoButton?
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)

        icon.contentTintColor = Glass.amberHi
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = Glass.Font.heading()
        titleLabel.textColor = Glass.ink
        titleLabel.alignment = .center
        detailLabel.font = Glass.Font.body()
        detailLabel.textColor = Glass.muted
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let button = LassoButton("", kind: .primary) { [weak self] in self?.action?() }
        actionButton = button
        let stack = NSStackView(views: [icon, titleLabel, detailLabel, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Glass.Space.sm
        stack.setCustomSpacing(Glass.Space.md, after: detailLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 330),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func configure(symbolName: String, title: String, detail: String,
                   actionTitle: String, action: @escaping () -> Void) {
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 32, weight: .regular))
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        actionButton?.title = actionTitle
        actionButton?.setAccessibilityLabel(actionTitle)
        self.action = action
        setAccessibilityLabel("\(title). \(detail)")
    }
}

private final class CaptureThumbnailCache {
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 100
        cache.totalCostLimit = 48 * 1_024 * 1_024
    }

    func image(for capture: Capture, loadData: () throws -> Data) rethrows -> NSImage? {
        let key = capture.imageFile as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let data = try loadData()
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
}
#endif
