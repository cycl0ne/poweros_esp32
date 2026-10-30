// SPDX-License-Identifier: MIT
//! A Matroska file - and WebM, which is one - opened: its EBML header
//! checked, then its segment's elements read up to the first cluster,
//! and those its seek heads say lie behind the clusters: its info (the
//! clock, the length, the title), its tracks, its cues, its tags and its
//! chapters (`tags.zig`). A file read through a function gives only what
//! comes before its clusters.
//!
//! **The tracks** are read whole into memory - the index - where the
//! setups their codecs want lie, handed out as they are: H.264's avcC,
//! H.265's hvcC, AAC's AudioSpecificConfig, Vorbis's three headers laced.
//! FLAC's metadata blocks come behind "fLaC", which is left out; Opus's
//! OpusHead is made the dOps an MP4 has; an old file's AAC that names its
//! profile in its codec and has no setup is given one, made from the
//! profile, the rate and the channels. Each track's number, its unique
//! number and how long its frames last are kept for its walk
//! (`blocks.zig`). A track whose frames leave out the bytes each begins
//! with keeps them; one compressed otherwise, or encrypted, is listed and
//! not read.
//!
//! **The cues** are read into a table of their own: each point's time,
//! the track it names, where its cluster begins and where in it the
//! block lies.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const _file = @import("../file/_file.zig");
const File = _file.File;
const Track = _file.Track;
const ebml = @import("ebml.zig");
const blocks = @import("blocks.zig");
const tags = @import("tags.zig");

/// The largest element read into memory: tracks, cues, tags, chapters.
const max_element: u64 = 16 * 1024 * 1024;

/// Whether the first bytes of a file are a Matroska file's: EBML's
/// header, its DocType "matroska" or "webm" where the bytes reach it.
pub fn identify(bytes: []const u8) bool {
    if (bytes.len < 4 or _file.be32(bytes[0..4]) != ebml.EBML) return false;
    const h = ebml.head(bytes) orelse return true;
    if (h.size == ebml.unknown) return false;
    const end: usize = @intCast(@min(bytes.len, h.length + h.size));
    var elements = ebml.Elements{ .rest = bytes[h.length..end] };
    while (elements.next()) |element| {
        if (element.id == ebml.DocType and h.length + h.size <= bytes.len) return matroska(element.body);
    }
    return true;
}

fn matroska(doc_type: []const u8) bool {
    const name = ebml.string(doc_type);
    return std.mem.eql(u8, name, "matroska") or std.mem.eql(u8, name, "webm");
}

/// An element read whole into memory of its own: where it lies, and its
/// body once read.
const Part = struct {
    at: u64 = 0,
    body: ?[*]u8 = null,
    size: usize = 0,

    fn bytes(part: *const Part) []const u8 {
        return if (part.body) |body| body[0..part.size] else &.{};
    }
};

/// The elements the file is opened from.
const Parts = struct {
    info: Part = .{},
    tracks: Part = .{},
    cues: Part = .{},
    tags: Part = .{},
    chapters: Part = .{},
    /// The seek head a seek head points to, read once.
    more_seeks: u64 = 0,

    fn of(parts: *Parts, id: u32) ?*Part {
        return switch (id) {
            ebml.Info => &parts.info,
            ebml.Tracks => &parts.tracks,
            ebml.Cues => &parts.cues,
            ebml.Tags => &parts.tags,
            ebml.Chapters => &parts.chapters,
            else => null,
        };
    }

    fn free(parts: *Parts, sys: anytype) void {
        for ([_]*Part{ &parts.info, &parts.tracks, &parts.cues, &parts.tags, &parts.chapters }) |part| {
            if (part.body) |body| sys.FreeVec(body);
            part.body = null;
        }
    }
};

/// The head of the element at `at`, read from the file - and kept for a
/// read function, for the cluster the opening stops at.
fn headAt(file: *File, at: u64) ?ebml.Head {
    var bytes: [ebml.max_head]u8 = undefined;
    var want: usize = bytes.len;
    if (file.size != 0) want = @intCast(@min(want, file.size -| at));
    const got = _file.readSome(file, at, bytes[0..want]);
    _file.keep(file, at, bytes[0..got]);
    return ebml.head(bytes[0..got]);
}

