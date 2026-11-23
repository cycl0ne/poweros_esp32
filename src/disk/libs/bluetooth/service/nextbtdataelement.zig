// SPDX-License-Identifier: MIT
//! NextBTDataElement: one data element of a record read.

const sdk = @import("sdk");
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _sdp = @import("../sdp/_sdp.zig");
const _service = @import("_service.zig");

/// Reads the data element some bytes begin with.
///
/// SYNOPSIS:
/// ```zig
/// fn NextBTDataElement(base: *BluetoothBase, data: [*]const u8, length: u32,
///     element: *bluetooth.BTDataElement) bool
/// ```
///
/// SINCE: 1.9. LVO -164.
///
/// INPUTS:
/// - `data`, `length` - the bytes: a record (BTService.record), an
///   attribute's value, a sequence's data, or what is left of it.
/// - `element` - filled in.
///
/// RESULT:
/// True with `element` filled in; false where the bytes do not begin with
/// a data element whole - nothing read past `length` - `element` then
/// left as it was.
///
/// BEHAVIOR:
/// `kind` is the element's type (sdp.DE_*); `data` and `length` its data
/// past its descriptor and its length, within the bytes given; `whole`
/// the bytes it takes in all, so that the next element begins `whole` on.
/// An unsigned integer's or a boolean's value of up to 8 bytes is in
/// `value`, a signed integer's with its sign kept (`@bitCast` to `i64`);
/// a UUID of 16, 32 or 128 bits is in `uuid` as 128 bits, the shorter
/// ones on the base UUID. A sequence's or an alternative's elements are
/// read by calling again on its `data`, from one element to the next.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `element.data` points into the bytes given; nothing is allocated.
///
/// NOTES:
/// What a profile reads of a device's record that ObtainBTServices does
/// not: a HID device's descriptor (sdk.bluetooth.sdp), an audio sink's
/// features.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FindBTServiceAttribute`, `ObtainBTServices`
///
/// EXAMPLES:
/// ```zig
/// // The elements of a sequence, one after the other.
/// var list: bluetooth.BTDataElement = .{};
/// if (!bt.FindBTServiceAttribute(service.record.?, service.record_length, sdp.ATTR_PROFILE_DESCRIPTOR_LIST, &list)) return;
/// var at: u32 = 0;
/// var item: bluetooth.BTDataElement = .{};
/// while (at < list.length and bt.NextBTDataElement(list.data.? + at, list.length - at, &item)) : (at += item.whole) {
///     // item.kind, item.value, item.uuid
/// }
/// ```
pub fn NextBTDataElement(_: *BluetoothBase, data: [*]const u8, length: u32, element: *bluetooth.BTDataElement) bool {
    const read = _sdp.element(data[0..length]) orelse return false;
    _service.describe(read, element);
    return true;
}
