extends Node
## Stroke recorder -- writes the raw sensor stream to a text file while the player
## rows, so a direction rule can be SCORED against real rowing instead of argued
## about.
##
## It reads the SensorInput autoload directly and knows nothing about the
## controller. That is the whole design: the rule is one line over the raw stream
## (`forward_power = clamp((-gx - DEAD) / (FULL - DEAD), 0, 1)`), so the raw stream
## IS the replay input and a recording can be scored against any future version of
## the rule without re-recording. The per-frame F line it used to write -- a copy
## of the controller's own inputs and outputs, for proving an offline replay of the
## OLD differentiated-accelerometer algorithm matched the GDScript frame for frame
## -- went away with that algorithm. There is now nothing to replay in lockstep.
##
## --- What goes in the file -------------------------------------------------
## Two line kinds, both timestamped on one clock (seconds since engine start,
## monotonic):
##
##   S <t> <x> <y> <z> <gx> <gy> <gz>   one per SENSOR sample, at the sensor's own
##                                     100 Hz; accel in g, gyro in deg/s
##   L <t> <label>                      the player changed what they are doing
##
## The S line is taken off the sensor's `sample` signal rather than by reading
## SensorInput once a frame, because the sensor sends at 100 Hz and the physics
## loop runs at 60 -- a per-frame reader never sees about a third of the stream.
## The signal carries only the three accelerometer axes, so the gyro columns are
## read off SensorInput inside the handler; that is safe because the signal is
## emitted after the latest-value fields are written, so a handler reading the
## fields sees the same sample the arguments came from.
##
## The columns are exactly the ones `tools/stroke_capture.py` writes, so
## `--read <file> --forward` scores a recording made in here as well as one made
## over the radio. That tool is the better instrument for a wireless oar (it also
## records the board's packet counters, which is how it can tell a damaged take
## from a slow one); this one is what works while playing in the editor, and it is
## the only one that can mark labels from inside the game.
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
## 划桨录制器 —— 玩家划船的时候把原始传感器流写进一个文本文件,这样「方向判得对不对」
## 就可以被打分,而不用靠嘴争。
##
## 它直接读 SensorInput 这个 autoload,完全不知道控制器的存在。这整个设计就在这一点上:
## 规则是一行作用在原始流上的式子(`forward_power = clamp((-gx - DEAD) / (FULL - DEAD),
## 0, 1)`),所以原始流**就是**回放的输入,一条录像可以拿未来任何一版规则去打分,不用重录。
## 它以前写的那个逐帧 F 行 —— 抄一份控制器自己的输入输出,用来证明旧那套「差分加速度计」
## 算法的离线回放和 GDScript 逐帧一致 —— 随那套算法一起消失了。现在没有任何东西需要
## 同步回放。
##
## --- 文件里有什么 ---------------------------------------------------------
## 两种行,共用同一个时钟(引擎启动至今的秒数,单调):
##
##   S <t> <x> <y> <z> <gx> <gy> <gz>   每个「传感器样本」一行,按传感器自己的 100 Hz;
##                                      加速度单位 g,陀螺仪单位 deg/s
##   L <t> <label>                      玩家切换了正在做的动作
##
## S 行走传感器的 `sample` 信号,而不是每帧读一次 SensorInput:传感器 100 Hz、物理循环 60 Hz,
## 每帧读一次的读者根本看不见大约三分之一的流。那个信号只带三个加速度轴,所以陀螺仪那三列是在
## 处理函数里从 SensorInput 上读的 —— 这是安全的,因为信号是在「最新值」字段写好之后才发的,
## 读字段的处理函数拿到的样本和参数里的是同一个。
##
## 这些列和 `tools/stroke_capture.py` 写的完全一样,所以 `--read <文件> --forward` 能给它录的
## 文件打分,也能给这里录的。无线桨用那个工具更合适(它还会记板子的包计数器,那是它分得出
## 「这条录像本身坏了」和「只是慢」的依据);而这个是在编辑器里玩着就能用的那一个,也是唯一能从
## 游戏内部打标签的那一个。
##
## --- 按键 -----------------------------------------------------------------
##   R          开始 / 结束录制(每次录制是一个新的带时间戳的文件)
##   T          为「下一次」录制选样本名,按 A -> B -> ... -> E 轮换
##   1 2 3      标记「从现在起在做的是什么」:
##                 1 = 前划        2 = 后划        3 = 其他
##              标签会一直保持到下次改变,所以通常的用法是:按 R、按 1、划十来桨前划、
##              按 2、划十来桨后划、再按 R 停。
##
## --- 文件写到哪 -----------------------------------------------------------
## res://recordings/。从编辑器跑的时候 res:// 就是真实项目目录,所以文件直接出现在项目
## 文件夹里,机器上任何东西都能读。导出后的包写不了那里;这是个开发用的仪器,那样就够。

