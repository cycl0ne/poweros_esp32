// SPDX-License-Identifier: MIT
//! The network device API's layout (sdk/devices/network.zig): every
//! driver and every opener are built against it separately, so a field
//! that moves breaks them apart silently. The offsets are written in
//! terms of a pointer's size, so they hold on the host and on the chip.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;

const ptr = @sizeOf(usize);

test "IOSana2Req: the fields after the IORequest" {
    const base = @sizeOf(exec.IORequest);
    try std.testing.expectEqual(base, @offsetOf(net.IOSana2Req, "wire_error"));
    try std.testing.expectEqual(base + 4, @offsetOf(net.IOSana2Req, "packet_type"));
    try std.testing.expectEqual(base + 8, @offsetOf(net.IOSana2Req, "src_addr"));
    try std.testing.expectEqual(base + 24, @offsetOf(net.IOSana2Req, "dst_addr"));
    try std.testing.expectEqual(base + 40, @offsetOf(net.IOSana2Req, "data_length"));
    const data = std.mem.alignForward(usize, base + 44, ptr);
    try std.testing.expectEqual(data, @offsetOf(net.IOSana2Req, "data"));
    try std.testing.expectEqual(data + ptr, @offsetOf(net.IOSana2Req, "stat_data"));
    try std.testing.expectEqual(data + 2 * ptr, @offsetOf(net.IOSana2Req, "buffer_management"));
    try std.testing.expectEqual(data + 3 * ptr, @sizeOf(net.IOSana2Req));
}

test "the address arrays hold the longest address" {
    try std.testing.expectEqual(16, net.SANA2_MAX_ADDR_BYTES);
    try std.testing.expectEqual(net.SANA2_MAX_ADDR_BYTES, @typeInfo(@FieldType(net.IOSana2Req, "src_addr")).array.len);
}

test "the statistics are whole words with no gaps" {
    try std.testing.expectEqual(24, @offsetOf(net.Sana2DeviceQuery, "bps"));
    try std.testing.expectEqual(36, @offsetOf(net.Sana2DeviceQuery, "raw_mtu"));
    try std.testing.expectEqual(40, @sizeOf(net.Sana2DeviceQuery));
    try std.testing.expectEqual(16, @offsetOf(net.Sana2PacketTypeStats, "bytes_sent"));
    try std.testing.expectEqual(40, @sizeOf(net.Sana2PacketTypeStats));
    try std.testing.expectEqual(40, @offsetOf(net.Sana2DeviceStats, "reconfigurations"));
    try std.testing.expectEqual(44, @offsetOf(net.Sana2DeviceStats, "last_start"));
    try std.testing.expectEqual(52, @sizeOf(net.Sana2DeviceStats));
    try std.testing.expectEqual(8, @sizeOf(net.Sana2SpecialStatHeader));
    try std.testing.expectEqual(8 + ptr, @sizeOf(net.Sana2SpecialStatRecord));
}

test "the commands and tags keep their numbers" {
    try std.testing.expectEqual(exec.CMD_NONSTD, net.S2_DEVICEQUERY);
    try std.testing.expectEqual(exec.CMD_NONSTD + 17, net.S2_OFFLINE);
    try std.testing.expectEqual(0x800B_0001, net.S2_CopyToBuff);
    try std.testing.expectEqual(0x800B_0003, net.S2_PacketFilter);
}
