@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO

protocol CameraFrameProvider: AnyObject {
    var session: AVCaptureSession { get }
    func start(
        preferredDeviceID: String?,
        frameHandler: @escaping @Sendable (PoseAnalysisFrame) -> Void,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    )
    func stop()
}

enum PostureCameraError: LocalizedError {
    case noCamera
    case cannotCreateInput
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCamera: "Aucune caméra n’est disponible."
        case .cannotCreateInput: "La caméra n’a pas pu être ouverte."
        case .cannotAddInput: "La caméra n’est pas compatible avec cette session."
        case .cannotAddOutput: "Le flux vidéo n’a pas pu être configuré."
        }
    }
}

enum PostureCapturePerformancePolicy {
    /// La posture humaine évolue lentement ; cinq analyses Vision par seconde
    /// suffisent tout en laissant la priorité aux entrées interactives.
    static let analysisFramesPerSecond = 5.0
    /// La reconstruction 3D est nettement plus coûteuse que le squelette 2D.
    /// Une mesure par seconde suffit pour recaler la posture sans monopoliser
    /// Vision entre deux gestes de pointeur.
    static let body3DFramesPerSecond = 1.0
    static let cameraFramesPerSecond = 15.0
    static let analysisInterval = 1.0 / analysisFramesPerSecond
    static let body3DAnalysisInterval = 1.0 / body3DFramesPerSecond
}

final class PostureCameraService: NSObject, CameraFrameProvider, @unchecked Sendable {
    let session = AVCaptureSession()

    private let captureQueue = DispatchQueue(label: "com.vibewalkie.posture.capture")
    private let analysisQueue = DispatchQueue(
        label: "com.vibewalkie.posture.vision",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let analyzer: PoseAnalyzing
    private let handlerLock = NSLock()
    private var frameHandler: (@Sendable (PoseAnalysisFrame) -> Void)?
    private var lastAnalysisTimestamp: TimeInterval = -.infinity

    init(analyzer: PoseAnalyzing = PoseVisionAnalyzer()) {
        self.analyzer = analyzer
        super.init()
    }

    static func availableDevices() -> [PostureCameraDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices.map { PostureCameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    func start(
        preferredDeviceID: String?,
        frameHandler: @escaping @Sendable (PoseAnalysisFrame) -> Void,
        completion: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        handlerLock.withLock { self.frameHandler = frameHandler }
        captureQueue.async { [weak self] in
            guard let self else { return }
            do {
                let deviceID = try self.configureSession(preferredDeviceID: preferredDeviceID)
                self.session.startRunning()
                completion(.success(deviceID))
            } catch {
                self.handlerLock.withLock { self.frameHandler = nil }
                completion(.failure(error))
            }
        }
    }

    func stop() {
        handlerLock.withLock { frameHandler = nil }
        captureQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            self.session.inputs.forEach(self.session.removeInput)
            self.session.outputs.forEach(self.session.removeOutput)
            self.session.commitConfiguration()
        }
    }

    private func configureSession(preferredDeviceID: String?) throws -> String {
        let devices = Self.availableDevices()
        guard let device = devices.first(where: { $0.id == preferredDeviceID }).flatMap({ selected in
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [.builtInWideAngleCamera, .external],
                mediaType: .video,
                position: .unspecified
            ).devices.first { $0.uniqueID == selected.id }
        }) ?? AVCaptureDevice.default(for: .video) else {
            throw PostureCameraError.noCamera
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw PostureCameraError.cannotCreateInput
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.setSampleBufferDelegate(self, queue: analysisQueue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        } else {
            session.sessionPreset = .high
        }
        guard session.canAddInput(input) else { throw PostureCameraError.cannotAddInput }
        session.addInput(input)
        guard session.canAddOutput(output) else { throw PostureCameraError.cannotAddOutput }
        session.addOutput(output)
        configureFrameRate(for: device)
        return device.uniqueID
    }

    private func configureFrameRate(for device: AVCaptureDevice) {
        let preferredFPS = PostureCapturePerformancePolicy.cameraFramesPerSecond
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            $0.minFrameRate <= preferredFPS && preferredFPS <= $0.maxFrameRate
        }), (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }

        let duration = CMTime(value: 1, timescale: CMTimeScale(preferredFPS))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }
}

extension PostureCameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard timestamp - lastAnalysisTimestamp >= PostureCapturePerformancePolicy.analysisInterval,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysisTimestamp = timestamp

        let frame = analyzer.analyze(
            pixelBuffer: pixelBuffer,
            orientation: .up,
            timestamp: timestamp
        )
        let handler = handlerLock.withLock { frameHandler }
        handler?(frame)
    }
}
