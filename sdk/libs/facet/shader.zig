// SPDX-License-Identifier: MIT
//! Shaders: a pipeline's vertex and fragment functions, written in Zig,
//! compiled into the program, and handed to facet.library in a shader
//! module (`Code`) as a Vulkan program hands its driver SPIR-V.
//!
//! **The vertex function** is called with a batch of a draw's vertices
//! (`Vertices`): for each, what its attributes hold - four floats for
//! each location - in; its position in clip space and the values it
//! carries over the triangle, its varyings, out.
//!
//! **The fragment function** is called with a batch of one triangle's
//! quads in one tile (`Fragments`): squares of 2 x 2 pixels, at least
//! one of each covered by the triangle and kept by the depth test. It
//! writes all four pixels' colours, 0xAARRGGBB, and the library puts
//! those kept into the tile, blended as the pipeline says. What the
//! vertices carried is there as planes over the triangle: 1 / w, then
//! each varying over w, so that at a pixel a varying is its plane's value
//! divided by the first's - mixed as the eye sees it, not as the surface
//! does. The helpers below do that as the rasterizer itself does:
//! `smooth` for a colour, `textured` for a texture, and `Rows` for a
//! function of the program's own.
//!
//! **Both run on every core at once**, for other vertices and other
//! tiles: they read what they are given, write only where they are told,
//! and keep nothing from one call to the next. They run on the queue's
//! task and on exec's workers, whose stacks are 16 KiB.
//!
//! What a shader reads besides - uniform buffers, textures, push
//! constants - is in `Resources`, as the draw had them bound.
//!
//! **A fragment function can be one of the fixed forms** (`Fixed`, made
//! with `fixedFragment`): the colour the vertices carry, a texture, or the
//! two multiplied. The cores run the function that comes with it, as they
//! run any other; a device with a processor of its own runs its own program
//! for the form, and a pipeline with any other fragment function cannot be
//! made on it. A vertex function is always the program's, and always runs
//! on the cores.

const facet = @import("facet.zig");
const texture = @import("texture.zig");

// --- the module -------------------------------------------------------------

/// What a shader module's code starts with: not SPIR-V's 0x07230203.
pub const MAGIC: u32 = 0x5A54_4346; // "FCTZ"

/// One function of a module, found by its name and stage.
pub const Entry = extern struct {
    name: [*:0]const u8,
    /// facet.SHADER_STAGE_VERTEX or facet.SHADER_STAGE_FRAGMENT.
    stage: u32,
    /// A VertexFn or a FragmentFn, as `stage` says.
    function: *const anyopaque,
    /// In its low 8 bits the floats a vertex function writes past the
    /// position, and a fragment function's planes past the first: no more
    /// than PhysicalDeviceLimits.max_vertex_output_components. A pipeline's
    /// two have to agree. Above them, a fragment function's fixed form, if
    /// it has one (`Fixed`): 0 for one of the program's own.
    varyings: u32,

    /// The floats it hands on, or takes.
    pub fn varyingCount(entry: *const Entry) u32 {
        return entry.varyings & 0xFF;
    }

    /// Its fixed form.
    pub fn fixed(entry: *const Entry) Fixed {
        return Fixed.fromBits(entry.varyings);
    }
};

/// What ShaderModuleCreateInfo.code points to.
pub const Code = extern struct {
    magic: u32 = MAGIC,
    entry_count: u32,
    entries: [*]const Entry,
};

/// An entry for a vertex function.
pub fn vertex(name: [*:0]const u8, function: VertexFn, varyings: u32) Entry {
    return .{ .name = name, .stage = facet.SHADER_STAGE_VERTEX, .function = function, .varyings = varyings };
}

/// An entry for a fragment function.
pub fn fragment(name: [*:0]const u8, function: FragmentFn, varyings: u32) Entry {
    return .{ .name = name, .stage = facet.SHADER_STAGE_FRAGMENT, .function = function, .varyings = varyings };
}

/// What a fixed form of fragment function does.
pub const FixedKind = enum(u8) {
    /// None: the function is the program's own.
    none = 0,
    /// The colour the vertices carry: varyings red, green, blue, alpha, as
    /// `smooth` has them.
    color = 1,
    /// A texture, binding 0 of set 0, at varyings s and t, as `textured`
    /// has it.
    texture = 2,
    /// The two multiplied: varyings s, t, then red, green, blue and alpha.
    texture_color = 3,
};

