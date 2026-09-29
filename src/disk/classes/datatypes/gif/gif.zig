// SPDX-License-Identifier: MIT
//! gif.datatype: a GIF file as a picture.
//!
//! A picture.datatype subclass. It reads the file in `OM_NEW` - the
//! screen the pictures sit on, the palette, the compressed pixels of the
//! first picture - and hands the rows to its superclass; everything
//! after that is the superclass's.
//!
//! **What is shown is the screen the file names, not the first picture.**
//! A file whose picture is smaller than that screen is meant to be seen
//! with that much room round it. What no picture covers is the
//! background colour the file names, or nothing at all where the file
//! says one of its colours stands for nothing.
//!
//! A file holding an animation is read as far as its first picture and
//! no further: what an animation is belongs to animation.datatype, and
//! a still of the first frame is the useful thing to have until there
//! is one.

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
const lzw = @import("lzw.zig");
const decode = @import("decode.zig");
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DosBase = sdk.interface.dos.DosBase;
const Class = classes.Class;
const Object = classes.Object;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = "gif.datatype",
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

/// gif.datatype's part of an object: nothing. The picture is the
/// superclass's the moment it has been read.
pub const Data = extern struct {
    unused: u32 = 0,
};

/// A colour of a palette as red, green, blue and coverage.
fn colourOf(palette: []const u8, index: u8, transparent: ?u8) [4]u8 {
    if (transparent) |nothing| {
        if (index == nothing) return .{ 0, 0, 0, 0 };
    }
    const at = @as(usize, index) * 3;
    if (at + 3 > palette.len) return .{ 0, 0, 0, 0xFF };
    return .{ palette[at], palette[at + 1], palette[at + 2], 0xFF };
}

/// The file read and its pixels given to the superclass. What went
/// wrong, or 0.
fn readFile(base: *Base, cl: *Class, o: *Object, file: []const u8) i32 {
    const sys = base.sys_base;
    const ib = base.intuition_base;
    const screen = decode.readScreen(file) catch return datatypes.DTERROR_INVALID_DATA;
    const picture = (decode.readFirst(file, screen) catch
        return datatypes.DTERROR_INVALID_DATA) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;

    const wanted = subclass.pictureBytes(screen.width, screen.height);
    if (wanted == ~@as(usize, 0) or !subclass.roomFor(sys, wanted)) {
        return datatypes.DTERROR_TOO_LARGE;
    }

    // The picture is the screen, with the one frame placed on it.
    const header = pic.BitMapHeader{
        .width = @intCast(screen.width),
        .height = @intCast(screen.height),
        .depth = 8,
        .masking = if (picture.transparent != null) pic.mskHasAlpha else pic.mskNone,
        .transparent = if (picture.transparent) |index| index else 0,
        .x_aspect = 1,
        .y_aspect = 1,
        .page_width = @intCast(screen.width),
        .page_height = @intCast(screen.height),
    };
    const alpha = picture.transparent != null;
    if (!subclass.setPicture(ib, cl, o, &header, if (alpha) pic.PBPAFMT_RGBA else pic.PBPAFMT_LUT8)) {
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    }

    const row_memory = sys.AllocVec(screen.width * 4, exec.MEMF_ANY) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(row_memory);
    const colour: [*]u8 = @ptrCast(row_memory);

    // What no picture covers: nothing where the file names a colour
    // that stands for nothing, and the background colour otherwise.
    fillGround(ib, cl, o, screen, picture, colour);

    const compressed_length = decode.blockBytes(file, picture.data_at) catch
        return datatypes.DTERROR_INVALID_DATA;
    if (compressed_length == 0) return datatypes.DTERROR_NOT_ENOUGH_DATA;
    const compressed_memory = sys.AllocVec(compressed_length, exec.MEMF_ANY) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(compressed_memory);
    const compressed: [*]u8 = @ptrCast(compressed_memory);
    const got = decode.gatherBlocks(file, picture.data_at, compressed[0..compressed_length]);

    const pixel_count = picture.width * picture.height;
    const pixel_memory = sys.AllocVec(pixel_count, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(pixel_memory);
    const pixels: [*]u8 = @ptrCast(pixel_memory);

    const work_memory = sys.AllocVec(@sizeOf(lzw.Work), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(work_memory);
    const work: *lzw.Work = @ptrCast(@alignCast(work_memory));
    work.* = .{};

    // A stream that ends early leaves the rows it did write: half a
    // picture is worth more than none, and the file says as much.
    const written = lzw.decode(work, picture.min_code_size, compressed[0..got], pixels[0..pixel_count]) catch |failure|
        switch (failure) {
            lzw.Error.Corrupt => return datatypes.DTERROR_INVALID_DATA,
            else => pixel_count,
        };
    const rows_read = written / picture.width;

    var n: u32 = 0;
    while (n < rows_read) : (n += 1) {
        const row = pixels + n * picture.width;
        var x: u32 = 0;
        while (x < picture.width) : (x += 1) {
            const colours = colourOf(picture.palette, row[x], picture.transparent);
            @memcpy((colour + x * 4)[0..4], &colours);
        }
        subclass.putRow(ib, cl, o, picture.left, picture.top + decode.rowOf(picture, n), picture.width, colour);
    }
    return 0;
}

/// The screen filled in before the picture is placed on it.
fn fillGround(ib: *IntuitionBase, cl: *Class, o: *Object, screen: decode.Screen, picture: decode.Picture, colour: [*]u8) void {
    // Where the picture covers the whole screen there is nothing to
    // fill, and a file that names a colour standing for nothing is
    // already clear: the picture's memory came zeroed.
    if (picture.transparent != null) return;
    if (picture.left == 0 and picture.top == 0 and
        picture.width >= screen.width and picture.height >= screen.height) return;
    const ground = colourOf(screen.palette, screen.background, null);
    var x: u32 = 0;
    while (x < screen.width) : (x += 1) @memcpy((colour + x * 4)[0..4], &ground);
    var y: u32 = 0;
    while (y < screen.height) : (y += 1) subclass.putRow(ib, cl, o, 0, y, screen.width, colour);
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
