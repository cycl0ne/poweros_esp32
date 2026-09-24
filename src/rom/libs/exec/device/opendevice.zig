// SPDX-License-Identifier: MPL-2.0
//! OpenDevice: finds a device by name and hands the request to the
//! device's own Open, which picks the unit. On success the request names
//! the device and is ready for I/O; on failure it names none, so a
//! `CloseDevice` after a failed open does nothing.
//!
//! This searches the device list and nothing else. What loads a device from
//! DEVS: is ramlib.library, which replaces the slot in front of it.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Device = sdk.exec.Device;
const IORequest = sdk.exec.IORequest;

/// Opens a unit of a device, for a request to use.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenDevice(base: *ExecBase, name: [*:0]const u8, unit: u32,
///     io: *IORequest, flags: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -320.
///
/// INPUTS:
/// - `name` - the device's name, matched exactly.
/// - `unit` - which unit. What a unit number means is the device's own.
/// - `io` - the request that will be used with this device. **It must be
///   big enough for what the device expects**: serial.device wants an
///   `IOExtSer`, and a plain `IORequest` there is memory the device will
///   write past.
/// - `flags` - device-specific open flags. Not the request's own flags: a
///   serial device's shared-access bit goes in the request, not here.
///
/// RESULT:
/// 0 if it opened. Otherwise the device's error, which is also left in the
/// request's error byte; `IOERR_OPENFAIL` when there is no device of that
/// name.
///
/// BEHAVIOR:
/// The request's device field is set before the Open vector runs and
/// cleared again if it refuses, so a failed open leaves a request that is
/// safe to pass to `CloseDevice` and to `DoIO` - both of which check it.
///
/// The device's Open picks the unit and writes it into the request. From
/// then on the request carries both, which is why a request is what is
/// opened rather than a handle being answered.
///
/// CONTEXT:
/// - Waits: no as exec has it, though a device's own Open may. With
///   ramlib.library in front of it, it may: the replacement loads the
///   device from DEVS:.
/// - Interrupts: no. It takes Forbid.
/// - Forbid: taken here, around the search and the vector.
/// - Process: a Task will do for exec's own. ramlib's replacement needs a
///   Process, and sends the work to its own when a Task calls it.
///
/// OWNERSHIP:
/// The caller holds an open count and must `CloseDevice` the request.
/// Several requests may be opened on one unit, and each is closed.
///
/// NOTES:
/// exec searches the device list and nothing else. What loads a device from
/// DEVS: is ramlib.library, which replaces this slot.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseDevice`, `DoIO`, `CreateIORequest`, `OpenLibrary`
///
/// EXAMPLES:
/// ```zig
/// const io = sys.CreateIORequest(port, @sizeOf(IOExtSer)) orelse return;
/// defer sys.DeleteIORequest(io);
/// if (sys.OpenDevice("serial.device", 0, io, 0) != 0) return;
/// defer sys.CloseDevice(io);
/// ```
pub fn OpenDevice(base: *ExecBase, name: [*:0]const u8, unit: u32, io: *IORequest, flags: u32) i32 {
    const sys = base.iface();
    sys.Forbid();
    defer sys.Permit();
    const node = sys.FindName(&base.device_list, name) orelse {
        io.device = null;
        io.err = sdk.exec.IOERR_OPENFAIL;
        return sdk.exec.IOERR_OPENFAIL;
    };
    const dev: *Device = @fieldParentPtr("node", node);
    io.device = dev;
    io.unit = null;
    io.err = 0;
    const result = dev.vector(sdk.exec.DevOpenFn, sdk.exec.LIB_OPEN)(dev, io, unit, flags);
    if (result != 0) {
        io.device = null;
        io.err = @truncate(result); // the request's error field is a byte
        return result;
    }
    return 0;
}
