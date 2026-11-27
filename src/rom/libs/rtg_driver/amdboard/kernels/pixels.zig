// SPDX-License-Identifier: MPL-2.0
//! What the board's kernels make of a pixel: the sums graphics.library
//! takes for the same jobs, written for the graphics block's compute
//! engine, which reaches no library. The kernels (`engine.zig`) take
//! them, and the host tests (`tests.zig`) hold them to the library's own
//! for the same pixels.
//!
//! A colour is a pen, 0xAARRGGBB, as a `bgra32` pixel holds it; an
//! `rgba32` pixel is a pen with its red and blue swapped. A pen laid over
//! a pixel counts by its coverage, its top byte: nothing for none, the
//! pen itself for all of it, and between, each channel `(pen x a +
//! under x (255 - a) + 127) / 255`, the result opaque - which lands full
//! coverage exactly on the colour and keeps a run of composites from
//! drifting dark. A picture scaled is the colour it has at the place each
//! pixel's middle falls in it, the two lined up by their edges: where it
//! is made larger, the four pixels round that place mixed by how near
//! each is, in 256ths of a pixel; where it is made smaller either way,
//! the mean of every pixel the destination pixel covers, each by how much
//! of it it covers. A shape's bit is its row's bits from the highest of
//! the first byte on.
//!
//! The places are counted from the part of the picture taken - its first
//! column and row are 0 - which moves every sum by whole pixels and
//! changes none of them.
//!
//! Every function is inline: a kernel calls nothing, which would want a
//! stack the engine is not given.

/// The flags the kernels take beside a shape's (`transparent`, `invert`):
/// an `rgba32` picture (else `bgra32`); every pixel of a picture covering
/// fully, laid at the strength alone; a picture made smaller either way;
/// pixels of two bytes (else four).
pub const rgba: u32 = 1 << 8;
pub const whole: u32 = 1 << 9;
pub const shrinks: u32 = 1 << 10;
pub const halves: u32 = 1 << 11;

/// x / 255 rounded down, for x up to 255 * 255 + 255.
pub inline fn div255(x: u32) u32 {
    return (x + 1 + (x >> 8)) >> 8;
}

/// The same for two values a half-word each, as red and blue lie in a
/// pen, each up to 255 * 255 + 127, so that neither carries into the
/// other.
pub inline fn div255Pair(x: u32) u32 {
    return ((x + 0x0001_0001 + ((x >> 8) & 0x00FF_00FF)) >> 8) & 0x00FF_00FF;
}

/// `pen`, of coverage 1 to 254, over `under`, opaque.
pub inline fn over(pen: u32, under: u32) u32 {
    const alpha = pen >> 24;
    const red_blue = ((((pen >> 16) & 0xFF) * alpha + 127) << 16) | ((pen & 0xFF) * alpha + 127);
    const green = ((pen >> 8) & 0xFF) * alpha + 127;
    const inverse = 255 - alpha;
    const mixed_red_blue = (under & 0x00FF_00FF) * inverse + red_blue;
    const mixed_green = ((under >> 8) & 0xFF) * inverse + green;
    return 0xFF00_0000 | div255Pair(mixed_red_blue) | (div255(mixed_green) << 8);
}

/// `pen` over a `bgra32` pixel by its coverage: the pixel as it was for
/// none, the pen for all of it, the two mixed between.
pub inline fn lay(pen: u32, under: u32) u32 {
    const coverage = pen >> 24;
    if (coverage == 0xFF) return pen;
    if (coverage == 0) return under;
    return over(pen, under);
}

/// An `rgba32` pixel as a pen.
pub inline fn fromRgba(value: u32) u32 {
    return (value & 0xFF00_FF00) | ((value & 0xFF) << 16) | ((value >> 16) & 0xFF);
}

/// A picture's pen with the coverage it lands at: its own at full
/// strength, times `alpha` / 256 at less, and `alpha` alone where every
/// pixel covers fully.
pub inline fn strength(pen: u32, alpha: u32, covers_fully: bool) u32 {
    const coverage = if (covers_fully) alpha else if (alpha == 255) pen >> 24 else ((pen >> 24) * alpha) >> 8;
    return (pen & 0x00FF_FFFF) | (coverage << 24);
}

// --- scaled --------------------------------------------------------------------------

/// Where the middle of destination pixel `dest` of `dest_size` falls in a
/// part of the source `src_size` pixels across, in 256ths of a source
/// pixel, a pixel's middle at its whole number.
pub inline fn sourceOf(dest: u32, dest_size: u32, src_size: u32) i64 {
    const offset: u64 = @as(u64, dest) * 2 + 1;
    return @as(i64, @intCast((offset * src_size * 256) / (2 * @as(u64, dest_size)))) - 128;
}

