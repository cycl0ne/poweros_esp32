// SPDX-License-Identifier: MIT
//! SBC, the subband codec every A2DP device takes: the encoder of the
//! A2DP specification's appendix B, which btaudio.device's stream is
//! made with.
//!
//! **A frame** is `blocks * subbands` samples of each channel: a header -
//! the rate, the blocks, the channel mode, how the bits are given out,
//! the subbands, the bitpool - its CRC, for joint stereo which subbands
//! are sent as sum and difference, a scale factor for each channel's
//! subbands, and the samples, each in as many bits as the allocation
//! gives its subband.
//!
//! **The analysis filter** splits each block of a channel's samples into
//! its subbands: the samples shifted into a history of ten blocks,
//! weighted by the prototype filter (40 or 80 coefficients), summed into
//! twice as many partial values as there are subbands, and those mixed by
//! a cosine matrix into the subbands' samples. With 8 subbands a sample
//! comes out of a decoder 73 samples later, with 4 subbands 37.
//!
//! **A subband's scale factor** is the least power of two (2 to 65536)
//! above all its samples in the frame. In joint stereo a subband but the
//! last is sent as the channels' half sum and half difference where the
//! two take smaller scale factors than left and right do.
//!
//! **The bits** of the bitpool are given out by the specification's
//! allocation - from each subband's scale factor, less an offset for its
//! place in loudness - over both channels in stereo and joint stereo, to
//! each channel apart in mono and dual channel; a sample is then
//! quantized to its subband's levels.
//!
//! Floating point throughout; an encoder keeps its history and its
//! frame's subband samples in itself, so the caller's state holds them
//! and nothing large is on the stack.

/// How the channels are sent: one, two apart with a bitpool each, two
/// sharing the bitpool, or two sharing it with sum and difference where
/// that is smaller.
pub const Mode = enum(u2) { mono = 0, dual_channel = 1, stereo = 2, joint_stereo = 3 };

/// How the bitpool is given out: by loudness, which weighs the subbands
/// as the ear does, or by the signal-to-noise ratio alone.
pub const Allocation = enum(u1) { loudness = 0, snr = 1 };

/// A stream's settings, as AVDTP's configuration names them.
pub const Config = struct {
    /// 16000, 32000, 44100 or 48000.
    rate: u32 = 48000,
    /// 4 or 8.
    subbands: u8 = 8,
    /// 4, 8, 12 or 16.
    blocks: u8 = 16,
    mode: Mode = .joint_stereo,
    allocation: Allocation = .loudness,
    /// 2 up to 16 a subband for mono and dual channel, 32 a subband for
    /// stereo and joint stereo, 250 at most.
    bitpool: u8 = 53,
};

/// The syncword every frame begins with.
pub const SYNCWORD = 0x9C;

/// The most subbands and channels, and the most blocks: what an encoder's
/// buffers hold.
const subbands_most = 8;
const channels_most = 2;
const blocks_most = 16;

/// How many channels `mode` carries.
pub fn channelsOf(mode: Mode) usize {
    return if (mode == .mono) 1 else 2;
}

/// How many samples of each channel a frame holds.
pub fn samplesPerFrame(config: Config) usize {
    return @as(usize, config.blocks) * config.subbands;
}

/// Whether `config` is one the specification allows.
pub fn valid(config: Config) bool {
    switch (config.rate) {
        16000, 32000, 44100, 48000 => {},
        else => return false,
    }
    if (config.subbands != 4 and config.subbands != 8) return false;
    switch (config.blocks) {
        4, 8, 12, 16 => {},
        else => return false,
    }
    const per_subband: u32 = if (config.mode == .mono or config.mode == .dual_channel) 16 else 32;
    return config.bitpool >= 2 and config.bitpool <= 250 and config.bitpool <= per_subband * config.subbands;
}

/// A frame's length in bytes: the header and its CRC, the scale factors,
/// the join bits in joint stereo and the samples, up to a whole byte.
pub fn frameLength(config: Config) usize {
    const channels = channelsOf(config.mode);
    const subbands: usize = config.subbands;
    const blocks: usize = config.blocks;
    const bitpool: usize = config.bitpool;
    const head = 4 + (4 * subbands * channels) / 8;
    return switch (config.mode) {
        .mono, .dual_channel => head + (blocks * channels * bitpool + 7) / 8,
        .stereo => head + (blocks * bitpool + 7) / 8,
        .joint_stereo => head + (subbands + blocks * bitpool + 7) / 8,
    };
}

