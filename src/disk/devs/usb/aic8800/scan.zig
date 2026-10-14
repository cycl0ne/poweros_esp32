// SPDX-License-Identifier: MIT
//! A scan: the request that has the firmware listen on every channel, and
//! the networks its results are.
//!
//! The firmware answers `SCANU_START_REQ` at once (its additional
//! confirmation), then sends a `SCANU_RESULT_IND` for every beacon or
//! probe response it hears - the frame whole, behind its frequency and
//! signal - and `SCANU_START_CFM` when it has been everywhere. A network
//! is read from a frame (`network`): its name, its access point's
//! address, its channel, how strong, and how it is protected - the RSN
//! element whole, which joining it needs.

const sdk = @import("sdk");
const wireless = sdk.devices.wireless;
const msg = @import("msg.zig");
const lmac = @import("lmac.zig");

/// The 2.4 GHz channels, and the 5 GHz ones every country allows.
const channels_2g4 = [_]u16{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 };
const channels_5g = [_]u16{ 36, 40, 44, 48 };

/// `SCANU_START_REQ`: every channel, any network, from the station
/// `vif`. 376 bytes.
pub fn request(vif: u8, has_5g: bool) [376]u8 {
    var params: [376]u8 = @splat(0);
    var count: usize = 0;
    for (channels_2g4) |number| {
        lmac.putChannel(&params, count * lmac.channel_bytes, lmac.freq2g4(number), lmac.BAND_2G4, 0, 20);
        count += 1;
    }
    if (has_5g) {
        for (channels_5g) |number| {
            lmac.putChannel(&params, count * lmac.channel_bytes, lmac.freq5g(number), lmac.BAND_5G, 0, 20);
            count += 1;
        }
    }
    // One name to probe for: none, which every network answers.
    params[252] = 0;
    // Any access point.
    @memset(params[352..358], 0xFF);
    params[366] = vif;
    params[367] = @intCast(count);
    params[368] = 1;
    return params;
}

pub const ssid_max = 32;
pub const rsn_max = 64;

