// SPDX-License-Identifier: MPL-2.0
//! Batched draws: triangles whose pixels are coloured by a fragment
//! function given at run time (sdk.facet.shader) - facet.library's
//! pipelines - where a Pipeline(cfg)'s are coloured by code made for it
//! at compile time.
//!
//! A draw is given its vertices in clip space as the vertex function
//! wrote them, the position and then the varyings, and does what
//! Pipeline's does: drops, cuts, projects, culls and sets up each
//! triangle - with a plane for 1 / w and one for each varying over w -
//! and puts it on the lists of the tiles it touches. In a tile, the walk
//! goes over a triangle's rows a pair at a time, tests each quad against
//! the depth and writes the depth of the pixels kept, and gathers the
//! quads with any pixel kept into a batch. A full batch, and the last
//! one at the triangle's end, goes to the fragment function, and the
//! colours it writes for the pixels kept go into the tile, blended.
//!
//! The depth test is made at compile time for none, less and less or
//! equal - the tests depth buffers are drawn with - and for any other
//! through a mask; the blend is chosen once a batch. Neither is asked
//! about for each pixel. A batch costs the fragment function's call and
//! its quads a few loads and stores each more than Pipeline's quads,
//! which are coloured where they are found.
//!
//! A draw may ask for the depth pre-pass (prepass.zig), and has it when
//! its depth is tested less or less or equal and written, and it is not
//! blended: then a pixel is shaded once, by the nearest, whatever order
//! the triangles come in.

const std = @import("std");
const shader = @import("sdk").facet.shader;
const bins = @import("bins.zig");
const setup = @import("setup.zig");
const target_zig = @import("target.zig");
const pipeline = @import("pipeline.zig");
const walk = @import("walk.zig");
const prepass = @import("prepass.zig");
const Target = target_zig.Target;
const Tile = target_zig.Tile;
const Rect = target_zig.Rect;
const Header = bins.Header;
const Span = walk.Span;
const tile_size = target_zig.tile_size;

/// The most floats a vertex carries past its position.
pub const most_varyings = 8;

/// The quads a batch holds.
pub const batch_quads = 64;

/// How a depth is compared with the one kept: the pixel passes where it
/// is so to it. The numbers are a mask - 1 less, 2 equal, 4 greater - and
/// Vulkan's.
pub const Compare = enum(u3) {
    never = 0,
    less = 1,
    equal = 2,
    less_or_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_or_equal = 6,
    always = 7,
};

/// How a draw draws.
pub const State = struct {
    viewport: setup.Viewport,
    /// Where z = 0 and z = 1 land in the depth, 0 to 1.
    min_depth: f32 = 0,
    max_depth: f32 = 1,
    /// The pixels drawn, inside the target's area: those outside are not.
    scissor: Rect,
    cull: setup.Cull = .none,
    front: setup.Winding = .counter_clockwise,
    /// The depth test, on a target with depth; null, and the depth is
    /// neither tested nor written.
    depth_test: ?Compare = null,
    depth_write: bool = false,
    blend: pipeline.Blend = .off,
    /// The depth pre-pass, where the depth test is less or less or equal,
    /// the depth written and nothing blended; else no pre-pass.
    prepass: bool = false,
    /// Floats past the position a vertex carries.
    varyings: u32 = 0,
    fragment: shader.FragmentFn,
    resources: *const shader.Resources,
};

pub const Error = error{OutOfMemory};

/// The triangles drawn into `target`, three indices each into `vertices`
/// - `stride` floats each, the position and the varyings - as `state`
/// says. Indices past the vertices leave their triangle out.
/// error.OutOfMemory when the frame's memory ran out: what was set up by
/// then is drawn, the rest not.
pub fn draw(target: *Target, state: *const State, vertices: []const f32, stride: u32, indices: []const u32) Error!void {
    const started = target.now();
    const first_pending = target.pending_count;
    const done = setUpAll(target, state, vertices, stride, indices);
    const set_up = target.now();
    try target.bin(first_pending);
    target.stats.setup_us += set_up - started;
    target.stats.binning_us += target.now() - set_up;
    return done;
}

/// What the tiles need of a draw, once for all its triangles.
const Shading = struct {
    fragment: shader.FragmentFn,
    resources: *const shader.Resources,
    plane_count: u32,
    compare: Compare,
    depth_write: bool,
    blend: pipeline.Blend,
};