/// The prototype filter for 4 subbands, the specification's Proto_4_40.
const proto_4_40 = [40]f32{
    0.00000000E+00,  5.36548976E-04,  1.49188357E-03,  2.73370904E-03,
    3.83720193E-03,  3.89205149E-03,  1.86581691E-03,  -3.06012286E-03,
    1.09137620E-02,  2.04385087E-02,  2.88757392E-02,  3.21939290E-02,
    2.58767811E-02,  6.13245186E-03,  -2.88217274E-02, -7.76463494E-02,
    1.35593274E-01,  1.94987841E-01,  2.46636662E-01,  2.81828203E-01,
    2.94315332E-01,  2.81828203E-01,  2.46636662E-01,  1.94987841E-01,
    -1.35593274E-01, -7.76463494E-02, -2.88217274E-02, 6.13245186E-03,
    2.58767811E-02,  3.21939290E-02,  2.88757392E-02,  2.04385087E-02,
    -1.09137620E-02, -3.06012286E-03, 1.86581691E-03,  3.89205149E-03,
    3.83720193E-03,  2.73370904E-03,  1.49188357E-03,  5.36548976E-04,
};

/// The prototype filter for 8 subbands, the specification's Proto_8_80.
const proto_8_80 = [80]f32{
    0.00000000E+00,  1.56575398E-04,  3.43256425E-04,  5.54620202E-04,
    8.23919506E-04,  1.13992507E-03,  1.47640169E-03,  1.78371725E-03,
    2.01182542E-03,  2.10371989E-03,  1.99454554E-03,  1.61656283E-03,
    9.02154502E-04,  -1.78805361E-04, -1.64973098E-03, -3.49717454E-03,
    5.65949473E-03,  8.02941163E-03,  1.04584443E-02,  1.27472335E-02,
    1.46525263E-02,  1.59045603E-02,  1.62208471E-02,  1.53184106E-02,
    1.29371806E-02,  8.85757540E-03,  2.92408442E-03,  -4.91578024E-03,
    -1.46404076E-02, -2.61098752E-02, -3.90751381E-02, -5.31873032E-02,
    6.79989431E-02,  8.29847578E-02,  9.75753918E-02,  1.11196689E-01,
    1.23264548E-01,  1.33264415E-01,  1.40753505E-01,  1.45389847E-01,
    1.46955068E-01,  1.45389847E-01,  1.40753505E-01,  1.33264415E-01,
    1.23264548E-01,  1.11196689E-01,  9.75753918E-02,  8.29847578E-02,
    -6.79989431E-02, -5.31873032E-02, -3.90751381E-02, -2.61098752E-02,
    -1.46404076E-02, -4.91578024E-03, 2.92408442E-03,  8.85757540E-03,
    1.29371806E-02,  1.53184106E-02,  1.62208471E-02,  1.59045603E-02,
    1.46525263E-02,  1.27472335E-02,  1.04584443E-02,  8.02941163E-03,
    -5.65949473E-03, -3.49717454E-03, -1.64973098E-03, -1.78805361E-04,
    9.02154502E-04,  1.61656283E-03,  1.99454554E-03,  2.10371989E-03,
    2.01182542E-03,  1.78371725E-03,  1.47640169E-03,  1.13992507E-03,
    8.23919506E-04,  5.54620202E-04,  3.43256425E-04,  1.56575398E-04,
};

/// The loudness allocation's offsets, by rate (16, 32, 44.1, 48 kHz) and
/// subband.
const offset4 = [4][4]i8{
    .{ -1, 0, 0, 0 },
    .{ -2, 0, 0, 1 },
    .{ -2, 0, 0, 1 },
    .{ -2, 0, 0, 1 },
};
const offset8 = [4][8]i8{
    .{ -2, 0, 0, 0, 0, 0, 0, 1 },
    .{ -3, 0, 0, 0, 0, 0, 1, 2 },
    .{ -4, 0, 0, 0, 0, 0, 1, 2 },
    .{ -4, 0, 0, 0, 0, 0, 1, 2 },
};

