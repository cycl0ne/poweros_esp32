// SPDX-License-Identifier: MIT
//! MP3 as a stream: the tags in front of the sound, the first frame, what
//! its encoder wrote about the rest, and the frames decoded as the program
//! asks for samples. The frames themselves are `layer3.zig`'s.
//!
//! **Tags**: ID3v2 at the front, read frame by frame - the names, the
//! year, the track, the genre and a comment taken from its frames, a
//! picture kept when the program asked for one and passed over otherwise
//! (a cover is often hundreds of kilobytes) - and ID3v1 at a file's end
//! (`_stream.scanTail`), which counts only where the front says nothing.
//!
//! **The first frame** may be a Xing or Info frame: an encoder's word on
//! the rest - how many frames, how many bytes, a table of where each
//! hundredth of the sound begins, and the samples it put before the music
//! and after it. It is no music itself, and is passed over. With it the
//! length is exact, the samples before and after the music are left out
//! (one song runs into the next without a gap), and a seek lands where the
//! table says - a seek to the start on the music's first sample. Without it the length is worked out from the bit rate and
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
const genres = @import("genres.zig");
const exec = sdk.exec;

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
    /// The frames the encoder put before the music, and those of them
    /// still to leave out.
    delay: u32,
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
    m.delay = 0;
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
            m.delay = tag.delay;
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
/// out, until the reservoir they reach back into is filled again. Frame
/// 0 is the first frame of music, the encoder's delay left out again.
pub fn seek(stream: *Stream, m: *Mp3, frame: u32) i32 {
    if (stream.file == null) return ac.ACERR_NOSEEK;
    var offset: u64 = 0;
    if (frame == 0) {
        offset = 0;
    } else if (m.has_toc and m.exact and m.total != 0 and m.music_bytes != 0) {
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
    m.to_skip = if (frame == 0) m.delay else 0;
    m.given = @min(frame, if (m.exact) m.total else frame);
    stream.pcm_start = 0;
    stream.pcm_stop = 0;
    return ac.ACERR_OK;
}

// --- ID3 --------------------------------------------------------------------------

/// The bytes of one ID3v2 tag, from the stream: `left` of them still in
/// the tag as it is stored. A tag unsynchronised as a whole (versions 2
/// and 3) has a 0 after every 0xFF, which is taken out again as the bytes
/// are read.
const TagReader = struct {
    stream: *Stream,
    left: u64,
    unsync: bool,
    after_ff: bool = false,

    /// Up to `into.len` bytes of the tag: how many there were.
    fn read(reader: *TagReader, into: []u8) usize {
        const stream = reader.stream;
        var done: usize = 0;
        while (done < into.len and reader.left > 0) {
            if (stream.stop == stream.start) {
                _stream.fill(stream);
                if (stream.stop == stream.start) break;
            }
            const here = _stream.available(stream);
            if (!reader.unsync) {
                const count: usize = @intCast(@min(@as(u64, @min(here.len, into.len - done)), reader.left));
                @memcpy(into[done..][0..count], here[0..count]);
                _stream.consume(stream, count);
                reader.left -= count;
                done += count;
                continue;
            }
            const byte = here[0];
            _stream.consume(stream, 1);
            reader.left -= 1;
            const inserted = reader.after_ff and byte == 0;
            reader.after_ff = byte == 0xFF;
            if (inserted) continue;
            into[done] = byte;
            done += 1;
        }
        return done;
    }

    /// `count` bytes of the tag passed over.
    fn skip(reader: *TagReader, count: u64) void {
        if (!reader.unsync) {
            const passed = @min(count, reader.left);
            _stream.skip(reader.stream, passed);
            reader.left -= passed;
            return;
        }
        var scratch: [256]u8 = undefined;
        var left = count;
        while (left > 0) {
            const got = reader.read(scratch[0..@intCast(@min(left, scratch.len))]);
            if (got == 0) return;
            left -= got;
        }
    }

    /// One byte of the tag, or null at its end.
    fn next(reader: *TagReader) ?u8 {
        var one: [1]u8 = undefined;
        return if (reader.read(&one) == 1) one[0] else null;
    }
};

/// Every ID3v2 tag at the front, read frame by frame through the stream
/// - so a tag of any size is read whole, the frames after a large picture
/// too: its texts into the stream's tags, its picture kept when the
/// stream keeps one, the rest passed over.
pub fn skipId3v2(stream: *Stream) void {
    while (true) {
        if (stream.stop - stream.start < 10) _stream.fill(stream);
        const bytes = _stream.available(stream);
        if (bytes.len < 10 or !_stream.same(bytes, "ID3")) return;
        if (bytes[6] & 0x80 != 0 or bytes[7] & 0x80 != 0 or bytes[8] & 0x80 != 0 or bytes[9] & 0x80 != 0) return;
        const version = bytes[3];
        const flags = bytes[5];
        const size: u64 = syncsafe(bytes[6..10]);
        const footer: u64 = if (flags & 0x10 != 0) 10 else 0;
        _stream.consume(stream, 10);
        var reader = TagReader{ .stream = stream, .left = size, .unsync = flags & 0x80 != 0 and version < 4 };
        if (version >= 2 and version <= 4) tagFrames(&reader, version, flags);
        // What is left - padding - passed over as it lies.
        reader.unsync = false;
        reader.skip(reader.left);
        _stream.skip(stream, footer);
    }
}

fn syncsafe(bytes: []const u8) u32 {
    return @as(u32, bytes[0] & 0x7f) << 21 | @as(u32, bytes[1] & 0x7f) << 14 | @as(u32, bytes[2] & 0x7f) << 7 | (bytes[3] & 0x7f);
}

fn be32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
}

