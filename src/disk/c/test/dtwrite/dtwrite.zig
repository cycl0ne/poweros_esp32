// SPDX-License-Identifier: MIT
//! DTWrite: a picture made by a program, saved through datatypes and read
//! back. Built against the SDK only.
//!
//!   DTWrite DIR/K
//!
//! A picture of 61 by 37 pixels is drawn in memory - a ramp of colour
//! across, coverage falling from top to bottom - and put into two empty
//! objects (`NewDTObjectA` with `DTST_RAM`): one of the picture group's
//! own class, written out as an IFF ILBM (`DTM_WRITE` with `DTWM_IFF`),
//! and one of png.datatype, written out as a PNG (`DTWM_RAW`). Both files
//! go into DIR (`RAM:` unless given), are opened again as any picture is,
//! and their pixels are compared with the ones drawn: each line says how
//! many pixels came back the same and how big the file is. A group with
//! no class of its own and an empty object with neither a group nor a
//! class are asked for too, and must be refused.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "DTWrite";
const VERSION_STRING = "\x00$VER: DTWrite 1.0 (19.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DIR/K";

const width = 61;
const height = 37;
const row_bytes = width * 4;
const picture_bytes = row_bytes * height;

const MSG_NOLIBRARY = "%s: cannot open %s\n";
const MSG_NOEMPTY = "%s: no empty %s object (error %ld)\n";
const MSG_NOWRITE = "%s: %s not written (error %ld)\n";
const MSG_NOREAD = "%s: %s not read back (error %ld)\n";
const MSG_RESULT = "%-6s %s: %ld bytes, %ld of %ld pixels the same, size %ldx%ld\n";
const MSG_REFUSED = "refused as it should be: %s (error %ld)\n";
const MSG_NOTREFUSED = "NOT refused: %s\n";

/// The picture drawn: red across, green down, blue fixed, and coverage
/// falling from the top - the last rows half and wholly see-through.
fn drawn(x: u32, y: u32) u32 {
    const red: u32 = x * 255 / (width - 1);
    const green: u32 = y * 255 / (height - 1);
    const alpha: u32 = 255 - y * 255 / (height - 1);
    return alpha << 24 | red << 16 | green << 8 | 0x40;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const dir: [*:0]const u8 = dos.rdargs.string(argv[0]) orelse "RAM:";

    const intuition_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(intuition_lib);
    const ib: *IntuitionBase = @ptrCast(intuition_lib);
    const datatypes_lib = sys.OpenLibrary(datatypes.DATATYPESNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, datatypes.DATATYPESNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(datatypes_lib);
    const dt: *DataTypesBase = @ptrCast(datatypes_lib);

    // The picture drawn, as rows of alpha, red, green and blue, and room
    // for the same read back.
    const memory = sys.AllocVec(2 * picture_bytes, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const rows: [*]u8 = @ptrCast(memory);
    const back = rows + picture_bytes;
    for (0..height) |y| {
        for (0..width) |x| {
            const pixel = drawn(@intCast(x), @intCast(y));
            rows[y * row_bytes + x * 4 ..][0..4].* = .{ @truncate(pixel >> 24), @truncate(pixel >> 16), @truncate(pixel >> 8), @truncate(pixel) };
        }
    }

    var failed = false;
    failed = !saveAndRead(dl, ib, dt, dir, "IFF", null, dtc.DTWM_IFF, "dtwrite.iff", rows, back) or failed;
    failed = !saveAndRead(dl, ib, dt, dir, "PNG", "png", dtc.DTWM_RAW, "dtwrite.png", rows, back) or failed;

    // What must be refused.
    const none = dt.NewDTObjectA(null, &.{
        .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_RAM },
        .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_SYSTEM },
        .{},
    });
    if (none) |made| {
        dt.DisposeDTObject(made);
        _ = Printf(dl, MSG_NOTREFUSED, .{"the system group"});
        failed = true;
    } else _ = Printf(dl, MSG_REFUSED, .{ "the system group", @as(i64, dl.IoErr()) });
    const bare = dt.NewDTObjectA(null, &.{
        .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_RAM },
        .{},
    });
    if (bare) |made| {
        dt.DisposeDTObject(made);
        _ = Printf(dl, MSG_NOTREFUSED, .{"no group and no class"});
        failed = true;
    } else _ = Printf(dl, MSG_REFUSED, .{ "no group and no class", @as(i64, dl.IoErr()) });
    return if (failed) dos.RETURN_ERROR else dos.RETURN_OK;
}

