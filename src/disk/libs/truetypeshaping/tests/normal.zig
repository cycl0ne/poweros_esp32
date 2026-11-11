// SPDX-License-Identifier: MIT
//! Host tests of a stretch made the characters a font draws it with
//! (`_normal.zig`), against the test the Unicode Character Database has
//! for its normalization forms.
//!
//! `NormalizationTest.txt` has a line for every character that is
//! written in more than one way, and for sequences of marks: the text,
//! the text put together, and the text taken apart and its marks in
//! order. Two fonts stand at the two ends of what a font has. One lacks
//! every character with parts, so the shaping takes every text apart;
//! the other has a glyph for every character there is, so a text taken
//! apart is put together as far as Unicode puts it together. A line's
//! columns say what both come to.
//!
//! Two kinds of lines are left out, each for what the shaping does
//! otherwise on purpose. One with a mark sorted by another number than
//! its combining class (`orderOf`): some 330 of the file's 20000, most
//! of them a mark of Hebrew, Arabic or Tibetan among others, which the
//! texts HarfBuzz shaped (`text_made.zig`) have instead. And for the
//! font that has every character, one where Unicode puts two letters
//! together - Hangul's single letters, Kirat Rai's vowel signs - which
//! is a script's model to do and not the marks' rule.
//!
//! The file is fetched by `scripts/fetch-unicode.sh`; the tests are
//! skipped where it is not there.

const std = @import("std");
const test_options = @import("test_options");
const harness = @import("harness.zig");
const _normal = @import("../shape/_normal.zig");

const testing = std.testing;

/// The most characters a column of the file has, with room to spare.
const widest = 64;

const Column = struct {
    chars: [widest]u32 = undefined,
    len: usize = 0,

    fn slice(column: *const Column) []const u32 {
        return column.chars[0..column.len];
    }

    /// The column as UTF-8, written to `bytes`.
    fn text(column: *const Column, bytes: *[widest * 4]u8) ![]const u8 {
        var length: usize = 0;
        for (column.slice()) |char| {
            length += try std.unicode.utf8Encode(@intCast(char), bytes[length..]);
        }
        return bytes[0..length];
    }
};

/// A line of the file: the text; the text put together; taken apart;
/// and the same two of the text with every character of a wider meaning
/// replaced.
const Line = struct {
    part: u32,
    columns: [5]Column,

    /// Whether one of its characters is sorted by another number than
    /// its combining class.
    fn sortedOtherwise(line: *const Line) bool {
        for ([_]usize{ 2, 4 }) |index| {
            for (line.columns[index].slice()) |char| {
                if (_normal.orderOf(char) != _normal.combiningOf(char)) return true;
            }
        }
        return false;
    }

    /// Whether it has letters Unicode puts together: Hangul's single
    /// letters, Kirat Rai's vowel signs.
    fn joinsLetters(line: *const Line) bool {
        for (line.columns[2].slice()) |char| {
            if (char >= 0x1100 and char <= 0x11FF) return true;
            if (char >= 0x16D63 and char <= 0x16D6A) return true;
        }
        return false;
    }
};

/// The file's lines, one after another.
const Lines = struct {
    rest: []const u8,
    part: u32 = 0,

    fn next(lines: *Lines) !?Line {
        while (lines.rest.len != 0) {
            const end = std.mem.indexOfScalar(u8, lines.rest, '\n') orelse lines.rest.len;
            var row = lines.rest[0..end];
            lines.rest = lines.rest[@min(end + 1, lines.rest.len)..];
            if (std.mem.indexOfScalar(u8, row, '#')) |comment| row = row[0..comment];
            row = std.mem.trim(u8, row, " \t\r");
            if (row.len == 0) continue;
            if (std.mem.startsWith(u8, row, "@Part")) {
                lines.part = try std.fmt.parseInt(u32, row[5..], 10);
                continue;
            }
            var line: Line = .{ .part = lines.part, .columns = @splat(.{}) };
            var fields = std.mem.splitScalar(u8, row, ';');
            for (&line.columns) |*column| {
                const field = fields.next() orelse return error.LineHasTooFewColumns;
                var numbers = std.mem.tokenizeScalar(u8, field, ' ');
                while (numbers.next()) |number| {
                    column.chars[column.len] = try std.fmt.parseInt(u32, number, 16);
                    column.len += 1;
                }
            }
            return line;
        }
        return null;
    }
};

/// The file's bytes, for the caller to free with the testing allocator.
/// `error.SkipZigTest` where the file is not fetched.
fn read() ![]u8 {
    if (test_options.unicode_dir.len == 0) return error.SkipZigTest;
    var path_buffer: [1024]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/NormalizationTest.txt", .{test_options.unicode_dir});
    return std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(64 << 20)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
}

