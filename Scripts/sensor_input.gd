extends Node
## SensorInput -- an autoload singleton.
##
## Reads the sensor's lines over gdserial and exposes the latest reading to the
## rest of the game, while drawing a live numeric readout in the top-left corner
## so the data can be confirmed before touching boat.gd.
##
## Two sensors have been on the oar, and they do NOT speak the same protocol, so
## both are parsed and the readout says which one it is looking at:
##
##   ADXL345 (accelerometer only, m/s^2):
##       "<x>,<y>,<z>\n"
##   the newer board (accelerometer in g, plus a rate gyro in deg/s):
##       "Accel(g): <x>, <y>, <z> | Gyro(deg/s): <x>, <y>, <z>\n"
##
## The units differ between them and the numbers are NOT comparable: the newer
## board's accelerometer reads about 1.0 at rest and the older one about 9.8.
## Anything that reasons about the magnitude has to know which it has --
## `accel_in_g` is exposed for exactly that. See `tools/serial_probe.py` for the
## same view from a terminal.
##
## Usage:
##   from any script, read SensorInput.x / .y / .z / .gx / .gy / .gz /
##   .magnitude / .gyro_magnitude / .accel_in_g / .port_open
##   run the game and watch the numbers top-left; F1 toggles the readout.
##
## Note: the Arduino IDE's Serial Monitor must be closed, otherwise it holds
## the port and this cannot open it.
##
## There is also a wireless link now. The ESP32 on the oar brings up its own
## access point ("oar-sensor") and broadcasts the same lines over UDP, because
## there is no router out on the water. Join that network and this finds the
## radio on its own: no switch to flip, and nothing to change when the board is
## on a cable instead.
##
## Both links carry the same lines through the same parser. When both are live the
## wireless one wins -- a board plugged into a laptop AND on WiFi would otherwise
## deliver every sample twice and the readout would claim 200 Hz. Serial keeps
## working the whole time, so it stays there as the fallback.
##
## To watch the radio without this game, use tools/udp_probe.py -- which is how
## the link was measured before any of this was written.
##
## 现在还有一条无线链路:桨上的 ESP32 自己开热点("oar-sensor"),把同样的行用 UDP 广播出去,
## 因为水上没有路由器。Mac 连上那个网络,这边会自己找到它 —— 没有开关要拨,
## 插着线的时候也不用改任何东西。
##
## 两条链路走同一套解析。两个都活着时以无线为准:否则一块既插着笔记本、又开着无线的板子
## 会把每个样本送两遍,读数会显示 200 Hz。串口全程照常工作,所以它一直在那里兜底。
##
## 想不启动游戏就看这条无线链路,用 tools/udp_probe.py —— 在这份代码写出来之前,
## 链路就是靠它量的。
##
## 桨上先后装过两个传感器,它们**协议不同**,所以两个都解析,并且读数会说明当前看的是
## 哪一个:
##
##   ADXL345(只有加速度计,单位 m/s²):"<x>,<y>,<z>\n"
##   新的那块板子(加速度计单位 g,外加 deg/s 的陀螺仪):
##       "Accel(g): <x>, <y>, <z> | Gyro(deg/s): <x>, <y>, <z>\n"
##
## 两者单位不同、数值**不可直接比较**:新板子静止时加速度约 1.0,旧板子约 9.8。
## 任何要用到「模长」的逻辑都必须知道当前是哪个 —— 为此暴露了 `accel_in_g`。
## 想从终端看同样的东西,用 `tools/serial_probe.py`。

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
## How long to wait before trying to open the port again, after a failed open or
## after the port is lost, in seconds.
##
## The port is not held by permission, it is held by whoever opened it last:
## anything that opens it -- the Arduino IDE's Serial Monitor, a second copy of
## this game, one run of tools/serial_probe.py -- takes it away, and gdserial
## reports that as a disconnect. Without a retry, that single event kills the
## sensor for the rest of the session, and it looks exactly like dead hardware.
## Seen on 2026-09-25: readings for a moment when the game started, then nothing
## forever, and restarting the game did not help because something else held the
## port again at that instant. Retrying turns "permanently broken" into a
## two-second gap.
## 打开端口失败或端口丢失后,等多久再试一次,单位秒。
##
## 端口的归属不是靠权限,而是靠「谁最后打开它」:任何打开它的东西 ——
## Arduino IDE 的串口监视器、这个游戏的第二个实例、跑一次 tools/serial_probe.py ——
## 都会把它拿走,而 gdserial 把这个报告成掉线。没有重试的话,
## 仅仅这一个事件就会让传感器在整个会话里失效,而且看起来和硬件坏了完全一样。
## 2026-09-25 实际发生的就是这个:游戏刚启动时有一小段读数,之后永远没有,
## 而重启游戏也没用 —— 因为那一刻端口正好又被别的东西占着。
## 加上重试,就把「永久损坏」变成「两秒的空档」。
const RECONNECT_INTERVAL_SEC := 2.0
## If the port is open but not a single byte has arrived for this long, treat the
## sensor as lost anyway and reopen.
##
## `port_open` is NOT evidence that the sensor works, and this is the trap the
## 2026-09-26 bug lived in: the oar's firmware can stop producing samples while
## its serial port stays open and healthy, because every failing path in its loop
## is a silent `return`. From this side that is indistinguishable from "the boat
## is not moving" -- the port opens, no error is raised, and nothing ever
## arrives. So silence gets treated as a lost port and the port is reopened.
##
## What reopening does NOT do, measured on 2026-09-26: it does not reset the
## board. gdserial's open() leaves DTR and RTS alone, so the ESP32 does not
## reboot and a mute board stays mute -- verified by watching for the boot banner
## and the firmware's "# soft reset: chip back after N ms" across an open, a
## close and a reopen: neither appeared. Resetting needs the DTR/RTS toggle that
## tools/reset_capture.py and arduino-cli do, and there is no gdserial call for
## it. So this watchdog buys honest reporting and recovery from a genuinely lost
## port; it CANNOT revive a board that is still powered but has stopped talking,
## and it should not be read as if it can. That case is the firmware's job, and
## the firmware does now watch for it.
## port_open **不能**证明传感器是好的,2026-09-26 那个 bug 就住在这个陷阱里:
## 桨上的固件可以在串口完好、保持打开的情况下停止出样本,因为它循环里每条失败路径
## 都是静默 return。从这一侧看,这和「船没在动」完全无法区分 —— 端口开得成功、
## 没有任何错误抛出,然后永远等不到数据。所以「沉默」按「端口丢失」处理,重开端口。
##
## 但重开**不会**复位板子 —— 2026-09-26 实测:gdserial 的 open() 不动 DTR/RTS,
## ESP32 不会重启,哑掉的板子重开后还是哑的。判据是开一次、关一次、再开一次,
## 全程盯着启动横幅和固件那句 "# soft reset: chip back after N ms",两者都没出现。
## 想复位就得像 tools/reset_capture.py 和 arduino-cli 那样拉 DTR/RTS,而 gdserial 没有这个接口。
## 所以这个看门狗换来的是「诚实地报出问题」和「真丢了端口能捡回来」;
## 它**不能**救活一块还通着电、但不再说话的板子,也不该被当成能。那是固件的职责,而固件现在确实在看这件事。
const SILENCE_TIMEOUT_SEC := 3.0

