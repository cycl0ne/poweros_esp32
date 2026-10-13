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
            mp3.id3v1(&tail, &stream.info);
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

/// A NUL-terminated copy of `text` into one of the info's names, cut at
/// its first NUL or where it no longer fits, trailing blanks dropped:
/// Latin-1 as it is.
pub fn copyName(into: *[64]u8, text: []const u8) void {
    var length: usize = 0;
    while (length < text.len and length < into.len - 1 and text[length] != 0) length += 1;
    while (length > 0 and text[length - 1] == ' ') length -= 1;
    @memcpy(into[0..length], text[0..length]);
    into[length] = 0;
}
