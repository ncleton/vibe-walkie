import XCTest
import RemoteCore
import Security
@testable import VibeWalkieMac

final class CommercializationConfigurationTests: XCTestCase {
    func testWorkingBundleIdentifierAndMinimumSystem() {
#if DEBUG
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.nicolascleton.viberemote.mac.debug")
#else
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.nicolascleton.viberemote.mac")
#endif
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String, "14.0")
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
            "VibeWalkieAppIcon"
        )
        XCTAssertNotEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    }

    func testBonjourAndSparkleConfigurationAreEmbedded() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String], ["_viberemote._tcp"])
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String)
        XCTAssertFalse(
            (Bundle.main.object(forInfoDictionaryKey: "NSScreenCaptureUsageDescription") as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            "https://app-remote.92.222.247.135.sslip.io/releases/macos/appcast.xml"
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            "Tx25YvoRGRZxtG4STjRt3c4HPfYvdeIcXIoq+M9AH78="
        )
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool, true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUAutomaticallyUpdate") as? Bool, true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUVerifyUpdateBeforeExtraction") as? Bool, true)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? Int, 14_400)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUEnableSystemProfiling") as? Bool, false)

        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = urlTypes?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertEqual(schemes, [UpdateRequest.scheme])
    }

    func testCameraEntitlementIsEmbedded() throws {
        let task = try XCTUnwrap(SecTaskCreateFromSelf(nil))
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.security.device.camera" as CFString,
            nil
        )
        XCTAssertEqual(value as? Bool, true)
    }

    func testImmediateUpdateCheckURLIsStrictlyScoped() throws {
        XCTAssertTrue(
            UpdateRequest.requestsImmediateCheck(
                try XCTUnwrap(URL(string: "\(UpdateRequest.scheme)://check-for-updates"))
            )
        )
        XCTAssertFalse(
            UpdateRequest.requestsImmediateCheck(
                try XCTUnwrap(URL(string: "vibewalkie-mac://anything-else"))
            )
        )
        XCTAssertFalse(
            UpdateRequest.requestsImmediateCheck(
                try XCTUnwrap(URL(string: "https://check-for-updates"))
            )
        )
    }

    func testUpdatePresentationStateExposesTheAvailableVersionAndProgress() {
        XCTAssertFalse(UpdatePresentationState.idle.isVisible)
        XCTAssertNil(UpdatePresentationState.idle.version)

        let available = UpdatePresentationState.available(version: "1.2.3")
        XCTAssertTrue(available.isVisible)
        XCTAssertEqual(available.version, "1.2.3")
        XCTAssertFalse(available.isBusy)

        let preparing = UpdatePresentationState.preparing(version: "1.2.3")
        XCTAssertTrue(preparing.isVisible)
        XCTAssertEqual(preparing.version, "1.2.3")
        XCTAssertTrue(preparing.isBusy)

        let installing = UpdatePresentationState.installing(version: "1.2.3")
        XCTAssertTrue(installing.isBusy)
    }

    func testPrivacyAndThirdPartyNoticesAreBundled() {
        XCTAssertNotNil(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        XCTAssertNotNil(Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"))
        XCTAssertNotNil(Bundle.main.url(forResource: "Apache-2.0", withExtension: "txt"))
        XCTAssertNotNil(Bundle.main.url(forResource: "Sparkle", withExtension: "txt"))
        XCTAssertNotNil(Bundle.main.url(forResource: "SwiftCrypto-NOTICE", withExtension: "txt"))
        XCTAssertNotNil(Bundle.main.url(forResource: "SwiftASN1-NOTICE", withExtension: "txt"))
        XCTAssertNotNil(Bundle.main.url(forResource: "SwiftCertificates-NOTICE", withExtension: "txt"))
    }

    func testTailscaleStatusExtractsOnlyAValidNomadEndpoint() throws {
        let data = Data(#"""
        {
          "BackendState": "Running",
          "Self": {
            "DNSName": "mac-vibe.tail123.ts.net.",
            "TailscaleIPs": ["fd7a:115c:a1e0::1", "100.101.22.8"]
          }
        }
        """#.utf8)

        let endpoint = try TailscaleCoordinator.endpoint(fromStatusJSON: data)
        XCTAssertEqual(endpoint?.magicDNSName, "mac-vibe.tail123.ts.net")
        XCTAssertEqual(endpoint?.ipv4Address, "100.101.22.8")
        XCTAssertEqual(endpoint?.port, 54_389)
    }

    func testTailscaleStatusRejectsStoppedOrPublicAddresses() throws {
        let stopped = Data(#"{"BackendState":"Stopped"}"#.utf8)
        XCTAssertNil(try TailscaleCoordinator.endpoint(fromStatusJSON: stopped))

        let publicAddress = Data(#"""
        {
          "BackendState": "Running",
          "Self": {
            "DNSName": "mac-vibe.tail123.ts.net",
            "TailscaleIPs": ["8.8.8.8"]
          }
        }
        """#.utf8)
        let endpoint = try TailscaleCoordinator.endpoint(fromStatusJSON: publicAddress)
        XCTAssertNil(endpoint?.ipv4Address)
        XCTAssertEqual(endpoint?.magicDNSName, "mac-vibe.tail123.ts.net")
    }
}
