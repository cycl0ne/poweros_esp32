// SPDX-License-Identifier: MPL-2.0
//! Copying and filling memory a word at a time: the loops `CopyMem`,
//! `CopyMemQuick` and `SetMem` run, and the kernel's memcpy, memmove and
//! memset (libc.zig). Every `@memcpy`, `@memset` and struct copy the
//! compiler leaves to a call ends here: the kernel's directly, a
//! program's through exec's jump table (sdk/libs/exec/libc.zig).
//!
//! **Why exec's own.** compiler_rt's memcpy stores through pointers it
//! takes as unaligned, and on a RISC-V core without fast misaligned
//! access - the VisionFive 2's U74 - each of those is a byte store; its
//! memset is a byte loop.
//!
//! **What the CPU can do decides the loop**, at compile time, from the
//! kernel's target: the kernel is built for each board.
//! - Two addresses as far from a word boundary as each other: bytes up to
//!   the boundary, then whole words, four at a time.
//! - Two that are not: a CPU that loads a word from any address at full
//!   speed (`misaligned_fast`) does that. Any other loads aligned words
//!   and shifts each two into the one to store, so no load or store is
//!   misaligned, and no load reaches a word without a byte of the copy in
//!   it - past the end of a page, say.
//! - Less than two words: a byte at a time.
//!
//! **No loop here may become a call.** LLVM takes a loop that copies or
//! fills for a memcpy or memset and calls that instead - here, itself. An
//! empty `asm volatile` that clobbers memory in every loop (`barrier`)
//! shows it the loop does more; it costs no instruction.

const std = @import("std");
const builtin = @import("builtin");

const Word = usize;
const word_bytes = @sizeOf(Word);
const word_mask = word_bytes - 1;
const Shift = std.math.Log2Int(Word);

/// Below this many bytes a copy or a fill goes a byte at a time: what it
/// takes to reach a word boundary would be most of it.
const word_least = 2 * word_bytes;

/// Whether the CPU loads a word from any address as fast as from an
/// aligned one. Where it does not, a misaligned load is slow - split, or
/// trapped and done by the firmware - or not there at all.
pub const misaligned_fast = switch (builtin.cpu.arch) {
    .x86, .x86_64 => true,
    .aarch64, .aarch64_be => !std.Target.aarch64.featureSetHas(builtin.cpu.features, .strict_align),
    .riscv32, .riscv64 => std.Target.riscv.featureSetHas(builtin.cpu.features, .unaligned_scalar_mem),
    else => false,
};

/// Copies `len` bytes from `source` to `dest`, however the two overlap.
pub fn move(dest: [*]u8, source: [*]const u8, len: usize) void {
    // dest at or below source, or past its end: from the first byte up.
    if (@intFromPtr(dest) -% @intFromPtr(source) >= len)
        forward(dest, source, len)
    else
        backward(dest, source, len);
}

/// Copies `len` bytes from `source` to `dest` from the first byte up:
/// right for two areas apart, and for an overlap with `dest` below.
pub fn forward(dest: [*]u8, source: [*]const u8, len: usize) void {
    forwardWith(misaligned_fast, dest, source, len);
}

/// Copies `len` bytes from `source` to `dest` from the last byte down:
/// right for an overlap with `dest` above.
pub fn backward(dest: [*]u8, source: [*]const u8, len: usize) void {
    backwardWith(misaligned_fast, dest, source, len);
}

/// Fills `len` bytes from `dest` on with `value`.
pub fn fill(dest: [*]u8, value: u8, len: usize) void {
    @setRuntimeSafety(false);
    var to = dest;
    var left = len;
    if (left >= word_least) {
        while (@intFromPtr(to) & word_mask != 0) : (left -= 1) {
            barrier();
            to[0] = value;
            to += 1;
        }
        // The byte in every byte of a word.
        const pattern = @as(Word, value) * (std.math.maxInt(Word) / 0xFF);
        const words: [*]Word = @ptrCast(@alignCast(to));
        const count = left / word_bytes;
        var i: usize = 0;
        while (i + 4 <= count) : (i += 4) {
            barrier();
            words[i] = pattern;
            words[i + 1] = pattern;
            words[i + 2] = pattern;
            words[i + 3] = pattern;
        }
        while (i < count) : (i += 1) {
            barrier();
            words[i] = pattern;
        }
        to += count * word_bytes;
        left -= count * word_bytes;
    }
    while (left != 0) : (left -= 1) {
        barrier();
        to[0] = value;
        to += 1;
    }
}

