// SPDX-License-Identifier: MPL-2.0
//! mkfs: builds a disk image - a RigidDiskBlock, one partition, and the
//! flash file system on it - so the board boots with a `C:` instead of the
//! shell copying programs into RAM: at every start.
//!
//! usage: mkfs [--tree=<dir>] [--manifest=<file>] [--medium=<file>]
//!            [--system-file=<path>[=<host-file>] ...]
//!            [--gpt=<file> --gpt-bytes=<bytes> [--gpt-file=<path>[=<host-file>] ...]]
//!            <out.bin> <volume> <partition> <sectors> <partition-sectors>
//!            <sector-size> <page-size> <rdb-sectors>
//!            [<path-in-image>[=<host-file>] ...]
//!        mkfs --gpt=<file> --gpt-bytes=<bytes> --gpt-tree=<dir>
//!            [--gpt-system-bytes=<bytes>] [--gpt-boot-pri=<n>]
//!            [--gpt-file=<path>[=<host-file>] ...]
//!            [--gpt-work=<volume>:<partition>
//!             [--gpt-work-file=<path>[=<host-file>] ...]]
//!            [--gpt-installed=<device>:<unit>:<boot> --gpt-manifest=<file>]
//!            <volume> <partition>
//!        mkfs --blank --gpt=<file> --gpt-bytes=<bytes> <volume> <partition>
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
//! **The same disk as the image a machine is started from out of RAM**
//! (`--medium`): a second image, the same blocks but for the partition's
//! boot priority, which stands above the one `C:Install` gives a system
//! partition (`medium_boot_pri`). A machine whose loader read this image
//! from a stick (`./zig build stick -Dstick-ram`) then runs the image's
//! system, whatever a disk of its own holds; the disk image an installed
//! machine's loader brings along stays below its system partition.
//!
//! **The same volume on a disk with a GPT** (`--gpt`): an image of
//! `--gpt-bytes` for a disk of 512-byte blocks - an SSD - with what
//! `RDB INIT GPT`, `RDB ADD` and `Format` make of one: a GPT whose one
//! partition is a PowerOS container over every usable block from the
//! first MiB, a RigidDiskBlock in the container's first block, and one
//! partition from the container's first MiB to its end, under the same
//! name, bootable, with posfs on it holding the same files. posfs is the
//! handler's own code too (`src/disk/devs/handlers/posfs`, through the
//! `posfs` module), sent the same packets, over the image file itself.
//! The file is as long as the disk, but only what was written takes room
//! on the host: the rest is a hole, which reads as zeroes. A
//! `--gpt-file` goes on this disk alone, after everything else: a file
//! too large for the flash disk - a song to try a player with - on the
//! SSD that has room for it. One with no `=` is a drawer made there
//! alone; as in the ordinary list, a drawer comes before what goes in
//! it.
//!
//! **A blank disk** (`--blank`): only that disk, with an empty volume
//! and its partition not bootable - a disk to keep work on. Its only
//! arguments are the volume's name and the partition's.
//!
//! **A GPT disk alone, from a tree** (`--gpt-tree`): only the GPT disk,
//! its system volume holding what a directory on the host holds - a
//! release package's `system/` - in a manifest's order, so a drawer
//! comes before what is in it; `--gpt-file` after it as before. Its
//! arguments are the volume's name and the partition's, and it takes
//! what lays the disk out as an install does:
//! - `--gpt-system-bytes`: the system partition that large, from the
//!   container's first MiB, rather than the whole container.
//! - `--gpt-boot-pri`: the system partition's boot priority, 0 without
//!   it.
//! - `--gpt-work=<volume>:<partition>`: a second partition, from the
//!   first MiB past the system's to the container's end, posfs, not
//!   bootable, holding what `--gpt-work-file` gives it - in the order
//!   given, a drawer (no `=`) before what goes in it. Each file is read
//!   from the host a piece at a time as it is written, so a film is
//!   never in memory whole.
//! - `--gpt-installed=<device>:<unit>:<boot>` with `--gpt-manifest`: the
//!   system volume is one `C:Install` left, with the two files it writes
//!   besides the system's own (src/disk/c/install/files.zig): the
//!   package's manifest as `Storage/installed.manifest`, the list an
//!   update compares against, and `ENVARC:Sys/install.prefs`, which says
//!   the device and unit the system is on, the two partitions, the boot
//!   partition by its name in the GPT, and the board the manifest names.
//!   A medium made of such a disk and the partition the firmware reads
//!   in front of it (tools/mkstick `--system`) is what an install leaves
//!   on that machine's card.
//!
//! **The same files outside the image**, for a volume that is not made
//! from it - a card that is SYS:, brought up to date file by file
//! (tools/vf2_update.py in the port's repository). `--tree` writes every
//! file and directory the image gets under `<dir>` as well, and
//! `--manifest` lists the image's files, one line each: the CRC-32 of its
//! bytes in hex, its size, its path. A path given twice is the later
//! file's, as on the image, and the list is sorted by path.
//!
//! **A file of the system that the image has no room for**
//! (`--system-file`): a large font, the emoji's names. It goes into the
//! tree and the manifest, so a release package made of them has it and a
//! machine installed or brought up to date from a package gets it, and
//! onto the `--gpt` disk; the image, which a machine without a disk of
//! its own starts from out of RAM, is made without it. As with
//! `--gpt-file`, one with no `=` is a drawer, and these come after the
//! ordinary list.
//!
//! An image has no clock, so a build from the same inputs gives the same
//! image: every file is dated 1 Jan 1978.

