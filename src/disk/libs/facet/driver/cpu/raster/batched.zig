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
//!
//! A draw with a stencil test goes by way of its own, a pixel at a time and
//! asking about everything: the rest pay nothing for it.
//!
//! A draw a query is counting (`State.samples`, `State.fragments`) has its
//! pixels counted once a batch, after the fragment function has run: what
//! it was called for, and what passed the tests and it did not drop. A draw
//! nothing is counting pays one branch a batch for it.

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
/// The floats a vertex hands on past its position, from the SDK so that
/// this and `PhysicalDeviceLimits.max_vertex_output_components` are one
/// number (`shader.MAX_VARYINGS`). Only the clip path is sized by it at
/// comptime, and that is bucketed - see `Clip` and `cutUp`.
pub const most_varyings = shader.MAX_VARYINGS;

/// The quads a batch holds.
pub const batch_quads = 64;

comptime {
    // The tiles hand out room for the colour attachments past the first
    // (`Tile.extra_colors`): it has to be a batch's worth exactly.
    if (target_zig.batch_color_words != batch_quads * 4) @compileError("a tile's batch colours are not a batch's");
}

/// How a depth is compared with the one kept: the pixel passes where it
/// is so to it. The numbers are a mask - 1 less, 2 equal, 4 greater - and
/// Vulkan's.
/// What a triangle adds to its depth (`State.depth_bias`).
pub const Bias = setup.Bias;

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

/// What a stencil test does to the value kept. Numbered as Vulkan's are.
pub const StencilOp = enum(u3) { keep, zero, replace, increment, decrement, invert, increment_wrap, decrement_wrap };

/// A face's stencil test.
pub const StencilFace = struct {
    fail: StencilOp = .keep,
    pass: StencilOp = .keep,
    depth_fail: StencilOp = .keep,
    compare: Compare = .never,
    compare_mask: u8 = 0,
    write_mask: u8 = 0,
    reference: u8 = 0,

    /// Whether the value kept passes.
    inline fn passes(face: *const StencilFace, kept: u8) bool {
        return byOrder(face.compare, face.reference & face.compare_mask, kept & face.compare_mask);
    }

    /// The value to keep after `op`.
    inline fn after(face: *const StencilFace, op: StencilOp, kept: u8) u8 {
        const made: u8 = switch (op) {
            .keep => kept,
            .zero => 0,
            .replace => face.reference,
            .increment => kept +| 1,
            .decrement => kept -| 1,
            .invert => ~kept,
            .increment_wrap => kept +% 1,
            .decrement_wrap => kept -% 1,
        };
        return (kept & ~face.write_mask) | (made & face.write_mask);
    }
};

/// A stencil test that passes and writes nothing: what a draw that goes
/// by the pixel for another reason - the depth clamp, the depth bounds -
/// is given in place of a test of its own.
const keeping = StencilFace{ .compare = .always, .compare_mask = 0, .write_mask = 0 };

/// Two depths, 0 to 1, in the units the depth attachment holds: what the
/// walk compares a pixel's with. Held inside the range, and the wrong way
/// round where the two are, which then keeps nothing.
fn boundsOf(asked: [2]f32) [2]u64 {
    const whole: f32 = 65535;
    const low = @round(std.math.clamp(asked[0], 0, 1) * whole);
    const high = @round(std.math.clamp(asked[1], 0, 1) * whole);
    return .{ @intFromFloat(low), @intFromFloat(high) };
}

/// Whether a stored depth lies between the bounds; nothing lies between
/// them where they are the wrong way round, as in Vulkan.
inline fn within(there: u16, bounds: [2]u64) bool {
    return there >= bounds[0] and there <= bounds[1];
}

/// Whether `near` is as `compare` asks to `kept`.
inline fn byOrder(compare: Compare, near: anytype, kept: anytype) bool {
    // 0 less, 1 equal, 2 greater.
    const order: u3 = @as(u3, @intFromBool(near >= kept)) + @intFromBool(near > kept);
    return @as(u8, @intFromEnum(compare)) >> order & 1 != 0;
}

