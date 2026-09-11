import CoreGraphics
import XCTest
@testable import VibeWalkieMac

final class RelativePointerIntegratorTests: XCTestCase {
    func testContinuousMovesUseLastPostedLocationWhenSystemPositionLags() {
        var integrator = RelativePointerIntegrator()

        let first = integrator.target(
            observedLocation: CGPoint(x: 100, y: 50),
            deltaX: 8,
            deltaY: 3,
            at: 10
        )
        let second = integrator.target(
            observedLocation: CGPoint(x: 100, y: 50),
            deltaX: 8,
            deltaY: 3,
            at: 10.008
        )

        XCTAssertEqual(first, CGPoint(x: 108, y: 53))
        XCTAssertEqual(second, CGPoint(x: 116, y: 56))
    }

    func testMoveResynchronizesWithObservedCursorAfterGesturePause() {
        var integrator = RelativePointerIntegrator()
        _ = integrator.target(
            observedLocation: CGPoint(x: 100, y: 50),
            deltaX: 8,
            deltaY: 3,
            at: 10
        )

        let resumed = integrator.target(
            observedLocation: CGPoint(x: 300, y: 200),
            deltaX: 4,
            deltaY: -2,
            at: 10 + RelativePointerIntegrator.continuityInterval + 0.001
        )

        XCTAssertEqual(resumed, CGPoint(x: 304, y: 198))
    }
}
