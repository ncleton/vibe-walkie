import CoreGraphics
import XCTest
@testable import VibeWalkieMac

final class PostureAnalysisEngineTests: XCTestCase {
    func testExclusiveRuntimeLockPreventsTwoCompanions() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("vibe-walkie-lock-test-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = ExclusiveProcessLock()
        let second = ExclusiveProcessLock()
        XCTAssertTrue(first.acquire(at: path))
        XCTAssertFalse(second.acquire(at: path))
        first.release()
        XCTAssertTrue(second.acquire(at: path))
    }

    func testCameraAnalysisLeavesInteractiveInputHeadroom() {
        XCTAssertLessThanOrEqual(PostureCapturePerformancePolicy.analysisFramesPerSecond, 5)
        XCTAssertLessThanOrEqual(PostureCapturePerformancePolicy.body3DFramesPerSecond, 1)
        XCTAssertLessThanOrEqual(PostureCapturePerformancePolicy.cameraFramesPerSecond, 15)
        XCTAssertGreaterThanOrEqual(PostureCapturePerformancePolicy.analysisInterval, 0.2)
        XCTAssertGreaterThanOrEqual(PostureCapturePerformancePolicy.body3DAnalysisInterval, 1)
    }

    func testOverlayProjectionMatchesPreviewOrientationAndAspectFillCrop() {
        let projected = PostureOverlayGeometry.displayPoint(
            CGPoint(x: 0.25, y: 0.75),
            frameSize: CGSize(width: 1280, height: 720),
            viewSize: CGSize(width: 800, height: 600)
        )

        XCTAssertEqual(projected.x, 666.667, accuracy: 0.01)
        XCTAssertEqual(projected.y, 150, accuracy: 0.01)
    }

    func testOverlayProjectionMirrorsVisionToMatchTheFaceTimePreview() {
        let projected = PostureOverlayGeometry.displayPoint(
            CGPoint(x: 0.64, y: 0.5),
            frameSize: CGSize(width: 1280, height: 720),
            viewSize: CGSize(width: 1754, height: 1082)
        )

        XCTAssertLessThan(projected.x, 1754 / 2)
        XCTAssertEqual(projected.y, 1082 / 2, accuracy: 0.01)
    }

    func testSquareBubbleUsesTheSameMirroredAspectFillCrop() {
        let projected = PostureOverlayGeometry.displayPoint(
            CGPoint(x: 0.35, y: 0.5),
            frameSize: CGSize(width: 1280, height: 720),
            viewSize: CGSize(width: 220, height: 220)
        )

        XCTAssertEqual(projected.x, 168.667, accuracy: 0.01)
        XCTAssertEqual(projected.y, 110, accuracy: 0.01)
    }

    func testCVAUsesNeckToMostReliableEarAgainstHorizontal() throws {
        var pose = makePose(profile: true)
        pose.points[.leftEar] = PosePoint(location: CGPoint(x: 0.62, y: 0.62), confidence: 0.9)
        pose.points[.rightEar] = PosePoint(location: CGPoint(x: 0.55, y: 0.7), confidence: 0.2)

        let angle = try XCTUnwrap(PostureMetricCalculator.craniovertebralAngle(in: pose))

        XCTAssertEqual(angle, 45, accuracy: 0.01)
    }

    func testViewpointClassifierSeparatesFrontProfileAndThreeQuarter() {
        XCTAssertEqual(
            PostureViewpointClassifier.classify(
                pose: makePose(profile: false),
                face: FacePose(pitchDegrees: 0, yawDegrees: 5, rollDegrees: 0)
            ),
            .front
        )
        XCTAssertEqual(
            PostureViewpointClassifier.classify(
                pose: makePose(profile: true),
                face: FacePose(pitchDegrees: 0, yawDegrees: 78, rollDegrees: 0)
            ),
            .profile
        )
        XCTAssertEqual(
            PostureViewpointClassifier.classify(
                pose: makePose(profile: false),
                face: FacePose(pitchDegrees: 0, yawDegrees: 42, rollDegrees: 0)
            ),
            .threeQuarter
        )
    }

