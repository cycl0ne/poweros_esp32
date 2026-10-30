// SPDX-License-Identifier: MIT
//! An MP4's tags: iTunes's items in `moov`/`udta`/`meta`/`ilst` - each a
//! box named for what it is, `©nam` the title, its value in a `data` box -
//! the cover among them, iTunes's note of an encoder's priming
//! (`iTunSMPB`), and the chapters: Nero's list (`udta`'s `chpl`), else the
//! text track a track names for its chapters (`tref`'s `chap`), one
//! sample a chapter, its time the chapter's start - QuickTime's and
//! iTunes's, an audiobook's.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const media = sdk.media;
const _file = @import("../file/_file.zig");
const File = _file.File;
const be16 = _file.be16;
const be32 = _file.be32;
const be64 = _file.be64;
const _mp4 = @import("_mp4.zig");
const kind = _mp4.kind;
const child = _mp4.child;
const cursor = @import("cursor.zig");
const genres = @import("genres.zig");

/// The most chapters kept, and the longest chapter name read.
const max_chapters = 1000;
const max_chapter_text = 512;

/// The `ilst` of an index: `udta`'s `meta`, which is a full box in an MP4
/// and a plain one in some MOVs.
fn itemList(index: []const u8) ?[]const u8 {
    const udta = child(index, kind("udta")) orelse return null;
    const meta = child(udta, kind("meta")) orelse return null;
    const boxes = if (meta.len >= 8 and be32(meta[4..8]) == kind("hdlr")) meta else if (meta.len >= 4) meta[4..] else return null;
    return child(boxes, kind("ilst"));
}

/// An item's value: its first `data` box's type and bytes.
const Value = struct {
    type: u32,
    bytes: []const u8,
};

fn valueOf(item: []const u8) ?Value {
    const data = child(item, kind("data")) orelse return null;
    if (data.len < 8) return null;
    return .{ .type = be32(data[0..4]) & 0xFF_FFFF, .bytes = data[8..] };
}

/// A freeform item's (`----`) name.
fn freeformName(item: []const u8) []const u8 {
    const name = child(item, kind("name")) orelse return &.{};
    return if (name.len >= 4) name[4..] else &.{};
}

/// The tags read into the file's: the items, then the chapters.
pub fn read(file: *File, index: []const u8) void {
    const t = &file.tags;
    if (itemList(index)) |ilst| {
        var boxes = _mp4.Boxes{ .rest = ilst };
        while (boxes.next()) |item| {
            const value = valueOf(item.body) orelse continue;
            const bytes = value.bytes;
            switch (item.kind) {
                kind("\xA9nam") => _file.copyUtf8(&t.title, bytes),
                kind("\xA9ART") => _file.copyUtf8(&t.artist, bytes),
                kind("\xA9alb") => _file.copyUtf8(&t.album, bytes),
                kind("aART") => _file.copyUtf8(&t.album_artist, bytes),
                kind("\xA9wrt") => _file.copyUtf8(&t.composer, bytes),
                kind("\xA9gen") => _file.copyUtf8(&t.genre, bytes),
                kind("\xA9cmt") => _file.copyUtf8(&t.comment, bytes),
                kind("\xA9day") => t.year = yearOf(bytes),
                kind("gnre") => if (bytes.len >= 2) {
                    const number = be16(bytes[0..2]);
                    if (number >= 1 and number <= genres.names.len) _file.copyName(&t.genre, std.mem.span(genres.names[number - 1]));
                },
                kind("trkn") => if (bytes.len >= 6) {
                    t.track = be16(bytes[2..4]);
                    t.tracks = be16(bytes[4..6]);
                },
                kind("covr") => if (t.keep_picture and !t.has_picture and bytes.len > 0) cover(t, value),
                else => {},
            }
        }
    }
    if (child(index, kind("udta"))) |udta| {
        if (child(udta, kind("chpl"))) |chpl| neroChapters(file, chpl);
    }
    if (t.chapter_count == 0) trackChapters(file);
}

/// The cover kept: its bytes are the index's, as it lies in memory.
fn cover(t: *_file.Tags, value: Value) void {
    t.picture = .{ .data = value.bytes.ptr, .size = @intCast(value.bytes.len), .kind = 3, .mime = @splat(0) };
    const png = value.type == 14 or (value.bytes.len >= 4 and value.bytes[0] == 0x89 and value.bytes[1] == 'P');
    const mime = if (png) "image/png" else "image/jpeg";
    @memcpy(t.picture.mime[0..mime.len], mime);
    t.has_picture = true;
}

/// A year's first four digits, 0 when there are none: "2004",
/// "2004-05-12T07:00:00Z".
fn yearOf(text: []const u8) u32 {
    var year: u32 = 0;
    var digits: usize = 0;
    for (text) |char| {
        if (char < '0' or char > '9' or digits == 4) break;
        year = year * 10 + (char - '0');
        digits += 1;
    }
    return if (digits == 4) year else 0;
}

pub const Gap = struct {
    /// Ticks of priming, and the ticks of sound after it.
    delay: i64,
    length: u64,
};

