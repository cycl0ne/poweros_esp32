// SPDX-License-Identifier: MPL-2.0
//! mkfs: builds a disk image - a RigidDiskBlock, one partition, and the
//! flash file system on it - so the board boots with a `C:` instead of the
//! shell copying programs into RAM: at every start.
//!
//! usage: mkfs [--tree=<dir>] [--manifest=<file>]
//!            <out.bin> <volume> <partition> <sectors> <partition-sectors>
//!            <sector-size> <page-size> <rdb-sectors>
//!            [<path-in-image>[=<host-file>] ...]
//!
//! `volume` is what the file system calls itself; `partition` is what the
//! device node is called (`DH0`), which is what flash.device reads out of
//! the PartitionBlock at boot. `sectors` is the whole disk's, and
//! `partition-sectors` the partition's: 0 gives it every sector past the
//! RDB's, and fewer leave the rest of the disk for partitions made later
//! (C:RDB ADD). `rdb-sectors` is the table's area before the partition,
//! RDB_LOCATION_LIMIT at least: what is past the RigidDiskBlock and the
//! PartitionBlock is room for more partitions and for file systems kept
//! in the table (C:RDB ADDFS, HDToolBox). A path with no `=` is a directory to make, one with `=` a
//! file to write from the host; directories come before what goes in them,
//! so the order on the command line matters (build.zig writes it out).
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
//!
//! **The same files outside the image**, for a volume that is not made
//! from it - a card that is SYS:, brought up to date file by file
//! (tools/vf2_update.py in the port's repository). `--tree` writes every
//! file and directory the image gets under `<dir>` as well, and
//! `--manifest` lists the image's files, one line each: the CRC-32 of its
//! bytes in hex, its size, its path. A path given twice is the later
//! file's, as on the image, and the list is sorted by path.
//!
//! An image has no clock, so a build from the same inputs gives the same
//! image: every file is dated 1 Jan 1978.

const std = @import("std");
const mem = std.mem;
const sdk = @import("sdk");
const dos = sdk.dos;
const hardblocks = dos.hardblocks;
const flashfs = dos.flashfs;
const disk = @import("fs");

/// The fewest blocks kept for the RDB and its chain: every block a
/// RigidDiskBlock may be in (RDB_LOCATION_LIMIT). The RigidDiskBlock is in
/// the first and the PartitionBlock follows. On flash a block is an erase
/// sector, so one can be rewritten without disturbing the next, and the
/// rest is room for more partitions and file systems later.
const min_rdb_blocks: u32 = hardblocks.RDB_LOCATION_LIMIT;
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

/// An answer from the file system.
const Reply = struct { res1: isize, res2: i32 };

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print("mkfs: " ++ format ++ "\n", args);
    std.process.exit(1);
}

/// One packet to the file system, as a program's dos call would send it.
fn send(fs: anytype, action: dos.ActionCode, args: dos.PacketArgs) Reply {
    var pkt = dos.DosPacket.init(action, args);
    const answer = fs.answer(&pkt);
    return .{ .res1 = answer.res1, .res2 = answer.res2 };
}

/// A file from the host, or a directory to make.
const Entry = struct { path: [:0]const u8, content: ?[]const u8 };

