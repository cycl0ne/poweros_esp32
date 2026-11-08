// SPDX-License-Identifier: MIT
//! VP9 read frame by frame into events: a packet cut into its frames,
//! each frame's uncompressed header read, a slot taken for it and its
//! events said, and the eight reference slots updated as its header says.
//!
//! **A packet** is a frame, or a superframe (B.3): its frames one after
//! the other and an index of their sizes at its end, between two copies
//! of a marker byte. Without an index the packet is one frame - or a
//! frame that only shows a reference, a byte or two, and what follows it
//! - and zero bytes before a frame belong to none.
//!
//! **A frame** is VPEV_SEQUENCE where its size or format is not what the
//! sequence said, VPEV_PICTURE - its slot, its header, the eight
//! reference slots' pictures as its references - VPEV_SLICE with its
//! bytes whole, VPEV_DECODE, VPEV_SHOW when it is shown, and VPEV_FREE
//! for each picture no reference slot holds any more, itself among them
//! when it went into none. A frame that only shows a reference is a
//! VPEV_SHOW of that reference's slot.
//!
//! **Waiting for a key frame**: at the start, after a seek and after a
//! frame that was not right, a frame that is not a key frame or an
//! intra-only one is passed over (VPERR_CORRUPT), and so is one whose
//! references are empty or of another format; a frame that resyncs drops
//! the references before it. What the decoder keeps from one frame to the
//! next for the vectors - the last frame's size, whether it was shown,
//! the last header's type and intra-only flag - is kept here as the
//! reference decoder keeps it, and said as the header's
//! `use_prev_frame_mvs`.
//!
//! **Waiting for a slot**: a frame that finds none free stops before
//! anything of it is kept (`Step.full`) and is read again once one was
//! given back.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const v9 = vp.vp9;
const header = @import("vp9header");
const Error = @import("h264sets").bits.Error;
const _parser = @import("../parser/_parser.zig");
const Parser = _parser.Parser;
const Step = _parser.Step;

/// Eight reference slots hold eight pictures at most, and the frame being
/// decoded is one more; then the slots the caller keeps beyond them
/// (VPA_Slots, 32 at most).
pub const stream_pics = 9;
pub const max_pics = stream_pics + 32;

const none = vp.VP_NO_SLOT;

/// What is kept of a picture.
pub const Pic = struct {
    /// The stream's: in a reference slot, or being decoded.
    in_use: bool = false,
    /// The caller's: handed out, and not yet given back.
    lent: bool = false,
    /// A number never given twice.
    uid: u32 = 0,
    /// The reference slots that hold it.
    refs: u8 = 0,
    /// Its size and format, which a frame that refers to it is checked
    /// against.
    width: u32 = 0,
    height: u32 = 0,
    bit_depth: u8 = 8,
    ss_x: u8 = 1,
    ss_y: u8 = 1,
};

pub const State = struct {
    pics: [max_pics]Pic = @splat(.{}),
    /// The slots there are: the stream's and the caller's.
    count: u32 = stream_pics,
    uid_next: u32 = 1,
    /// The picture in each of the eight reference slots, by its slot.
    ref_slots: [8]u8 = @splat(none),
    persist: header.Persist = .{},
    /// Until a key frame or an intra-only one.
    need_resync: bool = true,
    /// The last header read's frame type, and the intra-only flag of the
    /// last one that was not a key frame.
    last_type: u8 = v9.KEY_FRAME,
    last_intra_only: bool = false,
    /// The last frame handed out: shown or not, and its size.
    last_show_frame: bool = false,
    last_width: u32 = 0,
    last_height: u32 = 0,
    /// The sequence as it was last said; `told` once it was.
    sequence: vp.VideoSequence = .{},
    told: bool = false,
    /// The packet has a superframe index: its frames' ends are its.
    indexed: bool = false,
    /// What the events point at: each picture's, and its header, by its
    /// slot; the frame's slice.
    pictures: [max_pics]vp.VideoPicture = @splat(.{}),
    headers: [max_pics]v9.Vp9Header = @splat(.{}),
    slice: vp.VideoSlice = .{},
};

/// A reading of VP9 for `p`, with nothing read; null without memory.
pub fn create(p: *Parser) ?*State {
    const memory = p.alloc(@sizeOf(State)) orelse return null;
    const st: *State = @ptrCast(@alignCast(memory));
    st.* = .{ .count = stream_pics + p.extra_slots };
    return st;
}

pub fn destroy(p: *Parser, st: *State) void {
    p.free(@ptrCast(st));
}

/// Everything dropped, for a seek: the next frame must be a key frame or
/// an intra-only one. The slots the caller holds stay lent.
pub fn reset(st: *State) void {
    for (st.pics[0..st.count]) |*s| {
        s.in_use = false;
        s.refs = 0;
    }
    st.ref_slots = @splat(none);
    st.need_resync = true;
    // The sequence is said again with the next frame.
    st.told = false;
}

