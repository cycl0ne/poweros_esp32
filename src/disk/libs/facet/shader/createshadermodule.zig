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
/// - `info` - `code`, a shader.Code, and its size; `flags`, which with
///   `SHADER_MODULE_CREATE_SPIRV` says the code is a `shader.Module`
///   instead and carries SPIR-V beside the entries (since 1.75).
/// - `module` - where the module is written; null when it fails.
///
/// RESULT:
/// `success`; `error_invalid_shader_nv` for code that is not a
/// shader.Code, or an entry of a stage that is neither vertex nor
/// fragment, or with more varyings than a vertex carries, or - with
/// `SHADER_MODULE_CREATE_SPIRV` - for a `code_size` narrower than a
/// `shader.Module`, a `spirv_count` that is not the entry count, or words
/// that are not SPIR-V at all; `error_out_of_host_memory`. Two stages
/// carry something else in that word: a compute entry its workgroup
/// (`shader.computeGroup`), and a tessellation control entry the floats
/// its patch carries to its evaluation function (`shader.control`, since
/// 1.50). What those may hold is CreateComputePipelines' and
/// CreateGraphicsPipelines' to say.
///
/// BEHAVIOR:
/// The entries are copied. The functions they name are the program's
/// own, compiled into it: CreateGraphicsPipelines takes a pipeline's from
/// them by stage and name.
///
/// With `SHADER_MODULE_CREATE_SPIRV` the code is a `shader.Module`: a
/// `shader.Code` with a second array behind it, one `shader.Spirv` for
/// each entry, holding the SPIR-V of that entry's shader or nothing
/// (since 1.75). The table is copied like the entries; the words
/// themselves stay the program's.
///
/// Those words are looked over here only for what no device could ever
/// run - a header that is not SPIR-V's, a word count that walks off the
/// end, an instruction that is none - and such a module is refused. A
/// module that is merely richer than this device's own format is kept:
/// CreateGraphicsPipelines hands it to the driver, and a driver that
/// cannot make code of it is the one to say so
/// (`error_feature_not_present`). A device without a processor of its own
/// ignores the words and calls the function.
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
/// `CreateGraphicsPipelines`, `DestroyShaderModule`, `sdk.facet.spirv`
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
        switch (entry.stage) {
            facet.SHADER_STAGE_VERTEX, facet.SHADER_STAGE_TESSELLATION_CONTROL, facet.SHADER_STAGE_TESSELLATION_EVALUATION, facet.SHADER_STAGE_FRAGMENT, facet.SHADER_STAGE_COMPUTE => {},
            else => return .error_invalid_shader_nv,
        }
        // A compute entry's word is its workgroup, not varyings: the
        // device's compute limits are what bounds it, which the pipeline
        // sees to (CreateComputePipelines). A tessellation control
        // entry's is the floats its patch carries to its evaluation
        // function (`shader.control`, since 1.50), which
        // CreateGraphicsPipelines holds to
        // `PhysicalDeviceLimits.max_tessellation_patch_components`.
        switch (entry.stage) {
            facet.SHADER_STAGE_COMPUTE, facet.SHADER_STAGE_TESSELLATION_CONTROL => {},
            else => if (entry.varyingCount() > max_vertex_output_components) return .error_invalid_shader_nv,
        }
    }
    // The SPIR-V beside the entries, where the program says it is there
    // (since 1.75). The flag says what the memory holds and `code_size`
    // proves it is that wide, so a program built against an older SDK is
    // never read past its own struct.
    var words: []const shader.Spirv = &.{};
    if (info.flags & facet.SHADER_MODULE_CREATE_SPIRV != 0) {
        if (info.code_size < @sizeOf(shader.Module)) return .error_invalid_shader_nv;
        const wider: *const shader.Module = @ptrCast(@alignCast(info.code));
        // Index for index with the entries, or the library would read
        // past the program's array.
        if (wider.spirv_count != code.entry_count) return .error_invalid_shader_nv;
        words = wider.spirv[0..wider.spirv_count];
        for (words) |each| {
            const given = each.module();
            if (given.len == 0) continue;
            // Two tiers, and this is the first: a module that is not a
            // module is refused here, because no device could run it.
            // One that is merely richer than facet's own format is kept,
            // for a device that may compile it; the driver refuses that
            // as the pipeline is made.
            switch (facet.spirv.look(given, facet.spirv.facet_profile)) {
                .seen => {},
                .fault => |fault| if (fault.malformed()) return .error_invalid_shader_nv,
            }
        }
    }

    const sidecar = if (words.len == 0) 0 else words.len * @sizeOf(shader.Spirv);
    const memory = base.sys_base.AllocVec(@sizeOf(ShaderModule) + entries.len * @sizeOf(shader.Entry) + sidecar, exec.MEMF_CLEAR) orelse return .error_out_of_host_memory;
    const made: *ShaderModule = @ptrCast(@alignCast(memory));
    made.* = .{ .device = owner, .count = code.entry_count, .spirv_count = @intCast(words.len) };
    const kept: [*]shader.Entry = @ptrFromInt(@intFromPtr(made) + @sizeOf(ShaderModule));
    @memcpy(kept[0..entries.len], entries);
    if (words.len != 0) {
        const after: [*]shader.Spirv = @ptrFromInt(@intFromPtr(made) + @sizeOf(ShaderModule) + entries.len * @sizeOf(shader.Entry));
        @memcpy(after[0..words.len], words);
    }
    module.* = _objects.handle(facet.ShaderModule, made);
    return .success;
}
