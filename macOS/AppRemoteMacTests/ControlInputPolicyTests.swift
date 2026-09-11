import XCTest
import RemoteCore
@testable import VibeWalkieMac

final class ControlInputPolicyTests: XCTestCase {
    func testGestureDeltasAreBounded() throws {
        XCTAssertEqual(try ControlInputPolicy.gestureDelta(-9_000), -600)
        XCTAssertEqual(try ControlInputPolicy.gestureDelta(9_000), 600)
        XCTAssertEqual(try ControlInputPolicy.gestureDelta(42.5), 42.5)
    }

    func testNonFiniteGestureDeltasAreRejected() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try ControlInputPolicy.gestureDelta(value))
        }
    }

    func testNormalizedCoordinatesAreFiniteAndBounded() throws {
        XCTAssertEqual(try ControlInputPolicy.normalizedCoordinate(-1), 0)
        XCTAssertEqual(try ControlInputPolicy.normalizedCoordinate(2), 1)
        XCTAssertThrowsError(try ControlInputPolicy.normalizedCoordinate(.nan))
    }

    func testClickCountIsLimitedToOneThroughThree() {
        XCTAssertEqual(ControlInputPolicy.clickCount(-4), 1)
        XCTAssertEqual(ControlInputPolicy.clickCount(2), 2)
        XCTAssertEqual(ControlInputPolicy.clickCount(99), 3)
    }

    func testKeyRepeatCountIsLimitedToSafeBatches() {
        XCTAssertEqual(ControlInputPolicy.keyRepeatCount(-4), 1)
        XCTAssertEqual(ControlInputPolicy.keyRepeatCount(12), 12)
        XCTAssertEqual(ControlInputPolicy.keyRepeatCount(99), 32)
    }

    func testScreenSettingsAreBounded() throws {
        let settings = try ControlInputPolicy.screenSettings(for: .init(
            enabled: true,
            maxWidth: 20_000,
            framesPerSecond: 200,
            jpegQuality: 9
        ))
        XCTAssertEqual(settings.maxWidth, 1_920)
        XCTAssertEqual(settings.framesPerSecond, 20)
        XCTAssertEqual(settings.jpegQuality, 0.8)
    }

    func testScreenDimensionsPreserveAspectAndAreEven() throws {
        let settings = try ControlInputPolicy.screenSettings(for: .init(
            enabled: true,
            maxWidth: 1_280,
            framesPerSecond: 10,
            jpegQuality: 0.45
        ))
        let dimensions = settings.dimensions(displayWidth: 2_560, displayHeight: 1_600)
        XCTAssertEqual(dimensions.width, 1_280)
        XCTAssertEqual(dimensions.height, 800)
        XCTAssertEqual(dimensions.width % 2, 0)
        XCTAssertEqual(dimensions.height % 2, 0)
    }

    func testNonFiniteJPEGQualityIsRejected() {
        XCTAssertThrowsError(try ControlInputPolicy.screenSettings(for: .init(
            enabled: true,
            jpegQuality: .nan
        )))
    }

    @MainActor
    func testScreenSharingUsesPhysicalKeyboardEvents() {
        XCTAssertTrue(CGEventFactory.requiresPhysicalKeyboardEvents(
            bundleIdentifier: "com.apple.ScreenSharing"
        ))
        XCTAssertTrue(CGEventFactory.requiresPhysicalKeyboardEvents(
            bundleIdentifier: "COM.APPLE.SCREENSHARING"
        ))
        XCTAssertFalse(CGEventFactory.requiresPhysicalKeyboardEvents(
            bundleIdentifier: "com.google.Chrome"
        ))
        XCTAssertFalse(CGEventFactory.requiresPhysicalKeyboardEvents(bundleIdentifier: nil))
    }

    @MainActor
    func testPhysicalKeyboardTranslationDoesNotReuseOneKeyForEveryCharacter() throws {
        let strokes = try XCTUnwrap(CGEventFactory.physicalKeystrokes(for: "abc ABC 123"))

        XCTAssertEqual(strokes.count, 11)
        XCTAssertGreaterThan(Set(strokes.map(\.keyCode)).count, 3)
        XCTAssertTrue(strokes.contains { $0.flags.contains(.maskShift) })
        XCTAssertNotNil(CGEventFactory.physicalKeystrokes(
            for: "J’aimerais être à l’écran."
        ))
        XCTAssertNil(CGEventFactory.physicalKeystrokes(for: "🙂"))
    }

    func testVoiceControlOnlyMatchesExplicitVoiceButtons() {
        XCTAssertEqual(
            AIVoiceControlLabelPolicy.beganScore(for: "Démarrer une conversation vocale"),
            1
        )
        XCTAssertEqual(
            AIVoiceControlLabelPolicy.beganScore(for: "Démarrer un nouveau chat vocal"),
            1
        )
        XCTAssertEqual(
            AIVoiceControlLabelPolicy.beganScore(for: "Start a new voice chat"),
            1
        )
        XCTAssertEqual(
            AIVoiceControlLabelPolicy.beganScore(for: "Unmute microphone"),
            0
        )
        XCTAssertEqual(
            AIVoiceControlLabelPolicy.endedScore(for: "Couper le microphone"),
            0
        )
        XCTAssertEqual(
            AIVoiceControlLabelPolicy.endedScore(for: "End voice chat"),
            1
        )
        XCTAssertNil(
            AIVoiceControlLabelPolicy.beganScore(for: "Désactiver le microphone")
        )
        XCTAssertNil(
            AIVoiceControlLabelPolicy.endedScore(for: "Activer le microphone")
        )
        XCTAssertNil(
            AIVoiceControlLabelPolicy.endedScore(for: "Unmute microphone")
        )
        XCTAssertNil(AIVoiceControlLabelPolicy.beganScore(for: "Envoyer le message"))
        XCTAssertNil(AIVoiceControlLabelPolicy.endedScore(for: "Stop"))
    }
}