/// The file's header, segment, tracks, cues and tags read.
pub fn open(file: *File) i32 {
    const sys = file.base.sys_base;
    const m = &file.mkv;
    m.scale = 1_000_000;

    // EBML's header, and what it says the file is.
    const header = headAt(file, 0) orelse return media.MERR_UNKNOWN;
    if (header.id != ebml.EBML or header.size == ebml.unknown or header.size > 256) return media.MERR_UNKNOWN;
    var said: [256]u8 = undefined;
    const said_size: usize = @intCast(header.size);
    if (!_file.readAt(file, header.length, said[0..said_size])) return media.MERR_READ;
    if (!matroska(ebml.child(said[0..said_size], ebml.DocType) orelse "matroska")) return media.MERR_UNKNOWN;

    // The segment, past what may stand before it.
    var at: u64 = header.length + header.size;
    const segment = while (true) {
        const h = headAt(file, at) orelse return media.MERR_CORRUPT;
        if (h.id == ebml.Segment) break h;
        if (h.size == ebml.unknown) return media.MERR_CORRUPT;
        at += h.length + h.size;
    };
    m.segment_at = at + segment.length;
    m.segment_end = if (segment.size == ebml.unknown) std.math.maxInt(u64) else m.segment_at + segment.size;
    if (file.size != 0) m.segment_end = @min(m.segment_end, file.size);
    m.first_cluster = m.segment_end;

    var parts: Parts = .{};
    defer parts.free(sys);
    const result = gather(file, &parts);
    if (result != media.MERR_OK) return result;
    if (parts.tracks.body == null) return media.MERR_CORRUPT;
    // The tracks are the index: the setups they hand out lie in it.
    file.index = parts.tracks.body;
    file.index_size = parts.tracks.size;
    parts.tracks.body = null;

    var duration: f64 = 0;
    var title: [_file.name_bytes]u8 = @splat(0);
    readInfo(file, parts.info.bytes(), &duration, &title);
    const info = &file.info;
    info.kind = media.MEDIA_MKV;
    info.seekable = @intFromBool(_file.seekable(file));
    info.duration = @intFromFloat(@max(0, @min(duration * @as(f64, @floatFromInt(m.scale)) / 1000, 1e18)));
    readTracks(file, file.index.?[0..file.index_size], duration);
    readCues(file, parts.cues.bytes());
    tags.read(file, parts.tags.bytes(), parts.chapters.bytes(), &title);

    info.tracks = file.track_count;
    for (file.tracks[0..file.track_count], 0..) |*track, n| {
        info.duration = @max(info.duration, track.info.duration);
        blocks.rewind(file, track);
        const number: u32 = @intCast(n);
        if (track.info.kind == media.MTRACK_VIDEO) choose(file, &info.video, number);
        if (track.info.kind == media.MTRACK_AUDIO) choose(file, &info.audio, number);
    }
    file.subtitles = markedText(file);
    _file.copyName(&info.title, &file.tags.title);
    _file.copyName(&info.artist, &file.tags.artist);
    _file.copyName(&info.album, &file.tags.album);
    return media.MERR_OK;
}

/// A track of its kind for the info: the first marked to be played,
/// else the first.
fn choose(file: *File, chosen: *u32, number: u32) void {
    const marked = file.tracks[number].mkv.default;
    if (chosen.* == ~@as(u32, 0)) {
        chosen.* = number;
    } else if (marked and !file.tracks[chosen.*].mkv.default) {
        chosen.* = number;
    }
}

/// The text track the file marks to be shown: the first marked forced and
/// to be played, else the first marked to be played; ~0 for none.
fn markedText(file: *const File) u32 {
    var marked: u32 = ~@as(u32, 0);
    for (file.tracks[0..file.track_count], 0..) |*track, n| {
        if (track.info.kind != media.MTRACK_TEXT or !track.mkv.default) continue;
        if (track.mkv.forced) return @intCast(n);
        if (marked == ~@as(u32, 0)) marked = @intCast(n);
    }
    return marked;
}

