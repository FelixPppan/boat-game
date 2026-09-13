class_name OarController
extends Node
## Single-oar control algorithm: turns the ADXL345's three axes into
## "oar pose + stroke effort", then into the thrust / lateral force / yaw
## torque applied to the boat.
##
## --- 1. Sensor mounting orientation (the measured calibration) -----------
##   blade straight down        x ~ -10   y ~   0   z ~   0
##   held flat out to the left  x ~   0   y ~ -10   z ~   0
##   held flat out to the right x ~   0   y ~ +10   z ~   0
##   held flat forward          x ~   0   y ~   0   z ~ -10
##   swept flat back            x ~   0   y ~   0   z ~ +10
##
## Full scale is +/-10 (gravity, ~9.8, sits in that range): whichever axis
## points down reads full scale, and the axis perpendicular to it reads 0.
##
## At rest the reading is gravity projected onto the three axes, so those five
## poses really say "which axis points down". Dividing by the vector length
## (normalising) gives three components whose squares always sum to 1:
##
##   s_vert = -x / |a|   how vertical the oar is    1 = fully vertical
##   s_left = -y / |a|   how far out to the left    +1 = fully flat left
##   s_back =  z / |a|   how far swept aft          +1 = flat back, -1 = forward
##
## Normalise by |a| rather than by a fixed 9.81, for three reasons:
##   1. only the oar's direction matters, not the absolute magnitude;
##   2. no need to guess this chip's absolute scale (full scale +/-10, with
##      gravity landing around 9.8);
##   3. normalised, the components satisfy s_vert^2 + s_left^2 + s_back^2 = 1,
##      so the pose is a point on the unit sphere and both the angles and the
##      rates come out clean.
##
## --- 2. Thrust is continuous, not one impulse per stroke -----------------
## The blade pushes for as long as it is moving through the water, so the force
## is proportional to how fast the oar is sweeping -- not fired off by a
## once-per-stroke trigger. Sweep slowly and the push is gentle but unbroken;
## sweep hard and it is a single strong shove. Fast rowing is one hard burst of
## speed, slow rowing a steady slow push.
##
## The two sweep directions are NOT equal. Sweeping aft the blade is buried and
## grips the water (DRIVE_GRIP); sweeping forward it is feathered and travelling
## back to the catch, so it grips far less (RECOVERY_GRIP). That asymmetry is
## what lets a stroke cycle make headway -- grip equally both ways and the two
## halves cancel out and the boat sits still. It also means the return stroke
## pushes back a little instead of the boat free-coasting on, which is what
## keeps the motion tied to the oar rather than running on until the next stroke.
##
## --- 3. Splitting the force ----------------------------------------------
##   forward: sweep rate x grip x how vertical the oar is (the more upright the
##            oar, the more of the force points straight ahead)
##   lateral: rate of sideways sweep (sweeping the blade left pushes the
##            boat right)
##   yaw:     a left-side stroke pushes at the blade, which sits left of the
##            centreline, so the bow swings right (physically correct)
##
## Every tunable lives in the "Tuning" block below.

