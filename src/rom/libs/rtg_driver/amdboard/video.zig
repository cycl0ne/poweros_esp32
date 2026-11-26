// SPDX-License-Identifier: MPL-2.0
//! A film's frame as a plane: a picture of 4:2:0 YCbCr - its brightness
//! a sample a pixel, its colour a Cb and a Cr sample for each two pixels
//! across and each two rows down, in a plane of its own - part of which
//! a pipe's fetcher reads, its scaler scales into a place on the glass
//! and its colour matrix makes red, green and blue. What the fetcher and
//! the scaler are told is worked out here (`scalingOf`), as the vendor's
//! driver works it out; `plane.zig` writes it.
//!
//! **The ratios**: the part read over its place, each way, in 19 bits of
//! a pixel, cut and not rounded; the colour's half the brightness's, its
//! samples being half as many (calculate_scaling_ratios).
//!
//! **The taps** - how many input pixels each output pixel is made of,
//! each way (dpp3_get_optimal_number_of_taps): four where the picture is
//! made larger; where smaller, twice the ratio rounded up, at most eight,
//! so that no input pixel is passed over. Down, no more than the line
//! buffer holds rows of, less those a ratio past two reads ahead, and no
//! fewer than the ratio, which it must hold - a scaling it cannot is
//! refused. A way the brightness is not scaled has one tap for it and
//! for the colour, and a way the colour is not scaled one for the colour.
//! The taps are worked out first for a viewport of 100 pixels and then
//! again for the one they give, and the viewports again where the taps
//! changed.
//!
//! **The line buffer**, in its 4:2:0 layout: 3712 of its words for the
//! brightness and 2260 for the colour, a row of either taking a word for
//! each six pixels of the narrower of what is read and its place, at
//! most 64 rows counted (dscl2_calc_lb_num_partitions).
//!
//! **Each plane's viewport and init** (calculate_init_and_vp): the first
//! output pixel of the place is made from the input pixels from
//! (ratio + taps + 1) / 2 on, each next one a ratio further. Where the
//! glass cuts the place, the input is read from as far into the part as
//! the cut falls - its fraction added to the init - moved back by up to
//! as many pixels as the taps reach before it, which the init takes up.
//! The viewport ends at the last input pixel the last output pixel
//! reads, within the part. Mirrored, the viewport is the same stretch
//! counted from the part's other end, which the fetcher reads the other
//! way round. The brightness's viewport is at least 12 pixels each way
//! (MIN_VIEWPORT_SIZE).
//!
//! **The scaler's mode** (dpp1_dscl_get_dscl_mode): the brightness passed
//! through where it is scaled neither way, the colour where it is not,
//! both scaled otherwise.

const coefficients = @import("coefficients.zig");

/// Fixed point: 19 bits of a pixel.
pub const fraction_bits = 19;
pub const one: u32 = 1 << fraction_bits;

/// The line buffer's words in its 4:2:0 layout, for the brightness and
/// for the colour; the pixels a word holds of a row; the most rows it is
/// counted to hold.
const lb_luma_words: u32 = 970 + 1290 + 484 * 3;
const lb_chroma_words: u32 = 970 + 1290;
const lb_pixels_per_word: u32 = 6;
const lb_most_rows: u32 = 64;
/// The fewest pixels the brightness's viewport has each way.
const viewport_least: u32 = 12;
/// The most taps a way.
const taps_most: u32 = 8;
/// The widest part a scaler makes smaller, wider than the glass.
const downscale_widest: u32 = 4096;
/// The viewport the taps are first worked out for.
const viewport_first: u32 = 100;

/// The scaler's modes for a 4:2:0 picture: both passed through, the
/// brightness passed through, the colour passed through, both scaled.
pub const mode_bypass: u32 = 0;
pub const mode_luma_bypass: u32 = 4;
pub const mode_chroma_bypass: u32 = 5;
pub const mode_scaled: u32 = 3;

