// SPDX-License-Identifier: MIT
//! AV1 read OBU by OBU into events: each frame's header read, a slot
//! taken for it and its events said tile by tile, the eight reference
//! slots updated as its header says, and the frame a temporal unit shows
//! said at the unit's end.
//!
//! **A packet** is a temporal unit, or part of one: OBUs (5.3), each a
//! unit here - a temporal delimiter at the unit's start, the sequence
//! header, most often with a key frame, and the frames: a frame header
//! and its tile groups, or the two in one OBU. The OBUs with layers of
//! another operating point than 0 are passed by, and so are metadata,
//! padding and copies of a header.
//!
//! **A frame** is VPEV_SEQUENCE where its size or format is not what the
//! sequence said, VPEV_PICTURE - its slot, its header, the eight reference
//! slots' pictures as its references - a VPEV_SLICE for each tile, each
//! read on its own call (`Step.again`), so that the tiles of a frame
//! however many go through the one slice; VPEV_DECODE after the last
//! tile; then VPEV_FREE for each picture nothing holds any more. A frame
//! shown, or one shown again (show_existing_frame), is held until its
//! temporal unit ends - at its packet's end with VPPKT_ACCESS_UNIT, at
//! the next temporal delimiter without - and is then VPEV_SHOW: of a unit
//! with several, the last.
//!
//! **Waiting for a key frame**: at the start, after a seek, after a
//! sequence header of another format and after a frame that was not
//! right - or that never got its last tile - a frame that is not a key
//! frame or an intra-only one is passed over (VPERR_CORRUPT), and so is
//! one whose references are empty, of another format or a size it cannot
//! be predicted from.
//!
//! **Waiting for a slot**: a frame that finds none free stops before
//! anything of it is kept (`Step.full`) and is read again once one was
//! given back.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const av1 = vp.av1;
const header = @import("av1header");
const Error = @import("h264sets").bits.Error;
const _parser = @import("../parser/_parser.zig");
const Parser = _parser.Parser;
const Step = _parser.Step;

/// Eight reference slots hold eight pictures at most; the frame being
/// decoded is one more, and the frame shown last, waiting for its
/// temporal unit's end, another; then the slots the caller keeps beyond
/// them (VPA_Slots, 32 at most).
pub const stream_pics = 10;
pub const max_pics = stream_pics + 32;

const none = vp.VP_NO_SLOT;

/// What is kept of a picture.
pub const Pic = struct {
    /// The stream's: in a reference slot, being decoded, or to be shown.
    in_use: bool = false,
    /// The caller's: handed out, and not yet given back.
    lent: bool = false,
    /// A number never given twice.
    uid: u32 = 0,
    /// The reference slots that hold it.
    refs: u8 = 0,
    /// To be shown at the end of its temporal unit.
    showing: bool = false,
    /// Its size - UpscaledWidth by FrameHeight - and format, which a frame
    /// that refers to it is checked against.
    width: u32 = 0,
    height: u32 = 0,
    bit_depth: u8 = 8,
    ss_x: u8 = 1,
    ss_y: u8 = 1,
    mono: bool = false,
};

pub const State = struct {
    pics: [max_pics]Pic = @splat(.{}),
    /// The slots there are: the stream's and the caller's.
    count: u32 = stream_pics,
    uid_next: u32 = 1,
    /// The picture in each of the eight reference slots, by its slot, and
    /// what each slot keeps for the headers after it; what the headers
    /// hand on outside the slots.
    ref_slots: [8]u8 = @splat(none),
    states: [8]header.RefState = @splat(.{}),
    carry: header.Carry = .{},
    /// The sequence header in force, once one was read.
    seq: av1.Av1Sequence = .{},
    have_seq: bool = false,
    /// Until a key frame shown.
    need_key: bool = true,
    /// The frame whose tiles come: its slot, its header and picture, the
    /// tile due next. While a tile group's tiles are said one per call,
    /// `in_group`, with where the next one starts in the unit and the
    /// group's last.
    in_frame: bool = false,
    frame_slot: u8 = none,
    header: av1.Av1FrameHeader = .{},
    picture: vp.VideoPicture = .{},
    next_tile: u32 = 0,
    in_group: bool = false,
    group_at: u32 = 0,
    group_end: u32 = 0,
    /// The frame to show at the end of the temporal unit: its slot, the
    /// header it is shown with and its picture, and when.
    show_slot: u8 = none,
    shown_header: av1.Av1FrameHeader = .{},
    shown_picture: vp.VideoPicture = .{},
    show_time: i64 = 0,
    /// The sequence as it was last said, and the largest frame its header
    /// said; `told` once it was.
    sequence: vp.VideoSequence = .{},
    told_max_width: u32 = 0,
    told_max_height: u32 = 0,
    told: bool = false,
    /// The tile the last VPEV_SLICE said.
    slice: vp.VideoSlice = .{},
};

