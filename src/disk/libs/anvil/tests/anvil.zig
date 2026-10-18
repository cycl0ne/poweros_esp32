// SPDX-License-Identifier: MIT
//! Host tests of anvil.library's parts that need no window: pictures
//! shrunk to the icon size, icons placed in the first free cell, the
//! ground's geometry, the title's figures, the tool types as Information
//! writes them, the startup drawer's order and waits, and the jump table.

const std = @import("std");
const sdk = @import("sdk");
const graphics = sdk.graphics;
const picture = @import("../icons/picture.zig");
const place = @import("../icons/place.zig");
const ground = @import("../desktop/ground.zig");
const title = @import("../desktop/title.zig");
const drawer_path = @import("../drawer/path.zig");
const textview = @import("../drawer/textview.zig");
const leaveout = @import("../desktop/leaveout.zig");
const information = @import("../info/information.zig");
const startup = @import("../desktop/startup.zig");
const Rect = graphics.Rect;

const testing = std.testing;

comptime {
    _ = @import("../anvil_lvo.zig");
}

test "a picture's size on the desktop: itself when it fits, its shape kept when it does not" {
    try testing.expectEqual(picture.Size{ .width = 40, .height = 30 }, picture.fitted(40, 30, 48));
    try testing.expectEqual(picture.Size{ .width = 48, .height = 24 }, picture.fitted(96, 48, 48));
    try testing.expectEqual(picture.Size{ .width = 24, .height = 48 }, picture.fitted(64, 128, 48));
    try testing.expectEqual(picture.Size{ .width = 48, .height = 1 }, picture.fitted(256, 2, 48));
}

test "shrinking: each pixel the average of those it covers, colour weighted by coverage" {
    // Four pixels into one: red covered, blue covered, two clear ones that
    // must not darken it.
    const from = [_]u8{
        255, 0, 0, 255, 0, 0, 255, 255,
        0,   0, 0, 0,   9, 9, 9,   0,
    };
    var into: [4]u8 = undefined;
    picture.shrink(&from, 2, 2, &into, .{ .width = 1, .height = 1 });
    try testing.expectEqual(@as(u8, 127), into[0]);
    try testing.expectEqual(@as(u8, 0), into[1]);
    try testing.expectEqual(@as(u8, 127), into[2]);
    try testing.expectEqual(@as(u8, 127), into[3]);
    // A wholly clear area stays clear and black.
    const clear = [_]u8{ 7, 7, 7, 0 } ** 4;
    picture.shrink(&clear, 2, 2, &into, .{ .width = 1, .height = 1 });
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &into);
}

test "placing: down the right edge a column at a time, around what is there" {
    const area = Rect{ .min_x = 0, .min_y = 0, .max_x = 300, .max_y = 200 };
    const cell = place.Cell{ .width = 100, .height = 100 };
    try testing.expectEqual(place.Point{ .x = 200, .y = 0 }, place.firstFree(area, cell, &.{}, .columns_from_right));
    const one = [_]Rect{.{ .min_x = 210, .min_y = 10, .max_x = 260, .max_y = 60 }};
    try testing.expectEqual(place.Point{ .x = 200, .y = 100 }, place.firstFree(area, cell, &one, .columns_from_right));
    const column = [_]Rect{ one[0], .{ .min_x = 220, .min_y = 120, .max_x = 280, .max_y = 180 } };
    try testing.expectEqual(place.Point{ .x = 100, .y = 0 }, place.firstFree(area, cell, &column, .columns_from_right));
    // A drawer fills rows from the top left.
    try testing.expectEqual(place.Point{ .x = 100, .y = 0 }, place.firstFree(area, cell, &.{.{ .min_x = 0, .min_y = 0, .max_x = 50, .max_y = 50 }}, .rows_from_left));
    // Every cell taken: the first, rather than off the ground.
    const all = [_]Rect{area};
    try testing.expectEqual(place.Point{ .x = 200, .y = 0 }, place.firstFree(area, cell, &all, .columns_from_right));
}

