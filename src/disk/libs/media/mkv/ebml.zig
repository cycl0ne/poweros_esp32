// SPDX-License-Identifier: MIT
//! EBML, the coding Matroska is made of: elements, each its ID, its size
//! and its body, some of them holding more elements.
//!
//! The ID and the size are numbers of one to eight bytes whose first
//! byte says how long they are: as many bytes as the place of its first
//! bit set, counted from the top. An ID keeps that bit - 0x1A45DFA3 is
//! EBML's header - a size drops it. A size of all ones is not known: the
//! element goes on until something begins that cannot be in it, which
//! only a segment and a cluster written as they were recorded do.
//!
//! The IDs Matroska's reader looks at are named here.

const std = @import("std");

/// A size not known.
pub const unknown: u64 = std.math.maxInt(u64);

/// The longest head: an ID of four bytes and a size of eight.
pub const max_head = 12;

pub const Head = struct {
    id: u32,
    /// The body's size, `unknown` when it is not said.
    size: u64,
    /// The head's own bytes.
    length: u8,
};

/// A number's length from its first byte; 0 for a byte of 0, which
/// begins none.
pub fn lengthOf(first: u8) u8 {
    if (first == 0) return 0;
    return @as(u8, @clz(first)) + 1;
}

/// The element's head at the front of `bytes`: null when they do not hold
/// it whole, or it is none - an ID longer than four bytes.
pub fn head(bytes: []const u8) ?Head {
    if (bytes.len == 0) return null;
    const id_length = lengthOf(bytes[0]);
    if (id_length == 0 or id_length > 4 or bytes.len <= id_length) return null;
    var id: u32 = 0;
    for (bytes[0..id_length]) |byte| id = id << 8 | byte;
    const first = bytes[id_length];
    const size_length = lengthOf(first);
    if (size_length == 0 or bytes.len < id_length + size_length) return null;
    const marker: u16 = @as(u16, 0xFF) >> @intCast(size_length);
    var size: u64 = first & marker;
    var all_ones = size == marker;
    for (bytes[id_length + 1 ..][0 .. size_length - 1]) |byte| {
        size = size << 8 | byte;
        all_ones = all_ones and byte == 0xFF;
    }
    return .{ .id = id, .size = if (all_ones) unknown else size, .length = id_length + size_length };
}

/// A number as sizes are coded - its length's bit dropped - at `at`, and
/// `at` moved past it: a track's number in a block, a lace's size.
pub fn number(bytes: []const u8, at: *usize) ?u64 {
    if (at.* >= bytes.len) return null;
    const length = lengthOf(bytes[at.*]);
    if (length == 0 or at.* + length > bytes.len) return null;
    var value: u64 = bytes[at.*] & (@as(u16, 0xFF) >> @intCast(length));
    for (bytes[at.* + 1 ..][0 .. length - 1]) |byte| value = value << 8 | byte;
    at.* += length;
    return value;
}

/// A signed number as EBML's lacing codes the differences of sizes: the
/// number less half of what its length holds.
pub fn signedNumber(bytes: []const u8, at: *usize) ?i64 {
    const start = at.*;
    const value = number(bytes, at) orelse return null;
    const length = at.* - start;
    const half = (@as(i64, 1) << @intCast(7 * length - 1)) - 1;
    return @as(i64, @intCast(value)) - half;
}

pub const Element = struct {
    id: u32,
    body: []const u8,
};

/// The elements in a body held in memory, one after the other. One whose
/// size is not known, or is more than is left, takes the rest.
pub const Elements = struct {
    rest: []const u8,

    pub fn next(elements: *Elements) ?Element {
        const found = head(elements.rest) orelse return null;
        const after = elements.rest[found.length..];
        const length: usize = if (found.size > after.len) after.len else @intCast(found.size);
        elements.rest = after[length..];
        return .{ .id = found.id, .body = after[0..length] };
    }
};

/// The body of the first element `wanted` in `bytes`, or null.
pub fn child(bytes: []const u8, wanted: u32) ?[]const u8 {
    var elements = Elements{ .rest = bytes };
    while (elements.next()) |element| {
        if (element.id == wanted) return element.body;
    }
    return null;
}

/// An unsigned integer's body: up to eight bytes, the first the highest.
pub fn uint(body: []const u8) u64 {
    var value: u64 = 0;
    for (body[0..@min(body.len, 8)]) |byte| value = value << 8 | byte;
    return value;
}

/// A signed integer's body.
pub fn int(body: []const u8) i64 {
    if (body.len == 0) return 0;
    const length: usize = @min(body.len, 8);
    const value = uint(body[0..length]);
    const shift: u6 = @intCast(64 - 8 * length);
    return @as(i64, @bitCast(value << shift)) >> shift;
}

/// A float's body: four bytes or eight, 0 for any other length.
pub fn float(body: []const u8) f64 {
    return switch (body.len) {
        4 => @as(f32, @bitCast(@as(u32, @intCast(uint(body))))),
        8 => @bitCast(uint(body)),
        else => 0,
    };
}

/// A string's body: up to its first NUL.
pub fn string(body: []const u8) []const u8 {
    var length: usize = 0;
    while (length < body.len and body[length] != 0) length += 1;
    return body[0..length];
}

// --- the IDs ----------------------------------------------------------------------

