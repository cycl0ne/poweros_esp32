// SPDX-License-Identifier: MPL-2.0
//! screen [on|off|<percent>|ruler|rows [forget]|refresh [y rows]|reset|
//! realign|shift <pixels>]: the display graphics.library brought up at
//! cold start - its mode, backlight and the stream's counters - and the
//! means to take it apart when the glass looks wrong. It reaches the board
//! through rtg.library by the name graphics.library gave it, and owns
//! nothing.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const rtg = sdk.rtg;
const tags = rtg.tags;
const RtgBase = sdk.interface.rtg.RtgBase;
const RtgBoard = rtg.RtgBoard;

/// The shown picture: its pixels, its size and the bytes a row takes.
const Frame = struct { pixels: [*]u16, width: u32, height: u32, pitch: u32 };

/// The display's board and what it shows, for one command.
const Display = struct {
    rb: *RtgBase,
    board: *RtgBoard,
    shown: Frame,

    /// One of the driver's own controls.
    fn ask(display: Display, what: u32, value: isize) isize {
        return display.rb.BoardControl(display.board, what, value);
    }

    /// A control whose answer is a count, 0 if the driver refuses it.
    fn count(display: Display, what: u32, value: isize) u32 {
        const answer = display.ask(what, value);
        return if (answer < 0) 0 else @intCast(answer);
    }

    fn stats(display: Display) rtg.RtgBoardStats {
        var answer: rtg.RtgBoardStats = .{};
        _ = display.rb.GetBoardStats(display.board, &answer, @sizeOf(rtg.RtgBoardStats));
        return answer;
    }

    /// Rows `y` to `y + rows` of the shown buffer to the panel again; 0
    /// rows is all of them. False if the board has no buffer shown.
    fn refresh(display: Display, y: u32, count_rows: u32) bool {
        const bitmap = display.board.showing orelse return false;
        return display.rb.RefreshBitMap(bitmap, y, count_rows) == rtg.errors.RTGERR_OK;
    }
};

pub const name = "screen";
pub const usage = "screen [on|off|<percent>|ruler|rows|refresh|reset|realign|shift <pixels>]";
pub const help =
    \\  screen               the panel's mode, backlight and the stream's counters
    \\  screen on|off|<percent>  the backlight, through expander.resource
    \\  screen ruler         a scale across the glass, to measure where the picture starts
    \\  screen shift <pixels>  move the active area within the line
    \\  screen rows [forget] which rows have been handed on since the marks
    \\                       were cleared; a stale band over rows never asked
    \\                       for is damage that went missing
    \\  screen refresh [y rows]  the picture to the panel again, whatever
    \\                       anything thinks has changed: a band of the glass
    \\                       that is out of date clears if the rows were never
    \\                       handed on, and stays if the buffer itself is wrong
    \\  screen reset|realign  clear the counters; put the stream back in step
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const sys = shell.base.iface();
    const rtg_lib = sys.OpenLibrary(rtg.RTGNAME, 1) orelse {
        shell.print("can't open %s\n", .{rtg.RTGNAME});
        return;
    };
    defer sys.CloseLibrary(rtg_lib);
    const rb: *RtgBase = @ptrCast(@alignCast(rtg_lib));
    const display = find(rb) orelse {
        shell.print("the panel did not come up\n", .{});
        return;
    };
    const word = args.next() orelse return state(shell, display);
    if (_shell.same(word, "ruler")) return ruler(shell, display);
    if (_shell.same(word, "shift")) {
        const start = display.count(tags.RTGCTRL_RGB_SHIFT, try args.signed());
        shell.print("the active area starts %d pixels into the line (of %d)\n", .{ start, display.count(tags.RTGCTRL_RGB_LINE_TOTAL, 0) });
        return;
    }
    if (_shell.same(word, "reset")) {
        _ = display.ask(rtg.boards.RTGCTRL_RESET_STATS, 0);
        shell.print("counters cleared\n", .{});
        return;
    }
    if (_shell.same(word, "realign")) {
        _ = display.ask(tags.RTGCTRL_RGB_REALIGN, 0);
        shell.print("the stream is put back in step at the next blanking\n", .{});
        return;
    }
    if (_shell.same(word, "rows")) return askedRows(shell, display, args);
    if (_shell.same(word, "refresh")) return refresh(shell, display, args);
    var percent: u32 = 0;
    if (_shell.same(word, "on")) {
        percent = 100;
    } else if (!_shell.same(word, "off")) {
        percent = _shell.parseNumber(word) orelse return error.Usage;
        if (percent > 100) return error.Usage;
    }
    if (rb.SetBoardBrightness(display.board, percent) != rtg.errors.RTGERR_OK) shell.print("the expander does not answer\n", .{});
}