# --------------------------------------------------------------- Wireless --
# --------------------------------------------------------------- 无线 --
## The ports the oar's ESP32 broadcasts on. Must match
## Arduino/esp32_bmi270/esp32_bmi270.ino's UDP_DATA_PORT and UDP_DIAG_PORT, and
## the network to join is that file's AP_SSID.
##
## Two ports, not one: the data port carries nothing but sample lines, so
## `bad_lines` keeps meaning "a line arrived malformed" and cannot be confused
## with the firmware having something to say. On the serial link both arrive on
## the same wire and that distinction is already lost; there is no reason to
## rebuild that fog on a link that does not have to have it.
## ESP32 广播用的两个口。必须和 Arduino/esp32_bmi270/esp32_bmi270.ino 的
## UDP_DATA_PORT / UDP_DIAG_PORT 一致,要连的网络是那个文件里的 AP_SSID。
##
## 用两个口而不是一个:数据口上只有样本行,于是 `bad_lines` 的含义就始终是「来了一行乱码」,
## 不会和「固件有话说」混在一起。串口上两者走同一根线,这个区分本来就没了;
## 没这个必要的新链路,不必再把那团雾重建一遍。
const UDP_DATA_PORT := 4210
const UDP_DIAG_PORT := 4211
## Whether to listen on them at all.
## 是否监听这两个口。
const UDP_ENABLED := true
## How long after the last wireless packet the radio still counts as the link
## carrying samples, and during which serial lines are therefore ignored.
##
## A full second, not a frame: WiFi drops packets, and the whole point of
## preferring the radio is defeated if a single lost packet hands the stream back
## to a cable that is also delivering it -- the two would then interleave and the
## sample rate would be wrong in a way that changes from second to second.
## 最后一次收到无线包之后,还认为无线是「正在送样本的那条链路」、因而忽略串口行的时间。
##
## 整整一秒而不是一帧:WiFi 会丢包,如果丢一个包就把流交还给同样在送这份数据的串口,
## 两者就会交错,采样率会在一种每秒都在变的方式下变错 —— 那样「优先无线」这件事本身就白做了。
const WIFI_PREFERRED_SEC := 1.0
## Where the board sits on its own network. An ESP32 SoftAP is always the gateway
## of 192.168.4.0/24, so this is a fixed address rather than something discovered.
## 板子在它自己网段上的地址。ESP32 的 SoftAP 永远是 192.168.4.0/24 的网关,
## 所以这是个固定地址,不是要发现的东西。
const OAR_ADDRESS := "192.168.4.1"
## How often to tell the board where we are.
##
## Not a one-shot, because the board keeps the address in RAM: a board restart
## forgets it, and this side can come back on a different lease after rejoining.
## Repeating it costs one small packet a second and removes every state that could
## get out of step -- there is no handshake here to desynchronise.
## 多久告诉板子一次我们在哪。
##
## 不是只发一次,因为板子把这个地址存在内存里:它重启就忘了,而这一侧重新入网后
## 可能换一个租约。反复发只花每秒一个小包,却把「可能失步」的状态整个消掉 ——
## 这里本来就没有握手可以失步。
const HELLO_INTERVAL_SEC := 1.0

# ----------------------------------------------------------------- Signals --
# ----------------------------------------------------------------- 信号 --
## Emitted once per successfully parsed sample, at the SENSOR's own rate, not at
## the physics rate. Anything that needs every sample rather than the latest one
## -- the stroke recorder, a replay log -- must connect to this.
##
## Reading x/y/z once per frame silently drops samples, and which samples get
## dropped depends on which side is faster. The old ADXL345 sent at 100 Hz while
## the physics loop runs at 60, so about a third of the stream reached no
## per-frame reader at all; the newer board sends at about 5 Hz, so a per-frame
## reader instead sees the same reading two or three frames running -- and, more
## importantly, has no way to tell a repeated sample from a genuinely unchanged
## one. A recorder needs the arrivals, so it takes them from here.
## 每成功解析一个样本就发一次,按「传感器自己」的速率,不跟物理帧走。
## 需要「每一个样本」而不是「最新值」的东西(录制器、回放日志)必须接这个信号。
##
## 每帧读一次 x/y/z 会悄悄丢样本,而丢哪些取决于哪边更快。旧 ADXL345 是 100 Hz,
## 物理循环 60 Hz,于是大约三分之一的样本根本到不了「每帧读一次」的读者手里;
## 新板子约 5 Hz,每帧读一次的读者反而会连续两三帧看到同一个读数 —— 更要紧的是,
## 它没有办法区分「重复的样本」和「真的没变」。录制器要的是「到达」,所以从这里拿。
##
## Carries the accelerometer only. The gyro is exposed on the fields (gx/gy/gz)
## instead, and a handler that wants it reads the fields: this signal is emitted
## after they are written, so the fields hold this same sample and the extra
## arguments would be a second copy of them. Widening the signal would break every
## listener in the project to carry numbers they can already reach.
## 只带加速度计。陀螺仪走字段(gx/gy/gz),想要它的处理函数直接读字段:这个信号是在那些
## 字段写好之后才发的,所以字段里就是同一个样本,再多传几个参数只是它们的第二份拷贝。
## 加宽这个信号会让工程里每一个监听者都要改,只为拿到它们本来就够得着的数字。
signal sample(x: float, y: float, z: float)


