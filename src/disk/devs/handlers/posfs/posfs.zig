// SPDX-License-Identifier: MPL-2.0
//! posfs-handler: the PowerOS file system, a handler loaded from
//! HANDLERS: the first time a drive needs it, for any drive
//! whose DosType names posfs - on the internal flash, where flash.device
//! makes a node per partition of the disk's RigidDiskBlock
//! (src/rom/devs/flash/mount.zig), on a card a mountlist names, or on a
//! stick usb/disk.device finds it on. The startup message says which
//! device, which unit with which flags, and which blocks of it are the
//! drive's area - cylinders of a disk, or the whole medium when it names
//! none, read again for each one. Where the volume is in that area the
//! DosType says: `POS\0`, the area is the volume; `POS\1`, the area begins
//! with a partition table and the volume is its first partition of type
//! 0x7F (`sdk.dos.posfs.table`), as Format lays a card out. The handler
//! works on those blocks and nothing else.
//!
//! The file system itself is `fs.zig` and what it is built on, which call
//! no library: the medium comes to them as a table of calls
//! (`media.Device`), so all of it runs in the host tests and in
//! tools/posfsck as it runs here. This file is what the target needs:
//! the handler's tag, the process, and the medium made out of the device.
//!
//! On starting it opens the device, asks for its geometry and mounts the
//! volume, replaying the journal when the volume was not put away. A
//! medium with no posfs volume on it is not an error, nor is no medium:
//! the handler stays, answers ERROR_NOT_A_DOS_DISK or ERROR_NO_DISK, and
//! waits for ACTION_FORMAT or a medium, so either can come while the
//! system runs.
//!
//! **A medium comes and goes.** Before each packet the handler asks the
//! device whether its medium has changed (TD_CHANGENUM), and a device
//! that can tell causes the handler's change interrupt (TD_ADDCHANGEINT)
//! when one goes in or out, so it looks then too and tells input
//! (IECLASS_DISKINSERTED, IECLASS_DISKREMOVED). A medium that went takes
//! what the volume held in memory with it, unwritten - what was answered
//! is in its journal - and what its open files had not committed. Its
//! locks are kept (`retire`), and so is its volume node, on the device
//! list with no handler behind it while locks point at it: that is what
//! lets dos ask for the volume by name. The same volume coming back - the
//! same id in its label, whatever its name - takes the node up again and
//! its locks work again; the node goes once no lock points at it.
//!
//! **Idle work.** A change is durable when it is answered: it is in the
//! journal. What the trees hold in memory goes down as a checkpoint when
//! the journal or the changed nodes run full, and otherwise once the
//! handler has had nothing to do for a while - 30 seconds on flash, whose
//! sectors wear, 5 on a disk. A timer on timer.device's UNIT_VBLANK, made
//! when changes first wait, wakes the process for it.
//!
//! **Inhibit** (ACTION_INHIBIT) commits every open file's changes and
//! writes a checkpoint, then answers every packet but those that give a
//! lock back as for a disk that cannot be read, while Info says the drive
//! is busy (ID_BUSY_DISK). It is refused while a file is open for
//! writing, and inhibits nest.
//!
//! **Rollback** (ACTION_POSFS_ROLLBACK) puts the volume back to its
//! newest snapshot only while the drive is inhibited and nothing on it is
//! locked, so it gets through the inhibit.
//!
//! **Format** (ACTION_FORMAT) writes a fresh volume over the area, only
//! with nothing on it in use: the drive inhibited or holding no file
//! system, and no lock or handle on it. Its block size is the
//! partition's own block, raised to 4 KiB, and on flash at least the
//! erase sector. On a `POS\1` drive the volume goes into a partition from
//! the medium's first unit of writing (4 MiB on a card) to its end, and
//! the table that says so is written after it.
//!
//! Notification's watchers and the record locks are the process's, as
//! for the other file systems: the file system tells the watchers of its
//! changes, and their replies and the record locks' timers come to ports
//! of their own, which the process waits on beside its packets. So is
//! ExAll's matcher, utility.library's MatchPatternNoCase and CallHookPkt,
//! which EXAMINE_ALL tries each entry with.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const trackdisk = sdk.devices.trackdisk;
const timer = sdk.devices.timer;
const posfs = dos.posfs;
const layout = posfs.layout;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const Hook = sdk.utility.Hook;
const inputevent = sdk.devices.inputevent;
const DosPacket = dos.DosPacket;
const Process = dos.Process;
const MsgPort = exec.MsgPort;
const media = @import("media.zig");
const fs_core = @import("fs.zig");

pub const HANDLER_NAME = posfs.HANDLER_NAME;
const HANDLER_VERSION = 1;
const HANDLER_REVISION = 3;
const BUILD_DATE = "18.10.2026";
const HANDLER_VERSION_STRING =
    "\x00$VER: " ++ HANDLER_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ HANDLER_VERSION, HANDLER_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The name a volume gets when ACTION_FORMAT names none.
pub const DEFAULT_LABEL = "Empty";

/// How long the handler waits with nothing to do before it writes a
/// checkpoint, on a medium that is erased (flash) and on one that is not.
const idle_flash_micros: u64 = 30_000_000;
const idle_disk_micros: u64 = 5_000_000;

