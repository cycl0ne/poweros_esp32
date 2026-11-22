// SPDX-License-Identifier: MIT
//! A scan: the channels the radio may use, the request that has the
//! firmware go over them, and the networks the frames it hears are.
//!
//! **The channels** are the ones every country allows to be listened
//! on: 2.4 GHz 1 to 13 and the 5 GHz ones from 36 to 165. The device
//! does not know which country it is in, so it sends only where every
//! country lets a station send unasked - 2.4 GHz 1 to 11 - and the
//! firmware only listens on the rest (`NO_IR`) and keeps off those that
//! radar has a claim on until a network is heard there (`RADAR`).
//!
//! **The request** (`request`) names those channels and asks for any
//! network, or for the one named, which finds a network that keeps its
//! name out of its beacons. The firmware goes from channel to channel by
//! itself, sends its probe requests where it may - the station's rates
//! in them - and says with its scan-done event when it has been
//! everywhere.
//!
//! **What it hears** comes in on the data ring like any frame: a beacon
//! or a probe response is a network (`network`) - its name, its access
//! point, its channel (the one the access point names, since a 2.4 GHz
//! frame is heard on the channels beside its own too), how strong, and
//! the RSN element whole, which says how it is protected and which
//! joining it needs - and what a join asks of it: its rates, whether it
//! does HT and QoS, how often it beacons. `Heard` keeps each access
//! point once, at the strongest it was heard.

const sdk = @import("sdk");
const wireless = sdk.devices.wireless;
const wpa = sdk.wpa;
const WPABase = sdk.interface.wpa.WPABase;
const mcu = @import("mcu.zig");
const rxd = @import("rxd.zig");

/// The bands, as the firmware's channel lists number them.
pub const BAND_2G4: u8 = 1;
pub const BAND_5G: u8 = 2;

/// A channel's restrictions, as the firmware's channel domain takes them.
pub const NO_IR: u32 = 1 << 1;
pub const RADAR: u32 = 1 << 3;

pub const Channel = struct { band: u8, number: u8, flags: u32 };

pub const channels = blk: {
    var list: [13 + 25]Channel = undefined;
    var count: usize = 0;
    for (1..14) |number| {
        list[count] = .{ .band = BAND_2G4, .number = number, .flags = if (number > 11) NO_IR else 0 };
        count += 1;
    }
    for ([_]u8{ 36, 40, 44, 48 }) |number| {
        list[count] = .{ .band = BAND_5G, .number = number, .flags = NO_IR };
        count += 1;
    }
    for ([_]u8{ 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124, 128, 132, 136, 140, 144 }) |number| {
        list[count] = .{ .band = BAND_5G, .number = number, .flags = NO_IR | RADAR };
        count += 1;
    }
    for ([_]u8{ 149, 153, 157, 161, 165 }) |number| {
        list[count] = .{ .band = BAND_5G, .number = number, .flags = NO_IR };
        count += 1;
    }
    break :blk list;
};

/// How many of `channels` are on 2.4 GHz.
pub const channels_2g4 = 13;

/// START_HW_SCAN's request.
pub const request_bytes = 1186;
const REQ_SEQ = 0;
const REQ_SCAN_TYPE = 2;
const REQ_SSID_TYPE = 3;
const REQ_SSIDS_NUM = 4;
const REQ_PROBE_REQ_NUM = 5;
const REQ_SCAN_FUNC = 6;
const REQ_VERSION = 7;
const REQ_SSIDS = 8;
const REQ_CHANNEL_TYPE = 158;
const REQ_CHANNELS_NUM = 159;
const REQ_CHANNELS = 160;
const REQ_IES_LEN = 224;
const REQ_IES = 226;
const REQ_EXT_CHANNELS_NUM = 826;
const REQ_EXT_CHANNELS = 830;
const REQ_BSSID = 1110;
const REQ_SSID_TYPE_EXT = 1185;

