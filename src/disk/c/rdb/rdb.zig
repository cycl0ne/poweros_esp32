// SPDX-License-Identifier: MIT
//! RDB: what a disk says about itself - the RigidDiskBlock in its first
//! blocks and the partitions hanging off it - and changes to it, through
//! LIBS:rdb.library. Built against the SDK only.
//!
//!   RDB DEVICE,UNIT/K/N,FULL/S,INIT/S,FORCE/S,ADD/K,LOW/K/N,HIGH/K/N,
//!       DOSTYPE/K,BOOTABLE/S,REMOVE/K,CHANGE/K,ADDFS/K,REMFS/K,BOOTPRI/K/N,
//!       GPT/S
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
//!
//! The device is an exec device with trackdisk's commands, so anything
//! that answers TD_GETGEOMETRY and CMD_READ can be read. A change is made
//! in the order INIT, REMOVE, CHANGE, ADD, REMFS, ADDFS, then the table
//! is written as a whole and printed. Only the table's own blocks are written: what is on
//! a partition's cylinders stays, so a partition CHANGE gives another
//! DosType is formatted afterwards (C:Format) for its new file system.
//! RDB mounts nothing: a disk's table is read when the system starts, so
//! a partition added, changed or taken out is mounted as it now says at
//! the next start (a program mounts a new one at once with
//! rdb.library's MountPartition).
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
//! takes it the same way (`FLS\0`, or `FLS` with the zero left off) or as
//! a number (`0x464C5300`); without it a partition ADD makes is for the
//! flash file system. CHANGE takes DOSTYPE, BOOTABLE, BOOTPRI or more for
//! the partition it names: posfs's is `POS`.
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
const VERSION_STRING = "\x00$VER: RDB 1.5 (19.10.2026)\r\n";

const template = "DEVICE,UNIT/K/N,FULL/S,INIT/S,FORCE/S,ADD/K,LOW/K/N,HIGH/K/N,DOSTYPE/K,BOOTABLE/S,REMOVE/K,CHANGE/K,ADDFS/K,REMFS/K,BOOTPRI/K/N,GPT/S";
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
const arg_count = 16;

/// The disk this system boots from, when nothing else is named.
const default_device = "flash.device";

/// The rdb.library that keeps file systems in a table.
const file_systems_revision = 3;

/// The rdb.library that reads and writes a GPT.
const gpt_revision = 4;

/// The name INIT GPT gives the container.
const container_name = "PowerOS";

const MSG_NO_RDB = "%s unit %d has no RigidDiskBlock in its first %d blocks\n";
const MSG_FOREIGN = "%s unit %d has a RigidDiskBlock for another block size\n";
const MSG_NO_CONTAINER = "%s unit %d has a GPT and no PowerOS container in it\n";
const MSG_EMPTY_CONTAINER = "%s unit %d has a PowerOS container with no RigidDiskBlock in it (INIT makes one)\n";
const MSG_NO_PARTS = "  (no partitions)\n";

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
    full: bool,
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

    var run: Run = .{ .sys = sys, .dl = dl, .rb = rb, .handle = handle, .full = argv[arg_full] != 0 };
    showDrive(&run, device, unit);

    if (argv[arg_init] != 0 or argv[arg_add] != 0 or argv[arg_remove] != 0 or argv[arg_change] != 0 or
        argv[arg_addfs] != 0 or argv[arg_remfs] != 0)
    {
        const rc = change(&run, &argv);
        if (rc != dos.RETURN_OK) return rc;
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
        return dos.RETURN_WARN;
    }
    showRdb(&run, handle.block, &handle.rdb);
    showPartitions(&run);
    if (keepsFileSystems(rb)) showFileSystems(&run);
    if (handle.flags & rdb.RDBF_DAMAGED != 0) {
        _ = dl.PutStr("  (a chain of the table breaks at a block that is not sound: what follows it is not shown)\n");
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}

