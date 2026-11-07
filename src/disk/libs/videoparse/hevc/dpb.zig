// SPDX-License-Identifier: MIT
//! HEVC's decoded picture buffer, without the samples: each picture's
//! order count (8.3.1), the reference picture set that marks the
//! references before a picture is decoded (8.3.2), a slice's reference
//! lists and collocated picture (8.3.4), and the order pictures are shown
//! in (C.5.2's bumping). A picture is a slot the caller keeps its samples
//! by; what this keeps of it is its marking.
//!
//! A slot is the stream's while its picture is a reference, waits to be
//! shown or is being decoded (`in_use`), and the caller's from when it is
//! handed out until it is given back (`lent`). It is taken for a new
//! picture only when it is neither. Where the stream lets go of one, a
//! VPEV_FREE says so; a picture put out to be shown is a VPEV_SHOW. Both
//! go onto the parser's queue of events (`Events`), in the order they
//! happen.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const params = @import("params.zig");
const nal = @import("nal.zig");
const Header = @import("slice.zig").Header;
const Error = @import("bits.zig").Error;
const Events = @import("../parser/_parser.zig").Events;

/// Sixteen pictures at most in the buffer, the current one among them,
/// and room for references a stream names and lacks; then the slots the
/// caller keeps beyond them (VPA_Slots, 32 at most).
pub const stream_pics = 16 + 2;
pub const max_pics = stream_pics + 32;

pub const RefKind = enum(u8) { none, short, long };

/// What the buffer keeps of a picture.
pub const Pic = struct {
    /// The stream's: a reference, waiting to be shown, or being decoded.
    in_use: bool = false,
    /// The caller's: handed out, and not yet given back.
    lent: bool = false,
    ref: RefKind = .none,
    /// PicOrderCntVal.
    poc: i32 = 0,
    output_needed: bool = false,
    /// PicLatencyCount (C.5.2.3).
    latency: u32 = 0,
    /// It stands for a reference the stream lacks (8.3.3): never shown.
    missing: bool = false,
    /// When it is shown, as its packet said.
    time: i64 = 0,
    /// A number never given twice.
    uid: u32 = 0,

    pub fn isRef(s: *const Pic) bool {
        return s.ref != .none;
    }
};

/// The five sets of a picture's reference picture set (8.3.2), in the
/// standard's order - the sdk's VP_RPS_ numbers - with the order counts
/// they were named by. A null picture is one that is not there.
pub const Rps = struct {
    pic: [5][16]?*Pic = undefined,
    poc: [5][16]i32 = undefined,
    count: [5]u8 = @splat(0),

    pub const before = vp.VP_RPS_ST_CURR_BEFORE;
    pub const after = vp.VP_RPS_ST_CURR_AFTER;
    pub const st_foll = vp.VP_RPS_ST_FOLL;
    pub const long = vp.VP_RPS_LT_CURR;
    pub const lt_foll = vp.VP_RPS_LT_FOLL;

    fn add(r: *Rps, set: usize, s: ?*Pic, poc: i32) Error!void {
        if (r.count[set] == 16) return error.Corrupt;
        r.pic[set][r.count[set]] = s;
        r.poc[set][r.count[set]] = poc;
        r.count[set] += 1;
    }

    /// NumPicTotalCurr's pictures: the three sets the current picture
    /// refers to.
    pub fn total(r: *const Rps) u32 {
        return @as(u32, r.count[before]) + r.count[after] + r.count[long];
    }
};

/// An entry of a reference list.
pub const Ref = struct {
    pic: ?*Pic = null,
    poc: i32 = 0,
    long: bool = false,
};

/// A slice's two lists and its collocated picture.
pub const Lists = struct {
    refs: [2][16]Ref = @splat(@splat(.{})),
    count: [2]u8 = .{ 0, 0 },
    col: ?*Pic = null,
};

