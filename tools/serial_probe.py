#!/usr/bin/env python3
"""serial_probe.py -- read the oar's serial port from a terminal, correctly.

Why a separate tool when `cat /dev/cu.usbserial-10` exists
---------------------------------------------------------
On macOS, a USB serial port is configured through termios, and termios belongs
to an OPEN FILE DESCRIPTOR. `stty -f PORT 115200` opens the port, sets the
rate, and closes it again -- and Apple's DriverKit serial driver resets the
port to its default 9600 when the last descriptor closes. So the next
`open()` gets 9600 no matter what stty was just told, and the stream arrives as
garbage. That failure is especially nasty because it is SILENT: the bytes still
arrive, they are just decoded at the wrong rate, so it looks like the device is
broken rather than like the reader is.

The fix is to set termios on the descriptor you are about to read from, which
is what this file does and what Scripts/sensor_input.gd gets for free from
gdserial.

    python3 tools/serial_probe.py                 # auto-detect, 5 seconds
    python3 tools/serial_probe.py -s 15           # longer window
    python3 tools/serial_probe.py --raw           # hex dump instead of text
    python3 tools/serial_probe.py -p /dev/cu.usbserial-10 -b 115200

macOS 下串口是通过 termios 配置的,而 termios 属于「一个打开着的文件描述符」。
`stty -f PORT 115200` 会打开端口、设置速率、再关掉 —— 而 Apple 的 DriverKit 串口驱动
在最后一个描述符关闭时会把端口复位回默认的 9600。于是下一次 `open()` 拿到的还是 9600,
不管 stty 刚刚被告知了什么,数据就变成乱码。这个故障尤其阴险,因为它是**静默**的:
字节照样到,只是按错的速率解码,看上去像设备坏了,而不是像读的人弄错了。
正确做法是在「你即将读的那个描述符」上设 termios,也就是这个文件做的事,
而 Scripts/sensor_input.gd 通过 gdserial 免费得到了同样的效果。

用法:
    python3 tools/serial_probe.py                 # 自动检测,5 秒
    python3 tools/serial_probe.py -s 15           # 更长的窗口
    python3 tools/serial_probe.py --raw           # 十六进制转储而不是文本
    python3 tools/serial_probe.py -p /dev/cu.usbserial-10 -b 115200
"""

import argparse
import os
import re
import sys
import termios
import time

# ----------------------------------------------- Config / 配置 -------------
## Where to look if no port is given. The device is a CH340 (WCH 0x1a86:0x7523)
## so it comes up as /dev/cu.usbserial-*, but usbmodem covers the Arduino-style
## boards too, in case the oar is swapped back.
## 不给端口时去哪里找。设备是 CH340(WCH 0x1a86:0x7523),所以出现为
## /dev/cu.usbserial-*;usbmodem 是给 Arduino 那种板子留的,万一把桨换回去。
PORT_PATTERNS = ("/dev/cu.usbserial", "/dev/cu.usbmodem", "/dev/cu.SLAB_USBtoUART")

## The new sensor's rate. 115200 is what the ADXL345 sketch used and what this
## one turned out to use as well, but it is a parameter rather than a constant
## because that is exactly the thing that goes wrong silently.
## 新传感器的波特率。115200 是 ADXL345 那版用的,这个也恰好是 —— 但它是参数不是常量,
## 因为「这里弄错」正是那种会静默出错的事。
DEFAULT_BAUD = 115200

## Matches the new sensor's line:
##   Accel(g): 0.000, 0.000, 0.000 | Gyro(deg/s): 0.000, 0.000, 0.000
## Kept as one regex with six groups rather than two, so a line that carries
## only half the pair is treated as unparsed instead of as valid data.
## 匹配新传感器的那一行。<用一整条正则配六个分组,而不是拆成两条> —— 这样只带了一半的
## 残行会被当成「没解析出来」,而不是被当成有效数据。
IMU_RE = re.compile(
    r"Accel\(g\):\s*(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)"
    r"\s*\|\s*Gyro\(deg/s\):\s*(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)"
)

## The old sensor's line: three bare comma-separated numbers, no labels.
## 旧传感器的那一行:三个裸的逗号分隔数字,没有标签。
XYZ_RE = re.compile(r"^\s*(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\s*$")


def find_port() -> str:
    for prefix in PORT_PATTERNS:
        names = sorted(n for n in os.listdir("/dev") if ("/dev/" + n).startswith(prefix))
        if names:
            # cu. opens more reliably than tty. on macOS; prefer it when both
            # spellings exist for the same device.
            # cu. 在 macOS 上比 tty. 开得更可靠;同一设备两种写法都在时优先 cu.。
            for n in names:
                if n.startswith("cu."):
                    return "/dev/" + n
            return "/dev/" + names[0]
    return ""