/// What is asked: the part of the frame shown, in the frame's pixels -
/// its left and top even, so that the colour's start with them - and its
/// place on the picture before any turn, which may lie partly off the
/// glass, `glass_width` by `glass_height`; and how the picture is
/// mirrored about each axis.
pub const Asked = struct {
    src_x: u32,
    src_y: u32,
    src_width: u32,
    src_height: u32,
    dst_x: i32,
    dst_y: i32,
    dst_width: u32,
    dst_height: u32,
    glass_width: u32,
    glass_height: u32,
    mirror_x: bool = false,
    mirror_y: bool = false,
};

/// One way of a scaling: the brightness's and the colour's ratio and
/// taps, where each one's first output pixel lies in what it reads (its
/// init, in 19 bits of a pixel), and each one's viewport - its first
/// pixel, in the frame's pixels for the brightness and in the colour
/// plane's samples for the colour, and how many.
pub const Way = struct {
    ratio: u32,
    ratio_c: u32,
    taps: u32 = 1,
    taps_c: u32 = 1,
    init: u32 = 0,
    init_c: u32 = 0,
    start: u32 = 0,
    size: u32 = 0,
    start_c: u32 = 0,
    size_c: u32 = 0,
};

/// A scaling worked out: each way, the part of the place on the glass -
/// its top left on the glass and its size - and the scaler's mode.
pub const Scaling = struct {
    across: Way,
    down: Way,
    out_x: u32,
    out_y: u32,
    out_width: u32,
    out_height: u32,
    mode: u32,
};

/// What the scaler is told for `asked`; null where none of the place is
/// on the glass, for a part with an odd left or top, and where the line
/// buffer cannot hold the rows the taps read.
pub fn scalingOf(asked: Asked) ?Scaling {
    if (asked.src_width == 0 or asked.src_height == 0 or asked.dst_width == 0 or asked.dst_height == 0) return null;
    if (asked.src_x % 2 != 0 or asked.src_y % 2 != 0) return null;
    const across_on = onGlass(asked.dst_x, asked.dst_width, asked.glass_width, asked.mirror_x) orelse return null;
    const down_on = onGlass(asked.dst_y, asked.dst_height, asked.glass_height, asked.mirror_y) orelse return null;
    var across = ratiosOf(asked.src_width, asked.dst_width) orelse return null;
    var down = ratiosOf(asked.src_height, asked.dst_height) orelse return null;

    if (!tapsOf(&across, &down, viewport_first, viewport_first, across_on.size, asked.glass_width)) return null;
    viewportsOf(&across, across_on, asked.src_x, asked.src_width, asked.mirror_x);
    viewportsOf(&down, down_on, asked.src_y, asked.src_height, asked.mirror_y);
    const before = [4]u32{ across.taps, across.taps_c, down.taps, down.taps_c };
    if (!tapsOf(&across, &down, across.size, across.size_c, across_on.size, asked.glass_width)) return null;
    if (before[0] != across.taps or before[1] != across.taps_c or before[2] != down.taps or before[3] != down.taps_c) {
        viewportsOf(&across, across_on, asked.src_x, asked.src_width, asked.mirror_x);
        viewportsOf(&down, down_on, asked.src_y, asked.src_height, asked.mirror_y);
    }
    across.size = @max(across.size, viewport_least);
    down.size = @max(down.size, viewport_least);

    return .{
        .across = across,
        .down = down,
        .out_x = across_on.at,
        .out_y = down_on.at,
        .out_width = across_on.size,
        .out_height = down_on.size,
        .mode = modeOf(across, down),
    };
}

/// One way of the place on the glass: where it starts on the glass, how
/// much of it is seen, and how far into the place that starts, counted
/// on the glass - from its far end where the picture is mirrored.
const OnGlass = struct { at: u32, size: u32, offset: u32 };