/// How a draw draws.
pub const State = struct {
    viewport: setup.Viewport,
    /// Where z = 0 and z = 1 land in the depth, 0 to 1.
    min_depth: f32 = 0,
    max_depth: f32 = 1,
    /// The pixels drawn, inside the target's area: those outside are not.
    scissor: Rect,
    cull: setup.Cull = .none,
    /// Which samples of a pixel a triangle may cover, from the pipeline's
    /// `PipelineMultisampleStateCreateInfo.sample_mask`; all ones where
    /// the draw gave none. One sample a pixel is drawn, so bit 0 is the
    /// whole of it: clear it and the triangle is clipped, set up and
    /// counted as such, and then nothing is shaded. The bits above are
    /// kept rather than narrowed to a bool because they are the per-sample
    /// mask a 4x walk will read (item 61). (Since 1.89.)
    sample_mask: u32 = ~@as(u32, 0),
    /// The triangles are rectangles, two each, that lines or points were
    /// widened into (`_vertices.widen`): a rectangle is one primitive to
    /// `stats.clipped`, as llvmpipe counts a line or a point once and not
    /// as the triangles facet draws it with. (Since 1.92.)
    rectangles: bool = false,
    front: setup.Winding = .counter_clockwise,
    /// The depth test, on a target with depth; null, and the depth is
    /// neither tested nor written.
    depth_test: ?Compare = null,
    depth_write: bool = false,
    /// What its triangles add to their depth before it is tested and
    /// written, or null where they add nothing. Points and lines take
    /// none, as Vulkan has it, so a draw of them leaves this null.
    depth_bias: ?Bias = null,
    /// Whether what lies past the near plane is drawn all the same, each
    /// pixel's depth held inside `min_depth` and `max_depth`, rather than
    /// cut away (`depth_clamp_enable`).
    depth_clamp: bool = false,
    /// The depths a pixel's **stored** depth has to lie between for it to
    /// be drawn, 0 to 1; null for a draw that tests no bounds
    /// (`depth_bounds_test_enable`).
    depth_bounds: ?[2]f32 = null,
    blend: pipeline.Blend = .off,
    /// How it mixes, with `.general`.
    mixing: pipeline.Mixing = .{},
    /// The blend and the mixing of the colour attachments past the first,
    /// where the draw writes several together (`color_count`, since
    /// 1.51): `blend` and `mixing` are the first's.
    more_blends: [target_zig.most_colors - 1]pipeline.Blend = @splat(.off),
    more_mixings: [target_zig.most_colors - 1]pipeline.Mixing = @splat(.{}),
    /// The colour attachments the fragment function writes in the one
    /// call: 1, and `blend` and `mixing` alone are used. (Since 1.51.)
    color_count: u32 = 1,
    /// The stencil test on a target with stencil: the front's, the back's.
    stencil: ?[2]StencilFace = null,
    /// The depth pre-pass, where the depth test is less or less or equal,
    /// the depth written and nothing blended; else no pre-pass.
    prepass: bool = false,
    /// Floats past the position a vertex carries.
    varyings: u32 = 0,
    /// The fragment function may drop a pixel by clearing its bit in
    /// `shader.Quad.kept`, so the depth is written after it has run and not
    /// in the walk that gathers the quads.
    discards: bool = false,
    fragment: shader.FragmentFn,
    resources: *const shader.Resources,
    /// Whether the fragment function is given the pixels already in the
    /// tile: a subpass that reads the attachment it draws into
    /// (`shader.Fragments.keptAt`, since 1.64).
    reads_target: bool = false,
    /// Where the pixels that passed the tests and were not dropped are
    /// counted - an occlusion query's samples - and where the pixels the
    /// fragment function was called for are. Null for a draw nothing is
    /// counting, which is every draw until a query is begun; the tiles are
    /// drawn on every core at once, so both are added to atomically.
    samples: ?*u32 = null,
    fragments: ?*u32 = null,
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
    mixing: pipeline.Mixing,
    /// Those of the colour attachments past the first, where several go
    /// together (`color_count`, since 1.51).
    more_blends: [target_zig.most_colors - 1]pipeline.Blend,
    more_mixings: [target_zig.most_colors - 1]pipeline.Mixing,
    /// The colour attachments the fragment function writes at once: 1 for
    /// every draw but one into a subpass whose attachments go together.
    color_count: u32,
    /// The depth is tested, with a stencil test.
    has_depth: bool,
    stencil: [2]StencilFace,
    /// Where each pixel's depth is held, in the depth's own units: the
    /// viewport's range for a draw that clamps, and the whole of it
    /// otherwise.
    clamp: ?[2]u64,
    /// The stored depth a pixel has to lie between, in those units; null
    /// for a draw that tests no bounds.
    bounds: ?[2]u64,
    /// The fragment function may drop a pixel: its depth waits for it.
    discards: bool,
    /// What a query counts of the pixels (`State.samples`).
    samples: ?*u32,
    fragments: ?*u32,
    /// The fragment function reads the attachment it writes, out of the
    /// tile (since 1.64): the attachment's own first pixel, which is what
    /// a descriptor of it points at and so how `shader.Fragments.input`
    /// knows that descriptor (since 1.65). Null where the part does not
    /// read what it draws.
    drawn: ?[*]const u8,
};

