// SPDX-License-Identifier: MIT
//! A scan, for cyw43455.device: the firmware told to listen on every
//! channel its CLM data allows ("escan", as Linux's brcmfmac asks for
//! it), and the networks its results are.
//!
//! **The results** come as events (events.zig): one for each access point
//! heard, its status PARTIAL, then one with the status the scan ended
//! with. Each holds the firmware's record of the access point - its
//! address, name, capability, channel, signal - and the elements of its
//! beacon or probe response, of which the RSN element, and Microsoft's
//! WPA one, say how it is protected (`Network`).

const std = @import("std");
const sdk = @import("sdk");
const wireless = sdk.devices.wireless;

/// The escan request's version and its action, and the scan parameters'
/// defaults: any kind of network, active, every channel.
const ESCAN_VERSION: u32 = 1;
const ESCAN_ACTION_START: u16 = 1;
const BSSTYPE_ANY: u8 = 2;
const SCANTYPE_ACTIVE: u8 = 0;
/// The request: its header, then the scan parameters without a channel
/// list.
pub const request_bytes = 8 + 64;

/// The escan request with the ID its results will carry.
pub fn request(sync_id: u16) [request_bytes]u8 {
    var params: [request_bytes]u8 = @splat(0);
    std.mem.writeInt(u32, params[0..4], ESCAN_VERSION, .little);
    std.mem.writeInt(u16, params[4..6], ESCAN_ACTION_START, .little);
    std.mem.writeInt(u16, params[6..8], sync_id, .little);
    const scan = params[8..];
    // No name (offsets 0 to 36): every network.
    @memset(scan[36..42], 0xFF);
    scan[42] = BSSTYPE_ANY;
    scan[43] = SCANTYPE_ACTIVE;
    // Probes, dwell times and the home channel's: the firmware's own.
    for (0..4) |field| std.mem.writeInt(i32, scan[44 + field * 4 ..][0..4], -1, .little);
    // No channels listed (60): all of them.
    return params;
}

pub const ssid_max = 32;
pub const rsn_max = 64;

/// A network a scan heard.
pub const Network = struct {
    ssid: [ssid_max]u8 = @splat(0),
    ssid_len: u8 = 0,
    bssid: [6]u8 = @splat(0),
    channel: u8 = 0,
    rssi: i8 = 0,
    /// The capability's privacy bit: it is protected somehow.
    privacy: bool = false,
    /// Its RSN element, whole (id and length too); empty for none.
    rsn: [rsn_max]u8 = @splat(0),
    rsn_len: u8 = 0,
    /// A WPA element (the older, vendor's one) beside it.
    wpa: bool = false,

    pub fn name(heard: *const Network) []const u8 {
        return heard.ssid[0..heard.ssid_len];
    }

    /// How a station proves it may join (`wireless.S2AUTH_*`).
    pub fn authMode(heard: *const Network) u32 {
        const suites = rsnSuites(heard.rsn[0..heard.rsn_len]) orelse {
            if (heard.wpa) return wireless.S2AUTH_WPA_PSK;
            return if (heard.privacy) wireless.S2AUTH_WEP else wireless.S2AUTH_OPEN;
        };
        if (suites.psk and suites.sae) return wireless.S2AUTH_WPA2_WPA3_PSK;
        if (suites.sae) return wireless.S2AUTH_WPA3_PSK;
        if (suites.psk) return if (heard.wpa) wireless.S2AUTH_WPA_WPA2_PSK else wireless.S2AUTH_WPA2_PSK;
        if (suites.dot1x) return wireless.S2AUTH_ENTERPRISE;
        return wireless.S2AUTH_OTHER;
    }

    /// The cipher for its traffic (`wireless.S2ENC_*`).
    pub fn encryption(heard: *const Network) u32 {
        if (rsnSuites(heard.rsn[0..heard.rsn_len])) |suites| {
            if (suites.ccmp) return wireless.S2ENC_CCMP;
            if (suites.tkip) return wireless.S2ENC_TKIP;
        }
        if (heard.wpa) return wireless.S2ENC_TKIP;
        return if (heard.privacy) wireless.S2ENC_WEP else wireless.S2ENC_NONE;
    }
};

/// What an RSN element offers: the pairwise ciphers, whether its group
/// cipher is TKIP, and the key managements this device tells apart.
pub const Suites = struct {
    ccmp: bool = false,
    tkip: bool = false,
    group_tkip: bool = false,
    psk: bool = false,
    sae: bool = false,
    dot1x: bool = false,
};

/// The suites of RSN element `element` (its id and length on), null when
/// there is none or it is cut short.
pub fn rsnSuites(element: []const u8) ?Suites {
    if (element.len < 2 + 2 + 4 + 2) return null;
    const body = element[2..];
    var suites = Suites{};
    suites.group_tkip = isRsnSuite(body[2..6]) and body[5] == 2;
    var at: usize = 2 + 4;
    const pairwise = std.mem.readInt(u16, body[at..][0..2], .little);
    at += 2;
    for (0..pairwise) |_| {
        if (at + 4 > body.len) return null;
        if (isRsnSuite(body[at..][0..4])) switch (body[at + 3]) {
            2 => suites.tkip = true,
            4 => suites.ccmp = true,
            else => {},
        };
        at += 4;
    }
    if (at + 2 > body.len) return suites;
    const managements = std.mem.readInt(u16, body[at..][0..2], .little);
    at += 2;
    for (0..managements) |_| {
        if (at + 4 > body.len) return null;
        if (isRsnSuite(body[at..][0..4])) switch (body[at + 3]) {
            1, 5 => suites.dot1x = true,
            2, 6 => suites.psk = true,
            8 => suites.sae = true,
            else => {},
        };
        at += 4;
    }
    return suites;
}