# ------------------------------------------------------------------- State --
# ------------------------------------------------------------------- 状态 --
var x: float = 0.0
var y: float = 0.0
var z: float = 0.0
## Gyro rates in deg/s. Left at zero by a sensor that has no gyro, so pair any
## use of them with `has_gyro` rather than with "are they nonzero" -- a board
## that IS reporting will also read exactly zero while it sits still.
## 陀螺仪角速度(deg/s)。没有陀螺仪的传感器会把它们留在 0,所以判断「有没有」要用
## `has_gyro`,不要用「是不是非零」—— 有陀螺仪的板子在静止时读出来也正好是 0。
var gx: float = 0.0
var gy: float = 0.0
var gz: float = 0.0
## Resultant length, sqrt(x*x + y*y + z*z). About 1.0 on the newer board and
## about 9.8 on the ADXL345, which is why `accel_in_g` exists.
## 合矢量长度。新板子约 1.0,ADXL345 约 9.8 —— 这正是需要 `accel_in_g` 的原因。
var magnitude: float = 0.0
## Resultant gyro rate, sqrt(gx*gx + gy*gy + gz*gz), in deg/s.
## 陀螺仪合角速度(deg/s)。
var gyro_magnitude: float = 0.0
## True once a line in the newer board's format has been parsed, i.e. the
## accelerometer is reporting g and the gyro fields are live. Set by the parser
## rather than by a setting, so it follows the hardware instead of a config that
## can drift out of step with whatever is actually plugged in.
## 一旦解析到新板子格式的行就为 true,也就是「加速度计单位是 g、陀螺仪字段有效」。
## 由解析器置位而不是靠配置项,这样它跟着实际插着的硬件走,不会和现实脱节。
var has_gyro: bool = false
## True when `magnitude` is in g rather than m/s^2.
## `magnitude` 的单位是 g 而不是 m/s² 时为 true。
var accel_in_g: bool = false
## Whether the serial port is currently open.
## 串口当前是否打开。
var port_open: bool = false
## The last complete raw line, for troubleshooting.
## 最后一条完整的原始行,供排查用。
var last_line: String = ""
## Lines parsed successfully / lines that failed to parse.
## 解析成功的行数 / 解析失败的行数。
var good_lines: int = 0
var bad_lines: int = 0
## Measured lines per second, to verify the sample rate (target 100).
## 实测每秒行数,用来核对采样率(目标 100)。
var hz: float = 0.0

## Samples the radio dropped, counted from the board's own packet counter. This
## is the one failure a wireless link has that a cable does not, and it is
## invisible without the counter: a dropping radio and a slowing sensor both just
## read as a lower Hz. Shown in the readout for exactly that reason.
## 射频丢掉的样本数,来自板子自己的包序号。这是无线链路独有、而线缆不会有的失效,
## 没有那个序号就看不见它:丢包的射频和变慢的传感器,读出来都只是「Hz 低了一点」。
## 读数里显示它,正是因为这个。
var wifi_lost: int = 0
## Wireless packets per second, over the same one-second window as `hz`.
## 每秒无线包数,和 `hz` 用同一个一秒窗口。
var wifi_pps: float = 0.0
## The firmware's own last "# ..." line, or "" if it has never sent one.
##
## On a wireless oar there is no serial console to glance at, and the firmware's
## diagnostics are the only account of a stall -- the host can see silence but
## cannot see why. So they are surfaced here rather than merely discarded.
## 固件最后一条 "#" 行,没发过则为 ""。
##
## 无线的桨上没有串口可以瞄一眼,而固件的诊断是「卡住」唯一的说法 ——
## 主机只看得见沉默,看不见原因。所以它们显示在这里,而不是丢掉。
var last_diag: String = ""
## The board's packet counter read off the last wireless line, or -1 if none.
## Part of the parsed sample rather than transport bookkeeping because the parser
## is where the numbers are already pulled apart.
## 最后一条无线行里板子的包序号,没收到过则为 -1。
## 它算解析出来的字段、而不是传输层记账,因为拆数字这件事本来就是解析器在做。
var seq: int = -1

## Untyped on purpose: if Windows Smart App Control blocks gdserial.dll the
## GdSerialManager class never registers, and a typed reference would stop this
## autoload (and the whole project) from loading. UDP still works without it.