/// A reading of AV1 for `p`, with nothing read; null without memory.
pub fn create(p: *Parser) ?*State {
    const memory = p.alloc(@sizeOf(State)) orelse return null;
    const st: *State = @ptrCast(@alignCast(memory));
    st.* = .{ .count = stream_pics + p.extra_slots };
    return st;
}

pub fn destroy(p: *Parser, st: *State) void {
    p.free(@ptrCast(st));
}

/// The track's av1C (ISO/IEC 14496-15's for AV1): a byte of marker and
/// version, three of what the sequence header says, then OBUs - the
/// sequence header among them, read now. A record that is not right is
/// passed by: the key frames carry the sequence header again.
pub fn setup(st: *State, data: []const u8) void {
    if (data.len <= 4 or data[0] != 0x81) return;
    var at: usize = 4;
    while (at < data.len) {
        const o = header.obu(data[at..]) catch return;
        at += o.len;
        if (o.kind != header.OBU_SEQUENCE_HEADER) continue;
        st.seq = header.sequence(o.payload) catch return;
        st.have_seq = true;
    }
}

/// Everything dropped, for a seek: the next frame must be a key frame.
/// The slots the caller holds stay lent.
pub fn reset(st: *State) void {
    for (st.pics[0..st.count]) |*s| {
        s.in_use = false;
        s.refs = 0;
        s.showing = false;
    }
    st.ref_slots = @splat(none);
    st.states = @splat(.{});
    st.need_key = true;
    st.in_frame = false;
    st.in_group = false;
    st.frame_slot = none;
    st.show_slot = none;
    // The sequence is said again with the next frame.
    st.told = false;
}

/// The stream ended: the frame due shown, then every picture let go of,
/// a VPEV_FREE for each.
pub fn flush(p: *Parser, st: *State) Error!Step {
    // A frame without its last tile is passed over with the rest.
    endUnit(p, st) catch {};
    st.ref_slots = @splat(none);
    for (st.pics[0..st.count]) |*s| s.refs = 0;
    freeUnheld(p, st);
    st.need_key = true;
    return .done;
}

/// The packet's temporal unit ended (VPPKT_ACCESS_UNIT).
pub fn endAccessUnit(p: *Parser, st: *State) Error!Step {
    try endUnit(p, st);
    return .done;
}

/// The slot `slot` the caller's no more.
pub fn unlend(st: *State, slot: u32) void {
    if (slot < st.count) st.pics[slot].lent = false;
}

/// The next OBU of the packet, from `p.at` on, its header included; null
/// at the packet's end.
pub fn peek(p: *Parser) error{Corrupt}!?[]const u8 {
    const d = p.bytes();
    if (p.at >= d.len) return null;
    const o = try header.obu(d[p.at..]);
    p.unit_end = @intCast(p.at + o.len);
    return d[p.at..][0..o.len];
}

