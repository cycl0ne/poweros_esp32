// SPDX-License-Identifier: MIT
//! MP3 as a stream: the tags in front of the sound, the first frame, what
//! its encoder wrote about the rest, and the frames decoded as the program
//! asks for samples. The frames themselves are `layer3.zig`'s.
//!
//! **Tags**: ID3v2 at the front - the title, artist and album taken from
//! its text frames, the rest (a cover picture, often hundreds of
//! kilobytes) passed over - and ID3v1 at a file's end (`_stream.scanTail`),
//! which counts only where the front says nothing.
//!
//! **The first frame** may be a Xing or Info frame: an encoder's word on
//! the rest - how many frames, how many bytes, a table of where each
//! hundredth of the sound begins, and the samples it put before the music
//! and after it. It is no music itself, and is passed over. With it the
//! length is exact, the samples before and after the music are left out
//! (one song runs into the next without a gap), and a seek lands where the
//! table says. Without it the length is worked out from the bit rate and
//! the file's size, and a seek from the bit rate - exact for a constant
//! rate, near for a variable one.
//!
//! A frame of one channel in a stream of two is handed out on both, and
//! the other way round both sides together; layers I and II are refused
//! when the stream is opened.

const sdk = @import("sdk");
const ac = sdk.audiocodec;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;
const layer3 = @import("layer3.zig");

pub const Mp3 = struct {
    dec: layer3.Decoder,
    scratch: layer3.Scratch,
    /// Where the first frame of music is in the source.
    first_frame: u64,
    /// Samples a channel each frame holds.
    frame_samples: u32,
    /// From the Xing or Info frame: the frames there are, the bytes they
    /// take and the table of where each hundredth begins.
    tagged_frames: u32,
    music_bytes: u32,
    toc: [100]u8,
    has_toc: bool,
    /// The frames of music there are, when the encoder said - the end is
    /// then cut there - and how many have been handed out.
    exact: bool,
    total: u32,
    given: u32,
    /// Frames to leave out at the start, still to go.
    to_skip: u32,
};

/// The tags passed, the first frame found and the encoder's word read:
/// the info filled in and the stream at the first frame of music.
pub fn open(stream: *Stream) i32 {
    _stream.fill(stream);
    skipId3v2(stream);
    if (stream.stop - stream.start < _stream.input_bytes / 2) _stream.fill(stream);

    stream.codec = .{ .mp3 = undefined };
    const m = &stream.codec.mp3;
    // The stream came cleared; what the union put there is set again.
    m.dec = .{};
    m.first_frame = 0;
    m.frame_samples = 0;
    m.tagged_frames = 0;
    m.music_bytes = 0;
    m.has_toc = false;
    m.exact = false;
    m.total = 0;
    m.given = 0;
    m.to_skip = 0;

    // The first frame: found, but not decoded.
    var info: layer3.FrameInfo = .{};
    while (true) {
        const bytes = _stream.available(stream);
        if (bytes.len < 4) return if (stream.failed) ac.ACERR_READ else ac.ACERR_UNKNOWN;
        const samples = layer3.decodeFrame(&m.dec, &m.scratch, bytes, null, &info);
        if (samples != 0) break;
        if (stream.eof) return ac.ACERR_UNKNOWN;
        // Nothing in what is here: all but its tail passed over, the tail
        // kept to be looked at with what follows.
        const keep: usize = @min(bytes.len, layer3.max_frame_bytes);
        _stream.consume(stream, bytes.len - keep);
        _stream.fill(stream);
    }
    _stream.consume(stream, info.frame_offset);
    if (info.layer != 3) return ac.ACERR_UNSUPPORTED;

    const frame_len = info.frame_bytes - info.frame_offset;
    m.frame_samples = frameSamplesOf(_stream.available(stream));
    stream.info.codec = ac.ACODEC_MP3;
    stream.info.rate = info.hz;
    stream.info.channels = info.channels;
    stream.info.bits = 16;
    stream.info.bitrate = info.bitrate_kbps * 1000;

    m.first_frame = _stream.tell(stream);
    if (layer3.vbrTag(_stream.available(stream)[0..frame_len])) |tag| {
        _stream.consume(stream, frame_len);
        m.first_frame = _stream.tell(stream);
        m.dec.reset();
        if (tag.frames != 0) {
            const all = @as(u64, tag.frames) * m.frame_samples;
            const cut = @as(u64, tag.delay) + tag.padding;
            m.exact = true;
            m.total = @intCast(@min(all -| cut, 0xFFFF_FFFF));
            m.to_skip = tag.delay;
            m.tagged_frames = tag.frames;
            if (tag.bytes != 0 and tag.frames != 0) {
                m.music_bytes = tag.bytes;
                stream.info.bitrate = @intCast(@min(@as(u64, tag.bytes) * 8 * info.hz / (@as(u64, tag.frames) * m.frame_samples), 0xFFFF_FFFF));
            }
            if (tag.toc) |toc| {
                m.toc = toc;
                m.has_toc = true;
            }
        }
    }
    if (m.exact) {
        stream.info.frames = m.total;
    } else if (stream.has_end and stream.end > m.first_frame and info.bitrate_kbps != 0) {
        // The length by the bit rate: what the music's bytes come to.
        const bytes = stream.end - m.first_frame;
        stream.info.frames = @intCast(@min(bytes * 8 * info.hz / (@as(u64, info.bitrate_kbps) * 1000), 0xFFFF_FFFF));
    }
    if (m.music_bytes == 0 and stream.has_end and stream.end > m.first_frame) {
        m.music_bytes = @intCast(@min(stream.end - m.first_frame, 0xFFFF_FFFF));
    }
    return ac.ACERR_OK;
}