/// A network a scan heard.
pub const Network = struct {
    ssid: [ssid_max]u8 = @splat(0),
    ssid_len: u8 = 0,
    bssid: [6]u8 = @splat(0),
    freq: u16 = 0,
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

/// What an RSN element offers: the pairwise ciphers and the key
/// managements this device tells apart.
const Suites = struct {
    ccmp: bool = false,
    tkip: bool = false,
    psk: bool = false,
    sae: bool = false,
    dot1x: bool = false,
};

/// The suites of RSN element `element` (its id and length on), null when
/// there is none or it is cut short.
fn rsnSuites(element: []const u8) ?Suites {
    if (element.len < 2 + 2 + 4 + 2) return null;
    const body = element[2..];
    var suites = Suites{};
    var at: usize = 2 + 4;
    const pairwise = msg.get16(body, at);
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
    const managements = msg.get16(body, at);
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

/// The network a `SCANU_RESULT_IND`'s parameters are, null when they are
/// not a beacon or a probe response.
pub fn network(params: []const u8) ?Network {
    if (params.len < 12 + 36) return null;
    const length = @min(msg.get16(params, 0), params.len - 12);
    const frame = params[12..][0..length];
    if (frame.len < 36) return null;
    // A management frame: a beacon (0x80) or a probe response (0x50).
    const control = frame[0];
    if (control != 0x80 and control != 0x50) return null;
    var found = Network{
        .freq = msg.get16(params, 4),
        .rssi = @bitCast(params[9]),
    };
    @memcpy(&found.bssid, frame[16..22]);
    const capability = msg.get16(frame, 34);
    found.privacy = capability & 0x0010 != 0;
    found.channel = channelOf(found.freq);
    // The elements, after the timestamp, interval and capability.
    var at: usize = 36;
    while (at + 2 <= frame.len) {
        const element = frame[at];
        const size = frame[at + 1];
        if (at + 2 + size > frame.len) break;
        const body = frame[at + 2 ..][0..size];
        switch (element) {
            0 => if (size <= ssid_max) {
                @memcpy(found.ssid[0..size], body);
                found.ssid_len = size;
            },
            3 => if (size == 1) {
                found.channel = body[0];
            },
            48 => if (size + 2 <= rsn_max) {
                @memcpy(found.rsn[0 .. size + 2], frame[at..][0 .. size + 2]);
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

/// The networks a scan heard, each access point once - at the strongest
/// it was heard.
pub const Heard = struct {
    pub const max = 32;
    networks: [max]Network = undefined,
    count: usize = 0,
    /// Who the records not a scan's go to while it runs.
    before: ?lmac.Other = null,

    pub fn add(heard: *Heard, found: Network) void {
        for (heard.networks[0..heard.count]) |*known| {
            if (!sameAddress(&known.bssid, &found.bssid)) continue;
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
            if (!sameName(known.name(), ssid)) continue;
            if (best == null or known.rssi > best.?.rssi) best = known;
        }
        return best;
    }

    /// A result's record, as `lmac.Caller` hands on what is not the answer
    /// it waits for; anything else to whoever took it before.
    fn take(context: *anyopaque, record: msg.Record) void {
        const heard: *Heard = @ptrCast(@alignCast(context));
        switch (record) {
            .message => |m| if (m.id == lmac.SCANU_RESULT_IND) {
                if (network(m.params)) |found| heard.add(found);
                return;
            },
            else => {},
        }
        if (heard.before) |other| other.handle(other.context, record);
    }
};

/// A scan from the station `vif`, its networks into `heard`: the request,
/// its prompt confirmation, the results until the scan is done. What is
/// not a result goes where the caller's other records go.
pub fn run(c: *lmac.Caller, vif: u8, has_5g: bool, heard: *Heard) lmac.Error!void {
    heard.before = c.other;
    defer c.other = heard.before;
    c.other = .{ .context = heard, .handle = Heard.take };
    var status: [4]u8 = @splat(0);
    _ = try c.call(lmac.SCANU_START_REQ, &request(vif, has_5g), lmac.SCANU_START_CFM_ADDITIONAL, &status);
    // Every channel listened on for a while: a few seconds, the results
    // coming in all along.
    _ = try c.waitFor(lmac.SCANU_START_CFM, &status, 2000, 4);
}

fn sameAddress(a: *const [6]u8, b: *const [6]u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn sameName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// A frequency's channel number.
pub fn channelOf(freq: u16) u8 {
    if (freq >= 2412 and freq <= 2472) return @intCast((freq - 2407) / 5);
    if (freq == 2484) return 14;
    if (freq >= 5000 and freq <= 5900) return @intCast((freq - 5000) / 5);
    return 0;
}

// --- tests --------------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "a beacon read: name, access point, channel, signal, RSN element" {
    var params: [12 + 80]u8 = @splat(0);
    const frame = params[12..];
    frame[0] = 0x80;
    @memcpy(frame[16..22], &[_]u8{ 1, 2, 3, 4, 5, 6 });
    frame[34] = 0x11; // ESS, privacy
    var at: usize = 36;
    const elements = [_][]const u8{
        &.{ 0, 7, 'H', 'o', 'm', 'e', 'N', 'e', 't' },
        &.{ 3, 1, 6 },
        &.{ 48, 20, 1, 0, 0x00, 0x0F, 0xAC, 4, 1, 0, 0x00, 0x0F, 0xAC, 4, 1, 0, 0x00, 0x0F, 0xAC, 2, 0x0C, 0 },
    };
    for (elements) |element| {
        @memcpy(frame[at..][0..element.len], element);
        at += element.len;
    }
    msg.put32(&params, 0, @intCast(at));
    params[4] = @truncate(2437);
    params[5] = 2437 >> 8;
    params[9] = @bitCast(@as(i8, -48));
    const found = network(params[0 .. 12 + at]).?;
    try testing.expectEqualStrings("HomeNet", found.name());
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6 }, &found.bssid);
    try testing.expectEqual(@as(u8, 6), found.channel);
    try testing.expectEqual(@as(i8, -48), found.rssi);
    try testing.expect(found.privacy);
    try testing.expectEqual(@as(u8, 22), found.rsn_len);
    try testing.expectEqual(@as(u8, 48), found.rsn[0]);
    try testing.expectEqual(wireless.S2AUTH_WPA2_PSK, found.authMode());
    try testing.expectEqual(wireless.S2ENC_CCMP, found.encryption());
}

test "a frame that is not a beacon is no network" {
    var params: [12 + 40]u8 = @splat(0);
    params[12] = 0x08;
    params[0] = 40;
    try testing.expect(network(&params) == null);
}

test "the networks heard: each access point once, at its strongest" {
    var heard: Heard = .{};
    var first = Network{ .rssi = -70 };
    first.bssid = .{ 1, 1, 1, 1, 1, 1 };
    @memcpy(first.ssid[0..4], "Home");
    first.ssid_len = 4;
    heard.add(first);
    var again = first;
    again.rssi = -50;
    heard.add(again);
    var other = first;
    other.bssid[5] = 2;
    other.rssi = -40;
    heard.add(other);
    try testing.expectEqual(@as(usize, 2), heard.count);
    try testing.expectEqual(@as(i8, -50), heard.networks[0].rssi);
    try testing.expectEqual(@as(u8, 2), heard.strongest("Home").?.bssid[5]);
    try testing.expect(heard.strongest("Away") == null);
}

test "channels from frequencies" {
    try testing.expectEqual(@as(u8, 1), channelOf(2412));
    try testing.expectEqual(@as(u8, 13), channelOf(2472));
    try testing.expectEqual(@as(u8, 36), channelOf(5180));
}
