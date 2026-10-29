// SPDX-License-Identifier: MIT
//! The radio at work, on the device's worker: the firmware's frames in,
//! the unit's frames out, its requests, and scans.
//!
//! **Woken by the chip.** The card's interrupt (cyw43455.zig's server)
//! wakes the worker when the chip has something for it, and so does a
//! request; it then looks at the SDIO core's interrupt status, reads
//! every frame the firmware has, and turns the card's interrupt on again
//! before it waits. A timer wakes it too, every tenth of a second, for
//! what is due by the clock - a scan or a join that takes too long, a
//! join after its pause - and in case an interrupt went astray; every
//! few milliseconds, as the only way to the chip, where the board gives
//! no interrupt. A frame that comes while the worker waits for the
//! answer to a command is handed here too (bcdc.zig), so nothing is lost
//! meanwhile - which is why what a frame's handler needs a command for
//! is only noted, and done once the worker is back in its loop.
//!
//! **Frames.** An event goes to what waits for it; a data frame - an
//! Ethernet frame behind a BCDC header - to the unit, and the unit's
//! writes out the same way, while the firmware gives the host credit.
//!
//! **Scanning** (S2_GETNETWORKS): the firmware's escan, whose results come
//! as events; every request that comes while one runs is answered with
//! the same networks.
//!
//! **Joining** (S2_SETOPTIONS) is answered at once and done after: a scan
//! for the network, its strongest access point taken (or the one asked
//! for), and the firmware told the security and to join (join.zig). It
//! authenticates and associates by itself, and says so (E_SET_SSID); an
//! open network is then joined, and the unit has its carrier.
//!
//! **A WPA2-Personal network** is joined with wpa.library, as the
//! aic8800's: the network's key made from the passphrase (and kept for
//! the next join of the same network), and the station's RSN element
//! made from the access point's and given the firmware for its
//! association request. The firmware does not always send it: on the
//! first join after it comes up it puts in its own, whose capabilities
//! differ - and message 2 must repeat the element the access point was
//! sent, or it throws the station off. So the handshake is made, as
//! Linux's wpa_supplicant makes it, with the element the association
//! request really carried ("assoc_req_ies"), once it is over: the access
//! point's first EAPOL frame is held until then. Its EAPOL frames go to
//! the handshake; the frames it answers with go out first, before the
//! unit's, and the handshake is told each has gone once it is written to
//! the chip (Linux waits no longer before a key goes in). The keys it
//! hands over through its hook are given the firmware ("wsec_key"): only
//! then has the unit its carrier.
//!
//! **A network asked for stays wanted** until it is left
//! (S2INFO_Disassociate). Coming off it for any reason but its own leave -
//! thrown off, refused, not found, not joined in time - the station tries
//! again after a pause: a second, twice as long each time, up to a
//! minute; joining resets it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const wireless = sdk.devices.wireless;
const timer = sdk.devices.timer;
const systimer = sdk.hardware.systimer;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const _cyw = @import("_cyw43455.zig");
const host_file = @import("host.zig");
const sdpcm = @import("sdpcm.zig");
const bcdc = @import("bcdc.zig");
const events = @import("events.zig");
const scan = @import("scan.zig");
const join_file = @import("join.zig");
const wpa = sdk.wpa;
const utility = sdk.utility;
const WPABase = sdk.interface.wpa.WPABase;
const CywBase = _cyw.CywBase;
const Error = host_file.Error;
const DEVICE_NAME = _cyw.DEVICE_NAME;

/// How often the worker wakes by itself: with the chip's interrupt, and
/// without it, when it is the only way to the chip. How many of its
/// frames are read at a time: Linux's bound.
const tick_us = 100_000;
const poll_us = 5_000;
const rx_bound = 50;
/// How long a scan may take before it is ended with what it heard.
const scan_ms = 10_000;
/// How long a join may take - associating and the key handshake -
/// before it is given up.
const join_ms = 15_000;
/// The first pause before joining again, and the longest, in seconds.
const pause_first_s = 1;
const pause_most_s = 60;
/// The reason the station gives for its own leave: it is leaving.
const REASON_LEAVING: u32 = 3;

/// The commands the radio is set up with: up, a station's, power saving
/// off, and the minimum power consumption - the radio off while nothing
/// uses it - off too, so a scan and a join need no more.
const C_UP: u32 = 2;
const C_SET_INFRA: u32 = 20;
const C_SET_PM: u32 = 86;
const PM_OFF: u32 = 0;

/// BCDC's header of a data frame: its version, no priority, interface 0,
/// nothing between it and the frame.
const BCDC_DATA_FLAGS: u8 = 2 << 4;
const bcdc_data_header = 4;

/// The events the radio takes.
const wanted_events = [_]u32{
    events.E_IF,
    events.E_ESCAN_RESULT,
    events.E_SET_SSID,
    events.E_LINK,
    events.E_DEAUTH,
    events.E_DEAUTH_IND,
    events.E_DISASSOC_IND,
};

/// The Ethernet type of EAPOL, the key handshake's frames; the longest
/// held.
const ETHER_TYPE_EAPOL: u16 = 0x888E;
const ether_header = 14;
const held_max = 256;
/// The longest station element a handshake keeps, and the room the
/// association request's elements are read into.
const element_max = 64;
const assoc_bytes = 512;

