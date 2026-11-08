// SPDX-License-Identifier: MIT
//! What every parser has, whatever its codec: the packet it reads and how
//! far, the units cut from it, and the queue of events the codec's
//! reading put on it, handed out one by one.
//!
//! **The units** are cut from the packet as they are asked for - each
//! after a start code (Annex B), or after its length in as many bytes as
//! the setup said; a VP9 packet's are its frames, an AV1 packet's its
//! OBUs. A unit is looked at (`peek`) before it is gone past (`advance`):
//! the codec's reading may stop at a unit that needs a slot none is free
//! for, and read it again once one was given back - or at one that says
//! more than one slice holds (an AV1 frame's tiles), and read it on once
//! the events before are out.
//!
//! **The events** go onto a ring in the order they happen - a picture
//! finished and its marking's VPEV_FREE and VPEV_SHOW, then the next
//! picture's VPEV_PICTURE and its VPEV_SLICE - and the next unit is read
//! only once the ring is empty, so a pointer an event carries is still
//! good when the event is handed out.
//!
//! **The codec's reading** is H.264's, HEVC's, VP9's or AV1's (`h264/`,
//! `hevc/`, `vp9/`, `av1/`): the calls reach it through `before`, `unit`,
//! `endAccessUnit`, `flush`, `reset` and `unlend` here, whichever it is.
//!
//! **The light** a film was mastered for is said by messages of the
//! stream's own, the same in each codec that has them (`Light`): each
//! picture is said with it.

const sdk = @import("sdk");
const exec = sdk.exec;
const vp = sdk.videoparse;
const VideoParseBase = @import("../videoparse_base.zig").VideoParseBase;
const h264 = @import("../h264/_h264.zig");
const hevc = @import("../hevc/_hevc.zig");
const vp9 = @import("../vp9/_vp9.zig");
const av1 = @import("../av1/_av1.zig");
const Error = @import("h264sets").bits.Error;

/// What reading a unit came to: read; to be read on once the events
/// before it are out; to be read again once a slot is free.
pub const Step = enum { done, again, full };

/// The events a parser holds at most: a picture finished with its
/// marking and bumping, the frames of a gap, the next picture's own.
const ring_size = 512;

pub const Events = struct {
    ring: [ring_size]vp.VideoEvent = undefined,
    head: u32 = 0,
    count: u32 = 0,

    pub fn push(e: *Events, event: vp.VideoEvent) void {
        if (e.count == ring_size) return;
        e.ring[(e.head + e.count) % ring_size] = event;
        e.count += 1;
    }

    pub fn pop(e: *Events) ?vp.VideoEvent {
        if (e.count == 0) return null;
        const event = e.ring[e.head];
        e.head = (e.head + 1) % ring_size;
        e.count -= 1;
        return event;
    }

    pub fn clear(e: *Events) void {
        e.head = 0;
        e.count = 0;
    }
};

