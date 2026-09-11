import AppKit
import XCTest
@testable import VibeWalkieMac

final class PostureWindowPlacementTests: XCTestCase {
    func testFullHealthWindowIsCenteredInTheVisibleScreen() {
        let visibleFrame = NSRect(x: 100, y: 80, width: 1_440, height: 900)

        let frame = PostureWindowPlacement.centeredFullFrame(visibleFrame: visibleFrame)

        XCTAssertEqual(frame.size, NSSize(width: 960, height: 720))
        XCTAssertEqual(frame.midX, visibleFrame.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, visibleFrame.midY, accuracy: 0.001)
    }

    func testFullHealthWindowFitsACompactVisibleScreen() {
        let visibleFrame = NSRect(x: 0, y: 25, width: 820, height: 650)

        let frame = PostureWindowPlacement.centeredFullFrame(
            preferredSize: NSSize(width: 1_600, height: 1_200),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.width, 772, accuracy: 0.001)
        XCTAssertEqual(frame.height, 602, accuracy: 0.001)
        XCTAssertEqual(frame.midX, visibleFrame.midX, accuracy: 0.001)
        XCTAssertEqual(frame.midY, visibleFrame.midY, accuracy: 0.001)
    }
}
