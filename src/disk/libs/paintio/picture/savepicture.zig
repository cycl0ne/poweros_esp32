// SPDX-License-Identifier: MIT
//! SavePicture: pixels written as a PNG or an ILBM, through datatypes.
//!
//! An empty picture object is made (`DTST_RAM`) - of png.datatype for a
//! PNG, of the picture group's own class for an ILBM - and told the
//! picture's size and whether it has coverage. The rows go into it one
//! at a time, turned into alpha, red, green and blue bytes in a row's
//! worth of memory, and the object then writes itself to the file:
//! `DTM_WRITE` with `DTWM_RAW` for its own format, `DTWM_IFF` for ILBM.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const paintio = sdk.paintio;
const PaintIOBase = @import("../paintio_base.zig").PaintIOBase;
const _project = @import("../project/_project.zig");
const _picture = @import("_picture.zig");

/// Writes pixels as a picture file.
///
/// SYNOPSIS:
/// ```zig
/// fn SavePicture(base: *PaintIOBase, name: [*:0]const u8, pixels: [*]const u32, width: u32, height: u32, format: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `name`: the file, made anew or written over.
/// - `pixels`: `width` times `height` pixels, `0xAARRGGBB`, a row after
///   another with nothing between.
/// - `width`, `height`: from 1 to `MAX_SIDE` each.
/// - `format`: `PIOFORMAT_PNG` or `PIOFORMAT_ILBM`.
///
/// RESULT:
/// 0 when the file is written, otherwise a dos error code: why the file
/// could not be made or written, `ERROR_NO_FREE_STORE`,
/// `ERROR_INVALID_RESIDENT_LIBRARY` when datatypes.library or
/// intuition.library cannot be opened, `ERROR_OBJECT_WRONG_TYPE` when
/// there is no datatype that writes the format, or `ERROR_BAD_NUMBER`
/// for a size or a format there is not.
///
/// BEHAVIOR:
/// A picture with any pixel not wholly opaque is written with its
/// coverage - a PNG with alpha, an ILBM of 32 planes - and one that is
/// opaque all over without: an RGB PNG, an ILBM of 24 planes. A PNG is
/// written by png.datatype, an ILBM by the picture group's own class.
/// A file that could not be written whole is deleted.
///
/// CONTEXT:
/// - Waits: yes, for the file system.
/// - Interrupts: not from an interrupt.
/// - Locks: none taken.
/// - Process: a Process; the file is opened on its behalf.
///
/// OWNERSHIP:
/// The pixels stay the caller's, and are only read. The datatype keeps a
/// copy of them while it writes: about the pixels' size again.
///
/// NOTES:
/// A project of several layers is made into one picture by the caller
/// first; `LoadProject` reads either format back as a picture.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SaveProject`, `LoadProject`
///
/// EXAMPLES:
/// ```zig
/// const failure = pio.SavePicture("Work:sky.png", pixels, 320, 200, paintio.PIOFORMAT_PNG);
/// if (failure != 0) _ = dl.PrintFault(failure, "Work:sky.png");
/// ```
pub fn SavePicture(base: *PaintIOBase, name: [*:0]const u8, pixels: [*]const u32, width: u32, height: u32, format: u32) i32 {
    if (width == 0 or width > paintio.MAX_SIDE or height == 0 or height > paintio.MAX_SIDE) return dos.ERROR_BAD_NUMBER;
    if (format != paintio.PIOFORMAT_PNG and format != paintio.PIOFORMAT_ILBM) return dos.ERROR_BAD_NUMBER;
    const sys = base.sys_base;
    const dl = base.dos_base;
    const libraries = _picture.Libraries.open(base) orelse return dos.ERROR_INVALID_RESIDENT_LIBRARY;
    defer libraries.close(base);
    const dt = libraries.dt;
    const png = format == paintio.PIOFORMAT_PNG;

    const object = dt.NewDTObjectA(null, &.{
        .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_RAM },
        .{ .tag = if (png) dtc.DTA_BaseName else utility.TAG_IGNORE, .data = @intFromPtr("png") },
        .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
        .{},
    }) orelse return _picture.dosError(dl.IoErr());
    defer dt.DisposeDTObject(object);

    const count = @as(usize, width) * height;
    var coverage = false;
    for (pixels[0..count]) |pixel| {
        if (pixel >> 24 != 0xFF) {
            coverage = true;
            break;
        }
    }
    const header = pic.BitMapHeader{
        .width = @intCast(width),
        .height = @intCast(height),
        .depth = if (coverage) 32 else 24,
        .masking = if (coverage) pic.mskHasAlpha else pic.mskNone,
        .x_aspect = 1,
        .y_aspect = 1,
        .page_width = @intCast(width),
        .page_height = @intCast(height),
    };
    _ = dt.SetDTAttrsA(object, null, null, &.{
        .{ .tag = pic.PDTA_SourceMode, .data = if (coverage) pic.PBPAFMT_ARGB else pic.PBPAFMT_RGB },
        .{ .tag = pic.PDTA_BitMapHeader, .data = @intFromPtr(&header) },
        .{},
    });

    const row_memory = sys.AllocVec(@as(usize, width) * 4, exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
    defer sys.FreeVec(row_memory);
    const row: [*]u8 = @ptrCast(row_memory);
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        _project.toFile(pixels[@as(usize, y) * width ..][0..width], row);
        var put = pic.PdtBlitPixelArray{
            .pixel_data = row,
            .format = pic.PBPAFMT_ARGB,
            .bytes_per_row = width * 4,
            .top = y,
            .width = width,
            .height = 1,
        };
        if (libraries.ib.SendMessage(object, @ptrCast(&put)) == 0) return dos.ERROR_NO_FREE_STORE;
    }

    const file = dl.Open(name, dos.MODE_NEWFILE) orelse return dl.IoErr();
    var out = dtc.DtWrite{ .file = file, .mode = if (png) dtc.DTWM_RAW else dtc.DTWM_IFF };
    const written = dt.DoDTMethodA(object, null, null, @ptrCast(&out)) != 0;
    var failure: i32 = if (written) 0 else dl.IoErr();
    if (!written and failure == 0) failure = dos.ERROR_NO_FREE_STORE;
    if (!dl.Close(file) and failure == 0) failure = dl.IoErr();
    if (failure != 0) _ = dl.DeleteFile(name);
    return failure;
}
