// SPDX-License-Identifier: MPL-2.0
//! StartNotify: a file or a directory watched, its changes told to the
//! program.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("../lock/_lock.zig");
const packets = @import("../packet/_packet.zig");
const NotifyRequest = dos.notify.NotifyRequest;

/// Starts watching a file or a directory: the program is told whenever
/// it changes.
///
/// SYNOPSIS:
/// ```zig
/// fn StartNotify(db: *DosBase, request: *NotifyRequest) bool
/// ```
///
/// SINCE: 1.3. LVO -556.
///
/// INPUTS:
/// - `request` - filled in by the program: `name`, the object; `flags`,
///   `NRF_SEND_MESSAGE` with `port`, or `NRF_SEND_SIGNAL` with `task` and
///   `signal_number`, and `NRF_WAIT_REPLY`, `NRF_NOTIFY_INITIAL` as it
///   wants; `user_data` as it likes.
///
/// RESULT:
/// True when the object's handler has the request; false with IoErr() -
/// ERROR_ACTION_NOT_KNOWN from a handler that cannot watch,
/// ERROR_DEVICE_NOT_MOUNTED, ERROR_NO_FREE_STORE.
///
/// BEHAVIOR:
/// The name need not be there yet: it is watched until it appears. dos
/// writes the handler's own path into `full_name` - an assign's
/// directory written out, a relative name made whole from the current
/// directory - and sends the request to the handler, which keeps it:
///
/// - a file is changed when a handle that wrote to it is closed (not at
///   each write), when it is created, deleted or renamed away or onto,
///   and when its protection, comment, date or owner change;
/// - a directory is changed when an entry in it is created, deleted,
///   renamed, or closed after writing.
///
/// A change is told as the request asks: a NotifyMessage on `port` -
/// `class` NOTIFY_CLASS, `code` NOTIFY_CODE, `request` the request - which
/// the program replies; and a signal to `task`. With `NRF_WAIT_REPLY` no
/// message follows while one is out, and a change meanwhile is told once
/// it is replied. With `NRF_NOTIFY_INITIAL` an object already there is
/// told of once at the start.
///
/// RAM:, the flash file system and fat-handler watch; other handlers may
/// not. Of a multi-directory assign, the first directory is watched.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// `request` stays the program's, and where it is, until EndNotify;
/// `name` too. `full_name` is dos's until then. A NotifyMessage is the
/// handler's: the program replies it, and keeps nothing of it.
///
/// NOTES:
/// A watch follows the object it found: renamed away or deleted, the
/// object is let go, and the name is watched again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `EndNotify`, `sdk.dos.notify`
///
/// EXAMPLES:
/// ```zig
/// var request: dos.notify.NotifyRequest = .{ .name = "ENVARC:Sys/net/hostname", .flags = dos.notify.NRF_SEND_MESSAGE, .port = port };
/// if (!dos_lib.StartNotify(&request)) return;
/// defer dos_lib.EndNotify(&request);
/// // ... a NotifyMessage on `port`: read the file again, then ReplyMsg it.
/// ```
pub fn StartNotify(db: *DosBase, request: *NotifyRequest) bool {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const name = request.name orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_REQUIRED_ARG_MISSING);
        return false;
    };
    const dp = dos_lib.GetDeviceProc(name, null) orelse return false;
    defer dos_lib.FreeDeviceProc(dp);
    const port = dp.port orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_DEVICE_NOT_MOUNTED);
        return false;
    };
    const full = fullName(db, name, dp.lock) orelse return false;
    request.full_name = full;
    request.handler = port;
    request.msg_count = 0;
    const answer = packets.exchange(sys, port, @intFromEnum(dos.ActionCode.add_notify), .{ _lock.asArg(request), 0, 0, 0, 0 }) orelse {
        dropName(db, request);
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return false;
    };
    if (answer.res1 == 0) {
        dropName(db, request);
        _ = dos_lib.SetIoErr(answer.res2);
        return false;
    }
    return true;
}

/// The handler's own path to `name`: the directory `lock` stands for
/// written out, then the name past its device part; the name as it is
/// without a lock. In memory of its own, which EndNotify frees.
fn fullName(db: *DosBase, name: [*:0]const u8, lock: ?*dos.FileLock) ?[*:0]u8 {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    const ub = db.utility_base;
    var base: [dos.path_max + 1]u8 = undefined;
    var base_length: usize = 0;
    var rest: [*:0]const u8 = name;
    if (lock != null) {
        if (!dos_lib.NameFromLock(lock, &base, base.len)) return null;
        base_length = ub.Strlen(@ptrCast(&base));
        // Past the device or the assign's name.
        var at: usize = 0;
        while (name[at] != 0) : (at += 1) {
            if (name[at] == ':') rest = name + at + 1;
        }
    }
    const rest_length = ub.Strlen(rest);
    const joiner: usize = if (base_length > 0 and base[base_length - 1] != ':' and rest_length > 0) 1 else 0;
    const total = base_length + joiner + rest_length;
    if (total > dos.path_max) {
        _ = dos_lib.SetIoErr(dos.ERROR_LINE_TOO_LONG);
        return null;
    }
    const memory = sys.AllocVec(total + 1, exec.MEMF_ANY) orelse {
        _ = dos_lib.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    const into: [*]u8 = @ptrCast(memory);
    @memcpy(into[0..base_length], base[0..base_length]);
    if (joiner != 0) into[base_length] = '/';
    @memcpy(into[base_length + joiner ..][0..rest_length], rest[0..rest_length]);
    into[total] = 0;
    return @ptrCast(into);
}

/// The request's full name freed: it is dos's to make and to free.
pub fn dropName(db: *DosBase, request: *NotifyRequest) void {
    if (request.full_name) |full| db.sys_base.FreeVec(full);
    request.full_name = null;
}
