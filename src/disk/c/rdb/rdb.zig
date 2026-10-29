// SPDX-License-Identifier: MIT
//! RDB: what a disk says about itself - the RigidDiskBlock in its first
//! blocks and the partitions hanging off it - and changes to it, through
//! LIBS:rdb.library. Built against the SDK only.
//!
//!   RDB DEVICE,UNIT/K/N,FULL/S,INIT/S,FORCE/S,ADD/K,LOW/K/N,HIGH/K/N,
//!       DOSTYPE/K,BOOTABLE/S,REMOVE/K,CHANGE/K,ADDFS/K,REMFS/K,BOOTPRI/K/N,
//!       GPT/S,MOUNT/S,ADDGPT/K,REMGPT/K,SIZE/K
//!
//!   RDB                         flash.device unit 0
//!   RDB sdcard.device UNIT 0    another disk
//!   RDB FULL                    every field, and each partition's environment
//!   RDB INIT                    a fresh table on a disk that has none
//!   RDB INIT FORCE              ... or in place of the one it has
//!   RDB nvme.device INIT GPT    a GPT for the whole disk, a PowerOS
//!                               container over its free blocks, and a
//!                               table in the container
//!   RDB ADD DH1                 a partition over the largest free run
//!   RDB ADD DH1 LOW 100 HIGH 199 DOSTYPE FLS BOOTABLE
//!   RDB sdcard.device ADD SD0 LOW 8192 HIGH 62333951 DOSTYPE MSD
//!       BOOTABLE BOOTPRI 5      the card's FAT partition, started from
//!                               before the flash disk (whose BootPri is 0)
//!   RDB REMOVE DH1              a partition taken out of the table
//!   RDB CHANGE DH1 DOSTYPE POS  a partition given to another file system
//!   RDB ADDFS HANDLERS:posfs-handler DOSTYPE POS
//!                               a file system's code kept in the table
//!   RDB REMFS POS               ... and taken out of it
//!   RDB nvme.device ADD DH1 DOSTYPE POS MOUNT
//!                               ... and mounted at once, with every
//!                               partition of the table no drive has yet
//!   RDB ADD DH2 SIZE 4G DOSTYPE FAT32
//!                               4 GiB of FAT32, at the first free
//!                               cylinders they fit in
//!   RDB nvme.device INIT GPT ADDGPT BOOT DOSTYPE FAT32 SIZE 256M
//!                               a GPT with a FAT partition other systems
//!                               read first, mounted as BOOT: for
//!                               C:Format, and the container after it
//!   RDB sdcard.device ADDGPT Photos DOSTYPE EXFAT
//!                               a FAT partition over the GPT's largest
//!                               free run
//!   RDB sdcard.device REMGPT Photos
//!                               ... and taken out of the GPT again
//!
//! The device is an exec device with trackdisk's commands, so anything
//! that answers TD_GETGEOMETRY and CMD_READ can be read. A change is made
//! in the order INIT, REMOVE, REMGPT, CHANGE, ADD, ADDGPT, REMFS, ADDFS,
//! then the GPT and the table are written as a whole and printed. Only
//! the table's own blocks are written: what is on
//! a partition's cylinders stays, so a partition CHANGE gives another
//! DosType is formatted afterwards (C:Format) for its new file system.
//! A disk's table is read when the system starts, so a partition added,
//! changed or taken out is mounted as it now says at the next start.
//!
//! **MOUNT** mounts at once, as HDToolBox's Save does: once any change
//! is written, every partition of the table not marked PBFF_NOMOUNT is
//! mounted and its file system started (rdb.library's MountPartition),
//! under its name, or with a dot added while that is taken (`DH0.`) -
//! but for one a drive has already, or a drive over the whole medium
//! opens (`NV0:` on an SSD that had no table: `Assign NV0: DISMOUNT`
//! first). A partition mounted so with no volume on it yet waits for
//! C:Format. It is how a machine with no display - where HDToolBox does
//! not run - gets a new partition's drive without a restart, and a disk
//! the system's own drive names are taken on (a second `DH0`) a drive
//! for each of its partitions.
//!
//! A disk with no RigidDiskBlock is not an error: it says so and stops,
//! since that is the normal state of a blank chip.
//!
//! **A disk with a GPT.** Its GPT is listed before the table: each used
//! entry's number, first and last block, size, type and name, the
//! PowerOS container among them. The table is the one in the container,
//! and its blocks and cylinders count from the container's first block.
//! INIT on such a disk makes the table in the container. INIT GPT makes a
//! new GPT for the whole disk, with a container over its free blocks and
//! a table in that; with FORCE it replaces any table the disk has. INIT
//! FORCE on a disk with a GPT and no container replaces the GPT with a
//! table over the whole disk. Either way every partition the disk had is
//! lost. A changed GPT is written before the table, and a GPT read from
//! its copy at the end is written whole with any change.
//!
//! **FAT.** DOSTYPE takes a file system by name: `FAT` (`MSD\0`, which
//! C:Format makes FAT32 up to 32 GiB and exFAT past that), `FAT32`
//! (`MSD\1`), `EXFAT` (`MSD\2`) or `POSFS` (`POS\0`). A FAT partition
//! in the table (ADD) is one only PowerOS sees. One of the GPT's own
//! (ADDGPT) every system sees: a camera's card, a stick for a PC, the
//! partition a firmware loads its kernel from. ADDGPT puts a basic data
//! partition of that name in the GPT - over LOW to HIGH, the disk's
//! blocks with the first on a MiB; of SIZE at the first free MiB it fits
//! from; or over the largest free run - writes it, and mounts it at once
//! for FAT under its name, so that `Format DRIVE BOOT: NAME Boot` gives it
//! a volume of the format DOSTYPE names. Once it has one, the next start
//! mounts it as the device mounts a GPT's FAT partitions (nvme.device's
//! first as `NV0:`, a later one as `NV0P2:`). The container INIT GPT
//! makes takes every block the GPT's other partitions leave, so a FAT
//! partition goes in with INIT GPT, which puts ADDGPT's partition in
//! first and the container over the largest free run after it. REMGPT
//! takes a partition out of the GPT, by its name or its number - not the
//! container; a drive it had stays until the next start.
//!
//! SIZE is in bytes, or with K, M, G or T after it (`256M`), and goes in
//! place of LOW and HIGH: ADD rounds it up to whole cylinders, and puts
//! them at the first free ones they fit in.
//!
//! **File systems kept in the table.** ADDFS reads a handler's load file
//! and keeps it in the table for the partitions of DOSTYPE, in place of
//! code kept for that DosType before; its version is the handler's own,
//! from its ROM tag. A partition of that DosType runs the table's code
//! when the ROM has no handler for it or an older one, which the list's
//! last column says. REMFS takes the code for a DosType out again.
//!
//! A DosType is printed the way a disk labels itself - four characters,
//! with an unprintable one written as `\<n>`, so the flash file system's
//! `FLS\0` reads as it is spelled - and the longword after it. DOSTYPE
//! takes it the same way (`FLS\0`, or `FLS` with the zero left off), as
//! a number (`0x464C5300`) or by its file system's name; without it a
//! partition ADD makes is for the flash file system, and one ADDGPT makes
//! for FAT. CHANGE takes DOSTYPE, BOOTABLE, BOOTPRI or more for the
//! partition it names: posfs's is `POS`.
//!
//! BOOTPRI is the partition's de_BootPri, 0 for a new one without it: of
//! the bootable partitions of every disk, dos starts from the one with the
//! highest.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const rdb = sdk.rdb;
const hardblocks = dos.hardblocks;
const gpt = dos.gpt;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RDBBase = sdk.interface.rdb.RDBBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "RDB";
const VERSION_STRING = "\x00$VER: RDB 1.6 (29.10.2026)\r\n";

const template = "DEVICE,UNIT/K/N,FULL/S,INIT/S,FORCE/S,ADD/K,LOW/K/N,HIGH/K/N,DOSTYPE/K,BOOTABLE/S,REMOVE/K,CHANGE/K,ADDFS/K,REMFS/K,BOOTPRI/K/N,GPT/S,MOUNT/S,ADDGPT/K,REMGPT/K,SIZE/K";
const arg_device = 0;
const arg_unit = 1;
const arg_full = 2;
const arg_init = 3;
const arg_force = 4;
const arg_add = 5;
const arg_low = 6;
const arg_high = 7;
const arg_dostype = 8;
const arg_bootable = 9;
const arg_remove = 10;
const arg_change = 11;
const arg_addfs = 12;
const arg_remfs = 13;
const arg_boot_pri = 14;
const arg_gpt = 15;
const arg_mount = 16;
const arg_addgpt = 17;
const arg_remgpt = 18;
const arg_size = 19;
const arg_count = 20;

/// The disk this system boots from, when nothing else is named.
const default_device = "flash.device";

/// The rdb.library that keeps file systems in a table.
const file_systems_revision = 3;

/// The rdb.library that reads and writes a GPT.
const gpt_revision = 4;

/// The rdb.library that mounts a partition.
const mount_revision = 2;

/// The rdb.library that mounts a new GPT partition for FAT.
const fat_revision = 7;

