// SPDX-License-Identifier: MIT
//! MPEG-1, 2 and 2.5 audio, Layer III - MP3 - from a frame's bytes to
//! 16-bit samples. Nothing here touches the system: the bytes come in a
//! buffer, the samples go into one, and all the state is the caller's
//! (`Decoder` between frames, `Scratch` for the frame being decoded), so
//! the host tests run all of it.
//!
//! **A frame** is a header (sync, version, layer, bit rate, sample rate,
//! mode), side information - for each granule and channel where its bits
//! are, how its scale factors are coded and which Huffman tables cover
//! which part of the spectrum - and the main data, which may begin in the
//! frames before it: the bit reservoir (`restoreReservoir`,
//! `saveReservoir`). An MPEG-1 frame holds two granules of 576 samples per
//! channel, an MPEG-2 or 2.5 one a single granule.
//!
//! **A granule** is decoded as the format lays it down: the scale factors
//! (`decodeScalefactors`), the Huffman-coded values dequantized by them
//! (`huffman`), joint stereo undone - mid/side, intensity - (`decode`), the
//! short blocks put back in frequency order (`reorder`), the aliasing
//! between subbands taken out (`antialias`), the inverse MDCT with its
//! overlap (`imdctGranule`), and the polyphase synthesis filter
//! (`synthGranule`) that turns 32 subbands into samples, rounded to 16
//! bits.
//!
//! **Finding a frame** asks more than a sync word: the header must be one
//! that can be, and so must the next several frames' at the distances the
//! first one gives (`findFrame`), so a run of bytes in a tag or in a
//! picture that happens to look like a header is passed over. A free
//! format stream - a bit rate the header does not name - has its frame
//! length measured from header to header.
//!
//! Layers I and II are recognized - their frames are found and their
//! length known - and not decoded: `decodeFrame` answers no samples for
//! them, with the layer in the frame's info.

const tables = @import("tables.zig");

/// The most samples one frame decodes to: 1152 a channel, two channels.
pub const max_samples_per_frame = 1152 * 2;

/// The longest a frame may be: a free-format frame at the highest rate.
pub const max_frame_bytes = 2304;

/// How many frames after the first must agree with it before it counts as
/// found.
const max_frame_sync_matches = 10;
const max_l3_frame_payload_bytes = max_frame_bytes;
const max_bitreservoir_bytes = 511;
const short_block_type = 2;
const stop_block_type = 3;
const header_size = 4;
const bits_dequantizer_out = -1;
const max_scf = 255 + bits_dequantizer_out * 4 - 210;
const max_scfi = (max_scf + 3) & ~@as(i32, 3);

/// What has to last from one frame to the next: each channel's overlap
/// from the inverse MDCT, the synthesis filter's state, the reservoir's
/// bytes, and the last frame's header.
pub const Decoder = struct {
    mdct_overlap: [2][9 * 32]f32 = @splat(@splat(0)),
    qmf_state: [15 * 2 * 32]f32 = @splat(0),
    reserv: i32 = 0,
    free_format_bytes: i32 = 0,
    header: [4]u8 = .{ 0, 0, 0, 0 },
    reserv_buf: [max_bitreservoir_bytes]u8 = @splat(0),

    /// Forget everything: the next frame is found afresh.
    pub fn reset(dec: *Decoder) void {
        dec.header[0] = 0;
    }
};

/// What one frame's decoding works in, about 16 KiB: kept by the caller,
/// so it is not on a task's stack.
pub const Scratch = struct {
    bs: BitStream = .{},
    /// The main data: the reservoir's bytes and the frame's, with a few
    /// bytes' slack for the Huffman decoder's look ahead.
    maindata: [max_bitreservoir_bytes + max_l3_frame_payload_bytes + 8]u8 = @splat(0),
    gr_info: [4]GrInfo = @splat(.{}),
    /// Both channels' granule, the right one 576 values after the left.
    grbuf: [2 * 576]f32 = @splat(0),
    scf: [40]f32 = @splat(0),
    syn: [(18 + 15) * 2 * 32]f32 = @splat(0),
    ist_pos: [2][39]u8 = @splat(@splat(0)),
};

/// What a frame is, as `decodeFrame` finds it.
pub const FrameInfo = struct {
    /// The bytes it took: whatever was passed over to find it, and the
    /// frame itself.
    frame_bytes: u32 = 0,
    /// Where in those bytes the frame began.
    frame_offset: u32 = 0,
    channels: u32 = 0,
    hz: u32 = 0,
    /// 1, 2 or 3.
    layer: u32 = 0,
    bitrate_kbps: u32 = 0,
};

// --- the header -------------------------------------------------------------------

fn isMono(h: [*]const u8) bool {
    return h[3] & 0xC0 == 0xC0;
}
fn isMsStereo(h: [*]const u8) bool {
    return h[3] & 0xE0 == 0x60;
}
fn isFreeFormat(h: [*]const u8) bool {
    return h[2] & 0xF0 == 0;
}
fn isCrc(h: [*]const u8) bool {
    return h[1] & 1 == 0;
}
fn testPadding(h: [*]const u8) bool {
    return h[2] & 0x2 != 0;
}
pub fn testMpeg1(h: [*]const u8) bool {
    return h[1] & 0x8 != 0;
}
fn testNotMpeg25(h: [*]const u8) bool {
    return h[1] & 0x10 != 0;
}
fn testIStereo(h: [*]const u8) bool {
    return h[3] & 0x10 != 0;
}
fn testMsStereo(h: [*]const u8) bool {
    return h[3] & 0x20 != 0;
}
fn getLayer(h: [*]const u8) u32 {
    return (h[1] >> 1) & 3;
}
fn getBitrate(h: [*]const u8) u32 {
    return h[2] >> 4;
}
fn getSampleRate(h: [*]const u8) u32 {
    return (h[2] >> 2) & 3;
}
/// The sample rate as an index over all three versions: MPEG-1 0 to 2,
/// MPEG-2 3 to 5, MPEG-2.5 6 to 8.
fn getMySampleRate(h: [*]const u8) u32 {
    return getSampleRate(h) + (((h[1] >> 3) & 1) + ((h[1] >> 4) & 1)) * 3;
}
fn isFrame576(h: [*]const u8) bool {
    return h[1] & 14 == 2;
}
fn isLayer1(h: [*]const u8) bool {
    return h[1] & 6 == 6;
}

/// Whether four bytes are a header that can be: the sync, a layer, a bit
/// rate and a sample rate that exist.
pub fn headerValid(h: [*]const u8) bool {
    return h[0] == 0xff and
        ((h[1] & 0xF0) == 0xf0 or (h[1] & 0xFE) == 0xe2) and
        getLayer(h) != 0 and
        getBitrate(h) != 15 and
        getSampleRate(h) != 3;
}

/// Whether `h2` is a header of the same stream as `h1`.
fn headerCompare(h1: [*]const u8, h2: [*]const u8) bool {
    return headerValid(h2) and
        ((h1[1] ^ h2[1]) & 0xFE) == 0 and
        ((h1[2] ^ h2[2]) & 0x0C) == 0 and
        isFreeFormat(h1) == isFreeFormat(h2);
}

