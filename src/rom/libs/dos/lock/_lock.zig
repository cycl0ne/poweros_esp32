// SPDX-License-Identifier: MPL-2.0
//! Objects on a file system: locks on them, examining them, changing them
//! without opening them, and pattern searches over them.
//!
//! Locks: the calls that name an object or hold a lock on one - Lock,
//! UnLock, DupLock, ParentDir, SameLock, CurrentDir, CreateDir,
//! DeleteFile, ChangeMode, Info, IsFileSystem and SameDevice.
//!
//! The handler makes and frees every lock; dos only passes them on, and
//! reads a lock's port (`task`), volume and key. So each call is a packet,
//! sent through one of two helpers:
//!
//! - nameAction, for a call given a name: GetDeviceProc finds the handler
//!   and the directory the name is relative to, and the handler gets that
//!   directory's lock and the whole name, device part included, so it
//!   never has to be told what dos stripped. A name over 255 characters is
//!   refused with ERROR_LINE_TOO_LONG rather than cut, since a cut name
//!   names something else. On a multi-directory assign the next directory
//!   is asked only after ERROR_OBJECT_NOT_FOUND: any other answer - no
//!   room, protected, in use - is about the object that was found, and
//!   going on would hide it.
//! - lockAction, for a call given a lock: the lock's handler, or for a
//!   null lock the process's file system.
//!
//! Soft links are not followed and no requester is put up; a failure is
//! the call's result and IoErr(). CurrentDir from a plain task is null,
//! since a task has no current directory to swap.
//!
//! The examine calls: Examine, ExNext and ExamineFH, one object at a time
//! into a FileInfoBlock; ExAll and ExAllEnd, many entries of a directory
//! into a buffer at once.
//!
//! Each is a packet to the object's handler (ACTION_EXAMINE_OBJECT,
//! EXAMINE_NEXT, EXAMINE_FH, EXAMINE_ALL, EXAMINE_ALL_END). The owner
//! fields of the FileInfoBlock are cleared before a handler sees it, so a
//! handler that has no owners leaves them 0 rather than stale.
//!
//! A handler that doesn't know EXAMINE_ALL gets ExAll done for it:
//! `emulate` walks the directory with EXAMINE_OBJECT and EXAMINE_NEXT on a
//! FileInfoBlock of dos's own, kept in the control's last_key while the
//! listing is under way, and packs each entry into the caller's buffer as
//! the handler would. A record is aligned for its pointers, its strings
//! follow its fields, and it is offered to the MatchString and then the
//! MatchFunc hook before it counts. The FileInfoBlock is freed, and
//! last_key set back to 0, when the listing ends or ExAllEnd stops it.
//!
//! The calls that change an object on its volume without opening it: Rename,
//! SetProtection, SetComment, SetFileDate and SetOwner.
//!
//! The four setters are one shape: the name goes through the lock layer's
//! `nameAction`, which finds the handler and directory with GetDeviceProc
//! and sends the packet (ACTION_SET_PROTECT, SET_COMMENT, SET_DATE,
//! SET_OWNER) as (the directory's lock, the name, the value). The value is
//! the protection bits, the comment as a C string, the DateStamp's address,
//! or the owner as user << 16 | group. Along a multi-assign the packet goes
//! to each directory in turn while the object isn't found, so a name
//! resolves the same way Lock resolves it.
//!
//! Rename is the one call with two names. Both must be on one handler - a
//! packet goes to one handler, and moving between two would be a copy, which
//! is the caller's business - so it is ERROR_RENAME_ACROSS_DEVICES
//! otherwise. The packet is ACTION_RENAME_OBJECT (source directory, source
//! name, target directory, target name); the source is looked for along its
//! multi-assign like any name, and the target goes into the first directory
//! of its path, where a new file would go. A name over 255 characters is
//! ERROR_LINE_TOO_LONG rather than cut, since a cut name is another object.
//!
//! Pattern searches: MatchFirst, MatchNext and MatchEnd, with
//! utility.library's patterns.
//!
//! MatchFirst splits the pattern into a chain of AChain levels hanging off
//! the AnchorPath: one for the plain part before the first wildcard, one for
//! each level with wildcards, and the last part always one of its own. The
//! first level holds the lock the search starts in. MatchNext walks the
//! chain as a small state machine (`Step`): a plain level is located by
//! name, a wild one is read with ExNext and each entry matched; a match on
//! the last level is reported, a directory matched on an inner level is gone
//! into. The entry goes to ap_Info and, when ap_Strlen isn't 0, its full
//! path - built from the levels' names - to the buffer after the AnchorPath,
//! cut to fit with its NUL and ERROR_BUFFER_OVERFLOW. Setting APF_DODIR
//! before MatchNext adds an any-name level under the directory just found;
//! when it is read through the directory comes once more with APF_DIDDIR.
//! MatchEnd unlocks and frees the chain.
//!
//! The device part of a pattern is literal, and a pattern is split at '/'
//! before its groups are looked at, so a group can't hold a '/'. "*" and the
//! names of handlers that aren't file systems (NIL:, CON:) give one entry,
//! the name itself, so a command that takes a pattern also takes those. Any
//! error other than ERROR_BUFFER_OVERFLOW ends the search and frees the
//! chain, so the caller need only call MatchEnd after a search it stops
//! itself.
//!
//! A search works from a plain task too, for names with a device: a name in
//! a level's directory is located by a packet to that directory's handler,
//! and errors are taken from the packets, never from a stale IoErr.
//! APF_DOWILD and APF_DODOT are not looked at, and APF_DIDDIR stays set
//! until the caller clears it.