# ------------------------------------------- Tuning / 调参 (中英对照) ------
## Low-pass time constant for the readings, in seconds. Larger = smoother but
## more sluggish.
## 读数低通滤波时间常数(秒)。越大越平稳、越迟钝。
const FILTER_TAU := 0.025
## Time constant for the rates. Differentiation amplifies noise, so this one
## is deliberately duller than the filter above.
## 变化率(角速度)的滤波时间常数。微分会放大噪声,所以这里压得更钝。
const RATE_TAU := 0.04
## Which sweep direction grips the water. +1 = sweeping aft (s_back rising) is
## the power stroke, -1 = the other way about. Flip this single value if the
## power stroke turns out mirrored on the real hardware.
## 哪个方向算「抓水」的动力行程。+1 = 向后扫(s_back 增大)是动力行程,
## -1 则相反。如果实机上动力行程正好反了,只改这一个值。
const SWEEP_SIGN := 1.0
## Sweep rate, per second, that counts as a full-power stroke. The response is
## linear up to here rather than clipped at it, so a slow sweep gets a
## proportionally gentle push instead of being cut off.
## 每秒扫过多少算「满力」。到这之前是线性的、不是硬削顶的,
## 所以慢扫桨得到的是成比例的轻推,不会被一刀切掉。
## 实测一桨 s_back 大约 -1 → +1、用时 0.6~0.9 秒,即变化率约 2.2~3.3,故取中间值 2.6。
## 想让划水更灵敏就调小;想更难划满力就调大。
const FULL_DRIVE_RATE := 2.6
## Dead band on the sweep rate, per second. Anything smaller is treated as hand
## tremor and dropped, so an idle oar never nudges the boat. It has to stay
## well below a deliberate slow stroke, or slow rowing stops moving the boat.
## 扫速死区(每秒)。低于它的一律当手抖丢掉,桨放着不动时船不会自己跑。
## 必须明显小于「故意慢划」的速度,否则慢划就推不动船了。
const DRIVE_DEADBAND := 0.06
## How hard the blade bites on the power stroke, and on the return. The return
## value is small but not zero: a feathered blade still drags a little, so the
## boat slows instead of drifting on. Set it to 0.0 and the return stroke
## produces nothing at all, leaving the boat to coast.
## 动力行程 / 回桨行程各抓多少水。回桨给一个小值但不给 0:
## 桨叶平着回去也还是有一点阻力,船会慢下来,而不是一路干滑。
## 改成 0.0 则回桨完全不产生力,船就纯靠惯性滑。
const DRIVE_GRIP := 1.0
const RECOVERY_GRIP := 0.3
## The oar lies nearly flat at both ends of the sweep (x -> 0 in the measured
## calibration), which would otherwise pinch the push down to nothing exactly
## where the stroke starts and ends. Clamping the verticality factor to this
## floor keeps the force smooth across the whole sweep instead of bulging in
## the middle.
## 扫到两端时桨几乎是平躺的(实测标定里 x → 0),不兜底的话正好在
## 一桨的头尾把推力掐到接近零、中间鼓起来。给个下限,全程就平顺了。
const MIN_VERTICAL := 0.45
## Dead band on the lateral rate, same idea.
## 侧向速率的死区,同理。
const LATERAL_DEADBAND := 0.15
## Lateral force gain. A sideways sweep was never going to shove the boat
## hard, so this stays small.
## 侧向力增益。横向扫桨对船的推力本来就不大,给个小系数。
const LATERAL_GAIN := 0.55
## Lateral offset of the blade from the boat's centreline, in metres. Sets how
## much yaw torque a given amount of thrust produces.
## 桨叶到船中线的侧向距离(米)。决定同样大的推力能产生多大的转向力矩,
## 也就是船头转得多快。想转向更利落就调大。
const OARLOCK_OFFSET := 0.6
## Hysteresis threshold for deciding the side. The side only flips once
## |s_left| exceeds this, otherwise s_left would cross zero for an instant as
## the oar sweeps through vertical and the bow would twitch left and right.
## 左右判定的滞回阈值。|s_left| 超过它才改判左右,免得桨扫过竖直方向时
## s_left 瞬时过零、左右来回跳、船头乱抖。
const SIDE_HYSTERESIS := 0.08
## Start / end thresholds for counting a stroke. Power rising past ON opens
## the stroke; falling back below OFF closes it.
## 记一桨的起止阈值(滞回):力度升过 ON 开始计数,跌回 OFF 以下算这一桨结束。
## 只在左下角角标的「已划 N 桨」和「上一桨力度」里用到,不影响推力。
const STROKE_ON := 0.28
const STROKE_OFF := 0.12

# ------------------------------------------------------------------ State --
## Whether usable sensor data is coming in. While false, boat.gd falls back
## to the keyboard. Not named "ready" to avoid clashing with Node's signal.
var sensor_ready := false
## Normalised pose components; the squares always sum to 1.
var s_vert := 1.0
var s_left := 0.0
var s_back := 0.0
## Lateral and fore/aft angles in degrees. Lateral + is left, fore/aft + is aft.
var ang_lat := 0.0
var ang_fa := 0.0
## Which side the oar is on: +1 left, -1 right, 0 not yet decided.
var side := 0.0
## Drive effort at this instant: 0 = coasting, 1 = full power.
var drive_power := 0.0
## The split components (forward is >= 0, lateral carries its sign).
var forward_power := 0.0
var side_power := 0.0

