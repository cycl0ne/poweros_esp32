// SPDX-License-Identifier: MIT
//! A QR code encoder: a text in byte mode as a symbol of dark and light
//! modules, as ISO/IEC 18004 lays it out.
//!
//! **The steps.** The smallest version (1 to 40) whose data capacity at
//! the error correction level holds the text is chosen. The bit stream is
//! the byte mode's indicator, the length, the bytes, a terminator, and pad
//! bytes to fill the capacity. It is cut into the level's blocks, each
//! given its Reed-Solomon error correction codewords (GF(256) over the
//! polynomial 0x11D), and the blocks are interleaved. The function
//! patterns go down first - the timing lines, the three finders, the
//! alignment patterns, the format and version bits - then the codewords in
//! the zigzag from the bottom right, two columns at a time. Each of the
//! eight masks is tried and scored by the standard's four penalties; the
//! lowest is kept and its format bits written.
//!
//! **Memory.** Nothing is allocated here: the caller hands a work buffer
//! of `workSize(version)` bytes, which holds the grid (a byte a module:
//! bit 0 dark, bit 1 part of a function pattern) followed by the codewords
//! and the blocks while they are built.

/// The error correction levels, as the gadget's tags number them.
pub const Level = enum(u2) { low, medium, quartile, high };

pub const max_version = 40;

