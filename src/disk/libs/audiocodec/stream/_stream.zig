// SPDX-License-Identifier: MIT
//! A stream: where its bytes come from, the bytes read ahead of the
//! decoder, what it is, and its kind's own state.
//!
//! **The source** is a file the stream opened, one the program has open,
//! or the program's read function. Only a file can seek, so only a file's
//! stream does; the others are read once, front to back.
//!
//! **Read ahead**: `in` holds the next bytes, `start` to `stop`, and
//! `position` is where `in[0]` lies in the source. A kind takes bytes from
//! the front (`consume`) and `fill` moves what is left to the front and
//! reads behind it until the buffer is full or the source ends - so an MP3
//! frame is always whole in it, and the next one's header with it.
//!
//! **The end of a file** may be tags rather than sound - ID3v1, APE - and
//! a decoder that read them as sound would lose the frame before them:
//! the frame's length is only believed when the next frame's header
//! agrees. So a file's tail is looked at first (`scanTail`), and reading
//! stops where the tags begin (`end`). An ID3v1 tag's names are kept, for
//! a file whose own tags at the front say nothing.
//!
//! **The tags** are kept at full length in `tags`: ID3v1's first, then
//! what ID3v2 or a WAV's INFO list says over them. The info's names are
//! cut from them once the kind's header is read (`nameInfo`). A picture is
//! kept only when the program asked for it, in a block of its own.
//!
//! The stream is one allocation, cleared: every field's starting value is
//! zero, so nothing large is ever built on a stack.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ac = sdk.audiocodec;
const AudioCodecBase = @import("../audiocodec_base.zig").AudioCodecBase;
const wav = @import("../wav/_wav.zig");
const mp3 = @import("../mp3/_mp3.zig");
const layer3 = @import("../mp3/layer3.zig");

/// How many bytes are read ahead: enough to find an MP3's first frame -
/// it has to agree with the frames after it - and a WAV's header.
pub const input_bytes = 16 * 1024;

/// The longest a name is kept, and a comment; a frame's text read whole,
/// at most.
pub const name_bytes = 128;
pub const comment_bytes = 256;
pub const frame_text_bytes = 1024;

/// What the tags say, at full length, NUL-terminated.
pub const Tags = struct {
    title: [name_bytes]u8,
    artist: [name_bytes]u8,
    album: [name_bytes]u8,
    album_artist: [name_bytes]u8,
    composer: [name_bytes]u8,
    genre: [64]u8,
    comment: [comment_bytes]u8,
    /// The comment kept has no description of its own - the one a person
    /// wrote, not one a program keeps for itself.
    plain_comment: bool,
    year: u32,
    track: u32,
    tracks: u32,
    /// Whether the program wants the picture; the block the kept one is
    /// in, null when none is; and what it is.
    keep_picture: bool,
    picture_block: ?[*]u8,
    picture: ac.AudioPicture,
    /// The chapters the tags mark, in a block of their own made at the
    /// first, and how many.
    chapters: ?[*]ac.AudioChapter,
    chapter_count: u32,
    /// A text frame's body, read whole to be looked at.
    frame_text: [frame_text_bytes]u8,
};

pub const Codec = union(enum) {
    none,
    wav: wav.Wav,
    mp3: mp3.Mp3,
};

pub const Stream = struct {
    base: *AudioCodecBase,
    /// The source: a file - the stream's own to close, or the program's -
    /// or the program's read function.
    file: ?*dos.FileHandle,
    owns_file: bool,
    read_fn: ?ac.ReadFn,
    read_data: ?*anyopaque,
    /// Where in a file the sound ends - its tags after it - and whether
    /// that is known.
    end: u64,
    has_end: bool,
    /// Where `in[0]` lies in the source.
    position: u64,
    in: [input_bytes]u8,
    start: usize,
    stop: usize,
    /// The source has no more; or it failed.
    eof: bool,
    failed: bool,
    info: ac.AudioStreamInfo,
    tags: Tags,
    codec: Codec,
    /// Samples decoded and not handed out yet, the channels interleaved,
    /// `pcm_start` to `pcm_stop`.
    pcm: [layer3.max_samples_per_frame]i16,
    pcm_start: usize,
    pcm_stop: usize,
};

