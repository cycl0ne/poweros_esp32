// SPDX-License-Identifier: MIT
//! The decoded picture buffer: each picture's order count (8.2.1), the
//! reference lists of a slice (8.2.4), the marking of the references
//! after a picture (8.2.5), and the order pictures are shown in (C.4.5's
//! bumping).

const common = @import("common.zig");
const Store = common.Store;
const RefPic = common.RefPic;
const params = @import("params.zig");
const slice_mod = @import("slice.zig");
const Header = slice_mod.Header;
const Error = @import("bits.zig").Error;

/// Sixteen frames at most, the one being decoded, a lone field, and room
/// for the pictures put out while one unit is decoded and not yet taken:
/// the last picture finished, the frames a frame_num gap brings, and a
/// flush may put out as many as the buffer holds. A store gets its
/// samples only once it is used.
pub const max_stores = 2 * 16 + 2;

/// The picture being decoded, as the marking and the lists see it.
pub const Current = struct {
    store: *Store,
    /// 1 top field, 2 bottom field, 3 frame.
    structure: u2,
    frame_num: u32,
    max_frame_num: u32,
    /// The second field of a pair whose first was decoded before.
    second_field: bool,
    poc: i32,
};

pub const Dpb = struct {
    stores: [max_stores]Store = @splat(.{}),
    /// The frames the buffer holds (A.3.1), and how many may wait to be
    /// shown before the first must be (the VUI's num_reorder_frames).
    size: u32 = 16,
    reorder: u32 = 16,
    max_long_term_idx: i32 = -1,
    uid_next: u32 = 1,
    /// Pictures to be shown, in order, each held until taken.
    out: [max_stores]*Store = undefined,
    out_head: u32 = 0,
    out_count: u32 = 0,
    /// Stores taken out to be shown, still the caller's.
    // POC state (8.2.1).
    prev_poc_msb: i32 = 0,
    prev_poc_lsb: i32 = 0,
    prev_frame_num_offset: i32 = 0,
    prev_frame_num: u32 = 0,
    prev_ref_frame_num: u32 = 0,
    prev_mmco5: bool = false,
    frame_num_offset: i32 = 0,
    /// PicOrderCntMsb of the picture being decoded.
    cur_msb: i32 = 0,

    pub fn reset(d: *Dpb) void {
        for (&d.stores) |*s| {
            s.ref = .{ .none, .none };
            s.output_needed = false;
            if (!d.isQueued(s)) s.in_use = false;
        }
        d.max_long_term_idx = -1;
        d.prev_poc_msb = 0;
        d.prev_poc_lsb = 0;
        d.prev_frame_num_offset = 0;
        d.prev_frame_num = 0;
        d.prev_ref_frame_num = 0;
        d.prev_mmco5 = false;
    }

    fn isQueued(d: *const Dpb, s: *const Store) bool {
        var i: u32 = 0;
        while (i < d.out_count) : (i += 1) {
            if (d.out[(d.out_head + i) % max_stores] == s) return true;
        }
        return false;
    }

    // --- picture order counts ------------------------------------------

    /// TopFieldOrderCnt and BottomFieldOrderCnt of the picture `h` begins
    /// (8.2.1). For a field the other is left as it is.
    pub fn computePoc(d: *Dpb, h: *const Header, sps: *const params.Sps, poc: *[2]i32) void {
        const max_frame_num: i32 = @as(i32, 1) << sps.log2_max_frame_num;
        const frame_num: i32 = @intCast(h.frame_num);
        switch (sps.poc_type) {
            0 => {
                if (h.idr) {
                    d.prev_poc_msb = 0;
                    d.prev_poc_lsb = 0;
                }
                const max_lsb: i32 = @as(i32, 1) << sps.log2_max_poc_lsb;
                const lsb: i32 = @intCast(h.poc_lsb);
                var msb = d.prev_poc_msb;
                if (lsb < d.prev_poc_lsb and d.prev_poc_lsb - lsb >= @divTrunc(max_lsb, 2)) {
                    msb = d.prev_poc_msb + max_lsb;
                } else if (lsb > d.prev_poc_lsb and lsb - d.prev_poc_lsb > @divTrunc(max_lsb, 2)) {
                    msb = d.prev_poc_msb - max_lsb;
                }
                if (!h.field_pic) {
                    poc[0] = msb + lsb;
                    poc[1] = poc[0] + h.delta_poc_bottom;
                } else if (!h.bottom_field) {
                    poc[0] = msb + lsb;
                } else poc[1] = msb + lsb;
                d.cur_msb = msb;
            },
            else => {
                var offset: i32 = 0;
                if (!h.idr) {
                    const prev_offset = if (d.prev_mmco5) 0 else d.prev_frame_num_offset;
                    offset = if (@as(i32, @intCast(d.prev_frame_num)) > frame_num) prev_offset + max_frame_num else prev_offset;
                }
                d.frame_num_offset = offset;
                if (sps.poc_type == 1) {
                    var abs: i32 = if (sps.num_ref_frames_in_poc_cycle != 0) offset + frame_num else 0;
                    if (h.nal_ref_idc == 0 and abs > 0) abs -= 1;
                    var expected: i32 = 0;
                    if (abs > 0) {
                        const n: i32 = sps.num_ref_frames_in_poc_cycle;
                        var delta_cycle: i32 = 0;
                        for (sps.offset_for_ref_frame[0..sps.num_ref_frames_in_poc_cycle]) |o| delta_cycle +%= o;
                        const cycle = @divTrunc(abs - 1, n);
                        const in_cycle: usize = @intCast(@mod(abs - 1, n));
                        expected = cycle *% delta_cycle;
                        for (sps.offset_for_ref_frame[0 .. in_cycle + 1]) |o| expected +%= o;
                    }
                    if (h.nal_ref_idc == 0) expected +%= sps.offset_for_non_ref_pic;
                    if (!h.field_pic) {
                        poc[0] = expected +% h.delta_poc[0];
                        poc[1] = poc[0] +% sps.offset_for_top_to_bottom_field +% h.delta_poc[1];
                    } else if (!h.bottom_field) {
                        poc[0] = expected +% h.delta_poc[0];
                    } else poc[1] = expected +% sps.offset_for_top_to_bottom_field +% h.delta_poc[0];
                } else {
                    var temp: i32 = 0;
                    if (!h.idr) temp = if (h.nal_ref_idc == 0) 2 * (offset + frame_num) - 1 else 2 * (offset + frame_num);
                    if (!h.field_pic) {
                        poc[0] = temp;
                        poc[1] = temp;
                    } else if (!h.bottom_field) poc[0] = temp else poc[1] = temp;
                }
            },
        }
    }

    /// What the next picture's order count starts from, once the current
    /// one is decoded (8.2.1): after a reference picture for type 0, after
    /// any for types 1 and 2.
    pub fn afterPicture(d: *Dpb, h: *const Header, sps: *const params.Sps, cur: *Store, mmco5: bool) void {
        if (sps.poc_type == 0) {
            if (h.nal_ref_idc != 0) {
                if (mmco5) {
                    d.prev_poc_msb = 0;
                    d.prev_poc_lsb = if (h.field_pic and h.bottom_field) 0 else cur.poc[0];
                } else {
                    d.prev_poc_msb = d.cur_msb;
                    d.prev_poc_lsb = @intCast(h.poc_lsb);
                }
            }
        } else {
            d.prev_frame_num_offset = if (mmco5) 0 else d.frame_num_offset;
        }
        d.prev_mmco5 = mmco5;
        d.prev_frame_num = if (mmco5) 0 else h.frame_num;
        if (h.nal_ref_idc != 0) d.prev_ref_frame_num = if (mmco5) 0 else h.frame_num;
    }

    // --- stores ----------------------------------------------------------

    /// A store with nothing in it, emptying the buffer by showing pictures
    /// when there is none (C.4.5.3). Null when every store is held.
    pub fn freeStore(d: *Dpb) ?*Store {
        while (true) {
            for (&d.stores) |*s| {
                if (!s.in_use) return s;
            }
            if (!d.bump()) return null;
        }
    }

    /// The stores a frame occupies, for the fullness of the buffer.
    fn fullness(d: *const Dpb, except: ?*const Store) u32 {
        var n: u32 = 0;
        for (&d.stores) |*s| {
            if (s == except) continue;
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

    /// The picture with the lowest order count of those waiting, put out
    /// to be shown, and its store emptied if it is no reference (C.4.5.3).
    pub fn bump(d: *Dpb) bool {
        var best: ?*Store = null;
        for (&d.stores) |*s| {
            if (!s.in_use or !s.output_needed) continue;
            if (best == null or s.framePoc() < best.?.framePoc()) best = s;
        }
        const s = best orelse return d.release();
        s.output_needed = false;
        if (!s.non_existing and d.out_count < max_stores) {
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

    /// Every picture waiting put out, in order.
    pub fn flush(d: *Dpb) void {
        while (d.waiting() > 0) _ = d.bump();
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

    /// The current picture, decoded and marked, kept to be shown (C.4.5.1,
    /// C.4.5.2): shown as soon as nothing waiting comes before it and the
    /// buffer is full, and others shown while too many wait.
    pub fn store(d: *Dpb, cur: *Store) void {
        cur.output_needed = !cur.non_existing;
        while (d.fullness(null) > d.size or d.waiting() > d.reorder) {
            if (!d.bump()) break;
        }
        d.sweep();
    }

    // --- marking (8.2.5) -------------------------------------------------

    fn picNumOf(cur: *const Current, s: *const Store, parity: u2) i32 {
        // FrameNumWrap of the store, and PicNum of its field `parity` (or
        // of the frame).
        if (cur.structure == 3) return s.frame_num_wrap;
        return 2 * s.frame_num_wrap + @as(i32, if (parity == cur.structure) 1 else 0);
    }

    fn longPicNumOf(cur: *const Current, s: *const Store, parity: u2) i32 {
        const idx: i32 = @intCast(s.long_term_idx);
        if (cur.structure == 3) return idx;
        return 2 * idx + @as(i32, if (parity == cur.structure) 1 else 0);
    }

    /// FrameNumWrap of every short-term store (8.2.4.1).
    pub fn updateFrameNumWrap(d: *Dpb, cur: *const Current) void {
        for (&d.stores) |*s| {
            if (!s.in_use or s == cur.store) continue;
            if (s.ref[0] == .short or s.ref[1] == .short) {
                s.frame_num_wrap = if (s.frame_num > cur.frame_num) @as(i32, @intCast(s.frame_num)) - @as(i32, @intCast(cur.max_frame_num)) else @intCast(s.frame_num);
            }
        }
    }

    fn currPicNum(cur: *const Current) i32 {
        return if (cur.structure == 3) @intCast(cur.frame_num) else @intCast(2 * cur.frame_num + 1);
    }

    fn unmark(s: *Store, parity: u2) void {
        if (parity & 1 != 0) s.ref[0] = .none;
        if (parity & 2 != 0) s.ref[1] = .none;
    }

    /// The short-term picture with PicNum `num`, and which field of it.
    fn findShort(d: *Dpb, cur: *const Current, num: i32) ?struct { s: *Store, parity: u2 } {
        for (&d.stores) |*s| {
            if (!s.in_use) continue;
            if (cur.structure == 3) {
                if (s != cur.store and s.isShortFrame() and s.frame_num_wrap == num) return .{ .s = s, .parity = 3 };
            } else {
                for ([_]u2{ 1, 2 }) |p| {
                    if (s.ref[p - 1] == .short and (s != cur.store or p != cur.structure) and picNumOf(cur, s, p) == num) return .{ .s = s, .parity = p };
                }
            }
        }
        return null;
    }

    fn findLong(d: *Dpb, cur: *const Current, num: i32) ?struct { s: *Store, parity: u2 } {
        for (&d.stores) |*s| {
            if (!s.in_use) continue;
            if (cur.structure == 3) {
                if (s != cur.store and s.isLongFrame() and @as(i32, @intCast(s.long_term_idx)) == num) return .{ .s = s, .parity = 3 };
            } else {
                for ([_]u2{ 1, 2 }) |p| {
                    if (s.ref[p - 1] == .long and (s != cur.store or p != cur.structure) and longPicNumOf(cur, s, p) == num) return .{ .s = s, .parity = p };
                }
            }
        }
        return null;
    }

    /// Any store but `keep` holding long-term index `idx` let go of it.
    fn freeLongIdx(d: *Dpb, idx: u32, keep: ?*Store) void {
        for (&d.stores) |*s| {
            if (!s.in_use or s == keep) continue;
            for (0..2) |f| {
                if (s.ref[f] == .long and s.long_term_idx == idx) s.ref[f] = .none;
            }
        }
    }

    /// The marking after a reference picture is decoded (8.2.5): an IDR's,
    /// the operations the slice header gives, or the sliding window. True
    /// when an operation 5 was among them.
    pub fn mark(d: *Dpb, h: *const Header, sps: *const params.Sps, cur: *const Current) bool {
        const s = cur.store;
        const field_bits: u2 = cur.structure;
        if (h.idr) {
            for (&d.stores) |*o| {
                if (o != s) o.ref = .{ .none, .none };
            }
            if (h.long_term_reference) {
                d.max_long_term_idx = 0;
                s.long_term_idx = 0;
                setRef(s, field_bits, .long);
            } else {
                d.max_long_term_idx = -1;
                setRef(s, field_bits, .short);
            }
            return false;
        }
        var mmco5 = false;
        var marked_long = false;
        if (h.adaptive_marking) {
            d.updateFrameNumWrap(cur);
            for (h.mmco[0..h.mmco_count]) |m| {
                switch (m.op) {
                    1 => {
                        const num = currPicNum(cur) - @as(i32, @intCast(m.a)) - 1;
                        if (d.findShort(cur, num)) |f| unmark(f.s, f.parity);
                    },
                    2 => if (d.findLong(cur, @intCast(m.a))) |f| unmark(f.s, f.parity),
                    3 => {
                        const num = currPicNum(cur) - @as(i32, @intCast(m.a)) - 1;
                        if (d.findShort(cur, num)) |f| {
                            // The index taken from any other frame - but not
                            // from the other field of this one.
                            for (&d.stores) |*o| {
                                if (!o.in_use or o == f.s) continue;
                                for (0..2) |k| {
                                    if (o.ref[k] == .long and o.long_term_idx == m.b) o.ref[k] = .none;
                                }
                            }
                            if (f.s.long_term_idx != m.b) {
                                for (0..2) |k| {
                                    if (f.s.ref[k] == .long) f.s.ref[k] = .none;
                                }
                            }
                            f.s.long_term_idx = m.b;
                            setRef(f.s, f.parity, .long);
                        }
                    },
                    4 => {
                        d.max_long_term_idx = @as(i32, @intCast(m.a)) - 1;
                        for (&d.stores) |*o| {
                            if (!o.in_use) continue;
                            for (0..2) |k| {
                                if (o.ref[k] == .long and @as(i32, @intCast(o.long_term_idx)) > d.max_long_term_idx) o.ref[k] = .none;
                            }
                        }
                    },
                    5 => {
                        for (&d.stores) |*o| {
                            if (o != s) o.ref = .{ .none, .none };
                        }
                        d.max_long_term_idx = -1;
                        mmco5 = true;
                    },
                    6 => {
                        d.freeLongIdx(m.b, s);
                        // The other field of this frame keeps it only if it
                        // has the same index.
                        for (0..2) |k| {
                            if (s.ref[k] == .long and s.long_term_idx != m.b) s.ref[k] = .none;
                        }
                        s.long_term_idx = m.b;
                        setRef(s, field_bits, .long);
                        marked_long = true;
                    },
                    else => {},
                }
            }
        } else if (!(cur.second_field and (s.ref[0] != .none or s.ref[1] != .none))) {
            d.slidingWindow(sps, cur);
        }
        if (!marked_long) setRef(s, field_bits, .short);
        return mmco5;
    }

    fn setRef(s: *Store, parity: u2, kind: common.RefKind) void {
        if (parity & 1 != 0) s.ref[0] = kind;
        if (parity & 2 != 0) s.ref[1] = kind;
    }

    /// The sliding window (8.2.5.3): the oldest short-term frame let go
    /// when the references are as many as the sequence allows.
    pub fn slidingWindow(d: *Dpb, sps: *const params.Sps, cur: *const Current) void {
        d.updateFrameNumWrap(cur);
        var short: u32 = 0;
        var long: u32 = 0;
        var oldest: ?*Store = null;
        for (&d.stores) |*s| {
            if (!s.in_use or s == cur.store) continue;
            if (s.ref[0] == .short or s.ref[1] == .short) {
                short += 1;
                if (oldest == null or s.frame_num_wrap < oldest.?.frame_num_wrap) oldest = s;
            } else if (s.ref[0] == .long or s.ref[1] == .long) long += 1;
        }
        if (short + long >= @max(@as(u32, sps.max_num_ref_frames), 1) and short > 0) {
            const o = oldest.?;
            for (0..2) |k| {
                if (o.ref[k] == .short) o.ref[k] = .none;
            }
        }
    }

    // --- reference lists (8.2.4) -----------------------------------------

    /// The initial reference lists of a P, SP or B slice (8.2.4.2) into
    /// `lists`, then changed as its header says (8.2.4.3), each as long as
    /// the slice says. Entries no picture fills are left null.
    pub fn buildLists(d: *Dpb, h: *const Header, cur: *const Current, lists: *[2][33]RefPic) Error!void {
        for (lists) |*l| l.* = @splat(.{});
        if (!h.isInter()) return;
        d.updateFrameNumWrap(cur);
        var init: [2][64]RefPic = undefined;
        var count: [2]u32 = .{ 0, 0 };
        if (cur.structure == 3) {
            count[0] = d.initFrameList(h, cur, &init[0], 0);
            if (h.kind == .b) count[1] = d.initFrameList(h, cur, &init[1], 1);
        } else {
            count[0] = d.initFieldList(h, cur, &init[0], 0);
            if (h.kind == .b) count[1] = d.initFieldList(h, cur, &init[1], 1);
        }
        // A list 1 of more than one entry the same as list 0: its first two
        // swapped (8.2.4.2.3, 8.2.4.2.4).
        if (h.kind == .b and count[1] > 1 and count[0] == count[1]) {
            var same = true;
            for (0..count[0]) |i| {
                if (init[0][i].store != init[1][i].store or init[0][i].structure != init[1][i].structure) same = false;
            }
            if (same) {
                const t = init[1][0];
                init[1][0] = init[1][1];
                init[1][1] = t;
            }
        }
        const lists_used: u32 = if (h.kind == .b) 2 else 1;
        for (0..lists_used) |l| {
            const n = h.num_ref_idx[l];
            var list: [34]RefPic = @splat(.{});
            for (0..@min(n, count[l])) |i| list[i] = init[l][i];
            try d.modifyList(h, cur, &list, n, l);
            for (0..n) |i| lists[l][i] = list[i];
        }
    }

    fn sortDesc(items: []RefPic, keys: []i32) void {
        // Insertion sort: the lists are short.
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            var j = i;
            while (j > 0 and keys[j - 1] < keys[j]) : (j -= 1) {
                swap(items, keys, j);
            }
        }
    }

    fn sortAsc(items: []RefPic, keys: []i32) void {
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            var j = i;
            while (j > 0 and keys[j - 1] > keys[j]) : (j -= 1) {
                swap(items, keys, j);
            }
        }
    }

    fn swap(items: []RefPic, keys: []i32, j: usize) void {
        const t = items[j - 1];
        items[j - 1] = items[j];
        items[j] = t;
        const k = keys[j - 1];
        keys[j - 1] = keys[j];
        keys[j] = k;
    }

    /// A frame's list (8.2.4.2.1, 8.2.4.2.3).
    fn initFrameList(d: *Dpb, h: *const Header, cur: *const Current, out: *[64]RefPic, list: u32) u32 {
        var short: [max_stores]RefPic = undefined;
        var short_key: [max_stores]i32 = undefined;
        var ns: usize = 0;
        var long: [max_stores]RefPic = undefined;
        var long_key: [max_stores]i32 = undefined;
        var nl: usize = 0;
        for (&d.stores) |*s| {
            if (!s.in_use or s == cur.store) continue;
            if (s.isShortFrame()) {
                short[ns] = .{ .store = s, .structure = 3 };
                short_key[ns] = if (h.kind == .b) s.framePoc() else s.frame_num_wrap;
                ns += 1;
            } else if (s.isLongFrame()) {
                long[nl] = .{ .store = s, .structure = 3, .long = true };
                long_key[nl] = @intCast(s.long_term_idx);
                nl += 1;
            }
        }
        sortAsc(long[0..nl], long_key[0..nl]);
        var n: u32 = 0;
        if (h.kind != .b) {
            sortDesc(short[0..ns], short_key[0..ns]);
            for (short[0..ns]) |r| {
                out[n] = r;
                n += 1;
            }
        } else {
            // Before the current picture, nearest first, then after it.
            sortAsc(short[0..ns], short_key[0..ns]);
            var before: [max_stores]RefPic = undefined;
            var nb: usize = 0;
            var after: [max_stores]RefPic = undefined;
            var na: usize = 0;
            for (short[0..ns], short_key[0..ns]) |r, k| {
                if (k < cur.poc) {
                    before[nb] = r;
                    nb += 1;
                } else {
                    after[na] = r;
                    na += 1;
                }
            }
            const first = if (list == 0) before[0..nb] else after[0..na];
            const second = if (list == 0) after[0..na] else before[0..nb];
            if (list == 0) {
                var i = first.len;
                while (i > 0) : (i -= 1) {
                    out[n] = first[i - 1];
                    n += 1;
                }
                for (second) |r| {
                    out[n] = r;
                    n += 1;
                }
            } else {
                for (first) |r| {
                    out[n] = r;
                    n += 1;
                }
                var i = second.len;
                while (i > 0) : (i -= 1) {
                    out[n] = second[i - 1];
                    n += 1;
                }
            }
        }
        for (long[0..nl]) |r| {
            out[n] = r;
            n += 1;
        }
        return n;
    }

    /// A field's list (8.2.4.2.2, 8.2.4.2.4, 8.2.4.2.5): the frames in
    /// order, then their fields taken by turns, the current parity first.
    fn initFieldList(d: *Dpb, h: *const Header, cur: *const Current, out: *[64]RefPic, list: u32) u32 {
        var short: [max_stores]*Store = undefined;
        var short_key: [max_stores]i32 = undefined;
        var ns: usize = 0;
        var long: [max_stores]*Store = undefined;
        var long_key: [max_stores]i32 = undefined;
        var nl: usize = 0;
        for (&d.stores) |*s| {
            if (!s.in_use) continue;
            // The first field of the current frame counts, the current field
            // does not.
            var r0 = s.ref[0];
            var r1 = s.ref[1];
            if (s == cur.store) {
                if (cur.structure == 1) r0 = .none else r1 = .none;
            }
            if (r0 == .short or r1 == .short) {
                short[ns] = s;
                // The order count of the fields decoded - only the first of
                // the current frame (as the reference decoder has it).
                short_key[ns] = if (h.kind == .b) s.framePoc() else s.frame_num_wrap;
                ns += 1;
            }
            if (r0 == .long or r1 == .long) {
                long[nl] = s;
                long_key[nl] = @intCast(s.long_term_idx);
                nl += 1;
            }
        }
        var frames: [2 * max_stores]*Store = undefined;
        var nf: usize = 0;
        // Sort by the keys.
        sortStores(short[0..ns], short_key[0..ns], h.kind != .b);
        if (h.kind != .b) {
            for (short[0..ns]) |s| {
                frames[nf] = s;
                nf += 1;
            }
        } else {
            // POC <= current first (descending for list 0), then after.
            var before: [max_stores]*Store = undefined;
            var nb: usize = 0;
            var after: [max_stores]*Store = undefined;
            var na: usize = 0;
            // short is ascending here
            for (short[0..ns], short_key[0..ns]) |s, k| {
                if (k <= cur.poc) {
                    before[nb] = s;
                    nb += 1;
                } else {
                    after[na] = s;
                    na += 1;
                }
            }
            if (list == 0) {
                var i = nb;
                while (i > 0) : (i -= 1) {
                    frames[nf] = before[i - 1];
                    nf += 1;
                }
                for (after[0..na]) |s| {
                    frames[nf] = s;
                    nf += 1;
                }
            } else {
                for (after[0..na]) |s| {
                    frames[nf] = s;
                    nf += 1;
                }
                var i = nb;
                while (i > 0) : (i -= 1) {
                    frames[nf] = before[i - 1];
                    nf += 1;
                }
            }
        }
        var n = fieldsByTurns(frames[0..nf], cur, .short, out, 0);
        sortStores(long[0..nl], long_key[0..nl], false);
        n = fieldsByTurns(long[0..nl], cur, .long, out, n);
        return n;
    }

    /// Ascending, or descending when `desc`.
    fn sortStores(items: []*Store, keys: []i32, desc: bool) void {
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            var j = i;
            while (j > 0 and (if (desc) keys[j - 1] < keys[j] else keys[j - 1] > keys[j])) : (j -= 1) {
                const t = items[j - 1];
                items[j - 1] = items[j];
                items[j] = t;
                const k = keys[j - 1];
                keys[j - 1] = keys[j];
                keys[j] = k;
            }
        }
    }

    /// 8.2.4.2.5: fields of `frames` alternately, the current parity first,
    /// each only if it is a reference of `kind`; once one parity runs out
    /// the rest of the other in order.
    fn fieldsByTurns(frames: []const *Store, cur: *const Current, kind: common.RefKind, out: *[64]RefPic, start: u32) u32 {
        var n = start;
        const same: u2 = cur.structure;
        const other: u2 = 3 - cur.structure;
        var i_same: usize = 0;
        var i_other: usize = 0;
        var want_same = true;
        while (true) {
            const parity = if (want_same) same else other;
            const idx = if (want_same) &i_same else &i_other;
            // The next frame with that field a reference.
            var found = false;
            while (idx.* < frames.len) {
                const s = frames[idx.*];
                idx.* += 1;
                var r = s.ref[parity - 1];
                if (s == cur.store and parity == cur.structure) r = .none;
                if (r == kind) {
                    if (n < 64) {
                        out[n] = .{ .store = s, .structure = parity, .long = kind == .long };
                        n += 1;
                    }
                    found = true;
                    break;
                }
            }
            if (!found) {
                // This parity ran out: the rest of the other.
                const p2 = if (want_same) other else same;
                const idx2 = if (want_same) &i_other else &i_same;
                while (idx2.* < frames.len) {
                    const s = frames[idx2.*];
                    idx2.* += 1;
                    var r = s.ref[p2 - 1];
                    if (s == cur.store and p2 == cur.structure) r = .none;
                    if (r == kind and n < 64) {
                        out[n] = .{ .store = s, .structure = p2, .long = kind == .long };
                        n += 1;
                    }
                }
                break;
            }
            want_same = !want_same;
        }
        return n;
    }

    /// The modification of a list (8.2.4.3).
    fn modifyList(d: *Dpb, h: *const Header, cur: *const Current, list: *[34]RefPic, n: u32, l: usize) Error!void {
        const max_pic_num: i32 = @intCast(if (cur.structure == 3) cur.max_frame_num else 2 * cur.max_frame_num);
        const curr = currPicNum(cur);
        var pred = curr;
        var idx: u32 = 0;
        for (h.list_ops[l][0..h.list_op_count[l]]) |op| {
            if (idx >= n) return error.Corrupt;
            var pic: RefPic = undefined;
            if (op.idc < 2) {
                const diff: i32 = @intCast(op.value + 1);
                if (diff > max_pic_num) return error.Corrupt;
                var no_wrap: i32 = undefined;
                if (op.idc == 0) {
                    no_wrap = pred - diff;
                    if (no_wrap < 0) no_wrap += max_pic_num;
                } else {
                    no_wrap = pred + diff;
                    if (no_wrap >= max_pic_num) no_wrap -= max_pic_num;
                }
                pred = no_wrap;
                const num = if (no_wrap > curr) no_wrap - max_pic_num else no_wrap;
                const f = d.findShort(cur, num) orelse return error.Corrupt;
                pic = .{ .store = f.s, .structure = f.parity };
            } else {
                const f = d.findLong(cur, @intCast(op.value)) orelse return error.Corrupt;
                pic = .{ .store = f.s, .structure = f.parity, .long = true };
            }
            // Inserted at idx, the rest moved up, the same picture further
            // on taken out.
            var k: u32 = n;
            while (k > idx) : (k -= 1) list[k] = list[k - 1];
            list[idx] = pic;
            idx += 1;
            var w = idx;
            var r = idx;
            while (r <= n) : (r += 1) {
                const e = list[r];
                const same = e.store == pic.store and e.structure == pic.structure and e.long == pic.long;
                if (!same) {
                    list[w] = e;
                    w += 1;
                }
            }
        }
    }
};
