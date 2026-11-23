// SPDX-License-Identifier: MIT
//! L2CAP's signalling channels: BR/EDR's, whose frame carries any number
//! of commands, and LE's, whose frame carries one. What a device asks is
//! answered -
//!
//!   Information Request: the extended features - the fixed channels -
//!   and which fixed channels there are, the signalling channel; the
//!   connectionless MTU as not supported;
//!   Echo Request: echoed, its data as far as the smallest signalling
//!   MTU holds;
//!   Connection Request, LE Credit Based Connection Request: there is no
//!   such protocol;
//!   Configure Request, Disconnection Request: there is no such channel;
//!   Connection Parameter Update Request, LE's peripheral's to its
//!   central: parameters within the specification's bounds taken - the
//!   controller told (LE Connection Update) - others refused;
//!
//! - and any other request rejected as not understood. Answers that
//! come, and rejections, are let go: the library asks nothing yet. A
//! command identified as 0 identifies nothing, and is let go too.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const l2cap = sdk.bluetooth.l2cap;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const connections = @import("../hci/connections.zig");
const Connection = connections.Connection;
const _l2cap = @import("_l2cap.zig");

/// The most data an answer carries: what the smallest BR/EDR signalling
/// MTU holds after the command's header.
const ANSWER_MOST: usize = l2cap.MTU_SIGNALING_BREDR - l2cap.L2CAP_COMMAND_HDR;
/// LE's Flow Control Credit Indication: neither a request nor an answer.
const FLOW_CONTROL_CREDIT: u8 = 0x16;

/// BR/EDR's signalling channel: each command of the frame answered, one
/// after the other.
pub fn bredr(layer: *Hci, connection: *Connection, payload: []const u8) void {
    const cid = l2cap.CID_SIGNALING;
    var at: usize = 0;
    while (payload.len - at >= l2cap.L2CAP_COMMAND_HDR) {
        const code = payload[at];
        const ident = payload[at + 1];
        const length: usize = _hci.le16(payload[at + 2 ..][0..2]);
        at += l2cap.L2CAP_COMMAND_HDR;
        if (length > payload.len - at) {
            // Longer than the frame: what is left of it is not read.
            if (ident != 0) reject(layer, connection, cid, ident, l2cap.REJECT_NOT_UNDERSTOOD, &.{});
            return;
        }
        const data = payload[at..][0..length];
        at += length;
        if (ident == 0) continue;
        switch (code) {
            l2cap.INFORMATION_REQUEST => information(layer, connection, ident, data),
            l2cap.ECHO_REQUEST => respond(layer, connection, cid, l2cap.ECHO_RESPONSE, ident, data[0..@min(data.len, ANSWER_MOST)]),
            l2cap.CONNECTION_REQUEST => noProtocol(layer, connection, ident, data),
            l2cap.CONFIGURE_REQUEST => noChannel(layer, connection, cid, ident, data, 2),
            l2cap.DISCONNECTION_REQUEST => noChannel(layer, connection, cid, ident, data, 4),
            else => notUnderstood(layer, connection, cid, code, ident),
        }
    }
}

/// LE's signalling channel: the frame's one command answered.
pub fn le(layer: *Hci, connection: *Connection, payload: []const u8) void {
    const cid = l2cap.CID_LE_SIGNALING;
    if (payload.len < l2cap.L2CAP_COMMAND_HDR) return;
    const code = payload[0];
    const ident = payload[1];
    if (ident == 0) return;
    const length: usize = _hci.le16(payload[2..4]);
    if (length != payload.len - l2cap.L2CAP_COMMAND_HDR) return reject(layer, connection, cid, ident, l2cap.REJECT_NOT_UNDERSTOOD, &.{});
    const data = payload[l2cap.L2CAP_COMMAND_HDR..];
    switch (code) {
        l2cap.CONNECTION_PARAMETER_UPDATE_REQUEST => parameterUpdate(layer, connection, ident, data),
        l2cap.LE_CREDIT_CONNECTION_REQUEST => noLeProtocol(layer, connection, ident, data),
        l2cap.DISCONNECTION_REQUEST => noChannel(layer, connection, cid, ident, data, 4),
        else => notUnderstood(layer, connection, cid, code, ident),
    }
}

/// A command not answered above: a request rejected as not understood;
/// an answer - an odd code - a rejection, or LE's credits let go.
fn notUnderstood(layer: *Hci, connection: *Connection, cid: u16, code: u8, ident: u8) void {
    if (code == l2cap.COMMAND_REJECT or code == FLOW_CONTROL_CREDIT) return;
    if (code & 1 != 0) return;
    reject(layer, connection, cid, ident, l2cap.REJECT_NOT_UNDERSTOOD, &.{});
}

