// SPDX-License-Identifier: MIT
//! ScreenDump: a screen saved as a PNG file. Built against the SDK only.
//!
//!   ScreenDump TO/A,SCREEN/K,DELAY/K/N,QUIET/S
//!
//! TO is the file written; SCREEN the public screen to take, the default
//! one - the desktop's - unless named; DELAY how many seconds to wait
//! first, to set up what is to be seen. QUIET leaves out the line that
//! says what was written.
//!
//! The screen's own buffer is reached through `AllocScreenBuffer` with
//! `SB_SCREEN_BITMAP`, which hands it out rather than making another, and
//! copied at once into rows of 8-bit RGB - from whatever form the display
//! keeps it in - so a picture that moves is taken as one moment. The
//! copy then goes into an empty png.datatype object (`NewDTObjectA` with
//! `DTST_RAM`), which writes it out as a PNG (`DTM_WRITE`, `DTWM_RAW`).
//! The pointer is not in the screen's buffer - the display lays it over -
//! and so is not in the picture.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const rtg = sdk.rtg;
const datatypes = sdk.datatypes;
const dtc = datatypes.datatypesclass;
const pic = datatypes.pictureclass;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const PixelFormat = rtg.bitmaps.PixelFormat;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const sc = intuition.screens;

pub const COMMAND_NAME = "ScreenDump";
const VERSION_STRING = "\x00$VER: ScreenDump 1.2 (19.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TO/A,SCREEN/K,DELAY/K/N,QUIET/S";
const arg_to = 0;
const arg_screen = 1;
const arg_delay = 2;
const arg_quiet = 3;

