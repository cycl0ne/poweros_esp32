// SPDX-License-Identifier: MIT
//! The SDP server: what a device asks on a channel to PSM 1 answered from
//! the machine's records.
//!
//! **The records**: one, the server's own - handle 0, the class Service
//! Discovery Server, reached over L2CAP's PSM 1, in the public browse
//! group, speaking version 1.1, its database's state.
//!
//! **The requests**: ServiceSearch, the handles of the records that hold
//! every UUID of its pattern; ServiceAttribute, a record's attributes in
//! the ids and ranges it names; ServiceSearchAttribute, both at once. A
//! request that is none of them, or is not well made, is answered with
//! an error: its syntax, its size, a handle there is not, a continuation
//! state this server did not give.
//!
//! **In parts.** An answer's attributes longer than the channel's MTU
//! takes, or than the most the device asked for, go in parts: each ends
//! with a continuation state - where the next part begins, 2 bytes - which
//! the device's next request repeats, and the answer is built again from
//! the records for each part. A search's handles always fit one answer.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const sdp = bluetooth.sdp;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const channels = @import("../l2cap/channels.zig");
const Channel = channels.Channel;
const _sdp = @import("_sdp.zig");

/// The room an answer's attributes are built in before they go in parts.
pub const ROOM = 1024;

/// A record the server holds: its handle, and its attributes as one
/// sequence of ids and values, the ids rising.
const Record = struct {
    handle: u32,
    bytes: []const u8,
};

const server_record = _sdp.sequence(&(_sdp.uint16(sdp.ATTR_SERVICE_RECORD_HANDLE) ++ _sdp.uint32(sdp.SDP_SERVER_HANDLE) ++
    _sdp.uint16(sdp.ATTR_SERVICE_CLASS_ID_LIST) ++ _sdp.sequence(&_sdp.uuid16(sdp.UUID_SERVICE_DISCOVERY_SERVER)) ++
    _sdp.uint16(sdp.ATTR_PROTOCOL_DESCRIPTOR_LIST) ++ _sdp.sequence(&(_sdp.sequence(&(_sdp.uuid16(sdp.UUID_L2CAP) ++ _sdp.uint16(bluetooth.l2cap.PSM_SDP))) ++
    _sdp.sequence(&_sdp.uuid16(sdp.UUID_SDP)))) ++
    _sdp.uint16(sdp.ATTR_BROWSE_GROUP_LIST) ++ _sdp.sequence(&_sdp.uuid16(sdp.UUID_PUBLIC_BROWSE_ROOT)) ++
    _sdp.uint16(sdp.ATTR_VERSION_NUMBER_LIST) ++ _sdp.sequence(&_sdp.uint16(sdp.SDP_VERSION)) ++
    _sdp.uint16(sdp.ATTR_SERVICE_DATABASE_STATE) ++ _sdp.uint32(1)));

const records = [_]Record{.{ .handle = sdp.SDP_SERVER_HANDLE, .bytes = &server_record }};

/// A request on a channel to the server: answered.
pub fn received(layer: *Hci, channel: *const Channel, pdu: []const u8) void {
    if (pdu.len < sdp.SDP_HDR) return;
    const transaction = _sdp.be16(pdu[1..3]);
    if (_sdp.be16(pdu[3..5]) != pdu.len - sdp.SDP_HDR) return failure(layer, channel, transaction, sdp.SDP_ERR_INVALID_PDU_SIZE);
    const params = pdu[sdp.SDP_HDR..];
    const result = switch (pdu[0]) {
        sdp.SDP_SERVICE_SEARCH_REQUEST => search(layer, channel, transaction, params),
        sdp.SDP_SERVICE_ATTRIBUTE_REQUEST => attributes(layer, channel, transaction, params),
        sdp.SDP_SERVICE_SEARCH_ATTRIBUTE_REQUEST => searchAttributes(layer, channel, transaction, params),
        else => sdp.SDP_ERR_INVALID_SYNTAX,
    };
    if (result != 0) failure(layer, channel, transaction, result);
}

/// A search pattern read: its UUIDs, 1 to 12, as 128 bits.
const Pattern = struct {
    uuids: [sdp.SDP_PATTERN_MOST][16]u8 = undefined,
    count: usize = 0,

    fn matches(pattern: *const Pattern, record: Record) bool {
        // A record's elements are within its one sequence.
        const whole = _sdp.element(record.bytes) orelse return false;
        for (pattern.uuids[0..pattern.count]) |wanted| {
            if (!_sdp.holds(whole.data, wanted)) return false;
        }
        return true;
    }
};

