// SPDX-License-Identifier: MPL-2.0
//! flashfs-handler: the flash file system as a ROM module. flash.device
//! reads the disk's RigidDiskBlock at boot and makes a node per partition
//! (src/rom/devs/flash/mount.zig), whose startup message says which
//! device, which unit with which flags, and which blocks of it are the
//! partition's. The handler works on those blocks and nothing else.
//!
//! The format on the medium and the packets are in `volume.zig` and
//! `disk.zig`, both generic over the medium, so all of it is tested on the
//! host. This file is what the target needs: the ROM tag, the process, and
//! the medium made out of flash.device.
//!
//! On starting it opens the device, asks for its geometry and mounts the
//! volume. A medium with no file system on it is not an error: the handler
//! stays, answers ERROR_NOT_A_DOS_DISK, and waits for ACTION_FORMAT, so the
//! medium can be formatted from the running system.
//!
//! **Inhibit** (ACTION_INHIBIT) puts what the log holds on the flash and
//! answers every packet but those that give a lock back as for a disk that
//! cannot be read, while Info says the drive is busy (ID_BUSY_DISK). It is
//! refused while a file is open for writing, and inhibits nest. The
//! partition is this handler's alone, so the volume is as it left it when
//! the last inhibit is taken back.
//!
//! **Format** (ACTION_FORMAT) writes a fresh volume over the partition,
//! only with nothing on it in use: the drive inhibited or holding no file
//! system, and no lock on it - the tree is in memory, and every lock
//! points into it.
//!
//! Notification's watchers (`dos.notify.Watchers`) are the process's: the
//! file system tells them of its changes, and their replies come to a
//! port of their own, which the process waits on beside its packets.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const trackdisk = sdk.devices.trackdisk;
const flashfs = dos.flashfs;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const DosPacket = dos.DosPacket;
const Process = dos.Process;
const MsgPort = exec.MsgPort;
const disk = @import("disk.zig");

pub const HANDLER_NAME = "flashfs-handler";
const HANDLER_VERSION = 1;
const HANDLER_REVISION = 7;
const BUILD_DATE = "17.10.2026";
const HANDLER_VERSION_STRING =
    "\x00$VER: " ++ HANDLER_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ HANDLER_VERSION, HANDLER_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The name a volume gets when nothing else says otherwise.
pub const DEFAULT_LABEL = "Empty";

/// The medium: the partition of the device the startup message names. Every
/// address is the partition's own, so the file system on it never sees the
/// rest of the disk - which is what keeps the RigidDiskBlock, and any other
/// partition, out of its reach.
pub const DeviceMedia = struct {
    sys: *ExecBase,
    dl: *DosBase,
    /// The request every command goes out on, and its reply port.
    io: *exec.IOStdReq,
    port: *MsgPort,
    geometry: trackdisk.DriveGeometry = .{},
    /// The partition: its first byte on the device, and how many it has.
    first: u32 = 0,
    length: u32 = 0,

    pub fn alloc(m: *DeviceMedia, bytes_wanted: u32) ?[]u8 {
        const block = m.sys.AllocVec(bytes_wanted, exec.MEMF_CLEAR) orelse return null;
        const p: [*]u8 = @ptrCast(block);
        return p[0..bytes_wanted];
    }

    pub fn free(m: *DeviceMedia, block: []u8) void {
        m.sys.FreeVec(block.ptr);
    }

    pub fn now(m: *DeviceMedia) dos.DateStamp {
        var stamp: dos.DateStamp = .{};
        _ = m.dl.DateStamp(&stamp);
        return stamp;
    }

    pub fn size(m: *DeviceMedia) u32 {
        return m.length;
    }

    pub fn sectorSize(m: *DeviceMedia) u32 {
        return m.geometry.sector_size;
    }

    pub fn pageSize(m: *DeviceMedia) u32 {
        return m.geometry.write_size;
    }

    /// The partition as memory, when the device can be read that way
    /// (flash.device maps its unit into the data window).
    pub fn bytes(m: *DeviceMedia) ?[]const u8 {
        if (m.geometry.map_base == 0) return null;
        const p: [*]const u8 = @ptrFromInt(m.geometry.map_base + m.first);
        return p[0..m.length];
    }

    pub fn read(m: *DeviceMedia, at: u32, into: []u8) bool {
        return m.command(exec.CMD_READ, at, into.len, into.ptr);
    }

    pub fn write(m: *DeviceMedia, at: u32, from: []const u8) bool {
        return m.command(exec.CMD_WRITE, at, from.len, @constCast(from.ptr));
    }

    pub fn erase(m: *DeviceMedia, at: u32, len: u32) bool {
        return m.command(trackdisk.TDCMD_ERASE, at, len, null);
    }

    fn command(m: *DeviceMedia, what: u16, at: u32, len: usize, data: ?*anyopaque) bool {
        if (at > m.length or len > m.length - at) return false;
        m.io.req.command = what;
        m.io.offset = m.first + at;
        m.io.length = len;
        m.io.data = data;
        m.io.actual = 0;
        return m.sys.DoIO(&m.io.req) == 0;
    }
};

