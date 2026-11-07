// SPDX-License-Identifier: MIT
//! videoparse.library's host tests: the library made from its ROM tag on
//! the ROM's exec and utility, and an H.264 and an HEVC stream read
//! through it.
//!
//! `rows.h264`, the H.264 decoder's clip, is x264's (High, CABAC) of
//! ffmpeg's testsrc2 at 128x128, 24 frames: three slices a picture, B
//! pyramids, weighted P, four references, an IDR every 12. `rows.h265`,
//! the HEVC decoder's, is x265's (Main) of the same: 16x16 CTBs in three
//! slices a picture and wavefronts, B pyramids, weighted prediction, four
//! references, open GOPs (a CRA every 12 with RASL pictures before it).
//! Their events are read with the stream handed over whole, a unit a
//! packet and an access unit a packet, with the slots given back at once
//! and held back until the parser runs out of them, and with a seek on
//! the way: what they say is the same.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vp = sdk.videoparse;
const utility = sdk.utility;
const host = @import("host_rom");
const kexec = host.exec;
const videoparse_init = @import("../videoparse_init.zig");
const nal = @import("../h264/nal.zig");
const hevc_nal = @import("../hevc/nal.zig");
const VideoParseBase = sdk.interface.videoparse.VideoParseBase;

const testing = std.testing;

test {
    _ = @import("../videoparse_lvo.zig");
    _ = @import("../parser/_parser.zig");
    _ = @import("../h264/dpb.zig");
    _ = @import("../h264/bits.zig");
    _ = @import("../h264/nal.zig");
    _ = @import("../h264/params.zig");
    _ = @import("../h264/slice.zig");
    _ = @import("../h264/_h264.zig");
    _ = @import("../hevc/dpb.zig");
    _ = @import("../hevc/bits.zig");
    _ = @import("../hevc/nal.zig");
    _ = @import("../hevc/params.zig");
    _ = @import("../hevc/slice.zig");
    _ = @import("../hevc/_hevc.zig");
}

/// The decoders' clips.
const rows = @embedFile("../../codecs/h264/tests/rows.h264");
const rows_hevc = @embedFile("../../codecs/hevc/tests/rows.h265");

/// Memory lent to exec: a parser takes some 265 KiB for H.264, 330 KiB
/// for HEVC.
var lent: [1024 * 1024]u8 align(16) = undefined;

/// exec and utility up with memory lent, the library made and opened.
const Rig = struct {
    ub: *host.utility.UtilityBase = undefined,
    region: *exec.MemHeader = undefined,
    library: *exec.Library = undefined,
    vpb: *VideoParseBase = undefined,

    fn up(rig: *Rig) !void {
        rig.ub = try host.utility.setUp();
        const sys = kexec.SysBase.iface();
        rig.region = sys.AddMemList(lent.len, exec.MEMF_ANY, 0, &lent, "lent").?;
        const lib = kexec.InitResident(kexec.SysBase, &videoparse_init.videoparse_library_tag, null) orelse return error.NoLibrary;
        rig.library = @ptrCast(@alignCast(lib));
        rig.vpb = @ptrCast(sys.OpenLibrary(vp.VIDEOPARSENAME, 1) orelse return error.NoBase);
    }

    /// The library closed and expunged, and nothing left behind.
    fn down(rig: *Rig) !void {
        const sys = kexec.SysBase.iface();
        sys.CloseLibrary(rig.vpb.lib());
        _ = sys.RemLibrary(rig.library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, vp.VIDEOPARSENAME) == null);
        try testing.expectEqual(@intFromPtr(rig.region.upper) - @intFromPtr(rig.region.lower), rig.region.free);
        sys.Remove(&rig.region.node);
        try host.utility.tearDown(rig.ub);
        kexec.deinit();
    }
};

/// How the stream is handed over and its slots given back.
const Way = struct {
    codec: u32 = vp.VPCODEC_H264,
    packets: enum { whole, units, access_units } = .whole,
    /// Slots given back only when the parser has none left (VPERR_FULL).
    hold: bool = false,
    /// The caller's own slots (VPA_Slots).
    slots: u32 = 0,
    /// After so many events: a seek to the stream's start.
    reset_after: ?u32 = null,
};