fn readPattern(item: _sdp.Element) ?Pattern {
    if (item.kind != sdp.DE_SEQUENCE) return null;
    var pattern: Pattern = .{};
    var items = _sdp.itemsOf(item);
    while (items.next()) |one| {
        if (pattern.count == sdp.SDP_PATTERN_MOST) return null;
        pattern.uuids[pattern.count] = _sdp.uuid(one) orelse return null;
        pattern.count += 1;
    }
    if (pattern.count == 0 or items.rest.len != 0) return null;
    return pattern;
}

/// The continuation state that ends a request: its bytes, past their
/// length; null where the request does not end with one whole.
fn continuationOf(rest: []const u8) ?[]const u8 {
    if (rest.len < 1 or rest[0] > sdp.SDP_CONTINUATION_MOST or rest.len != 1 + @as(usize, rest[0])) return null;
    return rest[1..];
}

/// ServiceSearchRequest: the handles of the records that hold the
/// pattern - as many as the device asks for, at most.
fn search(layer: *Hci, channel: *const Channel, transaction: u16, params: []const u8) u16 {
    const pattern_item = _sdp.element(params) orelse return sdp.SDP_ERR_INVALID_SYNTAX;
    const pattern = readPattern(pattern_item) orelse return sdp.SDP_ERR_INVALID_SYNTAX;
    const rest = params[pattern_item.whole..];
    if (rest.len < 2) return sdp.SDP_ERR_INVALID_SYNTAX;
    const most = _sdp.be16(rest[0..2]);
    const continuation = continuationOf(rest[2..]) orelse return sdp.SDP_ERR_INVALID_SYNTAX;
    if (continuation.len != 0) return sdp.SDP_ERR_INVALID_CONTINUATION;
    const pdu = &layer.sdp_pdu;
    var count: u16 = 0;
    var at: usize = sdp.SDP_HDR + 4;
    for (records) |record| {
        if (count == most or !pattern.matches(record)) continue;
        _sdp.put32(pdu[at..][0..4], record.handle);
        at += 4;
        count += 1;
    }
    _sdp.put16(pdu[sdp.SDP_HDR..][0..2], count);
    _sdp.put16(pdu[sdp.SDP_HDR + 2 ..][0..2], count);
    pdu[at] = 0;
    at += 1;
    finishPdu(pdu, sdp.SDP_SERVICE_SEARCH_RESPONSE, transaction, at);
    _ = channels.frame(layer, channel, pdu[0..at]);
    return 0;
}

/// ServiceAttributeRequest: the attributes of the record with the handle
/// it names that its list asks for.
fn attributes(layer: *Hci, channel: *const Channel, transaction: u16, params: []const u8) u16 {
    if (params.len < 6) return sdp.SDP_ERR_INVALID_SYNTAX;
    const handle = _sdp.be32(params[0..4]);
    const most = _sdp.be16(params[4..6]);
    if (most < 7) return sdp.SDP_ERR_INVALID_SYNTAX;
    const ids = _sdp.element(params[6..]) orelse return sdp.SDP_ERR_INVALID_SYNTAX;
    if (!validIds(ids)) return sdp.SDP_ERR_INVALID_SYNTAX;
    const continuation = continuationOf(params[6 + ids.whole ..]) orelse return sdp.SDP_ERR_INVALID_SYNTAX;
    const record = for (records) |one| {
        if (one.handle == handle) break one;
    } else return sdp.SDP_ERR_INVALID_HANDLE;
    const room = &layer.sdp_room;
    const length = filtered(record, ids, room) orelse return sdp.SDP_ERR_INSUFFICIENT_RESOURCES;
    return part(layer, channel, transaction, sdp.SDP_SERVICE_ATTRIBUTE_RESPONSE, room[0..length], most, continuation);
}

/// ServiceSearchAttributeRequest: for each record that holds the
/// pattern, the attributes its list asks for - a sequence of them each,
/// in one sequence.
fn searchAttributes(layer: *Hci, channel: *const Channel, transaction: u16, params: []const u8) u16 {
    const pattern_item = _sdp.element(params) orelse return sdp.SDP_ERR_INVALID_SYNTAX;
    const pattern = readPattern(pattern_item) orelse return sdp.SDP_ERR_INVALID_SYNTAX;
    const rest = params[pattern_item.whole..];
    if (rest.len < 2) return sdp.SDP_ERR_INVALID_SYNTAX;
    const most = _sdp.be16(rest[0..2]);
    if (most < 7) return sdp.SDP_ERR_INVALID_SYNTAX;
    const ids = _sdp.element(rest[2..]) orelse return sdp.SDP_ERR_INVALID_SYNTAX;
    if (!validIds(ids)) return sdp.SDP_ERR_INVALID_SYNTAX;
    const continuation = continuationOf(rest[2 + ids.whole ..]) orelse return sdp.SDP_ERR_INVALID_SYNTAX;
    const room = &layer.sdp_room;
    var length: usize = 3;
    for (records) |record| {
        if (!pattern.matches(record)) continue;
        length += filtered(record, ids, room[length..]) orelse return sdp.SDP_ERR_INSUFFICIENT_RESOURCES;
    }
    _sdp.putSequence16(room[0..3], length - 3);
    return part(layer, channel, transaction, sdp.SDP_SERVICE_SEARCH_ATTRIBUTE_RESPONSE, room[0..length], most, continuation);
}

