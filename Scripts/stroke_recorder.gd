extends Node
## Stroke recorder -- writes the raw sensor stream and the controller's own
## per-frame decisions to one text file, so a direction rule can be SCORED
## against real rowing instead of argued about.
##
## Why this exists at all: oar_controller.gd decides forward vs astern entirely
## from the sign of the Z-axis sweep rate, and that statistic cannot tell a
## backstroke's return from a forward stroke's drive. Every attempt to patch it
## with a threshold has been tuned by hand, because the recordings that would
## settle the question were never kept. This writes the recording down.
##
## --- What goes in the file -------------------------------------------------
## Three line kinds, all timestamped on one clock (seconds since engine start,
## monotonic):
##
##   S <t> <x> <y> <z>     one per SENSOR sample, at the sensor's own 100 Hz
##   L <t> <label>         the player changed what they are doing
##   F <t> <d> <st> <sx> <sy> <sz> <sweep> <fwdbar> <backbar> <fwd> <back> <cool> <push> <verdict>
##                         one per PHYSICS frame -- its INPUTS and the
##                         controller's own OUTPUTS for that frame
##
## The F line is the point of the whole exercise. It lets the offline replay in
## tools/direction_lab.py prove it reproduces the shipped GDScript frame for
## frame before any new rule built on top of it is believed. Without that check
## a re-implementation that misreads one constant would reproduce its own
## mistake and score itself green.
##
## It carries the INPUT as well as the output (sx, sy, sz, delta, st) on purpose.
## The obvious alternative is to log only the outputs and have the replay work
## out which sample each frame consumed from the S-line timestamps -- but that
## inference is wrong by one sample whenever a sample lands in the gap between
## the controller reading the sensor and this file writing the line, and a
## one-sample error is exactly the size of the effect being measured. Logging
## the values the controller actually consumed removes the guess.
##
## st is which of update()'s three exits that frame took -- see the note at the
## write site.
##
## The S line is then free to be what it should be: the full stream, for testing
## designs that do not sample it the same way the controller does. It is taken
## off the sensor's `sample` signal rather than by reading SensorInput.x once a
## frame, because the sensor sends at 100 Hz and the physics loop runs at 60 --
## a per-frame reader never sees about a third of the stream.
##
## --- Controls --------------------------------------------------------------
##   R          start / stop recording (a new timestamped file per recording)
##   T          pick the take name for the NEXT recording, A -> B -> ... -> E.
##              It prefixes the filename, so the five takes of the protocol sort
##              together and are told apart afterwards without opening them.
##   1 2 3      mark what is happening from here on:
##                1 = rowing forward      2 = backstroking       3 = anything else
##              The label is carried forward until changed, so the usual pattern
##              is: press R, press 1, row a dozen forward strokes, press 2, row
##              a dozen back, press R again.
##
## --- Where the files land --------------------------------------------------
## res://recordings/. Running from the editor, res:// is the real project
## directory, so the files appear in the project folder and anything on the
## machine can read them. An exported build would not be able to write there;
## this is a development instrument and that is fine.
##
## 划桨录制器 —— 把原始传感器流和控制器自己的逐帧决策写进同一个文本文件,
## 这样「方向判得对不对」就可以被打分,而不用靠嘴争。
##
## 为什么要它:oar_controller.gd 完全靠 Z 轴扫速的符号决定前进还是后退,而这个统计量
## 分不开「后划的回程」和「前划的动力段」。之前每一次修补都是手工调门槛,因为能回答这个
## 问题的录像从来没被留下来。这个文件负责把录像留下来。
##
## --- 文件里有什么 ---------------------------------------------------------
## 三种行,共用同一个时钟(引擎启动至今的秒数,单调):
##
##   S <t> <x> <y> <z>     每个「传感器样本」一行,按传感器自己的 100 Hz
##   L <t> <label>         玩家切换了正在做的动作
##   F <t> <d> <st> <sx> <sy> <sz> <sweep> <fwdbar> <backbar> <fwd> <back> <cool> <push> <verdict>
##                         每个「物理帧」一行 —— 它的「输入」和控制器自己的「输出」
##
## F 行是整件事的目的:它让 tools/direction_lab.py 里的离线回放能逐帧证明自己复现了
## 出货版 GDScript,之后在它之上搭的任何新规则才值得相信。没有这道检查,一个读错了某个
## 常数的重写会连自己的错误一起复现,然后给自己打个满分。
##
## 它同时记「输入」(sx, sy, sz, delta, st)和输出,是刻意的。另一种显然的做法是只记输出,
## 让回放靠 S 行的时间戳去推每一帧当时吃的是哪个样本 —— 但只要有样本落在「控制器读传感器」
## 和「这里写这一行」之间,那个推断就会差一个样本,而一个样本正好就是我们在测的效应的
## 量级。把控制器真正吃到的值记下来,就不用猜了。
##
## st 记录这一帧走的是 update() 三个出口中的哪一个 —— 见写入处的说明。
##
## 于是 S 行就可以回归它该有的角色:完整的流,用来测试那些「不按控制器的方式采样」的设计。
## 它走传感器的 `sample` 信号,而不是每帧读一次 SensorInput.x:传感器 100 Hz、物理循环
## 60 Hz,每帧读一次的读者根本看不见大约三分之一的流。
##
## --- 按键 -----------------------------------------------------------------
##   R          开始 / 结束录制(每次录制是一个新的带时间戳的文件)
##   1 2 3      标记「从现在起在做的是什么」:
##                 1 = 前划        2 = 后划        3 = 其他
##              标签会一直保持到下次改变,所以通常的用法是:按 R、按 1、划十来桨前划、
##              按 2、划十来桨后划、再按 R 停。
##
## --- 文件写到哪 -----------------------------------------------------------
## res://recordings/。从编辑器跑的时候 res:// 就是真实项目目录,所以文件直接出现在项目
## 文件夹里,机器上任何东西都能读。导出后的包写不了那里;这是个开发用的仪器,那样就够。

