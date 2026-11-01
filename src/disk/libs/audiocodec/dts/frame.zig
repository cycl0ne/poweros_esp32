// SPDX-License-Identifier: MIT
//! A DTS core frame's audio: its coding header (ETSI TS 102 114 5.4.3),
//! then one subframe at a time its side information (5.5) and its subband
//! samples (5.6), as 24-bit samples in floats.
//!
//! **The samples** are a quantizer's level, whose kinds are many: a Huffman
//! code, a block code holding four, or plain - times the scale factor and
//! step size (C.3 for the rest): the two predictors' prediction added where
//! a subband has one (ADPCM), a joint subband's the samples of its source
//! channel scaled, a high frequency subband a vector from a table. Reading
//! past a frame's end gives zeros and is noticed.
//!
//! **What is left out**: the LFE's samples are passed over - a mix into two
//! channels leaves them out in any case, as the other kinds' do, and they
//! are half the filter's work - and the dynamic range, as FFmpeg does:
//! `header.read` knows of it. The extensions past the core (XCH, X96, XBR,
//! XLL, LBR) stay for later.
//!
//! The history of the predictors is the last four samples of each
//! subband's array, moved to its front when the next subframe begins.

const Bits = @import("../aac/bits.zig").Bits;
const header = @import("header.zig");
const tables = @import("tables.zig");
const vq = @import("vq.zig");

pub const CHANNELS = 5;
pub const BANDS = 32;
/// The blocks of a subframe: 8 to each of up to 4 subsubframes.
pub const SUBFRAME_BLOCKS = 32;
const HISTORY = 4;
/// Where a subband's samples begin in its array, after the history.
pub const FIRST = HISTORY;

pub const Error = error{Corrupt};

const LARGEST: f32 = 8388607.0;

pub const Decoder = struct {
    // The frame.
    fields: header.Fields,
    channels: usize,
    subframes: u32,
    blocks: u32,
    done: u32,
    bands: [CHANNELS]u8,
    vq_start: [CHANNELS]u8,
    joint: [CHANNELS]u8,
    transition_book: [CHANNELS]u8,
    scale_book: [CHANNELS]u8,
    allocation_book: [CHANNELS]u8,
    select: [CHANNELS][10]u8,
    adjust: [CHANNELS][10]f32,
    /// The subframe.
    moved: u32,
    prediction: [CHANNELS][BANDS]bool,
    predictor: [CHANNELS][BANDS]u16,
    allocation: [CHANNELS][BANDS]u8,
    transition: [CHANNELS][BANDS]u8,
    scales: [CHANNELS][BANDS][2]f32,
    joint_scale: [CHANNELS][BANDS]f32,
    /// How many subbands of each channel have sound: the rest are silent.
    active: [CHANNELS]u8,
    /// Each subband's samples, after its predictor's history.
    samples: [CHANNELS][BANDS][HISTORY + SUBFRAME_BLOCKS]f32,
};

/// The next code of a book: its level. A book's every code is one, so the
/// walk always ends on a leaf.
fn code(b: *Bits, tree: tables.Tree) i32 {
    const word = b.peek(16);
    var at: usize = 0;
    var used: u5 = 0;
    while (true) {
        const bit = (word >> @intCast(15 - @as(u32, used))) & 1;
        used += 1;
        const child = tree[at][bit];
        if (child < 0) {
            b.skip(used);
            return @as(i32, -child) - tables.leaf_bias;
        }
        at = @intCast(child);
    }
}

fn signed(value: u32, count: u5) i32 {
    const up: u5 = @intCast(@as(u32, 32) - count);
    return @as(i32, @bitCast(value << up)) >> up;
}

