// SPDX-License-Identifier: MIT
//! Bands: three buffers of different sizes shown in bands on the display
//! board, two of them scaled. Built against the SDK only.
//!
//!   Bands SECONDS/K/N
//!
//! On the machine's display - the first board rtg.library lists - it
//! takes three buffers in the display's format: one of the mode's width,
//! one half as wide, and one one and a half times as wide, each with the
//! rows a third of the display shows of it. Each is painted with squares
//! of sixteen pixels in a colour of its own, a frame round its edge and
//! a line from corner to corner. Then it shows the three in bands, each
//! a third of the display high: the buffer of the mode's width as it
//! is, the small one below it at twice its size, the wide one below
//! that at two thirds of its size. Together they take less than a
//! picture and a half of the display's memory.
//! So the squares are sixteen pixels in the first band, thirty-two in
//! the second and about eleven in the third, where neighbouring pixels
//! are mixed.
//!
//! While the bands are shown a white bar walks across the small buffer,
//! drawn there and handed on with RefreshRect a step at a time: what is
//! written into a scaled band reaches the glass scaled. After SECONDS (5
//! without it), or Ctrl-C, the buffer the display showed before is shown
//! again, whole, and the three are freed.
//!
//! A board that scales no bands (`RTGBC_SCALE_BANDS`) is said to be one,
//! and nothing is shown.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const rtg = sdk.rtg;
const err = rtg.errors;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Bands";
const VERSION_STRING = "\x00$VER: Bands 1.0 (16.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "SECONDS/K/N";

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOBOARD = "No display board\n";
const MSG_NOSCALE = "%s scales no bands: every buffer it shows is the mode's size\n";
const MSG_NOFORMAT = "The display's pixels are not ones this program paints\n";
const MSG_NOROOM = "No room in the display's memory for the three buffers\n";
const MSG_SHOWN = "%s, %ux%u: %ux%u as it is, %ux%u twice as large, %ux%u at two thirds\n";
const MSG_REFUSED = "The board would not show the bands: %s\n";

const square = 16;
/// dos's ticks between two steps of the bar: a tenth of a second.
const step_ticks = 5;
const ticks_a_second = 50;

/// The bytes a colour, 0xRRGGBB, takes in a pixel format, low byte first,
/// and how many; none for a format that holds no colour.
fn pack(format: rtg.PixelFormat, colour: u32) struct { bytes: [4]u8, count: u32 } {
    const r: u32 = colour >> 16 & 0xFF;
    const g: u32 = colour >> 8 & 0xFF;
    const b: u32 = colour & 0xFF;
    return switch (format) {
        .bgra32 => .{ .bytes = .{ @intCast(b), @intCast(g), @intCast(r), 0xFF }, .count = 4 },
        .rgba32 => .{ .bytes = .{ @intCast(r), @intCast(g), @intCast(b), 0xFF }, .count = 4 },
        .bgr24 => .{ .bytes = .{ @intCast(b), @intCast(g), @intCast(r), 0 }, .count = 3 },
        .rgb24 => .{ .bytes = .{ @intCast(r), @intCast(g), @intCast(b), 0 }, .count = 3 },
        .rgb565 => blk: {
            const word = (r >> 3) << 11 | (g >> 2) << 5 | b >> 3;
            break :blk .{ .bytes = .{ @truncate(word), @truncate(word >> 8), 0, 0 }, .count = 2 };
        },
        .argb1555 => blk: {
            const word = 0x8000 | (r >> 3) << 10 | (g >> 3) << 5 | b >> 3;
            break :blk .{ .bytes = .{ @truncate(word), @truncate(word >> 8), 0, 0 }, .count = 2 };
        },
        else => .{ .bytes = .{ 0, 0, 0, 0 }, .count = 0 },
    };
}

/// A rectangle of a buffer in one colour, cut to the buffer.
fn fill(bitmap: *rtg.RtgBitMap, x: u32, y: u32, width: u32, height: u32, colour: u32) void {
    const packed_colour = pack(bitmap.format, colour);
    const right = @min(x + width, bitmap.width);
    const end = @min(y + height, bitmap.height);
    var row = y;
    while (row < end) : (row += 1) {
        const line = bitmap.pixels.? + @as(usize, row) * bitmap.pitch;
        var column = x;
        while (column < right) : (column += 1) {
            const at = line + @as(usize, column) * packed_colour.count;
            var i: u32 = 0;
            while (i < packed_colour.count) : (i += 1) at[i] = packed_colour.bytes[i];
        }
    }
}

