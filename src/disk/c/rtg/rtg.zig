// SPDX-License-Identifier: MIT
//! Rtg: what displays this machine has, and what drives them. Built
//! against the SDK only.
//!
//!   Rtg BOARD,DRIVERS/S,BOARDS/S,MODES/S,MEMORY/S,STATS/S,FULL/S
//!
//! With nothing asked for it prints the two lists: the display drivers
//! that have joined rtg.library, and the boards made from them. Name a
//! board and it prints that board in full - what it is, what it can be
//! asked to do, the modes it has, what its display memory has been cut
//! into and, for a display that refreshes itself, how the stream is doing.
//!
//! The switches pick sections rather than repeat the name: MODES, MEMORY
//! and STATS each print that one section, for the board named or for every
//! board; DRIVERS and BOARDS print one list alone, which is what a script
//! wants; FULL prints every section of every board.
//!
//! Everything it prints comes from GetBoardInfo and GetBoardStats, which
//! answer with the bytes they wrote, so a command older or newer than the
//! ROM prints what the answer reached and no more. See docs/rtg.md.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const rtg = sdk.rtg;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Rtg";
const VERSION_STRING = "\x00$VER: Rtg 1.0 (17.9.2026)\r\n";

const template = "BOARD,DRIVERS/S,BOARDS/S,MODES/S,MEMORY/S,STATS/S,FULL/S";
const arg_board = 0;
const arg_drivers = 1;
const arg_boards = 2;
const arg_modes = 3;
const arg_memory = 4;
const arg_stats = 5;
const arg_full = 6;

const MSG_NOLIBRARY = "No %s - this machine has no display layer\n";
const MSG_NOBOARD = "No board \"%s\"\n";
const MSG_NOBOARDS = "No boards: no display driver found anything to drive\n";
const MSG_NODRIVERS = "No display drivers\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [7]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const base = sys.OpenLibrary(rtg.RTGNAME, rtg.RTG_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{rtg.RTGNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(base);
    const rb: *RtgBase = @ptrCast(base);

    // FULL is not "all three sections": it is the whole of every board,
    // which is what printBoard prints. A section switch asks for that
    // section and nothing else.
    const full = argv[arg_full] != 0;
    const want_modes = argv[arg_modes] != 0;
    const want_memory = argv[arg_memory] != 0;
    const want_stats = argv[arg_stats] != 0;
    const one_section = !full and (want_modes or want_memory or want_stats);

    // DRIVERS or BOARDS on their own is one list and nothing else.
    if (argv[arg_drivers] != 0 and argv[arg_boards] == 0 and !one_section) {
        return printDrivers(dl, rb);
    }
    if (argv[arg_boards] != 0 and argv[arg_drivers] == 0 and !one_section) {
        return printBoards(dl, rb);
    }

    // A board by name: that one, in as much detail as was asked for.
    if (argv[arg_board] != 0) {
        const wanted: [*:0]const u8 = @ptrFromInt(argv[arg_board]);
        const board = rb.FindBoard(wanted) orelse {
            _ = Printf(dl, MSG_NOBOARD, .{wanted});
            return dos.RETURN_ERROR;
        };
        if (one_section) {
            if (want_modes) printModes(dl, rb, board);
            if (want_memory) printMemory(dl, rb, board);
            if (want_stats) printStats(dl, rb, board);
            return dos.RETURN_OK;
        }
        printBoard(dl, rb, board);
        return dos.RETURN_OK;
    }

    // A section without a board: that section for every board there is,
    // each under the same heading a board's own report starts with.
    if (one_section) {
        var board = rb.NextBoard(null);
        if (board == null) {
            _ = dl.PutStr(MSG_NOBOARDS);
            return dos.RETURN_WARN;
        }
        while (board) |b| : (board = rb.NextBoard(b)) {
            var info: rtg.RtgBoardInfo = .{};
            _ = rb.GetBoardInfo(b, &info, @sizeOf(rtg.RtgBoardInfo));
            _ = Printf(dl, "%-12s %s\n", .{ "Board", name(info.name) });
            if (want_modes) printModes(dl, rb, b);
            if (want_memory) printMemory(dl, rb, b);
            if (want_stats) printStats(dl, rb, b);
        }
        return dos.RETURN_OK;
    }

    // FULL: every board, whole, with a blank line between them.
    if (full) {
        var board = rb.NextBoard(null);
        if (board == null) {
            _ = dl.PutStr(MSG_NOBOARDS);
            return dos.RETURN_WARN;
        }
        var first = true;
        while (board) |b| : (board = rb.NextBoard(b)) {
            if (!first) _ = dl.PutStr("\n");
            first = false;
            printBoard(dl, rb, b);
        }
        return dos.RETURN_OK;
    }

    // Nothing asked for: both lists.
    _ = printDrivers(dl, rb);
    _ = dl.PutStr("\n");
    return printBoards(dl, rb);
}

