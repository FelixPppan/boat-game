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
## --- 2. The four phases of a real single-oar stroke ----------------------
##   catch  ->  drive  ->  release  ->  recovery
## Only the drive has the blade in the water pushing aft, so only the drive
## produces thrust; the recovery is the empty return trip.
##
## The criterion is therefore "s_back is rising" -- the blade is sweeping aft.
## Whenever s_back falls, the oar is on its way back to the catch and produces
## nothing at all. Without that gate the recovery reads as reverse rowing and
## the boat twitches back and forth on the spot.
##
## Thrust is continuous, not one impulse per stroke: the blade pushes for as
## long as it is moving through the water, so the force is proportional to how
## fast the oar is sweeping rather than fired off by a once-per-stroke trigger.
## Sweep slowly and the push is gentle but unbroken; sweep hard and it is a
## single strong shove.
##
## --- 3. Splitting the force ----------------------------------------------
##   forward: sweep rate x how vertical the oar is (the more upright the oar,
##            the more of the force points straight ahead)
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
## 0.15 是实测手感正常的那一版用的值;调小会让桨一有动静就出力。
const DRIVE_DEADBAND := 0.15
## The oar lies nearly flat at both ends of the sweep (x -> 0 in the measured
## calibration), which would otherwise pinch the push down to nothing exactly
## where the stroke starts and ends. Clamping the verticality factor to this
## floor keeps the force smooth across the whole sweep instead of bulging in
## the middle.
## 扫到两端时桨几乎是平躺的(实测标定里 x → 0),不兜底的话正好在
## 一桨的头尾把推力掐到接近零、中间鼓起来。给个下限,全程就平顺了。
## 0.15 是实测手感正常的那一版用的值。
const MIN_VERTICAL := 0.15
## Dead band on the lateral rate, same idea.
## 侧向速率的死区,同理。
const LATERAL_DEADBAND := 0.15
## Lateral force gain. A sideways sweep was never going to shove the boat
## hard, so this stays small.
## 侧向力增益。横向扫桨对船的推力本来就不大,给个小系数。
const LATERAL_GAIN := 0.55
## How fore/aft a sweep has to be before its sideways component counts at full
## strength. The weight is the fore/aft share of the oar's motion, ramped 0..1
## and saturating here. Below it the sweep is mostly a sideways reposition --
## swapping the paddle from one hand to the other is almost pure lateral motion
## -- so the sideways push is scaled down in proportion; at or above it the
## sweep is an ordinary stroke and steering is untouched.
## 一次扫桨要有多「前后向」,它的侧向分量才算满力。权重 = 前后扫占整体运动的
## 比例,从 0 线性升到 1、到这里饱和。低于它说明这次主要是横向挪桨(换手),
## 侧向力按比例缩小;达到它就是正常划水,转向完全不受影响。
## 实测:正常划水的前后占比中位 0.71、5% 分位 0.39;换手动作最高只有 0.20 左右,
## 两边分得开,所以 0.6 这个门槛压得住换手、又几乎不动正常划水。
const LATERAL_FWD_SHARE := 0.6
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

	# --- 4. Stroke gate: thrust only while the blade sweeps aft -----------
	# Clamp at zero rather than taking the magnitude: a rising s_back is the
	# blade driving aft through the water, a falling one is the return. The
	# subtraction is the dead band, so an idle oar's tremor collapses to
	# nothing while a real stroke barely notices the loss.
	var drive_rate := maxf(0.0, _w_fa - DRIVE_DEADBAND)
	# Deliberately no saturation: the force stays proportional to sweep speed,
	# so a slow stroke is a long gentle push and a fast one a short hard shove.
	# The more upright the oar, the more of that force points straight ahead.
	drive_power = drive_rate / FULL_DRIVE_RATE * maxf(absf(s_vert), MIN_VERTICAL)
	# One-directional by construction, so this can never go negative: the
	# recovery contributes exactly nothing instead of pushing the boat back.
	forward_power = drive_power

	# Lateral: sweeping left (s_left growing) pushes the boat right, hence +.
	var lat_rate := _w_lat
	if absf(lat_rate) < LATERAL_DEADBAND:
		lat_rate = 0.0
	else:
		lat_rate -= signf(lat_rate) * LATERAL_DEADBAND

	# Weight the sideways push by how much of the sweep is fore/aft. Swapping the
	# paddle from one side of the body to the other swings s_left a long way with
	# no fore/aft sweep to go with it, and that must not shove the boat sideways.
	# The share is deliberately scale-invariant: it does not matter how fast or
	# how wide the swap is, only that it has no fore/aft component. A real stroke
	# is fore/aft-dominated, so the weight sits at 1 and steering is unaffected.
	var total_rate := absf(_w_fa) + absf(lat_rate)
	var fwd_share := 0.0
	if total_rate > 0.0:
		fwd_share = absf(_w_fa) / total_rate
	side_power = lat_rate * LATERAL_GAIN * clampf(
		fwd_share / LATERAL_FWD_SHARE, 0.0, 1.0)

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
## Note Godot points the bow along -Z, so forward thrust is negative z.
## forward_power is gated to >= 0, so the return stroke never pushes back.
func thrust_local() -> Vector3:
	return Vector3(side_power, 0.0, -forward_power)


## Yaw torque coefficient about Y: positive turns the bow left, negative right.
## A left-side stroke (side > 0) pushes left of the centreline, giving a
## negative torque and a bow that swings right, exactly like a real boat.
## Driven by drive_power, which is already zero on the return, so the recovery
## does not swing the bow back the other way and undo the turn.
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