const halfrate = [2][3][15]u8{
    .{
        .{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80 },
        .{ 0, 4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80 },
        .{ 0, 16, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96, 112, 128 },
    },
    .{
        .{ 0, 16, 20, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160 },
        .{ 0, 16, 24, 28, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192 },
        .{ 0, 16, 32, 48, 64, 80, 96, 112, 128, 144, 160, 176, 192, 208, 224 },
    },
};

pub fn headerBitrateKbps(h: [*]const u8) u32 {
    return 2 * @as(u32, halfrate[@intFromBool(testMpeg1(h))][getLayer(h) - 1][getBitrate(h)]);
}

pub fn headerSampleRateHz(h: [*]const u8) u32 {
    const hz = [3]u32{ 44100, 48000, 32000 };
    return hz[getSampleRate(h)] >> @intFromBool(!testMpeg1(h)) >> @intFromBool(!testNotMpeg25(h));
}

pub fn headerFrameSamples(h: [*]const u8) u32 {
    return if (isLayer1(h)) 384 else @as(u32, 1152) >> @intFromBool(isFrame576(h));
}

pub fn headerChannels(h: [*]const u8) u32 {
    return if (isMono(h)) 1 else 2;
}

pub fn headerLayer(h: [*]const u8) u32 {
    return 4 - getLayer(h);
}

/// The frame's length without its padding: from the bit rate, or for a
/// free-format stream the length measured.
fn headerFrameBytes(h: [*]const u8, free_format_size: i32) i32 {
    var frame_bytes: i32 = @intCast(headerFrameSamples(h) * headerBitrateKbps(h) * 125 / headerSampleRateHz(h));
    if (isLayer1(h)) frame_bytes &= ~@as(i32, 3);
    return if (frame_bytes != 0) frame_bytes else free_format_size;
}

fn headerPadding(h: [*]const u8) i32 {
    return if (testPadding(h)) (if (isLayer1(h)) 4 else 1) else 0;
}

// --- reading bits -----------------------------------------------------------------

pub const BitStream = struct {
    buf: [*]const u8 = undefined,
    pos: i32 = 0,
    limit: i32 = 0,
};

fn bsInit(bs: *BitStream, data: [*]const u8, bytes: i32) void {
    bs.buf = data;
    bs.pos = 0;
    bs.limit = bytes * 8;
}

/// The next `n` bits, most significant first; 0 once past the end.
fn getBits(bs: *BitStream, n: i32) u32 {
    const s: u32 = @intCast(bs.pos & 7);
    var shl: i32 = n + @as(i32, @intCast(s));
    var p = bs.buf + @as(usize, @intCast(bs.pos >> 3));
    bs.pos += n;
    if (bs.pos > bs.limit) return 0;
    var next: u32 = p[0] & (@as(u32, 255) >> @intCast(s));
    p += 1;
    var cache: u32 = 0;
    shl -= 8;
    while (shl > 0) : (shl -= 8) {
        cache |= next << @intCast(shl);
        next = p[0];
        p += 1;
    }
    return cache | (next >> @intCast(-shl));
}

// --- side information -------------------------------------------------------------

/// A granule of one channel, as its side information describes it.
pub const GrInfo = struct {
    sfbtab: [*]const u8 = &tables.scf_long[0],
    part_23_length: u16 = 0,
    big_values: u16 = 0,
    scalefac_compress: u16 = 0,
    global_gain: u8 = 0,
    block_type: u8 = 0,
    mixed_block_flag: u8 = 0,
    n_long_sfb: u8 = 0,
    n_short_sfb: u8 = 0,
    table_select: [3]u8 = .{ 0, 0, 0 },
    region_count: [3]u8 = .{ 0, 0, 0 },
    subblock_gain: [3]u8 = .{ 0, 0, 0 },
    preflag: u8 = 0,
    scalefac_scale: u8 = 0,
    count1_table: u8 = 0,
    scfsi: u8 = 0,
};

/// The side information into `gr` - two granules of two channels at most
/// - and where the main data begins, in bytes before this frame's; -1 for
/// side information that cannot be.
pub fn readSideInfo(bs: *BitStream, gr_first: [*]GrInfo, hdr: [*]const u8) i32 {
    var tables_bits: u32 = 0;
    var scfsi: u32 = 0;
    var main_data_begin: i32 = 0;
    var part_23_sum: i32 = 0;
    var sr_idx: usize = getMySampleRate(hdr);
    if (sr_idx != 0) sr_idx -= 1;
    var gr_count: u32 = if (isMono(hdr)) 1 else 2;
    const mpeg1 = testMpeg1(hdr);

    if (mpeg1) {
        gr_count *= 2;
        main_data_begin = @intCast(getBits(bs, 9));
        scfsi = getBits(bs, @intCast(7 + gr_count));
    } else {
        main_data_begin = @intCast(getBits(bs, @intCast(8 + gr_count)) >> @intCast(gr_count));
    }

    var gr = gr_first;
    while (gr_count > 0) : (gr_count -= 1) {
        if (isMono(hdr)) scfsi <<= 4;
        gr[0].part_23_length = @intCast(getBits(bs, 12));
        part_23_sum += gr[0].part_23_length;
        gr[0].big_values = @intCast(getBits(bs, 9));
        if (gr[0].big_values > 288) return -1;
        gr[0].global_gain = @intCast(getBits(bs, 8));
        gr[0].scalefac_compress = @intCast(getBits(bs, if (mpeg1) 4 else 9));
        gr[0].sfbtab = &tables.scf_long[sr_idx];
        gr[0].n_long_sfb = 22;
        gr[0].n_short_sfb = 0;
        if (getBits(bs, 1) != 0) {
            gr[0].block_type = @intCast(getBits(bs, 2));
            if (gr[0].block_type == 0) return -1;
            gr[0].mixed_block_flag = @intCast(getBits(bs, 1));
            gr[0].region_count[0] = 7;
            gr[0].region_count[1] = 255;
            gr[0].region_count[2] = 255;
            if (gr[0].block_type == short_block_type) {
                scfsi &= 0x0F0F;
                if (gr[0].mixed_block_flag == 0) {
                    gr[0].region_count[0] = 8;
                    gr[0].sfbtab = &tables.scf_short[sr_idx];
                    gr[0].n_long_sfb = 0;
                    gr[0].n_short_sfb = 39;
                } else {
                    gr[0].sfbtab = &tables.scf_mixed[sr_idx];
                    gr[0].n_long_sfb = if (mpeg1) 8 else 6;
                    gr[0].n_short_sfb = 30;
                }
            }
            tables_bits = getBits(bs, 10);
            tables_bits <<= 5;
            gr[0].subblock_gain[0] = @intCast(getBits(bs, 3));
            gr[0].subblock_gain[1] = @intCast(getBits(bs, 3));
            gr[0].subblock_gain[2] = @intCast(getBits(bs, 3));
        } else {
            gr[0].block_type = 0;
            gr[0].mixed_block_flag = 0;
            tables_bits = getBits(bs, 15);
            gr[0].region_count[0] = @intCast(getBits(bs, 4));
            gr[0].region_count[1] = @intCast(getBits(bs, 3));
            gr[0].region_count[2] = 255;
        }
        gr[0].table_select[0] = @intCast(tables_bits >> 10);
        gr[0].table_select[1] = @intCast((tables_bits >> 5) & 31);
        gr[0].table_select[2] = @intCast(tables_bits & 31);
        gr[0].preflag = if (mpeg1) @intCast(getBits(bs, 1)) else @intFromBool(gr[0].scalefac_compress >= 500);
        gr[0].scalefac_scale = @intCast(getBits(bs, 1));
        gr[0].count1_table = @intCast(getBits(bs, 1));
        gr[0].scfsi = @intCast((scfsi >> 12) & 15);
        scfsi <<= 4;
        gr += 1;
    }

    if (part_23_sum + bs.pos > bs.limit + main_data_begin * 8) return -1;
    return main_data_begin;
}

