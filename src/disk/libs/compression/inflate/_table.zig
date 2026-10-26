// SPDX-License-Identifier: MIT
//! A block's Huffman codes as Inflate reads them: made from the lengths
//! of the codes, which is all a DEFLATE stream says about them.
//!
//! The codes are canonical (RFC 1951, 3.2.2): of one length, they are a
//! run of numbers in the order of their symbols, and each length's run
//! starts where the shorter ones' left off, doubled. So the lengths alone
//! give every code, and two small tables - how many codes of each length,
//! and the symbols in that order - are enough to decode by walking the
//! lengths, a bit at a time.
//!
//! Walking is slow for the codes that come most often, which are the
//! short ones, so in front of it is a table of 2^10 entries indexed by the
//! next ten bits of the input (the first bit the lowest, as the stream
//! sends codes): an entry is the symbol and its code's length, filled in
//! at every index whose low bits are that code. A code longer than ten
//! bits leaves its entries 0, and the reader walks for it.

/// The bits the table in front looks at.
pub const fast_bits = 10;
pub const fast_mask: u64 = (1 << fast_bits) - 1;

/// The most symbols a code has: the literal/length code's 288.
pub const max_symbols = 288;
/// The longest code there may be.
pub const max_length = 15;

pub const Code = struct {
    /// For each value of the next ten bits, the symbol in the low twelve
    /// bits and its code's length in the top four; 0 where the code is
    /// longer than ten bits, or where there is no code.
    fast: [1 << fast_bits]u16,
    /// How many codes there are of each length, 1 to 15.
    count: [max_length + 1]u16,
    /// The symbols, shortest code first, and in symbol order within a
    /// length.
    symbol: [max_symbols]u16,
};

/// `code` made from the code lengths of its symbols, 0 for a symbol
/// without one. False when the lengths are no code: more codes of some
/// length than there is room for, or - but for a single code of one bit,
/// or none at all - fewer than fill the room.
pub fn build(code: *Code, lengths: []const u8) bool {
    code.count = @splat(0);
    for (lengths) |length| code.count[length] += 1;
    code.count[0] = 0;

    var left: i32 = 1;
    var total: u32 = 0;
    var longest: u32 = 0;
    for (1..max_length + 1) |length| {
        left <<= 1;
        left -= code.count[length];
        if (left < 0) return false;
        total += code.count[length];
        if (code.count[length] != 0) longest = @intCast(length);
    }
    // An incomplete code is taken only as a lone code of one bit, which
    // a distance code with a single distance is; no codes at all is a
    // block of literals only.
    if (left > 0 and total != 0 and !(total == 1 and longest == 1)) return false;

    var offset: [max_length + 2]u16 = undefined;
    offset[1] = 0;
    for (1..max_length + 1) |length| offset[length + 1] = offset[length] + code.count[length];
    for (lengths, 0..) |length, symbol| {
        if (length == 0) continue;
        code.symbol[offset[length]] = @intCast(symbol);
        offset[length] += 1;
    }

    code.fast = @splat(0);
    var next: u32 = 0;
    var index: usize = 0;
    for (1..max_length + 1) |length| {
        for (0..code.count[length]) |_| {
            if (length <= fast_bits) {
                const symbol = code.symbol[index];
                var at: usize = reverse(next, @intCast(length));
                while (at < code.fast.len) : (at += @as(usize, 1) << @intCast(length)) {
                    code.fast[at] = @intCast(length << 12 | symbol);
                }
            }
            next += 1;
            index += 1;
        }
        next <<= 1;
    }
    return true;
}

fn reverse(value: u32, length: u5) u32 {
    var result: u32 = 0;
    var rest = value;
    for (0..length) |_| {
        result = result << 1 | (rest & 1);
        rest >>= 1;
    }
    return result;
}

/// What looking up a symbol came to.
pub const Found = struct {
    symbol: u16,
    /// The code's length; 0 when the bits at hand do not finish a code
    /// yet, and `corrupt` set when no number of bits would.
    length: u32,
    corrupt: bool = false,
};

/// The symbol whose code is at the low end of `hold`, of which `bits`
/// bits are there, without taking them.
pub fn find(code: *const Code, hold: u64, bits: u32) Found {
    const entry = code.fast[@intCast(hold & fast_mask)];
    const length: u32 = entry >> 12;
    if (length != 0) {
        if (length > bits) return .{ .symbol = 0, .length = 0 };
        return .{ .symbol = entry & 0xFFF, .length = length };
    }
    // Longer than the table, or no code: the walk.
    var value: u32 = 0;
    var first: u32 = 0;
    var index: u32 = 0;
    var walked: u32 = 1;
    while (walked <= max_length) : (walked += 1) {
        if (walked > bits) return .{ .symbol = 0, .length = 0 };
        value |= @intCast((hold >> @intCast(walked - 1)) & 1);
        const count = code.count[walked];
        if (value -% first < count) return .{ .symbol = code.symbol[index + value - first], .length = walked };
        index += count;
        first = (first + count) << 1;
        value <<= 1;
    }
    return .{ .symbol = 0, .length = 0, .corrupt = true };
}

/// The fixed codes (RFC 1951, 3.2.6), made at compile time.
pub const fixed_literal: Code = blk: {
    @setEvalBranchQuota(200_000);
    var lengths: [288]u8 = undefined;
    for (&lengths, 0..) |*length, symbol| length.* = if (symbol < 144) 8 else if (symbol < 256) 9 else if (symbol < 280) 7 else 8;
    var code: Code = undefined;
    if (!build(&code, &lengths)) unreachable;
    break :blk code;
};

/// All 32 distance codes of five bits; 30 and 31 are in the code but no
/// distance, and the reader refuses them.
pub const fixed_distance: Code = blk: {
    @setEvalBranchQuota(200_000);
    const lengths: [32]u8 = @splat(5);
    var code: Code = undefined;
    if (!build(&code, &lengths)) unreachable;
    break :blk code;
};
