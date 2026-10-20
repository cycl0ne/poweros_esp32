// SPDX-License-Identifier: MIT
//! Host tests of HDToolBox's workings: free runs, partitions made, moved
//! and resized between their neighbours and snapped to the grid, the
//! bar's pixels, names and sizes, what a save leaves stale, and the
//! drives found on dos's list for a unit - the last with dos.library and
//! expansion.library brought up as the ROM has them. The window is not
//! here.

const std = @import("std");
const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const host_rom = @import("host_rom");
const kexec = host_rom.exec;
const kutility = host_rom.utility;
const kdos = host_rom.dos;
const kexpansion = host_rom.expansion;
const model = @import("../model.zig");
const drives = @import("../drives.zig");

const testing = std.testing;
const Span = model.Span;

fn span(low: u32, high: u32) Span {
    return .{ .low = low, .high = high };
}

test "HDToolBox: partitions in the order of their cylinders, and the runs between" {
    const spans = [_]Span{ span(40, 63), span(100, 120), span(16, 39) };
    var sorted_index: [3]u32 = undefined;
    model.order(&spans, &sorted_index);
    try testing.expectEqualSlices(u32, &.{ 2, 0, 1 }, &sorted_index);

    const area = span(16, 199);
    const sorted = [_]Span{ span(16, 39), span(40, 63), span(100, 120) };
    var runs: [4]Span = undefined;
    const free = model.gaps(area, &sorted, &runs);
    try testing.expectEqual(@as(usize, 2), free.len);
    try testing.expectEqual(span(64, 99), free[0]);
    try testing.expectEqual(span(121, 199), free[1]);

    // An empty table is one run; a full one none.
    try testing.expectEqual(span(16, 199), model.gaps(area, &.{}, &runs)[0]);
    try testing.expectEqual(@as(usize, 0), model.gaps(area, &.{span(16, 199)}, &runs).len);
    // Only as many as there is room for.
    try testing.expectEqual(@as(usize, 1), model.gaps(area, &sorted, runs[0..1]).len);

    // A partition may go from past the one below to before the one above.
    try testing.expectEqual(span(16, 39), model.room(area, &sorted, 0));
    try testing.expectEqual(span(40, 99), model.room(area, &sorted, 1));
    try testing.expectEqual(span(64, 199), model.room(area, &sorted, 2));
}

test "HDToolBox: the grid is whole MiB without an erase unit" {
    // 512-byte cylinders: 2048 to a MiB.
    try testing.expectEqual(@as(u64, 2048), model.Grid.of(512, 0).step);
    // An erase unit, cylinders of a MiB or more, or ones that do not go
    // into a MiB: every cylinder.
    try testing.expectEqual(@as(u64, 1), model.Grid.of(4096, 4096).step);
    try testing.expectEqual(@as(u64, 1), model.Grid.of(1 << 20, 0).step);
    try testing.expectEqual(@as(u64, 1), model.Grid.of(3 << 20, 0).step);
    try testing.expectEqual(@as(u64, 1), model.Grid.of(1536, 0).step);

    const grid = model.Grid.of(512, 0);
    try testing.expectEqual(@as(u64, 2048), grid.up(16));
    try testing.expectEqual(@as(u64, 2048), grid.up(2048));
    try testing.expectEqual(@as(u64, 0), grid.down(2047));

    // A new partition starts on the grid and goes to the run's end.
    try testing.expectEqual(span(2048, 9999), model.fresh(span(16, 9999), grid));
    // A run the grid leaves nothing of is taken whole.
    try testing.expectEqual(span(16, 1000), model.fresh(span(16, 1000), grid));
    try testing.expectEqual(span(16, 1000), model.fresh(span(16, 1000), .{}));
}

test "HDToolBox: a partition moved as far as its neighbours let it" {
    const within = span(64, 199);
    const part = span(100, 119); // 20 cylinders
    try testing.expectEqual(span(120, 139), model.moved(within, part, 120, .{}));
    try testing.expectEqual(span(64, 83), model.moved(within, part, 10, .{}));
    try testing.expectEqual(span(64, 83), model.moved(within, part, -5, .{}));
    try testing.expectEqual(span(180, 199), model.moved(within, part, 190, .{}));

    // On the grid, or against a neighbour where that is nearer.
    const grid = model.Grid{ .step = 32 };
    try testing.expectEqual(span(96, 115), model.moved(within, part, 100, grid));
    try testing.expectEqual(span(64, 83), model.moved(within, part, 70, grid));
    try testing.expectEqual(span(180, 199), model.moved(within, part, 175, grid));
}