/// The segment's elements read up to the first cluster, and then those
/// the seek heads say lie elsewhere, where the file can seek.
fn gather(file: *File, parts: *Parts) i32 {
    const m = &file.mkv;
    var at = m.segment_at;
    while (at < m.segment_end) {
        const h = headAt(file, at) orelse break;
        if (h.id == ebml.Cluster) {
            m.first_cluster = at;
            break;
        }
        if (h.size == ebml.unknown) return media.MERR_CORRUPT;
        if (h.id == ebml.SeekHead) {
            const result = seekHead(file, parts, at, h);
            if (result != media.MERR_OK) return result;
        } else if (parts.of(h.id)) |part| {
            if (part.body == null) {
                part.at = at;
                const result = readPart(file, part, at, h);
                if (result != media.MERR_OK) return result;
            }
        }
        at += h.length + h.size;
    }
    if (!_file.seekable(file)) return media.MERR_OK;
    if (parts.more_seeks != 0) {
        const more = parts.more_seeks;
        if (headAt(file, more)) |h| {
            if (h.id == ebml.SeekHead and h.size != ebml.unknown) {
                const result = seekHead(file, parts, more, h);
                if (result != media.MERR_OK) return result;
            }
        }
    }
    for ([_]u32{ ebml.Info, ebml.Tracks, ebml.Cues, ebml.Tags, ebml.Chapters }) |id| {
        const part = parts.of(id).?;
        if (part.body != null or part.at == 0) continue;
        const h = headAt(file, part.at) orelse continue;
        if (h.id != id or h.size == ebml.unknown) continue;
        const result = readPart(file, part, part.at, h);
        if (result != media.MERR_OK) return result;
    }
    // No cluster found on the way - an element in front of them that
    // could not be read: the first the cues name.
    if (m.first_cluster == m.segment_end) {
        var elements = ebml.Elements{ .rest = parts.cues.bytes() };
        while (elements.next()) |point| {
            const track = ebml.child(point.body, ebml.CueTrackPositions) orelse continue;
            const cluster = ebml.child(track, ebml.CueClusterPosition) orelse continue;
            m.first_cluster = m.segment_at + ebml.uint(cluster);
            break;
        }
    }
    return media.MERR_OK;
}

/// An element's body read into memory of its own.
fn readPart(file: *File, part: *Part, at: u64, h: ebml.Head) i32 {
    if (h.size > max_element) return media.MERR_OK;
    const size: usize = @intCast(h.size);
    const memory = file.base.sys_base.AllocVec(@max(size, 1), exec.MEMF_ANY) orelse return media.MERR_NOMEMORY;
    part.body = @ptrCast(memory);
    part.size = size;
    if (!_file.readAt(file, at + h.length, part.body.?[0..size])) {
        file.base.sys_base.FreeVec(memory);
        part.body = null;
        return media.MERR_READ;
    }
    return media.MERR_OK;
}

/// A seek head: where the elements it names lie, from the segment's body.
fn seekHead(file: *File, parts: *Parts, at: u64, h: ebml.Head) i32 {
    if (h.size > max_element) return media.MERR_OK;
    var part: Part = .{};
    const result = readPart(file, &part, at, h);
    if (result != media.MERR_OK) return result;
    defer file.base.sys_base.FreeVec(part.body.?);
    var seeks = ebml.Elements{ .rest = part.bytes() };
    while (seeks.next()) |seek| {
        if (seek.id != ebml.Seek) continue;
        const id_bytes = ebml.child(seek.body, ebml.SeekID) orelse continue;
        const position = ebml.child(seek.body, ebml.SeekPosition) orelse continue;
        const id: u32 = @truncate(ebml.uint(id_bytes));
        const where = file.mkv.segment_at + ebml.uint(position);
        if (id == ebml.SeekHead) {
            if (where != at and parts.more_seeks == 0) parts.more_seeks = where;
        } else if (parts.of(id)) |named| {
            if (named.at == 0) named.at = where;
        }
    }
    return media.MERR_OK;
}

