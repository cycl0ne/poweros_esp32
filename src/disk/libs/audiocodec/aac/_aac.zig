// SPDX-License-Identifier: MIT
//! AAC as a stream: ADTS frames - a `.aac` file, a station's stream - read
//! from the stream's bytes, or the packets of a track of a container - an
//! `.m4a`, a `.mka`, a film's sound - from media.library (`_media.zig`).
//! Each packet is a raw data block (`decodeBlock`): its channels' streams
//! read (`ics.zig`), M/S and intensity stereo, TNS, and the filter bank
//! (`filterbank.zig`).
//!
//! **A container's track** says how many frames the encoder put before
//! the sound - they are left out - and how many there are. **A seek is
//! exact**: the track moves to the packet before the one the frame is in,
//! which is decoded only to fill the overlap, and the frames before the
//! one asked for are passed over. The noise of PNS bands is drawn anew
//! from there - the same noise, other samples - and from its start again
//! after a seek to frame 0, which so gives the very samples the stream
//! began with.
//!
//! **ADTS** has no index: the length is worked out from the frames read
//! ahead at the start - their bytes a frame - and the file's size, and a
//! seek from the same; the frame landed on is decoded only to fill the
//! overlap. An ID3v2 tag in front is read for its names.
//!
//! The core of AAC-LC is decoded, mono or stereo: an HE-AAC stream plays
//! its core, at half the rate SBR would make; Main, SSR, LTP and coupling
//! channels are refused. Noise (PNS) is drawn from FFmpeg's generator, and
//! in each channel of a pair on its own, as FFmpeg does - so a file
//! decodes to FFmpeg's samples.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const media = sdk.media;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;
const _media = @import("../stream/_media.zig");
const mp3 = @import("../mp3/_mp3.zig");
const setup = @import("../vorbis/setup.zig");
const config = @import("config.zig");
const ics = @import("ics.zig");
const filterbank = @import("filterbank.zig");
const Bits = @import("bits.zig").Bits;

/// Samples a channel each frame holds.
const frame_samples = 1024;

pub const Aac = struct {
    config: config.Config,
    /// The tables and buffers.
    pool: ?*anyopaque,
    bank: filterbank.Bank,
    powers: *ics.Powers,
    quant: *[1024]i32,
    channels: [2]ics.Channel,
    coef: [2][*]f32,
    overlap: [2][*]f32,
    output: [2][*]f32,
    previous_shape: [2]u8,
    noise: ics.Noise,
    ms: [ics.max_bands]bool,
    /// ADTS: where the next frame's sound lies, in frames from the start;
    /// frames before `skip_until` are passed over; after a seek the first
    /// frame only fills the overlap.
    position: i64,
    skip_until: i64,
    discard: bool,
    /// ADTS: where the first frame lies, the bytes a frame on average,
    /// the header the frames must agree with, and a frame's raw data
    /// blocks still to decode, from bit `block_at`.
    first_frame: u64,
    frame_bytes: u32,
    header: [4]u8,
    blocks_left: u32,
    block_at: usize,
    resync: bool,
};

fn reset(a: *Aac) void {
    a.channels = .{ .{}, .{} };
    a.previous_shape = .{ 0, 0 };
    for (0..2) |ch| @memset(a.overlap[ch][0..frame_samples], 0);
}

/// The stream's bytes made an AAC stream of ADTS frames.
pub fn open(stream: *Stream) i32 {
    return openAdts(stream);
}

fn begin(stream: *Stream) *Aac {
    stream.codec = .{ .aac = undefined };
    const a = &stream.codec.aac;
    a.* = .{
        .config = .{},
        .pool = null,
        .bank = undefined,
        .powers = undefined,
        .quant = undefined,
        .channels = .{ .{}, .{} },
        .coef = undefined,
        .overlap = undefined,
        .output = undefined,
        .previous_shape = .{ 0, 0 },
        .noise = .{},
        .ms = @splat(false),
        .position = 0,
        .skip_until = 0,
        .discard = false,
        .first_frame = 0,
        .frame_bytes = 0,
        .header = @splat(0),
        .blocks_left = 0,
        .block_at = 0,
        .resync = false,
    };
    return a;
}

