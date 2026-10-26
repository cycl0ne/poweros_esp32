// SPDX-License-Identifier: MIT
//! smb-handler: a share on an SMB 2/3 server - Windows, Samba, a NAS -
//! as a DOS device, its files listed, read and written as a disk's. It is
//! `HANDLERS:smb-handler`, which dos loads the first time the device is
//! used; C:net/MountShare makes the device and starts it.
//!
//! **The startup** is the device node's `SmbStartup`
//! (`sdk.dos.smb`): the server, the port, the share, who logs on and the
//! password's NT hash, the volume's name and the mount's flags. At
//! ACTION_STARTUP the handler connects, negotiates, logs on and connects
//! to the share before it answers, and writes what it came to into the
//! startup's `result` - the stage it stopped at and the server's status
//! there, or the dialect, the signing and the cipher it got - so the
//! tool that started it can say what happened. A start that fails ends
//! the process; the next use of the device starts it again.
//!
//! **One process, one connection, one request at a time**: packets wait
//! on the port while the handler waits for the server. `fs.zig` turns
//! each packet into the requests it takes; `session.zig` and what it is
//! built on speak SMB. Only a READ sent ahead and a WRITE's last piece
//! (`fs.zig` says when) are not waited for: their answers are read
//! between packets as they come - a READ's into two buffers of the
//! process's - told by the socket's event signal.
//!
//! **The volume** is named after the share, or as the startup says,
//! dated at the logon, with the DosType `SMB\0`; it is write-protected
//! when the startup says so (SMBF_READONLY) or the share's MaximalAccess
//! does not let the user write. INFO and DISK_INFO answer from the
//! share's size as last asked, so Info, which holds the device list while
//! it asks, never waits on the network; once the share is written to, the
//! size is asked again between packets, no more often than every few
//! seconds.
//!
//! **Record locks and watches** are kept by the process: their timers
//! and the watchers' replies come back on ports of their own, which it
//! waits on beside its packets. A record lock that waits keeps its packet
//! unanswered until it is granted or its time runs out.
//!
//! **Staying connected.** A connection that is lost is made again when
//! it is next needed (`fs.zig` says how), through `reconnect`: the
//! connection, the negotiation, the logon and the tree as at the start.
//! A try that fails is not made again for `retry_seconds`, on the
//! E-clock, so while the server is gone each packet that needs it is
//! answered at once. The idle timer runs out every `idle_seconds`; when
//! no packet came since it last did and anything is locked or open, an
//! ECHO goes, so a connection that died is found and made again before a
//! program next asks.
//!
//! **Dismounting** (ACTION_DIE) is refused while anything is locked,
//! open or watched on the volume. Otherwise the handler disconnects from the share,
//! logs off, takes its volume off the device list and ends; the device
//! node is the tool's to remove.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const smb = dos.smb;
const crypto = sdk.crypto;
const bsd = sdk.bsdsocket;
const battmem = sdk.resources.battmem;
const battmembits = sdk.resources.battmembits;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const CryptoBase = sdk.interface.crypto.CryptoBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const DosPacket = dos.DosPacket;
const Process = dos.Process;
const timer = sdk.devices.timer;
const record = dos.record;
const notify = dos.notify;
const TimerBase = sdk.interface.timer.TimerBase;
const TagItem = sdk.utility.TagItem;
const connection_area = @import("connection.zig");
const session_area = @import("session.zig");
const negotiate_area = @import("negotiate.zig");
const logon_area = @import("logon.zig");
const ntlm = @import("ntlm.zig");
const names = @import("names.zig");
const fs_area = @import("fs.zig");
const commands = @import("commands.zig");
const Session = session_area.Session;
const FileSystem = fs_area.FileSystem;

pub const HANDLER_NAME = smb.SMB_HANDLER;
const HANDLER_VERSION = 1;
const HANDLER_REVISION = 8;
const BUILD_DATE = "26.10.2026";
const HANDLER_VERSION_STRING =
    "\x00$VER: " ++ HANDLER_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ HANDLER_VERSION, HANDLER_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// crypto.library 2.2, the first with InitGmac, UpdateGmac and FinishGmac,
