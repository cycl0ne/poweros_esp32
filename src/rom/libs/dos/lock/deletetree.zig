// SPDX-License-Identifier: MPL-2.0
//! DeleteTree: an object deleted, a directory with all it holds.
//!
//! The walk keeps no recursion on the caller's stack: one path, cut and
//! lengthened as it goes down and up, one batch of names, and a small
//! level for each directory it is inside. A batch is read under one lock,
//! which is let go before the first name goes, so no listing goes on over
//! a name taken from it; a directory is listed again when its batch is
//! done, and after each directory below it, whose names took the batch. A
//! name is deleted first and gone into only when it is a directory that
//! is not empty.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const fail = _lock.fail;

/// Deletes `name`: a file, a link, or a directory and everything in it,
/// innermost first - or with DELF_KEEP only what the directory holds.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteTree(db: *DosBase, name: [*:0]const u8, flags: u32, hook: ?*utility.Hook) bool
/// ```
///
/// SINCE: 1.18. LVO -636.
///
/// INPUTS:
/// - `name` - the object, as for DeleteFile.
/// - `flags` - DELF_KEEP leaves the directory `name` itself, emptied;
///   DELF_FORCE takes a delete-protected object's protection off and
///   deletes it; DELF_ONWARD goes on past an object that will not go.
/// - `hook` - called for each object once it has been tried, with its
///   name as the object and a `dos.DeleteMsg` as the message; an answer
///   other than 0 stops the walk. Null for none.
///
/// RESULT:
/// True when everything went; false with IoErr() - the failure of the
/// object that would not go (with DELF_ONWARD the last one), ERROR_BREAK
/// when the hook stopped the walk, ERROR_OBJECT_WRONG_TYPE for DELF_KEEP
/// on a file, ERROR_NO_FREE_STORE, ERROR_LINE_TOO_LONG for a name below
/// `name` longer than dos.path_max.
///
/// BEHAVIOR:
/// Each object is deleted by its name, `name` and the parts below it. A
/// directory that is not empty is gone into, emptied, and deleted after
/// what it held. A soft link is deleted itself, never what it names. The
/// names of a directory are read a batch at a time - some hundred - and
/// the directory listed again after each batch and after each directory
/// below it, until it is empty.
///
/// Without DELF_ONWARD the walk ends at the first object that will not go,
/// what it was in left as it is. With it, such an object is passed over -
/// its directory then will not go either - and all else is deleted.
///
/// The hook hears of every object, a directory after what it held, its
/// `failure` 0 when it went; a directory that is not empty is not told
/// of until it has been emptied.
///
/// CONTEXT:
/// - Waits: yes, for the handler, and in the hook.
/// - Interrupts: no.
/// - Locks: no spinlock may be held; no lock on anything inside `name`
///   may be held, or that object will not go.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// What went is gone. The hook's name and message are DeleteTree's,
/// for the call.
///
/// NOTES:
/// A hook that checks for Ctrl-C (`CheckSignal`) makes a long walk
/// stoppable. With DELF_ONWARD, the names that would not go are passed
/// over by their place in a new listing: a handler that lists a
/// directory in a new order each time may have one tried again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DeleteFile`, `SetProtection`, `CreateDirs`, utility's `CallHookPkt`
///
/// EXAMPLES:
/// ```zig
/// // A directory emptied, kept.
/// if (!dl.DeleteTree("RAM:cache", dos.DELF_KEEP, null)) _ = dl.PrintFault(dl.IoErr(), "RAM:cache");
///
/// // A tree deleted, each name said, Ctrl-C to stop.
/// fn said(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
///     const dl: *DosBase = @ptrCast(@alignCast(hook.data));
///     const deleted: *const dos.DeleteMsg = @ptrCast(@alignCast(message));
///     _ = object;
///     if (deleted.failure != 0) _ = dl.PrintFault(deleted.failure, deleted.name);
///     return dl.CheckSignal(exec.SIGBREAKF_CTRL_C);
/// }
/// var hook: utility.Hook = .{ .entry = said, .data = dl };
/// _ = dl.DeleteTree("RAM:old", 0, &hook);
/// ```
pub fn DeleteTree(db: *DosBase, name: [*:0]const u8, flags: u32, hook: ?*utility.Hook) bool {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    var length: usize = 0;
    while (name[length] != 0) : (length += 1) {
        if (length >= dos.path_max) return fail(db, dos.ERROR_LINE_TOO_LONG);
    }
    const walk: *Walk = @ptrCast(@alignCast(sys.AllocVec(@sizeOf(Walk), exec.MEMF_ANY) orelse return fail(db, dos.ERROR_NO_FREE_STORE)));
    defer sys.FreeVec(walk);
    walk.* = .{ .db = db, .flags = flags, .hook = hook };
    @memcpy(walk.path[0 .. length + 1], name[0 .. length + 1]);
    walk.length = length;

    if (flags & dos.DELF_KEEP == 0) {
        switch (walk.tryOne(false)) {
            .gone => return true,
            .failed => return false,
            .stopped => return fail(db, dos.ERROR_BREAK),
            .full => {},
        }
    } else {
        const lock = dos_lib.Lock(name, dos.SHARED_LOCK) orelse return false;
        const examined = dos_lib.Examine(lock, &walk.fib);
        dos_lib.UnLock(lock);
        if (!examined) return false;
        if (!dos.isDirectory(walk.fib.dir_entry_type)) return fail(db, dos.ERROR_OBJECT_WRONG_TYPE);
    }
    var here = walk.enter(null) orelse return fail(db, dos.ERROR_NO_FREE_STORE);
    while (true) {
        if (walk.at == walk.used) {
            if (!walk.list(here)) {
                // A directory that cannot be listed will not go.
                if (!walk.tell(dos_lib.IoErr())) return walk.stop(here);
                if (flags & dos.DELF_ONWARD == 0 or here.above == null) return walk.end(here, false);
                here = walk.leave(here);
                here.skipped += 1;
                continue;
            }
            if (walk.used != 0) continue;
            // Emptied, but for what would not go: the directory itself.
            const above = here.above orelse {
                walk.free(here);
                if (flags & dos.DELF_KEEP != 0) return walk.answer();
                return switch (walk.tryOne(true)) {
                    .gone => walk.answer(),
                    .failed => false,
                    .stopped => fail(db, dos.ERROR_BREAK),
                    .full => unreachable,
                };
            };
            const outcome = walk.tryOne(true);
            here = walk.leave(here);
            switch (outcome) {
                .gone => {},
                .failed => {
                    if (flags & dos.DELF_ONWARD == 0) return walk.end(above, false);
                    above.skipped += 1;
                },
                .stopped => return walk.stop(above),
                .full => unreachable,
            }
            continue;
        }
        // The batch's next name, below the directory.
        const entry = walk.next();
        if (!walk.down(entry)) {
            if (!walk.tell(dos.ERROR_LINE_TOO_LONG)) return walk.stop(here);
            if (flags & dos.DELF_ONWARD == 0) return walk.end(here, false);
            here.skipped += 1;
            continue;
        }
        switch (walk.tryOne(false)) {
            .gone => walk.up(here.length),
            .full => here = walk.enter(here) orelse {
                walk.up(here.length);
                _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
                return walk.end(here, false);
            },
            .failed => {
                walk.up(here.length);
                if (flags & dos.DELF_ONWARD == 0) return walk.end(here, false);
                here.skipped += 1;
            },
            .stopped => return walk.stop(here),
        }
    }
}

