// SPDX-License-Identifier: MIT
//! Joining a network, being on it and leaving it: the wireless requests
//! S2_SETOPTIONS, S2_GETNETWORKINFO and S2_GETSIGNALQUALITY, and the
//! frames to and from the access point.
//!
//! **A join** (S2_SETOPTIONS) is answered at once and made after, on the
//! worker, from start to end: a scan for the network, its strongest
//! access point taken (or the one asked for), its entry made in the
//! chip's table (peer.zig); then its channel asked for, the station
//! authenticated with the open system, the channel given back and asked
//! for again, and the station associated - each frame sent up to three
//! times, an answer waited for after each. Once the access point has the
//! station, the firmware is told the network, and the access point's
//! entry made again with what the association settled.
//!
//! **An open network** is then joined: the channel given back, the unit
//! has its carrier. **A WPA2-Personal network** is joined with
//! wpa.library: the network's key made from the passphrase (and kept for
//! the next join of the same network), the station's RSN element made
//! from the access point's and put into the association request, and a
//! key handshake made before the station authenticates. The access
//! point's EAPOL frames go to it - one that comes before the firmware has
//! been told the network is kept for it until then - and the frames it
//! answers with go out as the station's own; when the chip is through
//! with one, the handshake is told it has gone (`HandshakeSent`). The
//! channel is kept for the handshake until the time the firmware granted
//! it is up. The keys it hands over are not installed yet: the network
//! is not joined.
//!
//! **What the frames' handlers find** - an answer, a key, a leave - is
//! noted and done by `due` once the worker is back in its loop, as the
//! handlers run inside the worker's waits for the firmware.
//!
//! **A network asked for stays wanted** until it is left
//! (S2INFO_Disassociate). Coming off it for any reason but its own leave -
//! put off by the access point, refused, not found, not joined in time,
//! its beacons gone - the station tries again after a pause: a second,
//! twice as long each time, up to a minute; joining resets it.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const ethernet = net.ethernet;
const wireless = sdk.devices.wireless;
const wpa = sdk.wpa;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const _mt = @import("_mt7922.zig");
const mcu = @import("mcu.zig");
const rxd = @import("rxd.zig");
const scan = @import("scan.zig");
const frames = @import("frames.zig");
const peer = @import("peer.zig");
const tx = @import("tx.zig");
const radio = @import("radio.zig");
const Work = _mt.Work;
const say = _mt.say;

/// How long a join may take, from its start to the network joined.
const join_ms = 15_000;
/// The first pause before joining again, and the longest, in seconds.
const pause_first_s = 1;
const pause_most_s = 60;
/// How often a frame of the join is sent, and how long its answer is
/// waited for; how long the firmware may take to grant the channel, and
/// how long it is asked for.
const tries = 3;
const answer_ms = 300;
const grant_ms = 1000;
const channel_ms = 1000;
/// How long the station's leave may take to go out.
const leave_ms = 100;
/// The reasons the station gives when it leaves: it is leaving; it was
/// not let on in time.
const REASON_LEAVING = 3;
const REASON_UNSPECIFIED = 1;

const ETHERTYPE_EAPOL: u16 = 0x888E;
const eapol_max = 512;

/// Where the station stands with a network: being joined; associated,
/// its key handshake under way; joined.
pub const State = enum(u8) { idle, joining, keying, joined };

/// A key the handshake handed over.
const Key = struct {
    bytes: [32]u8 = @splat(0),
    length: u8 = 0,
    index: u8 = 0,
    due: bool = false,
};