/// The segment's info: its clock, its length in its ticks, its title.
fn readInfo(file: *File, info: []const u8, duration: *f64, title: *[_file.name_bytes]u8) void {
    var elements = ebml.Elements{ .rest = info };
    while (elements.next()) |element| switch (element.id) {
        ebml.TimestampScale => {
            const scale = ebml.uint(element.body);
            if (scale != 0) file.mkv.scale = scale;
        },
        ebml.Duration => duration.* = ebml.float(element.body),
        ebml.Title => _file.copyUtf8(title, ebml.string(element.body)),
        else => {},
    };
}

/// The tracks out of the Tracks element.
fn readTracks(file: *File, index: []const u8, duration: f64) void {
    var elements = ebml.Elements{ .rest = index };
    while (elements.next()) |entry| {
        if (entry.id != ebml.TrackEntry or file.track_count == _file.max_tracks) continue;
        const track = &file.tracks[file.track_count];
        if (makeTrack(file, entry.body, track, duration)) file.track_count += 1;
    }
}

/// A track out of its TrackEntry: false for one with no number.
fn makeTrack(file: *File, entry: []const u8, track: *Track, duration: f64) bool {
    const m = &file.mkv;
    const own = &track.mkv;
    const out = &track.info;
    own.default = true;
    own.forced = false;
    var enabled = true;
    var kind: u64 = 0;
    var codec: []const u8 = "";
    var private: ?[]const u8 = null;
    var language: []const u8 = "eng";
    var delay_ns: u64 = 0;
    var rate: f64 = 8000;
    var elements = ebml.Elements{ .rest = entry };
    while (elements.next()) |element| switch (element.id) {
        ebml.TrackNumber => own.number = ebml.uint(element.body),
        ebml.TrackUID => own.uid = ebml.uint(element.body),
        ebml.TrackType => kind = ebml.uint(element.body),
        ebml.FlagEnabled => enabled = ebml.uint(element.body) != 0,
        ebml.FlagDefault => own.default = ebml.uint(element.body) != 0,
        ebml.FlagForced => own.forced = ebml.uint(element.body) != 0,
        ebml.DefaultDuration => own.frame_ns = ebml.uint(element.body),
        ebml.Name => _file.copyUtf8(&out.name, ebml.string(element.body)),
        ebml.Language => language = ebml.string(element.body),
        ebml.CodecID => codec = ebml.string(element.body),
        ebml.CodecPrivate => private = element.body,
        ebml.CodecDelay => delay_ns = ebml.uint(element.body),
        ebml.Video => {
            var video = ebml.Elements{ .rest = element.body };
            while (video.next()) |item| switch (item.id) {
                ebml.PixelWidth => out.width = @truncate(ebml.uint(item.body)),
                ebml.PixelHeight => out.height = @truncate(ebml.uint(item.body)),
                else => {},
            };
        },
        ebml.Audio => {
            var audio = ebml.Elements{ .rest = element.body };
            while (audio.next()) |item| switch (item.id) {
                ebml.SamplingFrequency => rate = ebml.float(item.body),
                ebml.Channels => out.channels = @truncate(ebml.uint(item.body)),
                ebml.BitDepth => out.bits = @truncate(ebml.uint(item.body)),
                else => {},
            };
        },
        ebml.ContentEncodings => encodings(own, element.body),
        else => {},
    };
    if (own.number == 0) return false;
    own.default = own.default and enabled;
    out.id = @truncate(own.number);
    out.kind = switch (kind) {
        1 => media.MTRACK_VIDEO,
        2 => media.MTRACK_AUDIO,
        0x11 => media.MTRACK_TEXT,
        else => media.MTRACK_OTHER,
    };
    if (language.len >= 2 and language.len <= 3) {
        @memcpy(out.language[0..language.len], language);
    } else {
        out.language = "und\x00".*;
    }
    if (out.kind == media.MTRACK_AUDIO) {
        out.rate = @intFromFloat(@max(0, @min(rate, 1e9)));
        if (out.channels == 0) out.channels = 1;
    }
    // Sound counts in its rate, so an encoder's priming is so many frames
    // of it; anything else in the file's ticks.
    out.timescale = if (out.kind == media.MTRACK_AUDIO and out.rate != 0)
        out.rate
    else
        @intCast(@max(1, @min(1_000_000_000 / m.scale, std.math.maxInt(u32))));
    codecOf(track, codec, private);
    if (out.kind == media.MTRACK_AUDIO and own.frame_ns == 0) own.frame_ns = soundFrame(out);
    if (out.kind == media.MTRACK_VIDEO and own.frame_ns != 0) {
        out.frame_rate = @intCast(@min(1_000_000_000_000 / own.frame_ns, std.math.maxInt(u32)));
    }
    own.delay_ns = @min(delay_ns, 1_000_000_000_000);
    // Rounded: 23219955 ns are 1024 frames at 44.1 kHz.
    const delay = (@as(u128, own.delay_ns) * out.timescale + 500_000_000) / 1_000_000_000;
    out.delay = @intCast(@min(delay, std.math.maxInt(u32)));
    // The segment lasts to its last block's end, the priming with it:
    // what is presented is the rest.
    const nanos = @max(0, @min(duration, 1e15)) * @as(f64, @floatFromInt(m.scale));
    const presented = @as(u64, @intFromFloat(nanos)) -| own.delay_ns;
    out.length = blocks.ticksOf(presented, out.timescale);
    out.duration = presented / 1000;
    return true;
}

