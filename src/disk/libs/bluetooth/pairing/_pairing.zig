// SPDX-License-Identifier: MIT
//! The pairing calls' own: an agent as AddBTAgent keeps it on the base's
//! list - its number, its port and what its user can do - and a bond as
//! ObtainBTBonds hands it out, the public record and the device's name in
//! one piece, copied from the controller's table (hci/bonds.zig) under
//! the base's lock.
//!
//! **By its number.** The layers and the task know an agent by its
//! number, never by its record: RemBTAgent frees the record at once, and
//! the task finds an agent - under the agents' lock, which it holds while
//! it sends to the agent's port - or finds that it is gone.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const bonds = @import("../hci/bonds.zig");

/// One AddBTAgent: the BTAgent its caller holds.
pub const Agent = struct {
    node: exec.Node = .{},
    /// Its number: never 0, never one another agent had.
    id: u32,
    port: *exec.MsgPort,
    /// BTIO_*.
    capability: u32,
};

/// An agent's number and what its user can do; number 0 for none.
pub const Answering = struct {
    id: u32 = 0,
    capability: u32 = 0,
};

/// The agent a pairing a device begins goes to: the one added last.
pub fn current(base: *BluetoothBase) Answering {
    const sys = base.sys_base;
    sys.ObtainSemaphoreShared(&base.agents_lock);
    defer sys.ReleaseSemaphore(&base.agents_lock);
    const node = base.agents.first() orelse return .{};
    const agent: *Agent = @alignCast(@fieldParentPtr("node", node));
    return .{ .id = agent.id, .capability = agent.capability };
}

/// The agent with number `id`; null when it is gone. Under the agents'
/// lock, held while the record is used.
pub fn find(base: *BluetoothBase, id: u32) ?*Agent {
    var it = base.agents.iterator();
    while (it.next()) |node| {
        const agent: *Agent = @alignCast(@fieldParentPtr("node", node));
        if (agent.id == id) return agent;
    }
    return null;
}

pub const Entry = extern struct {
    public: bluetooth.BTBond = .{},
    name: [bluetooth.BT_BOND_NAME_MOST + 1]u8 = @splat(0),
    drivers: [bluetooth.BT_BOND_DRIVERS_MOST + 1]u8 = @splat(0),
};

/// A bond of controller `id` copied into an entry.
pub fn describe(id: u32, bond: *const bonds.Bond, entry: *Entry) void {
    @memcpy(&entry.name, &bond.name);
    entry.name[bluetooth.BT_BOND_NAME_MOST] = 0;
    var flags: u32 = 0;
    if (bonds.authenticated(bond)) flags |= bluetooth.BTBF_AUTHENTICATED;
    if (bonds.secure(bond)) flags |= bluetooth.BTBF_SECURE;
    if (bond.legacy) flags |= bluetooth.BTBF_LEGACY;
    if (bond.has_irk) flags |= bluetooth.BTBF_IDENTITY;
    entry.public = .{
        .controller = id,
        .flags = flags,
        .address = bond.address,
        .class_of_device = bond.class_of_device,
        .key_type = if (bonds.le(bond)) 0 else bond.key_type,
        .key_size = bond.key_size,
    };
    entry.public.node.name = @ptrCast(&entry.name);
    entry.public.drivers = @ptrCast(&entry.drivers);
}

/// Whether a bond is listed: one kept, not one ended whose file is still
/// to be deleted.
pub fn listed(bond: *const bonds.Bond) bool {
    return bond.used and !bond.gone;
}