var _manager = null
var _port: String = ""
var _overlay: CanvasLayer
var _label: Label
var _overlay_visible := false
var _status: String = "starting…"
var _hz_accum: float = 0.0
var _hz_mark: int = 0
## Time.get_ticks_msec() value before which the port must NOT be reopened, so the
## retry is a slow poll rather than an attempt every frame.
## Time.get_ticks_msec() 的时间戳;在此之前不要重新打开端口,让重试是慢轮询而不是每帧一试。
var _next_open_msec: int = 0
## Whether an open failure has already been reported. The troubleshooting list is
## worth printing once; printing it every two seconds forever is not.
## 是否已经报过一次打开失败。排查清单值得打一遍,每两秒永远重复不值得。
var _open_failure_reported := false
## Time.get_ticks_msec() of the last line that arrived, for the silence watchdog.
## Time.get_ticks_msec() 的时间戳,记录最后一行到达的时刻,供沉默看门狗使用。
var _last_data_msec: int = 0
var _udp: PacketPeerUDP
var _udp_diag: PacketPeerUDP
## Time.get_ticks_msec() of the last wireless packet, for `is_wireless()`.
## Time.get_ticks_msec() 的时间戳,记录最后一个无线包到达的时刻,供 `is_wireless()` 判断。
var _last_wifi_msec: int = 0
var _wifi_packets: int = 0
var _wifi_packets_mark: int = 0
## The packet counter as of the last wireless line, for spotting gaps. Kept apart
## from the public `seq` so that "what the board sent" and "what we have counted
## so far" cannot be confused for each other.
## 上一条无线行里的包序号,用来发现空洞。和公开的 `seq` 分开保存,
## 这样「板子发了什么」和「我们数到哪了」不会被当成同一件事。
var _wifi_seq_last: int = -1
## Time.get_ticks_msec() of the last hello packet sent to the board.
## Time.get_ticks_msec() 的时间戳,记录最后一次发给板子的 hello 包。
var _hello_msec: int = 0


# -------------------------------------------------------------- Lifecycle --
# -------------------------------------------------------------- 生命周期 --
func _ready() -> void:
	if ClassDB.class_exists("GdSerialManager"):
		_manager = ClassDB.instantiate("GdSerialManager")
		_manager.data_received.connect(_on_data)
		_manager.port_disconnected.connect(_on_disconnected)
	else:
		_status = "serial DLL blocked/missing (UDP only)"
		push_warning("[SensorInput] GdSerialManager is unavailable -- gdserial.dll failed to load (often Windows Smart App Control). USB serial is off; wireless UDP still works if you join the oar AP.")
	_open_udp()
	_build_overlay()
	if _manager != null:
		_open_port()


func _exit_tree() -> void:
	if _manager != null and _port != "":
		_manager.close(_port)


func _process(delta: float) -> void:
	# Before the serial work, so that a frame in which both links delivered
	# something resolves in the radio's favour -- which is the order the rest of
	# this file assumes.
	# 放在串口那摊事之前,这样一个「两条链路都送到东西」的帧会按无线的说法结算 ——
	# 这正是文件其余部分所假定的顺序。
	_poll_udp()

	if _manager != null:
		# poll_events must be called every frame or the signals never fire.
		# 必须每帧调用,否则信号永远不触发。
		_manager.poll_events()
		# Deliberately NOT asking is_open() here. gdserial documents that method
		# as actively testing the connection, and this runs at 60 Hz -- 60 test
		# operations a second against a port that is already being read. The
		# port_disconnected signal reports the same fact when it actually
		# happens, and it is the thing that should drive a reconnect.
		# 这里**故意不**调 is_open():gdserial 的文档说这个方法会主动测试连接,
		# 而这里是 60 Hz —— 在一个已经在被读的端口上每秒做 60 次测试操作。
		# 真掉线时 port_disconnected 信号会报告同一件事,而重连应当由它来驱动。
		if not port_open:
			if Time.get_ticks_msec() >= _next_open_msec:
				_open_port()
		elif Time.get_ticks_msec() - _last_data_msec > int(SILENCE_TIMEOUT_SEC * 1000.0):
			_lose_port("no data for %d s -- reopening" % int(SILENCE_TIMEOUT_SEC), true)
	_update_hz(delta)
	_refresh_overlay()


## Counts the lines actually received once per second, to check whether the
## sample rate really is hitting 100.
## 每秒统计一次实际收到的行数,用来核对采样率是否真的达到 100。
func _update_hz(delta: float) -> void:
	_hz_accum += delta
	if _hz_accum >= 1.0:
		hz = float(good_lines - _hz_mark) / _hz_accum
		_hz_mark = good_lines
		# Counted on packets rather than on lines, because the two differ in the
		# one case worth being able to see: a packet that arrived carrying a line
		# this parser refused. `hz` and `wifi_pps` coming apart is that case.
		# 按包数而不是行数,因为两者只在一种值得看见的情况下不同:来的包里那行解析器不收。
		# `hz` 和 `wifi_pps` 拉开差距,就是这种情况。
		wifi_pps = float(_wifi_packets - _wifi_packets_mark) / _hz_accum
		_wifi_packets_mark = _wifi_packets
		_hz_accum = 0.0


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == TOGGLE_KEY:
		_overlay_visible = not _overlay_visible
		if _overlay != null:
			_overlay.visible = _overlay_visible


# ----------------------------------------------------------- Wireless link --
# ----------------------------------------------------------- 无线链路 --
## Whether the radio, rather than the cable, is the link carrying samples right
## now. Public because it decides which stream the readout is describing, and
## because anything recording samples should record which link they came off.
## 现在在送样本的是无线还是串口。公开,是因为它决定了读数在描述哪一条流,
## 也因为任何录制样本的东西都该记下它们是从哪条链路来的。
func is_wireless() -> bool:
	return _last_wifi_msec > 0 \
		and Time.get_ticks_msec() - _last_wifi_msec < int(WIFI_PREFERRED_SEC * 1000.0)


