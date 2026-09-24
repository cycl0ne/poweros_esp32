// SPDX-License-Identifier: MPL-2.0
//! File handles: raw I/O a packet at a time, and buffered I/O on top.
//!
//! Files: opening, closing, and moving bytes one packet at a time.
//!
//! Open and OpenFromLock make a FileHandle and ask the file's handler to
//! fill it in; Close gives it back. Read, Write and Seek send one packet
//! each - ACTION_READ, ACTION_WRITE, ACTION_SEEK - and so do SetFileSize,
//! DupLockFromFH and ParentOfFH. Every packet about an open file carries
//! the FileHandle, so a handler with many files open knows which one is
//! meant. Read and Write answer a count (0 at the end) or -1, Seek the old
//! position or -1, and IoErr() holds the reason for a -1.
//!
//! Open takes three modes, one per packet: MODE_OLDFILE (FINDINPUT),
//! MODE_NEWFILE (FINDOUTPUT) and MODE_READWRITE (FINDUPDATE); anything else
//! is ERROR_ACTION_NOT_KNOWN. The name is resolved by lock/'s name
//! helper - handler, directory, name - and retried along a multi-assign
//! while the file isn't found, except for MODE_NEWFILE, which creates in
//! the first directory. "*" is CONSOLE:, or NIL: without a console. NIL:
//! is a handler like any other.
//!
//! Input, Output, SelectInput and SelectOutput read and set the running
//! process's pr_CIS and pr_COS; from a plain task they answer null. SetMode
//! and WaitForChar are the console's own packets.
//!
//! Buffered I/O: stdio on top of Read and Write. FGetC, UnGetC, FPutC,
//! FRead, FWrite, FGets, FPuts, Flush, SetVBuf, VFPrintf, VPrintf, PutStr
//! and WriteChars; FRead and FWrite take a buffer and a byte count.
//!
//! A handle has one buffer, for reading or for writing at a time
//! (FileHandle.state). It is allocated by the first buffered call
//! (stdio.BUFFER_SIZE bytes, unless SetVBuf gave another) rather than at
//! Open, so a handle only ever used unbuffered costs nothing, and Close
//! frees it. A handle turns around by itself: reading after writing writes
//! the waiting bytes out; writing after reading seeks the handler back over
//! what was read ahead. A console is the exception, since it has no
//! position: a write goes straight out, and what was typed ahead stays to
//! be read.
//!
//! The unbuffered calls keep to the same buffer: Read gives the
//! buffered bytes first, Write, Seek, SetFileSize, ExamineFH and Close
//! flush. So buffered and unbuffered calls mix on one handle, and
//! Seek(fh, 0, OFFSET_CURRENT) is always the caller's position.
//!
//! Line buffering (BUF_LINE, where every handle starts) writes out at '\n'
//! or '\r' - on consoles only, where someone is waiting to see the line; to
//! a file it is BUF_FULL. The end isn't sticky: FGetC asks the handler
//! again, so a console can be read on after an end of input. UnGetC keeps
//! up to four characters on a stack of its own, and -1 pushes back the
//! last one FGetC gave, the end included. Flush reports a write that
//! failed and keeps what didn't go out, for the next try.
//!
//! RunCommand lends a handle an argument line as its read-ahead (lend and
//! giveBack), so the command reads its arguments with the calls it reads
//! anything else with.

const sdk = @import("sdk");
const packets = @import("../packet/_packet.zig");
const process = @import("../process/_process.zig");
const locks = @import("../lock/_lock.zig");
const DosBase = @import("../dos_base.zig").DosBase;
const dos = sdk.dos;
const FileHandle = dos.FileHandle;
const ActionCode = dos.ActionCode;
const exec = sdk.exec;
const stdio = dos.stdio;

/// Sets `IoErr()` and answers `result`: the one-line failure of a call
/// that answers a count.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `code` - the error for `IoErr()`.
/// - `result` - what the caller answers with.
pub fn failWith(db: *DosBase, code: i32, result: isize) isize {
    const dos_lib = db.iface();
    _ = dos_lib.SetIoErr(code);
    return result;
}