const std = @import("std");
const mem = std.mem;
const sdk = @import("sdk");
const dos = sdk.dos;
const hardblocks = dos.hardblocks;
const flashfs = dos.flashfs;
const gpt = dos.gpt;
const install = sdk.install;
const manifest = install.manifest;
const prefs_install = sdk.prefs.install;
const disk = @import("fs");
const posfs = @import("posfs");

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

/// A GPT disk's block: an SSD's, and an NVMe namespace's in QEMU.
const gpt_block: u32 = 512;
/// Where the partition starts in the container, in blocks: one MiB in,
/// past the table's blocks, leaving room for file systems kept in the
/// table, and on a boundary of every block size posfs takes.
const gpt_partition_first: u32 = 2048;

/// The GPT disk as posfs's medium contract asks for it: the partition's
/// part of the image file, read and written in place. A disk erases for
/// itself, and the file system writes whole sectors.
const DiskMedia = struct {
    io: std.Io,
    file: std.Io.File,
    /// The partition: its first byte in the file, and how many it has.
    first: u64,
    length: u64,
    allocator: mem.Allocator,
    /// What the volume's random numbers are made from: the same disk made
    /// again gets the same ones.
    seed: [32]u8,
    drawn: u64 = 0,

    pub fn size(m: *DiskMedia) u64 {
        return m.length;
    }

    pub fn sectorSize(_: *DiskMedia) u32 {
        return gpt_block;
    }

    pub fn writeSize(_: *DiskMedia) u32 {
        return 0;
    }

    pub fn eraseSize(_: *DiskMedia) u32 {
        return 0;
    }

    pub fn mapped(_: *DiskMedia) ?[*]const u8 {
        return null;
    }

    pub fn read(m: *DiskMedia, at: u64, into: []u8) bool {
        if (at > m.length or into.len > m.length - at) return false;
        const got = m.file.readPositionalAll(m.io, into, m.first + at) catch return false;
        return got == into.len;
    }

    pub fn write(m: *DiskMedia, at: u64, from: []const u8) bool {
        if (at > m.length or from.len > m.length - at) return false;
        m.file.writePositionalAll(m.io, from, m.first + at) catch return false;
        return true;
    }

    pub fn erase(_: *DiskMedia, _: u64, _: u64) bool {
        return true;
    }

    pub fn update(_: *DiskMedia) bool {
        return true;
    }

    pub fn writable(_: *DiskMedia) bool {
        return true;
    }

    pub fn alloc(m: *DiskMedia, len: usize) ?[]u8 {
        const block = m.allocator.alignedAlloc(u8, .@"8", len) catch return null;
        @memset(block, 0);
        return block;
    }

    pub fn allocRaw(m: *DiskMedia, len: usize) ?[]u8 {
        return m.allocator.alignedAlloc(u8, .@"8", len) catch null;
    }

    pub fn free(m: *DiskMedia, block: []u8) void {
        const aligned: []align(8) u8 = @alignCast(block);
        m.allocator.free(aligned);
    }

    /// 1 Jan 1978, as every date on the flash disk.
    pub fn now(_: *DiskMedia) u64 {
        return 0;
    }

    pub fn random(m: *DiskMedia, into: *[16]u8) void {
        into.* = drawn(&m.seed, m.drawn)[0..16].*;
        m.drawn += 1;
    }
};

/// The `index`th number drawn from `seed`: random enough to tell volumes
/// and disks apart, and the same for the same inputs.
fn drawn(seed: *const [32]u8, index: u64) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(seed);
    hash.update(mem.asBytes(&index));
    return hash.finalResult();
}

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

