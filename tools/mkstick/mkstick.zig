// SPDX-License-Identifier: MPL-2.0
//! mkstick: makes the medium a machine whose firmware is UEFI starts
//! from - an image to write to a USB stick - out of the files that
//! firmware and the loader read.
//!
//! usage: mkstick --into=<image> [--size=<MiB>] [--label=<name>]
//!                [--name=<partition>] <path on the stick>=<file> ...
//!
//! What it writes: a protective MBR, a GPT whose one partition is an EFI
//! System partition over the medium from the first mebibyte on, and a
//! FAT32 volume on that partition holding the files it was given.
//!
//! A UEFI firmware reads one name off such a partition and no other,
//! `EFI/BOOT/BOOTX64.EFI`, so that is where the loader goes; the loader
//! then reads `kernel.bin` and `disk-x64.bin` from beside itself, and
//! the machine comes up on the disk image in RAM - from where
//! `C:Install` puts a system on a disk of the machine's own.
//!
//! **The volume is the file system's own format.** `format.write`
//! (`src/disk/devs/handlers/fat/fat32/format.zig`, through that
//! handler's `host.zig`) lays down the boot sector, both copies of the
//! table, the free-count sector and the root directory, with the cluster
//! size a volume that size gets. So there is one implementation of the
//! format and what this writes is what the handler mounts.
//!
//! The files are added here rather than through the handler: its own
//! file path wants a library base, which a tool on the host has no
//! business bringing up, and a boot medium holds a handful of files whose
//! names fit a directory entry as it stands. One that does not is
//! refused, not shortened - a medium is no place for a tool to invent
//! names on.
//!
//! The image is as long as the medium it describes and holds only the
//! blocks that were written, so it takes a few megabytes on the host
//! until it is written out to a stick.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const sdk = @import("sdk");
const gpt = sdk.dos.gpt;
const fat = sdk.dos.fat;
const fat_host = @import("fat32");
const format = fat_host.format;

fn fatal(comptime message: []const u8, args: anytype) noreturn {
    std.debug.print("mkstick: " ++ message ++ "\n", args);
    std.process.exit(1);
}

/// The medium's block, which is a stick's and what a GPT is written in.
const block_bytes: u32 = 512;

/// The volume's cluster, asked for rather than left to the volume's
/// size: four kibibytes is what a PC's own format gives a partition of
/// this order, and what a firmware is most used to reading.
const cluster_bytes: u32 = 4096;

/// How much of the medium the volume takes unless `--size` says
/// otherwise. FAT32 wants `format.min_clusters` clusters before a reader
/// will take it for FAT32 at all, which at four kibibytes each is 256
/// MiB; this leaves room above that for a kernel, a disk image and
/// whatever else is put beside them.
const default_size_mib: u64 = 320;

/// What the partition is called in the GPT, and the volume in its boot
/// sector, unless `--name` and `--label` say otherwise.
const default_name = "PowerOS boot";
const default_label = "POWEROS";

/// A file or a directory asked for, and where it goes.
const Give = struct {
    /// Its path on the stick, `/` between the parts.
    path: []const u8,
    /// A file's bytes; null for a directory to make.
    bytes: ?[]const u8,
};

