import CoreGraphics
import Foundation
import simd

enum PostureCoachPhase: Equatable, Sendable {
    case idle
    case requestingPermission
    case positioning
    case calibratingStatic(progress: Double)
    case awaitingLeanSample
    case calibratingLean(progress: Double)
    case monitoring
    case calibratingWalking(progress: Double)
    case permissionDenied
    case unavailable(String)

    var usesCompactBubble: Bool {
        self == .monitoring
    }
}

enum PostureCoachDestination: Equatable, Sendable {
    case liveTracking
    case dashboard
}

enum CameraViewpoint: String, Equatable, Sendable {
    case front
    case profile
    case threeQuarter
    case back
    case unknown
}

enum ActivityState: String, Equatable, Sendable {
    case stationary
    case walking
}

enum PostureSensitivity: String, CaseIterable, Hashable, Identifiable, Sendable {
    case relaxed
    case balanced
    case strict

    static let defaultsKey = "vibe.walkie.mac.posture.sensitivity.v1"

    var id: String { rawValue }

    var multiplier: Double {
        switch self {
        case .relaxed: 1.3
        case .balanced: 1
        case .strict: 0.8
        }
    }

    var title: String {
        switch self {
        case .relaxed: "Souple"
        case .balanced: "Équilibrée"
        case .strict: "Stricte"
        }
    }
}

enum PostureSeverity: Int, Comparable, Sendable {
    case unavailable = 0
    case good = 1
    case warning = 2
    case correction = 3

    static func < (lhs: PostureSeverity, rhs: PostureSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum PostureIssue: String, CaseIterable, Hashable, Sendable {
    case neckForward
    case headDown
    case headTurned
    case trunkInclined

    var message: String {
        switch self {
        case .neckForward: "Cou vers l’avant"
        case .headDown: "Tête baissée"
        case .headTurned: "Tête tournée"
        case .trunkInclined: "Buste incliné"
        }
    }
}

enum PoseJoint: String, CaseIterable, Hashable, Sendable {
    case nose
    case neck
    case leftEye
    case rightEye
    case leftEar
    case rightEar
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle
    case root
    case spine
    case centerShoulder
    case centerHead
    case topHead
}

struct PosePoint: Equatable, Sendable {
    let location: CGPoint
    let confidence: Float
}

struct TrackedPose2D: Equatable, Sendable {
    var points: [PoseJoint: PosePoint]
    var frameSize: CGSize

    subscript(_ joint: PoseJoint) -> PosePoint? {
        points[joint]
    }

    func reliablePoint(_ joint: PoseJoint, minimumConfidence: Float = 0.4) -> CGPoint? {
        guard let point = points[joint], point.confidence >= minimumConfidence else { return nil }
        return point.location
    }

    func midpoint(
        _ first: PoseJoint,
        _ second: PoseJoint,
        minimumConfidence: Float = 0.4
    ) -> CGPoint? {
        guard let a = reliablePoint(first, minimumConfidence: minimumConfidence),
              let b = reliablePoint(second, minimumConfidence: minimumConfidence) else { return nil }
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    var shoulderCenter: CGPoint? {
        reliablePoint(.centerShoulder)
            ?? reliablePoint(.neck)
            ?? midpoint(.leftShoulder, .rightShoulder)
    }

    var hipCenter: CGPoint? {
        reliablePoint(.root) ?? midpoint(.leftHip, .rightHip)
    }

    var headCenter: CGPoint? {
        if let eyes = midpoint(.leftEye, .rightEye) { return eyes }
        if let ears = midpoint(.leftEar, .rightEar) { return ears }
        return reliablePoint(.nose) ?? reliablePoint(.centerHead)
    }

    var hasNeck: Bool {
        headCenter != nil && shoulderCenter != nil
    }

    var hasUpperBody: Bool {
        hasNeck
            && hipCenter != nil
            && reliablePoint(.leftShoulder) != nil
            && reliablePoint(.rightShoulder) != nil
    }

    var hasFullBody: Bool {
        hasUpperBody
            && reliablePoint(.leftKnee) != nil
            && reliablePoint(.rightKnee) != nil
            && reliablePoint(.leftAnkle) != nil
            && reliablePoint(.rightAnkle) != nil
    }
}

struct TrackedPose3D: Equatable, Sendable {
    var points: [PoseJoint: SIMD3<Float>]

    subscript(_ joint: PoseJoint) -> SIMD3<Float>? {
        points[joint]
    }

    var hasHeadAndThorax: Bool {
        points[.spine] != nil
            && points[.centerShoulder] != nil
            && (points[.centerHead] != nil || points[.topHead] != nil)
    }
}

struct FacePose: Equatable, Sendable {
    /// Vision reports a downward nod as a negative pitch on the Mac camera.
    var pitchDegrees: Double?
    var yawDegrees: Double?
    var rollDegrees: Double?
}

struct PoseAnalysisFrame: Equatable, Sendable {
    var pose2D: TrackedPose2D?
    var pose3D: TrackedPose3D?
    var face: FacePose?
    var luma: Double
    var timestamp: TimeInterval
}

struct NeckMetrics: Equatable, Sendable {
    var profileCVA: Double?
    var headThoraxAngle: Double?
    var trunkInclination: Double?
    var headPitch: Double?
    var headYaw: Double?
    var uses3D: Bool
    var headPositionX: Double? = nil
    var headPositionY: Double? = nil
    var shoulderPositionX: Double? = nil
    var shoulderPositionY: Double? = nil

    var hasAnyMeasurement: Bool {
        profileCVA != nil
            || headThoraxAngle != nil
            || trunkInclination != nil
            || headPitch != nil
            || headYaw != nil
            || (headPositionX != nil && headPositionY != nil)
            || (shoulderPositionX != nil && shoulderPositionY != nil)
    }
}

struct PostureBaseline: Equatable, Sendable {
    var viewpoint: CameraViewpoint
    var metrics: NeckMetrics
    var variability: NeckMetrics
    var ghostPose: TrackedPose2D
    var leanedMetrics: NeckMetrics? = nil
}

struct PostureEvaluation: Equatable, Sendable {
    var severities: [PostureIssue: PostureSeverity]
    var primaryIssue: PostureIssue?

    static let good = PostureEvaluation(severities: [:], primaryIssue: nil)

    var severity: PostureSeverity {
        severities.values.max() ?? .good
    }

    func severity(for issue: PostureIssue) -> PostureSeverity {
        severities[issue] ?? .good
    }
}

struct PostureCameraDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct PoseTrackingQuality: Equatable, Sendable {
    var hasNeck: Bool
    var hasUpperBody: Bool
    var hasFullBody: Bool
    var enoughLight: Bool
    var fillsFrame: Bool

    var canCalibrate: Bool {
        hasNeck && enoughLight && fillsFrame
    }
}
