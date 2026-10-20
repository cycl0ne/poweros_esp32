// SPDX-License-Identifier: MIT
//! DestroyShaderModule: a shader module given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const ShaderModule = @import("_shader.zig").ShaderModule;

/// The shader module given back; the pipelines made from it stay.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyShaderModule(base: *FacetBase, device: *facet.Device, module: ?*facet.ShaderModule) void
/// ```
///
/// SINCE: 1.0. LVO -224.
///
/// INPUTS:
/// - `device` - the device.
/// - `module` - a module CreateShaderModule made, or null, which does
///   nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A pipeline keeps the functions it took from the module.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The module is gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateShaderModule`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyShaderModule(device, module);
/// ```
pub fn DestroyShaderModule(base: *FacetBase, device: *facet.Device, module: ?*facet.ShaderModule) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(ShaderModule, module orelse return));
}
