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
//! on the cores, and so do tessellation's and compute functions.

const std = @import("std");
const facet = @import("facet.zig");
const texture = @import("texture.zig");

// --- the module -------------------------------------------------------------

/// What a shader module's code starts with: not SPIR-V's 0x07230203.
pub const MAGIC: u32 = 0x5A54_4346; // "FCTZ"

/// One function of a module, found by its name and stage.
pub const Entry = extern struct {
    name: [*:0]const u8,
    /// One of the facet.SHADER_STAGE_ values.
    stage: u32,
    /// A VertexFn, a ControlFn, an EvaluationFn, a FragmentFn or a ComputeFn,
    /// as `stage` says.
    function: *const anyopaque,
    /// In its low 8 bits the floats a vertex or evaluation function writes
    /// past the position, and a fragment function's planes past the first: no
    /// more than PhysicalDeviceLimits.max_vertex_output_components. What
    /// comes to the fragment function has to agree with it. Above them, a
    /// fragment function's fixed form, if it has one (`Fixed`): 0 for one of
    /// the program's own; or an evaluation function's way of tessellating
    /// (`Tessellation`). A compute function's whole word is its workgroup
    /// instead (`localSize`, `sharedBytes`): 0 for one invocation a group
    /// and nothing shared, which is what `shader.compute` makes.
    varyings: u32,

    /// The floats it hands on, or takes.
    pub fn varyingCount(entry: *const Entry) u32 {
        return entry.varyings & 0xFF;
    }

    /// Its fixed form.
    pub fn fixed(entry: *const Entry) Fixed {
        return Fixed.fromBits(entry.varyings);
    }

    /// An evaluation function's way of tessellating.
    pub fn tessellation(entry: *const Entry) Tessellation {
        return .{ .domain = @enumFromInt((entry.varyings >> 8) & 3), .clockwise = entry.varyings & (1 << 10) != 0 };
    }

    /// A compute function's invocations along each axis, which is what
    /// `Groups.local` hands it: 1, 1, 1 for a `shader.compute` entry.
    /// (Since 1.41.)
    pub fn localSize(entry: *const Entry) [3]u32 {
        return .{
            (entry.varyings & 0x3FF) + 1,
            ((entry.varyings >> 10) & 0x3FF) + 1,
            ((entry.varyings >> 20) & 0x3F) + 1,
        };
    }

    /// The bytes a compute function's group shares between its invocations
    /// (`Groups.shared`), a whole KiB; 0 where it shares none. (Since 1.41.)
    pub fn sharedBytes(entry: *const Entry) u32 {
        return ((entry.varyings >> 26) & 0x3F) * 1024;
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

/// An entry for a tessellation control function.
pub fn control(name: [*:0]const u8, function: ControlFn) Entry {
    return .{ .name = name, .stage = facet.SHADER_STAGE_TESSELLATION_CONTROL, .function = function, .varyings = 0 };
}

/// An entry for a tessellation evaluation function.
pub fn evaluation(name: [*:0]const u8, function: EvaluationFn, varyings: u32, way: Tessellation) Entry {
    return .{
        .name = name,
        .stage = facet.SHADER_STAGE_TESSELLATION_EVALUATION,
        .function = function,
        .varyings = varyings | @as(u32, @intFromEnum(way.domain)) << 8 | @as(u32, @intFromBool(way.clockwise)) << 10,
    };
}

/// An entry for a compute function, of one invocation a group and nothing
/// shared: `computeGroup` is the one for a group of more.
pub fn compute(name: [*:0]const u8, function: ComputeFn) Entry {
    return .{ .name = name, .stage = facet.SHADER_STAGE_COMPUTE, .function = function, .varyings = 0 };
}

/// An entry for a compute function of `local` invocations a group - along x,
/// y and z - which share `shared` bytes of memory: what `Groups.local` and
/// `Groups.shared` give it as it runs. The function makes the invocations
/// itself, in the one call it gets for the group.
///
/// An axis under 1 counts as 1; one over what the entry holds - 1024, 1024,
/// 64 - and bytes over 64512 come out as the most it holds, and the bytes are
/// rounded up to a whole KiB. A pipeline refuses a group over the device's
/// limits (`PhysicalDeviceLimits.max_compute_work_group_size`,
/// `max_compute_work_group_invocations`,
/// `max_compute_shared_memory_size`). (Since 1.41.)
pub fn computeGroup(name: [*:0]const u8, function: ComputeFn, local: [3]u32, shared: u32) Entry {
    const x: u32 = @min(@max(local[0], 1), 1024) - 1;
    const y: u32 = @min(@max(local[1], 1), 1024) - 1;
    const z: u32 = @min(@max(local[2], 1), 64) - 1;
    const blocks: u32 = @min((shared + 1023) / 1024, 63);
    return .{
        .name = name,
        .stage = facet.SHADER_STAGE_COMPUTE,
        .function = function,
        .varyings = x | (y << 10) | (z << 20) | (blocks << 26),
    };
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
    /// A layer of an array: varyings s, t and the layer, the nearest that
    /// there is.
    texture_array = 4,
    /// A cube map, its view's six faces: varyings x, y and z, the direction.
    /// `sampling.address` is always `clamp`.
    texture_cube = 5,
    /// A 3D texture: varyings s, t and r, each 0 to 1 across it.
    texture_3d = 6,
    /// A texture, as `texture` has it, except that a pixel whose sampled
    /// alpha is under half is dropped rather than drawn: a cut-out, for the
    /// leaf and the railing and the sprite with a hole in it. Varyings s
    /// and t.
    texture_cutout = 7,
    /// A texture as the sampler bound beside it says (`texture.Sampler`,
    /// CreateSampler): binding 0 of set 0, written as a combined image
    /// sampler. Varyings s and t, as `texture` has them, and `sampling`'s
    /// filter and address are the sampler's instead - with the levels
    /// mixed, a bias and a clamp on them, mirrored and bordered edges, and
    /// anisotropy, none of which the fixed path has.
    texture_sampled = 8,
    /// The same compared with a reference rather than read as a colour: a
    /// shadow sample (`texture.Sampler.compare`). Varyings s, t and the
    /// reference, and what it writes is how much of the sample passed -
    /// white for all of it, black for none.
    texture_shadow = 9,
    /// One cube of an array of them: varyings x, y and z, the direction,
    /// and then which cube, the nearest there is - a view of `cube_array`,
    /// whose layers are six to a cube. `sampling.address` is always
    /// `clamp`, as for `texture_cube`. (Since 1.46.)
    texture_cube_array = 10,
};

/// Under this alpha, 0 to 255, `texture_cutout` drops a pixel.
pub const cutout_alpha = 128;

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
            .texture, .texture_cutout, .texture_sampled => 2,
            .texture_color => 6,
            .texture_array, .texture_cube, .texture_3d, .texture_shadow => 3,
            .texture_cube_array => 4,
        };
    }

    /// Whether the form samples through a sampler bound with the texture,
    /// rather than as `sampling` says. A device whose fragment programs are
    /// its own has one for each form it can draw, so such a pipeline is
    /// refused where `PhysicalDeviceFeatures.samplers` is false.
    pub fn needsSampler(fixed: Fixed) bool {
        return switch (fixed.kind) {
            .texture_sampled, .texture_shadow => true,
            else => false,
        };
    }

    /// Whether the form may drop a pixel instead of colouring it, which is
    /// what makes a pipeline's depth wait for its fragment function.
    pub fn discards(fixed: Fixed) bool {
        return fixed.kind == .texture_cutout;
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
                .texture_cutout => cutout(fixed.sampling, fragments, fragments.resources.sampled(0, 0, 0)),
                .texture_color => modulated(fixed.sampling, fragments, fragments.resources.sampled(0, 0, 0)),
                .texture_array, .texture_cube, .texture_3d, .texture_cube_array => layered(fixed.kind, fixed.sampling, fragments, fragments.resources.sampled(0, 0, 0)),
                .texture_sampled, .texture_shadow => texturedBy(
                    fixed.kind == .texture_shadow,
                    fixed.sampling,
                    fragments,
                    fragments.resources.sampled(0, 0, 0),
                    fragments.resources.samplerOf(0, 0, 0),
                ),
            }
        }
    };
    return .{ .name = name, .stage = facet.SHADER_STAGE_FRAGMENT, .function = &made.function, .varyings = fixed.varyings() | fixed.bits() };
}