    func testRearViewUsesProjected3DHeadWithoutRequiringAFace() {
        var pose = makePose(profile: false)
        for joint in [
            PoseJoint.nose, .leftEye, .rightEye, .leftEar, .rightEar
        ] {
            pose.points[joint] = nil
        }
        pose.points[.centerHead] = PosePoint(
            location: CGPoint(x: 0.5, y: 0.76),
            confidence: 0.75
        )
        pose.points[.centerShoulder] = PosePoint(
            location: CGPoint(x: 0.5, y: 0.64),
            confidence: 0.75
        )

        XCTAssertTrue(pose.hasNeck)
        XCTAssertTrue(pose.hasUpperBody)
        XCTAssertEqual(
            PostureViewpointClassifier.classify(pose: pose, face: nil),
            .back
        )
    }

    func testThreeDimensionalHeadAndThoraxMakeRearTrackingMeasurable() {
        let pose = TrackedPose3D(points: [
            .spine: SIMD3<Float>(0, 0.4, 0),
            .centerShoulder: SIMD3<Float>(0, 0.8, 0),
            .centerHead: SIMD3<Float>(0, 1.05, 0.04)
        ])

        XCTAssertTrue(pose.hasHeadAndThorax)
    }

    func testCalibrationSurvivesBriefPoseDropouts() {
        var gate = PostureCalibrationContinuityGate(toleratedGap: 2)

        XCTAssertFalse(gate.shouldRestart(isValid: false, at: 10))
        XCTAssertFalse(gate.shouldRestart(isValid: false, at: 11.9))
        XCTAssertFalse(gate.shouldRestart(isValid: true, at: 12))
        XCTAssertFalse(gate.shouldRestart(isValid: false, at: 20))
        XCTAssertTrue(gate.shouldRestart(isValid: false, at: 22))
    }

    func testModerateTwoDimensionalTrunkLeanIsDetected() {
        var baseline = makeBaseline()
        baseline.metrics.trunkInclination = 24
        var leaned = baseline.metrics
        leaned.trunkInclination = 30
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(metrics: leaned, baseline: baseline, sensitivity: .balanced, at: 0)
        let evaluation = engine.evaluate(
            metrics: leaned,
            baseline: baseline,
            sensitivity: .balanced,
            at: 0.6
        )

        XCTAssertEqual(evaluation.severity(for: .trunkInclined), .warning)
    }

    func testWholeBodyTranslationDoesNotPretendToBeATrunkLean() {
        var baseline = makeBaseline()
        baseline.metrics.trunkInclination = 24
        var translated = baseline.metrics
        translated.trunkInclination = 24
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(metrics: translated, baseline: baseline, sensitivity: .balanced, at: 0)
        let evaluation = engine.evaluate(
            metrics: translated,
            baseline: baseline,
            sensitivity: .balanced,
            at: 10
        )

        XCTAssertEqual(evaluation.severity(for: .trunkInclined), .good)
    }

    func testPersonalizedLeanFollowsTheLearnedCameraSpecificDirection() {
        var baseline = makeBaseline()
        baseline.metrics.headPositionX = 0.50
        baseline.metrics.headPositionY = 0.72
        baseline.metrics.shoulderPositionX = 0.48
        baseline.metrics.shoulderPositionY = 0.60
        baseline.variability.headPositionX = 0.002
        baseline.variability.headPositionY = 0.002
        baseline.variability.shoulderPositionX = 0.002
        baseline.variability.shoulderPositionY = 0.002
        var leaned = baseline.metrics
        leaned.headPositionX = 0.56
        leaned.headPositionY = 0.68
        leaned.shoulderPositionX = 0.53
        leaned.shoulderPositionY = 0.57
        baseline.leanedMetrics = leaned

        var moderatelyLeaned = baseline.metrics
        moderatelyLeaned.headPositionX = 0.53
        moderatelyLeaned.headPositionY = 0.70
        moderatelyLeaned.shoulderPositionX = 0.505
        moderatelyLeaned.shoulderPositionY = 0.585
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(
            metrics: moderatelyLeaned,
            baseline: baseline,
            sensitivity: .balanced,
            at: 0
        )
        let evaluation = engine.evaluate(
            metrics: moderatelyLeaned,
            baseline: baseline,
            sensitivity: .balanced,
            at: 0.61
        )

        XCTAssertEqual(evaluation.severity(for: .trunkInclined), .warning)
    }