/// The medium: the volume's blocks on the device the startup message
/// names. Every address is the volume's own, so the file system never
/// sees the rest of the disk - the RigidDiskBlock, a partition table and
/// any other partition stay out of its reach. Where the volume is, is
/// worked out again for each medium put in (`place`).
pub const DeviceMedia = struct {
    sys: *ExecBase,
    dl: *DosBase,
    /// The request every command goes out on.
    io: *exec.IOStdReq,
    geometry: trackdisk.DriveGeometry = .{},
    /// The area the environment gives, in bytes from the device's first:
    /// null for the whole medium, however large each one is.
    area: ?Area = null,
    /// Whether the area begins with a partition table, the volume in its
    /// first partition of type 0x7F (`POS\1`).
    table: bool = false,
    /// The area on the medium in the drive: its first byte on the device,
    /// and how many it has.
    area_first: u64 = 0,
    area_length: u64 = 0,
    /// The volume: its first byte on the device, and how many it has.
    first: u64 = 0,
    length: u64 = 0,
    /// The most bytes one command may move (de_MaxTransfer).
    max_transfer: u64 = 0x7FFF_FFFF,
    /// Written to since the device was last told to put what it holds on
    /// the medium itself.
    unsynced: bool = false,

    pub const Area = struct { first: u64, bytes: u64 };

    /// The startup message's environment: the area - cylinders, or none
    /// for the whole medium - what is in it, and the most a command moves.
    pub fn takeEnvironment(m: *DeviceMedia, env: *const dos.filehandler.DosEnvec) void {
        if (!env.wholeMedium()) m.area = .{ .first = env.byteOf(0), .bytes = env.blocks() * env.size_block };
        m.table = posfs.partitionedType(env.dos_type);
        if (env.table_size >= dos.filehandler.DE_MAXTRANSFER and env.max_transfer != 0) m.max_transfer = env.max_transfer;
    }

    /// The area on the medium in the drive now: its geometry read again,
    /// and the environment's cylinders checked against it, or the whole
    /// medium. The volume is the area until `place` says otherwise. False
    /// with no medium, or one the area does not fit.
    pub fn placeArea(m: *DeviceMedia) bool {
        m.first = 0;
        m.length = 0;
        m.geometry = .{};
        if (!m.command(trackdisk.TD_GETGEOMETRY, 0, @sizeOf(trackdisk.DriveGeometry), &m.geometry)) return false;
        const sector: u64 = m.geometry.sector_size;
        if (sector == 0) return false;
        const total = m.geometry.total_sectors * sector;
        var first: u64 = 0;
        var length: u64 = total;
        if (m.area) |area| {
            if (area.first % sector != 0 or area.first > total or area.bytes > total - area.first) return false;
            first = area.first;
            length = area.bytes;
        }
        if (length < 2 * sector) return false;
        m.area_first = first;
        m.area_length = length;
        m.first = first;
        m.length = length;
        return true;
    }

    /// The volume on the medium in the drive now: the area, and with a
    /// partition table the volume's partition in it. False with no medium,
    /// or no place for a volume on it.
    pub fn place(m: *DeviceMedia) bool {
        if (!m.placeArea()) return false;
        if (!m.table) return true;
        const sector: u64 = m.geometry.sector_size;
        const block = m.alloc(@intCast(sector)) orelse return false;
        defer m.free(block);
        if (!m.command(exec.CMD_READ, m.area_first, sector, block.ptr)) return false;
        const partition = posfs.table.volumeIn(block) orelse return false;
        const start = @as(u64, partition.first) * sector;
        const bytes = @as(u64, partition.blocks) * sector;
        if (start > m.area_length or bytes > m.area_length - start or bytes < 2 * sector) return false;
        m.first = m.area_first + start;
        m.length = bytes;
        return true;
    }

    /// The partition table a format writes on a `POS\1` drive: the volume
    /// put in a partition from the medium's first unit of writing to the
    /// area's end (as far as the table's 32-bit count reaches). The table
    /// itself is written by `writeTable`, after the volume.
    pub fn planTable(m: *DeviceMedia) bool {
        const sector: u64 = m.geometry.sector_size;
        const blocks = m.area_length / sector;
        const first = posfs.table.firstBlockFor(blocks, @intCast(sector));
        if (first + 2 > blocks) return false;
        const count: u64 = @min(blocks - first, 0xFFFF_FFFF);
        m.first = m.area_first + first * sector;
        m.length = count * sector;
        return true;
    }

    /// The table for the volume `planTable` placed, in the area's first
    /// block.
    pub fn writeTable(m: *DeviceMedia) bool {
        const sector: u64 = m.geometry.sector_size;
        const block = m.alloc(@intCast(sector)) orelse return false;
        defer m.free(block);
        var signature: [16]u8 = undefined;
        m.random(&signature);
        const first: u32 = @intCast((m.first - m.area_first) / sector);
        const count: u32 = @intCast(m.length / sector);
        posfs.table.writeTable(block, first, count, dos.fat.u32At(&signature, 0));
        m.unsynced = true;
        return m.command(exec.CMD_WRITE, m.area_first, sector, block.ptr);
    }

    /// Whether a medium is in. With none, asking is what makes the device
    /// look for one.
    pub fn present(m: *DeviceMedia) bool {
        return m.command(trackdisk.TD_CHANGESTATE, 0, 0, null) and m.io.actual == 0;
    }

    /// The device's count of media changes.
    pub fn changeNum(m: *DeviceMedia) u32 {
        _ = m.command(trackdisk.TD_CHANGENUM, 0, 0, null);
        return @truncate(m.io.actual);
    }

    pub fn size(m: *DeviceMedia) u64 {
        return m.length;
    }

    pub fn sectorSize(m: *DeviceMedia) u32 {
        return m.geometry.sector_size;
    }

    pub fn writeSize(m: *DeviceMedia) u32 {
        return m.geometry.write_size;
    }

    pub fn eraseSize(m: *DeviceMedia) u32 {
        return m.geometry.erase_size;
    }

    /// The partition as memory, when the device can be read that way
    /// (flash.device maps its unit into the data window).
    pub fn mapped(m: *DeviceMedia) ?[*]const u8 {
        if (m.geometry.map_base == 0) return null;
        return @ptrFromInt(m.geometry.map_base + @as(usize, @intCast(m.first)));
    }

    pub fn read(m: *DeviceMedia, at: u64, into: []u8) bool {
        return m.transfer(exec.CMD_READ, at, into);
    }

    pub fn write(m: *DeviceMedia, at: u64, from: []const u8) bool {
        m.unsynced = true;
        return m.transfer(exec.CMD_WRITE, at, @constCast(from));
    }

    pub fn erase(m: *DeviceMedia, at: u64, len: u64) bool {
        if (at > m.length or len > m.length - at) return false;
        return m.command(trackdisk.TDCMD_ERASE, m.first + at, len, null);
    }

    /// What the device holds in a cache of its own put on the medium
    /// itself (CMD_UPDATE: SYNCHRONIZE CACHE on a stick). Not asked when
    /// nothing was written since the last time.
    pub fn update(m: *DeviceMedia) bool {
        if (!m.unsynced) return true;
        if (!m.command(exec.CMD_UPDATE, 0, 0, null)) return false;
        m.unsynced = false;
        return true;
    }

    pub fn writable(m: *DeviceMedia) bool {
        return m.command(trackdisk.TD_PROTSTATUS, 0, 0, null) and m.io.actual == 0;
    }

    /// Eight-byte aligned and cleared, as the file system wants.
    pub fn alloc(m: *DeviceMedia, len: usize) ?[]u8 {
        const block = m.sys.AllocVec(@intCast(len), exec.MEMF_CLEAR) orelse return null;
        const bytes: [*]u8 = @ptrCast(block);
        return bytes[0..len];
    }

    /// Eight-byte aligned, as it is: for memory filled whole first.
    pub fn allocRaw(m: *DeviceMedia, len: usize) ?[]u8 {
        const block = m.sys.AllocVec(@intCast(len), exec.MEMF_ANY) orelse return null;
        const bytes: [*]u8 = @ptrCast(block);
        return bytes[0..len];
    }

    pub fn free(m: *DeviceMedia, memory: []u8) void {
        m.sys.FreeVec(memory.ptr);
    }

    /// The system clock, in microseconds since 1 Jan 1978.
    pub fn now(m: *DeviceMedia) u64 {
        var stamp: dos.DateStamp = .{};
        _ = m.dl.DateStamp(&stamp);
        return layout.microsOf(stamp);
    }

    /// From the chip's random number generator.
    pub fn random(_: *DeviceMedia, into: *[16]u8) void {
        sdk.hardware.rng.fill(into);
    }

    /// `bytes` at the partition's byte `at`, in commands of at most
    /// de_MaxTransfer bytes. Nothing outside the partition is reached.
    fn transfer(m: *DeviceMedia, what: u16, at: u64, bytes: []u8) bool {
        if (at > m.length or bytes.len > m.length - at) return false;
        const sector: u64 = m.geometry.sector_size;
        const most: u64 = @max(m.max_transfer / sector * sector, sector);
        var done: u64 = 0;
        while (done < bytes.len) {
            const left: u64 = bytes.len - done;
            const piece: u64 = @min(left, most);
            if (!m.command(what, m.first + at + done, piece, bytes.ptr + @as(usize, @intCast(done)))) return false;
            done += piece;
        }
        return true;
    }

    fn command(m: *DeviceMedia, what: u16, offset: u64, length: u64, data: ?*anyopaque) bool {
        m.io.req.command = what;
        m.io.offset = offset;
        m.io.length = length;
        m.io.data = data;
        m.io.actual = 0;
        return m.sys.DoIO(&m.io.req) == 0;
    }
};

