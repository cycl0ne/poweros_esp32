// SPDX-License-Identifier: MIT
//! GATT's server over a controller's LE links: the attributes the
//! library serves - GAP's service, with the machine's name and its
//! appearance, and GATT's, with Service Changed - and the requests a
//! device's client sends answered from them.
//!
//! **The attributes** are fixed, handles 1 to LAST, every type one of
//! 16 bits. GAP's Device Name is the controller's name (BTCA_Name) as it
//! is at the request; its Appearance a computer's. Service Changed is
//! never indicated - the attributes do not change - and its configuration
//! is kept for the link as the device's client writes it.
//!
//! **The requests answered**: Exchange MTU, Find Information, Find By
//! Type Value, Read By Type, Read, Read Blob, Read By Group Type of the
//! primary services, and a Write Request - or Write Command - to
//! Service Changed's configuration; each answer cut to the link's MTU.
//! Any other request is answered that it is not supported; any other
//! command is let go.
//!
//! Pure, as the rest of the layer.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const att = bluetooth.att;
const _hci = @import("../hci/_hci.zig");
const Hci = _hci.Hci;
const connections = @import("../hci/connections.zig");
const Connection = connections.Connection;
const _att = @import("_att.zig");
const le16 = _att.le16;
const put16 = _att.put16;

/// An opcode's bit that makes it a command, which is never answered.
const COMMAND_FLAG: u8 = 0x40;
/// The longest entry a Read By Type answer carries: its length is a byte.
const ENTRY_MOST: usize = 255;

const Attribute = struct {
    type16: u16,
    /// Its value where it is fixed; null for one read from the layer or
    /// the link.
    value: ?[]const u8 = null,
    readable: bool = true,
    writable: bool = false,
    /// A service's declaration: the last handle of the service.
    group_end: u16 = 0,
};

fn bytes16(comptime value: u16) [2]u8 {
    return .{ @truncate(value), @truncate(value >> 8) };
}

/// A characteristic's declaration: its properties, its value's handle,
/// its type.
fn declaration(comptime properties: u8, comptime value_handle: u16, comptime type16: u16) [5]u8 {
    return .{ properties, @truncate(value_handle), @truncate(value_handle >> 8), @truncate(type16), @truncate(type16 >> 8) };
}

const gap_service = bytes16(att.GATT_SERVICE_GAP);
const gatt_service = bytes16(att.GATT_SERVICE_GATT);
const name_declaration = declaration(att.GATT_PROP_READ, 3, att.GATT_DEVICE_NAME);
const appearance_declaration = declaration(att.GATT_PROP_READ, 5, att.GATT_APPEARANCE);
const appearance = bytes16(att.APPEARANCE_COMPUTER);
const changed_declaration = declaration(att.GATT_PROP_INDICATE, 8, att.GATT_SERVICE_CHANGED);

/// The attributes, handle 1 first.
const attributes = [_]Attribute{
    .{ .type16 = att.GATT_PRIMARY_SERVICE, .value = &gap_service, .group_end = 5 },
    .{ .type16 = att.GATT_CHARACTERISTIC, .value = &name_declaration },
    .{ .type16 = att.GATT_DEVICE_NAME },
    .{ .type16 = att.GATT_CHARACTERISTIC, .value = &appearance_declaration },
    .{ .type16 = att.GATT_APPEARANCE, .value = &appearance },
    .{ .type16 = att.GATT_PRIMARY_SERVICE, .value = &gatt_service, .group_end = 9 },
    .{ .type16 = att.GATT_CHARACTERISTIC, .value = &changed_declaration },
    .{ .type16 = att.GATT_SERVICE_CHANGED, .readable = false },
    .{ .type16 = att.GATT_CLIENT_CONFIGURATION, .writable = true },
};

/// The last handle served.
pub const LAST: u16 = attributes.len;

fn attributeOf(handle: u16) *const Attribute {
    return &attributes[handle - 1];
}