/// A triangle set up for the tiles: its planes follow it.
const Triangle = struct {
    header: Header,
    shading: *const Shading,
    depth: setup.Depth,
    /// The least 1 / w of its vertices: the least anywhere inside.
    least_inverse_w: f32,

    fn planes(triangle: *const Triangle) [*]const shader.Plane {
        return @ptrFromInt(@intFromPtr(triangle) + @sizeOf(Triangle));
    }
};

const Clip = setup.ClipVertex(most_varyings);

/// How the depth is tested in a tile: by the draw's test, or - `second`
/// and `second_or_equal` - as the pre-pass's second pass does after a
/// test of less or of less or equal (`prepass.keep`).
const Test = enum { off, less, less_or_equal, masked, second, second_or_equal };

/// A triangle in the pre-pass: its depth alone, then its quads tested as
/// `second` says.
fn TwoPasses(comptime second: Test) type {
    return struct {
        const passes = bins.Prepass{ .depth = &prepass.DepthOnly(Triangle).raster, .shade = &Rasterize(second).raster };
    };
}

/// Every triangle of the draw set up and put on the pending list.
fn setUpAll(target: *Target, state: *const State, vertices: []const f32, stride: u32, indices: []const u32) error{OutOfMemory}!void {
    const count = vertices.len / stride;
    const depth = target.attachments.depth.used and state.depth_test != null;
    const compare = if (depth) state.depth_test.? else .always;
    if (compare == .never) return;
    const area = scissored(target.areaBounds(), state.scissor) orelse return;
    const shading = target.arena.create(Shading) orelse return error.OutOfMemory;
    shading.* = .{
        .fragment = state.fragment,
        .resources = state.resources,
        .plane_count = 1 + state.varyings,
        .compare = compare,
        .depth_write = depth and state.depth_write,
        .blend = state.blend,
    };
    const test_kind: Test = if (!depth) .off else switch (compare) {
        .less => .less,
        .less_or_equal => .less_or_equal,
        else => .masked,
    };
    const raster = switch (test_kind) {
        inline .off, .less, .less_or_equal, .masked => |kind| &Rasterize(kind).raster,
        .second, .second_or_equal => unreachable,
    };
    const two = state.prepass and shading.depth_write and state.blend == .off;
    const passes: ?*const bins.Prepass = if (!two) null else switch (test_kind) {
        .less => &TwoPasses(.second).passes,
        .less_or_equal => &TwoPasses(.second_or_equal).passes,
        else => null,
    };
    const codes = target.arena.alloc(u8, count) orelse return error.OutOfMemory;
    const guard = setup.Guard.of(state.viewport);
    for (codes, 0..) |*code, k| code.* = setup.outcode(position(vertices, stride, k).*, guard);

    const set: SetUp = .{ .target = target, .state = state, .shading = shading, .raster = raster, .prepass = passes, .area = area, .depth = depth };
    var at: usize = 0;
    while (at + 3 <= indices.len) : (at += 3) {
        target.stats.triangles += 1;
        const which = [3]usize{ indices[at], indices[at + 1], indices[at + 2] };
        if (which[0] >= count or which[1] >= count or which[2] >= count) continue;
        const code = [3]u8{ codes[which[0]], codes[which[1]], codes[which[2]] };
        // Wholly outside one side of the view.
        if (code[0] & code[1] & code[2] & 63 != 0) {
            target.stats.dropped += 1;
            continue;
        }
        if ((code[0] | code[1] | code[2]) & setup.must_cut == 0) {
            var positions: [3]*const [4]f32 = undefined;
            var carried: [3][*]const f32 = undefined;
            for (which, &positions, &carried) |k, *p, *c| {
                p.* = position(vertices, stride, k);
                c.* = vertices[k * stride + 4 ..].ptr;
            }
            try set.one(positions, carried);
            continue;
        }
        target.stats.cut += 1;
        var corners: [3]Clip = undefined;
        for (&corners, which) |*corner, k| {
            corner.position = position(vertices, stride, k).*;
            corner.values = @splat(0);
            @memcpy(corner.values[0..state.varyings], vertices[k * stride + 4 ..][0..state.varyings]);
        }
        var polygon: [setup.most_cut]Clip = undefined;
        const made = setup.cut(Clip, corners, guard, &polygon);
        if (made < 3) continue;
        for (1..made - 1) |k| {
            const three = [3]*const Clip{ &polygon[0], &polygon[k], &polygon[k + 1] };
            try set.one(.{ &three[0].position, &three[1].position, &three[2].position }, .{ &three[0].values, &three[1].values, &three[2].values });
        }
    }
}

