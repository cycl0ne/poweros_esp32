// SPDX-License-Identifier: MIT
//! CAVLC (9.2): a block's coefficients from coeff_token, the trailing
//! ones' signs, the levels, total_zeros and each run_before.
//!
//! Every code table is a lookup made at compile time: the first bits of
//! the stream index a table, whose entry is the symbol and its length, or
//! a second table for the longer codes.

const tables = @import("tables.zig");
const bits_mod = @import("bits.zig");
const Bits = bits_mod.Bits;
const Error = bits_mod.Error;

const Entry = struct { sym: u16 = 0, len: i8 = 0 };

const Code = struct { len: u8, bits: u32, sym: u16 };

fn Vlc(comptime codes: []const Code, comptime root: u5) type {
    @setEvalBranchQuota(2_000_000);
    // How many entries: the root, and a table for each prefix of longer
    // codes, as long as its longest.
    const Sub = struct { prefix: u32, bits: u5 };
    comptime var subs: [256]Sub = undefined;
    comptime var sub_count: usize = 0;
    inline for (codes) |c| {
        if (c.len > root) {
            const prefix = c.bits >> (c.len - root);
            const need: u5 = c.len - root;
            var found = false;
            for (subs[0..sub_count]) |*s| {
                if (s.prefix == prefix) {
                    if (need > s.bits) s.bits = need;
                    found = true;
                }
            }
            if (!found) {
                subs[sub_count] = .{ .prefix = prefix, .bits = need };
                sub_count += 1;
            }
        }
    }
    comptime var total: usize = 1 << root;
    for (subs[0..sub_count]) |s| total += @as(usize, 1) << s.bits;
    const n = total;
    const t = comptime blk: {
        var entries: [n]Entry = @splat(.{});
        var offset: usize = 1 << root;
        for (subs[0..sub_count]) |s| {
            entries[s.prefix] = .{ .sym = @intCast(offset), .len = -@as(i8, s.bits) };
            for (codes) |c| {
                if (c.len > root and c.bits >> (c.len - root) == s.prefix) {
                    const rest = c.len - root;
                    const low = c.bits & ((@as(u32, 1) << rest) - 1);
                    const first = low << (s.bits - rest);
                    for (0..(@as(usize, 1) << (s.bits - rest))) |k| {
                        entries[offset + first + k] = .{ .sym = c.sym, .len = @intCast(rest) };
                    }
                }
            }
            offset += @as(usize, 1) << s.bits;
        }
        for (codes) |c| {
            if (c.len <= root and c.len > 0) {
                const first = c.bits << (root - c.len);
                for (0..(@as(usize, 1) << (root - c.len))) |k| entries[first + k] = .{ .sym = c.sym, .len = @intCast(c.len) };
            }
        }
        break :blk entries;
    };
    return struct {
        const entries = t;
        pub fn read(b: *Bits) Error!u32 {
            const e = entries[b.peek(root)];
            if (e.len > 0) {
                b.skip(@intCast(e.len));
                return e.sym;
            }
            if (e.len == 0) return error.Corrupt;
            b.skip(root);
            const sub: u5 = @intCast(-e.len);
            const s = entries[e.sym + b.peek(sub)];
            if (s.len <= 0) return error.Corrupt;
            b.skip(@intCast(s.len));
            return s.sym;
        }
    };
}

fn codesOf(comptime lens: []const u8, comptime bits: []const u8) []const Code {
    comptime var out: [lens.len]Code = undefined;
    comptime var count: usize = 0;
    inline for (lens, 0..) |l, i| {
        if (l != 0) {
            out[count] = .{ .len = l, .bits = bits[i], .sym = i };
            count += 1;
        }
    }
    const final = out[0..count].*;
    return &final;
}

