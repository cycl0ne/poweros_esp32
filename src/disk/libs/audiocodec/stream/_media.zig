// SPDX-License-Identifier: MIT
//! A track of a container - an MP4, a Matroska file - read through
//! media.library: the packets of one sound track, decoded by its codec's
//! code, and where each packet's sound lies.
//!
//! **Opening**: the stream's own file is handed over where the container
//! begins, or the program's read function behind the bytes already read
//! ahead - an MP4 then wants its index in front, a Matroska file is read
//! front to back - or a file the program has open with media.library
//! already (`ACA_Media`), which stays the program's. Its first sound track
//! - in a Matroska file the one it marks to be played - is decoded unless
//! `ACA_MediaTrack` names another: AAC, MP3, FLAC, Vorbis, AC-3, E-AC-3
//! and Opus; any other codec is refused.
//!
//! **Where the sound lies**: the first packet's ticks say where it begins,
//! in the track's own ticks, and each packet after it begins where the
//! one before ends - a Matroska file's times are milliseconds, a packet's
//! frames are exact. The track's priming (`delay`) counts before the
//! sound's first frame and is left out, as is what lies past the track's
//! length when the file says it. An MP4's edit says the length exactly; a
//! Matroska file to the millisecond - so its sound ends within one of
//! where it stops - but a FLAC's STREAMINFO exactly again.
//!
//! **A sound that begins late**: a Matroska file counts from its start,
//! and a film's sound may begin after its first picture - its first
//! block's time, where its first packet's priming ends. The frames count
//! from the file's start all the same, so the sound keeps time with the
//! pictures: silence is handed out up to where it begins (`gap`). To see
//! where that is, the first packet is read when the track is opened, and
//! again when it moves (`held`), and handed out after.
//!
//! **Holes**: a packet whose ticks put it more than a fiftieth of a
//! second after where the sound before it ends - a film cut and joined,
//! a recording that lost some - has silence before it, so the sound
//! after the hole keeps time too. The packet is held back and the codec
//! stops short (`paused`); DecodeAudio hands out the silence and goes on.
//! Sound that would lie over what was handed out already is passed over.
//! Packets laced into one Matroska block without a duration share its
//! time and are counted on.
//!
//! **A seek** moves the track to the packet the frame asked for lies in,
//! or so many frames before it as the codec wants decoded first - an
//! overlap filled, an MP3's reservoir - and the frames before the one
//! asked for are passed over. The packet landed on places the sound
//! again: exactly in an MP4, within a millisecond in a Matroska file -
//! and for Vorbis that FFmpeg muxed a short block's half more. Where it
//! begins after the frame asked for, silence fills up to it.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const media = sdk.media;
const utility = sdk.utility;
const MediaBase = sdk.interface.media.MediaBase;
const AudioCodecBase = @import("../audiocodec_base.zig").AudioCodecBase;
const _stream = @import("_stream.zig");
const Stream = _stream.Stream;

/// The stream's track, as the library and its module share it.
pub const Source = sdk.acodec.ACodecSource;

/// Whether the bytes begin a container: an MP4's `ftyp` box, or EBML's
/// header - a Matroska file.
pub fn container(bytes: []const u8) bool {
    if (bytes.len >= 8 and _stream.same(bytes[4..], "ftyp")) return true;
    return bytes.len >= 4 and _stream.same(bytes, "\x1A\x45\xDF\xA3");
}

