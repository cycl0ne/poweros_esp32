// SPDX-License-Identifier: MIT
//! Ogg: the pages a stream's packets are carried in, read through the
//! stream's read-ahead - a packet's bytes one after the other across the
//! pages it spans, its bits least significant first, and the pages
//! themselves found again after a seek.
//!
//! **A page** is a header - "OggS", its flags, a granule position, the
//! logical stream it belongs to (its serial), its number and a CRC - and
//! up to 255 lacing values, the lengths of its segments, then the
//! segments. A packet is segments one after the other up to one shorter
//! than 255; a packet that goes on past a page's last segment goes on in
//! the next page, which says so in its flags. Only the stream whose
//! serial was taken is read; another's pages are passed over.
//!
//! **A page whose CRC is wrong is no page**: the next "OggS" is looked
//! for. A page is checked when it lies whole in the read-ahead, as pages
//! of sound do; a larger one is believed.
//!
//! **What a packet ends** is noted for the decoder: the page's granule
//! position when it is the last packet to end on its page, and whether
//! that page ends the stream. A packet that began on a page not read -
//! after a seek, or a page lost - is passed over whole, as no decoder can
//! use part of one.

const _stream = @import("../stream/_stream.zig");
const Stream = _stream.Stream;

/// A page's flags: it goes on with a packet from the page before, it
/// begins the stream, it ends it.
pub const continued: u8 = 0x01;
pub const first: u8 = 0x02;
pub const last: u8 = 0x04;

pub const Ogg = struct {
    /// The logical stream read.
    serial: u32,
    has_serial: bool,
    /// The page being read: its lacing values and how many, the next
    /// segment, the bytes left of the one being read.
    lacing: [255]u8,
    segments: u32,
    segment: u32,
    left: u32,
    /// Its granule position, flags and number; which of its segments ends
    /// the last packet to end on it, -1 when none does.
    granule: i64,
    flags: u8,
    sequence: u32,
    last_end: i32,
    /// A page is being read.
    have_page: bool,
    /// The segment being read is a packet's last.
    final: bool,
    /// The next page's first packet, when it is continued, is passed over:
    /// its beginning was not read.
    pass_continued: bool,
    /// What the packet that ended last said: its page's granule position
    /// when it was the last to end there, -1 otherwise, and whether the
    /// stream ends with it.
    packet_granule: i64,
    packet_ends_stream: bool,
    /// Where the page being read begins in the source.
    page_offset: u64,
};

/// A reader set to begin at a page, for the stream `serial` (or the
/// first one met when `serial` is null).
pub fn begin(ogg: *Ogg, serial: ?u32) void {
    ogg.* = .{
        .serial = serial orelse 0,
        .has_serial = serial != null,
        .lacing = undefined,
        .segments = 0,
        .segment = 0,
        .left = 0,
        .granule = -1,
        .flags = 0,
        .sequence = 0,
        .last_end = -1,
        .have_page = false,
        .final = true,
        .pass_continued = true,
        .packet_granule = -1,
        .packet_ends_stream = false,
        .page_offset = 0,
    };
}

// --- pages ------------------------------------------------------------------------

const crc_table = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, i| {
        var crc: u32 = @as(u32, i) << 24;
        for (0..8) |_| crc = if (crc & 0x8000_0000 != 0) (crc << 1) ^ 0x04C1_1DB7 else crc << 1;
        entry.* = crc;
    }
    break :blk table;
};

/// A page's CRC: over all of it, the CRC's own four bytes as zeros.
fn pageCrc(page: []const u8) u32 {
    var crc: u32 = 0;
    for (page, 0..) |byte, i| {
        const value = if (i >= 22 and i < 26) 0 else byte;
        crc = (crc << 8) ^ crc_table[(crc >> 24) ^ value];
    }
    return crc;
}

/// What a page's header says.
pub const PageHead = struct {
    flags: u8,
    granule: i64,
    serial: u32,
    sequence: u32,
    /// Its header with the lacing values, and all of it.
    head_bytes: usize,
    bytes: usize,
};

/// The page that begins `bytes`, when one does - its whole header there -
/// and its CRC is right when the whole page is there too.
pub fn pageAt(bytes: []const u8) ?PageHead {
    if (bytes.len < 27 or !_stream.same(bytes, "OggS") or bytes[4] != 0) return null;
    const count: usize = bytes[26];
    if (bytes.len < 27 + count) return null;
    var body: usize = 0;
    for (bytes[27 .. 27 + count]) |value| body += value;
    const head: PageHead = .{
        .flags = bytes[5],
        .granule = @bitCast(@as(u64, _stream.le32(bytes[6..10])) | @as(u64, _stream.le32(bytes[10..14])) << 32),
        .serial = _stream.le32(bytes[14..18]),
        .sequence = _stream.le32(bytes[18..22]),
        .head_bytes = 27 + count,
        .bytes = 27 + count + body,
    };
    if (bytes.len >= head.bytes and pageCrc(bytes[0..head.bytes]) != _stream.le32(bytes[22..26])) return null;
    return head;
}

