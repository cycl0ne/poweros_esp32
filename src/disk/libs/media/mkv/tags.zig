// SPDX-License-Identifier: MIT
//! A Matroska file's tags and chapters.
//!
//! **A tag** names what it is about by its target: a level - 50 an album
//! or a film, 30 a song or a chapter of one - and the tracks it is of, by
//! their unique numbers, none for the whole file. Its simple tags are
//! each a name and a text: TITLE, ARTIST, COMPOSER, GENRE, COMMENT,
//! DATE_RELEASED, PART_NUMBER, TOTAL_PARTS - and FFmpeg's ALBUM, DATE and
//! PART_NUMBER of "3/12". A title of level 50 is an album's, its artist
//! the album's own; a film has no album, so for a file with pictures
//! that title is the title. The segment's own title (Info's) stands
//! where no tag gives one. A track's tags are the
//! numbers a muxer counted - mkvmerge and FFmpeg write them: how many
//! packets it has (NUMBER_OF_FRAMES), its bits a second (BPS), how long
//! it lasts (DURATION, "01:23:45.678000000" - to its last block's end,
//! the priming with it).
//!
//! **The chapters** are an edition's - the one marked to be played, else
//! the first that is not hidden - each a start, maybe an end, and a name
//! in the first of its languages, put in the order they start. Hidden
//! ones are passed over.

const std = @import("std");
const sdk = @import("sdk");
const media = sdk.media;
const _file = @import("../file/_file.zig");
const File = _file.File;
const ebml = @import("ebml.zig");
const blocks = @import("blocks.zig");
const mp4_tags = @import("../mp4/tags.zig");

/// The most chapters kept.
const max_chapters = 1000;

/// The tags and the chapters read into the file's; `title` the segment's
/// own, where no tag gives one.
pub fn read(file: *File, tags_body: []const u8, chapters_body: []const u8, title: []const u8) void {
    const t = &file.tags;
    var album_title: [_file.name_bytes]u8 = @splat(0);
    var list = ebml.Elements{ .rest = tags_body };
    while (list.next()) |tag| {
        if (tag.id != ebml.Tag) continue;
        var level: u64 = 50;
        var track_uid: u64 = 0;
        if (ebml.child(tag.body, ebml.Targets)) |targets| {
            var items = ebml.Elements{ .rest = targets };
            while (items.next()) |item| switch (item.id) {
                ebml.TargetTypeValue => level = ebml.uint(item.body),
                ebml.TagTrackUID => track_uid = ebml.uint(item.body),
                else => {},
            };
        }
        var simple = ebml.Elements{ .rest = tag.body };
        while (simple.next()) |item| {
            if (item.id != ebml.SimpleTag) continue;
            const name = ebml.string(ebml.child(item.body, ebml.TagName) orelse continue);
            const text = ebml.string(ebml.child(item.body, ebml.TagString) orelse continue);
            if (track_uid != 0) {
                trackTag(file, track_uid, name, text);
                continue;
            }
            const whole = level >= 50;
            if (same(name, "TITLE")) {
                _file.copyUtf8(if (whole) &album_title else &t.title, text);
            } else if (same(name, "ARTIST")) {
                _file.copyUtf8(if (whole) &t.album_artist else &t.artist, text);
            } else if (same(name, "ALBUM")) {
                _file.copyUtf8(&t.album, text);
            } else if (same(name, "COMPOSER")) {
                _file.copyUtf8(&t.composer, text);
            } else if (same(name, "GENRE")) {
                _file.copyUtf8(&t.genre, text);
            } else if (same(name, "COMMENT") or same(name, "DESCRIPTION")) {
                if (t.comment[0] == 0) _file.copyUtf8(&t.comment, text);
            } else if (same(name, "DATE_RELEASED") or same(name, "DATE_RECORDED") or same(name, "DATE")) {
                if (t.year == 0) t.year = mp4_tags.yearOf(text);
            } else if (same(name, "PART_NUMBER")) {
                t.track = number(text);
                if (std.mem.indexOfScalar(u8, text, '/')) |slash| t.tracks = number(text[slash + 1 ..]);
            } else if (same(name, "TOTAL_PARTS")) {
                t.tracks = number(text);
            }
        }
    }
    // A level-50 title: an album's, or a film's own.
    var pictures = false;
    for (file.tracks[0..file.track_count]) |*track| {
        if (track.info.kind == media.MTRACK_VIDEO) pictures = true;
    }
    if (t.title[0] == 0 and title.len != 0 and title[0] != 0) _file.copyName(&t.title, title);
    if (pictures) {
        if (t.title[0] == 0) _file.copyName(&t.title, &album_title);
    } else if (t.album[0] == 0) {
        _file.copyName(&t.album, &album_title);
    }
    if (t.artist[0] == 0) _file.copyName(&t.artist, &t.album_artist);
    chapters(file, chapters_body);
}

fn same(name: []const u8, wanted: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, wanted);
}

