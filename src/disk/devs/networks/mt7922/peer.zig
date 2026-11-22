// SPDX-License-Identifier: MIT
//! What the firmware is told of the access point the station joins: its
//! entry in the chip's station table, the network the station's
//! interface is on, the channel asked for while it joins.
//!
//! **The access point's entry** (`WCID_AP`) is made before the station
//! authenticates - its address, the rates its network has - so that the
//! station's frames to it have an entry to go by; it is made again once
//! the station is associated, with its number in the network, HT and
//! QoS, and the signal it was heard at; and it is ended when the station
//! leaves. Every entry is a station record: a header, then records of
//! their own (TLVs, each a tag and a length that counts its header), the
//! last of them the chip's table entry with records of its own inside.
//! Its table entry has data frames' headers made Ethernet ones both ways.
//!
//! **The network** is told the firmware once the station is associated:
//! the access point's address, how often it beacons, QoS, the channel -
//! and that the firmware is to watch its beacons, drop every other
//! network's, and say when they stop. The station's own entry
//! (`WCID_STATION`), which the network's group frames go by, is given the
//! access point's address.
//!
//! **The keys** a protected network's handshake hands over go into the
//! entries: the pairwise key into the access point's, which the chip
//! then encrypts the station's frames to it with and decrypts its frames
//! with; the group key into the station's own, for the network's group
//! frames. A TKIP key's two MIC halves are the other way round in the
//! chip. The group key is taken out again when the station leaves; the
//! access point's goes with its entry.
//!
//! **The channel** is the firmware's to manage: while the station joins,
//! it asks for the network's (`requestChannel`) and is told when it has
//! it; once the network is told the firmware, it keeps it there.

const sdk = @import("sdk");
const wpa = sdk.wpa;
const _mt = @import("_mt7922.zig");
const mcu = @import("mcu.zig");
const station = @import("station.zig");
const scan = @import("scan.zig");
const frames = @import("frames.zig");
const Work = _mt.Work;

pub const Error = station.Error;

/// The access point's entry in the chip's station table.
pub const WCID_AP: u16 = 1;
pub const WCID_STATION: u16 = station.WCID_STATION;

/// What the records say of the access point.
pub const Facts = struct {
    bssid: [6]u8 = @splat(0),
    channel: u8 = 0,
    five: bool = false,
    /// The station's number in the network: 0 until it is associated.
    aid: u16 = 0,
    qos: bool = false,
    /// Its rates as bits over its band's; the ones every station must
    /// have.
    rates: u16 = 0,
    basic: u16 = 0,
    /// HT as the station uses it with the access point.
    ht: bool = false,
    ht_info: u16 = 0,
    /// The largest aggregate it takes and the space it needs between
    /// frames in one, as its HT capabilities give them.
    ampdu: u8 = 0,
    /// The MCS it takes, as bits.
    mcs: [10]u8 = @splat(0),
    beacon_interval: u16 = 100,
    dtim: u8 = 1,
    /// The signal it was heard at, as the chip counts it: half a dB a
    /// step from -110 dBm.
    rcpi: u8 = 220,
};

/// The facts a network heard gives; its HT ones as far as the station
/// does them.
pub fn factsOf(target: *const scan.Network, streams: u8) Facts {
    var facts = Facts{
        .bssid = target.bssid,
        .channel = target.channel,
        .five = target.onFive(),
        .qos = target.wmm,
        .rates = frames.rateBits(target, false),
        .basic = frames.rateBits(target, true),
        .beacon_interval = if (target.beacon_interval == 0) 100 else target.beacon_interval,
        .dtim = @max(target.dtim, 1),
    };
    if (target.ht and target.wmm) {
        facts.ht = true;
        facts.ht_info = frames.sharedHt(mcu.get16(&target.ht_cap, 0));
        facts.ampdu = target.ht_cap[2] & 0x1f;
        for (0..@min(streams, 4)) |stream| facts.mcs[stream] = target.ht_cap[3 + stream];
    }
    return facts;
}

/// A signal in dBm as the chip counts it.
pub fn rcpiOf(signal: i8) u8 {
    const value: i32 = 2 * @as(i32, signal) + 220;
    return @intCast(@max(0, @min(255, value)));
}

// --- records ------------------------------------------------------------------------

const STA_REC_BASIC = 0;
const STA_REC_RA = 1;
const STA_REC_STATE = 7;
const STA_REC_HT = 9;
const STA_REC_WTBL = 13;
const STA_REC_PHY = 0x15;
const WTBL_GENERIC = 0;
const WTBL_RX = 1;
const WTBL_HT = 2;
const WTBL_HDR_TRANS = 6;
const WTBL_SMPS = 13;
const WTBL_RESET_AND_SET = 1;