/// A stream being read: what `OpenVideoParser` hands out.
pub const Parser = struct {
    base: *VideoParseBase,
    codec: u32,
    /// The bytes before each unit, from the setup; 0 for Annex B.
    length_size: u8,
    /// The slots the caller keeps beyond the stream's own (VPA_Slots).
    extra_slots: u32,
    /// The largest picture taken, in macroblocks (16 samples).
    max_width_mbs: u32,
    max_height_mbs: u32,
    /// The packet handed over, and how far it is read: `at` the next
    /// unit's start, `unit_end` past the unit `peek` found.
    packet: vp.VideoPacket,
    at: u32,
    unit_end: u32,
    has_packet: bool,
    /// Its end handled: the access unit's (VPPKT_ACCESS_UNIT), the
    /// stream's (VPPKT_END).
    unit_ended: bool,
    stream_ended: bool,
    events: Events,
    /// The light the film was mastered for, as its messages said.
    light: Light,
    /// The codec's own reading: one of the four.
    h264: ?*h264.State,
    hevc: ?*hevc.State,
    vp9: ?*vp9.State,
    av1: ?*av1.State,

    /// A packet to read.
    pub fn take(p: *Parser, packet: *const vp.VideoPacket) void {
        p.packet = packet.*;
        if (p.packet.data == null) p.packet.bytes = 0;
        p.at = 0;
        p.unit_end = 0;
        p.has_packet = true;
        p.unit_ended = false;
        p.stream_ended = false;
    }

    /// The packet's bytes.
    pub fn bytes(p: *const Parser) []const u8 {
        const data = p.packet.data orelse return &.{};
        return data[0..p.packet.bytes];
    }

    /// The next unit of the packet, without its start code or length and
    /// without the zero bytes after it - a VP9 packet's next frame, an
    /// AV1 packet's next OBU; null at the packet's end, and error.Corrupt
    /// for a length past it.
    pub fn peek(p: *Parser) error{Corrupt}!?[]const u8 {
        if (p.vp9) |st| return vp9.peek(p, st);
        if (p.av1 != null) return av1.peek(p);
        const d = p.bytes();
        var at: usize = p.at;
        while (true) {
            if (p.length_size != 0) {
                if (at >= d.len) return null;
                if (at + p.length_size > d.len) return error.Corrupt;
                var len: usize = 0;
                for (d[at..][0..p.length_size]) |byte| len = len << 8 | byte;
                at += p.length_size;
                if (len > d.len - at) return error.Corrupt;
                p.unit_end = @intCast(at + len);
                if (len == 0) {
                    p.at = p.unit_end;
                    continue;
                }
                return d[at..][0..len];
            }
            // The next start code, and the unit up to the one after it.
            var i = at;
            while (i + 3 <= d.len) : (i += 1) {
                if (d[i] == 0 and d[i + 1] == 0 and d[i + 2] == 1) break;
            } else {
                p.at = @intCast(d.len);
                return null;
            }
            const start = i + 3;
            var j = start;
            while (j + 3 <= d.len) : (j += 1) {
                if (d[j] == 0 and d[j + 1] == 0 and (d[j + 2] == 1 or d[j + 2] == 0)) break;
            } else j = d.len;
            var end = j;
            // A zero_byte or trailing_zero_8bits belongs to no unit.
            while (end > start and d[end - 1] == 0) end -= 1;
            p.unit_end = @intCast(j);
            if (end == start) {
                at = j;
                p.at = p.unit_end;
                continue;
            }
            return d[start..end];
        }
    }

    /// Past the unit `peek` found.
    pub fn advance(p: *Parser) void {
        p.at = p.unit_end;
    }

    /// Memory of the library's, cleared; null where there is none.
    pub fn alloc(p: *Parser, len: usize) ?[*]u8 {
        const memory = p.base.sys_base.AllocVec(len, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
        return @ptrCast(memory);
    }

    pub fn free(p: *Parser, memory: ?[*]u8) void {
        if (memory) |m| p.base.sys_base.FreeVec(m);
    }
};

/// A buffer the reading grows as it needs: its memory and its length.
pub const Buffer = struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,

    /// At least `len` bytes: false where there is no memory for them.
    pub fn reserve(b: *Buffer, p: *Parser, len: usize) bool {
        if (b.len >= len) return true;
        p.free(b.ptr);
        b.* = .{};
        const memory = p.alloc(len) orelse return false;
        b.* = .{ .ptr = memory, .len = len };
        return true;
    }

    pub fn slice(b: *const Buffer) []u8 {
        const memory = b.ptr orelse return &.{};
        return memory[0..b.len];
    }

    pub fn release(b: *Buffer, p: *Parser) void {
        p.free(b.ptr);
        b.* = .{};
    }
};

