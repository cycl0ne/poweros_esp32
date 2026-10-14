// SPDX-License-Identifier: MIT
//! A Vorbis audio packet decoded into sound: its mode and window, a floor
//! for each channel, the residue, the channels uncoupled, the floor laid
//! over the residue, the inverse MDCT, and the block overlapped with the
//! one before.
//!
//! **The floor** (type 1) is a curve of points, each predicted from its
//! neighbours and corrected by what the packet says; the lines between
//! them, in steps of the inverse-dB table, scale the residue. A channel
//! whose floor is unused is silent - unless coupling ties it to one that
//! is not, in which case its residue is decoded for the other's sake.
//!
//! **The residue** is decoded in passes: classifications first, then
//! partition after partition the vectors of the books each class names,
//! added in place - one vector at a time (format 0, interleaved by its
//! dimensions; format 1, in order), or all the channels as one
//! interleaved vector (format 2). The end of the packet in the middle of
//! it is not an error: what was decoded so far stands.
//!
//! **What a packet hands out** runs from the middle of the block before
//! to the middle of this one: the part of the earlier block after its
//! middle, kept faded out, is added to this block's start faded in. The
//! first packet - of the stream, or after a seek - hands out nothing.

const ogg = @import("../ogg/_ogg.zig");
const setup = @import("setup.zig");
const imdct = @import("imdct.zig");
const _vorbis = @import("_vorbis.zig");
const Vorbis = _vorbis.Vorbis;
const Bits = ogg.Bits;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;

