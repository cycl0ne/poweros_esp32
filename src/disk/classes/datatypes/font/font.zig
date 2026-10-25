// SPDX-License-Identifier: MIT
//! font.datatype: a font family's contents file as a picture of the font.
//!
//! A picture.datatype subclass. `FONTS:spleen.font`, or any other
//! family's contents file (`sdk.diskfont.fontfile`), is shown as a sheet:
//! the file's name and what the font is, a table of its characters, and
//! the same line of text at each of its sizes (sheet.zig). Everything
//! after that - drawing, scrolling, saving it as a picture - is the
//! superclass's.
//!
//! **The sizes are opened through diskfont.library**, by the family's
//! name when its file is in `FONTS:`, so that a size already in memory is
//! the one shown and the one loaded stays for whoever asks next, and by
//! the file's whole path anywhere else. A family drawn at fixed sizes
//! shows each of them as drawn (`FPF_DESIGNED`), the table at the size
//! nearest 16 rows; one with an outline is rendered at a range of
//! heights, the table at 24.
//!
//! The name, the note and the sizes' numbers are in the system's default
//! font (`IPREFS_DefaultFont`), so that a font of symbols still has a
//! sheet that says what it is. A sheet too large for the memory there is
//! loses its largest sizes until it fits.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const graphics = sdk.graphics;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const subclass = datatypes.subclass;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const fontfile = sdk.diskfont.fontfile;
const sheet = @import("sheet.zig");
const DosBase = sdk.interface.dos.DosBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const TextFont = graphics.TextFont;
const TextAttr = graphics.TextAttr;
const TagItem = utility.TagItem;
const Class = classes.Class;
const Object = classes.Object;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
///
/// diskfont.library opens the sizes, and dos.library names the file.
pub const Library = gadgets.ClassLibrary(.{
    .name = "font.datatype",
    .version = 1,
    .date = "25.10.2026",
    .super = pic.PICTUREDTCLASS,
    .opens = &.{ pic.PICTURE_LIBRARY, sdk.diskfont.DISKFONTNAME, sdk.dos.DOSNAME },
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

const opened_diskfont = 1;
const opened_dos = 2;

/// font.datatype's part of an object: nothing. The sheet is the
/// superclass's picture the moment it has been drawn.
pub const Data = extern struct {
    unused: u32 = 0,
};

/// The most sizes a sheet shows; a family listing more shows its first.
const most_sizes = 16;
/// The heights an outline is rendered at.
const outline_heights = [_]u16{ 12, 16, 20, 24, 32, 48, 64 };
/// The height the table is drawn at: an outline's, and the one a family
/// of fixed sizes comes nearest to.
const outline_table = 24;
const fixed_table = 16;

/// The fonts a sheet is drawn in, open, and the numbers it writes.
const Fonts = struct {
    gb: *GraphicsBase,
    caption: ?*TextFont = null,
    table: ?*TextFont = null,
    sizes: [most_sizes]?*TextFont = @splat(null),
    labels: [most_sizes][16]u8 = undefined,
    label_len: [most_sizes]u8 = @splat(0),
    count: usize = 0,

    fn close(fonts: *Fonts) void {
        fonts.gb.CloseFont(fonts.caption);
        fonts.gb.CloseFont(fonts.table);
        for (fonts.sizes[0..fonts.count]) |font| fonts.gb.CloseFont(font);
    }
};

/// `value` in decimal at the end of what `into` holds so far.
fn putNumber(into: []u8, at: *usize, value: u32) void {
    var digits: [10]u8 = undefined;
    var n: usize = 0;
    var left = value;
    while (true) {
        digits[n] = @intCast('0' + left % 10);
        n += 1;
        left /= 10;
        if (left == 0) break;
    }
    while (n > 0 and at.* < into.len) {
        n -= 1;
        into[at.*] = digits[n];
        at.* += 1;
    }
}

fn putText(into: []u8, at: *usize, text: []const u8) void {
    for (text) |c| {
        if (at.* >= into.len) return;
        into[at.*] = c;
        at.* += 1;
    }
}

/// The name the family is opened by: its own when its file is in
/// `FONTS:`, its whole path anywhere else.
fn nameToOpen(dl: *DosBase, lock: *dos.FileLock, path: [*:0]const u8) [*:0]const u8 {
    const parent = dl.ParentDir(lock) orelse return path;
    defer dl.UnLock(parent);
    const fonts = dl.Lock(sdk.diskfont.FONTSNAME, dos.SHARED_LOCK) orelse return path;
    defer dl.UnLock(fonts);
    return if (dl.SameLock(parent, fonts) == dos.LOCK_SAME) dl.FilePart(path) else path;
}

/// The system's default font, or pospaz from the ROM.
fn captionFont(base: *Base) ?*TextFont {
    var font: ?*TextFont = null;
    const tags = [_]TagItem{ .{ .tag = intuition.IPREFS_DefaultFont, .data = @intFromPtr(&font) }, .{} };
    _ = base.intuition_base.GetPrefs(&tags);
    if (font) |got| return got;
    return base.graphics_base.OpenFont(&.{ .name = graphics.POSPAZNAME, .y_size = 16 });
}

/// The family's sizes opened into `fonts`, smallest first, their numbers
/// written, and what the font is said in `note`. False when none opened.
fn openSizes(dfb: *DiskfontBase, name: [*:0]const u8, entries: []const fontfile.FontContents, fonts: *Fonts, note: []u8, note_len: *usize) bool {
    var outline = false;
    var colour = false;
    for (entries) |*entry| {
        if (entry.outline != 0) outline = true;
        if (entry.kind == @intFromEnum(graphics.fontimage.Kind.indexed8)) colour = true;
    }

    if (outline) {
        for (outline_heights) |height| {
            const font = dfb.OpenDiskFont(&.{ .name = name, .y_size = height }) orelse continue;
            addSize(fonts, font, height, graphics.FS_NORMAL);
        }
        fonts.table = dfb.OpenDiskFont(&.{ .name = name, .y_size = outline_table });
        putText(note, note_len, "An outline (TrueType), rendered at any height");
        return fonts.count != 0;
    }

    // The drawn sizes, each once, smallest first.
    var order: [most_sizes]*const fontfile.FontContents = undefined;
    var count: usize = 0;
    for (entries) |*entry| {
        if (count == most_sizes) break;
        const same = for (order[0..count]) |had| {
            if (had.y_size == entry.y_size and had.style == entry.style) break true;
        } else false;
        if (same) continue;
        var at = count;
        while (at > 0 and order[at - 1].y_size > entry.y_size) : (at -= 1) order[at] = order[at - 1];
        order[at] = entry;
        count += 1;
    }
    var nearest: u16 = 0;
    for (order[0..count]) |entry| {
        const want = TextAttr{ .name = name, .y_size = entry.y_size, .style = entry.style, .flags = graphics.FPF_DESIGNED };
        const font = dfb.OpenDiskFont(&want) orelse continue;
        addSize(fonts, font, entry.y_size, entry.style);
        if (nearest == 0 or distance(entry.y_size, fixed_table) < distance(nearest, fixed_table)) nearest = entry.y_size;
    }
    if (fonts.count == 0) return false;
    fonts.table = dfb.OpenDiskFont(&.{ .name = name, .y_size = nearest, .flags = graphics.FPF_DESIGNED });

    putText(note, note_len, if (colour) "Drawn in colour at " else "Drawn at ");
    for (fonts.sizes[0..fonts.count], 0..) |_, i| {
        if (i != 0) putText(note, note_len, if (i + 1 == fonts.count) " and " else ", ");
        putText(note, note_len, fonts.labels[i][0..fonts.label_len[i]]);
    }
    putText(note, note_len, " rows");
    return true;
}

fn distance(a: u16, b: u16) u16 {
    return if (a > b) a - b else b - a;
}

/// One size added, its number written - with its style where it was
/// drawn with one.
fn addSize(fonts: *Fonts, font: *TextFont, height: u16, style: graphics.FontStyle) void {
    const i = fonts.count;
    fonts.sizes[i] = font;
    var n: usize = 0;
    putNumber(&fonts.labels[i], &n, height);
    if (style & graphics.FSF_BOLD != 0) putText(&fonts.labels[i], &n, " bold");
    if (style & graphics.FSF_ITALIC != 0) putText(&fonts.labels[i], &n, " italic");
    fonts.label_len[i] = @intCast(n);
    fonts.count += 1;
}

/// The family read and its sheet drawn and handed to the superclass.
/// What went wrong, or 0.
fn readFamily(base: *Base, cl: *Class, o: *Object, dl: *DosBase, lock: *dos.FileLock, file: []u8) i32 {
    const sys = base.sys_base;
    const ib = base.intuition_base;
    const dfb: *DiskfontBase = @ptrCast(base.opened[opened_diskfont] orelse return datatypes.DTERROR_COULDNT_OPEN);
    if (!fontfile.sound(file.ptr, @intCast(file.len))) return datatypes.DTERROR_INVALID_DATA;
    const entries = fontfile.entriesOf(file.ptr);
    if (entries.len == 0) return datatypes.DTERROR_INVALID_DATA;

    var path: [256:0]u8 = @splat(0);
    if (!dl.NameFromLock(lock, &path, path.len)) return datatypes.DTERROR_COULDNT_OPEN;
    const name = nameToOpen(dl, lock, &path);

    var fonts = Fonts{ .gb = base.graphics_base };
    defer fonts.close();
    var note: [96]u8 = undefined;
    var note_len: usize = 0;
    if (!openSizes(dfb, name, entries, &fonts, &note, &note_len)) return datatypes.DTERROR_INVALID_DATA;
    fonts.caption = captionFont(base);
    const caption = fonts.caption orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    const table = fonts.table orelse fonts.sizes[0].?;

    var sizes: [most_sizes]sheet.Size = undefined;
    for (fonts.sizes[0..fonts.count], 0..) |font, i| {
        sizes[i] = .{ .image = font.?.image, .label = fonts.labels[i][0..fonts.label_len[i]] };
    }
    const title = dl.FilePart(&path);
    var page = sheet.Sheet{
        .caption = caption.image,
        .title = std.mem.span(title),
        .note = note[0..note_len],
        .table = table.image,
        .sizes = sizes[0..fonts.count],
    };

    // Laid out, and the largest sizes let go while the picture would not
    // fit.
    var lines: [sheet.linesFor(most_sizes)]sheet.Line = undefined;
    var layout = sheet.lay(&page, &lines);
    while (!subclass.roomFor(sys, subclass.pictureBytes(layout.width, layout.height)) and page.sizes.len > 1) {
        page.sizes = page.sizes[0 .. page.sizes.len - 1];
        layout = sheet.lay(&page, &lines);
    }

    const header = pic.BitMapHeader{
        .width = @intCast(layout.width),
        .height = @intCast(layout.height),
        .depth = 24,
        .masking = pic.mskNone,
        .x_aspect = 1,
        .y_aspect = 1,
        .page_width = @intCast(layout.width),
        .page_height = @intCast(layout.height),
    };
    subclass.setSource(ib, cl, o, layout.width, layout.height, 1);
    if (!subclass.setPicture(ib, cl, o, &header, pic.PBPAFMT_RGB)) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    const strip_bytes = @as(usize, layout.width) * layout.tallest * 3;
    const strip_memory = sys.AllocVec(strip_bytes, exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(strip_memory);
    const strip: [*]u8 = @ptrCast(strip_memory);
    for (lines[0..layout.count]) |*line| {
        const band = sheet.Band{ .rgb = strip[0..strip_bytes], .width = layout.width, .height = line.height };
        sheet.drawLine(&page, line, band);
        subclass.putPixels(ib, cl, o, 0, line.top, layout.width, line.height, pic.PBPAFMT_RGB, layout.width * 3, strip);
    }
    return 0;
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const made = ib.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const dl: *DosBase = @ptrCast(base.opened[opened_dos] orelse {
                ib.DisposeObject(obj);
                return 0;
            });

            const lock: ?*dos.FileLock = @ptrFromInt(subclass.superAsk(ib, cl, obj, dtc.DTA_Handle));
            const bytes = switch (subclass.readWhole(base.sys_base, dl, lock)) {
                .got => |read| read,
                .too_large => {
                    _ = dl.SetIoErr(datatypes.DTERROR_TOO_LARGE);
                    ib.DisposeObject(obj);
                    return 0;
                },
                .no_file => {
                    _ = dl.SetIoErr(datatypes.DTERROR_COULDNT_OPEN);
                    ib.DisposeObject(obj);
                    return 0;
                },
            };
            const failure = readFamily(base, cl, obj, dl, lock.?, bytes);
            base.sys_base.FreeVec(bytes.ptr);
            if (failure != 0) {
                _ = dl.SetIoErr(failure);
                ib.DisposeObject(obj);
                return 0;
            }
            return made;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
