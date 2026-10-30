// SPDX-License-Identifier: MIT
//! A file opened: where its bytes come from, its index in memory, its
//! tracks - each with its sample tables, its cursor and its buffer - and
//! its tags.
//!
//! **The source** is a file the library opened, one the program has open,
//! or the program's read function. A file is read where its bytes lie -
//! a seek and a read - by whichever task reads a track; the semaphore lets
//! one at a time at it (`readAt`). A read function only goes forward:
//! `position` is how far it has read, and bytes behind it are gone.
//!
//! **A track's buffer** holds bytes of the file from `cached_at` on: the
//! packet asked for and, where they fit, the rest of its chunk - the
//! packets of a track lie together in chunks, so the packets after it are
//! handed out of the buffer. It is made at the track's first read, as
//! large as its largest packet and 64 KiB at least, and a packet handed
//! out points into it.
//!
//! The file is one allocation, cleared; the index (an MP4's `moov`), the
//! chapters and each track's buffer are memory of their own, given back
//! with it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const media = sdk.media;
const MediaBase = @import("../media_base.zig").MediaBase;
const cursor = @import("../mp4/cursor.zig");

/// The most tracks a file's are read of; past them, tracks are passed
/// over.
pub const max_tracks = 16;

/// The longest a name is kept, and a comment.
pub const name_bytes = 128;
pub const comment_bytes = 256;

/// A track's buffer is at least this large.
pub const min_buffer = 64 * 1024;

/// What the tags say, at full length, NUL-terminated, Latin-1.
pub const Tags = struct {
    title: [name_bytes]u8,
    artist: [name_bytes]u8,
    album: [name_bytes]u8,
    album_artist: [name_bytes]u8,
    composer: [name_bytes]u8,
    genre: [64]u8,
    comment: [comment_bytes]u8,
    year: u32,
    track: u32,
    tracks: u32,
    keep_picture: bool,
    has_picture: bool,
    picture: media.MediaPicture,
    /// The chapters, in a block of their own, and how many.
    chapters: ?[*]media.MediaChapter,
    chapter_count: u32,
};

pub const Track = struct {
    /// What GetMediaTrack hands out.
    info: media.MediaTrack,
    /// The sample tables, where they lie in the index, and where the
    /// cursor is in them.
    tables: cursor.Tables,
    at: cursor.Cursor,
    /// Where presenting starts in the track's ticks (its edit), and the
    /// microseconds of nothing before the track begins.
    media_start: i64,
    empty_us: i64,
    /// The number of the text track that names this one's chapters
    /// (`tref`'s `chap`), 0 for none.
    chapter_ref: u32,
    /// Bytes of the file from `cached_at` on, `cached` of them, in a
    /// buffer `buffer_size` large.
    buffer: ?[*]u8,
    buffer_size: u32,
    cached_at: u64,
    cached: u32,
};

pub const File = struct {
    base: *MediaBase,
    file: ?*dos.FileHandle,
    owns_file: bool,
    read_fn: ?media.ReadFn,
    read_data: ?*anyopaque,
    /// How far a read function has read; the size of a file, 0 when not
    /// known; where in the file the container begins - where a handle
    /// the program gave was.
    position: u64,
    size: u64,
    origin: u64,
    /// Lets one task at a time at the source.
    lock: exec.SignalSemaphore,
    info: media.MediaInfo,
    /// The index, read whole.
    index: ?[*]u8,
    index_size: usize,
    movie_timescale: u32,
    tracks: [max_tracks]Track,
    track_count: u32,
    tags: Tags,
};

pub fn fileOf(public: *media.MediaFile) *File {
    return @ptrCast(@alignCast(public));
}

pub fn publicOf(file: *File) *media.MediaFile {
    return @ptrCast(file);
}

/// The file given back: the file it opened closed, its memory freed.
pub fn destroy(file: *File) void {
    const base = file.base;
    const sys = base.sys_base;
    for (file.tracks[0..file.track_count]) |*track| {
        if (track.buffer) |buffer| sys.FreeVec(buffer);
    }
    if (file.owns_file) {
        if (file.file) |handle| _ = base.dos_base.Close(handle);
    }
    if (file.index) |index| sys.FreeVec(index);
    if (file.tags.chapters) |list| sys.FreeVec(list);
    sys.FreeVec(file);
}

