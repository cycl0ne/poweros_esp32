// SPDX-License-Identifier: MIT
//! A link of an Ogg file - one stream with headers of its own, of a chain
//! of them or alone - measured and sought in, the same for every codec
//! carried in Ogg: where it ends, its last granule position, the page a
//! seek begins decoding on, and the next link's first page.

const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;
const ogg = @import("_ogg.zig");

/// Where a link's sound lies in the file: its first audio packet's page
/// and segment, and where it ends - the next link's first page, or the
/// file's end.
pub const Link = struct {
    audio_page: u64,
    audio_segment: u32,
    end: u64,
};

/// How far a file's link goes - to the first page that is none of its
/// own, or the file's end - into `link.end`, and its last granule
/// position: -1 when it has none. A file of one link, as most are, ends
/// with the link's own pages, and its last is looked for there; a link of
/// a chain ends where a search halving the file, then page by page, finds
/// the next link's first.
pub fn measure(stream: *Stream, o: *const ogg.Ogg, link: *Link) i64 {
    link.end = stream.end;
    const tail = finalPage(stream, o, link);
    if (tail.serial == null or inLink(o, tail.serial.?)) {
        return if (tail.granule >= 0) tail.granule else lastGranule(stream, o, link);
    }
    var probe: ogg.Ogg = undefined;
    var low = link.audio_page;
    var high = stream.end;
    var rounds: u32 = 0;
    while (high > low and high - low > 64 * 1024 and rounds < 40) : (rounds += 1) {
        const middle = low + (high - low) / 2;
        if (!_stream.seekSource(stream, middle)) return -1;
        ogg.begin(&probe, null);
        if (!ogg.nextPage(stream, &probe) or probe.page_offset >= high) {
            high = middle;
        } else if (inLink(o, probe.serial)) {
            low = probe.page_offset + 27 + probe.segments + bodyOf(&probe);
        } else {
            high = probe.page_offset;
        }
    }
    if (!_stream.seekSource(stream, low)) return -1;
    var last: i64 = -1;
    while (true) {
        ogg.begin(&probe, null);
        if (!ogg.nextPage(stream, &probe)) break;
        if (!inLink(o, probe.serial)) {
            link.end = probe.page_offset;
            break;
        }
        if (probe.serial == o.serial and probe.granule >= 0) last = probe.granule;
        _stream.skip(stream, bodyOf(&probe));
    }
    return last;
}

/// What the last 64 KiB of a file end with: the serial of its last page -
/// null when there is none there - and the last granule position of the
/// stream read among them, -1 when there is none.
fn finalPage(stream: *Stream, o: *const ogg.Ogg, link: *const Link) struct { serial: ?u32, granule: i64 } {
    const span: u64 = 64 * 1024;
    const from = if (stream.end - link.audio_page > span) stream.end - span else link.audio_page;
    var serial: ?u32 = null;
    var granule: i64 = -1;
    if (!_stream.seekSource(stream, from)) return .{ .serial = null, .granule = -1 };
    var probe: ogg.Ogg = undefined;
    while (true) {
        ogg.begin(&probe, null);
        if (!ogg.nextPage(stream, &probe)) break;
        serial = probe.serial;
        if (probe.serial == o.serial and probe.granule >= 0) granule = probe.granule;
        _stream.skip(stream, bodyOf(&probe));
    }
    return .{ .serial = serial, .granule = granule };
}

/// Whether the pages of the stream `serial` are the link's: its own, or a
/// stream's that began beside it.
fn inLink(o: *const ogg.Ogg, serial: u32) bool {
    if (serial == o.serial) return true;
    for (o.companions[0..o.companion_count]) |other| {
        if (other == serial) return true;
    }
    return false;
}

/// The last granule position of the stream in the file, looked for in
/// more and more of its end: -1 when there is none.
fn lastGranule(stream: *Stream, o: *const ogg.Ogg, link: *const Link) i64 {
    var span: u64 = 32 * 1024;
    while (true) {
        const from = if (stream.end - link.audio_page > span) stream.end - span else link.audio_page;
        if (!_stream.seekSource(stream, from)) return -1;
        var probe: ogg.Ogg = undefined;
        ogg.begin(&probe, o.serial);
        var last: i64 = -1;
        while (ogg.nextPage(stream, &probe)) {
            if (probe.granule >= 0) last = probe.granule;
            _stream.skip(stream, bodyOf(&probe));
        }
        if (last >= 0 or from == link.audio_page) return last;
        span *= 4;
    }
}

