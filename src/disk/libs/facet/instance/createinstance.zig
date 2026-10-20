// SPDX-License-Identifier: MIT
//! CreateInstance: a program's hold on the library.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const facet_init = @import("../facet_init.zig");
const _objects = @import("../_objects.zig");
const _instance = @import("_instance.zig");
const Instance = _instance.Instance;

/// A program's hold on the library, through which it finds the devices.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateInstance(base: *FacetBase, info: *const facet.InstanceCreateInfo, instance: *?*facet.Instance) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -20.
///
/// INPUTS:
/// - `info` - what the program is, and the interface it was written for
///   (`api_version`).
/// - `instance` - where the instance is written; null when it fails.
///
/// RESULT:
/// `success`; `error_initialization_failed` for an interface newer than
/// the library's; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The instance's one physical device is described as it is made: the
/// cores it draws on are counted, and its memory types made from the
/// regions exec has (GetPhysicalDeviceMemoryProperties). A region added
/// later is in the memory types of an instance made after it.
///
/// While an instance lasts the library stays loaded, even after the
/// program has closed it: its queues' tasks run the library's code.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: exec's memory list, for a moment.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The instance is the caller's, until DestroyInstance.
///
/// NOTES:
/// A program has one instance, as a rule; it may have more, each with
/// devices of its own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroyInstance`, `EnumeratePhysicalDevices`
///
/// EXAMPLES:
/// ```zig
/// var instance: ?*facet.Instance = null;
/// if (fb.CreateInstance(&.{ .application_name = "Cube" }, &instance) != .success) return error.NoInstance;
/// defer fb.DestroyInstance(instance);
/// ```
pub fn CreateInstance(base: *FacetBase, info: *const facet.InstanceCreateInfo, instance: *?*facet.Instance) facet.Result {
    instance.* = null;
    const wanted = if (info.api_version == 0) facet.API_VERSION_1_0 else info.api_version;
    if (wanted > facet.makeVersion(facet_init.LIBRARY_VERSION, facet_init.LIBRARY_REVISION)) return .error_initialization_failed;
    const sys = base.sys_base;
    const made = _objects.create(sys, Instance) orelse return .error_out_of_host_memory;
    made.* = .{ .base = base, .physical = undefined };
    _instance.describe(sys, made);
    _ = @atomicRmw(u32, &base.instances, .Add, 1, .monotonic);
    instance.* = _objects.handle(facet.Instance, made);
    return .success;
}
