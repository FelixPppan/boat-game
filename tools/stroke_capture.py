#!/usr/bin/env python3
"""stroke_capture.py -- record the oar's raw stream to a file, from a terminal.

Why this exists next to Scripts/stroke_recorder.gd
--------------------------------------------------
Both recorders write the same rows now -- `S <t> <x> <y> <z> <gx> <gy> <gz>` and
`L <t> <label>` -- so a take from either one can be scored the same way, here and
in tools/direction_lab.py. What this one adds is that it runs with no game in the
loop, and that it sees the board's own packet counters, which is how it can tell a
DAMAGED take from a merely slow one. What the Godot one adds is that it is the
only one that can mark a label from inside the game. Neither writes the old F
line any more: that recorded the controller's per-frame decision for a
golden-trace comparison, and both the comparison and the algorithm it checked
against are gone -- the rule is one line over the raw stream, so the raw stream is
the whole of what a replay needs.

The oar is usually UNTETHERED, running off a power bank with no cable, so the
default question "which port" has no answer: use --udp and record over the
board's own access point.

    python3 tools/stroke_capture.py --udp --label forward
    python3 tools/stroke_capture.py --udp --label backstroke --seconds 20
    python3 tools/stroke_capture.py --udp --label other --no-save   # just watch
    python3 tools/stroke_capture.py --label forward                 # over USB

Stop with Ctrl-C, or with --seconds. The summary at the end is printed either
way, and the file is flushed as it goes, so a Ctrl-C never costs the take.

Over the radio, join "oar-sensor" from the Mac's WiFi menu first. This asks the
board to unicast (broadcast loses about 7% and delivers it in clumps, which
would corrupt a take in a way that looks like the sensor stuttering), and it
reports what the radio lost, using the packet counter the board puts on the
wireless copy. See tools/udp_probe.py for the link measurement that established
this.

WHY THE S LINE HAS SEVEN NUMBERS
--------------------------------
`gx` is the fore/aft rotation rate, and on this oar its sign IS the rowing rule:
the power stroke is the aft sweep, and the boat drives forward on `-gx` above a
deadband. A take without the gyro in it cannot be scored against that rule at
all, so it goes in the same line as the accel and every line carries it.

Scripts/stroke_recorder.gd writes the same seven columns, reading the gyro off
SensorInput inside its `sample` handler. tools/direction_lab.py parses both
widths, because takes recorded before 2026-09-30 have only the four.

    S <t> <x> <y> <z> <gx> <gy> <gz>      one per sensor sample, at the sensor's rate
    L <t> <label>                          forward | backstroke | other | none
    # <t> <text>                           firmware diagnostics, as they happened

这个脚本为什么存在
------------------
两个录制器现在写的行是一样的 —— `S <t> <x> <y> <z> <gx> <gy> <gz>` 和
`L <t> <label>` —— 所以哪一边录出来的实录都能用同样的方式打分,这里和
tools/direction_lab.py 都是。这个脚本多出来的是:它不在游戏的回路里,而且它看得见板子自己
的包计数器 —— 那是它分得出「这条实录坏了」和「只是慢」的依据。Godot 那个多出来的是:它是
唯一能从游戏内部打标签的。两者都不再写旧的 F 行:那一行记的是控制器逐帧的判定,用于
golden trace 比对,而那个比对和它比对的那套算法都已经走了 —— 规则是一行作用在原始流上的
式子,所以原始流就是一整份回放需要的东西。

桨通常是**脱绳的** —— 挂在充电宝上、不插线 —— 所以「哪个串口」这个问题根本没有答案:
用 --udp,走板子自己的热点录。

    python3 tools/stroke_capture.py --udp --label forward
    python3 tools/stroke_capture.py --udp --label backstroke --seconds 20
    python3 tools/stroke_capture.py --udp --label other --no-save   # 只看不存
    python3 tools/stroke_capture.py --label forward                 # 走 USB

Ctrl-C 或 --seconds 结束。两种方式都会打印结尾的汇总,文件是边录边刷的,所以 Ctrl-C 不会
毁掉这一条。

走无线之前,先从 Mac 的 WiFi 菜单加入 "oar-sensor"。这里会请板子改发单播(广播丢大约
7%,而且是**成簇**地丢,那会以一种「传感器一卡一卡」的假象污染实录),并且用板子打在无线
那份里的包计数器报出射频丢了什么。这套链路测量的来龙去脉见 tools/udp_probe.py。

S 行为什么是七个数
------------------
`gx` 是前后方向的转动速率,而在这根桨上它的符号**就是**划桨的规则:动力段是向后扫,船在
`-gx` 越过门槛时往前走。一条没带陀螺仪的实录根本没法拿这条规则打分,所以它和加速度走在同一
行里,每一行都带着。

Scripts/stroke_recorder.gd 也写同样的七列 —— 它在自己的 `sample` 处理函数里从 SensorInput
上读陀螺仪。tools/direction_lab.py 两种宽度都解析,因为 2026-09-30 之前录下来的实录只有
四列。

    S <t> <x> <y> <z> <gx> <gy> <gz>      每个传感器样本,按传感器速率
    L <t> <label>                          forward | backstroke | other | none
    # <t> <text>                           固件诊断,发生的时候就写下来
"""

import argparse
import os
import queue
import re
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# The port handling is the delicate part and it already exists, including the
# reason it is delicate (termios belongs to an open descriptor, and macOS resets
# the port to 9600 when the last one closes). Importing it rather than copying it
# keeps one copy of that trap.
# 开端口这件事是精细活,而且已经写好了,包括它为什么精细(macOS 在最后一个描述符关闭时
# 会把端口复位回 9600)。import 它而不是抄一份,那个陷阱就只有一处。
from serial_probe import IMU_RE, find_port, open_configured

