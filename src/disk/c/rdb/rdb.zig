// SPDX-License-Identifier: MIT
//! RDB: what a disk says about itself - the RigidDiskBlock in its first
//! blocks and the partitions hanging off it - and changes to it, through
//! LIBS:rdb.library. Built against the SDK only.
//!
//!   RDB DEVICE,UNIT/K/N,FULL/S,INIT/S,FORCE/S,ADD/K,LOW/K/N,HIGH/K/N,
//!       DOSTYPE/K,BOOTABLE/S,REMOVE/K
//!
//!   RDB                         flash.device unit 0
//!   RDB sdcard.device UNIT 0    another disk
//!   RDB FULL                    every field, and each partition's environment
//!   RDB INIT                    a fresh table on a disk that has none
//!   RDB INIT FORCE              ... or in place of the one it has
//!   RDB ADD DH1                 a partition over the largest free run
//!   RDB ADD DH1 LOW 100 HIGH 199 DOSTYPE FLS BOOTABLE
//!   RDB REMOVE DH1              a partition taken out of the table
//!
//! The device is an exec device with trackdisk's commands, so anything
//! that answers TD_GETGEOMETRY and CMD_READ can be read. A change is made
//! in the order INIT, REMOVE, ADD, then the table is written as a whole
//! and printed. Only the table's own blocks are written: what is on a
//! partition's cylinders stays. dos reads the table at boot, so a
//! partition added or taken out is mounted, or no longer, at the next one.
//!
//! A disk with no RigidDiskBlock is not an error: it says so and stops,
//! since that is the normal state of a blank chip.
//!
//! A DosType is printed the way a disk labels itself - four characters,
//! with an unprintable one written as `\<n>`, so the flash file system's
//! `FLS\0` reads as it is spelled - and the longword after it. DOSTYPE
//! takes it the same way (`FLS\0`, or `FLS` with the zero left off) or as
//! a number (`0x464C5300`); without it a partition is for the flash file
//! system.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const rdb = sdk.rdb;
const trackdisk = sdk.devices.trackdisk;
const hardblocks = dos.hardblocks;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const RDBBase = sdk.interface.rdb.RDBBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "RDB";
const VERSION_STRING = "\x00$VER: RDB 1.1 (03.10.2026)\r\n";

const template = "DEVICE,UNIT/K/N,FULL/S,INIT/S,FORCE/S,ADD/K,LOW/K/N,HIGH/K/N,DOSTYPE/K,BOOTABLE/S,REMOVE/K";
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
const arg_count = 11;

/// The disk this system boots from, when nothing else is named.
const default_device = "flash.device";

const MSG_NO_RDB = "%s unit %d has no RigidDiskBlock in its first %d blocks\n";
const MSG_FOREIGN = "%s unit %d has a RigidDiskBlock for another block size\n";
const MSG_NO_PARTS = "  (no partitions)\n";

/// One row of the partition table. The same format prints the heading and
/// the rule, so the columns cannot drift apart.
const row = "  %-8s %5s %-13s %9s %7s %-16s %s\n";

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
    showDrive(&run, device, unit, &handle.geometry);

    if (argv[arg_init] != 0 or argv[arg_add] != 0 or argv[arg_remove] != 0) {
        const rc = change(&run, &argv);
        if (rc != dos.RETURN_OK) return rc;
    }

    if (handle.flags & rdb.RDBF_FOUND == 0) {
        if (handle.flags & rdb.RDBF_FOREIGN != 0) {
            _ = Printf(dl, MSG_FOREIGN, .{ device, unit });
        } else {
            _ = Printf(dl, MSG_NO_RDB, .{ device, unit, hardblocks.RDB_LOCATION_LIMIT });
        }
        return dos.RETURN_WARN;
    }
    showRdb(&run, handle.block, &handle.rdb);
    return showPartitions(&run);
}