/// The volume is full at `at`: says how much room it has, how much the
/// files asked for take, and which of them are the largest, and ends.
fn full(entries: []const Entry, at: []const u8, volume_bytes: u64) noreturn {
    var total: u64 = 0;
    var files: usize = 0;
    var largest: [10]?Entry = @splat(null);
    for (entries) |entry| {
        const content = entry.content orelse continue;
        total += content.len;
        files += 1;
        var held = entry;
        for (&largest) |*slot| {
            const kept = slot.* orelse {
                slot.* = held;
                break;
            };
            if (kept.content.?.len >= held.content.?.len) continue;
            slot.* = held;
            held = kept;
        }
    }
    std.debug.print("mkfs: the volume is full at {s}: it has {d} bytes, and the {d} files asked for are {d} bytes before what the file system needs for itself. The largest:\n", .{ at, volume_bytes, files, total });
    for (largest) |slot| {
        const entry = slot orelse break;
        std.debug.print("  {d:>9}  {s}\n", .{ entry.content.?.len, entry.path });
    }
    std.process.exit(1);
}

/// What the command line puts on the volume of `volume_bytes` bytes,
/// sent as packets.
fn fill(fs: anytype, entries: []const Entry, volume_bytes: u64) void {
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
        if (written.res1 != @as(isize, @intCast(content.len))) {
            if (written.res2 == dos.ERROR_DISK_FULL) full(entries, path, volume_bytes);
            fatal("{s}: only {d} of {d} bytes ({d})", .{ path, written.res1, content.len, written.res2 });
        }
        const closed = send(fs, .end, .{ .file = .{ .fh = &fh } });
        if (closed.res1 == dos.DOSFALSE) fatal("{s}: cannot close it ({d})", .{ path, closed.res2 });
        // The programs on disk are pure, so `resident` takes them without
        // being forced.
        const protect = send(fs, .set_protect, .{ .property = .{ .lock = null, .name = path.ptr, .value = dos.FIBF_PURE } });
        if (protect.res1 == dos.DOSFALSE) fatal("{s}: cannot set its bits ({d})", .{ path, protect.res2 });
    }
}

