// SPDX-License-Identifier: MPL-2.0
//! The pixels of a triangle in a tile, a row at a time: of each row the
//! run inside all three edges, worked out from where the edges cross it,
//! so that nothing is tested pixel by pixel.
//!
//! Going right along a row, an edge either comes inside (its step across,
//! `a`, is above 0), goes outside (below 0), or runs along the rows (0),
//! inside or not for the whole row. A row's run starts where the last edge
//! that comes inside does and ends where the first that goes outside does;
//! an edge along the rows only takes rows off the top or the bottom, once.
//! A triangle has two edges that come inside and one that goes out, or the
//! other way round, or one of each and one along the rows; setup sorts the
//! edges into those once a triangle (`bins.sortForWalk`), and the loop over
//! the rows is made for each of the three, so that it holds its edges in
//! registers and asks nothing of them while it runs.
//!
//! Where an edge crosses a row is kept as the column it bounds the run at
//! and what is left over: its value at the row's left over its step
//! across, divided once a tile. A row down adds the edge's step down,
//! which setup divided once a triangle (`Edge.down_whole`, `down_part`),
//! and carries what is left over without a branch, so a row costs adds
//! and no division, and the runs are those of the edges to the pixel. On
//! the VisionFive 2's U74 at 1 GHz a row costs about 35 cycles, a
//! triangle's start in a tile about 230 - its divisions - and a flat run
//! 3 cycles for two pixels.
//!
//! At more than one sample a pixel, each sample crosses the edges on its
//! own - its value at a pixel the centre's and what its offset adds, the
//! same in every pixel - so a row has a run for each, which a pair of
//! rows hands on together (`quads`). An edge along the rows holds some of
//! a row's samples and not the others, and is asked a row at a time.
//!
//! The numbers cannot overflow - an edge's values stay well inside 64
//! bits anywhere in the guard band (setup.zig) - so they are added
//! wrapping, without the checks that would cost more than the adds: this
//! runs for every row of every triangle in every tile.

const bins = @import("bins.zig");
const Edge = bins.Edge;
const Header = bins.Header;
const Tile = @import("target.zig").Tile;
const sampleOffsets = @import("setup.zig").sampleOffsets;

/// Each row's run of `triangle` in `tile`, top to bottom, handed to
/// `run(context, y, left, right)`: row `y` from the tile's top, its pixels
/// `left` to one before `right` from the tile's left. Rows with nothing
/// inside are left out.
pub inline fn runs(tile: *const Tile, triangle: *const Header, context: anytype, comptime run: anytype) void {
    walk(false, 1, tile, triangle, context, run);
}

/// A row's pixels from `left` to one before `right`, from the tile's
/// left; none where the two are the same.
pub const Span = struct {
    left: u32,
    right: u32,

    pub const none = Span{ .left = 0, .right = 0 };

    pub inline fn empty(span: Span) bool {
        return span.left >= span.right;
    }

    pub inline fn holds(span: Span, x: u32) bool {
        return x >= span.left and x < span.right;
    }
};

/// The runs two rows at a time, for drawing in 2 x 2 quads: each even row
/// `y` from the tile's top and the one under it, handed to `run(context,
/// y, upper, lower)` - either may be empty, the rows past the triangle's
/// box always are; a pair with nothing in either is left out. At one
/// sample a pixel `upper` and `lower` are a `Span` each; at four (since
/// 1.102) four each, one a sample (`setup.sampleOffsets`), for
/// `sampleMask` to make a quad's samples of.
pub inline fn quads(comptime samples: u32, tile: *const Tile, triangle: *const Header, context: anytype, comptime run: anytype) void {
    walk(true, samples, tile, triangle, context, run);
}

inline fn walk(comptime paired: bool, comptime samples: u32, tile: *const Tile, triangle: *const Header, context: anytype, comptime run: anytype) void {
    const span = tile.span(triangle) orelse return;
    // In the order setup sorted them in: those that come inside, those
    // that go out, the one along the rows.
    const edges = &triangle.edges;
    const along = edges[2].a == 0;
    var top = span.top;
    var bottom = span.bottom;
    if (along) {
        // The rows it holds the most inside sample of - at one sample a
        // pixel, the rows it holds.
        const edge = edges[2];
        const kept = alongRows(edge.at(tile.x, tile.y + @as(i64, top)) +% edge.inmost, edge.b, top, bottom) orelse return;
        top = kept[0];
        bottom = kept[1];
    }

    const x: i64 = tile.x + span.left;
    const y: i64 = tile.y + top;
    const box = Box{ .left = span.left, .width = span.right - span.left, .top = top, .bottom = bottom };
    // At more than one sample a pixel, the rows of those that each sample
    // is inside the edge along the rows on: a row can hold some of a
    // pixel's samples and not the others.
    var sample_rows: [samples][2]u32 = @splat(.{ top, bottom });
    if (samples > 1 and along) {
        const edge = edges[2];
        const value = edge.at(x, y);
        for (&sample_rows, comptime sampleOffsets(samples)) |*held, offset| {
            held.* = alongRows(value +% edge.offsetBy(offset), edge.b, top, bottom) orelse .{ bottom, bottom };
        }
    }
    if (along) {
        rows(paired, samples, 1, 1, crossings(.comes_in, samples, 1, .{edges[0]}, x, y), crossings(.goes_out, samples, 1, .{edges[1]}, x, y), sample_rows, box, context, run);
    } else if (edges[1].a > 0) {
        rows(paired, samples, 2, 1, crossings(.comes_in, samples, 2, .{ edges[0], edges[1] }, x, y), crossings(.goes_out, samples, 1, .{edges[2]}, x, y), sample_rows, box, context, run);
    } else {
        rows(paired, samples, 1, 2, crossings(.comes_in, samples, 1, .{edges[0]}, x, y), crossings(.goes_out, samples, 2, .{ edges[1], edges[2] }, x, y), sample_rows, box, context, run);
    }
}

