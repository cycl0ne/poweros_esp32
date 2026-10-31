// SPDX-License-Identifier: MIT
//! The VP9 decoder (VP9 Bitstream & Decoding Process Specification 0.6):
//! packets in, the frames to show out.
//!
//! A packet is one frame or a superframe of several, the last but one
//! usually hidden (B.3). A frame is its uncompressed header, which names
//! the frame's size, format and references and what the frame keeps of
//! the ones before it; the compressed header, which changes the
//! probabilities; and the tiles. The decoder reads every tile into the
//! blocks and coefficients of the frame (parse.zig), adapts the
//! probabilities to what it read, then puts the frame together a
//! superblock row at a time (recon.zig), the row above filtered once the
//! next is done (filter.zig) - intra prediction reads its neighbours
//! unfiltered. The frame then goes into the reference slots its header
//! names, of eight.
//!
//! What a frame keeps of the ones before it - the four saved sets of
//! probabilities, the segment map, the vectors of the frame before, the
//! loop filter's and segmentation's settings - is kept as libvpx keeps
//! it, whose decode the test vectors are of: a frame that is not right
//! leaves the decoder waiting for a key frame or an intra-only one.

const common = @import("common.zig");
const header = @import("header.zig");
const probs = @import("probs.zig");
const parse = @import("parse.zig");
const recon = @import("recon.zig");
const filter = @import("filter.zig");
const Env = common.Env;
const Error = common.Error;
const Frame = common.Frame;
const MvRef = common.MvRef;
const Probs = probs.Probs;

/// Frames waiting to be shown at most; one more drops the first.
const max_out = 4;
/// Frames at most: the eight reference slots, the one being decoded and
/// those waiting to be shown.
const max_frames = 8 + 1 + max_out;

/// A frame to show and when.
pub const Shown = struct { frame: *const Frame, time: i64 };