/// `forward` with misaligned word loads or without: the tests run both.
pub fn forwardWith(comptime misaligned: bool, dest: [*]u8, source: [*]const u8, len: usize) void {
    @setRuntimeSafety(false);
    var to = dest;
    var from = source;
    var left = len;
    if (left >= word_least) {
        while (@intFromPtr(to) & word_mask != 0) : (left -= 1) {
            barrier();
            to[0] = from[0];
            to += 1;
            from += 1;
        }
        const words: [*]Word = @ptrCast(@alignCast(to));
        const count = left / word_bytes;
        if (@intFromPtr(from) & word_mask == 0)
            copyUp(words, @as([*]const Word, @ptrCast(@alignCast(from))), count)
        else if (misaligned)
            copyUp(words, @as([*]align(1) const Word, @ptrCast(from)), count)
        else
            shiftUp(words, from, count);
        to += count * word_bytes;
        from += count * word_bytes;
        left -= count * word_bytes;
    }
    while (left != 0) : (left -= 1) {
        barrier();
        to[0] = from[0];
        to += 1;
        from += 1;
    }
}

/// `backward` with misaligned word loads or without: the tests run both.
pub fn backwardWith(comptime misaligned: bool, dest: [*]u8, source: [*]const u8, len: usize) void {
    @setRuntimeSafety(false);
    // Both ends, moving down.
    var to = dest + len;
    var from = source + len;
    var left = len;
    if (left >= word_least) {
        while (@intFromPtr(to) & word_mask != 0) : (left -= 1) {
            barrier();
            to -= 1;
            from -= 1;
            to[0] = from[0];
        }
        const count = left / word_bytes;
        to -= count * word_bytes;
        from -= count * word_bytes;
        left -= count * word_bytes;
        const words: [*]Word = @ptrCast(@alignCast(to));
        if (@intFromPtr(from) & word_mask == 0)
            copyDown(words, @as([*]const Word, @ptrCast(@alignCast(from))), count)
        else if (misaligned)
            copyDown(words, @as([*]align(1) const Word, @ptrCast(from)), count)
        else
            shiftDown(words, from, count);
    }
    while (left != 0) : (left -= 1) {
        barrier();
        to -= 1;
        from -= 1;
        to[0] = from[0];
    }
}

/// Copies `count` words up. Each round loads all it stores before it
/// stores, so an overlap with `to` below `from` comes out right.
inline fn copyUp(to: [*]Word, from: anytype, count: usize) void {
    @setRuntimeSafety(false);
    var i: usize = 0;
    while (i + 4 <= count) : (i += 4) {
        barrier();
        const a = from[i];
        const b = from[i + 1];
        const c = from[i + 2];
        const d = from[i + 3];
        to[i] = a;
        to[i + 1] = b;
        to[i + 2] = c;
        to[i + 3] = d;
    }
    while (i < count) : (i += 1) {
        barrier();
        to[i] = from[i];
    }
}

/// Copies `count` words down, the last first: an overlap with `to` above
/// `from` comes out right.
inline fn copyDown(to: [*]Word, from: anytype, count: usize) void {
    @setRuntimeSafety(false);
    var i = count;
    while (i >= 4) : (i -= 4) {
        barrier();
        const a = from[i - 1];
        const b = from[i - 2];
        const c = from[i - 3];
        const d = from[i - 4];
        to[i - 1] = a;
        to[i - 2] = b;
        to[i - 3] = c;
        to[i - 4] = d;
    }
    while (i != 0) {
        barrier();
        i -= 1;
        to[i] = from[i];
    }
}

