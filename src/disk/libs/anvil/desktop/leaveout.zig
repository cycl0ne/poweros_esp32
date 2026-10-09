// SPDX-License-Identifier: MIT
//! Files left out on the desktop: Leave Out puts a file's icon on the
//! desktop's ground, beside the disks, and Put Away takes it back into
//! its drawer.
//!
//! **Where it is kept**: `.backdrop` in the root of the file's volume, a
//! line for each file left out, its path from the root after a colon
//! (`:Work/Notes`). So it is the volume's to remember: a card left out
//! from shows its files again when it comes back, on any machine. The
//! desktop reads a volume's `.backdrop` when the volume's icon comes, and
//! the files go from the desktop when the volume does.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icons = @import("../icons/_icons.zig");
const Icon = icons.Icon;
const Desktop = @import("_desktop.zig").Desktop;
const volumes = @import("volumes.zig");

/// The most bytes of a `.backdrop` read or written.
const file_max = 4096;

fn textOf(text: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return text[0..n];
}

fn sameName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const left = if (x >= 'a' and x <= 'z') x - 32 else x;
        const right = if (y >= 'a' and y <= 'z') y - 32 else y;
        if (left != right) return false;
    }
    return true;
}

/// The volume part of a full name, and the rest after its colon.
pub fn split(path: []const u8) ?struct { volume: []const u8, rest: []const u8 } {
    for (path, 0..) |c, i| if (c == ':') return .{ .volume = path[0..i], .rest = path[i + 1 ..] };
    return null;
}

/// The `.backdrop` of a volume's lines, each a path from its root, handed
/// to `each`; `text` is the file's contents.
pub fn lines(text: []const u8, context: anytype, comptime each: fn (@TypeOf(context), []const u8) void) void {
    var rest = text;
    while (rest.len > 0) {
        var end: usize = 0;
        while (end < rest.len and rest[end] != '\n') end += 1;
        var line = rest[0..end];
        rest = if (end < rest.len) rest[end + 1 ..] else rest[rest.len..];
        while (line.len > 0 and (line[line.len - 1] == '\r' or line[line.len - 1] == ' ')) line = line[0 .. line.len - 1];
        if (line.len < 2 or line[0] != ':') continue;
        each(context, line[1..]);
    }
}

fn backdropName(into: []u8, volume: []const u8) ?[*:0]const u8 {
    const suffix = ":.backdrop";
    if (volume.len + suffix.len + 1 > into.len) return null;
    @memcpy(into[0..volume.len], volume);
    @memcpy(into[volume.len..][0..suffix.len], suffix);
    into[volume.len + suffix.len] = 0;
    return @ptrCast(into.ptr);
}

/// The files a volume's `.backdrop` names put on the desktop.
pub fn readVolume(d: *Desktop, volume: []const u8) void {
    var name: [dos.name_max + 16]u8 = undefined;
    const file = backdropName(&name, volume) orelse return;
    var text: [file_max]u8 = undefined;
    const read = sdk.prefs.load(d.dl, file, &text) orelse return;
    const Show = struct {
        d: *Desktop,
        volume: []const u8,
        fn each(show: @This(), rest: []const u8) void {
            var full: [dos.path_max + 1]u8 = undefined;
            if (show.volume.len + 1 + rest.len > dos.path_max) return;
            @memcpy(full[0..show.volume.len], show.volume);
            full[show.volume.len] = ':';
            @memcpy(full[show.volume.len + 1 ..][0..rest.len], rest);
            put(show.d, full[0 .. show.volume.len + 1 + rest.len]);
        }
    };
    lines(read, Show{ .d = d, .volume = volume }, Show.each);
}

/// A file's icon put on the desktop, standing for `path`.
fn put(d: *Desktop, path: []const u8) void {
    // Not twice.
    var it = d.volumes.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (ic.path) |held| if (sameName(textOf(held), path)) return;
    }
    const memory = d.sys.AllocVec(@intCast(path.len + 1), exec.MEMF_ANY) orelse return;
    const held: [*]u8 = @ptrCast(memory);
    @memcpy(held[0..path.len], path);
    held[path.len] = 0;
    const full: [*:0]u8 = @ptrCast(held);
    const object = d.icon_base.GetDiskObjectNew(full) orelse {
        d.sys.FreeVec(memory);
        return;
    };
    const label = textOf(d.dl.FilePart(full));
    const ic = icons.make(d.sys, &d.pictures, object, label, &d.look) orelse {
        d.icon_base.FreeDiskObject(object);
        d.sys.FreeVec(memory);
        return;
    };
    ic.path = full;
    ic.measure(d.gb, d.backdrop_rp, &d.look);
    volumes.place(d, ic);
    d.sys.AddTail(&d.volumes, &ic.node);
    d.holdRoot();
    ic.draw(d.gb, d.backdrop_rp, &d.look, .{});
    d.releaseRoot();
}

/// The files of a volume that went taken off the desktop - they stay in
/// its `.backdrop` for when it comes back.
pub fn forgetVolume(d: *Desktop, volume: []const u8) void {
    var it = d.volumes.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        const held = ic.path orelse continue;
        const parts = split(textOf(held)) orelse continue;
        // Removing the icon the walk stands on leaves the walk good.
        if (sameName(parts.volume, volume)) volumes.remove(d, ic);
    }
}

/// `path` added to its volume's `.backdrop`, or taken out of it.
fn rewrite(d: *Desktop, path: []const u8, add: bool) bool {
    const parts = split(path) orelse return false;
    var name: [dos.name_max + 16]u8 = undefined;
    const file = backdropName(&name, parts.volume) orelse return false;
    var text: [file_max]u8 = undefined;
    var out: [file_max]u8 = undefined;
    const read = sdk.prefs.load(d.dl, file, &text) orelse text[0..0];
    const Keep = struct {
        out: []u8,
        n: *usize,
        drop: []const u8,
        fn each(keep: @This(), rest: []const u8) void {
            if (sameName(rest, keep.drop)) return;
            if (keep.n.* + rest.len + 2 > keep.out.len) return;
            keep.out[keep.n.*] = ':';
            @memcpy(keep.out[keep.n.* + 1 ..][0..rest.len], rest);
            keep.out[keep.n.* + 1 + rest.len] = '\n';
            keep.n.* += rest.len + 2;
        }
    };
    var n: usize = 0;
    lines(read, Keep{ .out = &out, .n = &n, .drop = parts.rest }, Keep.each);
    if (add) {
        if (n + parts.rest.len + 2 > out.len) return false;
        out[n] = ':';
        @memcpy(out[n + 1 ..][0..parts.rest.len], parts.rest);
        out[n + 1 + parts.rest.len] = '\n';
        n += parts.rest.len + 2;
    }
    if (n == 0) return d.dl.DeleteFile(file) or true;
    return sdk.prefs.save(d.dl, file, out[0..n]);
}

/// Leave Out: `path`'s icon put on the desktop and kept there.
pub fn leaveOut(d: *Desktop, path: []const u8) void {
    if (!rewrite(d, path, true)) {
        d.say("The disk will not keep what is left out");
        return;
    }
    put(d, path);
}

/// Put Away: a left-out icon taken off the desktop and out of its
/// volume's `.backdrop`.
pub fn putAway(d: *Desktop, ic: *Icon) void {
    const held = ic.path orelse return;
    _ = rewrite(d, textOf(held), false);
    volumes.remove(d, ic);
}