/// One OBU `u` of the packet - or a tile group of it read on.
pub fn unit(p: *Parser, st: *State, u: []const u8) Error!Step {
    if (st.in_group) return tiles(p, st, u) catch |e| return abandon(p, st, e);
    const o = try header.obu(u);
    switch (o.kind) {
        header.OBU_SEQUENCE_HEADER => {
            const s = header.sequence(o.payload) catch |e| {
                st.need_key = true;
                return e;
            };
            if (st.have_seq and !sameFormat(&st.seq, &s)) st.need_key = true;
            st.seq = s;
            st.have_seq = true;
        },
        header.OBU_TEMPORAL_DELIMITER => try endUnit(p, st),
        header.OBU_FRAME_HEADER, header.OBU_REDUNDANT_FRAME_HEADER, header.OBU_FRAME => {
            if (!inOperatingPoint(st, &o)) return .done;
            if (st.in_frame) {
                // A copy of the header of the frame whose tiles come.
                if (o.kind == header.OBU_FRAME) return abandon(p, st, error.Corrupt);
                return .done;
            }
            if (o.kind == header.OBU_REDUNDANT_FRAME_HEADER) return .done;
            if (!st.have_seq) return error.Corrupt;
            return frameHeader(p, st, u, &o);
        },
        header.OBU_TILE_GROUP => {
            if (!inOperatingPoint(st, &o)) return .done;
            if (!st.in_frame) return error.Corrupt;
            return startGroup(p, st, u, offsetOf(u, o.payload)) catch |e| return abandon(p, st, e);
        },
        header.OBU_METADATA => p.light.metadata(o.payload),
        else => {},
    }
    return .done;
}

/// Whether the OBU belongs to the operating point read: every one
/// without layers does.
fn inOperatingPoint(st: *const State, o: *const header.Obu) bool {
    const idc = st.seq.chosen_operating_point_idc;
    if (idc == 0 or !o.extension) return true;
    const in_temporal = (idc >> @intCast(o.temporal_id)) & 1 != 0;
    const in_spatial = (idc >> @intCast(o.spatial_id + 8)) & 1 != 0;
    return in_temporal and in_spatial;
}

/// Whether frames of sequence `b` can be predicted from those of `a`.
fn sameFormat(a: *const av1.Av1Sequence, b: *const av1.Av1Sequence) bool {
    return a.bit_depth == b.bit_depth and a.mono_chrome == b.mono_chrome and a.subsampling_x == b.subsampling_x and
        a.subsampling_y == b.subsampling_y and a.max_frame_width == b.max_frame_width and
        a.max_frame_height == b.max_frame_height and a.use_128x128_superblock == b.use_128x128_superblock;
}

fn offsetOf(u: []const u8, part: []const u8) usize {
    return @intFromPtr(part.ptr) - @intFromPtr(u.ptr);
}

/// A frame's header, from OBU `o` of unit `u`: its events begun, and of
/// an OBU_FRAME its first tile said.
fn frameHeader(p: *Parser, st: *State, u: []const u8, o: *const header.Obu) Error!Step {
    // Read over a copy of what the headers hand on, kept once the frame
    // is: a frame that waits for a slot is read again as it was.
    var carry = st.carry;
    var b: header.Bits = .{ .data = o.payload };
    const h = header.frame(&b, &st.seq, &st.states, &carry, o.temporal_id, o.spatial_id) catch |e| {
        st.need_key = true;
        return e;
    };
    if (h.show_existing_frame) {
        st.carry = carry;
        return showExisting(p, st, &h);
    }
    check(p, st, &h) catch |e| {
        st.carry = carry;
        st.need_key = true;
        return e;
    };
    const pic = take(st) orelse return .full;
    st.carry = carry;
    if (h.frame_type == av1.KEY_FRAME and h.show_frame) st.need_key = false;
    tell(p, st, &h);
    const slot = slotOf(st, pic);
    pic.width = h.upscaled_width;
    pic.height = h.frame_height;
    pic.bit_depth = st.seq.bit_depth;
    pic.ss_x = st.seq.subsampling_x;
    pic.ss_y = st.seq.subsampling_y;
    pic.mono = st.seq.mono_chrome;

    st.header = h;
    st.picture = .{
        .slot = slot,
        .idr = h.frame_type == av1.KEY_FRAME and h.show_frame,
        .reference = h.refresh_frame_flags != 0,
        .ref_count = 8,
        .uid = pic.uid,
        .time = p.packet.time,
        .av1 = &st.header,
        .av1_sequence = &st.seq,
        .peak_nits = p.light.settle(),
    };
    for (st.ref_slots, 0..) |ref, i| {
        st.picture.refs[i] = .{ .slot = ref, .fields = 3, .uid = if (ref != none) st.pics[ref].uid else 0 };
    }
    p.events.push(.{ .kind = vp.VPEV_PICTURE, .slot = slot, .time = p.packet.time, .picture = &st.picture });
    st.in_frame = true;
    st.frame_slot = slot;
    st.next_tile = 0;
    if (o.kind != header.OBU_FRAME) return .done;
    // frame_obu (5.10): the tile group after the header, on a byte.
    b.byteAlign();
    if (b.overrun()) return abandon(p, st, error.Corrupt);
    return startGroup(p, st, u, offsetOf(u, o.payload) + (b.pos >> 3)) catch |e| return abandon(p, st, e);
}

