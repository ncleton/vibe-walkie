import XCTest
import RemoteCore
@testable import VibeWalkieiOS

final class GlobalButtonGridLayoutTests: XCTestCase {
    func testButtonCanMoveToBottomRightOfThirdRowAndLeaveItsOldSlotEmpty() throws {
        let available = ControlConfiguration.standard.availableGlobalButtons
        var slots = GlobalButtonGridLayout.resolvedSlots(storedIDs: [], availableButtons: available)
        let sourceIndex = try XCTUnwrap(slots.firstIndex(where: { $0?.id == "standard.right" }))

        slots.swapAt(sourceIndex, 11)
        let storedIDs = GlobalButtonGridLayout.storageIDs(from: slots)
        let restored = GlobalButtonGridLayout.resolvedSlots(
            storedIDs: storedIDs,
            availableButtons: available
        )

        XCTAssertNil(restored[sourceIndex])
        XCTAssertEqual(restored[11]?.id, "standard.right")
    }

    func testGridAlwaysExposesEmptyDropTargets() {
        let available = ControlConfiguration.standard.availableGlobalButtons
        let slots = GlobalButtonGridLayout.resolvedSlots(storedIDs: [], availableButtons: available)

        XCTAssertGreaterThanOrEqual(slots.count, 12)
        XCTAssertEqual(slots.count % 4, 0)
        XCTAssertTrue(slots.contains(where: { $0 == nil }))
    }

    func testRemoteCursorSelectionTrackerReportsRelativeCaretMovement() {
        var tracker = RemoteCursorSelectionTracker()
        tracker.reset(to: 256)

        XCTAssertEqual(tracker.movement(selectionStart: 249, selectionEnd: 249), -7)
        XCTAssertEqual(tracker.movement(selectionStart: 261, selectionEnd: 261), 12)
        XCTAssertNil(tracker.movement(selectionStart: 261, selectionEnd: 261))
    }

    func testRemoteCursorSelectionTrackerIgnoresTextSelections() {
        var tracker = RemoteCursorSelectionTracker()
        tracker.reset(to: 256)

        XCTAssertNil(tracker.movement(selectionStart: 250, selectionEnd: 256))
        XCTAssertEqual(tracker.previousOffset, 256)
    }

    func testRemoteCursorSelectionTrackerIgnoresUIKitFocusJump() {
        var tracker = RemoteCursorSelectionTracker()
        tracker.reset(to: 256)

        XCTAssertNil(tracker.movement(selectionStart: 513, selectionEnd: 513))
        XCTAssertEqual(tracker.previousOffset, 513)
    }

    func testHeldKeyRepeatAcceleratesToLargeBatches() {
        XCTAssertEqual(AcceleratingKeyRepeatPolicy.batchSize(forTick: -1), 1)
        XCTAssertEqual(AcceleratingKeyRepeatPolicy.batchSize(forTick: 0), 1)
        XCTAssertEqual(AcceleratingKeyRepeatPolicy.batchSize(forTick: 14), 2)
        XCTAssertEqual(AcceleratingKeyRepeatPolicy.batchSize(forTick: 28), 4)
        XCTAssertEqual(AcceleratingKeyRepeatPolicy.batchSize(forTick: 42), 8)
        XCTAssertEqual(AcceleratingKeyRepeatPolicy.batchSize(forTick: 56), 16)
        XCTAssertEqual(AcceleratingKeyRepeatPolicy.batchSize(forTick: 70), 32)
        XCTAssertEqual(AcceleratingKeyRepeatPolicy.batchSize(forTick: 10_000), 32)
    }
}
