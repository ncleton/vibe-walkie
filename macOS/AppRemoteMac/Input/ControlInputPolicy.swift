import Foundation
import RemoteCore

/// Validation pure des valeurs numériques reçues du réseau.
///
/// Les API CoreGraphics n'acceptent pas toutes les valeurs non finies de la
/// même manière. Le routeur les refuse donc avant de créer le moindre événement.
enum ControlInputPolicy {
    struct ScreenSettings: Equatable {
        let maxWidth: Int
        let framesPerSecond: Int
        let jpegQuality: Double

        func dimensions(displayWidth: Int, displayHeight: Int) -> (width: Int, height: Int) {
            guard displayWidth > 0, displayHeight > 0 else { return (2, 2) }
            let scale = min(1, Double(maxWidth) / Double(displayWidth))
            let width = max(2, Int(Double(displayWidth) * scale) / 2 * 2)
            let height = max(2, Int(Double(displayHeight) * scale) / 2 * 2)
            return (width, height)
        }
    }

    static func gestureDelta(_ value: Double) throws -> Double {
        guard value.isFinite else {
            throw RemoteErrorPayload(code: .protocolMismatch, detail: "coordonnée invalide")
        }
        return min(max(value, -600), 600)
    }

    static func normalizedCoordinate(_ value: Double) throws -> Double {
        guard value.isFinite else {
            throw RemoteErrorPayload(code: .protocolMismatch, detail: "coordonnée invalide")
        }
        return min(max(value, 0), 1)
    }

    static func clickCount(_ value: Int) -> Int {
        min(max(value, 1), 3)
    }

    static func keyRepeatCount(_ value: Int) -> Int {
        min(max(value, 1), 32)
    }

    static func screenSettings(for request: ScreenStreamRequestPayload) throws -> ScreenSettings {
        guard request.jpegQuality.isFinite else {
            throw RemoteErrorPayload(code: .protocolMismatch, detail: "qualité d’image invalide")
        }
        return ScreenSettings(
            maxWidth: min(max(request.maxWidth, 640), 1_920),
            framesPerSecond: min(max(request.framesPerSecond, 4), 20),
            jpegQuality: min(max(request.jpegQuality, 0.2), 0.8)
        )
    }
}