## Updated once per completed stroke:
var stroke_count := 0
##   peak effort of the previous stroke (0..1+)
var last_stroke_power := 0.0
##   which side the previous stroke was on (+1 left / -1 right)
var last_stroke_side := 0.0

## Deliberately untyped. SensorInput is an autoload singleton whose script
## declares no class_name, so `var _src: Node` makes the static analyser fail
## with "no member port_open / x / y / z on Node" and the whole script stops
## compiling. Leaving it as a Variant resolves those lookups dynamically.
var _src = null
var _fx := 0.0
var _fy := 0.0
var _fz := 0.0
var _w_lat := 0.0
var _w_fa := 0.0
var _prev_left := 0.0
var _prev_back := 0.0
var _primed := false
var _in_stroke := false
var _stroke_peak := 0.0
var _stroke_side := 0.0

var _overlay: CanvasLayer
var _label: Label
var _overlay_visible := true


func _ready() -> void:
	# Looked up by path rather than spelled as SensorInput, so a missing
	# autoload degrades gracefully instead of crashing.
	_src = get_node_or_null("/root/SensorInput")
	if _src == null:
		push_warning("[OarController] SensorInput autoload missing; keyboard only.")
	_build_overlay()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F2:
		_overlay_visible = not _overlay_visible
		if _overlay != null:
			_overlay.visible = _overlay_visible


# -------------------------------------------------------------- Main loop --
## Called once per physics frame. delta is the physics delta; it has nothing
## to do with the sensor's sample rate.
func update(delta: float) -> void:
	if _src == null or not _src.port_open or delta <= 0.0:
		sensor_ready = false
		drive_power = 0.0
		forward_power = 0.0
		side_power = 0.0
		_refresh_overlay()
		return

	# --- 1. Low-pass filter: sensor noise and impact spikes --------------
	var a := 1.0 - exp(-delta / FILTER_TAU)
	_fx = lerp(_fx, _src.x, a)
	_fy = lerp(_fy, _src.y, a)
	_fz = lerp(_fz, _src.z, a)

	var mag := sqrt(_fx * _fx + _fy * _fy + _fz * _fz)
	if mag < 1.0:
		# A tiny resultant means we are not in a gravity field at all
		# (free fall, or simply garbage) -- nothing here can be trusted.
		sensor_ready = false
		drive_power = 0.0
		forward_power = 0.0
		side_power = 0.0
		_refresh_overlay()
		return
	sensor_ready = true

	# --- 2. Pose decomposition -------------------------------------------
	s_vert = clampf(-_fx / mag, -1.0, 1.0)
	s_left = clampf(-_fy / mag, -1.0, 1.0)
	s_back = clampf(_fz / mag, -1.0, 1.0)
	ang_lat = rad_to_deg(asin(s_left))
	ang_fa = rad_to_deg(asin(s_back))

	# Hysteresis on the side, so the oar sweeping through vertical does not
	# make it flip back and forth.
	if absf(s_left) > SIDE_HYSTERESIS:
		side = signf(s_left)

	# --- 3. Rates (difference, then filter) ------------------------------
	var raw_w_lat := (s_left - _prev_left) / delta
	var raw_w_fa := (s_back - _prev_back) / delta
	_prev_left = s_left
	_prev_back = s_back
	if not _primed:
		# The first frame has no predecessor to difference against, which
		# would blow up into a bogus spike. Throw it away.
		_primed = true
		raw_w_lat = 0.0
		raw_w_fa = 0.0
	var b := 1.0 - exp(-delta / RATE_TAU)
	_w_lat = lerp(_w_lat, raw_w_lat, b)
	_w_fa = lerp(_w_fa, raw_w_fa, b)

	# --- 4. Continuous thrust, proportional to sweep speed ----------------
	# Signed sweep rate: positive is the power stroke (sweeping aft by default),
	# negative is the return. SWEEP_SIGN flips that convention.
	var sweep := _w_fa * SWEEP_SIGN
	# Subtract the dead band: standing still the tremor collapses to zero, while
	# a real stroke barely notices the loss.
	if absf(sweep) < DRIVE_DEADBAND:
		sweep = 0.0
	else:
		sweep -= signf(sweep) * DRIVE_DEADBAND

	# The blade bites hard one way and barely at all coming back.
	var grip := RECOVERY_GRIP if sweep < 0.0 else DRIVE_GRIP
	# Deliberately no saturation: the force stays proportional to sweep speed,
	# so a slow stroke is a long gentle push and a fast one a short hard shove.
	# The more upright the oar, the more of that force points straight ahead.
	forward_power = clampf(
		sweep * grip / FULL_DRIVE_RATE * maxf(absf(s_vert), MIN_VERTICAL),
		-1.5, 1.5)

	# Only the positive part: this is what the overlay calls "power" and what the
	# stroke counter tallies, so the return stroke does not count as a stroke.
	drive_power = maxf(forward_power, 0.0)

	# Lateral: sweeping left (s_left growing) pushes the boat right, hence +.
	var lat_rate := _w_lat
	if absf(lat_rate) < LATERAL_DEADBAND:
		lat_rate = 0.0
	else:
		lat_rate -= signf(lat_rate) * LATERAL_DEADBAND
	side_power = lat_rate * LATERAL_GAIN

	_update_stroke_stats()

	_refresh_overlay()