const MSG_NOSCREEN = "%s: no screen %s\n";
const MSG_NODEFAULT = "%s: no default screen\n";
const MSG_NOBUFFER = "%s: the screen's buffer cannot be had\n";
const MSG_FORMAT = "%s: the screen's pixels are in a form this does not read\n";
const MSG_NOMEMORY = "%s: no memory for a picture of %u by %u\n";
const MSG_NOLIBRARY = "%s: cannot open %s\n";
const MSG_NOWRITER = "%s: png.datatype cannot be made: %s\n";
const MSG_DONE = "%s: %u by %u written to %s, %lu bytes\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const to: [*:0]const u8 = @ptrFromInt(argv[arg_to]);
    const name = rdargs.string(argv[arg_screen]);
    const seconds: u32 = @intCast(@max(rdargs.number(argv[arg_delay]) orelse 0, 0));

    const intuition_lib = sys.OpenLibrary(intuition.INTUITIONNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(intuition_lib);
    const ib: *IntuitionBase = @ptrCast(intuition_lib);
    const datatypes_lib = sys.OpenLibrary(datatypes.DATATYPESNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, datatypes.DATATYPESNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(datatypes_lib);
    const dt: *DataTypesBase = @ptrCast(datatypes_lib);

    // Waited out in pieces, so Ctrl-C ends it.
    var waited: u32 = 0;
    while (waited < seconds * 50) : (waited += 10) {
        dl.Delay(10);
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, COMMAND_NAME);
            return dos.RETURN_WARN;
        }
    }

    const screen = ib.LockPubScreen(name) orelse {
        if (name) |given| {
            _ = Printf(dl, MSG_NOSCREEN, .{ COMMAND_NAME, given });
        } else {
            _ = Printf(dl, MSG_NODEFAULT, .{COMMAND_NAME});
        }
        return dos.RETURN_FAIL;
    };
    var unlocked = false;
    defer if (!unlocked) ib.UnlockPubScreen(null, screen);

    const buffer = ib.AllocScreenBuffer(screen, sc.SB_SCREEN_BITMAP) orelse {
        _ = Printf(dl, MSG_NOBUFFER, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    };
    const bitmap = buffer.bitmap;
    const width = bitmap.width;
    const height = bitmap.height;
    const stride = @as(usize, width) * 3;
    const memory = sys.AllocVec(stride * height, exec.MEMF_ANY) orelse {
        ib.FreeScreenBuffer(screen, buffer);
        _ = Printf(dl, MSG_NOMEMORY, .{ COMMAND_NAME, width, height });
        return dos.RETURN_FAIL;
    };
    var kept = true;
    defer if (kept) sys.FreeVec(memory);
    const rows: [*]u8 = @ptrCast(memory);
    const copied = copyScreen(bitmap, rows, stride);
    ib.FreeScreenBuffer(screen, buffer);
    ib.UnlockPubScreen(null, screen);
    unlocked = true;
    if (!copied) {
        _ = Printf(dl, MSG_FORMAT, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }

    // The copy into an empty PNG picture, which writes itself out.
    const picture = dt.NewDTObjectA(null, &.{
        .{ .tag = dtc.DTA_SourceType, .data = dtc.DTST_RAM },
        .{ .tag = dtc.DTA_BaseName, .data = @intFromPtr("png") },
        .{ .tag = dtc.DTA_GroupID, .data = datatypes.GID_PICTURE },
        .{},
    }) orelse {
        var why: [80]u8 = @splat(0);
        _ = dl.Fault(dl.IoErr(), null, &why, why.len);
        _ = Printf(dl, MSG_NOWRITER, .{ COMMAND_NAME, @as([*:0]const u8, @ptrCast(&why)) });
        return dos.RETURN_FAIL;
    };
    defer dt.DisposeDTObject(picture);
    const header = pic.BitMapHeader{
        .width = @intCast(width),
        .height = @intCast(height),
        .depth = 24,
        .masking = pic.mskNone,
        .x_aspect = 1,
        .y_aspect = 1,
        .page_width = @intCast(width),
        .page_height = @intCast(height),
    };
    _ = dt.SetDTAttrsA(picture, null, null, &.{
        .{ .tag = pic.PDTA_SourceMode, .data = pic.PBPAFMT_RGB },
        .{ .tag = pic.PDTA_BitMapHeader, .data = @intFromPtr(&header) },
        .{},
    });
    var rows_in = pic.PdtBlitPixelArray{
        .pixel_data = rows,
        .format = pic.PBPAFMT_RGB,
        .bytes_per_row = @intCast(stride),
        .width = width,
        .height = height,
    };
    if (ib.SendMessage(picture, @ptrCast(&rows_in)) == 0) {
        _ = Printf(dl, MSG_NOMEMORY, .{ COMMAND_NAME, width, height });
        return dos.RETURN_FAIL;
    }
    // The copy is in the picture now.
    sys.FreeVec(memory);
    kept = false;

    const file = dl.Open(to, dos.MODE_NEWFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), to);
        return dos.RETURN_FAIL;
    };
    var out = dtc.DtWrite{ .file = file, .mode = dtc.DTWM_RAW };
    const written_ok = dt.DoDTMethodA(picture, null, null, @ptrCast(&out)) != 0;
    const failure = dl.IoErr();
    const written: u64 = @intCast(@max(dl.Seek(file, 0, dos.OFFSET_CURRENT), 0));
    _ = dl.Close(file);
    if (!written_ok) {
        _ = dl.PrintFault(failure, to);
        _ = dl.DeleteFile(to);
        return dos.RETURN_FAIL;
    }
    if (argv[arg_quiet] == 0) _ = Printf(dl, MSG_DONE, .{ COMMAND_NAME, width, height, to, written });
    return dos.RETURN_OK;
}
/// The screen's pixels into rows of 8-bit RGB: false for a form this does
/// not read.
fn copyScreen(bitmap: *const rtg.RtgBitMap, rows: [*]u8, stride: usize) bool {
    const pixels = bitmap.pixels orelse return false;
    for (0..bitmap.height) |y| {
        const from = pixels + y * bitmap.pitch;
        const into = rows + y * stride;
        for (0..bitmap.width) |x| {
            const rgb: [3]u8 = switch (bitmap.format) {
                .rgb565 => blk: {
                    const value = @as(u16, from[x * 2]) | @as(u16, from[x * 2 + 1]) << 8;
                    break :blk .{ widen(value >> 11, 5), widen(value >> 5 & 0x3F, 6), widen(value & 0x1F, 5) };
                },
                .argb1555 => blk: {
                    const value = @as(u16, from[x * 2]) | @as(u16, from[x * 2 + 1]) << 8;
                    break :blk .{ widen(value >> 10 & 0x1F, 5), widen(value >> 5 & 0x1F, 5), widen(value & 0x1F, 5) };
                },
                .rgb24 => from[x * 3 ..][0..3].*,
                .bgr24 => .{ from[x * 3 + 2], from[x * 3 + 1], from[x * 3] },
                .rgba32 => from[x * 4 ..][0..3].*,
                .bgra32 => .{ from[x * 4 + 2], from[x * 4 + 1], from[x * 4] },
                else => return false,
            };
            into[x * 3 ..][0..3].* = rgb;
        }
    }
    return true;
}

/// A colour of `bits` bits brought to eight, its high bits repeated below
/// so white stays white.
fn widen(value: u16, comptime bits: u4) u8 {
    const v: u16 = value & ((1 << bits) - 1);
    return @truncate((v << (8 - bits)) | (v >> (2 * bits - 8)));
}
