#if os(macOS)
import AppKit

/// Shared "liquid glass" design foundation for the Conductor's windows. One set
/// of tokens (spacing rhythm, radii, brand accent, type ramp) plus reusable
/// AppKit components so onboarding and the annotate prompt read as one premium
/// product. Glassmorphism only works with depth *behind* the glass, so the
/// window backing is a designed gradient environment (`GlassBackdrop`) that the
/// frosted panels (`GlassCard`) refract — not flat system chrome. Everything
/// adapts to light/dark.
enum Glass {
    // 8pt-based spacing rhythm.
    enum Space {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 12
        static let md: CGFloat = 18
        static let lg: CGFloat = 24
    }

    // Warm dark glass (single dark appearance, from the validated mockup): near-
    // black ground with warm/indigo glows, cream ink, an amber gradient for the
    // primary action, indigo for secondary accents, orange for highlights.

    /// Styling is committed to the dark warm look regardless of system appearance.
    static var isDark: Bool { true }

    static let ink   = NSColor(srgbRed: 0.957, green: 0.925, blue: 0.878, alpha: 1) // #f4ece0
    static let muted = NSColor(srgbRed: 0.718, green: 0.671, blue: 0.600, alpha: 1) // #b7ab99
    static let faint = NSColor(srgbRed: 0.498, green: 0.463, blue: 0.400, alpha: 1) // #7f7666
    static let ground = NSColor(srgbRed: 0.039, green: 0.039, blue: 0.051, alpha: 1) // #0a0a0d

    static let amberHi  = NSColor(srgbRed: 0.886, green: 0.733, blue: 0.490, alpha: 1) // #e2bb7d
    static let amberLo  = NSColor(srgbRed: 0.663, green: 0.467, blue: 0.247, alpha: 1) // #a9773f
    static let amberInk = NSColor(srgbRed: 0.141, green: 0.090, blue: 0.024, alpha: 1) // #241706
    static let indigoHi = NSColor(srgbRed: 0.290, green: 0.361, blue: 0.682, alpha: 1) // #4a5cae
    static let indigoLo = NSColor(srgbRed: 0.192, green: 0.247, blue: 0.494, alpha: 1) // #313f7e
    static let orange   = NSColor(srgbRed: 0.910, green: 0.463, blue: 0.227, alpha: 1) // #e8763a
    static let okGreen  = NSColor(srgbRed: 0.157, green: 0.784, blue: 0.471, alpha: 1) // #28c878
    /// Opaque dark fill for editable fields. Must be opaque so a moving text caret
    /// erases its previous position — a transparent layer-backed text view leaves
    /// the old caret painted (it looks stuck at the start of the text).
    static let fieldFill = NSColor(srgbRed: 0.086, green: 0.075, blue: 0.060, alpha: 1)

    /// Dark ink used for text on the bright amber pill.
    static let primaryInk = amberInk
    /// Amber focus-ring color.
    static func focus(dark: Bool) -> NSColor { amberHi.withAlphaComponent(0.7) }
    /// The two-stop gradient a pin is filled with: amber when active (selected),
    /// indigo otherwise — matching the mockup.
    static func pinColors(active: Bool) -> [CGColor] {
        active ? [amberHi.cgColor, amberLo.cgColor] : [indigoHi.cgColor, indigoLo.cgColor]
    }
    /// Legacy single-color accessor (kept for callers that want one swatch).
    static func pin(active: Bool, dark: Bool) -> NSColor { active ? amberHi : indigoHi }
    /// The pin's number — white reads on both fills.
    static func pinInk(dark: Bool) -> NSColor { .white }

    /// A shared field editor with a visible caret — returned from a window's
    /// `windowWillReturnFieldEditor` so every glass field edits with a legible
    /// insertion point regardless of the translucent background.
    static func makeFieldEditor() -> NSTextView {
        let tv = GlassFieldEditor()
        _ = tv.layoutManager  // force TextKit 1 so the classic caret (drawInsertionPoint
                              // + insertionPointColor) is used instead of the TextKit-2
                              // NSTextInsertionIndicator, which ignores our caret color.
        tv.isFieldEditor = true
        tv.insertionPointColor = caretColor(dark: isDark)
        tv.textColor = ink
        tv.drawsBackground = false
        return tv
    }

