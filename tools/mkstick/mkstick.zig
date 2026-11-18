// SPDX-License-Identifier: MPL-2.0
//! mkstick: makes the medium a machine starts from - an image to write
//! to a USB stick - out of the files its firmware and loader read: a
//! machine whose firmware is UEFI, or a Raspberry Pi, whose firmware
//! reads the first FAT partition of a disk with an MBR.
//!
//! usage: mkstick --into=<image> [--as=<path>] [--size=<MiB>]
//!                [--table=gpt|mbr] [--label=<name>] [--name=<partition>]
//!                [--system=<disk image>]
//!                <path on the stick>=<file> ...
//!
//! What it writes: with `--table=gpt`, the default, a protective MBR, a
//! GPT whose first partition is an EFI System partition from the first
//! mebibyte on, and a FAT32 volume on that partition holding the files
//! it was given. With `--table=mbr`, an MBR whose one partition is FAT32
//! (type 0x0C) from the first mebibyte to the medium's end, with the
//! volume on it - what a Raspberry Pi's bootloader reads, off a card or
//! a USB stick. The medium is `--size` mebibytes either way.
//!
//! A UEFI firmware reads one name off such a partition and no other,
//! `EFI/BOOT/BOOTX64.EFI`, so that is where the loader goes; the loader
//! then reads `kernel.bin` from beside itself. A Raspberry Pi's firmware
//! reads config.txt from the volume's root, and what that names.
//!
//! **The system is the second partition** (`--system`): the PowerOS
//! container of a disk image `mkfs --gpt` made - a table in its first
//! block and a posfs partition with the system's files - copied as it
//! stands behind the EFI System partition, under an entry of its own in
//! the stick's table. A container counts its blocks from its own first
//! one, so it is the same container wherever on a medium it lies. The
//! loader hands the kernel the identifier of the partition it was read
//! from, and the kernel starts the system on that partition's disk: the
//! stick's. So the stick is a disk with a system on it, as an installed
//! one is - what is written on it stays - and `C:Install` on the machine
//! started from it puts a system on a disk of the machine's own. Without
//! `--system` the medium holds the EFI System partition alone, and the
//! loader reads a disk image from beside itself when one is there. The
//! container goes in a GPT: with `--table=mbr` there is the volume alone.
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
//! business bringing up, and a boot medium holds a handful of files.
//!
//! **Names are kept as they are given.** One that is eight characters
//! and three, each part in one case, is a short name alone, with the
//! entry's two flags for a part in small letters - `config.txt` stays in
//! small letters. Any other is a long name, in the entries before the
//! short one, and the short one is made from it as the handler makes one
//! (`fat32/names.zig`): its basis, with `~1` on the end, counted up until
//! no other entry in the directory has it. A firmware that reads long
//! names - a Raspberry Pi's does - finds `bcm2711-rpi-4-b.dtb` by its
//! name. A name with a character a FAT volume holds in no name is
//! refused, not changed.
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
const names = fat_host.names;

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

/// The partition table the medium has (`--table`).
const Table = enum { gpt, mbr };

/// Where the volume starts on a medium with an MBR: its first mebibyte
/// is the table's and room, as a GPT medium's is.
const mbr_first: u64 = 1024 * 1024 / block_bytes;

/// The longest name a long-name entry run holds.
const long_max = 255;

/// A file or a directory asked for, and where it goes.
const Give = struct {
    /// Its path on the stick, `/` between the parts.
    path: []const u8,
    /// A file's bytes; null for a directory to make.
    bytes: ?[]const u8,
};