/// The board graphics.library made, and the picture it shows. Null when
/// there is no display or nothing is shown.
fn find(rb: *RtgBase) ?Display {
    const board = rb.FindBoard(sdk.graphics.DISPLAY_BOARD) orelse return null;
    const bitmap = board.showing orelse return null;
    const pixels = bitmap.pixels orelse return null;
    return .{
        .rb = rb,
        .board = board,
        .shown = .{ .pixels = @ptrCast(@alignCast(pixels)), .width = bitmap.width, .height = bitmap.height, .pitch = bitmap.pitch },
    };
}

/// The mode, the backlight and the counters.
fn state(shell: *Shell, display: Display) void {
    const shown = display.shown;
    const counters = display.stats();
    // A display that streams has a stream to report on. One that is
    // written when something changes - a controller panel on a bus, the
    // emulator's window - has none of the stream's counters, and printing
    // them as zeroes would read as a panel that is doing nothing rather
    // than one that is not there.
    if (display.board.info.flags & rtg.boards.RTGBF_STREAMING == 0) {
        shell.print("%dx%d RGB565, written when it changes, framebuffer 0x%08x\n%d updates, %d failed, %d bands underrun; %d refreshes (%d dropped), %d rows asked for\n", .{
            shown.width,
            shown.height,
            @as(u32, @intCast(@intFromPtr(shown.pixels))),
            counters.frames,
            counters.failed_sends,
            counters.underruns,
            counters.refreshes,
            counters.refreshes_dropped,
            counters.rows_refreshed,
        });
        return;
    }
    const pixel_clock = _shell.partFact(shell, sdk.expansion.systemtags.PARTKIND_PANEL, tags.RTGA_RGB_PixelClock, 0);
    shell.print("%dx%d RGB565 on the panel at %d MHz, framebuffer 0x%08x in PSRAM, backlight %d%%, %d frames, active area at %d,\n%d late (worst %d us past the frame), %d starved, %d realigns,\ngaps: %d over a line, %d over 5 us, last %d us, worst %d us\n%d bufferfuls copied, %d of them late; at the blanking the copy is on stretch %d, which has moved %d\n", .{
        shown.width,
        shown.height,
        @as(u32, @intCast(pixel_clock / 1_000_000)),
        @as(u32, @intCast(@intFromPtr(shown.pixels))),
        display.rb.BoardBrightness(display.board),
        counters.frames,
        display.count(tags.RTGCTRL_RGB_ACTIVE_START, 0),
        counters.late_frames,
        counters.worst_late_us,
        counters.starved_frames,
        counters.realigns,
        counters.long_gaps,
        counters.slow_gaps,
        counters.last_gap_us,
        counters.worst_gap_us,
        counters.refills,
        counters.late_refills,
        counters.stream_at,
        counters.total_walk,
    });
}

/// Which rows have been handed on since the marks were cleared, or the
/// marks cleared. A stale band over rows that were never asked for is
/// damage that went missing; one over rows that were asked for is a
/// buffer with the wrong pixels in it.
fn askedRows(shell: *Shell, display: Display, args: *Args) !void {
    if (args.peek()) |next| {
        if (_shell.same(next, "forget")) {
            _ = display.ask(tags.RTGCTRL_DCS_FORGET_ROWS, 0);
            shell.print("the marks are cleared\n", .{});
            return;
        }
    }
    const height = display.shown.height;
    var row: u32 = 0;
    var runs: u32 = 0;
    var missing: u32 = 0;
    while (row < height) {
        if (asked(display, row)) {
            row += 1;
            continue;
        }
        const from = row;
        while (row < height and !asked(display, row)) row += 1;
        missing += row - from;
        if (runs < 12) shell.print("%s%d-%d", .{ if (runs == 0) "never asked: " else ", ", from, row - 1 });
        runs += 1;
    }
    if (runs == 0) {
        shell.print("every row of %d has been asked for\n", .{height});
    } else {
        shell.print("%s(%d rows in %d runs)\n", .{ if (runs > 12) ", ..." else "", missing, runs });
    }
}

