// SPDX-License-Identifier: MIT
//! Host tests of what the Emoji window shows (`picker.zig`): the book
//! made of the two files, a search, the ones used last and their file,
//! and the grid's cells.

const std = @import("std");
const testing = std.testing;
const sdk = @import("sdk");
const host_rom = @import("host_rom");
const kexec = host_rom.exec;
const kutility = host_rom.utility;
const picker = @import("../picker.zig");
const UtilityBase = sdk.interface.utility.UtilityBase;

const list_file = "emoji-list 1 2 4\n" ++
    "@Smileys & Emotion\n" ++
    "\u{1F600}\n" ++
    "\u{2764}\u{FE0F}\n" ++
    "@People & Body\n" ++
    "\u{1F44B}\t\u{1F44B}\u{1F3FB}\t\u{1F44B}\u{1F3FC}\t\u{1F44B}\u{1F3FD}\t\u{1F44B}\u{1F3FE}\t\u{1F44B}\u{1F3FF}\n" ++
    "\u{1F9D1}\u{200D}\u{1F91D}\u{200D}\u{1F9D1}\n";

const names_file = "emoji-names 1 3 deutsch\n" ++
    "\u{1F600}\tgrinsendes Gesicht\tfroh|fr\u{F6}hlich|Gesicht|lachen\n" ++
    "\u{2764}\u{FE0F}\trotes Herz\tHerz|Liebe\n" ++
    "\u{1F44B}\twinkende Hand\thallo|tsch\u{FC}ss|\u{DC}bung\n";

const english_file = "emoji-names 1 4 english\n" ++
    "\u{1F600}\tgrinning face\tface|grin\n" ++
    "\u{2764}\u{FE0F}\tred heart\theart\n" ++
    "\u{1F44B}\twaving hand\thand|wave\n" ++
    "\u{1F9D1}\u{200D}\u{1F91D}\u{200D}\u{1F9D1}\tpeople holding hands\tcouple|hand\n";

/// utility.library on the host, for the lower case of what is typed.
const Rig = struct {
    ub: *UtilityBase,

    fn init() !Rig {
        try kexec.setUp();
        errdefer kexec.deinit();
        const made = kexec.InitResident(kexec.SysBase, &kutility.utility_library_tag, null) orelse return error.NoUtility;
        return .{ .ub = @ptrCast(@alignCast(made)) };
    }

    fn deinit(_: *Rig) void {
        kexec.deinit();
    }
};

fn book(entries: []picker.Entry) picker.Book {
    var made = picker.Book{ .entries = entries };
    std.debug.assert(made.read(list_file));
    return made;
}

test "the book: the groups as runs, names in the list's order, a second language for the rest" {
    var entries: [4]picker.Entry = undefined;
    var made = book(&entries);
    try testing.expectEqual(@as(u32, 4), made.count);
    try testing.expectEqual(@as(u32, 2), made.group_count);
    try testing.expectEqualStrings("Smileys & Emotion", made.groups[0].name);
    try testing.expectEqual(@as(u32, 0), made.groups[0].first);
    try testing.expectEqual(@as(u32, 2), made.groups[0].count);
    try testing.expectEqual(@as(u32, 2), made.groups[1].first);
    try testing.expectEqual(@as(u32, 2), made.groups[1].count);

    try testing.expectEqual(@as(u32, 3), made.name(names_file));
    try testing.expectEqualStrings("rotes Herz", made.entries[1].name);
    try testing.expectEqualStrings("", made.entries[3].name);
    // The second language names only what the first left.
    try testing.expectEqual(@as(u32, 1), made.name(english_file));
    try testing.expectEqualStrings("winkende Hand", made.entries[2].name);
    try testing.expectEqualStrings("people holding hands", made.entries[3].name);

    try testing.expectEqual(@as(?u32, 2), made.find("\u{1F44B}"));
    try testing.expectEqual(@as(?u32, null), made.find("\u{1F44B}\u{1F3FB}"));

    var shown: [4]u32 = undefined;
    try testing.expectEqual(@as(u32, 2), made.group(1, &shown));
    try testing.expectEqualSlices(u32, &.{ 2, 3 }, shown[0..2]);
    try testing.expectEqual(@as(u32, 0), made.group(2, &shown));
    try testing.expect(!made.read("emoji-names 1 0 x\n"));
}

test "the book: no more emoji than there is room for, and one before any group" {
    var entries: [2]picker.Entry = undefined;
    var made = picker.Book{ .entries = &entries };
    try testing.expect(made.read("emoji-list 1 1 3\n\u{1F600}\n@Later\n\u{1F601}\n\u{1F602}\n"));
    try testing.expectEqual(@as(u32, 2), made.count);
    try testing.expectEqual(@as(u32, 2), made.group_count);
    try testing.expectEqualStrings("", made.groups[0].name);
    try testing.expectEqual(@as(u32, 1), made.groups[0].count);
    try testing.expectEqual(@as(u32, 1), made.groups[1].count);
}