/// The partition's boot priority on the medium a machine is started from
/// (`--medium`): above the 5 `C:Install` gives a system partition
/// (src/disk/c/install/disk.zig), so the medium's system is the one that
/// runs.
const medium_boot_pri: i32 = 10;

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
    var medium_path: ?[]const u8 = null;
    var gpt_path: ?[]const u8 = null;
    var gpt_bytes: u64 = 0;
    var gpt_tree: ?[]const u8 = null;
    var gpt_system_bytes: u64 = 0;
    var gpt_boot_pri: i32 = 0;
    var gpt_work: ?[]const u8 = null;
    var gpt_installed: ?[]const u8 = null;
    var gpt_manifest: ?[]const u8 = null;
    var blank = false;
    var system_only: std.ArrayList([]const u8) = .empty;
    var gpt_only: std.ArrayList([]const u8) = .empty;
    var work_only: std.ArrayList([]const u8) = .empty;
    var kept: std.ArrayList([:0]const u8) = .empty;
    for (all_args, 0..) |arg, index| {
        if (index == 0 or !mem.startsWith(u8, arg, "--")) {
            try kept.append(arena, arg);
        } else if (mem.startsWith(u8, arg, "--tree=")) {
            tree_path = arg["--tree=".len..];
        } else if (mem.startsWith(u8, arg, "--manifest=")) {
            manifest_path = arg["--manifest=".len..];
        } else if (mem.startsWith(u8, arg, "--medium=")) {
            medium_path = arg["--medium=".len..];
        } else if (mem.startsWith(u8, arg, "--gpt=")) {
            gpt_path = arg["--gpt=".len..];
        } else if (mem.startsWith(u8, arg, "--gpt-bytes=")) {
            const text = arg["--gpt-bytes=".len..];
            gpt_bytes = std.fmt.parseInt(u64, text, 0) catch fatal("{s}: not a number", .{text});
        } else if (mem.startsWith(u8, arg, "--system-file=")) {
            try system_only.append(arena, arg["--system-file=".len..]);
        } else if (mem.startsWith(u8, arg, "--gpt-file=")) {
            try gpt_only.append(arena, arg["--gpt-file=".len..]);
        } else if (mem.startsWith(u8, arg, "--gpt-tree=")) {
            gpt_tree = arg["--gpt-tree=".len..];
        } else if (mem.startsWith(u8, arg, "--gpt-system-bytes=")) {
            const text = arg["--gpt-system-bytes=".len..];
            gpt_system_bytes = std.fmt.parseInt(u64, text, 0) catch fatal("{s}: not a number", .{text});
        } else if (mem.startsWith(u8, arg, "--gpt-boot-pri=")) {
            const text = arg["--gpt-boot-pri=".len..];
            gpt_boot_pri = std.fmt.parseInt(i8, text, 0) catch fatal("{s}: not a boot priority, -128 to 127", .{text});
        } else if (mem.startsWith(u8, arg, "--gpt-work=")) {
            gpt_work = arg["--gpt-work=".len..];
        } else if (mem.startsWith(u8, arg, "--gpt-work-file=")) {
            try work_only.append(arena, arg["--gpt-work-file=".len..]);
        } else if (mem.startsWith(u8, arg, "--gpt-installed=")) {
            gpt_installed = arg["--gpt-installed=".len..];
        } else if (mem.startsWith(u8, arg, "--gpt-manifest=")) {
            gpt_manifest = arg["--gpt-manifest=".len..];
        } else if (mem.eql(u8, arg, "--blank")) {
            blank = true;
        } else fatal("{s}: no such option", .{arg});
    }
    const args = kept.items;
    const cwd = std.Io.Dir.cwd();
    if (gpt_path != null and gpt_bytes == 0) fatal("--gpt: --gpt-bytes says how large the disk is", .{});
    if (gpt_path == null and gpt_only.items.len != 0) fatal("--gpt-file: there is no --gpt disk to put it on", .{});
    if (gpt_tree == null) {
        // What lays a disk out as an install does is for a disk made
        // from a tree alone.
        if (gpt_system_bytes != 0) fatal("--gpt-system-bytes: only with --gpt-tree", .{});
        if (gpt_boot_pri != 0) fatal("--gpt-boot-pri: only with --gpt-tree", .{});
        if (gpt_work != null or work_only.items.len != 0) fatal("--gpt-work: only with --gpt-tree", .{});
        if (gpt_installed != null or gpt_manifest != null) fatal("--gpt-installed: only with --gpt-tree", .{});
    }
    if (blank) {
        if (args.len != 3 or gpt_path == null) fatal("usage: mkfs --blank --gpt=<file> --gpt-bytes=<bytes> <volume> <partition>", .{});
        checkDrive(args[2]);
        gptDisk(io, cwd, .{ .path = gpt_path.?, .bytes = gpt_bytes, .label = args[1], .drive = args[2], .bootable = false, .entries = &.{} }, arena);
        return;
    }
    if (gpt_tree) |tree| {
        if (args.len != 3 or gpt_path == null) fatal("usage: mkfs --gpt=<file> --gpt-bytes=<bytes> --gpt-tree=<dir> [...] <volume> <partition>", .{});
        checkDrive(args[2]);
        if (work_only.items.len != 0 and gpt_work == null) fatal("--gpt-work-file: there is no --gpt-work partition to put it on", .{});
        if ((gpt_installed == null) != (gpt_manifest == null)) fatal("--gpt-installed and --gpt-manifest come together: the install's record and the list it was installed from", .{});
        const work: ?Work = if (gpt_work) |text| work: {
            const colon = mem.indexOfScalar(u8, text, ':') orelse fatal("--gpt-work={s}: it is <volume>:<partition>", .{text});
            const drive = text[colon + 1 ..];
            if (colon == 0 or drive.len == 0) fatal("--gpt-work={s}: it is <volume>:<partition>", .{text});
            checkDrive(drive);
            if (std.ascii.eqlIgnoreCase(drive, args[2])) fatal("--gpt-work={s}: the system partition is {s} already", .{ text, args[2] });
            var streamed: std.ArrayList(Streamed) = .empty;
            for (work_only.items) |entry| try streamed.append(arena, try streamedOf(entry, arena));
            break :work .{ .label = text[0..colon], .drive = drive, .entries = streamed.items };
        } else null;

        var entries: std.ArrayList(Entry) = .empty;
        try treeEntries(io, cwd, tree, arena, &entries);
        for (gpt_only.items) |entry| try entries.append(arena, try entryOf(io, cwd, entry, arena));
        if (gpt_installed) |text| try installedRecords(io, cwd, text, gpt_manifest.?, args[2], if (work) |one| one.drive else "", arena, &entries);
        gptDisk(io, cwd, .{
            .path = gpt_path.?,
            .bytes = gpt_bytes,
            .label = args[1],
            .drive = args[2],
            .bootable = true,
            .boot_pri = gpt_boot_pri,
            .system_bytes = gpt_system_bytes,
            .entries = entries.items,
            .work = work,
        }, arena);
        return;
    }
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
    checkDrive(drive);

    // Everything the volume gets, read first; then what the system has
    // besides, which the tree, the manifest and the GPT disk get; then
    // what the GPT disk alone gets.
    var entries: std.ArrayList(Entry) = .empty;
    for (args[9..]) |entry| try entries.append(arena, try entryOf(io, cwd, entry, arena));
    const shared = entries.items.len;
    for (system_only.items) |entry| try entries.append(arena, try entryOf(io, cwd, entry, arena));
    const system = entries.items.len;
    for (gpt_only.items) |entry| try entries.append(arena, try entryOf(io, cwd, entry, arena));

    if (tree_path) |path| try writeTree(io, cwd, path, entries.items[0..system]);
    if (manifest_path) |path| try writeManifest(io, cwd, path, entries.items[0..system], arena);

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

    const used = flashfsVolume(store, rdb_blocks, part_sectors, sector_size, page_size, label, entries.items[0..shared], arena);
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = store[0..used] });
    if (medium_path) |path| {
        var started = part;
        started.environment.boot_pri = medium_boot_pri;
        putBlock(store, partition_block, sector_size, &started);
        try cwd.writeFile(io, .{ .sub_path = path, .data = store[0..used] });
    }
    if (gpt_path) |path| gptDisk(io, cwd, .{ .path = path, .bytes = gpt_bytes, .label = label, .drive = drive, .bootable = true, .entries = entries.items }, arena);
}