/// The tables and buffers, and the info of what the stream is.
fn prepare(stream: *Stream, a: *Aac, cfg: config.Config) i32 {
    if (cfg.object_type != config.LC) return ac.ACERR_UNSUPPORTED;
    if (cfg.channels == 0 or cfg.channels > 2) return ac.ACERR_UNSUPPORTED;
    a.config = cfg;
    const sys = stream.base.sys_base;
    const pool = sys.CreatePool(exec.MEMF_ANY | exec.MEMF_CLEAR, 32 * 1024, 8 * 1024) orelse return ac.ACERR_NOMEMORY;
    a.pool = pool;
    if (!filterbank.init(sys, pool, &a.bank)) return ac.ACERR_NOMEMORY;
    a.powers = @ptrCast(setup.allocate(sys, pool, ics.Powers, 1) orelse return ac.ACERR_NOMEMORY);
    a.quant = @ptrCast(setup.allocate(sys, pool, [1024]i32, 1) orelse return ac.ACERR_NOMEMORY);
    for (0..2) |ch| {
        a.coef[ch] = setup.allocate(sys, pool, f32, frame_samples) orelse return ac.ACERR_NOMEMORY;
        a.overlap[ch] = setup.allocate(sys, pool, f32, frame_samples) orelse return ac.ACERR_NOMEMORY;
        a.output[ch] = setup.allocate(sys, pool, f32, frame_samples) orelse return ac.ACERR_NOMEMORY;
    }
    ics.makePowers(a.powers);
    reset(a);
    stream.info.codec = ac.ACODEC_AAC;
    stream.info.rate = cfg.rate;
    stream.info.channels = cfg.channels;
    stream.info.bits = 16;
    return ac.ACERR_OK;
}

pub fn free(stream: *Stream, a: *Aac) void {
    const sys = stream.base.sys_base;
    if (a.pool) |pool| sys.DeletePool(pool);
    a.pool = null;
}

// --- ADTS -------------------------------------------------------------------------

fn openAdts(stream: *Stream) i32 {
    mp3.skipId3v2(stream);
    _stream.fill(stream);
    const a = begin(stream);
    // The first header the next one agrees with, within 64 KiB.
    const from = _stream.tell(stream);
    while (!framed(stream)) {
        if (_stream.available(stream).len < 7 or _stream.tell(stream) - from > 64 * 1024) {
            return if (stream.failed) ac.ACERR_READ else ac.ACERR_UNKNOWN;
        }
        _stream.consume(stream, 1);
        if (_stream.available(stream).len < 8192 + 7 and !stream.eof) _stream.fill(stream);
    }
    const bytes = _stream.available(stream);
    const h = config.adts(bytes).?;
    @memcpy(&a.header, bytes[0..4]);
    const result = prepare(stream, a, h.config);
    if (result != ac.ACERR_OK) return result;
    a.first_frame = _stream.tell(stream);

    // The bytes a frame, from the frames read ahead.
    var at: usize = 0;
    var blocks: u32 = 0;
    while (at + 7 <= bytes.len) {
        const next = config.adts(bytes[at..]) orelse break;
        if (!config.sameStream(bytes, bytes[at..]) or at + next.length > bytes.len) break;
        at += next.length;
        blocks += next.blocks;
    }
    if (blocks != 0) {
        a.frame_bytes = @intCast(at / blocks);
        stream.info.bitrate = @intCast(@min(@as(u64, at) * 8 * h.config.rate / (@as(u64, blocks) * frame_samples), 0xFFFF_FFFF));
    }
    if (stream.has_end and stream.end > a.first_frame and a.frame_bytes != 0) {
        const frames = (stream.end - a.first_frame) / a.frame_bytes * frame_samples;
        stream.info.frames = @intCast(@min(frames, 0xFFFF_FFFF));
    }
    return ac.ACERR_OK;
}

/// Whether a frame begins at the front of what is read ahead: a header,
/// and the next frame's agreeing with it - or the bytes ending with it.
fn framed(stream: *Stream) bool {
    const bytes = _stream.available(stream);
    const h = config.adts(bytes) orelse return false;
    if (h.length == bytes.len) return stream.eof;
    if (h.length + 7 > bytes.len) return false;
    return config.adts(bytes[h.length..]) != null and config.sameStream(bytes, bytes[h.length..]);
}

/// The next raw data block of the ADTS frames: its bits, or null at the
/// end. A frame of several blocks is decoded one block a call.
fn nextAdtsBlock(stream: *Stream, a: *Aac) ?Bits {
    while (true) {
        if (a.blocks_left == 0) {
            if (stream.stop - stream.start < 8192 + 7 and !stream.eof) _stream.fill(stream);
            const bytes = _stream.available(stream);
            if (bytes.len < 7) return null;
            const h = config.adts(bytes) orelse {
                _stream.consume(stream, 1);
                continue;
            };
            // After a seek, a header is believed only with the next one.
            if (!config.sameStream(&a.header, bytes) or (a.resync and !framed(stream))) {
                _stream.consume(stream, 1);
                continue;
            }
            a.resync = false;
            if (h.length > bytes.len) {
                // A frame cut off at the end.
                if (stream.eof) return null;
                _stream.consume(stream, 1);
                continue;
            }
            a.blocks_left = h.blocks;
            // A CRC for each block after the header, when there are several.
            const header: usize = if (h.protected and h.blocks > 1) 7 + 2 * h.blocks else h.header;
            a.block_at = header * 8;
        }
        const bytes = _stream.available(stream);
        const h = config.adts(bytes).?;
        return .{ .bytes = bytes[0..h.length], .at = a.block_at };
    }
}

