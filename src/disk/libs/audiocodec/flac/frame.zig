// SPDX-License-Identifier: MIT
//! A FLAC frame decoded: its header found and checked, then a subframe
//! for each channel, then the channels taken apart again where they were
//! coded as a sum and a difference.
//!
//! **The header** begins with a sync code no other part of a frame is
//! likely to hold, and ends with a CRC-8 of itself; a run of bytes that
//! only looks like one, or does not agree with the stream - its channels,
//! its sample size, its rate, a block larger than any the stream has - is
//! passed over, and the search goes on a byte later. The whole frame ends
//! with a CRC-16; a frame whose CRC is wrong is handed out as silence, as
//! is one that cannot be decoded.
//!
//! **A subframe** is a constant, the samples as they are, or a
//! prediction - one of four fixed ones, or a linear one with its own
//! coefficients - from the samples before, followed by the residual: what
//! the prediction missed, in Rice codes whose parameter changes from one
//! partition of the block to the next. Bits a subframe has none of at the
//! bottom (wasted bits) are put back last.
//!
//! **Bits are read most significant first**, a byte at a time from the
//! stream, and never a byte more than a read needs: the frame ends on a
//! byte, so what is left in hand at its end is its padding, and the next
//! frame starts with the next byte of the stream.
//!
//! The arithmetic wraps rather than traps, so a damaged frame decodes to
//! noise rather than stopping the program; the CRC then makes it silence.

const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;

/// The longest a header can be: sync and codes, a 7-byte number, a 2-byte
/// block size and rate, the CRC-8.
pub const header_max = 16;

/// The most a linear prediction looks back.
const lpc_max = 32;

/// What the stream says of every frame, to check a header against.
pub const Format = struct {
    channels: u32,
    bits: u32,
    rate: u32,
    max_block: u32,
};

pub const Header = struct {
    blocksize: u32,
    /// 0..7: that many channels plus one, each on its own; 8: left and
    /// side; 9: side and right; 10: mid and side.
    assignment: u32,
    channels: u32,
    /// Whether `number` counts samples (a variable block size) or frames.
    variable: bool,
    number: u64,
    /// Its bytes, the CRC-8 among them.
    length: usize,
};

const crc8_table = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u8 = undefined;
    for (&table, 0..) |*entry, i| {
        var crc: u8 = i;
        for (0..8) |_| crc = if (crc & 0x80 != 0) (crc << 1) ^ 0x07 else crc << 1;
        entry.* = crc;
    }
    break :blk table;
};

const crc16_table = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u16 = undefined;
    for (&table, 0..) |*entry, i| {
        var crc: u16 = @as(u16, i) << 8;
        for (0..8) |_| crc = if (crc & 0x8000 != 0) (crc << 1) ^ 0x8005 else crc << 1;
        entry.* = crc;
    }
    break :blk table;
};

fn crc16(crc: u16, byte: u8) u16 {
    return (crc << 8) ^ crc16_table[(crc >> 8) ^ byte];
}