/// The bytes of a page's segments.
pub fn bodyOf(probe: *const ogg.Ogg) u64 {
    var length: u64 = 0;
    for (probe.lacing[0..probe.segments]) |value| length += value;
    return length;
}

/// The reader set at segment `segment` of the page at `offset`.
pub fn readFrom(stream: *Stream, o: *ogg.Ogg, offset: u64, segment: u32) bool {
    if (!_stream.seekSource(stream, offset)) return false;
    ogg.again(o);
    if (!ogg.nextPage(stream, o) or segment > o.segments) return false;
    var before: u64 = 0;
    for (o.lacing[0..segment]) |value| before += value;
    _stream.skip(stream, before);
    o.segment = segment;
    o.pass_continued = false;
    return true;
}

/// The reader set at the next link's first page: one that begins a stream
/// whose first packet begins with `magic`. A page of another kind, or of
/// no beginning, is passed over - 64 of them at most. False when none
/// comes: the reader is left on the link that ended, which a seek goes
/// back into.
pub fn nextStart(stream: *Stream, o: *ogg.Ogg, comptime magic: []const u8) bool {
    var probe: ogg.Ogg = undefined;
    var pages: u32 = 0;
    while (pages < 64) : (pages += 1) {
        ogg.begin(&probe, null);
        if (!ogg.nextPage(stream, &probe)) return false;
        // The page is small, and whole in the read-ahead: its first packet
        // is looked at where it lies.
        const body = _stream.available(stream);
        const begins = probe.flags & ogg.first != 0 and probe.segments != 0;
        if (begins and _stream.same(body, magic)) {
            o.* = probe;
            return true;
        }
        _stream.skip(stream, bodyOf(&probe));
    }
    return false;
}

pub const Place = struct { offset: u64, segment: u32 };

/// The last page with a granule position no later than `target` whose
/// last packet begins on it: where that packet begins.
pub fn findPage(stream: *Stream, o: *const ogg.Ogg, link: *const Link, target: u64) ?Place {
    var probe: ogg.Ogg = undefined;
    var low = link.audio_page;
    var high = link.end;
    var rounds: u32 = 0;
    while (high > low and high - low > 64 * 1024 and rounds < 40) : (rounds += 1) {
        const middle = low + (high - low) / 2;
        if (!_stream.seekSource(stream, middle)) return null;
        ogg.begin(&probe, o.serial);
        var found: ?u64 = null;
        var granule: i64 = -1;
        while (ogg.nextPage(stream, &probe)) {
            if (probe.page_offset >= high) break;
            if (probe.granule >= 0) {
                found = probe.page_offset;
                granule = probe.granule;
                break;
            }
            _stream.skip(stream, bodyOf(&probe));
        }
        if (found == null or granule > @as(i64, @intCast(target))) {
            high = middle;
        } else {
            low = found.?;
        }
    }
    // From there page by page, to the last that will do.
    if (!_stream.seekSource(stream, low)) return null;
    ogg.begin(&probe, o.serial);
    var best: ?Place = null;
    while (ogg.nextPage(stream, &probe)) {
        if (probe.page_offset >= link.end or probe.granule > @as(i64, @intCast(target))) break;
        if (probe.granule >= 0) {
            if (lastPacketStart(&probe)) |segment| best = .{ .offset = probe.page_offset, .segment = segment };
        }
        _stream.skip(stream, bodyOf(&probe));
    }
    return best;
}

/// The segment the last packet to end on the page begins with, when it
/// begins on this page.
fn lastPacketStart(probe: *const ogg.Ogg) ?u32 {
    if (probe.last_end < 0) return null;
    var index: i32 = probe.last_end - 1;
    while (index >= 0 and probe.lacing[@intCast(index)] == 255) index -= 1;
    if (index < 0 and probe.flags & ogg.continued != 0) return null;
    return @intCast(index + 1);
}