/// iTunes's note of the priming and the length, for a file with no
/// edits: " 00000000 00000840 000001CA 00000000003F31F6 ..." - the
/// priming, the padding at the end, the length, in hexadecimal.
pub fn priming(index: []const u8) ?Gap {
    const ilst = itemList(index) orelse return null;
    var boxes = _mp4.Boxes{ .rest = ilst };
    while (boxes.next()) |item| {
        if (item.kind != kind("----")) continue;
        if (!std.mem.eql(u8, freeformName(item.body), "iTunSMPB")) continue;
        const value = valueOf(item.body) orelse return null;
        var fields: [4]u64 = @splat(0);
        var count: usize = 0;
        var words = std.mem.tokenizeScalar(u8, value.bytes, ' ');
        while (words.next()) |word| {
            if (count == fields.len) break;
            fields[count] = std.fmt.parseInt(u64, upToNul(word), 16) catch return null;
            count += 1;
        }
        if (count < 4 or fields[3] == 0) return null;
        return .{ .delay = @intCast(@min(fields[1], std.math.maxInt(i32))), .length = fields[3] };
    }
    return null;
}

fn upToNul(text: []const u8) []const u8 {
    return _file.upToNul(text);
}

/// The block of `count` chapters, cleared; null without memory.
fn chapterBlock(file: *File, count: usize) ?[*]media.MediaChapter {
    const memory = file.base.sys_base.AllocVec(@intCast(count * @sizeOf(media.MediaChapter)), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    return @ptrCast(@alignCast(memory));
}

/// Nero's chapters: their count, then each one's start in 100 ns and its
/// name, counted, in UTF-8.
fn neroChapters(file: *File, chpl: []const u8) void {
    if (chpl.len < 5) return;
    var at: usize = 4;
    if (chpl[0] != 0) at += 4;
    if (at >= chpl.len) return;
    const count: usize = @min(chpl[at], max_chapters);
    at += 1;
    if (count == 0) return;
    const list = chapterBlock(file, count) orelse return;
    var n: usize = 0;
    while (n < count and at + 9 <= chpl.len) : (n += 1) {
        const start = be64(chpl[at..][0..8]) / 10_000;
        const length: usize = chpl[at + 8];
        at += 9;
        if (at + length > chpl.len) break;
        list[n].start = @intCast(@min(start, std.math.maxInt(u32)));
        _file.copyUtf8(&list[n].title, chpl[at..][0..length]);
        at += length;
    }
    finishChapters(file, list, n);
}

/// The chapters of the text track a track names for them: each sample a
/// name - its length, then the text - due when the chapter starts. Read
/// from the file, so only one that can seek.
fn trackChapters(file: *File) void {
    if (!_file.seekable(file)) return;
    var wanted: u32 = 0;
    for (file.tracks[0..file.track_count]) |*track| {
        if (track.chapter_ref != 0) wanted = track.chapter_ref;
    }
    if (wanted == 0) return;
    const text = for (file.tracks[0..file.track_count]) |*track| {
        if (track.info.id == wanted and track.info.kind == media.MTRACK_TEXT) break track;
    } else return;
    const t = &text.tables;
    const count: usize = @min(t.samples, max_chapters);
    if (count == 0) return;
    const list = chapterBlock(file, count) orelse return;
    var at: cursor.Cursor = .{};
    cursor.reset(t, &at);
    var buffer: [max_chapter_text]u8 = undefined;
    for (0..count) |n| {
        const size = t.sizeOf(at.sample);
        const time = _file.micros(@as(i64, @intCast(at.dts)) - text.media_start, text.info.timescale) + text.empty_us;
        list[n].start = @intCast(std.math.clamp(@divFloor(time, 1000), 0, std.math.maxInt(u32)));
        const take = @min(size, buffer.len);
        if (take >= 2 and _file.readAt(file, at.offset, buffer[0..take])) {
            const length = @min(be16(buffer[0..2]), take - 2);
            sampleText(&list[n].title, buffer[2..][0..length]);
        }
        cursor.step(t, &at, size);
    }
    // The track is read; its cursor goes back to its start for a reader.
    cursor.reset(t, &text.at);
    finishChapters(file, list, count);
}

/// A text sample's text: UTF-16 behind its byte-order mark, else UTF-8.
fn sampleText(into: *[96]u8, bytes: []const u8) void {
    if (bytes.len >= 2 and bytes[0] == 0xFE and bytes[1] == 0xFF) {
        var out: usize = 0;
        var at: usize = 2;
        while (at + 1 < bytes.len and out < into.len - 1) : (at += 2) {
            const char = be16(bytes[at..][0..2]);
            into[out] = if (char <= 0xFF) @intCast(char) else '?';
            out += 1;
        }
        into[out] = 0;
        return;
    }
    _file.copyUtf8(into, bytes);
}

/// The chapters kept: each one ends where the next starts, the last one
/// where the file does.
fn finishChapters(file: *File, list: [*]media.MediaChapter, count: usize) void {
    if (count == 0) {
        file.base.sys_base.FreeVec(list);
        return;
    }
    const total: u32 = @intCast(@min(file.info.duration / 1000, std.math.maxInt(u32)));
    for (0..count) |n| {
        list[n].end = if (n + 1 < count) list[n + 1].start else @max(total, list[n].start);
    }
    file.tags.chapters = list;
    file.tags.chapter_count = @intCast(count);
}