const CONNECTION_INFRA_STA: u32 = 0x00010001;
const CONNECTION_INFRA_AP: u32 = 0x00010002;
const CONN_STATE_DISCONNECT = 0;
const CONN_STATE_PORT_SECURE = 2;
const EXTRA_INFO_VER: u16 = 1 << 0;
const EXTRA_INFO_NEW: u16 = 1 << 1;
const STATE_NONE = 0;
const STATE_ASSOC = 2;
/// Where an entry's own address is matched: the interface's, or none in
/// particular.
const MUAR_OWN = 0;
const MUAR_ANY = 0x0e;

const STA_REC_KEY_V2: u16 = 17;
const KEY_SET = 0;
const KEY_REMOVE = 1;
const KEY_CIPHER_TKIP = 4;
const KEY_CIPHER_CCMP = 5;
/// A key record's header, and each key in it.
const key_header_bytes = 8;
const key_bytes = 36;

const PHY_TYPE_HR_DSSS: u8 = 1 << 0;
const PHY_TYPE_ERP: u8 = 1 << 1;
const PHY_TYPE_OFDM: u8 = 1 << 3;
const PHY_TYPE_HT: u8 = 1 << 4;
const PHY_TYPE_VHT: u8 = 1 << 5;
const PHY_TYPE_HE: u8 = 1 << 6;

/// A station record being made in the worker's scratch.
const Record = struct {
    bytes: []u8,
    length: usize,
    /// Where the table entry's record is, once it is begun.
    entry_at: usize = 0,

    fn begin(work: *Work, wcid: u16, muar: u8) Record {
        const bytes = work.scratch[0..];
        @memset(bytes[0..8], 0);
        bytes[1] = @truncate(wcid);
        bytes[4] = 1; // its records follow
        bytes[5] = muar;
        bytes[6] = @truncate(wcid >> 8);
        return .{ .bytes = bytes, .length = 8 };
    }

    fn add(record: *Record, tag: u16, length: u16) []u8 {
        const at = record.length;
        const body = record.bytes[at..][0..length];
        @memset(body, 0);
        mcu.put16(body.ptr, 0, tag);
        mcu.put16(body.ptr, 2, length);
        record.length += length;
        mcu.put16(record.bytes.ptr, 2, mcu.get16(record.bytes, 2) + 1);
        return body;
    }

    /// The table entry's record, with its own header.
    fn beginEntry(record: *Record, wcid: u16) void {
        const at = record.length;
        _ = record.add(STA_REC_WTBL, 4 + 8);
        const header = record.bytes[at + 4 ..][0..8];
        header[0] = @truncate(wcid);
        header[1] = WTBL_RESET_AND_SET;
        header[4] = @truncate(wcid >> 8);
        record.entry_at = at;
    }

    fn addInEntry(record: *Record, tag: u16, length: u16) []u8 {
        const at = record.length;
        const body = record.bytes[at..][0..length];
        @memset(body, 0);
        mcu.put16(body.ptr, 0, tag);
        mcu.put16(body.ptr, 2, length);
        record.length += length;
        const entry = record.entry_at;
        mcu.put16(record.bytes.ptr, entry + 2, mcu.get16(record.bytes, entry + 2) + length);
        mcu.put16(record.bytes.ptr, entry + 4 + 2, mcu.get16(record.bytes, entry + 4 + 2) + 1);
        return body;
    }

    fn send(record: *const Record, work: *Work) Error!void {
        try station.uni(work, mcu.UNI_STA_REC_UPDATE, record.bytes[0..record.length]);
    }
};

/// The access point's entry made, before the station authenticates.
pub fn addAccessPoint(work: *Work, facts: *const Facts) Error!void {
    station.clearCounts(work, WCID_AP);
    try accessPointRecord(work, facts, STATE_NONE);
}

