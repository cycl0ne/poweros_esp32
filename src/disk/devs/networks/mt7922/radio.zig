// SPDX-License-Identifier: MIT
//! The radio: what the chip receives besides the answers to commands,
//! the events the firmware sends by itself, the unit's requests, and
//! scans. What the chip received goes where it belongs: a note of frames
//! sent to the sending (tx.zig), a frame to the scan while one runs and
//! to the join (join.zig), the firmware's grant of a channel and its loss
//! of a network's beacons to the join.
//!
//! **A scan** is started by the first S2_GETNETWORKS while none runs,
//! for the network that request names if it names one (scan.zig); every
//! S2_GETNETWORKS that comes while it runs waits for it. What the chip
//! hears meanwhile is taken off the data ring and kept (`Heard`). The
//! firmware's scan-done event ends it, once the frames that came before
//! it are taken too - they are on the data ring, the event on the
//! firmware's - and every request waiting is answered: the networks
//! heard, each a tag list in the caller's pool, how each is protected
//! read by wpa.library. A scan the firmware has not ended after
//! `scan_limit_ms` is cancelled and answered the same way.
//!
//! **A join's scan** is the same, waited for by the join itself
//! (`scanFor`).
//!
//! **The clock** wakes the worker every `tick_ms` while something waits
//! for time - a scan's limit, a join's deadline, the channel's time, the
//! pause before joining again - and not otherwise, so the worker sleeps
//! while nothing waits.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const wireless = sdk.devices.wireless;
const timer = sdk.devices.timer;
const wpa = sdk.wpa;
const TagItem = sdk.utility.TagItem;
const _mt = @import("_mt7922.zig");
const mcu = @import("mcu.zig");
const rxd = @import("rxd.zig");
const scan = @import("scan.zig");
const station = @import("station.zig");
const peer = @import("peer.zig");
const tx = @import("tx.zig");
const joining = @import("join.zig");
const Work = _mt.Work;
const say = _mt.say;

/// How long a scan may take before it is cancelled: every channel
/// listened on for longer than the firmware takes.
const scan_limit_ms = 20_000;
/// How often the clock wakes the worker while something waits for time.
const tick_ms = 250;

/// A buffer the chip filled that is not an event: a frame, a send's
/// status, a note of frames sent.
pub fn received(work: *Work, kind: u32, bytes: []const u8) void {
    switch (kind) {
        mcu.PKT_TYPE_TXRX_NOTIFY => return tx.freed(work, bytes),
        mcu.PKT_TYPE_NORMAL, mcu.PKT_TYPE_NORMAL_MCU, mcu.PKT_TYPE_RX_EVENT => {},
        else => return,
    }
    const frame = rxd.read(bytes, station.chainMask(work)) orelse return;
    if (work.scanning) {
        if (scan.network(frame)) |found| work.heard.add(found);
    }
    joining.frame(work, frame);
}

/// An event the firmware sent by itself: a unified one, or one of the
/// older kind, by its id.
pub fn event(work: *Work, eid: u8, unified: bool, bytes: []const u8) void {
    if (unified) {
        if (eid == mcu.UNI_EVENT_ROC) {
            if (peer.grantOf(bytes)) |token| joining.granted(work, token);
        }
        return;
    }
    switch (eid) {
        mcu.EVENT_SCAN_DONE => if (work.scanning) {
            work.scan_done = true;
        },
        mcu.EVENT_BSS_BEACON_LOSS => joining.beaconsLost(work),
        else => {},
    }
}

/// What the events and frames just taken leave to be done, done.
pub fn due(work: *Work) void {
    if (work.scan_done) endScan(work, 0);
    while (joining.due(work)) {}
}

/// The clock came back: a scan past its limit is cancelled, the join's
/// times looked at, and the clock asked again while anything waits.
pub fn tick(work: *Work) void {
    if (work.scanning and passed(elapsed(work), work.scan_ends)) cancelScan(work);
    const join_waits = joining.tick(work);
    if (work.scanning or join_waits) armClock(work, tick_ms);
}

