// SPDX-License-Identifier: MIT
//! HEVC read unit by unit into events: the parameter sets kept, each slice
//! segment's header read, the picture it belongs to begun or continued,
//! its slice's lists built, and a picture finished - kept and bumped -
//! when the next one begins, its access unit ends or the stream does.
//!
//! **A picture** begins with its first slice segment
//! (first_slice_segment_in_pic_flag). Its order count is worked out, its
//! reference picture set marks the references, the pictures due before it
//! are shown (or, after an IRAP picture that begins a sequence, let go
//! of); its sequence is made the active one (VPEV_SEQUENCE when what it
//! says changed); each reference the set names and the stream lacks gets
//! a slot (VPEV_MISSING); then a slot is taken for it and VPEV_PICTURE
//! said. Each segment is VPEV_SLICE, with its slice's lists. A RASL
//! picture whose IRAP picture began a sequence is passed over: its
//! references are not there.
//!
//! **Waiting for a slot**: a picture or a missing reference that finds
//! none free stops the unit's reading (`Step.full`); the unit is read
//! again once one was given back. What was done before the stop - the
//! last picture finished, its order count, the marking, the missing
//! references already given slots - comes to the same when done again.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const bits_mod = @import("hevcsets").bits;
const Bits = bits_mod.Bits;
const Error = bits_mod.Error;
const nal = @import("hevcsets").nal;
const params = @import("hevcsets").params;
const slice_mod = @import("slice.zig");
const Header = slice_mod.Header;
const dpb_mod = @import("dpb.zig");
const Dpb = dpb_mod.Dpb;
const Pic = dpb_mod.Pic;
const Rps = dpb_mod.Rps;
const _parser = @import("../parser/_parser.zig");
const Parser = _parser.Parser;
const Buffer = _parser.Buffer;
const Step = _parser.Step;

pub const State = struct {
    dpb: Dpb,
    sps: [16]params.Sps,
    pps: [64]params.Pps,
    active_sps: ?*const params.Sps,
    active_pps: ?*const params.Pps,
    /// The sequence as it was last said; `told` once it was.
    sequence: vp.VideoSequence,
    told: bool,
    // --- the picture being decoded ---
    cur: ?*Pic,
    /// PicOutputFlag.
    cur_output: bool,
    rps: Rps,
    /// The header of the slice's independent segment, and whether its
    /// lists were built: a dependent segment needs both.
    indep: Header,
    slice_ok: bool,
    /// The last picture was finished at the end of its access unit: a
    /// segment that does not begin another is passed over.
    ended_early: bool,
    /// The segment being read.
    hdr: Header,
    rbsp: Buffer,
    /// What the events point at: each picture's by its slot, the slice.
    pictures: [dpb_mod.max_pics]vp.VideoPicture,
    slice: vp.VideoSlice,
    lists: dpb_mod.Lists,
};

/// A reading of HEVC for `p`, with nothing read; null without memory.
pub fn create(p: *Parser) ?*State {
    const memory = p.alloc(@sizeOf(State)) orelse return null;
    const st: *State = @ptrCast(@alignCast(memory));
    // Cleared memory is every field's start but these.
    st.dpb.events = &p.events;
    st.dpb.count = dpb_mod.stream_pics + p.extra_slots;
    st.dpb.size = 16;
    st.dpb.reorder = 16;
    st.dpb.uid_next = 1;
    st.dpb.first = true;
    return st;
}

pub fn destroy(p: *Parser, st: *State) void {
    st.rbsp.release(p);
    p.free(@ptrCast(st));
}

/// An hvcC's parameter sets read, and the length its packets' units come
/// after.
pub fn setup(p: *Parser, st: *State, data: []const u8) Error!void {
    const config = try nal.HevcConfig.parse(data);
    p.length_size = config.length_size;
    var units = config.units();
    while (try units.next()) |u| _ = try unit(p, st, u);
}

/// Everything dropped, for a seek: the next picture must be an IRAP
/// picture. The slots the caller holds stay lent.
pub fn reset(st: *State) void {
    st.cur = null;
    st.ended_early = false;
    // The sequence is said again with the next picture.
    st.told = false;
    st.dpb.reset(false);
}

