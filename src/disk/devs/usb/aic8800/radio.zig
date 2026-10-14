// SPDX-License-Identifier: MIT
//! The Wi-Fi at work, on the device's worker: the stick's transfers in,
//! frames out, the unit's requests, scans and joins.
//!
//! **One read always out.** While the Wi-Fi runs, a bulk read waits on
//! the stick's endpoint in; each transfer it brings is taken apart into
//! its records (msg.zig) and handed on - a frame to the unit, an
//! indication to the station's state, a line of the firmware's log to the
//! system's - and the next read sent. A request to the firmware waits for
//! its confirmation through the same read (`Radio`, the transport
//! lmac.zig's `Caller` runs over): the worker waits for it, or for the
//! timer, and what comes in meanwhile is handed on as it would be. So a
//! record's handler never sends a request itself: what needs one - keys
//! to install, a join to start - is noted, and done by `due` once the
//! worker is back in its loop.
//!
//! **One transfer out at a time** on the endpoint for frames: the
//! station's own EAPOL frame first, then the unit's writes. An EAPOL
//! frame asks for its status, and the firmware sends one when it has gone
//! over the air; message 4's is what lets the keys be installed.
//!
//! **Joining** (S2_SETOPTIONS) is answered at once and done after: a scan
//! for the network, its strongest access point taken, and the firmware
//! told to connect. The firmware authenticates and associates by itself
//! and says so (`SM_CONNECT_IND`); an open network is then joined, and the
//! unit has its carrier.
//!
//! **A WPA2-Personal network** is joined with wpa.library: the network's
//! key made from the passphrase (and kept for the next join of the same
//! network), the station's RSN element made from the access point's and
//! put into the association request, and a key handshake made before the
//! firmware is told to connect. The access point's EAPOL frames go to the
//! handshake; the frames it answers with go out as the station's own,
//! each asking for its status, and the status is what tells the handshake
//! a frame has gone (`HandshakeSent`). The keys it then hands over through
//! its hook are installed (`MM_KEY_ADD_REQ`) and the port opened
//! (`ME_SET_CONTROL_PORT_REQ`) by `due`: only then has the unit its
//! carrier.
//!
//! **A network asked for stays wanted** until it is left
//! (S2INFO_Disassociate). Coming off it for any reason but its own leave -
//! thrown off, refused, not found, not joined in time - the station tries
//! again after a pause: a second, twice as long each time, up to a
//! minute; joining resets it. The first join after the board restarts is
//! often refused, the access point still holding the station from
//! before. A stick plugged in again joins the network wanted.
//!
//! **Scanning** (S2_GETNETWORKS) runs on the worker: every request that
//! comes while one waits is answered with the same networks.

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const ethernet = net.ethernet;
const wireless = sdk.devices.wireless;
const timer = sdk.devices.timer;
const usbhc = sdk.devices.usbhc;
const wpa = sdk.wpa;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const WPABase = sdk.interface.wpa.WPABase;
const _aic = @import("_aic8800.zig");
const AicBase = _aic.AicBase;
const msg = @import("msg.zig");
const lmac = @import("lmac.zig");
const bringup = @import("bringup.zig");
const scan = @import("scan.zig");
const frames = @import("frames.zig");

const DEVICE_NAME = _aic.DEVICE_NAME;

/// A read in: whole transfers of the firmware's, the largest record it
/// sends (an A-MSDU's frame) and more.
const in_bytes = 8192;
/// A transfer out: the largest Ethernet frame behind the descriptor.
const out_bytes = 1600;
/// How long a request waits for its answer, and a transfer out to go.
const answer_ms = 2000;
const out_timeout_ms = 5000;
/// How long a join may take, from the request to the network joined.
const join_ms = 15_000;
/// The first pause before joining again, and the longest, in seconds.
const pause_first_s = 1;
const pause_most_s = 60;
/// The networks a scan's answer holds at most, and the tags of each.
const tags_per_network = 7;

/// Where the station stands with a network: told the firmware to connect;
/// associated, the key handshake under way; joined, the port open.
const State = enum(u8) { idle, connecting, keying, joined };

/// A key the handshake handed over, waiting to be installed.
const Key = struct {
    bytes: [32]u8 = @splat(0),
    length: u8 = 0,
    index: u8 = 0,
    cipher: u8 = 0,
    due: bool = false,
};

