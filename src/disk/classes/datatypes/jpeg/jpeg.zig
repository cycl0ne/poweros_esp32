// SPDX-License-Identifier: MIT
//! jpeg.datatype: a JPEG file as a picture.
//!
//! A picture.datatype subclass. It reads the file in `OM_NEW` - the
//! tables, what the picture is, and the one scan that holds all of it -
//! and hands the rows to its superclass; everything after that is the
//! superclass's.
//!
//! A JPEG is not kept as pixels but as blocks of eight by eight, one set
//! for brightness and one for each of two colour differences, and the
//! colour ones are usually at half the size. So each of them is unpacked
//! into a plane of its own at its own size, and a row of pixels is made
//! at the end by reading all three: the plane's own row for brightness,
//! and the nearest one of each colour plane.
//!
//! **A colour plane kept at half the size is taken smoothly**, across
//! and down. Taking the nearest sample instead is a line of arithmetic
//! less and draws the plane's own squares round every edge, which on a
//! photograph shows as colour bleeding off each contour.
//!
//! **A picture with no colour planes is grey** and is handed over as it
//! is, which costs neither the conversion nor the two planes.
//!
//! A JPEG says nothing about coverage, so the picture is always solid.
//!
//! **On a machine with a JPEG codec** (jpeg.resource) the file goes to
//! the codec first: when it takes the file and its decoded picture fits
//! beside the one picture.datatype keeps, the rows come from that picture
//! and the software decoder is not used. The 2D-DMA brings the colour
//! planes' halved samples to full size its own way, so the picture is
//! close to the software decoder's, not equal. JDTA_Decoder
//! (sdk/libs/datatypes/jpegclass.zig)
//! given at `OM_NEW` chooses the decoder - the codec where it can, either
//! one only - and says afterwards which one read the file.

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
const jpegclass = datatypes.jpegclass;
const jpeg = sdk.resources.jpeg;
const decode = @import("decode.zig");
const DosBase = sdk.interface.dos.DosBase;
const Class = classes.Class;
const Object = classes.Object;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = "jpeg.datatype",
    .version = 1,
    .revision = 1,
    .date = "10.10.2026",
    .super = pic.PICTUREDTCLASS,
    .opens = &.{pic.PICTURE_LIBRARY},
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// jpeg.datatype's part of an object: which decoder read the file
/// (JDEC_*). The picture is the superclass's the moment it has been read.
pub const Data = extern struct {
    decoder: u32 = jpegclass.JDEC_SOFTWARE,
};

fn dataOf(cl: *Class, o: *Object) *Data {
    return intuition.instData(Data, cl, o);
}