pub const Dpb = struct {
    pics: [max_pics]Pic = @splat(.{}),
    /// The slots there are: the stream's and the caller's.
    count: u32 = stream_pics,
    /// The pictures the buffer holds, how many may wait to be shown, and
    /// how many later ones a waiting picture may see decoded before it
    /// must be shown (0: any number), from the SPS (C.5.2.2).
    size: u32 = 16,
    reorder: u32 = 16,
    latency: u32 = 0,
    uid_next: u32 = 1,
    /// Where SHOW and FREE go.
    events: *Events,
    /// PicOrderCntVal of prevTid0Pic (8.3.1).
    prev_tid0_poc: i32 = 0,
    /// No picture since the start, an end of sequence or a reset: the
    /// next IRAP picture has NoRaslOutputFlag 1 whatever its type.
    first: bool = true,
    /// NoRaslOutputFlag of the last IRAP picture: its RASL pictures are
    /// not decoded.
    skip_rasl: bool = false,

    pub fn slotOf(d: *const Dpb, s: *const Pic) u8 {
        return @intCast((@intFromPtr(s) - @intFromPtr(&d.pics[0])) / @sizeOf(Pic));
    }

    /// Everything the stream holds let go of: at its end with a VPEV_FREE
    /// for each (`say_free`), for a seek without - the slots the caller
    /// holds stay lent either way, its to give back.
    pub fn reset(d: *Dpb, say_free: bool) void {
        for (&d.pics) |*s| {
            s.ref = .none;
            s.output_needed = false;
            if (s.in_use and say_free) d.drop(s);
            s.in_use = false;
        }
        d.prev_tid0_poc = 0;
        d.first = true;
        d.skip_rasl = false;
    }

    /// The picture let go of by the stream, and VPEV_FREE said.
    fn drop(d: *Dpb, s: *Pic) void {
        s.in_use = false;
        d.events.push(.{ .kind = vp.VPEV_FREE, .slot = d.slotOf(s) });
    }

    // --- order counts and reference picture sets -----------------------

    /// NoRaslOutputFlag of an IRAP picture.
    pub fn noRaslOutput(d: *const Dpb, unit: nal.Header) bool {
        return unit.isIdr() or unit.isBla() or d.first;
    }

    /// Whether the picture of `unit` is left undecoded: a RASL picture of
    /// an IRAP picture with NoRaslOutputFlag 1 (8.1.3), whose references
    /// are not there.
    pub fn skipped(d: *const Dpb, unit: nal.Header) bool {
        return unit.isRasl() and d.skip_rasl;
    }

    /// PicOrderCntVal of the picture `h` begins (8.3.1), kept as the
    /// next picture's prevTid0Pic when it may be that. Worked out again
    /// for the same picture it comes to the same.
    pub fn computePoc(d: *Dpb, unit: nal.Header, h: *const Header, sps: *const params.Sps, no_rasl: bool) i32 {
        const max_lsb: i32 = @as(i32, 1) << @intCast(sps.log2_max_poc_lsb);
        const lsb: i32 = @intCast(h.poc_lsb);
        var msb: i32 = 0;
        if (!(unit.isIrap() and no_rasl)) {
            const prev_lsb = d.prev_tid0_poc & (max_lsb - 1);
            const prev_msb = d.prev_tid0_poc - prev_lsb;
            msb = prev_msb;
            if (lsb < prev_lsb and prev_lsb - lsb >= @divTrunc(max_lsb, 2)) {
                msb = prev_msb + max_lsb;
            } else if (lsb > prev_lsb and lsb - prev_lsb > @divTrunc(max_lsb, 2)) {
                msb = prev_msb - max_lsb;
            }
        }
        const poc = msb +% lsb;
        if (unit.tid == 0 and !unit.isRasl() and !unit.isRadl() and !unit.isSubLayerNonRef()) d.prev_tid0_poc = poc;
        if (unit.isIrap()) d.skip_rasl = no_rasl;
        return poc;
    }

    /// A reference picture whose order count, masked by `mask`, is `poc`.
    fn findRef(d: *Dpb, poc: i32, mask: i32, short_only: bool) ?*Pic {
        for (d.pics[0..d.count]) |*s| {
            if (!s.in_use or s.ref == .none or (short_only and s.ref != .short)) continue;
            if (s.poc & mask == poc) return s;
        }
        return null;
    }

    /// The reference picture set of the picture `h` begins (8.3.2): the
    /// references marked, and its five sets into `rps` (null where a
    /// picture is not there). Applied again to the same picture it marks
    /// nothing more.
    pub fn applyRps(d: *Dpb, unit: nal.Header, h: *const Header, sps: *const params.Sps, poc: i32, no_rasl: bool, rps: *Rps) Error!void {
        rps.count = @splat(0);
        if (unit.isIrap() and no_rasl) {
            for (&d.pics) |*s| s.ref = .none;
        }
        if (unit.isIdr()) return;
        const max_lsb: i32 = @as(i32, 1) << @intCast(sps.log2_max_poc_lsb);
        var keep: u64 = 0;
        var long: u64 = 0;
        for (0..h.num_lt) |i| {
            const bit = @as(u32, 1) << @intCast(i);
            var p: i32 = @intCast(h.lt_poc_lsb[i]);
            var mask: i32 = max_lsb - 1;
            if (h.lt_msb_present & bit != 0) {
                p +%= poc -% @as(i32, @bitCast(h.lt_msb_cycle[i])) *% max_lsb -% (poc & (max_lsb - 1));
                mask = -1;
            }
            const s = d.findRef(p, mask, false);
            if (s) |found| long |= @as(u64, 1) << @intCast(d.slotOf(found));
            try rps.add(if (h.lt_used & bit != 0) Rps.long else Rps.lt_foll, s, p);
        }
        for (&d.pics, 0..) |*s, i| {
            if (long >> @intCast(i) & 1 != 0) s.ref = .long;
        }
        keep |= long;
        const st = h.rps(sps);
        for (0..st.num_negative) |i| {
            const p = poc +% st.delta_s0[i];
            const s = d.findRef(p, -1, true);
            if (s) |found| keep |= @as(u64, 1) << @intCast(d.slotOf(found));
            try rps.add(if (st.used_s0 >> @intCast(i) & 1 != 0) Rps.before else Rps.st_foll, s, p);
        }
        for (0..st.num_positive) |i| {
            const p = poc +% st.delta_s1[i];
            const s = d.findRef(p, -1, true);
            if (s) |found| keep |= @as(u64, 1) << @intCast(d.slotOf(found));
            try rps.add(if (st.used_s1 >> @intCast(i) & 1 != 0) Rps.after else Rps.st_foll, s, p);
        }
        for (&d.pics, 0..) |*s, i| {
            if (keep >> @intCast(i) & 1 == 0) s.ref = .none;
        }
    }

    /// The reference picture lists of a P or B slice (8.3.4) and its
    /// collocated picture, from the current picture's sets.
    pub fn buildLists(h: *const Header, rps: *const Rps, lists: *Lists) Error!void {
        lists.* = .{};
        if (h.slice_type == .i) return;
        const total = rps.total();
        if (total == 0) return error.Corrupt;
        const nlists: usize = if (h.slice_type == .b) 2 else 1;
        for (0..nlists) |l| {
            const n = h.num_ref_idx[l];
            const len = @max(n, total);
            var temp: [48]Ref = undefined;
            const order: [3]usize = if (l == 0) .{ Rps.before, Rps.after, Rps.long } else .{ Rps.after, Rps.before, Rps.long };
            var k: u32 = 0;
            while (k < len) {
                for (order) |set| {
                    for (0..rps.count[set]) |i| {
                        if (k == len) break;
                        const s = rps.pic[set][i];
                        temp[k] = .{ .pic = s, .poc = if (s) |found| found.poc else rps.poc[set][i], .long = set == Rps.long };
                        k += 1;
                    }
                }
            }
            for (0..n) |i| {
                const idx = if (h.list_modified[l]) h.list_entry[l][i] else i;
                if (idx >= len) return error.Corrupt;
                lists.refs[l][i] = temp[idx];
            }
            lists.count[l] = n;
        }
        if (h.temporal_mvp) {
            const l: usize = if (h.slice_type == .b and !h.collocated_from_l0) 1 else 0;
            if (h.collocated_ref_idx >= lists.count[l]) return error.Corrupt;
            lists.col = lists.refs[l][h.collocated_ref_idx].pic;
        }
    }

    // --- slots -----------------------------------------------------------

    /// A slot with nothing in it, emptying the buffer by showing pictures
    /// when there is none, handed out: lent, with a new number. Null when
    /// every slot is held, and when the only ones the stream let go of
    /// are still lent: they are free once given back, and a picture shown
    /// now would be too early.
    pub fn take(d: *Dpb) ?*Pic {
        while (true) {
            var lent = false;
            for (d.pics[0..d.count]) |*s| {
                if (s.in_use) continue;
                if (!s.lent) {
                    s.* = .{ .in_use = true, .lent = true, .uid = d.uid_next };
                    d.uid_next +%= 1;
                    return s;
                }
                lent = true;
            }
            if (lent or !d.bump()) return null;
        }
    }

    /// The pictures in the buffer (C.5.2.2): references, and those
    /// waiting to be shown.
    fn fullness(d: *const Dpb) u32 {
        var n: u32 = 0;
        for (&d.pics) |*s| {
            if (s.in_use and (s.isRef() or s.output_needed)) n += 1;
        }
        return n;
    }

    fn waiting(d: *const Dpb) u32 {
        var n: u32 = 0;
        for (&d.pics) |*s| {
            if (s.in_use and s.output_needed) n += 1;
        }
        return n;
    }

    /// Whether a waiting picture has waited too long (C.5.2.2).
    fn overdue(d: *const Dpb) bool {
        if (d.latency == 0) return false;
        for (&d.pics) |*s| {
            if (s.in_use and s.output_needed and s.latency >= d.latency) return true;
        }
        return false;
    }

    /// The waiting picture with the lowest order count put out to be
    /// shown, and let go of if it is no reference (C.5.2.4); without one
    /// waiting, a picture neither waiting nor a reference let go of, and
    /// false when there is none. It takes the earliest time of the
    /// pictures waiting, as a chip's decoder gives them: the same where
    /// the container's times are right, and still rising where it wrote
    /// each packet's decoding time.
    pub fn bump(d: *Dpb) bool {
        var best: ?*Pic = null;
        var earliest: ?*Pic = null;
        for (&d.pics) |*s| {
            if (!s.in_use or !s.output_needed) continue;
            if (best == null or s.poc < best.?.poc) best = s;
            if (earliest == null or s.time < earliest.?.time) earliest = s;
        }
        const s = best orelse return d.release();
        const e = earliest.?;
        const time = s.time;
        s.time = e.time;
        e.time = time;
        s.output_needed = false;
        d.events.push(.{ .kind = vp.VPEV_SHOW, .slot = d.slotOf(s), .time = s.time });
        if (!s.isRef()) d.drop(s);
        return true;
    }

    /// A picture neither waiting nor a reference let go of; false when
    /// there was none.
    fn release(d: *Dpb) bool {
        for (&d.pics) |*s| {
            if (s.in_use and !s.isRef() and !s.output_needed) {
                d.drop(s);
                return true;
            }
        }
        return false;
    }

    /// What happens before a picture is decoded, once its reference
    /// picture set marked the references (C.5.2.2): after an IRAP picture
    /// with NoRaslOutputFlag 1 every picture shown, or let go of unshown
    /// when `no_output_of_prior` says so; else pictures shown while too
    /// many wait or the buffer is full.
    pub fn beforePicture(d: *Dpb, sps: *const params.Sps, irap_no_rasl: bool, no_output_of_prior: bool) void {
        d.size = sps.max_dec_pic_buffering;
        d.reorder = sps.max_num_reorder;
        d.latency = sps.max_latency;
        if (irap_no_rasl) {
            if (no_output_of_prior) {
                for (&d.pics) |*s| s.output_needed = false;
                d.sweep();
            } else d.flush();
            return;
        }
        d.sweep();
        while (d.waiting() > d.reorder or d.overdue() or d.fullness() >= d.size) {
            if (d.waiting() == 0 or !d.bump()) break;
        }
        d.sweep();
    }

    /// The current picture, decoded, kept as a short-term reference and,
    /// when `output`, to be shown; others shown while too many wait
    /// (C.5.2.3).
    pub fn store(d: *Dpb, cur: *Pic, output: bool) void {
        if (output) {
            for (&d.pics) |*s| {
                if (s != cur and s.in_use and s.output_needed and s.poc > cur.poc) s.latency += 1;
            }
        }
        cur.ref = .short;
        cur.output_needed = output;
        cur.latency = 0;
        while (d.waiting() > d.reorder or d.overdue()) {
            if (!d.bump()) break;
        }
        d.sweep();
        d.first = false;
    }

    /// Every picture waiting put out, in order.
    pub fn flush(d: *Dpb) void {
        while (d.waiting() > 0) _ = d.bump();
        d.sweep();
    }

    /// Pictures that are no reference and wait for nothing let go of.
    pub fn sweep(d: *Dpb) void {
        for (&d.pics) |*s| {
            if (s.in_use and !s.isRef() and !s.output_needed) d.drop(s);
        }
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "order counts across the wrap of the LSBs" {
    var events: Events = .{};
    var d: Dpb = .{ .events = &events };
    const sps: params.Sps = .{ .log2_max_poc_lsb = 4 };
    const trail: nal.Header = .{ .kind = nal.Type.trail_r, .layer = 0, .tid = 0 };
    const idr: nal.Header = .{ .kind = nal.Type.idr_w_radl, .layer = 0, .tid = 0 };
    try testing.expectEqual(@as(i32, 0), d.computePoc(idr, &.{ .poc_lsb = 0 }, &sps, true));
    // 0 to 14 is more than half the range: backwards.
    try testing.expectEqual(@as(i32, -2), d.computePoc(trail, &.{ .poc_lsb = 14 }, &sps, false));
    try testing.expectEqual(@as(i32, 0), d.computePoc(trail, &.{ .poc_lsb = 0 }, &sps, false));
    try testing.expectEqual(@as(i32, 6), d.computePoc(trail, &.{ .poc_lsb = 6 }, &sps, false));
    try testing.expectEqual(@as(i32, 12), d.computePoc(trail, &.{ .poc_lsb = 12 }, &sps, false));
    // 12 to 2: past the wrap of 16, forwards.
    try testing.expectEqual(@as(i32, 18), d.computePoc(trail, &.{ .poc_lsb = 2 }, &sps, false));
    // The same picture again comes to the same.
    try testing.expectEqual(@as(i32, 18), d.computePoc(trail, &.{ .poc_lsb = 2 }, &sps, false));
    // 18 to 13: backwards over the wrap.
    try testing.expectEqual(@as(i32, 13), d.computePoc(trail, &.{ .poc_lsb = 13 }, &sps, false));
    // An IDR picture starts again from its LSBs alone.
    try testing.expectEqual(@as(i32, 5), d.computePoc(idr, &.{ .poc_lsb = 5 }, &sps, true));
}

test "a picture shown takes the earliest time of those waiting; one that is no reference is let go of" {
    var events: Events = .{};
    var d: Dpb = .{ .events = &events };
    // Decoded first, shown second: the packets' decoding times.
    const a = d.take().?;
    a.poc = 2;
    a.time = 10;
    a.output_needed = true;
    const b = d.take().?;
    b.poc = 1;
    b.time = 30;
    b.output_needed = true;
    b.ref = .short;
    try testing.expect(d.bump());
    // b, the lower count, at the earlier time.
    var e = events.pop().?;
    try testing.expectEqual(vp.VPEV_SHOW, e.kind);
    try testing.expectEqual(@as(u32, d.slotOf(b)), e.slot);
    try testing.expectEqual(@as(i64, 10), e.time);
    try testing.expect(d.bump());
    e = events.pop().?;
    try testing.expectEqual(@as(u32, d.slotOf(a)), e.slot);
    try testing.expectEqual(@as(i64, 30), e.time);
    // a is no reference: let go of.
    e = events.pop().?;
    try testing.expectEqual(vp.VPEV_FREE, e.kind);
    try testing.expectEqual(@as(u32, d.slotOf(a)), e.slot);
    try testing.expect(events.pop() == null);
    // a's slot is still lent: it is not taken again until given back.
    const c = d.take().?;
    try testing.expect(c != a and c != b);
    a.lent = false;
    const again = d.take().?;
    try testing.expectEqual(a, again);
}
