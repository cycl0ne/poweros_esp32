// SPDX-License-Identifier: MIT
//! A pipeline layout, and a graphics pipeline: its functions and its
//! state, settled as it is made.
//!
//! What facet.library's pipelines draw:
//! - points, lines and triangles - lists, strips and fans - the triangles
//!   filled or as their edges or corners, one sample a pixel or four where
//!   the device draws them;
//! - patches tessellated on the cores, into triangles or lines;
//! - the vertex function's inputs read from up to sixteen vertex buffers,
//!   an attribute a location, of floats or of bytes 0 to 1;
//! - culled by their facing, front or back or both;
//! - a depth test of any compare, the depth written or not, the triangles'
//!   depth moved by a bias as asked, and a stencil test of any compare and
//!   operations, a face's own;
//! - the colour written, the channels asked for, replacing what is there or
//!   mixed with it by any blend factors and operation, each colour
//!   attachment its own way, and no logic op;
//! - one viewport and one scissor, given here or set by commands.
//!
//! Anything else is refused as the pipeline is made, rather than drawn
//! otherwise than asked: `error_validation_failed` where Vulkan does not
//! allow it on the device, `error_feature_not_present` where it does
//! (since 1.133; CreateGraphicsPipelines' RESULT says which).

const std = @import("std");
const sdk = @import("sdk");
const facet = sdk.facet;
const shader = facet.shader;
const Device = @import("../device/_device.zig").Device;
const _instance = @import("../instance/_instance.zig");
const _render = @import("../render/_render.zig");

pub const PipelineLayout = struct {
    device: *Device,
    set_count: u32,
    push_size: u32,
};

/// A pipeline cache (since 1.130), which holds no pipeline, as lavapipe's
/// holds none (lvp_pipeline_cache.c): what it hands out is Vulkan's header
/// alone.
pub const Cache = struct {
    device: *Device,
};

/// Where a vertex buffer binding's data goes.
pub const Binding = struct {
    stride: u32 = 0,
    per_instance: bool = false,
};

/// Where a location's input is read from.
pub const Attribute = struct {
    location: u32,
    binding: u32,
    format: facet.Format,
    offset: u32,
};

/// Which triangles are not drawn.
pub const Cull = enum { none, back, front };

/// What a pixel drawn does to what is there. Off, it replaces it, the
/// channels of `mask` only.
pub const Mixing = struct {
    enabled: bool = false,
    src_color: facet.BlendFactor = .one,
    dst_color: facet.BlendFactor = .zero,
    color_op: facet.BlendOp = .add,
    src_alpha: facet.BlendFactor = .one,
    dst_alpha: facet.BlendFactor = .zero,
    alpha_op: facet.BlendOp = .add,
    mask: u32 = facet.COLOR_COMPONENT_ALL,
    /// Null where a command sets them (CmdSetBlendConstants).
    constants: ?[4]f32 = .{ 0, 0, 0, 0 },

    /// The same over a target that has no alpha: what is there reads as
    /// wholly opaque.
    pub fn overOpaque(mixing: Mixing) Mixing {
        var made = mixing;
        made.src_color = opaqueFactor(mixing.src_color);
        made.dst_color = opaqueFactor(mixing.dst_color);
        made.src_alpha = opaqueFactor(mixing.src_alpha);
        made.dst_alpha = opaqueFactor(mixing.dst_alpha);
        return made;
    }

    fn opaqueFactor(factor: facet.BlendFactor) facet.BlendFactor {
        return switch (factor) {
            .dst_alpha => .one,
            .one_minus_dst_alpha, .src_alpha_saturate => .zero,
            else => factor,
        };
    }
};

/// What a triangle adds to its depth before it is tested and written, in
/// the depth attachment's own terms: `constant` smallest differences, and
/// `slope` of its steepest slope, held inside `clamp` of the depth range
/// where that is not 0 (a positive one the most, a negative one the least).
pub const Bias = struct {
    constant: f32 = 0,
    clamp: f32 = 0,
    slope: f32 = 0,
};

/// A face's stencil test.
pub const StencilFace = struct {
    fail: facet.StencilOp = .keep,
    pass: facet.StencilOp = .keep,
    depth_fail: facet.StencilOp = .keep,
    compare: facet.CompareOp = .never,
    compare_mask: u8 = 0,
    write_mask: u8 = 0,
    reference: u8 = 0,
};