/// The next page of the stream read, its header taken: false at the
/// source's end. Bytes that are no page are passed over until one is.
pub fn nextPage(stream: *Stream, ogg: *Ogg) bool {
    while (true) {
        if (stream.stop - stream.start < 27 + 255) _stream.fill(stream);
        var bytes = _stream.available(stream);
        if (bytes.len < 27) return false;
        if (!_stream.same(bytes, "OggS")) {
            passToCapture(stream, bytes);
            continue;
        }
        // The whole page in the read-ahead when it can be, to check it.
        if (bytes.len >= 27 and bytes.len >= 27 + @as(usize, bytes[26])) {
            var length: usize = 27 + @as(usize, bytes[26]);
            for (bytes[27..length]) |value| length += value;
            if (length > bytes.len and length <= _stream.input_bytes) {
                _stream.fill(stream);
                bytes = _stream.available(stream);
            }
        }
        const head = pageAt(bytes) orelse {
            _stream.consume(stream, 1);
            continue;
        };
        if (!ogg.has_serial) {
            ogg.serial = head.serial;
            ogg.has_serial = true;
        }
        if (head.serial != ogg.serial) {
            _stream.skip(stream, head.bytes);
            continue;
        }
        // A page missing between this and the one before: a packet going
        // on from it has lost its middle.
        if (ogg.have_page and head.sequence != ogg.sequence +% 1) ogg.pass_continued = true;
        ogg.page_offset = _stream.tell(stream);
        @memcpy(ogg.lacing[0 .. head.head_bytes - 27], bytes[27..head.head_bytes]);
        ogg.segments = @intCast(head.head_bytes - 27);
        ogg.segment = 0;
        ogg.left = 0;
        ogg.granule = head.granule;
        ogg.flags = head.flags;
        ogg.sequence = head.sequence;
        ogg.have_page = true;
        ogg.last_end = -1;
        var index: usize = ogg.segments;
        while (index > 0) {
            index -= 1;
            if (ogg.lacing[index] < 255) {
                ogg.last_end = @intCast(index);
                break;
            }
        }
        _stream.consume(stream, head.head_bytes);
        return true;
    }
}

/// Bytes with no page at their front passed over, up to the next "OggS"
/// or all but the last three, which may be its beginning.
fn passToCapture(stream: *Stream, bytes: []const u8) void {
    var at: usize = 1;
    while (at + 4 <= bytes.len) : (at += 1) {
        if (bytes[at] == 'O' and _stream.same(bytes[at..], "OggS")) {
            _stream.consume(stream, at);
            return;
        }
    }
    if (stream.eof) {
        _stream.consume(stream, bytes.len);
        return;
    }
    _stream.consume(stream, bytes.len - 3);
}

// --- packets ----------------------------------------------------------------------

/// The next packet begun: false at the end of the stream. A packet whose
/// beginning was not read is passed over first.
pub fn startPacket(stream: *Stream, ogg: *Ogg) bool {
    while (true) {
        if (!ogg.have_page or ogg.segment >= ogg.segments) {
            if (ogg.have_page and ogg.flags & last != 0) return false;
            if (!nextPage(stream, ogg)) return false;
            if (ogg.flags & continued == 0) ogg.pass_continued = false;
        }
        if (ogg.segment == 0 and ogg.flags & continued != 0 and ogg.pass_continued) {
            // The segments of the packet begun elsewhere, up to its end.
            while (ogg.segment < ogg.segments) {
                const value = ogg.lacing[ogg.segment];
                ogg.segment += 1;
                _stream.skip(stream, value);
                if (value < 255) {
                    ogg.pass_continued = false;
                    break;
                }
            }
            continue;
        }
        if (ogg.segment >= ogg.segments) continue;
        enterSegment(ogg);
        return true;
    }
}

/// The page's next segment begun, as part of the packet being read.
fn enterSegment(ogg: *Ogg) void {
    const index = ogg.segment;
    const value = ogg.lacing[index];
    ogg.segment += 1;
    ogg.left = value;
    ogg.final = value < 255;
    if (ogg.final) {
        const closes = @as(i32, @intCast(index)) == ogg.last_end;
        ogg.packet_granule = if (closes) ogg.granule else -1;
        ogg.packet_ends_stream = closes and ogg.flags & last != 0;
    }
}