pub const Work = struct {
    base: *AicBase,
    caller: lmac.Caller,
    heard: scan.Heard = .{},
    station: bringup.Station = .{},
    /// The Wi-Fi brought up, and the unit running on it.
    up: bool = false,
    running: bool = false,
    /// The read is out; a transfer is out on the endpoint for frames, and
    /// the write it is (null for the station's own frame).
    reading: bool = false,
    sending: bool = false,
    writing: ?*net.IOSana2Req = null,
    /// The station's own frame waiting to go, with its length.
    control: [frames.out_header_bytes + 256]u8 = @splat(0),
    control_len: usize = 0,
    /// S2_GETNETWORKS waiting for the scan.
    scans: exec.List = .{},
    /// The network asked for, and whether a join is to be made.
    wanted: bool = false,
    join_due: bool = false,
    want_ssid: [scan.ssid_max]u8 = @splat(0),
    want_len: usize = 0,
    want_bssid: ?[6]u8 = null,
    want_pass: [wpa.WPA_PASSPHRASE_MAX + 1]u8 = @splat(0),
    protected: bool = false,
    /// The network's key, and the name and passphrase it was made from.
    key: [wpa.WPA_KEY_BYTES]u8 = @splat(0),
    key_ssid: [scan.ssid_max]u8 = @splat(0),
    key_ssid_len: usize = 0,
    key_pass: [wpa.WPA_PASSPHRASE_MAX + 1]u8 = @splat(0),
    key_made: bool = false,
    /// The station's RSN element, the handshake, and its hook.
    own_element: [wpa.WPA_ELEMENT_MAX]u8 = @splat(0),
    handshake: ?*wpa.Handshake = null,
    hook: utility.Hook = .{},
    /// What the handshake left to be done: a frame of its gone out, keys
    /// to install, the port to open; and whether a frame of its waits
    /// for its status.
    sent_due: bool = false,
    pairwise_key: Key = .{},
    group_key: Key = .{},
    authorized_due: bool = false,
    awaiting_status: bool = false,
    status_index: u8 = 0,
    /// The handshake's numbers of the frame waiting to go, of the one
    /// whose status is waited for, and of the one whose status came.
    control_number: u32 = 0,
    awaiting_number: u32 = 0,
    sent_number: u32 = 0,
    /// The network being joined or joined, its access point's station
    /// number, and when the join gives up.
    state: State = .idle,
    target: scan.Network = .{},
    ap: u8 = 0,
    deadline: u32 = 0,
    /// A leave to be told the firmware: its reason; and whether the one
    /// being told is the station's own.
    leave_due: ?u16 = null,
    leaving: bool = false,
    /// The pause before joining again (or the join's deadline): a timer
    /// request of its own, whose answer comes to the pipes' port.
    pause: timer.TimeRequest = .{},
    pause_open: bool = false,
    pause_out: bool = false,
    pause_s: u32 = pause_first_s,
    /// The frame a record in makes, and the read's transfer.
    frame: [ethernet.frame_max]u8 = @splat(0),
    out: [out_bytes]u8 align(4) = @splat(0),
    in: [in_bytes]u8 align(4) = @splat(0),
};

pub fn workOf(base: *AicBase) *Work {
    return @ptrCast(@alignCast(base.work.?));
}

/// The worker's block, made when the worker starts: null without memory.
pub fn makeWork(base: *AicBase) ?*Work {
    const sys = base.sys_base;
    const memory = sys.AllocVec(@sizeOf(Work), exec.MEMF_CLEAR) orelse return null;
    const work: *Work = @ptrCast(@alignCast(memory));
    work.* = .{ .base = base, .caller = .{ .transport = .{
        .context = work,
        .send = Radio.send,
        .receive = Radio.receive,
        .wait = Radio.wait,
        .say = Radio.line,
    } } };
    work.caller.other = .{ .context = work, .handle = handOn };
    work.hook = .{ .entry = &handshakeHook, .data = work };
    work.scans.init(.message);
    base.work = work;
    return work;
}

/// The pause's timer opened, on the worker; without it the station does
/// not join again by itself.
pub fn openPause(work: *Work) void {
    const base = work.base;
    work.pause = .{};
    work.pause.node.message.reply_port = &base.pipes;
    work.pause.node.message.length = @sizeOf(timer.TimeRequest);
    work.pause_open = base.sys_base.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_VBLANK, &work.pause.node, 0) == 0;
}

