#if os(macOS)
import AppKit
import LassoCore
import LassoConductorCore

/// SPE-555: the keyboard-first post-capture annotate step. Shows the freshly
/// captured Region and lets the user drop numbered pins on it (click, or a number
/// key), give each an optional short note, and add one capture-level note — then
/// Save. It stays deliberately light: no freehand, no layers, skippable (Escape /
/// Cancel writes the Capture with no pins). Pins are stored normalized to the
/// image via the `Marker` contract (SPE-554). Rendered in the shared glass style.
struct AnnotationResult {
    let note: String?
    let markers: [Marker]
    let tags: [String]
    let keep: Bool

    static let empty = AnnotationResult(note: nil, markers: [], tags: [], keep: false)
}

enum AnnotationPrompt {
    static func run(image: NSImage?) -> AnnotationResult {
        AnnotationController().run(image: image)
    }
}

private final class AnnotationController: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private var canvas: PinCanvasView!
    private var noteField: GlassField!            // active pin's note
    private var captureNoteField: GlassTextArea!  // optional capture-level note (multi-line)
    private var captureTagField: GlassField!
    private var captureTagsStack: NSStackView!
    private var captureTags: [String] = []
    private var keepCapture = false
    private var keepButton: LassoButton!
    private var deletePinButton: LassoButton!
    private var counterLabel: NSTextField!        // "N / 9"
    private var emptyLabel: NSTextField!          // shown when no pin is selected
    private var noteRow: NSView!                  // the note field + tags (hidden when no pin)
    private var tagsStack: NSStackView!
    private var tagButtons: [String: LassoButton] = [:]
    private var helpPopover: NSPopover?
    private var result: AnnotationResult = .empty
    private var saved = false
    private lazy var fieldEditor = Glass.makeFieldEditor()

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        fieldEditor
    }

    private let contentWidth: CGFloat = 480

    func run(image: NSImage?) -> AnnotationResult {
        build(image: image)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return saved ? result : .empty
    }

    // MARK: - Layout

    private func build(image: NSImage?) {
        let canvasSize = fittedCanvasSize(for: image)
        let windowWidth = contentWidth + Glass.Space.lg * 2

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 640),
            styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        panel.title = "Annotate"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua) // commit to the dark theme
        panel.delegate = self
        window = panel

        // Keep the editable content OUT of the visual-effect view's subtree:
        // inside it, vibrancy blends the text caret to invisibility. The backdrop
        // sits behind as a sibling, so the blur still shows through the window but
        // the fields (and their carets) render with their true colors.
        let container = NSView()
        panel.contentView = container
        let backdrop = GlassBackdrop()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: container.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // Header. The pin counter and help "?" ride on the right of the title row
        // so they cost no extra vertical space (built just below with the button).
        let wordmark = plainLabel("Lasso", font: .systemFont(ofSize: 12, weight: .semibold),
                                  color: Glass.faint)
        let title = plainLabel("Annotate the capture", font: Glass.Font.title(), color: Glass.ink)
        let titleStack = vstack([wordmark, title], spacing: Glass.Space.xs)

        // Canvas.
        let canvasView = PinCanvasView(
            frame: NSRect(origin: .zero, size: canvasSize), image: image)
        canvasView.onActivePinChanged = { [weak self] in self?.syncNoteField() }
        canvasView.onPinsChanged = { [weak self] in self?.updateCounter() }
        canvasView.onDeletePin = { [weak self] index in self?.canvas.removeMarker(index: index) }
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        // Fixed to the image's fitted aspect ratio (not stretched to full width),
        // so the screenshot never distorts and pins map 1:1 to image coordinates.
        canvasView.widthAnchor.constraint(equalToConstant: canvasSize.width).isActive = true
        canvasView.heightAnchor.constraint(equalToConstant: canvasSize.height).isActive = true
        canvas = canvasView

        // Help "?" + pin counter, docked to the right of the title row.
        let helpButton = LassoButton("?", kind: .secondary) { [weak self] in self?.toggleHelp() }
        helpButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        helpButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        counterLabel = plainLabel("0 / \(PinAnnotationModel.maxPins)",
                                  font: .systemFont(ofSize: 11, weight: .semibold), color: Glass.faint)
        let headerSpacer = NSView()
        headerSpacer.translatesAutoresizingMaskIntoConstraints = false
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [titleStack, headerSpacer, counterLabel, helpButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = Glass.Space.sm
        header.translatesAutoresizingMaskIntoConstraints = false

        // Per-pin note. Persist live (onChange) so switching pins never drops an
        // uncommitted note.
        noteField = GlassField(placeholder: "Note for the selected pin")
        noteField.field.target = self
        noteField.field.action = #selector(commitPinNote)
        noteField.onChange = { [weak self] text in self?.updateActivePinNote(text) }
        deletePinButton = LassoButton("Delete pin", kind: .plain) { [weak self] in self?.deleteActivePin() }
        let noteHeaderSpacer = NSView()
        noteHeaderSpacer.translatesAutoresizingMaskIntoConstraints = false
        noteHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let noteHeader = NSStackView(views: [fieldLabel("Selected pin · note"), noteHeaderSpacer, deletePinButton])
        noteHeader.orientation = .horizontal

        // Quick tags (apply to the selected pin — grouped with the note).
        tagsStack = NSStackView()
        tagsStack.orientation = .horizontal
        tagsStack.spacing = Glass.Space.xs
        tagsStack.translatesAutoresizingMaskIntoConstraints = false
        for tag in QuickTags.defaults {
            let button = LassoButton(tag, kind: .secondary) { [weak self] in self?.applyQuickTag(tag) }
            tagButtons[tag] = button
            tagsStack.addArrangedSubview(button)
        }

        let noteStack = vstack([noteHeader, noteField, tagsStack], spacing: Glass.Space.sm)
        noteHeader.widthAnchor.constraint(equalTo: noteStack.widthAnchor).isActive = true
        noteRow = noteStack

        // Empty state when nothing is selected.
        emptyLabel = plainLabel("Select a pin to add a note, or click the capture to drop one.",
                                font: Glass.Font.body(), color: Glass.faint)
        let selectedGroup = makeGroup([emptyLabel, noteStack])

        // Capture note (multi-line, grows with the window).
        captureNoteField = GlassTextArea(placeholder: "Optional note for the whole capture")
        captureNoteField.setContentHuggingPriority(.defaultLow, for: .vertical)
        let captureGroup = vstack([fieldLabel("Capture note"), captureNoteField], spacing: Glass.Space.xs)
        captureNoteField.widthAnchor.constraint(equalTo: captureGroup.widthAnchor).isActive = true

        // Capture-level tags are distinct from the existing pin quick-notes.
        // Return creates a tag immediately; suggestions come from active tags in
        // the local library and unused ones naturally disappear.
        captureTagField = GlassField(placeholder: "Type a tag and press Return")
        captureTagField.field.target = self
        captureTagField.field.action = #selector(commitCaptureTag)
        captureTagsStack = NSStackView()
        captureTagsStack.orientation = .horizontal
        captureTagsStack.spacing = Glass.Space.xs
        captureTagsStack.translatesAutoresizingMaskIntoConstraints = false
        let suggestions = recentCaptureTags().map { tag in
            LassoButton(tag, kind: .secondary) { [weak self] in self?.addCaptureTag(tag) }
        }
        let suggestionsStack = NSStackView(views: suggestions)
        suggestionsStack.orientation = .horizontal
        suggestionsStack.spacing = Glass.Space.xs
        let tagGroup = vstack([fieldLabel("Tags"), captureTagField, captureTagsStack, suggestionsStack], spacing: Glass.Space.xs)
        captureTagField.widthAnchor.constraint(equalTo: tagGroup.widthAnchor).isActive = true
        renderCaptureTags()

        // Footer.
        let skip = LassoButton("Skip", kind: .plain) { [weak self] in self?.skip() }
        skip.keyEquivalent = "\u{1b}" // esc
        let keep = LassoButton("Keep", kind: .secondary) { [weak self] in
            guard let self else { return }
            self.keepCapture.toggle()
            self.keepButton.selected = self.keepCapture
        }
        keepButton = keep
        let save = LassoButton("Save capture", kind: .primary) { [weak self] in self?.save() }
        save.keyEquivalent = "\r"
        save.keyEquivalentModifierMask = .command // ⌘↩
        let footerSpacer = NSView()
        footerSpacer.translatesAutoresizingMaskIntoConstraints = false
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [skip, footerSpacer, keep, save])
        footer.orientation = .horizontal
        footer.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [header, canvasView, selectedGroup, captureGroup, tagGroup, footer])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = Glass.Space.md
        root.distribution = .fill
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setCustomSpacing(Glass.Space.sm, after: canvasView)
        container.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor, constant: Glass.Space.lg),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Glass.Space.lg),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Glass.Space.lg),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Glass.Space.lg),
        ])
        // Full-width rows (the canvas keeps its own fitted width and is centred).
        for v in [selectedGroup, captureGroup, tagGroup, footer, header] as [NSView] {
            v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        canvasView.centerXAnchor.constraint(equalTo: root.centerXAnchor).isActive = true

        syncNoteField()
        updateCounter()

        // Give the window its natural fitted height + a min size for resizing.
        panel.layoutIfNeeded()
        let fittedHeight = root.fittingSize.height + Glass.Space.lg * 2
        let height = max(fittedHeight, canvasSize.height + 340)
        panel.setContentSize(NSSize(width: windowWidth, height: height))
        panel.minSize = NSSize(width: windowWidth, height: min(height, 560))
    }

    /// A bordered smoked-glass group that binds related controls together.
    private func makeGroup(_ views: [NSView]) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = Glass.Radius.sm
        box.layer?.cornerCurve = .continuous
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.035).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = Glass.hairline(dark: true).cgColor
        box.translatesAutoresizingMaskIntoConstraints = false
        let stack = vstack(views, spacing: Glass.Space.sm)
        box.addSubview(stack)
        let pad = Glass.Space.md
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -pad),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -pad),
        ])
        // Group rows span the full inner width so fields don't collapse to intrinsic.
        for v in views { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return box
    }

    private func updateCounter() {
        counterLabel.stringValue = "\(canvas.model.markers.count) / \(PinAnnotationModel.maxPins)"
    }

    // MARK: - Help popover

    private func toggleHelp() {
        if let pop = helpPopover, pop.isShown { pop.close(); return }

        let title = plainLabel("Using pins", font: .systemFont(ofSize: 14, weight: .semibold), color: Glass.ink)
        let rows = [
            helpRow("hand.point.up.left", "Click the capture to drop a numbered pin (up to \(PinAnnotationModel.maxPins))."),
            helpRow("cursorarrow.rays", "Click a pin to select it, then type a note or pick a suggestion."),
            helpRow("number", "Press 1–9 to select or create that pin."),
            helpRow("delete.left", "Delete the selected pin: ⌫, its × badge, or “Delete pin”."),
            helpRow("return", "⌘↩ save · esc skip."),
        ]
        let stack = NSStackView(views: [title] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Glass.Space.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(Glass.Space.md, after: title)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let pad = Glass.Space.md + 2
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalToConstant: 320),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: pad),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -pad),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: pad),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -pad),
        ])
        let vc = NSViewController()
        vc.view = content
        let pop = NSPopover()
        pop.contentViewController = vc
        pop.behavior = .transient
        pop.appearance = NSAppearance(named: .darkAqua)
        helpPopover = pop
        let anchorView = helpButtonView() ?? window.contentView!
        pop.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
    }

    /// One help line: an amber SF Symbol aligned with wrapping text.
    private func helpRow(_ symbol: String, _ text: String) -> NSView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 13, weight: .semibold)
        icon.contentTintColor = Glass.amberHi
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = plainLabel(text, font: Glass.Font.body(), color: Glass.muted)
        label.lineBreakMode = .byWordWrapping
        (label.cell as? NSTextFieldCell)?.wraps = true
        label.preferredMaxLayoutWidth = 264

        // Center the icon within one line of text so it aligns with the first row,
        // not the top of a multi-line block.
        let lineHeight = ceil(Glass.Font.body().ascender - Glass.Font.body().descender + Glass.Font.body().leading)
        let iconBox = NSView()
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(icon)
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 20),
            iconBox.heightAnchor.constraint(equalToConstant: lineHeight),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
        ])
        iconBox.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [iconBox, label])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = Glass.Space.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func helpButtonView() -> NSView? {
        // The help button is the first LassoButton titled "?".
        func find(_ v: NSView) -> NSView? {
            for sub in v.subviews {
                if let b = sub as? LassoButton, b.title == "?" { return b }
                if let hit = find(sub) { return hit }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    private func plainLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = color
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func fieldLabel(_ text: String) -> NSTextField {
        plainLabel(text.uppercased(), font: .systemFont(ofSize: 10, weight: .semibold),
                   color: .tertiaryLabelColor)
    }

    private func vstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        for v in views where v is GlassField {
            v.widthAnchor.constraint(equalTo: s.widthAnchor).isActive = true
        }
        return s
    }

    /// The canvas size that fits the capture inside a `contentWidth` × 340 box
    /// while preserving its aspect ratio — never stretched. Wide captures fill the
    /// width; tall ones are bounded by the height and narrower than full width.
    private func fittedCanvasSize(for image: NSImage?) -> CGSize {
        let maxWidth = contentWidth
        let maxHeight: CGFloat = 340
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: maxWidth, height: 200)
        }
        let aspect = image.size.width / image.size.height
        var width = maxWidth
        var height = maxWidth / aspect
        if height > maxHeight {
            height = maxHeight
            width = maxHeight * aspect
        }
        return CGSize(width: width, height: height)
    }

    // MARK: - Note syncing

    /// Reflects the active pin's note into the field and enables it only when a
    /// pin is selected.
    private func syncNoteField() {
        guard let active = canvas.activeIndex,
              let marker = canvas.model.markers.first(where: { $0.index == active }) else {
            emptyLabel.isHidden = false
            noteRow.isHidden = true
            noteField.stringValue = ""
            highlightActiveTag(nil)
            return
        }
        emptyLabel.isHidden = true
        noteRow.isHidden = false
        noteField.isEnabled = true
        noteField.stringValue = marker.note ?? ""
        highlightActiveTag(marker.note)
        window.makeFirstResponder(noteField.field)
        noteField.moveCaretToEnd()
    }

    /// Highlights the quick-tag chip whose text matches the current note.
    private func highlightActiveTag(_ note: String?) {
        for (tag, button) in tagButtons { button.selected = (tag == note) }
    }

    /// Live-persist the field into the selected pin (called on every keystroke).
    private func updateActivePinNote(_ text: String) {
        guard let active = canvas.activeIndex else { return }
        canvas.model.setNote(index: active, text)
        highlightActiveTag(text)
    }

    @objc private func commitPinNote() {
        guard let active = canvas.activeIndex else { return }
        canvas.model.setNote(index: active, noteField.stringValue)
        canvas.refresh()
        window.makeFirstResponder(canvas) // back to drop mode for the next pin
    }

    /// Deletes the selected pin and returns to drop mode.
    private func deleteActivePin() {
        guard let active = canvas.activeIndex else { return }
        canvas.removeMarker(index: active)
        window.makeFirstResponder(canvas)
    }

    private func applyQuickTag(_ tag: String) {
        guard let active = canvas.activeIndex else { return }
        noteField.stringValue = tag
        canvas.model.setNote(index: active, tag)
        canvas.refresh()
        highlightActiveTag(tag)
        window.makeFirstResponder(noteField.field) // stay on the pin to keep editing
        noteField.moveCaretToEnd()
    }

    @objc private func commitCaptureTag() {
        addCaptureTag(captureTagField.stringValue)
    }

    private func addCaptureTag(_ raw: String) {
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !captureTags.contains(where: { $0.localizedCaseInsensitiveCompare(tag) == .orderedSame }) else {
            captureTagField.stringValue = ""
            return
        }
        captureTags.append(tag)
        captureTagField.stringValue = ""
        renderCaptureTags()
    }

    private func renderCaptureTags() {
        guard let captureTagsStack else { return }
        captureTagsStack.arrangedSubviews.forEach { captureTagsStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for tag in captureTags {
            captureTagsStack.addArrangedSubview(LassoButton("\(tag) ×", kind: .secondary) { [weak self] in
                self?.captureTags.removeAll { $0 == tag }
                self?.renderCaptureTags()
            })
        }
    }

    private func recentCaptureTags() -> [String] {
        guard let store = try? Store(directory: Store.defaultDirectory(), access: .reader) else { return [] }
        return (try? store.recentlyUsedActiveTags()) ?? []
    }

    // MARK: - Finish

    private func save() {
        // Fold any in-progress edit into the active pin before collecting.
        if let active = canvas.activeIndex, window.firstResponder == noteField.field.currentEditor() {
            canvas.model.setNote(index: active, noteField.stringValue)
        }
        let note = captureNoteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        result = AnnotationResult(note: note.isEmpty ? nil : note, markers: canvas.model.markers, tags: captureTags, keep: keepCapture)
        saved = true
        NSApp.stopModal()
    }

    private func skip() {
        // The capture is written regardless of how this prompt is dismissed, so a
        // "skip" must not silently throw away work the user already did. ⌘. (macOS's
        // Cancel chord) and Esc both land here; a user who typed a capture note or
        // dropped pins and then hit ⌘. expecting to save would otherwise lose it.
        // Only a genuinely empty annotation skips to no note / no pins.
        if let active = canvas.activeIndex, window.firstResponder == noteField.field.currentEditor() {
            canvas.model.setNote(index: active, noteField.stringValue)
        }
        let note = captureNoteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = canvas.model.markers
        result = note.isEmpty && markers.isEmpty && captureTags.isEmpty
            ? .empty
            : AnnotationResult(note: note.isEmpty ? nil : note, markers: markers, tags: captureTags, keep: keepCapture)
        saved = true
        NSApp.stopModal()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        skip()
        return true
    }
}

