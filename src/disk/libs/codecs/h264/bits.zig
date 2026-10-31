// SPDX-License-Identifier: MIT
//! Reading an H.264 RBSP bit by bit: fixed-length fields, Exp-Golomb
//! codes (9.1) and where the payload ends.
//!
//! The bytes are a NAL unit's payload with its emulation prevention bytes
//! already taken out (nal.zig). A read past the end yields zeros and is
//! remembered (`overrun`), so a damaged unit is found by its caller rather
//! than by a fault.

pub const Error = error{
    /// The stream says something the standard does not allow.
    Corrupt,
    /// A feature this decoder leaves out.
    Unsupported,
    /// Memory ran out.
    NoMemory,
};

pub const Bits = struct {
    data: []const u8,
    /// The next bit, counted from the first byte's highest bit.
    pos: usize = 0,

    pub fn init(data: []const u8) Bits {
        return .{ .data = data };
    }

    /// The 64 bits from `pos` on, zeros past the end.
    inline fn window(b: *const Bits) u64 {
        const byte = b.pos >> 3;
        var v: u64 = 0;
        if (byte + 8 <= b.data.len) {
            const p = b.data[byte..][0..8];
            v = @as(u64, p[0]) << 56 | @as(u64, p[1]) << 48 | @as(u64, p[2]) << 40 | @as(u64, p[3]) << 32 |
                @as(u64, p[4]) << 24 | @as(u64, p[5]) << 16 | @as(u64, p[6]) << 8 | p[7];
        } else {
            var i: usize = 0;
            while (i < 8) : (i += 1) {
                v <<= 8;
                if (byte + i < b.data.len) v |= b.data[byte + i];
            }
        }
        return v << @intCast(b.pos & 7);
    }

    /// The next `n` bits (at most 32) without moving.
    pub inline fn peek(b: *const Bits, n: u6) u32 {
        if (n == 0) return 0;
        return @intCast(b.window() >> @intCast(64 - @as(u7, n)));
    }

    pub inline fn skip(b: *Bits, n: usize) void {
        b.pos += n;
    }

    /// u(n): the next `n` bits, at most 32.
    pub inline fn u(b: *Bits, n: u6) u32 {
        const v = b.peek(n);
        b.pos += n;
        return v;
    }

    pub inline fn flag(b: *Bits) bool {
        return b.u(1) != 0;
    }

    /// ue(v): an unsigned Exp-Golomb code, up to 2^32 - 2.
    pub fn ue(b: *Bits) Error!u32 {
        const w = b.window();
        const zeros: u7 = @clz(w);
        if (zeros > 31) return error.Corrupt;
        const len: u7 = 2 * zeros + 1;
        b.pos += len;
        if (zeros == 0) return 0;
        const v: u64 = w >> @intCast(64 - len);
        return @intCast(v - 1);
    }

    /// ue(v) no larger than `most`.
    pub fn ueMax(b: *Bits, most: u32) Error!u32 {
        const v = try b.ue();
        if (v > most) return error.Corrupt;
        return v;
    }

    /// se(v): a signed Exp-Golomb code.
    pub fn se(b: *Bits) Error!i32 {
        const k = try b.ue();
        const half: i64 = @intCast((@as(u64, k) + 1) >> 1);
        return @intCast(if (k & 1 != 0) half else -half);
    }

    /// se(v) within [lo, hi].
    pub fn seRange(b: *Bits, lo: i32, hi: i32) Error!i32 {
        const v = try b.se();
        if (v < lo or v > hi) return error.Corrupt;
        return v;
    }

    /// te(v) with `range` its largest value (9.1.1).
    pub fn te(b: *Bits, range: u32) Error!u32 {
        if (range > 1) return b.ue();
        return @intFromBool(!b.flag());
    }

    pub fn byteAligned(b: *const Bits) bool {
        return b.pos & 7 == 0;
    }

    pub fn alignByte(b: *Bits) void {
        b.pos = (b.pos + 7) & ~@as(usize, 7);
    }

    /// Whether a read went past the end.
    pub fn overrun(b: *const Bits) bool {
        return b.pos > b.data.len * 8;
    }

    pub fn bitsLeft(b: *const Bits) isize {
        return @as(isize, @intCast(b.data.len * 8)) - @as(isize, @intCast(b.pos));
    }

    /// more_rbsp_data(): whether anything but the stop bit and the zeros
    /// after it is left.
    pub fn moreRbspData(b: *const Bits) bool {
        var end = b.data.len;
        while (end > 0 and b.data[end - 1] == 0) end -= 1;
        if (end == 0) return false;
        const last = b.data[end - 1];
        const stop = (end - 1) * 8 + (7 - @as(usize, @ctz(last)));
        return b.pos < stop;
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "fixed fields, Exp-Golomb codes and the end of the payload" {
    // 1 | 010 | 011 | 00100 | 00101 | 1 (stop) ...
    // ue: 0, 1, 2, 3, 4 -> se of 4 is -2
    const data = [_]u8{ 0b1010_0110, 0b0100_0010, 0b1100_0000 };
    var b = Bits.init(&data);
    try testing.expectEqual(@as(u32, 0), try b.ue());
    try testing.expectEqual(@as(u32, 1), try b.ue());
    try testing.expectEqual(@as(u32, 2), try b.ue());
    try testing.expectEqual(@as(u32, 3), try b.ue());
    try testing.expect(b.moreRbspData());
    try testing.expectEqual(@as(i32, -2), try b.se());
    try testing.expect(!b.moreRbspData());
    try testing.expect(!b.overrun());
    b.skip(30);
    try testing.expect(b.overrun());
    var c = Bits.init(&data);
    try testing.expectEqual(@as(u32, 0b1010), c.u(4));
    try testing.expectEqual(@as(u32, 0b0110_0100_0010_1), c.u(13));
}
