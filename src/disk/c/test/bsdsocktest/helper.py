#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 Thomas Dye
"""
helper.py -- the host helper for BsdSockTest's network tests.

Provides passive services (echo, sink, source) and active coordination
(connect-to-Amiga) via a line-based control channel.

Services (port offsets from --ctrl-port):
  ctrl+0  Control channel (TCP) — protocol commands
  ctrl+1  TCP echo server — echoes received data back
  ctrl+2  UDP echo server — echoes datagrams back
  ctrl+3  TCP sink server — receives and discards data
  ctrl+4  TCP source server — sends test pattern data until close

Usage:
  python3 helper.py [-v] [--bind ADDR] [--ctrl-port PORT]
"""

import argparse
import selectors
import socket
import struct
import sys
import time

# Default ports (must match helper.zig)
DEFAULT_CTRL_PORT = 8700


def log(msg, verbose_only=False):
    """Log to stderr."""
    if verbose_only and not log.verbose:
        return
    print(f"[helper] {msg}", file=sys.stderr, flush=True)

log.verbose = False


def fill_test_pattern(length, seed):
    """Generate the same test pattern as fillPattern in run.zig.
    LCG: seed = seed * 1103515245 + 12345, take bits 16-23."""
    result = bytearray(length)
    s = seed
    for i in range(length):
        s = (s * 1103515245 + 12345) & 0xFFFFFFFF
        result[i] = (s >> 16) & 0xFF
    return bytes(result)


