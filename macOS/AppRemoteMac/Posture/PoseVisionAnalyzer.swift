import CoreMedia
import Foundation
import ImageIO
import Vision

protocol PoseAnalyzing: AnyObject {
    func analyze(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) -> PoseAnalysisFrame
}

final class PoseVisionAnalyzer: PoseAnalyzing {
    private let body2DRequest = VNDetectHumanBodyPoseRequest()
    private let body3DRequest = VNDetectHumanBodyPose3DRequest()
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private var last3DAnalysisTimestamp: TimeInterval = -.infinity
    private var cachedPose3D: TrackedPose3D?
    private var cachedProjected3DPoints: [PoseJoint: PosePoint] = [:]

    init() {
        // Vision may otherwise choose an interactive QoS internally even when
        // the capture delegate runs on a utility queue.
        body2DRequest.preferBackgroundProcessing = true
        body3DRequest.preferBackgroundProcessing = true
        faceRequest.preferBackgroundProcessing = true
    }

    func analyze(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) -> PoseAnalysisFrame {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        let shouldAnalyze3D = timestamp - last3DAnalysisTimestamp
            >= PostureCapturePerformancePolicy.body3DAnalysisInterval
        var requests: [VNRequest] = [body2DRequest, faceRequest]
        if shouldAnalyze3D { requests.append(body3DRequest) }
        do {
            try handler.perform(requests)
        } catch {
            return PoseAnalysisFrame(
                pose2D: nil,
                pose3D: nil,
                face: nil,
                luma: Self.averageLuma(of: pixelBuffer),
                timestamp: timestamp
            )
        }

        if shouldAnalyze3D {
            last3DAnalysisTimestamp = timestamp
            let observation = body3DRequest.results?.first
            cachedPose3D = makePose3D(from: observation)
            cachedProjected3DPoints = makeProjected3DPoints(from: observation)
        }
        return PoseAnalysisFrame(
            pose2D: makePose2D(
                from: body2DRequest.results?.first,
                supplementingWith: cachedProjected3DPoints,
                frameSize: CGSize(
                    width: CVPixelBufferGetWidth(pixelBuffer),
                    height: CVPixelBufferGetHeight(pixelBuffer)
                )
            ),
            pose3D: cachedPose3D,
            face: makeFacePose(from: faceRequest.results?.first),
            luma: Self.averageLuma(of: pixelBuffer),
            timestamp: timestamp
        )
    }

    private func makePose2D(
        from observation: VNHumanBodyPoseObservation?,
        supplementingWith projected3DPoints: [PoseJoint: PosePoint],
        frameSize: CGSize
    ) -> TrackedPose2D? {
        let mapping: [(PoseJoint, VNHumanBodyPoseObservation.JointName)] = [
            (.nose, .nose),
            (.neck, .neck),
            (.leftEye, .leftEye),
            (.rightEye, .rightEye),
            (.leftEar, .leftEar),
            (.rightEar, .rightEar),
            (.leftShoulder, .leftShoulder),
            (.rightShoulder, .rightShoulder),
            (.leftElbow, .leftElbow),
            (.rightElbow, .rightElbow),
            (.leftWrist, .leftWrist),
            (.rightWrist, .rightWrist),
            (.leftHip, .leftHip),
            (.rightHip, .rightHip),
            (.leftKnee, .leftKnee),
            (.rightKnee, .rightKnee),
            (.leftAnkle, .leftAnkle),
            (.rightAnkle, .rightAnkle),
            (.root, .root)
        ]
        var points: [PoseJoint: PosePoint] = [:]
        if let observation,
           let recognized = try? observation.recognizedPoints(.all) {
            for (joint, visionJoint) in mapping {
                guard let point = recognized[visionJoint], point.confidence > 0 else { continue }
                points[joint] = PosePoint(location: point.location, confidence: point.confidence)
            }
        }

        // A rear view often hides every facial landmark even though Vision's 3D
        // request still reconstructs the head and thorax. Project those joints
        // back into the image so framing, calibration and the overlay do not
        // depend on seeing eyes, ears or a nose.
        for (joint, point) in projected3DPoints where points[joint] == nil {
            points[joint] = point
        }
        guard !points.isEmpty else { return nil }
        return TrackedPose2D(points: points, frameSize: frameSize)
    }

