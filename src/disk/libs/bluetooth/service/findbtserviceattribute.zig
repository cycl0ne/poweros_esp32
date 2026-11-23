// SPDX-License-Identifier: MIT
//! FindBTServiceAttribute: one attribute of a record read.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const sdp = bluetooth.sdp;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _sdp = @import("../sdp/_sdp.zig");
const _service = @import("_service.zig");

/// Reads the value of one of a record's attributes.
///
/// SYNOPSIS:
/// ```zig
/// fn FindBTServiceAttribute(base: *BluetoothBase, record: [*]const u8,
///     length: u32, id: u32, element: *bluetooth.BTDataElement) bool
/// ```
///
/// SINCE: 1.9. LVO -168.
///
/// INPUTS:
/// - `record`, `length` - a record: a sequence of attribute ids each
///   followed by its value (BTService.record and record_length).
/// - `id` - the attribute (sdp.ATTR_*, or a profile's own).
/// - `element` - filled in with its value.
///
/// RESULT:
/// True with `element` filled in; false where the record has no such
/// attribute, or the bytes are not a record - `element` then left as it
/// was.
///
/// BEHAVIOR:
/// The record's attributes are read in turn until the one with the id;
/// its value is described in `element` as NextBTDataElement describes an
/// element. Nothing is read past `length`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `element.data` points into the record; nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `NextBTDataElement`, `ObtainBTServices`
///
/// EXAMPLES:
/// ```zig
/// var name: bluetooth.BTDataElement = .{};
/// if (bt.FindBTServiceAttribute(service.record.?, service.record_length, sdp.ATTR_SERVICE_NAME, &name) and name.kind == sdp.DE_TEXT) {
///     _ = dos.Write(output, name.data.?, name.length);
/// }
/// ```
pub fn FindBTServiceAttribute(_: *BluetoothBase, record: [*]const u8, length: u32, id: u32, element: *bluetooth.BTDataElement) bool {
    const whole = _sdp.element(record[0..length]) orelse return false;
    if (whole.kind != sdp.DE_SEQUENCE) return false;
    var pairs = _service.Pairs{ .rest = whole.data };
    while (pairs.next()) |pair| {
        if (pair.id != id) continue;
        _service.describe(pair.value, element);
        return true;
    }
    return false;
}
