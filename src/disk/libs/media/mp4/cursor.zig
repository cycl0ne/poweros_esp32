// SPDX-License-Identifier: MIT
//! A track's sample tables, as an MP4 keeps them, and a cursor that walks
//! them a packet ("sample") at a time.
//!
//! The tables are read where they lie in the index, big-endian, never
//! copied:
//!
//! - `stts`: runs of samples that each last as long - the decode times;
//! - `ctts`: runs of samples each shown that much after it is decoded
//!   (pictures in another order than they are decoded); none when they
//!   are shown as decoded;
//! - `stsc`: runs of chunks that each hold as many samples, by the first
//!   chunk of each run;
//! - `stsz` (or the packed `stz2`): each sample's size, or one size for
//!   them all;
//! - `stco` (or `co64`, 64 bits): where each chunk begins in the file;
//! - `stss`: the samples a decoder can start at, numbered from 1; none
//!   when each one is.
//!
//! The cursor is where the next sample is in each table: which sample,
//! which chunk and which sample of it, where it begins in the file, its
//! decode time and the runs it is in. `step` moves it on by one;
//! `moveTo` puts it at any sample, by walking the runs from the start.

const std = @import("std");
const be32 = @import("../file/_file.zig").be32;
const be64 = @import("../file/_file.zig").be64;

pub const Tables = struct {
    /// Each table's entries; empty when the track has none.
    stts: []const u8 = &.{},
    ctts: []const u8 = &.{},
    stsc: []const u8 = &.{},
    sizes: []const u8 = &.{},
    chunks: []const u8 = &.{},
    syncs: []const u8 = &.{},
    /// The one size every sample has, 0 when each has its own; the bits a
    /// size takes in `sizes` (32, or `stz2`'s 16, 8 or 4).
    fixed_size: u32 = 0,
    size_bits: u8 = 32,
    /// Chunk offsets of 64 bits (`co64`).
    wide_chunks: bool = false,
    /// Whether `stss` was there: without it every sample is a key.
    has_syncs: bool = false,
    samples: u32 = 0,
    chunk_count: u32 = 0,

    pub fn sttsCount(t: *const Tables) u32 {
        return @intCast(t.stts.len / 8);
    }

    pub fn cttsCount(t: *const Tables) u32 {
        return @intCast(t.ctts.len / 8);
    }

    pub fn stscCount(t: *const Tables) u32 {
        return @intCast(t.stsc.len / 12);
    }

    pub fn syncCount(t: *const Tables) u32 {
        return @intCast(t.syncs.len / 4);
    }

    /// Sample `n`'s size in bytes.
    pub fn sizeOf(t: *const Tables, n: u32) u32 {
        if (t.fixed_size != 0) return t.fixed_size;
        return switch (t.size_bits) {
            32 => be32(t.sizes[n * 4 ..]),
            16 => @as(u32, t.sizes[n * 2]) << 8 | t.sizes[n * 2 + 1],
            8 => t.sizes[n],
            else => if (n & 1 == 0) t.sizes[n / 2] >> 4 else t.sizes[n / 2] & 0xF,
        };
    }

    /// Where chunk `n` begins in the file.
    pub fn chunkAt(t: *const Tables, n: u32) u64 {
        return if (t.wide_chunks) be64(t.chunks[n * 8 ..]) else be32(t.chunks[n * 4 ..]);
    }

    /// The first chunk of `stsc`'s run `n`, from 0, and how many samples
    /// each of its chunks holds.
    pub fn runFirst(t: *const Tables, n: u32) u32 {
        return be32(t.stsc[n * 12 ..]) -% 1;
    }

    pub fn runSamples(t: *const Tables, n: u32) u32 {
        return be32(t.stsc[n * 12 + 4 ..]);
    }

    /// The chunk after `stsc`'s run `n` ends: the next run's first, or
    /// the end.
    fn runEnd(t: *const Tables, n: u32) u32 {
        return if (n + 1 < t.stscCount()) @min(t.runFirst(n + 1), t.chunk_count) else t.chunk_count;
    }

    /// Sync sample entry `n`, from 0.
    pub fn syncAt(t: *const Tables, n: u32) u32 {
        return be32(t.syncs[n * 4 ..]) -% 1;
    }

    /// The last sample a decoder can start at that is `n` or before it; 0
    /// when none is.
    pub fn keyAtOrBefore(t: *const Tables, n: u32) u32 {
        if (!t.has_syncs) return n;
        var low: u32 = 0;
        var high: u32 = t.syncCount();
        // The first entry past `n`; the one before it is the answer.
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (t.syncAt(middle) <= n) low = middle + 1 else high = middle;
        }
        return if (low == 0) 0 else t.syncAt(low - 1);
    }

    /// Whether the tables hang together: each one as long as it says, the
    /// chunks enough for the samples.
    pub fn sound(t: *const Tables) bool {
        if (t.samples == 0) return true;
        if (t.stts.len == 0 or t.stsc.len == 0 or t.chunk_count == 0) return false;
        if (t.fixed_size == 0) {
            const need: u64 = (@as(u64, t.samples) * t.size_bits + 7) / 8;
            if (t.sizes.len < need) return false;
        }
        var held: u64 = 0;
        for (0..t.stscCount()) |n| {
            const run: u32 = @intCast(n);
            const first = t.runFirst(run);
            const end = t.runEnd(run);
            if (first >= t.chunk_count or end < first) return false;
            held += @as(u64, end - first) * t.runSamples(run);
        }
        return held >= t.samples;
    }
};

