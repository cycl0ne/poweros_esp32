// SPDX-License-Identifier: MPL-2.0
//! The driver list.
//!
//! A driver is a constant description (`RtgDriverSpec`) in its own image.
//! `AddRtgDriver` makes the library's node for one - an `RtgDriver`, with
//! the state the description asks for behind it in the same block - and
//! the node is what everything holds from then on: a board names it, an
//! op is handed it, and the driver finds its own state through it. The
//! list is ordered by the descriptions' priority, highest first, so a
//! driver that should be preferred when two could drive the same thing
//! says so; a caller that names a driver gets that one whatever its
//! priority.
//!
//! The library puts the drivers of the ROM on the list itself, at its
//! init: every tag of type `.rtg_driver` is a `ResidentRtgDriver`, read
//! where it lies (`addResidents`). Nothing of a driver runs for that.
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

/// What a driver's node and its state are aligned to in their one block:
/// as much as any field a driver keeps can ask for.
pub const state_alignment = @alignOf(u64);

/// Where a driver's state begins in the block its node is in: past the
/// node, on the state's alignment.
pub const state_offset = (@sizeOf(rtg.RtgDriver) + (state_alignment - 1)) & ~@as(usize, state_alignment - 1);

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

/// A driver of that name that can make a board, or one that can make a
/// transport - the two creates are separate, so a name that is on the
/// list but cannot do what is being asked is not the driver wanted.
///
/// INPUTS:
/// - `rb` - the library.
/// - `name` - the driver's name.
/// - `kind` - `RTGDT_BOARD` or `RTGDT_TRANSPORT`.
pub fn findDriverOfType(rb: *RtgBase, name: [*:0]const u8, kind: u32) ?*rtg.RtgDriver {
    const sys = rb.sys_base;
    sys.ObtainSemaphore(&rb.driver_lock);
    defer sys.ReleaseSemaphore(&rb.driver_lock);
    const driver = driverOf(sys.FindName(&rb.drivers, name) orelse return null);
    if (driver.spec.kind & kind == 0) return null;
    return driver;
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
