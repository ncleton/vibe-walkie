import CoreGraphics
import Foundation
import simd

protocol PostureEvaluating {
    mutating func evaluate(
        metrics: NeckMetrics,
        baseline: PostureBaseline,
        sensitivity: PostureSensitivity,
        at timestamp: TimeInterval
    ) -> PostureEvaluation

    mutating func reset()
}

enum PostureOverlayGeometry {
    /// Projects normalized Vision coordinates through the same aspect-fill crop
    /// as the camera preview. Vision analyzes the unmirrored capture buffer while
    /// the local preview deliberately behaves like FaceTime, so x must be mirrored
    /// before applying the crop — especially visible in the square bubble.
    static func displayPoint(
        _ point: CGPoint,
        frameSize: CGSize,
        viewSize: CGSize,
        mirrored: Bool = true
    ) -> CGPoint {
        let source = frameSize.width > 0 && frameSize.height > 0
            ? frameSize
            : CGSize(width: 16, height: 9)
        let scale = max(viewSize.width / source.width, viewSize.height / source.height)
        let rendered = CGSize(width: source.width * scale, height: source.height * scale)
        let origin = CGPoint(
            x: (viewSize.width - rendered.width) / 2,
            y: (viewSize.height - rendered.height) / 2
        )
        let normalizedX = mirrored ? 1 - point.x : point.x
        return CGPoint(
            x: origin.x + normalizedX * rendered.width,
            y: origin.y + (1 - point.y) * rendered.height
        )
    }
}

enum PostureViewpointClassifier {
    static func classify(pose: TrackedPose2D, face: FacePose?) -> CameraViewpoint {
        if let yaw = face?.yawDegrees {
            if abs(yaw) <= 20 { return .front }
            if abs(yaw) >= 70 { return .profile }
            return .threeQuarter
        }

        guard let leftShoulder = pose.reliablePoint(.leftShoulder),
              let rightShoulder = pose.reliablePoint(.rightShoulder),
              let shoulderCenter = pose.shoulderCenter,
              let headCenter = pose.headCenter else { return .unknown }

        let shoulderWidth = distance(leftShoulder, rightShoulder)
        let neckLength = max(distance(shoulderCenter, headCenter), 0.001)
        let shoulderRatio = shoulderWidth / neckLength
        if shoulderRatio >= 0.8 {
            return hasVisibleFaceLandmark(in: pose) ? .front : .back
        }
        if shoulderRatio <= 0.35 { return .profile }
        return .threeQuarter
    }

    private static func hasVisibleFaceLandmark(in pose: TrackedPose2D) -> Bool {
        [.nose, .leftEye, .rightEye, .leftEar, .rightEar].contains {
            pose[$0]?.confidence ?? 0 >= 0.4
        }
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}

enum PostureMetricCalculator {
    static func metrics(
        pose2D: TrackedPose2D,
        pose3D: TrackedPose3D?,
        face: FacePose?,
        viewpoint: CameraViewpoint
    ) -> NeckMetrics {
        let profileCVA = viewpoint == .profile ? craniovertebralAngle(in: pose2D) : nil
        let threeDimensionalHeadAngle = pose3D.flatMap(headThoraxAngle(in:))
        let head = pose2D.headCenter
        let shoulder = pose2D.shoulderCenter

        return NeckMetrics(
            profileCVA: profileCVA,
            headThoraxAngle: threeDimensionalHeadAngle ?? headThoraxAngle2D(in: pose2D),
            // Vision's monocular 3D trunk axis can move several degrees while a
            // person is still, particularly with a low camera. A calibrated 2D
            // shoulder-to-hip axis is substantially steadier for a fixed camera.
            trunkInclination: trunkInclination2D(in: pose2D),
            headPitch: face?.pitchDegrees,
            headYaw: face?.yawDegrees,
            uses3D: threeDimensionalHeadAngle != nil,
            headPositionX: head.map { Double($0.x) },
            headPositionY: head.map { Double($0.y) },
            shoulderPositionX: shoulder.map { Double($0.x) },
            shoulderPositionY: shoulder.map { Double($0.y) }
        )
    }