/// Opens a second handle on a handler that is already running, by its
/// port rather than by name: what "*" does for a process's own console,
/// for a console that is not the caller's. A console whose name makes a
/// window makes one per Open, so the other direction of it can only be had
/// this way.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `port` - the handler's port.
/// - `name` - the name the handler is given in the packet.
/// - `mode` - `MODE_OLDFILE`, `MODE_NEWFILE` or `MODE_READWRITE`.
///
/// RESULT:
/// The handle, or null with `IoErr()` set as for `Open`.
pub fn openOnPort(db: *DosBase, port: *sdk.exec.MsgPort, name: [*:0]const u8, mode: i32) ?*FileHandle {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const action: ActionCode = switch (mode) {
        dos.MODE_OLDFILE => .findinput,
        dos.MODE_NEWFILE => .findoutput,
        dos.MODE_READWRITE => .findupdate,
        else => {
            _ = dos_lib.SetIoErr(dos.ERROR_ACTION_NOT_KNOWN);
            return null;
        },
    };
    const block = dos_lib.AllocDosObject(dos.DOS_FILEHANDLE, null) orelse return null;
    const fh: *FileHandle = @ptrCast(@alignCast(block));
    fh.task = port;
    const args: [5]isize = .{ @bitCast(@intFromPtr(fh)), 0, @bitCast(@intFromPtr(name)), 0, 0 };
    const answer = packets.exchange(sys, port, @intFromEnum(action), args) orelse {
        dos_lib.FreeDosObject(dos.DOS_FILEHANDLE, fh);
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    if (answer.res1 == 0) {
        dos_lib.FreeDosObject(dos.DOS_FILEHANDLE, fh);
        _ = dos_lib.SetIoErr(answer.res2);
        return null;
    }
    return fh;
}

/// Sends a packet about an open file - READ, WRITE, SEEK, SET_FILE_SIZE -
/// as (fh, arg2, arg3) to its handler.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `file` - the handle; null is `ERROR_INVALID_LOCK`.
/// - `action` - the packet type.
/// - `arg2`, `arg3` - its second and third arguments.
///
/// RESULT:
/// dp_Res1; when it is negative, `IoErr()` is dp_Res2. -1 with
/// `ERROR_INVALID_LOCK` for a handle without a handler, and with
/// `ERROR_NO_FREE_STORE` when no packet can be sent.
pub fn fileAction(db: *DosBase, file: ?*FileHandle, action: ActionCode, arg2: isize, arg3: isize) isize {
    const dos_lib = db.iface();
    const fh = file orelse return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    const port = fh.task orelse return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(action), .{ locks.asArg(fh), arg2, arg3, 0, 0 }) orelse
        return failWith(db, dos.ERROR_NO_FREE_STORE, -1);
    if (answer.res1 < 0) _ = dos_lib.SetIoErr(answer.res2);
    return answer.res1;
}

/// Reads with one ACTION_READ, past the handle's buffer.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the handle.
/// - `buffer` - where the bytes go.
/// - `length` - how many are wanted.
///
/// RESULT:
/// The count, 0 at the end, or -1 with `IoErr()` set.
pub fn rawRead(db: *DosBase, fh: *FileHandle, buffer: [*]u8, length: isize) isize {
    return fileAction(db, fh, .read, locks.asArg(buffer), length);
}

/// Writes with one ACTION_WRITE, past the handle's buffer.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the handle.
/// - `buffer` - the bytes.
/// - `length` - how many.
///
/// RESULT:
/// The count written, or -1 with `IoErr()` set.
pub fn rawWrite(db: *DosBase, fh: *FileHandle, buffer: [*]const u8, length: isize) isize {
    return fileAction(db, fh, .write, locks.asArg(buffer), length);
}

/// Moves the handler's position with one ACTION_SEEK, past the handle's
/// buffer.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the handle.
/// - `position` - the offset.
/// - `mode` - `OFFSET_BEGINNING`, `OFFSET_CURRENT` or `OFFSET_END`.
///
/// RESULT:
/// The old position, or -1 with `IoErr()` set.
pub fn rawSeek(db: *DosBase, fh: *FileHandle, position: isize, mode: i32) isize {
    return fileAction(db, fh, .seek, position, mode);
}