/// How long a frame of sound lasts in nanoseconds, where its codec says
/// how many samples one has: for the times of frames laced in a block.
fn soundFrame(out: *const media.MediaTrack) u64 {
    if (out.rate == 0) return 0;
    const samples: u64 = switch (out.codec) {
        media.MCODEC_AAC => 1024,
        media.MCODEC_AC3, media.MCODEC_EAC3 => 1536,
        media.MCODEC_MP3 => if (out.rate >= 32000) 1152 else 576,
        else => return 0,
    };
    return samples * 1_000_000_000 / out.rate;
}

/// How a track's frames are coded: compressed - only header stripping is
/// read - or encrypted.
fn encodings(own: *blocks.Track, body: []const u8) void {
    var list = ebml.Elements{ .rest = body };
    while (list.next()) |encoding| {
        if (encoding.id != ebml.ContentEncoding) continue;
        var kind: u64 = 0;
        var algorithm: u64 = 0;
        var settings: []const u8 = &.{};
        var items = ebml.Elements{ .rest = encoding.body };
        while (items.next()) |item| switch (item.id) {
            ebml.ContentEncodingType => kind = ebml.uint(item.body),
            ebml.ContentCompression => {
                var compression = ebml.Elements{ .rest = item.body };
                while (compression.next()) |field| switch (field.id) {
                    ebml.ContentCompAlgo => algorithm = ebml.uint(field.body),
                    ebml.ContentCompSettings => settings = field.body,
                    else => {},
                };
            },
            else => {},
        };
        if (kind != 0 or algorithm != 3) {
            own.unreadable = true;
            continue;
        }
        own.strip = settings.ptr;
        own.strip_length = @intCast(settings.len);
    }
}