fn isRsnSuite(suite: *const [4]u8) bool {
    return suite[0] == 0x00 and suite[1] == 0x0F and suite[2] == 0xAC;
}

/// The firmware's record of an access point: where its fields are, and
/// how long its fixed part is.
const BSS_LENGTH = 4;
const BSS_BSSID = 8;
const BSS_CAPABILITY = 16;
const BSS_SSID_LEN = 18;
const BSS_SSID = 19;
const BSS_CHANSPEC = 72;
const BSS_RSSI = 78;
const BSS_CTL_CH = 88;
const BSS_IE_OFFSET = 116;
const BSS_IE_LENGTH = 120;
const bss_fixed = 128;
const CAPABILITY_PRIVACY: u16 = 0x0010;

/// The escan result's header, before its records: its length, version,
/// sync ID and how many records.
const RESULT_SYNC_ID = 8;
const RESULT_BSS_COUNT = 10;
const result_header = 12;

/// The networks in an E_ESCAN_RESULT's data, into `heard`; the sync ID
/// they carry.
pub fn results(data: []const u8, heard: *Heard) ?u16 {
    if (data.len < result_header) return null;
    const sync_id = std.mem.readInt(u16, data[RESULT_SYNC_ID..][0..2], .little);
    const count = std.mem.readInt(u16, data[RESULT_BSS_COUNT..][0..2], .little);
    var at: usize = result_header;
    for (0..count) |_| {
        if (at + bss_fixed > data.len) break;
        const length = std.mem.readInt(u32, data[at + BSS_LENGTH ..][0..4], .little);
        if (length < bss_fixed or length > data.len - at) break;
        if (network(data[at..][0..length])) |found| heard.add(found);
        at += length;
    }
    return sync_id;
}

/// The network the firmware's record `bss` is, or null when it is cut
/// short.
pub fn network(bss: []const u8) ?Network {
    if (bss.len < bss_fixed) return null;
    var found = Network{};
    found.bssid = bss[BSS_BSSID..][0..6].*;
    found.privacy = std.mem.readInt(u16, bss[BSS_CAPABILITY..][0..2], .little) & CAPABILITY_PRIVACY != 0;
    const ssid_len = @min(bss[BSS_SSID_LEN], ssid_max);
    @memcpy(found.ssid[0..ssid_len], bss[BSS_SSID..][0..ssid_len]);
    found.ssid_len = ssid_len;
    const rssi = std.mem.readInt(i16, bss[BSS_RSSI..][0..2], .little);
    found.rssi = @intCast(std.math.clamp(rssi, -128, 127));
    found.channel = bss[BSS_CTL_CH];
    if (found.channel == 0) found.channel = controlChannel(std.mem.readInt(u16, bss[BSS_CHANSPEC..][0..2], .little));
    const ie_offset = std.mem.readInt(u16, bss[BSS_IE_OFFSET..][0..2], .little);
    const ie_length = std.mem.readInt(u32, bss[BSS_IE_LENGTH..][0..4], .little);
    if (ie_offset > bss.len or ie_length > bss.len - ie_offset) return found;
    const elements = bss[ie_offset..][0..ie_length];
    var at: usize = 0;
    while (at + 2 <= elements.len) {
        const element = elements[at];
        const size = elements[at + 1];
        if (at + 2 + size > elements.len) break;
        const body = elements[at + 2 ..][0..size];
        switch (element) {
            48 => if (size + 2 <= rsn_max) {
                @memcpy(found.rsn[0 .. size + 2], elements[at..][0 .. size + 2]);
                found.rsn_len = size + 2;
            },
            221 => if (size >= 4 and body[0] == 0x00 and body[1] == 0x50 and body[2] == 0xF2 and body[3] == 1) {
                found.wpa = true;
            },
            else => {},
        }
        at += 2 + size;
    }
    return found;
}

/// The control channel of an 802.11ac chanspec: its channel at 20 MHz;
/// at 40 and 80 MHz its centre's, moved to the 20 MHz its sideband
/// names.
fn controlChannel(chanspec: u16) u8 {
    const channel: u8 = @truncate(chanspec);
    const sideband: u8 = @intCast((chanspec >> 8) & 0x7);
    return switch (chanspec & 0x3800) {
        0x1800 => channel -% 2 +% sideband * 4,
        0x2000 => channel -% 6 +% sideband * 4,
        else => channel,
    };
}

/// The networks a scan heard, each access point once - at the strongest
/// it was heard.
pub const Heard = struct {
    pub const max = 48;
    networks: [max]Network = undefined,
    count: usize = 0,

    pub fn add(heard: *Heard, found: Network) void {
        for (heard.networks[0..heard.count]) |*known| {
            if (!std.mem.eql(u8, &known.bssid, &found.bssid)) continue;
            if (found.rssi > known.rssi or known.ssid_len == 0) known.* = found;
            return;
        }
        if (heard.count == max) return;
        heard.networks[heard.count] = found;
        heard.count += 1;
    }

    pub fn list(heard: *const Heard) []const Network {
        return heard.networks[0..heard.count];
    }

    /// The strongest access point of the network `ssid`.
    pub fn strongest(heard: *const Heard, ssid: []const u8) ?*const Network {
        var best: ?*const Network = null;
        for (heard.list()) |*known| {
            if (!std.mem.eql(u8, known.name(), ssid)) continue;
            if (best == null or known.rssi > best.?.rssi) best = known;
        }
        return best;
    }
};