pub const Join = struct {
    state: State = .idle,
    /// The network asked for, and whether a join is to be made.
    wanted: bool = false,
    join_due: bool = false,
    want_ssid: [scan.ssid_max]u8 = @splat(0),
    want_len: usize = 0,
    want_bssid: ?[6]u8 = null,
    want_pass: [wpa.WPA_PASSPHRASE_MAX + 1]u8 = @splat(0),
    /// The pause before the next join, and when it ends.
    pause_s: u32 = pause_first_s,
    retry_waiting: bool = false,
    retry_at: u32 = 0,
    /// When the join under way gives up.
    deadline: u32 = 0,

    /// The access point joined, what the firmware was told of it, the
    /// rate the station's management frames go at; whether its entry is
    /// made and whether the network was told the firmware.
    target: scan.Network = .{},
    facts: peer.Facts = .{},
    rate: u16 = 0,
    entry: bool = false,
    told: bool = false,
    /// The channel: the number it was last asked for under, whether the
    /// firmware granted it, whether it is held and until when.
    token: u8 = 0,
    granted: bool = false,
    holding: bool = false,
    channel_ends: u32 = 0,
    /// The access point's answers.
    auth_answered: bool = false,
    auth_status: u16 = 0,
    assoc_answered: bool = false,
    assoc_status: u16 = 0,
    assoc_aid: u16 = 0,
    /// The signals of its answers, summed, for the firmware's rates.
    signal_sum: i32 = 0,
    signal_count: u8 = 0,

    /// A protected network: its key, and the name and passphrase it was
    /// made from; the station's RSN element; the handshake and its hook.
    protected: bool = false,
    key: [wpa.WPA_KEY_BYTES]u8 = @splat(0),
    key_ssid: [scan.ssid_max]u8 = @splat(0),
    key_ssid_len: usize = 0,
    key_pass: [wpa.WPA_PASSPHRASE_MAX + 1]u8 = @splat(0),
    key_made: bool = false,
    own_element: [wpa.WPA_ELEMENT_MAX]u8 = @splat(0),
    own_len: usize = 0,
    handshake: ?*wpa.Handshake = null,
    hook: utility.Hook = .{},
    /// An EAPOL frame that came before the handshake could take it.
    eapol: [eapol_max]u8 = @splat(0),
    eapol_len: usize = 0,

    /// What the handlers noted for `due`: a frame of the handshake's
    /// gone, keys handed over, the handshake done, a leave of the
    /// station's own, the access point's putting it off, its beacons
    /// gone.
    sent_due: bool = false,
    sent_number: u32 = 0,
    pairwise_key: Key = .{},
    group_key: Key = .{},
    authorized_due: bool = false,
    leave_due: ?u16 = null,
    thrown_due: ?u16 = null,
    lost_due: bool = false,

    /// A data frame the chip left as an 802.11 one, made an Ethernet one.
    frame: [ethernet.frame_max]u8 = @splat(0),
};

/// The handshake's hook made ready when the worker starts.
pub fn setUp(work: *Work) void {
    work.join.hook = .{ .entry = &handshakeHook, .data = work };
}

/// Whether the unit's frames go out: the station is on a network and the
/// unit is online.
pub fn carrying(work: *const Work) bool {
    return work.join.state == .joined and work.running;
}

/// What a data frame to the access point asks of the chip.
pub fn dataTo(work: *const Work, tid: u8) tx.Data {
    return .{ .wcid = peer.WCID_AP, .tid = tid, .qos = work.join.facts.qos };
}

// --- the requests ---------------------------------------------------------------

/// A wireless request answered: false if it is not one of these.
pub fn request(work: *Work, req: *net.IOSana2Req) bool {
    const sys = work.sys;
    switch (req.req.command) {
        wireless.S2_SETOPTIONS => req.req.err = setOptions(work, req),
        wireless.S2_GETNETWORKINFO => req.req.err = networkInfo(work, req),
        wireless.S2_GETSIGNALQUALITY => {
            const quality: ?*wireless.Sana2SignalQuality = @ptrCast(@alignCast(req.stat_data));
            if (quality == null) {
                req.req.err = net.S2ERR_BAD_ARGUMENT;
            } else if (work.join.state != .joined) {
                req.req.err = net.S2ERR_OUTOFSERVICE;
                req.wire_error = net.S2WERR_UNIT_OFFLINE;
            } else {
                quality.?.* = .{ .signal_level = work.join.target.signal, .noise_level = -95 };
            }
        },
        else => return false,
    }
    if (req.req.err == net.S2ERR_OUTOFSERVICE and req.wire_error == 0) req.wire_error = net.S2WERR_UNIT_OFFLINE;
    sys.ReplyMsg(&req.req.message);
    return true;
}

fn copyString(into: []u8, text: [*:0]const u8) ?usize {
    var length: usize = 0;
    while (text[length] != 0) : (length += 1) {
        if (length == into.len) return null;
        into[length] = text[length];
    }
    return length;
}

