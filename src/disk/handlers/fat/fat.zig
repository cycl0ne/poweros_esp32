// SPDX-License-Identifier: MIT
//! fat-handler: FAT32 on a card, as a handler on the disk -
//! `HANDLERS:fat-handler`, which dos loads the first time the device is
//! used and keeps in the device node from then on. The mountlist gives it
//! a whole device - sd.device's unit 0 - and it finds the volume on it
//! itself: the card's first block is the volume's boot sector, or a
//! partition table with the volume in one of its partitions, which is how
//! cards are sold.
//!
//! The file system is `fat32/fs.zig`, generic over the medium and tested
//! on the host. This file is what the machine needs: the handler's tag,
//! the process, and the medium made out of the device. The tag has the
//! shape a handler in the ROM has; dos finds it in the loaded file and
//! starts the process at its entry.
//!
//! **A card comes and goes.** Before each packet the handler asks the
//! device whether its card has changed. If it has, whatever it held of the
//! old one is dropped unwritten, the locks on it stop being any good, and
//! the new card is mounted - so the volume node is taken off the device
//! list and a new one put there, with the new card's name. A handler
//! started with no card, or with a card it cannot read, stays and answers
//! ERROR_NO_DISK or ERROR_NOT_A_DOS_DISK until there is one.
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
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const DosPacket = dos.DosPacket;
const Process = dos.Process;
const MsgPort = exec.MsgPort;
const _fat = @import("_fat.zig");
const fs_area = @import("fat32/fs.zig");

pub const HANDLER_NAME = "fat-handler";
const HANDLER_VERSION = 1;
const HANDLER_REVISION = 0;
const BUILD_DATE = "23.09.2026";
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
        return media.command(exec.CMD_WRITE, lba * media.blockSize(), bytes, @constCast(from.ptr));
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

    pub fn now(media: *DeviceMedia) dos.DateStamp {
        var stamp: dos.DateStamp = .{};
        _ = media.dl.DateStamp(&stamp);
        return stamp;
    }
};

const FileSystem = fs_area.FileSystem(DeviceMedia);

/// Everything the process keeps, in one allocation.
const State = struct {
    ub: *UtilityBase,
    media: DeviceMedia,
    fs: FileSystem,
    io: exec.IOStdReq,
    /// The volume node, while a volume is mounted.
    volume: ?*dos.DosList = null,
};

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

    st.fs = FileSystem.init(&st.media, st.ub, &me.msg_port);
    // A card that is not there or not readable is not an error: the
    // handler stays for the one that will be.
    st.fs.mount() catch {};
    if (st.fs.mounted) addVolume(dl, st);
    if (node) |device_node| device_node.task = &me.msg_port;
    dl.ReplyPkt(startup, dos.DOSTRUE, 0);

    while (dl.WaitPkt()) |pkt| {
        if (st.fs.checkMedium()) {
            removeVolume(dl, st);
            if (st.fs.mounted) addVolume(dl, st);
        }
        const reply = serve(st, pkt);
        dl.ReplyPkt(pkt, reply.res1, reply.res2);
    }
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

/// One packet. Without a volume only the ones that say what is in the
/// slot get an answer that is not an error.
fn serve(st: *State, pkt: *DosPacket) _fat.Answer {
    if (st.fs.mounted) return st.fs.answer(pkt);
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
        else => return _fat.no(if (card_in) dos.ERROR_NOT_A_DOS_DISK else dos.ERROR_NO_DISK),
    }
}

/// The volume on the device list under the card's name, so locks can
/// point at it.
fn addVolume(dl: *DosBase, st: *State) void {
    var name: [16:0]u8 = @splat(0);
    const label = st.fs.volumeName();
    @memcpy(name[0..label.len], label);
    const entry = dl.MakeDosEntry(&name, dos.DLT_VOLUME) orelse return;
    entry.misc.volume.disk_type = dos.ID_MSDOS_DISK;
    entry.task = st.fs.port;
    if (!dl.AddDosEntry(entry)) {
        dl.FreeDosEntry(entry);
        return;
    }
    st.volume = entry;
    st.fs.volume_node = entry;
}

fn removeVolume(dl: *DosBase, st: *State) void {
    const entry = st.volume orelse return;
    st.volume = null;
    st.fs.volume_node = null;
    if (dl.RemDosEntry(entry)) dl.FreeDosEntry(entry);
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
