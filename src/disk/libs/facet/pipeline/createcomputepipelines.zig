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
/// - `cache` - a pipeline cache, or null; it holds no pipeline, and
///   nothing is looked up in it or put into it (since 1.130).
/// - `count`, `infos` - each pipeline's function, of stage
///   SHADER_STAGE_COMPUTE, and layout. The function's own entry says what a
///   group of it holds: its invocations and the bytes they share
///   (`shader.computeGroup`).
/// - `pipelines` - where each is written; null for one that could not be
///   made.
///
/// RESULT:
/// `success`; else what the first that could not be made came to:
/// `error_invalid_shader_nv` for a stage that is not of a compute function
/// the module has; `error_validation_failed` for a workgroup over the
/// device's limits (VUID-RuntimeSpirv-x-06429, -y-06430, -z-06431,
/// -x-06432, -Workgroup-06530; `error_feature_not_present` until 1.133);
/// `error_feature_not_present` for a stage whose `specialization_info`
/// names a constant (since 1.80); `error_out_of_host_memory`, and
/// `error_out_of_device_memory` where the device found no memory for its
/// program (since 1.195). Those made are made either way.
///
/// BEHAVIOR:
/// A compute function runs on the cores, whichever device it was made on,
/// unless the device compiles the SPIR-V the module shipped beside it: a
/// CM5's V3D runs a compute shader it makes code of on its QPUs, through
/// its compute shader dispatcher, and the function of one it does not -
/// past 256 invocations a group, of Workgroup memory, of a barrier - on
/// the cores (since 1.195).
///
/// A group of more than one invocation is still one call of the function:
/// what the pipeline carries from the entry is the group's size and the bytes
/// its invocations share, which CmdDispatch hands the function
/// (`shader.Groups.local`, `shader.Groups.shared`) for it to make the
/// invocations itself. A group over `PhysicalDeviceLimits`'
/// `max_compute_work_group_size` along an axis, or holding more invocations
/// than `max_compute_work_group_invocations`, or sharing more than
/// `max_compute_shared_memory_size` bytes, is refused here rather than cut
/// to what fits.
///
/// Specialization constants are not honoured: a stage whose
/// `specialization_info` names any (`map_entry_count` above 0) is refused
/// with `error_feature_not_present` rather than made with the constants
/// dropped, which would run what the program did not ask for (since 1.80;
/// before it the pointer was read by nothing and no one was told). A
/// `SpecializationInfo` of no entries specializes nothing, as in Vulkan,
/// and is made: a program that fills the struct for every stage and leaves
/// it empty where it has no constants is not turned away.
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
/// `CmdDispatch`, `CmdBindPipeline`, `shader.compute`, `shader.computeGroup`
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
        // Specialization constants are not honoured, and a pipeline that
        // ran with them dropped would run something the program did not
        // ask for: refused instead (since 1.80). A `SpecializationInfo` of
        // no entries specializes nothing, which is what a program that
        // fills the struct unconditionally gives: that is not refused.
        if (info.stage.specialization_info) |asked| {
            if (asked.map_entry_count != 0) {
                if (result == .success) result = .error_feature_not_present;
                continue;
            }
        }
        const module = _objects.of(_shader.ShaderModule, info.stage.module);
        const at = (if (info.stage.stage == facet.SHADER_STAGE_COMPUTE) _shader.findAt(module, facet.SHADER_STAGE_COMPUTE, info.stage.name) else null) orelse {
            if (result == .success) result = .error_invalid_shader_nv;
            continue;
        };
        const entry = &module.entries()[at];
        // The workgroup the entry declares, as far as this device goes.
        const limits = &owner.physical.properties.limits;
        const local = entry.localSize();
        const shared = entry.sharedBytes();
        const holds = @as(u64, local[0]) * local[1] * local[2];
        const fits = local[0] <= limits.max_compute_work_group_size[0] and
            local[1] <= limits.max_compute_work_group_size[1] and
            local[2] <= limits.max_compute_work_group_size[2] and
            holds <= limits.max_compute_work_group_invocations and
            shared <= limits.max_compute_shared_memory_size;
        if (!fits) {
            if (result == .success) result = .error_validation_failed;
            continue;
        }
        const made = _objects.create(base.sys_base, Pipeline) orelse {
            if (result == .success) result = .error_out_of_host_memory;
            continue;
        };
        made.device = owner;
        made.driver = null;
        made.compute = @ptrCast(@alignCast(entry.function));
        made.local = local;
        made.shared = shared;
        // The words beside the function, which a device that compiles
        // makes its program of (since 1.195).
        made.compute_words = module.wordsAt(at);
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