/// A fragment function any device can run.
pub const Fixed = struct {
    kind: FixedKind = .none,
    /// How the texture is sampled, for a form with one. A device that reads
    /// the format from the image is not held to `format`, the cores' own.
    sampling: texture.Sampling = .{},

    /// The floats a function of the form takes.
    pub fn varyings(fixed: Fixed) u32 {
        return switch (fixed.kind) {
            .none => 0,
            .color => 4,
            .texture => 2,
            .texture_color => 6,
        };
    }

    fn bits(fixed: Fixed) u32 {
        return @as(u32, @intFromEnum(fixed.kind)) << 8 |
            @as(u32, @intFromEnum(fixed.sampling.filter)) << 16 |
            @as(u32, @intFromEnum(fixed.sampling.address)) << 17;
    }

    fn fromBits(bits_given: u32) Fixed {
        return .{
            .kind = @enumFromInt(@as(u8, @truncate(bits_given >> 8))),
            .sampling = .{
                .filter = @enumFromInt(@as(u1, @truncate(bits_given >> 16))),
                .address = @enumFromInt(@as(u1, @truncate(bits_given >> 17))),
            },
        };
    }
};

/// An entry for a fragment function of a fixed form.
pub fn fixedFragment(name: [*:0]const u8, comptime fixed: Fixed) Entry {
    const made = struct {
        fn function(fragments: *const Fragments) callconv(.c) void {
            switch (fixed.kind) {
                .none => @compileError("a fixed form says what it does"),
                .color => smooth(fragments),
                .texture => textured(fixed.sampling, fragments, fragments.resources.sampled(0, 0, 0)),
                .texture_color => modulated(fixed.sampling, fragments, fragments.resources.sampled(0, 0, 0)),
            }
        }
    };
    return .{ .name = name, .stage = facet.SHADER_STAGE_FRAGMENT, .function = &made.function, .varyings = fixed.varyings() | fixed.bits() };
}

// --- what they read ---------------------------------------------------------

/// The descriptor sets a pipeline layout binds at once, and the bytes of
/// push constants.
pub const MAX_SETS = 4;
pub const MAX_PUSH_CONSTANTS_SIZE = 128;

/// A descriptor as a shader reads it: a uniform or storage buffer's bytes
/// from the offset written, and how many; a sampled image's texture.
pub const Slot = extern struct {
    pointer: ?*const anyopaque = null,
    /// The bytes of a buffer's range; 0 for an image.
    range: u32 = 0,
};

/// A descriptor set as a shader reads it.
pub const Set = extern struct {
    /// For each binding, its first slot; the elements of an array follow
    /// it. Past the last binding, the number of slots.
    first: [*]const u16,
    binding_count: u32,
    slots: [*]const Slot,
};

/// What a draw had bound, as its shaders see it.
pub const Resources = extern struct {
    sets: [MAX_SETS]?*const Set = @splat(null),
    push: [MAX_PUSH_CONSTANTS_SIZE]u8 align(4) = @splat(0),

    /// Element `element` of binding `binding` in set `set`, or null where
    /// there is none.
    pub fn slot(resources: *const Resources, set: u32, binding: u32, element: u32) ?*const Slot {
        if (set >= MAX_SETS) return null;
        const bound = resources.sets[set] orelse return null;
        if (binding >= bound.binding_count) return null;
        const at = @as(u32, bound.first[binding]) + element;
        if (at >= bound.first[binding + 1]) return null;
        return &bound.slots[at];
    }

    /// Binding `binding` of set `set`, a buffer, as a `T`: null where it
    /// is not written, or shorter than a `T`.
    pub fn buffer(resources: *const Resources, comptime T: type, set: u32, binding: u32) ?*const T {
        const found = resources.slot(set, binding, 0) orelse return null;
        if (found.range < @sizeOf(T)) return null;
        return @ptrCast(@alignCast(found.pointer orelse return null));
    }

    /// Element `element` of binding `binding` of set `set`, a sampled
    /// image: its texture, or null where it is not written.
    pub fn sampled(resources: *const Resources, set: u32, binding: u32, element: u32) ?*const texture.Texture {
        const found = resources.slot(set, binding, element) orelse return null;
        return @ptrCast(@alignCast(found.pointer orelse return null));
    }

    /// The push constants as a `T`.
    pub fn constants(resources: *const Resources, comptime T: type) *const T {
        comptime if (@sizeOf(T) > MAX_PUSH_CONSTANTS_SIZE or @alignOf(T) > 4) @compileError("push constants hold 128 bytes, 4-byte aligned");
        return @ptrCast(&resources.push);
    }
};