/// What the events said, by the pictures' own numbers counted from the
/// first (slots differ with the way they are given back): a hash, and
/// the counts.
const Trace = struct {
    hash: u64 = 0xcbf29ce484222325,
    sequences: u32 = 0,
    pictures: u32 = 0,
    slices: u32 = 0,
    decodes: u32 = 0,
    missing: u32 = 0,
    shown: u32 = 0,
    freed: u32 = 0,
    /// Pictures shown in an order count lower than the one before: once
    /// for each IDR picture after the first.
    turns: u32 = 0,
    last_poc: i32 = std.math.minInt(i32),
    /// Every shown picture's time came in the order the packets did.
    times_rise: bool = true,
    last_time: i64 = -1,
    first_uid: u32 = 0,
    uid_of: [64]u32 = @splat(0),
    poc_of: [64]i32 = @splat(0),

    /// The slots let go of together, in no order of their own (they go
    /// in slot order, and the slots differ with when they come back): by
    /// number, mixed in when another event comes.
    frees: u64 = 0,
    /// The sequence's slots, the caller's among them.
    slots: u32 = 0,

    fn mix(t: *Trace, v: anytype) void {
        const bits: u64 = @bitCast(@as(i64, v));
        t.hash = (t.hash ^ bits) *% 0x100000001b3;
    }

    fn mixFrees(t: *Trace) void {
        if (t.frees == 0) return;
        t.mix(vp.VPEV_FREE);
        t.mix(@as(i64, @bitCast(t.frees)));
        t.frees = 0;
    }

    /// A picture's number from the first one's.
    fn rel(t: *Trace, uid: u32) u32 {
        if (uid == 0) return 0;
        if (t.first_uid == 0) t.first_uid = uid;
        return uid -% t.first_uid +% 1;
    }

    fn take(t: *Trace, e: *const vp.VideoEvent) !void {
        if (e.kind != vp.VPEV_FREE) {
            t.mixFrees();
            t.mix(e.kind);
        }
        switch (e.kind) {
            vp.VPEV_SEQUENCE => {
                const s = e.sequence.?;
                t.sequences += 1;
                try testing.expectEqual(@as(u32, 128), s.width);
                try testing.expectEqual(@as(u32, 128), s.height);
                t.slots = s.slots;
                for ([_]u32{ s.coded_width, s.coded_height, s.dpb_frames, s.reorder, s.chroma_format, s.profile }) |v| t.mix(v);
            },
            vp.VPEV_PICTURE, vp.VPEV_MISSING => {
                const pic = e.picture.?;
                try testing.expectEqual(e.slot, pic.slot);
                if (e.kind == vp.VPEV_MISSING) t.missing += 1 else t.pictures += 1;
                t.uid_of[e.slot] = pic.uid;
                t.poc_of[e.slot] = @min(pic.poc[0], pic.poc[1]);
                for ([_]i64{ t.rel(pic.uid), pic.poc[0], pic.poc[1], pic.structure, @intFromBool(pic.idr), @intFromBool(pic.reference), pic.frame_num, pic.ref_count, pic.nal_type, @intFromBool(pic.irap), @intFromBool(pic.no_rasl_output), pic.st_rps_bits }) |v| t.mix(v);
                // The references in no order of their own: by number.
                var sum: u64 = 0;
                for (pic.refs[0..pic.ref_count]) |r| {
                    try testing.expectEqual(t.uid_of[r.slot], r.uid);
                    sum +%= @as(u64, t.rel(r.uid)) *% 0x9E3779B97F4A7C15 +% @as(u64, r.fields) +% @as(u64, @intFromBool(r.long_term)) * 7;
                }
                t.mix(@as(i64, @bitCast(sum)));
                // HEVC's sets, in their order.
                for (pic.rps, pic.rps_count) |set, count| {
                    t.mix(count);
                    for (set[0..count]) |idx| {
                        try testing.expect(idx < pic.ref_count);
                        t.mix(t.rel(pic.refs[idx].uid));
                    }
                }
            },
            vp.VPEV_SLICE => {
                const s = e.slice.?;
                t.slices += 1;
                for ([_]i64{ s.count[0], s.count[1], s.data_bit, s.rbsp_bytes, s.unit_bytes }) |v| t.mix(v);
                if (s.h264) |h| {
                    for ([_]i64{ @intFromEnum(h.kind), h.first_mb }) |v| t.mix(v);
                } else {
                    const h = s.hevc.?;
                    for ([_]i64{ @intFromEnum(h.slice_type), h.segment_address, @intFromBool(h.dependent) }) |v| t.mix(v);
                    if (s.collocated != vp.VP_NO_SLOT) t.mix(t.rel(t.uid_of[s.collocated]));
                }
                for (0..2) |l| {
                    for (s.lists[l][0..s.count[l]]) |entry| {
                        if (entry.slot != vp.VP_NO_SLOT) try testing.expectEqual(t.uid_of[entry.slot], entry.uid);
                        for ([_]i64{ t.rel(entry.uid), entry.structure, @intFromBool(entry.long_term), entry.poc[0], entry.poc[1] }) |v| t.mix(v);
                    }
                }
            },
            vp.VPEV_DECODE => {
                t.decodes += 1;
                t.mix(t.rel(t.uid_of[e.slot]));
            },
            vp.VPEV_SHOW => {
                t.shown += 1;
                t.mix(t.rel(t.uid_of[e.slot]));
                const poc = t.poc_of[e.slot];
                if (poc <= t.last_poc) t.turns += 1;
                t.last_poc = poc;
                if (e.time <= t.last_time) t.times_rise = false;
                t.last_time = e.time;
            },
            vp.VPEV_FREE => {
                t.freed += 1;
                t.frees +%= @as(u64, t.rel(t.uid_of[e.slot])) *% 0x9E3779B97F4A7C15;
            },
            else => return error.UnknownEvent,
        }
    }
};