/// The light a film was mastered for, in candelas a square metre, as its
/// own messages say: H.264's and HEVC's SEI - the mastering display's
/// colour volume (payload 137) and the content light level (144), whose
/// syntax is the same in both - and AV1's metadata OBUs (HDR_MDCV and
/// HDR_CLL). It is what a film of high dynamic range is mapped into a
/// screen's range from.
///
/// What the messages before a picture said is gathered and made the
/// film's light when the picture begins (`settle`): the mastering
/// display's maximum, or the film's brightest pixel where that is said
/// too and is lower - a film is no brighter than its brightest pixel,
/// and mapping it from a light it never reaches would darken it for
/// nothing. Gathered by the picture rather than taken message by message,
/// since an encoder may put each message in a unit of its own. A seek
/// keeps it: it is the film's.
pub const Light = struct {
    /// What the messages since the last picture said: the mastering
    /// display's maximum, and the film's brightest pixel; 0 where not.
    mastering: u32 = 0,
    content: u32 = 0,
    /// The film's light as it stands: 0 until a message said it.
    peak: u16 = 0,

    /// An SEI unit's payload, unescaped: its messages, each a type and a
    /// size (both in bytes of 255 and a last one below), then that many
    /// bytes; the RBSP's last byte ends it. The mastering display's
    /// maximum follows its primaries and white point (16 bytes), in ten
    /// thousandths of a candela; the content light level's brightest
    /// pixel is its first two bytes, in candelas.
    pub fn sei(l: *Light, rbsp: []const u8) void {
        var at: usize = 0;
        while (at + 1 < rbsp.len) {
            const kind = sum(rbsp, &at) orelse return;
            const size = sum(rbsp, &at) orelse return;
            if (size > rbsp.len - at) return;
            const payload = rbsp[at..][0..size];
            at += size;
            switch (kind) {
                137 => if (size >= 24) {
                    l.mastering = be32(payload[16..20]) / 10000;
                },
                144 => if (size >= 4) {
                    l.content = be16(payload[0..2]);
                },
                else => {},
            }
        }
    }

    /// A metadata OBU's payload: its type (a leb128, one byte for the
    /// two read), then for HDR_CLL the brightest pixel in candelas, for
    /// HDR_MDCV the primaries and white point (16 bytes) and the maximum
    /// in 256ths of a candela.
    pub fn metadata(l: *Light, payload: []const u8) void {
        if (payload.len == 0 or payload[0] & 0x80 != 0) return;
        const rest = payload[1..];
        switch (payload[0]) {
            1 => if (rest.len >= 2) {
                l.content = be16(rest[0..2]);
            },
            2 => if (rest.len >= 20) {
                l.mastering = be32(rest[16..20]) >> 8;
            },
            else => {},
        }
    }

    /// The film's light as of the picture beginning: what was gathered
    /// before it made the light, and gathered afresh after.
    pub fn settle(l: *Light) u16 {
        const said = if (l.mastering != 0 and l.content != 0)
            @min(l.mastering, l.content)
        else if (l.mastering != 0) l.mastering else l.content;
        if (said != 0) l.peak = @intCast(@min(said, 10000));
        l.mastering = 0;
        l.content = 0;
        return l.peak;
    }

    /// A number of SEI's form: bytes of 255 added up to the first below.
    fn sum(bytes: []const u8, at: *usize) ?u32 {
        var value: u32 = 0;
        while (at.* < bytes.len) {
            const byte = bytes[at.*];
            at.* += 1;
            value += byte;
            if (byte != 0xff) return value;
        }
        return null;
    }

    fn be16(b: *const [2]u8) u32 {
        return @as(u32, b[0]) << 8 | b[1];
    }

    fn be32(b: *const [4]u8) u32 {
        return @as(u32, b[0]) << 24 | @as(u32, b[1]) << 16 | @as(u32, b[2]) << 8 | b[3];
    }
};

/// What a reading's error is said as.
pub fn codeOf(e: Error) i32 {
    return switch (e) {
        error.Corrupt => vp.VPERR_CORRUPT,
        error.Unsupported => vp.VPERR_UNSUPPORTED,
        error.NoMemory => vp.VPERR_NOMEMORY,
    };
}

// --- the codec's reading ---------------------------------------------------------

/// What comes before the unit `u` is read (H.264's data partitions).
pub fn before(p: *Parser, u: []const u8) Error!Step {
    if (p.h264) |st| return h264.before(p, st, u);
    return .done;
}

/// The unit `u`, once `before` is done with it.
pub fn unit(p: *Parser, u: []const u8) Error!Step {
    if (p.h264) |st| return h264.unit(p, st, u);
    if (p.vp9) |st| return vp9.unit(p, st, u);
    if (p.av1) |st| return av1.unit(p, st, u);
    return hevc.unit(p, p.hevc.?, u);
}

/// The packet's access unit ended: nothing to VP9, whose packets are
/// their frames; AV1's temporal unit, whose frame is shown.
pub fn endAccessUnit(p: *Parser) Error!Step {
    if (p.h264) |st| return h264.endAccessUnit(p, st);
    if (p.vp9 != null) return .done;
    if (p.av1) |st| return av1.endAccessUnit(p, st);
    return hevc.endAccessUnit(p, p.hevc.?);
}

/// The stream ended.
pub fn flush(p: *Parser) Error!Step {
    if (p.h264) |st| return h264.flush(p, st);
    if (p.vp9) |st| return vp9.flush(p, st);
    if (p.av1) |st| return av1.flush(p, st);
    return hevc.flush(p, p.hevc.?);
}