// --- scale factors ----------------------------------------------------------------

fn readScalefactors(scf_in: [*]u8, ist_in: [*]u8, scf_size: *const [4]u8, scf_count: [*]const u8, bitbuf: *BitStream, scfsi_in: i32) void {
    var scf = scf_in;
    var ist_pos = ist_in;
    var scfsi = scfsi_in;
    var i: usize = 0;
    while (i < 4 and scf_count[i] != 0) : ({
        i += 1;
        scfsi *%= 2;
    }) {
        const cnt: usize = scf_count[i];
        if (scfsi & 8 != 0) {
            @memcpy(scf[0..cnt], ist_pos[0..cnt]);
        } else {
            const bits = scf_size[i];
            if (bits == 0) {
                @memset(scf[0..cnt], 0);
                @memset(ist_pos[0..cnt], 0);
            } else {
                const max_scf_value: i32 = if (scfsi < 0) (@as(i32, 1) << @intCast(bits)) - 1 else -1;
                for (0..cnt) |k| {
                    const s: i32 = @intCast(getBits(bitbuf, bits));
                    ist_pos[k] = if (s == max_scf_value) 255 else @intCast(s);
                    scf[k] = @intCast(s);
                }
            }
        }
        ist_pos += cnt;
        scf += cnt;
    }
    scf[0] = 0;
    scf[1] = 0;
    scf[2] = 0;
}

/// `y` times 2 to the minus `exp_q2` quarters.
fn ldexpQ2(y_in: f32, exp_in: i32) f32 {
    var y = y_in;
    var exp_q2 = exp_in;
    while (true) {
        const e = @min(30 * 4, exp_q2);
        const whole: i32 = @as(i32, 1 << 30) >> @intCast(e >> 2);
        y *= tables.expfrac[@intCast(e & 3)] * @as(f32, @floatFromInt(whole));
        exp_q2 -= e;
        if (exp_q2 <= 0) break;
    }
    return y;
}

fn decodeScalefactors(hdr: [*]const u8, ist_pos: [*]u8, bs: *BitStream, gr: *const GrInfo, scf: [*]f32, ch: usize) void {
    var scf_partition: [*]const u8 = &tables.scf_partitions[@as(usize, @intFromBool(gr.n_short_sfb != 0)) + @intFromBool(gr.n_long_sfb == 0)];
    var scf_size: [4]u8 = undefined;
    var iscf: [40]u8 = undefined;
    const scf_shift: u5 = @intCast(gr.scalefac_scale + 1);
    var scfsi: i32 = gr.scfsi;

    if (testMpeg1(hdr)) {
        const part = tables.scfc_decode[gr.scalefac_compress];
        scf_size[0] = part >> 2;
        scf_size[1] = part >> 2;
        scf_size[2] = part & 3;
        scf_size[3] = part & 3;
    } else {
        const ist: u4 = @intFromBool(testIStereo(hdr) and ch != 0);
        var sfc: i32 = gr.scalefac_compress >> ist;
        var k: usize = @as(usize, ist) * 3 * 4;
        var modprod: i32 = 1;
        while (sfc >= 0) : ({
            sfc -= modprod;
            k += 4;
        }) {
            modprod = 1;
            var i: usize = 4;
            while (i > 0) {
                i -= 1;
                scf_size[i] = @intCast(@mod(@divTrunc(sfc, modprod), @as(i32, tables.scf_mod[k + i])));
                modprod *= tables.scf_mod[k + i];
            }
        }
        scf_partition += k;
        scfsi = -16;
    }
    readScalefactors(&iscf, ist_pos, &scf_size, scf_partition, bs, scfsi);

    const n_long: usize = gr.n_long_sfb;
    const n_short: usize = gr.n_short_sfb;
    if (n_short != 0) {
        const sh: u3 = @intCast(3 - @as(u32, scf_shift));
        var i: usize = 0;
        while (i < n_short) : (i += 3) {
            iscf[n_long + i + 0] +%= gr.subblock_gain[0] << sh;
            iscf[n_long + i + 1] +%= gr.subblock_gain[1] << sh;
            iscf[n_long + i + 2] +%= gr.subblock_gain[2] << sh;
        }
    } else if (gr.preflag != 0) {
        for (0..10) |i| iscf[11 + i] +%= tables.preamp[i];
    }

    const gain_exp: i32 = @as(i32, gr.global_gain) + bits_dequantizer_out * 4 - 210 - @as(i32, if (isMsStereo(hdr)) 2 else 0);
    const gain = ldexpQ2(@floatFromInt(@as(i32, 1) << @intCast(@divTrunc(max_scfi, 4))), max_scfi - gain_exp);
    for (0..n_long + n_short) |i| {
        scf[i] = ldexpQ2(gain, @as(i32, iscf[i]) << scf_shift);
    }
}

// --- the values -------------------------------------------------------------------

/// `x` to the power 4/3: from the table for small values, by its nearest
/// entry and two terms of a series for the rest.
fn pow43(x_in: i32) f32 {
    var x = x_in;
    var mult: f32 = 256;
    if (x < 129) return tables.pow43[@intCast(16 + x)];
    if (x < 1024) {
        mult = 16;
        x <<= 3;
    }
    const sign = 2 * x & 64;
    const frac: f32 = @as(f32, @floatFromInt((x & 63) - sign)) / @as(f32, @floatFromInt((x & ~@as(i32, 63)) + sign));
    return tables.pow43[@intCast(16 + ((x + sign) >> 6))] * (1.0 + frac * ((4.0 / 3.0) + frac * (2.0 / 9.0))) * mult;
}

/// The bits a cache of 32 holds at its top, `n` of them.
inline fn peek(cache: u32, n: u32) u32 {
    return @truncate(@as(u64, cache) >> @intCast(32 - n));
}

