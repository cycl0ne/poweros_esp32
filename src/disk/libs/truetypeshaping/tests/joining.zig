// SPDX-License-Identifier: MIT
//! Host tests of the joining model: the form each letter of a script
//! whose letters join takes, and the goes its features are applied in.

const std = @import("std");
const tts = @import("sdk").truetypeshaping;
const _joining = @import("../shape/_joining.zig");
const _buffer = @import("../shape/_buffer.zig");
const Wanted = @import("../shape/_plan.zig").Wanted;
const _shape = @import("../shape/_shape.zig");
const harness = @import("harness.zig");
const featureTag = tts.featureTag;

const testing = std.testing;

fn formsOf(comptime chars: []const u32) [chars.len]u8 {
    var items: [chars.len]_buffer.Item = undefined;
    for (&items) |*item| item.* = .{ .glyph = 0, .cluster = 0, .mask = 0 };
    var state: _joining.State = .{};
    for (chars, 0..) |char, index| state.next(char, &items, index);
    var result: [chars.len]u8 = undefined;
    for (&result, items) |*form, item| form.* = item.forms;
    return result;
}

test "the forms of a word: a letter at its start, in its middle, at its end, and alone" {
    // Beh, beh, beh: init, medi, fina.
    try testing.expectEqual([3]u8{ _joining.FORM_INIT, _joining.FORM_MEDI, _joining.FORM_FINA }, formsOf(&.{ 0x0628, 0x0628, 0x0628 }));
    // Alef joins only the one before it: the beh after it starts anew.
    try testing.expectEqual([3]u8{ _joining.FORM_ISOL, _joining.FORM_INIT, _joining.FORM_FINA }, formsOf(&.{ 0x0627, 0x0628, 0x0628 }));
    // A mark between two letters is passed over, and has no form.
    try testing.expectEqual([3]u8{ _joining.FORM_INIT, 0, _joining.FORM_FINA }, formsOf(&.{ 0x0628, 0x064B, 0x0628 }));
    // A space joins none; a zero width non-joiner keeps the two apart,
    // and a zero width joiner makes a letter take its joined form.
    try testing.expectEqual([3]u8{ _joining.FORM_ISOL, 0, _joining.FORM_ISOL }, formsOf(&.{ 0x0628, 0x0020, 0x0628 }));
    try testing.expectEqual([3]u8{ _joining.FORM_ISOL, 0, _joining.FORM_ISOL }, formsOf(&.{ 0x0628, 0x200C, 0x0628 }));
    try testing.expectEqual([2]u8{ _joining.FORM_INIT, _joining.FORM_FINA }, formsOf(&.{ 0x0628, 0x200D }));
    // Latin joins none.
    try testing.expectEqual([2]u8{ 0, 0 }, formsOf(&.{ 0x0041, 0x0042 }));
}

test "Syriac's Alaph: its own forms by what stands before it" {
    // Beth then Alaph: the Alaph ends the join.
    try testing.expectEqual([2]u8{ _joining.FORM_INIT, _joining.FORM_FINA }, formsOf(&.{ 0x0712, 0x0710 }));
    // Dalath then Alaph: fin3.
    try testing.expectEqual([2]u8{ _joining.FORM_ISOL, _joining.FORM_FIN3 }, formsOf(&.{ 0x0715, 0x0710 }));
    // Alaph after a letter that joins none on its side: fin2.
    try testing.expectEqual([2]u8{ _joining.FORM_ISOL, _joining.FORM_FIN2 }, formsOf(&.{ 0x0718, 0x0710 }));
}

test "the goes: a form before the ligatures, each form a go of its own" {
    var wanted = [_]Wanted{
        .{ .tag = featureTag("liga"), .mask = 1, .value = 1 },
        .{ .tag = featureTag("init"), .mask = 1, .value = 1 },
        .{ .tag = featureTag("isol"), .mask = 1, .value = 1 },
        .{ .tag = featureTag("rlig"), .mask = 1, .value = 1 },
        .{ .tag = featureTag("ccmp"), .mask = 1, .value = 1 },
        .{ .tag = featureTag("init"), .mask = 4, .value = 1 },
    };
    _joining.plan(&wanted, 5, featureTag("arab"));
    _joining.inGoes(&wanted);
    try testing.expectEqual(featureTag("ccmp"), wanted[0].tag);
    try testing.expectEqual(featureTag("isol"), wanted[1].tag);
    try testing.expectEqual(_joining.FORM_ISOL, wanted[1].forms);
    try testing.expectEqual(@as(u32, 0), wanted[1].mask);
    try testing.expectEqual(featureTag("init"), wanted[2].tag);
    // The caller's own keeps the part of the text it was asked for.
    try testing.expectEqual(@as(u32, 4), wanted[3].mask);
    try testing.expectEqual(featureTag("rlig"), wanted[4].tag);
    try testing.expectEqual(featureTag("liga"), wanted[5].tag);
}