## Binds the two sockets the oar broadcasts to.
##
## Failure here is reported and never fatal. The serial link is untouched by it,
## and a wireless oar on a power bank is precisely the case where there is no
## serial port to fall back to -- so refusing to run would turn "no wireless" into
## "no sensor", which is not a trade worth making.
## 绑定板子广播用的两个口。
##
## 这里失败只报告、不致命。串口链路完全不受影响,而无线的桨(充电宝供电)恰恰是
## 没有串口可以退的那种情况 —— 所以「跑不起来」会把「没有无线」变成「没有传感器」,
## 这不是一笔值得做的交换。
func _open_udp() -> void:
	if not UDP_ENABLED:
		return

	_udp = PacketPeerUDP.new()
	_udp.set_broadcast_enabled(true)
	var err := _udp.bind(UDP_DATA_PORT)
	if err != OK:
		_udp = null
		push_warning("[SensorInput] Could not listen on udp/%d (error %d). Another copy of the game, or tools/udp_probe.py, has almost certainly already bound it -- the port goes to whoever bound it last, so nothing arrives and no error is raised there either. Wireless off; the serial link is unaffected." % [UDP_DATA_PORT, err])
	else:
		print("[SensorInput] Listening for the oar's wireless stream on udp/%d (data) and udp/%d (diagnostics)." % [UDP_DATA_PORT, UDP_DIAG_PORT])

	_udp_diag = PacketPeerUDP.new()
	_udp_diag.set_broadcast_enabled(true)
	if _udp_diag.bind(UDP_DIAG_PORT) != OK:
		# Losing only this one costs the firmware's account of itself and nothing
		# else, so it is a quieter failure than the one above.
		# 只丢这一个,代价是固件对自己处境的说明,没有别的,所以比上面那个安静些。
		_udp_diag = null
		push_warning("[SensorInput] Could not listen on udp/%d for the firmware's diagnostics; samples are unaffected." % UDP_DIAG_PORT)


## Tells the board where we are, so that it can send to us alone.
##
## The packet carries nothing but the fact that it arrived: the address the board
## needs is the one it reads out of the IP header, so there is no message format
## here and nothing to parse on the other end. Until it hears this the board
## broadcasts, which works but measures badly -- 6.9% of samples lost on
## 2026-09-28, arriving in clumps, because 802.11 does not ACK or retransmit
## broadcast and the access point defers it to a DTIM beacon.
## 告诉板子我们在哪,好让它只发给我们。
##
## 这个包除了「它到了」不带任何内容:板子要的地址是它从 IP 头里读出来的,
## 所以这里没有消息格式,另一端也没有要解析的东西。在听到它之前板子走广播,
## 广播能用但实测很差 —— 2026-09-28 丢了 6.9% 的样本、而且是成串到达的,
## 因为 802.11 不对广播做 ACK 和重传,而且 AP 会把它推迟到 DTIM beacon。
func _send_hello() -> void:
	_udp.set_dest_address(OAR_ADDRESS, UDP_DATA_PORT)
	# A failure here is not worth reporting: the board's own "# wireless: host at
	# ..." line says whether it took, and that is the same fact told from the end
	# that actually knows.
	# 这里失败不值得报:板子自己那条 "# wireless: host at ..." 说的是同一件事,
	# 而且是从真正知道的那一端说的。
	_udp.put_packet("oar-here".to_ascii_buffer())


## Drains whatever the radio delivered since the last frame.
##
## Polled rather than signalled: Godot's PacketPeerUDP raises no arrival signal, so
## this is the only shape available -- and it is the same shape the serial side
## already uses in calling `poll_events()` once a frame.
## 把射频自上一帧以来送到的东西排空。
##
## 轮询而不是等信号:Godot 的 PacketPeerUDP 没有「包到达」信号,这是唯一可用的形状 ——
## 而且和串口那边每帧调一次 `poll_events()` 是同一个形状。
func _poll_udp() -> void:
	if _udp != null:
		var now := Time.get_ticks_msec()
		if now - _hello_msec >= int(HELLO_INTERVAL_SEC * 1000.0):
			_hello_msec = now
			_send_hello()

		while _udp.get_available_packet_count() > 0:
			var packet := _udp.get_packet()
			if packet.is_empty():
				continue
			_last_wifi_msec = Time.get_ticks_msec()
			_wifi_packets += 1
			_ingest(packet.get_string_from_ascii(), true)

	if _udp_diag != null:
		while _udp_diag.get_available_packet_count() > 0:
			var text := _udp_diag.get_packet().get_string_from_ascii().strip_edges()
			if text.is_empty():
				continue
			last_diag = text
			# Printed rather than pushed as a warning: a stalled sensor repeats its
			# own line once a second for as long as it stays stalled, and a warning
			# a second would bury everything else in the panel. The readout carries
			# it too, so it is on screen while it matters and in the output panel
			# afterwards.
			# 用 print 而不是 push_warning:卡住的传感器在卡着期间每秒重复它自己那行,
			# 每秒一条 warning 会把面板里别的东西全埋掉。读数里也带着它,
			# 所以需要的时候它在屏幕上,事后它在输出面板里。
			print("[SensorInput] firmware on the oar: ", text)


## Counts the samples the radio dropped, from the board's own packet counter.
##
## Nothing on the serial link can answer this: a UART does not lose a line, so the
## firmware has never had to number them. UDP does lose whole packets, and the
## only way to see it from here is for the board to say which one this is.
##
## A counter that goes backwards is a board that restarted, not a hole, so it is
## taken as a restart -- counting it as loss would report a million missing
## samples after every power cycle, which is a number that teaches nothing.
## 射频丢了多少样本,来自板子自己的包序号。
##
## 串口那边回答不了这个问题:UART 不会丢行,所以固件从来不需要给行编号。
## UDP 会丢掉整个包,而从这里能看见它的唯一办法,是让板子说这是第几个。
##
## 序号往回走是板子重启了,不是空洞,所以按重启处理 —— 把它算成丢包的话,
## 每次断电重启都会报一百万个丢失样本,那是个教不会任何东西的数字。
func _note_wifi_seq(board_seq: int) -> void:
	if board_seq < 0:
		return
	if _wifi_seq_last >= 0 and board_seq > _wifi_seq_last + 1:
		wifi_lost += board_seq - _wifi_seq_last - 1
	_wifi_seq_last = board_seq