test "HDToolBox: a partition resized by either edge, a cylinder long at least" {
    const within = span(64, 199);
    const part = span(100, 119);
    try testing.expectEqual(span(100, 149), model.resized(within, part, .high, 150, .{}));
    try testing.expectEqual(span(100, 199), model.resized(within, part, .high, 500, .{}));
    try testing.expectEqual(span(100, 100), model.resized(within, part, .high, 20, .{}));
    try testing.expectEqual(span(80, 119), model.resized(within, part, .low, 80, .{}));
    try testing.expectEqual(span(64, 119), model.resized(within, part, .low, 0, .{}));
    try testing.expectEqual(span(119, 119), model.resized(within, part, .low, 150, .{}));

    const grid = model.Grid{ .step = 32 };
    try testing.expectEqual(span(100, 159), model.resized(within, part, .high, 150, grid));
    // Nearer the neighbour above than the grid's 192.
    try testing.expectEqual(span(100, 199), model.resized(within, part, .high, 197, grid));
    try testing.expectEqual(span(64, 119), model.resized(within, part, .low, 70, grid));
}

test "HDToolBox: the bar's pixels and cylinders" {
    const bar = model.Bar{ .area = span(16, 1015), .width = 100 }; // 10 cylinders a pixel
    try testing.expectEqual(@as(u32, 0), bar.x(16));
    try testing.expectEqual(@as(u32, 50), bar.x(516));
    try testing.expectEqual(@as(u32, 100), bar.x(1016));
    try testing.expectEqual(@as(u32, 100), bar.x(5000));
    try testing.expectEqual(@as(u64, 516), bar.boundaryAt(50));
    try testing.expectEqual(@as(u64, 16), bar.boundaryAt(-3));
    try testing.expectEqual(@as(u64, 1016), bar.boundaryAt(400));
    try testing.expectEqual(@as(u32, 516), bar.cylinderAt(50));
    // A pixel's first cylinder.
    try testing.expectEqual(@as(u32, 1006), bar.cylinderAt(99));
    try testing.expectEqual(@as(u32, 1006), bar.cylinderAt(400));
    // A partition of a few cylinders still gets a pixel.
    const thin = bar.pixels(span(500, 502));
    try testing.expectEqual(@as(u32, 48), thin.left);
    try testing.expectEqual(@as(u32, 49), thin.right);

    // A medium of more than 2^32 blocks, in 2^32 cylinders less one.
    const huge = model.Bar{ .area = span(16, 0xFFFF_FFFE), .width = 800 };
    const half: u64 = (0xFFFF_FFFE - 16 + 1 + 1) / 2;
    try testing.expectEqual(@as(u32, 400), huge.x(16 + half));
    try testing.expectEqual(@as(u32, 399), huge.x(16 + half - 1));
    try testing.expectEqual(@as(u32, 800), huge.x(0xFFFF_FFFF));
    // Half the cylinders past the first: the one the middle pixel begins in.
    try testing.expectEqual(@as(u32, 16 + (0xFFFF_FFFE - 16 + 1) / 2), huge.cylinderAt(400));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFE), huge.boundaryAt(800) - 1);
}

test "HDToolBox: what a pixel of the bar is over" {
    const bar = model.Bar{ .area = span(16, 1015), .width = 100 };
    const sorted = [_]Span{ span(16, 315), span(516, 1015) }; // pixels 0..30, 50..100
    const grip = 8;
    try testing.expectEqual(model.Hit{ .part = .{ .index = 0, .grip = .low } }, model.hit(bar, &sorted, 3, grip));
    try testing.expectEqual(model.Hit{ .part = .{ .index = 0, .grip = .middle } }, model.hit(bar, &sorted, 15, grip));
    try testing.expectEqual(model.Hit{ .part = .{ .index = 0, .grip = .high } }, model.hit(bar, &sorted, 25, grip));
    try testing.expectEqual(model.Hit{ .part = .{ .index = 1, .grip = .high } }, model.hit(bar, &sorted, 95, grip));
    try testing.expectEqual(model.Hit{ .gap = span(316, 515) }, model.hit(bar, &sorted, 40, grip));
    try testing.expectEqual(model.Hit.none, model.hit(bar, &sorted, -1, grip));
    try testing.expectEqual(model.Hit.none, model.hit(bar, &sorted, 100, grip));
    // The last run, past every partition.
    try testing.expectEqual(model.Hit{ .gap = span(316, 1015) }, model.hit(bar, sorted[0..1], 70, grip));

    // A narrow partition keeps a middle to be moved by: a third each.
    const narrow = [_]Span{span(516, 605)}; // pixels 50..59
    try testing.expectEqual(model.Hit{ .part = .{ .index = 0, .grip = .low } }, model.hit(bar, &narrow, 52, grip));
    try testing.expectEqual(model.Hit{ .part = .{ .index = 0, .grip = .middle } }, model.hit(bar, &narrow, 54, grip));
    try testing.expectEqual(model.Hit{ .part = .{ .index = 0, .grip = .high } }, model.hit(bar, &narrow, 57, grip));
}