/// A key the handshake handed over, waiting to go to the firmware.
const Key = struct {
    bytes: [32]u8 = @splat(0),
    length: u8 = 0,
    index: u8 = 0,
    algo: u32 = 0,
    rsc: [8]u8 = @splat(0),
    due: bool = false,
};

/// The worker's state while the radio runs.
pub const Work = struct {
    base: *CywBase,
    /// S2_GETNETWORKS waiting for a scan; the networks the last one heard.
    scans: exec.List = .{},
    heard: scan.Heard = .{},
    /// A scan to start, one running - since when, and the ID its results
    /// carry.
    scan_due: bool = false,
    scanning: bool = false,
    scan_id: u16 = 0,
    scan_started: u32 = 0,
    /// The timer, and whether it is out; whether the firmware had frames
    /// past the bound.
    poll_io: timer.TimeRequest = .{},
    poll_out: bool = false,
    frames_left: bool = false,
    /// The network asked for; whether a join of it is to be made - after
    /// a scan for it, from when.
    wanted: bool = false,
    join_due: bool = false,
    join_scanned: bool = false,
    join_at: u32 = 0,
    want_ssid: [scan.ssid_max + 1]u8 = @splat(0),
    want_len: usize = 0,
    want_bssid: ?[6]u8 = null,
    want_pass: [wpa.WPA_PASSPHRASE_MAX + 1]u8 = @splat(0),
    /// The network being joined or joined, whether it is protected, what
    /// is done of the join so far - associated, the keys in - and when it
    /// is given up.
    state: State = .idle,
    target: scan.Network = .{},
    protected: bool = false,
    associated: bool = false,
    keyed: bool = false,
    deadline: u32 = 0,
    /// wpa.library, opened for the first protected network.
    wpa_base: ?*WPABase = null,
    /// The network's key, and the name and passphrase it was made from.
    key: [wpa.WPA_KEY_BYTES]u8 = @splat(0),
    key_ssid: [scan.ssid_max]u8 = @splat(0),
    key_ssid_len: usize = 0,
    key_pass: [wpa.WPA_PASSPHRASE_MAX + 1]u8 = @splat(0),
    key_made: bool = false,
    /// The station's RSN element, the handshake, and its hook; the access
    /// point's first EAPOL frame, held until the handshake is made.
    own_element: [wpa.WPA_ELEMENT_MAX]u8 = @splat(0),
    handshake: ?*wpa.Handshake = null,
    hook: utility.Hook = .{},
    held: [held_max]u8 = @splat(0),
    held_len: usize = 0,
    /// The handshake's frame waiting to go, behind BCDC's header, with its
    /// length and the handshake's number for it; and the number of the
    /// one gone, for the handshake to be told.
    control: [bcdc_data_header + 256]u8 = @splat(0),
    control_len: usize = 0,
    control_number: u32 = 0,
    sent_due: bool = false,
    sent_number: u32 = 0,
    /// The keys it handed over, and whether the port may open.
    pairwise_key: Key = .{},
    group_key: Key = .{},
    authorized_due: bool = false,
    /// A leave to be told the firmware, and the pause before joining
    /// again.
    leave_due: bool = false,
    pause_s: u32 = pause_first_s,
};

pub const State = enum(u8) { idle, joining, joined };

fn say(sys: *ExecBase, comptime text: [:0]const u8) void {
    exec.kprintf(sys, "%s: " ++ text ++ "\n", .{@as([*:0]const u8, DEVICE_NAME)});
}

fn sayError(sys: *ExecBase, comptime text: [:0]const u8, err: Error) void {
    exec.kprintf(sys, "%s: " ++ text ++ ": %s\n", .{ @as([*:0]const u8, DEVICE_NAME), @as([*:0]const u8, @errorName(err)) });
}

pub fn workOf(base: *CywBase) ?*Work {
    return @ptrCast(@alignCast(base.work orelse return null));
}

/// The radio set up for a station: the events it takes, the antenna, its
/// power saving off, and up. False, said, if the firmware refuses.
pub fn setUp(base: *CywBase) bool {
    const sys = base.sys_base;
    host_file.antenna(sys, &base.host);
    setUpCommands(base) catch |err| {
        sayError(sys, "the radio cannot be set up", err);
        return false;
    };
    return true;
}

fn setUpCommands(base: *CywBase) Error!void {
    const sys = base.sys_base;
    const status = try events.enable(base, &wanted_events);
    if (status != 0) exec.kprintf(sys, "%s: the firmware refuses its events: %d\n", .{ @as([*:0]const u8, DEVICE_NAME), status });
    _ = try bcdc.setVar32(base, "mpc", 0);
    // No roaming of the firmware's own: it would associate elsewhere
    // under the handshake made for the access point joined. The station
    // stays on it, and joins the network again when it comes off.
    _ = try bcdc.setVar32(base, "roam_off", 1);
    _ = try bcdc.set32(base, C_SET_PM, PM_OFF);
    _ = try bcdc.set32(base, C_SET_INFRA, 1);
    const up = try bcdc.set32(base, C_UP, 1);
    if (up != 0) {
        exec.kprintf(sys, "%s: the radio does not come up: %d\n", .{ @as([*:0]const u8, DEVICE_NAME), up });
        return error.Failed;
    }
}

