// SPDX-License-Identifier: MIT
//! WAV: a RIFF file of chunks - `fmt ` says what the samples are, `data`
//! holds them, a `LIST` of `INFO` names the sound - its title, artist,
//! album, year, genre, comment and track - read front to back.
//!
//! The samples are PCM of 8 bits (unsigned), 16, 24 or 32 (signed), or
//! 32-bit float, one channel or two, as a format tag of 1 or 3 says, or
//! the extensible form's sub-format. Each is handed out at 16 bits: the
//! top 16 of a wider sample, an 8-bit one moved up, a float scaled and
//! held at its ends.
//!
//! A chunk too large for the read-ahead - a long `JUNK` or `LIST` before
//! the data - is passed over by seeking or reading through it. The names
//! are taken from a `LIST` before the data; one after it is not looked
//! for.

const sdk = @import("sdk");
const ac = sdk.audiocodec;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;

const format_pcm: u16 = 1;
const format_float: u16 = 3;
const format_extensible: u16 = 0xFFFE;

pub const Wav = struct {
    float: bool,
    bits: u16,
    channels: u16,
    /// Bytes a frame: a sample a channel.
    block_align: u16,
    /// Where the samples begin in the source, how many bytes they are, and
    /// how many of them are still to come.
    data_start: u64,
    data_bytes: u64,
    data_left: u64,
};

/// The header read, to the first sample: the info filled in and the
/// stream left at the data. ACERR_* for a file it cannot be.
pub fn open(stream: *Stream) i32 {
    _stream.fill(stream);
    const head = _stream.available(stream);
    if (head.len < 12 or !_stream.same(head, "RIFF") or !_stream.same(head[8..], "WAVE")) return ac.ACERR_CORRUPT;
    _stream.consume(stream, 12);

    var have_format = false;
    var wav: Wav = .{ .float = false, .bits = 0, .channels = 0, .block_align = 0, .data_start = 0, .data_bytes = 0, .data_left = 0 };
    while (true) {
        if (stream.stop - stream.start < 8) _stream.fill(stream);
        const chunk = _stream.available(stream);
        if (chunk.len < 8) return if (stream.failed) ac.ACERR_READ else ac.ACERR_CORRUPT;
        const size: u64 = _stream.le32(chunk[4..8]);
        const padded = size + (size & 1);
        if (_stream.same(chunk, "data")) {
            if (!have_format) return ac.ACERR_CORRUPT;
            _stream.consume(stream, 8);
            wav.data_start = _stream.tell(stream);
            // A size of nothing, or all ones, is a file written as it was
            // recorded: the data goes to the end.
            wav.data_bytes = if (size == 0 or size == 0xFFFF_FFFF) 0xFFFF_FFFF_FFFF else size;
            if (stream.has_end and stream.end > wav.data_start) wav.data_bytes = @min(wav.data_bytes, stream.end - wav.data_start);
            wav.data_left = wav.data_bytes;
            break;
        }
        if (_stream.same(chunk, "fmt ")) {
            if (size < 16) return ac.ACERR_CORRUPT;
            if (chunk.len < 8 + 26) {
                _stream.fill(stream);
            }
            const body = _stream.available(stream)[8..];
            if (body.len < 16) return ac.ACERR_CORRUPT;
            var tag = _stream.le16(body[0..2]);
            if (tag == format_extensible and size >= 26 and body.len >= 26) tag = _stream.le16(body[24..26]);
            wav.channels = _stream.le16(body[2..4]);
            const rate = _stream.le32(body[4..8]);
            wav.block_align = _stream.le16(body[12..14]);
            wav.bits = _stream.le16(body[14..16]);
            wav.float = tag == format_float;
            if (tag != format_pcm and tag != format_float) return ac.ACERR_UNSUPPORTED;
            if (wav.channels < 1 or wav.channels > 2) return ac.ACERR_UNSUPPORTED;
            const supported = if (wav.float) wav.bits == 32 else (wav.bits == 8 or wav.bits == 16 or wav.bits == 24 or wav.bits == 32);
            if (!supported) return ac.ACERR_UNSUPPORTED;
            if (wav.block_align != wav.channels * (wav.bits / 8) or rate == 0) return ac.ACERR_CORRUPT;
            stream.info.rate = rate;
            stream.info.channels = wav.channels;
            stream.info.bits = wav.bits;
            have_format = true;
        } else if (_stream.same(chunk, "LIST") and chunk.len >= 12 and _stream.same(chunk[8..], "INFO")) {
            if (chunk.len < 8 + padded) _stream.fill(stream);
            const list = _stream.available(stream);
            if (list.len >= 8 + padded) names(list[12..@intCast(8 + size)], &stream.tags);
        }
        _stream.skip(stream, 8 + padded);
    }

    stream.info.codec = ac.ACODEC_WAV;
    stream.info.frames = @intCast(@min(wav.data_bytes / wav.block_align, 0xFFFF_FFFF));
    stream.info.bitrate = stream.info.rate * wav.block_align * 8;
    stream.codec = .{ .wav = wav };
    return ac.ACERR_OK;
}

