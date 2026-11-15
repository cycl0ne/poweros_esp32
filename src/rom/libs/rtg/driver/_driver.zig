// SPDX-License-Identifier: MPL-2.0
//! The driver list.
//!
//! A driver is a constant description (`RtgDriverSpec`) in its own image.
//! `AddRtgDriver` makes the library's node for one - an `RtgDriver`, with
//! the state the description asks for behind it in the same block - and
//! the node is what everything holds from then on: a board names it, an
//! op is handed it, and the driver finds its own state through it. The
//! list is ordered by the descriptions' priority, highest first, so of
//! two drivers whose tables name a device as closely the one that should
//! be preferred says so.
//!
//! The library puts the drivers of the ROM on the list itself, at its
//! init: every tag of type `.rtg_driver` is a `ResidentRtgDriver`, read
//! where it lies (`addResidents`). Nothing of a driver runs for that.
//!
//! The semaphore holds the list still. Adding and removing take it, and so
//! does whatever walks it: an offer of a device, which holds it through
//! the drivers' `attach`, and `GetRtgDrivers`, which copies the list out
//! so that a program holds no node of it.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const RtgBase = @import("../rtg.zig").RtgBase;

/// What the library keeps for a driver, beside the node a driver sees.
pub const Private = struct {
    driver: rtg.RtgDriver,
    /// How many boards the driver has made, for numbering the next one
    /// ("fb.1").
    board_serial: u32 = 0,
};

/// The library's own record around a driver's node.
///
/// INPUTS:
/// - `driver` - the driver's node.
pub fn privateOf(driver: *rtg.RtgDriver) *Private {
    return @fieldParentPtr("driver", driver);
}

/// The driver a node of the driver list belongs to.
///
/// INPUTS:
/// - `node` - the driver's node.
pub fn driverOf(node: *exec.Node) *rtg.RtgDriver {
    return @fieldParentPtr("node", node);
}

/// What a driver's record and its state are aligned to in their one
/// block: as much as any field a driver keeps can ask for.
pub const state_alignment = @alignOf(u64);

/// Where a driver's state begins in the block its record is in: past the
/// record, on the state's alignment.
pub const state_offset = (@sizeOf(Private) + (state_alignment - 1)) & ~@as(usize, state_alignment - 1);

/// Where a driver's node, handles and instances go: internal memory when
/// the description says its interrupts touch them, and wherever there is
/// room otherwise. Cleared either way.
///
/// INPUTS:
/// - `spec` - the driver's description.
pub fn memoryFor(spec: *const rtg.RtgDriverSpec) u32 {
    const clear = exec.MEMF_CLEAR;
    if (spec.flags & rtg.drivers.RTGDF_INTERNAL_INSTANCE != 0) return exec.MEMF_INTERNAL | clear;
    return exec.MEMF_ANY | clear;
}

/// Puts the drivers of the ROM on the list: every tag of type
/// `.rtg_driver` exec's boot scan found is a `ResidentRtgDriver`, whose
/// description is handed to `AddRtgDriver`. One the list refuses - a name
/// it has - is passed over.
///
/// INPUTS:
/// - `rb` - the library, its list and its locks set up.
///
/// CONTEXT:
/// Runs once, in the library's init. Nothing of a driver runs.
pub fn addResidents(rb: *RtgBase) void {
    const table = rb.sys_base.ResModules() orelse return;
    var index: usize = 0;
    while (table[index]) |tag| : (index += 1) {
        if (tag.type != .rtg_driver) continue;
        const described: *const rtg.ResidentRtgDriver = @fieldParentPtr("resident", tag);
        _ = rb.driverIface().AddRtgDriver(&described.spec, null);
    }
}