/// The container opened through media.library: the stream's file where
/// it begins, or the program's read function behind what is already
/// read ahead; then its track.
pub fn open(base: *AudioCodecBase, stream: *Stream) i32 {
    const sys = stream.base.sys_base;
    const mb: *MediaBase = @ptrCast(sys.OpenLibrary(media.MEDIANAME, 1) orelse return ac.ACERR_UNSUPPORTED);
    var err: i32 = 0;
    var file: ?*media.MediaFile = null;
    const keep: usize = @intFromBool(stream.tags.keep_picture);
    if (stream.file) |handle| {
        if (!_stream.seekSource(stream, _stream.tell(stream))) {
            sys.CloseLibrary(mb.lib());
            return ac.ACERR_READ;
        }
        file = mb.OpenMedia(&[_]utility.TagItem{
            .{ .tag = media.MDA_FileHandle, .data = @intFromPtr(handle) },
            .{ .tag = media.MDA_KeepPicture, .data = keep },
            .{},
        }, &err);
    } else {
        file = mb.OpenMedia(&[_]utility.TagItem{
            .{ .tag = media.MDA_ReadFunc, .data = @intFromPtr(&readThrough) },
            .{ .tag = media.MDA_ReadData, .data = @intFromPtr(stream) },
            .{ .tag = media.MDA_KeepPicture, .data = keep },
            .{},
        }, &err);
    }
    const opened = file orelse {
        sys.CloseLibrary(mb.lib());
        return switch (err) {
            media.MERR_NOMEMORY => ac.ACERR_NOMEMORY,
            media.MERR_UNKNOWN => ac.ACERR_UNKNOWN,
            media.MERR_UNSUPPORTED => ac.ACERR_UNSUPPORTED,
            media.MERR_CORRUPT => ac.ACERR_CORRUPT,
            else => ac.ACERR_READ,
        };
    };
    return openTrack(base, stream, mb, opened, true, stream.media_track);
}

/// The program's read function, behind the bytes the stream read ahead.
fn readThrough(data: ?*anyopaque, buffer: [*]u8, length: u32) callconv(.c) i32 {
    const stream: *Stream = @ptrCast(@alignCast(data.?));
    const here = _stream.available(stream);
    if (here.len != 0) {
        const count = @min(here.len, length);
        @memcpy(buffer[0..count], here[0..count]);
        _stream.consume(stream, count);
        return @intCast(count);
    }
    const read = stream.read_fn orelse return -1;
    return read(stream.read_data, buffer, length);
}

/// A file media.library has open, given with ACA_Media: its track
/// decoded, the file left the program's.
pub fn openGiven(base: *AudioCodecBase, stream: *Stream, file: *media.MediaFile, track: u32) i32 {
    const sys = stream.base.sys_base;
    const mb: *MediaBase = @ptrCast(sys.OpenLibrary(media.MEDIANAME, 1) orelse return ac.ACERR_UNSUPPORTED);
    return openTrack(base, stream, mb, file, false, track);
}

/// The track - the first sound track for ~0 - checked and opened by its
/// codec's code; then where its sound lies, its length, and the file's
/// tags as the stream's.
fn openTrack(base: *AudioCodecBase, stream: *Stream, mb: *MediaBase, file: *media.MediaFile, owns: bool, wanted: u32) i32 {
    const source = &stream.media;
    source.* = .{
        .base = mb,
        .file = file,
        .owns = owns,
        .track = 0,
        .timescale = 0,
        .rate = 0,
        .delay = 0,
        .exact = false,
        .total = 0,
        .done = false,
        .skip_until = 0,
        .position = 0,
        .placed = false,
        .start = 0,
        .gap = 0,
        .held = .{},
        .holding = false,
        .paused = false,
        .last_ticks = 0,
    };
    var info: media.MediaInfo = .{};
    mb.GetMediaInfo(file, &info);
    const number = if (wanted == ~@as(u32, 0)) info.audio else wanted;
    var track: media.MediaTrack = .{};
    if (number == ~@as(u32, 0) or mb.GetMediaTrack(file, number, &track) != media.MERR_OK) return ac.ACERR_UNKNOWN;
    if (track.kind != media.MTRACK_AUDIO) return ac.ACERR_UNKNOWN;
    if (track.timescale == 0) return ac.ACERR_CORRUPT;
    source.track = number;
    source.timescale = track.timescale;
    if (!hold(stream) and stream.failed) return ac.ACERR_READ;
    const first = source.held.ticks;
    const codec: u32 = switch (track.codec) {
        media.MCODEC_AAC => ac.ACODEC_AAC,
        media.MCODEC_MP3 => ac.ACODEC_MP3,
        media.MCODEC_FLAC => ac.ACODEC_FLAC,
        media.MCODEC_VORBIS => ac.ACODEC_VORBIS,
        media.MCODEC_AC3 => ac.ACODEC_AC3,
        media.MCODEC_EAC3 => ac.ACODEC_EAC3,
        media.MCODEC_OPUS => ac.ACODEC_OPUS,
        media.MCODEC_DTS => ac.ACODEC_DTS,
        else => return ac.ACERR_UNSUPPORTED,
    };
    // Every module of the kind, in the order their tags put them (SINCE
    // 1.14): one that opens and then refuses the track is let go and the
    // next is read the same packets, from the track's start again. Only a
    // track that can be moved back is read again; a container read
    // through a function keeps the refusal.
    const was = stream.info;
    var tried: u32 = 0;
    var why: i32 = ac.ACERR_UNSUPPORTED;
    while (_stream.openNextModule(base, stream, codec, &tried)) |module| {
        const result = module.OpenACodecTrack(stream, &track);
        if (result == ac.ACERR_OK) break;
        if (why == ac.ACERR_UNSUPPORTED) why = result;
        _stream.dropModule(base, stream, was);
        if (!restart(stream)) return result;
    } else return why;
    // The rate the codec decodes at: an HE-AAC track's core is half the
    // rate its container gives.
    source.rate = stream.info.rate;
    if (source.rate == 0) return ac.ACERR_CORRUPT;
    source.delay = framesOf(source, track.delay);
    if (!source.exact and track.length != 0) {
        source.exact = true;
        source.total = framesOf(source, @intCast(@min(track.length, std.math.maxInt(i64))));
    }
    // Where the first packet's priming ends: frame 0 of an MP4's track,
    // its first block's time in a Matroska file.
    source.start = framesOf(source, @intCast(@min(first, std.math.maxInt(i64))));
    source.skip_until = source.start;
    source.gap = gapOf(source, 0, source.start);
    stream.info.seekable = info.seekable;
    if (track.bitrate != 0) stream.info.bitrate = track.bitrate;
    if (source.exact) stream.info.frames = @intCast(@min(source.total, 0xFFFF_FFFF));
    tagsOf(stream, mb, file);
    return ac.ACERR_OK;
}

