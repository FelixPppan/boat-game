class_name OarController
extends Node

## The oar's rule, two parts: which half of the stroke is the drive, and how hard.
##
##     sweep = -gx                                    # + = aft sweep
##     drive_sign = the half whose peak beats the half before it   (a latch -- the
##                  only state in this file; it holds the direction across the air
##                  return, so the output is one push per stroke)
##     forward_power = clamp((|sweep| - DEAD) / (FULL - DEAD), 0, 1)
##
## Which half is loaded cannot be read off the gyro. Forward and reverse rowing make the
## same waveform and differ only in which half has the blade in the water, and only that
## half propels -- so no sign, threshold or filter recovers it. But the loaded half is
## always the deeper and heavier one too, so comparing a stroke's two halves answers the
## question without ever asking about the water. The four takes behind DRIVE_RATIO settled
## that.
##
## The throttle therefore stays one line: no load gate, no hysteresis, no cooldown, no
## sign test. No load gate also means waving the oar in the air drives the boat -- an
## accepted gap, because |a|/g ran 0.169..6.808 on 2026-09-29 with the extremes in
## confirmed water strokes, so no |a| threshold separates water from air.
##
## Absolute speed is not these knobs' job -- that is boat.gd's `max_thrust`; a ~27% duty
## cycle caps the mean power by itself. The oar's side is another axis: see SIDE_SIGN. The
## ADXL345 rate-of-change rule that used to live here is deleted, not ported.
##
## 桨的规则分两半:哪半圈是动力段,以及那半圈划得多重。
##
##     sweep = -gx                                    # + = 向后扫
##     drive_sign = 峰值压过前一段的那半圈          (一个锁存器 —— 这个文件里唯一的状态;
##                  它在整个空回期间保持方向不变,所以输出是一桨一下)
##     forward_power = clamp((|sweep| - DEAD) / (FULL - DEAD), 0, 1)
##
## 哪半圈吃水,陀螺仪读不出来。向前划和向后划的波形一模一样,区别只在哪半圈桨叶在水里,而只有
## 那半圈给力 —— 符号、阈值、滤波都变不出这个信息。但吃水那半圈同时也永远是更深、更沉的那半圈,
## 所以把一桨的两半圈比一比就有答案,从头到尾不用问水的事。依据是 DRIVE_RATIO 里那四份实录。
##
## 于是油门仍然只有一行:没有载荷门槛、没有滞回、没有冷却、没有符号判据。没有载荷门槛也意味着
## 空中挥桨照样推船 —— 这是明确接受的缺口:|a|/g 在 2026-09-29 那份实录里跑了 0.169..6.808,
## 极端值都在确认为水里的桨上,所以没有任何 |a| 阈值能把水和空气分开。
##
## 绝对速度不是这两个旋钮的事 —— 那是 boat.gd 的 `max_thrust`;约 27% 的占空比自己就把平均功率
## 压住了。桨在哪一舷是另一根轴:见 SIDE_SIGN。原来那套 ADXL345 差分规则是删掉的,没有移植。

# --------------------------------------------------------------- Constants --
## How far off the centreline the oarlock sits, in metres. Only scales the yaw the
## power stroke makes; the boat's own numbers do the rest.
## 桨架离中线的距离(米)。只用来说明动力段产生的偏转力矩有多大,其余的交给船自己的参数。
const OARLOCK_OFFSET := 0.6

## Where the yaw stops growing, as a multiple of a stroke that just reaches `full`.
## The turn follows the sweep, not the clamped throttle: at the full notch it is
## exactly what a proportional yaw gave, and past it the boat keeps coming round
## harder, up to this. The take's deepest stroke is 327 deg/s against a 150 full
## notch, so on the deepest strokes the boat now turns about twice as hard as one
## that only reaches the notch -- which is the whole point of the number. Without a
## ceiling a stroke far past the notch would spin the hull regardless of
## `max_yaw_rate`, and the knob is only clamped to the meter, not to the physics.
## 偏转增长的封顶倍数,基准是「刚好到 full 缺口」的那一桨。转向跟着扫速走,不跟着被削平的
## 油门走:在 full 缺口上它和不削顶的线性做法一模一样,过了缺口船头继续更快地转,一直到这个
## 倍数。实录里最深的一桨是 327 deg/s、而 full 缺口在 150,所以深划那几次的转向差不多是
## 「刚好够到缺口」的两倍 —— 这个数存在的意义就是这个。不封顶的话,远超缺口的一桨会让船体
## 不管 `max_yaw_rate` 地打转,而旋钮只被轨道夹住、没被物理夹住。
const YAW_DEPTH_MAX := 2.0

## One-pole low-pass on gx, in seconds. Short on purpose: it is here to blunt the
## blade slap as the oar enters the water, not to smooth the stroke. A power lobe
## lasts 0.2..0.55 s, so a longer time constant would both flatten it and lag its
## peak. The thing that actually holds the resting noise down is the deadband, not
## this filter.
## gx 上的一阶低通,单位秒。故意很短:它是用来钝化桨叶入水那一下的拍击,不是用来平滑整段桨
## 的。动力段只有 0.2..0.55 秒,时间常数再长就会把波形压平、还会让峰值滞后。真正压住静置
## 噪声的是门槛,不是这个滤波器。
const FILTER_TAU := 0.025

## The shipped pair. Scored on the 2026-09-29 take, 3..24 s rowing window, 15
## strokes: mean power 0.18 at a 27% duty cycle, so the mean thrust this feeds the
## boat is 0.18 x boat.gd's `max_thrust` -- what speed that settles at is boat.gd's
## numbers, not these. The resting noise floor is 6.5 deg/s, so 40 carries 6x
## headroom -- across all 1191 resting samples in that take the rule paid exactly
## nothing at every deadband from 20 to 150.
##
## 40 with 150 leaves 13 of those 15 strokes saturating at peak power, so the
## effort response is mostly clipped toward the end. Raising `full` buys dynamic
## range back and costs mean thrust (full 330 halves it, and the boat barely moves).
## 150 is shipped as the middle of that trade; both numbers are live on the panel,
## so the feel decides.
## 出厂值。在 2026-09-29 那份实录的 3..24 秒窗口上打分(15 次桨):平均功率 0.18、占空比
## 27%,所以喂给船的平均推力是 0.18 × boat.gd 的 `max_thrust` —— 稳态跑到多快是船那边的
## 数字决定的,不是这两个。静置噪声地板 6.5 deg/s,所以 40 有 6 倍余量 —— 那份实录里 1191
## 个静置样本,门槛从 20 到 150 一个都没漏。
##
## 40 配 150 会让那 15 次桨里有 13 次在峰值功率上饱和,所以后半段的力量响应基本被削平了。
## 把 full 调大能换回动态范围,代价是平均推力减半(330),船几乎不动。出厂取 150 是这笔交易
## 的中段;两个数在面板上都能现场调,手感说了算。
const SWEEP_DEADBAND_DEFAULT := 40.0
const SWEEP_FULL_DEFAULT := 150.0

## Where the sweep stops counting as a section of a stroke at all, in deg/s. This is
## delimitation only -- it cuts the stream into half-cycles so that two of them can be
## compared. Deliberately NOT the deadband: the deadband is what the player tunes for
## feel, and tuning it must not re-cut the sections the latch compares.
## 扫速低于这个值就不算一段了,单位 deg/s。只用来切段:把数据流切成半圈,好让两半圈能比。
## 故意不用门槛 —— 门槛是玩家按手感调的,调它不能把锁存器比较的切段也改了。
const LOBE_FLOOR := 25.0

## How much longer than the section before it the sweep has to stay below LOBE_FLOOR
## before that section is closed. The take's two halves are separated by ~0.1 s at the
## reversal, so this has 3x headroom there, and the gap between one stroke and the next
## is much longer: nothing gets split in the middle, and nothing gets merged across.
## 低于 LOBE_FLOOR 持续多久才算一段结束。实录里两半圈在换向处的间隔约 0.1 秒,所以这里有
## 3 倍余量;而一桨和下一桨之间的空档要长得多:中间不会被劈开,两桨之间也不会被并起来。
const LOBE_GAP := 0.30