/// A directory or a file on the way to the medium.
const Node = struct {
    /// Its name as it was given, which a long name holds where the short
    /// one cannot.
    name: []const u8,
    /// Its name as a directory entry holds it: eight and three,
    /// space-padded, in capitals.
    short: [fat.ent_name_bytes]u8 = @splat(' '),
    /// The entry's case byte: which parts of the short name were small
    /// letters.
    case: u8 = 0,
    /// Whether the name goes in long-name entries before the short one.
    long: bool = false,
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
    var called: ?[]const u8 = null;
    var size_mib: u64 = default_size_mib;
    var label_text: []const u8 = default_label;
    var name_text: []const u8 = default_name;
    var system_path: ?[]const u8 = null;
    var table: Table = .gpt;
    var given: std.ArrayList(Give) = .empty;
    for (args, 0..) |arg, index| {
        if (index == 0) continue;
        if (mem.startsWith(u8, arg, "--into=")) {
            into = arg["--into=".len..];
        } else if (mem.startsWith(u8, arg, "--as=")) {
            called = arg["--as=".len..];
        } else if (mem.startsWith(u8, arg, "--size=")) {
            size_mib = std.fmt.parseInt(u64, arg["--size=".len..], 10) catch
                fatal("--size: {s} is not a number of mebibytes", .{arg["--size=".len..]});
        } else if (mem.startsWith(u8, arg, "--label=")) {
            label_text = arg["--label=".len..];
        } else if (mem.startsWith(u8, arg, "--name=")) {
            name_text = arg["--name=".len..];
        } else if (mem.startsWith(u8, arg, "--system=")) {
            system_path = arg["--system=".len..];
        } else if (mem.startsWith(u8, arg, "--table=")) {
            table = std.meta.stringToEnum(Table, arg["--table=".len..]) orelse
                fatal("--table: {s} is neither gpt nor mbr", .{arg["--table=".len..]});
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
        "usage: mkstick --into=<image> [--as=<path>] [--size=<MiB>] [--table=gpt|mbr] [--label=<name>] [--name=<partition>] [--system=<disk image>] <path on the stick>=<file> ...",
        .{},
    );
    if (given.items.len == 0) fatal("nothing to put on it: give at least the loader the firmware reads", .{});
    if (table == .mbr and system_path != null) fatal("--system: the system's container goes in a GPT, and --table=mbr has room for the volume alone", .{});
    const label = fat_host.shortLabel(label_text) catch
        fatal("--label: {s} is not a name a volume can carry", .{label_text});

    // The tree, and what it takes.
    const root = try arena.create(Node);
    root.* = .{ .name = "", .bytes = null };
    for (given.items) |one| try place(arena, root, one);

    const made = layOut(root, size_mib, table) orelse fatal(
        "--size={d}: a volume that small cannot hold the files, or cannot be FAT32 at all",
        .{size_mib},
    );
    // The system's container, behind the volume on a mebibyte of its own.
    const system: ?System = if (system_path) |from| takeSystem(io, arena, from, gpt.alignUp(made.plan.first + made.plan.total, block_bytes)) else null;
    const body = if (system) |container| container.first + container.blocks else made.plan.first + made.plan.total;
    const blocks = switch (table) {
        .gpt => body + backBlocks(),
        .mbr => body,
    };

    // The image: as long as the medium, holding what was written.
    const file = cwd.createFile(io, path, .{ .read = true }) catch |e| fatal("{s}: {t}", .{ path, e });
    defer file.close(io);
    var image: Image = .{ .io = io, .file = file, .path = path, .arena = arena };
    image.end(blocks);

    const seed = seedOf(label_text, name_text, blocks);
    switch (table) {
        .gpt => writeTable(&image, blocks, made.plan, name_text, &seed, system),
        .mbr => writeMbr(&image, made.plan, &seed),
    }
    if (system) |container| writeSystem(&image, container);
    format.write(&image, made.plan, label, serialOf(&seed), made_stamp) catch |e|
        fatal("{s}: the volume could not be laid down: {t}", .{ path, e });
    writeFiles(&image, made.plan, root, made.clusters_used);

    // The report, by the name the medium will be found under: a build
    // writes it into its cache and puts it somewhere else afterwards, so
    // `--as` is the path to say, and the line that writes the medium to a
    // stick is a line that can be run.
    const shown = called orelse path;
    const used = (made.clusters_used - 1) * @as(u64, made.plan.sectors_per_cluster) * block_bytes;
    var out_buffer: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    out.interface.print(
        \\mkstick: {s}
        \\  medium        {d} MiB, blocks of {d} bytes
        \\
    , .{
        shown,
        blocks * block_bytes / (1024 * 1024),
        block_bytes,
    }) catch |e| fatal("the report could not be written: {t}", .{e});
    const partition_said = switch (table) {
        .gpt => out.interface.print(
            \\  partition     EFI System, blocks {d} to {d}, "{s}"
            \\
        , .{ made.plan.first, made.plan.first + made.plan.total - 1, name_text }),
        .mbr => out.interface.print(
            \\  partition     FAT32 in an MBR (type 0x0C), blocks {d} to {d}
            \\
        , .{ made.plan.first, made.plan.first + made.plan.total - 1 }),
    };
    partition_said catch |e| fatal("the report could not be written: {t}", .{e});
    out.interface.print(
        \\  volume        FAT32 "{s}", clusters of {d} bytes, {d} of them
        \\  on it         {d} bytes in {d} files and {d} drawers
        \\
    , .{
        label_text,
        made.plan.sectors_per_cluster * block_bytes,
        made.plan.clusters,
        used,
        count(root, false),
        count(root, true),
    }) catch |e| fatal("the report could not be written: {t}", .{e});
    if (system) |container| out.interface.print(
        \\  partition     PowerOS container, blocks {d} to {d}, "{s}": the system,
        \\                {d} MiB, as {s} holds it
        \\
    , .{
        container.first,
        container.first + container.blocks - 1,
        system_name,
        container.blocks * block_bytes / (1024 * 1024),
        system_path.?,
    }) catch |e| fatal("the report could not be written: {t}", .{e});
    out.interface.print(
        \\
        \\Write it to a stick with:
        \\  sudo dd if={s} of=/dev/sdX bs=4M conv=fsync status=progress
        \\
    , .{shown}) catch |e| fatal("the report could not be written: {t}", .{e});
    out.flush() catch |e| fatal("the report could not be written: {t}", .{e});
}

/// What the system's partition is called in the GPT.
const system_name = "PowerOS";

/// The system's container: where it goes on the medium, how many blocks
/// it is, and the blocks themselves as the disk image holds them.
const System = struct {
    first: u64,
    blocks: u64,
    bytes: []const u8,
};

/// The PowerOS container of the disk image at `path`, to go on the
/// medium from block `first` on. The image is one `mkfs --gpt` made: a
/// GPT in its block 1, whose container's blocks are taken as they are.
fn takeSystem(io: std.Io, arena: Allocator, path: []const u8, first: u64) System {
    const disk = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited) catch |e| fatal("{s}: {t}", .{ path, e });
    if (disk.len < 3 * block_bytes) fatal("{s}: too short to be a disk image", .{path});
    const disk_blocks = disk.len / block_bytes;
    const header = gpt.readHeader(disk[gpt.header_block * block_bytes ..][0..block_bytes], gpt.header_block, disk_blocks) orelse
        fatal("{s}: no partition table in its second block: it is not a disk image `mkfs --gpt` made", .{path});
    const entries_at: usize = @intCast(header.partition_entry_lba * block_bytes);
    const entries_bytes: usize = @intCast(gpt.entriesLength(&header));
    if (entries_at + entries_bytes > disk.len) fatal("{s}: its partition table reaches past its end", .{path});
    const entries = disk[entries_at..][0..entries_bytes];
    var index: u32 = 0;
    while (index < header.number_of_partition_entries) : (index += 1) {
        const entry = gpt.entryAt(&header, entries, index);
        if (!gpt.used(&entry) or !gpt.isContainer(&entry)) continue;
        if (entry.starting_lba > entry.ending_lba or entry.ending_lba >= disk_blocks) fatal("{s}: its container reaches past its end", .{path});
        const from: usize = @intCast(entry.starting_lba * block_bytes);
        const length: usize = @intCast((entry.ending_lba - entry.starting_lba + 1) * block_bytes);
        return .{ .first = first, .blocks = length / block_bytes, .bytes = disk[from..][0..length] };
    }
    fatal("{s}: no PowerOS container in its partition table", .{path});
}