/// The station associated: the network told the firmware, the access
/// point's entry made again, the station's own entry given the network,
/// and the network's beacons watched.
pub fn associated(work: *Work, facts: *const Facts) Error!void {
    try network(work, facts, true);
    station.clearCounts(work, WCID_AP);
    try accessPointRecord(work, facts, STATE_ASSOC);

    var own = Record.begin(work, WCID_STATION, MUAR_ANY);
    own.beginEntry(WCID_STATION);
    const generic = own.addInEntry(WTBL_GENERIC, 20);
    @memcpy(generic[4..10], &facts.bssid);
    generic[10] = MUAR_ANY;
    const rx = own.addInEntry(WTBL_RX, 12);
    rx[5] = 1;
    rx[6] = 1;
    rx[7] = 1;
    translation(&own);
    try own.send(work);

    var watch: [4 + 8]u8 = @splat(0);
    mcu.put16(&watch, 4, BSS_INFO_BCNFT);
    mcu.put16(&watch, 6, 8);
    mcu.put16(&watch, 8, facts.beacon_interval);
    watch[10] = facts.dtim;
    try station.uni(work, mcu.UNI_BSS_INFO_UPDATE, &watch);
    try otherBeacons(work, false);
}

/// The station off the network: the firmware told, the access point's
/// entry ended. `told` is whether the network was told the firmware.
pub fn left(work: *Work, facts: *const Facts, told: bool) void {
    if (told) {
        _ = mcu.send(work, mcu.ce(mcu.CE_SET_BSS_ABORT), &[_]u8{ 0, 0, 0, 0 }, false) catch {};
        otherBeacons(work, true) catch {};
    }
    var record = Record.begin(work, WCID_AP, MUAR_OWN);
    const basic = record.add(STA_REC_BASIC, 20);
    mcu.put32(basic.ptr, 4, CONNECTION_INFRA_AP);
    basic[8] = CONN_STATE_DISCONNECT;
    mcu.put16(basic.ptr, 10, facts.aid);
    @memcpy(basic[12..18], &facts.bssid);
    mcu.put16(basic.ptr, 18, EXTRA_INFO_VER);
    record.beginEntry(WCID_AP);
    record.send(work) catch {};
    station.clearCounts(work, WCID_AP);
    if (told) network(work, facts, false) catch {};
}

/// The chip's number for a cipher wpa.library names (a WPA_CIPHER_*
/// bit); null for one the station does not install.
pub fn cipherId(cipher: u32) ?u8 {
    return switch (cipher) {
        wpa.WPA_CIPHER_CCMP => KEY_CIPHER_CCMP,
        wpa.WPA_CIPHER_TKIP => KEY_CIPHER_TKIP,
        else => null,
    };
}

/// A key put in: the pairwise one into the access point's entry, the
/// group's key number `index` into the station's own.
pub fn installKey(work: *Work, pairwise: bool, cipher: u8, index: u8, key: []const u8) Error!void {
    var record = if (pairwise) Record.begin(work, WCID_AP, MUAR_OWN) else Record.begin(work, WCID_STATION, MUAR_ANY);
    const body = record.add(STA_REC_KEY_V2, key_header_bytes + key_bytes);
    body[4] = KEY_SET;
    body[5] = 1;
    const entry = body[key_header_bytes..];
    entry[0] = cipher;
    entry[1] = key_bytes;
    entry[2] = index;
    entry[3] = @intCast(key.len);
    @memcpy(entry[4..][0..key.len], key);
    if (cipher == KEY_CIPHER_TKIP and key.len == 32) {
        @memcpy(entry[4 + 16 ..][0..8], key[24..32]);
        @memcpy(entry[4 + 24 ..][0..8], key[16..24]);
    }
    defer {
        const secret: [*]volatile u8 = @ptrCast(entry.ptr);
        @memset(secret[0..key_bytes], 0);
    }
    try record.send(work);
}

/// The group key taken out of the station's own entry.
pub fn removeGroupKey(work: *Work) void {
    var record = Record.begin(work, WCID_STATION, MUAR_ANY);
    const body = record.add(STA_REC_KEY_V2, key_header_bytes);
    body[4] = KEY_REMOVE;
    record.send(work) catch {};
}