/// Whether the frame of `h` can be read for a decoder: its size taken,
/// a frame predicted from others not waiting for a key frame, its
/// references there, of its format and of a size it can be predicted
/// from (between half and sixteen times its own).
fn check(p: *const Parser, st: *const State, h: *const av1.Av1FrameHeader) Error!void {
    if ((h.upscaled_width + 15) / 16 > p.max_width_mbs or (h.frame_height + 15) / 16 > p.max_height_mbs) return error.Unsupported;
    // An intra-only frame with the decoder waiting is fine on its own,
    // though the frames after it may lack its references: read all the
    // same.
    if (h.frame_is_intra) return;
    if (st.need_key) return error.Corrupt;
    const seq = &st.seq;
    for (h.ref_frame_idx) |idx| {
        const slot = st.ref_slots[idx];
        if (slot == none) return error.Corrupt;
        const r = &st.pics[slot];
        if (r.bit_depth != seq.bit_depth or r.ss_x != seq.subsampling_x or r.ss_y != seq.subsampling_y or r.mono != seq.mono_chrome)
            return error.Corrupt;
        if (2 * h.frame_width < r.width or 2 * h.frame_height < r.height or
            h.frame_width > 16 * r.width or h.frame_height > 16 * r.height) return error.Corrupt;
    }
}

/// tile_group_obu (5.11.1) at `at` in unit `u`: which tiles it holds,
/// and the first of them said.
fn startGroup(p: *Parser, st: *State, u: []const u8, at: usize) Error!Step {
    const h = &st.header;
    var b: header.Bits = .{ .data = u[at..] };
    const num_tiles = h.tile_cols * h.tile_rows;
    var start: u32 = 0;
    var end: u32 = num_tiles - 1;
    if (num_tiles > 1 and b.flag()) {
        const bits = @as(u32, h.tile_cols_log2) + h.tile_rows_log2;
        start = b.f(bits);
        end = b.f(bits);
    }
    b.byteAlign();
    if (b.overrun() or start != st.next_tile or end < start or end >= num_tiles) return error.Corrupt;
    st.group_at = @intCast(at + (b.pos >> 3));
    st.group_end = end;
    st.in_group = true;
    return tiles(p, st, u);
}

/// The tile group's next tile said: its size from the bytes before it,
/// the last one's the rest of the OBU. The frame ends with its last.
fn tiles(p: *Parser, st: *State, u: []const u8) Error!Step {
    const h = &st.header;
    var at: usize = st.group_at;
    const tile = st.next_tile;
    var size: usize = u.len - at;
    if (tile != st.group_end) {
        if (size < h.tile_size_bytes) return error.Corrupt;
        var v: usize = 0;
        for (0..h.tile_size_bytes) |i| v |= @as(usize, u[at + i]) << @intCast(8 * i);
        at += h.tile_size_bytes;
        size = v + 1;
        if (size > u.len - at) return error.Corrupt;
    }
    st.slice = .{
        .unit = u.ptr + at,
        .unit_bytes = @intCast(size),
        .rbsp = u.ptr + at,
        .rbsp_bytes = @intCast(size),
        .tile = tile,
    };
    p.events.push(.{ .kind = vp.VPEV_SLICE, .slice = &st.slice });
    st.group_at = @intCast(at + size);
    st.next_tile = tile + 1;
    if (tile != st.group_end) return .again;
    st.in_group = false;
    if (tile == h.tile_cols * h.tile_rows - 1) finish(p, st);
    return .done;
}

