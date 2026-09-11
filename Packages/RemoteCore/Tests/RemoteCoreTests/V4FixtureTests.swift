import Foundation
import Testing
@testable import RemoteCore

@Suite("Fixtures interopérables V4")
struct V4FixtureTests {
    private func fixture(_ name: String) throws -> Data {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../ProtocolFixtures/V4", isDirectory: true)
            .standardizedFileURL
        return try Data(contentsOf: directory.appendingPathComponent(name))
    }

    @Test("L'enveloppe Swift correspond octet pour octet à la fixture")
    func envelopeFixture() throws {
        let payload = try RemoteCoding.encoder.encode(KeyPressPayload(key: .enter))
        let envelope = RemoteEnvelope(
            type: .keyPress,
            messageID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            sessionID: "fixture-session",
            sequence: 1,
            sentAt: try #require(ISO8601DateFormatter().date(from: "2026-09-02T00:00:00Z")),
            payload: payload
        )
        let expected = String(decoding: try fixture("envelope-keypress.json"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(String(decoding: try RemoteCoding.encoder.encode(envelope), as: UTF8.self) == expected)
    }

    @Test("Le QR Windows est décodable par le modèle Swift")
    func windowsPairingFixture() throws {
        let raw = try fixture("pairing-qr-windows.json")
            .trimmingTrailingNewline()
        let payload = try PairingQRPayload.decode(raw.base64EncodedString())
        #expect(payload.version == 4)
        #expect(payload.hostName == "PC Bureau")
        #expect(payload.hostPlatform == .windows)
    }

    @Test("Le statut Windows annonce toutes les capacités")
    func windowsStatusFixture() throws {
        let status = try RemoteCoding.decoder.decode(
            ConnectionStatusPayload.self,
            from: fixture("connection-status-windows.json")
        )
        #expect(status.hostPlatform == .windows)
        #expect(status.capabilities == HostCapability.fullControl.sorted { $0.rawValue < $1.rawValue })
        #expect(status.acknowledgesPointerMoves == nil)
    }

    @Test("La palette de raccourcis hôte reste opaque et interopérable")
    func shortcutPaletteFixture() throws {
        let expected = String(decoding: try fixture("control-configuration-palette.json"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = try RemoteCoding.decoder.decode(ControlConfiguration.self, from: Data(expected.utf8))
        #expect(configuration.availableShortcuts?.map(\.id) == ["search", "focus-main"])
        #expect(String(decoding: try RemoteCoding.encoder.encode(configuration), as: UTF8.self) == expected)
    }

    @Test("Le préfixe TCP est un entier 32 bits big-endian")
    func framingFixture() throws {
        let fixture = try RemoteCoding.decoder.decode(FramingFixture.self, from: fixture("framing.json"))
        let framed = try MessageFramer.frame(fixture.body)
        #expect(framed.map { String(format: "%02x", $0) }.joined() == fixture.frameHex)
        #expect(fixture.body.count == fixture.bodyLength)
        #expect(ProtocolLimits.maxFrameBytes == fixture.maximumBodyBytes)
    }

    @Test("Les erreurs V4 partagées sont identiques")
    func errorsFixture() throws {
        let fixture = try RemoteCoding.decoder.decode(ErrorFixture.self, from: fixture("errors.json"))
        #expect(fixture.codes == [.versionMismatch, .unsupportedCapability, .inputUnavailable, .screenUnavailable, .secureTarget, .targetLost, .activationDenied, .rateLimited, .invalidControlConfiguration])
    }

    @Test("Une image JPEG/base64 reste interopérable")
    func screenFrameFixture() throws {
        let expected = String(decoding: try fixture("screen-frame.json"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let frame = try RemoteCoding.decoder.decode(ScreenFramePayload.self, from: Data(expected.utf8))
        #expect(frame.jpegData == Data([0xFF, 0xD8, 0xFF, 0xD9]))
        #expect(String(decoding: try RemoteCoding.encoder.encode(frame), as: UTF8.self) == expected)
    }

    @Test("La signature Ed25519 est identique sur les trois implémentations")
    func ed25519Fixture() throws {
        let value = try RemoteCoding.decoder.decode(SignatureFixture.self, from: fixture("signature-ed25519.json"))
        let expectedMessage = ChallengeSigner.message(
            nonce: value.nonce,
            deviceIdentifier: value.deviceIdentifier,
            pairingSecret: value.pairingSecret
        )
        #expect(expectedMessage == value.message)
        #expect(ChallengeSigner.verify(
            signature: value.signature,
            nonce: value.nonce,
            deviceIdentifier: value.deviceIdentifier,
            pairingSecret: value.pairingSecret,
            publicKeyRepresentation: value.publicKey
        ))
    }
}

private struct SignatureFixture: Decodable {
    let deviceIdentifier: String
    let message: Data
    let nonce: Data
    let pairingSecret: Data
    let publicKey: Data
    let signature: Data
}

private struct FramingFixture: Decodable {
    let body: Data
    let bodyLength: Int
    let frameHex: String
    let maximumBodyBytes: Int
}

private struct ErrorFixture: Decodable {
    let codes: [RemoteErrorCode]
}

private extension Data {
    func trimmingTrailingNewline() -> Data {
        var copy = self
        while copy.last == 0x0A || copy.last == 0x0D { copy.removeLast() }
        return copy
    }
}