## How much deeper than the section before it a section has to get before it is taken
## to be the drive. In the four labelled takes -- forward 17:33, forward 20:40 and
## backward 20:41, counted over both blocks of the 20:40 file -- the drive half beat
## the air return by 1.16x at the closest and about 2.6x typically, and in all 48
## complete cycles the deeper half and the |a|-heavier half were the same half. 1.10
## sits under every measured cycle while still refusing to react to two comparable
## sections, which is what keeps the latch from flapping.
## 一段要比前一段深多少才算动力段。在四份带标注的实录上量过(17:33 正向、20:40 正向、
## 20:41 反向,20:40 那份的两段各算一份):动力段比空回深,最接近的一桨是 1.16 倍,典型
## 约 2.6 倍;48 个完整桨周期里,「更深」和「|a| 更沉」永远是同一半圈。1.10 落在每一个实测
## 周期之下,又不会对「两段差不多深」做出反应 —— 后者正是让锁存器不抖的原因。
const DRIVE_RATIO := 1.10

## The shallowest section allowed to set the direction on its own, in deg/s. The takes'
## air returns run 41..142 deg/s, so a section only just over the deadband is not
## evidence of anything and must not move the latch.
## 能单独决定方向的最浅一段,单位 deg/s。实录里的空回是 41..142 deg/s,所以一段刚过门槛的
## 扫动什么都证明不了,不许它动锁存器。
const DRIVE_MIN := 60.0

## How long a finished section stays evidence, in seconds. Longer than the gap between
## two strokes, so ordinary rowing always compares against a real neighbour; past it,
## "the section before" is stale and counts for nothing, and the latch then demands a
## stroke at the full notch before it will change direction. That is also the state a
## fresh boat starts in, so the very first stroke can only claim the direction if it is
## a full stroke rather than a nudge.
## 一段划完之后还算证据多久,单位秒。比两桨之间的间隔长,所以正常划桨永远拿真实的前一段来
## 比;超过之后「前一段」就过期、完全不算数,这时锁存器要求一桨达到 full 缺口才肯改方向。
## 新开的船就在这个状态,所以第一桨只有是完整的一桨、而不是随手一拨,才能定方向。
const STROKE_MEMORY := 1.5

## The meter's right-hand end, and therefore the largest either knob can be set to.
## The deepest stroke in the take peaked at 327 deg/s, so this covers everything
## seen. The knobs are clamped to the meter on purpose: a value the player cannot
## see on the track is a value they cannot tell from a bug.
## 轨道的右端,因此也是两个旋钮能取到的上限。实录里最深的一次桨峰值 327 deg/s,所以这个
## 范围盖得住见到过的一切。旋钮故意按轨道来夹:玩家在图上看不见的值,和一个 bug 分不出来。
const SWEEP_METER_MAX := 340.0

const SWEEP_FINE_STEP := 1.0
const SWEEP_COARSE_STEP := 5.0

## A drag lands on the values the keys produce instead of beside them -- half a
## fine step, so every key value is reachable and the last digit is not noise.
## 拖动落在按键能走出的那些值上,而不是停在旁边 —— 半个细步:每个键值都够得着,最后一位
## 又不会乱跳。
const DRAG_SNAP := 0.5

## How long without a new sensor line before the oar counts as gone. Generous next
## to the board's 100 Hz (a line every 10 ms) and short enough that unplugging the
## board drops the boat back to WASD within one stroke.
## 多久没有新的传感器行就算桨掉了。相对板子的 100 Hz(每 10 毫秒一行)很宽裕,又短到拔掉
## 板子后一次桨之内就退回 WASD。
const STALE_S := 0.5

## Which way the lateral axis points when the oar is on the PORT (left) side. +1
## means the axis reads negative on the left. Set from the old board's lateral
## calibration, which was measured with the board mounted differently, so treat it
## as a first guess rather than a fact -- the readout prints the live lateral
## number and the L/R it implies, and the `\` key flips this on the spot. A boat
## that turns the wrong way while rowing is one keypress from right.
## 桨在左舷时横轴朝哪边。+1 表示这根轴在左侧读负数。取值来自旧板子的横向标定,而那块板子
## 的装法不一样,所以这是一个先验猜测、不是事实 —— 读数会把实时横轴值和它推出的 L/R 一起
## 打出来,`\` 键当场翻转。划着发现船往反方向偏,一个键就回来了。
const SIDE_SIGN := -1.0

## How far the lateral axis has to leave zero before it is read as a side. In g:
## the oar parked on one side reads about a full g of lateral, and level reads
## about zero.
## 横轴要偏离零多少才被读成一个舷侧。单位是 g:桨放在一侧时横向差不多是整整 1 g,放平则
## 差不多是 0。
const SIDE_HYSTERESIS := 0.20

const KNOB_NONE := 0
const KNOB_DEAD := 1
const KNOB_FULL := 2
const TUNED_FLASH := 0.7

## boat.gd's `max_thrust`, so the readout can say what a power of 0.62 is worth in
## the units the boat actually uses. Nothing in this file scales by it -- the boat
## applies it -- so it is a label, never a behaviour. `boat.gd` sets it on the
## controller it creates, so retuning `max_thrust` retunes the label with it.
## boat.gd 的 `max_thrust`,让读数能把「功率 0.62 值多少」换算成船真正用的单位。这个文件里
## 没有任何东西用它做缩放 —— 缩放是船在做的 —— 所以它只是个标签,不是行为。由 boat.gd 在
## 建控制器时写进来,于是调 `max_thrust` 时这个标签跟着变。
var max_thrust_report := 600.0

## Whether the top-right FORWARD SWEEP tuning panel is shown. Set from boat.gd's
## inspector export; F2 still toggles the whole overlay (panel + bottom readout).
## 是否显示右上角 FORWARD SWEEP 调参面板。由 boat.gd 的 Inspector 开关写入;
## F2 仍然控制整块叠加层(面板 + 左下读数)。
var show_panel := true:
	set(value):
		show_panel = value
		if _panel != null:
			_panel.visible = show_panel

# ------------------------------------------------------------------- State --
## Live knobs, in deg/s of sweep. Written only by `_tune_dead` / `_tune_full`.
## 实时旋钮,单位是扫速 deg/s。只有 `_tune_dead` / `_tune_full` 会写。
var sweep_deadband := SWEEP_DEADBAND_DEFAULT
var sweep_full := SWEEP_FULL_DEFAULT

## True while sensor lines are still arriving and carry a gyro. boat.gd reads this
## to choose between the oar and the WASD fallback.
## 传感器数据还在到达、并且带陀螺仪时为真。boat.gd 靠它在桨和 WASD 兜底之间选。
var sensor_ready := false

## `-gx` after the low-pass, in deg/s. Positive is an aft sweep, the power stroke.
## 低通之后的 `-gx`,单位 deg/s。正数是向后扫,也就是动力段。
var sweep := 0.0

## 0..1, straight out of the rule. The only thing thrust_local and yaw_torque read.
## 0..1,规则直接给出的结果。thrust_local 和 yaw_torque 只读这一个。
var forward_power := 0.0

## +1 with the oar on the port side, -1 on the starboard, 0 before it is known.
## Latched, not integrated -- see the latch in update().
## 桨在左舷是 +1,右舷是 -1,还没测出来是 0。是锁存的,不是积分出来的 —— 见 update()。
var side := 0.0

## Flips with the `\` key when the L/R on the readout is the wrong way round.
## 读数上的 L/R 反了时用 `\` 键翻它。
var side_sign := SIDE_SIGN

## Which half of the stroke is the drive: +1 the aft half, which sends the boat
## forward, -1 the bow half, which sends it backward. This is the latch the header
## describes. Written only by `_update_drive`, read by thrust_local and yaw_torque.
## It starts at +1 and a take is what moves it, so a boat with no oar and a boat that
## has only ever rowed forward behave exactly as this file did before the latch.
## 哪半圈是动力段:+1 是后半圈(送船向前),-1 是前半圈(送船向后)。就是文件头说的那个
## 锁存器。只有 `_update_drive` 会写,thrust_local 和 yaw_torque 读它。初值是 +1、要靠
## 实录来改,所以「没有桨的船」和「只向前划过的船」的行为和加锁存器之前完全一样。
var drive_sign := 1