/// The container's blocks written where it goes, but those that are all
/// zeroes: the image is as long as the medium and holds only what was
/// written.
fn writeSystem(image: *Image, system: System) void {
    const step = 256 * block_bytes;
    var at: usize = 0;
    while (at < system.bytes.len) : (at += step) {
        const piece = system.bytes[at..@min(at + step, system.bytes.len)];
        if (mem.allEqual(u8, piece, 0)) continue;
        image.putBytes(system.first + at / block_bytes, piece);
    }
}

/// `one` put in the tree under `root`, the drawers on the way to it made
/// as they are met.
fn place(arena: Allocator, root: *Node, one: Give) !void {
    var node = root;
    var parts = mem.splitScalar(u8, one.path, '/');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const last = parts.peek() == null;
        if (find(node, part)) |had| {
            if (last) fatal("{s}: given twice", .{one.path});
            if (!had.isDir()) fatal("{s}: {s} is a file on the way to it", .{ one.path, part });
            node = had;
            continue;
        }
        if (!node.isDir()) fatal("{s}: {s} is a file on the way to it", .{ one.path, part });
        const made = try arena.create(Node);
        made.* = .{
            .name = part,
            .bytes = if (last) one.bytes else null,
            .parent = node,
        };
        if (!nameIn(node, made)) fatal(
            "{s}: not a name a FAT volume holds - at most {d} characters, none of \\ / : * ? \" < > | and none below a space, not ending in a dot or a space",
            .{ part, long_max },
        );
        try node.children.append(arena, made);
        node = made;
    }
    if (node == root) fatal("{s}: no name in it", .{one.path});
}

