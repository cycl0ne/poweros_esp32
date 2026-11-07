// SPDX-License-Identifier: MIT
//! The VP9 decoder (VP9 Bitstream & Decoding Process Specification 0.6):
//! videoparse.library's events in, the frames to show out.
//!
//! The library cuts the packets into their frames - a superframe's
//! several, the last but one usually hidden (B.3) - and reads each one's
//! uncompressed header, which names the frame's size, format and
//! references and what the frame keeps of the ones before it: the colour,
//! the loop filter's deltas, the segmentation, whether the vectors of the
//! frame before are read. Here a frame is its compressed header, which
//! changes the probabilities, and its tiles. The decoder reads every tile
//! into the blocks and coefficients of the frame (parse.zig) and adapts
//! the probabilities to what it read; the rest is a job: the frame put
//! together a superblock row at a time (recon.zig), each row filtered
//! once it is done (filter.zig) - its last line kept as it was before,
//! for the intra prediction of the row below, which reads its neighbours
//! unfiltered. The frame goes into the reference slots its header names,
//! of eight.
//!
//! What a frame keeps of the ones before it here - the four saved sets of
//! probabilities, the segment map, the vectors of the frame before - is
//! kept as libvpx keeps it, whose decode the test vectors are of: a frame
//! that is not right leaves the decoder waiting for a key frame or an
//! intra-only one. The library's slots name the pictures it shows
//! (VPEV_SHOW), a reference again among them; the decoder's own frames
//! are as many as it holds, in the eight reference slots, for its jobs
//! and to be shown, and a slot goes back to the library (`giveBack`) as
//! soon as it says VPEV_FREE of it, or with a seek.
//!
//! **The cores**: given workers (`useCores`), the jobs wait in turn for
//! whichever worker is free, and the decoder goes on reading the next
//! frames meanwhile - up to twice as many as there are workers, so that
//! a worker finds the next frame read when it is done with one. A job
//! counts the lines of its frame that are final (`progress`), and before
//! each superblock row it waits for the lines of the references its
//! blocks' vectors reach, which jobs begun before it put together.
//! Without workers the decoder runs each job itself.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const v9 = vp.vp9;
const common = @import("common.zig");
const tables = @import("tables.zig");
const header = @import("header.zig");
const probs = @import("probs.zig");
const parse = @import("parse.zig");
const recon = @import("recon.zig");
const filter = @import("filter.zig");
const Env = common.Env;
const Error = common.Error;
const Frame = common.Frame;
const MvRef = common.MvRef;
const Cores = common.Cores;
const Probs = probs.Probs;

/// The library's slots at most: the eight reference slots' pictures, the
/// frame decoded, and the caller's 32.
pub const max_slots = 9 + 32;

/// A frame's depth, sampling and colour, as its header says.
const Color = struct {
    bit_depth: u8 = 8,
    color_space: u8 = 0,
    full_range: bool = false,
    ss_x: u1 = 1,
    ss_y: u1 = 1,
};

/// Frames decoded at once at most; it divides 256 (`Decoder.crew`).
const max_jobs = 8;
/// Workers used at most.
const max_workers = 8;
/// Frames waiting to be shown at most; one more drops the first.
const max_out = max_jobs + 2;
/// Frames at most: the eight reference slots, one for each job, and
/// those waiting to be shown.
const max_frames = 8 + max_jobs + max_out;

/// A frame to show and when.
pub const Shown = struct { frame: *const Frame, time: i64 };

/// What a worker is handed: the decoder whose jobs it runs, and which
/// worker it is.
const Hand = struct { dec: *Decoder, who: u32 };