const sdk = @import("sdk");
const packets = @import("../packet/_packet.zig");
const process = @import("../process/_process.zig");
const DosBase = @import("../dos_base.zig").DosBase;
const paths = @import("../text/_text.zig");
const dos = sdk.dos;
const FileLock = dos.FileLock;
const FileHandle = dos.FileHandle;
const MsgPort = sdk.exec.MsgPort;
const ActionCode = dos.ActionCode;
const max_name = 255;
const FileInfoBlock = dos.FileInfoBlock;
const ExAllControl = dos.ExAllControl;
const ExAllData = dos.ExAllData;
const Hook = sdk.utility.Hook;
const exec = sdk.exec;
const utility = sdk.utility;
const AnchorPath = dos.AnchorPath;
const AChain = dos.AChain;

/// The longest name a handler is sent.
/// A pointer (or null) as a packet argument.
///
/// INPUTS:
/// - `p` - the pointer; any pointer or optional pointer type.
pub fn asArg(p: anytype) isize {
    return @bitCast(@intFromPtr(p));
}

/// A packet's dp_Res1 as the lock it is; 0 is null.
///
/// INPUTS:
/// - `value` - dp_Res1.
pub fn asLock(value: isize) ?*FileLock {
    return @ptrFromInt(@as(usize, @bitCast(value)));
}

/// Sets IoErr() to `code` and returns 0, a failed dp_Res1.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `code` - the error.
pub fn failZero(db: *DosBase, code: i32) isize {
    const dos_lib = db.iface();
    _ = dos_lib.SetIoErr(code);
    return 0;
}

/// What nameAction sends besides the directory and the name.
pub const NameArgs = struct {
    /// For the FIND actions: the handle, sent first (fh, directory, name);
    /// its `task` is set to the handler's port.
    fh: ?*FileHandle = null,
    arg3: isize = 0,
    arg4: isize = 0,
    /// Along a multi-assign while the object isn't found (not for
    /// MODE_NEWFILE, which makes its file in the first directory).
    retry: bool = true,
};

/// Sends a packet about a named object to the name's handler, along a
/// multi-directory assign while the object isn't found.
///
/// The arguments are (the directory's lock, the whole name, arg3, arg4),
/// or for a handle (fh, the directory's lock, the whole name), with the
/// handle's `task` set to the handler's port.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `name` - the object's name; at most 255 characters.
/// - `action` - the packet type.
/// - `extra` - the handle or the two further arguments, and whether an
///   assign's next directory may be tried.
///
/// RESULT:
/// dp_Res1, or 0 with IoErr() set.
///
/// CONTEXT:
/// - Waits: yes, for GetDeviceProc and the handler.
pub fn nameAction(db: *DosBase, name: [*:0]const u8, action: ActionCode, extra: NameArgs) isize {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    if (db.utility_base.Strlen(name) > max_name) return failZero(db, dos.ERROR_LINE_TOO_LONG);
    var dp = dos_lib.GetDeviceProc(name, null) orelse return 0;
    while (true) {
        const port = dp.port orelse {
            dos_lib.FreeDeviceProc(dp);
            return failZero(db, dos.ERROR_DEVICE_NOT_MOUNTED);
        };
        const args: [5]isize = if (extra.fh) |fh| blk: {
            fh.task = port;
            break :blk .{ asArg(fh), asArg(dp.lock), asArg(name), 0, 0 };
        } else .{ asArg(dp.lock), asArg(name), extra.arg3, extra.arg4, 0 };
        const answer = packets.exchange(sys, port, @intFromEnum(action), args) orelse {
            dos_lib.FreeDeviceProc(dp);
            return failZero(db, dos.ERROR_NO_FREE_STORE);
        };
        if (answer.res1 != 0) {
            dos_lib.FreeDeviceProc(dp);
            return answer.res1;
        }
        if (!extra.retry or answer.res2 != dos.ERROR_OBJECT_NOT_FOUND or dp.flags & dos.DVPF_ASSIGN == 0) {
            dos_lib.FreeDeviceProc(dp);
            return failZero(db, answer.res2);
        }
        // The assign's next directory.
        const next = dos_lib.GetDeviceProc(name, dp) orelse {
            dos_lib.FreeDeviceProc(dp);
            return failZero(db, dos.ERROR_OBJECT_NOT_FOUND);
        };
        if (next != dp) dos_lib.FreeDeviceProc(dp);
        dp = next;
    }
}

