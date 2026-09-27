// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! The host helper: helper.py, run on another machine, for the tests that
//! need a peer on the network. Its control channel is a TCP connection to
//! port 8700 that answers `OK` on connecting; on `CONNECT <port>` the
//! helper connects to this machine at that port, sends a greeting, and
//! answers `GO`; `QUIT` ends it. Beside it, 8701 echoes a TCP stream,
//! 8702 echoes UDP datagrams, and 8703 takes a TCP stream and drops it.

const sdk = @import("sdk");
const bsd = sdk.bsdsocket;
const Run = @import("run.zig").Run;

/// The helper's ports.
pub const control_port: u16 = 8700;
pub const tcp_echo_port: u16 = 8701;
pub const udp_echo_port: u16 = 8702;
pub const tcp_sink_port: u16 = 8703;

pub const Helper = struct {
    /// The control channel, or -1.
    control: i32 = -1,
    /// The helper's address, in network order.
    address: u32 = 0,
    connected: bool = false,

    /// The control channel opened to `host`, a dotted address or a name:
    /// true when the helper answered.
    pub fn connect(helper: *Helper, run: *Run, host: [*:0]const u8) bool {
        const sb = run.sb;
        var address = sb.Inet_Addr(host);
        if (address == bsd.INADDR_NONE) {
            const entry = sb.GetHostByName(host) orelse {
                run.tap.diag("  helper: cannot resolve \"%s\"", .{host});
                return false;
            };
            const first = entry.h_addr_list.?[0].?;
            address = @as(*align(1) const u32, @ptrCast(first)).*;
        }
        helper.address = address;

        const descriptor = run.tcpSocket();
        if (descriptor < 0) {
            run.tap.diag("  helper: cannot create a socket", .{});
            return false;
        }
        const to = helper.at(control_port);
        if (sb.Connect(descriptor, to.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) {
            run.tap.diag("  helper: connect failed, errno=%d", .{run.errno()});
            run.close(descriptor);
            return false;
        }
        run.setReceiveTimeout(descriptor, 5);
        var line: [64]u8 = undefined;
        const length = receiveLine(run, descriptor, &line);
        if (length != 2 or line[0] != 'O' or line[1] != 'K') {
            run.tap.diag("  helper: expected OK, got \"%s\" (length %d, errno=%d)", .{ @as([*:0]const u8, @ptrCast(&line)), length, run.errno() });
            run.close(descriptor);
            return false;
        }
        helper.control = descriptor;
        helper.connected = true;
        return true;
    }

    /// The helper's address at `port`.
    pub fn at(helper: *const Helper, port: u16) bsd.sockaddr_in {
        return .{ .sin_port = bsd.htons(port), .sin_addr = .{ .s_addr = helper.address } };
    }

    /// A stream socket connected to one of the helper's services: its
    /// descriptor, or -1.
    pub fn service(helper: *Helper, run: *Run, port: u16) i32 {
        if (!helper.connected) return -1;
        const descriptor = run.tcpSocket();
        if (descriptor < 0) return -1;
        const to = helper.at(port);
        if (run.sb.Connect(descriptor, to.anyConst(), @sizeOf(bsd.sockaddr_in)) < 0) {
            run.tap.diag("  helper service %u: errno=%d", .{ @as(u32, port), run.errno() });
            run.close(descriptor);
            return -1;
        }
        return descriptor;
    }

    /// The helper asked to connect to this machine at `port`: true when
    /// it answered GO.
    pub fn requestConnect(helper: *Helper, run: *Run, port: u16) bool {
        if (!helper.connected) return false;
        var command: [16]u8 = undefined;
        const prefix = "CONNECT ";
        @memcpy(command[0..prefix.len], prefix);
        var length: usize = prefix.len;
        var digits: [5]u8 = undefined;
        var count: usize = 0;
        var rest = port;
        while (true) {
            digits[count] = '0' + @as(u8, @intCast(rest % 10));
            count += 1;
            rest /= 10;
            if (rest == 0) break;
        }
        while (count > 0) {
            count -= 1;
            command[length] = digits[count];
            length += 1;
        }
        command[length] = '\n';
        length += 1;
        if (run.sb.Send(helper.control, &command, @intCast(length), 0) != length) return false;
        var line: [64]u8 = undefined;
        const got = receiveLine(run, helper.control, &line);
        return got == 2 and line[0] == 'G' and line[1] == 'O';
    }

    /// The control channel closed.
    pub fn quit(helper: *Helper, run: *Run) void {
        if (helper.connected) {
            _ = run.sb.Send(helper.control, "QUIT\n", 5, 0);
            run.close(helper.control);
        }
        helper.control = -1;
        helper.connected = false;
    }
};

/// One line from the control channel into `line`, without its CR and LF
/// and ended by a NUL: its length, 0 at the end, -1 on an error.
fn receiveLine(run: *Run, descriptor: i32, line: []u8) i32 {
    var used: usize = 0;
    line[0] = 0;
    while (used < line.len - 1) {
        var character: u8 = 0;
        const got = run.sb.Recv(descriptor, &character, 1, 0);
        if (got <= 0) {
            line[used] = 0;
            return if (got == 0 and used > 0) @intCast(used) else got;
        }
        if (character == '\n') break;
        if (character != '\r') {
            line[used] = character;
            used += 1;
        }
    }
    line[used] = 0;
    return @intCast(used);
}
