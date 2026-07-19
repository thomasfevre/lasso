import Foundation
import LassoCore

/// Loads the entries that can be rendered by History without letting one
/// unavailable image invalidate the rest of the library.
public enum CaptureHistoryLoading {
    public struct Resolved<Value> {
        public let capture: Capture
        public let value: Value?
    }

    /// Preserves every Capture even when its image cannot be loaded. History
    /// can render an unavailable-image placeholder while keeping the record
    /// selectable, inspectable, and deletable.
    public static func resolved<T>(_ captures: [Capture], load: (Capture) throws -> T?)
        -> [Resolved<T>] {
        captures.map { capture in
            do {
                return Resolved(capture: capture, value: try load(capture))
            } catch {
                return Resolved(capture: capture, value: nil)
            }
        }
    }

    public static func loadable<T>(_ captures: [Capture], load: (Capture) throws -> T?)
        -> [(Capture, T)] {
        resolved(captures, load: load).compactMap { result in
            guard let value = result.value else { return nil }
            return (result.capture, value)
        }
    }
}
