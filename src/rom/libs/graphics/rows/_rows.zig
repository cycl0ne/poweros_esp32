// SPDX-License-Identifier: MPL-2.0
//! Rows of pixels, moved and filled a word at a time.
//!
//! Every bulk operation in this library comes down to one of three things
//! done to a row: fill it with one packed pixel, copy it from somewhere
//! else, or copy it from somewhere that overlaps it. Done a pixel at a time
//! - an address worked out, a mode tested and a byte stored for each - a
//! full-screen stretch on this machine took over half a second, nearly all
//! of it spent waiting on external memory for stores one byte wide.
//!
//! So these write whole 32-bit words wherever the row allows, which is
//! nearly always: a pixel of 2 or 4 bytes on a surface whose rows start
//! aligned. The ends that do not fill a word, and a surface that is not
//! aligned at all, go a byte at a time, because the core raises an
//! exception for a load or store that is not aligned to its size.
//!
//! Nothing here knows about draw modes, clips or boards: the callers decide
//! that a row is a plain fill or a plain copy, and hand it here.

/// Fill `count` pixels of `bytes` each at `at` with `value`, which is a
/// pixel already packed into the surface's format, low byte first.
///
/// INPUTS:
/// - `at` - where the row starts.
/// - `bytes` - how many bytes a pixel takes.
/// - `count` - how many pixels.
/// - `value` - the pixel, right-aligned in the word.
pub fn fill(at: [*]u8, bytes: u32, count: usize, value: u32) void {
    if (count == 0) return;
    switch (bytes) {
        1 => {
            const b: u32 = value & 0xFF;
            fillWords(at, count, b | b << 8 | b << 16 | b << 24);
        },
        2 => {
            if (@intFromPtr(at) & 1 != 0) return fillBytes(at, bytes, count, value);
            const h: u32 = value & 0xFFFF;
            fillWords(at, count * 2, h | h << 16);
        },
        4 => {
            if (@intFromPtr(at) & 3 != 0) return fillBytes(at, bytes, count, value);
            const words: [*]u32 = @ptrCast(@alignCast(at));
            var i: usize = 0;
            while (i < count) : (i += 1) words[i] = value;
        },
        else => fillBytes(at, bytes, count, value),
    }
}

/// `length` bytes at `at` from a word that repeats every 4 bytes, the
/// pattern starting at `at` itself. `at` is aligned to whatever the pattern
/// repeats at, so the bytes before the first whole word are the pattern's
/// low bytes.
///
/// INPUTS:
/// - `at` - where to start.
/// - `length` - how many bytes.
/// - `word` - the pattern, as it lies from `at`.
fn fillWords(at: [*]u8, length: usize, word: u32) void {
    var i: usize = 0;
    var w = word;
    // Up to the first word boundary a byte at a time, turning the pattern
    // as it goes so the word written there still starts where it should.
    while (i < length and (@intFromPtr(at) + i) & 3 != 0) : (i += 1) {
        at[i] = @truncate(w);
        w = w >> 8 | w << 24;
    }
    // A row too short to reach a boundary ends above without one.
    if (i < length) {
        const words: [*]u32 = @ptrCast(@alignCast(at + i));
        const n = (length - i) / 4;
        var k: usize = 0;
        while (k < n) : (k += 1) words[k] = w;
        i += n * 4;
    }
    while (i < length) : (i += 1) {
        at[i] = @truncate(w);
        w >>= 8;
    }
}

/// A row filled a pixel at a time, for a pixel size that does not
/// repeat within a word.
///
/// INPUTS:
/// - `at` - where the row starts.
/// - `bytes` - how many bytes a pixel takes.
/// - `count` - how many pixels.
/// - `value` - the pixel, right-aligned in the word.
fn fillBytes(at: [*]u8, bytes: u32, count: usize, value: u32) void {
    var p = at;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        store(p, bytes, value);
        p += bytes;
    }
}