    func testPersonalizedLeanIgnoresMovementOppositeTheLearnedDirection() {
        var baseline = makeBaseline()
        baseline.metrics.headPositionX = 0.50
        baseline.metrics.shoulderPositionX = 0.48
        baseline.variability.headPositionX = 0.002
        baseline.variability.shoulderPositionX = 0.002
        var leaned = baseline.metrics
        leaned.headPositionX = 0.56
        leaned.shoulderPositionX = 0.54
        baseline.leanedMetrics = leaned
        var movedBack = baseline.metrics
        movedBack.headPositionX = 0.46
        movedBack.shoulderPositionX = 0.44
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(metrics: movedBack, baseline: baseline, sensitivity: .balanced, at: 0)
        let evaluation = engine.evaluate(
            metrics: movedBack,
            baseline: baseline,
            sensitivity: .balanced,
            at: 10
        )

        XCTAssertEqual(evaluation.severity(for: .trunkInclined), .good)
    }

    func testProjectedSpineSupportsTrunkLeanWhenHipsAreCropped() throws {
        var uprightPose = makePose(profile: true)
        uprightPose.points[.leftHip] = nil
        uprightPose.points[.rightHip] = nil
        uprightPose.points[.root] = nil
        uprightPose.points[.spine] = PosePoint(
            location: CGPoint(x: 0.5, y: 0.45),
            confidence: 0.75
        )
        let uprightMetrics = PostureMetricCalculator.metrics(
            pose2D: uprightPose,
            pose3D: nil,
            face: nil,
            viewpoint: .profile
        )

        var leanedPose = uprightPose
        leanedPose.points[.leftShoulder] = PosePoint(
            location: CGPoint(x: 0.52, y: 0.64),
            confidence: 1
        )
        leanedPose.points[.rightShoulder] = PosePoint(
            location: CGPoint(x: 0.58, y: 0.64),
            confidence: 1
        )
        let leanedMetrics = PostureMetricCalculator.metrics(
            pose2D: leanedPose,
            pose3D: nil,
            face: nil,
            viewpoint: .profile
        )

        var baseline = makeBaseline()
        baseline.viewpoint = .profile
        baseline.metrics.trunkInclination = try XCTUnwrap(uprightMetrics.trunkInclination)
        baseline.variability.trunkInclination = 0.5
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(metrics: leanedMetrics, baseline: baseline, sensitivity: .balanced, at: 0)
        let evaluation = engine.evaluate(
            metrics: leanedMetrics,
            baseline: baseline,
            sensitivity: .balanced,
            at: 0.6
        )

        XCTAssertEqual(evaluation.severity(for: .trunkInclined), .warning)
    }

    func testFaceOrientationClassifiesAHeadAndNeckCropWithoutHips() {
        let pose = TrackedPose2D(
            points: [
                .nose: PosePoint(location: CGPoint(x: 0.5, y: 0.72), confidence: 1),
                .neck: PosePoint(location: CGPoint(x: 0.5, y: 0.43), confidence: 1)
            ],
            frameSize: CGSize(width: 1280, height: 720)
        )

        XCTAssertTrue(pose.hasNeck)
        XCTAssertFalse(pose.hasUpperBody)
        XCTAssertEqual(
            PostureViewpointClassifier.classify(
                pose: pose,
                face: FacePose(pitchDegrees: 0, yawDegrees: 4, rollDegrees: 0)
            ),
            .front
        )

        let quality = PoseTrackingQuality(
            hasNeck: true,
            hasUpperBody: false,
            hasFullBody: false,
            enoughLight: true,
            fillsFrame: true
        )
        XCTAssertTrue(quality.canCalibrate)
    }