/// The calling process's file system, the handler for a null lock; null
/// from a plain task.
///
/// INPUTS:
/// - `db` - dos.library's base.
pub fn fileSystemTask(db: *DosBase) ?*MsgPort {
    const proc = process.currentProcess(db.sys_base) orelse return null;
    return proc.file_system_task;
}

/// Sends a packet with two arguments to a lock's handler, or for a null
/// lock to the process's file system.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `l` - the lock, or null.
/// - `action` - the packet type.
/// - `arg1` - dp_Arg1.
/// - `arg2` - dp_Arg2.
///
/// RESULT:
/// dp_Res1; when it is 0, IoErr() is dp_Res2, or ERROR_DEVICE_NOT_MOUNTED
/// when there was no handler, or ERROR_NO_FREE_STORE when no packet could
/// be sent.
pub fn lockAction(db: *DosBase, l: ?*FileLock, action: ActionCode, arg1: isize, arg2: isize) isize {
    const dos_lib = db.iface();
    const port = (if (l) |it| it.task else fileSystemTask(db)) orelse return failZero(db, dos.ERROR_DEVICE_NOT_MOUNTED);
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(action), .{ arg1, arg2, 0, 0, 0 }) orelse
        return failZero(db, dos.ERROR_NO_FREE_STORE);
    if (answer.res1 == 0) _ = dos_lib.SetIoErr(answer.res2);
    return answer.res1;
}

/// Whether a name is on a file system: a name without a device part is;
/// otherwise its handler answers ACTION_IS_FILESYSTEM, and one that
/// doesn't know the packet is a file system if its root can be locked.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `name` - the name.
/// - `code` - where the error goes when the answer is null.
///
/// RESULT:
/// The answer, or null when the name has no handler (or no packet could
/// be sent), with the error in `code`.
pub fn fileSystemOf(db: *DosBase, name: [*:0]const u8, code: *i32) ?bool {
    const dos_lib = db.iface();
    const colon_at = db.utility_base.Strchr(name, ':') orelse return true;
    const colon = @intFromPtr(colon_at) - @intFromPtr(name);
    const dp = dos_lib.GetDeviceProc(name, null) orelse {
        code.* = if (process.currentProcess(db.sys_base) != null) dos_lib.IoErr() else dos.ERROR_DEVICE_NOT_MOUNTED;
        return null;
    };
    defer dos_lib.FreeDeviceProc(dp);
    const port = dp.port orelse return false;
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(ActionCode.is_filesystem), .{ 0, 0, 0, 0, 0 }) orelse {
        code.* = dos.ERROR_NO_FREE_STORE;
        return null;
    };
    if (answer.res1 != 0) return true;
    if (answer.res2 == 0) return false;
    if (answer.res2 != dos.ERROR_ACTION_NOT_KNOWN) {
        code.* = answer.res2;
        return null;
    }
    // An old handler: is there a root to lock?
    var root: [dos.MAX_DEVICE_NAME + 2:0]u8 = @splat(0);
    if (colon + 1 > root.len) return false;
    @memcpy(root[0 .. colon + 1], name[0 .. colon + 1]);
    const l = dos_lib.Lock(&root, dos.SHARED_LOCK) orelse return false;
    dos_lib.UnLock(l);
    return true;
}

/// Sets IoErr to `code` and answers false, for the calls' failure paths.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `code` - the error code.
pub fn fail(db: *DosBase, code: i32) bool {
    const dos_lib = db.iface();
    _ = dos_lib.SetIoErr(code);
    return false;
}