/// The header at the front of `bytes`, when one is there and agrees with
/// `format`. `bytes` holds `header_max` bytes, or all the stream has left.
pub fn headerAt(bytes: []const u8, format: *const Format) ?Header {
    if (bytes.len < 6 or bytes[0] != 0xFF or bytes[1] & 0xFE != 0xF8) return null;
    const size_code = bytes[2] >> 4;
    const rate_code = bytes[2] & 0x0F;
    const assignment: u32 = bytes[3] >> 4;
    const bits_code = (bytes[3] >> 1) & 0x07;
    if (size_code == 0 or rate_code == 15 or assignment > 10 or bits_code == 3 or bytes[3] & 1 != 0) return null;

    // The frame's or first sample's number, coded as UTF-8 codes a character.
    var at: usize = 4;
    const lead = bytes[at];
    at += 1;
    var extra: usize = 0;
    var number: u64 = lead;
    if (lead >= 0x80) {
        var mask: u8 = 0x40;
        while (lead & mask != 0) : (mask >>= 1) extra += 1;
        if (extra == 0 or extra > 6) return null;
        number = lead & (mask -% 1);
    }
    if (bytes.len < at + extra) return null;
    for (bytes[at .. at + extra]) |byte| {
        if (byte & 0xC0 != 0x80) return null;
        number = number << 6 | (byte & 0x3F);
    }
    at += extra;

    var blocksize: u32 = switch (size_code) {
        1 => 192,
        2...5 => @as(u32, 576) << @intCast(size_code - 2),
        8...15 => @as(u32, 256) << @intCast(size_code - 8),
        else => 0,
    };
    if (size_code == 6 or size_code == 7) {
        const width: usize = if (size_code == 6) 1 else 2;
        if (bytes.len < at + width) return null;
        blocksize = (if (width == 1) @as(u32, bytes[at]) else @as(u32, bytes[at]) << 8 | bytes[at + 1]) + 1;
        at += width;
    }
    var rate: u32 = switch (rate_code) {
        1 => 88200,
        2 => 176400,
        3 => 192000,
        4 => 8000,
        5 => 16000,
        6 => 22050,
        7 => 24000,
        8 => 32000,
        9 => 44100,
        10 => 48000,
        11 => 96000,
        else => 0,
    };
    if (rate_code >= 12) {
        const width: usize = if (rate_code == 12) 1 else 2;
        if (bytes.len < at + width) return null;
        const value: u32 = if (width == 1) bytes[at] else @as(u32, bytes[at]) << 8 | bytes[at + 1];
        rate = switch (rate_code) {
            12 => value * 1000,
            13 => value,
            else => value * 10,
        };
        at += width;
    }
    if (bytes.len < at + 1) return null;
    var crc: u8 = 0;
    for (bytes[0..at]) |byte| crc = crc8_table[crc ^ byte];
    if (crc != bytes[at]) return null;

    const bits: u32 = switch (bits_code) {
        1 => 8,
        2 => 12,
        4 => 16,
        5 => 20,
        6 => 24,
        7 => 32,
        else => 0,
    };
    const channels: u32 = if (assignment < 8) assignment + 1 else 2;
    if (channels != format.channels) return null;
    if (bits != 0 and bits != format.bits) return null;
    if (rate != 0 and rate != format.rate) return null;
    if (blocksize > format.max_block) return null;
    return .{
        .blocksize = blocksize,
        .assignment = assignment,
        .channels = channels,
        .variable = bytes[1] & 1 != 0,
        .number = number,
        .length = at + 1,
    };
}

/// Bits from the stream, most significant first, a byte at a time as a
/// read needs it; the CRC-16 of every byte taken.
const Reader = struct {
    stream: *Stream,
    cache: u64 = 0,
    count: u32 = 0,
    crc: u16 = 0,
    /// The stream ended before the frame did.
    short: bool = false,

    fn byte(reader: *Reader) u8 {
        const stream = reader.stream;
        if (stream.start == stream.stop) {
            _stream.fill(stream);
            if (stream.start == stream.stop) {
                reader.short = true;
                return 0;
            }
        }
        const value = stream.in[stream.start];
        stream.start += 1;
        reader.crc = crc16(reader.crc, value);
        return value;
    }

    /// `width` bits, up to 32, as they are.
    fn bits(reader: *Reader, width: u32) u32 {
        if (width == 0) return 0;
        while (reader.count < width) {
            reader.cache = reader.cache << 8 | reader.byte();
            reader.count += 8;
        }
        reader.count -= width;
        return @truncate((reader.cache >> @intCast(reader.count)) & ((@as(u64, 1) << @intCast(width)) - 1));
    }

    /// `width` bits, up to 32, as a signed number.
    fn signed(reader: *Reader, width: u32) i32 {
        if (width == 0) return 0;
        const value = reader.bits(width);
        const shift: u5 = @intCast(32 - width);
        return @as(i32, @bitCast(value << shift)) >> shift;
    }

    /// The zeros before the next 1, the 1 read too.
    fn unary(reader: *Reader) u32 {
        var zeros: u32 = 0;
        while (true) {
            if (reader.count == 0) {
                reader.cache = reader.cache << 8 | reader.byte();
                reader.count = 8;
                if (reader.short or zeros > 1 << 28) {
                    reader.short = true;
                    return 0;
                }
            }
            const window = reader.cache & ((@as(u64, 1) << @intCast(reader.count)) - 1);
            if (window == 0) {
                zeros += reader.count;
                reader.count = 0;
                continue;
            }
            const top: u32 = 63 - @as(u32, @clz(window));
            zeros += reader.count - 1 - top;
            reader.count = top;
            return zeros;
        }
    }
};