/// The name INIT GPT gives the container.
const container_name = "PowerOS";

const MSG_NO_RDB = "%s unit %d has no RigidDiskBlock in its first %d blocks\n";
const MSG_FOREIGN = "%s unit %d has a RigidDiskBlock for another block size\n";
const MSG_NO_CONTAINER = "%s unit %d has a GPT and no PowerOS container in it\n";
const MSG_EMPTY_CONTAINER = "%s unit %d has a PowerOS container with no RigidDiskBlock in it (INIT makes one)\n";
const MSG_NO_PARTS = "  (no partitions)\n";
const MSG_BAD_DOSTYPE = "%s: %s is neither a file system's name, four characters nor a number\n";
const MSG_BAD_SIZE = "SIZE: %s is no size: a number of bytes, or one with K, M, G or T after it\n";
const MSG_NO_ROOM = "  (the PowerOS container has the disk's free blocks: INIT GPT FORCE with ADDGPT puts a partition before it,\n" ++
    "   and every partition on the disk is lost)\n";

/// The file systems DOSTYPE takes by name, as C:Format's switches call
/// them; a name wins over the characters it is spelled with.
const NamedType = struct { name: []const u8, dos_type: u32 };
const named_types = [_]NamedType{
    .{ .name = "FAT", .dos_type = dos.ID_MSDOS_DISK },
    .{ .name = "FAT32", .dos_type = dos.fat.typeWithFormat(dos.ID_MSDOS_DISK, dos.fat.FORMAT_FAT32) },
    .{ .name = "EXFAT", .dos_type = dos.fat.typeWithFormat(dos.ID_MSDOS_DISK, dos.fat.FORMAT_EXFAT) },
    .{ .name = "POSFS", .dos_type = dos.posfs.ID_POSFS_DISK },
};

/// One row of the partition table. The same format prints the heading and
/// the rule, so the columns cannot drift apart.
const row = "  %-8s %5s %-16s %9s %7s %-16s %s\n";

/// One row of the file systems the table keeps.
const fs_row = "  %-16s %-14s %-7s %7s %5s %6s %s\n";

/// One row of the GPT's partitions.
const gpt_row = "  %3s %10s %10s %7s %-18s %-16s %s\n";

