// SPDX-License-Identifier: MIT
//! An MP4 - ISO's base media file format, and QuickTime's MOV it comes
//! from - opened: its index found and read, its tracks made out of it.
//!
//! **The file** is a run of boxes, each its size, its kind - four
//! letters - and its body; some hold more boxes. The index is the `moov`
//! box: read whole into memory, wherever it lies in a file. Through a read
//! function the boxes are passed in order, so the index has to come before
//! the packets (`mdat`). A file in fragments - its index in `moof` boxes
//! among the packets, `mvex` in the `moov` saying so - is not read.
//!
//! **A track** (`trak`) is its header (`tkhd`: its number, a picture's
//! size), its media's header (`mdhd`: its timescale, its language), its
//! handler (`hdlr`: pictures, sound or text), its first sample entry
//! (`stsd`: the codec and the setup it wants), its sample tables
//! (`cursor.zig`) and its edits (`elst`): where presenting starts in the
//! track - past an encoder's priming - for how long, and the time of
//! nothing before it. Only the first edit that shows the track is used.
//!
//! The tags - `udta`'s `meta`/`ilst`, the chapters - are `tags.zig`'s.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const _file = @import("../file/_file.zig");
const File = _file.File;
const Track = _file.Track;
const be16 = _file.be16;
const be32 = _file.be32;
const be64 = _file.be64;
const cursor = @import("cursor.zig");
const tags = @import("tags.zig");

/// The largest index read: a film of hours has a few megabytes.
const max_index: u64 = 256 * 1024 * 1024;

/// A box's kind from its four letters.
pub fn kind(comptime letters: *const [4]u8) u32 {
    return @as(u32, letters[0]) << 24 | @as(u32, letters[1]) << 16 | @as(u32, letters[2]) << 8 | letters[3];
}

pub const Box = struct {
    kind: u32,
    body: []const u8,
};

/// The boxes in a run of bytes, one after the other. A box that says it
/// is larger than what is left ends the run.
pub const Boxes = struct {
    rest: []const u8,

    pub fn next(boxes: *Boxes) ?Box {
        const rest = boxes.rest;
        if (rest.len < 8) return null;
        var size: u64 = be32(rest[0..4]);
        var head: usize = 8;
        if (size == 1) {
            if (rest.len < 16) return null;
            size = be64(rest[8..16]);
            head = 16;
        } else if (size == 0) {
            size = rest.len;
        }
        if (size < head or size > rest.len) {
            boxes.rest = &.{};
            return null;
        }
        const length: usize = @intCast(size);
        boxes.rest = rest[length..];
        return .{ .kind = be32(rest[4..8]), .body = rest[head..length] };
    }
};

/// The body of the first box of `wanted` in `bytes`, or null.
pub fn child(bytes: []const u8, wanted: u32) ?[]const u8 {
    var boxes = Boxes{ .rest = bytes };
    while (boxes.next()) |box| {
        if (box.kind == wanted) return box.body;
    }
    return null;
}

/// The kinds a QuickTime file may begin with, besides ISO's `ftyp`.
fn opening(word: u32) bool {
    return switch (word) {
        kind("ftyp"), kind("moov"), kind("mdat"), kind("wide"), kind("free"), kind("skip"), kind("pnot") => true,
        else => false,
    };
}

/// Whether the first bytes of a file are an MP4's: a box of a kind one
/// begins with, and a size that fits.
pub fn identify(bytes: []const u8) bool {
    if (bytes.len < 8) return false;
    const size = be32(bytes[0..4]);
    if (size != 1 and size < 8) return false;
    return opening(be32(bytes[4..8]));
}

/// The file's index found and read, its tracks and tags made out of it;
/// with `check`, MERR_UNKNOWN when its first box is not an MP4's.
pub fn open(file: *File, check: bool) i32 {
    const sys = file.base.sys_base;
    var at: u64 = 0;
    var header: [16]u8 = undefined;
    while (file.index == null) {
        if (file.size != 0 and at + 8 > file.size) break;
        if (!_file.readAt(file, at, header[0..8])) break;
        if (at == 0 and check and !identify(header[0..8])) return media.MERR_UNKNOWN;
        var size: u64 = be32(header[0..4]);
        const box = be32(header[4..8]);
        var head: u64 = 8;
        if (size == 1) {
            if (!_file.readAt(file, at + 8, header[8..16])) return media.MERR_CORRUPT;
            size = be64(header[8..16]);
            head = 16;
        } else if (size == 0) {
            // To the end of the file.
            if (file.size == 0) {
                if (box != kind("moov")) break;
                return media.MERR_UNSUPPORTED;
            }
            size = file.size - at;
        }
        if (size < head) return media.MERR_CORRUPT;
        switch (box) {
            kind("moov") => {
                const length = size - head;
                if (length > max_index) return media.MERR_UNSUPPORTED;
                const memory = sys.AllocVec(@intCast(length), exec.MEMF_ANY) orelse return media.MERR_NOMEMORY;
                file.index = @ptrCast(memory);
                file.index_size = @intCast(length);
                if (!_file.readAt(file, at + head, file.index.?[0..file.index_size])) return media.MERR_READ;
            },
            // Through a read function the packets would be passed before
            // the index is known.
            kind("mdat") => if (!_file.seekable(file)) return media.MERR_UNSUPPORTED,
            else => {},
        }
        at += size;
    }
    if (file.index == null) return if (at == 0) media.MERR_READ else media.MERR_CORRUPT;
    return movie(file);
}

