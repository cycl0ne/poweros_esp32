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

    /// Its fixed form, or null where those bits name none: a word a
    /// program made up, or one of a revision later than the library's.
    /// (Since 1.75 it answers with a null rather than reading the byte as
    /// a kind whatever it holds.)
    pub fn fixed(entry: *const Entry) ?Fixed {
        return Fixed.fromBits(entry.varyings);
    }

    /// The colours a fragment function writes in the one call: 1 for a
    /// `shader.fragment` or a `shader.fixedFragment` entry, and what
    /// `shader.fragmentOutputs` said for one that writes a subpass's
    /// colour attachments together (since 1.51).
    pub fn outputCount(entry: *const Entry) u32 {
        return ((entry.varyings >> 18) & 3) + 1;
    }

    /// An evaluation function's way of tessellating, or null where its
    /// domain or its spacing is a value this library has not: a pipeline
    /// refuses such an entry with `error_invalid_shader_nv`. (Since 1.50
    /// it answers with a null rather than a domain of its own choosing.)
    pub fn tessellation(entry: *const Entry) ?Tessellation {
        const domain = (entry.varyings >> 8) & 3;
        const spacing = (entry.varyings >> 11) & 3;
        if (domain > @intFromEnum(Domain.isolines)) return null;
        if (spacing > @intFromEnum(Spacing.fractional_odd)) return null;
        return .{
            .domain = @enumFromInt(domain),
            .clockwise = entry.varyings & (1 << 10) != 0,
            .spacing = @enumFromInt(spacing),
        };
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

/// One entry's shader as a device that compiles wants it: a SPIR-V 1.0
/// module, header and all, in the program's own memory for as long as the
/// shader module lives - as an entry's name and function already are.
/// A null, or a `count` of 0, is an entry that ships none: the vertex
/// entries of a program whose fragment shaders alone are compiled say
/// `.{}` and nothing else. (Since 1.75.)
pub const Spirv = extern struct {
    words: ?[*]const u32 = null,
    count: u32 = 0,

    /// An entry's words, from what `ir.Fragment` wrote.
    pub fn of(given: []const u32) Spirv {
        return .{ .words = given.ptr, .count = @intCast(given.len) };
    }

    /// The words as a slice; empty where the entry ships none.
    pub fn module(each: Spirv) []const u32 {
        const first = each.words orelse return &.{};
        if (each.count == 0) return &.{};
        return first[0..each.count];
    }
};

/// What `ShaderModuleCreateInfo.code` points to where the entries ship
/// their SPIR-V as well, with `SHADER_MODULE_CREATE_SPIRV` in `flags` and
/// a `code_size` this wide. The words are a side of the entries, index
/// for index: entry k's are `spirv[k]`, and `spirv_count` is
/// `entry_count`.
///
/// Its first three fields **are** `Code`'s, asserted below rather than
/// intended, and the magic is the same. So a library that has not got the
/// flag reads such a module as a `Code` and runs the Zig functions: a
/// program offers its words to every revision and loses nothing but the
/// GPU path on an older one. (Since 1.75.)
pub const Module = extern struct {
    magic: u32 = MAGIC,
    entry_count: u32,
    entries: [*]const Entry,
    spirv: [*]const Spirv,
    spirv_count: u32,
};

comptime {
    // The prefix is the whole of the compatibility, so it is checked on
    // every target the SDK is built for rather than reasoned about once.
    if (@offsetOf(Module, "magic") != @offsetOf(Code, "magic")) @compileError("shader.Module's prefix is not shader.Code's");
    if (@offsetOf(Module, "entry_count") != @offsetOf(Code, "entry_count")) @compileError("shader.Module's prefix is not shader.Code's");
    if (@offsetOf(Module, "entries") != @offsetOf(Code, "entries")) @compileError("shader.Module's prefix is not shader.Code's");
    if (@sizeOf(Module) <= @sizeOf(Code)) @compileError("shader.Module has to be wider than shader.Code");
}

/// An entry for a vertex function.
pub fn vertex(name: [*:0]const u8, function: VertexFn, varyings: u32) Entry {
    return .{ .name = name, .stage = facet.SHADER_STAGE_VERTEX, .function = function, .varyings = varyings };
}

/// An entry for a fragment function.
pub fn fragment(name: [*:0]const u8, function: FragmentFn, varyings: u32) Entry {
    return .{ .name = name, .stage = facet.SHADER_STAGE_FRAGMENT, .function = function, .varyings = varyings };
}

/// An entry for a fragment function that writes `outputs` colours in the
/// one call - all the colour attachments of a subpass marked
/// SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER - rather than the one colour a
/// `fragment` entry writes. 1 to 4, and the pipeline is refused where it
/// is not the subpass's colour attachment count exactly.
/// `Fragments.colorsOf` is where each one's colours go.
/// (Since 1.51. `Capabilities.several_outputs`.)
pub fn fragmentOutputs(name: [*:0]const u8, function: FragmentFn, varyings: u32, outputs: u32) Entry {
    const held: u32 = @min(@max(outputs, 1), 4) - 1;
    return .{ .name = name, .stage = facet.SHADER_STAGE_FRAGMENT, .function = function, .varyings = varyings | held << 18 };
}

/// An entry for a tessellation control function. `own` is the floats it
/// writes for the whole patch, which its evaluation function reads back
/// (`Patch.ownValues`, since 1.50): no more than
/// `PhysicalDeviceLimits.max_tessellation_patch_components`, and 0 for a
/// control function that sets the levels alone.
pub fn control(name: [*:0]const u8, function: ControlFn, own: u32) Entry {
    return .{ .name = name, .stage = facet.SHADER_STAGE_TESSELLATION_CONTROL, .function = function, .varyings = own };
}

/// An entry for a tessellation evaluation function.
pub fn evaluation(name: [*:0]const u8, function: EvaluationFn, varyings: u32, way: Tessellation) Entry {
    return .{
        .name = name,
        .stage = facet.SHADER_STAGE_TESSELLATION_EVALUATION,
        .function = function,
        .varyings = varyings | @as(u32, @intFromEnum(way.domain)) << 8 |
            @as(u32, @intFromBool(way.clockwise)) << 10 |
            @as(u32, @intFromEnum(way.spacing)) << 11,
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
    /// A layer of an array as the sampler bound beside it says: varyings
    /// s, t and the layer, as `texture_array` has them, with everything a
    /// sampler gives that a fixed form's sampling has not - the levels
    /// mixed, a bias and a clamp on them, mirrored and bordered edges, and
    /// anisotropy. (Since 1.49.)
    texture_array_sampled = 11,
    /// A cube map the same way: varyings x, y and z, the direction. The
    /// sample is taken inside the face the direction falls on, so the
    /// sampler's edges are that face's - where `texture_cube` reads over
    /// the seam into the next face. (Since 1.49.)
    texture_cube_sampled = 12,
    /// A 3D texture the same way: varyings s, t and r, each 0 to 1 across
    /// it, with `wrap[2]` for what lies past the first and last slice and
    /// the two slices round the point mixed where the filter is bilinear.
    /// Since 1.59 `r` is taken over the slices the **level** has, a level
    /// being half as deep as the one before it
    /// (`texture.Texture.slicesAt`), and where two levels are mixed each
    /// is read over its own. (Since 1.49.)
    texture_3d_sampled = 13,
    /// One cube of an array of them as the sampler bound beside it says:
    /// varyings x, y and z, the direction, and then which cube, as
    /// `texture_cube_array` has them. The sample is taken inside the face
    /// the direction falls on, that cube's own, so the sampler's edges are
    /// that face's - where `texture_cube_array` reads over the seam into
    /// the next face of the same cube. (Since 1.53.)
    texture_cube_array_sampled = 14,
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
            .texture_array_sampled, .texture_cube_sampled, .texture_3d_sampled => 3,
            .texture_cube_array, .texture_cube_array_sampled => 4,
        };
    }

    /// Whether the form samples through a sampler bound with the texture,
    /// rather than as `sampling` says. A device whose fragment programs are
    /// its own has one for each form it can draw, so such a pipeline is
    /// refused where `Capabilities.samplers` is false.
    pub fn needsSampler(fixed: Fixed) bool {
        return switch (fixed.kind) {
            .texture_sampled, .texture_shadow => true,
            // The forms past 2D that read one (since 1.49), and the
            // array of cubes (since 1.53).
            .texture_array_sampled, .texture_cube_sampled, .texture_3d_sampled => true,
            .texture_cube_array_sampled => true,
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

    /// The form `bits_given` names, or null where its kind byte names no
    /// kind. That byte is the program's own, so it is read and not
    /// trusted: `@enumFromInt` of a value the enumeration has not got is
    /// illegal behaviour, which is a panic where there are checks and
    /// nothing at all where there are none. The filter and the address are
    /// one bit each and so are always a value. (Since 1.75.)
    fn fromBits(bits_given: u32) ?Fixed {
        const named = std.enums.fromInt(FixedKind, @as(u8, @truncate(bits_given >> 8))) orelse return null;
        return .{
            .kind = named,
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
                .texture_array_sampled, .texture_cube_sampled, .texture_3d_sampled, .texture_cube_array_sampled => layeredBy(
                    fixed.kind,
                    fragments,
                    fragments.resources.sampled(0, 0, 0),
                    fragments.resources.samplerOf(0, 0, 0),
                ),
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
/// from CmdBindDescriptorSets (`Resources.offsets`).
///
/// **Twelve, which is Vulkan's floor for a whole pipeline layout, in one
/// set.** Vulkan's two limits are per *layout* -
/// `maxDescriptorSetUniformBuffersDynamic` at least 8 and
/// `maxDescriptorSetStorageBuffersDynamic` at least 4 - and they put no
/// limit on one set, so a layout is entitled to spend all twelve of them
/// on a single set layout. That is what this has to hold, and why it is
/// twelve rather than the eight and four read separately: a set holding
/// 8 uniform and 4 storage dynamic descriptors is a legal layout, and
/// before 1.85 it was refused at the third (item 19 of
/// docs/facet-vulkan10.md).
///
/// It was 2 until then, on the reasoning that four sets of two is the
/// eight a layout may hold, which is true of a layout and false of a set:
/// CreateDescriptorSetLayout refused the third dynamic descriptor of one
/// set whatever the other three held.
///
/// The cost it was kept low for is real but small. The offsets are part
/// of what a draw was bound with, which the cores copy into the frame's
/// arena once for each draw whose bindings changed, so this array's size
/// is in that copy: `[MAX_SETS][12]u32` is 192 bytes where two a set was
/// 32, and `Resources` goes from about 200 bytes to about 360. Four a set
/// were measured for 1.43 - FacetMany drew a frame in 11.61 and 11.62 ms
/// with them against 11.18 to 11.58 ms with two over seven runs, about 2
/// per cent of the mean, by less than that test drifts between batches -
/// so the measurement never separated the copy from the noise, and
/// conformance is not a thing to trade against it either way.
pub const MAX_DYNAMIC_OFFSETS = 12;
pub const MAX_PUSH_CONSTANTS_SIZE = 128;
/// The floats a vertex function may hand to a fragment function past the
/// position, which is `Entry.varyings`' low 8 bits and both ends of
/// Vulkan's pair: `PhysicalDeviceLimits.max_vertex_output_components` out
/// of the vertex stage and `max_fragment_input_components` into the
/// fragment stage, each required to be at least 64.
///
/// **This is the one place the number is written.** It was 8 until 1.90,
/// and it was written in five uncoupled places - this library's limits
/// table, the cores' rasterizer, the vertex widening path, `ir.zig`'s
/// comptime bound, and the V3D's QPU ceiling - with nothing tying them
/// together. Four of those read it from here now; the fifth, the V3D's,
/// is a real and different ceiling and stays its own (`qpu.most_varyings`,
/// which is why that device reports 8 and refuses more at pipeline
/// creation). Item 17 of docs/facet-vulkan10.md.
///
/// A draw pays for what it carries and not for this number: the
/// per-triangle plane store and the per-vertex output store are both
/// sized at run time from the pipeline's own count, and the tiles hold no
/// varyings at all. The one place the width is comptime is the clip
/// path's vertex, and that is bucketed so a draw of 8 or fewer costs what
/// it did before (driver/cpu/raster/batched.zig).
pub const MAX_VARYINGS = 64;

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
    /// Whether `sampler` is the set layout's own and a write cannot change
    /// it: `DescriptorSetLayoutBinding.immutable_samplers` (since 1.49).
    /// In that padding as well, so a slot is as wide as it always was.
    fixed_sampler: bool = false,
    /// What a sampler or a combined image sampler was written with
    /// (CreateSampler), or what its set layout holds; null for every other
    /// kind.
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
    /// The regular grid of 1.54: one channel, two or four, of 8, 16 or 32
    /// bits, read as 0 to 1 (`r8_unorm` and the like), as the whole
    /// number itself (`_uint`, `_sint`) or as a float (`r16_sfloat`).
    /// `rgba8888` is 8-bit unorm of four channels already, so the grid
    /// starts at one channel there.
    /// 8 bits a channel: `r8_unorm`, `r8g8_unorm`.
    r8 = 8,
    rg8 = 9,
    /// `r8_uint`, `r8g8_uint`, `r8g8b8a8_uint`.
    r8u = 10,
    rg8u = 11,
    rgba8u = 12,
    /// `r8_sint`, `r8g8_sint`, `r8g8b8a8_sint`.
    r8i = 13,
    rg8i = 14,
    rgba8i = 15,
    /// 16 bits a channel: `r16_unorm`, `r16g16_unorm`,
    /// `r16g16b16a16_unorm`.
    r16 = 16,
    rg16 = 17,
    rgba16 = 18,
    /// `r16_uint`, `r16g16_uint`, `r16g16b16a16_uint`.
    r16u = 19,
    rg16u = 20,
    rgba16u = 21,
    /// `r16_sint`, `r16g16_sint`, `r16g16b16a16_sint`.
    r16i = 22,
    rg16i = 23,
    rgba16i = 24,
    /// Half-floats: `r16_sfloat`, `r16g16_sfloat`, `r16g16b16a16_sfloat`.
    r16f = 25,
    rg16f = 26,
    rgba16f = 27,
    /// 32 bits a channel, whole: `r32_uint`, `r32g32_uint`,
    /// `r32g32b32a32_uint`. A value past 2^24 is more than `Texels.at`'s
    /// float carries exactly, which is what `Texels.intAt` is for.
    r32u = 28,
    rg32u = 29,
    rgba32u = 30,
    /// `r32_sint`, `r32g32_sint`, `r32g32b32a32_sint`.
    r32i = 31,
    rg32i = 32,
    rgba32i = 33,
    /// The grid's last kind, since 1.68: `_snorm`, a whole number read as
    /// -1 to 1, the largest the channel holds either way standing for 1.
    /// `r8_snorm`, `r8g8_snorm`, `r8g8b8a8_snorm`, and the same of 16
    /// bits.
    r8n = 34,
    rg8n = 35,
    rgba8n = 36,
    r16n = 37,
    rg16n = 38,
    rgba16n = 39,
    /// `_srgb`, since 1.68: 8 bits a channel, kept the way a picture is
    /// written down and read as linear 0 to 1 - the three colour channels
    /// through sRGB's transfer function, the alpha straight.
    /// `r8_srgb`, `r8g8_srgb`, `r8g8b8a8_srgb` (which is
    /// `a8b8g8r8_srgb_pack32` as well) and `b8g8r8a8_srgb`.
    r8srgb = 40,
    rg8srgb = 41,
    rgba8srgb = 42,
    bgra8srgb = 43,
    /// Three channels of 10 bits and an alpha of 2 in one word, since
    /// 1.68: `a2b10g10r10_unorm_pack32` with red in the low bits,
    /// `a2r10g10b10_unorm_pack32` with blue there, and the `_uint` pair of
    /// them, whose channels are the whole numbers themselves.
    rgb10a2 = 44,
    bgr10a2 = 45,
    rgb10a2u = 46,
    bgr10a2u = 47,
    /// Floats in one word, since 1.68, as a texture of the format keeps
    /// them: `b10g11r11_ufloat_pack32`, three unsigned floats of 11, 11
    /// and 10 bits, and `e5b9g9r9_ufloat_pack32`, three mantissas of 9
    /// bits over one exponent of 5. Neither holds an alpha, which reads
    /// as 1, and neither holds a negative value.
    rg11b10f = 48,
    rgb9e5 = 49,
    /// Three channels of 32 bits, whole, since 1.68: `r32g32b32_uint` and
    /// `r32g32b32_sint`, beside the `rgb32f` that was there already. The
    /// three-channel formats of 8 and of 16 bits are not here: 3 or 6
    /// bytes a texel is what almost no hardware carries either.
    rgb32u = 50,
    rgb32i = 51,

    /// The bytes one texel takes; 0 for `.none`.
    pub fn bytes(format: TexelFormat) u32 {
        return switch (format) {
            .none => 0,
            .rgb565 => 2,
            .rgba8888, .bgra8888, .r32f => 4,
            // One word, whatever its channels are (since 1.68).
            .rgba8srgb, .bgra8srgb, .rgb10a2, .bgr10a2, .rgb10a2u, .bgr10a2u, .rg11b10f, .rgb9e5 => 4,
            .rg32f => 8,
            .rgb32f => 12,
            .rgba32f => 16,
            else => format.parts() * (format.channelBits() / 8),
        };
    }

    /// How many of the four parts the format holds; the rest read as 0,
    /// and alpha as 1.
    pub fn parts(format: TexelFormat) u32 {
        return switch (format) {
            .none => 0,
            .r32f, .r8, .r8u, .r8i, .r16, .r16u, .r16i, .r16f, .r32u, .r32i => 1,
            .rg32f, .rg8, .rg8u, .rg8i, .rg16, .rg16u, .rg16i, .rg16f, .rg32u, .rg32i => 2,
            .rgb565, .rgb32f => 3,
            .rgba8888, .bgra8888, .rgba32f => 4,
            .rgba8u, .rgba8i, .rgba16, .rgba16u, .rgba16i, .rgba16f, .rgba32u, .rgba32i => 4,
            // Since 1.68.
            .r8n, .r16n, .r8srgb => 1,
            .rg8n, .rg16n, .rg8srgb => 2,
            .rg11b10f, .rgb9e5, .rgb32u, .rgb32i => 3,
            .rgba8n, .rgba16n, .rgba8srgb, .bgra8srgb => 4,
            .rgb10a2, .bgr10a2, .rgb10a2u, .bgr10a2u => 4,
        };
    }

    /// The bits one channel takes, for a format whose channels are all of
    /// one width; 0 for `.none`, and 16 for `rgb565`, whose three are 5, 6
    /// and 5 of its one word. (Since 1.54.)
    pub fn channelBits(format: TexelFormat) u32 {
        return switch (format) {
            .none => 0,
            .rgb565 => 16,
            .rgba8888, .bgra8888 => 8,
            .r8, .rg8, .r8u, .rg8u, .rgba8u, .r8i, .rg8i, .rgba8i => 8,
            .r16, .rg16, .rgba16, .r16u, .rg16u, .rgba16u, .r16i, .rg16i, .rgba16i, .r16f, .rg16f, .rgba16f => 16,
            .r32f, .rg32f, .rgb32f, .rgba32f, .r32u, .rg32u, .rgba32u, .r32i, .rg32i, .rgba32i => 32,
            // Since 1.68: the grid's own widths, and one word of 32 bits
            // for every format whose channels are packed into one.
            .r8n, .rg8n, .rgba8n, .r8srgb, .rg8srgb, .rgba8srgb, .bgra8srgb => 8,
            .r16n, .rg16n, .rgba16n => 16,
            .rgb10a2, .bgr10a2, .rgb10a2u, .bgr10a2u, .rg11b10f, .rgb9e5, .rgb32u, .rgb32i => 32,
        };
    }

    /// What a channel of the format holds. (Since 1.54.)
    pub fn kind(format: TexelFormat) TexelKind {
        return switch (format) {
            .none => .none,
            .rgb565 => .packed_bits,
            .rgba8888, .bgra8888, .r8, .rg8, .r16, .rg16, .rgba16 => .unorm,
            .r8u, .rg8u, .rgba8u, .r16u, .rg16u, .rgba16u, .r32u, .rg32u, .rgba32u => .uint,
            .r8i, .rg8i, .rgba8i, .r16i, .rg16i, .rgba16i, .r32i, .rg32i, .rgba32i => .sint,
            .r16f, .rg16f, .rgba16f, .r32f, .rg32f, .rgb32f, .rgba32f => .sfloat,
            // Since 1.68. The packed words are `packed_bits` whether
            // their channels are bit fields (`packing`) or small floats
            // (`rg11b10f`, `rgb9e5`).
            .r8n, .rg8n, .rgba8n, .r16n, .rg16n, .rgba16n => .snorm,
            .r8srgb, .rg8srgb, .rgba8srgb, .bgra8srgb => .srgb,
            .rgb10a2, .bgr10a2, .rgb10a2u, .bgr10a2u, .rg11b10f, .rgb9e5 => .packed_bits,
            .rgb32u => .uint,
            .rgb32i => .sint,
        };
    }

    /// The largest whole number a channel of a `.unorm` or `.srgb` format
    /// holds: 255 of 8 bits, 65535 of 16. Of a `.snorm` one it is what is
    /// left once the sign has its bit, 127 and 32767, and the value below
    /// that - -128, -32768 - reads as -1 as well (since 1.68).
    /// (Since 1.54.)
    pub fn channelMost(format: TexelFormat) f32 {
        const signed = format.kind() == .snorm;
        if (format.channelBits() == 8) return if (signed) 127 else 255;
        return if (signed) 32767 else 65535;
    }

    /// Where each channel of a packed format lies in the texel's one word
    /// - its low bit and how many bits it takes, in x, y, z, w order,
    /// with 0 bits for a channel the format has not got - and what the
    /// channels hold. Null for every other format, `rg11b10f` and
    /// `rgb9e5` among them: their channels are small floats and not bit
    /// fields, and a texture of the format reads them
    /// (`texture.floatParts`). (Since 1.68, where `rgb565` became one of
    /// these rather than a case of its own.)
    pub fn packing(format: TexelFormat) ?Packing {
        return switch (format) {
            .rgb565 => .{ .at = .{ 11, 5, 0, 0 }, .bits = .{ 5, 6, 5, 0 } },
            .rgb10a2 => .{ .at = .{ 0, 10, 20, 30 }, .bits = .{ 10, 10, 10, 2 } },
            .bgr10a2 => .{ .at = .{ 20, 10, 0, 30 }, .bits = .{ 10, 10, 10, 2 } },
            .rgb10a2u => .{ .at = .{ 0, 10, 20, 30 }, .bits = .{ 10, 10, 10, 2 }, .whole = true },
            .bgr10a2u => .{ .at = .{ 20, 10, 0, 30 }, .bits = .{ 10, 10, 10, 2 }, .whole = true },
            else => null,
        };
    }
};

/// A packed format's channels, as `TexelFormat.packing` has them.
/// (Since 1.68.)
pub const Packing = struct {
    /// Each channel's low bit in the word.
    at: [4]u5,
    /// How many bits each takes; 0 for one the format has not got, which
    /// reads as 0, and as 1 for the alpha.
    bits: [4]u5,
    /// Whether the channels are the whole numbers themselves rather than
    /// 0 to 1 over the largest each holds.
    whole: bool = false,
};

/// What a channel of a `TexelFormat` holds. (Since 1.54.)
pub const TexelKind = enum {
    /// Nothing: `.none`.
    none,
    /// Channels of their own widths packed into the texel's one word:
    /// `rgb565` alone.
    packed_bits,
    /// A whole number read as 0 to 1, the largest it holds as 1.
    unorm,
    /// The same, signed: -1 to 1, the largest either way as 1.
    /// (Since 1.68.)
    snorm,
    /// 8 bits kept the way a picture is written down: read as linear 0 to
    /// 1, the three colour channels through sRGB's transfer function and
    /// the alpha straight. (Since 1.68.)
    srgb,
    /// A whole number read as itself, unsigned.
    uint,
    /// The same, signed, in two's complement.
    sint,
    /// A float of the channel's width.
    sfloat,
};

/// The whole number of `bits` bits at `from`, signed or not: a channel of
/// a `TexelFormat` whose channels are whole numbers. (Since 1.54.)
fn wholeAt(from: [*]const u8, bits: u32, signed: bool) i64 {
    return switch (bits) {
        8 => if (signed) @as(i64, @as(i8, @bitCast(from[0]))) else @as(i64, from[0]),
        16 => whole16: {
            const word = std.mem.readInt(u16, from[0..2], .little);
            break :whole16 if (signed) @as(i64, @as(i16, @bitCast(word))) else @as(i64, word);
        },
        else => whole32: {
            const word = std.mem.readInt(u32, from[0..4], .little);
            break :whole32 if (signed) @as(i64, @as(i32, @bitCast(word))) else @as(i64, word);
        },
    };
}

/// `value` written as a whole number of `bits` bits, its low bits taken.
/// (Since 1.54.)
fn putWhole(into: [*]u8, bits: u32, value: i64) void {
    const bytes: u64 = @bitCast(value);
    switch (bits) {
        8 => into[0] = @truncate(bytes),
        16 => std.mem.writeInt(u16, into[0..2], @truncate(bytes), .little),
        else => std.mem.writeInt(u32, into[0..4], @truncate(bytes), .little),
    }
}

/// `value` as a whole number of `bits` bits, held inside what they carry;
/// a NaN as the lowest of them. (Since 1.54.)
fn wholeFrom(value: f64, bits: u32, signed: bool) i64 {
    const span: i64 = @as(i64, 1) << @intCast(if (signed) bits - 1 else bits);
    const lowest: f64 = if (signed) @floatFromInt(-span) else 0;
    const highest: f64 = @floatFromInt(span - 1);
    const rounded = @round(value);
    if (!(rounded > lowest)) return @intFromFloat(lowest); // a NaN as well
    return @intFromFloat(@min(rounded, highest));
}

/// The float of `bits` bits at `from`, as an f32. (Since 1.54.)
fn floatAt(from: [*]const u8, bits: u32) f32 {
    if (bits == 16) {
        const half: f16 = @bitCast(std.mem.readInt(u16, from[0..2], .little));
        return @floatCast(half);
    }
    return @bitCast(std.mem.readInt(u32, from[0..4], .little));
}

/// The one word of a packed texel: two bytes or four, little-endian.
/// (Since 1.68.)
fn wordAt(from: [*]const u8, size: u32) u32 {
    return if (size == 2) std.mem.readInt(u16, from[0..2], .little) else std.mem.readInt(u32, from[0..4], .little);
}

/// `word` written back, two bytes or four. (Since 1.68.)
fn putWord(into: [*]u8, size: u32, word: u32) void {
    if (size == 2) return std.mem.writeInt(u16, into[0..2], @truncate(word), .little);
    std.mem.writeInt(u32, into[0..4], word, .little);
}

/// sRGB's transfer function, as Vulkan has it: the 8 bits a texel keeps
/// read as linear 0 to 1 - the low values a straight line, the rest a
/// power of 2.4. A table of the 256 of them, worked out as the program is
/// compiled. (Since 1.68.)
const srgb_linear: [256]f32 = made: {
    @setEvalBranchQuota(1 << 20);
    var table: [256]f32 = undefined;
    for (&table, 0..) |*one, k| {
        const part = @as(f32, @floatFromInt(k)) / 255;
        one.* = if (part <= 0.04045) part / 12.92 else std.math.pow(f32, (part + 0.055) / 1.055, 2.4);
    }
    break :made table;
};

/// The other way: linear 0 to 1 as the 0 to 1 a texel of an `.srgb`
/// format keeps. (Since 1.68.)
fn srgbOf(part: f32) f32 {
    const value = if (part >= 0) @min(part, 1) else 0;
    if (value <= 0.0031308) return value * 12.92;
    return std.math.pow(f32, value, 1.0 / 2.4) * 1.055 - 0.055;
}

/// A whole number from -1 to 1 over `most`, its sign kept: what a
/// `.snorm` channel holds, cut to -1 and 1 outside them. (Since 1.68.)
fn signedWhole(part: f32, most: f32) i64 {
    const value = if (part != part) 0 else @min(@max(part, -1), 1);
    return @intFromFloat(@round(value * most));
}

/// `value` written as a float of `bits` bits. (Since 1.54.)
fn putFloat(into: [*]u8, bits: u32, value: f32) void {
    if (bits == 16) {
        const half: f16 = @floatCast(value);
        return std.mem.writeInt(u16, into[0..2], @bitCast(half), .little);
    }
    std.mem.writeInt(u32, into[0..4], @bitCast(value), .little);
}

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
    /// The bytes from one texel to the next where that is not the
    /// format's own size, and 0 where it is: the depth of an attachment
    /// that holds a stencil too lies every four bytes, with the stencil
    /// in between (since 1.62).
    stride: u32 = 0,

    /// The bytes from one texel to the next.
    fn apart(texels: *const Texels) usize {
        return if (texels.stride != 0) texels.stride else texels.format.bytes();
    }

    /// Texel `index` as x, y, z and w: a colour format's channels are 0 to
    /// 1, an integer format's the whole numbers themselves (since 1.54),
    /// and what the format does not hold reads as 0, w as 1. All zero
    /// past the last texel.
    ///
    /// A 32-bit whole number past 2^24 is more than the float carries
    /// exactly; `intAt` reads those as they lie.
    pub fn at(texels: *const Texels, index: u32) [4]f32 {
        if (index >= texels.count) return .{ 0, 0, 0, 0 };
        const from = texels.bytes + @as(usize, index) * texels.apart();
        var made = [4]f32{ 0, 0, 0, 1 };
        switch (texels.format) {
            .none => {},
            // The four bytes of an 8888 word, in the order the format
            // keeps them; `.srgb` reads its three colour channels through
            // the transfer function and its alpha straight (since 1.68).
            .rgba8888, .bgra8888, .rgba8srgb, .bgra8srgb => {
                const packed_texel = std.mem.readInt(u32, from[0..4], .little);
                const red_first = texels.format == .rgba8888 or texels.format == .rgba8srgb;
                const order: [4]u5 = if (red_first) .{ 0, 8, 16, 24 } else .{ 16, 8, 0, 24 };
                const written = texels.format.kind() == .srgb;
                for (&made, order, 0..) |*part, shift, k| {
                    const byte: u8 = @truncate(packed_texel >> shift);
                    part.* = if (written and k < 3) srgb_linear[byte] else @as(f32, @floatFromInt(byte)) / 255;
                }
            },
            // Small floats in one word, as a texture of the format reads
            // them (since 1.68).
            .rg11b10f => made = texture.floatParts(.rg11b10f, from),
            .rgb9e5 => made = texture.floatParts(.rgb9e5, from),
            .r32f, .rg32f, .rgb32f, .rgba32f => {
                const floats: [*]align(1) const f32 = @ptrCast(from);
                for (0..texels.format.parts()) |k| made[k] = floats[k];
            },
            // Bit fields in one word: `rgb565` and the 10-10-10-2 ones
            // (`TexelFormat.packing`, since 1.68), or else the regular
            // grid of 1.54 - every channel the same width, and all of one
            // kind.
            else => {
                if (texels.format.packing()) |one| {
                    const word = wordAt(from, texels.format.bytes());
                    for (&made, one.at, one.bits) |*part, shift, width| {
                        if (width == 0) continue;
                        const most = (@as(u32, 1) << width) - 1;
                        const value = word >> shift & most;
                        part.* = if (one.whole) @floatFromInt(value) else @as(f32, @floatFromInt(value)) / @as(f32, @floatFromInt(most));
                    }
                    return made;
                }
                const bits = texels.format.channelBits();
                const step = bits / 8;
                const sort = texels.format.kind();
                for (0..texels.format.parts()) |k| {
                    const part_at = from + k * step;
                    made[k] = switch (sort) {
                        .unorm => @as(f32, @floatFromInt(wholeAt(part_at, bits, false))) / texels.format.channelMost(),
                        // -1 to 1, and never below -1: the value under the
                        // largest the channel holds stands for -1 as well.
                        .snorm => @max(@as(f32, @floatFromInt(wholeAt(part_at, bits, true))) / texels.format.channelMost(), -1),
                        .srgb => srgb_linear[@as(u8, @intCast(wholeAt(part_at, bits, false)))],
                        .uint => @floatFromInt(wholeAt(part_at, bits, false)),
                        .sint => @floatFromInt(wholeAt(part_at, bits, true)),
                        .sfloat => floatAt(part_at, bits),
                        .none, .packed_bits => 0,
                    };
                }
            },
        }
        return made;
    }

    /// Texel `index` as the four whole numbers its channels keep: an
    /// integer format's values as they lie, where `at`'s floats cannot
    /// carry a 32-bit one exactly; a format of 0 to 1 gives the numbers it
    /// keeps (0 to 255, 0 to 65535, and `rgb565` its 5, 6 and 5 bits); and
    /// a float format its channels rounded. What the format does not hold
    /// reads as 0, w as 1. All zero past the last texel. (Since 1.54.)
    pub fn intAt(texels: *const Texels, index: u32) [4]i64 {
        if (index >= texels.count) return .{ 0, 0, 0, 0 };
        const from = texels.bytes + @as(usize, index) * texels.apart();
        var made = [4]i64{ 0, 0, 0, 1 };
        switch (texels.format) {
            .none => {},
            // The bytes as they lie, the transfer function of an `.srgb`
            // format not among them: these are the numbers it keeps.
            .rgba8888, .bgra8888, .rgba8srgb, .bgra8srgb => {
                const packed_texel = std.mem.readInt(u32, from[0..4], .little);
                const red_first = texels.format == .rgba8888 or texels.format == .rgba8srgb;
                const order: [4]u5 = if (red_first) .{ 0, 8, 16, 24 } else .{ 16, 8, 0, 24 };
                for (&made, order) |*part, shift| part.* = packed_texel >> shift & 0xFF;
            },
            // Small floats, rounded as a float format's channels are.
            .rg11b10f, .rgb9e5 => {
                const parts = texels.at(index);
                for (&made, parts) |*part, one| part.* = wholeFrom(one, 32, true);
            },
            else => {
                if (texels.format.packing()) |one| {
                    const word = wordAt(from, texels.format.bytes());
                    for (&made, one.at, one.bits) |*part, shift, width| {
                        if (width == 0) continue;
                        part.* = word >> shift & ((@as(u32, 1) << width) - 1);
                    }
                    return made;
                }
                const bits = texels.format.channelBits();
                const step = bits / 8;
                const sort = texels.format.kind();
                for (0..texels.format.parts()) |k| {
                    const part_at = from + k * step;
                    made[k] = switch (sort) {
                        .unorm, .uint, .srgb => wholeAt(part_at, bits, false),
                        .snorm, .sint => wholeAt(part_at, bits, true),
                        .sfloat => wholeFrom(floatAt(part_at, bits), 32, true),
                        .none, .packed_bits => 0,
                    };
                }
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
        const into = texels.bytes + @as(usize, index) * texels.apart();
        switch (texels.format) {
            .none => {},
            .rgba8888, .bgra8888, .rgba8srgb, .bgra8srgb => {
                const red_first = texels.format == .rgba8888 or texels.format == .rgba8srgb;
                const order: [4]u5 = if (red_first) .{ 0, 8, 16, 24 } else .{ 16, 8, 0, 24 };
                const written = texels.format.kind() == .srgb;
                var made: u32 = 0;
                for (parts, order, 0..) |part, shift, k| {
                    const value = if (written and k < 3) srgbOf(part) else held(part);
                    made |= @as(u32, @intFromFloat(@round(value * 255))) << shift;
                }
                std.mem.writeInt(u32, into[0..4], made, .little);
            },
            // Small floats in one word, as a texture of the format writes
            // them: what the format cannot hold is cut to what it can.
            .rg11b10f => texture.putFloatTexel(.rg11b10f, into, parts),
            .rgb9e5 => texture.putFloatTexel(.rgb9e5, into, parts),
            .r32f, .rg32f, .rgb32f, .rgba32f => {
                const floats: [*]align(1) f32 = @ptrCast(into);
                for (0..texels.format.parts()) |k| floats[k] = parts[k];
            },
            // Bit fields in one word, or the regular grid of 1.54, as
            // `at` reads either.
            else => {
                if (texels.format.packing()) |one| {
                    var made: u32 = 0;
                    for (parts, one.at, one.bits) |part, shift, width| {
                        if (width == 0) continue;
                        const most = (@as(u32, 1) << width) - 1;
                        const value: u32 = if (one.whole)
                            @intCast(heldWhole(wholeFrom(part, 32, false), @as(i64, most)))
                        else
                            @intFromFloat(@round(held(part) * @as(f32, @floatFromInt(most))));
                        made |= value << shift;
                    }
                    return putWord(into, texels.format.bytes(), made);
                }
                const bits = texels.format.channelBits();
                const step = bits / 8;
                const sort = texels.format.kind();
                for (0..texels.format.parts()) |k| {
                    const part_at = into + k * step;
                    switch (sort) {
                        .unorm => putWhole(part_at, bits, wholeFrom(held(parts[k]) * texels.format.channelMost(), bits, false)),
                        .snorm => putWhole(part_at, bits, signedWhole(parts[k], texels.format.channelMost())),
                        .srgb => putWhole(part_at, bits, wholeFrom(@round(srgbOf(parts[k]) * 255), bits, false)),
                        .uint => putWhole(part_at, bits, wholeFrom(parts[k], bits, false)),
                        .sint => putWhole(part_at, bits, wholeFrom(parts[k], bits, true)),
                        .sfloat => putFloat(part_at, bits, parts[k]),
                        .none, .packed_bits => {},
                    }
                }
            },
        }
    }

    /// Texel `index` set from four whole numbers, as `intAt` reads them:
    /// each held inside what its channel carries, and a value past that
    /// cut to the largest or the smallest it holds. Nothing where the slot
    /// is only read, or past the last texel. (Since 1.54.)
    pub fn setInt(texels: *Texels, index: u32, parts: [4]i64) void {
        if (!texels.writable or index >= texels.count) return;
        const into = texels.bytes + @as(usize, index) * texels.apart();
        switch (texels.format) {
            .none => {},
            // The numbers as they are kept, an `.srgb` format's among
            // them: `intAt` reads them back unchanged.
            .rgba8888, .bgra8888, .rgba8srgb, .bgra8srgb => {
                const red_first = texels.format == .rgba8888 or texels.format == .rgba8srgb;
                const order: [4]u5 = if (red_first) .{ 0, 8, 16, 24 } else .{ 16, 8, 0, 24 };
                var made: u32 = 0;
                for (parts, order) |part, shift| made |= @as(u32, @intCast(heldWhole(part, 255))) << shift;
                std.mem.writeInt(u32, into[0..4], made, .little);
            },
            .rg11b10f => texture.putFloatTexel(.rg11b10f, into, floatsOf(parts)),
            .rgb9e5 => texture.putFloatTexel(.rgb9e5, into, floatsOf(parts)),
            else => {
                if (texels.format.packing()) |one| {
                    var made: u32 = 0;
                    for (parts, one.at, one.bits) |part, shift, width| {
                        if (width == 0) continue;
                        const most = (@as(u32, 1) << width) - 1;
                        made |= @as(u32, @intCast(heldWhole(part, @as(i64, most)))) << shift;
                    }
                    return putWord(into, texels.format.bytes(), made);
                }
                const bits = texels.format.channelBits();
                const step = bits / 8;
                const sort = texels.format.kind();
                for (0..texels.format.parts()) |k| {
                    const part_at = into + k * step;
                    switch (sort) {
                        .unorm, .srgb => putWhole(part_at, bits, heldWhole(parts[k], @intFromFloat(texels.format.channelMost()))),
                        // Held inside what the channel carries either way.
                        .snorm => putWhole(part_at, bits, heldBetween(parts[k], @intFromFloat(texels.format.channelMost()))),
                        .uint => putWhole(part_at, bits, wholeFrom(@floatFromInt(parts[k]), bits, false)),
                        .sint => putWhole(part_at, bits, wholeFrom(@floatFromInt(parts[k]), bits, true)),
                        .sfloat => putFloat(part_at, bits, @floatFromInt(parts[k])),
                        .none, .packed_bits => {},
                    }
                }
            },
        }
    }

    /// -`most` to `most`, a whole number: what a `.snorm` channel holds.
    /// (Since 1.68.)
    fn heldBetween(value: i64, most: i64) i64 {
        return @min(@max(value, -most), most);
    }

    /// Four whole numbers as four floats, for the formats whose channels
    /// are floats however they were given. (Since 1.68.)
    fn floatsOf(parts: [4]i64) [4]f32 {
        var made: [4]f32 = undefined;
        for (&made, parts) |*one, part| one.* = @floatFromInt(part);
        return made;
    }

    /// 0 to `most`, a whole number. (Since 1.54.)
    fn heldWhole(value: i64, most: i64) i64 {
        return @min(@max(value, 0), most);
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
///
/// Since 1.62 a depth attachment that is kept is read this way too: one
/// plane of it, the one the view's aspect names, as `r16` - the depth 0
/// to 1, nearest first, which `at` gives as x - or as `r8u`, the stencil
/// as the whole number it is. A format holding both is the two planes
/// inside the same rows, four bytes from one pixel to the next
/// (`stride`), and the view says which of them this is.
pub const Attachment = extern struct {
    /// Its first pixel, or null where nothing was written into the slot.
    bytes: ?[*]const u8 = null,
    /// The bytes from one row of pixels to the next.
    pitch: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// How a pixel is read, which is the attachment's own format.
    format: TexelFormat = .none,
    /// The bytes from one pixel to the next where that is not the
    /// format's own size, and 0 where it is: a depth attachment that
    /// holds a stencil as well is read four bytes apart, its depth and
    /// its stencil two planes inside the same rows (since 1.62).
    stride: u32 = 0,
    /// The pixel of the attachment its first column and its first row
    /// stand for: 0 and 0 for the image's own rows, which is every
    /// attachment an earlier subpass drew, and the tile's corner where
    /// what is read is the tile - the attachment this part is drawing
    /// into (`Fragments.input`, since 1.65). So a pixel is read at its
    /// own place on the attachment either way, and what this does not
    /// hold reads as transparent black.
    left: u32 = 0,
    top: u32 = 0,
    /// The samples each pixel holds: 1, or 4 for an attachment of four
    /// samples a pixel (since 1.111). What this reads by itself is sample
    /// 0, and `sampleOf` gives the others: sample s lies `s - 1` times
    /// `sample_bytes` on from `others`, which is the next plane of the
    /// image's memory for one an earlier subpass drew, and the tile's own
    /// planes of samples for the one this part is drawing. That is
    /// llvmpipe's image load of several samples, which adds the sample
    /// times its stride to the texel's offset (`lp_build_img_op_soa`,
    /// src/gallium/auxiliary/gallivm/lp_bld_sample_soa.c:4941-4956), and
    /// lavapipe reads a subpass input of several samples with that load
    /// (`try_lower_input_load`, src/gallium/frontends/lavapipe/nir/
    /// lvp_nir_lower_input_attachments.c:49-86).
    samples: u32 = 1,
    sample_bytes: usize = 0,
    others: ?[*]const u8 = null,

    /// Sample `which` of an attachment of several samples a pixel, as an
    /// attachment of one: what Vulkan's `subpassLoad` of a
    /// `subpassInputMS` reads, through `colorAt` and `at` of what it gives.
    /// A sample the attachment has not got reads as transparent black
    /// everywhere, as llvmpipe's load reads nothing for a sample past the
    /// count (`lp_build_sample_ms_offset`, lp_bld_sample_soa.c:2170-2187).
    /// Of an attachment of one sample, sample 0 is the attachment itself.
    /// (Since 1.111.)
    pub fn sampleOf(attachment: *const Attachment, which: u32) Attachment {
        var one = attachment.*;
        one.samples = 1;
        if (which == 0) return one;
        one.bytes = null;
        if (which < attachment.samples) if (attachment.others) |first| {
            one.bytes = first + @as(usize, which - 1) * attachment.sample_bytes;
        };
        return one;
    }

    /// The pixel at (x, y) of the attachment as 0xAARRGGBB; transparent
    /// black outside what this holds.
    pub fn colorAt(attachment: *const Attachment, x: u32, y: u32) u32 {
        const row = attachment.rowAt(y) orelse return 0;
        if (x < attachment.left) return 0;
        return row.colorAt(x - attachment.left);
    }

    /// The same as x, y, z and w: the channels 0 to 1, what the format
    /// does not hold as 0 and w as 1. All zero outside it.
    pub fn at(attachment: *const Attachment, x: u32, y: u32) [4]f32 {
        const row = attachment.rowAt(y) orelse return .{ 0, 0, 0, 0 };
        if (x < attachment.left) return .{ 0, 0, 0, 0 };
        return row.at(x - attachment.left);
    }

    /// The attachment's row `y` as texels, from its first column: null
    /// above or below what this holds, or where there is nothing to read.
    fn rowAt(attachment: *const Attachment, y: u32) ?Texels {
        const bytes = attachment.bytes orelse return null;
        if (y < attachment.top or attachment.format == .none) return null;
        const row = y - attachment.top;
        if (row >= attachment.height) return null;
        return .{
            .bytes = @constCast(bytes) + @as(usize, row) * attachment.pitch,
            .count = attachment.width,
            .format = attachment.format,
            .writable = false,
            .stride = attachment.stride,
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
    ///
    /// A texel is read by `colorAt` as 0xAARRGGBB whatever the format, by
    /// `partsAt` as four floats - a float texture's channels as they lie
    /// (1.57), and since 1.69 the whole of each channel of a texture that
    /// keeps its own - and since 1.70 by `wholesAt` as the four whole
    /// numbers a texture of Vulkan's `_uint` or `_sint` formats keeps,
    /// which no colour and no float carries exactly
    /// (`Capabilities.whole_textures`).
    ///
    /// An image of four samples a pixel is fetched a sample at a time
    /// (since 1.110): its texture holds each sample's texels apart
    /// (`texture.Texture.samples`), what it reads by itself is sample 0,
    /// and `texture.Texture.sampleOf` gives any one of them as a texture
    /// of one, to read at the pixel the function wants.
    pub fn sampled(resources: *const Resources, set: u32, binding: u32, element: u32) ?*const texture.Texture {
        const found = resources.slot(set, binding, element) orelse return null;
        return @ptrCast(@alignCast(found.pointer orelse return null));
    }

    /// Element `element` of binding `binding` of set `set`, a storage
    /// image, as the texture it is written through: null where it is not
    /// written, or is not a kind a function may write through.
    ///
    /// Its texels are set by `setColor` as 0xAARRGGBB whatever the format,
    /// and read by `colorAt`; a texture of floats is set by `setParts` from
    /// four floats and read by `partsAt` into them, which is what such a
    /// texel holds and what a colour of 8 bits a channel could never carry
    /// (since 1.57), and so is a texture whose channels are its own
    /// (since 1.69). A texture of whole numbers is set by `setWholes` and
    /// read by `wholesAt`, each channel the number it is rather than
    /// 0 to 1 (since 1.70). Every pair takes a level and a layer: the function
    /// names which of the view's it writes (since 1.55), level 0 of layer
    /// 0 being the view's first of each, and one the view has not got
    /// writes nothing and reads transparent black
    /// (`texture.Texture.holds`). What the view has is `levels` and
    /// `layer_count`, and each level's own size `width` and `height`.
    /// `putLayer` and `peekLayer` are the same pair in the texture's own
    /// format and hold to nothing.
    ///
    /// A colour attachment may be one since 1.56 (CreateImage): the image
    /// is kept in rows and those rows are the texture, of one level and
    /// one layer. A write reaches them at once, while what a subpass draws
    /// reaches them when it stores, so writing such an image through while
    /// the pass that draws into it is open has no order against that.
    ///
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
    /// (`Capabilities.input_attachments`).
    ///
    /// Asking this of a binding of another kind gives back whatever that
    /// kind's slot holds, read as an attachment: the layout says what a
    /// binding is, and a function has to ask for what is there, as it
    /// does for `sampled` and `texels`.
    ///
    /// A fragment function calls `Fragments.input` instead, which answers
    /// the tile for the attachment its own part is drawing into (since
    /// 1.65); this one is the descriptor as it was written, and for that
    /// attachment that is the image's memory, which the pass has not
    /// written yet.
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
    /// Where each vertex's point size goes, one float a vertex, or null
    /// where the draw makes no points: Vulkan's `PointSize`
    /// (`setPointSize`, since 1.70). Each starts at 1, so a function that
    /// writes none draws the one-pixel point a point always was. A field
    /// added at the end, so that none already there moves.
    sizes: ?[*]f32 = null,

    /// Vertex `k`'s attribute at `location`.
    pub inline fn input(vertices: *const Vertices, k: u32, location: u32) [4]f32 {
        return vertices.inputs[k * vertices.input_stride + location];
    }

    /// Where vertex `k` goes: its position, then its varyings.
    pub inline fn output(vertices: *const Vertices, k: u32) [*]f32 {
        return vertices.outputs + k * vertices.output_stride;
    }

    /// Vertex `k`'s point set to `size` pixels across and down: Vulkan's
    /// `PointSize`, for a draw of `point_list`, or of triangles drawn as
    /// their corners (`POLYGON_MODE_POINT`). The size is held inside
    /// `PhysicalDeviceLimits.point_size_range` as the point is widened,
    /// so 0 draws one pixel and a size above the range's end draws the
    /// end; a NaN draws one pixel. Nothing at all where the draw makes no
    /// points - a function may call this whatever the pipeline draws -
    /// and nothing where the pipeline tessellates, the points then being
    /// made of vertices this function never saw. (Since 1.70.)
    pub inline fn setPointSize(vertices: *const Vertices, k: u32, size: f32) void {
        if (vertices.sizes) |sizes| sizes[k] = size;
    }

    /// Vertex `k`'s point size as it stands, before it is held to the
    /// range: what `setPointSize` wrote, and 1 where nothing wrote one or
    /// the draw makes no points. (Since 1.70.)
    pub inline fn pointSize(vertices: *const Vertices, k: u32) f32 {
        const sizes = vertices.sizes orelse return 1;
        return sizes[k];
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

/// How an edge is cut into its pieces: Vulkan's three spacing modes. The
/// level is a float, and what is made of it is a whole number of pieces -
/// the question is what happens to the fraction. (Since 1.50.)
pub const Spacing = enum(u8) {
    /// The level held inside 1 to 64 and rounded up: that many pieces, all
    /// of one length. Vulkan's SpacingEqual, and what there was before
    /// 1.50.
    equal = 0,
    /// The level held inside 2 to 64 and rounded up to an even number of
    /// pieces; all but two of one length, and two shorter ones, one at
    /// each end of the edge, that shrink as the fraction does. So a level
    /// that grows moves the vertices rather than jumping them, which is
    /// what a patch whose level follows the camera wants.
    /// Vulkan's SpacingFractionalEven.
    fractional_even = 1,
    /// The same with an odd number of pieces, the level held inside 1 to
    /// 63: Vulkan's SpacingFractionalOdd. A level of 1 or below leaves the
    /// edge uncut.
    fractional_odd = 2,
};

/// What an evaluation function says of how it tessellates.
pub const Tessellation = struct {
    domain: Domain = .triangles,
    /// Triangles go clockwise on the coordinates, not the other way.
    clockwise: bool = false,
    /// How the fraction of a level is spent (since 1.50). Isolines ignore
    /// it, as Vulkan has them: their pieces are always of equal length.
    spacing: Spacing = .equal,
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
    /// The floats this patch carries from its control function to its
    /// evaluation function, as many as the control entry declared
    /// (`shader.control`): the control function writes them and the
    /// evaluation function reads them back, both through `ownValues`. Null
    /// where the entry declared none. What they hold is the patch's own
    /// doing - a normal of the whole patch, its displacement, a colour -
    /// and nothing reads them between the two calls. (Since 1.50.)
    own: ?[*]f32 = null,
    own_count: u32 = 0,

    /// Vertex `k` of the patch: its position, then its varyings.
    pub inline fn point(patch: *const Patch, k: u32) [*]const f32 {
        return patch.points + patch.corners[k] * patch.point_stride;
    }

    /// The patch's own floats, empty where its control entry declared
    /// none. The control function fills them in, undefined until it does;
    /// the evaluation function reads them. (Since 1.50.)
    pub inline fn ownValues(patch: *const Patch) []f32 {
        const first = patch.own orelse return &.{};
        return first[0..patch.own_count];
    }
};

/// Says of a patch how finely it is made, `levels` given all 1, and writes
/// what the patch carries as a whole (`Patch.ownValues`, since 1.50). What
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
    /// what is past it. With a stencil test that writes the stencil, the
    /// tests themselves are made after it, and a dropped pixel leaves the
    /// stencil as it was too (since 1.107). Its bits are then those
    /// covered, until the tests. `Capabilities.discarding_fragment_forms`
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
    /// order of `covered`'s bits. A function that writes several colour
    /// attachments at once finds the next attachment's `count` colours
    /// after this one's: `colorsOf` is the way to them.
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
    /// The attachment this call writes as the tile holds it, its `left`
    /// and `top` the tile's corner: what `input` answers where a
    /// descriptor names that same attachment, a subpass reading what it
    /// draws (since 1.64, through `input` since 1.65). Null for every
    /// other draw, which is all of them until a subpass names its own
    /// colour attachment as an input attachment.
    target: ?*const Attachment = null,
    /// That attachment as the image holds it - its first pixel - which is
    /// what a descriptor of it points at, and so how `input` tells it
    /// from an attachment an earlier subpass drew. Null where the part
    /// does not read what it draws. (Since 1.65.)
    drawn: ?[*]const u8 = null,
    /// The colour attachments the function writes in this call: 1 for
    /// every fragment function but one of a `shader.fragmentOutputs`
    /// entry drawing a subpass whose attachments go together
    /// (SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER, since 1.51). `colorsOf`
    /// gives each one's colours; attachment 0's are `colors` itself, so a
    /// function that writes the one colour needs no notice of this.
    output_count: u32 = 1,

    /// Where colour attachment `output`'s `count` colours go. Attachment
    /// 0's are `colors`; an `output` past `output_count` gives the last
    /// one's rather than memory that is not the batch's. (Since 1.51.)
    pub inline fn colorsOf(fragments: *const Fragments, output: u32) [*][4]u32 {
        const at = @min(output, fragments.output_count - 1);
        return fragments.colors + at * fragments.count;
    }

    /// Element `element` of binding `binding` of set `set`, an input
    /// attachment, as this call reads one: the pixels of it an earlier
    /// subpass drew, out of the image's memory - or, where the descriptor
    /// names the attachment this very part is drawing into, that
    /// attachment as the **tile** holds it, which is where the fragment's
    /// own pixel already is (a subpass reading what it draws, since
    /// 1.65). Null where the descriptor is not written or is of another
    /// kind.
    ///
    /// Either way a pixel is read at its own place on the attachment -
    /// `colorAt(x, y)` and `at(x, y)`, the fragment's own place being the
    /// tile's corner and the quad's place in it added (`Fragments.x`,
    /// `Fragments.y`, `Quad.x`, `Quad.y`) - and what the attachment this
    /// call holds does not cover reads as transparent black. For the one
    /// being drawn that is everything outside this tile: the fragment's
    /// own pixel is all Vulkan's self-dependency by region promises, and
    /// all this answers.
    ///
    /// This is the call a fragment function reads an input attachment
    /// with. `Resources.input` answers the descriptor as it was written,
    /// which for the attachment being drawn is the image's memory - what
    /// the pass has not written yet.
    pub inline fn input(fragments: *const Fragments, set: u32, binding: u32, element: u32) ?*const Attachment {
        const found = fragments.resources.input(set, binding, element) orelse return null;
        const own = fragments.drawn orelse return found;
        if (found.bytes != own) return found;
        return fragments.target orelse found;
    }
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
    // form to declare is the texture's own format. So is one kept in rows
    // (`Texture.pitch`) whatever its format, the fast path's places being
    // those of blocks: an image drawn into and sampled where its rows lie
    // is one of `argb8888` (since 1.119), a fixed form's own format. And
    // so is a view that swizzles its channels (since 1.120), which the
    // fast path reads as they lie, as llvmpipe's linear path takes no
    // swizzle either (`lp_linear_check_sampler`,
    // src/gallium/drivers/llvmpipe/lp_linear_sampler.c:918-924).
    if (given.format != sampling.format or given.pitch != 0 or !given.swizzle.isIdentity()) return texturedOther(sampling, fragments, given);
    if (fragments.exact) texturedQuads(sampling, true, fragments, given) else texturedQuads(sampling, false, fragments, given);
}

/// `textured` where the texture's format is not the form's, where it is
/// kept in rows, or where its view swizzles it: the colours come from
/// `Texture.sampleLayer`, which reads any format and any layout at run
/// time, swizzled, a pixel at a time. The level is
/// the quad's own steps', as a GPU takes it. (Since 1.44.)
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

/// A texture of layers, a cube map, a 3D texture or an array of cubes
/// through the sampler bound beside it (`texture.Sampler`, CreateSampler),
/// at the three coordinates varyings 0, 1 and 2 carry - as `layered` has
/// them for the forms that sample as they were compiled to. (Since 1.49;
/// the array of cubes, which takes a fourth coordinate, since 1.53.)
///
/// A pixel at a time and by floats, as `texturedBy` is, and with
/// everything a sampler says: the two levels round the point mixed, a bias
/// and a clamp on them, mirrored and bordered edges, anisotropy. How fast
/// the coordinates change is taken from the quad's own pixels, so a quad's
/// four samples share a level.
///
/// A cube's sample is taken at the face the direction falls on, its own u
/// and v and their steps the face's, and **since 1.60 what lies past that
/// face's edge is read from the face beside it**
/// (`texture.Texture.sampleCubeBy`), as the fixed form `texture_cube`
/// does: a bilinear sample on a seam mixes the texels either side of it
/// rather than the face's own edge twice, and the sampler's `wrap` says
/// nothing of a cube. An array of cubes reads over the seams of the cube
/// varying 3 names - the nearest there is, as `texture.Texture.cubeNear`
/// picks it. Where the quad's four pixels do not fall on the one face the
/// level is the first, as it is for the fixed forms: the steps across a
/// seam are no measure of anything. A texture not written, or with no
/// sampler beside it, paints every pixel `missing`.
pub fn layeredBy(
    comptime kind: FixedKind,
    fragments: *const Fragments,
    picture: ?*const texture.Texture,
    sampler: ?*const texture.Sampler,
) void {
    const given = picture orelse return fill(fragments, missing);
    const with = sampler orelse return fill(fragments, missing);
    @setRuntimeSafety(false);
    // A cube of an array takes a fourth coordinate: which cube.
    const carried = comptime if (kind == .texture_cube_array_sampled) 5 else 4;
    var rows = Rows(carried).of(fragments);
    for (fragments.quads[0..fragments.count], fragments.colors[0..fragments.count]) |quad, *out| {
        const at = rows.at(quad);
        const w = @as(Pixels, @splat(1)) / at[0];
        const s: [4]f32 = at[1] * w;
        const t: [4]f32 = at[2] * w;
        const r: [4]f32 = at[3] * w;
        const which: [4]f32 = if (comptime kind == .texture_cube_array_sampled) at[4] * w else @splat(0);
        // Where the quad's four pixels sample, and the steps between them:
        // the coordinates themselves for an array or a volume, and the
        // face's own u and v for a cube, of one or of an array.
        var us: [4]f32 = s;
        var vs: [4]f32 = t;
        var faces: [4]u32 = @splat(0);
        var one_face = true;
        if (comptime kind == .texture_cube_sampled or kind == .texture_cube_array_sampled) {
            inline for (0..4) |i| {
                const hit = texture.cubeHit(s[i], t[i], r[i]);
                us[i] = hit.u;
                vs[i] = hit.v;
                faces[i] = hit.face;
                if (i > 0 and hit.face != faces[0]) one_face = false;
            }
        }
        // The quad's steps measure a level only where its pixels are on
        // the one face: across a seam the u and v are two faces' and say
        // nothing, so the level is the first, as the fixed forms have it
        // (since 1.60).
        const du_dx = if (one_face) us[1] - us[0] else 0;
        const du_dy = if (one_face) us[2] - us[0] else 0;
        const dv_dx = if (one_face) vs[1] - vs[0] else 0;
        const dv_dy = if (one_face) vs[2] - vs[0] else 0;
        var colors: [4]u32 = @splat(0);
        for (&colors, 0..) |*color, i| {
            if (quad.covered >> @intCast(i) & 1 == 0) continue;
            const point = texture.Point{
                .u = us[i],
                .v = vs[i],
                .du_dx = du_dx,
                .dv_dx = dv_dx,
                .du_dy = du_dy,
                .dv_dy = dv_dy,
            };
            color.* = switch (kind) {
                .texture_array_sampled => texture.sampleBy(given, with, given.layerNear(r[i]), point),
                // Over the cube's seams since 1.60, as the fixed forms
                // read them: the face is where the sample begins, not
                // where it is held.
                .texture_cube_sampled => texture.sampleCubeBy(given, with, 0, faces[i], point),
                // That cube's first face, and the face the direction fell
                // on: a cube of an array is six layers.
                .texture_cube_array_sampled => texture.sampleCubeBy(given, with, given.cubeNear(which[i]), faces[i], point),
                .texture_3d_sampled => texture.sampleVolumeBy(given, with, point, r[i]),
                else => @compileError("not a form of three coordinates that samples through a sampler"),
            };
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
