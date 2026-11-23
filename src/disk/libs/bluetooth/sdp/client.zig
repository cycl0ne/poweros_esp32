// SPDX-License-Identifier: MIT
//! The SDP client: ObtainBTServices's query. Over a channel to the
//! device's PSM 1, opened for it (l2cap/channels.zig), one
//! ServiceSearchAttributeRequest asks for every record that names L2CAP,
//! with all of its attributes; the answer's parts are followed by their
//! continuation states and gathered into the caller's room, then the
//! channel is closed. One query a controller at a time.
//!
//! **Its end**: the records whole - the call answered 0, the task reading
//! how much came - or the device's error (BTERR_PROTOCOL), more than the
//! room holds (BTERR_NOMEM), no answer within ANSWER_WAIT_MS
//! (BTERR_TIMEOUT), or its channel's or link's end, with why.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const l2cap = bluetooth.l2cap;
const sdp = bluetooth.sdp;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const connections = @import("../hci/connections.zig");
const channels = @import("../l2cap/channels.zig");
const Channel = channels.Channel;
const _sdp = @import("_sdp.zig");

/// How long each answer is waited for.
pub const ANSWER_WAIT_MS: u32 = 10_000;

pub const State = enum(u8) { idle, opening, asking, done };

/// A controller's query.
pub const Query = struct {
    state: State = .idle,
    address: bluetooth.BTAddress = .{},
    /// Its channel, by its serial.
    serial: u32 = 0,
    transaction: u16 = 0,
    /// The continuation state the next request repeats, its length first.
    continuation: [1 + sdp.SDP_CONTINUATION_MOST]u8 = @splat(0),
    /// The caller's room, and how much of it the records fill.
    into: []u8 = &.{},
    have: usize = 0,
    deadline: ?u64 = null,
};

/// The most attribute bytes an answer is asked to carry: what a frame of
/// MTU_IN holds past the answer's header, count and the longest
/// continuation state.
const ASK_MOST: u16 = channels.MTU_IN - sdp.SDP_HDR - 2 - 1 - sdp.SDP_CONTINUATION_MOST;

/// ObtainBTServices: the records of the device at `address` asked for
/// into `into`, a channel to its PSM 1 opened first - the call's wait, or
/// why not at once.
pub fn query(layer: *Hci, address: bluetooth.BTAddress, into: []u8) connections.Begun {
    const asking = &layer.sdp_query;
    if (asking.state != .idle) return .{ .done = bluetooth.BTERR_BUSY };
    if (!connections.canWait(layer)) return .{ .done = bluetooth.BTERR_NOMEM };
    const channel = switch (channels.begin(layer, address, l2cap.PSM_SDP, .sdp_client)) {
        .channel => |made| made,
        .failed => |result| return .{ .done = result },
    };
    asking.* = .{ .state = .opening, .address = address, .serial = channel.serial, .into = into };
    return connections.waitFor(layer, .services, address);
}

/// The query's channel open: the first request sent.
pub fn opened(layer: *Hci, channel: *Channel) void {
    const asking = &layer.sdp_query;
    if (asking.state != .opening or channel.serial != asking.serial) return;
    asking.state = .asking;
    ask(layer, channel);
}