/// The stream ended: every picture let go of, a VPEV_FREE for each.
pub fn flush(p: *Parser, st: *State) Error!Step {
    st.ref_slots = @splat(none);
    for (st.pics[0..st.count]) |*s| s.refs = 0;
    freeUnheld(p, st);
    st.need_resync = true;
    return .done;
}

/// The slot `slot` the caller's no more.
pub fn unlend(st: *State, slot: u32) void {
    if (slot < st.count) st.pics[slot].lent = false;
}

/// The next frame of the packet, from `p.at` on: by the superframe index
/// at its end, or the rest of it. Null at the packet's end.
pub fn peek(p: *Parser, st: *State) error{Corrupt}!?[]const u8 {
    const d = p.bytes();
    var at: usize = p.at;
    st.indexed = false;
    if (d.len != 0) {
        const marker = d[d.len - 1];
        if (marker & 0xE0 == 0xC0) {
            const frames: usize = (marker & 7) + 1;
            const mag: usize = ((marker >> 3) & 3) + 1;
            const index = 2 + mag * frames;
            if (d.len >= index and d[d.len - index] == marker) {
                st.indexed = true;
                const end = d.len - index;
                var sizes = d[end + 1 ..];
                var start: usize = 0;
                for (0..frames) |_| {
                    var len: usize = 0;
                    for (0..mag) |i| len |= @as(usize, sizes[i]) << @intCast(8 * i);
                    sizes = sizes[mag..];
                    if (len > end - start) return error.Corrupt;
                    if (start >= at and len != 0) {
                        p.at = @intCast(start);
                        p.unit_end = @intCast(start + len);
                        return d[start..][0..len];
                    }
                    start += len;
                }
                p.at = @intCast(d.len);
                return null;
            }
        }
    }
    while (at < d.len and d[at] == 0) at += 1;
    if (at >= d.len) {
        p.at = @intCast(d.len);
        return null;
    }
    p.at = @intCast(at);
    p.unit_end = @intCast(d.len);
    return d[at..];
}

/// The sizes of the pictures in the reference slots.
fn refSizes(st: *const State) header.RefSizes {
    var sizes: header.RefSizes = .{};
    for (st.ref_slots, 0..) |slot, i| {
        if (slot == none) continue;
        sizes.width[i] = st.pics[slot].width;
        sizes.height[i] = st.pics[slot].height;
    }
    return sizes;
}

/// One frame `u` of the packet.
pub fn unit(p: *Parser, st: *State, u: []const u8) Error!Step {
    // Read over a copy of what stays, kept once the frame is: a frame
    // that waits for a slot is read again as it was.
    var persist = st.persist;
    var h: v9.Vp9Header = undefined;
    const sizes = refSizes(st);
    header.uncompressed(u, &persist, &sizes, &h) catch |e| {
        st.need_resync = true;
        return e;
    };
    if (h.show_existing_frame) return showExisting(p, st, u, &h);

    // What the vectors of the frame before it are read by.
    h.use_prev_frame_mvs = !h.error_resilient_mode and h.width == st.last_width and h.height == st.last_height and
        !st.last_intra_only and st.last_show_frame and st.last_type != v9.KEY_FRAME;
    check(p, st, &h, u.len) catch |e| {
        keep(st, &h, &persist);
        st.need_resync = true;
        return e;
    };
    if (h.frame_is_intra and st.need_resync) {
        // The references before it are gone; read again after a wait for
        // a slot, the frame finds none.
        st.ref_slots = @splat(none);
        for (st.pics[0..st.count]) |*s| s.refs = 0;
        freeUnheld(p, st);
        st.need_resync = false;
    }
    const pic = take(st) orelse return .full;
    keep(st, &h, &persist);
    tell(p, st, &h);
    const slot = slotOf(st, pic);
    pic.width = h.width;
    pic.height = h.height;
    pic.bit_depth = h.bit_depth;
    pic.ss_x = h.subsampling_x;
    pic.ss_y = h.subsampling_y;

    st.headers[slot] = h;
    const vpic = &st.pictures[slot];
    vpic.* = .{
        .slot = slot,
        .idr = h.frame_type == v9.KEY_FRAME,
        .reference = h.refresh_frame_flags != 0,
        .ref_count = 8,
        .uid = pic.uid,
        .time = p.packet.time,
        .vp9 = &st.headers[slot],
    };
    for (st.ref_slots, 0..) |ref, i| {
        vpic.refs[i] = .{ .slot = ref, .fields = 3, .uid = if (ref != none) st.pics[ref].uid else 0 };
    }
    p.events.push(.{ .kind = vp.VPEV_PICTURE, .slot = slot, .time = p.packet.time, .picture = vpic });
    st.slice = .{
        .unit = u.ptr,
        .unit_bytes = @intCast(u.len),
        .data_bit = h.uncompressed_bytes * 8,
        .rbsp = u.ptr,
        .rbsp_bytes = @intCast(u.len),
    };
    p.events.push(.{ .kind = vp.VPEV_SLICE, .slice = &st.slice });
    p.events.push(.{ .kind = vp.VPEV_DECODE });
    if (h.show_frame) p.events.push(.{ .kind = vp.VPEV_SHOW, .slot = slot, .time = p.packet.time });

    // The reference slots it goes into; the pictures none holds now let
    // go of, itself when it went into none.
    for (0..8) |i| {
        if (h.refresh_frame_flags >> @intCast(i) & 1 == 0) continue;
        const old = st.ref_slots[i];
        if (old != none) st.pics[old].refs -= 1;
        st.ref_slots[i] = slot;
        pic.refs += 1;
    }
    freeUnheld(p, st);
    st.last_show_frame = h.show_frame;
    st.last_width = h.width;
    st.last_height = h.height;
    return .done;
}

