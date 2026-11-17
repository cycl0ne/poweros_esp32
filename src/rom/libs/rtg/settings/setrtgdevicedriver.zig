// SPDX-License-Identifier: MPL-2.0
//! SetRtgDeviceDriver: Whether a driver from the disk is bound to a
//! device.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const err = rtg.errors;
const settings = @import("_settings.zig");

/// Says whether a driver from the disk is bound to a device.
///
/// SYNOPSIS:
/// ```zig
/// fn SetRtgDeviceDriver(rb: *RtgBase, device_name: [*:0]const u8, on: bool) i32
/// ```
///
/// SINCE: 1.34. LVO -120.
///
/// INPUTS:
/// - `device_name` - the device's name, as `GetRtgDevices` answers it
///   ("pci.01:00.0").
/// - `on` - true: a driver from the disk may take the device; false:
///   none is bound to it.
///
/// RESULT:
/// `RTGERR_OK`; `RTGERR_BAD_ARG` for a name of no length or one longer
/// than a device's can be; `RTGERR_NO_MEMORY` without room for the
/// device's line.
///
/// BEHAVIOR:
/// The device's line says `DRIVER=OFF` from now on, or no longer says
/// it. Nothing happens to a driver that has the device: the line is
/// read when the drivers on the disk are bound, at the next start, and
/// a device it switches off keeps the picture the firmware lit on it.
/// A driver in the ROM is not asked about.
///
/// The device need not be there: the line is kept for a card that is
/// out of its slot.
///
/// The change is not on the disk: `SaveBoardSettings` writes it.
///
/// CONTEXT:
/// - Waits: only while another task holds the settings' lock.
/// - Interrupts: no.
/// - Locks: takes the settings' lock.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The name is copied.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetRtgDevices`, `SaveBoardSettings`, `LoadBoardSettings`
///
/// EXAMPLES:
/// ```zig
/// // The card stays on the firmware's picture from the next start on.
/// if (rb.SetRtgDeviceDriver("pci.01:00.0", false) == rtg.errors.RTGERR_OK) {
///     _ = rb.SaveBoardSettings(rtg.RTG_SETTINGS_ENVARC);
/// }
/// ```
pub fn SetRtgDeviceDriver(rb: *RtgBase, device_name: [*:0]const u8, on: bool) i32 {
    const length = rb.utility_base.Strlen(device_name);
    if (length == 0 or length >= rtg.drivers.RTG_NAME_MAX) return err.RTGERR_BAD_ARG;
    const name = device_name[0..length];
    settings.obtain(rb);
    defer settings.release(rb);
    if (on) {
        const line = settings.findDevice(rb, name) orelse return err.RTGERR_OK;
        line.flags &= ~@as(u32, settings.DEVSET_DRIVER_OFF);
        settings.dropIfEmpty(rb, line);
        return err.RTGERR_OK;
    }
    const line = settings.needDevice(rb, name) orelse return err.RTGERR_NO_MEMORY;
    line.flags |= settings.DEVSET_DRIVER_OFF;
    return err.RTGERR_OK;
}