/// What a frame came to.
pub const Outcome = enum {
    /// Decoded, or made silence when it was damaged.
    decoded,
    /// The stream has no more frames.
    end,
};

/// The next frame found and decoded into `samples`, a block of each
/// channel: its header, for the block's size and where it lies.
pub fn decode(stream: *Stream, format: *const Format, samples: [2][*]i32, header: *Header) Outcome {
    if (!find(stream, format, header)) return .end;
    var reader: Reader = .{ .stream = stream };
    for (_stream.available(stream)[0..header.length]) |value| reader.crc = crc16(reader.crc, value);
    _stream.consume(stream, header.length);

    const n = header.blocksize;
    var good = true;
    for (0..header.channels) |channel| {
        // The side channel has one bit more than the others.
        const side = (header.assignment == 8 and channel == 1) or (header.assignment == 9 and channel == 0) or (header.assignment == 10 and channel == 1);
        if (!subframe(&reader, samples[channel][0..n], format.bits + @intFromBool(side))) {
            good = false;
            break;
        }
    }
    if (reader.short) return .end;
    if (good) {
        // What is left in hand is the padding to the byte; then the CRC.
        reader.count = 0;
        const expected = reader.crc;
        const high = reader.byte();
        const low = reader.byte();
        if (reader.short) return .end;
        good = (@as(u16, high) << 8 | low) == expected;
    }
    if (!good) {
        for (0..header.channels) |channel| @memset(samples[channel][0..n], 0);
        return .decoded;
    }
    if (header.channels == 2) decorrelate(header.assignment, samples[0][0..n], samples[1][0..n]);
    return .decoded;
}

/// The stream moved to the next header that agrees with `format`, and it
/// read into `header`: false when there is none before the end.
pub fn find(stream: *Stream, format: *const Format, header: *Header) bool {
    while (true) {
        if (stream.stop - stream.start < header_max) _stream.fill(stream);
        const bytes = _stream.available(stream);
        if (bytes.len < 6) return false;
        var at: usize = 0;
        while (at + 1 < bytes.len) : (at += 1) {
            if (bytes[at] != 0xFF or bytes[at + 1] & 0xFE != 0xF8) continue;
            // A header near the end of what is here is looked at once more
            // is read behind it.
            if (bytes.len - at < header_max and !stream.eof) break;
            if (headerAt(bytes[at..], format)) |found| {
                _stream.consume(stream, at);
                header.* = found;
                return true;
            }
        }
        if (stream.eof and at + 1 >= bytes.len) return false;
        // What lies before `at` holds no header: passed over, and more read.
        _stream.consume(stream, at);
    }
}

/// One channel's subframe into `out`, at `bits` a sample: false for one
/// that cannot be.
fn subframe(reader: *Reader, out: []i32, bits_given: u32) bool {
    if (reader.bits(1) != 0) return false;
    const kind = reader.bits(6);
    var wasted: u32 = 0;
    if (reader.bits(1) != 0) wasted = reader.unary() + 1;
    if (wasted >= bits_given) return false;
    const bits = bits_given - wasted;
    switch (kind) {
        0 => @memset(out, reader.signed(bits)),
        1 => for (out) |*sample| {
            sample.* = reader.signed(bits);
        },
        8...12 => {
            const order = kind - 8;
            if (order > out.len) return false;
            for (out[0..order]) |*sample| sample.* = reader.signed(bits);
            if (!residual(reader, out, order)) return false;
            restoreFixed(out, order);
        },
        32...63 => {
            const order = kind - 31;
            if (order > out.len) return false;
            for (out[0..order]) |*sample| sample.* = reader.signed(bits);
            const precision = reader.bits(4) + 1;
            if (precision == 16) return false;
            const shift = reader.signed(5);
            if (shift < 0) return false;
            var coefficients: [lpc_max]i32 = undefined;
            for (coefficients[0..order]) |*coefficient| coefficient.* = reader.signed(precision);
            if (!residual(reader, out, order)) return false;
            // A sum that can pass 32 bits is made in 64.
            const wide = bits + precision + log2(order) > 32;
            if (wide) restoreLpc(i64, out, coefficients[0..order], @intCast(shift)) else restoreLpc(i32, out, coefficients[0..order], @intCast(shift));
        },
        else => return false,
    }
    if (reader.short) return false;
    if (wasted != 0) {
        for (out) |*sample| sample.* = sample.* *% (@as(i32, 1) << @intCast(wasted));
    }
    return true;
}