/// The media file closed when it is the stream's, and media.library.
pub fn free(stream: *Stream) void {
    const source = &stream.media;
    const mb = source.base orelse return;
    if (source.owns) mb.CloseMedia(source.file);
    stream.base.sys_base.CloseLibrary(mb.lib());
    source.base = null;
    source.file = null;
}

/// `ticks` of the track in frames of the sound.
pub fn framesOf(source: *const Source, ticks: i64) i64 {
    return @intCast(@divFloor(@as(i128, ticks) * source.rate, source.timescale));
}

/// Where the sound of a packet of `ticks` begins, in frames from the
/// sound's first - below 0 for priming: where the packets before it ended,
/// or its ticks for the first since the track was opened or moved.
pub fn place(source: *Source, ticks: u64) i64 {
    if (!source.placed) {
        source.position = framesOf(source, @intCast(@min(ticks, std.math.maxInt(i64)))) - source.delay;
        source.placed = true;
    }
    return source.position;
}

/// The packet placed last holds `count` frames: the next begins after
/// them.
pub fn advance(source: *Source, count: u32) void {
    source.position += count;
}

/// The track's next packet, null at the end - or after a packet wholly
/// past the length, or when the file fails (`failed` then set).
pub fn next(stream: *Stream, packet: *media.MediaPacket) ?[]const u8 {
    const source = &stream.media;
    if (source.done) return null;
    if (source.holding) {
        packet.* = source.held;
        source.holding = false;
    } else {
        packet.* = .{};
        const result = source.base.?.ReadMediaPacket(source.file.?, source.track, packet);
        if (result == media.MERR_END) return null;
        if (result != media.MERR_OK) {
            stream.failed = true;
            return null;
        }
        if (hole(stream, packet)) return null;
    }
    source.last_ticks = packet.ticks;
    if (packet.size == 0) return &.{};
    return packet.data.?[0..packet.size];
}

