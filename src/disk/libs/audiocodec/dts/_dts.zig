// SPDX-License-Identifier: MIT
//! DTS as a stream: core frames one after another - a `.dts` file - read
//! from the stream's bytes, or the packets of a container's track - a
//! film's sound in a Matroska file or an MP4 - from media.library
//! (`_media.zig`). Each frame's subframes are read (`frame.zig`), one at a
//! time, each turned into samples of each channel (`synthesis.zig`).
//!
//! **What is heard**: the core, mixed into two channels - one for a mono
//! stream. A DTS-HD track's lossless or high resolution data, and all else
//! past the core, is passed over: the core is its lossy version, at the
//! core's own rate. A track with no core - DTS Express - is ACERR_UNSUPPORTED.
//! A frame that will not decode is heard as silence for its length, and
//! the next begins afresh.
//!
//! **Raw frames** are found by their sync word, in any of its four forms,
//! and believed when the next frame's header agrees or an extension
//! substream follows. The length is worked out from the frames read ahead
//! at the start - their bytes a frame - and the file's size, a seek from
//! the same, early enough that the filter is filled and the predictors
//! have their history.
//!
//! **A container's track** places each packet by its time; a seek moves
//! it as early and passes over what is before the frame asked for.

const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const media = sdk.media;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;
const _media = @import("../stream/_media.zig");
const setup = @import("../vorbis/setup.zig");
const header = @import("header.zig");
const frame = @import("frame.zig");
const synthesis = @import("synthesis.zig");
const Bits = @import("../aac/bits.zig").Bits;

/// Samples a channel each block holds.
const block_samples = 32;
/// How far before the sample asked for a seek starts decoding, at least: a
/// frame's filter fills in 512 samples, but the predictors of a steady tone
/// take longer to forget they began with no history.
const seek_early = 2048;

pub const Dts = struct {
    /// The decoder's state and the synthesis's buffers, and where a frame
    /// not of plain bytes is unpacked.
    pool: ?*anyopaque,
    decoder: *frame.Decoder,
    synthesis: *synthesis.Synthesis,
    unpacked: ?[*]u8,
    /// The frame being decoded: its bits, its header, its subframes read
    /// and blocks not yet heard; whether it would not decode.
    bits: Bits,
    current: header.Header,
    subframes: u32,
    left: u32,
    broken: bool,
    /// The header frames must agree with: the first one's.
    first: header.Header,
    /// A container's packet: the bytes after the frame being decoded,
    /// and where the next subframe's sound lies.
    rest: []const u8,
    at: i64,
    /// Raw frames: where the next subframe's sound lies, in frames from the
    /// start; frames before `skip_until` are passed over.
    position: i64,
    skip_until: i64,
    /// Raw frames: where the first lies; the bytes and frames read ahead
    /// at the start, which say how long one is; the frame's bytes, given
    /// back after its last subframe; whether a header is believed only with
    /// the next, after a seek.
    first_frame: u64,
    ahead_bytes: u32,
    ahead_frames: u32,
    frame_bytes: u32,
    resync: bool,
};

fn begin(stream: *Stream) ?*Dts {
    const a = _stream.stateOf(stream, Dts) orelse return null;
    a.* = .{
        .pool = null,
        .decoder = undefined,
        .synthesis = undefined,
        .unpacked = null,
        .bits = .{ .bytes = &.{} },
        .current = .{},
        .subframes = 0,
        .left = 0,
        .broken = false,
        .first = .{},
        .rest = &.{},
        .at = 0,
        .position = 0,
        .skip_until = 0,
        .first_frame = 0,
        .ahead_bytes = 0,
        .ahead_frames = 0,
        .frame_bytes = 0,
        .resync = false,
    };
    return a;
}

/// The decoder and the synthesis made, and the info of what the stream
/// is: by the first frame's header. An arrangement past the core's is
/// not for this decoder.
fn prepare(stream: *Stream, a: *Dts, h: header.Header) i32 {
    if (h.mode >= header.mode_channels.len) return ac.ACERR_UNSUPPORTED;
    a.first = h;
    const sys = stream.base.sys_base;
    const pool = sys.CreatePool(exec.MEMF_ANY | exec.MEMF_CLEAR, 32 * 1024, 8 * 1024) orelse return ac.ACERR_NOMEMORY;
    a.pool = pool;
    a.decoder = @ptrCast(setup.allocate(sys, pool, frame.Decoder, 1) orelse return ac.ACERR_NOMEMORY);
    a.synthesis = @ptrCast(setup.allocate(sys, pool, synthesis.Synthesis, 1) orelse return ac.ACERR_NOMEMORY);
    if (h.format != .be16) {
        a.unpacked = @ptrCast(setup.allocate(sys, pool, u8, header.MOST_BYTES) orelse return ac.ACERR_NOMEMORY);
    }
    reset(stream, a);
    stream.info.codec = ac.ACODEC_DTS;
    stream.info.rate = h.rate;
    stream.info.channels = if (h.mode == 0) 1 else 2;
    stream.info.bits = 16;
    const samples = @as(u64, h.blocks) * block_samples;
    stream.info.bitrate = @intCast(@as(u64, h.bytes) * 8 * h.rate / samples);
    return ac.ACERR_OK;
}