/// S2_SETOPTIONS: the network to join, or none. The join itself comes
/// after the answer.
fn setOptions(work: *Work, req: *net.IOSana2Req) i8 {
    const join = &work.join;
    const ub = work.base.utility.?;
    const list: [*]const TagItem = @ptrCast(@alignCast(req.data orelse return net.S2ERR_BAD_ARGUMENT));
    if (ub.FindTagItem(wireless.S2INFO_Disassociate, list) != null) {
        join.wanted = false;
        join.join_due = false;
        join.retry_waiting = false;
        if (join.state != .idle) join.leave_due = REASON_LEAVING;
        return 0;
    }
    const ssid: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(wireless.S2INFO_SSID, 0, list));
    const name = ssid orelse return net.S2ERR_BAD_ARGUMENT;
    var wanted: [scan.ssid_max]u8 = @splat(0);
    const length = copyString(&wanted, name) orelse return net.S2ERR_BAD_ARGUMENT;
    if (length == 0) return net.S2ERR_BAD_ARGUMENT;
    var passphrase: [wpa.WPA_PASSPHRASE_MAX + 1]u8 = @splat(0);
    const given: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(wireless.S2INFO_Passphrase, 0, list));
    if (given) |text| {
        const passphrase_length = copyString(passphrase[0..wpa.WPA_PASSPHRASE_MAX], text) orelse return net.S2ERR_BAD_ARGUMENT;
        if (passphrase_length < wpa.WPA_PASSPHRASE_MIN) return net.S2ERR_BAD_ARGUMENT;
    }
    join.want_ssid = wanted;
    join.want_len = length;
    join.want_pass = passphrase;
    const bssid: ?[*]const u8 = @ptrFromInt(ub.GetTagData(wireless.S2INFO_BSSID, 0, list));
    join.want_bssid = if (bssid) |address| address[0..6].* else null;
    join.wanted = true;
    join.join_due = true;
    join.retry_waiting = false;
    join.pause_s = pause_first_s;
    return 0;
}

/// S2_GETNETWORKINFO: the network joined, as one tag list.
fn networkInfo(work: *Work, req: *net.IOSana2Req) i8 {
    const join = &work.join;
    if (join.state != .joined) return net.S2ERR_OUTOFSERVICE;
    const target = &join.target;
    const tag_count = 6;
    const memory: [*]u8 = @ptrCast(work.sys.AllocPooled(req.data, tag_count * @sizeOf(TagItem) + scan.ssid_max + 1 + 6) orelse return net.S2ERR_NO_RESOURCES);
    const tags: [*]TagItem = @ptrCast(@alignCast(memory));
    const name = memory + tag_count * @sizeOf(TagItem);
    @memcpy(name[0..target.ssid_len], target.name());
    name[target.ssid_len] = 0;
    const address = name + scan.ssid_max + 1;
    @memcpy(address[0..6], &target.bssid);
    tags[0] = .{ .tag = wireless.S2INFO_SSID, .data = @intFromPtr(name) };
    tags[1] = .{ .tag = wireless.S2INFO_BSSID, .data = @intFromPtr(address) };
    tags[2] = .{ .tag = wireless.S2INFO_Channel, .data = target.channel };
    tags[3] = .{ .tag = wireless.S2INFO_Signal, .data = @bitCast(@as(isize, target.signal)) };
    tags[4] = .{ .tag = wireless.S2INFO_AuthMode, .data = target.authMode(radio.wpaBase(work)) };
    tags[5] = .{};
    req.stat_data = @ptrCast(tags);
    return 0;
}

// --- what is due ---------------------------------------------------------------------

/// What a handler, a request or the clock left to be done, done: true if
/// anything was, as that may leave more.
pub fn due(work: *Work) bool {
    const join = &work.join;
    if (join.leave_due) |reason| {
        join.leave_due = null;
        leave(work, reason, true);
        return true;
    }
    if (join.thrown_due) |reason| {
        join.thrown_due = null;
        if (join.state == .idle) return true;
        say(work.sys, "the access point put the station off the network: reason %u", .{@as(u32, reason)});
        leave(work, reason, false);
        cameOff(work);
        return true;
    }
    if (join.lost_due) {
        join.lost_due = false;
        if (join.state == .idle) return true;
        say(work.sys, "the access point's beacons are gone", .{});
        leave(work, REASON_UNSPECIFIED, true);
        cameOff(work);
        return true;
    }
    if (join.sent_due) {
        join.sent_due = false;
        if (join.handshake) |handshake| radio.wpaBase(work).?.HandshakeSent(handshake, join.sent_number);
        return true;
    }
    if (join.pairwise_key.due or join.group_key.due) {
        // Installing the keys is the next step; until then the network is
        // not joined.
        wipe(&join.pairwise_key);
        wipe(&join.group_key);
        return true;
    }
    if (join.authorized_due) {
        join.authorized_due = false;
        say(work.sys, "the key handshake is done; its keys are not installed yet", .{});
        return true;
    }
    if (join.join_due) {
        join.join_due = false;
        run(work);
        return true;
    }
    return false;
}

