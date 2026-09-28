#!/usr/bin/env python3
"""Read the oar's wireless stream, and measure the LINK rather than the sensor.

Companion to tools/serial_probe.py. Same job -- show what is actually arriving --
but for the ESP32's own access point instead of the USB cable, and with the one
extra question a radio raises: what does it lose?

    data         udp/4210   the "Accel(g): ..." lines
    diagnostics  udp/4211   the firmware's "# ..." lines

Two things make that measurable, and only one of them is free:

  * The wireless copy of each sample carries the board's own packet counter (S)
    and micros() timestamp (T). Without S, a dropped packet is invisible -- the
    rate simply reads lower, which is exactly what a stalled sensor looks like
    too. Without T, every timing number here would describe the WiFi and the
    operating system rather than the sensor.
  * Nothing else. The host-side arrival times are taken immediately after a
    blocking recvfrom() returns, in each socket's own thread, so they are not
    smeared by a select() loop draining a batch; that is the difference between
    measuring arrival jitter and measuring how often this process wakes up.

Before running it
-----------------
  1. Join the network "oar-sensor" from the Mac's WiFi menu. It has no internet,
     which macOS will point out; that is expected.
  2. Run this while the game is NOT running. The two cannot share the port --
     binding fails on purpose rather than one silently stealing the other's
     packets, so if you see "address already in use", that is the message.
  3. The first run will make macOS ask whether python3 may accept incoming
     connections. Say yes. If it was ever denied, the firewall settings have to
     be changed by hand -- a denied socket receives nothing and reports no error,
     which is indistinguishable from a board that is not transmitting.

Usage:
    python3 tools/udp_probe.py                 # run until Ctrl-C
    python3 tools/udp_probe.py --seconds 60    # run for a minute, print a summary

Exit code is 0 if any sample arrived, 1 if none did, so a script can tell.
"""

import argparse
import socket
import statistics
import sys
import threading
import time

# The same separator set Scripts/sensor_input.gd's _numbers_in() scrubs. Kept
# identical on purpose: if the probe and the game disagree about where a number
# starts, the probe is measuring a different line than the one the game reads,
# and it would report a healthy stream that the game cannot parse.
SEPARATORS = "()/,|:;="

# micros() on the board is a 32-bit microsecond counter, so it wraps roughly
# every 71 minutes. Every delta between two of its values goes through this.
MICROS_MASK = 0xFFFFFFFF

EXPECTED_INTERVAL_US = 10000  # 100 Hz

# Where the board sits on its own network. An ESP32 SoftAP is always the gateway
# of 192.168.4.0/24, so this is fixed rather than discovered.
OAR_ADDRESS = "192.168.4.1"

# What gets sent to the board so it stops broadcasting and starts unicasting. The
# content is irrelevant -- the board reads the sender's address out of the IP
# header, not out of this -- so it is kept short and said once.
# 发给板子、让它从广播改成单播的那个包。内容无关紧要 —— 板子是从 IP 头里
# 读发送方地址的,不是从这个包里 —— 所以短就好,意思到位就行。
HELLO_PAYLOAD = b"oar-here"

# How often to repeat it. The board forgets on restart and this side can come back
# on a different lease, so it is not a one-shot.
HELLO_INTERVAL_SEC = 1.0


def numbers_in(text: str):
    """Every token of `text` that reads as a number, in order."""
    cleaned = text
    for ch in SEPARATORS:
        cleaned = cleaned.replace(ch, " ")
    out = []
    for token in cleaned.split():
        try:
            out.append(float(token))
        except ValueError:
            pass
    return out


def percentile(values, fraction):
    if not values:
        return float("nan")
    ordered = sorted(values)
    index = int(fraction * (len(ordered) - 1))
    return ordered[index]


