extends Node
## SensorInput -- an autoload singleton.
##
## Reads the "x,y,z\n" lines the Arduino sends over gdserial and exposes the
## latest reading to the rest of the game, while drawing a live numeric readout
## in the top-left corner so the data can be confirmed before touching boat.gd.
##
## Usage:
##   from any script, read SensorInput.x / .y / .z / .magnitude / .port_open
##   run the game and watch the numbers top-left; F1 toggles the readout.
##
## Note: the Arduino IDE's Serial Monitor must be closed, otherwise it holds
## the port and this cannot open it.

# -------------------------------------- Config / 配置调参 (中英对照) -------
## Empty = pick a port automatically at startup (every available port is
## printed to the output panel so you can check what it found). If it picks
## the wrong one, paste the name it printed in here, e.g.
## "/dev/tty.usbmodem14101".
## 留空 = 启动时自动挑一个串口(会在输出面板打印全部可用串口供你核对)。
## 如果自动挑错了,把打印出来的名字填到这里,例如 "/dev/tty.usbmodem14101"。
const PORT_NAME := ""
## Must match the value in the Arduino's Serial.begin(...) or the data arrives
## garbled. Raised to 115200 to keep up with 100 Hz sampling (see
## Arduino/paddle_sensor/paddle_sensor.ino).
## 必须和 Arduino 里 Serial.begin(...) 的值一致,否则收到的是乱码。
## 已提到 115200 以配合 100Hz 采样(详见 Arduino/paddle_sensor/paddle_sensor.ino)。
## 【改这个值的时候记住:Arduino IDE 串口监视器的波特率是另一个独立的旋钮,
##   不会跟着 sketch 变,要手动改成一样。】
const BAUD_RATE := 115200
## Read timeout in milliseconds. Only affects how long a read blocks when
## there is nothing to read; it does not affect the sample rate.
## 读超时(毫秒)。只影响读不到数据时多久返回,不影响采样频率。
const READ_TIMEOUT_MS := 200
## Key that shows/hides the readout.
## 显示/隐藏左上角读数的按键。
const TOGGLE_KEY := KEY_F1

# ------------------------------------------------------------------- State --
var x: float = 0.0
var y: float = 0.0
var z: float = 0.0
## Resultant length, sqrt(x*x + y*y + z*z). Near 9.8 (1g) at rest.
var magnitude: float = 0.0
## Whether the serial port is currently open.
var port_open: bool = false
## The last complete raw line, for troubleshooting.
var last_line: String = ""
## Lines parsed successfully / lines that failed to parse.
var good_lines: int = 0
var bad_lines: int = 0
## Measured lines per second, to verify the sample rate (target 100).
var hz: float = 0.0

var _manager: GdSerialManager
var _port: String = ""
var _overlay: CanvasLayer
var _label: Label
var _overlay_visible := true
var _status: String = "starting…"
var _hz_accum: float = 0.0
var _hz_mark: int = 0


# -------------------------------------------------------------- Lifecycle --
func _ready() -> void:
	_manager = GdSerialManager.new()
	_manager.data_received.connect(_on_data)
	_manager.port_disconnected.connect(_on_disconnected)
	_build_overlay()
	_open_port()


func _exit_tree() -> void:
	if _manager != null and _port != "":
		_manager.close(_port)


func _process(delta: float) -> void:
	if _manager != null:
		# poll_events must be called every frame or the signals never fire.
		_manager.poll_events()
		if _port != "":
			port_open = _manager.is_open(_port)
	_update_hz(delta)
	_refresh_overlay()


## Counts the lines actually received once per second, to check whether the
## sample rate really is hitting 100.
func _update_hz(delta: float) -> void:
	_hz_accum += delta
	if _hz_accum >= 1.0:
		hz = float(good_lines - _hz_mark) / _hz_accum
		_hz_mark = good_lines
		_hz_accum = 0.0


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == TOGGLE_KEY:
		_overlay_visible = not _overlay_visible
		if _overlay != null:
			_overlay.visible = _overlay_visible


# ------------------------------------------------------------ Serial port --
func _open_port() -> void:
	var candidates := _candidate_ports()
	if candidates.is_empty():
		_status = "no usable serial port"
		push_warning("[SensorInput] No serial ports found. Plug in the Arduino, close the Serial Monitor, then rerun.")
		return

	# Try them in order; each candidate also gets an automatic macOS
	# /dev/cu. variant.
	var tried: Array[String] = []
	for cand in candidates:
		if _manager.open(cand, BAUD_RATE, READ_TIMEOUT_MS,
				GdSerialManager.MODE_LINE_BUFFERED):
			_port = cand
			port_open = true
			_status = "%s @ %d" % [cand, BAUD_RATE]
			print("[SensorInput] Opened port: ", _status)
			return
		tried.append(cand)

	_status = "open failed (%d ports tried)" % tried.size()
	push_error("[SensorInput] Could not open any of: " + ", ".join(PackedStringArray(tried)))
	push_error("[SensorInput] Check in this order: (1) close the Arduino IDE Serial Monitor (or the whole IDE); (2) run `lsof | grep -i usb` in a terminal to see what is holding the port; (3) try another cable (some are power-only); (4) unplug and replug the USB.")


