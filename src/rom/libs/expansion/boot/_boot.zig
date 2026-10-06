// SPDX-License-Identifier: MPL-2.0
//! What the boot node calls share: the BootNode a disk's device node waits
//! in until dos.library is up, and opening dos to hand one over.
//!
//! A driver that starts before dos - flash.device at cold start - cannot
//! put its partitions on dos's list, so AddBootNode keeps each node on
//! `boot_nodes`, by its boot priority, and dos's init takes them all with
//! EnterBootNodes. Whether dos is up is whether it opens: from the moment
//! dos is on the library list a node goes straight onto its device list,
//! and both paths run under `boot_lock`, so a node is never kept after dos
//! has taken the rest.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const DosBase = sdk.interface.dos.DosBase;
const ExpansionBase = @import("../expansion_base.zig").ExpansionBase;

/// A device node waiting for dos.library, on `boot_nodes` at its boot
/// priority (`node.pri`). One AllocVec, freed when dos takes the node.
pub const BootNode = extern struct {
    node: exec.Node = .{},
    device_node: *dos.DosList,
};

/// The priority a node waits at: the boot priority, held to a node's
/// range. -128 is the one never booted from.
pub fn nodePri(boot_pri: i32) i8 {
    if (boot_pri < -128) return -128;
    if (boot_pri > 127) return 127;
    return @intCast(boot_pri);
}

/// dos.library if it is up, opened for the caller to close; null before.
pub fn openDos(eb: *ExpansionBase) ?*DosBase {
    return @ptrCast(eb.sys_base.OpenLibrary(dos.DOSNAME, 0) orelse return null);
}
