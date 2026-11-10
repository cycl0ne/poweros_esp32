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
//! **What is drawn** is SVG 1.1's static pictures, without what needs
//! more than one pass - filters, clips, masks, patterns - and without
//! text, images and `use`: see `draw.zig`. A picture reads no other
//! file and goes to no address on a network: an `href` is followed only
//! within the file, and only to a gradient.
//!
//! The library's recognise call accepts a file whose first element,
//! after the declaration, comments and a DOCTYPE, is `svg`.

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
const xml = @import("xml.zig");
const document = @import("document.zig");
const draw = @import("draw.zig");
const DosBase = sdk.interface.dos.DosBase;
const ExecBase = sdk.interface.exec.ExecBase;
const VectorBase = sdk.interface.vector.VectorBase;
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
    .revision = 1,
    .date = "10.11.2026",
    .super = pic.PICTUREDTCLASS,
    .opens = &.{ pic.PICTURE_LIBRARY, vector.VECTORNAME },
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

/// The vector.library revision the class needs: `AddSegments`, which a
/// polygon is handed over with, is 1.2's.
const vector_revision = 2;

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
fn readFile(base: *Base, cl: *Class, o: *Object, bytes: []u8, wanted: Wanted) i32 {
    const sys = base.sys_base;
    const vb = vectorBase(base);
    const vector_lib = vb.lib();
    if (vector_lib.version == 1 and vector_lib.revision < vector_revision) return dos.ERROR_INVALID_RESIDENT_LIBRARY;
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
    draw.draw(vb, &doc, canvas, path, work, draw.baseMatrix(intrinsic, width, height), intrinsic.viewport);

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

/// datatypes.library's question: whether the file's first element is
/// `svg`.
fn recognise(base: *Base, context: *datatypes.DTHookContext) callconv(.c) bool {
    const sys = base.sys_base;
    const dl: *DosBase = @ptrCast(@alignCast(context.dos_base));
    const fib = context.fib orelse return false;
    if (fib.size == 0) return false;
    // Bytes in memory are in the buffer, whole.
    const file = context.file orelse {
        const whole = context.buffer orelse return false;
        return document.startsSvg(whole[0..@min(context.buffer_length, recognise_most)]);
    };
    const length: usize = @intCast(@min(fib.size, recognise_most));
    const memory = sys.AllocVec(length, exec.MEMF_ANY) orelse return false;
    defer sys.FreeVec(memory);
    const text: [*]u8 = @ptrCast(memory);
    const got = dl.Read(file, text, @intCast(length));
    if (got <= 0) return false;
    return document.startsSvg(text[0..@intCast(got)]);
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