/// which check a READ's signature as its data comes; HmacPieces, which
/// signs, came in 2.0, MD4 and MD5, which NTLM takes, in 1.4.
const CRYPTO_VERSION = 2;
const CRYPTO_REVISION = 2;

/// How often, and how long apart, the device list is tried for when the
/// volume node comes off it at a dismount.
const list_tries = 100;
const list_try_ticks = 2;

/// How often the idle timer runs out, and how long after a reconnection
/// that failed the next may be tried.
const idle_seconds = 60;
const retry_seconds = 5;

/// Everything the process keeps, in one allocation.
const State = struct {
    sys: *ExecBase,
    dl: *DosBase,
    cb: *CryptoBase,
    sb: *SocketBase,
    startup: *smb.SmbStartup,
    node: ?*dos.DosList,
    session: Session,
    fs: FileSystem,
    volume: ?*dos.DosList = null,
    /// The volume's name, NUL-terminated.
    volume_name: [dos.name_max + 1]u8 = @splat(0),
    /// The idle timer: its request on timer.device's UNIT_VBLANK and the
    /// port it comes back to, null without the device.
    clock: timer.TimeRequest = .{},
    clock_port: ?*exec.MsgPort = null,
    clock_running: bool = false,
    /// A packet came since the idle timer last ran out.
    busy: bool = false,
    /// When a reconnection may be tried again, in seconds on the E-clock.
    retry_after: u64 = 0,
    /// The volume's record locks and watchers.
    records: record.Records = undefined,
    watchers: notify.Watchers = undefined,
};

