// SPDX-License-Identifier: MIT
//! What the tests of built tables shape with: the library's shaping on
//! the host's memory, a run of glyphs or a text in and the shaped run
//! out.
//!
//! `shape` and `shapeText` take tables as bytes, so a test needs no font
//! file around them. Every block the shaping takes comes from the tests'
//! allocator, which fails a test that leaves one behind, and a test may
//! say after how many blocks there is no more memory.
//!
//! A font at a place on its axes has its store of deltas read by
//! truetype.library's reader of one (`deltaAt`), the code an outline
//! answers `VariationDelta` with, at the coordinates the test names.
//!
//! A text's font has a glyph for every character up to U+FFFF, of the
//! character's own number, so a test's tables name the letter "f" as
//! the glyph 'f'. What else the font has - other glyphs, glyphs for a
//! character with a selector, a `kern` table's pairs, advances - the
//! test lists.

const std = @import("std");
const sdk = @import("sdk");
const tts = sdk.truetypeshaping;
const _shape = @import("../shape/_shape.zig");
const _buffer = @import("../shape/_buffer.zig");
const _text = @import("../shape/_text.zig");
const _normal = @import("../shape/_normal.zig");
const variation = @import("../../truetype/outline/_variation.zig");

const testing = std.testing;

pub const test_feature = [_]tts.Feature{.{ .tag = tts.featureTag("test") }};

/// A font's tables; of no length where it has none.
pub const Tables = struct {
    gdef: []const u8 = &.{},
    gsub: []const u8 = &.{},
    gpos: []const u8 = &.{},
};

pub const Options = struct {
    script: u32 = tts.TTS_SCRIPT_DEFAULT,
    language: u32 = tts.TTS_LANGUAGE_DEFAULT,
    backward: bool = false,
    features: []const tts.Feature = &test_feature,
    /// A variable font's place: a coordinate an axis. None at its
    /// default.
    coords: []const i16 = &.{},
    /// Every glyph's advance.
    advance: i32 = 1000,
    /// The glyphs' clusters; their places in the run when null.
    clusters: ?[]const u32 = null,
    /// How many blocks the shaping gets before there is no more memory.
    blocks: ?u32 = null,
};

/// How many glyphs a shaped run of the tests may have.
pub const room = 256;

pub const Run = struct {
    glyphs: [room]tts.ShapedGlyph = undefined,
    count: u32 = 0,
    result: i32 = tts.TTS_OK,

    pub fn expectGlyphs(run: *const Run, expected: []const u32) !void {
        var found: [room]u32 = undefined;
        for (run.glyphs[0..run.count], 0..) |glyph, index| found[index] = glyph.glyph;
        try testing.expectEqualSlices(u32, expected, found[0..run.count]);
    }

    pub fn expectClusters(run: *const Run, expected: []const u32) !void {
        var found: [room]u32 = undefined;
        for (run.glyphs[0..run.count], 0..) |glyph, index| found[index] = glyph.cluster;
        try testing.expectEqualSlices(u32, expected, found[0..run.count]);
    }

    pub fn expectAdvances(run: *const Run, expected: []const i32) !void {
        var found: [room]i32 = undefined;
        for (run.glyphs[0..run.count], 0..) |glyph, index| found[index] = glyph.advance;
        try testing.expectEqualSlices(i32, expected, found[0..run.count]);
    }

    /// Each glyph's offsets, to the right and up.
    pub fn expectOffsets(run: *const Run, expected: []const [2]i32) !void {
        try testing.expectEqual(expected.len, @as(usize, run.count));
        for (run.glyphs[0..run.count], expected) |glyph, offsets| {
            try testing.expectEqual(offsets[0], glyph.x_offset);
            try testing.expectEqual(offsets[1], glyph.y_offset);
        }
    }
};

/// The memory a call gets: the tests' allocator, counted.
const Lender = struct {
    left: ?u32,
};

/// A block's length is kept in the 16 bytes before it.
const header = 16;

fn allocate(context: *anyopaque, bytes: usize) ?[*]u8 {
    const lender: *Lender = @ptrCast(@alignCast(context));
    if (lender.left) |*left| {
        if (left.* == 0) return null;
        left.* -= 1;
    }
    const block = testing.allocator.alignedAlloc(u8, .@"16", bytes + header) catch return null;
    const length: *usize = @ptrCast(block.ptr);
    length.* = block.len;
    return block.ptr + header;
}

fn release(context: *anyopaque, block: [*]u8) void {
    _ = context;
    const start: [*]align(16) u8 = @alignCast(block - header);
    const length: *usize = @ptrCast(start);
    testing.allocator.free(start[0..length.*]);
}

