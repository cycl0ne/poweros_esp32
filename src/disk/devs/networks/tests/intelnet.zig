// SPDX-License-Identifier: MIT
//! Host tests of what intelnet.device works out before a controller
//! finishes a packet's checksums (`devs/networks/intelnet/checksum.zig`),
//! and of the descriptors that ask it to (`.../ring.zig`).
//!
//! The controller's own part is one addition: it sums the bytes of the
//! transport part, adds in what it finds in the checksum field, and
//! writes the complement there. That is done here in four lines, over
//! the same frame the driver prepared, and the answer has to be the
//! checksum worked out from the packet in the ordinary way. So the
//! arithmetic is proved whole on the host, which no emulator can do: an
//! emulated controller works a checksum out from scratch and a wrong
//! seed goes unnoticed.

const std = @import("std");
const checksum = @import("../intelnet/checksum.zig");
const ring = @import("../intelnet/ring.zig");

const testing = std.testing;

const ethernet_bytes = 14;
const ip_bytes = 20;
const tcp_bytes = 20;
const udp_bytes = 8;

const protocol_tcp = 6;
const protocol_udp = 17;

/// A frame built for a test: an Ethernet header, an IPv4 header and a
/// transport header with `payload` behind it. Both checksum fields are
/// left 0, as an opener that asks the device for them leaves them.
fn frame(into: []u8, protocol: u8, payload: []const u8) []u8 {
    const transport: u32 = if (protocol == protocol_tcp) tcp_bytes else udp_bytes;
    const total: u32 = ip_bytes + transport + @as(u32, @intCast(payload.len));
    const length = ethernet_bytes + total;
    @memset(into[0..length], 0);
    // The addresses, and IPv4 behind them.
    into[0..6].* = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    into[6..12].* = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    into[12] = 0x08;
    into[13] = 0x00;
    const packet = into[ethernet_bytes..length];
    packet[0] = 0x45;
    put16(packet, 2, @intCast(total));
    put16(packet, 4, 0x1234); // the identification
    packet[8] = 64; // time to live
    packet[9] = protocol;
    put32(packet, 12, 0x0A00_020F); // 10.0.2.15
    put32(packet, 16, 0x0A00_0202); // 10.0.2.2
    const part = packet[ip_bytes..];
    put16(part, 0, 4711); // the source port
    put16(part, 2, 80); // and the destination
    if (protocol == protocol_tcp) {
        put32(part, 4, 0x0001_0000); // a sequence number
        part[12] = 0x50; // five words of header
        part[13] = 0x18; // its flags
        put16(part, 14, 8192); // the window
    } else {
        put16(part, 4, @intCast(udp_bytes + payload.len));
    }
    @memcpy(part[transport..][0..payload.len], payload);
    return into[0..length];
}

/// The transport checksum of a frame's packet, worked out the ordinary
/// way: over the pseudo-header and the transport part with its own
/// checksum field zero. This is what the controller has to arrive at.
fn transportChecksum(one: []const u8) u16 {
    const packet = one[ethernet_bytes..];
    const header = packet[0 .. @as(u32, packet[0] & 0xF) * 4];
    const part = packet[header.len..];
    var total: u32 = packet[9]; // the protocol
    total += @intCast(part.len);
    var at: usize = 12;
    while (at < 20) : (at += 2) total += get16(header, at);
    at = 0;
    while (at + 1 < part.len) : (at += 2) {
        if (at != checksumAt(packet[9])) total += get16(part, at);
    }
    if (part.len % 2 == 1) total += @as(u32, part[part.len - 1]) << 8;
    return ~fold(total);
}

/// The IP header's own checksum, over the header with its field zero.
fn headerChecksum(one: []const u8) u16 {
    const packet = one[ethernet_bytes..];
    const header = packet[0 .. @as(u32, packet[0] & 0xF) * 4];
    var total: u32 = 0;
    var at: usize = 0;
    while (at + 1 < header.len) : (at += 2) {
        if (at != 10) total += get16(header, at);
    }
    return ~fold(total);
}

/// What the controller does with the frame the driver prepared: it adds
/// up the transport part - the seeded checksum field among the rest of
/// it - and writes the complement of that into the field.
fn controllerFinishes(one: []u8, headers: checksum.Headers) void {
    const part = one[headers.mac + headers.ip ..];
    var total: u32 = 0;
    var at: usize = 0;
    while (at + 1 < part.len) : (at += 2) total += get16(part, at);
    if (part.len % 2 == 1) total += @as(u32, part[part.len - 1]) << 8;
    put16(part, checksumAt(if (headers.tcp) protocol_tcp else protocol_udp), ~fold(total));
}

fn checksumAt(protocol: u8) usize {
    return if (protocol == protocol_tcp) 16 else 6;
}

fn fold(sum: u32) u16 {
    var left = sum;
    while (left >> 16 != 0) left = (left & 0xFFFF) + (left >> 16);
    return @truncate(left);
}

fn get16(bytes: []const u8, at: usize) u32 {
    return @as(u32, bytes[at]) << 8 | bytes[at + 1];
}

fn put16(bytes: []u8, at: usize, value: u16) void {
    bytes[at] = @truncate(value >> 8);
    bytes[at + 1] = @truncate(value);
}

fn put32(bytes: []u8, at: usize, value: u32) void {
    put16(bytes, at, @truncate(value >> 16));
    put16(bytes, at + 2, @truncate(value));
}