/// Zeroes a FileInfoBlock's owner fields, for handlers that have no owners
/// and so never set them.
///
/// INPUTS:
/// - `fib` - the block a handler is about to fill in.
pub fn clearOwner(fib: *FileInfoBlock) void {
    fib.owner_uid = 0;
    fib.owner_gid = 0;
}

// --- ExAll ---

/// The bytes of an ExAllData record's fields at a level, up to the end of
/// its last one; the strings go after.
///
/// INPUTS:
/// - `level` - ED_NAME .. ED_OWNER.
fn fixedSize(level: i32) usize {
    return switch (level) {
        dos.ED_NAME => @offsetOf(ExAllData, "name") + @sizeOf(?[*:0]u8),
        dos.ED_TYPE => @offsetOf(ExAllData, "type") + @sizeOf(i32),
        dos.ED_SIZE => @offsetOf(ExAllData, "size") + @sizeOf(u64),
        dos.ED_PROTECTION => @offsetOf(ExAllData, "prot") + @sizeOf(u32),
        dos.ED_DATE => @offsetOf(ExAllData, "ticks") + @sizeOf(i32),
        dos.ED_COMMENT => @offsetOf(ExAllData, "comment") + @sizeOf(?[*:0]u8),
        else => @offsetOf(ExAllData, "owner_gid") + @sizeOf(u16),
    };
}

/// Packs a FileInfoBlock's entry as an ExAllData record into the buffer at
/// `pos.*`, aligned, its name (and comment) after its fields, and moves
/// `pos.*` past it. Null, and `pos.*` unchanged, when it doesn't fit.
///
/// INPUTS:
/// - `db` - dos.library's base, for utility.library.
/// - `buffer` - the caller's ExAll buffer.
/// - `size` - the buffer's size.
/// - `pos` - where the next record may start.
/// - `level` - which fields the record has.
/// - `fib` - the entry.
fn pack(db: *DosBase, buffer: [*]u8, size: usize, pos: *usize, level: i32, fib: *const FileInfoBlock) ?*ExAllData {
    const utility_lib = db.utility_base;
    const base = @intFromPtr(buffer);
    const start = utility_lib.AlignUp(base + pos.*, @alignOf(ExAllData)) - base;
    const name = fib.file_name[0..utility_lib.Strlen(@ptrCast(&fib.file_name))];
    const comment = fib.comment[0..utility_lib.Strlen(@ptrCast(&fib.comment))];
    const fixed = fixedSize(level);
    const with_comment = level >= dos.ED_COMMENT;
    const need = fixed + name.len + 1 + (if (with_comment) comment.len + 1 else 0);
    if (start + need > size) return null;

    const rec: *ExAllData = @ptrFromInt(base + start);
    var text: [*]u8 = buffer + start + fixed;
    rec.next = null;
    @memcpy(text[0..name.len], name);
    text[name.len] = 0;
    rec.name = @ptrCast(text);
    text += name.len + 1;
    if (level >= dos.ED_TYPE) rec.type = fib.dir_entry_type;
    if (level >= dos.ED_SIZE) rec.size = fib.size;
    if (level >= dos.ED_PROTECTION) rec.prot = fib.protection;
    if (level >= dos.ED_DATE) {
        rec.days = fib.date.days;
        rec.minute = fib.date.minute;
        rec.ticks = fib.date.tick;
    }
    if (with_comment) {
        @memcpy(text[0..comment.len], comment);
        text[comment.len] = 0;
        rec.comment = @ptrCast(text);
    }
    if (level >= dos.ED_OWNER) {
        rec.owner_uid = fib.owner_uid;
        rec.owner_gid = fib.owner_gid;
    }
    pos.* = start + need;
    return rec;
}

/// One EXAMINE_OBJECT or EXAMINE_NEXT for the emulation. Null when the
/// FileInfoBlock got an entry, else the error - returned rather than put in
/// IoErr, which a plain task doesn't have.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `l` - the directory's lock.
/// - `fib` - dos's own FileInfoBlock for the listing.
/// - `action` - `.examine_object` or `.examine_next`.
pub fn step(db: *DosBase, l: *FileLock, fib: *FileInfoBlock, action: ActionCode) ?i32 {
    const port = l.task orelse return dos.ERROR_INVALID_LOCK;
    clearOwner(fib);
    const answer = packets.exchange(db.sys_base, port, @intFromEnum(action), .{ asArg(l), asArg(fib), 0, 0, 0 }) orelse
        return dos.ERROR_NO_FREE_STORE;
    return if (answer.res1 != 0) null else answer.res2;
}