/// Copies `count` words up from `source`, which is not aligned, with
/// aligned loads: each word stored is the end of one aligned word and the
/// start of the next.
inline fn shiftUp(to: [*]Word, source: [*]const u8, count: usize) void {
    @setRuntimeSafety(false);
    const off = @intFromPtr(source) & word_mask;
    const shifts = Shifts.of(off);
    const from: [*]const Word = @ptrFromInt(@intFromPtr(source) - off);
    var low = from[0];
    var i: usize = 0;
    while (i + 4 <= count) : (i += 4) {
        barrier();
        const a = from[i + 1];
        const b = from[i + 2];
        const c = from[i + 3];
        const d = from[i + 4];
        to[i] = shifts.merge(low, a);
        to[i + 1] = shifts.merge(a, b);
        to[i + 2] = shifts.merge(b, c);
        to[i + 3] = shifts.merge(c, d);
        low = d;
    }
    while (i < count) : (i += 1) {
        barrier();
        const high = from[i + 1];
        to[i] = shifts.merge(low, high);
        low = high;
    }
}

/// `shiftUp` the last word first.
inline fn shiftDown(to: [*]Word, source: [*]const u8, count: usize) void {
    @setRuntimeSafety(false);
    const off = @intFromPtr(source) & word_mask;
    const shifts = Shifts.of(off);
    const from: [*]const Word = @ptrFromInt(@intFromPtr(source) - off);
    // The aligned word the copy ends in: source is not aligned, so it
    // holds a byte of it.
    var high = from[count];
    var i = count;
    while (i >= 4) : (i -= 4) {
        barrier();
        const a = from[i - 1];
        const b = from[i - 2];
        const c = from[i - 3];
        const d = from[i - 4];
        to[i - 1] = shifts.merge(a, high);
        to[i - 2] = shifts.merge(b, a);
        to[i - 3] = shifts.merge(c, b);
        to[i - 4] = shifts.merge(d, c);
        high = d;
    }
    while (i != 0) {
        barrier();
        i -= 1;
        const low = from[i];
        to[i] = shifts.merge(low, high);
        high = low;
    }
}

/// How two aligned words become the one that starts `off` bytes into the
/// first.
const Shifts = struct {
    /// Towards the first's end, in bits.
    first: Shift,
    /// Towards the second's start.
    second: Shift,

    /// `off` from 1 to a word less one: both shifts are less than a word.
    inline fn of(off: usize) Shifts {
        @setRuntimeSafety(false);
        return .{ .first = @intCast(off * 8), .second = @intCast(@bitSizeOf(Word) - off * 8) };
    }

    inline fn merge(shifts: Shifts, low: Word, high: Word) Word {
        return switch (builtin.cpu.arch.endian()) {
            .little => (low >> shifts.first) | (high << shifts.second),
            .big => (low << shifts.first) | (high >> shifts.second),
        };
    }
};

