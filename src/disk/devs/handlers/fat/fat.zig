// SPDX-License-Identifier: MIT
//! fat-handler: FAT32 and exFAT on a card, as a handler on the disk -
//! `HANDLERS:fat-handler`, which dos loads the first time the device is
//! used and keeps in the device node from then on. The mountlist gives it
//! a whole device - sdcard.device's unit 0 - and it finds the volume on it
//! itself: the card's first block is the volume's boot sector, or a
//! partition table with the volume in one of its partitions, which is how
//! cards are sold.
//!
//! The file systems are `fat32/fs.zig` and `exfat/fs.zig`, generic over
//! the medium and tested on the host. This file is what the machine needs:
//! the handler's tag, the process, the medium made out of the device, and
//! the choice between the two. The tag has the shape a handler in the ROM
//! has; dos finds it in the loaded file and starts the process at its
//! entry.
//!
//! **One handler, two bodies.** Which format a card is is known only once
//! its first blocks are read, so the handler keeps both file systems and
//! offers every card to each: the one whose format it is mounts it. They
//! are kept side by side, not swapped, because locks on a card that has
//! gone belong to the body that made them and are freed there - FREE_LOCK
//! and END go to the body that holds the lock, everything else to the one
//! with a volume.
//!
//! **A card comes and goes.** Before each packet the handler asks the
//! device whether its card has changed. If it has, whatever it held of the
//! old one is dropped unwritten, the locks on it stop being any good, and
//! the new card is mounted - so the volume node is put where the new
//! card's name says, as soon as the list can be had without waiting
//! (`renewVolume`). A handler nobody asks anything hears of a change by
//! its change interrupt (TD_ADDCHANGEINT), which the device causes when a
//! card goes in or out: it looks at once, and then tells input
//! (IECLASS_DISKINSERTED, IECLASS_DISKREMOVED), so a window showing the
//! device list looks again and finds the volume already where the card
//! says. A device whose medium stays answers TD_ADDCHANGEINT with an
//! error, and is only asked before each packet. A handler started with no card, or with a card it
//! cannot read, stays and answers ERROR_NO_DISK or ERROR_NOT_A_DOS_DISK
//! until there is one.
//!
//! A volume that goes while locks are held on it keeps its node on the
//! device list with no handler behind it, which is what dos calls not
//! mounted: the locks still point at something dos can name, so it can
//! ask for that card back by name, and the card coming back takes the
//! node up again and makes those locks work. The node is taken off the
//! list and freed once no lock points at it.
//!
//! **Notification** has one set of watchers for both bodies, so a watch
//! outlives a card: a card going lets go of every watch's object, and the
//! next one mounted - the same card back, or another with the volume's
//! name - finds each watch's name again on it and tells its watcher. A
//! watch named on the device (`SD0:x`) is on whichever card is in.
//!
//! **Record locks** are one table for both bodies too, kept with the
//! handler: a range is held through a handle, so it belongs to the body
//! that holds the handle's lock, and goes when the handle is closed. A
//! lock that waits keeps its packet unanswered, with a timer that comes
//! back on a port the process waits on beside its packets.
//!
//! **The order of the writes.** A card can go - pulled out, the power
//! cut - between any two blocks, and the handler writes so that what is
//! left is a volume with something lost at worst, never something wrong.
//! What a change takes goes down before what names it: a file's bytes,
//! then its clusters in the table (and on exFAT the bitmap), then the
//! entry that counts on them; a directory's new cluster is cleared before
//! it is linked on. What a change gives back goes the other way: the entry
//! first, then the clusters. Freed first, a cut would leave an entry
//! naming clusters marked free, which the next file is given too - two
//! files on the same bytes. In this order a cut leaves clusters nothing
//! names, which a check gives back, or after a rename the object under
//! both names. The volume is marked dirty before the first change and
//! clean once nothing is half done, so a check knows when to look.
//!
//! **The device's own cache.** A USB stick may hold writes in memory of
//! its own and put them down later, in an order of its own. So CMD_UPDATE
//! goes to the device when a file is closed, on FLUSH, after the dirty
//! mark and before the clean one: usb/disk.device passes it on as
//! SYNCHRONIZE CACHE, and from there on what went before is on the medium
//! itself. Between two of them the order above is the order the device
//! is given. It is sent only when something was written since the last
//! one; sdcard.device holds nothing and answers at once.
//!
//! **Buffers** are the blocks the cache holds - the table and directory
//! blocks a packet goes back to, never a file's bytes. There is one count
//! for the handler, not one per card: the mountlist's `Buffers` gives it
//! (32 without), ACTION_MORE_CACHE (`C:AddBuffers`) changes it, and the
//! card in the slot has its cache made that size at once, the next one
//! from the start.
//!
//! **A device it cannot open** - no slot, no controller - is another
//! matter: there will never be a card. The start then gives back what it
//! took, answers ERROR_DEVICE_NOT_MOUNTED and ends, and dos unloads the
//! handler's code.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const trackdisk = sdk.devices.trackdisk;
const inputevent = sdk.devices.inputevent;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const DosPacket = dos.DosPacket;
const Process = dos.Process;
const MsgPort = exec.MsgPort;
const _fat = @import("_fat.zig");
const fat32_fs = @import("fat32/fs.zig");
const exfat_fs = @import("exfat/fs.zig");
const cache_area = @import("cache.zig");

