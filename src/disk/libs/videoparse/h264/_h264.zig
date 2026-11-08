// SPDX-License-Identifier: MIT
//! H.264 read unit by unit into events: the parameter sets kept, each
//! slice's header read, the picture it belongs to begun or continued,
//! its lists built, and a picture finished - marked, kept and bumped -
//! when the next one begins, its access unit ends or the stream does.
//!
//! **A picture** begins with a slice whose header differs from the last
//! picture's first in what 7.4.1.2.4 names. Its sequence is made the
//! active one first (VPEV_SEQUENCE when what it says changed, after the
//! pictures of the old one are shown); a field that pairs with the lone
//! field before it goes into that field's slot; an IDR picture lets go of
//! everything before it; frame numbers a stream skipped get a slot each
//! (VPEV_MISSING) and are marked as references (8.2.5.2); then a slot is
//! taken for it and VPEV_PICTURE said. Each slice is VPEV_SLICE, with its
//! two lists; data partitions B and C wait for the A before them.
//!
//! **Waiting for a slot**: a picture or a missing frame that finds none
//! free stops the unit's reading (`Step.full`); the unit is read again
//! once one was given back. Everything done before the stop - the last
//! picture finished, the frames of a gap already given slots - is not
//! done twice: each step looks at what is already done.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const bits_mod = @import("h264sets").bits;
const Bits = bits_mod.Bits;
const Error = bits_mod.Error;
const nal = @import("h264sets").nal;
const params = @import("h264sets").params;
const slice_mod = @import("slice.zig");
const Header = slice_mod.Header;
const dpb_mod = @import("dpb.zig");
const Dpb = dpb_mod.Dpb;
const Pic = dpb_mod.Pic;
const _parser = @import("../parser/_parser.zig");
const Parser = _parser.Parser;
const Buffer = _parser.Buffer;

const Step = _parser.Step;

/// Data partitions B and C wait for the A before them (7.3.2.9): its
/// payload, where its slice data starts and its slice_id, then theirs.
const Partitions = struct {
    pending: bool,
    unit: nal.Header,
    id: u32,
    a: Buffer,
    a_len: usize,
    /// Where partition A's slice data starts, in bits.
    a_pos: usize,
    b: Buffer,
    b_len: usize,
    b_pos: usize,
    has_b: bool,
    c: Buffer,
    c_len: usize,
    c_pos: usize,
    has_c: bool,
    /// A's header, read to find where its data starts.
    header: Header,
};

pub const State = struct {
    dpb: Dpb,
    sps: [32]params.Sps,
    pps: [256]params.Pps,
    /// Slice group maps of type 6, each PPS's own.
    group_ids: [256]Buffer,
    active_sps: ?*const params.Sps,
    active_pps: ?*const params.Pps,
    /// The sequence as it was last said; `told` once it was.
    sequence: vp.VideoSequence,
    told: bool,
    // --- the picture being decoded ---
    cur: ?*Pic,
    structure: u2,
    second_field: bool,
    /// Its first slice's header.
    hdr0: Header,
    /// A first field decoded, waiting for its second.
    lone_field: ?*Pic,
    lone_structure: u2,
    lone_ref: bool,
    /// The last picture was finished at the end of its access unit: a
    /// slice that does not begin another is passed over.
    ended_early: bool,
    /// The slice being read.
    hdr: Header,
    rbsp: Buffer,
    parts: Partitions,
    /// What the events point at: each picture's by its slot, the slice.
    pictures: [dpb_mod.max_pics]vp.VideoPicture,
    slice: vp.VideoSlice,
    lists: [2][33]dpb_mod.Ref,
};

/// A reading of H.264 for `p`, with nothing read; null without memory.
pub fn create(p: *Parser) ?*State {
    const memory = p.alloc(@sizeOf(State)) orelse return null;
    const st: *State = @ptrCast(@alignCast(memory));
    // Cleared memory is every field's start but these.
    st.dpb.events = &p.events;
    st.dpb.count = dpb_mod.stream_pics + p.extra_slots;
    st.dpb.size = 16;
    st.dpb.reorder = 16;
    st.dpb.max_long_term_idx = -1;
    st.dpb.uid_next = 1;
    st.structure = 3;
    return st;
}

pub fn destroy(p: *Parser, st: *State) void {
    for (&st.group_ids) |*g| g.release(p);
    st.rbsp.release(p);
    st.parts.a.release(p);
    st.parts.b.release(p);
    st.parts.c.release(p);
    p.free(@ptrCast(st));
}