/// The frame in `b`, whose header is known decodable, begun: its headers
/// read. `blocks` is what the header says.
pub fn begin(d: *Decoder, b: *Bits, h: *const header.Header) Error!void {
    d.fields = header.read(b) orelse return error.Corrupt;
    d.blocks = h.blocks;
    d.done = 0;
    d.subframes = b.read(4) + 1;
    d.channels = b.read(3) + 1;
    if (d.channels != header.mode_channels[h.mode]) return error.Corrupt;
    const channels = d.channels;

    for (0..channels) |ch| {
        const bands = b.read(5) + 2;
        if (bands > BANDS) return error.Corrupt;
        d.bands[ch] = @intCast(bands);
    }
    for (0..channels) |ch| d.vq_start[ch] = @intCast(b.read(5) + 1);
    for (0..channels) |ch| {
        const source = b.read(3);
        if (source > channels) return error.Corrupt;
        d.joint[ch] = @intCast(source);
    }
    for (0..channels) |ch| d.transition_book[ch] = @intCast(b.read(2));
    for (0..channels) |ch| {
        const book = b.read(3);
        if (book == 7) return error.Corrupt;
        d.scale_book[ch] = @intCast(book);
    }
    for (0..channels) |ch| {
        const book = b.read(3);
        if (book == 7) return error.Corrupt;
        d.allocation_book[ch] = @intCast(book);
    }
    for (0..10) |n| {
        const width: u5 = if (n == 0) 1 else if (n < 5) 2 else 3;
        for (0..channels) |ch| d.select[ch][n] = @intCast(b.read(width));
    }
    for (0..10) |n| {
        for (0..channels) |ch| {
            d.adjust[ch][n] = 1.0;
            if (d.select[ch][n] < tables.quant_books[n]) {
                d.adjust[ch][n] = adjustments[b.read(2)];
            }
        }
    }
    if (d.fields.crc) b.skip(16);

    moveHistory(d);
    if (!d.fields.history) {
        for (0..CHANNELS) |ch| {
            for (0..BANDS) |band| {
                for (0..HISTORY) |i| d.samples[ch][band][i] = 0;
            }
        }
    }
    if (b.overrun()) return error.Corrupt;
}

const adjustments = [4]f32{ 1.0, 1.125, 1.25, 1.4375 };
const block_bits = [7]u5{ 7, 10, 12, 13, 15, 17, 19 };
const block_levels = [7]u32{ 3, 5, 7, 9, 13, 17, 25 };

/// The next scale factor: `index` holds what a Huffman book's differences
/// are added to.
fn scaleOf(b: *Bits, index: *i32, book: u8) Error!f32 {
    if (book < 5) {
        index.* += code(b, tables.scales[book]);
    } else {
        index.* = @intCast(b.read(@intCast(book + 1)));
    }
    const table: []const f32 = if (book > 5) &tables.scale7 else &tables.scale6;
    if (index.* < 0 or index.* >= table.len) return error.Corrupt;
    return table[@intCast(index.*)];
}

/// The predictors and the bit allocation of a subframe.
fn sideInformation(d: *Decoder, b: *Bits) Error!void {
    const channels = d.channels;
    for (0..channels) |ch| {
        for (0..d.bands[ch]) |band| d.prediction[ch][band] = b.bit();
    }
    for (0..channels) |ch| {
        for (0..d.bands[ch]) |band| {
            if (d.prediction[ch][band]) d.predictor[ch][band] = @intCast(b.read(12));
        }
    }
    for (0..channels) |ch| {
        const book = d.allocation_book[ch];
        for (0..d.vq_start[ch]) |band| {
            const abits = if (book < 5) code(b, tables.allocation[book]) else @as(i32, @intCast(b.read(@intCast(book - 1))));
            if (abits > 26) return error.Corrupt;
            d.allocation[ch][band] = @intCast(abits);
        }
    }
}