/// The worker woken in `seconds`, the pause before it set again.
fn pauseFor(work: *Work, seconds: u32) void {
    if (!work.pause_open) return;
    const sys = work.base.sys_base;
    if (work.pause_out) {
        _ = sys.AbortIO(&work.pause.node);
        _ = sys.WaitIO(&work.pause.node);
    }
    work.pause.node.command = timer.TR_ADDREQUEST;
    work.pause.time = .{ .secs = seconds, .micro = 0 };
    work.pause_out = true;
    sys.SendIO(&work.pause.node);
}

/// Off the network without having left it: joined again after the
/// pause, which doubles.
fn cameOff(work: *Work) void {
    if (!work.wanted) return;
    pauseFor(work, work.pause_s);
    work.pause_s = @min(work.pause_s * 2, pause_most_s);
}

fn say(sys: anytype, comptime text: [:0]const u8) void {
    exec.kprintf(sys, "%s: " ++ text ++ "\n", .{@as([*:0]const u8, DEVICE_NAME)});
}

// --- the transport ---------------------------------------------------------------

/// Requests to the firmware over the stick's pipes, their answers through
/// the read that is always out.
const Radio = struct {
    fn of(context: *anyopaque) *Work {
        return @ptrCast(@alignCast(context));
    }

    fn send(context: *anyopaque, bytes: []const u8) bool {
        const base = of(context).base;
        if (@atomicLoad(u8, &base.leaving, .acquire) != 0) return false;
        const io = &(base.msg_out orelse return false).io;
        io.std.data = @constCast(bytes.ptr);
        io.std.length = bytes.len;
        io.std.actual = 0;
        io.flags = usbhc.UHF_ZERO_PACKET;
        io.nak_timeout = out_timeout_ms;
        return base.sys_base.DoIO(&io.std.req) == 0;
    }

    /// The next transfer in, copied to `into`: null when none came in
    /// time. The read is sent again at once.
    fn receive(context: *anyopaque, into: []u8) ?usize {
        const work = of(context);
        const base = work.base;
        const sys = base.sys_base;
        if (!readOut(work)) return null;
        const read = &base.bulk_in.?.io.std.req;
        const clock = &base.timer_io;
        var timed = false;
        if (base.timer_open != 0) {
            clock.node.command = timer.TR_ADDREQUEST;
            clock.time = .{ .secs = answer_ms / 1000, .micro = (answer_ms % 1000) * 1000 };
            sys.SendIO(&clock.node);
            timed = true;
        }
        while (true) {
            if (sys.CheckIO(read) != null) {
                _ = sys.WaitIO(read);
                work.reading = false;
                if (timed) {
                    _ = sys.AbortIO(&clock.node);
                    _ = sys.WaitIO(&clock.node);
                }
                const got = taken(work);
                const length = @min(got.len, into.len);
                @memcpy(into[0..length], got[0..length]);
                _ = readOut(work);
                return if (length == 0) null else length;
            }
            if (timed and sys.CheckIO(&clock.node) != null) {
                _ = sys.WaitIO(&clock.node);
                return null;
            }
            if (@atomicLoad(u8, &base.leaving, .acquire) != 0) return null;
            _ = sys.Wait(base.work_mask);
        }
    }

    fn wait(context: *anyopaque, ms: u32) void {
        const base = of(context).base;
        base.dos_base.?.Delay(@max(ms / 20, 1));
    }

    /// A line of the chip's log, into the system's.
    fn line(context: *anyopaque, text: []const u8) void {
        const base = of(context).base;
        var buffer: [96:0]u8 = @splat(0);
        var length: usize = 0;
        for (text) |char| {
            if (char == 0 or length == buffer.len) break;
            if (char == '\n' or char == '\r') continue;
            buffer[length] = char;
            length += 1;
        }
        if (length == 0) return;
        exec.kprintf(base.sys_base, "%s: firmware: %s\n", .{ @as([*:0]const u8, DEVICE_NAME), @as([*:0]const u8, &buffer) });
    }
};

/// The read out, if it is not: false when the stick is going.
fn readOut(work: *Work) bool {
    const base = work.base;
    if (work.reading) return true;
    if (@atomicLoad(u8, &base.leaving, .acquire) != 0) return false;
    const io = &(base.bulk_in orelse return false).io;
    io.std.data = &work.in;
    io.std.length = in_bytes;
    io.std.actual = 0;
    io.flags = 0;
    io.nak_timeout = 0;
    work.reading = true;
    base.sys_base.SendIO(&io.std.req);
    return true;
}

