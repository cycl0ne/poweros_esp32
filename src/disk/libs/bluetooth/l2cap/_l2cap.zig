// SPDX-License-Identifier: MIT
//! L2CAP over a controller's links: each frame a link's ACL packets put
//! together (hci/acl.zig) handed to its channel, and frames sent on a
//! channel.
//!
//! **The channels** are the fixed ones - the signalling channels, BR/EDR's
//! and LE's (signalling.zig), and over LE the attribute protocol's and
//! the security manager's (hci/smp.zig) - and over BR/EDR the dynamic
//! ones, each to a protocol of the device (channels.zig). A request of
//! the attribute protocol is answered that it is not supported, and an
//! indication confirmed; a pairing BR/EDR's security manager channel is
//! asked for is refused as not supported. Frames on any other channel are
//! let go.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const l2cap = sdk.bluetooth.l2cap;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const acl = @import("../hci/acl.zig");
const connections = @import("../hci/connections.zig");
const Connection = connections.Connection;
const smp = @import("../hci/smp.zig");
const signalling = @import("signalling.zig");
const channels = @import("channels.zig");

/// The attribute protocol's Error Response, the indication and its
/// confirmation, and the error a request is answered with.
const ATT_ERROR_RESPONSE: u8 = 0x01;
const ATT_HANDLE_VALUE_INDICATION: u8 = 0x1D;
const ATT_HANDLE_VALUE_CONFIRMATION: u8 = 0x1E;
const ATT_REQUEST_NOT_SUPPORTED: u8 = 0x06;

/// A whole frame of the link, from its L2CAP header on, handed to its
/// channel.
pub fn received(layer: *Hci, connection: *Connection, frame: []const u8) void {
    if (frame.len < l2cap.L2CAP_HDR) return;
    const cid = _hci.le16(frame[2..4]);
    const payload = frame[l2cap.L2CAP_HDR..];
    if (connection.le) {
        switch (cid) {
            l2cap.CID_LE_SIGNALING => signalling.le(layer, connection, payload),
            l2cap.CID_ATT => attribute(layer, connection, payload),
            l2cap.CID_SMP => smp.received(layer, connection, payload),
            else => {},
        }
    } else {
        switch (cid) {
            l2cap.CID_SIGNALING => signalling.bredr(layer, connection, payload),
            l2cap.CID_SMP_BREDR => refusePairing(layer, connection, payload),
            else => if (cid >= l2cap.CID_DYNAMIC_FIRST) channels.received(layer, connection, cid, payload),
        }
    }
}

/// A frame sent on channel `cid` of the link: false when it cannot be
/// queued.
pub fn send(layer: *Hci, connection: *const Connection, cid: u16, payload: []const u8) bool {
    return acl.send(layer, connection, cid, payload);
}

fn attribute(layer: *Hci, connection: *Connection, payload: []const u8) void {
    if (payload.len == 0) return;
    const opcode = payload[0];
    if (opcode == ATT_HANDLE_VALUE_INDICATION) {
        _ = send(layer, connection, l2cap.CID_ATT, &.{ATT_HANDLE_VALUE_CONFIRMATION});
        return;
    }
    if (!isAttRequest(opcode)) return;
    // The request, no handle in it, and why.
    _ = send(layer, connection, l2cap.CID_ATT, &.{ ATT_ERROR_RESPONSE, opcode, 0, 0, ATT_REQUEST_NOT_SUPPORTED });
}

/// The attribute protocol's requests: those a server answers - its
/// commands, notifications and answers want none.
fn isAttRequest(opcode: u8) bool {
    return switch (opcode) {
        0x02, 0x04, 0x06, 0x08, 0x0A, 0x0C, 0x0E, 0x10, 0x12, 0x16, 0x18, 0x20 => true,
        else => false,
    };
}

/// A pairing over BR/EDR's security manager channel - LE's keys made from
/// a BR/EDR link - refused as not supported.
fn refusePairing(layer: *Hci, connection: *Connection, payload: []const u8) void {
    if (payload.len == 0) return;
    if (payload[0] != smp.PAIRING_REQUEST and payload[0] != smp.SECURITY_REQUEST) return;
    _ = send(layer, connection, l2cap.CID_SMP_BREDR, &.{ smp.PAIRING_FAILED, smp.REASON_PAIRING_NOT_SUPPORTED });
}