# ------------------------------------------------------------ Serial port --
# ------------------------------------------------------------ 串口 --
func _open_port() -> void:
	if _manager == null:
		return

	var candidates := _candidate_ports()
	if candidates.is_empty():
		_status = "no serial port (retrying)"
		_schedule_retry()
		if not _open_failure_reported:
			_open_failure_reported = true
			push_warning("[SensorInput] No serial ports found. Plug in the Arduino, close the Serial Monitor, then rerun. (Retrying every %d s.)" % int(RECONNECT_INTERVAL_SEC))
		return

	# Try them in order; each candidate also gets an automatic macOS
	# /dev/cu. variant.
	# 按顺序逐个试;每个候选还会自动加上一个 macOS 的 /dev/cu. 变体。
	# MODE_LINE_BUFFERED == 1 (see addons/gdserial docs); numeric so this file
	# still parses when the GdSerialManager class is absent.
	const MODE_LINE_BUFFERED := 1
	var tried: Array[String] = []
	for cand in candidates:
		if _manager.open(cand, BAUD_RATE, READ_TIMEOUT_MS, MODE_LINE_BUFFERED):
			_port = cand
			port_open = true
			_open_failure_reported = false
			_last_data_msec = Time.get_ticks_msec()
			_status = "%s @ %d" % [cand, BAUD_RATE]
			print("[SensorInput] Opened port: ", _status)
			return
		tried.append(cand)

	_status = "open failed (retrying)"
	_schedule_retry()
	if not _open_failure_reported:
		_open_failure_reported = true
		push_error("[SensorInput] Could not open any of: " + ", ".join(PackedStringArray(tried)))
		push_error("[SensorInput] Check in this order: (1) close the Arduino IDE Serial Monitor (or the whole IDE); (2) run `lsof | grep -i usb` in a terminal to see what is holding the port; (3) try another cable (some are power-only); (4) unplug and replug the USB. (Retrying every %d s.)" % int(RECONNECT_INTERVAL_SEC))


## Pushes the next open attempt out by RECONNECT_INTERVAL_SEC. Called from every
## failure path so that no path can leave the sensor dead without a retry queued.
## 把下一次打开尝试推迟 RECONNECT_INTERVAL_SEC。每条失败路径都要调它,
## 这样没有任何一条路径能让传感器在没排重试的情况下死掉。
func _schedule_retry() -> void:
	_next_open_msec = Time.get_ticks_msec() + int(RECONNECT_INTERVAL_SEC * 1000.0)


## Gives up the current port and queues a reopen. Every way of losing the port
## goes through here -- a gdserial disconnect signal, and the silence watchdog --
## so that none of them can leave the sensor dead without a retry queued.
## 放弃当前端口并排一次重开。所有「丢失端口」的路径都走这里 —— gdserial 的掉线信号,
## 以及沉默看门狗 —— 这样没有任何一条能把传感器置于死地而不排重试。
func _lose_port(reason: String, warn: bool) -> void:
	if _manager != null and _port != "":
		_manager.close(_port)
	_port = ""
	port_open = false
	_status = reason + ", retrying…"
	_schedule_retry()
	if warn:
		push_warning("[SensorInput] " + reason + " -- reopening in %d s." % int(RECONNECT_INTERVAL_SEC))


## Builds the list of port names to try: explicit choice > auto-picked > every
## USB serial port, each with a macOS /dev/cu. variant added (cu opens more
## reliably than tty).
## 构造要尝试的端口名列表:显式指定 > 自动挑选 > 每个 USB 串口,每个都加上一个 macOS 的
## /dev/cu. 变体(cu 比 tty 打开更可靠)。
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
	# The listing is only worth printing on the first attempt. Once retrying is
	# under way it would repeat every RECONNECT_INTERVAL_SEC forever, and the
	# one line that matters (the failure, printed once by _open_port) would be
	# buried under it.
	# 这份列表只在第一次尝试时值得打印。一旦重试开始,它会每 2 秒重复一次,
	# 而真正重要的那一行(由 _open_port 只印一次)会被它埋掉。
	var verbose := not _open_failure_reported
	if verbose:
		print("[SensorInput] === available ports ===")
	if ports.is_empty():
		if verbose:
			print("  (none)")
		return ""

	var names: Array[String] = []
	for key in ports.keys():
		var info: Dictionary = ports[key]
		var pname := str(info.get("port_name", ""))
		names.append(pname)
		if verbose:
			print("  ", pname, "   [", str(info.get("device_name", "")), "]   ",
				str(info.get("port_type", "")))

	# Prefer a USB serial adapter, which is what an Arduino normally is.
	# 优先选 USB 串口适配器,Arduino 通常就是这种。
	for pname in names:
		if _looks_usb(pname):
			return pname

	# Nothing suitable, so fall back to the first one.
	# 没有合适的,就退回第一个。
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
## macOS:/dev/tty.usbmodem14101 -> /dev/cu.usbmodem14101。其他平台上原样返回。
func _cu_variant(port: String) -> String:
	if port.begins_with("/dev/tty."):
		return "/dev/cu." + port.substr("/dev/tty.".length())
	return port


func _looks_usb(pname: String) -> bool:
	return pname.begins_with("/dev/tty.usb") or pname.begins_with("/dev/cu.usb") \
		or pname.begins_with("/dev/ttyUSB") or pname.begins_with("/dev/ttyACM") \
		or pname.begins_with("COM")


func _on_data(port: String, data: PackedByteArray) -> void:
	# Stamped on any real arrival, before parsing, and deliberately not after a
	# successful parse: the watchdog is asking "is this port still delivering?",
	# and bytes that fail to parse still answer that. Parsing well or badly is a
	# separate question, and bad_lines already reports it.
	# 只要有真实到达就打时间戳,在解析之前,故意不放在解析成功之后:看门狗问的是
	# 「这个端口还在送东西吗」,而解析失败的字节一样回答得了这个问题。解析得好不好是另一个问题,
	# bad_lines 已经在报了。
	if not data.is_empty():
		_last_data_msec = Time.get_ticks_msec()

	# While the radio is carrying the stream, the cable is carrying the same
	# stream. Ingesting both would deliver every sample twice and make the readout
	# claim 200 Hz -- so the wire is dropped here, which is deliberately AFTER the
	# timestamp above: that is what stops the serial silence watchdog from
	# concluding the port died when it is in fact alive and merely redundant.
	# 无线在送这份数据的时候,串口送的是同一份。两个都吃进去会让每个样本到达两次、
	# 读数显示 200 Hz —— 所以在这里把串口来的丢掉。位置**故意**在上面的时间戳之后:
	# 正是这一点让串口的沉默看门狗不会把「端口好着呢、只是多余」判成「端口死了」。
	if is_wireless():
		return

	_ingest(data.get_string_from_ascii(), false)


