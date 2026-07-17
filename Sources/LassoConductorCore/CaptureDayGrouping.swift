import Foundation
import LassoCore

/// Pure grouping input for the Photos-style History grid. Keeping the day
/// boundary rule out of AppKit makes chronology deterministic and testable.
public struct CaptureDayGroup: Sendable, Equatable {
    public let day: Date
    public let captureIDs: [Int64]
}

public enum CaptureDayGrouping {
    public static func grouped(_ captures: [Capture], calendar: Calendar = .current) -> [CaptureDayGroup] {
        let buckets = Dictionary(grouping: captures) { calendar.startOfDay(for: $0.createdAt) }
        return buckets.map { day, captures in
            CaptureDayGroup(day: day, captureIDs: captures.sorted { $0.id > $1.id }.map(\.id))
        }.sorted { $0.day > $1.day }
    }
}