/// The tracks and the tags out of the index.
fn movie(file: *File) i32 {
    const index = file.index.?[0..file.index_size];
    if (child(index, kind("mvex")) != null) return media.MERR_UNSUPPORTED;
    var duration: u64 = 0;
    if (child(index, kind("mvhd"))) |mvhd| {
        if (mvhd.len >= 20 and mvhd[0] == 0) {
            file.movie_timescale = be32(mvhd[12..16]);
            duration = be32(mvhd[16..20]);
        } else if (mvhd.len >= 32) {
            file.movie_timescale = be32(mvhd[20..24]);
            duration = be64(mvhd[24..32]);
        }
    }
    var boxes = Boxes{ .rest = index };
    while (boxes.next()) |box| {
        if (box.kind != kind("trak") or file.track_count == _file.max_tracks) continue;
        const track = &file.tracks[file.track_count];
        if (makeTrack(file, box.body, track)) file.track_count += 1;
    }

    const info = &file.info;
    info.kind = media.MEDIA_MP4;
    info.tracks = file.track_count;
    info.seekable = @intFromBool(_file.seekable(file));
    info.duration = @intCast(@max(0, _file.micros(@intCast(duration), file.movie_timescale)));
    for (file.tracks[0..file.track_count], 0..) |*track, n| {
        info.duration = @max(info.duration, track.info.duration);
        if (track.info.kind == media.MTRACK_VIDEO and info.video == ~@as(u32, 0)) info.video = @intCast(n);
        if (track.info.kind == media.MTRACK_AUDIO and info.audio == ~@as(u32, 0)) info.audio = @intCast(n);
    }
    tags.read(file, index);
    _file.copyName(&info.title, &file.tags.title);
    _file.copyName(&info.artist, &file.tags.artist);
    _file.copyName(&info.album, &file.tags.album);
    return media.MERR_OK;
}

/// A track out of its `trak` box: false for one with no media in it.
fn makeTrack(file: *File, trak: []const u8, track: *Track) bool {
    const out = &track.info;
    if (child(trak, kind("tkhd"))) |tkhd| {
        if (tkhd.len >= 84 and tkhd[0] == 0) {
            out.id = be32(tkhd[12..16]);
            out.width = be32(tkhd[76..80]) >> 16;
            out.height = be32(tkhd[80..84]) >> 16;
        } else if (tkhd.len >= 96) {
            out.id = be32(tkhd[20..24]);
            out.width = be32(tkhd[88..92]) >> 16;
            out.height = be32(tkhd[92..96]) >> 16;
        }
    }
    if (child(trak, kind("tref"))) |tref| {
        if (child(tref, kind("chap"))) |chap| {
            if (chap.len >= 4) track.chapter_ref = be32(chap[0..4]);
        }
    }
    const mdia = child(trak, kind("mdia")) orelse return false;
    const mdhd = child(mdia, kind("mdhd")) orelse return false;
    var language: u16 = 0;
    if (mdhd.len >= 24 and mdhd[0] == 0) {
        out.timescale = be32(mdhd[12..16]);
        language = be16(mdhd[20..22]);
    } else if (mdhd.len >= 34) {
        out.timescale = be32(mdhd[20..24]);
        language = be16(mdhd[32..34]);
    } else return false;
    if (out.timescale == 0) return false;
    languageOf(language, &out.language);

    if (child(mdia, kind("hdlr"))) |hdlr| {
        if (hdlr.len >= 12) {
            out.kind = switch (be32(hdlr[8..12])) {
                kind("vide") => media.MTRACK_VIDEO,
                kind("soun") => media.MTRACK_AUDIO,
                kind("text"), kind("sbtl"), kind("subt") => media.MTRACK_TEXT,
                else => media.MTRACK_OTHER,
            };
        }
        if (hdlr.len > 24) handlerName(hdlr[24..], &out.name);
    }
    const minf = child(mdia, kind("minf")) orelse return false;
    const stbl = child(minf, kind("stbl")) orelse return false;
    if (child(stbl, kind("stsd"))) |stsd| sampleEntry(track, stsd);
    readTables(&track.tables, stbl);
    if (!track.tables.sound()) track.tables = .{};

    const t = &track.tables;
    out.packets = t.samples;
    const total = cursor.totalTicks(t);
    edits(file, trak, track, total);
    out.duration = @intCast(_file.micros(@intCast(out.length), out.timescale) + track.empty_us);
    var bytes: u64 = 0;
    var largest: u32 = 0;
    for (0..t.samples) |n| {
        const size = t.sizeOf(@intCast(n));
        bytes += size;
        largest = @max(largest, size);
    }
    out.max_packet = largest;
    if (total != 0) {
        if (out.bitrate == 0) out.bitrate = @intCast(@min(bytes * 8 * out.timescale / total, std.math.maxInt(u32)));
        if (out.kind == media.MTRACK_VIDEO) out.frame_rate = @intCast(@min(@as(u64, t.samples) * 1000 * out.timescale / total, std.math.maxInt(u32)));
    }
    cursor.reset(t, &track.at);
    return true;
}