fn onGlass(start: i32, size: u32, length: u32, mirrored: bool) ?OnGlass {
    const first: i64 = if (mirrored) @as(i64, length) - start - size else start;
    const from = @max(first, 0);
    const to = @min(first + size, @as(i64, length));
    if (to <= from) return null;
    return .{ .at = @intCast(from), .size = @intCast(to - from), .offset = @intCast(from - first) };
}

/// The brightness's and the colour's ratio of `src` input pixels to
/// `dst` output pixels: the quotient rounded in 32 bits, as the vendor's
/// fixed point has it, then cut to 19; the colour's halved before it is
/// cut. Null for a ratio the scaler's three whole bits do not hold.
fn ratiosOf(src: u32, dst: u32) ?Way {
    const exact: u64 = ((@as(u64, src) << 33) + dst) / (2 * @as(u64, dst));
    const ratio = exact >> (32 - fraction_bits);
    if (ratio >= 8 * @as(u64, one)) return null;
    return .{ .ratio = @intCast(ratio), .ratio_c = @intCast(exact >> (33 - fraction_bits)) };
}

/// A ratio rounded up to a whole number.
fn ceilOf(ratio: u64) u32 {
    return @intCast((ratio + one - 1) >> fraction_bits);
}

/// The rows the line buffer is counted to hold for viewports `width`
/// and `width_c` wide, a place `out_width` wide.
const Rows = struct { luma: u32, chroma: u32 };

fn rowsOf(width: u32, width_c: u32, out_width: u32) Rows {
    const line = @max(1, @min(width, out_width));
    const line_c = @max(1, @min(width_c, out_width));
    const words = (line + lb_pixels_per_word - 1) / lb_pixels_per_word;
    const words_c = (line_c + lb_pixels_per_word - 1) / lb_pixels_per_word;
    return .{
        .luma = @min(lb_luma_words / words, lb_most_rows),
        .chroma = @min(lb_chroma_words / words_c, lb_most_rows),
    };
}

/// Each way's taps for viewports `width` and `width_c` wide and a place
/// `out_width` wide on a glass `glass_width` wide: false where the line
/// buffer holds fewer rows than a ratio reads, and for a part wider than
/// the glass and than the scaler makes smaller.
fn tapsOf(across: *Way, down: *Way, width: u32, width_c: u32, out_width: u32, glass_width: u32) bool {
    across.taps = if (ceilOf(across.ratio) > 1) @min(2 * ceilOf(across.ratio), taps_most) else 4;
    down.taps = if (ceilOf(down.ratio) > 1) @min(ceilOf(2 * @as(u64, down.ratio)), taps_most) else 4;
    down.taps_c = if (ceilOf(down.ratio_c) > 1) @min(ceilOf(2 * @as(u64, down.ratio_c)), taps_most) else 4;
    across.taps_c = if (ceilOf(across.ratio_c) > 1) @min(2 * ceilOf(across.ratio_c), taps_most) else 4;
    if (width > glass_width and width > downscale_widest) return false;

    const least = ceilOf(down.ratio);
    const least_c = ceilOf(down.ratio_c);
    const rows = rowsOf(width, width_c, out_width);
    const most: i64 = if (least > 2) @as(i64, rows.luma) - (least - 2) else rows.luma;
    const most_c: i64 = if (least_c > 2) @as(i64, rows.chroma) - (least_c - 2) else rows.chroma;
    if (most < least or most_c < least_c) return false;
    down.taps = @min(down.taps, @as(u32, @intCast(most)));
    down.taps_c = @min(down.taps_c, @as(u32, @intCast(most_c)));

    if (across.ratio == one) {
        across.taps = 1;
        across.taps_c = 1;
    }
    if (down.ratio == one) {
        down.taps = 1;
        down.taps_c = 1;
    }
    if (across.ratio_c == one) across.taps_c = 1;
    if (down.ratio_c == one) down.taps_c = 1;
    return true;
}