/// Whether the packet comes after a hole in the track's times: then it is
/// held back, the silence to fill the hole is the gap, and the codec is
/// to stop. A packet that would lie over sound handed out has that part
/// passed over.
fn hole(stream: *Stream, packet: *const media.MediaPacket) bool {
    const source = &stream.media;
    if (!source.placed or packet.ticks == source.last_ticks) return false;
    const begins = framesOf(source, @intCast(@min(packet.ticks, std.math.maxInt(i64)))) - source.delay;
    const away = begins - source.position;
    const slack: i64 = source.rate / 50;
    if (away < -slack) {
        source.skip_until = @max(source.skip_until, source.position);
        source.position = begins;
        return false;
    }
    if (away <= slack) return false;
    source.gap = gapOf(source, @max(source.position, source.skip_until), begins);
    source.position = begins;
    if (source.gap == 0) return false;
    source.held = packet.*;
    source.holding = true;
    source.paused = true;
    return true;
}

/// Whether a hole stopped the codec - its silence to hand out, then the
/// codec to go on; the stop forgotten.
pub fn goOn(stream: *Stream) bool {
    const source = &stream.media;
    if (!source.paused) return false;
    source.paused = false;
    return true;
}

/// The track read from its start again, for the next module to be given
/// the same packets: what was worked out from them forgotten and its
/// first packet held once more. False for a track that cannot be moved
/// back, and for one whose file then fails.
fn restart(stream: *Stream) bool {
    const source = &stream.media;
    const mb = source.base orelse return false;
    const file = source.file orelse return false;
    if (mb.SeekMedia(file, source.track, 0) != media.MERR_OK) return false;
    source.rate = 0;
    source.delay = 0;
    source.exact = false;
    source.total = 0;
    source.done = false;
    source.skip_until = 0;
    source.position = 0;
    source.placed = false;
    source.start = 0;
    source.gap = 0;
    source.held = .{};
    source.holding = false;
    source.paused = false;
    source.last_ticks = 0;
    return hold(stream) or !stream.failed;
}

/// The track's next packet read into `held`, for `next` to hand out;
/// false at the end, or when the file fails (`failed` then set).
fn hold(stream: *Stream) bool {
    const source = &stream.media;
    source.held = .{};
    source.holding = false;
    const result = source.base.?.ReadMediaPacket(source.file.?, source.track, &source.held);
    if (result == media.MERR_OK) {
        source.holding = true;
        return true;
    }
    if (result != media.MERR_END) stream.failed = true;
    return false;
}

/// The frames of silence from `frame` to `begins`, where the sound begins
/// after it - none past the length.
fn gapOf(source: *const Source, frame: i64, begins: i64) i64 {
    const until = if (source.exact) @min(begins, source.total) else begins;
    return @max(0, until - frame);
}

/// Up to `frames` of the silence before the sound into `buffer`; how
/// many.
pub fn silence(stream: *Stream, buffer: [*]i16, frames: u32) u32 {
    const source = &stream.media;
    if (source.gap <= 0) return 0;
    const count: u32 = @intCast(@min(source.gap, frames));
    if (count == 0) return 0;
    const bytes = @as(usize, count) * stream.info.channels * @sizeOf(i16);
    stream.base.sys_base.SetMem(buffer, 0, bytes);
    source.gap -= count;
    return count;
}

/// Of `count` frames a packet decoded, which begin at frame `start` of
/// the sound, the ones handed out: those before a seek's frame passed
/// over, those past the length cut. Null for none.
pub fn window(source: *Source, start: i64, count: u32) ?Span {
    var last: i64 = count;
    if (source.exact) {
        if (start + count >= source.total) source.done = true;
        last = @min(last, source.total - start);
    }
    const first: i64 = @max(0, source.skip_until - start);
    if (first >= last) return null;
    return .{ .first = @intCast(first), .last = @intCast(last) };
}

pub const Span = struct { first: u32, last: u32 };