/// The floor's amplitudes: from -140 dB up to 0, a step of about 0.47 dB
/// each.
const inverse_db = [256]f32{
    1.0649863e-07, 1.1341951e-07, 1.2079015e-07, 1.2863978e-07,
    1.3699951e-07, 1.4590251e-07, 1.5538408e-07, 1.6548181e-07,
    1.7623575e-07, 1.8768855e-07, 1.9988561e-07, 2.1287530e-07,
    2.2670913e-07, 2.4144197e-07, 2.5713223e-07, 2.7384213e-07,
    2.9163793e-07, 3.1059021e-07, 3.3077411e-07, 3.5226968e-07,
    3.7516214e-07, 3.9954229e-07, 4.2550680e-07, 4.5315863e-07,
    4.8260743e-07, 5.1396998e-07, 5.4737065e-07, 5.8294187e-07,
    6.2082472e-07, 6.6116941e-07, 7.0413592e-07, 7.4989464e-07,
    7.9862701e-07, 8.5052630e-07, 9.0579828e-07, 9.6466216e-07,
    1.0273513e-06, 1.0941144e-06, 1.1652161e-06, 1.2409384e-06,
    1.3215816e-06, 1.4074654e-06, 1.4989305e-06, 1.5963394e-06,
    1.7000785e-06, 1.8105592e-06, 1.9282195e-06, 2.0535261e-06,
    2.1869758e-06, 2.3290978e-06, 2.4804557e-06, 2.6416497e-06,
    2.8133190e-06, 2.9961443e-06, 3.1908506e-06, 3.3982101e-06,
    3.6190449e-06, 3.8542308e-06, 4.1047004e-06, 4.3714470e-06,
    4.6555282e-06, 4.9580707e-06, 5.2802740e-06, 5.6234160e-06,
    5.9888572e-06, 6.3780469e-06, 6.7925283e-06, 7.2339451e-06,
    7.7040476e-06, 8.2047000e-06, 8.7378876e-06, 9.3057248e-06,
    9.9104632e-06, 1.0554501e-05, 1.1240392e-05, 1.1970856e-05,
    1.2748789e-05, 1.3577278e-05, 1.4459606e-05, 1.5399272e-05,
    1.6400004e-05, 1.7465768e-05, 1.8600792e-05, 1.9809576e-05,
    2.1096914e-05, 2.2467911e-05, 2.3928002e-05, 2.5482978e-05,
    2.7139006e-05, 2.8902651e-05, 3.0780908e-05, 3.2781225e-05,
    3.4911534e-05, 3.7180282e-05, 3.9596466e-05, 4.2169667e-05,
    4.4910090e-05, 4.7828601e-05, 5.0936773e-05, 5.4246931e-05,
    5.7772202e-05, 6.1526565e-05, 6.5524908e-05, 6.9783085e-05,
    7.4317983e-05, 7.9147585e-05, 8.4291040e-05, 8.9768747e-05,
    9.5602426e-05, 0.00010181521, 0.00010843174, 0.00011547824,
    0.00012298267, 0.00013097477, 0.00013948625, 0.00014855085,
    0.00015820453, 0.00016848555, 0.00017943469, 0.00019109536,
    0.00020351382, 0.00021673929, 0.00023082423, 0.00024582449,
    0.00026179955, 0.00027881276, 0.00029693158, 0.00031622787,
    0.00033677814, 0.00035866388, 0.00038197188, 0.00040679456,
    0.00043323036, 0.00046138411, 0.00049136745, 0.00052329927,
    0.00055730621, 0.00059352311, 0.00063209358, 0.00067317058,
    0.00071691700, 0.00076350630, 0.00081312324, 0.00086596457,
    0.00092223983, 0.00098217216, 0.0010459992,  0.0011139742,
    0.0011863665,  0.0012634633,  0.0013455702,  0.0014330129,
    0.0015261382,  0.0016253153,  0.0017309374,  0.0018434235,
    0.0019632195,  0.0020908006,  0.0022266726,  0.0023713743,
    0.0025254795,  0.0026895994,  0.0028643847,  0.0030505286,
    0.0032487691,  0.0034598925,  0.0036847358,  0.0039241906,
    0.0041792066,  0.0044507950,  0.0047400328,  0.0050480668,
    0.0053761186,  0.0057254891,  0.0060975636,  0.0064938176,
    0.0069158225,  0.0073652516,  0.0078438871,  0.0083536271,
    0.0088964928,  0.009474637,   0.010090352,   0.010746080,
    0.011444421,   0.012188144,   0.012980198,   0.013823725,
    0.014722068,   0.015678791,   0.016697687,   0.017782797,
    0.018938423,   0.020169149,   0.021479854,   0.022875735,
    0.024362330,   0.025945531,   0.027631618,   0.029427276,
    0.031339626,   0.033376252,   0.035545228,   0.037855157,
    0.040315199,   0.042935108,   0.045725273,   0.048696758,
    0.051861348,   0.055231591,   0.058820850,   0.062643361,
    0.066714279,   0.071049749,   0.075666962,   0.080584227,
    0.085821044,   0.091398179,   0.097337747,   0.10366330,
    0.11039993,    0.11757434,    0.12521498,    0.13335215,
    0.14201813,    0.15124727,    0.16107617,    0.17154380,
    0.18269168,    0.19456402,    0.20720788,    0.22067342,
    0.23501402,    0.25028656,    0.26655159,    0.28387361,
    0.30232132,    0.32196786,    0.34289114,    0.36517414,
    0.38890521,    0.41417847,    0.44109412,    0.46975890,
    0.50028648,    0.53279791,    0.56742212,    0.60429640,
    0.64356699,    0.68538959,    0.72993007,    0.77736504,
    0.82788260,    0.88168307,    0.9389798,     1.0,
};

/// What a packet came to.
pub const Outcome = enum {
    /// Decoded: its sound - none, for the first - is ready.
    decoded,
    /// Not an audio packet, or one that cannot be decoded: passed over.
    passed,
    /// The stream has no more packets.
    end,
};

// --- codebooks in a packet --------------------------------------------------------