## Per-stroke bookkeeping: power rising past ON opens a stroke, falling back
## below OFF closes it and records that stroke's peak and side.
func _update_stroke_stats() -> void:
	if not _in_stroke:
		if drive_power > STROKE_ON:
			_in_stroke = true
			_stroke_peak = drive_power
			_stroke_side = side
		return

	if drive_power > _stroke_peak:
		_stroke_peak = drive_power
	if drive_power < STROKE_OFF:
		_in_stroke = false
		stroke_count += 1
		last_stroke_power = _stroke_peak
		last_stroke_side = _stroke_side


# --------------------------------------------------------- Boat interface --
## Thrust in the boat's own frame: x = right, z = back.
## Note Godot points the bow along -Z, so forward thrust is negative z. A
## negative forward_power is the return stroke, and pushes the boat backwards.
func thrust_local() -> Vector3:
	return Vector3(side_power, 0.0, -forward_power)


## Yaw torque coefficient about Y: positive turns the bow left, negative right.
## A left-side stroke (side > 0) pushes left of the centreline, giving a
## negative torque and a bow that swings right, exactly like a real boat.
## Driven by the power phase only, so the feathered return does not swing the
## bow back the other way and undo the turn.
func yaw_torque() -> float:
	return -drive_power * OARLOCK_OFFSET * side


# ---------------------------------------------------------------- Overlay --
func _side_text(v: float) -> String:
	if v > 0.0:
		return "L"
	if v < 0.0:
		return "R"
	return "-"


func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 99   # below SensorInput's 100, so both readouts stay put
	add_child(_overlay)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(root)

	_label = Label.new()
	# Pinned to the bottom-left corner, with a fixed height for three lines of
	# text and the text bottom-aligned inside it.
	_label.anchor_left = 0.0
	_label.anchor_top = 1.0
	_label.anchor_right = 0.0
	_label.anchor_bottom = 1.0
	_label.offset_left = 16.0
	_label.offset_top = -110.0
	_label.offset_right = 760.0
	_label.offset_bottom = -16.0
	_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color(0.08, 0.10, 0.12))
	_label.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_label.add_theme_constant_override("outline_size", 6)
	root.add_child(_label)


func _refresh_overlay() -> void:
	if _label == null:
		return
	if not sensor_ready:
		_label.text = "○  Oar: no sensor data (hold WASD to test)"
		return

	var phase := "DRIVE" if drive_power > STROKE_OFF else "RECOVER"
	_label.text = (
		"●  Oar %s      lateral %s°      fore/aft %s°\n" % [
			_side_text(side), _f1(ang_lat), _f1(ang_fa)]
		+ "%s    power %.2f      fwd %s / lat %s\n" % [
			phase, drive_power, _f2(forward_power), _f2(side_power)]
		+ "strokes %d      last %.2f (%s)" % [
			stroke_count, last_stroke_power, _side_text(last_stroke_side)]
	)


## One or two decimals with an explicit sign. The "+" format flag is avoided:
## whether Godot's sprintf implements it is not something to bet the whole
## string on, since an unsupported flag blanks the entire result.
func _f1(v: float) -> String:
	return "%s%.1f" % ["+" if v >= 0.0 else "-", absf(v)]


func _f2(v: float) -> String:
	return "%s%.2f" % ["+" if v >= 0.0 else "-", absf(v)]
