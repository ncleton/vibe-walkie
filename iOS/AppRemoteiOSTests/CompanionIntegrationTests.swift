#if COMPANION_INTEGRATION
import SwiftUI
import XCTest
import RemoteCore
@testable import VibeWalkieiOS

/// Dedicated gate requiring a real, locally approved companion. The ordinary
/// unit-test build does not compile this gate; it cannot pass without its host.
@MainActor
final class CompanionIntegrationTests: XCTestCase {
    func testNativeClientControlsAndRendersTheLinuxDesktop() async throws {
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let qrFile = documents.appendingPathComponent("companion-integration-qr.txt")
        guard FileManager.default.fileExists(atPath: qrFile.path) else {
            XCTFail("Install the live host QR in the dedicated simulator Documents directory before running this gate.")
            return
        }
        let encoded = try String(contentsOf: qrFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let qr = try PairingQRPayload.decode(encoded)
        let client = HostConnectionClient()
        guard client.pairedHosts.isEmpty else {
            XCTFail("Use a dedicated simulator without personal paired hosts.")
            return
        }
        // A signed simulator executable gets its normal application identity.
        // Disabling signing also removes the entitlement needed for Keychain.
        do {
            _ = try DeviceKeyStore.loadOrCreatePrivateKey()
        } catch let error as NSError where error.code == -34018 {
            XCTFail("Keychain access requires CODE_SIGNING_ALLOWED=YES and CODE_SIGN_IDENTITY=- for this simulator gate.")
            return
        }
        defer {
            client.stopScreenStream()
            if let paired = client.pairedHosts.first(where: { $0.certificateFingerprint == qr.certificateFingerprint }) {
                client.forgetHost(paired.id)
            }
            client.disconnect()
            try? FileManager.default.removeItem(at: qrFile)
        }
        try client.pair(with: qr)
        for _ in 0..<600 where !client.state.isReady {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(client.state.isReady, "Native client failed to pair: \(client.state)")
        guard client.state.isReady else { return }
        XCTAssertEqual(client.connectedHostPlatform, .linux)
        let windows = try await client.send(type: .listWindows, payload: ListWindowsPayload())
            .decodePayload(WindowsSnapshotPayload.self)
        XCTAssertTrue(windows.applications.contains { app in
            app.windows.contains { $0.title.contains("integration editor") }
        })
        let dictationID = UUID()
        let started = try await client.send(type: .recordingStarted,
            payload: RecordingStartedPayload(locale: "fr-FR", dictationID: dictationID))
            .decodePayload(AcknowledgementPayload.self)
        let target = try XCTUnwrap(started.targetToken)
        let inserted = try await client.send(type: .insertText,
            payload: InsertTextPayload(targetToken: target.token, text: "Depuis le vrai client iPhone : été 🌍", dictationID: dictationID))
            .decodePayload(AcknowledgementPayload.self)
        XCTAssertTrue(inserted.insertion?.verified == true)
        client.startScreenStream(maxWidth: 1280, framesPerSecond: 4)
        for _ in 0..<100 where client.latestScreenFrame == nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        let frame = try XCTUnwrap(client.latestScreenFrame, "The native client did not receive a real JPEG frame.")
        XCTAssertNotNil(UIImage(data: frame.jpegData))
        let root = RemoteScreenView(dictation: DictationController(client: client))
            .environmentObject(client)
        let controller = UIHostingController(rootView: root)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 430, height: 900)
        controller.view.layoutIfNeeded()
        let picture = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: picture)
        attachment.name = "native-iphone-client-linux-screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