/// One channel's granule of Huffman-coded values, dequantized by the
/// scale factors into `dst_in`; the bits read up to `layer3gr_limit`.
fn huffman(dst_in: [*]f32, bs: *BitStream, gr: *const GrInfo, scf_in: [*]const f32, layer3gr_limit: i32) void {
    const tabs: [*]const i16 = &tables.huffman;
    var dst = dst_in;
    var scf = scf_in;
    var one: f32 = 0;
    var ireg: usize = 0;
    var big_val_cnt: i32 = gr.big_values;
    var sfb = gr.sfbtab;
    var next = bs.buf + @as(usize, @intCast(bs.pos >> 3));
    var cache: u32 = (((@as(u32, next[0]) * 256 + next[1]) * 256 + next[2]) * 256 + next[3]) << @intCast(bs.pos & 7);
    var sh: i32 = (bs.pos & 7) - 8;
    next += 4;

    const Bits = struct {
        inline fn flush(c: *u32, s: *i32, n: u32) void {
            c.* = if (n >= 32) 0 else c.* << @intCast(n);
            s.* += @intCast(n);
        }
        inline fn check(c: *u32, s: *i32, p: *[*]const u8) void {
            while (s.* >= 0) {
                c.* |= @as(u32, p.*[0]) << @intCast(s.*);
                p.* += 1;
                s.* -= 8;
            }
        }
    };

    while (big_val_cnt > 0) {
        const tab_num = gr.table_select[ireg];
        var sfb_cnt: i32 = gr.region_count[ireg];
        ireg += 1;
        const codebook = tabs + @as(usize, @intCast(tables.tabindex[tab_num]));
        const linbits: u32 = tables.linbits[tab_num];
        while (true) {
            const np: i32 = sfb[0] / 2;
            sfb += 1;
            var pairs_to_decode = @min(big_val_cnt, np);
            one = scf[0];
            scf += 1;
            while (pairs_to_decode > 0) : (pairs_to_decode -= 1) {
                var w: u32 = 5;
                var leaf: i32 = codebook[peek(cache, w)];
                while (leaf < 0) {
                    Bits.flush(&cache, &sh, w);
                    w = @intCast(leaf & 7);
                    leaf = codebook[@intCast(@as(i32, @intCast(peek(cache, w))) - (leaf >> 3))];
                }
                Bits.flush(&cache, &sh, @intCast(leaf >> 8));

                for (0..2) |_| {
                    var lsb: i32 = leaf & 0x0F;
                    if (linbits != 0 and lsb == 15) {
                        lsb += @intCast(peek(cache, linbits));
                        Bits.flush(&cache, &sh, linbits);
                        Bits.check(&cache, &sh, &next);
                        dst[0] = one * pow43(lsb) * @as(f32, if (@as(i32, @bitCast(cache)) < 0) -1 else 1);
                    } else {
                        dst[0] = tables.pow43[@intCast(16 + lsb - 16 * @as(i32, @intCast(cache >> 31)))] * one;
                    }
                    Bits.flush(&cache, &sh, @intFromBool(lsb != 0));
                    dst += 1;
                    leaf >>= 4;
                }
                Bits.check(&cache, &sh, &next);
            }
            big_val_cnt -= np;
            if (big_val_cnt <= 0) break;
            sfb_cnt -= 1;
            if (sfb_cnt < 0) break;
        }
    }

    // The count1 region: values of -1, 0 or 1, four at a time.
    var np: i32 = 1 - big_val_cnt;
    const codebook_count1: [*]const u8 = if (gr.count1_table != 0) &tables.count1_b else &tables.count1_a;
    count1: while (true) : (dst += 4) {
        var leaf: u32 = codebook_count1[peek(cache, 4)];
        if (leaf & 8 == 0) {
            leaf = codebook_count1[(leaf >> 3) + peek(if ((leaf & 3) == 0) 0 else cache << 4, leaf & 3)];
        }
        Bits.flush(&cache, &sh, leaf & 7);
        const at: i32 = @as(i32, @intCast((@intFromPtr(next) - @intFromPtr(bs.buf)) * 8)) - 24 + sh;
        if (at > layer3gr_limit) break;
        inline for (.{ 0, 2 }) |first| {
            np -= 1;
            if (np == 0) {
                np = sfb[0] / 2;
                sfb += 1;
                if (np == 0) break :count1;
                one = scf[0];
                scf += 1;
            }
            inline for (.{ first, first + 1 }) |s| {
                if (leaf & (128 >> s) != 0) {
                    dst[s] = if (@as(i32, @bitCast(cache)) < 0) -one else one;
                    Bits.flush(&cache, &sh, 1);
                }
            }
        }
        Bits.check(&cache, &sh, &next);
    }

    bs.pos = layer3gr_limit;
}

// --- stereo -----------------------------------------------------------------------

fn midsideStereo(left: [*]f32, n: usize) void {
    const right = left + 576;
    for (0..n) |i| {
        const a = left[i];
        const b = right[i];
        left[i] = a + b;
        right[i] = a - b;
    }
}

fn intensityStereoBand(left: [*]f32, n: usize, kl: f32, kr: f32) void {
    for (0..n) |i| {
        left[i + 576] = left[i] * kr;
        left[i] = left[i] * kl;
    }
}

fn stereoTopBand(right_in: [*]const f32, sfb: [*]const u8, nbands: usize, max_band: *[3]i32) void {
    var right = right_in;
    max_band.* = .{ -1, -1, -1 };
    for (0..nbands) |i| {
        var k: usize = 0;
        while (k < sfb[i]) : (k += 2) {
            if (right[k] != 0 or right[k + 1] != 0) {
                max_band[i % 3] = @intCast(i);
                break;
            }
        }
        right += sfb[i];
    }
}

fn stereoProcess(left_in: [*]f32, ist_pos: [*]const u8, sfb: [*]const u8, hdr: [*]const u8, max_band: *const [3]i32, mpeg2_sh: u5) void {
    var left = left_in;
    const max_pos: u32 = if (testMpeg1(hdr)) 7 else 64;
    var i: usize = 0;
    while (sfb[i] != 0) : (i += 1) {
        const ipos: u32 = ist_pos[i];
        if (@as(i32, @intCast(i)) > max_band[i % 3] and ipos < max_pos) {
            const s: f32 = if (testMsStereo(hdr)) 1.41421356 else 1;
            var kl: f32 = undefined;
            var kr: f32 = undefined;
            if (testMpeg1(hdr)) {
                kl = tables.pan[2 * ipos];
                kr = tables.pan[2 * ipos + 1];
            } else {
                kl = 1;
                kr = ldexpQ2(1, @intCast((ipos + 1) >> 1 << mpeg2_sh));
                if (ipos & 1 != 0) {
                    kl = kr;
                    kr = 1;
                }
            }
            intensityStereoBand(left, sfb[i], kl * s, kr * s);
        } else if (testMsStereo(hdr)) {
            midsideStereo(left, sfb[i]);
        }
        left += sfb[i];
    }
}

fn intensityStereo(left: [*]f32, ist_pos: [*]u8, gr: [*]const GrInfo, hdr: [*]const u8) void {
    var max_band: [3]i32 = undefined;
    const n_sfb: usize = @as(usize, gr[0].n_long_sfb) + gr[0].n_short_sfb;
    const max_blocks: usize = if (gr[0].n_short_sfb != 0) 3 else 1;

    stereoTopBand(left + 576, gr[0].sfbtab, n_sfb, &max_band);
    if (gr[0].n_long_sfb != 0) {
        const most = @max(@max(max_band[0], max_band[1]), max_band[2]);
        max_band = .{ most, most, most };
    }
    for (0..max_blocks) |i| {
        const default_pos: u8 = if (testMpeg1(hdr)) 3 else 0;
        const itop = n_sfb - max_blocks + i;
        const prev = @as(i32, @intCast(itop)) - @as(i32, @intCast(max_blocks));
        ist_pos[itop] = if (max_band[i] >= prev) default_pos else ist_pos[@intCast(prev)];
    }
    stereoProcess(left, ist_pos, gr[0].sfbtab, hdr, &max_band, @intCast(gr[1].scalefac_compress & 1));
}