const FileSystem = fs_core.FileSystem;
const Answer = fs_core.Answer;

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
    /// The partition's own block (de_SizeBlock times de_SectorPerBlock),
    /// which a format's block size is taken from.
    partition_block: u32 = 0,
    /// The device's change count the volume was looked for at.
    change_num: u32 = 0,
    /// The id of the volume behind `volume`, which tells it when it comes
    /// back.
    volume_id: [16]u8 = @splat(0),
    /// Volume nodes whose medium has gone that locks still point at: left
    /// on the device list with no handler behind them, which is what dos
    /// calls not mounted, until the volume comes back or no lock points
    /// at them.
    gone: [8]Gone = @splat(.{}),
    /// The change interrupt the device causes when a medium comes or goes,
    /// the request it is kept with and that request's port, and the signal
    /// it gives the process; no signal (0) from a device whose medium
    /// stays.
    change_int: exec.Interrupt = .{},
    change_io: exec.IOStdReq = .{},
    change_port: ?*MsgPort = null,
    change_mask: u32 = 0,
    process: ?*exec.Task = null,
    /// input.device, told when a medium comes or goes.
    input: Input = .{},
    /// The idle timer: its request, the port it comes back to, and
    /// whether it runs.
    clock: timer.TimeRequest = .{},
    clock_port: ?*MsgPort = null,
    clock_open: bool = false,
    clock_running: bool = false,
    /// Who watches what, when there was memory for its port.
    watchers: dos.notify.Watchers = undefined,
    /// The record locks, when there was memory for their port.
    records: dos.record.Records = undefined,
    /// ExAll's tests, through utility.library.
    matcher: fs_core.Matcher = undefined,
    /// utility.library, for ExAll's tests and FormatTags's tags.
    ub: ?*UtilityBase = null,
};