/// The rows from `top` to one before `bottom` inside an edge along the
/// rows, its value `value` at row `top` and `b` more a row down - not 0,
/// the triangle having an area: from the row where it reaches 0 on, or
/// down to the one where it falls below 0. Null for none.
inline fn alongRows(value: i64, b: i64, top: u32, bottom: u32) ?[2]u32 {
    const height: i64 = bottom - top;
    if (b > 0) {
        const first = if (value >= 0) 0 else @divFloor(-value + b - 1, b);
        if (first >= height) return null;
        return .{ top + @as(u32, @intCast(first)), bottom };
    }
    if (value < 0) return null;
    const last = @divFloor(value, -b);
    return .{ top, if (last + 1 < height) top + @as(u32, @intCast(last + 1)) else bottom };
}

/// Where each of a pixel's samples crosses each of `edges`, from the
/// pixel at (x, y), the box's top left.
inline fn crossings(comptime way: Way, comptime samples: u32, comptime n: usize, edges: [n]Edge, x: i64, y: i64) [samples][n]Crossing(way) {
    var made: [samples][n]Crossing(way) = undefined;
    inline for (&made, comptime sampleOffsets(samples)) |*sample, offset| {
        inline for (sample, edges) |*crossing, edge| crossing.* = .of(edge, x, y, if (samples == 1) 0 else edge.offsetBy(offset));
    }
    return made;
}

/// The tile's pixels the triangle's box holds: its columns, from the
/// tile's left, and its rows, from the tile's top, those outside an edge
/// along the rows already taken off.
const Box = struct {
    left: u32,
    width: i64,
    top: u32,
    bottom: u32,
};

/// The rows of a box, with `n_in` edges that come inside and `n_out` that
/// go out, each of `samples` samples a pixel crossing them on its own:
/// each row's run, or each pair's. With an edge along the rows, a sample
/// is inside it on its own rows of the box alone, `sample_rows`.
inline fn rows(
    comptime paired: bool,
    comptime samples: u32,
    comptime n_in: usize,
    comptime n_out: usize,
    in: [samples][n_in]Crossing(.comes_in),
    out: [samples][n_out]Crossing(.goes_out),
    sample_rows: [samples][2]u32,
    box: Box,
    context: anytype,
    comptime run: anytype,
) void {
    if (!paired and samples != 1) @compileError("runs are of one sample a pixel");
    var comes_in = in;
    var goes_out = out;
    // With pairs: the even row's runs, until its pair is made - a span at
    // one sample a pixel, one a sample at more.
    const Runs = if (samples == 1) Span else [samples]Span;
    const nothing: Runs = if (samples == 1) Span.none else @splat(Span.none);
    var upper = nothing;
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        var here: [samples]Span = undefined;
        inline for (&here, &comes_in, &goes_out, sample_rows) |*sample, *ins, *outs, held| {
            var first: i64 = 0;
            var end: i64 = box.width;
            inline for (ins) |*crossing| {
                first = @max(first, crossing.column);
                crossing.down();
            }
            inline for (outs) |*crossing| {
                end = @min(end, crossing.column);
                crossing.down();
            }
            if (samples > 1 and n_in + n_out == 2 and (y < held[0] or y >= held[1])) end = first;
            if (!paired) {
                if (first < end) run(context, y, box.left +% column(first), box.left +% column(end));
            } else {
                sample.* = if (first < end) .{ .left = box.left +% column(first), .right = box.left +% column(end) } else Span.none;
            }
        }
        if (!paired) continue;
        const pair: Runs = if (samples == 1) here[0] else here;
        if (y & 1 == 0) {
            upper = pair;
            if (y + 1 == box.bottom and !emptyOf(pair)) run(context, y, pair, nothing);
        } else {
            if (!emptyOf(upper) or !emptyOf(pair)) run(context, y - 1, upper, pair);
            upper = nothing;
        }
    }
}

