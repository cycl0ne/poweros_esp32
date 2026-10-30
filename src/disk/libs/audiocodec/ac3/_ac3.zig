// SPDX-License-Identifier: MIT
//! AC-3 and E-AC-3 as a stream: syncframes one after another - a `.ac3`
//! or `.eac3` file - read from the stream's bytes, or the packets of a
//! container's track - a film's sound in an MP4 or a Matroska file -
//! from media.library (`_media.zig`), a packet holding one frame or
//! several. Each frame is read (`header.zig`, and E-AC-3's frame data),
//! then its blocks one at a time (`frame.zig`), each turned into 256
//! samples of each channel (`synthesis.zig`).
//!
//! **What is heard**: the program of the first substream, mixed into two
//! channels - one for a mono stream - with the stream's own levels;
//! E-AC-3's dependent frames, which add channels past 5.1, are passed
//! over, as are other programs. A frame that will not decode is heard
//! as silence for its length, and the next begins afresh.
//!
//! **Raw frames** are found by their sync word and believed when the next
//! frame's header agrees. The length is worked out from the frames read
//! ahead at the start - their bytes a frame - and the file's size, a
//! seek from the same: AC-3's frames are all one size, so a seek lands
//! where it means to. A frame early, so the overlap is filled.
//!
//! **A container's track** places each packet by its time; a seek moves
//! it a block before the frame asked for and passes over the frames
//! before it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const media = sdk.media;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;
const _media = @import("../stream/_media.zig");
const setup = @import("../vorbis/setup.zig");
const tables = @import("tables.zig");
const header = @import("header.zig");
const frame = @import("frame.zig");
const synthesis = @import("synthesis.zig");
const Bits = @import("../aac/bits.zig").Bits;

/// Samples a channel each block holds.
const block_samples = 256;

pub const Ac3 = struct {
    /// The decoder's state and the synthesis's buffers.
    pool: ?*anyopaque,
    decoder: *frame.Decoder,
    synthesis: synthesis.Synthesis,
    /// The frame being decoded: its bits, its next block and how many it
    /// has, its full-bandwidth channels; whether it would not decode.
    bits: Bits,
    block: u32,
    blocks: u32,
    fbw: usize,
    broken: bool,
    /// The header frames must agree with: the first one's.
    first: header.Header,
    /// A container's packet: the bytes after the frame being decoded,
    /// and where the next block's sound lies.
    rest: []const u8,
    at: i64,
    /// Raw frames: where the next block's sound lies, in frames from the
    /// start; frames before `skip_until` are passed over; after a seek the
    /// first block only fills the overlap.
    position: i64,
    skip_until: i64,
    discard: bool,
    /// Raw frames: where the first lies; the bytes and frames read ahead
    /// at the start, which say how long one is; the frame's bytes, given
    /// back after its last block; whether a header is believed only with
    /// the next, after a seek.
    first_frame: u64,
    ahead_bytes: u32,
    ahead_frames: u32,
    frame_bytes: u32,
    resync: bool,
};

fn begin(stream: *Stream) *Ac3 {
    stream.codec = .{ .ac3 = undefined };
    const a = &stream.codec.ac3;
    a.* = .{
        .pool = null,
        .decoder = undefined,
        .synthesis = undefined,
        .bits = .{ .bytes = &.{} },
        .block = 0,
        .blocks = 0,
        .fbw = 0,
        .broken = false,
        .first = .{},
        .rest = &.{},
        .at = 0,
        .position = 0,
        .skip_until = 0,
        .discard = false,
        .first_frame = 0,
        .ahead_bytes = 0,
        .ahead_frames = 0,
        .frame_bytes = 0,
        .resync = false,
    };
    return a;
}