class Link:
    """Everything counted about the stream, mutated under one lock.

    Deliberately one lock and not a queue per socket: the two threads only ever
    add, the main thread only ever reads and resets a window, and at 100 packets
    a second there is no contention worth designing around.
    """

    def __init__(self):
        self.lock = threading.Lock()

        self.packets = 0          # data packets seen
        self.bytes = 0
        self.diag_lines = 0
        self.malformed = 0

        self.lost = 0             # samples the radio dropped, from S
        self.reordered = 0        # S went backwards or repeated

        self.good = 0
        self.zero_run = 0         # consecutive all-zero samples, for a dead chip

        self._last_seq = None
        self._last_t_us = None
        self._last_arrival = None

        # First and last of each board-owned counter. The BOARD's rate comes from
        # (t_last - t_first) / (seq_last - seq_first), never from the intervals
        # between received packets: a lost packet makes one of those intervals
        # span two periods, which drags the median up and makes a board running at
        # a healthy 100 Hz look like it slowed to 92. That is not hypothetical --
        # it is what this tool reported on 2026-09-28 and it was wrong.
        # 两个「板子自己的」计数器的首尾值。板子的速率来自
        # (t_last - t_first) / (seq_last - seq_first),**永远不要**从「收到的包之间」的间隔算:
        # 丢一个包就让其中一个间隔跨两个周期,把中位数往上拽,
        # 于是一块好好跑在 100 Hz 的板子看起来像降到了 92。
        # 这不是假想 —— 2026-09-28 这个工具就是这么报的,而且是错的。
        self.first_seq = None
        self.last_seq = None
        self.first_t_us = None
        self.last_t_us = None

        self.board_intervals = []
        self.arrival_intervals = []
        self.max_arrival_gap = 0.0

        self.first_arrival = None
        self.last_arrival = None

        self.diag_messages = []
        self.bad_examples = []

        # Windowed counters, reset once a second by the reporter.
        self.win_packets = 0
        self.win_bytes = 0

    # -- data ---------------------------------------------------------------
    def add_sample(self, arrival, text):
        nums = numbers_in(text)
        if len(nums) < 6:
            with self.lock:
                self.malformed += 1
                if len(self.bad_examples) < 5 and text not in self.bad_examples:
                    self.bad_examples.append(text)
            return

        with self.lock:
            self.packets += 1
            self.win_packets += 1
            self.bytes += len(text)
            self.win_bytes += len(text)
            self.good += 1

            if self.first_arrival is None:
                self.first_arrival = arrival

            # The board's own view: did IT keep to 100 Hz? Independent of the
            # radio, so a bad number here is the sensor's fault and a bad number
            # below is the link's.
            if len(nums) >= 8:
                t_us = int(nums[7]) & MICROS_MASK
                if self._last_t_us is not None:
                    self.board_intervals.append(
                        (t_us - self._last_t_us) & MICROS_MASK)
                self._last_t_us = t_us
                if self.first_t_us is None:
                    self.first_t_us = t_us
                self.last_t_us = t_us

            # Gap detection, which only exists because the board numbers the
            # packets. A restart gives a large backwards jump, so it lands in
            # `reordered` rather than being mistaken for a million lost packets.
            if len(nums) >= 7:
                seq = int(nums[6])
                if self._last_seq is not None:
                    step = seq - self._last_seq
                    if step > 1:
                        self.lost += step - 1
                    elif step <= 0:
                        self.reordered += 1
                self._last_seq = seq
                if self.first_seq is None:
                    self.first_seq = seq
                self.last_seq = seq

            # Host-side arrival timing.
            if self._last_arrival is not None:
                dt = arrival - self._last_arrival
                self.arrival_intervals.append(dt)
                if dt > self.max_arrival_gap:
                    self.max_arrival_gap = dt
            self._last_arrival = arrival
            self.last_arrival = arrival

            # The vendor demo's signature failure was six axes printed from
            # fields that were never populated -- all zeros, forever, and silent
            # about it. Cheap to watch for, and the failure mode is otherwise
            # easy to mistake for "the oar is not moving".
            if all(v == 0.0 for v in nums[:6]):
                self.zero_run += 1
            else:
                self.zero_run = 0

    # -- diagnostics --------------------------------------------------------
    def add_diag(self, text):
        with self.lock:
            self.diag_lines += 1
            self.diag_messages.append(text)

    # -- reporting ----------------------------------------------------------
    def _board_rate_unlocked(self):
        """The board's true sample rate in Hz, or None. Call with the lock held.

        Computed from the board's own two counters over the whole run, so it does
        not move when the radio drops a packet -- which is exactly what the median
        of `board_intervals` does, and why that median must never be read as the
        board's rate.
        从板子自己的两个计数器、跨整个运行期算出来,所以射频丢包时它不动 ——
        而 `board_intervals` 的中位数恰恰会动,这就是那个中位数绝不能被当成板子速率的原因。
        """
        if None in (self.first_seq, self.last_seq, self.first_t_us, self.last_t_us):
            return None
        samples = self.last_seq - self.first_seq
        span_us = (self.last_t_us - self.first_t_us) & MICROS_MASK
        if samples <= 0 or span_us <= 0:
            return None
        return (samples + 1) * 1e6 / span_us

    def snapshot(self):
        with self.lock:
            window = (self.win_packets, self.win_bytes)
            self.win_packets = 0
            self.win_bytes = 0
            return {
                "packets": self.packets,
                "bytes": self.bytes,
                "good": self.good,
                "lost": self.lost,
                "reordered": self.reordered,
                "malformed": self.malformed,
                "diag_lines": self.diag_lines,
                "zero_run": self.zero_run,
                "window": window,
                "board": list(self.board_intervals),
                "board_rate": self._board_rate_unlocked(),
                "arrival": list(self.arrival_intervals),
                "max_gap": self.max_arrival_gap,
                "first": self.first_arrival,
                "last": self.last_arrival,
                "bad_examples": list(self.bad_examples),
                "diag_messages": list(self.diag_messages),
            }


