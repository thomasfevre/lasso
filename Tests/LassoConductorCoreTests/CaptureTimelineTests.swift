import XCTest
@testable import LassoConductorCore
import LassoCore

final class CaptureTimelineTests: XCTestCase {
    func testStartsAtNewestCapture() {
        let timeline = CaptureTimeline(idsNewestFirst: [9, 7, 2])

        XCTAssertEqual(timeline.latestID, 9)
    }

    func testNavigatesOlderAndNewerWithoutReorderingCaptures() {
        let timeline = CaptureTimeline(idsNewestFirst: [9, 7, 2])

        XCTAssertEqual(timeline.older(than: 9), 7)
        XCTAssertEqual(timeline.older(than: 7), 2)
        XCTAssertNil(timeline.older(than: 2))
        XCTAssertEqual(timeline.newer(than: 2), 7)
        XCTAssertEqual(timeline.newer(than: 7), 9)
        XCTAssertNil(timeline.newer(than: 9))
    }

    func testMissingCaptureHasNoNavigationTarget() {
        let timeline = CaptureTimeline(idsNewestFirst: [9])

        XCTAssertNil(timeline.older(than: 999))
        XCTAssertNil(timeline.newer(than: 999))
    }
}

final class CaptureDayGroupingTests: XCTestCase {
    func testGroupsNewestFirstAndKeepsNewestCaptureFirstWithinDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayOne = Date(timeIntervalSince1970: 1_700_000_000)
        let dayTwo = calendar.date(byAdding: .day, value: 1, to: dayOne)!
        let captures = [
            Capture(id: 2, createdAt: dayOne, imageFile: "2.png", note: nil, context: CaptureContext()),
            Capture(id: 3, createdAt: dayTwo, imageFile: "3.png", note: nil, context: CaptureContext()),
            Capture(id: 1, createdAt: dayOne, imageFile: "1.png", note: nil, context: CaptureContext()),
        ]

        let groups = CaptureDayGrouping.grouped(captures, calendar: calendar)

        XCTAssertEqual(groups.map(\.captureIDs), [[3], [2, 1]])
    }
}

final class CaptureHistoryOpeningTests: XCTestCase {
    func testResolvesCaptureAtDoubleClickedGridPosition() {
        XCTAssertEqual(CaptureHistoryOpening.captureID(at: IndexPath(item: 1, section: 0), dayGroups: [[9, 7], [2]]), 7)
        XCTAssertEqual(CaptureHistoryOpening.captureID(at: IndexPath(item: 0, section: 1), dayGroups: [[9, 7], [2]]), 2)
    }

    func testRejectsStaleOrOutOfRangeGridPositions() {
        XCTAssertNil(CaptureHistoryOpening.captureID(at: IndexPath(item: 3, section: 0), dayGroups: [[9, 7]]))
        XCTAssertNil(CaptureHistoryOpening.captureID(at: IndexPath(item: 0, section: 1), dayGroups: [[9, 7]]))
    }
}

final class CaptureDetailIndexTests: XCTestCase {
    func testSelectedCaptureCanAppearTwiceWithoutTrapping() {
        let active = Capture(id: 7, createdAt: .distantPast, imageFile: "7.png", note: "active", context: CaptureContext())
        let selected = Capture(id: 7, createdAt: .distantFuture, imageFile: "7.png", note: "selected", context: CaptureContext())

        XCTAssertEqual(CaptureDetailIndex.make([active, selected])[7]?.note, "selected")
    }
}