    static func craniovertebralAngle(in pose: TrackedPose2D) -> Double? {
        guard let neck = pose.shoulderCenter else { return nil }
        let ears: [PosePoint] = [PoseJoint.leftEar, .rightEar].compactMap { joint in
            guard let point = pose[joint], point.confidence >= 0.4 else { return nil }
            return point
        }
        guard let ear = ears.max(by: { $0.confidence < $1.confidence })?.location else { return nil }
        let radians = atan2(ear.y - neck.y, abs(ear.x - neck.x))
        return abs(radians * 180 / .pi)
    }

    private static func headThoraxAngle(in pose: TrackedPose3D) -> Double? {
        guard let spine = pose[.spine],
              let shoulder = pose[.centerShoulder],
              let head = pose[.centerHead] ?? pose[.topHead] else { return nil }
        return angle(between: shoulder - spine, and: head - shoulder)
    }

    private static func headThoraxAngle2D(in pose: TrackedPose2D) -> Double? {
        guard let hip = pose.hipCenter,
              let shoulder = pose.shoulderCenter,
              let head = pose.headCenter else { return nil }
        return angle(between: shoulder - hip, and: head - shoulder)
    }

    private static func trunkInclination2D(in pose: TrackedPose2D) -> Double? {
        guard let segment = trunkSegment(in: pose) else { return nil }
        return angle(between: segment.shoulder - segment.lower, and: CGPoint(x: 0, y: 1))
    }

    /// Uses anatomical points relative to each other, never their absolute
    /// position in the camera frame. When hips are cropped, Vision's projected
    /// 3D spine provides a steadier upper-torso axis than the raw 3D angle.
    static func trunkSegment(in pose: TrackedPose2D) -> (lower: CGPoint, shoulder: CGPoint)? {
        guard let shoulder = pose.midpoint(
            .leftShoulder,
            .rightShoulder,
            minimumConfidence: 0.55
        ) ?? pose.reliablePoint(.centerShoulder, minimumConfidence: 0.55) else { return nil }

        if let hip = pose.midpoint(.leftHip, .rightHip, minimumConfidence: 0.55),
           hip.y >= 0.06,
           shoulder.y - hip.y >= 0.12 {
            return (hip, shoulder)
        }
        if let spine = pose.reliablePoint(.spine, minimumConfidence: 0.55),
           shoulder.y - spine.y >= 0.06 {
            return (spine, shoulder)
        }
        return nil
    }

    private static func angle(between first: SIMD3<Float>, and second: SIMD3<Float>) -> Double? {
        let denominator = simd_length(first) * simd_length(second)
        guard denominator > 0.0001 else { return nil }
        let cosine = min(max(simd_dot(first, second) / denominator, -1), 1)
        return Double(acos(cosine) * 180 / .pi)
    }

    private static func angle(between first: CGPoint, and second: CGPoint) -> Double? {
        let firstLength = hypot(first.x, first.y)
        let secondLength = hypot(second.x, second.y)
        let denominator = firstLength * secondLength
        guard denominator > 0.0001 else { return nil }
        let cosine = min(max((first.x * second.x + first.y * second.y) / denominator, -1), 1)
        return acos(Double(cosine)) * 180 / Double.pi
    }
}

private extension CGPoint {
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }
}

struct PostureMetricSmoother {
    private struct Sample {
        let timestamp: TimeInterval
        let metrics: NeckMetrics
    }

    private var samples: [Sample] = []

    mutating func append(
        _ metrics: NeckMetrics,
        at timestamp: TimeInterval,
        activity: ActivityState
    ) -> NeckMetrics {
        samples.append(Sample(timestamp: timestamp, metrics: metrics))
        let window = activity == .walking ? 3.0 : 1.0
        samples.removeAll { timestamp - $0.timestamp > window }

        return NeckMetrics(
            profileCVA: median(samples.compactMap(\.metrics.profileCVA)),
            headThoraxAngle: median(samples.compactMap(\.metrics.headThoraxAngle)),
            trunkInclination: median(samples.compactMap(\.metrics.trunkInclination)),
            headPitch: median(samples.compactMap(\.metrics.headPitch)),
            headYaw: median(samples.compactMap(\.metrics.headYaw)),
            uses3D: samples.contains { $0.metrics.uses3D },
            headPositionX: median(samples.compactMap(\.metrics.headPositionX)),
            headPositionY: median(samples.compactMap(\.metrics.headPositionY)),
            shoulderPositionX: median(samples.compactMap(\.metrics.shoulderPositionX)),
            shoulderPositionY: median(samples.compactMap(\.metrics.shoulderPositionY))
        )
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }
}