/// A number's digits, up to what follows them: "3", "3/12".
fn number(text: []const u8) u32 {
    var value: u32 = 0;
    for (text) |char| {
        if (char < '0' or char > '9') break;
        value = value *| 10 +| (char - '0');
    }
    return value;
}

/// A track's tag: the numbers its muxer counted.
fn trackTag(file: *File, uid: u64, name: []const u8, text: []const u8) void {
    const track = for (file.tracks[0..file.track_count]) |*track| {
        if (track.mkv.uid == uid) break track;
    } else return;
    const out = &track.info;
    if (same(name, "NUMBER_OF_FRAMES")) {
        out.packets = number(text);
    } else if (same(name, "BPS")) {
        out.bitrate = number(text);
    } else if (same(name, "DURATION")) {
        if (durationOf(text)) |nanos| {
            const presented = nanos -| track.mkv.delay_ns;
            out.duration = presented / 1000;
            out.length = blocks.ticksOf(presented, out.timescale);
        }
    }
}

/// "HH:MM:SS.nnnnnnnnn" in nanoseconds.
fn durationOf(text: []const u8) ?u64 {
    var parts = std.mem.splitScalar(u8, text, ':');
    const hours = parts.next() orelse return null;
    const minutes = parts.next() orelse return null;
    const seconds = parts.next() orelse return null;
    var whole = seconds;
    var fraction: []const u8 = "";
    if (std.mem.indexOfScalar(u8, seconds, '.')) |dot| {
        whole = seconds[0..dot];
        fraction = seconds[dot + 1 ..];
    }
    var nanos: u64 = (@as(u64, number(hours)) * 3600 + @as(u64, number(minutes)) * 60 + number(whole)) * 1_000_000_000;
    var scale: u64 = 100_000_000;
    for (fraction) |char| {
        if (char < '0' or char > '9' or scale == 0) break;
        nanos += (char - '0') * scale;
        scale /= 10;
    }
    return nanos;
}

/// The chapters of the edition to play.
fn chapters(file: *File, body: []const u8) void {
    var chosen: ?[]const u8 = null;
    var editions = ebml.Elements{ .rest = body };
    while (editions.next()) |edition| {
        if (edition.id != ebml.EditionEntry) continue;
        const hidden = if (ebml.child(edition.body, ebml.EditionFlagHidden)) |flag| ebml.uint(flag) != 0 else false;
        const marked = if (ebml.child(edition.body, ebml.EditionFlagDefault)) |flag| ebml.uint(flag) != 0 else false;
        if (marked) {
            chosen = edition.body;
            break;
        }
        if (!hidden and chosen == null) chosen = edition.body;
    }
    const edition = chosen orelse return;
    var count: usize = 0;
    var atoms = ebml.Elements{ .rest = edition };
    while (atoms.next()) |atom| {
        if (atom.id == ebml.ChapterAtom and shown(atom.body)) count += 1;
    }
    count = @min(count, max_chapters);
    if (count == 0) return;
    const list = mp4_tags.chapterBlock(file, count) orelse return;
    var n: usize = 0;
    atoms = .{ .rest = edition };
    while (atoms.next()) |atom| {
        if (atom.id != ebml.ChapterAtom or !shown(atom.body) or n == count) continue;
        const chapter = &list[n];
        var items = ebml.Elements{ .rest = atom.body };
        while (items.next()) |item| switch (item.id) {
            ebml.ChapterTimeStart => chapter.start = milliseconds(item.body),
            ebml.ChapterTimeEnd => chapter.end = milliseconds(item.body),
            ebml.ChapterDisplay => if (chapter.title[0] == 0) {
                if (ebml.child(item.body, ebml.ChapString)) |text| _file.copyUtf8(&chapter.title, ebml.string(text));
            },
            else => {},
        };
        n += 1;
    }
    // In the order they start: a muxer keeps the order it was given.
    for (1..n) |k| {
        const chapter = list[k];
        var at = k;
        while (at > 0 and list[at - 1].start > chapter.start) : (at -= 1) list[at] = list[at - 1];
        list[at] = chapter;
    }
    const total: u32 = @intCast(@min(file.info.duration / 1000, std.math.maxInt(u32)));
    // The block came cleared: an end of 0 is one not given.
    for (0..n) |k| {
        if (list[k].end > list[k].start) continue;
        list[k].end = if (k + 1 < n) list[k + 1].start else @max(total, list[k].start);
    }
    file.tags.chapters = list;
    file.tags.chapter_count = @intCast(n);
}

/// Whether a chapter is one to list: neither hidden nor turned off.
fn shown(atom: []const u8) bool {
    if (ebml.child(atom, ebml.ChapterFlagHidden)) |flag| {
        if (ebml.uint(flag) != 0) return false;
    }
    if (ebml.child(atom, ebml.ChapterFlagEnabled)) |flag| {
        if (ebml.uint(flag) == 0) return false;
    }
    return true;
}

/// Nanoseconds in milliseconds, held to 32 bits.
fn milliseconds(body: []const u8) u32 {
    return @intCast(@min(ebml.uint(body) / 1_000_000, std.math.maxInt(u32)));
}