// --- what they read ---------------------------------------------------------

/// The descriptor sets a pipeline layout binds at once, and the bytes of
/// push constants.
pub const MAX_SETS = 4;
/// The dynamic buffer descriptors one set may hold: each takes an offset
/// from CmdBindDescriptorSets (`Resources.offsets`), so two of them is
/// eight across the four sets - which is Vulkan's guarantee for the
/// uniform ones of a pipeline layout, and twice it for the storage ones.
/// It is low because the offsets are part of what a draw was bound with,
/// which is copied for every draw that changed it. Four a set were tried
/// again for 1.43: FacetMany drew a frame in 11.61 and 11.62 ms with them,
/// and in 11.18 to 11.58 ms with two over seven runs - above every reading
/// two gave, by about 2 per cent of the mean, though by less than that
/// test drifts from batch to batch. Two is kept: nothing has asked for
/// more, and a program that wants eight ranges can bind eight offsets
/// across the four sets.
pub const MAX_DYNAMIC_OFFSETS = 2;
pub const MAX_PUSH_CONSTANTS_SIZE = 128;

/// A descriptor as a shader reads it: a uniform or storage buffer's bytes
/// from the offset written, and how many; a sampled image's texture; a
/// sampler's, and a combined image sampler's both.
pub const Slot = extern struct {
    pointer: ?*const anyopaque = null,
    /// The bytes of a buffer's range; 0 for an image or a sampler.
    range: u32 = 0,
    /// Whether a shader function may write through it: a `storage_image`
    /// or a `storage_texel_buffer`, and not one that is only read. It lies
    /// in the padding after `range`, so a slot is as wide as it always was.
    writable: bool = false,
    /// How the bytes are read where the slot is a texel buffer; `.none`
    /// for every other kind. In that same padding.
    texels: TexelFormat = .none,
    /// Which of the set's dynamic offsets shifts this slot's bytes, and
    /// one: 0 where none does, which is every kind but the two dynamic
    /// buffer descriptors (`Resources.offsets`). In that padding as well,
    /// so a slot is as wide as it always was.
    dynamic: u8 = 0,
    /// What a sampler or a combined image sampler was written with
    /// (CreateSampler); null for every other kind.
    sampler: ?*const texture.Sampler = null,
};