/// Ends an emulated listing: its FileInfoBlock freed, last_key 0 again,
/// IoErr `code`, and false.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `control` - the listing's control.
/// - `fib` - the listing's FileInfoBlock.
/// - `code` - the error to leave, ERROR_NO_MORE_ENTRIES at the end.
fn endExAll(db: *DosBase, control: *ExAllControl, fib: *FileInfoBlock, code: i32) bool {
    const dos_lib = db.iface();
    dos_lib.FreeDosObject(dos.DOS_FIB, fib);
    control.last_key = 0;
    return fail(db, code);
}

/// ExAll for a handler that doesn't know EXAMINE_ALL. True when the buffer
/// is full, the entry that didn't fit kept for the next call; false when the
/// directory ends (ERROR_NO_MORE_ENTRIES), when the buffer cannot hold even
/// one record (ERROR_BUFFER_OVERFLOW), or on an error.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `lock` - the directory; null fails with ERROR_INVALID_LOCK.
/// - `buffer` - where the records go.
/// - `size` - the buffer's size.
/// - `level` - ED_NAME .. ED_OWNER.
/// - `control` - the listing's control; last_key holds dos's FileInfoBlock
///   between calls.
///
/// BEHAVIOR:
/// A record the MatchString or the MatchFunc hook leaves out takes no room
/// in the buffer.
pub fn emulate(db: *DosBase, lock: ?*FileLock, buffer: [*]u8, size: isize, level: i32, control: *ExAllControl) bool {
    const dos_lib = db.iface();
    control.entries = 0;
    const l = lock orelse return fail(db, dos.ERROR_INVALID_LOCK);
    var fib: *FileInfoBlock = undefined;
    var pending = false;
    if (control.last_key != 0) {
        fib = @ptrFromInt(control.last_key);
        pending = true;
    } else {
        fib = @ptrCast(@alignCast(dos_lib.AllocDosObject(dos.DOS_FIB, null) orelse return false));
        if (step(db, l, fib, .examine_object)) |code| return endExAll(db, control, fib, code);
        if (fib.dir_entry_type < 0) return endExAll(db, control, fib, dos.ERROR_OBJECT_WRONG_TYPE);
    }
    const room: usize = if (size > 0) @intCast(size) else 0;
    var pos: usize = 0;
    var last: ?*ExAllData = null;
    while (true) {
        if (!pending) {
            if (step(db, l, fib, .examine_next)) |code| return endExAll(db, control, fib, code);
        }
        pending = false;
        if (control.match_string) |pat| {
            if (!db.utility_base.MatchPatternNoCase(pat, @ptrCast(&fib.file_name))) continue;
        }
        const mark = pos;
        const rec = pack(db, buffer, room, &pos, level, fib) orelse {
            // Not even one record fits: another call with this buffer would
            // answer the same, and a caller looping until false never ends.
            if (control.entries == 0) return endExAll(db, control, fib, dos.ERROR_BUFFER_OVERFLOW);
            control.last_key = @intFromPtr(fib);
            return true;
        };
        if (control.match_func) |hook| {
            var data_type: i32 = level;
            if (db.utility_base.CallHookPkt(hook, &data_type, rec) == 0) {
                pos = mark;
                continue;
            }
        }
        if (last) |prev| prev.next = rec;
        last = rec;
        control.entries += 1;
    }
}

/// The handler port an ExAll goes to: the lock's, or for null the current
/// file system's.
///
/// INPUTS:
/// - `db` - dos.library's base.
/// - `lock` - the directory, or null.
pub fn portFor(db: *DosBase, lock: ?*FileLock) ?*sdk.exec.MsgPort {
    return if (lock) |l| l.task else fileSystemTask(db);
}

/// A MatchFunc that leaves every entry out, so ExAllEnd can run a handler's
/// listing to its end without writing into the caller's buffer.
///
/// INPUTS:
/// - `hook` - the hook (unused).
/// - `data_type` - the level (unused).
/// - `record` - the record (unused).
pub fn takeNothing(_: *Hook, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) usize {
    return 0;
}

/// A u32 as a packet argument, all its bits kept (no sign extension).
///
/// INPUTS:
/// - `value` - the bits to send.
pub fn bitsArg(value: u32) isize {
    return @bitCast(@as(usize, value));
}

/// The level MatchNext adds to go into a directory (APF_DODIR): any name.
pub const any_name = [_:0]u8{utility.P_ANY};

