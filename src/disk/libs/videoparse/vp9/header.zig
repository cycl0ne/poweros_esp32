// SPDX-License-Identifier: MIT
//! A VP9 frame's uncompressed header (6.2) read in plain bits: the
//! frame's type and size, its references, the loop filter, the quantiser,
//! the segmentation and the tiles, with what stays from frame to frame -
//! the colour, the loop filter's deltas, the segmentation - kept in a
//! `Persist` the header changes as it says. The compressed header after
//! it is the decoder's.
//!
//! What a reset of past independence clears (setup_past_independence:
//! a key frame, an intra-only or an error resilient one) is cleared as
//! the reference decoder clears it - the segmentation's features, the
//! loop filter's deltas, the references' sign biases - before the rest of
//! the header is read over it.

const sdk = @import("sdk");
const v9 = sdk.videoparse.vp9;
const Error = @import("h264sets").bits.Error;

/// Bits read from the most significant on; zeros past the end.
pub const Bits = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn bit(r: *Bits) u1 {
        const i = r.pos >> 3;
        if (i >= r.data.len) {
            r.pos += 1;
            return 0;
        }
        const b: u1 = @intCast((r.data[i] >> @intCast(7 - (r.pos & 7))) & 1);
        r.pos += 1;
        return b;
    }
    pub fn flag(r: *Bits) bool {
        return r.bit() == 1;
    }
    pub fn f(r: *Bits, n: u6) u32 {
        var v: u32 = 0;
        for (0..n) |_| v = (v << 1) | r.bit();
        return v;
    }
    /// An `n`-bit magnitude, then its sign.
    pub fn s(r: *Bits, n: u6) i32 {
        const v: i32 = @intCast(r.f(n));
        return if (r.flag()) -v else v;
    }
    pub fn overrun(r: *const Bits) bool {
        return r.pos > r.data.len * 8;
    }
};

/// The colour as the last key frame or intra-only frame set it.
pub const Color = struct {
    bit_depth: u8 = 8,
    color_space: u8 = v9.CS_UNKNOWN,
    color_range: bool = false,
    ss_x: u8 = 1,
    ss_y: u8 = 1,
};

/// What stays from frame to frame that the header reads or changes.
pub const Persist = struct {
    seg: v9.Vp9Segmentation = .{},
    /// The loop filter's deltas: whether they are on and their values.
    delta_enabled: bool = false,
    ref_deltas: [4]i8 = .{ 1, 0, -1, -1 },
    mode_deltas: [2]i8 = .{ 0, 0 },
    color: Color = .{},
};

/// The size of the frame in each reference slot, 0 where it is empty.
pub const RefSizes = struct {
    width: [8]u32 = @splat(0),
    height: [8]u32 = @splat(0),
};

/// literal_to_type: the header's literal as FILTER_*.
const literal_to_type = [4]u8{ v9.FILTER_EIGHTTAP_SMOOTH, v9.FILTER_EIGHTTAP, v9.FILTER_EIGHTTAP_SHARP, v9.FILTER_BILINEAR };

/// The bits of each segmentation feature's value, and whether it has a
/// sign.
const segmentation_feature_bits = [4]u6{ 8, 6, 2, 0 };
const segmentation_feature_signed = [4]bool{ true, true, false, false };

fn syncCode(r: *Bits) Error!void {
    if (r.f(8) != 0x49 or r.f(8) != 0x83 or r.f(8) != 0x42) return error.Corrupt;
}

fn colorConfig(r: *Bits, profile: u8, c: *Color) Error!void {
    c.bit_depth = if (profile >= 2) (if (r.flag()) 12 else 10) else 8;
    c.color_space = @intCast(r.f(3));
    if (c.color_space != v9.CS_RGB) {
        c.color_range = r.flag();
        if (profile == 1 or profile == 3) {
            c.ss_x = r.bit();
            c.ss_y = r.bit();
            if (r.flag()) return error.Unsupported;
            // 4:2:0 is profile 0's and 2's.
            if (c.ss_x == 1 and c.ss_y == 1) return error.Corrupt;
        } else {
            c.ss_x = 1;
            c.ss_y = 1;
        }
    } else {
        c.color_range = true;
        if (profile == 1 or profile == 3) {
            c.ss_x = 0;
            c.ss_y = 0;
            if (r.flag()) return error.Unsupported;
        } else return error.Corrupt;
    }
}

fn frameSize(r: *Bits, h: *v9.Vp9Header) void {
    h.width = r.f(16) + 1;
    h.height = r.f(16) + 1;
}