/// Sends a console's packet - SCREEN_MODE, WAIT_CHAR - with its one
/// argument to the handle's handler.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the handle.
/// - `action` - the packet type.
/// - `arg` - its first argument.
///
/// RESULT:
/// Whether dp_Res1 is nonzero. A false with a dp_Res2 sets `IoErr()`; a
/// plain false (WAIT_CHAR's time running out) leaves it.
pub fn consoleAction(db: *DosBase, fh: *FileHandle, action: ActionCode, arg: isize) bool {
    const dos_lib = db.iface();
    const port = fh.task orelse return failWith(db, dos.ERROR_INVALID_LOCK, 0) != 0;
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(action), .{ arg, 0, 0, 0, 0 }) orelse
        return failWith(db, dos.ERROR_NO_FREE_STORE, 0) != 0;
    if (answer.res1 == 0 and answer.res2 != 0) _ = dos_lib.SetIoErr(answer.res2);
    return answer.res1 != 0;
}

/// Asks an open file's handler for a lock - COPY_DIR_FH, PARENT_FH - with
/// the handle as the packet's argument.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `file` - the handle; null is `ERROR_INVALID_LOCK`.
/// - `action` - the packet type.
///
/// RESULT:
/// The handler's lock, or null with `IoErr()` set.
pub fn handleLock(db: *DosBase, file: ?*FileHandle, action: ActionCode) ?*dos.FileLock {
    const dos_lib = db.iface();
    const fh = file orelse return @ptrFromInt(@as(usize, @bitCast(failWith(db, dos.ERROR_INVALID_LOCK, 0))));
    const port = fh.task orelse return @ptrFromInt(@as(usize, @bitCast(failWith(db, dos.ERROR_INVALID_LOCK, 0))));
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(action), .{ locks.asArg(fh), 0, 0, 0, 0 }) orelse
        return @ptrFromInt(@as(usize, @bitCast(failWith(db, dos.ERROR_NO_FREE_STORE, 0))));
    if (answer.res1 == 0) _ = dos_lib.SetIoErr(answer.res2);
    return @ptrFromInt(@as(usize, @bitCast(answer.res1)));
}

/// The size the handle's buffer has, or will have when it is allocated.
///
/// INPUTS:
/// - `fh` - the handle.
pub fn bufferSize(fh: *const FileHandle) u32 {
    return if (fh.buf_size == 0) stdio.BUFFER_SIZE else fh.buf_size;
}

/// The handle's buffer, allocated on first use.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the handle.
///
/// RESULT:
/// The buffer, or null with `ERROR_NO_FREE_STORE`.
///
/// OWNERSHIP:
/// An allocated buffer is dos's (`buf_owned`), freed by `release` or a
/// later `SetVBuf`.
pub fn bufferOf(db: *DosBase, fh: *FileHandle) ?[*]u8 {
    const dos_lib = db.iface();
    if (fh.buf) |b| return b;
    const size = bufferSize(fh);
    const block = db.sys_base.AllocVec(size, exec.MEMF_ANY) orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    fh.buf = @ptrCast(block);
    fh.buf_size = size;
    fh.buf_owned = true;
    return fh.buf;
}

/// Whether '\n' and '\r' write the buffer out: line buffering, on a
/// console.
///
/// INPUTS:
/// - `fh` - the handle.
pub fn lineBuffered(fh: *const FileHandle) bool {
    return fh.buf_mode == stdio.BUF_LINE and fh.interactive;
}

/// Writes the waiting bytes out, and leaves the handle empty.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - a writing handle.
///
/// RESULT:
/// True when all went out. False with `IoErr()` set (`ERROR_DISK_FULL`
/// when the handler wrote nothing); what didn't go stays at the front of
/// the buffer for the next try.
pub fn drain(db: *DosBase, fh: *FileHandle) bool {
    const dos_lib = db.iface();
    var done: u32 = 0;
    while (done < fh.pos) {
        const b = fh.buf.?;
        const n = rawWrite(db, fh, b + done, @intCast(fh.pos - done));
        if (n <= 0) {
            if (n == 0) _ = dos_lib.SetIoErr(dos.ERROR_DISK_FULL);
            db.sys_base.CopyMem(b + done, b, fh.pos - done);
            fh.pos -= done;
            return false;
        }
        done += @intCast(n);
    }
    fh.pos = 0;
    fh.state = .empty;
    return true;
}