/// Vertex `k`'s position.
fn position(vertices: []const f32, stride: u32, k: usize) *const [4]f32 {
    return vertices[k * stride ..][0..4];
}

/// The area's bounds cut to the scissor, or null where nothing is left.
fn scissored(area: [4]i32, scissor: Rect) ?[4]i32 {
    const left = @max(area[0], @as(i64, scissor.x));
    const top = @max(area[1], @as(i64, scissor.y));
    const right = @min(area[2], @as(i64, scissor.x) + scissor.width);
    const bottom = @min(area[3], @as(i64, scissor.y) + scissor.height);
    if (left >= right or top >= bottom) return null;
    return .{ @intCast(left), @intCast(top), @intCast(right), @intCast(bottom) };
}

/// What setting up a draw's triangles goes by.
const SetUp = struct {
    target: *Target,
    state: *const State,
    shading: *const Shading,
    raster: *const fn (tile: *const Tile, header: *const Header) void,
    prepass: ?*const bins.Prepass,
    area: [4]i32,
    depth: bool,

    /// One triangle in clip space projected, culled and set up: its
    /// vertices' positions, and what each carries.
    fn one(set: SetUp, positions: [3]*const [4]f32, carried: [3][*]const f32) error{OutOfMemory}!void {
        const target = set.target;
        const state = set.state;
        var projected: [3]setup.Projected = undefined;
        for (&projected, positions) |*into, p| into.* = setup.project(p.*, state.viewport);
        const made = switch (state.cull) {
            inline else => |cull| switch (state.front) {
                inline else => |front| setup.onSurface(projected, cull, front, set.area),
            },
        } orelse {
            target.stats.dropped += 1;
            return;
        };
        const plane_count = set.shading.plane_count;
        const bytes = @sizeOf(Triangle) + plane_count * @sizeOf(shader.Plane);
        const memory = target.arena.allocate(bytes, @alignOf(Triangle)) orelse return error.OutOfMemory;
        const triangle: *Triangle = @ptrCast(@alignCast(memory));
        triangle.* = .{
            .header = .{
                .raster = set.raster,
                .left = made.left,
                .top = made.top,
                .right = made.right,
                .bottom = made.bottom,
                .edges = made.edges,
                .prepass = set.prepass,
            },
            .shading = set.shading,
            .depth = if (set.depth) depthOf(&made, projected, state) else undefined,
            .least_inverse_w = @min(projected[0].inverse_w, projected[1].inverse_w, projected[2].inverse_w),
        };
        const planes: [*]shader.Plane = @ptrFromInt(@intFromPtr(triangle) + @sizeOf(Triangle));
        planesOf(&made, &projected, carried, planes[0..plane_count]);
        bins.sortForWalk(&triangle.header.edges);
        try target.addPending(&triangle.header);
    }
};

/// The depth of a triangle, its vertices' z moved into the depth range.
fn depthOf(made: *const setup.Triangle, projected: [3]setup.Projected, state: *const State) setup.Depth {
    var ranged = projected;
    if (state.min_depth != 0 or state.max_depth != 1) {
        for (&ranged) |*vertex| vertex.z = std.math.clamp(state.min_depth + vertex.z * (state.max_depth - state.min_depth), 0, 1);
    }
    return .of(made, &ranged);
}

/// The planes of a triangle: 1 / w, then each varying over w.
fn planesOf(made: *const setup.Triangle, projected: *const [3]setup.Projected, carried: [3][*]const f32, planes: []shader.Plane) void {
    const vertices = made.inOrder(projected);
    const values = made.inOrder(&carried);
    var inverse_w: [3]f64 = undefined;
    for (&inverse_w, vertices) |*into, vertex| into.* = vertex.inverse_w;
    planes[0] = planeOf(made, inverse_w);
    for (planes[1..], 0..) |*plane, k| {
        var over_w: [3]f64 = undefined;
        for (&over_w, values, inverse_w) |*into, corner, over| into.* = corner[k] * over;
        plane.* = planeOf(made, over_w);
    }
}