/// The decoder as at the start: nothing left of frames before.
fn reset(stream: *Stream, a: *Dts) void {
    stream.base.sys_base.SetMem(a.decoder, 0, @sizeOf(frame.Decoder));
    synthesis.clear(a.synthesis);
    a.left = 0;
}

pub fn free(stream: *Stream, a: *Dts) void {
    const sys = stream.base.sys_base;
    if (a.pool) |pool| sys.DeletePool(pool);
    a.pool = null;
}

/// Whether a frame is of the same stream as the first.
fn agrees(a: *const header.Header, b: *const header.Header) bool {
    return a.format == b.format and a.rate == b.rate;
}

/// The frame `bytes` holds made the one to decode. One that will not read
/// is decoded as silence.
fn startFrame(stream: *Stream, a: *Dts, h: *const header.Header, bytes: []const u8) void {
    var plain = bytes;
    if (a.unpacked) |into| {
        plain = into[0..header.unpack(h.format, bytes, into[0..header.MOST_BYTES])];
    }
    a.bits = .{ .bytes = plain };
    a.current = h.*;
    a.subframes = 0;
    a.left = h.blocks;
    a.broken = false;
    if (!h.decodable) return giveUp(stream, a);
    frame.begin(a.decoder, &a.bits, h) catch giveUp(stream, a);
}

/// The frame is silence from here, and the next begins afresh.
fn giveUp(stream: *Stream, a: *Dts) void {
    a.broken = true;
    stream.base.sys_base.SetMem(a.decoder, 0, @sizeOf(frame.Decoder));
    synthesis.clear(a.synthesis);
}

// --- raw frames -------------------------------------------------------------------

