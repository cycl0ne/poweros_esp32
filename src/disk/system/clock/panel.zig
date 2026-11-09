// SPDX-License-Identifier: MIT
//! The clock in figures: the hours and minutes in seven-segment figures on
//! a dark iron panel, the seconds smaller beside them, a colon that blinks
//! each half second, AM or PM above the seconds on a twelve-hour clock,
//! and the date along the panel's foot.
//!
//! A figure leans a little forward. Its lit segments are blue, light at
//! their top, with a glow round them; the others are there faintly, as
//! the segments of a display that is off are. Each figure is a picture
//! worked out once for its size - every figure, a blank one and the colon
//! lit and unlit - and a frame of the clock puts them down; nothing is
//! worked out again until the size changes.

const sdk = @import("sdk");
const graphics = sdk.graphics;
const shapes = sdk.gadgets.shapes;
const support = sdk.gadgets.support;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const picture = @import("picture.zig");
const time = @import("time.zig");
const Surface = picture.Surface;
const Shape = picture.Shape;
const Pen = graphics.Pen;

const blue = shapes.tones(.blue);
const iron = shapes.tones(.iron);
const metal = shapes.tones(.metal);

/// What an unlit segment is: white, faintly.
const unlit: Pen = 0x1AFF_FFFF;

/// A figure's measures in its square, in design units: where it starts,
/// how tall and wide it is, how thick a segment, the gap between two, and
/// how far it leans for each unit up.
const left: f32 = 5.0;
const top: f32 = 4.0;
const tall: f32 = 92.0;
const wide: f32 = 0.54 * tall;
const thick: f32 = 0.115 * tall;
const gap: f32 = 1.3;
const lean: f32 = 0.07;

/// How far along the next figure starts, and the colon's next one, in
/// parts of a figure's square.
const advance: f32 = 0.62;
const colon_advance: f32 = 0.26;
/// The seconds' figures, in parts of the hours'.
const small_part: f32 = 0.5;
/// The space before the seconds, or before AM and PM without them.
const seconds_gap: f32 = 0.06;

/// A figure's pictures at one size: 0 to 9, a blank one, and the colon
/// lit and unlit.
pub const Glyphs = struct {
    size: i32 = 0,
    figures: [11]?*Surface = @splat(null),
    colon: [2]?*Surface = @splat(null),

    pub const blank = 10;

    /// The pictures for figures `size` pixels tall, made and painted;
    /// false without the memory for them.
    pub fn fit(own: *Glyphs, gb: *GraphicsBase, rp: *graphics.RastPort, size: i32, with_colon: bool) bool {
        if (size == own.size and own.figures[0] != null and (own.colon[0] != null) == with_colon) return true;
        own.free(gb);
        if (size < 8) return false;
        for (&own.figures, 0..) |*figure, at| {
            figure.* = picture.make(gb, size, size) orelse {
                own.free(gb);
                return false;
            };
            paintFigure(gb, rp, figure.*.?, size, if (at == blank) 0 else time.segments(@intCast(at)));
        }
        if (with_colon) for (&own.colon, 0..) |*colon, which| {
            colon.* = picture.make(gb, size, size) orelse {
                own.free(gb);
                return false;
            };
            paintColon(gb, rp, colon.*.?, size, which == 1);
        };
        own.size = size;
        return true;
    }

    pub fn free(own: *Glyphs, gb: *GraphicsBase) void {
        for (own.figures) |figure| gb.FreeBitMap(figure);
        for (own.colon) |colon| gb.FreeBitMap(colon);
        own.* = .{};
    }
};

/// (`x`, `y`) of a figure's square, leaning: the higher, the farther
/// right.
fn leaned(x: f32, y: f32) [2]f32 {
    return .{ x + (top + tall - y) * lean, y };
}

/// The seven segments' corners, in the order `time.segments` numbers them.
fn segmentCorners() [7][6][2]f32 {
    const half = thick / 2;
    const x_left = left + half;
    const x_right = left + wide - half;
    const y_top = top + half;
    const y_middle = top + tall / 2;
    const y_bottom = top + tall - half;
    return .{
        across(x_left, x_right, y_top, half),
        down(x_right, y_top, y_middle, half),
        down(x_right, y_middle, y_bottom, half),
        across(x_left, x_right, y_bottom, half),
        down(x_left, y_middle, y_bottom, half),
        down(x_left, y_top, y_middle, half),
        across(x_left, x_right, y_middle, half),
    };
}