# The radio side is the same story: the hello that switches the board from
# broadcast to unicast, the bind that refuses to share the port, and the
# wrong-network check are all in udp_probe.py, tested by measuring the link. A
# second copy here would be a second thing to keep in step with the firmware.
# 无线这边同理:让板子从广播改单播的 hello、拒绝共端口的 bind、以及「上错网」检查都在
# udp_probe.py 里,是用实测链路验过的。在这里再抄一份,就是又多一处在固件改动时要跟着走。
from udp_probe import (HELLO_INTERVAL_SEC, HINTS, MICROS_MASK, OAR_ADDRESS,
                       check_network, open_socket, send_hello)

DEFAULT_BAUD = 115200
REC_DIR = "recordings"

LABELS = ("none", "forward", "backstroke", "other")

# The board appends its own counters to the WIRELESS copy of each line, and only
# to that one:
#     ... | Gyro(deg/s): a, b, c | S: <packet number>, T: <micros()>
# S is what makes a dropped packet visible -- without it, a lost packet just
# reads as a lower rate, which is exactly what a stalled sensor looks like too --
# and T is the board's own clock, so the sample interval can be checked with the
# radio's jitter taken out. Neither is written into the recording: the file's
# format is the sensor's readings, and these are facts about the link.
# 板子把**只有无线那一份**才带的两个计数器追加在行尾。S 让丢包看得见 —— 没有它,丢一个包
# 只表现为速率变低,而那和「传感器卡住了」一模一样 —— T 是板子自己的时钟,所以样本间隔
# 可以撇开射频抖动来查。两个都不写进实录:文件格式是传感器的读数,而这两个是关于链路的事实。
WIRELESS_TAIL_RE = re.compile(r"\|\s*S:\s*(\d+),\s*T:\s*(\d+)")

# The gate that is NOT in the rule, kept here as the evidence that killed it.
#
# The plan was: load the blade in the water and |a| rises toward 1 g, swing it
# through air and it does not, so "is the blade loaded" can be read off |a| and
# the boat can be made to pay only for real strokes. The 2026-09-29 take finished
# that idea: |a|/g ran 0.169..6.808 and the extremes were in strokes the player
# confirmed were in the water, so the water and air populations overlap completely
# and no threshold on |a| separates them. The rule is now `-gx` against a deadband
# with no load gate at all, and waving the oar in the air does drive the boat.
#
# So this block is a measurement, not a gate: it stays because it is the number
# that would REVIVE the hypothesis if some future take disagreed with that one,
# and because a take you cannot evaluate until tomorrow is a take you cannot steer
# by. It is reported on the sweeping samples only -- a sample with no sweep in it
# is not evidence either way.
# 这条门槛**不在**规则里,留在这里的是推翻它的那份证据。
#
# 原来的设想:桨叶在水里会被压住、|a| 往 1 g 走,在空中挥就不会,于是「桨叶有没有负载」可以
# 从 |a| 上读出来,船就可以只给真实划水付钱。2026-09-29 那份实录把这个想法了结了:|a|/g 跑了
# 0.169…6.808,而极端值出现在玩家确认**在水里**的那几桨上,所以水里和空中的总体完全重叠,没有
# 任何 |a| 阈值能分开它们。现在的规则是 `-gx` 过一个门槛,完全没有载荷判据,在空中挥桨一样
# 会推船。
#
# 所以这一段是一个**测量**,不是门槛:留着它,是因为将来某条实录一旦和那一条不一致,它就是
# 能把假设救回来的那个数字,也因为一条要等到明天才能评价的实录,是你没法拿它做决定的实录。
# 只在真的在扫的样本上报 —— 没有扫桨的样本对这件事不算证据。
SWEEP_MIN = 20.0   # deg/s on gx; below this the oar is not being swept at all
# SWEEP_MIN: gx 上的 deg/s;低于此处桨根本没在扫
GATE_T = 1.2       # one-sided gate: |a|/g < GATE_T  =>  "loaded"
# GATE_T: 单边门槛,|a|/g < GATE_T 即「有载荷」
GATE_LO = 0.9      # band gate instead: loaded means |a|/g inside [GATE_LO, GATE_T]
# GATE_LO: 带状门槛,有载荷指 |a|/g 落在 [GATE_LO, GATE_T] 内


def stamp() -> str:
    return time.strftime("%Y-%m-%d-%H%M%S")