const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    rb: *RDBBase,
    handle: *rdb.RDBHandle,
    device: [*:0]const u8,
    unit: u32,
    full: bool,
    /// The partition ADDGPT made, and the FAT DosType it is mounted with.
    made: ?*rdb.GPTPartition = null,
    made_type: u32 = 0,
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

    const device = rdargs.string(argv[arg_device]) orelse default_device;
    const unit: u32 = if (rdargs.number(argv[arg_unit])) |n| @intCast(@max(n, 0)) else 0;

    const rdb_lib = sys.OpenLibrary(rdb.RDBNAME, 1) orelse {
        _ = Printf(dl, "%s: cannot open %s\n", .{ COMMAND_NAME, rdb.RDBNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(rdb_lib);
    const rb: *RDBBase = @ptrCast(rdb_lib);

    var err: i32 = rdb.RDBERR_OK;
    const handle = rb.OpenRDB(device, unit, &err) orelse {
        _ = Printf(dl, "%s unit %d: %s\n", .{ device, unit, errorText(err) });
        return dos.RETURN_FAIL;
    };
    defer rb.CloseRDB(handle);

    var run: Run = .{ .sys = sys, .dl = dl, .rb = rb, .handle = handle, .device = device, .unit = unit, .full = argv[arg_full] != 0 };
    showDrive(&run, device, unit);

    // A partition made but not mounted is a warning, after the listing.
    var changed: i32 = dos.RETURN_OK;
    if (argv[arg_init] != 0 or argv[arg_add] != 0 or argv[arg_remove] != 0 or argv[arg_change] != 0 or
        argv[arg_addfs] != 0 or argv[arg_remfs] != 0 or argv[arg_addgpt] != 0 or argv[arg_remgpt] != 0)
    {
        changed = change(&run, &argv);
        if (changed >= dos.RETURN_ERROR) return changed;
    }

    const gpt_disk = readsGpt(rb) and handle.flags & rdb.RDBF_GPT != 0;
    if (gpt_disk) {
        showGpt(&run);
        if (handle.flags & rdb.RDBF_GPTDAMAGED != 0) {
            _ = dl.PutStr("  (the disk says it has a GPT, but neither copy is sound: INIT GPT FORCE makes a new one)\n");
            return dos.RETURN_ERROR;
        }
    }
    if (handle.flags & rdb.RDBF_FOUND == 0) {
        if (handle.flags & rdb.RDBF_FOREIGN != 0) {
            _ = Printf(dl, MSG_FOREIGN, .{ device, unit });
        } else if (gpt_disk and handle.flags & rdb.RDBF_CONTAINER != 0) {
            _ = Printf(dl, MSG_EMPTY_CONTAINER, .{ device, unit });
        } else if (gpt_disk) {
            _ = Printf(dl, MSG_NO_CONTAINER, .{ device, unit });
        } else {
            _ = Printf(dl, MSG_NO_RDB, .{ device, unit, hardblocks.RDB_LOCATION_LIMIT });
        }
        if (gpt_disk and argv[arg_mount] != 0) return @max(changed, mountAll(&run));
        return dos.RETURN_WARN;
    }
    showRdb(&run, handle.block, &handle.rdb);
    showPartitions(&run);
    if (keepsFileSystems(rb)) showFileSystems(&run);
    if (handle.flags & rdb.RDBF_DAMAGED != 0) {
        _ = dl.PutStr("  (a chain of the table breaks at a block that is not sound: what follows it is not shown)\n");
        return dos.RETURN_ERROR;
    }
    if (argv[arg_mount] != 0) return @max(changed, mountAll(&run));
    return changed;
}

/// MOUNT: every partition of the table no drive has yet, but those marked
/// PBFF_NOMOUNT, mounted and its file system started; then those of the
/// GPT, but the container and those marked ATTR_NO_AUTOMOUNT.
fn mountAll(run: *Run) i32 {
    const dl = run.dl;
    const rb = run.rb;
    const lib = rb.lib();
    if (lib.version == 1 and lib.revision < mount_revision) {
        _ = Printf(dl, "MOUNT: %s mounts nothing before 1.%d\n", .{ rdb.RDBNAME, @as(i32, mount_revision) });
        return dos.RETURN_ERROR;
    }
    var rc: i32 = dos.RETURN_OK;
    var part = rb.NextPartition(run.handle, null);
    while (part) |p| : (part = rb.NextPartition(run.handle, p)) {
        if (p.block.flags & hardblocks.PBFF_NOMOUNT != 0) continue;
        var name: rdb.MountName = @splat(0);
        const err = rb.MountPartition(run.handle, p, &name, rdb.RDBMF_START);
        var drive: [33:0]u8 = @splat(0);
        _ = copy(drive[0..32], p.block.name());
        // Its cylinders count from the container's first block.
        const env = &p.block.environment;
        const first = env.byteOf(0) + run.handle.container * run.handle.geometry.sector_size;
        const span: Span = .{ .first = first, .end = first + env.blocks() * env.size_block };
        if (!mountSaid(run, @ptrCast(&drive), &name, err, span, true)) rc = dos.RETURN_WARN;
    }
    if (readsGpt(rb) and run.handle.flags & rdb.RDBF_GPT != 0) {
        var gpt_part = rb.NextGPTPartition(run.handle, null);
        while (gpt_part) |p| : (gpt_part = rb.NextGPTPartition(run.handle, p)) {
            if (gpt.isContainer(&p.entry) or p.entry.attributes & gpt.ATTR_NO_AUTOMOUNT != 0) continue;
            if (p == run.made) continue; // its own mount said what came of it
            // Under its entry's name, when that is a drive's; a new
            // partition for FAT with an older library's MountGPTPartition
            // stays as it is.
            var drive: [gpt.name_units:0]u8 = @splat(0);
            if (!driveName(gpt.nameText(&p.entry, &drive))) continue;
            const flags = rdb.RDBMF_START | if (mountsFat(rb)) rdb.RDBMF_FAT else 0;
            var name: rdb.MountName = @splat(0);
            const err = rb.MountGPTPartition(run.handle, p, @ptrCast(&drive), &name, flags);
            // Another system's partition, or one with no volume on it.
            if (err == rdb.RDBERR_FILESYSTEM) continue;
            if (!mountSaid(run, @ptrCast(&drive), &name, err, gptSpan(run, p), true)) rc = dos.RETURN_WARN;
        }
    }
    return rc;
}

/// The bytes of the disk a partition takes, `first` to before `end`.
const Span = struct { first: u64, end: u64 };

fn gptSpan(run: *Run, part: *const rdb.GPTPartition) Span {
    const bytes = run.handle.geometry.sector_size;
    return .{ .first = part.entry.starting_lba * bytes, .end = (part.entry.ending_lba + 1) * bytes };
}

/// What a mount of a partition came to, printed - with `quiet_mounted`
/// nothing for one that has its drive already. False when it failed.
fn mountSaid(run: *Run, drive: [*:0]const u8, name: *const rdb.MountName, err: i32, span: Span, quiet_mounted: bool) bool {
    const dl = run.dl;
    if (err == rdb.RDBERR_OK) {
        _ = Printf(dl, "%s mounted as %s:\n", .{ drive, @as([*:0]const u8, @ptrCast(name)) });
        return true;
    }
    if (err == rdb.RDBERR_MOUNTED) {
        var other: [dos.MAX_DEVICE_NAME + 1:0]u8 = @splat(0);
        const in_the_way: [*:0]const u8 = @ptrCast(&other);
        switch (driveInTheWay(run, span, &other)) {
            .whole => {
                _ = Printf(dl, "%s not mounted: %s: is a drive over the whole medium (Assign %s: DISMOUNT, then MOUNT)\n", .{
                    drive,
                    in_the_way,
                    in_the_way,
                });
                return false;
            },
            .same => if (quiet_mounted) return true,
            .none => {},
            .some => {},
        }
        if (other[0] != 0) {
            _ = Printf(dl, "%s not mounted: %s: has some of its blocks, a drive from before the change that the next start lets go\n", .{
                drive,
                in_the_way,
            });
            return false;
        }
    }
    _ = Printf(dl, "%s not mounted: %s\n", .{ drive, mountErrorText(err) });
    return false;
}

const InTheWay = enum {
    none,
    /// A drive over the whole medium, which every partition is in: what
    /// a unit with no table gets when it comes in (`NV0:`).
    whole,
    /// A drive over just the partition's blocks: the partition's own.
    same,
    /// A drive over some of them.
    some,
};

/// A drive of the unit that has some of the partition's blocks, its name
/// in `into`, and how much of them it has.
fn driveInTheWay(run: *Run, span: Span, into: *[dos.MAX_DEVICE_NAME + 1:0]u8) InTheWay {
    const dl = run.dl;
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    const list = dl.LockDosList(flags) orelse return .none;
    defer dl.UnLockDosList(flags);
    var entry = dl.NextDosEntry(list, dos.LDF_DEVICES);
    while (entry) |node| : (entry = dl.NextDosEntry(node, dos.LDF_DEVICES)) {
        const startup = dos.filehandler.startupOf(node.misc.handler.startup) orelse continue;
        if (!dos.filehandler.opensUnit(startup, run.device, run.unit)) continue;
        var how: InTheWay = .whole;
        if (startup.environ) |env| {
            if (!env.wholeMedium()) {
                const first = env.byteOf(0);
                const end = env.byteOf(env.blocks());
                if (end <= span.first or span.end <= first) continue;
                how = if (first == span.first and end == span.end) .same else .some;
            }
        }
        into[copy(into, node.name[0..length(node.name)])] = 0;
        return how;
    }
    return .none;
}

/// What a failed MountPartition says, where it differs from the table's
/// calls.
fn mountErrorText(err: i32) [*:0]const u8 {
    return switch (err) {
        rdb.RDBERR_FILESYSTEM => "no handler serves its DosType here, and the table brings no code for it",
        rdb.RDBERR_NAME => "its name, and every one with dots that fits, is taken",
        rdb.RDBERR_MOUNTED => "a drive has some of its blocks already",
        else => errorText(err),
    };
}

/// INIT, REMOVE, REMGPT, CHANGE, ADD, ADDGPT, REMFS and ADDFS made, the
/// GPT and the table written, and ADDGPT's partition mounted.
fn change(run: *Run, argv: *const [arg_count]usize) i32 {
    const dl = run.dl;
    const rb = run.rb;
    const handle = run.handle;

    if (argv[arg_gpt] != 0 and argv[arg_init] == 0) {
        _ = dl.PutStr("GPT goes with INIT: INIT GPT makes a GPT with a PowerOS container\n");
        return dos.RETURN_ERROR;
    }
    if (argv[arg_add] != 0 and argv[arg_addgpt] != 0) {
        _ = dl.PutStr("ADD and ADDGPT go in runs of their own: LOW, HIGH, SIZE and DOSTYPE are one partition's\n");
        return dos.RETURN_ERROR;
    }
    if (argv[arg_size] != 0 and (argv[arg_low] != 0 or argv[arg_high] != 0)) {
        _ = dl.PutStr("SIZE goes in place of LOW and HIGH\n");
        return dos.RETURN_ERROR;
    }
    if (argv[arg_size] != 0 and argv[arg_add] == 0 and argv[arg_addgpt] == 0) {
        _ = dl.PutStr("SIZE goes with ADD or ADDGPT\n");
        return dos.RETURN_ERROR;
    }
    if (argv[arg_addgpt] != 0 and (argv[arg_bootable] != 0 or argv[arg_boot_pri] != 0)) {
        _ = dl.PutStr("BOOTABLE and BOOTPRI are a table partition's: they go with ADD and CHANGE\n");
        return dos.RETURN_ERROR;
    }
    if (argv[arg_init] != 0) {
        const rc = initTable(run, argv);
        if (rc != dos.RETURN_OK) return rc;
    }
    if (rdargs.string(argv[arg_remove])) |name| {
        const part = rb.FindPartition(handle, name) orelse {
            _ = Printf(dl, "REMOVE: there is no partition %s\n", .{name});
            return dos.RETURN_ERROR;
        };
        rb.RemPartition(handle, part);
    }
    if (rdargs.string(argv[arg_remgpt])) |name| {
        const rc = remGpt(run, name);
        if (rc != dos.RETURN_OK) return rc;
    }
    if (rdargs.string(argv[arg_change])) |name| {
        const part = rb.FindPartition(handle, name) orelse {
            _ = Printf(dl, "CHANGE: there is no partition %s\n", .{name});
            return dos.RETURN_ERROR;
        };
        if (argv[arg_dostype] == 0 and argv[arg_bootable] == 0 and argv[arg_boot_pri] == 0) {
            _ = dl.PutStr("CHANGE: DOSTYPE, BOOTABLE, BOOTPRI or more say what changes\n");
            return dos.RETURN_ERROR;
        }
        if (rdargs.string(argv[arg_dostype])) |text| {
            part.block.environment.dos_type = parseDosType(text) orelse {
                _ = Printf(dl, MSG_BAD_DOSTYPE, .{ "DOSTYPE", text });
                return dos.RETURN_ERROR;
            };
        }
        if (argv[arg_bootable] != 0) part.block.flags |= hardblocks.PBFF_BOOTABLE;
        if (rdargs.number(argv[arg_boot_pri])) |pri| part.block.environment.boot_pri = @max(-128, @min(pri, 127));
        handle.flags |= rdb.RDBF_CHANGED;
    }
    if (rdargs.string(argv[arg_add])) |name| {
        const rc = add(run, argv, name);
        if (rc != dos.RETURN_OK) return rc;
    }
    if (rdargs.string(argv[arg_addgpt])) |name| {
        // INIT GPT puts it in before the container.
        if (run.made == null) {
            const rc = addGpt(run, argv, name);
            if (rc != dos.RETURN_OK) return rc;
        }
    }
    if (argv[arg_addfs] != 0 or argv[arg_remfs] != 0) {
        if (!keepsFileSystems(rb)) {
            _ = Printf(dl, "ADDFS, REMFS: %s 1.%d or later keeps file systems\n", .{ rdb.RDBNAME, @as(u32, file_systems_revision) });
            return dos.RETURN_ERROR;
        }
    }
    if (rdargs.string(argv[arg_remfs])) |text| {
        const dos_type = parseDosType(text) orelse {
            _ = Printf(dl, MSG_BAD_DOSTYPE, .{ "REMFS", text });
            return dos.RETURN_ERROR;
        };
        const file_system = fileSystemFor(run, dos_type) orelse {
            _ = Printf(dl, "REMFS: the table keeps no file system for %s\n", .{text});
            return dos.RETURN_ERROR;
        };
        rb.RemFileSystem(handle, file_system);
    }
    if (rdargs.string(argv[arg_addfs])) |path| {
        const text = rdargs.string(argv[arg_dostype]) orelse {
            _ = dl.PutStr("ADDFS: DOSTYPE says which partitions run it\n");
            return dos.RETURN_ERROR;
        };
        const dos_type = parseDosType(text) orelse {
            _ = Printf(dl, MSG_BAD_DOSTYPE, .{ "DOSTYPE", text });
            return dos.RETURN_ERROR;
        };
        var size: u32 = 0;
        const code = loadFile(run, path, &size) orelse return dos.RETURN_ERROR;
        defer run.sys.FreeVec(code);
        if (failed(run, "ADDFS", rb.AddFileSystem(handle, dos_type, code, size))) return dos.RETURN_ERROR;
    }

    // The GPT first: WriteRDB refuses a table in a container that is not
    // on the disk yet.
    const gpt_changed = rdb.RDBF_GPT | rdb.RDBF_GPTCHANGED;
    var wrote_gpt = false;
    if (readsGpt(rb) and handle.flags & gpt_changed == gpt_changed) {
        if (failed(run, "Writing the GPT", rb.WriteGPT(handle))) return dos.RETURN_ERROR;
        wrote_gpt = true;
    }
    // A GPT with no table in it - its partitions all FAT - has none to
    // write.
    const err = rb.WriteRDB(handle);
    if (err == rdb.RDBERR_NORDB and wrote_gpt) {
        _ = dl.PutStr("GPT written\n");
    } else {
        if (failed(run, "Writing the table", err)) return dos.RETURN_ERROR;
        _ = dl.PutStr(if (argv[arg_mount] != 0) "Table written\n" else "Table written: the partitions are mounted as it says at the next boot\n");
    }
    if (run.made) |part| {
        if (!clearFirstBlock(run, part)) return dos.RETURN_ERROR;
        return mountMade(run, part);
    }
    return dos.RETURN_OK;
}

/// ADD: a partition in the table, at LOW to HIGH, of SIZE at the first
/// free cylinders it fits in, or over the largest free run.
fn add(run: *Run, argv: *const [arg_count]usize, name: [*:0]const u8) i32 {
    const dl = run.dl;
    const rb = run.rb;
    const handle = run.handle;
    const low = rdargs.number(argv[arg_low]);
    const high = rdargs.number(argv[arg_high]);
    if ((low == null) != (high == null) or (low orelse 0) < 0 or (high orelse 0) < 0) {
        _ = dl.PutStr("ADD: LOW and HIGH go together, or are both left out for SIZE or the largest free run\n");
        return dos.RETURN_ERROR;
    }
    var dos_type: u32 = dos.flashfs.ID_FLASHFS_DISK;
    if (rdargs.string(argv[arg_dostype])) |text| {
        dos_type = parseDosType(text) orelse {
            _ = Printf(dl, MSG_BAD_DOSTYPE, .{ "DOSTYPE", text });
            return dos.RETURN_ERROR;
        };
    }
    var low_cyl: u32 = @intCast(low orelse 0);
    var high_cyl: u32 = @intCast(high orelse 0);
    if (rdargs.string(argv[arg_size])) |text| {
        const bytes = parseSize(text) orelse {
            _ = Printf(dl, MSG_BAD_SIZE, .{text});
            return dos.RETURN_ERROR;
        };
        const table = &handle.rdb;
        const cylinder_bytes = @as(u64, table.cyl_blocks) * table.block_bytes;
        if (cylinder_bytes == 0) {
            _ = failed(run, "ADD", rdb.RDBERR_NORDB);
            return dos.RETURN_ERROR;
        }
        const count = (bytes + cylinder_bytes - 1) / cylinder_bytes;
        low_cyl = freeCylinders(run, count) orelse {
            _ = Printf(dl, "ADD: no %s of the table's usable cylinders in a row are free\n", .{text});
            return dos.RETURN_ERROR;
        };
        high_cyl = @intCast(low_cyl + count - 1);
    }
    if (failed(run, "ADD", rb.AddPartition(handle, name, low_cyl, high_cyl, dos_type))) return dos.RETURN_ERROR;
    if (rb.FindPartition(handle, name)) |part| {
        if (argv[arg_bootable] != 0) part.block.flags |= hardblocks.PBFF_BOOTABLE;
        if (rdargs.number(argv[arg_boot_pri])) |pri| part.block.environment.boot_pri = @max(-128, @min(pri, 127));
    }
    return dos.RETURN_OK;
}

/// The first of the first `count` free cylinders in a row of the table's
/// usable ones, or null.
fn freeCylinders(run: *Run, count: u64) ?u32 {
    // A free run starts at the first usable cylinder or just past a
    // partition.
    var best: ?u64 = null;
    var first: u64 = run.handle.rdb.lo_cylinder;
    var part: ?*rdb.RDBPartition = null;
    while (true) {
        if (cylindersFree(run, first, count) and (best == null or first < best.?)) best = first;
        part = run.rb.NextPartition(run.handle, part);
        const p = part orelse break;
        first = @as(u64, p.block.environment.high_cyl) + 1;
    }
    return if (best) |cylinder| @intCast(cylinder) else null;
}

fn cylindersFree(run: *Run, first: u64, count: u64) bool {
    const last = first + count - 1;
    if (last > run.handle.rdb.hi_cylinder) return false;
    var part = run.rb.NextPartition(run.handle, null);
    while (part) |p| : (part = run.rb.NextPartition(run.handle, p)) {
        const env = &p.block.environment;
        if (first <= env.high_cyl and env.low_cyl <= last) return false;
    }
    return true;
}

/// ADDGPT: a basic data partition for FAT in the GPT, at LOW to HIGH (the
/// disk's blocks), of SIZE at the first free MiB it fits from, or over
/// the largest free run. It is `run.made`, mounted once it is written.
fn addGpt(run: *Run, argv: *const [arg_count]usize, name: [*:0]const u8) i32 {
    const dl = run.dl;
    const rb = run.rb;
    const handle = run.handle;
    if (!mountsFat(rb)) {
        _ = Printf(dl, "ADDGPT: %s 1.%d or later makes a FAT partition of a GPT\n", .{ rdb.RDBNAME, @as(u32, fat_revision) });
        return dos.RETURN_ERROR;
    }
    if (handle.flags & rdb.RDBF_GPT == 0 or handle.flags & rdb.RDBF_GPTDAMAGED != 0) {
        _ = failed(run, "ADDGPT", rdb.RDBERR_NOGPT);
        return dos.RETURN_ERROR;
    }
    const text = name[0..length(name)];
    if (!driveName(text)) {
        _ = Printf(dl, "ADDGPT: %s is no drive's name: one of 1 to %d characters, with no colon or slash\n", .{ name, @as(u32, dos.MAX_DEVICE_NAME) });
        return dos.RETURN_ERROR;
    }
    if (gptPartitionNamed(run, name) != null) {
        _ = Printf(dl, "ADDGPT: the GPT has a partition %s already\n", .{name});
        return dos.RETURN_ERROR;
    }
    var dos_type: u32 = dos.ID_MSDOS_DISK;
    if (rdargs.string(argv[arg_dostype])) |kind| {
        dos_type = parseDosType(kind) orelse {
            _ = Printf(dl, MSG_BAD_DOSTYPE, .{ "DOSTYPE", kind });
            return dos.RETURN_ERROR;
        };
        if (!dos.fat.isFatType(dos_type) or dos.fat.partitionedType(dos_type)) {
            _ = dl.PutStr("ADDGPT: a partition of the GPT is for FAT, DOSTYPE FAT, FAT32 or EXFAT; posfs goes in the table (ADD)\n");
            return dos.RETURN_ERROR;
        }
    }

    if (!dos.filesystems.suits(dos_type, handle.geometry.erase_size, false)) {
        _ = dl.PutStr("ADDGPT: FAT does not go on a medium that is erased a unit at a time\n");
        return dos.RETURN_ERROR;
    }

    var entry: gpt.Entry = .{ .partition_type_guid = gpt.TYPE_BASIC_DATA };
    gpt.setName(&entry, text);
    const low = rdargs.number(argv[arg_low]);
    const high = rdargs.number(argv[arg_high]);
    if ((low == null) != (high == null) or (low orelse 0) < 0 or (high orelse 0) < 0) {
        _ = dl.PutStr("ADDGPT: LOW and HIGH go together, or are both left out for SIZE or the largest free run\n");
        return dos.RETURN_ERROR;
    }
    entry.starting_lba = @intCast(low orelse 0);
    entry.ending_lba = @intCast(high orelse 0);
    if (rdargs.string(argv[arg_size])) |size| {
        const bytes = parseSize(size) orelse {
            _ = Printf(dl, MSG_BAD_SIZE, .{size});
            return dos.RETURN_ERROR;
        };
        const block_bytes = handle.geometry.sector_size;
        const count = (bytes + block_bytes - 1) / block_bytes;
        entry.starting_lba = freeBlocks(run, count) orelse {
            _ = Printf(dl, "ADDGPT: no %s of the disk outside the GPT's partitions are free in a row\n", .{size});
            if (hasContainer(run)) _ = dl.PutStr(MSG_NO_ROOM);
            return dos.RETURN_ERROR;
        };
        entry.ending_lba = entry.starting_lba + count - 1;
    }
    var err: i32 = rdb.RDBERR_OK;
    const part = rb.AddGPTPartition(handle, &entry, &err) orelse {
        if (err == rdb.RDBERR_RANGE) {
            _ = dl.PutStr("ADDGPT: blocks outside the usable ones, the wrong way round, another partition's, or a first block\n" ++
                "not on a MiB - or none free for the largest free run\n");
            if (hasContainer(run)) _ = dl.PutStr(MSG_NO_ROOM);
        } else {
            _ = failed(run, "ADDGPT", err);
        }
        return dos.RETURN_ERROR;
    };
    run.made = part;
    run.made_type = dos_type;
    return dos.RETURN_OK;
}

/// The partition ADDGPT made, mounted for FAT under its name and its
/// handler started, so that C:Format can give it a volume.
fn mountMade(run: *Run, part: *rdb.GPTPartition) i32 {
    const dl = run.dl;
    var text: [gpt.name_units:0]u8 = @splat(0);
    _ = gpt.nameText(&part.entry, &text);
    var name: rdb.MountName = @splat(0);
    const flags = rdb.RDBMF_START | rdb.RDBMF_FAT | rdb.mountFormat(dos.fat.formatOfType(run.made_type));
    const err = run.rb.MountGPTPartition(run.handle, part, @ptrCast(&text), &name, flags);
    if (!mountSaid(run, @ptrCast(&text), &name, err, gptSpan(run, part), false)) return dos.RETURN_WARN;
    _ = Printf(dl, "  (Format DRIVE %s: NAME <name> gives it a volume)\n", .{@as([*:0]const u8, @ptrCast(&name))});
    return dos.RETURN_OK;
}

/// The first block of the partition ADDGPT made cleared, so that what was
/// on it before is not taken for a volume, and the partition is a new one
/// MountGPTPartition mounts for FAT (RDBMF_FAT). False, and why printed,
/// when the device does not take the block.
fn clearFirstBlock(run: *Run, part: *const rdb.GPTPartition) bool {
    const sys = run.sys;
    const bytes = run.handle.geometry.sector_size;
    const port = sys.CreateMsgPort() orelse return notCleared(run, errorText(rdb.RDBERR_NOMEM));
    defer sys.DeleteMsgPort(port);
    const request = sys.CreateIORequest(port, @sizeOf(exec.IOStdReq)) orelse return notCleared(run, errorText(rdb.RDBERR_NOMEM));
    defer sys.DeleteIORequest(request);
    const block = sys.AllocVec(bytes, exec.MEMF_CLEAR) orelse return notCleared(run, errorText(rdb.RDBERR_NOMEM));
    defer sys.FreeVec(block);
    if (sys.OpenDevice(run.device, run.unit, request, 0) != 0) return notCleared(run, errorText(rdb.RDBERR_DEVICE));
    defer sys.CloseDevice(request);
    const io: *exec.IOStdReq = @ptrCast(@alignCast(request));
    io.req.command = exec.CMD_WRITE;
    io.data = block;
    io.length = bytes;
    io.offset = part.entry.starting_lba * bytes;
    if (sys.DoIO(request) != 0) return notCleared(run, errorText(rdb.RDBERR_IO));
    io.req.command = exec.CMD_UPDATE;
    _ = sys.DoIO(request);
    return true;
}

fn notCleared(run: *Run, why: [*:0]const u8) bool {
    _ = Printf(run.dl, "ADDGPT: the partition's first block is not cleared: %s\n", .{why});
    return false;
}

/// The first block of the first `count` free blocks in a row of the GPT's
/// usable ones that starts on a MiB, or null.
fn freeBlocks(run: *Run, count: u64) ?u64 {
    const handle = run.handle;
    const block_bytes = handle.geometry.sector_size;
    // A free run starts at the first usable block or just past a
    // partition, moved up to the next MiB.
    var best: ?u64 = null;
    var start = handle.gpt_header.first_usable_lba;
    var part: ?*rdb.GPTPartition = null;
    while (true) {
        const first = gpt.alignUp(start, block_bytes);
        if (blocksFree(run, first, count) and (best == null or first < best.?)) best = first;
        part = run.rb.NextGPTPartition(handle, part);
        const p = part orelse break;
        start = p.entry.ending_lba + 1;
    }
    return best;
}

fn blocksFree(run: *Run, first: u64, count: u64) bool {
    const last = first + count - 1;
    if (count == 0 or last > run.handle.gpt_header.last_usable_lba) return false;
    var part = run.rb.NextGPTPartition(run.handle, null);
    while (part) |p| : (part = run.rb.NextGPTPartition(run.handle, p)) {
        if (first <= p.entry.ending_lba and p.entry.starting_lba <= last) return false;
    }
    return true;
}

/// Whether the GPT has a PowerOS container.
fn hasContainer(run: *Run) bool {
    var part = run.rb.NextGPTPartition(run.handle, null);
    while (part) |p| : (part = run.rb.NextGPTPartition(run.handle, p)) {
        if (gpt.isContainer(&p.entry)) return true;
    }
    return false;
}

/// REMGPT: a partition taken out of the GPT, named or by its number; not
/// the container, which the table is in.
fn remGpt(run: *Run, name: [*:0]const u8) i32 {
    const dl = run.dl;
    const handle = run.handle;
    if (!readsGpt(run.rb) or handle.flags & rdb.RDBF_GPT == 0 or handle.flags & rdb.RDBF_GPTDAMAGED != 0) {
        _ = failed(run, "REMGPT", rdb.RDBERR_NOGPT);
        return dos.RETURN_ERROR;
    }
    const part = gptPartitionNamed(run, name) orelse gptPartitionNumbered(run, name) orelse {
        _ = Printf(dl, "REMGPT: the GPT has no partition %s\n", .{name});
        return dos.RETURN_ERROR;
    };
    if (gpt.isContainer(&part.entry)) {
        _ = Printf(dl, "REMGPT: %s is the PowerOS container, and every partition of the table in it: INIT GPT FORCE makes the disk anew\n", .{name});
        return dos.RETURN_ERROR;
    }
    run.rb.RemGPTPartition(handle, part);
    return dos.RETURN_OK;
}

/// The GPT partition whose entry has this name, letter case aside.
fn gptPartitionNamed(run: *Run, name: [*:0]const u8) ?*rdb.GPTPartition {
    var part = run.rb.NextGPTPartition(run.handle, null);
    while (part) |p| : (part = run.rb.NextGPTPartition(run.handle, p)) {
        var text: [gpt.name_units:0]u8 = @splat(0);
        if (sameText(name, gpt.nameText(&p.entry, &text))) return p;
    }
    return null;
}

/// The GPT partition of the entry a number names, from 1.
fn gptPartitionNumbered(run: *Run, text: [*:0]const u8) ?*rdb.GPTPartition {
    var number: u32 = 0;
    var at: usize = 0;
    while (text[at] >= '0' and text[at] <= '9') : (at += 1) {
        if (number > 0xFFFF) return null;
        number = number * 10 + (text[at] - '0');
    }
    if (at == 0 or text[at] != 0) return null;
    var part = run.rb.NextGPTPartition(run.handle, null);
    while (part) |p| : (part = run.rb.NextGPTPartition(run.handle, p)) {
        if (p.number == number) return p;
    }
    return null;
}

/// INIT: a fresh table in the GPT's container where the disk has one,
/// over the whole disk where it has none, or with GPT in the container
/// of a new GPT - after ADDGPT's partition, when there is one, so that
/// the container gets what that leaves. What the disk has is replaced
/// only with FORCE.
fn initTable(run: *Run, argv: *const [arg_count]usize) i32 {
    const dl = run.dl;
    const rb = run.rb;
    const handle = run.handle;
    const with_gpt = argv[arg_gpt] != 0;
    const force = argv[arg_force] != 0;
    const gpt_disk = readsGpt(rb) and handle.flags & rdb.RDBF_GPT != 0;
    if (with_gpt) {
        if (!readsGpt(rb)) {
            _ = Printf(dl, "INIT GPT: %s 1.%d or later writes a GPT\n", .{ rdb.RDBNAME, @as(u32, gpt_revision) });
            return dos.RETURN_ERROR;
        }
        if (!force and (gpt_disk or handle.flags & (rdb.RDBF_FOUND | rdb.RDBF_FOREIGN) != 0)) {
            _ = dl.PutStr("The disk has a table already: INIT GPT FORCE replaces it, and every partition with it\n");
            return dos.RETURN_ERROR;
        }
        if (failed(run, "INIT GPT", rb.InitGPT(handle))) return dos.RETURN_ERROR;
        if (rdargs.string(argv[arg_addgpt])) |name| {
            const rc = addGpt(run, argv, name);
            if (rc != dos.RETURN_OK) return rc;
        }
        var entry: gpt.Entry = .{ .partition_type_guid = gpt.TYPE_CONTAINER };
        gpt.setName(&entry, container_name);
        var err: i32 = rdb.RDBERR_OK;
        if (rb.AddGPTPartition(handle, &entry, &err) == null) {
            if (err == rdb.RDBERR_RANGE and run.made != null) {
                _ = dl.PutStr("  (ADDGPT's partition takes every free block: the GPT gets no PowerOS container)\n");
                return dos.RETURN_OK;
            }
            _ = failed(run, "INIT GPT", err);
            return dos.RETURN_ERROR;
        }
    } else if (gpt_disk and handle.flags & rdb.RDBF_CONTAINER == 0) {
        if (!force) {
            _ = dl.PutStr("The disk has a GPT and no PowerOS container: INIT FORCE replaces the GPT with a table over the whole disk,\n" ++
                "and INIT GPT FORCE with a new GPT and a container; every partition on the disk is lost either way\n");
            return dos.RETURN_ERROR;
        }
        rb.RemGPT(handle);
    } else if (handle.flags & rdb.RDBF_FOUND != 0 and !force) {
        _ = dl.PutStr("The disk has a table already: INIT FORCE replaces it, and every partition with it\n");
        return dos.RETURN_ERROR;
    }
    if (failed(run, "INIT", rb.InitRDB(handle))) return dos.RETURN_ERROR;
    return dos.RETURN_OK;
}

/// Whether a call failed; if it did, what it said.
fn failed(run: *Run, what: [*:0]const u8, err: i32) bool {
    if (err == rdb.RDBERR_OK) return false;
    _ = Printf(run.dl, "%s: %s\n", .{ what, errorText(err) });
    return true;
}

fn errorText(err: i32) [*:0]const u8 {
    return switch (err) {
        rdb.RDBERR_NOMEM => "not enough memory",
        rdb.RDBERR_DEVICE => "no such device or unit, or no medium in it",
        rdb.RDBERR_IO => "the device refused a transfer",
        rdb.RDBERR_NORDB => "the disk has no table (INIT makes one)",
        rdb.RDBERR_BLOCKSIZE => "the medium cannot take blocks of this size",
        rdb.RDBERR_NAME => "a name that is empty, too long, holds a colon or a slash, or is taken",
        rdb.RDBERR_RANGE => "cylinders outside the usable ones, the wrong way round, or taken",
        rdb.RDBERR_FULL => "no room in the table's blocks for another partition, or for the file systems' code",
        rdb.RDBERR_FILESYSTEM => "not a handler's load file for this machine",
        rdb.RDBERR_CHANGED => "the medium in the unit is not the one the table was read from",
        rdb.RDBERR_GPT => "the disk's GPT has no PowerOS container for it",
        rdb.RDBERR_NOGPT => "the disk has no sound GPT (INIT GPT makes one)",
        else => "failed",
    };
}

/// A DosType as written on the command line: a file system's name (FAT,
/// FAT32, EXFAT, POSFS), `0x` and a number, or up to four characters with
/// `\<n>` for a byte by its value, the rest zero.
fn parseDosType(text: [*:0]const u8) ?u32 {
    for (named_types) |named| {
        if (sameText(text, named.name)) return named.dos_type;
    }
    if (text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        var value: u32 = 0;
        var at: usize = 2;
        if (text[at] == 0) return null;
        while (text[at] != 0) : (at += 1) {
            const digit: u32 = switch (text[at]) {
                '0'...'9' => text[at] - '0',
                'a'...'f' => text[at] - 'a' + 10,
                'A'...'F' => text[at] - 'A' + 10,
                else => return null,
            };
            if (at >= 10) return null;
            value = value << 4 | digit;
        }
        return value;
    }
    var value: u32 = 0;
    var chars: u32 = 0;
    var at: usize = 0;
    while (text[at] != 0) : (chars += 1) {
        if (chars == 4) return null;
        var byte: u32 = text[at];
        at += 1;
        if (byte == '\\') {
            byte = 0;
            var digits: u32 = 0;
            while (text[at] >= '0' and text[at] <= '9') : (at += 1) {
                byte = byte * 10 + (text[at] - '0');
                digits += 1;
            }
            if (digits == 0 or byte > 255) return null;
        }
        value = value << 8 | byte;
    }
    if (chars == 0) return null;
    while (chars < 4) : (chars += 1) value <<= 8;
    return value;
}

/// SIZE in bytes: a number, with K, M, G or T after it for KiB, MiB, GiB
/// or TiB; null for anything else, or none.
fn parseSize(text: [*:0]const u8) ?u64 {
    var value: u64 = 0;
    var at: usize = 0;
    while (text[at] >= '0' and text[at] <= '9') : (at += 1) {
        const times = @mulWithOverflow(value, 10);
        if (times[1] != 0) return null;
        const sum = @addWithOverflow(times[0], text[at] - '0');
        if (sum[1] != 0) return null;
        value = sum[0];
    }
    if (at == 0) return null;
    const shift: u6 = switch (upper(text[at])) {
        0 => 0,
        'K' => 10,
        'M' => 20,
        'G' => 30,
        'T' => 40,
        else => return null,
    };
    if (text[at] != 0 and text[at + 1] != 0) return null;
    if (value == 0 or value > @as(u64, 0xFFFF_FFFF_FFFF_FFFF) >> shift) return null;
    return value << shift;
}

/// Whether a name may be a drive's: 1 to MAX_DEVICE_NAME characters, no
/// colon and no slash.
fn driveName(text: []const u8) bool {
    if (text.len == 0 or text.len > dos.MAX_DEVICE_NAME) return false;
    for (text) |char| {
        if (char == ':' or char == '/') return false;
    }
    return true;
}

/// Whether a word of the command line is `name`, letter case aside.
fn sameText(text: [*:0]const u8, name: []const u8) bool {
    for (name, 0..) |char, at| {
        if (upper(text[at]) != upper(char)) return false;
    }
    return text[name.len] == 0;
}

fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - ('a' - 'A') else char;
}

fn length(text: [*:0]const u8) usize {
    var at: usize = 0;
    while (text[at] != 0) at += 1;
    return at;
}

// --- What it prints ---------------------------------------------------------

fn showDrive(run: *Run, device: [*:0]const u8, unit: u32) void {
    const dl = run.dl;
    const geo = &run.handle.geometry;
    // In a container `geometry` counts the container's blocks; the medium
    // is the whole disk.
    const blocks: u64 = if (readsGpt(run.rb)) run.handle.disk_blocks else geo.total_sectors;
    const cylinders: u32 = if (blocks == geo.total_sectors) geo.cylinders else @intCast(@min(blocks / @max(geo.cyl_sectors, 1), 0xFFFF_FFFF));
    var size: [16:0]u8 = @splat(0);
    bytesAsText(&size, blocks * geo.sector_size);

    _ = Printf(dl, "%s unit %d\n", .{ device, unit });
    _ = Printf(dl, "  Medium       %ld blocks of %d bytes (%s)\n", .{
        blocks,
        geo.sector_size,
        @as([*:0]const u8, @ptrCast(&size)),
    });
    _ = Printf(dl, "  Geometry     %u cylinders, %u head(s), %u block(s) per track\n", .{
        cylinders,
        geo.heads,
        geo.track_sectors,
    });
    if (!run.full) return;
    if (geo.erase_size != 0) {
        _ = Printf(dl, "  Erase        %d bytes at a time\n", .{geo.erase_size});
    }
    if (geo.write_size != 0) {
        _ = Printf(dl, "  Write        %d bytes at a time\n", .{geo.write_size});
    }
    if (geo.map_base != 0) {
        _ = Printf(dl, "  Mapped at    0x%08zx, so a read costs no request\n", .{geo.map_base});
    }
}

fn showRdb(run: *Run, at: u32, table: *const hardblocks.RigidDiskBlock) void {
    const dl = run.dl;
    if (run.handle.flags & rdb.RDBF_CONTAINER != 0) {
        const blocks = run.handle.geometry.total_sectors;
        var size: [16:0]u8 = @splat(0);
        bytesAsText(&size, blocks * run.handle.geometry.sector_size);
        _ = Printf(dl, "\nRigidDiskBlock in block %d of the container\n", .{at});
        _ = Printf(dl, "  Container    blocks %ld to %ld of the disk (%s)\n", .{
            run.handle.container,
            run.handle.container + blocks - 1,
            @as([*:0]const u8, @ptrCast(&size)),
        });
    } else {
        _ = Printf(dl, "\nRigidDiskBlock in block %d\n", .{at});
    }
    _ = Printf(dl, "  Blocks       %d bytes\n", .{table.block_bytes});
    _ = Printf(dl, "  Drive        %u cylinders, %u head(s), %u sector(s) per track\n", .{
        table.cylinders,
        table.heads,
        table.sectors,
    });
    _ = Printf(dl, "  Kept back    blocks %d to %d, for these structures\n", .{
        table.rdb_blocks_lo,
        table.rdb_blocks_hi,
    });
    _ = Printf(dl, "  Usable       cylinders %u to %u, %u block(s) each\n", .{
        table.lo_cylinder,
        table.hi_cylinder,
        table.cyl_blocks,
    });
    if (!run.full) return;

    var where: [16:0]u8 = @splat(0);
    blockAsText(&where, table.partition_list);
    _ = Printf(dl, "  Partitions   %s\n", .{@as([*:0]const u8, @ptrCast(&where))});
    blockAsText(&where, table.bad_block_list);
    _ = Printf(dl, "  Bad blocks   %s\n", .{@as([*:0]const u8, @ptrCast(&where))});
    blockAsText(&where, table.file_sys_header_list);
    _ = Printf(dl, "  File systems %s\n", .{@as([*:0]const u8, @ptrCast(&where))});

    identity(run, "  Disk         ", &table.disk_vendor, &table.disk_product, &table.disk_revision);
    identity(run, "  Controller   ", &table.controller_vendor, &table.controller_product, &table.controller_revision);
    _ = Printf(dl, "  Flags        0x%08x, host id %d\n", .{ table.flags, table.host_id });
}

/// The vendor, product and revision strings a drive carries, when it
/// carries any. They are fixed-width and are not NUL-terminated.
fn identity(
    run: *Run,
    label: [*:0]const u8,
    vendor: []const u8,
    product: []const u8,
    revision: []const u8,
) void {
    var text: [40:0]u8 = @splat(0);
    var at: usize = 0;
    at += trimmed(text[at..], vendor);
    if (at != 0) {
        text[at] = ' ';
        at += 1;
    }
    at += trimmed(text[at..], product);
    const before_rev = at;
    if (at != 0) {
        text[at] = ' ';
        at += 1;
    }
    const rev = trimmed(text[at..], revision);
    at = if (rev == 0) before_rev else at + rev;
    text[at] = 0;
    if (at == 0) return; // a drive that says nothing about itself
    _ = Printf(run.dl, "%s%s\n", .{ label, @as([*:0]const u8, @ptrCast(&text)) });
}

fn showPartitions(run: *Run) void {
    const dl = run.dl;
    const rb = run.rb;
    _ = dl.PutStr("\nPartitions\n");
    _ = Printf(dl, row, .{ "Name", "Block", "Cylinders", "Blocks", "Size", "File system", "Flags" });
    _ = Printf(dl, row, .{ "--------", "-----", "----------------", "---------", "-------", "----------------", "-----" });

    var part = rb.NextPartition(run.handle, null);
    if (part == null) _ = dl.PutStr(MSG_NO_PARTS);
    while (part) |p| : (part = rb.NextPartition(run.handle, p)) {
        partitionRow(run, p.at, &p.block);
        if (run.full) partitionDetail(run, &p.block);
    }
}

/// The file systems the table keeps, when it keeps any: each one's
/// DosType, name, version, size, header block and code blocks, and
/// whether its partitions run it or the ROM's handler.
fn showFileSystems(run: *Run) void {
    const dl = run.dl;
    const rb = run.rb;
    const first = rb.NextFileSystem(run.handle, null) orelse return;
    _ = dl.PutStr("\nFile systems\n");
    _ = Printf(dl, fs_row, .{ "DosType", "Name", "Version", "Size", "Block", "Blocks", "Runs" });
    _ = Printf(dl, fs_row, .{ "----------------", "--------------", "-------", "-------", "-----", "------", "----" });
    var file_system: ?*rdb.RDBFileSystem = first;
    while (file_system) |fs| : (file_system = rb.NextFileSystem(run.handle, fs)) {
        const header = &fs.header;
        var kind: [20:0]u8 = @splat(0);
        dosTypeAsText(&kind, header.dos_type);
        const name: [*:0]const u8 = if (dos.filesystems.of(header.dos_type)) |known| known.name else "-";
        var version: [16:0]u8 = @splat(0);
        _ = versionText(&version, header.version);
        var size: [16:0]u8 = @splat(0);
        bytesAsText(&size, fs.size);
        var block_text: [12:0]u8 = @splat(0);
        var blocks_text: [12:0]u8 = @splat(0);
        if (fs.at == hardblocks.end_of_list) {
            _ = copy(&block_text, "-");
            _ = copy(&blocks_text, "-");
        } else {
            _ = decimal(&block_text, fs.at);
            _ = decimal(&blocks_text, fs.blocks);
        }
        // Which code a partition of the DosType runs: the table's, or the
        // ROM's handler when that is as new.
        var runs: [24:0]u8 = @splat(0);
        const rom = dos.filesystems.romVersion(run.sys, header.dos_type);
        if (dos.filesystems.storedWins(header.version, rom)) {
            _ = copy(&runs, "this");
        } else {
            const at = copy(&runs, "ROM's ");
            _ = versionText(runs[at..], rom.?);
        }
        _ = Printf(dl, fs_row, .{
            @as([*:0]const u8, @ptrCast(&kind)),
            name,
            @as([*:0]const u8, @ptrCast(&version)),
            @as([*:0]const u8, @ptrCast(&size)),
            @as([*:0]const u8, @ptrCast(&block_text)),
            @as([*:0]const u8, @ptrCast(&blocks_text)),
            @as([*:0]const u8, @ptrCast(&runs)),
        });
    }
}

/// Whether the library has the calls for the file systems a table keeps.
fn keepsFileSystems(rb: *RDBBase) bool {
    const lib = rb.lib();
    return lib.version > 1 or lib.revision >= file_systems_revision;
}

/// Whether the library mounts a new GPT partition for FAT (RDBMF_FAT).
fn mountsFat(rb: *RDBBase) bool {
    const lib = rb.lib();
    return lib.version > 1 or lib.revision >= fat_revision;
}

/// Whether the library reads and writes a GPT; an older one's handle has
/// none of its fields.
fn readsGpt(rb: *RDBBase) bool {
    const lib = rb.lib();
    return lib.version > 1 or lib.revision >= gpt_revision;
}

/// The GPT: where its blocks are, and each used entry.
fn showGpt(run: *Run) void {
    const dl = run.dl;
    const handle = run.handle;
    const header = &handle.gpt_header;
    _ = dl.PutStr("\nGPT\n");
    if (handle.flags & rdb.RDBF_GPTDAMAGED != 0) return;
    var guid: [gpt.guid_text_len:0]u8 = @splat(0);
    gpt.formatGuid(&header.disk_guid, &guid);
    _ = Printf(dl, "  Disk         %s\n", .{@as([*:0]const u8, @ptrCast(&guid))});
    _ = Printf(dl, "  Usable       blocks %ld to %ld\n", .{ header.first_usable_lba, header.last_usable_lba });
    if (run.full) {
        _ = Printf(dl, "  Entries      %d of %d bytes from block %ld; the copy's header in block %ld\n", .{
            header.number_of_partition_entries,
            header.size_of_partition_entry,
            header.partition_entry_lba,
            header.alternate_lba,
        });
    }
    if (handle.flags & rdb.RDBF_GPTCHANGED != 0) {
        _ = dl.PutStr("  (read from the copy at the end: the one in block 1 is not sound, and a change written mends it)\n");
    }

    _ = dl.PutStr("\n");
    _ = Printf(dl, gpt_row, .{ "#", "First", "Last", "Size", "Type", "Name", "Flags" });
    _ = Printf(dl, gpt_row, .{ "---", "----------", "----------", "-------", "------------------", "----------------", "-----" });
    var part = run.rb.NextGPTPartition(handle, null);
    if (part == null) _ = dl.PutStr(MSG_NO_PARTS);
    while (part) |p| : (part = run.rb.NextGPTPartition(handle, p)) {
        gptRow(run, p);
    }
}

fn gptRow(run: *Run, part: *const rdb.GPTPartition) void {
    const handle = run.handle;
    const entry = &part.entry;
    var number: [12:0]u8 = @splat(0);
    _ = decimal(&number, part.number);
    var first: [24:0]u8 = @splat(0);
    _ = decimal(&first, entry.starting_lba);
    var last: [24:0]u8 = @splat(0);
    _ = decimal(&last, entry.ending_lba);
    var size: [16:0]u8 = @splat(0);
    bytesAsText(&size, (entry.ending_lba - entry.starting_lba + 1) * handle.geometry.sector_size);

    // A type with no name is shown by its GUID.
    var guid: [gpt.guid_text_len:0]u8 = @splat(0);
    const kind: [*:0]const u8 = gpt.typeName(&entry.partition_type_guid) orelse kind: {
        gpt.formatGuid(&entry.partition_type_guid, &guid);
        break :kind @ptrCast(&guid);
    };
    var name: [gpt.name_units:0]u8 = @splat(0);
    if (gpt.nameText(entry, &name).len == 0) _ = copy(&name, "-");

    var flags: [48:0]u8 = @splat(0);
    var at: usize = 0;
    // The container the table shown is in.
    const holds_table = handle.flags & (rdb.RDBF_CONTAINER | rdb.RDBF_FOUND) == rdb.RDBF_CONTAINER | rdb.RDBF_FOUND;
    if (holds_table and gpt.isContainer(entry) and entry.starting_lba == handle.container) {
        at += word(flags[at..], at, "table");
    }
    if (entry.attributes & gpt.ATTR_NO_AUTOMOUNT != 0) at += word(flags[at..], at, "nomount");
    if (entry.attributes & gpt.ATTR_REQUIRED != 0) at += word(flags[at..], at, "required");
    if (entry.attributes & gpt.ATTR_LEGACY_BOOTABLE != 0) at += word(flags[at..], at, "boot");
    if (at == 0) at += copy(flags[at..], "-");
    flags[at] = 0;

    _ = Printf(run.dl, gpt_row, .{
        @as([*:0]const u8, @ptrCast(&number)),
        @as([*:0]const u8, @ptrCast(&first)),
        @as([*:0]const u8, @ptrCast(&last)),
        @as([*:0]const u8, @ptrCast(&size)),
        kind,
        @as([*:0]const u8, @ptrCast(&name)),
        @as([*:0]const u8, @ptrCast(&flags)),
    });
    if (!run.full) return;
    gpt.formatGuid(&entry.unique_partition_guid, &guid);
    _ = Printf(run.dl, "      GUID         %s\n", .{@as([*:0]const u8, @ptrCast(&guid))});
    _ = Printf(run.dl, "      Attributes   0x%016lx\n\n", .{entry.attributes});
}

/// The file system the table keeps for a DosType, or null.
fn fileSystemFor(run: *Run, dos_type: u32) ?*rdb.RDBFileSystem {
    var file_system = run.rb.NextFileSystem(run.handle, null);
    while (file_system) |fs| : (file_system = run.rb.NextFileSystem(run.handle, fs)) {
        if (fs.header.dos_type == dos_type) return fs;
    }
    return null;
}

/// A file read whole into memory of its own, its size in `size`; null,
/// and why printed, when it cannot be.
fn loadFile(run: *Run, path: [*:0]const u8, size: *u32) ?[*]u8 {
    const dl = run.dl;
    const fh = dl.Open(path, dos.MODE_OLDFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), path);
        return null;
    };
    defer _ = dl.Close(fh);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.ExamineFH(fh, &fib)) {
        _ = dl.PrintFault(dl.IoErr(), path);
        return null;
    }
    if (fib.size == 0 or fib.size > 0xFFFF_FFFF) {
        _ = Printf(dl, "ADDFS: %s is empty or too large\n", .{path});
        return null;
    }
    const bytes: u32 = @intCast(fib.size);
    const block: [*]u8 = @ptrCast(run.sys.AllocVec(bytes, exec.MEMF_ANY) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, path);
        return null;
    });
    if (dl.Read(fh, block, @intCast(bytes)) != bytes) {
        _ = dl.PrintFault(dl.IoErr(), path);
        run.sys.FreeVec(block);
        return null;
    }
    size.* = bytes;
    return block;
}

