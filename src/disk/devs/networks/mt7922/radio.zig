// SPDX-License-Identifier: MIT
//! The radio: what the chip receives besides the answers to commands,
//! the events the firmware sends by itself, the unit's requests, and
//! scans.
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
//! **The clock** wakes the worker for a scan's limit; it is not asked to
//! wake it at any other time, so the worker sleeps while nothing waits.
//!
//! The station is not on any network yet: frames that are not a scan's
//! are dropped, and the other wireless requests are answered as out of
//! service.

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
const Work = _mt.Work;
const say = _mt.say;

/// How long a scan may take before it is cancelled: every channel
/// listened on for longer than the firmware takes.
const scan_limit_ms = 20_000;

/// A buffer the chip filled that is not an event: a frame, a send's
/// status, a note of frames sent.
pub fn received(work: *Work, kind: u32, bytes: []const u8) void {
    if (!work.scanning) return;
    switch (kind) {
        mcu.PKT_TYPE_NORMAL, mcu.PKT_TYPE_NORMAL_MCU, mcu.PKT_TYPE_RX_EVENT => {},
        else => return,
    }
    const frame = rxd.read(bytes, station.chainMask(work)) orelse return;
    const found = scan.network(frame) orelse return;
    work.heard.add(found);
}

/// An event the firmware sent by itself.
pub fn event(work: *Work, eid: u8, bytes: []const u8) void {
    _ = bytes;
    switch (eid) {
        mcu.EVENT_SCAN_DONE => if (work.scanning) {
            work.scan_done = true;
        },
        else => {},
    }
}

/// What the events and frames just taken leave to be done, done.
pub fn due(work: *Work) void {
    if (work.scan_done) endScan(work, 0);
}

/// The clock came back: a scan past its limit is cancelled, and the
/// clock asked again while one runs.
pub fn tick(work: *Work) void {
    if (!work.scanning) return;
    const now = elapsed(work);
    const left: i32 = @bitCast(work.scan_ends -% now);
    if (left > 0) return armClock(work, @intCast(left));
    say(work.sys, "the scan is not done in time: cancelled", .{});
    _ = mcu.send(work, mcu.ce(mcu.CE_CANCEL_HW_SCAN), &[_]u8{ work.scan_seq & 0x7f, 0, 0, 0 }, false) catch {};
    endScan(work, 0);
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
        wireless.S2_SETOPTIONS, wireless.S2_GETNETWORKINFO, wireless.S2_GETSIGNALQUALITY => {
            req.req.err = net.S2ERR_OUTOFSERVICE;
            req.wire_error = net.S2WERR_UNIT_OFFLINE;
            sys.ReplyMsg(&req.req.message);
        },
        else => base.net.perform(req),
    }
}

/// Everything waiting answered as out of service: the device is going.
pub fn stop(work: *Work) void {
    work.scanning = false;
    work.scan_done = false;
    answerScans(work, net.S2ERR_OUTOFSERVICE);
}

// --- scanning -------------------------------------------------------------------

fn startScan(work: *Work, ssid: []const u8) void {
    work.heard = .{};
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
    armClock(work, scan_limit_ms);
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
fn wpaBase(work: *Work) ?*sdk.interface.wpa.WPABase {
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
fn elapsed(work: *const Work) u32 {
    return @truncate(work.sys.UptimeUs() / 1000);
}