/// A frame put together, on a worker or by the decoder, from its blocks
/// as the decoder read them.
const Job = struct {
    // The decoder's: the cores, the worker that took it, whether it runs
    // and which began first.
    cores: ?*const Cores = null,
    who: u32 = 0,
    active: bool = false,
    order: u32 = 0,
    /// Set by the worker once the frame is done.
    done: bool = false,
    out: parse.Out = .{},
    rc: recon.Recon = undefined,
    lf: filter.Filter = undefined,
    filtering: bool = false,
    /// Whether it reads references, which it holds while it runs.
    inter: bool = false,
    scratch: recon.Scratch = .{},
    /// The last line of the row above as it was before it was filtered,
    /// of each plane in turn, at their strides.
    line: []u8 = &.{},

    fn decode(j: *Job) void {
        if (j.rc.frame.alloc_bytes == 1) j.rows(u8) else j.rows(u16);
    }

    fn rows(j: *Job, comptime P: type) void {
        const sb_rows = (j.out.mi_rows + 7) >> 3;
        for (0..sb_rows) |ru| {
            const r: u32 = @intCast(ru);
            j.reach(r);
            if (j.filtering and r > 0) j.above(r, false);
            j.rc.sbRow(P, r, &j.scratch);
            if (j.filtering) {
                if (r > 0) j.above(r, false);
                if (r + 1 < sb_rows) j.above(r + 1, true);
                j.lf.sbRow(P, r);
            }
            // Filtering the next row changes the last lines of this one:
            // seven at most, in the colour fourteen.
            j.publish(64 * r + 48);
        }
        j.publish(0xFFFF_FFFF);
    }

    /// The line above superblock row `r`, of each plane: kept before it
    /// is filtered (`save`), or swapped with the one kept - put back for
    /// the row's intra prediction, and filtered again after it.
    fn above(j: *Job, r: u32, comptime save: bool) void {
        const f = j.rc.frame;
        const bytes: usize = f.alloc_bytes;
        var at: usize = 0;
        for (0..3) |p| {
            const ss: u5 = if (p > 0) f.ss_y else 0;
            const len = f.stride[p] * bytes;
            const row = f.planes[p][(((64 * r) >> ss) - 1) * len ..][0..len];
            const kept = j.line[at..][0..len];
            if (save) {
                @memcpy(kept, row);
            } else for (kept, row) |*k, *a| {
                const t = k.*;
                k.* = a.*;
                a.* = t;
            }
            at += len;
        }
    }

    /// Until the lines of the references that the blocks of superblock
    /// row `r` read are final: as far down as their vectors point, with
    /// the filters' taps below, in the brightness and in the colour; the
    /// whole of a reference of another size.
    fn reach(j: *Job, r: u32) void {
        const c = j.cores orelse return;
        const out = &j.out;
        var need: [4]u32 = @splat(0);
        const sb_cols = (out.mi_cols + 7) >> 3;
        for (0..sb_cols) |sc| {
            const i = r * sb_cols + sc;
            const first = out.sb_first[i];
            for (out.blocks[first .. first + out.sb_count[i]]) |*b| {
                if (!b.is_inter) continue;
                const bottom: i32 = @intCast(@min(@as(u32, b.row) + tables.num_8x8_high[b.size], out.mi_rows) * 8);
                for (b.ref_frame, &b.mvs) |ref, *mvs| {
                    if (ref <= common.INTRA_FRAME) continue;
                    const rf = &j.rc.refs[@intCast(ref)];
                    var n = rf.frame.height;
                    if (!rf.scaled) {
                        var down: i32 = mvs[0].row;
                        for (mvs[1..]) |m| down = @max(down, m.row);
                        n = @min(n, @as(u32, @intCast(bottom + (@max(down, 0) >> 3) + 12)));
                    }
                    need[@intCast(ref)] = @max(need[@intCast(ref)], n);
                }
            }
        }
        for (1..4) |ref| {
            if (need[ref] != 0) c.lines(j.who, j.rc.refs[ref].frame, need[ref]);
        }
    }

    fn publish(j: *Job, n: u32) void {
        @atomicStore(u32, &j.rc.frame.progress, n, .seq_cst);
        if (j.cores) |c| c.wake(c.ctx);
    }

    /// Its frame and references held, each once, or let go.
    fn hold(j: *Job, comptime take: bool) void {
        if (j.inter) {
            for (1..4) |i| {
                const f: *Frame = @constCast(j.rc.refs[i].frame);
                if (i > 1 and f == j.rc.refs[1].frame or i > 2 and f == j.rc.refs[2].frame) continue;
                if (take) f.pinned += 1 else f.pinned -= 1;
            }
        }
        if (take) j.rc.frame.pinned += 1 else j.rc.frame.pinned -= 1;
    }
};