    func testUpperBodyReadinessDoesNotRequireHandsOrElbows() {
        var pose = makePose(profile: false)
        pose.points[.leftElbow] = nil
        pose.points[.rightElbow] = nil
        pose.points[.leftWrist] = nil
        pose.points[.rightWrist] = nil

        XCTAssertTrue(pose.hasNeck)
        XCTAssertTrue(pose.hasUpperBody)
    }

    func testCroppedHipsDoNotProduceAnInferredTrunkAlertMetric() {
        var pose = makePose(profile: false)
        pose.points[.leftHip] = nil
        pose.points[.rightHip] = nil

        let metrics = PostureMetricCalculator.metrics(
            pose2D: pose,
            pose3D: nil,
            face: FacePose(pitchDegrees: 0, yawDegrees: 0, rollDegrees: 0),
            viewpoint: .front
        )

        XCTAssertNil(metrics.trunkInclination)
        XCTAssertNotNil(metrics.headThoraxAngle)
    }

    func testWarningRequiresSixTenthsOfASecondAndBriefGlanceIsIgnored() {
        let baseline = makeBaseline()
        var engine = PostureEvaluationEngine()
        let deviated = NeckMetrics(
            profileCVA: nil,
            headThoraxAngle: 17,
            trunkInclination: 0,
            headPitch: 13,
            headYaw: 0,
            uses3D: true
        )

        XCTAssertEqual(
            engine.evaluate(metrics: deviated, baseline: baseline, sensitivity: .balanced, at: 0).severity,
            .good
        )
        XCTAssertEqual(
            engine.evaluate(metrics: deviated, baseline: baseline, sensitivity: .balanced, at: 0.5).severity,
            .good
        )
        XCTAssertEqual(
            engine.evaluate(metrics: baseline.metrics, baseline: baseline, sensitivity: .balanced, at: 0.6).severity,
            .good
        )

        _ = engine.evaluate(metrics: deviated, baseline: baseline, sensitivity: .balanced, at: 10)
        XCTAssertEqual(
            engine.evaluate(metrics: deviated, baseline: baseline, sensitivity: .balanced, at: 10.61).severity,
            .warning
        )
    }

    func testLookingDownUsesNegativeVisionPitch() {
        let baseline = makeBaseline()
        var engine = PostureEvaluationEngine()
        var lookingDown = baseline.metrics
        lookingDown.headPitch = -16

        _ = engine.evaluate(
            metrics: lookingDown,
            baseline: baseline,
            sensitivity: .balanced,
            at: 0
        )
        let evaluation = engine.evaluate(
            metrics: lookingDown,
            baseline: baseline,
            sensitivity: .balanced,
            at: 5
        )

        XCTAssertEqual(evaluation.severity(for: .headDown), .warning)
        XCTAssertEqual(evaluation.primaryIssue, .headDown)
    }

    func testCameraPerspectiveCannotHidePitchChangeInTheOppositeDirection() {
        var baseline = makeBaseline()
        baseline.metrics.headPitch = -22
        var changed = baseline.metrics
        changed.headPitch = -12
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(metrics: changed, baseline: baseline, sensitivity: .balanced, at: 0)
        let evaluation = engine.evaluate(
            metrics: changed,
            baseline: baseline,
            sensitivity: .balanced,
            at: 5
        )

        XCTAssertEqual(evaluation.severity(for: .headDown), .warning)
    }