def data_thread(sock, link, stop):
    while not stop.is_set():
        try:
            packet = sock.recv(4096)
        except OSError:
            if stop.is_set():
                return
            continue
        # Taken here, in this thread, immediately after the syscall returned --
        # not handed to the main thread to timestamp later.
        arrival = time.monotonic()
        text = packet.decode("ascii", "replace").strip()
        if not text:
            continue
        if text.startswith("#"):
            # A diagnostic on the DATA port would be a firmware bug: they belong
            # on udp/4211 so the game's parse-failure count keeps meaning one
            # thing. Count it as malformed so it shows up rather than hides.
            link.add_sample(arrival, text)
            link.add_diag("(on the data port, which is wrong) " + text)
        else:
            link.add_sample(arrival, text)


def diag_thread(sock, link, stop, echo):
    while not stop.is_set():
        try:
            packet = sock.recv(4096)
        except OSError:
            if stop.is_set():
                return
            continue
        text = packet.decode("ascii", "replace").strip()
        if not text:
            continue
        link.add_diag(text)
        if echo:
            print("  !! firmware: %s" % text)


def local_address_for(address, port):
    """Which local address a datagram to `address` would leave from, or None.

    connect() on a UDP socket sends nothing -- it only fixes the peer so the
    kernel resolves the route, which is what makes this a question about routing
    rather than a probe of the network. Harmless to run at any time.
    对一个 UDP socket 调 connect() 什么都不会发出去 —— 它只是固定对端,让内核去解路由,
    所以这是「问一下路由」而不是「探一下网络」。任何时候跑都无害。
    """
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.connect((address, port))
        return probe.getsockname()[0]
    except OSError:
        return None
    finally:
        probe.close()


def check_network(address, port):
    """Say plainly when the host is not on the board's subnet.

    Worth its own check because every other symptom of this is silence: a Mac on
    another network hears nothing, raises nothing, and looks exactly like a board
    that is not transmitting. On 2026-09-28 that cost a full 60-second run and a
    wrong diagnosis -- macOS had quietly rejoined the internet-connected network.
        之所以值得单独查一次,是因为这个故障的其它表现全是沉默:
    在别的网络上的 Mac 什么都收不到、也不报任何错,和「板子没在发」一模一样。
    2026-09-28 这一次就白跑了一整轮 60 秒,而且诊断错了 —— macOS 悄悄回到了有外网的那个网络。
    """
    source = local_address_for(address, port)
    prefix = OAR_ADDRESS.rsplit(".", 1)[0] + "."
    if source is None:
        print(">>> No route to %s at all. The Mac is not on the board's network." % address)
        print(">>> Join \"oar-sensor\" before running this.")
        return False
    if not source.startswith(prefix):
        print(">>> WRONG NETWORK: this Mac is on %s, the board is on %s0/24."
              % (source, prefix))
        print(">>> Nothing will arrive and nothing will raise an error -- which is")
        print(">>> exactly what a dead board looks like. Join \"oar-sensor\" first,")
        print(">>> and turn OFF Auto-Join for the other network or macOS will")
        print(">>> quietly go back to it.")
        return False
    print("The Mac is on %s, which is the board's subnet." % source)
    return True