/// What the read that came back brought: nothing after an error.
fn taken(work: *Work) []const u8 {
    const io = &work.base.bulk_in.?.io;
    if (io.std.req.err != 0) {
        if (io.std.req.err == usbhc.UHIOERR_STALL) _ = work.base.ub().ClearUSBStall(work.base.bulk_in.?);
        return &.{};
    }
    return work.in[0..@min(io.std.actual, in_bytes)];
}

// --- what comes in ---------------------------------------------------------------

/// A transfer's records handed on, as the read's answer or while a
/// request waits for its own.
fn handOn(context: *anyopaque, record: msg.Record) void {
    const work: *Work = @ptrCast(@alignCast(context));
    switch (record) {
        .frame => |frame| received(work, frame.header, frame.frame),
        .message => |m| indication(work, m.id, m.params),
        .tx_status => if (work.awaiting_status) {
            work.awaiting_status = false;
            work.sent_number = work.awaiting_number;
            work.sent_due = true;
        },
        .log => |text| Radio.line(work, text),
        .other => {},
    }
}

/// A frame the radio received: an EAPOL frame to the handshake, every
/// other packet to the unit.
fn received(work: *Work, header: []const u8, frame: []const u8) void {
    if (work.state == .idle) return;
    var incoming = frames.Incoming.of(header, frame) orelse return;
    while (incoming.next(&work.frame)) |length| {
        const packet = work.frame[0..length];
        if (packet[12] == 0x88 and packet[13] == 0x8E) {
            if (work.handshake) |handshake| {
                const eapol = packet[frames.ether_header_bytes..];
                work.base.wpa_base.?.HandshakeFrame(handshake, eapol.ptr, @intCast(eapol.len));
            }
            continue;
        }
        if (work.running and work.state == .joined) work.base.net.receive(packet);
    }
}

/// What the handshake asks, from inside HandshakeFrame and HandshakeSent:
/// a frame sent at once, everything else noted for `due`.
fn handshakeHook(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const work: *Work = @ptrCast(@alignCast(hook.data.?));
    const asked: *const wpa.HandshakeMessage = @ptrCast(@alignCast(message orelse return 0));
    switch (asked.kind) {
        wpa.WPAHM_SEND => {
            const frame = (asked.data orelse return 0)[0..asked.length];
            work.status_index +%= 1;
            const length = frames.outgoing(&work.control, frame, work.station.vif, work.ap, frames.statusWord(work.status_index));
            if (length == 0) return 0;
            work.control_len = length;
            work.control_number = asked.number;
            startWrites(work.base);
        },
        wpa.WPAHM_PAIRWISEKEY, wpa.WPAHM_GROUPKEY => {
            const key = if (asked.kind == wpa.WPAHM_PAIRWISEKEY) &work.pairwise_key else &work.group_key;
            const length = @min(asked.length, key.bytes.len);
            @memcpy(key.bytes[0..length], (asked.data orelse return 0)[0..length]);
            key.length = @intCast(length);
            key.index = @truncate(asked.index);
            key.cipher = if (asked.cipher == wpa.WPA_CIPHER_TKIP) lmac.CIPHER_TKIP else lmac.CIPHER_CCMP;
            key.due = true;
        },
        wpa.WPAHM_AUTHORIZED => work.authorized_due = true,
        wpa.WPAHM_LEAVE => work.leave_due = @truncate(asked.reason),
        else => {},
    }
    return 0;
}

/// An indication from the firmware.
fn indication(work: *Work, id: u16, params: []const u8) void {
    const sys = work.base.sys_base;
    switch (id) {
        lmac.SM_CONNECT_IND => {
            const result = lmac.connected(params) orelse return;
            if (work.state != .connecting) return;
            if (result.status != 0) {
                exec.kprintf(sys, "%s: the access point refused the station: status %u\n", .{
                    @as([*:0]const u8, DEVICE_NAME),
                    @as(u32, result.status),
                });
                work.state = .idle;
                return cameOff(work);
            }
            work.ap = result.ap;
            if (work.protected) {
                // The key handshake comes next, from the access point.
                work.state = .keying;
                say(sys, "associated; the key handshake follows");
                return;
            }
            work.state = .joined;
            work.pause_s = pause_first_s;
            say(sys, "joined the network");
            work.base.net.setCarrier(true);
        },
        lmac.SM_DISCONNECT_IND => {
            // The station's own leave, said during it or after.
            if (work.leaving or work.state == .idle) return;
            const reason = if (params.len >= 2) msg.get16(params, 0) else 0;
            exec.kprintf(sys, "%s: off the network: reason %u\n", .{ @as([*:0]const u8, DEVICE_NAME), @as(u32, reason) });
            work.state = .idle;
            work.base.net.setCarrier(false);
            cameOff(work);
        },
        else => {},
    }
}