/// The caller's side of the slots: which it holds, and those the stream
/// let go of that it has not given back yet, oldest first.
const Slots = struct {
    held: [64]bool = @splat(false),
    waiting: [64]u8 = undefined,
    count: u32 = 0,

    fn give(s: *Slots, vpb: *VideoParseBase, parser: *vp.VideoParser, slot: u32) !void {
        try testing.expect(s.held[slot]);
        s.held[slot] = false;
        vpb.ReleaseVideoSlot(parser, slot);
    }

    fn oldest(s: *Slots, vpb: *VideoParseBase, parser: *vp.VideoParser) !void {
        if (s.count == 0) return error.Stuck;
        const slot = s.waiting[0];
        std.mem.copyForwards(u8, s.waiting[0 .. s.count - 1], s.waiting[1..s.count]);
        s.count -= 1;
        try s.give(vpb, parser, slot);
    }

    fn all(s: *Slots, vpb: *VideoParseBase, parser: *vp.VideoParser) !void {
        s.count = 0;
        for (&s.held, 0..) |held, slot| {
            if (held) try s.give(vpb, parser, @intCast(slot));
        }
    }
};

/// The packets of a stream in Annex B form: the whole of it, a unit each,
/// or an access unit each - which begins at an access unit delimiter, a
/// parameter set or SEI after a slice, or a slice that begins a picture
/// (first_mb_in_slice 0, first_slice_segment_in_pic_flag 1).
const Packets = struct {
    data: []const u8,
    way: @FieldType(Way, "packets"),
    hevc: bool = false,
    at: usize = 0,

    fn next(it: *Packets) ?[]const u8 {
        if (it.at >= it.data.len) return null;
        if (it.way == .whole) {
            it.at = it.data.len;
            return it.data;
        }
        var units = nal.AnnexB{ .data = it.data[it.at..] };
        const first = units.next() orelse {
            it.at = it.data.len;
            return null;
        };
        var end = it.data.len;
        if (it.way == .units) {
            if (units.next()) |u| end = startOf(it.data, u);
        } else {
            // Once a slice came, the next access unit begins.
            var sliced = it.isSlice(first);
            while (units.next()) |u| {
                if (sliced and it.begins(u)) {
                    end = startOf(it.data, u);
                    break;
                }
                if (it.isSlice(u)) sliced = true;
            }
        }
        const packet = it.data[it.at..end];
        it.at = end;
        return packet;
    }

    fn isSlice(it: *const Packets, u: []const u8) bool {
        if (it.hevc) {
            const h = hevc_nal.header(u) catch return false;
            return h.isSlice();
        }
        const kind = u[0] & 0x1F;
        return kind == 1 or kind == 5;
    }

    /// Whether the unit `u` begins an access unit, once a slice came.
    fn begins(it: *const Packets, u: []const u8) bool {
        if (it.hevc) {
            const h = hevc_nal.header(u) catch return false;
            if (h.isSlice()) return u.len > 2 and u[2] & 0x80 != 0;
            return (h.kind >= hevc_nal.Type.vps and h.kind <= hevc_nal.Type.aud) or h.kind == hevc_nal.Type.prefix_sei or
                (h.kind >= 41 and h.kind <= 44) or (h.kind >= 48 and h.kind <= 55);
        }
        const kind = u[0] & 0x1F;
        if (it.isSlice(u)) return u[1] & 0x80 != 0;
        return kind >= 6 and kind <= 9;
    }

    /// Where the start code before the unit `u` begins.
    fn startOf(data: []const u8, u: []const u8) usize {
        return @intFromPtr(u.ptr) - @intFromPtr(data.ptr) - 3;
    }
};

