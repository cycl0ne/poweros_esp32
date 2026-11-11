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
//! needs - and then the outlines nobody holds (`outline/_outline.zig`).
//!
//! **A font falls back to the families `font.prefs` names** under
//! FALLBACK: as a record is made, `fallbackOf` opens those families at
//! the record's height and sets the first that opens as the TextFont's
//! `fallback`, before graphics has the font. A family of the list is
//! given the families after it, so the fonts of one height are one chain
//! in the list's order and no font comes back to itself. A font that
//! another falls back to is kept for as long as that other is: `freeOne`
//! passes it by.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const graphics = sdk.graphics;
const fontimage = graphics.fontimage;
const fontfile = sdk.diskfont.fontfile;
const TextFont = graphics.TextFont;
const _base = @import("../diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const _outline = @import("../outline/_outline.zig");
const opendiskfont = @import("opendiskfont.zig");
const font_prefs = sdk.prefs.font;

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
    // The font is on the system's list until it is flushed: the system's, not
    // the task's that opened it first.
    const memory = dfb.sys_base.AllocVec(@sizeOf(DiskFont) + size, exec.MEMF_ANY | exec.MEMF_SYSTEM) orelse return null;
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
    // Set before graphics has the font, and never again: whoever draws
    // with it reads the chain without a lock.
    const fallback = fallbackOf(dfb, record);
    record.font.fallback = fallback;
    if (!gb.AddFont(&record.font)) {
        if (fallback) |held| gb.CloseFont(held);
        dfb.sys_base.FreeVec(record);
        return null;
    }
    dfb.sys_base.AddTail(&dfb.fonts, &record.link);
    // The record on the library's list keeps the font it falls back to
    // from here on, so the open that kept it until now is given back.
    if (fallback) |held| gb.CloseFont(held);
    // Its own description weighs perfectly against it, so this opens it -
    // or one exactly like it that was there first.
    const attr = attrOf(&record.font);
    return gb.OpenFont(&attr);
}

/// The font a record's font falls back to: of the families `font.prefs`
/// names under FALLBACK - those after the record's own family, if it is
/// one of them - the first that opens at the record's height as a font of
/// the library's. The caller holds the load lock.
///
/// The families are opened from the last to the first, so each is in
/// memory, with its own fallback set, by the time the one before it is
/// made and asks for it: making a family as a fallback goes one level
/// into this function, however many families there are. Only a family
/// scaled from a size of another height goes further, for that size's
/// own fallbacks.
///
/// A family that opens at another height (a scaler without memory), or
/// as a font a program added under the same name, is passed over: the
/// first would not sit on the line, and the second the library could not
/// keep. A font of the ROM's at the height is taken: graphics keeps it
/// for good. It falls back to nothing, so the chain ends with it,
/// whatever the list names after it.
///
/// INPUTS:
/// - `dfb` - the library.
/// - `record` - the record, its name and image set, on no list yet.
///
/// RESULT:
/// The font, open: the caller closes it once the record is on the
/// library's list. Null when `font.prefs` names no family, or none of
/// them opens.
fn fallbackOf(dfb: *DiskfontBase, record: *const DiskFont) ?*TextFont {
    const gb = dfb.graphics_base;
    if (!dfb.fallbacks_read) readFallbacks(dfb);
    if (dfb.fallback_count == 0) return null;
    // A family is given the families after it, so the depth ends with
    // the list; this holds whatever a list turns out to be.
    if (dfb.fallback_depth >= graphics.FONT_FALLBACKS) return null;
    dfb.fallback_depth += 1;
    defer dfb.fallback_depth -= 1;

    const family: [*:0]const u8 = @ptrCast(&record.name);
    var first: u32 = 0;
    var index: u32 = 0;
    while (index < dfb.fallback_count) : (index += 1) {
        if (dfb.utility_base.Stricmp(family, fallbackName(dfb, index)) == 0) first = index + 1;
    }
    const height = record.font.image.height;
    var next: ?*TextFont = null;
    index = dfb.fallback_count;
    while (index > first) {
        index -= 1;
        const want = graphics.TextAttr{ .name = fallbackName(dfb, index), .y_size = height };
        const font = opendiskfont.openFamily(dfb, &want, want.name) orelse continue;
        if (font.image.height != height or !stays(dfb, font)) {
            gb.CloseFont(font);
            continue;
        }
        // The family just opened has the one held as its fallback, or
        // goes its own way: made before the list named it, or the ROM's.
        if (next) |held| gb.CloseFont(held);
        next = font;
    }
    return next;
}

/// The name of the fallback family at `index` of the list.
fn fallbackName(dfb: *DiskfontBase, index: u32) [*:0]const u8 {
    return @ptrCast(&dfb.fallback_names[index]);
}

/// Whether a font is in memory for as long as a record that falls back
/// to it: a record of the library's, which `freeOne` keeps for that
/// long, or a font of the ROM's.
fn stays(dfb: *DiskfontBase, font: *const TextFont) bool {
    if (font.flags & graphics.FPF_ROMFONT != 0) return true;
    var at = dfb.fonts.first();
    while (at) |node| : (at = node.next()) {
        const record: *const DiskFont = @fieldParentPtr("link", node);
        if (&record.font == font) return true;
    }
    return false;
}

/// Whether a font of the library's is what another of them falls back
/// to.
fn fallenBackTo(dfb: *DiskfontBase, font: *const TextFont) bool {
    var at = dfb.fonts.first();
    while (at) |node| : (at = node.next()) {
        const record: *const DiskFont = @fieldParentPtr("link", node);
        if (record.font.fallback == font) return true;
    }
    return false;
}

