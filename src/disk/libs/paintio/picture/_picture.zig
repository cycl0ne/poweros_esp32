// SPDX-License-Identifier: MIT
//! A picture read through datatypes, as a project of one layer, and the
//! libraries a picture call works with.
//!
//! datatypes makes the picture object from the file, whatever its format;
//! its size is the object's `BitMapHeader`, and its pixels come out with
//! `PDTM_READPIXELARRAY` as alpha, red, green and blue bytes straight
//! into the layer's memory, which are made pixels where they lie. A
//! palette the file had comes with it.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const intuition = sdk.intuition;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const paintio = sdk.paintio;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const PaintIOBase = @import("../paintio_base.zig").PaintIOBase;
const _project = @import("../project/_project.zig");

/// datatypes.library and intuition.library, open for one call.
pub const Libraries = struct {
    dt: *DataTypesBase,
    ib: *IntuitionBase,

    /// Both opened, or null when either cannot be.
    pub fn open(base: *PaintIOBase) ?Libraries {
        const sys = base.sys_base;
        const dt_lib = sys.OpenLibrary(datatypes.DATATYPESNAME, 0) orelse return null;
        const ib_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse {
            sys.CloseLibrary(dt_lib);
            return null;
        };
        return .{ .dt = @ptrCast(dt_lib), .ib = @ptrCast(ib_lib) };
    }

    pub fn close(libraries: Libraries, base: *PaintIOBase) void {
        base.sys_base.CloseLibrary(libraries.ib.lib());
        base.sys_base.CloseLibrary(libraries.dt.lib());
    }
};

/// datatypes' reason a picture could not be made, as a dos code: dos's
/// own reasons as they are, datatypes' own (from `DTERROR_UNKNOWN_DATATYPE`
/// up) as a file of the wrong type.
pub fn dosError(code: i32) i32 {
    if (code == 0 or code >= datatypes.DTERROR_UNKNOWN_DATATYPE) return dos.ERROR_OBJECT_WRONG_TYPE;
    return code;
}

/// The picture `name` into `project`: 0, or why not. The project's
/// memory is in it as far as it got, for the caller to free.
pub fn load(base: *PaintIOBase, name: [*:0]const u8, project: *paintio.Project) i32 {
    const sys = base.sys_base;
    const dl = base.dos_base;
    const libraries = Libraries.open(base) orelse return dos.ERROR_INVALID_RESIDENT_LIBRARY;
    defer libraries.close(base);
    const dt = libraries.dt;

    const object = dt.NewDTObjectA(name, &.{
        .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
        .{},
    }) orelse return dosError(dl.IoErr());
    defer dt.DisposeDTObject(object);

    var header_at: usize = 0;
    var colours_at: usize = 0;
    var colour_count: usize = 0;
    _ = dt.GetDTAttrsA(object, &.{
        .{ .tag = pic.PDTA_BitMapHeader, .data = @intFromPtr(&header_at) },
        .{ .tag = pic.PDTA_ColorRegisters, .data = @intFromPtr(&colours_at) },
        .{ .tag = pic.PDTA_NumColors, .data = @intFromPtr(&colour_count) },
        .{},
    });
    if (header_at == 0) return dos.ERROR_OBJECT_WRONG_TYPE;
    const header: *const pic.BitMapHeader = @ptrFromInt(header_at);
    const width: u32 = header.width;
    const height: u32 = header.height;
    if (width == 0 or height == 0) return dos.ERROR_OBJECT_WRONG_TYPE;
    if (width > paintio.MAX_SIDE or height > paintio.MAX_SIDE) return dos.ERROR_OBJECT_TOO_LARGE;

    const layer_memory = sys.AllocVec(@sizeOf(paintio.Layer), exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
    const layers: [*]paintio.Layer = @ptrCast(@alignCast(layer_memory));
    layers[0] = .{};
    project.layers = layers;
    project.layer_count = 1;
    project.width = width;
    project.height = height;
    project.kind = paintio.PIOKIND_PICTURE;

    const count = @as(usize, width) * height;
    const memory = sys.AllocVec(count * 4, exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
    const pixels: [*]u32 = @ptrCast(@alignCast(memory));
    layers[0].pixels = pixels;
    var rows = pic.PdtBlitPixelArray{
        .method_id = pic.PDTM_READPIXELARRAY,
        .pixel_data = @ptrCast(pixels),
        .format = pic.PBPAFMT_ARGB,
        .bytes_per_row = width * 4,
        .width = width,
        .height = height,
    };
    if (libraries.ib.SendMessage(object, @ptrCast(&rows)) == 0) return dos.ERROR_OBJECT_WRONG_TYPE;
    _project.fromFile(pixels[0..count]);

    if (colours_at != 0) {
        const colours: [*]const pic.ColorRegister = @ptrFromInt(colours_at);
        const kept = @min(colour_count, paintio.MAX_PALETTE);
        for (colours[0..kept], project.palette[0..kept]) |colour, *into| {
            into.* = 0xFF00_0000 | @as(u32, colour.red) << 16 | @as(u32, colour.green) << 8 | colour.blue;
        }
        project.palette_count = @intCast(kept);
    }
    return 0;
}
