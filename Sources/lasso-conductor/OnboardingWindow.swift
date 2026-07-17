#if os(macOS)
import AppKit
import LassoConductorCore
import LassoHub

/// SPE-552 / SPE-576: the guided first run. One frosted-glass window that walks
/// the user from install to capturing — a benefit-first welcome with an animated
/// demo of the capture gesture, permissions, the *optional* browser extension,
/// and MCP registration — advancing automatically as each prerequisite is met
/// (live-polled). Shown once on first launch and re-openable from the status
/// menu. The prerequisite logic is the pure `OnboardingState`; the welcome and
/// done screens are display-only bookends handled here.
final class OnboardingController: NSObject, NSWindowDelegate {
    static let onboardedKey = "LassoOnboarded"
    static var hasCompleted: Bool { UserDefaults.standard.bool(forKey: onboardedKey) }

    /// The screens actually rendered. `welcome`/`done` are intro/outro bookends
    /// with no prerequisite in `OnboardingState`; the middle three map 1:1 to
    /// `OnboardingStep` and drive auto-advance.
    private enum Screen: Int, CaseIterable {
        case welcome, permissions, extensionPairing, registerAgents, done

        /// The prerequisite step this screen tracks, if any.
        var step: OnboardingStep? {
            switch self {
            case .welcome: return nil
            case .permissions: return .permissions
            case .extensionPairing: return .extensionPairing
            case .registerAgents: return .registerAgents
            case .done: return .done
            }
        }
    }

    private var window: NSWindow!
    private var backdrop: GlassBackdrop!
    private var headerTitle: NSTextField!
    private var progress: ProgressDots!
    private var stepCount: NSTextField!
    private var content: NSView!          // swapped per step
    private var timer: Timer?
    private weak var relay: RelayServer?
    private var agentsAcknowledged = false
    private var extensionSkipped = false
    /// Which client's registration snippet is shown on the register step; the
    /// pills switch it in place rather than dumping every client's config at once.
    private var registerClient: RegistrationClient = .claude
    private weak var registerTextView: NSTextView?
    private var renderedScreen: Screen?
    /// The screen on display. Usually tracks the natural progression, but the
    /// user can move it backward with "Back"; auto-advance only fires on a fresh
    /// state transition (see `poll()`), so going back stays put.
    private var displayedScreen: Screen = .welcome
    private var lastScreenRecording = false
    private var lastPaired = false
    private weak var doneInstructionsLabel: NSTextField?
    private weak var demoView: GestureDemoView?
    private let activeHotkey: () -> HotkeyChord
    private let updateHotkey: (HotkeyChord) -> Bool

    private let width: CGFloat = 580
    private let height: CGFloat = 660

    init(relay: RelayServer?,
         activeHotkey: @escaping () -> HotkeyChord,
         updateHotkey: @escaping (HotkeyChord) -> Bool) {
        self.relay = relay
        self.activeHotkey = activeHotkey
        self.updateHotkey = updateHotkey
        super.init()
    }

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        let s = state()
        // A returning user who already finished lands on the recap; everyone else
        // starts at the welcome hook.
        displayedScreen = s.isComplete ? .done : .welcome
        lastScreenRecording = s.screenRecordingGranted
        lastPaired = s.extensionPaired
        renderedScreen = nil
        render()
        timer?.invalidate() // never stack pollers if show() is called while open
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    /// Live status tick. Advances the displayed screen only on the rising edge of
    /// a satisfied prerequisite, so a user who stepped back isn't yanked forward.
    private func poll() {
        let s = state()
        let at = displayedScreen
        // At most one auto-advance per tick, so a permission grant and a pairing
        // landing in the same window can't skip the extension screen entirely.
        if s.screenRecordingGranted, !lastScreenRecording, at == .permissions {
            displayedScreen = .extensionPairing
        } else if s.extensionPaired, !lastPaired, at == .extensionPairing {
            displayedScreen = .registerAgents
        }
        lastScreenRecording = s.screenRecordingGranted
        lastPaired = s.extensionPaired
        render()
    }

    // MARK: - State

    private func state() -> OnboardingState {
        OnboardingState(
            screenRecordingGranted: Permissions.hasScreenRecording,
            accessibilityGranted: Permissions.hasAccessibility,
            extensionPaired: relay?.hasConnectedExtension ?? false,
            extensionSkipped: extensionSkipped,
            agentsAcknowledged: agentsAcknowledged)
    }

    private var extensionPaired: Bool { relay?.hasConnectedExtension ?? false }

    // MARK: - Window chrome

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Welcome to Lasso"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isOpaque = false
        w.backgroundColor = .clear
        w.appearance = NSAppearance(named: .darkAqua) // commit to the dark theme
        w.delegate = self
        window = w

        backdrop = GlassBackdrop()
        w.contentView = backdrop

        // Fixed header: wordmark + step title + progress row. Only the step body
        // below is swapped on each screen change.
        let wordmark = makeLabel("Lasso", font: .systemFont(ofSize: 12, weight: .semibold),
                                 color: Glass.muted)
        wordmark.setContentHuggingPriority(.required, for: .vertical)