fn renderSize(r: *Bits, h: *v9.Vp9Header) void {
    if (r.flag()) {
        h.render_width = r.f(16) + 1;
        h.render_height = r.f(16) + 1;
    } else {
        h.render_width = h.width;
        h.render_height = h.height;
    }
}

fn readDeltaQ(r: *Bits) i8 {
    return if (r.flag()) @intCast(r.s(4)) else 0;
}

fn readProb(r: *Bits) u8 {
    return if (r.flag()) @intCast(r.f(8)) else 255;
}

/// The uncompressed header of the frame `data` into `h`, the frames in
/// the reference slots of `refs`' sizes; `st` changed as it says. Of a
/// frame that only shows a reference, `h` holds that and its profile.
pub fn uncompressed(data: []const u8, st: *Persist, refs: *const RefSizes, h: *v9.Vp9Header) Error!void {
    var r: Bits = .{ .data = data };
    h.* = .{};
    if (r.f(2) != 2) return error.Corrupt;
    const low = r.bit();
    h.profile = (@as(u8, r.bit()) << 1) | low;
    if (h.profile == 3 and r.flag()) return error.Unsupported;
    h.show_existing_frame = r.flag();
    if (h.show_existing_frame) {
        h.frame_to_show_map_idx = @intCast(r.f(3));
        return;
    }
    h.frame_type = r.bit();
    h.show_frame = r.flag();
    h.error_resilient_mode = r.flag();
    if (h.frame_type == v9.KEY_FRAME) {
        try syncCode(&r);
        try colorConfig(&r, h.profile, &st.color);
        frameSize(&r, h);
        renderSize(&r, h);
        h.refresh_frame_flags = 0xFF;
        h.frame_is_intra = true;
    } else {
        h.intra_only = if (h.show_frame) false else r.flag();
        h.frame_is_intra = h.intra_only;
        h.reset_frame_context = if (h.error_resilient_mode) 0 else @intCast(r.f(2));
        if (h.intra_only) {
            try syncCode(&r);
            if (h.profile > 0) {
                try colorConfig(&r, h.profile, &st.color);
            } else {
                st.color = .{ .color_space = v9.CS_BT_601 };
            }
            h.refresh_frame_flags = @intCast(r.f(8));
            frameSize(&r, h);
            renderSize(&r, h);
        } else {
            h.refresh_frame_flags = @intCast(r.f(8));
            for (0..3) |i| {
                h.ref_frame_idx[i] = @intCast(r.f(3));
                h.ref_frame_sign_bias[1 + i] = r.flag();
            }
            var found = false;
            for (h.ref_frame_idx) |idx| {
                if (r.flag()) {
                    h.width = refs.width[idx];
                    h.height = refs.height[idx];
                    found = true;
                    break;
                }
            }
            if (!found) frameSize(&r, h);
            if (h.width == 0) return error.Corrupt;
            renderSize(&r, h);
            h.allow_high_precision_mv = r.flag();
            h.interp_filter = if (r.flag()) v9.FILTER_SWITCHABLE else literal_to_type[r.f(2)];
        }
    }
    if (!h.error_resilient_mode) {
        h.refresh_frame_context = r.flag();
        h.frame_parallel_decoding_mode = r.flag();
    } else {
        h.refresh_frame_context = false;
        h.frame_parallel_decoding_mode = true;
    }
    h.frame_context_idx = @intCast(r.f(2));
    if (h.frame_is_intra or h.error_resilient_mode) {
        // setup_past_independence: what the rest of this header reads
        // over; the decoder resets the probabilities and the segment map.
        h.reset_past = true;
        st.seg.feature_enabled = @splat(@splat(false));
        st.seg.feature_data = @splat(@splat(0));
        st.seg.abs_delta = false;
        st.delta_enabled = true;
        st.ref_deltas = .{ 1, 0, -1, -1 };
        st.mode_deltas = .{ 0, 0 };
        h.ref_frame_sign_bias = @splat(false);
    }
    // Loop filter (6.2.8).
    h.loop_filter.level = @intCast(r.f(6));
    h.loop_filter.sharpness = @intCast(r.f(3));
    st.delta_enabled = r.flag();
    if (st.delta_enabled) {
        h.loop_filter.delta_update = r.flag();
        if (h.loop_filter.delta_update) {
            for (&st.ref_deltas) |*d| {
                if (r.flag()) d.* = @intCast(r.s(6));
            }
            for (&st.mode_deltas) |*d| {
                if (r.flag()) d.* = @intCast(r.s(6));
            }
        }
    }
    h.loop_filter.delta_enabled = st.delta_enabled;
    h.loop_filter.ref_deltas = st.ref_deltas;
    h.loop_filter.mode_deltas = st.mode_deltas;
    // Quantisation (6.2.9).
    h.base_q_idx = @intCast(r.f(8));
    h.delta_q_y_dc = readDeltaQ(&r);
    h.delta_q_uv_dc = readDeltaQ(&r);
    h.delta_q_uv_ac = readDeltaQ(&r);
    h.lossless = h.base_q_idx == 0 and h.delta_q_y_dc == 0 and h.delta_q_uv_dc == 0 and h.delta_q_uv_ac == 0;
    // Segmentation (6.2.11).
    const sg = &st.seg;
    sg.update_map = false;
    sg.temporal_update = false;
    sg.update_data = false;
    sg.enabled = r.flag();
    if (sg.enabled) {
        sg.update_map = r.flag();
        if (sg.update_map) {
            for (&sg.tree_probs) |*p| p.* = readProb(&r);
            sg.temporal_update = r.flag();
            for (&sg.pred_probs) |*p| p.* = if (sg.temporal_update) readProb(&r) else 255;
        }
        sg.update_data = r.flag();
        if (sg.update_data) {
            sg.abs_delta = r.flag();
            for (0..8) |i| {
                for (0..4) |j| {
                    var v: i16 = 0;
                    sg.feature_enabled[i][j] = r.flag();
                    if (sg.feature_enabled[i][j]) {
                        v = @intCast(r.f(segmentation_feature_bits[j]));
                        if (segmentation_feature_signed[j] and r.flag()) v = -v;
                    }
                    sg.feature_data[i][j] = v;
                }
            }
        }
    }
    h.segmentation = sg.*;
    // Tiles (6.2.13).
    const sb_cols = (((h.width + 7) >> 3) + 7) >> 3;
    var min_log2: u8 = 0;
    while ((@as(u32, 64) << @intCast(min_log2)) < sb_cols) min_log2 += 1;
    var max_log2: u8 = 1;
    while ((sb_cols >> @intCast(max_log2)) >= 4) max_log2 += 1;
    max_log2 -= 1;
    h.tile_cols_log2 = min_log2;
    while (h.tile_cols_log2 < max_log2 and r.flag()) h.tile_cols_log2 += 1;
    h.tile_rows_log2 = r.bit();
    if (h.tile_rows_log2 == 1) h.tile_rows_log2 += r.bit();
    h.compressed_bytes = r.f(16);
    // The trailing bits (6.1.1).
    h.uncompressed_bytes = @intCast((r.pos + 7) >> 3);
    if (r.overrun() or h.uncompressed_bytes > data.len) return error.Corrupt;
    const c = st.color;
    h.bit_depth = c.bit_depth;
    h.color_space = c.color_space;
    h.color_range = c.color_range;
    h.subsampling_x = c.ss_x;
    h.subsampling_y = c.ss_y;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

/// Bits written from the most significant on, for headers made here.
const Writer = struct {
    bytes: [64]u8 = @splat(0),
    pos: usize = 0,

    fn put(w: *Writer, value: u32, n: u6) void {
        var i = n;
        while (i > 0) {
            i -= 1;
            if ((value >> @intCast(i)) & 1 != 0) w.bytes[w.pos >> 3] |= @as(u8, 0x80) >> @intCast(w.pos & 7);
            w.pos += 1;
        }
    }
};

test "a key frame's header: its size, colour, filter, quantiser and segmentation, and the deltas it keeps" {
    var w: Writer = .{};
    w.put(2, 2); // frame marker
    w.put(0, 2); // profile 0
    w.put(0, 1); // show_existing_frame
    w.put(0, 1); // key frame
    w.put(1, 1); // show_frame
    w.put(0, 1); // error_resilient_mode
    w.put(0x498342, 24);
    w.put(2, 3); // BT.709
    w.put(1, 1); // the whole byte
    w.put(319, 16);
    w.put(179, 16);
    w.put(0, 1); // render size the same
    w.put(1, 1); // refresh_frame_context
    w.put(0, 1); // frame_parallel_decoding_mode
    w.put(2, 2); // frame_context_idx
    w.put(36, 6); // filter level
    w.put(3, 3); // sharpness
    w.put(1, 1); // deltas on
    w.put(1, 1); // and updated
    w.put(1, 1);
    w.put(5, 6);
    w.put(1, 1); // ref_deltas[0] = -5
    w.put(0, 3); // the others kept
    w.put(0, 2);
    w.put(60, 8); // base_q_idx
    w.put(0, 3); // no quantiser deltas
    w.put(1, 1); // segmentation on
    w.put(0, 1); // the map kept
    w.put(1, 1); // the data updated
    w.put(1, 1); // absolute
    for (0..8) |i| {
        w.put(@intFromBool(i == 2), 1); // ALT_Q of segment 2 only
        if (i == 2) w.put(17 << 1 | 1, 9); // -17
        w.put(0, 3);
    }
    // Tile columns: 320 is 5 superblocks, one column and no bit.
    w.put(0, 1); // one tile row
    w.put(123, 16); // compressed header's size
    var st: Persist = .{};
    var h: v9.Vp9Header = undefined;
    try uncompressed(&w.bytes, &st, &.{}, &h);
    try testing.expect(h.frame_is_intra and h.reset_past and h.show_frame and !h.use_prev_frame_mvs);
    try testing.expectEqual(@as(u32, 320), h.width);
    try testing.expectEqual(@as(u32, 180), h.render_height);
    try testing.expectEqual(@as(u8, 0xFF), h.refresh_frame_flags);
    try testing.expectEqual(v9.CS_BT_709, h.color_space);
    try testing.expect(h.color_range);
    try testing.expectEqual(@as(u8, 2), h.frame_context_idx);
    try testing.expectEqual(@as(u8, 36), h.loop_filter.level);
    try testing.expectEqual([4]i8{ -5, 0, -1, -1 }, h.loop_filter.ref_deltas);
    try testing.expectEqual(@as(u8, 60), h.base_q_idx);
    try testing.expect(h.segmentation.enabled and h.segmentation.abs_delta and h.segmentation.update_data);
    try testing.expectEqual(@as(i16, -17), h.segmentation.feature_data[2][v9.SEG_LVL_ALT_Q]);
    try testing.expectEqual(@as(u32, 123), h.compressed_bytes);
    try testing.expectEqual(@as(u32, @intCast((w.pos + 7) / 8)), h.uncompressed_bytes);
    // What stays: the deltas and the segmentation's features.
    try testing.expectEqual(@as(i8, -5), st.ref_deltas[0]);
    try testing.expect(st.seg.feature_enabled[2][0]);

    // A frame that only shows slot 5.
    var e: Writer = .{};
    e.put(2, 2);
    e.put(0, 2);
    e.put(1, 1);
    e.put(5, 3);
    try uncompressed(&e.bytes, &st, &.{}, &h);
    try testing.expect(h.show_existing_frame);
    try testing.expectEqual(@as(u8, 5), h.frame_to_show_map_idx);
}

test "an inter frame takes its size from a reference, and a header that is not one is refused" {
    var w: Writer = .{};
    w.put(2, 2);
    w.put(0, 2);
    w.put(0, 1);
    w.put(1, 1); // not a key frame
    w.put(1, 1); // shown
    w.put(0, 1);
    w.put(0, 2); // reset_frame_context
    w.put(0b0000_0001, 8); // refresh slot 0
    for ([_]u32{ 0, 3, 6 }) |idx| {
        w.put(idx, 3);
        w.put(@intFromBool(idx == 6), 1);
    }
    w.put(0, 1);
    w.put(1, 1); // the size of ref_frame_idx[1], slot 3
    w.put(0, 1); // render size the same
    w.put(1, 1); // allow_high_precision_mv
    w.put(0, 1);
    w.put(2, 2); // literal 2: sharp
    w.put(0, 2);
    w.put(0, 2);
    w.put(0, 6 + 3 + 1); // no filter, no deltas
    w.put(0, 8 + 3 + 1); // q 0, lossless, no segmentation
    w.put(0, 1); // one tile row
    w.put(7, 16);
    var refs: RefSizes = .{};
    refs.width[3] = 64;
    refs.height[3] = 48;
    var st: Persist = .{};
    var h: v9.Vp9Header = undefined;
    try uncompressed(&w.bytes, &st, &refs, &h);
    try testing.expect(!h.frame_is_intra and !h.reset_past);
    try testing.expectEqual(@as(u32, 64), h.width);
    try testing.expectEqual(@as(u32, 48), h.height);
    try testing.expectEqual([3]u8{ 0, 3, 6 }, h.ref_frame_idx);
    try testing.expect(h.ref_frame_sign_bias[v9.ALTREF_FRAME] and !h.ref_frame_sign_bias[v9.LAST_FRAME]);
    try testing.expectEqual(v9.FILTER_EIGHTTAP_SHARP, h.interp_filter);
    try testing.expect(h.allow_high_precision_mv and h.lossless);

    var bad = w;
    bad.bytes[0] &= 0x3F;
    try testing.expectError(error.Corrupt, uncompressed(&bad.bytes, &st, &refs, &h));
    // The size of an empty slot.
    try testing.expectError(error.Corrupt, uncompressed(&w.bytes, &st, &.{}, &h));
}
