// SPDX-License-Identifier: MIT
//! S2_GETNETWORKS: a scan, and its networks as tag lists in the caller's
//! pool (sdk/devices/wireless.zig).
//!
//! One scan runs at a time. A request that comes while one runs waits for
//! it and is answered with the same networks; one that names an SSID gets
//! only the networks with that name. The libraries post SCAN_DONE when
//! the radio has been round every channel (about two seconds); the
//! records are fetched then, into the work block, and each waiting
//! request is answered from them.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const wireless = sdk.devices.wireless;
const TagItem = sdk.utility.TagItem;
const _wifi = @import("_wifi.zig");
const WifiBase = _wifi.WifiBase;
const vendor = @import("vendor.zig");

/// The most networks one scan answers.
pub const max_networks = 24;
/// Tags per network, with the end.
const tags_per_network = 7;

pub fn authMode(mode: c_uint) u32 {
    return switch (mode) {
        vendor.auth_open => wireless.S2AUTH_OPEN,
        vendor.auth_wep => wireless.S2AUTH_WEP,
        vendor.auth_wpa_psk => wireless.S2AUTH_WPA_PSK,
        vendor.auth_wpa2_psk => wireless.S2AUTH_WPA2_PSK,
        vendor.auth_wpa_wpa2_psk => wireless.S2AUTH_WPA_WPA2_PSK,
        vendor.auth_wpa3_psk => wireless.S2AUTH_WPA3_PSK,
        vendor.auth_wpa2_wpa3_psk => wireless.S2AUTH_WPA2_WPA3_PSK,
        vendor.auth_enterprise, vendor.auth_wpa3_enterprise, vendor.auth_wpa2_wpa3_enterprise, vendor.auth_wpa_enterprise => wireless.S2AUTH_ENTERPRISE,
        else => wireless.S2AUTH_OTHER,
    };
}

/// The cipher for a network's traffic, or null for one the extension
/// has no name for.
pub fn encryption(cipher: c_uint) ?u32 {
    return switch (cipher) {
        vendor.cipher_none => wireless.S2ENC_NONE,
        vendor.cipher_wep40, vendor.cipher_wep104 => wireless.S2ENC_WEP,
        vendor.cipher_tkip => wireless.S2ENC_TKIP,
        vendor.cipher_ccmp, vendor.cipher_tkip_ccmp => wireless.S2ENC_CCMP,
        else => null,
    };
}

fn ssidLength(ssid: *const [33]u8) usize {
    var length: usize = 0;
    while (length < 32 and ssid[length] != 0) length += 1;
    return length;
}

fn sameName(record: *const vendor.ApRecord, wanted: ?[*:0]const u8) bool {
    const name = wanted orelse return true;
    const length = ssidLength(&record.ssid);
    for (0..length) |i| if (name[i] != record.ssid[i]) return false;
    return name[length] == 0;
}

/// A scan started, or joined if one runs. False if the libraries refuse.
pub fn begin(base: *WifiBase, req: *net.IOSana2Req) bool {
    const sys = base.sys_base;
    if (base.scanning == 0) {
        if (vendor.esp_wifi_scan_start(null, false) != vendor.ok) return false;
        base.scanning = 1;
    }
    req.req.flags &= ~exec.IOF_QUICK;
    sys.AddTail(&base.scans, &req.req.message.node);
    return true;
}

/// One request answered from the records.
fn answer(base: *WifiBase, req: *net.IOSana2Req, records: []const vendor.ApRecord) void {
    const sys = base.sys_base;
    const pool = req.data;
    const params: ?[*]const TagItem = @ptrCast(@alignCast(req.stat_data));
    const wanted: ?[*:0]const u8 = if (params) |list|
        @ptrFromInt(base.utility.?.GetTagData(wireless.S2INFO_SSID, 0, list))
    else
        null;
    var count: usize = 0;
    for (records) |*record| {
        if (sameName(record, wanted)) count += 1;
    }
    req.data_length = 0;
    const lists: [*]?[*]TagItem = @ptrCast(@alignCast(sys.AllocPooled(pool, @max(count, 1) * @sizeOf(usize)) orelse {
        req.req.err = net.S2ERR_NO_RESOURCES;
        return;
    }));
    var made: usize = 0;
    for (records) |*record| {
        if (!sameName(record, wanted)) continue;
        const tags: [*]TagItem = @ptrCast(@alignCast(sys.AllocPooled(pool, tags_per_network * @sizeOf(TagItem) + 33 + 6) orelse break));
        const ssid: [*]u8 = @as([*]u8, @ptrCast(tags)) + tags_per_network * @sizeOf(TagItem);
        const length = ssidLength(&record.ssid);
        @memcpy(ssid[0..length], record.ssid[0..length]);
        ssid[length] = 0;
        const bssid = ssid + 33;
        @memcpy(bssid[0..6], &record.bssid);
        var at: usize = 0;
        tags[at] = .{ .tag = wireless.S2INFO_SSID, .data = @intFromPtr(ssid) };
        at += 1;
        tags[at] = .{ .tag = wireless.S2INFO_BSSID, .data = @intFromPtr(bssid) };
        at += 1;
        tags[at] = .{ .tag = wireless.S2INFO_Channel, .data = record.primary };
        at += 1;
        tags[at] = .{ .tag = wireless.S2INFO_Signal, .data = @bitCast(@as(isize, record.rssi)) };
        at += 1;
        tags[at] = .{ .tag = wireless.S2INFO_AuthMode, .data = authMode(record.authmode) };
        at += 1;
        if (encryption(record.pairwise_cipher)) |value| {
            tags[at] = .{ .tag = wireless.S2INFO_Encryption, .data = value };
            at += 1;
        }
        tags[at] = .{};
        lists[made] = tags;
        made += 1;
    }
    req.stat_data = @ptrCast(lists);
    req.data_length = @intCast(made);
}

/// SCAN_DONE: the records fetched, and every waiting request answered.
pub fn done(base: *WifiBase) void {
    const sys = base.sys_base;
    const work = base.work.?;
    base.scanning = 0;
    var number: u16 = max_networks;
    if (vendor.esp_wifi_scan_get_ap_records(&number, &work.networks) != vendor.ok) number = 0;
    const records = work.networks[0..number];
    while (sys.RemHead(&base.scans)) |node| {
        const msg: *exec.Message = @alignCast(@fieldParentPtr("node", node));
        const req = _wifi.sanaReq(_wifi.requestOf(msg));
        answer(base, req, records);
        sys.ReplyMsg(msg);
    }
}