/// An avcC's parameter sets read, and the length its packets' units come
/// after.
pub fn setup(p: *Parser, st: *State, data: []const u8) Error!void {
    const config = try nal.AvcConfig.parse(data);
    p.length_size = config.length_size;
    var units = config.units();
    while (try units.next()) |u| {
        if (u.len == 0) continue;
        _ = try before(p, st, u);
        _ = try unit(p, st, u);
    }
}

/// Everything dropped, for a seek: the next picture must be an IDR or a
/// recovery point. The slots the caller holds stay lent.
pub fn reset(st: *State) void {
    st.parts.pending = false;
    st.cur = null;
    st.lone_field = null;
    st.ended_early = false;
    // The sequence is said again with the next picture.
    st.told = false;
    st.dpb.reset(false);
}

/// The payload of `unit` (after its header) unescaped into `buf`: its
/// length.
fn unescape(p: *Parser, payload: []const u8, buf: *Buffer) Error!usize {
    if (!buf.reserve(p, payload.len + 64)) return error.NoMemory;
    return nal.unescape(payload, buf.slice());
}

/// What comes before the unit `u` is read: data partitions B and C
/// belong to the A before them, and anything else ends the wait - that
/// slice is said first (`.again`), and `u` read once its events are out.
/// An error is the waiting slice's, which is dropped; `u` is still to be
/// read.
pub fn before(p: *Parser, st: *State, u: []const u8) Error!Step {
    if (!st.parts.pending or u.len == 0) return .done;
    const kind = u[0] & 0x1F;
    if (kind == nal.Type.partition_b or kind == nal.Type.partition_c) return .done;
    const step = try flushPartitions(p, st);
    return if (step == .full) .full else .again;
}

/// One NAL unit, without its start code or length, once `before` is done
/// with it.
pub fn unit(p: *Parser, st: *State, u: []const u8) Error!Step {
    if (u.len == 0) return .done;
    const h = try nal.header(u[0]);
    switch (h.kind) {
        nal.Type.slice, nal.Type.idr, nal.Type.partition_a, nal.Type.partition_b, nal.Type.partition_c => {},
        else => st.ended_early = false,
    }
    switch (h.kind) {
        nal.Type.slice, nal.Type.idr => {
            const n = try unescape(p, u[1..], &st.rbsp);
            var b = Bits.init(st.rbsp.slice()[0..n]);
            return slice(p, st, &b, h, u, false);
        },
        nal.Type.partition_a => try partitionA(p, st, u, h),
        nal.Type.partition_b, nal.Type.partition_c => return partitionBC(p, st, u, h),
        nal.Type.sps => {
            finishPicture(p, st);
            const n = try unescape(p, u[1..], &st.rbsp);
            var b = Bits.init(st.rbsp.slice()[0..n]);
            var s: params.Sps = .{};
            const id = try params.parseSps(&b, &s, .{ .max_width_mbs = p.max_width_mbs, .max_height_mbs = p.max_height_mbs });
            if (id >= 32) return error.Corrupt;
            // The active one changes only at an IDR picture.
            st.sps[id] = s;
        },
        nal.Type.pps => {
            finishPicture(p, st);
            const n = try unescape(p, u[1..], &st.rbsp);
            var b = Bits.init(st.rbsp.slice()[0..n]);
            var peek = b;
            const ids = try params.ppsIds(&peek);
            const sps = &st.sps[ids.sps];
            if (!sps.valid) return error.Corrupt;
            const units = sps.width_mbs * sps.height_map_units;
            if (!st.group_ids[ids.pps].reserve(p, units)) return error.NoMemory;
            var pps: params.Pps = .{};
            try params.parsePps(&b, &pps, sps, st.group_ids[ids.pps].slice());
            st.pps[ids.pps] = pps;
        },
        nal.Type.sei => {
            finishPicture(p, st);
            const n = try unescape(p, u[1..], &st.rbsp);
            p.light.sei(st.rbsp.slice()[0..n]);
        },
        nal.Type.aud, nal.Type.sps_ext, nal.Type.prefix, nal.Type.subset_sps, 16, 17, 18 => finishPicture(p, st),
        nal.Type.end_of_seq, nal.Type.end_of_stream => finishPicture(p, st),
        else => {},
    }
    return .done;
}