/// A triangle set up for the tiles: its planes follow it.
const Triangle = struct {
    header: Header,
    shading: *const Shading,
    depth: setup.Depth,
    /// The least 1 / w of its vertices: the least anywhere inside.
    least_inverse_w: f32,
    /// Which face of it is seen, 0 the front, for a stencil test.
    face: u8,

    fn planes(triangle: *const Triangle) [*]const shader.Plane {
        return @ptrFromInt(@intFromPtr(triangle) + @sizeOf(Triangle));
    }
};

/// The widths a clipped triangle's vertex is cut at. The clip path is the
/// one place a vertex's varyings are a *comptime* array, so cutting costs
/// what the array is wide whatever the draw actually carries: `setup.cut`
/// interpolates every slot of each vertex it makes, copies a whole vertex
/// per kept corner, and copies the polygon once per clip plane, five of
/// them. At `most_varyings` of 64 that is about 11 KB of copying a cut
/// triangle against about 1.9 KB at 8 - and it would have been paid by a
/// two-varying draw as readily as a sixty-four-varying one.
///
/// So the width is bucketed and a draw pays for the bucket it fits. The
/// first bucket is 8, which is what every draw written before 1.90 fits
/// and is exactly the cost it had then; the rest are there so that the
/// step up is gradual rather than straight to the widest. Nothing else in
/// the rasterizer is bucketed, because nothing else is comptime-sized by
/// this number: the per-triangle planes and the per-vertex outputs are
/// both sized at run time from the pipeline's own count.
/// Narrowest first, and the last one is the cap: a draw carrying more
/// than the widest bucket cannot be clipped at all, which `of` and the
/// test below hold it to. Lowering `shader.MAX_VARYINGS` below 32 makes
/// two of these equal, which is a duplicate enum value and so a compile
/// error naming this type - the right failure, since the buckets would
/// then need rewriting rather than silently collapsing.
const Clip = enum(u32) {
    eight = 8,
    sixteen = 16,
    thirty_two = 32,
    all = most_varyings,

    /// The narrowest bucket that holds `varyings`.
    fn of(varyings: u32) Clip {
        inline for (@typeInfo(Clip).@"enum".fields) |field| {
            if (varyings <= field.value) return @enumFromInt(field.value);
        }
        return .all;
    }

    fn width(bucket: Clip) u32 {
        return @intFromEnum(bucket);
    }
};

test "a clip bucket holds what it is asked for, and the narrowest is what 1.89 cost" {
    const testing = std.testing;
    try testing.expectEqual(Clip.eight, Clip.of(0));
    try testing.expectEqual(Clip.eight, Clip.of(8));
    try testing.expectEqual(Clip.sixteen, Clip.of(9));
    try testing.expectEqual(Clip.sixteen, Clip.of(16));
    try testing.expectEqual(Clip.thirty_two, Clip.of(17));
    try testing.expectEqual(Clip.all, Clip.of(33));
    try testing.expectEqual(Clip.all, Clip.of(most_varyings));
    // Every count up to the cap is held by the bucket chosen for it. A
    // bucket too narrow would make `cutUp`'s @memcpy of the varyings run
    // off the end of a clip vertex, which is a panic in a safe build and
    // worse in any other, so this is the check that matters.
    for (0..most_varyings + 1) |varyings| {
        try testing.expect(varyings <= Clip.of(@intCast(varyings)).width());
    }
    // And the widest bucket is the cap, so there is no count above it.
    const fields = @typeInfo(Clip).@"enum".fields;
    try testing.expectEqual(@as(u32, most_varyings), fields[fields.len - 1].value);
    // Narrowest first, which is what makes `of` pick the narrowest that
    // fits rather than whichever comes first.
    inline for (fields[1..], fields[0 .. fields.len - 1]) |after, before| {
        try testing.expect(before.value < after.value);
    }
}