/// A way's inits and viewports, the brightness's and the colour's, for
/// the part of the place `on` the glass, of a part `src_size` long from
/// `src_start` on.
fn viewportsOf(way: *Way, on: OnGlass, src_start: u32, src_size: u32, mirrored: bool) void {
    const luma = initOf(mirrored, on.offset, on.size, src_size, way.taps, way.ratio);
    const chroma = initOf(mirrored, on.offset, on.size, src_size / 2, way.taps_c, way.ratio_c);
    way.init = luma.init;
    way.start = luma.start + src_start;
    way.size = luma.size;
    way.init_c = chroma.init;
    way.start_c = chroma.start + src_start / 2;
    way.size_c = chroma.size;
}

/// One plane's init and viewport, from the part's start, for a place cut
/// `offset` pixels in and `out_size` long, of a part `src_size` long,
/// with `taps` and `ratio`.
fn initOf(mirrored: bool, offset: u32, out_size: u32, src_size: u32, taps: u32, ratio: u32) struct { init: u32, start: u32, size: u32 } {
    const into = @as(u64, ratio) * offset;
    var start: u32 = @intCast(into >> fraction_bits);
    var init: u64 = (@as(u64, ratio) + (@as(u64, taps) + 1) * one) / 2 + (into & (one - 1));
    const whole: u32 = @intCast(init >> fraction_bits);
    if (whole < taps) {
        const back = @min(taps - whole, start);
        start -= back;
        init += @as(u64, back) * one;
    }
    var size: u32 = @intCast((init + @as(u64, ratio) * (out_size - 1)) >> fraction_bits);
    if (start > src_size) start = src_size;
    if (size + start > src_size) size = src_size - start;
    if (mirrored) start = src_size - start - size;
    return .{ .init = @intCast(init), .start = start, .size = size };
}

fn modeOf(across: Way, down: Way) u32 {
    if (across.ratio == one and down.ratio == one and across.ratio_c == one and down.ratio_c == one) return mode_bypass;
    if (across.ratio == one and down.ratio == one) return mode_luma_bypass;
    if (across.ratio_c == one and down.ratio_c == one) return mode_chroma_bypass;
    return mode_scaled;
}

/// The filters the scaler is loaded with for a scaling: the
/// brightness's across and down, the colour's across and down, each null
/// for one tap; and whether a way of two taps for both planes takes the
/// scaler's own coefficients instead (dpp1_dscl_set_scl_filter).
pub const Filters = struct {
    luma_across: ?[]const u16,
    luma_down: ?[]const u16,
    chroma_across: ?[]const u16,
    chroma_down: ?[]const u16,
    two_taps_across: bool,
    two_taps_down: bool,

    /// Whether the scaler holds `filters` already, all the ones there are.
    pub fn same(filters: Filters, other: Filters) bool {
        return sameTable(filters.luma_across, other.luma_across) and sameTable(filters.luma_down, other.luma_down) and
            sameTable(filters.chroma_across, other.chroma_across) and sameTable(filters.chroma_down, other.chroma_down) and
            filters.two_taps_across == other.two_taps_across and filters.two_taps_down == other.two_taps_down;
    }

    /// Whether `filters` are to be loaded into a scaler that holds `held`
    /// - null where nothing it holds is known: one of them that is not
    /// what it holds there (dpp1_dscl_set_scl_filter's filter_updated).
    pub fn updates(filters: Filters, held: ?Filters) bool {
        const was = held orelse return filters.luma_across != null or filters.luma_down != null or
            filters.chroma_across != null or filters.chroma_down != null;
        return differs(filters.luma_across, was.luma_across) or differs(filters.luma_down, was.luma_down) or
            differs(filters.chroma_across, was.chroma_across) or differs(filters.chroma_down, was.chroma_down);
    }
};