pub const Decoder = struct {
    env: Env,
    frames: [max_frames]Frame = @splat(.{}),
    slots: [8]?*Frame = @splat(null),
    /// What the headers keep from frame to frame.
    st: header.State = .{},
    /// The saved probabilities, and whether a reset has set each.
    contexts: [4]Probs = @splat(Probs.defaults),
    ready: [4]bool = @splat(false),
    /// The frame's probabilities, and how often it read each value.
    p: Probs = Probs.defaults,
    counts: probs.Counts = undefined,
    ps: parse.Parse,
    /// The vectors of this frame and of the one before ([cur ^ 1]), and
    /// the segment maps likewise; by 8x8.
    mvs: [2][]MvRef = .{ &.{}, &.{} },
    mv_cur: u1 = 0,
    segs: [2][]u8 = .{ &.{}, &.{} },
    seg_cur: u1 = 0,
    /// What `ps` and the maps were made for.
    mi_cols: u32 = 0,
    mi_rows: u32 = 0,
    ss_x: u1 = 1,
    /// The last frame decoded: its size, whether it was shown, and the
    /// type and intra-only flag of the last header read, which libvpx
    /// keeps through a key frame.
    width: u32 = 0,
    height: u32 = 0,
    last_show_frame: bool = false,
    frame_type: u1 = header.KEY_FRAME,
    intra_only: bool = false,
    /// Until a key frame or an intra-only one: at the start, after a
    /// frame that was not right and after a seek.
    need_resync: bool = true,
    scratch: recon.Scratch = .{},

    // --- the frames to show ---
    out: [max_out]Shown = undefined,
    out_first: u32 = 0,
    out_count: u32 = 0,
    flushing: bool = false,

    pub fn create(env: Env) ?*Decoder {
        const bytes = env.alloc(env.ctx, @sizeOf(Decoder), true) orelse return null;
        const dec: *Decoder = @ptrCast(@alignCast(bytes));
        dec.* = .{ .env = env, .ps = .{ .env = env } };
        return dec;
    }

    pub fn destroy(dec: *Decoder) void {
        const env = dec.env;
        for (&dec.frames) |*f| env.freeSlice(u8, f.memory);
        for (dec.mvs) |m| env.freeSlice(MvRef, m);
        for (dec.segs) |s| env.freeSlice(u8, s);
        dec.ps.deinit();
        env.free(env.ctx, @ptrCast(dec), @sizeOf(Decoder));
    }

    /// Everything dropped, for a seek: the next frame decoded is a key
    /// frame or an intra-only one.
    pub fn reset(dec: *Decoder) void {
        for (0..8) |i| dec.setSlot(i, null);
        while (dec.out_count != 0) dec.release();
        dec.flushing = false;
        dec.need_resync = true;
    }

    /// The next frame to show, or null. It stays valid until `release`.
    pub fn next(dec: *Decoder) ?Shown {
        if (dec.out_count == 0) return null;
        return dec.out[dec.out_first];
    }

    pub fn release(dec: *Decoder) void {
        if (dec.out_count == 0) return;
        const f: *Frame = @constCast(dec.out[dec.out_first].frame);
        f.queued -= 1;
        dec.out_first = (dec.out_first + 1) % max_out;
        dec.out_count -= 1;
    }

    /// The end of the stream: every frame decoded is handed out.
    pub fn flush(dec: *Decoder) void {
        dec.flushing = true;
    }

    /// Packet `data` decoded, shown at `time`: the frame it shows is
    /// handed out by `next`, unless `drop` - due before what is shown -
    /// has it decoded for the frames after it alone. As libvpx, a packet
    /// shows one frame at most, its last frame's when that is shown.
    pub fn decodeFrame(dec: *Decoder, data: []const u8, time: i64, drop: bool) Error!void {
        dec.flushing = false;
        var shown: ?*Frame = null;
        dec.packet(data, &shown) catch |e| {
            dec.need_resync = true;
            return e;
        };
        if (shown) |f| {
            if (!drop) dec.queue(f, time);
        }
    }

    /// The frames of a packet (B.3): by the superframe index at its end,
    /// or one after the other, as many as there are.
    fn packet(dec: *Decoder, data: []const u8, shown: *?*Frame) Error!void {
        if (data.len == 0) return error.Corrupt;
        const marker = data[data.len - 1];
        if (marker & 0xE0 == 0xC0) {
            const frames: usize = (marker & 7) + 1;
            const mag: usize = ((marker >> 3) & 3) + 1;
            const index = 2 + mag * frames;
            if (data.len >= index and data[data.len - index] == marker) {
                var at: usize = 0;
                var sizes = data[data.len - index + 1 ..];
                for (0..frames) |_| {
                    var size: usize = 0;
                    for (0..mag) |i| size |= @as(usize, sizes[i]) << @intCast(8 * i);
                    sizes = sizes[mag..];
                    if (size > data.len - at) return error.Corrupt;
                    _ = try dec.frame(data[at .. at + size], shown);
                    at += size;
                }
                return;
            }
        }
        var at: usize = 0;
        while (at < data.len) {
            at += try dec.frame(data[at..], shown);
            // What an encoder may leave after a frame.
            while (at < data.len and data[at] == 0) at += 1;
        }
    }

    /// One frame decoded; how many bytes of `data` it was.
    fn frame(dec: *Decoder, data: []const u8, shown: *?*Frame) Error!usize {
        if (data.len == 0) return error.Corrupt;
        shown.* = null;
        const last_type = dec.frame_type;
        const last_intra_only = dec.intra_only;
        const st = &dec.st;
        var h = try header.uncompressed(data, st);
        if (h.show_existing_frame) {
            const f = dec.slots[h.frame_to_show] orelse return error.Corrupt;
            if (!dec.need_resync) shown.* = f;
            return if (h.profile <= 2) 1 else 2;
        }
        dec.frame_type = h.frame_type;
        if (h.frame_type != header.KEY_FRAME) dec.intra_only = h.intra_only;
        if (h.intra) {
            // A key frame or an intra-only one with the decoder waiting:
            // the references before it are gone.
            if (dec.need_resync) {
                for (0..8) |i| dec.setSlot(i, null);
                dec.need_resync = false;
            }
        } else if (dec.need_resync) return error.Corrupt;
        if (h.header_size == 0) return error.Corrupt;
        if (h.header_size > data.len - h.header_start) return error.Corrupt;
        const color = st.color;
        const w = h.width;
        const hh = h.height;

        // The references: there, of the frame's format, and one at least
        // of a size it can be predicted from; one that is not cannot be
        // used.
        var rc: recon.Recon = .{ .frame = undefined, .ps = &dec.ps, .lossless = h.lossless };
        var bad_scale = false;
        if (!h.intra) {
            var any = false;
            for (h.ref_frame_idx, 1..) |idx, i| {
                const r = dec.slots[idx] orelse return error.Corrupt;
                if (r.bit_depth != color.bit_depth or r.ss_x != color.ss_x or r.ss_y != color.ss_y) return error.Corrupt;
                const ok = 2 * w >= r.width and 2 * hh >= r.height and w <= 16 * r.width and hh <= 16 * r.height;
                any = any or ok;
                bad_scale = bad_scale or !ok;
                rc.refs[i] = recon.Ref.init(r, w, hh);
            }
            if (!any) return error.Corrupt;
        }

        // The tables for the frame's size; a new size drops the segment
        // map.
        const mi_cols = (w + 7) >> 3;
        const mi_rows = (hh + 7) >> 3;
        if (mi_cols != dec.mi_cols or mi_rows != dec.mi_rows or color.ss_x != dec.ss_x) try dec.fit(mi_cols, mi_rows, color.ss_x);
        if (w != dec.width or hh != dec.height) @memset(dec.segs[dec.seg_cur ^ 1], 0);
        const use_prev_mvs = !h.error_resilient and w == dec.width and hh == dec.height and
            !last_intra_only and dec.last_show_frame and last_type != header.KEY_FRAME;

        // setup_past_independence (7.2): the probabilities reset, saved
        // as the frame says, and those of the first set used.
        if (h.reset_past) {
            dec.p = Probs.defaults;
            if (h.frame_type == header.KEY_FRAME or h.error_resilient or h.reset_frame_context == 3) {
                dec.contexts = @splat(dec.p);
                dec.ready = @splat(true);
            } else if (h.reset_frame_context == 2) {
                dec.contexts[h.frame_context_idx] = dec.p;
                dec.ready[h.frame_context_idx] = true;
            }
            for (dec.segs) |s| @memset(s, 0);
            h.frame_context_idx = 0;
        }
        if (!dec.ready[h.frame_context_idx]) return error.Corrupt;
        dec.p = dec.contexts[h.frame_context_idx];
        const count = !h.error_resilient and !h.frame_parallel;
        if (count) dec.counts.clear();
        try header.compressed(data[h.header_start..][0..h.header_size], &h, &dec.p);

        // The tiles read.
        const cur = try dec.freeFrame(w, hh, color);
        const ps = &dec.ps;
        ps.h = &h;
        ps.seg = &st.seg;
        ps.p = &dec.p;
        ps.counts = &dec.counts;
        ps.count = count;
        ps.bit_depth = color.bit_depth;
        ps.ss_x = color.ss_x;
        ps.ss_y = color.ss_y;
        ps.use_prev_mvs = use_prev_mvs;
        ps.prev_mvs = dec.mvs[dec.mv_cur ^ 1];
        ps.cur_mvs = dec.mvs[dec.mv_cur];
        ps.prev_seg = dec.segs[dec.seg_cur ^ 1];
        ps.cur_seg = dec.segs[dec.seg_cur];
        ps.frameTables(&st.deltas);
        try ps.tiles(data[h.header_start + h.header_size ..]);
        if (bad_scale) {
            for (ps.blocks[0..ps.n_blocks]) |*b| {
                if (!b.is_inter) continue;
                for (b.ref_frame) |r| {
                    if (r > common.INTRA_FRAME and !validScale(rc.refs[@intCast(r)].frame, w, hh)) return error.Corrupt;
                }
            }
        }

        // The probabilities adapted (8.4.2) from the set the frame
        // started with, and saved.
        if (count) {
            var a = dec.contexts[h.frame_context_idx];
            probs.adaptCoef(&a, &dec.counts, h.intra, last_type == header.KEY_FRAME);
            if (h.intra) {
                dec.p.coef = a.coef;
            } else {
                probs.adaptNoncoef(&a, &dec.counts, h.interp_filter == common.SWITCHABLE, h.tx_mode == common.TX_MODE_SELECT, h.allow_hp);
                dec.p = a;
            }
        }
        if (h.refresh_frame_context) dec.contexts[h.frame_context_idx] = dec.p;

        // The frame put together and filtered, a superblock row at a time.
        rc.frame = cur;
        const sb_rows = (mi_rows + 7) >> 3;
        const lf = filter.Filter.init(cur, ps, h.sharpness);
        const filtering = h.filter_level != 0;
        if (color.bit_depth == 8) {
            for (0..sb_rows) |r| {
                rc.sbRow(u8, @intCast(r), &dec.scratch);
                if (filtering and r > 0) lf.sbRow(u8, @intCast(r - 1));
            }
            if (filtering) lf.sbRow(u8, sb_rows - 1);
        } else {
            for (0..sb_rows) |r| {
                rc.sbRow(u16, @intCast(r), &dec.scratch);
                if (filtering and r > 0) lf.sbRow(u16, @intCast(r - 1));
            }
            if (filtering) lf.sbRow(u16, sb_rows - 1);
        }

        // What the next frames keep of it.
        for (0..8) |i| {
            if (h.refresh_frame_flags >> @intCast(i) & 1 == 0) continue;
            dec.setSlot(i, cur);
        }
        dec.mv_cur ^= 1;
        if (st.seg.enabled and st.seg.update_map) dec.seg_cur ^= 1;
        dec.last_show_frame = h.show_frame;
        dec.width = w;
        dec.height = hh;
        if (h.show_frame) shown.* = cur;
        return data.len;
    }

    fn validScale(r: *const Frame, w: u32, h: u32) bool {
        return 2 * w >= r.width and 2 * h >= r.height and w <= 16 * r.width and h <= 16 * r.height;
    }

    /// The tables and maps for `mi_cols` by `mi_rows` 8x8s.
    fn fit(dec: *Decoder, mi_cols: u32, mi_rows: u32, ss_x: u1) Error!void {
        const env = dec.env;
        dec.mi_cols = 0;
        dec.mi_rows = 0;
        const n: usize = @as(usize, mi_cols) * mi_rows;
        if (!dec.ps.size(mi_cols, mi_rows, ss_x)) return error.NoMemory;
        for (&dec.mvs) |*m| {
            if (!env.resize(MvRef, m, n)) return error.NoMemory;
        }
        for (&dec.segs) |*s| {
            if (!env.resize(u8, s, n)) return error.NoMemory;
        }
        dec.mi_cols = mi_cols;
        dec.mi_rows = mi_rows;
        dec.ss_x = ss_x;
    }

    fn setSlot(dec: *Decoder, i: usize, f: ?*Frame) void {
        if (dec.slots[i]) |old| old.refs -= 1;
        dec.slots[i] = f;
        if (f) |new| new.refs += 1;
        dec.st.ref_width[i] = if (f) |new| new.width else 0;
        dec.st.ref_height[i] = if (f) |new| new.height else 0;
    }

    fn queue(dec: *Decoder, f: *Frame, time: i64) void {
        if (dec.out_count == max_out) dec.release();
        dec.out[(dec.out_first + dec.out_count) % max_out] = .{ .frame = f, .time = time };
        dec.out_count += 1;
        f.queued += 1;
    }

    /// A frame no slot holds and none waits to show, for a `w` by `h`
    /// frame of `color`'s format: one made for it, or another made anew.
    fn freeFrame(dec: *Decoder, w: u32, h: u32, color: header.Color) Error!*Frame {
        const alloc_w = (w + 63) & ~@as(u32, 63);
        const alloc_h = (h + 63) & ~@as(u32, 63);
        const bytes: u8 = if (color.bit_depth > 8) 2 else 1;
        var spare: ?*Frame = null;
        for (&dec.frames) |*f| {
            if (f.refs != 0 or f.queued != 0) continue;
            if (f.memory.len != 0 and f.alloc_w == alloc_w and f.alloc_h == alloc_h and
                f.alloc_bytes == bytes and f.ss_x == color.ss_x and f.ss_y == color.ss_y)
            {
                spare = f;
                break;
            }
            if (spare == null) spare = f;
        }
        const f = spare orelse return error.NoMemory;
        if (!(f.memory.len != 0 and f.alloc_w == alloc_w and f.alloc_h == alloc_h and
            f.alloc_bytes == bytes and f.ss_x == color.ss_x and f.ss_y == color.ss_y))
        {
            const env = dec.env;
            env.freeSlice(u8, f.memory);
            f.* = .{};
            const luma: usize = @as(usize, alloc_w) * alloc_h;
            const chroma: usize = @as(usize, alloc_w >> color.ss_x) * (alloc_h >> color.ss_y);
            const memory = env.slice(u8, (luma + 2 * chroma) * bytes) orelse return error.NoMemory;
            f.* = .{
                .planes = .{ memory.ptr, memory.ptr + luma * bytes, memory.ptr + (luma + chroma) * bytes },
                .stride = .{ alloc_w, alloc_w >> color.ss_x, alloc_w >> color.ss_x },
                .memory = memory,
                .ss_x = color.ss_x,
                .ss_y = color.ss_y,
                .alloc_w = alloc_w,
                .alloc_h = alloc_h,
                .alloc_bytes = bytes,
            };
        }
        f.width = w;
        f.height = h;
        f.bit_depth = color.bit_depth;
        f.color_space = color.color_space;
        f.full_range = color.full_range;
        return f;
    }
};

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
    /// After so many packets: everything dropped, as for a seek, and the
    /// stream decoded from its start again.
    reset_after: ?u32 = null,
    /// After so many packets: the decoder closed, whatever it is doing.
    stop_after: ?u32 = null,
    /// Each packet cut to this part of it, in sixteenths.
    cut: u32 = 16,
};

