// SPDX-License-Identifier: MPL-2.0
//! Pipeline(cfg): a way of drawing triangles, made at compile time.
//!
//! `cfg` says what a vertex carries and what is done with it - where the
//! colour comes from, which triangles are culled - and the pipeline made
//! from it has a vertex type of its own, and a draw and a tile loop built
//! for that alone: nothing in them asks at run time what the pipeline is.
//! What may change from draw to draw - the transform, the viewport, a
//! colour - is in the pipeline's fields.
//!
//! A draw runs on the caller: the vertices transformed into clip space
//! once each, the triangles put together from the indices, dropped when
//! wholly outside the view, cut where they cross the near plane or the
//! guard band, projected, snapped and culled, and each set up for the
//! tiles - its edges, its box, its colour, its depth - in the frame's
//! memory. Then each goes on the list of every tile it touches.
//!
//! With a depth test a pixel's depth is worked out from the triangle's
//! plane once a run and stepped along it in fixed point, and tested
//! against the tile's before the pixel's colour is, unless `early_depth`
//! is off. On the VisionFive 2 a test costs about 8 cycles a pixel: two
//! layers over 800 x 600 took 6.0 ms without depth and 8.5 ms with, the
//! front layer drawn first, 8.8 ms the back one first.

const std = @import("std");
const bins = @import("bins.zig");
const setup = @import("setup.zig");
const target_zig = @import("target.zig");
const Target = target_zig.Target;
const Tile = target_zig.Tile;
const walk = @import("walk.zig");
const Header = bins.Header;
const tile_size = target_zig.tile_size;

pub const Viewport = setup.Viewport;
pub const Winding = setup.Winding;
pub const Cull = setup.Cull;

/// A transform: 4 x 4, column after column, as clip = M * (x, y, z, 1).
pub const Matrix = [16]f32;

pub const identity: Matrix = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

/// Where a triangle's colour comes from.
pub const ColorSource = enum {
    /// The pipeline's `color`, every triangle.
    constant,
    /// Each vertex carries one; a triangle is its first vertex's.
    flat,
};

/// Which of a triangle's pixels the depth test keeps, against the depth
/// already in the tile.
pub const DepthTest = enum {
    /// Every one: no test, and nothing written to the depth.
    off,
    /// Those nearer.
    less,
    /// Those nearer or as near.
    less_equal,
};

/// What a pipeline is.
pub const Config = struct {
    color: ColorSource = .constant,
    cull: Cull = .back,
    /// Which way round the front of a triangle is, seen on the surface.
    front: Winding = .counter_clockwise,
    /// A pixel the test keeps writes its depth. On a target without depth
    /// the test is off.
    depth: DepthTest = .off,
    /// Whether a pixel is tested before its colour is worked out, so that
    /// one behind costs nothing more, or after.
    early_depth: bool = true,
};