/// How a texel buffer's bytes are read: the formats a BufferView takes,
/// numbered for this library alone and not as `facet.Format` numbers them.
pub const TexelFormat = enum(u8) {
    none = 0,
    /// 8 bits a channel, red first in memory, as `r8g8b8a8_unorm`.
    rgba8888 = 1,
    /// The same, blue first: `b8g8r8a8_unorm`.
    bgra8888 = 2,
    /// 16 bits, `r5g6b5_unorm_pack16`.
    rgb565 = 3,
    /// One float to four, `r32_sfloat` to `r32g32b32a32_sfloat`.
    r32f = 4,
    rg32f = 5,
    rgb32f = 6,
    rgba32f = 7,

    /// The bytes one texel takes; 0 for `.none`.
    pub fn bytes(format: TexelFormat) u32 {
        return switch (format) {
            .none => 0,
            .rgb565 => 2,
            .rgba8888, .bgra8888, .r32f => 4,
            .rg32f => 8,
            .rgb32f => 12,
            .rgba32f => 16,
        };
    }

    /// How many of the four parts the format holds; the rest read as 0,
    /// and alpha as 1.
    pub fn parts(format: TexelFormat) u32 {
        return switch (format) {
            .none => 0,
            .r32f => 1,
            .rg32f => 2,
            .rgb565, .rgb32f => 3,
            .rgba8888, .bgra8888, .rgba32f => 4,
        };
    }
};

/// A texel buffer as a shader function reads it: `count` texels of
/// `format`, one after another from `bytes`. What `Resources.texels`
/// gives back.
///
/// A texel is read as four floats by `at` or as a colour by `colorAt`,
/// whatever the format, and set the same way where `writable` says so - a
/// `storage_texel_buffer` and not a uniform one. Nothing orders one
/// function's writes against another's.
pub const Texels = struct {
    bytes: [*]u8,
    count: u32,
    format: TexelFormat,
    writable: bool,

    /// Texel `index` as x, y, z and w: a colour format's channels are 0 to
    /// 1, and what the format does not hold reads as 0, w as 1. All zero
    /// past the last texel.
    pub fn at(texels: *const Texels, index: u32) [4]f32 {
        if (index >= texels.count) return .{ 0, 0, 0, 0 };
        const from = texels.bytes + @as(usize, index) * texels.format.bytes();
        var made = [4]f32{ 0, 0, 0, 1 };
        switch (texels.format) {
            .none => {},
            .rgba8888, .bgra8888 => {
                const packed_texel = std.mem.readInt(u32, from[0..4], .little);
                const order: [4]u5 = if (texels.format == .rgba8888) .{ 0, 8, 16, 24 } else .{ 16, 8, 0, 24 };
                for (&made, order) |*part, shift| part.* = @as(f32, @floatFromInt(packed_texel >> shift & 0xFF)) / 255;
            },
            .rgb565 => {
                const packed_texel = std.mem.readInt(u16, from[0..2], .little);
                made[0] = @as(f32, @floatFromInt(packed_texel >> 11 & 0x1F)) / 31;
                made[1] = @as(f32, @floatFromInt(packed_texel >> 5 & 0x3F)) / 63;
                made[2] = @as(f32, @floatFromInt(packed_texel & 0x1F)) / 31;
            },
            .r32f, .rg32f, .rgb32f, .rgba32f => {
                const floats: [*]align(1) const f32 = @ptrCast(from);
                for (0..texels.format.parts()) |k| made[k] = floats[k];
            },
        }
        return made;
    }

    /// Texel `index` as 0xAARRGGBB: a float format's parts held to 0 to 1
    /// first. Transparent black past the last texel.
    pub fn colorAt(texels: *const Texels, index: u32) u32 {
        const parts = texels.at(index);
        var made: u32 = 0;
        for (parts, [4]u5{ 16, 8, 0, 24 }) |part, shift| {
            made |= @as(u32, @intFromFloat(@round(held(part) * 255))) << shift;
        }
        return made;
    }

    /// Texel `index` set from x, y, z and w; nothing where the slot is only
    /// read, or past the last texel. A colour format takes 0 to 1.
    pub fn set(texels: *Texels, index: u32, parts: [4]f32) void {
        if (!texels.writable or index >= texels.count) return;
        const into = texels.bytes + @as(usize, index) * texels.format.bytes();
        switch (texels.format) {
            .none => {},
            .rgba8888, .bgra8888 => {
                const order: [4]u5 = if (texels.format == .rgba8888) .{ 0, 8, 16, 24 } else .{ 16, 8, 0, 24 };
                var made: u32 = 0;
                for (parts, order) |part, shift| made |= @as(u32, @intFromFloat(@round(held(part) * 255))) << shift;
                std.mem.writeInt(u32, into[0..4], made, .little);
            },
            .rgb565 => {
                const r: u32 = @intFromFloat(@round(held(parts[0]) * 31));
                const g: u32 = @intFromFloat(@round(held(parts[1]) * 63));
                const b: u32 = @intFromFloat(@round(held(parts[2]) * 31));
                std.mem.writeInt(u16, into[0..2], @intCast(r << 11 | g << 5 | b), .little);
            },
            .r32f, .rg32f, .rgb32f, .rgba32f => {
                const floats: [*]align(1) f32 = @ptrCast(into);
                for (0..texels.format.parts()) |k| floats[k] = parts[k];
            },
        }
    }

    /// Texel `index` set from 0xAARRGGBB.
    pub fn setColor(texels: *Texels, index: u32, color: u32) void {
        var parts: [4]f32 = undefined;
        for (&parts, [4]u5{ 16, 8, 0, 24 }) |*part, shift| part.* = @as(f32, @floatFromInt(color >> shift & 0xFF)) / 255;
        texels.set(index, parts);
    }

    /// 0 to 1, a NaN as 0.
    fn held(part: f32) f32 {
        return if (part >= 0) @min(part, 1) else 0;
    }
};