# ------------------------------------------------------------- Config ------
# ------------------------------------------------------------- 配置 ------
## How many buffered lines to hold before touching the disk. Writing one line per
## sample would hitch the main thread at 100 lines a second, and a hitch perturbs
## exactly the frame timing this file exists to measure -- so the writes are
## batched and the file is also flushed on stop and on exit.
## 攒够多少行才落一次盘。一个样本写一次磁盘会在主线程上每秒卡 100 次,而卡顿扰乱的正是
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
# ------------------------------------------------------------------ 状态 --
## Deliberately untyped: SensorInput is an autoload whose script declares no
## class_name, so a typed reference makes the static analyser reject the member
## lookups.
## 故意不写类型:SensorInput 是个 autoload,它的脚本没有声明 class_name,写成有类型的
## 引用会让静态分析器拒绝那些成员查找。
var _src = null

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
## Samples recorded, so the console line on stop can say whether anything landed.
## 录了多少个样本,好让停止时的那行输出说明到底有没有录到东西。
var _samples := 0


func _ready() -> void:
	_src = get_node_or_null("/root/SensorInput")
	if _src == null:
		push_warning("[StrokeRecorder] SensorInput autoload missing; cannot record.")
		return
	_src.sample.connect(_on_sample)


func _exit_tree() -> void:
	# The player can quit mid-recording. Without this the last buffered lines --
	# up to FLUSH_LINES of them, which can be the end of a stroke -- are lost.
	# 玩家可能在录制中途退出。不处理的话缓冲区里最后那几十行就丢了,而那可能正是一桨的结尾。
	if _recording:
		_stop()


# ------------------------------------------------------------- Controls ----
# ------------------------------------------------------------- 按键 ----
## R starts and stops; 1/2/3 set the label. Nothing here collides with the
## controller's own keys ([ ] , . \ 0 and F2), the sensor readout's F1, or the
## boat's ESC.
## R 开始/停止;1/2/3 设标签。这些键和控制器自己的键([ ] , . \ 0 和 F2)、
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
# ------------------------------------------------------------ 录制 ----
func _start() -> void:
	if _src == null:
		print("[StrokeRecorder] no SensorInput; nothing to record")
		return
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
	_samples = 0
	_label = 0
	_recording = true
	_line("# oar recording -- BMI270 on the oar, straight off SensorInput")
	_line("# take %s, started %s" % [TAKE_NAMES[_take], _started_at])
	_line("# S <t> <x> <y> <z> <gx> <gy> <gz>  one per sensor sample (100 Hz), g / deg/s")
	_line("# L <t> <label>                 forward | backstroke | other")
	_line("# score with: tools/stroke_capture.py --read %s --forward" % _path)
	_line("# R stops. 1/2/3 set the label. T picks the next take name.")
	print("[StrokeRecorder] recording -> %s" % ProjectSettings.globalize_path(_path))


func _stop() -> void:
	_recording = false
	if _file == null:
		return
	_line("# stopped %s -- %d samples" % [_now_text(), _samples])
	_flush()
	# Closing is what guarantees the tail is on disk; FileAccess writes the
	# buffer out on close, but the explicit flush above means the count in the
	# console message is already true before it happens.
	# 关文件才是尾巴落盘的保证;close 会把缓冲写出去,但上面的显式 flush 意味着
	# 打印那行消息的时候行数已经是真的了。
	_file.close()
	_file = null
	var real := ProjectSettings.globalize_path(_path)
	print("[StrokeRecorder] stopped: %d samples -> %s" % [_samples, real])
	_path = ""


# --------------------------------------------------------------- Writing ---
# --------------------------------------------------------------- 写入 ---
## One line per sensor sample, off the sensor's own signal. The gyro columns are
## read from the autoload rather than from the arguments because the signal only
## carries the three accelerometer axes; the signal is emitted after those fields
## are written, so what is read here is this same sample and not the previous one.
##
## An accelerometer-only board writes zeros there, because its parser clears the
## gyro fields on every line -- which is visible in the file rather than being
## silently a stale number from some earlier board.
## 每个传感器样本一行,走传感器自己的信号。陀螺仪那几列是从 autoload 上读的,而不是从参数
## 里来的,因为那个信号只带三个加速度轴;信号是在那些字段写好之后才发的,所以这里读到的
## 是同一个样本,不是上一个。只有加速度计的板子在那些列上写零,因为它那套解析每行都会清掉
## 陀螺仪字段 —— 这会在文件里看得见,而不是悄悄留着一个更早那块板子的旧数字。
func _on_sample(x: float, y: float, z: float) -> void:
	if not _recording:
		return
	_samples += 1
	_line("S %.6f %.6f %.6f %.6f %.6f %.6f %.6f" % [
		_now(), x, y, z, _src.gx, _src.gy, _src.gz])


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
# ------------------------------------------------------------------- 时间 --
## Seconds since engine start, monotonic. Same clock for the S and L lines.
## 引擎启动至今的秒数,单调。S 行和 L 行共用这个时钟。
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