/// Whether an attribute id list is one: a sequence of ids (16 bits) and
/// ranges of them (32 bits, the first id in the upper half).
fn validIds(ids: _sdp.Element) bool {
    if (ids.kind != sdp.DE_SEQUENCE) return false;
    var items = _sdp.itemsOf(ids);
    var any = false;
    while (items.next()) |item| {
        if (item.kind != sdp.DE_UINT or (item.data.len != 2 and item.data.len != 4)) return false;
        any = true;
    }
    return any and items.rest.len == 0;
}

/// Whether the list asks for attribute `id`.
fn asksFor(ids: _sdp.Element, id: u16) bool {
    var items = _sdp.itemsOf(ids);
    while (items.next()) |item| {
        if (item.data.len == 2) {
            if (_sdp.be16(item.data[0..2]) == id) return true;
        } else {
            const range = _sdp.be32(item.data[0..4]);
            if (id >= range >> 16 and id <= range & 0xFFFF) return true;
        }
    }
    return false;
}

/// The record's attributes the list asks for, as a sequence, into
/// `into`: its length, or null where it does not fit.
fn filtered(record: Record, ids: _sdp.Element, into: []u8) ?usize {
    if (into.len < 3) return null;
    const whole = _sdp.element(record.bytes) orelse return null;
    const body = whole.data;
    var from: usize = 0;
    var at: usize = 3;
    while (from < body.len) {
        const id_item = _sdp.element(body[from..]) orelse break;
        const value = _sdp.element(body[from + id_item.whole ..]) orelse break;
        // The id's element and its value's, as the record has them.
        const both = body[from..][0 .. id_item.whole + value.whole];
        from += both.len;
        const id = _sdp.unsigned(id_item) orelse continue;
        if (id > 0xFFFF or !asksFor(ids, @intCast(id))) continue;
        if (into.len - at < both.len) return null;
        @memcpy(into[at..][0..both.len], both);
        at += both.len;
    }
    _sdp.putSequence16(into[0..3], at - 3);
    return at;
}

/// An answer's attributes sent from where the device's continuation state
/// says - as much as `most` and the channel take, and a continuation
/// state for the rest.
fn part(layer: *Hci, channel: *const Channel, transaction: u16, id: u8, full: []const u8, most: u16, continuation: []const u8) u16 {
    var offset: usize = 0;
    if (continuation.len != 0) {
        if (continuation.len != 2) return sdp.SDP_ERR_INVALID_CONTINUATION;
        offset = _sdp.be16(continuation[0..2]);
        if (offset == 0 or offset >= full.len) return sdp.SDP_ERR_INVALID_CONTINUATION;
    }
    const pdu = &layer.sdp_pdu;
    // Past the header and the count, room for a continuation state.
    const room = @min(@as(usize, channel.mtu_out), pdu.len) - sdp.SDP_HDR - 2 - 3;
    const length = @min(full.len - offset, @as(usize, most), room);
    _sdp.put16(pdu[sdp.SDP_HDR..][0..2], @intCast(length));
    @memcpy(pdu[sdp.SDP_HDR + 2 ..][0..length], full[offset..][0..length]);
    var at = sdp.SDP_HDR + 2 + length;
    if (offset + length < full.len) {
        pdu[at] = 2;
        _sdp.put16(pdu[at + 1 ..][0..2], @intCast(offset + length));
        at += 3;
    } else {
        pdu[at] = 0;
        at += 1;
    }
    finishPdu(pdu, id, transaction, at);
    _ = channels.frame(layer, channel, pdu[0..at]);
    return 0;
}

/// An error answer: its code.
fn failure(layer: *Hci, channel: *const Channel, transaction: u16, code: u16) void {
    var pdu: [sdp.SDP_HDR + 2]u8 = undefined;
    _sdp.put16(pdu[sdp.SDP_HDR..][0..2], code);
    finishPdu(&pdu, sdp.SDP_ERROR_RESPONSE, transaction, pdu.len);
    _ = channels.frame(layer, channel, &pdu);
}

/// A PDU's header written: its id, transaction and the length of what
/// follows, `length` bytes in all.
fn finishPdu(pdu: []u8, id: u8, transaction: u16, length: usize) void {
    pdu[0] = id;
    _sdp.put16(pdu[1..3], transaction);
    _sdp.put16(pdu[3..5], @intCast(length - sdp.SDP_HDR));
}