/// INIT, REMOVE and ADD made to the table, and the table written.
fn change(run: *Run, argv: *const [arg_count]usize) i32 {
    const dl = run.dl;
    const rb = run.rb;
    const handle = run.handle;

    if (argv[arg_init] != 0) {
        if (handle.flags & rdb.RDBF_FOUND != 0 and argv[arg_force] == 0) {
            _ = dl.PutStr("The disk has a table already: INIT FORCE replaces it, and every partition with it\n");
            return dos.RETURN_ERROR;
        }
        if (failed(run, "INIT", rb.InitRDB(handle))) return dos.RETURN_ERROR;
    }
    if (rdargs.string(argv[arg_remove])) |name| {
        const part = rb.FindPartition(handle, name) orelse {
            _ = Printf(dl, "REMOVE: there is no partition %s\n", .{name});
            return dos.RETURN_ERROR;
        };
        rb.RemPartition(handle, part);
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
        if (argv[arg_bootable] != 0) {
            if (rb.FindPartition(handle, name)) |part| part.block.flags |= hardblocks.PBFF_BOOTABLE;
        }
    }

    if (failed(run, "Writing the table", rb.WriteRDB(handle))) return dos.RETURN_ERROR;
    _ = dl.PutStr("Table written: the partitions are mounted as it says at the next boot\n");
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
        rdb.RDBERR_FULL => "no room in the table's blocks for another partition",
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

fn showDrive(run: *Run, device: [*:0]const u8, unit: u32, geo: *const trackdisk.DriveGeometry) void {
    const dl = run.dl;
    var size: [16:0]u8 = @splat(0);
    bytesAsText(&size, geo.total_sectors * geo.sector_size);

    _ = Printf(dl, "%s unit %d\n", .{ device, unit });
    _ = Printf(dl, "  Medium       %ld blocks of %d bytes (%s)\n", .{
        geo.total_sectors,
        geo.sector_size,
        @as([*:0]const u8, @ptrCast(&size)),
    });
    _ = Printf(dl, "  Geometry     %d cylinders, %d head(s), %d block(s) per track\n", .{
        geo.cylinders,
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
        _ = Printf(dl, "  Mapped at    0x%08x, so a read costs no request\n", .{geo.map_base});
    }
}

fn showRdb(run: *Run, at: u32, table: *const hardblocks.RigidDiskBlock) void {
    const dl = run.dl;
    _ = Printf(dl, "\nRigidDiskBlock in block %d\n", .{at});
    _ = Printf(dl, "  Blocks       %d bytes\n", .{table.block_bytes});
    _ = Printf(dl, "  Drive        %d cylinders, %d head(s), %d sector(s) per track\n", .{
        table.cylinders,
        table.heads,
        table.sectors,
    });
    _ = Printf(dl, "  Kept back    blocks %d to %d, for these structures\n", .{
        table.rdb_blocks_lo,
        table.rdb_blocks_hi,
    });
    _ = Printf(dl, "  Usable       cylinders %d to %d, %d block(s) each\n", .{
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

fn showPartitions(run: *Run) i32 {
    const dl = run.dl;
    const rb = run.rb;
    _ = dl.PutStr("\nPartitions\n");
    _ = Printf(dl, row, .{ "Name", "Block", "Cylinders", "Blocks", "Size", "File system", "Flags" });
    _ = Printf(dl, row, .{ "--------", "-----", "-------------", "---------", "-------", "----------------", "-----" });

    var part = rb.NextPartition(run.handle, null);
    if (part == null) _ = dl.PutStr(MSG_NO_PARTS);
    while (part) |p| : (part = rb.NextPartition(run.handle, p)) {
        partitionRow(run, p.at, &p.block);
        if (run.full) partitionDetail(run, &p.block);
    }
    if (run.handle.flags & rdb.RDBF_DAMAGED != 0) {
        _ = dl.PutStr("  (the chain breaks after these: a block that is not a sound PartitionBlock)\n");
        return dos.RETURN_ERROR;
    }
    return dos.RETURN_OK;
}

fn partitionRow(run: *Run, block: u32, part: *const hardblocks.PartitionBlock) void {
    const env = &part.environment;

    var name: [33:0]u8 = @splat(0);
    _ = trimmed(&name, &part.drive_name);

    var block_text: [12:0]u8 = @splat(0);
    _ = decimal(&block_text, block);

    var cylinders: [16:0]u8 = @splat(0);
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
    _ = Printf(dl, "      Geometry     %d surface(s), %d block(s) per track, interleave %d\n", .{
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
