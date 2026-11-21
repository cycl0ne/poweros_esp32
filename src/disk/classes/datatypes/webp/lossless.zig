// SPDX-License-Identifier: MIT
//! A lossless WebP picture (`VP8L`, RFC 9649 section 3) unpacked into its
//! pixels, alpha, red, green and blue in a word each (0xAARRGGBB).
//!
//! The stream is read a bit at a time from the lowest bit of each byte.
//! It begins with the picture's size, then the **transforms** that were
//! made to it before it was coded, each at most once: a prediction of
//! each pixel from its neighbours, a block's own way, leaving the
//! difference (`predictor`); a mixing of the colours into each other by
//! a block's own amounts (`colour`); green taken from red and blue
//! (`subtract green`); and a palette, with up to eight pixels' numbers
//! packed into one (`colour indexing`). Then the picture itself.
//!
//! **The picture is coded** as a run of symbols: a pixel's green, red,
//! blue and alpha each in a prefix code of its own; or a length and a
//! distance back to pixels already there to copy; or a number into a
//! cache of the colours seen lately. The codes may change across the
//! picture: an **entropy image** - a smaller picture of its own, a
//! pixel a block - says which group of five codes each block uses. The
//! transforms' data, the palette and the entropy image are pictures
//! coded the same way, without groups or transforms of their own.
//!
//! The codes are read from their lengths (canonical prefix codes): the
//! lengths themselves are coded, in a code of their own. A code is
//! looked up eight bits at a time in a table, and one longer than that
//! bit by bit.
//!
//! Once the picture is read, the transforms are undone the other way
//! round from how they came. The picture is unpacked in place in the
//! caller's memory, which is whole rows of the picture's width: a
//! palette's packed rows take less and are opened out in it from the
//! end.
//!
//! **Memory** comes from whoever runs the decoder (`Env`): the codes, the
//! transforms' data and the cache, all given back before it answers.

const vp8 = @import("vp8core");

pub const Env = vp8.Env;
pub const Error = error{ Corrupt, Unsupported, NoMemory };

/// The first byte of a lossless stream.
pub const signature: u8 = 0x2F;

/// What a stream's first five bytes say.
pub const Header = struct {
    width: u32,
    height: u32,
    /// The encoder says some pixel is not opaque. A hint: the pixels
    /// say for themselves.
    alpha: bool,
};

/// The size and the hint of a stream, from its header.
pub fn readHeader(data: []const u8) Error!Header {
    if (data.len < 5 or data[0] != signature) return Error.Corrupt;
    const bits = @as(u32, data[1]) | @as(u32, data[2]) << 8 | @as(u32, data[3]) << 16 | @as(u32, data[4]) << 24;
    if (bits >> 29 != 0) return Error.Unsupported; // a version this decoder does not know
    return .{
        .width = (bits & 0x3FFF) + 1,
        .height = ((bits >> 14) & 0x3FFF) + 1,
        .alpha = (bits >> 28) & 1 != 0,
    };
}

/// A whole stream - header and picture - into `pixels`, which has room
/// for its width times its height.
pub fn decode(env: Env, data: []const u8, pixels: []u32) Error!Header {
    const header = try readHeader(data);
    if (pixels.len < @as(usize, header.width) * header.height) return Error.NoMemory;
    try decodeBody(env, data[5..], header.width, header.height, pixels);
    return header;
}

/// A stream without a header - the transforms and the picture - of a
/// size said elsewhere, as an alpha chunk holds one.
pub fn decodeBody(env: Env, data: []const u8, width: u32, height: u32, pixels: []u32) Error!void {
    const decoder = env.slice(Decoder, 1) orelse return Error.NoMemory;
    defer env.freeSlice(Decoder, decoder);
    decoder[0] = .{ .env = env, .bits = .{ .from = data } };
    try decoder[0].readPicture(width, height, pixels);
}

// --- the bits -----------------------------------------------------------------

/// The stream, a bit at a time from the lowest of each byte. Past the
/// end it is zeroes, and says it went there.
const Bits = struct {
    from: []const u8,
    at: usize = 0,
    held: u64 = 0,
    count: u32 = 0,
    /// How many of the bits held are the zeroes after the end.
    padding: u32 = 0,

    fn fill(bits: *Bits) void {
        while (bits.count <= 56) {
            if (bits.at < bits.from.len) {
                bits.held |= @as(u64, bits.from[bits.at]) << @intCast(bits.count);
                bits.at += 1;
            } else {
                bits.padding += 8;
            }
            bits.count += 8;
        }
    }

    fn read(bits: *Bits, n: u32) u32 {
        if (n == 0) return 0;
        if (bits.count < n) bits.fill();
        const value: u32 = @truncate(bits.held & ((@as(u64, 1) << @intCast(n)) - 1));
        bits.skip(n);
        return value;
    }

    fn skip(bits: *Bits, n: u32) void {
        bits.held >>= @intCast(n);
        bits.count -= n;
    }

    /// Whether the stream was read past its end.
    fn past(bits: *const Bits) bool {
        return bits.padding > bits.count;
    }
};