const FileSystem = disk.FileSystem(DeviceMedia);

/// Everything the process keeps, in one allocation.
const State = struct {
    media: DeviceMedia,
    fs: FileSystem,
    io: exec.IOStdReq,
    /// The volume node, while there is a readable file system.
    volume: ?*dos.DosList = null,
    /// The device node dos started us for.
    node: ?*dos.DosList = null,
    mounted: bool = false,
    /// The volume node is to be made again - after a format - once the
    /// device list can be had.
    renew: bool = false,
    /// The volume's name after ACTION_RENAME_DISK, for its node.
    label: dos.volumename.VolumeName = .{},
    /// ACTION_INHIBIT's count: while it is not 0 the drive is busy.
    inhibited: u32 = 0,
    /// Who watches what, when there was memory for its port.
    watchers: dos.notify.Watchers = undefined,
    /// The record locks, when there was memory for their port.
    records: dos.record.Records = undefined,
};

/// The handler process: ACTION_STARTUP (the device from the startup
/// message, the volume node), then packets for good.
pub fn fsHandler(sb: *ExecBase) callconv(.c) void {
    const lib = sb.OpenLibrary(dos.DOSNAME, 0) orelse return;
    const dl: *DosBase = @ptrCast(lib);
    const startup = dl.WaitPkt() orelse return;
    if (startup.getAction() != .startup) {
        dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_ACTION_NOT_KNOWN);
        return;
    }
    const me: *Process = @fieldParentPtr("task", sb.FindTask(null).?);
    const fssm: ?*const dos.FileSysStartupMsg = @ptrFromInt(@as(usize, @bitCast(startup.args.raw[1])));
    const node: ?*dos.DosList = @ptrFromInt(@as(usize, @bitCast(startup.args.raw[2])));

    const port = sb.CreateMsgPort() orelse return dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_NO_FREE_STORE);
    const block = sb.AllocVec(@sizeOf(State), exec.MEMF_CLEAR) orelse
        return dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_NO_FREE_STORE);
    const st: *State = @ptrCast(@alignCast(block));
    st.node = node;
    st.io = .{ .req = .{ .message = .{ .reply_port = port, .length = @sizeOf(exec.IOStdReq) } } };
    st.media = .{ .sys = sb, .dl = dl, .io = &st.io, .port = port };

    const device = if (fssm) |f| f.device orelse "" else "";
    const unit = if (fssm) |f| f.unit else 0;
    const flags = if (fssm) |f| f.flags else 0;
    if (device[0] == 0 or sb.OpenDevice(device, unit, &st.io.req, flags) != 0) {
        sb.FreeVec(block);
        sb.DeleteMsgPort(port);
        return dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_DEVICE_NOT_MOUNTED);
    }
    st.io.req.command = trackdisk.TD_GETGEOMETRY;
    st.io.data = &st.media.geometry;
    st.io.length = @sizeOf(trackdisk.DriveGeometry);
    if (sb.DoIO(&st.io.req) != 0 or st.media.geometry.sector_size == 0 or !partition(st, fssm)) {
        sb.CloseDevice(&st.io.req);
        sb.FreeVec(block);
        sb.DeleteMsgPort(port);
        return dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_NOT_A_DOS_DISK);
    }

    st.fs = FileSystem.init(&st.media, &me.msg_port);
    if (st.watchers.init(sb)) st.fs.watchers = &st.watchers;
    if (st.records.init(sb, dl)) st.fs.records = &st.records;
    if (st.fs.mount()) |_| {
        st.mounted = true;
        addVolume(sb, dl, st);
    } else |_| {
        // No file system on it yet: the handler stays, so `format` has
        // somewhere to send ACTION_FORMAT.
        st.mounted = false;
    }
    if (node) |n| n.task = &me.msg_port;
    dl.ReplyPkt(startup, dos.DOSTRUE, 0);

    // Packets on the process's port; the watchers' replies and the record
    // locks' timers on theirs.
    const packets = &me.msg_port;
    const replies: u32 = if (st.fs.watchers) |watchers| watchers.signals() else 0;
    const timers: u32 = if (st.fs.records) |records| records.signals() else 0;
    while (true) {
        if (st.fs.watchers) |watchers| watchers.collect();
        if (st.fs.records) |records| records.collect();
        while (sb.GetMsg(packets)) |message| {
            const pkt = DosPacket.fromMessage(message);
            const reply = serve(st, pkt);
            if (!reply.held) dl.ReplyPkt(pkt, reply.res1, reply.res2);
            if (st.renew) renewVolume(sb, dl, st);
            st.label.apply(dl, st.volume);
        }
        _ = sb.Wait(packets.sigMask() | replies | timers);
    }
}