class Take:
    """The file being written, plus the numbers for the summary.

    正在写的这个文件,外加汇总要用的那些数字。
    """

    def __init__(self, path: str, label: str, source: str) -> None:
        self.path = path
        self.label = label
        self.samples = 0
        self.unparsed = 0
        self.diag_count = 0
        # How many diagnostics have been echoed to the screen. The file takes
        # them all; the screen takes a few, because a firmware that is stuck can
        # emit them at loop rate and an unbounded echo is the same flood as an
        # unbounded sample view.
        # 已经往屏幕上回过多少条诊断。文件全收,屏幕上只回几条:卡住的固件可以按循环速率
        # 刷诊断,无上界的回显和无上界的样本视图是同一种洪水。
        self.diag_echoed = 0
        self.first_t = None
        self.last_t = None
        # |a|/g and gx, kept so the summary can say what the take actually
        # contained rather than only how long it was.
        # 留下 |a|/g 和 gx,好让汇总说的是这一条**内容**是什么,而不只是它有多长。
        self.mags = []
        self.gxs = []
        # Sample times, in the same order and appended in the same place, so the
        # per-second view below can bucket them without re-reading the file.
        # 样本时刻,与上面两个同序、在同一处追加,好让下面的按秒视图不必重读文件就能分桶。
        self.ts = []
        # Radio accounting, from the wireless tail. All None/0 on a USB take.
        # 射频账,来自无线行尾。走 USB 的实录里全是 None/0。
        self.lost = 0
        self._last_seq = None
        self.first_seq = None
        self.last_seq = None
        self.first_t_us = None
        self.last_t_us = None
        self.fh = None
        if path:
            d = os.path.dirname(path)
            if d:
                os.makedirs(d, exist_ok=True)
            self.fh = open(path, "w", encoding="utf-8")
            self._line("# oar take, label=%s, %s" % (label, time.strftime("%Y-%m-%d %H:%M:%S")))
            self._line("# read from %s" % source)
            self._line("# S <t> <x> <y> <z> <gx> <gy> <gz>   accel in g, gyro in deg/s")
            self._line("# L <t> <label>                     %s" % " | ".join(LABELS))
            # One label at t=0 rather than keys during the take: a take records
            # one gesture, and separate runs are easier to keep honest than a
            # keypress that may or may not have registered.
            # t=0 处写一个标签,而不是录的过程中按键:一条实录录一个动作,而分几次跑,
            # 比一个「按没按上不确定」的按键更容易说得清。
            self._line("L 0.000000 %s" % label)

    def _line(self, s: str) -> None:
        if self.fh:
            self.fh.write(s + "\n")

    # --------------------------------------------------------------- one line
    # ------------------------------------------------------------------ 单行
    def add_line(self, text: str, t: float):
        """Take one wire line. Returns the six readings, or None.

        A `#` line is not a bad sample and is not counted as one: the firmware's
        diagnostics say what the board was doing (a stall, a recovery), and
        folding them into a "malformed data" count would hide exactly the
        context that explains a gap in the samples. They go in the file as
        comments, so a stall is visible at the moment it happened.
        # 行不是坏样本,也不按坏样本计:固件诊断说的是板子当时在干什么(卡住、恢复),
        把它们算进「数据格式错误」里,恰好会把解释样本缺口的那点上下文藏起来。它们以注释
        的形式进文件,于是卡顿发生在哪一刻是一眼可见的。
        """
        if text.startswith("#"):
            self.diag_count += 1
            self._line("# %.6f %s" % (t, text))
            return None

        m = IMU_RE.search(text)
        if not m:
            self.unparsed += 1
            return None

        x, y, z, gx, gy, gz = (float(v) for v in m.groups())
        self._note_wireless_tail(text)
        self.samples += 1
        if self.first_t is None:
            self.first_t = t
        self.last_t = t
        self.mags.append((x * x + y * y + z * z) ** 0.5)
        self.gxs.append(gx)
        self.ts.append(t)
        self._line("S %.6f %.6f %.6f %.6f %.6f %.6f %.6f" % (t, x, y, z, gx, gy, gz))
        return (x, y, z, gx, gy, gz)

    def _note_wireless_tail(self, text: str) -> None:
        tail = WIRELESS_TAIL_RE.search(text)
        if not tail:
            return
        seq = int(tail.group(1))
        t_us = int(tail.group(2)) & MICROS_MASK
        if self._last_seq is not None:
            step = seq - self._last_seq
            if step > 1:
                self.lost += step - 1
        self._last_seq = seq
        if self.first_seq is None:
            self.first_seq = seq
        self.last_seq = seq
        if self.first_t_us is None:
            self.first_t_us = t_us
        self.last_t_us = t_us

    def flush(self) -> None:
        if self.fh:
            self.fh.flush()

    def close(self) -> None:
        if self.fh:
            self._line("# stopped %s -- %d samples" % (time.strftime("%H:%M:%S"), self.samples))
            self.fh.close()
            self.fh = None

    # ------------------------------------------------------------------ report
    # -------------------------------------------------------------------- 报告
    def board_rate(self):
        """The board's own sample rate in Hz, or None.

        From the board's two counters over the whole take, never from the
        intervals between received packets: a lost packet makes one of those
        span two periods, so the median reads low and a healthy 100 Hz board
        looks like it slowed down. tools/udp_probe.py reported exactly that on
        2026-09-28, which is why the arithmetic lives here in one place.
        从板子自己的两个计数器、跨整条实录算出来,永远不从「收到的包之间」的间隔算:
        丢一个包就让其中一个间隔跨两个周期,于是中位数偏低,一块好端端跑在 100 Hz 的板子
        看起来像降速了。tools/udp_probe.py 在 2026-09-28 就是这么报的,所以这段算术只此一处。
        """
        if None in (self.first_seq, self.last_seq, self.first_t_us, self.last_t_us):
            return None
        samples = self.last_seq - self.first_seq
        span_us = (self.last_t_us - self.first_t_us) & MICROS_MASK
        if samples <= 0 or span_us <= 0:
            return None
        return (samples + 1) * 1e6 / span_us

    def report(self, note: str = "") -> None:
        print()
        if self.samples == 0:
            print("  no samples -- nothing was recorded")
            if self.diag_count:
                print("  (but %d firmware line(s) arrived -- see the file)" % self.diag_count)
            return

        span = self.last_t - self.first_t
        mags = sorted(self.mags)
        n = len(mags)
        median = mags[n // 2]
        # How much of the take is quasi-static, i.e. attitude only. It was the
        # number that decided whether the |a| gate had anything to work with; the
        # gate is gone (see the constants), and this stays as the coarsest way to
        # see how much of a take was an oar sitting still.
        # 这一条里有多少是准静态的,也就是纯姿态。它曾经是「|a| 门槛有没有东西可用」的判据;
        # 门槛已经没了(见那几个常数),这里留下来,当作「这条实录里有多少时间是桨放着不动」
        # 最粗的一个看法。
        near1 = sum(1 for m in mags if abs(m - 1.0) <= 0.05)
        turning = sum(1 for g in self.gxs if abs(g) > 5.0)

        print("  %d samples over %.2f s  (%.1f Hz)" % (n, span, n / span if span else 0.0))
        print("  |a|/g   min %.3f  median %.3f  max %.3f" % (mags[0], median, mags[-1]))
        print("  |a|/g   within 5%% of 1 g: %d/%d (%.0f%%)" % (near1, n, 100.0 * near1 / n))
        print("  gx      min %+8.1f  max %+8.1f deg/s" % (min(self.gxs), max(self.gxs)))
        print("  gx      |gx| > 5 deg/s: %d/%d (%.0f%%)"
              % (turning, n, 100.0 * turning / n))

        # The two |a| tests that are NOT in the rule, on the sweeping samples only:
        # a sample with no sweep in it is not evidence either way, and including
        # the resting samples would only make both of them look good by averaging
        # them against an oar lying still. Read them as "what a gate would have
        # said", never as a gate: the rule applies no gate at all.
        # 两条**不在**规则里的 |a| 判据,只在正在扫的样本上算:没有扫桨的样本对这件事不算
        # 证据,把静止的样本也算进去,无非是拿「桨放着不动」去平均,让两者都显得好看。读它们的
        # 时候当成「如果有门槛它会怎么说」,而不是门槛本身:规则里一个门槛都没有。
        sweep = sorted(m for m, g in zip(self.mags, self.gxs) if abs(g) >= SWEEP_MIN)
        if sweep:
            sn = len(sweep)
            one = sum(1 for m in sweep if m < GATE_T)
            band = sum(1 for m in sweep if GATE_LO <= m <= GATE_T)
            print("  while |gx| >= %.0f deg/s (%d samples):" % (SWEEP_MIN, sn))
            print("    |a|/g   min %.3f  median %.3f  max %.3f"
                  % (sweep[0], sweep[sn // 2], sweep[-1]))
            print("    gate    |a|/g < %.2f        would call %d/%d loaded (%.0f%%)"
                  % (GATE_T, one, sn, 100.0 * one / sn))
            print("    gate    %.2f <= |a|/g <= %.2f  would call %d/%d loaded (%.0f%%)"
                  % (GATE_LO, GATE_T, band, sn, 100.0 * band / sn))

            # Per second, because a whole-take average cannot tell a phase of
            # loading from a phase of air. The question is never "how was this
            # take", it is "was the blade in the water during *this* sweep", and
            # in a real take that changes second by second -- the take above had
            # a 3 s stretch at 95-100% in band inside 20 s that ran 17-59%, and
            # averaging those together describes neither one.
            # 按秒,因为整条实录的平均值分不出「负载的一段」和「空挥的一段」。问题从来不是
            # 「这一条怎么样」,而是「**这一次**扫桨时桨叶在不在水里」,而在真实的一录里这件事
            # 每一秒都在变 —— 上面那一条里就有 3 秒稳定在带内 95–100%,夹在 20 秒只有 17–59%
            # 当中,把这两者平均起来,哪一个都没描述到。
            step = max(1, int(span / 60) + 1)
            buckets = {}
            for t, m, g in zip(self.ts, self.mags, self.gxs):
                buckets.setdefault(int(t) // step, []).append((m, g))
            print("  every %d s:" % step)
            print("     sec    n  |gx|max   |a|min   |a|med   |a|max    band   <0.9    >1.2")
            for b in sorted(buckets):
                cells = buckets[b]
                w = sorted(m for m, g in cells if abs(g) >= SWEEP_MIN)
                if not w:
                    print("   %5d  %4d  %7.0f        -        -        -       -       -       -"
                          % (b * step, len(cells), max(abs(g) for _, g in cells)))
                    continue
                n2 = len(w)
                print("   %5d  %4d  %7.0f  %7.3f  %7.3f  %7.3f  %4.0f%%   %4.0f%%   %4.0f%%"
                      % (b * step, len(cells), max(abs(g) for _, g in cells), w[0],
                         w[n2 // 2], w[-1],
                         100.0 * sum(1 for m in w if GATE_LO <= m <= GATE_T) / n2,
                         100.0 * sum(1 for m in w if m < GATE_LO) / n2,
                         100.0 * sum(1 for m in w if m > GATE_T) / n2))

        rate = self.board_rate()
        if rate is not None:
            # The radio's own scorecard. A take with samples missing is not a
            # shorter take: the replay reconstructs each frame from the samples
            # it received, so a clump of missing samples changes what the chain
            # saw, and a number here is the difference between "the algorithm
            # disagreed with the player" and "the recording was damaged".
            # 射频自己的成绩单。缺样本的实录不是「更短的实录」:回放是用它收到的样本来重建每一帧
            # 的,所以缺一簇样本就改变了信号链当时看到的东西,而这个数字就是「算法和玩家判得不
            # 一样」与「这条实录本身是残的」之间的区别。
            print("  board   %.2f Hz  (from the board's own S/T)" % rate)
            total = self.samples + self.lost
            print("  radio   lost %d of %d samples (%.2f%%)"
                  % (self.lost, total, 100.0 * self.lost / total if total else 0.0))
            if self.lost:
                print("          ^ the take is damaged; re-record it if the numbers matter")
        if self.unparsed:
            print("  %d line(s) arrived that were neither a sample nor a diagnostic"
                  % self.unparsed)
        if self.diag_count:
            print("  %d firmware diagnostic line(s) -- check the file for a stall"
                  % self.diag_count)
        if self.path:
            print("  saved -> %s" % self.path)
        if note:
            print("  %s" % note)


DIAG_ECHO_MAX = 5


def load_take(path: str) -> Take:
    """A Take rebuilt from a saved recording.

    The gate constants will move as we learn, and every take already recorded has
    to be re-scorable with the new ones -- otherwise a change of threshold
    silently invalidates the data it was chosen from, and the only way back is to
    go and record it all again. The link facts (loss, board rate) are not in the
    file on purpose, so those come back empty rather than invented.
    门槛常数会随着认识改变,而每一条已经录下来的实录都必须能拿新常数重新算过 —— 否则改一次
    门槛就悄悄作废了当初据以选它的数据,唯一的退路就是全部重录。链路那两个事实(丢包、板上速率)
    是故意不写进文件的,所以读回来是空的,而不是编出来的。
    """
    take = Take("", "read", path)
    try:
        fh = open(path, encoding="utf-8")
    except OSError as exc:
        print("cannot read %s: %s" % (path, exc), file=sys.stderr)
        return take
    for ln in fh:
        if not ln.startswith("S "):
            continue
        p = ln.split()
        if len(p) != 8:
            take.unparsed += 1
            continue
        try:
            t, x, y, z, gx, gy, gz = (float(v) for v in p[1:8])
        except ValueError:
            take.unparsed += 1
            continue
        take.samples += 1
        if take.first_t is None:
            take.first_t = t
        take.last_t = t
        take.mags.append((x * x + y * y + z * z) ** 0.5)
        take.gxs.append(gx)
        take.ts.append(t)
    fh.close()
    return take


def print_beat(elapsed: float, take) -> None:
    """One status line, on a timer.

    Deliberately not one line per sample. Output that grows with the length of
    the take is output that can outrun whatever is reading it, and a recorder
    that cannot be trusted to return to the prompt is a recorder nobody can run
    a take with. This prints at most one line every `--live` seconds, so a ten
    minute take costs a few dozen lines and nothing downstream can be buried.
    Every sample still reaches the file.
    故意不是一行一样本。随实录长度增长的输出,就是能跑赢读它的那一端的输出;而一个不能
    保证回到提示符的录制器,是没人敢拿它录的。这里最多每 `--live` 秒打一行,所以十分钟的
    实录也只花几十行,下游什么都不会被埋掉。每一个样本仍然进文件。
    """
    if take.gxs:
        print("  %5.1fs  %5d samples   last |a|/g %.3f  gx %+7.1f"
              % (elapsed, take.samples, take.mags[-1], take.gxs[-1]))
    else:
        print("  %5.1fs  no samples yet" % elapsed)
    sys.stdout.flush()


# ------------------------------------------------------------- the forward rule
# The controller now judges direction from the gyro alone (see
# Scripts/oar_controller.gd). These are the same two numbers it runs on, kept here
# so a recording can be scored with Godot shut. They are the only constants that
# have to stay in step with the GDScript, and --forward prints them, so a drift
# between the two shows up instead of staying silent.
# 控制器现在只看陀螺仪判方向(见 Scripts/oar_controller.gd)。这两个数和它用的同一对,
# 放在这里是为了不开 Godot 也能给实录打分。它们是唯一必须和 GDScript 保持同步的常数,而
# --forward 会把它们打出来,所以两边漂了是看得见的,不会悄悄的。
SWEEP_DEADBAND = 40.0    # deg/s of -gx. The oar at rest peaks at 6.5 -- 6x margin
# SWEEP_DEADBAND: -gx 的 deg/s。桨静止时的峰值是 6.5 —— 6 倍余量
SWEEP_FULL = 150.0       # deg/s of -gx where a stroke saturates
# SWEEP_FULL: -gx 的 deg/s,一桨到此饱和
MAX_THRUST = 600.0       # Scenes/boat.gd max_thrust, for reporting thrust
# MAX_THRUST: Scenes/boat.gd 的 max_thrust,用来报推力
BOAT_LINEAR_DRAG = 60.0  # Scenes/boat.gd linear_drag, for the steady-speed column
# BOAT_LINEAR_DRAG: Scenes/boat.gd 的 linear_drag,给稳速那一列用
STROKE_GAP = 0.25        # s of quiet that ends a stroke
# STROKE_GAP: 结束一桨所需的静默秒数
STROKE_ROWS_MAX = 60     # cap on the stroke list; output stays bounded
# STROKE_ROWS_MAX: 桨清单的上限;输出因此有界
TABLE_ROWS_MAX = 120     # cap on the per-second table, same reason
# TABLE_ROWS_MAX: 每秒表的上限,同一个原因


def forward_power(gx: float, dead: float, full: float) -> float:
    """Thrust for one sample: the aft sweep, and only the aft sweep.

    `sweep = -gx`, because a backward sweep is the stroke that drives the boat
    forward. Nothing else is consulted -- the recovery carries the opposite sign
    and is rejected by the sign alone, which is why this rule has no hysteresis,
    no cooldown and no "blade in the water" gate left in it.
    一个样本的推力:只看向后扫,只看向后扫。`sweep = -gx`,因为向后扫才是把船推向前的
    那一冲程。别的什么都不看 —— 回程符号相反,光靠符号就被排除掉了,这就是为什么这条
    规则里不再有滞回、不再有冷却、也不再有「桨叶在水里」的门槛。
    """
    sweep = -gx
    if sweep <= dead:
        return 0.0
    return min((sweep - dead) / (full - dead), 1.0)


def find_strokes(ts, ps, gxs, dead):
    """Maximal runs of -gx > dead, merging runs closer together than STROKE_GAP.

    One run per stroke is the property the whole simplification rests on: because
    the rule reads a signed signal instead of a differentiated one, the aft lobe
    cannot split into two bursts. A take where this returns two runs per physical
    stroke means something upstream is wrong.

    -gx > dead 的极大连续段,间隔小于 STROKE_GAP 的两段会被合并。一次划桨只出一段,是
    整个简化的立足点:因为规则读的是带符号的信号、不是微分过的信号,向后那个瓣不会裂成
    两簇。这条函数若对一次真实划桨返回两段,就说明上游有问题。
    """
    runs = []
    start = last = None
    peak_p = peak_g = 0.0

    def close():
        runs.append((start, last, peak_p, peak_g))

    for t, p, gx in zip(ts, ps, gxs):
        if -gx > dead:
            if start is not None and t - last > STROKE_GAP:
                close()
                start, peak_p, peak_g = None, 0.0, 0.0
            if start is None:
                start = t
            last = t
            peak_p = max(peak_p, p)
            peak_g = min(peak_g, gx)
        elif start is not None and t - last > STROKE_GAP:
            close()
            start, peak_p, peak_g = None, 0.0, 0.0
    if start is not None:
        close()
    return runs


def steady_speed(thrust: float) -> float:
    """The speed at which this thrust balances boat.gd's drag.

    boat.gd has linear_drag 60 and quadratic_drag 60, so thrust = 60v + 60v^2.
    Reported so a constant change can be read as "how fast does the boat actually
    go" instead of as an abstract mean power.

    这个推力与 boat.gd 的阻力相平衡时的速度。boat.gd 的 linear_drag 是 60、quadratic_drag
    是 60,所以 thrust = 60v + 60v^2。报出来,是为了让某个常数改动可以读成「船实际跑多
    快」,而不是一个抽象的平均功率。
    """
    return (-1.0 + (1.0 + 4.0 * thrust / BOAT_LINEAR_DRAG) ** 0.5) / 2.0


def score_forward(take: Take, dead: float, full: float) -> None:
    """Score a saved take against the forward-only rule.

    Output is bounded on purpose: at most TABLE_ROWS_MAX rows in the per-second
    table and at most STROKE_ROWS_MAX strokes listed, however long the take is.
    输出是刻意有上限的:不管实录多长,每秒的表最多 TABLE_ROWS_MAX 行,桨的清单最多
    STROKE_ROWS_MAX 条。
    """
    if not take.ts:
        print("  no samples to score")
        return
    if full <= dead:
        print("  full (%.0f) must be greater than dead (%.0f)" % (full, dead),
              file=sys.stderr)
        return
    ps = [forward_power(g, dead, full) for g in take.gxs]
    span = take.last_t - take.first_t

    print("forward rule:  forward_power = clamp((-gx - dead) / (full - dead), 0, 1)")
    print("  dead %.0f deg/s   full %.0f deg/s   (oar_controller.gd "
          "SWEEP_DEADBAND / SWEEP_FULL)" % (dead, full))
    print("  %d samples over %.2f s" % (take.samples, span))
    print()

    # --- one row per second, thinned if the take is long
    # --- 每秒一行,实录长的话就抽稀
    step = max(1, int(span / TABLE_ROWS_MAX) + 1)
    buckets = {}
    for t, p, gx in zip(take.ts, ps, take.gxs):
        b = buckets.setdefault(int(t) // step,
                               {"n": 0, "sum_p": 0.0, "peak_p": 0.0,
                                "gx_lo": gx, "gx_hi": gx})
        b["n"] += 1
        b["sum_p"] += p
        b["peak_p"] = max(b["peak_p"], p)
        b["gx_lo"] = min(b["gx_lo"], gx)
        b["gx_hi"] = max(b["gx_hi"], gx)
    print("   each row is %d s" % step if step > 1 else "   each row is 1 s")

    print("      sec      n   gx min   gx max   mean p   peak p")
    for k in sorted(buckets):
        b = buckets[k]
        print("   %6d   %5d  %+8.1f %+8.1f    %.3f    %.3f"
              % (k * step, b["n"], b["gx_lo"], b["gx_hi"],
                 b["sum_p"] / b["n"], b["peak_p"]))

    # --- how much room the deadband has left
    # The rule can only ever pay when -gx > dead, so "no false positives" is not a
    # claim this scorer can test -- it is a property of the arithmetic. What it can
    # measure is the MARGIN: how close the oar's own noise came to the deadband.
    # Walking back from the end while the rule pays nothing finds the stretch where
    # the oar was down without being told where it is, and the largest -gx in there
    # is the number to watch. If it ever approaches the deadband, the deadband is
    # too low for this boat.
    # 规则只有在 -gx > dead 时才可能给力,所以「没有假阳性」不是这个打分器能检验的东西 ——
    # 那是算术本身的性质。它能测的是**余量**:桨自己的噪声离门槛还有多远。从末尾往回走、
    # 只要规则不给力就继续,就找到了桨放下那一段(不需要别人告诉我),而那里的最大 -gx 就是
    # 要盯的数。一旦它逼近门槛,这个门槛对这条船就太低了。
    i = len(ps) - 1
    while i >= 0 and ps[i] == 0.0:
        i -= 1
    quiet_n = len(ps) - 1 - i
    print()
    if quiet_n:
        q_start = take.ts[i + 1]
        q_gx = take.gxs[i + 1:]
        q_ts = take.ts[i + 1:]
        # Split the quiet stretch in two, because one number for all of it lies.
        # Its first second still carries the tail of the last stroke -- the oar is
        # genuinely still moving aft as it comes out of the water, so a large -gx
        # there is correct behaviour, not a false positive. The margin that matters
        # is the one measured once the oar has actually settled.
        # 把静置段分成两截,因为只给一个数会说谎。它的第一秒还拖着上一桨的尾巴 —— 桨出水时
        # 确实还在向后走,所以那里 -gx 大是**正确行为**,不是假阳性。真正要紧的余量是在桨
        # 彻底停下之后量的那个。
        settle_from = max(q_start, take.last_t - 3.0)
        settle = [-g for t, g in zip(q_ts, q_gx) if t >= settle_from]
        settle_gx = max(settle) if settle else 0.0
        print("  trailing quiet: %.1f s, %d samples (t >= %.1f)"
              % (take.last_t - q_start, quiet_n, q_start))
        print("    still settling, first 1.0 s:  largest -gx %.1f deg/s"
              % max([-g for t, g in zip(q_ts, q_gx) if t < q_start + 1.0] or [0.0]))
        print("    settled, last 3.0 s:         largest -gx %.1f deg/s   "
              "-> x%.1f headroom on a %.0f deadband"
              % (settle_gx, dead / settle_gx if settle_gx > 0 else float("inf"),
                 dead))
        print("    a lower deadband is what would eat that margin")
    else:
        print("  trailing quiet: none -- the oar was still being swept at the end")

    # --- strokes, and the rowing window they define
    # --- 桨,以及它们定义的划水窗口
    runs = find_strokes(take.ts, ps, take.gxs, dead)
    print("  strokes (a run of -gx > %.0f deg/s, ending after %.2f s of quiet): %d"
          % (dead, STROKE_GAP, len(runs)))
    if runs:
        print("      #    start     dur   peak p    peak gx")
        for n, (a, b, pp, pg) in enumerate(runs[:STROKE_ROWS_MAX], 1):
            print("   %4d  %6.2fs  %5.2fs    %.3f   %+8.1f" % (n, a, b - a, pp, pg))
        if len(runs) > STROKE_ROWS_MAX:
            print("   ... and %d more" % (len(runs) - STROKE_ROWS_MAX))

    # The window from the first stroke to the last is the rowing window, found
    # rather than assumed -- the take's own rest and warm-up are excluded by
    # construction, so the mean power below is comparable between takes.
    # 第一次桨到最后一次桨之间就是划水窗口,是找出来的不是假定的 —— 实录自己的静置和准备
    # 段被构造性地排除了,所以下面这个平均功率在不同实录之间是可比的。
    if runs:
        t0, t1 = runs[0][0], runs[-1][1]
        win = [p for t, p in zip(take.ts, ps) if t0 <= t <= t1]
        mean_p = sum(win) / len(win)
        thrust = mean_p * MAX_THRUST
        duty = sum(1 for p in win if p > 0.0) / len(win)
        print()
        print("  rowing window %.1f-%.1f s (first stroke to last):" % (t0, t1))
        print("    mean power  %.3f   duty %.0f%%   (the oar drives only part of each cycle)"
              % (mean_p, 100.0 * duty))
        print("    mean thrust %.1f of %.0f   -> steady speed ~%.2f m/s"
              % (thrust, MAX_THRUST, steady_speed(thrust)))
        print("    stroke peaks %.2f .. %.2f  (how much of the effort reaches the boat)"
              % (min(r[2] for r in runs), max(r[2] for r in runs)))


# ---------------------------------------------------------------------- USB
def capture_serial(take: Take, port: str, baud: int, seconds: float,
                   live: float) -> None:
    fd = open_configured(port, baud)
    buf = b""
    t0 = time.monotonic()
    last_live = t0
    try:
        while True:
            if seconds and time.monotonic() - t0 >= seconds:
                break
            try:
                chunk = os.read(fd, 8192)
            except BlockingIOError:
                time.sleep(0.002)
                continue
            except OSError as exc:
                print("  port read failed: %s" % exc, file=sys.stderr)
                break
            if not chunk:
                time.sleep(0.002)
                continue

            buf += chunk
            # Everything up to the last newline is complete lines; the tail is a
            # partial line and stays in the buffer. A half line that happened to
            # parse would be counted as a real sample, which is the same trap
            # serial_probe.py documents.
            # 最后一个换行之前都是完整的行,尾巴是半行,留在缓冲区里。半行如果恰好能解析,
            # 会被当成真样本 —— 和 serial_probe.py 里写的是同一个陷阱。
            text = buf.decode("ascii", "replace")
            cut = text.rfind("\n")
            if cut < 0:
                continue
            buf = text[cut + 1:].encode("ascii", "replace")

            for line in text[:cut].split("\n"):
                line = line.strip()
                if not line:
                    continue
                take.add_line(line, time.monotonic() - t0)

            now = time.monotonic()
            if live and now - last_live >= live:
                last_live = now
                print_beat(now - t0, take)
    except KeyboardInterrupt:
        pass
    finally:
        os.close(fd)


# ---------------------------------------------------------------------- WiFi
def capture_udp(take: Take, oar: str, data_port: int, diag_port: int,
                seconds: float, live: float) -> None:
    data_sock = open_socket(data_port, "data")
    diag_sock = open_socket(diag_port, "diagnostics")
    stop = threading.Event()
    # One queue, tagged, drained by this thread only: the file and stdout are
    # then touched by one thread, which is what keeps a take's lines in order
    # and keeps a print from landing inside another print.
    # 一个队列、带标记、只由本线程取空:于是文件和 stdout 只有一个线程在碰,
    # 这既保证了实录里的行是有序的,也保证了一次 print 不会插进另一次 print 中间。
    q = queue.Queue()

    def reader(sock, kind):
        while not stop.is_set():
            try:
                packet = sock.recv(4096)
            except OSError:
                if stop.is_set():
                    return
                continue
            # Timestamped here, in the receiving thread, immediately after the
            # syscall returned -- not later, in the thread that writes the file.
            # 时间戳打在这里,在接收线程里,recv 一返回就打 —— 不是稍后在写文件的那个线程里。
            q.put((kind, time.monotonic(), packet.decode("ascii", "replace").strip()))

    threads = [
        threading.Thread(target=reader, args=(data_sock, "data"), daemon=True),
        threading.Thread(target=reader, args=(diag_sock, "diag"), daemon=True),
    ]
    for thread in threads:
        thread.start()

    on_subnet = check_network(oar, data_port)
    if on_subnet:
        print("Sending a hello to %s so the board unicasts (unicast is ACKed and"
              % oar)
        print("retransmitted; the broadcast fallback is not).")
        send_hello(data_sock, oar, data_port, announce=True)

    started = time.monotonic()
    last_hello = started
    last_hint = started
    last_live = started
    hinted = False
    nothing = "  ... still nothing (%.0f s).\n"

    def dispatch(item) -> None:
        kind, arrival, text = item
        t = arrival - started
        if not text:
            return
        if kind == "diag":
            take.add_line(text, t)
            if take.diag_echoed < DIAG_ECHO_MAX:
                take.diag_echoed += 1
                print("  !! firmware: %s" % text)
            elif take.diag_echoed == DIAG_ECHO_MAX:
                take.diag_echoed += 1
                print("  !! (more firmware lines -- the file has them all)")
            return
        take.add_line(text, t)

    try:
        while True:
            try:
                first = q.get(timeout=0.25)
            except queue.Empty:
                first = None
            if first is not None:
                dispatch(first)
                while True:
                    try:
                        dispatch(q.get_nowait())
                    except queue.Empty:
                        break

            now = time.monotonic()
            if live and now - last_live >= live:
                last_live = now
                print_beat(now - started, take)
            if now - last_hello >= HELLO_INTERVAL_SEC:
                last_hello = now
                send_hello(data_sock, oar, data_port)
            if take.samples == 0 and now - last_hint >= 10.0:
                last_hint = now
                if not hinted:
                    hinted = True
                    print(HINTS)
                else:
                    sys.stdout.write(nothing % (now - started))
                    sys.stdout.flush()
            if seconds and now - started >= seconds:
                break
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        data_sock.close()
        diag_sock.close()
        for thread in threads:
            thread.join(timeout=1.0)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--label", default="other", choices=LABELS,
                    help="what this take contains (default: other)")
    ap.add_argument("-s", "--seconds", type=float, default=0.0,
                    help="stop after N seconds (default: run until Ctrl-C)")
    ap.add_argument("-o", "--out", default="", help="output file (default: recordings/<label>-<stamp>.txt)")
    ap.add_argument("--no-save", action="store_true", help="print only, write no file")
    # One line per sample is the thing that made this script unusable: nobody can
    # read 100 lines a second, it buries the summary, it keeps scrolling after the
    # oar has been put down, and its volume grows with the length of the take --
    # so the terminal has to keep up forever or the script never returns. The
    # status line is now on a timer, which makes the output bounded by the length
    # of the take in seconds rather than in samples. Every sample still reaches
    # the file.
    # 一行一样本正是让这个脚本没法用的原因:每秒 100 行没人读得了,它把摘要埋掉,桨放下之后
    # 还在滚,而且它的量随实录长度增长 —— 于是终端必须永远跟得上,否则脚本永不返回。现在状态
    # 行是按时间打的,输出量就只和实录有多少**秒**有关,和有多少样本无关。每个样本仍进文件。
    ap.add_argument("--live", type=float, default=2.0, metavar="SEC",
                    help="one status line every SEC seconds; 0 for none "
                         "(default 2; the file always gets every sample)")
    ap.add_argument("--udp", action="store_true",
                    help="record over the board's own access point instead of USB")
    ap.add_argument("--oar", default=OAR_ADDRESS,
                    help="the board's address over the radio (default %s)" % OAR_ADDRESS)
    ap.add_argument("--port", type=int, default=4210, help="UDP data port (default 4210)")
    ap.add_argument("--diag-port", type=int, default=4211,
                    help="UDP diagnostics port (default 4211)")
    ap.add_argument("-p", "--serial-port", default="",
                    help="serial port (default: auto-detect)")
    ap.add_argument("-b", "--baud", type=int, default=DEFAULT_BAUD)
    ap.add_argument("--read", default="", metavar="FILE",
                    help="score a recording that was already saved, instead of "
                         "recording a new one")
    ap.add_argument("--forward", action="store_true",
                    help="with --read: score the take against the forward-only "
                         "rule the controller now runs, instead of the old gate "
                         "summary")
    ap.add_argument("--dead", type=float, default=SWEEP_DEADBAND, metavar="DEG_S",
                    help="sweep deadband, deg/s (default %.0f)" % SWEEP_DEADBAND)
    ap.add_argument("--full", type=float, default=SWEEP_FULL, metavar="DEG_S",
                    help="sweep value that saturates, deg/s (default %.0f)"
                         % SWEEP_FULL)
    args = ap.parse_args()

    if args.read:
        take = load_take(args.read)
        print("read %s" % args.read)
        if args.forward:
            score_forward(take, args.dead, args.full)
        else:
            take.report()
        return 0 if take.samples else 1

    port = ""
    if args.udp:
        source = "udp %s:%d" % (args.oar, args.port)
    else:
        port = args.serial_port or find_port()
        if not port:
            print("no serial port found. The oar is normally untethered -- over the",
                  file=sys.stderr)
            print("radio it has no cable and so no port: add --udp, and join",
                  file=sys.stderr)
            print("\"oar-sensor\" from the WiFi menu first.", file=sys.stderr)
            return 1
        if not os.path.exists(port):
            print("no such port: %s" % port, file=sys.stderr)
            return 1
        source = port

    out = ""
    if not args.no_save:
        out = args.out or os.path.join(REC_DIR, "%s-%s.txt" % (args.label, stamp()))

    live = max(0.0, args.live)
    print("recording from %s, label=%s" % (source, args.label))
    if out:
        print("  -> %s" % out)
    # Always state when the run ends. The recorder stops on its own clock, not
    # when the oar stops moving, so without this line a 10 s take that follows a
    # 3 s swing looks like a script that refuses to stop.
    # 永远说清楚这一轮什么时候结束。录制器是按自己的钟停的,不是桨停了就停,所以少了这一行,
    # 跟着 3 秒划桨后面那 10 秒的录制看起来就像一个死活不肯停的脚本。
    if args.seconds:
        print("  stops by itself after %.0f s (Ctrl-C stops it sooner)"
              % args.seconds)
    else:
        print("  (Ctrl-C to stop)")
    if live:
        print("  one status line every %.0f s; the file gets every sample" % live)
    print()

    take = Take(out, args.label, source)
    if args.udp:
        capture_udp(take, args.oar, args.port, args.diag_port, args.seconds, live)
    else:
        capture_serial(take, port, args.baud, args.seconds, live)
    take.close()
    take.report()
    return 0 if take.samples else 1


if __name__ == "__main__":
    raise SystemExit(main())
