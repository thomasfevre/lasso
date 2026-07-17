import XCTest
@testable import LassoCore

final class RetentionDurationTests: XCTestCase {
    func testSupportedDurationsMatchTheUserFacingPolicy() {
        XCTAssertEqual(
            RetentionDuration.supported,
            [.oneHour, .oneDay, .sevenDays, .thirtyDays, .ninetyDays]
        )
        XCTAssertEqual(RetentionDuration.sevenDays.seconds, 7 * 24 * 60 * 60)
        XCTAssertEqual(RetentionDuration.default, .sevenDays)
        XCTAssertEqual(Retention.default.duration, .sevenDays)
    }

    func testPersistedDurationAcceptsSupportedValuesAndRejectsStaleOnes() {
        XCTAssertEqual(
            RetentionDuration.persisted(seconds: RetentionDuration.thirtyDays.seconds),
            .thirtyDays
        )
        XCTAssertEqual(RetentionDuration.persisted(seconds: 42), .sevenDays)
        XCTAssertEqual(RetentionDuration.persisted(seconds: .nan), .sevenDays)
    }

    func testCustomDurationRequiresPositiveFiniteSeconds() {
        XCTAssertNil(RetentionDuration(seconds: 0))
        XCTAssertNil(RetentionDuration(seconds: -.infinity))
        XCTAssertEqual(RetentionDuration(seconds: 60)?.seconds, 60)
    }
}