fn information(layer: *Hci, connection: *Connection, ident: u8, data: []const u8) void {
    const cid = l2cap.CID_SIGNALING;
    if (data.len < 2) return reject(layer, connection, cid, ident, l2cap.REJECT_NOT_UNDERSTOOD, &.{});
    const kind = _hci.le16(data[0..2]);
    var answer: [12]u8 = @splat(0);
    put16(answer[0..2], kind);
    var length: usize = 4;
    switch (kind) {
        l2cap.INFO_EXTENDED_FEATURES => {
            put16(answer[2..4], l2cap.INFO_SUCCESS);
            put32(answer[4..8], l2cap.FEATURE_FIXED_CHANNELS);
            length = 8;
        },
        l2cap.INFO_FIXED_CHANNELS => {
            put16(answer[2..4], l2cap.INFO_SUCCESS);
            put32(answer[4..8], @truncate(l2cap.FIXED_SIGNALING));
            put32(answer[8..12], @truncate(l2cap.FIXED_SIGNALING >> 32));
            length = 12;
        },
        else => put16(answer[2..4], l2cap.INFO_NOT_SUPPORTED),
    }
    respond(layer, connection, cid, l2cap.INFORMATION_RESPONSE, ident, answer[0..length]);
}

/// Connection Request: no channel to its protocol - none, its own
/// channel named back.
fn noProtocol(layer: *Hci, connection: *Connection, ident: u8, data: []const u8) void {
    const cid = l2cap.CID_SIGNALING;
    if (data.len < 4) return reject(layer, connection, cid, ident, l2cap.REJECT_NOT_UNDERSTOOD, &.{});
    var answer: [8]u8 = @splat(0);
    answer[2] = data[2];
    answer[3] = data[3];
    put16(answer[4..6], l2cap.CONNECTION_PSM_NOT_SUPPORTED);
    respond(layer, connection, cid, l2cap.CONNECTION_RESPONSE, ident, &answer);
}

/// LE Credit Based Connection Request: no channel to its protocol.
fn noLeProtocol(layer: *Hci, connection: *Connection, ident: u8, data: []const u8) void {
    const cid = l2cap.CID_LE_SIGNALING;
    if (data.len < 10) return reject(layer, connection, cid, ident, l2cap.REJECT_NOT_UNDERSTOOD, &.{});
    var answer: [10]u8 = @splat(0);
    put16(answer[8..10], l2cap.LE_CONNECTION_PSM_NOT_SUPPORTED);
    respond(layer, connection, cid, l2cap.LE_CREDIT_CONNECTION_RESPONSE, ident, &answer);
}

/// A request for a channel there is not: rejected as such, with the
/// channel it names and - where it has one, `ids` 4 - its own.
fn noChannel(layer: *Hci, connection: *Connection, cid: u16, ident: u8, data: []const u8, ids: usize) void {
    if (data.len < ids) return reject(layer, connection, cid, ident, l2cap.REJECT_NOT_UNDERSTOOD, &.{});
    var channels: [4]u8 = @splat(0);
    channels[0] = data[0];
    channels[1] = data[1];
    if (ids == 4) {
        channels[2] = data[2];
        channels[3] = data[3];
    }
    reject(layer, connection, cid, ident, l2cap.REJECT_INVALID_CID, &channels);
}

/// Connection Parameter Update Request: a peripheral asks its central for
/// other parameters - taken where they are within the bounds and the
/// controller takes the change; a central asked is not one to ask.
fn parameterUpdate(layer: *Hci, connection: *Connection, ident: u8, data: []const u8) void {
    const cid = l2cap.CID_LE_SIGNALING;
    if (!connection.central or data.len < 8) return reject(layer, connection, cid, ident, l2cap.REJECT_NOT_UNDERSTOOD, &.{});
    const min = _hci.le16(data[0..2]);
    const max = _hci.le16(data[2..4]);
    const latency = _hci.le16(data[4..6]);
    const timeout = _hci.le16(data[6..8]);
    const taken = connections.validParameters(min, max, latency, timeout) and
        connections.update(layer, connection, min, max, latency, timeout);
    var answer: [2]u8 = undefined;
    put16(&answer, if (taken) l2cap.PARAMETERS_ACCEPTED else l2cap.PARAMETERS_REJECTED);
    respond(layer, connection, cid, l2cap.CONNECTION_PARAMETER_UPDATE_RESPONSE, ident, &answer);
}

/// A command sent on the signalling channel `cid`: its code, the
/// identifier it answers, and its data.
fn respond(layer: *Hci, connection: *Connection, cid: u16, code: u8, ident: u8, data: []const u8) void {
    var command: [l2cap.L2CAP_COMMAND_HDR + ANSWER_MOST]u8 = undefined;
    const length = @min(data.len, ANSWER_MOST);
    command[0] = code;
    command[1] = ident;
    put16(command[2..4], @intCast(length));
    @memcpy(command[l2cap.L2CAP_COMMAND_HDR..][0..length], data[0..length]);
    _ = _l2cap.send(layer, connection, cid, command[0 .. l2cap.L2CAP_COMMAND_HDR + length]);
}

/// Command Reject: the reason, and what goes with it.
fn reject(layer: *Hci, connection: *Connection, cid: u16, ident: u8, reason: u16, with: []const u8) void {
    var data: [6]u8 = @splat(0);
    put16(data[0..2], reason);
    const length = @min(with.len, 4);
    @memcpy(data[2..][0..length], with[0..length]);
    respond(layer, connection, cid, l2cap.COMMAND_REJECT, ident, data[0 .. 2 + length]);
}

fn put16(into: *[2]u8, value: u16) void {
    into[0] = @truncate(value);
    into[1] = @truncate(value >> 8);
}

fn put32(into: *[4]u8, value: u32) void {
    for (into, 0..) |*byte, index| byte.* = @truncate(value >> @intCast(index * 8));
}