## True while the last completed pair had the two channels disagree about which half
## was the drive -- the deeper half was not the heavier one. Shown on the readout: it
## is the one situation where the direction is riding on a single channel's word.
## 上一对完成的半圈里两个通道对「哪半是动力段」意见不一致时为真 —— 更深的那半圈不是更沉的
## 那个。显示在读数上:这是唯一一种「方向只靠一个通道的话撑着」的情况。
var disagree := false

## The section in progress: its direction, its running peak, and the running sum and
## count that make its mean |a|. Cleared by `_end_lobe`.
## 正在进行的那一段:方向、当前峰值,以及算平均 |a| 用的和与计数。由 `_end_lobe` 清掉。
var _lobe_sign := 0
var _lobe_peak := 0.0
var _lobe_a := 0.0
var _lobe_n := 0
## How long the sweep has been below LOBE_FLOOR, so a section can be closed.
## 扫速低于 LOBE_FLOOR 已经多久,用来判断一段是否该闭合。
var _lobe_gap := 0.0

## The last finished section: its peak, its mean |a| and its direction, plus the clock
## reading when it ended -- the three things "the section before it" means. Seeded at
## the bar a stale neighbour would set, so the first stroke of a session has to be a
## full stroke before it is allowed to name the direction.
## 上一段:峰值、平均 |a|、方向,以及它结束时的时钟 —— 这就是「前一段」的全部含义。初值
## 直接设成「前一段过期」时的门槛,于是一次划桨的第一桨必须是完整一桨才被允许定方向。
var _prev_peak := SWEEP_FULL_DEFAULT / DRIVE_RATIO
var _prev_a := 0.0
var _prev_sign := 0
var _last_lobe_ms := 0

## Whether the section in progress has already named the direction, and what the latch
## held before it did. A section may claim once, and the claim can be withdrawn if |a|
## disagrees by the time the section is complete.
## 正在进行的这一段是否已经定过方向,以及它定之前锁存器是什么。一段最多定一次,而且等这段
## 结束后如果 |a| 不同意,这次定下的还能撤回。
var _claimed := false
var _latch_before := 1

var _src: Node = null
var _f_gx := 0.0
## Freshness of the sensor link: the value of `good_lines` last frame, and the
## clock reading when it last changed. Deliberately NOT `seq`, which only wireless
## packets carry -- gating on that would leave a cabled oar permanently not ready,
## which is the mirror image of the bug this replaced.
## 传感器链路的鲜度:上一帧的 `good_lines`,以及它最后一次变化时的时钟。故意不用 `seq`,
## 那个只有无线包才有 —— 拿它当门会让插线的桨永远不就绪,正好是这个要替掉的 bug 的镜像。
var _last_lines := 0
var _last_beat_ms := -1

var _tuned := 0.0
var _tuned_knob := KNOB_NONE

var _overlay: CanvasLayer
var _overlay_visible := false
var _label: Label
var _panel: Panel
var _title: Label
var _status: Label
var _value_dead: Label
var _value_full: Label
var _cap_lo: Label
var _cap_hi: Label
var _live: Label
var _reset: Button
var _meter: Control
var _track: ColorRect
var _zone_dead: ColorRect
var _zone_ramp: ColorRect
var _zone_full: ColorRect
var _mark_dead: ColorRect
var _mark_full: ColorRect
var _needle: ColorRect
var _dragging := false
var _drag_knob := KNOB_NONE


func _ready() -> void:
	# Looked up by path rather than spelled as SensorInput, so a missing autoload
	# degrades gracefully instead of crashing.
	# 按路径取而不是直接写 SensorInput:autoload 不在时优雅降级,而不是崩掉。
	_src = get_node_or_null("/root/SensorInput")
	if _src == null:
		push_warning("[OarController] SensorInput autoload missing; keyboard only.")
	else:
		# Seeded here so the first frame does not mistake the link's existing count
		# for a line that just arrived. Only a CHANGE means data is flowing.
		# 在这里播下初值,免得第一帧把链路已有的计数当成刚到的数据。只有「变了」才说明数据在流。
		_last_lines = int(_src.good_lines)
	_build_overlay()
	# Draw once up front, so the panel shows the shipped pair for the frames before
	# the first update() rather than an empty box.
	# 先画一次,好让第一个 update() 之前那几帧显示的是出厂值,而不是一个空框。
	_refresh_overlay()
	if _overlay != null:
		_overlay.visible = _overlay_visible


## Live tuning, in game and at any moment: keys for a nudge with both hands on the oar
## handle, the panel for finding a value in the first place.
##
##   [  ]   the DEADBAND, one fine step (1 deg/s)    Shift + these = one coarse step (5)
##   ,  .   the FULL point, one fine step (1 deg/s)
##   0      both back to the shipped pair (40 / 150)
##   \      flip which side the lateral axis calls "L"
##   F2     show / hide the readout and the panel
##   drag the meter      grab the nearer notch; it follows the pointer
##
## Shift is a STEP SIZE rather than a second set of bindings: four keys to learn, not
## eight. The brackets and the comma pair also match on the key's POSITION, because
## character and position disagree on non-US layouts ("[" is AltGr+8 on several European
## ones, and Shift turns "," and "." into ";" and ":"). A tuning key that silently does
## nothing on the player's own keyboard is the worst outcome. `0`, `\` and F2 match on the
## character only, on purpose: Shift+0 is the physical "0" key on a US layout, so a
## position match would let it fire the reset.
##
## 游戏里随时可以调:两手都在桨把上时用按键挪一下,要找值的时候用面板。
##
##   [  ]   门槛,一个细步(1 deg/s)            Shift + 这两个 = 一个粗步(5)
##   ,  .   饱和点,一个细步(1 deg/s)
##   0      两个都放回出厂值(40 / 150)
##   \      翻转横轴的哪一边算「左」
##   F2     显示 / 隐藏读数与面板
##   拖轨道      抓更近的那个缺口,跟着指针走
##
## Shift 是「步长」而不是第二套按键:要记四个键,不是八个。括号对和逗号对额外按「位置」匹配
## 一次,因为非美式布局上字符和位置会分家(某些欧洲布局里「[」是 AltGr+8,Shift 还会把「,」
## 「.」变成「;」「:」)。调参键在玩家自己的键盘上默默失灵是最糟的结果。`0`、`\`、F2 故意只按
## 字符匹配:美式布局里 Shift+0 就是物理上的 "0" 键,位置匹配会让它触发重置。
func _input(event: InputEvent) -> void:
	# Cast to a typed local rather than reading `event` directly: the `is` test does not
	# narrow the parameter, so `event.keycode` would not be inferred.
	# 先转成带类型的局部变量再用:判断语句不会收窄参数类型,直接读 `event.keycode` 推不出类型。
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	var code := key.keycode
	if code == KEY_F1:
		if key.echo:
			return
		_overlay_visible = not _overlay_visible
		if _overlay != null:
			_overlay.visible = _overlay_visible
		return
	var echo := key.echo
	var step := SWEEP_COARSE_STEP if key.shift_pressed else SWEEP_FINE_STEP
	if key_is(key, code, KEY_BRACKETLEFT):
		_tune_dead(sweep_deadband - step, echo)
	elif key_is(key, code, KEY_BRACKETRIGHT):
		_tune_dead(sweep_deadband + step, echo)
	elif key_is(key, code, KEY_COMMA) or key_is(key, code, KEY_SEMICOLON):
		_tune_full(sweep_full - step, echo)
	elif key_is(key, code, KEY_PERIOD) or key_is(key, code, KEY_COLON):
		_tune_full(sweep_full + step, echo)
	elif key_is(key, code, KEY_BACKSLASH):
		side_sign = -side_sign
		if not echo:
			print("[OarController] side flip -> L is on the %s of the lateral axis"
					% ("-" if side_sign > 0.0 else "+"))
		_tuned = TUNED_FLASH
		_tuned_knob = KNOB_NONE
		_refresh_overlay()
	elif code == KEY_0:
		_reset_knobs(echo)


## True when the event is this key, read either as the character it produced or as
## the position it was pressed in.
## 判断这个事件是不是这个键:按它产生的字符读,或按它按下的位置读。
func key_is(key: InputEventKey, code: int, want: int) -> bool:
	return code == want or key.physical_keycode == want