    private func makeProjected3DPoints(
        from observation: VNHumanBodyPose3DObservation?
    ) -> [PoseJoint: PosePoint] {
        let mapping: [(PoseJoint, VNHumanBodyPose3DObservation.JointName)] = [
            (.centerHead, .centerHead),
            (.topHead, .topHead),
            (.centerShoulder, .centerShoulder),
            (.spine, .spine),
            (.root, .root)
        ]
        guard let observation else { return [:] }
        var points: [PoseJoint: PosePoint] = [:]
        for (joint, visionJoint) in mapping {
            if let point = try? observation.pointInImage(visionJoint) {
                points[joint] = PosePoint(
                    location: CGPoint(x: point.x, y: point.y),
                    confidence: 0.75
                )
            }
        }
        return points
    }

    private func makePose3D(from observation: VNHumanBodyPose3DObservation?) -> TrackedPose3D? {
        guard let observation else { return nil }
        let mapping: [(PoseJoint, VNHumanBodyPose3DObservation.JointName)] = [
            (.root, .root),
            (.leftHip, .leftHip),
            (.rightHip, .rightHip),
            (.leftKnee, .leftKnee),
            (.rightKnee, .rightKnee),
            (.leftAnkle, .leftAnkle),
            (.rightAnkle, .rightAnkle),
            (.spine, .spine),
            (.centerShoulder, .centerShoulder),
            (.centerHead, .centerHead),
            (.topHead, .topHead),
            (.leftShoulder, .leftShoulder),
            (.rightShoulder, .rightShoulder),
            (.leftElbow, .leftElbow),
            (.rightElbow, .rightElbow),
            (.leftWrist, .leftWrist),
            (.rightWrist, .rightWrist)
        ]
        var points: [PoseJoint: SIMD3<Float>] = [:]
        for (joint, visionJoint) in mapping {
            guard let recognized = try? observation.recognizedPoint(visionJoint) else { continue }
            let translation = recognized.position.columns.3
            points[joint] = SIMD3<Float>(translation.x, translation.y, translation.z)
        }
        guard !points.isEmpty else { return nil }
        return TrackedPose3D(points: points)
    }

    private func makeFacePose(from observation: VNFaceObservation?) -> FacePose? {
        guard let observation else { return nil }
        return FacePose(
            pitchDegrees: observation.pitch.map { $0.doubleValue * 180 / .pi },
            yawDegrees: observation.yaw.map { $0.doubleValue * 180 / .pi },
            rollDegrees: observation.roll.map { $0.doubleValue * 180 / .pi }
        )
    }

    private static func averageLuma(of pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let plane = CVPixelBufferGetPlaneCount(pixelBuffer) > 0 ? 0 : -1
        let baseAddress: UnsafeMutableRawPointer?
        let width: Int
        let height: Int
        let bytesPerRow: Int
        if plane == 0 {
            baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
            width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        } else {
            baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
            width = CVPixelBufferGetWidth(pixelBuffer)
            height = CVPixelBufferGetHeight(pixelBuffer)
            bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        }
        guard let baseAddress, width > 0, height > 0 else { return 0 }

        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        let horizontalStep = max(width / 32, 1)
        let verticalStep = max(height / 18, 1)
        var total = 0
        var count = 0
        for y in stride(from: 0, to: height, by: verticalStep) {
            for x in stride(from: 0, to: width, by: horizontalStep) {
                total += Int(bytes[y * bytesPerRow + x])
                count += 1
            }
        }
        return count > 0 ? Double(total) / Double(count * 255) : 0
    }
}