pub const HANDLER_NAME = "fat-handler";
const HANDLER_VERSION = 1;
const HANDLER_REVISION = 8;
const BUILD_DATE = "17.10.2026";
const HANDLER_VERSION_STRING =
    "\x00$VER: " ++ HANDLER_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ HANDLER_VERSION, HANDLER_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const UTILITY_VERSION = 1;

/// The medium: the device the startup message names, counted in its own
/// blocks. What it answers about the card - its size, whether it is in,
/// whether it may be written - it asks the device each time, because
/// the card is not always the same one.
pub const DeviceMedia = struct {
    sys: *ExecBase,
    dl: *DosBase,
    /// The request every command goes out on.
    io: *exec.IOStdReq,
    geometry: trackdisk.DriveGeometry = .{},
    /// The change count the geometry was read at.
    geometry_change: ?u32 = null,
    /// Written to since the device was last told to put what it holds on
    /// the medium itself.
    unsynced: bool = false,

    fn command(media: *DeviceMedia, what: u16, offset: u64, length: u64, data: ?*anyopaque) bool {
        media.io.req.command = what;
        media.io.offset = offset;
        media.io.length = length;
        media.io.data = data;
        media.io.actual = 0;
        return media.sys.DoIO(&media.io.req) == 0;
    }

    /// The card's geometry, read again when a different card is in.
    fn geometryNow(media: *DeviceMedia) *const trackdisk.DriveGeometry {
        const change = media.changeNum();
        if (media.geometry_change != change) {
            media.geometry = .{};
            if (media.command(trackdisk.TD_GETGEOMETRY, 0, @sizeOf(trackdisk.DriveGeometry), &media.geometry)) {
                media.geometry_change = change;
            }
        }
        return &media.geometry;
    }

    pub fn blockSize(media: *DeviceMedia) u32 {
        const size = media.geometryNow().sector_size;
        return if (size == 0) 512 else size;
    }

    pub fn blocks(media: *DeviceMedia) u64 {
        return media.geometryNow().total_sectors;
    }

    pub fn read(media: *DeviceMedia, lba: u64, count: u32, into: []u8) bool {
        const bytes = @as(u64, count) * media.blockSize();
        if (into.len < bytes) return false;
        return media.command(exec.CMD_READ, lba * media.blockSize(), bytes, into.ptr);
    }

    pub fn write(media: *DeviceMedia, lba: u64, count: u32, from: []const u8) bool {
        const bytes = @as(u64, count) * media.blockSize();
        if (from.len < bytes) return false;
        media.unsynced = true;
        return media.command(exec.CMD_WRITE, lba * media.blockSize(), bytes, @constCast(from.ptr));
    }

    /// What the device holds in a cache of its own put on the medium
    /// itself (CMD_UPDATE). Not asked when nothing has been written since
    /// the last time.
    pub fn update(media: *DeviceMedia) bool {
        if (!media.unsynced) return true;
        if (!media.command(exec.CMD_UPDATE, 0, 0, null)) return false;
        media.unsynced = false;
        return true;
    }

    pub fn writable(media: *DeviceMedia) bool {
        return media.command(trackdisk.TD_PROTSTATUS, 0, 0, null) and media.io.actual == 0;
    }

    /// Whether a card is in. On an empty slot this is what makes the
    /// device look for one.
    pub fn present(media: *DeviceMedia) bool {
        return media.command(trackdisk.TD_CHANGESTATE, 0, 0, null) and media.io.actual == 0;
    }

    pub fn changeNum(media: *DeviceMedia) u32 {
        _ = media.command(trackdisk.TD_CHANGENUM, 0, 0, null);
        return @truncate(media.io.actual);
    }

    /// Eight-byte aligned, as AllocVec's are: the file system keeps
    /// structures with 64-bit fields in these.
    pub fn alloc(media: *DeviceMedia, bytes_wanted: u32) ?[]u8 {
        const block = media.sys.AllocVec(bytes_wanted, exec.MEMF_CLEAR) orelse return null;
        const bytes: [*]u8 = @ptrCast(block);
        return bytes[0..bytes_wanted];
    }

    pub fn free(media: *DeviceMedia, block: []u8) void {
        media.sys.FreeVec(block.ptr);
    }

    /// The zone the system clock keeps: the rule in the zone file, the
    /// one C:net/TimeSync sets the clock by. UTC with no file, or with one
    /// that holds no rule.
    pub fn timeZone(media: *DeviceMedia) dos.timezone.Zone {
        const file = media.dl.Open(dos.timezone.zone_file, dos.MODE_OLDFILE) orelse return .{};
        defer _ = media.dl.Close(file);
        var text: [256]u8 = undefined;
        const got = media.dl.Read(file, &text, text.len);
        if (got <= 0) return .{};
        var rest: []const u8 = text[0..@intCast(got)];
        while (rest.len > 0) {
            var end: usize = 0;
            while (end < rest.len and rest[end] != '\n') end += 1;
            var line = rest[0..end];
            rest = if (end < rest.len) rest[end + 1 ..] else rest[rest.len..];
            while (line.len > 0 and (line[line.len - 1] == '\r' or line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) line = line[0 .. line.len - 1];
            while (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) line = line[1..];
            if (line.len == 0 or line[0] == '#') continue;
            return dos.timezone.parse(line) orelse .{};
        }
        return .{};
    }

    pub fn now(media: *DeviceMedia) dos.DateStamp {
        var stamp: dos.DateStamp = .{};
        _ = media.dl.DateStamp(&stamp);
        return stamp;
    }
};

const Fat32 = fat32_fs.FileSystem(DeviceMedia);
const Exfat = exfat_fs.FileSystem(DeviceMedia);

/// The two file systems, and which of them has the card's volume.
const Bodies = struct {
    fat32: Fat32,
    exfat: Exfat,

    const Which = enum { fat32, exfat };

    fn init(media: *DeviceMedia, ub: *UtilityBase, port: *MsgPort) Bodies {
        return .{ .fat32 = Fat32.init(media, ub, port), .exfat = Exfat.init(media, ub, port) };
    }

    /// The card offered to each; the one whose format it is mounts it.
    fn mount(bodies: *Bodies) void {
        bodies.fat32.mount() catch {};
        if (!bodies.fat32.mounted) bodies.exfat.mount() catch {};
    }

    /// Whether the card changed; each body lets go of what it held of the
    /// old one and tries the new one.
    fn checkMedium(bodies: *Bodies) bool {
        const one = bodies.fat32.checkMedium();
        const other = bodies.exfat.checkMedium();
        return one or other;
    }

    /// The body with a volume, if either has one.
    fn active(bodies: *Bodies) ?Which {
        if (bodies.fat32.mounted) return .fat32;
        if (bodies.exfat.mounted) return .exfat;
        return null;
    }

    /// The body a packet goes to: for FREE_LOCK and END, the one holding
    /// the lock, which may be a card that has gone; otherwise the one with
    /// a volume.
    fn bodyFor(bodies: *Bodies, pkt: *DosPacket) ?Which {
        const lock: usize = switch (pkt.getAction()) {
            .free_lock => @bitCast(pkt.args.raw[0]),
            .end => if (pkt.args.file.fh) |fh| @intFromPtr(fh.key) else 0,
            .lock_record => if (pkt.args.lock_record.fh) |fh| @intFromPtr(fh.key) else 0,
            .free_record => if (pkt.args.free_record.fh) |fh| @intFromPtr(fh.key) else 0,
            else => 0,
        };
        if (lock != 0) {
            if (bodies.fat32.holdsLock(lock)) return .fat32;
            if (bodies.exfat.holdsLock(lock)) return .exfat;
        }
        return bodies.active();
    }

    /// The blocks the cache holds, the same for both bodies.
    fn buffers(bodies: *const Bodies) u32 {
        if (bodies.exfat.mounted) return bodies.exfat.buffers;
        return bodies.fat32.buffers;
    }

    /// Both bodies' caches made `count` blocks: the one with a volume
    /// first, as only that one can fail, and then nothing has changed.
    fn setBuffers(bodies: *Bodies, count: u32) _fat.Error!void {
        if (bodies.active() == .exfat) {
            try bodies.exfat.setBuffers(count);
            try bodies.fat32.setBuffers(count);
        } else {
            try bodies.fat32.setBuffers(count);
            try bodies.exfat.setBuffers(count);
        }
    }

    fn volumeName(bodies: *Bodies) []const u8 {
        return switch (bodies.active() orelse return "") {
            .fat32 => bodies.fat32.volumeName(),
            .exfat => bodies.exfat.volumeName(),
        };
    }

    fn locksOn(bodies: *Bodies, node: *dos.DosList) u32 {
        return bodies.fat32.locksOn(node) + bodies.exfat.locksOn(node);
    }

    fn setVolumeNode(bodies: *Bodies, node: ?*dos.DosList) void {
        bodies.fat32.volume_node = if (bodies.active() == .fat32) node else null;
        bodies.exfat.volume_node = if (bodies.active() == .exfat) node else null;
    }

    /// One set of watchers for both: a watch stays while cards come and
    /// go, and the device's name, which a watch may be named on.
    fn watch(bodies: *Bodies, watchers: *dos.notify.Watchers, device: []const u8) void {
        bodies.fat32.watchers = watchers;
        bodies.exfat.watchers = watchers;
        bodies.fat32.device_name = device;
        bodies.exfat.device_name = device;
    }

    /// One table of record locks for both: a range is held through a
    /// handle, and stays with the body that holds the handle's lock.
    fn keepRecords(bodies: *Bodies, records: *dos.record.Records) void {
        bodies.fat32.records = records;
        bodies.exfat.records = records;
    }
};

/// Everything the process keeps, in one allocation.
const State = struct {
    ub: *UtilityBase,
    media: DeviceMedia,
    bodies: Bodies,
    io: exec.IOStdReq,
    /// The volume node, while a volume is mounted.
    volume: ?*dos.DosList = null,
    /// The volume node is behind the card: renew it when the device list
    /// can be had.
    renew: bool = false,
    /// Volume nodes whose card has gone that locks still point at: left
    /// on the device list with no handler behind them, which is what dos
    /// calls not mounted. They stay there so that a lock still points at
    /// something dos can name - that is what lets it ask for the card
    /// back - and so that the card coming back can take its node up
    /// again and make those locks work. One is freed once no lock points
    /// at it.
    gone: [8]?*dos.DosList = @splat(null),
    /// The volume's name after ACTION_RENAME_DISK, for its node.
    label: dos.volumename.VolumeName = .{},
    /// Who watches what, when there was memory for its port.
    watchers: dos.notify.Watchers = undefined,
    watching: bool = false,
    /// The record locks; without a port for their timers it holds none
    /// and gives no signal.
    records: dos.record.Records = undefined,
    /// The change interrupt the device causes when the card comes or
    /// goes, the request it is kept with and that request's port, and the
    /// signal it gives the process; no signal (0) when the device has
    /// none to give.
    change_int: exec.Interrupt = .{},
    change_io: exec.IOStdReq = .{},
    change_port: ?*MsgPort = null,
    change_mask: u32 = 0,
    process: ?*exec.Task = null,
    /// input.device, for telling it a disk came or went.
    input: Input = .{},
};

/// Its change interrupt: the process signalled, to look at the card on
/// its own time.
fn changeInterrupt(is_data: ?*anyopaque) callconv(.c) void {
    const st: *State = @ptrCast(@alignCast(is_data.?));
    st.media.sys.Signal(st.process.?, st.change_mask);
}

/// The change interrupt given to the device, on a request and a port of
/// its own: the device keeps it until the handler ends. A device that
/// does not take it (a medium that stays) answers at once, and then the
/// handler only asks before each packet.
fn listenForChanges(sys: *ExecBase, st: *State, process: *exec.Task) void {
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return;
    const port = sys.CreateMsgPort() orelse {
        sys.FreeSignal(signal);
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
    sys.SendIO(&st.change_io.req);
    if (sys.CheckIO(&st.change_io.req) != null) {
        _ = sys.WaitIO(&st.change_io.req);
        sys.DeleteMsgPort(port);
        sys.FreeSignal(signal);
        st.change_mask = 0;
        return;
    }
    st.change_port = port;
}

/// The device said its card came or went: looked at now - nobody may be
/// asking anything - the volume node renewed, and input told.
fn mediumChanged(sys: *ExecBase, dl: *DosBase, st: *State, port: *MsgPort) void {
    if (st.bodies.checkMedium()) st.renew = true;
    renewSoon(dl, st, port);
    const class = if (st.media.present()) inputevent.IECLASS_DISKINSERTED else inputevent.IECLASS_DISKREMOVED;
    st.input.announce(sys, class);
}

/// `renewVolume` until it has had the list: another handler starting or
/// renewing beside this one may hold it for a moment, so a try that fails
/// is made again a tick later - a few times, and after that the next
/// packet does it.
fn renewSoon(dl: *DosBase, st: *State, port: *MsgPort) void {
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        renewVolume(dl, st, port);
        if (!st.renew or tries == renew_tries) break;
        dl.Delay(1);
    }
}

/// input.device, opened the first time a disk is announced, and kept.
const Input = struct {
    port: ?*MsgPort = null,
    io: exec.IOStdReq = .{},
    open: bool = false,
    event: inputevent.InputEvent = .{},

    fn announce(input: *Input, sys: *ExecBase, class: u32) void {
        if (!input.open) {
            const port = input.port orelse sys.CreateMsgPort() orelse return;
            input.port = port;
            input.io = .{};
            input.io.req.message.reply_port = port;
            input.io.req.message.length = @sizeOf(exec.IOStdReq);
            if (sys.OpenDevice(sdk.devices.input.INPUTNAME, 0, &input.io.req, 0) != 0) return;
            input.open = true;
        }
        input.event = .{ .class = class };
        input.io.req.command = sdk.devices.input.IND_WRITEEVENT;
        input.io.length = @sizeOf(inputevent.InputEvent);
        input.io.data = @ptrCast(&input.event);
        _ = sys.DoIO(&input.io.req);
    }
};

/// How often the volume node is tried for, a tick apart, before the next
/// packet is left to do it.
const renew_tries = 25;

/// The handler process: ACTION_STARTUP (the device from the startup
/// message, the volume if there is one), then packets for good.
pub fn fsHandler(sys: *ExecBase) callconv(.c) void {
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    const startup = dl.WaitPkt() orelse return;
    if (startup.getAction() != .startup) {
        dl.ReplyPkt(startup, dos.DOSFALSE, dos.ERROR_ACTION_NOT_KNOWN);
        return;
    }
    const me: *Process = @fieldParentPtr("task", sys.FindTask(null).?);
    const fssm: ?*const dos.FileSysStartupMsg = @ptrFromInt(@as(usize, @bitCast(startup.args.raw[1])));
    const node: ?*dos.DosList = @ptrFromInt(@as(usize, @bitCast(startup.args.raw[2])));

    // What a start that fails took is given back before it says so, and
    // the process ends: dos then unloads the handler's code, and the
    // device - which the device's own init refused, on a machine without
    // a slot - has nothing of it left open either.
    var code: i32 = 0;
    const st = start(sys, dl, fssm, &code) orelse return dl.ReplyPkt(startup, dos.DOSFALSE, code);

    st.bodies = Bodies.init(&st.media, st.ub, &me.msg_port);
    // The mountlist's Buffers, when it gives any; before a card is
    // mounted, so this cannot fail.
    if (fssm) |startup_msg| if (startup_msg.environ) |env| {
        if (env.table_size >= dos.filehandler.DE_NUMBUFFERS and env.num_buffers != 0)
            st.bodies.setBuffers(bounded(env.num_buffers)) catch {};
    };
    if (st.watchers.init(sys)) {
        st.watching = true;
        const device: []const u8 = if (node) |device_node| std.mem.span(device_node.name) else "";
        st.bodies.watch(&st.watchers, device);
    }
    if (st.records.init(sys, dl)) st.bodies.keepRecords(&st.records);
    // A card that is not there or not readable is not an error: the
    // handler stays for the one that will be.
    st.bodies.mount();
    // The volume on the list before the startup is answered, so it is
    // there before anyone asks.
    st.renew = true;
    renewSoon(dl, st, &me.msg_port);
    listenForChanges(sys, st, &me.task);
    if (node) |device_node| device_node.task = &me.msg_port;
    dl.ReplyPkt(startup, dos.DOSTRUE, 0);

    // Packets on the process's port; the watchers' replies and the record
    // locks' timers on theirs.
    const packets = &me.msg_port;
    const replies: u32 = (if (st.watching) st.watchers.signals() else 0) | st.records.signals();
    while (true) {
        if (st.watching) st.watchers.collect();
        st.records.collect();
        while (sys.GetMsg(packets)) |message| handle(dl, st, DosPacket.fromMessage(message), packets);
        const got = sys.Wait(packets.sigMask() | replies | st.change_mask);
        if (got & st.change_mask != 0) mediumChanged(sys, dl, st, packets);
    }
}

/// One packet: the card checked first, the packet served - asked about
/// again while the user says to retry - and answered.
fn handle(dl: *DosBase, st: *State, pkt: *DosPacket, port: *MsgPort) void {
    if (st.bodies.checkMedium()) st.renew = true;
    if (st.renew) renewVolume(dl, st, port);
    var reply = serve(st, pkt);
    // A mounted volume that suddenly cannot be read is a read or
    // write error, not a card that is missing or unformatted: the
    // user is asked, and the packet served again if they say to.
    // Nothing is asked when there is no volume to name - an empty
    // slot and a card this handler cannot read both answer the same
    // way, and neither is worth a question.
    while (reply.res2 == dos.ERROR_NOT_A_DOS_DISK and st.volume != null) {
        const volume = st.volume.?;
        if (dl.ErrorReport(dos.ABORT_DISK_ERROR, dos.REPORT_VOLUME, @intFromPtr(volume), null)) break;
        if (st.bodies.checkMedium()) {
            st.renew = true;
            break;
        }
        reply = serve(st, pkt);
    }
    sweepIfFree(dl, st);
    // A rename keeps the node, which locks point at, and gives it the
    // name once the packet is answered.
    const renamed = pkt.getAction() == .rename_disk and reply.res1 != dos.DOSFALSE;
    if (!reply.held) dl.ReplyPkt(pkt, reply.res1, reply.res2);
    if (renamed) st.label.set(st.bodies.volumeName());
    st.label.apply(dl, st.volume);
}

/// What the handler runs on: utility.library, a port, its state and the
/// device the startup message names. Null, with the dos error in `code`,
/// when any of it cannot be had - and then whatever was had is given
/// back first.
fn start(sys: *ExecBase, dl: *DosBase, fssm: ?*const dos.FileSysStartupMsg, code: *i32) ?*State {
    const utility = sys.OpenLibrary(sdk.interface.utility.NAME, UTILITY_VERSION) orelse {
        code.* = dos.ERROR_INVALID_RESIDENT_LIBRARY;
        return null;
    };
    const port = sys.CreateMsgPort() orelse {
        sys.CloseLibrary(utility);
        code.* = dos.ERROR_NO_FREE_STORE;
        return null;
    };
    const block = sys.AllocVec(@sizeOf(State), exec.MEMF_CLEAR) orelse {
        sys.DeleteMsgPort(port);
        sys.CloseLibrary(utility);
        code.* = dos.ERROR_NO_FREE_STORE;
        return null;
    };
    const st: *State = @ptrCast(@alignCast(block));
    st.ub = @ptrCast(utility);
    st.io = .{ .req = .{ .message = .{ .reply_port = port, .length = @sizeOf(exec.IOStdReq) } } };
    st.media = .{ .sys = sys, .dl = dl, .io = &st.io };

    const device = if (fssm) |startup_msg| startup_msg.device orelse "" else "";
    const unit = if (fssm) |startup_msg| startup_msg.unit else 0;
    if (device[0] == 0 or sys.OpenDevice(device, unit, &st.io.req, 0) != 0) {
        sys.FreeVec(block);
        sys.DeleteMsgPort(port);
        sys.CloseLibrary(utility);
        code.* = dos.ERROR_DEVICE_NOT_MOUNTED;
        return null;
    }
    return st;
}

/// One packet, to the body it is for. Without a volume only the ones that
/// say what is in the slot get an answer that is not an error.
fn serve(st: *State, pkt: *DosPacket) _fat.Answer {
    if (pkt.getAction() == .more_cache) return moreCache(st, pkt.args.raw[0]);
    if (st.bodies.bodyFor(pkt)) |which| return switch (which) {
        .fat32 => st.bodies.fat32.answer(pkt),
        .exfat => st.bodies.exfat.answer(pkt),
    };
    const action = pkt.getAction();
    const card_in = st.media.present();
    switch (action) {
        .disk_info, .info => {
            const data: ?*dos.InfoData = if (action == .disk_info)
                @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[0])))
            else
                pkt.args.info.info;
            if (data) |into| into.* = .{
                .disk_state = dos.ID_VALIDATED,
                .disk_type = if (card_in) dos.ID_NOT_REALLY_DOS else dos.ID_NO_DISK_PRESENT,
            };
            return _fat.yes();
        },
        .is_filesystem => return _fat.yes(),
        .die => return _fat.no(dos.ERROR_OBJECT_IN_USE),
        // A name watched with no volume waits for the card that has it.
        .add_notify => {
            const request: ?*dos.notify.NotifyRequest = @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[0])));
            const watched = request orelse return _fat.no(dos.ERROR_OBJECT_NOT_FOUND);
            if (!st.watching or !st.watchers.add(watched, null)) return _fat.no(dos.ERROR_NO_FREE_STORE);
            return _fat.yes();
        },
        .remove_notify => {
            const request: ?*dos.notify.NotifyRequest = @ptrFromInt(@as(usize, @bitCast(pkt.args.raw[0])));
            if (request) |watched| if (st.watching) {
                _ = st.watchers.remove(watched);
            };
            return _fat.yes();
        },
        else => return _fat.no(if (card_in) dos.ERROR_NOT_A_DOS_DISK else dos.ERROR_NO_DISK),
    }
}