const SCAN_ACTIVE = 1;
const SSID_WILDCARD = 1 << 0;
const SSID_SPECIFIED = 1 << 2;
const SCAN_FUNC_SPLIT = 1 << 5;
const CHANNELS_LISTED = 4;
const listed_max = 32;

/// What the probe requests carry after the name: the rates the station
/// speaks, the first eight, then the rest.
const probe_elements = [_]u8{ 1, 8, 0x02, 0x04, 0x0b, 0x16, 0x0c, 0x12, 0x18, 0x24, 50, 4, 0x30, 0x48, 0x60, 0x6c };

/// The request for a scan numbered `seq` of every channel the device
/// has (`has_5g`), for any network, or for the one called `ssid` too.
pub fn request(into: *[request_bytes]u8, seq: u8, has_5g: bool, ssid: []const u8) void {
    @memset(into, 0);
    into[REQ_SEQ] = seq & 0x7f;
    into[REQ_SCAN_TYPE] = SCAN_ACTIVE;
    into[REQ_PROBE_REQ_NUM] = 2;
    into[REQ_SCAN_FUNC] = SCAN_FUNC_SPLIT;
    into[REQ_VERSION] = 1;
    if (ssid.len != 0) {
        into[REQ_SSID_TYPE] = SSID_SPECIFIED;
        into[REQ_SSIDS_NUM] = 1;
        mcu.put32(into, REQ_SSIDS, @intCast(ssid.len));
        @memcpy(into[REQ_SSIDS + 4 ..][0..ssid.len], ssid);
    } else {
        into[REQ_SSID_TYPE] = SSID_WILDCARD;
    }
    const count: usize = if (has_5g) channels.len else channels_2g4;
    into[REQ_CHANNEL_TYPE] = CHANNELS_LISTED;
    into[REQ_CHANNELS_NUM] = @intCast(@min(count, listed_max));
    into[REQ_EXT_CHANNELS_NUM] = @intCast(count -| listed_max);
    for (channels[0..count], 0..) |channel, index| {
        const at = if (index < listed_max) REQ_CHANNELS + index * 2 else REQ_EXT_CHANNELS + (index - listed_max) * 2;
        into[at] = channel.band;
        into[at + 1] = channel.number;
    }
    mcu.put16(into, REQ_IES_LEN, probe_elements.len);
    @memcpy(into[REQ_IES..][0..probe_elements.len], &probe_elements);
    @memset(into[REQ_BSSID..][0..6], 0xff);
}

pub const ssid_max = 32;
pub const rsn_max = 64;
pub const rates_max = 16;
pub const ht_cap_bytes = 26;