/// The analysis matrix for `subbands` subbands: cos((i + 1/2)(k - M/2)pi/M).
fn analysisMatrix(comptime subbands: usize) [subbands][2 * subbands]f32 {
    @setEvalBranchQuota(10_000);
    var matrix: [subbands][2 * subbands]f32 = undefined;
    const m: f64 = @floatFromInt(subbands);
    for (0..subbands) |i| {
        for (0..2 * subbands) |k| {
            const angle = (@as(f64, @floatFromInt(i)) + 0.5) * (@as(f64, @floatFromInt(k)) - m / 2.0) * pi / m;
            matrix[i][k] = @floatCast(@cos(angle));
        }
    }
    return matrix;
}

const pi: f64 = 3.14159265358979323846264338327950288;
const matrix4 = analysisMatrix(4);
const matrix8 = analysisMatrix(8);

/// The code of a rate in the header, and the row of the offsets.
fn rateCode(rate: u32) u2 {
    return switch (rate) {
        16000 => 0,
        32000 => 1,
        44100 => 2,
        else => 3,
    };
}

/// The bits each channel's subbands get of the bitpool, from their scale
/// factors: the specification's allocation.
fn allocate(config: Config, scale: *const [channels_most][subbands_most]u4, bits: *[channels_most][subbands_most]u5) void {
    const channels = channelsOf(config.mode);
    bits.* = @splat(@splat(0));
    if (config.mode == .mono or config.mode == .dual_channel) {
        for (0..channels) |channel| distribute(config, scale, bits, channel, channel + 1);
    } else {
        distribute(config, scale, bits, 0, 2);
    }
}

/// The allocation over the channels `first` up to `end`, which share the
/// bitpool.
fn distribute(config: Config, scale: *const [channels_most][subbands_most]u4, bits: *[channels_most][subbands_most]u5, first: usize, end: usize) void {
    const subbands: usize = config.subbands;
    const bitpool: i32 = config.bitpool;
    const row = rateCode(config.rate);
    var bitneed: [channels_most][subbands_most]i32 = @splat(@splat(0));
    var max_bitneed: i32 = 0;
    for (first..end) |channel| {
        for (0..subbands) |subband| {
            const factor: i32 = scale[channel][subband];
            const need: i32 = if (config.allocation == .snr) factor else if (factor == 0) -5 else need: {
                const offset: i32 = if (subbands == 4) offset4[row][subband] else offset8[row][subband];
                const loudness = factor - offset;
                break :need if (loudness > 0) @divTrunc(loudness, 2) else loudness;
            };
            bitneed[channel][subband] = need;
            if (need > max_bitneed) max_bitneed = need;
        }
    }
    // The slice: the level below which a subband gets no bits, lowered
    // while the bits above it still fit in the bitpool.
    var bitcount: i32 = 0;
    var slicecount: i32 = 0;
    var bitslice: i32 = max_bitneed + 1;
    while (true) {
        bitslice -= 1;
        bitcount += slicecount;
        slicecount = 0;
        for (first..end) |channel| {
            for (0..subbands) |subband| {
                const need = bitneed[channel][subband];
                if (need > bitslice + 1 and need < bitslice + 16) {
                    slicecount += 1;
                } else if (need == bitslice + 1) {
                    slicecount += 2;
                }
            }
        }
        if (bitcount + slicecount >= bitpool) break;
    }
    if (bitcount + slicecount == bitpool) {
        bitcount += slicecount;
        bitslice -= 1;
    }
    for (first..end) |channel| {
        for (0..subbands) |subband| {
            const need = bitneed[channel][subband];
            bits[channel][subband] = if (need < bitslice + 2) 0 else @intCast(@min(need - bitslice, 16));
        }
    }
    // What is left: first one more bit to each subband that has some, or
    // two to one just below the slice; then one to each in turn - the
    // channels alternating within a subband.
    var subband: usize = 0;
    var channel: usize = first;
    while (bitcount < bitpool and subband < subbands) {
        const have = bits[channel][subband];
        if (have >= 2 and have < 16) {
            bits[channel][subband] = have + 1;
            bitcount += 1;
        } else if (bitneed[channel][subband] == bitslice + 1 and bitpool > bitcount + 1) {
            bits[channel][subband] = 2;
            bitcount += 2;
        }
        channel += 1;
        if (channel == end) {
            channel = first;
            subband += 1;
        }
    }
    subband = 0;
    channel = first;
    while (bitcount < bitpool and subband < subbands) {
        if (bits[channel][subband] < 16) {
            bits[channel][subband] += 1;
            bitcount += 1;
        }
        channel += 1;
        if (channel == end) {
            channel = first;
            subband += 1;
        }
    }
}