/// One path on the command line: a directory to make, or with `=` a file
/// and the host file it is read from.
fn entryOf(io: std.Io, cwd: std.Io.Dir, entry: []const u8, arena: mem.Allocator) !Entry {
    const split = mem.indexOfScalar(u8, entry, '=');
    const path = try arena.dupeZ(u8, if (split) |at| entry[0..at] else entry);
    const content: ?[]const u8 = if (split) |at| try cwd.readFileAlloc(io, entry[at + 1 ..], arena, .unlimited) else null;
    return .{ .path = path, .content = content };
}

/// A partition's name that fits its PartitionBlock.
fn checkDrive(drive: []const u8) void {
    if (drive.len >= @typeInfo(@FieldType(hardblocks.PartitionBlock, "drive_name")).array.len) {
        fatal("{s}: too long for a partition name", .{drive});
    }
}

/// What the GPT disk holds: its size, the system partition and its
/// volume, and the work partition where there is one.
const GptDisk = struct {
    path: []const u8,
    bytes: u64,
    /// The system volume's name and its partition's.
    label: []const u8,
    drive: []const u8,
    bootable: bool,
    /// The system partition's boot priority.
    boot_pri: i32 = 0,
    /// How large the system partition is; 0 for the whole container.
    system_bytes: u64 = 0,
    /// What the system volume holds.
    entries: []const Entry,
    /// The second partition, over the rest of the container.
    work: ?Work = null,
};

/// The work partition (`--gpt-work`): its volume's name, its
/// partition's, and what the volume holds.
const Work = struct {
    label: []const u8,
    drive: []const u8,
    entries: []const Streamed,
};

/// A drawer to make, or a file read from the host as it is written.
const Streamed = struct { path: [:0]const u8, host: ?[]const u8 };

/// The fewest blocks the work partition may have: what posfs takes for
/// a volume with room in it (its limits: 64 blocks of up to 64 KiB).
const min_work_blocks: u64 = 64 * 128;

