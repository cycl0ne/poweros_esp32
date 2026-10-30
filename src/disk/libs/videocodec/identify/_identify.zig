// SPDX-License-Identifier: MIT
//! What codec a film's pictures are in, by the first bytes of its file:
//! an MP4's index, where they reach it.
//!
//! An MP4 is a run of boxes - a size, four letters, a body - and its index
//! is the `moov` box. In it each track is a `trak`, whose `mdia` says
//! what it holds (`hdlr`: `vide` for pictures) and whose sample table
//! (`minf`, `stbl`, `stsd`) names the codec by its first entry's four
//! letters: `avc1` or `avc3` H.264, `hvc1` or `hev1` H.265, `jpeg` and
//! its kin Motion JPEG. An `mp4v` entry is MPEG-4's, whose descriptor
//! (`esds`) names the codec by a number: 0x6C JPEG, 0x20 MPEG-4 Part 2.
//!
//! A file whose index lies behind the bytes given - at its end, as a film
//! written in one go has it - says nothing yet.

const vc = @import("sdk").videocodec;

pub fn identify(bytes: []const u8) u32 {
    if (bytes.len < 8 or !opensMp4(bytes[4..8])) return vc.VCODEC_UNKNOWN;
    var boxes = Boxes{ .bytes = bytes };
    while (boxes.next()) |box| {
        if (same(box.kind, "moov")) return movieCodec(box.body);
    }
    return vc.VCODEC_UNKNOWN;
}

/// The boxes an MP4 begins with, as media.library knows one.
fn opensMp4(kind: []const u8) bool {
    for ([_]*const [4]u8{ "ftyp", "moov", "mdat", "wide", "free", "skip" }) |first| {
        if (same(kind, first)) return true;
    }
    return false;
}

/// The codec of the first track of pictures in the index.
fn movieCodec(moov: []const u8) u32 {
    var boxes = Boxes{ .bytes = moov };
    while (boxes.next()) |box| {
        if (!same(box.kind, "trak")) continue;
        const media = child(box.body, "mdia") orelse continue;
        const handler = child(media, "hdlr") orelse continue;
        if (handler.len < 12 or !same(handler[8..12], "vide")) continue;
        const info = child(media, "minf") orelse return vc.VCODEC_UNKNOWN;
        const table = child(info, "stbl") orelse return vc.VCODEC_UNKNOWN;
        const entries = child(table, "stsd") orelse return vc.VCODEC_UNKNOWN;
        // Its version and flags, how many entries, then the first.
        if (entries.len < 16) return vc.VCODEC_UNKNOWN;
        return entryCodec(entries[8..]);
    }
    return vc.VCODEC_UNKNOWN;
}

/// A sample entry's codec: its four letters, or an `mp4v`'s descriptor.
fn entryCodec(entry: []const u8) u32 {
    const kind = entry[4..8];
    if (same(kind, "avc1") or same(kind, "avc3")) return vc.VCODEC_H264;
    if (same(kind, "hvc1") or same(kind, "hev1")) return vc.VCODEC_H265;
    for ([_]*const [4]u8{ "jpeg", "mjpa", "mjpb", "MJPG" }) |name| {
        if (same(kind, name)) return vc.VCODEC_MJPEG;
    }
    if (!same(kind, "mp4v")) return vc.VCODEC_UNKNOWN;
    // The box's header and a picture entry's 78 bytes, then its children.
    const size = @min(be32(entry), entry.len);
    if (size < 8 + 78) return vc.VCODEC_MPEG4V;
    const esds = child(entry[8 + 78 .. size], "esds") orelse return vc.VCODEC_MPEG4V;
    return if (objectType(esds) == 0x6C) vc.VCODEC_MJPEG else vc.VCODEC_MPEG4V;
}

/// The object type an `esds` names: its ES descriptor (0x03), and in it
/// the decoder's (0x04), whose first byte it is. 0 when it is not there.
fn objectType(esds: []const u8) u8 {
    var at: usize = 4; // version and flags
    var tag = descriptor(esds, &at) orelse return 0;
    if (tag == 0x03) {
        if (at + 3 > esds.len) return 0;
        const flags = esds[at + 2];
        at += 3;
        if (flags & 0x80 != 0) at += 2;
        if (flags & 0x40 != 0) {
            if (at >= esds.len) return 0;
            at += 1 + @as(usize, esds[at]);
        }
        if (flags & 0x20 != 0) at += 2;
        tag = descriptor(esds, &at) orelse return 0;
    }
    if (tag != 0x04 or at >= esds.len) return 0;
    return esds[at];
}

/// A descriptor's tag, `at` moved past it and its length (7 bits a
/// byte, up to four).
fn descriptor(bytes: []const u8, at: *usize) ?u8 {
    if (at.* >= bytes.len) return null;
    const tag = bytes[at.*];
    at.* += 1;
    for (0..4) |_| {
        if (at.* >= bytes.len) return null;
        const byte = bytes[at.*];
        at.* += 1;
        if (byte & 0x80 == 0) break;
    }
    return tag;
}

/// The body of the first box of `kind` among `bytes`, cut where they end.
fn child(bytes: []const u8, kind: *const [4]u8) ?[]const u8 {
    var boxes = Boxes{ .bytes = bytes };
    while (boxes.next()) |box| {
        if (same(box.kind, kind)) return box.body;
    }
    return null;
}

const Box = struct { kind: []const u8, body: []const u8 };

/// The boxes one after the other; the last is cut where the bytes end.
const Boxes = struct {
    bytes: []const u8,
    at: usize = 0,

    fn next(b: *Boxes) ?Box {
        if (b.at + 8 > b.bytes.len) return null;
        const from = b.bytes[b.at..];
        var size: u64 = be32(from);
        var header: usize = 8;
        if (size == 1) {
            if (from.len < 16) return null;
            size = (@as(u64, be32(from[8..])) << 32) | be32(from[12..]);
            header = 16;
        } else if (size == 0) {
            size = from.len;
        }
        if (size < header) return null;
        const end: usize = @intCast(@min(size, from.len));
        b.at = if (size >= from.len) b.bytes.len else b.at + @as(usize, @intCast(size));
        return .{ .kind = from[4..8], .body = from[header..end] };
    }
};

fn same(a: []const u8, b: []const u8) bool {
    return a.len >= 4 and b.len >= 4 and a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

fn be32(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) | (@as(u32, bytes[1]) << 16) | (@as(u32, bytes[2]) << 8) | bytes[3];
}
