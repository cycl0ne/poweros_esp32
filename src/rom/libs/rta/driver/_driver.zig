// SPDX-License-Identifier: MPL-2.0
//! The driver list.
//!
//! A driver is a module that hands in an RtaDriver node and keeps it for
//! as long as it is registered. The list is ordered by priority, highest
//! first; a caller that names a driver gets that one whatever its
//! priority.
//!
//! The semaphore holds the list still. Adding and removing take it, and so
//! does a caller that means to walk it with NextRtaDriver - which is why
//! LockRtaDrivers is a call of its own rather than something the walk does
//! for itself: a walk that locked each step would hand back a driver that
//! could be gone by the time it was used.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;

/// The driver a node of the driver list belongs to.
///
/// INPUTS:
/// - `node` - the driver's node.
pub fn driverOf(node: *exec.Node) *rta.RtaDriver {
    return @fieldParentPtr("node", node);
}

/// A driver of that name that makes the kind of thing asked for: the
/// creates are separate, so a name that is registered but cannot make
/// what is being asked is not the driver wanted.
///
/// INPUTS:
/// - `rb` - the library.
/// - `name` - the driver's name.
/// - `kind` - `RTADT_SINK`, `RTADT_TRANSPORT` or `RTADT_SOURCE`.
pub fn findDriverOfType(rb: *RtaBase, name: [*:0]const u8, kind: u32) ?*rta.RtaDriver {
    const rta_lib = rb.iface();
    const driver = rta_lib.FindRtaDriver(name) orelse return null;
    if (driver.type & kind == 0) return null;
    return driver;
}

/// What a handle of this driver is allocated in: internal memory for a
/// driver whose interrupts read it, anything otherwise. Cleared either
/// way.
///
/// INPUTS:
/// - `driver` - the driver.
pub fn memoryFor(driver: *const rta.RtaDriver) u32 {
    const internal = driver.flags & rta.sinks.RTADF_INTERNAL_INSTANCE != 0;
    return exec.MEMF_CLEAR | (if (internal) exec.MEMF_INTERNAL else exec.MEMF_ANY);
}

/// Records why a call that answers with a pointer failed: in the library,
/// and where the caller's `RTAA_ErrorPtr` asked for it.
///
/// INPUTS:
/// - `rb` - the library.
/// - `code` - the `RTAERR_` code.
/// - `error_ptr` - the caller's `RTAA_ErrorPtr`, or null.
pub fn fail(rb: *RtaBase, code: i32, error_ptr: ?*i32) void {
    rb.last_error = code;
    if (error_ptr) |p| p.* = code;
}

/// A handle's name: what the caller asked for, or the driver's name and a
/// number. It is copied, because the caller's string is the caller's.
///
/// INPUTS:
/// - `rb` - the library. Its utility.library does the copy.
/// - `into` - the handle's name buffer.
/// - `driver_name` - the driver's name, used when none is wanted.
/// - `wanted` - the caller's name for it, or null.
/// - `serial` - the number to put after the driver's name.
pub fn setName(rb: *RtaBase, into: []u8, driver_name: [*:0]const u8, wanted: ?[*:0]const u8, serial: u32) void {
    const source: [*:0]const u8 = wanted orelse driver_name;
    // Up to len - 4 characters of name, which leaves room for a number:
    // Strlcpy keeps one byte of `room` for its NUL.
    const room = into.len - 3;
    var at = @min(rb.utility_base.Strlcpy(into.ptr, room, source), room - 1);
    if (wanted == null) {
        // "i2s0", "i2s1": the driver's name and which one this is.
        var digits: [10]u8 = undefined;
        var count: usize = 0;
        var left = serial;
        while (true) {
            digits[count] = '0' + @as(u8, @intCast(left % 10));
            count += 1;
            left /= 10;
            if (left == 0) break;
        }
        while (count > 0 and at < into.len - 1) {
            count -= 1;
            into[at] = digits[count];
            at += 1;
        }
    }
    into[at] = 0;
}