fn planeOf(made: *const setup.Triangle, values: [3]f64) shader.Plane {
    const plane = setup.Plane.of(setup.Linear.of(made, values), made);
    return .{ .origin = plane.origin, .dx = plane.dx, .dy = plane.dy };
}

/// How the tiles draw a draw's triangles, testing the depth as `kind`
/// says.
fn Rasterize(comptime kind: Test) type {
    return struct {
        // On a cache line, as a segment is loaded on one: placed wherever
        // the code before it ended, the quads' loops took the cube up to
        // 0.3 ms a frame more on the U74s, from one build to the next.
        fn raster(tile: *const Tile, header: *const Header) align(64) void {
            // The quads' loops, inlined for each way the edges run, unroll
            // more than the default allows.
            @setEvalBranchQuota(10_000);
            const triangle: *const Triangle = @alignCast(@fieldParentPtr("header", header));
            var batch: Batch = undefined;
            batch.start(tile, triangle);
            walk.quads(tile, header, Walker{ .tile = tile, .batch = &batch, .depth = triangle.depth, .shading = triangle.shading }, Walker.run);
            batch.flush();
        }

        /// What the walk goes by over a triangle's rows in a tile.
        const Walker = struct {
            tile: *const Tile,
            batch: *Batch,
            depth: setup.Depth,
            shading: *const Shading,

            /// Rows `y` and `y + 1`, the quads from the even column at or
            /// left of the first pixel of either run to past the last of
            /// either.
            inline fn run(walker: Walker, y: u32, upper: Span, lower: Span) void {
                // This runs for every quad: its numbers are held inside
                // their ranges, and the checks would cost more than the
                // work.
                @setRuntimeSafety(false);
                const first = if (upper.empty()) lower.left else if (lower.empty()) upper.left else @min(upper.left, lower.left);
                const end = @max(upper.right, lower.right);
                var x = first & ~@as(u32, 1);
                const tested = kind != .off;
                const step = if (tested) walker.depth.step else 0;
                var z_upper: i64 = if (tested) walker.rowDepth(upper, x, y) else 0;
                var z_lower: i64 = if (tested) walker.rowDepth(lower, x, y + 1) else 0;
                const depths = walker.tile.depthRow(y);
                const second = kind == .second or kind == .second_or_equal;
                const write = tested and !second and walker.shading.depth_write;
                // The batch's count held here while the row is walked:
                // in memory it would be read again after every quad
                // stored.
                const batch = walker.batch;
                var count = batch.count;
                defer batch.count = count;
                while (x < end) : ({
                    x += 2;
                    z_upper +%= 2 *% step;
                    z_lower +%= 2 *% step;
                }) {
                    const covered = @as(u4, @intFromBool(upper.holds(x))) | @as(u4, @intFromBool(upper.holds(x + 1))) << 1 |
                        @as(u4, @intFromBool(lower.holds(x))) << 2 | @as(u4, @intFromBool(lower.holds(x + 1))) << 3;
                    var kept = covered;
                    if (tested) {
                        const near = [4]u64{ units(z_upper), units(z_upper +% step), units(z_lower), units(z_lower +% step) };
                        if (second) {
                            kept = prepass.keep(walker.tile, kind == .second_or_equal, x, y, covered, near, depths);
                        } else inline for (0..4) |i| {
                            if (kept >> i & 1 != 0 and !walker.passes(near[i], depths[offset(i) + x])) kept &= ~(@as(u4, 1) << i);
                        }
                        if (write) inline for (0..4) |i| {
                            if (kept >> i & 1 != 0) depths[offset(i) + x] = @truncate(near[i]);
                        };
                    }
                    if (kept == 0) continue;
                    batch.quads[count] = .{ .x = @intCast(x), .y = @intCast(y), .covered = covered, .kept = kept };
                    count += 1;
                    if (count == batch_quads) {
                        batch.count = count;
                        batch.flush();
                        count = 0;
                    }
                }
            }

            /// A row's depth at column `x`: from where its run starts,
            /// stepped back. 0 for a row with nothing in it.
            inline fn rowDepth(walker: Walker, span: Span, x: u32, y: u32) i64 {
                if (span.empty()) return 0;
                const tile = walker.tile;
                return walker.depth.at(tile.x + span.left, tile.y + y) -% @as(i64, span.left - x) *% walker.depth.step;
            }

            inline fn passes(walker: Walker, near: u64, kept: u16) bool {
                return switch (kind) {
                    .off => true,
                    .less => near < kept,
                    .less_or_equal => near <= kept,
                    .second, .second_or_equal => unreachable,
                    .masked => mask: {
                        // 0 less, 1 equal, 2 greater.
                        const order: u3 = @as(u3, @intFromBool(near >= kept)) + @intFromBool(near > kept);
                        break :mask @as(u8, @intFromEnum(walker.shading.compare)) >> order & 1 != 0;
                    },
                };
            }
        };
    };
}

