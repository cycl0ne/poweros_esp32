// SPDX-License-Identifier: MIT
//! A Vorbis stream's setup header: the codebooks, the floors, the
//! residues, the mappings and the modes every audio packet is decoded
//! with - read once, into memory of the stream's own pool.
//!
//! **A codebook** gives each of its entries a codeword by its length
//! alone: the lengths are read in entry order, and each entry takes the
//! lowest codeword of its length still free. The used entries are kept
//! sorted by codeword, so a codeword is found by halving the list; the
//! short ones - most of what a packet holds - by a table the stream's
//! next bits index directly. A book that stands for vectors has each
//! used entry's vector worked out once, here.
//!
//! **A book's tree must be whole**: one with codewords left over or with
//! too many is no Vorbis book, but for a book of one entry, whose one
//! codeword is read whatever its bits are.
//!
//! Floor type 0 is refused (ACERR_UNSUPPORTED); everything else the
//! format has is read.

const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const ExecBase = sdk.interface.exec.ExecBase;
const ogg = @import("../ogg/_ogg.zig");
const Bits = ogg.Bits;

/// Codewords up to this long are found by the table, at once.
const fast_max = 10;

/// The most entries a codebook may have here: far past any encoder's.
const entries_max = 1 << 20;

pub const Codebook = struct {
    dimensions: u32,
    entries: u32,
    /// The used entries, sorted by their codewords, which are kept left-
    /// aligned in 32 bits: the codeword, its length, the entry's number.
    used: u32,
    codes: [*]u32,
    lengths: [*]u8,
    numbers: [*]u32,
    /// For each way the next `fast_bits` of the stream can begin with a
    /// codeword, the sorted index of its entry plus one; 0 for none.
    fast_bits: u32,
    fast: [*]u16,
    /// Each used entry's vector, `dimensions` values, in sorted order;
    /// null for a book that stands for numbers only.
    vectors: ?[*]f32,
};

pub const Floor = struct {
    partitions: u32,
    partition_class: [32]u8,
    class_dimensions: [16]u8,
    class_subclasses: [16]u8,
    class_masterbook: [16]u8,
    subclass_books: [16][8]i16,
    multiplier: u32,
    values: u32,
    x: [65]u32,
    /// The points in the order of their X; each point's neighbours, the
    /// nearest before it on either side, among the points before it.
    sorted: [65]u8,
    low: [65]u8,
    high: [65]u8,
};

pub const Residue = struct {
    kind: u32,
    begin: u32,
    end: u32,
    partition_size: u32,
    classifications: u32,
    classbook: u32,
    books: [64][8]i16,
};

pub const Mapping = struct {
    submaps: u32,
    coupling_steps: u32,
    magnitude: [*]u8,
    angle: [*]u8,
    mux: [2]u8,
    submap_floor: [16]u8,
    submap_residue: [16]u8,
};

pub const Mode = struct {
    long: bool,
    mapping: u8,
};

pub const Setup = struct {
    codebooks: [*]Codebook,
    codebook_count: u32,
    floors: [*]Floor,
    floor_count: u32,
    residues: [*]Residue,
    residue_count: u32,
    mappings: [*]Mapping,
    mapping_count: u32,
    modes: [64]Mode,
    mode_count: u32,
    /// The bits a packet's mode number takes.
    mode_bits: u32,
};

/// Memory from the stream's pool, `count` of `T`, cleared.
pub fn allocate(sys: *ExecBase, pool: *anyopaque, comptime T: type, count: usize) ?[*]T {
    const size = @max(count, 1) * @sizeOf(T);
    const memory = sys.AllocPooled(pool, size) orelse return null;
    return @ptrCast(@alignCast(memory));
}

/// The bits it takes to write `value`: 0 for 0, 1 for 1, 2 for 2 and 3.
pub fn ilog(value: u32) u32 {
    return 32 - @as(u32, @clz(value));
}