// --- the codes ----------------------------------------------------------------

/// How many bits a code is looked up by at once.
const fast_bits = 8;

/// The longest code.
const max_length = 15;

/// A prefix code, from its symbols' lengths.
const Code = struct {
    /// What the next `fast_bits` bits of the stream are: the symbol
    /// shifted up four and its length, or 0 for a code longer than that.
    fast: [1 << fast_bits]u16 = @splat(0),
    /// How many codes there are of each length.
    count: [max_length + 1]u16 = @splat(0),
    /// The symbols in the order of their codes.
    symbols: []u16 = &.{},
    /// A code of one symbol, which takes no bits at all.
    lone: ?u16 = null,
};

/// The five codes of a group: green with the copies' lengths and the
/// cache's numbers; red, blue and alpha; and the copies' distances.
const Group = struct {
    codes: [5]Code = @splat(.{}),
};

const green = 0;
const red = 1;
const blue = 2;
const alpha = 3;
const distance = 4;

/// The lengths of a copy, coded after the 256 greens.
const length_codes = 24;
/// The distances of a copy.
const distance_codes = 40;

/// The order the lengths of the code of code lengths are written in.
const length_order = [19]u8{ 17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

/// The code a group's symbols are in, from their lengths: false when
/// they say nothing, or more than codes of those lengths can.
fn build(code: *Code, lengths: []const u8, pool: *Pool) Error!void {
    code.* = .{};
    var present: u32 = 0;
    var only: u16 = 0;
    for (lengths, 0..) |length, symbol| {
        if (length == 0) continue;
        code.count[length] += 1;
        present += 1;
        only = @intCast(symbol);
    }
    if (present == 0) return Error.Corrupt;
    if (present == 1) {
        code.lone = only;
        return;
    }
    // More codes of a length than there is room for is no code.
    var left: i32 = 1;
    for (1..max_length + 1) |length| {
        left <<= 1;
        left -= code.count[length];
        if (left < 0) return Error.Corrupt;
    }
    var offsets: [max_length + 2]u32 = @splat(0);
    for (1..max_length + 1) |length| offsets[length + 1] = offsets[length] + code.count[length];
    code.symbols = try pool.take(u16, present);
    for (lengths, 0..) |length, symbol| {
        if (length == 0) continue;
        code.symbols[offsets[length]] = @intCast(symbol);
        offsets[length] += 1;
    }
    // The table: each code of `fast_bits` or fewer, its bits as the
    // stream has them - the code's highest bit first - at every place
    // the bits after it could make.
    var value: u32 = 0;
    var index: u32 = 0;
    for (1..fast_bits + 1) |length| {
        for (0..code.count[length]) |_| {
            const reversed = reverse(value, @intCast(length));
            const entry: u16 = @intCast(@as(u32, code.symbols[index]) << 4 | @as(u32, @intCast(length)));
            var fill: u32 = reversed;
            while (fill < code.fast.len) : (fill += @as(u32, 1) << @intCast(length)) code.fast[fill] = entry;
            value += 1;
            index += 1;
        }
        value <<= 1;
    }
}

/// The lowest `length` bits of `value` the other way round.
fn reverse(value: u32, length: u5) u32 {
    var result: u32 = 0;
    var rest = value;
    var left = length;
    while (left > 0) : (left -= 1) {
        result = result << 1 | (rest & 1);
        rest >>= 1;
    }
    return result;
}

/// The next symbol of a code.
fn take(bits: *Bits, code: *const Code) Error!u16 {
    if (code.lone) |symbol| return symbol;
    if (bits.count < max_length) bits.fill();
    const entry = code.fast[@as(usize, @truncate(bits.held & ((1 << fast_bits) - 1)))];
    if (entry & 0x0F != 0) {
        bits.skip(entry & 0x0F);
        return entry >> 4;
    }
    // Longer: the codes of each length are a run of numbers.
    var value: u32 = 0;
    var first: u32 = 0;
    var index: u32 = 0;
    var length: u32 = 1;
    while (length <= max_length) : (length += 1) {
        value |= @truncate((bits.held >> @intCast(length - 1)) & 1);
        const count = code.count[length];
        if (value < first) return Error.Corrupt;
        if (value - first < count) {
            bits.skip(length);
            return code.symbols[index + value - first];
        }
        index += count;
        first = (first + count) << 1;
        value <<= 1;
    }
    return Error.Corrupt;
}

/// Memory for codes, in blocks from the decoder's `Env`, all given back
/// at once.
const Pool = struct {
    env: Env,
    blocks: ?*Block = null,
    free: []u8 = &.{},

    const Block = struct {
        next: ?*Block,
        length: usize,
    };
    const block_bytes = 64 << 10;

    fn take(pool: *Pool, comptime T: type, n: usize) Error![]T {
        const wanted = n * @sizeOf(T);
        const aligned = (@intFromPtr(pool.free.ptr) + @alignOf(T) - 1) & ~@as(usize, @alignOf(T) - 1);
        const skipped = aligned - @intFromPtr(pool.free.ptr);
        if (pool.free.len < skipped + wanted) {
            const length = @max(block_bytes, wanted + @sizeOf(Block) + 16);
            const memory = pool.env.alloc(pool.env.ctx, length, true) orelse return Error.NoMemory;
            const block: *Block = @ptrCast(@alignCast(memory));
            block.* = .{ .next = pool.blocks, .length = length };
            pool.blocks = block;
            pool.free = memory[@sizeOf(Block)..length];
            return pool.take(T, n);
        }
        const bytes = pool.free[skipped..][0..wanted];
        pool.free = pool.free[skipped + wanted ..];
        @memset(bytes, 0);
        const typed: [*]T = @ptrCast(@alignCast(bytes.ptr));
        return typed[0..n];
    }

    fn release(pool: *Pool) void {
        var block = pool.blocks;
        while (block) |held| {
            block = held.next;
            pool.env.free(pool.env.ctx, @ptrCast(held), held.length);
        }
        pool.* = .{ .env = pool.env };
    }
};

// --- the decoder ---------------------------------------------------------------

/// A transform, as it came: what it is, how large its blocks are, the
/// width of the picture it was made to, and its data.
const Transform = struct {
    kind: u2,
    bits: u5 = 0,
    width: u32,
    data: []u32 = &.{},
    /// A palette's: how many numbers one packed pixel holds, as a shift.
    pack: u5 = 0,
};

const predictor_transform = 0;
const colour_transform = 1;
const subtract_green = 2;
const colour_indexing = 3;

/// A colour cache: the colours seen lately, by a hash of each.
const Cache = struct {
    colours: []u32,
    shift: u5,

    fn insert(cache: *Cache, colour: u32) void {
        cache.colours[(colour *% 0x1E35A7BD) >> cache.shift] = colour;
    }
};

/// The groups' map: which group of codes each block of the picture
/// uses.
const Meta = struct {
    groups: []u32,
    bits: u5,
    across: u32,
};

const Decoder = struct {
    env: Env,
    bits: Bits,
    /// A code's symbols' lengths, as they are read.
    lengths: [256 + length_codes + (1 << 11)]u8 = @splat(0),

    /// The whole picture: its transforms, its pixels, the transforms
    /// undone.
    fn readPicture(decoder: *Decoder, width: u32, height: u32, pixels: []u32) Error!void {
        var transforms: [4]Transform = undefined;
        var count: usize = 0;
        defer for (transforms[0..count]) |transform| decoder.env.freeSlice(u32, transform.data);
        var seen: u4 = 0;
        var coded_width = width;
        while (decoder.bits.read(1) == 1) {
            const kind: u2 = @intCast(decoder.bits.read(2));
            const mask = @as(u4, 1) << kind;
            if (seen & mask != 0) return Error.Corrupt;
            seen |= mask;
            var transform = Transform{ .kind = kind, .width = coded_width };
            switch (kind) {
                predictor_transform, colour_transform => {
                    transform.bits = @intCast(decoder.bits.read(3) + 2);
                    const across = divide(coded_width, transform.bits);
                    const down = divide(height, transform.bits);
                    transform.data = decoder.env.slice(u32, @as(usize, across) * down) orelse return Error.NoMemory;
                    transforms[count] = transform;
                    count += 1;
                    try decoder.readImage(across, down, false, transforms[count - 1].data);
                },
                subtract_green => {
                    transforms[count] = transform;
                    count += 1;
                },
                colour_indexing => {
                    const size = decoder.bits.read(8) + 1;
                    transform.pack = if (size <= 2) 3 else if (size <= 4) 2 else if (size <= 16) 1 else 0;
                    // Room for every number a pixel can hold: one past
                    // the palette is nothing at all.
                    transform.data = decoder.env.slice(u32, 256) orelse return Error.NoMemory;
                    transforms[count] = transform;
                    count += 1;
                    const palette = transforms[count - 1].data;
                    try decoder.readImage(size, 1, false, palette[0..size]);
                    // Each colour is written as its difference from the one
                    // before.
                    for (1..size) |index| palette[index] = addPixels(palette[index], palette[index - 1]);
                    coded_width = divide(coded_width, transform.pack);
                },
            }
        }
        try decoder.readImage(coded_width, height, true, pixels[0 .. @as(usize, coded_width) * height]);
        var index = count;
        while (index > 0) {
            index -= 1;
            const transform = &transforms[index];
            switch (transform.kind) {
                predictor_transform => undoPredictor(pixels, transform.width, height, transform),
                colour_transform => undoColour(pixels, transform.width, height, transform),
                subtract_green => undoSubtractGreen(pixels[0 .. @as(usize, transform.width) * height]),
                colour_indexing => undoPalette(pixels, transform.width, height, transform),
            }
        }
    }

    /// A picture coded as one: its cache, its groups - for the picture
    /// itself (`whole`) only - its codes and its pixels.
    fn readImage(decoder: *Decoder, width: u32, height: u32, whole: bool, pixels: []u32) Error!void {
        var pool = Pool{ .env = decoder.env };
        defer pool.release();
        var cache_bits: u32 = 0;
        if (decoder.bits.read(1) == 1) {
            cache_bits = decoder.bits.read(4);
            if (cache_bits < 1 or cache_bits > 11) return Error.Corrupt;
        }
        var meta: ?Meta = null;
        var group_count: u32 = 1;
        var entropy: []u32 = &.{};
        defer decoder.env.freeSlice(u32, entropy);
        if (whole and decoder.bits.read(1) == 1) {
            const bits: u5 = @intCast(decoder.bits.read(3) + 2);
            const across = divide(width, bits);
            const down = divide(height, bits);
            entropy = decoder.env.slice(u32, @as(usize, across) * down) orelse return Error.NoMemory;
            try decoder.readImage(across, down, false, entropy);
            for (entropy) |*entry| {
                entry.* = (entry.* >> 8) & 0xFFFF;
                group_count = @max(group_count, entry.* + 1);
            }
            meta = .{ .groups = entropy, .bits = bits, .across = across };
        }
        // Each group is read, but kept only when a block uses it: the
        // numbers need not be dense.
        const places = try pool.take(u32, group_count);
        var kept: u32 = 0;
        if (meta) |map| {
            const unused = ~@as(u32, 0);
            @memset(places, unused);
            for (map.groups) |number| {
                if (places[number] == unused) {
                    places[number] = kept;
                    kept += 1;
                }
            }
            for (map.groups) |*number| number.* = places[number.*];
        } else {
            places[0] = 0;
            kept = 1;
        }
        const groups = try pool.take(Group, kept);
        var spare: Group = .{};
        const cache_size: u32 = if (cache_bits != 0) @as(u32, 1) << @intCast(cache_bits) else 0;
        for (0..group_count) |number| {
            const into = if (places[number] < kept) &groups[places[number]] else &spare;
            try decoder.readGroup(into, cache_size, &pool);
        }
        var cache: ?Cache = null;
        if (cache_bits != 0) cache = .{
            .colours = try pool.take(u32, cache_size),
            .shift = @intCast(32 - cache_bits),
        };
        try decoder.readPixels(width, height, groups, meta, if (cache) |*held| held else null, pixels);
    }

    /// A group's five codes.
    fn readGroup(decoder: *Decoder, into: *Group, cache_size: u32, pool: *Pool) Error!void {
        const sizes = [5]u32{ 256 + length_codes + cache_size, 256, 256, 256, distance_codes };
        for (&into.codes, sizes) |*code, size| try decoder.readCode(code, size, pool);
    }

    /// One code: two symbols or one given as they are, or the lengths of
    /// all of them in a code of their own.
    fn readCode(decoder: *Decoder, into: *Code, size: u32, pool: *Pool) Error!void {
        const bits = &decoder.bits;
        const lengths = decoder.lengths[0..size];
        @memset(lengths, 0);
        if (bits.read(1) == 1) {
            const symbols = bits.read(1) + 1;
            const first = bits.read(if (bits.read(1) == 1) 8 else 1);
            if (first >= size) return Error.Corrupt;
            lengths[first] = 1;
            if (symbols == 2) {
                const second = bits.read(8);
                if (second >= size) return Error.Corrupt;
                lengths[second] = 1;
            }
            return build(into, lengths, pool);
        }
        // The code the lengths are in.
        var length_lengths: [19]u8 = @splat(0);
        const written = bits.read(4) + 4;
        for (length_order[0..written]) |symbol| length_lengths[symbol] = @intCast(bits.read(3));
        var length_code: Code = .{};
        try build(&length_code, &length_lengths, pool);

        var most = size;
        if (bits.read(1) == 1) {
            const width = 2 + 2 * bits.read(3);
            most = 2 + bits.read(width);
            if (most > size) return Error.Corrupt;
        }
        var previous: u8 = 8;
        var symbol: u32 = 0;
        while (symbol < size) {
            if (most == 0) break;
            most -= 1;
            const length = try take(bits, &length_code);
            if (length < 16) {
                lengths[symbol] = @intCast(length);
                symbol += 1;
                if (length != 0) previous = @intCast(length);
                continue;
            }
            // 16: the last length again; 17 and 18: runs of nothing.
            const extra = [3]u32{ 2, 3, 7 };
            const least = [3]u32{ 3, 3, 11 };
            const which = length - 16;
            const repeat = bits.read(extra[which]) + least[which];
            if (symbol + repeat > size) return Error.Corrupt;
            const value: u8 = if (length == 16) previous else 0;
            @memset(lengths[symbol..][0..repeat], value);
            symbol += repeat;
        }
        if (bits.past()) return Error.Corrupt;
        return build(into, lengths, pool);
    }

    /// The pixels of a picture coded as one, in its codes.
    fn readPixels(decoder: *Decoder, width: u32, height: u32, groups: []Group, meta: ?Meta, cache: ?*Cache, into: []u32) Error!void {
        const bits = &decoder.bits;
        const total = @as(usize, width) * height;
        var at: usize = 0;
        var x: u32 = 0;
        var y: u32 = 0;
        const mask: u32 = if (meta) |map| (@as(u32, 1) << map.bits) - 1 else ~@as(u32, 0);
        var codes = &groups[0].codes;
        while (at < total) {
            if (x & mask == 0) if (meta) |map| {
                codes = &groups[map.groups[(y >> map.bits) * map.across + (x >> map.bits)]].codes;
            };
            const symbol = try take(bits, &codes[green]);
            if (symbol < 256) {
                const r = try take(bits, &codes[red]);
                const b = try take(bits, &codes[blue]);
                const a = try take(bits, &codes[alpha]);
                const colour = @as(u32, a) << 24 | @as(u32, r) << 16 | @as(u32, symbol) << 8 | b;
                into[at] = colour;
                if (cache) |held| held.insert(colour);
                at += 1;
                x += 1;
                if (x == width) {
                    x = 0;
                    y += 1;
                    if (bits.past()) return Error.Corrupt;
                }
            } else if (symbol < 256 + length_codes) {
                const length = prefixed(bits, symbol - 256);
                const distance_symbol = try take(bits, &codes[distance]);
                const back = planeDistance(width, prefixed(bits, distance_symbol));
                if (back > at or length > total - at) return Error.Corrupt;
                // A pixel at a time: a copy may reach into what it makes.
                for (0..length) |index| into[at + index] = into[at + index - back];
                if (cache) |held| for (into[at..][0..length]) |colour| held.insert(colour);
                at += length;
                y = @intCast(at / width);
                x = @intCast(at % width);
                if (bits.past()) return Error.Corrupt;
                if (at < total) if (meta) |map| {
                    codes = &groups[map.groups[(y >> map.bits) * map.across + (x >> map.bits)]].codes;
                };
            } else {
                const held = cache orelse return Error.Corrupt;
                const index = symbol - 256 - length_codes;
                if (index >= held.colours.len) return Error.Corrupt;
                const colour = held.colours[index];
                into[at] = colour;
                held.insert(colour);
                at += 1;
                x += 1;
                if (x == width) {
                    x = 0;
                    y += 1;
                    if (bits.past()) return Error.Corrupt;
                }
            }
        }
        if (bits.past()) return Error.Corrupt;
    }
};

/// A length or a distance from its prefix symbol and the bits after it.
fn prefixed(bits: *Bits, symbol: u32) u32 {
    if (symbol < 4) return symbol + 1;
    const extra = (symbol - 2) >> 1;
    const offset = (2 + (symbol & 1)) << @intCast(extra);
    return offset + bits.read(extra) + 1;
}

/// The first 120 distances are places near the pixel - so many across,
/// so many rows up - by how near they are; the rest are counts back.
const near_places = [120][2]i8{
    .{ 0, 1 },  .{ 1, 0 },  .{ 1, 1 },  .{ -1, 1 }, .{ 0, 2 },  .{ 2, 0 },  .{ 1, 2 },
    .{ -1, 2 }, .{ 2, 1 },  .{ -2, 1 }, .{ 2, 2 },  .{ -2, 2 }, .{ 0, 3 },  .{ 3, 0 },
    .{ 1, 3 },  .{ -1, 3 }, .{ 3, 1 },  .{ -3, 1 }, .{ 2, 3 },  .{ -2, 3 }, .{ 3, 2 },
    .{ -3, 2 }, .{ 0, 4 },  .{ 4, 0 },  .{ 1, 4 },  .{ -1, 4 }, .{ 4, 1 },  .{ -4, 1 },
    .{ 3, 3 },  .{ -3, 3 }, .{ 2, 4 },  .{ -2, 4 }, .{ 4, 2 },  .{ -4, 2 }, .{ 0, 5 },
    .{ 3, 4 },  .{ -3, 4 }, .{ 4, 3 },  .{ -4, 3 }, .{ 5, 0 },  .{ 1, 5 },  .{ -1, 5 },
    .{ 5, 1 },  .{ -5, 1 }, .{ 2, 5 },  .{ -2, 5 }, .{ 5, 2 },  .{ -5, 2 }, .{ 4, 4 },
    .{ -4, 4 }, .{ 3, 5 },  .{ -3, 5 }, .{ 5, 3 },  .{ -5, 3 }, .{ 0, 6 },  .{ 6, 0 },
    .{ 1, 6 },  .{ -1, 6 }, .{ 6, 1 },  .{ -6, 1 }, .{ 2, 6 },  .{ -2, 6 }, .{ 6, 2 },
    .{ -6, 2 }, .{ 4, 5 },  .{ -4, 5 }, .{ 5, 4 },  .{ -5, 4 }, .{ 3, 6 },  .{ -3, 6 },
    .{ 6, 3 },  .{ -6, 3 }, .{ 0, 7 },  .{ 7, 0 },  .{ 1, 7 },  .{ -1, 7 }, .{ 5, 5 },
    .{ -5, 5 }, .{ 7, 1 },  .{ -7, 1 }, .{ 4, 6 },  .{ -4, 6 }, .{ 6, 4 },  .{ -6, 4 },
    .{ 2, 7 },  .{ -2, 7 }, .{ 7, 2 },  .{ -7, 2 }, .{ 3, 7 },  .{ -3, 7 }, .{ 7, 3 },
    .{ -7, 3 }, .{ 5, 6 },  .{ -5, 6 }, .{ 6, 5 },  .{ -6, 5 }, .{ 8, 0 },  .{ 4, 7 },
    .{ -4, 7 }, .{ 7, 4 },  .{ -7, 4 }, .{ 8, 1 },  .{ 8, 2 },  .{ 6, 6 },  .{ -6, 6 },
    .{ 8, 3 },  .{ 5, 7 },  .{ -5, 7 }, .{ 7, 5 },  .{ -7, 5 }, .{ 8, 4 },  .{ 6, 7 },
    .{ -6, 7 }, .{ 7, 6 },  .{ -7, 6 }, .{ 8, 5 },  .{ 7, 7 },  .{ -7, 7 }, .{ 8, 6 },
    .{ 8, 7 },
};

/// How many pixels back a distance code reaches in a picture this wide.
fn planeDistance(width: u32, code_value: u32) usize {
    if (code_value > near_places.len) return code_value - near_places.len;
    const place = near_places[code_value - 1];
    const back = @as(i64, place[1]) * width + place[0];
    return if (back < 1) 1 else @intCast(back);
}

/// A length divided by a block of `1 << bits`, rounded up.
fn divide(length: u32, bits: u5) u32 {
    return (length + (@as(u32, 1) << bits) - 1) >> bits;
}

// --- the transforms undone -----------------------------------------------------

/// Two pixels added, each of their four bytes on its own.
fn addPixels(first: u32, second: u32) u32 {
    const alpha_green = (first & 0xFF00FF00) +% (second & 0xFF00FF00);
    const red_blue = (first & 0x00FF00FF) +% (second & 0x00FF00FF);
    return (alpha_green & 0xFF00FF00) | (red_blue & 0x00FF00FF);
}

/// Two pixels' bytes each halfway between, rounded down.
fn average(first: u32, second: u32) u32 {
    return (((first ^ second) & 0xFEFEFEFE) >> 1) +% (first & second);
}

fn byteOf(pixel: u32, shift: u5) i32 {
    return @intCast((pixel >> shift) & 0xFF);
}

fn clampByte(value: i32) u32 {
    return @intCast(@max(0, @min(255, value)));
}

/// Left or top, whichever is nearer to what the gradient through the
/// three says.
fn select(left: u32, top: u32, top_left: u32) u32 {
    var to_left: i32 = 0;
    var to_top: i32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |shift| {
        const l = byteOf(left, shift);
        const t = byteOf(top, shift);
        const tl = byteOf(top_left, shift);
        // The estimate is l + t - tl: its distance to l is |t - tl|,
        // to t |l - tl|.
        to_left += @intCast(@abs(t - tl));
        to_top += @intCast(@abs(l - tl));
    }
    return if (to_left < to_top) left else top;
}

/// Each byte the gradient a + b - c, held to a byte.
fn clampFull(first: u32, second: u32, third: u32) u32 {
    var result: u32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |shift| {
        result |= clampByte(byteOf(first, shift) + byteOf(second, shift) - byteOf(third, shift)) << shift;
    }
    return result;
}

/// Each byte a + (a - b) / 2, held to a byte.
fn clampHalf(first: u32, second: u32) u32 {
    var result: u32 = 0;
    inline for (.{ 24, 16, 8, 0 }) |shift| {
        const a = byteOf(first, shift);
        result |= clampByte(a + @divTrunc(a - byteOf(second, shift), 2)) << shift;
    }
    return result;
}

/// What a pixel is predicted as, by its block's mode.
fn predict(mode: u32, left: u32, top: u32, top_left: u32, top_right: u32) u32 {
    return switch (mode) {
        1 => left,
        2 => top,
        3 => top_right,
        4 => top_left,
        5 => average(average(left, top_right), top),
        6 => average(left, top_left),
        7 => average(left, top),
        8 => average(top_left, top),
        9 => average(top, top_right),
        10 => average(average(left, top_left), average(top, top_right)),
        11 => select(left, top, top_left),
        12 => clampFull(left, top, top_left),
        13 => clampHalf(average(left, top), top_left),
        else => 0xFF000000,
    };
}

/// Each pixel its prediction added back: the first opaque black, the
/// rest of the first row from the left, the first of each row from
/// above, every other by its block's mode. The pixel above and to the
/// right of a row's last is that row's first.
fn undoPredictor(pixels: []u32, width: u32, height: u32, transform: *const Transform) void {
    pixels[0] = addPixels(pixels[0], 0xFF000000);
    for (1..width) |x| pixels[x] = addPixels(pixels[x], pixels[x - 1]);
    const across = divide(width, transform.bits);
    for (1..height) |row| {
        const y: u32 = @intCast(row);
        const start = @as(usize, y) * width;
        pixels[start] = addPixels(pixels[start], pixels[start - width]);
        const modes = transform.data[@as(usize, y >> transform.bits) * across ..];
        for (1..width) |column| {
            const at = start + column;
            const mode = (modes[column >> transform.bits] >> 8) & 0x0F;
            const guess = predict(mode, pixels[at - 1], pixels[at - width], pixels[at - width - 1], pixels[at - width + 1]);
            pixels[at] = addPixels(pixels[at], guess);
        }
    }
}

/// A colour's share of another, as the colour transform has it.
fn delta(amount: u8, colour: u8) i32 {
    return (@as(i32, @as(i8, @bitCast(amount))) * @as(i8, @bitCast(colour))) >> 5;
}

/// Red and blue given back their shares of green and of red, by each
/// block's amounts.
fn undoColour(pixels: []u32, width: u32, height: u32, transform: *const Transform) void {
    const across = divide(width, transform.bits);
    for (0..height) |row| {
        const y: u32 = @intCast(row);
        const amounts = transform.data[@as(usize, y >> transform.bits) * across ..];
        for (pixels[@as(usize, y) * width ..][0..width], 0..) |*pixel, column| {
            const element = amounts[column >> transform.bits];
            const green_to_red: u8 = @truncate(element);
            const green_to_blue: u8 = @truncate(element >> 8);
            const red_to_blue: u8 = @truncate(element >> 16);
            const argb = pixel.*;
            const green_value: u8 = @truncate(argb >> 8);
            var red_value: i32 = @intCast((argb >> 16) & 0xFF);
            var blue_value: i32 = @intCast(argb & 0xFF);
            red_value += delta(green_to_red, green_value);
            red_value &= 0xFF;
            blue_value += delta(green_to_blue, green_value);
            blue_value += delta(red_to_blue, @intCast(red_value));
            blue_value &= 0xFF;
            pixel.* = (argb & 0xFF00FF00) | @as(u32, @intCast(red_value)) << 16 | @as(u32, @intCast(blue_value));
        }
    }
}

/// Green added back to red and to blue.
fn undoSubtractGreen(pixels: []u32) void {
    for (pixels) |*pixel| {
        const green_value = (pixel.* >> 8) & 0xFF;
        const red_blue = ((pixel.* & 0x00FF00FF) +% (green_value << 16 | green_value)) & 0x00FF00FF;
        pixel.* = (pixel.* & 0xFF00FF00) | red_blue;
    }
}

/// Each pixel's palette number made its colour, the packed rows opened
/// out to the picture's width from the last pixel back, so that the
/// rows share the memory.
fn undoPalette(pixels: []u32, width: u32, height: u32, transform: *const Transform) void {
    const pack = transform.pack;
    const packed_width = divide(width, pack);
    const per_pixel: u5 = @intCast(@as(u32, 8) >> pack);
    const number_mask: u32 = (@as(u32, 1) << per_pixel) - 1;
    const in_one: u32 = (@as(u32, 1) << pack) - 1;
    var row = height;
    while (row > 0) {
        row -= 1;
        var column = width;
        while (column > 0) {
            column -= 1;
            const holder = pixels[@as(usize, row) * packed_width + (column >> pack)];
            const shift: u5 = @intCast((column & in_one) * per_pixel);
            const number = ((holder >> 8) >> shift) & number_mask;
            pixels[@as(usize, row) * width + column] = transform.data[number];
        }
    }
}

const std = @import("std");
const testing = std.testing;

test "a header says the size and the hint" {
    const bits: u32 = (99) | (49 << 14) | (1 << 28);
    const data = [_]u8{ signature, @truncate(bits), @truncate(bits >> 8), @truncate(bits >> 16), @truncate(bits >> 24) };
    const header = try readHeader(&data);
    try testing.expectEqual(@as(u32, 100), header.width);
    try testing.expectEqual(@as(u32, 50), header.height);
    try testing.expect(header.alpha);
}

test "a code from its lengths, looked up and read bit by bit" {
    var pool = Pool{ .env = testing_env };
    defer pool.release();
    // Symbol 0 of one bit, 1 of two, and 2 and 3 of ten.
    var lengths: [4]u8 = .{ 1, 2, 10, 10 };
    // That leaves room: it is a code, if not a full one.
    var code: Code = .{};
    try build(&code, &lengths, &pool);
    // The codes: 0, 10, 1100000000, 1100000001 - read highest bit first.
    var stream = [_]u8{ 0b0001_1010, 0, 0, 0, 0, 0 };
    var bits = Bits{ .from = &stream };
    try testing.expectEqual(@as(u16, 0), try take(&bits, &code));
    try testing.expectEqual(@as(u16, 1), try take(&bits, &code));
    try testing.expectEqual(@as(u16, 2), try take(&bits, &code));
    lengths = .{ 1, 1, 1, 0 };
    try testing.expectError(Error.Corrupt, build(&code, &lengths, &pool));
}

test "a code of one symbol takes no bits" {
    var pool = Pool{ .env = testing_env };
    defer pool.release();
    var lengths: [3]u8 = .{ 0, 4, 0 };
    var code: Code = .{};
    try build(&code, &lengths, &pool);
    var bits = Bits{ .from = &.{} };
    try testing.expectEqual(@as(u16, 1), try take(&bits, &code));
    try testing.expect(!bits.past());
}

test "a distance code near the pixel, and one that counts back" {
    try testing.expectEqual(@as(usize, 100), planeDistance(100, 1));
    try testing.expectEqual(@as(usize, 1), planeDistance(100, 2));
    try testing.expectEqual(@as(usize, 99), planeDistance(100, 4));
    try testing.expectEqual(@as(usize, 1), planeDistance(1, 4));
    try testing.expectEqual(@as(usize, 5), planeDistance(100, 125));
}

test "the predictions' arithmetic" {
    try testing.expectEqual(@as(u32, 0x01020304), addPixels(0xFF010203, 0x02010101));
    try testing.expectEqual(@as(u32, 0x7F000000), average(0xFF000000, 0x00000100));
    try testing.expectEqual(@as(u32, 0x00000081), average(0x00000080, 0x00000082));
    try testing.expectEqual(@as(u32, 0x00FF0000), clampFull(0x00F00000, 0x00800000, 0x00100000));
    // A half of a difference that is odd and below nothing rounds to
    // nothing.
    try testing.expectEqual(@as(u32, 0x00000009), clampHalf(0x0000000A, 0x0000000D));
}

/// Memory for the tests, from the testing allocator.
const testing_env = Env{ .ctx = undefined, .alloc = testingAlloc, .free = testingFree };

fn testingAlloc(_: *anyopaque, length: usize, clear: bool) ?[*]u8 {
    const memory = testing.allocator.alignedAlloc(u8, .@"16", length) catch return null;
    if (clear) @memset(memory, 0);
    return memory.ptr;
}

fn testingFree(_: *anyopaque, memory: [*]u8, length: usize) void {
    const aligned: [*]align(16) u8 = @alignCast(memory);
    testing.allocator.free(aligned[0..length]);
}