        headerTitle = makeLabel("", font: Glass.Font.title(), color: Glass.ink)
        headerTitle.maximumNumberOfLines = 2
        headerTitle.lineBreakMode = .byWordWrapping
        headerTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)

        progress = ProgressDots()
        stepCount = makeLabel("", font: Glass.Font.caption(), color: Glass.faint)

        let progressRow = NSStackView(views: [progress, stepCount])
        progressRow.orientation = .horizontal
        progressRow.alignment = .centerY
        progressRow.spacing = Glass.Space.md
        progressRow.translatesAutoresizingMaskIntoConstraints = false

        content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [wordmark, headerTitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = Glass.Space.xs
        header.translatesAutoresizingMaskIntoConstraints = false

        let root = NSStackView(views: [header, progressRow, content])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = Glass.Space.lg
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setCustomSpacing(Glass.Space.sm, after: header)
        root.setCustomSpacing(Glass.Space.lg, after: progressRow)
        backdrop.addSubview(root)

        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 44),
            root.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: Glass.Space.xl),
            root.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -Glass.Space.xl),
            headerTitle.widthAnchor.constraint(equalTo: root.widthAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -Glass.Space.xl),
        ])
    }

    /// Rebuilds the step body only when the screen changes, so live polling never
    /// resets a text selection or scroll position mid-step.
    private func render() {
        let screen = displayedScreen
        guard screen != renderedScreen else { return }
        renderedScreen = screen
        demoView?.stop()
        demoView = nil
        content.subviews.forEach { $0.removeFromSuperview() }

        headerTitle.stringValue = title(for: screen)
        // Progress dots track the three prerequisite steps; the welcome hook has
        // no dots, and done shows them all filled.
        progress.isHidden = screen == .welcome
        if let step = screen.step { progress.setActive(step) }
        stepCount.stringValue = stepLabel(for: screen)

        let body: NSView
        switch screen {
        case .welcome: body = buildWelcome()
        case .permissions: body = buildPermissions()
        case .extensionPairing: body = buildExtension()
        case .registerAgents: body = buildRegister()
        case .done: body = buildDone()
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: content.topAnchor),
            body.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func title(for screen: Screen) -> String {
        switch screen {
        case .welcome: return "Capture anything for your agent"
        case .permissions: return "Let Lasso see the screen"
        case .extensionPairing: return "Richer context on the web"
        case .registerAgents: return "Connect your agent"
        case .done: return "You're all set"
        }
    }

    private func stepLabel(for screen: Screen) -> String {
        switch screen {
        case .welcome: return "Get started"
        case .permissions: return "Step 1 of 3"
        case .extensionPairing: return "Step 2 of 3"
        case .registerAgents: return "Step 3 of 3"
        case .done: return "Done"
        }
    }

    // MARK: - Welcome

    private func buildWelcome() -> NSView {
        let demo = GestureDemoView(hotkeyLabel: activeHotkey().description)
        demoView = demo
        demo.start()

        let benefit = benefitLabel(
            lead: "Point at anything on screen. ",
            rest: "Press your shortcut, drag a box, and your coding agent gets the exact region and what's under it — no copy-paste, no describing.")

        let start = LassoButton("Set up Lasso  →", kind: .primary) { [weak self] in
            self?.go(to: .permissions)
        }
        start.keyEquivalent = "\r"
        let footer = row([spacer(), start])

        let col = column([demo, benefit, spacer(), footer], spacingAfterFirst: Glass.Space.lg)
        demo.heightAnchor.constraint(equalToConstant: 190).isActive = true
        return col
    }

    // MARK: - Step 1 · Permissions

    private func buildPermissions() -> NSView {
        let benefit = benefitLabel(
            lead: "One permission and you're capturing. ",
            rest: "Screen Recording is required; Accessibility is optional and sharpens text extraction.")

        let screenRow = PermissionRow(
            name: "Screen Recording",
            detail: "Required — captures the region you draw over.",
            granted: Permissions.hasScreenRecording,
            requirement: "Required",
            action: { Permissions.openScreenRecordingSettings() })

        let axRow = PermissionRow(
            name: "Accessibility",
            detail: "Optional — reads the element's label for cleaner context.",
            granted: Permissions.hasAccessibility,
            requirement: "Optional",
            action: { Permissions.openAccessibilitySettings() })

        // Continue is normally reached by auto-advance; it's here so a user who
        // stepped back can move forward again once the requirement is met.
        let back = LassoButton("Back", kind: .plain) { [weak self] in self?.go(to: .welcome) }
        let cont = LassoButton("Continue", kind: .primary) { [weak self] in
            self?.go(to: .extensionPairing)
        }
        cont.keyEquivalent = "\r"
        cont.isEnabled = Permissions.hasScreenRecording
        cont.alphaValue = Permissions.hasScreenRecording ? 1 : 0.4
        let footer = row([back, spacer(), cont])

        return column([benefit, screenRow, axRow, spacer(), footer],
                      spacingAfterFirst: Glass.Space.md)
    }

    // MARK: - Step 2 · Extension (optional)

    private func buildExtension() -> NSView {
        let optionalTag = TagChip(text: "OPTIONAL", tint: Glass.muted)

        let benefit = benefitLabel(
            lead: "On web pages, hand over the real element. ",
            rest: "The browser extension gives your agent the DOM node you pointed at — selector, text, component. Skip it and web captures fall back to a screenshot.")

        let flow = FlowMap()

        let status = StatusChip(paired: extensionPaired)

        let back = LassoButton("Back", kind: .plain) { [weak self] in self?.go(to: .permissions) }
        // Once paired, offer Continue; otherwise the step is skippable, with a
        // reveal-the-folder shortcut to make loading the unpacked extension easy.
        let advance: LassoButton = extensionPaired
            ? LassoButton("Continue", kind: .primary) { [weak self] in self?.go(to: .registerAgents) }
            : LassoButton("Skip", kind: .plain) { [weak self] in
                self?.extensionSkipped = true
                self?.go(to: .registerAgents)
              }
        let reveal = LassoButton("Open extension folder",
                                 kind: .secondary) { [weak self] in self?.revealExtensionFolder() }
        let footer = row([back, spacer(), advance, reveal])

        return column([optionalTag, benefit, flow, status, spacer(), footer],
                      spacingAfterFirst: Glass.Space.sm)
    }

    // MARK: - Step 3 · Register

    private func buildRegister() -> NSView {
        let benefit = benefitLabel(
            lead: "Add Lasso to your coding agent. ",
            rest: "Pick your client — the same MCP server binary works for all of them.")

        // Client selector: one snippet at a time, switched by the pills.
        let pills = SegmentedPills(
            titles: RegistrationClient.allCases.map { $0.displayName },
            selected: RegistrationClient.allCases.firstIndex(of: registerClient) ?? 0) { [weak self] i in
            guard let self else { return }
            self.registerClient = RegistrationClient.allCases[i]
            self.registerTextView?.string = self.registerSnippet()
        }

        let card = GlassCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = NSTextView()
        tv.isEditable = false
        tv.drawsBackground = false
        tv.font = Glass.Font.mono()
        tv.string = registerSnippet()
        tv.textColor = Glass.ink
        tv.textContainerInset = NSSize(width: Glass.Space.md, height: Glass.Space.md)
        scroll.documentView = tv
        registerTextView = tv
        card.contentView.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            card.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])

        let back = LassoButton("Back", kind: .plain) { [weak self] in
            self?.go(to: .extensionPairing)
        }
        let copy = LassoButton("Copy", kind: .secondary) { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.registerSnippet(), forType: .string)
        }
        let finish = LassoButton("I've added it  →", kind: .primary) { [weak self] in
            self?.agentsAcknowledged = true
            self?.go(to: .done)
        }
        finish.keyEquivalent = "\r"
        let footer = row([back, spacer(), copy, finish])

        let col = column([benefit, pills, card, footer], spacingAfterFirst: Glass.Space.md)
        card.setContentHuggingPriority(.defaultLow, for: .vertical)
        return col
    }

    private func registerSnippet() -> String {
        RegistrationSnippet.text(for: registerClient, binaryPath: mcpBinaryPath())
    }

    // MARK: - Done

    private func buildDone() -> NSView {
        UserDefaults.standard.set(true, forKey: Self.onboardedKey)

        let demo = GestureDemoView(hotkeyLabel: activeHotkey().description)
        demoView = demo
        demo.start()

        let benefit = benefitLabel(
            lead: "That's the whole loop. ",
            rest: doneInstructions())
        doneInstructionsLabel = benefit

        let hotkeySettings = HotkeySettingsRow(chord: activeHotkey()) { [weak self] chord in
            guard let self else { return false }
            let accepted = self.updateHotkey(chord)
            if accepted {
                self.doneInstructionsLabel?.attributedStringValue =
                    self.benefitAttributed(lead: "That's the whole loop. ", rest: self.doneInstructions())
                self.demoView?.setHotkeyLabel(chord.description)
            }
            return accepted
        }

        let tip = InfoCard(
            title: "Tip",
            body: extensionSkipped
                ? "You skipped the browser extension — web captures use a screenshot. Add it anytime from the menu's Setup item for exact DOM context."
                : "Reopen this guide anytime from the menu bar's Setup item.")

        let back = LassoButton("Back", kind: .plain) { [weak self] in
            self?.go(to: .registerAgents)
        }
        let start = LassoButton("Start using Lasso", kind: .primary) { [weak self] in
            self?.close()
        }
        start.keyEquivalent = "\r"
        let footer = row([back, spacer(), start])

        let col = column([demo, benefit, hotkeySettings, tip, spacer(), footer],
                         spacingAfterFirst: Glass.Space.md)
        demo.heightAnchor.constraint(equalToConstant: 150).isActive = true
        return col
    }

    private func doneInstructions() -> String {
        "Press \(activeHotkey().description) over anything, draw a region, and your agent reads it with get_latest_capture."
    }

    // MARK: - Actions

    /// Move to a specific screen (forward via an action, or backward via "Back").
    private func go(to screen: Screen) {
        displayedScreen = screen
        render()
    }

    private func revealExtensionFolder() {
        // `activateFileViewerSelecting` may silently do nothing for this
        // LSUIElement app. Opening the directory directly is dependable and
        // is exactly what Chrome's “Load unpacked” picker needs the user to
        // select next.
        let result = ExtensionFolderLocator.open(Self.extensionFolderURL(), using: NSWorkspace.shared.open)
        guard result == .opened else {
            showExtensionFolderError()
            return
        }
    }

    private func showExtensionFolderError() {
        let alert = NSAlert()
        alert.messageText = "Extension folder not found"
        alert.informativeText = "The bundled browser extension is missing. Rebuild or reinstall Lasso, then try again."
        alert.runModal()
    }

    // MARK: - Paths

    /// The `lasso-mcp` binary sits next to the Conductor executable.
    private func mcpBinaryPath() -> String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "lasso-conductor"
        return URL(fileURLWithPath: exe).deletingLastPathComponent()
            .appendingPathComponent("lasso-mcp").path
    }

    /// Best-effort location of the bundled/dev `extension` folder: the app bundle
    /// Resources first, then walking up from the executable to a checkout.
    static func extensionFolderURL() -> URL? {
        let executableURL = (Bundle.main.executablePath ?? CommandLine.arguments.first)
            .map { URL(fileURLWithPath: $0) }
        return ExtensionFolderLocator.locate(resourceURL: Bundle.main.resourceURL,
                                             executableURL: executableURL)
    }

    // MARK: - Layout helpers

    private func makeLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = font
        l.textColor = color
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    /// A benefit-first headline line: an ink-weighted lead followed by a muted
    /// continuation, wrapping as one paragraph.
    private func benefitAttributed(lead: String, rest: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: lead, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
            .foregroundColor: Glass.ink,
        ])
        s.append(NSAttributedString(string: rest, attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .regular),
            .foregroundColor: Glass.muted,
        ]))
        return s
    }

    private func benefitLabel(lead: String, rest: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: "")
        l.attributedStringValue = benefitAttributed(lead: lead, rest: rest)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return l
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return v
    }

    /// A full-width vertical stack.
    private func column(_ views: [NSView], spacingAfterFirst: CGFloat? = nil) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Glass.Space.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let s = spacingAfterFirst, let first = views.first {
            stack.setCustomSpacing(s, after: first)
        }
        // Every direct child spans the full width so cards fill the pane and
        // footer rows can push their trailing button to the edge via a spacer.
        for v in views {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    /// A full-width horizontal stack (buttons / status rows).
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Glass.Space.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func close() {
        timer?.invalidate()
        timer = nil
        demoView?.stop()
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        demoView?.stop()
    }
}