    func testCameraPitchOffsetDoesNotCreateAHeadDownAlert() {
        var baseline = makeBaseline()
        baseline.metrics.headPitch = -18
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(
            metrics: baseline.metrics,
            baseline: baseline,
            sensitivity: .balanced,
            at: 0
        )
        let evaluation = engine.evaluate(
            metrics: baseline.metrics,
            baseline: baseline,
            sensitivity: .balanced,
            at: 5
        )

        XCTAssertEqual(evaluation.severity(for: .headDown), .good)
    }

    func testStableHeadThoraxOffsetUsesThePersonalCalibration() {
        var baseline = makeBaseline()
        baseline.metrics.headThoraxAngle = 31
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(
            metrics: baseline.metrics,
            baseline: baseline,
            sensitivity: .balanced,
            at: 0
        )
        let evaluation = engine.evaluate(
            metrics: baseline.metrics,
            baseline: baseline,
            sensitivity: .balanced,
            at: 5
        )

        XCTAssertEqual(evaluation.severity(for: .neckForward), .good)
    }

    func testCorrectionSoundStartsImmediatelyRepeatsAndRearmsAfterRecovery() {
        var gate = PostureCorrectionSoundGate()

        XCTAssertFalse(gate.shouldPlay(for: .warning, at: 0))
        XCTAssertTrue(gate.shouldPlay(for: .correction, at: 1))
        XCTAssertFalse(gate.shouldPlay(for: .correction, at: 20))
        XCTAssertTrue(gate.shouldPlay(for: .correction, at: 21))
        XCTAssertFalse(gate.shouldPlay(for: .warning, at: 22))
        XCTAssertFalse(gate.shouldPlay(for: .good, at: 23))
        XCTAssertTrue(gate.shouldPlay(for: .correction, at: 24))
    }

    func testSmallNegativePitchRemainsNeutralForCameraAllowance() {
        var baseline = makeBaseline()
        baseline.metrics.headPitch = -4
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(
            metrics: baseline.metrics,
            baseline: baseline,
            sensitivity: .balanced,
            at: 0
        )
        let evaluation = engine.evaluate(
            metrics: baseline.metrics,
            baseline: baseline,
            sensitivity: .balanced,
            at: 30
        )

        XCTAssertEqual(evaluation.severity(for: .headDown), .good)
    }

    func testLowUpwardFacingCameraDoesNotCreatePersistentTrunkAlert() {
        var baseline = makeBaseline()
        baseline.metrics.trunkInclination = 24
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(
            metrics: baseline.metrics,
            baseline: baseline,
            sensitivity: .balanced,
            at: 0
        )
        let evaluation = engine.evaluate(
            metrics: baseline.metrics,
            baseline: baseline,
            sensitivity: .balanced,
            at: 30
        )

        XCTAssertEqual(evaluation.severity(for: .trunkInclined), .good)
    }

    func testFloorCameraOffsetsHeadAndTrunkWithoutMaskingLaterHeadDrop() {
        var baseline = makeBaseline()
        baseline.metrics.headPitch = -22
        baseline.metrics.trunkInclination = 31
        var lookingDown = baseline.metrics
        lookingDown.headPitch = -36
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(
            metrics: lookingDown,
            baseline: baseline,
            sensitivity: .balanced,
            at: 0
        )
        let evaluation = engine.evaluate(
            metrics: lookingDown,
            baseline: baseline,
            sensitivity: .balanced,
            at: 5
        )

        XCTAssertEqual(evaluation.severity(for: .headDown), .warning)
        XCTAssertEqual(evaluation.severity(for: .trunkInclined), .good)
    }

    func testTrunkDriftIsStillDetectedRelativeToTiltedCameraBaseline() {
        var baseline = makeBaseline()
        baseline.metrics.trunkInclination = 24
        var leaned = baseline.metrics
        leaned.trunkInclination = 37
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(metrics: leaned, baseline: baseline, sensitivity: .balanced, at: 0)
        let evaluation = engine.evaluate(
            metrics: leaned,
            baseline: baseline,
            sensitivity: .balanced,
            at: 5
        )

        XCTAssertEqual(evaluation.severity(for: .trunkInclined), .warning)
    }