test "a search: every word, in the name or a keyword, whatever the case" {
    var rig = try Rig.init();
    defer rig.deinit();
    var entries: [4]picker.Entry = undefined;
    var made = book(&entries);
    _ = made.name(names_file);
    _ = made.name(english_file);
    var found: [4]u32 = undefined;

    var query = picker.Query.init(rig.ub, "HERZ");
    try testing.expectEqual(@as(u32, 1), made.search(rig.ub, &query, &found));
    try testing.expectEqual(@as(u32, 1), found[0]);

    // Part of a word, and a letter past ASCII in either case.
    query = picker.Query.init(rig.ub, "FR\u{D6}H");
    try testing.expectEqual(@as(u32, 1), made.search(rig.ub, &query, &found));
    try testing.expectEqual(@as(u32, 0), found[0]);
    query = picker.Query.init(rig.ub, "\u{FC}bung");
    try testing.expectEqual(@as(u32, 1), made.search(rig.ub, &query, &found));
    try testing.expectEqual(@as(u32, 2), found[0]);

    // Two words: both must be there.
    query = picker.Query.init(rig.ub, "  hand   wink ");
    try testing.expectEqual(@as(u32, 2), query.count);
    try testing.expectEqual(@as(u32, 1), made.search(rig.ub, &query, &found));
    try testing.expectEqual(@as(u32, 2), found[0]);
    query = picker.Query.init(rig.ub, "hand");
    try testing.expectEqual(@as(u32, 2), made.search(rig.ub, &query, &found));
    try testing.expectEqualSlices(u32, &.{ 2, 3 }, found[0..2]);
    try testing.expectEqual(@as(u32, 1), made.search(rig.ub, &query, found[0..1]));

    query = picker.Query.init(rig.ub, "zebra");
    try testing.expectEqual(@as(u32, 0), made.search(rig.ub, &query, &found));
    query = picker.Query.init(rig.ub, "   ");
    try testing.expect(query.empty());
    try testing.expectEqual(@as(u32, 0), made.search(rig.ub, &query, &found));
}

test "the ones used last: the newest first, each once, the oldest out" {
    var used: picker.Used = .{};
    try testing.expect(used.use(3));
    try testing.expect(used.use(1));
    try testing.expect(!used.use(1));
    try testing.expect(used.use(3));
    try testing.expectEqualSlices(u32, &.{ 3, 1 }, used.items[0..used.count]);

    var at: u32 = 10;
    while (at < 10 + picker.MOST_USED) : (at += 1) _ = used.use(at);
    try testing.expectEqual(@as(u32, picker.MOST_USED), used.count);
    try testing.expectEqual(@as(u32, 10 + picker.MOST_USED - 1), used.items[0]);
    try testing.expectEqual(@as(u32, 10), used.items[picker.MOST_USED - 1]);
}

test "the ones used last: written and read back, a stranger passed by" {
    var entries: [4]picker.Entry = undefined;
    const made = book(&entries);
    var used: picker.Used = .{ .tone = 2 };
    _ = used.use(0);
    _ = used.use(2);
    var file: [picker.USED_ROOM]u8 = undefined;
    const length = used.write(&made, &file);
    try testing.expectEqualStrings("emoji-used 1 3\n\u{1F44B}\n\u{1F600}\n", file[0..length]);

    var back: picker.Used = .{};
    try testing.expect(back.read(&made, file[0..length]));
    try testing.expectEqual(@as(?u32, 2), back.tone);
    try testing.expectEqualSlices(u32, &.{ 2, 0 }, back.items[0..back.count]);

    try testing.expect(back.read(&made, "emoji-used 1 0\n\u{1F680}\n\u{2764}\u{FE0F}\n\n\u{2764}\u{FE0F}\n"));
    try testing.expectEqual(@as(?u32, null), back.tone);
    try testing.expectEqualSlices(u32, &.{1}, back.items[0..back.count]);

    // Not the file, another form, a tone there is none of: left as it was.
    try testing.expect(!back.read(&made, "emoji-list 1 0 0\n"));
    try testing.expect(!back.read(&made, "emoji-used 2 0\n"));
    try testing.expect(!back.read(&made, "emoji-used 1 6\n"));
    try testing.expect(!back.read(&made, ""));
    try testing.expectEqual(@as(u32, 1), back.count);
    // No room for the first line: nothing written.
    try testing.expectEqual(@as(usize, 0), used.write(&made, file[0..10]));
}

test "the grid: columns and rows of a box, the cell at a place and a cell's place" {
    const grid = picker.Grid.init(370, 100, 36);
    try testing.expectEqual(@as(u32, 10), grid.columns);
    try testing.expectEqual(@as(u32, 2), grid.rows);
    try testing.expectEqual(@as(u32, 3), grid.drawn);
    try testing.expectEqual(@as(u32, 5), grid.lines(41));
    try testing.expectEqual(@as(u32, 3), grid.lastTop(41));
    try testing.expectEqual(@as(u32, 0), grid.lastTop(12));

    try testing.expectEqual(@as(?u32, 0), grid.at(0, 0, 0, 41));
    try testing.expectEqual(@as(?u32, 11), grid.at(36, 36, 0, 41));
    try testing.expectEqual(@as(?u32, 31), grid.at(71, 35, 3, 41));
    // Past the last cell, beside the columns, above the box.
    try testing.expectEqual(@as(?u32, null), grid.at(40, 40, 3, 41));
    try testing.expectEqual(@as(?u32, null), grid.at(365, 0, 0, 41));
    try testing.expectEqual(@as(?u32, null), grid.at(-1, 0, 0, 41));

    try testing.expectEqual(picker.Place{ .x = 36, .y = 36 }, grid.place(11, 0).?);
    try testing.expectEqual(picker.Place{ .x = 0, .y = 72 }, grid.place(40, 2).?);
    try testing.expectEqual(@as(?picker.Place, null), grid.place(0, 1));
    try testing.expectEqual(@as(?picker.Place, null), grid.place(40, 1));

    // A box smaller than a cell still has one.
    const small = picker.Grid.init(10, 10, 36);
    try testing.expectEqual(@as(u32, 1), small.columns);
    try testing.expectEqual(@as(u32, 1), small.rows);
}
