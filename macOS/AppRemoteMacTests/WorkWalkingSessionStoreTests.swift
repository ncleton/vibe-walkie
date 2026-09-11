import Foundation
import XCTest
@testable import VibeWalkieMac

@MainActor
final class WorkWalkingSessionStoreTests: XCTestCase {
    func testConfirmedWalkingCreatesAnExportableCompensatedSession() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkWalkingSessionStore(fileURL: url)
        let start = Date(timeIntervalSince1970: 1_780_000_000)

        store.observe(.walking, at: start)
        store.observe(.walking, at: start.addingTimeInterval(9))
        store.observe(.stationary, at: start.addingTimeInterval(14))

        let session = try XCTUnwrap(store.snapshot(since: start.addingTimeInterval(-60)).sessions.first)
        XCTAssertEqual(session.startedAt, start.addingTimeInterval(-3))
        XCTAssertEqual(session.endedAt, start.addingTimeInterval(9))
        XCTAssertEqual(session.duration, 12, accuracy: 0.01)
        XCTAssertFalse(session.isOngoing)
    }

    func testSnapshotIncludesAnActiveSessionWithoutClosingIt() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = WorkWalkingSessionStore(fileURL: url)
        let start = Date(timeIntervalSince1970: 1_780_000_000)

        store.observe(.walking, at: start)
        store.observe(.walking, at: start.addingTimeInterval(30))

        let session = try XCTUnwrap(
            store.snapshot(
                since: start.addingTimeInterval(-60),
                now: start.addingTimeInterval(31)
            ).sessions.first
        )
        XCTAssertTrue(session.isOngoing)
        XCTAssertEqual(session.endedAt, start.addingTimeInterval(31))
        XCTAssertTrue(store.isWalking)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("work-walking-\(UUID().uuidString).json")
    }
}
