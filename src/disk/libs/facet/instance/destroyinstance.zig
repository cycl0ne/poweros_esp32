// SPDX-License-Identifier: MIT
//! DestroyInstance: the program's hold on the library given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Instance = @import("_instance.zig").Instance;

/// The instance given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyInstance(base: *FacetBase, instance: ?*facet.Instance) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `instance` - an instance CreateInstance made, or null, which does
///   nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Every device and surface made from the instance has to be destroyed
/// first. One that is not is left as it is, with the instance under it,
/// and said so on the debug output: a device's queue's task may still be
/// running.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The instance is gone; so are its physical devices.
///
/// NOTES:
/// The library may go once its last instance has: an Expunge it refused
/// while instances lasted is tried again when memory runs short.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateInstance`, `DestroyDevice`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyInstance(instance);
/// ```
pub fn DestroyInstance(base: *FacetBase, instance: ?*facet.Instance) void {
    const made = _objects.of(Instance, instance orelse return);
    const sys = base.sys_base;
    if (made.devices != 0 or made.surfaces != 0) {
        sdk.exec.kprintf(sys, "facet.library: an instance destroyed with %ld devices and %ld surfaces left, kept\n", .{ @as(i64, made.devices), @as(i64, made.surfaces) });
        return;
    }
    _objects.destroy(sys, made);
    _ = @atomicRmw(u32, &base.instances, .Sub, 1, .monotonic);
}