/// The clock: the join's deadline, the channel's time, the pause before
/// joining again. True while it is still wanted.
pub fn tick(work: *Work) bool {
    const join = &work.join;
    const now = radio.elapsed(work);
    if (join.holding and passed(now, join.channel_ends)) {
        join.holding = false;
        peer.releaseChannel(work, join.token);
    }
    if ((join.state == .joining or join.state == .keying) and passed(now, join.deadline)) {
        say(work.sys, "the network was not joined in time", .{});
        join.leave_due = REASON_UNSPECIFIED;
        // Joined again after the pause, as for any other way off.
        join.retry_waiting = join.wanted;
        join.retry_at = now +% join.pause_s * 1000;
        join.pause_s = @min(join.pause_s * 2, pause_most_s);
    }
    if (join.retry_waiting and passed(now, join.retry_at)) {
        join.retry_waiting = false;
        if (join.wanted and join.state == .idle) join.join_due = true;
    }
    return join.holding or join.retry_waiting or join.state == .joining or join.state == .keying;
}

fn passed(now: u32, at: u32) bool {
    const left: i32 = @bitCast(at -% now);
    return left <= 0;
}

/// Off the network without having left it: joined again after the
/// pause, which doubles.
fn cameOff(work: *Work) void {
    const join = &work.join;
    if (!join.wanted) return;
    join.retry_waiting = true;
    join.retry_at = radio.elapsed(work) +% join.pause_s * 1000;
    join.pause_s = @min(join.pause_s * 2, pause_most_s);
    radio.keepTime(work);
}

/// The device is going: the network left.
pub fn stop(work: *Work) void {
    const join = &work.join;
    join.wanted = false;
    join.retry_waiting = false;
    if (join.state != .idle) leave(work, REASON_LEAVING, true);
    dropHandshake(work);
}

// --- joining --------------------------------------------------------------------------

const Failure = error{ Refused, NoChannel, NoAnswer, NoRoom } || peer.Error;

/// The network asked for joined, from the scan for it to its association.
fn run(work: *Work) void {
    const join = &work.join;
    if (join.state != .idle) leave(work, REASON_LEAVING, true);
    const name = join.want_ssid[0..join.want_len];
    radio.scanFor(work, name);
    const wanted_bssid: ?*const [6]u8 = if (join.want_bssid) |*address| address else null;
    const found = work.heard.strongest(name, wanted_bssid) orelse {
        say(work.sys, "the network asked for was not found", .{});
        return cameOff(work);
    };
    join.target = found.*;
    dropHandshake(work);
    join.protected = found.rsn_len != 0 or found.privacy;
    join.own_len = 0;
    if (join.protected) join.own_len = prepareKeys(work) orelse return;
    join.facts = peer.factsOf(&join.target, work.streams);
    join.rate = frames.managementRate(&join.target);
    join.signal_sum = 0;
    join.signal_count = 0;
    join.eapol_len = 0;
    join.state = .joining;
    join.deadline = radio.elapsed(work) +% join_ms;
    radio.keepTime(work);
    say(work.sys, "joining on channel %u, at %d dBm", .{ @as(u32, join.target.channel), @as(i32, join.target.signal) });
    associate(work) catch |failure| {
        say(work.sys, "the network is not joined: %s", .{@as([*:0]const u8, @errorName(failure))});
        leave(work, REASON_LEAVING, false);
        return cameOff(work);
    };
}

