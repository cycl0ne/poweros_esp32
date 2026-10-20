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
//! front layer drawn first, 8.8 ms the back one first. A pipeline whose
//! colour changes over its triangles may ask for the depth pre-pass
//! (prepass.zig): their depth drawn first, then each pixel shaded once,
//! whatever the order they come in.
//!
//! A triangle whose colour changes over it - mixed from its vertices'
//! colours, or read from a texture at coordinates mixed from theirs - is
//! drawn in quads of 2 x 2 pixels, all four shaded whether covered or
//! not, as a GPU's quad is, and those kept written. What a vertex carries
//! is mixed as the eye sees it, not as the surface does: each value over
//! w, and 1 / w, are what change linearly over the surface, kept as
//! planes, and at a pixel the one is divided by the other. The division is made once a
//! quad, at its centre. A colour's pixels put it right with a step of
//! Newton's each - two multiplies and an add; a texture's take the
//! coordinates at the centre and how fast they change there, and step
//! from it in fixed point. Where w changes so fast in a tile that either
//! is not near enough, each pixel divides: which is settled once a tile
//! (`newton_change`), so that no quad waits on a float to know. How fast
//! the coordinates change chooses the texture's level.

const std = @import("std");
const bins = @import("bins.zig");
const setup = @import("setup.zig");
const target_zig = @import("target.zig");
const texture_zig = @import("sdk").facet.texture;
const Target = target_zig.Target;
const Tile = target_zig.Tile;
const Texture = texture_zig.Texture;
const walk = @import("walk.zig");
const prepass = @import("prepass.zig");
const Span = walk.Span;
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
    /// Each vertex carries one, and they are mixed over the triangle.
    smooth,
    /// The pipeline's `texture`, at the coordinates each vertex carries,
    /// mixed over the triangle (`Config.sampling`).
    texture,
};

/// How a pixel's colour goes into the tile.
pub const Blend = enum {
    /// It replaces what is there.
    off,
    /// It is laid over what is there by its alpha: 255 covers it, 0
    /// leaves it. All four channels are mixed, the alpha as well.
    alpha,
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
    /// The texture's format, its filter and what it does past its edges,
    /// with `.texture`.
    sampling: texture_zig.Sampling = .{},
    blend: Blend = .off,
    cull: Cull = .back,
    /// Which way round the front of a triangle is, seen on the surface.
    front: Winding = .counter_clockwise,
    /// A pixel the test keeps writes its depth. On a target without depth
    /// the test is off.
    depth: DepthTest = .off,
    /// Whether a pixel is tested before its colour is worked out, so that
    /// one behind costs nothing more, or after.
    early_depth: bool = true,
    /// The depth pre-pass (prepass.zig): the triangles' depth drawn into
    /// a tile first, then their colour only where theirs is the depth
    /// left, so that a pixel is shaded once however many cover it and in
    /// whatever order. For a colour that changes over the triangle, not
    /// blended, with a depth test; on a target without depth it is off.
    prepass: bool = false,
};

