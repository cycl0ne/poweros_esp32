#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""A serial terminal for the board.

    scripts/term.py                          talk to it; Ctrl-] quits
    scripts/term.py --listen 20              just watch, for a boot that goes wrong
    scripts/term.py --line newshell --line info --settle 4
                                             feed it lines and print what came back

Both of the board's USB-C ports appear as /dev/ttyACM*, and which number
each gets swaps between plug-ins, so --port names them by what they are:
"native" (the chip's own USB-Serial-JTAG, the default) or "uart" (the CH343
bridge on UART0). A device path still works.

Prefer the native port. The shell's echo is clean there, and it carries the
ROM's boot messages and the shell. UART0 also carries the shell, but the
kernel's status lines (kprintf) go out on it as well, so the two interleave.

Four things this gets right, each of which cost an evening once:

- DTR and RTS are cleared *before* the port is opened. The CH343's lines
  drive the board's reset circuit, so opening it with them asserted resets
  the chip - and the chip's own USB port then drops and re-enumerates.
- HUPCL is cleared once the port is open, so closing the terminal does not
  drop those lines and reset the board on the way out.
- Typed bytes go out one at a time. The console handler reads one byte per
  request, and a burst can outrun it.
- The native port drops and re-enumerates whenever the chip resets, so a
  SerialException is not the end: it waits for the port to come back.
