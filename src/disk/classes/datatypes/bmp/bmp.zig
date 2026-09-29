// SPDX-License-Identifier: MIT
//! bmp.datatype: a Windows bitmap as a picture.
//!
//! A picture.datatype subclass. It reads the file in `OM_NEW` - what the
//! picture is, its palette and its rows - and hands the pixels to its
//! superclass; everything after that is the superclass's.
//!
//! One, four or eight bits into a palette, sixteen or thirty-two bits in
//! channels the file itself places, and twenty-four bits of blue, green
//! and red. Palette rows may be packed as runs, which is the only
//! compression the format ever had.
//!
//! **The rows are written from the bottom up** unless the file says its
//! height the other way round, so what is read first is the last row of
//! the picture.

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
const DosBase = sdk.interface.dos.DosBase;
const Class = classes.Class;
const Object = classes.Object;
const Base = gadgets.Base;

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = gadgets.ClassLibrary(.{
    .name = "bmp.datatype",
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

/// bmp.datatype's part of an object: nothing. The picture is the
/// superclass's the moment it has been read.
pub const Data = extern struct {
    unused: u32 = 0,
};

/// The file read and its pixels given to the superclass. What went
/// wrong, or 0.
fn readFile(base: *Base, cl: *Class, o: *Object, file: []const u8) i32 {
    const sys = base.sys_base;
    const ib = base.intuition_base;
    const info = decode.readInfo(file) catch |failure| return switch (failure) {
        decode.Error.Unsupported => datatypes.DTERROR_UNKNOWN_COMPRESSION,
        else => datatypes.DTERROR_INVALID_DATA,
    };

    const wanted = subclass.pictureBytes(info.width, info.height);
    if (wanted == ~@as(usize, 0) or !subclass.roomFor(sys, wanted)) {
        return datatypes.DTERROR_TOO_LARGE;
    }

    const header = pic.BitMapHeader{
        .width = @intCast(info.width),
        .height = @intCast(info.height),
        .depth = @intCast(info.bits),
        .masking = if (info.alpha.bits != 0) pic.mskHasAlpha else pic.mskNone,
        .x_aspect = 1,
        .y_aspect = 1,
        .page_width = @intCast(info.width),
        .page_height = @intCast(info.height),
    };
    const alpha = info.alpha.bits != 0;
    if (!subclass.setPicture(ib, cl, o, &header, if (alpha) pic.PBPAFMT_RGBA else pic.PBPAFMT_RGB)) {
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    }

    const colour_memory = sys.AllocVec(info.width * 4, exec.MEMF_ANY) orelse
        return datatypes.DTERROR_NOT_ENOUGH_DATA;
    defer sys.FreeVec(colour_memory);
    const colour: [*]u8 = @ptrCast(colour_memory);

    // Packed rows are not rows until they have been unpacked, so they
    // are unpacked whole and then read like any other palette picture.
    var unpacked_memory: ?*anyopaque = null;
    defer sys.FreeVec(unpacked_memory);
    var rows: []const u8 = file[info.pixels_at..];
    var stride = info.rowBytes();
    var plain = info;
    if (info.compression == decode.BI_RLE8 or info.compression == decode.BI_RLE4) {
        const count = info.width * info.height;
        unpacked_memory = sys.AllocVec(count, exec.MEMF_ANY) orelse
            return datatypes.DTERROR_NOT_ENOUGH_DATA;
        const into: [*]u8 = @ptrCast(unpacked_memory);
        _ = decode.unpackRuns(file, info, into[0..count]);
        rows = into[0..count];
        stride = info.width;
        plain.bits = 8;
        plain.compression = decode.BI_RGB;
        // The unpacked rows are already the picture's own way up.
        plain.top_down = true;
    }

    var y: u32 = 0;
    while (y < info.height) : (y += 1) {
        // The file's first row is the picture's last, unless it says
        // otherwise.
        const which = if (plain.top_down) y else info.height - 1 - y;
        const at = @as(usize, which) * stride;
        if (at + stride > rows.len) break;
        decode.expandRow(file, plain, rows[at..][0..stride], colour[0 .. info.width * 4]);
        subclass.putRow(ib, cl, o, 0, y, info.width, colour);
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