/// A volume node kept for a volume that has gone, and that volume's id.
const Gone = struct {
    node: ?*dos.DosList = null,
    id: [16]u8 = @splat(0),
};

/// ExAll's tests through utility.library: the matcher the file system
/// is given.
pub fn utilityMatcher(ub: *UtilityBase) fs_core.Matcher {
    return .{ .context = ub, .matches = &matchesName, .takes = &takesRecord };
}

/// Whether an ExAll entry's name matches the caller's pattern.
fn matchesName(context: *anyopaque, pattern: [*:0]const u8, name: [*:0]const u8) bool {
    const ub: *UtilityBase = @ptrCast(@alignCast(context));
    return ub.MatchPatternNoCase(pattern, name);
}

/// Whether the caller's MatchFunc takes an ExAll record: the hook called
/// with the level and the record.
fn takesRecord(context: *anyopaque, hook: *Hook, level: i32, rec: *dos.ExAllData) bool {
    const ub: *UtilityBase = @ptrCast(@alignCast(context));
    var data_type: i32 = level;
    return ub.CallHookPkt(hook, &data_type, rec) != 0;
}

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
    const block = sb.AllocVec(@sizeOf(State), exec.MEMF_CLEAR) orelse {
        sb.DeleteMsgPort(port);
        return dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_NO_FREE_STORE);
    };
    const st: *State = @ptrCast(@alignCast(block));
    st.* = .{
        .media = .{ .sys = sb, .dl = dl, .io = &st.io },
        .fs = undefined,
        .io = .{ .req = .{ .message = .{ .reply_port = port, .length = @sizeOf(exec.IOStdReq) } } },
        .node = node,
    };

    const device = if (fssm) |f| f.device orelse "" else "";
    const unit = if (fssm) |f| f.unit else 0;
    const flags = if (fssm) |f| f.flags else 0;
    const env = if (fssm) |f| f.environ else null;
    if (env == null or device[0] == 0 or sb.OpenDevice(device, unit, &st.io.req, flags) != 0) {
        sb.FreeVec(block);
        sb.DeleteMsgPort(port);
        return dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_DEVICE_NOT_MOUNTED);
    }
    st.media.takeEnvironment(env.?);
    const per_block = if (env.?.sector_per_block == 0) 1 else env.?.sector_per_block;
    st.partition_block = env.?.size_block * per_block;

    st.fs = FileSystem.init(media.Device.of(DeviceMedia, &st.media));
    st.fs.port = &me.msg_port;
    // The mountlist's Buffers, when it gives any: the cache's blocks.
    if (env.?.table_size >= dos.filehandler.DE_NUMBUFFERS and env.?.num_buffers != 0) {
        st.fs.vol.cache_blocks = if (env.?.num_buffers < 32) 32 else env.?.num_buffers;
    }
    if (node) |device_node| st.fs.device_name = span(device_node.name);
    if (st.watchers.init(sb)) st.fs.watchers = &st.watchers;
    if (st.records.init(sb, dl)) st.fs.records = &st.records;
    if (sb.OpenLibrary(sdk.interface.utility.NAME, 0)) |utility| {
        st.ub = @ptrCast(utility);
        st.matcher = utilityMatcher(st.ub.?);
        st.fs.matcher = &st.matcher;
    }
    openClock(sb, st);
    // No medium, or no file system on it yet: the handler stays, for the
    // medium that will come and for ACTION_FORMAT.
    mountMedium(st);
    if (st.mounted) addVolume(dl, st);
    listenForChanges(sb, st, &me.task);
    if (node) |n| n.task = &me.msg_port;
    dl.ReplyPkt(startup, dos.DOSTRUE, 0);

    // Packets on the process's port; the watchers' replies, the record
    // locks' timers and the idle timer on theirs.
    const packets = &me.msg_port;
    const replies: u32 = if (st.fs.watchers) |watchers| watchers.signals() else 0;
    const timers: u32 = if (st.fs.records) |records| records.signals() else 0;
    const clock: u32 = if (st.clock_port) |clock_port| clock_port.sigMask() else 0;
    while (true) {
        if (st.fs.watchers) |watchers| watchers.collect();
        if (st.fs.records) |records| records.collect();
        if (st.clock_port) |clock_port| {
            if (sb.GetMsg(clock_port) != null) {
                st.clock_running = false;
                if (st.mounted and st.inhibited == 0) st.fs.idle() catch {};
            }
        }
        while (sb.GetMsg(packets)) |message| {
            const pkt = DosPacket.fromMessage(message);
            if (st.inhibited == 0 and checkMedium(st)) st.renew = true;
            if (st.renew) renewVolume(dl, st);
            const reply = serve(st, pkt);
            if (!reply.held) dl.ReplyPkt(pkt, reply.res1, reply.res2);
            if (st.renew) renewVolume(dl, st);
            sweepIfFree(dl, st);
            st.label.apply(dl, st.volume);
        }
        if (st.mounted and st.inhibited == 0 and st.fs.pending()) startClock(sb, st);
        const got = sb.Wait(packets.sigMask() | replies | timers | clock | st.change_mask);
        if (got & st.change_mask != 0) mediumChanged(sb, dl, st);
    }
}