"""

import argparse
import errno
import glob
import os
import sys
import time

import serial

QUIT = b"\x1d"  # Ctrl-]

# The two ports the board shows up as, by what they are rather than by the
# number Linux happened to give them this time - they swap.
PORTS = {
    "native": ("303a", "1001"),  # the chip's own USB-Serial-JTAG
    "uart": ("1a86", "55d3"),    # the CH343 bridge on UART0
}


def find_port(want):
    """The device node of `want`, or `want` itself if it is already a path.

    Prefer "native". Opening the CH343 drives the board's reset circuit, so
    the chip resets and its USB port drops and comes back; the native port
    leaves it running, and carries the shell without the kernel's status
    lines interleaved.
    """
    if want.startswith("/") or want not in PORTS:
        return want
    vid, pid = PORTS[want]
    for path in sorted(glob.glob("/dev/ttyACM*") + glob.glob("/dev/ttyUSB*")):
        base = "/sys/class/tty/%s/device/.." % os.path.basename(path)
        try:
            with open(base + "/idVendor") as f:
                have_vid = f.read().strip()
            with open(base + "/idProduct") as f:
                have_pid = f.read().strip()
        except OSError:
            continue
        if (have_vid, have_pid) == (vid, pid):
            return path
    raise SystemExit("[no %s port (%s:%s) is plugged in]" % (want, vid, pid))


def open_port(path, baud, wait=True):
    """The port, once it is there. DTR and RTS are cleared before opening."""
    first = True
    while True:
        try:
            s = serial.Serial()
            s.port = path
            s.baudrate = baud
            s.dtr = False
            s.rts = False
            s.timeout = 0.05
            s.open()
            keep_lines(s)
            return s
        except (serial.SerialException, OSError) as e:
            if not wait:
                raise
            if first:
                sys.stderr.write("[waiting for %s: %s]\n" % (path, e))
                first = False
            time.sleep(0.3)


def keep_lines(s):
    """Stop the close dropping DTR and RTS.

    On the chip's native USB port RTS is wired to EN, so a terminal that
    lets the line fall on close resets the board on its way out - and the
    next open resets it again on its way in. Clearing HUPCL leaves the
    lines where they are, so only the open pulses and a session that ends
    leaves the board running.
    """
    try:
        import termios
        fd = s.fileno()
        attrs = termios.tcgetattr(fd)
        attrs[2] &= ~termios.HUPCL  # cflag
        termios.tcsetattr(fd, termios.TCSANOW, attrs)
    except Exception:
        pass  # not a tty, or the platform has no HUPCL: nothing to keep


def drain(s, out, seconds):
    """Everything the board says for that long, onto `out`."""
    end = time.time() + seconds
    while time.time() < end:
        try:
            got = s.read(256)
        except (serial.SerialException, OSError):
            return False
        if got:
            out.write(got.decode("latin-1"))
            out.flush()
    return True


def feed(args):
    """Send each line, print what comes back. For scripted rounds."""
    s = open_port(args.port, args.baud)
    out = sys.stdout
    try:
        drain(s, out, args.before)
        for line in args.line:
            text = line.encode("latin-1") + b"\r"
            for b in text:  # one byte at a time
                try:
                    s.write(bytes([b]))
                    s.flush()
                except (serial.SerialException, OSError):
                    sys.stderr.write("\n[port dropped while writing]\n")
                    s = open_port(args.port, args.baud)
                    break
                time.sleep(args.pace)
            if not drain(s, out, args.delay):
                sys.stderr.write("\n[port dropped; waiting for it]\n")
                s = open_port(args.port, args.baud)
        drain(s, out, args.settle)
    finally:
        s.close()
    return 0


def listen(args, seconds):
    """Just watch. What a boot that never reaches a prompt needs."""
    s = open_port(args.port, args.baud)
    try:
        drain(s, sys.stdout, seconds)
    finally:
        s.close()
    sys.stderr.write("\n[listened %g s]\n" % seconds)
    return 0


def interactive(args):
    """A terminal. Ctrl-] quits. Without a terminal to type at, it watches."""
    import termios
    import tty

    if not sys.stdin.isatty():
        # Piped or redirected: there is nothing to type with, so watch
        # instead of dying in tcgetattr.
        return listen(args, args.settle)

    s = open_port(args.port, args.baud)
    stdin = sys.stdin.fileno()
    saved = termios.tcgetattr(stdin)
    sys.stderr.write("[%s %d, Ctrl-] quits]\n" % (args.port, args.baud))
    try:
        tty.setraw(stdin)
        os.set_blocking(stdin, False)
        while True:
            try:
                got = s.read(256)
            except (serial.SerialException, OSError):
                sys.stderr.write("\r\n[port dropped; waiting for it]\r\n")
                try:
                    s.close()
                except Exception:
                    pass
                s = open_port(args.port, args.baud)
                continue
            if got:
                sys.stdout.write(got.decode("latin-1"))
                sys.stdout.flush()
            try:
                typed = os.read(stdin, 64)
            except OSError as e:
                if e.errno not in (errno.EAGAIN, errno.EWOULDBLOCK):
                    raise
                typed = b""
            if not typed:
                continue
            if QUIT in typed:
                typed = typed[: typed.index(QUIT)]
                if typed:
                    s.write(typed)
                break
            for b in typed:  # one byte at a time
                try:
                    s.write(bytes([b]))
                    s.flush()
                except (serial.SerialException, OSError):
                    break
                time.sleep(args.pace)
    finally:
        termios.tcsetattr(stdin, termios.TCSADRAIN, saved)
        os.set_blocking(stdin, True)
        try:
            s.close()
        except Exception:
            pass
        sys.stderr.write("\n")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", default="native",
                   help="native (the chip's USB port, the default), uart (the CH343), or a device path")
    p.add_argument("--baud", type=int, default=115200)
    p.add_argument("--line", action="append", default=[], help="a line to send (repeatable); no --line means a terminal")
    p.add_argument("--listen", type=float, default=0, help="seconds to watch without sending anything")
    p.add_argument("--before", type=float, default=1.0, help="seconds to listen before the first line")
    p.add_argument("--delay", type=float, default=2.0, help="seconds to listen after each line")
    p.add_argument("--settle", type=float, default=3.0, help="seconds to listen at the end")
    p.add_argument("--pace", type=float, default=0.002, help="seconds between typed bytes")
    args = p.parse_args()
    args.port = find_port(args.port)
    if args.listen:
        return listen(args, args.listen)
    return feed(args) if args.line else interactive(args)


if __name__ == "__main__":
    sys.exit(main())