## Set the deadband. The only writer it has, with `_tune_full` for the other knob;
## neither can touch the other's value. A held key or a drag passes quiet = true,
## because a line per repeat would bury the output.
## 设置门槛。它是这个值唯一的写入者,另一个旋钮归 `_tune_full`;两边都碰不到对方。按住键或
## 拖动时 quiet = true,否则每次重复一行会把输出埋掉。
func _tune_dead(v: float, quiet: bool) -> void:
	var was := sweep_deadband
	sweep_deadband = clampf(v, 0.0, SWEEP_METER_MAX)
	_tuned = TUNED_FLASH
	_tuned_knob = KNOB_DEAD
	if not quiet and not is_equal_approx(was, sweep_deadband):
		print("[OarController] deadband -> %.0f deg/s  (an aft sweep past it pays)"
				% sweep_deadband)
	_refresh_overlay()


## Set where the ramp saturates. Same contract and the same shape as _tune_dead.
## 设置饱和点。契约和形状都跟 _tune_dead 一样。
func _tune_full(v: float, quiet: bool) -> void:
	var was := sweep_full
	sweep_full = clampf(v, 0.0, SWEEP_METER_MAX)
	_tuned = TUNED_FLASH
	_tuned_knob = KNOB_FULL
	if not quiet and not is_equal_approx(was, sweep_full):
		print("[OarController] full sweep -> %.0f deg/s  (a stroke past it saturates)"
				% sweep_full)
	_refresh_overlay()


## Both knobs back to the shipped pair. Routed through the two setters rather than
## assigning the vars directly, so the flash and the console line happen once per
## knob that actually moved and there is no third copy of the clamp to keep in
## step.
## 两个旋钮都放回出厂值。走上面两个 setter,而不是直接给变量赋值 —— 这样闪烁和控制台输出
## 只在真正动过的那一个上各发生一次,也不会多出第三份 clamp 要对齐。
func _reset_knobs(quiet: bool) -> void:
	_tune_dead(SWEEP_DEADBAND_DEFAULT, quiet)
	_tune_full(SWEEP_FULL_DEFAULT, quiet)


# -------------------------------------------------------------- Main loop --
## Called once per physics frame. delta is the physics delta; it has nothing to do
## with the sensor's sample rate.
## 每个物理帧调用一次。delta 是物理帧长,和传感器的采样率没有关系。
func update(delta: float) -> void:
	# Run the tuning marker down before any of the early returns below: they all redraw
	# the overlay, so doing it here means the marker fades even with no oar attached.
	# 在下面那些提前返回之前先把调参标记推进:它们都会重画面板,放这里意味着没有桨时标记也会淡出。
	if _tuned > 0.0:
		_tuned = maxf(0.0, _tuned - delta)

	if _src == null or delta <= 0.0:
		_go_quiet()
		return

	# Readiness is "lines are still arriving", not "a port is open": the oar is
	# wireless now, and `port_open` is set by the serial path alone, so gating on it
	# left the boat on WASD forever with a sensor that was plainly working.
	# 就绪判定是「数据还在到达」,不是「串口开着」:桨现在是无线的,而 `port_open` 只有
	# 串口路径会置位 —— 拿它当门会让一条明明在工作着的传感器把船永远留在 WASD 上。
	var now := Time.get_ticks_msec()
	var lines := int(_src.good_lines)
	if lines != _last_lines:
		_last_lines = lines
		_last_beat_ms = now
	var fresh := _last_beat_ms >= 0 and now - _last_beat_ms < int(STALE_S * 1000.0)
	sensor_ready = fresh and bool(_src.has_gyro)
	if not sensor_ready:
		_go_quiet()
		return

	# The rule, and nothing else. gx is read straight off the latest sample: no
	# differentiation, no unit conversion, no attitude decomposition. The old code
	# did all three and got a signal that flipped sign inside one stroke; this one
	# is already the quantity the decision is about.
	# 规则本身,别无他物。gx 直接从最新样本上读:不差分、不换算单位、不做姿态分解。旧代码
	# 做了这三件事,拿到一个在一段桨里就会翻符号的量;而这个量本身就已经是决策的对象了。
	var a := 1.0 - exp(-delta / FILTER_TAU)
	_f_gx = lerpf(_f_gx, float(_src.gx), a)
	sweep = -_f_gx

	# Which half of the stroke is the drive. Runs before the throttle, because the
	# throttle is only allowed out on the half this names.
	# 哪半圈是动力段。放在油门之前,因为油门只在它认定的那半圈上放行。
	_update_drive(delta, now)

	# The throttle is the SIZE of the sweep, and it only reaches the boat while the
	# half sweeping is the half the latch calls the drive. Everything else -- the air
	# return, and the whole stroke when there is no drive to compare against -- is
	# zero by this one test.
	# 油门取扫速的大小,而且只有在「正在扫的那半圈就是锁存器认定的动力半圈」时才到得了船。
	# 其余情况 —— 空回,以及比不出动力段的整段桨 —— 都被这一个判断归零。
	if signf(sweep) != float(drive_sign):
		forward_power = 0.0
	else:
		var mag := absf(sweep)
		if mag <= sweep_deadband:
			forward_power = 0.0
		else:
			var span := sweep_full - sweep_deadband
			# A span of zero or less is reachable by dragging one notch past the other.
			# It is not an error to guard against, it is a rule the player just made:
			# anything past the deadband pays in full.
			# 把两个缺口拖成重叠或反序就会得到零或负的跨度。这不是要防的错误,而是玩家刚做出来的
			# 一条规则:过了门槛就全额给力。
			forward_power = 1.0 if span <= 0.0 else minf((mag - sweep_deadband) / span, 1.0)

	# Which side the oar is on is latched only while the oar is NOT driving. During a
	# stroke the lateral axis is carrying the blade's own swing, which crosses zero
	# on every stroke, so reading it then would flip the side mid-stroke and the yaw
	# with it. Parked, the oar lies out to one side and the axis reads a steady
	# fraction of a g -- that is the measurement worth keeping.
	# 桨在哪个舷只在「没在给力」的时候锁存。划起来的时候横轴上带的是桨叶自己的摆动,每次
	# 桨都会过零,那时候去读会让舷侧在半段桨里翻掉、偏转跟着翻。而桨放下时是横在一边的,
	# 那根轴读出的是一个稳定的零点几 g —— 那才是值得留下的测量。
	if forward_power <= 0.0:
		var lat := float(_src.x)
		if absf(lat) > SIDE_HYSTERESIS:
			side = signf(lat) * side_sign

	_refresh_overlay()


## Which half of the stroke is the drive, decided by comparing the section now in
## progress against the one before it: the deeper of the two is the drive, and its
## direction is the boat's direction. This runs every frame rather than at the end of
## a stroke so the latch can turn as soon as the evidence arrives -- a drive is deeper
## than the air return it follows within a few frames of starting, so a change of
## direction takes effect inside the first stroke of the new direction instead of one
## stroke later.
##
## The |a| channel is a veto, not a second vote. Mean |a| over a half-cycle is higher
## on the loaded half in every cycle measured, but it cannot decide anything live
## because it is only known once the half is over. So it is read the other way round:
## when the two channels disagree about a completed pair, the claim that pair made is
## withdrawn. Across the four takes that never once happened.
##
## 哪半圈是动力段,靠「进行中的这一段」和「前一段」比出来:深的那半圈是动力段,它的方向就是
## 船的方向。它每帧都跑,而不是只在桨结束时跑,所以证据一到锁存器就能翻 —— 动力段在开始后
## 几帧内就比它前面的空回深,于是换方向在换向后的第一桨之内就生效,而不是晚一桨。
##
## |a| 通道是否决权,不是第二张票。半圈的平均 |a| 在每一个实测周期里都是吃水那半圈更高,但
## 它要等半圈结束才知道,没法在线决定任何事。所以它是反着用的:一对半圈完成后如果两个通道
## 意见不一致,就把这一对做出的认领撤回来。四份实录里一次都没发生过。
func _update_drive(delta: float, now: int) -> void:
	var mag := absf(sweep)
	var s := 0
	if mag > LOBE_FLOOR:
		s = 1 if sweep > 0.0 else -1

	if s != 0:
		if s != _lobe_sign:
			_end_lobe(now)
			_lobe_sign = s
			_lobe_peak = 0.0
			_lobe_a = 0.0
			_lobe_n = 0
			_claimed = false
		_lobe_gap = 0.0
		_lobe_peak = maxf(_lobe_peak, mag)
		_lobe_a += _accel_mag()
		_lobe_n += 1
		# The bar this section has to clear before it may name the direction. A
		# neighbour that just ended is real evidence and sets the bar; one that went
		# quiet longer ago than STROKE_MEMORY is not evidence, and then only a stroke
		# at the full notch counts.
		# 这一段要越过多少才被允许定方向。刚结束的邻居是真实证据、由它来定门槛;安静超过
		# STROKE_MEMORY 的邻居不算证据,这时只有达到 full 缺口的一桨才算数。
		var bar := sweep_full
		if now - _last_lobe_ms <= int(STROKE_MEMORY * 1000.0):
			bar = _prev_peak * DRIVE_RATIO
		if not _claimed and _lobe_peak >= DRIVE_MIN and _lobe_peak >= bar:
			_latch_before = drive_sign
			drive_sign = _lobe_sign
			_claimed = true
	else:
		_lobe_gap += delta
		if _lobe_sign != 0 and _lobe_gap >= LOBE_GAP:
			_end_lobe(now)