/// The access unit ended - a packet of an MP4 or Matroska track is one -
/// so the picture is finished now rather than when the next one begins.
pub fn endAccessUnit(p: *Parser, st: *State) Error!Step {
    if ((try flushPartitions(p, st)) == .full) return .full;
    if (st.cur == null) return .done;
    finishPicture(p, st);
    st.ended_early = true;
    return .done;
}

/// The stream's end: everything finished, every picture shown, and
/// every slot let go of - nothing is referred to past the end.
pub fn flush(p: *Parser, st: *State) Error!Step {
    if ((try flushPartitions(p, st)) == .full) return .full;
    finishPicture(p, st);
    storeLoneField(st);
    st.dpb.flush();
    st.dpb.reset(true);
    return .done;
}

// --- data partitions ---------------------------------------------------------

fn partitionA(p: *Parser, st: *State, u: []const u8, h: nal.Header) Error!void {
    const parts = &st.parts;
    parts.a_len = try unescape(p, u[1..], &parts.a);
    var b = Bits.init(parts.a.slice()[0..parts.a_len]);
    // The header is read again when the slice is said; here only where
    // the data starts and its slice_id.
    const pps_id = try slice_mod.peekPpsId(parts.a.slice()[0..parts.a_len]);
    const pps = &st.pps[pps_id];
    if (!pps.valid) return error.Corrupt;
    const sps = &st.sps[pps.sps_id];
    if (!sps.valid) return error.Corrupt;
    try slice_mod.parse(&b, &parts.header, h, sps, pps);
    const mbs = sps.width_mbs * sps.heightMbs();
    parts.id = try b.ueMax(mbs);
    parts.a_pos = b.pos;
    parts.unit = h;
    parts.pending = true;
    parts.has_b = false;
    parts.has_c = false;
}

fn partitionBC(p: *Parser, st: *State, u: []const u8, h: nal.Header) Error!Step {
    const parts = &st.parts;
    if (!parts.pending) return .done;
    const is_b = h.kind == nal.Type.partition_b;
    const buf = if (is_b) &parts.b else &parts.c;
    const len = try unescape(p, u[1..], buf);
    var b = Bits.init(buf.slice()[0..len]);
    const pps_id = try slice_mod.peekPpsId(parts.a.slice()[0..parts.a_len]);
    const pps = &st.pps[pps_id];
    const sps = &st.sps[pps.sps_id];
    const id = try b.ue();
    if (id != parts.id) return .done;
    if (sps.separate_colour_plane) _ = b.u(2);
    if (pps.redundant_pic_cnt_present) _ = try b.ue();
    if (is_b) {
        parts.b_len = len;
        parts.b_pos = b.pos;
        parts.has_b = true;
        return .done;
    }
    parts.c_len = len;
    parts.c_pos = b.pos;
    parts.has_c = true;
    return flushPartitions(p, st);
}

/// A partition A waiting said as its slice, with what came of B and C.
fn flushPartitions(p: *Parser, st: *State) Error!Step {
    const parts = &st.parts;
    if (!parts.pending) return .done;
    var b = Bits.init(parts.a.slice()[0..parts.a_len]);
    const step = slice(p, st, &b, parts.unit, &.{}, true) catch |e| {
        parts.pending = false;
        return e;
    };
    if (step != .full) parts.pending = false;
    return step;
}

// --- slices --------------------------------------------------------------------

