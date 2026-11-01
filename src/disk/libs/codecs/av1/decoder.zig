// SPDX-License-Identifier: MIT
//! The AV1 decoder (AV1 Bitstream & Decoding Process Specification,
//! 2019): temporal units in, the frames to show out.
//!
//! A temporal unit is OBUs (5.3): the sequence header, which names the
//! profile, the depth and format of the samples and the tools the frames
//! may use; and frames, each its header (5.9) and its tiles, in tile
//! groups. The decoder reads each tile as its tile group comes
//! (parse.zig) into the frame's blocks and coefficients; once the last is
//! read, the frame is put together a superblock at a time (recon.zig),
//! then deblocked, CDEF filtered, upscaled when it was coded narrower
//! and loop restored (post.zig). The frame goes into the
//! reference slots its header names, of eight, with what the frames
//! after it read of it: its CDFs, its motion field and segment map, its
//! size and settings. A frame shown with film grain is shown as a copy
//! with the grain added (grain.zig).
//!
//! Of a temporal unit with several frames shown - the layers of a
//! scalable stream - the last is handed out, as libaom does by default.

const common = @import("common.zig");
const header = @import("header.zig");
const cdf = @import("cdf.zig");
const parse = @import("parse.zig");
const recon = @import("recon.zig");
const post = @import("post.zig");
const grain = @import("grain.zig");
const Env = common.Env;
const Error = common.Error;
const Frame = common.Frame;
const Cores = common.Cores;
const Cdfs = cdf.Cdfs;

const max_out = 4;
/// The slots', the frame decoded, the narrower one of a frame coded
/// with superres, those waiting to be shown and their film grain
/// copies.
const max_frames = 8 + 2 + 2 * max_out;

pub const Shown = struct { frame: *const Frame, time: i64 };