/// The GPT disk: its GPT and the copy at its end, the PowerOS container,
/// the table in it, posfs on the table's system partition with what
/// `gpt_disk.entries` puts there, and on the work partition, where there
/// is one, what `gpt_disk.work` does.
fn gptDisk(io: std.Io, cwd: std.Io.Dir, gpt_disk: GptDisk, arena: mem.Allocator) void {
    const path = gpt_disk.path;
    const bytes = gpt_disk.bytes;
    const label = gpt_disk.label;
    const drive = gpt_disk.drive;
    if (bytes % gpt_block != 0) fatal("--gpt-bytes={d}: not whole {d}-byte blocks", .{ bytes, gpt_block });
    if (gpt_disk.system_bytes % gpt_block != 0) fatal("--gpt-system-bytes={d}: not whole {d}-byte blocks", .{ gpt_disk.system_bytes, gpt_block });
    const blocks = bytes / gpt_block;
    var seed: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(label);
    hash.update(drive);
    hash.update(mem.asBytes(&bytes));
    hash.final(&seed);
    var disk_guid = drawn(&seed, 0)[0..16].*;
    gpt.markRandom(&disk_guid);
    var header = gpt.freshHeader(blocks, gpt_block, &disk_guid) orelse fatal("--gpt-bytes={d}: too small for a GPT", .{bytes});

    // The container over every usable block from the first aligned one.
    var container: gpt.Entry = .{
        .partition_type_guid = gpt.TYPE_CONTAINER,
        .unique_partition_guid = drawn(&seed, 1)[0..16].*,
        .starting_lba = gpt.alignUp(header.first_usable_lba, gpt_block),
        .ending_lba = header.last_usable_lba,
    };
    gpt.markRandom(&container.unique_partition_guid);
    gpt.setName(&container, "PowerOS");
    const container_blocks = container.ending_lba - container.starting_lba + 1;
    if (container_blocks > 0xFFFF_FFFF) fatal("--gpt-bytes={d}: a table counts at most 2^32 blocks", .{bytes});
    if (container_blocks < gpt_partition_first + 2) fatal("--gpt-bytes={d}: no room for a partition", .{bytes});

    // The system partition from the container's first MiB, as large as
    // asked or to the container's end; the work partition from the first
    // MiB past it to the end. Block numbers count from the container's
    // first block, and a cylinder is a block.
    const system_last: u64 = if (gpt_disk.system_bytes == 0)
        container_blocks - 1
    else
        gpt_partition_first + gpt_disk.system_bytes / gpt_block - 1;
    if (system_last >= container_blocks) fatal("--gpt-system-bytes={d}: the container has {d} bytes from its first MiB", .{ gpt_disk.system_bytes, (container_blocks - gpt_partition_first) * gpt_block });
    const work_first = gpt.alignUp(system_last + 1, gpt_block);
    if (gpt_disk.work != null and (work_first >= container_blocks or container_blocks - work_first < min_work_blocks))
        fatal("--gpt-work: the container has no room past the system partition's {d} bytes", .{(system_last + 1 - gpt_partition_first) * gpt_block});

    const file = cwd.createFile(io, path, .{ .read = true }) catch |e| fatal("{s}: {t}", .{ path, e });
    defer file.close(io);
    file.setLength(io, bytes) catch |e| fatal("{s}: {t}", .{ path, e });

    // The protective MBR, the GPT with its entries, and the copy of both
    // at the end.
    const entries_bytes = arena.alloc(u8, @intCast(gpt.entriesBlocks(&header, gpt_block) * gpt_block)) catch fatal("out of memory", .{});
    @memset(entries_bytes, 0);
    gpt.putEntry(&header, entries_bytes, 0, &container);
    const entries_crc = gpt.entriesCrc(&header, entries_bytes);
    var block: [gpt_block]u8 = undefined;
    gpt.makeProtective(&block, blocks);
    writeAt(io, file, path, &block, 0);
    var backup = gpt.backupOf(&header);
    gpt.putHeader(&header, entries_crc, &block);
    writeAt(io, file, path, &block, header.my_lba * gpt_block);
    writeAt(io, file, path, entries_bytes, header.partition_entry_lba * gpt_block);
    gpt.putHeader(&backup, entries_crc, &block);
    writeAt(io, file, path, &block, backup.my_lba * gpt_block);
    writeAt(io, file, path, entries_bytes, backup.partition_entry_lba * gpt_block);

    // The table in the container, as InitRDB makes it - its blocks the
    // first RDB_LOCATION_LIMIT, a cylinder a block - and the partition
    // from the container's first MiB to its end. Block numbers count from
    // the container's first block.
    const cylinders: u32 = @intCast(container_blocks);
    var rdb: hardblocks.RigidDiskBlock = .{
        .block_bytes = gpt_block,
        .partition_list = partition_block,
        .cylinders = cylinders,
        .sectors = 1,
        .heads = 1,
        .rdb_blocks_lo = 0,
        .rdb_blocks_hi = min_rdb_blocks - 1,
        .lo_cylinder = min_rdb_blocks,
        .hi_cylinder = cylinders - 1,
        .cyl_blocks = 1,
    };
    @memcpy(rdb.disk_vendor[0.."PowerOS".len], "PowerOS");
    @memcpy(rdb.disk_product[0.."disk image".len], "disk image");
    var part: hardblocks.PartitionBlock = .{
        .next = if (gpt_disk.work != null) work_block else hardblocks.end_of_list,
        .flags = if (gpt_disk.bootable) hardblocks.PBFF_BOOTABLE else 0,
        .environment = .{
            .size_block = gpt_block,
            .low_cyl = gpt_partition_first,
            .high_cyl = @intCast(system_last),
            .num_buffers = buffers,
            .buf_mem_type = sdk.exec.MEMF_ANY,
            .boot_pri = gpt_disk.boot_pri,
            .dos_type = dos.posfs.ID_POSFS_DISK,
        },
    };
    @memcpy(part.drive_name[0..drive.len], drive);
    var table: [3 * gpt_block]u8 = @splat(0);
    putBlock(&table, rdb_block, gpt_block, &rdb);
    putBlock(&table, partition_block, gpt_block, &part);
    if (gpt_disk.work) |work| {
        var second: hardblocks.PartitionBlock = .{
            .environment = .{
                .size_block = gpt_block,
                .low_cyl = @intCast(work_first),
                .high_cyl = cylinders - 1,
                .num_buffers = buffers,
                .buf_mem_type = sdk.exec.MEMF_ANY,
                .dos_type = dos.posfs.ID_POSFS_DISK,
            },
        };
        @memcpy(second.drive_name[0..work.drive.len], work.drive);
        putBlock(&table, work_block, gpt_block, &second);
    }
    writeAt(io, file, path, &table, container.starting_lba * gpt_block);

    // posfs on the partition, filled, and put away clean.
    var media: DiskMedia = .{
        .io = io,
        .file = file,
        .first = (container.starting_lba + gpt_partition_first) * gpt_block,
        .length = (system_last + 1 - gpt_partition_first) * gpt_block,
        // Not the arena: the file system frees as much as it takes,
        // packet after packet.
        .allocator = std.heap.smp_allocator,
        .seed = drawn(&seed, 2),
    };
    var fs = posfs.FileSystem.init(posfs.Device.of(DiskMedia, &media));
    defer fs.deinit();
    fs.format(.{ .name = label, .partition_block = gpt_block }) catch |e| fatal("{s}: format: {t}", .{ path, e });
    fill(&fs, gpt_disk.entries, media.length);
    fs.unmount() catch |e| fatal("{s}: unmount: {t}", .{ path, e });

    // And posfs on the work partition, its files read from the host as
    // they are written.
    const work = gpt_disk.work orelse return;
    var work_media: DiskMedia = .{
        .io = io,
        .file = file,
        .first = (container.starting_lba + work_first) * gpt_block,
        .length = (container_blocks - work_first) * gpt_block,
        .allocator = std.heap.smp_allocator,
        .seed = drawn(&seed, 3),
    };
    var work_fs = posfs.FileSystem.init(posfs.Device.of(DiskMedia, &work_media));
    defer work_fs.deinit();
    work_fs.format(.{ .name = work.label, .partition_block = gpt_block }) catch |e| fatal("{s}: format {s}: {t}", .{ path, work.drive, e });
    const piece = arena.alloc(u8, stream_piece) catch fatal("out of memory", .{});
    fillStreamed(&work_fs, io, cwd, work.entries, work_media.length, piece);
    work_fs.unmount() catch |e| fatal("{s}: unmount {s}: {t}", .{ path, work.drive, e });
}

