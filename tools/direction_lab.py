#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""direction_lab.py -- score oar direction rules offline, against real rowing.

把「划桨方向判得对不对」从一个手感问题变成一个可回放、可打分、可对比的数字。

WHY THIS EXISTS / 为什么要它
--------------------------------------------------------------------------
oar_controller.gd decides forward vs astern entirely from the sign of the Z-axis
sweep rate. That statistic cannot separate a backstroke's return from a forward
stroke's drive -- the file itself says so -- so every threshold in it has been
tuned by hand, and every hand-tuned threshold has been argued about instead of
measured. This tool is the measuring instrument that was missing.

oar_controller.gd 完全靠 Z 轴扫速的符号决定前进还是后退。这个统计量分不开「后划的
回程」和「前划的动力段」—— 文件自己就是这么写的 —— 所以里面每一个门槛都是手工调的,
而每一个手工调的门槛都是在被争论,而不是在被测量。这个工具就是那个一直缺着的量具。

HOW IT WORKS / 它怎么工作
--------------------------------------------------------------------------
`verify` replays the SHIPPED signal chain over a recording and compares itself to
the controller's own per-frame output, which Scripts/stroke_recorder.gd wrote
into the F lines. It must match frame for frame. That check is the foundation of
everything else here: without it, a re-implementation that misreads one constant
reproduces its own mistake and then scores itself green.

`verify` 会对着录像回放出货版的信号链,并逐帧比对控制器自己的输出 —— 也就是
Scripts/stroke_recorder.gd 写进 F 行的那份。必须一帧不差。这道检查是这里其他一切的
地基:没有它,一个读错了某个常数的重写会连自己的错误一起复现,然后给自己打满分。

`score` then runs candidate rules over the same recording and reports, per
labelled segment, the net forward/astern impulse and whether its sign matches
what the player said they were doing.

`score` 再把候选规则跑一遍同一份录像,按标签分段报出「净前向/后退冲量」以及它的符号
是否与玩家声明的意图一致。

WHAT IT CANNOT DO / 它做不到什么
--------------------------------------------------------------------------
It cannot tell you a rule is RIGHT. It can only tell you a rule is better or
worse than another rule on the rowing it has seen, and it can be fooled by a
rule that wins by paying less thrust. Read the honesty section of the report.
It also cannot test the |a| hypothesis on synthetic data: no amount of time-
scaling changes |a|, so only real recordings with real water load can do that.

它不能告诉你某个规则是「对的」。它只能告诉你,在它见过的划桨上,某个规则比另一个
更好或更差;而且它会被「靠少给力取胜」的规则骗到。报告里有一段专门讲这个。它也无法
用合成数据检验 |a| 假设:任何时间缩放都不改变 |a|,只有带真实水阻的真实录像能做到。