// --- short blocks, aliasing, the inverse MDCT -------------------------------------

/// The short blocks' values, which come window by window, put back in
/// order of frequency.
fn reorder(grbuf: [*]f32, scratch: [*]f32, sfb_in: [*]const u8) void {
    var sfb = sfb_in;
    var src = grbuf;
    var dst = scratch;
    while (sfb[0] != 0) : (sfb += 3) {
        const len: usize = sfb[0];
        for (0..len) |_| {
            dst[0] = src[0 * len];
            dst[1] = src[1 * len];
            dst[2] = src[2 * len];
            dst += 3;
            src += 1;
        }
        src += 2 * len;
    }
    const count = (@intFromPtr(dst) - @intFromPtr(scratch)) / @sizeOf(f32);
    @memcpy(grbuf[0..count], scratch[0..count]);
}

fn antialias(grbuf_in: [*]f32, nbands_in: i32) void {
    var grbuf = grbuf_in;
    var nbands = nbands_in;
    while (nbands > 0) : ({
        nbands -= 1;
        grbuf += 18;
    }) {
        for (0..8) |i| {
            const u = grbuf[18 + i];
            const d = grbuf[17 - i];
            grbuf[18 + i] = u * tables.antialias[0][i] - d * tables.antialias[1][i];
            grbuf[17 - i] = u * tables.antialias[1][i] + d * tables.antialias[0][i];
        }
    }
}

fn dct3_9(y: *[9]f32) void {
    var s0 = y[0];
    var s2 = y[2];
    var s4 = y[4];
    var s6 = y[6];
    var s8 = y[8];
    var t0 = s0 + s6 * 0.5;
    s0 -= s6;
    var t4 = (s4 + s2) * 0.93969262;
    var t2 = (s8 + s2) * 0.76604444;
    s6 = (s4 - s8) * 0.17364818;
    s4 += s8 - s2;

    s2 = s0 - s4 * 0.5;
    y[4] = s4 + s0;
    s8 = t0 - t2 + s6;
    s0 = t0 - t4 + t2;
    s4 = t0 + t4 - s6;

    var s1 = y[1];
    var s3 = y[3];
    var s5 = y[5];
    var s7 = y[7];

    s3 *= 0.86602540;
    t0 = (s5 + s1) * 0.98480775;
    t4 = (s5 - s7) * 0.34202014;
    t2 = (s1 + s7) * 0.64278761;
    s1 = (s1 - s5 - s7) * 0.86602540;

    s5 = t0 - s3 - t2;
    s7 = t4 - s3 - t0;
    s3 = t4 + s3 - t2;

    y[0] = s4 - s7;
    y[1] = s2 + s1;
    y[2] = s0 - s3;
    y[3] = s8 + s5;
    y[5] = s8 - s5;
    y[6] = s0 + s3;
    y[7] = s2 - s1;
    y[8] = s4 + s7;
}

fn imdct36(grbuf_in: [*]f32, overlap_in: [*]f32, window: [*]const f32, nbands: usize) void {
    var grbuf = grbuf_in;
    var overlap = overlap_in;
    for (0..nbands) |_| {
        var co: [9]f32 = undefined;
        var si: [9]f32 = undefined;
        co[0] = -grbuf[0];
        si[0] = grbuf[17];
        for (0..4) |i| {
            si[8 - 2 * i] = grbuf[4 * i + 1] - grbuf[4 * i + 2];
            co[1 + 2 * i] = grbuf[4 * i + 1] + grbuf[4 * i + 2];
            si[7 - 2 * i] = grbuf[4 * i + 4] - grbuf[4 * i + 3];
            co[2 + 2 * i] = -(grbuf[4 * i + 3] + grbuf[4 * i + 4]);
        }
        dct3_9(&co);
        dct3_9(&si);

        si[1] = -si[1];
        si[3] = -si[3];
        si[5] = -si[5];
        si[7] = -si[7];

        for (0..9) |i| {
            const ovl = overlap[i];
            const sum = co[i] * tables.twid9[9 + i] + si[i] * tables.twid9[0 + i];
            overlap[i] = co[i] * tables.twid9[0 + i] - si[i] * tables.twid9[9 + i];
            grbuf[i] = ovl * window[0 + i] - sum * window[9 + i];
            grbuf[17 - i] = ovl * window[9 + i] + sum * window[0 + i];
        }
        grbuf += 18;
        overlap += 9;
    }
}

fn idct3(x0: f32, x1: f32, x2: f32, dst: *[3]f32) void {
    const m1 = x1 * 0.86602540;
    const a1 = x0 - x2 * 0.5;
    dst[1] = x0 + x2;
    dst[0] = a1 + m1;
    dst[2] = a1 - m1;
}

fn imdct12(x: [*]const f32, dst: [*]f32, overlap: [*]f32) void {
    var co: [3]f32 = undefined;
    var si: [3]f32 = undefined;
    idct3(-x[0], x[6] + x[3], x[12] + x[9], &co);
    idct3(x[15], x[12] - x[9], x[6] - x[3], &si);
    si[1] = -si[1];
    for (0..3) |i| {
        const ovl = overlap[i];
        const sum = co[i] * tables.twid3[3 + i] + si[i] * tables.twid3[0 + i];
        overlap[i] = co[i] * tables.twid3[0 + i] - si[i] * tables.twid3[3 + i];
        dst[i] = ovl * tables.twid3[2 - i] - sum * tables.twid3[5 - i];
        dst[5 - i] = ovl * tables.twid3[5 - i] + sum * tables.twid3[2 - i];
    }
}

fn imdctShort(grbuf_in: [*]f32, overlap_in: [*]f32, nbands_in: usize) void {
    var grbuf = grbuf_in;
    var overlap = overlap_in;
    var nbands = nbands_in;
    while (nbands > 0) : ({
        nbands -= 1;
        overlap += 9;
        grbuf += 18;
    }) {
        var tmp: [18]f32 = undefined;
        @memcpy(&tmp, grbuf[0..18]);
        @memcpy(grbuf[0..6], overlap[0..6]);
        imdct12(&tmp, grbuf + 6, overlap + 6);
        imdct12(@as([*]const f32, &tmp) + 1, grbuf + 12, overlap + 6);
        imdct12(@as([*]const f32, &tmp) + 2, overlap, overlap + 6);
    }
}

fn changeSign(grbuf_in: [*]f32) void {
    var grbuf = grbuf_in + 18;
    var b: usize = 0;
    while (b < 32) : ({
        b += 2;
        grbuf += 36;
    }) {
        var i: usize = 1;
        while (i < 18) : (i += 2) grbuf[i] = -grbuf[i];
    }
}

