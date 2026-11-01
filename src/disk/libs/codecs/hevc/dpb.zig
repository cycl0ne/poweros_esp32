// SPDX-License-Identifier: MIT
//! The decoded picture buffer: each picture's order count (8.3.1), the
//! reference picture set that marks the references (8.3.2), a slice's
//! reference lists and collocated picture (8.3.4, 8.3.5), and the order
//! pictures are shown in (C.5.2).

const common = @import("common.zig");
const Store = common.Store;
const params = @import("params.zig");
const nal = @import("nal.zig");
const Header = @import("slice.zig").Header;
const picture = @import("picture.zig");
const Error = @import("bits.zig").Error;

/// Sixteen pictures at most in the buffer, the one being decoded, and
/// room for the pictures put out while one unit is decoded and not yet
/// taken: a flush may put out as many as the buffer holds. A store gets
/// its samples only once it is used.
pub const max_stores = 2 * 16 + 2;

/// The pictures of a reference picture set the current picture refers
/// to (8.3.2): RefPicSetStCurrBefore, RefPicSetStCurrAfter and
/// RefPicSetLtCurr, with the order counts they were named by. A null
/// store is a picture that is not there.
pub const Rps = struct {
    store: [3][16]?*Store = undefined,
    poc: [3][16]i32 = undefined,
    count: [3]u8 = .{ 0, 0, 0 },

    pub const before = 0;
    pub const after = 1;
    pub const long = 2;

    fn add(r: *Rps, set: usize, s: ?*Store, poc: i32) Error!void {
        if (r.count[set] == 16) return error.Corrupt;
        r.store[set][r.count[set]] = s;
        r.poc[set][r.count[set]] = poc;
        r.count[set] += 1;
    }

    pub fn total(r: *const Rps) u32 {
        return @as(u32, r.count[0]) + r.count[1] + r.count[2];
    }
};

