// SPDX-License-Identifier: MIT
//! Joining and leaving a network, and what the station is joined to
//! (sdk/devices/wireless.zig).
//!
//! **S2_SETOPTIONS** with S2INFO_SSID (and S2INFO_Passphrase for a
//! protected network, S2INFO_BSSID for one access point of it) hands the
//! libraries the station's settings and starts the join: they scan for
//! the network, take its strongest access point and associate. A
//! passphrase also has its pairwise master key made here, before the
//! request is answered, because the key handshake runs on the libraries'
//! task and cannot spend PBKDF2's rounds there. The request is answered at
//! once. The join's outcome is the link: the
//! unit's carrier comes when the station has joined (STA_CONNECTED), and
//! goes when it leaves or is thrown off. S2INFO_Disassociate leaves.
//!
//! **S2_GETNETWORKINFO** answers, while the station is joined, the
//! network's name, its access point, the channel and the signal, as a
//! tag list in the caller's pool; S2ERR_OUTOFSERVICE while it is not.

const sdk = @import("sdk");
const net = sdk.devices.network;
const wireless = sdk.devices.wireless;
const TagItem = sdk.utility.TagItem;
const _wifi = @import("_wifi.zig");
const WifiBase = _wifi.WifiBase;
const vendor = @import("vendor.zig");
const scan = @import("scan.zig");
const supplicant = @import("wpa/supplicant.zig");

fn copyString(into: []u8, text: [*:0]const u8) ?usize {
    var length: usize = 0;
    while (text[length] != 0) : (length += 1) {
        if (length == into.len) return null;
        into[length] = text[length];
    }
    return length;
}

/// S2_SETOPTIONS: join, or leave. Answers an error code for the request.
pub fn setOptions(base: *WifiBase, req: *net.IOSana2Req) i8 {
    const utility = base.utility.?;
    const tags: ?[*]const TagItem = @ptrCast(@alignCast(req.data));
    const list = tags orelse return net.S2ERR_BAD_ARGUMENT;
    if (utility.FindTagItem(wireless.S2INFO_Disassociate, list) != null) {
        _ = vendor.esp_wifi_disconnect_internal();
        return 0;
    }
    const ssid: ?[*:0]const u8 = @ptrFromInt(utility.GetTagData(wireless.S2INFO_SSID, 0, list));
    const name = ssid orelse return net.S2ERR_BAD_ARGUMENT;
    var config: vendor.StaConfig = .{};
    const name_length = copyString(&config.ssid, name) orelse return net.S2ERR_BAD_ARGUMENT;
    if (name_length == 0) return net.S2ERR_BAD_ARGUMENT;
    const passphrase: ?[*:0]const u8 = @ptrFromInt(utility.GetTagData(wireless.S2INFO_Passphrase, 0, list));
    if (passphrase) |text| {
        // 8 to 63 characters, or 64 hex digits of the key itself; the
        // libraries keep it NUL-terminated.
        const length = copyString(config.password[0..63], text) orelse (copyString(&config.password, text) orelse return net.S2ERR_BAD_ARGUMENT);
        if (length < 8) return net.S2ERR_BAD_ARGUMENT;
        config.threshold.authmode = vendor.auth_wpa2_psk;
        // The pairwise master key is made here rather than when the
        // libraries ask to associate: PBKDF2's rounds are 8192 hashes, and
        // their task cannot be held up for them.
        if (!supplicant.makePmk(base, config.ssid[0..name_length], config.password[0..length])) {
            return net.S2ERR_SOFTWARE;
        }
    }
    const bssid: ?[*]const u8 = @ptrFromInt(utility.GetTagData(wireless.S2INFO_BSSID, 0, list));
    if (bssid) |address| {
        @memcpy(&config.bssid, address[0..6]);
        config.bssid_set = true;
    }
    _ = vendor.esp_wifi_disconnect_internal();
    if (vendor.esp_wifi_set_config(vendor.if_sta, &config) != vendor.ok) return net.S2ERR_BAD_ARGUMENT;
    if (vendor.esp_wifi_connect_internal() != vendor.ok) return net.S2ERR_SOFTWARE;
    return 0;
}