fn imdctGranule(grbuf_in: [*]f32, overlap_in: [*]f32, block_type: u32, n_long_bands: usize) void {
    var grbuf = grbuf_in;
    var overlap = overlap_in;
    if (n_long_bands != 0) {
        imdct36(grbuf, overlap, &tables.mdct_window[0], n_long_bands);
        grbuf += 18 * n_long_bands;
        overlap += 9 * n_long_bands;
    }
    if (block_type == short_block_type) {
        imdctShort(grbuf, overlap, 32 - n_long_bands);
    } else {
        imdct36(grbuf, overlap, &tables.mdct_window[@intFromBool(block_type == stop_block_type)], 32 - n_long_bands);
    }
}

// --- the bit reservoir and a granule's decoding -----------------------------------

fn saveReservoir(dec: *Decoder, s: *Scratch) void {
    var pos: i32 = @intCast(@divTrunc(@as(u32, @intCast(s.bs.pos + 7)), 8));
    var remains: i32 = @divTrunc(s.bs.limit, 8) - pos;
    if (remains > max_bitreservoir_bytes) {
        pos += remains - max_bitreservoir_bytes;
        remains = max_bitreservoir_bytes;
    }
    if (remains > 0) {
        const from: usize = @intCast(pos);
        const count: usize = @intCast(remains);
        @memmove(dec.reserv_buf[0..count], s.maindata[from..][0..count]);
    }
    dec.reserv = remains;
}

/// The main data put together: the reservoir's bytes the frame reaches
/// back for, then the frame's own. False if the reservoir has fewer than
/// the frame wants - after a seek, or at the start - and the frame cannot
/// be decoded whole.
fn restoreReservoir(dec: *Decoder, bs: *BitStream, s: *Scratch, main_data_begin: i32) bool {
    const frame_bytes: usize = @intCast(@divTrunc(bs.limit - bs.pos, 8));
    const bytes_have: usize = @intCast(@min(dec.reserv, main_data_begin));
    const from: usize = @intCast(@max(0, dec.reserv - main_data_begin));
    @memcpy(s.maindata[0..bytes_have], dec.reserv_buf[from..][0..bytes_have]);
    const frame_start = bs.buf + @as(usize, @intCast(@divTrunc(bs.pos, 8)));
    @memcpy(s.maindata[bytes_have..][0..frame_bytes], frame_start[0..frame_bytes]);
    bsInit(&s.bs, &s.maindata, @intCast(bytes_have + frame_bytes));
    return dec.reserv >= main_data_begin;
}

fn decode(dec: *Decoder, s: *Scratch, gr_info: [*]GrInfo, nch: usize) void {
    for (0..nch) |ch| {
        const layer3gr_limit = s.bs.pos + gr_info[ch].part_23_length;
        decodeScalefactors(&dec.header, &s.ist_pos[ch], &s.bs, &gr_info[ch], &s.scf, ch);
        huffman(@as([*]f32, &s.grbuf) + 576 * ch, &s.bs, &gr_info[ch], &s.scf, layer3gr_limit);
    }

    if (testIStereo(&dec.header)) {
        intensityStereo(&s.grbuf, &s.ist_pos[1], gr_info, &dec.header);
    } else if (isMsStereo(&dec.header)) {
        midsideStereo(&s.grbuf, 576);
    }

    for (0..nch) |ch| {
        const gr = &gr_info[ch];
        const channel = @as([*]f32, &s.grbuf) + 576 * ch;
        var aa_bands: i32 = 31;
        const n_long_bands: usize = @as(usize, if (gr.mixed_block_flag != 0) 2 else 0) << @intFromBool(getMySampleRate(&dec.header) == 2);

        if (gr.n_short_sfb != 0) {
            aa_bands = @as(i32, @intCast(n_long_bands)) - 1;
            reorder(channel + n_long_bands * 18, &s.syn, gr.sfbtab + gr.n_long_sfb);
        }

        antialias(channel, aa_bands);
        imdctGranule(channel, &dec.mdct_overlap[ch], gr.block_type, n_long_bands);
        changeSign(channel);
    }
}

// --- the synthesis filter ---------------------------------------------------------

fn dctII(grbuf: [*]f32, n: usize) void {
    for (0..n) |k| {
        var t: [4][8]f32 = undefined;
        const y = grbuf + k;
        for (0..8) |i| {
            const x0 = y[i * 18];
            const x1 = y[(15 - i) * 18];
            const x2 = y[(16 + i) * 18];
            const x3 = y[(31 - i) * 18];
            const t0 = x0 + x3;
            const t1 = x1 + x2;
            const t2 = (x1 - x2) * tables.sec[3 * i + 0];
            const t3 = (x0 - x3) * tables.sec[3 * i + 1];
            t[0][i] = t0 + t1;
            t[1][i] = (t0 - t1) * tables.sec[3 * i + 2];
            t[2][i] = t3 + t2;
            t[3][i] = (t3 - t2) * tables.sec[3 * i + 2];
        }
        for (&t) |*x| {
            var x0 = x[0];
            var x1 = x[1];
            var x2 = x[2];
            var x3 = x[3];
            var x4 = x[4];
            var x5 = x[5];
            var x6 = x[6];
            var x7 = x[7];
            var xt = x0 - x7;
            x0 += x7;
            x7 = x1 - x6;
            x1 += x6;
            x6 = x2 - x5;
            x2 += x5;
            x5 = x3 - x4;
            x3 += x4;
            x4 = x0 - x3;
            x0 += x3;
            x3 = x1 - x2;
            x1 += x2;
            x[0] = x0 + x1;
            x[4] = (x0 - x1) * 0.70710677;
            x5 = x5 + x6;
            x6 = (x6 + x7) * 0.70710677;
            x7 = x7 + xt;
            x3 = (x3 + x4) * 0.70710677;
            x5 -= x7 * 0.198912367; // rotate by PI/8
            x7 += x5 * 0.382683432;
            x5 -= x7 * 0.198912367;
            x0 = xt - x6;
            xt += x6;
            x[1] = (xt + x7) * 0.50979561;
            x[2] = (x4 + x3) * 0.54119611;
            x[3] = (x0 - x5) * 0.60134488;
            x[5] = (x0 + x5) * 0.89997619;
            x[6] = (x4 - x3) * 1.30656302;
            x[7] = (xt - x7) * 2.56291556;
        }
        var out = y;
        for (0..7) |i| {
            out[0 * 18] = t[0][i];
            out[1 * 18] = t[2][i] + t[3][i] + t[3][i + 1];
            out[2 * 18] = t[1][i] + t[1][i + 1];
            out[3 * 18] = t[2][i + 1] + t[3][i] + t[3][i + 1];
            out += 4 * 18;
        }
        out[0 * 18] = t[0][7];
        out[1 * 18] = t[2][7] + t[3][7];
        out[2 * 18] = t[1][7];
        out[3 * 18] = t[3][7];
    }
}

/// A filter output rounded to a 16-bit sample, away from zero at the
/// half, and held at the ends.
fn scalePcm(sample: f32) i16 {
    if (sample >= 32766.5) return 32767;
    if (sample <= -32767.5) return -32768;
    var s: i16 = @intFromFloat(sample + 0.5);
    if (s < 0) s -= 1;
    return s;
}