/// Everything dropped, for a seek.
pub fn reset(p: *Parser) void {
    if (p.h264) |st| return h264.reset(st);
    if (p.hevc) |st| hevc.reset(st);
    if (p.vp9) |st| vp9.reset(st);
    if (p.av1) |st| av1.reset(st);
}

/// The slot `slot` the caller's no more.
pub fn unlend(p: *Parser, slot: u32) void {
    if (p.h264) |st| {
        if (slot < st.dpb.count) st.dpb.pics[slot].lent = false;
    } else if (p.hevc) |st| {
        if (slot < st.dpb.count) st.dpb.pics[slot].lent = false;
    } else if (p.vp9) |st| {
        vp9.unlend(st, slot);
    } else if (p.av1) |st| av1.unlend(st, slot);
}

/// The parser behind a handle.
pub fn of(handle: *vp.VideoParser) *Parser {
    return @ptrCast(@alignCast(handle));
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the queue hands its events out in order, and holds as many as it has room for" {
    var events: Events = .{};
    for (0..3) |n| events.push(.{ .kind = vp.VPEV_SHOW, .slot = @intCast(n) });
    for (0..3) |n| try testing.expectEqual(@as(u32, @intCast(n)), events.pop().?.slot);
    try testing.expect(events.pop() == null);
    for (0..ring_size + 4) |_| events.push(.{ .kind = vp.VPEV_FREE });
    try testing.expectEqual(@as(u32, ring_size), events.count);
}

/// An SEI payload of a mastering display's message saying `nits`
/// candelas (0 leaves it out) and a content light level's saying `cll`
/// (likewise), ended as an RBSP is.
fn seiOf(nits: u32, cll: u16, out: []u8) []const u8 {
    var at: usize = 0;
    if (nits != 0) {
        out[0] = 137;
        out[1] = 24;
        @memset(out[2..18], 0x11);
        const most = nits * 10000;
        out[18..22].* = .{ @truncate(most >> 24), @truncate(most >> 16), @truncate(most >> 8), @truncate(most) };
        @memset(out[22..26], 0);
        at = 26;
    }
    if (cll != 0) {
        out[at..][0..6].* = .{ 144, 4, @truncate(cll >> 8), @truncate(cll), 0, 50 };
        at += 6;
    }
    out[at] = 0x80;
    return out[0 .. at + 1];
}

test "the light a film was mastered for, out of its SEI" {
    var bytes: [64]u8 = undefined;
    var light: Light = .{};
    try testing.expectEqual(@as(u16, 0), light.settle());
    light.sei(seiOf(1000, 0, &bytes));
    try testing.expectEqual(@as(u16, 1000), light.settle());
    // Said once, it holds for the pictures after.
    try testing.expectEqual(@as(u16, 1000), light.settle());
    // The film's own brightest pixel below the display's maximum.
    light.sei(seiOf(4000, 600, &bytes));
    try testing.expectEqual(@as(u16, 600), light.settle());
    // The two messages in units of their own, before one picture.
    light.sei(seiOf(4000, 0, &bytes));
    light.sei(seiOf(0, 500, &bytes));
    try testing.expectEqual(@as(u16, 500), light.settle());
    // A message of another kind first, and a type past 255.
    const other = [_]u8{ 5, 2, 0xAA, 0xBB, 0xff, 0x01, 1, 0x00 } ++ [_]u8{ 144, 4, 0x02, 0x58, 0, 0, 0x80 };
    light.sei(&other);
    try testing.expectEqual(@as(u16, 600), light.settle());
    // A message cut short says nothing.
    light.sei(seiOf(2000, 0, &bytes)[0..20]);
    try testing.expectEqual(@as(u16, 600), light.settle());
}

test "the light a film was mastered for, out of AV1's metadata" {
    var light: Light = .{};
    const mdcv = [_]u8{2} ++ [_]u8{0} ** 16 ++ [_]u8{ 0x00, 0x03, 0xE8, 0x00 } ++ [_]u8{0} ** 4;
    light.metadata(&mdcv);
    try testing.expectEqual(@as(u16, 1000), light.settle());
    light.metadata(&mdcv);
    light.metadata(&[_]u8{ 1, 0x01, 0x90, 0x00, 0x64 });
    try testing.expectEqual(@as(u16, 400), light.settle());
    // A type of another kind, and one past a byte's leb128.
    light.metadata(&[_]u8{ 4, 0xB5, 0x00 });
    light.metadata(&[_]u8{ 0x81, 0x01, 0x01, 0x90 });
    try testing.expectEqual(@as(u16, 400), light.settle());
}
