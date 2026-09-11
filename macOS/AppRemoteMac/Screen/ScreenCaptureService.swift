import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit
import RemoteCore

enum ScreenCaptureServiceError: LocalizedError {
    case permissionDenied
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return MacL10n.text("mac.allow.screen.recording.on.the.mac.then.relaunch.vibe.walkie.634232c")
        case .noDisplay:
            return MacL10n.text("mac.the.mac.screen.is.locked.or.unavailable.unlock.the.mac.ee3612b")
        }
    }
}

/// Capture l'écran principal et produit des JPEG bornés, faciles à transmettre
/// sur la connexion TLS existante. La file dédiée et le saut de frames évitent
/// que l'encodage d'image ne ralentisse les commandes souris/clavier.
final class ScreenCaptureService: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // L'encodage JPEG ne doit jamais rivaliser avec l'injection souris sur le
    // thread interactif. Une image peut attendre quelques millisecondes ; le
    // pointeur, lui, doit rester prioritaire.
    private let frameQueue = DispatchQueue(
        label: "com.nicolascleton.viberemote.screen",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var stream: SCStream?
    private var powerActivity: NSObjectProtocol?
    private var frameHandler: (@Sendable (ScreenFramePayload) -> Void)?
    private var stoppedHandler: (@Sendable (Error) -> Void)?
    private var jpegQuality = 0.45
    private var minimumFrameInterval: TimeInterval = 0.1
    private var lastFrameAt = Date.distantPast
    private let maximumJPEGBytes = 360 * 1_024

    func start(
        request: ScreenStreamRequestPayload,
        frameHandler: @escaping @Sendable (ScreenFramePayload) -> Void,
        stoppedHandler: @escaping @Sendable (Error) -> Void
    ) async throws {
        await stop()

        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureServiceError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw ScreenCaptureServiceError.noDisplay
        }

        let settings = try ControlInputPolicy.screenSettings(for: request)
        let dimensions = settings.dimensions(displayWidth: display.width, displayHeight: display.height)

        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.framesPerSecond))
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)

        self.jpegQuality = settings.jpegQuality
        self.minimumFrameInterval = 1 / Double(settings.framesPerSecond)
        self.lastFrameAt = .distantPast
        self.frameHandler = frameHandler
        self.stoppedHandler = stoppedHandler
        self.stream = stream
        try await stream.startCapture()
        powerActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            reason: "Vibe Walkie diffuse l’écran vers un iPhone autorisé"
        )
    }

    func stop() async {
        let previous = stream
        stream = nil
        frameHandler = nil
        stoppedHandler = nil
        if let previous { try? await previous.stopCapture() }
        if let powerActivity {
            ProcessInfo.processInfo.endActivity(powerActivity)
            self.powerActivity = nil
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              sampleBuffer.isValid,
              Date().timeIntervalSince(lastFrameAt) >= minimumFrameInterval,
              let pixelBuffer = sampleBuffer.imageBuffer,
              let frameHandler else { return }

        lastFrameAt = Date()
        autoreleasepool {
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            guard let encoded = encodeBoundedJPEG(image) else { return }

            frameHandler(ScreenFramePayload(
                jpegData: encoded.data,
                width: encoded.width,
                height: encoded.height
            ))
        }
    }

    /// La représentation base64 ajoute environ 33 % avant l'enveloppe JSON.
    /// On garde donc une marge et on réduit progressivement qualité puis
    /// dimensions au lieu de jeter silencieusement les scènes détaillées.
    private func encodeBoundedJPEG(_ source: CIImage) -> (data: Data, width: Int, height: Int)? {
        let qualitySteps = [jpegQuality, min(jpegQuality, 0.34), 0.25, 0.18, 0.12]
        let scaleSteps: [CGFloat] = [1, 0.82, 0.66, 0.5]
        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String
        )

        for scale in scaleSteps {
            let image = scale == 1
                ? source
                : source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            for quality in qualitySteps {
                guard let data = context.jpegRepresentation(
                    of: image,
                    colorSpace: colorSpace,
                    options: [qualityKey: quality]
                ) else { continue }
                if data.count <= maximumJPEGBytes {
                    return (
                        data,
                        max(1, Int(image.extent.width.rounded())),
                        max(1, Int(image.extent.height.rounded()))
                    )
                }
            }
        }
        return nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Keep diagnostics useful without ever serialising a framework error,
        // which may carry display, window or application context.
        NSLog("[VibeWalkie] screen_capture_stopped")
        guard self.stream === stream else { return }
        stoppedHandler?(error)
    }
}
