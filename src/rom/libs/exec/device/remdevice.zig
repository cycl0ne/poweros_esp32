// SPDX-License-Identifier: MPL-2.0
//! RemDevice: asks a device to expunge itself. The device's own Expunge
//! decides - it takes itself off the list when nobody has it open, and
//! otherwise marks itself to go at the last close.

const sdk = @import("sdk");
const _library = @import("../library/_library.zig");

const ExecBase = @import("../exec.zig").ExecBase;
const Device = sdk.exec.Device;

/// Asks a device to go away, through its own Expunge vector.
///
/// SYNOPSIS:
/// ```zig
/// fn RemDevice(base: *ExecBase, dev: *Device) ?*anyopaque
/// ```
///
/// SINCE: 1.0. LVO -316.
///
/// INPUTS:
/// - `dev` - a device on the device list.
///
/// RESULT:
/// What the Expunge vector answered: null, or the seglist of a loaded
/// module the caller should unload.
///
/// BEHAVIOR:
/// As `RemLibrary`: it asks rather than tells, inside the device's own
/// lock. A device with anything open marks itself and goes on its last
/// `CloseDevice`; one nobody has open is marked going and its vector runs
/// with nothing held. A device in the ROM keeps itself, which is read from
/// it still being on the list.
///
/// CONTEXT:
/// - Waits: for the device's lock and exec's library list while others
///   hold them; and the vector may close what it opened.
/// - Interrupts: no. It takes semaphores.
/// - Locks: takes the device's own lock and exec's library list, both
///   semaphores; no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// If the device went, its memory is gone. A non-null result is a seglist
/// the caller now owns.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddDevice`, `CloseDevice`, `RemLibrary`
///
/// EXAMPLES:
/// ```zig
/// _ = sys.RemDevice(dev);
/// ```
pub fn RemDevice(base: *ExecBase, dev: *Device) ?*anyopaque {
    base.iface().ObtainSemaphore(&dev.lock);
    return _library.expungeHeld(base, dev, &base.device_list).seg_list;
}
