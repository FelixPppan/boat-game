#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""direction_lab.py -- say what is actually IN an oar recording.

说清楚「一条桨的录像里到底有什么」:按玩家声明的动作,分开看加速度和陀螺仪的分布。

WHY THIS EXISTS / 为什么要它
--------------------------------------------------------------------------
Scoring a direction RULE used to live here, and it does not any more.

`verify` replayed the shipped signal chain over a recording and compared itself
frame for frame against the F lines that Scripts/stroke_recorder.gd wrote, and
`score` ran the candidate rules R0..R5 over the same take. Every one of those
went with the old algorithm: the F line is no longer written by anything, and
there is nothing left for a golden trace to compare against. The rule that
replaced them

    forward_power = clamp((-gx - SWEEP_DEADBAND) / (SWEEP_FULL - SWEEP_DEADBAND), 0, 1)

is one line over the raw stream, so a rule can be scored straight off the raw
samples -- and that is what `tools/stroke_capture.py --read <file> --forward`
does. Nothing here re-implements the controller, so nothing here can drift away
from it.

What is left is the half that was never about a rule: parsing a recording, and
saying where the accelerometer and the gyro actually sit for each thing the
player said they were doing. That is the view that decides whether a threshold
has anything to bite on at all, and it stays useful whatever the rule becomes.
For the 2026-09-29 take it is what showed the answer outright -- the |a|/g
distribution of the water strokes and the air swings overlapped completely,
while the aft sweeps ran 2-7x deeper than the bow-ward ones.

给「方向判得对不对」评分的那条线以前在这里,现在不在了。

`verify` 会把出货版信号链在录像上回放一遍,逐帧比对 Scripts/stroke_recorder.gd 写下的
F 行;`score` 再把候选规则 R0..R5 跑一遍同一条录像。那些都随旧算法一起走了:F 行现在没有
任何东西在写,golden trace 也就没有可比对的对象。取代它们的那条规则是一行作用在原始流上的
式子,所以规则可以直接拿原始样本评分 —— 那正是 `tools/stroke_capture.py --read <文件>
--forward` 在做的事。这里不再重新实现一遍控制器,所以这里没有会漂移的东西。

剩下的是从来与规则无关的那一半:解析录像,以及按玩家声明的动作分开报出加速度和陀螺仪到底
落在哪里。这是决定「一个门槛有没有东西可咬」的那一屏,不管规则以后变成什么都还有用。
2026-09-29 那份实录上,它是直接把答案摆出来的那一个 —— 水里那几桨的 |a|/g 分布和空挥的
完全重叠,而后扫叶比前扫叶深 2–7 倍。

WHAT IT CANNOT DO / 它做不到什么
--------------------------------------------------------------------------
It cannot tell you a threshold is RIGHT. It can tell you whether two populations
overlap, which is the question that comes first -- a threshold that separates
nothing is not badly tuned, it is not a threshold. And it cannot test anything on
synthetic data: no amount of time-scaling changes |a|, so only real recordings
with real water load say anything about load.

它不能告诉你某个门槛是「对的」。它能告诉你两个总体是不是重叠,而那是更靠前的问题 ——
一个什么都分不开的门槛不是「调得不好」,它根本不是一个门槛。它也没法用合成数据检验任何
东西:任何时间缩放都不改变 |a|,所以关于「负载」只有带真实水阻的真实录像说了算。