/// The frame's last tile said: VPEV_DECODE, the reference slots it goes
/// into (7.20), held to be shown when it is, and the pictures nothing
/// holds now let go of - itself when nothing does.
fn finish(p: *Parser, st: *State) void {
    const h = &st.header;
    const seq = &st.seq;
    const slot = st.frame_slot;
    const pic = &st.pics[slot];
    p.events.push(.{ .kind = vp.VPEV_DECODE });
    for (0..8) |i| {
        if (h.refresh_frame_flags >> @intCast(i) & 1 == 0) continue;
        st.states[i] = .{
            .valid = true,
            .frame_id = h.current_frame_id,
            .frame_type = h.frame_type,
            .order_hint = h.order_hint,
            .upscaled_width = h.upscaled_width,
            .frame_width = h.frame_width,
            .frame_height = h.frame_height,
            .render_width = h.render_width,
            .render_height = h.render_height,
            .mi_cols = h.mi_cols,
            .mi_rows = h.mi_rows,
            .bit_depth = seq.bit_depth,
            .ss_x = seq.subsampling_x,
            .ss_y = seq.subsampling_y,
            .showable = h.showable_frame,
            .saved_order_hints = h.order_hints,
            .gm_params = h.gm_params,
            .lf_ref_deltas = h.loop_filter_ref_deltas,
            .lf_mode_deltas = h.loop_filter_mode_deltas,
            .feature_enabled = h.feature_enabled,
            .feature_data = h.feature_data,
            .grain = h.film_grain,
        };
        const old = st.ref_slots[i];
        if (old != none) st.pics[old].refs -= 1;
        st.ref_slots[i] = slot;
        pic.refs += 1;
    }
    st.in_frame = false;
    st.frame_slot = none;
    if (h.show_frame) {
        st.shown_header = h.*;
        st.shown_picture = st.picture;
        st.shown_picture.av1 = &st.shown_header;
        show(st, slot, p.packet.time);
    }
    freeUnheld(p, st);
}

/// A frame that shows the picture in a reference slot again: held to be
/// shown with the header `h` - the picture's type and the film grain it
/// was stored with - unless the decoder waits for a key frame. A key
/// frame shown again goes into every slot, what it keeps with it (7.21).
fn showExisting(p: *Parser, st: *State, h: *const av1.Av1FrameHeader) Error!Step {
    const idx = h.frame_to_show_map_idx;
    const slot = st.ref_slots[idx];
    if (slot == none) {
        st.need_key = true;
        return error.Corrupt;
    }
    if (h.frame_type == av1.KEY_FRAME) {
        const state = st.states[idx];
        for (0..8) |i| {
            if (i == idx) continue;
            st.states[i] = state;
            const old = st.ref_slots[i];
            if (old != none) st.pics[old].refs -= 1;
            st.ref_slots[i] = slot;
            st.pics[slot].refs += 1;
        }
        st.need_key = false;
    } else if (st.need_key) return .done;
    st.shown_header = h.*;
    st.shown_picture = .{
        .slot = slot,
        .idr = h.frame_type == av1.KEY_FRAME,
        .reference = h.frame_type == av1.KEY_FRAME,
        .uid = st.pics[slot].uid,
        .time = p.packet.time,
        .av1 = &st.shown_header,
        .av1_sequence = &st.seq,
        .peak_nits = p.light.settle(),
    };
    show(st, slot, p.packet.time);
    freeUnheld(p, st);
    return .done;
}

/// The picture in `slot` to be shown at `time` when its temporal unit
/// ends, in place of one the unit showed before it.
fn show(st: *State, slot: u8, time: i64) void {
    if (st.show_slot != none and st.show_slot != slot) st.pics[st.show_slot].showing = false;
    st.show_slot = slot;
    st.pics[slot].showing = true;
    st.show_time = time;
}

/// The temporal unit ended: a frame without its last tile passed over
/// (error.Corrupt, once the rest is said), and the frame it shows
/// VPEV_SHOW.
fn endUnit(p: *Parser, st: *State) Error!void {
    const broken = st.in_frame;
    if (broken) abandonFrame(p, st);
    if (st.show_slot != none) {
        const slot = st.show_slot;
        p.events.push(.{ .kind = vp.VPEV_SHOW, .slot = slot, .time = st.show_time, .picture = &st.shown_picture });
        st.pics[slot].showing = false;
        st.show_slot = none;
        freeUnheld(p, st);
    }
    if (broken) return error.Corrupt;
}

