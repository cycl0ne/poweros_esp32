// SPDX-License-Identifier: MIT
//! AddBTService: a record of a program's own served by the SDP server.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const sdp = bluetooth.sdp;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _sdp = @import("../sdp/_sdp.zig");
const _service = @import("_service.zig");

/// Serves a record of the program's own: the SDP server answers devices
/// with it beside its own.
///
/// SYNOPSIS:
/// ```zig
/// fn AddBTService(base: *BluetoothBase, record: [*]const u8, length: u32) ?*bluetooth.BTRecord
/// ```
///
/// SINCE: 1.9. LVO -172.
///
/// INPUTS:
/// - `record`, `length` - the record: a sequence of attribute ids, each
///   a 16-bit unsigned integer followed by its value, the ids rising
///   (sdk.bluetooth.sdp) - the service's classes, its protocols, its
///   profile and what the profile adds.
///
/// RESULT:
/// The record, for RemBTService; null for no memory, for bytes that are
/// not a record whole, and for a record of more than 2048 bytes as it is
/// served.
///
/// BEHAVIOR:
/// The record is copied and given a handle of its own - from
/// sdp.SDP_HANDLE_FIRST on, never one another record has - as its
/// attribute 0x0000, in place of any the bytes name. Until RemBTService
/// the SDP server answers every controller's devices with it, after its
/// own record and those added before it: a device's search finds it by
/// the UUIDs it holds, and its attributes are read in the parts the
/// device asks for.
///
/// CONTEXT:
/// - Waits: yes, for the records' list.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The bytes stay the caller's: the record served is a copy, the
/// library's. The handle is the caller's until RemBTService, which gives
/// it back before the library is closed.
///
/// NOTES:
/// A record says what a service is and where it is reached; its PSMs are
/// served with AddBTListener. Answers hold 4 KiB of records' attributes
/// at most: a device's search that asks for more is told the server has
/// no room.
///
/// BUGS:
/// The server's record says its database's state is 1, always: a device
/// that keeps what it read by that state does not see records added or
/// given back.
///
/// SEE ALSO:
/// `RemBTService`, `AddBTListener`, `ObtainBTServices`
///
/// EXAMPLES:
/// ```zig
/// // A service of the class 0x1101, reached over L2CAP's PSM 0x1001.
/// const record = [_]u8{
///     0x35, 0x15,
///     0x09, 0x00, 0x01, 0x35, 0x03, 0x19, 0x11, 0x01,
///     0x09, 0x00, 0x04, 0x35, 0x08, 0x35, 0x06, 0x19, 0x01, 0x00, 0x09, 0x10, 0x01,
/// };
/// const served = bt.AddBTService(&record, record.len) orelse return;
/// defer bt.RemBTService(served);
/// ```
pub fn AddBTService(base: *BluetoothBase, record: [*]const u8, length: u32) ?*bluetooth.BTRecord {
    const given = record[0..length];
    const whole = _sdp.element(given) orelse return null;
    if (whole.kind != sdp.DE_SEQUENCE or whole.whole != given.len) return null;
    // Its attributes: each id a 16-bit integer, rising, with a value -
    // what they take without a handle of their own.
    var attributes: usize = 0;
    var last: ?u16 = null;
    var rest = whole.data;
    while (rest.len > 0) {
        const id_item = _sdp.element(rest) orelse return null;
        if (id_item.kind != sdp.DE_UINT or id_item.data.len != 2) return null;
        const value = _sdp.element(rest[id_item.whole..]) orelse return null;
        const id = _sdp.be16(id_item.data[0..2]);
        if (last) |before| {
            if (id <= before) return null;
        }
        last = id;
        if (id != sdp.ATTR_SERVICE_RECORD_HANDLE) attributes += id_item.whole + value.whole;
        rest = rest[id_item.whole + value.whole ..];
    }
    const served = 3 + handle_attribute.len + attributes;
    if (served > _service.RECORD_MOST) return null;
    const sys = base.sys_base;
    const memory = sys.AllocVec(@sizeOf(_service.Record) + served, 0) orelse return null;
    const kept: *_service.Record = @ptrCast(@alignCast(memory));
    sys.ObtainSemaphore(&base.records_lock);
    defer sys.ReleaseSemaphore(&base.records_lock);
    kept.* = .{ .handle = sdp.SDP_HANDLE_FIRST +% base.record_number, .length = @intCast(served) };
    base.record_number +%= 1;
    const bytes = kept.bytes();
    _sdp.putSequence16(bytes[0..3], served - 3);
    @memcpy(bytes[3..][0..handle_attribute.len], &handle_attribute);
    _sdp.put32(bytes[3 + handle_attribute.len - 4 ..][0..4], kept.handle);
    var at: usize = 3 + handle_attribute.len;
    rest = whole.data;
    while (rest.len > 0) {
        const id_item = _sdp.element(rest).?;
        const value = _sdp.element(rest[id_item.whole..]).?;
        const both = rest[0 .. id_item.whole + value.whole];
        rest = rest[both.len..];
        if (_sdp.be16(id_item.data[0..2]) == sdp.ATTR_SERVICE_RECORD_HANDLE) continue;
        @memcpy(bytes[at..][0..both.len], both);
        at += both.len;
    }
    sys.AddTail(&base.records, &kept.node);
    return @ptrCast(kept);
}

/// The handle's attribute, its value written in.
const handle_attribute = _sdp.uint16(sdp.ATTR_SERVICE_RECORD_HANDLE) ++ _sdp.uint32(0);