// --- the vertex function ----------------------------------------------------

/// What a vertex function is given.
pub const Vertices = extern struct {
    /// Each vertex's attributes: `input_stride` vectors, one for each
    /// location from 0, in the order of the vertices. A location the
    /// pipeline reads nothing into is (0, 0, 0, 1), and so are the parts
    /// of a vector its format does not fill.
    inputs: [*]const [4]f32,
    input_stride: u32,
    count: u32,
    /// Where each vertex goes: its position in clip space - x, y, z and w
    /// - then its varyings, `output_stride` floats from one vertex to the
    /// next.
    outputs: [*]f32,
    output_stride: u32,
    /// The draw's number of the batch's first vertex: vertex k is
    /// `first_vertex + k`.
    first_vertex: u32,
    /// The instance drawn.
    instance: u32,
    resources: *const Resources,

    /// Vertex `k`'s attribute at `location`.
    pub inline fn input(vertices: *const Vertices, k: u32, location: u32) [4]f32 {
        return vertices.inputs[k * vertices.input_stride + location];
    }

    /// Where vertex `k` goes: its position, then its varyings.
    pub inline fn output(vertices: *const Vertices, k: u32) [*]f32 {
        return vertices.outputs + k * vertices.output_stride;
    }
};

pub const VertexFn = *const fn (vertices: *const Vertices) callconv(.c) void;

/// `m * (p, 1)`, m 4 x 4 column after column.
pub inline fn transform(m: *const [16]f32, p: [3]f32) [4]f32 {
    var out: [4]f32 = undefined;
    inline for (&out, 0..) |*o, row| o.* = m[row] * p[0] + m[4 + row] * p[1] + m[8 + row] * p[2] + m[12 + row];
    return out;
}

/// A colour's channel, 0 to 1, as `smooth` mixes it: 0 to 255, and a
/// half, so that cut to an integer it is rounded.
pub inline fn channel(value: f32) f32 {
    return value * 255 + 0.5;
}

// --- the fragment function --------------------------------------------------

/// Four pixels of a tile.
pub const Quad = extern struct {
    /// Its top left pixel, from the tile's top left: both even.
    x: u8,
    y: u8,
    /// Its pixels inside the triangle: bit 0 the top left, 1 the top
    /// right, 2 the bottom left, 3 the bottom right.
    covered: u8,
    /// Those the depth test kept, which are written.
    kept: u8,
};

/// A value over a triangle: at the tile's pixel (x, y), its centre, it
/// is `origin + dx * x + dy * y`.
pub const Plane = extern struct {
    origin: f32,
    dx: f32,
    dy: f32,
};

/// What a fragment function is given.
pub const Fragments = extern struct {
    quads: [*]const Quad,
    count: u32,
    /// Where each quad's four colours go, 0xAARRGGBB, its pixels in the
    /// order of `covered`'s bits.
    colors: [*][4]u32,
    /// 1 / w, then each varying over w.
    planes: [*]const Plane,
    plane_count: u32,
    /// The tile's top left on the surface: a pixel's place there is the
    /// tile's and its own added.
    x: u32,
    y: u32,
    /// w changes so fast over the tile that a quad's centre does not
    /// stand for its pixels: each has to divide.
    exact: bool,
    resources: *const Resources,
};

pub const FragmentFn = *const fn (fragments: *const Fragments) callconv(.c) void;

/// Four floats, one a pixel of a quad.
pub const Pixels = @Vector(4, f32);

