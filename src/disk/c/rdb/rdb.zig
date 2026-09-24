// SPDX-License-Identifier: MIT
//! RDB: what a disk says about itself - the RigidDiskBlock in its first
//! blocks and the partitions hanging off it. Built against the SDK only.
//!
//!   RDB DEVICE,UNIT/K/N,FULL/S
//!
//!   RDB                     flash.device unit 0
//!   RDB flash.device UNIT 0 the same, said out loud
//!   RDB FULL                every field, and each partition's environment
//!
//! The device is an exec device with trackdisk's commands, so anything
//! that answers TD_GETGEOMETRY and CMD_READ can be read. The first
//! `RDB_LOCATION_LIMIT` blocks are searched for a sound RigidDiskBlock,
//! and its partition list is walked from there.
//!
//! Nothing here writes. A disk with no RigidDiskBlock is not an error: it
//! says so and stops, since that is the normal state of a blank chip.
//!
//! A DosType is printed the way a disk labels itself - four characters,
//! with an unprintable one written as `\<n>`, so the flash file system's
//! `FLS\0` reads as it is spelled - and the longword after it.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const trackdisk = sdk.devices.trackdisk;
const hardblocks = dos.hardblocks;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "RDB";
const VERSION_STRING = "\x00$VER: RDB 1.0 (16.9.2026)\r\n";

const template = "DEVICE,UNIT/K/N,FULL/S";
const arg_device = 0;
const arg_unit = 1;
const arg_full = 2;
const arg_count = 3;

/// The disk this system boots from, when nothing else is named.
const default_device = "flash.device";

/// The most partitions it follows before it decides the list is a ring.
const max_partitions = 32;

const MSG_NO_RDB = "%s unit %d has no RigidDiskBlock in its first %d blocks\n";
const MSG_NO_PARTS = "  (no partitions)\n";

/// One row of the partition table. The same format prints the heading and
/// the rule, so the columns cannot drift apart.
const row = "  %-8s %5s %-13s %9s %7s %-16s %s\n";

const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    io: *exec.IOStdReq,
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

    // The request and its port belong to this program; a device is opened
    // for as long as it takes to read a few blocks.
    const port = sys.CreateMsgPort() orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.DeleteMsgPort(port);
    const request = sys.CreateIORequest(port, @sizeOf(exec.IOStdReq)) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.DeleteIORequest(request);
    const io: *exec.IOStdReq = @ptrCast(@alignCast(request));

    if (sys.OpenDevice(device, unit, request, 0) != 0) {
        _ = Printf(dl, "%s unit %d: no such device or unit\n", .{ device, unit });
        return dos.RETURN_FAIL;
    }
    defer sys.CloseDevice(request);

    var run: Run = .{ .sys = sys, .dl = dl, .io = io, .full = argv[arg_full] != 0 };

    var geo: trackdisk.DriveGeometry = .{};
    if (command(&run, trackdisk.TD_GETGEOMETRY, 0, @sizeOf(trackdisk.DriveGeometry), &geo) != 0) {
        _ = Printf(dl, "%s unit %d: it does not answer TD_GETGEOMETRY\n", .{ device, unit });
        return dos.RETURN_FAIL;
    }
    showDrive(&run, device, unit, &geo);

    var rdb: hardblocks.RigidDiskBlock = undefined;
    const at = findRdb(&run, &geo, &rdb) orelse {
        _ = Printf(dl, MSG_NO_RDB, .{ device, unit, hardblocks.RDB_LOCATION_LIMIT });
        return dos.RETURN_WARN;
    };
    showRdb(&run, at, &rdb);
    return showPartitions(&run, &rdb);
}

/// One command to the device; its io_Error.
fn command(run: *Run, code: u16, offset: u64, length: u64, data: ?*anyopaque) i8 {
    run.io.req.command = code;
    run.io.offset = offset;
    run.io.length = length;
    run.io.data = data;
    run.io.actual = 0;
    _ = run.sys.DoIO(&run.io.req);
    return run.io.req.err;
}