// MARK: - Reusable pieces

/// Settings row for the capture shortcut. The control owns keyboard capture;
/// the controller only supplies the currently active value and change action.
final class HotkeySettingsRow: NSView {
    private let recorder: HotkeyRecorder

    init(chord: HotkeyChord, onChange: @escaping (HotkeyChord) -> Bool) {
        recorder = HotkeyRecorder(chord: chord, onChange: onChange)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let card = GlassCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let title = NSTextField(labelWithString: "Capture shortcut")
        title.font = Glass.Font.heading()
        title.textColor = Glass.ink
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(
            wrappingLabelWithString: "Click the shortcut, then press a new key combination.")
        detail.font = Glass.Font.caption()
        detail.textColor = Glass.muted
        detail.translatesAutoresizingMaskIntoConstraints = false

        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentHuggingPriority(.defaultLow, for: .horizontal)

        recorder.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [text, recorder])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Glass.Space.md
        row.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: Glass.Space.md),
            row.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -Glass.Space.md),
            row.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: Glass.Space.md),
            row.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -Glass.Space.md),
        ])
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func setChord(_ chord: HotkeyChord) {
        recorder.setChord(chord)
    }
}

/// A focused, button-like control that records the next key-down and modifiers.
/// Escape with no modifiers cancels recording; rejected values snap back to the
/// active chord because `onChange` only succeeds after Carbon registration.
private final class HotkeyRecorder: NSControl {
    private let valueLabel = NSTextField(labelWithString: "")
    private let onChange: (HotkeyChord) -> Bool
    private var chord: HotkeyChord
    private var isRecording = false
    private var modifierOnlyKeyCode: UInt32?
    private var recordedModifiers: HotkeyModifiers = []

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 132, height: 36) }

    init(chord: HotkeyChord, onChange: @escaping (HotkeyChord) -> Bool) {
        self.chord = chord
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1

        valueLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        valueLabel.alignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 132),
            heightAnchor.constraint(equalToConstant: 36),
        ])
        setAccessibilityLabel("Capture shortcut")
        refreshAppearance()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
        modifierOnlyKeyCode = nil
        recordedModifiers = []
        refreshAppearance()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { return }
        let modifiers = HotkeyModifiers(event.modifierFlags)
        if event.keyCode == 53, modifiers.isEmpty {
            stopRecording()
            return
        }

        let candidate = HotkeyChord(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers)
        if onChange(candidate) { chord = candidate }
        stopRecording()
    }

    override func flagsChanged(with event: NSEvent) {
        guard isRecording else { return }
        let modifiers = HotkeyModifiers(event.modifierFlags)
        modifierOnlyKeyCode = UInt32(event.keyCode)
        recordedModifiers.formUnion(modifiers)
        if modifiers.isEmpty {
            if let modifierOnlyKeyCode {
                _ = onChange(HotkeyChord(
                    keyCode: modifierOnlyKeyCode,
                    modifiers: recordedModifiers))
            }
            stopRecording()
        } else {
            valueLabel.stringValue = "\(modifiers.description)…"
        }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { stopRecording() }
        return resigned
    }

    private func stopRecording() {
        isRecording = false
        refreshAppearance()
    }

    func setChord(_ chord: HotkeyChord) {
        isRecording = false
        modifierOnlyKeyCode = nil
        recordedModifiers = []
        self.chord = chord
        refreshAppearance()
    }

    private func refreshAppearance() {
        valueLabel.stringValue = isRecording ? "Type shortcut…" : chord.description
        valueLabel.textColor = isRecording ? Glass.ink : Glass.muted
        layer?.backgroundColor = NSColor.white.withAlphaComponent(isRecording ? 0.13 : 0.07).cgColor
        layer?.borderColor = (isRecording ? Glass.amberHi : NSColor(white: 1, alpha: 0.14)).cgColor
        setAccessibilityValue(chord.description)
    }
}

