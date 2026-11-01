// SPDX-License-Identifier: MIT
//! The drives a device feeds, held still. A reset writes nothing out, so
//! whatever a file system is still holding is lost unless every such
//! drive is stopped first: Inhibit does that, and a handler writes out
//! what it has and closes the medium before it answers.
//!
//! A drive here is a device node whose handler was started on a device -
//! its `FileSysStartupMsg` names one - which is a file system on a disk,
//! a card or a stick. `RAM:`, `PIPE:` and a handler that speaks to a
//! server over the network have no device under them and hold nothing a
//! reset could lose.
//!
//! The names are taken while dos's list is locked and the drives held
//! once it is let go: Inhibit talks to a handler, which may want the list
//! itself.
//!
//! A drive that will not stop is the caller's to say something about. It
//! means a program still has something open on it, and what to do then -
//! go ahead, or ask - is the caller's business.

const dos = @import("dos.zig");
const DosBase = @import("../../interface/dos.zig").DosBase;

/// The most drives one list holds. A machine with more than this many
/// mounted keeps the rest running, which costs what they were holding.
pub const max_drives = 64;

/// A drive's name with its colon, as dos is given it.
pub const Name = [dos.MAX_DEVICE_NAME + 2:0]u8;

/// The drives found, each a name with its colon.
pub const List = struct {
    names: [max_drives]Name = @splat(@splat(0)),
    count: usize = 0,

    /// Every drive a device feeds, taken while the list is locked.
    pub fn gather(list: *List, dl: *DosBase) void {
        list.count = 0;
        const flags = dos.LDF_DEVICES | dos.LDF_READ;
        const first = dl.LockDosList(flags) orelse return;
        defer dl.UnLockDosList(flags);
        var entry = dl.NextDosEntry(first, dos.LDF_DEVICES);
        while (entry) |node| : (entry = dl.NextDosEntry(node, dos.LDF_DEVICES)) {
            if (list.count == max_drives) break;
            if (node.task == null) continue;
            const startup = dos.filehandler.startupOf(node.misc.handler.startup) orelse continue;
            if (startup.device == null) continue;
            const into = &list.names[list.count];
            into.* = @splat(0);
            var at: usize = 0;
            while (node.name[at] != 0 and at < dos.MAX_DEVICE_NAME) : (at += 1) into[at] = node.name[at];
            into[at] = ':';
            list.count += 1;
        }
    }

    /// The names found.
    pub fn all(list: *const List) []const Name {
        return list.names[0..list.count];
    }
};

/// A name as dos takes it.
pub fn path(name: *const Name) [*:0]const u8 {
    return @ptrCast(name);
}

/// One drive held still: false where it would not stop, and what it
/// holds may then not be written out.
pub fn hold(dl: *DosBase, name: *const Name) bool {
    return dl.Inhibit(path(name), true);
}

/// One drive let go again, for a restart that is not going ahead after
/// all.
pub fn release(dl: *DosBase, name: *const Name) void {
    _ = dl.Inhibit(path(name), false);
}

/// Every drive in the list held still, the ones that would not stop
/// named to `refused` in the order they were tried: how many refused.
pub fn holdAll(dl: *DosBase, list: *const List, refused: ?*List) usize {
    if (refused) |into| into.count = 0;
    var count: usize = 0;
    for (list.all()) |*name| {
        if (hold(dl, name)) continue;
        count += 1;
        if (refused) |into| {
            if (into.count == max_drives) continue;
            into.names[into.count] = name.*;
            into.count += 1;
        }
    }
    return count;
}

/// Every drive in the list let go again.
pub fn releaseAll(dl: *DosBase, list: *const List) void {
    for (list.all()) |*name| release(dl, name);
}
