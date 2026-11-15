// SPDX-License-Identifier: MPL-2.0
//! AddRtgDriver: Put a driver's description on the list.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _driver = @import("_driver.zig");

/// Puts a driver's description on the library's list.
///
/// SYNOPSIS:
/// ```zig
/// fn AddRtgDriver(rb: *RtgBase, spec: *const rtg.RtgDriverSpec, seg_list: ?*anyopaque) ?*rtg.RtgDriver
/// ```
///
/// SINCE: 1.0. LVO -304.
///
/// INPUTS:
/// - `spec` - the driver's description: its name, what it makes and the
///   operations the library calls. It stays where it is and is read there
///   for as long as the driver is on the list.
/// - `seg_list` - the segments of a driver that was loaded from a file,
///   kept in the node; null for one in ROM.
///
/// RESULT:
/// The driver's node, or null: for operations that fill in neither
/// `attach` nor `create_transport`, for a name already on the list, and
/// without memory.
///
/// BEHAVIOR:
/// The library makes the node and, in the same block behind it, the
/// `state_size` bytes the description asks for, cleared; `state` is null
/// for a driver that asks for none. The node carries what a driver needs
/// to work: exec, this library as a driver calls it, and
/// expansion.library where the machine has it. The block is in internal
/// memory for a driver whose interrupts read it
/// (`RTGDF_INTERNAL_INSTANCE`). The list is kept by the descriptions'
/// priority, so of two that name a device as closely the more wanted is
/// asked first. A driver that can take no device and make no bus would
/// sit on the list answering nothing, so it is refused.
///
/// The library calls this itself for every driver in the ROM, at its
/// init; a test calls it for its own driver. No device is offered to the
/// driver by this call: `BindRtgDrivers` offers the ones no driver has.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the driver list.
/// - Interrupts: no. It may wait.
/// - Locks: no spinlock may be held: it waits for a lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The node and the state are the library's, freed by `RemRtgDriver`. The
/// description stays its module's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemRtgDriver`, `BindRtgDrivers`, `GetRtgDrivers`
///
/// EXAMPLES:
/// ```zig
/// const driver = rb.AddRtgDriver(&my_spec, null) orelse return error.DriverRefused;
/// ```
pub fn AddRtgDriver(rb: *RtgBase, spec: *const rtg.RtgDriverSpec, seg_list: ?*anyopaque) ?*rtg.RtgDriver {
    const sys = rb.sys_base;
    // A driver that can take no device and make no bus would sit on the
    // list answering nothing.
    if (spec.ops.attach == null and spec.ops.create_transport == null) return null;

    sys.ObtainSemaphore(&rb.driver_lock);
    defer sys.ReleaseSemaphore(&rb.driver_lock);

    if (sys.FindName(&rb.drivers, spec.name) != null) return null;

    // The node and the driver's state in one block, the state behind the
    // node.
    const memory = sys.AllocVec(_driver.state_offset + spec.state_size, _driver.memoryFor(spec)) orelse return null;
    const private: *_driver.Private = @ptrCast(@alignCast(memory));
    private.* = .{ .driver = .{
        .node = .{ .type = .rtg_driver, .name = spec.name, .pri = spec.priority },
        .spec = spec,
        .sys_base = sys,
        .rtg_base = rb.driverIface(),
        .expansion_base = rb.expansion_base,
        .seg_list = seg_list,
    } };
    const driver = &private.driver;
    if (spec.state_size != 0) driver.state = @as([*]u8, @ptrCast(memory)) + _driver.state_offset;
    sys.Enqueue(&rb.drivers, &driver.node);
    return driver;
}