/// The blocks of the device the startup message's environment gives this
/// handler, checked against what the device says it has. The file system's
/// block must be the device's erase unit: it erases a whole one at a time.
fn partition(st: *State, fssm: ?*const dos.FileSysStartupMsg) bool {
    const env = (fssm orelse return false).environ orelse return false;
    const geo = &st.media.geometry;
    if (env.size_block != geo.sector_size) return false;
    const blocks = env.blocks();
    const first = env.byteOf(0);
    const total = geo.total_sectors * geo.sector_size;
    if (blocks < 2 or first + blocks * env.size_block > total) return false;
    st.media.first = @intCast(first);
    st.media.length = @intCast(blocks * env.size_block);
    return true;
}

/// One packet. Before there is a file system, and while the drive is
/// inhibited, only the ones that say what the disk is, ACTION_INHIBIT and
/// ACTION_FORMAT get through - and, inhibited, those that give a lock
/// back.
fn serve(st: *State, pkt: *DosPacket) disk.Answer {
    const action = pkt.getAction();
    switch (action) {
        .inhibit => return inhibit(st, pkt.args.raw[0] != dos.DOSFALSE),
        .format => return formatVolume(st, pkt),
        else => {},
    }
    if (st.inhibited != 0) switch (action) {
        .free_lock, .end, .free_record => if (st.mounted) return st.fs.answer(pkt),
        else => {},
    };
    if (!st.mounted or st.inhibited != 0) {
        switch (action) {
            .disk_info, .info => {
                const data: ?*dos.InfoData = if (action == .disk_info)
                    @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[0])))
                else
                    pkt.args.info.info;
                if (data) |d| d.* = .{
                    .disk_state = dos.ID_VALIDATED,
                    .num_blocks = st.media.length / st.media.geometry.sector_size,
                    .bytes_per_block = st.media.geometry.sector_size,
                    .disk_type = if (st.inhibited != 0) dos.ID_BUSY_DISK else dos.ID_NOT_REALLY_DOS,
                    .unit_number = 0,
                };
                return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
            },
            .is_filesystem => return .{ .res1 = dos.DOSTRUE, .res2 = 0 },
            .die => return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_OBJECT_IN_USE },
            else => return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_NOT_A_DOS_DISK },
        }
    }
    const reply = st.fs.answer(pkt);
    // A rename keeps the node and gives it the name.
    if (action == .rename_disk and reply.res1 != dos.DOSFALSE) st.label.set(st.fs.volumeName());
    return reply;
}