/// A request or command of the device's client answered.
pub fn received(layer: *Hci, connection: *Connection, pdu: []const u8) void {
    switch (pdu[0]) {
        att.ATT_EXCHANGE_MTU_REQ => exchange(layer, connection, pdu),
        att.ATT_FIND_INFORMATION_REQ => findInformation(layer, connection, pdu),
        att.ATT_FIND_BY_TYPE_VALUE_REQ => findByTypeValue(layer, connection, pdu),
        att.ATT_READ_BY_TYPE_REQ => readByType(layer, connection, pdu),
        att.ATT_READ_REQ, att.ATT_READ_BLOB_REQ => read(layer, connection, pdu),
        att.ATT_READ_BY_GROUP_TYPE_REQ => readByGroupType(layer, connection, pdu),
        att.ATT_WRITE_REQ, att.ATT_WRITE_CMD => write(layer, connection, pdu),
        else => |opcode| if (opcode & COMMAND_FLAG == 0) refuse(layer, connection, opcode, 0, att.ATT_ERR_REQUEST_NOT_SUPPORTED),
    }
}

/// The request with `opcode` refused, for the attribute `handle`.
fn refuse(layer: *Hci, connection: *const Connection, opcode: u8, handle: u16, code: u8) void {
    var answer: [5]u8 = .{ att.ATT_ERROR_RSP, opcode, 0, 0, code };
    put16(answer[2..4], handle);
    _ = _att.send(layer, connection, &answer);
}

/// Exchange MTU: this machine's said, the smaller of the two kept.
fn exchange(layer: *Hci, connection: *Connection, pdu: []const u8) void {
    if (pdu.len != 3) return refuse(layer, connection, pdu[0], 0, att.ATT_ERR_INVALID_PDU);
    var answer: [3]u8 = .{ att.ATT_EXCHANGE_MTU_RSP, 0, 0 };
    put16(answer[1..3], _att.MTU_OURS);
    // Answered at the MTU the request came with.
    _ = _att.send(layer, connection, &answer);
    connection.att.mtu = _att.agreed(le16(pdu[1..3]));
}

/// A request's range of handles - false, refused, for one that is none.
fn range(layer: *Hci, connection: *const Connection, pdu: []const u8, start: *u16, end: *u16) bool {
    start.* = le16(pdu[1..3]);
    end.* = le16(pdu[3..5]);
    if (start.* == 0 or start.* > end.*) {
        refuse(layer, connection, pdu[0], start.*, att.ATT_ERR_INVALID_HANDLE);
        return false;
    }
    return true;
}

/// Find Information: each attribute in the range, its handle and type.
fn findInformation(layer: *Hci, connection: *const Connection, pdu: []const u8) void {
    if (pdu.len != 5) return refuse(layer, connection, pdu[0], 0, att.ATT_ERR_INVALID_PDU);
    var start: u16 = 0;
    var end: u16 = 0;
    if (!range(layer, connection, pdu, &start, &end)) return;
    const answer = &layer.att_pdu;
    answer[0] = att.ATT_FIND_INFORMATION_RSP;
    answer[1] = att.ATT_FORMAT_UUID16;
    var at: usize = 2;
    var handle = start;
    while (handle <= @min(end, LAST) and at + 4 <= connection.att.mtu) : (handle += 1) {
        put16(answer[at..][0..2], handle);
        put16(answer[at + 2 ..][0..2], attributeOf(handle).type16);
        at += 4;
    }
    if (at == 2) return refuse(layer, connection, pdu[0], start, att.ATT_ERR_ATTRIBUTE_NOT_FOUND);
    _ = _att.send(layer, connection, answer[0..at]);
}