/// The CRC-8 of a frame (x^8 + x^4 + x^3 + x^2 + 1, from 0x0F) over the
/// header's second and third bytes, then `bit_count` bits from its fifth
/// byte on: the join bits and the scale factors.
fn crcOf(frame: []const u8, bit_count: usize) u8 {
    var crc: u8 = 0x0F;
    for (0..16 + bit_count) |at| {
        const byte_at = if (at < 16) 1 + at / 8 else 4 + (at - 16) / 8;
        const bit: u1 = @truncate(frame[byte_at] >> @intCast(7 - (at % 8)));
        const feedback = @as(u1, @truncate(crc >> 7)) ^ bit;
        crc <<= 1;
        if (feedback == 1) crc ^= 0x1D;
    }
    return crc;
}

/// How many bits after the CRC the CRC covers: the join bits, the scale
/// factors.
fn crcBits(config: Config) usize {
    const join: usize = if (config.mode == .joint_stereo) config.subbands else 0;
    return join + 4 * @as(usize, config.subbands) * channelsOf(config.mode);
}

/// Bits written into a frame from its first byte on, the most
/// significant first.
const BitWriter = struct {
    bytes: []u8,
    at: usize = 0,

    fn put(writer: *BitWriter, value: u32, count: u5) void {
        var left = count;
        while (left > 0) {
            left -= 1;
            const bit: u8 = @truncate(value >> left & 1);
            const byte = writer.at / 8;
            const shift: u3 = @intCast(7 - writer.at % 8);
            if (shift == 7) writer.bytes[byte] = 0;
            writer.bytes[byte] |= bit << shift;
            writer.at += 1;
        }
    }
};

/// The least scale factor whose power of two, 2 << it, is above `peak`;
/// 15 where none is.
fn scaleOf(peak: f32) u4 {
    var factor: u4 = 0;
    while (factor < 15 and peak >= @as(f32, @floatFromInt(@as(u32, 2) << factor))) factor += 1;
    return factor;
}