USAGE / 用法
--------------------------------------------------------------------------
    python3 tools/direction_lab.py selftest
        No data needed. Checks the constant mirror, the invariants the model
        promises, and the parser round trip. Run this first.
        不需要数据。检查常数镜像、模型承诺的不变量、以及解析器往返。先跑这个。

    python3 tools/direction_lab.py verify recordings/*.txt
        The golden trace. Must pass before any score below means anything.
        golden trace。在它通过之前,下面任何一个评分都没有意义。

    python3 tools/direction_lab.py peaks recordings/*.txt
        Where the two populations actually sit: |a|/g and sweep rate, per label,
        as distributions rather than extremes. This is the falsification view.
        两个总体究竟落在哪里:|a|/g 和扫速,按标签,给分布而不是极值。
        这是用来「证伪」的那一屏。

    python3 tools/direction_lab.py score recordings/*.txt --rule R0,R2,R3
        Score the candidate rules. Add --r2-sweep 1.0:2.0:0.1 to sweep the
        quasi-static gate, and --loo to score it leave-one-recording-out.
        给候选规则打分。加 --r2-sweep 1.0:2.0:0.1 扫准静态门槛,加 --loo
        做「留一次录像」的交叉验证。

LANGUAGE / 语言
--------------------------------------------------------------------------
Module docstring, section banners and all printed output are bilingual because
the player reads them. Dense inline rationale is English only -- doubling a
600-line tool's prose would bury the code it explains.
模块说明、分节标题、以及所有打印输出都是中英对照,因为读它们的是玩家。密集的段落内
推理只用英文 —— 把一份 600 行工具的散文全部翻倍,只会把它解释的代码埋掉。
"""

from __future__ import annotations

import argparse
import math
import os
import re
import sys
from dataclasses import dataclass, field
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

# ---------------------------------------------------------------------------
# 1. THE CONSTANT MIRROR / 常数镜像
# ---------------------------------------------------------------------------
# This section is a hand-copy of the tunables in Scripts/oar_controller.gd. It
# is a copy on purpose: the replay has to be able to run constants the shipped
# file does not currently have (a swept |a| gate, a latched direction), so it
# cannot simply import them. The cost of a copy is that it can drift, and a
# drifted mirror makes every check below lie. `check_mirror` pays that cost back
# by reading the real file and comparing, and `selftest` fails loudly if they
# ever part.
# 这一节是 Scripts/oar_controller.gd 里那些旋钮的手抄本。刻意抄一份:回放必须能跑
# 出货文件里现在还没有的常数(被扫的 |a| 门槛、被锁定的方向),所以没法直接 import。
# 抄本的代价是它会漂移,而漂移了的镜像会让下面每一道检查都在说谎。check_mirror 通过
# 读真实文件做比对把这份代价还回去,selftest 在两者一旦分家时会大声失败。

G = 9.80665  # m/s^2 per g. The chip reads ~9.8 at rest (see why-normalise.txt).

FILTER_TAU = 0.025
RATE_TAU = 0.04
FULL_DRIVE_RATE = 26.0
DRIVE_DEADBAND = 1.5
MIN_VERTICAL = 0.15
SWEEP_NEED_MIN = 0.0
SWEEP_NEED_MAX = 200.0
SWEEP_NEED_AFT_RESET = 40.0
SWEEP_NEED_FWD_RESET = 55.0
LATERAL_DEADBAND = 1.5
LATERAL_GAIN = 0.055
LATERAL_FWD_SHARE = 0.6
OARLOCK_OFFSET = 0.6
SIDE_HYSTERESIS = 0.20
STROKE_ON = 0.28
STROKE_OFF = 0.12
STROKE_COOLDOWN = 0.1

MIRROR = {
    "FILTER_TAU": FILTER_TAU,
    "RATE_TAU": RATE_TAU,
    "FULL_DRIVE_RATE": FULL_DRIVE_RATE,
    "DRIVE_DEADBAND": DRIVE_DEADBAND,
    "MIN_VERTICAL": MIN_VERTICAL,
    "SWEEP_NEED_MIN": SWEEP_NEED_MIN,
    "SWEEP_NEED_MAX": SWEEP_NEED_MAX,
    "SWEEP_NEED_AFT_RESET": SWEEP_NEED_AFT_RESET,
    "SWEEP_NEED_FWD_RESET": SWEEP_NEED_FWD_RESET,
    "LATERAL_DEADBAND": LATERAL_DEADBAND,
    "LATERAL_GAIN": LATERAL_GAIN,
    "LATERAL_FWD_SHARE": LATERAL_FWD_SHARE,
    "OARLOCK_OFFSET": OARLOCK_OFFSET,
    "SIDE_HYSTERESIS": SIDE_HYSTERESIS,
    "STROKE_ON": STROKE_ON,
    "STROKE_OFF": STROKE_OFF,
    "STROKE_COOLDOWN": STROKE_COOLDOWN,
}

CONTROLLER_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Scripts", "oar_controller.gd")

_CONST_RE = re.compile(r"^const\s+([A-Z_][A-Z0-9_]*)\s*:=\s*([-0-9.]+)\s*$")


def read_gdscript_constants(path: str = CONTROLLER_PATH) -> Dict[str, float]:
    """Pull `const NAME := 1.23` out of the shipped controller."""
    out: Dict[str, float] = {}
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            m = _CONST_RE.match(line.rstrip("\n"))
            if m:
                try:
                    out[m.group(1)] = float(m.group(2))
                except ValueError:
                    pass
    return out


def check_mirror(path: str = CONTROLLER_PATH) -> List[str]:
    """Return a list of complaints; empty means the mirror is faithful."""
    bad: List[str] = []
    live = read_gdscript_constants(path)
    if not live:
        return ["could not read any constants from %s" % path]
    for name, mine in sorted(MIRROR.items()):
        if name not in live:
            bad.append("%s: gone from the .gd file (mirror still has %r)" % (name, mine))
        elif abs(live[name] - mine) > 1e-9:
            bad.append("%s: mirror says %r, the .gd file says %r"
                       % (name, mine, live[name]))
    return bad


# ---------------------------------------------------------------------------
# 2. THE SMALL MATHS THE .gd FILE USES / .gd 文件用的那几个小函数
# ---------------------------------------------------------------------------
# Godot's lerp/clampf/signf, re-stated so the replay reads like the file it is
# replaying. Getting lerp's argument order or signf(0) wrong here would be
# invisible except as a golden-trace mismatch, which is the point of the check.

def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def clampf(v: float, lo: float, hi: float) -> float:
    return lo if v < lo else (hi if v > hi else v)


def signf(v: float) -> float:
    if v > 0.0:
        return 1.0
    if v < 0.0:
        return -1.0
    return 0.0


def alpha_for(delta: float, tau: float) -> float:
    """1 - exp(-delta/tau), the same one-pole coefficient the .gd file builds.

    Precomputed per (delta, tau) because the chain runs it tens of thousands of
    times and exp() is the only expensive thing in the loop.
    """
    if delta <= 0.0 or tau <= 0.0:
        return 1.0
    return 1.0 - math.exp(-delta / tau)


# ---------------------------------------------------------------------------
# 3. THE RECORDING / 录像文件
# ---------------------------------------------------------------------------
# Three line kinds, all on one clock. See Scripts/stroke_recorder.gd for what
# writes them and why the F line carries its own inputs.
#
#   S <t> <x> <y> <z>
#   L <t> <forward|backstroke|other|none>
#   F <t> <d> <st> <sx> <sy> <sz> <sweep> <bar_aft> <bar_fwd> \
#     <fwd> <back> <cool> <push> <verdict...>

# The verdict is the string "-> FORWARD" / "-> ASTERN" / "-> ---", so it is up
# to three whitespace-separated tokens: split off the 13 numbers and keep the
# rest whole rather than assuming a width.
F_FIELDS = 13

LABEL_INTENT = {"forward": +1, "backstroke": -1}


@dataclass
class Frame:
    t: float
    d: float
    st: int
    sx: float
    sy: float
    sz: float
    sweep: float
    bar_aft: float
    bar_fwd: float
    fwd: float
    back: float
    cool: float
    push: float
    verdict: str
    index: int = 0


@dataclass
class Take:
    path: str
    samples: List[Tuple[float, float, float, float]] = field(default_factory=list)
    labels: List[Tuple[float, str]] = field(default_factory=list)
    frames: List[Frame] = field(default_factory=list)
    warnings: List[str] = field(default_factory=list)

    @property
    def name(self) -> str:
        return os.path.basename(self.path)

    def label_at(self, t: float) -> str:
        """The label in force at time t: the last L line at or before it."""
        cur = "none"
        for lt, name in self.labels:
            if lt <= t:
                cur = name
            else:
                break
        return cur

    def label_for_frame(self, f: Frame) -> str:
        return self.label_at(f.t)


def parse_recording(path: str) -> Take:
    take = Take(path=path)
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            kind = line[0]
            if kind == "S":
                parts = line.split()
                if len(parts) != 5:
                    take.warnings.append("%s:%d bad S line" % (path, lineno))
                    continue
                try:
                    take.samples.append((float(parts[1]), float(parts[2]),
                                         float(parts[3]), float(parts[4])))
                except ValueError:
                    take.warnings.append("%s:%d unparsable S line" % (path, lineno))
            elif kind == "L":
                parts = line.split()
                if len(parts) < 3:
                    take.warnings.append("%s:%d bad L line" % (path, lineno))
                    continue
                take.labels.append((float(parts[1]), parts[2]))
            elif kind == "F":
                # maxsplit keeps the three-token verdict together.
                parts = line.split(None, F_FIELDS + 1)
                if len(parts) < F_FIELDS + 2:
                    take.warnings.append("%s:%d bad F line" % (path, lineno))
                    continue
                nums = parts[1:F_FIELDS + 1]
                try:
                    vals = [float(v) for v in nums[:2]] + [int(nums[2])] \
                        + [float(v) for v in nums[3:]]
                except ValueError:
                    take.warnings.append("%s:%d unparsable F line" % (path, lineno))
                    continue
                take.frames.append(Frame(
                    t=vals[0], d=vals[1], st=vals[2],
                    sx=vals[3], sy=vals[4], sz=vals[5],
                    sweep=vals[6], bar_aft=vals[7], bar_fwd=vals[8],
                    fwd=vals[9], back=vals[10], cool=vals[11],
                    push=vals[12], verdict=parts[F_FIELDS + 1].strip(),
                    index=len(take.frames)))
            else:
                take.warnings.append("%s:%d unknown line kind %r" % (path, lineno, kind))
    return take


# ---------------------------------------------------------------------------
# 4. THE SHIPPED CHAIN / 出货版信号链
# ---------------------------------------------------------------------------
# A transcription of oar_controller.gd update() (lines ~1161-1330). Every branch
# here corresponds to a branch there, in the same order, because the golden trace
# compares them frame for frame and any structural difference shows up as a
# numeric mismatch rather than a silent divergence.
#
# update() has THREE exits and they are not equivalent, which is why the F line
# records which one fired (`st`):
#
#   st 0  no port       -- returned before the low-pass filter ran, so the filter
#                          state is untouched this frame
#   st 1  |a| < 1 g     -- filter ran, differencing did not, so _prev_y/_prev_z
#                          are untouched
#   st 2  full run
#
# All three pay nothing, so a replay that conflated them would still get the
# powers right and would still be wrong: it would carry a different filter state
# into the frames that follow.

def gate_and_law(sweep: float, vert: float,
                 bar_aft: float, bar_fwd: float) -> Tuple[float, float]:
    """Sections 5 and 6 of update(), as a pure function.

    Factored out so the model invariants can be swept over it directly without
    standing up a whole chain. The two gates read different bars and neither
    reads the other's -- that separation is the whole point of the split.

    A sweep aft past the forward bar drives the boat forward; a sweep toward the
    bow past the backstroke bar drives it astern; anything slower is a recovery
    and pays nothing. Both powers are clamped at zero before the dead band is
    subtracted, and no single sweep value can be both `<= -bar_aft` and
    `>= +bar_fwd` for non-negative bars, so the two can never be positive
    together. (At bar_aft = bar_fwd = 0 and sweep = 0 both TESTS fire, and both
    forces then come out zero because the dead band is subtracted after the
    clamp -- which is why the invariant is stated about the forces and not the
    tests.)
    """
    aft_is_stroke = -sweep >= bar_aft
    fwd_is_stroke = sweep >= bar_fwd
    fwd = 0.0
    if aft_is_stroke:
        fwd = max(0.0, -sweep - DRIVE_DEADBAND) / FULL_DRIVE_RATE * vert
    back = 0.0
    if fwd_is_stroke:
        back = max(0.0, sweep - DRIVE_DEADBAND) / FULL_DRIVE_RATE * vert
    return fwd, back


def verdict_text(sweep: float, bar_aft: float, bar_fwd: float) -> str:
    if sweep <= -bar_aft:
        return "-> FORWARD"
    if sweep >= bar_fwd:
        return "-> ASTERN"
    return "-> ---"


class State:
    """The controller's persistent members, all of them, in one place."""

    __slots__ = ("fx", "fy", "fz", "w_lat", "w_fa", "prev_y", "prev_z", "primed",
                 "in_stroke", "peak", "stroke_side", "side",
                 "sensor_ready", "s_vert", "s_left", "s_back",
                 "stroke_cool", "stroke_count",
                 "r1_prev_sback", "r1_w_fa", "r1_primed",
                 "r5_prev_mag", "r5_until", "r3_latch")

    def __init__(self) -> None:
        self.fx = self.fy = self.fz = 0.0
        self.w_lat = self.w_fa = 0.0
        self.prev_y = self.prev_z = 0.0
        self.primed = False
        self.in_stroke = False
        self.peak = 0.0
        self.stroke_side = 0.0
        self.side = 0.0
        self.sensor_ready = False
        self.s_vert = 1.0
        self.s_left = self.s_back = 0.0
        self.stroke_cool = 0.0
        self.stroke_count = 0
        # rule-specific state
        self.r1_prev_sback = 0.0
        self.r1_w_fa = 0.0
        self.r1_primed = False
        self.r5_prev_mag = 0.0
        self.r5_until = -1.0
        self.r3_latch = 0.0


@dataclass
class Out:
    """One frame of the replay's output, in the same shape as an F line."""
    sweep: float
    fwd: float
    back: float
    cool: float
    push: float
    mag: float          # filtered |a|, m/s^2
    vert: float         # max(|s_vert|, MIN_VERTICAL) -- the drive's upright factor
    side: float


class Rule:
    """A candidate direction rule: the shipped chain plus three hooks.

    `sweep_of`       how the sweep rate is derived (R0/R2/R3 read the raw axis;
                     R1 reads the |a|-normalised one)
    `loaded`         an extra per-frame veto on top of the gate (R2's
                     quasi-static test, R5's phase window)
    `post`           a post-process on the two powers (R3's direction latch)

    Keeping the hooks narrow means every rule runs through the SAME chain, so a
    difference in score is a difference in the rule and not a difference in two
    separately written replays.
    """
    name = "R0"
    blurb = "shipped"

    def sweep_of(self, st: State, f: Frame, delta: float, mag: float) -> float:
        return -st.w_fa

    def loaded(self, st: State, o: Out, f: Frame, t: float) -> bool:
        return True

    def post(self, st: State, f: Frame, o: Out) -> Tuple[float, float]:
        return o.fwd, o.back


class R0(Rule):
    name = "R0"
    blurb = "shipped: raw dZ/dt sign vs two bars"


class R1(Rule):
    name = "R1"
    blurb = "|a|-normalised d(z/|a|)/dt sign vs two bars"

    def sweep_of(self, st: State, f: Frame, delta: float, mag: float) -> float:
        # d/dt of the normalised Z pose, then the same EMA the shipped chain
        # applies to the raw rate. Section 3 of why-normalise.txt shows the
        # division removes about a fifth of the raw rate at the gate's own
        # operating points.
        sback = st.fz / mag if mag > 0.0 else 0.0
        raw = (sback - st.r1_prev_sback) / delta if delta > 0.0 else 0.0
        st.r1_prev_sback = sback
        if not st.r1_primed:
            st.r1_primed = True
            raw = 0.0
        st.r1_w_fa = lerp(st.r1_w_fa, raw, alpha_for(delta, RATE_TAU))
        return -st.r1_w_fa


class R2(Rule):
    name = "R2"
    blurb = "shipped gate AND quasi-static |a|/g < T"
    default_t = 1.3

    def __init__(self, threshold: float = None) -> None:
        self.t = R2.default_t if threshold is None else threshold

    def loaded(self, st: State, o: Out, f: Frame, t: float) -> bool:
        return (o.mag / G) < self.t


class R3(Rule):
    name = "R3"
    blurb = "shipped gate, but one stroke latches one direction"

    def post(self, st: State, f: Frame, o: Out) -> Tuple[float, float]:
        # A stroke opens on push crossing STROKE_ON and closes below STROKE_OFF.
        # While it is open, only the direction it opened in may be paid. The
        # latch is set from the frame that OPENED the stroke, which is the frame
        # whose power first cleared the ON level.
        if not st.in_stroke:
            st.r3_latch = 0.0
        raw_fwd, raw_back = o.fwd, o.back
        if not st.in_stroke and max(raw_fwd, raw_back) > STROKE_ON:
            st.r3_latch = 1.0 if raw_fwd >= raw_back else -1.0
        if st.r3_latch > 0.0:
            raw_back = 0.0
        elif st.r3_latch < 0.0:
            raw_fwd = 0.0
        return raw_fwd, raw_back


class R5(Rule):
    name = "R5"
    blurb = "shipped gate AND a window after a |a| transient"
    default_window = 0.35
    default_jerk = 30.0

    def __init__(self, window: float = None, jerk: float = None) -> None:
        self.window = R5.default_window if window is None else window
        self.jerk = R5.default_jerk if jerk is None else jerk

    def loaded(self, st: State, o: Out, f: Frame, t: float) -> bool:
        # The catch and the release are impacts: |a| moves faster than water load
        # or a free swing can. A window opened by one of those transients is the
        # phase marker; payment is confined to it. This is the weakest of the
        # candidates and is here mainly so it can be shown to lose.
        if f.d > 0.0:
            jerk = abs(o.mag - st.r5_prev_mag) / f.d
            if jerk > self.jerk:
                st.r5_until = t + self.window
        st.r5_prev_mag = o.mag
        return t <= st.r5_until


class R2R3(R2):
    name = "R2+R3"
    blurb = "quasi-static gate AND direction latch"

    def post(self, st: State, f: Frame, o: Out) -> Tuple[float, float]:
        return R3.post(self, st, f, o)


def run_chain(take: Take, rule: Rule) -> List[Out]:
    """Replay `rule` over `take`'s frames, driven by the logged inputs.

    The inputs come from the F lines (sx, sy, sz, delta), not from the S lines.
    That is deliberate and it is the only way this check is worth anything: a
    reconstruction from S-line timestamps is wrong by one sample whenever a
    sample lands between the controller reading the sensor and the recorder
    writing the line, and one sample is the size of the effect being measured.
    The S lines are kept for the opposite purpose -- testing designs that do not
    sample the stream the way the shipped controller does.
    """
    st = State()
    out: List[Out] = []
    for f in take.frames:
        delta = f.d
        o = Out(sweep=0.0, fwd=0.0, back=0.0, cool=st.stroke_cool,
                push=0.0, mag=0.0, vert=1.0, side=st.side)

        if f.st == 0:
            # update() returned before the filter ran. Powers zeroed; the
            # cooldown, the stroke bookkeeping and push_power are NOT touched.
            st.sensor_ready = False
            o.sweep = 0.0
            o.fwd = o.back = 0.0
            o.cool = st.stroke_cool
            o.push = out[-1].push if out else 0.0
            o.mag = 0.0
            out.append(o)
            continue

        a = alpha_for(delta, FILTER_TAU)
        st.fx = lerp(st.fx, f.sx, a)
        st.fy = lerp(st.fy, f.sy, a)
        st.fz = lerp(st.fz, f.sz, a)
        mag = math.sqrt(st.fx * st.fx + st.fy * st.fy + st.fz * st.fz)
        o.mag = mag

        if f.st == 1:
            # Filter ran; the differencing and everything after it did not.
            st.sensor_ready = False
            o.sweep = 0.0
            o.fwd = o.back = 0.0
            o.cool = st.stroke_cool
            o.push = out[-1].push if out else 0.0
            out.append(o)
            continue

        st.sensor_ready = True

        # --- section 2: pose decomposition ---------------------------------
        st.s_vert = clampf(-st.fx / mag, -1.0, 1.0)
        st.s_left = clampf(-st.fy / mag, -1.0, 1.0)
        st.s_back = clampf(st.fz / mag, -1.0, 1.0)
        if abs(st.s_left) > SIDE_HYSTERESIS:
            st.side = signf(st.s_left)
        o.side = st.side

        # --- section 3: rates ------------------------------------------------
        raw_w_lat = (st.fy - st.prev_y) / delta
        raw_w_fa = (st.fz - st.prev_z) / delta
        st.prev_y = st.fy
        st.prev_z = st.fz
        if not st.primed:
            st.primed = True
            raw_w_lat = 0.0
            raw_w_fa = 0.0
        b = alpha_for(delta, RATE_TAU)
        st.w_lat = lerp(st.w_lat, raw_w_lat, b)
        st.w_fa = lerp(st.w_fa, raw_w_fa, b)

        # --- section 4: the sweep, however this rule derives it ---------------
        sweep = rule.sweep_of(st, f, delta, mag)
        o.sweep = sweep
        vert = max(abs(st.s_vert), MIN_VERTICAL)
        o.vert = vert

        # --- sections 5 and 6: gate and force --------------------------------
        fwd, back = gate_and_law(sweep, vert, f.bar_aft, f.bar_fwd)

        # --- the rule's own veto --------------------------------------------
        # Applied to the powers rather than inside the gate, so the shipped
        # gate stays exactly two comparisons and a new rule is visibly an extra
        # condition on top of it rather than a rewrite of it.
        if not rule.loaded(st, o, f, f.t):
            fwd = 0.0
            back = 0.0

        # --- section 6b: lateral --------------------------------------------
        lat_rate = -st.w_lat
        if abs(lat_rate) < LATERAL_DEADBAND:
            lat_rate = 0.0
        else:
            lat_rate -= signf(lat_rate) * LATERAL_DEADBAND
        total_rate = abs(st.w_fa) + abs(lat_rate)
        fwd_share = abs(st.w_fa) / total_rate if total_rate > 0.0 else 0.0
        side_power = lat_rate * LATERAL_GAIN * clampf(
            fwd_share / LATERAL_FWD_SHARE, 0.0, 1.0)

        # --- the rule's post-process (direction latch) ------------------------
        # Hand the chain's pair to the rule first, so a post-processor reads what
        # the gate decided rather than whatever happened to be on `o` before.
        o.fwd, o.back = fwd, back
        fwd, back = rule.post(st, f, o)

        # --- section 7: the silence after a stroke ---------------------------
        # The cooldown ticks down BEFORE it is tested, exactly as in the file,
        # and it mutes the powers but not the sweep.
        if st.stroke_cool > 0.0:
            st.stroke_cool = max(0.0, st.stroke_cool - delta)
            fwd = 0.0
            back = 0.0
            side_power = 0.0

        o.fwd, o.back = fwd, back
        o.cool = st.stroke_cool

        # --- bookkeeping, read from what section 7 left ----------------------
        push = max(fwd, back)
        o.push = push
        if not st.in_stroke:
            if push > STROKE_ON:
                st.in_stroke = True
                st.peak = push
                st.stroke_side = st.side
        else:
            if push > st.peak:
                st.peak = push
            if push < STROKE_OFF:
                st.in_stroke = False
                st.stroke_count += 1
                st.stroke_cool = STROKE_COOLDOWN

        out.append(o)

    return out


# ---------------------------------------------------------------------------
# 5. THE GOLDEN TRACE / golden trace
# ---------------------------------------------------------------------------
# Compare the replay against the controller's own log. Any mismatch is fatal:
# nothing downstream is worth reading until this passes, because a replay that
# disagrees with the shipped rule is not measuring the shipped rule.

# The F lines carry %.6f on the outputs and %.9f on the inputs (see the write
# site in Scripts/stroke_recorder.gd for why those differ), so a faithful replay
# lands within about 1e-6 of the log. A tolerance of 1e-4 is far tighter than any
# real divergence -- a misread constant moves these by whole units -- and far
# looser than the formatting noise.
TOL = 1e-4

# How close to a bar a sweep has to be before a disagreement across that bar
# stops being evidence of anything. The gate is two hard comparisons, so a frame
# whose sweep sits exactly on a bar is decided by the last bit of a float, and
# two implementations that agree everywhere else can still fall on opposite
# sides of it. That is not a divergence, it is a tie, and calling it a failure
# would drown the check in false alarms on the very frames most worth watching.
# The band is relative because the rate error scales with the rate.
TIE_REL = 1e-3

_COMPARED = ("sweep", "fwd", "back", "cool", "push")
_GATED = ("fwd", "back", "push")


def _sits_on_a_bar(sweep: float, bar_aft: float, bar_fwd: float) -> bool:
    band = TIE_REL * max(1.0, abs(sweep))
    return (abs(-sweep - bar_aft) <= band) or (abs(sweep - bar_fwd) <= band)


def _cooldown_edges(take: Take) -> set:
    """Frame indices within one frame of the cooldown starting or ending.

    The shipped cooldown is armed at exactly STROKE_COOLDOWN and then counted
    down by subtracting delta once per frame, with `if stroke_cool > 0.0` as the
    test. Reaching zero that way is a floating-point accident: six subtractions
    of 1/60 from 0.1 do not necessarily land on exactly 0.0, and whether the
    sixth one leaves a residual of 1e-17 decides whether one MORE frame is
    muted. It is harmless in the game -- one frame of extra silence, 16 ms -- but
    it means the frame the silence ends on is not reproducible from the log,
    because the log records the countdown and not the residual that decided it.

    So the frames either side of every logged transition are marked, and a
    power disagreement there is a tie rather than a complaint.
    """
    edges = set()
    prev = None
    for i, f in enumerate(take.frames):
        if prev is not None:
            if (prev.cool > 0.0) != (f.cool > 0.0):
                edges.update((i - 1, i, i + 1))
        prev = f
    return edges


def verify_take(take: Take, max_report: int = 12) -> Tuple[int, List[str], List[str]]:
    """Return (frames_checked, complaints, ties).

    A complaint is a disagreement that means something. A tie is a frame sitting
    on one of the chain's hard comparisons -- the sweep against a bar, or the
    cooldown against zero -- where a disagreement means only that two float
    expressions rounded differently. Ties are unavoidable in any
    re-implementation, so they are reported separately rather than failing the
    trace; a large number of them, though, would mean the filter is hiding a
    real divergence, which is why selftest bounds their share.
    """
    out = run_chain(take, R0())
    problems: List[str] = []
    ties: List[str] = []
    if not take.frames:
        return 0, ["%s: no F lines -- was the recorder running?" % take.name], []
    edges = _cooldown_edges(take)
    for i, (o, f) in enumerate(zip(out, take.frames)):
        on_bar = _sits_on_a_bar(o.sweep, f.bar_aft, f.bar_fwd) or (i in edges)
        for name in _COMPARED:
            got = getattr(o, name)
            want = getattr(f, name)
            if abs(got - want) <= TOL + TOL * abs(want):
                continue
            message = ("%s frame %d (t=%.3f) %s: replay %.6f, controller %.6f"
                       % (take.name, f.index, f.t, name, got, want))
            if name in _GATED and on_bar:
                if len(ties) < max_report:
                    ties.append(message)
            elif len(problems) < max_report:
                problems.append(message)
        v = verdict_text(o.sweep, f.bar_aft, f.bar_fwd)
        if v != f.verdict:
            message = ("%s frame %d (t=%.3f) verdict: replay %r, controller %r"
                       % (take.name, f.index, f.t, v, f.verdict))
            if on_bar:
                if len(ties) < max_report:
                    ties.append(message)
            elif len(problems) < max_report:
                problems.append(message)
    # The stage field is a 1-bit function of the filter state, so agreeing with
    # it on every frame is independent evidence that the low-pass is in step --
    # stronger than the powers, which stay at zero through any disagreement in
    # a quiet stretch. Only meaningful where a filter exists at all.
    for i, f in enumerate(take.frames):
        if f.st == 1 and i > 0 and out[i].mag >= 1.0:
            if len(problems) < max_report:
                problems.append(
                    "%s frame %d: controller says |a| < 1 g, replay says %.3f"
                    % (take.name, i, out[i].mag))
    return len(out), problems, ties


# ---------------------------------------------------------------------------
# 6. SCORING / 打分
# ---------------------------------------------------------------------------
# The question a score has to answer is "when the player said they were rowing
# one way, did the boat get pushed that way?" -- so the primary metric is the
# net impulse over a labelled segment, in the units the player can feel.
#
# Two numbers are reported together, always, because either one alone can be
# gamed:
#
#   net      fwd_impulse - astern_impulse. Its SIGN against the declared intent
#            is the whole question.
#   cover    the fraction of labelled frames that were paid at all. A rule that
#            pays nothing has a net near zero and a cover near zero -- it did not
#            get the direction right, it stopped the boat.
#   purity   of the frames that WERE paid, the fraction paid the declared way.

@dataclass
class Segment:
    take: str
    label: str
    n: int
    paid: int
    fwd_imp: float
    back_imp: float
    wrong_frames: int

    @property
    def net(self) -> float:
        return self.fwd_imp - self.back_imp

    @property
    def cover(self) -> float:
        return self.paid / self.n if self.n else 0.0

    @property
    def purity(self) -> float:
        return (self.paid - self.wrong_frames) / self.paid if self.paid else float("nan")

    def correct(self) -> Optional[bool]:
        intent = LABEL_INTENT.get(self.label)
        if intent is None or self.n == 0:
            return None
        return (self.net * intent) > 0.0


def score_take(take: Take, out: Sequence[Out]) -> List[Segment]:
    """One Segment per contiguous run of frames sharing a label."""
    segs: List[Segment] = []
    cur: Optional[Segment] = None
    for o, f in zip(out, take.frames):
        lab = take.label_for_frame(f)
        if cur is None or cur.label != lab:
            if cur is not None:
                segs.append(cur)
            cur = Segment(take.name, lab, 0, 0, 0.0, 0.0, 0)
        intent = LABEL_INTENT.get(lab, 0)
        cur.n += 1
        cur.fwd_imp += o.fwd * f.d
        cur.back_imp += o.back * f.d
        if o.fwd > 0.0 or o.back > 0.0:
            cur.paid += 1
            if intent != 0:
                direction = 1 if o.fwd > o.back else -1
                if direction != intent:
                    cur.wrong_frames += 1
    if cur is not None:
        segs.append(cur)
    return segs


def oracle_take(take: Take, out: Sequence[Out]) -> List[Segment]:
    """The ceiling: pay every frame the label says to, with the same force law.

    Not a rule anyone can implement -- it reads the player's intent off the
    label. Its only job is to say how much room is left, so that a rule sitting
    just under it can stop being tuned.
    """
    segs: List[Segment] = []
    cur: Optional[Segment] = None
    for o, f in zip(out, take.frames):
        lab = take.label_for_frame(f)
        if cur is None or cur.label != lab:
            if cur is not None:
                segs.append(cur)
            cur = Segment(take.name, lab, 0, 0, 0.0, 0.0, 0)
        intent = LABEL_INTENT.get(lab, 0)
        cur.n += 1
        # The force the shipped law would have given, with no bar and only the
        # declared direction. Bounded by the same FULL_DRIVE_RATE, so it is the
        # same currency as every candidate's score.
        raw_fwd, raw_back = gate_and_law(o.sweep, o.vert, 0.0, 0.0)
        if intent > 0:
            cur.fwd_imp += raw_fwd * f.d
        elif intent < 0:
            cur.back_imp += raw_back * f.d
        if raw_fwd > 0.0 or raw_back > 0.0:
            cur.paid += 1
    if cur is not None:
        segs.append(cur)
    return segs


def summarise(segs: Sequence[Segment]) -> Dict[str, float]:
    """Roll segments up per intent, which is the number anyone actually asks for."""
    out = {"fwd_imp": 0.0, "back_imp": 0.0, "n": 0, "paid": 0, "wrong": 0,
           "takes": 0, "takes_right": 0}
    per_take: Dict[str, float] = {}
    for s in segs:
        i = LABEL_INTENT.get(s.label)
        if i is None:
            continue
        out["n"] += s.n
        out["paid"] += s.paid
        out["wrong"] += s.wrong_frames
        if i > 0:
            out["fwd_imp"] += s.fwd_imp
        else:
            out["back_imp"] += s.back_imp
            out["takes"] += 1
            per_take[s.take] = per_take.get(s.take, 0.0) + s.net
    out["takes_right"] = sum(1 for v in per_take.values() if v > 0.0)
    return out


def cross_correlation(a: Sequence[float], b: Sequence[float],
                      max_lag: int = 20) -> Tuple[int, float]:
    """Best lag and its correlation of series a against series b.

    The dishonest winner this is here to catch is a rule that is the shipped
    rule delayed by a few frames: it can score differently on a fixed window
    while doing the same thing, and a lagged match at |corr| near 1 says so.
    """
    n = min(len(a), len(b))
    if n == 0:
        return 0, 0.0
    best_lag, best = 0, -2.0
    for lag in range(-max_lag, max_lag + 1):
        xs, ys = [], []
        for i in range(n):
            j = i + lag
            if 0 <= j < n:
                xs.append(a[i])
                ys.append(b[j])
        if len(xs) < 8:
            continue
        mx = sum(xs) / len(xs)
        my = sum(ys) / len(ys)
        num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
        dx = math.sqrt(sum((x - mx) ** 2 for x in xs))
        dy = math.sqrt(sum((y - my) ** 2 for y in ys))
        if dx <= 0.0 or dy <= 0.0:
            continue
        c = num / (dx * dy)
        if c > best:
            best, best_lag = c, lag
    return best_lag, (best if best > -2.0 else 0.0)


# ---------------------------------------------------------------------------
# 7. PERCENTILES / 分位数
# ---------------------------------------------------------------------------

def percentile(sorted_vals: Sequence[float], p: float) -> float:
    """Linear-interpolated percentile of an already-sorted list."""
    if not sorted_vals:
        return float("nan")
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    k = (len(sorted_vals) - 1) * p
    lo = int(math.floor(k))
    hi = min(lo + 1, len(sorted_vals) - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)


def pcts(vals: Iterable[float], points: Sequence[float]) -> List[float]:
    s = sorted(vals)
    return [percentile(s, p) for p in points]


# ---------------------------------------------------------------------------
# 8. THE INVARIANTS / 不变量
# ---------------------------------------------------------------------------
# The claims the model makes about itself, checkable with no recording at all.
# Most are ported from reverse-gate-replay.txt section 2, which measured them on
# a harness that no longer exists; restating them here means a future rewrite has
# to keep them.

def check_invariants() -> List[str]:
    bad: List[str] = []

    bar_vals = [i * 2.5 for i in range(81)]          # 0 .. 200 in 81 steps
    sweeps = [(-150.0 + 0.25 * i) for i in range(1201)]  # -150 .. +150

    # i. the two forces can never be positive together, at any pair of bars
    for ba in bar_vals:
        for bf in bar_vals:
            for sw in sweeps:
                f, b = gate_and_law(sw, 1.0, ba, bf)
                if f > 0.0 and b > 0.0:
                    bad.append("both powers positive at sweep=%.2f bars=%.1f/%.1f"
                               % (sw, ba, bf))
                    return bad   # one counterexample is enough

    # ii. each direction is monotone in BOTH bars: raising a bar never buys more
    #     thrust in either direction. This is what makes the two knobs a cost
    #     rather than a trade.
    for sw in (-60.0, -40.0, -10.0, 10.0, 40.0, 60.0):
        for bf in bar_vals:
            prev = None
            for ba in bar_vals:
                f, b = gate_and_law(sw, 1.0, ba, bf)
                if prev is not None:
                    if f > prev[0] + 1e-12 or b > prev[1] + 1e-12:
                        bad.append("not monotone in the aft bar at sweep=%.1f" % sw)
                        break
                prev = (f, b)
        for ba in bar_vals:
            prev = None
            for bf in bar_vals:
                f, b = gate_and_law(sw, 1.0, ba, bf)
                if prev is not None:
                    if f > prev[0] + 1e-12 or b > prev[1] + 1e-12:
                        bad.append("not monotone in the fwd bar at sweep=%.1f" % sw)
                        break
                prev = (f, b)

    # iii. the range can shut the ASTERN channel outright but canNOT shut the
    #      forward one, and that asymmetry is a real limit of the design.
    #
    #      The fastest bow sweep any surviving measurement holds is 143.22
    #      (reverse-gate-replay.txt section 2: "the fastest recovery is 143.22,
    #      the bar can go to 200.0"), so a backstroke bar at the top of the
    #      range refuses every one of them. The fastest aft sweep on record is
    #      240.69 -- rev1's own return -- which is above 200.0, so NO setting of
    #      the forward bar refuses it. Asserting that here keeps it from being
    #      rediscovered later as a bug: it is a consequence of the raw-axis
    #      statistic having no upper bound, and it is one more reason the two
    #      channels are not symmetric.
    for sw in (46.021, 79.23, 143.222):
        _f, b = gate_and_law(sw, 1.0, SWEEP_NEED_MIN, SWEEP_NEED_MAX)
        if b > 0.0:
            bad.append("a bow sweep of %.3f still pays astern with the bar at "
                       "the top of the range" % sw)
    f, _b = gate_and_law(-240.69, 1.0, SWEEP_NEED_MAX, SWEEP_NEED_FWD_RESET)
    if f <= 0.0:
        bad.append("a bar at the top of the range refused a 240.69 aft sweep -- "
                   "the forward channel is shuttable after all, and this "
                   "invariant's note about the asymmetry is wrong")

    # iv. the shipped pair is inside the range, and it is a PAIR (unequal), which
    #     is the whole change the split bought.
    if not (SWEEP_NEED_MIN <= SWEEP_NEED_AFT_RESET <= SWEEP_NEED_MAX):
        bad.append("shipped aft bar outside the range")
    if not (SWEEP_NEED_MIN <= SWEEP_NEED_FWD_RESET <= SWEEP_NEED_MAX):
        bad.append("shipped fwd bar outside the range")
    if SWEEP_NEED_AFT_RESET == SWEEP_NEED_FWD_RESET:
        bad.append("the two shipped bars are equal -- the split has been undone")

    # v. the verdict text is the same two comparisons as the gate, not a
    #    re-derivation that could disagree with what the boat is paid.
    for sw in sweeps:
        ba, bf = SWEEP_NEED_AFT_RESET, SWEEP_NEED_FWD_RESET
        v = verdict_text(sw, ba, bf)
        f2, b2 = gate_and_law(sw, 1.0, ba, bf)
        if v == "-> ---" and (f2 > 0.0 or b2 > 0.0):
            bad.append("verdict says no stroke at sweep=%.2f but the gate paid" % sw)
        if v == "-> FORWARD" and f2 <= 0.0:
            bad.append("verdict says FORWARD at sweep=%.2f but nothing was paid" % sw)

    # vi. the cooldown mutes all four powers, and push_power still equals
    #     max(fwd, back) on every frame of a real chain -- checked on the
    #     synthetic take in selftest, since it needs a running chain.
    return bad


# ---------------------------------------------------------------------------
# 9. SYNTHETIC TAKE + SELF TEST / 合成录像与自检
# ---------------------------------------------------------------------------
# A synthetic stream cannot test the |a| hypothesis: the hypothesis is about
# water load, and no amount of time-scaling or amplitude-shaping in a generator
# puts water on the blade. What it CAN do is exercise every branch of the parser
# and the chain, and let the invariants above be checked on a running chain
# rather than on the gate function alone.

SYNTH_HZ = 100.0
SYNTH_FRAME_HZ = 60.0


def _smoothstep(u: float) -> float:
    u = clampf(u, 0.0, 1.0)
    return u * u * (3.0 - 2.0 * u)


def synth_take() -> Take:
    """A forward stroke, a backstroke, then a third of each, at 100 Hz.

    Built the way the physics is: the blade's Z angle sweeps between waypoints
    with a smoothstep, and |a| is held at g while the blade is loaded and lifted
    above g while it is swinging free -- which is exactly the contrast the |a|
    hypothesis claims is there in real rowing.
    """
    # (duration, z_from, z_to, |a| in g) -- z is the raw chip axis, ~10 per g
    script: List[Tuple[float, float, float, float]] = []
    for _ in range(3):
        script.append((0.40, -6.0, +6.0, 1.00))   # forward drive: aft sweep, loaded
        script.append((0.30, +6.0, -6.0, 1.05))   # forward recovery: bow sweep
    for _ in range(3):
        script.append((0.30, +4.0, -4.0, 1.05))   # backstroke push: bow sweep, loaded
        script.append((0.25, -4.0, +4.0, 1.90))   # backstroke return: aft sweep, free

    samples: List[Tuple[float, float, float, float]] = []
    t = 0.0
    z = script[0][1]
    step = 1.0 / SYNTH_HZ
    for dur, z0, z1, mag_g in script:
        n = max(1, int(round(dur * SYNTH_HZ)))
        for k in range(n):
            u = _smoothstep((k + 1) / n)
            z = z0 + (z1 - z0) * u
            mag = mag_g * G
            # Put the whole |a| excess in x, so the oar reads as upright-ish and
            # s_vert stays well clear of MIN_VERTICAL.
            x = -math.sqrt(max(0.0, mag * mag - z * z))
            samples.append((t, x, 0.0, z))
            t += step

    take = Take(path="<synthetic>")
    take.samples = samples

    # Walk the frames at 60 Hz, each consuming the latest sample, exactly the
    # aliasing the real loop has. Labels split the two halves of the script.
    frames: List[Frame] = []
    si = 0
    fi = 0
    ft = 0.0
    fstep = 1.0 / SYNTH_FRAME_HZ
    nf = int(round(t * SYNTH_FRAME_HZ)) - 1
    # The label change lands where the backstrokes begin.
    fwd_dur = 3 * (0.40 + 0.30)
    for _ in range(nf):
        ft += fstep
        while si + 1 < len(samples) and samples[si + 1][0] <= ft:
            si += 1
        sx, sy, sz = samples[si][1], samples[si][2], samples[si][3]
        frames.append(Frame(t=ft, d=fstep, st=2, sx=sx, sy=sy, sz=sz,
                            sweep=0.0, bar_aft=SWEEP_NEED_AFT_RESET,
                            bar_fwd=SWEEP_NEED_FWD_RESET,
                            fwd=0.0, back=0.0, cool=0.0, push=0.0,
                            verdict="", index=fi))
        fi += 1
    take.frames = frames
    take.labels = [(0.0, "none"), (0.25, "forward"), (fwd_dur, "backstroke")]
    return take


def render_recording(take: Take, out: Sequence[Out]) -> str:
    """Write a Take + a replay back out as a recording file, for round-tripping."""
    lines = ["# synthetic recording written by direction_lab.py --selftest",
             "# S <t> <x> <y> <z>", "# L <t> <label>",
             "# F <t> <d> <st> <sx> <sy> <sz> <sweep> <bar_aft> <bar_fwd> "
             "<fwd> <back> <cool> <push> <verdict>"]
    ev: List[Tuple[float, str]] = []
    for t, x, y, z in take.samples:
        ev.append((t, "S %.6f %.6f %.6f %.6f" % (t, x, y, z)))
    for t, name in take.labels:
        ev.append((t, "L %.6f %s" % (t, name)))
    # The inputs are written at nine decimals and the outputs at six, matching
    # Scripts/stroke_recorder.gd. The extra digits on the inputs are load-
    # bearing: the chain differences the inputs, so a 5e-7 rounding on a value
    # ~10 becomes a 1e-5 relative error on a difference ~0.04, which lands in
    # the fourth decimal of the rate and would fail a replay that is perfect.
    for o, f in zip(out, take.frames):
        ev.append((f.t, "F %.6f %.9f %d %.9f %.9f %.9f %.6f %.6f %.6f "
                        "%.6f %.6f %.6f %.6f %s" % (
                            f.t, f.d, f.st, f.sx, f.sy, f.sz, o.sweep,
                            f.bar_aft, f.bar_fwd, o.fwd, o.back, o.cool,
                            o.push,
                            verdict_text(o.sweep, f.bar_aft, f.bar_fwd))))
    ev.sort(key=lambda p: p[0])
    lines.extend(text for _, text in ev)
    return "\n".join(lines) + "\n"


def selftest(verbose: bool = True) -> int:
    """Everything checkable with no recording present. Returns failures."""
    fails = 0

    def ok(cond: bool, label: str, detail: str = "") -> None:
        nonlocal fails
        if cond:
            if verbose:
                print("  ok   %s%s" % (label, ("   " + detail) if detail else ""))
        else:
            fails += 1
            print("  FAIL %s%s" % (label, ("   " + detail) if detail else ""))

    print("=" * 78)
    print("CONSTANT MIRROR / 常数镜像")
    print("=" * 78)
    bad = check_mirror()
    ok(not bad, "the Python mirror matches Scripts/oar_controller.gd",
       "%d constants" % len(MIRROR))
    for b in bad:
        print("       %s" % b)

    print()
    print("=" * 78)
    print("MODEL INVARIANTS / 模型不变量")
    print("=" * 78)
    inv = check_invariants()
    ok(not inv, "no invariant is violated")
    for b in inv:
        print("       %s" % b)

    print()
    print("=" * 78)
    print("ROUND TRIP / 往返")
    print("=" * 78)
    print("  note: this proves the parser, the field order and the comparison.")
    print("        It does NOT prove the physics -- a replay wrong in the same")
    print("        way twice round-trips perfectly. Only `verify` on a real")
    print("        recording can do that.")
    print("  注意:这只能证明解析器、字段顺序和比对逻辑。它证明不了物理 —— 一个用")
    print("        同一种错法错两次的回放可以完美往返。那件事只有对真实录像跑")
    print("        `verify` 才能证明。")
    take = synth_take()
    out = run_chain(take, R0())
    ok(len(out) == len(take.frames), "the chain ran one output per frame",
       "%d frames" % len(out))

    # push == max(fwd, back) after section 7, on every frame of a live chain.
    bad_push = [i for i, o in enumerate(out)
                if abs(o.push - max(o.fwd, o.back)) > 1e-12]
    ok(not bad_push, "push_power is max(fwd, back) on every frame",
       "%d frames" % len(out))

    # The cooldown covers all four powers. A frame inside the cooldown whose
    # powers are non-zero means section 7 has drifted below the force.
    bad_cool = [i for i, o in enumerate(out)
                if o.cool > 0.0 and (o.fwd > 0.0 or o.back > 0.0)]
    ok(not bad_cool, "no frame inside the cooldown pays anything")

    # Every frame the chain actually ran must have produced a verdict that
    # matches its own gate -- the readout and the boat cannot disagree.
    bad_v = []
    for o, f in zip(out, take.frames):
        if f.st != 2:
            continue
        if verdict_text(o.sweep, f.bar_aft, f.bar_fwd) == "-> ---" \
                and (o.fwd > 0.0 or o.back > 0.0):
            bad_v.append(f.index)
    ok(not bad_v, "the verdict and the gate agree on every frame")

    text = render_recording(take, out)
    tmp = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "_selftest_roundtrip.txt")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    try:
        again = parse_recording(tmp)
        ok(len(again.frames) == len(take.frames), "the parser recovered every F line",
           "%d of %d" % (len(again.frames), len(take.frames)))
        ok(len(again.samples) == len(take.samples), "the parser recovered every S line")
        ok(not again.warnings, "the parser found nothing to complain about",
           "%d warnings" % len(again.warnings))
        for w in again.warnings[:5]:
            print("       %s" % w)
        n, problems, ties = verify_take(again)
        ok(not problems, "verify() passes on the round-tripped file",
           "%d frames" % n)
        for p in problems[:5]:
            print("       %s" % p)
        # The tie filter forgives frames sitting on a hard comparison. Bound it
        # by the number of STROKES, not frames: the only knife edges in the
        # chain are the cooldown arming and the cooldown expiring, so a filter
        # that works forgives at most a frame or two per stroke, while one that
        # is broken forgives everything. A share-of-frames bound would pass a
        # filter that forgave every frame of a short recording and fail one that
        # forgave two frames of a long quiet one -- backwards on both counts.
        arms = sum(1 for i, f in enumerate(again.frames)
                   if f.cool > 0.0 and (i == 0 or again.frames[i - 1].cool <= 0.0))
        ok(len(ties) <= 2 * arms + 2,
           "the tie filter is forgiving a frame or two per stroke, not everything",
           "%d tie(s), %d stroke(s) armed" % (len(ties), arms))
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass

    # The synthetic take must actually exercise both directions, or the round
    # trip above is a test of the quiet path only.
    fwd_imp = sum(o.fwd * f.d for o, f in zip(out, take.frames))
    back_imp = sum(o.back * f.d for o, f in zip(out, take.frames))
    ok(fwd_imp > 0.0, "the synthetic take pays forward thrust", "%.3f" % fwd_imp)
    ok(back_imp > 0.0, "the synthetic take pays astern thrust", "%.3f" % back_imp)

    print()
    if fails:
        print("SELFTEST FAILED: %d check(s)" % fails)
    else:
        print("SELFTEST PASSED")
    return fails


# ---------------------------------------------------------------------------
# 10. REPORTING / 报告
# ---------------------------------------------------------------------------

def report_peaks(takes: Sequence[Take]) -> None:
    """Where the two populations sit, as distributions."""
    print("=" * 78)
    print("|a|/g AND SWEEP, BY LABEL / 按标签看 |a|/g 和扫速")
    print("=" * 78)
    print("  A rule that separates the two legs has to separate these two")
    print("  distributions, not their maxima. A single extreme value on each")
    print("  side is not a separation -- it is two outliers that will move the")
    print("  next time the sensor is remounted.")
    print("  能分开两条腿的规则,必须能分开这两个「分布」,而不是它们的最大值。两边各")
    print("  一个极值不叫分开 —— 那只是两个离群点,下次重新装传感器就会挪位置。")
    print()
    hdr = ("  %-26s %-11s %6s %8s %8s %8s %8s %8s %8s" %
           ("take", "label", "frames", "|a| p10", "|a| p50", "|a| p90",
            "sw p10", "sw p50", "sw p90"))
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for take in takes:
        out = run_chain(take, R0())
        buckets: Dict[str, List[Tuple[float, float]]] = {}
        for o, f in zip(out, take.frames):
            if f.st != 2:
                continue
            buckets.setdefault(take.label_for_frame(f), []).append(
                (o.mag / G, abs(o.sweep)))
        for lab in ("forward", "backstroke", "other", "none"):
            vals = buckets.get(lab)
            if not vals:
                continue
            amags = [v[0] for v in vals]
            sws = [v[1] for v in vals]
            pa = pcts(amags, (0.10, 0.50, 0.90))
            ps = pcts(sws, (0.10, 0.50, 0.90))
            print("  %-26s %-11s %6d %8.3f %8.3f %8.3f %8.2f %8.2f %8.2f" % (
                take.name[:26], lab, len(vals),
                pa[0], pa[1], pa[2], ps[0], ps[1], ps[2]))
    print()
    print("  Read the |a| p50 columns: if the loaded leg and the free leg have")
    print("  overlapping p10..p90 bands, the quasi-static gate has nothing to")
    print("  bite on and R2 has already lost.")
    print("  读 |a| 的 p50 那一列:如果入水腿和空挥腿的 p10..p90 带子互相重叠,")
    print("  准静态门槛就无从下口,R2 已经输了。")


def report_score(takes: Sequence[Take], rules: Sequence[Rule],
                 show_xcorr: bool = True) -> None:
    print("=" * 78)
    print("RULES / 候选规则")
    print("=" * 78)
    for r in rules:
        print("  %-8s %s" % (r.name, r.blurb))
    print()

    # The shipped series, per take, for the phase-delay comparison.
    print("=" * 78)
    print("PER-SEGMENT NET IMPULSE / 分段净冲量")
    print("=" * 78)
    print("  net = forward impulse - astern impulse, over one labelled run.")
    print("  A backstroke segment should net ASTERN, so its net should be")
    print("  NEGATIVE. The 'ok' column is that sign test, per segment.")
    print("  净 = 前向冲量 - 后退冲量,统计一段连续同标签的帧。后划段应当净向「后」,")
    print("  也就是净值为负。'ok' 那一列就是这个符号检验,逐段给。")
    print()
    hdr = ("  %-24s %-11s %6s %8s %9s %9s %8s %6s %6s" %
           ("take", "label", "frames", "cover", "fwd imp", "back imp",
            "net", "purit", "ok"))
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for take in takes:
        for r in rules:
            out = run_chain(take, r)
            for s in score_take(take, out):
                if s.label not in LABEL_INTENT:
                    continue
                c = s.correct()
                print("  %-24s %-11s %6d %8.2f %9.3f %9.3f %8.3f %6s %6s" % (
                    (take.name[:24] + (" " + r.name if r.name != "R0" else ""))[:24],
                    s.label, s.n, s.cover, s.fwd_imp, s.back_imp, s.net,
                    ("%.2f" % s.purity) if s.paid else "  --",
                    ("y" if c else "n") if c is not None else "?"))
        print()

    print("=" * 78)
    print("ROLLED UP / 汇总")
    print("=" * 78)
    print("  forward imp   the total forward impulse paid on frames the player")
    print("                called forward rowing. Higher is a better forward")
    print("                stroke -- but compare it against the oracle's own.")
    print("  back takes    how many backstroke segments netted ASTERN, out of")
    print("                how many. This is the number the whole exercise is")
    print("                about.")
    print("  forward imp   玩家标为「前划」的帧上付出的前向冲量总和。越高说明前划给力")
    print("                越足 —— 但要跟 oracle 自己的那个数比。")
    print("  back takes    有多少个「后划段」净向船尾,除以总段数。整件事要的就是这个数。")
    print()
    hdr = ("  %-8s %12s %10s %10s %8s %12s" %
           ("rule", "forward imp", "fwd cover", "purity", "back ok", "net back"))
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))

    oracle_fwd = 0.0
    for take in takes:
        out = run_chain(take, R0())
        for s in oracle_take(take, out):
            if s.label == "forward":
                oracle_fwd += s.fwd_imp

    for r in rules:
        agg = {"fwd_imp": 0.0, "paid": 0.0, "n": 0, "wrong": 0,
               "takes": 0, "takes_right": 0, "net_back": 0.0}
        for take in takes:
            out = run_chain(take, r)
            s = summarise(score_take(take, out))
            agg["fwd_imp"] += s["fwd_imp"]
            agg["paid"] += s["paid"]
            agg["n"] += s["n"]
            agg["wrong"] += s["wrong"]
            agg["takes"] += s["takes"]
            agg["takes_right"] += s["takes_right"]
            for seg in score_take(take, out):
                if seg.label == "backstroke":
                    agg["net_back"] += seg.net
        cover = agg["paid"] / agg["n"] if agg["n"] else 0.0
        purity = ((agg["paid"] - agg["wrong"]) / agg["paid"]) if agg["paid"] else float("nan")
        print("  %-8s %12.3f %10.2f %10s %5d/%-6d %12.3f" % (
            r.name, agg["fwd_imp"], cover,
            ("%.3f" % purity) if agg["paid"] else "--",
            agg["takes_right"], agg["takes"], agg["net_back"]))
    print("  %-8s %12.3f %10s %10s %5s %12s" % (
        "ORACLE", oracle_fwd, "--", "--", "--", "--"))
    print()

    if not show_xcorr:
        return

    print("=" * 78)
    print("IS IT JUST THE SHIPPED RULE, DELAYED? / 会不会只是出货规则延迟了几帧?")
    print("=" * 78)
    print("  Best-lag correlation of each rule's (forward - astern) series")
    print("  against the shipped rule's, per take. A best lag near 0 with a")
    print("  high correlation means the rule is the shipped one wearing a hat;")
    print("  a rule that wins at lag 0 is doing something genuinely different.")
    print("  每个规则的 (前向 - 后退) 序列与出货规则序列的最佳滞后互相关,逐条录像。")
    print("  最佳滞后接近 0 而相关又很高,说明这规则只是出货规则换了顶帽子;")
    print("  在滞后 0 处取胜的规则,才是真的做了别的事。")
    print()
    for take in takes:
        baseline = [o.fwd - o.back for o in run_chain(take, R0())]
        for r in rules:
            if r.name == "R0":
                continue
            series = [o.fwd - o.back for o in run_chain(take, r)]
            lag, corr = cross_correlation(series, baseline)
            flag = "  <-- clone" if (abs(lag) > 3 and corr > 0.95) else ""
            print("  %-24s %-8s best lag %+3d frames, corr %+.3f%s"
                  % (take.name[:24], r.name, lag, corr, flag))
    print()


def report_verify(takes: Sequence[Take]) -> int:
    print("=" * 78)
    print("GOLDEN TRACE / golden trace")
    print("=" * 78)
    print("  The replay of the shipped chain must reproduce the controller's")
    print("  own per-frame output exactly. Until it does, no score below means")
    print("  anything: a replay that disagrees with the shipped rule is not")
    print("  measuring the shipped rule.")
    print("  出货链的回放必须精确复现控制器自己的逐帧输出。在它做到之前,下面任何")
    print("  评分都没有意义 —— 一个跟出货规则对不上的回放,量的不是出货规则。")
    print()
    print("  Frames whose sweep sat on a bar are reported as TIES and do not")
    print("  fail the trace: the gate is two hard comparisons, so a sweep parked")
    print("  exactly on a bar is decided by the last bit of a float, and no two")
    print("  implementations need agree there.")
    print("  扫速正好压在门槛上的帧报为 TIE,不算失败:门槛是两个硬比较,压在门槛上的")
    print("  扫速由浮点的最后一位决定,不该要求两份实现在这里一致。")
    print()
    fails = 0
    for take in takes:
        n, problems, ties = verify_take(take)
        if problems:
            fails += 1
            print("  FAIL %s  (%d frames)" % (take.name, n))
            for p in problems:
                print("       %s" % p)
        else:
            print("  ok   %-34s %6d frames, %6d samples, %6d labels"
                  % (take.name[:34], n, len(take.samples), len(take.labels)))
        for t in ties[:3]:
            print("       tie  %s" % t)
        if len(ties) > 3:
            print("       ... and %d more tie(s)" % (len(ties) - 3))
        if take.warnings:
            print("       %d parser warning(s), first few:" % len(take.warnings))
            for w in take.warnings[:5]:
                print("         %s" % w)
    print()
    if fails:
        print("GOLDEN TRACE FAILED on %d of %d recording(s)." % (fails, len(takes)))
    else:
        print("GOLDEN TRACE PASSED on %d recording(s)." % len(takes))
    return fails


def load_all(paths: Sequence[str]) -> Tuple[List[Take], int]:
    takes: List[Take] = []
    bad = 0
    for p in paths:
        if not os.path.isfile(p):
            print("  no such file: %s" % p, file=sys.stderr)
            bad += 1
            continue
        takes.append(parse_recording(p))
    return takes, bad


# ---------------------------------------------------------------------------
# 11. CLI / 命令行
# ---------------------------------------------------------------------------

def parse_sweep(spec: str) -> List[float]:
    """"1.0:2.0:0.1" -> [1.0, 1.1, ...]. A bare number -> [that number]."""
    if ":" not in spec:
        return [float(spec)]
    lo, hi, step = (float(x) for x in spec.split(":"))
    out = []
    v = lo
    while v <= hi + 1e-9:
        out.append(round(v, 6))
        v += step
    return out


def build_rules(names: Sequence[str], r2_t: float,
                r5_window: Optional[float] = None,
                r5_jerk: Optional[float] = None) -> List[Rule]:
    rules: List[Rule] = []
    for n in names:
        key = n.strip().upper()
        if key == "R0":
            rules.append(R0())
        elif key == "R1":
            rules.append(R1())
        elif key == "R2":
            rules.append(R2(r2_t))
        elif key == "R3":
            rules.append(R3())
        elif key == "R5":
            rules.append(R5(r5_window, r5_jerk))
        elif key in ("R2+R3", "R2R3"):
            rules.append(R2R3(r2_t))
        else:
            raise SystemExit("unknown rule %r (try R0,R1,R2,R3,R5,R2+R3)" % n)
    return rules


def loo_report(takes: Sequence[Take], sweep: Sequence[float]) -> None:
    """Leave-one-recording-out over R2's threshold.

    The point is to refuse a threshold that only wins because it was picked on
    the same rowing it is scored on. With this few recordings the honest reading
    is the WORST held-out score, not the mean -- a rule that is excellent on
    three takes and catastrophic on the fourth is a rule that will be
    catastrophic the next time it rains.
    目的:拒绝那种「因为是在同一批划桨上挑出来的才赢」的门槛。这么少的录像条数下,
    诚实的读法是「留出那一条的最差成绩」,而不是平均值 —— 一个在三条上优秀、在第四条
    上灾难的规则,下次下雨的时候一样会灾难。
    """
    print("=" * 78)
    print("LEAVE-ONE-RECORDING-OUT / 留一次录像")
    print("=" * 78)
    if len(takes) < 2:
        print("  needs at least 2 recordings to hold one out.")
        print("  至少需要 2 条录像才谈得上「留出」。")
        return

    def right_count(rule: Rule, subset: Sequence[Take]) -> int:
        n = 0
        for take in subset:
            out = run_chain(take, rule)
            n += summarise(score_take(take, out))["takes_right"]
        return n

    print("  %-24s %10s %12s %10s" % ("held out", "picked T", "its back ok", "its fwd imp"))
    print("  " + "-" * 60)
    worst = None
    for i, held in enumerate(takes):
        rest = [t for j, t in enumerate(takes) if j != i]
        best_t, best_key = None, None
        for tval in sweep:
            r = R2(tval)
            right = right_count(r, rest)
            fwd = sum(summarise(score_take(t, run_chain(t, r)))["fwd_imp"] for t in rest)
            # Prefer more backstrokes right, then more forward impulse.
            key = (right, fwd)
            if best_key is None or key > best_key:
                best_key, best_t = key, tval
        r = R2(best_t)
        out = run_chain(held, r)
        s = summarise(score_take(held, out))
        print("  %-24s %10.2f %8d/%-3d %10.3f" % (
            held.name[:24], best_t, s["takes_right"], s["takes"], s["fwd_imp"]))
        if worst is None or s["takes_right"] < worst:
            worst = s["takes_right"]
    print()
    print("  worst held-out backstroke score: %d" % worst)
    print("  留出集上最差的后划得分:%d" % worst)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        prog="direction_lab.py",
        description="Score oar direction rules offline against real rowing.")
    ap.add_argument("mode", choices=["selftest", "verify", "score", "peaks"])
    ap.add_argument("files", nargs="*", help="recording files from Scripts/stroke_recorder.gd")
    ap.add_argument("--rule", default="R0,R2,R3",
                    help="comma-separated candidate rules (default R0,R2,R3)")
    ap.add_argument("--r2-t", type=float, default=R2.default_t,
                    help="R2's quasi-static threshold, in g (default %(default)s)")
    ap.add_argument("--r2-sweep", default=None,
                    help="sweep R2's threshold, e.g. 1.0:2.0:0.1")
    ap.add_argument("--r5-window", type=float, default=None)
    ap.add_argument("--r5-jerk", type=float, default=None)
    ap.add_argument("--loo", action="store_true",
                    help="leave-one-recording-out over R2's threshold")
    ap.add_argument("--no-xcorr", action="store_true")
    args = ap.parse_args(argv)

    if args.mode == "selftest":
        return 1 if selftest() else 0

    if not args.files:
        print("this mode needs at least one recording file.", file=sys.stderr)
        print("record one in game with R (see Scripts/stroke_recorder.gd), then:", file=sys.stderr)
        print("  python3 tools/direction_lab.py %s recordings/*.txt" % args.mode,
              file=sys.stderr)
        return 2

    takes, bad = load_all(args.files)
    if bad:
        return 2
    if not takes:
        print("no recordings loaded.", file=sys.stderr)
        return 2

    total_frames = sum(len(t.frames) for t in takes)
    if total_frames == 0:
        print("the recordings have no F lines -- the recorder only writes them "
              "while it is recording, and the boat's _physics_process is what "
              "feeds them.", file=sys.stderr)
        return 2

    print("loaded %d recording(s), %d frames, %d samples"
          % (len(takes), total_frames, sum(len(t.samples) for t in takes)))
    print()

    if args.mode == "verify":
        return 1 if report_verify(takes) else 0

    if args.mode == "peaks":
        report_peaks(takes)
        return 0

    # score: verify first, because a score off an unverified replay is noise.
    if report_verify(takes):
        print("refusing to score: the golden trace must pass first.")
        print("拒绝评分:golden trace 必须先通过。")
        return 1
    print()

    r2_t = args.r2_t
    if args.r2_sweep:
        vals = parse_sweep(args.r2_sweep)
        print("sweeping R2's threshold over %d values: %s"
              % (len(vals), ", ".join("%.2f" % v for v in vals)))
        print()
        print("  %-8s %10s %12s %12s %10s" %
              ("T", "fwd imp", "back ok", "net back", "cover"))
        print("  " + "-" * 56)
        for v in vals:
            r = R2(v)
            fwd = right = takes_n = 0
            net_back = 0.0
            paid = n = 0
            for take in takes:
                out = run_chain(take, r)
                segs = score_take(take, out)
                s = summarise(segs)
                fwd += s["fwd_imp"]
                right += s["takes_right"]
                takes_n += s["takes"]
                paid += s["paid"]
                n += s["n"]
                for seg in segs:
                    if seg.label == "backstroke":
                        net_back += seg.net
            print("  %-8.2f %10.3f %8d/%-3d %12.3f %10.3f" % (
                v, fwd, right, takes_n, net_back, paid / n if n else 0.0))
        print()
        r2_t = R2.default_t

        if args.loo:
            loo_report(takes, vals)
            print()

    rules = build_rules(args.rule.split(","), r2_t, args.r5_window, args.r5_jerk)
    report_score(takes, rules, show_xcorr=not args.no_xcorr)

    print("=" * 78)
    print("BEFORE YOU BELIEVE A WINNER / 在相信某个赢家之前")
    print("=" * 78)
    print("  1. Did it win by paying LESS? Read its 'cover' and its forward")
    print("     impulse against the oracle's, not just its backstroke count.")
    print("     它是不是靠「少给力」赢的?读它的 cover 和前向冲量,跟 oracle 比,")
    print("     不要只看后划对了几个。")
    print("  2. Is it the shipped rule delayed? The lag table above answers it.")
    print("     它是不是出货规则的延迟版?上面那张滞后表回答了。")
    print("  3. Is its constant sitting inside the band 46.02 .. 79.23? Those are")
    print("     two isolated peaks from one afternoon, not a distribution, and")
    print("     they will move the next time the sensor is remounted.")
    print("     它的常数是不是落在 46.02 .. 79.23 这条带子里面?那两个数是某个下午的")
    print("     两个孤立峰值,不是分布,下次重装传感器就会挪。")
    print("  4. Was it picked after trying dozens of thresholds on this same small")
    print("     batch? If so, run the recordings again tomorrow and re-check.")
    print("     它是不是在同一小批数据上试了几十组门槛之后挑出来的?如果是,明天")
    print("     重录一轮再验一遍。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
