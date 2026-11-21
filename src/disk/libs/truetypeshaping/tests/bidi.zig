// SPDX-License-Identifier: MIT
//! Host tests of the bidirectional algorithm: the levels of texts of
//! both directions, lines of Unicode's own test of it, the mirrored
//! characters and the classes.

const std = @import("std");
const utf8 = @import("sdk").utility.utf8;
const _bidi = @import("../bidi/_bidi.zig");
const _table = @import("../bidi/_bidi_table.zig");
const Memory = @import("../shape/_buffer.zig").Memory;
const Base = _bidi.Base;

const testing = std.testing;

/// A block's length is kept in the 16 bytes before it.
const header = 16;

fn allocate(_: *anyopaque, bytes: usize) ?[*]u8 {
    const block = testing.allocator.alignedAlloc(u8, .@"16", bytes + header) catch return null;
    const length: *usize = @ptrCast(block.ptr);
    length.* = block.len;
    return block.ptr + header;
}

fn release(_: *anyopaque, block: [*]u8) void {
    const start: [*]align(16) u8 = @alignCast(block - header);
    const length: *usize = @ptrCast(start);
    testing.allocator.free(start[0..length.*]);
}

var context: u8 = 0;

fn memory() Memory {
    return .{ .context = &context, .allocFn = allocate, .freeFn = release };
}

/// The levels of the characters of `text`, one each, as `resolve` gives
/// them to their bytes.
fn levelsOf(text: []const u8, base: Base, out: []u8) ![]u8 {
    var bytes: [256]u8 = undefined;
    try testing.expect(_bidi.resolve(memory(), text, base, bytes[0..text.len]));
    var count: usize = 0;
    var at: usize = 0;
    while (at < text.len) : (count += 1) {
        out[count] = bytes[at];
        at += utf8.read(text[at..]).length;
    }
    return out[0..count];
}

test "the levels of a text of both directions" {
    var out: [64]u8 = undefined;
    // Latin with a Hebrew word in it, read from left to right.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1, 1, 0, 0 }, try levelsOf("ab\u{05D0}\u{05D1}cd", .left_to_right, &out));
    // Arabic with a number: the number one level up.
    try testing.expectEqualSlices(u8, &.{ 1, 1, 2, 2, 1 }, try levelsOf("\u{0627}\u{0628}12\u{0629}", .first_strong, &out));
    // Latin in a text read from right to left.
    try testing.expectEqualSlices(u8, &.{ 1, 2, 2, 1 }, try levelsOf("\u{05D0}ab\u{05D1}", .right_to_left, &out));
    // An override reads Latin from right to left.
    try testing.expectEqualSlices(u8, &.{ 0, 1, 1, 0 }, try levelsOf("\u{202E}ab\u{202C}", .left_to_right, &out));
    // White space at the end is at the paragraph's level.
    try testing.expectEqualSlices(u8, &.{ 1, 1, 0 }, try levelsOf("\u{05D0}\u{05D1} ", .left_to_right, &out));
    // Each paragraph by its own first letter.
    try testing.expectEqualSlices(u8, &.{ 1, 1, 0 }, try levelsOf("\u{05D0}\u{2029}a", .first_strong, &out));
    // Nothing to resolve.
    try testing.expect(_bidi.resolve(memory(), "", .left_to_right, &out));
}

test "lines of Unicode's own test of the algorithm" {
    // From BidiCharacterTest.txt: the text, the paragraph's direction,
    // and the levels.
    const Case = struct { text: []const u8, base: Base, levels: []const u8 };
    const cases = [_]Case{
        // 05D0 05D1 0028 05D2 05D3 005B 0026 0065 0066 005D 002E 0029 0067 0068;0
        .{ .text = "\u{05D0}\u{05D1}(\u{05D2}\u{05D3}[&ef].)gh", .base = .left_to_right, .levels = &.{ 1, 1, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
        // the same;1
        .{ .text = "\u{05D0}\u{05D1}(\u{05D2}\u{05D3}[&ef].)gh", .base = .right_to_left, .levels = &.{ 1, 1, 1, 1, 1, 1, 1, 2, 2, 1, 1, 1, 2, 2 } },
        // 0061 0062 0063 0020 0028 0064 0065 0066 0020 0627 0628 062C 0029 0020 05D0 05D1 05D2;0
        .{ .text = "abc (def \u{0627}\u{0628}\u{062C}) \u{05D0}\u{05D1}\u{05D2}", .base = .left_to_right, .levels = &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1 } },
    };
    var out: [64]u8 = undefined;
    for (cases) |case| try testing.expectEqualSlices(u8, case.levels, try levelsOf(case.text, case.base, &out));
}

test "the mirrored characters, and the class of a character" {
    try testing.expectEqual(@as(?u32, ')'), _bidi.mirrorOf('('));
    try testing.expectEqual(@as(?u32, '<'), _bidi.mirrorOf('>'));
    try testing.expectEqual(@as(?u32, null), _bidi.mirrorOf('a'));
    try testing.expectEqual(_table.AL, _bidi.classOf(0x0627));
    try testing.expectEqual(_table.R, _bidi.classOf(0x05D0));
    try testing.expectEqual(_table.EN, _bidi.classOf('7'));
    try testing.expectEqual(_table.L, _bidi.classOf('x'));
    try testing.expectEqual(_table.AL, _bidi.classOf(0x08A0));
}