// --- the lists --------------------------------------------------------------

fn printDrivers(dl: *DosBase, rb: *RtgBase) i32 {
    var driver = blk: {
        rb.LockRtgDrivers();
        break :blk rb.NextRtgDriver(null);
    };
    if (driver == null) {
        rb.UnlockRtgDrivers();
        _ = dl.PutStr(MSG_NODRIVERS);
        return dos.RETURN_WARN;
    }
    _ = dl.PutStr("Driver          Ver  Kind       Handles  Module\n");
    var id: [48]u8 = undefined;
    while (driver) |d| : (driver = rb.NextRtgDriver(d)) {
        _ = Printf(dl, "%-14s  %d.%-2d %-9s  %7d  %s\n", .{
            name(d.node.name),
            d.version,
            d.revision,
            kindOf(d.type),
            d.open_cnt,
            idText(&id, d.id_string),
        });
    }
    rb.UnlockRtgDrivers();
    return dos.RETURN_OK;
}

fn printBoards(dl: *DosBase, rb: *RtgBase) i32 {
    var board = rb.NextBoard(null);
    if (board == null) {
        _ = dl.PutStr(MSG_NOBOARDS);
        return dos.RETURN_WARN;
    }
    _ = dl.PutStr("Board        Driver    Mode               Memory free  Showing\n");
    while (board) |b| : (board = rb.NextBoard(b)) {
        var info: rtg.RtgBoardInfo = .{};
        const got = rb.GetBoardInfo(b, &info, @sizeOf(rtg.RtgBoardInfo));
        if (got == 0) continue;
        const shown = rb.BoardDisplayBitMap(b);
        _ = Printf(dl, "%-11s  %-8s  %4dx%-4d %-8s  %10d  %s\n", .{
            name(info.name),
            name(info.driver),
            info.width,
            info.height,
            formatName(info.format),
            info.memory_free,
            if (shown != null) "yes" else "no",
        });
    }
    return dos.RETURN_OK;
}

// --- one board --------------------------------------------------------------

fn printBoard(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) void {
    var info: rtg.RtgBoardInfo = .{};
    const got = rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo));
    if (got == 0) {
        _ = Printf(dl, MSG_NOBOARD, .{name(info.name)});
        return;
    }
    _ = Printf(dl, "%-12s %s\n", .{ "Board", name(info.name) });
    var id: [48]u8 = undefined;
    _ = Printf(dl, "%-12s %s (%s)\n", .{ "Driver", name(info.driver), idText(&id, info.id_string) });
    _ = Printf(dl, "%-12s %dx%d %s, %d bytes a row\n", .{
        "Mode",
        info.width,
        info.height,
        formatName(info.format),
        info.pitch,
    });
    if (info.refresh_mhz != 0) {
        _ = Printf(dl, "%-12s %d.%03d Hz, pixel clock %d.%03d MHz\n", .{
            "Refresh",
            info.refresh_mhz / 1000,
            info.refresh_mhz % 1000,
            info.pixel_clock_hz / 1_000_000,
            (info.pixel_clock_hz / 1000) % 1000,
        });
    }
    _ = Printf(dl, "%-12s %d at once\n", .{ "Buffers", info.buffers });
    _ = Printf(dl, "%-12s %d%%\n", .{ "Brightness", info.brightness });
    _ = Printf(dl, "%-12s ", .{"State"});
    printFlags(dl, info.flags);
    _ = Printf(dl, "%-12s ", .{"Can"});
    printCaps(dl, info.caps);
    printTurn(dl, &info);

    printModes(dl, rb, board);
    printMemory(dl, rb, board);
    if (info.flags & rtg.boards.RTGBF_STREAMING != 0) printStats(dl, rb, board);
}

/// How the picture is turned, for a board that can be turned at all or one
/// that has been. A board that answers RTGERR_NOT_SUPPORTED to all three
/// says nothing here: turning its picture is the business of whoever draws
/// it.
fn printTurn(dl: *DosBase, info: *const rtg.RtgBoardInfo) void {
    const can = info.caps & (rtg.boards.RTGBC_MIRROR | rtg.boards.RTGBC_SWAP_XY | rtg.boards.RTGBC_GAP);
    const turned = info.mirror_x != 0 or info.mirror_y != 0 or info.swapped != 0;
    if (can == 0 and !turned) return;
    _ = Printf(dl, "%-12s %s%s%s", .{
        "Turned",
        if (info.swapped != 0) "axes exchanged" else "upright",
        if (info.mirror_x != 0) ", mirrored about x" else "",
        if (info.mirror_y != 0) ", mirrored about y" else "",
    });
    if (info.gap_x != 0 or info.gap_y != 0) {
        _ = Printf(dl, ", offset %d,%d", .{ info.gap_x, info.gap_y });
    }
    _ = dl.PutStr("\n");
}