fn partitionRow(run: *Run, block: u32, part: *const hardblocks.PartitionBlock) void {
    const env = &part.environment;

    var name: [33:0]u8 = @splat(0);
    _ = trimmed(&name, &part.drive_name);

    var block_text: [12:0]u8 = @splat(0);
    _ = decimal(&block_text, block);

    var cylinders: [25:0]u8 = @splat(0);
    var at = decimal(&cylinders, env.low_cyl);
    at += copy(cylinders[at..], " to ");
    at += decimal(cylinders[at..], env.high_cyl);
    cylinders[at] = 0;

    var blocks_text: [24:0]u8 = @splat(0);
    _ = decimal(&blocks_text, env.blocks());

    var size: [16:0]u8 = @splat(0);
    bytesAsText(&size, env.blocks() * env.size_block);

    var kind: [20:0]u8 = @splat(0);
    dosTypeAsText(&kind, env.dos_type);

    var flags: [32:0]u8 = @splat(0);
    at = 0;
    if (part.flags & hardblocks.PBFF_BOOTABLE != 0) at += word(flags[at..], at, "boot");
    if (part.flags & hardblocks.PBFF_NOMOUNT != 0) at += word(flags[at..], at, "nomount");
    // Whether the device list has a node of this name: what the RDB asked
    // for and what the system actually did are not the same thing.
    if (mounted(run, @ptrCast(&name))) at += word(flags[at..], at, "mounted");
    if (at == 0) at += copy(flags[at..], "-");
    flags[at] = 0;

    _ = Printf(run.dl, row, .{
        @as([*:0]const u8, @ptrCast(&name)),
        @as([*:0]const u8, @ptrCast(&block_text)),
        @as([*:0]const u8, @ptrCast(&cylinders)),
        @as([*:0]const u8, @ptrCast(&blocks_text)),
        @as([*:0]const u8, @ptrCast(&size)),
        @as([*:0]const u8, @ptrCast(&kind)),
        @as([*:0]const u8, @ptrCast(&flags)),
    });
}