fn associate(work: *Work) Failure!void {
    const join = &work.join;
    try peer.addAccessPoint(work, &join.facts);
    join.entry = true;

    try holdChannel(work);
    join.auth_answered = false;
    for (0..tries) |_| {
        const buffer = tx.frameBuffer(work) orelse return error.NoRoom;
        tx.sendManagement(work, frames.authentication(buffer, &join.target.bssid, &work.station), peer.WCID_AP, join.rate);
        if (waitFor(work, &join.auth_answered, answer_ms)) break;
    }
    if (!join.auth_answered) return error.NoAnswer;
    if (join.auth_status != 0) {
        say(work.sys, "the access point refuses the authentication: status %u", .{@as(u32, join.auth_status)});
        return error.Refused;
    }
    giveChannelBack(work);

    try holdChannel(work);
    join.assoc_answered = false;
    const asked = frames.Asked{
        .element = join.own_element[0..join.own_len],
        .ht = join.facts.ht,
        .streams = work.streams,
        .qos = join.facts.qos,
    };
    for (0..tries) |_| {
        const buffer = tx.frameBuffer(work) orelse return error.NoRoom;
        const length = frames.associationRequest(buffer, &join.target, &work.station, asked);
        if (length == 0) return error.NoRoom;
        tx.sendManagement(work, length, peer.WCID_AP, join.rate);
        if (waitFor(work, &join.assoc_answered, answer_ms)) break;
    }
    if (!join.assoc_answered) return error.NoAnswer;
    if (join.assoc_status != 0) {
        say(work.sys, "the access point refuses the association: status %u", .{@as(u32, join.assoc_status)});
        return error.Refused;
    }

    // What the association settled, from the access point's answer.
    join.facts = peer.factsOf(&join.target, work.streams);
    join.facts.aid = join.assoc_aid;
    if (join.signal_count != 0) {
        join.facts.rcpi = peer.rcpiOf(@intCast(@divTrunc(join.signal_sum, join.signal_count)));
    }
    try peer.associated(work, &join.facts);
    join.told = true;

    if (join.protected) {
        join.state = .keying;
        say(work.sys, "associated, number %u; the key handshake follows", .{@as(u32, join.facts.aid)});
        if (join.eapol_len != 0) {
            const length = join.eapol_len;
            join.eapol_len = 0;
            toHandshake(work, join.eapol[0..length]);
        }
        return;
    }
    giveChannelBack(work);
    joined(work);
}

/// The network joined: the unit has its carrier.
fn joined(work: *Work) void {
    const join = &work.join;
    join.state = .joined;
    join.pause_s = pause_first_s;
    say(work.sys, "joined the network", .{});
    work.base.net.setCarrier(true);
    tx.startWrites(work);
}

/// The network's channel asked for and granted.
fn holdChannel(work: *Work) Failure!void {
    const join = &work.join;
    join.token +%= 1;
    if (join.token == 0) join.token = 1;
    join.granted = false;
    try peer.requestChannel(work, &join.facts, join.token, channel_ms);
    if (!waitFor(work, &join.granted, grant_ms)) {
        peer.releaseChannel(work, join.token);
        return error.NoChannel;
    }
    join.holding = true;
    join.channel_ends = radio.elapsed(work) +% channel_ms;
}

fn giveChannelBack(work: *Work) void {
    const join = &work.join;
    if (!join.holding) return;
    join.holding = false;
    peer.releaseChannel(work, join.token);
}

/// Until `flag` is set by what comes in, or `ms` milliseconds have gone:
/// whether it was.
fn waitFor(work: *Work, flag: *const bool, ms: u32) bool {
    const ends = radio.elapsed(work) +% ms;
    while (true) {
        _ = mcu.takeEvents(work, 0);
        if (flag.*) return true;
        if (passed(radio.elapsed(work), ends)) return false;
        work.pause(1000);
    }
}

/// The network left, or the join given up: the access point told if
/// `tell`, the firmware's records ended, the unit without a carrier.
fn leave(work: *Work, reason: u16, tell: bool) void {
    const join = &work.join;
    if (tell and join.entry) {
        if (tx.frameBuffer(work)) |buffer| {
            tx.sendManagement(work, frames.deauthentication(buffer, &join.target.bssid, &work.station, reason), peer.WCID_AP, join.rate);
            // The entry it goes by is kept until it has gone.
            work.pause(leave_ms * 1000);
            _ = mcu.takeEvents(work, 0);
        }
    }
    giveChannelBack(work);
    if (join.entry) peer.left(work, &join.facts, join.told);
    join.entry = false;
    join.told = false;
    dropHandshake(work);
    const was = join.state;
    join.state = .idle;
    if (was == .joined) work.base.net.setCarrier(false);
}