/// The image + pin overlay. Owns a `PinAnnotationModel` and translates clicks and
/// number keys into pin operations. The image is drawn to fill the view's bounds
/// (the view is sized to the image aspect ratio by the controller), so a click
/// maps directly to a normalized image point.
private final class PinCanvasView: NSView {
    var model = PinAnnotationModel()
    private(set) var activeIndex: Int?
    var onActivePinChanged: (() -> Void)?
    var onPinsChanged: (() -> Void)?          // count changed (drop / remove)
    var onDeletePin: ((Int) -> Void)?         // × badge tapped
    private let image: NSImage?
    /// Rect of the active pin's × badge, in view coords, for hit-testing.
    private var deleteBadgeRect: CGRect?

    init(frame: NSRect, image: NSImage?) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        // Only a small radius: this shows the captured screenshot, so a large
        // rounding would clip real content (and the burned-in gesture border) at
        // the corners.
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.04).cgColor
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        // Crosshair for dropping a new pin on empty space; a pointing hand over an
        // existing pin to signal it's selectable/editable.
        addCursorRect(bounds, cursor: .crosshair)
        for marker in model.markers {
            let c = viewPoint(x: marker.x, y: marker.y)
            addCursorRect(CGRect(x: c.x - pinRadius, y: c.y - pinRadius,
                                 width: pinRadius * 2, height: pinRadius * 2),
                          cursor: .pointingHand)
        }
    }

    func refresh() { needsDisplay = true }

    // MARK: - Input

    private let pinRadius: CGFloat = 14

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // The × badge on the selected pin deletes it.
        if let badge = deleteBadgeRect, badge.contains(p), let active = activeIndex {
            onDeletePin?(active)
            return
        }
        // Clicking an existing pin re-selects it (to edit its note) rather than
        // stacking a new pin on top.
        if let hit = markerHit(at: p) {
            activeIndex = hit.index
            needsDisplay = true
            onActivePinChanged?()
            return
        }
        // At the cap, ignore drops on empty space so pins can't pile up endlessly.
        guard !model.isFull else {
            NSSound.beep()
            return
        }
        let normalized = normalize(p)
        let marker = model.drop(x: normalized.x, y: normalized.y)
        activeIndex = marker.index
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onActivePinChanged?()
        onPinsChanged?()
    }

    /// Removes a pin by number, clearing the selection if it was the active one,
    /// and keeps the display + cursor zones in sync.
    func removeMarker(index: Int) {
        guard model.remove(index: index) != nil else { return }
        if activeIndex == index { activeIndex = nil }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onActivePinChanged?()
        onPinsChanged?()
    }

    /// The nearest pin whose drawn circle contains the point, if any.
    private func markerHit(at p: CGPoint) -> Marker? {
        model.markers
            .map { ($0, hypot(viewPoint(x: $0.x, y: $0.y).x - p.x,
                              viewPoint(x: $0.x, y: $0.y).y - p.y)) }
            .filter { $0.1 <= pinRadius + 2 }
            .min { $0.1 < $1.1 }?.0
    }

    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, let first = chars.first else {
            super.keyDown(with: event); return
        }
        switch first {
        case "1"..."9":
            let index = Int(String(first))!
            if model.markers.contains(where: { $0.index == index }) {
                activeIndex = index
            } else if model.isFull {
                NSSound.beep()
                return
            } else {
                // Drop this number at the view centre so a pure-keyboard user can
                // still create it, then move it later by clicking.
                model.place(index: index, x: 0.5, y: 0.5)
                activeIndex = index
            }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
            onActivePinChanged?()
            onPinsChanged?()
        case "\u{7f}", "\u{8}": // Delete / Backspace: remove the selected pin, else the last
            if let target = activeIndex ?? model.markers.map(\.index).max() {
                removeMarker(index: target)
            }
        default:
            super.keyDown(with: event)
        }
    }

    /// View point (bottom-left origin) to normalized image point (top-left origin,
    /// [0,1]).
    private func normalize(_ p: CGPoint) -> (x: Double, y: Double) {
        let x = Double(p.x / max(bounds.width, 1))
        let y = Double(1 - p.y / max(bounds.height, 1))
        return (x, y)
    }

    /// Normalized image point (top-left) back to a view point (bottom-left) for
    /// drawing.
    private func viewPoint(x: Double, y: Double) -> CGPoint {
        CGPoint(x: CGFloat(x) * bounds.width, y: (1 - CGFloat(y)) * bounds.height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        deleteBadgeRect = nil
        for marker in model.markers {
            let center = viewPoint(x: marker.x, y: marker.y)
            let isActive = marker.index == activeIndex
            let radius: CGFloat = isActive ? 14 : 12
            let rect = CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2)
            let circle = NSBezierPath(ovalIn: rect)

            // Gradient fill (amber for the active pin, indigo otherwise), clipped
            // to the circle, under a soft shadow.
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 7,
                          color: NSColor.black.withAlphaComponent(0.5).cgColor)
            NSColor.black.setFill()   // shadow caster (hidden by the gradient)
            circle.fill()
            ctx.restoreGState()

            ctx.saveGState()
            circle.addClip()
            let colors = Glass.pinColors(active: isActive)
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors as CFArray, locations: [0, 1]) {
                ctx.drawLinearGradient(gradient,
                                       start: CGPoint(x: rect.minX, y: rect.maxY),
                                       end: CGPoint(x: rect.maxX, y: rect.minY),
                                       options: [])
            }
            ctx.restoreGState()

            NSColor.white.withAlphaComponent(0.95).setStroke()
            circle.lineWidth = 2
            circle.stroke()

            let text = "\(marker.index)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: Glass.pinInk(dark: Glass.isDark),
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2),
                      withAttributes: attrs)

            // A small orange × badge on the selected pin (top-right) as a second
            // way to delete it.
            if isActive {
                let br: CGFloat = 9
                let bc = CGPoint(x: center.x + radius - 2, y: center.y + radius - 2)
                let badge = CGRect(x: bc.x - br, y: bc.y - br, width: br * 2, height: br * 2)
                deleteBadgeRect = badge.insetBy(dx: -2, dy: -2)
                Glass.orange.setFill()
                NSBezierPath(ovalIn: badge).fill()
                NSColor.white.setStroke()
                let x = NSBezierPath()
                let o: CGFloat = 3.5
                x.move(to: CGPoint(x: bc.x - o, y: bc.y - o)); x.line(to: CGPoint(x: bc.x + o, y: bc.y + o))
                x.move(to: CGPoint(x: bc.x - o, y: bc.y + o)); x.line(to: CGPoint(x: bc.x + o, y: bc.y - o))
                x.lineWidth = 1.6
                x.stroke()
            }
        }
    }
}
#endif