    func testTrunkDriftTowardCameraIsDetectedInEitherAngularDirection() {
        var baseline = makeBaseline()
        baseline.metrics.trunkInclination = 24
        var leaned = baseline.metrics
        leaned.trunkInclination = 11
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(metrics: leaned, baseline: baseline, sensitivity: .balanced, at: 0)
        let evaluation = engine.evaluate(
            metrics: leaned,
            baseline: baseline,
            sensitivity: .balanced,
            at: 5
        )

        XCTAssertEqual(evaluation.severity(for: .trunkInclined), .warning)
    }

    func testModeratePersistentDeviationEventuallyEscalatesToSoundLevel() {
        let baseline = makeBaseline()
        var changed = baseline.metrics
        changed.headThoraxAngle = 12
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(metrics: changed, baseline: baseline, sensitivity: .balanced, at: 0)
        let evaluation = engine.evaluate(
            metrics: changed,
            baseline: baseline,
            sensitivity: .balanced,
            at: 12
        )

        XCTAssertEqual(evaluation.severity(for: .neckForward), .correction)
    }

    func testLowProfileCVAReferenceIsNotOverriddenByAnAbsoluteImageThreshold() {
        var baseline = makeBaseline()
        baseline.viewpoint = .profile
        baseline.metrics.profileCVA = 42
        var engine = PostureEvaluationEngine()

        _ = engine.evaluate(metrics: baseline.metrics, baseline: baseline, sensitivity: .balanced, at: 0)
        let evaluation = engine.evaluate(
            metrics: baseline.metrics,
            baseline: baseline,
            sensitivity: .balanced,
            at: 30
        )

        XCTAssertEqual(evaluation.severity(for: .neckForward), .good)
    }

    func testRedRequiresFifteenSecondsOrFiveSecondsPastHardGuardrail() {
        let baseline = makeBaseline()
        var timedEngine = PostureEvaluationEngine()
        let redDeviation = NeckMetrics(
            profileCVA: nil,
            headThoraxAngle: 24,
            trunkInclination: 0,
            headPitch: 0,
            headYaw: 0,
            uses3D: true
        )
        _ = timedEngine.evaluate(metrics: redDeviation, baseline: baseline, sensitivity: .balanced, at: 0)
        XCTAssertEqual(
            timedEngine.evaluate(metrics: redDeviation, baseline: baseline, sensitivity: .balanced, at: 15).severity,
            .correction
        )

        var hardEngine = PostureEvaluationEngine()
        let hardDeviation = NeckMetrics(
            profileCVA: nil,
            headThoraxAngle: 31,
            trunkInclination: 0,
            headPitch: 0,
            headYaw: 0,
            uses3D: true
        )
        _ = hardEngine.evaluate(metrics: hardDeviation, baseline: baseline, sensitivity: .balanced, at: 0)
        XCTAssertEqual(
            hardEngine.evaluate(metrics: hardDeviation, baseline: baseline, sensitivity: .balanced, at: 5).severity,
            .correction
        )
    }

    func testRecoveryReturnsToGreenInUnderOneSecond() {
        let baseline = makeBaseline()
        var engine = PostureEvaluationEngine()
        let deviated = NeckMetrics(
            profileCVA: nil,
            headThoraxAngle: 17,
            trunkInclination: 0,
            headPitch: 0,
            headYaw: 0,
            uses3D: true
        )
        _ = engine.evaluate(metrics: deviated, baseline: baseline, sensitivity: .balanced, at: 0)
        XCTAssertEqual(
            engine.evaluate(metrics: deviated, baseline: baseline, sensitivity: .balanced, at: 5).severity,
            .warning
        )
        XCTAssertEqual(
            engine.evaluate(metrics: baseline.metrics, baseline: baseline, sensitivity: .balanced, at: 6).severity,
            .warning
        )
        XCTAssertEqual(
            engine.evaluate(metrics: baseline.metrics, baseline: baseline, sensitivity: .balanced, at: 6.51).severity,
            .good
        )
    }

