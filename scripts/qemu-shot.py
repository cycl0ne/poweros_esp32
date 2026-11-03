#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""A picture of the machine running in QEMU, through its QMP monitor.

    scripts/qemu-shot.py desktop.png            what is on the display now
    scripts/qemu-shot.py --click 832,1057 --settle 2 dock.png
                                                click there first, then wait, then shoot
    scripts/qemu-shot.py --key d --key i --key r --key ret shell.png
                                                type into it, then shoot

The machine must have been started with a QMP monitor on a socket -
`scripts/qemu-web.sh` opens one, and so does any display step given
`-Dvirt-qmp=<socket>`. The default socket is the one qemu-web.sh uses,
work/qemu.qmp.

A click is a place on the display in pixels, as the picture shows it.
The machine's pointer is a USB tablet, which says where it is rather
than how far it moved, over a range of its own; the display's size,
taken from a first picture, turns the one into the other. A key is one
of QEMU's key names (a, ret, spc, f1, ctrl, ...); names joined with
`-`, as in `ctrl-alt-f1`, are pressed together.
"""

import argparse
import json
import os
import socket
import struct
import sys
import tempfile
import time

# The range a USB tablet says its pointer's place in, whatever the
# display's size is.
TABLET_RANGE = 32768


class Monitor:
    """QEMU's QMP monitor on a Unix socket: a command, and its answer."""

    def __init__(self, path):
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(20)
        self.socket.connect(path)
        self.stream = self.socket.makefile("rw", encoding="utf-8", newline="\n")
        self.stream.readline()  # the greeting
        self.ask("qmp_capabilities")

    def ask(self, command, **arguments):
        self.stream.write(json.dumps({"execute": command, "arguments": arguments}
                                     if arguments else {"execute": command}) + "\n")
        self.stream.flush()
        while True:
            answer = json.loads(self.stream.readline())
            if "event" in answer:  # something happened meanwhile; not an answer
                continue
            if "error" in answer:
                raise SystemExit("qemu: " + answer["error"].get("desc", str(answer["error"])))
            return answer

    def picture(self, path):
        self.ask("screendump", filename=os.path.abspath(path), format="png")

    def size(self):
        """The display's width and height, read from a picture of it."""
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "size.png")
            self.picture(path)
            with open(path, "rb") as picture:
                header = picture.read(24)
        # PNG: 8 bytes of signature, the IHDR chunk's length and name,
        # then the width and the height as 32-bit numbers.
        return struct.unpack(">II", header[16:24])

    def click(self, x, y, width, height):
        self.ask("input-send-event", events=[
            {"type": "abs", "data": {"axis": "x", "value": x * (TABLET_RANGE - 1) // width}},
            {"type": "abs", "data": {"axis": "y", "value": y * (TABLET_RANGE - 1) // height}},
        ])
        for down in (True, False):
            self.ask("input-send-event", events=[{"type": "btn", "data": {"down": down, "button": "left"}}])

    def key(self, name):
        self.ask("send-key", keys=[{"type": "qcode", "data": part} for part in name.split("-")])


def place(text):
    try:
        x, y = text.split(",")
        return int(x), int(y)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text} is not a place, such as 832,1057")


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("picture", help="the PNG file to write")
    parser.add_argument("--socket", default=os.path.join(here, "work", "qemu.qmp"),
                        help="the machine's QMP socket (default: work/qemu.qmp)")
    parser.add_argument("--click", type=place, metavar="X,Y", help="click there before the picture is taken")
    parser.add_argument("--key", action="append", default=[], metavar="NAME",
                        help="press that key before the picture is taken; may be given more than once")
    parser.add_argument("--settle", type=float, default=1.0, metavar="SECONDS",
                        help="wait this long after the clicks and keys (default: 1)")
    what = parser.parse_args()

    try:
        monitor = Monitor(what.socket)
    except OSError as trouble:
        raise SystemExit(f"no machine at {what.socket}: {trouble}")

    if what.click or what.key:
        if what.click:
            width, height = monitor.size()
            monitor.click(what.click[0], what.click[1], width, height)
        for name in what.key:
            monitor.key(name)
        time.sleep(what.settle)

    monitor.picture(what.picture)
    print(what.picture)


if __name__ == "__main__":
    sys.exit(main())