pub fn Pipeline(comptime config: Config) type {
    return struct {
        /// From the vertices' space to clip space.
        transform: Matrix = identity,
        /// Where clip space lands on the surface.
        viewport: Viewport,
        /// 0xAARRGGBB: every triangle's colour, with `.constant`.
        color: u32 = 0xFFFF_FFFF,

        const Self = @This();

        pub const cfg = config;

        const VertexColor = if (config.color == .flat) u32 else void;
        const no_color: VertexColor = if (config.color == .flat) 0xFFFF_FFFF else {};

        /// A vertex: where it is, and what it carries.
        pub const Vertex = struct {
            position: [3]f32,
            /// 0xAARRGGBB.
            color: VertexColor = no_color,
        };

        /// A vertex in clip space: nothing more is carried through a cut.
        const Clip = setup.ClipVertex(0);

        const tests_depth = config.depth != .off;

        /// A triangle set up for the tiles.
        const Triangle = struct {
            header: Header,
            /// Its colour, in the surface's format.
            pixel: u32,
            depth: if (tests_depth) setup.Depth else void,
        };

        /// The triangles drawn into `target`, three indices each, as this
        /// pipeline draws them. Indices past the vertices leave their
        /// triangle out. error.OutOfMemory when the frame's memory ran out:
        /// what was set up by then is drawn, the rest not.
        pub fn drawInto(pipeline: *const Self, target: *Target, vertices: []const Vertex, indices: anytype) error{OutOfMemory}!void {
            const started = target.now();
            const first_pending = target.pending_count;
            // What was set up before memory ran out is binned all the same.
            const done = pipeline.setUpAll(target, vertices, indices);
            const set_up = target.now();
            try target.bin(first_pending);
            target.stats.setup_us += set_up - started;
            target.stats.binning_us += target.now() - set_up;
            return done;
        }

        /// Every triangle of the draw set up and put on the pending list.
        fn setUpAll(pipeline: *const Self, target: *Target, vertices: []const Vertex, indices: anytype) error{OutOfMemory}!void {
            const clip = target.arena.alloc(Clip, vertices.len) orelse return error.OutOfMemory;
            const codes = target.arena.alloc(u8, vertices.len) orelse return error.OutOfMemory;
            const guard = setup.Guard.of(pipeline.viewport);
            for (vertices, clip, codes) |vertex, *into, *code| {
                into.* = .{ .position = transformed(&pipeline.transform, vertex.position), .values = .{} };
                code.* = setup.outcode(into.position, guard);
            }

            var at: usize = 0;
            while (at + 3 <= indices.len) : (at += 3) {
                target.stats.triangles += 1;
                const which = [3]usize{ indices[at], indices[at + 1], indices[at + 2] };
                if (which[0] >= vertices.len or which[1] >= vertices.len or which[2] >= vertices.len) continue;
                const code = [3]u8{ codes[which[0]], codes[which[1]], codes[which[2]] };
                // Wholly outside one side of the view.
                if (code[0] & code[1] & code[2] & 63 != 0) {
                    target.stats.dropped += 1;
                    continue;
                }
                const color = switch (config.color) {
                    .constant => pipeline.color,
                    .flat => vertices[which[0]].color,
                };
                const corners = [3]Clip{ clip[which[0]], clip[which[1]], clip[which[2]] };
                if ((code[0] | code[1] | code[2]) & setup.must_cut == 0) {
                    try pipeline.setUp(target, corners, color);
                    continue;
                }
                target.stats.cut += 1;
                var polygon: [setup.most_cut]Clip = undefined;
                const count = setup.cut(Clip, corners, guard, &polygon);
                if (count < 3) continue;
                for (1..count - 1) |k| try pipeline.setUp(target, .{ polygon[0], polygon[k], polygon[k + 1] }, color);
            }
        }

        /// One triangle in clip space projected, culled and set up.
        fn setUp(pipeline: *const Self, target: *Target, corners: [3]Clip, color: u32) error{OutOfMemory}!void {
            var projected: [3]setup.Projected = undefined;
            for (&projected, corners) |*into, corner| into.* = setup.project(corner.position, pipeline.viewport);
            const made = setup.onSurface(projected, config.cull, config.front, target.areaBounds()) orelse {
                target.stats.dropped += 1;
                return;
            };
            const triangle = target.arena.create(Triangle) orelse return error.OutOfMemory;
            triangle.* = .{
                .header = .{
                    .raster = if (tests_depth and target.attachments.depth.used) &rasterDepth else &rasterFlat,
                    .left = made.left,
                    .top = made.top,
                    .right = made.right,
                    .bottom = made.bottom,
                    .edges = made.edges,
                },
                .pixel = target.surface.format.pack(color),
                .depth = if (tests_depth) .of(&made, &projected) else {},
            };
            try target.addPending(&triangle.header);
        }

        /// A triangle of one colour drawn over its pixels in a tile.
        fn rasterFlat(tile: *const Tile, header: *const Header) void {
            const triangle: *const Triangle = @alignCast(@fieldParentPtr("header", header));
            walk.runs(tile, header, Flat{ .tile = tile, .pixel = triangle.pixel }, Flat.run);
        }

        /// What a flat triangle's runs are filled with, and where.
        const Flat = struct {
            tile: *const Tile,
            pixel: u32,

            inline fn run(flat: Flat, y: u32, left: u32, right: u32) void {
                walk.fill(flat.tile.row(y), left, right, flat.pixel);
            }
        };

        /// A triangle of one colour drawn over those of its pixels the
        /// depth test keeps.
        fn rasterDepth(tile: *const Tile, header: *const Header) void {
            const triangle: *const Triangle = @alignCast(@fieldParentPtr("header", header));
            walk.runs(tile, header, Tested{ .tile = tile, .depth = triangle.depth, .pixel = triangle.pixel }, Tested.run);
        }

        /// A run tested pixel by pixel against the tile's depth. What it
        /// needs of the triangle is copied in, where the stores into the
        /// tile cannot change it, so that it stays in registers.
        const Tested = struct {
            tile: *const Tile,
            depth: setup.Depth,
            pixel: u32,

            inline fn run(tested: Tested, y: u32, left: u32, right: u32) void {
                const tile = tested.tile;
                var z = tested.depth.at(tile.x + left, tile.y + y);
                for (tile.depthRow(y)[left..right], tile.row(y)[left..right]) |*kept, *pixel| {
                    const near = @as(u64, @bitCast(z)) >> setup.Depth.fraction;
                    z +%= tested.depth.step;
                    const late = if (config.early_depth) {} else tested.color();
                    if (passes(near, kept.*)) {
                        kept.* = @truncate(near);
                        pixel.* = if (config.early_depth) tested.color() else late;
                    }
                }
            }

            /// The pixel's colour: the fragment, which costs nothing yet.
            inline fn color(tested: Tested) u32 {
                return tested.pixel;
            }
        };

        inline fn passes(near: u64, kept: u16) bool {
            return switch (config.depth) {
                .off => true,
                .less => near < kept,
                .less_equal => near <= kept,
            };
        }
    };
}

/// `m * (p, 1)`.
fn transformed(m: *const Matrix, p: [3]f32) [4]f32 {
    var out: [4]f32 = undefined;
    for (&out, 0..) |*o, row| o.* = m[row] * p[0] + m[4 + row] * p[1] + m[8 + row] * p[2] + m[12 + row];
    return out;
}

/// The triangles drawn: the module's one call that draws.
pub fn draw(target: *Target, pipeline: anytype, vertices: []const @TypeOf(pipeline.*).Vertex, indices: anytype) error{OutOfMemory}!void {
    return pipeline.drawInto(target, vertices, indices);
}
