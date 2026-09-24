// SPDX-License-Identifier: MPL-2.0
//! What the DCS board driver works out without touching a bus, so the host
//! tests can hold it: the steps of a controller's bring-up, the window a
//! refresh sends, and the pixels turned the way the bus carries them.
//!
//! A bring-up is a run of bytes, step after step: the command, the number
//! of parameters, the milliseconds to wait after it, then the parameters.
//! Bytes are what a board's description can write down as they are in the
//! maker's table, and what a tag can point at.

const std = @import("std");
const step = @import("sdk").rtg.tags.dcsStep;

/// One step of a bring-up.
pub const Step = struct {
    cmd: u8,
    delay_ms: u8,
    params: []const u8,
};

/// The steps of `bytes`, in order.
pub const Steps = struct {
    bytes: []const u8,
    at: usize = 0,

    /// The next step, or null at the end - or at a step that runs past the
    /// end, which `valid` refuses before anything is sent.
    pub fn next(steps: *Steps) ?Step {
        const rest = steps.bytes[steps.at..];
        if (rest.len < 3) return null;
        const count = rest[1];
        if (rest.len < 3 + @as(usize, count)) return null;
        steps.at += 3 + @as(usize, count);
        return .{ .cmd = rest[0], .delay_ms = rest[2], .params = rest[3..][0..count] };
    }
};

/// Whether `bytes` is whole steps and nothing else.
pub fn valid(bytes: []const u8) bool {
    var steps: Steps = .{ .bytes = bytes };
    while (steps.next()) |_| {}
    return steps.at == bytes.len;
}

/// Rows `top` to `end` (one past), the smallest run of whole alignments
/// that holds rows `y` to `y + rows` of a picture `height` rows tall.
/// `rows` 0 is all of them.
pub const Window = struct { top: u32, end: u32 };

pub fn window(y: u32, rows: u32, height: u32, alignment: u32) Window {
    if (rows == 0) return .{ .top = 0, .end = height };
    const step_rows = @max(alignment, 1);
    const top = @min(y, height) / step_rows * step_rows;
    const last = @min(y +| rows, height);
    const end = @min((last + step_rows - 1) / step_rows * step_rows, height);
    return .{ .top = top, .end = end };
}

/// How many rows of `row_bytes` fit in `bytes`, as a whole number of
/// alignments. At least one alignment, which the caller makes room for.
pub fn bandRows(bytes: u32, row_bytes: u32, alignment: u32) u32 {
    const step_rows = @max(alignment, 1);
    const fit = bytes / @max(row_bytes, 1);
    return @max(fit / step_rows * step_rows, step_rows);
}

/// RGB565 as memory holds it, low byte first, into the order the bus
/// sends it, high byte first. Both runs are whole pixels and the same
/// length; `into` and `from` start on four bytes.
pub fn swapPixels(into: []align(4) u8, from: []align(4) const u8) void {
    const words = from.len / 4;
    const out: [*]u32 = @ptrCast(into.ptr);
    const in: [*]const u32 = @ptrCast(from.ptr);
    for (0..words) |i| {
        const pair = in[i];
        out[i] = ((pair & 0x00FF_00FF) << 8) | ((pair >> 8) & 0x00FF_00FF);
    }
    if (from.len % 4 != 0) {
        const last = words * 4;
        into[last] = from[last + 1];
        into[last + 1] = from[last];
    }
}

/// A quarter turn, for a picture on a panel whose controller cannot
/// exchange its own axes: the picture is the panel's size the other way
/// round, and every band is turned as it is sent.
pub const Turn = enum {
    none,
    /// The picture's left edge lies along the panel's top edge.
    clockwise,
    /// Its right edge does.
    counter_clockwise,
};

/// What a turned picture is, for the rows taken out of it.
pub const Turned = struct {
    /// The picture: where it starts, its bytes a row, and the panel it is
    /// turned onto.
    pixels: [*]const u8,
    pitch: u32,
    panel_width: u32,
    panel_height: u32,
    turn: Turn,
};

/// Rows `y` to `y + rows` of a turned picture are a strip of the panel's
/// columns: which ones, as whole alignments. `rows` 0 is all of them.
pub fn turnedColumns(turn: Turn, y: u32, rows: u32, panel_width: u32, alignment: u32) Window {
    if (rows == 0) return .{ .top = 0, .end = panel_width };
    const first = @min(y, panel_width);
    const last = @min(y +| rows, panel_width);
    // Turned clockwise, the picture's first row is the panel's last column.
    const from = if (turn == .clockwise) panel_width - last else first;
    const to = if (turn == .clockwise) panel_width - first else last;
    const step_columns = @max(alignment, 1);
    return .{
        .top = from / step_columns * step_columns,
        .end = @min((to + step_columns - 1) / step_columns * step_columns, panel_width),
    };
}

