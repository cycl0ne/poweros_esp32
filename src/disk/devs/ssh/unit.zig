// SPDX-License-Identifier: MIT
//! A unit's task: the connection's socket, taken from where ShellServer
//! or C:net/SSH left it, the protocol - the server's end
//! (`connection.zig`) or the client's (`client.zig`) - run over it, and
//! every request of the unit served from it.
//!
//! **Its work, each time round**: the requests that came are taken; the
//! protocol takes what came in; what it has to say is sent; the reads are
//! given what the peer sent, the writes go out as far as the window lets
//! them, and the command waiting is answered once its step is over -
//! SSHCMD_ACCEPT once the client has asked for its session, the client's
//! commands once the server has answered them. Then it waits - in
//! WaitSelect for the socket while the protocol has room for more, beside
//! its request port and its quit signal, and while a server's login runs
//! no longer than the login has left; otherwise in Wait for the two.
//!
//! **Nothing is read before the first command**: the server's end needs
//! the host key before it can answer, and either end its role. A client
//! that has not asked the server for its session within two minutes of
//! SSHCMD_ACCEPT is sent away.
//!
//! **Its end.** CloseDevice signals it to quit. It answers what still
//! waits, closes the socket and its libraries, and ends; exec tells
//! CloseDevice once it is gone (SetTaskEndMsg).

