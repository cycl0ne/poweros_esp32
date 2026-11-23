// SPDX-License-Identifier: MIT
//! The attribute protocol over a controller's LE links: each link's
//! bearer - the MTU the two sides agreed, the request of this machine's
//! out on it - and its PDUs handed to the side they are for: requests and
//! commands to the server (server.zig); answers, notifications and
//! indications to the client (client.zig).
//!
//! **The MTU** is att.ATT_MTU_DEFAULT until an Exchange MTU is answered -
//! the device's, to this machine's server, or this machine's own, which
//! the client sends before its first request on the link - and then the
//! smaller of the two sides', never less than the default.
//!
//! **One request at a time** each way: the client's next waits for the
//! answer to the last, TRANSACTION_MS at most. A request not answered by
//! then leaves the bearer dead: nothing more is sent on it or taken from
//! it until the link is made again. An indication is confirmed as it
//! comes.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const att = bluetooth.att;
const l2cap = bluetooth.l2cap;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const acl = @import("../hci/acl.zig");
const connections = @import("../hci/connections.zig");
const Connection = connections.Connection;
const _sdp = @import("../sdp/_sdp.zig");
const client = @import("client.zig");
const server = @import("server.zig");

/// This machine's MTU: the most a PDU to it carries - room for the
/// longest value and a request's header.
pub const MTU_OURS: u16 = 517;
/// How long a request is waited for before the bearer is given up.
pub const TRANSACTION_MS: u32 = 30_000;

/// A link's bearer: kept in its connection, made again with it.
pub const Bearer = struct {
    /// The most a PDU carries.
    mtu: u16 = att.ATT_MTU_DEFAULT,
    /// This machine's Exchange MTU answered, or refused: the client's
    /// procedures may run.
    exchanged: bool = false,
    /// The opcode of the client's request out, 0 for none, and when it is
    /// given up.
    asked: u8 = 0,
    deadline: ?u64 = null,
    /// A request not answered in its time: nothing more goes or comes.
    dead: bool = false,
    /// The client's procedure that runs on it, by its place in the
    /// layer's table.
    running: ?u8 = null,
    /// Service Changed's Client Characteristic Configuration, as the
    /// device's client wrote it.
    service_changed: u16 = 0,
};

/// A PDU of the link handed to its side.
pub fn received(layer: *Hci, connection: *Connection, pdu: []const u8) void {
    if (pdu.len == 0 or connection.att.dead) return;
    switch (pdu[0]) {
        att.ATT_ERROR_RSP,
        att.ATT_EXCHANGE_MTU_RSP,
        att.ATT_FIND_INFORMATION_RSP,
        att.ATT_FIND_BY_TYPE_VALUE_RSP,
        att.ATT_READ_BY_TYPE_RSP,
        att.ATT_READ_RSP,
        att.ATT_READ_BLOB_RSP,
        att.ATT_READ_MULTIPLE_RSP,
        att.ATT_READ_BY_GROUP_TYPE_RSP,
        att.ATT_WRITE_RSP,
        att.ATT_PREPARE_WRITE_RSP,
        att.ATT_EXECUTE_WRITE_RSP,
        att.ATT_READ_MULTIPLE_VARIABLE_RSP,
        => client.answered(layer, connection, pdu),
        att.ATT_HANDLE_VALUE_NTF => client.notified(layer, connection, pdu),
        att.ATT_HANDLE_VALUE_IND => {
            _ = send(layer, connection, &.{att.ATT_HANDLE_VALUE_CFM});
            client.notified(layer, connection, pdu);
        },
        // Not asked for - the client says no features - and not sent: the
        // server indicates nothing.
        att.ATT_MULTIPLE_HANDLE_VALUE_NTF, att.ATT_HANDLE_VALUE_CFM => {},
        else => server.received(layer, connection, pdu),
    }
}

/// A PDU sent on the link's attribute channel: false when it cannot be
/// queued.
pub fn send(layer: *Hci, connection: *const Connection, pdu: []const u8) bool {
    return acl.send(layer, connection, l2cap.CID_ATT, pdu);
}

/// The MTU two sides agree on, given the other's.
pub fn agreed(theirs: u16) u16 {
    return @max(att.ATT_MTU_DEFAULT, @min(MTU_OURS, theirs));
}

/// A UUID as a PDU carries it - 2 or 16 bytes, little-endian - written
/// out, big-endian.
pub fn uuidOf(bytes: []const u8) [16]u8 {
    var full: [16]u8 = bluetooth.sdp.BASE_UUID;
    if (bytes.len == 2) {
        full[2] = bytes[1];
        full[3] = bytes[0];
    } else {
        for (0..16) |index| full[index] = bytes[15 - index];
    }
    return full;
}

/// A UUID's value on the base as 16 bits; 0 where it is not one.
pub fn short(full: [16]u8) u16 {
    return _sdp.short(full);
}

pub fn le16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | @as(u16, bytes[1]) << 8;
}

pub fn put16(into: []u8, value: u16) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
}