/// Whether the medium is still the one looked at. If not, the volume
/// that was there is retired - what it held dropped unwritten, its locks
/// kept - and the new one mounted: true, so the caller renews the volume
/// node.
fn checkMedium(st: *State) bool {
    // With nothing mounted, asking whether a medium is in is what makes
    // the device look for one put in since.
    if (!st.mounted) _ = st.media.present();
    if (st.media.changeNum() == st.change_num) return false;
    if (st.mounted) {
        st.fs.retire();
        st.fs.volume_node = null;
        st.mounted = false;
    }
    mountMedium(st);
    return true;
}

/// The volume on the medium in the drive mounted, if there is one.
fn mountMedium(st: *State) void {
    st.change_num = st.media.changeNum();
    st.mounted = false;
    if (!st.media.place()) return;
    st.fs.mount() catch return;
    st.mounted = true;
}

/// The device said its medium came or went: looked at now - nobody may
/// be asking anything - the volume node renewed, and input told.
fn mediumChanged(sb: *ExecBase, dl: *DosBase, st: *State) void {
    if (st.inhibited == 0 and checkMedium(st)) st.renew = true;
    renewSoon(dl, st);
    const class = if (st.media.present()) inputevent.IECLASS_DISKINSERTED else inputevent.IECLASS_DISKREMOVED;
    st.input.announce(sb, class);
}

/// `renewVolume` until it has had the list: another handler starting or
/// renewing beside this one may hold it for a moment, so a try that fails
/// is made again a tick later - a few times, and after that the next
/// packet does it.
fn renewSoon(dl: *DosBase, st: *State) void {
    var tries: u32 = 0;
    while (st.renew and tries < renew_tries) : (tries += 1) {
        renewVolume(dl, st);
        if (st.renew) dl.Delay(1);
    }
}

/// How often the volume node is tried for, a tick apart, before the next
/// packet is left to do it.
const renew_tries = 25;

/// Its change interrupt: the process signalled, to look at the medium on
/// its own time.
fn changeInterrupt(is_data: ?*anyopaque) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(is_data.?));
    st.media.sys.Signal(st.process.?, st.change_mask);
}

/// The change interrupt given to the device, on a request and a port of
/// its own: the device keeps it for as long as the handler runs. A device
/// that does not take it - a medium that stays, as the flash - answers at
/// once, and the handler then asks only before each packet.
fn listenForChanges(sb: *ExecBase, st: *State, process: *exec.Task) void {
    const signal = sb.AllocSignal(-1);
    if (signal < 0) return;
    const port = sb.CreateMsgPort() orelse {
        sb.FreeSignal(signal);
        return;
    };
    st.process = process;
    st.change_mask = @as(u32, 1) << @intCast(signal);
    st.change_int = .{ .node = .{ .type = .interrupt, .name = HANDLER_NAME }, .data = st, .code = @ptrCast(&changeInterrupt) };
    st.change_io = st.io;
    st.change_io.req.message.reply_port = port;
    st.change_io.req.command = trackdisk.TD_ADDCHANGEINT;
    st.change_io.data = &st.change_int;
    st.change_io.length = @sizeOf(exec.Interrupt);
    sb.SendIO(&st.change_io.req);
    if (sb.CheckIO(&st.change_io.req) != null) {
        _ = sb.WaitIO(&st.change_io.req);
        sb.DeleteMsgPort(port);
        sb.FreeSignal(signal);
        st.change_mask = 0;
        return;
    }
    st.change_port = port;
}