/// The slice in `b` (its payload): its header read, its picture begun or
/// continued, and VPEV_SLICE said with its lists. `u` is the unit as it
/// came; a slice of partitions has none.
fn slice(p: *Parser, st: *State, b: *Bits, h: nal.Header, u: []const u8, partitioned: bool) Error!Step {
    const data = b.data;
    const pps_id = try slice_mod.peekPpsId(data);
    const pps = &st.pps[pps_id];
    if (!pps.valid) return error.Corrupt;
    const sps = &st.sps[pps.sps_id];
    if (!sps.valid) return error.Corrupt;
    const hdr = &st.hdr;
    try slice_mod.parse(b, hdr, h, sps, pps);
    if (hdr.redundant_pic_cnt > 0) return .done;
    if (partitioned) b.pos = st.parts.a_pos;

    if (st.cur != null and newPicture(st, hdr, sps)) finishPicture(p, st);
    // More of a picture whose access unit ended.
    if (st.cur == null and st.ended_early and !newPicture(st, hdr, sps)) return .done;
    if (st.cur == null) {
        if ((try startPicture(p, st, hdr, sps, pps)) == .full) return .full;
    }
    if (st.active_pps != pps) return error.Corrupt;

    const s = st.cur.?;
    const cur_poc = switch (st.structure) {
        1 => s.poc[0],
        2 => s.poc[1],
        else => @min(s.poc[0], s.poc[1]),
    };
    const current: dpb_mod.Current = .{
        .pic = s,
        .structure = st.structure,
        .frame_num = hdr.frame_num,
        .max_frame_num = sps.maxFrameNum(),
        .second_field = st.second_field,
        .poc = cur_poc,
    };
    try st.dpb.buildLists(hdr, &current, &st.lists);

    const sl = &st.slice;
    sl.* = .{
        .unit = u.ptr,
        .unit_bytes = @intCast(u.len),
        .data_bit = @intCast(b.pos),
        .rbsp = b.data.ptr,
        .rbsp_bytes = @intCast(b.data.len),
        .partitioned = partitioned,
        .h264 = hdr,
    };
    if (partitioned) {
        const parts = &st.parts;
        if (parts.has_b) {
            sl.part_b = parts.b.ptr;
            sl.part_b_bytes = @intCast(parts.b_len);
            sl.part_b_bit = @intCast(parts.b_pos);
        }
        if (parts.has_c) {
            sl.part_c = parts.c.ptr;
            sl.part_c_bytes = @intCast(parts.c_len);
            sl.part_c_bit = @intCast(parts.c_pos);
        }
    }
    for (0..2) |l| {
        sl.count[l] = if (hdr.isInter() and (l == 0 or hdr.kind == .b)) hdr.num_ref_idx[l] else 0;
        for (&sl.lists[l], st.lists[l]) |*entry, ref| entry.* = listEntry(&st.dpb, ref);
    }
    p.events.push(.{ .kind = vp.VPEV_SLICE, .slice = sl });
    return .done;
}

fn listEntry(d: *const Dpb, ref: dpb_mod.Ref) vp.VideoListEntry {
    const s = ref.pic orelse return .{};
    return .{ .slot = d.slotOf(s), .structure = ref.structure, .long_term = ref.long, .uid = s.uid, .poc = s.poc };
}

/// Whether the slice `h` begins a new picture (7.4.1.2.4).
fn newPicture(st: *const State, h: *const Header, sps: *const params.Sps) bool {
    const o = &st.hdr0;
    if (h.frame_num != o.frame_num or h.pps_id != o.pps_id or h.field_pic != o.field_pic) return true;
    if (h.field_pic and h.bottom_field != o.bottom_field) return true;
    if ((h.nal_ref_idc == 0) != (o.nal_ref_idc == 0)) return true;
    if (h.idr != o.idr) return true;
    if (h.idr and h.idr_pic_id != o.idr_pic_id) return true;
    if (sps.poc_type == 0) {
        if (h.poc_lsb != o.poc_lsb or h.delta_poc_bottom != o.delta_poc_bottom) return true;
    } else if (sps.poc_type == 1) {
        if (h.delta_poc[0] != o.delta_poc[0] or h.delta_poc[1] != o.delta_poc[1]) return true;
    }
    return false;
}

// --- pictures --------------------------------------------------------------------

/// The sequence `sps` made the active one: what is waiting shown first
/// when its pictures' size or kind changed, and VPEV_SEQUENCE said when
/// anything it says did.
fn activate(p: *Parser, st: *State, sps: *const params.Sps) void {
    st.active_sps = sps;
    const d = &st.dpb;
    d.size = sps.dpbFrames();
    d.reorder = if (sps.restriction) @min(sps.num_reorder_frames, d.size) else d.size;
    var seq: vp.VideoSequence = .{
        .codec = vp.VPCODEC_H264,
        .coded_width = sps.width_mbs * 16,
        .coded_height = sps.heightMbs() * 16,
        .left = sps.cropX(),
        .top = sps.cropY(),
        .width = sps.croppedWidth(),
        .height = sps.croppedHeight(),
        .dpb_frames = d.size,
        .reorder = d.reorder,
        .slots = d.count,
        .bit_depth_luma = sps.bit_depth_luma,
        .bit_depth_chroma = sps.bit_depth_chroma,
        .chroma_format = sps.chroma_format_idc,
        .full_range = sps.full_range,
        .matrix = sps.matrix,
        .colour_primaries = sps.colour_primaries,
        .transfer = sps.transfer,
        .profile = sps.profile_idc,
        .level = sps.level_idc,
        .h264_sps = sps,
    };
    if (sps.timing and sps.num_units_in_tick != 0) {
        seq.rate_num = sps.time_scale;
        seq.rate_den = 2 * sps.num_units_in_tick;
    }
    const old = &st.sequence;
    const same_pictures = st.told and old.coded_width == seq.coded_width and old.coded_height == seq.coded_height and
        old.chroma_format == seq.chroma_format and old.bit_depth_luma == seq.bit_depth_luma and
        old.bit_depth_chroma == seq.bit_depth_chroma and old.h264_sps != null and
        old.h264_sps.?.separate_colour_plane == sps.separate_colour_plane;
    const same = same_pictures and old.left == seq.left and old.top == seq.top and old.width == seq.width and
        old.height == seq.height and old.dpb_frames == seq.dpb_frames and old.reorder == seq.reorder and
        old.rate_num == seq.rate_num and old.rate_den == seq.rate_den and old.full_range == seq.full_range and
        old.matrix == seq.matrix and old.colour_primaries == seq.colour_primaries and old.transfer == seq.transfer and
        old.profile == seq.profile and old.level == seq.level and old.h264_sps == seq.h264_sps;
    if (same) return;
    if (!same_pictures and st.told) {
        // A new size: what is waiting is shown first.
        storeLoneField(st);
        d.flush();
    }
    st.sequence = seq;
    st.told = true;
    p.events.push(.{ .kind = vp.VPEV_SEQUENCE, .sequence = &st.sequence });
}

