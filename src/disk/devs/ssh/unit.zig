// SPDX-License-Identifier: MIT
//! A unit's task: the connection's socket, taken from where ShellServer
//! left it, the protocol (`connection.zig`) run over it, and every
//! request of the unit served from it.
//!
//! **Its work, each time round**: the requests that came are taken; the
//! protocol takes what came in; what it has to say is sent; the reads are
//! given what the client typed, the writes go out as far as the window
//! lets them, and SSHCMD_ACCEPT is answered once the client has asked for
//! its session. Then it waits - in WaitSelect for the socket while the
//! protocol has room for more, beside its request port and its quit
//! signal, and while the login runs no longer than the login has left;
//! otherwise in Wait for the two.
//!
//! **Nothing is read before SSHCMD_ACCEPT**: the protocol needs the host
//! key before it can answer. A client that has not asked for its session
//! within two minutes of that is sent away.
//!
//! **Its end.** CloseDevice signals it to quit. It answers what still
//! waits, closes the socket and its libraries, and ends; exec tells
//! CloseDevice once it is gone (SetTaskEndMsg).

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const ssh = sdk.devices.ssh;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TimerBase = sdk.interface.timer.TimerBase;
const _ssh = @import("_ssh.zig");
const Unit = _ssh.Unit;
const connection_file = @import("connection.zig");
const Connection = connection_file.Connection;

pub fn unitTask(sys: *ExecBase) callconv(.c) void {
    const unit: *Unit = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
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
    unit.timer_io = .{};
    unit.timer_io.node.message.length = @sizeOf(timer.TimeRequest);
    unit.timer_open = sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &unit.timer_io.node, 0) == 0;
    // Open is waiting to hear the unit is ready.
    started(sys, unit);

    const conn = unit.connection;
    while (true) {
        while (sys.GetMsg(port)) |msg| take(sys, unit, _ssh.requestOf(msg));
        work(sys, unit);
        const listening = unit.started and !conn.ended() and conn.inRoom() > 0;
        var came: u32 = 0;
        if (listening) {
            var ready: bsd.fd_set = .{};
            ready.set(unit.socket);
            var signals: u32 = port.sigMask() | unit.quit_mask;
            var patience: timer.TimeVal = .{};
            const timed = unit.accept != null;
            if (timed) patience = timer.TimeVal.fromMicros(unit.deadline -| now(unit));
            const ready_count = sb.WaitSelect(unit.socket + 1, &ready, null, null, if (timed) &patience else null, &signals);
            if (ready_count > 0) receive(unit);
            if (timed and unit.accept != null and now(unit) >= unit.deadline) conn.disconnect(connection_file.reason_by_application, "login time over");
            came = signals;
        } else {
            came = sys.Wait(port.sigMask() | unit.quit_mask);
        }
        if (came & unit.quit_mask != 0) break;
    }

    // Closed: what still waits is answered, the connection goes.
    while (sys.GetMsg(port)) |msg| answer(sys, _ssh.requestOf(msg), exec.IOERR_ABORTED);
    abortAll(sys, unit);
    _ = sb.CloseSocket(unit.socket);
    unit.socket = -1;
    if (unit.timer_open) sys.CloseDevice(&unit.timer_io.node);
    sys.CloseLibrary(lib);
    unit.socket_base = null;
}

/// Open is told the task is ready.
fn started(sys: *ExecBase, unit: *Unit) void {
    const waiter = unit.waiter orelse return;
    unit.waiter = null;
    sys.Signal(waiter, @as(u32, 1) << @intCast(unit.wait_signal));
}

/// The system time, in microseconds; 0 without timer.device.
fn now(unit: *Unit) u64 {
    if (!unit.timer_open) return 0;
    const timer_base: *TimerBase = @ptrCast(@alignCast(unit.timer_io.node.device.?));
    var time: timer.TimeVal = .{};
    timer_base.GetSysTime(&time);
    return @as(u64, time.secs) * 1_000_000 + time.micro;
}

fn answer(sys: *ExecBase, io: *exec.IOStdReq, err: i8) void {
    io.req.err = err;
    sys.ReplyIO(&io.req);
}

/// A request off the port: an accept starts the protocol, a read and a
/// write wait their turn, an exit ends the session, a flush the reads.
fn take(sys: *ExecBase, unit: *Unit, io: *exec.IOStdReq) void {
    switch (io.req.command) {
        ssh.SSHCMD_ACCEPT => {
            if (unit.started or io.data == null) return answer(sys, io, exec.IOERR_BADADDRESS);
            const given: *const ssh.SshAccept = @ptrCast(@alignCast(io.data.?));
            unit.connection.start(given);
            unit.started = true;
            unit.deadline = now(unit) + _ssh.login_grace_us;
            sys.AcquireLock(&unit.lock);
            unit.accept = io;
            sys.ReleaseLock(&unit.lock);
        },
        exec.CMD_READ, exec.CMD_WRITE => {
            sys.AcquireLock(&unit.lock);
            sys.AddTail(if (io.req.command == exec.CMD_READ) &unit.reads else &unit.writes, &io.req.message.node);
            sys.ReleaseLock(&unit.lock);
        },
        ssh.SSHCMD_EXIT => {
            unit.connection.exit(@truncate(io.length));
            flush(unit);
            answer(sys, io, 0);
        },
        exec.CMD_FLUSH => {
            abortList(sys, unit, &unit.reads);
            answer(sys, io, 0);
        },
        else => answer(sys, io, exec.IOERR_NOCMD),
    }
}