/// The decoder and the synthesis made, and the info of what the stream
/// is: by the first frame's header.
fn prepare(stream: *Stream, a: *Ac3, h: header.Header) i32 {
    a.first = h;
    const sys = stream.base.sys_base;
    const pool = sys.CreatePool(exec.MEMF_ANY | exec.MEMF_CLEAR, 32 * 1024, 8 * 1024) orelse return ac.ACERR_NOMEMORY;
    a.pool = pool;
    a.decoder = @ptrCast(setup.allocate(sys, pool, frame.Decoder, 1) orelse return ac.ACERR_NOMEMORY);
    if (!synthesis.init(sys, pool, &a.synthesis)) return ac.ACERR_NOMEMORY;
    reset(stream, a);
    stream.info.codec = if (h.eac3) ac.ACODEC_EAC3 else ac.ACODEC_AC3;
    stream.info.rate = h.rate;
    stream.info.channels = if (h.mode == 1) 1 else 2;
    stream.info.bits = 16;
    stream.info.bitrate = h.bitrate;
    return ac.ACERR_OK;
}

/// The decoder as at the start: its state cleared, its noise seeded
/// again, nothing left of blocks before.
fn reset(stream: *Stream, a: *Ac3) void {
    stream.base.sys_base.SetMem(a.decoder, 0, @sizeOf(frame.Decoder));
    a.decoder.noise.seed();
    synthesis.clear(&a.synthesis);
    a.block = 0;
    a.blocks = 0;
}

pub fn free(stream: *Stream, a: *Ac3) void {
    const sys = stream.base.sys_base;
    if (a.pool) |pool| sys.DeletePool(pool);
    a.pool = null;
}

/// Whether a frame is the program's: AC-3, or E-AC-3's first substream's
/// independent frames.
fn heard(h: *const header.Header) bool {
    return !h.eac3 or (h.kind != header.DEPENDENT and h.substream == 0);
}

/// Whether a frame is of the same stream as the first.
fn agrees(a: *const header.Header, b: *const header.Header) bool {
    return a.eac3 == b.eac3 and a.rate == b.rate;
}

/// The frame `bytes` holds made the one to decode: its header and frame
/// data read, its mix set. One damaged or that will not read is decoded
/// as silence.
fn startFrame(stream: *Stream, a: *Ac3, peeked: *const header.Header, bytes: []const u8) void {
    a.bits = .{ .bytes = bytes };
    a.block = 0;
    a.blocks = peeked.blocks;
    a.fbw = tables.mode_channels[peeked.mode];
    a.broken = false;
    const read = if (header.intact(bytes)) header.read(&a.bits) else null;
    const h = read orelse {
        a.broken = true;
        synthesis.setMix(&a.synthesis, peeked, stream.info.channels);
        return;
    };
    synthesis.setMix(&a.synthesis, &h, stream.info.channels);
    frame.begin(a.decoder, h, &a.bits) catch {
        a.broken = true;
    };
}

// --- raw frames -------------------------------------------------------------------

/// The stream's bytes made a stream of syncframes.
pub fn open(stream: *Stream) i32 {
    _stream.fill(stream);
    const a = begin(stream);
    // The first frame the next one agrees with, within 64 KiB.
    const from = _stream.tell(stream);
    while (!framed(stream, null)) {
        if (_stream.available(stream).len < 8 or _stream.tell(stream) - from > 64 * 1024) {
            return if (stream.failed) ac.ACERR_READ else ac.ACERR_UNKNOWN;
        }
        _stream.consume(stream, 1);
        if (_stream.available(stream).len < 8192 and !stream.eof) _stream.fill(stream);
    }
    const bytes = _stream.available(stream);
    const h = header.peek(bytes).?;
    const result = prepare(stream, a, h);
    if (result != ac.ACERR_OK) return result;
    a.first_frame = _stream.tell(stream);

    // The bytes a frame, from the frames read ahead: the program's, with
    // what comes between them.
    var at: usize = 0;
    var count: u32 = 0;
    while (at + 8 <= bytes.len) {
        const next = header.peek(bytes[at..]) orelse break;
        if (!agrees(&h, &next) or at + next.size > bytes.len) break;
        at += next.size;
        if (heard(&next)) count += 1;
    }
    a.ahead_bytes = @intCast(at);
    a.ahead_frames = count;
    // AC-3 says its rate; E-AC-3's is its frames'.
    if (count != 0 and h.eac3) {
        const samples = @as(u64, count) * h.blocks * block_samples;
        stream.info.bitrate = @intCast(@min(@as(u64, at) * 8 * h.rate / samples, 0xFFFF_FFFF));
    }
    if (stream.has_end and stream.end > a.first_frame and count != 0) {
        const frames = (stream.end - a.first_frame) * count / at * h.blocks * block_samples;
        stream.info.frames = @intCast(@min(frames, 0xFFFF_FFFF));
    }
    return ac.ACERR_OK;
}

