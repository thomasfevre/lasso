import Foundation

/// Navigation order for an immutable set of captures. The newest capture is
/// always first; the detail UI owns loading the corresponding records.
public struct CaptureTimeline: Sendable, Equatable {
    private let idsNewestFirst: [Int64]

    public init(idsNewestFirst: [Int64]) {
        var seen = Set<Int64>()
        self.idsNewestFirst = idsNewestFirst.filter { seen.insert($0).inserted }
    }

    public var latestID: Int64? {
        idsNewestFirst.first
    }

    public func older(than id: Int64) -> Int64? {
        guard let index = idsNewestFirst.firstIndex(of: id) else { return nil }
        let nextIndex = idsNewestFirst.index(after: index)
        guard nextIndex < idsNewestFirst.endIndex else { return nil }
        return idsNewestFirst[nextIndex]
    }

    public func newer(than id: Int64) -> Int64? {
        guard let index = idsNewestFirst.firstIndex(of: id), index > idsNewestFirst.startIndex else {
            return nil
        }
        return idsNewestFirst[idsNewestFirst.index(before: index)]
    }
}
