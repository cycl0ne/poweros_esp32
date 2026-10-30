// SPDX-License-Identifier: MPL-2.0
//! The depth pre-pass: a tile's triangles drawn in two passes, so that a
//! pixel several of them cover is shaded once, by the nearest.
//!
//! Drawn in the order given, a pixel behind costs nothing more only when
//! what covers it came first: drawn back to front, every layer is shaded
//! and then drawn over. A pipeline that asks for the pre-pass has its
//! triangles' depth drawn into the tile first, alone - their rows walked,
//! a pixel's depth kept where it is nearer - and then, in the order given,
//! their colour only where their depth is the one left: each pixel is
//! shaded once, whatever the order. Front to back costs a little more, the
//! rows walked twice.
//!
//! Nothing drawn changes. After the first pass a pixel's depth is the
//! nearest of all; in the second, of the triangles as near as that, the
//! one shaded is the one that would have been without it - with a test of
//! `less` the first of them, with `less_or_equal` the last. Which pixels
//! the second pass has shaded is kept in a bit each (`Buffer.shaded`): a
//! triangle tested `less` is shaded only where none has been, and every
//! one marks its pixels, so pipelines of either test may share a tile.
//!
//! It covers the triangles at the head of a tile's list whose pipelines
//! ask for it. From the first that does not - blended, its depth not
//! written, its pipeline not asking - on, the triangles are drawn as they
//! would be without it, over a tile that is by then what it would have
//! been without it. Opaque triangles are drawn before blended ones anyway;
//! drawn so, the pre-pass covers all of them.

const bins = @import("bins.zig");
const setup = @import("setup.zig");
const target_zig = @import("target.zig");
const walk = @import("walk.zig");
const Tile = target_zig.Tile;
const Header = bins.Header;
const tile_size = target_zig.tile_size;

/// The first pass for a pipeline whose triangles are `Triangle`s, each
/// with a `header` and a `depth`: the depth written where it is nearer -
/// with either test, the nearest is what is left - and nothing else.
pub fn DepthOnly(comptime Triangle: type) type {
    return struct {
        pub fn raster(tile: *const Tile, header: *const Header) void {
            const triangle: *const Triangle = @alignCast(@fieldParentPtr("header", header));
            walk.runs(tile, header, Runs{ .tile = tile, .depth = triangle.depth }, Runs.run);
        }

        /// A run's depths stepped along it as the second pass's quads step
        /// them, so that the depths come out the same to the bit.
        const Runs = struct {
            tile: *const Tile,
            depth: setup.Depth,

            inline fn run(runs: Runs, y: u32, left: u32, right: u32) void {
                @setRuntimeSafety(false);
                const tile = runs.tile;
                var z = runs.depth.at(tile.x + left, tile.y + y);
                for (tile.depthRow(y)[left..right]) |*kept| {
                    const near = @as(u64, @bitCast(z)) >> setup.Depth.fraction;
                    z +%= runs.depth.step;
                    kept.* = @intCast(@min(near, kept.*));
                }
            }
        };
    };
}

/// Of the pixels `covered` of the quad at column `x` of rows `y` and
/// `y + 1`, at depths `near`, those the second pass shades: where the
/// first pass left their depth, and - tested `less`, not `or_equal` -
/// where none has been shaded before them. They are marked shaded.
pub inline fn keep(tile: *const Tile, comptime or_equal: bool, x: u32, y: u32, covered: u4, near: [4]u64, depths: [*]const u16) u4 {
    @setRuntimeSafety(false);
    const marks = &tile.buffer.shaded;
    const shift: u6 = @intCast(x);
    var kept = covered;
    if (!or_equal) kept &= ~@as(u4, @truncate(marks[y] >> shift & 3 | (marks[y + 1] >> shift & 3) << 2));
    inline for (0..4) |i| {
        if (kept >> i & 1 != 0 and near[i] != depths[offset(i) + x]) kept &= ~(@as(u4, 1) << i);
    }
    marks[y] |= @as(u64, kept & 3) << shift;
    marks[y + 1] |= @as(u64, kept >> 2) << shift;
    return kept;
}

/// Pixel `i` of a quad - left, right, then the same a row down - from its
/// top left, in a tile's rows.
inline fn offset(comptime i: u32) u32 {
    return (i >> 1) * tile_size + (i & 1);
}