## Feeds one chunk of ASCII from either link through the shared parse path: same
## parser, same counters, same `sample` signal, whichever transport it came in
## on. Everything the two links do differently is settled before this is called.
##
## Decoded as ASCII rather than UTF-8: the payload is nothing but digits, commas
## and newlines, and UTF-8 floods the console with "Unicode parsing error" the
## moment a byte is malformed -- garbled output from the wrong baud, a truncated
## packet off the radio -- which is exactly when the console has something worth
## showing.
##
## Split on newlines rather than assuming one line per call. Serial delivers one
## line at a time in line-buffered mode and the radio currently sends one line per
## packet, so today this loop always runs once -- but batching is the first lever
## to reach for if the radio turns out to cost the board samples, and that change
## should not have to reach in here.
## 把任一条链路来的一整块 ASCII 喂进共同的解析路径:同一套解析、同一套计数、同一个
## `sample` 信号,不管它是从哪个传输来的。两条链路所有不同的地方,都在调它之前就决定完了。
##
## 按 ASCII 而不是 UTF-8 解码:载荷只有数字、逗号和换行,而 UTF-8 会在第一个坏字节出现时
## 往控制台刷 "Unicode parsing error" —— 波特率不对的乱码、无线上的截断包 ——
## 那恰恰是控制台最该说话的时候。
##
## 按换行切开,而不是假定一次调用只有一行。串口的行缓冲一次给一行、无线现在一个包一行,
## 所以这个循环眼下总是只跑一遍 —— 但「射频要是真让板子丢样本,第一个该动的杠杆就是攒批发」
## 这件事,不该要改动伸进这里来。
func _ingest(text: String, from_wifi: bool) -> void:
	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		if line.is_empty():
			continue
		last_line = line

		# Which protocol this line is in. Keyed on the newer board's label, because
		# the older one's line is bare numbers and has nothing to key on -- so
		# anything that is not the newer format falls through to the old parser,
		# which is also the right behaviour for a garbled line: it gets counted as
		# bad instead of being silently half-parsed into plausible-looking numbers.
		# 这一行属于哪套协议。判据取新板子的标签,因为旧板子那行是裸数字、没有可依据的东西 ——
		# 所以不是新格式的一律落到旧解析器。这对乱码行也是对的:它会被记成 bad,
		# 而不是被悄悄解析成一组看着像样的数字。
		var was_good := _parse_imu(line) if line.contains("Accel(") else _parse_xyz(line)
		if not was_good:
			bad_lines += 1
			continue

		good_lines += 1
		if from_wifi:
			_note_wifi_seq(seq)
		# Announced after the latest-value fields are written, so a handler that
		# reads them instead of the arguments still sees this same sample.
		# 在「最新值」字段写好之后再发,这样读字段而不是读参数的处理函数拿到的也是同一个样本。
		sample.emit(x, y, z)


## Parses the newer board's six axes out of one line. Returns whether it was good.
##
## The six numbers are taken in the order they appear, not by matching them
## against the labels. That is deliberate: the labels ("Accel(g)",
## "Gyro(deg/s)") contain no digits, so the digits always come out as accel
## x,y,z then gyro x,y,z whatever the separators are -- and the parse survives
## the firmware being reformatted, say dropping the "|" or changing the spacing.
## 解析新板子一行里的六个轴。返回这行是否有效。
##
## 六个数字按**出现顺序**取,而不是去匹配标签。这是故意的:标签("Accel(g)"、
## "Gyro(deg/s)")里没有数字,所以无论分隔符是什么,数字顺序一定是加速度 x,y,z
## 然后陀螺仪 x,y,z —— 固件改格式(比如去掉「|」或改空格)也还能解析。
func _parse_imu(text: String) -> bool:
	var nums := _numbers_in(text)
	if nums.size() < 6:
		return false

	x = nums[0]
	y = nums[1]
	z = nums[2]
	gx = nums[3]
	gy = nums[4]
	gz = nums[5]
	# The wireless copy carries two more numbers after the six axes: the board's
	# packet counter and its own micros() timestamp (the firmware's S and T). Read
	# when present, ignored when not -- which is what lets the serial copy go
	# through this same function unchanged, its line having no room for them
	# because 115200 is already nearly full with the six axes alone.
	# 无线那份在六个轴之后多两个数:板子的包序号和它自己的 micros() 时间戳(固件的 S 和 T)。
	# 有就读、没有就忽略 —— 串口那份正是靠这一点原样走同一个函数的:
	# 它那行光装六个轴就已经把 115200 塞得差不多了,放不下这两个字段。
	seq = int(nums[6]) if nums.size() >= 7 else -1
	magnitude = sqrt(x * x + y * y + z * z)
	gyro_magnitude = sqrt(gx * gx + gy * gy + gz * gz)
	has_gyro = true
	accel_in_g = true
	return true


## Parses the ADXL345's bare "<x>,<y>,<z>" line. Returns whether it was good.
## 解析 ADXL345 的裸 "<x>,<y>,<z>" 行。返回这行是否有效。
func _parse_xyz(text: String) -> bool:
	var parts := text.split(",", false)
	if parts.size() != 3:
		return false

	var nums: Array[float] = []
	for part in parts:
		var token := part.strip_edges()
		if not token.is_valid_float():
			return false
		nums.append(token.to_float())

	x = nums[0]
	y = nums[1]
	z = nums[2]
	magnitude = sqrt(x * x + y * y + z * z)
	# Swapping the gyro board back out for an accelerometer-only one has to
	# clear these, or the readout would keep showing the last rates the gyro
	# ever reported and the overlay would be describing hardware that is no
	# longer plugged in.
	# 把陀螺仪板子换回只有加速度计的板子时,必须把这些清零,否则读数会一直显示陀螺仪
	# 最后报过的角速度,界面就在描述一个已经不在的硬件。
	gx = 0.0
	gy = 0.0
	gz = 0.0
	gyro_magnitude = 0.0
	has_gyro = false
	accel_in_g = false
	return true