const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const ssh = sdk.devices.ssh;
const serial = sdk.devices.serial;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const TimerBase = sdk.interface.timer.TimerBase;
const _ssh = @import("_ssh.zig");
const Unit = _ssh.Unit;
const transport_file = @import("transport.zig");

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

    while (true) {
        while (sys.GetMsg(port)) |msg| take(sys, unit, _ssh.requestOf(msg));
        work(sys, unit);
        const listening = unit.started and !_ssh.transport(unit).ended() and _ssh.transport(unit).inRoom() > 0;
        var came: u32 = 0;
        if (listening) {
            var ready: bsd.fd_set = .{};
            ready.set(unit.socket);
            var signals: u32 = port.sigMask() | unit.quit_mask;
            var patience: timer.TimeVal = .{};
            // The server's login has its time; the client waits as long
            // as the server takes.
            const timed = unit.role == .server and unit.waiting != null;
            if (timed) patience = timer.TimeVal.fromMicros(unit.deadline -| now(unit));
            const ready_count = sb.WaitSelect(unit.socket + 1, &ready, null, null, if (timed) &patience else null, &signals);
            if (ready_count > 0) receive(unit);
            if (timed and unit.waiting != null and now(unit) >= unit.deadline) _ssh.transport(unit).disconnect(transport_file.reason_by_application, "login time over");
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

/// A request off the port: the first command picks the end and starts
/// the protocol, a client's step begins, a read and a write wait their
/// turn, an exit ends the server's session, a flush the reads.
fn take(sys: *ExecBase, unit: *Unit, io: *exec.IOStdReq) void {
    const command = io.req.command;
    switch (command) {
        ssh.SSHCMD_ACCEPT, ssh.SSHCMD_CONNECT => {
            if (unit.role != .none) return answer(sys, io, ssh.SSHERR_ORDER);
            if (io.data == null) return answer(sys, io, exec.IOERR_BADADDRESS);
            if (command == ssh.SSHCMD_ACCEPT) {
                const given: *const ssh.SshAccept = @ptrCast(@alignCast(io.data.?));
                unit.role = .server;
                const conn = _ssh.server(unit);
                conn.init(unit.crypto);
                conn.start(given);
                unit.deadline = now(unit) + _ssh.login_grace_us;
            } else {
                unit.role = .client;
                const client = _ssh.client(unit);
                client.init(unit.crypto);
                client.start();
            }
            unit.started = true;
            wait(sys, unit, io);
        },
        ssh.SSHCMD_LOGIN, ssh.SSHCMD_SESSION, ssh.SSHCMD_STATUS => {
            if (unit.role != .client or unit.waiting != null) return answer(sys, io, ssh.SSHERR_ORDER);
            const client = _ssh.client(unit);
            if (command != ssh.SSHCMD_STATUS and client.transport.ended()) {
                io.actual = client.transport.reason;
                return answer(sys, io, exec.IOERR_ENDOFSTREAM);
            }
            if (command != ssh.SSHCMD_STATUS and io.data == null) return answer(sys, io, exec.IOERR_BADADDRESS);
            switch (command) {
                ssh.SSHCMD_LOGIN => {
                    if (client.step != .connected and client.step != .refused) return answer(sys, io, ssh.SSHERR_ORDER);
                    client.login(@ptrCast(@alignCast(io.data.?)));
                },
                ssh.SSHCMD_SESSION => {
                    if (client.step != .logged_in) return answer(sys, io, ssh.SSHERR_ORDER);
                    client.session(@ptrCast(@alignCast(io.data.?)));
                },
                else => if (client.step != .running and client.step != .failed) return answer(sys, io, ssh.SSHERR_ORDER),
            }
            wait(sys, unit, io);
        },
        exec.CMD_READ, exec.CMD_WRITE, ssh.SSHCMD_EOF => {
            if (unit.role == .none or (command == ssh.SSHCMD_EOF and unit.role != .client)) return answer(sys, io, ssh.SSHERR_ORDER);
            // EOF waits behind the writes, to go after them.
            sys.AcquireLock(&unit.lock);
            sys.AddTail(if (command == exec.CMD_READ) &unit.reads else &unit.writes, &io.req.message.node);
            sys.ReleaseLock(&unit.lock);
        },
        ssh.SSHCMD_EXIT => {
            if (unit.role != .server) return answer(sys, io, ssh.SSHERR_ORDER);
            _ssh.server(unit).exit(@truncate(io.length));
            flush(unit);
            answer(sys, io, 0);
        },
        ssh.SSHCMD_WINDOW => {
            if (unit.role != .client) return answer(sys, io, ssh.SSHERR_ORDER);
            _ssh.client(unit).windowChange(@truncate(io.length), @truncate(io.offset));
            flush(unit);
            answer(sys, io, 0);
        },
        exec.CMD_FLUSH => {
            abortList(sys, unit, &unit.reads);
            answer(sys, io, 0);
        },
        serial.SDCMD_TERMSIZE => {
            if (unit.role != .server or _ssh.server(unit).columns == 0) return answer(sys, io, exec.IOERR_NOCMD);
            const conn = _ssh.server(unit);
            io.actual = conn.columns;
            io.offset = conn.rows;
            answer(sys, io, 0);
        },
        else => answer(sys, io, exec.IOERR_NOCMD),
    }
}

/// `io` the command that waits for the protocol.
fn wait(sys: *ExecBase, unit: *Unit, io: *exec.IOStdReq) void {
    sys.AcquireLock(&unit.lock);
    unit.waiting = io;
    sys.ReleaseLock(&unit.lock);
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
    const waiting = unit.waiting;
    unit.waiting = null;
    sys.ReleaseLock(&unit.lock);
    if (waiting) |io| answer(sys, io, exec.IOERR_ABORTED);
}

/// Everything that can be done now, done: the protocol's input taken,
/// its output sent, the requests served.
fn work(sys: *ExecBase, unit: *Unit) void {
    if (!unit.started) return;
    while (true) {
        switch (unit.role) {
            .server => _ssh.server(unit).process(),
            .client => _ssh.client(unit).process(),
            .none => unreachable,
        }
        flush(unit);
        serveReads(sys, unit);
        serveWrites(sys, unit);
        flush(unit);
        if (!_ssh.transport(unit).processable()) break;
    }
    serveWaiting(sys, unit);
}

/// What the protocol has to say, sent; the connection lost if it cannot
/// be.
fn flush(unit: *Unit) void {
    const t = _ssh.transport(unit);
    const sb = unit.socket_base.?;
    while (t.pending().len > 0) {
        const bytes = t.pending();
        const sent = sb.Send(unit.socket, bytes.ptr, @intCast(bytes.len), 0);
        if (sent <= 0) {
            t.lose();
            return;
        }
        t.sent(@intCast(sent));
    }
}

/// What the connection has now, given to the protocol; its end if the
/// client has closed.
fn receive(unit: *Unit) void {
    const t = _ssh.transport(unit);
    const sb = unit.socket_base.?;
    var bytes: [_ssh.receive_chunk]u8 = undefined;
    const room = @min(bytes.len, t.inRoom());
    const got = sb.Recv(unit.socket, &bytes, @intCast(room), bsd.MSG_DONTWAIT);
    if (got < 0) {
        if (sb.Errno() != bsd.EWOULDBLOCK) t.lose();
        return;
    }
    if (got == 0) return t.lose();
    t.feed(bytes[0..@intCast(got)]);
}

/// The command waiting answered, once its step is over or the
/// connection has gone.
fn serveWaiting(sys: *ExecBase, unit: *Unit) void {
    const pending = unit.waiting orelse return;
    if (!stepOver(unit, pending.req.command)) return;
    sys.AcquireLock(&unit.lock);
    const waiting = unit.waiting;
    unit.waiting = null;
    sys.ReleaseLock(&unit.lock);
    const io = waiting orelse return;
    if (unit.role == .server) return answerAccept(sys, unit, io);
    answerStep(sys, unit, io);
}

/// Whether the step `command` waits for is over: one way or the other,
/// or with the connection gone.
fn stepOver(unit: *Unit, command: u16) bool {
    if (_ssh.transport(unit).ended()) return true;
    if (unit.role == .server) return _ssh.server(unit).session_ready;
    const client = _ssh.client(unit);
    return switch (command) {
        ssh.SSHCMD_CONNECT => client.step != .connecting,
        ssh.SSHCMD_LOGIN => client.step == .logged_in or client.step == .refused,
        ssh.SSHCMD_SESSION => client.step == .running or client.step == .failed,
        else => client.sessionEnded(),
    };
}

/// SSHCMD_ACCEPT answered with what the client asked for.
fn answerAccept(sys: *ExecBase, unit: *Unit, io: *exec.IOStdReq) void {
    const conn = _ssh.server(unit);
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

/// A client's step answered: how it went, or why the connection went.
fn answerStep(sys: *ExecBase, unit: *Unit, io: *exec.IOStdReq) void {
    const client = _ssh.client(unit);
    const t = &client.transport;
    switch (io.req.command) {
        ssh.SSHCMD_STATUS => {
            io.actual = client.exit_status;
            return answer(sys, io, if (client.status_given) 0 else exec.IOERR_ENDOFSTREAM);
        },
        ssh.SSHCMD_CONNECT => if (client.step != .connecting) {
            const into: *ssh.SshConnect = @ptrCast(@alignCast(io.data.?));
            into.host_public = client.host_public;
            into.kex = if (t.hybrid) ssh.SSHKEX_MLKEM768X25519 else ssh.SSHKEX_CURVE25519;
            return answer(sys, io, 0);
        },
        ssh.SSHCMD_LOGIN => {
            const into: *ssh.SshLogin = @ptrCast(@alignCast(io.data.?));
            client.takeBanner(&into.banner);
            switch (client.step) {
                .logged_in => return answer(sys, io, 0),
                .refused => {
                    client.methodsLeft(&into.methods);
                    return answer(sys, io, ssh.SSHERR_LOGIN);
                },
                else => {},
            }
        },
        else => switch (client.step) {
            .running => {
                io.actual = @intFromBool(client.has_terminal);
                return answer(sys, io, 0);
            },
            .failed => return answer(sys, io, ssh.SSHERR_SESSION),
            else => {},
        },
    }
    io.actual = t.reason;
    answer(sys, io, exec.IOERR_ENDOFSTREAM);
}

/// The reads that can be answered: with what the peer sent, or once its
/// input has ended, with the end.
fn serveReads(sys: *ExecBase, unit: *Unit) void {
    const t = _ssh.transport(unit);
    const channel = _ssh.channel(unit);
    while (channel.readable() > 0 or channel.inputEnded(t)) {
        const io = first(sys, unit, &unit.reads) orelse return;
        remove(sys, unit, io);
        if (channel.readable() == 0) {
            io.actual = 0;
            answer(sys, io, exec.IOERR_ENDOFSTREAM);
            continue;
        }
        const into: [*]u8 = @ptrCast(io.data orelse {
            answer(sys, io, exec.IOERR_BADADDRESS);
            continue;
        });
        const count = channel.read(t, into[0..@intCast(io.length)]);
        io.actual = count;
        answer(sys, io, 0);
    }
}

/// The writes, in turn, as far as the window and the output let them; a
/// write is answered when all of it is gone, an EOF once it is sent.
fn serveWrites(sys: *ExecBase, unit: *Unit) void {
    const t = _ssh.transport(unit);
    const channel = _ssh.channel(unit);
    while (first(sys, unit, &unit.writes)) |io| {
        if (io.req.command == ssh.SSHCMD_EOF) {
            remove(sys, unit, io);
            channel.endOutput(t);
            answer(sys, io, 0);
            continue;
        }
        if (channel.writeEnded(t)) {
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
            const count = channel.write(t, from[unit.written..length]);
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
