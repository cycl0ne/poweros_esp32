// SPDX-License-Identifier: MIT
//! CreateGraphicsPipelines: ways of drawing.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const shader = facet.shader;
const std = @import("std");
const _objects = @import("../_objects.zig");
const _render = @import("../render/_render.zig");
const Device = @import("../device/_device.zig").Device;
const _pipeline = @import("_pipeline.zig");
const Pipeline = _pipeline.Pipeline;
const _shader = @import("../shader/_shader.zig");
const _instance = @import("../instance/_instance.zig");

/// `count` graphics pipelines, one for each of `infos`, into `pipelines`.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateGraphicsPipelines(base: *FacetBase, device: *facet.Device, cache: ?*facet.PipelineCache, count: u32, infos: [*]const facet.GraphicsPipelineCreateInfo, pipelines: [*]?*facet.Pipeline) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -268.
///
/// INPUTS:
/// - `device` - the device.
/// - `cache` - null: facet.library has no pipeline caches.
/// - `count`, `infos` - each pipeline's stages and state.
/// - `pipelines` - where each is written; null for one that could not be
///   made.
///
/// RESULT:
/// `success`; else what the first that could not be made came to:
/// `error_invalid_shader_nv` for stages that are not one vertex function
/// and one fragment function of the same varyings or none (since 1.115),
/// with or without a tessellation control and evaluation function, whose
/// varyings then the fragment function's have to be, or for a fragment
/// function that writes other
/// than the subpass's colour attachments (`shader.fragmentOutputs`, since
/// 1.51), or for a fragment entry whose `varyings` word names no fixed
/// form (since 1.75); `error_feature_not_present`
/// for state facet.library does not draw (see BEHAVIOR), among it a
/// stage whose `specialization_info` names a constant (since 1.80);
/// `error_format_not_supported` for an attribute in a format it does not
/// read; `error_initialization_failed` for state that does not hold
/// together - an attribute of a binding not given, no viewport where it is
/// not set by commands; `error_out_of_host_memory`. Those made are made
/// either way.
///
/// BEHAVIOR:
/// A pipeline takes its vertex and fragment functions from the modules by
/// stage and name, and settles its state as it is made: the rasterizer's
/// code for its depth test and blend is chosen then, not as it draws. On a
/// device with a processor of its own the fragment function has to be of a
/// fixed form (`shader.fixedFragment`), or the pipeline is refused with
/// `error_feature_not_present`.
///
/// A pipeline of no fragment stage, as Vulkan 1.0 allows - a shadow map's
/// - is drawn with a fragment function of the library's own that does
/// nothing, as lavapipe binds `noop_fs` where a pipeline has none
/// (lvp_device.c:2048-2052, lvp_execute.c:552-554; since 1.115). Vulkan
/// leaves what it writes into a colour attachment undefined, and here every
/// colour attachment keeps what it held; alpha to coverage, which takes
/// the alpha of a colour that is not written, changes no sample, as in
/// llvmpipe (lp_state_fs.c:1181-1185). A device with a processor of its
/// own has no code for it and refuses it with `error_feature_not_present`:
/// the V3D, until v3dv's no-op fragment shader is ported
/// (v3dv_pipeline.c:2616-2642, docs/facet-vulkan10.md item 85).
///
/// With tessellation functions, the topology is `patch_list` and the
/// `tessellation_state` says the vertices of a patch, 1 to 32: the cores make
/// each patch into triangles or lines (`shader.Tessellation`), for a device
/// with a processor of its own too, and those are drawn; without them,
/// `patch_list` is `error_initialization_failed`. The evaluation entry says
/// the domain, which way round its triangles go, and how the fraction of a
/// level is spent (`shader.Spacing`, since 1.50): a domain or a spacing of a
/// value this library has not is `error_invalid_shader_nv`. The control entry
/// says the floats the patch carries from the one function to the other
/// (`shader.control`, `Patch.ownValues`, since 1.50), more of them than
/// `PhysicalDeviceLimits.max_tessellation_patch_components` being
/// `error_feature_not_present`.
///
/// What it draws: points, lines and line strips, and triangle lists, strips
/// and fans, a restart index ending a strip or a fan; triangles filled, or as
/// their edges or corners (POLYGON_MODE_LINE, POINT); one sample a pixel,
/// or four in a subpass of four on a device that draws them (since 1.100);
/// triangles culled by facing as asked; lines `line_width` pixels wide, set
/// here or by CmdSetLineWidth, and points one pixel; a
/// depth test of any compare, written or not, with a bias on the triangles'
/// depth where the device takes one, held inside the viewport's range
/// where it clamps (`depth_clamp_enable`) and kept only between two
/// bounds where it tests them (`depth_bounds_test_enable`, since 1.40);
/// a stencil test of any compare and operations, a face's own, the masks and
/// the reference given here or set by commands; the channels of the write mask written, replacing what is
/// there or mixed with it by any blend factors and operation, the alpha by
/// its own and each colour attachment of the subpass by its own
/// (`color_blend_state.attachments`, one for each), and no logic op; one viewport and one scissor, given here or set
/// by CmdSetViewport and CmdSetScissor (DynamicState viewport and scissor;
/// blend_constants with CmdSetBlendConstants, line_width with CmdSetLineWidth,
/// depth_bias with CmdSetDepthBias, depth_bounds with CmdSetDepthBounds,
/// the stencil's with CmdSetStencilCompareMask, CmdSetStencilWriteMask and
/// CmdSetStencilReference;
/// the others are taken and do nothing). A pipeline with the rasterizer
/// discarding, or culling front and back, draws nothing.
///
/// `PIPELINE_CREATE_DEPTH_PREPASS` in `flags`, facet.library's own, has the
/// pipeline's triangles' depth drawn first in each tile and each pixel then
/// shaded once, by the nearest: a scene drawn back to front costs little
/// more than one drawn front to back, which costs a little more than
/// without it. For a depth test of LESS or LESS_OR_EQUAL, written, and no
/// blending; ignored otherwise. Other flags are taken and do nothing.
///
/// On a device with a processor of its own, the fragment function has to be
/// one of the fixed forms (`shader.fixedFragment`), or the shader has to
/// come with its SPIR-V (a `shader.Module` and
/// `SHADER_MODULE_CREATE_SPIRV`, since 1.75), or the pipeline is refused
/// with `error_feature_not_present`; the cores, always the first device
/// listed, take any. Where the words are there they are handed to the
/// driver with the pipeline, and a driver that cannot make code of them
/// answers `error_feature_not_present` all the same: a shader may be well
/// formed SPIR-V and still ask for more than the device has.
///
/// Specialization constants are not honoured: a stage whose
/// `specialization_info` names any (`map_entry_count` above 0) is refused
/// with `error_feature_not_present` rather than made with the constants
/// dropped, which would draw what the program did not ask for (since
/// 1.80; before it the pointer was read by nothing and no one was told).
/// A `SpecializationInfo` of no entries specializes nothing, as in Vulkan,
/// and is made: a program that fills the struct for every stage and leaves
/// it empty where it has no constants is not turned away.
///
/// Attributes are read as floats - r32_sfloat to r32g32b32a32_sfloat - or
/// as bytes 0 to 1, r8g8b8a8_unorm and b8g8r8a8_unorm, into four floats
/// each, up to sixteen bindings and sixteen locations, which is the floor
/// Vulkan puts under `maxVertexInputBindings` and
/// `maxVertexInputAttributes`. It was four and eight until 1.84.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Each pipeline is the caller's, until DestroyPipeline. The modules, the
/// layout and the render pass may go before it; the functions it took have
/// to last as long as it does, as the program's code does.
///
/// NOTES:
/// A depth test on a render pass without depth is no test, as Vulkan has
/// it, nor a stencil test on one without stencil. Lines and points use the
/// front's stencil test, and take no depth bias: only triangles are moved,
/// as in Vulkan, and `depth_bias_enable` wants a device whose
/// `Capabilities.depth_bias` is true (since 1.34).
///
/// `depth_clamp_enable` draws what lies past the near plane instead of
/// cutting it away, each pixel's depth held inside the viewport's
/// `min_depth` and `max_depth` - which is what a shadow volume wants - and
/// `depth_bounds_test_enable` draws a pixel only where the depth
/// **already** in the attachment lies between `min_depth_bounds` and
/// `max_depth_bounds`, whatever the depth being drawn; `DynamicState`'s
/// `depth_bounds` leaves the two to CmdSetDepthBounds. Both want a device
/// whose `Capabilities.depth_clamp` or `depth_bounds` is true -
/// every device since 1.47, the V3D's own configuration having both - and
/// on the cores both have a draw's pixels walked one at a time, as a
/// stencil test does, so they cost more there than the quads the fast
/// paths walk.
///
/// On an attachment without alpha, R5G6B5, what is there reads as wholly
/// opaque. `color_blend_state.attachments` holds one state for each colour
/// attachment of the subpass, or none for the default over all of them; a
/// subpass of several has each blended its own way (since 1.33,
/// `Capabilities.independent_blend`). The blend constants are
/// the pipeline's and shared, as in Vulkan, unless
/// `attachment_constants` gives one set for each attachment instead -
/// facet.library's own, since 1.51 - and with `blend_constants` among the
/// dynamic states CmdSetBlendConstants sets the one set over all of them
/// and CmdSetBlendConstantsAt one attachment's own. On the cores,
/// SRC_ALPHA and ONE_MINUS_SRC_ALPHA or ONE, with
/// the alpha's factors the same or ZERO and ONE and the mask whole, cost
/// less than any other mixing.
///
/// The fragment entry says how many colours its function writes in the
/// one call: one, or the subpass's colour attachments where the subpass
/// draws them together (SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER,
/// `shader.fragmentOutputs`, since 1.51). It has to come to exactly what
/// the subpass has either way, and a function of several wants a device
/// whose `several_outputs` is true.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateShaderModule`, `CreatePipelineLayout`, `CreateRenderPass`, `CmdBindPipeline`, `DestroyPipeline`
///
/// EXAMPLES:
/// ```zig
/// const stages = [2]facet.PipelineShaderStageCreateInfo{
///     .{ .stage = facet.SHADER_STAGE_VERTEX, .module = module.? },
///     .{ .stage = facet.SHADER_STAGE_FRAGMENT, .module = module.? },
/// };
/// const raster_state = facet.PipelineRasterizationStateCreateInfo{ .cull_mode = facet.CULL_MODE_BACK, .front_face = .clockwise };
/// const depth = facet.PipelineDepthStencilStateCreateInfo{ .depth_test_enable = true, .depth_write_enable = true };
/// const viewport_state = facet.PipelineViewportStateCreateInfo{ .viewports = @ptrCast(&viewport), .scissors = @ptrCast(&scissor) };
/// var pipeline: ?*facet.Pipeline = null;
/// _ = fb.CreateGraphicsPipelines(device, null, 1, @ptrCast(&facet.GraphicsPipelineCreateInfo{
///     .stage_count = 2,
///     .stages = &stages,
///     .viewport_state = &viewport_state,
///     .rasterization_state = &raster_state,
///     .depth_stencil_state = &depth,
///     .layout = layout.?,
///     .render_pass = pass.?,
/// }), @ptrCast(&pipeline));
/// ```
pub fn CreateGraphicsPipelines(base: *FacetBase, device: *facet.Device, cache: ?*facet.PipelineCache, count: u32, infos: [*]const facet.GraphicsPipelineCreateInfo, pipelines: [*]?*facet.Pipeline) facet.Result {
    _ = cache;
    const owner = _objects.of(Device, device);
    var result: facet.Result = .success;
    for (infos[0..count], pipelines[0..count]) |*info, *pipeline| {
        pipeline.* = null;
        const made = _objects.create(base.sys_base, Pipeline) orelse {
            if (result == .success) result = .error_out_of_host_memory;
            continue;
        };
        const settled = settle(made, owner, info);
        if (settled != .success) {
            _objects.destroy(base.sys_base, made);
            if (result == .success) result = settled;
            continue;
        }
        const translated = owner.physical.ops.make_pipeline(made);
        if (translated != .success) {
            _objects.destroy(base.sys_base, made);
            if (result == .success) result = translated;
            continue;
        }
        pipeline.* = _objects.handle(facet.Pipeline, made);
    }
    return result;
}