/// A directory or a file on the way to the medium.
const Node = struct {
    /// Its name as a directory entry holds it: eight and three,
    /// space-padded.
    short: [fat.ent_name_bytes]u8,
    /// A file's bytes; null for a directory.
    bytes: ?[]const u8,
    /// A directory's children, in the order they were given.
    children: std.ArrayList(*Node) = .empty,
    /// Where its first cluster is, once the clusters have been handed
    /// out, and how many it has.
    cluster: u32 = 0,
    clusters: u32 = 0,
    /// The directory it is in; null for the root.
    parent: ?*Node = null,

    fn isDir(node: *const Node) bool {
        return node.bytes == null;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const cwd = std.Io.Dir.cwd();

    var into: ?[]const u8 = null;
    var size_mib: u64 = default_size_mib;
    var label_text: []const u8 = default_label;
    var name_text: []const u8 = default_name;
    var given: std.ArrayList(Give) = .empty;
    for (args, 0..) |arg, index| {
        if (index == 0) continue;
        if (mem.startsWith(u8, arg, "--into=")) {
            into = arg["--into=".len..];
        } else if (mem.startsWith(u8, arg, "--size=")) {
            size_mib = std.fmt.parseInt(u64, arg["--size=".len..], 10) catch
                fatal("--size: {s} is not a number of mebibytes", .{arg["--size=".len..]});
        } else if (mem.startsWith(u8, arg, "--label=")) {
            label_text = arg["--label=".len..];
        } else if (mem.startsWith(u8, arg, "--name=")) {
            name_text = arg["--name=".len..];
        } else if (mem.startsWith(u8, arg, "--")) {
            fatal("{s}: no such option", .{arg});
        } else {
            const split = mem.indexOfScalar(u8, arg, '=');
            const path = if (split) |at| arg[0..at] else arg;
            const bytes: ?[]const u8 = if (split) |at|
                cwd.readFileAlloc(io, arg[at + 1 ..], arena, .unlimited) catch |e|
                    fatal("{s}: {t}", .{ arg[at + 1 ..], e })
            else
                null;
            try given.append(arena, .{ .path = path, .bytes = bytes });
        }
    }
    const path = into orelse fatal(
        "usage: mkstick --into=<image> [--size=<MiB>] [--label=<name>] [--name=<partition>] <path on the stick>=<file> ...",
        .{},
    );
    if (given.items.len == 0) fatal("nothing to put on it: give at least the loader the firmware reads", .{});
    const label = fat_host.shortLabel(label_text) catch
        fatal("--label: {s} is not a name a volume can carry", .{label_text});

    // The tree, and what it takes.
    const root = try arena.create(Node);
    root.* = .{ .short = @splat(' '), .bytes = null };
    for (given.items) |one| try place(arena, root, one);

    const made = layOut(root, size_mib) orelse fatal(
        "--size={d}: a volume that small cannot hold the files, or cannot be FAT32 at all",
        .{size_mib},
    );
    const blocks = made.plan.first + made.plan.total + backBlocks();

    // The image: as long as the medium, holding what was written.
    const file = cwd.createFile(io, path, .{ .read = true }) catch |e| fatal("{s}: {t}", .{ path, e });
    defer file.close(io);
    var image: Image = .{ .io = io, .file = file, .path = path, .arena = arena };
    image.end(blocks);

    const seed = seedOf(label_text, name_text, blocks);
    writeTable(&image, blocks, made.plan, name_text, &seed);
    format.write(&image, made.plan, label, serialOf(&seed), made_stamp) catch |e|
        fatal("{s}: the volume could not be laid down: {t}", .{ path, e });
    writeFiles(&image, made.plan, root, made.clusters_used);

    // The report goes to the standard output: a tool run by hand says
    // what it made, and a build that runs it for its output file keeps
    // its own summary clean.
    const used = (made.clusters_used - 1) * @as(u64, made.plan.sectors_per_cluster) * block_bytes;
    var out_buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    out.interface.print(
        \\mkstick: {s}
        \\  medium        {d} MiB, blocks of {d} bytes
        \\  partition     EFI System, blocks {d} to {d}, "{s}"
        \\  volume        FAT32 "{s}", clusters of {d} bytes, {d} of them
        \\  on it         {d} bytes in {d} files and {d} drawers
        \\
        \\Write it to a stick with:
        \\  sudo dd if={s} of=/dev/sdX bs=4M conv=fsync status=progress
        \\
    , .{
        path,
        blocks * block_bytes / (1024 * 1024),
        block_bytes,
        made.plan.first,
        made.plan.first + made.plan.total - 1,
        name_text,
        label_text,
        made.plan.sectors_per_cluster * block_bytes,
        made.plan.clusters,
        used,
        count(root, false),
        count(root, true),
        path,
    }) catch |e| fatal("the report could not be written: {t}", .{e});
    out.flush() catch |e| fatal("the report could not be written: {t}", .{e});
}

/// `one` put in the tree under `root`, the drawers on the way to it made
/// as they are met.
fn place(arena: Allocator, root: *Node, one: Give) !void {
    var node = root;
    var parts = mem.splitScalar(u8, one.path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const last = parts.peek() == null;
        const short = shortName(part) orelse fatal(
            "{s}: a directory entry holds eight characters and three, and this tool does not shorten a name for you",
            .{part},
        );
        if (find(node, &short)) |had| {
            if (last) fatal("{s}: given twice", .{one.path});
            if (!had.isDir()) fatal("{s}: {s} is a file on the way to it", .{ one.path, part });
            node = had;
            continue;
        }
        if (!node.isDir()) fatal("{s}: {s} is a file on the way to it", .{ one.path, part });
        const made = try arena.create(Node);
        made.* = .{
            .short = short,
            .bytes = if (last) one.bytes else null,
            .parent = node,
        };
        try node.children.append(arena, made);
        node = made;
    }
    if (node == root) fatal("{s}: no name in it", .{one.path});
}

/// The child of `node` by that name, if it has one.
fn find(node: *Node, short: *const [fat.ent_name_bytes]u8) ?*Node {
    for (node.children.items) |child| {
        if (mem.eql(u8, &child.short, short)) return child;
    }
    return null;
}

/// The files or the drawers in the tree, `root` itself left out.
fn count(node: *const Node, dirs: bool) u32 {
    var total: u32 = 0;
    for (node.children.items) |child| {
        if (child.isDir() == dirs) total += 1;
        if (child.isDir()) total += count(child, dirs);
    }
    return total;
}

/// A name as a directory entry holds it: eight characters and three,
/// upper case, space-padded. Null for a name that does not fit one, or
/// that holds a character an entry may not.
fn shortName(name: []const u8) ?[fat.ent_name_bytes]u8 {
    if (name.len == 0) return null;
    const dot = mem.lastIndexOfScalar(u8, name, '.');
    const base = if (dot) |at| name[0..at] else name;
    const ext = if (dot) |at| name[at + 1 ..] else name[0..0];
    if (base.len == 0 or base.len > 8 or ext.len > 3) return null;
    var short: [fat.ent_name_bytes]u8 = @splat(' ');
    for (base, 0..) |char, at| short[at] = upper(char) orelse return null;
    for (ext, 0..) |char, at| short[8 + at] = upper(char) orelse return null;
    return short;
}

/// A character of a short name, upper case; null for one a name may not
/// hold.
fn upper(char: u8) ?u8 {
    return switch (char) {
        'a'...'z' => char - ('a' - 'A'),
        'A'...'Z', '0'...'9' => char,
        '$', '%', '\'', '-', '_', '@', '~', '`', '!', '(', ')', '{', '}', '^', '#', '&' => char,
        else => null,
    };
}

/// The volume worked out, and what the tree takes on it.
const Made = struct {
    plan: format.Plan,
    /// The clusters the tree uses, counted from the root's.
    clusters_used: u32,
};

/// Where the volume goes and how it is laid out, for a medium of
/// `size_mib` mebibytes. Null where the volume cannot be FAT32 at that
/// size, or cannot hold the tree.
fn layOut(root: *Node, size_mib: u64) ?Made {
    const blocks = size_mib * 1024 * 1024 / block_bytes;
    var guid: gpt.Guid = @splat(0);
    const header = gpt.freshHeader(blocks, block_bytes, &guid) orelse return null;
    const first = gpt.alignUp(header.first_usable_lba, block_bytes);
    if (first > header.last_usable_lba) return null;
    const total = header.last_usable_lba - first + 1;
    // The cluster asked for, or the one the volume's size would get if
    // it is too small for that - a stick made smaller than a FAT32
    // volume of 4 KiB clusters can be.
    const plan = format.planCluster(first, total, block_bytes, 1, cluster_bytes) orelse
        format.plan(first, total, block_bytes, 1) orelse return null;
    const used = handOut(root, plan.sectors_per_cluster * block_bytes);
    if (used > plan.clusters) return null;
    return .{ .plan = plan, .clusters_used = used };
}

/// Every node given its clusters, the root the first. The answer is how
/// many clusters the tree takes, the root's counted.
fn handOut(root: *Node, bytes_per_cluster: u32) u32 {
    root.cluster = fat.first_cluster;
    root.clusters = clustersFor(dirBytes(root), bytes_per_cluster);
    var next = root.cluster + root.clusters;
    hand(root, bytes_per_cluster, &next);
    return next - fat.first_cluster;
}

fn hand(node: *Node, bytes_per_cluster: u32, next: *u32) void {
    for (node.children.items) |child| {
        const bytes = if (child.bytes) |content| content.len else dirBytes(child);
        child.cluster = next.*;
        child.clusters = clustersFor(bytes, bytes_per_cluster);
        next.* += child.clusters;
    }
    // The children's own children after them, so a directory's clusters
    // are a run.
    for (node.children.items) |child| {
        if (child.isDir()) hand(child, bytes_per_cluster, next);
    }
}

/// The bytes a directory's entries take: its children, and for one that
/// is not the root the two entries that name itself and the directory
/// above it.
fn dirBytes(node: *const Node) usize {
    const own: usize = if (node.parent == null) 1 else 2;
    return (own + node.children.items.len) * fat.entry_bytes;
}

/// The clusters `bytes` take, one at least - a directory always has a
/// cluster, and so does a file of no bytes, which keeps a chain to point
/// at.
fn clustersFor(bytes: usize, bytes_per_cluster: u32) u32 {
    const made = (bytes + bytes_per_cluster - 1) / bytes_per_cluster;
    return @intCast(@max(made, 1));
}

/// The blocks the second copy of the table takes at the end of the
/// medium: its entries and its header.
fn backBlocks() u64 {
    var header: gpt.Header = .{};
    return gpt.entriesBlocks(&header, block_bytes) + 1;
}

/// The protective MBR and both copies of the GPT, with the one partition
/// the volume is on.
fn writeTable(image: *Image, blocks: u64, plan: format.Plan, name: []const u8, seed: *const [32]u8) void {
    const arena = image.arena;
    var disk_guid = drawn(seed, 0)[0..16].*;
    var part_guid = drawn(seed, 1)[0..16].*;
    gpt.markRandom(&disk_guid);
    gpt.markRandom(&part_guid);

    var header = gpt.freshHeader(blocks, block_bytes, &disk_guid) orelse
        fatal("{s}: the medium is too small for a partition table", .{image.path});
    var entry: gpt.Entry = .{
        .partition_type_guid = gpt.TYPE_EFI_SYSTEM,
        .unique_partition_guid = part_guid,
        .starting_lba = plan.first,
        .ending_lba = plan.first + plan.total - 1,
    };
    gpt.setName(&entry, name);

    const entries_bytes: usize = @intCast(gpt.entriesLength(&header));
    const entries = arena.alloc(u8, entries_bytes) catch @panic("out of memory");
    @memset(entries, 0);
    gpt.putEntry(&header, entries, 0, &entry);
    const entries_crc = gpt.entriesCrc(&header, entries);

    const block = arena.alloc(u8, block_bytes) catch @panic("out of memory");
    gpt.makeProtective(block, blocks);
    image.put(0, block);

    gpt.putHeader(&header, entries_crc, block);
    image.put(header.my_lba, block);
    image.putBytes(header.partition_entry_lba, entries);

    var backup = gpt.backupOf(&header);
    gpt.putHeader(&backup, entries_crc, block);
    image.putBytes(backup.partition_entry_lba, entries);
    image.put(backup.my_lba, block);
}

/// The tree written onto the volume: the table's chains, every
/// directory's entries, every file's bytes, and the free count left
/// saying what is left.
fn writeFiles(image: *Image, plan: format.Plan, root: *Node, used: u32) void {
    const arena = image.arena;
    // The whole table, built and then written over both copies: a stick's
    // is a few hundred kibibytes.
    const table = arena.alloc(u8, plan.fat_sectors * block_bytes) catch @panic("out of memory");
    @memset(table, 0);
    // What the format put in the first three entries stays: the medium
    // byte, the flags that say the volume is clean, and the root.
    fat.putU32(table, 0, @as(u32, 0x0FFF_FF00) | 0xF8);
    fat.putU32(table, 4, fat.eoc);
    chain(table, root);
    link(table, root);
    for (0..2) |copy| {
        image.putBytes(plan.first + plan.reserved + copy * plan.fat_sectors, table);
    }

    writeDir(image, plan, root);

    // The free count and where to look next, as they now stand.
    const block = arena.alloc(u8, block_bytes) catch @panic("out of memory");
    @memset(block, 0);
    fat.putU32(block, fat.fsinfo_lead_at, fat.fsinfo_lead);
    fat.putU32(block, fat.fsinfo_struct_at, fat.fsinfo_struct);
    fat.putU32(block, fat.fsinfo_free_count_at, plan.clusters - used);
    fat.putU32(block, fat.fsinfo_next_free_at, fat.first_cluster + used);
    fat.putU32(block, fat.fsinfo_trail_at, fat.fsinfo_trail);
    image.put(plan.first + 1, block);
    image.put(plan.first + 7, block);
}

/// One node's chain in the table: its clusters one after another, the
/// last one ending it.
fn chain(table: []u8, node: *const Node) void {
    var at: u32 = 0;
    while (at < node.clusters) : (at += 1) {
        const cluster = node.cluster + at;
        const next: u32 = if (at + 1 == node.clusters) fat.eoc else cluster + 1;
        fat.putU32(table, cluster * 4, next);
    }
}

/// Every chain below `node`, and `node`'s own already written.
fn link(table: []u8, node: *const Node) void {
    for (node.children.items) |child| {
        chain(table, child);
        if (child.isDir()) link(table, child);
    }
}

/// A directory's entries written, and then the directories and files in
/// it.
fn writeDir(image: *Image, plan: format.Plan, node: *Node) void {
    const arena = image.arena;
    const bytes = node.clusters * plan.sectors_per_cluster * block_bytes;
    const room = arena.alloc(u8, bytes) catch @panic("out of memory");
    @memset(room, 0);
    var at: usize = 0;
    if (node.parent == null) {
        // The root keeps the entry the format put the volume's name in.
        image.get(clusterAt(plan, node.cluster), room[0..block_bytes]);
        at = fat.entry_bytes;
    } else {
        putEntry(room[0..fat.entry_bytes], ".          ".*, fat_host.ATTR_DIRECTORY, node.cluster, 0);
        // The directory above, which is 0 where that is the root: a
        // reader is told to find the root by the boot sector and not by
        // a cluster number here.
        const above = node.parent.?;
        const up: u32 = if (above.parent == null) 0 else above.cluster;
        putEntry(room[fat.entry_bytes..][0..fat.entry_bytes], "..         ".*, fat_host.ATTR_DIRECTORY, up, 0);
        at = 2 * fat.entry_bytes;
    }
    for (node.children.items) |child| {
        const length: u32 = if (child.bytes) |content| @intCast(content.len) else 0;
        const attr: u8 = if (child.isDir()) fat_host.ATTR_DIRECTORY else fat_host.ATTR_ARCHIVE;
        putEntry(room[at..][0..fat.entry_bytes], child.short, attr, child.cluster, length);
        at += fat.entry_bytes;
    }
    image.putBytes(clusterAt(plan, node.cluster), room);

    for (node.children.items) |child| {
        if (child.isDir()) {
            writeDir(image, plan, child);
        } else {
            image.putBytes(clusterAt(plan, child.cluster), child.bytes.?);
        }
    }
}

/// One directory entry made.
fn putEntry(
    into: []u8,
    short: [fat.ent_name_bytes]u8,
    attr: u8,
    cluster: u32,
    length: u32,
) void {
    @memset(into, 0);
    @memcpy(into[fat.ent_name..][0..fat.ent_name_bytes], &short);
    into[fat.ent_attr] = attr;
    fat.putU16(into, fat.ent_create_time, made_stamp.time);
    fat.putU16(into, fat.ent_create_date, made_stamp.date);
    fat.putU16(into, fat.ent_access_date, made_stamp.date);
    fat.putU16(into, fat.ent_write_time, made_stamp.time);
    fat.putU16(into, fat.ent_write_date, made_stamp.date);
    fat.setEntryCluster(into, cluster);
    fat.putU32(into, fat.ent_size, length);
}

/// The block a cluster begins at.
fn clusterAt(plan: format.Plan, cluster: u32) u64 {
    const data = plan.first + plan.reserved + 2 * @as(u64, plan.fat_sectors);
    return data + @as(u64, cluster - fat.first_cluster) * plan.sectors_per_cluster;
}

/// The one date everything on the medium carries, as a directory entry
/// holds one - the years since 1980 and the hours of the day. It is the
/// same for every build so that the same files give the same image, byte
/// for byte, which is what lets a stick be checksummed and handed on;
/// the date a file on a boot medium carries is of use to no one. The
/// handler's own format puts the machine's clock here instead, where
/// there is one.
const made_stamp: fat_host.Stamp = .{
    // 1 January 2026, at midnight. A stamp of all zeroes is not a date,
    // so the date word is set even though the time's is not.
    .time = 0,
    .date = (2026 - 1980) << 9 | 1 << 5 | 1,
};

/// A number for the volume, drawn from the same seed as the GUIDs: it is
/// only ever compared with another one.
fn serialOf(seed: *const [32]u8) u32 {
    return mem.readInt(u32, drawn(seed, 2)[0..4], .little);
}

/// The `index`th number drawn from `seed`: enough to tell one medium from
/// another, and the same for the same medium.
fn drawn(seed: *const [32]u8, index: u64) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(seed);
    hash.update(mem.asBytes(&index));
    return hash.finalResult();
}