pub fn Pipeline(comptime config: Config) type {
    return struct {
        /// From the vertices' space to clip space.
        transform: Matrix = identity,
        /// Where clip space lands on the surface.
        viewport: Viewport,
        /// 0xAARRGGBB: every triangle's colour, with `.constant`.
        color: u32 = 0xFFFF_FFFF,
        /// What `.texture` paints with, in the format `cfg.sampling` says.
        texture: TextureField = no_texture,

        const Self = @This();

        pub const cfg = config;

        const textured = config.color == .texture;
        /// Drawn in quads: the colour changes over the triangle.
        const shaded = config.color == .smooth or textured;
        /// What a vertex carries over the triangle: its texture
        /// coordinates, or its colour's red, green, blue and alpha.
        const varyings = switch (config.color) {
            .constant, .flat => 0,
            .smooth => 4,
            .texture => 2,
        };
        /// 1 / w, then each varying over w.
        const plane_count = if (shaded) 1 + varyings else 0;

        const VertexColor = if (config.color == .flat or config.color == .smooth) u32 else void;
        const no_color: VertexColor = if (VertexColor == u32) 0xFFFF_FFFF else {};
        const Coordinates = if (textured) [2]f32 else void;
        const no_coordinates: Coordinates = if (textured) .{ 0, 0 } else {};
        const TextureField = if (textured) ?*const Texture else void;
        const no_texture: TextureField = if (textured) null else {};
        const TexturePointer = if (textured) *const Texture else void;

        /// A vertex: where it is, and what it carries.
        pub const Vertex = struct {
            position: [3]f32,
            /// 0xAARRGGBB.
            color: VertexColor = no_color,
            /// Where it is on the texture: 0 to 1 across it and down.
            uv: Coordinates = no_coordinates,
        };

        /// A vertex in clip space, and what it carries through a cut.
        const Clip = setup.ClipVertex(varyings);

        const tests_depth = config.depth != .off;

        comptime {
            if (config.prepass and !(shaded and config.blend == .off and tests_depth))
                @compileError("the depth pre-pass is for an unblended pipeline whose colour changes over it, with a depth test");
        }

        /// A triangle set up for the tiles.
        const Triangle = struct {
            header: Header,
            /// Its colour, 0xAARRGGBB, when it has one.
            pixel: u32,
            depth: if (tests_depth) setup.Depth else void,
            /// What changes linearly over it on the surface.
            planes: [plane_count]setup.Plane,
            /// The least 1 / w of its vertices: the least anywhere inside.
            least_inverse_w: if (shaded) f32 else void,
            texture: TexturePointer,
        };

        pub const Error = error{ OutOfMemory, BadTexture };

        /// The triangles drawn into `target`, three indices each, as this
        /// pipeline draws them. Indices past the vertices leave their
        /// triangle out. error.OutOfMemory when the frame's memory ran out:
        /// what was set up by then is drawn, the rest not.
        /// error.BadTexture, and nothing drawn, for a pipeline with
        /// `.texture` and no texture, or one in another format.
        pub fn drawInto(pipeline: *const Self, target: *Target, vertices: []const Vertex, indices: anytype) Error!void {
            const texture: TexturePointer = if (textured) texture: {
                const given = pipeline.texture orelse return error.BadTexture;
                if (given.format != config.sampling.format) return error.BadTexture;
                break :texture given;
            } else {};
            const started = target.now();
            const first_pending = target.pending_count;
            // What was set up before memory ran out is binned all the same.
            const done = pipeline.setUpAll(target, vertices, indices, texture);
            const set_up = target.now();
            try target.bin(first_pending);
            target.stats.setup_us += set_up - started;
            target.stats.binning_us += target.now() - set_up;
            return done;
        }

        /// Every triangle of the draw set up and put on the pending list.
        fn setUpAll(pipeline: *const Self, target: *Target, vertices: []const Vertex, indices: anytype, texture: TexturePointer) error{OutOfMemory}!void {
            const clip = target.arena.alloc(Clip, vertices.len) orelse return error.OutOfMemory;
            const codes = target.arena.alloc(u8, vertices.len) orelse return error.OutOfMemory;
            const guard = setup.Guard.of(pipeline.viewport);
            for (vertices, clip, codes) |vertex, *into, *code| {
                into.* = .{ .position = transformed(&pipeline.transform, vertex.position), .values = valuesOf(vertex) };
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
                    .constant, .smooth, .texture => pipeline.color,
                    .flat => vertices[which[0]].color,
                };
                const corners = [3]Clip{ clip[which[0]], clip[which[1]], clip[which[2]] };
                if ((code[0] | code[1] | code[2]) & setup.must_cut == 0) {
                    try pipeline.setUp(target, corners, color, texture);
                    continue;
                }
                target.stats.cut += 1;
                var polygon: [setup.most_cut]Clip = undefined;
                const count = setup.cut(Clip, corners, guard, &polygon);
                if (count < 3) continue;
                for (1..count - 1) |k| try pipeline.setUp(target, .{ polygon[0], polygon[k], polygon[k + 1] }, color, texture);
            }
        }

        /// What a vertex carries over the triangle.
        fn valuesOf(vertex: Vertex) [varyings]f32 {
            return switch (config.color) {
                .constant, .flat => .{},
                .smooth => .{ channel(vertex.color, 16), channel(vertex.color, 8), channel(vertex.color, 0), channel(vertex.color, 24) },
                .texture => vertex.uv,
            };
        }

        /// One triangle in clip space projected, culled and set up.
        fn setUp(pipeline: *const Self, target: *Target, corners: [3]Clip, color: u32, texture: TexturePointer) error{OutOfMemory}!void {
            var projected: [3]setup.Projected = undefined;
            for (&projected, corners) |*into, corner| into.* = setup.project(corner.position, pipeline.viewport);
            const made = setup.onSurface(projected, config.cull, config.front, target.areaBounds()) orelse {
                target.stats.dropped += 1;
                return;
            };
            const triangle = target.arena.create(Triangle) orelse return error.OutOfMemory;
            triangle.* = .{
                .header = .{
                    .raster = rasterFor(target),
                    .left = made.left,
                    .top = made.top,
                    .right = made.right,
                    .bottom = made.bottom,
                    .edges = made.edges,
                    .prepass = if (config.prepass and target.attachments.depth.used) &two_passes else null,
                },
                .pixel = color,
                .depth = if (tests_depth) .of(&made, &projected) else {},
                .planes = if (shaded) planesOf(&made, &projected, &corners) else .{},
                .least_inverse_w = if (shaded) @min(projected[0].inverse_w, projected[1].inverse_w, projected[2].inverse_w) else {},
                .texture = texture,
            };
            try target.addPending(&triangle.header);
        }

        /// The planes of a triangle: 1 / w, then each varying over w.
        fn planesOf(made: *const setup.Triangle, projected: *const [3]setup.Projected, corners: *const [3]Clip) [plane_count]setup.Plane {
            const vertices = made.inOrder(projected);
            const carried = made.inOrder(corners);
            var inverse_w: [3]f64 = undefined;
            for (&inverse_w, vertices) |*into, vertex| into.* = vertex.inverse_w;
            var planes: [plane_count]setup.Plane = undefined;
            planes[0] = .of(setup.Linear.of(made, inverse_w), made);
            for (planes[1..], 0..) |*plane, k| {
                var values: [3]f64 = undefined;
                for (&values, carried, inverse_w) |*into, corner, over| into.* = corner.values[k] * over;
                plane.* = .of(setup.Linear.of(made, values), made);
            }
            return planes;
        }

        /// How the tiles draw the triangles, with the target's depth or
        /// without.
        fn rasterFor(target: *const Target) *const fn (tile: *const Tile, header: *const Header) void {
            const depth = tests_depth and target.attachments.depth.used;
            return if (shaded)
                (if (depth) &rasterShadedDepth else &rasterShaded)
            else if (depth) &rasterDepth else &rasterFlat;
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
                switch (config.blend) {
                    .off => walk.fill(flat.tile.row(y), left, right, flat.pixel),
                    .alpha => for (flat.tile.row(y)[left..right]) |*pixel| {
                        pixel.* = blended(flat.pixel, pixel.*);
                    },
                }
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
                        pixel.* = blended(if (config.early_depth) tested.color() else late, pixel.*);
                    }
                }
            }

            /// The pixel's colour: the fragment, which costs nothing yet.
            inline fn color(tested: Tested) u32 {
                return tested.pixel;
            }
        };

        /// A triangle whose colour changes over it, drawn over its pixels
        /// in a tile a quad at a time.
        fn rasterShaded(tile: *const Tile, header: *const Header) void {
            // The quads' loops, inlined for each way the edges run and for
            // both ways of dividing, unroll more than the default allows.
            @setEvalBranchQuota(10_000);
            const triangle: *const Triangle = @alignCast(@fieldParentPtr("header", header));
            walk.quads(tile, header, Shaded(.untested).of(tile, triangle), Shaded(.untested).run);
        }

        /// The same over those of its pixels the depth test keeps.
        fn rasterShadedDepth(tile: *const Tile, header: *const Header) void {
            @setEvalBranchQuota(10_000);
            const triangle: *const Triangle = @alignCast(@fieldParentPtr("header", header));
            walk.quads(tile, header, Shaded(.tested).of(tile, triangle), Shaded(.tested).run);
        }

        /// The same over those of its pixels where its depth is what the
        /// pre-pass left: its second pass.
        fn rasterShadedSecond(tile: *const Tile, header: *const Header) void {
            @setEvalBranchQuota(10_000);
            const triangle: *const Triangle = @alignCast(@fieldParentPtr("header", header));
            walk.quads(tile, header, Shaded(.second).of(tile, triangle), Shaded(.second).run);
        }

        const two_passes = bins.Prepass{ .depth = &prepass.DepthOnly(Triangle).raster, .shade = &rasterShadedSecond };

        /// How a triangle's quads are tested against the tile's depth.
        const Testing = enum {
            untested,
            /// By the pipeline's test, and their depth written.
            tested,
            /// As the pre-pass's second pass does: their depth the one
            /// left (`prepass.keep`), and nothing written.
            second,
        };

        /// A triangle's quads in a tile, tested against its depth as
        /// `testing` says. What they need of the triangle is copied in, as
        /// with `Tested`, the planes moved to the tile's top left, where
        /// their numbers are smallest.
        fn Shaded(comptime testing: Testing) type {
            const tested = testing != .untested;
            return struct {
                tile: *const Tile,
                /// At the tile's pixel (x, y): `origin + x * dx + y * dy`.
                planes: [plane_count]setup.Plane,
                depth: if (tested) setup.Depth else void,
                texture: TexturePointer,
                /// The first level's width and height in texels, as floats.
                texels: if (textured) [2]f32 else void,
                /// Each pixel divides: w changes too fast in the tile for
                /// the centre's division and a step of Newton's.
                exact: bool,

                const Context = @This();

                const Quad = @Vector(4, f32);

                inline fn of(tile: *const Tile, triangle: *const Triangle) Context {
                    const across: f32 = @floatFromInt(@as(i64, tile.x) - triangle.header.left);
                    const down: f32 = @floatFromInt(@as(i64, tile.y) - triangle.header.top);
                    var moved = triangle.planes;
                    for (&moved) |*plane| plane.origin += plane.dx * across + plane.dy * down;
                    // How much 1 / w changes a pixel aslant, against the
                    // least it is at a quad's centre in the tile: no less
                    // than at the tile's corners, nor than inside the
                    // triangle, and a centre is less than a pixel aslant
                    // from a pixel inside. A NaN divides.
                    const inverse_w = moved[0];
                    const change = @abs(inverse_w.dx) + @abs(inverse_w.dy);
                    const last: f32 = tile_size - 1;
                    const corners = inverse_w.origin + @min(0, inverse_w.dx * last) + @min(0, inverse_w.dy * last);
                    const least = @max(corners, triangle.least_inverse_w) - change;
                    return .{
                        .tile = tile,
                        .planes = moved,
                        .depth = if (tested) triangle.depth else {},
                        .texture = triangle.texture,
                        .texels = if (textured) .{ @floatFromInt(triangle.texture.width(0)), @floatFromInt(triangle.texture.height(0)) } else {},
                        .exact = !(least > 0 and change <= least * newton_change),
                    };
                }

                /// Rows `y` and `y + 1`, the quads from the even column at
                /// or left of the first pixel of either run to past the
                /// last of either.
                inline fn run(context: Context, y: u32, upper: Span, lower: Span) void {
                    if (context.exact) context.quads(true, y, upper, lower) else context.quads(false, y, upper, lower);
                }

                inline fn quads(context: Context, comptime exact: bool, y: u32, upper: Span, lower: Span) void {
                    // This runs for every quad: its numbers are held inside
                    // their ranges, and the checks would cost more than the
                    // work (see `byteOf`).
                    @setRuntimeSafety(false);
                    const tile = context.tile;
                    const first = if (upper.empty()) lower.left else if (lower.empty()) upper.left else @min(upper.left, lower.left);
                    const end = @max(upper.right, lower.right);
                    var x = first & ~@as(u32, 1);
                    var across: f32 = @floatFromInt(x);
                    // Each plane at the rows' left.
                    const down: f32 = @floatFromInt(y);
                    var rows: [plane_count]f32 = undefined;
                    inline for (&rows, context.planes) |*value, plane| value.* = plane.origin + plane.dy * down;
                    // Each row's depth at the quad's column, stepped along
                    // two a quad.
                    const step = if (tested) context.depth.step else 0;
                    var z_upper: i64 = if (tested) context.rowDepth(upper, x, y) else 0;
                    var z_lower: i64 = if (tested) context.rowDepth(lower, x, y + 1) else 0;
                    const colors = tile.row(y);
                    const depths = tile.depthRow(y);
                    while (x < end) : ({
                        x += 2;
                        across += 2;
                        z_upper +%= 2 *% step;
                        z_lower +%= 2 *% step;
                    }) {
                        const covered = @as(u4, @intFromBool(upper.holds(x))) | @as(u4, @intFromBool(upper.holds(x + 1))) << 1 |
                            @as(u4, @intFromBool(lower.holds(x))) << 2 | @as(u4, @intFromBool(lower.holds(x + 1))) << 3;
                        // Each pixel's depth, and the pixels the test keeps.
                        var near: [4]u64 = undefined;
                        var kept = covered;
                        if (tested) {
                            near = .{ units(z_upper), units(z_upper +% step), units(z_lower), units(z_lower +% step) };
                            if (testing == .second) {
                                kept = prepass.keep(tile, config.depth == .less_equal, x, y, covered, near, depths);
                            } else inline for (0..4) |i| {
                                if (kept >> i & 1 != 0 and !passes(near[i], depths[offset(i) + x])) kept &= ~(@as(u4, 1) << i);
                            }
                        }
                        const shown = if (tested and (config.early_depth or testing == .second)) kept else covered;
                        if (shown == 0) continue;
                        const pixels = context.shade(exact, covered, rows, across);
                        if (kept == 0xF) {
                            inline for (0..4) |i| context.put(colors, depths, offset(i) + x, pixels[i], near[i]);
                        } else inline for (0..4) |i| {
                            if (kept >> i & 1 != 0) context.put(colors, depths, offset(i) + x, pixels[i], near[i]);
                        }
                    }
                }

                /// Pixel `i` of a quad - left, right, then the same a row
                /// down - from its top left, in a tile's rows.
                inline fn offset(comptime i: u32) u32 {
                    return (i >> 1) * tile_size + (i & 1);
                }

                /// A row's depth at column `x`: from where its run starts,
                /// stepped back, so that the run's pixels have the depths
                /// the runs of a flat triangle do. 0 for a row with nothing
                /// in it.
                inline fn rowDepth(context: Context, span: Span, x: u32, y: u32) i64 {
                    if (span.empty()) return 0;
                    const tile = context.tile;
                    return context.depth.at(tile.x + span.left, tile.y + y) -% @as(i64, span.left - x) *% context.depth.step;
                }

                inline fn units(z: i64) u64 {
                    return @as(u64, @bitCast(z)) >> setup.Depth.fraction;
                }

                /// A pixel kept: its colour and its depth put into the tile.
                inline fn put(_: Context, colors: [*]u32, depths: [*]u16, at: u32, color: u32, near: u64) void {
                    if (testing == .tested) depths[at] = @truncate(near);
                    colors[at] = blended(color, colors[at]);
                }

                /// The colours of the quad at column `across` of the rows
                /// whose planes start at `rows`: all four, as a GPU's quad
                /// shades its pixels outside the triangle too. Done
                /// whatever is covered, each pixel's work goes alongside
                /// the others', where pixels shaded one by one behind a
                /// branch each would wait for each load and each
                /// multiplication in turn; past the triangle the
                /// coordinates go on as they do inside, and a sample is
                /// held inside its texture wherever they go.
                inline fn shade(context: Context, comptime exact: bool, covered: u4, rows: [plane_count]f32, across: f32) [4]u32 {
                    return switch (config.color) {
                        .smooth => context.mixed(exact, covered, rows, across),
                        .texture => context.pictured(exact, rows, across),
                        .constant, .flat => unreachable,
                    };
                }

                /// Each pixel's colour mixed from the vertices': its w
                /// divided, or put right with a step of Newton's from the
                /// quad's centre's. The planes carry each channel and a
                /// half, so that cut to an integer it is rounded; inside
                /// the triangle a channel is a mix of the vertices', no
                /// further outside 0.5 to 255.5 than Newton's step leaves
                /// it, 1/4096 of it, and needs holding inside only where a
                /// pixel of the quad is past an edge.
                inline fn mixed(context: Context, comptime exact: bool, covered: u4, rows: [plane_count]f32, across: f32) [4]u32 {
                    @setRuntimeSafety(false);
                    const values = context.atPixels(rows, across);
                    const inverse_w = values[0];
                    const w = if (exact) @as(Quad, @splat(1)) / inverse_w else newton: {
                        const centre: Quad = @splat(1 / ((inverse_w[0] + inverse_w[3]) * 0.5));
                        break :newton centre + centre * (@as(Quad, @splat(1)) - inverse_w * centre);
                    };
                    // A channel at a time for the four pixels, so that
                    // each step is taken for all four together.
                    var bytes: [varyings]@Vector(4, u32) = undefined;
                    if (!exact and covered == 0xF) {
                        inline for (&bytes, values[1..]) |*channel_bytes, over_w| channel_bytes.* = @intFromFloat(over_w * w);
                    } else inline for (&bytes, values[1..]) |*channel_bytes, over_w| channel_bytes.* = bytesOf(over_w * w);
                    return bytes[3] << @splat(24) | bytes[0] << @splat(16) | bytes[1] << @splat(8) | bytes[2];
                }

                /// Each pixel's texel. Where w changes slowly enough, from
                /// the coordinates at the quad's centre - one division -
                /// and how fast they change there, in fixed point: the
                /// pixels are the centre's plus or minus half a step each
                /// way, and nothing more is worked out in floats for each.
                /// Elsewhere each pixel divides, and the steps are those
                /// between the quad's pixels.
                inline fn pictured(context: Context, comptime exact: bool, rows: [plane_count]f32, across: f32) [4]u32 {
                    @setRuntimeSafety(false);
                    const texture = context.texture;
                    const texels = context.texels;
                    var s: [4]i32 = undefined;
                    var t: [4]i32 = undefined;
                    var level: *const texture_zig.Level = undefined;
                    const bias = texture_zig.bias(config.sampling);
                    if (exact) {
                        const values = context.atPixels(rows, across);
                        const w = @as(Quad, @splat(1)) / values[0];
                        const u = values[1] * w;
                        const v = values[2] * w;
                        const lod = if (texture.levels == 1) 0 else texture_zig.levelFor(
                            texture,
                            (u[1] - u[0]) * texels[0],
                            (v[1] - v[0]) * texels[1],
                            (u[2] - u[0]) * texels[0],
                            (v[2] - v[0]) * texels[1],
                        );
                        level = &texture.layout[lod];
                        inline for (0..4) |i| {
                            s[i] = texture_zig.place(u[i] * level.across - bias);
                            t[i] = texture_zig.place(v[i] * level.down - bias);
                        }
                    } else {
                        const inverse_w = context.planes[0];
                        const u_over_w = context.planes[1];
                        const v_over_w = context.planes[2];
                        const middle = across + 0.5;
                        const w = 1 / (rows[0] + inverse_w.dx * middle + inverse_w.dy * 0.5);
                        const u = (rows[1] + u_over_w.dx * middle + u_over_w.dy * 0.5) * w;
                        const v = (rows[2] + v_over_w.dx * middle + v_over_w.dy * 0.5) * w;
                        // (u / w)' / (1 / w) - u (1 / w)' / (1 / w)
                        const du_dx = (u_over_w.dx - u * inverse_w.dx) * w;
                        const du_dy = (u_over_w.dy - u * inverse_w.dy) * w;
                        const dv_dx = (v_over_w.dx - v * inverse_w.dx) * w;
                        const dv_dy = (v_over_w.dy - v * inverse_w.dy) * w;
                        const lod = if (texture.levels == 1) 0 else texture_zig.levelFor(texture, du_dx * texels[0], dv_dx * texels[1], du_dy * texels[0], dv_dy * texels[1]);
                        level = &texture.layout[lod];
                        const s0 = texture_zig.place((u - (du_dx + du_dy) * 0.5) * level.across - bias);
                        const t0 = texture_zig.place((v - (dv_dx + dv_dy) * 0.5) * level.down - bias);
                        const s_x = texture_zig.step(du_dx * level.across);
                        const s_y = texture_zig.step(du_dy * level.across);
                        const t_x = texture_zig.step(dv_dx * level.down);
                        const t_y = texture_zig.step(dv_dy * level.down);
                        s = .{ s0, s0 +% s_x, s0 +% s_y, s0 +% s_x +% s_y };
                        t = .{ t0, t0 +% t_x, t0 +% t_y, t0 +% t_x +% t_y };
                    }
                    var pixels: [4]u32 = undefined;
                    inline for (&pixels, s, t) |*pixel, s_i, t_i| pixel.* = texture_zig.sampleAt(config.sampling, texture, level, s_i, t_i);
                    return pixels;
                }

                /// Each plane at the quad's four pixels.
                inline fn atPixels(context: Context, rows: [plane_count]f32, across: f32) [plane_count]Quad {
                    @setRuntimeSafety(false);
                    var values: [plane_count]Quad = undefined;
                    inline for (&values, rows, context.planes) |*value, row, plane| {
                        const left = row + plane.dx * across;
                        value.* = .{ left, left + plane.dx, left + plane.dy, left + plane.dx + plane.dy };
                    }
                    return values;
                }
            };
        }

        inline fn passes(near: u64, kept: u16) bool {
            return switch (config.depth) {
                .off => true,
                .less => near < kept,
                .less_equal => near <= kept,
            };
        }

        /// A pixel's colour put into the tile over `under`.
        inline fn blended(color: u32, under: u32) u32 {
            return blendedBy(config.blend, color, under);
        }
    };
}

