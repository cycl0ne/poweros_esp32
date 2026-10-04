// SPDX-License-Identifier: MIT
//! NewFontContents: a family's contents file, made from its directory.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const fontfile = sdk.diskfont.fontfile;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const _font = @import("../font/_font.zig");

/// A family's contents file, made from its directory.
///
/// SYNOPSIS:
/// ```zig
/// fn NewFontContents(dfb: *DiskfontBase, lock: ?*dos.FileLock, name: [*:0]const u8) ?*fontfile.ContentsHeader
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `lock` - the directory the family is in: `FONTS:`, or wherever its
///   contents file is to go.
/// - `name` - the family's name, ending in ".font": "spleen.font". Its
///   sizes are in the directory of that name without ".font".
///
/// RESULT:
/// The contents file's image, sealed and ready to be written as
/// `<name>`; null if the name does not end in ".font" or is too long, the
/// directory cannot be read, it holds no font, or there is no memory.
///
/// BEHAVIOR:
/// Every file in the family's directory that is a whole font - its image
/// checks and its sum is sound - becomes an entry: its path from `lock`
/// ("spleen/16"), height, drawn styles, flags, kind and width, as its own
/// header says. A TrueType file becomes the family's outline entry, of
/// height 0. Anything else there is passed over. The entries are in
/// order of height. At most 64 sizes are listed.
///
/// CONTEXT:
/// - Waits: yes, for the disk.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Process, since it reads files.
///
/// OWNERSHIP:
/// The image is the caller's, freed with `DisposeFontContents`. Its size
/// is `fontfile.contentsSize(header.count)`. `lock` stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DisposeFontContents`, `AvailFonts`
///
/// EXAMPLES:
/// ```zig
/// const made = dfb.NewFontContents(fonts_lock, "spleen.font") orelse return;
/// defer dfb.DisposeFontContents(made);
/// _ = dl.Write(fh, made, @intCast(fontfile.contentsSize(made.count)));
/// ```
pub fn NewFontContents(dfb: *DiskfontBase, lock: ?*dos.FileLock, name: [*:0]const u8) ?*fontfile.ContentsHeader {
    const dl = dfb.dos_base;
    const sys = dfb.sys_base;

    // The directory's name is the family's without ".font".
    var family: [_font.MAXFONTNAME]u8 = @splat(0);
    var len: usize = 0;
    while (name[len] != 0) : (len += 1) {
        if (len == family.len - 1) return null;
        family[len] = name[len];
    }
    const suffix = ".font";
    if (len <= suffix.len) return null;
    for (suffix, 0..) |c, i| {
        const got = family[len - suffix.len + i];
        if ((if (got >= 'A' and got <= 'Z') got + 32 else got) != c) return null;
    }
    const stem = len - suffix.len;
    family[stem] = 0;

    const was = dl.CurrentDir(lock);
    defer _ = dl.CurrentDir(was);
    const dir = dl.Lock(@ptrCast(&family), dos.SHARED_LOCK) orelse return null;
    defer dl.UnLock(dir);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(dir, &fib) or fib.dir_entry_type <= 0) return null;

    var found: [max_sizes]fontfile.FontContents = undefined;
    var count: usize = 0;
    _ = dl.CurrentDir(dir);
    while (count < max_sizes and dl.ExNext(dir, &fib)) {
        if (fib.dir_entry_type > 0) continue;
        var path: [fontfile.MAXFONTPATH]u8 = @splat(0);
        const path_len = joinPath(&path, family[0..stem], &fib.file_name) orelse continue;
        const entry = readEntry(dfb, @ptrCast(&fib.file_name), path[0..path_len]) orelse continue;
        // In order of height, as they are found.
        var at = count;
        while (at > 0 and found[at - 1].y_size > entry.y_size) : (at -= 1) found[at] = found[at - 1];
        found[at] = entry;
        count += 1;
    }
    if (count == 0) return null;

    const size = fontfile.contentsSize(@intCast(count));
    const memory = sys.AllocVec(size, exec.MEMF_ANY) orelse return null;
    const block: [*]align(4) u8 = @ptrCast(@alignCast(memory));
    const header: *fontfile.ContentsHeader = @ptrCast(block);
    header.* = .{ .count = @intCast(count) };
    const entries: [*]fontfile.FontContents = @ptrCast(@alignCast(block + @sizeOf(fontfile.ContentsHeader)));
    for (found[0..count], 0..) |entry, i| entries[i] = entry;
    fontfile.seal(block, size);
    return header;
}

/// How many sizes one family lists.
const max_sizes = 64;

/// A file's entry: a TrueType file is the family's outline; a size file
/// is listed as its image header says, if the file is a whole font. That
/// file is read whole to know it - its sum covers every byte - into
/// memory that goes again at once.
fn readEntry(dfb: *DiskfontBase, file: [*:0]const u8, path: []const u8) ?fontfile.FontContents {
    const dl = dfb.dos_base;
    const fh = dl.Open(file, dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(fh);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.ExamineFH(fh, &fib) or fib.size < 4 or fib.size > 4 * 1024 * 1024) return null;
    var magic: [4]u8 = undefined;
    if (dl.Read(fh, &magic, 4) != 4) return null;
    if (sdk.truetype.isTrueType(&magic)) return fontfile.outlineEntry(path);
    if (fib.size < @sizeOf(fontimage.FontImage)) return null;
    _ = dl.Seek(fh, 0, dos.OFFSET_BEGINNING);
    const size: u32 = @intCast(fib.size);
    const memory = dfb.sys_base.AllocVec(size, exec.MEMF_ANY) orelse return null;
    defer dfb.sys_base.FreeVec(memory);
    const block: [*]align(4) u8 = @ptrCast(@alignCast(memory));
    if (dl.Read(fh, block, @intCast(size)) != size) return null;
    if (!fontimage.check(block, size) or !fontimage.sound(block, size)) return null;
    return fontfile.entryFor(path, @ptrCast(block));
}

/// "<family>/<file>" into `out`, or null if it does not fit.
fn joinPath(out: *[fontfile.MAXFONTPATH]u8, family: []const u8, file: []const u8) ?usize {
    var len: usize = 0;
    for (family) |c| {
        if (len == out.len - 1) return null;
        out[len] = c;
        len += 1;
    }
    if (len == out.len - 1) return null;
    out[len] = '/';
    len += 1;
    for (file) |c| {
        if (c == 0) break;
        if (len == out.len - 1) return null;
        out[len] = c;
        len += 1;
    }
    return len;
}
