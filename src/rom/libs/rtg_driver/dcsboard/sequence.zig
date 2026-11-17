// SPDX-License-Identifier: MPL-2.0
//! What the DCS board driver works out without touching a bus, so the host
//! tests can hold it: the window a rectangle of the picture is sent in,
//! and the pixels turned the way the bus carries them and the way the
//! panel lies. The controller's bring-up is walked by the library
//! (`RunPanelSequence`).

const std = @import("std");

/// A rectangle of the picture or of the panel: columns `left` up to
/// `right`, rows `top` up to `end`.
pub const Box = struct {
    left: u32,
    top: u32,
    right: u32,
    end: u32,

    pub fn columns(box: Box) u32 {
        return box.right - box.left;
    }

    pub fn rows(box: Box) u32 {
        return box.end - box.top;
    }
};

/// The smallest rectangle of whole alignments, each way, that holds
/// `box` on a panel `width` by `height`: what a controller takes as a
/// window. The panel's sides are whole alignments themselves.
pub fn aligned(box: Box, width: u32, height: u32, alignment: u32) Box {
    const step = @max(alignment, 1);
    return .{
        .left = box.left / step * step,
        .top = box.top / step * step,
        .right = @min((box.right + step - 1) / step * step, width),
        .end = @min((box.end + step - 1) / step * step, height),
    };
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
/// length; `into` and `from` start on four bytes, and may be the same
/// run: a band is turned round where it lies.
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
        const low = from[last];
        into[last] = from[last + 1];
        into[last + 1] = low;
    }
}

/// A quarter turn, for a picture on a panel whose controller cannot
/// exchange its own axes: the picture is the panel's size the other way
/// round, and every band is turned as it is sent.
pub const Turn = enum {
    none,
    /// The picture's left edge lies along the panel's top edge: the
    /// picture's pixel (x, y) is the panel's column `height - 1 - y`,
    /// row `x`.
    clockwise,
    /// Its right edge does: the panel's column `y`, row `width - 1 - x`.
    counter_clockwise,
};

/// Where a rectangle of a turned picture lies on the panel. The picture
/// is `width` by `height`, the panel `height` by `width`.
pub fn onPanel(turn: Turn, box: Box, width: u32, height: u32) Box {
    return switch (turn) {
        .none => box,
        .clockwise => .{ .left = height - box.end, .top = box.left, .right = height - box.top, .end = box.right },
        .counter_clockwise => .{ .left = box.top, .top = width - box.right, .right = box.end, .end = width - box.left },
    };
}

/// Which rectangle of a turned picture a rectangle of the panel shows:
/// `onPanel` the other way round.
pub fn ofPicture(turn: Turn, box: Box, width: u32, height: u32) Box {
    return switch (turn) {
        .none => box,
        .clockwise => .{ .left = box.top, .top = height - box.right, .right = box.end, .end = height - box.left },
        .counter_clockwise => .{ .left = width - box.end, .top = box.left, .right = width - box.top, .end = box.right },
    };
}

/// A rectangle of the picture, as memory holds RGB565, turned into the
/// band of the panel that shows it, the way the bus sends it, high byte
/// first.
///
/// A panel row is a column of the picture. The picture's rows are walked
/// along, so the reads are consecutive; the writes are the strided ones,
/// and they go into the band, which is internal memory and has no cache
/// to miss.
///
/// INPUTS:
/// - `into` - the band: `width` rows of `height` pixels, the panel's.
/// - `from` - the picture's rectangle: `height` rows of `width` pixels,
///   a row straight after the other.
/// - `width`, `height` - the rectangle's size in the picture.
/// - `turn` - which way the picture lies on the panel; not `.none`.
pub fn turnInto(into: []u8, from: []const u8, width: u32, height: u32, turn: Turn) void {
    const clockwise = turn == .clockwise;
    // A panel row is `height` pixels.
    const row_bytes = height * 2;
    for (0..height) |y| {
        // Clockwise the picture's last row is the panel's first column.
        const column = if (clockwise) height - 1 - y else y;
        const row = from[y * width * 2 ..];
        for (0..width) |x| {
            // The other way round its last column is the panel's first
            // row.
            const panel_row = if (clockwise) x else width - 1 - x;
            const at = panel_row * row_bytes + column * 2;
            into[at] = row[x * 2 + 1];
            into[at + 1] = row[x * 2];
        }
    }
}