def send_hello(sock, address, port, announce=False):
    """Ask the board to unicast to us instead of broadcasting.

    The packet carries nothing but the fact that it arrived -- the board reads the
    address it needs out of the IP header -- so there is no format here and
    nothing to parse at the other end.
    请板子改发单播给我们,而不是广播。

    这个包除了「它到了」不带任何内容 —— 板子要的地址是它从 IP 头里读出来的 ——
    所以这里没有格式,另一端也没有要解析的东西。
    """
    try:
        sock.sendto(HELLO_PAYLOAD, (address, port))
    except OSError as exc:
        # Only worth saying out loud for the announced first one. The usual cause
        # is the Mac having drifted back to another network, and that failure is
        # otherwise indistinguishable from a board that is not transmitting.
        # 只有宣告的那第一次值得出声。常见原因是 Mac 已经飘回别的网络,
        # 而那种失败和「板子没在发」本来是分不出来的。
        if announce:
            print("  (could not send the hello to %s: %s)" % (address, exc))


def open_socket(port, label):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # A fat receive buffer, so a burst is not dropped by the kernel and then
    # reported here as the radio's fault.
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 20)
    except OSError:
        pass
    # No SO_REUSEADDR on purpose. With it, this and a running game would both
    # bind and the kernel would hand the packets to one of them -- so the probe
    # would report a silent, wrong result. Without it, the conflict is an error
    # message that says which port and why.
    try:
        sock.bind(("", port))
    except OSError as exc:
        print("cannot listen on udp/%d (%s): %s" % (port, label, exc))
        print("Something else is already using it -- most likely the game, which")
        print("listens on the same port. Stop it, or the two will not share.")
        sys.exit(2)
    return sock


def report(link, started, elapsed, last_report, quiet):
    snap = link.snapshot()
    window_packets, window_bytes = snap["window"]
    period = elapsed - last_report
    if period <= 0:
        period = 1.0

    parts = [
        "data %5.1f/s" % (window_packets / period),
        "%6.1f kB/s" % (window_bytes / period / 1000.0),
    ]

    rate = snap["board_rate"]
    if rate:
        parts.append("board %5.1f Hz" % rate)
    arrival = snap["arrival"]
    if arrival:
        parts.append("arrive %5.2fms" % (1000 * statistics.median(arrival)))

    parts.append("lost %d" % snap["lost"])
    if snap["reordered"]:
        parts.append("reorder %d" % snap["reordered"])
    if snap["malformed"]:
        parts.append("BAD %d" % snap["malformed"])
    if snap["zero_run"] >= 20:
        parts.append("ALL-ZERO x%d" % snap["zero_run"])

    if not quiet:
        print("  t+%4ds  %s" % (int(elapsed), "  ".join(parts)))


def summary(link, elapsed, quiet):
    snap = link.snapshot()
    print("")
    print("--- what arrived " + "-" * 52)
    if snap["packets"] == 0:
        print("  nothing. See the hints below.")
        return False

    rate = snap["packets"] / elapsed if elapsed > 0 else 0.0
    print("  ran              %6.1f s" % elapsed)
    print("  data packets     %6d   (%.1f /s, target 100)" % (
        snap["packets"], rate))
    print("  bytes            %6d   (%.0f B/s)" % (
        snap["bytes"], snap["bytes"] / elapsed if elapsed > 0 else 0))
    print("  samples          %6d" % snap["good"])

    board_rate = snap["board_rate"]
    print("  board rate       " + (
        "%7.2f Hz   (from the board's own S/T, so loss cannot move it; target %.2f)" % (
            board_rate, 1e6 / EXPECTED_INTERVAL_US)
        if board_rate else "no S/T fields -- firmware older than 2026-09-27?"))
    board = snap["board"]
    print("  board interval   " + (
        "median %d us   p05 %d   p95 %d   <- inflated by loss; NOT the rate" % (
            statistics.median(board),
            percentile(board, 0.05),
            percentile(board, 0.95))
        if board else "n/a"))

    arrival = snap["arrival"]
    print("  arrival interval " + (
        "median %7.2f ms   p95 %7.2f ms   worst gap %6.1f ms" % (
            1000 * statistics.median(arrival),
            1000 * percentile(arrival, 0.95),
            1000 * snap["max_gap"])
        if arrival else "n/a"))

    total_seq = snap["good"] + snap["lost"]
    pct = (100.0 * snap["lost"] / total_seq) if total_seq else 0.0
    print("  lost             %6d packets  (%.3f%%)" % (snap["lost"], pct))
    print("  reordered        %6d  (a board restart also shows up here)" % snap["reordered"])
    print("  malformed        %6d" % snap["malformed"])
    print("  diagnostics      %6d" % snap["diag_lines"])
    for text in snap["bad_examples"]:
        print("    unparsable: %r" % text[:120])
    for text in snap["diag_messages"][:10]:
        print("    firmware: %s" % text)
    return True