// --- frames out ------------------------------------------------------------------

/// The unit runs, or stops: what waits to be written goes or is answered
/// by the unit itself.
pub fn setRunning(base: *AicBase, on: bool) void {
    const work = workOf(base);
    work.running = on;
    if (on) startWrites(base);
}

/// The next transfer out, if none is: the station's own frame, then the
/// unit's next write.
pub fn startWrites(base: *AicBase) void {
    const work = workOf(base);
    if (work.sending or !work.up) return;
    if (@atomicLoad(u8, &base.leaving, .acquire) != 0) return;
    if (work.control_len != 0) {
        const length = work.control_len;
        work.control_len = 0;
        work.awaiting_status = true;
        work.awaiting_number = work.control_number;
        return sendOut(work, work.control[0..length], null);
    }
    if (!work.running or work.state != .joined) return;
    while (base.net.nextWrite()) |req| {
        const length = base.net.buildFrame(req, &work.frame);
        if (length == 0) continue;
        const total = frames.outgoing(&work.out, work.frame[0..length], work.station.vif, work.ap, 0);
        if (total == 0) {
            base.net.written(req, false);
            continue;
        }
        return sendOut(work, work.out[0..total], req);
    }
}

fn sendOut(work: *Work, bytes: []const u8, req: ?*net.IOSana2Req) void {
    const base = work.base;
    const io = &base.bulk_out.?.io;
    io.std.data = @constCast(bytes.ptr);
    io.std.length = bytes.len;
    io.std.actual = 0;
    io.flags = usbhc.UHF_ZERO_PACKET;
    io.nak_timeout = 0;
    work.sending = true;
    work.writing = req;
    base.sys_base.SendIO(&io.std.req);
}

// --- the worker's loop -------------------------------------------------------------

/// A message on the pipes' port: the read's answer, a transfer out
/// done, the timer. False if it is none of these.
pub fn replied(work: *Work, message: *exec.Message) bool {
    const base = work.base;
    if (base.bulk_in) |pipe| if (message == &pipe.io.std.req.message) {
        work.reading = false;
        var reader = msg.Reader{ .bytes = taken(work) };
        while (reader.next()) |record| handOn(work, record);
        if (work.up) _ = readOut(work);
        return true;
    };
    if (message == &work.pause.node.message) {
        work.pause_out = false;
        if (work.wanted and work.state == .idle) work.join_due = true;
        return true;
    }
    if (base.bulk_out) |pipe| if (message == &pipe.io.std.req.message) {
        const ok = pipe.io.std.req.err == 0;
        if (pipe.io.std.req.err == usbhc.UHIOERR_STALL) _ = base.ub().ClearUSBStall(pipe);
        work.sending = false;
        if (work.writing) |req| {
            work.writing = null;
            base.net.written(req, ok);
        }
        startWrites(base);
        return true;
    };
    return false;
}

/// The Wi-Fi brought up after the firmware started: the station
/// interface added, the read sent, the unit given its address.
pub fn start(work: *Work) void {
    const base = work.base;
    const sys = base.sys_base;
    var address: [6]u8 = @splat(0);
    work.station = .{};
    bringup.bringUp(&work.caller, &work.station, &address) catch {
        say(sys, "the Wi-Fi firmware does not answer");
        return;
    };
    exec.kprintf(sys, "%s: firmware %s, %s, address %x:%x:%x:%x:%x:%x\n", .{
        @as([*:0]const u8, DEVICE_NAME),
        @as([*:0]const u8, &work.station.version),
        @as([*:0]const u8, if (work.station.has_5g) "2.4 and 5 GHz" else "2.4 GHz"),
        @as(u32, address[0]),
        @as(u32, address[1]),
        @as(u32, address[2]),
        @as(u32, address[3]),
        @as(u32, address[4]),
        @as(u32, address[5]),
    });
    const net_unit = &base.net;
    const own = sameAddress(&net_unit.station, &net_unit.factory);
    net_unit.factory = address;
    if (own) net_unit.station = address;
    work.up = true;
    work.state = .idle;
    _ = readOut(work);
    // The unit's interface, the first time the Wi-Fi comes up.
    if (base.asked == 0) if (base.adder) |port| {
        base.asked = 1;
        base.tell = .{ .length = @sizeOf(exec.Message) };
        sys.PutMsg(port, &base.tell);
    };
    // A join asked for before the stick came is made now.
    if (work.wanted) work.join_due = true;
}