/// The setup header's body, after its type and name: ACERR_* when it is
/// none, or asks for what is not decoded.
pub fn read(bits: *Bits, sys: *ExecBase, pool: *anyopaque, channels: u32, out: *Setup) i32 {
    out.codebook_count = bits.read(8) + 1;
    out.codebooks = allocate(sys, pool, Codebook, out.codebook_count) orelse return ac.ACERR_NOMEMORY;
    for (out.codebooks[0..out.codebook_count]) |*book| {
        const result = codebook(bits, sys, pool, book);
        if (result != ac.ACERR_OK) return result;
    }
    // Time-domain transforms: placeholders, each 0.
    const times = bits.read(6) + 1;
    for (0..times) |_| {
        if (bits.read(16) != 0) return ac.ACERR_CORRUPT;
    }

    out.floor_count = bits.read(6) + 1;
    out.floors = allocate(sys, pool, Floor, out.floor_count) orelse return ac.ACERR_NOMEMORY;
    for (out.floors[0..out.floor_count]) |*floor_config| {
        const kind = bits.read(16);
        if (kind == 0) return ac.ACERR_UNSUPPORTED;
        if (kind != 1) return ac.ACERR_CORRUPT;
        if (!floor(bits, out.codebook_count, floor_config)) return ac.ACERR_CORRUPT;
    }

    out.residue_count = bits.read(6) + 1;
    out.residues = allocate(sys, pool, Residue, out.residue_count) orelse return ac.ACERR_NOMEMORY;
    for (out.residues[0..out.residue_count]) |*residue_config| {
        if (!residue(bits, out, residue_config)) return ac.ACERR_CORRUPT;
    }

    out.mapping_count = bits.read(6) + 1;
    out.mappings = allocate(sys, pool, Mapping, out.mapping_count) orelse return ac.ACERR_NOMEMORY;
    for (out.mappings[0..out.mapping_count]) |*mapping_config| {
        const result = mapping(bits, sys, pool, channels, out, mapping_config);
        if (result != ac.ACERR_OK) return result;
    }

    out.mode_count = bits.read(6) + 1;
    for (out.modes[0..out.mode_count]) |*mode| {
        mode.long = bits.read(1) != 0;
        const window = bits.read(16);
        const transform = bits.read(16);
        const index = bits.read(8);
        if (window != 0 or transform != 0 or index >= out.mapping_count) return ac.ACERR_CORRUPT;
        mode.mapping = @intCast(index);
    }
    out.mode_bits = ilog(out.mode_count - 1);
    if (bits.read(1) != 1 or bits.ended) return ac.ACERR_CORRUPT;
    return ac.ACERR_OK;
}

// --- codebooks --------------------------------------------------------------------