/// An encoder of one stream: its settings, each channel's history of
/// samples, and the subband samples of the frame it makes.
pub const Encoder = struct {
    config: Config,
    history: [channels_most][10 * subbands_most]f32 = @splat(@splat(0)),
    samples: [blocks_most][channels_most][subbands_most]f32 = @splat(@splat(@splat(0))),

    /// An encoder for `config`, which `valid` takes.
    pub fn init(config: Config) Encoder {
        return .{ .config = config };
    }

    /// A frame of `pcm` - `samplesPerFrame` samples of each channel,
    /// interleaved, 16 bits - into `out`, which holds `frameLength`
    /// bytes; answers its length.
    pub fn encode(encoder: *Encoder, pcm: []const i16, out: []u8) usize {
        const config = encoder.config;
        const channels = channelsOf(config.mode);
        const subbands: usize = config.subbands;
        const blocks: usize = config.blocks;
        for (0..blocks) |block| {
            for (0..channels) |channel| {
                var input: [subbands_most]f32 = undefined;
                for (0..subbands) |index| {
                    input[index] = @floatFromInt(pcm[(block * subbands + index) * channels + channel]);
                }
                encoder.analyze(channel, &input, &encoder.samples[block][channel]);
            }
        }
        var scale: [channels_most][subbands_most]u4 = @splat(@splat(0));
        for (0..channels) |channel| {
            for (0..subbands) |subband| {
                var peak: f32 = 0;
                for (0..blocks) |block| peak = @max(peak, @abs(encoder.samples[block][channel][subband]));
                scale[channel][subband] = scaleOf(peak);
            }
        }
        var join: [subbands_most]bool = @splat(false);
        if (config.mode == .joint_stereo) {
            for (0..subbands - 1) |subband| {
                var peak_sum: f32 = 0;
                var peak_difference: f32 = 0;
                for (0..blocks) |block| {
                    const left = encoder.samples[block][0][subband];
                    const right = encoder.samples[block][1][subband];
                    peak_sum = @max(peak_sum, @abs((left + right) / 2));
                    peak_difference = @max(peak_difference, @abs((left - right) / 2));
                }
                const sum_factor = scaleOf(peak_sum);
                const difference_factor = scaleOf(peak_difference);
                if (@as(u32, sum_factor) + difference_factor < @as(u32, scale[0][subband]) + scale[1][subband]) {
                    join[subband] = true;
                    scale[0][subband] = sum_factor;
                    scale[1][subband] = difference_factor;
                    for (0..blocks) |block| {
                        const left = encoder.samples[block][0][subband];
                        const right = encoder.samples[block][1][subband];
                        encoder.samples[block][0][subband] = (left + right) / 2;
                        encoder.samples[block][1][subband] = (left - right) / 2;
                    }
                }
            }
        }
        var bits: [channels_most][subbands_most]u5 = undefined;
        allocate(config, &scale, &bits);

        var writer = BitWriter{ .bytes = out };
        writer.put(SYNCWORD, 8);
        writer.put(rateCode(config.rate), 2);
        writer.put(@intCast(blocks / 4 - 1), 2);
        writer.put(@intFromEnum(config.mode), 2);
        writer.put(@intFromEnum(config.allocation), 1);
        writer.put(if (subbands == 8) 1 else 0, 1);
        writer.put(config.bitpool, 8);
        writer.put(0, 8); // the CRC, once what it covers is written
        if (config.mode == .joint_stereo) {
            for (0..subbands - 1) |subband| writer.put(@intFromBool(join[subband]), 1);
            writer.put(0, 1);
        }
        for (0..channels) |channel| {
            for (0..subbands) |subband| writer.put(scale[channel][subband], 4);
        }
        out[3] = crcOf(out, crcBits(config));
        for (0..blocks) |block| {
            for (0..channels) |channel| {
                for (0..subbands) |subband| {
                    const count = bits[channel][subband];
                    if (count == 0) continue;
                    const levels: u32 = (@as(u32, 1) << count) - 1;
                    const factor: f32 = @floatFromInt(@as(u32, 2) << scale[channel][subband]);
                    const level_count: f32 = @floatFromInt(levels);
                    const value = (encoder.samples[block][channel][subband] / factor + 1.0) * level_count / 2.0;
                    const clamped = @min(@max(@floor(value), 0.0), level_count);
                    writer.put(@intFromFloat(clamped), count);
                }
            }
        }
        // The last byte's unused bits are zero: put cleared the byte it
        // began.
        return (writer.at + 7) / 8;
    }

    /// One block of a channel's samples into its subbands' samples.
    fn analyze(encoder: *Encoder, channel: usize, input: *const [subbands_most]f32, out: *[subbands_most]f32) void {
        const subbands: usize = encoder.config.subbands;
        const length = 10 * subbands;
        const history = &encoder.history[channel];
        var index = length - 1;
        while (index >= subbands) : (index -= 1) history[index] = history[index - subbands];
        for (0..subbands) |at| history[subbands - 1 - at] = input[at];
        var partial: [2 * subbands_most]f32 = undefined;
        const proto: []const f32 = if (subbands == 4) &proto_4_40 else &proto_8_80;
        for (0..2 * subbands) |k| {
            var sum: f32 = 0;
            for (0..5) |j| sum += proto[k + j * 2 * subbands] * history[k + j * 2 * subbands];
            partial[k] = sum;
        }
        for (0..subbands) |i| {
            var sum: f32 = 0;
            for (0..2 * subbands) |k| {
                const weight = if (subbands == 4) matrix4[i][k] else matrix8[i][k];
                sum += weight * partial[k];
            }
            out[i] = sum;
        }
    }
};

// --- tests: a decoder of the specification's synthesis side -----------------

const std = @import("std");
const testing = std.testing;