/// The worker's state made, its poll timer from the worker's own. Null
/// if there is no memory.
pub fn makeWork(base: *CywBase) ?*Work {
    const sys = base.sys_base;
    const memory = sys.AllocVec(@sizeOf(Work), exec.MEMF_CLEAR) orelse return null;
    const work: *Work = @ptrCast(@alignCast(memory));
    work.* = .{ .base = base };
    work.scans.init(.message);
    work.hook = .{ .entry = &handshakeHook, .data = work };
    work.poll_io = base.timer_io;
    work.poll_io.node.message.reply_port = &base.poll_port;
    base.work = work;
    return work;
}

/// The worker's loop, for good: the unit's requests, the timer, and the
/// chip looked at after each and whenever it interrupts - its interrupt
/// on again before the worker waits. Frames left past the bound are read
/// at once.
pub fn run(work: *Work) noreturn {
    const base = work.base;
    const sys = base.sys_base;
    const every_us: u64 = if (base.int_hooked != 0) tick_us else poll_us;
    while (true) {
        while (sys.GetMsg(&base.poll_port)) |_| work.poll_out = false;
        while (sys.GetMsg(&base.unit.msg_port)) |message| request(work, _cyw.sanaReq(_cyw.requestOf(message)));
        service(work);
        if (work.frames_left) continue;
        if (!work.poll_out) {
            work.poll_io.node.command = timer.TR_ADDREQUEST;
            work.poll_io.time = timer.TimeVal.fromMicros(every_us);
            sys.SendIO(&work.poll_io.node);
            work.poll_out = true;
        }
        if (base.int_hooked != 0 and base.running != 0) host_file.cardInterrupt(&base.host, true);
        _ = sys.Wait(base.work_mask);
    }
}

/// The chip looked at: its frames read and handed on; then a leave or a
/// join made, a scan started or ended, a join that takes too long given
/// up, and the unit's writes sent.
fn service(work: *Work) void {
    const base = work.base;
    work.frames_left = false;
    if (base.running == 0) return;
    work.frames_left = readFrames(base) catch |err| left: {
        sayError(base.sys_base, "the firmware's frames cannot be read", err);
        break :left false;
    };
    if (work.leave_due) leave(work);
    if (work.join_due) joinStep(work);
    if (work.scan_due) startScan(work);
    if (work.scanning and elapsed() -% work.scan_started > scan_ms) {
        say(base.sys_base, "the scan did not finish");
        endScan(work);
    }
    sendWrites(work);
    handshakeDue(work);
    if (work.state == .joining and reached(work.deadline)) {
        const progress: u32 = if (work.handshake) |handshake| work.wpa_base.?.HandshakeStatus(handshake) else 0;
        exec.kprintf(base.sys_base, "%s: the network was not joined in time: %s, handshake %s\n", .{
            @as([*:0]const u8, DEVICE_NAME),
            @as([*:0]const u8, if (work.associated) "associated" else "not associated"),
            @as([*:0]const u8, switch (progress) {
                wpa.WPAHS_RUNNING => "under way",
                wpa.WPAHS_DONE => "done",
                else => "not begun",
            }),
        });
        leave(work);
        cameOff(work);
    }
}

/// The firmware's frames read and handed on, up to the bound: whether it
/// has more.
fn readFrames(base: *CywBase) Error!bool {
    try sdpcm.poll(base);
    for (0..rx_bound) |_| {
        const frame = (try sdpcm.receive(base)) orelse return false;
        frameIn(base, frame);
    }
    return true;
}

/// A frame from the firmware that answers no command: an event to what
/// waits for it, an EAPOL frame to the handshake, every other data frame
/// to the unit once the network is joined. Dropped before the worker's
/// state is made.
pub fn frameIn(base: *CywBase, frame: sdpcm.Frame) void {
    const work = workOf(base) orelse return;
    if (frame.channel != sdpcm.CHANNEL_EVENT and frame.channel != sdpcm.CHANNEL_DATA) return;
    const packet = events.packetOf(frame.payload) orelse return;
    if (frame.channel == sdpcm.CHANNEL_EVENT or events.isBroadcom(packet)) {
        if (events.parse(packet)) |event| eventIn(work, event);
        return;
    }
    if (packet.len > ether_header and std.mem.readInt(u16, packet[12..14], .big) == ETHER_TYPE_EAPOL) {
        if (work.state == .idle or !work.protected) return;
        const eapol = packet[ether_header..];
        if (work.handshake) |handshake| {
            work.wpa_base.?.HandshakeFrame(handshake, eapol.ptr, @intCast(eapol.len));
        } else if (eapol.len <= work.held.len) {
            // The first: held until the handshake is made (`handshakeDue`).
            @memcpy(work.held[0..eapol.len], eapol);
            work.held_len = eapol.len;
        }
        return;
    }
    if (work.state == .joined and base.net.online != 0) base.net.receive(packet);
}

fn eventIn(work: *Work, event: events.Event) void {
    const sys = work.base.sys_base;
    switch (event.kind) {
        events.E_ESCAN_RESULT => {
            if (!work.scanning) return;
            if (event.status == events.STATUS_PARTIAL) {
                _ = scan.results(event.data, &work.heard);
            } else {
                endScan(work);
            }
        },
        events.E_SET_SSID => {
            if (work.state != .joining) return;
            if (event.status != events.STATUS_SUCCESS) {
                exec.kprintf(sys, "%s: the network was not joined: status %u\n", .{ @as([*:0]const u8, DEVICE_NAME), event.status });
                work.leave_due = true;
                return cameOff(work);
            }
            work.associated = true;
            joined(work);
        },
        events.E_LINK => {
            if (event.flags & events.FLAG_LINK == 0) lost(work, event.reason);
        },
        events.E_DEAUTH, events.E_DEAUTH_IND, events.E_DISASSOC_IND => lost(work, event.reason),
        else => {},
    }
}

