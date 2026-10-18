// SPDX-License-Identifier: MIT
//! PosFS: what a posfs volume holds and how it is set, and the volume's
//! own work - its check, its Recycled, its snapshots. Built against the SDK
//! only.
//!
//!   PosFS DRIVE/A,INFO/S,CHECKSUMS/K,COMPRESS/K,RECYCLED/K,LIMIT/K/N,
//!         SNAPSHOT/K,DELSNAPSHOT/K,ROLLBACK/K,UNDELETE/K,TO/K,EMPTY/S,
//!         CHECK/S,DATA/S,FORCE/S
//!
//!   PosFS DH1:                         ; what the volume holds (INFO)
//!   PosFS DH1: COMPRESS ON             ; data written from now on compressed
//!   PosFS DH1: CHECK DATA              ; the volume checked, its data too
//!   PosFS DH1: UNDELETE Letter TO Work:Letters/Letter
//!   PosFS DH1: SNAPSHOT Monday
//!   PosFS DH1: ROLLBACK Monday
//!
//! DRIVE is the volume's drive or name, with its colon; anything but a
//! posfs volume is refused. CHECKSUMS and COMPRESS take ON or OFF and
//! change what is written from then on. RECYCLED ON gives the volume its
//! Recycled directory, where deletes go, and OFF empties it and takes it
//! away; LIMIT is the most Recycled keeps, in KiB (0 for as much as the
//! volume has room for), and either keeps the other as it is. EMPTY
//! empties Recycled, UNDELETE gives back what is in it under that name -
//! to where it came from, or TO a path on the volume: into the directory
//! it names, or under the name it ends in. SNAPSHOT makes a
//! snapshot under that name (`.snapshots/<name>/` in the root, read
//! only), DELSNAPSHOT deletes one, and ROLLBACK puts the volume back to
//! its newest snapshot, which it names - to an older one once the newer
//! ones are deleted: everything written since is lost, so it asks first,
//! unless FORCE is given, and it needs the drive with nothing on it in
//! use. CHECK checks the volume's trees, objects and
//! space while it stays in use; DATA reads every file's data as well and
//! checks it against its checksums. INFO, or no other action, prints what
//! the volume holds. Several actions given run in the order of the
//! template.
//!
//! The return code is 0 when everything asked was done, 5 when it was
//! stopped at the question or by Ctrl-C, 10 when the check found damage,
//! and 20 when something could not be done, with the reason said.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const posfs = dos.posfs;
const packets = posfs.packets;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const MsgPort = exec.MsgPort;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "PosFS";
const VERSION_STRING = "\x00$VER: PosFS 1.0 (18.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DRIVE/A,INFO/S,CHECKSUMS/K,COMPRESS/K,RECYCLED/K,LIMIT/K/N,SNAPSHOT/K,DELSNAPSHOT/K,ROLLBACK/K,UNDELETE/K,TO/K,EMPTY/S,CHECK/S,DATA/S,FORCE/S";
const arg_drive = 0;
const arg_info = 1;
const arg_checksums = 2;
const arg_compress = 3;
const arg_recycled = 4;
const arg_limit = 5;
const arg_snapshot = 6;
const arg_delsnapshot = 7;
const arg_rollback = 8;
const arg_undelete = 9;
const arg_to = 10;
const arg_empty = 11;
const arg_check = 12;
const arg_data = 13;
const arg_force = 14;
const arg_count = 15;

const MSG_INVALID_DEVICE = "Invalid device or volume name '%s'\n";
const MSG_NOT_POSFS = "%s is not a posfs volume\n";
const MSG_ON_OFF = "%s takes ON or OFF\n";
const MSG_TO_ALONE = "TO goes with UNDELETE\n";
const MSG_ROLLBACK = "Put %s back to snapshot %s? Everything written since is lost.\n";
const MSG_NOT_NEWEST = "%s is not the newest snapshot: delete the newer ones first\n";
const MSG_PRESS = "Press RETURN to go on or CTRL-C to stop: ";
const MSG_CHECKING = "Checking %s%s\n";
const MSG_CHECKED = "%lu objects, %lu nodes, %lu data blocks: ";
const MSG_CLEAN = "no damage found\n";
const MSG_DAMAGE = "%lu faults found\n  the first: %s\n";