class Helper:
    """Main helper server managing all services and control connections."""

    def __init__(self, bind_addr, ctrl_port):
        self.bind_addr = bind_addr
        self.ctrl_port = ctrl_port
        self.sel = selectors.DefaultSelector()
        self.amiga_ip = None
        self.ctrl_conn = None
        self.ctrl_buf = b""
        self.listeners = []
        self._sink_totals = {}      # fd -> bytes received
        self._source_state = {}     # fd -> (offset, pattern)

    def start(self):
        """Start all listeners."""
        # Control channel
        self._listen_tcp(self.ctrl_port, self._accept_ctrl)
        # TCP echo
        self._listen_tcp(self.ctrl_port + 1, self._accept_echo)
        # UDP echo
        self._listen_udp(self.ctrl_port + 2, self._handle_udp_echo)
        # TCP sink
        self._listen_tcp(self.ctrl_port + 3, self._accept_sink)
        # TCP source
        self._listen_tcp(self.ctrl_port + 4, self._accept_source)

        log(f"Listening on {self.bind_addr}")
        log(f"  Control:    port {self.ctrl_port}")
        log(f"  TCP echo:   port {self.ctrl_port + 1}")
        log(f"  UDP echo:   port {self.ctrl_port + 2}")
        log(f"  TCP sink:   port {self.ctrl_port + 3}")
        log(f"  TCP source: port {self.ctrl_port + 4}")

    def run(self):
        """Main event loop."""
        try:
            while True:
                events = self.sel.select(timeout=1.0)
                for key, mask in events:
                    callback = key.data
                    callback(key.fileobj, mask)
        except KeyboardInterrupt:
            log("Shutting down (Ctrl-C)")
        finally:
            self._cleanup()

    def _listen_tcp(self, port, accept_callback):
        """Create a TCP listener."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((self.bind_addr, port))
        sock.listen(5)
        sock.setblocking(False)
        self.sel.register(sock, selectors.EVENT_READ, accept_callback)
        self.listeners.append(sock)

    def _listen_udp(self, port, handler):
        """Create a UDP listener."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((self.bind_addr, port))
        sock.setblocking(False)
        self.sel.register(sock, selectors.EVENT_READ, handler)
        self.listeners.append(sock)

    # ---- Control channel ----

    def _accept_ctrl(self, sock, mask):
        conn, addr = sock.accept()
        conn.setblocking(False)

        if self.ctrl_conn is not None:
            log(f"New control connection from {addr[0]}:{addr[1]}, "
                f"closing previous")
            self._close_ctrl()

        self.amiga_ip = addr[0]
        self.ctrl_conn = conn
        self.ctrl_buf = b""
        log(f"Control connection from {self.amiga_ip}:{addr[1]}")

        # Send OK
        try:
            conn.sendall(b"OK\n")
        except OSError as e:
            log(f"Error sending OK: {e}")
            self._close_ctrl()
            return

        self.sel.register(conn, selectors.EVENT_READ, self._handle_ctrl)

    def _handle_ctrl(self, sock, mask):
        try:
            data = sock.recv(1024)
        except OSError:
            data = b""

        if not data:
            log("Control connection closed by Amiga")
            self._close_ctrl()
            return

        self.ctrl_buf += data
        while b"\n" in self.ctrl_buf:
            line, self.ctrl_buf = self.ctrl_buf.split(b"\n", 1)
            line = line.strip().decode("ascii", errors="replace")
            self._process_ctrl_command(line)

    def _process_ctrl_command(self, line):
        log(f"Control command: {line}", verbose_only=True)

        if line.startswith("CONNECT "):
            try:
                port = int(line.split()[1])
            except (IndexError, ValueError):
                self._ctrl_send("FAIL bad port\n")
                return
            self._handle_connect(port)

        elif line == "QUIT":
            log("QUIT received, closing control connection")
            self._close_ctrl()

        else:
            log(f"Unknown command: {line}")
            self._ctrl_send(f"FAIL unknown command\n")

    def _handle_connect(self, port):
        """Handle CONNECT command: connect to Amiga on the specified port."""
        if not self.amiga_ip:
            self._ctrl_send("FAIL no Amiga IP\n")
            return

        log(f"CONNECT to {self.amiga_ip}:{port}", verbose_only=True)
        self._ctrl_send("GO\n")

        # Sleep to let Amiga set up its listener
        time.sleep(0.5)

        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(5.0)
            s.connect((self.amiga_ip, port))
            s.sendall(b"BSDSOCKTEST HELLO FROM HELPER\n")
            s.close()
            log(f"CONNECT to {self.amiga_ip}:{port} completed",
                verbose_only=True)
        except OSError as e:
            log(f"CONNECT to {self.amiga_ip}:{port} failed: {e}")

    def _ctrl_send(self, msg):
        if self.ctrl_conn:
            try:
                self.ctrl_conn.sendall(msg.encode("ascii"))
            except OSError:
                pass

    def _close_ctrl(self):
        if self.ctrl_conn:
            try:
                self.sel.unregister(self.ctrl_conn)
            except (KeyError, ValueError):
                pass
            try:
                self.ctrl_conn.close()
            except OSError:
                pass
            self.ctrl_conn = None
            self.amiga_ip = None
            self.ctrl_buf = b""

    # ---- TCP echo ----

    def _accept_echo(self, sock, mask):
        conn, addr = sock.accept()
        # Keep echo connections blocking — sendall() needs to block when
        # the TCP send buffer fills (Amiga sends all data before reading).
        log(f"Echo connection from {addr[0]}:{addr[1]}", verbose_only=True)
        self.sel.register(conn, selectors.EVENT_READ, self._handle_echo)

    def _handle_echo(self, sock, mask):
        try:
            data = sock.recv(8192)
        except OSError:
            data = b""

        if not data:
            log("Echo connection closed", verbose_only=True)
            self.sel.unregister(sock)
            sock.close()
            return

        try:
            sock.sendall(data)
        except OSError:
            self.sel.unregister(sock)
            sock.close()

    # ---- UDP echo ----

    def _handle_udp_echo(self, sock, mask):
        try:
            data, addr = sock.recvfrom(65536)
        except OSError:
            return

        log(f"UDP echo: {len(data)} bytes from {addr[0]}:{addr[1]}",
            verbose_only=True)

        try:
            sock.sendto(data, addr)
        except OSError as e:
            log(f"UDP echo sendto failed: {e}", verbose_only=True)

    # ---- TCP sink ----

    def _accept_sink(self, sock, mask):
        conn, addr = sock.accept()
        conn.setblocking(False)
        log(f"Sink connection from {addr[0]}:{addr[1]}", verbose_only=True)
        self._sink_totals[conn.fileno()] = 0
        self.sel.register(conn, selectors.EVENT_READ, self._handle_sink)

    def _handle_sink(self, sock, mask):
        try:
            data = sock.recv(65536)
        except OSError:
            data = b""

        fd = sock.fileno()
        if not data:
            total = self._sink_totals.pop(fd, 0)
            log(f"Sink connection closed ({total} bytes received)",
                verbose_only=True)
            self.sel.unregister(sock)
            sock.close()
            return

        self._sink_totals[fd] = self._sink_totals.get(fd, 0) + len(data)

    # ---- TCP source ----

    def _accept_source(self, sock, mask):
        conn, addr = sock.accept()
        conn.setblocking(False)
        log(f"Source connection from {addr[0]}:{addr[1]}", verbose_only=True)
        pattern = fill_test_pattern(8192, 0xDEAD)
        self._source_state[conn.fileno()] = [0, pattern]
        # Register for write readiness
        self.sel.register(conn, selectors.EVENT_WRITE, self._handle_source)

    def _handle_source(self, sock, mask):
        fd = sock.fileno()
        state = self._source_state.get(fd)
        if not state:
            self.sel.unregister(sock)
            sock.close()
            return
        try:
            n = sock.send(state[1])
            state[0] += n
        except (OSError, BrokenPipeError):
            total = state[0]
            self._source_state.pop(fd, None)
            log(f"Source connection closed ({total} bytes sent)",
                verbose_only=True)
            self.sel.unregister(sock)
            sock.close()

    # ---- Cleanup ----

    def _cleanup(self):
        self._close_ctrl()
        for sock in self.listeners:
            try:
                self.sel.unregister(sock)
            except (KeyError, ValueError):
                pass
            sock.close()
        self.sel.close()


def main():
    parser = argparse.ArgumentParser(
        description="bsdsocktest host helper — provides network services "
                    "for Amiga bsdsocket.library conformance testing")
    parser.add_argument("--bind", default="0.0.0.0",
                        help="Bind address (default: 0.0.0.0)")
    parser.add_argument("--ctrl-port", type=int, default=DEFAULT_CTRL_PORT,
                        help=f"Control channel port (default: {DEFAULT_CTRL_PORT})")
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="Verbose logging")
    args = parser.parse_args()

    log.verbose = args.verbose

    helper = Helper(args.bind, args.ctrl_port)
    helper.start()
    helper.run()


if __name__ == "__main__":
    main()