/// The join done once the firmware associated and - on a protected
/// network - has the handshake's keys: the unit has its carrier.
fn joined(work: *Work) void {
    if (!work.associated or (work.protected and !work.keyed)) return;
    work.state = .joined;
    work.pause_s = pause_first_s;
    exec.kprintf(work.base.sys_base, "%s: joined %s on channel %u\n", .{
        @as([*:0]const u8, DEVICE_NAME),
        @as([*:0]const u8, @ptrCast(&work.want_ssid)),
        @as(u32, work.target.channel),
    });
    work.base.net.setCarrier(true);
}

/// Off the network, the firmware says. Joined, the carrier goes; being
/// joined, the join has failed - the access point threw the station off,
/// or its handshake timed out. Either way the network is joined again
/// after the pause, with a new scan and a new handshake. Idle, it is the
/// station's own leave.
fn lost(work: *Work, reason: u32) void {
    switch (work.state) {
        .idle => return,
        .joining => exec.kprintf(work.base.sys_base, "%s: thrown off while joining: reason %u\n", .{ @as([*:0]const u8, DEVICE_NAME), reason }),
        .joined => {
            exec.kprintf(work.base.sys_base, "%s: off the network: reason %u\n", .{ @as([*:0]const u8, DEVICE_NAME), reason });
            work.state = .idle;
            work.base.net.setCarrier(false);
        },
    }
    work.leave_due = true;
    cameOff(work);
}

/// Off the network without having left it: joined again after the
/// pause, which doubles.
fn cameOff(work: *Work) void {
    if (work.state == .joining) work.state = .idle;
    if (!work.wanted) return;
    work.join_due = true;
    work.join_scanned = false;
    work.join_at = elapsed() +% work.pause_s * 1000;
    work.pause_s = @min(work.pause_s * 2, pause_most_s);
}

/// Milliseconds since the system started, as the system timer counts
/// them: not the system time, which is a date once battclock.resource
/// or C:net/TimeSync has set it, and moves when it is set.
fn elapsed() u32 {
    return @truncate(systimer.uptimeUs() / 1000);
}

/// Whether the time `at` has come.
fn reached(at: u32) bool {
    return @as(i32, @bitCast(elapsed() -% at)) >= 0;
}

// --- the unit's requests --------------------------------------------------

/// A request on the unit's port: a wireless one here, every other the
/// unit's.
fn request(work: *Work, req: *net.IOSana2Req) void {
    const base = work.base;
    const sys = base.sys_base;
    switch (req.req.command) {
        wireless.S2_GETNETWORKS => {
            if (base.running == 0) {
                req.req.err = net.S2ERR_OUTOFSERVICE;
                req.wire_error = net.S2WERR_UNIT_OFFLINE;
                return sys.ReplyMsg(&req.req.message);
            }
            sys.AddTail(&work.scans, &req.req.message.node);
            if (!work.scanning) work.scan_due = true;
        },
        wireless.S2_SETOPTIONS => {
            req.req.err = setOptions(work, req);
            sys.ReplyMsg(&req.req.message);
        },
        wireless.S2_GETNETWORKINFO => {
            req.req.err = networkInfo(work, req);
            sys.ReplyMsg(&req.req.message);
        },
        wireless.S2_GETSIGNALQUALITY => {
            req.req.err = signalQuality(work, req);
            sys.ReplyMsg(&req.req.message);
        },
        else => base.net.perform(req),
    }
}

/// Whether a request is one of the wireless ones the worker answers.
pub fn isWireless(command: u16) bool {
    return switch (command) {
        wireless.S2_GETNETWORKS, wireless.S2_SETOPTIONS, wireless.S2_GETNETWORKINFO, wireless.S2_GETSIGNALQUALITY => true,
        else => false,
    };
}

// --- joining --------------------------------------------------------------

/// `text` copied into `into`: its length, null when it does not fit.
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
    const ub = work.base.utility.?;
    const list: [*]const TagItem = @ptrCast(@alignCast(req.data orelse return net.S2ERR_BAD_ARGUMENT));
    if (ub.FindTagItem(wireless.S2INFO_Disassociate, list) != null) {
        work.wanted = false;
        work.join_due = false;
        if (work.state != .idle) work.leave_due = true;
        return 0;
    }
    const ssid: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(wireless.S2INFO_SSID, 0, list));
    const name = ssid orelse return net.S2ERR_BAD_ARGUMENT;
    var wanted: [scan.ssid_max + 1]u8 = @splat(0);
    const length = copyString(wanted[0..scan.ssid_max], name) orelse return net.S2ERR_BAD_ARGUMENT;
    if (length == 0) return net.S2ERR_BAD_ARGUMENT;
    var passphrase: [wpa.WPA_PASSPHRASE_MAX + 1]u8 = @splat(0);
    const given: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(wireless.S2INFO_Passphrase, 0, list));
    if (given) |text| {
        const passphrase_length = copyString(passphrase[0..wpa.WPA_PASSPHRASE_MAX], text) orelse return net.S2ERR_BAD_ARGUMENT;
        if (passphrase_length < wpa.WPA_PASSPHRASE_MIN) return net.S2ERR_BAD_ARGUMENT;
    }
    work.want_ssid = wanted;
    work.want_len = length;
    work.want_pass = passphrase;
    const bssid: ?[*]const u8 = @ptrFromInt(ub.GetTagData(wireless.S2INFO_BSSID, 0, list));
    work.want_bssid = if (bssid) |address| address[0..6].* else null;
    work.wanted = true;
    work.join_due = true;
    work.join_scanned = false;
    work.join_at = elapsed();
    work.pause_s = pause_first_s;
    if (work.state != .idle) work.leave_due = true;
    return 0;
}