/// The clock asked to wake the worker, if it is not asked already: a
/// scan or a join has started to wait for time.
pub fn keepTime(work: *Work) void {
    armClock(work, tick_ms);
}

fn passed(now: u32, at: u32) bool {
    const left: i32 = @bitCast(at -% now);
    return left <= 0;
}

/// A request of the unit's openers.
pub fn request(work: *Work, req: *net.IOSana2Req) void {
    const base = work.base;
    const sys = base.sys_base;
    switch (req.req.command) {
        wireless.S2_GETNETWORKS => {
            sys.AddTail(&work.scans, &req.req.message.node);
            if (!work.scanning) startScan(work, wantedName(work, req));
        },
        else => if (!joining.request(work, req)) base.net.perform(req),
    }
}

/// The network left and everything waiting answered as out of service:
/// the device is going.
pub fn stop(work: *Work) void {
    joining.stop(work);
    work.scanning = false;
    work.scan_done = false;
    answerScans(work, net.S2ERR_OUTOFSERVICE);
}

// --- scanning -------------------------------------------------------------------

/// A scan for the network `name`, waited for: its networks in `heard`.
/// One already running is waited for instead.
pub fn scanFor(work: *Work, name: []const u8) void {
    if (!work.scanning) startScan(work, name);
    while (work.scanning and !work.scan_done) {
        if (passed(elapsed(work), work.scan_ends)) return cancelScan(work);
        _ = mcu.takeEvents(work, 0);
        if (work.scan_done) break;
        work.pause(1000);
    }
    if (work.scanning) endScan(work, 0);
}

fn startScan(work: *Work, ssid: []const u8) void {
    work.heard.count = 0;
    work.scan_done = false;
    work.scan_seq = (work.scan_seq +% 1) & 0x7f;
    if (work.scan_seq == 0) work.scan_seq = 1;
    const payload = work.scratch[0..scan.request_bytes];
    scan.request(payload, work.scan_seq, work.has_5g, ssid);
    // Frames heard are kept from here: a command waited for later takes
    // them off the ring too.
    work.scanning = true;
    _ = mcu.send(work, mcu.ce(mcu.CE_START_HW_SCAN), payload, false) catch |failure| {
        work.scanning = false;
        say(work.sys, "the scan cannot be started: %s", .{@as([*:0]const u8, @errorName(failure))});
        return answerScans(work, net.S2ERR_SOFTWARE);
    };
    work.scan_ends = elapsed(work) +% scan_limit_ms;
    keepTime(work);
}

fn cancelScan(work: *Work) void {
    say(work.sys, "the scan is not done in time: cancelled", .{});
    _ = mcu.send(work, mcu.ce(mcu.CE_CANCEL_HW_SCAN), &[_]u8{ work.scan_seq & 0x7f, 0, 0, 0 }, false) catch {};
    endScan(work, 0);
}

fn endScan(work: *Work, err: i8) void {
    work.scanning = false;
    work.scan_done = false;
    answerScans(work, err);
}

/// The name the request asks for, if it names one.
fn wantedName(work: *Work, req: *net.IOSana2Req) []const u8 {
    const text = askedName(work, req) orelse return "";
    var length: usize = 0;
    while (length < scan.ssid_max and text[length] != 0) length += 1;
    return text[0..length];
}

fn askedName(work: *Work, req: *net.IOSana2Req) ?[*:0]const u8 {
    const params: ?[*]const TagItem = @ptrCast(@alignCast(req.stat_data));
    const list = params orelse return null;
    return @ptrFromInt(work.base.utility.?.GetTagData(wireless.S2INFO_SSID, 0, list));
}

/// Every S2_GETNETWORKS waiting answered: from the scan just ended, or
/// with `err`.
fn answerScans(work: *Work, err: i8) void {
    const sys = work.sys;
    while (sys.RemHead(&work.scans)) |node| {
        const message: *exec.Message = @alignCast(@fieldParentPtr("node", node));
        const req = _mt.sanaReq(_mt.requestOf(message));
        if (err == 0) answerNetworks(work, req) else req.req.err = err;
        sys.ReplyMsg(message);
    }
}

