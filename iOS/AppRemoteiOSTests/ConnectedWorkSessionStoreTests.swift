import Foundation
import XCTest
@testable import VibeWalkieiOS

@MainActor
final class ConnectedWorkSessionStoreTests: XCTestCase {
    func testSessionRequiresForegroundAndReadyMac() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectedWorkSessionStore(fileURL: url)
        let start = Date(timeIntervalSince1970: 1_780_000_000)

        store.update(isAppActive: true, isConnectedToMac: false, at: start)
        store.update(
            isAppActive: false,
            isConnectedToMac: true,
            at: start.addingTimeInterval(10)
        )

        XCTAssertFalse(store.isTracking)
        XCTAssertTrue(store.intervals(since: start, now: start.addingTimeInterval(20)).isEmpty)
    }

    func testSessionClosesWhenConnectionStops() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectedWorkSessionStore(fileURL: url)
        let start = Date(timeIntervalSince1970: 1_780_000_000)

        store.update(isAppActive: true, isConnectedToMac: true, at: start)
        store.update(
            isAppActive: true,
            isConnectedToMac: false,
            at: start.addingTimeInterval(90)
        )

        let interval = try XCTUnwrap(
            store.intervals(since: start, now: start.addingTimeInterval(120)).first
        )
        XCTAssertEqual(interval.start, start)
        XCTAssertEqual(interval.end, start.addingTimeInterval(90))
        XCTAssertFalse(store.isTracking)
    }

    func testSessionClosesWhenAppLeavesForegroundAndPersists() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date(timeIntervalSince1970: 1_780_000_000)

        do {
            let store = ConnectedWorkSessionStore(fileURL: url)
            store.update(isAppActive: true, isConnectedToMac: true, at: start)
            store.update(
                isAppActive: false,
                isConnectedToMac: true,
                at: start.addingTimeInterval(45)
            )
        }

        let restored = ConnectedWorkSessionStore(fileURL: url)
        let interval = try XCTUnwrap(
            restored.intervals(since: start, now: start.addingTimeInterval(60)).first
        )
        XCTAssertEqual(interval, DateInterval(
            start: start,
            end: start.addingTimeInterval(45)
        ))
    }

    func testRepeatedReadyUpdatesDoNotRestartTheSession() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectedWorkSessionStore(fileURL: url)
        let start = Date(timeIntervalSince1970: 1_780_000_000)

        store.update(isAppActive: true, isConnectedToMac: true, at: start)
        store.update(
            isAppActive: true,
            isConnectedToMac: true,
            at: start.addingTimeInterval(30)
        )

        let interval = try XCTUnwrap(
            store.intervals(since: start, now: start.addingTimeInterval(60)).first
        )
        XCTAssertEqual(interval.start, start)
        XCTAssertEqual(interval.end, start.addingTimeInterval(60))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("connected-work-\(UUID().uuidString).json")
    }
}