def open_configured(port: str, baud: int) -> int:
    """Open the port and set its line discipline, returning the descriptor.

    The whole point of this function is the ordering: termios is applied to a
    descriptor that is already open and is the one that will be read, so
    nothing can reset it in between.

    打开端口、设好它的线路规程,返回该描述符。这个函数的全部要点就在顺序:termios 作用在
    一个已经打开、而且就是要被读的那个描述符上,中间没有任何东西能把它复位。
    """
    fd = os.open(port, os.O_RDWR | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0                                        # iflag: no translation
    # iflag: 不做任何转换
    attrs[1] = 0                                        # oflag: no translation
    # oflag: 不做任何转换
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0                                        # lflag: raw
    # lflag: 原始
    attrs[4] = baud                                     # ispeed
    # ispeed: 输入速率
    attrs[5] = baud                                     # ospeed
    # ospeed: 输出速率
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def read_for(fd: int, seconds: float) -> bytes:
    buf = b""
    t0 = time.time()
    while time.time() - t0 < seconds:
        try:
            chunk = os.read(fd, 8192)
        except BlockingIOError:
            time.sleep(0.002)
            continue
        except OSError:
            break
        if chunk:
            buf += chunk
        else:
            time.sleep(0.002)
    return buf


def dump_raw(buf: bytes) -> None:
    for i in range(0, len(buf), 16):
        row = buf[i:i + 16]
        print("  %04x  %-47s  %s" % (
            i,
            " ".join("%02x" % x for x in row),
            "".join(chr(x) if 32 <= x < 127 else "." for x in row)))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-p", "--port", default="", help="serial port (default: auto-detect)")
    ap.add_argument("-b", "--baud", type=int, default=DEFAULT_BAUD)
    ap.add_argument("-s", "--seconds", type=float, default=5.0)
    ap.add_argument("--raw", action="store_true", help="hex dump instead of parsed lines")
    args = ap.parse_args()

    port = args.port or find_port()
    if not port:
        print("no serial port found (looked for %s)" % ", ".join(PORT_PATTERNS),
              file=sys.stderr)
        return 1
    if not os.path.exists(port):
        print("no such port: %s" % port, file=sys.stderr)
        return 1

    print("port %s @ %d baud, %.1f s" % (port, args.baud, args.seconds))
    fd = open_configured(port, args.baud)
    try:
        buf = read_for(fd, args.seconds)
    finally:
        os.close(fd)

    if not buf:
        print("  (nothing arrived -- is the sketch running? is another program "
              "holding the port, e.g. the Arduino IDE Serial Monitor?)")
        return 1

    if args.raw:
        print("  %d bytes (hex dump)" % len(buf))
        dump_raw(buf)
        return 0

    text = buf.decode("ascii", "replace")
    print("  %d bytes, %.1f B/s" % (len(buf), len(buf) / args.seconds))

    lines = text.split("\n")
    # The final element is a partial line unless the capture ended exactly on a
    # newline, so it is dropped rather than parsed -- a half line that happened
    # to parse would be counted as a real sample.
    # 最后一个元素是半行,除非采集正好停在一个换行上,所以它被丢掉而不是拿去解析 ——
    # 一个碰巧能解析的半行会被当成真样本。
    complete = lines[:-1] if lines else []

    imu, xyz, junk = 0, 0, 0
    first_imu = None
    for line in complete:
        line = line.strip()
        if not line:
            continue
        m = IMU_RE.search(line)
        if m:
            imu += 1
            if first_imu is None:
                first_imu = [float(x) for x in m.groups()]
            continue
        m = XYZ_RE.match(line)
        if m:
            xyz += 1
            if first_imu is None:
                first_imu = [float(x) for x in m.groups()]
            continue
        junk += 1

    n = imu + xyz
    print("  %d line(s): %d imu, %d xyz, %d unparsed" % (len(complete), imu, xyz, junk))
    if n:
        print("  %.2f lines/s" % (n / args.seconds))
    if first_imu is not None:
        print("  first sample: %s" % ", ".join("%.4f" % v for v in first_imu))
    if junk:
        for line in complete:
            if line.strip() and not IMU_RE.search(line) and not XYZ_RE.match(line.strip()):
                print("  unparsed: %r" % line)
                break
    if n == 0:
        print("  the port is delivering bytes but no line matched either format --"
              " the baud is probably wrong (try -b 9600 / -b 57600)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