/// Every frame of an IVF file shown: how many shown and not right, and
/// FNV-1a of their planes' bytes at the size shown.
fn decodeAll(ivf: []const u8, way: Way) !Decoded {
    var ctx: u8 = 0;
    const env: Env = .{ .ctx = &ctx, .alloc = TestMemory.alloc, .free = TestMemory.free };
    const dec = Decoder.create(env) orelse return error.OutOfMemory;
    defer dec.destroy();
    const start = std.mem.readInt(u16, ivf[6..8], .little);
    var got: Decoded = .{};
    var at: usize = start;
    var count: u32 = 0;
    while (at + 12 <= ivf.len) {
        count += 1;
        if (way.stop_after == count) return got;
        if (way.reset_after == count) {
            dec.reset();
            got = .{};
            at = start;
        }
        const size = std.mem.readInt(u32, ivf[at..][0..4], .little);
        const data = ivf[at + 12 ..][0 .. size * way.cut / 16];
        at += 12 + size;
        dec.decodeFrame(data, count, false) catch {
            got.errors += 1;
        };
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
        }
    }
    return got;
}

// tests/alt.ivf: libvpx (two passes, alternate references in superframes,
// two tile rows, variance segmentation) of ffmpeg's testsrc2 at 136x104,
// 24 frames shown, a key frame every 12. tests/p3.ivf: profile 3, 10-bit
// 4:4:4, lossless, 72x56, 6 frames. tests/p3b.ivf: profile 3, 12-bit
// 4:2:2, error resilient, a key frame every 5, 10 frames. The hashes are
// of libvpx's decode.
test "frames decoded as libvpx decodes them, after a seek, a close and damaged ones" {
    const streams = [_]struct { ivf: []const u8, expect: Decoded }{
        .{ .ivf = @embedFile("tests/alt.ivf"), .expect = .{ .shown = 24, .hash = 0x70d55fed6db4ff63 } },
        .{ .ivf = @embedFile("tests/p3.ivf"), .expect = .{ .shown = 6, .hash = 0xb62fd6dd0824a579 } },
        .{ .ivf = @embedFile("tests/p3b.ivf"), .expect = .{ .shown = 10, .hash = 0x03b0e6b2545da3b7 } },
    };
    for (streams) |s| {
        try testing.expectEqual(s.expect, try decodeAll(s.ivf, .{}));
        for ([_]u32{ 3, 6, 9 }) |at| {
            try testing.expectEqual(s.expect, try decodeAll(s.ivf, .{ .reset_after = at }));
            _ = try decodeAll(s.ivf, .{ .stop_after = at });
        }
        // Packets cut short: some frames come out, wrong; nothing is caught.
        for ([_]u32{ 1, 5, 8, 15 }) |cut| _ = try decodeAll(s.ivf, .{ .cut = cut });
    }
}
