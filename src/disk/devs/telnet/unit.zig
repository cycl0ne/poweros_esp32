// SPDX-License-Identifier: MIT
//! A unit's task: the one connection's socket, taken from where
//! ShellServer left it, and every request of the unit served on it.
//!
//! **Waiting.** With a read waiting and nothing to hand it, the task
//! waits in WaitSelect for the socket and, beside it, for its request
//! port and its quit signal; otherwise in Wait for those two. So a read
//! is answered as soon as a byte comes, a write as soon as it is asked
//! for, and data nobody reads stays in the connection, where TCP holds
//! the peer back.
//!
//! **Its end.** CloseDevice signals it to quit. It answers what still
//! waits as aborted, closes the socket and its library, and ends; exec
//! tells CloseDevice once it is gone (SetTaskEndSignal), so the unit and
//! the stack it ran on can be freed at once. An Open that fails is told
//! the same way.

const sdk = @import("sdk");
const exec = sdk.exec;
const serial = sdk.devices.serial;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const _telnet = @import("_telnet.zig");
const Unit = _telnet.Unit;
const filter_file = @import("filter.zig");

/// The bytes one write is sent in, 255 doubled.
const write_chunk = 256;

pub fn unitTask(sys: *ExecBase) callconv(.c) void {
    const unit: *Unit = @fieldParentPtr("task", sys.FindTask(null).?);
    const port = &unit.unit.msg_port;
    const port_signal = sys.AllocSignal(-1);
    const quit_signal = sys.AllocSignal(-1);
    if (port_signal < 0 or quit_signal < 0) return;
    unit.quit_mask = @as(u32, 1) << @intCast(quit_signal);
    sys.Disable();
    port.sig_bit = @intCast(port_signal);
    port.sig_task = &unit.task;
    port.flags = exec.PA_SIGNAL;
    sys.Enable();

    const lib = sys.OpenLibrary(bsd.SOCKETNAME, 1) orelse return;
    const sb: *SocketBase = @ptrCast(lib);
    unit.socket_base = sb;
    unit.socket = sb.ObtainSocket(unit.id, bsd.PF_UNSPEC, bsd.SOCK_STREAM, 0);
    if (unit.socket < 0) {
        sys.CloseLibrary(lib);
        unit.socket_base = null;
        return;
    }
    var offer: filter_file.Reply = .{};
    unit.filter.offer(&offer);
    sendAll(unit, offer.bytes[0..offer.length]);
    // Open is waiting to hear the unit is ready.
    started(sys, unit);

    while (true) {
        while (sys.GetMsg(port)) |msg| take(sys, unit, _telnet.requestOf(msg));
        serveReads(sys, unit);
        const reading = unit.reads.first() != null and unit.data_length == 0 and !unit.ended;
        var came: u32 = 0;
        if (reading) {
            var ready: bsd.fd_set = .{};
            ready.set(unit.socket);
            var signals: u32 = port.sigMask() | unit.quit_mask;
            if (sb.WaitSelect(unit.socket + 1, &ready, null, null, null, &signals) > 0) receive(unit);
            came = signals;
        } else {
            came = sys.Wait(port.sigMask() | unit.quit_mask);
        }
        if (came & unit.quit_mask != 0) break;
    }

    // Closed: what still waits is aborted, the connection goes.
    while (sys.GetMsg(port)) |msg| answer(sys, _telnet.requestOf(msg), exec.IOERR_ABORTED);
    abortReads(sys, unit);
    _ = sb.CloseSocket(unit.socket);
    unit.socket = -1;
    sys.CloseLibrary(lib);
    unit.socket_base = null;
}

/// Open is told the task is ready. A task that fails before it is ends,
/// and Open hears of that from exec.
fn started(sys: *ExecBase, unit: *Unit) void {
    const waiter = unit.waiter orelse return;
    unit.waiter = null;
    sys.Signal(waiter, @as(u32, 1) << @intCast(unit.wait_signal));
}

fn answer(sys: *ExecBase, io: *exec.IOStdReq, err: i8) void {
    io.req.err = err;
    sys.ReplyIO(&io.req);
}

