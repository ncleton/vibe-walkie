"""Fetch exact upstream models only at build time, with committed SHA-256s."""
import hashlib
import json
from pathlib import Path
import urllib.request

root = Path(__file__).resolve().parents[1] / "Vision"
urls = {
    "pose_landmarker_full.task": "https://storage.googleapis.com/mediapipe-models/pose_landmarker/pose_landmarker_full/float16/1/pose_landmarker_full.task",
    "face_landmarker.task": "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task",
}
(root / "models").mkdir(exist_ok=True)
for name, digest in json.loads((root / "model-sha256.json").read_text()).items():
    with urllib.request.urlopen(urls[name], timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit("Upstream model checksum mismatch: " + name)
    (root / "models" / name).write_bytes(data)
