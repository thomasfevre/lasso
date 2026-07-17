import XCTest
@testable import LassoConductorCore

final class TextLayoutClassifierTests: XCTestCase {
    func testClassifiesIdentifierHeavyIndentedTextAsCode() {
        let observations = [
            OCRTextObservation(text: "func fetchUser(user_id: String) throws -> User {", minX: 0.10),
            OCRTextObservation(text: "    let cacheKey = user_id.lowercased()", minX: 0.14),
            OCRTextObservation(text: "    return userCache[cacheKey]", minX: 0.14),
            OCRTextObservation(text: "}", minX: 0.10),
        ]

        XCTAssertEqual(TextLayoutClassifier.classify(observations), .code)
    }

    func testClassifiesNaturalLanguageAsProse() {
        let observations = [
            OCRTextObservation(
                text: "Use the settings panel to choose your preferred language.", minX: 0.10
            ),
            OCRTextObservation(
                text: "Changes are saved automatically for the next session.", minX: 0.10
            ),
        ]

        XCTAssertEqual(TextLayoutClassifier.classify(observations), .prose)
    }

    func testProseContainingAtIsNotMistakenForAStackTrace() {
        let observations = [
            OCRTextObservation(text: "Meet the team at noon to discuss the release."),
            OCRTextObservation(text: "The agenda will be shared before the meeting."),
        ]

        XCTAssertEqual(TextLayoutClassifier.classify(observations), .prose)
    }

    func testCodeSelectionPreservesUncorrectedIdentifiersInsteadOfCorrectedText() {
        let selection = OCRTextPolicy.select(
            classifiedLayout: .code,
            correctedText: "use Camel Case(user id)\nsnake case = true",
            uncorrectedText: "useCamelCase(user_id)\nsnake_case = true"
        )

        XCTAssertEqual(selection.text, "useCamelCase(user_id)\nsnake_case = true")
        XCTAssertEqual(selection.layoutHint, .code)
    }

    func testCodeSelectionFallsBackToCorrectedTextWhenUncorrectedPassIsEmpty() {
        let selection = OCRTextPolicy.select(
            classifiedLayout: .code,
            correctedText: "Configuration error",
            uncorrectedText: "  \n"
        )

        XCTAssertEqual(selection.text, "Configuration error")
        XCTAssertEqual(selection.layoutHint, .code)
    }

    func testProseSelectionKeepsCorrectedTextWithoutLayoutHint() {
        let selection = OCRTextPolicy.select(
            classifiedLayout: .prose,
            correctedText: "The corrected sentence.",
            uncorrectedText: "The corected sentence."
        )

        XCTAssertEqual(selection.text, "The corrected sentence.")
        XCTAssertNil(selection.layoutHint)
    }

    func testProseSelectionFallsBackToUncorrectedTextWhenCorrectedPassFails() {
        let selection = OCRTextPolicy.select(
            classifiedLayout: .prose,
            correctedText: nil,
            uncorrectedText: "Readable fallback text."
        )

        XCTAssertEqual(selection.text, "Readable fallback text.")
        XCTAssertNil(selection.layoutHint)
    }
}