fn frameSamplesOf(frame: []const u8) u32 {
    if (frame.len < 4) return 1152;
    return layer3.headerFrameSamples(frame.ptr);
}

/// Up to `frames` frames into `out`: how many, 0 at the end.
pub fn decode(stream: *Stream, m: *Mp3, out: [*]i16, frames: u32) i32 {
    const channels: usize = stream.info.channels;
    var done: u32 = 0;
    while (done < frames) {
        if (stream.pcm_start == stream.pcm_stop) {
            if (!decodeNext(stream, m)) break;
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

/// The next frame of music decoded into the stream's samples: false at
/// the end.
fn decodeNext(stream: *Stream, m: *Mp3) bool {
    const channels: usize = stream.info.channels;
    while (true) {
        if (m.exact and m.given >= m.total) return false;
        // A whole frame and the header after it, unless the source ends.
        if (stream.stop - stream.start < 2 * layer3.max_frame_bytes + 4 and !stream.eof) _stream.fill(stream);
        const bytes = _stream.available(stream);
        if (bytes.len == 0) return false;
        var info: layer3.FrameInfo = .{};
        const samples = layer3.decodeFrame(&m.dec, &m.scratch, bytes, &stream.pcm, &info);
        if (info.channels == 0) {
            // No frame in what is here.
            if (stream.eof) return false;
            const keep: usize = @min(bytes.len, layer3.max_frame_bytes);
            _stream.consume(stream, bytes.len - keep);
            const before = stream.stop - stream.start;
            _stream.fill(stream);
            if (stream.stop - stream.start == before) return false;
            continue;
        }
        _stream.consume(stream, info.frame_bytes);
        // Passed-over bytes, a layer it does not decode, or a frame whose
        // reservoir is not there yet: nothing to hand out.
        if (samples == 0) continue;
        if (info.channels != channels) toChannels(stream, samples, info.channels);

        var first: u32 = 0;
        var count: u32 = samples;
        if (m.to_skip != 0) {
            const drop = @min(m.to_skip, count);
            first = drop;
            count -= drop;
            m.to_skip -= drop;
        }
        if (m.exact) count = @min(count, m.total - m.given);
        m.given += count;
        stream.pcm_start = first * channels;
        stream.pcm_stop = (first + count) * channels;
        if (count != 0) return true;
    }
}

/// A frame of the other number of channels made into the stream's: one
/// channel onto both sides, or both sides together onto one.
fn toChannels(stream: *Stream, samples: u32, from: u32) void {
    const pcm = &stream.pcm;
    if (from == 1) {
        var i: usize = samples;
        while (i > 0) {
            i -= 1;
            pcm[i * 2] = pcm[i];
            pcm[i * 2 + 1] = pcm[i];
        }
    } else {
        for (0..samples) |i| {
            const sum = @as(i32, pcm[i * 2]) + pcm[i * 2 + 1];
            pcm[i] = @intCast(@divTrunc(sum, 2));
        }
    }
}

/// The stream moved to near `frame`: by the encoder's table where there
/// is one, else by the bit rate. The frames just after it may be left
/// out, until the reservoir they reach back into is filled again.
pub fn seek(stream: *Stream, m: *Mp3, frame: u32) i32 {
    if (stream.file == null) return ac.ACERR_NOSEEK;
    var offset: u64 = 0;
    if (m.has_toc and m.exact and m.total != 0 and m.music_bytes != 0) {
        const at = @as(f32, @floatFromInt(@min(frame, m.total))) * 100.0 / @as(f32, @floatFromInt(m.total));
        const index: usize = @intFromFloat(@min(at, 99.0));
        const low: f32 = @floatFromInt(m.toc[index]);
        const high: f32 = if (index < 99) @floatFromInt(m.toc[index + 1]) else 256.0;
        const part = low + (high - low) * (at - @as(f32, @floatFromInt(index)));
        offset = @intFromFloat(part / 256.0 * @as(f32, @floatFromInt(m.music_bytes)));
    } else if (stream.info.bitrate != 0 and stream.info.rate != 0) {
        offset = @as(u64, frame) * stream.info.bitrate / 8 / stream.info.rate;
    }
    if (m.music_bytes != 0) offset = @min(offset, m.music_bytes);
    if (!_stream.seekSource(stream, m.first_frame + offset)) return ac.ACERR_NOSEEK;
    m.dec.reset();
    m.to_skip = 0;
    m.given = @min(frame, if (m.exact) m.total else frame);
    stream.pcm_start = 0;
    stream.pcm_stop = 0;
    return ac.ACERR_OK;
}

// --- ID3 --------------------------------------------------------------------------

/// Every ID3v2 tag at the front: its names into the info, the tag passed
/// over.
fn skipId3v2(stream: *Stream) void {
    while (true) {
        const bytes = _stream.available(stream);
        if (bytes.len < 10 or !_stream.same(bytes, "ID3")) return;
        if (bytes[6] & 0x80 != 0 or bytes[7] & 0x80 != 0 or bytes[8] & 0x80 != 0 or bytes[9] & 0x80 != 0) return;
        var size: u64 = syncsafe(bytes[6..10]) + 10;
        if (bytes[5] & 0x10 != 0) size += 10; // a footer
        id3v2(bytes[0..@intCast(@min(size, bytes.len))], &stream.info);
        _stream.skip(stream, size);
        if (stream.stop - stream.start < _stream.input_bytes / 2) _stream.fill(stream);
    }
}

fn syncsafe(bytes: []const u8) u32 {
    return @as(u32, bytes[0] & 0x7f) << 21 | @as(u32, bytes[1] & 0x7f) << 14 | @as(u32, bytes[2] & 0x7f) << 7 | (bytes[3] & 0x7f);
}

/// An ID3v2 tag's title, artist and album - TIT2, TPE1 and TALB (TT2, TP1
/// and TAL in version 2) - from as much of the tag as `tag` holds.
pub fn id3v2(tag: []const u8, info: *ac.AudioStreamInfo) void {
    const version = tag[3];
    if (version < 2 or version > 4) return;
    var at: usize = 10;
    // An extended header in version 3 or 4 is passed over.
    if (tag[5] & 0x40 != 0 and version >= 3 and tag.len >= 14) {
        const extended = if (version == 4) syncsafe(tag[10..14]) else be32(tag[10..14]) + 4;
        at += extended;
    }
    const id_len: usize = if (version == 2) 3 else 4;
    const head_len: usize = if (version == 2) 6 else 10;
    while (at + head_len <= tag.len) {
        const id = tag[at .. at + id_len];
        if (id[0] == 0) return; // padding
        const size: usize = if (version == 2)
            @as(usize, tag[at + 3]) << 16 | @as(usize, tag[at + 4]) << 8 | tag[at + 5]
        else if (version == 4)
            syncsafe(tag[at + 4 .. at + 8])
        else
            be32(tag[at + 4 .. at + 8]);
        const body_start = at + head_len;
        if (body_start + size > tag.len) return;
        const body = tag[body_start .. body_start + size];
        if (_stream.same(id, "TIT2") or _stream.same(id, "TT2")) text(&info.title, body);
        if (_stream.same(id, "TPE1") or _stream.same(id, "TP1")) text(&info.artist, body);
        if (_stream.same(id, "TALB") or _stream.same(id, "TAL")) text(&info.album, body);
        at = body_start + size;
    }
}

fn be32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
}

/// A text frame's words into a name, Latin-1: its encoding byte says
/// whether they are Latin-1 (0), UTF-16 with a byte-order mark (1),
/// UTF-16 big-endian (2) or UTF-8 (3). A character past Latin-1 is a `?`.
fn text(into: *[64]u8, body: []const u8) void {
    if (body.len < 1) return;
    var out: usize = 0;
    const words = body[1..];
    switch (body[0]) {
        1, 2 => {
            var big = body[0] == 2;
            var i: usize = 0;
            if (body[0] == 1 and words.len >= 2) {
                big = words[0] == 0xFE and words[1] == 0xFF;
                i = 2;
            }
            while (i + 1 < words.len and out < into.len - 1) : (i += 2) {
                const unit: u16 = if (big) @as(u16, words[i]) << 8 | words[i + 1] else @as(u16, words[i + 1]) << 8 | words[i];
                if (unit == 0) break;
                into[out] = if (unit < 0x100) @intCast(unit) else '?';
                out += 1;
            }
        },
        3 => {
            var i: usize = 0;
            while (i < words.len and out < into.len - 1) {
                const lead = words[i];
                if (lead == 0) break;
                var point: u32 = lead;
                var length: usize = 1;
                if (lead >= 0xC0 and lead < 0xE0 and i + 1 < words.len) {
                    point = (@as(u32, lead & 0x1F) << 6) | (words[i + 1] & 0x3F);
                    length = 2;
                } else if (lead >= 0xE0 and lead < 0xF0) {
                    length = 3;
                    point = 0x10000;
                } else if (lead >= 0xF0) {
                    length = 4;
                    point = 0x10000;
                }
                into[out] = if (point < 0x100) @intCast(point) else '?';
                out += 1;
                i += length;
            }
        },
        else => {
            for (words) |char| {
                if (char == 0 or out == into.len - 1) break;
                into[out] = char;
                out += 1;
            }
        },
    }
    while (out > 0 and into[out - 1] == ' ') out -= 1;
    into[out] = 0;
}

/// An ID3v1 tag's title, artist and album: thirty characters each,
/// Latin-1, filled out with blanks or NULs.
pub fn id3v1(tag: *const [128]u8, info: *ac.AudioStreamInfo) void {
    _stream.copyName(&info.title, tag[3..33]);
    _stream.copyName(&info.artist, tag[33..63]);
    _stream.copyName(&info.album, tag[63..93]);
}