/// What a pipeline does between the vertex function and the rasterizer.
pub const Tessellated = struct {
    control: shader.ControlFn,
    evaluation: shader.EvaluationFn,
    way: shader.Tessellation,
    /// The vertices of a patch.
    points: u32,
    /// What the vertex function writes past the position.
    vertex_varyings: u32,
    /// The floats the control function writes for the whole patch, which
    /// the evaluation function reads back (`shader.Patch.ownValues`,
    /// since 1.50); 0 where its entry declared none.
    own: u32 = 0,
};

pub const Pipeline = struct {
    device: *Device,
    /// What its driver made of it (make_pipeline).
    driver: ?*anyopaque = null,
    /// A compute pipeline: nothing else here but `device`, `driver`,
    /// `local` and `shared` is set, and no driver makes anything of it.
    compute: ?shader.ComputeFn = null,
    tessellated: ?Tessellated = null,
    vertex: shader.VertexFn,
    fragment: shader.FragmentFn,
    /// The fragment function's fixed form, if it has one.
    fixed: shader.Fixed,
    /// Its fragment shader as a device with a processor of its own wants
    /// it: the SPIR-V the program shipped beside the function (a
    /// `shader.Module`), or nothing where it shipped none. A driver that
    /// compiles reads it in `make_pipeline` and refuses what it cannot
    /// make code of (`error_feature_not_present`); one that does not, and
    /// one that finds nothing here, calls `fragment` as it always has.
    /// The words are the program's own memory and live as long as it
    /// keeps them there (since 1.75).
    fragment_words: []const u32 = &.{},
    /// Whether the fragment shader may drop a pixel, which makes the depth
    /// wait for it: its fixed form says so, or the SPIR-V shipped beside
    /// it holds an `OpKill`, as llvmpipe goes by the shader's
    /// `info.fs.uses_discard` (since 1.139). A function shipped with no
    /// words and no form that drops is taken at its word that it does not.
    discards: bool = false,
    varyings: u32,
    /// The locations the vertex function's inputs take: the highest an
    /// attribute reads into, and one.
    locations: u32,
    bindings: [_instance.max_vertex_input_bindings]Binding,
    attributes: [_instance.max_vertex_input_attributes]Attribute,
    attribute_count: u32,
    topology: facet.PrimitiveTopology,
    /// What comes to be drawn: `topology`, or what patches are made into.
    drawn_topology: facet.PrimitiveTopology,
    /// Triangles drawn filled, or as their edges or their corners.
    polygon_mode: facet.PolygonMode,
    /// In pixels; null where a command sets it (CmdSetLineWidth).
    line_width: ?f32,
    /// An index of all ones ends a strip or a fan, and the next starts.
    restart: bool,
    /// Its draws draw nothing: the rasterizer is switched off, or every
    /// triangle is culled - a polygon's face, which a line or a point has
    /// none of (since 1.92). Both of those discard the primitive *before*
    /// rasterisation, so a draw of this pipeline still owes the counters
    /// of input assembly and the vertex stage - which is what separates it
    /// from `sample_mask` below. See driver/cpu/_draw.zig.
    draws_nothing: bool,
    /// Of those, the ones whose every face is culled
    /// (`CULL_MODE_FRONT_AND_BACK`) and whose rasterizer is on: their
    /// primitives reach clipping, are counted going in, and stop at setup.
    /// That is llvmpipe's `triangle_noop`, which `lp_setup_choose_triangle`
    /// picks for that cull after gallium's draw module has counted the
    /// primitives into its clip stage. (Since 1.92.)
    culls_everything: bool,
    /// `PipelineMultisampleStateCreateInfo.sample_mask`'s first word, or
    /// all ones where the program passed none - which Vulkan says to read
    /// as every sample covered. With one sample a pixel only bit 0 is
    /// read: Vulkan reads ceil(rasterization_samples / 32) words and
    /// ignores the bits above the sample count. Clearing it covers no
    /// sample, so nothing is shaded - but the mask is applied *after*
    /// rasterisation, so such a draw owes the clipping counters as well,
    /// and this is therefore not `draws_nothing`. (Since 1.89.)
    sample_mask: u32,
    /// `PipelineMultisampleStateCreateInfo.rasterization_samples`, which
    /// Vulkan has be its subpass's count: 1, or 4 on a device that draws
    /// them (since 1.100).
    samples: u32 = 1,
    /// `alpha_to_coverage_enable`: colour 0's alpha cuts the samples a
    /// pixel covers, which every implementation of Vulkan 1.0 does - it
    /// has no feature to ask for. The cores dither it as lavapipe does
    /// (driver/cpu/raster/batched.zig). The V3D takes it at four samples
    /// through a compiled program's FTOC since 1.149, and draws a pipeline
    /// of one without it, as v3dv does; a fixed form of four that asks
    /// for it it refuses (docs/facet-vulkan10.md item 61, V6). (Since
    /// 1.108.)
    alpha_to_coverage: bool = false,
    cull: Cull,
    front: facet.FrontFace,
    depth_test: ?facet.CompareOp,
    depth_write: bool,
    /// Whether its triangles move their depth before it is tested and
    /// written (`depth_bias_enable`), and by how much: null where a
    /// command says (CmdSetDepthBias).
    biased: bool,
    bias: ?Bias,
    /// Whether what lies past the near plane is drawn all the same, its
    /// depth held inside the viewport's range a pixel at a time
    /// (`depth_clamp_enable`, `Capabilities.depth_clamp`).
    clamped: bool = false,
    /// Whether a pixel is drawn only where the depth already there lies
    /// between two bounds (`depth_bounds_test_enable`), and which: null
    /// where a command says (CmdSetDepthBounds).
    bounded: bool = false,
    bounds: ?[2]f32 = .{ 0, 1 },
    /// The front's and the back's test, or null for none.
    stencil: ?[2]StencilFace,
    /// What of them commands set (CmdSetStencilCompareMask and the like).
    dynamic_stencil_compare: bool,
    dynamic_stencil_write: bool,
    dynamic_stencil_reference: bool,
    /// PIPELINE_CREATE_DEPTH_PREPASS.
    prepass: bool,
    /// What each colour attachment of the subpass is mixed with what is
    /// there by: one for each, `mixingAt` giving the one being drawn
    /// (`Capabilities.independent_blend`, since 1.33). All hold
    /// the default where the create info gave no attachment state.
    mixings: [_render.most_colors]Mixing,
    /// The colour attachments the fragment function writes in the one
    /// call (`shader.fragmentOutputs`, since 1.51): 1 for a function that
    /// writes the one colour, and the subpass's colour attachment count
    /// for one drawing a subpass whose attachments go together
    /// (SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER).
    outputs: u32 = 1,
    /// The viewport and the scissor, or null where commands set them.
    viewport: ?facet.Viewport,
    scissor: ?facet.Rect2D,
    /// A compute pipeline's workgroup, as its entry declared it: the
    /// invocations a group holds and the bytes they share
    /// (`shader.computeGroup`). At the end, where it is out of the way of
    /// what a draw reads.
    local: [3]u32 = .{ 1, 1, 1 },
    shared: u32 = 0,
};

