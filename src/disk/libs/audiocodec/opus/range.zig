// SPDX-License-Identifier: MIT
//! Opus's range decoder (RFC 6716 4.1): the symbols of a frame read from
//! the front of its bytes, each by the range its probability takes, and
//! raw bits read from the back.
//!
//! **The state** is the range `rng` and the value `val` - the distance
//! from the top of the range to where the coded number lies - both 32
//! bits; when the range falls to 2^23 or less a byte comes in and both
//! move up by 8 bits. The bytes come in shifted by one bit, as the
//! encoder carries them; past the end they are zeros.
//!
//! **Raw bits** - a CELT frame's fine energy, its PVQ indices' low bits,
//! its signs - come from the end of the bytes backwards, least significant
//! first, and are counted with the rest: `tell` is the bits used so far,
//! `tellFrac` the same in eighths.
//!
//! **The final range** - `rng` once the frame is decoded - is what an
//! encoder ended with too: the test vectors give it for each packet, which
//! checks that every symbol was read as it was written.

pub const Range = struct {
    bytes: []const u8,
    /// The bytes of the frame, of which `storage` count: the back ones a
    /// redundant frame takes are not this one's.
    storage: u32,
    offs: u32,
    end_offs: u32,
    end_window: u32,
    nend_bits: u32,
    /// The bits counted: those read and the 9 the state starts holding.
    nbits_total: i32,
    rng: u32,
    val: u32,
    ext: u32,
    rem: u32,
    /// A uint was out of its range: the frame is damaged.
    failed: bool,

    pub fn init(bytes: []const u8) Range {
        var r: Range = .{
            .bytes = bytes,
            .storage = @intCast(bytes.len),
            .offs = 0,
            .end_offs = 0,
            .end_window = 0,
            .nend_bits = 0,
            .nbits_total = 32 + 1 - ((32 - 7) / 8) * 8,
            .rng = 1 << 7,
            .val = 0,
            .ext = 0,
            .rem = 0,
            .failed = false,
        };
        r.rem = r.readByte();
        r.val = r.rng - 1 - (r.rem >> 1);
        r.normalize();
        return r;
    }

    fn readByte(r: *Range) u32 {
        if (r.offs >= r.storage) return 0;
        const byte = r.bytes[r.offs];
        r.offs += 1;
        return byte;
    }

    fn readByteFromEnd(r: *Range) u32 {
        if (r.end_offs >= r.storage) return 0;
        r.end_offs += 1;
        return r.bytes[r.storage - r.end_offs];
    }

    fn normalize(r: *Range) void {
        while (r.rng <= 1 << 23) {
            r.nbits_total += 8;
            r.rng <<= 8;
            const sym = r.rem;
            r.rem = r.readByte();
            const both = ((sym << 8) | r.rem) >> 1;
            r.val = ((r.val << 8) +% (255 & ~both)) & 0x7FFF_FFFF;
        }
    }

    /// Where the next symbol lies among `ft` equally likely steps; then
    /// `update` with its range.
    pub fn decode(r: *Range, ft: u32) u32 {
        r.ext = r.rng / ft;
        const s = r.val / r.ext;
        return ft - @min(s + 1, ft);
    }

    /// `decode` for a total of 2^bits.
    pub fn decodeBin(r: *Range, ftb: u5) u32 {
        r.ext = r.rng >> ftb;
        const s = r.val / r.ext;
        const ft = @as(u32, 1) << ftb;
        return ft - @min(s + 1, ft);
    }

    /// The symbol `decode` found takes [fl, fh) of `ft`.
    pub fn update(r: *Range, fl: u32, fh: u32, ft: u32) void {
        const s = r.ext *% (ft - fh);
        r.val -%= s;
        r.rng = if (fl > 0) r.ext *% (fh - fl) else r.rng -% s;
        r.normalize();
    }

    /// A bit that is 1 with the probability 1/2^logp.
    pub fn bitLogp(r: *Range, logp: u5) bool {
        const s = r.rng >> logp;
        const one = r.val < s;
        if (!one) r.val -= s;
        r.rng = if (one) s else r.rng - s;
        r.normalize();
        return one;
    }

    /// A symbol by an inverse cumulative table over 2^ftb.
    pub fn icdf(r: *Range, table: []const u8, ftb: u5) u32 {
        var s = r.rng;
        const d = r.val;
        const step = s >> ftb;
        var ret: u32 = 0;
        var t: u32 = s;
        while (true) {
            t = s;
            s = step *% table[ret];
            if (d >= s) break;
            ret += 1;
        }
        r.val = d - s;
        r.rng = t - s;
        r.normalize();
        return ret;
    }

    /// A number below `ft` (more than 1), equally likely: its top 8 bits
    /// by range, the rest raw.
    pub fn uint(r: *Range, total: u32) u32 {
        const top = total - 1;
        var ftb: u32 = ilog(top);
        if (ftb > 8) {
            ftb -= 8;
            const ft = (top >> @intCast(ftb)) + 1;
            const s = r.decode(ft);
            r.update(s, s + 1, ft);
            const t = (s << @intCast(ftb)) | r.bits(@intCast(ftb));
            if (t <= top) return t;
            r.failed = true;
            return top;
        }
        const s = r.decode(total);
        r.update(s, s + 1, total);
        return s;
    }

    /// `count` raw bits (up to 25) from the back.
    pub fn bits(r: *Range, count: u5) u32 {
        var window = r.end_window;
        var available = r.nend_bits;
        if (available < count) {
            while (true) {
                window |= r.readByteFromEnd() << @intCast(available);
                available += 8;
                if (available > 32 - 8) break;
            }
        }
        const ret = window & ((@as(u32, 1) << count) - 1);
        window >>= count;
        available -= count;
        r.end_window = window;
        r.nend_bits = available;
        r.nbits_total += count;
        return ret;
    }

    /// The bits used so far, rounded up.
    pub fn tell(r: *const Range) i32 {
        return r.nbits_total - @as(i32, @intCast(ilog(r.rng)));
    }

    /// The bits used so far in eighths.
    pub fn tellFrac(r: *const Range) u32 {
        const correction = [8]u32{ 35733, 38967, 42495, 46340, 50535, 55109, 60097, 65535 };
        const nbits: u32 = @as(u32, @bitCast(r.nbits_total)) << 3;
        const l = ilog(r.rng);
        const x = r.rng >> @intCast(l - 16);
        var b = (x >> 12) - 8;
        if (x > correction[b]) b += 1;
        return nbits - ((l << 3) + b);
    }
};

/// The bits a number needs: 0 for 0.
pub fn ilog(x: u32) u32 {
    return 32 - @as(u32, @clz(x));
}