/// Everything the environment says, for FULL. This is what a handler is
/// handed when the partition is mounted.
fn partitionDetail(run: *Run, part: *const hardblocks.PartitionBlock) void {
    const dl = run.dl;
    const env = &part.environment;
    _ = Printf(dl, "      Block size   %d bytes, %d sector(s) per block\n", .{ env.size_block, env.sector_per_block });
    _ = Printf(dl, "      Geometry     %u surface(s), %u block(s) per track, interleave %u\n", .{
        env.surfaces,
        env.blocks_per_track,
        env.interleave,
    });
    _ = Printf(dl, "      Set aside    %d block(s) at the start, %d at the end\n", .{ env.reserved, env.pre_alloc });
    _ = Printf(dl, "      Buffers      %d, in memory of type 0x%08x\n", .{ env.num_buffers, env.buf_mem_type });
    _ = Printf(dl, "      Transfer     at most 0x%08x bytes, address mask 0x%08x\n", .{ env.max_transfer, env.mask });
    _ = Printf(dl, "      Boot         priority %d\n", .{env.boot_pri});
    _ = Printf(dl, "      Device flags 0x%08x, table size %d\n", .{ part.dev_flags, env.table_size });
    _ = dl.PutStr("\n");
}

// --- Text -------------------------------------------------------------------

