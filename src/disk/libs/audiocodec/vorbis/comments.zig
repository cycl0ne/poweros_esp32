// SPDX-License-Identifier: MIT
//! Vorbis comments - the tags of an Ogg Vorbis stream and of a FLAC file -
//! and the picture block FLAC defines, which an Ogg stream carries in a
//! comment of its own, base64-coded.
//!
//! **Comments** are a vendor's name, then fields of `NAME=value`, each
//! with its length in front, little-endian; the name in any case, the
//! value UTF-8. The names read are TITLE, ARTIST, ALBUM, ALBUMARTIST,
//! COMPOSER, GENRE, DATE, TRACKNUMBER, TRACKTOTAL, COMMENT (DESCRIPTION
//! too), the chapters - `CHAPTER001=00:01:30.000` with
//! `CHAPTER001NAME=...` - and METADATA_BLOCK_PICTURE. A name given twice
//! counts the first time; a comment says more than ID3v1 at a file's end.
//!
//! **A picture block** is its kind, its MIME type, a description, its
//! size and colours, then the image file, all lengths big-endian. It is
//! kept as an ID3 picture is: only when the program asked, the front
//! cover over another.
//!
//! Both are read through a reader - FLAC's metadata block, an Ogg packet
//! - with `read` and `skip`, so a comment of any length is passed over
//! without being held, and a picture is decoded into its own memory as
//! it comes.

const sdk = @import("sdk");
const exec = sdk.exec;
const ac = sdk.audiocodec;
const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;
const mp3 = @import("../mp3/_mp3.zig");

/// The most comments looked at, and the longest name.
const comments_max = 10_000;
const name_max = 32;

const Kind = enum { none, title, artist, album, album_artist, composer, genre, date, track, tracks, comment, picture, chapter, chapter_name };

/// What the comments have said so far: the fields given, and the number
/// each chapter kept has in its name.
const Seen = struct {
    given: u32 = 0,
    numbers: [mp3.chapter_max]u32 = undefined,

    fn first(seen: *Seen, kind: Kind) bool {
        const bit = @as(u32, 1) << @intFromEnum(kind);
        if (seen.given & bit != 0) return false;
        seen.given |= bit;
        return true;
    }
};

/// The comments, their vendor's name first, from `reader`.
pub fn read(reader: anytype, stream: *Stream) void {
    var seen: Seen = .{};
    const vendor = le32Of(reader) orelse return;
    reader.skip(vendor);
    const count = le32Of(reader) orelse return;
    var index: u32 = 0;
    while (index < count and index < comments_max) : (index += 1) {
        const length = le32Of(reader) orelse return;
        field(reader, stream, &seen, length);
    }
}

/// A little-endian 32-bit length.
fn le32Of(reader: anytype) ?u32 {
    var bytes: [4]u8 = undefined;
    if (reader.read(&bytes) != bytes.len) return null;
    return _stream.le32(&bytes);
}

fn be32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) << 24 | @as(u32, bytes[1]) << 16 | @as(u32, bytes[2]) << 8 | bytes[3];
}

/// One comment of `length` bytes: its name, then its value taken or
/// passed over.
fn field(reader: anytype, stream: *Stream, seen: *Seen, length: u32) void {
    var name: [name_max]u8 = undefined;
    var name_len: usize = 0;
    var used: u32 = 0;
    var found = false;
    while (used < length) {
        var one: [1]u8 = undefined;
        if (reader.read(&one) != 1) return;
        used += 1;
        if (one[0] == '=') {
            found = true;
            break;
        }
        if (name_len == name.len) break;
        name[name_len] = upper(one[0]);
        name_len += 1;
    }
    const value_len = length - used;
    var number: u32 = 0;
    const kind = if (found) kindOf(name[0..name_len], &number) else .none;
    const tags = &stream.tags;
    switch (kind) {
        .none => return reader.skip(value_len),
        .picture => {
            if (!tags.keep_picture) return reader.skip(value_len);
            var decoder = Base64(@TypeOf(reader)){ .source = reader, .left = value_len };
            picture(&decoder, stream);
            reader.skip(decoder.left);
            return;
        },
        else => {},
    }
    // The value, behind the byte that says it is UTF-8, as an ID3 text
    // frame has it.
    const text = &tags.frame_text;
    const keep: usize = @min(value_len, text.len - 2);
    const got = reader.read(text[1..][0..keep]);
    reader.skip(value_len - got);
    text[0] = 3;
    text[1 + got] = 0;
    const value = text[0 .. 1 + got];
    if (kind == .chapter or kind == .chapter_name) return chapter(stream, seen, kind, number, value);
    if (!seen.first(kind)) return;
    var short: [64]u8 = undefined;
    switch (kind) {
        .title => mp3.text(&tags.title, value),
        .artist => mp3.text(&tags.artist, value),
        .album => mp3.text(&tags.album, value),
        .album_artist => mp3.text(&tags.album_artist, value),
        .composer => mp3.text(&tags.composer, value),
        .genre => mp3.text(&tags.genre, value),
        .date => {
            mp3.text(&short, value);
            const year = _stream.yearOf(&short);
            if (year != 0) tags.year = year;
        },
        .track => {
            mp3.text(&short, value);
            const tracks = tags.tracks;
            _stream.trackOf(&short, &tags.track, &tags.tracks);
            if (tags.tracks == 0) tags.tracks = tracks;
        },
        .tracks => {
            mp3.text(&short, value);
            var none: u32 = 0;
            _stream.trackOf(&short, &tags.tracks, &none);
        },
        .comment => {
            mp3.text(&tags.comment, value);
            tags.plain_comment = true;
        },
        .none, .picture, .chapter, .chapter_name => {},
    }
}

