// SPDX-License-Identifier: MIT
//! A file opened: where its bytes come from, its index in memory, its
//! tracks - each with its buffer, and what its kind keeps of it: sample
//! tables and a cursor, or a walk through the clusters - and its tags.
//!
//! **The source** is a file the library opened, one the program has open,
//! or the program's read function. A file is read where its bytes lie -
//! a seek and a read - by whichever task reads a track; the semaphore lets
//! one at a time at it (`readAt`). A read function only goes forward:
//! `position` is how far it has read, and bytes behind it are gone - but
//! for a few kept to be read again (`kept`): its first, which the kind
//! was found by, or the head of the cluster a Matroska file's opening
//! stopped at.
//!
//! **A track's buffer** holds bytes of the file from `cached_at` on: the
//! packet asked for and, where they fit, the rest of its chunk - the
//! packets of a track lie together in chunks, so the packets after it are
//! handed out of the buffer. It is made at the track's first read, as
//! large as its largest packet and 64 KiB at least, and a packet handed
//! out points into it. A Matroska track's holds the bytes its walk through
//! the clusters reads (`mkv/blocks.zig`).
//!
//! **A kind's code** is a module (sdk/libs/media/mcontainer.zig): this file
//! is compiled into the library and into each of them, and the file's
//! layout is the SDK's. What a kind keeps of a file and its tracks is
//! memory of its own (`state`, each track's `own`).
//!
//! The file is one allocation, cleared; the index (an MP4's `moov`, a
//! Matroska file's tracks), the chapters and each track's buffers are
//! memory of their own, given back with it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const media = sdk.media;
const utility = sdk.utility;
const mcontainer = sdk.mcontainer;
const MContainerBase = sdk.interface.mcontainer.MContainerBase;

/// The most tracks a file's are read of; past them, tracks are passed
/// over.
pub const max_tracks = mcontainer.MCONTAINER_MOST_TRACKS;

/// The longest a name is kept, and a comment.
pub const name_bytes = mcontainer.MCONTAINER_NAME_BYTES;
pub const comment_bytes = mcontainer.MCONTAINER_COMMENT_BYTES;

/// A track's buffer is at least this large.
pub const min_buffer = 64 * 1024;

/// A file, a track and its tags, as the library and its module share them.
pub const Tags = mcontainer.MContainerTags;
pub const Track = mcontainer.MContainerTrack;
pub const File = mcontainer.MediaContainerFile;

/// The file's module, as its calls are made.
pub fn moduleOf(file: *File) ?*MContainerBase {
    return @ptrCast(file.module);
}