struct PostureCalibrationAccumulator {
    private var samples: [(metrics: NeckMetrics, pose: TrackedPose2D)] = []

    var count: Int { samples.count }

    mutating func append(metrics: NeckMetrics, pose: TrackedPose2D) {
        samples.append((metrics, pose))
    }

    mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    func makeBaseline(viewpoint: CameraViewpoint) -> PostureBaseline? {
        guard samples.count >= 12, let lastPose = samples.last?.pose else { return nil }

        let metricSamples = samples.map(\.metrics)
        let center = NeckMetrics(
            profileCVA: median(metricSamples.compactMap(\.profileCVA)),
            headThoraxAngle: median(metricSamples.compactMap(\.headThoraxAngle)),
            trunkInclination: median(metricSamples.compactMap(\.trunkInclination)),
            headPitch: median(metricSamples.compactMap(\.headPitch)),
            headYaw: median(metricSamples.compactMap(\.headYaw)),
            uses3D: metricSamples.contains(where: \.uses3D),
            headPositionX: median(metricSamples.compactMap(\.headPositionX)),
            headPositionY: median(metricSamples.compactMap(\.headPositionY)),
            shoulderPositionX: median(metricSamples.compactMap(\.shoulderPositionX)),
            shoulderPositionY: median(metricSamples.compactMap(\.shoulderPositionY))
        )
        let variability = NeckMetrics(
            profileCVA: medianAbsoluteDeviation(metricSamples.compactMap(\.profileCVA)),
            headThoraxAngle: medianAbsoluteDeviation(metricSamples.compactMap(\.headThoraxAngle)),
            trunkInclination: medianAbsoluteDeviation(metricSamples.compactMap(\.trunkInclination)),
            headPitch: medianAbsoluteDeviation(metricSamples.compactMap(\.headPitch)),
            headYaw: medianAbsoluteDeviation(metricSamples.compactMap(\.headYaw)),
            uses3D: center.uses3D,
            headPositionX: medianAbsoluteDeviation(metricSamples.compactMap(\.headPositionX)),
            headPositionY: medianAbsoluteDeviation(metricSamples.compactMap(\.headPositionY)),
            shoulderPositionX: medianAbsoluteDeviation(metricSamples.compactMap(\.shoulderPositionX)),
            shoulderPositionY: medianAbsoluteDeviation(metricSamples.compactMap(\.shoulderPositionY))
        )

        guard center.hasAnyMeasurement else { return nil }

        return PostureBaseline(
            viewpoint: viewpoint,
            metrics: center,
            variability: variability,
            ghostPose: averagedPose(fallback: lastPose)
        )
    }

    private func averagedPose(fallback: TrackedPose2D) -> TrackedPose2D {
        var averaged: [PoseJoint: PosePoint] = [:]
        for joint in PoseJoint.allCases {
            let points = samples.compactMap { sample -> CGPoint? in
                sample.pose[joint].flatMap { $0.confidence >= 0.4 ? $0.location : nil }
            }
            guard !points.isEmpty else { continue }
            averaged[joint] = PosePoint(
                location: CGPoint(
                    x: points.map(\.x).reduce(0, +) / Double(points.count),
                    y: points.map(\.y).reduce(0, +) / Double(points.count)
                ),
                confidence: 1
            )
        }
        return TrackedPose2D(points: averaged, frameSize: fallback.frameSize)
    }
}

/// A pose detector can legitimately miss one or two frames because of motion,
/// occlusion or a landmark touching the crop. Calibration should survive those
/// gaps and restart only when tracking has been continuously unusable.
struct PostureCalibrationContinuityGate {
    private var invalidSince: TimeInterval?
    private let toleratedGap: TimeInterval

    init(toleratedGap: TimeInterval = 2) {
        self.toleratedGap = toleratedGap
    }

    mutating func shouldRestart(isValid: Bool, at timestamp: TimeInterval) -> Bool {
        if isValid {
            invalidSince = nil
            return false
        }
        if invalidSince == nil { invalidSince = timestamp }
        return timestamp - (invalidSince ?? timestamp) >= toleratedGap
    }

    mutating func reset() {
        invalidSince = nil
    }
}

struct PostureActivityDetector {
    private struct LowerBodySample {
        let timestamp: TimeInterval
        let ankleDifference: Double
        let rootY: Double
    }