/// The first `count` planes, held by the fragment function while it goes
/// over the quads, and each at the left of the row of quads it is on -
/// worked out again only when a quad is on another row, as the quads come
/// a row at a time, left to right. A quad's values are then a multiply and
/// an add a plane from there. What `smooth` and `textured` go by.
pub fn Rows(comptime count: usize) type {
    return struct {
        planes: [count]Plane,
        /// The row `left` is at.
        y: u32 = ~@as(u32, 0),
        left: [count]f32 = undefined,

        const Self = @This();

        pub inline fn of(fragments: *const Fragments) Self {
            var made = Self{ .planes = undefined };
            inline for (&made.planes, 0..) |*plane, k| plane.* = fragments.planes[k];
            return made;
        }

        /// Each plane at the quad's four pixels.
        pub inline fn at(rows: *Self, quad: Quad) [count]Pixels {
            @setRuntimeSafety(false);
            rows.move(quad.y);
            const across: f32 = @floatFromInt(quad.x);
            var made: [count]Pixels = undefined;
            inline for (&made, rows.left, rows.planes) |*value, left, plane| {
                const first = left + plane.dx * across;
                value.* = .{ first, first + plane.dx, first + plane.dy, first + plane.dx + plane.dy };
            }
            return made;
        }

        /// Each plane at the quad's centre, between its four pixels.
        pub inline fn centre(rows: *Self, quad: Quad) [count]f32 {
            @setRuntimeSafety(false);
            rows.move(quad.y);
            const middle = @as(f32, @floatFromInt(quad.x)) + 0.5;
            var made: [count]f32 = undefined;
            inline for (&made, rows.left, rows.planes) |*value, left, plane| value.* = left + plane.dx * middle + plane.dy * 0.5;
            return made;
        }

        inline fn move(rows: *Self, y: u8) void {
            @setRuntimeSafety(false);
            if (y == rows.y) return;
            rows.y = y;
            const down: f32 = @floatFromInt(y);
            inline for (&rows.left, rows.planes) |*left, plane| left.* = plane.origin + plane.dy * down;
        }
    };
}

/// Every quad one colour.
pub fn fill(fragments: *const Fragments, color: u32) void {
    for (fragments.colors[0..fragments.count]) |*out| out.* = @splat(color);
}

/// What a texture not written, or not in the format a shader samples,
/// paints.
pub const missing: u32 = 0xFFFF_00FF;

/// Colours mixed from the vertices': the vertex function writes a
/// colour's red, green, blue and alpha as varyings 0 to 3, each through
/// `channel`.
///
/// A pixel's w is divided once a quad, at its centre, and put right with
/// a step of Newton's for each pixel - two multiplies and an add - but
/// where w changes too fast (`Fragments.exact`), where each divides.
/// Inside the triangle a channel is a mix of the vertices', and needs
/// holding inside 0 to 255 only where a pixel of the quad is past an
/// edge.
pub fn smooth(fragments: *const Fragments) void {
    if (fragments.exact) smoothQuads(true, fragments) else smoothQuads(false, fragments);
}

inline fn smoothQuads(comptime exact: bool, fragments: *const Fragments) void {
    // This runs for every quad; its numbers are held inside, and the
    // checks would cost more than the work.
    @setRuntimeSafety(false);
    var rows = Rows(5).of(fragments);
    for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |quad, *out| {
        const at = rows.at(quad);
        const inverse_w = at[0];
        const w = if (exact) @as(Pixels, @splat(1)) / inverse_w else newton: {
            const centre: Pixels = @splat(1 / ((inverse_w[0] + inverse_w[3]) * 0.5));
            break :newton centre + centre * (@as(Pixels, @splat(1)) - inverse_w * centre);
        };
        var bytes: [4]@Vector(4, u32) = undefined;
        if (!exact and quad.covered == 0xF) {
            inline for (&bytes, at[1..]) |*channel_bytes, over_w| channel_bytes.* = @intFromFloat(over_w * w);
        } else inline for (&bytes, at[1..]) |*channel_bytes, over_w| channel_bytes.* = bytesOf(over_w * w);
        out.* = bytes[3] << @splat(24) | bytes[0] << @splat(16) | bytes[1] << @splat(8) | bytes[2];
    }
}

/// A channel of four pixels, 0 to 255, from the channel and a half: held
/// inside first - a NaN as well, which @min and @max pass over - so that
/// the conversion cannot fail.
inline fn bytesOf(at: Pixels) @Vector(4, u32) {
    @setRuntimeSafety(false);
    return @intFromFloat(@min(@max(at, @as(Pixels, @splat(0))), @as(Pixels, @splat(255.5))));
}

/// A texture, `picture`, at the coordinates the vertex function writes as
/// varyings 0 and 1: 0 to 1 across it and down. Its format, its filter
/// and what it does past its edges are `sampling`'s; a texture not
/// written, or in another format, paints every pixel `missing`.
///
/// Where w changes slowly enough, each quad takes its coordinates at its
/// centre - one division - and how fast they change there, and its pixels
/// are the centre's plus or minus half a step each way, in fixed point.
/// Elsewhere each pixel divides. How fast they change chooses the level.
pub fn textured(comptime sampling: texture.Sampling, fragments: *const Fragments, picture: ?*const texture.Texture) void {
    const given = picture orelse return fill(fragments, missing);
    if (given.format != sampling.format) return fill(fragments, missing);
    if (fragments.exact) texturedQuads(sampling, true, fragments, given) else texturedQuads(sampling, false, fragments, given);
}