/// The next codeword of `book`: the sorted index of its entry, or null at
/// the packet's end or a codeword the book does not have.
fn decodeIndex(bits: *Bits, book: *const setup.Codebook) ?u32 {
    if (book.used == 0) {
        bits.ended = true;
        return null;
    }
    if (bits.count < 32) bits.refill();
    if (book.used == 1) {
        bits.drop(book.lengths[0]);
        return if (bits.ended) null else 0;
    }
    if (book.fast_bits != 0) {
        const mask = (@as(u64, 1) << @intCast(book.fast_bits)) - 1;
        const slot = book.fast[@intCast(bits.cache & mask)];
        if (slot != 0) {
            const index = slot - 1;
            bits.drop(book.lengths[index]);
            return if (bits.ended) null else index;
        }
    }
    // A longer codeword: the greatest one no larger than what the stream
    // holds, read from its first bit down.
    const held: u32 = @bitReverse(@as(u32, @truncate(bits.cache)));
    var low: u32 = 0;
    var high: u32 = book.used;
    while (high - low > 1) {
        const middle = low + (high - low) / 2;
        if (book.codes[middle] <= held) low = middle else high = middle;
    }
    const length: u32 = book.lengths[low];
    const differs = if (length < 32) (book.codes[low] ^ held) >> @intCast(32 - length) != 0 else book.codes[low] != held;
    if (differs) {
        bits.ended = true;
        return null;
    }
    bits.drop(length);
    return if (bits.ended) null else low;
}

/// A number from `book`: the entry its codeword stands for.
fn decodeScalar(bits: *Bits, book: *const setup.Codebook) ?u32 {
    const index = decodeIndex(bits, book) orelse return null;
    return book.numbers[index];
}

// --- the packet -------------------------------------------------------------------

/// The next packet decoded: its sound, if it hands any out, in the
/// stream's outputs, `ready` frames of it.
pub fn decode(stream: *Stream, v: *Vorbis) Outcome {
    if (!ogg.startPacket(stream, &v.ogg)) return .end;
    var bits: Bits = .{ .stream = stream, .ogg = &v.ogg };
    const s = &v.setup;
    if (bits.read(1) != 0) return pass(stream, v);
    const mode_index = bits.read(s.mode_bits);
    if (bits.ended or mode_index >= s.mode_count) return pass(stream, v);
    const mode = s.modes[mode_index];
    const n = v.blocksizes[@intFromBool(mode.long)];
    const short = v.blocksizes[0];
    var previous_long = false;
    var next_long = false;
    if (mode.long) {
        previous_long = bits.read(1) != 0;
        next_long = bits.read(1) != 0;
    }
    const half = n / 2;
    // Where the window rises and falls in this block.
    const left_start = if (mode.long and !previous_long) (n - short) / 4 else 0;
    const left_end = if (mode.long and !previous_long) (n + short) / 4 else half;
    const right_start = if (mode.long and !next_long) (3 * n - short) / 4 else half;
    const right_end = if (mode.long and !next_long) (3 * n + short) / 4 else n;

    const map = &s.mappings[mode.mapping];
    const channels = v.channels;

    // The floors; then which residues are decoded.
    var decoded: [2]bool = .{ false, false };
    for (0..channels) |channel| {
        const floor = &s.floors[map.submap_floor[map.mux[channel]]];
        v.used[channel] = floorDecode(&bits, s, floor, &v.final_y[channel], &v.step2[channel]);
        decoded[channel] = v.used[channel];
    }
    for (0..map.coupling_steps) |step| {
        const magnitude = map.magnitude[step];
        const angle = map.angle[step];
        if (decoded[magnitude] or decoded[angle]) {
            decoded[magnitude] = true;
            decoded[angle] = true;
        }
    }

    for (0..channels) |channel| @memset(v.buffers[channel][0..half], 0);
    for (0..map.submaps) |submap| {
        var vectors: [2][*]f32 = undefined;
        var skip: [2]bool = undefined;
        var count: usize = 0;
        for (0..channels) |channel| {
            if (map.mux[channel] != submap) continue;
            vectors[count] = v.buffers[channel];
            skip[count] = !decoded[channel];
            count += 1;
        }
        residueDecode(&bits, s, v, &s.residues[map.submap_residue[submap]], vectors[0..count], skip[0..count], half);
    }

    // The channels uncoupled, last step first.
    var step = map.coupling_steps;
    while (step > 0) {
        step -= 1;
        const magnitudes = v.buffers[map.magnitude[step]];
        const angles = v.buffers[map.angle[step]];
        for (0..half) |i| {
            const m = magnitudes[i];
            const a = angles[i];
            if (m > 0) {
                if (a > 0) {
                    angles[i] = m - a;
                } else {
                    angles[i] = m;
                    magnitudes[i] = m + a;
                }
            } else {
                if (a > 0) {
                    angles[i] = m + a;
                } else {
                    angles[i] = m;
                    magnitudes[i] = m - a;
                }
            }
        }
    }

    // The floors laid over; a channel whose floor is unused is silent.
    for (0..channels) |channel| {
        const buffer = v.buffers[channel];
        if (!v.used[channel]) {
            @memset(buffer[0..n], 0);
            continue;
        }
        const floor = &s.floors[map.submap_floor[map.mux[channel]]];
        floorApply(floor, &v.final_y[channel], &v.step2[channel], buffer, half);
        imdct.inverse(&v.transforms[@intFromBool(mode.long)], buffer);
    }

    ogg.endPacket(stream, &v.ogg);
    overlap(v, n, left_start, left_end, right_start, right_end);
    return .decoded;
}

