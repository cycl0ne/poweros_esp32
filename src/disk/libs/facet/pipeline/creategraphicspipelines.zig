// SPDX-License-Identifier: MIT
//! CreateGraphicsPipelines: ways of drawing.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const shader = facet.shader;
const _objects = @import("../_objects.zig");
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
/// fragment function of the same varyings; `error_feature_not_present`
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
/// code for its depth test and blend is chosen then, not as it draws.
///
/// What it draws: triangle lists, strips and fans, a restart index ending a
/// strip or a fan; filled, one sample a pixel, culled by facing as asked; a
/// depth test of any compare, written or not, without stencil, bounds,
/// bias or clamp; the colour written whole, replacing what is there, or
/// laid over it by its alpha - SRC_ALPHA and ONE_MINUS_SRC_ALPHA, ADD - and
/// no logic op; one viewport and one scissor, given here or set by
/// CmdSetViewport and CmdSetScissor (DynamicState viewport and scissor;
/// the others are taken and do nothing). A pipeline with the rasterizer
/// discarding, or culling front and back, draws nothing.
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
/// it.
///
/// BUGS:
/// Blending lays the alpha over the attachment's as it does the colour,
/// whatever the alpha's blend factors say.
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
        pipeline.* = _objects.handle(facet.Pipeline, made);
    }
    return result;
}

/// `made` filled in from `info`: what it came to.
fn settle(made: *Pipeline, device: *Device, info: *const facet.GraphicsPipelineCreateInfo) facet.Result {
    // The functions.
    var vertex: ?*const shader.Entry = null;
    var fragment: ?*const shader.Entry = null;
    for (info.stages[0..info.stage_count]) |stage| {
        const module = _objects.of(_shader.ShaderModule, stage.module);
        const entry = _shader.find(module, stage.stage, stage.name) orelse return .error_invalid_shader_nv;
        switch (stage.stage) {
            facet.SHADER_STAGE_VERTEX => vertex = entry,
            facet.SHADER_STAGE_FRAGMENT => fragment = entry,
            else => return .error_invalid_shader_nv,
        }
    }
    const vertex_entry = vertex orelse return .error_invalid_shader_nv;
    const fragment_entry = fragment orelse return .error_invalid_shader_nv;
    if (vertex_entry.varyings != fragment_entry.varyings) return .error_invalid_shader_nv;
    if (info.subpass != 0) return .error_initialization_failed;

    made.* = .{
        .device = device,
        .vertex = @ptrCast(@alignCast(vertex_entry.function)),
        .fragment = @ptrCast(@alignCast(fragment_entry.function)),
        .varyings = vertex_entry.varyings,
        .locations = 0,
        .bindings = @splat(.{}),
        .attributes = undefined,
        .attribute_count = 0,
        .topology = .triangle_list,
        .restart = false,
        .draws_nothing = false,
        .cull = .none,
        .front = .counter_clockwise,
        .depth_test = null,
        .depth_write = false,
        .blend = .off,
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
            .triangle_list, .triangle_strip, .triangle_fan => made.topology = assembly.topology,
            else => return .error_feature_not_present,
        }
        made.restart = assembly.primitive_restart_enable;
    }
    if (info.tessellation_state != null) return .error_feature_not_present;

    // The rasterization.
    const rasterization = info.rasterization_state;
    if (rasterization.polygon_mode != .fill or rasterization.depth_clamp_enable or rasterization.depth_bias_enable) return .error_feature_not_present;
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
        if (depth.stencil_test_enable or depth.depth_bounds_test_enable) return .error_feature_not_present;
        if (depth.depth_test_enable) {
            const compare = @intFromEnum(depth.depth_compare_op);
            if (compare > 7) return .error_initialization_failed;
            made.depth_test = @enumFromInt(compare);
            made.depth_write = depth.depth_write_enable;
        }
    }
    if (info.color_blend_state) |blend| {
        if (blend.logic_op_enable or blend.attachment_count > 1) return .error_feature_not_present;
        if (blend.attachment_count == 1) {
            const attachment = blend.attachments.?[0];
            if (attachment.color_write_mask & facet.COLOR_COMPONENT_ALL != facet.COLOR_COMPONENT_ALL) return .error_feature_not_present;
            if (attachment.blend_enable) {
                if (attachment.src_color_blend_factor != .src_alpha or attachment.dst_color_blend_factor != .one_minus_src_alpha or attachment.color_blend_op != .add or attachment.alpha_blend_op != .add) return .error_feature_not_present;
                made.blend = .alpha;
            }
        }
    }

    // The viewport and the scissor, unless commands set them.
    var dynamic_viewport = false;
    var dynamic_scissor = false;
    if (info.dynamic_state) |dynamic| {
        if (dynamic.dynamic_states) |states| for (states[0..dynamic.dynamic_state_count]) |state| switch (state) {
            .viewport => dynamic_viewport = true,
            .scissor => dynamic_scissor = true,
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
