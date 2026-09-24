// SPDX-License-Identifier: MPL-2.0
//! mkfs: builds a disk image - a RigidDiskBlock, one partition, and the
//! flash file system on it - so the board boots with a `C:` instead of the
//! shell copying programs into RAM: at every start.
//!
//! usage: mkfs <out.bin> <volume> <partition> <sectors> <sector-size>
//!            <page-size> [<path-in-image>[=<host-file>] ...]
//!
//! `volume` is what the file system calls itself; `partition` is what the
//! device node is called (`DH0`), which is what dos.library reads out of
//! the PartitionBlock at boot. A path with no `=` is a directory to make,
//! one with `=` a file to write from the host; directories come before what
//! goes in them, so the order on the command line matters (build.zig writes
//! it out).
//!
//! It writes no format itself. The RigidDiskBlock and the PartitionBlock
//! are `sdk/libs/dos/hardblocks.zig`'s structures, and the file system is the
//! code the handler runs (`src/rom/handler/flashfs`, through the `fs`
//! module the build makes of it) driven over a block of memory, sent the
//! packets a program would send. So there is one implementation of each,
//! and what this writes is by construction what the kernel reads.
//!
//! The image holds only the blocks it touched - the RDB's, and the file
//! system's - and stops there; the rest of the disk area is left as it is,
//! which on flash means erased.

const std = @import("std");
const mem = std.mem;
const sdk = @import("sdk");
const dos = sdk.dos;
const hardblocks = dos.hardblocks;
const flashfs = dos.flashfs;
const disk = @import("fs");

/// The blocks kept for the RDB and its chain: the RigidDiskBlock is in the
/// first of them (RDB_LOCATION_LIMIT) and the PartitionBlock follows.
/// On flash a block is an erase sector, so one can be rewritten without
/// disturbing the next, and there is room for a second partition or a file
/// system header later.
const rdb_blocks: u32 = hardblocks.RDB_LOCATION_LIMIT;
/// Where the RigidDiskBlock and the first PartitionBlock go.
const rdb_block: u32 = 0;
const partition_block: u32 = 1;

/// The blocks the file system may hold in memory (de_NumBuffers).
const buffers: u32 = 32;

/// The medium: a block of memory that behaves like flash - a write only
/// clears bits, and an erase sets a sector back to ones. The file system
/// gets the partition's part of it, as the handler does on the target.
const ImageMedia = struct {
    store: []u8,
    /// The partition: its first byte in the image, and how many it has.
    first: u32,
    length: u32,
    sector: u32,
    page: u32,
    allocator: mem.Allocator,

    /// Eight-byte aligned, as exec's AllocVec is on the target: the file
    /// system puts structures with 64-bit fields in these blocks.
    pub fn alloc(m: *ImageMedia, bytes_wanted: u32) ?[]u8 {
        return m.allocator.alignedAlloc(u8, .@"8", bytes_wanted) catch null;
    }

    pub fn free(m: *ImageMedia, block: []u8) void {
        const aligned: []align(8) u8 = @alignCast(block);
        m.allocator.free(aligned);
    }

    /// Every file gets the same date: an image has no clock, and a
    /// reproducible build wants none.
    pub fn now(_: *ImageMedia) dos.DateStamp {
        return .{};
    }

    pub fn size(m: *ImageMedia) u32 {
        return m.length;
    }

    pub fn sectorSize(m: *ImageMedia) u32 {
        return m.sector;
    }

    pub fn pageSize(m: *ImageMedia) u32 {
        return m.page;
    }

    pub fn bytes(m: *ImageMedia) ?[]const u8 {
        return m.store[m.first..][0..m.length];
    }

    pub fn read(m: *ImageMedia, at: u32, into: []u8) bool {
        if (at + into.len > m.length) return false;
        @memcpy(into, m.store[m.first + at ..][0..into.len]);
        return true;
    }

    pub fn write(m: *ImageMedia, at: u32, from: []const u8) bool {
        if (at + from.len > m.length) return false;
        for (from, 0..) |b, i| m.store[m.first + at + i] &= b;
        return true;
    }

    pub fn erase(m: *ImageMedia, at: u32, len: u32) bool {
        if (at + len > m.length) return false;
        @memset(m.store[m.first + at ..][0..len], 0xFF);
        return true;
    }
};

const FileSystem = disk.FileSystem(ImageMedia);

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("mkfs: " ++ format ++ "\n", args);
    std.process.exit(1);
}

/// One packet to the file system, as a program's dos call would send it.
fn send(fs: *FileSystem, action: dos.ActionCode, args: dos.PacketArgs) disk.Answer {
    var pkt = dos.DosPacket.init(action, args);
    return fs.answer(&pkt);
}