private extension HotkeyModifiers {
    init(_ eventFlags: NSEvent.ModifierFlags) {
        var value: HotkeyModifiers = []
        if eventFlags.contains(.command) { value.insert(.command) }
        if eventFlags.contains(.option) { value.insert(.option) }
        if eventFlags.contains(.control) { value.insert(.control) }
        if eventFlags.contains(.shift) { value.insert(.shift) }
        self = value
    }

}

/// The three-step progress indicator (capsules; the active one widens and takes
/// the ink, completed ones take a dimmed amber).
private final class ProgressDots: NSView {
    private let dots: [NSView]
    private let widthConstraints: [NSLayoutConstraint]
    private let steps: [OnboardingStep] = [.permissions, .extensionPairing, .registerAgents]

    init() {
        var dotViews: [NSView] = []
        var widths: [NSLayoutConstraint] = []
        for _ in steps {
            let d = NSView()
            d.wantsLayer = true
            d.layer?.cornerRadius = 3
            d.translatesAutoresizingMaskIntoConstraints = false
            d.heightAnchor.constraint(equalToConstant: 6).isActive = true
            let w = d.widthAnchor.constraint(equalToConstant: 6)
            w.isActive = true
            widths.append(w)
            dotViews.append(d)
        }
        dots = dotViews
        widthConstraints = widths
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: dots)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    func setActive(_ step: OnboardingStep) {
        let activeIndex = steps.firstIndex(of: step) ?? steps.count // done → all filled
        for (i, dot) in dots.enumerated() {
            let done = i < activeIndex
            let current = i == activeIndex
            widthConstraints[i].constant = current ? 24 : 6
            dot.layer?.backgroundColor = (current
                ? Glass.ink
                : (done ? Glass.amberLo : NSColor(white: 1, alpha: 0.14))).cgColor
            dot.layer?.opacity = done ? 0.8 : 1
        }
    }
}