/// The payload of a unit (after its two header bytes) unescaped into
/// `st.rbsp`: its length.
fn unescape(p: *Parser, st: *State, payload: []const u8) Error!usize {
    if (!st.rbsp.reserve(p, payload.len + 64)) return error.NoMemory;
    return nal.unescape(payload, st.rbsp.slice());
}

/// One NAL unit, without its start code or length.
pub fn unit(p: *Parser, st: *State, u: []const u8) Error!Step {
    if (u.len < 2) return .done;
    const h = try nal.header(u);
    // The layers above the base one are another decoder's.
    if (h.layer != 0) return .done;
    if (!h.isSlice()) st.ended_early = false;
    switch (h.kind) {
        nal.Type.sps => {
            finishPicture(p, st);
            const n = try unescape(p, st, u[2..]);
            var b = Bits.init(st.rbsp.slice()[0..n]);
            var s: params.Sps = .{};
            const limits: params.Limits = .{ .max_width = p.max_width_mbs * 16, .max_height = p.max_height_mbs * 16 };
            const id = try params.parseSps(&b, &s, limits);
            if (id >= 16) return error.Corrupt;
            // The active one changes only at an IRAP picture.
            st.sps[id] = s;
        },
        nal.Type.pps => {
            finishPicture(p, st);
            const n = try unescape(p, st, u[2..]);
            var b = Bits.init(st.rbsp.slice()[0..n]);
            var peek = b;
            _ = try peek.ue();
            const sps_id = try peek.ueMax(15);
            var pps: params.Pps = .{};
            const id = try params.parsePps(&b, &pps, if (st.sps[sps_id].valid) &st.sps[sps_id] else null);
            if (id >= 64) return error.Corrupt;
            st.pps[id] = pps;
        },
        nal.Type.prefix_sei => {
            finishPicture(p, st);
            const n = try unescape(p, st, u[2..]);
            p.light.sei(st.rbsp.slice()[0..n]);
        },
        nal.Type.vps, nal.Type.aud, 41...44, 48...55 => finishPicture(p, st),
        nal.Type.end_of_seq, nal.Type.end_of_stream => {
            finishPicture(p, st);
            st.dpb.first = true;
        },
        else => if (h.isSlice()) return segment(p, st, u, h),
    }
    return .done;
}

/// The access unit ended - a packet of an MP4 or Matroska track is one -
/// so the picture is finished now rather than when the next one begins.
pub fn endAccessUnit(p: *Parser, st: *State) Error!Step {
    if (st.cur == null) return .done;
    finishPicture(p, st);
    st.ended_early = true;
    return .done;
}

/// The stream's end: everything finished, every picture shown, and
/// every slot let go of - nothing is referred to past the end.
pub fn flush(p: *Parser, st: *State) Error!Step {
    finishPicture(p, st);
    st.dpb.flush();
    st.dpb.reset(true);
    return .done;
}

// --- slice segments ------------------------------------------------------------

