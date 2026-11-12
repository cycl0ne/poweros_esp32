// SPDX-License-Identifier: MIT
//! NewFontContents: a family's contents file, made from its directory.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const fontfile = sdk.diskfont.fontfile;
const truetype = sdk.truetype;
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
/// SINCE: 1.0, a file of outlines of up to 64 MiB since 1.12, a
/// variable font listed a style since 1.13. LVO -28.
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
/// header says. A TrueType or OpenType file of one font becomes an
/// outline entry of the family, of height 0, in the styles the file
/// says it is drawn in - bold for a bold face. Anything else there is
/// passed over, and so is a file that is too large: a size of more than
/// 4 MiB, a file of outlines of more than 64 MiB or than there is
/// memory to read it into. The entries are in order of height. At most
/// 64 entries are listed.
///
/// **A variable font becomes an entry for each style it has**: the
/// file's own, then with bold, with italic and with both, all naming
/// the one file, each with its place on the file's axes - the axes
/// away from their default, at most `fontfile.MAXFONTAXES` of them. A
/// style is at the place of the instance the file names for it
/// ("Regular", "Bold", "Italic", "Bold Italic"; the first of a name).
/// Where the file names none, the place is made from what the axes
/// mean: regular is `wght` at 400, bold `wght` at 700, italic `ital`
/// at 1 or, without that axis, `slnt` at the end of its range away
/// from 0, each held to the axis' range; a style the axes cannot give
/// is left out and drawn by the soft styles (`fontfile.variableEntries`).
/// A variable font of more than 32 axes, or one truetype.library does
/// not open, is listed once, at its default. truetype.library is opened
/// for the first variable font found.
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

    // The entries as they are found, in memory of their own: they are
    // more than a caller's stack should hold.
    const work = sys.AllocVec(max_sizes * @sizeOf(fontfile.FontContents), exec.MEMF_ANY) orelse return null;
    defer sys.FreeVec(work);
    const found: [*]fontfile.FontContents = @ptrCast(@alignCast(work));
    var count: usize = 0;
    _ = dl.CurrentDir(dir);
    while (count < max_sizes and dl.ExNext(dir, &fib)) {
        if (dos.isDirectory(fib.dir_entry_type)) continue;
        var path: [fontfile.MAXFONTPATH]u8 = @splat(0);
        const path_len = joinPath(&path, family[0..stem], &fib.file_name) orelse continue;
        var made: [4]fontfile.FontContents = undefined;
        const made_count = readEntries(dfb, @ptrCast(&fib.file_name), path[0..path_len], &made);
        for (made[0..made_count]) |entry| {
            if (count == max_sizes) break;
            // In order of height, as they are found.
            var at = count;
            while (at > 0 and found[at - 1].y_size > entry.y_size) : (at -= 1) found[at] = found[at - 1];
            found[at] = entry;
            count += 1;
        }
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

/// How many entries one family lists.
const max_sizes = 64;

/// How many axes of a variable font are read: as many as
/// truetype.library opens a font with.
const max_axes = 32;

/// A file's entries, into `into`, and how many they are: a font file of
/// outlines is an outline of the family, in the styles it says it is
/// drawn in - a variable one an entry for each style it has
/// (`variableStyles`); a size file is listed as its image header says, if
/// the file is a whole font. The file is read whole - a size file's sum
/// covers every byte - into memory that goes again at once. A file
/// larger than its kind is read at (`_font.max_outline_file`,
/// `_font.max_size_file`), or than there is memory for, is passed over.
fn readEntries(dfb: *DiskfontBase, file: [*:0]const u8, path: []const u8, into: *[4]fontfile.FontContents) u32 {
    const dl = dfb.dos_base;
    const fh = dl.Open(file, dos.MODE_OLDFILE) orelse return 0;
    defer _ = dl.Close(fh);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.ExamineFH(fh, &fib) or fib.size < 4 or fib.size > _font.max_outline_file) return 0;
    const size: u32 = @intCast(fib.size);
    const memory = dfb.sys_base.AllocVec(size, exec.MEMF_ANY) orelse return 0;
    defer dfb.sys_base.FreeVec(memory);
    const block: [*]align(4) u8 = @ptrCast(@alignCast(memory));
    if (dl.Read(fh, block, @intCast(size)) != size) return 0;
    if (sdk.truetype.isTrueType(block[0..size])) {
        const style = sdk.truetype.styleOf(block[0..size]);
        const styles = variableStyles(dfb, block, size, path, style, into);
        if (styles != 0) return styles;
        into[0] = fontfile.outlineEntry(path, style, .{});
        return 1;
    }
    if (size < @sizeOf(fontimage.FontImage) or size > _font.max_size_file) return 0;
    if (!fontimage.check(block, size) or !fontimage.sound(block, size)) return 0;
    into[0] = fontfile.entryFor(path, @ptrCast(block));
    return 1;
}

/// The entries of a variable font, one for each style it has
/// (`fontfile.variableEntries`), from the axes and the named instances
/// truetype.library reads of the file at `block`. 0 for a file without
/// axes, one with more than are read, or one that cannot be opened: it
/// is listed once, at its default.
fn variableStyles(dfb: *DiskfontBase, block: [*]const u8, size: u32, path: []const u8, style: graphics.FontStyle, into: *[4]fontfile.FontContents) u32 {
    const tb = _font.trueType(dfb) orelse return 0;
    const outline = tb.OpenOutline(block, size, null) orelse return 0;
    defer tb.CloseOutline(outline);
    var axes: [max_axes]truetype.Axis = undefined;
    const axis_count = tb.FontAxes(outline, &axes, axes.len);
    if (axis_count == 0 or axis_count > max_axes) return 0;

    // The first instance named for a style is that style's place.
    var named: [4]?fontfile.Place = @splat(null);
    var values: [max_axes]truetype.AxisValue = undefined;
    var number: u32 = 0;
    while (true) : (number += 1) {
        const name = tb.FontInstance(outline, number, &values, values.len);
        if (name == 0) break;
        var text: [32]u8 = @splat(0);
        const len = tb.FontName(outline, name, &text, text.len);
        if (len == 0 or len >= text.len) continue;
        const said = fontfile.styleOfName(text[0..len]) orelse continue;
        if (named[said] != null) continue;
        named[said] = fontfile.placeOf(axes[0..axis_count], values[0..axis_count]);
    }
    return fontfile.variableEntries(path, style, axes[0..axis_count], &named, into);
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
