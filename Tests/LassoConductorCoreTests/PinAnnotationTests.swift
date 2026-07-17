import XCTest
import LassoCore
@testable import LassoConductorCore

// SPE-555: pin annotation state machine.
final class PinAnnotationTests: XCTestCase {
    func testSequentialDropAssignsIncrementingIndices() {
        var model = PinAnnotationModel()
        XCTAssertEqual(model.nextIndex, 1)
        let a = model.drop(x: 0.1, y: 0.2)
        let b = model.drop(x: 0.3, y: 0.4)
        XCTAssertEqual(a.index, 1)
        XCTAssertEqual(b.index, 2)
        XCTAssertEqual(model.markers.count, 2)
    }

    func testDropClampsToImageBounds() {
        var model = PinAnnotationModel()
        let m = model.drop(x: 1.4, y: -0.2)
        XCTAssertEqual(m.x, 1)
        XCTAssertEqual(m.y, 0)
        XCTAssertTrue(m.isValid)
    }

    func testPlaceMovesExistingPinKeepingNote() {
        var model = PinAnnotationModel()
        model.drop(x: 0.1, y: 0.1)          // pin 1
        model.setNote(index: 1, "keep me")
        model.place(index: 1, x: 0.9, y: 0.8)
        XCTAssertEqual(model.markers.count, 1)
        XCTAssertEqual(model.markers[0].x, 0.9)
        XCTAssertEqual(model.markers[0].note, "keep me")
    }

    func testPlaceAddsWhenIndexIsNew() {
        var model = PinAnnotationModel()
        model.place(index: 3, x: 0.5, y: 0.5)
        XCTAssertEqual(model.markers.map(\.index), [3])
        XCTAssertEqual(model.nextIndex, 4)
    }

    func testMarkersStaySortedByIndex() {
        var model = PinAnnotationModel()
        model.place(index: 3, x: 0.5, y: 0.5)
        model.place(index: 1, x: 0.1, y: 0.1)
        model.place(index: 2, x: 0.2, y: 0.2)
        XCTAssertEqual(model.markers.map(\.index), [1, 2, 3])
    }

    func testSetNoteTrimsAndClearsBlank() {
        var model = PinAnnotationModel()
        model.drop(x: 0.1, y: 0.1)
        model.setNote(index: 1, "  hello  ")
        XCTAssertEqual(model.markers[0].note, "hello")
        model.setNote(index: 1, "   ")
        XCTAssertNil(model.markers[0].note)
    }

    func testSetNoteUnknownIndexIsNoOp() {
        var model = PinAnnotationModel()
        model.drop(x: 0.1, y: 0.1)
        model.setNote(index: 99, "nope")
        XCTAssertNil(model.markers[0].note)
    }

    func testRemoveLastRemovesHighestIndex() {
        var model = PinAnnotationModel()
        model.drop(x: 0.1, y: 0.1)  // 1
        model.drop(x: 0.2, y: 0.2)  // 2
        let removed = model.removeLast()
        XCTAssertEqual(removed?.index, 2)
        XCTAssertEqual(model.markers.map(\.index), [1])
        XCTAssertEqual(model.nextIndex, 2, "next pin reuses the freed number")
    }

    func testRemoveLastOnEmptyReturnsNil() {
        var model = PinAnnotationModel()
        XCTAssertNil(model.removeLast())
    }

    func testRemoveByIndexKeepsOtherPins() {
        var model = PinAnnotationModel()
        model.drop(x: 0.1, y: 0.1)  // 1
        model.drop(x: 0.2, y: 0.2)  // 2
        model.drop(x: 0.3, y: 0.3)  // 3
        let removed = model.remove(index: 2)
        XCTAssertEqual(removed?.index, 2)
        XCTAssertEqual(model.markers.map(\.index), [1, 3], "gap left by the removed pin")
    }

    func testRemoveUnknownIndexReturnsNil() {
        var model = PinAnnotationModel()
        model.drop(x: 0.1, y: 0.1)  // 1
        XCTAssertNil(model.remove(index: 5))
        XCTAssertEqual(model.markers.count, 1)
    }

    func testIsFullAtCap() {
        var model = PinAnnotationModel()
        for i in 0..<PinAnnotationModel.maxPins {
            XCTAssertFalse(model.isFull, "should not be full at \(i) pins")
            model.drop(x: 0.1, y: 0.1)
        }
        XCTAssertTrue(model.isFull)
        XCTAssertEqual(model.markers.count, PinAnnotationModel.maxPins)
    }

    func testProducedMarkersAreContractValid() {
        var model = PinAnnotationModel()
        model.drop(x: 0.0, y: 1.0)
        model.drop(x: 0.5, y: 0.5)
        XCTAssertTrue(model.markers.allSatisfy { $0.isValid })
        // Indices are unique, as the Store requires.
        XCTAssertEqual(Set(model.markers.map(\.index)).count, model.markers.count)
    }
}
