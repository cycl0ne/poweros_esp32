// SPDX-License-Identifier: MIT
//! svg.datatype: an SVG file as a picture.
//!
//! A picture.datatype subclass, laid out as png.datatype is: the file is
//! read whole in `OM_NEW` (`xml.zig`, `document.zig`), drawn by
//! vector.library onto pens of its own (`draw.zig`), and handed to the
//! superclass a row at a time with `PDTM_WRITEPIXELARRAY`. Everything
//! after that is the superclass's, and nothing of the file is kept.
//!
//! **The size** is the root's `width` and `height`; what it leaves out
//! comes from its `viewBox`, and without that from CSS's 300 by 150.
//! Since 1.1 a program may want another (`PDTA_WantedWidth`,
//! `PDTA_WantedHeight` at `OM_NEW`): the picture is drawn to fit inside
//! it, its shape kept, so an icon is as sharp at 40 pixels as at the 48
//! its file gives. A
//! picture larger than `draw.max_side` either way is drawn smaller to fit,
//! and one larger than memory holds is drawn at a half, a quarter or an
//! eighth of its size: drawn small, rather than drawn large and thinned.
//! What is not drawn on is clear, so the picture is shown over what is
//! under it.
//!
//! **What is drawn** is SVG's static pictures: see `draw.zig`. Since
//! 1.2 clips and masks are drawn, `use` and
//! `symbol`, and the rules of the file's `style` elements. Since 1.3
//! text is, in the fonts of `FONTS:` - diskfont.library's outlines,
//! drawn by truetype.library's glyphs - and blurs, and pictures in the
//! file: an `image` of a `data:` address is made a picture by
//! datatypes.library from its bytes. Since 1.4 a text is shaped by its
//! font, through truetypeshaping.library: kerned, its ligatures joined,
//! its marks put on their letters, and since 1.5 a glyph of any number
//! of points is drawn. Since 1.7 every filter primitive is drawn
//! (`filter.zig`), patterns, markers and context paint, blend modes,
//! text along a path, in columns, on its baselines and in both
//! directions - Arabic's letters joined, through truetypeshaping.library
//! 1.11 - and a picture of an SVG file inside another; the CSS of
//! `style` elements takes the selectors `css.zig` reads, the entities of
//! a DOCTYPE are put in (`entity.zig`), and references that close a
//! loop are dropped (`loops.zig`). Without those libraries, or a font,
//! the text or the picture is left out and the rest is drawn. Since 1.7
//! an `image` whose address names a file reads it (`address.zig`): one
//! from a relative address is found from the directory of the file the
//! picture was made from - the source's lock; a picture made from memory
//! reads only one of an address with a volume's name. No address on a
//! network is followed.
//!
//! **.svgz** (since 1.2): a file packed with gzip is unpacked whole by
//! compression.library first, into as much memory as gzip's trailer
//! says it holds - one that holds more is not an SVG file.
//!
//! The library's recognise call accepts a file whose first element,
//! after the declaration, comments and a DOCTYPE, is `svg` - unpacked
//! first, as far as `recognise_most` bytes, for one packed with gzip.

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
const pic = datatypes.pictureclass;
const vector = sdk.vector;
const compression = sdk.compression;
const truetype = sdk.truetype;
const tts = sdk.truetypeshaping;
const diskfont = sdk.diskfont;
const locale = sdk.locale;
const dtc = datatypes.datatypesclass;
const xml = @import("xml.zig");
const document = @import("document.zig");
const draw = @import("draw.zig");
const data = @import("data.zig");
const address = @import("address.zig");
const DosBase = sdk.interface.dos.DosBase;
const ExecBase = sdk.interface.exec.ExecBase;
const VectorBase = sdk.interface.vector.VectorBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;
const TrueTypeShapingBase = sdk.interface.truetypeshaping.TrueTypeShapingBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
const LocaleBase = sdk.interface.locale.LocaleBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Base = gadgets.Base;
const Pen = graphics.Pen;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
/// Its one call, after the standard four, is the recognise function
/// datatypes.library asks.
pub const Library = gadgets.ClassLibrary(.{
    .name = "svg.datatype",
    .version = 1,
    .revision = 7,
    .date = "21.11.2026",
    .super = pic.PICTUREDTCLASS,
    .opens = &.{ pic.PICTURE_LIBRARY, vector.VECTORNAME, compression.COMPRESSIONNAME },
    .Instance = Data,
    .dispatch = dispatch,
    .functions = &.{exec.libraries.vec(recognise)},
});
comptime {
    _ = Library;
}