test "the ground: a picture scaled to cover, centred, and which colours are light" {
    // Wider than the ground: as high as it, cut equally left and right.
    try testing.expectEqual(Rect{ .min_x = -100, .min_y = 0, .max_x = 1100, .max_y = 600 }, ground.cover(800, 400, 1000, 600));
    // Taller: as wide as it, cut at top and bottom.
    try testing.expectEqual(Rect{ .min_x = 0, .min_y = -200, .max_x = 1000, .max_y = 800 }, ground.cover(500, 500, 1000, 600));
    try testing.expectEqual(Rect{ .min_x = 450, .min_y = 250, .max_x = 550, .max_y = 350 }, ground.centred(100, 100, 1000, 600));
    try testing.expect(ground.isLight(0xFFAAAAAA));
    try testing.expect(!ground.isLight(0xFF3A5F8A));
    try testing.expect(!ground.isLight(0xFF000000));
}

test "the title: kilobytes free, the thousands parted, PSRAM only when there is some" {
    var text: [96]u8 = undefined;
    const n = title.memoryTitle(&text, 123 * 1024 + 500, 4_620_288, null);
    try testing.expectEqualStrings("Anvil   Internal 123 KB free   PSRAM 4,512 KB free", text[0..n]);
    try testing.expectEqual(@as(u8, 0), text[n]);
    const m = title.memoryTitle(&text, 1_234_567 * 1024, 0, null);
    try testing.expectEqualStrings("Anvil   Internal 1,234,567 KB free", text[0..m]);
}

test "the title: the battery's charge where a cell is measured" {
    const battery = @import("sdk").resources.battery;
    var text: [96]u8 = undefined;
    var state = battery.BatteryState{ .flags = battery.BATTF_MEASURED | battery.BATTF_PRESENT, .percent = 70 };
    var n = title.memoryTitle(&text, 446 * 1024, 32_747 * 1024, &state);
    try testing.expectEqualStrings("Anvil   Internal 446 KB free   PSRAM 32,747 KB free   Battery 70%", text[0..n]);
    state.flags |= battery.BATTF_KNOWS_EXTERNAL | battery.BATTF_EXTERNAL;
    n = title.memoryTitle(&text, 446 * 1024, 0, &state);
    try testing.expectEqualStrings("Anvil   Internal 446 KB free   Battery 70%, external power", text[0..n]);
    state.flags |= battery.BATTF_CHARGING;
    state.percent = 100;
    n = title.memoryTitle(&text, 446 * 1024, 32_747 * 1024, &state);
    try testing.expectEqualStrings("Anvil   Internal 446 KB free   PSRAM 32,747 KB free   Battery 100%, charging", text[0..n]);
    // Measured, but no cell: nothing said.
    state.flags = battery.BATTF_MEASURED;
    n = title.memoryTitle(&text, 446 * 1024, 0, &state);
    try testing.expectEqualStrings("Anvil   Internal 446 KB free", text[0..n]);
}

test "a drawer's path: its parent, a name joined on, its last part" {
    try testing.expectEqualStrings("Work:Pictures", drawer_path.parent("Work:Pictures/Holiday").?);
    try testing.expectEqualStrings("Work:", drawer_path.parent("Work:Pictures").?);
    try testing.expect(drawer_path.parent("Work:") == null);
    var into: [32]u8 = undefined;
    try testing.expectEqualStrings("Work:Pictures", into[0..drawer_path.join(&into, "Work:", "Pictures").?]);
    try testing.expectEqualStrings("Work:Pictures/One", into[0..drawer_path.join(&into, "Work:Pictures", "One").?]);
    try testing.expectEqual(@as(u8, 0), into[17]);
    try testing.expect(drawer_path.join(into[0..8], "Work:", "Pictures") == null);
    try testing.expectEqualStrings("Holiday", drawer_path.lastPart("Work:Pictures/Holiday"));
    try testing.expectEqualStrings("Work", drawer_path.lastPart("Work:"));
}