/// How the depth is tested in a tile: by the draw's test, or - `second`
/// and `second_or_equal` - as the pre-pass's second pass does after a
/// test of less or of less or equal (`prepass.keep`).
const Test = enum { off, less, less_or_equal, masked, second, second_or_equal, stencil };

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
    if (compare == .never and !(target.attachments.stencil.used and state.stencil != null)) return;
    const area = scissored(target.areaBounds(), state.scissor) orelse return;
    const stencil = if (target.attachments.stencil.used) state.stencil else null;
    // The depth bounds test is of the depth already there, so it wants a
    // depth to look at; a draw that clamps holds each pixel's depth inside
    // the viewport's range. Either goes by the pixel at a time way, as a
    // stencil test does, and a draw with none of the three keeps its fast
    // path untouched.
    const bounds: ?[2]u64 = if (state.depth_bounds) |asked| boundsOf(asked) else null;
    const clamp: ?[2]u64 = if (state.depth_clamp) boundsOf(.{ state.min_depth, state.max_depth }) else null;
    // The bounds test is of the depth already there, which a pass with a
    // depth attachment has whether this draw tests it or not, as in
    // Vulkan.
    const has_plane = target.attachments.depth.used;
    const by_pixel = stencil != null or clamp != null or (bounds != null and has_plane);
    const shading = target.arena.create(Shading) orelse return error.OutOfMemory;
    shading.* = .{
        .fragment = state.fragment,
        .resources = state.resources,
        .plane_count = 1 + state.varyings,
        .compare = compare,
        .depth_write = depth and state.depth_write,
        .blend = state.blend,
        .mixing = state.mixing,
        .more_blends = state.more_blends,
        .more_mixings = state.more_mixings,
        // Never more than the frame has planes and surfaces for.
        .color_count = @min(@max(state.color_count, 1), target.colorCount()),
        .has_depth = depth,
        // A draw that goes by pixel without a stencil test of its own has
        // a test that passes and writes nothing.
        .stencil = stencil orelse [2]StencilFace{ keeping, keeping },
        .clamp = clamp,
        .bounds = if (has_plane) bounds else null,
        .discards = state.discards,
        .samples = state.samples,
        .fragments = state.fragments,
        // What the part draws into, as the image holds it: a descriptor
        // of that attachment points there, and the fragment function is
        // given the tile for it instead (since 1.65).
        .drawn = if (state.reads_target and target.surface_count > 0) target.surfaceAt(0).pixels else null,
    };
    const test_kind: Test = if (by_pixel) .stencil else if (!depth) .off else switch (compare) {
        .less => .less,
        .less_or_equal => .less_or_equal,
        else => .masked,
    };
    const raster = switch (test_kind) {
        inline .off, .less, .less_or_equal, .masked, .stencil => |kind| &Rasterize(kind).raster,
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
    const outside: u8 = if (state.depth_clamp) setup.outside_clamped else setup.outside_all;
    const cut_bits: u8 = if (state.depth_clamp) setup.must_cut_clamped else setup.must_cut;
    for (codes, 0..) |*code, k| code.* = setup.outcode(position(vertices, stride, k).*, guard);

    const set: SetUp = .{ .target = target, .state = state, .shading = shading, .raster = raster, .prepass = passes, .area = area, .depth = depth };
    // Chosen once a draw, not once a triangle: the clip vertex's width is
    // comptime, so this is the switch that picks which `cutUp` is called.
    const width = Clip.of(state.varyings);
    var at: usize = 0;
    // `CLIPPING_PRIMITIVES` as llvmpipe counts it: once for each triangle
    // the clipper lets through to setup, before setup culls a face or finds
    // no area (`c_primitives` at the top of lp_setup_tri.c's
    // triangle_cw/ccw/both), so a piece of a cut triangle is one more; and
    // once for a line or a point (try_setup_line, and the point's setup in
    // lp_setup_point.c), which here is once for its rectangle, if either
    // of its two triangles got through.
    var rectangle_through = false;
    while (at + 3 <= indices.len) : (at += 3) {
        target.stats.triangles += 1;
        const pieces_before = target.stats.pieces;
        const second_half = state.rectangles and (at / 3) % 2 == 1;
        defer {
            const through = target.stats.pieces - pieces_before;
            if (!state.rectangles) {
                target.stats.clipped += through;
            } else if (!second_half) {
                rectangle_through = through != 0;
            } else if (rectangle_through or through != 0) {
                target.stats.clipped += 1;
            }
        }
        const which = [3]usize{ indices[at], indices[at + 1], indices[at + 2] };
        if (which[0] >= count or which[1] >= count or which[2] >= count) continue;
        const code = [3]u8{ codes[which[0]], codes[which[1]], codes[which[2]] };
        // Wholly outside one side of the view: for a draw that clamps,
        // the depth planes do not count among the sides.
        if (code[0] & code[1] & code[2] & outside != 0) {
            target.stats.dropped += 1;
            continue;
        }
        if ((code[0] | code[1] | code[2]) & cut_bits == 0) {
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
        switch (width) {
            inline else => |bucket| try cutUp(bucket.width(), &set, vertices, stride, which, guard),
        }
    }
}

/// One triangle cut by the near plane and the guard band, and each piece
/// of what is left set up. `width` is the clip vertex's bucket
/// (`clipWidth`), so a draw carrying few varyings copies little.
fn cutUp(comptime width: u32, set: *const SetUp, vertices: []const f32, stride: u32, which: [3]usize, guard: setup.Guard) error{OutOfMemory}!void {
    const Vertex = setup.ClipVertex(width);
    const varyings = set.state.varyings;
    var corners: [3]Vertex = undefined;
    for (&corners, which) |*corner, k| {
        corner.position = position(vertices, stride, k).*;
        corner.values = @splat(0);
        @memcpy(corner.values[0..varyings], vertices[k * stride + 4 ..][0..varyings]);
    }
    var polygon: [setup.most_cut]Vertex = undefined;
    const made = setup.cut(Vertex, corners, guard, set.state.depth_clamp, &polygon);
    if (made < 3) return;
    for (1..made - 1) |k| {
        const three = [3]*const Vertex{ &polygon[0], &polygon[k], &polygon[k + 1] };
        try set.one(.{ &three[0].position, &three[1].position, &three[2].position }, .{ &three[0].values, &three[1].values, &three[2].values });
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
        // Out of clipping, and counted so before anything below drops it.
        target.stats.pieces += 1;
        var projected: [3]setup.Projected = undefined;
        // One branch a triangle, not one a vertex: a draw that clamps
        // leaves its vertices' depth as it comes.
        if (state.depth_clamp) {
            for (&projected, positions) |*into, p| into.* = setup.projectFree(p.*, state.viewport);
        } else {
            for (&projected, positions) |*into, p| into.* = setup.project(p.*, state.viewport);
        }
        const made = switch (state.cull) {
            inline else => |cull| switch (state.front) {
                inline else => |front| setup.onSurface(projected, cull, front, set.area, 1),
            },
        } orelse {
            target.stats.dropped += 1;
            return;
        };
        // Covering no sample: this is where the triangle stops, and it
        // stops *here* and not at the draw. Vulkan applies the sample mask
        // after rasterisation, so the primitive reached clipping and came
        // out of it, and `CLIPPING_INVOCATIONS` (counted by the draw from
        // its primitives) and `CLIPPING_PRIMITIVES` (`stats.pieces`, above)
        // are both owed - as llvmpipe counts `c_primitives` before its
        // `lp_setup_zero_sample_mask` test. Nothing is allocated and no
        // quad is walked, so `FRAGMENT_SHADER_INVOCATIONS` stays where it
        // was - which is the whole of what the mask does.
        if (state.sample_mask & 1 == 0) return;
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
            .face = faceOf(&projected, state.front),
        };
        const planes: [*]shader.Plane = @ptrFromInt(@intFromPtr(triangle) + @sizeOf(Triangle));
        planesOf(&made, &projected, carried, planes[0..plane_count]);
        bins.sortForWalk(&triangle.header.edges);
        try target.addPending(&triangle.header);
    }
};