/// A DosType the way a disk labels itself: four characters, an unprintable
/// one written `\<n>`, and the longword after it.
fn dosTypeAsText(into: *[20:0]u8, value: u32) void {
    var at: usize = 0;
    var shift: u5 = 24;
    while (true) : (shift -= 8) {
        const b: u8 = @truncate(value >> shift);
        if (b >= 0x20 and b < 0x7F) {
            into[at] = b;
            at += 1;
        } else {
            into[at] = '\\';
            at += 1;
            at += decimal(into[at..], b);
        }
        if (shift == 0) break;
    }
    at += copy(into[at..], " 0x");
    at += hex(into[at..], value);
    into[at] = 0;
}

/// A version as fhb_Version holds it, version << 16 | revision: "2.5".
/// Answers how many bytes it wrote.
fn versionText(into: []u8, value: u32) usize {
    var at = decimal(into, value >> 16);
    at += copy(into[at..], ".");
    at += decimal(into[at..], value & 0xFFFF);
    return at;
}

/// A byte count as a person reads it: "14.9M", "4096" for something small.
fn bytesAsText(into: *[16:0]u8, bytes: u64) void {
    const units = [_]struct { scale: u64, tag: []const u8 }{
        .{ .scale = 1 << 30, .tag = "G" },
        .{ .scale = 1 << 20, .tag = "M" },
        .{ .scale = 1 << 10, .tag = "K" },
    };
    for (units) |unit| {
        if (bytes < unit.scale) continue;
        const whole = bytes / unit.scale;
        const tenths = (bytes % unit.scale) * 10 / unit.scale;
        var at = decimal(into, whole);
        if (whole < 100) { // a tenth is worth showing while it still tells you something
            into[at] = '.';
            at += 1;
            at += decimal(into[at..], tenths);
        }
        at += copy(into[at..], unit.tag);
        into[at] = 0;
        return;
    }
    const at = decimal(into, bytes);
    into[at] = 0;
}