/// Frames sbc 2.2's sbcenc made of a 1 kHz tone on the left and 440 Hz
/// with 3150 Hz on the right at 48 kHz: its 21st frame of each setting.
const sbcenc_joint8 = "9cfd35b620d1000000db000000227b6ec241920ab9cd0e1d334e6d2f4d2c7365a9bb051924f0d91a8c4597a858c725a063284f3ed889edb52c55d24ae73425eb9371b4bd344b9b5126ec146a35561b2a31165f6ac98296818d04f5e25227b6ebae4f70ab9cd0d95e9032d2f4d34ca3239bb051b62ee98d";
const sbcenc_joint4 = "9cdc1f078c100d300598d632f31e2e83e5c56824455cd33199d760f110ee363519c3f15137665d50";
const sbcenc_stereo8 = "9cf923ebd1100000db0000002275c2390ae6b870d2d2c2c6e56eb2c9336a8a57a78a9654a10f889d52c5cab9a97a4db4b04b94fbaca8d586a295f6492595413782275bacf6ae6b6563ed2c34c326eb2d8ba5";

fn fromHex(comptime text: []const u8) [text.len / 2]u8 {
    var bytes: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
    return bytes;
}

/// A frame's settings, from its header.
fn configOf(frame: []const u8) Config {
    return .{
        .rate = ([_]u32{ 16000, 32000, 44100, 48000 })[frame[1] >> 6],
        .blocks = ([_]u8{ 4, 8, 12, 16 })[(frame[1] >> 4) & 3],
        .mode = @enumFromInt(@as(u2, @truncate(frame[1] >> 2))),
        .allocation = @enumFromInt(@as(u1, @truncate(frame[1] >> 1))),
        .subbands = if (frame[1] & 1 != 0) 8 else 4,
        .bitpool = frame[2],
    };
}

const BitReader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn get(reader: *BitReader, count: u5) u32 {
        var value: u32 = 0;
        for (0..count) |_| {
            value = value << 1 | (reader.bytes[reader.at / 8] >> @intCast(7 - reader.at % 8) & 1);
            reader.at += 1;
        }
        return value;
    }
};

/// The specification's decoder: subband samples from a frame, then the
/// synthesis filter - its matrix cos((i + 1/2)(k + M/2)pi/M), its window
/// the prototype times -M.
const Decoder = struct {
    v: [channels_most][20 * subbands_most]f64 = @splat(@splat(0)),

    fn decode(decoder: *Decoder, frame: []const u8, pcm: []f64) !usize {
        const config = configOf(frame);
        const channels = channelsOf(config.mode);
        const subbands: usize = config.subbands;
        const blocks: usize = config.blocks;
        if (frame[0] != SYNCWORD) return error.NoSync;
        if (crcOf(frame, crcBits(config)) != frame[3]) return error.Crc;
        var reader = BitReader{ .bytes = frame, .at = 32 };
        var join: [subbands_most]bool = @splat(false);
        if (config.mode == .joint_stereo) {
            for (0..subbands - 1) |subband| join[subband] = reader.get(1) == 1;
            _ = reader.get(1);
        }
        var scale: [channels_most][subbands_most]u4 = @splat(@splat(0));
        for (0..channels) |channel| {
            for (0..subbands) |subband| scale[channel][subband] = @intCast(reader.get(4));
        }
        var bits: [channels_most][subbands_most]u5 = undefined;
        allocate(config, &scale, &bits);
        const m: f64 = @floatFromInt(subbands);
        for (0..blocks) |block| {
            var samples: [channels_most][subbands_most]f64 = @splat(@splat(0));
            for (0..channels) |channel| {
                for (0..subbands) |subband| {
                    const count = bits[channel][subband];
                    if (count == 0) continue;
                    const levels: f64 = @floatFromInt((@as(u32, 1) << count) - 1);
                    const code: f64 = @floatFromInt(reader.get(count));
                    const factor: f64 = @floatFromInt(@as(u32, 2) << scale[channel][subband]);
                    samples[channel][subband] = factor * ((2.0 * code + 1.0) / levels - 1.0);
                }
            }
            for (0..subbands) |subband| {
                if (!join[subband]) continue;
                const sum = samples[0][subband];
                const difference = samples[1][subband];
                samples[0][subband] = sum + difference;
                samples[1][subband] = sum - difference;
            }
            for (0..channels) |channel| {
                const v = &decoder.v[channel];
                var index = 20 * subbands - 1;
                while (index >= 2 * subbands) : (index -= 1) v[index] = v[index - 2 * subbands];
                for (0..2 * subbands) |k| {
                    var sum: f64 = 0;
                    for (0..subbands) |i| {
                        const angle = (@as(f64, @floatFromInt(i)) + 0.5) * (@as(f64, @floatFromInt(k)) + m / 2.0) * pi / m;
                        sum += @cos(angle) * samples[channel][i];
                    }
                    v[k] = sum;
                }
                const proto: []const f32 = if (subbands == 4) &proto_4_40 else &proto_8_80;
                for (0..subbands) |j| {
                    var sum: f64 = 0;
                    for (0..5) |i| {
                        sum += v[i * 4 * subbands + j] * proto[i * 2 * subbands + j];
                        sum += v[i * 4 * subbands + 3 * subbands + j] * proto[i * 2 * subbands + subbands + j];
                    }
                    pcm[(block * subbands + j) * channels + channel] = -m * sum;
                }
            }
        }
        return frameLength(config);
    }
};