test "snapping: the free cell nearest where an icon was let go, counted from the ground's own edge" {
    const area = Rect{ .min_x = 0, .min_y = 0, .max_x = 300, .max_y = 200 };
    const cell = place.Cell{ .width = 100, .height = 100 };
    // A drawer's grid from the left: the cell nearest, rounded.
    try testing.expectEqual(place.Point{ .x = 100, .y = 0 }, place.nearestFree(area, cell, &.{}, .{ .x = 90, .y = 10 }, .rows_from_left));
    try testing.expectEqual(place.Point{ .x = 200, .y = 100 }, place.nearestFree(area, cell, &.{}, .{ .x = 160, .y = 70 }, .rows_from_left));
    // Past the ground's edge: the last cell inside it.
    try testing.expectEqual(place.Point{ .x = 200, .y = 100 }, place.nearestFree(area, cell, &.{}, .{ .x = 900, .y = 900 }, .rows_from_left));
    try testing.expectEqual(place.Point{ .x = 0, .y = 0 }, place.nearestFree(area, cell, &.{}, .{ .x = -50, .y = -50 }, .rows_from_left));
    // That cell taken: the free one nearest of the ring round it.
    const there = [_]Rect{.{ .min_x = 110, .min_y = 10, .max_x = 160, .max_y = 60 }};
    try testing.expectEqual(place.Point{ .x = 0, .y = 0 }, place.nearestFree(area, cell, &there, .{ .x = 90, .y = 10 }, .rows_from_left));
    try testing.expectEqual(place.Point{ .x = 200, .y = 0 }, place.nearestFree(area, cell, &there, .{ .x = 140, .y = 0 }, .rows_from_left));
    // The desktop's grid from the right edge: an area not a whole number
    // of cells wide still has its first column at the edge.
    const wide = Rect{ .min_x = 0, .min_y = 0, .max_x = 350, .max_y = 200 };
    try testing.expectEqual(place.Point{ .x = 250, .y = 100 }, place.nearestFree(wide, cell, &.{}, .{ .x = 240, .y = 110 }, .columns_from_right));
    try testing.expectEqual(place.Point{ .x = 150, .y = 0 }, place.nearestFree(wide, cell, &.{}, .{ .x = 170, .y = 20 }, .columns_from_right));
    // Every cell taken: the nearest, rather than off the ground.
    const all = [_]Rect{area};
    try testing.expectEqual(place.Point{ .x = 100, .y = 0 }, place.nearestFree(area, cell, &all, .{ .x = 90, .y = 10 }, .rows_from_left));
}

test "a disk's title: how full, free and used, in K, then M, G, T and P past 9,999 of each" {
    var text: [96]u8 = undefined;
    const n = drawer_path.diskTitle(&text, "Work", 1000, 450, 1024);
    try testing.expectEqualStrings("Work  45% full, 550K free, 450K in use", text[0..n]);
    const m = drawer_path.diskTitle(&text, "Card", 4_000_000, 1_000_000, 512);
    try testing.expectEqualStrings("Card  25% full, 1,464M free, 488M in use", text[0..m]);
    // A 2 TB disk a quarter full, in 4 KiB blocks.
    const g = drawer_path.diskTitle(&text, "Big", 488_281_250, 122_070_312, 4096);
    try testing.expectEqualStrings("Big  25% full, 1,396G free, 465G in use", text[0..g]);
    try testing.expectEqualStrings("Gone", text[0..drawer_path.diskTitle(&text, "Gone", 0, 0, 0)]);
    // Each unit up to 9,999, the next past it; P as far as a u64 goes.
    var size: [24]u8 = undefined;
    try testing.expectEqualStrings("9,999M", size[0..drawer_path.amount(&size, 9999 << 20)]);
    try testing.expectEqualStrings("9G", size[0..drawer_path.amount(&size, 10000 << 20)]);
    try testing.expectEqualStrings("12T", size[0..drawer_path.amount(&size, 12 << 40)]);
    try testing.expectEqualStrings("10P", size[0..drawer_path.amount(&size, 10 << 50)]);
    try testing.expectEqualStrings("16,383P", size[0..drawer_path.amount(&size, ~@as(u64, 0))]);
}

test "rows: names in order case aside, the protection as hsparwed" {
    try testing.expect(textview.nameBefore("apple", "Banana"));
    try testing.expect(!textview.nameBefore("Banana", "apple"));
    try testing.expect(textview.nameBefore("Note", "notes"));
    var bits: [8]u8 = undefined;
    textview.protectionText(&bits, 0);
    try testing.expectEqualStrings("----rwed", &bits);
    textview.protectionText(&bits, sdk.dos.FIBF_SCRIPT | sdk.dos.FIBF_DELETE | sdk.dos.FIBF_WRITE);
    try testing.expectEqualStrings("-s--r-e-", &bits);
}