    /// Explicit cream caret color (a dynamic catalog color would be remapped by
    /// vibrancy / appearance and can vanish; a fixed color always reads).
    static func caretColor(dark: Bool) -> NSColor { ink }

    enum Font {
        static func title() -> NSFont { .systemFont(ofSize: 25, weight: .bold) }
        static func heading() -> NSFont { .systemFont(ofSize: 15, weight: .semibold) }
        static func body() -> NSFont { .systemFont(ofSize: 13, weight: .regular) }
        static func caption() -> NSFont { .systemFont(ofSize: 11.5, weight: .regular) }
        static func mono() -> NSFont { .monospacedSystemFont(ofSize: 11, weight: .regular) }
    }

    /// Hairline that separates glass from the ground without a hard outline.
    static func hairline(dark: Bool) -> NSColor {
        NSColor.white.withAlphaComponent(
            NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.24 : 0.09
        )
    }
}

/// A directional specular rim — the single biggest difference between cheap and
/// convincing hand-rolled liquid glass. Real glass catches light on its top-
/// leading edge and lets it fade around the curve; a flat uniform `borderColor`
/// reads as a drawn outline. Implemented as a gradient stroked along the rounded
/// rect via a shape-layer mask. Layer coords are y-up (AppKit, non-flipped), so
/// the top-leading corner is (0, 1).
final class GlassRim {
    let gradient = CAGradientLayer()
    private let mask = CAShapeLayer()
    private let radius: CGFloat
    private let width: CGFloat

    init(radius: CGFloat, width: CGFloat = 1) {
        self.radius = radius
        self.width = width
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        mask.fillColor = NSColor.clear.cgColor
        mask.strokeColor = NSColor.black.cgColor
        mask.lineWidth = width
        gradient.mask = mask
    }

    func layout(in bounds: CGRect) {
        gradient.frame = bounds
        mask.frame = bounds
        // Inset by half the stroke width so the rim sits fully inside the edge.
        let inset = bounds.insetBy(dx: width / 2, dy: width / 2)
        mask.path = CGPath(roundedRect: inset, cornerWidth: radius, cornerHeight: radius,
                           transform: nil)
    }

    func setColors(dark: Bool, focused: Bool = false) {
        // A defined edge, not a light wash: a bright specular highlight on the
        // top-leading, fading through transparent, to a subtle dark ambient edge
        // on the bottom-trailing. This reads as glass thickness rather than a pale
        // outline.
        let hi = focused ? 1.0 : (dark ? 0.5 : 0.85)
        gradient.colors = [
            NSColor.white.withAlphaComponent(hi).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.black.withAlphaComponent(dark ? 0.22 : 0.10).cgColor,
        ]
        gradient.locations = [0, 0.5, 1]
    }
}

/// The window backing: real Apple liquid-glass. A `.behindWindow` visual-effect
/// view blurs whatever is behind the window (the desktop / other apps), giving
/// an honest frosted-glass surface with no invented color or gradient. Neutral,
/// adapts to light/dark.
/// The window backing: a designed near-black ground with a warm glow (top-right)
/// and an indigo glow (bottom-left), the environment the glass panels sit on.
/// Opaque (no desktop show-through) — the warm-glass look depends on a controlled
/// dark field, not the user's wallpaper.
final class GlassBackdrop: NSView {
    private var displayOptionsObserver: NSObjectProtocol?

