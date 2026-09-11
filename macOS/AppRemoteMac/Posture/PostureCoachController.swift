@preconcurrency import AVFoundation
import AppKit
import Combine
import Foundation

@MainActor
final class PostureCoachController: ObservableObject {
    @Published private(set) var phase: PostureCoachPhase = .idle
    @Published private(set) var cameras: [PostureCameraDevice] = []
    @Published var selectedCameraID: String?
    @Published private(set) var currentPose: TrackedPose2D?
    @Published private(set) var ghostPose: TrackedPose2D?
    @Published private(set) var facePose: FacePose?
    @Published private(set) var metrics: NeckMetrics?
    @Published private(set) var evaluation: PostureEvaluation = .good
    @Published private(set) var viewpoint: CameraViewpoint = .unknown
    @Published private(set) var activity: ActivityState = .stationary
    @Published private(set) var trackingQuality = PoseTrackingQuality(
        hasNeck: false,
        hasUpperBody: false,
        hasFullBody: false,
        enoughLight: true,
        fillsFrame: false
    )
    @Published private(set) var isTrackingReliable = false
    @Published private(set) var isReadyToFreezePosture = false
    @Published private(set) var destination: PostureCoachDestination = .liveTracking
    @Published private(set) var keepsLiveTrackingExpanded = false
    @Published private(set) var guidance = "Placez la caméra où elle vous voit le mieux, même de côté ou de dos."
    @Published private(set) var sensitivity: PostureSensitivity
    @Published private(set) var soundEnabled: Bool
    @Published private(set) var isPreviewHidden = false

    let session: AVCaptureSession
    let walkingSessions: WorkWalkingSessionStore

    private static let cameraDefaultsKey = "vibe.walkie.mac.posture.camera.v1"
    private static let soundDefaultsKey = "vibe.walkie.mac.posture.sound.v1"
    private let cameraService: CameraFrameProvider
    private let defaults: UserDefaults
    private var staticBaseline: PostureBaseline?
    private var walkingBaseline: PostureBaseline?
    private var calibration = PostureCalibrationAccumulator()
    private var calibrationContinuity = PostureCalibrationContinuityGate()
    private var calibrationStartedAt: TimeInterval?
    private var positioningCandidate: (viewpoint: CameraViewpoint, since: TimeInterval)?
    private var activityDetector = PostureActivityDetector()
    private var evaluator = PostureEvaluationEngine()
    private var smoother = PostureMetricSmoother()
    private var correctionSoundGate = PostureCorrectionSoundGate()
    private let hiddenAlertPresenter = PostureHiddenAlertPresenter()
    private var previousEvaluationSeverity: PostureSeverity = .good
    private var activeAlertSound: NSSound?
    private var previousActivity: ActivityState = .stationary
    private var missingPoseSince: TimeInterval?
    private var isRunning = false
    private var receivedFirstFrame = false
    private var lastFrameArrival = 0.0
    private var watchdogTask: Task<Void, Never>?

    init(
        cameraService: CameraFrameProvider = PostureCameraService(),
        walkingSessions: WorkWalkingSessionStore = WorkWalkingSessionStore(),
        defaults: UserDefaults = .standard
    ) {
        self.cameraService = cameraService
        self.session = cameraService.session
        self.walkingSessions = walkingSessions
        self.defaults = defaults
        self.selectedCameraID = defaults.string(forKey: Self.cameraDefaultsKey)
        self.sensitivity = PostureSensitivity(
            rawValue: defaults.string(forKey: PostureSensitivity.defaultsKey) ?? ""
        ) ?? .balanced
        self.soundEnabled = defaults.object(forKey: Self.soundDefaultsKey) == nil
            ? true
            : defaults.bool(forKey: Self.soundDefaultsKey)
    }

    func refreshCameras() {
        cameras = PostureCameraService.availableDevices()
        if let selectedCameraID, cameras.contains(where: { $0.id == selectedCameraID }) {
            return
        }
        selectedCameraID = cameras.first?.id
    }