    private struct UpperBodySample {
        let timestamp: TimeInterval
        let headY: Double
        let shoulderY: Double
        let shoulderWidth: Double
    }

    private var lowerBodySamples: [LowerBodySample] = []
    private var upperBodySamples: [UpperBodySample] = []
    private var walkingCandidateSince: TimeInterval?
    private var lastCadenceAt: TimeInterval?
    private(set) var state: ActivityState = .stationary

    mutating func update(pose: TrackedPose2D, at timestamp: TimeInterval) -> ActivityState {
        let cadence: Bool
        if let leftAnkle = pose.reliablePoint(.leftAnkle),
           let rightAnkle = pose.reliablePoint(.rightAnkle),
           let root = pose.hipCenter,
           pose.reliablePoint(.leftKnee) != nil,
           pose.reliablePoint(.rightKnee) != nil {
            upperBodySamples.removeAll(keepingCapacity: true)
            lowerBodySamples.append(LowerBodySample(
                timestamp: timestamp,
                ankleDifference: leftAnkle.y - rightAnkle.y,
                rootY: root.y
            ))
            lowerBodySamples.removeAll { timestamp - $0.timestamp > 4 }
            cadence = lowerBodyCadenceIsConsistent()
        } else if let head = pose.headCenter,
                  let shoulders = pose.midpoint(.leftShoulder, .rightShoulder),
                  let leftShoulder = pose.reliablePoint(.leftShoulder),
                  let rightShoulder = pose.reliablePoint(.rightShoulder) {
            lowerBodySamples.removeAll(keepingCapacity: true)
            upperBodySamples.append(UpperBodySample(
                timestamp: timestamp,
                headY: head.y,
                shoulderY: shoulders.y,
                shoulderWidth: abs(rightShoulder.x - leftShoulder.x)
            ))
            upperBodySamples.removeAll { timestamp - $0.timestamp > 4 }
            cadence = upperBodyCadenceIsConsistent()
        } else {
            return updateWithoutCadence(at: timestamp)
        }
        if cadence {
            lastCadenceAt = timestamp
            if walkingCandidateSince == nil { walkingCandidateSince = timestamp }
            if let started = walkingCandidateSince, timestamp - started >= 3 {
                state = .walking
            }
        } else {
            walkingCandidateSince = nil
            if state == .walking,
               let lastCadenceAt,
               timestamp - lastCadenceAt >= 5 {
                state = .stationary
            }
        }
        return state
    }

    mutating func reset() {
        lowerBodySamples.removeAll(keepingCapacity: true)
        upperBodySamples.removeAll(keepingCapacity: true)
        walkingCandidateSince = nil
        lastCadenceAt = nil
        state = .stationary
    }

    private mutating func updateWithoutCadence(at timestamp: TimeInterval) -> ActivityState {
        walkingCandidateSince = nil
        lowerBodySamples.removeAll(keepingCapacity: true)
        upperBodySamples.removeAll(keepingCapacity: true)
        if state == .walking,
           let lastCadenceAt,
           timestamp - lastCadenceAt >= 5 {
            state = .stationary
        }
        return state
    }

    private func lowerBodyCadenceIsConsistent() -> Bool {
        guard let first = lowerBodySamples.first,
              let last = lowerBodySamples.last,
              last.timestamp - first.timestamp >= 2.5 else { return false }

        let ankleValues = lowerBodySamples.map(\.ankleDifference)
        guard let minimum = ankleValues.min(), let maximum = ankleValues.max(),
              maximum - minimum >= 0.045 else { return false }

        let rootValues = lowerBodySamples.map(\.rootY)
        guard let rootMinimum = rootValues.min(), let rootMaximum = rootValues.max(),
              rootMaximum - rootMinimum >= 0.006 else { return false }

        let duration = last.timestamp - first.timestamp
        let zeroCrossings = Self.zeroCrossingCount(in: ankleValues)
        let cadenceHz = Double(zeroCrossings) / max(duration * 2, 0.001)
        return zeroCrossings >= 3 && (0.5...2.5).contains(cadenceHz)
    }