/// The track moved for `frame` - held to the length - `early` frames
/// before it: the codec decodes from there, and the frames before
/// `frame` are passed over.
pub fn seek(stream: *Stream, frame: u32, early: u32) i32 {
    const source = &stream.media;
    const target: i64 = if (source.exact) @min(frame, source.total) else frame;
    const from = target - early;
    const time: i64 = @intCast(@divFloor(@as(i128, from) * 1_000_000, source.rate));
    const result = source.base.?.SeekMedia(source.file.?, source.track, time);
    if (result == media.MERR_NOSEEK) return ac.ACERR_NOSEEK;
    if (result != media.MERR_OK) return ac.ACERR_READ;
    source.skip_until = @max(target, source.start);
    source.done = false;
    source.placed = false;
    source.paused = false;
    stream.failed = false;
    // The packet landed on, and silence up to it where the sound begins
    // after the frame asked for.
    source.gap = 0;
    if (hold(stream)) {
        const landed = framesOf(source, @intCast(@min(source.held.ticks, std.math.maxInt(i64)))) - source.delay;
        source.gap = gapOf(source, target, @max(landed, source.start));
    }
    return ac.ACERR_OK;
}

/// The file's tags as the stream's: the names, the numbers, the chapters,
/// and the cover copied when the stream keeps one.
fn tagsOf(stream: *Stream, mb: *MediaBase, file: *media.MediaFile) void {
    const tags = &stream.tags;
    var title: [*:0]const u8 = "";
    var artist: [*:0]const u8 = "";
    var album: [*:0]const u8 = "";
    var album_artist: [*:0]const u8 = "";
    var composer: [*:0]const u8 = "";
    var genre: [*:0]const u8 = "";
    var comment: [*:0]const u8 = "";
    var chapters: u32 = 0;
    var list: ?[*]const media.MediaChapter = null;
    var picture: ?*const media.MediaPicture = null;
    _ = mb.GetMediaAttrs(file, &[_]utility.TagItem{
        .{ .tag = media.MDA_Title, .data = @intFromPtr(&title) },
        .{ .tag = media.MDA_Artist, .data = @intFromPtr(&artist) },
        .{ .tag = media.MDA_Album, .data = @intFromPtr(&album) },
        .{ .tag = media.MDA_AlbumArtist, .data = @intFromPtr(&album_artist) },
        .{ .tag = media.MDA_Composer, .data = @intFromPtr(&composer) },
        .{ .tag = media.MDA_Genre, .data = @intFromPtr(&genre) },
        .{ .tag = media.MDA_Comment, .data = @intFromPtr(&comment) },
        .{ .tag = media.MDA_Year, .data = @intFromPtr(&tags.year) },
        .{ .tag = media.MDA_Track, .data = @intFromPtr(&tags.track) },
        .{ .tag = media.MDA_Tracks, .data = @intFromPtr(&tags.tracks) },
        .{ .tag = media.MDA_Chapters, .data = @intFromPtr(&chapters) },
        .{ .tag = media.MDA_ChapterList, .data = @intFromPtr(&list) },
        .{ .tag = media.MDA_Picture, .data = @intFromPtr(&picture) },
        .{},
    });
    _stream.copyName(&tags.title, _stream.upToNul(title));
    _stream.copyName(&tags.artist, _stream.upToNul(artist));
    _stream.copyName(&tags.album, _stream.upToNul(album));
    _stream.copyName(&tags.album_artist, _stream.upToNul(album_artist));
    _stream.copyName(&tags.composer, _stream.upToNul(composer));
    _stream.copyName(&tags.genre, _stream.upToNul(genre));
    _stream.copyName(&tags.comment, _stream.upToNul(comment));
    tags.plain_comment = tags.comment[0] != 0;
    const sys = stream.base.sys_base;
    if (chapters != 0 and list != null) {
        const size = chapters * @sizeOf(ac.AudioChapter);
        if (sys.AllocVec(size, exec.MEMF_ANY)) |memory| {
            const into: [*]ac.AudioChapter = @ptrCast(@alignCast(memory));
            for (0..chapters) |n| {
                into[n] = .{ .start = list.?[n].start, .end = list.?[n].end, .title = list.?[n].title };
            }
            tags.chapters = into;
            tags.chapter_count = chapters;
        }
    }
    if (tags.keep_picture) {
        if (picture) |cover| {
            if (sys.AllocVec(cover.size, exec.MEMF_ANY)) |memory| {
                const block: [*]u8 = @ptrCast(memory);
                @memcpy(block[0..cover.size], cover.data[0..cover.size]);
                tags.picture_block = block;
                tags.picture = .{ .data = block, .size = cover.size, .kind = cover.kind, .mime = cover.mime };
            }
        }
    }
}
