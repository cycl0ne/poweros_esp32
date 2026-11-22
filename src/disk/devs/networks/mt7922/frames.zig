// SPDX-License-Identifier: MIT
//! The 802.11 frames the station makes and reads itself - the ones the
//! chip leaves to the host: authentication, association, leaving, a
//! block-ack offer declined - and the data frames the chip did not turn
//! into Ethernet ones.
//!
//! **A management frame** is a 24-byte header - its kind, the access
//! point as receiver and as network, the station as sender; the chip
//! numbers it - and its body. The station authenticates with the open
//! system, the first of two frames; it then asks to associate, naming
//! the network and what it can do as far as the network does it too: the
//! access point's own rates, HT if the access point does HT, QoS if it
//! does QoS, and the RSN element wpa.library made for a protected one.
//!
//! **HT** is offered on 20 MHz: both streams' MCS 0 to 7, the short
//! guard interval, space-time block coding received and sent, LDPC, and
//! no power save of the streams. A wider channel is not asked for.
//!
//! **Block acknowledgement** is not taken up: the station does not put
//! reordered frames back in order, so an access point's offer of it is
//! declined, and its frames come one by one.
//!
//! **A data frame the chip left as it was** - one whose header it did not
//! translate - is made an Ethernet frame here when it is a plain or a QoS
//! data frame from the network, unencrypted or decrypted by the chip,
//! carrying an LLC/SNAP header.

const sdk = @import("sdk");
const ethernet = sdk.devices.network.ethernet;
const mcu = @import("mcu.zig");
const scan = @import("scan.zig");

pub const header_bytes = 24;

/// The first byte of a frame's control field, for the kinds used here.
pub const FC_ASSOC_REQUEST: u8 = 0x00;
pub const FC_ASSOC_RESPONSE: u8 = 0x10;
pub const FC_REASSOC_RESPONSE: u8 = 0x30;
pub const FC_DISASSOC: u8 = 0xa0;
pub const FC_AUTH: u8 = 0xb0;
pub const FC_DEAUTH: u8 = 0xc0;
pub const FC_ACTION: u8 = 0xd0;

const FC_TYPE_MASK: u8 = 0x0c;
const FC_TYPE_DATA: u8 = 0x08;
const FC_SUBTYPE_QOS: u8 = 0x80;
const FC_SUBTYPE_NO_DATA: u8 = 0x40;
/// The second byte: from the network, protected, an HT control field.
const FC1_FROM_DS: u8 = 0x02;
const FC1_PROTECTED: u8 = 0x40;
const FC1_ORDER: u8 = 0x80;

const CAPABILITY_ESS: u16 = 0x0001;
const CAPABILITY_PRIVACY: u16 = 0x0010;
const CAPABILITY_SHORT_PREAMBLE: u16 = 0x0020;
const CAPABILITY_SHORT_SLOT: u16 = 0x0400;

const EID_SSID = 0;
const EID_RATES = 1;
const EID_HT_CAPABILITIES = 45;
const EID_EXTENDED_RATES = 50;
const EID_VENDOR = 221;

/// Every how many beacons the station says it listens for what the access
/// point keeps for it; it never sleeps, so the number is only what it
/// says.
const listen_interval = 10;

/// The largest number of rates the Supported Rates element holds; the
/// rest go in the Extended one.
const rates_in_first = 8;

/// The station's HT capabilities: LDPC received, no power save of its
/// streams, the short guard interval at 20 MHz, space-time block coding
/// sent (with two streams) and received on one.
const HT_LDPC: u16 = 0x0001;
/// The streams' power save, two bits: 1 dynamic, 3 none.
const HT_SM_POWER_SAVE: u16 = 0x000c;
pub const HT_SGI_20: u16 = 0x0020;
const HT_TX_STBC: u16 = 0x0080;
const HT_RX_STBC_ONE: u16 = 0x0100;
const HT_RX_STBC: u16 = 0x0300;
/// The A-MPDU parameters: up to 64 KiB.
const AMPDU_64K: u8 = 0x03;
/// The MCS set's "the sent ones are the received ones" bit.
const MCS_TX_DEFINED: u8 = 0x01;

