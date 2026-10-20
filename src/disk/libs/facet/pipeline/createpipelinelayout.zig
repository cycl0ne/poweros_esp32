// SPDX-License-Identifier: MIT
//! CreatePipelineLayout: what a pipeline's shaders read.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const shader = facet.shader;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const PipelineLayout = @import("_pipeline.zig").PipelineLayout;

/// A pipeline layout: the descriptor sets and the push constants a pipeline's shaders read.
///
/// SYNOPSIS:
/// ```zig
/// fn CreatePipelineLayout(base: *FacetBase, device: *facet.Device, info: *const facet.PipelineLayoutCreateInfo, layout: *?*facet.PipelineLayout) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -236.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - a set layout for each set from 0, and the ranges of push
///   constants.
/// - `layout` - where the layout is written; null when it fails.
///
/// RESULT:
/// `success`; `error_feature_not_present` for more than four sets, or
/// push constants past 128 bytes; `error_initialization_failed` for a range
/// not on 4 bytes; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// A shader reads set `n` as `Resources.sets[n]` and the push constants
/// as `Resources.push`, from byte 0, whatever the stages.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The layout is the caller's, until DestroyPipelineLayout. The set
/// layouts may go before it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateDescriptorSetLayout`, `CreateGraphicsPipelines`, `CmdBindDescriptorSets`, `CmdPushConstants`
///
/// EXAMPLES:
/// ```zig
/// const push = facet.PushConstantRange{ .stage_flags = facet.SHADER_STAGE_VERTEX, .size = 64 };
/// var layout: ?*facet.PipelineLayout = null;
/// _ = fb.CreatePipelineLayout(device, &.{ .set_layout_count = 1, .set_layouts = @ptrCast(&set_layout), .push_constant_range_count = 1, .push_constant_ranges = @ptrCast(&push) }, &layout);
/// ```
pub fn CreatePipelineLayout(base: *FacetBase, device: *facet.Device, info: *const facet.PipelineLayoutCreateInfo, layout: *?*facet.PipelineLayout) facet.Result {
    layout.* = null;
    const owner = _objects.of(Device, device);
    if (info.set_layout_count > shader.MAX_SETS) return .error_feature_not_present;
    var push_size: u32 = 0;
    if (info.push_constant_ranges) |ranges| for (ranges[0..info.push_constant_range_count]) |range| {
        if (range.offset % 4 != 0 or range.size % 4 != 0 or range.size == 0) return .error_initialization_failed;
        if (range.offset > shader.MAX_PUSH_CONSTANTS_SIZE or range.size > shader.MAX_PUSH_CONSTANTS_SIZE - range.offset) return .error_feature_not_present;
        push_size = @max(push_size, range.offset + range.size);
    };
    const made = _objects.create(base.sys_base, PipelineLayout) orelse return .error_out_of_host_memory;
    made.* = .{ .device = owner, .set_count = info.set_layout_count, .push_size = push_size };
    layout.* = _objects.handle(facet.PipelineLayout, made);
    return .success;
}
