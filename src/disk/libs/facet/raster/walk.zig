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
//! other way round, or one of each and one along the rows; the edges are
//! sorted into those once a tile, and the loop over the rows is made for
//! each of the three, so that it holds its edges in registers and asks
//! nothing of them while it runs.
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
//! The numbers cannot overflow - an edge's values stay well inside 64
//! bits anywhere in the guard band (setup.zig) - so they are added
//! wrapping, without the checks that would cost more than the adds: this
//! runs for every row of every triangle in every tile.

const bins = @import("bins.zig");
const Edge = bins.Edge;
const Header = bins.Header;
const Tile = @import("target.zig").Tile;

/// Each row's run of `triangle` in `tile`, top to bottom, handed to
/// `run(context, y, left, right)`: row `y` from the tile's top, its pixels
/// `left` to one before `right` from the tile's left. Rows with nothing
/// inside are left out.
pub inline fn runs(tile: *const Tile, triangle: *const Header, context: anytype, comptime run: anytype) void {
    walk(false, tile, triangle, context, run);
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
/// box always are; a pair with nothing in either is left out.
pub inline fn quads(tile: *const Tile, triangle: *const Header, context: anytype, comptime run: anytype) void {
    walk(true, tile, triangle, context, run);
}

inline fn walk(comptime paired: bool, tile: *const Tile, triangle: *const Header, context: anytype, comptime run: anytype) void {
    const span = tile.span(triangle) orelse return;
    const edges = &triangle.edges;
    var top = span.top;
    var bottom = span.bottom;
    var in: [2]u8 = undefined;
    var out: [2]u8 = undefined;
    var ins: u8 = 0;
    var outs: u8 = 0;
    inline for (edges, 0..) |edge, i| {
        if (edge.a > 0) {
            in[ins] = i;
            ins += 1;
        } else if (edge.a < 0) {
            out[outs] = i;
            outs += 1;
        } else {
            // Along the rows: row k down from the top has the value
            // `value + k * b`, and b is not 0 - the triangle has an area.
            const value = edge.at(tile.x, tile.y + @as(i64, top));
            const height: i64 = bottom - top;
            if (edge.b > 0) {
                // Inside from the row where it reaches 0 on.
                const first = if (value >= 0) 0 else @divFloor(-value + edge.b - 1, edge.b);
                if (first >= height) return;
                top += @intCast(first);
            } else {
                // Inside down to the row where it falls below 0.
                if (value < 0) return;
                const last = @divFloor(value, -edge.b);
                if (last + 1 < height) bottom = top + @as(u32, @intCast(last + 1));
            }
        }
    }

    const x: i64 = tile.x + span.left;
    const y: i64 = tile.y + top;
    const box = Box{ .left = span.left, .width = span.right - span.left, .top = top, .bottom = bottom };
    if (ins == 2) {
        rows(paired, 2, 1, .{ .of(edges[in[0]], x, y), .of(edges[in[1]], x, y) }, .{.of(edges[out[0]], x, y)}, box, context, run);
    } else if (outs == 2) {
        rows(paired, 1, 2, .{.of(edges[in[0]], x, y)}, .{ .of(edges[out[0]], x, y), .of(edges[out[1]], x, y) }, box, context, run);
    } else if (ins == 1 and outs == 1) {
        rows(paired, 1, 1, .{.of(edges[in[0]], x, y)}, .{.of(edges[out[0]], x, y)}, box, context, run);
    }
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
/// go out: each row's run, or each pair's.
inline fn rows(
    comptime paired: bool,
    comptime n_in: usize,
    comptime n_out: usize,
    in: [n_in]Crossing(.comes_in),
    out: [n_out]Crossing(.goes_out),
    box: Box,
    context: anytype,
    comptime run: anytype,
) void {
    var comes_in = in;
    var goes_out = out;
    // With pairs: the even row's run, until its pair is made.
    var upper = Span.none;
    var y = box.top;
    while (y < box.bottom) : (y += 1) {
        var first: i64 = 0;
        var end: i64 = box.width;
        inline for (&comes_in) |*crossing| {
            first = @max(first, crossing.column);
            crossing.down();
        }
        inline for (&goes_out) |*crossing| {
            end = @min(end, crossing.column);
            crossing.down();
        }
        if (!paired) {
            if (first < end) run(context, y, box.left +% column(first), box.left +% column(end));
            continue;
        }
        const here = if (first < end) Span{ .left = box.left +% column(first), .right = box.left +% column(end) } else Span.none;
        if (y & 1 == 0) {
            upper = here;
            if (y + 1 == box.bottom and !here.empty()) run(context, y, here, Span.none);
        } else {
            if (!upper.empty() or !here.empty()) run(context, y - 1, upper, here);
            upper = Span.none;
        }
    }
}

/// A column of the box, 0 to its width: a run's ends once they are cut to
/// the box.
inline fn column(at: i64) u32 {
    return @truncate(@as(u64, @bitCast(at)));
}

/// Which way an edge crosses the rows, going right.
const Way = enum { comes_in, goes_out };

/// An edge where it crosses the row under way.
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

        inline fn of(edge: Edge, x: i64, y: i64) Self {
            const step: i64 = @intCast(@abs(edge.a));
            const at = edge.at(x, y);
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