/// The frame whose tiles came passed over: its picture let go of, and a
/// key frame waited for.
fn abandonFrame(p: *Parser, st: *State) void {
    st.in_frame = false;
    st.in_group = false;
    st.frame_slot = none;
    st.need_key = true;
    freeUnheld(p, st);
}

fn abandon(p: *Parser, st: *State, e: Error) Error {
    abandonFrame(p, st);
    return e;
}

/// VPEV_SEQUENCE where the frame's size or format is not what the
/// sequence said, or the sequence header's largest frame changed.
fn tell(p: *Parser, st: *State, h: *const av1.Av1FrameHeader) void {
    const s = &st.seq;
    const chroma: u8 = if (s.mono_chrome) 0 else if (s.subsampling_x == 1 and s.subsampling_y == 1) 1 else if (s.subsampling_x == 1) 2 else 3;
    var seq: vp.VideoSequence = .{
        .codec = vp.VPCODEC_AV1,
        .coded_width = (h.upscaled_width + 7) & ~@as(u32, 7),
        .coded_height = (h.frame_height + 7) & ~@as(u32, 7),
        .width = h.upscaled_width,
        .height = h.frame_height,
        .dpb_frames = 8,
        .reorder = 0,
        .slots = st.count,
        .bit_depth_luma = s.bit_depth,
        .bit_depth_chroma = s.bit_depth,
        .chroma_format = chroma,
        .full_range = s.color_range,
        .matrix = s.matrix_coefficients,
        .colour_primaries = s.color_primaries,
        .transfer = s.transfer_characteristics,
        .profile = s.seq_profile,
        .level = s.seq_level_idx[0],
        .av1 = s,
    };
    // A picture lasts num_ticks_per_picture display ticks, each
    // num_units_in_display_tick of time_scale's.
    if (s.timing_info_present_flag and s.equal_picture_interval) {
        const den = @as(u64, s.num_units_in_display_tick) * s.num_ticks_per_picture;
        if (den != 0 and den <= 0xFFFF_FFFF and s.time_scale != 0) {
            seq.rate_num = s.time_scale;
            seq.rate_den = @intCast(den);
        }
    }
    const q = &st.sequence;
    if (st.told and q.width == seq.width and q.height == seq.height and q.bit_depth_luma == seq.bit_depth_luma and
        q.chroma_format == seq.chroma_format and q.full_range == seq.full_range and q.matrix == seq.matrix and
        q.profile == seq.profile and st.told_max_width == s.max_frame_width and st.told_max_height == s.max_frame_height) return;
    st.sequence = seq;
    st.told_max_width = s.max_frame_width;
    st.told_max_height = s.max_frame_height;
    st.told = true;
    p.events.push(.{ .kind = vp.VPEV_SEQUENCE, .sequence = &st.sequence });
}

fn slotOf(st: *const State, s: *const Pic) u8 {
    return @intCast((@intFromPtr(s) - @intFromPtr(&st.pics[0])) / @sizeOf(Pic));
}

/// A slot with nothing in it handed out: lent, with a new number. Null
/// when every slot is held.
fn take(st: *State) ?*Pic {
    for (st.pics[0..st.count]) |*s| {
        if (s.in_use or s.lent) continue;
        s.* = .{ .in_use = true, .lent = true, .uid = st.uid_next };
        st.uid_next +%= 1;
        return s;
    }
    return null;
}

/// Every picture of the stream's that no reference slot holds, that is
/// not being decoded and not to be shown, let go of, a VPEV_FREE for
/// each.
fn freeUnheld(p: *Parser, st: *State) void {
    for (st.pics[0..st.count], 0..) |*s, slot| {
        if (!s.in_use or s.refs != 0 or s.showing) continue;
        if (st.in_frame and slot == st.frame_slot) continue;
        s.in_use = false;
        p.events.push(.{ .kind = vp.VPEV_FREE, .slot = @intCast(slot) });
    }
}