/// Whether a picture row has been asked for since the marks were cleared.
fn asked(display: Display, row: u32) bool {
    return display.ask(tags.RTGCTRL_DCS_ROW_ASKED, @intCast(row)) == 1;
}

/// The picture to the panel again, whatever anything thinks has changed:
/// a band of the glass that is out of date clears if the rows were drawn
/// and never handed on, and stays if what is in the buffer is wrong - the
/// first is damage that went missing, the second a drawing fault, and they
/// look identical on the glass. `screen refresh <y> <rows>` sends only
/// those rows, so the same pixels can be covered as one whole or as two
/// halves: a fault that clears only for the whole is in the sending of a
/// part.
fn refresh(shell: *Shell, display: Display, args: *Args) !void {
    const y = try args.numberOr(0);
    const count = try args.numberOr(0);
    const before = display.stats();
    if (!display.refresh(y, count)) {
        shell.print("nothing to refresh: no buffer shown\n", .{});
        return;
    }
    const after = display.stats();
    shell.print("rows %d for %d sent again (%d updates, %d failed)\n", .{
        y,
        if (count == 0) display.shown.height else count,
        after.frames - before.frames,
        after.failed_sends - before.failed_sends,
    });
}

/// A scale across the screen, so the picture can be measured rather than
/// described. A line every 64 pixels, a wider one every 256 with as many
/// blocks stacked under it as it is 256s from the start, and a red block
/// over the first 64 pixels: whichever of those sits at the left edge of
/// the glass is how far the picture has moved. The marks are counted
/// rather than read: nothing here draws text.
fn ruler(shell: *Shell, display: Display) void {
    const shown = display.shown;
    fillRect(shown, 0, 0, shown.width, shown.height, rgb565(0, 0, 0x40));
    var x: u32 = 0;
    while (x < shown.width) : (x += 64) {
        const wide = x % 256 == 0;
        const mark = if (wide) rgb565(0xFF, 0xFF, 0xFF) else rgb565(0x60, 0x60, 0x60);
        fillRect(shown, x, 0, if (wide) 2 else 1, shown.height, mark);
        if (!wide) continue;
        // As many blocks as this mark is 256s along: the first has none,
        // and has the red block instead.
        var block: u32 = 0;
        while (block < x / 256) : (block += 1) {
            fillRect(shown, x + 6, 20 + block * 14, 8, 8, rgb565(0xFF, 0xFF, 0));
        }
    }
    // A red block in the first 64 pixels: whatever is at the very start of
    // the frame, wherever it has ended up on the glass.
    fillRect(shown, 0, 100, 64, 64, rgb565(0xFF, 0, 0));
    _ = display.refresh(0, 0);
    shell.print("a mark every 64 pixels, a wide one every 256 with that many blocks\n", .{});
    shell.print("under it; the red block is 0..64. If its left edge sits x pixels in\n", .{});
    shell.print("from the left of the glass, \"screen shift -x\" brings it back. The\n", .{});
    shell.print("active area starts %d pixels into the line now\n", .{display.count(tags.RTGCTRL_RGB_ACTIVE_START, 0)});
}

/// A colour as the display's RGB565 pixel.
fn rgb565(red: u8, green: u8, blue: u8) u16 {
    return @as(u16, red >> 3) << 11 | @as(u16, green >> 2) << 5 | blue >> 3;
}

/// A filled rectangle in the shown picture, clipped to it. What is drawn
/// reaches the glass with the display's next refresh.
fn fillRect(shown: Frame, x: u32, y: u32, w: u32, h: u32, color: u16) void {
    const x0 = @min(x, shown.width);
    const x1 = @min(x +| w, shown.width);
    var row = @min(y, shown.height);
    const y1 = @min(y +| h, shown.height);
    while (row < y1) : (row += 1) {
        const row_pixels: [*]u16 = @ptrCast(@alignCast(@as([*]u8, @ptrCast(shown.pixels)) + @as(usize, row) * shown.pitch));
        @memset(row_pixels[x0..x1], color);
    }
}
