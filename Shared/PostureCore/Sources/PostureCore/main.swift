import Foundation

// Dedicated local process: this is the same calibrated posture and walking
// engine as macOS. Neither landmarks nor video are stored by this process.
struct Input: Decodable {
    let command: String?
    let timestamp: Double
    let points: [String: [Double]]
    let world: [String: [Float]]?
    let face: [Double]?
    let luma: Double
    let frameSize: [Double]
    let sensitivity: String?
}
struct Output: Encodable {
    let phase: String
    let progress: Double
    let activity: String
    let severity: Int
    let issue: String?
    let viewpoint: String
    let sound: Bool
    let hasNeck: Bool
    let hasUpperBody: Bool
    let hasFullBody: Bool
    let enoughLight: Bool
    let ghostPoints: [String: [Double]]?
    let currentPoints: [String: [Double]]
    let frameWidth: Double
    let frameHeight: Double
}
var activity = PostureActivityDetector()
var evaluation = PostureEvaluationEngine()
var calibration = PostureCalibrationAccumulator()
var continuity = PostureCalibrationContinuityGate()
var smoothing = PostureMetricSmoother()
var alerts = PostureCorrectionSoundGate()
var baseline: PostureBaseline?
var walkingBaseline: PostureBaseline?
var phase = "positioning"
var calibrationStarted: Double?
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
while let line = readLine() {
    do {
        let input = try JSONDecoder().decode(Input.self, from: Data(line.utf8))
        guard input.frameSize.count == 2, input.frameSize.allSatisfy({ $0.isFinite && $0 > 0 }), input.timestamp.isFinite, input.luma.isFinite else { throw NSError(domain: "PostureCore", code: 1) }
        let points = Dictionary(uniqueKeysWithValues: input.points.compactMap { key, value -> (PoseJoint, PosePoint)? in
            guard let joint = PoseJoint(rawValue: key), value.count == 3, value.allSatisfy(\.isFinite) else { return nil }
            return (joint, PosePoint(location: CGPoint(x: value[0], y: value[1]), confidence: Float(value[2])))
        })
        let pose = TrackedPose2D(points: points, frameSize: CGSize(width: input.frameSize[0], height: input.frameSize[1]))
        let world = input.world.map { values in TrackedPose3D(points: Dictionary(uniqueKeysWithValues: values.compactMap { key, value -> (PoseJoint, SIMD3<Float>)? in
            guard let joint = PoseJoint(rawValue: key), value.count == 3, value.allSatisfy(\.isFinite) else { return nil }
            return (joint, SIMD3<Float>(value[0], value[1], value[2]))
        })) }
        let face = input.face.flatMap { values -> FacePose? in
            guard values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
            return FacePose(pitchDegrees: values[0], yawDegrees: values[1], rollDegrees: values[2])
        }
        let viewpoint = PostureViewpointClassifier.classify(pose: pose, face: face)
        let metrics = PostureMetricCalculator.metrics(pose2D: pose, pose3D: world, face: face, viewpoint: viewpoint)
        if input.command == "calibrate" || input.command == "lean" {
            calibration.reset(); continuity.reset(); calibrationStarted = input.timestamp
            phase = input.command == "lean" ? "calibratingLean" : "calibratingStatic"
            evaluation.reset(); smoothing.reset()
        }
        let walking = activity.update(pose: pose, at: input.timestamp)
        let canCalibrate = (pose.hasNeck || world?.hasHeadAndThorax == true) && input.luma >= 0.12 && metrics.hasAnyMeasurement
        if phase == "monitoring", walking == .walking, walkingBaseline == nil {
            calibration.reset(); continuity.reset(); calibrationStarted = input.timestamp; phase = "calibratingWalking"
        }
        if phase == "calibratingWalking", walking != .walking {
            calibration.reset(); calibrationStarted = nil; phase = "monitoring"
        }
        var progress = 0.0
        if let start = calibrationStarted {
            if canCalibrate {
                calibration.append(metrics: metrics, pose: pose)
                _ = continuity.shouldRestart(isValid: true, at: input.timestamp)
                let duration = phase == "calibratingWalking" ? 12.0 : phase == "calibratingLean" ? 5.0 : 8.0
                progress = min(1, max(0, (input.timestamp - start) / duration))
                if progress >= 1, let sample = calibration.makeBaseline(viewpoint: viewpoint) {
                    if phase == "calibratingWalking" { walkingBaseline = sample; phase = "monitoring" }
                    else if phase == "calibratingLean", var upright = baseline {
                        guard PersonalizedLeanModel.hasLearnableSignal(upright: upright.metrics, leaned: sample.metrics, variability: upright.variability) else {
                            throw NSError(domain: "PostureCore", code: 2)
                        }
                        upright.leanedMetrics = sample.metrics; baseline = upright; phase = "monitoring"
                    } else { baseline = sample; phase = "awaitingLeanSample" }
                    calibrationStarted = nil
                }
            } else if continuity.shouldRestart(isValid: false, at: input.timestamp) { calibration.reset(); calibrationStarted = input.timestamp; continuity.reset() }
        }
        var result = PostureEvaluation.good
        let reference = walking == .walking ? walkingBaseline : baseline
        if let reference, phase == "monitoring", canCalibrate {
            let smooth = smoothing.append(metrics, at: input.timestamp, activity: walking)
            result = evaluation.evaluate(metrics: smooth, baseline: reference,
                sensitivity: PostureSensitivity(rawValue: input.sensitivity ?? "balanced") ?? .balanced, at: input.timestamp)
        }
        let output = Output(phase: phase, progress: progress, activity: walking.rawValue,
            severity: canCalibrate ? result.severity.rawValue : 0, issue: result.primaryIssue?.rawValue,
            viewpoint: viewpoint.rawValue, sound: alerts.shouldPlay(for: result.severity, at: input.timestamp),
            hasNeck: pose.hasNeck, hasUpperBody: pose.hasUpperBody, hasFullBody: pose.hasFullBody, enoughLight: input.luma >= 0.12,
            ghostPoints: baseline.map { reference in Dictionary(uniqueKeysWithValues: reference.ghostPose.points.map { (key, point) in
                (key.rawValue, [Double(point.location.x), Double(point.location.y), Double(point.confidence)])
            }) }, currentPoints: input.points, frameWidth: input.frameSize[0], frameHeight: input.frameSize[1])
        print(String(decoding: try encoder.encode(output), as: UTF8.self))
        fflush(stdout)
    } catch {
        // No sensitive field data in diagnostics. The caller displays the
        // actionable error and stops monitoring until the user restarts it.
        print("{\"error\":\"Analyse ou calibration impossible. Placez-vous dans le cadre et recommencez la calibration.\"}")
        fflush(stdout)
    }
}