fn transitions(d: *Decoder, b: *Bits, subsubframes: u32) void {
    for (0..d.channels) |ch| {
        for (0..BANDS) |band| d.transition[ch][band] = 0;
        if (subsubframes < 2) continue;
        const book = tables.transition[d.transition_book[ch]];
        for (0..d.vq_start[ch]) |band| {
            if (d.allocation[ch][band] != 0) d.transition[ch][band] = @intCast(code(b, book));
        }
    }
}

fn scaleFactors(d: *Decoder, b: *Bits) Error!void {
    for (0..d.channels) |ch| {
        const book = d.scale_book[ch];
        var index: i32 = 0;
        for (0..d.vq_start[ch]) |band| {
            d.scales[ch][band] = .{ 0, 0 };
            if (d.allocation[ch][band] == 0) continue;
            d.scales[ch][band][0] = try scaleOf(b, &index, book);
            if (d.transition[ch][band] != 0) d.scales[ch][band][1] = try scaleOf(b, &index, book);
        }
        var band: usize = d.vq_start[ch];
        while (band < d.bands[ch]) : (band += 1) d.scales[ch][band][0] = try scaleOf(b, &index, book);
    }
    var book_of: [CHANNELS]u8 = undefined;
    for (0..d.channels) |ch| {
        if (d.joint[ch] == 0) continue;
        const book = b.read(3);
        if (book == 7) return error.Corrupt;
        book_of[ch] = @intCast(book);
    }
    for (0..d.channels) |ch| {
        if (d.joint[ch] == 0) continue;
        const book = book_of[ch];
        const source = d.joint[ch] - 1;
        var band: usize = d.bands[ch];
        while (band < d.bands[source]) : (band += 1) {
            const value: i32 = if (book < 5) code(b, tables.scales[book]) else @intCast(b.read(@intCast(book + 1)));
            const index = value + 64;
            if (index < 0 or index >= tables.joint_scale.len) return error.Corrupt;
            d.joint_scale[ch][band] = tables.joint_scale[@intCast(index)];
        }
    }
}

/// Eight samples' levels of a subband into `levels`: whether by a Huffman
/// code, which has its scale factor adjusted.
fn levelsOf(d: *const Decoder, b: *Bits, ch: usize, abits: u32, levels: *[8]i32) Error!bool {
    if (abits <= 10) {
        const select = d.select[ch][abits - 1];
        if (select < tables.quant_books[abits - 1]) {
            const book = tables.quant[abits - 1][select];
            for (levels) |*level| level.* = code(b, book);
            return true;
        }
        if (abits <= 7) {
            const count = block_levels[abits - 1];
            const offset: i32 = @intCast((count - 1) / 2);
            for (0..2) |half| {
                var value = b.read(block_bits[abits - 1]);
                for (0..4) |i| {
                    levels[half * 4 + i] = @as(i32, @intCast(value % count)) - offset;
                    value /= count;
                }
                if (value != 0) return error.Corrupt;
            }
            return false;
        }
    }
    const width: u5 = @intCast(abits - 3);
    for (levels) |*level| level.* = signed(b.read(width), width);
    return false;
}

fn audio(d: *Decoder, b: *Bits, subsubframes: u32) Error!void {
    const steps: *const [27]f32 = if (d.fields.lossless) &tables.step_lossless else &tables.step_lossy;
    var levels: [8]i32 = undefined;
    for (0..subsubframes) |ssf| {
        for (0..d.channels) |ch| {
            for (0..d.vq_start[ch]) |band| {
                const out = d.samples[ch][band][FIRST + ssf * 8 ..][0..8];
                const abits = d.allocation[ch][band];
                if (abits == 0) {
                    @memset(out, 0);
                    continue;
                }
                const adjusted = try levelsOf(d, b, ch, abits, &levels);
                const later = d.transition[ch][band];
                const which: usize = if (later == 0 or ssf < later) 0 else 1;
                var scale = d.scales[ch][band][which] * steps[abits];
                if (adjusted) scale *= d.adjust[ch][abits - 1];
                for (out, levels) |*sample, level| sample.* = @as(f32, @floatFromInt(level)) * scale;
            }
        }
        if (ssf == subsubframes - 1 or d.fields.sync_each) {
            if (b.read(16) != 0xFFFF) return error.Corrupt;
        }
        if (b.overrun()) return error.Corrupt;
    }
}