    override var isOpaque: Bool { true }
    override var allowsVibrancy: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.needsDisplay = true }
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Glass.ground.setFill()
        bounds.fill()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency else { return }
        drawGlow(center: CGPoint(x: bounds.maxX - bounds.width * 0.18, y: bounds.maxY - bounds.height * 0.06),
                 radius: bounds.width * 0.9,
                 color: NSColor(srgbRed: 0.47, green: 0.34, blue: 0.17, alpha: 1), peak: 0.30)
        drawGlow(center: CGPoint(x: bounds.minX + bounds.width * 0.12, y: bounds.minY + bounds.height * 0.06),
                 radius: bounds.width * 0.8,
                 color: NSColor(srgbRed: 0.16, green: 0.20, blue: 0.41, alpha: 1), peak: 0.32)
    }

    private func drawGlow(center: CGPoint, radius: CGFloat, color: NSColor, peak: CGFloat) {
        guard let gradient = NSGradient(colors: [color.withAlphaComponent(peak), color.withAlphaComponent(0)]) else { return }
        gradient.draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
    }
}

/// A neutral translucent panel that floats over the frosted backdrop — a sheet
/// of white glass. No second blur (avoids the stacked-vibrancy "fog"): a subtle
/// white fill over the blurred backing reads as brighter glass, with a hairline
/// edge, a brighter top rim, and a soft downward shadow for elevation.
final class GlassCard: NSView {
    private let surface = NSView()
    private let rim = GlassRim(radius: Glass.Radius.md)
    private let sheen = CAGradientLayer()   // faint diagonal light across the glass
    private var displayOptionsObserver: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        surface.wantsLayer = true
        surface.layer?.cornerRadius = Glass.Radius.md
        surface.layer?.cornerCurve = .continuous
        surface.layer?.masksToBounds = true
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        // Sheen sits above the fill but below any content added to `surface`.
        sheen.startPoint = CGPoint(x: 0, y: 1)   // top-leading (y-up layer coords)
        sheen.endPoint = CGPoint(x: 0.65, y: 0.15)
        surface.layer?.addSublayer(sheen)
        surface.layer?.addSublayer(rim.gradient)
        restyle()
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.restyle() }
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    deinit {
        if let displayOptionsObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
        }
    }

    /// Content is added here so it sits inside the rounded, clipped surface.
    var contentView: NSView { surface }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds,
                                   cornerWidth: Glass.Radius.md, cornerHeight: Glass.Radius.md,
                                   transform: nil)
        sheen.frame = surface.bounds
        rim.layout(in: surface.bounds)
    }

    private func restyle() {
        // A warm smoked-glass panel over the dark ground: a translucent warm fill,
        // a directional specular rim, and a faint diagonal sheen — no flat border.
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        surface.layer?.backgroundColor = NSColor(
            srgbRed: 0.118,
            green: 0.102,
            blue: 0.082,
            alpha: reduceTransparency ? 0.98 : (increaseContrast ? 0.72 : 0.55)
        ).cgColor
        sheen.colors = [
            NSColor.white.withAlphaComponent(reduceTransparency ? 0 : (increaseContrast ? 0.11 : 0.07)).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
        rim.setColors(dark: true, focused: increaseContrast)
        layer?.shadowOpacity = reduceTransparency ? 0 : 0.5
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// A pill-shaped text button, or a circular icon-only button, with hover/pressed
/// states drawn to match the glass system. Primary = accent-filled with a rim +
/// glow; secondary = translucent glass; plain = text/icon.
final class LassoButton: NSButton {
    enum Kind { case primary, secondary, destructive, plain }
    private static let iconButtonDiameter: CGFloat = 36

    private let kind: Kind
    private let onClick: () -> Void
    private let isIconOnly: Bool
    private var hovering = false
    private var pressed = false

    init(_ title: String, symbolName: String? = nil, accessibilityLabel: String? = nil,
         kind: Kind = .secondary, onClick: @escaping () -> Void) {
        self.kind = kind
        self.onClick = onClick
        self.isIconOnly = title.isEmpty && symbolName != nil
        super.init(frame: .zero)
        // This button is always positioned by a parent stack or explicit
        // constraints. Leaving the autoresizing mask on lets AppKit translate
        // its initial frame into a competing height constraint.
        translatesAutoresizingMaskIntoConstraints = false
        self.title = title
        if let symbolName { setSymbol(symbolName, accessibilityLabel: accessibilityLabel ?? title) }
        isBordered = false
        bezelStyle = .regularSquare
        wantsLayer = true
        layer?.masksToBounds = false
        contentTintColor = titleColor()
        target = self
        action = #selector(fire)
        font = .systemFont(ofSize: 13, weight: kind == .primary ? .semibold : .medium)
        if isIconOnly {
            setContentHuggingPriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .horizontal)
            // NSStackView can stretch a view when only its aspect ratio is
            // constrained. Pin both dimensions so history navigation remains a
            // 36 × 36 pt circle under every header height.
            widthAnchor.constraint(equalToConstant: Self.iconButtonDiameter).isActive = true
            heightAnchor.constraint(equalToConstant: Self.iconButtonDiameter).isActive = true
        }
        if kind == .primary {
            layer?.masksToBounds = false
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = 0.22
            layer?.shadowRadius = 7
            layer?.shadowOffset = CGSize(width: 0, height: -2)
        }
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    /// A selected secondary button (e.g. an active quick-tag chip) renders with
    /// the amber fill.
    var selected = false { didSet { needsDisplay = true } }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled ? 1 : 0.45
            needsDisplay = true
        }
    }

    func setSymbol(_ symbolName: String, accessibilityLabel: String) {
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        imagePosition = isIconOnly ? .imageOnly : .imageLeading
        // Keep a symbol and its label as one centered content group. The
        // default cell layout can otherwise pin the image left while
        // independently centering the title inside a custom-drawn pill.
        imageHugsTitle = !isIconOnly
        imageScaling = .scaleProportionallyDown
        setAccessibilityLabel(accessibilityLabel)
        toolTip = accessibilityLabel
        needsDisplay = true
    }

    /// AppKit gives standard buttons extra visual margins outside their alignment
    /// rect. That is useful for text controls, but it turns a constrained 36 pt
    /// icon button into a 36.5 × 41 pt drawing surface. Icon-only controls own
    /// their circular silhouette, so their alignment and drawing rects must be
    /// identical.
    override var alignmentRectInsets: NSEdgeInsets {
        isIconOnly ? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0) : super.alignmentRectInsets
    }

    override var intrinsicContentSize: NSSize {
        if isIconOnly {
            return NSSize(width: Self.iconButtonDiameter, height: Self.iconButtonDiameter)
        }
        var s = super.intrinsicContentSize
        s.height = 32
        s.width += Glass.Space.lg
        return s
    }

    override func layout() {
        super.layout()
        // AppKit can reuse an icon button while its enclosing stack changes
        // size. Keeping the layer geometry in sync prevents a square-looking
        // hit/background during those transitions; the custom path still draws
        // the soft continuous edge and the unmasked layer preserves shadows.
        layer?.cornerRadius = bounds.height / 2
        layer?.cornerCurve = .continuous
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        updatePressedPresentation()
        needsDisplay = true
        super.mouseDown(with: event)
        pressed = false
        updatePressedPresentation()
        needsDisplay = true
    }
    @objc private func fire() { onClick() }

    private func titleColor() -> NSColor {
        switch kind {
        case .primary: return Glass.amberInk       // dark ink on the amber pill
        case .secondary: return selected ? Glass.amberInk : Glass.ink
        case .destructive: return .systemRed
        case .plain: return Glass.muted
        }
    }

    /// A tiny physical press acknowledgement is enough for a desktop button.
    /// It starts at mouse-down, remains interruptible by AppKit's normal mouse
    /// tracking, and respects the system Reduce Motion setting.
    private func updatePressedPresentation() {
        guard let layer else { return }
        let transform = pressed && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? CATransform3DMakeScale(0.97, 0.97, 1)
            : CATransform3DIdentity
        CATransaction.begin()
        CATransaction.setAnimationDuration(pressed ? 0.08 : 0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        layer.transform = transform
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        // The radius is clamped to half of the shortest edge. This matters for
        // the circular history-navigation controls as well as text pills when
        // Auto Layout is resolving a transient frame.
        let radius = min(bounds.width, bounds.height) / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        switch kind {
        case .primary:
            // The warm amber pill: a diagonal amber gradient with a bright top rim.
            let hi = hovering ? Glass.amberHi.blended(withFraction: 0.12, of: .white)! : Glass.amberHi
            let lo = pressed ? Glass.amberLo.blended(withFraction: 0.15, of: .black)! : Glass.amberLo
            NSGradient(starting: hi, ending: lo)?.draw(in: path, angle: -60)
            NSColor.white.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
        case .secondary:
            if selected {
                NSGradient(starting: Glass.amberHi, ending: Glass.amberLo)?.draw(in: path, angle: -60)
                NSColor.white.withAlphaComponent(0.4).setStroke()
            } else {
                (hovering ? NSColor.white.withAlphaComponent(pressed ? 0.16 : 0.11)
                          : NSColor.white.withAlphaComponent(0.05)).setFill()
                path.fill()
                Glass.hairline(dark: true).setStroke()
            }
            path.lineWidth = 1
            path.stroke()
        case .destructive:
            NSColor.systemRed.withAlphaComponent(
                hovering ? (pressed ? 0.18 : 0.13) : 0.06
            ).setFill()
            path.fill()
            NSColor.systemRed.withAlphaComponent(hovering ? 0.65 : 0.38).setStroke()
            path.lineWidth = 1
            path.stroke()
        case .plain:
            if hovering {
                NSColor.white.withAlphaComponent(pressed ? 0.12 : 0.07).setFill()
                path.fill()
            }
        }
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: titleColor(),
            .font: font ?? .systemFont(ofSize: 13),
        ])
        contentTintColor = titleColor()
        super.draw(dirtyRect)
    }
}