/// The handler process: ACTION_STARTUP - the connection, the logon and
/// the share - then packets until ACTION_DIE.
pub fn fsHandler(sys: *ExecBase) callconv(.c) void {
    const library = sys.OpenLibrary(dos.DOSNAME, 0) orelse return;
    const dl: *DosBase = @ptrCast(library);
    defer sys.CloseLibrary(library);
    const startup_packet = dl.WaitPkt() orelse return;
    if (startup_packet.getAction() != .startup) {
        dl.ReplyPkt(startup_packet, dos.DOSFALSE, dos.ERROR_ACTION_NOT_KNOWN);
        return;
    }
    const me: *Process = @fieldParentPtr("task", sys.FindTask(null).?);
    const node: ?*dos.DosList = @ptrFromInt(@as(usize, @bitCast(startup_packet.args.raw[2])));
    const startup = smb.SmbStartup.of(@bitCast(startup_packet.args.raw[1])) orelse
        return dl.ReplyPkt(startup_packet, dos.DOSFALSE, dos.ERROR_DEVICE_NOT_MOUNTED);
    startup.result = .{};

    const crypto_lib = sys.OpenLibrary(crypto.CRYPTONAME, CRYPTO_VERSION) orelse
        return refuse(dl, startup_packet, startup, smb.SMBSTAGE_NETWORK);
    defer sys.CloseLibrary(crypto_lib);
    if (crypto_lib.version == CRYPTO_VERSION and crypto_lib.revision < CRYPTO_REVISION)
        return refuse(dl, startup_packet, startup, smb.SMBSTAGE_NETWORK);
    const socket_lib = sys.OpenLibrary(bsd.SOCKETNAME, 0) orelse
        return refuse(dl, startup_packet, startup, smb.SMBSTAGE_NETWORK);
    defer sys.CloseLibrary(socket_lib);

    const send_buffer = sys.AllocVec(session_area.send_size, exec.MEMF_ANY) orelse
        return refuse(dl, startup_packet, startup, smb.SMBSTAGE_MEMORY);
    defer sys.FreeVec(send_buffer);
    const receive_buffer = sys.AllocVec(session_area.receive_size, exec.MEMF_ANY) orelse
        return refuse(dl, startup_packet, startup, smb.SMBSTAGE_MEMORY);
    defer sys.FreeVec(receive_buffer);
    const block = sys.AllocVec(@sizeOf(State), exec.MEMF_CLEAR) orelse
        return refuse(dl, startup_packet, startup, smb.SMBSTAGE_MEMORY);
    defer sys.FreeVec(block);
    // Reading ahead, when there is the memory for it, and a signal that
    // says when its answer comes.
    const ahead_block = sys.AllocVec(2 * session_area.receive_size, exec.MEMF_ANY);
    defer if (ahead_block) |ahead| sys.FreeVec(ahead);
    const event_signal = sys.AllocSignal(-1);
    defer if (event_signal >= 0) sys.FreeSignal(event_signal);

    const st: *State = @ptrCast(@alignCast(block));
    const cb: *CryptoBase = @ptrCast(crypto_lib);
    const sb: *SocketBase = @ptrCast(socket_lib);
    st.* = .{
        .sys = sys,
        .dl = dl,
        .cb = cb,
        .sb = sb,
        .startup = startup,
        .node = node,
        .session = .{
            .cb = cb,
            .connection = .{ .sb = sb },
            .send_buffer = @as([*]u8, @ptrCast(send_buffer))[0..session_area.send_size],
            .receive_buffer = @as([*]u8, @ptrCast(receive_buffer))[0..session_area.receive_size],
        },
        .fs = undefined,
    };
    st.fs = .{
        .sys = sys,
        .dl = dl,
        .session = &st.session,
        .port = &me.msg_port,
        .zone = timeZone(sys),
        .reconnect = &reconnect,
        .now = &clockSeconds,
    };
    if (node) |device| st.fs.device_name = cString(std.mem.span(device.name));
    cb.RandomBytes(&st.session.client_guid, 16);
    const event_mask: u32 = if (event_signal >= 0) @as(u32, 1) << @intCast(event_signal) else 0;
    if (ahead_block != null and event_mask != 0) {
        const tags = [_]TagItem{ .{ .tag = bsd.SBTM_SETVAL(bsd.SBTC_SIGEVENTMASK), .data = event_mask }, .{} };
        if (sb.SocketBaseTagList(&tags) == 0) {
            const bytes: [*]u8 = @ptrCast(ahead_block.?);
            st.fs.ahead_buffers = .{ bytes[0..session_area.receive_size], bytes[session_area.receive_size..][0..session_area.receive_size] };
        }
    }

    // The share's size, for Info; a server that will not say is shown
    // with none.
    const connected = connect(st);
    if (connected) st.fs.askSpace() catch {};
    if (!connected or st.fs.lost) {
        st.session.connection.close();
        return dl.ReplyPkt(startup_packet, dos.DOSFALSE, dos.ERROR_DEVICE_NOT_MOUNTED);
    }
    st.fs.read_only = readOnly(st);
    addVolume(st);
    openClock(st);
    if (st.records.init(sys, dl)) st.fs.records = &st.records;
    if (st.watchers.init(sys)) st.fs.watchers = &st.watchers;
    if (node) |device| device.task = &me.msg_port;
    dl.ReplyPkt(startup_packet, dos.DOSTRUE, 0);

    // Packets on the process's port; the idle timer, the record locks'
    // timers and the watchers' replies on their own; while a READ ahead
    // is coming, its answer on the socket's event signal.
    const packets = &me.msg_port;
    const clock_mask: u32 = if (st.clock_port) |port| port.sigMask() else 0;
    const mask = packets.sigMask() | clock_mask | st.records.signals() | st.watchers.signals() | event_mask;
    startClock(st);
    while (true) {
        if (st.clock_port) |port| {
            if (sys.GetMsg(port) != null) {
                st.clock_running = false;
                if (!st.busy) st.fs.idle();
                st.busy = false;
                startClock(st);
            }
        }
        st.records.collect();
        st.watchers.collect();
        while (sys.GetMsg(packets)) |message| {
            const pkt = DosPacket.fromMessage(message);
            st.busy = true;
            if (pkt.getAction() == .die) {
                if (st.fs.inUse()) {
                    dl.ReplyPkt(pkt, dos.DOSFALSE, dos.ERROR_OBJECT_IN_USE);
                    continue;
                }
                closeClock(st);
                st.fs.releaseAll();
                st.records.deinit();
                st.watchers.deinit();
                if (!st.fs.lost) logon_area.logoff(&st.session);
                st.session.connection.close();
                if (node) |device| device.task = null;
                removeVolume(st, &me.msg_port);
                dl.ReplyPkt(pkt, dos.DOSTRUE, 0);
                return;
            }
            const reply = st.fs.answer(pkt);
            if (!reply.held) dl.ReplyPkt(pkt, reply.res1, reply.res2);
        }
        st.fs.refresh();
        st.fs.pump();
        if (sys.Wait(if (st.fs.reading()) mask else mask & ~event_mask) & event_mask != 0) {
            var events: u32 = 0;
            while (sb.GetSocketEvents(&events) >= 0) {}
            st.fs.pump();
        }
    }
}