/// Where the reason is in the data of a station-disconnected event
/// (the network's name, its length, the access point's address, then the
/// reason).
const reason_offset = 32 + 1 + 6;

/// Why the station is off a network, in words for the reasons a join runs
/// into and as a number for the rest.
fn reasonName(reason: u8) ?[*:0]const u8 {
    return switch (reason) {
        1 => "unspecified",
        2 => "the authentication expired",
        3 => "deauthenticated, because one end is leaving",
        8 => "disassociated, because one end is leaving",
        13 => "a security element was refused",
        14 => "a message integrity check failed",
        15 => "the 4-way handshake timed out",
        16 => "the group key handshake timed out",
        17 => "the RSN element of the 4-way handshake differed",
        18 => "the group cipher was refused",
        19 => "the pairwise cipher was refused",
        20 => "the key management was refused",
        23, 202 => "the authentication failed",
        24 => "the cipher suite was refused",
        200 => "the beacons stopped",
        201 => "no access point of that name was found",
        203 => "the association failed",
        204 => "the handshake timed out",
        205 => "the connection failed",
        210 => "no access point with a security it can use",
        211 => "no access point meeting the security asked for",
        212 => "no access point near enough",
        else => null,
    };
}

/// The station is off a network, or never got on one. Said once: a wrong
/// passphrase (the 4-way handshake timing out) reads differently from a
/// network out of reach, and nothing else tells them apart.
pub fn left(base: *WifiBase, data: []const u8) void {
    const reason: u8 = if (data.len > reason_offset) data[reason_offset] else 0;
    const sys = base.sys_base;
    if (reasonName(reason)) |text| {
        sdk.exec.kprintf(sys, "%s: off the network: %s (%u)\n", .{ _wifi.DEVICE_NAME, text, @as(u32, reason) });
    } else {
        sdk.exec.kprintf(sys, "%s: off the network: reason %u\n", .{ _wifi.DEVICE_NAME, @as(u32, reason) });
    }
}

/// S2_GETNETWORKINFO: the network joined, as one tag list.
pub fn networkInfo(base: *WifiBase, req: *net.IOSana2Req) i8 {
    if (base.net.carrier == 0) {
        req.wire_error = net.S2WERR_UNIT_OFFLINE;
        return net.S2ERR_OUTOFSERVICE;
    }
    var record: vendor.ApRecord = undefined;
    if (vendor.esp_wifi_sta_get_ap_info(&record) != vendor.ok) {
        req.wire_error = net.S2WERR_UNIT_OFFLINE;
        return net.S2ERR_OUTOFSERVICE;
    }
    const sys = base.sys_base;
    const tag_count = 6;
    const memory: [*]u8 = @ptrCast(sys.AllocPooled(req.data, tag_count * @sizeOf(TagItem) + 33 + 6) orelse return net.S2ERR_NO_RESOURCES);
    const tags: [*]TagItem = @ptrCast(@alignCast(memory));
    const name = memory + tag_count * @sizeOf(TagItem);
    var length: usize = 0;
    while (length < 32 and record.ssid[length] != 0) length += 1;
    @memcpy(name[0..length], record.ssid[0..length]);
    name[length] = 0;
    const address = name + 33;
    @memcpy(address[0..6], &record.bssid);
    tags[0] = .{ .tag = wireless.S2INFO_SSID, .data = @intFromPtr(name) };
    tags[1] = .{ .tag = wireless.S2INFO_BSSID, .data = @intFromPtr(address) };
    tags[2] = .{ .tag = wireless.S2INFO_Channel, .data = record.primary };
    tags[3] = .{ .tag = wireless.S2INFO_Signal, .data = @bitCast(@as(isize, record.rssi)) };
    tags[4] = .{ .tag = wireless.S2INFO_AuthMode, .data = scan.authMode(record.authmode) };
    tags[5] = .{};
    req.stat_data = @ptrCast(tags);
    return 0;
}
