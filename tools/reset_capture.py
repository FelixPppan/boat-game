#!/usr/bin/env python3
"""Reset the ESP32 over DTR/RTS and capture what it prints from the very first line.

Why this exists next to serial_probe.py
---------------------------------------
serial_probe.py reads the port, and opening the port does NOT reset the board.
So a plain capture always starts somewhere in the middle of a sketch's output and
misses everything setup() printed -- which is the only place the sensor's init
result is stated. On 2026-09-25 that difference was the whole diagnosis: the
running sketch's data lines were the same either way, and only the boot capture
revealed the retry message that named the actual fault.

It is also the only way to see what a board does from a cold start, which is what
the oar actually does when it is plugged in. A capture taken after the board has
already been running proves nothing about that.

How
---
The ESP32's auto-reset circuit hangs off the two modem-control lines of the
serial port: RTS drives EN, DTR drives IO0. Holding IO0 high while pulsing EN low
reboots it into a normal run (IO0 low would be the flash-download mode instead).
Both are driven through ioctl because termios has no notion of them.

Usage
-----
    python3 tools/reset_capture.py                       # autodetect, 6 s
    python3 tools/reset_capture.py /dev/cu.usbserial-10 12

Then read it the way you would any other capture: the "[SensorInput]" and "#"
lines are the part that says what the firmware thinks it is doing.
"""
import fcntl
import os
import struct
import sys
import termios
import time

# Must match the sketch's Serial.begin(), or the capture is garbage. This is the
# one dial that makes the difference between readable text and noise.
BAUD = 115200

# Modem-control bits. Named here because termios exports TIOCMBIS/TIOCMBIC (set
# and clear these bits) but not the bits themselves on every platform.
TIOCM_DTR = 0x002
TIOCM_RTS = 0x004

# Long enough for the ESP32's ROM bootloader, the second-stage loader and the
# sketch's own `delay(1000)` to all get their say.
DEFAULT_SECONDS = 6.0


def set_lines(fd: int, dtr: bool, rts: bool) -> None:
    """Drive DTR and RTS to the given levels."""
    for bit, on in ((TIOCM_DTR, dtr), (TIOCM_RTS, rts)):
        # The kernel wants a POINTER to the bit mask here. Passing a plain int
        # raises OSError: [Errno 14] Bad address, which reads like a permissions
        # problem and is not one.
        fcntl.ioctl(fd,
                    termios.TIOCMBIS if on else termios.TIOCMBIC,
                    struct.pack("I", bit))


def autodetect() -> str:
    """First USB serial port, preferring the /dev/cu. name.

    cu. and tty. are the same device; cu. is the one that does not block waiting
    for carrier detect, so cu. is what everything here uses.
    """
    candidates = sorted(
        name for name in os.listdir("/dev") if name.startswith("cu.usbserial")
    )
    if not candidates:
        raise SystemExit(
            "no /dev/cu.usbserial* found -- is the board plugged in? "
            "(a charge-only cable looks exactly like this)"
        )
    return os.path.join("/dev", candidates[0])


def configure(fd: int) -> None:
    """Raw 8N1 at BAUD, non-blocking, no flow control.

    Done on THIS fd rather than with `stty`: on macOS the port settings belong to
    an open file descriptor, so `stty -f PORT 115200` opens, sets and closes --
    and closing the last fd makes the driver reset the port to 9600. See
    memory: serial-port-reading.
    """
    iflag, oflag, cflag, lflag, _ispeed, _ospeed, cc = termios.tcgetattr(fd)
    iflag = oflag = lflag = 0
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL
    cc = list(cc)
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW,
                      [iflag, oflag, cflag, lflag, BAUD, BAUD, cc])
    termios.tcflush(fd, termios.TCIOFLUSH)


def reset_board(fd: int) -> None:
    """Pulse EN low and release it with IO0 high, i.e. a normal reboot."""
    set_lines(fd, dtr=False, rts=False)
    time.sleep(0.05)
    set_lines(fd, dtr=False, rts=True)    # EN low: held in reset
    time.sleep(0.15)
    set_lines(fd, dtr=False, rts=False)   # EN released: boots, IO0 high


def capture(fd: int, seconds: float) -> bytes:
    """Read until the deadline, sleeping only when there is nothing to read."""
    deadline = time.time() + seconds
    out = bytearray()
    while time.time() < deadline:
        try:
            chunk = os.read(fd, 4096)
        except BlockingIOError:
            chunk = b""
        if chunk:
            out += chunk
        else:
            time.sleep(0.01)
    return bytes(out)


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    port = args[0] if args else autodetect()
    seconds = float(args[1]) if len(args) > 1 else DEFAULT_SECONDS

    print(f"# resetting {port} and capturing {seconds:.0f} s from the boot banner"
          f" @ {BAUD} baud", file=sys.stderr)

    fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        configure(fd)
        reset_board(fd)
        raw = capture(fd, seconds)
    finally:
        os.close(fd)

    # The ROM banner ends its lines with \r\n; normalising keeps the output
    # diffable against a capture from any other tool.
    sys.stdout.write(raw.decode("utf-8", "replace").replace("\r\n", "\n"))


if __name__ == "__main__":
    main()
