// SPDX-License-Identifier: MIT
//! The symbol decoder (8.2): a range decoder reading symbols by their
//! CDFs and adapting the CDFs to what it read. The value's 16 bits sit at
//! the top of a 64-bit window with the next bits, inverted, below them;
//! past the data the bits are zeros, inverted ones, as the specification
//! pads them.

pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,
    /// SymbolValue in bits 63 to 48, `cnt` more bits below.
    dif: u64 = 0,
    rng: u32 = 0x8000,
    cnt: i32 = -15,
    /// Whether CDFs adapt (disable_cdf_update clear).
    update: bool = true,

    pub fn init(data: []const u8, update: bool) Reader {
        var r: Reader = .{ .data = data, .update = update };
        r.refill();
        return r;
    }

    fn refill(r: *Reader) void {
        var c = r.cnt;
        var d = r.dif;
        while (c <= 40) : (c += 8) {
            const byte: u64 = if (r.pos < r.data.len) r.data[r.pos] else 0;
            r.pos += 1;
            d |= (byte ^ 0xFF) << @intCast(40 - c);
        }
        r.dif = d;
        r.cnt = c;
    }

    inline fn renormalize(r: *Reader, rng: u32) void {
        const d: u5 = @intCast(@clz(rng) - 16);
        r.rng = rng << d;
        r.dif <<= d;
        r.cnt -= d;
        if (r.cnt < 16) r.refill();
    }

    /// A symbol by `cdf`, a pointer to an array of the cumulative
    /// probabilities and the counter.
    pub inline fn symbol(r: *Reader, cdf: anytype) u32 {
        const N = @typeInfo(@TypeOf(cdf.*)).array.len - 1;
        const c: u32 = @intCast(r.dif >> 48);
        const rr = r.rng >> 8;
        var cur: u32 = r.rng;
        var prev: u32 = cur;
        var s: u32 = 0;
        while (true) : (s += 1) {
            prev = cur;
            if (s == N - 1) {
                cur = 0;
                break;
            }
            cur = ((rr * ((32768 - @as(u32, cdf[s])) >> 6)) >> 1) + 4 * (N - 1 - s);
            if (c >= cur) break;
        }
        r.dif -= @as(u64, cur) << 48;
        r.renormalize(prev - cur);
        if (r.update) adapt(cdf, s);
        return s;
    }

    /// read_bool: a bit at even odds.
    pub inline fn boolean(r: *Reader) u1 {
        const c: u32 = @intCast(r.dif >> 48);
        const cur = ((r.rng >> 8) << 7) + 4;
        if (c >= cur) {
            r.dif -= @as(u64, cur) << 48;
            r.renormalize(r.rng - cur);
            return 0;
        }
        r.renormalize(cur);
        return 1;
    }

    /// Whether the tile ended as exit_symbol requires (8.2.4): no more
    /// than 14 padding bits used, then a one bit and zeros to its end.
    pub fn finished(r: *const Reader) bool {
        const len: i64 = @intCast(r.data.len);
        const used: i64 = 8 * @as(i64, @intCast(r.pos)) - r.cnt;
        if (8 * len - used < -14) return false;
        const trailing = used - 15;
        if (trailing < 0 or trailing >= 8 * len) return false;
        const t: usize = @intCast(trailing);
        const byte = r.data[t >> 3];
        const bit: u3 = @intCast(7 - (t & 7));
        if ((byte >> bit) & 1 != 1) return false;
        if (byte & ((@as(u8, 1) << bit) - 1) != 0) return false;
        for (r.data[(t >> 3) + 1 ..]) |rest| {
            if (rest != 0) return false;
        }
        return true;
    }

    /// L(n): `n` bits at even odds, the most significant first.
    pub fn literal(r: *Reader, n: u32) u32 {
        var x: u32 = 0;
        for (0..n) |_| x = (x << 1) | r.boolean();
        return x;
    }
};

fn adapt(cdf: anytype, s: u32) void {
    const N = @typeInfo(@TypeOf(cdf.*)).array.len - 1;
    const count = cdf[N];
    const log2n: u4 = comptime if (N >= 4) 2 else if (N >= 2) 1 else 0;
    const rate: u4 = 3 + @as(u4, @intFromBool(count > 15)) + @intFromBool(count > 31) + log2n;
    inline for (0..N - 1) |i| {
        if (i < s) {
            cdf[i] -= cdf[i] >> rate;
        } else {
            cdf[i] += (32768 - cdf[i]) >> rate;
        }
    }
    cdf[N] += @intFromBool(count < 32);
}