test "a window: whole alignments around the rectangle, each way" {
    // A panel 320 by 480 whose windows keep to fours.
    try std.testing.expectEqual(Box{ .left = 8, .top = 8, .right = 16, .end = 16 }, aligned(.{ .left = 9, .top = 9, .right = 14, .end = 14 }, 320, 480, 4));
    try std.testing.expectEqual(Box{ .left = 0, .top = 476, .right = 320, .end = 480 }, aligned(.{ .left = 0, .top = 478, .right = 320, .end = 480 }, 320, 480, 4));
    // One that is whole already stays, and so does any with no alignment.
    try std.testing.expectEqual(Box{ .left = 4, .top = 8, .right = 12, .end = 16 }, aligned(.{ .left = 4, .top = 8, .right = 12, .end = 16 }, 320, 480, 4));
    try std.testing.expectEqual(Box{ .left = 9, .top = 9, .right = 14, .end = 14 }, aligned(.{ .left = 9, .top = 9, .right = 14, .end = 14 }, 320, 480, 1));
}

test "a turned picture's rectangle on the panel, and back" {
    // A picture 480 by 320 on a panel 320 wide and 480 tall. Its first
    // 16 rows are the panel's last 16 columns turned clockwise, its
    // first 16 the other way round; its columns are the panel's rows.
    const top_left = Box{ .left = 0, .top = 0, .right = 100, .end = 16 };
    try std.testing.expectEqual(Box{ .left = 304, .top = 0, .right = 320, .end = 100 }, onPanel(.clockwise, top_left, 480, 320));
    try std.testing.expectEqual(Box{ .left = 0, .top = 380, .right = 16, .end = 480 }, onPanel(.counter_clockwise, top_left, 480, 320));
    try std.testing.expectEqual(top_left, onPanel(.none, top_left, 480, 320));
    // And every rectangle comes back as itself.
    for ([_]Turn{ .none, .clockwise, .counter_clockwise }) |turn| {
        for ([_]Box{ top_left, .{ .left = 7, .top = 300, .right = 480, .end = 320 }, .{ .left = 479, .top = 0, .right = 480, .end = 1 } }) |box| {
            try std.testing.expectEqual(box, ofPicture(turn, onPanel(turn, box, 480, 320), 480, 320));
        }
    }
}

test "a rectangle turned into its band: every pixel where the panel has it, both ways round" {
    // A rectangle 3 wide and 2 tall. Each pixel says where it is: 0xRRCC,
    // the row and the column, low byte first as memory holds RGB565.
    var picture: [2 * 3 * 2]u8 = undefined;
    for (0..2) |r| for (0..3) |c| {
        picture[(r * 3 + c) * 2] = @intCast(c);
        picture[(r * 3 + c) * 2 + 1] = @intCast(r);
    };
    // Its band is 3 rows of 2 pixels, high byte first.
    var band: [3 * 2 * 2]u8 = undefined;

    // Clockwise: the panel's row is the picture's column, its first
    // column the picture's last row.
    turnInto(&band, &picture, 3, 2, .clockwise);
    try std.testing.expectEqualSlices(u8, &.{
        1, 0, 0, 0,
        1, 1, 0, 1,
        1, 2, 0, 2,
    }, &band);

    // The other way round: its first row is the picture's last column,
    // its first column the picture's first row.
    turnInto(&band, &picture, 3, 2, .counter_clockwise);
    try std.testing.expectEqualSlices(u8, &.{
        0, 2, 1, 2,
        0, 1, 1, 1,
        0, 0, 1, 0,
    }, &band);

    // Each agrees with where `onPanel` puts a single pixel.
    for ([_]Turn{ .clockwise, .counter_clockwise }) |turn| {
        turnInto(&band, &picture, 3, 2, turn);
        for (0..2) |r| for (0..3) |c| {
            const at = onPanel(turn, .{ .left = @intCast(c), .top = @intCast(r), .right = @intCast(c + 1), .end = @intCast(r + 1) }, 3, 2);
            const pixel = band[(at.top * 2 + at.left) * 2 ..];
            try std.testing.expectEqual(@as(u8, @intCast(r)), pixel[0]);
            try std.testing.expectEqual(@as(u8, @intCast(c)), pixel[1]);
        };
    }
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
    // Where they lie, the odd pixel at the end too, and one pixel alone.
    swapPixels(&from, &from);
    try std.testing.expectEqualSlices(u8, &into, &from);
    var one: [2]u8 align(4) = .{ 0x00, 0xF8 };
    swapPixels(&one, &one);
    try std.testing.expectEqualSlices(u8, &.{ 0xF8, 0x00 }, &one);
}