/// The RigidDiskBlock, if one of the first blocks holds a sound one, and
/// which block that was.
fn findRdb(run: *Run, geo: *const trackdisk.DriveGeometry, into: *hardblocks.RigidDiskBlock) ?u32 {
    var block: u32 = 0;
    while (block < hardblocks.RDB_LOCATION_LIMIT and block < geo.total_sectors) : (block += 1) {
        const at = @as(u64, block) * geo.sector_size;
        if (command(run, exec.CMD_READ, at, @sizeOf(hardblocks.RigidDiskBlock), into) != 0) continue;
        if (hardblocks.sound(into, hardblocks.IDNAME_RIGIDDISK)) return block;
    }
    return null;
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

fn showRdb(run: *Run, at: u32, rdb: *const hardblocks.RigidDiskBlock) void {
    const dl = run.dl;
    _ = Printf(dl, "\nRigidDiskBlock in block %d\n", .{at});
    _ = Printf(dl, "  Blocks       %d bytes\n", .{rdb.block_bytes});
    _ = Printf(dl, "  Drive        %d cylinders, %d head(s), %d sector(s) per track\n", .{
        rdb.cylinders,
        rdb.heads,
        rdb.sectors,
    });
    _ = Printf(dl, "  Kept back    blocks %d to %d, for these structures\n", .{
        rdb.rdb_blocks_lo,
        rdb.rdb_blocks_hi,
    });
    _ = Printf(dl, "  Usable       cylinders %d to %d, %d block(s) each\n", .{
        rdb.lo_cylinder,
        rdb.hi_cylinder,
        rdb.cyl_blocks,
    });
    if (!run.full) return;

    var where: [16:0]u8 = @splat(0);
    blockAsText(&where, rdb.partition_list);
    _ = Printf(dl, "  Partitions   %s\n", .{@as([*:0]const u8, @ptrCast(&where))});
    blockAsText(&where, rdb.bad_block_list);
    _ = Printf(dl, "  Bad blocks   %s\n", .{@as([*:0]const u8, @ptrCast(&where))});
    blockAsText(&where, rdb.file_sys_header_list);
    _ = Printf(dl, "  File systems %s\n", .{@as([*:0]const u8, @ptrCast(&where))});

    identity(run, "  Disk         ", &rdb.disk_vendor, &rdb.disk_product, &rdb.disk_revision);
    identity(run, "  Controller   ", &rdb.controller_vendor, &rdb.controller_product, &rdb.controller_revision);
    _ = Printf(dl, "  Flags        0x%08x, host id %d\n", .{ rdb.flags, rdb.host_id });
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

fn showPartitions(run: *Run, rdb: *const hardblocks.RigidDiskBlock) i32 {
    const dl = run.dl;
    _ = dl.PutStr("\nPartitions\n");
    _ = Printf(dl, row, .{ "Name", "Block", "Cylinders", "Blocks", "Size", "File system", "Flags" });
    _ = Printf(dl, row, .{ "--------", "-----", "-------------", "---------", "-------", "----------------", "-----" });

    var next = rdb.partition_list;
    var seen: u32 = 0;
    var rc: i32 = dos.RETURN_OK;
    var part: hardblocks.PartitionBlock = undefined;
    while (next != hardblocks.end_of_list and seen < max_partitions) : (seen += 1) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
            _ = dl.PrintFault(dos.ERROR_BREAK, null);
            return dos.RETURN_WARN;
        }
        const at = @as(u64, next) * rdb.block_bytes;
        if (command(run, exec.CMD_READ, at, @sizeOf(hardblocks.PartitionBlock), &part) != 0) {
            _ = Printf(dl, "  block %d cannot be read\n", .{next});
            return dos.RETURN_ERROR;
        }
        if (!hardblocks.sound(&part, hardblocks.IDNAME_PARTITION)) {
            _ = Printf(dl, "  block %d is not a sound PartitionBlock\n", .{next});
            return dos.RETURN_ERROR;
        }
        partitionRow(run, next, &part);
        if (run.full) partitionDetail(run, &part);
        next = part.next;
    }
    if (seen == 0) _ = dl.PutStr(MSG_NO_PARTS);
    if (seen == max_partitions and next != hardblocks.end_of_list) {
        _ = Printf(dl, "  (the list does not end after %d partitions)\n", .{max_partitions});
        rc = dos.RETURN_WARN;
    }
    return rc;
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
