// SPDX-License-Identifier: MIT
//! VP8's boolean entropy decoder (RFC 6386 7): bools read at a
//! probability out of 256, from a window of the data a word wide. Past
//! the end of its data it reads zeros, as libvpx does.

const tables = @import("tables.zig");

const Word = usize;
const word_bits = @bitSizeOf(Word);

pub const Bool = struct {
    data: []const u8 = &.{},
    pos: usize = 0,
    /// The value's bits at the top, the comparison's eight first.
    value: Word = 0,
    /// Bits in the window below those eight; under 0, it is filled.
    count: i32 = -8,
    range: u32 = 255,

    pub fn init(data: []const u8) Bool {
        var b: Bool = .{ .data = data };
        b.fill();
        return b;
    }

    fn fill(b: *Bool) void {
        var shift: i32 = word_bits - 8 - (b.count + 8);
        while (shift >= 0) : (shift -= 8) {
            if (b.pos >= b.data.len) {
                // Zeros from here on: enough of them never to fill again.
                b.count += 0x4000_0000;
                return;
            }
            b.value |= @as(Word, b.data[b.pos]) << @intCast(shift);
            b.pos += 1;
            b.count += 8;
        }
    }

    /// A bool whose probability of being 0 is `prob` / 256.
    pub inline fn read(b: *Bool, prob: u8) u1 {
        const split: u32 = 1 + (((b.range - 1) * prob) >> 8);
        if (b.count < 0) b.fill();
        const big = @as(Word, split) << (word_bits - 8);
        var bit: u1 = 0;
        if (b.value >= big) {
            b.range -= split;
            b.value -= big;
            bit = 1;
        } else b.range = split;
        const shift: u5 = @clz(@as(u8, @intCast(b.range)));
        b.range <<= shift;
        b.value <<= shift;
        b.count -= shift;
        return bit;
    }

    pub inline fn flag(b: *Bool) bool {
        return b.read(128) == 1;
    }

    /// An unsigned `n`-bit literal, its highest bit first.
    pub fn literal(b: *Bool, n: u5) u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | b.read(128);
        return v;
    }

    /// A flag, then if it is set an `n`-bit magnitude and its sign; 0
    /// without.
    pub fn maybeSigned(b: *Bool, n: u5) i32 {
        if (!b.flag()) return 0;
        const v: i32 = @intCast(b.literal(n));
        return if (b.flag()) -v else v;
    }

    /// A value read by `tree` with its nodes' probabilities.
    pub inline fn tree(b: *Bool, t: tables.Tree, probs: []const u8) u8 {
        var i: i32 = 0;
        while (true) {
            const u: usize = @intCast(i);
            i = t[u + b.read(probs[u >> 1])];
            if (i <= 0) return @intCast(-i);
        }
    }

    /// Whether more was read than the data holds (libvpx's
    /// vp8dx_bool_error).
    pub fn overrun(b: *const Bool) bool {
        return b.count > word_bits and b.count < 0x4000_0000;
    }
};

const testing = @import("std").testing;

test "bools read back as they were written" {
    // A minimal writer (RFC 6386 7.3) to make the data.
    const Writer = struct {
        out: [256]u8 = undefined,
        len: usize = 0,
        range: u32 = 255,
        bottom: u32 = 0,
        bit_count: i32 = 24,

        fn addOne(w: *@This()) void {
            var i = w.len;
            while (i > 0) {
                i -= 1;
                if (w.out[i] == 255) {
                    w.out[i] = 0;
                } else {
                    w.out[i] += 1;
                    return;
                }
            }
        }
        fn put(w: *@This(), prob: u8, bit: bool) void {
            const split: u32 = 1 + (((w.range - 1) * prob) >> 8);
            if (bit) {
                w.bottom +%= split;
                w.range -= split;
            } else w.range = split;
            while (w.range < 128) {
                w.range <<= 1;
                if (w.bottom & (1 << 31) != 0) w.addOne();
                w.bottom <<= 1;
                w.bit_count -= 1;
                if (w.bit_count == 0) {
                    w.out[w.len] = @intCast(w.bottom >> 24);
                    w.len += 1;
                    w.bottom &= (1 << 24) - 1;
                    w.bit_count = 8;
                }
            }
        }
        fn flush(w: *@This()) void {
            var c = w.bit_count;
            var v = w.bottom;
            if (v & (@as(u32, 1) << @intCast(32 - c)) != 0) w.addOne();
            v <<= @intCast(c & 7);
            c >>= 3;
            while (c > 0) : (c -= 1) v <<= 8;
            for (0..4) |_| {
                w.out[w.len] = @intCast(v >> 24);
                w.len += 1;
                v <<= 8;
            }
        }
    };
    var w: Writer = .{};
    var seed: u32 = 12345;
    var probs: [400]u8 = undefined;
    var bits: [400]bool = undefined;
    for (&probs, &bits) |*p, *bit| {
        seed = seed *% 1103515245 +% 12345;
        p.* = @intCast(1 + (seed >> 16) % 255);
        bit.* = ((seed >> 8) & 0xFF) >= p.*;
        w.put(p.*, bit.*);
    }
    w.flush();
    var b = Bool.init(w.out[0..w.len]);
    for (probs, bits) |p, bit| try testing.expectEqual(bit, b.read(p) == 1);
    try testing.expect(!b.overrun());
}
