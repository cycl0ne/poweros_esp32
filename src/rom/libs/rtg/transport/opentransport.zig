// SPDX-License-Identifier: MPL-2.0
//! OpenTransport: The bus a device is reached over.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const Private = _transport.Private;
const err = rtg.errors;
const registry = @import("../driver/_driver.zig");
const devices = @import("../device/_device.zig");
const _transport = @import("_transport.zig");

/// Opens the bus a device is reached over.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenTransport(rb: *RtgBase, driver: *rtg.RtgDriver, device: *rtg.RtgDevice) ?*rtg.RtgTransport
/// ```
///
/// SINCE: 1.18. LVO -376.
///
/// INPUTS:
/// - `driver` - the driver that asks: the one that has `device`, or is
///   being offered it.
/// - `device` - the device on the bus.
///
/// RESULT:
/// The bus, or null: when `driver` neither has the device nor is being
/// offered it, for a bus no transport driver's table names, without
/// memory, and when no transport driver could make it.
///
/// BEHAVIOR:
/// A panel on a bus is two drivers: one for the panel, which takes the
/// device, and one for the bus. The transport drivers whose table names
/// the device - its bus, most often - are asked in turn, the closest
/// first, to make the bus from the device's tags (`create_transport`):
/// the pads, the clock and the framing are tags of the part. The first
/// that answers `RTGERR_OK` has made it. The handle and the driver's
/// instance come from memory the bus's driver can read from its
/// interrupts. The panel's driver talks over the bus with `TxParam`,
/// `TxColor` and `RxParam`.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the driver list or the board
///   list, and if the bus's driver does.
/// - Interrupts: no.
/// - Locks: takes the driver list's lock and the board list's. No
///   spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bus is the caller's until `CloseTransport`. Its driver is one bus
/// more.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseTransport`, `TxParam`, `TxColor`, `RxParam`
///
/// EXAMPLES:
/// ```zig
/// const io = rb.OpenTransport(driver, device) orelse return rtg.errors.RTGERR_NO_DISPLAY;
/// ```
pub fn OpenTransport(rb: *RtgBase, driver: *rtg.RtgDriver, device: *rtg.RtgDevice) ?*rtg.RtgTransport {
    const sys = rb.sys_base;
    // The bus is its device's driver's to open.
    if (device.driver != driver and devices.privateOf(device).offered_to != driver) return null;

    sys.ObtainSemaphore(&rb.driver_lock);
    defer sys.ReleaseSemaphore(&rb.driver_lock);
    var asked: [devices.max_candidates]devices.Candidate = undefined;
    const count = devices.candidates(rb, device, rtg.drivers.RTGDT_TRANSPORT, &asked);
    for (asked[0..count]) |candidate| {
        const maker = candidate.driver;
        const spec = maker.spec;
        const create = spec.ops.create_transport orelse continue;

        const where = registry.memoryFor(spec);
        const memory = sys.AllocVec(@sizeOf(Private), where) orelse return null;
        const private: *Private = @ptrCast(@alignCast(memory));
        private.* = .{};
        const io = &private.io;
        io.rtg_base = @ptrCast(rb);
        io.driver = @ptrCast(maker);
        io.node.name = spec.name;
        if (spec.instance_size != 0) {
            io.instance = sys.AllocVec(spec.instance_size, where) orelse {
                sys.FreeVec(memory);
                return null;
            };
            io.instance_size = spec.instance_size;
        }

        if (create(maker, io, device.tags) != err.RTGERR_OK) {
            if (io.instance) |instance| sys.FreeVec(instance);
            sys.FreeVec(memory);
            continue;
        }
        maker.buses += 1;
        sys.ObtainSemaphore(&rb.board_lock);
        sys.AddTail(&rb.transports, &io.node);
        sys.ReleaseSemaphore(&rb.board_lock);
        return io;
    }
    return null;
}
