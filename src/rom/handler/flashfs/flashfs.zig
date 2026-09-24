// SPDX-License-Identifier: MPL-2.0
//! flashfs-handler: the flash file system as a ROM module. dos.library's
//! init reads the disk's RigidDiskBlock and gives the handler a node per
//! partition whose startup message says which device, which unit and which
//! blocks of it are the partition's (src/rom/libs/dos/mount.zig).
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
const HANDLER_REVISION = 0;
const BUILD_DATE = "16.9.2026";
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
    /// de_NumBuffers from the environment, which ACTION_MORE_CACHE answers
    /// with.
    buffers: u32 = 0,
    mounted: bool = false,
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
    if (device[0] == 0 or sb.OpenDevice(device, unit, &st.io.req, 0) != 0) {
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
    st.fs.buffers = st.buffers;
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

    while (dl.WaitPkt()) |pkt| {
        const reply = serve(sb, dl, st, pkt);
        dl.ReplyPkt(pkt, reply.res1, reply.res2);
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
    st.buffers = env.num_buffers;
    return true;
}

/// One packet. Before there is a file system only the ones that say what
/// the disk is, and ACTION_FORMAT, get through.
fn serve(sb: *ExecBase, dl: *DosBase, st: *State, pkt: *DosPacket) disk.Answer {
    const action = pkt.getAction();
    if (!st.mounted) {
        switch (action) {
            .format => {
                const label: ?[*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[0])));
                const name: []const u8 = if (label) |l| std.mem.span(l) else DEFAULT_LABEL;
                st.fs.format(name) catch |e| return .{ .res1 = dos.DOSFALSE, .res2 = disk.codeOf(e) };
                st.mounted = true;
                addVolume(sb, dl, st);
                return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
            },
            .disk_info, .info => {
                const data: ?*dos.InfoData = if (action == .disk_info)
                    @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[0])))
                else
                    pkt.args.info.info;
                if (data) |d| d.* = .{
                    .disk_state = dos.ID_VALIDATED,
                    .num_blocks = st.media.length / st.media.geometry.sector_size,
                    .bytes_per_block = st.media.geometry.sector_size,
                    .disk_type = dos.ID_NOT_REALLY_DOS,
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
    // A format renames the volume, so its node is made again.
    if (action == .format and reply.res1 != dos.DOSFALSE) {
        removeVolume(sb, dl, st);
        addVolume(sb, dl, st);
    }
    return reply;
}

/// The volume on the device list, named as the superblock has it, so
/// `doslist` shows it and locks can point at it.
fn addVolume(sb: *ExecBase, dl: *DosBase, st: *State) void {
    _ = sb;
    var name: [flashfs.max_name + 1:0]u8 = @splat(0);
    const label = st.fs.vol.name();
    const len = @min(label.len, flashfs.max_name);
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