/// The font `shape` shapes with: every glyph's advance, and its place.
const Face = struct {
    advance: i32,
    coords: []const i16,
};

fn advanceOf(context: *anyopaque, glyph: u32) i32 {
    _ = glyph;
    const face: *const Face = @ptrCast(@alignCast(context));
    return face.advance;
}

fn faceDeltaOf(context: *anyopaque, store: []const u8, item: u32, regions: *u32) i32 {
    const face: *const Face = @ptrCast(@alignCast(context));
    return variation.wholeDelta(store, face.coords, item, regions);
}

/// A font's reader of a store of deltas for a test that asks one by
/// itself: `context` is the place, a `[]const i16` of a coordinate an
/// axis.
pub fn deltaAt(context: *anyopaque, store: []const u8, item: u32, regions: *u32) i32 {
    const coords: *const []const i16 = @ptrCast(@alignCast(context));
    return variation.wholeDelta(store, coords.*, item, regions);
}

/// Shapes `glyphs` with `tables`. A shaped run of more glyphs than the
/// tests' room answers `TTSERR_ROOM` with its count alone.
pub fn shape(tables: Tables, glyphs: []const u16, options: Options) Run {
    var run: Run = .{};
    var lender: Lender = .{ .left = options.blocks };
    var face: Face = .{ .advance = options.advance, .coords = options.coords };
    const memory: _buffer.Memory = .{ .context = &lender, .allocFn = allocate, .freeFn = release };
    const font: _shape.Font = .{
        .gdef = .{ .bytes = tables.gdef },
        .gsub = .{ .bytes = tables.gsub },
        .gpos = .{ .bytes = tables.gpos },
        .coords = options.coords,
        .context = &face,
        .advanceFn = advanceOf,
        .deltaFn = faceDeltaOf,
    };
    var buffer = _buffer.Buffer.init(memory, @intCast(glyphs.len)) orelse {
        run.result = tts.TTSERR_NOMEM;
        return run;
    };
    defer buffer.deinit();
    for (glyphs, 0..) |glyph, index| {
        const cluster: u32 = if (options.clusters) |clusters| clusters[index] else @intCast(index);
        buffer.append(.{ .glyph = glyph, .cluster = cluster, .mask = 0 });
    }
    const order: _shape.Order = .{
        .memory = memory,
        .font = font,
        .script = options.script,
        .language = options.language,
        .backward = options.backward,
        .features = options.features,
    };
    run.result = _shape.shape(&order, &buffer);
    if (run.result != tts.TTS_OK) return run;
    run.count = buffer.len;
    if (buffer.len > room) {
        run.result = tts.TTSERR_ROOM;
        return run;
    }
    for (buffer.slice(), 0..) |item, index| {
        run.glyphs[index] = .{
            .glyph = item.glyph,
            .cluster = item.cluster,
            .advance = item.advance,
            .x_offset = item.x_offset,
            .y_offset = item.y_offset,
        };
    }
    return run;
}

pub const TextOptions = struct {
    language: u32 = tts.TTS_LANGUAGE_DEFAULT,
    backward: bool = false,
    features: []const tts.Feature = &.{},
    /// Every glyph's advance, but for those of `advances`.
    advance: i32 = 1000,
    /// `.{ glyph, advance }`.
    advances: []const [2]i32 = &.{},
    /// Each glyph has an advance by its number instead: 400 and ten
    /// times what the number leaves over 37.
    varied: bool = false,
    /// Characters whose glyph is not their own number: `.{ character,
    /// glyph }`, the glyph 0 for a character the font lacks. Every
    /// other character up to U+FFFF has a glyph.
    glyphs: []const [2]u32 = &.{},
    /// How many units an em has.
    em: u32 = 1000,
    /// A variable font's place: a coordinate an axis. Empty at the
    /// default.
    coords: []const i16 = &.{},
    /// A character and a selector the font has a glyph for:
    /// `.{ character, selector, glyph }`.
    variants: []const [3]u32 = &.{},
    /// The `kern` table's pairs: `.{ left, right, value }`.
    kerning: []const [3]i32 = &.{},
    /// The boxes of glyphs' outlines: `.{ glyph, x_min, y_min, x_max,
    /// y_max }`. Empty for a font that says none.
    boxes: []const [5]i32 = &.{},
    /// How many blocks the shaping gets before there is no more memory.
    blocks: ?u32 = null,
    /// How many glyphs the answer has room for.
    room: u32 = room,
};

fn textAdvanceOf(context: *anyopaque, glyph: u32) i32 {
    const options: *const TextOptions = @ptrCast(@alignCast(context));
    if (options.varied) return @intCast(400 + glyph % 37 * 10);
    for (options.advances) |entry| {
        if (entry[0] == glyph) return entry[1];
    }
    return options.advance;
}