/// A join due: once its time has come and no scan runs, a scan for the
/// network; after it, the join.
fn joinStep(work: *Work) void {
    if (work.scanning or work.scan_due or !reached(work.join_at)) return;
    if (!work.join_scanned) {
        work.join_scanned = true;
        work.scan_due = true;
        return;
    }
    work.join_due = false;
    work.join_scanned = false;
    join(work);
}

/// The network asked for joined: found by the scan, its strongest access
/// point (or the one asked for) given the firmware with the security it
/// asks for.
fn join(work: *Work) void {
    const base = work.base;
    const sys = base.sys_base;
    const name = work.want_ssid[0..work.want_len];
    const found = found: {
        if (work.want_bssid) |bssid| {
            for (work.heard.list()) |*each| {
                if (std.mem.eql(u8, &each.bssid, &bssid)) break :found each;
            }
            break :found null;
        }
        break :found work.heard.strongest(name);
    } orelse {
        say(sys, "the network asked for was not found");
        return cameOff(work);
    };
    work.target = found.*;
    dropHandshake(work);
    work.protected = found.privacy or found.rsn_len != 0 or found.wpa;
    var wsec: u32 = 0;
    var own_length: usize = 0;
    if (work.protected) {
        own_length = prepareKeys(work, found) orelse return;
        // CCMP for the station's own traffic; TKIP too if the group's is.
        wsec = join_file.AES_ENABLED;
        if (scan.rsnSuites(found.rsn[0..found.rsn_len])) |offered| {
            if (offered.group_tkip) wsec |= join_file.TKIP_ENABLED;
        }
    }
    const started = joinCommands(work, wsec, work.own_element[0..own_length]) catch |err| {
        sayError(sys, "the join cannot be started", err);
        work.state = .idle;
        return cameOff(work);
    };
    if (!started) {
        work.state = .idle;
        return cameOff(work);
    }
    work.deadline = elapsed() +% join_ms;
}

/// The firmware told the security and to join: false, said, if it
/// refuses. The join is being made before it is asked for, so that its
/// events and the handshake's first frame are taken however soon they
/// come.
fn joinCommands(work: *Work, wsec: u32, own_element: []const u8) Error!bool {
    const base = work.base;
    const sys = base.sys_base;
    const protected = work.protected;
    if (!try setting(base, "wpa_auth", if (protected) join_file.WPA2_AUTH_PSK else join_file.WPA_AUTH_DISABLED)) return false;
    if (!try setting(base, "auth", join_file.AUTH_OPEN)) return false;
    if (!try setting(base, "wsec", wsec)) return false;
    // The station's element asks for no protected management frames.
    _ = try bcdc.setVar32(base, "mfp", 0);
    const wpaie = try bcdc.setVar(base, "wpaie", own_element);
    if (wpaie != 0) {
        exec.kprintf(sys, "%s: the firmware refuses the station's RSN element: %d\n", .{ @as([*:0]const u8, DEVICE_NAME), wpaie });
        return false;
    }
    work.state = .joining;
    work.associated = false;
    work.keyed = false;
    const name = work.want_ssid[0..work.want_len];
    const params = join_file.params(name, &work.target.bssid, work.target.channel);
    if (try bcdc.setVar(base, "join", &params) == 0) return true;
    // Firmware without "join": the older command, the name alone.
    var ssid = join_file.ssidParams(name);
    const status = try bcdc.command(base, join_file.C_SET_SSID, true, &ssid);
    if (status == 0) return true;
    exec.kprintf(sys, "%s: the firmware refuses the join: %d\n", .{ @as([*:0]const u8, DEVICE_NAME), status });
    return false;
}

/// An iovar of a join set: false, said, if the firmware refuses it.
fn setting(base: *CywBase, comptime name: [:0]const u8, value: u32) Error!bool {
    const status = try bcdc.setVar32(base, name, value);
    if (status == 0) return true;
    exec.kprintf(base.sys_base, "%s: the firmware refuses \"" ++ name ++ "\": %d\n", .{ @as([*:0]const u8, DEVICE_NAME), status });
    return false;
}

/// The network left: the unit without a carrier, and the firmware told.
/// The station is idle first, so the events the leave brings are not
/// taken for being thrown off.
fn leave(work: *Work) void {
    const base = work.base;
    work.leave_due = false;
    const was = work.state;
    work.state = .idle;
    work.associated = false;
    work.keyed = false;
    dropHandshake(work);
    if (was == .joined) base.net.setCarrier(false);
    var params = join_file.scb(REASON_LEAVING, &work.target.bssid);
    _ = bcdc.command(base, join_file.C_DISASSOC, true, &params) catch |err| sayError(base.sys_base, "the network cannot be left", err);
}