# ------------------------------------------------------------- Config ------
## How many buffered lines to hold before touching the disk. Writing one line per
## sample would hitch the main thread at 160 lines a second, and a hitch perturbs
## exactly the frame timing this file exists to measure -- so the writes are
## batched and the file is also flushed on stop and on exit.
## 攒够多少行才落一次盘。一个样本写一次磁盘会在主线程上每秒卡 160 次,而卡顿扰乱的正是
## 这个文件要测的那套帧时序 —— 所以写入是批量的,另外在停止和退出时也会 flush。
const FLUSH_LINES := 64

## Where recordings go. See the note above on res://.
## 录制文件的位置。res:// 的说明见上面。
const REC_DIR := "res://recordings"

## What the three label keys mean, in the order they are written to the file.
## 三个标签键的含义,按写进文件的顺序排列。
const LABEL_NAMES := ["none", "forward", "backstroke", "other"]

## Take names, cycled with T before pressing R; the current one prefixes the
## filename. The timestamp alone says WHEN a recording happened but not WHICH
## line of the protocol it was, and it is the line that scoring compares -- a
## pile of timestamped files cannot be scored, because nothing in them says
## whether they are a forward baseline or the in-water-vs-air test that can
## falsify the whole hypothesis.
## 样本名,按 R 之前先用 T 轮换,当前值会作为文件名的前缀。光有时间戳只能说明
## 「什么时候录的」,说明不了「录的是协议里的哪一条」,而打分比对的正是那一条 ——
## 一堆只有时间戳的文件没法评分,因为里面没有任何东西说明它是前划基准,还是那条
## 能一票否决整个假设的「水中慢拖 vs 空中快挥」。
const TAKE_NAMES := ["A", "B", "C", "D", "E"]

# ------------------------------------------------------------------ State --
## Deliberately untyped, for the same reason oar_controller.gd leaves _src
## untyped: SensorInput is an autoload whose script declares no class_name, so a
## typed reference makes the static analyser reject the member lookups.
## 故意不写类型,原因和 oar_controller.gd 里 _src 一样:SensorInput 是个 autoload,
## 它的脚本没有声明 class_name,写成有类型的引用会让静态分析器拒绝那些成员查找。
var _src = null
## The OarController, handed over by boat.gd. Also untyped: it is reached through
## a preload constant there, not through a class_name the analyser can resolve.
## OarController,由 boat.gd 交过来。同样不写类型:那边是通过 preload 常量拿到的,
## 不是分析器能解析的 class_name。
var _oar = null

