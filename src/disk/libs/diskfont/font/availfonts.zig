// SPDX-License-Identifier: MIT
//! AvailFonts: every font in memory and in FONTS:, described.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const diskfont = sdk.diskfont;
const fontfile = diskfont.fontfile;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const _font = @import("_font.zig");

/// Every font in memory and in FONTS:, described.
///
/// SYNOPSIS:
/// ```zig
/// fn AvailFonts(dfb: *DiskfontBase, buffer: *anyopaque, buffer_size: u32, flags: u32) u32
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `buffer` - where the answer goes, four-byte aligned.
/// - `buffer_size` - how many bytes it has.
/// - `flags` - where to look: `AFF_MEMORY` for the fonts on graphics'
///   list, `AFF_DISK` for every size every contents file in `FONTS:`
///   lists, `AFF_SCALED` to count memory fonts made by scaling as well.
///
/// RESULT:
/// 0 when everything fitted: the buffer holds an `AvailFontsHeader`, its
/// `count` `AvailFonts` entries (`diskfont.availEntries`), and the names
/// they point at. Otherwise
/// how many bytes more it needed; the buffer is then not filled, and a
/// caller tries again with that much more.
///
/// BEHAVIOR:
/// Each entry is the `TextAttr` that opens the font - with `OpenFont` for
/// one in memory, `OpenDiskFont` for one on a disk - and where it was:
/// `AFF_MEMORY`, `AFF_MEMORY | AFF_SCALED`, `AFF_DISK`, or
/// `AFF_DISK | AFF_SCALABLE` with a height of 0 for an outline, which
/// comes at any height. A font loaded
/// from a disk is listed under both, once for each place. A disk entry
/// says what its contents file says; whether the size file itself is
/// sound is only known when it is opened. Every directory of a `FONTS:`
/// assign of several is looked in.
///
/// CONTEXT:
/// - Waits: yes: for the disk, and for graphics' font list.
/// - Interrupts: no.
/// - Forbid: must not be held.
/// - Process: a Process, since it reads files.
///
/// OWNERSHIP:
/// The buffer is the caller's; the names in it point into it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenDiskFont`, `graphics.library/NextFont`
///
/// EXAMPLES:
/// ```zig
/// var size: u32 = 1024;
/// while (true) {
///     const buffer = sys.AllocVec(size, exec.MEMF_ANY) orelse return;
///     const more = dfb.AvailFonts(buffer, size, diskfont.AFF_MEMORY | diskfont.AFF_DISK);
///     if (more == 0) break use(buffer);
///     sys.FreeVec(buffer);
///     size += more;
/// }
/// ```
pub fn AvailFonts(dfb: *DiskfontBase, buffer: *anyopaque, buffer_size: u32, flags: u32) u32 {
    // Counted first, then written: the names go after the entries, and
    // where the entries end is only known once they are counted.
    var count = Collector{};
    visit(dfb, flags, &count);
    const needed = count.bytesFor();
    if (needed > buffer_size) return needed - buffer_size;

    const bytes: [*]u8 = @ptrCast(buffer);
    var fill = Collector{
        .entries = @ptrCast(@alignCast(bytes + diskfont.avail_entries_at)),
        .names = bytes + diskfont.avail_entries_at + count.count * @sizeOf(diskfont.AvailFonts),
        .limit = .{ .count = count.count, .name_bytes = count.name_bytes },
    };
    visit(dfb, flags, &fill);
    const header: *diskfont.AvailFontsHeader = @ptrCast(@alignCast(buffer));
    header.* = .{ .count = fill.count };
    return 0;
}