const CoeffToken0 = Vlc(codesOf(&tables.coeff_token_len[0], &tables.coeff_token_bits[0]), 8);
const CoeffToken1 = Vlc(codesOf(&tables.coeff_token_len[1], &tables.coeff_token_bits[1]), 8);
const CoeffToken2 = Vlc(codesOf(&tables.coeff_token_len[2], &tables.coeff_token_bits[2]), 8);
const CoeffToken3 = Vlc(codesOf(&tables.coeff_token_len[3], &tables.coeff_token_bits[3]), 6);
const ChromaDcToken = Vlc(codesOf(&tables.chroma_dc_coeff_token_len, &tables.chroma_dc_coeff_token_bits), 8);
const Chroma422DcToken = Vlc(codesOf(&tables.chroma422_dc_coeff_token_len, &tables.chroma422_dc_coeff_token_bits), 8);

fn TotalZeros(comptime k: usize) type {
    return Vlc(codesOf(&tables.total_zeros_len[k], &tables.total_zeros_bits[k]), 9);
}
fn ChromaDcZeros(comptime k: usize) type {
    return Vlc(codesOf(&tables.chroma_dc_total_zeros_len[k], &tables.chroma_dc_total_zeros_bits[k]), 3);
}
fn Chroma422DcZeros(comptime k: usize) type {
    return Vlc(codesOf(&tables.chroma422_dc_total_zeros_len[k], &tables.chroma422_dc_total_zeros_bits[k]), 5);
}
fn Run(comptime k: usize) type {
    return Vlc(codesOf(&tables.run_len[k], &tables.run_bits[k]), 11);
}

fn totalZeros(b: *Bits, total_coeff: u32, max_coeff: u32) Error!u32 {
    if (max_coeff == 4) {
        return switch (total_coeff) {
            1 => ChromaDcZeros(0).read(b),
            2 => ChromaDcZeros(1).read(b),
            else => ChromaDcZeros(2).read(b),
        };
    }
    if (max_coeff == 8) {
        return switch (total_coeff) {
            1 => Chroma422DcZeros(0).read(b),
            2 => Chroma422DcZeros(1).read(b),
            3 => Chroma422DcZeros(2).read(b),
            4 => Chroma422DcZeros(3).read(b),
            5 => Chroma422DcZeros(4).read(b),
            6 => Chroma422DcZeros(5).read(b),
            else => Chroma422DcZeros(6).read(b),
        };
    }
    return switch (total_coeff) {
        1 => TotalZeros(0).read(b),
        2 => TotalZeros(1).read(b),
        3 => TotalZeros(2).read(b),
        4 => TotalZeros(3).read(b),
        5 => TotalZeros(4).read(b),
        6 => TotalZeros(5).read(b),
        7 => TotalZeros(6).read(b),
        8 => TotalZeros(7).read(b),
        9 => TotalZeros(8).read(b),
        10 => TotalZeros(9).read(b),
        11 => TotalZeros(10).read(b),
        12 => TotalZeros(11).read(b),
        13 => TotalZeros(12).read(b),
        14 => TotalZeros(13).read(b),
        else => TotalZeros(14).read(b),
    };
}

fn runBefore(b: *Bits, zeros_left: u32) Error!u32 {
    return switch (zeros_left) {
        1 => Run(0).read(b),
        2 => Run(1).read(b),
        3 => Run(2).read(b),
        4 => Run(3).read(b),
        5 => Run(4).read(b),
        6 => Run(5).read(b),
        else => Run(6).read(b),
    };
}

/// nC (9.2.1) for chroma DC: -1 for 4:2:0, -2 for 4:2:2.
pub const nc_chroma_dc: i32 = -1;
pub const nc_chroma422_dc: i32 = -2;