/// A list head: the block it names, or that there is none.
fn blockAsText(into: *[16:0]u8, block: u32) void {
    if (block == hardblocks.end_of_list) {
        into[copy(into, "none")] = 0;
        return;
    }
    var at = copy(into, "block ");
    at += decimal(into[at..], block);
    into[at] = 0;
}

/// A fixed-width field copied out without the spaces and NULs around it.
/// Answers how many bytes it wrote.
fn trimmed(into: []u8, field: []const u8) usize {
    var last: usize = 0;
    for (field, 0..) |b, i| {
        if (b != 0 and b != ' ') last = i + 1;
    }
    var at: usize = 0;
    while (at < last and at + 1 < into.len) : (at += 1) into[at] = field[at];
    into[at] = 0;
    return at;
}

/// A word onto a list of them, with ", " in front of it when it is not the
/// first. Answers how many bytes it wrote.
fn word(into: []u8, already: usize, text: []const u8) usize {
    var at: usize = 0;
    if (already != 0) at += copy(into[at..], ", ");
    at += copy(into[at..], text);
    return at;
}

/// Whether a device node of that name is on the device list, i.e. whether
/// this partition is mounted at the moment.
fn mounted(run: *Run, name: [*:0]const u8) bool {
    const dl = run.dl;
    if (name[0] == 0) return false;
    const flags = dos.LDF_DEVICES | dos.LDF_READ;
    const start = dl.LockDosList(flags) orelse return false;
    const found = dl.FindDosEntry(start, name, dos.LDF_DEVICES) != null;
    dl.UnLockDosList(flags);
    return found;
}

fn copy(into: []u8, text: []const u8) usize {
    var at: usize = 0;
    while (at < text.len and at + 1 < into.len) : (at += 1) into[at] = text[at];
    return at;
}

fn decimal(into: []u8, value: u64) usize {
    var digits: [20]u8 = undefined;
    var n: usize = 0;
    var left = value;
    while (true) {
        digits[n] = '0' + @as(u8, @intCast(left % 10));
        n += 1;
        left /= 10;
        if (left == 0) break;
    }
    var at: usize = 0;
    while (n > 0 and at + 1 < into.len) {
        n -= 1;
        into[at] = digits[n];
        at += 1;
    }
    return at;
}

fn hex(into: []u8, value: u32) usize {
    const digits = "0123456789ABCDEF";
    var at: usize = 0;
    var shift: u5 = 28;
    while (at + 1 < into.len) : (shift -= 4) {
        into[at] = digits[@as(u4, @truncate(value >> shift))];
        at += 1;
        if (shift == 0) break;
    }
    return at;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