/// A management frame's header into `into`: to the access point, from the
/// station.
fn header(into: []u8, kind: u8, bssid: *const [6]u8, own: *const [6]u8) void {
    @memset(into[0..header_bytes], 0);
    into[0] = kind;
    @memcpy(into[4..10], bssid);
    @memcpy(into[10..16], own);
    @memcpy(into[16..22], bssid);
}

/// The first frame of the open system's authentication: its length.
pub fn authentication(into: []u8, bssid: *const [6]u8, own: *const [6]u8) usize {
    header(into, FC_AUTH, bssid, own);
    // The open system, its first frame, no status.
    @memcpy(into[header_bytes..][0..6], &[_]u8{ 0, 0, 1, 0, 0, 0 });
    return header_bytes + 6;
}

/// The station's leave, with its reason: its length.
pub fn deauthentication(into: []u8, bssid: *const [6]u8, own: *const [6]u8, reason: u16) usize {
    header(into, FC_DEAUTH, bssid, own);
    mcu.put16(into.ptr, header_bytes, reason);
    return header_bytes + 2;
}

/// What the station asks for in its association request.
pub const Asked = struct {
    /// The station's RSN element; empty for an open network.
    element: []const u8 = &.{},
    /// HT, with this many streams.
    ht: bool = false,
    streams: u8 = 1,
    qos: bool = false,
};

/// The association request for `target`: its length, 0 if it does not
/// fit `into`.
pub fn associationRequest(into: []u8, target: *const scan.Network, own: *const [6]u8, asked: Asked) usize {
    if (into.len < 256 + asked.element.len) return 0;
    header(into, FC_ASSOC_REQUEST, &target.bssid, own);
    var capability: u16 = CAPABILITY_ESS;
    if (target.privacy) capability |= CAPABILITY_PRIVACY;
    if (!target.onFive()) capability |= target.capability & (CAPABILITY_SHORT_PREAMBLE | CAPABILITY_SHORT_SLOT);
    mcu.put16(into.ptr, header_bytes, capability);
    mcu.put16(into.ptr, header_bytes + 2, listen_interval);
    var at: usize = header_bytes + 4;
    at = element(into, at, EID_SSID, target.name());
    const rates = target.rateList();
    at = element(into, at, EID_RATES, rates[0..@min(rates.len, rates_in_first)]);
    if (rates.len > rates_in_first) at = element(into, at, EID_EXTENDED_RATES, rates[rates_in_first..]);
    @memcpy(into[at..][0..asked.element.len], asked.element);
    at += asked.element.len;
    if (asked.ht) {
        var capabilities: [scan.ht_cap_bytes]u8 = @splat(0);
        var info: u16 = HT_LDPC | HT_SM_POWER_SAVE | HT_SGI_20 | HT_RX_STBC_ONE;
        if (asked.streams > 1) info |= HT_TX_STBC;
        mcu.put16(&capabilities, 0, info);
        capabilities[2] = AMPDU_64K;
        for (0..@min(asked.streams, 4)) |stream| capabilities[3 + stream] = 0xff;
        capabilities[15] = MCS_TX_DEFINED;
        at = element(into, at, EID_HT_CAPABILITIES, &capabilities);
    }
    // The WMM information element: version 1, no power save of its own.
    if (asked.qos) at = element(into, at, EID_VENDOR, &[_]u8{ 0x00, 0x50, 0xF2, 0x02, 0x00, 0x01, 0x00 });
    return at;
}

fn element(into: []u8, at: usize, id: u8, body: []const u8) usize {
    into[at] = id;
    into[at + 1] = @intCast(body.len);
    @memcpy(into[at + 2 ..][0..body.len], body);
    return at + 2 + body.len;
}