## Close the section in progress: check it against the one before, withdraw the claim
## this section made if the two channels disagree, and shift it into the "previous"
## slot. Called when the sweep changes sign and when it has sat below the floor long
## enough, so a section is always closed before the next one starts.
## 把进行中的这一段闭合:和上一段比一比,两个通道不同意就撤回这一段做出的认领,然后把它挪进
## 「前一段」的位置。在扫速换向、以及低于地板够久时调用,所以下一段开始时上一段一定已经闭合。
func _end_lobe(now: int) -> void:
	if _lobe_sign == 0:
		return
	var mean_a := _lobe_a / float(maxi(_lobe_n, 1))
	if _prev_sign != 0 and _lobe_n > 0:
		# Deeper and heavier have to name the same half of this pair. When they do not,
		# the pair is not evidence: hold the direction it had before this section
		# claimed it, and say so on the readout.
		# 更深和更沉必须指向这一对的同一半圈。不一致时这一对不算证据:保持这一段认领之前的
		# 方向,并在读数上说明。
		var deeper := 1 if _lobe_peak >= _prev_peak else -1
		var heavier := 1 if mean_a >= _prev_a else -1
		disagree = deeper != heavier
		if disagree and _claimed:
			drive_sign = _latch_before
	_prev_peak = _lobe_peak
	_prev_a = mean_a
	_prev_sign = _lobe_sign
	_last_lobe_ms = now
	_lobe_sign = 0
	_claimed = false


## |a| straight off the sensor, in g, one sample per frame. This is the second channel
## of the drive decision and the only thing the accelerometer axes are still used for
## in this file. Averaged over a half-cycle rather than thresholded per sample: per
## sample the loaded and unloaded populations overlap completely, which is what killed
## the load gate, but their means over a half-cycle do not.
## 直接读传感器的 |a|,单位 g,每帧一个样本。这是动力段判定的第二个通道,也是加速度计三根轴
## 在这个文件里剩下的唯一用途。它按半圈取平均,而不是逐样本过门槛:逐样本时「吃水」和「空
## 载」两个总体完全重叠 —— 那正是载荷门槛死掉的原因 —— 但它们按半圈的平均不重叠。
func _accel_mag() -> float:
	if _src == null:
		return 0.0
	return sqrt(float(_src.x) * float(_src.x)
		+ float(_src.y) * float(_src.y)
		+ float(_src.z) * float(_src.z))


## Every output zero, for the frames where there is no usable oar: a missing
## autoload, a delta of zero, a board that stopped sending, or one that came back
## without a gyro. Kept in one place so no early return can leave a stale value
## behind and drive the boat with it.
## 没有可用的桨时(autoload 缺失、delta 为零、板子不再发数据、或者回来时没有陀螺仪)
## 把所有输出归零。集中在一处,免得哪个提前返回留下一个旧值,船还照着它开。
func _go_quiet() -> void:
	sensor_ready = false
	sweep = 0.0
	forward_power = 0.0
	# Drop the half-finished section and forget the pair it belonged to. A board that
	# goes away mid-stroke must not leave half a section behind for the next one to be
	# compared against, and with no neighbour the latch goes back to demanding a stroke
	# at the full notch before it will change direction. The direction itself is kept:
	# the boat remembers which way it was being rowed, which is the useful half of this
	# state to survive a dropout.
	# 丢掉半途的那一段,并忘掉它所属的那一对。板子在桨划到一半时掉线,不能留下半段让下一段
	# 拿它去比;而没有了邻居,锁存器就回到「要求一桨达到 full 缺口才肯改方向」。方向本身留着:
	# 船记得自己刚才是被往哪边划的,这是这份状态里值得扛过掉线的那一半。
	_lobe_sign = 0
	_lobe_peak = 0.0
	_lobe_a = 0.0
	_lobe_n = 0
	_claimed = false
	_prev_peak = sweep_full / DRIVE_RATIO
	_prev_a = 0.0
	_prev_sign = 0
	_last_lobe_ms = 0
	_refresh_overlay()


# ------------------------------------------------------------------ Output --
## The push the oar asks for, in the boat's local frame, as a unit vector times the
## throttle boat.gd scales. The oar pushes along its own axis: -Z while the drive is
## the aft half, +Z while it is the bow half, which is reverse. Forward is still -Z,
## so the other two components are exactly zero rather than small.
## 桨要求的推力,在船的局部坐标里,是一个方向乘上 boat.gd 缩放的油门。桨沿自己的轴推:动力
## 段是后半圈时是 -Z,是前半圈时是 +Z,也就是倒船。前方仍然是 -Z,所以另外两个分量是确切的
## 零,不是很小的数。
func thrust_local() -> Vector3:
	return Vector3(0.0, 0.0, -forward_power * float(drive_sign))


## The yaw a single oar makes: a power stroke on one side swings the bow away from
## that side. A port oar (side +1) drives the boat forward, and that push arrives at
## the oarlock, which sits OARLOCK_OFFSET to port of the centreline. Forward is -Z
## and the lever arm is -X, so the torque about +Y is NEGATIVE. boat.gd's convention
## is the opposite-facing one -- it documents `_yaw_rate` as "positive turns left"
## and turns the hull with rotate_y -- so a negative torque here is starboard, which
## is the way a left oar swings the bow. The sign was the other way round and turned
## the boat into its own oar.
## 单桨产生的偏转:在一侧给力,船头就被推离那一侧。左舷桨(side 为 +1)把船往前推,而这个
## 推力落在桨架上,桨架在中心线往左 OARLOCK_OFFSET 处。前方是 -Z、力臂是 -X,所以绕 +Y 的
## 力矩是负的。而 boat.gd 的约定正相反 —— 它写明 `_yaw_rate` 为「正值向左转」并用 rotate_y
## 转船体 —— 所以这里的负力矩就是右舷,也正是左舷桨该把船头带过去的方向。这个符号原来是反
## 的,船会朝着自己那根桨转。
##
## Row the same oar backward and the push reverses to +Z while the lever arm stays -X,
## so the torque about +Y flips to positive: a port oar rowed backward swings the bow
## to port. That is the `drive_sign` factor at the end, and it is the whole difference
## between the two directions -- the oar stays on the same side of the boat.
## 同一根桨反过来划,推力变成 +Z 而力臂仍然是 -X,于是绕 +Y 的力矩翻成正的:左舷桨倒着划,
## 船头往左偏。这就是末尾那个 `drive_sign` 因子,也是两个方向之间全部的差别 —— 桨一直在船的
## 同一侧。
##
## The size comes from the sweep rather than from `forward_power`, so it keeps growing
## where the throttle has already saturated: the deeper the stroke, the harder the bow
## comes round, and a stroke at the full notch turns exactly as much as it would have
## when the yaw was proportional to the clamped power.
## 大小取自扫速、而不是取自 `forward_power`,所以它在油门已经削平的地方继续增长:划得越深,
## 船头被带得越狠;而刚好到 full 缺口的一桨,转向和「用削平后的油门」时一模一样。
func yaw_torque() -> float:
	if forward_power <= 0.0:
		return 0.0
	var span := sweep_full - sweep_deadband
	var depth := 1.0 if span <= 0.0 else clampf((absf(sweep) - sweep_deadband) / span, 0.0, YAW_DEPTH_MAX)
	return -OARLOCK_OFFSET * side * depth * float(drive_sign)


