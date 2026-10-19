extends Node
## Receives hand landmarks from python/hand_tracking.py over UDP.
const PORT: int = 4242
const TIMEOUT: float = 0.5
# MediaPipe landmark ids
const WRIST: int = 0
const THUMB_MCP: int = 2
const THUMB_IP: int = 3
const THUMB_TIP: int = 4
const INDEX_MCP: int = 5
const INDEX_PIP: int = 6
const INDEX_TIP: int = 8
const MIDDLE_MCP: int = 9
const MIDDLE_PIP: int = 10
const MIDDLE_TIP: int = 12
const RING_PIP: int = 14
const RING_TIP: int = 16
const PINKY_PIP: int = 18
const PINKY_TIP: int = 20

const CURLED_FINGERS := [
	[INDEX_TIP, INDEX_PIP], [MIDDLE_TIP, MIDDLE_PIP],
	[RING_TIP, RING_PIP], [PINKY_TIP, PINKY_PIP],
]

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

# Thumb pointing up above a closed fist. Image y grows downward, so "up" means a smaller y.
func is_thumbs_up(hand: Array[Vector3]) -> bool:
	var wrist := _flat(hand[WRIST])
	var palm_size := wrist.distance_to(_flat(hand[MIDDLE_MCP]))
	if palm_size < 0.001:
		return false
	var tip := _flat(hand[THUMB_TIP])
	var ip := _flat(hand[THUMB_IP])
	var mcp := _flat(hand[THUMB_MCP])
	if tip.y > ip.y or ip.y > mcp.y:
		return false
	var rise := mcp.y - tip.y
	if rise < 0.6 * palm_size or absf(tip.x - mcp.x) > rise * 0.7:
		return false
	if tip.y > _flat(hand[INDEX_MCP]).y - 0.3 * palm_size:
		return false
	for finger in CURLED_FINGERS:
		if wrist.distance_to(_flat(hand[finger[0]])) > wrist.distance_to(_flat(hand[finger[1]])):
			return false
	return true

func _flat(landmark: Vector3) -> Vector2:
	return Vector2(landmark.x, landmark.y)