    func testProfileNoiseFloorIgnoresChangesBelowFiveDegrees() {
        var baseline = makeBaseline()
        baseline.viewpoint = .profile
        baseline.metrics.profileCVA = 55
        baseline.variability.profileCVA = 2
        var engine = PostureEvaluationEngine()
        let smallChange = NeckMetrics(
            profileCVA: 52,
            headThoraxAngle: 0,
            trunkInclination: 0,
            headPitch: 0,
            headYaw: 0,
            uses3D: false
        )

        _ = engine.evaluate(metrics: smallChange, baseline: baseline, sensitivity: .balanced, at: 0)
        XCTAssertEqual(
            engine.evaluate(metrics: smallChange, baseline: baseline, sensitivity: .balanced, at: 20).severity,
            .good
        )
    }

    func testSensitivityChangesTheWarningThreshold() {
        let baseline = makeBaseline()
        let deviation = NeckMetrics(
            profileCVA: nil,
            headThoraxAngle: 10,
            trunkInclination: 0,
            headPitch: 0,
            headYaw: 0,
            uses3D: true
        )
        var strictEngine = PostureEvaluationEngine()
        var relaxedEngine = PostureEvaluationEngine()
        _ = strictEngine.evaluate(metrics: deviation, baseline: baseline, sensitivity: .strict, at: 0)
        _ = relaxedEngine.evaluate(metrics: deviation, baseline: baseline, sensitivity: .relaxed, at: 0)

        XCTAssertEqual(
            strictEngine.evaluate(metrics: deviation, baseline: baseline, sensitivity: .strict, at: 5).severity,
            .warning
        )
        XCTAssertEqual(
            relaxedEngine.evaluate(metrics: deviation, baseline: baseline, sensitivity: .relaxed, at: 5).severity,
            .good
        )
    }

    func testWalkingNeedsSustainedAlternatingLegsAndStopsAfterInactivity() {
        var detector = PostureActivityDetector()
        var time = 0.0
        while time <= 8 {
            let ankleWave = 0.04 * sin(2 * Double.pi * time)
            let rootWave = 0.004 * sin(4 * Double.pi * time)
            let pose = makeFullBodyPose(ankleDifference: ankleWave, rootOffset: rootWave)
            _ = detector.update(pose: pose, at: time)
            time += 0.125
        }
        XCTAssertEqual(detector.state, .walking)

        while time <= 19 {
            _ = detector.update(pose: makeFullBodyPose(ankleDifference: 0, rootOffset: 0), at: time)
            time += 0.125
        }
        XCTAssertEqual(detector.state, .stationary)
    }

    func testStaticUpperBodyDoesNotPretendToWalk() {
        let pose = makePose(profile: false)
        var detector = PostureActivityDetector()

        XCTAssertTrue(pose.hasUpperBody)
        XCTAssertFalse(pose.hasFullBody)
        var time = 0.0
        while time <= 8 {
            _ = detector.update(pose: pose, at: time)
            time += 0.125
        }
        XCTAssertEqual(detector.state, .stationary)
    }

    func testPeriodicHeadAndShoulderMotionDetectsWalkingWithoutLegs() {
        var detector = PostureActivityDetector()
        var time = 0.0
        while time <= 9 {
            let bounce = 0.009 * sin(2 * Double.pi * 1.6 * time)
            var pose = makePose(profile: false)
            for joint in [
                PoseJoint.nose, .leftEye, .rightEye, .leftEar, .rightEar,
                .neck, .leftShoulder, .rightShoulder
            ] {
                if let point = pose.points[joint] {
                    pose.points[joint] = PosePoint(
                        location: CGPoint(x: point.location.x, y: point.location.y + bounce),
                        confidence: point.confidence
                    )
                }
            }
            _ = detector.update(pose: pose, at: time)
            time += 0.125
        }

        XCTAssertFalse(makePose(profile: false).hasFullBody)
        XCTAssertEqual(detector.state, .walking)
    }

