// SPDX-License-Identifier: MPL-2.0
//! Requests: a READ or a WRITE sent to a file's handler and waited for
//! later - StartRead, StartWrite, CheckRequest, WaitRequest - and the wait
//! every other call on the handle does for them first (`settle`).
//!
//! A request is a DosPacket and the port it comes back to. Starting one
//! sends the packet as SendPkt does and puts the request last on its
//! handle's list of requests out (`FileHandle.requests`). A handler serves
//! a handle's packets in the order they came, so each request reads or
//! writes from where the one before it ended.
//!
//! Its answer comes back to its port, which other requests and the
//! program's own messages may share. Taking it (`take`) takes only its own
//! packet off, and puts back what came before it, in order and with the
//! port's signal set again, as `exchange` does with the packets it was not
//! waiting for. The request is then `back`, its answer in it and off its
//! handle's list, for WaitRequest to give - whether WaitRequest took it,
//! CheckRequest did, or a call that waited for the handle's requests.
//!
//! A port that is the process's own msg_port is waited at through
//! pr_PktWait when the process has one, so a process that multiplexes its
//! port is handed the packet the way it hands dos every other.
//!
//! What the handle's buffer holds goes first, as Seek gives it up: waiting
//! bytes are written, bytes read ahead seeked back over, so the request
//! reads or writes from the caller's position, all of `length` it can. A
//! console has no position to go back to: there a StartRead takes what
//! was typed ahead and is back at once, without a packet, as Read gives
//! it first; a StartWrite leaves it to be read.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const packets = @import("../packet/_packet.zig");
const process = @import("../process/_process.zig");
const FileHandle = dos.FileHandle;
const DosRequest = dos.DosRequest;

/// Starts `request` on `file`: ACTION_READ or ACTION_WRITE of `length`
/// bytes at `buffer`, sent without waiting.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `file` - the handle; null is `ERROR_INVALID_LOCK`.
/// - `request` - from AllocDosObject(DOS_REQUEST), not out; null is
///   `ERROR_REQUIRED_ARG_MISSING`, one still out `ERROR_OBJECT_IN_USE`.
/// - `action` - `.read` or `.write`.
/// - `buffer`, `length` - the bytes, the caller's until the request is
///   back.
///
/// RESULT:
/// True when it is out (or, a console's read the buffer answers, back
/// already); false with `IoErr()` set, nothing sent.
pub fn start(db: *DosBase, file: ?*FileHandle, request: ?*DosRequest, action: dos.ActionCode, buffer: [*]u8, length: isize) bool {
    const req = request orelse return fail(db, dos.ERROR_REQUIRED_ARG_MISSING);
    if (req.state == .out) return fail(db, dos.ERROR_OBJECT_IN_USE);
    const fh = file orelse return fail(db, dos.ERROR_INVALID_LOCK);
    const port = fh.task orelse return fail(db, dos.ERROR_INVALID_LOCK);
    const reply = req.port orelse return fail(db, dos.ERROR_NO_FREE_STORE);
    if (action == .read and fh.state == .read and fh.interactive and length > 0) {
        // Typed ahead: the console's next bytes, and the request's
        // answer - back at once, as Read gives them first.
        const taken = _file.take(fh, buffer, @intCast(length));
        if (taken.count > 0 or taken.end) {
            send(fh, req, action, buffer, length);
            req.packet.res1 = @intCast(taken.count);
            req.packet.res2 = 0;
            req.packet.port = reply;
            db.sys_base.PutMsg(reply, &req.packet.msg);
            return true;
        }
    }
    const ready = if (action == .read) _file.flush(db, fh) else _file.beforeWrite(db, fh);
    if (!ready) return false;
    send(fh, req, action, buffer, length);
    req.packet.port = reply;
    req.packet.msg.reply_port = reply;
    db.sys_base.PutMsg(port, &req.packet.msg);
    return true;
}

/// The request's packet made for `action` and the request put last on
/// the handle's list, out.
fn send(fh: *FileHandle, req: *DosRequest, action: dos.ActionCode, buffer: [*]u8, length: isize) void {
    var args: dos.PacketArgs = .{ .raw = @splat(0) };
    args.io = .{ .fh = fh, .buffer = buffer, .length = length };
    req.packet = dos.DosPacket.init(action, args);
    req.fh = fh;
    req.next = null;
    req.state = .out;
    var at = &fh.requests;
    while (at.*) |held| at = &held.next;
    at.* = req;
}

/// Takes `req`'s answer off its port, waiting for it when `wait` says so.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `req` - the request.
/// - `wait` - whether to wait for an answer that has not come.
///
/// RESULT:
/// Whether it is back: its answer in `result` and `code`, and it off its
/// handle's list. True at once for one that is not out.
pub fn take(db: *DosBase, req: *DosRequest, wait: bool) bool {
    if (req.state != .out) return true;
    const sys = db.sys_base;
    const port = req.port.?;
    const proc = process.currentProcess(sys);
    const through_process = if (proc) |p| port == &p.msg_port else false;
    var strays: exec.List = undefined;
    strays.init(.message);
    var found = false;
    while (true) {
        const msg = sys.GetMsg(port) orelse blk: {
            if (!wait) break;
            if (through_process) break :blk &packets.taskwait(sys, proc, port).msg;
            _ = sys.Wait(port.sigMask());
            continue;
        };
        if (msg == &req.packet.msg) {
            found = true;
            break;
        }
        sys.AddTail(&strays, &msg.node);
    }
    if (!strays.isEmpty()) {
        sys.Disable();
        while (sys.RemTail(&strays)) |node| sys.AddHead(&port.msg_list, node);
        sys.Enable();
        _ = sys.SetSignal(port.sigMask(), port.sigMask());
    }
    if (!found) return false;
    req.result = req.packet.res1;
    req.code = req.packet.res2;
    req.state = .back;
    unlink(req);
    return true;
}

/// Waits for every request out on the handle, oldest first, their
/// answers kept for WaitRequest: what each call that reads, writes, moves,
/// asks about or closes a handle does first.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the handle.
pub fn settle(db: *DosBase, fh: *FileHandle) void {
    while (fh.requests) |req| {
        if (!take(db, req, true)) return;
    }
}

/// The request off its handle's list.
fn unlink(req: *DosRequest) void {
    const fh = req.fh orelse return;
    var at = &fh.requests;
    while (at.*) |held| : (at = &held.next) {
        if (held == req) {
            at.* = req.next;
            break;
        }
    }
    req.fh = null;
    req.next = null;
}

fn fail(db: *DosBase, code: i32) bool {
    _ = db.iface().SetIoErr(code);
    return false;
}