pub const Cursor = struct {
    /// The next sample, its chunk and which of the chunk's it is, how
    /// many the chunk holds and the `stsc` run it is in, and where the
    /// sample begins in the file.
    sample: u32 = 0,
    chunk: u32 = 0,
    in_chunk: u32 = 0,
    chunk_samples: u32 = 0,
    run: u32 = 0,
    offset: u64 = 0,
    /// Its decode time in the track's ticks, and its `stts` run and how
    /// many samples are left in it after this one; the same for `ctts`.
    dts: u64 = 0,
    stts_at: u32 = 0,
    stts_left: u32 = 0,
    ctts_at: u32 = 0,
    ctts_left: u32 = 0,
    /// The first `stss` entry at or past the sample.
    sync_at: u32 = 0,
};

/// How long sample `c.sample` lasts, in ticks.
pub fn duration(t: *const Tables, c: *const Cursor) u32 {
    if (c.stts_at >= t.sttsCount()) return 0;
    return be32(t.stts[c.stts_at * 8 + 4 ..]);
}

/// How long after its decode time the sample is shown, in ticks: signed,
/// as version 1 has it and version 0 files write it.
pub fn showOffset(t: *const Tables, c: *const Cursor) i64 {
    if (c.ctts_at >= t.cttsCount()) return 0;
    return @as(i32, @bitCast(be32(t.ctts[c.ctts_at * 8 + 4 ..])));
}

/// Whether a decoder can start at the sample.
pub fn isKey(t: *const Tables, c: *const Cursor) bool {
    if (!t.has_syncs) return true;
    return c.sync_at < t.syncCount() and t.syncAt(c.sync_at) == c.sample;
}

/// The chunk's sample count and where it begins, for the chunk the cursor
/// is in: the run moved on when the chunk is past it.
fn enterChunk(t: *const Tables, c: *Cursor) void {
    while (c.run + 1 < t.stscCount() and c.chunk >= t.runFirst(c.run + 1)) c.run += 1;
    c.chunk_samples = t.runSamples(c.run);
    c.offset = if (c.chunk < t.chunk_count) t.chunkAt(c.chunk) else 0;
}

/// The cursor at the first sample.
pub fn reset(t: *const Tables, c: *Cursor) void {
    c.* = .{};
    if (t.samples == 0) return;
    enterChunk(t, c);
    c.stts_left = if (t.sttsCount() > 0) be32(t.stts[0..]) else 0;
    c.ctts_left = if (t.cttsCount() > 0) be32(t.ctts[0..]) else 0;
    skipEmptyRuns(t, c);
}