/// A program run: dos, the drive's handler, and the drive as typed.
const Run = struct {
    dl: *DosBase,
    port: *MsgPort,
    drive: [*:0]const u8,

    /// One of posfs's packets, its structure in dp_Arg1: false with
    /// IoErr when it was refused.
    fn send(run: *const Run, action: i32, structure: ?*anyopaque) bool {
        const arg: isize = @bitCast(@intFromPtr(structure));
        return run.dl.DoPkt(run.port, action, arg, 0, 0, 0, 0) != dos.DOSFALSE;
    }

    /// The reason a packet was refused, and the return code for it.
    fn fail(run: *const Run) i32 {
        _ = run.dl.PrintFault(run.dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const drive = rdargs.string(argv[arg_drive]).?;

    // A name without its colon is a file's, not a drive's.
    var name_len: usize = 0;
    while (drive[name_len] != 0) name_len += 1;
    if (name_len == 0 or drive[name_len - 1] != ':') {
        _ = Printf(dl, MSG_INVALID_DEVICE, .{drive});
        return dos.RETURN_FAIL;
    }
    const dp = dl.GetDeviceProc(drive, null) orelse {
        _ = Printf(dl, MSG_INVALID_DEVICE, .{drive});
        return dos.RETURN_FAIL;
    };
    defer dl.FreeDeviceProc(dp);
    const port = dp.port orelse {
        _ = Printf(dl, MSG_INVALID_DEVICE, .{drive});
        return dos.RETURN_FAIL;
    };
    const run: Run = .{ .dl = dl, .port = port, .drive = drive };

    // posfs's packets go to posfs volumes only.
    var disk: dos.InfoData = .{};
    const disk_info = @intFromEnum(dos.ActionCode.disk_info);
    if (dl.DoPkt(port, disk_info, @bitCast(@intFromPtr(&disk)), 0, 0, 0, 0) == dos.DOSFALSE or disk.disk_type != posfs.ID_POSFS_DISK) {
        _ = Printf(dl, MSG_NOT_POSFS, .{drive});
        return dos.RETURN_FAIL;
    }
    if (argv[arg_to] != 0 and argv[arg_undelete] == 0) {
        _ = dl.PutStr(MSG_TO_ALONE);
        return dos.RETURN_FAIL;
    }
    var did = false;

    // The switches, in one packet.
    var settings: packets.Settings = .{};
    const switches = [_]struct { arg: usize, bit: u32, name: [*:0]const u8 }{
        .{ .arg = arg_checksums, .bit = packets.SET_CHECKSUMS, .name = "CHECKSUMS" },
        .{ .arg = arg_compress, .bit = packets.SET_COMPRESS, .name = "COMPRESS" },
        .{ .arg = arg_recycled, .bit = packets.SET_RECYCLED, .name = "RECYCLED" },
    };
    for (switches) |each| {
        const text = rdargs.string(argv[each.arg]) orelse continue;
        const on = onOff(text) orelse {
            _ = Printf(dl, MSG_ON_OFF, .{each.name});
            return dos.RETURN_FAIL;
        };
        settings.mask |= each.bit;
        if (on) settings.settings |= each.bit;
    }
    const limit = rdargs.number(argv[arg_limit]);
    if (limit != null and limit.? < 0) {
        _ = dl.PrintFault(dos.ERROR_BAD_NUMBER, COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    // Recycled's switch and its limits go together: each as it is, unless
    // given.
    if (limit != null or settings.mask & packets.SET_RECYCLED != 0) {
        var now: packets.Info = .{};
        if (!run.send(packets.ACTION_POSFS_INFO, &now)) return run.fail();
        if (settings.mask & packets.SET_RECYCLED == 0) {
            settings.mask |= packets.SET_RECYCLED;
            settings.settings |= now.settings & packets.SET_RECYCLED;
        }
        settings.recycled_max_count = now.recycled_max_count;
        settings.recycled_max_bytes = if (limit) |kib| @as(u64, @intCast(kib)) * 1024 else now.recycled_max_bytes;
    }
    if (settings.mask != 0) {
        if (!run.send(packets.ACTION_POSFS_SETTINGS, &settings)) return run.fail();
        did = true;
    }

    if (argv[arg_empty] != 0) {
        if (!run.send(packets.ACTION_POSFS_EMPTY_RECYCLED, null)) return run.fail();
        did = true;
    }
    if (rdargs.string(argv[arg_undelete])) |name| {
        var undelete: packets.UndeleteArgs = .{ .name = name, .to = rdargs.string(argv[arg_to]) };
        if (!run.send(packets.ACTION_POSFS_UNDELETE, &undelete)) return run.fail();
        did = true;
    }
    if (rdargs.string(argv[arg_snapshot])) |name| {
        var snapshot: packets.SnapshotArgs = .{ .name = name };
        if (!run.send(packets.ACTION_POSFS_MAKE_SNAPSHOT, &snapshot)) return run.fail();
        did = true;
    }
    if (rdargs.string(argv[arg_delsnapshot])) |name| {
        var snapshot: packets.SnapshotArgs = .{ .name = name };
        if (!run.send(packets.ACTION_POSFS_DELETE_SNAPSHOT, &snapshot)) return run.fail();
        did = true;
    }
    if (rdargs.string(argv[arg_rollback])) |name| {
        if (argv[arg_force] == 0) {
            _ = Printf(dl, MSG_ROLLBACK, .{ drive, name });
            if (!confirm(dl)) return dos.RETURN_WARN;
        }
        if (!dl.Inhibit(drive, true)) return run.fail();
        var snapshot: packets.SnapshotArgs = .{ .name = name };
        const rolled = run.send(packets.ACTION_POSFS_ROLLBACK, &snapshot);
        const code = dl.IoErr();
        _ = dl.Inhibit(drive, false);
        if (!rolled) {
            if (code == dos.ERROR_OBJECT_EXISTS) {
                _ = Printf(dl, MSG_NOT_NEWEST, .{name});
            } else _ = dl.PrintFault(code, COMMAND_NAME);
            return dos.RETURN_FAIL;
        }
        did = true;
    }
    if (argv[arg_check] != 0 or argv[arg_data] != 0) {
        const result = check(&run, &disk, argv[arg_data] != 0);
        if (result != dos.RETURN_OK) return result;
        did = true;
    }
    if (argv[arg_info] != 0 or !did) return printInfo(&run, &disk);
    return dos.RETURN_OK;
}

/// ON or OFF, in any case; null for anything else.
fn onOff(text: [*:0]const u8) ?bool {
    if (same(text, "ON")) return true;
    if (same(text, "OFF")) return false;
    return null;
}

fn same(text: [*:0]const u8, word: []const u8) bool {
    for (word, 0..) |char, at| {
        const typed = text[at];
        if (typed == 0) return false;
        const upper = if (typed >= 'a' and typed <= 'z') typed - 32 else typed;
        if (upper != char) return false;
    }
    return text[word.len] == 0;
}

/// RETURN, or Ctrl-C. A line is read rather than a character, so a script
/// may answer with a blank line.
fn confirm(dl: *DosBase) bool {
    _ = dl.PutStr(MSG_PRESS);
    _ = dl.Flush(dl.Output());
    while (true) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) return false;
        const c = dl.FGetC(dl.Input());
        if (c < 0) return false;
        if (c == '\n') return true;
    }
}

/// The volume's name, off the node its handler points at.
fn volumeName(disk: *const dos.InfoData, into: *[32:0]u8) [*:0]const u8 {
    into.* = @splat(0);
    if (disk.volume_node) |node| {
        var at: usize = 0;
        while (at < into.len and node.name[at] != 0) : (at += 1) into[at] = node.name[at];
    }
    return into;
}

/// The check, a slice a packet until it is done; Ctrl-C between two ends
/// it.
fn check(run: *const Run, disk: *const dos.InfoData, data: bool) i32 {
    const dl = run.dl;
    var name: [32:0]u8 = undefined;
    _ = Printf(dl, MSG_CHECKING, .{ volumeName(disk, &name), @as([*:0]const u8, if (data) ", its data too" else "") });
    var args: packets.CheckArgs = .{ .flags = if (data) packets.CHECK_DATA else 0 };
    while (true) {
        if (!run.send(packets.ACTION_POSFS_CHECK, &args)) return run.fail();
        if (args.cursor == 0) break;
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            args.flags = packets.CHECK_STOP;
            _ = run.send(packets.ACTION_POSFS_CHECK, &args);
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            return dos.RETURN_WARN;
        }
    }
    _ = Printf(dl, MSG_CHECKED, .{ args.objects, args.nodes, args.data_blocks });
    if (args.errors == 0) {
        _ = dl.PutStr(MSG_CLEAN);
        return dos.RETURN_OK;
    }
    args.message[args.message.len - 1] = 0;
    _ = Printf(dl, MSG_DAMAGE, .{ @as(u64, args.errors), @as([*:0]const u8, @ptrCast(&args.message)) });
    return dos.RETURN_ERROR;
}

/// What the volume holds and how it is set.
fn printInfo(run: *const Run, disk: *const dos.InfoData) i32 {
    const dl = run.dl;
    var numbers: packets.Info = .{};
    if (!run.send(packets.ACTION_POSFS_INFO, &numbers)) return run.fail();
    var name: [32:0]u8 = undefined;
    const kib = numbers.block_size / 1024;
    _ = Printf(dl, "%s (%s), posfs %u\n", .{ volumeName(disk, &name), run.drive, numbers.version });
    _ = Printf(dl, "  Blocks       %lu of %u bytes (%lu KiB), written in %u\n", .{ numbers.blocks, numbers.block_size, numbers.blocks * kib, numbers.write_unit });
    _ = Printf(dl, "  Free         %lu blocks (%lu KiB)\n", .{ numbers.free, numbers.free * kib });
    _ = Printf(dl, "  In use       live %lu, snapshots %lu, Recycled %lu, pending %lu, reserve %lu\n", .{ numbers.live, numbers.snapshots, numbers.recycled, numbers.pending, numbers.reserve });
    _ = Printf(dl, "  Checksums    %s\n", .{onOffText(numbers.settings, packets.SET_CHECKSUMS)});
    _ = Printf(dl, "  Compression  %s\n", .{onOffText(numbers.settings, packets.SET_COMPRESS)});
    if (numbers.settings & packets.SET_RECYCLED == 0) {
        _ = dl.PutStr("  Recycled     off\n");
    } else if (numbers.recycled_max_bytes == 0) {
        _ = Printf(dl, "  Recycled     on, %lu objects\n", .{numbers.recycled_count});
    } else {
        _ = Printf(dl, "  Recycled     on, %lu objects, at most %lu KiB\n", .{ numbers.recycled_count, numbers.recycled_max_bytes / 1024 });
    }
    _ = Printf(dl, "  Snapshots    %u\n", .{numbers.snapshot_count});
    _ = Printf(dl, "  Checkpoint   %lu, journal %u of %u blocks\n", .{ numbers.gen, numbers.journal_used, numbers.journal_limit });
    if (numbers.erased != 0) _ = Printf(dl, "  Erased       %u blocks ahead\n", .{numbers.erased});
    if (numbers.last_check == 0) {
        _ = dl.PutStr("  Last check   never\n");
        return dos.RETURN_OK;
    }
    var date: [dos.LEN_DATSTRING:0]u8 = @splat(0);
    var time: [dos.LEN_DATSTRING:0]u8 = @splat(0);
    var when: dos.DateTime = .{ .stamp = posfs.layout.stampOf(numbers.last_check), .format = dos.FORMAT_DOS, .str_date = &date, .str_time = &time };
    if (!dl.DateToStr(&when)) {
        _ = dl.PutStr("  Last check   ?\n");
        return dos.RETURN_OK;
    }
    _ = Printf(dl, "  Last check   %s %s, no damage found\n", .{ @as([*:0]const u8, &date), @as([*:0]const u8, &time) });
    return dos.RETURN_OK;
}

fn onOffText(settings: u32, bit: u32) [*:0]const u8 {
    return if (settings & bit != 0) "on" else "off";
}