/// The whole of it for one packet: the frame prepared, the controller's
/// part done over it, and both checksums the same as the ordinary way
/// works them out.
fn checkOnePacket(protocol: u8, payload: []const u8) !void {
    var bytes: [1600]u8 = undefined;
    const one = frame(&bytes, protocol, payload);
    const wanted_transport = transportChecksum(one);
    const wanted_header = headerChecksum(one);

    const headers = checksum.seed(one) orelse return error.NotPrepared;
    try testing.expectEqual(@as(u32, ethernet_bytes), headers.mac);
    try testing.expectEqual(@as(u32, ip_bytes), headers.ip);
    try testing.expectEqual(protocol == protocol_tcp, headers.tcp);
    // The IP header's checksum is the driver's own work, finished.
    try testing.expectEqual(wanted_header, @as(u16, @intCast(get16(one[ethernet_bytes..], 10))));
    controllerFinishes(one, headers);
    const part = one[ethernet_bytes + ip_bytes ..];
    try testing.expectEqual(wanted_transport, @as(u16, @intCast(get16(part, checksumAt(protocol)))));
}

test "intelnet: a TCP packet's checksums come out right" {
    try checkOnePacket(protocol_tcp, "hello");
    try checkOnePacket(protocol_tcp, &[_]u8{0} ** 1460);
    try checkOnePacket(protocol_tcp, &[_]u8{0xFF} ** 1460);
    try checkOnePacket(protocol_tcp, "");
    // An odd length, where the last byte stands alone in its word.
    try checkOnePacket(protocol_tcp, &[_]u8{ 1, 2, 3 });
}

test "intelnet: a UDP packet's checksums come out right" {
    try checkOnePacket(protocol_udp, "hello");
    try checkOnePacket(protocol_udp, &[_]u8{0xA5} ** 1472);
    try checkOnePacket(protocol_udp, "");
    try checkOnePacket(protocol_udp, &[_]u8{ 9, 8, 7, 6, 5 });
}

test "intelnet: every byte of a payload tells" {
    // The same packet with one byte changed has a different checksum, so
    // the sum really covers the payload and not only the headers.
    var first: [1600]u8 = undefined;
    var second: [1600]u8 = undefined;
    var payload: [64]u8 = @splat(0);
    const one = frame(&first, protocol_tcp, &payload);
    payload[33] = 1;
    const other = frame(&second, protocol_tcp, &payload);
    const left = checksum.seed(one).?;
    const right = checksum.seed(other).?;
    controllerFinishes(one, left);
    controllerFinishes(other, right);
    const at = ethernet_bytes + ip_bytes + 16;
    try testing.expect(get16(one, at) != get16(other, at));
}

test "intelnet: a packet the controller cannot finish is left alone" {
    var bytes: [1600]u8 = undefined;

    // A fragment: its transport part is not whole.
    var one = frame(&bytes, protocol_tcp, "hello");
    put16(one[ethernet_bytes..], 6, 0x2000); // more fragments
    try testing.expect(checksum.seed(one) == null);

    // Neither TCP nor UDP.
    one = frame(&bytes, protocol_tcp, "hello");
    one[ethernet_bytes + 9] = 1; // ICMP
    try testing.expect(checksum.seed(one) == null);

    // Not IPv4 at all.
    one = frame(&bytes, protocol_tcp, "hello");
    one[12] = 0x86;
    one[13] = 0xDD;
    try testing.expect(checksum.seed(one) == null);

    // A frame with bytes behind the packet: the controller would add
    // those in too, so this one is sent as it came.
    one = frame(&bytes, protocol_tcp, "hello");
    try testing.expect(checksum.seed(bytes[0 .. one.len + 4]) == null);

    // Shorter than the headers it claims.
    one = frame(&bytes, protocol_tcp, "hello");
    try testing.expect(checksum.seed(one[0..20]) == null);

    // A header length under the least a header can be.
    one = frame(&bytes, protocol_tcp, "hello");
    one[ethernet_bytes] = 0x44;
    try testing.expect(checksum.seed(one) == null);

    // Nothing was written into a frame that was left alone: this one's
    // checksum fields are still the zeroes it was built with.
    one = frame(&bytes, protocol_tcp, "hello");
    one[ethernet_bytes + 9] = 1;
    try testing.expect(checksum.seed(one) == null);
    try testing.expectEqual(@as(u32, 0), get16(one[ethernet_bytes..], 10));
    try testing.expectEqual(@as(u32, 0), get16(one[ethernet_bytes + ip_bytes ..], 16));
}

test "intelnet: the descriptors that ask for it" {
    var descriptor: ring.Transmit = .{};
    const view: *const ring.Context = @ptrCast(&descriptor);

    ring.context(&descriptor, 14, 20, true);
    try testing.expectEqual(@as(u32, 14 << 9 | 20), view.lengths);
    // A context descriptor of the advanced kind, carrying TCP.
    try testing.expectEqual(@as(u32, 0x2020_0800), view.kind);
    try testing.expectEqual(@as(u32, 0), view.seed);
    try testing.expectEqual(@as(u32, 0), view.segment);

    ring.context(&descriptor, 14, 24, false);
    try testing.expectEqual(@as(u32, 14 << 9 | 24), view.lengths);
    try testing.expectEqual(@as(u32, 0x2020_0000), view.kind);

    // The frame's own descriptor: the option bit set only when asked.
    ring.send(&descriptor, 0x1234_5678, 100, true);
    try testing.expectEqual(@as(u32, 100 << 14 | 0x200), descriptor.status);
    ring.send(&descriptor, 0x1234_5678, 100, false);
    try testing.expectEqual(@as(u32, 100 << 14), descriptor.status);
    try testing.expectEqual(@as(u32, 0x1234_5678), descriptor.address_low);
    try testing.expectEqual(@as(u32, 0), descriptor.address_high);
}