USAGE / 用法
--------------------------------------------------------------------------
    python3 tools/direction_lab.py selftest
        No data needed. Checks the parser round trip, the label lookup, and the
        percentile helper. Run this first.
        不需要数据。检查解析器往返、标签查找和分位数函数。先跑这个。

    python3 tools/direction_lab.py peaks recordings/*.txt
        Where the populations sit: |a|/g and gx per label, as percentiles rather
        than extremes. This is the falsification view.
        总体究竟落在哪里:按标签给 |a|/g 和 gx 的分位数,而不是极值。这是用来
        「证伪」的那一屏。

LANGUAGE / 语言
--------------------------------------------------------------------------
Printed output is bilingual because the player reads it. Dense inline rationale is
English only -- doubling the prose would bury the code it explains.
打印输出中英对照,因为读它们的是玩家。密集的段落内推理只用英文 —— 把散文全部翻倍只会把
它解释的代码埋掉。
"""

from __future__ import annotations

import argparse
import math
import os
import sys
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Sequence, Tuple

# ---------------------------------------------------------------------------
# 1. PERCENTILES / 分位数
# ---------------------------------------------------------------------------


def percentile(sorted_vals: Sequence[float], p: float) -> float:
    """Linear-interpolated percentile of an already-sorted list.

    对已经排好序的列表做线性插值的分位数。
    """
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


# The three points every table here reports. p10 and p90 rather than min and max
# because a single extreme value is an outlier that moves the next time the
# sensor is remounted, and a decision made on two outliers is a decision about
# the mounting, not about the rowing.
# 每张表都报这三个点。用 p10/p90 而不是最小/最大:单个极值是一个下次重装传感器就会挪位置的
# 离群点,而拿两个离群点做决定,决定的是安装方式,不是划桨。
PTS = (0.10, 0.50, 0.90)

# The label that applies before the player has pressed anything. Not in
# LABEL_INTENT because it is not an intent -- it is the absence of one.
# 玩家还没按任何键时适用的标签。不在 LABEL_INTENT 里,因为它不是一个意图 —— 是没有意图。
NO_LABEL = "none"

# A recording is scored as forward rowing vs backstroking, so those are the two
# labels whose populations have to be told apart. "other" is whatever the player
# was doing in between and is reported but never compared.
# 录像被当作「前划 vs 后划」来评分,所以这两个标签是必须分得开的两个总体。「other」是玩家
# 中间做的别的事,照报但不参与比较。
LABELS = ("forward", "backstroke", "other", NO_LABEL)


# ---------------------------------------------------------------------------
# 2. THE RECORDING / 录像文件
# ---------------------------------------------------------------------------
# Two line kinds, all on one clock. See Scripts/stroke_recorder.gd for the in-game
# writer and tools/stroke_capture.py for the wireless one; both write the same
# rows.
#
#   S <t> <x> <y> <z>                 accel, 4 fields after the tag
#   S <t> <x> <y> <z> <gx> <gy> <gz>  accel and gyro, 7 fields after the tag
#   L <t> <forward|backstroke|other|none>
#
# and one obsolete kind, which is counted and ignored:
#
#   F <t> <d> <st> ...   the controller's per-frame decision, written by the old
#                        recorder for the golden-trace comparison. Nothing writes
#                        it any more, but takes recorded before 2026-09-30 have
#                        them and they must not read as parse errors.
#
# 两种行,共用同一个时钟(见 Scripts/stroke_recorder.gd 的游戏内写入方,以及
# tools/stroke_capture.py 的无线那一个;两者写的行是一样的),外加一种已经作废的行:
# F 行是控制器逐帧的判定,由旧录制器为 golden trace 比对而写。现在没有任何东西写它,但
# 2026-09-30 之前录下来的实录里有,它们不能被读成解析错误。
S_ACCEL_FIELDS = 4
S_GYRO_FIELDS = 7


@dataclass
class Take:
    path: str
    samples: List[Tuple[float, float, float, float]] = field(default_factory=list)
    # Gyro, (t, gx, gy, gz), index-aligned with `samples` -- but only when the
    # recording carries it at all. Kept beside `samples` rather than widened into
    # it on purpose: the wide row is the gyro one, and a four-tuple that silently
    # became a seven-tuple would change every call site that unpacks it.
    #
    # 陀螺仪,(t, gx, gy, gz),与 `samples` 下标对齐 —— 但只在录制带了它的时候。放在
    # `samples` 旁边而不是并进去,是有意的:宽的那种行才是带陀螺仪的那一种,一个悄悄从四元
    # 变成七元的元组会改变每一处解包它的调用点。
    gyro: List[Tuple[float, float, float, float]] = field(default_factory=list)
    labels: List[Tuple[float, str]] = field(default_factory=list)
    ## How many F lines were seen and skipped. Reported, so a take that was
    ## recorded for the old comparison says so rather than looking like an
    ## ordinary file that happens to have no frames.
    ## 看到并跳过了多少 F 行。报出来,这样一条为旧比对而录的实录会自己说明,而不是看起来像
    ## 一条碰巧没有帧的普通文件。
    frames_ignored: int = 0
    warnings: List[str] = field(default_factory=list)

    @property
    def name(self) -> str:
        return os.path.basename(self.path)

    @property
    def has_gyro(self) -> bool:
        """True only if EVERY sample has a gyro reading.

        A file where some S lines carry the gyro and some do not is not a file
        you can index gyro against samples in, and saying so here is better than
        letting a consumer line up the wrong pairs and get a plausible number.
        只有**每一条**样本都带陀螺仪才为真。有的 S 行带、有的不带,这种文件没法把陀螺仪和
        样本按下标对上,在这里明说出来,好过让调用方配错对还得到一个像样的数。
        """
        return bool(self.samples) and len(self.gyro) == len(self.samples)

    def label_at(self, t: float) -> str:
        """The label in force at time t: the last L line at or before it.

        t 时刻生效的标签:它之前(含)最后一条 L 行所指的那个。
        """
        cur = NO_LABEL
        for lt, name in self.labels:
            if lt <= t:
                cur = name
            else:
                break
        return cur

    def span(self) -> float:
        if not self.samples:
            return 0.0
        return self.samples[-1][0] - self.samples[0][0]


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
                if len(parts) != S_ACCEL_FIELDS + 1 and len(parts) != S_GYRO_FIELDS + 1:
                    take.warnings.append(
                        "%s:%d bad S line (%d fields)" % (path, lineno, len(parts) - 1))
                    continue
                try:
                    # Parsed all at once, then appended: appending the sample
                    # first and failing on the gyro would leave the two lists
                    # different lengths, which is exactly the misalignment
                    # has_gyro exists to prevent.
                    # 一次解析完再追加:先追加样本、再在陀螺仪上失败,会让两个列表长度不同,
                    # 而那正是 has_gyro 存在的意义所在。
                    vals = [float(v) for v in parts[1:]]
                except ValueError:
                    take.warnings.append("%s:%d unparsable S line" % (path, lineno))
                    continue
                take.samples.append((vals[0], vals[1], vals[2], vals[3]))
                if len(vals) == S_GYRO_FIELDS:
                    take.gyro.append((vals[0], vals[4], vals[5], vals[6]))
            elif kind == "L":
                parts = line.split()
                if len(parts) < 3:
                    take.warnings.append("%s:%d bad L line" % (path, lineno))
                    continue
                try:
                    take.labels.append((float(parts[1]), parts[2]))
                except ValueError:
                    take.warnings.append("%s:%d unparsable L line" % (path, lineno))
            elif kind == "F":
                # Ignored on purpose rather than warned about: see the note at the
                # top of this section. Counted so a reader can tell an old take
                # from a new one.
                # 有意忽略而不是报警:见上面那一节。计数,好让读者分得出旧实录和新实录。
                take.frames_ignored += 1
            else:
                take.warnings.append("%s:%d unknown line kind %r" % (path, lineno, kind))
    return take


# ---------------------------------------------------------------------------
# 3. PEAKS, BY LABEL / 按标签看分布
# ---------------------------------------------------------------------------


def _by_label(take: Take) -> Dict[str, List[Tuple[float, float]]]:
    """(mag, gx) per sample, bucketed by the label in force when it was taken.

    The gyro is zipped in by index rather than matched by timestamp: the two
    lists are written from the same signal, so index alignment is exact, and
    matching floats by value would be a slower way to find the same pairs.
    Buckets are only as good as the L lines -- a take recorded without pressing
    1/2/3 lands entirely under "none", which is reported rather than hidden.
    每个样本的 (|a|, gx),按它被采到时生效的标签分桶。陀螺仪按下标配对而不是按时间戳配对:
    两个列表是同一个信号写出来的,所以下标对齐是精确的,而拿浮点值去配对只是用更慢的方式
    找同一批配对。分桶的好坏取决于 L 行 —— 一条没按过 1/2/3 的实录会整个落在 "none" 下面,
    这会被报出来而不是藏起来。
    """
    out: Dict[str, List[Tuple[float, float]]] = {}
    has_gyro = take.has_gyro
    for i, (t, x, y, z) in enumerate(take.samples):
        gx = take.gyro[i][1] if has_gyro else 0.0
        mag = math.sqrt(x * x + y * y + z * z)
        out.setdefault(take.label_at(t), []).append((mag, gx))
    return out


def report_peaks(takes: Sequence[Take]) -> None:
    """Where the populations sit, as distributions.

    各个总体究竟落在哪里,以分布的形式给出。
    """
    print("=" * 78)
    print("|a|/g AND gx, BY LABEL / 按标签看 |a|/g 和 gx")
    print("=" * 78)
    print("  A rule that tells the two legs apart has to tell these two")
    print("  distributions apart, not their extremes. A single extreme value on")
    print("  each side is not a separation -- it is two outliers that will move")
    print("  the next time the sensor is remounted.")
    print("  能分开两条腿的规则,必须能分开这两个「分布」,而不是它们的极值。两边各一个")
    print("  极值不叫分开 —— 那只是两个离群点,下次重新装传感器就会挪位置。")
    print()
    print("  accel is in g and gyro in deg/s as the board reports them, so the")
    print("  |a| column is directly comparable to 1.")
    print("  加速度就是板子报的 g、陀螺仪就是它报的 deg/s,所以 |a| 那一列可以直接和 1 比。")
    print()
    hdr = ("  %-24s %-11s %6s %7s %7s %7s %8s %8s %8s" %
           ("take", "label", "n", "|a| p10", "|a| p50", "|a| p90",
            "gx p10", "gx p50", "gx p90"))
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for take in takes:
        if not take.samples:
            print("  %-24s (no samples)" % take.name[:24])
            continue
        if not take.has_gyro:
            print("  %-24s (no gyro in this take -- gx columns would be zero)"
                  % take.name[:24])
        buckets = _by_label(take)
        for lab in LABELS:
            vals = buckets.get(lab)
            if not vals:
                continue
            pa = pcts((v[0] for v in vals), PTS)
            ps = pcts((v[1] for v in vals), PTS)
            print("  %-24s %-11s %6d %7.3f %7.3f %7.3f %8.1f %8.1f %8.1f" % (
                take.name[:24], lab, len(vals),
                pa[0], pa[1], pa[2], ps[0], ps[1], ps[2]))
    print()
    print("  Read the |a| p50 columns first: if the forward leg and the backstroke")
    print("  leg have overlapping p10..p90 bands, no load gate can separate them")
    print("  and the sign of gx is all that is left to decide on.")
    print("  先读 |a| 的 p50 那两列:如果前划腿和后划腿的 p10..p90 带子互相重叠,就没有")
    print("  任何载荷门槛能分开它们,能拿来判断的就只剩 gx 的符号。")
    print()
    print("  Then read gx p50. The power stroke is the AFT sweep, and on this oar")
    print("  aft is negative, so the backstroke rows should sit well to the left")
    print("  of zero -- deeper, in fact, than the bow-ward rows sit to the right.")
    print("  再读 gx 的 p50。动力段是向后扫,而在这根桨上向后是负的,所以后划那几行应该")
    print("  明显落在零的左边 —— 事实上比前扫那几行落在右边更深。")


def load_all(paths: Sequence[str]) -> Tuple[List[Take], int]:
    takes: List[Take] = []
    bad = 0
    for p in paths:
        try:
            take = parse_recording(p)
        except OSError as exc:
            print("cannot read %s: %s" % (p, exc), file=sys.stderr)
            bad += 1
            continue
        for w in take.warnings:
            print("warning: " + w, file=sys.stderr)
        if take.frames_ignored:
            print("note: %s carries %d obsolete F line(s); ignored"
                  % (take.name, take.frames_ignored))
        takes.append(take)
    return takes, bad


# ---------------------------------------------------------------------------
# 4. SELFTEST / 自检
# ---------------------------------------------------------------------------
# Everything here is about the parser and the small helpers, because those are
# the only things left in the file. There is deliberately no check that a rule
# computes what it should: no rule lives here any more, so a test of one would be
# testing a second copy of something that is scored elsewhere.
# 这里的一切都是关于解析器和那几个小函数的,因为文件里也只剩这些了。故意没有「规则算得对不对」
# 的检查:规则已经不在这里了,测它就等于测一份别处已经在评分的第二份拷贝。

SYNTH_HZ = 100.0


def synth_lines(n: int = 60, hz: float = SYNTH_HZ) -> Tuple[List[str], List[tuple]]:
    """A tiny well-formed take, and the samples it should parse back to.

    One stroke's worth of gx -- a deep negative lobe the way the real take's
    power strokes look -- plus a flat 1 g of accel, so the expected values are
    checkable by hand rather than by re-running the same arithmetic twice.
    一条小的、格式正确的实录,以及它应该被解析回来的那些样本。一段桨的 gx —— 像真实实录里
    动力段那样一个很深的负瓣 —— 再加上平的 1 g 加速度,这样期望值是能手算出来的,而不是把
    同一套算术跑两遍对出来的。
    """
    lines = ["# synthetic take written by direction_lab.py --selftest"]
    expect: List[tuple] = []
    for i in range(n):
        t = i / hz
        u = i / (n - 1.0)
        gx = -300.0 if 0.35 < u < 0.55 else 2.0
        lines.append("S %.6f 0.000000 0.000000 1.000000 %.6f 0.000000 0.000000"
                     % (t, gx))
        expect.append((t, 0.0, 0.0, 1.0))
    # The label goes in the MIDDLE. At the end -- the obvious choice -- no sample
    # falls under it, because every sample is earlier than the line that names
    # it, and the by-label test would then be checking one bucket while believing
    # it was checking two. In the middle it exercises both the unlabelled stretch
    # and the labelled one, with the deep gx lobe inside the labelled half.
    # 标签放在**中间**。放在末尾 —— 那个显然的选择 —— 会让没有任何样本落在它下面,因为每个
    # 样本都比给它命名的这一行更早,于是那个按标签分桶的检查会在以为自己在查两个桶的时候只
    # 查了一个。放中间就同时覆盖了没标签的那一段和有标签的那一段,而且深 gx 那个瓣落在有标签
    # 的那一半里。
    lines.append("L %.6f forward" % ((n // 2) / hz))
    return lines, expect


def render(take: Take) -> List[str]:
    """A Take back out to lines, the way a writer would have produced it.

    把一个 Take 还原成行,就像写文件的那一方会产出的那样。
    """
    lines = ["# rendered by direction_lab.py"]
    for i, (t, x, y, z) in enumerate(take.samples):
        if take.has_gyro:
            _, gx, gy, gz = take.gyro[i]
            lines.append("S %.6f %.6f %.6f %.6f %.6f %.6f %.6f"
                         % (t, x, y, z, gx, gy, gz))
        else:
            lines.append("S %.6f %.6f %.6f %.6f" % (t, x, y, z))
    for t, name in take.labels:
        lines.append("L %.6f %s" % (t, name))
    return lines


def _selftest_parses(lines: Sequence[str], tmp: str) -> Take:
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")
    return parse_recording(tmp)


def selftest(verbose: bool = True) -> int:
    """0 when everything holds, 1 otherwise. Prints every check either way.

    全部成立时返回 0,否则返回 1。两种情况都会把每一项检查打印出来。
    """
    failures: List[str] = []

    def ok(cond: bool, what: str) -> None:
        if verbose:
            print("  %s  %s" % ("ok  " if cond else "FAIL", what))
        if not cond:
            failures.append(what)

    tmp = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "_selftest_tmp.txt")
    try:
        print("parser / 解析器")
        lines, expect = synth_lines()
        take = _selftest_parses(lines, tmp)
        ok(not take.warnings, "a well-formed take parses with no warnings")
        ok(len(take.samples) == len(expect),
           "every S line became one sample (%d/%d)" % (len(take.samples), len(expect)))
        ok(all(abs(a[0] - b[0]) < 1e-9 and abs(a[3] - b[3]) < 1e-9
               for a, b in zip(take.samples, expect)),
           "timestamps and accel come back unchanged")
        ok(take.has_gyro, "a seven-wide take reports has_gyro")
        ok(take.gyro[0][1] == 2.0, "gyro column 1 is gx, not another axis")
        ok(take.samples[0][3] == 1.0 and take.samples[0][1] == 0.0,
           "the accel columns keep their order (x, y, z, not z, y, x)")

        print("labels / 标签")
        ok(take.label_at(0.0) == NO_LABEL, "before the first L line the label is none")
        ok(take.label_at(take.labels[0][0]) == "forward",
           "at the L line's own timestamp the label has already changed")
        ok(take.label_at(1e9) == "forward", "the last label is carried forward")

        print("widths / 行宽")
        narrow = _selftest_parses(
            ["S 0.0 0.0 0.0 1.0", "S 0.01 0.0 0.0 1.0"], tmp)
        ok(len(narrow.samples) == 2, "a four-wide take parses")
        ok(not narrow.has_gyro, "a four-wide take does not claim a gyro")
        mixed = _selftest_parses(
            ["S 0.0 0.0 0.0 1.0", "S 0.01 0.0 0.0 1.0 2.0 0.0 0.0"], tmp)
        ok(not mixed.has_gyro,
           "a mixed-width take does not claim a gyro either")

        print("bad lines / 坏行")
        bad = _selftest_parses(
            ["S 0.0 0.0 0.0 1.0", "S 0.01 0.0 0.0", "Q 0.02 1",
             "S nonsense here", "L 0.03", "", "# a comment"], tmp)
        ok(len(bad.samples) == 1, "only the good S line became a sample")
        ok(len(bad.warnings) == 4, "each bad line is reported once (%d)"
           % len(bad.warnings))
        ok(not bad.labels, "an L line with no label is refused")

        print("obsolete F lines / 作废的 F 行")
        old = _selftest_parses(
            ["S 0.0 0.0 0.0 1.0", "F 0.0 0.0166 2 0.0 0.0 1.0 0.0 40 55 "
             "0.0 0.0 0.0 0.0 -> ---", "L 0.01 forward"], tmp)
        ok(old.frames_ignored == 1, "an F line is counted, not warned about")
        ok(not old.warnings, "an old take parses without warnings")
        ok(len(old.samples) == 1 and len(old.labels) == 1,
           "an F line does not disturb the samples or the labels")

        print("round trip / 往返")
        back = _selftest_parses(render(take), tmp)
        ok(back.samples == take.samples, "samples survive a render/parse round trip")
        ok(back.gyro == take.gyro, "gyro survives too")
        ok(back.labels == take.labels, "labels survive too")

        print("percentiles / 分位数")
        ok(percentile([], 0.5) != percentile([], 0.5),
           "an empty list gives nan rather than a made-up number")
        ok(percentile([5.0], 0.9) == 5.0, "a single value is returned as itself")
        ok(abs(percentile([0.0, 10.0], 0.5) - 5.0) < 1e-9, "p50 interpolates")
        ok(percentile([0.0, 10.0], 0.0) == 0.0 and percentile([0.0, 10.0], 1.0) == 10.0,
           "p0 and p100 are the ends, not one step inside them")
        p = pcts(range(11), (0.10, 0.50, 0.90))
        ok(p == [1.0, 5.0, 9.0], "pcts sorts before it interpolates (%r)" % (p,))

        print("by-label buckets / 按标签分桶")
        buckets = _by_label(take)
        ok(set(buckets) == {NO_LABEL, "forward"},
           "the synthetic take buckets by exactly the labels it has")
        ok(len(buckets[NO_LABEL]) + len(buckets["forward"]) == len(take.samples),
           "every sample lands in exactly one bucket")
        ok(all(abs(m - 1.0) < 1e-6 for m, _ in buckets[NO_LABEL]),
           "|a| of a flat 1 g row is 1.0")
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)

    print()
    if failures:
        print("%d check(s) FAILED:" % len(failures))
        for f in failures:
            print("  - " + f)
        return 1
    print("all checks passed / 全部通过")
    return 0


# ---------------------------------------------------------------------------
# 5. CLI / 命令行
# ---------------------------------------------------------------------------


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="direction_lab.py",
        description="Say what is actually in an oar recording.")
    ap.add_argument("mode", choices=["selftest", "peaks"])
    ap.add_argument("files", nargs="*",
                    help="recording files from Scripts/stroke_recorder.gd or "
                         "tools/stroke_capture.py")
    args = ap.parse_args(argv)

    if args.mode == "selftest":
        return selftest()

    if not args.files:
        print("this mode needs at least one recording file.", file=sys.stderr)
        print("record one in game with R (see Scripts/stroke_recorder.gd), or "
              "over the radio with tools/stroke_capture.py, then:", file=sys.stderr)
        print("  python3 tools/direction_lab.py %s recordings/*.txt" % args.mode,
              file=sys.stderr)
        return 2

    takes, bad = load_all(args.files)
    if bad:
        return 2
    if not takes:
        print("no recordings loaded.", file=sys.stderr)
        return 2

    print("loaded %d recording(s), %d samples"
          % (len(takes), sum(len(t.samples) for t in takes)))
    print()
    report_peaks(takes)
    return 0


if __name__ == "__main__":
    sys.exit(main())