/// A texture as `textured` has it, at varyings 0 and 1, times the colour of
/// varyings 2 to 5: red, green, blue and alpha, each through `channel`.
pub fn modulated(comptime sampling: texture.Sampling, fragments: *const Fragments, picture: ?*const texture.Texture) void {
    @setRuntimeSafety(false);
    textured(sampling, fragments, picture);
    var rows = Rows(7).of(fragments);
    for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |quad, *out| {
        const at = rows.at(quad);
        const w = @as(Pixels, @splat(1)) / at[0];
        const seen: @Vector(4, u32) = out.*;
        const parts = [4]@Vector(4, u32){ bytesOf(at[3] * w), bytesOf(at[4] * w), bytesOf(at[5] * w), bytesOf(at[6] * w) };
        const shifts = [4]@Vector(4, u5){ @splat(16), @splat(8), @splat(0), @splat(24) };
        var mixed: @Vector(4, u32) = @splat(0);
        inline for (parts, shifts) |part, shift| {
            const texel = (seen >> shift) & @as(@Vector(4, u32), @splat(0xFF));
            mixed |= ((texel * part + @as(@Vector(4, u32), @splat(127))) / @as(@Vector(4, u32), @splat(255))) << shift;
        }
        out.* = mixed;
    }
}

inline fn texturedQuads(comptime sampling: texture.Sampling, comptime exact: bool, fragments: *const Fragments, picture: *const texture.Texture) void {
    @setRuntimeSafety(false);
    const texels = [2]f32{ @floatFromInt(picture.width(0)), @floatFromInt(picture.height(0)) };
    const bias = texture.bias(sampling);
    var rows = Rows(3).of(fragments);
    const inverse_w = rows.planes[0];
    const u_over_w = rows.planes[1];
    const v_over_w = rows.planes[2];
    for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |quad, *out| {
        var s: [4]i32 = undefined;
        var t: [4]i32 = undefined;
        var level: *const texture.Level = undefined;
        if (exact) {
            const at = rows.at(quad);
            const w = @as(Pixels, @splat(1)) / at[0];
            const u = at[1] * w;
            const v = at[2] * w;
            const lod = if (picture.levels == 1) 0 else texture.levelFor(
                picture,
                (u[1] - u[0]) * texels[0],
                (v[1] - v[0]) * texels[1],
                (u[2] - u[0]) * texels[0],
                (v[2] - v[0]) * texels[1],
            );
            level = &picture.layout[lod];
            inline for (0..4) |i| {
                s[i] = texture.place(u[i] * level.across - bias);
                t[i] = texture.place(v[i] * level.down - bias);
            }
        } else {
            const at = rows.centre(quad);
            const w = 1 / at[0];
            const u = at[1] * w;
            const v = at[2] * w;
            // (u / w)' / (1 / w) - u (1 / w)' / (1 / w)
            const du_dx = (u_over_w.dx - u * inverse_w.dx) * w;
            const du_dy = (u_over_w.dy - u * inverse_w.dy) * w;
            const dv_dx = (v_over_w.dx - v * inverse_w.dx) * w;
            const dv_dy = (v_over_w.dy - v * inverse_w.dy) * w;
            const lod = if (picture.levels == 1) 0 else texture.levelFor(picture, du_dx * texels[0], dv_dx * texels[1], du_dy * texels[0], dv_dy * texels[1]);
            level = &picture.layout[lod];
            const s0 = texture.place((u - (du_dx + du_dy) * 0.5) * level.across - bias);
            const t0 = texture.place((v - (dv_dx + dv_dy) * 0.5) * level.down - bias);
            const s_x = texture.step(du_dx * level.across);
            const s_y = texture.step(du_dy * level.across);
            const t_x = texture.step(dv_dx * level.down);
            const t_y = texture.step(dv_dy * level.down);
            s = .{ s0, s0 +% s_x, s0 +% s_y, s0 +% s_x +% s_y };
            t = .{ t0, t0 +% t_x, t0 +% t_y, t0 +% t_x +% t_y };
        }
        // Gathered before any is written, as a colour written could be
        // the level's to the compiler, which would read it again each time.
        var colors: [4]u32 = undefined;
        inline for (&colors, s, t) |*pixel, s_i, t_i| pixel.* = texture.sampleAt(sampling, picture, level, s_i, t_i);
        out.* = colors;
    }
}
