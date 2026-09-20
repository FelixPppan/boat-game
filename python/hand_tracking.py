"""Tracking hands from a webcam and streams the hand landmarks to Godot over UDP."""


# Sources: 
# https://developers.google.com/edge/mediapipe/solutions/vision/hand_landmarker
# https://www.youtube.com/watch?v=MQYB69ZstPo
# https://medium.com/@florian-trautweiler/real-time-hand-tracking-in-godot-creating-virtual-3d-clones-of-my-hands-ecbfb73c2fcf


import json
import socket
import time
import urllib.request
from pathlib import Path
from typing import Any

import cv2
import mediapipe as mp
from mediapipe.tasks import python as mp_python
from mediapipe.tasks.python import vision

SERVER_IP = "127.0.0.1"
SERVER_PORT = 4242

MODEL_PATH = Path(__file__).parent / "hand_landmarker.task"
MODEL_URL = (
    "https://storage.googleapis.com/mediapipe-models/"
    "hand_landmarker/hand_landmarker/float16/latest/hand_landmarker.task"
)

HAND_CONNECTIONS = [
    (0, 1), (1, 2), (2, 3), (3, 4),  # thumb
    (0, 5), (5, 6), (6, 7), (7, 8),  # index finger
    (5, 9), (9, 10), (10, 11), (11, 12),  # Middle finger
    (9, 13), (13, 14), (14, 15), (15, 16),  # Ring finger
    (0, 17), (13, 17), (17, 18), (18, 19), (19, 20),  # Pinky
]

OPPOSITE_SIDE = {"left": "right", "right": "left"}


def ensure_model() -> None:
    print("Downloading hand landmarker model...")
    if MODEL_PATH.exists():
        return
    urllib.request.urlretrieve(MODEL_URL, MODEL_PATH)


def create_landmarker() -> Any:
    """Create the MediaPipe hand landmarker for video input."""
    options = vision.HandLandmarkerOptions(
        base_options=mp_python.BaseOptions(model_asset_path=str(MODEL_PATH)),
        running_mode=vision.RunningMode.VIDEO,
        num_hands=2,
        min_hand_detection_confidence=0.5,
        min_hand_presence_confidence=0.5,
        min_tracking_confidence=0.5,
    )
    return vision.HandLandmarker.create_from_options(options)


def extract_left_right_hand_coords(result) -> dict:
    """
    Pick the best left and best right hand from the detection result.

    Returns:
        {"left": [[x, y, z], ...] or None, "right": [[x, y, z], ...] or None}
    """
    hand_coords: dict[str, list[list[float]] | None] = {"left": None, "right": None}
    best_scores = {"left": 0.0, "right": 0.0}

    for landmarks, handedness in zip(result.hand_landmarks, result.handedness):
        label = OPPOSITE_SIDE[handedness[0].category_name.lower()]
        score = handedness[0].score

        if score > 0.5 and score > best_scores[label]:
            best_scores[label] = score
            hand_coords[label] = [[landmark.x, landmark.y, landmark.z] for landmark in landmarks]
            #print(hand_coords)

    return hand_coords


def draw_hands(frame, hand_coords: dict) -> None:
    """Draw the landmarks on the frame so we can see what is tracked."""
    height, width, _ = frame.shape

    for landmarks in hand_coords.values():
        if landmarks is None:
            continue

        points = [(int(x * width), int(y * height)) for x, y, _ in landmarks]
        for start, end in HAND_CONNECTIONS:
            cv2.line(frame, points[start], points[end], (255, 255, 0), 2) # color in BGR
        for point in points:
            cv2.circle(frame, point, 4, (0, 0, 255), -1)


def run_hand_tracking_server(server_ip: str, server_port: int) -> None:
    """Run the hand tracking and send the hand coordinates via UDP."""
    ensure_model()
    client_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    cap = cv2.VideoCapture(0)

    with create_landmarker() as landmarker:
        while cap.isOpened():
            ret, frame = cap.read()
            if not ret:
                print("Error: failed to capture image")
                break

            # miirroring the image first so left/right labels are correct
            # and the coordinates match what the player sees
            frame = cv2.flip(frame, 1)

            frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB) # converting from BGR to RGB since OpenCV wants BGR but Mediapipe RGB
            mp_image = mp.Image(image_format=mp.ImageFormat.SRGB, data=frame_rgb)
            timestamp_ms = int(time.monotonic() * 1000)
            result = landmarker.detect_for_video(mp_image, timestamp_ms)

            hand_coords = extract_left_right_hand_coords(result)

            encoded_coords = json.dumps(hand_coords)
            client_socket.sendto(encoded_coords.encode(), (server_ip, server_port))

            draw_hands(frame, hand_coords)
            cv2.imshow("Hand Tracking", frame)
            if cv2.waitKey(1) & 0xFF == ord("q"):
                break

    cap.release()
    cv2.destroyAllWindows()


if __name__ == "__main__":
    run_hand_tracking_server(SERVER_IP, SERVER_PORT)