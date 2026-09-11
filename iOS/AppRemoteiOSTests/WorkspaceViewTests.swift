import SwiftUI
import XCTest
import RemoteCore
@testable import VibeWalkieiOS

@MainActor
final class WorkspaceViewTests: XCTestCase {
    /// Render the actual home view at representative viewport sizes. These are
    /// responsive-layout tests, not claims about an unavailable Duo simulator.
    func testHomeAtCompactAndExpandedSizes() async throws {
        let sizes: [(String, CGSize, UserInterfaceSizeClass)] = [
            ("closed-short", CGSize(width: 420, height: 620), .compact),
            ("closed-landscape", CGSize(width: 620, height: 420), .compact),
            ("open-landscape", CGSize(width: 900, height: 700), .regular),
            ("open-portrait", CGSize(width: 700, height: 900), .regular)
        ]
        for (name, size, sizeClass) in sizes {
            let client = HostConnectionClient()
            let root = RemoteHomeView(client: client)
                .environmentObject(client)
                .environment(\.horizontalSizeClass, sizeClass)
            let controller = UIHostingController(rootView: root)
            controller.loadViewIfNeeded()
            controller.view.frame = CGRect(origin: .zero, size: size)
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(size: size)
            let image = renderer.image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertEqual(image.size, size)
            let attachment = XCTAttachment(image: image)
            attachment.name = "workspace-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testScreenOwnershipPreventsDismissedViewStoppingAnotherStream() {
        let client = HostConnectionClient()
        let workspace = UUID()
        let fullScreen = UUID()
        client.startScreenStream(owner: workspace)
        client.startScreenStream(owner: fullScreen)
        client.reportStaleScreenStream(owner: workspace)
        XCTAssertNil(client.screenStreamStatus.detail)
        client.reportStaleScreenStream(owner: fullScreen)
        XCTAssertNotNil(client.screenStreamStatus.detail)
    }

    func testPendingConfigurationCannotCrossHostBoundaries() throws {
        let suite = "WorkspaceConfigurationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HostControlConfigurationStore(defaults: defaults)
        try store.save(.standard, hostID: "mac-fingerprint", pending: true)
        XCTAssertNotNil(try store.load(hostID: "mac-fingerprint").pending)
        XCTAssertNil(try store.load(hostID: "linux-fingerprint").pending)
        XCTAssertNil(try store.load(hostID: "windows-fingerprint").pending)
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
