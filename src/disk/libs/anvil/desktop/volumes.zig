// SPDX-License-Identifier: MIT
//! The disks on the desktop: an icon for each mounted volume, coming and
//! going with the volumes.
//!
//! The dos list is read under its lock and only copied - the names and
//! the nodes - and the icons are made after it is let go, since reading
//! an icon asks the volume's handler, which may itself want the list. A
//! volume is known again by its node and its name together: a node
//! freed and made again for another disk has that disk's name, and a
//! volume renamed (Relabel) keeps its node and gets a new icon with its
//! new name.
//!
//! A volume's icon lies where its `Disk.info` says, unless it says
//! nothing or the desktop was started to clean up; then it goes in the
//! first free cell down the desktop's right edge.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const graphics = sdk.graphics;
const Rect = graphics.Rect;
const icons = @import("../icons/_icons.zig");
const Icon = icons.Icon;
const Desktop = @import("_desktop.zig").Desktop;
const leaveout = @import("leaveout.zig");

/// The most volumes shown.
pub const max_volumes = 32;

/// A mounted volume, as the list said.
pub const Seen = struct {
    node: *dos.DosList,
    name: [icons.label_max + 1]u8,
    len: u16,

    fn name_(seen: *const Seen) []const u8 {
        return seen.name[0..seen.len];
    }
};

/// The room the desktop keeps clear round its edges.
const margin = 8;

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

/// The dos list read and the icons brought in line with it.
pub fn scan(d: *Desktop) void {
    const count = read(d);
    // A volume gone takes its left-out files with it, which may be any
    // icons of the list: the walk starts again after each.
    gone: while (true) {
        var it = d.volumes.iterator();
        while (it.next()) |node| {
            const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
            if (ic.path != null or ic.app != null) continue;
            const still = for (d.seen[0..count]) |*seen| {
                if (ic.key == @as(*anyopaque, @ptrCast(seen.node)) and same(ic.name(), seen.name_())) break true;
            } else false;
            if (still) continue;
            var name: [icons.label_max]u8 = undefined;
            const length = ic.label_len;
            @memcpy(name[0..length], ic.name());
            remove(d, ic);
            leaveout.forgetVolume(d, name[0..length]);
            continue :gone;
        }
        break;
    }
    for (d.seen[0..count]) |*seen| {
        var shown = d.volumes.iterator();
        const has = while (shown.next()) |node| {
            const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
            if (ic.key == @as(*anyopaque, @ptrCast(seen.node)) and same(ic.name(), seen.name_())) break true;
        } else false;
        if (!has) add(d, seen);
    }
}

/// The mounted volumes copied into `d.seen`; how many.
fn read(d: *Desktop) usize {
    const flags = dos.LDF_VOLUMES | dos.LDF_READ;
    const first = d.dl.LockDosList(flags) orelse return 0;
    defer d.dl.UnLockDosList(flags);
    var count: usize = 0;
    var node = first;
    while (d.dl.NextDosEntry(node, dos.LDF_VOLUMES)) |entry| : (node = entry) {
        // A volume whose disk has gone stays on the list while locks point
        // at it, with no handler behind it: not shown.
        if (entry.task == null) continue;
        if (count == max_volumes) break;
        const seen = &d.seen[count];
        var length: usize = 0;
        while (entry.name[length] != 0 and length < icons.label_max) : (length += 1) seen.name[length] = entry.name[length];
        seen.len = @intCast(length);
        seen.node = entry;
        count += 1;
    }
    return count;
}

/// An icon for a volume: its `Disk.info`, or the default disk icon,
/// placed and drawn.
fn add(d: *Desktop, seen: *const Seen) void {
    var path: [icons.label_max + 2:0]u8 = @splat(0);
    @memcpy(path[0..seen.len], seen.name_());
    path[seen.len] = ':';
    const object = d.icon_base.GetDiskObjectNew(&path) orelse return;
    const ic = icons.make(d.sys, &d.pictures, object, seen.name_(), &d.look) orelse {
        d.icon_base.FreeDiskObject(object);
        return;
    };
    ic.key = seen.node;
    ic.measure(d.gb, d.backdrop_rp, &d.look);
    if (!d.clean_up and object.current_x != icon.NO_ICON_POSITION and object.current_y != icon.NO_ICON_POSITION) {
        ic.x = object.current_x;
        ic.y = object.current_y;
        ic.placed_by_file = true;
    } else {
        place(d, ic);
    }
    d.sys.AddTail(&d.volumes, &ic.node);
    d.holdRoot();
    ic.draw(d.gb, d.backdrop_rp, &d.look, .{});
    d.releaseRoot();
    leaveout.readVolume(d, seen.name_());
}

/// An icon put in the first cell down the right edge that no other icon
/// overlaps.
pub fn place(d: *Desktop, ic: *Icon) void {
    var taken: [max_volumes]Rect = undefined;
    var count: usize = 0;
    var it = d.volumes.iterator();
    while (it.next()) |node| {
        const other: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (count == taken.len) break;
        taken[count] = other.box(&d.look);
        count += 1;
    }
    const area = Rect{ .min_x = margin, .min_y = margin, .max_x = d.width - margin, .max_y = d.height - margin };
    const at = icons.place.firstFree(area, d.look.cell, taken[0..count], .columns_from_right);
    ic.putInCell(&d.look, at.x, at.y);
}

/// An icon taken off the desktop: the ground painted where it was, and
/// what else lay there drawn again.
pub fn remove(d: *Desktop, ic: *Icon) void {
    d.sys.Remove(&ic.node);
    // A picked icon's plate reaches a little past its box.
    const b = ic.box(&d.look);
    const was = Rect{ .min_x = b.min_x - 4, .min_y = b.min_y - 4, .max_x = b.max_x + 4, .max_y = b.max_y + 4 };
    icons.free(d.sys, d.icon_base, &d.pictures, ic);
    d.drawArea(was);
}

/// Every volume's icon let go of, nothing drawn: before the desktop
/// makes them anew, or as it ends.
pub fn forgetAll(d: *Desktop) void {
    while (d.volumes.first()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        d.sys.Remove(&ic.node);
        icons.free(d.sys, d.icon_base, &d.pictures, ic);
    }
}