/// The stream given back: the file it opened closed, its memory freed.
pub fn destroy(stream: *Stream) void {
    const base = stream.base;
    if (stream.owns_file) {
        if (stream.file) |file| _ = base.dos_base.Close(file);
    }
    if (stream.tags.picture_block) |block| base.sys_base.FreeVec(block);
    if (stream.tags.chapters) |list| base.sys_base.FreeVec(list);
    base.sys_base.FreeVec(stream);
}

pub fn streamOf(public: *ac.AudioStream) *Stream {
    return @ptrCast(@alignCast(public));
}

pub fn publicOf(stream: *Stream) *ac.AudioStream {
    return @ptrCast(stream);
}

/// Up to `into.len` bytes from the source: how many, 0 at the end, below 0
/// when it fails.
fn readSource(stream: *Stream, into: []u8) isize {
    if (stream.file) |file| {
        return stream.base.dos_base.Read(file, into.ptr, @intCast(into.len));
    }
    const read = stream.read_fn orelse return -1;
    return read(stream.read_data, into.ptr, @intCast(into.len));
}

/// What is left moved to the front, and the buffer filled behind it until
/// it is full or the source ends.
pub fn fill(stream: *Stream) void {
    if (stream.start != 0) {
        const left = stream.stop - stream.start;
        @memmove(stream.in[0..left], stream.in[stream.start..stream.stop]);
        stream.position += stream.start;
        stream.stop = left;
        stream.start = 0;
    }
    while (stream.stop < stream.in.len and !stream.eof) {
        var want: usize = stream.in.len - stream.stop;
        if (stream.has_end) {
            const at = stream.position + stream.stop;
            if (at >= stream.end) {
                stream.eof = true;
                break;
            }
            want = @intCast(@min(@as(u64, want), stream.end - at));
        }
        const got = readSource(stream, stream.in[stream.stop..][0..want]);
        if (got < 0) {
            stream.failed = true;
            stream.eof = true;
            break;
        }
        if (got == 0) {
            stream.eof = true;
            break;
        }
        stream.stop += @intCast(got);
    }
}

/// The bytes read ahead.
pub fn available(stream: *Stream) []const u8 {
    return stream.in[stream.start..stream.stop];
}

pub fn consume(stream: *Stream, count: usize) void {
    stream.start += @min(count, stream.stop - stream.start);
}

/// Where the next byte comes from in the source.
pub fn tell(stream: *Stream) u64 {
    return stream.position + stream.start;
}

/// The source moved to `offset` - a file's only - and what was read ahead
/// dropped. False for a source that cannot seek.
pub fn seekSource(stream: *Stream, offset: u64) bool {
    const file = stream.file orelse return false;
    if (offset > 0x7fff_ffff) return false;
    if (stream.base.dos_base.Seek(file, @intCast(offset), dos.OFFSET_BEGINNING) < 0) return false;
    stream.position = offset;
    stream.start = 0;
    stream.stop = 0;
    stream.eof = false;
    stream.failed = false;
    return true;
}

/// `count` bytes passed over: out of the buffer, then by seeking a file
/// or reading through the rest.
pub fn skip(stream: *Stream, count: u64) void {
    const here: u64 = stream.stop - stream.start;
    if (count <= here) {
        consume(stream, @intCast(count));
        return;
    }
    const target = tell(stream) + count;
    if (stream.file != null and seekSource(stream, target)) return;
    var left = count - here;
    stream.start = stream.stop;
    while (left > 0 and !stream.eof) {
        fill(stream);
        const now: u64 = stream.stop - stream.start;
        if (now == 0) break;
        const taken = @min(now, left);
        consume(stream, @intCast(taken));
        left -= taken;
    }
}