pub const EBML: u32 = 0x1A45DFA3;
pub const DocType: u32 = 0x4282;
pub const Void: u32 = 0xEC;
pub const CRC32: u32 = 0xBF;

pub const Segment: u32 = 0x18538067;
pub const SeekHead: u32 = 0x114D9B74;
pub const Seek: u32 = 0x4DBB;
pub const SeekID: u32 = 0x53AB;
pub const SeekPosition: u32 = 0x53AC;

pub const Info: u32 = 0x1549A966;
pub const TimestampScale: u32 = 0x2AD7B1;
pub const Duration: u32 = 0x4489;
pub const Title: u32 = 0x7BA9;

pub const Tracks: u32 = 0x1654AE6B;
pub const TrackEntry: u32 = 0xAE;
pub const TrackNumber: u32 = 0xD7;
pub const TrackUID: u32 = 0x73C5;
pub const TrackType: u32 = 0x83;
pub const FlagEnabled: u32 = 0xB9;
pub const FlagDefault: u32 = 0x88;
pub const FlagForced: u32 = 0x55AA;
pub const DefaultDuration: u32 = 0x23E383;
pub const Name: u32 = 0x536E;
pub const Language: u32 = 0x22B59C;
pub const CodecID: u32 = 0x86;
pub const CodecPrivate: u32 = 0x63A2;
pub const CodecDelay: u32 = 0x56AA;
pub const Video: u32 = 0xE0;
pub const PixelWidth: u32 = 0xB0;
pub const PixelHeight: u32 = 0xBA;
pub const Audio: u32 = 0xE1;
pub const SamplingFrequency: u32 = 0xB5;
pub const Channels: u32 = 0x9F;
pub const BitDepth: u32 = 0x6264;
pub const ContentEncodings: u32 = 0x6D80;
pub const ContentEncoding: u32 = 0x6240;
pub const ContentEncodingType: u32 = 0x5033;
pub const ContentCompression: u32 = 0x5034;
pub const ContentCompAlgo: u32 = 0x4254;
pub const ContentCompSettings: u32 = 0x4255;

pub const Cluster: u32 = 0x1F43B675;
pub const Timestamp: u32 = 0xE7;
pub const SimpleBlock: u32 = 0xA3;
pub const BlockGroup: u32 = 0xA0;
pub const Block: u32 = 0xA1;
pub const BlockDuration: u32 = 0x9B;
pub const ReferenceBlock: u32 = 0xFB;

pub const Cues: u32 = 0x1C53BB6B;
pub const CuePoint: u32 = 0xBB;
pub const CueTime: u32 = 0xB3;
pub const CueTrackPositions: u32 = 0xB7;
pub const CueTrack: u32 = 0xF7;
pub const CueClusterPosition: u32 = 0xF1;
pub const CueRelativePosition: u32 = 0xF0;

pub const Tags: u32 = 0x1254C367;
pub const Tag: u32 = 0x7373;
pub const Targets: u32 = 0x63C0;
pub const TargetTypeValue: u32 = 0x68CA;
pub const TagTrackUID: u32 = 0x63C5;
pub const SimpleTag: u32 = 0x67C8;
pub const TagName: u32 = 0x45A3;
pub const TagString: u32 = 0x4487;

pub const Chapters: u32 = 0x1043A770;
pub const EditionEntry: u32 = 0x45B9;
pub const EditionFlagHidden: u32 = 0x45BD;
pub const EditionFlagDefault: u32 = 0x45DB;
pub const ChapterAtom: u32 = 0xB6;
pub const ChapterTimeStart: u32 = 0x91;
pub const ChapterTimeEnd: u32 = 0x92;
pub const ChapterFlagHidden: u32 = 0x98;
pub const ChapterFlagEnabled: u32 = 0x4598;
pub const ChapterDisplay: u32 = 0x80;
pub const ChapString: u32 = 0x85;

pub const Attachments: u32 = 0x1941A469;

/// Whether an element can only stand in a segment, never in a cluster: one
/// of them begins after a cluster of a size not known.
pub fn topLevel(id: u32) bool {
    return switch (id) {
        Cluster, Cues, Tags, Chapters, Attachments, SeekHead, Info, Tracks, Segment, EBML => true,
        else => false,
    };
}

test "a head, numbers and integers" {
    const testing = std.testing;
    const h = head(&[_]u8{ 0x1A, 0x45, 0xDF, 0xA3, 0x9F }).?;
    try testing.expectEqual(EBML, h.id);
    try testing.expectEqual(@as(u64, 31), h.size);
    try testing.expectEqual(@as(u8, 5), h.length);
    const open = head(&[_]u8{ 0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }).?;
    try testing.expectEqual(unknown, open.size);
    try testing.expectEqual(@as(?Head, null), head(&[_]u8{ 0x1A, 0x45 }));
    var at: usize = 0;
    try testing.expectEqual(@as(?u64, 1), number(&[_]u8{0x81}, &at));
    at = 0;
    try testing.expectEqual(@as(?u64, 0x123), number(&[_]u8{ 0x41, 0x23 }, &at));
    at = 0;
    try testing.expectEqual(@as(?i64, -1), signedNumber(&[_]u8{0xBE}, &at));
    try testing.expectEqual(@as(i64, -2), int(&[_]u8{0xFE}));
    try testing.expectEqual(@as(f64, 2.5), float(&[_]u8{ 0x40, 0x20, 0x00, 0x00 }));
}