fn accessPointRecord(work: *Work, facts: *const Facts, state: u8) Error!void {
    var record = Record.begin(work, WCID_AP, MUAR_OWN);
    const basic = record.add(STA_REC_BASIC, 20);
    mcu.put32(basic.ptr, 4, CONNECTION_INFRA_AP);
    basic[8] = CONN_STATE_PORT_SECURE;
    basic[9] = @intFromBool(facts.qos);
    mcu.put16(basic.ptr, 10, facts.aid);
    @memcpy(basic[12..18], &facts.bssid);
    mcu.put16(basic.ptr, 18, EXTRA_INFO_VER | if (state == STATE_NONE) EXTRA_INFO_NEW else 0);
    const ht = facts.ht and state == STATE_ASSOC;
    if (ht) {
        const capabilities = record.add(STA_REC_HT, 8);
        mcu.put16(capabilities.ptr, 4, facts.ht_info);
    }
    const phy = record.add(STA_REC_PHY, 12);
    mcu.put16(phy.ptr, 4, facts.basic);
    phy[6] = (if (facts.five) PHY_TYPE_OFDM else PHY_TYPE_HR_DSSS | PHY_TYPE_ERP) | if (ht) PHY_TYPE_HT else 0;
    if (ht) phy[7] = facts.ampdu;
    phy[9] = facts.rcpi;
    const rates = record.add(STA_REC_RA, 16);
    const legacy: u16 = if (facts.five) facts.rates << 6 else (facts.rates & 0xf) | (facts.rates >> 4) << 6;
    mcu.put16(rates.ptr, 4, legacy);
    if (ht) @memcpy(rates[6..16], &facts.mcs);
    const status = record.add(STA_REC_STATE, 12);
    status[8] = state;

    record.beginEntry(WCID_AP);
    const generic = record.addInEntry(WTBL_GENERIC, 20);
    @memcpy(generic[4..10], &facts.bssid);
    generic[10] = MUAR_OWN;
    generic[13] = @intFromBool(facts.qos);
    mcu.put16(generic.ptr, 16, facts.aid);
    const rx = record.addInEntry(WTBL_RX, 12);
    rx[5] = 1;
    rx[6] = 1;
    rx[7] = 1;
    translation(&record);
    if (ht) {
        const entry_ht = record.addInEntry(WTBL_HT, 12);
        entry_ht[4] = 1;
        entry_ht[5] = @intFromBool(facts.ht_info & 0x0001 != 0);
        entry_ht[6] = facts.ampdu & 0x03;
        entry_ht[7] = (facts.ampdu >> 2) & 0x07;
    }
    const smps = record.addInEntry(WTBL_SMPS, 8);
    smps[4] = @intFromBool(ht and frames.dynamicPowerSave(facts.ht_info));
    try record.send(work);
}

/// Frames to the network sent as Ethernet ones, the network's received
/// as Ethernet ones.
fn translation(record: *Record) void {
    const body = record.addInEntry(WTBL_HDR_TRANS, 8);
    body[4] = 1; // to the network
}

// --- the network ------------------------------------------------------------------

const BSS_INFO_BASIC = 0;
const BSS_INFO_RLM = 2;
const BSS_INFO_QBSS = 15;
const BSS_INFO_BCNFT = 22;
/// The modes the band's radio has, and the kinds of transmission it
/// knows outside HT, as the firmware numbers them.
const PHY_MODE_2G4: u8 = 0x4e;
const PHY_MODE_5G: u8 = 0xb1;
const NONHT_2G4: u16 = PHY_TYPE_HR_DSSS | PHY_TYPE_ERP | PHY_TYPE_HT | PHY_TYPE_HE;
const NONHT_5G: u16 = PHY_TYPE_OFDM | PHY_TYPE_HT | PHY_TYPE_VHT | PHY_TYPE_HE;

/// The network told the firmware, or that the station is off it; then
/// the channel it is on.
fn network(work: *Work, facts: *const Facts, on: bool) Error!void {
    var basic: [4 + 32 + 8]u8 = @splat(0);
    mcu.put16(&basic, 4, BSS_INFO_BASIC);
    mcu.put16(&basic, 6, 32);
    basic[8] = 1; // active
    mcu.put32(&basic, 12, CONNECTION_INFRA_STA);
    basic[16] = @intFromBool(!on);
    @memcpy(basic[18..24], &facts.bssid);
    mcu.put16(&basic, 24, WCID_STATION);
    mcu.put16(&basic, 26, facts.beacon_interval);
    basic[28] = facts.dtim;
    basic[29] = if (facts.five) PHY_MODE_5G else PHY_MODE_2G4;
    mcu.put16(&basic, 30, WCID_STATION);
    mcu.put16(&basic, 32, if (facts.five) NONHT_5G else NONHT_2G4);
    mcu.put16(&basic, 36, BSS_INFO_QBSS);
    mcu.put16(&basic, 38, 8);
    basic[40] = @intFromBool(facts.qos);
    try station.uni(work, mcu.UNI_BSS_INFO_UPDATE, &basic);

    var channel: [4 + 16]u8 = @splat(0);
    mcu.put16(&channel, 4, BSS_INFO_RLM);
    mcu.put16(&channel, 6, 16);
    channel[8] = facts.channel;
    channel[9] = facts.channel;
    channel[12] = @popCount(station.chainMask(work));
    channel[13] = station.chainMask(work);
    channel[14] = 1; // short slot
    channel[17] = @intFromBool(facts.five);
    try station.uni(work, mcu.UNI_BSS_INFO_UPDATE, &channel);
}