/// Runs of no samples passed over, so the cursor's runs are its sample's.
fn skipEmptyRuns(t: *const Tables, c: *Cursor) void {
    while (c.stts_left == 0 and c.stts_at + 1 < t.sttsCount()) {
        c.stts_at += 1;
        c.stts_left = be32(t.stts[c.stts_at * 8 ..]);
    }
    while (c.ctts_left == 0 and c.ctts_at + 1 < t.cttsCount()) {
        c.ctts_at += 1;
        c.ctts_left = be32(t.ctts[c.ctts_at * 8 ..]);
    }
    // A chunk said to hold no samples is passed over too.
    while (c.chunk_samples == 0 and c.chunk + 1 < t.chunk_count) {
        c.chunk += 1;
        enterChunk(t, c);
    }
}

/// The cursor moved on past the sample it is at, of `size` bytes.
pub fn step(t: *const Tables, c: *Cursor, size: u32) void {
    c.dts += duration(t, c);
    if (c.stts_left > 0) c.stts_left -= 1;
    if (c.ctts_left > 0) c.ctts_left -= 1;
    c.sample += 1;
    c.offset += size;
    c.in_chunk += 1;
    if (c.in_chunk >= c.chunk_samples) {
        c.chunk += 1;
        c.in_chunk = 0;
        enterChunk(t, c);
    }
    while (t.has_syncs and c.sync_at < t.syncCount() and t.syncAt(c.sync_at) < c.sample) c.sync_at += 1;
    skipEmptyRuns(t, c);
}

/// The cursor put at sample `n`: the runs walked from the start to find
/// its chunk and its times, its chunk's samples before it summed for
/// where it begins.
pub fn moveTo(t: *const Tables, c: *Cursor, n: u32) void {
    reset(t, c);
    if (n == 0 or t.samples == 0) return;
    const target = @min(n, t.samples);

    // Its chunk: the runs of chunks counted until one holds it.
    var before: u64 = 0;
    var run: u32 = 0;
    while (run < t.stscCount()) : (run += 1) {
        const first = t.runFirst(run);
        const end = t.runEnd(run);
        const per = t.runSamples(run);
        const held = @as(u64, end -| first) * per;
        if (per != 0 and target < before + held) {
            const into: u64 = target - before;
            c.run = run;
            c.chunk = first + @as(u32, @intCast(into / per));
            c.in_chunk = @intCast(into % per);
            c.chunk_samples = per;
            break;
        }
        before += held;
    } else {
        c.chunk = t.chunk_count;
        c.in_chunk = 0;
    }
    c.offset = if (c.chunk < t.chunk_count) t.chunkAt(c.chunk) else 0;
    var k: u32 = target - c.in_chunk;
    while (k < target) : (k += 1) c.offset += t.sizeOf(k);
    c.sample = target;

    // Its decode time: the runs of durations summed up to it.
    var left: u32 = target;
    c.dts = 0;
    c.stts_at = 0;
    while (c.stts_at < t.sttsCount()) : (c.stts_at += 1) {
        const count = be32(t.stts[c.stts_at * 8 ..]);
        const delta = be32(t.stts[c.stts_at * 8 + 4 ..]);
        if (left < count) {
            c.dts += @as(u64, left) * delta;
            c.stts_left = count - left;
            break;
        }
        c.dts += @as(u64, count) * delta;
        left -= count;
    } else {
        c.stts_left = 0;
    }
    left = target;
    c.ctts_at = 0;
    c.ctts_left = 0;
    while (c.ctts_at < t.cttsCount()) : (c.ctts_at += 1) {
        const count = be32(t.ctts[c.ctts_at * 8 ..]);
        if (left < count) {
            c.ctts_left = count - left;
            break;
        }
        left -= count;
    }
    if (t.has_syncs) {
        var low: u32 = 0;
        var high: u32 = t.syncCount();
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (t.syncAt(middle) < target) low = middle + 1 else high = middle;
        }
        c.sync_at = low;
    }
    skipEmptyRuns(t, c);
}

