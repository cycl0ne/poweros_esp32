// SPDX-License-Identifier: MIT
//! png.datatype: a PNG file as a picture.
//!
//! A picture.datatype subclass. All it does is read the file in
//! `OM_NEW` - the chunks, the palette, the compressed rows - and hand
//! the pixels to its superclass a row at a time with
//! `PDTM_WRITEPIXELARRAY`. Everything after that, drawing, scrolling,
//! scaling and writing out, is the superclass's.
//!
//! Every colour kind and every depth the format defines is read, and
//! both ways of laying the rows out. What a pixel is written as in the
//! file - one bit, a palette number, sixteen bits a channel - is all
//! gone by the time it leaves `decode.zig`: a row arrives here as red,
//! green, blue and coverage, and the coverage is what decides whether
//! the picture is later drawn mixed into what is under it.
//!
//! **The file is read whole before it is unpacked**, because the
//! compressed stream is the `IDAT` chunks joined and nothing says where
//! they end until the file does. A picture too large for memory
//! therefore fails to open, which is the right answer and not a
//! half-drawn window.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const intuition = sdk.intuition;
const classes = intuition.classes;
const classusr = intuition.classusr;
const gadgets = sdk.gadgets;
const datatypes = sdk.datatypes;
const subclass = datatypes.subclass;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const inflate = @import("inflate.zig");
const decode = @import("decode.zig");
const Class = classes.Class;
const Object = classes.Object;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = "png.datatype",
    .version = 1,
    .date = "29.09.2026",
    .super = pic.PICTUREDTCLASS,
    .opens = &.{pic.PICTURE_LIBRARY},
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// png.datatype's part of an object: nothing. The picture is the
/// superclass's the moment it has been read, and the file is closed
/// before `OM_NEW` answers.
pub const Data = extern struct {
    unused: u32 = 0,
};

/// What the decoder needs besides the file, in one block so that it
/// costs the caller's stack nothing.
const Work = struct {
    stream: inflate.Work = .{},
    palette: decode.Palette = .{},
};

/// A pass's row written pixel by pixel, for the passes of an interlaced
/// file whose pixels are not next to one another.
fn putSpread(ib: *IntuitionBase, cl: *Class, o: *Object, left: u32, top: u32, step: u32, count: u32, rgba: [*]u8) void {
    var x: u32 = 0;
    while (x < count) : (x += 1) subclass.putRow(ib, cl, o, left + x * step, top, 1, rgba + x * 4);
}

