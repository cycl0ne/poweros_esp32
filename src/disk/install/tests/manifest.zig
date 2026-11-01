// SPDX-License-Identifier: MIT
//! Host tests of a release package's list (`sdk.install`): a manifest
//! written and read back, the order its lines are in, the counts that
//! catch one cut short, and the paths it refuses.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const install = sdk.install;
const manifest = install.manifest;

/// A manifest written into `into`: its explanation, its settings line
/// over the entries' own counts, and a line for each, as a tool on the
/// host or a command writes one.
fn write(entries: []const manifest.Entry, chip: sdk.hardware.Chip, into: []u8) ![]const u8 {
    var counts: manifest.Counts = .{};
    for (entries) |entry| counts.add(entry);
    var at: usize = 0;
    @memcpy(into[0..manifest.preamble.len], manifest.preamble);
    at += manifest.preamble.len;
    at += manifest.headerLine(.{ .chip = chip, .counts = counts }, into[at..]);
    for (entries) |entry| {
        const length = manifest.entryLength(entry);
        try testing.expectEqual(length, manifest.entryLine(entry, into[at..]));
        at += length;
    }
    return into[0..at];
}

/// What a manifest reads back as.
fn readAll(text: []const u8, into: []manifest.Entry) manifest.Error!struct { header: manifest.Header, entries: []manifest.Entry } {
    var reader = try manifest.Reader.init(text);
    var count: usize = 0;
    while (try reader.next()) |entry| {
        into[count] = entry;
        count += 1;
    }
    return .{ .header = reader.header, .entries = into[0..count] };
}

const sample = [_]manifest.Entry{
    .{ .kind = .drawer, .path = "boot" },
    .{ .kind = .file, .path = "boot/kernel.bin", .crc = 0x1234_5678, .size = 1_732_608 },
    .{ .kind = .drawer, .path = "system" },
    .{ .kind = .drawer, .path = "system/C" },
    .{ .kind = .file, .path = "system/C/List", .crc = 0x7F3A_21B0, .size = 5120 },
    .{ .kind = .file, .path = "system/C/My Tool", .crc = 0, .size = 0 },
    .{ .kind = .drawer, .path = "system/WBStartup" },
};