/// The packet's next segment begun, on the next page when it goes on
/// there: false when the packet has ended, or is cut short - the source
/// ends, or the next page does not go on with it.
fn advance(stream: *Stream, ogg: *Ogg) bool {
    if (ogg.final) return false;
    if (ogg.segment >= ogg.segments) {
        if (!nextPage(stream, ogg)) {
            ogg.final = true;
            ogg.packet_granule = -1;
            ogg.packet_ends_stream = true;
            return false;
        }
        if (ogg.flags & continued == 0 or ogg.pass_continued) {
            // Cut short: this page's first packet is one of its own, or
            // the rest of this one, which is passed over.
            ogg.final = true;
            ogg.packet_granule = -1;
            ogg.packet_ends_stream = false;
            return false;
        }
    }
    enterSegment(ogg);
    return true;
}

/// The packet's next byte, or null at its end.
pub fn readByte(stream: *Stream, ogg: *Ogg) ?u8 {
    while (ogg.left == 0) {
        if (!advance(stream, ogg)) return null;
    }
    if (stream.start == stream.stop) {
        _stream.fill(stream);
        if (stream.start == stream.stop) {
            ogg.left = 0;
            ogg.final = true;
            return null;
        }
    }
    const byte = stream.in[stream.start];
    stream.start += 1;
    ogg.left -= 1;
    return byte;
}

/// Up to `into.len` bytes of the packet: how many there were.
pub fn readBytes(stream: *Stream, ogg: *Ogg, into: []u8) usize {
    var done: usize = 0;
    while (done < into.len) {
        if (ogg.left == 0) {
            if (!advance(stream, ogg)) break;
            continue;
        }
        if (stream.start == stream.stop) {
            _stream.fill(stream);
            if (stream.start == stream.stop) {
                ogg.left = 0;
                ogg.final = true;
                break;
            }
        }
        const here = _stream.available(stream);
        const count = @min(here.len, into.len - done, ogg.left);
        @memcpy(into[done..][0..count], here[0..count]);
        _stream.consume(stream, count);
        ogg.left -= @intCast(count);
        done += count;
    }
    return done;
}

/// The rest of the packet passed over.
pub fn endPacket(stream: *Stream, ogg: *Ogg) void {
    while (true) {
        if (ogg.left != 0) {
            _stream.skip(stream, ogg.left);
            ogg.left = 0;
        }
        if (!advance(stream, ogg)) return;
    }
}

/// A packet's bytes as a tag reader takes them: `read` and `skip`, `left`
/// of them at most.
pub const PacketReader = struct {
    stream: *Stream,
    ogg: *Ogg,
    left: u64 = 0xFFFF_FFFF_FFFF_FFFF,

    pub fn read(reader: *PacketReader, into: []u8) usize {
        const want: usize = @intCast(@min(@as(u64, into.len), reader.left));
        const got = readBytes(reader.stream, reader.ogg, into[0..want]);
        reader.left -= got;
        return got;
    }

    pub fn skip(reader: *PacketReader, count: u64) void {
        var scratch: [256]u8 = undefined;
        var left = count;
        while (left > 0) {
            const got = reader.read(scratch[0..@intCast(@min(left, scratch.len))]);
            if (got == 0) return;
            left -= got;
        }
    }
};

// --- bits -------------------------------------------------------------------------

/// A packet's bits, least significant first, as the codecs carried in Ogg
/// pack them. A read past the packet's end gives 0 and sets `ended`, and
/// every read after it does the same.
pub const Bits = struct {
    stream: *Stream,
    ogg: *Ogg,
    cache: u64 = 0,
    count: u32 = 0,
    /// The packet has no more bytes.
    drained: bool = false,
    /// A read wanted more bits than the packet had.
    ended: bool = false,

    /// The cache filled to more than 56 bits, or with all the packet has.
    pub fn refill(bits: *Bits) void {
        while (bits.count <= 56 and !bits.drained) {
            if (readByte(bits.stream, bits.ogg)) |byte| {
                bits.cache |= @as(u64, byte) << @intCast(bits.count);
                bits.count += 8;
            } else {
                bits.drained = true;
            }
        }
    }

    /// `width` bits (up to 32), the first read the least significant.
    pub fn read(bits: *Bits, width: u32) u32 {
        if (width == 0) return 0;
        if (bits.count < width) {
            bits.refill();
            if (bits.count < width) {
                bits.ended = true;
                bits.cache = 0;
                bits.count = 0;
                return 0;
            }
        }
        const value: u32 = @truncate(bits.cache & ((@as(u64, 1) << @intCast(width)) - 1));
        bits.cache >>= @intCast(width);
        bits.count -= width;
        return value;
    }

    /// `width` bits dropped after a look at them; past the end, `ended`.
    pub fn drop(bits: *Bits, width: u32) void {
        if (width > bits.count) {
            bits.ended = true;
            bits.cache = 0;
            bits.count = 0;
            return;
        }
        bits.cache >>= @intCast(width);
        bits.count -= width;
    }
};