## Every token of `text` that reads as a number, in order.
##
## Everything that cannot be part of a number is turned into a space first, then
## the pieces are filtered -- which is what makes this indifferent to the
## punctuation the firmware happens to use. The separators are listed rather than
## matched with a regex because a regex per line at 100 Hz is work the parse does
## not need to do.
## `text` 里所有「读起来像数字」的片段,按顺序。
##
## 先把不可能属于数字的字符换成空格,再过滤 —— 这就是它不挑固件标点的原因。
## 分隔符是逐个列出来的、没有用正则,因为 100 Hz 下每行跑一次正则,是这份解析
## 不必付的开销。
func _numbers_in(text: String) -> Array[float]:
	var cleaned := text
	for ch in ["(", ")", "/", ",", "|", ":", "=", ";"]:
		cleaned = cleaned.replace(ch, " ")

	var out: Array[float] = []
	for token in cleaned.split(" ", false):
		if token.is_valid_float():
			out.append(token.to_float())
	return out


func _on_disconnected(port: String) -> void:
	# Whatever took the port may already be gone, so this retries soon -- but not
	# on the next frame, because a port that is genuinely gone would then be
	# reopened 60 times a second.
	# 抢走端口的东西可能已经走了,所以这里很快就重试 —— 但不是下一帧,
	# 否则一个真的不在的端口会被每秒重新打开 60 次。
	_lose_port("disconnected (" + port + ")", true)


# ----------------------------------------------------------------- Readout --
# ----------------------------------------------------------------- 读数 --
func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.visible = _overlay_visible
	_overlay.layer = 100
	_overlay.visible = _overlay_visible
	add_child(_overlay)

	_label = Label.new()
	_label.position = Vector2(16.0, 16.0)
	_label.add_theme_font_size_override("font_size", 20)
	_label.add_theme_color_override("font_color", Color(0.08, 0.10, 0.12))
	_label.add_theme_color_override("font_outline_color", Color(1, 1, 1, 0.9))
	_label.add_theme_constant_override("outline_size", 6)
	_overlay.add_child(_label)


## The live readout. Shows every axis the sensor reports, both resultant
## lengths, and the raw line -- the raw line because it is the only thing here
## that is not an interpretation, so when a field is in the wrong place or a new
## board reformats its output, the cause is visible instead of merely suspected.
## 实时读数。显示传感器报的每一个轴、两个合矢量长度,以及**原始行** ——
## 原始行在这里是唯一一个「未经解释」的东西,所以当字段错位、或者新板子改了输出格式时,
## 原因能直接被看见,而不是只能靠猜。
func _refresh_overlay() -> void:
	if _label == null:
		return
	# Either link delivering counts as live: with the board on a power bank there
	# is no serial port at all, and with it on a cable the radio may not be joined.
	# Watching only one of them would make a working sensor look dead.
	# 任一条链路在送东西就算「活着」:板子接充电宝时根本没有串口,接笔记本时又可能没连热点。
	# 只盯其中一条,会让一个正常工作的传感器看起来是死的。
	var dot := "●" if (is_wireless() or port_open) else "○"
	var accel_unit := "g" if accel_in_g else "m/s²"

	var rows := [
		"%s sensor  %s" % [dot, _link_text()],
		"accel  x %8.3f   y %8.3f   z %8.3f   |a| %7.3f %s" % [
			x, y, z, magnitude, accel_unit],
	]
	if has_gyro:
		rows.append("gyro   x %8.3f   y %8.3f   z %8.3f   |w| %7.3f deg/s" % [
			gx, gy, gz, gyro_magnitude])
	else:
		# Said out loud rather than shown as four zeros, because a gyro board
		# reading zero and a board with no gyro would otherwise look identical --
		# and telling those two apart is the whole reason to look at this.
		# 明说,而不是显示四个 0:否则「陀螺仪坏的板子」和「没有陀螺仪的板子」看起来一模一样,
		# 而分辨这两者正是看这个界面的全部意义。
		rows.append("gyro   -- no gyro on this sensor --")

	var counts := "%.1f Hz   lines %d / bad %d" % [hz, good_lines, bad_lines]
	if _wifi_packets > 0:
		# Shown only once the radio has actually been heard from, so a cabled
		# board's readout is exactly what it always was.
		# 只有在真的收到过无线包之后才显示,这样插着线的板子读数还是原来那个样子。
		counts += "   wifi lost %d" % wifi_lost
	rows.append(counts)
	rows.append("raw  %s" % last_line)
	if last_diag != "":
		rows.append("firmware  %s" % last_diag)
	_label.text = "\n".join(rows)


## What the readout calls the link that is actually carrying samples.
##
## The serial `_status` is what it shows when serial is the one working, because
## that string holds the port name and the baud. When the radio is carrying there
## is no point showing the serial state at all: the port may not even exist, and
## "no serial port (retrying)" sitting next to a perfectly healthy 100 Hz readout
## is the kind of thing that sends someone hunting for a cable that is not there.
## 读数怎么称呼「正在送样本的那条链路」。
##
## 串口在干活时显示的就是 `_status`,因为那个字符串里有端口名和波特率。
## 无线在送的时候则完全没必要显示串口状态:端口可能根本不存在,
## 而把「no serial port (retrying)」摆在一个完全健康的 100 Hz 读数旁边,
## 正是会让人去找一根并不存在的线的那种东西。
func _link_text() -> String:
	if is_wireless():
		return "wifi udp %d   %.0f pkt/s" % [UDP_DATA_PORT, wifi_pps]
	return _status