const RFCR_DROP_OTHER_BEACON: u32 = 1 << 11;
const FILTER_BIT_SET = 1;
const FILTER_BIT_CLEAR = 2;

/// Other networks' beacons dropped by the chip, or taken again.
fn otherBeacons(work: *Work, take: bool) Error!void {
    var payload: [68]u8 = @splat(0);
    payload[4] = 2; // one bit of the filter
    mcu.put32(&payload, 12, RFCR_DROP_OTHER_BEACON);
    payload[16] = if (take) FILTER_BIT_CLEAR else FILTER_BIT_SET;
    _ = try mcu.send(work, mcu.ce(mcu.CE_SET_RX_FILTER), &payload, false);
}

// --- the channel ---------------------------------------------------------------------

const ROC_ACQUIRE = 0;
const ROC_ABORT = 1;
const ROC_JOIN = 0;
/// Whichever of the radio's bands the firmware picks.
const DBDC_AUTO = 0xff;

/// The network's channel asked for, for `ms` milliseconds: the firmware
/// says when the radio is on it (`radio.zig`'s event), under `token`.
pub fn requestChannel(work: *Work, facts: *const Facts, token: u8, ms: u32) Error!void {
    var payload: [4 + 24]u8 = @splat(0);
    mcu.put16(&payload, 4, ROC_ACQUIRE);
    mcu.put16(&payload, 6, 24);
    payload[9] = token;
    payload[10] = facts.channel;
    payload[12] = if (facts.five) scan.BAND_5G else scan.BAND_2G4;
    payload[14] = facts.channel;
    payload[17] = facts.channel;
    payload[19] = ROC_JOIN;
    mcu.put32(&payload, 20, ms);
    payload[24] = DBDC_AUTO;
    _ = try mcu.send(work, mcu.uni(mcu.UNI_ROC), &payload, false);
}

/// The channel asked for under `token` given back.
pub fn releaseChannel(work: *Work, token: u8) void {
    var payload: [4 + 12]u8 = @splat(0);
    mcu.put16(&payload, 4, ROC_ABORT);
    mcu.put16(&payload, 6, 12);
    payload[9] = token;
    payload[10] = DBDC_AUTO;
    _ = mcu.send(work, mcu.uni(mcu.UNI_ROC), &payload, false) catch {};
}

/// The token of a grant event, if `bytes` is one: the channel is the
/// radio's.
pub fn grantOf(bytes: []const u8) ?u8 {
    // The grant's record follows the event's header and four bytes.
    const at = 40;
    if (bytes.len < at + 8) return null;
    if (mcu.get16(bytes, at) != 0) return null;
    return bytes[at + 5];
}

// --- tests ----------------------------------------------------------------------

const testing = @import("std").testing;

test "the firmware's grant of the channel, by its token" {
    var event: [64]u8 = @splat(0);
    event[45] = 9;
    try testing.expectEqual(@as(?u8, 9), grantOf(&event));
    // Another record, or one too short, is no grant.
    event[40] = 1;
    try testing.expectEqual(@as(?u8, null), grantOf(&event));
    try testing.expectEqual(@as(?u8, null), grantOf(event[0..44]));
}

test "the ciphers the card is given" {
    try testing.expectEqual(@as(?u8, KEY_CIPHER_CCMP), cipherId(wpa.WPA_CIPHER_CCMP));
    try testing.expectEqual(@as(?u8, KEY_CIPHER_TKIP), cipherId(wpa.WPA_CIPHER_TKIP));
    try testing.expectEqual(@as(?u8, null), cipherId(wpa.WPA_CIPHER_GCMP));
}

test "the access point's facts: HT only with QoS, its MCS per stream" {
    var target = scan.Network{ .channel = 36, .ht = true, .wmm = true };
    target.ht_cap[2] = 0x17;
    @memset(target.ht_cap[3..5], 0xff);
    const facts = factsOf(&target, 2);
    try testing.expect(facts.five and facts.ht and facts.qos);
    try testing.expectEqual(@as(u8, 0x17), facts.ampdu);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0 }, facts.mcs[0..3]);
    target.wmm = false;
    try testing.expect(!factsOf(&target, 2).ht);
    try testing.expectEqual(@as(u8, 220 - 80), rcpiOf(-40));
}
