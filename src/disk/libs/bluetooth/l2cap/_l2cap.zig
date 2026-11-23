// SPDX-License-Identifier: MIT
//! L2CAP over a controller's links: each frame a link's ACL packets put
//! together (hci/acl.zig) handed to its channel, and frames sent on a
//! channel.
//!
//! **The channels** are the fixed ones - the signalling channels, BR/EDR's
//! and LE's (signalling.zig), and over LE the attribute protocol's
//! (att/) and the security manager's (hci/smp.zig) - and over BR/EDR the
//! dynamic ones, each to a protocol of the device (channels.zig). A
//! pairing BR/EDR's security manager channel is asked for is refused as
//! not supported. Frames on any other channel are let go.
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
const _att = @import("../att/_att.zig");

/// A whole frame of the link, from its L2CAP header on, handed to its
/// channel.
pub fn received(layer: *Hci, connection: *Connection, frame: []const u8) void {
    if (frame.len < l2cap.L2CAP_HDR) return;
    const cid = _hci.le16(frame[2..4]);
    const payload = frame[l2cap.L2CAP_HDR..];
    if (connection.le) {
        switch (cid) {
            l2cap.CID_LE_SIGNALING => signalling.le(layer, connection, payload),
            l2cap.CID_ATT => _att.received(layer, connection, payload),
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

/// A pairing over BR/EDR's security manager channel - LE's keys made from
/// a BR/EDR link - refused as not supported.
fn refusePairing(layer: *Hci, connection: *Connection, payload: []const u8) void {
    if (payload.len == 0) return;
    if (payload[0] != smp.PAIRING_REQUEST and payload[0] != smp.SECURITY_REQUEST) return;
    _ = send(layer, connection, l2cap.CID_SMP_BREDR, &.{ smp.PAIRING_FAILED, smp.REASON_PAIRING_NOT_SUPPORTED });
}
