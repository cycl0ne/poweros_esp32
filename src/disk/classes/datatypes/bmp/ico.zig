// SPDX-License-Identifier: MIT
//! ico.datatype: a Windows icon as a picture - the favicon a web site
//! names, among them.
//!
//! A picture.datatype subclass. It reads the file in `OM_NEW`, picks the
//! largest of the pictures its directory holds (icon.zig) - the deepest
//! of the largest - and hands that one's pixels to its superclass;
//! everything after that is the superclass's.
//!
//! **A bitmap** is read as bmp.datatype reads its rows (decode.zig) - one,
//! four or eight bits into a palette, twenty-four bits of colour, or
//! thirty-two with coverage - and its mask makes the pixels it marks
//! clear, unless the picture's own coverage says it. **A PNG** in it is
//! made a picture of its own from memory, png.datatype's, whose rows are
//! taken back (`PDTM_READPIXELARRAY`) and handed over as they are.
//!
//! **Its one call**, after the standard four, is the recognise function
//! datatypes.library asks: the four bytes an icon file starts with are
//! few, and a directory that makes sense is what tells one.

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
const decode = @import("decode.zig");
const icon = @import("icon.zig");
const DosBase = sdk.interface.dos.DosBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const Class = classes.Class;
const Object = classes.Object;
const TagItem = utility.TagItem;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
/// datatypes.library to make a PNG in it a picture with.
pub const Library = gadgets.ClassLibrary(.{
    .name = "ico.datatype",
    .version = 1,
    .revision = 0,
    .date = "29.10.2026",
    .super = pic.PICTUREDTCLASS,
    .opens = &.{ pic.PICTURE_LIBRARY, datatypes.DATATYPESNAME },
    .Instance = Data,
    .dispatch = dispatch,
    .functions = &.{exec.libraries.vec(recognise)},
});
comptime {
    _ = Library;
}

const opened_datatypes = 1;

/// ico.datatype's part of an object: nothing. The picture is the
/// superclass's the moment it has been read.
pub const Data = extern struct {
    unused: u32 = 0,
};

fn datatypesOf(base: *Base) *DataTypesBase {
    return @ptrCast(base.opened[opened_datatypes].?);
}

/// The file read and its chosen picture's pixels given to the
/// superclass. What went wrong, or 0.
fn readFile(base: *Base, cl: *Class, o: *Object, file: []const u8) i32 {
    const pictures = icon.count(file) catch return datatypes.DTERROR_INVALID_DATA;
    const chosen = icon.pick(file, pictures) catch return datatypes.DTERROR_INVALID_DATA;
    const image = file[chosen.at..][0..chosen.length];
    if (icon.isPng(image)) return readPng(base, cl, o, image);
    return readBitmap(base, cl, o, image);
}