/// A protected network's side made ready: wpa.library opened, the
/// station's element made from the access point's, and the network's key
/// made (or the one kept). The station element's length; null, said in
/// the log, when the network can't be joined.
fn prepareKeys(work: *Work, found: *const scan.Network) ?usize {
    const base = work.base;
    const sys = base.sys_base;
    if (work.wpa_base == null) {
        work.wpa_base = @ptrCast(sys.OpenLibrary(wpa.WPANAME, 1) orelse {
            say(sys, "a protected network needs LIBS:wpa.library");
            return null;
        });
    }
    const wb = work.wpa_base.?;
    if (found.rsn_len == 0) {
        say(sys, "the network is WEP or WPA: only WPA2 is joined");
        return null;
    }
    const own_length = wb.StationElement(&found.rsn, &work.own_element, work.own_element.len);
    if (own_length == 0) {
        say(sys, "the network asks for a security this station can't do (WPA2-Personal with CCMP is)");
        return null;
    }
    if (work.want_pass[0] == 0) {
        say(sys, "the network is protected, and no passphrase was given");
        return null;
    }
    const name = found.name();
    const kept = work.key_made and work.key_ssid_len == name.len and
        std.mem.eql(u8, work.key_ssid[0..name.len], name) and std.mem.eql(u8, &work.key_pass, &work.want_pass);
    if (!kept) {
        work.key_made = false;
        if (!wb.PassphraseKey(@ptrCast(&work.want_pass), name.ptr, @intCast(name.len), &work.key)) {
            say(sys, "the passphrase makes no key: 8 to 63 characters, or 64 hex digits");
            return null;
        }
        @memcpy(work.key_ssid[0..name.len], name);
        work.key_ssid_len = name.len;
        work.key_pass = work.want_pass;
        work.key_made = true;
    }
    return own_length;
}

/// The handshake made, once the association is over, with the station
/// element its request carried - the station's own if it can't be read
/// - and handed the frame held for it. Without memory the join is given
/// up, to be made again.
fn startHandshake(work: *Work) void {
    const base = work.base;
    const sys = base.sys_base;
    var association: [assoc_bytes]u8 = @splat(0);
    const element = sentElement(base, &association) orelse work.own_element[0 .. @as(usize, work.own_element[1]) + 2];
    const tags = [_]TagItem{
        .{ .tag = wpa.WPAH_Key, .data = @intFromPtr(&work.key) },
        .{ .tag = wpa.WPAH_Authenticator, .data = @intFromPtr(&work.target.bssid) },
        .{ .tag = wpa.WPAH_Supplicant, .data = @intFromPtr(&base.station) },
        .{ .tag = wpa.WPAH_StationElement, .data = @intFromPtr(element.ptr) },
        .{ .tag = wpa.WPAH_NetworkElement, .data = @intFromPtr(&work.target.rsn) },
        .{ .tag = wpa.WPAH_Hook, .data = @intFromPtr(&work.hook) },
        .{},
    };
    const handshake = work.wpa_base.?.CreateHandshake(&tags) orelse {
        say(sys, "no memory for the key handshake");
        work.held_len = 0;
        work.leave_due = true;
        return cameOff(work);
    };
    work.handshake = handshake;
    const length = work.held_len;
    work.held_len = 0;
    work.wpa_base.?.HandshakeFrame(handshake, &work.held, @intCast(length));
}

/// The RSN element of the association request the firmware sent, its
/// elements read into `elements`; null if they can't be read or have
/// none.
fn sentElement(base: *CywBase, elements: *[assoc_bytes]u8) ?[]const u8 {
    // "assoc_info" first: how long the request's elements are.
    const info = bcdc.getVar(base, "assoc_info", elements) catch return null;
    if (info != 0) return null;
    const length = @min(std.mem.readInt(u32, elements[0..4], .little), assoc_bytes);
    @memset(elements, 0);
    const status = bcdc.getVar(base, "assoc_req_ies", elements) catch return null;
    if (status != 0) return null;
    var at: usize = 0;
    while (at + 2 <= length) {
        const size = @as(usize, elements[at + 1]) + 2;
        if (at + size > length) return null;
        if (elements[at] == 48) return if (size <= element_max) elements[at..][0..size] else null;
        at += size;
    }
    return null;
}

/// The handshake given up, and what it left undone with it.
fn dropHandshake(work: *Work) void {
    if (work.handshake) |handshake| work.wpa_base.?.DeleteHandshake(handshake);
    work.handshake = null;
    work.held_len = 0;
    work.control_len = 0;
    work.sent_due = false;
    work.authorized_due = false;
    wipe(&work.pairwise_key);
    wipe(&work.group_key);
}

fn wipe(key: *Key) void {
    std.crypto.secureZero(u8, &key.bytes);
    key.* = .{};
}

