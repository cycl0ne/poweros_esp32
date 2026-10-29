// SPDX-License-Identifier: MIT
//! The firmware's events, for cyw43455.device: what it tells the host
//! unasked - a scan's networks, a join's progress, the link - as Linux's
//! brcmfmac reads them.
//!
//! **An event** comes as a packet on the event channel, now and then on
//! the data channel: behind a BCDC header, an Ethernet frame of
//! Broadcom's own type (0x886C), Broadcom's header - its OUI and the
//! subtype that says event - and the event itself, big-endian: what
//! happened, its status and reason, the station it is about, and its
//! data. Data packets have the same BCDC header in front of their
//! Ethernet frame.
//!
//! **Which events come** is the firmware's event mask, a bit per event,
//! which the host reads, sets bits in and writes back (`enable`).

const std = @import("std");
const _cyw = @import("_cyw43455.zig");
const host_file = @import("host.zig");
const bcdc = @import("bcdc.zig");
const CywBase = _cyw.CywBase;
const Error = host_file.Error;

/// The events the device takes.
pub const E_SET_SSID: u32 = 0;
pub const E_DEAUTH: u32 = 5;
pub const E_DEAUTH_IND: u32 = 6;
pub const E_DISASSOC_IND: u32 = 12;
pub const E_LINK: u32 = 16;
pub const E_IF: u32 = 54;
pub const E_ESCAN_RESULT: u32 = 69;

/// An event's statuses: done, failed, and - for a scan - more to come.
pub const STATUS_SUCCESS: u32 = 0;
pub const STATUS_FAIL: u32 = 1;
pub const STATUS_PARTIAL: u32 = 8;
/// E_LINK's flag: the link is up.
pub const FLAG_LINK: u16 = 1;

/// The Ethernet type of Broadcom's packets, their OUI and the subtype of
/// an event.
const ETHER_TYPE_BRCM: u16 = 0x886C;
const oui = [3]u8{ 0x00, 0x10, 0x18 };
const SUBTYPE_EVENT: u16 = 1;
/// Where the event is in its packet - past the Ethernet header and
/// Broadcom's - and where its data starts.
const event_at = 14 + 10;
const data_at = event_at + 48;

/// The firmware's event mask: a bit for each of its events. Linux's
/// length, which covers every event it knows.
const mask_bytes = 24;

/// An event: what happened, its status and reason, the flags, the
/// station it is about, and its data.
pub const Event = struct {
    kind: u32,
    status: u32,
    reason: u32,
    flags: u16,
    address: [6]u8,
    data: []const u8,
};

/// The packet a data or event frame's payload carries: past the BCDC
/// header and the words the firmware put after it. Null when the payload
/// is too short for them.
pub fn packetOf(payload: []u8) ?[]u8 {
    if (payload.len < 4) return null;
    const start = 4 + @as(usize, payload[3]) * 4;
    if (start > payload.len) return null;
    return payload[start..];
}

/// The event `packet` is, or null when it is none.
pub fn parse(packet: []const u8) ?Event {
    if (packet.len < data_at) return null;
    if (std.mem.readInt(u16, packet[12..14], .big) != ETHER_TYPE_BRCM) return null;
    if (!std.mem.eql(u8, packet[19..22], &oui)) return null;
    if (std.mem.readInt(u16, packet[22..24], .big) != SUBTYPE_EVENT) return null;
    const event = packet[event_at..data_at];
    const length = std.mem.readInt(u32, event[20..24], .big);
    if (length > packet.len - data_at) return null;
    return .{
        .kind = std.mem.readInt(u32, event[4..8], .big),
        .status = std.mem.readInt(u32, event[8..12], .big),
        .reason = std.mem.readInt(u32, event[12..16], .big),
        .flags = std.mem.readInt(u16, event[2..4], .big),
        .address = event[24..30].*,
        .data = packet[data_at..][0..length],
    };
}

/// Whether `packet`, an Ethernet frame, is one of Broadcom's - an event,
/// and no frame for the unit.
pub fn isBroadcom(packet: []const u8) bool {
    return packet.len >= 14 and std.mem.readInt(u16, packet[12..14], .big) == ETHER_TYPE_BRCM;
}

/// The events in `kinds` added to those the firmware sends: its status.
pub fn enable(base: *CywBase, kinds: []const u32) Error!i32 {
    var mask: [mask_bytes]u8 = @splat(0);
    const got = try bcdc.getVar(base, "event_msgs", &mask);
    if (got != 0) return got;
    for (kinds) |kind| mask[kind / 8] |= @as(u8, 1) << @intCast(kind % 8);
    return bcdc.setVar(base, "event_msgs", &mask);
}
