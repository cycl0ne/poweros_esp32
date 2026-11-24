// SPDX-License-Identifier: MIT
//! A link as ObtainBTConnections hands it out: the public record and the
//! device's name, in one piece, copied from the controller's table
//! (hci/connections.zig) under the base's lock.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const hci = bluetooth.hci;
const _hci = @import("../hci/_hci.zig");
const bonds = @import("../hci/bonds.zig");
const connections = @import("../hci/connections.zig");

pub const Entry = extern struct {
    public: bluetooth.BTConnection = .{},
    name: [hci.HCI_MAX_NAME + 1]u8 = @splat(0),
};

/// Whether a link is listed: one that is made - up, the device having
/// answered on it - or being ended.
pub fn listed(connection: *const connections.Connection) bool {
    return (connection.state == .up or connection.state == .disconnecting) and connection.heard;
}

/// A link of controller `id`, whose layer is `layer`, copied into an
/// entry; `now` the time in milliseconds, which its age is counted from.
pub fn describe(id: u32, layer: *_hci.Hci, connection: *const connections.Connection, entry: *Entry, now: u64) void {
    @memcpy(&entry.name, &connection.name);
    entry.name[hci.HCI_MAX_NAME] = 0;
    var flags: u32 = 0;
    if (connection.le) flags |= bluetooth.BTLF_LE;
    if (connection.incoming) flags |= bluetooth.BTLF_INCOMING;
    if (connection.central) flags |= bluetooth.BTLF_CENTRAL;
    if (connection.encrypted) flags |= bluetooth.BTLF_ENCRYPTED;
    if (connection.authenticated) flags |= bluetooth.BTLF_AUTHENTICATED;
    if (bonds.find(layer, connection.identity orelse connection.address) != null) flags |= bluetooth.BTLF_BONDED;
    if (connection.pairing.stage != .idle) flags |= bluetooth.BTLF_PAIRING;
    entry.public = .{
        .controller = id,
        .flags = flags,
        .address = connection.address,
        .handle = connection.handle,
        .interval = connection.interval,
        .latency = connection.latency,
        .supervision = connection.supervision,
        .age = @intCast(@min(now -| connection.since, 0xFFFF_FFFF)),
        .class_of_device = connection.class_of_device,
        .identity = connection.identity orelse .{},
        .own_address = if (connection.le) connection.own else .{},
    };
    entry.public.node.name = @ptrCast(&entry.name);
}