# ---------------------------------------------------------------- Overlay --
## Panel geometry, in pixels. The base viewport is 1152 wide, so PANEL_W plus both
## margins has to stay inside that or the panel hangs off the screen. Written down
## once, because _build_panel and _layout_meter both need it and a disagreement
## between them would put the needle somewhere the drag does not expect.
## 面板尺寸(像素)。基础视口宽 1152,所以 PANEL_W 加两侧边距必须留在里面,否则面板会跑出
## 屏幕。只写这一处:_build_panel 和 _layout_meter 都要用,两者一旦对不上,指针就会出现在
## 拖动所预期之外的位置。
const PANEL_W := 560.0
const PANEL_H := 210.0
const PANEL_MARGIN := 16.0
const PANEL_PAD := 14.0
## The meter: where it sits in the panel, how wide, and the track's own height. The
## scale is fixed to SWEEP_METER_MAX rather than to the current knobs, so the
## notches and the needle move by the same rule and a notch always lands under the
## pointer that grabbed it.
## 轨道:在面板里的位置、宽度,以及底槽自己的高度。刻度固定按 SWEEP_METER_MAX,不跟着当前
## 旋钮走 —— 这样缺口和指针用同一套换算,抓哪个缺口就停在哪个位置。
const METER_Y := 56.0
const METER_W := PANEL_W - 2.0 * PANEL_PAD
const METER_H := 56.0
const TRACK_H := 22.0
const NOTCH_W := 4.0
const NOTCH_H := 34.0
const NEEDLE_W := 3.0
const NEEDLE_H := 52.0


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

	_build_label(root)
	_build_panel(root)


## The text readout, pinned to the bottom-left corner and hugging the bottom edge.
## The width stops short of the base viewport: the label is left-anchored and does
## not clip, so a line wider than the box would run off the right-hand edge.
## 文本读数,钉在左下角、紧贴下边缘。宽度止步于基础视口之前:标签是左对齐的而且不裁剪,
## 所以比框宽的一行会跑出右边缘。
func _build_label(root: Control) -> void:
	_label = Label.new()
	_label.anchor_left = 0.0
	_label.anchor_top = 1.0
	_label.anchor_right = 0.0
	_label.anchor_bottom = 1.0
	_label.offset_left = 16.0
	_label.offset_top = -150.0
	_label.offset_right = 1130.0
	_label.offset_bottom = -16.0
	_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color(0.08, 0.10, 0.12))
	_label.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_label.add_theme_constant_override("outline_size", 6)
	root.add_child(_label)


## The knob panel, pinned to the top-right corner -- the bottom-left one is already the
## readout's, and the two must not collide.
##
## It exists because a rule made of two numbers is not something a player can act on while
## rowing. The meter runs from a sweep of zero at the left edge to SWEEP_METER_MAX at the
## right: the dark stretch is the deadband and pays nothing, the lit ramp is where power
## climbs, the bright stretch past the full notch is saturated, and the white needle is the
## live sweep rate -- so "have I cleared it" is a glance, not a comparison. Both notches drag.
##
## Nothing here is a Container or a Slider: containers place their children a frame after
## being built, and a Slider needs a per-frame guard against the signal setting it emits.
##
## 旋钮面板,钉在右上角 —— 左下角已经是读数文本的位置,两者不能重叠。
##
## 它的理由:一条由两个数字组成的规则,玩家划起来没法照着操作。轨道从左端的扫速零到右端的
## SWEEP_METER_MAX:深色那段是门槛、一分不给,亮的斜升段是功率往上爬的地方,过了饱和缺口的
## 更亮段表示已经削平,白色指针是实时扫速 —— 所以「过了没有」是看一眼、不是做比较。两个缺口
## 都能拖。
##
## 这里没有用任何 Container 或 Slider:Container 要等一帧才摆好子节点,Slider 得每帧防一次
## 「设置它」本身发出的信号。
func _build_panel(root: Control) -> void:
	_panel = Panel.new()
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.05, 0.06, 0.08, 0.82)
	box.set_corner_radius_all(10)
	box.set_border_width_all(1)
	box.border_color = Color(1.0, 1.0, 1.0, 0.18)
	_panel.add_theme_stylebox_override("panel", box)
	# Both anchors on the right edge and both offsets negative, so the panel keeps
	# its size and stays in the corner whatever the window does.
	# 两个锚点都在右边、偏移都是负的,于是窗口怎么变,面板都保持大小、留在角落。
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left = -(PANEL_W + PANEL_MARGIN)
	_panel.offset_right = -PANEL_MARGIN
	_panel.offset_top = PANEL_MARGIN
	_panel.offset_bottom = PANEL_MARGIN + PANEL_H
	# The panel must not eat the mouse: everything in it except the meter is decoration,
	# and a click on it should reach the game. Setting a parent to IGNORE does not stop
	# its children being tested, which is why the meter can still be STOP inside it.
	# 面板不能吃掉鼠标:除了那根表条,里面全是装饰,点上去应该能穿透到游戏。把父节点设成
	# IGNORE 挡不住子节点被测试,所以表条仍然可以在它内部保持 STOP。
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_panel)
	_panel.visible = show_panel

	_title = _panel_label("FORWARD SWEEP   gyro gx", PANEL_PAD, 0.0, 300.0, 20.0, 12)
	_title.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
	_panel.add_child(_title)

	# The readiness line, in the panel rather than only in the readout, because
	# "the boat is not responding" and "the board is not sending" look identical
	# from the cockpit and this is the one place that tells them apart.
	# 就绪状态放在面板里而不只是读数里:在船上「船不理我」和「板子没在发」看起来一模一样,
	# 而这里是唯一能把两者分开的地方。
	_status = _panel_label("", PANEL_W - PANEL_PAD - 240.0, 0.0, 240.0, 20.0, 12)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_panel.add_child(_status)

	# One number per knob, each coloured like the notch it governs and placed over
	# that notch. Two labels rather than one "40 / 150" string on purpose: a single
	# string flashes as a whole, which would leave the player unable to tell which
	# of the four tuning keys actually did something -- the one failure this whole
	# readout exists to prevent.
	# 每个旋钮一个大号数值,颜色和它管的那个缺口一致,并且摆在那个缺口上方。故意用两个 Label
	# 而不是拼一个「40 / 150」:拼成一串的话闪烁是整串一起闪,玩家就看不出刚按的四个调参键
	# 里到底哪个起了作用 —— 而那是这整套读数存在的唯一理由。
	_value_dead = _panel_label("", PANEL_PAD, 22.0, 96.0, 30.0, 22)
	_value_dead.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_value_dead.add_theme_color_override("font_color", Color(0.35, 0.82, 1.0))
	_panel.add_child(_value_dead)
	_value_full = _panel_label("", PANEL_PAD, 22.0, 96.0, 30.0, 22)
	_value_full.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_value_full.add_theme_color_override("font_color", Color(1.0, 0.72, 0.30))
	_panel.add_child(_value_full)

	_build_meter()

	_cap_lo = _panel_label("PAYS NOTHING", PANEL_PAD, 116.0, 200.0, 22.0, 13)
	_cap_lo.add_theme_color_override("font_color", Color(0.55, 0.58, 0.64))
	_panel.add_child(_cap_lo)
	_cap_hi = _panel_label("SATURATED", PANEL_W - PANEL_PAD - 200.0, 116.0, 200.0,
			22.0, 13)
	_cap_hi.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_cap_hi.add_theme_color_override("font_color", Color(0.55, 0.58, 0.64))
	_panel.add_child(_cap_hi)

	_reset = Button.new()
	_reset.text = "Reset  (0)"
	_reset.focus_mode = Control.FOCUS_NONE
	_reset.mouse_filter = Control.MOUSE_FILTER_STOP
	_reset.anchor_right = 0.0
	_reset.anchor_bottom = 0.0
	_reset.offset_left = PANEL_PAD
	_reset.offset_top = PANEL_H - 44.0
	_reset.offset_right = PANEL_PAD + 130.0
	_reset.offset_bottom = PANEL_H - 12.0
	_reset.pressed.connect(_on_reset_pressed)
	_panel.add_child(_reset)

	_live = _panel_label("", PANEL_W - PANEL_PAD - 300.0, PANEL_H - 44.0, 300.0, 32.0,
			16)
	_live.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_live.add_theme_color_override("font_color", Color(0.86, 0.90, 0.95))
	_panel.add_child(_live)