/// What a frame is, of those read.
const Kind = enum { none, title, artist, album, album_artist, composer, genre, year, track, comment, picture, chapter };

/// A frame's kind by its name: version 2's three letters, or the four of
/// versions 3 and 4.
fn kindOf(id: []const u8) Kind {
    const known = [_]struct { []const u8, []const u8, Kind }{
        .{ "TIT2", "TT2", .title },
        .{ "TPE1", "TP1", .artist },
        .{ "TALB", "TAL", .album },
        .{ "TPE2", "TP2", .album_artist },
        .{ "TCOM", "TCM", .composer },
        .{ "TCON", "TCO", .genre },
        .{ "TYER", "TYE", .year },
        .{ "TDRC", "TDA", .year },
        .{ "TRCK", "TRK", .track },
        .{ "COMM", "COM", .comment },
        .{ "APIC", "PIC", .picture },
        // Version 2 has no chapters: no three letters are theirs.
        .{ "CHAP", "", .chapter },
    };
    for (known) |entry| {
        const name = if (id.len == 3) entry[1] else entry[0];
        if (id.len == name.len and eql(id, name)) return entry[2];
    }
    return .none;
}

fn eql(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

/// A tag's frames, one after the other, after its extended header.
fn tagFrames(reader: *TagReader, version: u8, flags: u8) void {
    if (flags & 0x40 != 0 and version >= 3) {
        var head: [4]u8 = undefined;
        if (reader.read(&head) != head.len) return;
        // Version 4 counts these four bytes in the size, version 3 does not.
        reader.skip(if (version == 4) @as(u64, syncsafe(&head)) -| 4 else be32(&head));
    }
    const id_len: usize = if (version == 2) 3 else 4;
    const head_len: usize = if (version == 2) 6 else 10;
    while (reader.left >= head_len) {
        var head: [10]u8 = undefined;
        if (reader.read(head[0..head_len]) != head_len) return;
        if (head[0] == 0) return; // padding
        const size: u64 = if (version == 2)
            @as(u64, head[3]) << 16 | @as(u64, head[4]) << 8 | head[5]
        else if (version == 4)
            syncsafe(head[4..8])
        else
            be32(head[4..8]);
        if (size > reader.left) return;
        tagFrame(reader, version, kindOf(head[0..id_len]), size, if (version == 2) 0 else head[9]);
    }
}

/// One frame of `size` bytes, its header read: what is in it taken, or
/// it passed over. `format` is the header's second flag byte.
fn tagFrame(reader: *TagReader, version: u8, kind: Kind, size: u64, format: u8) void {
    // A compressed or encrypted frame is passed over; a group's byte and
    // version 4's length of the frame before it was unsynchronised come
    // before the body.
    var before: u64 = 0;
    var unsync = false;
    var unreadable = false;
    if (version == 3) {
        unreadable = format & 0xC0 != 0;
        if (format & 0x20 != 0) before += 1;
    } else if (version == 4) {
        unreadable = format & 0x0C != 0;
        if (format & 0x40 != 0) before += 1;
        if (format & 0x01 != 0) before += 4;
        unsync = format & 0x02 != 0;
    }
    if (kind == .none or unreadable or before > size) {
        reader.skip(size);
        return;
    }
    reader.skip(before);
    const body_size = size - before;
    const tags = &reader.stream.tags;
    if (kind == .picture) {
        if (tags.keep_picture) picture(reader, version, body_size, unsync) else reader.skip(body_size);
        return;
    }
    if (body_size > tags.frame_text.len) {
        reader.skip(body_size);
        return;
    }
    const length = reader.read(tags.frame_text[0..@intCast(body_size)]);
    const body = if (unsync) resync(tags.frame_text[0..length]) else tags.frame_text[0..length];
    var short: [64]u8 = undefined;
    switch (kind) {
        .title => text(&tags.title, body),
        .artist => text(&tags.artist, body),
        .album => text(&tags.album, body),
        .album_artist => text(&tags.album_artist, body),
        .composer => text(&tags.composer, body),
        .genre => {
            text(&short, body);
            genre(&tags.genre, &short);
        },
        .year => {
            text(&short, body);
            const year = _stream.yearOf(&short);
            if (year != 0) tags.year = year;
        },
        .track => {
            text(&short, body);
            _stream.trackOf(&short, &tags.track, &tags.tracks);
        },
        .comment => comment(tags, body),
        .chapter => chapter(reader.stream, version, body),
        .none, .picture => {},
    }
}

/// Bytes unsynchronised one by one taken back in place: the 0 after each
/// 0xFF out. What is left.
fn resync(bytes: []u8) []u8 {
    var out: usize = 0;
    var after_ff = false;
    for (bytes) |b| {
        const inserted = after_ff and b == 0;
        after_ff = b == 0xFF;
        if (inserted) continue;
        bytes[out] = b;
        out += 1;
    }
    return bytes[0..out];
}

/// A genre: `(17)`, `17` or `(17)Rock` - an ID3v1 number, with words of
/// its own after it that say more - or the name as it is.
fn genre(into: *[64]u8, given: *const [64]u8) void {
    const words = _stream.upToNul(given);
    if (words.len == 0) return;
    var at: usize = 0;
    const bracketed = words[0] == '(';
    if (bracketed) at = 1;
    var number: u32 = 0;
    const first_digit = at;
    while (at < words.len and words[at] >= '0' and words[at] <= '9') : (at += 1) number = number *| 10 +| (words[at] - '0');
    const has_number = at > first_digit;
    if (has_number and bracketed and at < words.len and words[at] == ')') {
        const rest = words[at + 1 ..];
        if (rest.len > 0) return _stream.copyName(into, rest);
        if (genres.named(number)) |name| return _stream.copyName(into, _stream.upToNul(name));
    } else if (has_number and !bracketed and at == words.len) {
        if (genres.named(number)) |name| return _stream.copyName(into, _stream.upToNul(name));
    }
    _stream.copyName(into, words);
}

/// A comment: its language and description, then its words. One with no
/// description is kept over one with; one a program wrote for itself -
/// iTunes' figures - is not kept.
fn comment(tags: *_stream.Tags, body: []u8) void {
    if (body.len < 5) return;
    const encoding = body[0];
    const rest = body[4..];
    const after = endOfString(encoding, rest);
    const description = rest[0..after.text_end];
    const plain = description.len == 0;
    if (!plain and (tags.plain_comment or (description.len >= 4 and eql(description[0..4], "iTun")))) return;
    if (after.next >= rest.len) return;
    // The words, with their encoding byte in front as `text` wants them.
    const words = rest[after.next - 1 ..];
    words[0] = encoding;
    text(&tags.comment, words);
    tags.plain_comment = plain;
}

/// Where a string in `encoding` ends in `bytes`, and where what follows it
/// starts: one NUL for Latin-1 and UTF-8, two on an even place for UTF-16.
fn endOfString(encoding: u8, bytes: []const u8) struct { text_end: usize, next: usize } {
    if (encoding == 1 or encoding == 2) {
        var at: usize = 0;
        while (at + 1 < bytes.len) : (at += 2) {
            if (bytes[at] == 0 and bytes[at + 1] == 0) return .{ .text_end = at, .next = at + 2 };
        }
        return .{ .text_end = bytes.len, .next = bytes.len };
    }
    for (bytes, 0..) |b, at| {
        if (b == 0) return .{ .text_end = at, .next = at + 1 };
    }
    return .{ .text_end = bytes.len, .next = bytes.len };
}

/// The most chapters kept: a block for them made at the first.
pub const chapter_max = 256;

/// A chapter (CHAP): its element's name, where it starts and ends in
/// milliseconds, two places in the file that are not used, then frames of
/// its own - its title among them.
fn chapter(stream: *Stream, version: u8, body: []const u8) void {
    const tags = &stream.tags;
    var at: usize = 0;
    while (at < body.len and body[at] != 0) at += 1;
    at += 1;
    if (at + 16 > body.len) return;
    const list = tags.chapters orelse made: {
        const memory = stream.base.sys_base.AllocVec(chapter_max * @sizeOf(ac.AudioChapter), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return;
        const made: [*]ac.AudioChapter = @ptrCast(@alignCast(memory));
        tags.chapters = made;
        break :made made;
    };
    if (tags.chapter_count == chapter_max) return;
    const entry = &list[tags.chapter_count];
    entry.start = be32(body[at..][0..4]);
    entry.end = be32(body[at + 4 ..][0..4]);
    at += 16;
    while (at + 10 <= body.len) {
        const size: usize = if (version == 4) syncsafe(body[at + 4 .. at + 8]) else be32(body[at + 4 .. at + 8]);
        const sub = at + 10;
        if (sub + size > body.len) break;
        if (eql(body[at .. at + 4], "TIT2")) text(&entry.title, body[sub .. sub + size]);
        at = sub + size;
    }
    tags.chapter_count += 1;
}

/// The largest picture kept.
pub const picture_max: u64 = 16 * 1024 * 1024;

/// A picture frame of `size` bytes: its header read - its kind, its MIME
/// type or version 2's three letters - and its image kept when there is
/// none yet, or this is the front cover and the one kept is not.
fn picture(reader: *TagReader, version: u8, size: u64, unsync: bool) void {
    const tags = &reader.stream.tags;
    const sys = reader.stream.base.sys_base;
    const at_start = reader.left;
    const encoding = reader.next() orelse return;
    var mime: [32]u8 = @splat(0);
    if (version == 2) {
        var format: [3]u8 = undefined;
        if (reader.read(&format) != format.len) return;
        const name = if (eql(&format, "PNG")) "image/png" else if (eql(&format, "JPG")) "image/jpeg" else "";
        @memcpy(mime[0..name.len], name);
    } else {
        var length: usize = 0;
        while (reader.next()) |char| {
            if (char == 0) break;
            if (length < mime.len - 1) {
                mime[length] = char;
                length += 1;
            }
        }
    }
    const kind: u32 = reader.next() orelse return;
    // The description, passed over: up to its end in its encoding.
    const wide = encoding == 1 or encoding == 2;
    while (true) {
        const first = reader.next() orelse return;
        if (!wide) {
            if (first == 0) break;
            continue;
        }
        const second = reader.next() orelse return;
        if (first == 0 and second == 0) break;
    }
    const header = at_start - reader.left;
    if (header >= size) return;
    const image_size = size - header;
    const better = tags.picture_block == null or (kind == ac.ACPIC_FRONTCOVER and tags.picture.kind != ac.ACPIC_FRONTCOVER);
    if (!better or image_size > picture_max) {
        reader.skip(image_size);
        return;
    }
    const memory = sys.AllocVec(@intCast(image_size), exec.MEMF_ANY) orelse {
        reader.skip(image_size);
        return;
    };
    const block: [*]u8 = @ptrCast(memory);
    const got = reader.read(block[0..@intCast(image_size)]);
    const image = if (unsync) resync(block[0..got]) else block[0..got];
    if (tags.picture_block) |old| sys.FreeVec(old);
    tags.picture_block = block;
    tags.picture = .{ .data = image.ptr, .size = @intCast(image.len), .kind = kind, .mime = mime };
}

/// A text frame's words into a name, Latin-1: its encoding byte says
/// whether they are Latin-1 (0), UTF-16 with a byte-order mark (1),
/// UTF-16 big-endian (2) or UTF-8 (3). What Latin-1 lacks is narrowed by
/// `narrow`; spaces that come together are one.
pub fn text(into: []u8, body: []const u8) void {
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
            while (i + 1 < words.len) : (i += 2) {
                const unit: u32 = if (big) @as(u32, words[i]) << 8 | words[i + 1] else @as(u32, words[i + 1]) << 8 | words[i];
                if (unit == 0) break;
                // A pair of surrogates is one character past 0xFFFF; a
                // second byte-order mark, before a later value, is none.
                if (unit >= 0xD800 and unit < 0xDC00) {
                    i += 2;
                    put(into, &out, 0x10000);
                    continue;
                }
                if (unit == 0xFEFF) continue;
                put(into, &out, unit);
            }
        },
        3 => {
            var i: usize = 0;
            while (i < words.len) {
                const lead = words[i];
                if (lead == 0) break;
                var point: u32 = lead;
                var length: usize = 1;
                if (lead >= 0xC0 and lead < 0xE0 and i + 1 < words.len) {
                    point = (@as(u32, lead & 0x1F) << 6) | (words[i + 1] & 0x3F);
                    length = 2;
                } else if (lead >= 0xE0 and lead < 0xF0 and i + 2 < words.len) {
                    point = (@as(u32, lead & 0x0F) << 12) | (@as(u32, words[i + 1] & 0x3F) << 6) | (words[i + 2] & 0x3F);
                    length = 3;
                } else if (lead >= 0xF0) {
                    point = 0x10000;
                    length = 4;
                }
                put(into, &out, point);
                i += length;
            }
        },
        else => {
            for (words) |char| {
                if (char == 0) break;
                put(into, &out, char);
            }
        },
    }
    while (out > 0 and into[out - 1] == ' ') out -= 1;
    into[out] = 0;
}