/// The codec a track's CodecID names, and the setup it hands out.
fn codecOf(track: *Track, id: []const u8, private: ?[]const u8) void {
    const out = &track.info;
    const eql = std.mem.eql;
    const begins = std.mem.startsWith;
    var config = private;
    out.codec = media.MCODEC_UNKNOWN;
    if (eql(u8, id, "V_MPEG4/ISO/AVC")) {
        out.codec = media.MCODEC_H264;
    } else if (eql(u8, id, "V_MPEGH/ISO/HEVC")) {
        out.codec = media.MCODEC_H265;
    } else if (begins(u8, id, "V_MPEG4/ISO/")) {
        out.codec = media.MCODEC_MPEG4V;
    } else if (eql(u8, id, "V_MJPEG")) {
        out.codec = media.MCODEC_MJPEG;
    } else if (eql(u8, id, "V_VP8")) {
        out.codec = media.MCODEC_VP8;
    } else if (eql(u8, id, "V_VP9")) {
        out.codec = media.MCODEC_VP9;
    } else if (eql(u8, id, "V_AV1")) {
        out.codec = media.MCODEC_AV1;
    } else if (eql(u8, id, "V_MS/VFW/FOURCC")) {
        config = windowsPicture(out, private);
    } else if (begins(u8, id, "A_AAC")) {
        out.codec = media.MCODEC_AAC;
        out.bits = 0;
        if (config == null) config = aacConfig(track, id);
    } else if (eql(u8, id, "A_MPEG/L3") or eql(u8, id, "A_MPEG/L2") or eql(u8, id, "A_MPEG/L1")) {
        out.codec = media.MCODEC_MP3;
        out.bits = 0;
    } else if (eql(u8, id, "A_FLAC")) {
        out.codec = media.MCODEC_FLAC;
        if (config) |bytes| {
            if (bytes.len > 4 and eql(u8, bytes[0..4], "fLaC")) config = bytes[4..];
        }
    } else if (eql(u8, id, "A_VORBIS")) {
        out.codec = media.MCODEC_VORBIS;
        out.bits = 0;
    } else if (eql(u8, id, "A_OPUS")) {
        out.codec = media.MCODEC_OPUS;
        out.bits = 0;
        config = if (config) |head| opusSetup(track, head) else null;
    } else if (begins(u8, id, "A_AC3")) {
        out.codec = media.MCODEC_AC3;
        out.bits = 0;
    } else if (eql(u8, id, "A_EAC3")) {
        out.codec = media.MCODEC_EAC3;
        out.bits = 0;
    } else if (begins(u8, id, "A_DTS")) {
        out.codec = media.MCODEC_DTS;
        out.bits = 0;
    } else if (eql(u8, id, "A_ALAC")) {
        out.codec = media.MCODEC_ALAC;
    } else if (eql(u8, id, "A_MS/ACM")) {
        config = windowsSound(out, private);
    } else if (eql(u8, id, "S_TEXT/UTF8")) {
        out.codec = media.MCODEC_SRT;
    } else if (eql(u8, id, "S_TEXT/ASS") or eql(u8, id, "S_TEXT/SSA") or eql(u8, id, "S_ASS") or eql(u8, id, "S_SSA")) {
        out.codec = media.MCODEC_ASS;
    } else if (eql(u8, id, "S_HDMV/PGS")) {
        out.codec = media.MCODEC_PGS;
    }
    if (config) |bytes| {
        if (bytes.len != 0) {
            out.config = bytes.ptr;
            out.config_size = @intCast(bytes.len);
        }
    }
}

/// A picture in Windows's form (BITMAPINFOHEADER): its size, and its
/// codec by its four letters - Motion JPEG, or MPEG-4 Part 2 with its
/// setup behind the header.
fn windowsPicture(out: *media.MediaTrack, private: ?[]const u8) ?[]const u8 {
    const header = private orelse return null;
    if (header.len < 40) return null;
    // The height is below 0 for a picture stored top row first.
    if (out.width == 0) out.width = @abs(std.mem.readInt(i32, header[4..8], .little));
    if (out.height == 0) out.height = @abs(std.mem.readInt(i32, header[8..12], .little));
    const letters = header[16..20];
    for ([_]*const [4]u8{ "MJPG", "mjpg", "AVRn" }) |name| {
        if (std.mem.eql(u8, letters, name)) out.codec = media.MCODEC_MJPEG;
    }
    for ([_]*const [4]u8{ "XVID", "xvid", "DIVX", "divx", "DX50", "FMP4", "MP4V" }) |name| {
        if (std.mem.eql(u8, letters, name)) out.codec = media.MCODEC_MPEG4V;
    }
    return if (out.codec == media.MCODEC_MPEG4V and header.len > 40) header[40..] else null;
}