fn upper(char: u8) u8 {
    return if (char >= 'a' and char <= 'z') char - 32 else char;
}

/// A field's kind by its name, in capitals; a chapter's number into
/// `number`.
fn kindOf(name: []const u8, number: *u32) Kind {
    const known = [_]struct { []const u8, Kind }{
        .{ "TITLE", .title },
        .{ "ARTIST", .artist },
        .{ "ALBUM", .album },
        .{ "ALBUMARTIST", .album_artist },
        .{ "ALBUM ARTIST", .album_artist },
        .{ "COMPOSER", .composer },
        .{ "GENRE", .genre },
        .{ "DATE", .date },
        .{ "YEAR", .date },
        .{ "TRACKNUMBER", .track },
        .{ "TRACKTOTAL", .tracks },
        .{ "TOTALTRACKS", .tracks },
        .{ "COMMENT", .comment },
        .{ "DESCRIPTION", .comment },
        .{ "METADATA_BLOCK_PICTURE", .picture },
    };
    inline for (known) |entry| {
        if (name.len == entry[0].len and _stream.same(name, entry[0])) return entry[1];
    }
    if (name.len > 7 and _stream.same(name, "CHAPTER")) {
        var at: usize = 7;
        var value: u32 = 0;
        while (at < name.len and name[at] >= '0' and name[at] <= '9') : (at += 1) value = value *| 10 +| (name[at] - '0');
        if (at == 7) return .none;
        number.* = value;
        if (at == name.len) return .chapter;
        if (name.len - at == 4 and _stream.same(name[at..], "NAME")) return .chapter_name;
    }
    return .none;
}