/// Copy `length` bytes forward. Safe when `to` is below `from` even if the
/// two overlap.
///
/// INPUTS:
/// - `to` - where the bytes go.
/// - `from` - where they come from.
/// - `length` - how many.
pub fn copy(to: [*]u8, from: [*]const u8, length: usize) void {
    var i: usize = 0;
    // Words only when both ends come to a boundary together.
    if ((@intFromPtr(to) ^ @intFromPtr(from)) & 3 == 0) {
        while (i < length and (@intFromPtr(to) + i) & 3 != 0) : (i += 1) to[i] = from[i];
        if (i < length) {
            const t: [*]u32 = @ptrCast(@alignCast(to + i));
            const f: [*]const u32 = @ptrCast(@alignCast(from + i));
            const n = (length - i) / 4;
            var k: usize = 0;
            while (k < n) : (k += 1) t[k] = f[k];
            i += n * 4;
        }
    } else if ((@intFromPtr(to) ^ @intFromPtr(from)) & 1 == 0 and length != 0) {
        // Two bytes apart from a word boundary is still a halfword each,
        // which is every row of a 16-bit surface landing on an odd pixel.
        if (i < length and (@intFromPtr(to) & 1) != 0) {
            to[0] = from[0];
            i = 1;
        }
        const t: [*]u16 = @ptrCast(@alignCast(to + i));
        const f: [*]const u16 = @ptrCast(@alignCast(from + i));
        const n = (length - i) / 2;
        var k: usize = 0;
        while (k < n) : (k += 1) t[k] = f[k];
        i += n * 2;
    }
    while (i < length) : (i += 1) to[i] = from[i];
}

/// Copy `length` bytes from the end backward, for when `to` is above
/// `from` and the two overlap.
///
/// INPUTS:
/// - `to` - where the bytes go.
/// - `from` - where they come from.
/// - `length` - how many.
pub fn copyBack(to: [*]u8, from: [*]const u8, length: usize) void {
    var i: usize = length;
    if ((@intFromPtr(to) ^ @intFromPtr(from)) & 3 == 0) {
        while (i > 0 and (@intFromPtr(to) + i) & 3 != 0) {
            i -= 1;
            to[i] = from[i];
        }
        while (i >= 4) {
            i -= 4;
            const t: *u32 = @ptrCast(@alignCast(to + i));
            const f: *const u32 = @ptrCast(@alignCast(from + i));
            t.* = f.*;
        }
    }
    while (i > 0) {
        i -= 1;
        to[i] = from[i];
    }
}

/// One pixel of `bytes`, low byte first, at an address that may not be
/// aligned.
///
/// INPUTS:
/// - `at` - where the pixel is.
/// - `bytes` - how many bytes it takes.
pub inline fn load(at: [*]const u8, bytes: u32) u32 {
    return switch (bytes) {
        1 => at[0],
        2 => @as(u32, at[0]) | @as(u32, at[1]) << 8,
        3 => @as(u32, at[0]) | @as(u32, at[1]) << 8 | @as(u32, at[2]) << 16,
        else => @as(u32, at[0]) | @as(u32, at[1]) << 8 | @as(u32, at[2]) << 16 | @as(u32, at[3]) << 24,
    };
}

/// One pixel of `bytes` written, low byte first, at an address that may
/// not be aligned.
///
/// INPUTS:
/// - `at` - where the pixel goes.
/// - `bytes` - how many bytes it takes.
/// - `value` - the pixel, right-aligned in the word.
pub inline fn store(at: [*]u8, bytes: u32, value: u32) void {
    at[0] = @truncate(value);
    if (bytes > 1) at[1] = @truncate(value >> 8);
    if (bytes > 2) at[2] = @truncate(value >> 16);
    if (bytes > 3) at[3] = @truncate(value >> 24);
}

/// A row stretched: `count` pixels written at `to`, the i-th taken from
/// the source column `first + (start + i) * src_w / dest_w`, walked with
/// a running remainder instead of a division per pixel.
///
/// `start` is how far into the whole stretched row this piece begins, so
/// a row cut by a clip still takes each pixel from where the whole row
/// would have.
///
/// INPUTS:
/// - `to` - where the stretched row goes.
/// - `from_row` - the source row.
/// - `bytes` - how many bytes a pixel takes.
/// - `count` - how many pixels to write.
/// - `first` - the source column the whole row starts at.
/// - `start` - how far into the whole stretched row this piece begins.
/// - `src_w` - how wide the source rectangle is.
/// - `dest_w` - how wide the stretched one is.
pub fn stretch(to: [*]u8, from_row: [*]const u8, bytes: u32, count: usize, first: i32, start: i32, src_w: i32, dest_w: i32) void {
    const top = start * src_w;
    var sx: i32 = first + @divTrunc(top, dest_w);
    var rem: i32 = @mod(top, dest_w);
    const aligned16 = bytes == 2 and (@intFromPtr(to) | @intFromPtr(from_row)) & 1 == 0;
    const aligned32 = bytes == 4 and (@intFromPtr(to) | @intFromPtr(from_row)) & 3 == 0;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const s: usize = @intCast(sx);
        if (aligned16) {
            const t: [*]u16 = @ptrCast(@alignCast(to));
            const f: [*]const u16 = @ptrCast(@alignCast(from_row));
            t[i] = f[s];
        } else if (aligned32) {
            const t: [*]u32 = @ptrCast(@alignCast(to));
            const f: [*]const u32 = @ptrCast(@alignCast(from_row));
            t[i] = f[s];
        } else {
            store(to + i * bytes, bytes, load(from_row + s * bytes, bytes));
        }
        rem += src_w;
        while (rem >= dest_w) {
            rem -= dest_w;
            sx += 1;
        }
    }
}

