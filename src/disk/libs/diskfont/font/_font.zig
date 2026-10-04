// SPDX-License-Identifier: MIT
//! A font diskfont.library holds, and what it does with it.
//!
//! **A font is one allocation**: a `DiskFont` record - the `TextFont`
//! first, then the link on the library's own list and the family's name
//! the TextFont is known by - and the image right after it, as it was
//! read from its size file or made by the scaler. Freeing the font is one
//! FreeVec, and because the TextFont comes first, FreeVec of the TextFont
//! is the same thing - which is how a caller frees what NewScaledDiskFont
//! gave it.
//!
//! Fonts nobody holds stay loaded, for the next OpenDiskFont to find in
//! memory, until memory runs short: the library's low-memory handler then
//! frees one at a time, for as long as the allocation that ran short
//! needs.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const fontfile = sdk.diskfont.fontfile;
const TextFont = graphics.TextFont;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;

/// How long a family's name may be, ".font" and the NUL included.
pub const MAXFONTNAME = 32;

/// A font the library made: the TextFont, its link on the library's
/// list, its name. The image follows the record.
pub const DiskFont = extern struct {
    font: TextFont,
    link: exec.Node = .{},
    /// The family's name, "spleen.font"; `font.node.name` points here.
    name: [MAXFONTNAME]u8 = @splat(0),
};

comptime {
    // The image starts right after the record, and wants 4-byte alignment.
    if (@sizeOf(DiskFont) % 4 != 0) @compileError("DiskFont is not a whole number of longwords");
}

/// A record and room for an image of `size` bytes after it, the name set
/// and the TextFont pointed at the image; null without memory.
///
/// INPUTS:
/// - `dfb` - the library.
/// - `name` - the family's name; cut to fit.
/// - `size` - the image's size.
pub fn newRecord(dfb: *DiskfontBase, name: [*:0]const u8, size: u32) ?*DiskFont {
    const memory = dfb.sys_base.AllocVec(@sizeOf(DiskFont) + size, exec.MEMF_ANY) orelse return null;
    const record: *DiskFont = @ptrCast(@alignCast(memory));
    record.* = .{ .font = .{ .image = @ptrCast(imageArea(record)) } };
    var i: usize = 0;
    while (name[i] != 0 and i < MAXFONTNAME - 1) : (i += 1) record.name[i] = name[i];
    record.font.node.name = @ptrCast(&record.name);
    return record;
}

/// Where a record's image goes.
pub fn imageArea(record: *DiskFont) [*]align(4) u8 {
    const bytes: [*]align(4) u8 = @ptrCast(record);
    return bytes + @sizeOf(DiskFont);
}

/// The record a TextFont of the library's is the start of.
pub fn recordOf(font: *TextFont) *DiskFont {
    return @fieldParentPtr("font", font);
}

/// A font's own description, as it is opened again: its name, height,
/// drawn styles, and its flags with where it came from.
pub fn attrOf(font: *const TextFont) graphics.TextAttr {
    return .{
        .name = font.node.name orelse "",
        .y_size = font.image.height,
        .style = font.image.style,
        .flags = font.image.flags | font.flags,
    };
}

/// A record just made, put on graphics' list and the library's, and
/// opened for the caller. The caller holds the load lock.
///
/// RESULT:
/// The font, open; null if graphics refused it, and then the record is
/// freed.
pub fn addAndOpen(dfb: *DiskfontBase, record: *DiskFont) ?*TextFont {
    const gb = dfb.graphics_base;
    if (!gb.AddFont(&record.font)) {
        dfb.sys_base.FreeVec(record);
        return null;
    }
    dfb.sys_base.AddTail(&dfb.fonts, &record.link);
    // Its own description weighs perfectly against it, so this opens it -
    // or one exactly like it that was there first.
    const attr = attrOf(&record.font);
    return gb.OpenFont(&attr);
}

/// A size of a family, read from `path` relative to the directory `dir`,
/// checked whole, added and opened. The caller holds the load lock.
///
/// INPUTS:
/// - `dfb` - the library.
/// - `dir` - the directory the family's contents file is in.
/// - `path` - the size file, from there: "spleen/16".
/// - `name` - the family's name, "spleen.font".
///
/// RESULT:
/// The font, open, or null if the file cannot be read or is not a whole
/// font.
pub fn loadSize(dfb: *DiskfontBase, dir: ?*dos.FileLock, path: [*:0]const u8, name: [*:0]const u8) ?*TextFont {
    const dl = dfb.dos_base;
    const was = dl.CurrentDir(dir);
    defer _ = dl.CurrentDir(was);
    const fh = dl.Open(path, dos.MODE_OLDFILE) orelse return null;
    defer _ = dl.Close(fh);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.ExamineFH(fh, &fib)) return null;
    if (fib.size > max_size_file) return null;
    const size: u32 = @intCast(fib.size);
    const record = newRecord(dfb, name, size) orelse return null;
    const image = imageArea(record);
    if (dl.Read(fh, image, @intCast(size)) != size or
        !fontimage.check(image, size) or !fontimage.sound(image, size))
    {
        dfb.sys_base.FreeVec(record);
        return null;
    }
    record.font.flags = graphics.FPF_DISKFONT;
    return addAndOpen(dfb, record);
}