/// `into.len` bytes from `offset` of the source, whole: false when they
/// are not there, or lie behind what a read function has read. The caller
/// holds the lock.
pub fn readAt(file: *File, offset: u64, into: []u8) bool {
    if (file.file) |handle| {
        const dl = file.base.dos_base;
        const at = offset +| file.origin;
        if (at > std.math.maxInt(i64)) return false;
        if (dl.Seek(handle, @intCast(at), dos.OFFSET_BEGINNING) < 0) return false;
        var got: usize = 0;
        while (got < into.len) {
            const want: isize = @intCast(@min(into.len - got, 0x4000_0000));
            const read = dl.Read(handle, into.ptr + got, want);
            if (read <= 0) return false;
            got += @intCast(read);
        }
        return true;
    }
    if (offset < file.position) return false;
    if (!skipTo(file, offset)) return false;
    var got: usize = 0;
    while (got < into.len) {
        const want: u32 = @intCast(@min(into.len - got, 0x4000_0000));
        const read = file.read_fn.?(file.read_data, into.ptr + got, want);
        if (read <= 0) return false;
        got += @intCast(read);
    }
    file.position += into.len;
    return true;
}

/// A read function's bytes up to `offset` read and dropped.
fn skipTo(file: *File, offset: u64) bool {
    var scratch: [512]u8 = undefined;
    while (file.position < offset) {
        const want: u32 = @intCast(@min(offset - file.position, scratch.len));
        const read = file.read_fn.?(file.read_data, &scratch, want);
        if (read <= 0) return false;
        file.position += @intCast(read);
    }
    return true;
}

/// Whether the source can be read anywhere.
pub fn seekable(file: *const File) bool {
    return file.file != null;
}

pub fn be16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}

pub fn be32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
}

pub fn be64(bytes: []const u8) u64 {
    return @as(u64, be32(bytes[0..4])) << 32 | be32(bytes[4..8]);
}

/// A NUL-terminated copy of `text` - UTF-8 - into `into`, in Latin-1: a
/// character past it is a `?`. Cut where it no longer fits.
pub fn copyUtf8(into: []u8, text: []const u8) void {
    var out: usize = 0;
    var at: usize = 0;
    while (at < text.len and out < into.len - 1) {
        const lead = text[at];
        if (lead == 0) break;
        // A character of two bytes may be Latin-1; longer ones never are,
        // and a byte that does not begin one is no character.
        var char: u32 = '?';
        var length: usize = 1;
        if (lead < 0x80) {
            char = lead;
        } else if (lead >= 0xF0) {
            length = 4;
        } else if (lead >= 0xE0) {
            length = 3;
        } else if (lead >= 0xC0 and at + 1 < text.len) {
            length = 2;
            char = (@as(u32, lead & 0x1F) << 6) | (text[at + 1] & 0x3F);
        }
        at += length;
        into[out] = if (char <= 0xFF) @intCast(char) else '?';
        out += 1;
    }
    into[out] = 0;
}

/// A string's bytes up to its NUL.
pub fn upToNul(text: []const u8) []const u8 {
    var length: usize = 0;
    while (length < text.len and text[length] != 0) length += 1;
    return text[0..length];
}

/// A NUL-terminated copy of a name, cut where it no longer fits.
pub fn copyName(into: []u8, text: []const u8) void {
    const length = @min(upToNul(text).len, into.len - 1);
    @memcpy(into[0..length], text[0..length]);
    into[length] = 0;
}

/// `ticks` of `timescale` in microseconds.
pub fn micros(ticks: i64, timescale: u32) i64 {
    if (timescale == 0) return 0;
    return @intCast(@divFloor(@as(i128, ticks) * 1_000_000, timescale));
}

/// `us` microseconds in ticks of `timescale`, rounded down.
pub fn ticksOf(us: i64, timescale: u32) i64 {
    return @intCast(@divFloor(@as(i128, us) * timescale, 1_000_000));
}