fn read(vpb: *VideoParseBase, way: Way) !Trace {
    var err: i32 = 0;
    const tags = [_]utility.TagItem{ .{ .tag = vp.VPA_Slots, .data = way.slots }, .{} };
    const parser = vpb.OpenVideoParser(way.codec, null, 0, &tags, &err) orelse return error.NoParser;
    const hevc = way.codec == vp.VPCODEC_HEVC;
    const stream = if (hevc) rows_hevc else rows;
    defer vpb.CloseVideoParser(parser);
    var trace: Trace = .{};
    var slots: Slots = .{};
    var packets: Packets = .{ .data = stream, .way = way.packets, .hevc = hevc };
    var events: u32 = 0;
    var index: i64 = 0;
    var ended = false;
    while (!ended) {
        var packet: vp.VideoPacket = .{ .time = index * 1000 };
        index += 1;
        if (packets.next()) |bytes| {
            packet.data = bytes.ptr;
            packet.bytes = @intCast(bytes.len);
            if (way.packets == .access_units) packet.flags = vp.VPPKT_ACCESS_UNIT;
        } else packet.flags = vp.VPPKT_END;
        try testing.expectEqual(vp.VPERR_OK, vpb.ParseVideoPacket(parser, &packet));
        var event: vp.VideoEvent = .{};
        while (true) {
            switch (vpb.NextVideoEvent(parser, &event)) {
                vp.VPERR_OK => {},
                vp.VPERR_NEED_DATA => break,
                vp.VPERR_END => {
                    ended = true;
                    break;
                },
                vp.VPERR_FULL => {
                    try slots.oldest(vpb, parser);
                    continue;
                },
                else => return error.Unexpected,
            }
            // The next packet is refused while this one has events.
            try testing.expectEqual(vp.VPERR_FULL, vpb.ParseVideoPacket(parser, &packet));
            try trace.take(&event);
            events += 1;
            switch (event.kind) {
                vp.VPEV_PICTURE => if (!event.picture.?.second_field) {
                    try testing.expect(!slots.held[event.slot]);
                    slots.held[event.slot] = true;
                },
                vp.VPEV_MISSING => slots.held[event.slot] = true,
                vp.VPEV_FREE => if (way.hold) {
                    slots.waiting[slots.count] = @intCast(event.slot);
                    slots.count += 1;
                } else try slots.give(vpb, parser, event.slot),
                else => {},
            }
            if (way.reset_after == events) {
                // A seek to the start: what the caller holds given back.
                vpb.ResetVideoParser(parser);
                try slots.all(vpb, parser);
                trace = .{};
                packets = .{ .data = stream, .way = way.packets, .hevc = hevc };
                index = 0;
                break;
            }
        }
    }
    trace.mixFrees();
    // Sixteen frames, the picture being decoded, a lone field (H.264's),
    // or sixteen pictures and two missing ones (HEVC's): the stream's own,
    // then the caller's.
    try testing.expectEqual(18 + way.slots, trace.slots);
    // Every slot handed out was let go of by the stream at its end.
    try slots.all(vpb, parser);
    try testing.expectEqual(trace.pictures + trace.missing, trace.freed);
    return trace;
}