/// A buffer painted: squares in `colour` and a darker shade of it, a
/// white frame round its edge, and a white line from corner to corner.
fn paint(bitmap: *rtg.RtgBitMap, colour: u32) void {
    const dark = (colour >> 1) & 0x7F7F7F;
    var y: u32 = 0;
    while (y < bitmap.height) : (y += square) {
        var x: u32 = 0;
        while (x < bitmap.width) : (x += square) {
            fill(bitmap, x, y, square, square, if ((x / square + y / square) % 2 == 0) colour else dark);
        }
    }
    fill(bitmap, 0, 0, bitmap.width, 1, 0xFFFFFF);
    fill(bitmap, 0, bitmap.height - 1, bitmap.width, 1, 0xFFFFFF);
    fill(bitmap, 0, 0, 1, bitmap.height, 0xFFFFFF);
    fill(bitmap, bitmap.width - 1, 0, 1, bitmap.height, 0xFFFFFF);
    y = 0;
    while (y < bitmap.height) : (y += 1) {
        fill(bitmap, @intCast(@as(u64, y) * bitmap.width / bitmap.height), y, bitmap.width / bitmap.height + 2, 1, 0xFFFFFF);
    }
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_ERROR;
    };
    defer dl.FreeArgs(rda);
    const seconds: u32 = if (argv[0] != 0) @intCast(@max(1, @as(*const i32, @ptrFromInt(argv[0])).*)) else 5;

    const rtg_lib = sys.OpenLibrary(rtg.RTGNAME, 1) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(rtg_lib);
    const rb: *RtgBase = @ptrCast(rtg_lib);
    // The machine's display: the first board rtg.library lists.
    const board = rb.NextBoard(null) orelse {
        _ = dl.PutStr(MSG_NOBOARD);
        return dos.RETURN_FAIL;
    };
    var info: rtg.RtgBoardInfo = .{};
    _ = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    const name: [*:0]const u8 = info.name orelse "the board";
    if (info.caps & rtg.boards.RTGBC_SCALE_BANDS == 0) {
        _ = Printf(dl, MSG_NOSCALE, .{name});
        return dos.RETURN_WARN;
    }
    if (pack(info.format, 0).count == 0 or info.width < 4 * square or info.height < 6 * square) {
        _ = dl.PutStr(MSG_NOFORMAT);
        return dos.RETURN_WARN;
    }

    // Three buffers: the mode's width, half of it, and one and a half
    // times it, each with the rows a third of the display shows of it.
    const format = @intFromEnum(info.format);
    const displayable = rtg.bitmaps.RTGBMF_DISPLAYABLE;
    const third = info.height / 3;
    const whole = rb.AllocBitMap(board, info.width, third, format, displayable);
    defer rb.FreeBitMap(whole);
    const small = rb.AllocBitMap(board, info.width / 2, third / 2 + 2, format, displayable);
    defer rb.FreeBitMap(small);
    const wide = rb.AllocBitMap(board, info.width / 2 * 3, third / 2 * 3 + 2, format, displayable);
    defer rb.FreeBitMap(wide);
    if (whole == null or small == null or wide == null) {
        _ = dl.PutStr(MSG_NOROOM);
        return dos.RETURN_FAIL;
    }
    paint(whole.?, 0xD03030);
    paint(small.?, 0x30B030);
    paint(wide.?, 0x3050E0);
    for ([_]*rtg.RtgBitMap{ whole.?, small.?, wide.? }) |buffer| _ = rb.RefreshRect(buffer, null);

    // What the display shows now is shown again when this is over.
    const before = rb.BoardDisplayBitMap(board);
    const bands = [_]rtg.RtgBand{
        .{ .bitmap = whole.? },
        .{ .bitmap = small.?, .line = third, .origin = third },
        .{ .bitmap = wide.?, .line = 2 * third, .origin = 2 * third },
    };
    const code = rb.ShowBoard(board, 0, &bands, bands.len);
    if (code != err.RTGERR_OK) {
        _ = Printf(dl, MSG_REFUSED, .{rb.RtgErrorText(code)});
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, MSG_SHOWN, .{ name, info.width, info.height, whole.?.width, whole.?.height, small.?.width, small.?.height, wide.?.width, wide.?.height });

    // A bar across the small buffer, a step at a time: drawn there, and
    // handed on as the rectangle it is.
    const bar = square / 2;
    const bar_top = square;
    const bar_height = 2 * square;
    var at: u32 = 0;
    var ticks: u32 = 0;
    while (ticks < seconds * ticks_a_second) : (ticks += step_ticks) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) break;
        const next = (at + bar) % (small.?.width - bar);
        // Where the bar was, painted as the squares were; where it is,
        // white.
        var y: u32 = bar_top;
        while (y < bar_top + bar_height) : (y += square) {
            const colour: u32 = if (((at / square) + y / square) % 2 == 0) 0x30B030 else 0x185818;
            fill(small.?, at, y, bar, square, colour);
        }
        fill(small.?, next, bar_top, bar, bar_height, 0xFFFFFF);
        _ = rb.RefreshRect(small.?, &.{ .x = @intCast(at), .y = bar_top, .width = bar, .height = bar_height });
        _ = rb.RefreshRect(small.?, &.{ .x = @intCast(next), .y = bar_top, .width = bar, .height = bar_height });
        at = next;
        dl.Delay(step_ticks);
    }

    // The picture before, whole; nothing where there was none.
    _ = rb.ShowBitMap(board, before);
    return dos.RETURN_OK;
}