## A Label placed by hand inside the panel: anchors all at the top-left and the
## rectangle given by offsets, so nothing waits on a parent's size being resolved.
## 手动摆进面板里的 Label:锚点全在左上、矩形由偏移给出,于是不用等父节点算出尺寸。
func _panel_label(text: String, x: float, y: float, w: float, h: float,
		size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.offset_left = x
	l.offset_top = y
	l.offset_right = x + w
	l.offset_bottom = y + h
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	l.add_theme_constant_override("outline_size", 3)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## The meter itself: the drag target, and the bands drawn inside it. Child order is
## the draw order, so the track goes on first, the bands over it, and the notches
## and the needle last.
## 轨道本身:拖动的落点,以及里面画的那些色带。子节点顺序就是绘制顺序,所以底槽先放、色带
## 盖在上面,缺口和指针最后。
func _build_meter() -> void:
	_meter = Control.new()
	_meter.anchor_right = 0.0
	_meter.anchor_bottom = 0.0
	_meter.offset_left = PANEL_PAD
	_meter.offset_top = METER_Y
	_meter.offset_right = PANEL_PAD + METER_W
	_meter.offset_bottom = METER_Y + METER_H
	_meter.mouse_filter = Control.MOUSE_FILTER_STOP
	_meter.gui_input.connect(_on_meter_input)
	_panel.add_child(_meter)

	_track = _meter_rect(Color(0.26, 0.29, 0.34))
	_zone_dead = _meter_rect(Color(0.14, 0.15, 0.18))
	_zone_ramp = _meter_rect(Color(0.20, 0.72, 0.92, 0.85))
	_zone_full = _meter_rect(Color(0.45, 0.95, 1.0, 0.95))
	_mark_dead = _meter_rect(Color(0.05, 0.06, 0.08))
	_mark_full = _meter_rect(Color(0.05, 0.06, 0.08))
	_needle = _meter_rect(Color(1, 1, 1))


## A bar inside the meter. Every one of them is transparent to the mouse, so the
## meter underneath is the single thing a click or a drag lands on.
## 表条里的一根条。所有条对鼠标都是透明的,于是无论点击还是拖动,落点都只有底下那根表条。
func _meter_rect(colour: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = colour
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_meter.add_child(r)
	return r


## Where a sweep rate sits on the meter, in meter-local pixels. The track starts at
## a sweep of zero, so unlike the old bipolar one there is no centre to measure
## from and the needle can never sit left of the origin.
## 一个扫速在轨道上的位置,单位是轨道内的像素。轨道从扫速零开始,所以跟旧的双极轨道不同,
## 这里没有中点可以量,指针也永远不会跑到原点左边。
func meter_x(v: float) -> float:
	return clampf(v, 0.0, SWEEP_METER_MAX) * (METER_W / SWEEP_METER_MAX)


## Lay the meter out for the two knobs and the live sweep. Called on every redraw;
## the values are all it needs, so it cannot go stale.
## 按两个旋钮和实时扫速摆放轨道里的东西。每次重绘都跑,需要的只有那几个值,所以不会走样。
func _layout_meter() -> void:
	if _meter == null:
		return
	var mid := (METER_H - TRACK_H) * 0.5
	var x_dead := meter_x(sweep_deadband)
	var x_full := meter_x(sweep_full)
	_place(_track, 0.0, mid, METER_W, TRACK_H)
	_place(_zone_dead, 0.0, mid, x_dead, TRACK_H)
	# The ramp is floored at zero width: dragging the full notch left of the
	# deadband is a rule the player is allowed to make, and a negative width is not
	# something a ColorRect will draw.
	# 斜升段的宽度下限取零:把饱和缺口拖到门槛左边是允许玩家做出来的一条规则,而负宽度不是
	# ColorRect 能画的东西。
	_place(_zone_ramp, x_dead, mid, x_full - x_dead, TRACK_H)
	_place(_zone_full, x_full, mid, METER_W - x_full, TRACK_H)
	_place(_mark_dead, x_dead - NOTCH_W * 0.5, (METER_H - NOTCH_H) * 0.5, NOTCH_W,
			NOTCH_H)
	_place(_mark_full, x_full - NOTCH_W * 0.5, (METER_H - NOTCH_H) * 0.5, NOTCH_W,
			NOTCH_H)
	_place(_needle, meter_x(sweep) - NEEDLE_W * 0.5, (METER_H - NEEDLE_H) * 0.5,
			NEEDLE_W, NEEDLE_H)
	# Each number sits just outside its own notch, the two growing apart, so they
	# cannot land on top of each other however close the knobs get. Clamped to the
	# panel, because a notch at either end would otherwise push its number off the
	# edge -- and with a clamped number it is still the notch that says where the
	# value is.
	# 两个数值各自摆在自己缺口的外侧、朝相反方向长,所以不管两个旋钮多近都不会叠在一起。
	# 夹在面板内:缺口顶到两端时数值会被推出边缘 —— 而夹住之后,指位置的就还是缺口本身。
	_place_label(_value_dead, x_dead - 8.0 - 96.0)
	_place_label(_value_full, x_full + 8.0)


## Put one of the knob numbers at a left edge, kept inside the panel.
## 把一个旋钮数值放到左边,并保证它在面板里面。
func _place_label(l: Label, x: float) -> void:
	var w := l.offset_right - l.offset_left
	var left := clampf(x, PANEL_PAD, PANEL_W - PANEL_PAD - w)
	l.offset_left = left
	l.offset_right = left + w


## Put one meter bar at a rectangle. Widths are floored at zero, so a rounding
## error can never ask a ColorRect for a negative width.
## 把一根表条放到给定矩形上。宽度下限取零,于是舍入误差永远不会让 ColorRect 拿到负宽度。
func _place(r: ColorRect, x: float, y: float, w: float, h: float) -> void:
	r.offset_left = x
	r.offset_top = y
	r.offset_right = x + maxf(0.0, w)
	r.offset_bottom = y + h


## Mouse on the meter. A press grabs whichever notch is nearer and the rest of the
## drag moves that one, so the pointer stays on the notch it picked up. Which knob
## a drag owns is decided once, at the press, and does not change while the pointer
## travels: a drag that reassigned itself mid-motion would hand one knob over and
## pick up the other the moment the pointer passed it, and the player would have no
## way to see why. The press also sets the value immediately, so a click on the
## meter jumps the grabbed notch to the pointer rather than waiting for a movement.
##
## The subclass members are reached through an explicit cast rather than by relying
## on the `is` test to narrow the type: button_index and position live on the
## subclasses, and a member lookup on the base InputEvent does not compile.
##
## 轨道上的鼠标。按下时抓更近的那个缺口,之后整段拖动都在动那一个,指针于是始终停在它抓起
## 来的那个缺口上。一次拖动归谁管只在按下那一刻决定,指针移动过程中不变:中途改主自己的拖动
## 会在指针越过另一个缺口的一瞬间把一个放下、把另一个拿起来,而玩家没有任何线索能看出这是
## 为什么。按下同时也立刻定值,所以在轨道上点一下,被抓的缺口就直接跳到指针处,不用等移动。
##
## 子类成员一律用显式转换去取,不指望 `is` 测试帮忙收窄类型:button_index 和 position 都在
## 子类上,在基类 InputEvent 上查成员是编译不过的。
func _on_meter_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			_dragging = true
			var x_dead := meter_x(sweep_deadband)
			var x_full := meter_x(sweep_full)
			_drag_knob = (
				KNOB_DEAD if absf(button.position.x - x_dead)
						<= absf(button.position.x - x_full)
				else KNOB_FULL)
			_set_from_meter_x(button.position.x)
		elif _dragging:
			# One line at the end of a drag rather than one per pixel, so there is a
			# record of where it landed without burying the output.
			# 一次拖动只在结束时打一行,而不是每个像素一行:留下落点记录,又不会把输出淹掉。
			_dragging = false
			_drag_knob = KNOB_NONE
			print("[OarController] deadband %.0f   full %.0f" % [
				sweep_deadband, sweep_full])
	elif event is InputEventMouseMotion and _dragging:
		_set_from_meter_x((event as InputEventMouseMotion).position.x)


## Turn a point on the meter into a value for the notch this drag owns, through the
## same scale meter_x uses in the other direction, and snapped so a drag can land
## on the values the keys produce instead of stopping beside them.
## 把一个轨道上的点换算成本次拖动所属那个旋钮的值,用的是 meter_x 的反函数,并且做了吸附,
## 让拖出来的值能落在按键走出的那些值上、而不是停在它们旁边。
func _set_from_meter_x(px: float) -> void:
	var v := roundf(clampf(px, 0.0, METER_W) / METER_W * SWEEP_METER_MAX
			/ DRAG_SNAP) * DRAG_SNAP
	if _drag_knob == KNOB_DEAD:
		_tune_dead(v, true)
	elif _drag_knob == KNOB_FULL:
		_tune_full(v, true)


func _on_reset_pressed() -> void:
	_reset_knobs(false)


## The readout. The live numbers are drawn whether or not there is a sensor,
## because this is the part the player tunes and it must not vanish exactly when
## they are setting up -- and the raw lateral value is in there so that a side
## reading backwards is something they can see and correct in one keypress rather
## than something they have to guess at.
## 读数。实时数字有没有传感器都照画,因为这是玩家要调的部分,它不该正好在设置的时候消失
## —— 而且里面带着原始横轴值,这样一个读反了的舷侧就是看得见、一个键能改的东西,而不是
## 只能靠猜。
func _refresh_overlay() -> void:
	if _label == null:
		return
	var knobs := (
		"dead %.0f%s      full %.0f%s\n" % [
			sweep_deadband, _knob_flash(KNOB_DEAD), sweep_full,
			_knob_flash(KNOB_FULL)]
		+ "[ ] dead   , . full   Shift coarse   \\ flip side   drag meter   0 reset")
	_refresh_panel()
	if not sensor_ready:
		_label.text = (
			"○  Oar: no sensor data (hold WASD to test)\n\n" + knobs)
		return
	var state := "RECOVER"
	if forward_power > 0.0:
		state = "DRIVE"
	_label.text = (
		"●  Oar  gx %s      sweep %s deg/s      side %s (x %s)\n" % [
			_f1(_gx_raw()), _f1(sweep), _side_text(side), _f2(_lat_raw())]
		+ "%s %s    power %.2f   yaw %s   (thrust %.0f of %.0f)\n" % [
			state, _dir_text(), forward_power, _f2(yaw_torque()),
			forward_power * max_thrust_report, max_thrust_report]
		+ "sec %s / prev %s    |a| %s / %s    %s\n" % [
			_f1(float(_lobe_sign) * _lobe_peak), _f1(float(_prev_sign) * _prev_peak),
			_f2(_lobe_mean_a()), _f2(_prev_a),
			"agree" if not disagree else "VETO"]
		+ knobs
	)


## gx and the lateral axis straight off the sensor, for the readout. Read here rather
## than stored, so the number on screen is the one the next frame will use, not a
## frame behind it.
## 直接从传感器读 gx 和左右轴,只给读数用。现读而不是存下来,所以屏上的数就是下一帧要用的数,
## 不会落后一帧。
func _gx_raw() -> float:
	return float(_src.gx) if _src != null else 0.0


func _lat_raw() -> float:
	return float(_src.x) if _src != null else 0.0


## FWD or REV for the readout: which way the latched drive is sending the boat. On
## screen because the latch is the one part of the rule the player cannot see in the
## raw numbers -- gx and |a| are shown, the conclusion drawn from them is not, and a
## wrong conclusion and a broken sensor would otherwise look the same.
## 读数用的 FWD / REV:锁存器认定的动力段把船送向哪边。放在屏幕上是因为锁存器是整条规则里
## 玩家从原始数字上看不出来的那一部分 —— gx 和 |a| 都打出来了,从它们推出的结论没有;否则
## 「推错了」和「传感器坏了」在屏幕上一模一样。
func _dir_text() -> String:
	return "FWD" if drive_sign > 0 else "REV"


## The section in progress's mean |a| so far, in g. Read by the readout only; the
## decision itself reads the mean once the section is closed, in `_end_lobe`.
## 进行中这一段到目前为止的平均 |a|,单位 g。只有读数用它;判定本身在 `_end_lobe` 里、
## 等这一段闭合后才取平均。
func _lobe_mean_a() -> float:
	return _lobe_a / float(maxi(_lobe_n, 1))


## The panel's numbers, readiness line, key numbers and bars, brought up to date
## with the two knobs and the live sweep. Rebuilt on every redraw rather than on
## the tuning events, so it is right the first time it is drawn and after a sensor
## comes and goes.
## 面板上的数值、就绪行、关键数字和色带,跟着两个旋钮与实时扫速更新。每次重绘都重建,而不是
## 只在调参事件上做 —— 这样它第一次画出来就是对的,传感器来去之后也是对的。
func _refresh_panel() -> void:
	if _panel == null:
		return
	_value_dead.text = "%.0f" % sweep_deadband
	_value_full.text = "%.0f" % sweep_full
	# Flash the number that moved, and only that one: a knob that gives no sign of
	# having moved is indistinguishable from a key that is dead. With two knobs
	# "something moved" is not enough, because the player's next question is always
	# which.
	# 只闪刚动过的那一个数值:一个动了却没有任何表示的旋钮,和一个坏掉的键分不出来。有两个
	# 旋钮时「有东西动了」还不够,因为玩家接下来永远要问是哪一个。
	_value_dead.modulate = (
		Color(1.0, 0.86, 0.32)
		if _tuned > 0.0 and _tuned_knob == KNOB_DEAD else Color(1, 1, 1))
	_value_full.modulate = (
		Color(1.0, 0.86, 0.32)
		if _tuned > 0.0 and _tuned_knob == KNOB_FULL else Color(1, 1, 1))
	if sensor_ready:
		_status.text = "● LIVE %s   side %s" % [_side_text(side), _f2(_lat_raw())]
		_status.add_theme_color_override("font_color", Color(0.45, 0.90, 0.55))
	else:
		_status.text = "○ no data"
		_status.add_theme_color_override("font_color", Color(1.0, 0.62, 0.45))
	_live.text = "gx %s   sweep %s   %s" % [_f1(_gx_raw()), _f1(sweep), _dir_text()]
	_layout_meter()


## A marker for the knob on the readout line, for a moment after it moves. A knob with
## no feedback is indistinguishable from a key that does nothing -- the one failure this
## whole readout exists to prevent.
## 旋钮动过之后,在读数行上留一小会儿标记。没有反馈的旋钮和一个坏掉的键分不出来,而这正是整套
## 读数要防的那一种故障。
func _knob_flash(knob: int) -> String:
	return " <<" if _tuned > 0.0 and _tuned_knob == knob else ""


## One or two decimals with an explicit sign. The "+" format flag is avoided: whether
## Godot's sprintf implements it is not something to bet the whole string on, since an
## unsupported flag blanks the entire result.
## 一到两位小数,并且显式带符号。不用 "+" 这个格式标志:Godot 的 sprintf 支不支持它,不值得拿
## 整个字符串去赌 —— 不支持的标志会把结果整条变空。
func _f1(v: float) -> String:
	return "%s%.1f" % ["+" if v >= 0.0 else "-", absf(v)]


func _f2(v: float) -> String:
	return "%s%.2f" % ["+" if v >= 0.0 else "-", absf(v)]
