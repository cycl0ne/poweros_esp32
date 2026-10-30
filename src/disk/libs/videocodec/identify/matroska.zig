// SPDX-License-Identifier: MIT
//! What codec a Matroska file's pictures are in, by its first bytes: its
//! tracks, which lie near the front.
//!
//! Matroska is EBML: elements, each an ID, a size and a body, numbers of
//! one to eight bytes whose first byte says how long they are (an ID
//! keeps that bit, a size drops it; a size of all ones is not known).
//! After EBML's header comes the segment, and in it its parts: the seek
//! head, the info, the tracks (`Tracks`) - muxers keep room for them at
//! the front - then the clusters with the sound and pictures, where the
//! search stops. The first track of pictures (type 1) names its codec:
//! `V_MPEG4/ISO/AVC` H.264, `V_MPEGH/ISO/HEVC` H.265, `V_MJPEG` Motion
//! JPEG, `V_MPEG4/ISO/...` MPEG-4 Part 2, `V_MS/VFW/FOURCC` by the four
//! letters of its Windows header. VP8, VP9 and AV1 are none here.

const vc = @import("sdk").videocodec;

const EBML: u32 = 0x1A45DFA3;
const Segment: u32 = 0x18538067;
const Cluster: u32 = 0x1F43B675;
const Tracks: u32 = 0x1654AE6B;
const TrackEntry: u32 = 0xAE;
const TrackType: u32 = 0x83;
const CodecID: u32 = 0x86;
const CodecPrivate: u32 = 0x63A2;

/// Whether the bytes begin a Matroska file: EBML's header.
pub fn matroska(bytes: []const u8) bool {
    return bytes.len >= 4 and bytes[0] == 0x1A and bytes[1] == 0x45 and bytes[2] == 0xDF and bytes[3] == 0xA3;
}

/// The codec of the first track of pictures, where the bytes reach its
/// entry whole.
pub fn identify(bytes: []const u8) u32 {
    var at: usize = 0;
    const header = head(bytes, &at) orelse return vc.VCODEC_UNKNOWN;
    if (header.id != EBML or header.size == unknown) return vc.VCODEC_UNKNOWN;
    at += @intCast(@min(header.size, bytes.len - at));
    const segment = head(bytes, &at) orelse return vc.VCODEC_UNKNOWN;
    if (segment.id != Segment) return vc.VCODEC_UNKNOWN;
    while (head(bytes, &at)) |part| {
        if (part.id == Cluster or part.size == unknown) return vc.VCODEC_UNKNOWN;
        if (part.size > bytes.len - at) return vc.VCODEC_UNKNOWN;
        const body = bytes[at..][0..@intCast(part.size)];
        if (part.id == Tracks) return tracksCodec(body);
        at += body.len;
    }
    return vc.VCODEC_UNKNOWN;
}

/// The codec of the first track of pictures among the entries.
fn tracksCodec(tracks: []const u8) u32 {
    var entries = Elements{ .rest = tracks };
    while (entries.next()) |entry| {
        if (entry.id != TrackEntry) continue;
        var kind: u64 = 0;
        var codec: []const u8 = "";
        var private: []const u8 = "";
        var items = Elements{ .rest = entry.body };
        while (items.next()) |item| switch (item.id) {
            TrackType => {
                for (item.body[0..@min(item.body.len, 8)]) |byte| kind = kind << 8 | byte;
            },
            CodecID => codec = item.body,
            CodecPrivate => private = item.body,
            else => {},
        };
        if (kind == 1) return codecOf(codec, private);
    }
    return vc.VCODEC_UNKNOWN;
}

fn codecOf(id: []const u8, private: []const u8) u32 {
    if (same(id, "V_MPEG4/ISO/AVC")) return vc.VCODEC_H264;
    if (same(id, "V_MPEGH/ISO/HEVC")) return vc.VCODEC_H265;
    if (same(id, "V_MJPEG")) return vc.VCODEC_MJPEG;
    if (id.len > 12 and same(id[0..12], "V_MPEG4/ISO/")) return vc.VCODEC_MPEG4V;
    if (!same(id, "V_MS/VFW/FOURCC") or private.len < 20) return vc.VCODEC_UNKNOWN;
    // A BITMAPINFOHEADER: its compression's four letters 16 bytes in.
    const letters = private[16..20];
    for ([_]*const [4]u8{ "MJPG", "mjpg", "AVRn" }) |name| {
        if (same(letters, name)) return vc.VCODEC_MJPEG;
    }
    for ([_]*const [4]u8{ "XVID", "xvid", "DIVX", "divx", "DX50", "FMP4", "MP4V" }) |name| {
        if (same(letters, name)) return vc.VCODEC_MPEG4V;
    }
    return vc.VCODEC_UNKNOWN;
}

/// A size not known.
const unknown: u64 = ~@as(u64, 0);

const Head = struct { id: u32, size: u64 };

/// The element's head at `at`, `at` moved past it; null when the bytes
/// do not hold it whole, or it is none.
fn head(bytes: []const u8, at: *usize) ?Head {
    if (at.* >= bytes.len) return null;
    const id_length = lengthOf(bytes[at.*]);
    if (id_length == 0 or id_length > 4 or at.* + id_length >= bytes.len) return null;
    var id: u32 = 0;
    for (bytes[at.*..][0..id_length]) |byte| id = id << 8 | byte;
    const first = bytes[at.* + id_length];
    const size_length = lengthOf(first);
    if (size_length == 0 or at.* + id_length + size_length > bytes.len) return null;
    const marker: u8 = @truncate(@as(u16, 0xFF) >> @intCast(size_length));
    var size: u64 = first & marker;
    var all_ones = size == marker;
    for (bytes[at.* + id_length + 1 ..][0 .. size_length - 1]) |byte| {
        size = size << 8 | byte;
        all_ones = all_ones and byte == 0xFF;
    }
    at.* += id_length + size_length;
    return .{ .id = id, .size = if (all_ones) unknown else size };
}

/// A number's length from its first byte; 0 for a byte of 0.
fn lengthOf(first: u8) usize {
    if (first == 0) return 0;
    return @as(usize, @clz(first)) + 1;
}

const Element = struct { id: u32, body: []const u8 };

/// The elements of a body in memory; one that runs past its end is cut.
const Elements = struct {
    rest: []const u8,

    fn next(elements: *Elements) ?Element {
        var at: usize = 0;
        const found = head(elements.rest, &at) orelse return null;
        const left = elements.rest.len - at;
        const length: usize = if (found.size > left) left else @intCast(found.size);
        const body = elements.rest[at..][0..length];
        elements.rest = elements.rest[at + length ..];
        return .{ .id = found.id, .body = body };
    }
};

fn same(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