/// The kind's state, cleared, in memory of its own: made once, and given
/// back at CloseContainer. Null when there is no memory for it.
pub fn stateOf(file: *File, comptime T: type) ?*T {
    const made = file.state orelse file.base.sys_base.AllocVec(@sizeOf(T), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    file.state = made;
    return @ptrCast(@alignCast(made));
}

pub fn fileOf(public: *media.MediaFile) *File {
    return @ptrCast(@alignCast(public));
}

pub fn publicOf(file: *File) *media.MediaFile {
    return @ptrCast(file);
}

/// The file given back: the file it opened closed, its memory freed.
/// The module let go after it refused the file, so the next can be given
/// it: what the module made handed back (`CloseContainer` frees its state
/// and each track's own), the module closed, and the file as it was
/// handed to it - the tracks it found, an index, the chapters and the tags
/// it read all gone. Its bytes are read again where they lie, which only a
/// file can do.
pub fn dropModule(file: *File) void {
    const sys = file.base.sys_base;
    const module = moduleOf(file) orelse return;
    module.CloseContainer(file);
    sys.CloseLibrary(module.lib());
    file.module = null;
    for (file.tracks[0..file.track_count]) |*track| {
        if (track.buffer) |buffer| sys.FreeVec(buffer);
    }
    @memset(std.mem.asBytes(&file.tracks), 0);
    file.track_count = 0;
    file.subtitles = ~@as(u32, 0);
    if (file.index) |index| sys.FreeVec(index);
    file.index = null;
    file.index_size = 0;
    if (file.tags.chapters) |list| sys.FreeVec(list);
    const keep_picture = file.tags.keep_picture;
    @memset(std.mem.asBytes(&file.tags), 0);
    file.tags.keep_picture = keep_picture;
    file.info = .{};
}

pub fn destroy(file: *File) void {
    const base = file.base;
    const sys = base.sys_base;
    if (moduleOf(file)) |module| module.CloseContainer(file);
    for (file.tracks[0..file.track_count]) |*track| {
        if (track.buffer) |buffer| sys.FreeVec(buffer);
    }
    if (file.owns_file) {
        if (file.file) |handle| _ = base.dos_base.Close(handle);
    }
    if (file.index) |index| sys.FreeVec(index);
    if (file.tags.chapters) |list| sys.FreeVec(list);
    if (moduleOf(file)) |module| sys.CloseLibrary(module.lib());
    sys.FreeVec(file);
}

/// `into.len` bytes from `offset` of the source, whole: false when they
/// are not there, or lie behind what a read function has read. The caller
/// holds the lock.
pub fn readAt(file: *File, offset: u64, into: []u8) bool {
    return readSome(file, offset, into) == into.len;
}

/// Up to `into.len` bytes from `offset` of the source: how many it had -
/// fewer where it ends, 0 where it cannot be read, or the bytes lie
/// behind what a read function has read. The caller holds the lock.
pub fn readSome(file: *File, offset: u64, into: []u8) usize {
    var got: usize = 0;
    if (file.file) |handle| {
        const dl = file.base.dos_base;
        const at = offset +| file.origin;
        if (at > std.math.maxInt(i64)) return 0;
        if (dl.Seek(handle, @intCast(at), dos.OFFSET_BEGINNING) < 0) return 0;
        while (got < into.len) {
            const want: isize = @intCast(@min(into.len - got, 0x4000_0000));
            const read = dl.Read(handle, into.ptr + got, want);
            if (read <= 0) break;
            got += @intCast(read);
        }
        return got;
    }
    var at = offset;
    if (at >= file.kept_at and at < file.kept_at + file.kept_length) {
        const from: usize = @intCast(at - file.kept_at);
        got = @min(file.kept_length - from, into.len);
        @memcpy(into[0..got], file.kept[from..][0..got]);
        at += got;
        if (got == into.len) return got;
    }
    if (at < file.position) return got;
    if (!skipTo(file, at)) return 0;
    while (got < into.len) {
        const want: u32 = @intCast(@min(into.len - got, 0x4000_0000));
        const read = file.read_fn.?(file.read_data, into.ptr + got, want);
        if (read <= 0) break;
        got += @intCast(read);
        file.position += @intCast(read);
    }
    return got;
}

/// Bytes just read from `offset`, kept for a read function to give them
/// again: as many as `kept` holds.
pub fn keep(file: *File, offset: u64, bytes: []const u8) void {
    if (file.file != null) return;
    const length = @min(bytes.len, file.kept.len);
    @memcpy(file.kept[0..length], bytes[0..length]);
    file.kept_at = offset;
    file.kept_length = @intCast(length);
}

/// Whether bytes from `offset` are gone: behind what a read function has
/// read, and not kept.
pub fn behind(file: *const File, offset: u64) bool {
    if (file.file != null or offset >= file.position) return false;
    return offset < file.kept_at or offset >= file.kept_at + file.kept_length;
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

/// A NUL-terminated copy of `text` - UTF-8, up to a NUL in it - into
/// `into`, in Latin-1 by the file's utility.library: typesetting's quotes
/// and dashes plain ones, another character past Latin-1 and a byte that
/// is no UTF-8 a `?`. Cut where it no longer fits.
pub fn copyUtf8(file: *const File, into: []u8, text: []const u8) void {
    const whole = upToNul(text);
    var conversion: utility.Utf8Conversion = .{ .flags = utility.UTF8F_TYPESET };
    const length = file.base.utility_base.Utf8ToLatin1(&conversion, whole.ptr, whole.len, into.ptr, into.len - 1);
    into[length] = 0;
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