fn startPicture(p: *Parser, st: *State, hdr: *const Header, sps: *const params.Sps, pps: *const params.Pps) Error!Step {
    st.ended_early = false;
    activate(p, st, sps);
    st.active_pps = pps;
    const structure: u2 = if (!hdr.field_pic) 3 else if (hdr.bottom_field) 2 else 1;
    // The second field of the frame the last picture began?
    if (st.lone_field) |lf| {
        const pairs = hdr.field_pic and structure != st.lone_structure and lf.frame_num == hdr.frame_num and
            !hdr.idr and st.lone_ref == (hdr.nal_ref_idc != 0);
        if (pairs) {
            st.lone_field = null;
            st.cur = lf;
            st.structure = structure;
            st.second_field = true;
            st.hdr0 = hdr.*;
            st.dpb.computePoc(hdr, sps, &lf.poc);
            lf.fields |= structure;
            pushPicture(p, st, lf, hdr, sps, pps);
            return .done;
        }
        storeLoneField(st);
    }
    if (hdr.idr) {
        if (!hdr.no_output_of_prior_pics) st.dpb.flush();
        st.dpb.reset(true);
    } else {
        if ((try frameNumGap(p, st, hdr, sps)) == .full) return .full;
    }
    const s = st.dpb.take() orelse return .full;
    s.fields = structure;
    s.frame_num = hdr.frame_num;
    s.frame_num_wrap = @intCast(hdr.frame_num);
    s.idr = hdr.idr;
    s.time = p.packet.time;
    st.dpb.computePoc(hdr, sps, &s.poc);
    if (hdr.field_pic) {
        // The other field, until it comes, as this one.
        if (structure == 1) s.poc[1] = s.poc[0] else s.poc[0] = s.poc[1];
    }
    st.cur = s;
    st.structure = structure;
    st.second_field = false;
    st.hdr0 = hdr.*;
    pushPicture(p, st, s, hdr, sps, pps);
    return .done;
}

/// VPEV_PICTURE for `s`, with the references the buffer holds before the
/// picture is marked - the first field of its own frame among them.
fn pushPicture(p: *Parser, st: *State, s: *Pic, hdr: *const Header, sps: *const params.Sps, pps: *const params.Pps) void {
    const d = &st.dpb;
    const slot = d.slotOf(s);
    const pic = &st.pictures[slot];
    pic.* = .{
        .slot = slot,
        .structure = st.structure,
        .second_field = st.second_field,
        .idr = hdr.idr,
        .reference = hdr.nal_ref_idc != 0,
        .uid = s.uid,
        .frame_num = hdr.frame_num,
        .poc = s.poc,
        .time = s.time,
        .h264_sps = sps,
        .h264_pps = pps,
        .peak_nits = p.light.settle(),
    };
    var n: u8 = 0;
    for (&d.pics) |*o| {
        if (!o.in_use or !o.isRef() or n == pic.refs.len) continue;
        const long = o.ref[0] == .long or o.ref[1] == .long;
        pic.refs[n] = .{
            .slot = d.slotOf(o),
            .long_term = long,
            .missing = o.non_existing,
            .fields = @as(u8, @intFromBool(o.ref[0] != .none)) | @as(u8, @intFromBool(o.ref[1] != .none)) << 1,
            .frame_num = if (long) o.long_term_idx else o.frame_num,
            .poc = o.poc,
            .uid = o.uid,
        };
        n += 1;
    }
    pic.ref_count = n;
    p.events.push(.{ .kind = vp.VPEV_PICTURE, .slot = slot, .time = s.time, .picture = pic });
}