var _file: FileAccess = null
var _buf: PackedStringArray = PackedStringArray()
var _recording := false
## 0 none, 1 forward, 2 backstroke, 3 other. Written on every change, and the
## current value travels in the header so a file always says where it started.
## 0 无、1 前划、2 后划、3 其他。每次改变都写一行,当前值也写进文件头,
## 这样一个文件永远说得出它一开始是什么状态。
var _label := 0
## Index into TAKE_NAMES. Only settable while not recording, so the name in the
## filename always describes the whole file.
## TAKE_NAMES 的下标。只在没录制时可改,这样文件名里的那个名字描述的一定是整个文件。
var _take := 0
var _path := ""
var _started_at := ""
## Frames recorded, so the console line on stop can say whether anything landed.
## 录了多少帧,好让停止时的那行输出说明到底有没有录到东西。
var _frames := 0
var _samples := 0


func _ready() -> void:
	# Run after the boat's _physics_process, which is what calls
	# _oar.update(delta). Without this the F line would report the previous
	# frame's state -- off by one, which for this file is the same as wrong.
	# 排在船的 _physics_process 之后跑,因为调用 _oar.update(delta) 的正是它。
	# 不这样设,F 行报的会是上一帧的状态 —— 差一帧,对这个文件来说等于错。
	process_physics_priority = 1
	_src = get_node_or_null("/root/SensorInput")
	if _src == null:
		push_warning("[StrokeRecorder] SensorInput autoload missing; can only record frames.")
	else:
		_src.sample.connect(_on_sample)


## Handed the OarController by boat.gd, the same way TrailDots is handed the
## boat. Kept as a separate call rather than a _ready-time lookup so the
## dependency is visible at the one place that creates both.
## 由 boat.gd 把 OarController 交进来,和 TrailDots 拿到船的方式一样。做成单独一次调用
## 而不是在 _ready 里去找,是为了让这个依赖在「同时创建两者」的那一处看得见。
func setup(oar) -> void:
	_oar = oar


func _exit_tree() -> void:
	# The player can quit mid-recording. Without this the last buffered lines --
	# up to FLUSH_LINES of them, which can be the end of a stroke -- are lost.
	# 玩家可能在录制中途退出。不处理的话缓冲区里最后那几十行就丢了,而那可能正是一桨的结尾。
	if _recording:
		_stop()


# ------------------------------------------------------------- Controls ----
## R starts and stops; 1/2/3 set the label. Nothing here collides with the
## controller's own keys ([ ] , . - = 0 and F2), the sensor readout's F1, or the
## boat's ESC.
## R 开始/停止;1/2/3 设标签。这些键和控制器自己的键([ ] , . - = 0 和 F2)、
## 传感器读数的 F1、以及船的 ESC 都不冲突。
func _input(event: InputEvent) -> void:
	# Read through a typed local rather than off `event` directly: a property of
	# the base InputEvent is not something the analyser can infer a type from.
	# 通过有类型的局部变量去读,而不是直接读 `event`:基类 InputEvent 上的属性,
	# 静态分析器推断不出类型。
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_R:
			if _recording:
				_stop()
			else:
				_start()
		KEY_1:
			_set_label(1)
		KEY_2:
			_set_label(2)
		KEY_3:
			_set_label(3)
		KEY_T:
			_cycle_take()


func _set_label(n: int) -> void:
	if not _recording or n == _label:
		return
	_label = n
	_line("L %.6f %s" % [_now(), LABEL_NAMES[n]])
	print("[StrokeRecorder] label -> %s" % LABEL_NAMES[n])


## Picks the take name for the NEXT recording. Refused mid-recording rather than
## silently renaming, because the name goes in the filename before the first
## line is written and the file must not end up claiming to be a take it is not.
## 为「下一次」录制选样本名。录制中直接拒绝而不是偷偷改名,因为这个名字在写第一行之前
## 就已经进了文件名,文件不该最后自称是另一条样本。
func _cycle_take() -> void:
	if _recording:
		print("[StrokeRecorder] take is fixed for this recording: %s" % TAKE_NAMES[_take])
		return
	_take = (_take + 1) % TAKE_NAMES.size()
	print("[StrokeRecorder] next take -> %s" % TAKE_NAMES[_take])


