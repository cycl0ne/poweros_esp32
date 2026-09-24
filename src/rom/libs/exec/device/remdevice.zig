// SPDX-License-Identifier: MPL-2.0
//! RemDevice: asks a device to expunge itself. The device's own Expunge
//! decides - it takes itself off the list when nobody has it open, and
//! otherwise marks itself to go at the last close.

const sdk = @import("sdk");

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
/// As `RemLibrary`: it asks rather than tells. A device with anything open
/// marks itself and goes on its last `CloseDevice`; a device in the ROM
/// keeps itself, which is read from it still being on the list.
///
/// CONTEXT:
/// - Waits: no, and the vector must not either - the low-memory handler
///   reaches this from inside `AllocMem`.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the vector.
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
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    return dev.vector(sdk.exec.ExpungeFn, sdk.exec.LIB_EXPUNGE)(dev);
}