fn codebook(bits: *Bits, sys: *ExecBase, pool: *anyopaque, book: *Codebook) i32 {
    if (bits.read(24) != 0x564342) return ac.ACERR_CORRUPT;
    const dimensions = bits.read(16);
    const entries = bits.read(24);
    if (dimensions == 0 or entries == 0 or bits.ended) return ac.ACERR_CORRUPT;
    if (entries > entries_max) return ac.ACERR_UNSUPPORTED;

    // Each entry's codeword length, 0 for one not used; held while the
    // book is built.
    const length_memory = sys.AllocVec(entries, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return ac.ACERR_NOMEMORY;
    defer sys.FreeVec(length_memory);
    const lengths: [*]u8 = @ptrCast(length_memory);
    if (bits.read(1) == 0) {
        const sparse = bits.read(1) != 0;
        for (lengths[0..entries]) |*length| {
            const present = !sparse or bits.read(1) != 0;
            length.* = if (present) @intCast(bits.read(5) + 1) else 0;
        }
    } else {
        var length = bits.read(5) + 1;
        var entry: u32 = 0;
        while (entry < entries) {
            const count = bits.read(ilog(entries - entry));
            if (bits.ended or count > entries - entry or length > 32) return ac.ACERR_CORRUPT;
            @memset(lengths[entry..][0..count], @intCast(length));
            entry += count;
            length += 1;
        }
    }
    if (bits.ended) return ac.ACERR_CORRUPT;

    const lookup = bits.read(4);
    var minimum: f32 = 0;
    var delta: f32 = 0;
    var value_bits: u32 = 0;
    var sequence = false;
    var lookup_values: u32 = 0;
    if (lookup > 2) return ac.ACERR_CORRUPT;
    if (lookup != 0) {
        minimum = unpackFloat(bits.read(32));
        delta = unpackFloat(bits.read(32));
        value_bits = bits.read(4) + 1;
        sequence = bits.read(1) != 0;
        lookup_values = if (lookup == 1) lookup1Values(entries, dimensions) else entries *| dimensions;
        if (lookup_values == 0 or lookup_values > entries_max) return ac.ACERR_CORRUPT;
    }
    const multiplicand_memory = if (lookup != 0) (sys.AllocVec(lookup_values * 4, exec.MEMF_ANY) orelse return ac.ACERR_NOMEMORY) else null;
    defer if (multiplicand_memory) |memory| sys.FreeVec(memory);
    if (multiplicand_memory) |memory| {
        const multiplicands: [*]u32 = @ptrCast(@alignCast(memory));
        for (multiplicands[0..lookup_values]) |*value| value.* = bits.read(value_bits);
    }
    if (bits.ended) return ac.ACERR_CORRUPT;

    book.* = .{
        .dimensions = dimensions,
        .entries = entries,
        .used = 0,
        .codes = undefined,
        .lengths = undefined,
        .numbers = undefined,
        .fast_bits = 0,
        .fast = undefined,
        .vectors = null,
    };
    const built = codewords(sys, pool, book, lengths[0..entries]);
    if (built != ac.ACERR_OK) return built;

    if (multiplicand_memory) |memory| {
        const multiplicands: [*]const u32 = @ptrCast(@alignCast(memory));
        const vectors = allocate(sys, pool, f32, @as(usize, book.used) * dimensions) orelse return ac.ACERR_NOMEMORY;
        book.vectors = vectors;
        for (0..book.used) |index| {
            const entry = book.numbers[index];
            var last: f32 = 0;
            var divisor: u64 = 1;
            for (0..dimensions) |d| {
                const offset: u64 = if (lookup == 1)
                    (entry / divisor) % lookup_values
                else
                    @as(u64, entry) * dimensions + d;
                if (offset >= lookup_values) return ac.ACERR_CORRUPT;
                const value = @as(f32, @floatFromInt(multiplicands[@intCast(offset)])) * delta + minimum + last;
                vectors[index * dimensions + d] = value;
                if (sequence) last = value;
                divisor *|= lookup_values;
            }
        }
    }
    return ac.ACERR_OK;
}

/// The codewords given by the lengths: the used entries sorted by them,
/// and the table for the short ones.
fn codewords(sys: *ExecBase, pool: *anyopaque, book: *Codebook, lengths: []const u8) i32 {
    var used: u32 = 0;
    var longest: u32 = 0;
    for (lengths) |length| {
        if (length == 0) continue;
        used += 1;
        longest = @max(longest, length);
    }
    if (used == 0) return ac.ACERR_OK;

    // Keys of codeword and entry, sorted together.
    const key_memory = sys.AllocVec(used * 8, exec.MEMF_ANY) orelse return ac.ACERR_NOMEMORY;
    defer sys.FreeVec(key_memory);
    const keys: [*]u64 = @ptrCast(@alignCast(key_memory));

    // The lowest codeword free at each length, left-aligned; 0 is none,
    // as only the first codeword is 0.
    var free: [33]u32 = @splat(0);
    var count: u32 = 0;
    for (lengths, 0..) |length, entry| {
        if (length == 0) continue;
        var code: u32 = 0;
        if (count == 0) {
            for (1..@as(usize, length) + 1) |level| free[level] = @as(u32, 1) << @intCast(32 - level);
        } else {
            var level: usize = length;
            while (level > 0 and free[level] == 0) level -= 1;
            if (level == 0) return ac.ACERR_CORRUPT;
            code = free[level];
            free[level] = 0;
            var deeper: usize = length;
            while (deeper > level) : (deeper -= 1) free[deeper] = code + (@as(u32, 1) << @intCast(32 - deeper));
        }
        keys[count] = @as(u64, code) << 32 | entry;
        count += 1;
    }
    // A tree with room left is not whole - but for a book of one entry.
    if (used > 1) {
        for (free[1..]) |left| {
            if (left != 0) return ac.ACERR_CORRUPT;
        }
    }
    heapSort(keys[0..used]);

    book.used = used;
    book.codes = allocate(sys, pool, u32, used) orelse return ac.ACERR_NOMEMORY;
    book.lengths = allocate(sys, pool, u8, used) orelse return ac.ACERR_NOMEMORY;
    book.numbers = allocate(sys, pool, u32, used) orelse return ac.ACERR_NOMEMORY;
    for (keys[0..used], 0..) |key, index| {
        const entry: u32 = @truncate(key);
        book.codes[index] = @intCast(key >> 32);
        book.numbers[index] = entry;
        book.lengths[index] = lengths[entry];
    }

    book.fast_bits = if (used < 0xFFFF) @min(longest, fast_max) else 0;
    const slots = @as(usize, 1) << @intCast(book.fast_bits);
    book.fast = allocate(sys, pool, u16, slots) orelse return ac.ACERR_NOMEMORY;
    @memset(book.fast[0..slots], 0);
    if (book.fast_bits != 0) {
        for (0..used) |index| {
            const length = book.lengths[index];
            if (length > book.fast_bits) continue;
            // The codeword as the stream holds it: its first bit lowest.
            const in_stream = @bitReverse(book.codes[index]);
            var fill: usize = in_stream;
            const step = @as(usize, 1) << @intCast(length);
            while (fill < slots) : (fill += step) book.fast[fill] = @intCast(index + 1);
        }
    }
    return ac.ACERR_OK;
}

/// Keys sorted, smallest first.
fn heapSort(keys: []u64) void {
    const count = keys.len;
    var start = count / 2;
    while (start > 0) {
        start -= 1;
        siftDown(keys, start, count);
    }
    var end = count;
    while (end > 1) {
        end -= 1;
        const top = keys[0];
        keys[0] = keys[end];
        keys[end] = top;
        siftDown(keys, 0, end);
    }
}

fn siftDown(keys: []u64, from: usize, end: usize) void {
    var root = from;
    while (2 * root + 1 < end) {
        var child = 2 * root + 1;
        if (child + 1 < end and keys[child] < keys[child + 1]) child += 1;
        if (keys[root] >= keys[child]) return;
        const held = keys[root];
        keys[root] = keys[child];
        keys[child] = held;
        root = child;
    }
}

/// A codebook's packed float: a 21-bit mantissa, its sign, and a 10-bit
/// exponent biased by 788.
fn unpackFloat(word: u32) f32 {
    const mantissa: f64 = @floatFromInt(word & 0x1F_FFFF);
    const exponent: i32 = @intCast((word & 0x7FE0_0000) >> 21);
    const signed = if (word & 0x8000_0000 != 0) -mantissa else mantissa;
    const two_to: i32 = exponent - 788;
    // 2 to that power, built as a double: within its range.
    const scale: f64 = @bitCast(@as(u64, @intCast(two_to + 1023)) << 52);
    return @floatCast(signed * scale);
}

/// The most values a type-1 lookup has: the greatest whose power of
/// `dimensions` is no more than `entries`.
fn lookup1Values(entries: u32, dimensions: u32) u32 {
    var low: u32 = 0;
    var high: u32 = entries + 1;
    // The greatest `r` with r^dimensions <= entries, by halving.
    while (high - low > 1) {
        const middle = low + (high - low) / 2;
        if (power(middle, dimensions) <= entries) low = middle else high = middle;
    }
    return low;
}

fn power(value: u32, exponent: u32) u64 {
    var result: u64 = 1;
    for (0..exponent) |_| {
        result *|= value;
        if (result > 1 << 32) return result;
    }
    return result;
}

// --- floors, residues, mappings ---------------------------------------------------

fn floor(bits: *Bits, books: u32, out: *Floor) bool {
    out.partitions = bits.read(5);
    var classes: u32 = 0;
    for (out.partition_class[0..out.partitions]) |*class| {
        class.* = @intCast(bits.read(4));
        classes = @max(classes, @as(u32, class.*) + 1);
    }
    for (0..classes) |class| {
        out.class_dimensions[class] = @intCast(bits.read(3) + 1);
        out.class_subclasses[class] = @intCast(bits.read(2));
        if (out.class_subclasses[class] != 0) {
            const master = bits.read(8);
            if (master >= books) return false;
            out.class_masterbook[class] = @intCast(master);
        }
        for (0..@as(usize, 1) << @intCast(out.class_subclasses[class])) |sub| {
            const book = @as(i32, @intCast(bits.read(8))) - 1;
            if (book >= @as(i32, @intCast(books))) return false;
            out.subclass_books[class][sub] = @intCast(book);
        }
    }
    out.multiplier = bits.read(2) + 1;
    const range_bits = bits.read(4);
    out.x[0] = 0;
    out.x[1] = @as(u32, 1) << @intCast(range_bits);
    out.values = 2;
    for (out.partition_class[0..out.partitions]) |class| {
        for (0..out.class_dimensions[class]) |_| {
            if (out.values == 65) return false;
            out.x[out.values] = bits.read(range_bits);
            out.values += 1;
        }
    }
    if (bits.ended) return false;
    // The points in X's order; no two at one X.
    for (0..out.values) |index| out.sorted[index] = @intCast(index);
    var at: usize = 1;
    while (at < out.values) : (at += 1) {
        const moving = out.sorted[at];
        var place = at;
        while (place > 0 and out.x[out.sorted[place - 1]] > out.x[moving]) : (place -= 1) out.sorted[place] = out.sorted[place - 1];
        out.sorted[place] = moving;
    }
    for (1..out.values) |index| {
        if (out.x[out.sorted[index]] == out.x[out.sorted[index - 1]]) return false;
    }
    for (2..out.values) |point| {
        var low: usize = 0;
        var high: usize = 1;
        var low_x: u32 = 0;
        var high_x: u32 = 0xFFFF_FFFF;
        for (0..point) |before| {
            const x = out.x[before];
            if (x < out.x[point] and x >= low_x) {
                low = before;
                low_x = x;
            }
            if (x > out.x[point] and x < high_x) {
                high = before;
                high_x = x;
            }
        }
        out.low[point] = @intCast(low);
        out.high[point] = @intCast(high);
    }
    return true;
}

fn residue(bits: *Bits, setup: *const Setup, out: *Residue) bool {
    out.kind = bits.read(16);
    if (out.kind > 2) return false;
    out.begin = bits.read(24);
    out.end = bits.read(24);
    out.partition_size = bits.read(24) + 1;
    out.classifications = bits.read(6) + 1;
    out.classbook = bits.read(8);
    if (out.classbook >= setup.codebook_count) return false;
    var cascade: [64]u32 = undefined;
    for (cascade[0..out.classifications]) |*bitmap| {
        var value = bits.read(3);
        if (bits.read(1) != 0) value |= bits.read(5) << 3;
        bitmap.* = value;
    }
    for (0..out.classifications) |class| {
        for (0..8) |pass| {
            out.books[class][pass] = -1;
            if (cascade[class] & (@as(u32, 1) << @intCast(pass)) == 0) continue;
            const book = bits.read(8);
            if (book >= setup.codebook_count or setup.codebooks[book].vectors == null) return false;
            out.books[class][pass] = @intCast(book);
        }
    }
    const classbook = &setup.codebooks[out.classbook];
    if (classbook.used == 0) return false;
    return !bits.ended;
}

fn mapping(bits: *Bits, sys: *ExecBase, pool: *anyopaque, channels: u32, setup: *const Setup, out: *Mapping) i32 {
    if (bits.read(16) != 0) return ac.ACERR_CORRUPT;
    out.submaps = if (bits.read(1) != 0) bits.read(4) + 1 else 1;
    out.coupling_steps = if (bits.read(1) != 0) bits.read(8) + 1 else 0;
    out.magnitude = allocate(sys, pool, u8, out.coupling_steps) orelse return ac.ACERR_NOMEMORY;
    out.angle = allocate(sys, pool, u8, out.coupling_steps) orelse return ac.ACERR_NOMEMORY;
    const channel_bits = ilog(channels - 1);
    for (0..out.coupling_steps) |step| {
        const magnitude = bits.read(channel_bits);
        const angle = bits.read(channel_bits);
        if (magnitude == angle or magnitude >= channels or angle >= channels) return ac.ACERR_CORRUPT;
        out.magnitude[step] = @intCast(magnitude);
        out.angle[step] = @intCast(angle);
    }
    if (bits.read(2) != 0) return ac.ACERR_CORRUPT;
    out.mux = .{ 0, 0 };
    if (out.submaps > 1) {
        for (out.mux[0..channels]) |*mux| {
            mux.* = @intCast(bits.read(4));
            if (mux.* >= out.submaps) return ac.ACERR_CORRUPT;
        }
    }
    for (0..out.submaps) |submap| {
        _ = bits.read(8);
        const floor_index = bits.read(8);
        const residue_index = bits.read(8);
        if (floor_index >= setup.floor_count or residue_index >= setup.residue_count) return ac.ACERR_CORRUPT;
        out.submap_floor[submap] = @intCast(floor_index);
        out.submap_residue[submap] = @intCast(residue_index);
    }
    return if (bits.ended) ac.ACERR_CORRUPT else ac.ACERR_OK;
}