/// The child of `node` by that name, if it has one - in either case, as
/// a FAT volume tells names apart.
fn find(node: *Node, name: []const u8) ?*Node {
    for (node.children.items) |child| {
        if (std.ascii.eqlIgnoreCase(child.name, name)) return child;
    }
    return null;
}

/// Whether a child of `node` has that short name.
fn hasShort(node: *const Node, short: *const [fat.ent_name_bytes]u8) bool {
    for (node.children.items) |child| {
        if (mem.eql(u8, &child.short, short)) return true;
    }
    return false;
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

/// `node`'s entry worked out among those already in `dir`: its short
/// name alone where the name is one, else a long name and a short one
/// made from it - the basis, `~1` on the end, counted up until no other
/// entry in the directory has it (`names.withTail`). False for a name a
/// FAT volume does not hold.
fn nameIn(dir: *const Node, node: *Node) bool {
    const name = node.name;
    if (name.len == 0 or name.len > long_max) return false;
    for (name) |char| if (!longChar(char)) return false;
    if (name[name.len - 1] == '.' or name[name.len - 1] == ' ') return false;
    if (shortOf(name)) |short| {
        node.short = short.bytes;
        node.case = short.case;
        return true;
    }
    node.long = true;
    const basis = basisOf(name);
    var number: u32 = 1;
    while (number < 1_000_000) : (number += 1) {
        const short = names.withTail(basis, number);
        if (hasShort(dir, &short)) continue;
        node.short = short;
        return true;
    }
    return false;
}

/// A name as a short entry alone - eight characters and three, in
/// capitals, space-padded, and the case byte's flags for a part that was
/// all small letters - or null where it needs a long name: a part too
/// long, a second dot, a character a short name may not hold, or small
/// letters and capitals in one part.
fn shortOf(name: []const u8) ?names.Short {
    const dot = mem.indexOfScalar(u8, name, '.');
    if (dot) |at| if (mem.indexOfScalarPos(u8, name, at + 1, '.') != null) return null;
    const base = if (dot) |at| name[0..at] else name;
    const ext = if (dot) |at| name[at + 1 ..] else name[0..0];
    if (base.len == 0 or base.len > 8 or ext.len > 3) return null;
    if (dot != null and ext.len == 0) return null;
    var short: names.Short = .{ .bytes = @splat(' '), .case = 0 };
    for (base, 0..) |char, at| short.bytes[at] = upper(char) orelse return null;
    for (ext, 0..) |char, at| short.bytes[8 + at] = upper(char) orelse return null;
    short.case |= caseFlag(base, names.case_lower_base) orelse return null;
    short.case |= caseFlag(ext, names.case_lower_ext) orelse return null;
    return short;
}

/// `flag` for a part whose letters are all small, 0 for one whose
/// letters are all capitals or that has none, null for one with both.
fn caseFlag(part: []const u8, flag: u8) ?u8 {
    var small = false;
    var capital = false;
    for (part) |char| {
        if (std.ascii.isLower(char)) small = true;
        if (std.ascii.isUpper(char)) capital = true;
    }
    if (small and capital) return null;
    return if (small) flag else 0;
}

/// The short name a long one starts from, by the handler's rule
/// (`names.basisOf`) for the characters this tool takes: capitals, each
/// character a short name may not hold made one `_`, spaces and leading
/// dots dropped, up to eight before the last dot and three after it.
fn basisOf(name: []const u8) names.Basis {
    var basis: names.Basis = .{};
    var start: usize = 0;
    while (start < name.len and (name[start] == '.' or name[start] == ' ')) start += 1;
    const last_dot = mem.lastIndexOfScalar(u8, name[start..], '.');
    const stem_end = if (last_dot) |at| start + at else name.len;
    for (name[start..stem_end]) |char| {
        if (char == ' ' or char == '.') continue;
        if (basis.base_len == basis.base.len) break;
        basis.base[basis.base_len] = upper(char) orelse '_';
        basis.base_len += 1;
    }
    if (basis.base_len == 0) {
        basis.base[0] = '_';
        basis.base_len = 1;
    }
    if (stem_end < name.len) {
        var ext_len: usize = 0;
        for (name[stem_end + 1 ..]) |char| {
            if (char == ' ') continue;
            if (ext_len == basis.ext.len) break;
            basis.ext[ext_len] = upper(char) orelse '_';
            ext_len += 1;
        }
    }
    return basis;
}

/// Whether a long name may hold `char`: anything printable but the nine
/// a FAT volume keeps out of every name. This tool takes ASCII alone.
fn longChar(char: u8) bool {
    if (char < 0x20 or char >= 0x7F) return false;
    return mem.indexOfScalar(u8, "\\/:*?\"<>|", char) == null;
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
fn layOut(root: *Node, size_mib: u64, table: Table) ?Made {
    const blocks = size_mib * 1024 * 1024 / block_bytes;
    var first: u64 = undefined;
    var total: u64 = undefined;
    switch (table) {
        .gpt => {
            var guid: gpt.Guid = @splat(0);
            const header = gpt.freshHeader(blocks, block_bytes, &guid) orelse return null;
            first = gpt.alignUp(header.first_usable_lba, block_bytes);
            if (first > header.last_usable_lba) return null;
            total = header.last_usable_lba - first + 1;
        },
        .mbr => {
            // An MBR counts blocks in 32 bits.
            if (blocks <= mbr_first or blocks > 0xFFFF_FFFF) return null;
            first = mbr_first;
            total = blocks - mbr_first;
        },
    }
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

/// The bytes a directory's entries take: its children's, each one's long
/// name before it where it has one, and for a directory that is not the
/// root the two entries that name itself and the directory above it; the
/// root's one is the volume's name.
fn dirBytes(node: *const Node) usize {
    var entries: usize = if (node.parent == null) 1 else 2;
    for (node.children.items) |child| {
        entries += 1;
        if (child.long) entries += names.pieceCount(child.name.len);
    }
    return entries * fat.entry_bytes;
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

/// Where an MBR holds the number a disk is told apart by.
const mbr_disk_signature_at: usize = 440;

/// The MBR, with the one partition the volume is on, marked FAT32 that
/// is found by its blocks' numbers alone (0x0C), and not marked active:
/// nothing that reads this medium asks.
fn writeMbr(image: *Image, plan: format.Plan, seed: *const [32]u8) void {
    const block = image.arena.alloc(u8, block_bytes) catch @panic("out of memory");
    @memset(block, 0);
    @memcpy(block[mbr_disk_signature_at..][0..4], drawn(seed, 0)[0..4]);
    const at = fat.partition_table_at;
    const last = plan.first + plan.total - 1;
    @memcpy(block[at + 1 ..][0..3], &chsOf(plan.first));
    block[at + 4] = fat.TYPE_FAT32_LBA;
    @memcpy(block[at + 5 ..][0..3], &chsOf(last));
    fat.putU32(block, at + 8, @intCast(plan.first));
    fat.putU32(block, at + 12, @intCast(plan.total));
    fat.putU16(block, fat.signature_at, fat.signature);
    image.put(0, block);
}

/// A block's place as an MBR entry also gives it - its cylinder, head and
/// sector for 255 heads of 63 sectors, as the entry packs them - and past
/// what those can count, the most they can.
fn chsOf(block: u64) [3]u8 {
    const heads = 255;
    const sectors = 63;
    if (block >= 1024 * heads * sectors) return .{ 0xFE, 0xFF, 0xFF };
    const cylinder = block / (heads * sectors);
    const head = block / sectors % heads;
    const sector = block % sectors + 1;
    return .{ @intCast(head), @intCast(sector | (cylinder >> 8) << 6), @intCast(cylinder & 0xFF) };
}

/// The protective MBR and both copies of the GPT, with the partition
/// the volume is on and, with `system`, the system's container after it.
fn writeTable(image: *Image, blocks: u64, plan: format.Plan, name: []const u8, seed: *const [32]u8, system: ?System) void {
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
    if (system) |container| {
        var container_guid = drawn(seed, 2)[0..16].*;
        gpt.markRandom(&container_guid);
        var second: gpt.Entry = .{
            .partition_type_guid = gpt.TYPE_CONTAINER,
            .unique_partition_guid = container_guid,
            .starting_lba = container.first,
            .ending_lba = container.first + container.blocks - 1,
        };
        gpt.setName(&second, system_name);
        gpt.putEntry(&header, entries, 1, &second);
    }
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
        putEntry(room[0..fat.entry_bytes], ".          ".*, 0, fat_host.ATTR_DIRECTORY, node.cluster, 0);
        // The directory above, which is 0 where that is the root: a
        // reader is told to find the root by the boot sector and not by
        // a cluster number here.
        const above = node.parent.?;
        const up: u32 = if (above.parent == null) 0 else above.cluster;
        putEntry(room[fat.entry_bytes..][0..fat.entry_bytes], "..         ".*, 0, fat_host.ATTR_DIRECTORY, up, 0);
        at = 2 * fat.entry_bytes;
    }
    for (node.children.items) |child| {
        if (child.long) {
            // The long name's pieces, its end first, each carrying the
            // short name's check.
            var units: [long_max]u16 = undefined;
            for (child.name, 0..) |char, index| units[index] = char;
            const name = units[0..child.name.len];
            const checksum = fat.shortNameChecksum(&child.short);
            var order = names.pieceCount(name.len);
            while (order != 0) : (order -= 1) {
                names.fillPiece(room[at..][0..fat.entry_bytes], name, order, checksum);
                at += fat.entry_bytes;
            }
        }
        const length: u32 = if (child.bytes) |content| @intCast(content.len) else 0;
        const attr: u8 = if (child.isDir()) fat_host.ATTR_DIRECTORY else fat_host.ATTR_ARCHIVE;
        putEntry(room[at..][0..fat.entry_bytes], child.short, child.case, attr, child.cluster, length);
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
    case: u8,
    attr: u8,
    cluster: u32,
    length: u32,
) void {
    @memset(into, 0);
    @memcpy(into[fat.ent_name..][0..fat.ent_name_bytes], &short);
    into[fat.ent_attr] = attr;
    into[fat.ent_case] = case;
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

test "a name is kept as it is given: short where it fits, long with a short one made from it" {
    const gpa = std.testing.allocator;
    var dir: Node = .{ .name = "", .bytes = null };
    defer dir.children.deinit(gpa);

    // Eight and three in small letters: a short name, flagged small.
    var config: Node = .{ .name = "config.txt", .bytes = "" };
    try std.testing.expect(nameIn(&dir, &config));
    try std.testing.expectEqualStrings("CONFIG  TXT", &config.short);
    try std.testing.expectEqual(names.case_lower_base | names.case_lower_ext, config.case);
    try std.testing.expect(!config.long);
    try dir.children.append(gpa, &config);

    // In capitals: a short name as it is.
    var loader: Node = .{ .name = "BOOTX64.EFI", .bytes = "" };
    try std.testing.expect(nameIn(&dir, &loader));
    try std.testing.expectEqualStrings("BOOTX64 EFI", &loader.short);
    try std.testing.expectEqual(@as(u8, 0), loader.case);
    try std.testing.expect(!loader.long);

    // Too long: a long name, its short one the basis and `~1` - and `~2`
    // for the next with the same basis.
    var tree: Node = .{ .name = "bcm2711-rpi-4-b.dtb", .bytes = "" };
    try std.testing.expect(nameIn(&dir, &tree));
    try std.testing.expect(tree.long);
    try std.testing.expectEqualStrings("BCM271~1DTB", &tree.short);
    try dir.children.append(gpa, &tree);
    var other: Node = .{ .name = "bcm2711-rpi-cm4.dtb", .bytes = "" };
    try std.testing.expect(nameIn(&dir, &other));
    try std.testing.expectEqualStrings("BCM271~2DTB", &other.short);

    // Small letters and capitals in one part, or two dots: a long name.
    var mixed: Node = .{ .name = "Kernel.bin", .bytes = "" };
    try std.testing.expect(nameIn(&dir, &mixed));
    try std.testing.expect(mixed.long);
    try std.testing.expectEqualStrings("KERNEL~1BIN", &mixed.short);
    var dotted: Node = .{ .name = "a.b.c", .bytes = "" };
    try std.testing.expect(nameIn(&dir, &dotted));
    try std.testing.expect(dotted.long);
    try std.testing.expectEqualStrings("AB~1    C  ", &dotted.short);

    // What no FAT name holds is refused.
    var colon: Node = .{ .name = "a:b", .bytes = "" };
    try std.testing.expect(!nameIn(&dir, &colon));
    var trailing: Node = .{ .name = "end.", .bytes = "" };
    try std.testing.expect(!nameIn(&dir, &trailing));
}

test "an MBR entry counts a block in cylinders, heads and sectors until they run out" {
    // The first mebibyte's end, where the volume starts: as fdisk gives it.
    try std.testing.expectEqual([3]u8{ 0x20, 0x21, 0x00 }, chsOf(mbr_first));
    try std.testing.expectEqual([3]u8{ 0xFE, 0xFF, 0xFF }, chsOf(1024 * 255 * 63));
}
