import Foundation
import RemoteCore
import XCTest
@testable import VibeWalkieMac

@MainActor
final class HealthSessionRouterTests: XCTestCase {
    func testPointerMoveIsAcknowledgedOnlyAfterRouting() throws {
        let envelope = try RemoteEnvelope.make(
            type: .pointerMove,
            sessionID: "pointer-test",
            sequence: 1,
            payload: PointerMovePayload(deltaX: 4, deltaY: -3)
        )
        let router = SessionRouter(peerID: "iphone-test", sessionID: "pointer-test")

        switch router.handle(envelope) {
        case .gestureAcknowledged:
            break
        default:
            XCTFail("Le Mac doit confirmer chaque déplacement après son injection")
        }
    }

    func testAuthenticatedRouterDecodesWalkingSessionRequest() throws {
        let since = Date(timeIntervalSince1970: 1_780_000_000)
        let envelope = try RemoteEnvelope.make(
            type: .workWalkingSessionsRequest,
            sessionID: "health-test",
            sequence: 1,
            payload: WorkWalkingSessionsRequestPayload(since: since)
        )
        let router = SessionRouter(peerID: "iphone-test", sessionID: "health-test")

        switch router.handle(envelope) {
        case .workWalkingSessionsRequest(let decodedSince):
            XCTAssertEqual(decodedSince, since)
        default:
            XCTFail("Le routeur doit transmettre la borne de synchronisation Santé")
        }
    }

    func testMalformedWalkingSessionRequestFailsClosed() {
        let envelope = RemoteEnvelope(
            type: .workWalkingSessionsRequest,
            sessionID: "health-test",
            sequence: 1,
            payload: Data("{}".utf8)
        )
        let router = SessionRouter(peerID: "iphone-test", sessionID: "health-test")

        switch router.handle(envelope) {
        case .failure(let error):
            XCTAssertEqual(error.code, .internalFailure)
        default:
            XCTFail("Une demande Santé malformée doit être rejetée")
        }
    }

    func testAuthenticatedRouterDecodesHealthActivitySnapshot() throws {
        let payload = HealthActivitySnapshotPayload(
            briskWalkingMinutesLast7Days: 210,
            walkingDistanceMetersLast7Days: 8_400,
            detectedWalkingDurationLast7Days: 18_000
        )
        let envelope = try RemoteEnvelope.make(
            type: .healthActivitySnapshotUpdate,
            sessionID: "health-test",
            sequence: 1,
            payload: payload
        )
        let router = SessionRouter(peerID: "iphone-test", sessionID: "health-test")

        switch router.handle(envelope) {
        case .healthActivitySnapshotUpdate(let decoded):
            XCTAssertEqual(
                decoded.briskWalkingMinutesLast7Days,
                payload.briskWalkingMinutesLast7Days
            )
            XCTAssertEqual(
                decoded.walkingDistanceMetersLast7Days,
                payload.walkingDistanceMetersLast7Days
            )
            XCTAssertEqual(
                decoded.detectedWalkingDurationLast7Days,
                payload.detectedWalkingDurationLast7Days
            )
            XCTAssertEqual(
                decoded.capturedAt.timeIntervalSince(payload.capturedAt),
                0,
                accuracy: 1
            )
        default:
            XCTFail("Le routeur doit transmettre le résumé HealthKit agrégé")
        }
    }

    func testInvalidHealthActivitySnapshotFailsClosed() throws {
        let payload = HealthActivitySnapshotPayload(
            briskWalkingMinutesLast7Days: 10_081,
            walkingDistanceMetersLast7Days: 1_000,
            detectedWalkingDurationLast7Days: 3_600
        )
        let envelope = try RemoteEnvelope.make(
            type: .healthActivitySnapshotUpdate,
            sessionID: "health-test",
            sequence: 1,
            payload: payload
        )
        let router = SessionRouter(peerID: "iphone-test", sessionID: "health-test")

        switch router.handle(envelope) {
        case .failure(let error):
            XCTAssertEqual(error.code, .protocolMismatch)
        default:
            XCTFail("Un résumé Santé hors limites doit être rejeté")
        }
    }
}