fn differs(wanted: ?[]const u16, held: ?[]const u16) bool {
    const table = wanted orelse return false;
    const was = held orelse return true;
    return table.ptr != was.ptr;
}

fn sameTable(one_table: ?[]const u16, other: ?[]const u16) bool {
    const a = one_table orelse return other == null;
    const b = other orelse return false;
    return a.ptr == b.ptr;
}

/// The filters for `scaling`, by each way's taps and ratio.
pub fn filtersOf(scaling: Scaling) Filters {
    const across = scaling.across;
    const down = scaling.down;
    return .{
        .luma_across = coefficients.filterOf(across.taps, across.ratio << 5),
        .luma_down = coefficients.filterOf(down.taps, down.ratio << 5),
        .chroma_across = coefficients.filterOf(across.taps_c, across.ratio_c << 5),
        .chroma_down = coefficients.filterOf(down.taps_c, down.ratio_c << 5),
        .two_taps_across = across.taps < 3 and across.taps_c < 3 and across.taps > 1 and across.taps_c > 1,
        .two_taps_down = down.taps < 3 and down.taps_c < 3 and down.taps > 1 and down.taps_c > 1,
    };
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

/// The input pixel, counted from 0, the first tap of output pixel `out`
/// reads with `init` and `ratio`: the init counts from 1.
fn firstTap(init: u32, ratio: u32, out: u32) i64 {
    return @as(i64, @intCast((@as(u64, init) + @as(u64, ratio) * out) >> fraction_bits)) - 1;
}

test "a frame shown as it is: the brightness passed through, the colour's samples each laid on two pixels each way" {
    const shown = scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 1920, .src_height = 1080, .dst_x = 320, .dst_y = 180, .dst_width = 1920, .dst_height = 1080, .glass_width = 2560, .glass_height = 1440 }).?;
    try testing.expectEqual(mode_luma_bypass, shown.mode);
    try testing.expectEqual(one, shown.across.ratio);
    try testing.expectEqual(one / 2, shown.across.ratio_c);
    // One tap for both: a sample is the colour of the two pixels it lies on.
    try testing.expectEqual(@as(u32, 1), shown.across.taps);
    try testing.expectEqual(@as(u32, 1), shown.across.taps_c);
    try testing.expectEqual(@as(u32, 1), shown.down.taps_c);
    try testing.expectEqual(@as(u32, 1920), shown.across.size);
    try testing.expectEqual(@as(u32, 960), shown.across.size_c);
    try testing.expectEqual(@as(u32, 540), shown.down.size_c);
    try testing.expectEqual(@as(u32, 320), shown.out_x);
    try testing.expectEqual(@as(u32, 1920), shown.out_width);
    var out: u32 = 0;
    while (out < 1920) : (out += 1) {
        try testing.expectEqual(@as(i64, out / 2), firstTap(shown.across.init_c, shown.across.ratio_c, out));
    }
}