/// What a walk found: counted, and written out when there is somewhere
/// to write. A second walk that finds more than the first - a font added
/// between them - writes no more than the first counted.
const Collector = struct {
    entries: ?[*]diskfont.AvailFonts = null,
    names: ?[*]u8 = null,
    count: u32 = 0,
    name_bytes: u32 = 0,
    limit: ?Limit = null,

    const Limit = struct { count: u32, name_bytes: u32 };

    fn bytesFor(c: *const Collector) u32 {
        return @intCast(diskfont.avail_entries_at + c.count * @sizeOf(diskfont.AvailFonts) + c.name_bytes);
    }

    fn add(c: *Collector, kind: u32, name: [*:0]const u8, y_size: u16, style: graphics.FontStyle, flags: graphics.FontFlags) void {
        var len: u32 = 0;
        while (name[len] != 0) len += 1;
        if (c.limit) |limit| {
            if (c.count == limit.count or c.name_bytes + len + 1 > limit.name_bytes) return;
        }
        if (c.entries) |entries| {
            const at = c.names.? + c.name_bytes;
            for (0..len) |i| at[i] = name[i];
            at[len] = 0;
            entries[c.count] = .{
                .type = kind,
                .attr = .{ .name = @ptrCast(at), .y_size = y_size, .style = style, .flags = flags },
            };
        }
        c.count += 1;
        c.name_bytes += len + 1;
    }
};

fn visit(dfb: *DiskfontBase, flags: u32, into: *Collector) void {
    if (flags & diskfont.AFF_MEMORY != 0) visitMemory(dfb, flags, into);
    if (flags & diskfont.AFF_DISK != 0) visitDisk(dfb, into);
}

/// The fonts on graphics' list, read while it holds still.
fn visitMemory(dfb: *DiskfontBase, flags: u32, into: *Collector) void {
    const gb = dfb.graphics_base;
    gb.LockFonts();
    defer gb.UnlockFonts();
    var at = gb.NextFont(null);
    while (at) |font| : (at = gb.NextFont(font)) {
        const attr = _font.attrOf(font);
        const drawn = graphics.FPF_DESIGNED | graphics.FPF_ROMFONT | graphics.FPF_DISKFONT;
        const scaled = attr.flags & drawn == 0;
        if (scaled and flags & diskfont.AFF_SCALED == 0) continue;
        const kind = diskfont.AFF_MEMORY | if (scaled) diskfont.AFF_SCALED else 0;
        into.add(kind, attr.name, attr.y_size, attr.style, attr.flags);
    }
}

/// Every contents file in every directory of FONTS:.
fn visitDisk(dfb: *DiskfontBase, into: *Collector) void {
    const dl = dfb.dos_base;
    // An assign of several directories is walked in the one DevProc,
    // which moves on to the next each time and is still to be freed when
    // there is no next.
    const place = dl.GetDeviceProc(diskfont.FONTSNAME, null) orelse return;
    defer dl.FreeDeviceProc(place);
    while (true) {
        const dir = if (place.lock) |lock| dl.DupLock(lock) else dl.Lock(diskfont.FONTSNAME, dos.SHARED_LOCK);
        if (dir) |lock| {
            visitDirectory(dfb, lock, into);
            dl.UnLock(lock);
        }
        if (place.flags & dos.DVPF_ASSIGN == 0) break;
        if (dl.GetDeviceProc(diskfont.FONTSNAME, place) == null) break;
    }
}

/// Each `.font` file in one directory, its entries.
fn visitDirectory(dfb: *DiskfontBase, dir: *dos.FileLock, into: *Collector) void {
    const dl = dfb.dos_base;
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(dir, &fib)) return;
    const was = dl.CurrentDir(dir);
    defer _ = dl.CurrentDir(was);
    while (dl.ExNext(dir, &fib)) {
        if (fib.dir_entry_type > 0) continue;
        const name: [*:0]const u8 = @ptrCast(&fib.file_name);
        if (!endsInFont(name)) continue;
        var contents = _font.readContents(dfb, name);
        defer contents.free(dfb);
        for (contents.entries()) |entry| {
            const kind = diskfont.AFF_DISK | if (entry.outline != 0) diskfont.AFF_SCALABLE else 0;
            into.add(kind, name, entry.y_size, entry.style, entry.flags | graphics.FPF_DISKFONT);
        }
    }
}

/// Whether a name ends in ".font", in any case.
fn endsInFont(name: [*:0]const u8) bool {
    var len: usize = 0;
    while (name[len] != 0) len += 1;
    const suffix = ".font";
    if (len <= suffix.len) return false;
    for (suffix, 0..) |c, i| {
        const got = name[len - suffix.len + i];
        const lower = if (got >= 'A' and got <= 'Z') got + 32 else got;
        if (lower != c) return false;
    }
    return true;
}