/// Where presenting starts in the track and for how long, from its edits:
/// edits of nothing before it are time before the track begins; the
/// first that shows the track says where in it, and for how long in the
/// movie's timescale. Without edits, all of it from the start - or what
/// iTunes's own note of the priming says.
fn edits(file: *File, trak: []const u8, track: *Track, total: u64) void {
    const out = &track.info;
    var start: i64 = 0;
    var length: ?u64 = null;
    var empty: u64 = 0;
    const elst = if (child(trak, kind("edts"))) |edts| child(edts, kind("elst")) else null;
    if (elst) |list| {
        if (list.len >= 8) {
            const wide = list[0] == 1;
            const size: usize = if (wide) 20 else 12;
            const count = be32(list[4..8]);
            var n: usize = 0;
            while (n < count and 8 + (n + 1) * size <= list.len) : (n += 1) {
                const entry = list[8 + n * size ..];
                const span: u64 = if (wide) be64(entry[0..8]) else be32(entry[0..4]);
                const time: i64 = if (wide) @bitCast(be64(entry[8..16])) else @as(i32, @bitCast(be32(entry[4..8])));
                if (time == -1) {
                    empty += span;
                    continue;
                }
                start = time;
                if (span != 0 and file.movie_timescale != 0) {
                    length = (span * out.timescale + file.movie_timescale / 2) / file.movie_timescale;
                }
                break;
            }
        }
    }
    if (elst == null and out.kind == media.MTRACK_AUDIO) {
        if (tags.priming(file.index.?[0..file.index_size])) |gap| {
            start = gap.delay;
            length = gap.length;
        }
    }
    if (start < 0) start = 0;
    track.media_start = start;
    track.empty_us = _file.micros(@intCast(empty), file.movie_timescale);
    out.delay = @intCast(@min(start, std.math.maxInt(u32)));
    // What is left after the start: frames shown after they are decoded
    // (`ctts`) are shown up to the start's ticks later, so for them the
    // decode times' whole length.
    const rest: u64 = if (track.tables.ctts.len != 0) total else total -| @as(u64, @intCast(start));
    out.length = if (length) |presented| @min(presented, rest) else rest;
}

/// ISO 639-2 from the three letters mdhd packs in five bits each; "und"
/// for none, or QuickTime's numbers of a Macintosh language.
fn languageOf(packed_letters: u16, into: *[4]u8) void {
    if (packed_letters < 0x400) {
        const code = if (packed_letters < macintosh_languages.len) macintosh_languages[packed_letters] else "und";
        into.* = (code ++ "\x00").*;
        return;
    }
    if (packed_letters == 0x7FFF) {
        into.* = "und\x00".*;
        return;
    }
    into[0] = @intCast(((packed_letters >> 10) & 0x1F) + 0x60);
    into[1] = @intCast(((packed_letters >> 5) & 0x1F) + 0x60);
    into[2] = @intCast((packed_letters & 0x1F) + 0x60);
    into[3] = 0;
}

/// QuickTime's first Macintosh languages, by number, in ISO 639-2.
const macintosh_languages = [_]*const [3]u8{
    "eng", "fra", "deu", "ita", "nld", "swe", "spa", "dan", "por", "nor",
    "heb", "jpn", "ara", "fin", "ell", "isl", "mlt", "tur", "hrv", "zho",
    "urd", "hin", "tha", "kor", "lit", "pol", "hun", "est", "lav", "sme",
};