/// A segment lying from `x0` to `x1` at `y`, pointed at both ends.
fn across(x0: f32, x1: f32, y: f32, half: f32) [6][2]f32 {
    const a = x0 + gap;
    const b = x1 - gap;
    return .{
        leaned(a, y), leaned(a + half, y - half), leaned(b - half, y - half),
        leaned(b, y), leaned(b - half, y + half), leaned(a + half, y + half),
    };
}

/// A segment standing from `y0` to `y1` at `x`, pointed at both ends.
fn down(x: f32, y0: f32, y1: f32, half: f32) [6][2]f32 {
    const a = y0 + gap;
    const b = y1 - gap;
    return .{
        leaned(x, a), leaned(x + half, a + half), leaned(x + half, b - half),
        leaned(x, b), leaned(x - half, b - half), leaned(x - half, a + half),
    };
}

/// A lit shape: two rings of glow round it, then it, light at its top.
/// Each segment on its own, so that each is worked out over its own box.
fn lit(p: *shapes.Painter, shape: Shape, scale: f32) void {
    p.fill(shape.inset(-3.0 * scale), .{ .colour = shapes.withAlpha(blue.base, 0x18) });
    p.fill(shape.inset(-1.5 * scale), .{ .colour = shapes.withAlpha(blue.base, 0x30) });
    p.fill(shape, shapes.downward(blue.light, blue.base));
}

fn paintFigure(gb: *GraphicsBase, rp: *graphics.RastPort, into: *Surface, size: i32, on: u7) void {
    var p = picture.painter(gb, rp, into, size);
    defer p.end();
    const scale = @as(f32, @floatFromInt(size)) / 100;
    const corners = segmentCorners();
    for (corners, 0..) |segment, at| {
        const shape = picture.edges(size, &segment, 0, 0);
        if (on & (@as(u7, 1) << @intCast(at)) != 0) lit(&p, shape, scale) else p.fill(shape, .{ .colour = unlit });
    }
}

fn paintColon(gb: *GraphicsBase, rp: *graphics.RastPort, into: *Surface, size: i32, on: bool) void {
    var p = picture.painter(gb, rp, into, size);
    defer p.end();
    const scale = @as(f32, @floatFromInt(size)) / 100;
    for ([_]f32{ 0.31, 0.71 }) |down_by| {
        const middle = leaned(left + 6, top + tall * down_by);
        const half = thick / 2;
        const dot = Shape{ .box = .{
            .x0 = (middle[0] - half) * scale,
            .y0 = (middle[1] - half) * scale,
            .x1 = (middle[0] + half) * scale,
            .y1 = (middle[1] + half) * scale,
            .radius = half * 0.6 * scale,
        } };
        if (on) lit(&p, dot, scale) else p.fill(dot, .{ .colour = unlit });
    }
}