inline fn units(z: i64) u64 {
    return @as(u64, @bitCast(z)) >> setup.Depth.fraction;
}

/// Pixel `i` of a quad - left, right, then the same a row down - from its
/// top left, in a tile's rows.
inline fn offset(comptime i: u32) u32 {
    return (i >> 1) * tile_size + (i & 1);
}

/// A triangle's quads in a tile on their way to the fragment function,
/// and what it is given with them.
const Batch = struct {
    count: u32,
    tile: *const Tile,
    shading: *const Shading,
    fragments: shader.Fragments,
    quads: [batch_quads]shader.Quad,
    colors: [batch_quads][4]u32 align(8),
    /// The triangle's planes moved to the tile's top left, where their
    /// numbers are smallest.
    planes: [1 + most_varyings]shader.Plane,

    fn start(batch: *Batch, tile: *const Tile, triangle: *const Triangle) void {
        const shading = triangle.shading;
        const across: f32 = @floatFromInt(@as(i64, tile.x) - triangle.header.left);
        const down: f32 = @floatFromInt(@as(i64, tile.y) - triangle.header.top);
        const given = triangle.planes();
        for (batch.planes[0..shading.plane_count], given[0..shading.plane_count]) |*plane, from| {
            plane.* = from;
            plane.origin += from.dx * across + from.dy * down;
        }
        // How much 1 / w changes a pixel aslant, against the least it is
        // at a quad's centre in the tile: no less than at the tile's
        // corners, nor than inside the triangle, and a centre is less than
        // a pixel aslant from a pixel inside. A NaN divides.
        const inverse_w = batch.planes[0];
        const change = @abs(inverse_w.dx) + @abs(inverse_w.dy);
        const last: f32 = tile_size - 1;
        const corners = inverse_w.origin + @min(0, inverse_w.dx * last) + @min(0, inverse_w.dy * last);
        const least = @max(corners, triangle.least_inverse_w) - change;
        batch.count = 0;
        batch.tile = tile;
        batch.shading = shading;
        batch.fragments = .{
            .quads = &batch.quads,
            .count = 0,
            .colors = &batch.colors,
            .planes = &batch.planes,
            .plane_count = shading.plane_count,
            .x = tile.x,
            .y = tile.y,
            .exact = !(least > 0 and change <= least * newton_change),
            .resources = shading.resources,
        };
    }

    /// The quads gathered coloured by the fragment function, and the
    /// pixels kept put into the tile.
    fn flush(batch: *Batch) void {
        if (batch.count == 0) return;
        batch.fragments.count = batch.count;
        batch.shading.fragment(&batch.fragments);
        switch (batch.shading.blend) {
            inline else => |blend| batch.put(blend),
        }
        batch.count = 0;
    }

    inline fn put(batch: *Batch, comptime blend: pipeline.Blend) void {
        @setRuntimeSafety(false);
        // The tile's colours held here: through the tile they would be
        // read again after every pixel stored.
        const pixels: [*]u32 = &batch.tile.buffer.color;
        for (batch.quads[0..batch.count], batch.colors[0..batch.count]) |quad, *colors| {
            const at = pixels + @as(u32, quad.y) * tile_size + quad.x;
            if (quad.kept == 0xF and blend == .off) {
                // A row of a quad a store: its column is even, and its two
                // pixels are 8 bytes aligned, in the tile and here.
                const pairs: *const [2]u64 = @ptrCast(@alignCast(colors));
                inline for (0..2) |row| @as(*u64, @ptrCast(@alignCast(at + row * tile_size))).* = pairs[row];
            } else inline for (0..4) |i| {
                if (quad.kept >> i & 1 != 0) at[offset(i)] = pipeline.blendedBy(blend, colors[i], at[offset(i)]);
            }
        }
    }
};

/// Pipeline's: how much 1 / w may change from a pixel to the next aslant
/// for a quad's centre to stand for its pixels.
const newton_change = pipeline.newton_change;