/// A pixel's colour put into a tile over `under`, as `blend` says.
pub inline fn blendedBy(comptime blend: Blend, color: u32, under: u32) u32 {
    @setRuntimeSafety(false);
    return switch (blend) {
        .off => color,
        .alpha => alpha: {
            const alpha = color >> 24;
            const weight = alpha + (alpha >> 7);
            break :alpha texture_zig.gather(texture_zig.mix(texture_zig.spread(under), texture_zig.spread(color), weight));
        },
    };
}

/// How much 1 / w may change from a pixel to the next aslant, as a part
/// of it, in a tile drawn with the quads' centres' divisions and a step of
/// Newton's: a pixel is half that from its quad's centre, and the step
/// leaves its w out by that squared, 1/4096 of it at most.
pub const newton_change: f32 = 1.0 / 32.0;

/// A channel of 0xAARRGGBB, 0 to 255, and a half: what a smooth
/// triangle's planes carry (`mixed`).
fn channel(color: u32, comptime shift: u5) f32 {
    return @as(f32, @floatFromInt(color >> shift & 0xFF)) + 0.5;
}

/// A channel of a quad's four pixels, 0 to 255, from the channel and a
/// half. Held inside first - a NaN as well, which @min and @max pass over -
/// so the conversion cannot fail, and is not checked: on the U74 a check is
/// a compare and a branch that waits for the float, sixteen times a quad.
inline fn bytesOf(values: @Vector(4, f32)) @Vector(4, u32) {
    @setRuntimeSafety(false);
    return @intFromFloat(@min(@max(values, @as(@Vector(4, f32), @splat(0))), @as(@Vector(4, f32), @splat(255.5))));
}

/// `m * (p, 1)`.
fn transformed(m: *const Matrix, p: [3]f32) [4]f32 {
    var out: [4]f32 = undefined;
    for (&out, 0..) |*o, row| o.* = m[row] * p[0] + m[4 + row] * p[1] + m[8 + row] * p[2] + m[12 + row];
    return out;
}

/// The triangles drawn: the module's one call that draws.
pub fn draw(target: *Target, pipeline: anytype, vertices: []const @TypeOf(pipeline.*).Vertex, indices: anytype) @TypeOf(pipeline.*).Error!void {
    return pipeline.drawInto(target, vertices, indices);
}