/// A bitmap picture: its rows in colour, its mask - or its own coverage -
/// saying which pixels are clear.
fn readBitmap(base: *Base, cl: *Class, o: *Object, image: []const u8) i32 {
    const sys = base.sys_base;
    const ib = base.intuition_base;
    const bitmap = icon.readBitmap(image) catch |failure| return switch (failure) {
        icon.Error.Unsupported => datatypes.DTERROR_UNKNOWN_COMPRESSION,
        else => datatypes.DTERROR_INVALID_DATA,
    };
    const info = bitmap.info;
    const by = subclass.shrinkFor(sys, info.width, info.height, 0);
    if (by == 0) return datatypes.DTERROR_TOO_LARGE;
    const kept_width = subclass.shrunk(info.width, by);
    const kept_height = subclass.shrunk(info.height, by);
    const header = pic.BitMapHeader{
        .width = @intCast(kept_width),
        .height = @intCast(kept_height),
        .depth = @intCast(info.bits),
        .masking = pic.mskHasAlpha,
        .x_aspect = 1,
        .y_aspect = 1,
        .page_width = @intCast(kept_width),
        .page_height = @intCast(kept_height),
    };
    subclass.setSource(ib, cl, o, info.width, info.height, by);
    if (!subclass.setPicture(ib, cl, o, &header, pic.PBPAFMT_RGBA)) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    const colour_memory = sys.AllocVec(info.width * 4, exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(colour_memory);
    const colour: [*]u8 = @ptrCast(colour_memory);
    const stride = info.rowBytes();
    var y: u32 = 0;
    while (y < kept_height) : (y += 1) {
        // The file's first row is the picture's last.
        const row = info.height - 1 - y * by;
        const at = info.pixels_at + @as(usize, row) * stride;
        decode.expandRow(image, info, image[at..][0..stride], colour[0 .. info.width * 4]);
        if (!bitmap.alpha) {
            var x: u32 = 0;
            while (x < info.width) : (x += 1) {
                if (icon.clearAt(image, bitmap, x, row)) colour[x * 4 + 3] = 0;
            }
        }
        const count = subclass.thinRow(colour, info.width, by);
        subclass.putRow(ib, cl, o, 0, y, count, colour);
    }
    return 0;
}

/// A PNG picture: made a picture of its own from memory, and its rows
/// taken over - its size and how much it was kept smaller with them.
fn readPng(base: *Base, cl: *Class, o: *Object, image: []const u8) i32 {
    const sys = base.sys_base;
    const ib = base.intuition_base;
    const dt = datatypesOf(base);
    const png = dt.NewDTObjectA(null, &[_]TagItem{
        .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_MEMORY },
        .{ .tag = dtc.DTA_Handle, .data = @intFromPtr(image.ptr) },
        .{ .tag = dtc.DTA_SourceSize, .data = image.len },
        .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
        .{},
    }) orelse return datatypes.DTERROR_INVALID_DATA;
    defer dt.DisposeDTObject(png);

    var shape: usize = 0;
    var source_width: usize = 0;
    var source_height: usize = 0;
    var by: usize = 1;
    _ = dt.GetDTAttrsA(png, &[_]TagItem{
        .{ .tag = pic.PDTA_BitMapHeader, .data = @intFromPtr(&shape) },
        .{ .tag = pic.PDTA_SourceWidth, .data = @intFromPtr(&source_width) },
        .{ .tag = pic.PDTA_SourceHeight, .data = @intFromPtr(&source_height) },
        .{ .tag = pic.PDTA_ShrunkBy, .data = @intFromPtr(&by) },
        .{},
    });
    if (shape == 0) return datatypes.DTERROR_INVALID_DATA;
    const theirs: *const pic.BitMapHeader = @ptrFromInt(shape);
    const width: u32 = theirs.width;
    const height: u32 = theirs.height;
    if (width == 0 or height == 0) return datatypes.DTERROR_INVALID_DATA;
    var header = theirs.*;
    header.masking = pic.mskHasAlpha;
    subclass.setSource(ib, cl, o, @intCast(source_width), @intCast(source_height), @intCast(@max(by, 1)));
    if (!subclass.setPicture(ib, cl, o, &header, pic.PBPAFMT_RGBA)) return datatypes.DTERROR_NOT_ENOUGH_DATA;

    const row_memory = sys.AllocVec(width * 4, exec.MEMF_ANY) orelse return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(row_memory);
    const row: [*]u8 = @ptrCast(row_memory);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var read = pic.PdtBlitPixelArray{
            .method_id = pic.PDTM_READPIXELARRAY,
            .pixel_data = row,
            .format = pic.PBPAFMT_RGBA,
            .bytes_per_row = width * 4,
            .top = y,
            .width = width,
            .height = 1,
        };
        // A method of the object itself, with no window: its second
        // field is the rows, not a GadgetInfo.
        if (ib.SendMessage(png, @ptrCast(&read)) == 0) return datatypes.DTERROR_INVALID_DATA;
        subclass.putRow(ib, cl, o, 0, y, width, row);
    }
    return 0;
}

/// datatypes.library's question: whether what starts as an icon file
/// does is one - a directory of a sensible size whose first picture lies
/// past it.
fn recognise(base: *Base, context: *datatypes.DTHookContext) callconv(.c) bool {
    _ = base;
    const buffer = context.buffer orelse return false;
    const bytes = buffer[0..context.buffer_length];
    if (bytes.len < 6 + 16) return false;
    const pictures = icon.count(bytes) catch |failure| switch (failure) {
        // A directory longer than what was read is looked at as far as
        // its first entry.
        icon.Error.Corrupt => @as(u32, @intCast(bytes[4] | @as(u32, bytes[5]) << 8)),
        else => return false,
    };
    if (pictures > 256) return false;
    const first = icon.entryAt(bytes, 0);
    if (bytes[6 + 3] != 0) return false;
    switch (first.bits) {
        0, 1, 4, 8, 16, 24, 32 => {},
        else => return false,
    }
    return first.length != 0 and first.at >= 6 + 16 * pictures;
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
