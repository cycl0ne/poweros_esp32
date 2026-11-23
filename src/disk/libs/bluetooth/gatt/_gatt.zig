// SPDX-License-Identifier: MIT
//! The GATT calls' shared part: ObtainBTCharacteristics's list, made in
//! one block from the records its procedure put in the caller's room
//! (att/client.zig) - the list, a BTCharacteristic each, their
//! descriptors, and the empty name the nodes share.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const att = bluetooth.att;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _att = @import("../att/_att.zig");
const att_client = @import("../att/client.zig");

/// The room the characteristics are gathered in: more than a service has.
pub const ROOM = 16 * 1024;

const CharacteristicRecord = att_client.CharacteristicRecord;
const DescriptorRecord = att_client.DescriptorRecord;
const HEAD = att_client.CHARACTERISTICS_HEAD;

fn roundUp(size: usize, alignment: usize) usize {
    return (size + alignment - 1) / alignment * alignment;
}

/// ObtainBTCharacteristics's list made from `room` - the count, the
/// characteristics' records, the descriptors' - in one block that
/// ReleaseBTCharacteristics frees: 0, BTERR_PROTOCOL for a room not well
/// made, BTERR_NOMEM.
pub fn make(base: *BluetoothBase, room: []const u8, into: *?*exec.List) i32 {
    const sys = base.sys_base;
    if (room.len < HEAD) return bluetooth.BTERR_PROTOCOL;
    const count_at: *align(1) const u16 = @ptrCast(room.ptr);
    const count: usize = count_at.*;
    const records_end = HEAD + count * @sizeOf(CharacteristicRecord);
    if (records_end > room.len or (room.len - records_end) % @sizeOf(DescriptorRecord) != 0) return bluetooth.BTERR_PROTOCOL;
    const descriptor_count = (room.len - records_end) / @sizeOf(DescriptorRecord);
    const nodes_at = roundUp(@sizeOf(exec.List), @alignOf(bluetooth.BTCharacteristic));
    const descriptors_at = roundUp(nodes_at + count * @sizeOf(bluetooth.BTCharacteristic), @alignOf(bluetooth.BTDescriptor));
    const name_at = descriptors_at + descriptor_count * @sizeOf(bluetooth.BTDescriptor);
    const memory = sys.AllocVec(name_at + 1, exec.MEMF_CLEAR) orelse return bluetooth.BTERR_NOMEM;
    const start = @intFromPtr(memory);
    const list: *exec.List = @ptrCast(@alignCast(memory));
    list.init(.unknown);
    const descriptors: [*]bluetooth.BTDescriptor = @ptrFromInt(start + descriptors_at);
    for (0..descriptor_count) |index| {
        const record: *align(1) const DescriptorRecord = @ptrCast(room[records_end + index * @sizeOf(DescriptorRecord) ..].ptr);
        descriptors[index] = .{ .uuid = .{ .bytes = record.uuid }, .uuid16 = _att.short(record.uuid), .handle = record.handle };
    }
    const name: [*:0]const u8 = @ptrFromInt(start + name_at);
    for (0..count) |index| {
        const record: *align(1) const CharacteristicRecord = @ptrCast(room[HEAD + index * @sizeOf(CharacteristicRecord) ..].ptr);
        const first: usize = record.first_descriptor;
        const many: usize = record.descriptor_count;
        if (first + many > descriptor_count) {
            sys.FreeVec(memory);
            return bluetooth.BTERR_PROTOCOL;
        }
        const node: *bluetooth.BTCharacteristic = @ptrFromInt(start + nodes_at + index * @sizeOf(bluetooth.BTCharacteristic));
        node.* = .{
            .uuid = .{ .bytes = record.uuid },
            .uuid16 = _att.short(record.uuid),
            .properties = record.properties,
            .handle = record.handle,
            .value_handle = record.value,
            .end_handle = record.end,
            .descriptors = if (many == 0) null else descriptors + first,
            .descriptor_count = @intCast(many),
        };
        for (descriptors[first..][0..many]) |*descriptor| {
            if (descriptor.uuid16 == att.GATT_CLIENT_CONFIGURATION) {
                node.configuration_handle = descriptor.handle;
                break;
            }
        }
        node.node.name = name;
        sys.AddTail(list, &node.node);
    }
    into.* = list;
    return 0;
}