// --- what comes in ---------------------------------------------------------------------

/// A frame the chip received while the station is joining or on a
/// network.
pub fn frame(work: *Work, received: rxd.Received) void {
    const join = &work.join;
    if (join.state == .idle) return;
    const bytes = received.frame;
    if (received.translated) {
        if (received.wcid == peer.WCID_AP) dataIn(work, bytes);
        return;
    }
    if (bytes.len < frames.header_bytes) return;
    switch (bytes[0] & 0x0c) {
        // Data the chip left as it was.
        0x08 => {
            if (received.wcid != peer.WCID_AP) return;
            const length = frames.ethernetOf(&join.frame, bytes, received.decrypted);
            if (length != 0) dataIn(work, join.frame[0..length]);
        },
        0x00 => management(work, received),
        else => {},
    }
}

fn management(work: *Work, received: rxd.Received) void {
    const join = &work.join;
    const bytes = received.frame;
    const bssid = &join.target.bssid;
    const own = &work.station;
    if (frames.authenticationAnswer(bytes, bssid, own)) |status| {
        if (join.state != .joining or join.auth_answered) return;
        join.auth_status = status;
        join.auth_answered = true;
        heardAt(work, received.signal);
        return;
    }
    if (frames.associationAnswer(bytes, bssid, own)) |answer| {
        if (join.state != .joining or join.assoc_answered) return;
        join.assoc_status = answer.status;
        join.assoc_aid = answer.aid;
        join.assoc_answered = true;
        heardAt(work, received.signal);
        if (answer.status == 0) {
            // Its rates, HT and QoS as the answer gives them.
            join.target.rates_len = 0;
            join.target.ht = false;
            join.target.wmm = false;
            _ = scan.readElements(&join.target, answer.elements);
        }
        return;
    }
    if (frames.leaveReason(bytes, bssid, own)) |reason| {
        join.thrown_due = reason;
        return;
    }
    if (join.state == .joining or bytes[0] != frames.FC_ACTION) return;
    const buffer = tx.frameBuffer(work) orelse return;
    const length = frames.declineBlockAck(buffer, bytes, bssid, own);
    if (length != 0) tx.sendManagement(work, length, peer.WCID_AP, join.rate);
}

fn heardAt(work: *Work, signal: i8) void {
    const join = &work.join;
    if (signal == -128) return;
    join.signal_sum += signal;
    join.signal_count += 1;
}

/// An Ethernet frame from the network: an EAPOL one to the handshake,
/// every other to the unit once the network is joined.
fn dataIn(work: *Work, packet: []const u8) void {
    const join = &work.join;
    if (packet.len < ethernet.header_bytes) return;
    if (mcu.getBe16(packet, 12) == ETHERTYPE_EAPOL) {
        const eapol = packet[ethernet.header_bytes..];
        if (join.state == .joining) {
            // Kept until the firmware has been told the network.
            if (eapol.len > join.eapol.len) return;
            @memcpy(join.eapol[0..eapol.len], eapol);
            join.eapol_len = eapol.len;
            return;
        }
        return toHandshake(work, eapol);
    }
    if (join.state == .joined and work.running) work.base.net.receive(packet);
}

fn toHandshake(work: *Work, eapol: []const u8) void {
    const handshake = work.join.handshake orelse return;
    radio.wpaBase(work).?.HandshakeFrame(handshake, eapol.ptr, @intCast(eapol.len));
}

/// The firmware has the channel asked for under `token`.
pub fn granted(work: *Work, token: u8) void {
    if (token == work.join.token) work.join.granted = true;
}

/// The firmware no longer hears the network's beacons.
pub fn beaconsLost(work: *Work) void {
    if (work.join.state != .idle) work.join.lost_due = true;
}

/// A frame of the handshake's is through the chip.
pub fn frameGone(work: *Work, number: u32) void {
    const join = &work.join;
    if (join.handshake == null) return;
    join.sent_number = number;
    join.sent_due = true;
}

// --- the handshake -------------------------------------------------------------------