/// The first request of `list`, taken off it.
fn first(sys: *ExecBase, unit: *Unit, list: *exec.List) ?*exec.IOStdReq {
    sys.AcquireLock(&unit.lock);
    defer sys.ReleaseLock(&unit.lock);
    const node = list.first() orelse return null;
    return _ssh.requestOf(@fieldParentPtr("node", node));
}

fn remove(sys: *ExecBase, unit: *Unit, io: *exec.IOStdReq) void {
    sys.AcquireLock(&unit.lock);
    sys.Remove(&io.req.message.node);
    sys.ReleaseLock(&unit.lock);
}

fn abortList(sys: *ExecBase, unit: *Unit, list: *exec.List) void {
    while (first(sys, unit, list)) |io| {
        remove(sys, unit, io);
        answer(sys, io, exec.IOERR_ABORTED);
    }
}

fn abortAll(sys: *ExecBase, unit: *Unit) void {
    abortList(sys, unit, &unit.reads);
    abortList(sys, unit, &unit.writes);
    sys.AcquireLock(&unit.lock);
    const waiting = unit.accept;
    unit.accept = null;
    sys.ReleaseLock(&unit.lock);
    if (waiting) |io| answer(sys, io, exec.IOERR_ABORTED);
}

/// Everything that can be done now, done: the protocol's input taken,
/// its output sent, the requests served.
fn work(sys: *ExecBase, unit: *Unit) void {
    if (!unit.started) return;
    const conn = unit.connection;
    while (true) {
        conn.process();
        flush(unit);
        serveReads(sys, unit);
        serveWrites(sys, unit);
        flush(unit);
        if (!conn.processable()) break;
    }
    serveAccept(sys, unit);
}

/// What the protocol has to say, sent; the connection lost if it cannot
/// be.
fn flush(unit: *Unit) void {
    const conn = unit.connection;
    const sb = unit.socket_base.?;
    while (conn.pending().len > 0) {
        const bytes = conn.pending();
        const sent = sb.Send(unit.socket, bytes.ptr, @intCast(bytes.len), 0);
        if (sent <= 0) {
            conn.lose();
            return;
        }
        conn.sent(@intCast(sent));
    }
}

/// What the connection has now, given to the protocol; its end if the
/// client has closed.
fn receive(unit: *Unit) void {
    const conn = unit.connection;
    const sb = unit.socket_base.?;
    var bytes: [_ssh.receive_chunk]u8 = undefined;
    const room = @min(bytes.len, conn.inRoom());
    const got = sb.Recv(unit.socket, &bytes, @intCast(room), bsd.MSG_DONTWAIT);
    if (got < 0) {
        if (sb.Errno() != bsd.EWOULDBLOCK) conn.lose();
        return;
    }
    if (got == 0) return conn.lose();
    conn.feed(bytes[0..@intCast(got)]);
}

/// SSHCMD_ACCEPT answered once the session is asked for - with what was
/// asked - or once the connection has gone.
fn serveAccept(sys: *ExecBase, unit: *Unit) void {
    const conn = unit.connection;
    if (unit.accept == null or !(conn.session_ready or conn.ended())) return;
    sys.AcquireLock(&unit.lock);
    const waiting = unit.accept;
    unit.accept = null;
    sys.ReleaseLock(&unit.lock);
    const io = waiting orelse return;
    if (!conn.session_ready) return answer(sys, io, exec.IOERR_ENDOFSTREAM);
    const into: *ssh.SshAccept = @ptrCast(@alignCast(io.data.?));
    into.kind = conn.kind;
    into.columns = conn.columns;
    into.rows = conn.rows;
    into.user = conn.user;
    into.terminal = conn.terminal;
    into.command = conn.command;
    answer(sys, io, 0);
}

/// The reads that can be answered: with what the client typed, or once
/// its input has ended, with the end.
fn serveReads(sys: *ExecBase, unit: *Unit) void {
    const conn = unit.connection;
    while (conn.readable() > 0 or conn.input_ended) {
        const io = first(sys, unit, &unit.reads) orelse return;
        remove(sys, unit, io);
        if (conn.readable() == 0) {
            io.actual = 0;
            answer(sys, io, exec.IOERR_ENDOFSTREAM);
            continue;
        }
        const into: [*]u8 = @ptrCast(io.data orelse {
            answer(sys, io, exec.IOERR_BADADDRESS);
            continue;
        });
        const count = conn.read(into[0..@intCast(io.length)]);
        io.actual = count;
        answer(sys, io, 0);
    }
}

/// The writes, in turn, as far as the window and the output let them; a
/// write is answered when all of it is gone.
fn serveWrites(sys: *ExecBase, unit: *Unit) void {
    const conn = unit.connection;
    while (first(sys, unit, &unit.writes)) |io| {
        if (conn.writeEnded()) {
            remove(sys, unit, io);
            unit.written = 0;
            answer(sys, io, exec.IOERR_ENDOFSTREAM);
            continue;
        }
        const from: [*]const u8 = @ptrCast(io.data orelse {
            remove(sys, unit, io);
            answer(sys, io, exec.IOERR_BADADDRESS);
            continue;
        });
        const length: usize = @intCast(io.length);
        while (unit.written < length) {
            const count = conn.write(from[unit.written..length]);
            if (count == 0) return;
            unit.written += count;
            flush(unit);
        }
        remove(sys, unit, io);
        io.actual = length;
        unit.written = 0;
        answer(sys, io, 0);
    }
}