/// The fragment function of a pipeline of no fragment stage: one of no
/// instructions, which writes nothing and drops no pixel (since 1.115).
fn noFragment(fragments: *const shader.Fragments) callconv(.c) void {
    _ = fragments;
}
const no_fragment = shader.fragment("main", &noFragment, 0);

/// `made` filled in from `info`: what it came to.
fn settle(made: *Pipeline, device: *Device, info: *const facet.GraphicsPipelineCreateInfo) facet.Result {
    // The functions.
    var vertex: ?*const shader.Entry = null;
    var fragment: ?*const shader.Entry = null;
    var control: ?*const shader.Entry = null;
    var evaluation: ?*const shader.Entry = null;
    // The words beside the fragment function, where the module shipped
    // them: what a device with a processor of its own compiles instead of
    // calling the function (since 1.75).
    var fragment_words: []const u32 = &.{};
    for (info.stages[0..info.stage_count]) |stage| {
        // Specialization constants are not honoured, and a pipeline that
        // drew with them dropped would draw something the program did
        // not ask for: refused instead (since 1.80). A `SpecializationInfo`
        // of no entries specializes nothing, which is what a program that
        // fills the struct unconditionally gives: that is not refused.
        if (stage.specialization_info) |asked| {
            if (asked.map_entry_count != 0) return .error_feature_not_present;
        }
        const module = _objects.of(_shader.ShaderModule, stage.module);
        const at = _shader.findAt(module, stage.stage, stage.name) orelse return .error_invalid_shader_nv;
        const entry = &module.entries()[at];
        switch (stage.stage) {
            facet.SHADER_STAGE_VERTEX => vertex = entry,
            facet.SHADER_STAGE_FRAGMENT => {
                fragment = entry;
                fragment_words = module.wordsAt(at);
            },
            facet.SHADER_STAGE_TESSELLATION_CONTROL => control = entry,
            facet.SHADER_STAGE_TESSELLATION_EVALUATION => evaluation = entry,
            else => return .error_invalid_shader_nv,
        }
    }
    const vertex_entry = vertex orelse return .error_invalid_shader_nv;
    if ((control == null) != (evaluation == null)) return .error_invalid_shader_nv;
    const last_entry = evaluation orelse vertex_entry;
    // A pipeline of no fragment stage, which Vulkan 1.0 allows: it asks
    // for a vertex stage alone (VUID-VkGraphicsPipelineCreateInfo-stage-02096).
    // It is drawn with a function that does nothing, as lavapipe binds
    // `noop_fs` (lvp_device.c:2048-2052, lvp_execute.c:552-554), which
    // reads no varying for the last stage's to agree with (since 1.115).
    const fragment_entry = fragment orelse &no_fragment;
    if (fragment != null and last_entry.varyingCount() != fragment_entry.varyingCount()) return .error_invalid_shader_nv;
    // The fixed form is in the fragment entry's own `varyings` word, which
    // the program wrote: a kind byte that names no form is refused here
    // rather than read as whichever form it lands on (since 1.75).
    const fixed_form = fragment_entry.fixed() orelse return .error_invalid_shader_nv;
    const pass = _objects.of(_render.RenderPass, info.render_pass);
    if (info.subpass >= pass.subpass_count) return .error_initialization_failed;
    const subpass = pass.subpasses[info.subpass];
    // The subpass's colour attachments as Vulkan counts them, those named
    // ATTACHMENT_UNUSED too, which the blend state has an entry for each
    // of (VUID-VkGraphicsPipelineCreateInfo-renderPass-07609, since 1.118).
    const colors = subpass.color_count;
    // The fragment entry says how many colours it writes in the one call
    // (`shader.fragmentOutputs`): the subpass's own count where they go
    // together, and one where they do not - and one in a subpass of
    // none, where what it writes goes nowhere, llvmpipe's blending being
    // a loop over no colour buffer (lp_state_fs.c:3618-3622, since 1.113).
    // The function of no fragment stage has the room of as many as the
    // subpass has, and writes none of them.
    const outputs = if (fragment == null) @max(pass.parts[subpass.first_part].color_count, 1) else fragment_entry.outputCount();
    if (outputs != @max(pass.parts[subpass.first_part].color_count, 1)) return .error_invalid_shader_nv;
    if (outputs > 1 and !device.physical.can.several_outputs) return .error_feature_not_present;

    made.* = .{
        .device = device,
        .vertex = @ptrCast(@alignCast(vertex_entry.function)),
        .fragment = @ptrCast(@alignCast(fragment_entry.function)),
        .fixed = fixed_form,
        .fragment_words = fragment_words,
        // What is drawn carries, which with tessellation is the
        // evaluation function's output and not the vertex function's: the
        // patch's own vertices are as wide as `Tessellated.vertex_varyings`
        // says instead.
        .varyings = last_entry.varyingCount(),
        .locations = 0,
        .bindings = @splat(.{}),
        .attributes = undefined,
        .attribute_count = 0,
        .topology = .triangle_list,
        .drawn_topology = .triangle_list,
        .restart = false,
        .draws_nothing = false,
        .culls_everything = false,
        .sample_mask = ~@as(u32, 0),
        .cull = .none,
        .front = .counter_clockwise,
        .depth_test = null,
        .depth_write = false,
        .biased = false,
        .bias = null,
        .prepass = info.flags & facet.PIPELINE_CREATE_DEPTH_PREPASS != 0 and !fixed_form.discards(),
        .stencil = null,
        .dynamic_stencil_compare = false,
        .dynamic_stencil_write = false,
        .dynamic_stencil_reference = false,
        .polygon_mode = .fill,
        .line_width = 1,
        .mixings = @splat(.{}),
        .outputs = outputs,
        .viewport = null,
        .scissor = null,
    };

    // The vertex input.
    var given_bindings: u32 = 0;
    if (info.vertex_input_state) |input| {
        if (input.vertex_binding_descriptions) |bindings| for (bindings[0..input.vertex_binding_description_count]) |binding| {
            if (binding.binding >= _instance.max_vertex_input_bindings or binding.stride > 2048) return .error_feature_not_present;
            made.bindings[binding.binding] = .{ .stride = binding.stride, .per_instance = binding.input_rate == .instance };
            given_bindings |= @as(u32, 1) << @intCast(binding.binding);
        };
        if (input.vertex_attribute_descriptions) |attributes| for (attributes[0..input.vertex_attribute_description_count]) |attribute| {
            if (made.attribute_count == _instance.max_vertex_input_attributes or attribute.location >= _instance.max_vertex_input_attributes) return .error_feature_not_present;
            if (!_pipeline.attributeFormat(attribute.format)) return .error_format_not_supported;
            if (attribute.binding >= _instance.max_vertex_input_bindings or given_bindings >> @intCast(attribute.binding) & 1 == 0) return .error_initialization_failed;
            made.attributes[made.attribute_count] = .{ .location = attribute.location, .binding = attribute.binding, .format = attribute.format, .offset = attribute.offset };
            made.attribute_count += 1;
            made.locations = @max(made.locations, attribute.location + 1);
        };
    }
    if (info.input_assembly_state) |assembly| {
        switch (assembly.topology) {
            .point_list, .line_list, .line_strip, .triangle_list, .triangle_strip, .triangle_fan, .patch_list => made.topology = assembly.topology,
            else => return .error_feature_not_present,
        }
        made.restart = assembly.primitive_restart_enable;
    }
    made.drawn_topology = made.topology;
    if (evaluation) |entry| {
        const state = info.tessellation_state orelse return .error_initialization_failed;
        if (made.topology != .patch_list or state.patch_control_points == 0 or state.patch_control_points > _instance.max_patch_points) return .error_initialization_failed;
        const way = entry.tessellation() orelse return .error_invalid_shader_nv;
        // What the control function writes for the whole patch (since
        // 1.50): its entry's own count, held to the limit.
        const own = control.?.varyingCount();
        if (own > _instance.max_tessellation_patch_components) return .error_feature_not_present;
        made.tessellated = .{
            .control = @ptrCast(@alignCast(control.?.function)),
            .evaluation = @ptrCast(@alignCast(entry.function)),
            .way = way,
            .points = state.patch_control_points,
            .vertex_varyings = vertex_entry.varyingCount(),
            .own = own,
        };
        made.drawn_topology = if (way.domain == .isolines) .line_list else .triangle_list;
    } else if (made.topology == .patch_list) return .error_initialization_failed;

    // The rasterization.
    const rasterization = info.rasterization_state;
    if (rasterization.depth_clamp_enable) {
        if (!device.physical.can.depth_clamp) return .error_feature_not_present;
        made.clamped = true;
    }
    if (rasterization.depth_bias_enable) {
        if (!device.physical.can.depth_bias) return .error_feature_not_present;
        made.biased = true;
        made.bias = .{
            .constant = rasterization.depth_bias_constant_factor,
            .clamp = rasterization.depth_bias_clamp,
            .slope = rasterization.depth_bias_slope_factor,
        };
    }
    switch (rasterization.polygon_mode) {
        .fill, .line, .point => made.polygon_mode = rasterization.polygon_mode,
        else => return .error_feature_not_present,
    }
    made.line_width = rasterization.line_width;
    made.front = if (rasterization.front_face == .clockwise) .clockwise else .counter_clockwise;
    switch (rasterization.cull_mode) {
        facet.CULL_MODE_NONE => made.cull = .none,
        facet.CULL_MODE_FRONT => made.cull = .front,
        facet.CULL_MODE_BACK => made.cull = .back,
        // Every face: which lines and points have none of, so it culls
        // none of them - Vulkan culls polygons, and llvmpipe's
        // `triangle_noop` takes the place of its triangle function alone.
        // Until 1.92 this drew no line and no point either.
        else => switch (made.drawn_topology) {
            .point_list, .line_list, .line_strip => {},
            else => {
                made.draws_nothing = true;
                made.culls_everything = true;
            },
        },
    }
    // Discarded before clipping, which nothing then counts.
    if (rasterization.rasterizer_discard_enable) {
        made.draws_nothing = true;
        made.culls_everything = false;
    }
    if (info.multisample_state) |multisample| {
        if (multisample.sample_shading_enable or multisample.alpha_to_one_enable) return .error_feature_not_present;
        // It drops samples after the fragment function, as a form that
        // drops pixels does, so it has no depth pre-pass (since 1.108).
        // Not where there is no fragment stage: llvmpipe takes the alpha
        // of colour 0 where the shader writes it and leaves the coverage
        // as it is otherwise (lp_state_fs.c:1181-1185, since 1.115).
        if (multisample.alpha_to_coverage_enable and fragment != null) {
            made.alpha_to_coverage = true;
            made.prepass = false;
        }
        // Four samples a pixel where the device draws them, and the
        // subpass's own count whatever it is (since 1.100):
        // VUID-VkGraphicsPipelineCreateInfo-multisampledRenderToSingleSampled-06853.
        const samples = multisample.rasterization_samples;
        if (samples != 1 and !(samples == 4 and device.physical.can.multisampling)) return .error_feature_not_present;
        // A subpass of no attachment has no count of its own: it draws at
        // its pipelines', one of `framebuffer_no_attachments_sample_counts`
        // (VUID-VkGraphicsPipelineCreateInfo-subpass-00758, since 1.114).
        const first = pass.parts[subpass.first_part];
        const no_attachment = first.color_count == 0 and first.depth == null;
        if (!no_attachment and samples != first.samples) return .error_initialization_failed;
        made.samples = samples;
        // One word of the mask, which at one sample a pixel is one bit of
        // it: `PhysicalDeviceLimits.max_sample_mask_words` is 1 and Vulkan
        // ignores the bits above the sample count. A null pointer is every
        // sample covered, which is what the field is initialised to. The
        // word is copied here because `sample_mask` need not outlive the
        // call. (Since 1.89, item 61 of docs/facet-vulkan10.md.)
        if (multisample.sample_mask) |mask| made.sample_mask = mask[0];
    }
    if (info.depth_stencil_state) |depth| {
        if (depth.depth_bounds_test_enable) {
            if (!device.physical.can.depth_bounds) return .error_feature_not_present;
            made.bounded = true;
            made.bounds = .{ depth.min_depth_bounds, depth.max_depth_bounds };
        }
        if (depth.stencil_test_enable) {
            var faces: [2]_pipeline.StencilFace = undefined;
            for ([2]facet.StencilOpState{ depth.front, depth.back }, &faces) |state, *face| {
                if (@intFromEnum(state.compare_op) > 7) return .error_initialization_failed;
                for ([3]facet.StencilOp{ state.fail_op, state.pass_op, state.depth_fail_op }) |op| {
                    if (@intFromEnum(op) > 7) return .error_initialization_failed;
                }
                face.* = .{
                    .fail = state.fail_op,
                    .pass = state.pass_op,
                    .depth_fail = state.depth_fail_op,
                    .compare = state.compare_op,
                    .compare_mask = @truncate(state.compare_mask),
                    .write_mask = @truncate(state.write_mask),
                    .reference = @truncate(state.reference),
                };
            }
            made.stencil = faces;
        }
        if (depth.depth_test_enable) {
            if (@intFromEnum(depth.depth_compare_op) > 7) return .error_initialization_failed;
            made.depth_test = depth.depth_compare_op;
            made.depth_write = depth.depth_write_enable;
        }
    }
    if (info.color_blend_state) |blend| {
        if (blend.logic_op_enable) return .error_feature_not_present;
        if (blend.attachment_count != 0 and blend.attachment_count != colors) return .error_initialization_failed;
        // A device without `independent_blend` wants them all alike, and
        // says so rather than drawing what was not asked for.
        if (blend.attachment_count > 1 and !device.physical.can.independent_blend) {
            for (blend.attachments.?[1..blend.attachment_count]) |other| {
                if (!std.mem.eql(u8, std.mem.asBytes(&other), std.mem.asBytes(&blend.attachments.?[0]))) return .error_feature_not_present;
            }
        }
        // One for each colour attachment of the subpass, each its own way:
        // an attachment is a pass of its own, drawn with its own mixing.
        if (blend.attachment_count != 0) for (blend.attachments.?[0..blend.attachment_count], 0..) |attachment, index| {
            const mixing = &made.mixings[index];
            mixing.mask = attachment.color_write_mask & facet.COLOR_COMPONENT_ALL;
            if (attachment.blend_enable) {
                const factors = [4]facet.BlendFactor{ attachment.src_color_blend_factor, attachment.dst_color_blend_factor, attachment.src_alpha_blend_factor, attachment.dst_alpha_blend_factor };
                for (factors) |factor| if (@intFromEnum(factor) > @intFromEnum(facet.BlendFactor.src_alpha_saturate)) return .error_feature_not_present;
                if (@intFromEnum(attachment.color_blend_op) > @intFromEnum(facet.BlendOp.max) or @intFromEnum(attachment.alpha_blend_op) > @intFromEnum(facet.BlendOp.max)) return .error_feature_not_present;
                mixing.enabled = true;
                mixing.src_color = factors[0];
                mixing.dst_color = factors[1];
                mixing.color_op = attachment.color_blend_op;
                mixing.src_alpha = factors[2];
                mixing.dst_alpha = factors[3];
                mixing.alpha_op = attachment.alpha_blend_op;
            }
        };
        // The constants are the pipeline's, shared by all of them - or
        // one set for each attachment, which is facet.library's own
        // (since 1.51).
        for (&made.mixings) |*mixing| mixing.constants = blend.blend_constants;
        if (blend.attachment_constants) |given| {
            const count = if (blend.attachment_count != 0) blend.attachment_count else colors;
            if (count > _render.most_colors) return .error_initialization_failed;
            for (given[0..count], made.mixings[0..count]) |constants, *mixing| mixing.constants = constants;
        }
    }
    // What a pipeline of no fragment stage writes into a colour attachment
    // Vulkan leaves undefined ("undefined values may be written to all
    // color attachment outputs", *Fragment Shading*): here nothing, each
    // attachment keeping what it held (since 1.115).
    if (fragment == null) for (&made.mixings) |*mixing| {
        mixing.mask = 0;
    };

    // The viewport and the scissor, unless commands set them.
    var dynamic_viewport = false;
    var dynamic_scissor = false;
    if (info.dynamic_state) |dynamic| {
        if (dynamic.dynamic_states) |states| for (states[0..dynamic.dynamic_state_count]) |state| switch (state) {
            .viewport => dynamic_viewport = true,
            .scissor => dynamic_scissor = true,
            .blend_constants => for (&made.mixings) |*mixing| {
                mixing.constants = null;
            },
            .line_width => made.line_width = null,
            .depth_bias => made.bias = null,
            .depth_bounds => made.bounds = null,
            .stencil_compare_mask => made.dynamic_stencil_compare = true,
            .stencil_write_mask => made.dynamic_stencil_write = true,
            .stencil_reference => made.dynamic_stencil_reference = true,
            else => {},
        };
    }
    if (!dynamic_viewport or !dynamic_scissor) {
        const view = info.viewport_state orelse return .error_initialization_failed;
        if (view.viewport_count != 1 or view.scissor_count != 1) return .error_feature_not_present;
        if (!dynamic_viewport) made.viewport = (view.viewports orelse return .error_initialization_failed)[0];
        if (!dynamic_scissor) made.scissor = (view.scissors orelse return .error_initialization_failed)[0];
    }
    return .success;
}