/// A start refused before there is anything to connect with: the stage
/// in the startup's result, and the packet answered.
fn refuse(dl: *DosBase, pkt: *DosPacket, startup: *smb.SmbStartup, stage: u32) void {
    startup.result.stage = stage;
    dl.ReplyPkt(pkt, dos.DOSFALSE, if (stage == smb.SMBSTAGE_MEMORY) dos.ERROR_NO_FREE_STORE else dos.ERROR_DEVICE_NOT_MOUNTED);
}

/// The connection, the negotiation, the logon and the share, each
/// stage's outcome written into the startup's result: true when the
/// share is there to be used.
fn connect(st: *State) bool {
    const startup = st.startup;
    const result = &startup.result;
    const session = &st.session;
    const cb = st.cb;
    const server = cString(&startup.server);
    const port: u16 = if (startup.port == 0) smb.SMB_PORT else startup.port;

    var failure: connection_area.Failure = .{};
    if (!session.connection.open(@ptrCast(&startup.server), port, &failure)) {
        result.stage = failure.stage;
        result.@"error" = failure.code;
        return false;
    }

    var salt: [32]u8 = undefined;
    cb.RandomBytes(&salt, salt.len);
    const negotiated = negotiate_area.negotiate(session, &salt) catch |err| return failed(result, smb.SMBSTAGE_NEGOTIATE, err);
    if (negotiated != smb.STATUS_SUCCESS) {
        result.stage = smb.SMBSTAGE_NEGOTIATE;
        result.status = negotiated;
        return false;
    }
    result.dialect = session.dialect;

    // Who logs on: the user in capitals as NTLMv2 hashes it, and this
    // machine's name for the server's logs.
    const user = cString(&startup.user);
    var user_upper: [smb.SMB_USER_MAX + 1]u8 = undefined;
    for (user, 0..) |char, at| user_upper[at] = names.upper(char);
    var host: [64]u8 = @splat(0);
    _ = st.sb.GetHostName(&host, host.len - 1);
    const identity: ntlm.Identity = .{
        .user = user,
        .user_upper = user_upper[0..user.len],
        .domain = cString(&startup.domain),
        .workstation = cString(&host),
        .nt_hash = if (startup.flags & smb.SMBF_HASH != 0) startup.nt_hash else null,
    };
    var inventions: ntlm.Inventions = .{ .client_challenge = undefined, .random_session_key = undefined, .time = session.server_time };
    cb.RandomBytes(&inventions.client_challenge, 8);
    cb.RandomBytes(&inventions.random_session_key, 16);
    var nonce_salt: [4]u8 = undefined;
    cb.RandomBytes(&nonce_salt, 4);
    const encrypt = startup.flags & smb.SMBF_ENCRYPT != 0;
    if (encrypt and session.cipher == smb.SMB2_CIPHER_NONE) {
        result.stage = smb.SMBSTAGE_SECURITY;
        result.@"error" = smb.SMBSECURITY_ENCRYPTION;
        return false;
    }
    const logged_on = logon_area.logon(session, &identity, &inventions, &nonce_salt, encrypt) catch |err| return failed(result, smb.SMBSTAGE_LOGON, err);
    switch (logged_on) {
        .security => |reason| {
            result.stage = smb.SMBSTAGE_SECURITY;
            result.@"error" = reason;
            return false;
        },
        .status => |status| if (status != smb.STATUS_SUCCESS) {
            result.stage = smb.SMBSTAGE_LOGON;
            result.status = status;
            return false;
        },
    }
    result.session_flags = session.session_flags;
    result.signing = if (session.signed) session.signer.algorithm else smb.SMB2_SIGNING_NONE;

    const tree = logon_area.connectTree(session, server, cString(&startup.share)) catch |err| return failed(result, smb.SMBSTAGE_TREE, err);
    switch (tree) {
        .security => |reason| {
            result.stage = smb.SMBSTAGE_SECURITY;
            result.@"error" = reason;
            return false;
        },
        .status => |status| if (status != smb.STATUS_SUCCESS) {
            result.stage = smb.SMBSTAGE_TREE;
            result.status = status;
            return false;
        },
    }
    if (session.encrypt_all or session.encrypt_tree) result.cipher = session.keys.cipher;
    return true;
}