fn printModes(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) void {
    var mode = rb.NextBoardMode(board, null);
    if (mode == null) {
        _ = Printf(dl, "%-12s none\n", .{"Modes"});
        return;
    }
    _ = dl.PutStr("Modes         id  size      format     row    clock    refresh  how it is\n");
    while (mode) |m| : (mode = rb.NextBoardMode(board, m)) {
        _ = Printf(dl, "             %3d  %4dx%-4d %-6s  %6d  %4d MHz  %2d.%03d Hz  ", .{
            m.id,
            m.width,
            m.height,
            formatName(m.format),
            m.pitch,
            m.pixel_clock_hz / 1_000_000,
            m.refresh_mhz / 1000,
            m.refresh_mhz % 1000,
        });
        // What this mode is to the board, in words: no legend to look up.
        printWords(dl, m.flags, &mode_words, "-");
    }
}

fn printMemory(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) void {
    var info: rtg.RtgBoardInfo = .{};
    if (rb.GetBoardInfo(board, &info, @sizeOf(rtg.RtgBoardInfo)) == 0) return;
    _ = Printf(dl, "%-12s %d bytes, %d free, largest piece %d\n", .{
        "Memory",
        info.memory_total,
        info.memory_free,
        info.memory_largest,
    });
    if (rb.BoardDisplayBitMap(board)) |shown| {
        _ = Printf(dl, "%-12s 0x%08x, %dx%d %s, %d bytes a row, %d bytes\n", .{
            "Showing",
            @intFromPtr(shown.pixels),
            shown.width,
            shown.height,
            formatName(shown.format),
            shown.pitch,
            shown.size_bytes,
        });
    } else {
        _ = Printf(dl, "%-12s nothing\n", .{"Showing"});
    }
}

fn printStats(dl: *DosBase, rb: *RtgBase, board: *rtg.RtgBoard) void {
    var s: rtg.RtgBoardStats = .{};
    const got = rb.GetBoardStats(board, &s, @sizeOf(rtg.RtgBoardStats));
    if (got == 0) return;
    if (s.frames == 0 and s.refills == 0 and s.buffer_swaps == 0) {
        _ = dl.PutStr("Stream       nothing counted\n");
        return;
    }
    _ = Printf(dl, "%-12s %d frames, %d late (worst %d us past the frame), %d starved\n", .{
        "Stream",
        s.frames,
        s.late_frames,
        s.worst_late_us,
        s.starved_frames,
    });
    if (has(got, "late_refills")) {
        _ = Printf(dl, "%-12s %d copied, %d of them waited for\n", .{ "Refills", s.refills, s.late_refills });
    }
    if (has(got, "slow_gaps")) {
        _ = Printf(dl, "%-12s %d, last gap %d us, worst %d us, %d over a line, %d over 5 us\n", .{
            "Realigns",
            s.realigns,
            s.last_gap_us,
            s.worst_gap_us,
            s.long_gaps,
            s.slow_gaps,
        });
    }
    if (has(got, "walk_frames")) {
        _ = Printf(dl, "%-12s at stretch %d, moved %d over %d frames\n", .{
            "In step",
            s.stream_at,
            s.total_walk,
            s.walk_frames,
        });
    }
    if (has(got, "buffer_swaps") and s.buffer_swaps != 0) {
        _ = Printf(dl, "%-12s %d buffer(s) handed to the display\n", .{ "Swaps", s.buffer_swaps });
    }
}

// --- what the words are -----------------------------------------------------

const Named = struct { bit: u32, word: [*:0]const u8 };

const state_words = [_]Named{
    .{ .bit = rtg.boards.RTGBF_NO_DISPLAY, .word = "no-display" },
    .{ .bit = rtg.boards.RTGBF_DISPLAY_ON, .word = "on" },
    .{ .bit = rtg.boards.RTGBF_MODE_SET, .word = "mode-set" },
    .{ .bit = rtg.boards.RTGBF_SHOWING, .word = "showing" },
    .{ .bit = rtg.boards.RTGBF_STREAMING, .word = "streaming" },
    .{ .bit = rtg.boards.RTGBF_ADOPTED, .word = "adopted" },
};

const mode_words = [_]Named{
    .{ .bit = rtg.boards.RTGMF_CURRENT, .word = "current" },
    .{ .bit = rtg.boards.RTGMF_DEFAULT, .word = "default" },
    .{ .bit = rtg.boards.RTGMF_DOUBLE_BUFFER, .word = "double-buffer" },
    .{ .bit = rtg.boards.RTGMF_PANNABLE, .word = "pannable" },
};