/// So many bytes of a directory's names are read under one lock: some
/// hundred names, so that a directory of a thousand on a share is listed
/// a few times rather than once for each. The host's tests, on a RAM
/// disk of 80 KiB, take more than one batch with less.
const batch_bytes = if (@import("builtin").is_test) 2048 else 16 * 1024;

/// What became of the object at the walk's path.
const Outcome = enum { gone, full, failed, stopped };

/// The walk: the path it is at, the block Examine and ExNext fill, and
/// what it was asked.
const Walk = struct {
    db: *DosBase,
    flags: u32,
    hook: ?*utility.Hook,
    path: [dos.path_max + 1]u8 = undefined,
    length: usize = 0,
    fib: dos.FileInfoBlock = .{},
    /// Why the last object that would not go did not: IoErr at the end.
    failure: i32 = 0,
    /// The batch: names of the directory last listed, a NUL after each.
    names: [batch_bytes]u8 = undefined,
    used: usize = 0,
    at: usize = 0,

    fn name(walk: *Walk) [*:0]const u8 {
        return @ptrCast(&walk.path);
    }

    /// The object at the path deleted, its protection taken off with
    /// DELF_FORCE; `.full` for a directory that is not empty, unless
    /// `last` - when it was emptied and still holds something, which is
    /// its failure. The hook is told of all but `.full`.
    fn tryOne(walk: *Walk, last: bool) Outcome {
        const dos_lib = walk.db.iface();
        const object = walk.name();
        var failure: i32 = 0;
        if (!dos_lib.DeleteFile(object)) {
            failure = dos_lib.IoErr();
            if (failure == dos.ERROR_DELETE_PROTECTED and walk.flags & dos.DELF_FORCE != 0) {
                failure = if (dos_lib.SetProtection(object, 0) and dos_lib.DeleteFile(object)) 0 else dos_lib.IoErr();
            }
            if (failure == dos.ERROR_DIRECTORY_NOT_EMPTY and !last) return .full;
        }
        if (!walk.tell(failure)) return .stopped;
        if (failure != 0) {
            _ = dos_lib.SetIoErr(failure);
            return .failed;
        }
        return .gone;
    }

    /// The hook told that the object at the path went (`failure` 0) or why
    /// it did not: false when it stops the walk.
    fn tell(walk: *Walk, failure: i32) bool {
        if (failure != 0) walk.failure = failure;
        const hook = walk.hook orelse return true;
        var message: dos.DeleteMsg = .{ .name = walk.name(), .failure = failure };
        return walk.db.utility_base.CallHookPkt(hook, @ptrCast(&walk.path), &message) == 0;
    }

    /// `entry` added to the path, a `/` before it but after a device's
    /// colon: false when the path cannot hold it.
    fn down(walk: *Walk, entry: []const u8) bool {
        var at = walk.length;
        const joined = at != 0 and walk.path[at - 1] != ':' and walk.path[at - 1] != '/';
        if (at + @intFromBool(joined) + entry.len > dos.path_max) return false;
        if (joined) {
            walk.path[at] = '/';
            at += 1;
        }
        @memcpy(walk.path[at..][0..entry.len], entry);
        walk.length = at + entry.len;
        walk.path[walk.length] = 0;
        return true;
    }

    /// The path cut back to `length`.
    fn up(walk: *Walk, length: usize) void {
        walk.length = length;
        walk.path[length] = 0;
    }

    /// A level for the directory at the path, inside `above`; its names
    /// are listed next.
    fn enter(walk: *Walk, above: ?*Level) ?*Level {
        const memory = walk.db.sys_base.AllocVec(@sizeOf(Level), exec.MEMF_ANY) orelse return null;
        const level: *Level = @ptrCast(@alignCast(memory));
        level.* = .{ .above = above, .length = walk.length };
        walk.used = 0;
        walk.at = 0;
        return level;
    }

    /// `level` done: its memory given back, the path the directory
    /// above's, listed again next.
    fn leave(walk: *Walk, level: *Level) *Level {
        const above = level.above.?;
        walk.free(level);
        walk.up(above.length);
        walk.used = 0;
        walk.at = 0;
        return above;
    }

    fn free(walk: *Walk, level: *Level) void {
        walk.db.sys_base.FreeVec(level);
    }

    /// Every level given back from `level` up; `result` the answer, IoErr
    /// as it was set.
    fn end(walk: *Walk, level: *Level, result: bool) bool {
        var at: ?*Level = level;
        while (at) |this| {
            at = this.above;
            walk.free(this);
        }
        return result;
    }

    /// The walk stopped by the hook.
    fn stop(walk: *Walk, level: *Level) bool {
        _ = walk.db.iface().SetIoErr(dos.ERROR_BREAK);
        return walk.end(level, false);
    }

    /// The whole walk's answer: false, with IoErr the last failure's,
    /// when something was passed over.
    fn answer(walk: *Walk) bool {
        if (walk.failure == 0) return true;
        _ = walk.db.iface().SetIoErr(walk.failure);
        return false;
    }

    /// A batch of the names of the directory at the path, `level`'s, past
    /// those that would not go: false with IoErr when it cannot be listed.
    /// No batch (`used` 0) when nothing else is in it.
    fn list(walk: *Walk, level: *const Level) bool {
        const dos_lib = walk.db.iface();
        walk.used = 0;
        walk.at = 0;
        const lock = dos_lib.Lock(walk.name(), dos.SHARED_LOCK) orelse return false;
        defer dos_lib.UnLock(lock);
        if (!dos_lib.Examine(lock, &walk.fib)) return false;
        var passed: usize = 0;
        while (dos_lib.ExNext(lock, &walk.fib)) {
            if (passed < level.skipped) {
                passed += 1;
                continue;
            }
            var length: usize = 0;
            while (length < walk.fib.file_name.len and walk.fib.file_name[length] != 0) length += 1;
            // The rest comes with the next batch.
            if (walk.used + length + 1 > walk.names.len) return true;
            @memcpy(walk.names[walk.used..][0..length], walk.fib.file_name[0..length]);
            walk.names[walk.used + length] = 0;
            walk.used += length + 1;
        }
        return dos_lib.IoErr() == dos.ERROR_NO_MORE_ENTRIES;
    }

    /// The batch's next name.
    fn next(walk: *Walk) []const u8 {
        const start = walk.at;
        while (walk.names[walk.at] != 0) walk.at += 1;
        const entry = walk.names[start..walk.at];
        walk.at += 1;
        return entry;
    }
};

/// A directory the walk is inside: where the path ends at it, and how
/// many of its names would not go.
const Level = struct {
    above: ?*Level,
    length: usize,
    /// Names that would not go: they come first in each listing, and are
    /// passed over.
    skipped: usize = 0,
};