/// Whether a frame begins at the front of what is read ahead: a header
/// - agreeing with `first`, when given - and the next frame's agreeing
/// with it, or the bytes ending with it.
fn framed(stream: *Stream, first: ?*const header.Header) bool {
    const bytes = _stream.available(stream);
    const h = header.peek(bytes) orelse return false;
    if (first) |f| {
        if (!agrees(f, &h)) return false;
    }
    if (h.size == bytes.len) return stream.eof;
    if (h.size + 8 > bytes.len) return false;
    const next = header.peek(bytes[h.size..]) orelse return false;
    return agrees(&h, &next);
}

/// The next frame of the program in the stream's bytes, begun: false at
/// the end. The frame stays in the read-ahead until its last block.
fn nextRawFrame(stream: *Stream, a: *Ac3) bool {
    while (true) {
        if (stream.stop - stream.start < 8192 and !stream.eof) _stream.fill(stream);
        const bytes = _stream.available(stream);
        if (bytes.len < 8) return false;
        const h = header.peek(bytes) orelse {
            _stream.consume(stream, 1);
            continue;
        };
        // After a seek, a header is believed only with the next one.
        if (!agrees(&a.first, &h) or (a.resync and !framed(stream, &a.first))) {
            _stream.consume(stream, 1);
            continue;
        }
        a.resync = false;
        if (h.size > bytes.len) {
            // A frame cut off at the end.
            if (stream.eof) return false;
            _stream.consume(stream, 1);
            continue;
        }
        if (!heard(&h)) {
            _stream.consume(stream, h.size);
            continue;
        }
        a.frame_bytes = h.size;
        startFrame(stream, a, &h, bytes[0..h.size]);
        return true;
    }
}

// --- a container's track --------------------------------------------------------

/// A track of a container (`_media.zig`): what it is by the first
/// packet's frame - by the track's own word where it has none.
pub fn openTrack(stream: *Stream, track: *const media.MediaTrack) i32 {
    const a = begin(stream);
    const source = &stream.media;
    var h: header.Header = .{
        .eac3 = track.codec == media.MCODEC_EAC3,
        .rate = track.rate,
        .mode = if (track.channels == 1) 1 else 2,
    };
    if (source.holding and source.held.data != null) {
        if (header.peek(source.held.data.?[0..source.held.size])) |found| h = found;
    }
    if (h.rate == 0) return ac.ACERR_CORRUPT;
    return prepare(stream, a, h);
}

/// The samples a packet's frames hold: its program's.
fn samplesIn(bytes: []const u8) u32 {
    var rest = bytes;
    var samples: u32 = 0;
    while (header.peek(rest)) |h| {
        if (h.size > rest.len) break;
        if (heard(&h)) samples += h.blocks * block_samples;
        rest = rest[h.size..];
    }
    return samples;
}