# ------------------------------------------------------------ Recording ----
func _start() -> void:
	var dir := DirAccess.make_dir_recursive_absolute(REC_DIR)
	if dir != OK and dir != ERR_ALREADY_EXISTS:
		push_error("[StrokeRecorder] cannot create %s (error %d)" % [REC_DIR, dir])
		return

	# A timestamped name per recording, so starting a second take never
	# overwrites the first -- losing a take to a filename collision is the one
	# failure this instrument cannot afford.
	# 每次录制一个带时间戳的名字,所以录第二条不会覆盖第一条 —— 因为文件名撞车丢掉
	# 一条录像,是这个仪器最赔不起的一种失败。
	var d: Dictionary = Time.get_datetime_dict_from_system()
	_started_at = "%04d-%02d-%02d %02d:%02d:%02d" % [
		int(d["year"]), int(d["month"]), int(d["day"]),
		int(d["hour"]), int(d["minute"]), int(d["second"])]
	var stamp := _started_at.replace("-", "").replace(":", "").replace(" ", "-")
	# Take first, so the directory sorts by protocol line and the five takes of
	# one session sit together; the timestamp stays so a second pass reusing a
	# name cannot overwrite the first.
	# 样本名放前面,这样目录按协议顺序排、同一次会话的五条挨在一起;时间戳留着,
	# 所以第二轮复用同一个名字也覆盖不掉第一轮。
	_path = "%s/%s-%s.txt" % [REC_DIR, TAKE_NAMES[_take], stamp]

	_file = FileAccess.open(_path, FileAccess.WRITE)
	if _file == null:
		push_error("[StrokeRecorder] cannot write %s (error %d)" % [
			_path, FileAccess.get_open_error()])
		return

	_buf.clear()
	_frames = 0
	_samples = 0
	_label = 0
	_recording = true
	_line("# oar recording -- ADXL345 on the oar, watched by oar_controller.gd")
	_line("# take %s, started %s" % [TAKE_NAMES[_take], _started_at])
	_line("# S <t> <x> <y> <z>              one per sensor sample (100 Hz)")
	_line("# L <t> <label>                 forward | backstroke | other")
	_line("# F <t> <d> <st> <sx> <sy> <sz> <sweep> <fwdbar> <backbar> <fwd> <back> <cool> <push> <verdict>")
	_line("# R stops. 1/2/3 set the label. T picks the next take name.")
	print("[StrokeRecorder] recording -> %s" % ProjectSettings.globalize_path(_path))


func _stop() -> void:
	_recording = false
	if _file == null:
		return
	_line("# stopped %s -- %d samples, %d frames" % [_now_text(), _samples, _frames])
	_flush()
	# Closing is what guarantees the tail is on disk; FileAccess writes the
	# buffer out on close, but the explicit flush above means the line count in
	# the console message is already true before it happens.
	# 关文件才是尾巴落盘的保证;close 会把缓冲写出去,但上面的显式 flush 意味着
	# 打印那行消息的时候行数已经是真的了。
	_file.close()
	_file = null
	var real := ProjectSettings.globalize_path(_path)
	print("[StrokeRecorder] stopped: %d samples, %d frames -> %s" % [
		_samples, _frames, real])
	_path = ""


# --------------------------------------------------------------- Writing ---
func _on_sample(x: float, y: float, z: float) -> void:
	if not _recording:
		return
	_samples += 1
	_line("S %.6f %.6f %.6f %.6f" % [_now(), x, y, z])