/// The connection made again after it was lost: what the old one had
/// forgotten, then the connection, the negotiation, the logon and the
/// tree as at the start - unless a try failed less than `retry_seconds`
/// ago. The file system's `reconnect`.
fn reconnect(fs: *FileSystem) bool {
    const st: *State = @alignCast(@fieldParentPtr("fs", fs));
    const now = seconds(st);
    if (now) |at| if (at < st.retry_after) return false;
    st.session.reset();
    if (connect(st)) {
        st.retry_after = 0;
        st.fs.read_only = readOnly(st);
        return true;
    }
    st.session.reset();
    if (now) |at| st.retry_after = at + retry_seconds;
    return false;
}

/// Whether nothing is to be written: the startup says so, or the share's
/// MaximalAccess does not let the user write - when the server says it.
fn readOnly(st: *State) bool {
    if (st.startup.flags & smb.SMBF_READONLY != 0) return true;
    const access = st.session.maximal_access;
    return access != 0 and access & (commands.FILE_WRITE_DATA | commands.FILE_APPEND_DATA) == 0;
}

/// The file system's clock: seconds on the E-clock.
fn clockSeconds(fs: *FileSystem) ?u64 {
    const st: *State = @alignCast(@fieldParentPtr("fs", fs));
    return seconds(st);
}

/// Seconds on the E-clock, which only ever counts up - whatever the
/// system's time is set to; null without timer.device.
fn seconds(st: *State) ?u64 {
    if (st.clock_port == null) return null;
    const timer_base: *TimerBase = @ptrCast(@alignCast(st.clock.node.device orelse return null));
    var value: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&value);
    if (rate == 0) return null;
    return value.toTicks() / rate;
}

/// The idle timer's request, opened on timer.device with a port of its
/// own. Without it the handler still works; it sends no ECHO, and tries
/// a reconnection whenever it is asked to.
fn openClock(st: *State) void {
    const sys = st.sys;
    const port = sys.CreateMsgPort() orelse return;
    st.clock = .{ .node = .{ .message = .{ .reply_port = port, .length = @sizeOf(timer.TimeRequest) } } };
    if (sys.OpenDevice(timer.TIMERNAME, timer.UNIT_VBLANK, &st.clock.node, 0) != 0) {
        sys.DeleteMsgPort(port);
        return;
    }
    st.clock_port = port;
}

/// The idle timer started for `idle_seconds`.
fn startClock(st: *State) void {
    if (st.clock_port == null or st.clock_running) return;
    st.clock.node.command = timer.TR_ADDREQUEST;
    st.clock.time = .{ .secs = idle_seconds };
    st.sys.SendIO(&st.clock.node);
    st.clock_running = true;
}

/// The idle timer stopped and its device closed.
fn closeClock(st: *State) void {
    const port = st.clock_port orelse return;
    if (st.clock_running) {
        _ = st.sys.AbortIO(&st.clock.node);
        _ = st.sys.WaitIO(&st.clock.node);
        st.clock_running = false;
    }
    st.sys.CloseDevice(&st.clock.node);
    st.sys.DeleteMsgPort(port);
    st.clock_port = null;
}

/// A stage that broke off: a signature or seal that was wrong is a
/// security failure, anything else a failure at the stage itself, with
/// no status from the server.
fn failed(result: *smb.SmbResult, stage: u32, err: session_area.Error) bool {
    result.stage = stage;
    if (err == error.Security) {
        result.stage = smb.SMBSTAGE_SECURITY;
        result.@"error" = smb.SMBSECURITY_SIGNATURE;
    }
    return false;
}

/// The bytes of a NUL-terminated array up to its NUL.
fn cString(bytes: []const u8) []const u8 {
    for (bytes, 0..) |byte, at| if (byte == 0) return bytes[0..at];
    return bytes;
}