/// The file decoded by the machine's codec, and its rows handed to the
/// superclass. Null when there is no codec, it does not take the file, or
/// its picture would not fit beside the one picture.datatype keeps: the
/// software decoder's turn. Otherwise what went wrong after the codec
/// had decoded it, or 0.
fn readByCodec(base: *Base, cl: *Class, o: *Object, file: []const u8) ?i32 {
    const sys = base.sys_base;
    const ib = base.intuition_base;
    const jb: *jpeg.JpegBase = @ptrCast(sys.OpenResource(jpeg.JPEGNAME) orelse return null);
    const length: u32 = @intCast(file.len);
    var info: jpeg.JPEGInfo = .{};
    if (jb.ExamineJPEG(file.ptr, length, &info) != jpeg.JPEGERR_OK) return null;
    const by = subclass.shrinkFor(sys, info.width, info.height, info.bytes);
    if (by == 0) return null;
    var picture: jpeg.JPEGPicture = .{};
    if (jb.DecodeJPEG(file.ptr, length, &picture) != jpeg.JPEGERR_OK) return null;
    defer jb.FreeJPEGPicture(&picture);

    const kept_width = subclass.shrunk(info.width, by);
    const kept_height = subclass.shrunk(info.height, by);
    const header = pic.BitMapHeader{
        .width = @intCast(kept_width),
        .height = @intCast(kept_height),
        .depth = @intCast(info.components * 8),
        .masking = pic.mskNone,
        .x_aspect = 1,
        .y_aspect = 1,
        .page_width = @intCast(kept_width),
        .page_height = @intCast(kept_height),
    };
    subclass.setSource(ib, cl, o, info.width, info.height, by);
    if (!subclass.setPicture(ib, cl, o, &header, pic.PBPAFMT_RGB)) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    const row_memory = sys.AllocVec(info.width * 4, exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(row_memory);
    const colour: [*]u8 = @ptrCast(row_memory);
    const pixels = picture.pixels.?;
    var y: u32 = 0;
    while (y < kept_height) : (y += 1) {
        const row = pixels + @as(usize, y * by) * picture.pitch;
        var x: u32 = 0;
        while (x < info.width) : (x += 1) {
            const at = colour + x * 4;
            if (picture.format == jpeg.JPEGFMT_GREY8) {
                at[0] = row[x];
                at[1] = row[x];
                at[2] = row[x];
            } else {
                // Blue, green, red in the codec's picture.
                at[0] = row[x * 3 + 2];
                at[1] = row[x * 3 + 1];
                at[2] = row[x * 3];
            }
            at[3] = 0xFF;
        }
        const count = subclass.thinRow(colour, info.width, by);
        subclass.putRow(ib, cl, o, 0, y, count, colour);
    }
    return 0;
}

/// The file read by the decoder `want` allows (JDEC_*): what went wrong,
/// or 0. Which one did is noted in the object.
fn readWith(base: *Base, cl: *Class, o: *Object, file: []const u8, want: usize) i32 {
    const own = dataOf(cl, o);
    if (want != jpegclass.JDEC_SOFTWARE) {
        if (readByCodec(base, cl, o, file)) |failure| {
            own.decoder = jpegclass.JDEC_CODEC;
            return failure;
        }
        if (want == jpegclass.JDEC_CODEC) return datatypes.DTERROR_UNKNOWN_COMPRESSION;
    }
    own.decoder = jpegclass.JDEC_SOFTWARE;
    return readFile(base, cl, o, file);
}

/// The file read and its pixels given to the superclass. What went
/// wrong, or 0.
fn readFile(base: *Base, cl: *Class, o: *Object, file: []const u8) i32 {
    const sys = base.sys_base;
    const ib = base.intuition_base;

    const work_memory = sys.AllocVec(@sizeOf(decode.Work), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(work_memory);
    const work: *decode.Work = @ptrCast(@alignCast(work_memory));
    work.* = .{};

    decode.readHeaders(file, work) catch |failure| return switch (failure) {
        decode.Error.Unsupported => datatypes.DTERROR_UNKNOWN_COMPRESSION,
        else => datatypes.DTERROR_INVALID_DATA,
    };

    // What it will take: the picture as pens, and a plane for each of
    // the parts it is made of beside it. The planes are the size the
    // file says whatever size the picture is kept at, so they are the
    // floor under how small it can usefully be.
    var planes_bytes: usize = 0;
    for (work.component[0..work.count]) |*component| {
        planes_bytes += @as(usize, decode.planeStride(work, component)) * decode.planeLines(work, component);
    }
    const by = subclass.shrinkFor(sys, work.width, work.height, planes_bytes);
    if (by == 0) return datatypes.DTERROR_TOO_LARGE;
    const kept_width = subclass.shrunk(work.width, by);
    const kept_height = subclass.shrunk(work.height, by);

    // A plane for each of the parts the picture is made of, whole units
    // across and down: the last unit of a row is unpacked whether or
    // not the picture reaches the end of it.
    var planes: [4]?*anyopaque = @splat(null);
    defer for (planes) |plane| sys.FreeVec(plane);
    for (work.component[0..work.count], 0..) |*component, i| {
        component.stride = decode.planeStride(work, component);
        component.lines = decode.planeLines(work, component);
        const memory = sys.AllocVec(component.stride * component.lines, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse
            return datatypes.DTERROR_NOT_ENOUGH_DATA;
        planes[i] = memory;
        component.plane = @ptrCast(memory);
    }

    decode.readScan(file, work) catch return datatypes.DTERROR_INVALID_DATA;

    const header = pic.BitMapHeader{
        .width = @intCast(kept_width),
        .height = @intCast(kept_height),
        .depth = @intCast(@min(work.count * 8, 32)),
        .masking = pic.mskNone,
        .x_aspect = 1,
        .y_aspect = 1,
        .page_width = @intCast(kept_width),
        .page_height = @intCast(kept_height),
    };
    subclass.setSource(ib, cl, o, work.width, work.height, by);
    if (!subclass.setPicture(ib, cl, o, &header, pic.PBPAFMT_RGB)) {
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    }

    const row_memory = sys.AllocVec(work.width * 4, exec.MEMF_ANY) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(row_memory);
    const colour: [*]u8 = @ptrCast(row_memory);

    var y: u32 = 0;
    while (y < kept_height) : (y += 1) {
        makeRow(work, y * by, colour);
        const count = subclass.thinRow(colour, work.width, by);
        subclass.putRow(ib, cl, o, 0, y, count, colour);
    }
    return 0;
}

/// Where a picture pixel falls in a plane kept at another size, in
/// 256ths of a sample: the first pixel is half a sample in, so that the
/// two sizes have the same middle. It may fall before the plane's first
/// sample, which is why it is signed.
fn placeIn(n: u32, part: u32, whole: u32) i32 {
    const step: i32 = @intCast(part * 256 / whole);
    const start: i32 = @intCast(part * 128 / whole);
    return start - 128 + @as(i32, @intCast(n)) * step;
}

/// How far apart two neighbouring picture pixels are in that plane.
fn stepIn(part: u32, whole: u32) i32 {
    return @intCast(part * 256 / whole);
}

/// Two numbers mixed, `part` 256ths of the second.
fn mix(first: u8, second: u8, part: u32) u8 {
    return @truncate((@as(u32, first) * (256 - part) + @as(u32, second) * part) >> 8);
}

/// One row of a plane, taken smoothly across and down.
///
/// A colour plane is usually kept at half the size of the picture, and
/// taking the nearest sample would draw its squares round every edge.
const Taken = struct {
    above: [*]const u8,
    below: [*]const u8,
    last: u32,
    down_part: u32,
    at: i32,
    step: i32,

    fn of(work: *const decode.Work, component: *const decode.Component, y: u32) Taken {
        const down_at = placeIn(y, component.down, work.max_down);
        const first: u32 = if (down_at < 0) 0 else @intCast(down_at >> 8);
        const above = @min(first, component.lines - 1);
        return .{
            .above = component.plane + above * component.stride,
            .below = component.plane + @min(above + 1, component.lines - 1) * component.stride,
            .last = component.stride - 1,
            .down_part = if (down_at < 0) 0 else @as(u32, @intCast(down_at)) & 0xFF,
            .at = placeIn(0, component.across, work.max_across),
            .step = stepIn(component.across, work.max_across),
        };
    }

    fn next(self: *Taken) u8 {
        const at = self.at;
        self.at += self.step;
        const left: u32 = if (at < 0) 0 else @min(@as(u32, @intCast(at >> 8)), self.last);
        const right = @min(left + 1, self.last);
        const part: u32 = if (at < 0) 0 else @as(u32, @intCast(at)) & 0xFF;
        return mix(
            mix(self.above[left], self.above[right], part),
            mix(self.below[left], self.below[right], part),
            self.down_part,
        );
    }
};

/// One row of the picture made out of the planes: red, green, blue and
/// full coverage.
fn makeRow(work: *const decode.Work, y: u32, into: [*]u8) void {
    var bright = Taken.of(work, &work.component[0], y);
    if (work.count < 3) {
        // Brightness alone: the same number three times over.
        var x: u32 = 0;
        while (x < work.width) : (x += 1) {
            const grey = bright.next();
            const at = into + x * 4;
            at[0] = grey;
            at[1] = grey;
            at[2] = grey;
            at[3] = 0xFF;
        }
        return;
    }
    var blue = Taken.of(work, &work.component[1], y);
    var red = Taken.of(work, &work.component[2], y);
    var x: u32 = 0;
    while (x < work.width) : (x += 1) {
        const at = into + x * 4;
        decode.toRGB(bright.next(), blue.next(), red.next(), at[0..3]);
        at[3] = 0xFF;
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
            const dos_lib = base.sys_base.OpenLibrary(dos.DOSNAME, 0) orelse {
                ib.DisposeObject(obj);
                return 0;
            };
            const dl: *DosBase = @ptrCast(dos_lib);
            defer base.sys_base.CloseLibrary(dos_lib);

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
            const new: *classusr.OpSet = @ptrCast(@alignCast(msg));
            const want = base.utility_base.GetTagData(jpegclass.JDTA_Decoder, jpegclass.JDEC_ANY, new.attr_list);
            const failure = readWith(base, cl, obj, bytes, want);
            base.sys_base.FreeVec(bytes.ptr);
            if (failure != 0) {
                _ = dl.SetIoErr(failure);
                ib.DisposeObject(obj);
                return 0;
            }
            return made;
        },
        classusr.OM_GET => {
            const get: *classusr.OpGet = @ptrCast(@alignCast(msg));
            if (get.attr_id != jpegclass.JDTA_Decoder) return ib.SendSuperMessage(cl, o, msg);
            get.storage.* = dataOf(cl, o.?).decoder;
            return 1;
        },
        else => return ib.SendSuperMessage(cl, o, msg),
    }
}