test "HDToolBox: names offered and names refused" {
    try testing.expectEqualStrings("DH", model.prefixFor("flash.device"));
    try testing.expectEqualStrings("SD", model.prefixFor("sdcard.device"));
    try testing.expectEqualStrings("DU", model.prefixFor("usb/disk.device"));
    try testing.expectEqualStrings("DU", model.prefixFor("DEVS:usb/disk.device"));
    try testing.expectEqualStrings("HD", model.prefixFor("nvme.device"));

    var name: [model.name_room]u8 = undefined;
    try testing.expectEqualStrings("DH0", model.freeName("DH", &.{}, &name));
    try testing.expectEqualStrings("DH2", model.freeName("DH", &.{ "dh0", "DH1", "RAM", "DH3" }, &name));
    try testing.expectEqualStrings("SD10", model.freeName("SD", &.{ "SD0", "SD1", "SD2", "SD3", "SD4", "SD5", "SD6", "SD7", "SD8", "SD9" }, &name));

    try testing.expectEqual(model.NameProblem.none, model.nameProblem("Work", &.{"DH0"}));
    try testing.expectEqual(model.NameProblem.empty, model.nameProblem("", &.{}));
    try testing.expectEqual(model.NameProblem.long, model.nameProblem("A" ** 31, &.{}));
    try testing.expectEqual(model.NameProblem.none, model.nameProblem("A" ** 30, &.{}));
    try testing.expectEqual(model.NameProblem.separator, model.nameProblem("DH:0", &.{}));
    try testing.expectEqual(model.NameProblem.separator, model.nameProblem("D/H", &.{}));
    try testing.expectEqual(model.NameProblem.taken, model.nameProblem("dh0", &.{"DH0"}));
}

test "HDToolBox: sizes as text" {
    var text: [model.size_room]u8 = undefined;
    try testing.expectEqualStrings("512", model.sizeText(512, &text));
    try testing.expectEqualStrings("1.0K", model.sizeText(1024, &text));
    try testing.expectEqualStrings("1.9K", model.sizeText(2047, &text));
    try testing.expectEqualStrings("1.5M", model.sizeText(3 << 19, &text));
    try testing.expectEqualStrings("120G", model.sizeText(120 << 30, &text));
    try testing.expectEqualStrings("2.0T", model.sizeText(2 << 40, &text));
    try testing.expectEqualStrings("16777215T", model.sizeText(std.math.maxInt(u64), &text));
}

test "HDToolBox: numbers typed, and DosTypes written" {
    try testing.expectEqual(@as(?u64, 0), model.parseNumber("0"));
    try testing.expectEqual(@as(?u64, 4294967294), model.parseNumber(" 4294967294 "));
    try testing.expectEqual(@as(?u64, std.math.maxInt(u64)), model.parseNumber("18446744073709551615"));
    for ([_][]const u8{ "", "  ", "-1", "12a", "1 2", "18446744073709551616" }) |text| {
        try testing.expectEqual(@as(?u64, null), model.parseNumber(text));
    }

    var text: [model.type_room]u8 = undefined;
    try testing.expectEqualStrings("POS\\0", model.typeText(dos.posfs.ID_POSFS_DISK, &text));
    try testing.expectEqualStrings("MSD\\0", model.typeText(dos.ID_MSDOS_DISK, &text));
    try testing.expectEqualStrings("\\255\\1AB", model.typeText(0xFF01_4142, &text));
}