/// A request off the port: a read waits, a write goes, a flush ends the
/// reads.
fn take(sys: *ExecBase, unit: *Unit, io: *exec.IOStdReq) void {
    switch (io.req.command) {
        exec.CMD_READ => {
            sys.AcquireLock(&unit.lock);
            sys.AddTail(&unit.reads, &io.req.message.node);
            sys.ReleaseLock(&unit.lock);
        },
        exec.CMD_WRITE => write(sys, unit, io),
        exec.CMD_FLUSH => {
            abortReads(sys, unit);
            answer(sys, io, 0);
        },
        serial.SDCMD_TERMSIZE => {
            if (unit.filter.columns == 0 or unit.filter.rows == 0) return answer(sys, io, exec.IOERR_NOCMD);
            io.actual = unit.filter.columns;
            io.offset = unit.filter.rows;
            answer(sys, io, 0);
        },
        else => answer(sys, io, exec.IOERR_NOCMD),
    }
}

fn abortReads(sys: *ExecBase, unit: *Unit) void {
    while (true) {
        sys.AcquireLock(&unit.lock);
        const node = sys.RemHead(&unit.reads);
        sys.ReleaseLock(&unit.lock);
        const waiting = node orelse return;
        const msg: *exec.Message = @fieldParentPtr("node", waiting);
        answer(sys, _telnet.requestOf(msg), exec.IOERR_ABORTED);
    }
}

/// The reads that can be answered: with what came, or, once the
/// connection has ended, with the end.
fn serveReads(sys: *ExecBase, unit: *Unit) void {
    while (unit.data_length > 0 or unit.ended) {
        sys.AcquireLock(&unit.lock);
        const node = sys.RemHead(&unit.reads);
        sys.ReleaseLock(&unit.lock);
        const waiting = node orelse return;
        const io = _telnet.requestOf(@fieldParentPtr("node", waiting));
        if (unit.data_length == 0) {
            io.actual = 0;
            answer(sys, io, exec.IOERR_ENDOFSTREAM);
            continue;
        }
        const into: [*]u8 = @ptrCast(io.data orelse {
            answer(sys, io, exec.IOERR_BADADDRESS);
            continue;
        });
        const count: usize = @intCast(@min(io.length, unit.data_length));
        @memcpy(into[0..count], unit.data[unit.data_start..][0..count]);
        unit.data_start += count;
        unit.data_length -= count;
        io.actual = count;
        answer(sys, io, 0);
    }
}

/// What the connection has now, its Telnet commands taken out and
/// answered; the end if the peer has closed.
fn receive(unit: *Unit) void {
    const sb = unit.socket_base.?;
    var raw: [_telnet.receive_bytes]u8 = undefined;
    const got = sb.Recv(unit.socket, &raw, raw.len, bsd.MSG_DONTWAIT);
    if (got < 0) {
        if (sb.Errno() != bsd.EWOULDBLOCK) unit.ended = true;
        return;
    }
    if (got == 0) {
        unit.ended = true;
        return;
    }
    var reply: filter_file.Reply = .{};
    unit.data_start = 0;
    unit.data_length = unit.filter.feed(raw[0..@intCast(got)], &unit.data, &reply);
    if (reply.length > 0) sendAll(unit, reply.bytes[0..reply.length]);
}

/// A write's bytes out, 255 doubled.
fn write(sys: *ExecBase, unit: *Unit, io: *exec.IOStdReq) void {
    if (unit.ended) return answer(sys, io, exec.IOERR_ENDOFSTREAM);
    const from: [*]const u8 = @ptrCast(io.data orelse return answer(sys, io, exec.IOERR_BADADDRESS));
    const length: usize = @intCast(io.length);
    var at: usize = 0;
    var escaped: [2 * write_chunk]u8 = undefined;
    while (at < length and !unit.ended) {
        const piece = from[at..@min(length, at + write_chunk)];
        sendAll(unit, escaped[0..filter_file.escape(piece, &escaped)]);
        at += piece.len;
    }
    io.actual = at;
    answer(sys, io, if (unit.ended) exec.IOERR_ENDOFSTREAM else 0);
}

/// Every byte of `bytes` sent; the connection ended if it cannot be.
fn sendAll(unit: *Unit, bytes: []const u8) void {
    const sb = unit.socket_base.?;
    var at: usize = 0;
    while (at < bytes.len) {
        const sent = sb.Send(unit.socket, bytes.ptr + at, @intCast(bytes.len - at), 0);
        if (sent <= 0) {
            unit.ended = true;
            return;
        }
        at += @intCast(sent);
    }
}