/// Where everything goes on a panel of a window's inside.
pub const Layout = struct {
    /// The panel, its corners rounded by `radius`.
    panel: graphics.Rect,
    radius: i32,
    /// The hours' figures' size and the seconds'; 0 for the seconds
    /// when they are not shown.
    big: i32,
    small: i32,
    /// The squares' left edges: the hours, the colon, the minutes, the
    /// seconds.
    x: [7]i32,
    y_big: i32,
    y_small: i32,
    /// AM or PM: where its text starts and where its top is.
    marker_x: i32,
    marker_y: i32,
    /// The date's middle across and its top.
    date_middle: i32,
    date_y: i32,

    /// The inside `width` by `height`, with the seconds or not, AM and
    /// PM `marker` pixels wide (0 for none), and the date's lines
    /// `date_height` high (0 for no date). The figures as large as fit.
    pub fn of(width: i32, height: i32, seconds: bool, marker: i32, date_height: i32) Layout {
        const margin = @max(4, @divTrunc(@min(width, height), 18));
        const panel = graphics.Rect{ .min_x = margin, .min_y = margin, .max_x = @max(margin + 1, width - margin), .max_y = @max(margin + 1, height - margin) };
        const panel_width = panel.max_x - panel.min_x;
        const panel_height = panel.max_y - panel.min_y;
        const pad = @max(4, @divTrunc(panel_height, 10));
        const room_width: f32 = @floatFromInt(@max(1, panel_width - 2 * pad - if (seconds) 0 else marker));
        const room_height: f32 = @floatFromInt(@max(1, panel_height - 2 * pad - date_height));
        // How wide the figures are, in their size: four, the colon, and
        // the seconds' two or the space before AM and PM.
        const figures_end = 3 * advance + colon_advance + 0.61;
        const across_all: f32 = if (seconds) figures_end + seconds_gap + small_part * (advance + 0.61) else figures_end + if (marker > 0) seconds_gap else 0;
        const size_f = @min(room_height / 0.92, room_width / across_all);
        const big: i32 = @max(8, @as(i32, @intFromFloat(size_f)));
        const big_f: f32 = @floatFromInt(big);
        const small: i32 = if (seconds) @max(8, @as(i32, @intFromFloat(big_f * small_part))) else 0;
        const small_f: f32 = @floatFromInt(small);
        const used: i32 = @intFromFloat(big_f * across_all);
        const x0 = panel.min_x + @divTrunc(panel_width - used - if (seconds) 0 else marker, 2);
        const step = big_f * advance;
        const minutes_at = 2 * step + big_f * colon_advance;
        const seconds_at = minutes_at + step + big_f * (0.61 + seconds_gap);
        // The figures' visible part - 4 to 96 of their square - in the
        // middle of the room above the date.
        const room_top = panel.min_y + pad;
        const room_high = panel_height - 2 * pad - date_height;
        const y_big = room_top + @divTrunc(room_high - big, 2);
        // The seconds' feet on the hours'.
        const y_small = y_big + @as(i32, @intFromFloat((big_f - small_f) * 0.96));
        const marker_x = if (seconds) x0 + @as(i32, @intFromFloat(seconds_at + small_f * 0.08)) else x0 + @as(i32, @intFromFloat(minutes_at + step + big_f * (0.61 + seconds_gap)));
        return .{
            .panel = panel,
            .radius = @max(3, @divTrunc(panel_height, 8)),
            .big = big,
            .small = small,
            .x = .{
                x0,
                x0 + @as(i32, @intFromFloat(step)),
                x0 + @as(i32, @intFromFloat(2 * step - big_f * 0.04)),
                x0 + @as(i32, @intFromFloat(minutes_at)),
                x0 + @as(i32, @intFromFloat(minutes_at + step)),
                x0 + @as(i32, @intFromFloat(seconds_at)),
                x0 + @as(i32, @intFromFloat(seconds_at + small_f * advance)),
            },
            .y_big = y_big,
            .y_small = y_small,
            .marker_x = marker_x,
            .marker_y = y_big + @as(i32, @intFromFloat(big_f * 0.04)),
            .date_middle = panel.min_x + @divTrunc(panel_width, 2),
            .date_y = panel.max_y - pad - date_height + @divTrunc(date_height, 4),
        };
    }
};

/// What the panel shows besides the time.
pub const How = struct {
    seconds: bool,
    /// On a twelve-hour clock: AM or PM, as the locale says them.
    marker: ?[*:0]const u8 = null,
    date: ?[*:0]const u8 = null,
    font_height: i32,
    baseline: i32,
};