/// The HT capabilities the station uses with an access point: the
/// access point's, as far as the station does them too, on 20 MHz.
pub fn sharedHt(ap_info: u16) u16 {
    var shared = ap_info & (HT_LDPC | HT_SM_POWER_SAVE | HT_SGI_20);
    // It receives space-time coded frames if the station sends them, and
    // sends them if the station takes them.
    if (ap_info & HT_RX_STBC != 0) shared |= ap_info & HT_RX_STBC;
    if (ap_info & HT_TX_STBC != 0) shared |= HT_TX_STBC;
    return shared;
}

/// Whether the access point's streams save power dynamically: then it
/// wants a frame of protection before each of the station's that uses
/// more than one.
pub fn dynamicPowerSave(info: u16) bool {
    return (info & HT_SM_POWER_SAVE) >> 2 == 1;
}

// --- frames in -------------------------------------------------------------------

fn fromNetwork(frame: []const u8, bssid: *const [6]u8, own: *const [6]u8) bool {
    if (frame.len < header_bytes) return false;
    return scan.sameBytes(frame[4..10], own) and scan.sameBytes(frame[10..16], bssid);
}

/// The status the access point answered the station's authentication
/// with, if `frame` is that answer.
pub fn authenticationAnswer(frame: []const u8, bssid: *const [6]u8, own: *const [6]u8) ?u16 {
    if (frame.len < header_bytes + 6 or frame[0] != FC_AUTH) return null;
    if (!fromNetwork(frame, bssid, own)) return null;
    const body = frame[header_bytes..];
    if (mcu.get16(body, 0) != 0 or mcu.get16(body, 2) != 2) return null;
    return mcu.get16(body, 4);
}

/// The access point's answer to an association request.
pub const Association = struct {
    status: u16,
    /// The station's number in the network.
    aid: u16,
    elements: []const u8,
};

pub fn associationAnswer(frame: []const u8, bssid: *const [6]u8, own: *const [6]u8) ?Association {
    if (frame.len < header_bytes + 6) return null;
    if (frame[0] != FC_ASSOC_RESPONSE and frame[0] != FC_REASSOC_RESPONSE) return null;
    if (!fromNetwork(frame, bssid, own)) return null;
    const body = frame[header_bytes..];
    return .{ .status = mcu.get16(body, 2), .aid = mcu.get16(body, 4) & 0x3fff, .elements = body[6..] };
}

/// The reason the access point gave for putting the station off the
/// network, if `frame` does that: a deauthentication or a disassociation
/// from it, to the station or to every station.
pub fn leaveReason(frame: []const u8, bssid: *const [6]u8, own: *const [6]u8) ?u16 {
    if (frame.len < header_bytes + 2) return null;
    if (frame[0] != FC_DEAUTH and frame[0] != FC_DISASSOC) return null;
    if (!scan.sameBytes(frame[10..16], bssid)) return null;
    if (!scan.sameBytes(frame[4..10], own) and !ethernet.isBroadcast(frame[4..10])) return null;
    return mcu.get16(frame, header_bytes);
}

const CATEGORY_BLOCK_ACK = 3;
const ADDBA_REQUEST = 0;
const ADDBA_RESPONSE = 1;
const STATUS_REQUEST_DECLINED = 37;

/// The answer declining a block-ack offer, if `frame` is one from the
/// access point: its length in `into`, 0 if it is not.
pub fn declineBlockAck(into: []u8, frame: []const u8, bssid: *const [6]u8, own: *const [6]u8) usize {
    if (frame.len < header_bytes + 9 or frame[0] != FC_ACTION) return 0;
    if (!fromNetwork(frame, bssid, own)) return 0;
    const body = frame[header_bytes..];
    if (body[0] != CATEGORY_BLOCK_ACK or body[1] != ADDBA_REQUEST) return 0;
    header(into, FC_ACTION, bssid, own);
    const answer = into[header_bytes..];
    answer[0] = CATEGORY_BLOCK_ACK;
    answer[1] = ADDBA_RESPONSE;
    answer[2] = body[2];
    mcu.put16(answer.ptr, 3, STATUS_REQUEST_DECLINED);
    // The offer's parameters and timeout, as they were.
    @memcpy(answer[5..9], body[3..7]);
    return header_bytes + 9;
}