/// Whether the frame of `h`, `bytes` long, can be read for a decoder: its
/// size taken, its references there and of its format, its headers
/// within it.
fn check(p: *const Parser, st: *const State, h: *const v9.Vp9Header, bytes: usize) Error!void {
    if ((h.width + 15) / 16 > p.max_width_mbs or (h.height + 15) / 16 > p.max_height_mbs) return error.Unsupported;
    if (!h.frame_is_intra) {
        if (st.need_resync) return error.Corrupt;
        for (h.ref_frame_idx) |idx| {
            const slot = st.ref_slots[idx];
            if (slot == none) return error.Corrupt;
            const r = &st.pics[slot];
            if (r.bit_depth != h.bit_depth or r.ss_x != h.subsampling_x or r.ss_y != h.subsampling_y) return error.Corrupt;
        }
    }
    if (h.compressed_bytes == 0 or h.compressed_bytes > bytes - h.uncompressed_bytes) return error.Corrupt;
}

/// What the frame's header changed kept, and what the next frame's
/// vectors depend on of it.
fn keep(st: *State, h: *const v9.Vp9Header, persist: *const header.Persist) void {
    st.persist = persist.*;
    st.last_type = h.frame_type;
    if (h.frame_type != v9.KEY_FRAME) st.last_intra_only = h.intra_only;
}

/// A frame that only shows the picture in a reference slot: VPEV_SHOW of
/// it, unless the decoder waits for a key frame. A packet without an
/// index goes on after its byte or two.
fn showExisting(p: *Parser, st: *State, u: []const u8, h: *const v9.Vp9Header) Error!Step {
    if (!st.indexed) {
        const start = @intFromPtr(u.ptr) - @intFromPtr(p.packet.data.?);
        p.unit_end = @intCast(start + @as(usize, if (h.profile <= 2) 1 else 2));
    }
    const slot = st.ref_slots[h.frame_to_show_map_idx];
    if (slot == none) {
        st.need_resync = true;
        return error.Corrupt;
    }
    if (!st.need_resync) p.events.push(.{ .kind = vp.VPEV_SHOW, .slot = slot, .time = p.packet.time });
    return .done;
}

/// VPEV_SEQUENCE where the frame's size or format is not what the
/// sequence said.
fn tell(p: *Parser, st: *State, h: *const v9.Vp9Header) void {
    const chroma: u8 = if (h.subsampling_x == 1 and h.subsampling_y == 1) 1 else if (h.subsampling_x == 1) 2 else if (h.subsampling_y == 1) 4 else 3;
    const seq: vp.VideoSequence = .{
        .codec = vp.VPCODEC_VP9,
        .coded_width = (h.width + 7) & ~@as(u32, 7),
        .coded_height = (h.height + 7) & ~@as(u32, 7),
        .width = h.width,
        .height = h.height,
        .dpb_frames = 8,
        .reorder = 0,
        .slots = st.count,
        .bit_depth_luma = h.bit_depth,
        .bit_depth_chroma = h.bit_depth,
        .chroma_format = chroma,
        .full_range = h.color_range,
        .matrix = matrixOf(h.color_space),
        .profile = h.profile,
    };
    const q = &st.sequence;
    if (st.told and q.width == seq.width and q.height == seq.height and q.bit_depth_luma == seq.bit_depth_luma and
        q.chroma_format == seq.chroma_format and q.full_range == seq.full_range and q.matrix == seq.matrix and
        q.profile == seq.profile) return;
    st.sequence = seq;
    st.told = true;
    p.events.push(.{ .kind = vp.VPEV_SEQUENCE, .sequence = &st.sequence });
}

/// A colour space as the VUI's matrix_coefficients numbers it.
fn matrixOf(color_space: u8) u8 {
    return switch (color_space) {
        v9.CS_BT_601 => 5,
        v9.CS_BT_709 => 1,
        v9.CS_SMPTE_170 => 6,
        v9.CS_SMPTE_240 => 7,
        v9.CS_BT_2020 => 9,
        v9.CS_RGB => 0,
        else => 2,
    };
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

/// Every picture of the stream's that no reference slot holds let go of,
/// a VPEV_FREE for each.
fn freeUnheld(p: *Parser, st: *State) void {
    for (st.pics[0..st.count], 0..) |*s, slot| {
        if (!s.in_use or s.refs != 0) continue;
        s.in_use = false;
        p.events.push(.{ .kind = vp.VPEV_FREE, .slot = @intCast(slot) });
    }
}