/// The seed a medium's GUIDs and its volume number come from: what the
/// medium is, so that two builds of the same files make the same image
/// and two different media are told apart.
fn seedOf(label: []const u8, name: []const u8, blocks: u64) [32]u8 {
    var seed: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(label);
    hash.update(name);
    hash.update(mem.asBytes(&blocks));
    hash.final(&seed);
    return seed;
}

/// The image the medium is written into. It answers the few things the
/// file system's format asks of a medium - memory, and blocks written -
/// over a file on the host.
const Image = struct {
    io: std.Io,
    file: std.Io.File,
    path: []const u8,
    arena: Allocator,

    /// The file made as long as the medium, so the table's second copy
    /// at the end is inside it.
    fn end(image: *Image, blocks: u64) void {
        image.file.setLength(image.io, blocks * block_bytes) catch |e|
            fatal("{s}: {t}", .{ image.path, e });
    }

    /// One block written.
    fn put(image: *Image, block: u64, bytes: []const u8) void {
        image.putBytes(block, bytes[0..block_bytes]);
    }

    /// Bytes written from a block on, however many they are.
    fn putBytes(image: *Image, block: u64, bytes: []const u8) void {
        image.file.writePositionalAll(image.io, bytes, block * block_bytes) catch |e|
            fatal("{s}: {t}", .{ image.path, e });
    }

    /// Bytes read back from a block on.
    fn get(image: *Image, block: u64, into: []u8) void {
        _ = image.file.readPositionalAll(image.io, into, block * block_bytes) catch |e|
            fatal("{s}: {t}", .{ image.path, e });
    }

    // --- what the format asks of a medium ---------------------------------

    pub fn alloc(image: *Image, bytes: usize) ?[]u8 {
        return image.arena.alloc(u8, bytes) catch null;
    }

    pub fn free(image: *Image, bytes: []u8) void {
        _ = image;
        _ = bytes;
    }

    pub fn write(image: *Image, sector: u64, sectors: u32, from: []const u8) bool {
        image.file.writePositionalAll(image.io, from[0 .. sectors * block_bytes], sector * block_bytes) catch
            return false;
        return true;
    }
};