/// input.device, opened the first time a medium is announced, and kept.
const Input = struct {
    port: ?*MsgPort = null,
    io: exec.IOStdReq = .{},
    open: bool = false,
    event: inputevent.InputEvent = .{},

    fn announce(input: *Input, sb: *ExecBase, class: u32) void {
        if (!input.open) {
            const port = input.port orelse sb.CreateMsgPort() orelse return;
            input.port = port;
            input.io = .{};
            input.io.req.message.reply_port = port;
            input.io.req.message.length = @sizeOf(exec.IOStdReq);
            if (sb.OpenDevice(sdk.devices.input.INPUTNAME, 0, &input.io.req, 0) != 0) return;
            input.open = true;
        }
        input.event = .{ .class = class };
        input.io.req.command = sdk.devices.input.IND_WRITEEVENT;
        input.io.length = @sizeOf(inputevent.InputEvent);
        input.io.data = @ptrCast(&input.event);
        _ = sb.DoIO(&input.io.req);
    }
};

/// The idle timer's request, opened on timer.device with a port of its
/// own. Without it the handler still works; it writes checkpoints only
/// when its journal or its changed nodes run full.
fn openClock(sb: *ExecBase, st: *State) void {
    const clock_port = sb.CreateMsgPort() orelse return;
    st.clock = .{ .node = .{ .message = .{ .reply_port = clock_port, .length = @sizeOf(timer.TimeRequest) } } };
    if (sb.OpenDevice(timer.TIMERNAME, timer.UNIT_VBLANK, &st.clock.node, 0) != 0) {
        sb.DeleteMsgPort(clock_port);
        return;
    }
    st.clock_port = clock_port;
    st.clock_open = true;
}

/// The idle timer started, unless it runs already: changes wait.
fn startClock(sb: *ExecBase, st: *State) void {
    if (!st.clock_open or st.clock_running) return;
    st.clock.node.command = timer.TR_ADDREQUEST;
    st.clock.time = timer.TimeVal.fromMicros(if (st.media.geometry.erase_size != 0) idle_flash_micros else idle_disk_micros);
    sb.SendIO(&st.clock.node);
    st.clock_running = true;
}

/// One packet. Before there is a file system, and while the drive is
/// inhibited, only the ones that say what the disk is, ACTION_INHIBIT,
/// ACTION_FORMAT and ACTION_POSFS_ROLLBACK get through - and, inhibited,
/// those that give a lock back.
fn serve(st: *State, pkt: *DosPacket) Answer {
    const action = pkt.getAction();
    switch (action) {
        .inhibit => return inhibit(st, pkt.args.raw[0] != dos.DOSFALSE),
        .format => return formatVolume(st, pkt),
        .die => return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_OBJECT_IN_USE }, // it stays, as RAM: does
        else => {},
    }
    if (pkt.action == posfs.packets.ACTION_POSFS_ROLLBACK) return rollback(st, pkt);
    // Locks and handles are given back whatever the drive holds - a lock
    // of a volume that has gone too - and a name may be watched before
    // its volume is in.
    switch (action) {
        .free_lock, .end, .free_record, .add_notify, .remove_notify => return st.fs.answer(pkt),
        else => {},
    }
    if (!st.mounted or st.inhibited != 0) {
        const medium_in = st.media.present();
        switch (action) {
            .disk_info, .info => {
                const data: ?*dos.InfoData = if (action == .disk_info)
                    @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[0])))
                else
                    pkt.args.info.info;
                const sector = st.media.geometry.sector_size;
                if (data) |d| d.* = .{
                    .disk_state = if (medium_in and !st.media.writable()) dos.ID_WRITE_PROTECTED else dos.ID_VALIDATED,
                    .num_blocks = if (medium_in and sector != 0) st.media.area_length / sector else 0,
                    .bytes_per_block = if (medium_in) sector else 0,
                    .disk_type = if (st.inhibited != 0)
                        dos.ID_BUSY_DISK
                    else if (medium_in)
                        dos.ID_NOT_REALLY_DOS
                    else
                        dos.ID_NO_DISK_PRESENT,
                    .unit_number = 0,
                };
                return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
            },
            .is_filesystem => return .{ .res1 = dos.DOSTRUE, .res2 = 0 },
            else => return .{ .res1 = dos.DOSFALSE, .res2 = if (medium_in) dos.ERROR_NOT_A_DOS_DISK else dos.ERROR_NO_DISK },
        }
    }
    const reply = st.fs.answer(pkt);
    // A rename keeps the node and gives it the name.
    if (action == .rename_disk and reply.res1 != dos.DOSFALSE) st.label.set(st.fs.volumeName());
    return reply;
}

/// ACTION_INHIBIT: on, every open file's changes committed, a checkpoint
/// written and the drive busy - refused with ERROR_OBJECT_IN_USE while a
/// file is open for writing, whose writes would have nowhere to go; off,
/// the drive in use again. They nest, and off on a drive that is not
/// inhibited does nothing.
fn inhibit(st: *State, on: bool) Answer {
    if (!on) {
        if (st.inhibited != 0) st.inhibited -= 1;
        return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
    }
    if (st.inhibited == 0 and st.mounted) {
        if (st.fs.writing()) return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_OBJECT_IN_USE };
        st.fs.flush() catch |err| return .{ .res1 = dos.DOSFALSE, .res2 = fs_core.codeOf(err) };
        st.fs.idle() catch |err| return .{ .res1 = dos.DOSFALSE, .res2 = fs_core.codeOf(err) };
    }
    st.inhibited += 1;
    return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
}