/// One character into a name at `out`, narrowed to Latin-1, while there
/// is room before the NUL.
fn put(into: []u8, out: *usize, point: u32) void {
    for (narrow(point)) |char| {
        if (out.* >= into.len - 1) return;
        if (char == ' ' and (out.* == 0 or into[out.* - 1] == ' ')) continue;
        into[out.*] = char;
        out.* += 1;
    }
}

/// A character as Latin-1 has it: as it is below 0x100; typographic
/// quotes, dashes, the ellipsis and the bullet as their plain kin; a
/// full-width form as the one it is wide for; nothing for what only
/// decorates - a character past 0xFFFF (an emoji), a variation selector,
/// a joiner; `?` for anything else.
fn narrow(point: u32) []const u8 {
    const latin = struct {
        const all = blk: {
            var table: [256]u8 = undefined;
            for (&table, 0..) |*entry, i| entry.* = i;
            break :blk table;
        };
    };
    if (point < 0x100) return latin.all[point..][0..1];
    return switch (point) {
        0x2018, 0x2019, 0x201A, 0x2032 => "'",
        0x201C, 0x201D, 0x201E, 0x2033 => "\"",
        0x2010...0x2015, 0x2212 => "-",
        0x2026 => "...",
        0x2022 => "\xB7",
        0x3000 => " ",
        0xFF01...0xFF5E => latin.all[point - 0xFEE0 ..][0..1],
        0x200B...0x200F, 0xFE00...0xFE0F => "",
        else => if (point >= 0x10000) "" else "?",
    };
}

/// An ID3v1 tag: the title, artist and album, thirty characters each,
/// Latin-1, filled out with blanks or NULs; the year in four digits; a
/// comment of thirty - or twenty-eight and the track's number after a
/// NUL (ID3v1.1); and the genre's number.
pub fn id3v1(tag: *const [128]u8, tags: *_stream.Tags) void {
    _stream.copyName(&tags.title, tag[3..33]);
    _stream.copyName(&tags.artist, tag[33..63]);
    _stream.copyName(&tags.album, tag[63..93]);
    tags.year = _stream.yearOf(tag[93..97]);
    if (tag[125] == 0 and tag[126] != 0) {
        _stream.copyName(&tags.comment, tag[97..125]);
        tags.track = tag[126];
    } else {
        _stream.copyName(&tags.comment, tag[97..127]);
    }
    if (genres.named(tag[127])) |name| _stream.copyName(&tags.genre, _stream.upToNul(name));
}
