// SPDX-License-Identifier: MIT
//! CreateComputePipelines: functions run by CmdDispatch.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const shader = facet.shader;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const Pipeline = @import("_pipeline.zig").Pipeline;
const _shader = @import("../shader/_shader.zig");

/// `count` compute pipelines, one for each of `infos`, into `pipelines`.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateComputePipelines(base: *FacetBase, device: *facet.Device, cache: ?*facet.PipelineCache, count: u32, infos: [*]const facet.ComputePipelineCreateInfo, pipelines: [*]?*facet.Pipeline) facet.Result
/// ```
///
/// SINCE: 1.18. LVO -416.
///
/// INPUTS:
/// - `device` - the device.
/// - `cache` - null: facet.library has no pipeline caches.
/// - `count`, `infos` - each pipeline's function, of stage
///   SHADER_STAGE_COMPUTE, and layout.
/// - `pipelines` - where each is written; null for one that could not be
///   made.
///
/// RESULT:
/// `success`; else what the first that could not be made came to:
/// `error_invalid_shader_nv` for a stage that is not of a compute function
/// the module has; `error_out_of_host_memory`. Those made are made either
/// way.
///
/// BEHAVIOR:
/// A compute function runs on the cores, whichever device it was made on: a
/// CM5's V3D runs no program of the library's but its fragment programs.
///
/// CONTEXT:
/// - Waits: yes, for memory.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pipeline is the caller's, given back by DestroyPipeline. The module
/// may go once it is made, not the function it names.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdDispatch`, `CmdBindPipeline`, `shader.compute`
///
/// EXAMPLES:
/// ```zig
/// const info = facet.ComputePipelineCreateInfo{ .stage = .{ .stage = facet.SHADER_STAGE_COMPUTE, .module = module.? }, .layout = layout.? };
/// var pipeline: [1]?*facet.Pipeline = undefined;
/// if (fb.CreateComputePipelines(device, null, 1, @ptrCast(&info), &pipeline) != .success) return error.NoPipeline;
/// ```
pub fn CreateComputePipelines(base: *FacetBase, device: *facet.Device, cache: ?*facet.PipelineCache, count: u32, infos: [*]const facet.ComputePipelineCreateInfo, pipelines: [*]?*facet.Pipeline) facet.Result {
    _ = cache;
    const owner = _objects.of(Device, device);
    var result: facet.Result = .success;
    for (infos[0..count], pipelines[0..count]) |*info, *pipeline| {
        pipeline.* = null;
        const module = _objects.of(_shader.ShaderModule, info.stage.module);
        const entry = (if (info.stage.stage == facet.SHADER_STAGE_COMPUTE) _shader.find(module, facet.SHADER_STAGE_COMPUTE, info.stage.name) else null) orelse {
            if (result == .success) result = .error_invalid_shader_nv;
            continue;
        };
        const made = _objects.create(base.sys_base, Pipeline) orelse {
            if (result == .success) result = .error_out_of_host_memory;
            continue;
        };
        made.device = owner;
        made.driver = null;
        made.compute = @ptrCast(@alignCast(entry.function));
        pipeline.* = _objects.handle(facet.Pipeline, made);
    }
    return result;
}