fn textGlyphOf(context: *anyopaque, char: u32) u32 {
    const options: *const TextOptions = @ptrCast(@alignCast(context));
    for (options.glyphs) |entry| {
        if (entry[0] == char) return entry[1];
    }
    return if (char <= 0xFFFF) char else 0;
}

fn textEmOf(context: *anyopaque) u32 {
    const options: *const TextOptions = @ptrCast(@alignCast(context));
    return options.em;
}

fn textVariantOf(context: *anyopaque, char: u32, selector: u32) u32 {
    const options: *const TextOptions = @ptrCast(@alignCast(context));
    for (options.variants) |entry| {
        if (entry[0] == char and entry[1] == selector) return entry[2];
    }
    return 0;
}

fn textDeltaOf(context: *anyopaque, store: []const u8, item: u32, regions: *u32) i32 {
    const options: *const TextOptions = @ptrCast(@alignCast(context));
    return variation.wholeDelta(store, options.coords, item, regions);
}

fn textBoxOf(context: *anyopaque, glyph: u32, box: *_shape.Box) bool {
    const options: *const TextOptions = @ptrCast(@alignCast(context));
    for (options.boxes) |entry| {
        if (entry[0] != glyph) continue;
        box.* = .{ .x_min = entry[1], .y_min = entry[2], .x_max = entry[3], .y_max = entry[4] };
        return true;
    }
    return false;
}

fn textKerningOf(context: *anyopaque, left: u32, right: u32) i32 {
    const options: *const TextOptions = @ptrCast(@alignCast(context));
    for (options.kerning) |entry| {
        if (entry[0] == left and entry[1] == right) return entry[2];
    }
    return 0;
}

/// Shapes `text` with `tables`. `count` is what the call left there,
/// having started at 0xDEAD.
pub fn shapeText(tables: Tables, text: []const u8, options: TextOptions) Run {
    var run: Run = .{};
    var lender: Lender = .{ .left = options.blocks };
    var font_options = options;
    const request: _text.Text = .{
        .memory = .{ .context = &lender, .allocFn = allocate, .freeFn = release },
        .font = .{
            .gdef = .{ .bytes = tables.gdef },
            .gsub = .{ .bytes = tables.gsub },
            .gpos = .{ .bytes = tables.gpos },
            .coords = options.coords,
            .context = &font_options,
            .advanceFn = textAdvanceOf,
            .kerningFn = textKerningOf,
            .glyphFn = textGlyphOf,
            .boxFn = if (options.boxes.len != 0) textBoxOf else null,
            .variantFn = textVariantOf,
            .emFn = textEmOf,
            .deltaFn = textDeltaOf,
        },
        .bytes = text,
        .backward = options.backward,
        .language = options.language,
        .features = options.features,
    };
    var shaped: tts.ShapedRun = .{ .glyphs = &run.glyphs, .room = options.room, .count = 0xDEAD };
    run.result = _text.shapeText(&request, &shaped);
    run.count = shaped.count;
    return run;
}

fn glyphUnlessLacking(context: *anyopaque, char: u32) u32 {
    const lacking: *const []const u32 = @ptrCast(@alignCast(context));
    var low: usize = 0;
    var high: usize = lacking.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (lacking.*[middle] == char) return 0;
        if (lacking.*[middle] < char) low = middle + 1 else high = middle;
    }
    return char;
}

fn noAdvance(context: *anyopaque, glyph: u32) i32 {
    _ = context;
    _ = glyph;
    return 0;
}

/// The characters a font draws `text` with, the whole of it one
/// stretch: what its shaping starts from (`_normal.zig`). The font has
/// a glyph for every character there is but for those of `lacking`,
/// which is sorted. The characters are written to `found`, as many as
/// it holds, and their number is answered.
pub fn charactersOf(text: []const u8, lacking: []const u32, found: []u32) !usize {
    var lender: Lender = .{ .left = null };
    var sorted = lacking;
    const font: _shape.Font = .{ .context = @ptrCast(&sorted), .advanceFn = noAdvance, .glyphFn = glyphUnlessLacking };
    var chars: u32 = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) chars += 1;
    }
    var list = _normal.List.init(.{ .context = &lender, .allocFn = allocate, .freeFn = release }, &font, chars) orelse
        return error.OutOfMemory;
    defer list.deinit();
    list.fill(text, 0, text.len);
    if (list.failed) return error.OutOfMemory;
    for (list.slice(), 0..) |entry, index| {
        if (index < found.len) found[index] = entry.char;
    }
    return list.len;
}