/// The fallback families read from `ENV:Sys/font.prefs` into the base:
/// none when there is no file, its line is not a font line, or it names
/// none. A family whose name is too long for a record is left out: no
/// font of the library's has it.
fn readFallbacks(dfb: *DiskfontBase) void {
    const sys = dfb.sys_base;
    dfb.fallbacks_read = true;
    dfb.fallback_count = 0;
    const read = sdk.prefs.loadWhole(sys, dfb.dos_base, font_prefs.ENV_FILE) orelse return;
    defer sys.FreeVec(read.ptr);
    const words = sdk.prefs.firstLine(read) orelse return;
    // The line is most of a kilobyte, and this is deep in the stack of
    // whoever opens a font.
    const memory = sys.AllocVec(@sizeOf(font_prefs.Line), exec.MEMF_ANY) orelse return;
    defer sys.FreeVec(memory);
    const line: *font_prefs.Line = @ptrCast(@alignCast(memory));
    if (font_prefs.parse(dfb.utility_base, words, line) != null) return;
    var families = font_prefs.Families{ .text = line.fallbacks() orelse return };
    while (families.next()) |family| {
        if (family.len == 0 or family.len >= MAXFONTNAME) continue;
        const name = &dfb.fallback_names[dfb.fallback_count];
        @memset(name, 0);
        @memcpy(name[0..family.len], family);
        dfb.fallback_count += 1;
    }
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

/// What a size made from an outline holds: the characters the font has
/// of Latin, Greek and Cyrillic - with IPA, the spacing modifiers (`ˆ`
/// `˜` `ˇ`) and the combining marks, which a letter written apart from
/// its mark is followed by - general punctuation, currency, the
/// letterlike symbols (`™`, `№`), box drawing and blocks, and U+FFFD. A
/// character the font lacks is looked for in the font's fallbacks; one
/// they lack too is drawn as its base letter if it is a Latin, Greek or
/// Cyrillic letter, and as the font's missing glyph if not.
const outline_ranges = [_]sdk.truetype.CodeRange{
    .{ .first = 0x0020, .last = 0x007E }, // ASCII
    .{ .first = 0x00A0, .last = 0x036F }, // Latin-1, Latin Extended-A and -B, IPA, spacing modifiers, combining marks
    .{ .first = 0x0370, .last = 0x052F }, // Greek, Cyrillic and its supplement
    .{ .first = 0x1E00, .last = 0x1FFF }, // Latin Extended Additional, Greek Extended
    .{ .first = 0x2000, .last = 0x206F }, // general punctuation
    .{ .first = 0x20A0, .last = 0x20CF }, // currency
    .{ .first = 0x2100, .last = 0x214F }, // letterlike symbols
    .{ .first = 0x2500, .last = 0x259F }, // box drawing, blocks
    .{ .first = 0xFFFD, .last = 0xFFFD }, // the replacement character
};

/// A size made from a family's outline, `rows` tall: the TrueType file
/// at `path` beside the contents file read, rendered by truetype.library
/// (opened on first use) with the characters of `outline_ranges`, added
/// and opened. The caller holds the load lock.
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
    const tb = trueType(dfb) orelse return null;
    const data = readWhole(dfb, dir, path, exec.MEMF_ANY) orelse return null;
    defer sys.FreeVec(data.ptr);

    const outline = tb.OpenOutline(data.ptr, @intCast(data.len), null) orelse return null;
    defer tb.CloseOutline(outline);
    const image = tb.RenderFontImage(outline, rows, &outline_ranges, outline_ranges.len) orelse return null;
    defer sys.FreeVec(image);
    const image_bytes: [*]const u8 = @ptrCast(image);
    const record = newRecord(dfb, name, image.size) orelse return null;
    @memcpy(imageArea(record)[0..image.size], image_bytes[0..image.size]);
    record.font.flags = graphics.FPF_DISKFONT;
    return addAndOpen(dfb, record);
}

/// truetype.library, opened the first time it is needed and kept until
/// expunge; null if it cannot be opened.
pub fn trueType(dfb: *DiskfontBase) ?*sdk.interface.truetype.TrueTypeBase {
    if (dfb.truetype_base) |tb| return tb;
    const lib = dfb.sys_base.OpenLibrary(sdk.truetype.TRUETYPENAME, sdk.truetype.TRUETYPE_VERSION) orelse return null;
    dfb.truetype_base = @ptrCast(lib);
    return dfb.truetype_base;
}

/// The file at `path` relative to `dir`, read whole into memory of
/// `flags`, which the caller frees with FreeVec; null if it cannot be read
/// or is larger than a size file may be.
pub fn readWhole(dfb: *DiskfontBase, dir: ?*dos.FileLock, path: [*:0]const u8, flags: u32) ?[]u8 {
    const sys = dfb.sys_base;
    const dl = dfb.dos_base;
    const was = dl.CurrentDir(dir);
    const fh = dl.Open(path, dos.MODE_OLDFILE);
    _ = dl.CurrentDir(was);
    const file = fh orelse return null;
    defer _ = dl.Close(file);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.ExamineFH(file, &fib) or fib.size > max_size_file) return null;
    const size: u32 = @intCast(fib.size);
    const bytes = sys.AllocVec(@max(size, 4), flags) orelse return null;
    const data: [*]u8 = @ptrCast(bytes);
    if (dl.Read(file, data, @intCast(size)) != size) {
        sys.FreeVec(bytes);
        return null;
    }
    return data[0..size];
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
        // One that another font draws from stays until that one has gone.
        if (fallenBackTo(dfb, &record.font)) continue;
        if (!dfb.graphics_base.AttemptRemFont(&record.font)) continue;
        dfb.sys_base.Remove(&record.link);
        dfb.sys_base.FreeVec(record);
        return true;
    }
    // Then an outline nobody holds (since 1.4).
    return _outline.freeOne(dfb);
}