    /// Une webcam placée sur l'écran ne voit souvent ni genoux ni chevilles.
    /// La marche reste toutefois visible dans l'oscillation verticale, régulière
    /// et synchrone de la tête et des épaules. On retire la dérive lente avant
    /// d'analyser le rythme afin qu'un changement de posture ne ressemble pas à
    /// une succession de pas.
    private func upperBodyCadenceIsConsistent() -> Bool {
        guard let first = upperBodySamples.first,
              let last = upperBodySamples.last,
              upperBodySamples.count >= 16,
              last.timestamp - first.timestamp >= 2.5 else { return false }

        let head = Self.detrended(upperBodySamples.map(\.headY))
        let shoulders = Self.detrended(upperBodySamples.map(\.shoulderY))
        let scale = max(upperBodySamples.map(\.shoulderWidth).sorted()[upperBodySamples.count / 2], 0.08)
        guard Self.amplitude(head) >= max(0.004, scale * 0.012),
              Self.amplitude(shoulders) >= max(0.004, scale * 0.012),
              Self.correlation(head, shoulders) >= 0.62 else { return false }

        let combined = zip(head, shoulders).map { ($0 + $1) / 2 }
        let crossings = Self.zeroCrossingCount(in: combined, deadband: scale * 0.0025)
        let duration = last.timestamp - first.timestamp
        let cadenceHz = Double(crossings) / max(duration * 2, 0.001)
        return crossings >= 4 && (0.65...2.6).contains(cadenceHz)
    }

    private static func detrended(_ values: [Double]) -> [Double] {
        guard values.count > 1, let first = values.first, let last = values.last else { return values }
        let denominator = Double(values.count - 1)
        return values.enumerated().map { index, value in
            value - (first + (last - first) * Double(index) / denominator)
        }
    }

    private static func amplitude(_ values: [Double]) -> Double {
        guard let minimum = values.min(), let maximum = values.max() else { return 0 }
        return maximum - minimum
    }

    private static func zeroCrossingCount(in values: [Double], deadband: Double = 0) -> Int {
        var previousSign = 0
        var crossings = 0
        for value in values {
            let sign = value > deadband ? 1 : (value < -deadband ? -1 : 0)
            guard sign != 0 else { continue }
            if previousSign != 0, sign != previousSign { crossings += 1 }
            previousSign = sign
        }
        return crossings
    }

    private static func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let lhsMean = lhs.reduce(0, +) / Double(lhs.count)
        let rhsMean = rhs.reduce(0, +) / Double(rhs.count)
        var numerator = 0.0
        var lhsSquare = 0.0
        var rhsSquare = 0.0
        for (left, right) in zip(lhs, rhs) {
            let centeredLeft = left - lhsMean
            let centeredRight = right - rhsMean
            numerator += centeredLeft * centeredRight
            lhsSquare += centeredLeft * centeredLeft
            rhsSquare += centeredRight * centeredRight
        }
        return numerator / max(sqrt(lhsSquare * rhsSquare), 0.000_000_1)
    }
}

enum PersonalizedLeanModel {
    static func hasLearnableSignal(
        upright: NeckMetrics,
        leaned: NeckMetrics,
        variability: NeckMetrics
    ) -> Bool {
        score(
            current: leaned,
            upright: upright,
            leaned: leaned,
            variability: variability
        ) != nil
    }

    /// Projects the current posture onto the camera-specific movement learned
    /// between an upright sample (0) and the user's usual leaned sample (1).
    /// Taking the median of several independent landmarks prevents one noisy
    /// Vision joint from changing the result on its own.
    static func score(
        current: NeckMetrics,
        upright: NeckMetrics,
        leaned: NeckMetrics,
        variability: NeckMetrics
    ) -> Double? {
        var progresses: [Double] = []

        func append(
            current: Double?,
            upright: Double?,
            leaned: Double?,
            noise: Double?,
            minimumSignal: Double
        ) {
            guard let current, let upright, let leaned else { return }
            let signal = leaned - upright
            guard abs(signal) >= max(minimumSignal, 3 * (noise ?? 0)) else { return }
            progresses.append((current - upright) / signal)
        }

        append(current: current.headPositionX, upright: upright.headPositionX,
               leaned: leaned.headPositionX, noise: variability.headPositionX,
               minimumSignal: 0.008)
        append(current: current.headPositionY, upright: upright.headPositionY,
               leaned: leaned.headPositionY, noise: variability.headPositionY,
               minimumSignal: 0.008)
        append(current: current.shoulderPositionX, upright: upright.shoulderPositionX,
               leaned: leaned.shoulderPositionX, noise: variability.shoulderPositionX,
               minimumSignal: 0.008)
        append(current: current.shoulderPositionY, upright: upright.shoulderPositionY,
               leaned: leaned.shoulderPositionY, noise: variability.shoulderPositionY,
               minimumSignal: 0.008)
        append(current: current.trunkInclination, upright: upright.trunkInclination,
               leaned: leaned.trunkInclination, noise: variability.trunkInclination,
               minimumSignal: 2)
        append(current: current.headThoraxAngle, upright: upright.headThoraxAngle,
               leaned: leaned.headThoraxAngle, noise: variability.headThoraxAngle,
               minimumSignal: 2)
        append(current: current.profileCVA, upright: upright.profileCVA,
               leaned: leaned.profileCVA, noise: variability.profileCVA,
               minimumSignal: 2)
        append(current: current.headPitch, upright: upright.headPitch,
               leaned: leaned.headPitch, noise: variability.headPitch,
               minimumSignal: 2)

        guard progresses.count >= 2, let center = median(progresses) else { return nil }
        return max(0, center)
    }
}