/// The stick gone: its transfers taken back, the unit off line, every
/// scan waiting answered.
pub fn stop(work: *Work) void {
    const base = work.base;
    const sys = base.sys_base;
    if (work.reading) {
        _ = sys.AbortIO(&base.bulk_in.?.io.std.req);
        _ = sys.WaitIO(&base.bulk_in.?.io.std.req);
        work.reading = false;
    }
    if (work.sending) {
        _ = sys.AbortIO(&base.bulk_out.?.io.std.req);
        _ = sys.WaitIO(&base.bulk_out.?.io.std.req);
        work.sending = false;
        if (work.writing) |req| {
            work.writing = null;
            base.net.written(req, false);
        }
    }
    work.up = false;
    work.control_len = 0;
    dropHandshake(work);
    if (work.state != .idle) {
        work.state = .idle;
        base.net.setCarrier(false);
    }
    answerScans(work);
    // The stick that comes back joins what was wanted.
    if (work.wanted) work.join_due = true;
}

/// What a record's handler or a request left to be done, done: a scan, a
/// join, a leave. True if anything was.
pub fn due(work: *Work) bool {
    if (!work.up) return false;
    if (@atomicLoad(u8, &work.base.leaving, .acquire) != 0) return false;
    if (work.leave_due) |reason| {
        work.leave_due = null;
        leave(work, reason);
        return true;
    }
    if (work.sent_due) {
        work.sent_due = false;
        if (work.handshake) |handshake| work.base.wpa_base.?.HandshakeSent(handshake, work.sent_number);
        return true;
    }
    if (work.pairwise_key.due) {
        install(work, &work.pairwise_key, true);
        return true;
    }
    if (work.group_key.due) {
        install(work, &work.group_key, false);
        return true;
    }
    if (work.authorized_due) {
        work.authorized_due = false;
        openPort(work);
        return true;
    }
    if (!work.scans.isEmpty()) {
        runScan(work);
        answerScans(work);
        return true;
    }
    if (work.join_due) {
        work.join_due = false;
        join(work);
        return true;
    }
    if ((work.state == .connecting or work.state == .keying) and elapsed(work.base) > work.deadline) {
        say(work.base.sys_base, "the network was not joined in time");
        leave(work, 1);
        cameOff(work);
        return true;
    }
    return false;
}

/// Milliseconds since the system started, from the timer.
fn elapsed(base: *AicBase) u32 {
    const time = base.now();
    return @truncate(time.secs * 1000 + time.micro / 1000);
}

// --- the unit's wireless requests ------------------------------------------------