/// Frames for the frame_num values a stream skipped (8.2.5.2): each a
/// short-term reference that is never shown, said with VPEV_MISSING.
fn frameNumGap(p: *Parser, st: *State, hdr: *const Header, sps: *const params.Sps) Error!Step {
    const d = &st.dpb;
    const max = sps.maxFrameNum();
    const prev = d.prev_ref_frame_num;
    if (hdr.frame_num == prev or hdr.frame_num == (prev + 1) % max) return .done;
    var num = (prev + 1) % max;
    // Only the last max_num_ref_frames of them outlast the sliding
    // window; the ones before would leave at once.
    const keep = @max(@as(u32, sps.max_num_ref_frames), 1);
    const gap = (hdr.frame_num + max - num) % max;
    if (gap > keep) num = (hdr.frame_num + max - keep) % max;
    var guard: u32 = 0;
    while (num != hdr.frame_num and guard < max) : (guard += 1) {
        const s = d.take() orelse return .full;
        s.fields = 3;
        s.frame_num = num;
        s.frame_num_wrap = @intCast(num);
        s.non_existing = true;
        const gh: Header = .{ .frame_num = num, .nal_ref_idc = 1 };
        if (sps.poc_type != 0) {
            // Their FrameNumOffset keeps the count going; type 0's count
            // is the next real picture's alone.
            d.computePoc(&gh, sps, &s.poc);
            d.afterPicture(&gh, sps, s, false);
        } else {
            d.prev_frame_num = num;
            d.prev_ref_frame_num = num;
        }
        const current: dpb_mod.Current = .{ .pic = s, .structure = 3, .frame_num = num, .max_frame_num = max, .second_field = false, .poc = 0 };
        d.slidingWindow(sps, &current);
        s.ref = .{ .short, .short };
        const slot = d.slotOf(s);
        st.pictures[slot] = .{ .slot = slot, .structure = 3, .reference = true, .uid = s.uid, .frame_num = num, .poc = s.poc, .h264_sps = sps };
        p.events.push(.{ .kind = vp.VPEV_MISSING, .slot = slot, .picture = &st.pictures[slot] });
        d.store(s);
        num = (num + 1) % max;
    }
    return .done;
}

/// The first field of a pair whose second never came, kept as it is.
fn storeLoneField(st: *State) void {
    const lf = st.lone_field orelse return;
    st.lone_field = null;
    st.dpb.store(lf);
}

/// The picture being read finished: VPEV_DECODE, then it is marked and
/// kept.
fn finishPicture(p: *Parser, st: *State) void {
    const s = st.cur orelse return;
    st.cur = null;
    const sps = st.active_sps.?;
    const hdr = &st.hdr0;
    const d = &st.dpb;
    p.events.push(.{ .kind = vp.VPEV_DECODE, .slot = d.slotOf(s) });
    var mmco5 = false;
    if (hdr.nal_ref_idc != 0) {
        const current: dpb_mod.Current = .{
            .pic = s,
            .structure = st.structure,
            .frame_num = hdr.frame_num,
            .max_frame_num = sps.maxFrameNum(),
            .second_field = st.second_field,
            .poc = 0,
        };
        mmco5 = d.mark(hdr, sps, &current);
    }
    if (mmco5) {
        // Everything before is shown first; the picture counts as
        // frame_num 0 from now on and its order count starts again from
        // it (8.2.1, 7.4.3).
        s.mmco5 = true;
        s.frame_num = 0;
        switch (st.structure) {
            1 => s.poc[0] = 0,
            2 => s.poc[1] = 0,
            else => {
                const t = @min(s.poc[0], s.poc[1]);
                s.poc[0] -= t;
                s.poc[1] -= t;
            },
        }
        d.flush();
    }
    d.afterPicture(hdr, sps, s, mmco5);
    if (st.structure != 3 and !st.second_field) {
        st.lone_field = s;
        st.lone_structure = st.structure;
        st.lone_ref = hdr.nal_ref_idc != 0;
        return;
    }
    d.store(s);
}