/// A size made from a family's outline, `rows` tall: the TrueType file
/// at `path` beside the contents file read, rendered by truetype.library
/// (opened on first use), added and opened. The caller holds the load
/// lock.
///
/// INPUTS:
/// - `dfb` - the library.
/// - `dir` - the directory the family's contents file is in.
/// - `path` - the TrueType file, from there.
/// - `name` - the family's name.
/// - `rows` - the height wanted.
///
/// RESULT:
/// The font, open, or null if the file cannot be read or rendered.
pub fn renderOutline(dfb: *DiskfontBase, dir: ?*dos.FileLock, path: [*:0]const u8, name: [*:0]const u8, rows: u32) ?*TextFont {
    const sys = dfb.sys_base;
    const dl = dfb.dos_base;
    const tb = dfb.truetype_base orelse blk: {
        const lib = sys.OpenLibrary(sdk.truetype.TRUETYPENAME, sdk.truetype.TRUETYPE_VERSION) orelse return null;
        dfb.truetype_base = @ptrCast(lib);
        break :blk dfb.truetype_base.?;
    };
    const was = dl.CurrentDir(dir);
    const fh = dl.Open(path, dos.MODE_OLDFILE);
    _ = dl.CurrentDir(was);
    const file = fh orelse return null;
    defer _ = dl.Close(file);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.ExamineFH(file, &fib) or fib.size > max_size_file) return null;
    const size: u32 = @intCast(fib.size);
    const bytes = sys.AllocVec(@max(size, 4), exec.MEMF_ANY) orelse return null;
    defer sys.FreeVec(bytes);
    const data: [*]u8 = @ptrCast(bytes);
    if (dl.Read(file, data, @intCast(size)) != size) return null;

    const outline = tb.OpenOutline(data, size) orelse return null;
    defer tb.CloseOutline(outline);
    const image = tb.RenderFontImage(outline, rows, 32, 255) orelse return null;
    defer sys.FreeVec(image);
    const image_bytes: [*]const u8 = @ptrCast(image);
    const record = newRecord(dfb, name, image.size) orelse return null;
    @memcpy(imageArea(record)[0..image.size], image_bytes[0..image.size]);
    record.font.flags = graphics.FPF_DISKFONT;
    return addAndOpen(dfb, record);
}

/// The largest size file read: a font of hundreds of large glyphs in
/// colour is still far below it.
const max_size_file = 4 * 1024 * 1024;

/// A family's contents file, read whole, and the directory it is in.
pub const Contents = struct {
    block: ?[*]align(4) u8 = null,
    size: u32 = 0,
    /// A lock on the file's directory, where its sizes are.
    dir: ?*dos.FileLock = null,

    /// The entries; none if there was no file.
    pub fn entries(contents: *const Contents) []const fontfile.FontContents {
        const block = contents.block orelse return &.{};
        return fontfile.entriesOf(block);
    }

    /// Everything it holds given back.
    pub fn free(contents: *Contents, dfb: *DiskfontBase) void {
        if (contents.block) |block| dfb.sys_base.FreeVec(block);
        dfb.dos_base.UnLock(contents.dir);
        contents.* = .{};
    }
};

/// The contents file at `path`, if there is a sound one.
///
/// INPUTS:
/// - `dfb` - the library.
/// - `path` - "FONTS:spleen.font", or wherever the caller named.
pub fn readContents(dfb: *DiskfontBase, path: [*:0]const u8) Contents {
    const dl = dfb.dos_base;
    const fh = dl.Open(path, dos.MODE_OLDFILE) orelse return .{};
    defer _ = dl.Close(fh);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.ExamineFH(fh, &fib) or fib.size > max_contents_file) return .{};
    const size: u32 = @intCast(fib.size);
    const memory = dfb.sys_base.AllocVec(@max(size, 4), exec.MEMF_ANY) orelse return .{};
    const block: [*]align(4) u8 = @ptrCast(@alignCast(memory));
    if (dl.Read(fh, block, @intCast(size)) != size or !fontfile.sound(block, size)) {
        dfb.sys_base.FreeVec(block);
        return .{};
    }
    const file_lock = dl.DupLockFromFH(fh);
    const dir = dl.ParentDir(file_lock);
    dl.UnLock(file_lock);
    return .{ .block = block, .size = size, .dir = dir };
}

/// A contents file lists at most this many sizes.
const max_contents_file = fontfile.contentsSize(1024);

/// The low-memory handler: one font nobody holds taken off graphics'
/// list and freed, per call.
///
/// It runs inside AllocMem, in whichever task ran short and whatever that
/// task holds, so it waits for nothing: a load under way (the load lock
/// held) or graphics' list in use means it does nothing this time.
///
/// INPUTS:
/// - `data` - what the allocation wanted; not looked at: a font is freed
///   whatever its size, and the allocation retried.
/// - `is_data` - the library's base.
///
/// RESULT:
/// `MEM_TRY_AGAIN` after freeing one, so AllocMem retries and calls again
/// if that was not enough; `MEM_DID_NOTHING` when there was none to free.
pub fn flushFonts(data: *const exec.MemHandlerData, is_data: ?*anyopaque) callconv(.c) i32 {
    _ = data;
    const dfb: *DiskfontBase = @ptrCast(@alignCast(is_data.?));
    const sys = dfb.sys_base;
    if (!sys.AttemptSemaphore(&dfb.load_lock)) return exec.MEM_DID_NOTHING;
    defer sys.ReleaseSemaphore(&dfb.load_lock);
    return if (freeOne(dfb)) exec.MEM_TRY_AGAIN else exec.MEM_DID_NOTHING;
}

/// One of the library's fonts that nobody holds, freed. The caller holds
/// the load lock.
///
/// RESULT:
/// Whether one was.
pub fn freeOne(dfb: *DiskfontBase) bool {
    var at = dfb.fonts.first();
    while (at) |node| : (at = node.next()) {
        const record: *DiskFont = @fieldParentPtr("link", node);
        if (!dfb.graphics_base.AttemptRemFont(&record.font)) continue;
        dfb.sys_base.Remove(&record.link);
        dfb.sys_base.FreeVec(record);
        return true;
    }
    return false;
}