/// One row of the panel out of a turned picture, written the way the bus
/// sends it, high byte first: panel row `row`, its columns `first` to
/// `first + count`.
///
/// A panel row runs down a column of the picture, which is what a turned
/// picture costs: a read a pixel, a pitch apart, where an upright one
/// reads along the row.
///
/// This is the mapping written out one row at a time, and it is what
/// `turnedBand` is checked against. The driver sends bands, so it is
/// `turnedBand` that runs on the machine.
pub fn turnedRow(into: []u8, picture: Turned, row: u32, first: u32, count: u32) void {
    const clockwise = picture.turn == .clockwise;
    // The picture column this panel row is.
    const column = if (clockwise) row else picture.panel_height - 1 - row;
    const at = picture.pixels + @as(usize, column) * 2;
    for (0..count) |i| {
        const panel_column = first + @as(u32, @intCast(i));
        // Clockwise, the panel's first column is the picture's last row.
        const picture_row = if (clockwise) picture.panel_width - 1 - panel_column else panel_column;
        const from = at + @as(usize, picture_row) * picture.pitch;
        into[i * 2] = from[1];
        into[i * 2 + 1] = from[0];
    }
}

/// A whole band of panel rows at once, which is what the driver sends.
///
/// It writes exactly what `turnedRow` does for each of its rows, and the
/// only difference is the order the two loops are nested in - and that
/// order is the whole cost of a turned picture.
///
/// A panel row is a column of the picture. Walking a panel row therefore
/// walks *down* the picture, a pitch apart, and every pixel read is a
/// cache line fetched for two bytes of it. Walking a panel *column*
/// instead walks *along* one picture row, so the reads are consecutive
/// and a line fetched is a line used. The writes become the strided
/// ones, and they go into the band, which is internal memory and has no
/// cache to miss.
///
/// INPUTS:
/// - `into` - the band: `rows` rows of `columns * 2` bytes.
/// - `picture` - the bitmap and which way it is turned.
/// - `first_row` - the panel row the band starts at.
/// - `rows` - the panel rows in the band.
/// - `first_column` - the panel column the strip starts at.
/// - `columns` - the panel columns in the strip.
pub fn turnedBand(
    into: []u8,
    picture: Turned,
    first_row: u32,
    rows: u32,
    first_column: u32,
    columns: u32,
) void {
    const clockwise = picture.turn == .clockwise;
    const row_bytes = columns * 2;
    for (0..columns) |i| {
        const panel_column = first_column + @as(u32, @intCast(i));
        // Clockwise, the panel's first column is the picture's last row.
        const picture_row = if (clockwise) picture.panel_width - 1 - panel_column else panel_column;
        const from = picture.pixels + @as(usize, picture_row) * picture.pitch;
        var at = i * 2;
        for (0..rows) |j| {
            const panel_row = first_row + @as(u32, @intCast(j));
            // The picture column this panel row is. One step of the
            // panel row is one pixel along the picture row above.
            const column = if (clockwise) panel_row else picture.panel_height - 1 - panel_row;
            const pixel = from + @as(usize, column) * 2;
            into[at] = pixel[1];
            into[at + 1] = pixel[0];
            at += row_bytes;
        }
    }
}

test "steps: walked in order, and a short one refused" {
    const bytes = step(0xF1, 0, .{0x00}) ++ step(0x11, 120, .{}) ++ step(0x2A, 0, .{ 0x00, 0x00, 0x01, 0x3F });
    try std.testing.expect(valid(&bytes));
    var steps: Steps = .{ .bytes = &bytes };
    const first = steps.next().?;
    try std.testing.expectEqual(@as(u8, 0xF1), first.cmd);
    try std.testing.expectEqualSlices(u8, &.{0x00}, first.params);
    const second = steps.next().?;
    try std.testing.expectEqual(@as(u8, 0x11), second.cmd);
    try std.testing.expectEqual(@as(u8, 120), second.delay_ms);
    try std.testing.expectEqual(@as(usize, 0), second.params.len);
    const third = steps.next().?;
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x01, 0x3F }, third.params);
    try std.testing.expect(steps.next() == null);

    // Four parameters promised, three there.
    try std.testing.expect(!valid(&[_]u8{ 0x2A, 4, 0, 1, 2, 3 }));
}

test "window: whole alignments around the rows, all of them for 0" {
    try std.testing.expectEqual(Window{ .top = 0, .end = 480 }, window(0, 0, 480, 4));
    try std.testing.expectEqual(Window{ .top = 8, .end = 16 }, window(9, 5, 480, 4));
    try std.testing.expectEqual(Window{ .top = 476, .end = 480 }, window(478, 10, 480, 4));
    try std.testing.expectEqual(Window{ .top = 9, .end = 14 }, window(9, 5, 480, 1));
}

test "bands: whole alignments that fit, never fewer than one" {
    try std.testing.expectEqual(@as(u32, 24), bandRows(16384, 640, 4));
    try std.testing.expectEqual(@as(u32, 16), bandRows(16384, 960, 4));
    try std.testing.expectEqual(@as(u32, 4), bandRows(100, 960, 4));
}