test "the prototype filters mirror themselves" {
    for (1..40) |at| try testing.expectEqual(@abs(proto_4_40[at]), @abs(proto_4_40[40 - at]));
    for (1..80) |at| try testing.expectEqual(@abs(proto_8_80[at]), @abs(proto_8_80[80 - at]));
}

test "frames of another encoder: their lengths, their CRCs, decoded" {
    inline for (.{ sbcenc_joint8, sbcenc_joint4, sbcenc_stereo8 }) |hex| {
        const frame = fromHex(hex);
        const config = configOf(&frame);
        try testing.expect(valid(config));
        try testing.expectEqual(frame.len, frameLength(config));
        try testing.expectEqual(frame[3], crcOf(&frame, crcBits(config)));
        var decoder = Decoder{};
        var pcm: [blocks_most * subbands_most * channels_most]f64 = undefined;
        try testing.expectEqual(frame.len, try decoder.decode(&frame, &pcm));
    }
    const joint8 = configOf(&fromHex(sbcenc_joint8));
    try testing.expectEqual(@as(u32, 48000), joint8.rate);
    try testing.expectEqual(@as(u8, 16), joint8.blocks);
    try testing.expectEqual(Mode.joint_stereo, joint8.mode);
    try testing.expectEqual(@as(u8, 8), joint8.subbands);
    try testing.expectEqual(@as(u8, 53), joint8.bitpool);
    try testing.expectEqual(@as(usize, 119), frameLength(joint8));
}

/// A second of a 1 kHz tone on the left and 440 Hz with 3150 Hz on the
/// right, 16 bits.
fn tone(pcm: []i16, rate: u32) void {
    const frames = pcm.len / 2;
    for (0..frames) |at| {
        const t = @as(f64, @floatFromInt(at)) / @as(f64, @floatFromInt(rate));
        pcm[at * 2] = @intFromFloat(@round(12000 * @sin(2 * pi * 1000 * t)));
        pcm[at * 2 + 1] = @intFromFloat(@round(9000 * @sin(2 * pi * 440 * t) + 3000 * @sin(2 * pi * 3150 * t)));
    }
}

/// The signal-to-noise ratio in dB of what came out against what went
/// in, `delay` samples later, a channel of two.
fn snr(input: []const i16, output: []const f64, delay: usize, channel: usize) f64 {
    var signal: f64 = 0;
    var noise: f64 = 0;
    const frames = input.len / 2;
    var at: usize = 1024;
    while (at + delay < frames) : (at += 1) {
        const want: f64 = @floatFromInt(input[at * 2 + channel]);
        const got = output[(at + delay) * 2 + channel];
        signal += want * want;
        noise += (want - got) * (want - got);
    }
    return 10 * @log10(signal / noise);
}