// --- tests -------------------------------------------------------------------

const testing = @import("std").testing;

test "fill writes exactly the pixels asked for, at every alignment" {
    for ([_]u32{ 1, 2, 3, 4 }) |bytes| {
        var start: usize = 0;
        while (start < 8) : (start += 1) {
            var count: usize = 0;
            while (count < 13) : (count += 1) {
                var buf: [96]u8 align(4) = @splat(0xEE);
                const value: u32 = 0x44332211;
                fill(@as([*]u8, &buf) + start, bytes, count, value);
                for (buf, 0..) |b, i| {
                    const lo = start;
                    const hi = start + count * bytes;
                    if (i < lo or i >= hi) {
                        try testing.expectEqual(@as(u8, 0xEE), b);
                    } else {
                        const k: u5 = @intCast(((i - lo) % bytes) * 8);
                        try testing.expectEqual(@as(u8, @truncate(value >> k)), b);
                    }
                }
            }
        }
    }
}

test "copy and copyBack move every byte, overlapping or not" {
    var src: [64]u8 = undefined;
    for (&src, 0..) |*b, i| b.* = @intCast(i + 1);
    var a: usize = 0;
    while (a < 4) : (a += 1) {
        var b: usize = 0;
        while (b < 4) : (b += 1) {
            var len: usize = 0;
            while (len < 40) : (len += 1) {
                var dst: [64]u8 align(4) = @splat(0);
                copy(@as([*]u8, &dst) + a, @as([*]const u8, &src) + b, len);
                try testing.expectEqualSlices(u8, src[b .. b + len], dst[a .. a + len]);
                try testing.expectEqual(@as(u8, 0), dst[a + len]);
            }
        }
    }
    // Overlapping, both ways, the way a blit moving within one surface
    // would.
    var shift: usize = 1;
    while (shift < 9) : (shift += 1) {
        var buf: [64]u8 align(4) = src;
        copyBack(@as([*]u8, &buf) + shift, &buf, 40);
        try testing.expectEqualSlices(u8, src[0..40], buf[shift .. shift + 40]);
        buf = src;
        copy(&buf, @as([*]const u8, &buf) + shift, 40);
        try testing.expectEqualSlices(u8, src[shift .. shift + 40], buf[0..40]);
    }
}

test "stretch takes each pixel from where the whole row would" {
    var src: [16]u16 = undefined;
    for (&src, 0..) |*p, i| p.* = @intCast(0x100 + i);
    // Ten across to twenty-three, all of it and then a piece cut out of
    // the middle, which must agree with the whole row where they overlap.
    var whole: [23]u16 = undefined;
    stretch(@ptrCast(&whole), @ptrCast(&src), 2, 23, 3, 0, 10, 23);
    for (whole, 0..) |p, x| {
        const want = 3 + @divTrunc(@as(i32, @intCast(x)) * 10, 23);
        try testing.expectEqual(src[@intCast(want)], p);
    }
    var part: [9]u16 = undefined;
    stretch(@ptrCast(&part), @ptrCast(&src), 2, 9, 3, 7, 10, 23);
    try testing.expectEqualSlices(u16, whole[7..16], &part);

    // Three bytes a pixel takes the byte path and says the same.
    var src3: [30]u8 = undefined;
    for (&src3, 0..) |*b, i| b.* = @intCast(i);
    var out3: [23 * 3]u8 = undefined;
    stretch(&out3, &src3, 3, 23, 0, 0, 10, 23);
    for (0..23) |x| {
        const s: usize = @intCast(@divTrunc(@as(i32, @intCast(x)) * 10, 23));
        try testing.expectEqualSlices(u8, src3[s * 3 .. s * 3 + 3], out3[x * 3 .. x * 3 + 3]);
    }
}