test "a manifest written and read back, with what it says of itself" {
    var buffer: [4096]u8 = undefined;
    const text = try write(&sample, .rv64sbi, &buffer);

    // The settings line says the chip and what follows it.
    var read: [16]manifest.Entry = undefined;
    const got = try readAll(text, &read);
    try testing.expectEqual(manifest.format_now, got.header.format);
    try testing.expectEqual(sdk.hardware.Chip.rv64sbi, got.header.chip);
    try testing.expectEqual(@as(u32, 4), got.header.counts.drawers);
    try testing.expectEqual(@as(u32, 3), got.header.counts.files);
    try testing.expectEqual(@as(u64, 1_732_608 + 5120), got.header.counts.bytes);

    // Every entry comes back as it went in, a path with a blank in it too.
    try testing.expectEqual(sample.len, got.entries.len);
    for (sample, got.entries) |wrote, back| {
        try testing.expectEqual(wrote.kind, back.kind);
        try testing.expectEqualStrings(wrote.path, back.path);
        try testing.expectEqual(wrote.crc, back.crc);
        try testing.expectEqual(wrote.size, back.size);
    }

    // The lines are what a person reads in the file.
    try testing.expect(std.mem.indexOf(u8, text, "FORMAT=1 CHIP=rv64sbi DRAWERS=4 FILES=3 BYTES=1737728\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "drawer system/WBStartup\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "7f3a21b0 5120 system/C/List\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "00000000 0 system/C/My Tool\n") != null);
}

test "a length past 4 GiB, and the chips' names" {
    var buffer: [512]u8 = undefined;
    const big = [_]manifest.Entry{.{ .kind = .file, .path = "system/Work/film.mp4", .crc = 0xFFFF_FFFF, .size = 6_000_000_000 }};
    for ([_]sdk.hardware.Chip{ .esp32s3, .esp32p4, .rv64sbi, .a64psci }) |chip| {
        const text = try write(&big, chip, &buffer);
        var read: [2]manifest.Entry = undefined;
        const got = try readAll(text, &read);
        try testing.expectEqual(chip, got.header.chip);
        try testing.expectEqual(@as(u64, 6_000_000_000), got.entries[0].size);
        try testing.expectEqual(@as(u32, 0xFFFF_FFFF), got.entries[0].crc);
    }
}

test "a manifest cut short is refused, not read as a shorter one" {
    var buffer: [4096]u8 = undefined;
    const text = try write(&sample, .rv64sbi, &buffer);

    // A fetch that ended early: the lines that are there are fine, and
    // what the settings line promised is not.
    const at = std.mem.indexOf(u8, text, "drawer system/WBStartup").?;
    var read: [16]manifest.Entry = undefined;
    try testing.expectError(error.Truncated, readAll(text[0..at], &read));

    // One cut in the middle of a line, which has no end.
    try testing.expectError(error.Truncated, readAll(text[0 .. at + 6], &read));

    // And one with a line more than it says.
    var longer: [4096]u8 = undefined;
    @memcpy(longer[0..text.len], text);
    const extra = "drawer system/Z\n";
    @memcpy(longer[text.len..][0..extra.len], extra);
    try testing.expectError(error.Counts, readAll(longer[0 .. text.len + extra.len], &read));
}

test "the order is the format's: sorted, and no path twice" {
    var read: [8]manifest.Entry = undefined;
    const head = "FORMAT=1 CHIP=rv64sbi DRAWERS=0 FILES=2 BYTES=2\n";
    try testing.expectError(error.OutOfOrder, readAll(head ++
        "00000000 1 system/C/Mount\n" ++
        "00000000 1 system/C/List\n", &read));
    try testing.expectError(error.OutOfOrder, readAll(head ++
        "00000000 1 system/C/List\n" ++
        "00000000 1 system/c/list\n", &read));

    // Sorted as the file systems compare names, and so a drawer comes
    // before what is in it.
    try testing.expectEqual(manifest.Order.before, manifest.orderPaths("system/C", "system/C/List"));
    try testing.expectEqual(manifest.Order.before, manifest.orderPaths("system/C/List", "system/CL"));
    try testing.expectEqual(manifest.Order.same, manifest.orderPaths("system/c/LIST", "SYSTEM/C/list"));
    try testing.expectEqual(manifest.Order.after, manifest.orderPaths("system/Devs", "system/C"));
    try testing.expect(manifest.samePath("boot/Kernel.bin", "BOOT/kernel.BIN"));
}

test "a settings line a reader cannot trust" {
    var read: [4]manifest.Entry = undefined;
    // Nothing of a manifest about it.
    try testing.expectError(error.NotManifest, readAll("hello\n", &read));
    try testing.expectError(error.NotManifest, readAll("", &read));
    // No chip: every machine's package has the same paths in it.
    try testing.expectError(error.NotManifest, readAll("FORMAT=1 DRAWERS=0 FILES=0 BYTES=0\n", &read));
    // A chip with no such name, and a count that is not one.
    try testing.expectError(error.BadHeader, readAll("FORMAT=1 CHIP=esp32s4 DRAWERS=0 FILES=0 BYTES=0\n", &read));
    try testing.expectError(error.BadHeader, readAll("FORMAT=1 CHIP=rv64sbi DRAWERS=x FILES=0 BYTES=0\n", &read));
    // Written by a newer system.
    try testing.expectError(error.Format, readAll("FORMAT=2 CHIP=rv64sbi DRAWERS=0 FILES=0 BYTES=0\n", &read));

    // A key this does not know is a field a later format added, and is
    // passed over; the explanation and blank lines are too.
    var reader = try manifest.Reader.init(
        "# an explanation\n" ++
            "\n" ++
            "  FORMAT=1 CHIP=a64psci RELEASE=0.2 DRAWERS=1 FILES=0 BYTES=0  \r\n" ++
            "drawer system/T\r\n",
    );
    const entry = (try reader.next()).?;
    try testing.expectEqual(manifest.Kind.drawer, entry.kind);
    try testing.expectEqualStrings("system/T", entry.path);
    try testing.expect(try reader.next() == null);
    try testing.expect(reader.seen.same(reader.header.counts));
}

test "a line that is neither a drawer nor a file" {
    var read: [4]manifest.Entry = undefined;
    const head = "FORMAT=1 CHIP=rv64sbi DRAWERS=1 FILES=1 BYTES=1\n";
    try testing.expectError(error.BadLine, readAll(head ++ "file system/C/List\n", &read));
    try testing.expectError(error.BadLine, readAll(head ++ "7f3a21b 5120 system/C/List\n", &read));
    try testing.expectError(error.BadLine, readAll(head ++ "7f3a21b0 system/C/List\n", &read));
    try testing.expectError(error.BadLine, readAll(head ++ "drawer\n", &read));
    // The word reads in any case, as every other does.
    var reader = try manifest.Reader.init(head ++ "DRAWER system/T\n" ++ "00000000 1 system/T/x\n");
    try testing.expectEqual(manifest.Kind.drawer, (try reader.next()).?.kind);
    try testing.expectEqual(manifest.Kind.file, (try reader.next()).?.kind);
}

test "a path a manifest may not name" {
    for ([_][]const u8{
        "system/C/List",
        "boot/kernel.bin",
        "system/C/My Tool",
        "system",
        "system/prefs/env-archive/Sys/net/networks/WLAN0",
    }) |good| try testing.expect(manifest.pathOk(good));

    for ([_][]const u8{
        "",
        "/system/C/List", // not relative
        "system/C/List/", // a drawer's name with nothing in it
        "system//C", // a part with no name
        "system/../S/Startup-Sequence", // out of the tree
        "system/./C", // the drawer itself
        "..",
        "SYS:C/List", // a device of its own
        "system/C/Li\nst", // a line of its own
        "system/C/Li\x01st",
        "system/C/*", // a pattern, not a name
        "system/C/What?",
        "system/C/back\\slash",
        "#system/C/List", // would read back as the explanation
    }) |bad| try testing.expect(!manifest.pathOk(bad));

    // A reader refuses one, rather than reading it as well as it can.
    var read: [4]manifest.Entry = undefined;
    const head = "FORMAT=1 CHIP=rv64sbi DRAWERS=0 FILES=1 BYTES=1\n";
    try testing.expectError(error.BadPath, readAll(head ++ "00000000 1 system/../S/Startup-Sequence\n", &read));
}

test "the halves of a package" {
    const system = install.halfOf("system/C/List").?;
    try testing.expectEqual(install.Half.system, system.half);
    try testing.expectEqualStrings("C/List", system.rest);
    const boot = install.halfOf("BOOT/kernel.bin").?;
    try testing.expectEqual(install.Half.boot, boot.half);
    try testing.expectEqualStrings("kernel.bin", boot.rest);
    try testing.expect(install.halfOf("system") == null);
    try testing.expect(install.halfOf("sys/C/List") == null);
    try testing.expect(install.halfOf("C/List") == null);

    var path: [64]u8 = undefined;
    const length = install.join(.system, "C/List", &path);
    try testing.expectEqual(install.joinLength(.system, "C/List"), length);
    try testing.expectEqualStrings("system/C/List", path[0..length]);
}