func _physics_process(delta: float) -> void:
	if not _recording or _oar == null:
		return
	_frames += 1
	# The controller's own numbers, not a re-derivation of them. Everything the
	# replay needs to reproduce this line is either in it or is handed to it as an
	# input below -- including the two bars, which the player can move
	# mid-recording and which therefore cannot be assumed to be the shipped pair.
	#
	# The inputs are read here rather than reconstructed by the replay from the S
	# lines because the reconstruction is only right to within one sample, and one
	# sample is the size of the effect being measured. This still runs after
	# _oar.update(): _process does not run between two nodes' _physics_process in
	# the same step, so SensorInput cannot have moved underneath us.
	# 控制器自己的数,不是把它们再算一遍。回放要重现这一行所需要的一切,不是在这一行里,
	# 就是以输入的形式在下面交给它了 —— 包括两个门槛,玩家可以在录制过程中改它们,所以
	# 不能假定它们就是出厂值。
	#
	# 输入是这里读的,而不是让回放从 S 行反推,因为那个反推只准到一个样本以内,而一个样本
	# 正好就是我们在测的那个效应的量级。这一步仍然排在 _oar.update() 之后:同一个物理步里
	# _process 不会插在两个节点的 _physics_process 之间,所以 SensorInput 不可能被换掉。
	#
	# The INPUTS get nine decimals and the OUTPUTS get six, and the difference is
	# not cosmetic. The first thing the controller does with an input is
	# difference it: (fz - prev_z) / delta over a 16.7 ms frame, where the two
	# values are ~10 apart and their difference is ~0.04. Rounding the input to
	# six decimals costs 5e-7, which is 1e-5 of that difference -- so the rate,
	# and every filtered value built on it, comes back wrong in the fourth
	# decimal. That is larger than the tolerance the replay compares at, and it
	# would make the golden trace fail on a replay that is actually perfect.
	# 输入给九位小数、输出给六位,这个差别不是装饰。控制器拿到输入做的第一件事就是差分:
	# (fz - prev_z) / delta,一帧 16.7 ms,两个值相差约 10 而它们的差只有 0.04。
	# 输入舍到六位小数要付 5e-7,那是这个差的 1e-5 —— 于是速率、以及建立在它之上的每一个
	# 滤波值,都会在第四位小数上错掉。那已经超过了回放比对用的容差,会让一个其实完全正确
	# 的回放在 golden trace 上失败。
	var sx := 0.0
	var sy := 0.0
	var sz := 0.0
	var stage := 0
	if _src != null:
		sx = _src.x
		sy = _src.y
		sz = _src.z
		# Which of update()'s three exits this frame took. It matters even though
		# all three are "no thrust": the exits sit at different points, so they
		# leave the filter in different states, and the replay has to advance the
		# same state to stay in step with the frames that follow.
		#
		#   0  no port        update() returned before the filter ran at all
		#   1  |a| < 1 g      filter ran, but the differencing did not
		#   2  full run       everything ran
		#
		# Derived here rather than exported from the controller because the two
		# facts it needs -- port_open and sensor_ready -- are both public already.
		# 这一帧走的是 update() 三个出口中的哪一个。四个都是「没有推力」,但仍然要记:
		# 这三个出口的位置不同,留给滤波器的状态也就不同,回放必须推进同一份状态,
		# 才能跟后面的帧保持同步。
		#
		#   0  没有串口      update() 在滤波器跑之前就返回了
		#   1  |a| < 1 g     滤波器跑了,但差分没跑
		#   2  完整跑完      全跑了
		#
		# 在这里推导,而不是让控制器导出,因为它需要的两个事实(port_open 和
		# sensor_ready)本来就都是公开的。
		if not _src.port_open:
			stage = 0
		elif not _oar.sensor_ready:
			stage = 1
		else:
			stage = 2
	_line("F %.6f %.9f %d %.9f %.9f %.9f %.6f %.6f %.6f %.6f %.6f %.6f %.6f %s" % [
		_now(), delta, stage, sx, sy, sz,
		_oar.reverse_rate, _oar.sweep_need_aft, _oar.sweep_need_fwd,
		_oar.forward_power, _oar.reverse_power, _oar.stroke_cool,
		_oar.push_power, _oar._verdict_text(_oar.reverse_rate).strip_edges()])


func _line(s: String) -> void:
	if _file == null:
		return
	_buf.append(s)
	if _buf.size() >= FLUSH_LINES:
		_flush()


func _flush() -> void:
	if _file == null or _buf.is_empty():
		return
	_file.store_string("\n".join(_buf) + "\n")
	_buf.clear()


# ------------------------------------------------------------------- Time --
## Seconds since engine start, monotonic. Same clock for the S, L and F lines,
## which is what lets the replay work out which samples each physics frame had
## actually received.
## 引擎启动至今的秒数,单调。S、L、F 三种行共用这个时钟,回放才能算出每个物理帧当时
## 究竟已经收到了哪些样本。
func _now() -> float:
	return float(Time.get_ticks_usec()) / 1000000.0


## The same clock, but as text, for the human-readable header and footer lines
## where a wall-clock time is what the reader wants.
## 同一个时钟的文本形式,用在文件头和文件尾那两行给人看的注释里 —— 那里读者想看的是
## 真实时间。
func _now_text() -> String:
	var d: Dictionary = Time.get_datetime_dict_from_system()
	return "%04d-%02d-%02d %02d:%02d:%02d" % [
		int(d["year"]), int(d["month"]), int(d["day"]),
		int(d["hour"]), int(d["minute"]), int(d["second"])]
