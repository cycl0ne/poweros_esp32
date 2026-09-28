// SPDX-License-Identifier: MIT
//! The process that does the clipboard's work.
//!
//! Every request is done here and nowhere else: the clips are files, the
//! files are reached through dos, and dos needs a process. The loop
//! waits on one port for every unit, so the requests of a unit are done
//! in the order they were sent and two programs writing at once cannot
//! interleave.
//!
//! **A write starts at offset 0.** That is what says a new clip has
//! begun: the file is made afresh, the write id counts up, and what
//! could be read before stays readable until `CMD_UPDATE` finishes the
//! new one. A write that never finishes leaves the old clip in place.
//!
//! **The offset moves on by itself.** A read or a write leaves
//! `io.offset` past what it just did, so a program works through a clip
//! by sending the same request again and again and only seeks when it
//! means to.
//!
//! **A read past the end ends the reading.** The file is closed there,
//! which is what a reader that has taken everything does: iffparse asks
//! for a byte past the end when it closes a clipboard stream.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const clipboard = sdk.devices.clipboard;
const ExecBase = sdk.interface.exec.ExecBase;
const _clip = @import("_clipboard.zig");
const ClipBase = _clip.ClipBase;
const Unit = _clip.Unit;

/// Whatever signal the process has free for its port.
const any_signal: i8 = -1;

fn read(unit: *Unit, io: *clipboard.IOClipReq) void {
    const dl = unit.base.dos_base.?;
    io.io.actual = 0;
    // Nothing has been written, or the reader has gone past the end.
    if (unit.read_id == 0 or io.io.offset >= unit.length) {
        if (unit.read_file) |file| {
            _ = dl.Close(file);
            unit.read_file = null;
        }
        return;
    }
    if (unit.read_file == null) {
        unit.read_file = dl.Open(@ptrCast(&unit.name), dos.MODE_OLDFILE) orelse {
            io.io.req.err = exec.IOERR_BADADDRESS;
            return;
        };
    }
    const file = unit.read_file.?;
    if (dl.Seek(file, @intCast(io.io.offset), dos.OFFSET_BEGINNING) < 0) {
        io.io.req.err = exec.IOERR_BADADDRESS;
        return;
    }
    const left = unit.length - io.io.offset;
    const wanted: isize = @intCast(@min(io.io.length, left));
    const buf = io.io.data orelse {
        io.io.req.err = exec.IOERR_BADADDRESS;
        return;
    };
    const got = dl.Read(file, @ptrCast(buf), wanted);
    if (got < 0) {
        io.io.req.err = exec.IOERR_BADADDRESS;
        return;
    }
    io.io.actual = @intCast(got);
    // The offset moves on with the reading: a reader works through the
    // clip by sending the same request again and again.
    io.io.offset += io.io.actual;
    io.clip_id = unit.read_id;
}

fn write(unit: *Unit, io: *clipboard.IOClipReq) void {
    const dl = unit.base.dos_base.?;
    io.io.actual = 0;
    if (io.io.offset == 0 and unit.write_file == null) {
        // A new clip: the file is made afresh and the old one stays
        // readable until this write is finished.
        unit.write_file = dl.Open(@ptrCast(&unit.name), dos.MODE_NEWFILE) orelse {
            io.io.req.err = exec.IOERR_BADADDRESS;
            return;
        };
        unit.write_id +%= 1;
        unit.written = 0;
    }
    const file = unit.write_file orelse {
        io.io.req.err = exec.IOERR_BADADDRESS;
        return;
    };
    if (io.io.offset != unit.written) {
        if (dl.Seek(file, @intCast(io.io.offset), dos.OFFSET_BEGINNING) < 0) {
            io.io.req.err = exec.IOERR_BADADDRESS;
            return;
        }
    }
    const buf = io.io.data orelse {
        io.io.req.err = exec.IOERR_BADADDRESS;
        return;
    };
    const wanted: isize = @intCast(io.io.length);
    const put = dl.Write(file, @ptrCast(buf), wanted);
    if (put != wanted) {
        io.io.req.err = exec.IOERR_BADADDRESS;
        return;
    }
    io.io.actual = io.io.length;
    // How long the clip is, not where this write ended: a size written
    // back over the header goes to an offset already passed.
    unit.written = @max(unit.written, io.io.offset + io.io.length);
    io.io.offset += io.io.length;
    io.clip_id = unit.write_id;
}

/// The clip being written finished: from now on it is the one that is
/// read, and everything listening is told.
fn update(unit: *Unit, io: *clipboard.IOClipReq) void {
    const dl = unit.base.dos_base.?;
    const file = unit.write_file orelse return;
    _ = dl.Close(file);
    unit.write_file = null;
    if (unit.read_file) |open_for_reading| {
        _ = dl.Close(open_for_reading);
        unit.read_file = null;
    }
    unit.length = unit.written;
    unit.read_id = unit.write_id;
    io.clip_id = unit.read_id;
    _clip.tellHooks(unit, exec.CMD_UPDATE);
}

fn changeHook(unit: *Unit, io: *clipboard.IOClipReq) void {
    const sys = unit.base.sys_base;
    const hook: *utility.Hook = @ptrCast(@alignCast(io.io.data orelse {
        io.io.req.err = exec.IOERR_BADADDRESS;
        return;
    }));
    sys.ObtainSemaphore(&unit.hook_lock);
    defer sys.ReleaseSemaphore(&unit.hook_lock);
    if (io.io.length != 0) {
        sys.AddTail(@ptrCast(&unit.hooks), @ptrCast(&hook.node));
    } else {
        sys.Remove(@ptrCast(&hook.node));
    }
}

fn serve(io: *clipboard.IOClipReq) void {
    const unit: *Unit = @fieldParentPtr("unit", io.io.req.unit.?);
    io.io.req.err = 0;
    switch (io.io.req.command) {
        exec.CMD_READ => read(unit, io),
        exec.CMD_WRITE => write(unit, io),
        exec.CMD_UPDATE => update(unit, io),
        clipboard.CBD_CURRENTREADID => io.io.actual = @intCast(@as(u32, @bitCast(unit.read_id))),
        clipboard.CBD_CURRENTWRITEID => io.io.actual = @intCast(@as(u32, @bitCast(unit.write_id))),
        clipboard.CBD_CHANGEHOOK => changeHook(unit, io),
        else => io.io.req.err = exec.IOERR_NOCMD,
    }
}

/// The server: one port, every unit's requests, until the device is
/// expunged.
pub fn serverProcess(sys: *ExecBase) callconv(.c) void {
    const process = sys.FindTask(null).?;
    const base: *ClipBase = @ptrCast(@alignCast(process.user_data orelse return));
    // The port answers on a signal of the process's own.
    const signal = sys.AllocSignal(any_signal);
    if (signal < 0) return;
    base.port.sig_bit = @intCast(signal);
    base.port.sig_task = process;
    base.port.flags = exec.PA_SIGNAL;
    base.server = process;
    if (base.starter) |starter| sys.Signal(starter, @as(u32, 1) << @intCast(base.start_signal));
    while (true) {
        const got = sys.Wait(@as(u32, 1) << @intCast(signal) | exec.SIGBREAKF_CTRL_C);
        while (sys.GetMsg(&base.port)) |message| {
            serve(_clip.requestOf(message));
            sys.ReplyMsg(message);
        }
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
    }
    // Nothing more comes: the port takes messages without a signal so
    // that a request sent as the device goes is not lost in the dark.
    sys.Disable();
    base.port.flags = exec.PA_IGNORE;
    base.server = null;
    sys.Enable();
}
