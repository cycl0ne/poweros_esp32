// SPDX-License-Identifier: MPL-2.0
//! GetRtgDrivers: Copy out the drivers on the list.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;
const _driver = @import("_driver.zig");

/// Copies out the drivers on the library's list.
///
/// SYNOPSIS:
/// ```zig
/// fn GetRtgDrivers(rb: *RtgBase, into: ?[*]rtg.RtgDriverInfo, count: u32) u32
/// ```
///
/// SINCE: 1.18. LVO -212.
///
/// INPUTS:
/// - `into` - where the drivers go, or null to ask how many there are.
/// - `count` - how many `into` has room for.
///
/// RESULT:
/// How many drivers there are, which may be more than were copied.
///
/// BEHAVIOR:
/// Up to `count` drivers are copied, highest priority first: each one's
/// name, what it calls itself, its version and revision, what it makes
/// (`RTGDT_BOARD`, `RTGDT_TRANSPORT`), its flags and priority, how many
/// devices it has and how many boards and buses of it are alive, and
/// whether it was loaded from a file.
///
/// CONTEXT:
/// - Waits: yes, while another task holds the driver list - through an
///   offer of a device, which lasts as long as a driver's bring-up.
/// - Interrupts: no.
/// - Locks: takes the driver list's lock. No spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated: the copies are the caller's, and hold no pointer
/// into the library.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetRtgDevices`, `BindRtgDrivers`, `AddRtgDriver`
///
/// EXAMPLES:
/// ```zig
/// var found: [8]rtg.RtgDriverInfo = undefined;
/// const there = rb.GetRtgDrivers(&found, found.len);
/// for (found[0..@min(there, found.len)]) |*driver| list(driver);
/// ```
pub fn GetRtgDrivers(rb: *RtgBase, into: ?[*]rtg.RtgDriverInfo, count: u32) u32 {
    const sys = rb.sys_base;
    const ub = rb.utility_base;
    sys.ObtainSemaphore(&rb.driver_lock);
    defer sys.ReleaseSemaphore(&rb.driver_lock);
    var there: u32 = 0;
    var node = rb.drivers.first();
    while (node) |one| : (node = one.next()) {
        const driver = _driver.driverOf(one);
        const spec = driver.spec;
        if (into != null and there < count) {
            const info = &into.?[there];
            info.* = .{
                .version = spec.version,
                .revision = spec.revision,
                .kind = spec.kind,
                .flags = spec.flags,
                .priority = spec.priority,
                .devices = driver.devices,
                .boards = driver.boards,
                .buses = driver.buses,
                .loaded = @intFromBool(driver.seg_list != null),
            };
            _ = ub.Strlcpy(&info.name, info.name.len, spec.name);
            if (spec.id_string) |called| _ = ub.Strlcpy(&info.id_string, info.id_string.len, called);
        }
        there += 1;
    }
    return there;
}