struct PostureEvaluationEngine: PostureEvaluating {
    private struct IssueState {
        var amberStart: TimeInterval?
        var redStart: TimeInterval?
        var hardRedStart: TimeInterval?
        var recoveryStart: TimeInterval?
        var severity: PostureSeverity = .good
    }

    private struct Thresholds {
        let amber: Double
        let red: Double
        let hardRed: Double?
    }

    private struct Deviation {
        let value: Double
        let thresholds: Thresholds
    }

    private var states: [PostureIssue: IssueState] = [:]

    mutating func evaluate(
        metrics: NeckMetrics,
        baseline: PostureBaseline,
        sensitivity: PostureSensitivity,
        at timestamp: TimeInterval
    ) -> PostureEvaluation {
        var deviations: [PostureIssue: Deviation] = [:]
        let multiplier = sensitivity.multiplier
        let learnedLeanScore = baseline.leanedMetrics.flatMap { leaned in
            PersonalizedLeanModel.score(
                current: metrics,
                upright: baseline.metrics,
                leaned: leaned,
                variability: baseline.variability
            )
        }

        if learnedLeanScore == nil,
           baseline.viewpoint == .profile,
           let reference = baseline.metrics.profileCVA,
           let current = metrics.profileCVA {
            let noise = 2.5 * (baseline.variability.profileCVA ?? 0)
            deviations[.neckForward] = Deviation(
                value: abs(current - reference),
                thresholds: Thresholds(
                    amber: max(4, noise) * multiplier,
                    red: max(8, noise * 1.6) * multiplier,
                    hardRed: 15
                )
            )
        } else if learnedLeanScore == nil,
                  let reference = baseline.metrics.headThoraxAngle,
                  let current = metrics.headThoraxAngle {
            let noise = 2.5 * (baseline.variability.headThoraxAngle ?? 0)
            deviations[.neckForward] = Deviation(
                value: abs(current - reference),
                thresholds: Thresholds(
                    amber: max(4, noise) * multiplier,
                    red: max(8, noise * 1.6) * multiplier,
                    hardRed: 15
                )
            )
        }

        if let reference = baseline.metrics.headPitch, let current = metrics.headPitch {
            let noise = 3 * (baseline.variability.headPitch ?? 0)
            deviations[.headDown] = Deviation(
                // Vision pitch is relative to the camera, not gravity. Measure
                // distance from the frozen value in either direction: depending
                // on camera pitch, a downward nod may raise or lower this value.
                value: abs(current - reference),
                thresholds: Thresholds(
                    amber: max(6, noise) * multiplier,
                    red: max(12, noise * 1.6) * multiplier,
                    hardRed: 20
                )
            )
        }
        if let reference = baseline.metrics.headYaw, let current = metrics.headYaw {
            let noise = 3 * (baseline.variability.headYaw ?? 0)
            deviations[.headTurned] = Deviation(
                value: abs(current - reference),
                thresholds: Thresholds(
                    amber: max(12, noise) * multiplier,
                    red: max(22, noise) * multiplier,
                    hardRed: nil
                )
            )
        }
        if let learnedLeanScore {
            deviations[.trunkInclined] = Deviation(
                value: learnedLeanScore,
                thresholds: Thresholds(
                    amber: 0.3 * multiplier,
                    red: 0.75 * multiplier,
                    hardRed: 1.15
                )
            )
        } else if let reference = baseline.metrics.trunkInclination,
           let current = metrics.trunkInclination {
            let noise = 3 * (baseline.variability.trunkInclination ?? 0)
            deviations[.trunkInclined] = Deviation(
                // A fixed camera has no gravity reference. Only drift from the
                // user's calibrated trunk may be evaluated safely.
                value: abs(current - reference),
                thresholds: Thresholds(
                    amber: max(2.5, noise) * multiplier,
                    red: max(6, noise * 1.7) * multiplier,
                    hardRed: 15
                )
            )
        }

        for issue in PostureIssue.allCases {
            if let deviation = deviations[issue] {
                states[issue] = update(
                    states[issue] ?? IssueState(),
                    value: deviation.value,
                    thresholds: deviation.thresholds,
                    at: timestamp
                )
            } else {
                states[issue] = IssueState()
            }
        }

        let severities = states.mapValues(\.severity)
        let primaryIssue = severities
            .filter { $0.value >= .warning }
            .max { lhs, rhs in
                if lhs.value == rhs.value {
                    return normalizedDeviation(for: lhs.key, in: deviations)
                        < normalizedDeviation(for: rhs.key, in: deviations)
                }
                return lhs.value < rhs.value
            }?.key
        return PostureEvaluation(severities: severities, primaryIssue: primaryIssue)
    }