/// A handler's name: NUL-terminated in an MP4, a counted string in a MOV.
fn handlerName(bytes: []const u8, into: *[64]u8) void {
    var text = bytes;
    if (text.len > 0 and text[0] == text.len - 1) text = text[1..];
    _file.copyUtf8(into, text);
}

/// The sample tables of a track's `stbl`, where they lie.
fn readTables(t: *cursor.Tables, stbl: []const u8) void {
    t.stts = entries(child(stbl, kind("stts")), 8, 8);
    t.ctts = entries(child(stbl, kind("ctts")), 8, 8);
    t.stsc = entries(child(stbl, kind("stsc")), 8, 12);
    if (child(stbl, kind("stco"))) |stco| {
        t.chunks = entries(stco, 8, 4);
        t.chunk_count = @intCast(t.chunks.len / 4);
    } else if (child(stbl, kind("co64"))) |co64| {
        t.chunks = entries(co64, 8, 8);
        t.chunk_count = @intCast(t.chunks.len / 8);
        t.wide_chunks = true;
    }
    if (child(stbl, kind("stss"))) |stss| {
        t.syncs = entries(stss, 8, 4);
        t.has_syncs = true;
    }
    if (child(stbl, kind("stsz"))) |stsz| {
        if (stsz.len < 12) return;
        t.fixed_size = be32(stsz[4..8]);
        t.samples = be32(stsz[8..12]);
        t.sizes = stsz[12..];
        t.size_bits = 32;
    } else if (child(stbl, kind("stz2"))) |stz2| {
        if (stz2.len < 12) return;
        t.size_bits = stz2[7];
        if (t.size_bits != 4 and t.size_bits != 8 and t.size_bits != 16) return;
        t.samples = be32(stz2[8..12]);
        t.sizes = stz2[12..];
    }
}

/// A table's entries: its body past the version, the flags and the count,
/// as many whole entries as the count says and the body holds.
fn entries(body: ?[]const u8, head: usize, size: usize) []const u8 {
    const table = body orelse return &.{};
    if (table.len < head) return &.{};
    const count: usize = be32(table[head - 4 .. head]);
    const room = (table.len - head) / size;
    return table[head..][0 .. @min(count, room) * size];
}

/// The codec of a track's first sample entry, and what it says of the
/// picture or the sound.
fn sampleEntry(track: *Track, stsd: []const u8) void {
    if (stsd.len < 8 or be32(stsd[4..8]) == 0) return;
    var boxes = Boxes{ .rest = stsd[8..] };
    const entry = boxes.next() orelse return;
    switch (track.info.kind) {
        media.MTRACK_AUDIO => soundEntry(&track.info, entry.kind, entry.body),
        media.MTRACK_VIDEO => pictureEntry(&track.info, entry.kind, entry.body),
        media.MTRACK_TEXT => {
            if (entry.kind == kind("tx3g") or entry.kind == kind("text")) track.info.codec = media.MCODEC_TEXT;
        },
        else => {},
    }
}

/// A sound's sample entry: its channels, its bits and its rate - in the
/// layout of each of QuickTime's versions - and its codec's own box.
fn soundEntry(out: *media.MediaTrack, format: u32, body: []const u8) void {
    if (body.len < 28) return;
    const version = be16(body[8..10]);
    out.channels = be16(body[16..18]);
    out.bits = be16(body[18..20]);
    out.rate = be32(body[24..28]) >> 16;
    var extra: usize = 28;
    if (version == 1) extra = 44;
    if (version == 2 and body.len >= 64) {
        extra = 64;
        out.rate = @intFromFloat(@as(f64, @bitCast(be64(body[32..40]))));
        out.channels = be32(body[40..44]);
        out.bits = be32(body[48..52]);
    }
    if (out.rate == 0) out.rate = out.timescale;
    const children = if (body.len >= extra) body[extra..] else &[_]u8{};
    switch (format) {
        kind("mp4a") => {
            var esds = child(children, kind("esds"));
            if (esds == null) {
                if (child(children, kind("wave"))) |wave| esds = child(wave, kind("esds"));
            }
            if (esds) |box| elementary(out, box);
            if (out.codec == media.MCODEC_AAC) out.bits = 0;
        },
        kind(".mp3") => {
            out.codec = media.MCODEC_MP3;
            out.bits = 0;
        },
        kind("alac") => {
            out.codec = media.MCODEC_ALAC;
            if (child(children, kind("alac"))) |cookie| setup(out, cookie, 4);
        },
        kind("ac-3") => out.codec = media.MCODEC_AC3,
        kind("ec-3") => out.codec = media.MCODEC_EAC3,
        kind("Opus") => {
            out.codec = media.MCODEC_OPUS;
            if (child(children, kind("dOps"))) |dops| setup(out, dops, 0);
        },
        kind("fLaC") => {
            out.codec = media.MCODEC_FLAC;
            if (child(children, kind("dfLa"))) |dfla| setup(out, dfla, 4);
        },
        else => {},
    }
}