HINTS = """
  Nothing is arriving. In the order worth checking:

   1. Is the Mac joined to "oar-sensor"? macOS quietly rejoins an
      internet-connected network on its own, and then nothing is on the subnet
      the board is talking into. Check the Wi-Fi menu before anything else. To
      stop that happening, turn off Auto-Join for the other network.
   2. Did macOS ask about incoming connections and get told no? System Settings,
      Network, Firewall: either turn the firewall off for a test run, or allow
      python3 / Godot in Options. A blocked socket receives nothing and raises no
      error, so this looks exactly like a board that is not transmitting.
   3. Is the board actually powered and running the new firmware? A power bank
      that cuts off at low current, or a cable that is charge-only, gives a dead
      board with a green LED story to tell. Check the board's own TX LED or the
      serial port, and confirm the sketch was really uploaded (arduino-cli
      prints "Sketch uses ... bytes"; a failed compile leaves the OLD binary
      running, which looks like a code change with no effect).
   4. Anything else listening on udp/4210? This script refuses to bind if so, so
      it would have said.
"""


def main():
    parser = argparse.ArgumentParser(
        description="Measure the oar's wireless link (and only the link).")
    parser.add_argument("--port", type=int, default=4210,
                        help="UDP data port (default 4210)")
    parser.add_argument("--diag-port", type=int, default=4211,
                        help="UDP diagnostics port (default 4211)")
    parser.add_argument("--seconds", type=float, default=0.0,
                        help="stop after this many seconds (0 = until Ctrl-C)")
    parser.add_argument("--quiet", action="store_true",
                        help="summary only, no per-second line")
    parser.add_argument("--oar", default=OAR_ADDRESS,
                        help="the board's address (default %s)" % OAR_ADDRESS)
    parser.add_argument("--no-hello", action="store_true",
                        help="do not ask the board to unicast; measure the "
                             "broadcast fallback instead")
    args = parser.parse_args()

    data_sock = open_socket(args.port, "data")
    diag_sock = open_socket(args.diag_port, "diagnostics")

    link = Link()
    stop = threading.Event()
    threads = [
        threading.Thread(target=data_thread, args=(data_sock, link, stop), daemon=True),
        threading.Thread(target=diag_thread,
                         args=(diag_sock, link, stop, not args.quiet), daemon=True),
    ]
    for thread in threads:
        thread.start()

    print("Listening on udp/%d (data) and udp/%d (diagnostics)."
          % (args.port, args.diag_port))
    on_subnet = check_network(args.oar, args.port)
    if args.no_hello:
        print("--no-hello: measuring the broadcast fallback, which loses about 7%")
        print("and delivers in clumps.")
    elif on_subnet:
        print("Sending a hello to %s so the board unicasts (unicast is ACKed and"
              % args.oar)
        print("retransmitted; the broadcast fallback is not).")
        send_hello(data_sock, args.oar, args.port, announce=True)
    print("Ctrl-C to stop." if not args.seconds else "Running for %.0f s." % args.seconds)
    print("")

    started = time.monotonic()
    last_report = started
    last_hint = started
    last_hello = started
    hinted = False

    try:
        while not stop.is_set():
            time.sleep(0.25)
            now = time.monotonic()
            elapsed = now - started

            if now - last_report >= 1.0:
                report(link, started, elapsed, last_report, args.quiet)
                last_report = now

            if not args.no_hello and now - last_hello >= HELLO_INTERVAL_SEC:
                last_hello = now
                send_hello(data_sock, args.oar, args.port)

            if link.packets == 0 and now - last_hint >= 10.0:
                last_hint = now
                if not hinted:
                    hinted = True
                    print(HINTS)
                else:
                    print("  ... still nothing (%.0f s)." % elapsed)

            if args.seconds and elapsed >= args.seconds:
                break
    except KeyboardInterrupt:
        print("\nStopped.")

    stop.set()
    elapsed = time.monotonic() - started
    got_data = summary(link, elapsed, args.quiet)

    data_sock.close()
    diag_sock.close()
    return 0 if got_data else 1


if __name__ == "__main__":
    sys.exit(main())