    func start() {
        guard !isRunning else { return }
        refreshCameras()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture()
        case .notDetermined:
            phase = .requestingPermission
            Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self else { return }
                if granted {
                    self.startCapture()
                } else {
                    self.phase = .permissionDenied
                }
            }
        case .denied, .restricted:
            phase = .permissionDenied
        @unknown default:
            phase = .permissionDenied
        }
    }

    func stop() {
        isRunning = false
        watchdogTask?.cancel()
        watchdogTask = nil
        cameraService.stop()
        hiddenAlertPresenter.hide()
        activeAlertSound?.stop()
        resetSessionState()
        phase = .idle
        destination = .liveTracking
        keepsLiveTrackingExpanded = false
    }

    func recalibrate() {
        guard isRunning else {
            start()
            return
        }
        resetAnalysisState()
        phase = .positioning
        guidance = "Placez-vous dans le cadre, puis redressez-vous avant d’enregistrer votre référence."
    }

    func confirmCalibrationPosture() {
        guard phase == .positioning, isReadyToFreezePosture else { return }
        isReadyToFreezePosture = false
        beginCalibration(at: ProcessInfo.processInfo.systemUptime, walking: false)
    }

    func confirmLeanPosture() {
        guard phase == .awaitingLeanSample, staticBaseline != nil else { return }
        beginCalibration(
            at: ProcessInfo.processInfo.systemUptime,
            walking: false,
            learningLean: true
        )
    }

    func selectCamera(_ id: String) {
        guard id != selectedCameraID else { return }
        selectedCameraID = id
        defaults.set(id, forKey: Self.cameraDefaultsKey)
        guard isRunning else { return }
        cameraService.stop()
        resetAnalysisState()
        isRunning = false
        startCapture()
    }

    func setSensitivity(_ value: PostureSensitivity) {
        sensitivity = value
        defaults.set(value.rawValue, forKey: PostureSensitivity.defaultsKey)
        evaluator.reset()
        evaluation = .good
    }

    func setSoundEnabled(_ value: Bool) {
        soundEnabled = value
        defaults.set(value, forKey: Self.soundDefaultsKey)
        if value { correctionSoundGate.reset() }
    }

    func setPreviewHidden(_ hidden: Bool) {
        isPreviewHidden = hidden
        if hidden, evaluation.severity >= .warning {
            hiddenAlertPresenter.show(
                message: evaluation.primaryIssue?.message ?? "Mauvaise posture détectée",
                severity: evaluation.severity
            )
        } else if !hidden {
            hiddenAlertPresenter.hide()
        }
    }

    func showHealthDashboard() {
        destination = .dashboard
        keepsLiveTrackingExpanded = false
    }

    func showExpandedLiveTracking() {
        destination = .liveTracking
        keepsLiveTrackingExpanded = true
    }

    func showCompactCoach() {
        destination = .liveTracking
        keepsLiveTrackingExpanded = false
    }

    func testAlertSound() {
        guard soundEnabled else { return }
        playAlertSound()
    }

    func openCameraPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func startCapture() {
        isRunning = true
        receivedFirstFrame = false
        lastFrameArrival = ProcessInfo.processInfo.systemUptime
        startWatchdog()
        phase = .positioning
        isReadyToFreezePosture = false
        guidance = "Placez-vous dans le cadre, puis redressez-vous avant d’enregistrer votre référence."
        cameraService.start(
            preferredDeviceID: selectedCameraID,
            frameHandler: { [weak self] frame in
                Task { @MainActor in self?.receive(frame) }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    switch result {
                    case .success(let deviceID):
                        self.selectedCameraID = deviceID
                        self.defaults.set(deviceID, forKey: Self.cameraDefaultsKey)
                    case .failure(let error):
                        self.isRunning = false
                        self.watchdogTask?.cancel()
                        self.watchdogTask = nil
                        self.phase = .unavailable(error.localizedDescription)
                    }
                }
            }
        )
    }

    private func receive(_ frame: PoseAnalysisFrame) {
        guard isRunning else { return }
        receivedFirstFrame = true
        lastFrameArrival = ProcessInfo.processInfo.systemUptime
        facePose = frame.face
        guard let pose = frame.pose2D else {
            handleMissingPose(at: frame.timestamp)
            return
        }

        missingPoseSince = nil
        currentPose = pose
        trackingQuality = quality(for: pose, pose3D: frame.pose3D, luma: frame.luma)
        isTrackingReliable = trackingQuality.hasNeck

        switch phase {
        case .positioning:
            handlePositioning(frame: frame, pose: pose)
        case .calibratingStatic:
            handleCalibration(frame: frame, pose: pose, duration: 8, walking: false)
        case .awaitingLeanSample:
            metrics = PostureMetricCalculator.metrics(
                pose2D: pose,
                pose3D: frame.pose3D,
                face: frame.face,
                viewpoint: viewpoint
            )
        case .calibratingLean:
            handleCalibration(
                frame: frame,
                pose: pose,
                duration: 5,
                walking: false,
                learningLean: true
            )
        case .calibratingWalking:
            handleCalibration(frame: frame, pose: pose, duration: 12, walking: true)
        case .monitoring:
            handleMonitoring(frame: frame, pose: pose)
        case .idle, .requestingPermission, .permissionDenied, .unavailable:
            break
        }
    }

    private func handlePositioning(frame: PoseAnalysisFrame, pose: TrackedPose2D) {
        guard trackingQuality.enoughLight else {
            positioningCandidate = nil
            isReadyToFreezePosture = false
            guidance = "Ajoutez de la lumière pour fiabiliser le suivi."
            return
        }
        guard trackingQuality.hasNeck else {
            positioningCandidate = nil
            isReadyToFreezePosture = false
            guidance = "Gardez la tête et le haut des épaules dans l’image."
            return
        }
        guard trackingQuality.fillsFrame else {
            positioningCandidate = nil
            isReadyToFreezePosture = false
            guidance = "Recadrez-vous pour occuper davantage l’image sans couper la tête."
            return
        }

        let candidate = PostureViewpointClassifier.classify(pose: pose, face: frame.face)
        switch candidate {
        case .front, .profile, .threeQuarter, .back:
            // Face yaw changes whenever the user looks at another screen and
            // must not restart framing. What matters is one second of reliable
            // head/thorax tracking; the personal baseline absorbs camera angle.
            if positioningCandidate == nil {
                positioningCandidate = (candidate, frame.timestamp)
            }
            viewpoint = candidate
            guard let since = positioningCandidate?.since,
                  frame.timestamp - since >= 1 else {
                isReadyToFreezePosture = false
                guidance = framingGuidance(for: candidate)
                return
            }
            isReadyToFreezePosture = true
            guidance = "Cadrage prêt. Redressez la tête et le buste, relâchez les épaules, puis enregistrez cette posture."
        case .unknown:
            viewpoint = .unknown
            if frame.pose3D?.hasHeadAndThorax == true {
                if positioningCandidate == nil {
                    positioningCandidate = (.unknown, frame.timestamp)
                }
                guard let since = positioningCandidate?.since,
                      frame.timestamp - since >= 1 else {
                    isReadyToFreezePosture = false
                    guidance = "Analyse 3D disponible. Gardez cette posture encore un instant."
                    return
                }
                isReadyToFreezePosture = true
                guidance = "Cadrage prêt en 3D. Prenez votre meilleure posture, puis enregistrez-la comme référence."
            } else {
                positioningCandidate = nil
                isReadyToFreezePosture = false
                guidance = "Ajustez la caméra pour garder la tête, les épaules et le buste visibles."
            }
        }
    }

    private func beginCalibration(
        at timestamp: TimeInterval,
        walking: Bool,
        learningLean: Bool = false
    ) {
        calibration.reset()
        calibrationContinuity.reset()
        smoother.reset()
        evaluator.reset()
        calibrationStartedAt = timestamp
        if walking {
            phase = .calibratingWalking(progress: 0)
            guidance = "Marchez naturellement. La position et l’angle de la caméra sont compensés."
        } else if learningLean {
            phase = .calibratingLean(progress: 0)
            guidance = "Gardez votre posture habituelle légèrement penchée vers l’écran."
        } else {
            phase = .calibratingStatic(progress: 0)
            guidance = "Maintenez volontairement votre meilleure posture : tête droite, buste redressé et épaules relâchées."
        }
    }

    private func handleCalibration(
        frame: PoseAnalysisFrame,
        pose: TrackedPose2D,
        duration: TimeInterval,
        walking: Bool,
        learningLean: Bool = false
    ) {
        if walking {
            updateActivity(with: pose, at: frame.timestamp)
            guard activity == .walking else {
                calibration.reset()
                calibrationStartedAt = nil
                enterMonitoring(
                    guidance: "La calibration marche reprendra dès que vos pas seront visibles."
                )
                return
            }
        } else {
            let currentViewpoint = PostureViewpointClassifier.classify(pose: pose, face: frame.face)
            let hasSpatialFallback = frame.pose3D?.hasHeadAndThorax == true
            let currentMetrics = PostureMetricCalculator.metrics(
                pose2D: pose,
                pose3D: frame.pose3D,
                face: frame.face,
                viewpoint: currentViewpoint
            )
            let calibrationFrameIsValid = (currentViewpoint != .unknown || hasSpatialFallback)
                && trackingQuality.hasNeck
                && trackingQuality.enoughLight
                && currentMetrics.hasAnyMeasurement
            guard calibrationFrameIsValid else {
                if calibrationContinuity.shouldRestart(isValid: false, at: frame.timestamp) {
                    if learningLean {
                        restartLeanCalibration(
                            guidance: "Le suivi a été perdu. Reprenez votre posture légèrement penchée, puis réessayez."
                        )
                    } else {
                        restartStaticCalibration(
                            guidance: "Le suivi du haut du corps est perdu depuis plusieurs secondes. Replacez-vous pour recommencer."
                        )
                    }
                } else {
                    guidance = "Repères momentanément masqués · votre calibration est conservée."
                }
                return
            }
            _ = calibrationContinuity.shouldRestart(isValid: true, at: frame.timestamp)
            // Keep the label representative without treating a look to the side
            // as a physical camera move. All evaluated metrics remain relative
            // to the baseline frozen at this placement.
            viewpoint = currentViewpoint
        }

        guard let startedAt = calibrationStartedAt else {
            beginCalibration(at: frame.timestamp, walking: walking, learningLean: learningLean)
            return
        }
        let currentMetrics = PostureMetricCalculator.metrics(
            pose2D: pose,
            pose3D: frame.pose3D,
            face: frame.face,
            viewpoint: viewpoint
        )
        calibration.append(metrics: currentMetrics, pose: pose)
        metrics = currentMetrics
        let progress = min(max((frame.timestamp - startedAt) / duration, 0), 1)
        if walking {
            phase = .calibratingWalking(progress: progress)
        } else if learningLean {
            phase = .calibratingLean(progress: progress)
        } else {
            phase = .calibratingStatic(progress: progress)
        }

        guard progress >= 1 else { return }
        guard let baseline = calibration.makeBaseline(viewpoint: viewpoint) else {
            calibration.reset()
            calibrationStartedAt = nil
            if learningLean {
                phase = .awaitingLeanSample
                guidance = "L’exemple penché n’était pas assez stable. Reprenez-le puis réessayez."
            } else {
                phase = .positioning
                guidance = "Le cou est visible, mais son angle reste incertain. Regardez droit devant quelques secondes."
            }
            return
        }
        if walking {
            walkingBaseline = baseline
        } else if learningLean {
            guard var upright = staticBaseline,
                  PersonalizedLeanModel.hasLearnableSignal(
                    upright: upright.metrics,
                    leaned: baseline.metrics,
                    variability: upright.variability
                  ) else {
                restartLeanCalibration(
                    guidance: "Le mouvement est trop proche de la posture droite. Penchez-vous comme vous le faites naturellement devant l’écran, puis réessayez."
                )
                return
            }
            upright.leanedMetrics = baseline.metrics
            staticBaseline = upright
        } else {
            staticBaseline = baseline
            ghostPose = baseline.ghostPose
            calibration.reset()
            calibrationStartedAt = nil
            evaluation = .good
            phase = .awaitingLeanSample
            guidance = "Posture droite enregistrée. Prenez maintenant votre posture habituelle légèrement penchée vers l’écran."
            return
        }
        ghostPose = staticBaseline?.ghostPose ?? baseline.ghostPose
        calibration.reset()
        calibrationStartedAt = nil
        evaluation = .good
        let monitoringGuidance: String
        if trackingQuality.hasFullBody {
            monitoringGuidance = "Posture calibrée. La marche sera détectée automatiquement."
        } else if trackingQuality.hasUpperBody {
            monitoringGuidance = "Posture calibrée. La marche est suivie grâce au mouvement du buste."
        } else {
            monitoringGuidance = "Cou calibré. Gardez aussi les épaules visibles pour suivre la marche."
        }
        enterMonitoring(guidance: monitoringGuidance)
    }

    private func handleMonitoring(frame: PoseAnalysisFrame, pose: TrackedPose2D) {
        updateActivity(with: pose, at: frame.timestamp)
        if activity != previousActivity {
            previousActivity = activity
            smoother.reset()
            evaluator.reset()
            correctionSoundGate.reset()
            evaluation = .good
        }

        if activity == .walking, walkingBaseline == nil {
            beginCalibration(at: frame.timestamp, walking: true)
            return
        }

        guard let baseline = activity == .walking ? walkingBaseline : staticBaseline else {
            phase = .positioning
            return
        }
        let rawMetrics = PostureMetricCalculator.metrics(
            pose2D: pose,
            pose3D: frame.pose3D,
            face: frame.face,
            viewpoint: baseline.viewpoint
        )
        let smoothedMetrics = smoother.append(rawMetrics, at: frame.timestamp, activity: activity)
        metrics = smoothedMetrics
        ghostPose = baseline.ghostPose
        evaluation = evaluator.evaluate(
            metrics: smoothedMetrics,
            baseline: baseline,
            sensitivity: sensitivity,
            at: frame.timestamp
        )
        let severityChanged = evaluation.severity != previousEvaluationSeverity
        let shouldPlaySound = soundEnabled
            && correctionSoundGate.shouldPlay(for: evaluation.severity, at: frame.timestamp)
        if shouldPlaySound {
            playAlertSound()
        }
        if isPreviewHidden, evaluation.severity >= .warning,
           severityChanged || shouldPlaySound {
            hiddenAlertPresenter.show(
                message: evaluation.primaryIssue?.message ?? "Mauvaise posture détectée",
                severity: evaluation.severity
            )
        } else if evaluation.severity < .warning {
            hiddenAlertPresenter.hide()
        }
        previousEvaluationSeverity = evaluation.severity
        guidance = statusGuidance()
    }

    private func handleMissingPose(at timestamp: TimeInterval) {
        if missingPoseSince == nil { missingPoseSince = timestamp }
        switch phase {
        case .calibratingStatic, .calibratingLean:
            if calibrationContinuity.shouldRestart(isValid: false, at: timestamp) {
                if case .calibratingLean = phase {
                    restartLeanCalibration(
                        guidance: "Le suivi est perdu. Reprenez votre posture légèrement penchée, puis réessayez."
                    )
                } else {
                    restartStaticCalibration(
                        guidance: "Le suivi est perdu depuis plusieurs secondes. Replacez-vous pour recommencer."
                    )
                }
            } else {
                guidance = "Sujet momentanément masqué · votre calibration est conservée."
            }
            return
        case .calibratingWalking:
            if calibrationContinuity.shouldRestart(isValid: false, at: timestamp) {
                calibration.reset()
                calibrationStartedAt = nil
                calibrationContinuity.reset()
                enterMonitoring(
                    guidance: "La calibration marche reprendra quand vos pas seront visibles."
                )
            } else {
                guidance = "Pas momentanément masqués · la calibration est conservée."
            }
            return
        default:
            break
        }
        guard let missingPoseSince, timestamp - missingPoseSince >= 2 else { return }
        walkingSessions.finishActive()
        activityDetector.reset()
        activity = .stationary
        previousActivity = .stationary
        isTrackingReliable = false
        currentPose = nil
        evaluation = PostureEvaluation(
            severities: Dictionary(uniqueKeysWithValues: PostureIssue.allCases.map { ($0, .unavailable) }),
            primaryIssue: nil
        )
        guidance = "Revenez dans le cadre pour reprendre l’analyse."
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.isRunning else { return }
                let silence = ProcessInfo.processInfo.systemUptime - self.lastFrameArrival
                // Vision 3D can occasionally spend several seconds on one
                // difficult frame (profile, occlusion, low light). The capture
                // delegate is serial, so a 2.5-second timeout stopped a healthy
                // session while analysis was merely busy.
                let timeout: TimeInterval = self.receivedFirstFrame ? 10 : 12
                guard silence >= timeout else { continue }
                self.isRunning = false
                self.cameraService.stop()
                self.resetAnalysisState()
                self.phase = .unavailable(
                    "Le flux caméra s’est interrompu. Vérifiez la caméra puis réessayez."
                )
                return
            }
        }
    }

    private func quality(
        for pose: TrackedPose2D,
        pose3D: TrackedPose3D?,
        luma: Double
    ) -> PoseTrackingQuality {
        let reliable = pose.points.values
            .filter { $0.confidence >= 0.4 }
            .map(\.location)
        let fillsFrame: Bool
        if let minY = reliable.map(\.y).min(), let maxY = reliable.map(\.y).max(),
           let minX = reliable.map(\.x).min(), let maxX = reliable.map(\.x).max() {
            let height = maxY - minY
            fillsFrame = height >= 0.28
                && height <= 0.97
                && minX >= 0.01
                && maxX <= 0.99
                && minY >= 0.01
                && maxY <= 0.99
        } else {
            fillsFrame = false
        }
        return PoseTrackingQuality(
            hasNeck: pose.hasNeck || pose3D?.hasHeadAndThorax == true,
            hasUpperBody: pose.hasUpperBody,
            hasFullBody: pose.hasFullBody,
            enoughLight: luma >= 0.12,
            fillsFrame: fillsFrame
        )
    }

    private func statusGuidance() -> String {
        if !isTrackingReliable { return "Suivi momentanément indisponible."
        }
        if let issue = evaluation.primaryIssue { return issue.message }
        if activity == .walking { return "Marche détectée · posture stable"
        }
        if !trackingQuality.hasUpperBody {
            return "Cou suivi · gardez les épaules visibles pour détecter la marche"
        }
        return "Posture stable"
    }

    private func restartStaticCalibration(guidance: String) {
        calibration.reset()
        calibrationStartedAt = nil
        calibrationContinuity.reset()
        isReadyToFreezePosture = false
        phase = .positioning
        self.guidance = guidance
    }

    private func restartLeanCalibration(guidance: String) {
        calibration.reset()
        calibrationStartedAt = nil
        calibrationContinuity.reset()
        phase = .awaitingLeanSample
        self.guidance = guidance
    }

    private func enterMonitoring(guidance: String) {
        phase = .monitoring
        keepsLiveTrackingExpanded = false
        self.guidance = guidance
    }

    private func framingGuidance(for viewpoint: CameraViewpoint) -> String {
        switch viewpoint {
        case .front: "Vue de face détectée. Gardez votre bonne posture."
        case .profile: "Vue de profil détectée. Gardez votre bonne posture."
        case .threeQuarter: "Vue en angle détectée. Gardez votre bonne posture."
        case .back: "Vue de dos détectée. Gardez votre bonne posture."
        case .unknown: "Gardez la tête, les épaules et le buste visibles."
        }
    }

    private func updateActivity(with pose: TrackedPose2D, at timestamp: TimeInterval) {
        activity = activityDetector.update(pose: pose, at: timestamp)
        walkingSessions.observe(activity)
    }

    private func playAlertSound() {
        activeAlertSound?.stop()
        let names = ["Sosumi", "Glass", "Ping"]
        guard let sound = names.lazy.compactMap({ NSSound(named: NSSound.Name($0)) }).first else {
            NSSound.beep()
            return
        }
        sound.volume = 1
        activeAlertSound = sound
        if !sound.play() { NSSound.beep() }
    }

    private func resetAnalysisState() {
        walkingSessions.finishActive()
        staticBaseline = nil
        walkingBaseline = nil
        calibration.reset()
        calibrationContinuity.reset()
        calibrationStartedAt = nil
        positioningCandidate = nil
        activityDetector.reset()
        evaluator.reset()
        smoother.reset()
        correctionSoundGate.reset()
        previousEvaluationSeverity = .good
        previousActivity = .stationary
        missingPoseSince = nil
        receivedFirstFrame = false
        lastFrameArrival = 0
        currentPose = nil
        ghostPose = nil
        facePose = nil
        metrics = nil
        evaluation = .good
        viewpoint = .unknown
        activity = .stationary
        isTrackingReliable = false
        isReadyToFreezePosture = false
        hiddenAlertPresenter.hide()
    }

    private func resetSessionState() {
        resetAnalysisState()
        trackingQuality = PoseTrackingQuality(
            hasNeck: false,
            hasUpperBody: false,
            hasFullBody: false,
            enoughLight: true,
            fillsFrame: false
        )
        guidance = "Placez la caméra où elle vous voit le mieux, même de côté ou de dos."
    }
}