/// What the command line puts on the volume, sent as packets.
fn fill(fs: anytype, entries: []const Entry) void {
    for (entries) |entry| {
        const path = entry.path;
        const content = entry.content orelse {
            const made = send(fs, .create_dir, .{ .raw = .{ 0, @bitCast(@intFromPtr(path.ptr)), dos.EXCLUSIVE_LOCK, 0, 0, 0, 0 } });
            if (made.res1 == 0) fatal("{s}: cannot make it ({d})", .{ path, made.res2 });
            _ = send(fs, .free_lock, .{ .raw = .{ made.res1, 0, 0, 0, 0, 0, 0 } });
            continue;
        };
        var fh: dos.FileHandle = .{};
        const opened = send(fs, .findoutput, .{ .find = .{ .fh = &fh, .lock = null, .name = path.ptr } });
        if (opened.res1 == dos.DOSFALSE) fatal("{s}: cannot write it ({d})", .{ path, opened.res2 });
        const written = send(fs, .write, .{ .io = .{ .fh = &fh, .buffer = @constCast(content.ptr), .length = @intCast(content.len) } });
        if (written.res1 != @as(isize, @intCast(content.len))) fatal("{s}: only {d} of {d} bytes ({d})", .{ path, written.res1, content.len, written.res2 });
        const closed = send(fs, .end, .{ .file = .{ .fh = &fh } });
        if (closed.res1 == dos.DOSFALSE) fatal("{s}: cannot close it ({d})", .{ path, closed.res2 });
        // The programs on disk are pure, so `resident` takes them without
        // being forced.
        const protect = send(fs, .set_protect, .{ .property = .{ .lock = null, .name = path.ptr, .value = dos.FIBF_PURE } });
        if (protect.res1 == dos.DOSFALSE) fatal("{s}: cannot set its bits ({d})", .{ path, protect.res2 });
    }
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
    const all_args = try init.minimal.args.toSlice(arena);
    // The options taken out wherever they are: no path in an image starts
    // with "--".
    var tree_path: ?[]const u8 = null;
    var manifest_path: ?[]const u8 = null;
    var kept: std.ArrayList([:0]const u8) = .empty;
    for (all_args, 0..) |arg, index| {
        if (index == 0 or !mem.startsWith(u8, arg, "--")) {
            try kept.append(arena, arg);
        } else if (mem.startsWith(u8, arg, "--tree=")) {
            tree_path = arg["--tree=".len..];
        } else if (mem.startsWith(u8, arg, "--manifest=")) {
            manifest_path = arg["--manifest=".len..];
        } else fatal("{s}: no such option", .{arg});
    }
    const args = kept.items;
    if (args.len < 9) fatal("usage: mkfs <out.bin> <volume> <partition> <sectors> <partition-sectors> <sector-size> <page-size> <rdb-sectors> [<path>[=<file>] ...]", .{});

    const out_path = args[1];
    const label = args[2];
    const drive = args[3];
    const sectors = std.fmt.parseInt(u32, args[4], 0) catch fatal("{s}: not a number", .{args[4]});
    const asked = std.fmt.parseInt(u32, args[5], 0) catch fatal("{s}: not a number", .{args[5]});
    const sector_size = std.fmt.parseInt(u32, args[6], 0) catch fatal("{s}: not a number", .{args[6]});
    const page_size = std.fmt.parseInt(u32, args[7], 0) catch fatal("{s}: not a number", .{args[7]});
    const rdb_blocks = std.fmt.parseInt(u32, args[8], 0) catch fatal("{s}: not a number", .{args[8]});
    if (rdb_blocks < min_rdb_blocks) fatal("{d} RDB sectors: the table needs {d} at least", .{ rdb_blocks, min_rdb_blocks });
    if (sectors < rdb_blocks + 2 or sector_size == 0) fatal("a disk needs more than its RDB blocks", .{});
    const part_sectors = if (asked == 0) sectors - rdb_blocks else asked;
    if (part_sectors < 2 or part_sectors > sectors - rdb_blocks) fatal("{d} sectors: the disk has {d} past its RDB blocks", .{ part_sectors, sectors - rdb_blocks });
    if (drive.len >= @typeInfo(@FieldType(hardblocks.PartitionBlock, "drive_name")).array.len) {
        fatal("{s}: too long for a partition name", .{drive});
    }

    // Everything the volume gets, read first.
    const cwd = std.Io.Dir.cwd();
    var entries: std.ArrayList(Entry) = .empty;
    for (args[9..]) |entry| {
        const split = mem.indexOfScalar(u8, entry, '=');
        const path = try arena.dupeZ(u8, if (split) |at| entry[0..at] else entry);
        const content: ?[]const u8 = if (split) |at| try cwd.readFileAlloc(io, entry[at + 1 ..], arena, .unlimited) else null;
        try entries.append(arena, .{ .path = path, .content = content });
    }

    if (tree_path) |path| try writeTree(io, cwd, path, entries.items);
    if (manifest_path) |path| try writeManifest(io, cwd, path, entries.items, arena);

    const store = try arena.alloc(u8, sectors * sector_size);
    @memset(store, 0xFF);

    // The partition is past the blocks the RDB keeps. One block to a
    // cylinder, so a cylinder is a sector and the numbers stay plain.
    const last = rdb_blocks + part_sectors - 1;
    const environment: dos.DosEnvec = .{
        .size_block = sector_size,
        .surfaces = 1,
        .sector_per_block = 1,
        .blocks_per_track = 1,
        .low_cyl = rdb_blocks,
        .high_cyl = last,
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

    const used = flashfsVolume(store, rdb_blocks, part_sectors, sector_size, page_size, label, entries.items, arena);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = store[0..used] });
}