/// vector.library, opened by the library's init (`.opens`, the second).
fn vectorBase(base: *const Base) *VectorBase {
    return @ptrCast(base.opened[1].?);
}

/// compression.library, opened by the library's init (the third).
fn compressionBase(base: *const Base) *CompressionBase {
    return @ptrCast(base.opened[2].?);
}

/// The vector.library revision the class needs: filters, blend modes
/// and a path's vertices are 1.5's.
const vector_revision = 5;
/// The revisions text needs: truetype.library's glyphs, a font's weight
/// and a glyph's measures in a column, truetypeshaping.library's
/// `ShapeText`, diskfont's outlines, the families a character missing
/// from its font is looked for in, and the face nearest a weight, a
/// width and a slant of a family found by its name.
const truetype_revision = 17;
const shaping_revision = 11;
const diskfont_revision = 16;
/// locale.library's `LanguageCode`: the user's languages, which
/// `systemLanguage` is held to.
const locale_revision = 7;

/// How much of a file recognise reads to find its first element.
const recognise_most = 16 << 10;
/// The most coverage a canvas keeps, vector.library's band.
const band_bytes = 512 << 10;

/// svg.datatype's part of an object: nothing. The picture is the
/// superclass's the moment it has been drawn.
pub const Data = extern struct {
    unused: u32 = 0,
};

/// The size a program wants the picture at, from `OM_NEW`'s tags; 0
/// for a side not given.
const Wanted = struct {
    width: u32 = 0,
    height: u32 = 0,
};