/// Empties the buffer, so the handler's position is the caller's: waiting
/// bytes are written, bytes read ahead and pushed back are seeked back
/// over. On a console they are dropped, having no position to go back to.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the handle.
///
/// RESULT:
/// False with `IoErr()` set when the write or the seek failed.
///
/// A pushed-back character is seeked back over only when it stands for a
/// byte the file gave; one the caller made up has no place in the file.
pub fn flush(db: *DosBase, fh: *FileHandle) bool {
    switch (fh.state) {
        .empty => return true,
        .write => return drain(db, fh),
        .read => {
            const back: isize = @as(isize, @intCast(fh.end - fh.pos)) + @popCount(fh.unget_backed);
            fh.pos = 0;
            fh.end = 0;
            fh.unget_count = 0;
            fh.unget_backed = 0;
            fh.last = FileHandle.NO_CHAR;
            fh.state = .empty;
            if (back == 0 or fh.interactive) return true;
            return rawSeek(db, fh, -back, dos.OFFSET_CURRENT) >= 0;
        },
    }
}

/// Makes the handle ready for an unbuffered write, as `flush` does - except
/// that a reading console keeps what it read ahead, since it has no
/// position to give back. Write and Flush use it.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the handle.
///
/// RESULT:
/// False with `IoErr()` set when `flush` failed.
pub fn beforeWrite(db: *DosBase, fh: *FileHandle) bool {
    if (fh.state == .read and fh.interactive) return true;
    return flush(db, fh);
}

/// What a handle's buffer held while RunCommand lends it an argument line:
/// the FileHandle's buffer fields, kept aside by `lend` for `giveBack`.
pub const Lent = struct {
    buf: ?[*]u8,
    buf_size: u32,
    pos: u32,
    end: u32,
    state: dos.BufferState,
    buf_owned: bool,
    unget_count: u8,
    unget_backed: u8,
    unget: [4]i16,
    last: i16,
    lent: bool,
};

/// Lends a handle an argument line: `line` becomes what the handle has
/// read ahead, so FGetC and ReadArgs read it first. Bytes waiting to be
/// written are written out first.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the command's input handle.
/// - `line` - the argument line; it must outlive the command.
///
/// RESULT:
/// What the handle held, for `giveBack`.
pub fn lend(db: *DosBase, fh: *FileHandle, line: []u8) Lent {
    if (fh.state == .write) _ = drain(db, fh);
    const saved: Lent = .{
        .buf = fh.buf,
        .buf_size = fh.buf_size,
        .pos = fh.pos,
        .end = fh.end,
        .state = fh.state,
        .buf_owned = fh.buf_owned,
        .unget_count = fh.unget_count,
        .unget_backed = fh.unget_backed,
        .unget = fh.unget,
        .last = fh.last,
        .lent = fh.lent,
    };
    fh.buf = line.ptr;
    fh.buf_size = @intCast(line.len);
    fh.pos = 0;
    fh.end = @intCast(line.len);
    fh.state = .read;
    fh.buf_owned = false;
    fh.unget_count = 0;
    fh.unget_backed = 0;
    fh.last = FileHandle.NO_CHAR;
    fh.lent = true;
    return saved;
}

/// Gives a handle its own buffer back after the command, freeing one the
/// command's calls allocated meanwhile.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the handle `lend` was given.
/// - `saved` - what `lend` answered.
pub fn giveBack(db: *DosBase, fh: *FileHandle, saved: Lent) void {
    if (fh.state == .write) _ = drain(db, fh);
    if (fh.buf_owned) {
        if (fh.buf) |b| {
            if (saved.buf == null or b != saved.buf.?) db.sys_base.FreeVec(b);
        }
    }
    fh.buf = saved.buf;
    fh.buf_size = saved.buf_size;
    fh.pos = saved.pos;
    fh.end = saved.end;
    fh.state = saved.state;
    fh.buf_owned = saved.buf_owned;
    fh.unget_count = saved.unget_count;
    fh.unget_backed = saved.unget_backed;
    fh.unget = saved.unget;
    fh.last = saved.last;
    fh.lent = saved.lent;
}

/// Close's part: writes the waiting bytes and frees dos's buffer. A
/// buffer the caller gave SetVBuf is left alone.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the handle being closed.
///
/// RESULT:
/// Whether the waiting bytes went out; `IoErr()` says why not.
pub fn release(db: *DosBase, fh: *FileHandle) bool {
    const written = fh.state != .write or drain(db, fh);
    if (fh.buf_owned) {
        if (fh.buf) |b| db.sys_base.FreeVec(b);
    }
    fh.buf = null;
    fh.buf_owned = false;
    fh.state = .empty;
    return written;
}