/// Whether a row's runs hold no pixel: its one, or each sample's.
inline fn emptyOf(spans: anytype) bool {
    if (@TypeOf(spans) == Span) return spans.empty();
    for (spans) |span| if (!span.empty()) return false;
    return true;
}

/// The samples of the quad at columns `x` and `x + 1` that a pair of rows
/// holds at four samples a pixel (`quads`): bit 4s + i is sample s of
/// the quad's pixel i, 0 and 1 the upper row's, 2 and 3 the lower's.
/// llvmpipe builds a block's mask a sample at a time the same way
/// (`do_block_4`, lp_rast_tri_tmp.h:63-72). (Since 1.102.)
pub inline fn sampleMask(upper: [4]Span, lower: [4]Span, x: u32) u16 {
    var mask: u16 = 0;
    inline for (upper, lower, 0..) |high, low, sample| {
        const pixels = @as(u16, @intFromBool(high.holds(x))) | @as(u16, @intFromBool(high.holds(x + 1))) << 1 |
            @as(u16, @intFromBool(low.holds(x))) << 2 | @as(u16, @intFromBool(low.holds(x + 1))) << 3;
        mask |= pixels << (4 * sample);
    }
    return mask;
}

/// The pixels a row's runs hold between them at more than one sample a
/// pixel: from the first that any of them holds to past the last; none
/// where they hold nothing. What a quad is looked for in, and its depth
/// read from (batched.zig). (Since 1.103.)
pub inline fn hullOf(spans: anytype) Span {
    var hull = Span{ .left = ~@as(u32, 0), .right = 0 };
    for (spans) |span| {
        if (span.empty()) continue;
        hull.left = @min(hull.left, span.left);
        hull.right = @max(hull.right, span.right);
    }
    return if (hull.empty()) Span.none else hull;
}

/// The pixels of a quad with any of their samples inside, bit i pixel i:
/// those it is shaded for (`shader.Quad.covered`). (Since 1.102.)
pub inline fn pixelsOf(mask: u16) u4 {
    return @truncate(mask | mask >> 4 | mask >> 8 | mask >> 12);
}

/// A column of the box, 0 to its width: a run's ends once they are cut to
/// the box.
inline fn column(at: i64) u32 {
    return @truncate(@as(u64, @bitCast(at)));
}

/// Which way an edge crosses the rows, going right.
const Way = enum { comes_in, goes_out };

/// An edge where it crosses the row under way, at a pixel's centre or,
/// `shift` added to its value, at one of its samples.
///
/// With `step` its step across made positive, the edge's value at the
/// row's left is `whole * step + part`, 0 <= part < step. Going right it
/// adds `a` a pixel: one coming inside is 0 or more from column `-whole`
/// on, one going out up to column `whole`. Kept is that column - the run's
/// first, or one past its last - and `part - step`, below 0: a row down
/// adds the step down to both, and when the second gets to 0 or more it
/// gives up a step and the column moves one more.
fn Crossing(comptime way: Way) type {
    return struct {
        column: i64,
        over: i64,
        step: i64,
        /// What a row down adds to `column` when what is left over
        /// carries; when it does not, `down` takes the carry back.
        down_column: i64,
        down_part: i64,

        const Self = @This();

        inline fn of(edge: Edge, x: i64, y: i64, shift: i64) Self {
            const step: i64 = @intCast(@abs(edge.a));
            const at = edge.at(x, y) +% shift;
            const whole = @divFloor(at, step);
            return .{
                .column = switch (way) {
                    .comes_in => -%whole,
                    .goes_out => whole +% 1,
                },
                .over = at -% whole *% step -% step,
                .step = step,
                .down_column = switch (way) {
                    .comes_in => -%edge.down_whole -% 1,
                    .goes_out => edge.down_whole +% 1,
                },
                .down_part = edge.down_part,
            };
        }

        inline fn down(crossing: *Self) void {
            crossing.over +%= crossing.down_part;
            // All ones while what is left over stays below 0, else 0.
            const stays = crossing.over >> 63;
            crossing.over = (crossing.over -% crossing.step) +% (crossing.step & stays);
            crossing.column +%= switch (way) {
                .comes_in => crossing.down_column -% stays,
                .goes_out => crossing.down_column +% stays,
            };
        }
    };
}

/// Pixels `left` to one before `right` of a row set to `pixel`, `left`
/// below `right`. The first and the last are stored alone and the pairs
/// between two at a store, from the first even column on - a row starts
/// on 8 bytes; what they overlap is stored twice, and nothing has to be
/// asked of where the run starts and ends.
pub inline fn fill(row: [*]u32, left: u32, right: u32, pixel: u32) void {
    row[left] = pixel;
    row[right -% 1] = pixel;
    const pairs: [*]u64 = @ptrCast(@alignCast(row));
    const pair = @as(u64, pixel) << 32 | pixel;
    var at = pairs + (left + 1) / 2;
    const end = @intFromPtr(pairs + right / 2);
    while (@intFromPtr(at) < end) : (at += 1) at[0] = pair;
}