/// The file read, drawn and handed over, the files its `image`s name
/// read from `directory`, the directory of the file it was read from, if
/// any. What went wrong, or 0.
fn readFile(base: *Base, cl: *Class, o: *Object, file_bytes: []u8, wanted: Wanted, dl: *DosBase, directory: ?*dos.FileLock) i32 {
    const sys = base.sys_base;
    const vb = vectorBase(base);
    const vector_lib = vb.lib();
    if (vector_lib.version == 1 and vector_lib.revision < vector_revision) return dos.ERROR_INVALID_RESIDENT_LIBRARY;
    var bytes = file_bytes;
    var unpacked: ?[]u8 = null;
    defer if (unpacked) |text| sys.FreeVec(text.ptr);
    if (isGzip(file_bytes)) {
        unpacked = switch (gunzip(base, file_bytes)) {
            .got => |text| text,
            .too_large => return datatypes.DTERROR_TOO_LARGE,
            .bad => return datatypes.DTERROR_INVALID_DATA,
        };
        bytes = unpacked.?;
    }
    // The entities its DOCTYPE declares put in: a text of its own.
    var grown: ?[]u8 = null;
    defer if (grown) |text| sys.FreeVec(text.ptr);
    if (draw.entity.declared(bytes)) |declared| {
        if (draw.entity.expandedSize(bytes, &declared)) |size| {
            if (!subclass.roomFor(sys, size)) return datatypes.DTERROR_TOO_LARGE;
            const memory = sys.AllocVec(@max(size, 1), exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
            const text: [*]u8 = @ptrCast(memory);
            grown = draw.entity.expand(bytes, &declared, text[0..size]);
            bytes = grown.?;
        }
    }
    const counts = document.count(bytes) orelse return datatypes.DTERROR_INVALID_DATA;
    const doc_bytes = document.bytesFor(counts);
    const block_memory = sys.AllocVec(@max(doc_bytes, 8), exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(block_memory);
    const block: [*]align(8) u8 = @ptrCast(@alignCast(block_memory));
    const doc = document.build(bytes, counts, block[0..doc_bytes]);
    const intrinsic = draw.intrinsic(&doc);
    const full = draw.wantedSize(intrinsic, wanted.width, wanted.height);

    // Drawn the size it is, or smaller where there is no room for its
    // pens twice - the canvas's and the superclass's - and a band.
    var by: u32 = 1;
    var width: u32 = full[0];
    var height: u32 = full[1];
    while (true) : (by *= 2) {
        if (by > 8) return datatypes.DTERROR_TOO_LARGE;
        width = subclass.shrunk(full[0], by);
        height = subclass.shrunk(full[1], by);
        const pens = subclass.pictureBytes(width, height);
        const band = @min(band_bytes, (@as(usize, width) + 2) * height * 4);
        if (subclass.roomFor(sys, 2 * pens + band + @sizeOf(draw.Work))) break;
    }

    const pens_memory = sys.AllocVec(@as(usize, width) * height * @sizeOf(Pen), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(pens_memory);
    const pens: [*]Pen = @ptrCast(@alignCast(pens_memory));
    const canvas_tags = [_]TagItem{
        .{ .tag = vector.VCA_Width, .data = width },
        .{ .tag = vector.VCA_Height, .data = height },
        .{ .tag = vector.VCA_Pens, .data = @intFromPtr(pens) },
        .{ .tag = vector.VCA_BytesPerRow, .data = width * @sizeOf(Pen) },
        .{},
    };
    const canvas = vb.CreateCanvasTagList(&canvas_tags) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer vb.DisposeCanvas(canvas);
    const path = vb.CreatePath() orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer vb.DisposePath(path);
    const work_memory = sys.AllocVec(@sizeOf(draw.Work), exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(work_memory);
    const work: *draw.Work = @ptrCast(@alignCast(work_memory));
    var sources = Sources.open(base, dl, directory);
    defer sources.close();
    draw.draw(vb, &sources, &doc, canvas, .{ width, height }, path, work, draw.baseMatrix(intrinsic, width, height), intrinsic.viewport);

    const header = pic.BitMapHeader{
        .width = @intCast(width),
        .height = @intCast(height),
        .depth = 32,
        .masking = pic.mskHasAlpha,
        .x_aspect = 1,
        .y_aspect = 1,
        .page_width = @intCast(width),
        .page_height = @intCast(height),
    };
    subclass.setSource(base.intuition_base, cl, o, full[0], full[1], by);
    if (!subclass.setPicture(base.intuition_base, cl, o, &header, pic.PBPAFMT_RGBA)) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    const row_memory = sys.AllocVec(@as(usize, width) * 4, exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(row_memory);
    const row: [*]u8 = @ptrCast(row_memory);
    for (0..height) |y| {
        const from = pens + y * width;
        for (0..width) |x| {
            const pen = from[x];
            row[x * 4 + 0] = @truncate(pen >> 16);
            row[x * 4 + 1] = @truncate(pen >> 8);
            row[x * 4 + 2] = @truncate(pen);
            row[x * 4 + 3] = @truncate(pen >> 24);
        }
        subclass.putRow(base.intuition_base, cl, o, 0, @intCast(y), width, row);
    }
    return 0;
}

/// Where text's fonts and an `image`'s pictures come from: the libraries
/// opened for one picture, each null when it is not there or too old.
/// Text needs its three together: diskfont.library, which gives the
/// fonts, is opened only beside the other two.
const Sources = struct {
    base: *Base,
    /// For the files an `image` names, and the directory of the file the
    /// picture was read from, which a relative address starts at: null
    /// for a picture made from memory. The lock is the caller's.
    dl: *DosBase,
    directory: ?*dos.FileLock,
    tb: ?*TrueTypeBase = null,
    sb: ?*TrueTypeShapingBase = null,
    dfb: ?*DiskfontBase = null,
    dt: ?*DataTypesBase = null,
    lb: ?*LocaleBase = null,
    loc: ?*locale.Locale = null,

    fn open(base: *Base, dl: *DosBase, directory: ?*dos.FileLock) Sources {
        const sys = base.sys_base;
        var s = Sources{ .base = base, .dl = dl, .directory = directory };
        s.tb = @ptrCast(openAt(sys, truetype.TRUETYPENAME, truetype_revision));
        if (s.tb != null) s.sb = @ptrCast(openAt(sys, tts.TRUETYPESHAPINGNAME, shaping_revision));
        if (s.sb != null) s.dfb = @ptrCast(openAt(sys, diskfont.DISKFONTNAME, diskfont_revision));
        s.dt = @ptrCast(sys.OpenLibrary(datatypes.DATATYPESNAME, 0));
        s.lb = @ptrCast(openAt(sys, locale.LOCALENAME, locale_revision));
        if (s.lb) |lb| s.loc = lb.OpenLocale(null);
        return s;
    }

    fn close(s: *Sources) void {
        const sys = s.base.sys_base;
        if (s.dfb) |l| sys.CloseLibrary(l.lib());
        if (s.sb) |l| sys.CloseLibrary(l.lib());
        if (s.tb) |l| sys.CloseLibrary(l.lib());
        if (s.dt) |l| sys.CloseLibrary(l.lib());
        if (s.lb) |lb| {
            lb.CloseLocale(s.loc);
            sys.CloseLibrary(lb.lib());
        }
    }

    /// A library of version 1 at `revision` at least, or a later version.
    fn openAt(sys: *ExecBase, name: [*:0]const u8, revision: u16) ?*exec.Library {
        const lib = sys.OpenLibrary(name, 1) orelse return null;
        if (lib.version == 1 and lib.revision < revision) {
            sys.CloseLibrary(lib);
            return null;
        }
        return lib;
    }

    /// The face of the family `name` nearest what `want` asks, as
    /// diskfont.library chooses it.
    pub fn OpenFace(s: *Sources, name: [*:0]const u8, want: *const draw.Want) ?*diskfont.OutlineFont {
        const dfb = s.dfb orelse return null;
        var axes: [draw.max_axes + 1]truetype.AxisValue = undefined;
        const count = want.axesInto(&axes);
        const tags = [_]TagItem{
            .{ .tag = diskfont.DFA_Weight, .data = want.weight },
            .{ .tag = diskfont.DFA_Stretch, .data = want.stretch },
            .{ .tag = diskfont.DFA_Italic, .data = @intFromBool(want.italic) },
            .{ .tag = diskfont.DFA_Axes, .data = @intFromPtr(&axes) },
            .{ .tag = diskfont.DFA_AxisCount, .data = count },
            .{ .tag = utility.TAG_DONE, .data = 0 },
        };
        return dfb.OpenOutlineFontTagList(name, &tags);
    }
    pub fn FindFamily(s: *Sources, name: [*:0]const u8, into: [*]u8, size: u32) bool {
        const dfb = s.dfb orelse return false;
        return dfb.FindFamily(name, into, size);
    }
    pub fn GenericFamily(s: *Sources, generic: u32, into: [*]u8, size: u32) bool {
        const dfb = s.dfb orelse return false;
        return dfb.GenericFamily(generic, into, size);
    }
    pub fn FontAxes(s: *Sources, outline: *truetype.Outline, axes: ?[*]truetype.Axis, room: u32) u32 {
        return s.tb.?.FontAxes(outline, axes, room);
    }
    pub fn CloseFace(s: *Sources, font: *diskfont.OutlineFont) void {
        s.dfb.?.CloseOutlineFont(font);
    }
    pub fn FallbackFamily(s: *Sources, index: u32, name: [*]u8, size: u32) bool {
        const dfb = s.dfb orelse return false;
        return dfb.FallbackFamily(index, name, size);
    }
    pub fn GlyphIndex(s: *Sources, outline: *truetype.Outline, code: u32) u32 {
        return s.tb.?.GlyphIndex(outline, code);
    }
    /// The user's language `index`, in the order preferred, as its
    /// ISO 639-1 code; English alone without a locale.
    pub fn UserLanguage(s: *Sources, index: u32) ?[*:0]const u8 {
        const lb = s.lb orelse return if (index == 0) "en" else null;
        const loc = s.loc orelse return if (index == 0) "en" else null;
        if (index >= loc.pref_languages.len) return null;
        const name = loc.pref_languages[index] orelse return if (index == 0) lb.LanguageCode(loc.language_name) orelse "en" else null;
        return lb.LanguageCode(name) orelse "";
    }
    /// A stretch of text shaped by its font, read in `direction`.
    pub fn ShapeText(s: *Sources, outline: *truetype.Outline, text: []const u8, direction: u32, language: u32, features: ?[*]const tts.Feature, run: *tts.ShapedRun) i32 {
        return s.sb.?.ShapeText(outline, text.ptr, @intCast(text.len), direction, language, features, run);
    }
    /// The bidirectional level of each byte of a chunk's text.
    pub fn BidiLevels(s: *Sources, text: []const u8, direction: u32, levels: []u8) i32 {
        return s.sb.?.BidiLevels(text.ptr, @intCast(text.len), direction, levels.ptr);
    }
    pub fn GlyphMetrics(s: *Sources, outline: *truetype.Outline, glyph: u32, metrics: *truetype.GlyphMetrics) bool {
        return s.tb.?.GlyphMetrics(outline, glyph, metrics);
    }
    pub fn GlyphVerticalMetrics(s: *Sources, outline: *truetype.Outline, glyph: u32, metrics: *truetype.VerticalMetrics) bool {
        return s.tb.?.GlyphVerticalMetrics(outline, glyph, metrics);
    }
    pub fn GlyphSegments(s: *Sources, outline: *truetype.Outline, glyph: u32, segments: *truetype.Segments) i32 {
        return s.tb.?.GlyphSegments(outline, glyph, segments);
    }
    pub fn FontMetrics(s: *Sources, outline: *truetype.Outline, metrics: *truetype.FontMetrics) void {
        s.tb.?.FontMetrics(outline, metrics);
    }
    pub fn GlyphPaints(s: *Sources, outline: *truetype.Outline, glyph: u32, steps: ?[*]truetype.PaintStep, room: u32) u32 {
        return s.tb.?.GlyphPaints(outline, glyph, steps, room);
    }
    pub fn GlyphPicture(s: *Sources, outline: *truetype.Outline, glyph: u32, picture: *truetype.Picture) bool {
        return s.tb.?.GlyphPicture(outline, glyph, picture);
    }
    pub fn GlyphDocument(s: *Sources, outline: *truetype.Outline, glyph: u32, glyph_document: *truetype.Document) bool {
        return s.tb.?.GlyphDocument(outline, glyph, glyph_document);
    }
    /// Memory for a glyph the work block is too short for; null when
    /// there is none.
    pub fn AllocRoom(s: *Sources, bytes: usize) ?draw.Room {
        const memory = s.base.sys_base.AllocVec(@max(bytes, 1), exec.MEMF_ANY) orelse return null;
        const room: [*]align(@alignOf(vector.Point)) u8 = @ptrCast(@alignCast(memory));
        return room[0..bytes];
    }
    pub fn FreeRoom(s: *Sources, room: draw.Room) void {
        s.base.sys_base.FreeVec(room.ptr);
    }

    /// The picture an `image`'s address holds: the bytes of a `data:`
    /// address, or of the file it names, found from the directory of the
    /// picture's own file. An SVG document's text, unpacked when it is
    /// packed, or a picture datatypes.library makes pens of. Null for no
    /// such file, bytes no datatype reads, or no memory.
    pub fn OpenImage(s: *Sources, href: []const u8) ?draw.Image {
        const read = s.readAddress(href) orelse return null;
        return s.imageOf(read.memory, read.bytes);
    }

    /// The bytes an address holds as they are - an ICC profile - read as
    /// `OpenImage` reads a picture's.
    pub fn OpenFile(s: *Sources, href: []const u8) ?draw.Bytes {
        const read = s.readAddress(href) orelse return null;
        return .{ .bytes = read.bytes, .handle = read.memory };
    }
    pub fn CloseFile(s: *Sources, file: draw.Bytes) void {
        if (file.handle) |memory| s.base.sys_base.FreeVec(memory);
    }

    /// The bytes of a `data:` address, or of the file it names, in
    /// memory of AllocVec's; null for none.
    fn readAddress(s: *Sources, href: []const u8) ?struct { memory: *anyopaque, bytes: []u8 } {
        const sys = s.base.sys_base;
        const dl = s.dl;
        if (data.payloadOf(href)) |payload| {
            const most = data.payloadMost(payload);
            const memory = sys.AllocVec(@max(most, 1), exec.MEMF_ANY) orelse return null;
            const bytes = data.decodePayload(payload, @as([*]u8, @ptrCast(memory))[0..most]) orelse {
                sys.FreeVec(memory);
                return null;
            };
            return .{ .memory = memory, .bytes = bytes };
        }
        const place = address.placeOf(href) orelse return null;
        var path_room: [512]u8 = undefined;
        const path = address.dosPath(place, &path_room) orelse return null;
        // A relative path, and one from the root of a volume, start at
        // the picture's directory; one of a volume's name at that.
        const lock = if (s.directory) |directory| found: {
            const before = dl.CurrentDir(directory);
            defer _ = dl.CurrentDir(before);
            break :found dl.Lock(path.ptr, dos.SHARED_LOCK);
        } else if (place.kind == .volume) dl.Lock(path.ptr, dos.SHARED_LOCK) else null;
        const file = lock orelse return null;
        defer dl.UnLock(file);
        const bytes = switch (subclass.readWhole(sys, dl, file)) {
            .got => |whole| whole,
            .too_large, .no_file => return null,
        };
        return .{ .memory = bytes.ptr, .bytes = bytes };
    }

    /// The picture a file in memory is - a font's picture of a glyph, or
    /// the SVG document that draws one - as `OpenImage` gives the one an
    /// address holds; the bytes stay the caller's.
    pub fn OpenImageBytes(s: *Sources, bytes: []const u8) ?draw.Image {
        const sys = s.base.sys_base;
        const memory = sys.AllocVec(@max(bytes.len, 1), exec.MEMF_ANY) orelse return null;
        const copy = @as([*]u8, @ptrCast(memory))[0..bytes.len];
        @memcpy(copy, bytes);
        return s.imageOf(memory, copy);
    }

    /// The picture `bytes` are, in the memory `memory` AllocVec gave,
    /// which is kept or freed: an SVG document's text, unpacked when it
    /// is packed, or a picture datatypes.library makes pens of.
    fn imageOf(s: *Sources, memory: *anyopaque, bytes: []u8) ?draw.Image {
        const sys = s.base.sys_base;
        const ib = s.base.intuition_base;
        const bytes_memory = memory;
        var kept = false;
        defer if (!kept) sys.FreeVec(bytes_memory);
        if (bytes.len == 0) return null;
        if (isGzip(bytes)) {
            const unpacked = switch (gunzip(s.base, bytes)) {
                .got => |whole| whole,
                .too_large, .bad => return null,
            };
            if (!document.startsSvg(unpacked)) {
                sys.FreeVec(unpacked.ptr);
                return null;
            }
            return .{ .document = unpacked, .handle = unpacked.ptr };
        }
        if (document.startsSvg(bytes)) {
            kept = true;
            return .{ .document = bytes, .handle = bytes_memory };
        }
        const dt = s.dt orelse return null;
        const picture = dt.NewDTObjectA(null, &[_]TagItem{
            .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_MEMORY },
            .{ .tag = dtc.DTA_Handle, .data = @intFromPtr(bytes.ptr) },
            .{ .tag = dtc.DTA_SourceSize, .data = bytes.len },
            .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
            .{},
        }) orelse return null;
        defer dt.DisposeDTObject(picture);
        var shape: usize = 0;
        _ = dt.GetDTAttrsA(picture, &[_]TagItem{ .{ .tag = pic.PDTA_BitMapHeader, .data = @intFromPtr(&shape) }, .{} });
        if (shape == 0) return null;
        const header: *const pic.BitMapHeader = @ptrFromInt(shape);
        const width: u32 = header.width;
        const height: u32 = header.height;
        if (width == 0 or height == 0) return null;
        const size = @as(usize, width) * height * @sizeOf(Pen);
        if (!subclass.roomFor(sys, size)) return null;
        const pens_memory = sys.AllocVec(size, exec.MEMF_ANY) orelse return null;
        const pens: [*]Pen = @ptrCast(@alignCast(pens_memory));
        var read = pic.PdtBlitPixelArray{
            .method_id = pic.PDTM_READPIXELARRAY,
            .pixel_data = @ptrCast(pens),
            .format = pic.PBPAFMT_ARGB,
            .bytes_per_row = width * @sizeOf(Pen),
            .top = 0,
            .width = width,
            .height = height,
        };
        if (ib.SendMessage(picture, @ptrCast(&read)) == 0) {
            sys.FreeVec(pens_memory);
            return null;
        }
        // A, R, G, B in memory: a pen as the machine reads one.
        for (pens[0 .. @as(usize, width) * height]) |*pen| pen.* = std.mem.bigToNative(u32, pen.*);
        return .{ .pens = pens, .width = width, .height = height, .bytes_per_row = width * @sizeOf(Pen), .handle = pens_memory };
    }
    pub fn CloseImage(s: *Sources, image: draw.Image) void {
        s.base.sys_base.FreeVec(image.handle);
    }
};

/// gzip's first two bytes, and room for its header and trailer.
fn isGzip(bytes: []const u8) bool {
    return bytes.len >= 18 and bytes[0] == 0x1F and bytes[1] == 0x8B;
}

const Unpacked = union(enum) { got: []u8, too_large, bad };

/// A file packed with gzip unpacked whole into memory of its own, as
/// much as its trailer says it holds.
fn gunzip(base: *Base, bytes: []const u8) Unpacked {
    const sys = base.sys_base;
    const size = @as(u32, bytes[bytes.len - 4]) | @as(u32, bytes[bytes.len - 3]) << 8 |
        @as(u32, bytes[bytes.len - 2]) << 16 | @as(u32, bytes[bytes.len - 1]) << 24;
    if (size == 0) return .bad;
    if (!subclass.roomFor(sys, size)) return .too_large;
    const memory = sys.AllocVec(size, exec.MEMF_ANY) orelse return .too_large;
    const text: [*]u8 = @ptrCast(memory);
    var stream = compression.Stream{ .next_in = bytes.ptr, .avail_in = @intCast(bytes.len), .next_out = text, .avail_out = size };
    if (compressionBase(base).Uncompress(&stream, compression.FORMAT_GZIP) != compression.COMPRESS_OK or stream.total_out != size) {
        sys.FreeVec(memory);
        return .bad;
    }
    return .{ .got = text[0..size] };
}

/// Whether the start of a file packed with gzip, unpacked as far as
/// `recognise_most` bytes, is an SVG file's.
fn packedStartsSvg(base: *Base, bytes: []const u8) bool {
    const sys = base.sys_base;
    const cb = compressionBase(base);
    const memory = sys.AllocVec(recognise_most, exec.MEMF_ANY) orelse return false;
    defer sys.FreeVec(memory);
    const text: [*]u8 = @ptrCast(memory);
    var stream = compression.Stream{ .next_in = bytes.ptr, .avail_in = @intCast(bytes.len), .next_out = text, .avail_out = recognise_most };
    if (cb.InitInflate(&stream, compression.FORMAT_GZIP) != compression.COMPRESS_OK) return false;
    defer cb.EndInflate(&stream);
    if (cb.Inflate(&stream, compression.FLUSH_NONE) < 0) return false;
    return document.startsSvg(text[0 .. recognise_most - stream.avail_out]);
}

/// The start of a file: an SVG file's, or one packed with gzip whose is.
fn startsSvg(base: *Base, bytes: []const u8) bool {
    if (bytes.len >= 2 and bytes[0] == 0x1F and bytes[1] == 0x8B) return packedStartsSvg(base, bytes);
    return document.startsSvg(bytes);
}

/// datatypes.library's question: whether the file's first element is
/// `svg`, once it is unpacked when it is packed.
fn recognise(base: *Base, context: *datatypes.DTHookContext) callconv(.c) bool {
    const sys = base.sys_base;
    const dl: *DosBase = @ptrCast(@alignCast(context.dos_base));
    const fib = context.fib orelse return false;
    if (fib.size == 0) return false;
    // Bytes in memory are in the buffer, whole.
    const file = context.file orelse {
        const whole = context.buffer orelse return false;
        return startsSvg(base, whole[0..@min(context.buffer_length, recognise_most)]);
    };
    const length: usize = @intCast(@min(fib.size, recognise_most));
    const memory = sys.AllocVec(length, exec.MEMF_ANY) orelse return false;
    defer sys.FreeVec(memory);
    const text: [*]u8 = @ptrCast(memory);
    const got = dl.Read(file, text, @intCast(length));
    if (got <= 0) return false;
    return startsSvg(base, text[0..@intCast(got)]);
}

fn dispatch(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const cl: *Class = @ptrCast(hook);
    const base = gadgets.baseOf(cl);
    const ib = base.intuition_base;
    const sys = base.sys_base;
    const msg: *classusr.Msg = @ptrCast(@alignCast(message orelse return 0));
    const o: ?*Object = @ptrCast(object);

    switch (msg.method_id) {
        classusr.OM_NEW => {
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const ub = base.utility_base;
            const wanted = Wanted{
                .width = @truncate(ub.GetTagData(pic.PDTA_WantedWidth, 0, new.attr_list)),
                .height = @truncate(ub.GetTagData(pic.PDTA_WantedHeight, 0, new.attr_list)),
            };
            const made = ib.SendSuperMessage(cl, o, msg);
            if (made == 0) return 0;
            const obj: *Object = @ptrFromInt(made);
            const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse {
                ib.DisposeObject(obj);
                return 0;
            };
            const dl: *DosBase = @ptrCast(dos_lib);
            defer sys.CloseLibrary(dos_lib);
            // The directory of the file it is read from, for the files
            // its `image`s name.
            const directory: ?*dos.FileLock = if (subclass.superAsk(ib, cl, obj, dtc.DTA_SourceType) == dtc.DTST_FILE)
                dl.ParentDir(@ptrFromInt(subclass.superAsk(ib, cl, obj, dtc.DTA_Handle)))
            else
                null;
            defer if (directory) |lock| dl.UnLock(lock);
            const failure = switch (subclass.readSource(sys, dl, ib, cl, obj)) {
                .got => |bytes| failed: {
                    defer sys.FreeVec(bytes.ptr);
                    break :failed readFile(base, cl, obj, bytes, wanted, dl, directory);
                },
                .too_large => datatypes.DTERROR_TOO_LARGE,
                .no_file => datatypes.DTERROR_COULDNT_OPEN,
            };
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