/// ACTION_POSFS_ROLLBACK: only with the volume mounted, the drive
/// inhibited and no lock or handle on it, else ERROR_OBJECT_IN_USE.
fn rollback(st: *State, pkt: *DosPacket) Answer {
    if (!st.mounted) return .{ .res1 = dos.DOSFALSE, .res2 = if (st.media.present()) dos.ERROR_NOT_A_DOS_DISK else dos.ERROR_NO_DISK };
    if (st.inhibited == 0 or st.fs.inUse()) return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_OBJECT_IN_USE };
    return st.fs.answer(pkt);
}

/// ACTION_FORMAT: a fresh volume over the area - on a `POS\1` drive in a
/// new partition, the table written after the volume - named as dp_Arg1
/// says (DEFAULT_LABEL without), its block size FORMAT_BlockSize from the
/// tags in dp_Arg3, or without one the partition's default. A block size
/// the medium cannot have is ERROR_INVALID_ARGUMENT. Only with nothing on
/// it in use - the drive inhibited or holding no
/// file system, and no lock or handle on the volume - else
/// ERROR_OBJECT_IN_USE; with no medium ERROR_NO_DISK, with one that will
/// not be written ERROR_DISK_WRITE_PROTECTED. A DosType in dp_Arg2 that is
/// not posfs's is ERROR_INVALID_ARGUMENT, and a name a volume cannot have
/// is refused before anything is written. The volume's node is made again
/// once the packet is answered.
fn formatVolume(st: *State, pkt: *DosPacket) Answer {
    if (st.mounted and (st.inhibited == 0 or st.fs.inUse())) return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_OBJECT_IN_USE };
    const given_type: u32 = @truncate(@as(usize, @bitCast(pkt.args.raw[1])));
    if (given_type != 0 and !posfs.isPosfsType(given_type)) return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_INVALID_ARGUMENT };
    if (!st.media.present()) return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_NO_DISK };
    if (!st.media.writable()) return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_DISK_WRITE_PROTECTED };
    const given: ?[*:0]const u8 = @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[0])));
    const name: []const u8 = if (given) |label| span(label) else DEFAULT_LABEL;
    const wanted: usize = if (st.ub) |ub| ub.GetTagData(dos.FORMAT_BlockSize, 0, pkt.args.format.tags) else 0;
    if (wanted > posfs.max_block_size) return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_INVALID_ARGUMENT };
    st.change_num = st.media.changeNum();
    if (!st.media.placeArea() or (st.media.table and !st.media.planTable())) {
        return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_NOT_A_DOS_DISK };
    }
    st.fs.format(.{ .name = name, .partition_block = st.partition_block, .block_size = @intCast(wanted) }) catch |err| {
        // Refused before a write, the volume is where it was; else what
        // was there may be gone, and the drive holds no volume now.
        st.mounted = st.fs.vol.mounted;
        if (st.mounted) {
            if (!st.media.place()) st.mounted = false;
        }
        if (!st.mounted) st.renew = true;
        return .{ .res1 = dos.DOSFALSE, .res2 = fs_core.codeOf(err) };
    };
    st.mounted = true;
    st.renew = true;
    if (st.media.table and !(st.media.writeTable() and st.media.update())) {
        return .{ .res1 = dos.DOSFALSE, .res2 = dos.ERROR_NOT_A_DOS_DISK };
    }
    return .{ .res1 = dos.DOSTRUE, .res2 = 0 };
}

/// The bytes of a C string from a packet.
fn span(text: [*:0]const u8) []const u8 {
    var len: usize = 0;
    while (text[len] != 0) len += 1;
    return text[0..len];
}

/// The volume node made again to match the file system, but only if the
/// device list can be had at once. A program holding it may be waiting
/// on this very handler for an answer - Info holds it while it asks every
/// device - so waiting for it would never end; the node is renewed after
/// a later packet instead.
fn renewVolume(dl: *DosBase, st: *State) void {
    const flags = dos.LDF_ALL | dos.LDF_ENTRY | dos.LDF_DELETE | dos.LDF_WRITE;
    _ = dl.AttemptLockDosList(flags) orelse return;
    defer dl.UnLockDosList(flags);
    partVolume(dl, st);
    if (st.mounted) addVolume(dl, st);
    sweepGone(dl, st);
    st.renew = false;
}

/// The volume's name as dos shows it: Latin-1, with `_` for what dos
/// cannot say yet.
fn nodeName(st: *State, into: *[posfs.max_volume_name + 1:0]u8) [*:0]const u8 {
    into.* = @splat(0);
    const label = st.fs.volumeName();
    var len: usize = 0;
    var at: usize = 0;
    while (at < label.len and len < posfs.max_volume_name) : (len += 1) {
        const code = posfs.fold.decode(label, &at) orelse {
            at += 1;
            into[len] = '_';
            continue;
        };
        into[len] = if (code <= 0xFF) @intCast(code) else '_';
    }
    return if (len == 0) DEFAULT_LABEL else into;
}