pub const Decoder = struct {
    env: Env,
    frames: [max_frames]Frame = @splat(.{}),
    slots: [8]?*Frame = @splat(null),
    /// The saved probabilities, and whether a reset has set each.
    contexts: [4]Probs = @splat(probs.defaults),
    ready: [4]bool = @splat(false),
    /// The frame's probabilities, and how often it read each value.
    p: Probs = probs.defaults,
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
    /// The last frame decoded: its size and depth, and the type of the
    /// last header, which the probabilities adapt by.
    width: u32 = 0,
    height: u32 = 0,
    bit_depth: u8 = 8,
    frame_type: u1 = header.KEY_FRAME,
    /// The frame whose VPEV_PICTURE came, its header and its slot, until
    /// its VPEV_SLICE; the picture of each slot the library gave.
    pending: v9.Vp9Header = .{},
    pending_slot: u8 = 0,
    has_pending: bool = false,
    by_slot: [max_slots]?*Frame = @splat(null),
    /// The library's slots by bit: lent with their VPEV_PICTURE, and to be
    /// given back (ReleaseVideoSlot) since their VPEV_FREE or a seek.
    lent: u64 = 0,
    returned: u64 = 0,
    /// Until a key frame or an intra-only one: at the start, after a
    /// frame that was not right and after a seek.
    need_resync: bool = true,

    // --- the frames to show ---
    out: [max_out]Shown = undefined,
    out_first: u32 = 0,
    out_count: u32 = 0,
    /// The end was sent: a frame still being decoded is waited for.
    flushing: bool = false,

    // --- the other cores ---
    cores: ?*const Cores = null,
    jobs: [max_jobs]?*Job = @splat(null),
    job_order: u32 = 0,
    /// The jobs begun that wait for a worker, in turn from the one at
    /// the head of `crew`; the next is put at `begun`.
    waiting: [max_jobs]?*Job = @splat(null),
    begun: u32 = 0,
    /// One word, so that a worker stops only while no job waits: a bit
    /// for each worker that runs jobs (`work`), the number of jobs that
    /// wait times 0x100, and their head, of 256, times 0x10000.
    crew: u32 = 0,
    hands: [max_workers]Hand = undefined,

    pub fn create(env: Env) ?*Decoder {
        const bytes = env.alloc(env.ctx, @sizeOf(Decoder), true) orelse return null;
        const dec: *Decoder = @ptrCast(@alignCast(bytes));
        dec.* = .{ .env = env, .ps = .{ .env = env } };
        return dec;
    }

    /// Frames put together on `cores` from now on, as many at once as it
    /// has workers, and as many again read ahead.
    pub fn useCores(dec: *Decoder, cores: *const Cores) void {
        dec.cores = cores;
        for (&dec.hands, 0..) |*h, i| h.* = .{ .dec = dec, .who = @intCast(i) };
    }

    pub fn destroy(dec: *Decoder) void {
        const env = dec.env;
        dec.drain();
        for (dec.jobs) |slot| {
            const j = slot orelse continue;
            j.out.deinit(env);
            env.freeSlice(u8, j.line);
            env.free(env.ctx, @ptrCast(j), @sizeOf(Job));
        }
        for (&dec.frames) |*f| env.freeSlice(u8, f.memory);
        for (dec.mvs) |m| env.freeSlice(MvRef, m);
        for (dec.segs) |s| env.freeSlice(u8, s);
        dec.ps.deinit();
        env.free(env.ctx, @ptrCast(dec), @sizeOf(Decoder));
    }

    /// Everything dropped, for a seek: the next frame decoded is a key
    /// frame or an intra-only one.
    pub fn reset(dec: *Decoder) void {
        dec.drain();
        for (0..8) |i| dec.setSlot(i, null);
        while (dec.out_count != 0) dec.release();
        dec.by_slot = @splat(null);
        dec.returned |= dec.lent;
        dec.lent = 0;
        dec.has_pending = false;
        dec.flushing = false;
        dec.need_resync = true;
    }

    /// The next frame to show, or null. It stays valid until `release`.
    /// While the frames are workers' and a job is free, null: the frames
    /// after it first, so that the workers have them while the frame is
    /// shown - as long as no more wait to be shown than there are
    /// workers. One a worker still decodes is waited for.
    pub fn next(dec: *Decoder) ?Shown {
        if (dec.out_count == 0) return null;
        const s = dec.out[dec.out_first];
        if (dec.cores) |c| {
            if (!dec.flushing and dec.out_count <= c.workers and dec.idle()) return null;
            c.lines(c.workers, s.frame, s.frame.height);
        }
        return s;
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

    /// An event of videoparse.library's: a frame's header kept from its
    /// VPEV_PICTURE, the frame decoded - or begun on a worker - from its
    /// VPEV_SLICE into the picture of the slot the library gave it, shown
    /// by VPEV_SHOW unless `drop` - due before what is shown - has it
    /// decoded for the frames after it alone; VPEV_FREE forgets the
    /// slot's picture, which the decoder keeps as long as it needs it.
    pub fn event(dec: *Decoder, e: *const vp.VideoEvent, drop: bool) Error!void {
        switch (e.kind) {
            vp.VPEV_PICTURE => {
                const pic = e.picture orelse return;
                const v = pic.vp9 orelse return;
                if (pic.slot >= dec.by_slot.len) return error.Corrupt;
                dec.lent |= @as(u64, 1) << @intCast(pic.slot);
                dec.pending = v.*;
                dec.pending_slot = pic.slot;
                dec.has_pending = true;
            },
            vp.VPEV_SLICE => {
                if (!dec.has_pending) return;
                dec.has_pending = false;
                const sl = e.slice orelse return;
                dec.flushing = false;
                dec.by_slot[dec.pending_slot] = null;
                const f = dec.frame(sl.unit[0..sl.unit_bytes], &dec.pending) catch |failure| {
                    dec.need_resync = true;
                    return failure;
                };
                dec.by_slot[dec.pending_slot] = f;
            },
            vp.VPEV_SHOW => {
                if (e.slot >= dec.by_slot.len or dec.need_resync) return;
                const f = dec.by_slot[e.slot] orelse return;
                if (!drop) dec.queue(f, e.time);
            },
            vp.VPEV_FREE => if (e.slot < dec.by_slot.len) {
                dec.by_slot[e.slot] = null;
                const bit = @as(u64, 1) << @intCast(e.slot);
                if (dec.lent & bit != 0) dec.returned |= bit;
                dec.lent &= ~bit;
            },
            else => {},
        }
    }

    /// A slot to give back to the library (ReleaseVideoSlot), or null:
    /// one it let go of, or every one it lent after a seek. The decoder
    /// keeps its own frames as long as it needs them.
    pub fn giveBack(dec: *Decoder) ?u32 {
        if (dec.returned == 0) return null;
        const slot: u32 = @ctz(dec.returned);
        dec.returned &= dec.returned - 1;
        return slot;
    }

    /// The frame `data` of the header `v` decoded, or begun on a worker:
    /// the picture it comes to.
    fn frame(dec: *Decoder, data: []const u8, v: *const v9.Vp9Header) Error!*Frame {
        if (data.len == 0) return error.Corrupt;
        const last_type = dec.frame_type;
        var h = header.of(v);
        dec.frame_type = h.frame_type;
        if (h.intra) {
            // A key frame or an intra-only one with the decoder waiting:
            // the references before it are gone.
            if (dec.need_resync) {
                for (0..8) |i| dec.setSlot(i, null);
                dec.need_resync = false;
            }
        } else if (dec.need_resync) return error.Corrupt;
        if (h.header_size == 0) return error.Corrupt;
        if (h.header_start > data.len or h.header_size > data.len - h.header_start) return error.Corrupt;
        const color: Color = .{
            .bit_depth = v.bit_depth,
            .color_space = v.color_space,
            .full_range = v.color_range,
            .ss_x = @intCast(v.subsampling_x),
            .ss_y = @intCast(v.subsampling_y),
        };
        const w = h.width;
        const hh = h.height;

        // What the frame is put together with - a job, a frame - before
        // anything of the decoder's changes.
        const j = try dec.freeJob();
        const mi_cols = (w + 7) >> 3;
        const mi_rows = (hh + 7) >> 3;
        if (!j.out.fit(dec.env, mi_cols, mi_rows)) return error.NoMemory;
        j.rc = .{ .frame = undefined, .out = &j.out, .lossless = h.lossless };

        // The references: there, of the frame's format, and one at least
        // of a size it can be predicted from; one that is not cannot be
        // used.
        var bad_scale = false;
        if (!h.intra) {
            var any = false;
            for (h.ref_frame_idx, 1..) |idx, i| {
                const r = dec.slots[idx] orelse return error.Corrupt;
                if (r.bit_depth != color.bit_depth or r.ss_x != color.ss_x or r.ss_y != color.ss_y) return error.Corrupt;
                const ok = validScale(r, w, hh);
                any = any or ok;
                bad_scale = bad_scale or !ok;
                j.rc.refs[i] = recon.Ref.init(r, w, hh);
            }
            if (!any) return error.Corrupt;
        }
        const cur = try dec.freeFrame(w, hh, color);
        const line = (cur.stride[0] + 2 * @as(usize, cur.stride[1])) * cur.alloc_bytes;
        if (j.line.len != line and !dec.env.resize(u8, &j.line, line)) return error.NoMemory;

        // The contexts for the frame's size; a new size drops the segment
        // map.
        if (mi_cols != dec.mi_cols or mi_rows != dec.mi_rows or color.ss_x != dec.ss_x) try dec.fit(mi_cols, mi_rows, color.ss_x);
        if (w != dec.width or hh != dec.height) @memset(dec.segs[dec.seg_cur ^ 1], 0);
        const use_prev_mvs = v.use_prev_frame_mvs;

        // setup_past_independence (7.2): the probabilities reset, saved
        // as the frame says, and those of the first set used.
        if (h.reset_past) {
            dec.p = probs.defaults;
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
        const ps = &dec.ps;
        ps.h = &h;
        ps.seg = &v.segmentation;
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
        ps.out = &j.out;
        ps.frameTables(&v.loop_filter);
        try ps.tiles(data[h.header_start + h.header_size ..]);
        if (bad_scale) {
            for (j.out.blocks[0..j.out.n_blocks]) |*b| {
                if (!b.is_inter) continue;
                for (b.ref_frame) |r| {
                    if (r > common.INTRA_FRAME and !validScale(j.rc.refs[@intCast(r)].frame, w, hh)) return error.Corrupt;
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

        // The rest is the job's.
        j.rc.frame = cur;
        j.lf = filter.Filter.init(cur, &j.out, h.sharpness);
        j.filtering = h.filter_level != 0;
        cur.progress = 0;
        dec.begin(j, !h.intra);

        // What the next frames keep of it.
        for (0..8) |i| {
            if (h.refresh_frame_flags >> @intCast(i) & 1 == 0) continue;
            dec.setSlot(i, cur);
        }
        dec.mv_cur ^= 1;
        if (v.segmentation.enabled and v.segmentation.update_map) dec.seg_cur ^= 1;
        dec.width = w;
        dec.height = hh;
        dec.bit_depth = color.bit_depth;
        return cur;
    }

    fn validScale(r: *const Frame, w: u32, h: u32) bool {
        return 2 * w >= r.width and 2 * h >= r.height and w <= 16 * r.width and h <= 16 * r.height;
    }

    /// The contexts and maps for `mi_cols` by `mi_rows` 8x8s.
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
    }

    fn queue(dec: *Decoder, f: *Frame, time: i64) void {
        if (dec.out_count == max_out) dec.release();
        dec.out[(dec.out_first + dec.out_count) % max_out] = .{ .frame = f, .time = time };
        dec.out_count += 1;
        f.queued += 1;
    }

    /// A frame no slot, job or wait for showing holds, for a `w` by `h`
    /// frame of `color`'s format: one made for it, or another made anew;
    /// when every one is held, once the first job is done.
    fn freeFrame(dec: *Decoder, w: u32, h: u32, color: Color) Error!*Frame {
        const alloc_w = (w + 63) & ~@as(u32, 63);
        const alloc_h = (h + 63) & ~@as(u32, 63);
        const bytes: u8 = if (color.bit_depth > 8) 2 else 1;
        const f = while (true) {
            dec.retire();
            var spare: ?*Frame = null;
            for (&dec.frames) |*f| {
                if (f.refs != 0 or f.pinned != 0 or f.queued != 0) continue;
                if (f.memory.len != 0 and f.alloc_w == alloc_w and f.alloc_h == alloc_h and
                    f.alloc_bytes == bytes and f.ss_x == color.ss_x and f.ss_y == color.ss_y)
                {
                    spare = f;
                    break;
                }
                if (spare == null) spare = f;
            }
            if (spare) |f| break f;
            if (!dec.retireOldest()) return error.NoMemory;
        };
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

    // --- the jobs -------------------------------------------------------------

    /// The jobs there may be: twice the workers, one without them.
    fn jobCount(dec: *const Decoder) usize {
        const c = dec.cores orelse return 1;
        return @max(1, @min(2 * @as(usize, c.workers), max_jobs));
    }

    /// A job not running: made while there are fewer than `jobCount`,
    /// and when every one runs, the first once it is done.
    fn freeJob(dec: *Decoder) Error!*Job {
        const n = dec.jobCount();
        while (true) {
            dec.retire();
            for (dec.jobs[0..n]) |*slot| {
                if (slot.*) |j| {
                    if (!j.active) return j;
                    continue;
                }
                const bytes = dec.env.alloc(dec.env.ctx, @sizeOf(Job), true) orelse return error.NoMemory;
                const j: *Job = @ptrCast(@alignCast(bytes));
                j.* = .{};
                slot.* = j;
                return j;
            }
            if (!dec.retireOldest()) return error.NoMemory;
        }
    }

    /// Job `j` begun, its frame and references held until it is done:
    /// waiting for a worker, one that runs none sent to run them - or run
    /// here without workers.
    fn begin(dec: *Decoder, j: *Job, inter: bool) void {
        j.inter = inter;
        j.hold(true);
        j.cores = dec.cores;
        j.done = false;
        j.active = true;
        j.order = dec.job_order;
        dec.job_order +%= 1;
        const c = dec.cores orelse {
            j.decode();
            retireJob(j);
            return;
        };
        @atomicStore(?*Job, &dec.waiting[dec.begun % max_jobs], j, .monotonic);
        dec.begun +%= 1;
        var crew = @atomicRmw(u32, &dec.crew, .Add, 0x100, .seq_cst) + 0x100;
        const all = (@as(u32, 1) << @intCast(@min(c.workers, max_workers))) - 1;
        while (~crew & all != 0) {
            const w: u5 = @intCast(@ctz(~crew & all));
            crew = @cmpxchgWeak(u32, &dec.crew, crew, crew | @as(u32, 1) << w, .seq_cst, .seq_cst) orelse
                return c.run(c.ctx, w, work, &dec.hands[w]);
        }
    }

    /// A worker's: the jobs that wait, in turn, until none does. Each is
    /// taken by the same change of `crew` that checks it is the head -
    /// read before - and the worker stops by one that checks none waits,
    /// its last look at the decoder.
    fn work(arg: *anyopaque) void {
        const hand: *const Hand = @ptrCast(@alignCast(arg));
        const dec = hand.dec;
        const who = hand.who;
        const c = dec.cores.?;
        const bit = @as(u32, 1) << @intCast(who);
        var crew = @atomicLoad(u32, &dec.crew, .seq_cst);
        while (true) {
            if (crew >> 8 & 0xFF == 0) {
                crew = @cmpxchgWeak(u32, &dec.crew, crew, crew & ~bit, .seq_cst, .seq_cst) orelse break;
                continue;
            }
            const head = crew >> 16;
            const j = @atomicLoad(?*Job, &dec.waiting[head % max_jobs], .monotonic).?;
            const taken = ((crew & 0xFFFF) - 0x100) | ((head + 1) & 0xFF) << 16;
            crew = @cmpxchgWeak(u32, &dec.crew, crew, taken, .seq_cst, .seq_cst) orelse {
                j.who = who;
                j.decode();
                @atomicStore(bool, &j.done, true, .seq_cst);
                c.wake(c.ctx);
                crew = @atomicLoad(u32, &dec.crew, .seq_cst);
                continue;
            };
        }
        c.wake(c.ctx);
    }

    /// The jobs that are done given back their frames.
    fn retire(dec: *Decoder) void {
        for (dec.jobs) |slot| {
            const j = slot orelse continue;
            if (j.active and @atomicLoad(bool, &j.done, .acquire)) retireJob(j);
        }
    }

    fn retireJob(j: *Job) void {
        j.hold(false);
        j.active = false;
    }

    /// Until the job begun first is done, which is then retired; false
    /// when none runs.
    fn retireOldest(dec: *Decoder) bool {
        var oldest: ?*Job = null;
        for (dec.jobs) |slot| {
            const j = slot orelse continue;
            if (j.active and (oldest == null or j.order -% oldest.?.order > 1 << 31)) oldest = j;
        }
        const j = oldest orelse return false;
        const c = dec.cores.?;
        while (!@atomicLoad(bool, &j.done, .acquire)) {
            c.arm(c.ctx, c.workers);
            if (@atomicLoad(bool, &j.done, .seq_cst)) break;
            c.sleep(c.ctx, c.workers);
        }
        retireJob(j);
        return true;
    }

    /// Every job done, and every worker gone from the decoder: it goes
    /// on alone.
    fn drain(dec: *Decoder) void {
        while (dec.retireOldest()) {}
        const c = dec.cores orelse return;
        while (@atomicLoad(u32, &dec.crew, .seq_cst) & 0xFF != 0) {
            c.arm(c.ctx, c.workers);
            if (@atomicLoad(u32, &dec.crew, .seq_cst) & 0xFF == 0) break;
            c.sleep(c.ctx, c.workers);
        }
    }

    /// Whether a job is free: another frame can be read.
    fn idle(dec: *Decoder) bool {
        if (dec.cores == null) return false;
        dec.retire();
        for (dec.jobs[0..dec.jobCount()]) |slot| {
            const j = slot orelse return true;
            if (!j.active) return true;
        }
        return false;
    }
};