/// What the handshake asks, from inside HandshakeFrame and HandshakeSent:
/// noted, for the worker's loop to do (`handshakeDue`, `sendWrites`).
fn handshakeHook(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const work: *Work = @ptrCast(@alignCast(hook.data.?));
    const asked: *const wpa.HandshakeMessage = @ptrCast(@alignCast(message orelse return 0));
    switch (asked.kind) {
        wpa.WPAHM_SEND => {
            const frame = (asked.data orelse return 0)[0..asked.length];
            if (frame.len > work.control.len - bcdc_data_header) return 0;
            work.control[0..bcdc_data_header].* = .{ BCDC_DATA_FLAGS, 0, 0, 0 };
            @memcpy(work.control[bcdc_data_header..][0..frame.len], frame);
            work.control_len = bcdc_data_header + frame.len;
            work.control_number = asked.number;
        },
        wpa.WPAHM_PAIRWISEKEY, wpa.WPAHM_GROUPKEY => {
            const key = if (asked.kind == wpa.WPAHM_PAIRWISEKEY) &work.pairwise_key else &work.group_key;
            const length = @min(asked.length, key.bytes.len);
            @memcpy(key.bytes[0..length], (asked.data orelse return 0)[0..length]);
            key.length = @intCast(length);
            key.index = @truncate(asked.index);
            key.algo = if (asked.cipher == wpa.WPA_CIPHER_TKIP) join_file.ALGO_TKIP else join_file.ALGO_AES_CCM;
            key.rsc = asked.rsc;
            key.due = true;
        },
        wpa.WPAHM_AUTHORIZED => work.authorized_due = true,
        wpa.WPAHM_LEAVE => {
            exec.kprintf(work.base.sys_base, "%s: the key handshake gives up: reason %u (is the passphrase right?)\n", .{
                @as([*:0]const u8, DEVICE_NAME),
                asked.reason,
            });
            work.leave_due = true;
            cameOff(work);
        },
        else => {},
    }
    return 0;
}

/// What the handshake left to be done: told its frame has gone, its keys
/// given the firmware, the port opened.
fn handshakeDue(work: *Work) void {
    if (work.held_len != 0 and work.handshake == null and work.state != .idle) startHandshake(work);
    if (work.sent_due) {
        work.sent_due = false;
        if (work.handshake) |handshake| work.wpa_base.?.HandshakeSent(handshake, work.sent_number);
    }
    if (work.pairwise_key.due) install(work, &work.pairwise_key, true);
    if (work.group_key.due) install(work, &work.group_key, false);
    if (work.authorized_due) {
        work.authorized_due = false;
        if (work.state == .idle) return;
        work.keyed = true;
        if (work.state == .joining) joined(work);
    }
}

/// A key the handshake handed over, into the firmware.
fn install(work: *Work, key: *Key, pairwise: bool) void {
    const sys = work.base.sys_base;
    var params = join_file.key(key.bytes[0..key.length], if (pairwise) 0 else key.index, key.algo, &key.rsc, if (pairwise) &work.target.bssid else null);
    wipe(key);
    const status = bcdc.setVar(work.base, "wsec_key", &params) catch |err| {
        std.crypto.secureZero(u8, &params);
        return sayError(sys, "the key cannot be given the firmware", err);
    };
    std.crypto.secureZero(u8, &params);
    if (status != 0) {
        exec.kprintf(sys, "%s: the firmware refuses the %s key: %d\n", .{
            @as([*:0]const u8, DEVICE_NAME),
            @as([*:0]const u8, if (pairwise) "pairwise" else "group"),
            status,
        });
    }
}

/// S2_GETNETWORKINFO: the network joined, as one tag list.
fn networkInfo(work: *Work, req: *net.IOSana2Req) i8 {
    if (work.state != .joined) {
        req.wire_error = net.S2WERR_UNIT_OFFLINE;
        return net.S2ERR_OUTOFSERVICE;
    }
    const sys = work.base.sys_base;
    const target = &work.target;
    const tag_count = 7;
    const memory: [*]u8 = @ptrCast(sys.AllocPooled(req.data, tag_count * @sizeOf(TagItem) + 33 + 6) orelse return net.S2ERR_NO_RESOURCES);
    const tags: [*]TagItem = @ptrCast(@alignCast(memory));
    const name = memory + tag_count * @sizeOf(TagItem);
    @memcpy(name[0..target.ssid_len], target.name());
    name[target.ssid_len] = 0;
    const address = name + 33;
    @memcpy(address[0..6], &target.bssid);
    tags[0] = .{ .tag = wireless.S2INFO_SSID, .data = @intFromPtr(name) };
    tags[1] = .{ .tag = wireless.S2INFO_BSSID, .data = @intFromPtr(address) };
    tags[2] = .{ .tag = wireless.S2INFO_Channel, .data = target.channel };
    tags[3] = .{ .tag = wireless.S2INFO_Signal, .data = @bitCast(@as(isize, target.rssi)) };
    tags[4] = .{ .tag = wireless.S2INFO_AuthMode, .data = target.authMode() };
    tags[5] = .{ .tag = wireless.S2INFO_Encryption, .data = target.encryption() };
    tags[6] = .{};
    req.stat_data = @ptrCast(tags);
    return 0;
}

/// S2_GETSIGNALQUALITY: the access point's signal as the firmware hears
/// it now.
fn signalQuality(work: *Work, req: *net.IOSana2Req) i8 {
    const quality: *wireless.Sana2SignalQuality = @ptrCast(@alignCast(req.stat_data orelse return net.S2ERR_BAD_ARGUMENT));
    if (work.state != .joined) {
        req.wire_error = net.S2WERR_UNIT_OFFLINE;
        return net.S2ERR_OUTOFSERVICE;
    }
    var params = join_file.scb(0, &work.target.bssid);
    const status = bcdc.command(work.base, join_file.C_GET_RSSI, false, &params) catch return net.S2ERR_SOFTWARE;
    if (status == 0) {
        const rssi = std.mem.readInt(i32, params[0..4], .little);
        work.target.rssi = @intCast(std.math.clamp(rssi, -128, 127));
    }
    quality.* = .{ .signal_level = work.target.rssi, .noise_level = -95 };
    return 0;
}

