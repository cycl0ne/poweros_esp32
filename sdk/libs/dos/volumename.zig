// SPDX-License-Identifier: MIT
//! A handler's side of ACTION_RENAME_DISK: the volume node given its new
//! name in place.
//!
//! Locks point at the volume node, so it is not made again: its `name` is
//! pointed at a copy the handler keeps here instead, the node's own having
//! been made at the length of the old name. That is a change to the device
//! list, made only when the list can be had at once - a handler must never
//! wait for the list while it serves a packet, since a program may hold it
//! while it asks this very handler (Info does) - so it is noted here and
//! put on the node after the packet is answered, as often as it takes.

const dos = @import("dos.zig");
const DosBase = @import("../../interface/dos.zig").DosBase;

/// Whether a name may be a volume's: one to MAX_DEVICE_NAME characters,
/// none of them `:`, `/` or a control character.
pub fn valid(name: []const u8) bool {
    if (name.len == 0 or name.len > dos.MAX_DEVICE_NAME) return false;
    for (name) |char| {
        if (char == ':' or char == '/' or char < 0x20 or char == 0x7F) return false;
    }
    return true;
}

/// The name a handler's volume node shows after a rename, and whether it
/// is still to be put on the node.
pub const VolumeName = extern struct {
    text: [dos.MAX_DEVICE_NAME + 1:0]u8 = @splat(0),
    pending: u8 = 0,

    /// The new name, to be put on the node at the next `apply`.
    pub fn set(volume_name: *VolumeName, name: []const u8) void {
        const len = @min(name.len, dos.MAX_DEVICE_NAME);
        @memset(&volume_name.text, 0);
        @memcpy(volume_name.text[0..len], name[0..len]);
        volume_name.pending = 1;
    }

    /// The name put on `node` if the device list can be had at once; left
    /// pending if not. Call after each packet is answered.
    pub fn apply(volume_name: *VolumeName, dl: *DosBase, node: ?*dos.DosList) void {
        if (volume_name.pending == 0) return;
        const flags = dos.LDF_VOLUMES | dos.LDF_WRITE;
        _ = dl.AttemptLockDosList(flags) orelse return;
        defer dl.UnLockDosList(flags);
        if (node) |volume| volume.name = &volume_name.text;
        volume_name.pending = 0;
    }
};
