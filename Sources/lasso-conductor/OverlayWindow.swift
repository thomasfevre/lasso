#if os(macOS)
import AppKit

/// Drives the full-screen Overlay for one capture: shows one dimmed, borderless
/// window on every display and coordinates them as a single global Gesture.
/// `Escape` or a zero-size drag cancels (completion called with `nil`).
final class OverlayController {
    private let screens: [NSScreen]
    private var windows: [OverlayWindow] = []
    private var completion: ((CGRect?) -> Void)?
    private var startPoint: CGPoint?
    private var currentRect: CGRect?

    init(screens: [NSScreen]) {
        self.screens = screens
    }

    func begin(_ completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        windows = screens.map { screen in
            let window = OverlayWindow(screen: screen)
            window.selectionView.onStart = { [weak self] point in
                self?.startGesture(at: point)
            }
            window.selectionView.onDrag = { [weak self] point in
                self?.updateGesture(to: point)
            }
            window.selectionView.onFinish = { [weak self] point in
                self?.finishGesture(at: point)
            }
            window.selectionView.onCancel = { [weak self] in
                self?.finish(nil)
            }
            return window
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }

        // Give keyboard focus (notably Escape) to the display under the pointer,
        // preserving the single-display flow while every window remains active.
        let mouse = NSEvent.mouseLocation
        let keyWindow = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        keyWindow?.makeKey()
        keyWindow?.makeFirstResponder(keyWindow?.selectionView)
    }

    private func startGesture(at point: CGPoint) {
        windows.forEach { $0.selectionView.dismissHint() }
        startPoint = point
        currentRect = nil
        render(nil)
    }

    private func updateGesture(to point: CGPoint) {
        guard let start = startPoint else { return }
        let rect = CGRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y))
        currentRect = rect
        render(rect)
    }

    private func finishGesture(at point: CGPoint) {
        updateGesture(to: point)
        finish(currentRect)
    }

    private func render(_ globalRect: CGRect?) {
        for window in windows {
            let localRect = globalRect.flatMap { rect -> CGRect? in
                let visible = rect.intersection(window.frame)
                guard !visible.isNull, !visible.isEmpty else { return nil }
                return window.convertFromScreen(visible)
            }
            window.selectionView.selectionRect = localRect
        }
    }

    private func finish(_ globalRect: CGRect?) {
        guard completion != nil else { return }
        startPoint = nil
        currentRect = nil
        windows.forEach { $0.orderOut(nil) }
        windows = []
        let done = completion
        completion = nil
        done?(globalRect)
    }
}

/// Borderless, transparent, screen-saver-level window that owns the selection view.
final class OverlayWindow: NSWindow {
    let selectionView: SelectionView

    init(screen: NSScreen) {
        selectionView = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        // A clearly-visible dim so a first-time user knows capture mode is active
        // (0.12 was too faint to read as a mode change).
        backgroundColor = NSColor.black.withAlphaComponent(0.28)
        hasShadow = false
        ignoresMouseEvents = false
        contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
}

/// Tracks the drag and draws the selection marquee. Coordinates are the view's
/// global AppKit screen coordinates so a drag retained by its starting window
/// can continue across display boundaries.
final class SelectionView: NSView {
    var onStart: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onFinish: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    var selectionRect: CGRect? {
        didSet { needsDisplay = true }
    }

    /// A centered "you are in capture mode" hint, hidden as soon as the drag
    /// starts so it never sits under the selection.
    private let hint: NSView = SelectionView.makeHint()
    private var hintDismissed = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // The frame is fixed to the screen size and never changes, and bounds are
        // known now, so center the hint here rather than depending on a layout pass
        // firing before first display.
        hint.frame.origin = CGPoint(x: ((frameRect.width - hint.frame.width) / 2).rounded(),
                                    y: ((frameRect.height - hint.frame.height) / 2).rounded())
        addSubview(hint)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Hides the capture-mode hint. Driven by the controller so every display's
    /// hint clears together the moment the gesture starts, not just the one that
    /// received the mouseDown (a cross-display drag paints a selection on the others).
    func dismissHint() {
        guard !hintDismissed else { return }
        hintDismissed = true
        hint.isHidden = true
    }

    private static func makeHint() -> NSView {
        let text = NSTextField(labelWithString: "Drag to capture a region   ·   Esc to cancel")
        text.font = .systemFont(ofSize: 15, weight: .medium)
        text.textColor = .white
        text.alignment = .center
        text.sizeToFit()
        let pad = NSSize(width: 32, height: 18)
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: text.frame.width + pad.width,
                                             height: text.frame.height + pad.height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        container.layer?.cornerRadius = 11
        text.frame.origin = CGPoint(x: pad.width / 2, y: pad.height / 2)
        container.addSubview(text)
        return container
    }

    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        onStart?(globalPoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(globalPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        onFinish?(globalPoint(for: event))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let rect = selectionRect else { return }
        // Punch the selection clear of the dim so the user sees the real pixels.
        NSColor.clear.setFill()
        rect.fill(using: .copy)

        NSColor.systemRed.setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    private func globalPoint(for event: NSEvent) -> CGPoint {
        guard let window else { return NSEvent.mouseLocation }
        return window.convertToScreen(
            CGRect(origin: event.locationInWindow, size: .zero)).origin
    }
}
#endif