const cap_words = [_]Named{
    .{ .bit = rtg.boards.RTGBC_SET_MODE, .word = "set-mode" },
    .{ .bit = rtg.boards.RTGBC_SHOW, .word = "show" },
    .{ .bit = rtg.boards.RTGBC_PAN, .word = "pan" },
    .{ .bit = rtg.boards.RTGBC_VBLANK, .word = "wait-blank" },
    .{ .bit = rtg.boards.RTGBC_REFRESH, .word = "refresh" },
    .{ .bit = rtg.boards.RTGBC_DISPLAY, .word = "display" },
    .{ .bit = rtg.boards.RTGBC_BRIGHTNESS, .word = "brightness" },
    .{ .bit = rtg.boards.RTGBC_STATS, .word = "stats" },
    .{ .bit = rtg.boards.RTGBC_CONTROL, .word = "control" },
    .{ .bit = rtg.boards.RTGBC_MIRROR, .word = "mirror" },
    .{ .bit = rtg.boards.RTGBC_SWAP_XY, .word = "swap-axes" },
    .{ .bit = rtg.boards.RTGBC_GAP, .word = "gap" },
    .{ .bit = rtg.boards.RTGBC_FILL_RECT, .word = "fill" },
    .{ .bit = rtg.boards.RTGBC_COPY_RECT, .word = "copy" },
    .{ .bit = rtg.boards.RTGBC_INVERT_RECT, .word = "invert" },
    .{ .bit = rtg.boards.RTGBC_BLIT_TEMPLATE, .word = "template" },
    .{ .bit = rtg.boards.RTGBC_BLIT_PATTERN, .word = "pattern" },
    .{ .bit = rtg.boards.RTGBC_ENGINE, .word = "engine" },
};

fn printWords(dl: *DosBase, bits: u32, words: []const Named, none: [*:0]const u8) void {
    var printed = false;
    for (words) |w| {
        if (bits & w.bit == 0) continue;
        _ = Printf(dl, "%s%s", .{ if (printed) " " else "", w.word });
        printed = true;
    }
    if (!printed) _ = Printf(dl, "%s", .{none});
    _ = dl.PutStr("\n");
}

fn printFlags(dl: *DosBase, flags: u32) void {
    printWords(dl, flags, &state_words, "idle");
}

/// What the board's own hardware does. Whatever is not here the caller
/// does itself: this layer holds no drawing.
fn printCaps(dl: *DosBase, caps: u32) void {
    printWords(dl, caps, &cap_words, "nothing");
}

fn kindOf(kind: u32) [*:0]const u8 {
    const board = kind & rtg.boards.RTGDT_BOARD != 0;
    const bus = kind & rtg.boards.RTGDT_TRANSPORT != 0;
    if (board and bus) return "board+bus";
    if (board) return "board";
    if (bus) return "bus";
    return "-";
}

fn formatName(format: rtg.PixelFormat) [*:0]const u8 {
    return switch (format) {
        .rgba32 => "rgba32",
        .bgra32 => "bgra32",
        .rgb24 => "rgb24",
        .bgr24 => "bgr24",
        .rgb565 => "rgb565",
        .argb1555 => "a1555",
        .indexed8 => "index8",
        .gray8 => "gray8",
        .mono1 => "mono1",
        else => "?",
    };
}

/// A module's id string, which is its "$VER:" line: past the "$VER: " and
/// cut before the carriage return every one of them ends with, so it can
/// go in a table without taking two lines.
fn idText(into: []u8, from: ?[*:0]const u8) [*:0]const u8 {
    const text = from orelse return "";
    var at: usize = 0;
    if (starts(text, "$VER: ")) at = 6;
    var put: usize = 0;
    while (text[at] != 0 and put + 1 < into.len) : (at += 1) {
        if (text[at] < ' ') break;
        into[put] = text[at];
        put += 1;
    }
    into[put] = 0;
    return @ptrCast(into.ptr);
}

fn starts(text: [*:0]const u8, comptime prefix: []const u8) bool {
    inline for (prefix, 0..) |want, i| {
        if (text[i] != want) return false;
    }
    return true;
}

/// A string the library may have left null.
fn name(s: ?[*:0]const u8) [*:0]const u8 {
    return s orelse "?";
}

/// Whether the answer reached far enough to hold a field. The ROM says how
/// many bytes it wrote; a field is there when its last byte is inside them.
fn has(got: u32, comptime field: []const u8) bool {
    const end = @offsetOf(rtg.RtgBoardStats, field) + @sizeOf(@FieldType(rtg.RtgBoardStats, field));
    return got >= end;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