pub const Decoder = struct {
    env: Env,
    /// The size and depth of the last frame shown; 0 before the first.
    width: u32 = 0,
    height: u32 = 0,
    bit_depth: u8 = 0,
    frames: [max_frames]Frame = @splat(.{}),
    slots: [8]?*Frame = @splat(null),
    /// What each slot keeps for the headers after it, and its CDFs.
    states: [8]header.RefState = @splat(.{}),
    slot_cdfs: [8]Cdfs = undefined,
    seq: header.Sequence = .{},
    have_seq: bool = false,
    carry: header.Carry = .{},
    /// The frame whose tiles are read: its header, CDFs, and the CDFs
    /// of the tile they adapt to.
    h: header.Frame = .{},
    in_frame: bool = false,
    next_tile: u32 = 0,
    cdfs: Cdfs = undefined,
    saved: Cdfs = undefined,
    out: parse.Out = .{},
    ps: parse.Parse,
    ref_info: [8]parse.RefInfo = @splat(.{}),
    /// The frame decoded, and the narrower one it is coded in with
    /// superres (else the same).
    cur: ?*Frame = null,
    coded: ?*Frame = null,
    rc: recon.Recon = .{},
    post: post.Scratch = .{},
    film: grain.Scratch = .{},
    /// Until a key frame: at the start, after an error and a reset.
    need_key: bool = true,
    /// The temporal unit's frame to show.
    shown: ?*Frame = null,

    // --- the frames to show ---
    queue: [max_out]Shown = undefined,
    out_first: u32 = 0,
    out_count: u32 = 0,
    flushing: bool = false,
    cores: ?*const Cores = null,

    pub fn create(env: Env) ?*Decoder {
        const bytes = env.alloc(env.ctx, @sizeOf(Decoder), true) orelse return null;
        const dec: *Decoder = @ptrCast(@alignCast(bytes));
        dec.* = .{ .env = env, .ps = parse.Parse.init(env) };
        return dec;
    }

    /// The other cores (unused yet: every frame is decoded on the
    /// caller's).
    pub fn useCores(dec: *Decoder, cores: *const Cores) void {
        dec.cores = cores;
    }

    pub fn destroy(dec: *Decoder) void {
        const env = dec.env;
        for (&dec.frames) |*f| freeFrameMemory(env, f);
        dec.out.free(env);
        dec.ps.deinit();
        dec.rc.deinit(env);
        dec.post.deinit(env);
        dec.film.deinit(env);
        env.free(env.ctx, @ptrCast(dec), @sizeOf(Decoder));
    }

    /// Everything dropped, for a seek: the next frame decoded is a key
    /// frame.
    pub fn reset(dec: *Decoder) void {
        for (0..8) |i| dec.setSlot(i, null);
        dec.states = @splat(.{});
        while (dec.out_count != 0) dec.release();
        dec.flushing = false;
        dec.need_key = true;
        dec.in_frame = false;
    }

    /// The next frame to show, or null; valid until `release`.
    pub fn next(dec: *Decoder) ?Shown {
        if (dec.out_count == 0) return null;
        return dec.queue[dec.out_first];
    }

    pub fn release(dec: *Decoder) void {
        if (dec.out_count == 0) return;
        const f: *Frame = @constCast(dec.queue[dec.out_first].frame);
        f.queued -= 1;
        dec.out_first = (dec.out_first + 1) % max_out;
        dec.out_count -= 1;
    }

    /// The end of the stream: every frame decoded is handed out.
    pub fn flush(dec: *Decoder) void {
        dec.flushing = true;
    }

    /// Temporal unit `data` decoded, shown at `time`: the frame it shows
    /// is handed out by `next`, unless `drop`.
    pub fn decodeFrame(dec: *Decoder, data: []const u8, time: i64, drop: bool) Error!void {
        dec.flushing = false;
        dec.shown = null;
        dec.unit(data) catch |e| {
            dec.need_key = true;
            dec.in_frame = false;
            if (dec.shown) |f| f.queued -= 1;
            return e;
        };
        if (dec.shown) |f| {
            if (drop) f.queued -= 1 else dec.enqueue(f, time);
        }
    }

    fn unit(dec: *Decoder, data: []const u8) Error!void {
        var at: usize = 0;
        while (at < data.len) {
            const o = try header.obu(data[at..]);
            at += o.len;
            switch (o.kind) {
                header.OBU_SEQUENCE_HEADER => {
                    const s = try header.sequence(o.payload);
                    if (dec.have_seq and !sameFormat(&dec.seq, &s)) dec.need_key = true;
                    dec.seq = s;
                    dec.have_seq = true;
                },
                header.OBU_TEMPORAL_DELIMITER => dec.in_frame = false,
                header.OBU_FRAME_HEADER, header.OBU_REDUNDANT_FRAME_HEADER, header.OBU_FRAME => {
                    if (!dec.have_seq) return error.Corrupt;
                    if (!dec.inOperatingPoint(&o)) continue;
                    if (dec.in_frame) {
                        // A copy of the header of the frame being read.
                        if (o.kind == header.OBU_FRAME) return error.Corrupt;
                        continue;
                    }
                    if (o.kind == header.OBU_REDUNDANT_FRAME_HEADER) continue;
                    var b: header.Bits = .{ .data = o.payload };
                    try dec.frameHeader(&b, o.temporal_id, o.spatial_id);
                    if (o.kind == header.OBU_FRAME and dec.in_frame) {
                        b.byteAlign();
                        if (b.overrun()) return error.Corrupt;
                        try dec.tileGroup(o.payload[b.pos >> 3 ..]);
                    }
                },
                header.OBU_TILE_GROUP => {
                    if (!dec.inOperatingPoint(&o)) continue;
                    if (!dec.in_frame) return error.Corrupt;
                    try dec.tileGroup(o.payload);
                },
                else => {},
            }
        }
    }

    fn inOperatingPoint(dec: *const Decoder, o: *const header.Obu) bool {
        const idc = dec.seq.idc;
        if (idc == 0 or !o.extension) return true;
        const in_t = (idc >> @intCast(o.temporal_id)) & 1 != 0;
        const in_s = (idc >> @intCast(o.spatial_id + 8)) & 1 != 0;
        return in_t and in_s;
    }

    fn sameFormat(a: *const header.Sequence, b: *const header.Sequence) bool {
        return a.bit_depth == b.bit_depth and a.mono == b.mono and a.ss_x == b.ss_x and a.ss_y == b.ss_y and
            a.max_frame_width == b.max_frame_width and a.max_frame_height == b.max_frame_height and
            a.use_128x128 == b.use_128x128;
    }

    fn frameHeader(dec: *Decoder, b: *header.Bits, temporal_id: u8, spatial_id: u8) Error!void {
        const seq = &dec.seq;
        var h = try header.frame(b, seq, &dec.states, &dec.carry, temporal_id, spatial_id);
        if (b.overrun()) return error.Corrupt;
        if (h.show_existing_frame) {
            const idx = h.frame_to_show_map_idx;
            const f = dec.slots[idx] orelse return error.Corrupt;
            if (h.frame_type == common.KEY_FRAME) {
                // The reference loading process, then every slot set to
                // it (7.21, 7.20).
                const st = dec.states[idx];
                for (0..8) |i| {
                    if (i == idx) continue;
                    dec.states[i] = st;
                    dec.slot_cdfs[i] = dec.slot_cdfs[idx];
                    dec.setSlot(i, f);
                }
                dec.need_key = false;
            } else if (dec.need_key) return;
            try dec.show(f, &h.grain);
            return;
        }
        if (h.frame_type == common.KEY_FRAME and h.show_frame) {
            dec.need_key = false;
        } else if (dec.need_key) {
            if (!h.intra) return error.Corrupt;
            // An intra-only frame with the decoder waiting: fine on its
            // own, but the frames after it lack its references; decoded
            // all the same, as libaom does.
        }
        dec.h = h;
        try dec.beginFrame();
        dec.in_frame = true;
        dec.next_tile = 0;
    }

    /// The frame set up: its references checked, its frames made, the
    /// CDFs and maps it starts from.
    fn beginFrame(dec: *Decoder) Error!void {
        const h = &dec.h;
        const seq = &dec.seq;
        const env = dec.env;
        // The references there, of the frame's format and of a size it
        // can be predicted from.
        if (!h.intra) {
            for (h.ref_frame_idx) |idx| {
                const r = dec.slots[idx] orelse return error.Corrupt;
                if (r.bit_depth != seq.bit_depth or r.ss_x != seq.ss_x or r.ss_y != seq.ss_y or r.mono != seq.mono) return error.Corrupt;
                if (2 * h.frame_width < r.width or 2 * h.frame_height < r.height or
                    h.frame_width > 16 * r.width or h.frame_height > 16 * r.height) return error.Corrupt;
            }
        }
        const cur = try dec.freeFrame(h.upscaled_width, h.frame_height);
        cur.refs += 1;
        defer cur.refs -= 1;
        var coded = cur;
        if (h.use_superres) {
            coded = try dec.freeFrame(h.frame_width, h.frame_height);
        }
        dec.cur = cur;
        dec.coded = coded;
        const n = h.mi_cols * h.mi_rows;
        const n8 = (h.mi_cols >> 1) * (h.mi_rows >> 1);
        if (cur.segs.len != n and !env.resize(u8, &cur.segs, n)) return error.NoMemory;
        if (cur.mvs.len != n8) {
            env.freeSlice(common.MfMv, cur.mvs);
            cur.mvs = &.{};
            cur.mvs = env.slice(common.MfMv, n8) orelse return error.NoMemory;
        }

        // The CDFs.
        if (h.primary_ref_frame == common.PRIMARY_REF_NONE) {
            dec.cdfs.initNonCoeff();
            dec.cdfs.initCoeff(h.base_q_idx);
        } else {
            const slot = h.ref_frame_idx[h.primary_ref_frame];
            if (dec.slots[slot] == null) return error.Corrupt;
            dec.cdfs = dec.slot_cdfs[slot];
            dec.cdfs.clearCounts();
        }

        // What the frame reads of its references.
        for (0..8) |i| {
            const f = dec.slots[i] orelse {
                dec.ref_info[i] = .{};
                continue;
            };
            const st = &dec.states[i];
            dec.ref_info[i] = .{
                .mvs = f.mvs,
                .segs = f.segs,
                .mi_cols = st.mi_cols,
                .mi_rows = st.mi_rows,
                .frame_type = st.frame_type,
                .order_hint = st.order_hint,
                .saved_order_hints = st.saved_order_hints,
                .upscaled_width = st.upscaled_width,
                .frame_height = st.frame_height,
            };
        }
        var prev_segs: []const u8 = &.{};
        if (h.primary_ref_frame != common.PRIMARY_REF_NONE and h.segmentation_enabled) {
            const ri = &dec.ref_info[h.ref_frame_idx[h.primary_ref_frame]];
            if (ri.mi_cols == h.mi_cols and ri.mi_rows == h.mi_rows and ri.segs.len == n) prev_segs = ri.segs;
        }
        try dec.ps.begin(&dec.out, seq, h, &dec.ref_info, cur.segs, prev_segs);
    }

    /// tile_group_obu (5.11.1).
    fn tileGroup(dec: *Decoder, data: []const u8) Error!void {
        const h = &dec.h;
        var b: header.Bits = .{ .data = data };
        const num_tiles = h.tile_cols * h.tile_rows;
        var start: u32 = 0;
        var end: u32 = num_tiles - 1;
        if (num_tiles > 1 and b.flag()) {
            const bits: u6 = @as(u6, h.tile_cols_log2) + h.tile_rows_log2;
            start = b.f(bits);
            end = b.f(bits);
        }
        b.byteAlign();
        if (b.overrun() or start != dec.next_tile or end < start or end >= num_tiles) return error.Corrupt;
        var at: usize = b.pos >> 3;
        var t = start;
        while (t <= end) : (t += 1) {
            var size: usize = data.len - at;
            if (t != end) {
                if (data.len - at < h.tile_size_bytes) return error.Corrupt;
                var v: usize = 0;
                for (0..h.tile_size_bytes) |i| v |= @as(usize, data[at + i]) << @intCast(8 * i);
                at += h.tile_size_bytes;
                size = v + 1;
                if (size > data.len - at) return error.Corrupt;
            }
            const keep = !h.disable_frame_end_update_cdf and t == h.context_update_tile_id;
            try dec.ps.tile(t, data[at..][0..size], &dec.cdfs, if (keep) &dec.saved else null);
            at += size;
        }
        dec.next_tile = end + 1;
        if (end == num_tiles - 1) {
            if (!h.disable_frame_end_update_cdf) dec.cdfs = dec.saved;
            dec.in_frame = false;
            try dec.endFrame();
        }
    }

    /// decode_frame_wrapup (7.4): the frame put together and filtered,
    /// what the frames after it read of it kept, the slots set.
    fn endFrame(dec: *Decoder) Error!void {
        const h = &dec.h;
        const seq = &dec.seq;
        const cur = dec.cur.?;
        const coded = dec.coded.?;
        coded.refs += 1;
        defer coded.refs -= 1;
        cur.refs += 1;
        defer cur.refs -= 1;

        // Put together.
        var refs: [8]?*const Frame = @splat(null);
        if (!h.intra) {
            for (0..7) |i| refs[i + 1] = dec.slots[h.ref_frame_idx[i]];
        }
        try dec.rc.frame(dec.env, seq, h, &dec.out, coded, refs);

        // Filtered (7.14 to 7.17).
        try post.frame(&dec.post, dec.env, seq, h, &dec.out, coded, cur);

        // The motion field (7.19) and the segment map kept.
        dec.storeMotionField(cur);
        if (h.segmentation_enabled and !h.segmentation_update_map) {
            if (dec.ps.prev_segs.len == cur.segs.len) {
                @memcpy(cur.segs, dec.ps.prev_segs);
            } else {
                @memset(cur.segs, 0);
            }
        }

        // The reference update process (7.20).
        for (0..8) |i| {
            if (h.refresh_frame_flags >> @intCast(i) & 1 == 0) continue;
            dec.states[i] = .{
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
                .ss_x = seq.ss_x,
                .ss_y = seq.ss_y,
                .showable = h.showable_frame,
                .saved_order_hints = h.order_hints,
                .gm_params = h.gm_params,
                .lf_ref_deltas = h.loop_filter_ref_deltas,
                .lf_mode_deltas = h.loop_filter_mode_deltas,
                .feature_enabled = h.feature_enabled,
                .feature_data = h.feature_data,
                .grain = h.grain,
            };
            dec.slot_cdfs[i] = dec.cdfs;
            dec.setSlot(i, cur);
        }
        if (h.show_frame) try dec.show(cur, &h.grain);
    }

    fn storeMotionField(dec: *Decoder, cur: *Frame) void {
        const h = &dec.h;
        const seq = &dec.seq;
        const out = &dec.out;
        const w8 = h.mi_cols >> 1;
        const h8 = h.mi_rows >> 1;
        const limit = (1 << 12) - 1;
        for (0..h8) |y8| {
            for (0..w8) |x8| {
                var m: common.MfMv = .{};
                const blk = out.block(@intCast(2 * y8 + 1), @intCast(2 * x8 + 1));
                for (0..2) |list| {
                    const r = blk.ref[list];
                    if (r <= common.INTRA_FRAME) continue;
                    if (seq.dist(h.order_hints[@intCast(r)], h.order_hint) >= 0) continue;
                    const mv = blk.mv[list];
                    if (@abs(mv.row) <= limit and @abs(mv.col) <= limit) m = .{ .mv = mv, .ref = r };
                }
                cur.mvs[y8 * w8 + x8] = m;
            }
        }
    }

    /// The output process: `f` handed out at the end of the temporal
    /// unit - with film grain `g`, as a copy with the grain added.
    fn show(dec: *Decoder, f: *Frame, g: *const header.Grain) Error!void {
        var shown = f;
        if (dec.seq.film_grain_params_present and g.apply_grain) {
            f.refs += 1;
            defer f.refs -= 1;
            const copy = try dec.freeFrame(f.width, f.height);
            try grain.apply(copy, f, g, &dec.film, dec.env);
            shown = copy;
        }
        if (dec.shown) |old| old.queued -= 1;
        shown.queued += 1;
        dec.shown = shown;
        dec.width = shown.width;
        dec.height = shown.height;
        dec.bit_depth = shown.bit_depth;
    }

    fn enqueue(dec: *Decoder, f: *Frame, time: i64) void {
        // `show` counted it once already.
        if (dec.out_count == max_out) dec.release();
        dec.queue[(dec.out_first + dec.out_count) % max_out] = .{ .frame = f, .time = time };
        dec.out_count += 1;
    }

    fn setSlot(dec: *Decoder, i: usize, f: ?*Frame) void {
        if (dec.slots[i]) |old| old.refs -= 1;
        dec.slots[i] = f;
        if (f) |new| new.refs += 1;
    }

    /// A frame no slot or queue holds, made for a `w` by `h` frame of the
    /// sequence's format.
    fn freeFrame(dec: *Decoder, w: u32, h: u32) Error!*Frame {
        const seq = &dec.seq;
        const alloc_w = (w + 127) & ~@as(u32, 127);
        const alloc_h = (h + 127) & ~@as(u32, 127);
        const bytes: u8 = if (seq.bit_depth > 8) 2 else 1;
        var spare: ?*Frame = null;
        for (&dec.frames) |*f| {
            if (f.refs != 0 or f.pinned != 0 or f.queued != 0) continue;
            if (f.memory.len != 0 and f.alloc_w == alloc_w and f.alloc_h == alloc_h and
                f.alloc_bytes == bytes and f.ss_x == seq.ss_x and f.ss_y == seq.ss_y)
            {
                spare = f;
                break;
            }
            if (spare == null) spare = f;
        }
        const f = spare orelse return error.NoMemory;
        if (!(f.memory.len != 0 and f.alloc_w == alloc_w and f.alloc_h == alloc_h and
            f.alloc_bytes == bytes and f.ss_x == seq.ss_x and f.ss_y == seq.ss_y))
        {
            const env = dec.env;
            freeFrameMemory(env, f);
            const luma: usize = @as(usize, alloc_w) * alloc_h;
            const cw = alloc_w >> seq.ss_x;
            const chroma: usize = @as(usize, cw) * (alloc_h >> seq.ss_y);
            const memory = env.slice(u8, (luma + 2 * chroma) * bytes) orelse return error.NoMemory;
            f.* = .{
                .planes = .{ memory.ptr, memory.ptr + luma * bytes, memory.ptr + (luma + chroma) * bytes },
                .stride = .{ alloc_w, cw, cw },
                .memory = memory,
                .ss_x = seq.ss_x,
                .ss_y = seq.ss_y,
                .alloc_w = alloc_w,
                .alloc_h = alloc_h,
                .alloc_bytes = bytes,
            };
        }
        f.width = w;
        f.height = h;
        f.mono = seq.mono;
        f.bit_depth = seq.bit_depth;
        f.primaries = seq.primaries;
        f.transfer = seq.transfer;
        f.matrix = seq.matrix;
        f.full_range = seq.full_range;
        return f;
    }
};