test "a frame made larger and smaller: the ratios cut, the taps as the vendor counts them" {
    // 1280 by 720 into 2560 by 1440: half a pixel a pixel, four taps.
    const larger = scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 1280, .src_height = 720, .dst_x = 0, .dst_y = 0, .dst_width = 2560, .dst_height = 1440, .glass_width = 2560, .glass_height = 1440 }).?;
    try testing.expectEqual(mode_scaled, larger.mode);
    try testing.expectEqual(one / 2, larger.across.ratio);
    try testing.expectEqual(one / 4, larger.across.ratio_c);
    try testing.expectEqual(@as(u32, 4), larger.across.taps);
    try testing.expectEqual(@as(u32, 4), larger.down.taps_c);
    // The init: (ratio + taps + 1) / 2.
    try testing.expectEqual((one / 2 + 5 * one) / 2, larger.across.init);
    try testing.expectEqual(@as(u32, 1280), larger.across.size);
    try testing.expectEqual(@as(u32, 640), larger.across.size_c);

    // 1920 by 1080 into 960 by 540: the brightness two pixels a pixel and
    // four taps, the colour passed through.
    const smaller = scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 1920, .src_height = 1080, .dst_x = 0, .dst_y = 0, .dst_width = 960, .dst_height = 540, .glass_width = 2560, .glass_height = 1440 }).?;
    try testing.expectEqual(mode_chroma_bypass, smaller.mode);
    try testing.expectEqual(2 * one, smaller.across.ratio);
    try testing.expectEqual(@as(u32, 4), smaller.across.taps);
    try testing.expectEqual(@as(u32, 4), smaller.down.taps);
    try testing.expectEqual(@as(u32, 1), smaller.across.taps_c);

    // 1920 into 1366: a ratio that is no whole number, cut to 19 bits.
    const odd = scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 1920, .src_height = 1080, .dst_x = 0, .dst_y = 0, .dst_width = 1366, .dst_height = 768, .glass_width = 2560, .glass_height = 1440 }).?;
    try testing.expectEqual(@as(u32, (1920 << 19) / 1366), odd.across.ratio);
    try testing.expectEqual(@as(u32, 4), odd.across.taps);
    try testing.expectEqual(@as(u32, 3), odd.down.taps);
}

test "a place cut by the glass: the viewport from as far in, the taps' pixels before it read" {
    // 1280 wide into 2560 from 100 left of the glass: the first 50 input
    // pixels not shown, and the four taps reaching three before.
    const cut = scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 1280, .src_height = 720, .dst_x = -100, .dst_y = 0, .dst_width = 2560, .dst_height = 1440, .glass_width = 2560, .glass_height = 1440 }).?;
    try testing.expectEqual(@as(u32, 0), cut.out_x);
    try testing.expectEqual(@as(u32, 2460), cut.out_width);
    const whole = scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 1280, .src_height = 720, .dst_x = 0, .dst_y = 0, .dst_width = 2560, .dst_height = 1440, .glass_width = 2560, .glass_height = 1440 }).?;
    // Each output pixel of the cut place reads what the same pixel of the
    // whole one reads.
    var out: u32 = 0;
    while (out < cut.out_width) : (out += 1) {
        const in_cut = firstTap(cut.across.init, cut.across.ratio, out) + cut.across.start;
        const in_whole = firstTap(whole.across.init, whole.across.ratio, out + 100) + whole.across.start;
        try testing.expectEqual(in_whole, in_cut);
        const c_cut = firstTap(cut.across.init_c, cut.across.ratio_c, out) + cut.across.start_c;
        const c_whole = firstTap(whole.across.init_c, whole.across.ratio_c, out + 100) + whole.across.start_c;
        try testing.expectEqual(c_whole, c_cut);
    }
    // The viewport never reaches past the part.
    try testing.expect(cut.across.start + cut.across.size <= 1280);
    try testing.expect(cut.across.start_c + cut.across.size_c <= 640);
}

