import XCTest
import RemoteCore
@testable import VibeWalkieiOS

@MainActor
final class HostConfigurationTests: XCTestCase {
    func testPendingConfigurationCannotCrossHostBoundaries() throws {
        let suite = "WorkspaceConfigurationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HostControlConfigurationStore(defaults: defaults)
        try store.save(.standard, hostID: "mac-fingerprint", pending: true)
        try store.saveSlots(["mac-shortcut", nil], hostID: "mac-fingerprint")
        XCTAssertNotNil(try store.load(hostID: "mac-fingerprint").pending)
        XCTAssertEqual(try store.load(hostID: "mac-fingerprint").slotIDs, ["mac-shortcut", nil])
        XCTAssertNil(try store.load(hostID: "linux-fingerprint").pending)
        XCTAssertTrue(try store.load(hostID: "linux-fingerprint").slotIDs.isEmpty)
        XCTAssertNil(try store.load(hostID: "windows-fingerprint").pending)
        XCTAssertTrue(try store.load(hostID: "windows-fingerprint").slotIDs.isEmpty)
    }

    func testCorruptPendingMigrationPreservesOriginalDataForRecovery() throws {
        let suite = "WorkspaceConfigurationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let valid = try RemoteCoding.encoder.encode(ControlConfiguration.standard)
        let corrupt = Data("corrupt".utf8)
        defaults.set(valid, forKey: "controlConfiguration.v1")
        defaults.set(corrupt, forKey: "controlConfiguration.pending.v1")
        let store = HostControlConfigurationStore(defaults: defaults)
        XCTAssertThrowsError(try store.migrateLegacy(selectedHostID: "mac"))
        XCTAssertThrowsError(try store.migrateLegacy(selectedHostID: "mac"))
        XCTAssertEqual(defaults.data(forKey: "controlConfiguration.v1"), valid)
        XCTAssertEqual(defaults.data(forKey: "controlConfiguration.pending.v1"), corrupt)
        XCTAssertNil(defaults.data(forKey: "controlConfiguration.host.v2.mac"))
    }
}