/// The volume on the device list, named as its volume table has it, so
/// `doslist` shows it and locks can point at it. A volume that comes back
/// takes up the node it had - its locks point at it, and work again - and
/// the node is given the name the volume has now. The caller holds the
/// list.
fn addVolume(dl: *DosBase, st: *State) void {
    var name: [posfs.max_volume_name + 1:0]u8 = undefined;
    const shown = nodeName(st, &name);
    const id = st.fs.vol.uuid;
    for (&st.gone) |*slot| {
        const entry = slot.node orelse continue;
        if (!sameId(&slot.id, &id)) continue;
        slot.* = .{};
        entry.task = st.fs.port;
        st.volume = entry;
        st.volume_id = id;
        st.fs.revive(entry);
        st.fs.volume_node = entry;
        if (!sameName(span(entry.name), span(shown))) st.label.set(span(shown));
        return;
    }
    const entry = dl.MakeDosEntry(shown, dos.DLT_VOLUME) orelse return;
    entry.misc.volume.disk_type = posfs.ID_POSFS_DISK;
    entry.misc.volume.volume_date = layout.stampOf(st.fs.vol.label.created);
    entry.task = st.fs.port;
    if (!dl.AddDosEntry(entry)) {
        dl.FreeDosEntry(entry);
        return;
    }
    st.volume = entry;
    st.volume_id = id;
    st.fs.volume_node = entry;
}

/// The volume node let go of: off the device list and freed when no lock
/// points at it, else kept on the list with no handler behind it - so the
/// locks still point at something dos can name, and the volume coming
/// back can take it up again. With no room left to remember it, it comes
/// off the list and is left allocated: memory lost is better than memory
/// freed under a lock. The caller holds the list.
fn partVolume(dl: *DosBase, st: *State) void {
    const entry = st.volume orelse return;
    st.volume = null;
    if (st.fs.volume_node == entry) st.fs.volume_node = null;
    if (st.fs.locksOn(entry) == 0) {
        if (dl.RemDosEntry(entry)) dl.FreeDosEntry(entry);
        return;
    }
    entry.task = null;
    for (&st.gone) |*slot| if (slot.node == null) {
        slot.* = .{ .node = entry, .id = st.volume_id };
        return;
    };
    _ = dl.RemDosEntry(entry);
}

/// The sweep, if the device list can be had at once. It never waits for
/// it: a program holding the list may be waiting on this handler for an
/// answer, and a node left a packet longer costs nothing.
fn sweepIfFree(dl: *DosBase, st: *State) void {
    for (st.gone) |slot| {
        if (slot.node != null) break;
    } else return;
    const flags = dos.LDF_ALL | dos.LDF_ENTRY | dos.LDF_DELETE | dos.LDF_WRITE;
    _ = dl.AttemptLockDosList(flags) orelse return;
    defer dl.UnLockDosList(flags);
    sweepGone(dl, st);
}

/// Kept volume nodes no lock points at any more, taken off the device
/// list and freed. The caller holds the list.
fn sweepGone(dl: *DosBase, st: *State) void {
    for (&st.gone) |*slot| {
        const entry = slot.node orelse continue;
        if (st.fs.locksOn(entry) != 0) continue;
        if (!dl.RemDosEntry(entry)) continue;
        dl.FreeDosEntry(entry);
        slot.* = .{};
    }
}

fn sameId(one: *const [16]u8, other: *const [16]u8) bool {
    for (one, other) |a, b| {
        if (a != b) return false;
    }
    return true;
}

fn sameName(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |a, b| {
        if (a != b) return false;
    }
    return true;
}

/// It is in `.resident`, which program.ld KEEPs: nothing in the file
/// refers to the tag, dos finds it by looking.
export const posfs_handler_tag: exec.ResidentHandler linksection(".resident") = .{
    .resident = .{
        .match_tag = &posfs_handler_tag.resident,
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

/// The "$VER:" string, which `Version <file>` looks for. Nothing refers to
/// it, so it needs an export and a section of its own that program.ld
/// KEEPs.
const version_tag: [HANDLER_VERSION_STRING.len:0]u8 linksection(".version") = HANDLER_VERSION_STRING.*;

// The file's entry and its version string, under the names the loader and
// `Version` look for. The host tests build this file beside fat-handler,
// whose names are the same, so there they are left out.
comptime {
    if (!builtin.is_test) {
        @export(&programEntry, .{ .name = "_program_entry" });
        @export(&version_tag, .{ .name = "version_tag" });
    }
}

const testing = std.testing;

test "the handler's tag names the handler and its entry" {
    try testing.expectEqual(exec.NodeType.handler, posfs_handler_tag.resident.type);
    try testing.expectEqualStrings(HANDLER_NAME, std.mem.span(posfs_handler_tag.resident.name));
    try testing.expectEqual(@as(?exec.TaskFn, &fsHandler), posfs_handler_tag.handler);
}