fn roundTrip(config: Config, delay: usize) !void {
    const allocator = testing.allocator;
    const frames = 9600;
    const input = try allocator.alloc(i16, frames * 2);
    defer allocator.free(input);
    const output = try allocator.alloc(f64, frames * 2);
    defer allocator.free(output);
    tone(input, config.rate);
    var encoder = Encoder.init(config);
    var decoder = Decoder{};
    var frame: [512]u8 = undefined;
    const per = samplesPerFrame(config);
    var at: usize = 0;
    while (at + per <= frames) : (at += per) {
        const length = encoder.encode(input[at * 2 ..][0 .. per * 2], &frame);
        try testing.expectEqual(frameLength(config), length);
        try testing.expectEqual(length, try decoder.decode(frame[0..length], output[at * 2 ..][0 .. per * 2]));
    }
    try testing.expect(snr(input[0 .. at * 2], output[0 .. at * 2], delay, 0) > 55);
    try testing.expect(snr(input[0 .. at * 2], output[0 .. at * 2], delay, 1) > 50);
}

test "a tone through the encoder and the decoder: 8 subbands 73 samples late, 4 subbands 37" {
    try roundTrip(.{}, 73);
    try roundTrip(.{ .subbands = 4, .blocks = 8, .bitpool = 31 }, 37);
    try roundTrip(.{ .rate = 44100, .mode = .stereo, .bitpool = 35 }, 73);
    try roundTrip(.{ .allocation = .snr }, 73);
    try roundTrip(.{ .mode = .dual_channel, .bitpool = 26 }, 73);
}

test "frame lengths, as another encoder's frames have them" {
    try testing.expectEqual(@as(usize, 119), frameLength(.{}));
    try testing.expectEqual(@as(usize, 83), frameLength(.{ .bitpool = 35 }));
    try testing.expectEqual(@as(usize, 118), frameLength(.{ .mode = .stereo }));
    try testing.expectEqual(@as(usize, 116), frameLength(.{ .mode = .dual_channel, .bitpool = 26 }));
    try testing.expectEqual(@as(usize, 40), frameLength(.{ .subbands = 4, .blocks = 8, .bitpool = 31 }));
    try testing.expectEqual(@as(usize, 72), frameLength(.{ .mode = .mono, .bitpool = 32 }));
    try testing.expectEqual(@as(usize, 26), frameLength(.{ .mode = .mono, .subbands = 4, .blocks = 8, .bitpool = 20 }));
}

test "the header as another encoder writes it" {
    const reference = fromHex(sbcenc_joint8);
    var encoder = Encoder.init(.{});
    var pcm: [128 * 2]i16 = @splat(0);
    tone(&pcm, 48000);
    var frame: [119]u8 = undefined;
    try testing.expectEqual(@as(usize, 119), encoder.encode(&pcm, &frame));
    try testing.expectEqualSlices(u8, reference[0..3], frame[0..3]);
    try testing.expectEqual(crcOf(&frame, crcBits(encoder.config)), frame[3]);
}

test "silence is silence, and a full-scale square is no more than clipped" {
    var encoder = Encoder.init(.{});
    var decoder = Decoder{};
    var pcm: [128 * 2]i16 = @splat(0);
    var frame: [119]u8 = undefined;
    var output: [128 * 2]f64 = undefined;
    for (0..4) |_| {
        _ = encoder.encode(&pcm, &frame);
        _ = try decoder.decode(&frame, &output);
    }
    for (output) |sample| try testing.expect(@abs(sample) < 1.0);
    for (0..128) |at| {
        const high = at / 24 % 2 == 0;
        pcm[at * 2] = if (high) 32767 else -32768;
        pcm[at * 2 + 1] = if (high) -32768 else 32767;
    }
    for (0..8) |_| {
        _ = encoder.encode(&pcm, &frame);
        _ = try decoder.decode(&frame, &output);
    }
    for (output) |sample| try testing.expect(@abs(sample) < 32768.0 * 1.5);
}

test "settings the specification allows" {
    try testing.expect(valid(.{}));
    try testing.expect(!valid(.{ .rate = 22050 }));
    try testing.expect(!valid(.{ .subbands = 6 }));
    try testing.expect(!valid(.{ .blocks = 10 }));
    try testing.expect(!valid(.{ .mode = .mono, .subbands = 4, .bitpool = 65 }));
    try testing.expect(valid(.{ .mode = .joint_stereo, .subbands = 4, .bitpool = 128 }));
    try testing.expect(!valid(.{ .bitpool = 1 }));
}