test "HDToolBox: which drives a save leaves stale" {
    const fls = dos.flashfs.ID_FLASHFS_DISK;
    const posfs = dos.posfs.ID_POSFS_DISK;
    const work: dos.DosEnvec = .{ .size_block = 4096, .low_cyl = 40, .high_cyl = 63, .dos_type = posfs };
    const system: dos.DosEnvec = .{ .size_block = 4096, .low_cyl = 16, .high_cyl = 39, .dos_type = fls };
    const table = [_]dos.DosEnvec{ system, work };

    // Laid out as before: kept, whatever else changed.
    var renamed = work;
    renamed.num_buffers = 100;
    renamed.boot_pri = 5;
    try testing.expect(model.sameLayout(&renamed, &work));
    try testing.expect(!model.stale(&renamed, &table));

    // Moved, resized, retyped, or another block size: stale.
    var changed = work;
    changed.low_cyl = 41;
    try testing.expect(model.stale(&changed, &table));
    changed = work;
    changed.high_cyl = 70;
    try testing.expect(model.stale(&changed, &table));
    changed = work;
    changed.dos_type = dos.ID_MSDOS_DISK;
    try testing.expect(model.stale(&changed, &table));
    changed = work;
    changed.size_block = 512;
    try testing.expect(model.stale(&changed, &table));
    changed = work;
    changed.reserved = 2;
    try testing.expect(model.stale(&changed, &table));

    // A drive over the whole medium, once there is a table.
    const whole: dos.DosEnvec = .{ .dos_type = dos.ID_MSDOS_DISK };
    try testing.expect(model.stale(&whole, &table));
    try testing.expect(model.kept(&table, &system));
    try testing.expect(!model.kept(table[0..1], &work));
}

test "HDToolBox: a GPT's partitions on the bar, and a container's table on the disk" {
    // Cylinders of 2048 blocks: a partition reaches into every cylinder
    // it has a block of.
    try testing.expectEqual(span(0, 0), model.blockSpan(34, 2047, 2048));
    try testing.expectEqual(span(1, 4), model.blockSpan(2048, 10239, 2048));
    try testing.expectEqual(span(34, 99), model.blockSpan(34, 99, 0));

    // A table in a container from block 8192, cylinders of 2048 blocks:
    // four cylinders along on the disk.
    const part: dos.DosEnvec = .{ .size_block = 512, .surfaces = 1, .blocks_per_track = 2048, .low_cyl = 1, .high_cyl = 9 };
    const placed = model.onDisk(&part, 8192);
    try testing.expectEqual(@as(u32, 5), placed.low_cyl);
    try testing.expectEqual(@as(u32, 13), placed.high_cyl);
    try testing.expectEqual(@as(u32, 1), model.onDisk(&part, 0).low_cyl);
    // A container off the partition's cylinders: left as it is.
    try testing.expectEqual(@as(u32, 1), model.onDisk(&part, 100).low_cyl);

    // A drive mounted from a partition of the GPT, as MountGPTPartition
    // lays it out: cylinders of one block.
    const fat: dos.DosEnvec = .{ .size_block = 512, .surfaces = 1, .blocks_per_track = 1, .low_cyl = 2048, .high_cyl = 206847 };
    try testing.expect(model.covers(&fat, 2048, 206847, 512));
    try testing.expect(!model.covers(&fat, 2048, 206848, 512));
    try testing.expect(!model.covers(&fat, 4096, 206847, 512));
    try testing.expect(model.covers(&placed, 10240, 28671, 512));
    const whole: dos.DosEnvec = .{};
    try testing.expect(!model.covers(&whole, 0, 0, 512));
}

test "HDToolBox: which span a pixel of the bar is over" {
    const bar: model.Bar = .{ .area = span(0, 99), .width = 100 };
    const spans = [_]Span{ span(10, 19), span(50, 59) };
    try testing.expectEqual(@as(?usize, 0), model.under(bar, &spans, 10));
    try testing.expectEqual(@as(?usize, 0), model.under(bar, &spans, 19));
    try testing.expectEqual(@as(?usize, 1), model.under(bar, &spans, 55));
    try testing.expectEqual(@as(?usize, null), model.under(bar, &spans, 20));
    try testing.expectEqual(@as(?usize, null), model.under(bar, &spans, -1));
    try testing.expectEqual(@as(?usize, null), model.under(bar, &spans, 100));
}

// --- the drives on dos's list ---------------------------------------------------------