test "a part of a frame, mirrored, and none on the glass" {
    // The right half of a frame, shown as it is: its viewport from 960.
    const half = scalingOf(.{ .src_x = 960, .src_y = 0, .src_width = 960, .src_height = 1080, .dst_x = 0, .dst_y = 0, .dst_width = 960, .dst_height = 1080, .glass_width = 2560, .glass_height = 1440 }).?;
    try testing.expectEqual(@as(u32, 960), half.across.start);
    try testing.expectEqual(@as(u32, 480), half.across.start_c);
    // Mirrored left to right, a place partly off the picture's left is
    // partly off the glass's right, its viewport the same stretch of the
    // part counted from the other end.
    const mirrored = scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 640, .src_height = 360, .dst_x = -40, .dst_y = 10, .dst_width = 640, .dst_height = 360, .glass_width = 2560, .glass_height = 1440, .mirror_x = true }).?;
    try testing.expectEqual(@as(u32, 2560 - 600), mirrored.out_x);
    try testing.expectEqual(@as(u32, 600), mirrored.out_width);
    try testing.expectEqual(@as(u32, 40), mirrored.across.start);
    try testing.expectEqual(@as(u32, 600), mirrored.across.size);
    const plain = scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 640, .src_height = 360, .dst_x = -40, .dst_y = 10, .dst_width = 640, .dst_height = 360, .glass_width = 2560, .glass_height = 1440 }).?;
    try testing.expectEqual(@as(u32, 0), plain.out_x);
    try testing.expectEqual(@as(u32, 40), plain.across.start);
    // Off the glass, an odd left, a ratio past what the scaler holds.
    try testing.expect(scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 640, .src_height = 360, .dst_x = 2560, .dst_y = 0, .dst_width = 640, .dst_height = 360, .glass_width = 2560, .glass_height = 1440 }) == null);
    try testing.expect(scalingOf(.{ .src_x = 1, .src_y = 0, .src_width = 640, .src_height = 360, .dst_x = 0, .dst_y = 0, .dst_width = 640, .dst_height = 360, .glass_width = 2560, .glass_height = 1440 }) == null);
    try testing.expect(scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 3840, .src_height = 2160, .dst_x = 0, .dst_y = 0, .dst_width = 400, .dst_height = 200, .glass_width = 2560, .glass_height = 1440 }) == null);
}

test "the line buffer's rows: a wide frame's taps down cut to what it holds" {
    try testing.expectEqual(Rows{ .luma = 8, .chroma = 10 }, rowsOf(2560, 1280, 2560));
    try testing.expectEqual(Rows{ .luma = 64, .chroma = 64 }, rowsOf(100, 100, 2560));
    // 3840 by 2160 into 1280 by 720: three pixels a pixel, six taps each
    // way, the line buffer holding 17 rows of the place's 1280; the
    // colour one and a half samples a pixel, three taps down, four across.
    const smaller = scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 3840, .src_height = 2160, .dst_x = 0, .dst_y = 0, .dst_width = 1280, .dst_height = 720, .glass_width = 2560, .glass_height = 1440 }).?;
    try testing.expectEqual(@as(u32, 6), smaller.down.taps);
    try testing.expectEqual(@as(u32, 6), smaller.across.taps);
    try testing.expectEqual(@as(u32, 3), smaller.down.taps_c);
    try testing.expectEqual(@as(u32, 4), smaller.across.taps_c);
    try testing.expectEqual(@as(u32, 3840), smaller.across.size);
    try testing.expectEqual(@as(u32, 1920), smaller.across.size_c);
}

test "the filters: one tap none, two taps for both planes the scaler's own" {
    const shown = scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 640, .src_height = 360, .dst_x = 0, .dst_y = 0, .dst_width = 640, .dst_height = 360, .glass_width = 2560, .glass_height = 1440 }).?;
    const none = filtersOf(shown);
    try testing.expect(none.luma_across == null and none.chroma_across == null and none.chroma_down == null);
    const larger = scalingOf(.{ .src_x = 0, .src_y = 0, .src_width = 640, .src_height = 360, .dst_x = 0, .dst_y = 0, .dst_width = 1280, .dst_height = 720, .glass_width = 2560, .glass_height = 1440 }).?;
    const four = filtersOf(larger);
    try testing.expectEqual(@as(usize, 33 * 4), four.luma_across.?.len);
    try testing.expect(four.same(filtersOf(larger)));
    try testing.expect(!four.same(none));
    try testing.expect(!four.two_taps_across);
    // Loaded where nothing is known held, or another is; not again, nor
    // for a frame shown as it is, which takes none.
    try testing.expect(four.updates(null));
    try testing.expect(four.updates(none));
    try testing.expect(!four.updates(four));
    try testing.expect(!none.updates(four));
    try testing.expect(!none.updates(null));
}