/// ACTION_MORE_CACHE: `more` blocks added to the cache, or taken away
/// when it is negative - never below `least_blocks` - and none to ask how
/// many it holds. The answer is that number after it; when the memory for
/// a larger cache is not there, ERROR_NO_FREE_STORE, and the cache stays
/// as it was. Taking blocks away writes back the changed ones that go.
fn moreCache(st: *State, more: isize) _fat.Answer {
    const wanted = bounded(@as(i64, st.bodies.buffers()) + more);
    st.bodies.setBuffers(wanted) catch |e| return _fat.no(_fat.codeOf(e));
    return .{ .res1 = @intCast(st.bodies.buffers()), .res2 = 0 };
}

/// A count of buffers as the handler keeps it: `least_blocks` at the
/// least, and no more than the answer's `res1` can say.
fn bounded(count: i64) u32 {
    if (count < cache_area.least_blocks) return cache_area.least_blocks;
    if (count > std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(count);
}

/// The volume node made to match the card the bodies now have: the old
/// one taken off the device list and a new one put on - but only if the
/// list can be had at once. A program holding it may be waiting on this
/// very handler for an answer - Info holds it while it asks every device
/// - so waiting for it would never end; the node is renewed at a later
/// packet instead.
///
/// Taking a node off the list (RemDosEntry) needs the entry and delete
/// locks besides the list; putting one on needs the list alone. Only
/// what this renewal does is asked for: dos holds the entry lock while
/// it starts the handler, so at ACTION_STARTUP - nothing to take off yet
/// - the card's volume goes on the list at once, before anyone asks.
fn renewVolume(dl: *DosBase, st: *State, port: *MsgPort) void {
    const takes_off = st.volume != null or anyGone(st);
    const flags = if (takes_off)
        dos.LDF_ALL | dos.LDF_ENTRY | dos.LDF_DELETE | dos.LDF_WRITE
    else
        dos.LDF_ALL | dos.LDF_WRITE;
    _ = dl.AttemptLockDosList(flags) orelse return;
    defer dl.UnLockDosList(flags);
    partVolume(dl, st);
    if (st.bodies.active() != null) addVolume(dl, st, port);
    sweepGone(dl, st);
    st.renew = false;
}

/// The volume on the device list under the card's name, so locks can
/// point at it.
///
/// A card with the name of a volume that went while locks were held on
/// it takes that volume's node up again rather than getting one of its
/// own: the locks point at that node, and this is what makes them work
/// again. The name is what says it is the same volume - a card with no
/// label is named by its serial, so two blank cards are still two names.
fn addVolume(dl: *DosBase, st: *State, port: *MsgPort) void {
    var name: [24:0]u8 = @splat(0);
    const label = st.bodies.volumeName();
    for (&st.gone) |*slot| {
        const entry = slot.* orelse continue;
        if (!_fat.same(st.ub, std.mem.span(entry.name), label)) continue;
        entry.task = port;
        slot.* = null;
        st.volume = entry;
        st.bodies.setVolumeNode(entry);
        return;
    }
    @memcpy(name[0..label.len], label);
    const entry = dl.MakeDosEntry(&name, dos.DLT_VOLUME) orelse return;
    entry.misc.volume.disk_type = dos.ID_MSDOS_DISK;
    entry.task = port;
    if (!dl.AddDosEntry(entry)) {
        dl.FreeDosEntry(entry);
        return;
    }
    st.volume = entry;
    st.bodies.setVolumeNode(entry);
}

/// The card behind the volume has gone. With no lock on it the node
/// goes off the device list and is freed; with locks on it the node
/// stays on the list with no handler behind it - not mounted - so that
/// the locks still point at something dos can name and the card coming
/// back can take it up again. With no room left to remember it, it comes
/// off the list and is left allocated: memory lost is better than memory
/// freed under a lock. The caller holds the list (`renewVolume`).
fn partVolume(dl: *DosBase, st: *State) void {
    const entry = st.volume orelse return;
    st.volume = null;
    st.bodies.setVolumeNode(null);
    if (st.bodies.locksOn(entry) == 0) {
        if (dl.RemDosEntry(entry)) dl.FreeDosEntry(entry);
        return;
    }
    entry.task = null;
    for (&st.gone) |*slot| if (slot.* == null) {
        slot.* = entry;
        return;
    };
    _ = dl.RemDosEntry(entry);
}

/// The sweep, if the device list can be had at once. It never waits for
/// it: a program holding the list may be waiting on this handler for an
/// answer, and a node left a packet longer costs nothing.
fn sweepIfFree(dl: *DosBase, st: *State) void {
    if (!anyGone(st)) return;
    const flags = dos.LDF_ALL | dos.LDF_ENTRY | dos.LDF_DELETE | dos.LDF_WRITE;
    _ = dl.AttemptLockDosList(flags) orelse return;
    defer dl.UnLockDosList(flags);
    sweepGone(dl, st);
}

/// Whether volume nodes whose card has gone are still on the list.
fn anyGone(st: *const State) bool {
    for (st.gone) |slot| if (slot != null) return true;
    return false;
}

/// Volume nodes no lock points at any more, taken off the device list
/// and freed. The caller holds the list.
fn sweepGone(dl: *DosBase, st: *State) void {
    for (&st.gone) |*slot| {
        const entry = slot.* orelse continue;
        if (st.bodies.locksOn(entry) != 0) continue;
        if (!dl.RemDosEntry(entry)) continue;
        dl.FreeDosEntry(entry);
        slot.* = null;
    }
}

/// It is in `.resident`, which program.ld KEEPs: nothing in the file
/// refers to the tag, dos finds it by looking.
export const fat_handler_tag: exec.ResidentHandler linksection(".resident") = .{
    .resident = .{
        .match_tag = &fat_handler_tag.resident,
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
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    sdk.exec.kprintf(sys, "%s is a handler, not a command\n", .{HANDLER_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for. Nothing refers to
/// it, so it needs an export and a section of its own that program.ld
/// KEEPs.
export const version_tag: [HANDLER_VERSION_STRING.len:0]u8 linksection(".version") = HANDLER_VERSION_STRING.*;

const testing = std.testing;

test "the handler's tag names the handler and its entry" {
    try testing.expectEqual(exec.NodeType.handler, fat_handler_tag.resident.type);
    try testing.expectEqualStrings(HANDLER_NAME, std.mem.span(fat_handler_tag.resident.name));
    try testing.expectEqual(@as(?exec.TaskFn, &fsHandler), fat_handler_tag.handler);
}