/// The stream's bytes made a stream of core frames.
pub fn open(stream: *Stream) i32 {
    _stream.fill(stream);
    const a = begin(stream) orelse return ac.ACERR_NOMEMORY;
    // The first frame the next one agrees with, within 64 KiB.
    const from = _stream.tell(stream);
    while (!framed(stream, null)) {
        if (_stream.available(stream).len < 16 or _stream.tell(stream) - from > 64 * 1024) {
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

    // The bytes a frame, from the frames read ahead, with what lies
    // between them.
    var at: usize = 0;
    var count: u32 = 0;
    while (at + 16 <= bytes.len) {
        const next = header.peek(bytes[at..]) orelse break;
        if (!agrees(&h, &next) or at + next.size > bytes.len) break;
        at += next.size;
        count += 1;
        while (at + 16 <= bytes.len and header.peek(bytes[at..]) == null) at += 1;
    }
    a.ahead_bytes = @intCast(at);
    a.ahead_frames = count;
    if (count != 0) {
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
/// with it, or an extension substream, or the bytes ending with it. A
/// frame so long the next cannot be seen is believed.
fn framed(stream: *Stream, first: ?*const header.Header) bool {
    var bytes = _stream.available(stream);
    const h = header.peek(bytes) orelse return false;
    if (first) |f| {
        if (!agrees(f, &h)) return false;
    }
    if (h.size + 16 > _stream.input_bytes) return true;
    if (h.size + 16 > bytes.len and !stream.eof) {
        _stream.fill(stream);
        bytes = _stream.available(stream);
    }
    if (h.size > bytes.len) return false;
    const after = bytes[h.size..];
    if (header.isExtension(after)) return true;
    if (after.len < 16) return stream.eof;
    const next = header.peek(after) orelse return false;
    return agrees(&h, &next);
}

/// The next frame in the stream's bytes, begun: false at the end. The
/// frame stays in the read-ahead until its last subframe.
fn nextRawFrame(stream: *Stream, a: *Dts) bool {
    while (true) {
        if (stream.stop - stream.start < 8192 and !stream.eof) _stream.fill(stream);
        var bytes = _stream.available(stream);
        if (bytes.len < 16) return false;
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
        if (h.size > bytes.len and !stream.eof) {
            _stream.fill(stream);
            bytes = _stream.available(stream);
        }
        if (h.size > bytes.len) {
            // A frame cut off at the end, or too long to hold.
            if (stream.eof) return false;
            _stream.consume(stream, 1);
            continue;
        }
        a.frame_bytes = h.size;
        startFrame(stream, a, &h, bytes[0..h.size]);
        return true;
    }
}

// --- a container's track --------------------------------------------------------

/// A track of a container (`_media.zig`): what it is by the first
/// packet's frame. A track whose packets hold no core has nothing for this
/// decoder.
pub fn openTrack(stream: *Stream, track: *const media.MediaTrack) i32 {
    _ = track;
    const a = begin(stream) orelse return ac.ACERR_NOMEMORY;
    const source = &stream.media;
    if (!source.holding or source.held.data == null) return ac.ACERR_UNSUPPORTED;
    const h = header.peek(source.held.data.?[0..source.held.size]) orelse return ac.ACERR_UNSUPPORTED;
    return prepare(stream, a, h);
}

/// The next frame in the track's packets, begun: false at the end. A
/// packet's frames are placed one after another from its time; what follows
/// a core frame and is not one is an extension's, and passed over.
fn nextPacketFrame(stream: *Stream, a: *Dts) bool {
    while (true) {
        if (a.rest.len == 0) {
            var packet: media.MediaPacket = .{};
            const bytes = _media.next(stream, &packet) orelse return false;
            a.at = _media.place(&stream.media, packet.ticks);
            _media.advance(&stream.media, samplesIn(a, bytes));
            a.rest = bytes;
            continue;
        }
        const h = header.peek(a.rest) orelse {
            a.rest = &.{};
            continue;
        };
        if (h.size > a.rest.len or h.format != a.first.format) {
            a.rest = &.{};
            continue;
        }
        const bytes = a.rest[0..h.size];
        a.rest = a.rest[h.size..];
        startFrame(stream, a, &h, bytes);
        return true;
    }
}

/// The samples a packet's frames hold.
fn samplesIn(a: *const Dts, bytes: []const u8) u32 {
    var rest = bytes;
    var samples: u32 = 0;
    while (header.peek(rest)) |h| {
        if (h.size > rest.len or h.format != a.first.format) break;
        samples += h.blocks * block_samples;
        rest = rest[h.size..];
    }
    return samples;
}

// --- decoding ---------------------------------------------------------------------

/// Up to `frames` frames into `out`: how many, 0 at the end.
pub fn decode(stream: *Stream, a: *Dts, out: [*]i16, frames: u32) i32 {
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

/// The next subframe decoded into the stream's samples, the frames passed
/// over and cut left out: false at the end.
fn decodeNext(stream: *Stream, a: *Dts) bool {
    const in_track = stream.media.base != null;
    while (true) {
        if (a.left == 0) {
            const found = if (in_track) nextPacketFrame(stream, a) else nextRawFrame(stream, a);
            if (!found) return false;
            continue;
        }
        var blocks: u32 = 0;
        if (!a.broken and a.subframes < a.decoder.subframes) {
            a.subframes += 1;
            blocks = frame.subframe(a.decoder, &a.bits) catch blk: {
                giveUp(stream, a);
                break :blk 0;
            };
        }
        // No subframe: the rest of the frame is silence, a subframe at most.
        const heard = blocks != 0;
        if (!heard) blocks = @min(a.left, frame.SUBFRAME_BLOCKS);
        const count = blocks * block_samples;
        if (heard) {
            const d = a.decoder;
            for (0..d.channels) |ch| synthesis.channel(a.synthesis, d, ch, blocks);
            synthesis.undoSums(a.synthesis, d, a.current.mode, count);
        }
        const start: i64 = if (in_track) a.at else a.position;
        if (in_track) a.at += count else a.position += count;
        a.left -= blocks;
        if (!in_track and a.left == 0) _stream.consume(stream, a.frame_bytes);

        var first: u32 = 0;
        var last: u32 = count;
        if (in_track) {
            const span = _media.window(&stream.media, start, count, a.left * block_samples) orelse continue;
            first = span.first;
            last = span.last;
        } else {
            const passed = @max(0, a.skip_until - start);
            if (passed >= count) continue;
            first = @intCast(passed);
        }
        const channels: usize = stream.info.channels;
        if (heard) {
            synthesis.samples(a.synthesis, a.current.mode, a.decoder.channels, channels, first, last, &stream.pcm);
        } else {
            @memset(stream.pcm[0 .. (last - first) * channels], 0);
        }
        stream.pcm_start = 0;
        stream.pcm_stop = (last - first) * channels;
        return true;
    }
}

// --- seeking ----------------------------------------------------------------------

/// The stream moved to `frame`: exactly in a container, near it by the
/// bytes a frame in raw frames - early, what comes before `frame` only
/// filling the filter and the predictors.
pub fn seek(stream: *Stream, a: *Dts, to: u32) i32 {
    stream.pcm_start = 0;
    stream.pcm_stop = 0;
    const frame_samples: u32 = a.first.blocks * block_samples;
    const early_samples = @max(frame_samples, seek_early);
    if (stream.media.base != null) {
        const result = _media.seek(stream, to, early_samples);
        if (result != ac.ACERR_OK) return result;
        reset(stream, a);
        a.rest = &.{};
        return ac.ACERR_OK;
    }
    if (stream.file == null) return ac.ACERR_NOSEEK;
    // Near the start, the start as it was.
    const early = to >= early_samples;
    const index: u64 = if (early) (to - early_samples) / frame_samples else 0;
    var offset: u64 = 0;
    if (a.ahead_frames != 0) offset = index * a.ahead_bytes / a.ahead_frames;
    if (stream.has_end and stream.end > a.first_frame) offset = @min(offset, stream.end - a.first_frame);
    if (!_stream.seekSource(stream, a.first_frame + offset)) return ac.ACERR_NOSEEK;
    reset(stream, a);
    a.resync = early;
    a.position = @intCast(index * frame_samples);
    a.skip_until = to;
    return ac.ACERR_OK;
}
