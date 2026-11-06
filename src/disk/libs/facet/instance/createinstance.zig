// SPDX-License-Identifier: MIT
//! CreateInstance: a program's hold on the library.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const facet_version = @import("../facet_version.zig");
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
/// `success`; `error_incompatible_driver` for an interface newer than the
/// library's, which is what Vulkan answers where nothing present can
/// provide the version asked for (`error_initialization_failed` before
/// 1.80); `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The instance's physical devices are described as it is made. The first is
/// the cores: those it draws on are counted, and its memory types made from
/// the regions exec has (GetPhysicalDeviceMemoryProperties). A region added
/// later is in the memory types of an instance made after it.
///
/// After them comes a device for each driver module that finds its hardware.
/// The first instance made on a process looks for them in LIBS:facet/, opening
/// each file there as a library; an instance made on a task before that lists
/// only the cores. One built from other source than this library is refused,
/// with a line in the log. They stay open until the library goes.
///
/// While an instance lasts the library stays loaded, even after the
/// program has closed it: its queues' tasks run the library's code.
///
/// CONTEXT:
/// - Waits: the first time on a process, on the disk.
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
    // Vulkan's answer for a version nothing here can provide is
    // INCOMPATIBLE_DRIVER, not INITIALIZATION_FAILED (since 1.80).
    if (wanted > facet.makeVersion(facet_version.LIBRARY_VERSION, facet_version.LIBRARY_REVISION)) return .error_incompatible_driver;
    const sys = base.sys_base;
    const made = _objects.create(sys, Instance) orelse return .error_out_of_host_memory;
    made.* = .{ .base = base, .physicals = undefined };
    _instance.describe(base, made);
    _ = @atomicRmw(u32, &base.instances, .Add, 1, .monotonic);
    instance.* = _objects.handle(facet.Instance, made);
    return .success;
}