/// Fills the buffer from the handler with one ACTION_READ (one byte with
/// BUF_NONE). A lent argument line, once read, is dropped for a buffer of
/// the handle's own.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the handle.
///
/// RESULT:
/// READ's answer: the count, 0 at the end (`IoErr()` cleared, and the end
/// is what UnGetC(-1) pushes back), -1 on an error.
pub fn refill(db: *DosBase, fh: *FileHandle) isize {
    const dos_lib = db.iface();
    if (fh.lent) { // the argument line is read: a real buffer (giveBack frees it)
        fh.buf = null;
        fh.buf_size = 0;
        fh.lent = false;
    }
    const b = bufferOf(db, fh) orelse return -1;
    const want: isize = if (fh.buf_mode == stdio.BUF_NONE) 1 else @intCast(fh.buf_size);
    const n = rawRead(db, fh, b, want);
    fh.pos = 0;
    fh.end = if (n > 0) @intCast(n) else 0;
    fh.state = .read;
    if (n == 0) {
        _ = dos_lib.SetIoErr(0);
        fh.last = -1;
    } else if (n < 0) {
        fh.last = FileHandle.NO_CHAR;
    }
    return n;
}

/// What `take` moved: how many bytes, and whether a pushed-back end
/// stopped it.
const Taken = struct { count: usize, end: bool };

/// Moves what the handle holds into `dest`: pushed-back characters first,
/// then read-ahead. A pushed-back end stops it.
///
/// INPUTS:
/// - `fh` - the handle.
/// - `dest` - where the bytes go.
/// - `want` - how many at most.
pub fn take(fh: *FileHandle, dest: [*]u8, want: usize) Taken {
    var got: usize = 0;
    while (got < want and fh.unget_count > 0) {
        fh.unget_count -= 1;
        fh.unget_backed &= ~(@as(u8, 1) << @intCast(fh.unget_count));
        const c = fh.unget[fh.unget_count];
        if (c < 0) return .{ .count = got, .end = true };
        dest[got] = @intCast(c);
        got += 1;
    }
    const n: usize = @min(fh.end - fh.pos, want - got);
    if (n > 0) {
        @memcpy(dest[got..][0..n], fh.buf.?[fh.pos..][0..n]);
        fh.pos += @intCast(n);
        got += n;
    }
    return .{ .count = got, .end = false };
}

/// Read's part: what the buffer holds first, then one ACTION_READ for the
/// rest - on a console only when the buffer had nothing, so a line typed
/// is not waited past.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `fh` - the handle.
/// - `dest` - where the bytes go.
/// - `length` - how many are wanted.
///
/// RESULT:
/// As Read: the count, 0 at the end, -1 on an error before any byte.
pub fn readThrough(db: *DosBase, fh: *FileHandle, dest: [*]u8, length: isize) isize {
    if (fh.state == .write and !drain(db, fh)) return -1;
    fh.last = FileHandle.NO_CHAR;
    if (fh.state != .read or length <= 0) return rawRead(db, fh, dest, length);
    const want: usize = @intCast(length);
    const taken = take(fh, dest, want);
    const got: isize = @intCast(taken.count);
    if (taken.end or taken.count == want or (taken.count > 0 and fh.interactive)) return got;
    const n = rawRead(db, fh, dest + taken.count, @intCast(want - taken.count));
    if (n < 0) return if (got > 0) got else -1;
    return got + n;
}

/// VFPrintf's state, and RawDoFmt's output function for it. Each
/// character goes out one call late, so the NUL RawDoFmt ends with - and
/// only that - stays out of the file.
pub const Printing = struct {
    /// The library's base, for FPutC.
    db: *DosBase,
    /// Where the text goes.
    fh: ?*FileHandle,
    /// The character given last, not yet written.
    held: ?u8 = null,
    /// The bytes written so far.
    count: i32 = 0,
    /// A write failed; the rest is dropped.
    failed: bool = false,

    /// Writes the held character and holds `c`.
    ///
    /// INPUTS:
    /// - `c` - the next character from RawDoFmt.
    /// - `data` - the `Printing`.
    pub fn put(c: u8, data: ?*anyopaque) callconv(.c) void {
        const p: *Printing = @ptrCast(@alignCast(data.?));
        const dos_lib = p.db.iface();
        if (p.held) |h| {
            if (!p.failed) {
                if (dos_lib.FPutC(p.fh, h) < 0) p.failed = true else p.count += 1;
            }
        }
        p.held = c;
    }
};