/// The slice segment `u`: its header read, its picture begun or
/// continued, and VPEV_SLICE said with its slice's lists.
fn segment(p: *Parser, st: *State, u: []const u8, h: nal.Header) Error!Step {
    const n = try unescape(p, st, u[2..]);
    const rbsp = st.rbsp.slice()[0..n];
    var b = Bits.init(rbsp);
    var peek = b;
    const ids = try slice_mod.peekPps(&peek, h);
    const pps = &st.pps[ids.pps];
    if (!pps.valid) return error.Corrupt;
    const sps = &st.sps[pps.sps_id];
    if (!sps.valid) return error.Corrupt;
    if (ids.first) finishPicture(p, st);
    if (st.cur == null) {
        // More of a picture whose access unit ended, or of one whose
        // first segment was lost, or a RASL picture passed over.
        if (!ids.first and st.ended_early) return .done;
        if (st.dpb.skipped(h)) return .done;
    } else if (pps != st.active_pps) return error.Corrupt;
    const hdr = &st.hdr;
    try slice_mod.parse(&b, hdr, h, sps, pps, &st.indep);
    if (st.cur == null) {
        // A dependent segment needs the header of its slice.
        if (hdr.dependent) return error.Corrupt;
        if ((try startPicture(p, st, h, hdr, sps, pps)) == .full) return .full;
    }
    if (!hdr.dependent) {
        st.indep = hdr.*;
        st.slice_ok = false;
        try Dpb.buildLists(hdr, &st.rps, &st.lists);
        st.slice_ok = true;
    } else if (!st.slice_ok) return error.Corrupt;

    const lists = &st.lists;
    const sl = &st.slice;
    sl.* = .{
        .unit = u.ptr,
        .unit_bytes = @intCast(u.len),
        .data_bit = hdr.data_offset * 8,
        .rbsp = rbsp.ptr,
        .rbsp_bytes = @intCast(n),
        .count = lists.count,
        .collocated = if (lists.col) |c| st.dpb.slotOf(c) else vp.VP_NO_SLOT,
        .hevc = hdr,
    };
    for (0..2) |l| {
        for (sl.lists[l][0..lists.count[l]], lists.refs[l][0..lists.count[l]]) |*entry, ref| entry.* = listEntry(&st.dpb, ref);
    }
    p.events.push(.{ .kind = vp.VPEV_SLICE, .slice = sl });
    return .done;
}

fn listEntry(d: *const Dpb, ref: dpb_mod.Ref) vp.VideoListEntry {
    const s = ref.pic orelse return .{};
    return .{ .slot = d.slotOf(s), .structure = 3, .long_term = ref.long, .uid = s.uid, .poc = .{ ref.poc, ref.poc } };
}

// --- pictures --------------------------------------------------------------------

/// The sequence `sps` made the active one, and VPEV_SEQUENCE said when
/// anything it says changed. The pictures of the one before were shown
/// or let go of already: a new sequence begins at an IRAP picture that
/// has NoRaslOutputFlag 1.
fn activate(p: *Parser, st: *State, sps: *const params.Sps) void {
    st.active_sps = sps;
    const d = &st.dpb;
    var seq: vp.VideoSequence = .{
        .codec = vp.VPCODEC_HEVC,
        .coded_width = sps.width,
        .coded_height = sps.height,
        .left = sps.cropX(),
        .top = sps.cropY(),
        .width = sps.croppedWidth(),
        .height = sps.croppedHeight(),
        .dpb_frames = sps.max_dec_pic_buffering,
        .reorder = sps.max_num_reorder,
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
        .hevc_sps = sps,
    };
    if (sps.timing and sps.num_units_in_tick != 0) {
        seq.rate_num = sps.time_scale;
        seq.rate_den = sps.num_units_in_tick;
    }
    const old = &st.sequence;
    const same = st.told and old.coded_width == seq.coded_width and old.coded_height == seq.coded_height and
        old.chroma_format == seq.chroma_format and old.bit_depth_luma == seq.bit_depth_luma and
        old.bit_depth_chroma == seq.bit_depth_chroma and old.left == seq.left and old.top == seq.top and
        old.width == seq.width and old.height == seq.height and old.dpb_frames == seq.dpb_frames and
        old.reorder == seq.reorder and old.rate_num == seq.rate_num and old.rate_den == seq.rate_den and
        old.full_range == seq.full_range and old.matrix == seq.matrix and old.colour_primaries == seq.colour_primaries and
        old.transfer == seq.transfer and old.profile == seq.profile and old.level == seq.level and old.hevc_sps == seq.hevc_sps;
    if (same) return;
    st.sequence = seq;
    st.told = true;
    p.events.push(.{ .kind = vp.VPEV_SEQUENCE, .sequence = &st.sequence });
}

