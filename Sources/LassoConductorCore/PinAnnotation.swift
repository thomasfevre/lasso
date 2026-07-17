import Foundation
import LassoCore

// SPE-555: keyboard-first pin-drop annotation. This is the pure annotation state
// the AppKit panel drives — dropping numbered pins, moving them, noting them,
// undoing — kept platform-free so the index/coordinate/note rules unit-test
// without a UI. Coordinates are normalized to the image ([0,1], top-left origin),
// matching the Marker contract from SPE-554.
public struct PinAnnotationModel: Equatable {
    /// Upper bound on pins, matched to the 1–9 number-key affordance. Once
    /// reached, further drops are refused (the UI selects an existing pin instead
    /// of stacking a new one).
    public static let maxPins = 9

    public private(set) var markers: [Marker]

    public init(markers: [Marker] = []) {
        self.markers = markers
    }

    /// The number the next sequential pin will take (1-based, one past the max).
    public var nextIndex: Int {
        (markers.map(\.index).max() ?? 0) + 1
    }

    /// True once the pin cap is reached; the UI stops accepting new drops.
    public var isFull: Bool { markers.count >= Self.maxPins }

    /// Drops the next sequential pin at a point (clamped to the image bounds so a
    /// click on the very edge still yields a valid marker). Returns it.
    @discardableResult
    public mutating func drop(x: Double, y: Double) -> Marker {
        let marker = Marker(index: nextIndex, x: clamp(x), y: clamp(y))
        markers.append(marker)
        return marker
    }

    /// Places a specific pin number (the number-key path). If that pin already
    /// exists it moves, keeping its note; otherwise it is added. Markers stay
    /// sorted by index so the UI renders them in order.
    public mutating func place(index: Int, x: Double, y: Double) {
        let existingNote = markers.first { $0.index == index }?.note
        markers.removeAll { $0.index == index }
        markers.append(Marker(index: index, x: clamp(x), y: clamp(y), note: existingNote))
        markers.sort { $0.index < $1.index }
    }

    /// Sets (or clears) a pin's note. Blank/whitespace notes clear to nil so an
    /// empty field never persists an empty string. No-op for an unknown index.
    public mutating func setNote(index: Int, _ note: String?) {
        guard let i = markers.firstIndex(where: { $0.index == index }) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        markers[i].note = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Removes a specific pin by its number. Returns it, or nil for an unknown
    /// index. Remaining pins keep their numbers (gaps are allowed and refillable
    /// via the number keys).
    @discardableResult
    public mutating func remove(index: Int) -> Marker? {
        guard let removed = markers.first(where: { $0.index == index }) else { return nil }
        markers.removeAll { $0.index == index }
        return removed
    }

    /// Removes the most recently numbered pin (the highest index). Returns it, or
    /// nil when there is nothing to undo.
    @discardableResult
    public mutating func removeLast() -> Marker? {
        guard let maxIndex = markers.map(\.index).max() else { return nil }
        let removed = markers.first { $0.index == maxIndex }
        markers.removeAll { $0.index == maxIndex }
        return removed
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}

/// One-tap note presets that ride on top of pins as preset notes (SPE-555 /
/// SPE-553). No new contract — a quick-tag just fills a pin's `note`.
public enum QuickTags {
    public static let defaults: [String] = [
        "this element",
        "broken here",
        "wrong text",
        "should be here",
    ]
}