/// What the handshake asks, from inside HandshakeFrame and HandshakeSent:
/// a frame sent at once, everything else noted for `due`.
fn handshakeHook(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const work: *Work = @ptrCast(@alignCast(hook.data.?));
    const join = &work.join;
    const asked: *const wpa.HandshakeMessage = @ptrCast(@alignCast(message orelse return 0));
    switch (asked.kind) {
        wpa.WPAHM_SEND => {
            const sent = (asked.data orelse return 0)[0..asked.length];
            const buffer = tx.frameBuffer(work) orelse return 0;
            if (sent.len > ethernet.frame_max) return 0;
            @memcpy(buffer[0..sent.len], sent);
            var data = dataTo(work, tx.TID_VOICE);
            data.number = asked.number;
            tx.sendData(work, sent.len, data);
        },
        wpa.WPAHM_PAIRWISEKEY, wpa.WPAHM_GROUPKEY => {
            const key = if (asked.kind == wpa.WPAHM_PAIRWISEKEY) &join.pairwise_key else &join.group_key;
            const length = @min(asked.length, key.bytes.len);
            @memcpy(key.bytes[0..length], (asked.data orelse return 0)[0..length]);
            key.length = @intCast(length);
            key.index = @truncate(asked.index);
            key.due = true;
        },
        wpa.WPAHM_AUTHORIZED => join.authorized_due = true,
        wpa.WPAHM_LEAVE => join.leave_due = @truncate(asked.reason),
        else => {},
    }
    return 0;
}

/// A protected network's side made ready: wpa.library opened, the
/// station's element made from the access point's, the network's key
/// made (or the one kept), and the handshake made. The station element's
/// length; null, said in the log, when the network can't be joined.
fn prepareKeys(work: *Work) ?usize {
    const join = &work.join;
    const sys = work.sys;
    const found = &join.target;
    const wb = radio.wpaBase(work) orelse {
        say(sys, "a protected network needs LIBS:wpa.library", .{});
        return null;
    };
    if (found.rsn_len == 0) {
        say(sys, "the network is WEP or WPA: only WPA2 is joined", .{});
        return null;
    }
    const own_length = wb.StationElement(&found.rsn, &join.own_element, join.own_element.len);
    if (own_length == 0) {
        say(sys, "the network asks for a security this station can't do (WPA2-Personal with CCMP is)", .{});
        return null;
    }
    if (join.want_pass[0] == 0) {
        say(sys, "the network is protected, and no passphrase was given", .{});
        return null;
    }
    const passphrase: [*:0]const u8 = @ptrCast(&join.want_pass);
    const name = found.name();
    const kept = join.key_made and join.key_ssid_len == name.len and
        scan.sameBytes(join.key_ssid[0..name.len], name) and scan.sameBytes(&join.key_pass, &join.want_pass);
    if (!kept) {
        join.key_made = false;
        if (!wb.PassphraseKey(passphrase, name.ptr, @intCast(name.len), &join.key)) {
            say(sys, "the passphrase makes no key: 8 to 63 characters, or 64 hex digits", .{});
            return null;
        }
        @memcpy(join.key_ssid[0..name.len], name);
        join.key_ssid_len = name.len;
        join.key_pass = join.want_pass;
        join.key_made = true;
    }
    const tags = [_]TagItem{
        .{ .tag = wpa.WPAH_Key, .data = @intFromPtr(&join.key) },
        .{ .tag = wpa.WPAH_Authenticator, .data = @intFromPtr(&found.bssid) },
        .{ .tag = wpa.WPAH_Supplicant, .data = @intFromPtr(&work.station) },
        .{ .tag = wpa.WPAH_StationElement, .data = @intFromPtr(&join.own_element) },
        .{ .tag = wpa.WPAH_NetworkElement, .data = @intFromPtr(&found.rsn) },
        .{ .tag = wpa.WPAH_Hook, .data = @intFromPtr(&join.hook) },
        .{},
    };
    join.handshake = wb.CreateHandshake(&tags) orelse {
        say(sys, "no memory for the key handshake", .{});
        return null;
    };
    return own_length;
}

/// The handshake given up, and what it left undone with it.
fn dropHandshake(work: *Work) void {
    const join = &work.join;
    if (join.handshake) |handshake| radio.wpaBase(work).?.DeleteHandshake(handshake);
    join.handshake = null;
    join.sent_due = false;
    join.authorized_due = false;
    join.eapol_len = 0;
    wipe(&join.pairwise_key);
    wipe(&join.group_key);
}

fn wipe(key: *Key) void {
    const bytes: [*]volatile u8 = @ptrCast(&key.bytes);
    @memset(bytes[0..key.bytes.len], 0);
    key.* = .{};
}