/// The zone the system clock keeps, as battmem.resource holds it; UTC
/// while nobody wrote it.
fn timeZone(sys: *ExecBase) dos.timezone.Zone {
    const base: *battmem.BattMemBase = @ptrCast(sys.OpenResource(battmem.BATTMEMNAME) orelse return .{});
    var bits: u64 = 0;
    if (base.ReadBattMem(@ptrCast(&bits), battmembits.BATTMEM_ZONE_ADDR, battmembits.BATTMEM_ZONE_LEN) != 0) return .{};
    return dos.timezone.unpack(bits) orelse .{};
}

/// The volume on the device list, named after the share or as the
/// startup says, dated now.
fn addVolume(st: *State) void {
    const startup = st.startup;
    const given = cString(&startup.volume);
    const name = if (given.len > 0) given else cString(&startup.share);
    @memcpy(st.volume_name[0..name.len], name);
    st.fs.volume_name = st.volume_name[0..name.len];
    _ = st.dl.DateStamp(&st.fs.volume_date);
    const entry = st.dl.MakeDosEntry(@ptrCast(&st.volume_name), dos.DLT_VOLUME) orelse return;
    entry.misc.volume.disk_type = smb.ID_SMB_DISK;
    entry.misc.volume.volume_date = st.fs.volume_date;
    entry.task = st.fs.port;
    if (!st.dl.AddDosEntry(entry)) {
        st.dl.FreeDosEntry(entry);
        return;
    }
    st.volume = entry;
    st.fs.volume_node = entry;
}

/// The volume off the device list and freed. The list is only ever
/// tried for: a program holding it may be waiting on this handler, so
/// packets that come meanwhile are answered as for a device that has
/// gone.
fn removeVolume(st: *State, port: *exec.MsgPort) void {
    const entry = st.volume orelse return;
    const flags = dos.LDF_VOLUMES | dos.LDF_DELETE | dos.LDF_WRITE;
    for (0..list_tries) |_| {
        if (st.dl.AttemptLockDosList(flags) != null) {
            const removed = st.dl.RemDosEntry(entry);
            st.dl.UnLockDosList(flags);
            if (removed) st.dl.FreeDosEntry(entry);
            st.volume = null;
            return;
        }
        while (st.sys.GetMsg(port)) |message| {
            st.dl.ReplyPkt(DosPacket.fromMessage(message), dos.DOSFALSE, dos.ERROR_DEVICE_NOT_MOUNTED);
        }
        st.dl.Delay(list_try_ticks);
    }
}

/// It is in `.resident`, which program.ld KEEPs: nothing in the file
/// refers to the tag, dos finds it by looking.
export const smb_handler_tag: exec.ResidentHandler linksection(".resident") = .{
    .resident = .{
        .match_tag = &smb_handler_tag.resident,
        .flags = 0,
        .version = HANDLER_VERSION,
        .type = .handler,
        .pri = 0,
        .name = HANDLER_NAME,
        .id_string = HANDLER_VERSION_STRING[1..],
    },
    .handler = &fsHandler,
};

/// A handler is not a command. Whoever runs this file gets nothing done
/// and a return code that says so.
fn programEntry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    exec.kprintf(sys, "%s is a handler, not a command\n", .{HANDLER_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
const version_tag: [HANDLER_VERSION_STRING.len:0]u8 linksection(".version") = HANDLER_VERSION_STRING.*;

// The file's entry and its version string, under the names the loader and
// `Version` look for; the host tests build this file beside the other
// handlers, whose names are the same, so there they are left out.
comptime {
    if (!builtin.is_test) {
        @export(&programEntry, .{ .name = "_program_entry" });
        @export(&version_tag, .{ .name = "version_tag" });
    }
}

const testing = std.testing;

test "the handler's tag names the handler and its entry" {
    try testing.expectEqual(exec.NodeType.handler, smb_handler_tag.resident.type);
    try testing.expectEqualStrings(HANDLER_NAME, std.mem.span(smb_handler_tag.resident.name));
    try testing.expectEqual(@as(?exec.TaskFn, &fsHandler), smb_handler_tag.handler);
}
