import XCTest
import RemoteCore
@testable import VibeWalkieiOS

@MainActor
final class CommercializationConfigurationTests: XCTestCase {
    func testForegroundReconnectOnlyRunsAfterRealBackgroundTransition() {
        var gate = ForegroundReconnectGate()

        XCTAssertFalse(gate.consumeReconnectOnActive())

        gate.didEnterBackground()
        XCTAssertTrue(gate.consumeReconnectOnActive())
        XCTAssertFalse(gate.consumeReconnectOnActive())
    }

    func testPremiumProductIdentifiersAreStable() {
        XCTAssertEqual(PurchaseManager.monthlyProductID, "app.vibewalkie.premium.monthly")
        XCTAssertEqual(PurchaseManager.yearlyProductID, "app.vibewalkie.premium.yearly")
        XCTAssertEqual(PurchaseManager.lifetimeProductID, "app.vibewalkie.premium.lifetime")
        XCTAssertEqual(Set(PurchaseManager.productIDs).count, 3)
    }

    func testWorkingBundleIdentifierAndFrenchPermissionCopy() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "app.vibewalkie")
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String)
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String)
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String)
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String)
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSHealthShareUsageDescription") as? String)
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSHealthUpdateUsageDescription") as? String)
    }

    func testBonjourAndEncryptionDeclarationsAreEmbedded() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String], ["_viberemote._tcp"])
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption") as? Bool, false)
    }

    func testPrivacyManifestIsBundled() {
        XCTAssertNotNil(Bundle.main.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
    }

    func testPairedMacV1StorageMigratesWithoutNomadEndpoint() throws {
        let legacy = Data(#"""
        {
          "name": "Mac de test",
          "serviceName": "VibeWalkie-Test",
          "certificateFingerprint": "fingerprint"
        }
        """#.utf8)
        let paired = try RemoteCoding.decoder.decode(PairedHost.self, from: legacy)
        XCTAssertEqual(paired.name, "Mac de test")
        XCTAssertNil(paired.nomadEndpoint)
    }

    func testPairedMacPersistsOnlyAValidTailscaleEndpoint() {
        let valid = NomadEndpoint(
            magicDNSName: "mac-vibe.tail123.ts.net",
            ipv4Address: "100.101.22.8"
        )
        let paired = PairedHost(
            name: "Mac de test",
            serviceName: "VibeWalkie-Test",
            certificateFingerprint: "fingerprint",
            nomadEndpoint: valid
        )
        XCTAssertEqual(paired.nomadEndpoint, valid)

        let invalid = NomadEndpoint(
            magicDNSName: "example.com",
            ipv4Address: "8.8.8.8"
        )
        let rejected = PairedHost(
            name: "Mac de test",
            serviceName: "VibeWalkie-Test",
            certificateFingerprint: "fingerprint",
            nomadEndpoint: invalid
        )
        XCTAssertNil(rejected.nomadEndpoint)
    }

    func testPairedMacStoreMigratesLegacySelection() throws {
        let defaults = try makeDefaults()
        let legacy = PairedHost(
            name: "Ancien Mac",
            serviceName: "VibeWalkie-Legacy",
            certificateFingerprint: "legacy-fingerprint"
        )
        defaults.set(
            try RemoteCoding.encoder.encode(legacy),
            forKey: "com.nicolascleton.viberemote.pairedHost"
        )

        let state = PairedHostStore.load(defaults: defaults)

        XCTAssertEqual(state.macs, [legacy])
        XCTAssertEqual(state.selectedHost, legacy)
        XCTAssertNil(defaults.data(forKey: "com.nicolascleton.viberemote.pairedHost"))
    }

    func testV2RegistryMigrationPreservesIdentityAndNomadRoute() throws {
        let defaults = try makeDefaults()
        let fingerprint = "preserved-certificate-fingerprint"
        let v2Registry = Data("""
        {
          "macs": [{
            "name": "Mac bureau",
            "serviceName": "VibeWalkie-Office",
            "certificateFingerprint": "\(fingerprint)",
            "nomadEndpoint": {
              "magicDNSName": "office.tail123.ts.net",
              "ipv4Address": "100.101.22.8",
              "port": 54389
            }
          }],
          "selectedMacID": "\(fingerprint)"
        }
        """.utf8)
        defaults.set(v2Registry, forKey: "com.nicolascleton.viberemote.pairedHosts.v2")

        let state = PairedHostStore.load(defaults: defaults)

        XCTAssertEqual(state.hosts.count, 1)
        XCTAssertEqual(state.selectedHostID, fingerprint)
        XCTAssertEqual(state.hosts[0].name, "Mac bureau")
        XCTAssertEqual(state.hosts[0].platform, .macOS)
        XCTAssertEqual(state.hosts[0].certificateFingerprint, fingerprint)
        XCTAssertEqual(
            state.hosts[0].nomadEndpoint,
            NomadEndpoint(magicDNSName: "office.tail123.ts.net", ipv4Address: "100.101.22.8")
        )
        XCTAssertNil(defaults.data(forKey: "com.nicolascleton.viberemote.pairedHosts.v2"))

        let persisted = try XCTUnwrap(defaults.data(forKey: "com.nicolascleton.viberemote.pairedHosts.v3"))
        let persistedState = try RemoteCoding.decoder.decode(PairedHostStore.State.self, from: persisted)
        XCTAssertEqual(persistedState, state)
    }

    func testPairedMacStoreAddsSelectsAndRemovesMacs() throws {
        let defaults = try makeDefaults()
        let office = PairedHost(
            name: "Mac bureau",
            serviceName: "VibeWalkie-Office",
            certificateFingerprint: "office-fingerprint"
        )
        let home = PairedHost(
            name: "Mac maison",
            serviceName: "VibeWalkie-Home",
            certificateFingerprint: "home-fingerprint"
        )

        _ = PairedHostStore.upsert(office, select: true, defaults: defaults)
        var state = PairedHostStore.upsert(home, select: false, defaults: defaults)
        XCTAssertEqual(state.macs, [office, home])
        XCTAssertEqual(state.selectedHost, office)

        state = PairedHostStore.select(home.id, defaults: defaults)
        XCTAssertEqual(state.selectedHost, home)

        state = PairedHostStore.remove(home.id, defaults: defaults)
        XCTAssertEqual(state.macs, [office])
        XCTAssertEqual(state.selectedHost, office)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "CommercializationConfigurationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw XCTSkip("Impossible de créer un domaine UserDefaults isolé")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
