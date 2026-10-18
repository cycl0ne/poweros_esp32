// SPDX-License-Identifier: MPL-2.0
//! posfsck: checks the posfs volumes in an image - a disk image the build
//! made, a dump of a board's flash, an SD card's image - on the host.
//!
//! usage: posfsck [--data] [--offset <bytes> --length <bytes>] <image>
//!
//! Without --offset it finds the volumes itself: a volume that starts the
//! image (its label first), the posfs partitions (DosType `POS\0`) of a
//! RigidDiskBlock anywhere in the image at a 512-byte boundary - which
//! finds the disk in a dump of the whole flash too - or the partition of
//! type 0x7F of a partition table at the image's start, as a card
//! formatted for `POS\1` has. With --offset and --length the volume is
//! where they say.
//!
//! It is the check the handler runs (`src/rom/handler/posfs/check.zig`,
//! through the `posfs` module the build makes of it), over the image read
//! as memory and never written: the volume is mounted read-only, what its
//! journal holds after the newest checkpoint replayed in memory, and then
//! checked whole - its trees, objects and space, and with --data every
//! file's data against its checksums. Every fault is printed.
//!
//! The exit code is 0 when nothing was found wrong, 1 when something was,
//! and 2 when a volume could not be checked at all.

const std = @import("std");
const mem = std.mem;
const sdk = @import("sdk");
const dos = sdk.dos;
const posfs = dos.posfs;
const layout = posfs.layout;
const hardblocks = dos.hardblocks;
const posfs_fs = @import("posfs");

/// The image as posfs's medium contract asks for it, read only: one
/// volume's bytes, read as memory.
const ImageMedia = struct {
    bytes: []const u8,
    erase_unit: u32,
    write_unit: u32,
    allocator: mem.Allocator,

    pub fn size(m: *ImageMedia) u64 {
        return m.bytes.len;
    }

    pub fn sectorSize(_: *ImageMedia) u32 {
        return 512;
    }

    pub fn writeSize(m: *ImageMedia) u32 {
        return m.write_unit;
    }

    pub fn eraseSize(m: *ImageMedia) u32 {
        return m.erase_unit;
    }

    pub fn mapped(m: *ImageMedia) ?[*]const u8 {
        return m.bytes.ptr;
    }

    pub fn read(m: *ImageMedia, at: u64, into: []u8) bool {
        if (at > m.bytes.len or into.len > m.bytes.len - at) return false;
        @memcpy(into, m.bytes[@intCast(at)..][0..into.len]);
        return true;
    }

    pub fn write(_: *ImageMedia, _: u64, _: []const u8) bool {
        return false;
    }

    pub fn erase(_: *ImageMedia, _: u64, _: u64) bool {
        return false;
    }

    pub fn update(_: *ImageMedia) bool {
        return true;
    }

    pub fn writable(_: *ImageMedia) bool {
        return false;
    }

    pub fn alloc(m: *ImageMedia, len: usize) ?[]u8 {
        const block = m.allocator.alignedAlloc(u8, .@"8", len) catch return null;
        @memset(block, 0);
        return block;
    }

    pub fn free(m: *ImageMedia, block: []u8) void {
        const aligned: []align(8) u8 = @alignCast(block);
        m.allocator.free(aligned);
    }

    pub fn now(_: *ImageMedia) u64 {
        return 0;
    }

    pub fn random(_: *ImageMedia, into: *[16]u8) void {
        into.* = @splat(0);
    }
};

/// A volume to check: where it is in the image, and what to call it.
const Place = struct { offset: u64, length: u64, name: []const u8 };

/// How a check ended.
const Outcome = enum { clean, damaged, unreadable };