/// INIT, REMOVE, CHANGE and ADD made to the table, and the table written.
fn change(run: *Run, argv: *const [arg_count]usize) i32 {
    const dl = run.dl;
    const rb = run.rb;
    const handle = run.handle;

    if (argv[arg_gpt] != 0 and argv[arg_init] == 0) {
        _ = dl.PutStr("GPT goes with INIT: INIT GPT makes a GPT with a PowerOS container\n");
        return dos.RETURN_ERROR;
    }
    if (argv[arg_init] != 0) {
        const rc = initTable(run, argv[arg_gpt] != 0, argv[arg_force] != 0);
        if (rc != dos.RETURN_OK) return rc;
    }
    if (rdargs.string(argv[arg_remove])) |name| {
        const part = rb.FindPartition(handle, name) orelse {
            _ = Printf(dl, "REMOVE: there is no partition %s\n", .{name});
            return dos.RETURN_ERROR;
        };
        rb.RemPartition(handle, part);
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
                _ = Printf(dl, "DOSTYPE: %s is neither four characters nor a number\n", .{text});
                return dos.RETURN_ERROR;
            };
        }
        if (argv[arg_bootable] != 0) part.block.flags |= hardblocks.PBFF_BOOTABLE;
        if (rdargs.number(argv[arg_boot_pri])) |pri| part.block.environment.boot_pri = @max(-128, @min(pri, 127));
        handle.flags |= rdb.RDBF_CHANGED;
    }
    if (rdargs.string(argv[arg_add])) |name| {
        const low = rdargs.number(argv[arg_low]);
        const high = rdargs.number(argv[arg_high]);
        if ((low == null) != (high == null) or (low orelse 0) < 0 or (high orelse 0) < 0) {
            _ = dl.PutStr("ADD: LOW and HIGH go together, or are both left out for the largest free run\n");
            return dos.RETURN_ERROR;
        }
        var dos_type: u32 = dos.flashfs.ID_FLASHFS_DISK;
        if (rdargs.string(argv[arg_dostype])) |text| {
            dos_type = parseDosType(text) orelse {
                _ = Printf(dl, "DOSTYPE: %s is neither four characters nor a number\n", .{text});
                return dos.RETURN_ERROR;
            };
        }
        const low_cyl: u32 = @intCast(low orelse 0);
        const high_cyl: u32 = @intCast(high orelse 0);
        if (failed(run, "ADD", rb.AddPartition(handle, name, low_cyl, high_cyl, dos_type))) return dos.RETURN_ERROR;
        if (rb.FindPartition(handle, name)) |part| {
            if (argv[arg_bootable] != 0) part.block.flags |= hardblocks.PBFF_BOOTABLE;
            if (rdargs.number(argv[arg_boot_pri])) |pri| part.block.environment.boot_pri = @max(-128, @min(pri, 127));
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
            _ = Printf(dl, "REMFS: %s is neither four characters nor a number\n", .{text});
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
            _ = Printf(dl, "DOSTYPE: %s is neither four characters nor a number\n", .{text});
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
    if (readsGpt(rb) and handle.flags & gpt_changed == gpt_changed) {
        if (failed(run, "Writing the GPT", rb.WriteGPT(handle))) return dos.RETURN_ERROR;
    }
    if (failed(run, "Writing the table", rb.WriteRDB(handle))) return dos.RETURN_ERROR;
    _ = dl.PutStr("Table written: the partitions are mounted as it says at the next boot\n");
    return dos.RETURN_OK;
}

/// INIT: a fresh table in the GPT's container where the disk has one,
/// over the whole disk where it has none, or with GPT in the container
/// of a new GPT. What the disk has is replaced only with FORCE.
fn initTable(run: *Run, with_gpt: bool, force: bool) i32 {
    const dl = run.dl;
    const rb = run.rb;
    const handle = run.handle;
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
        var entry: gpt.Entry = .{ .partition_type_guid = gpt.TYPE_CONTAINER };
        gpt.setName(&entry, container_name);
        var err: i32 = rdb.RDBERR_OK;
        if (rb.AddGPTPartition(handle, &entry, &err) == null) {
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

/// A DosType as written on the command line: `0x` and a number, or up to
/// four characters with `\<n>` for a byte by its value, the rest zero.
fn parseDosType(text: [*:0]const u8) ?u32 {
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