pub const Panel = struct {
    big: Glyphs = .{},
    small: Glyphs = .{},

    pub fn free(own: *Panel, gb: *GraphicsBase) void {
        own.big.free(gb);
        own.small.free(gb);
    }

    /// The panel drawn on `rp`, a window's inside `width` by `height`,
    /// at `shown`; false without the memory for its figures, with only
    /// the panel drawn.
    pub fn draw(own: *Panel, gb: *GraphicsBase, rp: *graphics.RastPort, width: i32, height: i32, shown: time.Shown, how: How) bool {
        const marker_width: i32 = if (how.marker) |marker| gb.TextLength(rp, marker, length(marker)) else 0;
        const date_height: i32 = if (how.date != null) how.font_height + @divTrunc(how.font_height, 2) else 0;
        const at = Layout.of(width, height, how.seconds, marker_width, date_height);
        paintPanel(gb, rp, at);
        if (!own.big.fit(gb, rp, at.big, true)) return false;
        if (how.seconds and !own.small.fit(gb, rp, at.small, false)) return false;

        const hour = if (how.marker != null) shown.twelve() else shown.hour;
        const tens = hour / 10;
        put(gb, rp, own.big.figures[if (tens == 0 and how.marker != null) Glyphs.blank else tens], at.x[0], at.y_big);
        put(gb, rp, own.big.figures[hour % 10], at.x[1], at.y_big);
        put(gb, rp, own.big.colon[@intFromBool(!shown.late)], at.x[2], at.y_big);
        put(gb, rp, own.big.figures[shown.minute / 10], at.x[3], at.y_big);
        put(gb, rp, own.big.figures[shown.minute % 10], at.x[4], at.y_big);
        if (how.seconds) {
            put(gb, rp, own.small.figures[shown.second / 10], at.x[5], at.y_small);
            put(gb, rp, own.small.figures[shown.second % 10], at.x[6], at.y_small);
        }
        if (how.marker) |marker| {
            support.setPen(gb, rp, blue.light);
            gb.Move(rp, at.marker_x, at.marker_y + how.baseline);
            gb.Text(rp, marker, length(marker));
        }
        if (how.date) |date| {
            const count = length(date);
            const across_px = gb.TextLength(rp, date, count);
            if (across_px <= at.panel.max_x - at.panel.min_x - 8) {
                support.setPen(gb, rp, metal.base);
                gb.Move(rp, at.date_middle - @divTrunc(across_px, 2), at.date_y + how.baseline);
                gb.Text(rp, date, count);
            }
        }
        return true;
    }
};

fn put(gb: *GraphicsBase, rp: *graphics.RastPort, glyph: ?*Surface, x: i32, y: i32) void {
    picture.putDown(gb, rp, glyph orelse return, x, y);
}

fn length(text: [*:0]const u8) u32 {
    var count: u32 = 0;
    while (text[count] != 0) count += 1;
    return count;
}

/// The panel: iron, darker towards its foot, smooth at its corners, with
/// a thin lighter edge.
fn paintPanel(gb: *GraphicsBase, rp: *graphics.RastPort, at: Layout) void {
    const fill = shapes.downward(iron.dark, shapes.darker(iron.dark, 150)).fill;
    gb.SetRPAttrs(rp, &[_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = iron.dark },
        .{ .tag = graphics.RPTAG_FillStyle, .data = @intFromPtr(&fill) },
        .{ .tag = graphics.RPTAG_Smooth, .data = 1 },
        .{},
    });
    gb.FillRoundRect(rp, &at.panel, @intCast(at.radius));
    gb.SetRPAttrs(rp, &[_]TagItem{
        .{ .tag = graphics.RPTAG_FillStyle, .data = 0 },
        .{ .tag = graphics.RPTAG_APen, .data = shapes.toward(iron.dark, iron.base, 140) },
        .{},
    });
    gb.DrawRoundRect(rp, &at.panel, @intCast(at.radius));
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_Smooth, .data = 0 }, .{} });
}

const testing = @import("std").testing;

test "clock: the figures as large as the panel takes, the seconds beside them" {
    const with = Layout.of(320, 120, true, 0, 0);
    // In order along, and inside the panel.
    for (with.x[0..6], with.x[1..7]) |a, b| try testing.expect(a < b);
    try testing.expect(with.x[0] >= with.panel.min_x);
    try testing.expect(with.x[6] + @divTrunc(with.small * 61, 100) <= with.panel.max_x);
    try testing.expectEqual(@divTrunc(with.big, 2), with.small);
    try testing.expect(with.y_big >= with.panel.min_y);
    try testing.expect(with.y_big + with.big <= with.panel.max_y);
    // Without the seconds the same panel takes larger figures, or as
    // large when it is the height that holds them.
    const without = Layout.of(320, 120, false, 0, 0);
    try testing.expect(without.big >= with.big);
    try testing.expectEqual(@as(i32, 0), without.small);
    // A date takes room from the figures' height.
    const dated = Layout.of(320, 120, true, 0, 20);
    try testing.expect(dated.big <= with.big);
    try testing.expect(dated.date_y > dated.y_big);
}