/// Past the block just decoded: the frame consumed after its last.
fn endAdtsBlock(stream: *Stream, a: *Aac, bits: *const Bits) void {
    a.blocks_left -= 1;
    var at = (bits.at + 7) & ~@as(usize, 7);
    const h = config.adts(_stream.available(stream)).?;
    if (h.protected and h.blocks > 1) at += 16;
    a.block_at = at;
    if (a.blocks_left == 0) _stream.consume(stream, h.length);
}

// --- a container's track --------------------------------------------------------

/// A track of a container (`_media.zig`): its config read, the tables and
/// buffers made.
pub fn openTrack(stream: *Stream, track: *const media.MediaTrack) i32 {
    const a = begin(stream);
    if (track.config == null) return ac.ACERR_CORRUPT;
    const cfg = config.audioSpecific(track.config.?[0..track.config_size]) catch |e| return switch (e) {
        error.Unsupported => ac.ACERR_UNSUPPORTED,
        error.Corrupt => ac.ACERR_CORRUPT,
    };
    return prepare(stream, a, cfg);
}

// --- decoding ---------------------------------------------------------------------

/// Up to `frames` frames into `out`: how many, 0 at the end.
pub fn decode(stream: *Stream, a: *Aac, out: [*]i16, frames: u32) i32 {
    const channels: usize = stream.info.channels;
    var done: u32 = 0;
    while (done < frames) {
        if (stream.pcm_start == stream.pcm_stop) {
            if (!decodeNext(stream, a)) break;
            continue;
        }
        const ready: u32 = @intCast((stream.pcm_stop - stream.pcm_start) / channels);
        const count = @min(ready, frames - done);
        const samples = count * channels;
        @memcpy(out[@as(usize, done) * channels ..][0..samples], stream.pcm[stream.pcm_start..][0..samples]);
        stream.pcm_start += samples;
        done += count;
    }
    if (done == 0 and stream.failed) return ac.ACERR_READ;
    return @intCast(done);
}

/// The next packet decoded into the stream's samples, the frames passed
/// over and cut left out: false at the end.
fn decodeNext(stream: *Stream, a: *Aac) bool {
    if (stream.media.base != null) return decodePacket(stream, a);
    while (true) {
        const start: i64 = a.position;
        var bits = nextAdtsBlock(stream, a) orelse return false;
        const decoded = decodeBlock(a, &bits) catch null;
        endAdtsBlock(stream, a, &bits);
        a.position = start + frame_samples;
        // A frame that would not decode is passed over, and what was
        // left of the one before with it.
        const got = decoded orelse {
            reset(a);
            continue;
        };
        if (a.discard) {
            a.discard = false;
            continue;
        }
        const first: i64 = @max(0, a.skip_until - start);
        if (first >= frame_samples) continue;
        toSamples(stream, a, got, @intCast(first), frame_samples);
        return true;
    }
}

/// A container's next packet decoded, as `decodeNext` does. The packet a
/// seek lands on lies before the frame asked for, so it only fills the
/// overlap.
fn decodePacket(stream: *Stream, a: *Aac) bool {
    while (true) {
        var packet: media.MediaPacket = .{};
        const bytes = _media.next(stream, &packet) orelse return false;
        const start = _media.place(&stream.media, packet.ticks);
        _media.advance(&stream.media, frame_samples);
        var bits: Bits = .{ .bytes = bytes };
        const got = decodeBlock(a, &bits) catch {
            reset(a);
            continue;
        };
        const span = _media.window(&stream.media, start, frame_samples) orelse continue;
        toSamples(stream, a, got, span.first, span.last);
        return true;
    }
}

/// Frames `first` to `last` of the packet's sound into the stream's
/// samples, interleaved: one channel decoded onto both where the stream
/// has two.
fn toSamples(stream: *Stream, a: *Aac, decoded: u32, first: usize, last: usize) void {
    const channels: usize = stream.info.channels;
    const pcm = &stream.pcm;
    for (0..channels) |ch| {
        const from = a.output[if (ch < decoded) ch else 0];
        for (first..last, 0..) |i, n| pcm[n * channels + ch] = toSixteen(from[i]);
    }
    stream.pcm_start = 0;
    stream.pcm_stop = (last - first) * channels;
}

fn toSixteen(sample: f32) i16 {
    const held = @max(-32768.0, @min(sample, 32767.0));
    // Added to 1.5 * 2^23, the sum's low bits are the rounded value.
    const sum: f32 = held + 12582912.0;
    const word: u32 = @bitCast(sum);
    return @truncate(@as(i32, @bitCast(word)) - 0x4B40_0000);
}