/// The flash file system on the partition; the image's end is the last
/// block it wrote.
fn flashfsVolume(store: []u8, rdb_blocks: u32, part_sectors: u32, sector_size: u32, page_size: u32, label: []const u8, entries: []const Entry, arena: mem.Allocator) usize {
    var media: ImageMedia = .{
        .store = store,
        .first = rdb_blocks * sector_size,
        .length = part_sectors * sector_size,
        .sector = sector_size,
        .page = page_size,
        .allocator = arena,
    };
    var fs = FileSystem.init(&media, null);
    defer fs.deinit();
    fs.format(label) catch |e| fatal("format: {t}", .{e});
    fill(&fs, entries);
    // Only as far as the file system went: the rest of the disk is left
    // alone, and on flash that means erased.
    var used: u32 = (partition_block + 1) * sector_size;
    for (1..part_sectors) |sector| {
        if (fs.vol.segs[sector].seq != 0) used = (rdb_blocks + @as(u32, @intCast(sector)) + 1) * sector_size;
    }
    return used;
}

/// Every directory and file of the image under `root` on the host, the
/// later of two files at one path written last.
fn writeTree(io: std.Io, cwd: std.Io.Dir, root: []const u8, entries: []const Entry) !void {
    try cwd.createDirPath(io, root);
    var dir = try cwd.openDir(io, root, .{});
    defer dir.close(io);
    for (entries) |entry| {
        const content = entry.content orelse {
            try dir.createDirPath(io, entry.path);
            continue;
        };
        try dir.writeFile(io, .{ .sub_path = entry.path, .data = content });
    }
}

/// The image's files, a line each - CRC-32, size, path - sorted by path.
/// A path given twice is listed once, with the later file: case does not
/// tell two paths apart, as on the volume.
fn writeManifest(io: std.Io, cwd: std.Io.Dir, path: []const u8, entries: []const Entry, arena: mem.Allocator) !void {
    var latest: std.StringArrayHashMapUnmanaged(Entry) = .empty;
    for (entries) |entry| {
        if (entry.content == null) continue;
        const key = try std.ascii.allocLowerString(arena, entry.path);
        try latest.put(arena, key, entry);
    }
    const Sort = struct {
        keys: []const []const u8,
        pub fn lessThan(sort: @This(), a: usize, b: usize) bool {
            return mem.lessThan(u8, sort.keys[a], sort.keys[b]);
        }
    };
    latest.sort(Sort{ .keys = latest.keys() });
    var text: std.ArrayList(u8) = .empty;
    for (latest.values()) |entry| {
        const content = entry.content.?;
        try text.print(arena, "{x:0>8} {d} {s}\n", .{ std.hash.Crc32.hash(content), content.len, entry.path });
    }
    try cwd.writeFile(io, .{ .sub_path = path, .data = text.items });
}