/// A chapter's start (`HH:MM:SS.mmm`) or its title, into the chapter with
/// its number - made at the first word of it.
fn chapter(stream: *Stream, seen: *Seen, kind: Kind, number: u32, value: []u8) void {
    const tags = &stream.tags;
    const list = tags.chapters orelse made: {
        const memory = stream.base.sys_base.AllocVec(mp3.chapter_max * @sizeOf(ac.AudioChapter), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return;
        const made: [*]ac.AudioChapter = @ptrCast(@alignCast(memory));
        tags.chapters = made;
        break :made made;
    };
    var index: u32 = 0;
    while (index < tags.chapter_count and seen.numbers[index] != number) index += 1;
    if (index == tags.chapter_count) {
        if (index == mp3.chapter_max) return;
        seen.numbers[index] = number;
        list[index] = .{ .start = 0, .end = 0, .title = @splat(0) };
        tags.chapter_count += 1;
    }
    const entry = &list[index];
    if (kind == .chapter_name) {
        mp3.text(&entry.title, value);
        return;
    }
    entry.start = millisecondsOf(value[1..]);
}

/// `HH:MM:SS.mmm` - hours, minutes, seconds and a fraction of one - in
/// milliseconds.
fn millisecondsOf(text: []const u8) u32 {
    var whole: u64 = 0;
    var part: u64 = 0;
    var at: usize = 0;
    while (at < text.len and text[at] != 0) : (at += 1) {
        const char = text[at];
        if (char == ':') {
            whole = whole *| 60 +| part;
            part = 0;
        } else if (char >= '0' and char <= '9') {
            part = part *| 10 +| (char - '0');
        } else break;
    }
    whole = whole *| 60 +| part;
    var milliseconds: u64 = whole *| 1000;
    if (at < text.len and text[at] == '.') {
        var scale: u64 = 100;
        at += 1;
        while (at < text.len and text[at] >= '0' and text[at] <= '9') : (at += 1) {
            milliseconds +|= (text[at] - '0') * scale;
            scale /= 10;
        }
    }
    return @intCast(@min(milliseconds, 0xFFFF_FFFF));
}

/// The chapters put in the order they start, each ending where the next
/// starts and the last at the end of the sound, `length` milliseconds
/// long (0 when that is not known: it ends where it starts).
pub fn finishChapters(stream: *Stream, length: u32) void {
    const list = stream.tags.chapters orelse return;
    const count = stream.tags.chapter_count;
    if (count == 0) return;
    var sorted: u32 = 1;
    while (sorted < count) : (sorted += 1) {
        const moving = list[sorted];
        var at = sorted;
        while (at > 0 and list[at - 1].start > moving.start) : (at -= 1) list[at] = list[at - 1];
        list[at] = moving;
    }
    for (0..count) |index| {
        list[index].end = if (index + 1 < count) list[index + 1].start else @max(length, list[index].start);
    }
}

/// A picture block, from `reader`: kept when there is none yet, or it is
/// the front cover and the one kept is not.
pub fn picture(reader: anytype, stream: *Stream) void {
    const tags = &stream.tags;
    const sys = stream.base.sys_base;
    var head: [8]u8 = undefined;
    if (reader.read(&head) != head.len) return;
    const kind = be32(head[0..4]);
    const mime_len = be32(head[4..8]);
    var mime: [32]u8 = @splat(0);
    const mime_kept: usize = @min(mime_len, mime.len - 1);
    if (reader.read(mime[0..mime_kept]) != mime_kept) return;
    reader.skip(mime_len - mime_kept);
    var word: [4]u8 = undefined;
    if (reader.read(&word) != word.len) return;
    reader.skip(be32(&word));
    // Its width, height, depth and colours, then the image's length.
    var sizes: [20]u8 = undefined;
    if (reader.read(&sizes) != sizes.len) return;
    const image_size: u64 = be32(sizes[16..20]);
    const better = tags.picture_block == null or (kind == ac.ACPIC_FRONTCOVER and tags.picture.kind != ac.ACPIC_FRONTCOVER);
    if (!better or image_size == 0 or image_size > mp3.picture_max) return reader.skip(image_size);
    const memory = sys.AllocVec(@intCast(image_size), exec.MEMF_ANY) orelse return reader.skip(image_size);
    const block: [*]u8 = @ptrCast(memory);
    const got = reader.read(block[0..@intCast(image_size)]);
    if (got != image_size) {
        sys.FreeVec(memory);
        return;
    }
    if (tags.picture_block) |old| sys.FreeVec(old);
    tags.picture_block = block;
    tags.picture = .{ .data = block, .size = @intCast(got), .kind = kind, .mime = mime };
}

/// A reader of base64 text from another, `left` characters of it, handing
/// out the bytes it codes.
fn Base64(comptime Source: type) type {
    return struct {
        const Self = @This();
        source: Source,
        left: u64,
        held: u32 = 0,
        held_bits: u32 = 0,
        done: bool = false,

        fn sextet(char: u8) ?u32 {
            return switch (char) {
                'A'...'Z' => char - 'A',
                'a'...'z' => char - 'a' + 26,
                '0'...'9' => char - '0' + 52,
                '+' => 62,
                '/' => 63,
                else => null,
            };
        }

        pub fn read(decoder: *Self, into: []u8) usize {
            var done: usize = 0;
            while (done < into.len) {
                while (decoder.held_bits < 8) {
                    if (decoder.done or decoder.left == 0) return done;
                    var chars: [1]u8 = undefined;
                    if (decoder.source.read(&chars) != 1) {
                        decoder.done = true;
                        return done;
                    }
                    decoder.left -= 1;
                    // The padding ends it; anything else not base64 - a
                    // line's end - is passed over.
                    if (chars[0] == '=') {
                        decoder.done = true;
                        return done;
                    }
                    const value = sextet(chars[0]) orelse continue;
                    decoder.held = (decoder.held << 6) | value;
                    decoder.held_bits += 6;
                }
                decoder.held_bits -= 8;
                into[done] = @truncate(decoder.held >> @intCast(decoder.held_bits));
                done += 1;
            }
            return done;
        }

        pub fn skip(decoder: *Self, count: u64) void {
            var scratch: [64]u8 = undefined;
            var left = count;
            while (left > 0) {
                const got = decoder.read(scratch[0..@intCast(@min(left, scratch.len))]);
                if (got == 0) return;
                left -= got;
            }
        }
    };
}

/// A FLAC metadata block's bytes as a reader: `left` of them, from the
/// stream.
pub const BlockReader = struct {
    stream: *Stream,
    left: u64,

    pub fn read(reader: *BlockReader, into: []u8) usize {
        const stream = reader.stream;
        var done: usize = 0;
        while (done < into.len and reader.left > 0) {
            if (stream.stop == stream.start) {
                _stream.fill(stream);
                if (stream.stop == stream.start) break;
            }
            const here = _stream.available(stream);
            const count: usize = @intCast(@min(@as(u64, @min(here.len, into.len - done)), reader.left));
            @memcpy(into[done..][0..count], here[0..count]);
            _stream.consume(stream, count);
            reader.left -= count;
            done += count;
        }
        return done;
    }

    pub fn skip(reader: *BlockReader, count: u64) void {
        const passed = @min(count, reader.left);
        _stream.skip(reader.stream, passed);
        reader.left -= passed;
    }
};