/// A network a scan heard.
pub const Network = struct {
    ssid: [ssid_max]u8 = @splat(0),
    ssid_len: u8 = 0,
    bssid: [6]u8 = @splat(0),
    channel: u8 = 0,
    signal: i8 = 0,
    /// The capability's privacy bit: it is protected somehow.
    privacy: bool = false,
    /// A WPA element (the older, vendor's one) beside the RSN one.
    wpa: bool = false,
    /// Its RSN element, whole (id and length too); empty for none.
    rsn: [rsn_max]u8 = @splat(0),
    rsn_len: u8 = 0,
    /// Its capability field, how often it beacons (in units of 1024 us)
    /// and every how many beacons it sends what it kept for sleepers (0
    /// until a beacon says).
    capability: u16 = 0,
    beacon_interval: u16 = 0,
    dtim: u8 = 0,
    /// Its rates, as its elements give them: 500 kbit/s steps, the top bit
    /// set on those every station must have.
    rates: [rates_max]u8 = @splat(0),
    rates_len: u8 = 0,
    /// Its HT capabilities element's body, if it does HT.
    ht_cap: [ht_cap_bytes]u8 = @splat(0),
    ht: bool = false,
    /// It does QoS (a WMM element).
    wmm: bool = false,

    pub fn name(heard: *const Network) []const u8 {
        return heard.ssid[0..heard.ssid_len];
    }

    pub fn onFive(heard: *const Network) bool {
        return heard.channel > 14;
    }

    pub fn rateList(heard: *const Network) []const u8 {
        return heard.rates[0..heard.rates_len];
    }

    /// What its RSN element offers, as wpa.library reads it; null for a
    /// network without one, or without the library.
    pub fn security(heard: *const Network, wb: ?*WPABase) ?wpa.Security {
        const library = wb orelse return null;
        if (heard.rsn_len == 0) return null;
        var offered: wpa.Security = .{};
        if (!library.ParseSecurity(&heard.rsn, &offered)) return null;
        return offered;
    }

    /// How a station proves it may join (`wireless.S2AUTH_*`).
    pub fn authMode(heard: *const Network, wb: ?*WPABase) u32 {
        const offered = heard.security(wb) orelse {
            if (heard.rsn_len != 0) return wireless.S2AUTH_OTHER;
            if (heard.wpa) return wireless.S2AUTH_WPA_PSK;
            return if (heard.privacy) wireless.S2AUTH_WEP else wireless.S2AUTH_OPEN;
        };
        const psk = offered.managements & (wpa.WPA_AKM_PSK | wpa.WPA_AKM_PSK_SHA256 | wpa.WPA_AKM_FT_PSK) != 0;
        const sae = offered.managements & (wpa.WPA_AKM_SAE | wpa.WPA_AKM_FT_SAE) != 0;
        if (psk and sae) return wireless.S2AUTH_WPA2_WPA3_PSK;
        if (sae) return wireless.S2AUTH_WPA3_PSK;
        if (psk) return if (heard.wpa) wireless.S2AUTH_WPA_WPA2_PSK else wireless.S2AUTH_WPA2_PSK;
        if (offered.managements & (wpa.WPA_AKM_IEEE8021X | wpa.WPA_AKM_IEEE8021X_SHA256 | wpa.WPA_AKM_FT_IEEE8021X) != 0) return wireless.S2AUTH_ENTERPRISE;
        return wireless.S2AUTH_OTHER;
    }

    /// The cipher for its traffic (`wireless.S2ENC_*`).
    pub fn encryption(heard: *const Network, wb: ?*WPABase) u32 {
        if (heard.security(wb)) |offered| {
            if (offered.pairwise & wpa.WPA_CIPHER_CCMP != 0) return wireless.S2ENC_CCMP;
            if (offered.pairwise & wpa.WPA_CIPHER_TKIP != 0) return wireless.S2ENC_TKIP;
        }
        if (heard.rsn_len != 0) return wireless.S2ENC_CCMP;
        if (heard.wpa) return wireless.S2ENC_TKIP;
        return if (heard.privacy) wireless.S2ENC_WEP else wireless.S2ENC_NONE;
    }
};

/// The frame's kinds a network is read from.
const FC_BEACON = 0x80;
const FC_PROBE_RESPONSE = 0x50;
const header_bytes = 24;
const BSSID = 16;
const BEACON_INTERVAL = 32;
const CAPABILITY = 34;
const ELEMENTS = 36;
const CAPABILITY_PRIVACY: u16 = 0x0010;

const EID_SSID = 0;
const EID_RATES = 1;
const EID_DS_PARAMETERS = 3;
const EID_TIM = 5;
const EID_HT_CAPABILITIES = 45;
const EID_RSN = 48;
const EID_EXTENDED_RATES = 50;
const EID_HT_OPERATION = 61;
const EID_VENDOR = 221;

/// The fastest rate there is without HT, in 500 kbit/s steps: a larger
/// value in a rates element is no rate but a feature the network asks for.
const rate_highest = 108;

/// The network a received frame is: null when it is not a beacon or a
/// probe response.
pub fn network(received: rxd.Received) ?Network {
    if (received.translated) return null;
    const frame = received.frame;
    if (frame.len < ELEMENTS) return null;
    if (frame[0] != FC_BEACON and frame[0] != FC_PROBE_RESPONSE) return null;
    var found = Network{ .channel = received.channel, .signal = received.signal };
    @memcpy(&found.bssid, frame[BSSID..][0..6]);
    found.beacon_interval = mcu.get16(frame, BEACON_INTERVAL);
    found.capability = mcu.get16(frame, CAPABILITY);
    found.privacy = found.capability & CAPABILITY_PRIVACY != 0;
    const named_channel = readElements(&found, frame[ELEMENTS..]);
    if (named_channel != 0) found.channel = named_channel;
    return found;
}