const Rig = struct {
    db: *kdos.DosBase,
    eb: *kexpansion.ExpansionBase,
    dl: *sdk.interface.dos.DosBase,

    fn init() !Rig {
        try kexec.setUp();
        _ = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
        const expansion_made = kexec.InitResident(kexec.SysBase, &kexpansion.expansion_library_tag, null) orelse return error.NoExpansion;
        const dos_made = kexec.InitResident(kexec.SysBase, &kdos.dos_library_tag, null) orelse return error.NoDos;
        const db: *kdos.DosBase = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(dos_made))));
        return .{
            .db = db,
            .eb = @fieldParentPtr("lib", @as(*exec.Library, @ptrCast(@alignCast(expansion_made)))),
            .dl = db.iface(),
        };
    }

    /// expansion and dos taken down, which frees what is on dos's list
    /// and checks that nothing is left.
    fn deinit(rig: *Rig) !void {
        kexpansion.testTakeDown(rig.eb);
        try kdos.testTearDown(rig.db);
        kexec.deinit();
    }

    /// A device node on the list, its handler started from `startup`.
    fn drive(rig: *Rig, name: [*:0]const u8, startup: ?*dos.FileSysStartupMsg) !*dos.DosList {
        const node = rig.dl.MakeDosEntry(name, dos.DLT_DEVICE) orelse return error.NoMemory;
        if (startup) |msg| node.misc.handler.startup = @intFromPtr(msg);
        if (!rig.dl.AddDosEntry(node)) {
            rig.dl.FreeDosEntry(node);
            return error.Taken;
        }
        return node;
    }
};

test "HDToolBox: the drives mounted from a unit" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;

    var system_env: dos.DosEnvec = .{ .size_block = 4096, .low_cyl = 16, .high_cyl = 39, .dos_type = dos.flashfs.ID_FLASHFS_DISK };
    var work_env: dos.DosEnvec = .{ .size_block = 4096, .low_cyl = 40, .high_cyl = 63, .dos_type = dos.posfs.ID_POSFS_DISK };
    var system = dos.FileSysStartupMsg{ .unit = 0, .device = "flash.device", .environ = &system_env };
    var work = dos.FileSysStartupMsg{ .unit = 0, .device = "flash.device", .environ = &work_env };
    var card = dos.FileSysStartupMsg{ .unit = 0, .device = "DEVS:sdcard.device" };
    var stick = dos.FileSysStartupMsg{ .unit = 1, .device = "usb/disk.device" };
    const dh0 = try rig.drive("DH0", &system);
    _ = try rig.drive("DH1", &work);
    _ = try rig.drive("SD0", &card);
    _ = try rig.drive("DU1", &stick);
    _ = try rig.drive("ALONE", null);

    var found: [drives.max_mounted]drives.Mounted = undefined;
    const flash = drives.mountedOn(rig.dl, "flash.device", 0, dh0, &found);
    try testing.expectEqual(@as(usize, 2), flash.len);
    var dh0_seen = false;
    for (flash) |*mounted| {
        if (std.mem.eql(u8, mounted.nameText(), "DH0")) {
            dh0_seen = true;
            try testing.expect(mounted.system);
            try testing.expect(model.sameLayout(&mounted.env, &system_env));
        } else {
            try testing.expectEqualStrings("DH1", mounted.nameText());
            try testing.expect(!mounted.system);
            try testing.expect(model.sameLayout(&mounted.env, &work_env));
        }
        try testing.expect(!mounted.started);
    }
    try testing.expect(dh0_seen);

    // The device by its last part; a node with no environment is over the
    // whole medium.
    const cards = drives.mountedOn(rig.dl, "sdcard.device", 0, null, &found);
    try testing.expectEqual(@as(usize, 1), cards.len);
    try testing.expectEqualStrings("SD0", cards[0].nameText());
    try testing.expect(cards[0].env.wholeMedium());
    try testing.expectEqual(@as(usize, 1), drives.mountedOn(rig.dl, "DEVS:usb/disk.device", 1, null, &found).len);
    try testing.expectEqual(@as(usize, 0), drives.mountedOn(rig.dl, "usb/disk.device", 0, null, &found).len);
    // Only as many as there is room for.
    try testing.expectEqual(@as(usize, 1), drives.mountedOn(rig.dl, "flash.device", 0, null, found[0..1]).len);
}

test "HDToolBox: the names a new partition is not offered" {
    var rig = try Rig.init();
    defer rig.deinit() catch unreachable;

    _ = try rig.drive("DH0", null);
    const assign = rig.dl.MakeDosEntry("Work", dos.DLT_DIRECTORY) orelse return error.NoMemory;
    try testing.expect(rig.dl.AddDosEntry(assign));
    const volume = rig.dl.MakeDosEntry("DH1", dos.DLT_VOLUME) orelse return error.NoMemory;
    try testing.expect(rig.dl.AddDosEntry(volume));

    var names: drives.Names = .{};
    names.addDosList(rig.dl);
    names.add("DH2");
    var name: [model.name_room]u8 = undefined;
    // A volume's name is no device's: DH1 is offered.
    try testing.expectEqualStrings("DH1", model.freeName("DH", names.all(), &name));
    try testing.expect(model.nameProblem("work", names.all()) == .taken);
    try testing.expect(model.nameProblem("dh2", names.all()) == .taken);
}