/// A file's tail looked at before anything is read: an ID3v1 tag in its
/// last 128 bytes, an APE tag before it or at the very end - reading
/// stops where they begin. The ID3v1 tag's names go into the info, for
/// tags at the front to replace. The file is left at its start.
pub fn scanTail(stream: *Stream) void {
    const file = stream.file orelse return;
    const dl = stream.base.dos_base;
    var fib: dos.FileInfoBlock = .{};
    if (!dl.ExamineFH(file, &fib)) return;
    if (fib.size > 0x7fff_ffff) return;
    var end: u64 = fib.size;

    var tail: [128]u8 = undefined;
    if (end >= 128 and readAt(stream, end - 128, &tail)) {
        if (tail[0] == 'T' and tail[1] == 'A' and tail[2] == 'G') {
            mp3.id3v1(&tail, &stream.tags);
            end -= 128;
        }
    }
    // An APE tag's footer: "APETAGEX", its version, its size (footer
    // included, header not), its count and its flags; a header before it
    // when bit 31 of the flags says so.
    var footer: [32]u8 = undefined;
    if (end >= 32 and readAt(stream, end - 32, &footer)) {
        if (same(footer[0..8], "APETAGEX")) {
            const size = le32(footer[12..16]);
            const flags = le32(footer[20..24]);
            const whole: u64 = @as(u64, size) + (if (flags & 0x8000_0000 != 0) @as(u64, 32) else 0);
            if (whole <= end) end -= whole;
        }
    }
    stream.end = end;
    stream.has_end = true;
    _ = seekSource(stream, 0);
}

/// `into.len` bytes from `offset` of the stream's file, whole or not at all.
fn readAt(stream: *Stream, offset: u64, into: []u8) bool {
    const file = stream.file orelse return false;
    const dl = stream.base.dos_base;
    if (offset > 0x7fff_ffff) return false;
    if (dl.Seek(file, @intCast(offset), dos.OFFSET_BEGINNING) < 0) return false;
    return dl.Read(file, into.ptr, @intCast(into.len)) == @as(isize, @intCast(into.len));
}

pub fn same(bytes: []const u8, comptime word: []const u8) bool {
    if (bytes.len < word.len) return false;
    for (word, 0..) |char, i| {
        if (bytes[i] != char) return false;
    }
    return true;
}

pub fn le32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | @as(u32, bytes[1]) << 8 | @as(u32, bytes[2]) << 16 | @as(u32, bytes[3]) << 24;
}

pub fn le16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | @as(u16, bytes[1]) << 8;
}

/// A NUL-terminated copy of `text` into a name, cut at its first NUL or
/// where it no longer fits, trailing blanks dropped: Latin-1 as it is.
pub fn copyName(into: []u8, text: []const u8) void {
    var length: usize = 0;
    while (length < text.len and length < into.len - 1 and text[length] != 0) length += 1;
    while (length > 0 and text[length - 1] == ' ') length -= 1;
    @memcpy(into[0..length], text[0..length]);
    into[length] = 0;
}

/// The info's title, artist and album cut from the tags: once the kind's
/// header is read, and the tags say all they will.
pub fn nameInfo(stream: *Stream) void {
    copyName(&stream.info.title, &stream.tags.title);
    copyName(&stream.info.artist, &stream.tags.artist);
    copyName(&stream.info.album, &stream.tags.album);
}

/// A year's first four digits, 0 when there are none: "2004",
/// "2004-05-12".
pub fn yearOf(text: []const u8) u32 {
    var year: u32 = 0;
    var digits: usize = 0;
    for (text) |char| {
        if (char < '0' or char > '9' or digits == 4) break;
        year = year * 10 + (char - '0');
        digits += 1;
    }
    return if (digits == 4) year else 0;
}

/// A track's number and the album's count of them: "3", "3/12".
pub fn trackOf(text: []const u8, track: *u32, tracks: *u32) void {
    var number: u32 = 0;
    var at: usize = 0;
    while (at < text.len and text[at] >= '0' and text[at] <= '9') : (at += 1) number = number *| 10 +| (text[at] - '0');
    track.* = number;
    tracks.* = 0;
    if (at < text.len and text[at] == '/') {
        at += 1;
        var count: u32 = 0;
        while (at < text.len and text[at] >= '0' and text[at] <= '9') : (at += 1) count = count *| 10 +| (text[at] - '0');
        tracks.* = count;
    }
}

/// A string's bytes up to its NUL: a name in a buffer, or a C string.
pub fn upToNul(text: anytype) []const u8 {
    const T = @TypeOf(text);
    if (T == [*:0]const u8) {
        var length: usize = 0;
        while (text[length] != 0) length += 1;
        return text[0..length];
    }
    var length: usize = 0;
    while (length < text.len and text[length] != 0) length += 1;
    return text[0..length];
}