/// A frame's elements read into `found`: its name, rates, HT and QoS,
/// how it is protected. The channel the elements name, 0 for none. Rates
/// are added to those `found` holds.
pub fn readElements(found: *Network, elements: []const u8) u8 {
    var named_channel: u8 = 0;
    var at: usize = 0;
    while (at + 2 <= elements.len) {
        const element = elements[at];
        const size = elements[at + 1];
        if (at + 2 + size > elements.len) break;
        const body = elements[at + 2 ..][0..size];
        switch (element) {
            EID_SSID => if (size <= ssid_max) {
                @memcpy(found.ssid[0..size], body);
                found.ssid_len = size;
            },
            EID_RATES, EID_EXTENDED_RATES => for (body) |rate| {
                if (rate & 0x7f > rate_highest or found.rates_len == rates_max) continue;
                found.rates[found.rates_len] = rate;
                found.rates_len += 1;
            },
            EID_DS_PARAMETERS => if (size == 1) {
                named_channel = body[0];
            },
            EID_TIM => if (size >= 2) {
                found.dtim = body[1];
            },
            EID_HT_CAPABILITIES => if (size >= ht_cap_bytes) {
                @memcpy(&found.ht_cap, body[0..ht_cap_bytes]);
                found.ht = true;
            },
            EID_HT_OPERATION => if (size >= 1 and named_channel == 0) {
                named_channel = body[0];
            },
            EID_RSN => if (size + 2 <= rsn_max) {
                @memcpy(found.rsn[0 .. size + 2], elements[at..][0 .. size + 2]);
                found.rsn_len = size + 2;
            },
            EID_VENDOR => if (size >= 4 and body[0] == 0x00 and body[1] == 0x50 and body[2] == 0xF2) {
                switch (body[3]) {
                    1 => found.wpa = true,
                    2 => found.wmm = true,
                    else => {},
                }
            },
            else => {},
        }
        at += 2 + size;
    }
    return named_channel;
}

/// The networks a scan heard, each access point once - at the strongest
/// it was heard.
pub const Heard = struct {
    pub const max = 64;
    networks: [max]Network = undefined,
    count: usize = 0,

    pub fn add(heard: *Heard, found: Network) void {
        for (heard.networks[0..heard.count]) |*known| {
            if (!sameBytes(&known.bssid, &found.bssid)) continue;
            if (found.signal > known.signal or known.ssid_len == 0) {
                const before = known.*;
                known.* = found;
                // A probe response names a network its beacons keep quiet,
                // and only a beacon says its DTIM.
                if (found.ssid_len == 0) {
                    known.ssid = before.ssid;
                    known.ssid_len = before.ssid_len;
                }
                if (found.dtim == 0) known.dtim = before.dtim;
            } else if (known.dtim == 0) {
                known.dtim = found.dtim;
            }
            return;
        }
        if (heard.count == max) return;
        heard.networks[heard.count] = found;
        heard.count += 1;
    }

    pub fn list(heard: *const Heard) []const Network {
        return heard.networks[0..heard.count];
    }

    /// The access point of the network `name` heard strongest - or the one
    /// `bssid` names, if it is that network's.
    pub fn strongest(heard: *const Heard, name: []const u8, bssid: ?*const [6]u8) ?*const Network {
        var best: ?*const Network = null;
        for (heard.list()) |*known| {
            if (!sameBytes(known.name(), name)) continue;
            if (bssid) |wanted| {
                if (sameBytes(&known.bssid, wanted)) return known;
                continue;
            }
            if (best == null or known.signal > best.?.signal) best = known;
        }
        return best;
    }
};

pub fn sameBytes(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |byte, against| {
        if (byte != against) return false;
    }
    return true;
}