/// Every character Unicode takes apart, in rising order: the file's
/// second part has a line for each. For the caller to free.
fn takenApart(bytes: []const u8) ![]u32 {
    var chars: std.ArrayList(u32) = .empty;
    errdefer chars.deinit(testing.allocator);
    var lines: Lines = .{ .rest = bytes };
    while (try lines.next()) |line| {
        if (line.part != 1) continue;
        const char = line.columns[0].chars[0];
        if (line.columns[2].len == 1 and line.columns[2].chars[0] == char) continue;
        if (chars.items.len != 0) try testing.expect(chars.items[chars.items.len - 1] < char);
        try chars.append(testing.allocator, char);
    }
    return chars.toOwnedSlice(testing.allocator);
}

/// What came of a file: how many texts were made characters, how many
/// lines were left out, and how many texts came out otherwise.
const Tally = struct {
    texts: u32 = 0,
    left_out: u32 = 0,
    differing: u32 = 0,

    /// Makes `from` the characters a font lacking `lacking` draws it
    /// with, and holds them against `expected`. The first few that
    /// differ are printed.
    fn hold(tally: *Tally, from: *const Column, lacking: []const u32, expected: *const Column) !void {
        var bytes: [widest * 4]u8 = undefined;
        var found: [widest]u32 = undefined;
        const count = try harness.charactersOf(try from.text(&bytes), lacking, &found);
        tally.texts += 1;
        if (count <= found.len and std.mem.eql(u32, found[0..count], expected.slice())) return;
        tally.differing += 1;
        if (tally.differing > 8) return;
        std.debug.print("\n", .{});
        for (from.slice()) |char| std.debug.print(" {X:0>4}", .{char});
        std.debug.print(" is made\n", .{});
        for (found[0..@min(count, found.len)]) |char| std.debug.print(" {X:0>4}", .{char});
        std.debug.print(" and not\n", .{});
        for (expected.slice()) |char| std.debug.print(" {X:0>4}", .{char});
        std.debug.print("\n", .{});
    }
};

test "a font that lacks every character with parts draws a text taken apart, its marks in order" {
    const bytes = try read();
    defer testing.allocator.free(bytes);
    const lacking = try takenApart(bytes);
    defer testing.allocator.free(lacking);
    // The letters with marks, the letters of other scripts with theirs,
    // and Hangul's 11172 syllables.
    try testing.expect(lacking.len > 13000);

    var tally: Tally = .{};
    var lines: Lines = .{ .rest = bytes };
    while (try lines.next()) |line| {
        if (line.sortedOtherwise()) {
            tally.left_out += 1;
            continue;
        }
        // The text, put together or taken apart, comes to the same.
        for (line.columns[0..3]) |*column| try tally.hold(column, lacking, &line.columns[2]);
        for (line.columns[3..5]) |*column| try tally.hold(column, lacking, &line.columns[4]);
    }
    try testing.expectEqual(@as(u32, 0), tally.differing);
    try testing.expect(tally.texts > 90000);
    try testing.expect(tally.left_out < 400);
}

test "a font that has every character draws a text taken apart put together" {
    const bytes = try read();
    defer testing.allocator.free(bytes);

    var tally: Tally = .{};
    var lines: Lines = .{ .rest = bytes };
    while (try lines.next()) |line| {
        if (line.sortedOtherwise() or line.joinsLetters()) {
            tally.left_out += 1;
            continue;
        }
        try tally.hold(&line.columns[2], &.{}, &line.columns[1]);
    }
    try testing.expectEqual(@as(u32, 0), tally.differing);
    try testing.expect(tally.texts > 7000);
}

test "a character without a mark behind it is the font's own glyph, whatever it has parts of" {
    var found: [8]u32 = undefined;
    // A font that has the character draws it.
    var count = try harness.charactersOf("\u{1EAD}", &.{}, &found);
    try testing.expectEqualSlices(u32, &.{0x1EAD}, found[0..count]);
    // One that lacks it takes one step apart where it has the two.
    count = try harness.charactersOf("\u{1EAD}", &.{0x1EAD}, &found);
    try testing.expectEqualSlices(u32, &.{ 0x1EA1, 0x302 }, found[0..count]);
    // And all of them where it does not.
    count = try harness.charactersOf("\u{1EAD}", &.{ 0xE2, 0x1EA1, 0x1EAD }, &found);
    try testing.expectEqualSlices(u32, &.{ 'a', 0x323, 0x302 }, found[0..count]);
    // A font without the mark draws the character as nothing.
    count = try harness.charactersOf("\u{E9}", &.{ 0xE9, 0x301 }, &found);
    try testing.expectEqualSlices(u32, &.{0xE9}, found[0..count]);
}