/// A permission line: name + description on the left, a status chip and an
/// "Open settings" button on the right, inside a glass card.
private final class PermissionRow: NSView {
    init(name: String, detail: String, granted: Bool, requirement: String,
         action: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let card = GlassCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let title = NSTextField(labelWithString: name)
        title.font = Glass.Font.heading()
        title.textColor = Glass.ink
        title.translatesAutoresizingMaskIntoConstraints = false

        let sub = NSTextField(wrappingLabelWithString: detail)
        sub.font = Glass.Font.caption()
        sub.textColor = Glass.muted
        sub.translatesAutoresizingMaskIntoConstraints = false
        sub.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [title, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        let chip = TagChip(
            text: granted ? "Granted" : requirement,
            tint: granted ? Glass.okGreen : (requirement == "Required" ? Glass.orange : Glass.muted))

        let button = LassoButton(granted ? "Re-open" : "Grant",
                                 kind: granted ? .secondary : .primary, onClick: action)

        let gap = NSView()
        gap.translatesAutoresizingMaskIntoConstraints = false
        gap.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let hstack = NSStackView(views: [text, gap, chip, button])
        hstack.orientation = .horizontal
        hstack.alignment = .centerY
        hstack.spacing = Glass.Space.sm
        hstack.translatesAutoresizingMaskIntoConstraints = false
        chip.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentHuggingPriority(.required, for: .horizontal)
        card.contentView.addSubview(hstack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            hstack.topAnchor.constraint(equalTo: card.topAnchor, constant: Glass.Space.md),
            hstack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Glass.Space.md),
            hstack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Glass.Space.md),
            hstack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Glass.Space.md),
        ])
    }
    required init?(coder: NSCoder) { fatalError("unused") }
}

/// A titled explanatory card ("Tip").
private final class InfoCard: NSView {
    init(title: String, body: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let card = GlassCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let t = NSTextField(labelWithString: title)
        t.font = Glass.Font.heading()
        t.textColor = Glass.ink
        t.translatesAutoresizingMaskIntoConstraints = false

        let b = NSTextField(wrappingLabelWithString: body)
        b.font = Glass.Font.body()
        b.textColor = Glass.muted
        b.translatesAutoresizingMaskIntoConstraints = false
        b.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [t, b])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Glass.Space.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Glass.Space.md),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Glass.Space.md),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Glass.Space.md),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Glass.Space.md),
        ])
    }
    required init?(coder: NSCoder) { fatalError("unused") }
}

/// A small pill label (OPTIONAL, Required, Granted…).
private final class TagChip: NSView {
    init(text: String, tint: NSColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = tint.withAlphaComponent(0.15).cgColor

        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = tint.blended(withFraction: 0.35, of: .white) ?? tint
        l.translatesAutoresizingMaskIntoConstraints = false
        addSubview(l)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            l.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            l.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            l.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
    }
    required init?(coder: NSCoder) { fatalError("unused") }
}

/// A single-select row of pills (a lightweight segmented control). The selected
/// pill takes the amber fill; the rest are outline. Used to pick which client's
/// registration snippet is shown.
private final class SegmentedPills: NSView {
    private var pills: [Pill] = []
    private var selectedIndex: Int
    private let onSelect: (Int) -> Void

    init(titles: [String], selected: Int, onSelect: @escaping (Int) -> Void) {
        self.selectedIndex = selected
        self.onSelect = onSelect
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        pills = titles.enumerated().map { index, title in
            Pill(title: title) { [weak self] in self?.select(index) }
        }
        let stack = NSStackView(views: pills)
        stack.orientation = .horizontal
        stack.spacing = Glass.Space.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    private func select(_ i: Int) {
        guard i != selectedIndex else { return }
        selectedIndex = i
        refresh()
        onSelect(i)
    }

    private func refresh() {
        for (i, pill) in pills.enumerated() { pill.setSelected(i == selectedIndex) }
    }

    /// One clickable pill with selected / unselected styling.
    private final class Pill: NSView {
        private let onClick: () -> Void
        private let label = NSTextField(labelWithString: "")

        init(title: String, onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.cornerRadius = 11
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 1

            label.stringValue = title
            label.font = .systemFont(ofSize: 11.5, weight: .medium)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
        }
        required init?(coder: NSCoder) { fatalError("unused") }

        func setSelected(_ on: Bool) {
            if on {
                layer?.backgroundColor = Glass.amberHi.cgColor
                layer?.borderColor = NSColor.clear.cgColor
                label.textColor = Glass.amberInk
            } else {
                layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
                layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
                label.textColor = Glass.muted
            }
        }

        override func mouseDown(with event: NSEvent) { onClick() }
    }
}

/// The web-context explainer: three glass nodes (Web page → Lasso → Agent) with
/// SF Symbol glyphs, the middle one accented amber, joined by arrows. Conveys
/// the DOM hand-off at a glance instead of a paragraph.
private final class FlowMap: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let card = GlassCard()
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        let web = FlowMap.node(kind: .browser, label: "Web page", tint: Glass.ink)
        let lasso = FlowMap.node(kind: .marquee, label: "Capture", tint: Glass.amberHi)
        let agent = FlowMap.node(kind: .dom, label: "Agent gets DOM", tint: Glass.ink)