/// `frame`, a data frame from the network the chip did not translate, as
/// an Ethernet frame in `into`: its length, 0 if it is not one or carries
/// nothing.
pub fn ethernetOf(into: []u8, frame: []const u8, decrypted: bool) usize {
    if (frame.len < header_bytes) return 0;
    if (frame[0] & FC_TYPE_MASK != FC_TYPE_DATA or frame[0] & FC_SUBTYPE_NO_DATA != 0) return 0;
    if (frame[1] & FC1_FROM_DS == 0) return 0;
    if (frame[1] & FC1_PROTECTED != 0 and !decrypted) return 0;
    var at: usize = header_bytes;
    if (frame[0] & FC_SUBTYPE_QOS != 0) {
        at += 2;
        if (frame[1] & FC1_ORDER != 0) at += 4;
    }
    // LLC/SNAP: AA AA 03, no organisation, then the packet's type.
    if (frame.len < at + 8) return 0;
    const snap = frame[at..][0..6];
    if (snap[0] != 0xAA or snap[1] != 0xAA or snap[2] != 0x03 or snap[3] != 0 or snap[4] != 0 or snap[5] != 0) return 0;
    const payload = frame[at + 8 ..];
    const length = ethernet.header_bytes + payload.len;
    if (length > into.len) return 0;
    // To (A1), from (A3), the type, the packet.
    @memcpy(into[0..6], frame[4..10]);
    @memcpy(into[6..12], frame[16..22]);
    @memcpy(into[12..14], frame[at + 6 ..][0..2]);
    @memcpy(into[ethernet.header_bytes..][0..payload.len], payload);
    return length;
}

// --- rates ----------------------------------------------------------------------

/// The rates of each band, in the order the firmware's rate bits count
/// them: on 2.4 GHz the four DSSS ones first.
const rates_2g4 = [_]u8{ 2, 4, 11, 22, 12, 18, 24, 36, 48, 72, 96, 108 };
const rates_5g = [_]u8{ 12, 18, 24, 36, 48, 72, 96, 108 };
/// The chip's index of each OFDM rate, from 6 to 54 Mbit/s.
const ofdm_index = [_]u16{ 11, 15, 10, 14, 9, 13, 8, 12 };
const RATE_MODE_OFDM: u16 = 1 << 6;

/// The network's rates as bits over its band's rates; only the ones
/// every station must have, with `basic`.
pub fn rateBits(target: *const scan.Network, basic: bool) u16 {
    const table: []const u8 = if (target.onFive()) &rates_5g else &rates_2g4;
    var bits: u16 = 0;
    for (target.rateList()) |rate| {
        if (basic and rate & 0x80 == 0) continue;
        for (table, 0..) |known, index| {
            if (rate & 0x7f == known) bits |= @as(u16, 1) << @intCast(index);
        }
    }
    return bits;
}

/// The rate the station's management frames go at, as the chip's fixed
/// rate: the network's slowest that every station must have.
pub fn managementRate(target: *const scan.Network) u16 {
    const basic = rateBits(target, true);
    const lowest: u16 = if (basic == 0) 0 else @ctz(basic);
    if (target.onFive()) return RATE_MODE_OFDM | ofdm_index[@min(lowest, ofdm_index.len - 1)];
    if (lowest < 4) return lowest;
    return RATE_MODE_OFDM | ofdm_index[lowest - 4];
}

// --- tests ----------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

const test_bssid = [6]u8{ 0x02, 0x11, 0x22, 0x33, 0x44, 0x55 };
const test_own = [6]u8{ 0x02, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };

fn testNetwork(channel: u8) scan.Network {
    var network = scan.Network{ .bssid = test_bssid, .channel = channel, .privacy = true };
    @memcpy(network.ssid[0..4], "home");
    network.ssid_len = 4;
    const rates: []const u8 = if (channel > 14)
        &.{ 0x8c, 0x12, 0x98, 0x24, 0xb0, 0x48, 0x60, 0x6c }
    else
        &.{ 0x82, 0x84, 0x8b, 0x96, 0x0c, 0x12, 0x18, 0x24, 0x30, 0x48, 0x60, 0x6c };
    @memcpy(network.rates[0..rates.len], rates);
    network.rates_len = @intCast(rates.len);
    return network;
}

test "the authentication: the open system's first frame" {
    var out: [64]u8 = undefined;
    try testing.expectEqual(@as(usize, 30), authentication(&out, &test_bssid, &test_own));
    try testing.expectEqual(FC_AUTH, out[0]);
    try testing.expectEqualSlices(u8, &test_bssid, out[4..10]);
    try testing.expectEqualSlices(u8, &test_own, out[10..16]);
    try testing.expectEqualSlices(u8, &test_bssid, out[16..22]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 0, 0, 0 }, out[24..30]);
}

test "the association request: name, rates split, the RSN element, HT, WMM" {
    const network = testNetwork(11);
    const rsn = [_]u8{ 48, 2, 1, 0 };
    var out: [512]u8 = undefined;
    const length = associationRequest(&out, &network, &test_own, .{ .element = &rsn, .ht = true, .streams = 2, .qos = true });
    try testing.expectEqual(FC_ASSOC_REQUEST, out[0]);
    try testing.expect(mcu.get16(&out, header_bytes) & CAPABILITY_PRIVACY != 0);
    try testing.expectEqual(listen_interval, mcu.get16(&out, header_bytes + 2));
    var at: usize = header_bytes + 4;
    try testing.expectEqualSlices(u8, &.{ EID_SSID, 4, 'h', 'o', 'm', 'e' }, out[at..][0..6]);
    at += 6;
    try testing.expectEqual(EID_RATES, out[at]);
    try testing.expectEqual(@as(u8, 8), out[at + 1]);
    at += 10;
    try testing.expectEqual(EID_EXTENDED_RATES, out[at]);
    try testing.expectEqualSlices(u8, &.{ 0x30, 0x48, 0x60, 0x6c }, out[at + 2 ..][0..4]);
    at += 6;
    try testing.expectEqualSlices(u8, &rsn, out[at..][0..4]);
    at += 4;
    try testing.expectEqual(EID_HT_CAPABILITIES, out[at]);
    try testing.expectEqual(@as(u8, scan.ht_cap_bytes), out[at + 1]);
    try testing.expect(mcu.get16(&out, at + 2) & HT_TX_STBC != 0);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0x00 }, out[at + 5 ..][0..3]);
    at += 2 + scan.ht_cap_bytes;
    try testing.expectEqualSlices(u8, &.{ EID_VENDOR, 7, 0x00, 0x50, 0xF2, 0x02, 0x00, 0x01, 0x00 }, out[at..][0..9]);
    try testing.expectEqual(at + 9, length);
}

test "the access point's answers: authentication, association, a leave" {
    var frame: [40]u8 = @splat(0);
    frame[0] = FC_AUTH;
    @memcpy(frame[4..10], &test_own);
    @memcpy(frame[10..16], &test_bssid);
    @memcpy(frame[16..22], &test_bssid);
    frame[header_bytes + 2] = 2;
    frame[header_bytes + 4] = 17;
    try testing.expectEqual(@as(?u16, 17), authenticationAnswer(frame[0..30], &test_bssid, &test_own));
    // Its own first frame, or one from another network, is no answer.
    frame[header_bytes + 2] = 1;
    try testing.expectEqual(@as(?u16, null), authenticationAnswer(frame[0..30], &test_bssid, &test_own));
    frame[header_bytes + 2] = 2;
    try testing.expectEqual(@as(?u16, null), authenticationAnswer(frame[0..30], &test_own, &test_own));

    @memset(frame[header_bytes..], 0);
    frame[0] = FC_ASSOC_RESPONSE;
    mcu.put16(&frame, header_bytes + 4, 0xc003);
    frame[header_bytes + 6] = EID_RATES;
    const answer = associationAnswer(frame[0 .. header_bytes + 8], &test_bssid, &test_own).?;
    try testing.expectEqual(@as(u16, 0), answer.status);
    try testing.expectEqual(@as(u16, 3), answer.aid);
    try testing.expectEqual(@as(usize, 2), answer.elements.len);

    frame[0] = FC_DEAUTH;
    @memset(frame[4..10], 0xff);
    mcu.put16(&frame, header_bytes, 7);
    try testing.expectEqual(@as(?u16, 7), leaveReason(frame[0..26], &test_bssid, &test_own));
    try testing.expectEqual(@as(?u16, null), leaveReason(frame[0..26], &test_own, &test_own));
}

