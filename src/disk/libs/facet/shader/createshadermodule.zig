// SPDX-License-Identifier: MIT
//! CreateShaderModule: the functions a pipeline's stages run.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const exec = sdk.exec;
const shader = facet.shader;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const ShaderModule = @import("_shader.zig").ShaderModule;
const max_vertex_output_components = @import("../instance/_instance.zig").max_vertex_output_components;

/// A shader module: the vertex and fragment functions a `shader.Code` names.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateShaderModule(base: *FacetBase, device: *facet.Device, info: *const facet.ShaderModuleCreateInfo, module: *?*facet.ShaderModule) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -220.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - `code`, a shader.Code, and its size.
/// - `module` - where the module is written; null when it fails.
///
/// RESULT:
/// `success`; `error_invalid_shader_nv` for code that is not a
/// shader.Code - SPIR-V among it - or an entry of a stage that is neither
/// vertex nor fragment, or with more varyings than a vertex carries;
/// `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The entries are copied. The functions they name are the program's
/// own, compiled into it: CreateGraphicsPipelines takes a pipeline's from
/// them by stage and name.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The module is the caller's, until DestroyShaderModule. The code is
/// read during the call alone; the functions, and the names, have to last
/// as long as the module and the pipelines made from it - as the program's
/// code does.
///
/// NOTES:
/// A shader runs on every core at once and on the queue's task: see
/// sdk.facet.shader for what it may do.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateGraphicsPipelines`, `DestroyShaderModule`
///
/// EXAMPLES:
/// ```zig
/// const entries = [_]facet.shader.Entry{
///     facet.shader.vertex("main", &boxVertex, 2),
///     facet.shader.fragment("main", &boxFragment, 2),
/// };
/// const code = facet.shader.Code{ .entry_count = entries.len, .entries = &entries };
/// var module: ?*facet.ShaderModule = null;
/// _ = fb.CreateShaderModule(device, &.{ .code = &code }, &module);
/// ```
pub fn CreateShaderModule(base: *FacetBase, device: *facet.Device, info: *const facet.ShaderModuleCreateInfo, module: *?*facet.ShaderModule) facet.Result {
    module.* = null;
    const owner = _objects.of(Device, device);
    if (info.code_size < @sizeOf(shader.Code)) return .error_invalid_shader_nv;
    const code: *const shader.Code = @ptrCast(@alignCast(info.code));
    if (code.magic != shader.MAGIC) return .error_invalid_shader_nv;
    const entries = code.entries[0..code.entry_count];
    for (entries) |entry| {
        if (entry.stage != facet.SHADER_STAGE_VERTEX and entry.stage != facet.SHADER_STAGE_FRAGMENT) return .error_invalid_shader_nv;
        if (entry.varyingCount() > max_vertex_output_components) return .error_invalid_shader_nv;
    }
    const memory = base.sys_base.AllocVec(@sizeOf(ShaderModule) + entries.len * @sizeOf(shader.Entry), exec.MEMF_CLEAR) orelse return .error_out_of_host_memory;
    const made: *ShaderModule = @ptrCast(@alignCast(memory));
    made.* = .{ .device = owner, .count = code.entry_count };
    const kept: [*]shader.Entry = @ptrFromInt(@intFromPtr(made) + @sizeOf(ShaderModule));
    @memcpy(kept[0..entries.len], entries);
    module.* = _objects.handle(facet.ShaderModule, made);
    return .success;
}