/// A packet that is no audio, or cannot be decoded, passed over.
fn pass(stream: *Stream, v: *Vorbis) Outcome {
    ogg.endPacket(stream, &v.ogg);
    return .passed;
}

/// The block windowed and overlapped with the one before: its sound from
/// the middle of that block to the middle of this one into the outputs,
/// and what follows this one's middle kept for the next.
fn overlap(v: *Vorbis, n: u32, left_start: u32, left_end: u32, right_start: u32, right_end: u32) void {
    const half = n / 2;
    const left_window = windowFor(v, left_end - left_start);
    const right_window = windowFor(v, right_end - right_start);
    const right_length = right_end - right_start;
    var length: u32 = 0;
    if (v.previous_n != 0) length = v.previous_start + half - left_start;
    length = @min(length, v.blocksizes[1]);

    for (0..v.channels) |channel| {
        const buffer = v.buffers[channel];
        const kept = v.overlaps[channel];
        const output = v.outputs[channel];
        if (v.previous_n != 0) {
            const previous_half = v.previous_n / 2;
            // This block's first half, faded in, laid where the earlier
            // block's slope is.
            for (0..length) |k| {
                var sample: f32 = if (k < previous_half) kept[k] else 0;
                const j = @as(i64, @intCast(k)) + left_start - v.previous_start;
                if (j >= 0 and j < half) {
                    const at: u32 = @intCast(j);
                    const gain: f32 = if (at < left_start) 0 else if (at < left_end) left_window[at - left_start] else 1;
                    sample += buffer[at] * gain;
                }
                output[k] = sample;
            }
        }
        // The second half kept, faded out.
        for (half..n) |j| {
            const at: u32 = @intCast(j);
            const gain: f32 = if (at < right_start) 1 else if (at < right_end) right_window[right_length - 1 - (at - right_start)] else 0;
            kept[j - half] = buffer[j] * gain;
        }
    }
    v.previous_n = n;
    v.previous_start = right_start - half;
    v.ready = length;
    v.ready_start = 0;
}

/// The rising slope `length` long: a short block's or a long one's.
fn windowFor(v: *const Vorbis, length: u32) [*]const f32 {
    return if (length == v.blocksizes[0] / 2) v.transforms[0].window else v.transforms[1].window;
}

// --- floor 1 ----------------------------------------------------------------------