fn synthPair(pcm: [*]i16, nch: usize, z_in: [*]const f32) void {
    var z = z_in;
    var a: f32 = (z[14 * 64] - z[0]) * 29;
    a += (z[1 * 64] + z[13 * 64]) * 213;
    a += (z[12 * 64] - z[2 * 64]) * 459;
    a += (z[3 * 64] + z[11 * 64]) * 2037;
    a += (z[10 * 64] - z[4 * 64]) * 5153;
    a += (z[5 * 64] + z[9 * 64]) * 6574;
    a += (z[8 * 64] - z[6 * 64]) * 37489;
    a += z[7 * 64] * 75038;
    pcm[0] = scalePcm(a);

    z += 2;
    a = z[14 * 64] * 104;
    a += z[12 * 64] * 1567;
    a += z[10 * 64] * 9727;
    a += z[8 * 64] * 64019;
    a += z[6 * 64] * -9975;
    a += z[4 * 64] * -45;
    a += z[2 * 64] * 146;
    a += z[0 * 64] * -5;
    pcm[16 * nch] = scalePcm(a);
}

/// Two subband rows into 64 samples a channel. `lins` is the filter's
/// window of 15 rows behind and the rows being added; `zlin` - row 15 - is
/// where they go, and the window reaches back from it.
fn synth(xl: [*]const f32, dstl: [*]i16, nch: usize, lins: [*]f32) void {
    const xr = xl + 576 * (nch - 1);
    const dstr = dstl + (nch - 1);
    const zlin_at: usize = 15 * 64;

    lins[zlin_at + 4 * 15] = xl[18 * 16];
    lins[zlin_at + 4 * 15 + 1] = xr[18 * 16];
    lins[zlin_at + 4 * 15 + 2] = xl[0];
    lins[zlin_at + 4 * 15 + 3] = xr[0];

    lins[zlin_at + 4 * 31] = xl[1 + 18 * 16];
    lins[zlin_at + 4 * 31 + 1] = xr[1 + 18 * 16];
    lins[zlin_at + 4 * 31 + 2] = xl[1];
    lins[zlin_at + 4 * 31 + 3] = xr[1];

    synthPair(dstr, nch, lins + 4 * 15 + 1);
    synthPair(dstr + 32 * nch, nch, lins + 4 * 15 + 64 + 1);
    synthPair(dstl, nch, lins + 4 * 15);
    synthPair(dstl + 32 * nch, nch, lins + 4 * 15 + 64);

    var w: [*]const f32 = &tables.synth_window;
    var i: i32 = 14;
    while (i >= 0) : (i -= 1) {
        const four: usize = @intCast(4 * i);
        const iu: usize = @intCast(i);
        var a: [4]f32 = undefined;
        var b: [4]f32 = undefined;

        lins[zlin_at + four] = xl[18 * (31 - iu)];
        lins[zlin_at + four + 1] = xr[18 * (31 - iu)];
        lins[zlin_at + four + 2] = xl[1 + 18 * (31 - iu)];
        lins[zlin_at + four + 3] = xr[1 + 18 * (31 - iu)];
        lins[zlin_at + four + 64] = xl[1 + 18 * (1 + iu)];
        lins[zlin_at + four + 64 + 1] = xr[1 + 18 * (1 + iu)];
        lins[zlin_at + four - 64 + 2] = xl[18 * (1 + iu)];
        lins[zlin_at + four - 64 + 3] = xr[18 * (1 + iu)];

        // The window's eight taps: the first sets a and b, the rest add -
        // the even ones with the sign of a's term turned round.
        inline for (0..8) |k| {
            const w0 = w[0];
            const w1 = w[1];
            w += 2;
            const vz = lins + zlin_at + four - k * 64;
            const vy = lins + zlin_at + four - (15 - k) * 64;
            for (0..4) |j| {
                const bb = vz[j] * w1 + vy[j] * w0;
                const aa = if (k % 2 == 1) vy[j] * w1 - vz[j] * w0 else vz[j] * w0 - vy[j] * w1;
                if (k == 0) {
                    b[j] = bb;
                    a[j] = aa;
                } else {
                    b[j] += bb;
                    a[j] += aa;
                }
            }
        }

        dstr[(15 - iu) * nch] = scalePcm(a[1]);
        dstr[(17 + iu) * nch] = scalePcm(b[1]);
        dstl[(15 - iu) * nch] = scalePcm(a[0]);
        dstl[(17 + iu) * nch] = scalePcm(b[0]);
        dstr[(47 - iu) * nch] = scalePcm(a[3]);
        dstr[(49 + iu) * nch] = scalePcm(b[3]);
        dstl[(47 - iu) * nch] = scalePcm(a[2]);
        dstl[(49 + iu) * nch] = scalePcm(b[2]);
    }
}

fn synthGranule(qmf_state: *[15 * 2 * 32]f32, grbuf: [*]f32, nbands: usize, nch: usize, pcm: [*]i16, lins: [*]f32) void {
    for (0..nch) |i| dctII(grbuf + 576 * i, nbands);

    @memcpy(lins[0 .. 15 * 64], qmf_state[0 .. 15 * 64]);

    var i: usize = 0;
    while (i < nbands) : (i += 2) {
        synth(grbuf + i, pcm + 32 * nch * i, nch, lins + i * 64);
    }
    if (nch == 1) {
        var k: usize = 0;
        while (k < 15 * 64) : (k += 2) qmf_state[k] = lins[nbands * 64 + k];
    } else {
        @memcpy(qmf_state[0 .. 15 * 64], lins[nbands * 64 ..][0 .. 15 * 64]);
    }
}

// --- finding a frame --------------------------------------------------------------

fn matchFrame(hdr: [*]const u8, mp3_bytes: i32, frame_bytes: i32) bool {
    var i: i32 = 0;
    var nmatch: u32 = 0;
    while (nmatch < max_frame_sync_matches) : (nmatch += 1) {
        const at: usize = @intCast(i);
        i += headerFrameBytes(hdr + at, frame_bytes) + headerPadding(hdr + at);
        if (i + header_size > mp3_bytes) return nmatch > 0;
        if (!headerCompare(hdr, hdr + @as(usize, @intCast(i)))) return false;
    }
    return true;
}

/// Where in `mp3` the first frame begins that the frames after it agree
/// with, and its length with padding in `ptr_frame_bytes`; the length of
/// `mp3` and 0 when there is none.
fn findFrame(mp3_in: [*]const u8, mp3_bytes: i32, free_format_bytes: *i32, ptr_frame_bytes: *i32) i32 {
    var mp3 = mp3_in;
    var i: i32 = 0;
    while (i < mp3_bytes - header_size) : ({
        i += 1;
        mp3 += 1;
    }) {
        if (!headerValid(mp3)) continue;
        var frame_bytes = headerFrameBytes(mp3, free_format_bytes.*);
        var frame_and_padding = frame_bytes + headerPadding(mp3);

        var k: i32 = header_size;
        while (frame_bytes == 0 and k < max_frame_bytes and i + 2 * k < mp3_bytes - header_size) : (k += 1) {
            if (headerCompare(mp3, mp3 + @as(usize, @intCast(k)))) {
                const fb = k - headerPadding(mp3);
                const nextfb = fb + headerPadding(mp3 + @as(usize, @intCast(k)));
                if (i + k + nextfb + header_size > mp3_bytes or !headerCompare(mp3, mp3 + @as(usize, @intCast(k + nextfb)))) continue;
                frame_and_padding = k;
                frame_bytes = fb;
                free_format_bytes.* = fb;
            }
        }
        if ((frame_bytes != 0 and i + frame_and_padding <= mp3_bytes and matchFrame(mp3, mp3_bytes - i, frame_bytes)) or
            (i == 0 and frame_and_padding == mp3_bytes))
        {
            ptr_frame_bytes.* = frame_and_padding;
            return i;
        }
        free_format_bytes.* = 0;
    }
    ptr_frame_bytes.* = 0;
    return mp3_bytes;
}