    mutating func reset() {
        states.removeAll(keepingCapacity: true)
    }

    private func normalizedDeviation(
        for issue: PostureIssue,
        in deviations: [PostureIssue: Deviation]
    ) -> Double {
        guard let deviation = deviations[issue] else { return 0 }
        return deviation.value / max(deviation.thresholds.amber, 0.001)
    }

    private func update(
        _ previous: IssueState,
        value: Double,
        thresholds: Thresholds,
        at timestamp: TimeInterval
    ) -> IssueState {
        var state = previous
        let exceedsHardGuardrail = thresholds.hardRed.map {
            value >= $0
        } ?? false

        if value >= thresholds.amber || exceedsHardGuardrail {
            state.recoveryStart = nil
            if value >= thresholds.amber {
                if state.amberStart == nil { state.amberStart = timestamp }
            } else {
                state.amberStart = nil
            }
            if value >= thresholds.red {
                if state.redStart == nil { state.redStart = timestamp }
            } else {
                state.redStart = nil
            }
            if exceedsHardGuardrail {
                if state.hardRedStart == nil { state.hardRedStart = timestamp }
            } else {
                state.hardRedStart = nil
            }

            if let hardStart = state.hardRedStart, timestamp - hardStart >= 5 {
                state.severity = .correction
            } else if let redStart = state.redStart, timestamp - redStart >= 12 {
                state.severity = .correction
            } else if let amberStart = state.amberStart, timestamp - amberStart >= 12 {
                // A moderate but uninterrupted deviation eventually deserves
                // the same audible escalation as a larger one.
                state.severity = .correction
            } else if let amberStart = state.amberStart, timestamp - amberStart >= 0.6,
                      state.severity < .warning {
                state.severity = .warning
            }
            return state
        }

        state.amberStart = nil
        state.redStart = nil
        state.hardRedStart = nil
        if state.severity >= .warning, value < thresholds.amber * 0.75 {
            if state.recoveryStart == nil { state.recoveryStart = timestamp }
            if let recoveryStart = state.recoveryStart, timestamp - recoveryStart >= 0.5 {
                return IssueState()
            }
        } else if value >= thresholds.amber * 0.75 {
            state.recoveryStart = nil
        } else {
            state = IssueState()
        }
        return state
    }
}

struct PostureCorrectionSoundGate {
    private var lastPlayedAt: TimeInterval?
    private let repeatInterval: TimeInterval = 20

    mutating func shouldPlay(for severity: PostureSeverity, at timestamp: TimeInterval) -> Bool {
        switch severity {
        case .correction:
            guard lastPlayedAt.map({ timestamp - $0 >= repeatInterval }) ?? true else { return false }
            lastPlayedAt = timestamp
            return true
        case .good:
            lastPlayedAt = nil
            return false
        case .warning, .unavailable:
            return false
        }
    }

    mutating func reset() {
        lastPlayedAt = nil
    }
}

private func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
}

private func medianAbsoluteDeviation(_ values: [Double]) -> Double? {
    guard let center = median(values) else { return nil }
    return median(values.map { abs($0 - center) })
}