/// Keeps LLVM from taking the loop it is in for a copy or a fill.
inline fn barrier() void {
    asm volatile ("" ::: .{ .memory = true });
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

/// Every offset of `dest` and `source` within a word and a half, every
/// length to past four rounds of four words, and longer ones: `copy`
/// copies what a byte loop copies, and not a byte around it.
fn expectCopies(comptime copy: fn ([*]u8, [*]const u8, usize) void) !void {
    var source: [512]u8 align(16) = undefined;
    for (&source, 0..) |*byte, i| byte.* = @truncate(i *% 131 +% 17);
    var dest: [512]u8 align(16) = undefined;
    for (0..12) |to| for (0..12) |from| {
        for ([_]usize{ 0, 1, 7, 8, 15, 16, 17, 23, 31, 32, 33, 63, 64, 65, 127, 136, 160, 250, 333, 480 }) |len| {
            @memset(&dest, 0xEE);
            copy(dest[to..].ptr, source[from..].ptr, len);
            try testing.expectEqualSlices(u8, source[from..][0..len], dest[to..][0..len]);
            for (dest[0..to]) |byte| try testing.expectEqual(@as(u8, 0xEE), byte);
            for (dest[to + len ..]) |byte| try testing.expectEqual(@as(u8, 0xEE), byte);
        }
    };
}

fn forwardAligned(dest: [*]u8, source: [*]const u8, len: usize) void {
    forwardWith(false, dest, source, len);
}
fn forwardMisaligned(dest: [*]u8, source: [*]const u8, len: usize) void {
    forwardWith(true, dest, source, len);
}
fn backwardAligned(dest: [*]u8, source: [*]const u8, len: usize) void {
    backwardWith(false, dest, source, len);
}
fn backwardMisaligned(dest: [*]u8, source: [*]const u8, len: usize) void {
    backwardWith(true, dest, source, len);
}

test "a copy up or down, by shifts or by misaligned loads, copies the bytes and no more" {
    try expectCopies(forwardAligned);
    try expectCopies(forwardMisaligned);
    try expectCopies(backwardAligned);
    try expectCopies(backwardMisaligned);
    try expectCopies(move);
}

test "move is right for any overlap" {
    var start: [400]u8 align(16) = undefined;
    for (&start, 0..) |*byte, i| byte.* = @truncate(i *% 89 +% 3);
    var buffer: [400]u8 align(16) = undefined;
    var expected: [400]u8 = undefined;
    for (0..9) |base| for (0..41) |distance| for ([_]usize{ 1, 9, 16, 17, 40, 67, 200, 333 }) |len| {
        // dest above source by distance, then below.
        for ([_]bool{ true, false }) |up| {
            const from = if (up) base else base + distance;
            const to = if (up) base + distance else base;
            buffer = start;
            expected = start;
            // What a byte loop through a copy of the source gives.
            var through: [400]u8 = undefined;
            @memcpy(through[0..len], start[from..][0..len]);
            @memcpy(expected[to..][0..len], through[0..len]);
            move(buffer[to..].ptr, buffer[from..].ptr, len);
            try testing.expectEqualSlices(u8, &expected, &buffer);
        }
    };
}

test "a fill fills the bytes and no more" {
    var dest: [300]u8 align(16) = undefined;
    for (0..12) |to| for ([_]usize{ 0, 1, 7, 15, 16, 17, 31, 32, 33, 64, 65, 100, 257 }) |len| {
        @memset(&dest, 0xEE);
        fill(dest[to..].ptr, 0x5C, len);
        for (dest[to..][0..len]) |byte| try testing.expectEqual(@as(u8, 0x5C), byte);
        for (dest[0..to]) |byte| try testing.expectEqual(@as(u8, 0xEE), byte);
        for (dest[to + len ..]) |byte| try testing.expectEqual(@as(u8, 0xEE), byte);
    };
    fill(&dest, 0, dest.len);
    for (dest) |byte| try testing.expectEqual(@as(u8, 0), byte);
}

test "a program's memcpy, memmove and memset do less than two words themselves" {
    // Less than two words never reaches exec, so no SysBase is needed.
    const libc = @import("sdk").exec.libc;
    var start: [40]u8 = undefined;
    for (&start, 0..) |*byte, i| byte.* = @truncate(i *% 37 +% 1);
    var buffer: [40]u8 = undefined;
    var expected: [40]u8 = undefined;
    for (0..2 * word_bytes) |len| for (0..8) |distance| for ([_]bool{ true, false }) |up| {
        const from: usize = if (up) 4 else 4 + distance;
        const to: usize = if (up) 4 + distance else 4;
        buffer = start;
        expected = start;
        var through: [40]u8 = undefined;
        @memcpy(through[0..len], start[from..][0..len]);
        @memcpy(expected[to..][0..len], through[0..len]);
        _ = libc.memmove(buffer[to..].ptr, buffer[from..].ptr, len);
        try testing.expectEqualSlices(u8, &expected, &buffer);
        buffer = start;
        _ = libc.memcpy(buffer[20..].ptr, start[from..].ptr, len);
        try testing.expectEqualSlices(u8, start[from..][0..len], buffer[20..][0..len]);
        try testing.expectEqualSlices(u8, start[20 + len ..], buffer[20 + len ..]);
        buffer = start;
        _ = libc.memset(buffer[to..].ptr, 0x1A5, len);
        for (buffer[to..][0..len]) |byte| try testing.expectEqual(@as(u8, 0xA5), byte);
        try testing.expectEqualSlices(u8, start[to + len ..], buffer[to + len ..]);
    };
}