/// The two source pixels either side of a place, kept inside the part,
/// and how far between them it is, in 256ths: the second's weight.
pub const Between = struct { first: u32, second: u32, weight: u32 };

pub inline fn between(place: i64, size: u32) Between {
    const last: i64 = @as(i64, size) - 1;
    const first = @max(@min(place >> 8, last), 0);
    const second = @min(first + 1, last);
    const weight = @max(@min(place - first * 256, 255), 0);
    return .{ .first = @intCast(first), .second = @intCast(second), .weight = @intCast(weight) };
}

/// Four pens mixed by weights that make 65536, each channel and the
/// coverage alike, rounded.
pub inline fn sample(corners: [4]u32, weights: [4]u32) u32 {
    var mixed: u32 = 0;
    inline for (0..4) |channel| {
        const shift: u5 = channel * 8;
        var sum: u32 = 0;
        inline for (corners, weights) |corner, weight| sum += ((corner >> shift) & 0xFF) * weight;
        mixed |= ((sum + 32768) >> 16) << shift;
    }
    return mixed;
}

/// A stretch of the source along one axis, from `from` up to `to`, in
/// 256ths of a pixel with a pixel's middle at its whole number: pixel
/// `pixel` reaches from `pixel * 256 - 128` up to `pixel * 256 + 128`.
pub const Span = struct {
    from: i64,
    to: i64,

    /// How much of pixel `pixel` lies in it, in 256ths.
    pub inline fn share(span: Span, pixel: i64) u64 {
        const middle = pixel * 256;
        const lo = @max(span.from, middle - 128);
        const hi = @min(span.to, middle + 128);
        return if (hi > lo) @intCast(hi - lo) else 0;
    }

    /// The first pixel some of which lies in it, kept inside the part.
    pub inline fn first(span: Span) i64 {
        return @max((span.from + 128) >> 8, 0);
    }

    /// The last, kept inside the part `size` pixels across.
    pub inline fn last(span: Span, size: u32) i64 {
        return @min((span.to + 127) >> 8, @as(i64, size) - 1);
    }
};

/// The stretch of the source destination pixel `dest` takes along one
/// axis: where the picture is made smaller along it, the destination
/// pixel's own part of the source; elsewhere a source pixel's width round
/// where its middle falls, which takes the two pixels either side by how
/// near each is.
pub inline fn spanOf(dest: u32, dest_size: u32, src_size: u32) Span {
    if (src_size <= dest_size) {
        const middle = sourceOf(dest, dest_size, src_size);
        return .{ .from = middle - 128, .to = middle + 128 };
    }
    const scale = @as(u64, src_size) * 256;
    return .{
        .from = @as(i64, @intCast((@as(u64, dest) * scale) / dest_size)) - 128,
        .to = @as(i64, @intCast(((@as(u64, dest) + 1) * scale) / dest_size)) - 128,
    };
}

/// The sums of a mean: each channel and the coverage, each pixel's
/// share counted in, and the shares together.
pub const Mean = struct {
    sums: [4]u64 = .{ 0, 0, 0, 0 },
    total: u64 = 0,

    /// One row's sums, `weight` of it lying in the stretch down, added.
    pub inline fn add(mean: *Mean, row: Mean, weight: u64) void {
        inline for (&mean.sums, row.sums) |*sum, part| sum.* += part * weight;
        mean.total += row.total * weight;
    }

    /// A pen, `weight` of it lying in the stretch across, added to a row.
    pub inline fn take(mean: *Mean, colour: u32, weight: u64) void {
        inline for (&mean.sums, 0..) |*sum, channel| sum.* += ((colour >> (channel * 8)) & 0xFF) * weight;
        mean.total += weight;
    }

    /// The pen: each sum divided by the shares, rounded; none for none.
    pub inline fn result(mean: Mean) u32 {
        if (mean.total == 0) return 0;
        var mixed: u32 = 0;
        inline for (mean.sums, 0..) |sum, channel| mixed |= @as(u32, @intCast((sum + mean.total / 2) / mean.total)) << (channel * 8);
        return mixed;
    }
};

// --- shapes --------------------------------------------------------------------------

/// Whether bit `column` of a row of a shape is set, `byte` the row's byte
/// that holds it.
pub inline fn bitOf(byte: u8, column: u32) bool {
    return (byte >> @intCast(7 - (column & 7))) & 1 != 0;
}

/// RtgTemplate's and RtgPattern's flags as the kernels take them: a clear
/// bit leaves the pixel alone, and set and clear swap.
pub const transparent: u32 = 1 << 0;
pub const invert: u32 = 1 << 1;

/// Whether a bit puts down the set colour, after the swap; one that does
/// not puts down the clear colour, or leaves the pixel alone
/// (`transparent`).
pub inline fn inked(set: bool, flags: u32) bool {
    return set != (flags & invert != 0);
}
