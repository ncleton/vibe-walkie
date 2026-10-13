"""Local camera analysis. No video, audio or landmarks are written to disk."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys
import time


JOINTS = {"nose": 0, "leftEye": 2, "rightEye": 5, "leftEar": 7, "rightEar": 8,
          "leftShoulder": 11, "rightShoulder": 12, "leftElbow": 13, "rightElbow": 14,
          "leftWrist": 15, "rightWrist": 16, "leftHip": 23, "rightHip": 24,
          "leftKnee": 25, "rightKnee": 26, "leftAnkle": 27, "rightAnkle": 28}


def midpoint(points, first, second, output):
    if first in points and second in points:
        points[output] = [(points[first][i] + points[second][i]) / 2 for i in range(2)] + [min(points[first][2], points[second][2])]


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--camera", type=int, default=0)
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    import cv2
    import mediapipe as mp
    from mediapipe.tasks import python
    from mediapipe.tasks.python import vision
    if args.list:
        from pygrabber.dshow_graph import FilterGraph
        print(json.dumps(FilterGraph().get_input_devices()), flush=True)
        return
    hashes = json.loads((args.models / "model-sha256.json").read_text())
    for name, digest in hashes.items():
        if hashlib.sha256((args.models / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError("Le modèle caméra est absent ou endommagé. Réinstallez le compagnon Windows.")
    pose_options = vision.PoseLandmarkerOptions(
        base_options=python.BaseOptions(model_asset_path=str(args.models / "pose_landmarker_full.task")),
        running_mode=vision.RunningMode.VIDEO, num_poses=1)
    face_options = vision.FaceLandmarkerOptions(
        base_options=python.BaseOptions(model_asset_path=str(args.models / "face_landmarker.task")),
        running_mode=vision.RunningMode.VIDEO, num_faces=1, output_facial_transformation_matrixes=True)
    camera = cv2.VideoCapture(args.camera, cv2.CAP_DSHOW)
    if not camera.isOpened():
        raise RuntimeError("Caméra inaccessible. Dans les paramètres Windows, autorisez l’accès caméra aux applications de bureau puis sélectionnez une caméra disponible.")
    camera.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    camera.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    try:
        with vision.PoseLandmarker.create_from_options(pose_options) as pose, vision.FaceLandmarker.create_from_options(face_options) as face:
            previous_ms = 0
            while True:
                started = time.monotonic()
                success, pixels = camera.read()
                if not success:
                    raise RuntimeError("La caméra ne fournit plus d’images. Rebranchez-la puis relancez le coach.")
                image = mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(pixels, cv2.COLOR_BGR2RGB))
                milliseconds = max(previous_ms + 1, round(started * 1000)); previous_ms = milliseconds
                body = pose.detect_for_video(image, milliseconds)
                head = face.detect_for_video(image, milliseconds)
                points, world = {}, {}
                if body.pose_landmarks:
                    landmarks = body.pose_landmarks[0]
                    for name, index in JOINTS.items():
                        item = landmarks[index]
                        points[name] = [item.x, 1 - item.y, min(item.visibility, item.presence)]
                    midpoint(points, "leftShoulder", "rightShoulder", "neck")
                    midpoint(points, "leftHip", "rightHip", "root")
                    for name, index in JOINTS.items():
                        if points[name][2] >= 0.4:
                            item = body.pose_world_landmarks[0][index]
                            world[name] = [item.x, -item.y, -item.z]
                    for name, left, right in [("centerShoulder", "leftShoulder", "rightShoulder"), ("spine", "leftHip", "rightHip"), ("centerHead", "leftEye", "rightEye")]:
                        if left in world and right in world:
                            world[name] = [(world[left][i] + world[right][i]) / 2 for i in range(3)]
                face_angles = None
                if head.facial_transformation_matrixes:
                    face_angles = list(cv2.RQDecomp3x3(head.facial_transformation_matrixes[0][:3, :3])[0])
                encoded, preview = cv2.imencode(".jpg", cv2.flip(pixels, 1), [cv2.IMWRITE_JPEG_QUALITY, 65])
                if not encoded:
                    raise RuntimeError("Le rendu caméra a échoué. Relancez le coach.")
                result = {"timestamp": started, "points": points, "world": world, "face": face_angles,
                          "luma": float(cv2.cvtColor(pixels, cv2.COLOR_BGR2GRAY).mean() / 255),
                          "frameSize": [pixels.shape[1], pixels.shape[0]], "preview": base64.b64encode(preview).decode()}
                print(json.dumps(result, separators=(",", ":"), allow_nan=False), flush=True)
                time.sleep(max(0, 0.2 - (time.monotonic() - started)))
    finally:
        camera.release()


if __name__ == "__main__":
    try:
        run()
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=True), flush=True)
        sys.exit(1)
