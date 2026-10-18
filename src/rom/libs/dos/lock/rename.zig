// SPDX-License-Identifier: MPL-2.0
//! Rename: renames or moves an object within its volume.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _lock = @import("_lock.zig");
const packets = @import("../packet/_packet.zig");
const asArg = _lock.asArg;
const fail = _lock.fail;
const Links = _lock.Links;
const Place = _lock.Place;
/// The longest path a handler is sent: a whole path, not one name of it.
const max_path = dos.path_max;

/// Renames or moves an object on its volume.
///
/// SYNOPSIS:
/// ```zig
/// fn Rename(db: *DosBase, from: [*:0]const u8, to: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -348.
///
/// INPUTS:
/// - `from` - the object's name, as for Lock.
/// - `to` - its new name, which may be in another directory of the same
///   volume ("RAM:a" to "RAM:d/b").
///
/// RESULT:
/// True when the object was renamed. False otherwise, with IoErr set:
/// ERROR_LINE_TOO_LONG for a name over 255 characters,
/// ERROR_RENAME_ACROSS_DEVICES when the two names are on different
/// handlers, ERROR_TOO_MANY_LEVELS when a path leads through more than 16
/// soft links, ERROR_DEVICE_NOT_MOUNTED for a node with no handler,
/// ERROR_NO_FREE_STORE when the packet could not be sent, and whatever the
/// handler answers - ERROR_OBJECT_EXISTS when `to` is already there,
/// ERROR_OBJECT_NOT_FOUND when `from` isn't.
///
/// BEHAVIOR:
/// Both names are resolved with GetDeviceProc. `to` is taken in the first
/// directory of its path, where a new object would be made. `from` is
/// looked for along its multi-assign: while the handler answers
/// ERROR_OBJECT_NOT_FOUND and the name is an assign, the next directory is
/// tried. ACTION_RENAME_OBJECT is sent as (source directory, `from`, target
/// directory, `to`); the handler strips the device part of each name.
///
/// A soft link on the way of either name is followed: on
/// ERROR_IS_SOFT_LINK the source's path is given to ReadLink first, and
/// when it has no link the target's, and the packet goes again with the
/// path that came back (see `Lock`). A link at the end of `from` is what is
/// renamed: the link itself.
///
/// CONTEXT:
/// - Waits: yes, for the handler's answer.
/// - Interrupts: not callable.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; only a process gets IoErr.
///
/// OWNERSHIP:
/// Nothing is kept. The strings stay the caller's; the handler copies what
/// it needs.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Lock`, `DeleteFile`, `GetDeviceProc`
///
/// EXAMPLES:
/// ```zig
/// if (!dos_lib.Rename("RAM:draft", "RAM:done/final")) {
///     _ = dos_lib.PrintFault(dos_lib.IoErr(), "Rename");
/// }
/// ```
pub fn Rename(db: *DosBase, from: [*:0]const u8, to: [*:0]const u8) bool {
    const dos_lib = db.iface();
    if (db.utility_base.Strlen(from) > max_path or db.utility_base.Strlen(to) > max_path) return fail(db, dos.ERROR_LINE_TOO_LONG);
    var from_links: Links = .{ .db = db };
    defer from_links.free();
    var to_links: Links = .{ .db = db };
    defer to_links.free();
    var target: Place = .{ .path = to, .dp = dos_lib.GetDeviceProc(to, null) orelse return false };
    var source: Place = .{ .path = from, .dp = dos_lib.GetDeviceProc(from, null) orelse {
        dos_lib.FreeDeviceProc(target.dp);
        return false;
    } };
    const done = renameFrom(db, &source, &target, &from_links, &to_links);
    dos_lib.FreeDeviceProc(source.dp);
    dos_lib.FreeDeviceProc(target.dp);
    return done;
}

/// The packet sent until it is answered for good: along the source's
/// assign, and through the links of both paths. Each place's DevProc is
/// the caller's to free.
fn renameFrom(db: *DosBase, source: *Place, target: *Place, from_links: *Links, to_links: *Links) bool {
    const dos_lib = db.iface();
    while (true) {
        if (source.dp.port != target.dp.port) return fail(db, dos.ERROR_RENAME_ACROSS_DEVICES);
        const port = source.dp.port orelse return fail(db, dos.ERROR_DEVICE_NOT_MOUNTED);
        const answer = packets.exchange(db.sys_base, port, @intFromEnum(dos.ActionCode.rename_object), .{
            asArg(source.dir()), asArg(source.path), asArg(target.dir()), asArg(target.path), 0,
        }) orelse return fail(db, dos.ERROR_NO_FREE_STORE);
        if (answer.res1 != 0) return true;
        if (answer.res2 == dos.ERROR_IS_SOFT_LINK) {
            if (from_links.follow(port, source.dir(), source.path)) |path| {
                if (!source.moveTo(db, path)) return false;
                continue;
            }
            if (dos_lib.IoErr() == dos.ERROR_TOO_MANY_LEVELS) return false;
            const path = to_links.follow(port, target.dir(), target.path) orelse return false;
            if (!target.moveTo(db, path)) return false;
            continue;
        }
        if (answer.res2 != dos.ERROR_OBJECT_NOT_FOUND or !source.own or source.dp.flags & dos.DVPF_ASSIGN == 0) return fail(db, answer.res2);
        // The source's next directory.
        const next = dos_lib.GetDeviceProc(source.path, source.dp) orelse return fail(db, dos.ERROR_OBJECT_NOT_FOUND);
        if (next != source.dp) dos_lib.FreeDeviceProc(source.dp);
        source.dp = next;
    }
}
