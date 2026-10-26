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
//! keeps it in - so a picture that moves is taken as one moment. Writing
//! the PNG (png.zig) comes after, from the copy, packed by
//! compression.library. The pointer is not in
//! the screen's buffer - the display lays it over - and so is not in the
//! picture.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const rtg = sdk.rtg;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const CompressionBase = sdk.interface.compression.CompressionBase;
const PixelFormat = rtg.bitmaps.PixelFormat;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;
const sc = intuition.screens;
const png = @import("png.zig");

pub const COMMAND_NAME = "ScreenDump";
const VERSION_STRING = "\x00$VER: ScreenDump 1.1 (25.10.2026)\r\n";
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
const MSG_DONE = "%s: %u by %u written to %s, %lu bytes\n";

/// What the PNG writer hands over goes to the file, and is counted.
const Output = struct {
    dl: *DosBase,
    file: *dos.FileHandle,
    written: u64 = 0,

    fn put(context: *anyopaque, bytes: []const u8) bool {
        const output: *Output = @ptrCast(@alignCast(context));
        if (bytes.len == 0) return true;
        const done = output.dl.Write(output.file, bytes.ptr, @intCast(bytes.len));
        if (done != @as(isize, @intCast(bytes.len))) return false;
        output.written += bytes.len;
        return true;
    }
};

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
    const compression_lib = sys.OpenLibrary(sdk.compression.COMPRESSIONNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{ COMMAND_NAME, sdk.compression.COMPRESSIONNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(compression_lib);
    const cb: *CompressionBase = @ptrCast(compression_lib);

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
    const stride = png.rowBytes(width);
    const memory = sys.AllocVec(stride * height, exec.MEMF_ANY) orelse {
        ib.FreeScreenBuffer(screen, buffer);
        _ = Printf(dl, MSG_NOMEMORY, .{ COMMAND_NAME, width, height });
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const rows: [*]u8 = @ptrCast(memory);
    const copied = copyScreen(bitmap, rows, stride);
    ib.FreeScreenBuffer(screen, buffer);
    ib.UnlockPubScreen(null, screen);
    unlocked = true;
    if (!copied) {
        _ = Printf(dl, MSG_FORMAT, .{COMMAND_NAME});
        return dos.RETURN_FAIL;
    }

    const work_memory = sys.AllocVec(@sizeOf(png.Work), exec.MEMF_ANY) orelse {
        _ = Printf(dl, MSG_NOMEMORY, .{ COMMAND_NAME, width, height });
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(work_memory);
    const work: *png.Work = @ptrCast(@alignCast(work_memory));

    const file = dl.Open(to, dos.MODE_NEWFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), to);
        return dos.RETURN_FAIL;
    };
    var output = Output{ .dl = dl, .file = file };
    const result = png.write(work, cb, .{ .context = &output, .put = Output.put }, width, height, rows[0 .. stride * height]);
    const failure = dl.IoErr();
    _ = dl.Close(file);
    switch (result) {
        .written => {},
        .sink_failed => {
            _ = dl.PrintFault(failure, to);
            _ = dl.DeleteFile(to);
            return dos.RETURN_FAIL;
        },
        .no_memory => {
            _ = Printf(dl, MSG_NOMEMORY, .{ COMMAND_NAME, width, height });
            _ = dl.DeleteFile(to);
            return dos.RETURN_FAIL;
        },
    }
    if (argv[arg_quiet] == 0) _ = Printf(dl, MSG_DONE, .{ COMMAND_NAME, width, height, to, output.written });
    return dos.RETURN_OK;
}

/// The screen's pixels into rows of 8-bit RGB, each after a byte left for
/// its filter: false for a form this does not read.
fn copyScreen(bitmap: *const rtg.RtgBitMap, rows: [*]u8, stride: usize) bool {
    const pixels = bitmap.pixels orelse return false;
    for (0..bitmap.height) |y| {
        const from = pixels + y * bitmap.pitch;
        const into = rows + y * stride + 1;
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