        let stack = NSStackView(views: [web, FlowMap.arrow(), lasso, FlowMap.arrow(), agent])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = Glass.Space.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: Glass.Space.md),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -Glass.Space.md),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: Glass.Space.md),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -Glass.Space.md),
            web.widthAnchor.constraint(equalTo: agent.widthAnchor),
            lasso.widthAnchor.constraint(equalTo: agent.widthAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    private static func node(kind: FlowIconView.Kind, label: String, tint: NSColor) -> NSView {
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = Glass.Radius.sm
        box.layer?.cornerCurve = .continuous
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor(white: 1, alpha: 0.09).cgColor

        let icon = FlowIconView(kind: kind, tint: tint)

        let text = NSTextField(labelWithString: label)
        text.font = .systemFont(ofSize: 11, weight: .regular)
        text.textColor = Glass.muted
        text.alignment = .center
        text.maximumNumberOfLines = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [icon, text])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Glass.Space.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: Glass.Space.sm + 2),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -(Glass.Space.sm + 2)),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: Glass.Space.xs),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -Glass.Space.xs),
        ])
        return box
    }

    private static func arrow() -> NSView {
        let l = NSTextField(labelWithString: "→")
        l.font = .systemFont(ofSize: 16, weight: .medium)
        l.textColor = Glass.amberLo
        l.translatesAutoresizingMaskIntoConstraints = false
        l.setContentHuggingPriority(.required, for: .horizontal)
        return l
    }
}

/// Hand-drawn glyphs for the FlowMap, tuned to Lasso's own vocabulary rather than
/// generic SF Symbols: a browser chrome, the rectangular capture gesture (a
/// dashed marquee with a cursor — what the user actually draws), and the DOM
/// context the agent receives (a document of structured lines).
private final class FlowIconView: NSView {
    enum Kind { case browser, marquee, dom }
    private let kind: Kind
    private let tint: NSColor

    init(kind: Kind, tint: NSColor) {
        self.kind = kind
        self.tint = tint
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 28) }
    override var isFlipped: Bool { false } // y-up: higher y is the top

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds.insetBy(dx: 3, dy: 2)
        switch kind {
        case .browser:  drawBrowser(in: b)
        case .marquee:  drawMarquee(in: b)
        case .dom:      drawDOM(in: b)
        }
    }

    /// A browser window: rounded frame, a title bar with two dots, content lines.
    private func drawBrowser(in b: NSRect) {
        tint.setStroke()
        let frame = NSBezierPath(roundedRect: b, xRadius: 4, yRadius: 4)
        frame.lineWidth = 1.6
        frame.stroke()

        let barY = b.maxY - 6
        let bar = NSBezierPath()
        bar.move(to: NSPoint(x: b.minX, y: barY))
        bar.line(to: NSPoint(x: b.maxX, y: barY))
        bar.lineWidth = 1.4
        bar.stroke()

        tint.setFill()
        for i in 0..<2 {
            let dot = NSBezierPath(ovalIn: NSRect(x: b.minX + 3 + CGFloat(i) * 4, y: barY + 2, width: 1.6, height: 1.6))
            dot.fill()
        }
        // Two faint content lines.
        let faint = tint.withAlphaComponent(0.45)
        faint.setStroke()
        for (i, w) in [0.6, 0.4].enumerated() {
            let y = barY - 6 - CGFloat(i) * 5
            let line = NSBezierPath()
            line.move(to: NSPoint(x: b.minX + 4, y: y))
            line.line(to: NSPoint(x: b.minX + 4 + (b.width - 8) * CGFloat(w), y: y))
            line.lineWidth = 1.6
            line.lineCapStyle = .round
            line.stroke()
        }
    }

    /// The capture gesture: a dashed selection rectangle with a cursor arrow —
    /// exactly what the user drags on screen.
    private func drawMarquee(in b: NSRect) {
        let rect = b.insetBy(dx: 1, dy: 1)
        let marquee = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        marquee.lineWidth = 1.6
        marquee.setLineDash([3, 2.4], count: 2, phase: 0)
        tint.setStroke()
        marquee.stroke()

        // A small pointer near the lower-right, as if mid-drag.
        let ox = rect.maxX - 5, oy = rect.minY + 9
        let cursor = NSBezierPath()
        cursor.move(to: NSPoint(x: ox, y: oy))
        cursor.line(to: NSPoint(x: ox, y: oy - 9))
        cursor.line(to: NSPoint(x: ox + 2.6, y: oy - 6.4))
        cursor.line(to: NSPoint(x: ox + 4.2, y: oy - 9.6))
        cursor.line(to: NSPoint(x: ox + 5.4, y: oy - 9.1))
        cursor.line(to: NSPoint(x: ox + 3.7, y: oy - 5.7))
        cursor.line(to: NSPoint(x: ox + 7, y: oy - 5.4))
        cursor.close()
        tint.setFill()
        cursor.fill()
    }

    /// The DOM context the agent receives: a document with structured lines, the
    /// first one accented to read as "highlighted element".
    private func drawDOM(in b: NSRect) {
        let doc = b.insetBy(dx: 2, dy: 0)
        tint.setStroke()
        let frame = NSBezierPath(roundedRect: doc, xRadius: 3, yRadius: 3)
        frame.lineWidth = 1.6
        frame.stroke()

        let widths: [CGFloat] = [0.66, 0.5, 0.72]
        for (i, w) in widths.enumerated() {
            let y = doc.maxY - 6 - CGFloat(i) * 5
            let line = NSBezierPath()
            line.move(to: NSPoint(x: doc.minX + 4, y: y))
            line.line(to: NSPoint(x: doc.minX + 4 + (doc.width - 8) * w, y: y))
            line.lineWidth = 1.8
            line.lineCapStyle = .round
            (i == 0 ? Glass.amberHi : tint.withAlphaComponent(0.45)).setStroke()
            line.stroke()
        }
    }
}