/// ACTION_INHIBIT: on, what the log holds put on the flash and the drive
/// busy - refused with ERROR_OBJECT_IN_USE while a file is open for
/// writing, whose writes would have nowhere to go; off, the drive in use
/// again. They nest, and off on a drive that is not inhibited does
/// nothing.
fn inhibit(st: *State, on: bool) disk.Answer {
    if (!on) {
        if (st.inhibited != 0) st.inhibited -= 1;
        return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
    }
    if (st.inhibited == 0 and st.mounted) {
        if (st.fs.writing()) return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_OBJECT_IN_USE };
        st.fs.flush() catch |e| return .{ .res1 = dos.DOSFALSE, .res2 = disk.codeOf(e) };
    }
    st.inhibited += 1;
    return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
}

/// ACTION_FORMAT: a fresh volume over the partition, named as dp_Arg1 says
/// (DEFAULT_LABEL without). Only with nothing on it in use - the drive
/// inhibited or holding no file system, and no lock on the volume - else
/// ERROR_OBJECT_IN_USE; a name a volume cannot have is refused before
/// anything is written. The DosType in dp_Arg2 is not looked at: the
/// flash file system has one format. The volume's node is made again
/// once the packet is answered.
fn formatVolume(st: *State, pkt: *DosPacket) disk.Answer {
    if (st.mounted and st.inhibited == 0) return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_OBJECT_IN_USE };
    const label: ?[*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[0])));
    const name: []const u8 = if (label) |l| std.mem.span(l) else DEFAULT_LABEL;
    const made = if (st.mounted) st.fs.reformat(name) else st.fs.format(name);
    made catch |e| return .{ .res1 = dos.DOSFALSE, .res2 = disk.codeOf(e) };
    st.mounted = true;
    st.renew = true;
    return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
}

/// The volume node made again to match the file system, but only if the
/// device list can be had at once. A program holding it may be waiting
/// on this very handler for an answer - Info holds it while it asks every
/// device - so waiting for it would never end; the node is renewed after
/// a later packet instead.
fn renewVolume(sb: *ExecBase, dl: *DosBase, st: *State) void {
    const flags = dos.LDF_ALL | dos.LDF_ENTRY | dos.LDF_DELETE | dos.LDF_WRITE;
    _ = dl.AttemptLockDosList(flags) orelse return;
    defer dl.UnLockDosList(flags);
    removeVolume(sb, dl, st);
    addVolume(sb, dl, st);
    st.renew = false;
}

/// The volume on the device list, named as the superblock has it, so
/// `doslist` shows it and locks can point at it.
fn addVolume(sb: *ExecBase, dl: *DosBase, st: *State) void {
    _ = sb;
    var name: [flashfs.max_volume_name + 1:0]u8 = @splat(0);
    const label = st.fs.volumeName();
    const len = @min(label.len, flashfs.max_volume_name);
    @memcpy(name[0..len], label[0..len]);
    const entry = dl.MakeDosEntry(if (len == 0) DEFAULT_LABEL else &name, dos.DLT_VOLUME) orelse return;
    entry.misc.volume.disk_type = flashfs.ID_FLASHFS_DISK;
    entry.misc.volume.volume_date = st.fs.vol.super.created;
    entry.task = st.fs.port;
    if (!dl.AddDosEntry(entry)) {
        dl.FreeDosEntry(entry);
        return;
    }
    st.volume = entry;
    st.fs.volume_node = entry;
}

/// The volume node off the device list and freed. The caller holds the
/// list.
fn removeVolume(sb: *ExecBase, dl: *DosBase, st: *State) void {
    _ = sb;
    const entry = st.volume orelse return;
    st.volume = null;
    st.fs.volume_node = null;
    if (dl.RemDosEntry(entry)) dl.FreeDosEntry(entry);
}

export const fs_handler_tag: exec.ResidentHandler linksection(".resident") = .{
    .resident = .{
        .match_tag = &fs_handler_tag.resident,
        .flags = 0,
        .version = HANDLER_VERSION,
        .type = .handler,
        .pri = -122,
        .name = HANDLER_NAME,
        .id_string = HANDLER_VERSION_STRING[1..],
    },
    .handler = &fsHandler,
};

const testing = std.testing;

test "the ROM tag names the handler and its entry" {
    try testing.expectEqual(exec.NodeType.handler, fs_handler_tag.resident.type);
    try testing.expectEqualStrings(HANDLER_NAME, std.mem.span(fs_handler_tag.resident.name));
    try testing.expectEqual(@as(?exec.TaskFn, &fsHandler), fs_handler_tag.handler);
}