fn log2(value: u32) u32 {
    return 31 - @as(u32, @clz(value | 1));
}

/// The residual of a subframe with a prediction of `order`, into
/// `out[order..]`: partitions of Rice codes, or of raw bits where the
/// parameter is the escape.
fn residual(reader: *Reader, out: []i32, order: u32) bool {
    const method = reader.bits(2);
    if (method > 1) return false;
    const parameter_bits: u32 = if (method == 0) 4 else 5;
    const escape: u32 = if (method == 0) 15 else 31;
    const partition_order = reader.bits(4);
    const partitions = @as(usize, 1) << @intCast(partition_order);
    const each = out.len >> @intCast(partition_order);
    if (each << @intCast(partition_order) != out.len or each < order) return false;
    var at: usize = order;
    for (0..partitions) |partition| {
        const count = if (partition == 0) each - order else each;
        const parameter = reader.bits(parameter_bits);
        if (parameter == escape) {
            const width = reader.bits(5);
            for (out[at..][0..count]) |*sample| sample.* = reader.signed(width);
        } else {
            for (out[at..][0..count]) |*sample| {
                const high = reader.unary();
                const value = (high << @intCast(parameter)) | reader.bits(parameter);
                sample.* = @bitCast((value >> 1) ^ (0 -% (value & 1)));
            }
        }
        if (reader.short) return false;
        at += count;
    }
    return true;
}

/// The samples after the first `order` made from the residual and one of
/// the fixed predictions.
fn restoreFixed(out: []i32, order: u32) void {
    var i: usize = order;
    switch (order) {
        1 => while (i < out.len) : (i += 1) {
            out[i] +%= out[i - 1];
        },
        2 => while (i < out.len) : (i += 1) {
            out[i] +%= 2 *% out[i - 1] -% out[i - 2];
        },
        3 => while (i < out.len) : (i += 1) {
            out[i] +%= 3 *% out[i - 1] -% 3 *% out[i - 2] +% out[i - 3];
        },
        4 => while (i < out.len) : (i += 1) {
            out[i] +%= 4 *% out[i - 1] -% 6 *% out[i - 2] +% 4 *% out[i - 3] -% out[i - 4];
        },
        else => {},
    }
}

/// The samples after the first made from the residual and a linear
/// prediction with `coefficients`, its sum in `Sum` and moved down by
/// `shift`.
fn restoreLpc(comptime Sum: type, out: []i32, coefficients: []const i32, shift: u32) void {
    const order = coefficients.len;
    var i: usize = order;
    while (i < out.len) : (i += 1) {
        var sum: Sum = 0;
        for (coefficients, 1..) |coefficient, back| sum +%= @as(Sum, coefficient) *% @as(Sum, out[i - back]);
        out[i] +%= @truncate(sum >> @intCast(shift));
    }
}

/// Two channels coded as left and side, side and right, or mid and side,
/// made left and right again.
fn decorrelate(assignment: u32, first: []i32, second: []i32) void {
    switch (assignment) {
        8 => for (first, second) |left, *side| {
            side.* = left -% side.*;
        },
        9 => for (first, second) |*side, right| {
            side.* = side.* +% right;
        },
        10 => for (first, second) |*mid, *side| {
            const sum = (mid.* *% 2) | (side.* & 1);
            const left = (sum +% side.*) >> 1;
            const right = (sum -% side.*) >> 1;
            mid.* = left;
            side.* = right;
        },
        else => {},
    }
}