fn startPicture(p: *Parser, st: *State, h: nal.Header, hdr: *const Header, sps: *const params.Sps, pps: *const params.Pps) Error!Step {
    try params.checkPps(pps, sps);
    st.ended_early = false;
    const d = &st.dpb;
    const no_rasl = h.isIrap() and d.noRaslOutput(h);
    const poc = d.computePoc(h, hdr, sps, no_rasl);
    try d.applyRps(h, hdr, sps, poc, no_rasl, &st.rps);
    // NoOutputOfPriorPicsFlag (C.5.2.2): a CRA picture that begins a
    // sequence lets go of the pictures of the one before.
    d.beforePicture(sps, no_rasl, hdr.no_output_of_prior_pics or h.kind == nal.Type.cra);
    activate(p, st, sps);
    st.active_pps = pps;
    if ((try missing(p, st, sps)) == .full) return .full;
    const s = d.take() orelse return .full;
    // A reference once decoded; so already, that nothing lets go of it.
    s.ref = .short;
    s.poc = poc;
    s.time = p.packet.time;
    st.cur = s;
    st.cur_output = hdr.pic_output;
    st.slice_ok = false;
    pushPicture(p, st, s, h, hdr, sps, pps, no_rasl);
    return .done;
}

/// VPEV_PICTURE for `s`, with the pictures of its reference picture set.
fn pushPicture(p: *Parser, st: *State, s: *Pic, h: nal.Header, hdr: *const Header, sps: *const params.Sps, pps: *const params.Pps, no_rasl: bool) void {
    const d = &st.dpb;
    const slot = d.slotOf(s);
    const pic = &st.pictures[slot];
    pic.* = .{
        .slot = slot,
        .structure = 3,
        .idr = h.isIdr(),
        .reference = !h.isSubLayerNonRef(),
        .uid = s.uid,
        .poc = .{ s.poc, s.poc },
        .time = s.time,
        .hevc_sps = sps,
        .hevc_pps = pps,
        .nal_type = h.kind,
        .irap = h.isIrap(),
        .peak_nits = p.light.settle(),
        .no_rasl_output = no_rasl,
        .st_rps_bits = hdr.st_rps_bits,
    };
    var n: u8 = 0;
    for (0..5) |set| {
        for (st.rps.pic[set][0..st.rps.count[set]]) |found| {
            const o = found orelse continue;
            const o_slot = d.slotOf(o);
            // The index of the picture in `refs`, added once.
            var idx: u8 = 0;
            while (idx < n and pic.refs[idx].slot != o_slot) idx += 1;
            if (idx == n) {
                if (n == pic.refs.len) continue;
                pic.refs[n] = .{
                    .slot = o_slot,
                    .long_term = o.ref == .long,
                    .missing = o.missing,
                    .fields = 3,
                    .poc = .{ o.poc, o.poc },
                    .uid = o.uid,
                };
                n += 1;
            }
            pic.rps[set][pic.rps_count[set]] = idx;
            pic.rps_count[set] += 1;
        }
    }
    pic.ref_count = n;
    p.events.push(.{ .kind = vp.VPEV_PICTURE, .slot = slot, .time = s.time, .picture = pic });
}

/// Pictures for the references the current picture lacks (8.3.3): each
/// a reference that is never shown, said with VPEV_MISSING.
fn missing(p: *Parser, st: *State, sps: *const params.Sps) Error!Step {
    const d = &st.dpb;
    for ([_]usize{ Rps.before, Rps.after, Rps.long }) |set| {
        for (st.rps.pic[set][0..st.rps.count[set]], st.rps.poc[set][0..st.rps.count[set]]) |*found, poc| {
            if (found.* != null) continue;
            const s = d.take() orelse return .full;
            s.ref = if (set == Rps.long) .long else .short;
            s.poc = poc;
            s.missing = true;
            found.* = s;
            const slot = d.slotOf(s);
            st.pictures[slot] = .{ .slot = slot, .structure = 3, .reference = true, .uid = s.uid, .poc = .{ poc, poc }, .hevc_sps = sps };
            p.events.push(.{ .kind = vp.VPEV_MISSING, .slot = slot, .picture = &st.pictures[slot] });
        }
    }
    return .done;
}

/// The picture being read finished: VPEV_DECODE, then it is kept.
fn finishPicture(p: *Parser, st: *State) void {
    const s = st.cur orelse return;
    st.cur = null;
    const d = &st.dpb;
    p.events.push(.{ .kind = vp.VPEV_DECODE, .slot = d.slotOf(s) });
    d.store(s, st.cur_output);
}
