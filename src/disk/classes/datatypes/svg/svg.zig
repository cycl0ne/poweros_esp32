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
//! **What is drawn** is SVG 1.1's static pictures, without patterns:
//! see `draw.zig`. Since 1.2 clips and masks are drawn, `use` and
//! `symbol`, and the rules of the file's `style` elements. Since 1.3
//! text is, in the fonts of `FONTS:` - diskfont.library's outlines,
//! drawn by truetype.library's glyphs - and blurs, and pictures in the
//! file: an `image` of a `data:` address is made a picture by
//! datatypes.library from its bytes. Since 1.4 a text is shaped by its
//! font, through truetypeshaping.library: kerned, its ligatures joined,
//! its marks put on their letters, and since 1.5 a glyph of any number
//! of points is drawn. Without those libraries, or a font, the text or
//! the picture is left out and the rest is drawn. A
//! picture reads no other file and goes to no address on a network: an
//! `href` is followed only within the file.
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
const dtc = datatypes.datatypesclass;
const xml = @import("xml.zig");
const document = @import("document.zig");
const draw = @import("draw.zig");
const data = @import("data.zig");
const DosBase = sdk.interface.dos.DosBase;
const ExecBase = sdk.interface.exec.ExecBase;
const VectorBase = sdk.interface.vector.VectorBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;
const TrueTypeShapingBase = sdk.interface.truetypeshaping.TrueTypeShapingBase;
const DiskfontBase = sdk.interface.diskfont.DiskfontBase;
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
    .revision = 6,
    .date = "12.11.2026",
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

/// The vector.library revision the class needs: blurs and pictures are
/// 1.4's.
const vector_revision = 4;
/// The revisions text needs: truetype.library's glyphs,
/// truetypeshaping.library's `ShapeText`, diskfont's outlines.
const truetype_revision = 2;
const shaping_revision = 1;
const diskfont_revision = 4;

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

/// The file read, drawn and handed over. What went wrong, or 0.
fn readFile(base: *Base, cl: *Class, o: *Object, file_bytes: []u8, wanted: Wanted) i32 {
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
    var sources = Sources.open(base);
    defer sources.close();
    draw.draw(vb, &sources, &doc, canvas, path, work, draw.baseMatrix(intrinsic, width, height), intrinsic.viewport);

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
    tb: ?*TrueTypeBase = null,
    sb: ?*TrueTypeShapingBase = null,
    dfb: ?*DiskfontBase = null,
    dt: ?*DataTypesBase = null,

    fn open(base: *Base) Sources {
        const sys = base.sys_base;
        var s = Sources{ .base = base };
        s.tb = @ptrCast(openAt(sys, truetype.TRUETYPENAME, truetype_revision));
        if (s.tb != null) s.sb = @ptrCast(openAt(sys, tts.TRUETYPESHAPINGNAME, shaping_revision));
        if (s.sb != null) s.dfb = @ptrCast(openAt(sys, diskfont.DISKFONTNAME, diskfont_revision));
        s.dt = @ptrCast(sys.OpenLibrary(datatypes.DATATYPESNAME, 0));
        return s;
    }

    fn close(s: *Sources) void {
        const sys = s.base.sys_base;
        if (s.dfb) |l| sys.CloseLibrary(l.lib());
        if (s.sb) |l| sys.CloseLibrary(l.lib());
        if (s.tb) |l| sys.CloseLibrary(l.lib());
        if (s.dt) |l| sys.CloseLibrary(l.lib());
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

    pub fn OpenFace(s: *Sources, name: [*:0]const u8, style: graphics.FontStyle) ?*diskfont.OutlineFont {
        const dfb = s.dfb orelse return null;
        return dfb.OpenOutlineFont(name, style);
    }
    pub fn CloseFace(s: *Sources, font: *diskfont.OutlineFont) void {
        s.dfb.?.CloseOutlineFont(font);
    }
    /// A stretch of text shaped by its font, read from left to right
    /// in no language of its own.
    pub fn ShapeText(s: *Sources, outline: *truetype.Outline, text: []const u8, language: u32, features: ?[*]const tts.Feature, run: *tts.ShapedRun) i32 {
        return s.sb.?.ShapeText(outline, text.ptr, @intCast(text.len), tts.TTS_LEFT_TO_RIGHT, language, features, run);
    }
    pub fn GlyphMetrics(s: *Sources, outline: *truetype.Outline, glyph: u32, metrics: *truetype.GlyphMetrics) bool {
        return s.tb.?.GlyphMetrics(outline, glyph, metrics);
    }
    pub fn GlyphSegments(s: *Sources, outline: *truetype.Outline, glyph: u32, segments: *truetype.Segments) i32 {
        return s.tb.?.GlyphSegments(outline, glyph, segments);
    }
    pub fn FontMetrics(s: *Sources, outline: *truetype.Outline, metrics: *truetype.FontMetrics) void {
        s.tb.?.FontMetrics(outline, metrics);
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

    /// The picture of a `data:` address: its bytes decoded, made a
    /// picture of their own by datatypes.library, and its pixels taken
    /// into pens. Null for an address of another kind, bytes no
    /// datatype reads, an SVG file - a picture is not drawn inside
    /// another - or no memory.
    pub fn OpenImage(s: *Sources, href: []const u8) ?draw.Image {
        const dt = s.dt orelse return null;
        const sys = s.base.sys_base;
        const ib = s.base.intuition_base;
        const text = data.base64Of(href) orelse return null;
        const most = data.decodedMost(text);
        const bytes_memory = sys.AllocVec(@max(most, 1), exec.MEMF_ANY) orelse return null;
        defer sys.FreeVec(bytes_memory);
        const bytes = data.decode(text, @as([*]u8, @ptrCast(bytes_memory))[0..most]) orelse return null;
        if (bytes.len == 0 or isGzip(bytes) or document.startsSvg(bytes)) return null;
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
            const failure = switch (subclass.readSource(sys, dl, ib, cl, obj)) {
                .got => |bytes| failed: {
                    defer sys.FreeVec(bytes.ptr);
                    break :failed readFile(base, cl, obj, bytes, wanted);
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