const SCE = 0;
const CPE = 1;
const CCE = 2;
const LFE = 3;
const DSE = 4;
const PCE = 5;
const FIL = 6;
const END = 7;

/// A raw data block: its elements read, its channels made sound in
/// `output`. Answers how many channels it had.
fn decodeBlock(a: *Aac, bits: *Bits) (ics.Error || config.Error)!u32 {
    const rate = a.config.rate_index;
    var channels: u32 = 0;
    while (true) {
        const id = bits.read(3);
        if (bits.overrun()) return error.Corrupt;
        switch (id) {
            SCE, LFE => {
                bits.skip(4);
                if (channels >= 2) return error.Unsupported;
                const ch = &a.channels[channels];
                try ics.readSide(bits, rate, false, ch);
                try ics.readSpectrum(bits, ch, a.quant);
                ics.dequantise(ch, a.quant, a.powers, &a.noise, a.coef[channels]);
                channels += 1;
            },
            CPE => {
                bits.skip(4);
                if (channels != 0) return error.Unsupported;
                const left = &a.channels[0];
                const right = &a.channels[1];
                const common = bits.bit();
                var ms_present: u8 = 0;
                if (common) {
                    try ics.readInfo(bits, rate, &left.info);
                    right.info = left.info;
                    ms_present = @intCast(bits.read(2));
                    if (ms_present == 3) return error.Corrupt;
                    const count = @as(usize, left.info.groups) * left.info.max_sfb;
                    for (a.ms[0..count]) |*flag| flag.* = ms_present == 2 or (ms_present == 1 and bits.bit());
                }
                try ics.readSide(bits, rate, common, left);
                try ics.readSpectrum(bits, left, a.quant);
                ics.dequantise(left, a.quant, a.powers, &a.noise, a.coef[0]);
                try ics.readSide(bits, rate, common, right);
                try ics.readSpectrum(bits, right, a.quant);
                ics.dequantise(right, a.quant, a.powers, &a.noise, a.coef[1]);
                if (common) {
                    if (ms_present != 0) ics.applyMs(left, right, &a.ms, a.coef[0], a.coef[1]);
                    ics.applyIntensity(left, right, ms_present, &a.ms, a.coef[0], a.coef[1]);
                }
                channels = 2;
            },
            CCE => return error.Unsupported,
            DSE => {
                bits.skip(4);
                const aligned = bits.bit();
                var count = bits.read(8);
                if (count == 255) count += bits.read(8);
                if (aligned) bits.alignByte();
                bits.skip(8 * count);
            },
            PCE => _ = try config.programConfig(bits),
            FIL => {
                var count = bits.read(4);
                if (count == 15) count = count + bits.read(8) - 1;
                bits.skip(8 * count);
            },
            END => break,
            else => unreachable,
        }
    }
    if (bits.overrun()) return error.Corrupt;
    if (channels == 0) return error.Corrupt;
    for (0..channels) |ch| {
        const c = &a.channels[ch];
        ics.applyTns(c, a.coef[ch]);
        filterbank.synthesize(&a.bank, &c.info, a.previous_shape[ch], a.coef[ch], a.overlap[ch], a.output[ch]);
        a.previous_shape[ch] = c.info.shape;
    }
    return channels;
}

// --- seeking ----------------------------------------------------------------------

/// The stream moved to `frame`: exactly in a container, near it by the
/// bytes a frame in ADTS. The packet before is decoded only to fill the
/// overlap.
pub fn seek(stream: *Stream, a: *Aac, frame: u32) i32 {
    stream.pcm_start = 0;
    stream.pcm_stop = 0;
    if (stream.media.base != null) {
        // A packet early: its own sound is passed over, its tail kept.
        const result = _media.seek(stream, frame, frame_samples);
        if (result != ac.ACERR_OK) return result;
        reset(a);
        a.noise = .{};
        return ac.ACERR_OK;
    }
    if (stream.file == null) return ac.ACERR_NOSEEK;
    var offset: u64 = 0;
    if (frame != 0 and a.frame_bytes != 0) offset = @as(u64, frame) / frame_samples * a.frame_bytes;
    if (stream.has_end and stream.end > a.first_frame) offset = @min(offset, stream.end - a.first_frame);
    if (!_stream.seekSource(stream, a.first_frame + offset)) return ac.ACERR_NOSEEK;
    reset(a);
    a.noise = .{};
    a.blocks_left = 0;
    a.resync = frame != 0;
    a.discard = frame != 0;
    a.position = if (frame != 0) @as(i64, frame) - frame_samples else 0;
    a.skip_until = frame;
    return ac.ACERR_OK;
}