pub const Dpb = struct {
    stores: [max_stores]Store = @splat(.{}),
    uid_next: u32 = 1,
    /// Pictures to be shown, in order, each held until taken.
    out: [max_stores]*Store = undefined,
    out_head: u32 = 0,
    out_count: u32 = 0,
    /// The pictures the buffer holds, how many may wait to be shown, and
    /// how many later ones a waiting picture may see decoded before it
    /// must be shown (0: any number), from the SPS (C.5.2.2).
    size: u32 = 16,
    reorder: u32 = 16,
    latency: u32 = 0,
    /// PicOrderCntVal of prevTid0Pic (8.3.1).
    prev_tid0_poc: i32 = 0,
    /// No picture since the start, an end of sequence or a reset: the
    /// next IRAP picture has NoRaslOutputFlag 1 whatever its type.
    first: bool = true,
    /// NoRaslOutputFlag of the last IRAP picture: its RASL pictures are
    /// not decoded.
    skip_rasl: bool = false,

    pub fn reset(d: *Dpb) void {
        for (&d.stores) |*s| {
            s.ref = .none;
            s.output_needed = false;
            if (!d.isQueued(s)) s.in_use = false;
        }
        d.prev_tid0_poc = 0;
        d.first = true;
        d.skip_rasl = false;
    }

    pub fn indexOf(d: *const Dpb, s: *const Store) u8 {
        return @intCast((@intFromPtr(s) - @intFromPtr(&d.stores[0])) / @sizeOf(Store));
    }

    fn isQueued(d: *const Dpb, s: *const Store) bool {
        var i: u32 = 0;
        while (i < d.out_count) : (i += 1) {
            if (d.out[(d.out_head + i) % max_stores] == s) return true;
        }
        return false;
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
    /// next picture's prevTid0Pic when it may be that.
    pub fn computePoc(d: *Dpb, unit: nal.Header, h: *const Header, sps: *const params.Sps, no_rasl: bool) i32 {
        const max_lsb: i32 = @as(i32, 1) << sps.log2_max_poc_lsb;
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
    fn findRef(d: *Dpb, poc: i32, mask: i32, short_only: bool) ?*Store {
        for (&d.stores) |*s| {
            if (!s.in_use or s.ref == .none or (short_only and s.ref != .short)) continue;
            if (s.poc & mask == poc) return s;
        }
        return null;
    }

    /// The reference picture set of the picture `h` begins (8.3.2): the
    /// references marked, and those the picture refers to into `rps`
    /// (null where one is missing).
    pub fn applyRps(d: *Dpb, unit: nal.Header, h: *const Header, sps: *const params.Sps, poc: i32, no_rasl: bool, rps: *Rps) Error!void {
        rps.count = .{ 0, 0, 0 };
        if (unit.isIrap() and no_rasl) {
            for (&d.stores) |*s| s.ref = .none;
        }
        if (unit.isIdr()) return;
        const max_lsb: i32 = @as(i32, 1) << sps.log2_max_poc_lsb;
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
            if (s) |found| long |= @as(u64, 1) << @intCast(d.indexOf(found));
            if (h.lt_used & bit != 0) try rps.add(Rps.long, s, p);
        }
        for (&d.stores, 0..) |*s, i| {
            if (long >> @intCast(i) & 1 != 0) s.ref = .long;
        }
        keep |= long;
        const st = h.rps(sps);
        for (0..st.num_negative) |i| {
            const p = poc +% st.delta_s0[i];
            const s = d.findRef(p, -1, true);
            if (s) |found| keep |= @as(u64, 1) << @intCast(d.indexOf(found));
            if (st.used_s0 >> @intCast(i) & 1 != 0) try rps.add(Rps.before, s, p);
        }
        for (0..st.num_positive) |i| {
            const p = poc +% st.delta_s1[i];
            const s = d.findRef(p, -1, true);
            if (s) |found| keep |= @as(u64, 1) << @intCast(d.indexOf(found));
            if (st.used_s1 >> @intCast(i) & 1 != 0) try rps.add(Rps.after, s, p);
        }
        for (&d.stores, 0..) |*s, i| {
            if (keep >> @intCast(i) & 1 == 0) s.ref = .none;
        }
    }

    /// The reference picture lists of a P or B slice (8.3.4), its
    /// collocated picture and NoBackwardPredFlag (8.3.5).
    pub fn buildLists(d: *const Dpb, h: *const Header, rps: *const Rps, poc: i32, lists: *picture.Lists) Error!void {
        lists.* = .{};
        if (h.slice_type == .i) return;
        const total = rps.total();
        if (total == 0) return error.Corrupt;
        const nlists: usize = if (h.slice_type == .b) 2 else 1;
        for (0..nlists) |l| {
            const n = h.num_ref_idx[l];
            const len = @max(n, total);
            var temp: [48]picture.Ref = undefined;
            const order: [3]usize = if (l == 0) .{ Rps.before, Rps.after, Rps.long } else .{ Rps.after, Rps.before, Rps.long };
            var k: u32 = 0;
            while (k < len) {
                for (order) |set| {
                    for (0..rps.count[set]) |i| {
                        if (k == len) break;
                        const s = rps.store[set][i];
                        temp[k] = .{
                            .store = s,
                            .poc = if (s) |found| found.poc else rps.poc[set][i],
                            .long = set == Rps.long,
                            .id = if (s) |found| d.indexOf(found) else 0xff,
                        };
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
            lists.col = lists.refs[l][h.collocated_ref_idx].store;
        }
        lists.no_backward = true;
        for (0..nlists) |l| {
            for (lists.refs[l][0..lists.count[l]]) |r| {
                if (r.poc > poc) lists.no_backward = false;
            }
        }
    }

    // --- stores ----------------------------------------------------------

    /// A store with nothing in it, emptying the buffer by showing pictures
    /// when there is none. Null when every store is held, and when the
    /// only empty ones are still read by jobs: they are free once those
    /// are done, and a picture shown now would be too early.
    pub fn freeStore(d: *Dpb) ?*Store {
        while (true) {
            var pinned = false;
            for (&d.stores) |*s| {
                if (s.in_use) continue;
                if (s.pinned == 0) return s;
                pinned = true;
            }
            if (pinned) return null;
            if (!d.bump() and !d.release()) return null;
        }
    }

    /// The pictures in the buffer (C.5.2.2): references, and those
    /// waiting to be shown.
    fn fullness(d: *const Dpb) u32 {
        var n: u32 = 0;
        for (&d.stores) |*s| {
            if (s.in_use and (s.isRef() or s.output_needed)) n += 1;
        }
        return n;
    }

    fn waiting(d: *const Dpb) u32 {
        var n: u32 = 0;
        for (&d.stores) |*s| {
            if (s.in_use and s.output_needed) n += 1;
        }
        return n;
    }

    /// Whether a waiting picture has waited too long (C.5.2.2).
    fn overdue(d: *const Dpb) bool {
        if (d.latency == 0) return false;
        for (&d.stores) |*s| {
            if (s.in_use and s.output_needed and s.latency >= d.latency) return true;
        }
        return false;
    }

    /// The waiting picture with the lowest order count put out to be
    /// shown, and its store emptied if it is no reference (C.5.2.4);
    /// false when none waits. It takes the earliest time of the pictures
    /// waiting, as a chip's decoder gives them (videodec.resource): the
    /// same where the container's times are right, and still rising where
    /// it wrote each packet's decoding time.
    pub fn bump(d: *Dpb) bool {
        var best: ?*Store = null;
        var earliest: ?*Store = null;
        for (&d.stores) |*s| {
            if (!s.in_use or !s.output_needed) continue;
            if (best == null or s.poc < best.?.poc) best = s;
            if (earliest == null or s.time < earliest.?.time) earliest = s;
        }
        const s = best orelse return false;
        const e = earliest.?;
        const time = s.time;
        s.time = e.time;
        e.time = time;
        s.output_needed = false;
        if (d.out_count < max_stores) {
            d.out[(d.out_head + d.out_count) % max_stores] = s;
            d.out_count += 1;
        } else if (!s.isRef()) s.in_use = false;
        return true;
    }

    /// A store neither waiting nor a reference nor queued, emptied; false
    /// when there was none.
    fn release(d: *Dpb) bool {
        for (&d.stores) |*s| {
            if (s.in_use and !s.isRef() and !s.output_needed and !d.isQueued(s)) {
                s.in_use = false;
                return true;
            }
        }
        return false;
    }

    /// What happens before a picture is decoded, once its reference
    /// picture set marked the references (C.5.2.2): after an IRAP picture
    /// with NoRaslOutputFlag 1 every picture shown, or dropped when
    /// `no_output_of_prior` says so; else pictures shown while too many
    /// wait or the buffer is full.
    pub fn beforePicture(d: *Dpb, sps: *const params.Sps, irap_no_rasl: bool, no_output_of_prior: bool) void {
        d.size = sps.max_dec_pic_buffering;
        d.reorder = sps.max_num_reorder;
        d.latency = sps.max_latency;
        if (irap_no_rasl) {
            if (no_output_of_prior) {
                for (&d.stores) |*s| {
                    s.output_needed = false;
                    if (!d.isQueued(s)) s.in_use = false;
                }
            } else d.flush();
            return;
        }
        d.sweep();
        while (d.waiting() > d.reorder or d.overdue() or d.fullness() >= d.size) {
            if (!d.bump()) break;
        }
        d.sweep();
    }

    /// The current picture, decoded, kept as a short-term reference and,
    /// when `output`, to be shown; others shown while too many wait
    /// (C.5.2.3).
    pub fn store(d: *Dpb, cur: *Store, output: bool) void {
        if (output) {
            for (&d.stores) |*s| {
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
        while (d.bump()) {}
        d.sweep();
    }

    /// Stores that are no reference, waiting for nothing and not queued,
    /// emptied.
    pub fn sweep(d: *Dpb) void {
        for (&d.stores) |*s| {
            if (s.in_use and !s.isRef() and !s.output_needed and !d.isQueued(s)) s.in_use = false;
        }
    }

    /// The next picture to be shown, or null. It stays the caller's until
    /// `taken`.
    pub fn peekOutput(d: *Dpb) ?*Store {
        if (d.out_count == 0) return null;
        return d.out[d.out_head];
    }

    /// The picture `peekOutput` gave is done with.
    pub fn taken(d: *Dpb) void {
        if (d.out_count == 0) return;
        const s = d.out[d.out_head];
        d.out_head = (d.out_head + 1) % max_stores;
        d.out_count -= 1;
        if (!s.isRef() and !s.output_needed and !d.isQueued(s)) s.in_use = false;
    }
};

const testing = @import("std").testing;

test "order counts across the wrap of the LSBs" {
    var d: Dpb = .{};
    var sps: params.Sps = .{};
    sps.log2_max_poc_lsb = 4;
    var h: Header = .{};
    const idr: nal.Header = .{ .kind = nal.Type.idr_w_radl, .layer = 0, .tid = 0 };
    const trail: nal.Header = .{ .kind = nal.Type.trail_r, .layer = 0, .tid = 0 };
    try testing.expectEqual(@as(i32, 0), d.computePoc(idr, &h, &sps, true));
    h.poc_lsb = 14;
    try testing.expectEqual(@as(i32, -2), d.computePoc(trail, &h, &sps, false));
    h.poc_lsb = 6;
    try testing.expectEqual(@as(i32, 6), d.computePoc(trail, &h, &sps, false));
    h.poc_lsb = 13;
    try testing.expectEqual(@as(i32, 13), d.computePoc(trail, &h, &sps, false));
    h.poc_lsb = 2;
    try testing.expectEqual(@as(i32, 18), d.computePoc(trail, &h, &sps, false));
}

test "lists from the reference picture set, and the bumping" {
    var d: Dpb = .{};
    var sps: params.Sps = .{};
    sps.log2_max_poc_lsb = 8;
    sps.max_dec_pic_buffering = 4;
    sps.max_num_reorder = 1;
    // Pictures 0, 8 and 4 decoded, all references.
    for ([_]i32{ 0, 8, 4 }, 0..) |poc, i| {
        d.beforePicture(&sps, i == 0, false);
        const s = &d.stores[i];
        s.in_use = true;
        s.poc = poc;
        d.store(s, true);
    }
    // 0 was shown when 8 came, 4 when it came.
    try testing.expectEqual(@as(i32, 0), d.peekOutput().?.poc);
    d.taken();
    try testing.expectEqual(@as(i32, 4), d.peekOutput().?.poc);
    d.taken();
    try testing.expect(d.peekOutput() == null);
    // Picture 2 refers to 0 and 4 before it, 8 after it.
    var h: Header = .{ .slice_type = .b, .num_ref_idx = .{ 3, 2 } };
    h.st_rps = .{ .num_negative = 1, .num_positive = 2, .used_s0 = 1, .used_s1 = 3 };
    h.st_rps.delta_s0[0] = -2;
    h.st_rps.delta_s1[0] = 2;
    h.st_rps.delta_s1[1] = 6;
    const unit: nal.Header = .{ .kind = nal.Type.trail_r, .layer = 0, .tid = 0 };
    var rps: Rps = .{};
    try d.applyRps(unit, &h, &sps, 2, false, &rps);
    try testing.expectEqual([3]u8{ 1, 2, 0 }, rps.count);
    var lists: picture.Lists = .{};
    try d.buildLists(&h, &rps, 2, &lists);
    try testing.expectEqual(@as(i32, 0), lists.refs[0][0].poc);
    try testing.expectEqual(@as(i32, 4), lists.refs[0][1].poc);
    try testing.expectEqual(@as(i32, 8), lists.refs[0][2].poc);
    try testing.expectEqual(@as(i32, 4), lists.refs[1][0].poc);
    try testing.expectEqual(@as(i32, 8), lists.refs[1][1].poc);
    try testing.expect(!lists.no_backward);
    // A set without picture 0 drops it as a reference; it was shown, so
    // its store is free.
    h.st_rps = .{ .num_negative = 0, .num_positive = 2, .used_s1 = 3 };
    h.st_rps.delta_s1[0] = 2;
    h.st_rps.delta_s1[1] = 6;
    try d.applyRps(unit, &h, &sps, 2, false, &rps);
    d.beforePicture(&sps, false, false);
    try testing.expect(!d.stores[0].in_use);
    try testing.expectEqual(common.RefKind.short, d.stores[2].ref);
    d.flush();
    try testing.expectEqual(@as(i32, 8), d.peekOutput().?.poc);
}

test "a picture shown takes the earliest time of those waiting: right times kept, decoding times put in order" {
    var sps: params.Sps = .{};
    sps.log2_max_poc_lsb = 8;
    sps.max_dec_pic_buffering = 4;
    sps.max_num_reorder = 1;
    // Pictures 0, 8 and 4 decoded in that order, their times as shown
    // (0, 2, 1) and as decoded (0, 1, 2).
    for ([_][3]i64{ .{ 0, 2, 1 }, .{ 0, 1, 2 } }) |times| {
        var d: Dpb = .{};
        for ([_]i32{ 0, 8, 4 }, times, 0..) |poc, time, i| {
            d.beforePicture(&sps, i == 0, false);
            const s = &d.stores[i];
            s.in_use = true;
            s.poc = poc;
            s.time = time;
            d.store(s, true);
        }
        d.flush();
        for ([_]i32{ 0, 4, 8 }, 0..) |poc, time| {
            const s = d.peekOutput().?;
            try testing.expectEqual(poc, s.poc);
            try testing.expectEqual(@as(i64, @intCast(time)), s.time);
            d.taken();
        }
    }
}