/// The field editor used inside the glass windows. It opts out of vibrancy and
/// forces an explicit caret color at draw time so the insertion point stays
/// visible over the frosted `NSVisualEffectView` backdrop — where the default
/// dynamic caret color is otherwise blended away to nothing.
/// A label that never intercepts mouse events, so it can overlay an editable
/// view (as a placeholder) without swallowing the click that focuses it.
final class ClickThroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class GlassFieldEditor: NSTextView {
    override var allowsVibrancy: Bool { false }
    // No drawInsertionPoint override: it is also the erase path, and detouring it
    // on a layer-backed view left a painted caret stuck at the start. TextKit 1
    // (forced via layoutManager) + insertionPointColor render the caret correctly.
}

/// A rounded, borderless text field on a translucent surface with an accent
/// focus ring — the input style for the glass system.
final class GlassField: NSView, NSTextFieldDelegate {
    let field = NSTextField()
    private var focused = false
    private let well = CAGradientLayer()  // top inner shadow → "carved in" look
    private let rim = GlassRim(radius: Glass.Radius.sm)

    init(placeholder: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Glass.Radius.sm
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        well.startPoint = CGPoint(x: 0.5, y: 1)   // top (AppKit layer coords)
        well.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(well)
        layer?.addSublayer(rim.gradient)

        field.placeholderString = placeholder
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = Glass.ink
        field.font = Glass.Font.body()
        field.usesSingleLineMode = true
        (field.cell as? NSTextFieldCell)?.isScrollable = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            field.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Glass.Space.sm),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Glass.Space.sm),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    /// Opt this field's subtree out of the surrounding `NSVisualEffectView`
    /// vibrancy so the text and caret keep their real colors instead of being
    /// blended into the frosted backdrop.
    override var allowsVibrancy: Bool { false }

    var isEnabled: Bool {
        get { field.isEnabled }
        set { field.isEnabled = newValue; alphaValue = newValue ? 1 : 0.5 }
    }
    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    /// Put the insertion point at the end of the text — used after programmatically
    /// filling the field (e.g. loading a pin's note) so typing continues from the
    /// end rather than the start. Requires the field to be first responder.
    func moveCaretToEnd() {
        guard let editor = field.currentEditor() else { return }
        let end = (field.stringValue as NSString).length
        editor.selectedRange = NSRange(location: end, length: 0)
    }

    override func layout() {
        super.layout()
        well.frame = CGRect(x: 0, y: bounds.height - 10, width: bounds.width, height: 10)
        rim.layout(in: bounds)
    }

    private func restyle() {
        // Recessed translucent dark well carved into the warm panel + a soft top
        // inner shadow.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        let shade = NSColor.black.withAlphaComponent(0.34)
        well.colors = [shade.cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        // Specular rim, brightening on focus, plus a crisp amber focus ring.
        rim.setColors(dark: true, focused: focused)
        if focused {
            layer?.borderWidth = 2
            layer?.borderColor = Glass.focus(dark: true).cgColor
        } else {
            layer?.borderWidth = 0
        }
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        focused = true
        restyle()
        // The field editor exists now (unlike in becomeFirstResponder): give it a
        // caret color that stays visible on the translucent field.
        if let editor = obj.userInfo?["NSFieldEditor"] as? NSTextView {
            editor.insertionPointColor = Glass.caretColor(dark: Glass.isDark)
            editor.textColor = Glass.ink
            editor.drawsBackground = false
        }
    }
    func controlTextDidEndEditing(_ obj: Notification) { focused = false; restyle() }

    /// Fires on every keystroke so callers can persist edits live (no need to
    /// press Return), which avoids losing an uncommitted note when the selection
    /// changes underneath the field.
    var onChange: ((String) -> Void)?
    func controlTextDidChange(_ obj: Notification) { onChange?(field.stringValue) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// A multi-line variant of `GlassField`: a scrollable text view in the same
/// recessed warm well, with a placeholder overlay and an amber focus ring. Used
/// for the capture note so a long message stays fully readable and the field can
/// grow with the window.
final class GlassTextArea: NSView, NSTextViewDelegate {
    private let scroll = NSScrollView()
    let textView = GlassFieldEditor()
    private let placeholderLabel = ClickThroughLabel(labelWithString: "")
    private let rim = GlassRim(radius: Glass.Radius.sm)
    private var focused = false
    var onChange: ((String) -> Void)?

    init(placeholder: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = Glass.Radius.sm
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.addSublayer(rim.gradient)

        _ = textView.layoutManager  // force TextKit 1 so the caret honors our color
        textView.isFieldEditor = false
        textView.drawsBackground = false
        textView.textColor = Glass.ink
        textView.insertionPointColor = Glass.caretColor(dark: true)
        textView.font = Glass.Font.body()
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        // Proper programmatic text-view-in-scroll-view setup, otherwise the view
        // does not lay out or accept editing reliably (this was why the capture
        // note appeared to need a pin selected before it would take text).
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        placeholderLabel.stringValue = placeholder
        placeholderLabel.font = Glass.Font.body()
        placeholderLabel.textColor = Glass.faint
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        // Transparent text view again (for the translucent well look); the
        // placeholder is a ClickThroughLabel so it never blocks the focus click.
        addSubview(placeholderLabel)
        addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Glass.Space.sm),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Glass.Space.sm),
            placeholderLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Glass.Space.md),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 74),
        ])
        restyle()
    }
    required init?(coder: NSCoder) { fatalError("unused") }

    override var allowsVibrancy: Bool { false }

    var stringValue: String {
        get { textView.string }
        set { textView.string = newValue; syncPlaceholder() }
    }

    override func layout() {
        super.layout()
        rim.layout(in: bounds)
    }

    private func syncPlaceholder() { placeholderLabel.isHidden = !textView.string.isEmpty }

    func textDidChange(_ notification: Notification) {
        syncPlaceholder()
        onChange?(textView.string)
    }
    func textDidBeginEditing(_ notification: Notification) { focused = true; restyle() }
    func textDidEndEditing(_ notification: Notification) { focused = false; restyle() }

    private func restyle() {
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        rim.setColors(dark: true, focused: focused)
        layer?.borderWidth = focused ? 2 : 0
        layer?.borderColor = Glass.focus(dark: true).cgColor
        syncPlaceholder()
    }
}
#endif
