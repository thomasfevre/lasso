import Foundation
import LassoCore

/// Resolves a collection-view hit into a Capture id without coupling the
/// opening gesture to selection callbacks or AppKit's transient current event.
public enum CaptureHistoryOpening {
    public static func captureID(at indexPath: IndexPath, dayGroups: [[Int64]]) -> Int64? {
        guard indexPath.count >= 2,
              dayGroups.indices.contains(indexPath.section),
              dayGroups[indexPath.section].indices.contains(indexPath.item) else { return nil }
        return dayGroups[indexPath.section][indexPath.item]
    }
}

/// Builds the detail lookup defensively: the selected Capture can already be
/// part of the active navigation window, so duplicate ids must not trap.
public enum CaptureDetailIndex {
    public static func make(_ captures: [Capture]) -> [Int64: Capture] {
        captures.reduce(into: [:]) { index, capture in index[capture.id] = capture }
    }
}