const ecc_per_block = [4][41]i8{
    .{ -1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 },
    .{ -1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
    .{ -1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30 },
};

const blocks_of = [4][41]i8{
    .{ -1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25 },
    .{ -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 },
    .{ -1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68 },
    .{ -1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81 },
};

/// The format bits' code for each level: L 1, M 0, Q 3, H 2.
const level_bits = [4]u32{ 1, 0, 3, 2 };

/// How many modules a side a version has.
pub fn sizeOf(version: u32) u32 {
    return version * 4 + 17;
}

/// The modules left for codewords once the function patterns are down.
fn rawModules(version: u32) u32 {
    var result: u32 = (16 * version + 128) * version + 64;
    if (version >= 2) {
        const aligns = version / 7 + 2;
        result -= (25 * aligns - 10) * aligns - 55;
        if (version >= 7) result -= 36;
    }
    return result;
}

/// How many data codewords a version holds at a level.
pub fn dataCodewords(version: u32, level: Level) u32 {
    const l = @intFromEnum(level);
    return rawModules(version) / 8 - @as(u32, @intCast(ecc_per_block[l][version])) * @as(u32, @intCast(blocks_of[l][version]));
}

/// The smallest version that holds `length` bytes at `level`; null when
/// none does.
pub fn versionFor(length: usize, level: Level) ?u32 {
    var version: u32 = 1;
    while (version <= max_version) : (version += 1) {
        const count_bits: usize = if (version <= 9) 8 else 16;
        if (4 + count_bits + 8 * length <= 8 * dataCodewords(version, level)) return version;
    }
    return null;
}

/// The work buffer a version needs: its grid, its codewords, its blocks.
pub fn workSize(version: u32) usize {
    const size = sizeOf(version);
    const raw = rawModules(version) / 8;
    return size * size + 2 * raw + 2 * 81;
}

// --- Reed-Solomon -------------------------------------------------------------------

fn gfMul(x: u8, y: u8) u8 {
    var z: u32 = 0;
    var i: u5 = 8;
    while (i > 0) {
        i -= 1;
        z = (z << 1) ^ ((z >> 7) * 0x11D);
        z ^= ((@as(u32, y) >> i) & 1) * x;
    }
    return @truncate(z);
}

/// The divisor polynomial of a degree, highest term left out.
fn divisor(degree: usize, into: []u8) void {
    @memset(into[0..degree], 0);
    into[degree - 1] = 1;
    var root: u8 = 1;
    for (0..degree) |_| {
        for (0..degree) |j| {
            into[j] = gfMul(into[j], root);
            if (j + 1 < degree) into[j] ^= into[j + 1];
        }
        root = gfMul(root, 0x02);
    }
}

/// The error correction codewords of `data` by `div`, into `into`.
pub fn remainder(data: []const u8, div: []const u8, into: []u8) void {
    @memset(into, 0);
    for (data) |byte| {
        const factor = byte ^ into[0];
        var i: usize = 0;
        while (i + 1 < into.len) : (i += 1) into[i] = into[i + 1];
        into[into.len - 1] = 0;
        for (into, 0..) |*r, j| r.* ^= gfMul(div[j], factor);
    }
}

// --- the grid ------------------------------------------------------------------------

const dark_bit: u8 = 1;
const function_bit: u8 = 2;

/// A symbol being built, or built: a byte a module.
pub const Symbol = struct {
    size: u32,
    grid: []u8,

    pub fn dark(s: Symbol, x: u32, y: u32) bool {
        return s.grid[y * s.size + x] & dark_bit != 0;
    }

    fn setFunction(s: Symbol, x: u32, y: u32, is_dark: bool) void {
        s.grid[y * s.size + x] = function_bit | @intFromBool(is_dark);
    }

    fn isFunction(s: Symbol, x: u32, y: u32) bool {
        return s.grid[y * s.size + x] & function_bit != 0;
    }

    fn finder(s: Symbol, cx: i32, cy: i32) void {
        var dy: i32 = -4;
        while (dy <= 4) : (dy += 1) {
            var dx: i32 = -4;
            while (dx <= 4) : (dx += 1) {
                const x = cx + dx;
                const y = cy + dy;
                if (x < 0 or y < 0 or x >= s.size or y >= s.size) continue;
                const distance = @max(@abs(dx), @abs(dy));
                s.setFunction(@intCast(x), @intCast(y), distance != 2 and distance != 4);
            }
        }
    }

    fn alignment(s: Symbol, cx: u32, cy: u32) void {
        var dy: i32 = -2;
        while (dy <= 2) : (dy += 1) {
            var dx: i32 = -2;
            while (dx <= 2) : (dx += 1) {
                s.setFunction(@intCast(@as(i32, @intCast(cx)) + dx), @intCast(@as(i32, @intCast(cy)) + dy), @max(@abs(dx), @abs(dy)) != 1);
            }
        }
    }

    fn formatBits(s: Symbol, level: Level, mask: u32) void {
        const data = level_bits[@intFromEnum(level)] << 3 | mask;
        var rem = data;
        for (0..10) |_| rem = (rem << 1) ^ ((rem >> 9) * 0x537);
        const bits = (data << 10 | rem) ^ 0x5412;
        const bit = struct {
            fn of(value: u32, i: u5) bool {
                return (value >> i) & 1 != 0;
            }
        }.of;
        var i: u5 = 0;
        while (i <= 5) : (i += 1) s.setFunction(8, i, bit(bits, i));
        s.setFunction(8, 7, bit(bits, 6));
        s.setFunction(8, 8, bit(bits, 7));
        s.setFunction(7, 8, bit(bits, 8));
        i = 9;
        while (i < 15) : (i += 1) s.setFunction(14 - @as(u32, i), 8, bit(bits, i));
        i = 0;
        while (i < 8) : (i += 1) s.setFunction(s.size - 1 - @as(u32, i), 8, bit(bits, i));
        i = 8;
        while (i < 15) : (i += 1) s.setFunction(8, s.size - 15 + @as(u32, i), bit(bits, i));
        s.setFunction(8, s.size - 8, true);
    }

    fn versionBits(s: Symbol, version: u32) void {
        if (version < 7) return;
        var rem = version;
        for (0..12) |_| rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
        const bits = version << 12 | rem;
        for (0..18) |i| {
            const is_dark = (bits >> @intCast(i)) & 1 != 0;
            const a: u32 = s.size - 11 + @as(u32, @intCast(i % 3));
            const b: u32 = @intCast(i / 3);
            s.setFunction(a, b, is_dark);
            s.setFunction(b, a, is_dark);
        }
    }

    /// The alignment patterns' centres along one side; the count answered.
    fn alignPositions(version: u32, into: *[7]u32) usize {
        if (version == 1) return 0;
        const count = version / 7 + 2;
        const step: u32 = if (version == 32) 26 else (version * 4 + count * 2 + 1) / (count * 2 - 2) * 2;
        into[0] = 6;
        var position = sizeOf(version) - 7;
        var i = count - 1;
        while (i >= 1) : (i -= 1) {
            into[i] = position;
            // Past the last one it may go below 0: it is not used.
            position -%= step;
        }
        return count;
    }

    fn functionPatterns(s: Symbol, version: u32, level: Level) void {
        for (0..s.size) |i| {
            const at: u32 = @intCast(i);
            s.setFunction(6, at, at % 2 == 0);
            s.setFunction(at, 6, at % 2 == 0);
        }
        s.finder(3, 3);
        s.finder(@as(i32, @intCast(s.size)) - 4, 3);
        s.finder(3, @as(i32, @intCast(s.size)) - 4);
        var positions: [7]u32 = undefined;
        const count = alignPositions(version, &positions);
        for (0..count) |i| {
            for (0..count) |j| {
                if ((i == 0 and j == 0) or (i == 0 and j == count - 1) or (i == count - 1 and j == 0)) continue;
                s.alignment(positions[i], positions[j]);
            }
        }
        // Reserved now, written with the mask.
        s.formatBits(level, 0);
        s.versionBits(version);
    }

    fn codewords(s: Symbol, data: []const u8) void {
        var i: usize = 0;
        var right: i32 = @as(i32, @intCast(s.size)) - 1;
        while (right >= 1) : (right -= 2) {
            if (right == 6) right = 5;
            for (0..s.size) |vert| {
                for (0..2) |j| {
                    const x: u32 = @intCast(right - @as(i32, @intCast(j)));
                    const upward = (right + 1) & 2 == 0;
                    const y: u32 = if (upward) s.size - 1 - @as(u32, @intCast(vert)) else @intCast(vert);
                    if (s.isFunction(x, y) or i >= data.len * 8) continue;
                    const is_dark = (data[i >> 3] >> @intCast(7 - (i & 7))) & 1 != 0;
                    s.grid[y * s.size + x] = @intFromBool(is_dark);
                    i += 1;
                }
            }
        }
    }

    fn applyMask(s: Symbol, mask: u32) void {
        for (0..s.size) |yi| {
            for (0..s.size) |xi| {
                const x: u32 = @intCast(xi);
                const y: u32 = @intCast(yi);
                if (s.isFunction(x, y)) continue;
                const invert = switch (mask) {
                    0 => (x + y) % 2 == 0,
                    1 => y % 2 == 0,
                    2 => x % 3 == 0,
                    3 => (x + y) % 3 == 0,
                    4 => (x / 3 + y / 2) % 2 == 0,
                    5 => x * y % 2 + x * y % 3 == 0,
                    6 => (x * y % 2 + x * y % 3) % 2 == 0,
                    else => ((x + y) % 2 + x * y % 3) % 2 == 0,
                };
                if (invert) s.grid[y * s.size + x] ^= dark_bit;
            }
        }
    }

    // --- the penalty -------------------------------------------------------------

    const History = struct {
        runs: [7]u32 = @splat(0),
        size: u32,

        fn add(h: *History, length: u32) void {
            var run = length;
            if (h.runs[0] == 0) run += h.size;
            var i: usize = 6;
            while (i > 0) : (i -= 1) h.runs[i] = h.runs[i - 1];
            h.runs[0] = run;
        }

        fn patterns(h: *const History) u32 {
            const n = h.runs[1];
            const core = n > 0 and h.runs[2] == n and h.runs[3] == n * 3 and h.runs[4] == n and h.runs[5] == n;
            return @as(u32, @intFromBool(core and h.runs[0] >= n * 4 and h.runs[6] >= n)) +
                @as(u32, @intFromBool(core and h.runs[6] >= n * 4 and h.runs[0] >= n));
        }

        fn finish(h: *History, colour: bool, length: u32) u32 {
            var run = length;
            if (colour) {
                h.add(run);
                run = 0;
            }
            run += h.size;
            h.add(run);
            return h.patterns();
        }
    };

    fn lineScore(s: Symbol, along_rows: bool, line: u32) u32 {
        var score: u32 = 0;
        var colour = false;
        var run: u32 = 0;
        var history = History{ .size = s.size };
        for (0..s.size) |ii| {
            const i: u32 = @intCast(ii);
            const module = if (along_rows) s.dark(i, line) else s.dark(line, i);
            if (module == colour) {
                run += 1;
                if (run == 5) score += 3 else if (run > 5) score += 1;
            } else {
                history.add(run);
                if (!colour) score += history.patterns() * 40;
                colour = module;
                run = 1;
            }
        }
        return score + history.finish(colour, run) * 40;
    }

    pub fn penalty(s: Symbol) u32 {
        var score: u32 = 0;
        for (0..s.size) |line| {
            score += s.lineScore(true, @intCast(line));
            score += s.lineScore(false, @intCast(line));
        }
        var darks: u32 = 0;
        for (0..s.size) |yi| {
            for (0..s.size) |xi| {
                const x: u32 = @intCast(xi);
                const y: u32 = @intCast(yi);
                if (s.dark(x, y)) darks += 1;
                if (x + 1 < s.size and y + 1 < s.size) {
                    const c = s.dark(x, y);
                    if (c == s.dark(x + 1, y) and c == s.dark(x, y + 1) and c == s.dark(x + 1, y + 1)) score += 3;
                }
            }
        }
        const total = s.size * s.size;
        const off: u32 = @intCast(@abs(@as(i64, darks) * 20 - @as(i64, total) * 10));
        const k = (off + total - 1) / total;
        if (k > 0) score += (k - 1) * 10;
        return score;
    }
};

/// `text` encoded at `level` as the smallest version that holds it, built
/// in `work`, which is `workSize` of that version long. The symbol's grid
/// is the start of `work`.
pub fn encode(text: []const u8, level: Level, version: u32, work: []u8) Symbol {
    const size = sizeOf(version);
    const l = @intFromEnum(level);
    const raw = rawModules(version) / 8;
    const capacity = dataCodewords(version, level);
    const symbol = Symbol{ .size = size, .grid = work[0 .. size * size] };
    const data = work[size * size ..][0..raw];
    const blocks_area = work[size * size + raw ..];
    @memset(symbol.grid, 0);
    @memset(data, 0);

    // The bit stream: mode, length, bytes, terminator, pad.
    var bits: usize = 0;
    const put = struct {
        fn bits_(into: []u8, at: *usize, value: u32, count: u5) void {
            var i = count;
            while (i > 0) {
                i -= 1;
                if ((value >> i) & 1 != 0) into[at.* >> 3] |= @as(u8, 0x80) >> @intCast(at.* & 7);
                at.* += 1;
            }
        }
    }.bits_;
    put(data, &bits, 0b0100, 4);
    put(data, &bits, @intCast(text.len), if (version <= 9) 8 else 16);
    for (text) |byte| put(data, &bits, byte, 8);
    const capacity_bits = capacity * 8;
    put(data, &bits, 0, @intCast(@min(4, capacity_bits - bits)));
    bits = (bits + 7) / 8 * 8;
    var pad: u8 = 0xEC;
    while (bits < capacity_bits) : (bits += 8) {
        data[bits >> 3] = pad;
        pad ^= 0xEC ^ 0x11;
    }

    // The blocks, each its data and its error correction, the short ones
    // with a gap where the long ones have one more data codeword.
    const count: usize = @intCast(blocks_of[l][version]);
    const ecc_len: usize = @intCast(ecc_per_block[l][version]);
    const short_count = count - raw % count;
    const short_len = raw / count;
    const block_len = short_len + 1;
    var div: [30]u8 = undefined;
    divisor(ecc_len, div[0..ecc_len]);
    var k: usize = 0;
    for (0..count) |i| {
        const block = blocks_area[i * block_len ..][0..block_len];
        const data_len = short_len - ecc_len + @intFromBool(i >= short_count);
        @memcpy(block[0..data_len], data[k..][0..data_len]);
        k += data_len;
        if (i < short_count) block[data_len] = 0;
        remainder(data[k - data_len ..][0..data_len], div[0..ecc_len], block[block_len - ecc_len ..]);
    }
    // Interleaved, the short blocks' gap left out, back into `data`.
    var at: usize = 0;
    for (0..block_len) |i| {
        for (0..count) |j| {
            if (i == short_len - ecc_len and j < short_count) continue;
            data[at] = blocks_area[j * block_len + i];
            at += 1;
        }
    }

    symbol.functionPatterns(version, level);
    symbol.codewords(data[0..raw]);

    // The mask with the lowest penalty.
    var best: u32 = 0;
    var best_score: u32 = 0xFFFF_FFFF;
    for (0..8) |m| {
        const mask: u32 = @intCast(m);
        symbol.applyMask(mask);
        symbol.formatBits(level, mask);
        const score = symbol.penalty();
        if (score < best_score) {
            best = mask;
            best_score = score;
        }
        symbol.applyMask(mask);
    }
    symbol.applyMask(best);
    symbol.formatBits(level, best);
    return symbol;
}
