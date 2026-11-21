// SPDX-License-Identifier: MIT
//! webp.datatype: a WebP file as a picture.
//!
//! A picture.datatype subclass. It reads the file in `OM_NEW` and hands
//! the rows to its superclass; everything after that is the
//! superclass's.
//!
//! **A lossy picture** is a VP8 key frame, decoded by the decoder
//! vp8.vcodec has (`vp8core`), built in: its brightness and colour
//! planes are kept while the rows are made from them one at a time, and
//! its coverage, when it has one, beside them a byte a pixel. **A
//! lossless picture** is unpacked whole, a word a pixel, before its rows
//! are handed over: its pixels may copy any that came before. **An
//! animation** is drawn as its first frame; webpanim.datatype plays it.
//!
//! A picture with coverage is handed over with it, and drawn mixed into
//! what is under it. One too large for memory is kept at a half, a
//! quarter or an eighth of its size, as the other picture classes keep
//! one; the decoder's own memory is the floor under how small that can
//! usefully be.

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
const pic = datatypes.pictureclass;
const decode = @import("decode.zig");
const memory = @import("memory.zig");
const DosBase = sdk.interface.dos.DosBase;
const Class = classes.Class;
const Object = classes.Object;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = "webp.datatype",
    .version = 1,
    .revision = 0,
    .date = "21.11.2026",
    .super = pic.PICTUREDTCLASS,
    .opens = &.{pic.PICTURE_LIBRARY},
    .Instance = Data,
    .dispatch = dispatch,
});
comptime {
    _ = Library;
}

/// webp.datatype's part of an object: nothing. The picture is the
/// superclass's the moment it has been read.
pub const Data = extern struct {
    unused: u32 = 0,
};

/// What went wrong in the decoder, as a datatype says it.
fn failureOf(failure: decode.Error) i32 {
    return switch (failure) {
        decode.Error.Unsupported => datatypes.DTERROR_UNKNOWN_COMPRESSION,
        decode.Error.NoMemory => datatypes.DTERROR_NOT_ENOUGH_DATA,
        decode.Error.Corrupt => datatypes.DTERROR_INVALID_DATA,
    };
}

/// A row of words, 0xAARRGGBB, as red, green, blue and coverage.
fn bytesOf(words: []const u32, into: [*]u8) void {
    for (words, 0..) |word, x| {
        const at = into + x * 4;
        at[0] = @truncate(word >> 16);
        at[1] = @truncate(word >> 8);
        at[2] = @truncate(word);
        at[3] = @truncate(word >> 24);
    }
}

/// The file read and its pixels given to the superclass. What went
/// wrong, or 0.
fn readFile(base: *Base, cl: *Class, o: *Object, file: []const u8) i32 {
    const sys = base.sys_base;
    const ib = base.intuition_base;
    const env = memory.envOf(sys);
    const info = decode.readInfo(file) catch |failure| return failureOf(failure);
    const pixel_count = @as(usize, info.width) * info.height;

    // The picture, or the animation's first frame and its place.
    var frame: ?decode.Frame = null;
    const image = if (info.image) |still| still else first: {
        frame = (decode.readFrame(file, &info, info.frames_at) catch |failure| return failureOf(failure)) orelse
            return datatypes.DTERROR_NOT_ENOUGH_DATA;
        break :first frame.?.image;
    };

    // What it takes besides the picture: the pixels as words, or a lossy
    // picture's planes in whole macroblocks and its coverage.
    const working: usize = if (frame) |first|
        pixel_count * 4 + @as(usize, first.width) * first.height * 4
    else if (image.lossless)
        pixel_count * 4
    else
        @as(usize, (info.width + 15) & ~@as(u32, 15)) * ((info.height + 15) & ~@as(u32, 15)) * 3 / 2 +
            (if (image.alpha != null) pixel_count else 0);
    const by = subclass.shrinkFor(sys, info.width, info.height, working);
    if (by == 0) return datatypes.DTERROR_TOO_LARGE;
    const kept_width = subclass.shrunk(info.width, by);
    const kept_height = subclass.shrunk(info.height, by);

    const header = pic.BitMapHeader{
        .width = @intCast(kept_width),
        .height = @intCast(kept_height),
        .depth = if (info.alpha) 32 else 24,
        .masking = if (info.alpha) pic.mskHasAlpha else pic.mskNone,
        .x_aspect = 1,
        .y_aspect = 1,
        .page_width = @intCast(kept_width),
        .page_height = @intCast(kept_height),
    };
    subclass.setSource(ib, cl, o, info.width, info.height, by);
    if (!subclass.setPicture(ib, cl, o, &header, if (info.alpha) pic.PBPAFMT_RGBA else pic.PBPAFMT_RGB)) {
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    }
    const row_memory = sys.AllocVec(info.width * 4, exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(row_memory);
    const colour: [*]u8 = @ptrCast(row_memory);

    if (frame != null or image.lossless) {
        const words = env.slice(u32, pixel_count) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
        defer env.freeSlice(u32, words);
        if (frame) |first| {
            const frame_words = env.slice(u32, @as(usize, first.width) * first.height) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
            defer env.freeSlice(u32, frame_words);
            decode.decodeImage(env, first.image, first.width, first.height, frame_words) catch |failure| return failureOf(failure);
            var canvas = decode.Canvas{ .pixels = words, .width = info.width, .height = info.height };
            canvas.add(&first, frame_words);
        } else {
            decode.decodeImage(env, image, info.width, info.height, words) catch |failure| return failureOf(failure);
        }
        var y: u32 = 0;
        while (y < kept_height) : (y += 1) {
            bytesOf(words[@as(usize, y * by) * info.width ..][0..info.width], colour);
            const count = subclass.thinRow(colour, info.width, by);
            subclass.putRow(ib, cl, o, 0, y, count, colour);
        }
        return 0;
    }

    var picture = decode.Lossy.decode(env, image.data) catch |failure| return failureOf(failure);
    defer picture.deinit();
    if (picture.width != info.width or picture.height != info.height) return datatypes.DTERROR_INVALID_DATA;
    var coverage: []u8 = &.{};
    defer env.freeSlice(u8, coverage);
    if (image.alpha) |chunk| {
        coverage = env.slice(u8, pixel_count) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
        // A broken coverage leaves the picture opaque, as it would be
        // without one.
        decode.alphaOf(env, chunk, info.width, info.height, coverage) catch @memset(coverage, 0xFF);
    }
    var y: u32 = 0;
    while (y < kept_height) : (y += 1) {
        const source_row = y * by;
        decode.Lossy.row(&picture, source_row, colour);
        if (coverage.len != 0) {
            for (coverage[@as(usize, source_row) * info.width ..][0..info.width], 0..) |value, x| colour[x * 4 + 3] = value;
        }
        const count = subclass.thinRow(colour, info.width, by);
        subclass.putRow(ib, cl, o, 0, y, count, colour);
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
            const dos_lib = base.sys_base.OpenLibrary(dos.DOSNAME, 0) orelse {
                ib.DisposeObject(obj);
                return 0;
            };
            const dl: *DosBase = @ptrCast(dos_lib);
            defer base.sys_base.CloseLibrary(dos_lib);

            const bytes = switch (subclass.readSource(base.sys_base, dl, ib, cl, obj)) {
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
            const failure = readFile(base, cl, obj, bytes);
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