test "rows.h264's events: its pictures, slices and references, shown in order, the same however it is handed over" {
    var rig: Rig = .{};
    try rig.up();
    defer rig.down() catch |e| std.debug.panic("down: {}", .{e});

    const whole = try read(rig.vpb, .{});
    try testing.expectEqual(@as(u32, 1), whole.sequences);
    try testing.expectEqual(@as(u32, 24), whole.pictures);
    try testing.expectEqual(@as(u32, 72), whole.slices);
    try testing.expectEqual(@as(u32, 24), whole.decodes);
    try testing.expectEqual(@as(u32, 0), whole.missing);
    try testing.expectEqual(@as(u32, 24), whole.shown);
    try testing.expectEqual(@as(u32, 1), whole.turns);
    try sameEveryWay(rig.vpb, vp.VPCODEC_H264, whole);
}

test "rows.h265's events: its pictures, segments and reference picture sets, shown in order, the same however it is handed over" {
    var rig: Rig = .{};
    try rig.up();
    defer rig.down() catch |e| std.debug.panic("down: {}", .{e});

    const whole = try read(rig.vpb, .{ .codec = vp.VPCODEC_HEVC });
    try testing.expectEqual(@as(u32, 1), whole.sequences);
    try testing.expectEqual(@as(u32, 24), whole.pictures);
    try testing.expectEqual(@as(u32, 24), whole.decodes);
    try testing.expectEqual(@as(u32, 0), whole.missing);
    try testing.expectEqual(@as(u32, 24), whole.shown);
    // One IDR picture at the start: the order counts rise throughout.
    try testing.expectEqual(@as(u32, 0), whole.turns);
    try sameEveryWay(rig.vpb, vp.VPCODEC_HEVC, whole);
}

/// The stream read a unit a packet and an access unit a packet says what
/// it says whole; with the slots held back, with the caller's own and
/// with seeks on the way, too.
fn sameEveryWay(vpb: *VideoParseBase, codec: u32, whole: Trace) !void {
    var units = try read(vpb, .{ .codec = codec, .packets = .units });
    units.times_rise = whole.times_rise;
    units.last_time = whole.last_time;
    try testing.expectEqual(whole, units);
    const access_units = try read(vpb, .{ .codec = codec, .packets = .access_units });
    // An access unit a packet, each with its decoding time: the pictures
    // are shown at times that rise.
    try testing.expect(access_units.times_rise);
    try testing.expectEqual(whole.hash, access_units.hash);
    try testing.expectEqual(whole.shown, access_units.shown);
    for ([_]u32{ 0, 1, 4 }) |slots| {
        const held = try read(vpb, .{ .codec = codec, .hold = true, .slots = slots, .packets = .access_units });
        try testing.expectEqual(whole.hash, held.hash);
    }
    var at: u32 = 3;
    while (at < 200) : (at += 17) {
        const sought = try read(vpb, .{ .codec = codec, .reset_after = at, .packets = if (at & 1 != 0) .access_units else .units, .hold = at & 2 != 0 });
        try testing.expectEqual(whole.hash, sought.hash);
        try testing.expectEqual(whole.shown, sought.shown);
    }
}