/// The INFO list's names: INAM the title, IART the artist, IPRD the
/// album, ICRD the date (its year), IGNR the genre, ICMT a comment, ITRK
/// or IPRT the track.
fn names(list: []const u8, tags: *_stream.Tags) void {
    var at: usize = 0;
    while (at + 8 <= list.len) {
        const size: usize = _stream.le32(list[at + 4 .. at + 8]);
        const body_end = @min(at + 8 + size, list.len);
        const body = list[at + 8 .. body_end];
        const id = list[at..];
        if (_stream.same(id, "INAM")) _stream.copyName(&tags.title, body);
        if (_stream.same(id, "IART")) _stream.copyName(&tags.artist, body);
        if (_stream.same(id, "IPRD")) _stream.copyName(&tags.album, body);
        if (_stream.same(id, "IGNR")) _stream.copyName(&tags.genre, body);
        if (_stream.same(id, "ICMT")) {
            _stream.copyName(&tags.comment, body);
            tags.plain_comment = true;
        }
        if (_stream.same(id, "ICRD")) tags.year = _stream.yearOf(body);
        if (_stream.same(id, "ITRK") or _stream.same(id, "IPRT")) _stream.trackOf(body, &tags.track, &tags.tracks);
        at += 8 + size + (size & 1);
    }
}

/// Up to `frames` frames into `out` at 16 bits: how many.
pub fn decode(stream: *Stream, wav: *Wav, out: [*]i16, frames: u32) i32 {
    const block: usize = wav.block_align;
    var done: u32 = 0;
    while (done < frames and wav.data_left >= block) {
        if (stream.stop - stream.start < block) _stream.fill(stream);
        const bytes = _stream.available(stream);
        var count: usize = @min(bytes.len / block, frames - done);
        count = @intCast(@min(@as(u64, count), wav.data_left / block));
        if (count == 0) break;
        const samples = count * wav.channels;
        const into = out + @as(usize, done) * wav.channels;
        convert(bytes[0 .. count * block], into[0..samples], wav);
        _stream.consume(stream, count * block);
        wav.data_left -= count * block;
        done += @intCast(count);
    }
    if (done == 0 and stream.failed) return ac.ACERR_READ;
    return @intCast(done);
}

/// Samples of the file's form to 16 bits.
fn convert(bytes: []const u8, out: []i16, wav: *const Wav) void {
    switch (wav.bits) {
        8 => for (out, 0..) |*sample, i| {
            sample.* = (@as(i16, bytes[i]) - 128) << 8;
        },
        16 => for (out, 0..) |*sample, i| {
            sample.* = @bitCast(_stream.le16(bytes[i * 2 ..]));
        },
        24 => for (out, 0..) |*sample, i| {
            sample.* = @bitCast(@as(u16, bytes[i * 3 + 1]) | @as(u16, bytes[i * 3 + 2]) << 8);
        },
        else => for (out, 0..) |*sample, i| {
            const word = _stream.le32(bytes[i * 4 ..]);
            if (wav.float) {
                const value: f32 = @bitCast(word);
                const scaled = value * 32768.0;
                sample.* = if (scaled >= 32767.0) 32767 else if (scaled <= -32768.0) -32768 else @intFromFloat(scaled);
            } else {
                sample.* = @truncate(@as(i32, @bitCast(word)) >> 16);
            }
        },
    }
}

/// The stream at frame `frame`, exactly.
pub fn seek(stream: *Stream, wav: *Wav, frame: u32) i32 {
    const offset = @as(u64, frame) * wav.block_align;
    if (offset > wav.data_bytes) return ac.ACERR_CORRUPT;
    if (!_stream.seekSource(stream, wav.data_start + offset)) return ac.ACERR_NOSEEK;
    wav.data_left = wav.data_bytes - offset;
    return ac.ACERR_OK;
}