/// Live pairing status for the extension step.
private final class StatusChip: NSView {
    init(paired: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = (paired ? Glass.okGreen : Glass.orange).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let l = NSTextField(labelWithString: paired ? "Extension paired" : "Waiting to pair…")
        l.font = Glass.Font.caption()
        l.textColor = Glass.muted
        l.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [dot, l])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = Glass.Space.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError("unused") }
}

/// SPE-576: the "aha" visual — a looping animation of the core capture gesture:
/// a faux editor window, the hotkey badge lights, the screen dims, a marquee is
/// dragged over a region, then a "Captured" toast. Timer-driven (a single ~30fps
/// phase in [0,1) over ~5s) so the geometry is predictable across AppKit's
/// coordinate quirks; honours Reduce Motion by showing the end state statically.
private final class GestureDemoView: NSView {
    private let appPanel = NSView()
    private let dim = NSView()
    private let marquee = NSView()
    private let cursor = NSImageView()
    private let keyBadge = NSView()
    private let keyLabel = NSTextField(labelWithString: "")
    private let toast = NSView()

    private var timer: Timer?
    private var phase: CGFloat = 0
    private let period: CGFloat = 5.0
    private let tick: CGFloat = 1.0 / 30.0

    override var isFlipped: Bool { true } // top-left origin, matching the mockup math

    init(hotkeyLabel: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Glass.Radius.md
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(srgbRed: 0.051, green: 0.051, blue: 0.067, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.09).cgColor

        // Faux editor: a bordered dark panel with a title bar and code lines.
        appPanel.wantsLayer = true
        appPanel.layer?.cornerRadius = 10
        appPanel.layer?.backgroundColor = NSColor(srgbRed: 0.082, green: 0.082, blue: 0.106, alpha: 1).cgColor
        appPanel.layer?.borderWidth = 1
        appPanel.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        addCodeLines(to: appPanel)
        addSubview(appPanel)

        // Dim overlay.
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor(srgbRed: 0.02, green: 0.02, blue: 0.03, alpha: 0.55).cgColor
        dim.alphaValue = 0
        addSubview(dim)

        // Marquee selection rect.
        marquee.wantsLayer = true
        marquee.layer?.borderWidth = 2
        marquee.layer?.borderColor = Glass.amberHi.cgColor
        marquee.layer?.cornerRadius = 4
        marquee.layer?.backgroundColor = Glass.amberHi.withAlphaComponent(0.12).cgColor
        marquee.alphaValue = 0
        addSubview(marquee)

        // Cursor (arrow).
        cursor.image = GestureDemoView.cursorImage()
        cursor.alphaValue = 0
        addSubview(cursor)

        // Hotkey badge.
        keyBadge.wantsLayer = true
        keyBadge.layer?.cornerRadius = 8
        keyBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        keyBadge.layer?.borderWidth = 1
        keyBadge.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        keyLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        keyLabel.textColor = Glass.ink
        keyLabel.stringValue = hotkeyLabel
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        keyBadge.addSubview(keyLabel)
        NSLayoutConstraint.activate([
            keyLabel.topAnchor.constraint(equalTo: keyBadge.topAnchor, constant: 4),
            keyLabel.bottomAnchor.constraint(equalTo: keyBadge.bottomAnchor, constant: -4),
            keyLabel.leadingAnchor.constraint(equalTo: keyBadge.leadingAnchor, constant: 9),
            keyLabel.trailingAnchor.constraint(equalTo: keyBadge.trailingAnchor, constant: -9),
        ])
        keyBadge.alphaValue = 0
        addSubview(keyBadge)

        // Toast.
        buildToast()
        toast.alphaValue = 0
        addSubview(toast)
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Safety net: the RunLoop retains the Timer independently of this view, so
    /// invalidate here too rather than relying on every call site to call stop().
    deinit { timer?.invalidate() }

    func setHotkeyLabel(_ text: String) { keyLabel.stringValue = text }

    func start() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layoutStaticEndState()
            return
        }
        stop()
        let t = Timer(timeInterval: TimeInterval(tick), repeats: true) { [weak self] _ in
            self?.advance()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func advance() {
        phase += tick / period
        if phase >= 1 { phase -= 1 }
        applyPhase()
    }

    // MARK: geometry

    override func layout() {
        super.layout()
        layoutFrames()
        if timer == nil, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            layoutStaticEndState()
        } else {
            applyPhase()
        }
    }

    /// Static frames that don't depend on phase (panel, dim, badge, toast).
    private func layoutFrames() {
        let b = bounds
        appPanel.frame = NSRect(x: 26, y: 26, width: min(300, b.width - 52), height: max(0, b.height - 52))
        dim.frame = b
        let kb = keyLabel.intrinsicContentSize
        let kbw = kb.width + 18, kbh = kb.height + 8
        keyBadge.frame = NSRect(x: (b.width - kbw) / 2, y: 12, width: kbw, height: kbh)
        toast.frame = NSRect(x: b.width - toastSize.width - 16,
                             y: b.height - toastSize.height - 14,
                             width: toastSize.width, height: toastSize.height)
    }

    private var startPoint: NSPoint { NSPoint(x: 150, y: 78) }
    private var endMarquee: NSSize { NSSize(width: 130, height: 66) }

    /// Interpolate 0→1 over [lo,hi], clamped.
    private func seg(_ t: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        guard hi > lo else { return t >= hi ? 1 : 0 }
        return max(0, min(1, (t - lo) / (hi - lo)))
    }

