// SPDX-License-Identifier: MIT
//! What the tests of built tables shape with: the library's shaping on
//! the host's memory, a run of glyphs in and the shaped run out.
//!
//! `shape` takes tables as bytes, so a test needs no font file around
//! them. Every block the shaping takes comes from the tests' allocator,
//! which fails a test that leaves one behind, and a test may say after
//! how many blocks there is no more memory.

const std = @import("std");
const sdk = @import("sdk");
const tts = sdk.truetypeshaping;
const _shape = @import("../shape/_shape.zig");
const _buffer = @import("../shape/_buffer.zig");

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

fn advanceOf(context: *anyopaque, glyph: u32) i32 {
    _ = glyph;
    const advance: *const i32 = @ptrCast(@alignCast(context));
    return advance.*;
}

/// Shapes `glyphs` with `tables`. A shaped run of more glyphs than the
/// tests' room answers `TTSERR_ROOM` with its count alone.
pub fn shape(tables: Tables, glyphs: []const u16, options: Options) Run {
    var run: Run = .{};
    var lender: Lender = .{ .left = options.blocks };
    var advance = options.advance;
    const memory: _buffer.Memory = .{ .context = &lender, .allocFn = allocate, .freeFn = release };
    const font: _shape.Font = .{
        .gdef = .{ .bytes = tables.gdef },
        .gsub = .{ .bytes = tables.gsub },
        .gpos = .{ .bytes = tables.gpos },
        .context = &advance,
        .advanceFn = advanceOf,
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
    run.result = _shape.shape(memory, font, options.script, options.language, options.backward, options.features, &buffer);
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