/// The picture into an empty object - of the class `base_name` names, or
/// the picture group's own - written as `mode` to `file` in `dir`, read
/// back and compared. True when every pixel came back.
fn saveAndRead(dl: *DosBase, ib: *IntuitionBase, dt: *DataTypesBase, dir: [*:0]const u8, label: [*:0]const u8, base_name: ?[*:0]const u8, mode: u32, file_name: [*:0]const u8, rows: [*]u8, back: [*]u8) bool {
    var path: [128]u8 = @splat(0);
    var at: usize = 0;
    while (dir[at] != 0 and at < path.len - 1) : (at += 1) path[at] = dir[at];
    if (!dl.AddPart(@ptrCast(&path), file_name, path.len)) return false;
    const name: [*:0]const u8 = @ptrCast(&path);

    const picture = dt.NewDTObjectA(null, &.{
        .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_RAM },
        .{ .tag = if (base_name != null) dtc.DTA_BaseName else sdk.utility.TAG_IGNORE, .data = @intFromPtr(base_name) },
        .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOEMPTY, .{ COMMAND_NAME, label, @as(i64, dl.IoErr()) });
        return false;
    };
    defer dt.DisposeDTObject(picture);
    const header = pic.BitMapHeader{
        .width = width,
        .height = height,
        .depth = 32,
        .masking = pic.mskHasAlpha,
        .x_aspect = 1,
        .y_aspect = 1,
        .page_width = width,
        .page_height = height,
    };
    _ = dt.SetDTAttrsA(picture, null, null, &.{
        .{ .tag = pic.PDTA_SourceMode, .data = pic.PBPAFMT_ARGB },
        .{ .tag = pic.PDTA_BitMapHeader, .data = @intFromPtr(&header) },
        .{},
    });
    var put = pic.PdtBlitPixelArray{
        .pixel_data = rows,
        .format = pic.PBPAFMT_ARGB,
        .bytes_per_row = row_bytes,
        .width = width,
        .height = height,
    };
    if (ib.SendMessage(picture, @ptrCast(&put)) == 0) {
        _ = Printf(dl, MSG_NOWRITE, .{ COMMAND_NAME, label, @as(i64, 0) });
        return false;
    }

    const file = dl.Open(name, dos.MODE_NEWFILE) orelse {
        _ = Printf(dl, MSG_NOWRITE, .{ COMMAND_NAME, name, @as(i64, dl.IoErr()) });
        return false;
    };
    var out = dtc.DtWrite{ .file = file, .mode = mode };
    const written = dt.DoDTMethodA(picture, null, null, @ptrCast(&out)) != 0;
    const failure = dl.IoErr();
    const size = dl.Seek(file, 0, dos.OFFSET_CURRENT);
    _ = dl.Close(file);
    if (!written) {
        _ = Printf(dl, MSG_NOWRITE, .{ COMMAND_NAME, name, @as(i64, failure) });
        return false;
    }

    const again = dt.NewDTObjectA(name, &.{
        .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOREAD, .{ COMMAND_NAME, name, @as(i64, dl.IoErr()) });
        return false;
    };
    defer dt.DisposeDTObject(again);
    var header_at: usize = 0;
    _ = dt.GetDTAttrsA(again, &.{ .{ .tag = pic.PDTA_BitMapHeader, .data = @intFromPtr(&header_at) }, .{} });
    const read_header: *const pic.BitMapHeader = @ptrFromInt(header_at);
    @memset(back[0..picture_bytes], 0);
    var get = pic.PdtBlitPixelArray{
        .method_id = pic.PDTM_READPIXELARRAY,
        .pixel_data = back,
        .format = pic.PBPAFMT_ARGB,
        .bytes_per_row = row_bytes,
        .width = width,
        .height = height,
    };
    _ = ib.SendMessage(again, @ptrCast(&get));
    var same: i64 = 0;
    for (0..width * height) |i| {
        const read: u32 = @bitCast(back[i * 4 ..][0..4].*);
        const drawn_pixel: u32 = @bitCast(rows[i * 4 ..][0..4].*);
        if (read == drawn_pixel) same += 1;
    }
    _ = Printf(dl, MSG_RESULT, .{ label, name, size, same, @as(i64, width * height), @as(i64, read_header.width), @as(i64, read_header.height) });
    return same == width * height and read_header.width == width and read_header.height == height;
}