/// The request sent, with the continuation state the last answer ended
/// with.
fn ask(layer: *Hci, channel: *Channel) void {
    const asking = &layer.sdp_query;
    asking.transaction +%= 1;
    const pattern = _sdp.sequence(&_sdp.uuid16(sdp.UUID_L2CAP));
    const ids = _sdp.sequence(&_sdp.uint32(0x0000_FFFF));
    var pdu: [sdp.SDP_HDR + pattern.len + 2 + ids.len + 1 + sdp.SDP_CONTINUATION_MOST]u8 = undefined;
    var at: usize = sdp.SDP_HDR;
    @memcpy(pdu[at..][0..pattern.len], &pattern);
    at += pattern.len;
    _sdp.put16(pdu[at..][0..2], ASK_MOST);
    at += 2;
    @memcpy(pdu[at..][0..ids.len], &ids);
    at += ids.len;
    const state_length = 1 + @as(usize, asking.continuation[0]);
    @memcpy(pdu[at..][0..state_length], asking.continuation[0..state_length]);
    at += state_length;
    pdu[0] = sdp.SDP_SERVICE_SEARCH_ATTRIBUTE_REQUEST;
    _sdp.put16(pdu[1..3], asking.transaction);
    _sdp.put16(pdu[3..5], @intCast(at - sdp.SDP_HDR));
    if (!channels.frame(layer, channel, pdu[0..at])) return finish(layer, channel, bluetooth.BTERR_NOMEM);
    asking.deadline = layer.now + ANSWER_WAIT_MS;
}

/// A frame on the query's channel: its part of the answer gathered, and
/// the next part asked for - or the query over.
pub fn received(layer: *Hci, channel: *Channel, pdu: []const u8) void {
    const asking = &layer.sdp_query;
    if (asking.state != .asking or channel.serial != asking.serial) return;
    // Not the answer to the request out.
    if (pdu.len < sdp.SDP_HDR or _sdp.be16(pdu[1..3]) != asking.transaction) return;
    const params = pdu[sdp.SDP_HDR..];
    if (pdu[0] != sdp.SDP_SERVICE_SEARCH_ATTRIBUTE_RESPONSE or _sdp.be16(pdu[3..5]) != params.len or params.len < 3) {
        return finish(layer, channel, bluetooth.BTERR_PROTOCOL);
    }
    const count: usize = _sdp.be16(params[0..2]);
    if (params.len - 2 < count + 1) return finish(layer, channel, bluetooth.BTERR_PROTOCOL);
    const piece = params[2..][0..count];
    const continuation = params[2 + count ..];
    const state_length: usize = continuation[0];
    if (state_length > sdp.SDP_CONTINUATION_MOST or continuation.len != 1 + state_length) return finish(layer, channel, bluetooth.BTERR_PROTOCOL);
    if (asking.into.len - asking.have < piece.len) return finish(layer, channel, bluetooth.BTERR_NOMEM);
    @memcpy(asking.into[asking.have..][0..piece.len], piece);
    asking.have += piece.len;
    if (state_length == 0) return finish(layer, channel, 0);
    @memcpy(asking.continuation[0 .. 1 + state_length], continuation);
    ask(layer, channel);
}

/// The query over with `result`: its call answered, its channel closed.
fn finish(layer: *Hci, channel: *Channel, result: i32) void {
    const asking = &layer.sdp_query;
    asking.state = .done;
    asking.deadline = null;
    connections.answerServices(layer, asking.address, result);
    channels.close(layer, channel, 0);
}

/// The query's channel ended, for `result`: the query, while it runs,
/// ended with it - a channel the device closes before the answer is
/// whole as one it refused.
pub fn channelGone(layer: *Hci, channel: *const Channel, result: i32) void {
    const asking = &layer.sdp_query;
    if (channel.serial != asking.serial) return;
    if (asking.state != .opening and asking.state != .asking) return;
    asking.state = .done;
    asking.deadline = null;
    connections.answerServices(layer, asking.address, if (result == 0) bluetooth.BTERR_REFUSED else result);
}

/// The task has read the query's end: the controller can query again.
pub fn release(layer: *Hci) void {
    layer.sdp_query = .{};
}

/// A query whose answer is not in by its time given up.
pub fn tick(layer: *Hci) void {
    const asking = &layer.sdp_query;
    const due = asking.deadline orelse return;
    if (layer.now < due) return;
    asking.deadline = null;
    const channel = channels.bySerial(layer, asking.serial) orelse return;
    finish(layer, channel, bluetooth.BTERR_TIMEOUT);
}

pub fn deadline(layer: *const Hci) ?u64 {
    return layer.sdp_query.deadline;
}
