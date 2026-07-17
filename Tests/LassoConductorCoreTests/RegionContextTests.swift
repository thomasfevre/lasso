import XCTest
import LassoCore
@testable import LassoConductorCore

// SPE-546: Region Context source-selection policy.
final class RegionContextTests: XCTestCase {
    func testAccessibilityWinsWhenPresent() {
        let c = RegionContextResolver.resolve(
            accessibilityText: "Save",
            ocrText: "useCamelCase(user_id)",
            layout: .code
        )
        XCTAssertEqual(c.source, .accessibility)
        XCTAssertEqual(c.text, "Save")
        XCTAssertNil(c.layout)
    }

    func testOCRUsedWhenNoAccessibilityText() {
        let c = RegionContextResolver.resolve(accessibilityText: nil, ocrText: "Checkout")
        XCTAssertEqual(c.source, .ocr)
        XCTAssertEqual(c.text, "Checkout")
    }

    func testCodeOCRLayoutHintIsCarriedIntoContext() {
        let c = RegionContextResolver.resolve(
            accessibilityText: nil,
            ocrText: "useCamelCase(user_id)",
            layout: .code
        )

        XCTAssertEqual(c.source, .ocr)
        XCTAssertEqual(c.layout, .code)
    }

    func testCodeOCRPreservesLeadingWhitespaceAndLineStructure() {
        let text = "    useCamelCase(user_id)\n  snake_case = true\n"
        let c = RegionContextResolver.resolve(
            accessibilityText: nil,
            ocrText: text,
            layout: .code
        )

        XCTAssertEqual(c.text, text)
    }

    func testNoneWhenNothingExtracted() {
        let c = RegionContextResolver.resolve(accessibilityText: nil, ocrText: nil)
        XCTAssertEqual(c.source, .none)
        XCTAssertNil(c.text)
    }

    func testBlankCandidatesTreatedAsEmpty() {
        let c = RegionContextResolver.resolve(accessibilityText: "   \n", ocrText: "  ")
        XCTAssertEqual(c.source, .none)
        XCTAssertNil(c.text)
    }

    func testFallsThroughBlankAccessibilityToOCR() {
        let c = RegionContextResolver.resolve(accessibilityText: "  ", ocrText: "readable")
        XCTAssertEqual(c.source, .ocr)
        XCTAssertEqual(c.text, "readable")
    }

    func testTextIsTrimmed() {
        let c = RegionContextResolver.resolve(accessibilityText: "  padded label \n", ocrText: nil)
        XCTAssertEqual(c.text, "padded label")
    }
}