/// The sample whose decode time is the last at or before `ticks`; the
/// last sample when they all are.
pub fn sampleAt(t: *const Tables, ticks: u64) u32 {
    var sample: u64 = 0;
    var time: u64 = 0;
    for (0..t.sttsCount()) |n| {
        const count = be32(t.stts[n * 8 ..]);
        const delta = be32(t.stts[n * 8 + 4 ..]);
        const span = @as(u64, count) * delta;
        if (delta != 0 and ticks < time + span) {
            sample += (ticks - time) / delta;
            return @intCast(@min(sample, t.samples -| 1));
        }
        time += span;
        sample += count;
    }
    return t.samples -| 1;
}

/// The sum of every sample's duration: the track's length in ticks.
pub fn totalTicks(t: *const Tables) u64 {
    var total: u64 = 0;
    for (0..t.sttsCount()) |n| total += @as(u64, be32(t.stts[n * 8 ..])) * be32(t.stts[n * 8 + 4 ..]);
    return total;
}

test "a cursor walks runs of chunks and durations, and is put anywhere the same" {
    // Five samples: chunks of 2, 2 and 1 (runs: chunk 1 holds 2 from it
    // on, chunk 3 holds 1), sizes 10..14, durations 3,3,3 then 5,5; the
    // second and the fifth are keys.
    const stts = [_]u8{ 0, 0, 0, 3, 0, 0, 0, 3, 0, 0, 0, 2, 0, 0, 0, 5 };
    const stsc = [_]u8{ 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0, 3, 0, 0, 0, 1, 0, 0, 0, 1 };
    const sizes = [_]u8{ 0, 0, 0, 10, 0, 0, 0, 11, 0, 0, 0, 12, 0, 0, 0, 13, 0, 0, 0, 14 };
    const chunks = [_]u8{ 0, 0, 0, 100, 0, 0, 0, 200, 0, 0, 1, 44 };
    const syncs = [_]u8{ 0, 0, 0, 2, 0, 0, 0, 5 };
    const t = Tables{ .stts = &stts, .stsc = &stsc, .sizes = &sizes, .chunks = &chunks, .syncs = &syncs, .has_syncs = true, .samples = 5, .chunk_count = 3 };
    try std.testing.expect(t.sound());
    var c: Cursor = .{};
    reset(&t, &c);
    const offsets = [_]u64{ 100, 110, 200, 212, 300 };
    const times = [_]u64{ 0, 3, 6, 9, 14 };
    const keys = [_]bool{ false, true, false, false, true };
    for (0..5) |n| {
        try std.testing.expectEqual(offsets[n], c.offset);
        try std.testing.expectEqual(times[n], c.dts);
        try std.testing.expectEqual(keys[n], isKey(&t, &c));
        var other: Cursor = .{};
        moveTo(&t, &other, @intCast(n));
        try std.testing.expectEqual(c.offset, other.offset);
        try std.testing.expectEqual(c.dts, other.dts);
        try std.testing.expectEqual(c.chunk, other.chunk);
        try std.testing.expectEqual(duration(&t, &c), duration(&t, &other));
        try std.testing.expectEqual(isKey(&t, &c), isKey(&t, &other));
        step(&t, &c, t.sizeOf(@intCast(n)));
    }
    try std.testing.expectEqual(@as(u32, 1), t.keyAtOrBefore(3));
    try std.testing.expectEqual(@as(u32, 0), t.keyAtOrBefore(0));
    try std.testing.expectEqual(@as(u32, 4), t.keyAtOrBefore(4));
    try std.testing.expectEqual(@as(u32, 3), sampleAt(&t, 12));
    try std.testing.expectEqual(@as(u32, 4), sampleAt(&t, 100));
    try std.testing.expectEqual(@as(u64, 19), totalTicks(&t));
}