/// A channel's floor read: its points' final amplitudes, and which of them
/// the curve is drawn through. False for a floor that is unused - or the
/// packet ended in it.
fn floorDecode(bits: *Bits, s: *const setup.Setup, floor: *const setup.Floor, final_y: *[65]i32, drawn: *[65]bool) bool {
    if (bits.read(1) == 0) return false;
    const ranges = [4]i32{ 256, 128, 86, 64 };
    const range = ranges[floor.multiplier - 1];
    const y_bits = setup.ilog(@intCast(range - 1));
    var y: [65]i32 = undefined;
    y[0] = @intCast(bits.read(y_bits));
    y[1] = @intCast(bits.read(y_bits));
    var offset: usize = 2;
    for (floor.partition_class[0..floor.partitions]) |class| {
        const dimensions = floor.class_dimensions[class];
        const sub_bits: u5 = @intCast(floor.class_subclasses[class]);
        const sub_mask = (@as(u32, 1) << sub_bits) - 1;
        var value: u32 = 0;
        if (sub_bits != 0) value = decodeScalar(bits, &s.codebooks[floor.class_masterbook[class]]) orelse return false;
        for (0..dimensions) |_| {
            const book = floor.subclass_books[class][value & sub_mask];
            value >>= sub_bits;
            y[offset] = if (book >= 0) @intCast(decodeScalar(bits, &s.codebooks[@intCast(book)]) orelse return false) else 0;
            offset += 1;
        }
    }
    if (bits.ended) return false;

    // The amplitudes: each point predicted from its neighbours, the
    // packet's value the step from there.
    drawn[0] = true;
    drawn[1] = true;
    final_y[0] = y[0];
    final_y[1] = y[1];
    for (2..floor.values) |point| {
        const low = floor.low[point];
        const high = floor.high[point];
        const predicted = renderPoint(floor.x[low], final_y[low], floor.x[high], final_y[high], floor.x[point]);
        const value = y[point];
        const high_room = range - predicted;
        const low_room = predicted;
        const room = if (high_room < low_room) high_room * 2 else low_room * 2;
        if (value != 0) {
            drawn[low] = true;
            drawn[high] = true;
            drawn[point] = true;
            final_y[point] = if (value >= room)
                (if (high_room > low_room) value - low_room + predicted else predicted - value + high_room - 1)
            else if (value & 1 != 0)
                predicted - @divTrunc(value + 1, 2)
            else
                predicted + @divTrunc(value, 2);
        } else {
            drawn[point] = false;
            final_y[point] = predicted;
        }
    }
    for (final_y[0..floor.values]) |*amplitude| amplitude.* = @max(0, @min(amplitude.*, range - 1));
    return true;
}

/// Y at X on the line between two points.
fn renderPoint(x0: u32, y0: i32, x1: u32, y1: i32, x: u32) i32 {
    const dy = y1 - y0;
    const adx: i32 = @intCast(x1 - x0);
    const err = @as(i32, @intCast(@abs(dy))) * @as(i32, @intCast(x - x0));
    const off = @divTrunc(err, adx);
    return if (dy < 0) y0 - off else y0 + off;
}

/// The curve through the points drawn, in X's order, multiplied into the
/// first `half` of `buffer`.
fn floorApply(floor: *const setup.Floor, final_y: *const [65]i32, drawn: *const [65]bool, buffer: [*]f32, half: u32) void {
    const multiplier: i32 = @intCast(floor.multiplier);
    var lx: u32 = 0;
    var ly: i32 = final_y[floor.sorted[0]] * multiplier;
    for (floor.sorted[1..floor.values]) |point| {
        if (!drawn[point]) continue;
        const hx = floor.x[point];
        const hy = final_y[point] * multiplier;
        if (lx < hx) renderLine(lx, ly, hx, hy, buffer, half);
        lx = hx;
        ly = hy;
    }
    var x = lx;
    while (x < half) : (x += 1) buffer[x] *= inverse_db[@intCast(ly)];
}

/// The line from (x0, y0) up to x1, in whole steps as the format draws it,
/// multiplied into `buffer` below `limit`.
fn renderLine(x0: u32, y0: i32, x1: u32, y1: i32, buffer: [*]f32, limit: u32) void {
    const dy = y1 - y0;
    const adx: i32 = @intCast(x1 - x0);
    var ady: i32 = @intCast(@abs(dy));
    const base = @divTrunc(dy, adx);
    const sy = if (dy < 0) base - 1 else base + 1;
    ady -= @as(i32, @intCast(@abs(base))) * adx;
    var y = y0;
    var err: i32 = 0;
    const end = @min(x1, limit);
    var x = x0;
    if (x < end) buffer[x] *= inverse_db[@intCast(y)];
    x += 1;
    while (x < end) : (x += 1) {
        err += ady;
        if (err >= adx) {
            err -= adx;
            y += sy;
        } else {
            y += base;
        }
        buffer[x] *= inverse_db[@intCast(y)];
    }
}

// --- residue ----------------------------------------------------------------------