    private func applyPhase() {
        let t = phase
        // Hotkey badge: fade in 0.04→0.08, hold, out by 0.26.
        keyBadge.alphaValue = seg(t, 0.04, 0.08) * (1 - seg(t, 0.20, 0.26))
        // Dim in 0.14→0.22, hold, out 0.74→0.84.
        dim.alphaValue = seg(t, 0.14, 0.22) * (1 - seg(t, 0.74, 0.84))
        // Cursor: appears 0.16, travels start→end 0.20→0.46, out 0.72→0.80.
        let curAppear = seg(t, 0.16, 0.20)
        let curOut = 1 - seg(t, 0.72, 0.80)
        cursor.alphaValue = curAppear * curOut
        let travel = seg(t, 0.20, 0.46)
        let cx = startPoint.x + endMarquee.width * travel
        let cy = startPoint.y + endMarquee.height * travel
        cursor.frame = NSRect(x: cx, y: cy, width: 18, height: 18)
        // Marquee: grows 0.24→0.46, holds, flash+out 0.72→0.76.
        let grow = seg(t, 0.24, 0.46)
        let mAlpha = seg(t, 0.22, 0.26) * (1 - seg(t, 0.72, 0.76))
        marquee.alphaValue = mAlpha
        marquee.frame = NSRect(x: startPoint.x, y: startPoint.y,
                               width: endMarquee.width * grow, height: endMarquee.height * grow)
        // Toast: in 0.74→0.80, hold, out by 1.0.
        toast.alphaValue = seg(t, 0.74, 0.80) * (1 - seg(t, 0.94, 1.0))
    }

    private func layoutStaticEndState() {
        keyBadge.alphaValue = 0
        dim.alphaValue = 0.5
        cursor.alphaValue = 1
        cursor.frame = NSRect(x: startPoint.x + endMarquee.width,
                              y: startPoint.y + endMarquee.height, width: 18, height: 18)
        marquee.alphaValue = 1
        marquee.frame = NSRect(x: startPoint.x, y: startPoint.y,
                               width: endMarquee.width, height: endMarquee.height)
        toast.alphaValue = 1
    }

    // MARK: sub-pieces

    private func addCodeLines(to panel: NSView) {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 5
        bar.translatesAutoresizingMaskIntoConstraints = false
        for _ in 0..<3 {
            let d = NSView()
            d.wantsLayer = true
            d.layer?.cornerRadius = 4
            d.layer?.backgroundColor = NSColor(white: 0.24, alpha: 1).cgColor
            d.translatesAutoresizingMaskIntoConstraints = false
            d.widthAnchor.constraint(equalToConstant: 8).isActive = true
            d.heightAnchor.constraint(equalToConstant: 8).isActive = true
            bar.addArrangedSubview(d)
        }

        func line(width: CGFloat, color: NSColor) -> NSView {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.cornerRadius = 3
            v.layer?.backgroundColor = color.cgColor
            v.translatesAutoresizingMaskIntoConstraints = false
            v.heightAnchor.constraint(equalToConstant: 7).isActive = true
            v.widthAnchor.constraint(equalToConstant: width).isActive = true
            return v
        }
        let lines = NSStackView(views: [
            line(width: 190, color: Glass.amberHi.withAlphaComponent(0.35)),
            line(width: 140, color: NSColor(white: 1, alpha: 0.10)),
            line(width: 170, color: NSColor(white: 1, alpha: 0.10)),
            line(width: 110, color: Glass.indigoHi.withAlphaComponent(0.4)),
            line(width: 140, color: NSColor(white: 1, alpha: 0.10)),
        ])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 7
        lines.translatesAutoresizingMaskIntoConstraints = false

        panel.addSubview(bar)
        panel.addSubview(lines)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            bar.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            lines.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 12),
            lines.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
        ])
    }

    private let toastSize = NSSize(width: 200, height: 34)
    private func buildToast() {
        toast.wantsLayer = true
        toast.layer?.cornerRadius = 10
        toast.layer?.backgroundColor = NSColor(srgbRed: 0.118, green: 0.102, blue: 0.082, alpha: 0.9).cgColor
        toast.layer?.borderWidth = 1
        toast.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor

        let tickDot = NSView()
        tickDot.wantsLayer = true
        tickDot.layer?.cornerRadius = 8
        tickDot.layer?.backgroundColor = Glass.okGreen.cgColor
        tickDot.translatesAutoresizingMaskIntoConstraints = false
        let mark = NSTextField(labelWithString: "✓")
        mark.font = .systemFont(ofSize: 10, weight: .heavy)
        mark.textColor = NSColor(srgbRed: 0.016, green: 0.071, blue: 0.039, alpha: 1)
        mark.translatesAutoresizingMaskIntoConstraints = false
        tickDot.addSubview(mark)

        let text = NSTextField(labelWithString: "Captured — your agent can read it")
        text.font = .systemFont(ofSize: 11.5, weight: .regular)
        text.textColor = Glass.ink
        text.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [tickDot, text])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        toast.addSubview(stack)
        NSLayoutConstraint.activate([
            tickDot.widthAnchor.constraint(equalToConstant: 16),
            tickDot.heightAnchor.constraint(equalToConstant: 16),
            mark.centerXAnchor.constraint(equalTo: tickDot.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: tickDot.centerYAnchor),
            stack.centerYAnchor.constraint(equalTo: toast.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: toast.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: toast.trailingAnchor, constant: -12),
        ])
    }

    private static func cursorImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 3, y: 17))
        path.line(to: NSPoint(x: 3, y: 1))
        path.line(to: NSPoint(x: 8, y: 6))
        path.line(to: NSPoint(x: 11, y: 0))
        path.line(to: NSPoint(x: 13, y: 1))
        path.line(to: NSPoint(x: 10, y: 7))
        path.line(to: NSPoint(x: 16, y: 7))
        path.close()
        Glass.ink.setFill()
        path.fill()
        NSColor.black.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1
        path.stroke()
        img.unlockFocus()
        return img
    }
}
#endif