test "pixels: each one's two bytes exchanged" {
    var from: [6]u8 align(4) = .{ 0x1F, 0xF8, 0xE0, 0x07, 0x34, 0x12 };
    var into: [6]u8 align(4) = undefined;
    swapPixels(&into, &from);
    try std.testing.expectEqualSlices(u8, &.{ 0xF8, 0x1F, 0x07, 0xE0, 0x12, 0x34 }, &into);
}

test "turned columns: the picture's rows are the panel's columns" {
    // A 480x320 picture on a panel 320 wide: rows 0-15 of the picture are
    // the panel's last 16 columns turned clockwise, its first 16 the other
    // way round.
    try std.testing.expectEqual(Window{ .top = 304, .end = 320 }, turnedColumns(.clockwise, 0, 16, 320, 4));
    try std.testing.expectEqual(Window{ .top = 0, .end = 16 }, turnedColumns(.counter_clockwise, 0, 16, 320, 4));
    try std.testing.expectEqual(Window{ .top = 0, .end = 320 }, turnedColumns(.clockwise, 0, 0, 320, 4));
    // Widened to whole alignments at both ends.
    try std.testing.expectEqual(Window{ .top = 4, .end = 12 }, turnedColumns(.counter_clockwise, 5, 5, 320, 4));
}

test "turned rows: a picture read down its columns" {
    // A picture 3 wide and 2 tall, on a panel 2 wide and 3 tall. Each
    // pixel says where it is: 0xRRCC, the row and the column.
    const pitch = 3 * 2;
    var picture: [2 * 3 * 2]u8 align(4) = undefined;
    for (0..2) |r| for (0..3) |c| {
        const at = r * pitch + c * 2;
        // Low byte first, as memory holds RGB565.
        picture[at] = @intCast(c);
        picture[at + 1] = @intCast(r);
    };
    const turned: Turned = .{
        .pixels = &picture,
        .pitch = pitch,
        .panel_width = 2,
        .panel_height = 3,
        .turn = .clockwise,
    };
    var row: [4]u8 = undefined;
    // Panel row 0 is the picture's column 0, bottom row first.
    turnedRow(&row, turned, 0, 0, 2);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x00, 0x00 }, &row);
    // Panel row 2 is the picture's column 2.
    turnedRow(&row, turned, 2, 0, 2);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x00, 0x02 }, &row);
    // The other way round, panel row 0 is the picture's last column.
    var back = turned;
    back.turn = .counter_clockwise;
    turnedRow(&row, back, 0, 0, 2);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x02, 0x01, 0x02 }, &row);
}

test "a turned band is what the rows of it are, both ways round" {
    // A picture wide enough that a wrong loop order shows: every pixel
    // is its own value, so a single one out of place fails.
    const width = 12;
    const height = 8;
    const pitch = width * 2;
    var pixels: [height * pitch]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const at = y * pitch + x * 2;
            pixels[at] = @intCast(y * width + x);
            pixels[at + 1] = @intCast(0x80 + y);
        }
    }

    for ([_]Turn{ .clockwise, .counter_clockwise }) |turn| {
        const picture: Turned = .{
            .pixels = &pixels,
            .pitch = pitch,
            // The panel is the picture turned, so its sides are swapped.
            .panel_width = height,
            .panel_height = width,
            .turn = turn,
        };
        // A band that is neither the whole panel nor aligned to its
        // start, in both directions.
        const first_row = 3;
        const rows = 5;
        const first_column = 2;
        const columns = 4;

        var band: [rows * columns * 2]u8 = @splat(0);
        turnedBand(&band, picture, first_row, rows, first_column, columns);

        var expected: [rows * columns * 2]u8 = @splat(0xFF);
        for (0..rows) |j| {
            const into = expected[j * columns * 2 ..][0 .. columns * 2];
            turnedRow(into, picture, first_row + @as(u32, @intCast(j)), first_column, columns);
        }
        try std.testing.expectEqualSlices(u8, &expected, &band);
    }
}

test "a turned band of one row, and of the whole panel" {
    const width = 6;
    const height = 4;
    const pitch = width * 2;
    var pixels: [height * pitch]u8 = undefined;
    for (&pixels, 0..) |*byte, i| byte.* = @intCast(i);

    const picture: Turned = .{
        .pixels = &pixels,
        .pitch = pitch,
        .panel_width = height,
        .panel_height = width,
        .turn = .clockwise,
    };

    // One row of the band is one turnedRow.
    var one: [height * 2]u8 = @splat(0);
    turnedBand(&one, picture, 2, 1, 0, height);
    var same: [height * 2]u8 = @splat(0xFF);
    turnedRow(&same, picture, 2, 0, height);
    try std.testing.expectEqualSlices(u8, &same, &one);

    // And the whole panel at once.
    var all: [width * height * 2]u8 = @splat(0);
    turnedBand(&all, picture, 0, width, 0, height);
    var rows: [width * height * 2]u8 = @splat(0xFF);
    for (0..width) |j| {
        turnedRow(rows[j * height * 2 ..][0 .. height * 2], picture, @intCast(j), 0, height);
    }
    try std.testing.expectEqualSlices(u8, &rows, &all);
}