/// Whether a byte of a parsed pattern is one of utility.library's tokens,
/// which makes the level it is in a wild one.
///
/// INPUTS:
/// - `c` - the byte.
fn isToken(c: u8) bool {
    return c >= utility.P_ANY and c <= utility.P_STOP;
}

/// Where a search keeps the error of the step that failed.
pub const Search = struct {
    db: *DosBase,
    ap: *AnchorPath,
    code: i32 = 0,

    /// Records `code` as the search's error and fails the step.
    ///
    /// INPUTS:
    /// - `s` - the search.
    /// - `code` - the error code (ERROR_*).
    fn fail(s: *Search, code: i32) error{Failed} {
        s.code = code;
        return error.Failed;
    }
};

/// IoErr when the caller is a process; a plain task has none, so `guess`.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `guess` - the error to answer from a task.
fn lastError(db: *DosBase, guess: i32) i32 {
    const dos_lib = db.iface();
    return if (process.currentProcess(db.sys_base) != null) dos_lib.IoErr() else guess;
}

/// Sets IoErr to `code` and answers it, the way every call here returns.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `code` - 0 or the error code.
pub fn matchAnswer(db: *DosBase, code: i32) i32 {
    const dos_lib = db.iface();
    _ = dos_lib.SetIoErr(code);
    return code;
}

/// Ends a search on an error: the chain is freed with MatchEnd, and `code`
/// answered.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `ap` - the search's anchor.
/// - `code` - the error code.
pub fn finish(db: *DosBase, ap: *AnchorPath, code: i32) i32 {
    const dos_lib = db.iface();
    dos_lib.MatchEnd(ap);
    return matchAnswer(db, code);
}

/// The name of a level's entry: the one ExNext found, for a wild level,
/// else the level's own string.
///
/// INPUTS:
/// - `node` - the level.
pub fn entryName(node: *AChain) [*:0]const u8 {
    return if (node.flags & dos.DDF_PatternBit != 0) @ptrCast(&node.info.file_name) else node.string();
}

/// Adds a level for `text` (up to a NUL in it) under ap_Last, or as the
/// first, and makes it ap_Last. A wild level's string is upper-cased for
/// MatchPatternNoCase. The first level also gets the lock the search starts
/// in: the path part of its string for a plain level (DDF_Single; its last
/// name is examined later), else the current directory. On failure the
/// search's error is set and APF_NOMEMERR too, which makes the next
/// MatchNext end the search.
///
/// INPUTS:
/// - `s` - the search.
/// - `text` - the level's part of the parsed pattern.
/// - `wild` - DDF_PatternBit for a wild level, else 0.
pub fn addAnchor(s: *Search, text: []const u8, wild: u8) error{Failed}!*AChain {
    const db = s.db;
    const dos_lib = db.iface();
    const ap = s.ap;
    var len: usize = 0;
    while (len < text.len and text[len] != 0) len += 1;
    const block = db.sys_base.AllocVec(@sizeOf(AChain) + len + 1, exec.MEMF_CLEAR) orelse {
        ap.flags |= dos.APF_NOMEMERR;
        return s.fail(dos.ERROR_NO_FREE_STORE);
    };
    const node: *AChain = @ptrCast(@alignCast(block));
    node.* = .{};
    const str = node.string();
    for (text[0..len], 0..) |c, i| str[i] = if (wild != 0) db.utility_base.ToUpper(c) else c;
    str[len] = 0;
    if (len > 0) node.flags = wild;
    if (ap.base != null) {
        ap.last.?.child = node;
        node.parent = ap.last;
        ap.last = node;
        return node;
    }
    ap.base = node;
    ap.last = node;
    const got = if (wild == 0) blk: {
        // The path part is where it starts; its last name is examined later.
        node.flags |= dos.DDF_Single;
        const cut = @intFromPtr(dos_lib.PathPart(str)) - @intFromPtr(str);
        const save = str[cut];
        str[cut] = 0;
        defer str[cut] = save;
        break :blk dos_lib.Lock(str, dos.SHARED_LOCK);
    } else dos_lib.Lock("", dos.SHARED_LOCK);
    node.lock = got orelse {
        ap.flags |= dos.APF_NOMEMERR;
        return s.fail(lastError(db, dos.ERROR_OBJECT_NOT_FOUND));
    };
    return node;
}