test "a block-ack offer declined, its parameters kept" {
    var frame: [header_bytes + 9]u8 = @splat(0);
    frame[0] = FC_ACTION;
    @memcpy(frame[4..10], &test_own);
    @memcpy(frame[10..16], &test_bssid);
    @memcpy(frame[header_bytes..], &[_]u8{ CATEGORY_BLOCK_ACK, ADDBA_REQUEST, 9, 0x02, 0x10, 0x00, 0x00, 0, 0 });
    var out: [64]u8 = undefined;
    const length = declineBlockAck(&out, &frame, &test_bssid, &test_own);
    try testing.expectEqual(@as(usize, header_bytes + 9), length);
    try testing.expectEqualSlices(u8, &.{ CATEGORY_BLOCK_ACK, ADDBA_RESPONSE, 9, STATUS_REQUEST_DECLINED, 0, 0x02, 0x10, 0x00, 0x00 }, out[header_bytes..][0..9]);
    try testing.expectEqualSlices(u8, &test_bssid, out[4..10]);
}

test "a QoS data frame from the network: Ethernet's" {
    var frame: [header_bytes + 2 + 8 + 4]u8 = @splat(0);
    frame[0] = 0x88;
    frame[1] = FC1_FROM_DS;
    @memcpy(frame[4..10], &test_own);
    @memcpy(frame[10..16], &test_bssid);
    @memset(frame[16..22], 7);
    @memcpy(frame[26..34], &[_]u8{ 0xAA, 0xAA, 0x03, 0, 0, 0, 0x08, 0x06 });
    @memcpy(frame[34..38], "arp!");
    var out: [64]u8 = undefined;
    const length = ethernetOf(&out, &frame, false);
    try testing.expectEqual(@as(usize, 14 + 4), length);
    try testing.expectEqualSlices(u8, &test_own, out[0..6]);
    try testing.expectEqualSlices(u8, &[_]u8{7} ** 6, out[6..12]);
    try testing.expectEqualSlices(u8, &.{ 0x08, 0x06, 'a', 'r', 'p', '!' }, out[12..18]);
    // Still encrypted, or to the network: nothing.
    frame[1] = FC1_FROM_DS | FC1_PROTECTED;
    try testing.expectEqual(@as(usize, 0), ethernetOf(&out, &frame, false));
    try testing.expectEqual(@as(usize, 18), ethernetOf(&out, &frame, true));
    frame[1] = 0;
    try testing.expectEqual(@as(usize, 0), ethernetOf(&out, &frame, false));
}

test "the rates: bits over the band's, the management frames' rate" {
    const slow = testNetwork(6);
    try testing.expectEqual(@as(u16, 0x0fff), rateBits(&slow, false));
    try testing.expectEqual(@as(u16, 0x000f), rateBits(&slow, true));
    // 1 Mbit/s, DSSS.
    try testing.expectEqual(@as(u16, 0), managementRate(&slow));
    const five = testNetwork(36);
    try testing.expectEqual(@as(u16, 0x00ff), rateBits(&five, false));
    try testing.expectEqual(@as(u16, 0x0015), rateBits(&five, true));
    // 6 Mbit/s, OFDM.
    try testing.expectEqual(RATE_MODE_OFDM | 11, managementRate(&five));
}
