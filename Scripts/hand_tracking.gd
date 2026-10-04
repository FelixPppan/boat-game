extends Node
## Receives hand landmarks from python/hand_tracking.py over UDP.
const PORT: int = 4242
const TIMEOUT: float = 0.5
# MediaPipe landmark ids
const WRIST: int = 0
const THUMB_TIP: int = 4
const INDEX_TIP: int = 8
const MIDDLE_MCP: int = 9

# 21 points per hand
# Empty when the hand is not visible.
var left_hand: Array[Vector3] = []
var right_hand: Array[Vector3] = []

var _udp := PacketPeerUDP.new()
var _time_since_packet: float = 0.0

func _ready() -> void:
	if _udp.bind(PORT, "127.0.0.1") != OK:
		push_error("HandTracking: could not bind UDP port %d" % PORT)

func _process(delta: float) -> void:
	# Only use the newest packet, older ones would just add lag
	var packet := PackedByteArray()
	while _udp.get_available_packet_count() > 0:
		packet = _udp.get_packet()

	if packet.is_empty():
		_time_since_packet += delta
		if _time_since_packet > TIMEOUT:
			left_hand.clear()
			right_hand.clear()
		return

	_time_since_packet = 0.0
	var data = JSON.parse_string(packet.get_string_from_utf8())
	if data is Dictionary:
		left_hand = _to_landmarks(data.get("left"))
		right_hand = _to_landmarks(data.get("right"))

func _to_landmarks(raw) -> Array[Vector3]:
	var landmarks: Array[Vector3] = []
	if raw == null:
		return landmarks
	for point in raw:
		landmarks.append(Vector3(point[0], point[1], point[2]))
	return landmarks

func get_hand(side: String) -> Array[Vector3]:
	return left_hand if side == "left" else right_hand

func to_screen(landmark: Vector3, screen_size: Vector2) -> Vector2:
	return _flat(landmark) * screen_size

# Point between thumb tip and index tip, steady while pinching
func get_pinch_point(hand: Array[Vector3]) -> Vector3:
	return (hand[THUMB_TIP] + hand[INDEX_TIP]) / 2.0

# Thumb to index distance divided by palm size, small number means pinching.
# Dividing by the palm size makes it independent of the distance to the camera.
func get_pinch_ratio(hand: Array[Vector3]) -> float:
	var palm_size := _flat(hand[WRIST]).distance_to(_flat(hand[MIDDLE_MCP]))
	var pinch_distance := _flat(hand[THUMB_TIP]).distance_to(_flat(hand[INDEX_TIP]))
	return pinch_distance / maxf(palm_size, 0.001)

func _flat(landmark: Vector3) -> Vector2:
	return Vector2(landmark.x, landmark.y)