/// A shared lock on `name` in a level's directory, by ACTION_LOCATE_OBJECT
/// to the directory's handler; the first plain level, or one without a
/// directory, locks the whole name with Lock instead.
///
/// INPUTS:
/// - `s` - the search, which gets the error on failure.
/// - `node` - the level whose directory `name` is in.
/// - `name` - the entry's name.
pub fn relLock(s: *Search, node: *AChain, name: [*:0]const u8) error{Failed}!*FileLock {
    const dir = node.lock orelse return lockName(s, name);
    if (node.flags & dos.DDF_Single != 0) return lockName(s, name);
    const port = dir.task orelse return s.fail(dos.ERROR_INVALID_LOCK);
    const a = packets.exchange(s.db.sys_base, port, @intFromEnum(dos.ActionCode.locate_object), .{
        asArg(dir), asArg(name), dos.SHARED_LOCK, 0, 0,
    }) orelse return s.fail(dos.ERROR_NO_FREE_STORE);
    if (a.res1 == 0) return s.fail(a.res2);
    return @ptrFromInt(@as(usize, @bitCast(a.res1)));
}

/// A shared lock on `name` with Lock, or the search's error set.
///
/// INPUTS:
/// - `s` - the search.
/// - `name` - the name.
fn lockName(s: *Search, name: [*:0]const u8) error{Failed}!*FileLock {
    const dos_lib = s.db.iface();
    const l = dos_lib.Lock(name, dos.SHARED_LOCK) orelse return s.fail(lastError(s.db, dos.ERROR_OBJECT_NOT_FOUND));
    return l;
}

/// What examining a level's entry found.
const Examined = enum { ok, not_dir, failed };

/// Examines a level's entry into its ap_Info, once per entry: not_dir for a
/// file where the pattern goes on below it, failed with the search's error
/// set when the handler refuses.
///
/// INPUTS:
/// - `s` - the search.
/// - `node` - the level.
/// - `l` - a lock on the entry.
pub fn examineNode(s: *Search, node: *AChain, l: *FileLock) Examined {
    if (node.flags & dos.DDF_ExaminedBit != 0) return .ok;
    if (step(s.db, l, &node.info, .examine_object)) |code| {
        s.code = code;
        return .failed;
    }
    node.flags |= dos.DDF_ExaminedBit;
    if (node.child == null or node.info.dir_entry_type >= 0) return .ok;
    return .not_dir;
}

/// Frees levels from `first` down, without unlocking their
///
/// INPUTS:
/// - `db` - the library's base.
/// - `first` - the highest level to free.
pub fn freeLevels(db: *DosBase, first: *AChain) void {
    var it: ?*AChain = first;
    while (it) |node| {
        it = node.child;
        db.sys_base.FreeVec(node);
    }
}

/// A byte onto the path in `buf`, keeping one byte for the NUL; false when
/// it doesn't fit.
///
/// INPUTS:
/// - `buf` - the caller's path buffer.
/// - `pos` - where the byte goes; moved on past it.
/// - `c` - the byte.
fn put(buf: []u8, pos: *usize, c: u8) bool {
    if (pos.* + 1 >= buf.len) return false;
    buf[pos.*] = c;
    pos.* += 1;
    return true;
}

/// Reports a match: the last level's entry into ap_Info, and, when
/// ap_Strlen isn't 0, the full path from the levels' names into the buffer,
/// with a '/' where one is needed. 0, or ERROR_BUFFER_OVERFLOW when the
/// path was cut.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `ap` - the search's anchor.
pub fn report(db: *DosBase, ap: *AnchorPath) i32 {
    ap.info = ap.last.?.info;
    if (ap.strlen == 0) return matchAnswer(db, 0);
    const buf = ap.buffer()[0..ap.strlen];
    var pos: usize = 0;
    var it = ap.base;
    const full = while (it) |node| : (it = node.child) {
        if (node != ap.base and pos > 0 and buf[pos - 1] != ':' and buf[pos - 1] != '/') {
            if (!put(buf, &pos, '/')) break false;
        }
        const entry = entryName(node);
        for (entry[0..db.utility_base.Strlen(entry)]) |c| {
            if (!put(buf, &pos, c)) break;
        } else continue;
        break false;
    } else true;
    buf[pos] = 0;
    return matchAnswer(db, if (full) 0 else dos.ERROR_BUFFER_OVERFLOW);
}

/// Where MatchNext's walk of the levels is.
pub const Step = enum { loop, enter, up, did_dir, wild, new_node, locate, check };