/// A structure into its block of the image, with the checksum that makes it
/// sound.
fn putBlock(store: []u8, block: u32, sector: u32, value: anytype) void {
    var copy = value.*;
    copy.checksum = hardblocks.checksumOf(&copy);
    const bytes = mem.asBytes(&copy);
    @memcpy(store[block * sector ..][0..bytes.len], bytes);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 7) fatal("usage: mkfs <out.bin> <volume> <partition> <sectors> <sector-size> <page-size> [<path>[=<file>] ...]", .{});

    const out_path = args[1];
    const label = args[2];
    const drive = args[3];
    const sectors = std.fmt.parseInt(u32, args[4], 0) catch fatal("{s}: not a number", .{args[4]});
    const sector_size = std.fmt.parseInt(u32, args[5], 0) catch fatal("{s}: not a number", .{args[5]});
    const page_size = std.fmt.parseInt(u32, args[6], 0) catch fatal("{s}: not a number", .{args[6]});
    if (sectors < rdb_blocks + 2 or sector_size == 0) fatal("a disk needs more than its RDB blocks", .{});
    if (drive.len >= @typeInfo(@FieldType(hardblocks.PartitionBlock, "drive_name")).array.len) {
        fatal("{s}: too long for a partition name", .{drive});
    }

    const store = try arena.alloc(u8, sectors * sector_size);
    @memset(store, 0xFF);

    // The partition is everything past the blocks the RDB keeps. One block
    // to a cylinder, so a cylinder is a sector and the numbers stay plain.
    const environment: dos.DosEnvec = .{
        .size_block = sector_size,
        .surfaces = 1,
        .sector_per_block = 1,
        .blocks_per_track = 1,
        .low_cyl = rdb_blocks,
        .high_cyl = sectors - 1,
        .num_buffers = buffers,
        .buf_mem_type = sdk.exec.MEMF_ANY,
        .max_transfer = 0x7FFF_FFFF,
        .mask = 0xFFFF_FFFF,
        .boot_pri = 0,
        .dos_type = flashfs.ID_FLASHFS_DISK,
    };
    var rdb: hardblocks.RigidDiskBlock = .{
        .block_bytes = sector_size,
        .partition_list = partition_block,
        .cylinders = sectors,
        .sectors = 1,
        .heads = 1,
        .rdb_blocks_lo = 0,
        .rdb_blocks_hi = rdb_blocks - 1,
        .lo_cylinder = rdb_blocks,
        .hi_cylinder = sectors - 1,
        .cyl_blocks = 1,
    };
    @memcpy(rdb.disk_vendor[0.."PowerOS".len], "PowerOS");
    @memcpy(rdb.disk_product[0.."flash disk".len], "flash disk");
    var part: hardblocks.PartitionBlock = .{
        .flags = hardblocks.PBFF_BOOTABLE,
        .environment = environment,
    };
    @memcpy(part.drive_name[0..drive.len], drive);
    putBlock(store, rdb_block, sector_size, &rdb);
    putBlock(store, partition_block, sector_size, &part);

    var media: ImageMedia = .{
        .store = store,
        .first = rdb_blocks * sector_size,
        .length = (sectors - rdb_blocks) * sector_size,
        .sector = sector_size,
        .page = page_size,
        .allocator = arena,
    };
    var fs = FileSystem.init(&media, null);
    fs.format(label) catch |e| fatal("format: {t}", .{e});

    const cwd = std.Io.Dir.cwd();
    for (args[7..]) |entry| {
        const split = mem.indexOfScalar(u8, entry, '=');
        const path = try arena.dupeZ(u8, if (split) |at| entry[0..at] else entry);
        if (split == null) {
            const made = send(&fs, .create_dir, .{ .raw = .{ 0, @bitCast(@intFromPtr(path.ptr)), dos.EXCLUSIVE_LOCK, 0, 0, 0, 0 } });
            if (made.res1 == 0) fatal("{s}: cannot make it ({d})", .{ path, made.res2 });
            _ = send(&fs, .free_lock, .{ .raw = .{ made.res1, 0, 0, 0, 0, 0, 0 } });
            continue;
        }
        const from = entry[split.? + 1 ..];
        const content = try cwd.readFileAlloc(io, from, arena, .unlimited);
        var fh: dos.FileHandle = .{};
        const opened = send(&fs, .findoutput, .{ .find = .{ .fh = &fh, .lock = null, .name = path.ptr } });
        if (opened.res1 == dos.DOSFALSE) fatal("{s}: cannot write it ({d})", .{ path, opened.res2 });
        const written = send(&fs, .write, .{ .io = .{ .fh = &fh, .buffer = content.ptr, .length = @intCast(content.len) } });
        if (written.res1 != @as(isize, @intCast(content.len))) fatal("{s}: only {d} of {d} bytes ({d})", .{ path, written.res1, content.len, written.res2 });
        _ = send(&fs, .end, .{ .file = .{ .fh = &fh } });
        // The programs on disk are pure, so `resident` takes them without
        // being forced.
        const protect = send(&fs, .set_protect, .{ .property = .{ .lock = null, .name = path.ptr, .value = dos.FIBF_PURE } });
        if (protect.res1 == dos.DOSFALSE) fatal("{s}: cannot set its bits ({d})", .{ path, protect.res2 });
    }

    // Only as far as the file system went: the rest of the disk is left
    // alone, and on flash that means erased.
    var used: u32 = (partition_block + 1) * sector_size;
    for (1..sectors - rdb_blocks) |sector| {
        if (fs.vol.segs[sector].seq != 0) used = (rdb_blocks + @as(u32, @intCast(sector)) + 1) * sector_size;
    }
    fs.deinit();
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = store[0..used] });
}
