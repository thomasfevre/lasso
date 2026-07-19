import XCTest
@testable import LassoConductorCore

final class CaptureDisplayDateTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_784_465_040)

    func testDayHeaderIsAlwaysEnglish() {
        XCTAssertEqual(
            CaptureDisplayDate.dayHeader(instant, timeZone: TimeZone(secondsFromGMT: 0)!),
            "Sunday, July 19, 2026"
        )
    }

    func testThumbnailIsAlwaysEnglish() {
        XCTAssertEqual(
            CaptureDisplayDate.thumbnail(instant, timeZone: TimeZone(secondsFromGMT: 0)!),
            "Jul 19, 2026 at 12:44\u{202F}PM"
        )
    }

    func testDetailIncludesEnglishDateAndTime() {
        XCTAssertEqual(
            CaptureDisplayDate.detail(instant, timeZone: TimeZone(secondsFromGMT: 0)!),
            "Jul 19, 2026 at 12:44\u{202F}PM"
        )
    }
}