// --- scanning -------------------------------------------------------------

fn startScan(work: *Work) void {
    const base = work.base;
    work.scan_due = false;
    work.heard = .{};
    work.scan_id +%= 1;
    var params = scan.request(work.scan_id);
    const status = bcdc.setVar(base, "escan", &params) catch |err| {
        sayError(base.sys_base, "the scan cannot be started", err);
        return answerScans(work, net.S2ERR_SOFTWARE);
    };
    if (status != 0) {
        exec.kprintf(base.sys_base, "%s: the firmware refuses the scan: %d\n", .{ @as([*:0]const u8, DEVICE_NAME), status });
        return answerScans(work, net.S2ERR_SOFTWARE);
    }
    work.scanning = true;
    work.scan_started = elapsed();
}

fn endScan(work: *Work) void {
    work.scanning = false;
    answerScans(work, 0);
}

/// Every S2_GETNETWORKS waiting answered: from the last scan, or with
/// `err`.
fn answerScans(work: *Work, err: i8) void {
    const sys = work.base.sys_base;
    while (sys.RemHead(&work.scans)) |node| {
        const message: *exec.Message = @alignCast(@fieldParentPtr("node", node));
        const req = _cyw.sanaReq(_cyw.requestOf(message));
        if (err == 0) answerNetworks(work, req) else req.req.err = err;
        sys.ReplyMsg(message);
    }
}

fn sameName(name: []const u8, wanted: ?[*:0]const u8) bool {
    const text = wanted orelse return true;
    for (name, 0..) |char, i| if (text[i] != char) return false;
    return text[name.len] == 0;
}

/// Tags per network: name, access point, channel, signal, how it is
/// joined, its cipher, the end.
const tags_per_network = 7;

/// One S2_GETNETWORKS answered: a tag list per network heard (with the
/// name asked for, if one was), in the caller's pool.
fn answerNetworks(work: *Work, req: *net.IOSana2Req) void {
    const sys = work.base.sys_base;
    const pool = req.data;
    const params: ?[*]const TagItem = @ptrCast(@alignCast(req.stat_data));
    const wanted: ?[*:0]const u8 = if (params) |list|
        @ptrFromInt(work.base.utility.?.GetTagData(wireless.S2INFO_SSID, 0, list))
    else
        null;
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
        const tags: [*]TagItem = @ptrCast(@alignCast(sys.AllocPooled(pool, tags_per_network * @sizeOf(TagItem) + 33 + 6) orelse break));
        const ssid: [*]u8 = @as([*]u8, @ptrCast(tags)) + tags_per_network * @sizeOf(TagItem);
        @memcpy(ssid[0..found.ssid_len], found.name());
        ssid[found.ssid_len] = 0;
        const bssid = ssid + 33;
        @memcpy(bssid[0..6], &found.bssid);
        tags[0] = .{ .tag = wireless.S2INFO_SSID, .data = @intFromPtr(ssid) };
        tags[1] = .{ .tag = wireless.S2INFO_BSSID, .data = @intFromPtr(bssid) };
        tags[2] = .{ .tag = wireless.S2INFO_Channel, .data = found.channel };
        tags[3] = .{ .tag = wireless.S2INFO_Signal, .data = @bitCast(@as(isize, found.rssi)) };
        tags[4] = .{ .tag = wireless.S2INFO_AuthMode, .data = found.authMode() };
        tags[5] = .{ .tag = wireless.S2INFO_Encryption, .data = found.encryption() };
        tags[6] = .{};
        lists[made] = tags;
        made += 1;
    }
    req.stat_data = @ptrCast(lists);
    req.data_length = @intCast(made);
}

// --- frames out -----------------------------------------------------------

/// The unit has a write for the link: sent now if the firmware gives
/// credit. The unit asks on the worker, as it takes the request.
pub fn startWrites(base: *CywBase) void {
    const work = workOf(base) orelse return;
    if (base.running != 0) sendWrites(work);
}

/// The handshake's frame, then the unit's writes, sent while the firmware
/// gives credit: each an Ethernet frame behind BCDC's header, on the
/// data channel.
fn sendWrites(work: *Work) void {
    const base = work.base;
    if (work.control_len != 0 and sdpcm.canSend(&base.bus)) {
        const length = work.control_len;
        work.control_len = 0;
        @memcpy(sdpcm.payload(base)[0..length], work.control[0..length]);
        if (sdpcm.send(base, sdpcm.CHANNEL_DATA, length)) {
            work.sent_number = work.control_number;
            work.sent_due = true;
        } else |err| sayError(base.sys_base, "the handshake's frame cannot be sent", err);
    }
    if (work.state != .joined) return;
    while (sdpcm.canSend(&base.bus)) {
        const req = base.net.nextWrite() orelse return;
        const payload = sdpcm.payload(base);
        payload[0..bcdc_data_header].* = .{ BCDC_DATA_FLAGS, 0, 0, 0 };
        const length = base.net.buildFrame(req, payload[bcdc_data_header..]);
        if (length == 0) continue;
        const sent = if (sdpcm.send(base, sdpcm.CHANNEL_DATA, bcdc_data_header + length)) true else |_| false;
        base.net.written(req, sent);
    }
}