/// Find By Type Value: each attribute in the range of that type with
/// that value, its handle and its group's end.
fn findByTypeValue(layer: *Hci, connection: *const Connection, pdu: []const u8) void {
    if (pdu.len < 7) return refuse(layer, connection, pdu[0], 0, att.ATT_ERR_INVALID_PDU);
    var start: u16 = 0;
    var end: u16 = 0;
    if (!range(layer, connection, pdu, &start, &end)) return;
    const wanted_type = le16(pdu[5..7]);
    const wanted = pdu[7..];
    const answer = &layer.att_pdu;
    answer[0] = att.ATT_FIND_BY_TYPE_VALUE_RSP;
    var at: usize = 1;
    var room: [2]u8 = undefined;
    var handle = start;
    while (handle <= @min(end, LAST) and at + 4 <= connection.att.mtu) : (handle += 1) {
        const attribute = attributeOf(handle);
        if (attribute.type16 != wanted_type) continue;
        const value = valueOf(layer, connection, handle, &room) orelse continue;
        if (!same(value, wanted)) continue;
        put16(answer[at..][0..2], handle);
        put16(answer[at + 2 ..][0..2], if (attribute.group_end != 0) attribute.group_end else handle);
        at += 4;
    }
    if (at == 1) return refuse(layer, connection, pdu[0], start, att.ATT_ERR_ATTRIBUTE_NOT_FOUND);
    _ = _att.send(layer, connection, answer[0..at]);
}

/// The 16 bits a request's type is - one of 16 bits, or of 128 on the
/// base - or null for one of 128 that is not.
fn typeOf(bytes: []const u8) ?u16 {
    if (bytes.len == 2) return le16(bytes);
    const full = _att.uuidOf(bytes);
    const value = _att.short(full);
    return if (value == 0) null else value;
}

/// Read By Type: each attribute in the range of that type, its handle and
/// value - all the same length, as the first one's.
fn readByType(layer: *Hci, connection: *const Connection, pdu: []const u8) void {
    if (pdu.len != 7 and pdu.len != 21) return refuse(layer, connection, pdu[0], 0, att.ATT_ERR_INVALID_PDU);
    var start: u16 = 0;
    var end: u16 = 0;
    if (!range(layer, connection, pdu, &start, &end)) return;
    const wanted_type = typeOf(pdu[5..]) orelse return refuse(layer, connection, pdu[0], start, att.ATT_ERR_ATTRIBUTE_NOT_FOUND);
    const mtu = connection.att.mtu;
    const answer = &layer.att_pdu;
    answer[0] = att.ATT_READ_BY_TYPE_RSP;
    var at: usize = 2;
    var each: usize = 0;
    var room: [2]u8 = undefined;
    var handle = start;
    while (handle <= @min(end, LAST)) : (handle += 1) {
        if (attributeOf(handle).type16 != wanted_type) continue;
        const value = valueOf(layer, connection, handle, &room) orelse {
            if (each == 0) return refuse(layer, connection, pdu[0], handle, att.ATT_ERR_READ_NOT_PERMITTED);
            break;
        };
        const cut = value[0..@min(value.len, mtu - 4, ENTRY_MOST - 2)];
        if (each == 0) {
            each = 2 + cut.len;
        } else if (2 + cut.len != each) break;
        if (at + each > mtu) break;
        put16(answer[at..][0..2], handle);
        @memcpy(answer[at + 2 ..][0..cut.len], cut);
        at += each;
    }
    if (each == 0) return refuse(layer, connection, pdu[0], start, att.ATT_ERR_ATTRIBUTE_NOT_FOUND);
    answer[1] = @intCast(each);
    _ = _att.send(layer, connection, answer[0..at]);
}

/// Read and Read Blob: the attribute's value, from the offset asked for.
fn read(layer: *Hci, connection: *const Connection, pdu: []const u8) void {
    const blob = pdu[0] == att.ATT_READ_BLOB_REQ;
    if (pdu.len != @as(usize, if (blob) 5 else 3)) return refuse(layer, connection, pdu[0], 0, att.ATT_ERR_INVALID_PDU);
    const handle = le16(pdu[1..3]);
    if (handle == 0 or handle > LAST) return refuse(layer, connection, pdu[0], handle, att.ATT_ERR_INVALID_HANDLE);
    var room: [2]u8 = undefined;
    const value = valueOf(layer, connection, handle, &room) orelse return refuse(layer, connection, pdu[0], handle, att.ATT_ERR_READ_NOT_PERMITTED);
    const offset: usize = if (blob) le16(pdu[3..5]) else 0;
    if (offset > value.len) return refuse(layer, connection, pdu[0], handle, att.ATT_ERR_INVALID_OFFSET);
    const part = value[offset..][0..@min(value.len - offset, connection.att.mtu - 1)];
    const answer = &layer.att_pdu;
    answer[0] = if (blob) att.ATT_READ_BLOB_RSP else att.ATT_READ_RSP;
    @memcpy(answer[1..][0..part.len], part);
    _ = _att.send(layer, connection, answer[0 .. 1 + part.len]);
}