/// The predictors' predictions added, over `count` samples of each subband
/// with one.
fn inverseAdpcm(d: *Decoder, count: u32) void {
    for (0..d.channels) |ch| {
        for (0..d.bands[ch]) |band| {
            if (!d.prediction[ch][band]) continue;
            const vector = vq.adpcm[d.predictor[ch][band]];
            const c0: f32 = @as(f32, @floatFromInt(vector[0])) / 8192.0;
            const c1: f32 = @as(f32, @floatFromInt(vector[1])) / 8192.0;
            const c2: f32 = @as(f32, @floatFromInt(vector[2])) / 8192.0;
            const c3: f32 = @as(f32, @floatFromInt(vector[3])) / 8192.0;
            const s = &d.samples[ch][band];
            for (FIRST..FIRST + count) |m| {
                const value = s[m] + c0 * s[m - 1] + c1 * s[m - 2] + c2 * s[m - 3] + c3 * s[m - 4];
                s[m] = @max(-LARGEST, @min(LARGEST, value));
            }
        }
    }
}

/// The next subframe of the frame read into the samples: how many blocks
/// it holds. The frame's every subframe read, a frame's blocks left over
/// are the caller's to fill.
pub fn subframe(d: *Decoder, b: *Bits) Error!u32 {
    moveHistory(d);
    const subsubframes = b.read(2) + 1;
    b.skip(3); // PSC
    const count = subsubframes * 8;
    if (d.done + count > d.blocks) return error.Corrupt;
    try sideInformation(d, b);
    transitions(d, b, subsubframes);
    try scaleFactors(d, b);
    if (d.fields.drc) b.skip(8);
    if (d.fields.crc) b.skip(16);

    // The high frequency vectors.
    for (0..d.channels) |ch| {
        var band: usize = d.vq_start[ch];
        while (band < d.bands[ch]) : (band += 1) {
            const vector = vq.high[b.read(10)];
            const scale = d.scales[ch][band][0] / 16.0;
            const out = d.samples[ch][band][FIRST..][0..count];
            for (out, vector[0..count]) |*sample, value| sample.* = @as(f32, @floatFromInt(value)) * scale;
        }
    }

    // The LFE's samples and their scale factor.
    if (d.fields.lfe != 0) b.skip(8 * (2 * d.fields.lfe * subsubframes + 1));

    try audio(d, b, subsubframes);
    inverseAdpcm(d, count);

    // Joint subbands: their source channel's samples, scaled.
    for (0..d.channels) |ch| {
        var active = d.bands[ch];
        if (d.joint[ch] != 0) {
            const source = d.joint[ch] - 1;
            var band: usize = d.bands[ch];
            while (band < d.bands[source]) : (band += 1) {
                const scale = d.joint_scale[ch][band];
                const out = d.samples[ch][band][FIRST..][0..count];
                for (out, d.samples[source][band][FIRST..][0..count]) |*sample, value| sample.* = value * scale;
            }
            active = @max(active, d.bands[source]);
        }
        d.active[ch] = active;
    }
    d.done += count;
    d.moved = count;
    return count;
}

/// The last samples of the subframe before made the history; a subband no
/// longer active has none.
fn moveHistory(d: *Decoder) void {
    const count = d.moved;
    if (count == 0) return;
    d.moved = 0;
    for (0..d.channels) |ch| {
        for (0..BANDS) |band| {
            const s = &d.samples[ch][band];
            if (band < d.active[ch]) {
                for (0..HISTORY) |i| s[i] = s[count + i];
            } else {
                @memset(s[0..HISTORY], 0);
            }
        }
    }
}