/// Where the work partition's PartitionBlock goes: after the system
/// partition's, in the table's blocks.
const work_block: u32 = partition_block + 1;

/// How much of a file on the host is read and written at a time.
const stream_piece: usize = 8 * 1024 * 1024;

/// What `--gpt-work-file` puts on the work volume, in the order given:
/// each file read from the host a piece at a time and written as it is
/// read.
fn fillStreamed(fs: anytype, io: std.Io, cwd: std.Io.Dir, entries: []const Streamed, volume_bytes: u64, piece: []u8) void {
    var written_total: u64 = 0;
    for (entries) |entry| {
        const path = entry.path;
        const host = entry.host orelse {
            const made = send(fs, .create_dir, .{ .raw = .{ 0, @bitCast(@intFromPtr(path.ptr)), dos.EXCLUSIVE_LOCK, 0, 0, 0, 0 } });
            if (made.res1 == 0) fatal("{s}: cannot make it ({d})", .{ path, made.res2 });
            _ = send(fs, .free_lock, .{ .raw = .{ made.res1, 0, 0, 0, 0, 0, 0 } });
            continue;
        };
        const source = cwd.openFile(io, host, .{}) catch |e| fatal("{s}: {t}", .{ host, e });
        defer source.close(io);
        var fh: dos.FileHandle = .{};
        const opened = send(fs, .findoutput, .{ .find = .{ .fh = &fh, .lock = null, .name = path.ptr } });
        if (opened.res1 == dos.DOSFALSE) fatal("{s}: cannot write it ({d})", .{ path, opened.res2 });
        var at: u64 = 0;
        while (true) {
            const got = source.readPositionalAll(io, piece, at) catch |e| fatal("{s}: {t}", .{ host, e });
            if (got == 0) break;
            const written = send(fs, .write, .{ .io = .{ .fh = &fh, .buffer = piece.ptr, .length = @intCast(got) } });
            if (written.res1 != @as(isize, @intCast(got))) {
                if (written.res2 == dos.ERROR_DISK_FULL)
                    fatal("the work volume is full at {s}: it has {d} bytes, and {d} were written before it", .{ path, volume_bytes, written_total + at });
                fatal("{s}: only {d} of {d} bytes ({d})", .{ path, at + @as(u64, @intCast(@max(written.res1, 0))), at + got, written.res2 });
            }
            at += got;
            if (got < piece.len) break;
        }
        written_total += at;
        const closed = send(fs, .end, .{ .file = .{ .fh = &fh } });
        if (closed.res1 == dos.DOSFALSE) fatal("{s}: cannot close it ({d})", .{ path, closed.res2 });
    }
}

/// One `--gpt-work-file`: a drawer to make, or with `=` a file and the
/// host file it is read from.
fn streamedOf(entry: []const u8, arena: mem.Allocator) !Streamed {
    const split = mem.indexOfScalar(u8, entry, '=');
    const path = try arena.dupeZ(u8, if (split) |at| entry[0..at] else entry);
    return .{ .path = path, .host = if (split) |at| entry[at + 1 ..] else null };
}