/// Read By Group Type: each primary service in the range, its first and
/// last handle and its type.
fn readByGroupType(layer: *Hci, connection: *const Connection, pdu: []const u8) void {
    if (pdu.len != 7 and pdu.len != 21) return refuse(layer, connection, pdu[0], 0, att.ATT_ERR_INVALID_PDU);
    var start: u16 = 0;
    var end: u16 = 0;
    if (!range(layer, connection, pdu, &start, &end)) return;
    const group = typeOf(pdu[5..]) orelse 0;
    switch (group) {
        att.GATT_PRIMARY_SERVICE => {},
        // None served.
        att.GATT_SECONDARY_SERVICE => return refuse(layer, connection, pdu[0], start, att.ATT_ERR_ATTRIBUTE_NOT_FOUND),
        else => return refuse(layer, connection, pdu[0], start, att.ATT_ERR_UNSUPPORTED_GROUP_TYPE),
    }
    const answer = &layer.att_pdu;
    answer[0] = att.ATT_READ_BY_GROUP_TYPE_RSP;
    answer[1] = 6;
    var at: usize = 2;
    var handle = start;
    while (handle <= @min(end, LAST) and at + 6 <= connection.att.mtu) : (handle += 1) {
        const attribute = attributeOf(handle);
        if (attribute.type16 != att.GATT_PRIMARY_SERVICE) continue;
        put16(answer[at..][0..2], handle);
        put16(answer[at + 2 ..][0..2], attribute.group_end);
        @memcpy(answer[at + 4 ..][0..2], attribute.value.?);
        at += 6;
    }
    if (at == 2) return refuse(layer, connection, pdu[0], start, att.ATT_ERR_ATTRIBUTE_NOT_FOUND);
    _ = _att.send(layer, connection, answer[0..at]);
}

/// A Write Request - answered - or a Write Command - never: Service
/// Changed's configuration kept for the link.
fn write(layer: *Hci, connection: *Connection, pdu: []const u8) void {
    const request = pdu[0] == att.ATT_WRITE_REQ;
    if (pdu.len < 3) {
        if (request) refuse(layer, connection, pdu[0], 0, att.ATT_ERR_INVALID_PDU);
        return;
    }
    const handle = le16(pdu[1..3]);
    const value = pdu[3..];
    const code: u8 = if (handle == 0 or handle > LAST)
        att.ATT_ERR_INVALID_HANDLE
    else if (!attributeOf(handle).writable)
        att.ATT_ERR_WRITE_NOT_PERMITTED
    else if (value.len != 2)
        att.ATT_ERR_INVALID_VALUE_LENGTH
    else
        0;
    if (code != 0) {
        if (request) refuse(layer, connection, pdu[0], handle, code);
        return;
    }
    connection.att.service_changed = le16(value);
    if (request) _ = _att.send(layer, connection, &.{att.ATT_WRITE_RSP});
}

/// An attribute's value, `room` holding it where it is the link's; null
/// for one that may not be read.
fn valueOf(layer: *const Hci, connection: *const Connection, handle: u16, room: *[2]u8) ?[]const u8 {
    const attribute = attributeOf(handle);
    if (!attribute.readable) return null;
    return switch (attribute.type16) {
        att.GATT_DEVICE_NAME => nameOf(layer),
        att.GATT_CLIENT_CONFIGURATION => {
            put16(room, connection.att.service_changed);
            return room;
        },
        else => attribute.value.?,
    };
}

/// The controller's name, up to its end.
fn nameOf(layer: *const Hci) []const u8 {
    var length: usize = 0;
    while (length < layer.name.len and layer.name[length] != 0) length += 1;
    return layer.name[0..length];
}

fn same(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a_byte, b_byte| {
        if (a_byte != b_byte) return false;
    }
    return true;
}