test "a drawer's cells: one after another along the rows, past what lies where its file says" {
    const area = Rect{ .min_x = 8, .min_y = 8, .max_x = 308, .max_y = 1000 };
    const cell = place.Cell{ .width = 100, .height = 60 };
    var found = place.nextFree(area, cell, &.{}, 0);
    try testing.expectEqual(place.Point{ .x = 8, .y = 8 }, found.at);
    found = place.nextFree(area, cell, &.{}, found.index + 1);
    try testing.expectEqual(place.Point{ .x = 108, .y = 8 }, found.at);
    // The third cell taken by an icon of its own: the fourth, on the next row.
    const own = [_]Rect{.{ .min_x = 220, .min_y = 10, .max_x = 260, .max_y = 50 }};
    found = place.nextFree(area, cell, &own, found.index + 1);
    try testing.expectEqual(place.Point{ .x = 8, .y = 68 }, found.at);
}

test ".backdrop: a line per file left out, from the volume's root after a colon" {
    const text = ":Work/Notes\n:Readme\r\n\nnot a line\n:\n:Pictures/Sea Side.png";
    var seen: [4][]const u8 = undefined;
    var count: usize = 0;
    const Gather = struct {
        seen: *[4][]const u8,
        count: *usize,
        fn each(gather: @This(), rest: []const u8) void {
            gather.seen[gather.count.*] = rest;
            gather.count.* += 1;
        }
    };
    leaveout.lines(text, Gather{ .seen = &seen, .count = &count }, Gather.each);
    try testing.expectEqual(@as(usize, 3), count);
    try testing.expectEqualStrings("Work/Notes", seen[0]);
    try testing.expectEqualStrings("Readme", seen[1]);
    try testing.expectEqualStrings("Pictures/Sea Side.png", seen[2]);
    const parts = leaveout.split("Work:Pictures/One").?;
    try testing.expectEqualStrings("Work", parts.volume);
    try testing.expectEqualStrings("Pictures/One", parts.rest);
    try testing.expect(leaveout.split("NoColon") == null);
}

test "tool types: a line each, empty lines left out, as many as fit" {
    var text = "DONOTWAIT\n\nTABS=4\nLAST?".*;
    var into: [4]?[*:0]const u8 = undefined;
    try testing.expectEqual(@as(usize, 3), information.splitLines(&text, &into));
    try testing.expectEqualStrings("DONOTWAIT", std.mem.span(into[0].?));
    try testing.expectEqualStrings("TABS=4", std.mem.span(into[1].?));
    try testing.expectEqualStrings("LAST", std.mem.span(into[2].?));
    try testing.expectEqual(@as(?[*:0]const u8, null), into[3]);

    var more = "A\nB\nC\n?".*;
    var two: [3]?[*:0]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), information.splitLines(&more, &two));
    try testing.expectEqual(@as(?[*:0]const u8, null), two[2]);

    var none = "\n\n?".*;
    try testing.expectEqual(@as(usize, 0), information.splitLines(&none, &two));
    try testing.expectEqual(@as(?[*:0]const u8, null), two[0]);
}

test "the startup drawer: highest STARTPRI first, equals in the drawer's order; WAIT in seconds" {
    var order: startup.Startup = .{};
    const given = [_]struct { name: []const u8, priority: i32 }{
        .{ .name = "Clock", .priority = 0 },
        .{ .name = "Mail", .priority = 10 },
        .{ .name = "Notes", .priority = 0 },
        .{ .name = "Last", .priority = -5 },
        .{ .name = "First", .priority = 127 },
    };
    for (given) |one| {
        var entry = startup.Entry{ .priority = one.priority };
        @memcpy(entry.name[0..one.name.len], one.name);
        startup.insert(&order, entry);
    }
    const wanted = [_][]const u8{ "First", "Mail", "Clock", "Notes", "Last" };
    try testing.expectEqual(wanted.len, order.count);
    for (wanted, order.entries[0..order.count]) |name, entry| {
        try testing.expectEqualStrings(name, std.mem.sliceTo(&entry.name, 0));
    }
    try testing.expectEqual(@as(?u32, 10), startup.seconds("10"));
    try testing.expectEqual(@as(?u32, 0), startup.seconds("0"));
    try testing.expectEqual(@as(?u32, 3600), startup.seconds("9999"));
    try testing.expectEqual(@as(?u32, null), startup.seconds("5s"));
    try testing.expectEqual(@as(?u32, null), startup.seconds(""));
}