/// Every drawer and file under `root` on the host, as the volume's
/// entries, in a manifest's order: a drawer before what is in it, and the
/// same volume from the same tree whatever order the host lists it in.
fn treeEntries(io: std.Io, cwd: std.Io.Dir, root: []const u8, arena: mem.Allocator, entries: *std.ArrayList(Entry)) !void {
    var dir = cwd.openDir(io, root, .{ .iterate = true }) catch |e| fatal("{s}: {t}", .{ root, e });
    defer dir.close(io);
    var found: std.ArrayList(Entry) = .empty;
    var walker = try dir.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const path = try arena.dupeZ(u8, entry.path);
        switch (entry.kind) {
            .directory => try found.append(arena, .{ .path = path, .content = null }),
            .file => {
                const content = entry.dir.readFileAlloc(io, entry.basename, arena, .unlimited) catch |e|
                    fatal("{s}/{s}: {t}", .{ root, entry.path, e });
                try found.append(arena, .{ .path = path, .content = content });
            },
            else => fatal("{s}/{s}: neither a file nor a drawer", .{ root, entry.path }),
        }
    }
    const Sort = struct {
        fn before(_: void, a: Entry, b: Entry) bool {
            return manifest.orderPaths(a.path, b.path) == .before;
        }
    };
    mem.sort(Entry, found.items, {}, Sort.before);
    try entries.appendSlice(arena, found.items);
}

/// Where `C:Install` keeps its record in ENVARC:, by the path on the
/// volume that S:Startup-Sequence assigns ENVARC: to.
const install_prefs_path = "Prefs/Env-Archive/Sys/install.prefs";

/// The two files `C:Install` leaves on a system volume besides the
/// system's own (`--gpt-installed`, `--gpt-manifest`): the list it was
/// installed from, where an update reads it, and its record of where
/// the system went - `<device>:<unit>:<boot>` the device and unit, and
/// the boot partition's name in the GPT; `system` and `work` the two
/// partitions' drives, `work` empty where there is none; the board the
/// list names. Neither says where the files came from or when: they came
/// from a build, not from a place the machine could look again.
fn installedRecords(io: std.Io, cwd: std.Io.Dir, text: []const u8, manifest_path: []const u8, system: []const u8, work: []const u8, arena: mem.Allocator, entries: *std.ArrayList(Entry)) !void {
    var parts = mem.splitScalar(u8, text, ':');
    const device = parts.next() orelse "";
    const unit_text = parts.next() orelse "";
    const boot = parts.next() orelse "";
    if (device.len == 0 or boot.len == 0 or parts.next() != null)
        fatal("--gpt-installed={s}: it is <device>:<unit>:<boot>", .{text});
    const unit = std.fmt.parseInt(u32, unit_text, 10) catch fatal("--gpt-installed={s}: {s} is no unit", .{ text, unit_text });

    const list = cwd.readFileAlloc(io, manifest_path, arena, .unlimited) catch |e| fatal("{s}: {t}", .{ manifest_path, e });
    const reader = manifest.Reader.init(list) catch |e| fatal("{s}: {s}", .{ manifest_path, manifest.why(e) });

    var settings: prefs_install.Settings = .{};
    setField(&settings.device, device, "the device");
    settings.unit = unit;
    setField(&settings.system, system, "the system partition");
    setField(&settings.work, work, "the work partition");
    setField(&settings.boot, boot, "the boot partition");
    setField(&settings.board, reader.header.board, "the board");
    var line: [prefs_install.max_line]u8 = undefined;
    const length = prefs_install.write(&settings, &line);
    const record = try mem.concat(arena, u8, &.{ prefs_install.header, line[0..length], "\n" });

    try needDrawers(arena, entries, install.installed_manifest["SYS:".len..]);
    try entries.append(arena, .{ .path = try arena.dupeZ(u8, install.installed_manifest["SYS:".len..]), .content = list });
    try needDrawers(arena, entries, install_prefs_path);
    try entries.append(arena, .{ .path = install_prefs_path, .content = record });
}

/// A field of the install's record set to `value`, which must fit.
fn setField(field: anytype, value: []const u8, what: []const u8) void {
    if (value.len > field.len) fatal("{s}: {s} is too long for the install's record", .{ what, value });
    field.* = @splat(0);
    @memcpy(field[0..value.len], value);
}

/// The drawers above `path` that `entries` does not make, added to it,
/// outermost first.
fn needDrawers(arena: mem.Allocator, entries: *std.ArrayList(Entry), path: []const u8) !void {
    var at: usize = 0;
    while (mem.indexOfScalarPos(u8, path, at, '/')) |slash| : (at = slash + 1) {
        const drawer = path[0..slash];
        for (entries.items) |entry| {
            if (entry.content == null and manifest.samePath(entry.path, drawer)) break;
        } else try entries.append(arena, .{ .path = try arena.dupeZ(u8, drawer), .content = null });
    }
}

fn writeAt(io: std.Io, file: std.Io.File, path: []const u8, bytes: []const u8, at: u64) void {
    file.writePositionalAll(io, bytes, at) catch |e| fatal("{s}: {t}", .{ path, e });
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
    fill(&fs, entries, media.length);
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
