// SPDX-License-Identifier: MPL-2.0
//! AddDevice: puts a device on exec's device list, by priority, where
//! `OpenDevice` finds it by name.

const sdk = @import("sdk");
const _library = @import("../library/_library.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Device = sdk.exec.Device;

/// Puts a device on the device list, where `OpenDevice` finds it.
///
/// SYNOPSIS:
/// ```zig
/// fn AddDevice(base: *ExecBase, dev: *Device) void
/// ```
///
/// SINCE: 1.0. LVO -312.
///
/// INPUTS:
/// - `dev` - a built device, with its name, version and priority set.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// As `AddLibrary`, on the device list instead: the node's type becomes a
/// device, it is enqueued by priority, and its jump table is summed.
///
/// The two lists are separate, so a name may be on both - a library and a
/// device of the same name are two different things and neither hides the
/// other.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the list.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. The system holds the pointer until the device
/// expunges.
///
/// NOTES:
/// The jump table is marked changed and summed before the device goes on
/// the list, so a device that asked for a checksum has one from the first
/// moment anyone can open it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemDevice`, `OpenDevice`, `AddLibrary`
///
/// EXAMPLES:
/// ```zig
/// sys.AddDevice(dev);
/// ```
pub fn AddDevice(base: *ExecBase, dev: *Device) void {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    dev.node.type = .device;
    dev.flags |= sdk.exec.LIBF_CHANGED;
    _library.SumLibrary(dev);
    sys.Enqueue(&base.device_list, &dev.node);
}
