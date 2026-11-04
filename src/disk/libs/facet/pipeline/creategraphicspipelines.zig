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
/// `error_invalid_shader_nv` for stages that are not one vertex and one
/// fragment function of the same varyings, with or without a tessellation
/// control and evaluation function, whose varyings then the fragment
/// function's have to be; `error_feature_not_present`
/// for state facet.library does not draw (see BEHAVIOR);
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
/// With tessellation functions, the topology is `patch_list` and the
/// `tessellation_state` says the vertices of a patch, 1 to 32: the cores make
/// each patch into triangles or lines (`shader.Tessellation`), for a device
/// with a processor of its own too, and those are drawn; without them,
/// `patch_list` is `error_initialization_failed`.
///
/// What it draws: points, lines and line strips, and triangle lists, strips
/// and fans, a restart index ending a strip or a fan; triangles filled, or as
/// their edges or corners (POLYGON_MODE_LINE, POINT); one sample a pixel,
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
/// one of the fixed forms (`shader.fixedFragment`), or the pipeline is
/// refused with `error_feature_not_present`; the cores, always the first
/// device listed, take any.
///
/// Attributes are read as floats - r32_sfloat to r32g32b32a32_sfloat - or
/// as bytes 0 to 1, r8g8b8a8_unorm and b8g8r8a8_unorm, into four floats
/// each, up to four bindings and eight locations.
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
/// `PhysicalDeviceFeatures.depth_bias` is true (since 1.34).
///
/// `depth_clamp_enable` draws what lies past the near plane instead of
/// cutting it away, each pixel's depth held inside the viewport's
/// `min_depth` and `max_depth` - which is what a shadow volume wants - and
/// `depth_bounds_test_enable` draws a pixel only where the depth
/// **already** in the attachment lies between `min_depth_bounds` and
/// `max_depth_bounds`, whatever the depth being drawn; `DynamicState`'s
/// `depth_bounds` leaves the two to CmdSetDepthBounds. Both want a device
/// whose `PhysicalDeviceFeatures.depth_clamp` or `depth_bounds` is true -
/// every device since 1.47, the V3D's own configuration having both - and
/// on the cores both have a draw's pixels walked one at a time, as a
/// stencil test does, so they cost more there than the quads the fast
/// paths walk.
///
/// On an attachment without alpha, R5G6B5, what is there reads as wholly
/// opaque. `color_blend_state.attachments` holds one state for each colour
/// attachment of the subpass, or none for the default over all of them; a
/// subpass of several has each blended its own way (since 1.33,
/// `PhysicalDeviceFeatures.independent_blend`), the blend constants being
/// the pipeline's and shared. On the cores, SRC_ALPHA and ONE_MINUS_SRC_ALPHA or ONE, with
/// the alpha's factors the same or ZERO and ONE and the mask whole, cost
/// less than any other mixing.
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

/// `made` filled in from `info`: what it came to.
fn settle(made: *Pipeline, device: *Device, info: *const facet.GraphicsPipelineCreateInfo) facet.Result {
    // The functions.
    var vertex: ?*const shader.Entry = null;
    var fragment: ?*const shader.Entry = null;
    var control: ?*const shader.Entry = null;
    var evaluation: ?*const shader.Entry = null;
    for (info.stages[0..info.stage_count]) |stage| {
        const module = _objects.of(_shader.ShaderModule, stage.module);
        const entry = _shader.find(module, stage.stage, stage.name) orelse return .error_invalid_shader_nv;
        switch (stage.stage) {
            facet.SHADER_STAGE_VERTEX => vertex = entry,
            facet.SHADER_STAGE_FRAGMENT => fragment = entry,
            facet.SHADER_STAGE_TESSELLATION_CONTROL => control = entry,
            facet.SHADER_STAGE_TESSELLATION_EVALUATION => evaluation = entry,
            else => return .error_invalid_shader_nv,
        }
    }
    const vertex_entry = vertex orelse return .error_invalid_shader_nv;
    const fragment_entry = fragment orelse return .error_invalid_shader_nv;
    if ((control == null) != (evaluation == null)) return .error_invalid_shader_nv;
    const last_entry = evaluation orelse vertex_entry;
    if (last_entry.varyingCount() != fragment_entry.varyingCount()) return .error_invalid_shader_nv;
    const pass = _objects.of(_render.RenderPass, info.render_pass);
    if (info.subpass >= pass.subpass_count) return .error_initialization_failed;
    const colors = pass.subpasses[info.subpass].part_count;

    made.* = .{
        .device = device,
        .vertex = @ptrCast(@alignCast(vertex_entry.function)),
        .fragment = @ptrCast(@alignCast(fragment_entry.function)),
        .fixed = fragment_entry.fixed(),
        .varyings = vertex_entry.varyingCount(),
        .locations = 0,
        .bindings = @splat(.{}),
        .attributes = undefined,
        .attribute_count = 0,
        .topology = .triangle_list,
        .drawn_topology = .triangle_list,
        .restart = false,
        .draws_nothing = false,
        .cull = .none,
        .front = .counter_clockwise,
        .depth_test = null,
        .depth_write = false,
        .biased = false,
        .bias = null,
        .prepass = info.flags & facet.PIPELINE_CREATE_DEPTH_PREPASS != 0 and !fragment_entry.fixed().discards(),
        .stencil = null,
        .dynamic_stencil_compare = false,
        .dynamic_stencil_write = false,
        .dynamic_stencil_reference = false,
        .polygon_mode = .fill,
        .line_width = 1,
        .mixings = @splat(.{}),
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
        const way = entry.tessellation();
        if (@intFromEnum(way.domain) > @intFromEnum(shader.Domain.isolines)) return .error_invalid_shader_nv;
        made.tessellated = .{
            .control = @ptrCast(@alignCast(control.?.function)),
            .evaluation = @ptrCast(@alignCast(entry.function)),
            .way = way,
            .points = state.patch_control_points,
            .vertex_varyings = vertex_entry.varyingCount(),
        };
        made.drawn_topology = if (way.domain == .isolines) .line_list else .triangle_list;
    } else if (made.topology == .patch_list) return .error_initialization_failed;

    // The rasterization.
    const rasterization = info.rasterization_state;
    if (rasterization.depth_clamp_enable) {
        if (!device.physical.features.depth_clamp) return .error_feature_not_present;
        made.clamped = true;
    }
    if (rasterization.depth_bias_enable) {
        if (!device.physical.features.depth_bias) return .error_feature_not_present;
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
        else => made.draws_nothing = true,
    }
    if (rasterization.rasterizer_discard_enable) made.draws_nothing = true;
    if (info.multisample_state) |multisample| {
        if (multisample.rasterization_samples > 1 or multisample.sample_shading_enable or multisample.alpha_to_coverage_enable or multisample.alpha_to_one_enable) return .error_feature_not_present;
    }
    if (info.depth_stencil_state) |depth| {
        if (depth.depth_bounds_test_enable) {
            if (!device.physical.features.depth_bounds) return .error_feature_not_present;
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
        if (blend.attachment_count > 1 and !device.physical.features.independent_blend) {
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
        // The constants are the pipeline's, shared by all of them.
        for (&made.mixings) |*mixing| mixing.constants = blend.blend_constants;
    }

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
