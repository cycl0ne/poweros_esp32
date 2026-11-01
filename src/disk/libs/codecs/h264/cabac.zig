// SPDX-License-Identifier: MIT
//! CABAC's arithmetic decoding engine (9.3.1.2, 9.3.3.2) and the
//! initialisation of its 1024 contexts (9.3.1.1).
//!
//! A context is a byte: its probability state times two, plus the value
//! of its most probable symbol. The engine keeps codIRange and
//! codIOffset as the standard does, and the bits still to come in a
//! 64-bit cache, so that a renormalisation of several bits is one shift.

const tables = @import("tables.zig");

pub const Engine = struct {
    data: []const u8,
    /// The next byte to load into `cache`.
    next: usize = 0,
    cache: u64 = 0,
    cache_bits: u32 = 0,
    range: u32 = 510,
    offset: u32 = 0,

    /// The engine started on `data` from its byte `at` (9.3.1.2): false
    /// when codIOffset comes out as 510 or 511, which the standard forbids.
    pub fn init(e: *Engine, data: []const u8, at: usize) bool {
        e.* = .{ .data = data, .next = at };
        e.range = 510;
        e.offset = e.take(9);
        return e.offset < 510;
    }

    fn refill(e: *Engine) void {
        while (e.cache_bits <= 56) {
            const byte: u64 = if (e.next < e.data.len) e.data[e.next] else 0;
            e.next += 1;
            e.cache |= byte << @intCast(56 - e.cache_bits);
            e.cache_bits += 8;
        }
    }

    inline fn take(e: *Engine, n: u32) u32 {
        if (e.cache_bits < n) e.refill();
        const v: u32 = @intCast(e.cache >> @intCast(64 - n));
        e.cache <<= @intCast(n);
        e.cache_bits -= n;
        return v;
    }

    /// DecodeDecision (9.3.3.2.1) with the context `ctx`.
    pub inline fn decision(e: *Engine, ctx: *u8) u1 {
        const state = ctx.* >> 1;
        var bin: u1 = @intCast(ctx.* & 1);
        const lps: u32 = tables.range_lps[state][(e.range >> 6) & 3];
        e.range -= lps;
        if (e.offset < e.range) {
            ctx.* = (@as(u8, @min(state + 1, 62)) << 1) | bin;
            if (e.range < 256) {
                e.range <<= 1;
                e.offset = (e.offset << 1) | e.take(1);
            }
        } else {
            e.offset -= e.range;
            e.range = lps;
            bin ^= 1;
            const mps: u8 = if (state == 0) bin else (ctx.* & 1);
            ctx.* = (tables.trans_lps[state] << 1) | mps;
            const n: u5 = @intCast(@clz(e.range) - 23);
            e.range <<= n;
            e.offset = (e.offset << n) | e.take(n);
        }
        return bin;
    }

    /// DecodeBypass (9.3.3.2.3).
    pub inline fn bypass(e: *Engine) u1 {
        e.offset = (e.offset << 1) | e.take(1);
        if (e.offset >= e.range) {
            e.offset -= e.range;
            return 1;
        }
        return 0;
    }

    /// DecodeTerminate (9.3.3.2.2.3).
    pub fn terminate(e: *Engine) u1 {
        e.range -= 2;
        if (e.offset >= e.range) return 1;
        if (e.range < 256) {
            e.range <<= 1;
            e.offset = (e.offset << 1) | e.take(1);
        }
        return 0;
    }

    /// The byte after the arithmetic code, once terminate gave 1: where
    /// an I_PCM macroblock's samples start, after its alignment bits.
    pub fn bytePosition(e: *const Engine) usize {
        const consumed_bits = e.next * 8 - e.cache_bits;
        return (consumed_bits + 7) / 8;
    }

    /// Whether the engine read past the end of its data.
    pub fn overrun(e: *const Engine) bool {
        return e.next > e.data.len + 8;
    }
};

/// The contexts initialised for a slice (9.3.1.1): its kind - I and SI
/// use their own table, the others cabac_init_idc's - and SliceQPY.
pub fn initContexts(ctx: *[1024]u8, intra: bool, init_idc: u8, qp: i32) void {
    const table = if (intra) &tables.cabac_init_i else &tables.cabac_init_pb[init_idc];
    const q: i32 = @max(0, @min(51, qp));
    for (ctx, table) |*c, mn| {
        const pre = @max(1, @min(126, ((@as(i32, mn[0]) * q) >> 4) + mn[1]));
        c.* = if (pre <= 63) @intCast((63 - pre) << 1) else @intCast(((pre - 64) << 1) | 1);
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "contexts start from (m, n) and the slice's QP; bypass bins read as bits while range stays" {
    var ctx: [1024]u8 = undefined;
    initContexts(&ctx, true, 0, 26);
    // Context 0 for I: (20, -15): ((20 * 26) >> 4) - 15 = 17 -> pStateIdx 46, MPS 0.
    try testing.expectEqual(@as(u8, 46 << 1), ctx[0]);
    // Context 276 (the terminate bin's) is (0, 0) in every table... any
    // value; context 6 for I: (-28, 127): (-728 >> 4) + 127 = 81 -> 17, MPS 1.
    try testing.expectEqual(@as(u8, (17 << 1) | 1), ctx[6]);
    var e: Engine = undefined;
    const data = [_]u8{ 0x00, 0x00, 0xFF, 0xFF };
    try testing.expect(e.init(&data, 0));
    try testing.expectEqual(@as(u32, 0), e.offset);
    // Offset 0 below every range: bypass gives 0s.
    try testing.expectEqual(@as(u1, 0), e.bypass());
    try testing.expectEqual(@as(u1, 0), e.terminate());
}

test "a most probable symbol moves every state up, past 31 too" {
    var e: Engine = undefined;
    // Offset 0: every decision is the most probable symbol.
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    try testing.expect(e.init(&data, 0));
    var ctx: u8 = (31 << 1) | 1;
    try testing.expectEqual(@as(u1, 1), e.decision(&ctx));
    try testing.expectEqual(@as(u8, (32 << 1) | 1), ctx);
    ctx = 62 << 1;
    try testing.expectEqual(@as(u1, 0), e.decision(&ctx));
    try testing.expectEqual(@as(u8, 62 << 1), ctx);
}