    private func makeBaseline() -> PostureBaseline {
        let pose = makePose(profile: false)
        return PostureBaseline(
            viewpoint: .front,
            metrics: NeckMetrics(
                profileCVA: nil,
                headThoraxAngle: 5,
                trunkInclination: 0,
                headPitch: 0,
                headYaw: 0,
                uses3D: true
            ),
            variability: NeckMetrics(
                profileCVA: nil,
                headThoraxAngle: 1,
                trunkInclination: 1,
                headPitch: 1,
                headYaw: 1,
                uses3D: true
            ),
            ghostPose: pose
        )
    }

    private func makePose(profile: Bool) -> TrackedPose2D {
        let leftShoulderX = profile ? 0.49 : 0.32
        let rightShoulderX = profile ? 0.53 : 0.68
        return TrackedPose2D(
            points: [
                .nose: PosePoint(location: CGPoint(x: 0.56, y: 0.77), confidence: 1),
                .neck: PosePoint(location: CGPoint(x: 0.5, y: 0.5), confidence: 1),
                .leftEye: PosePoint(location: CGPoint(x: 0.48, y: 0.76), confidence: 1),
                .rightEye: PosePoint(location: CGPoint(x: 0.54, y: 0.76), confidence: 1),
                .leftEar: PosePoint(location: CGPoint(x: 0.62, y: 0.62), confidence: 1),
                .rightEar: PosePoint(location: CGPoint(x: 0.45, y: 0.7), confidence: 0.2),
                .leftShoulder: PosePoint(location: CGPoint(x: leftShoulderX, y: 0.64), confidence: 1),
                .rightShoulder: PosePoint(location: CGPoint(x: rightShoulderX, y: 0.64), confidence: 1),
                .leftElbow: PosePoint(location: CGPoint(x: leftShoulderX - 0.03, y: 0.5), confidence: 1),
                .rightElbow: PosePoint(location: CGPoint(x: rightShoulderX + 0.03, y: 0.5), confidence: 1),
                .leftWrist: PosePoint(location: CGPoint(x: leftShoulderX - 0.04, y: 0.38), confidence: 1),
                .rightWrist: PosePoint(location: CGPoint(x: rightShoulderX + 0.04, y: 0.38), confidence: 1),
                .leftHip: PosePoint(location: CGPoint(x: 0.46, y: 0.3), confidence: 1),
                .rightHip: PosePoint(location: CGPoint(x: 0.54, y: 0.3), confidence: 1),
                .root: PosePoint(location: CGPoint(x: 0.5, y: 0.3), confidence: 1)
            ],
            frameSize: CGSize(width: 1280, height: 720)
        )
    }

    private func makeFullBodyPose(ankleDifference: Double, rootOffset: Double) -> TrackedPose2D {
        var pose = makePose(profile: false)
        pose.points[.root] = PosePoint(location: CGPoint(x: 0.5, y: 0.4 + rootOffset), confidence: 1)
        pose.points[.leftHip] = PosePoint(location: CGPoint(x: 0.45, y: 0.4 + rootOffset), confidence: 1)
        pose.points[.rightHip] = PosePoint(location: CGPoint(x: 0.55, y: 0.4 + rootOffset), confidence: 1)
        pose.points[.leftKnee] = PosePoint(location: CGPoint(x: 0.45, y: 0.24), confidence: 1)
        pose.points[.rightKnee] = PosePoint(location: CGPoint(x: 0.55, y: 0.24), confidence: 1)
        pose.points[.leftAnkle] = PosePoint(location: CGPoint(x: 0.44, y: 0.08 + ankleDifference / 2), confidence: 1)
        pose.points[.rightAnkle] = PosePoint(location: CGPoint(x: 0.56, y: 0.08 - ankleDifference / 2), confidence: 1)
        return pose
    }
}
