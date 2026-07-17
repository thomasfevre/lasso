#if os(macOS)
import AppKit

public struct CaptureGridInteractionResult: Equatable {
    public let selection: Set<IndexPath>
    public let openItem: IndexPath?

    public init(selection: Set<IndexPath>, openItem: IndexPath?) {
        self.selection = selection
        self.openItem = openItem
    }
}

/// Deterministic Photos-style grid interaction: click selects, Command-click
/// toggles membership, and double-click opens without destroying a batch
/// selection that already contains the item.
public enum CaptureGridInteraction {
    public static func resolve(current: Set<IndexPath>, clicked: IndexPath,
                               modifiers: NSEvent.ModifierFlags, clickCount: Int) -> CaptureGridInteractionResult {
        if clickCount >= 2 {
            return CaptureGridInteractionResult(
                selection: current.contains(clicked) ? current : [clicked],
                openItem: clicked
            )
        }
        if modifiers.contains(.command) {
            var selection = current
            if selection.contains(clicked) {
                selection.remove(clicked)
            } else {
                selection.insert(clicked)
            }
            return CaptureGridInteractionResult(selection: selection, openItem: nil)
        }
        return CaptureGridInteractionResult(selection: [clicked], openItem: nil)
    }
}

/// Mouse-event boundary owned by each thumbnail, ensuring that item subviews
/// cannot swallow selection or double-click gestures before History sees them.
open class CaptureGridItemView: NSView {
    public var onClick: ((NSEvent.ModifierFlags, Int) -> Void)?

    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    open override func mouseDown(with event: NSEvent) {
        onClick?(event.modifierFlags, event.clickCount)
    }
}
#endif