/// How the colour attachment a part draws is mixed with what is there:
/// `output` is which of the subpass's colour attachments that is
/// (`shader.Resources.output`), and a pipeline holds one mixing for each.
pub fn mixingAt(pipeline: *const Pipeline, output: u32) *const Mixing {
    return &pipeline.mixings[@min(output, _render.most_colors - 1)];
}

/// The formats an attribute is read in.
pub fn attributeFormat(format: facet.Format) bool {
    return switch (format) {
        .r32_sfloat, .r32g32_sfloat, .r32g32b32_sfloat, .r32g32b32a32_sfloat, .r8g8b8a8_unorm, .b8g8r8a8_unorm => true,
        else => false,
    };
}

/// The value an attribute of `format` holds at `at`, as four floats, the
/// parts the format does not fill (0, 0, 0, 1).
pub fn decode(format: facet.Format, at: [*]const u8) [4]f32 {
    var value = [4]f32{ 0, 0, 0, 1 };
    switch (format) {
        .r32_sfloat, .r32g32_sfloat, .r32g32b32_sfloat, .r32g32b32a32_sfloat => {
            const count: usize = switch (format) {
                .r32_sfloat => 1,
                .r32g32_sfloat => 2,
                .r32g32b32_sfloat => 3,
                else => 4,
            };
            // An offset need not be aligned.
            for (value[0..count], 0..) |*part, k| part.* = @bitCast(std.mem.readInt(u32, at[k * 4 ..][0..4], .little));
        },
        .r8g8b8a8_unorm => for (&value, 0..) |*part, k| {
            part.* = @as(f32, @floatFromInt(at[k])) / 255;
        },
        .b8g8r8a8_unorm => for (&value, [4]usize{ 2, 1, 0, 3 }) |*part, k| {
            part.* = @as(f32, @floatFromInt(at[k])) / 255;
        },
        else => {},
    }
    return value;
}
