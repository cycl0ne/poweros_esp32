// SPDX-License-Identifier: MPL-2.0
//! The driver list.
//!
//! A driver is a module that hands in an RtgDriver node and keeps it for
//! as long as it is registered. The list is ordered by priority, highest
//! first, so a driver that should be preferred when two could drive the
//! same thing says so with ln_Pri; a caller that names a driver gets that
//! one whatever its priority.
//!
//! The semaphore holds the list still. Adding and removing take it, and so
//! does a caller that means to walk it with NextRtgDriver - which is why
//! LockRtgDrivers is a call of its own rather than something the walk does
//! for itself: a walk that locked each step would hand back a driver that
//! could be gone by the time it was used.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;

/// The driver a node of the driver list belongs to.
///
/// INPUTS:
/// - `node` - the driver's node.
pub fn driverOf(node: *exec.Node) *rtg.RtgDriver {
    return @fieldParentPtr("node", node);
}

/// A driver of that name that can make a board, or one that can make a
/// transport - the two creates are separate, so a name that is registered
/// but cannot do what is being asked is not the driver wanted.
///
/// INPUTS:
/// - `rb` - the library.
/// - `name` - the driver's name.
/// - `kind` - `RTGDT_BOARD` or `RTGDT_TRANSPORT`.
pub fn findDriverOfType(rb: *RtgBase, name: [*:0]const u8, kind: u32) ?*rtg.RtgDriver {
    const rtg_lib = rb.iface();
    const driver = rtg_lib.FindRtgDriver(name) orelse return null;
    if (driver.type & kind == 0) return null;
    return driver;
}