fn sameName(name: []const u8, wanted: ?[*:0]const u8) bool {
    const text = wanted orelse return true;
    for (name, 0..) |char, index| {
        if (text[index] != char) return false;
    }
    return text[name.len] == 0;
}

/// Tags per network: name, access point, channel, signal, how it is
/// joined, its cipher, the end.
const tags_per_network = 7;

/// One S2_GETNETWORKS answered: a tag list per network heard (with the
/// name asked for, if one was), in the caller's pool.
fn answerNetworks(work: *Work, req: *net.IOSana2Req) void {
    const sys = work.sys;
    const pool = req.data;
    const wanted = askedName(work, req);
    const wb = wpaBase(work);
    var count: usize = 0;
    for (work.heard.list()) |*found| {
        if (found.ssid_len != 0 and sameName(found.name(), wanted)) count += 1;
    }
    req.data_length = 0;
    const lists: [*]?[*]TagItem = @ptrCast(@alignCast(sys.AllocPooled(pool, @max(count, 1) * @sizeOf(usize)) orelse {
        req.req.err = net.S2ERR_NO_RESOURCES;
        return;
    }));
    var made: usize = 0;
    for (work.heard.list()) |*found| {
        if (found.ssid_len == 0 or !sameName(found.name(), wanted)) continue;
        const tags: [*]TagItem = @ptrCast(@alignCast(sys.AllocPooled(pool, tags_per_network * @sizeOf(TagItem) + scan.ssid_max + 1 + 6) orelse break));
        const ssid: [*]u8 = @as([*]u8, @ptrCast(tags)) + tags_per_network * @sizeOf(TagItem);
        @memcpy(ssid[0..found.ssid_len], found.name());
        ssid[found.ssid_len] = 0;
        const bssid = ssid + scan.ssid_max + 1;
        @memcpy(bssid[0..6], &found.bssid);
        tags[0] = .{ .tag = wireless.S2INFO_SSID, .data = @intFromPtr(ssid) };
        tags[1] = .{ .tag = wireless.S2INFO_BSSID, .data = @intFromPtr(bssid) };
        tags[2] = .{ .tag = wireless.S2INFO_Channel, .data = found.channel };
        tags[3] = .{ .tag = wireless.S2INFO_Signal, .data = @bitCast(@as(isize, found.signal)) };
        tags[4] = .{ .tag = wireless.S2INFO_AuthMode, .data = found.authMode(wb) };
        tags[5] = .{ .tag = wireless.S2INFO_Encryption, .data = found.encryption(wb) };
        tags[6] = .{};
        lists[made] = tags;
        made += 1;
    }
    req.stat_data = @ptrCast(lists);
    req.data_length = @intCast(made);
}

/// wpa.library, opened the first time a network's security is read; null
/// without it, when the networks are listed by their privacy alone.
pub fn wpaBase(work: *Work) ?*sdk.interface.wpa.WPABase {
    const base = work.base;
    if (base.wpa_base == null) base.wpa_base = @ptrCast(@alignCast(work.sys.OpenLibrary(wpa.WPANAME, 1)));
    return base.wpa_base;
}

// --- the clock --------------------------------------------------------------------

/// The clock asked to wake the worker in `ms` milliseconds, unless it is
/// asked already - its answer then looks again.
fn armClock(work: *Work, ms: u32) void {
    if (work.clock_busy) return;
    work.clock_io.node.command = timer.TR_ADDREQUEST;
    work.clock_io.time = .{ .secs = ms / 1000, .micro = (ms % 1000) * 1000 };
    work.sys.SendIO(&work.clock_io.node);
    work.clock_busy = true;
}

/// Milliseconds since the system started, as the system timer counts
/// them: not the system time, which moves when it is set.
pub fn elapsed(work: *const Work) u32 {
    return @truncate(work.sys.UptimeUs() / 1000);
}