/// Which face of a triangle on the surface is seen, 0 the front.
fn faceOf(p: *const [3]setup.Projected, front: setup.Winding) u8 {
    // Positive is clockwise on the surface, whose y runs down.
    const clockwise = (p[1].x - p[0].x) * (p[2].y - p[0].y) - (p[1].y - p[0].y) * (p[2].x - p[0].x) > 0;
    return @intFromBool(clockwise != (front == .clockwise));
}

/// The depth of a triangle, its vertices' z moved into the depth range.
fn depthOf(made: *const setup.Triangle, projected: [3]setup.Projected, state: *const State) setup.Depth {
    var ranged = projected;
    if (state.min_depth != 0 or state.max_depth != 1) {
        // A draw that clamps keeps the triangle's own plane: what lies
        // outside the range is held pixel by pixel as it is read, not
        // bent at the vertices.
        for (&ranged) |*vertex| {
            const moved = state.min_depth + vertex.z * (state.max_depth - state.min_depth);
            vertex.z = if (state.depth_clamp) moved else std.math.clamp(moved, 0, 1);
        }
    }
    const depth: setup.Depth = .of(made, &ranged);
    return if (state.depth_bias) |bias| depth.biased(bias) else depth;
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
            // A dropped pixel must leave no depth behind, so a form that can
            // drop one has its depths held back until it has run.
            const tested_here = if (kind == .stencil) triangle.shading.has_depth else kind != .off;
            const second_here = kind == .second or kind == .second_or_equal;
            // The pixel at a time way writes each depth as it tests it, so
            // there is none held back for the fragment function to drop:
            // holding them back there would write what was never gathered.
            batch.deferred_depth = kind != .stencil and triangle.shading.discards and tested_here and !second_here and triangle.shading.depth_write;
            walk.quads(1, tile, header, Walker{ .tile = tile, .batch = &batch, .depth = triangle.depth, .shading = triangle.shading, .face = triangle.face }, Walker.run);
            batch.flush();
        }

        /// What the walk goes by over a triangle's rows in a tile.
        const Walker = struct {
            tile: *const Tile,
            batch: *Batch,
            depth: setup.Depth,
            shading: *const Shading,
            face: u8,

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
                const tested = if (kind == .stencil) walker.shading.has_depth else kind != .off;
                const step = if (tested) walker.depth.step else 0;
                const free = kind == .stencil and walker.shading.clamp != null;
                var z_upper: i64 = if (tested) walker.rowDepth(upper, x, y, free) else 0;
                var z_lower: i64 = if (tested) walker.rowDepth(lower, x, y + 1, free) else 0;
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
                    if (kind == .stencil) {
                        // A draw that clamps walks the triangle's own
                        // plane and holds each pixel's depth inside the
                        // viewport's range as it reads it; one that cuts
                        // at the near plane never had a depth outside the
                        // range to hold.
                        const near = if (!tested) [4]u64{ 0, 0, 0, 0 } else if (walker.shading.clamp) |range| [4]u64{
                            held(z_upper, range),
                            held(z_upper +% step, range),
                            held(z_lower, range),
                            held(z_lower +% step, range),
                        } else [4]u64{ units(z_upper), units(z_upper +% step), units(z_lower), units(z_lower +% step) };
                        kept = walker.stenciled(x, y, covered, near, depths);
                    } else if (tested) {
                        const near = [4]u64{ units(z_upper), units(z_upper +% step), units(z_lower), units(z_lower +% step) };
                        if (second) {
                            kept = prepass.keep(walker.tile, kind == .second_or_equal, x, y, covered, near, depths);
                        } else inline for (0..4) |i| {
                            if (kept >> i & 1 != 0 and !walker.passes(near[i], depths[offset(i) + x])) kept &= ~(@as(u4, 1) << i);
                        }
                        if (write) {
                            if (batch.deferred_depth) {
                                inline for (0..4) |i| batch.depths[count][i] = @truncate(near[i]);
                            } else inline for (0..4) |i| {
                                if (kept >> i & 1 != 0) depths[offset(i) + x] = @truncate(near[i]);
                            }
                        }
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
            /// stepped back. 0 for a row with nothing in it. `free` leaves
            /// it outside the depth's range, for a draw that holds each
            /// pixel's own inside the viewport's.
            inline fn rowDepth(walker: Walker, span: Span, x: u32, y: u32, free: bool) i64 {
                if (span.empty()) return 0;
                const tile = walker.tile;
                const column = tile.x + span.left;
                const row = tile.y + y;
                const start = if (free) walker.depth.atFree(column, row) else walker.depth.at(column, row);
                return start -% @as(i64, span.left - x) *% walker.depth.step;
            }

            inline fn passes(walker: Walker, near: u64, kept: u16) bool {
                return switch (kind) {
                    .off => true,
                    .less => near < kept,
                    .less_or_equal => near <= kept,
                    .second, .second_or_equal, .stencil => unreachable,
                    .masked => byOrder(walker.shading.compare, near, kept),
                };
            }

            /// The stencil test and then the depth test for a quad's pixels,
            /// each keeping what it should: the pixels kept.
            inline fn stenciled(walker: Walker, x: u32, y: u32, covered: u4, near: [4]u64, depths: [*]u16) u4 {
                const shading = walker.shading;
                const face = &shading.stencil[walker.face];
                const values = walker.tile.stencilRow(y);
                var kept: u4 = 0;
                inline for (0..4) |i| {
                    if (covered >> i & 1 != 0) {
                        const value = &values[offset(i) + x];
                        // The depth bounds test is of the depth already
                        // there and comes before the stencil's, so a pixel
                        // it drops leaves the stencil as it is.
                        const in_bounds = if (shading.bounds) |bounds| within(depths[offset(i) + x], bounds) else true;
                        if (!in_bounds) {
                            // Dropped, and nothing written.
                        } else if (!face.passes(value.*)) {
                            value.* = face.after(face.fail, value.*);
                        } else if (shading.has_depth and !byOrder(shading.compare, near[i], depths[offset(i) + x])) {
                            value.* = face.after(face.depth_fail, value.*);
                        } else {
                            if (shading.depth_write) depths[offset(i) + x] = @truncate(near[i]);
                            value.* = face.after(face.pass, value.*);
                            kept |= @as(u4, 1) << i;
                        }
                    }
                }
                return kept;
            }
        };
    };
}