/// A picture's sample entry: its size, and its codec's setup box.
fn pictureEntry(out: *media.MediaTrack, format: u32, body: []const u8) void {
    if (body.len < 78) return;
    const width = be16(body[24..26]);
    const height = be16(body[26..28]);
    if (width != 0) out.width = width;
    if (height != 0) out.height = height;
    const children = body[78..];
    switch (format) {
        kind("avc1"), kind("avc3") => {
            out.codec = media.MCODEC_H264;
            if (child(children, kind("avcC"))) |avcc| setup(out, avcc, 0);
        },
        kind("hvc1"), kind("hev1") => {
            out.codec = media.MCODEC_H265;
            if (child(children, kind("hvcC"))) |hvcc| setup(out, hvcc, 0);
        },
        kind("mp4v") => {
            out.codec = media.MCODEC_MPEG4V;
            if (child(children, kind("esds"))) |esds| elementary(out, esds);
        },
        kind("jpeg"), kind("mjpa"), kind("mjpb"), kind("MJPG") => out.codec = media.MCODEC_MJPEG,
        else => {},
    }
}

/// A box's body, past `skip` bytes of its own header, as the setup.
fn setup(out: *media.MediaTrack, body: []const u8, skip: usize) void {
    if (body.len <= skip) return;
    out.config = body[skip..].ptr;
    out.config_size = @intCast(body.len - skip);
}

/// An `esds` box: the elementary stream's descriptor, the decoder's
/// config in it - what codec, at what rate - and the codec's own setup
/// in that.
fn elementary(out: *media.MediaTrack, esds: []const u8) void {
    if (esds.len < 4) return;
    var at: usize = 4;
    var descriptor = descriptorAt(esds, &at) orelse return;
    if (descriptor.tag == 0x03) {
        // ES_Descriptor: its number, its flags, what they add.
        const body = descriptor.body;
        if (body.len < 3) return;
        var inner: usize = 3;
        const flags = body[2];
        if (flags & 0x80 != 0) inner += 2;
        if (flags & 0x40 != 0) {
            if (inner >= body.len) return;
            inner += 1 + @as(usize, body[inner]);
        }
        if (flags & 0x20 != 0) inner += 2;
        if (inner > body.len) return;
        descriptor = descriptorAt(body, &inner) orelse return;
    }
    if (descriptor.tag != 0x04 or descriptor.body.len < 13) return;
    const config = descriptor.body;
    out.codec = switch (config[0]) {
        0x40, 0x66, 0x67, 0x68 => media.MCODEC_AAC,
        0x69, 0x6B => media.MCODEC_MP3,
        0xA5 => media.MCODEC_AC3,
        0xA6 => media.MCODEC_EAC3,
        0x20 => media.MCODEC_MPEG4V,
        0x6C => media.MCODEC_MJPEG,
        else => out.codec,
    };
    const average = be32(config[9..13]);
    if (average != 0) out.bitrate = average;
    var inner: usize = 13;
    if (descriptorAt(config, &inner)) |specific| {
        if (specific.tag == 0x05 and specific.body.len > 0) {
            out.config = specific.body.ptr;
            out.config_size = @intCast(specific.body.len);
        }
    }
}

const Descriptor = struct {
    tag: u8,
    body: []const u8,
};

/// The descriptor at `at`: its tag, its length in up to four bytes of
/// seven bits, its body; `at` moved past it.
fn descriptorAt(bytes: []const u8, at: *usize) ?Descriptor {
    if (at.* >= bytes.len) return null;
    const tag = bytes[at.*];
    at.* += 1;
    var length: usize = 0;
    for (0..4) |_| {
        if (at.* >= bytes.len) return null;
        const byte = bytes[at.*];
        at.* += 1;
        length = length << 7 | (byte & 0x7F);
        if (byte & 0x80 == 0) break;
    }
    if (at.* + length > bytes.len) return null;
    const body = bytes[at.*..][0..length];
    at.* += length;
    return .{ .tag = tag, .body = body };
}