fn usage() noreturn {
    std.debug.print("usage: posfsck [--data] [--offset <bytes> --length <bytes>] <image>\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    var data = false;
    var offset: ?u64 = null;
    var length: ?u64 = null;
    var path: ?[]const u8 = null;
    var at: usize = 1;
    while (at < args.len) : (at += 1) {
        const arg = args[at];
        if (mem.eql(u8, arg, "--data")) {
            data = true;
        } else if (mem.eql(u8, arg, "--offset") or mem.eql(u8, arg, "--length")) {
            at += 1;
            if (at == args.len) usage();
            const value = std.fmt.parseInt(u64, args[at], 0) catch usage();
            if (arg[2] == 'o') offset = value else length = value;
        } else if (path == null and arg.len > 0 and arg[0] != '-') {
            path = arg;
        } else usage();
    }
    const image_path = path orelse usage();
    if ((offset == null) != (length == null)) usage();
    const image = std.Io.Dir.cwd().readFileAlloc(io, image_path, arena, .unlimited) catch |err| {
        std.debug.print("posfsck: {s}: {t}\n", .{ image_path, err });
        std.process.exit(2);
    };

    var places: std.ArrayList(Place) = .empty;
    if (offset) |first| {
        try places.append(arena, .{ .offset = first, .length = length.?, .name = image_path });
    } else try findVolumes(arena, image, &places);
    if (places.items.len == 0) {
        std.debug.print("posfsck: {s}: no posfs volume found\n", .{image_path});
        std.process.exit(2);
    }

    var worst: Outcome = .clean;
    for (places.items) |place| {
        if (place.offset > image.len or place.length > image.len - place.offset) {
            std.debug.print("{s}: past the image's end\n", .{place.name});
            worst = .unreadable;
            continue;
        }
        const outcome = checkVolume(place, image[@intCast(place.offset)..][0..@intCast(place.length)], data);
        if (@intFromEnum(outcome) > @intFromEnum(worst)) worst = outcome;
    }
    std.process.exit(switch (worst) {
        .clean => 0,
        .damaged => 1,
        .unreadable => 2,
    });
}

/// The volumes of an image: one that starts it, the posfs partitions of a
/// RigidDiskBlock, or a partition table's partition of type 0x7F.
fn findVolumes(arena: mem.Allocator, image: []const u8, into: *std.ArrayList(Place)) !void {
    if (image.len >= @sizeOf(layout.Label) and mem.readInt(u32, image[0..4], .little) == layout.label_magic) {
        try into.append(arena, .{ .offset = 0, .length = image.len, .name = "the volume" });
        return;
    }
    var at: usize = 0;
    while (at + 512 <= image.len) : (at += 512) {
        var rdb: hardblocks.RigidDiskBlock = undefined;
        @memcpy(layout.bytesOfMut(&rdb), image[at..][0..@sizeOf(hardblocks.RigidDiskBlock)]);
        if (!hardblocks.sound(&rdb, hardblocks.IDNAME_RIGIDDISK) or rdb.block_bytes < 256) continue;
        // The RigidDiskBlock is the disk's first block, and the
        // partition list counts in its blocks.
        var next = rdb.partition_list;
        var seen: u32 = 0;
        while (next != hardblocks.end_of_list and seen < 64) : (seen += 1) {
            const where = at + @as(u64, next) * rdb.block_bytes;
            if (where + @sizeOf(hardblocks.PartitionBlock) > image.len) break;
            var part: hardblocks.PartitionBlock = undefined;
            @memcpy(layout.bytesOfMut(&part), image[@intCast(where)..][0..@sizeOf(hardblocks.PartitionBlock)]);
            if (!hardblocks.sound(&part, hardblocks.IDNAME_PARTITION)) break;
            const env = &part.environment;
            if (env.dos_type == posfs.ID_POSFS_DISK and !env.wholeMedium()) {
                try into.append(arena, .{
                    .offset = at + env.byteOf(0),
                    .length = env.blocks() * env.size_block,
                    .name = try arena.dupe(u8, part.name()),
                });
            }
            next = part.next;
        }
        return;
    }
    // A partition table: four entries from byte 446, its mark at 510.
    if (image.len >= 512 and image[510] == 0x55 and image[511] == 0xAA) {
        for (0..4) |index| {
            const entry = image[446 + 16 * index ..][0..16];
            if (entry[4] != posfs.mbr_type) continue;
            const first = mem.readInt(u32, entry[8..12], .little);
            const count = mem.readInt(u32, entry[12..16], .little);
            try into.append(arena, .{ .offset = @as(u64, first) * 512, .length = @as(u64, count) * 512, .name = "the partition" });
        }
    }
}

/// Fault after fault, as the check finds them.
fn printFault(context: ?*anyopaque, message: []const u8, where: u64) void {
    const shown: *u32 = @ptrCast(@alignCast(context.?));
    shown.* += 1;
    if (shown.* <= 100) std.debug.print("  {s}: {d}\n", .{ message, where });
    if (shown.* == 101) std.debug.print("  ...\n", .{});
}

/// One volume mounted read-only and checked.
fn checkVolume(place: Place, bytes: []const u8, data: bool) Outcome {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    var label: layout.Label = undefined;
    if (bytes.len < @sizeOf(layout.Label)) {
        std.debug.print("{s}: too short for a volume\n", .{place.name});
        return .unreadable;
    }
    @memcpy(layout.bytesOfMut(&label), bytes[0..@sizeOf(layout.Label)]);
    var medium: ImageMedia = .{ .bytes = bytes, .erase_unit = label.erase_size, .write_unit = label.write_unit, .allocator = gpa.allocator() };
    var fs = posfs_fs.FileSystem.init(posfs_fs.Device.of(ImageMedia, &medium));
    defer fs.deinit();
    fs.mount() catch |err| {
        std.debug.print("{s}: does not mount: {t}\n", .{ place.name, err });
        return .unreadable;
    };
    const vol = &fs.vol;
    std.debug.print("{s}: volume \"{s}\", {d} blocks of {d} bytes, checkpoint {d}", .{ place.name, fs.volumeName(), vol.block_count, vol.block_size, vol.durable.gen });
    if (vol.replayed.records != 0) std.debug.print(", {d} changes replayed from the journal", .{vol.replayed.records});
    if (vol.replayed.stopped) std.debug.print(", replay stopped short", .{});
    std.debug.print("\n", .{});
    var shown: u32 = 0;
    var report: posfs_fs.Report = .{ .each = printFault, .context = &shown };
    const totals = fs.checkWhole(data, &report) catch |err| {
        std.debug.print("  the check stopped: {t}\n", .{err});
        return .unreadable;
    };
    std.debug.print("  {d} objects, {d} nodes", .{ totals.objects, report.nodes });
    if (data) std.debug.print(", {d} data blocks", .{totals.data_blocks});
    if (report.errors == 0 and !vol.replayed.stopped) {
        std.debug.print(": no damage found\n", .{});
        return .clean;
    }
    std.debug.print(": {d} faults\n", .{report.errors});
    return .damaged;
}