/// The widths of the glyphs of the stretch tests: the pieces 1 to 3,
/// a letter 4.
fn widthOf(context: *anyopaque, glyph: u32) i32 {
    _ = context;
    return switch (glyph) {
        1 => 100,
        2 => 50,
        3 => 100,
        else => 300,
    };
}

/// A run of a stretch's three pieces - glyphs 1, 2, 3, the middle one
/// repeated - and `letters` letters of 300 behind it, as the go of
/// `stch` leaves it: the pieces made of one glyph.
fn stretchRun(buffer: *_buffer.Buffer, letters: u32) void {
    for (0..3) |place| buffer.append(.{ .glyph = @intCast(place + 1), .cluster = 0, .mask = 0, .advance = 100, .part = @intCast(place), .flags = _buffer.ITEM_MULTIPLIED | _buffer.ITEM_SUBSTITUTED });
    for (0..letters) |index| buffer.append(.{ .glyph = 4, .cluster = @intCast(index + 1), .mask = 0, .advance = 300, .stretch = _joining.wordOf(0x0710) });
    buffer.append(.{ .glyph = 5, .cluster = 9, .mask = 0, .advance = 300 });
}

test "a stretch: its repeated piece fills the word behind it, and all of it is drawn over the word" {
    var lender: harness.Lender = .{ .left = null };
    var context: u8 = 0;
    const font: _shape.Font = .{ .context = &context, .advanceFn = widthOf };

    // A word of 600: 400 to fill past the two pieces drawn once, the
    // repeated one 50 wide eight times. Read from right to left, the
    // pieces go left from where the stretch is, over the word: the
    // first from -100, then the repeats, then the last.
    var buffer = _buffer.Buffer.init(lender.memory(), 8) orelse return error.OutOfMemory;
    defer buffer.deinit();
    stretchRun(&buffer, 2);
    _joining.beforeStretch(&buffer);
    for (buffer.slice()) |*item| item.stretch &= _joining.STRETCH_WORD;
    _joining.afterStretch(&buffer);
    _joining.stretch(&font, &buffer, true);
    try testing.expectEqual(@as(u32, 1 + 8 + 1 + 3), buffer.len);
    const items = buffer.slice();
    try testing.expectEqual(@as(u32, 1), items[0].glyph);
    try testing.expectEqual(@as(i32, -100), items[0].x_offset);
    for (items[1..9], 0..) |item, index| {
        try testing.expectEqual(@as(u32, 2), item.glyph);
        try testing.expectEqual(@as(i32, -150 - 50 * @as(i32, @intCast(index))), item.x_offset);
    }
    try testing.expectEqual(@as(u32, 3), items[9].glyph);
    try testing.expectEqual(@as(i32, -600), items[9].x_offset);
    for (items[0..10]) |item| try testing.expectEqual(@as(i32, 0), item.advance);
    try testing.expectEqual(@as(i32, 300), items[10].advance);

    // Read from left to right, the same to the right. A word of 620
    // leaves 420 to fill: eight repeats would leave 20 of it, so nine
    // are drawn, each after the first 3 into the one before.
    var forward = _buffer.Buffer.init(lender.memory(), 8) orelse return error.OutOfMemory;
    defer forward.deinit();
    stretchRun(&forward, 2);
    forward.items[4].advance = 320;
    _joining.afterStretch(&forward);
    _joining.stretch(&font, &forward, false);
    try testing.expectEqual(@as(u32, 1 + 9 + 1 + 3), forward.len);
    try testing.expectEqual(@as(i32, 0), forward.items[0].x_offset);
    try testing.expectEqual(@as(i32, 100), forward.items[1].x_offset);
    try testing.expectEqual(@as(i32, 150), forward.items[2].x_offset);
    try testing.expectEqual(@as(i32, 197), forward.items[3].x_offset);
    try testing.expectEqual(@as(u32, 3), forward.items[10].glyph);
    try testing.expectEqual(@as(i32, 100 + 450 - 8 * 3), forward.items[10].x_offset);

    // A word narrower than the pieces: they stand out of it on both
    // sides alike.
    var narrow = _buffer.Buffer.init(lender.memory(), 8) orelse return error.OutOfMemory;
    defer narrow.deinit();
    stretchRun(&narrow, 1);
    narrow.items[3].advance = 150;
    _joining.afterStretch(&narrow);
    _joining.stretch(&font, &narrow, false);
    try testing.expectEqual(@as(u32, 5), narrow.len);
    try testing.expectEqual(@as(i32, -50), narrow.items[0].x_offset);

    // A glyph made of another before the go is no piece.
    var before = _buffer.Buffer.init(lender.memory(), 8) orelse return error.OutOfMemory;
    defer before.deinit();
    stretchRun(&before, 2);
    _joining.beforeStretch(&before);
    _joining.afterStretch(&before);
    _joining.stretch(&font, &before, true);
    try testing.expectEqual(@as(u32, 6), before.len);
    try testing.expectEqual(@as(i32, 100), before.items[0].advance);
}