/// A request on the unit's port: a wireless one here, every other the
/// unit's.
pub fn request(work: *Work, req: *net.IOSana2Req) void {
    const base = work.base;
    const sys = base.sys_base;
    switch (req.req.command) {
        wireless.S2_GETNETWORKS => {
            if (!work.up) {
                req.req.err = net.S2ERR_OUTOFSERVICE;
                req.wire_error = net.S2WERR_UNIT_OFFLINE;
                return sys.ReplyMsg(&req.req.message);
            }
            sys.AddTail(&work.scans, &req.req.message.node);
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
            const quality: ?*wireless.Sana2SignalQuality = @ptrCast(@alignCast(req.stat_data));
            if (quality == null) {
                req.req.err = net.S2ERR_BAD_ARGUMENT;
            } else if (work.state != .joined) {
                req.req.err = net.S2ERR_OUTOFSERVICE;
                req.wire_error = net.S2WERR_UNIT_OFFLINE;
            } else {
                quality.?.* = .{ .signal_level = work.target.rssi, .noise_level = -95 };
            }
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

/// A scan, its networks in `heard`.
fn runScan(work: *Work) void {
    work.heard = .{};
    scan.run(&work.caller, work.station.vif, work.station.has_5g, &work.heard) catch {
        say(work.base.sys_base, "the scan did not finish");
    };
}

/// Every S2_GETNETWORKS waiting, answered from the last scan.
fn answerScans(work: *Work) void {
    const sys = work.base.sys_base;
    while (sys.RemHead(&work.scans)) |node| {
        const message: *exec.Message = @alignCast(@fieldParentPtr("node", node));
        const req = _aic.sanaReq(_aic.requestOf(message));
        if (work.up) {
            answerNetworks(work, req);
        } else {
            req.req.err = net.S2ERR_OUTOFSERVICE;
            req.wire_error = net.S2WERR_UNIT_OFFLINE;
        }
        sys.ReplyMsg(message);
    }
}

fn sameName(name: []const u8, wanted: ?[*:0]const u8) bool {
    const text = wanted orelse return true;
    for (name, 0..) |char, i| if (text[i] != char) return false;
    return text[name.len] == 0;
}

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
        if (work.state != .idle) work.leave_due = 3;
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
    work.want_ssid = wanted;
    work.want_len = length;
    work.want_pass = passphrase;
    const bssid: ?[*]const u8 = @ptrFromInt(ub.GetTagData(wireless.S2INFO_BSSID, 0, list));
    work.want_bssid = if (bssid) |address| address[0..6].* else null;
    work.wanted = true;
    work.join_due = true;
    work.pause_s = pause_first_s;
    if (work.state != .idle) work.leave_due = 3;
    return 0;
}

/// The network asked for joined: found by a scan, its strongest access
/// point (or the one asked for) told the firmware to connect to.
fn join(work: *Work) void {
    const sys = work.base.sys_base;
    const name = work.want_ssid[0..work.want_len];
    runScan(work);
    const found = blk: {
        if (work.want_bssid) |bssid| {
            for (work.heard.list()) |*each| {
                if (sameAddress(&each.bssid, &bssid)) break :blk each;
            }
            break :blk null;
        }
        break :blk work.heard.strongest(name);
    } orelse {
        say(sys, "the network asked for was not found");
        return cameOff(work);
    };
    work.target = found.*;
    dropHandshake(work);
    var own_length: usize = 0;
    work.protected = found.rsn_len != 0 or found.privacy;
    if (work.protected) {
        own_length = prepareKeys(work, found) orelse return;
    }
    const request_params = lmac.connectRequest(.{
        .ssid = name,
        .bssid = found.bssid,
        .freq = found.freq,
        .band = if (found.freq >= 5000) lmac.BAND_5G else lmac.BAND_2G4,
        .vif = work.station.vif,
        .protected = work.protected,
        .elements = work.own_element[0..own_length],
    });
    var status: [4]u8 = @splat(0xFF);
    _ = work.caller.call(lmac.SM_CONNECT_REQ, &request_params, lmac.SM_CONNECT_CFM, &status) catch {
        say(sys, "the firmware does not take the join");
        return cameOff(work);
    };
    if (status[0] != 0) {
        exec.kprintf(sys, "%s: the firmware refuses the join: %u\n", .{ @as([*:0]const u8, DEVICE_NAME), @as(u32, status[0]) });
        return cameOff(work);
    }
    work.state = .connecting;
    work.deadline = elapsed(work.base) + join_ms;
    // Woken at the deadline, to see that it was kept.
    pauseFor(work, join_ms / 1000 + 1);
}

/// The network left: the firmware told, the unit without a carrier.
fn leave(work: *Work, reason: u16) void {
    var answer: [4]u8 = undefined;
    work.leaving = true;
    _ = work.caller.call(lmac.SM_DISCONNECT_REQ, &lmac.disconnectRequest(reason, work.station.vif), lmac.SM_DISCONNECT_CFM, &answer) catch {};
    work.leaving = false;
    dropHandshake(work);
    if (work.state != .idle) {
        work.state = .idle;
        work.base.net.setCarrier(false);
    }
}

/// A protected network's side made ready: wpa.library opened, the
/// station's element made from the access point's, the network's key
/// made (or the one kept), and the handshake made. The station element's
/// length; null, said in the log, when the network can't be joined.
fn prepareKeys(work: *Work, found: *const scan.Network) ?usize {
    const base = work.base;
    const sys = base.sys_base;
    if (base.wpa_base == null) {
        base.wpa_base = @ptrCast(sys.OpenLibrary(wpa.WPANAME, 1) orelse {
            say(sys, "a protected network needs LIBS:wpa.library");
            return null;
        });
    }
    const wb = base.wpa_base.?;
    if (found.rsn_len == 0) {
        say(sys, "the network is WEP or WPA: only WPA2 is joined");
        return null;
    }
    const own_length = wb.StationElement(&found.rsn, &work.own_element, work.own_element.len);
    if (own_length == 0) {
        say(sys, "the network asks for a security this station can't do (WPA2-Personal with CCMP is)");
        return null;
    }
    const passphrase: [*:0]const u8 = @ptrCast(&work.want_pass);
    if (work.want_pass[0] == 0) {
        say(sys, "the network is protected, and no passphrase was given");
        return null;
    }
    const name = found.name();
    const kept = work.key_made and work.key_ssid_len == name.len and
        sameBytes(work.key_ssid[0..name.len], name) and sameBytes(&work.key_pass, &work.want_pass);
    if (!kept) {
        work.key_made = false;
        if (!wb.PassphraseKey(passphrase, name.ptr, @intCast(name.len), &work.key)) {
            say(sys, "the passphrase makes no key: 8 to 63 characters, or 64 hex digits");
            return null;
        }
        @memcpy(work.key_ssid[0..name.len], name);
        work.key_ssid_len = name.len;
        work.key_pass = work.want_pass;
        work.key_made = true;
    }
    const station_address = &base.net.factory;
    const tags = [_]TagItem{
        .{ .tag = wpa.WPAH_Key, .data = @intFromPtr(&work.key) },
        .{ .tag = wpa.WPAH_Authenticator, .data = @intFromPtr(&found.bssid) },
        .{ .tag = wpa.WPAH_Supplicant, .data = @intFromPtr(station_address) },
        .{ .tag = wpa.WPAH_StationElement, .data = @intFromPtr(&work.own_element) },
        .{ .tag = wpa.WPAH_NetworkElement, .data = @intFromPtr(&found.rsn) },
        .{ .tag = wpa.WPAH_Hook, .data = @intFromPtr(&work.hook) },
        .{},
    };
    work.handshake = wb.CreateHandshake(&tags) orelse {
        say(sys, "no memory for the key handshake");
        return null;
    };
    return own_length;
}

/// The handshake given up, and what it left undone with it.
fn dropHandshake(work: *Work) void {
    if (work.handshake) |handshake| work.base.wpa_base.?.DeleteHandshake(handshake);
    work.handshake = null;
    work.sent_due = false;
    work.authorized_due = false;
    work.awaiting_status = false;
    wipe(&work.pairwise_key);
    wipe(&work.group_key);
}

fn wipe(key: *Key) void {
    const bytes: [*]volatile u8 = @ptrCast(&key.bytes);
    @memset(bytes[0..key.bytes.len], 0);
    key.* = .{};
}

/// A key the handshake handed over, into the firmware.
fn install(work: *Work, key: *Key, pairwise: bool) void {
    const sys = work.base.sys_base;
    const params = lmac.keyRequest(key.bytes[0..key.length], if (pairwise) 0 else key.index, if (pairwise) work.ap else lmac.STA_NONE, key.cipher, work.station.vif, pairwise);
    wipe(key);
    var answer: [2]u8 = @splat(0xFF);
    _ = work.caller.call(lmac.MM_KEY_ADD_REQ, &params, lmac.MM_KEY_ADD_CFM, &answer) catch {
        say(sys, "the firmware does not take the key");
        return;
    };
    if (answer[0] != 0) {
        exec.kprintf(sys, "%s: the firmware refuses the %s key: %u\n", .{
            @as([*:0]const u8, DEVICE_NAME),
            @as([*:0]const u8, if (pairwise) "pairwise" else "group"),
            @as(u32, answer[0]),
        });
    }
}

/// The keys are in: the port opened for the station's traffic, and the
/// network joined.
fn openPort(work: *Work) void {
    const sys = work.base.sys_base;
    var answer: [4]u8 = undefined;
    _ = work.caller.call(lmac.ME_SET_CONTROL_PORT_REQ, &.{ work.ap, 1 }, lmac.ME_SET_CONTROL_PORT_CFM, &answer) catch {
        say(sys, "the firmware does not open the port");
        return;
    };
    if (work.state != .keying) return;
    work.state = .joined;
    work.pause_s = pause_first_s;
    say(sys, "joined the network; the keys are in");
    work.base.net.setCarrier(true);
}

fn sameBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// S2_GETNETWORKINFO: the network joined, as one tag list.
fn networkInfo(work: *Work, req: *net.IOSana2Req) i8 {
    if (work.state != .joined) {
        req.wire_error = net.S2WERR_UNIT_OFFLINE;
        return net.S2ERR_OUTOFSERVICE;
    }
    const sys = work.base.sys_base;
    const target = &work.target;
    const tag_count = 6;
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
    tags[5] = .{};
    req.stat_data = @ptrCast(tags);
    return 0;
}

fn sameAddress(a: *const [6]u8, b: *const [6]u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