/// residual_block_cavlc (7.3.5.3.2): the coefficients `levels[start ..
/// end]` (in scan order, the rest left as they are, zeros expected) of a
/// block of `max_coeff` coefficients, with nC; TotalCoeff.
pub fn residualBlock(b: *Bits, nc: i32, levels: []i32, start: u32, end: u32, max_coeff: u32) Error!u32 {
    const token: u32 = switch (nc) {
        -1 => try ChromaDcToken.read(b),
        -2 => try Chroma422DcToken.read(b),
        0, 1 => try CoeffToken0.read(b),
        2, 3 => try CoeffToken1.read(b),
        4, 5, 6, 7 => try CoeffToken2.read(b),
        else => try CoeffToken3.read(b),
    };
    const total: u32 = token >> 2;
    const ones: u32 = token & 3;
    if (total == 0) return 0;
    if (total > max_coeff or total > end - start + 1) return error.Corrupt;
    var level: [16]i32 = undefined;
    var suffix_length: u5 = if (total > 10 and ones < 3) 1 else 0;
    for (0..total) |i| {
        if (i < ones) {
            level[i] = if (b.flag()) -1 else 1;
            continue;
        }
        // level_prefix: leading zeros, then a one.
        const w = b.peek(32);
        if (w == 0) return error.Corrupt;
        const prefix: u32 = @clz(w);
        b.skip(prefix + 1);
        var suffix_size: u5 = suffix_length;
        if (prefix == 14 and suffix_length == 0) suffix_size = 4;
        if (prefix >= 15) suffix_size = @intCast(prefix - 3);
        var code: i32 = @intCast(@as(u32, @min(15, prefix)) << suffix_length);
        if (suffix_size > 0) code += @intCast(b.u(suffix_size));
        if (prefix >= 15 and suffix_length == 0) code += 15;
        if (prefix >= 16) code += (@as(i32, 1) << @intCast(prefix - 3)) - 4096;
        if (i == ones and ones < 3) code += 2;
        const value: i32 = if (code & 1 == 0) (code + 2) >> 1 else (-code - 1) >> 1;
        level[i] = value;
        if (suffix_length == 0) suffix_length = 1;
        const magnitude: u32 = @abs(value);
        if (magnitude > (@as(u32, 3) << (suffix_length - 1)) and suffix_length < 6) suffix_length += 1;
    }
    var zeros_left: u32 = 0;
    if (total < end - start + 1) {
        zeros_left = try totalZeros(b, total, max_coeff);
        if (zeros_left > end - start + 1 - total) return error.Corrupt;
    }
    // From the last coefficient backwards.
    var pos: i32 = @as(i32, @intCast(total + zeros_left)) - 1;
    for (0..total) |i| {
        if (pos < 0) return error.Corrupt;
        levels[start + @as(u32, @intCast(pos))] = level[i];
        var run: u32 = 0;
        if (zeros_left > 0 and i + 1 < total) {
            run = try runBefore(b, zeros_left);
            if (run > zeros_left) return error.Corrupt;
            zeros_left -= run;
        }
        pos -= @as(i32, @intCast(run)) + 1;
    }
    return total;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "a 4x4 block: 0 3 0 1 -1 -1 0 1 0 ... (Richardson's first example)" {
    // TotalCoeff 5, TrailingOnes 3, nC 0 -> coeff_token 0000100; the
    // trailing ones from the end, + - - -> 011; level 1 (suffixLength 0,
    // levelCode 0) -> 1; level 3 (suffixLength 1, levelCode 4) -> 0010;
    // total_zeros 3 -> 111; run_before 1, 0, 0, 1 -> 10 1 1 01.
    const stream = "0000100" ++ "011" ++ "1" ++ "0010" ++ "111" ++ "10" ++ "1" ++ "1" ++ "01" ++ "1";
    var data: [8]u8 = @splat(0);
    for (stream, 0..) |c, i| {
        if (c == '1') data[i >> 3] |= @as(u8, 0x80) >> @intCast(i & 7);
    }
    var b = Bits.init(&data);
    var levels: [16]i32 = @splat(0);
    try testing.expectEqual(@as(u32, 5), try residualBlock(&b, 0, &levels, 0, 15, 16));
    try testing.expectEqualSlices(i32, &.{ 0, 3, 0, 1, -1, -1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0 }, &levels);
    try testing.expectEqual(@as(usize, stream.len - 1), b.pos);
}