/// The file read and its pixels given to the superclass. What went
/// wrong, or 0.
fn readFile(base: *Base, cl: *Class, o: *Object, file: []const u8) i32 {
    const sys = base.sys_base;
    const info = decode.readInfo(file) catch return datatypes.DTERROR_INVALID_DATA;

    const memory = sys.AllocVec(@sizeOf(Work), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(memory);
    const work: *Work = @ptrCast(@alignCast(memory));
    work.* = .{};

    // The chunks: the palette, what of it is see-through, and how long
    // the compressed stream is when its pieces are joined.
    var plte: []const u8 = &.{};
    var trns: []const u8 = &.{};
    var idat_length: usize = 0;
    var walk = decode.Walk.start(file) catch return datatypes.DTERROR_INVALID_DATA;
    while (walk.next() catch return datatypes.DTERROR_INVALID_DATA) |chunk| {
        switch (chunk.id) {
            decode.ID_PLTE => plte = chunk.data,
            decode.ID_TRNS => trns = chunk.data,
            decode.ID_IDAT => idat_length += chunk.data.len,
            decode.ID_IEND => break,
            else => {},
        }
    }
    if (idat_length == 0) return datatypes.DTERROR_NOT_ENOUGH_DATA;
    decode.readPalette(info, &work.palette, plte, trns) catch return datatypes.DTERROR_INVALID_DATA;

    const joined_memory = sys.AllocVec(idat_length, exec.MEMF_ANY) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(joined_memory);
    const joined: [*]u8 = @ptrCast(joined_memory);
    var at: usize = 0;
    walk = decode.Walk.start(file) catch return datatypes.DTERROR_INVALID_DATA;
    while (walk.next() catch return datatypes.DTERROR_INVALID_DATA) |chunk| {
        if (chunk.id != decode.ID_IDAT) continue;
        @memcpy(joined[at..][0..chunk.data.len], chunk.data);
        at += chunk.data.len;
    }

    // The unpacked rows, each with the filter byte that says how it was
    // written down, and room for two rows of colour: the one being read
    // and the one before it, which a filter counts against.
    const raw_size = decode.rawSize(info);
    const raw_memory = sys.AllocVec(raw_size, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(raw_memory);
    const raw: [*]u8 = @ptrCast(raw_memory);
    const written = inflate.uncompress(&work.stream, joined[0..idat_length], raw[0..raw_size]) catch
        return datatypes.DTERROR_UNKNOWN_COMPRESSION;
    if (written != raw_size) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    const row_memory = sys.AllocVec(info.width * 4, exec.MEMF_ANY) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(row_memory);
    const colour: [*]u8 = @ptrCast(row_memory);

    // The row the first row of a pass is undone against: zeroes, which
    // is what the format says stands above it.
    const first_row = info.rowBytes(info.width);
    const empty_memory = sys.AllocVec(first_row, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(empty_memory);
    const empty: [*]const u8 = @ptrCast(empty_memory);

    // The picture's size, which is what gives the superclass its room.
    const alpha = info.hasAlpha(work.palette.transparent != null or trns.len != 0);
    const header = pic.BitMapHeader{
        .width = @intCast(info.width),
        .height = @intCast(info.height),
        .depth = @intCast(@min(info.channels() * info.depth, 32)),
        .masking = if (alpha) pic.mskHasAlpha else pic.mskNone,
        .x_aspect = 1,
        .y_aspect = 1,
        .page_width = @intCast(info.width),
        .page_height = @intCast(info.height),
    };
    if (!subclass.setPicture(base.intuition_base, cl, o, &header, if (alpha) pic.PBPAFMT_RGBA else pic.PBPAFMT_RGB)) {
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    }

    unpackRows(base, cl, o, info, work, raw[0..raw_size], colour, empty[0..first_row]);
    return 0;
}

/// The unpacked rows undone one after another and given to the
/// superclass, in one pass or in seven.
fn unpackRows(base: *Base, cl: *Class, o: *Object, info: decode.Info, work: *Work, raw: []u8, colour: [*]u8, empty: []const u8) void {
    if (info.interlace == 0) {
        walkPass(base, cl, o, info, work, raw, colour, empty, 0, 0, 1, 1, info.width, info.height);
        return;
    }
    var at: usize = 0;
    for (0..decode.passes.len) |pass| {
        const size = decode.passSize(info, pass);
        if (size.width == 0 or size.height == 0) continue;
        const bytes = @as(usize, size.height) * (1 + info.rowBytes(size.width));
        walkPass(
            base,
            cl,
            o,
            info,
            work,
            raw[at..][0..bytes],
            colour,
            empty,
            decode.passes[pass][0],
            decode.passes[pass][1],
            decode.passes[pass][2],
            decode.passes[pass][3],
            size.width,
            size.height,
        );
        at += bytes;
    }
}

/// One pass of rows: each undone against the one above it, read as
/// colour and handed over.
fn walkPass(base: *Base, cl: *Class, o: *Object, info: decode.Info, work: *Work, raw: []u8, colour: [*]u8, empty: []const u8, start_x: u32, start_y: u32, step_x: u32, step_y: u32, width: u32, height: u32) void {
    const stride = info.rowBytes(width);
    const pixel = info.pixelBytes();
    var above: []const u8 = empty[0..stride];
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const at = @as(usize, y) * (1 + stride);
        const kind = raw[at];
        const row = raw[at + 1 ..][0..stride];
        // The row above the first of a pass is zeroes, as the format
        // has it.
        const previous = if (y == 0) empty[0..stride] else above;
        decode.unfilter(kind, row, previous, pixel) catch return;
        decode.expand(info, &work.palette, row, width, colour[0 .. width * 4]);
        const top = start_y + y * step_y;
        if (step_x == 1) {
            subclass.putRow(base.intuition_base, cl, o, start_x, top, width, colour);
        } else {
            putSpread(base.intuition_base, cl, o, start_x, top, step_x, width, colour);
        }
        above = row;
    }
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
            const dl = base.sys_base.OpenLibrary(dos.DOSNAME, 0) orelse {
                ib.DisposeObject(obj);
                return 0;
            };
            const dos_base: *sdk.interface.dos.DosBase = @ptrCast(dl);
            defer base.sys_base.CloseLibrary(dl);

            const lock: ?*dos.FileLock = @ptrFromInt(subclass.superAsk(ib, cl, obj, dtc.DTA_Handle));
            const failure = readLocked(base, cl, obj, dos_base, lock);
            if (failure != 0) {
                _ = dos_base.SetIoErr(failure);
                ib.DisposeObject(obj);
                return 0;
            }
            return made;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}

/// The object's own file read and given to the superclass. What went
/// wrong, or 0.
fn readLocked(base: *Base, cl: *Class, o: *Object, dl: *sdk.interface.dos.DosBase, lock: ?*dos.FileLock) i32 {
    const bytes = subclass.readWhole(base.sys_base, dl, lock) orelse
        return datatypes.DTERROR_COULDNT_OPEN;
    defer base.sys_base.FreeVec(bytes.ptr);
    return readFile(base, cl, o, bytes);
}