## Builds the list of port names to try: explicit choice > auto-picked > every
## USB serial port, each with a macOS /dev/cu. variant added (cu opens more
## reliably than tty).
func _candidate_ports() -> Array[String]:
	var raw: Array[String] = []
	if PORT_NAME != "":
		raw.append(PORT_NAME)
	else:
		var picked := _pick_port()
		if picked != "":
			raw.append(picked)
		for pname in _list_port_names():
			if _looks_usb(pname):
				raw.append(pname)

	var out: Array[String] = []
	for pname in raw:
		if not out.has(pname):
			out.append(pname)
		var cu := _cu_variant(pname)
		if cu != pname and not out.has(cu):
			out.append(cu)
	return out


func _pick_port() -> String:
	var ports: Dictionary = _manager.list_ports()
	print("[SensorInput] === available ports ===")
	if ports.is_empty():
		print("  (none)")
		return ""

	var names: Array[String] = []
	for key in ports.keys():
		var info: Dictionary = ports[key]
		var pname := str(info.get("port_name", ""))
		names.append(pname)
		print("  ", pname, "   [", str(info.get("device_name", "")), "]   ",
			str(info.get("port_type", "")))

	# Prefer a USB serial adapter, which is what an Arduino normally is.
	for pname in names:
		if _looks_usb(pname):
			return pname

	# Nothing suitable, so fall back to the first one.
	return names[0]


func _list_port_names() -> Array[String]:
	var out: Array[String] = []
	var ports: Dictionary = _manager.list_ports()
	for key in ports.keys():
		var info: Dictionary = ports[key]
		out.append(str(info.get("port_name", "")))
	return out


## macOS: /dev/tty.usbmodem14101 -> /dev/cu.usbmodem14101. Returned unchanged
## on every other platform.
func _cu_variant(port: String) -> String:
	if port.begins_with("/dev/tty."):
		return "/dev/cu." + port.substr("/dev/tty.".length())
	return port


func _looks_usb(pname: String) -> bool:
	return pname.begins_with("/dev/tty.usb") or pname.begins_with("/dev/cu.usb") \
		or pname.begins_with("/dev/ttyUSB") or pname.begins_with("/dev/ttyACM") \
		or pname.begins_with("COM")


func _on_data(port: String, data: PackedByteArray) -> void:
	# Decode as ASCII: the payload is nothing but digits, commas and newlines.
	# Decoding as UTF-8 floods the console with "Unicode parsing error" the
	# moment a byte is malformed (e.g. garbled output when the baud is wrong).
	var text := data.get_string_from_ascii().strip_edges()
	if text.is_empty():
		return
	last_line = text

	var parts := text.split(",", false)
	if parts.size() != 3:
		bad_lines += 1
		return

	var sx := str(parts[0]).strip_edges()
	var sy := str(parts[1]).strip_edges()
	var sz := str(parts[2]).strip_edges()
	if not (sx.is_valid_float() and sy.is_valid_float() and sz.is_valid_float()):
		bad_lines += 1
		return

	x = sx.to_float()
	y = sy.to_float()
	z = sz.to_float()
	magnitude = sqrt(x * x + y * y + z * z)
	good_lines += 1


func _on_disconnected(port: String) -> void:
	port_open = false
	_status = "disconnected: %s" % port
	push_warning("[SensorInput] Port disconnected: " + port)


# ----------------------------------------------------------------- Readout --
func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 100
	add_child(_overlay)

	_label = Label.new()
	_label.position = Vector2(16.0, 16.0)
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color(0.08, 0.10, 0.12))
	_label.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_label.add_theme_constant_override("outline_size", 6)
	_overlay.add_child(_label)


func _refresh_overlay() -> void:
	if _label == null:
		return
	var dot := "●" if port_open else "○"
	_label.text = "%s sensor %s\nx = %8.2f   y = %8.2f   z = %8.2f\n|a| = %6.2f   %.0f Hz   lines %d / bad %d" % [
		dot, _status, x, y, z, magnitude, hz, good_lines, bad_lines]