/// Builds the levels for a pattern, then finds the first entry with
/// MatchNext. The device part stays as it is; the rest goes through
/// ParsePattern into a buffer of this call's own, and is split into levels
/// at each '/' that ends a wild part. A trailing '/' goes, but not the one
/// of "dev:/" or "//".
///
/// INPUTS:
/// - `db` - the library's base.
/// - `ap` - the caller's anchor, cleared of levels.
/// - `pattern` - the pattern.
pub fn findFirst(db: *DosBase, ap: *AnchorPath, pattern: [*:0]const u8) i32 {
    const dos_lib = db.iface();
    var s: Search = .{ .db = db, .ap = ap };
    const text = pattern[0..db.utility_base.Strlen(pattern)];
    const size = (text.len + 1) * 2;
    const block = db.sys_base.AllocVec(size, exec.MEMF_CLEAR) orelse return finish(db, ap, dos.ERROR_NO_FREE_STORE);
    defer db.sys_base.FreeVec(block);
    const buf: [*]u8 = @ptrCast(block);
    // The device part, with its colon, stays as it is; the rest is parsed.
    const start = if (db.utility_base.Strchr(pattern, ':')) |colon| @intFromPtr(colon) - @intFromPtr(pattern) + 1 else 0;
    @memcpy(buf[0..start], text[0..start]);
    if (db.utility_base.ParsePattern(pattern + start, buf + start, size - start) < 0)
        return finish(db, ap, lastError(db, dos.ERROR_BAD_TEMPLATE));

    var base: usize = 0; // where the current level's text starts
    var last: usize = start; // after the last '/' or the colon
    var cur: usize = start;
    var wild: u8 = 0;
    while (buf[cur] != 0) {
        const c = buf[cur];
        cur += 1;
        if (c == '/') {
            // A trailing '/' goes, but not the one of "dev:/" or "//".
            if (buf[cur] == 0 and cur - last > 1) {
                cur -= 1;
                buf[cur] = 0;
                break;
            }
            last = cur;
            if (wild == 0) continue;
            _ = addAnchor(&s, buf[base .. cur - 1], wild) catch return finish(db, ap, s.code);
            base = last;
            wild = 0;
            continue;
        }
        if (!isToken(c) or wild != 0) continue;
        // A wildcard: the plain levels before it become one level.
        if (last != base) {
            _ = addAnchor(&s, buf[base..last], 0) catch return finish(db, ap, s.code);
            base = last;
        }
        wild = dos.DDF_PatternBit;
        ap.flags |= dos.APF_ITSWILD;
    }
    if (last != base) {
        _ = addAnchor(&s, buf[base..last], 0) catch return finish(db, ap, s.code);
        base = last;
    }
    _ = addAnchor(&s, buf[base..cur], wild) catch return finish(db, ap, s.code);
    ap.last = ap.base;
    const rc = dos_lib.MatchNext(ap);
    ap.flags |= dos.APF_DirChanged;
    return rc;
}

/// The one entry for "*" and a handler that isn't a file system: the name
/// itself, as a file, reported once. The level holds a copy of the current
/// directory's lock, so MatchEnd has the same work as for any search.
///
/// INPUTS:
/// - `db` - the library's base.
/// - `ap` - the caller's anchor.
/// - `text` - the name.
pub fn single(db: *DosBase, ap: *AnchorPath, text: []const u8) i32 {
    const dos_lib = db.iface();
    const block = db.sys_base.AllocVec(@sizeOf(AChain) + 1, exec.MEMF_CLEAR) orelse {
        ap.flags |= dos.APF_NOMEMERR;
        return matchAnswer(db, dos.ERROR_NO_FREE_STORE);
    };
    const node: *AChain = @ptrCast(@alignCast(block));
    node.* = .{ .flags = dos.DDF_Completed | dos.DDF_Single };
    ap.base = node;
    ap.last = node;
    if (process.currentProcess(db.sys_base)) |proc| node.lock = dos_lib.DupLock(proc.current_dir);
    const n = @min(text.len, node.info.file_name.len - 1);
    @memcpy(node.info.file_name[0..n], text[0..n]);
    node.info.file_name[n] = 0;
    node.info.dir_entry_type = -1;
    node.info.entry_type = -1;
    ap.info = node.info;
    ap.flags |= dos.APF_DirChanged;
    if (ap.strlen != 0) {
        const buf = ap.buffer()[0..ap.strlen];
        const m = @min(text.len, buf.len - 1);
        @memcpy(buf[0..m], text[0..m]);
        buf[m] = 0;
        if (m < text.len) return matchAnswer(db, dos.ERROR_BUFFER_OVERFLOW);
    }
    return matchAnswer(db, 0);
}
