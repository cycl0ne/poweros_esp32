// SPDX-License-Identifier: MPL-2.0
//! rdb [init [partition]]: the flash disk's RigidDiskBlock and the
//! partitions hanging off it (sdk/libs/dos/hardblocks.zig), which is what
//! dos.library reads at boot to decide what to mount; or a fresh one
//! written.

const sdk = @import("sdk");
const _shell = @import("../shell.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;
const IOStdReq = sdk.exec.IOStdReq;
const trackdisk = sdk.devices.trackdisk;
const hardblocks = sdk.dos.hardblocks;

pub const name = "rdb";
pub const usage = "rdb [init [partition]]";
pub const help =
    \\  rdb                  the disk's RigidDiskBlock and its partitions
    \\  rdb init [partition]  write a fresh one (one partition, default DH0);
    \\                       what is on the partition stays. Mounted at the next boot
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const io = try _shell.openDisk(shell);
    var geo: trackdisk.DriveGeometry = .{};
    if (_shell.blockIO(shell, io, trackdisk.TD_GETGEOMETRY, 0, 0, &geo) != 0) {
        shell.print("TD_GETGEOMETRY failed\n", .{});
        return;
    }
    if (args.next()) |word| {
        if (!_shell.same(word, "init")) return error.Usage;
        return rdbInit(shell, io, &geo, args.next() orelse "DH0");
    }

    var rdb: hardblocks.RigidDiskBlock = undefined;
    const at = findRdb(shell, io, &geo, &rdb) orelse {
        shell.print("no RigidDiskBlock in the first %d blocks; 'rdb init' writes one\n", .{hardblocks.RDB_LOCATION_LIMIT});
        return;
    };
    shell.print("RDSK in block %d: %d-byte blocks, %d cylinders of %d block(s), %d head(s)\n", .{
        at, rdb.block_bytes, rdb.cylinders, rdb.cyl_blocks, rdb.heads,
    });
    shell.print("  kept for the RDB: blocks %d-%d; for partitions: cylinders %d-%d\n", .{
        rdb.rdb_blocks_lo, rdb.rdb_blocks_hi, rdb.lo_cylinder, rdb.hi_cylinder,
    });
    var next = rdb.partition_list;
    var seen: u32 = 0;
    while (next != hardblocks.end_of_list and seen < 16) : (seen += 1) {
        var part: hardblocks.PartitionBlock = undefined;
        if (_shell.blockIO(shell, io, sdk.exec.CMD_READ, @as(u64, next) * rdb.block_bytes, @sizeOf(hardblocks.PartitionBlock), &part) != 0) break;
        if (!hardblocks.sound(&part, hardblocks.IDNAME_PARTITION)) {
            shell.print("  block %d: not a sound PartitionBlock\n", .{next});
            break;
        }
        const env = &part.environment;
        var drive: [32:0]u8 = @splat(0);
        const text = part.name();
        @memcpy(drive[0..text.len], text);
        shell.print("  PART in block %d: %s: cylinders %d-%d, %ld blocks of %d, type 0x%08x%s%s\n", .{
            next,         &drive,                                                               env.low_cyl,
            env.high_cyl, env.blocks(),                                                         env.size_block,
            env.dos_type, if (part.flags & hardblocks.PBFF_BOOTABLE != 0) ", bootable" else "", if (part.flags & hardblocks.PBFF_NOMOUNT != 0) ", not mounted" else "",
        });
        next = part.next;
    }
    if (seen == 0) shell.print("  no partitions\n", .{});
}

/// The RigidDiskBlock, if the disk has a sound one; its block number.
fn findRdb(shell: *Shell, io: *IOStdReq, geo: *const trackdisk.DriveGeometry, into: *hardblocks.RigidDiskBlock) ?u32 {
    var block: u32 = 0;
    while (block < hardblocks.RDB_LOCATION_LIMIT and block < geo.total_sectors) : (block += 1) {
        if (_shell.blockIO(shell, io, sdk.exec.CMD_READ, @as(u64, block) * geo.sector_size, @sizeOf(hardblocks.RigidDiskBlock), into) != 0) continue;
        if (hardblocks.sound(into, hardblocks.IDNAME_RIGIDDISK)) return block;
    }
    return null;
}

/// A fresh RigidDiskBlock and one partition over everything past the blocks
/// it keeps. Only those two blocks are touched, so a file system already on
/// the partition is still there afterwards - but dos reads the RDB at its
/// init, so the node appears at the next boot.
fn rdbInit(shell: *Shell, io: *IOStdReq, geo: *const trackdisk.DriveGeometry, partition: []const u8) !void {
    const sector = geo.sector_size;
    const sectors: u32 = @intCast(geo.total_sectors);
    const kept = hardblocks.RDB_LOCATION_LIMIT;
    if (partition.len == 0 or partition.len > sdk.dos.MAX_DEVICE_NAME) return error.Usage;
    if (sectors < kept + 2) {
        shell.print("the disk is too small for an RDB and a partition\n", .{});
        return;
    }

    var rdb: hardblocks.RigidDiskBlock = .{
        .block_bytes = sector,
        .partition_list = 1,
        .cylinders = sectors,
        .sectors = 1,
        .heads = 1,
        .rdb_blocks_lo = 0,
        .rdb_blocks_hi = kept - 1,
        .lo_cylinder = kept,
        .hi_cylinder = sectors - 1,
        .cyl_blocks = 1,
    };
    @memcpy(rdb.disk_vendor[0.."PowerOS".len], "PowerOS");
    @memcpy(rdb.disk_product[0.."flash disk".len], "flash disk");
    rdb.checksum = hardblocks.checksumOf(&rdb);

    var part: hardblocks.PartitionBlock = .{
        .flags = hardblocks.PBFF_BOOTABLE,
        .environment = .{
            .size_block = sector,
            .surfaces = 1,
            .sector_per_block = 1,
            .blocks_per_track = 1,
            .low_cyl = kept,
            .high_cyl = sectors - 1,
            .num_buffers = 32,
            .buf_mem_type = sdk.exec.MEMF_ANY,
            .max_transfer = 0x7FFF_FFFF,
            .mask = 0xFFFF_FFFF,
            .boot_pri = 0,
            .dos_type = sdk.dos.flashfs.ID_FLASHFS_DISK,
        },
    };
    @memcpy(part.drive_name[0..partition.len], partition);
    part.checksum = hardblocks.checksumOf(&part);

    // Each of these blocks is an erase sector of its own, so neither
    // disturbs the other, and neither touches the partition.
    if (_shell.blockIO(shell, io, trackdisk.TDCMD_ERASE, 0, 2 * sector, null) != 0) {
        shell.print("erasing the first two blocks failed\n", .{});
        return;
    }
    if (_shell.blockIO(shell, io, sdk.exec.CMD_WRITE, 0, @sizeOf(hardblocks.RigidDiskBlock), &rdb) != 0 or
        _shell.blockIO(shell, io, sdk.exec.CMD_WRITE, sector, @sizeOf(hardblocks.PartitionBlock), &part) != 0)
    {
        shell.print("writing them failed\n", .{});
        return;
    }
    var zero: [32:0]u8 = @splat(0);
    @memcpy(zero[0..partition.len], partition);
    shell.print("%s: cylinders %d-%d of %d-byte blocks, bootable. Mounted at the next boot\n", .{
        &zero, kept, sectors - 1, sector,
    });
}