/// The next frame of the program in the track's packets, begun: false at
/// the end. A packet's frames are placed one after another from its time.
fn nextPacketFrame(stream: *Stream, a: *Ac3) bool {
    while (true) {
        if (a.rest.len == 0) {
            var packet: media.MediaPacket = .{};
            const bytes = _media.next(stream, &packet) orelse return false;
            a.at = _media.place(&stream.media, packet.ticks);
            _media.advance(&stream.media, samplesIn(bytes));
            a.rest = bytes;
            continue;
        }
        const h = header.peek(a.rest) orelse {
            a.rest = &.{};
            continue;
        };
        if (h.size > a.rest.len) {
            a.rest = &.{};
            continue;
        }
        const bytes = a.rest[0..h.size];
        a.rest = a.rest[h.size..];
        if (!heard(&h)) continue;
        startFrame(stream, a, &h, bytes);
        return true;
    }
}

// --- decoding ---------------------------------------------------------------------

/// Up to `frames` frames into `out`: how many, 0 at the end.
pub fn decode(stream: *Stream, a: *Ac3, out: [*]i16, frames: u32) i32 {
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

/// The next block decoded into the stream's samples, the frames passed
/// over and cut left out: false at the end.
fn decodeNext(stream: *Stream, a: *Ac3) bool {
    const in_track = stream.media.base != null;
    while (true) {
        if (a.block == a.blocks) {
            const found = if (in_track) nextPacketFrame(stream, a) else nextRawFrame(stream, a);
            if (!found) return false;
            continue;
        }
        const start: i64 = if (in_track) a.at else a.position;
        if (in_track) a.at += block_samples else a.position += block_samples;
        const blk = a.block;
        a.block += 1;
        if (!a.broken) {
            frame.block(a.decoder, &a.bits, blk) catch {
                a.broken = true;
            };
        }
        const s = &a.synthesis;
        if (a.broken) {
            for (0..a.fbw) |ch| @memset(s.output[ch][0..block_samples], 0);
            synthesis.clear(s);
        } else {
            const d = a.decoder;
            for (1..a.fbw + 1) |ch| synthesis.channel(s, &d.coeffs[ch], d.block_switch[ch], ch - 1);
        }
        if (!in_track and a.block == a.blocks) _stream.consume(stream, a.frame_bytes);

        var first: usize = 0;
        var last: usize = block_samples;
        if (in_track) {
            const span = _media.window(&stream.media, start, block_samples) orelse continue;
            first = span.first;
            last = span.last;
        } else {
            if (a.discard) {
                a.discard = false;
                continue;
            }
            const passed = @max(0, a.skip_until - start);
            if (passed >= block_samples) continue;
            first = @intCast(passed);
        }
        const channels: usize = stream.info.channels;
        synthesis.samples(s, a.fbw, channels, first, last, &stream.pcm);
        stream.pcm_start = 0;
        stream.pcm_stop = (last - first) * channels;
        return true;
    }
}

// --- seeking ----------------------------------------------------------------------

/// The stream moved to `frame`: exactly in a container, near it by the
/// bytes a frame in raw frames - a frame early, its first block only
/// filling the overlap.
pub fn seek(stream: *Stream, a: *Ac3, to: u32) i32 {
    stream.pcm_start = 0;
    stream.pcm_stop = 0;
    if (stream.media.base != null) {
        const result = _media.seek(stream, to, block_samples);
        if (result != ac.ACERR_OK) return result;
        reset(stream, a);
        a.rest = &.{};
        return ac.ACERR_OK;
    }
    if (stream.file == null) return ac.ACERR_NOSEEK;
    const frame_samples: u64 = @as(u64, a.first.blocks) * block_samples;
    // From the first frame the start is as it was; past it, a frame
    // early.
    const early = to >= frame_samples;
    const index: u64 = if (early) to / frame_samples - 1 else 0;
    var offset: u64 = 0;
    if (a.ahead_frames != 0) offset = index * a.ahead_bytes / a.ahead_frames;
    if (stream.has_end and stream.end > a.first_frame) offset = @min(offset, stream.end - a.first_frame);
    if (!_stream.seekSource(stream, a.first_frame + offset)) return ac.ACERR_NOSEEK;
    reset(stream, a);
    a.resync = early;
    a.discard = early;
    a.position = @intCast(index * frame_samples);
    a.skip_until = to;
    return ac.ACERR_OK;
}