/// Sound in Windows's form (WAVEFORMATEX): its codec by its number.
fn windowsSound(out: *media.MediaTrack, private: ?[]const u8) ?[]const u8 {
    const format = private orelse return null;
    if (format.len < 2) return null;
    out.codec = switch (@as(u16, format[1]) << 8 | format[0]) {
        0x0055 => media.MCODEC_MP3,
        0x2000 => media.MCODEC_AC3,
        0x2001 => media.MCODEC_DTS,
        else => media.MCODEC_UNKNOWN,
    };
    if (out.codec != media.MCODEC_UNKNOWN) out.bits = 0;
    return null;
}

/// The rates AAC numbers.
const aac_rates = [_]u32{ 96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350 };

/// An AudioSpecificConfig for AAC named by its profile: A_AAC/MPEG4/LC,
/// /MAIN, /SSR, /LTP, /LC/SBR - SBR's core is LC at the track's rate.
fn aacConfig(track: *Track, id: []const u8) ?[]const u8 {
    const out = &track.info;
    const object: u8 = if (std.mem.indexOf(u8, id, "/MAIN") != null)
        1
    else if (std.mem.indexOf(u8, id, "/SSR") != null)
        3
    else if (std.mem.indexOf(u8, id, "/LTP") != null)
        4
    else
        2;
    const index: u8 = for (aac_rates, 0..) |rate, n| {
        if (rate == out.rate) break @intCast(n);
    } else return null;
    const channels: u8 = @intCast(@min(out.channels, 7));
    const made = &track.mkv.made;
    made[0] = object << 3 | index >> 1;
    made[1] = (index & 1) << 7 | channels << 3;
    return made[0..2];
}

/// Opus's OpusHead, little-endian, made the dOps an MP4 has: big-endian,
/// without its name.
fn opusSetup(track: *Track, head: []const u8) ?[]const u8 {
    if (head.len < 19 or !std.mem.eql(u8, head[0..8], "OpusHead")) return null;
    const made = &track.mkv.made;
    const channels = head[9];
    made[0] = 0;
    made[1] = channels;
    made[2] = head[11];
    made[3] = head[10];
    made[4] = head[15];
    made[5] = head[14];
    made[6] = head[13];
    made[7] = head[12];
    made[8] = head[17];
    made[9] = head[16];
    made[10] = head[18];
    if (head[18] == 0) return made[0..11];
    const length = 13 + @as(usize, channels);
    if (head.len < 21 + @as(usize, channels) or length > made.len) return null;
    @memcpy(made[11..length], head[19..][0 .. 2 + @as(usize, channels)]);
    return made[0..length];
}

/// The cue points into a table of their own: one for each track a point
/// names.
fn readCues(file: *File, cues: []const u8) void {
    if (cues.len == 0) return;
    var count: usize = 0;
    var points = ebml.Elements{ .rest = cues };
    while (points.next()) |point| {
        if (point.id != ebml.CuePoint) continue;
        var items = ebml.Elements{ .rest = point.body };
        while (items.next()) |item| {
            if (item.id == ebml.CueTrackPositions) count += 1;
        }
    }
    if (count == 0) return;
    const memory = file.base.sys_base.AllocVec(@intCast(count * @sizeOf(blocks.Cue)), exec.MEMF_ANY) orelse return;
    const table: [*]blocks.Cue = @ptrCast(@alignCast(memory));
    var n: usize = 0;
    points = .{ .rest = cues };
    while (points.next()) |point| {
        if (point.id != ebml.CuePoint) continue;
        const time = ebml.uint(ebml.child(point.body, ebml.CueTime) orelse continue);
        var items = ebml.Elements{ .rest = point.body };
        while (items.next()) |item| {
            if (item.id != ebml.CueTrackPositions or n == count) continue;
            var cue = blocks.Cue{ .time = time, .cluster = 0, .relative = blocks.no_relative, .track = 0 };
            var fields = ebml.Elements{ .rest = item.body };
            while (fields.next()) |field| switch (field.id) {
                ebml.CueTrack => cue.track = ebml.uint(field.body),
                ebml.CueClusterPosition => cue.cluster = ebml.uint(field.body),
                ebml.CueRelativePosition => cue.relative = ebml.uint(field.body),
                else => {},
            };
            table[n] = cue;
            n += 1;
        }
    }
    file.mkv.cues = table;
    file.mkv.cue_count = @intCast(n);
}