/// An attachment read pixel by pixel: what an `input_attachment`
/// descriptor gives a fragment function (`Resources.input`) - the pixels
/// a subpass before it drew, still in the image's memory.
///
/// Vulkan's `subpassLoad` reads the fragment's own pixel; here the whole
/// attachment is there to be read, the function working out where it is
/// from the tile's corner and the quad's place in it (`Fragments.x`,
/// `Fragments.y`, `Quad.x`, `Quad.y`). Reading another pixel is the
/// function's own doing, and what is outside reads as transparent black.
pub const Attachment = extern struct {
    /// Its first pixel, or null where nothing was written into the slot.
    bytes: ?[*]const u8 = null,
    /// The bytes from one row of pixels to the next.
    pitch: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// How a pixel is read, which is the attachment's own format.
    format: TexelFormat = .none,

    /// The pixel at (x, y) as 0xAARRGGBB; transparent black outside it.
    pub fn colorAt(attachment: *const Attachment, x: u32, y: u32) u32 {
        const row = attachment.rowAt(y) orelse return 0;
        return row.colorAt(x);
    }

    /// The same as x, y, z and w: the channels 0 to 1, what the format
    /// does not hold as 0 and w as 1. All zero outside it.
    pub fn at(attachment: *const Attachment, x: u32, y: u32) [4]f32 {
        const row = attachment.rowAt(y) orelse return .{ 0, 0, 0, 0 };
        return row.at(x);
    }

    /// Row `y` as texels, the pixels of one row: null past the last row,
    /// or where there is nothing to read.
    fn rowAt(attachment: *const Attachment, y: u32) ?Texels {
        const bytes = attachment.bytes orelse return null;
        if (y >= attachment.height or attachment.format == .none) return null;
        return .{
            .bytes = @constCast(bytes) + @as(usize, y) * attachment.pitch,
            .count = attachment.width,
            .format = attachment.format,
            .writable = false,
        };
    }
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
    /// A fragment function's colour attachment: which of the subpass's is being
    /// drawn, each in turn (`CreateRenderPass`).
    output: u32 = 0,
    /// What each set's dynamic buffer descriptors are shifted by, as
    /// CmdBindDescriptorSets gave them: `offsets[set][slot.dynamic - 1]`
    /// is a slot's own, and `buffer` adds it. The sets' other slots are
    /// not shifted (`Slot.dynamic` is 0 for them).
    offsets: [MAX_SETS][MAX_DYNAMIC_OFFSETS]u32 = @splat(@splat(0)),

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
    /// is not written, or shorter than a `T`. Its first element;
    /// `bufferAt` reaches the others.
    ///
    /// A dynamic buffer descriptor is read from the offset
    /// CmdBindDescriptorSets gave for it, and what is left of the range
    /// from there has to hold a `T`.
    pub fn buffer(resources: *const Resources, comptime T: type, set: u32, binding: u32) ?*const T {
        return resources.bufferAt(T, set, binding, 0);
    }

    /// Element `element` of binding `binding` of set `set`, a buffer, as a
    /// `T`: a binding that is an array of buffers read element by element,
    /// as `sampled` and `texels` are read. (Since 1.43.)
    pub fn bufferAt(resources: *const Resources, comptime T: type, set: u32, binding: u32, element: u32) ?*const T {
        const found = resources.slot(set, binding, element) orelse return null;
        const shift = resources.shiftOf(set, found);
        if (found.range -| shift < @sizeOf(T)) return null;
        const bytes: [*]const u8 = @ptrCast(found.pointer orelse return null);
        return @ptrCast(@alignCast(bytes + shift));
    }

    /// What `found`, a slot of set `set`, has its bytes shifted by: the
    /// offset CmdBindDescriptorSets gave for it where it is a dynamic
    /// buffer descriptor, and 0 for every other kind.
    pub fn shiftOf(resources: *const Resources, set: u32, found: *const Slot) u32 {
        if (found.dynamic == 0 or set >= MAX_SETS) return 0;
        const at = found.dynamic - 1;
        if (at >= MAX_DYNAMIC_OFFSETS) return 0;
        return resources.offsets[set][at];
    }

    /// Element `element` of binding `binding` of set `set`, a sampled
    /// image: its texture, or null where it is not written. A combined
    /// image sampler's texture is read the same way, its sampler by
    /// `samplerOf`.
    pub fn sampled(resources: *const Resources, set: u32, binding: u32, element: u32) ?*const texture.Texture {
        const found = resources.slot(set, binding, element) orelse return null;
        return @ptrCast(@alignCast(found.pointer orelse return null));
    }

    /// Element `element` of binding `binding` of set `set`, a storage
    /// image, as the texture it is written through: null where it is not
    /// written, or is not a kind a function may write through.
    ///
    /// Its texels are set by `putLayer` in the texture's own format, or by
    /// `setColor` as 0xAARRGGBB whatever the format, and read by
    /// `colorAt`. The level and the layer are the view's first, so a
    /// function writes level 0 of layer 0 unless the view says otherwise.
    /// Nothing orders one function's writes against another's: a frame's
    /// work is shared between the cores, so two of them writing the same
    /// texel is for the program to avoid, as it is in Vulkan.
    pub fn written(resources: *const Resources, set: u32, binding: u32, element: u32) ?*texture.Texture {
        const found = resources.slot(set, binding, element) orelse return null;
        if (!found.writable) return null;
        return @ptrCast(@alignCast(@constCast(found.pointer orelse return null)));
    }

    /// Element `element` of binding `binding` of set `set`, a texel
    /// buffer: its texels, or null where it is not written or is of
    /// another kind. A `storage_texel_buffer`'s may be set as well as
    /// read, a `uniform_texel_buffer`'s only read.
    pub fn texels(resources: *const Resources, set: u32, binding: u32, element: u32) ?Texels {
        const found = resources.slot(set, binding, element) orelse return null;
        if (found.texels == .none) return null;
        const bytes: [*]u8 = @ptrCast(@constCast(found.pointer orelse return null));
        return .{
            .bytes = bytes,
            .count = found.range / found.texels.bytes(),
            .format = found.texels,
            .writable = found.writable,
        };
    }

    /// Element `element` of binding `binding` of set `set`, a sampler or a
    /// combined image sampler: what it was written with, or null where it
    /// is not written or is of another kind.
    pub fn samplerOf(resources: *const Resources, set: u32, binding: u32, element: u32) ?*const texture.Sampler {
        const found = resources.slot(set, binding, element) orelse return null;
        return found.sampler;
    }

    /// Binding `binding` of set `set`, a buffer written through, as the
    /// `T`s it has room for: null where it is not written. Its first
    /// element; `storageAt` reaches the others. A dynamic one starts where
    /// CmdBindDescriptorSets said.
    pub fn storage(resources: *const Resources, comptime T: type, set: u32, binding: u32) ?[]T {
        return resources.storageAt(T, set, binding, 0);
    }

    /// Element `element` of binding `binding` of set `set`, a buffer
    /// written through, as the `T`s it has room for. (Since 1.43.)
    pub fn storageAt(resources: *const Resources, comptime T: type, set: u32, binding: u32, element: u32) ?[]T {
        const found = resources.slot(set, binding, element) orelse return null;
        // A dynamic one starts where the bind said, and what is left of
        // the range from there is how many a function may reach.
        const shift = resources.shiftOf(set, found);
        const bytes: [*]u8 = @ptrCast(@constCast(found.pointer orelse return null));
        const first: [*]T = @ptrCast(@alignCast(bytes + shift));
        return first[0 .. (found.range -| shift) / @sizeOf(T)];
    }

    /// Element `element` of binding `binding` of set `set`, an input
    /// attachment: its pixels, or null where it is not written. What
    /// another subpass drew, read from the image's memory
    /// (`PhysicalDeviceFeatures.input_attachments`).
    ///
    /// Asking this of a binding of another kind gives back whatever that
    /// kind's slot holds, read as an attachment: the layout says what a
    /// binding is, and a function has to ask for what is there, as it
    /// does for `sampled` and `texels`.
    pub fn input(resources: *const Resources, set: u32, binding: u32, element: u32) ?*const Attachment {
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

// --- tessellation -----------------------------------------------------------

/// The shape a patch is made into.
pub const Domain = enum(u8) {
    /// Triangles in a triangle, the coordinates three that come to 1.
    triangles = 0,
    /// Triangles in a square, the coordinates u, v and 0.
    quads = 1,
    /// Lines of a constant v, `outer[0]` of them, of `outer[1]` pieces each:
    /// the coordinates u, v and 0.
    isolines = 2,
};

/// What an evaluation function says of how it tessellates. The pieces are of
/// equal length, as Vulkan's SpacingEqual.
pub const Tessellation = struct {
    domain: Domain = .triangles,
    /// Triangles go clockwise on the coordinates, not the other way.
    clockwise: bool = false,
};

/// How finely a patch is made: a level is rounded up to a whole number, from
/// 1 to 64. A patch with an outer level its domain uses not above 0 is left
/// out. Triangles use outer 0 to 2, on the edges where u, v and w are 0, and
/// inner 0; quads outer 0 to 3, on the edges u = 0, v = 0, u = 1, v = 1, and
/// inner 0 and 1, along u and v; isolines outer 0 and 1.
pub const Levels = extern struct {
    outer: [4]f32 = .{ 1, 1, 1, 1 },
    inner: [2]f32 = .{ 1, 1 },
};

/// A patch: the vertices the vertex function worked that make it.
pub const Patch = extern struct {
    points: [*]const f32,
    point_stride: u32,
    corners: [*]const u32,
    /// How many vertices it is of.
    count: u32,
    /// The patch's number in the draw.
    number: u32,
    instance: u32,
    resources: *const Resources,

    /// Vertex `k` of the patch: its position, then its varyings.
    pub inline fn point(patch: *const Patch, k: u32) [*]const f32 {
        return patch.points + patch.corners[k] * patch.point_stride;
    }
};

/// Says of a patch how finely it is made, `levels` given all 1. What
/// Vulkan's control shader does to the vertices, an evaluation function does
/// from them.
pub const ControlFn = *const fn (patch: *const Patch, levels: *Levels) callconv(.c) void;

/// What an evaluation function is given: where on the patch `count` new
/// vertices lie, and where they go.
pub const Evaluations = extern struct {
    patch: *const Patch,
    levels: *const Levels,
    /// As its `Domain` has them.
    coordinates: [*]const [3]f32,
    count: u32,
    /// Each vertex's position, then its varyings: `output_stride` floats.
    outputs: [*]f32,
    output_stride: u32,

    /// Where vertex `k` goes.
    pub inline fn output(evaluations: *const Evaluations, k: u32) [*]f32 {
        return evaluations.outputs + k * evaluations.output_stride;
    }
};

pub const EvaluationFn = *const fn (evaluations: *const Evaluations) callconv(.c) void;

// --- the compute function ---------------------------------------------------

/// What a compute function is given: one group, which it makes as many
/// invocations of as `local` says. It is called once for each group, the
/// groups in no order and on any of the cores at once, so no two groups may
/// write the same memory, and on a worker's stack: keep what it puts there
/// small, and what the invocations share in `shared`.
///
/// There is nothing between the invocations of a group but the order the
/// function runs them in: a barrier is the point between two loops over them
/// inside the one call, and there are no subgroups.
pub const Groups = extern struct {
    /// This group's number along each axis.
    group: [3]u32,
    /// How many groups the dispatch has along each.
    count: [3]u32,
    resources: *const Resources,
    /// The memory this group's invocations share, `shared_bytes` of it, for
    /// this call alone: null where the function's entry asked for none, or
    /// where the library could not get it. It is this worker's own, so no
    /// other group is in it while this one runs; it is cleared before the
    /// dispatch's first group on that worker, and after that it holds what
    /// the group before it left. `sharedAs` is how to read it as values.
    /// (Since 1.41.)
    shared: ?[*]u8 = null,
    /// The invocations this group holds along each axis, as the function's
    /// entry declared them (`shader.computeGroup`): 1, 1, 1 for a
    /// `shader.compute` entry. (Since 1.41.)
    local: [3]u32 = .{ 1, 1, 1 },
    /// The bytes `shared` holds. (Since 1.41.)
    shared_bytes: u32 = 0,

    /// The invocations the group holds: `local` multiplied out. (Since 1.41.)
    pub inline fn invocations(groups: *const Groups) u32 {
        return groups.local[0] * groups.local[1] * groups.local[2];
    }

    /// Invocation `local`'s number in its group, x fastest, as GLSL's
    /// gl_LocalInvocationIndex. (Since 1.41.)
    pub inline fn localIndex(groups: *const Groups, local: [3]u32) u32 {
        return local[0] + groups.local[0] * (local[1] + groups.local[1] * local[2]);
    }

    /// Invocation `local`'s number in the dispatch, as GLSL's
    /// gl_GlobalInvocationID: the group's own number times the group's size,
    /// plus the invocation's. (Since 1.41.)
    pub inline fn globalInvocation(groups: *const Groups, local: [3]u32) [3]u32 {
        var out: [3]u32 = undefined;
        inline for (&out, 0..) |*o, k| o.* = groups.group[k] * groups.local[k] + local[k];
        return out;
    }

    /// `count` values of T in the group's shared memory: null where there is
    /// none, where it has not got room for them, or where it is not aligned
    /// for T, which it is for anything of up to 16 bytes. (Since 1.41.)
    pub inline fn sharedAs(groups: *const Groups, comptime T: type, count: usize) ?[]T {
        const bytes = groups.shared orelse return null;
        if (count * @sizeOf(T) > groups.shared_bytes) return null;
        if (@intFromPtr(bytes) % @alignOf(T) != 0) return null;
        const values: [*]T = @ptrCast(@alignCast(bytes));
        return values[0..count];
    }
};

pub const ComputeFn = *const fn (groups: *const Groups) callconv(.c) void;

/// `m * (p, 1)`, m 4 x 4 column after column.
pub inline fn transform(m: *const [16]f32, p: [3]f32) [4]f32 {
    var out: [4]f32 = undefined;
    inline for (&out, 0..) |*o, row| o.* = m[row] * p[0] + m[4 + row] * p[1] + m[8 + row] * p[2] + m[12 + row];
    return out;
}

/// A channel already of 8 bits as a smooth triangle's planes carry it.
pub fn channelOfByte(value: u32) f32 {
    return @as(f32, @floatFromInt(value)) + 0.5;
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
    /// Those the depth test kept, which are written. A fragment function of a
    /// form that drops pixels may clear a bit to drop that one: a pipeline
    /// whose form can do it has its depth written after the function has run,
    /// for the pixels left, so a dropped one leaves behind no depth to hide
    /// what is past it. `PhysicalDeviceFeatures.discarding_fragment_forms`
    /// says where that happens.
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
    /// The quads to colour. A function may clear a bit of a quad's `kept` to
    /// drop that pixel; nothing else of a quad may be changed.
    quads: [*]Quad,
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
/// and what it does past its edges are `sampling`'s; a texture not written
/// paints every pixel `missing`. One of another format than the form says
/// is drawn through the run-time sampler instead, a pixel at a time
/// (since 1.44): correct, and far slower than the form it matches.
///
/// Where w changes slowly enough, each quad takes its coordinates at its
/// centre - one division - and how fast they change there, and its pixels
/// are the centre's plus or minus half a step each way, in fixed point.
/// Elsewhere each pixel divides. How fast they change chooses the level.
/// A texture, with the pixels whose alpha is under `cutout_alpha` dropped.
/// The colours are those `textured` writes; what this adds is clearing the
/// bit of every pixel too transparent to draw, so that neither its colour nor
/// its depth is kept.
pub fn cutout(comptime sampling: texture.Sampling, fragments: *const Fragments, picture: ?*const texture.Texture) void {
    @setRuntimeSafety(false);
    textured(sampling, fragments, picture);
    for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |*quad, *out| {
        inline for (0..4) |i| {
            if (out[i] >> 24 < cutout_alpha) quad.kept &= ~(@as(u8, 1) << i);
        }
    }
}

pub fn textured(comptime sampling: texture.Sampling, fragments: *const Fragments, picture: ?*const texture.Texture) void {
    const given = picture orelse return fill(fragments, missing);
    // A texture of another format than the form was built for - a
    // compressed one on a device that keeps its blocks, say, where the
    // form says 8888 - is drawn all the same, through the sampler that
    // reads whatever a texture holds. A pixel at a time: slow, and the
    // form to declare is the texture's own format.
    if (given.format != sampling.format) return texturedOther(sampling, fragments, given);
    if (fragments.exact) texturedQuads(sampling, true, fragments, given) else texturedQuads(sampling, false, fragments, given);
}

/// `textured` where the texture's format is not the form's: the colours
/// come from `Texture.sampleLayer`, which reads any format at run time,
/// a pixel at a time. The level is the quad's own steps', as a GPU takes
/// it. (Since 1.44.)
fn texturedOther(comptime sampling: texture.Sampling, fragments: *const Fragments, given: *const texture.Texture) void {
    @setRuntimeSafety(false);
    const texels = [2]f32{ @floatFromInt(given.width(0)), @floatFromInt(given.height(0)) };
    var rows = Rows(3).of(fragments);
    for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |quad, *out| {
        const at = rows.at(quad);
        const w = @as(Pixels, @splat(1)) / at[0];
        const u: [4]f32 = at[1] * w;
        const v: [4]f32 = at[2] * w;
        const lod = if (given.levels == 1) 0 else texture.levelFor(given, (u[1] - u[0]) * texels[0], (v[1] - v[0]) * texels[1], (u[2] - u[0]) * texels[0], (v[2] - v[0]) * texels[1]);
        var colors: [4]u32 = @splat(0);
        for (&colors, 0..) |*color, i| {
            if (quad.covered >> @intCast(i) & 1 == 0) continue;
            color.* = given.sampleLayer(sampling, 0, lod, u[i], v[i]);
        }
        out.* = colors;
    }
}

/// A texture of layers, `picture`, at the three coordinates its `kind` takes,
/// varyings 0 to 2. A pixel at a time: much slower than `textured`.
pub fn layered(comptime kind: FixedKind, comptime sampling: texture.Sampling, fragments: *const Fragments, picture: ?*const texture.Texture) void {
    // Whatever format the texture holds: the samples are read through
    // `Texture.sampleLayer` and the like, which take it from the texture
    // rather than from the form (since 1.44).
    const given = picture orelse return fill(fragments, missing);
    const texels = [2]f32{ @floatFromInt(given.width(0)), @floatFromInt(given.height(0)) };
    // A cube of an array takes a fourth coordinate: which cube.
    const carried = comptime if (kind == .texture_cube_array) 5 else 4;
    var rows = Rows(carried).of(fragments);
    for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |quad, *out| {
        const at = rows.at(quad);
        const w = @as(Pixels, @splat(1)) / at[0];
        const s: [4]f32 = at[1] * w;
        const t: [4]f32 = at[2] * w;
        const r: [4]f32 = at[3] * w;
        const which: [4]f32 = if (comptime kind == .texture_cube_array) at[4] * w else @splat(0);
        var colors: [4]u32 = @splat(0);
        switch (kind) {
            .texture_array => {
                const lod = if (given.levels == 1) 0 else texture.levelFor(given, (s[1] - s[0]) * texels[0], (t[1] - t[0]) * texels[1], (s[2] - s[0]) * texels[0], (t[2] - t[0]) * texels[1]);
                for (&colors, 0..) |*color, i| {
                    if (quad.covered >> @intCast(i) & 1 == 0) continue;
                    color.* = given.sampleLayer(sampling, given.layerNear(r[i]), lod, s[i], t[i]);
                }
            },
            .texture_cube => {
                const hits = [3]texture.CubeHit{ texture.cubeHit(s[0], t[0], r[0]), texture.cubeHit(s[1], t[1], r[1]), texture.cubeHit(s[2], t[2], r[2]) };
                const same = hits[0].face == hits[1].face and hits[0].face == hits[2].face;
                const lod = if (given.levels == 1 or !same) 0 else texture.levelFor(given, (hits[1].u - hits[0].u) * texels[0], (hits[1].v - hits[0].v) * texels[1], (hits[2].u - hits[0].u) * texels[0], (hits[2].v - hits[0].v) * texels[1]);
                for (&colors, 0..) |*color, i| {
                    if (quad.covered >> @intCast(i) & 1 == 0) continue;
                    color.* = given.sampleCube(sampling, lod, s[i], t[i], r[i]);
                }
            },
            .texture_cube_array => {
                // Each pixel its own cube and its own face: the level is
                // the quad's, as it is for one cube.
                const hits = [3]texture.CubeHit{ texture.cubeHit(s[0], t[0], r[0]), texture.cubeHit(s[1], t[1], r[1]), texture.cubeHit(s[2], t[2], r[2]) };
                const same = hits[0].face == hits[1].face and hits[0].face == hits[2].face;
                const lod = if (given.levels == 1 or !same) 0 else texture.levelFor(given, (hits[1].u - hits[0].u) * texels[0], (hits[1].v - hits[0].v) * texels[1], (hits[2].u - hits[0].u) * texels[0], (hits[2].v - hits[0].v) * texels[1]);
                for (&colors, 0..) |*color, i| {
                    if (quad.covered >> @intCast(i) & 1 == 0) continue;
                    color.* = given.sampleCubeIn(sampling, given.cubeNear(which[i]), lod, s[i], t[i], r[i]);
                }
            },
            .texture_3d => {
                // Its levels are the 2D ones, each slice's own, and a
                // level has half the slices of the one before it
                // (`Texture.slicesAt`, since 1.46).
                const lod = if (given.levels == 1) 0 else texture.levelFor(given, (s[1] - s[0]) * texels[0], (t[1] - t[0]) * texels[1], (s[2] - s[0]) * texels[0], (t[2] - t[0]) * texels[1]);
                for (&colors, 0..) |*color, i| {
                    if (quad.covered >> @intCast(i) & 1 == 0) continue;
                    color.* = given.sampleVolume(sampling, lod, s[i], t[i], r[i]);
                }
            },
            else => @compileError("not a form with three coordinates"),
        }
        out.* = colors;
    }
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

/// A texture through the sampler bound beside it (`texture.Sampler`,
/// CreateSampler), at the coordinates varyings 0 and 1 carry, as `textured`
/// has them. With `shadow`, varying 2 is the reference the sample is
/// compared with (`texture.Sampler.compare`), and what is written is how
/// much of the sample passed rather than a colour.
///
/// A pixel at a time and by floats: the sampler is read for every sample,
/// and what it may ask for - the levels mixed, several samples along an
/// axis - is work the fixed path has no room for. How fast the coordinates
/// change is taken from the quad's own pixels, as a GPU takes it, so a
/// quad's four samples share a level. A texture not written, or with no
/// sampler beside it, paints every pixel `missing`; one of another format
/// than the form says is read all the same, the sampler taking the format
/// from the texture.
pub fn texturedBy(
    comptime shadow: bool,
    comptime sampling: texture.Sampling,
    fragments: *const Fragments,
    picture: ?*const texture.Texture,
    sampler: ?*const texture.Sampler,
) void {
    const given = picture orelse return fill(fragments, missing);
    const with = sampler orelse return fill(fragments, missing);
    // Everything the form's `sampling` would say - the filter, the edges,
    // the format - the sampler says instead, or the texture itself.
    _ = sampling;
    @setRuntimeSafety(false);
    var rows = Rows(if (shadow) 4 else 3).of(fragments);
    for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |quad, *out| {
        const at = rows.at(quad);
        const w = @as(Pixels, @splat(1)) / at[0];
        const u: [4]f32 = at[1] * w;
        const v: [4]f32 = at[2] * w;
        const reference: [4]f32 = if (shadow) at[3] * w else @splat(0);
        // The quad's own steps: across from its left pixel to its right,
        // down from its top row to its bottom.
        const du_dx = u[1] - u[0];
        const du_dy = u[2] - u[0];
        const dv_dx = v[1] - v[0];
        const dv_dy = v[2] - v[0];
        var colors: [4]u32 = @splat(0);
        for (&colors, 0..) |*color, i| {
            if (quad.covered >> @intCast(i) & 1 == 0) continue;
            color.* = texture.sampleBy(given, with, 0, .{
                .u = u[i],
                .v = v[i],
                .du_dx = du_dx,
                .dv_dx = dv_dx,
                .du_dy = du_dy,
                .dv_dy = dv_dy,
                .reference = reference[i],
            });
        }
        out.* = colors;
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