fn freeFrameMemory(env: Env, f: *Frame) void {
    env.freeSlice(u8, f.memory);
    env.freeSlice(common.MfMv, f.mvs);
    env.freeSlice(u8, f.segs);
    f.* = .{};
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

const TestMemory = struct {
    fn alloc(_: *anyopaque, len: usize, clear: bool) ?[*]u8 {
        const m = testing.allocator.alignedAlloc(u8, .@"16", len) catch return null;
        if (clear) @memset(m, 0);
        return m.ptr;
    }
    fn free(_: *anyopaque, memory: [*]u8, len: usize) void {
        const s: []align(16) u8 = @alignCast(memory[0..len]);
        testing.allocator.free(s);
    }
};

const Decoded = struct { shown: u32 = 0, errors: u32 = 0, hash: u64 = 0xcbf29ce484222325 };

const Way = struct {
    /// After so many temporal units: everything dropped, as for a seek,
    /// and the stream decoded from its start again.
    reset_after: ?u32 = null,
    /// After so many temporal units: the decoder closed, whatever it is
    /// doing.
    stop_after: ?u32 = null,
    /// Each temporal unit cut to this part of it, in sixteenths.
    cut: u32 = 16,
    /// Each frame taken as soon as there is one, as a program would not.
    eager: bool = false,
};

/// Every frame of an IVF file shown, in a decoder made for it: how many
/// shown and not right, and FNV-1a of their planes' bytes at the size
/// shown.
fn decodeAll(ivf: []const u8, way: Way) !Decoded {
    var ctx: u8 = 0;
    const env: Env = .{ .ctx = &ctx, .alloc = TestMemory.alloc, .free = TestMemory.free };
    const dec = Decoder.create(env) orelse return error.OutOfMemory;
    defer dec.destroy();
    const start = std.mem.readInt(u16, ivf[6..8], .little);
    var got: Decoded = .{};
    var at: usize = start;
    var count: u32 = 0;
    while (true) {
        count += 1;
        if (way.stop_after == count) return got;
        if (way.reset_after == count) {
            dec.reset();
            got = .{};
            at = start;
        }
        if (at + 12 <= ivf.len) {
            const size = std.mem.readInt(u32, ivf[at..][0..4], .little);
            const data = ivf[at + 12 ..][0 .. size * way.cut / 16];
            at += 12 + size;
            dec.decodeFrame(data, count, false) catch {
                got.errors += 1;
            };
        } else dec.flush();
        while (dec.next()) |s| {
            const f = s.frame;
            const bytes: usize = f.alloc_bytes;
            for (0..3) |p| {
                const sx: u5 = if (p > 0) f.ss_x else 0;
                const sy: u5 = if (p > 0) f.ss_y else 0;
                const w = (f.width + (@as(u32, 1) << sx) - 1) >> sx;
                const h = (f.height + (@as(u32, 1) << sy) - 1) >> sy;
                for (0..h) |r| {
                    for (f.planes[p][r * f.stride[p] * bytes ..][0 .. w * bytes]) |byte| got.hash = (got.hash ^ byte) *% 0x100000001b3;
                }
            }
            got.shown += 1;
            dec.release();
            if (!way.eager) break;
        }
        if (dec.flushing and dec.out_count == 0) return got;
    }
}

// tests/t1.ivf: libaom of ffmpeg's testsrc2 at 200x112, 24 frames, 2x2
// tiles (palette, CfL, OBMC, local warp, skip mode). tests/t2.ivf:
// libaom, 10-bit 4:4:4, 72x56, 6 frames. tests/t3.ivf: libaom, 12-bit
// 4:2:2, error resilient, loop restoration, 96x64, 10 frames.
// tests/t4.ivf: SVT-AV1, superres and screen content (intra block copy),
// frames 192x112 in a sequence that says 192x108 at most, 12 frames.
// tests/t5.ivf: libaom, film grain (its test table 3), 96x56, 8 frames.
// The hashes are of dav1d's decode.
test "frames decoded as dav1d decodes them, after a seek, a close and damaged ones" {
    const streams = [_]struct { ivf: []const u8, expect: Decoded }{
        .{ .ivf = @embedFile("tests/t1.ivf"), .expect = .{ .shown = 24, .hash = 0x4a9ee9e57edf4494 } },
        .{ .ivf = @embedFile("tests/t2.ivf"), .expect = .{ .shown = 6, .hash = 0xef6063783e47e4fd } },
        .{ .ivf = @embedFile("tests/t3.ivf"), .expect = .{ .shown = 10, .hash = 0x92867b231c1cd63d } },
        .{ .ivf = @embedFile("tests/t4.ivf"), .expect = .{ .shown = 12, .hash = 0xbdc14b8d4a731f16 } },
        .{ .ivf = @embedFile("tests/t5.ivf"), .expect = .{ .shown = 8, .hash = 0xc0e64490c5bfaf5c } },
    };
    for (streams) |s| {
        try testing.expectEqual(s.expect, try decodeAll(s.ivf, .{}));
        try testing.expectEqual(s.expect, try decodeAll(s.ivf, .{ .eager = true }));
        for ([_]u32{ 3, 6 }) |at| {
            try testing.expectEqual(s.expect, try decodeAll(s.ivf, .{ .reset_after = at }));
            _ = try decodeAll(s.ivf, .{ .stop_after = at });
        }
        // Temporal units cut short: some frames come out, wrong; nothing
        // is caught.
        for ([_]u32{ 1, 5, 8, 15 }) |cut| _ = try decodeAll(s.ivf, .{ .cut = cut });
    }
}