inline fn units(z: i64) u64 {
    return @as(u64, @bitCast(z)) >> setup.Depth.fraction;
}

/// A depth walked outside the range held inside `range`, in whole units:
/// what a draw that clamps reads at a pixel. The shift is signed, so a
/// depth in front of the viewport's nearest is below it and comes out as
/// the nearest rather than wrapping round.
inline fn held(z: i64, range: [2]u64) u64 {
    const whole = z >> setup.Depth.fraction;
    const low: i64 = @intCast(range[0]);
    const high: i64 = @intCast(range[1]);
    return @intCast(@min(@max(whole, low), high));
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
    /// Each quad's four depths, held while the fragment function runs where
    /// it may drop pixels: written after it, for those it left.
    depths: [batch_quads][4]u16,
    /// Whether that is what happens, worked out once a triangle.
    deferred_depth: bool,
    /// The triangle's planes moved to the tile's top left, where their
    /// numbers are smallest.
    planes: [1 + most_varyings]shader.Plane,
    /// The colour attachment being drawn into as this tile holds it, for
    /// a subpass that reads what it draws: what `shader.Fragments.target`
    /// points at, written only for such a part so that every other
    /// batch starts no differently than it did (since 1.65).
    target: shader.Attachment,

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
            .output_count = shading.color_count,
        };
        // A function that writes several colour attachments at once
        // writes them one after another, so they go in the one run the
        // tile keeps for its part; the one colour a draw usually writes
        // stays on the stack, where it always was. (Since 1.51.)
        if (shading.color_count > 1) batch.fragments.colors = tile.extra_colors.?;
        // A subpass that reads the attachment it draws into is given the
        // tile's own pixels for it, where they already are: the first
        // plane, which is what the function writes as `colors`. Its rows
        // begin at the tile's corner, so a pixel is read at its own place
        // on the attachment, as it is for one an earlier subpass drew.
        // (Since 1.64, through `shader.Fragments.input` since 1.65.)
        if (shading.drawn) |pixels| {
            batch.target = .{
                .bytes = @ptrCast(tile.plane(0)),
                .pitch = tile_size * @sizeOf(u32),
                .width = tile_size,
                .height = tile_size,
                .format = .bgra8888,
                .left = tile.x,
                .top = tile.y,
            };
            batch.fragments.drawn = pixels;
            batch.fragments.target = &batch.target;
        }
    }

    /// The quads gathered coloured by the fragment function, and the
    /// pixels kept put into the tile.
    fn flush(batch: *Batch) void {
        if (batch.count == 0) return;
        batch.fragments.count = batch.count;
        batch.shading.fragment(&batch.fragments);
        // After it, not before: the quads' `kept` is what the function left.
        if (batch.deferred_depth) batch.putDepths();
        if (batch.shading.fragments != null or batch.shading.samples != null) batch.countPixels();
        // The colours the function wrote: each attachment's `count` of
        // them after the one before (`shader.Fragments.colorsOf`), and
        // each blended its own way into its own plane of the tile
        // (since 1.51).
        const written = batch.fragments.colors;
        batch.putAt(0, batch.shading.blend, &batch.shading.mixing, written);
        var output: u32 = 1;
        while (output < batch.shading.color_count) : (output += 1) {
            batch.putAt(output, batch.shading.more_blends[output - 1], &batch.shading.more_mixings[output - 1], written + output * batch.count);
        }
        batch.count = 0;
    }

    /// What a query counts of a batch: the pixels the fragment function was
    /// called for, all four of every quad as a GPU shades them, and those
    /// that passed the tests and it did not drop. Only for a draw a query
    /// is counting, and once a batch rather than once a pixel.
    fn countPixels(batch: *Batch) void {
        const shading = batch.shading;
        countUp(shading.fragments, @as(u32, batch.count) * 4);
        if (shading.samples) |at| {
            var passed: u32 = 0;
            for (batch.quads[0..batch.count]) |quad| passed += @popCount(quad.kept);
            countUp(at, passed);
        }
    }

    /// `by` added to one of a query's counters, which several cores add to
    /// at once: held at the highest it takes rather than wrapping round. It
    /// is 32 bits wide because a 32-bit machine has no wider atomic.
    inline fn countUp(counter: ?*u32, by: u32) void {
        const at = counter orelse return;
        if (by == 0) return;
        const most = std.math.maxInt(u32);
        var have = @atomicLoad(u32, at, .monotonic);
        while (have != most) {
            have = @cmpxchgWeak(u32, at, have, have +| by, .monotonic, .monotonic) orelse return;
        }
    }

    /// The depths of the pixels the fragment function left, for a form that
    /// may drop them.
    inline fn putDepths(batch: *Batch) void {
        @setRuntimeSafety(false);
        const depths: [*]u16 = &batch.tile.buffer.depth;
        for (batch.quads[0..batch.count], batch.depths[0..batch.count]) |quad, near| {
            const at = depths + @as(u32, quad.y) * tile_size + quad.x;
            inline for (0..4) |i| {
                if (quad.kept >> i & 1 != 0) at[offset(i)] = near[i];
            }
        }
    }

    /// Colour attachment `output`'s colours put into its plane of the
    /// tile, as its own blend says. (Since 1.51: before that there was
    /// the one attachment, and `put` and `putMixed` took the tile's one
    /// colour plane.)
    inline fn putAt(batch: *Batch, output: u32, blend: pipeline.Blend, mixing: *const pipeline.Mixing, colors: [*][4]u32) void {
        const plane = batch.tile.plane(output);
        switch (blend) {
            .general => batch.putMixed(plane, mixing, colors),
            inline else => |one| batch.put(plane, one, colors),
        }
    }

    inline fn put(batch: *Batch, pixels: [*]u32, comptime blend: pipeline.Blend, from: [*][4]u32) void {
        @setRuntimeSafety(false);
        for (batch.quads[0..batch.count], from[0..batch.count]) |quad, *colors| {
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

    /// As `put`, by what the attachment's Mixing says.
    fn putMixed(batch: *Batch, pixels: [*]u32, mixing: *const pipeline.Mixing, from: [*][4]u32) void {
        @setRuntimeSafety(false);
        for (batch.quads[0..batch.count], from[0..batch.count]) |quad, *colors| {
            const at = pixels + @as(u32, quad.y) * tile_size + quad.x;
            inline for (0..4) |i| {
                if (quad.kept >> i & 1 != 0) at[offset(i)] = mixing.mixed(colors[i], at[offset(i)]);
            }
        }
    }
};

/// Pipeline's: how much 1 / w may change from a pixel to the next aslant
/// for a quad's centre to stand for its pixels.
const newton_change = pipeline.newton_change;