/// A submap's residue vectors decoded and added into `vectors`, each
/// `half` long; those marked `skip` left as they are, but for format 2,
/// which decodes all of them when it decodes any.
fn residueDecode(bits: *Bits, s: *const setup.Setup, v: *Vorbis, r: *const setup.Residue, vectors: [][*]f32, skip: []bool, half: u32) void {
    const count: u32 = @intCast(vectors.len);
    var interleaved = false;
    var lanes: u32 = count;
    if (r.kind == 2) {
        var any = false;
        for (skip) |passed| any = any or !passed;
        if (!any) return;
        interleaved = true;
        lanes = 1;
    }
    const actual: u32 = if (interleaved) half * count else half;
    const begin = @min(r.begin, actual);
    const end = @min(r.end, actual);
    if (end <= begin) return;
    const partitions = (end - begin) / r.partition_size;
    if (partitions == 0) return;
    const classbook = &s.codebooks[r.classbook];
    const per_word = classbook.dimensions;
    const classes = v.classifications;
    const stride = v.class_stride;

    for (0..8) |pass_number| {
        var partition: u32 = 0;
        while (partition < partitions) {
            if (pass_number == 0) {
                for (0..lanes) |lane| {
                    if (!interleaved and skip[lane]) continue;
                    var word = decodeScalar(bits, classbook) orelse return;
                    var i = per_word;
                    while (i > 0) {
                        i -= 1;
                        if (partition + i < partitions) classes[lane * stride + partition + i] = @intCast(word % r.classifications);
                        word /= r.classifications;
                    }
                }
            }
            var i: u32 = 0;
            while (i < per_word and partition < partitions) : (i += 1) {
                for (0..lanes) |lane| {
                    if (!interleaved and skip[lane]) continue;
                    const class = classes[lane * stride + partition];
                    const book_index = r.books[class][pass_number];
                    if (book_index < 0) continue;
                    const book = &s.codebooks[@intCast(book_index)];
                    const offset = begin + partition * r.partition_size;
                    const done = if (interleaved)
                        partitionInterleaved(bits, book, vectors, offset, r.partition_size, actual)
                    else if (r.kind == 0)
                        partitionSpread(bits, book, vectors[lane], offset, r.partition_size, half)
                    else
                        partitionInOrder(bits, book, vectors[lane], offset, r.partition_size, half);
                    if (!done) return;
                }
                partition += 1;
            }
        }
    }
}

/// Format 0: the partition's vectors interleaved by their dimensions.
fn partitionSpread(bits: *Bits, book: *const setup.Codebook, vector: [*]f32, offset: u32, size: u32, limit: u32) bool {
    const dimensions = book.dimensions;
    const step = size / dimensions;
    for (0..step) |i| {
        const index = decodeIndex(bits, book) orelse return false;
        const values = book.vectors.? + @as(usize, index) * dimensions;
        for (0..dimensions) |d| {
            const at = offset + i + d * step;
            if (at < limit) vector[at] += values[d];
        }
    }
    return true;
}

/// Format 1: the partition's vectors one after the other.
fn partitionInOrder(bits: *Bits, book: *const setup.Codebook, vector: [*]f32, offset: u32, size: u32, limit: u32) bool {
    const dimensions = book.dimensions;
    var i: u32 = 0;
    while (i < size) {
        const index = decodeIndex(bits, book) orelse return false;
        const values = book.vectors.? + @as(usize, index) * dimensions;
        for (0..dimensions) |d| {
            const at = offset + i;
            if (at < limit) vector[at] += values[d];
            i += 1;
        }
    }
    return true;
}

/// Format 2: as format 1 over all the channels interleaved, sample by
/// sample.
fn partitionInterleaved(bits: *Bits, book: *const setup.Codebook, vectors: [][*]f32, offset: u32, size: u32, limit: u32) bool {
    const dimensions = book.dimensions;
    const count: u32 = @intCast(vectors.len);
    var i: u32 = 0;
    while (i < size) {
        const index = decodeIndex(bits, book) orelse return false;
        const values = book.vectors.? + @as(usize, index) * dimensions;
        for (0..dimensions) |d| {
            const at = offset + i;
            if (at < limit) vectors[at % count][at / count] += values[d];
            i += 1;
        }
    }
    return true;
}