/// Whether `bytes` hold MPEG audio: a frame that the frames after it
/// agree with, as `findFrame` asks - not merely bytes that look like a
/// header.
pub fn startsStream(bytes: []const u8) bool {
    if (bytes.len < header_size * 2) return false;
    var free_format: i32 = 0;
    var frame_bytes: i32 = 0;
    _ = findFrame(bytes.ptr, @intCast(@min(bytes.len, 0x7fffffff)), &free_format, &frame_bytes);
    return frame_bytes != 0;
}

/// One frame of `mp3` decoded into `pcm` - the samples a channel, the
/// channels interleaved - or, with `pcm` null, only found. Answers the
/// samples a channel it made: 0 when no frame was found (`info.frame_bytes`
/// is then how many bytes can go, being no frame's start), when the frame
/// is of layer I or II, or when it needs more of the reservoir than there
/// is - which is so for a frame or two after a seek.
pub fn decodeFrame(dec: *Decoder, scratch: *Scratch, mp3: []const u8, pcm: ?[*]i16, info: *FrameInfo) u32 {
    const mp3_bytes: i32 = @intCast(@min(mp3.len, 0x7fffffff));
    var i: i32 = 0;
    var frame_size: i32 = 0;

    if (mp3_bytes > 4 and dec.header[0] == 0xff and headerCompare(&dec.header, mp3.ptr)) {
        frame_size = headerFrameBytes(mp3.ptr, dec.free_format_bytes) + headerPadding(mp3.ptr);
        if (frame_size != mp3_bytes and (frame_size + header_size > mp3_bytes or !headerCompare(mp3.ptr, mp3.ptr + @as(usize, @intCast(frame_size))))) {
            frame_size = 0;
        }
    }
    if (frame_size == 0) {
        dec.* = .{};
        i = findFrame(mp3.ptr, mp3_bytes, &dec.free_format_bytes, &frame_size);
        if (frame_size == 0 or i + frame_size > mp3_bytes) {
            info.* = .{ .frame_bytes = @intCast(i) };
            return 0;
        }
    }

    const hdr = mp3.ptr + @as(usize, @intCast(i));
    @memcpy(&dec.header, hdr[0..header_size]);
    info.* = .{
        .frame_bytes = @intCast(i + frame_size),
        .frame_offset = @intCast(i),
        .channels = headerChannels(hdr),
        .hz = headerSampleRateHz(hdr),
        .layer = headerLayer(hdr),
        .bitrate_kbps = headerBitrateKbps(hdr),
    };

    const out = pcm orelse return headerFrameSamples(hdr);
    if (info.layer != 3) return 0;

    var bs_frame: BitStream = .{};
    bsInit(&bs_frame, hdr + header_size, frame_size - header_size);
    if (isCrc(hdr)) _ = getBits(&bs_frame, 16);

    const main_data_begin = readSideInfo(&bs_frame, &scratch.gr_info, hdr);
    if (main_data_begin < 0 or bs_frame.pos > bs_frame.limit) {
        dec.reset();
        return 0;
    }
    const success = restoreReservoir(dec, &bs_frame, scratch, main_data_begin);
    if (success) {
        const granules: usize = if (testMpeg1(hdr)) 2 else 1;
        const nch: usize = info.channels;
        var samples = out;
        for (0..granules) |igr| {
            @memset(&scratch.grbuf, 0);
            decode(dec, scratch, @as([*]GrInfo, &scratch.gr_info) + igr * nch, nch);
            synthGranule(&dec.qmf_state, &scratch.grbuf, 18, nch, samples, &scratch.syn);
            samples += 576 * nch;
        }
    }
    saveReservoir(dec, scratch);
    return if (success) headerFrameSamples(&dec.header) else 0;
}

fn be32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
}

/// What a Xing or Info frame - the first of a stream that its encoder
/// wrote about the rest - says: how many frames there are, and the
/// samples the encoder put before the music and after it.
pub const VbrTag = struct {
    frames: u32 = 0,
    /// The bytes of music after the tag's frame, when it says.
    bytes: u32 = 0,
    /// Where each hundredth of the music begins, in 256ths of `bytes`.
    toc: ?[100]u8 = null,
    delay: u32 = 0,
    padding: u32 = 0,
};

/// The Xing or Info frame `frame` is, or null for a frame of music.
pub fn vbrTag(frame: []const u8) ?VbrTag {
    if (frame.len < header_size + 8) return null;
    var bs: BitStream = .{};
    bsInit(&bs, frame.ptr + header_size, @intCast(frame.len - header_size));
    if (isCrc(frame.ptr)) _ = getBits(&bs, 16);
    var gr_info: [4]GrInfo = @splat(.{});
    if (readSideInfo(&bs, &gr_info, frame.ptr) < 0) return null;

    var at: usize = header_size + @as(usize, @intCast(bs.pos >> 3));
    if (at > frame.len or frame.len - at < 8) return null;
    const tag = frame[at..];
    const is_xing = tag[0] == 'X' and tag[1] == 'i' and tag[2] == 'n' and tag[3] == 'g';
    const is_info = tag[0] == 'I' and tag[1] == 'n' and tag[2] == 'f' and tag[3] == 'o';
    if (!is_xing and !is_info) return null;
    const flags = tag[7];
    // Without the count of frames it says nothing worth having, but it is
    // still no music.
    if (flags & 1 == 0) return .{};
    at += 8;
    if (frame.len - at < 4) return null;
    var result: VbrTag = .{ .frames = be32(frame[at..]) };
    at += 4;
    if (flags & 2 != 0) {
        if (frame.len - at < 4) return result;
        result.bytes = be32(frame[at..]);
        at += 4;
    }
    if (flags & 4 != 0) {
        if (frame.len - at < 100) return result;
        result.toc = frame[at..][0..100].*;
        at += 100;
    }
    if (flags & 8 != 0) {
        if (frame.len - at < 4) return result;
        at += 4;
    }
    if (frame.len - at < 1 or frame[at] == 0) return result;
    // An encoder's own extension - LAME's and those that copied it - with
    // the delay and padding in three bytes, 21 bytes in.
    if (frame.len - at <= 35) return result;
    const lame = frame[at + 21 ..];
    const delay: u32 = (@as(u32, lame[0]) << 4) | (lame[1] >> 4);
    const padding: u32 = (@as(u32, lame[1] & 0xF) << 8) | lame[2];
    // The decoder's own delay - 528 samples and one - is added to the
    // encoder's, and taken off the padding.
    result.delay = delay + 529;
    result.padding = padding -| 529;
    return result;
}
