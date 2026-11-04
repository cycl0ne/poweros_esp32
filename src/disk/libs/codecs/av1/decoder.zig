// SPDX-License-Identifier: MIT
//! The AV1 decoder (AV1 Bitstream & Decoding Process Specification,
//! 2019): temporal units in, the frames to show out.
//!
//! A temporal unit is OBUs (5.3): the sequence header, which names the
//! profile, the depth and format of the samples and the tools the frames
//! may use; and frames, each its header (5.9) and its tiles, in tile
//! groups. The decoder reads the headers and keeps each tile's bytes as
//! its tile group comes; once the last is there, the frame goes into the
//! reference slots its header names, of eight, with its size and settings
//! for the headers after it, and the rest is a job: the tiles read
//! (parse.zig) into the frame's blocks and coefficients, which leaves the
//! frames after it its CDFs, motion field and segment map; the frame put
//! together a superblock row at a time (recon.zig), and behind the rows
//! deblocked, CDEF filtered, upscaled when it was coded narrower and loop
//! restored (post.zig). A frame shown with film grain is shown as a copy
//! with the grain added (grain.zig), the job's last part - or a job of
//! its own for a frame shown again.
//!
//! Of a temporal unit with several frames shown - the layers of a
//! scalable stream - the last is handed out, as libaom does by default.
//!
//! **The cores**: given workers (`useCores`), the jobs wait in turn for
//! whichever worker is free, and the decoder goes on with the next
//! frames' headers meanwhile - up to twice as many frames as there are
//! workers, so that a worker finds the next one when it is done with one.
//! A job reads its tiles once the frame its CDFs come from is read (and
//! with temporal motion vectors, its references), so frames are read side
//! by side as far as the stream's references allow. It counts the lines
//! of its frame that are final (`progress`), and each read of a reference
//! waits for the lines it reaches, which jobs begun before it put
//! together. Without workers the decoder runs each job itself.
//!
//! A frame read wrongly is not shown, nor any predicted from it, until a
//! key frame - the same with workers and without.

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

/// Frames decoded at once at most; it divides 256 (`Decoder.crew`).
const max_jobs = 8;
/// Workers used at most.
const max_workers = 8;
/// Frames waiting to be shown at most; one more drops the first.
const max_out = max_jobs + 2;
/// Frames at most: the eight reference slots; for each job its frame,
/// the narrower one it is coded in with superres and its copy with film
/// grain; those waiting to be shown.
const max_frames = 8 + 3 * max_jobs + max_out;

/// A frame to show and when.
pub const Shown = struct { frame: *const Frame, time: i64 };

/// What a worker is handed: the decoder whose jobs it runs, and which
/// worker it is.
const Hand = struct { dec: *Decoder, who: u32 };

/// Where a tile's bytes lie in a job's `data`.
const Tile = struct { num: u32, at: usize, len: usize };

/// A frame read, put together and filtered, on a worker or by the
/// decoder; or a frame shown again given its film grain.
const Job = struct {
    // The decoder's: the cores, the worker that took it, whether it runs
    // and which began first.
    cores: ?*const Cores = null,
    who: u32 = 0,
    active: bool = false,
    order: u32 = 0,
    /// Set by the worker once the frame is done.
    done: bool = false,
    /// A frame shown again: decoded by a job before, its copy with film
    /// grain made once it is done.
    again: bool = false,
    /// The frame's sequence and header, its blocks, the references it
    /// reads (by LAST_FRAME to ALTREF_FRAME, for an inter frame), which
    /// it holds while it runs; the frame, the narrower one it is coded
    /// in (else the same) and the copy shown with film grain.
    seq: header.Sequence = .{},
    h: header.Frame = .{},
    out: parse.Out = .{},
    refs: [8]?*const Frame = @splat(null),
    cur: *Frame = undefined,
    coded: *Frame = undefined,
    grained: ?*Frame = null,
    rc: recon.Recon = .{},
    post: post.Scratch = .{},
    rows: post.Rows = .{},
    film: grain.Scratch = .{},
    /// The frame's tiles as they came: `bytes` of `data`, and where each
    /// lies.
    data: []u8 = &.{},
    bytes: usize = 0,
    tiles: []Tile = &.{},
    ntiles: u32 = 0,
    /// The CDFs the frame starts from: those its primary reference left
    /// (`cdf_frame`'s, there once it is read), or the defaults; and where
    /// the frame's own go, for the frames after it.
    cdf_frame: ?*const Frame = null,
    cdf_from: ?*const Cdfs = null,
    cdf_to: *Cdfs = undefined,
    start: Cdfs = undefined,
    /// What the frame reads of the references, by slot, and the segment
    /// map it predicts from; the mi rows whose motion field it kept.
    info: [8]parse.RefInfo = @splat(.{}),
    prev_segs: []const u8 = &.{},
    kept: u32 = 0,

    /// The job's work, with `ps` to read the tiles with.
    fn decode(j: *Job, ps: *parse.Parse) void {
        const wait: ?recon.Wait = if (j.cores) |c| .{ .cores = c, .who = j.who } else null;
        if (j.again) {
            if (wait) |w| w.cores.lines(w.who, j.cur, j.cur.height);
        } else {
            j.read(ps, wait);
            // A frame predicted from one not right is not right either:
            // known once a line of each reference is final.
            for (j.refs) |ref| {
                const f = ref orelse continue;
                if (wait) |w| w.cores.lines(w.who, f, 1);
                if (f.broken) j.cur.broken = true;
            }
            if (!j.cur.broken) {
                const sb_rows = j.out.sb_rows;
                j.rows = .{};
                for (0..sb_rows) |ru| {
                    const r: u32 = @intCast(ru);
                    j.rc.row(&j.seq, &j.h, &j.out, j.coded, j.refs, wait, r);
                    j.publish(j.cur, post.advance(&j.post, &j.rows, &j.seq, &j.h, &j.out, j.coded, j.cur, r + 1, r + 1 == sb_rows));
                }
            }
            j.publish(j.cur, 0xFFFF_FFFF);
        }
        if (j.grained) |g| {
            if (j.cur.broken) g.broken = true else grain.apply(g, j.cur, &j.h.grain, &j.film);
            j.publish(g, 0xFFFF_FFFF);
        }
    }

    /// The tiles read into the frame's blocks, once the frame its CDFs
    /// come from is read (the references' motion fields are waited for
    /// by rows); the motion field kept by rows as they are read, and at
    /// the end the rest of what the frame leaves the frames after it -
    /// zeros when it was read wrongly - and the frame marked read.
    fn read(j: *Job, ps: *parse.Parse, wait: ?recon.Wait) void {
        const h = &j.h;
        const cur = j.cur;
        if (wait) |w| {
            if (j.cdf_frame) |f| w.cores.read(w.who, f, Frame.whole);
        }
        j.kept = 0;
        ps.hooks = .{ .ctx = j, .until = refRows, .read = rowsRead };
        j.readTiles(ps) catch {
            cur.broken = true;
        };
        if (cur.broken) {
            @memset(cur.mvs[(j.kept >> 1) * (h.mi_cols >> 1) ..], .{});
            @memset(cur.segs, 0);
        } else {
            storeMotionField(&j.seq, h, cur, &j.out, j.kept, h.mi_rows);
            if (h.segmentation_enabled and !h.segmentation_update_map) {
                if (j.prev_segs.len == cur.segs.len) {
                    @memcpy(cur.segs, j.prev_segs);
                } else {
                    @memset(cur.segs, 0);
                }
            }
        }
        @atomicStore(u32, &cur.parsed, Frame.whole, .seq_cst);
        if (j.cores) |c| c.wake(c.ctx);
    }

    /// parse.Hooks: until reference `ref`'s motion field is there down
    /// to mi row `rows`.
    fn refRows(ctx: *anyopaque, ref: i8, rows: u32) void {
        const j: *Job = @ptrCast(@alignCast(ctx));
        const c = j.cores orelse return;
        if (j.refs[@intCast(ref)]) |f| c.read(j.who, f, rows);
    }

    /// parse.Hooks: the frame read down to mi row `rows`, its motion
    /// field kept that far.
    fn rowsRead(ctx: *anyopaque, rows: u32) void {
        const j: *Job = @ptrCast(@alignCast(ctx));
        storeMotionField(&j.seq, &j.h, j.cur, &j.out, j.kept, rows);
        j.kept = rows;
        @atomicStore(u32, &j.cur.parsed, rows, .seq_cst);
        if (j.cores) |c| c.wake(c.ctx);
    }

    fn readTiles(j: *Job, ps: *parse.Parse) Error!void {
        const h = &j.h;
        if (j.cdf_from) |from| {
            j.start = from.*;
            j.start.clearCounts();
        } else {
            j.start.initNonCoeff();
            j.start.initCoeff(h.base_q_idx);
        }
        // What the frame leaves, unless the tile they adapt to is read.
        j.cdf_to.* = j.start;
        try ps.begin(&j.out, &j.seq, h, &j.info, j.cur.segs, j.prev_segs);
        for (j.tiles[0..j.ntiles]) |t| {
            const keep = !h.disable_frame_end_update_cdf and t.num == h.context_update_tile_id;
            try ps.tile(t.num, j.data[t.at..][0..t.len], &j.start, if (keep) j.cdf_to else null);
        }
    }

    fn publish(j: *Job, f: *Frame, n: u32) void {
        @atomicStore(u32, &f.progress, n, .seq_cst);
        if (j.cores) |c| c.wake(c.ctx);
    }

    /// Its frames and references held, or let go.
    fn hold(j: *Job, comptime take: bool) void {
        for (j.refs) |ref| {
            if (ref) |f| pin(@constCast(f), take);
        }
        pin(j.cur, take);
        pin(j.coded, take);
        if (j.grained) |g| pin(g, take);
    }

    fn pin(f: *Frame, comptime take: bool) void {
        if (take) f.pinned += 1 else f.pinned -= 1;
    }

    fn deinit(j: *Job, env: Env) void {
        env.freeSlice(u8, j.data);
        env.freeSlice(Tile, j.tiles);
        j.out.free(env);
        j.rc.deinit(env);
        j.post.deinit(env);
        j.film.deinit(env);
    }
};

pub const Decoder = struct {
    env: Env,
    /// The size and depth of the last frame shown; 0 before the first.
    width: u32 = 0,
    height: u32 = 0,
    bit_depth: u8 = 0,
    frames: [max_frames]Frame = @splat(.{}),
    /// The CDFs each frame leaves, made with its first job.
    frame_cdfs: [max_frames]?*Cdfs = @splat(null),
    slots: [8]?*Frame = @splat(null),
    /// What each slot keeps for the headers after it.
    states: [8]header.RefState = @splat(.{}),
    seq: header.Sequence = .{},
    have_seq: bool = false,
    carry: header.Carry = .{},
    /// The frame whose tiles come: its header and its job.
    h: header.Frame = .{},
    in_frame: bool = false,
    next_tile: u32 = 0,
    job: ?*Job = null,
    /// What reads the tiles: the decoder's, and each worker's.
    ps: parse.Parse,
    parses: [max_workers]?*parse.Parse = @splat(null),
    /// Until a key frame: at the start, after an error and a reset.
    need_key: bool = true,
    /// The light the film was mastered for, in candelas a square metre,
    /// as a metadata OBU said; 0 until one does.
    peak_nits: u16 = 0,
    /// The temporal unit's frame to show.
    shown: ?*Frame = null,

    // --- the frames to show ---
    queue: [max_out]Shown = undefined,
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
        dec.* = .{ .env = env, .ps = parse.Parse.init(env) };
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
            j.deinit(env);
            env.destroy(Job, j);
        }
        for (&dec.frames) |*f| freeFrameMemory(env, f);
        for (dec.frame_cdfs) |slot| {
            if (slot) |c| env.destroy(Cdfs, c);
        }
        for (dec.parses) |slot| {
            const ps = slot orelse continue;
            ps.deinit();
            env.destroy(parse.Parse, ps);
        }
        dec.ps.deinit();
        env.free(env.ctx, @ptrCast(dec), @sizeOf(Decoder));
    }

    /// Everything dropped, for a seek: the next frame decoded is a key
    /// frame.
    pub fn reset(dec: *Decoder) void {
        dec.drain();
        for (0..8) |i| dec.setSlot(i, null);
        dec.states = @splat(.{});
        while (dec.out_count != 0) dec.release();
        dec.flushing = false;
        dec.need_key = true;
        dec.in_frame = false;
    }

    /// The next frame to show, or null. It stays valid until `release`.
    /// While the frames are workers' and a job is free, null: the frames
    /// after it first, so that the workers have them while the frame is
    /// shown - as long as no more wait to be shown than there are
    /// workers. One a worker still decodes is waited for; one not right
    /// is passed over.
    pub fn next(dec: *Decoder) ?Shown {
        while (dec.out_count != 0) {
            const s = dec.queue[dec.out_first];
            if (dec.cores) |c| {
                if (!dec.flushing and dec.out_count <= c.workers and dec.idle()) return null;
                c.lines(c.workers, s.frame, s.frame.height);
            }
            if (!s.frame.broken) return s;
            dec.release();
        }
        return null;
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
                header.OBU_METADATA => dec.metadata(o.payload),
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

    /// A metadata OBU (5.8.1): the light the film was mastered for, which
    /// the screen's own range has to be mapped from. The mastering
    /// display's maximum, and the film's brightest pixel where it says
    /// that too and it is lower - a film is no brighter than its
    /// brightest pixel, and mapping from a peak it never reaches would
    /// darken it for nothing. Anything else in the OBU is passed over.
    fn metadata(dec: *Decoder, payload: []const u8) void {
        const kind = header.leb128(payload, 0) orelse return;
        var b: header.Bits = .{ .data = payload, .pos = kind.len * 8 };
        const peak: u32 = switch (kind.value) {
            // metadata_hdr_cll: max_cll, in candelas.
            1 => b.f(16),
            // metadata_hdr_mdcv: the primaries and the white point first,
            // then luminance_max in 256ths of a candela.
            2 => blk: {
                b.pos += 16 * 8;
                break :blk b.f(32) >> 8;
            },
            else => return,
        };
        if (b.overrun() or peak == 0) return;
        const now: u16 = @intCast(@min(peak, 10000));
        dec.peak_nits = if (dec.peak_nits == 0) now else @min(dec.peak_nits, now);
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
                    dec.setSlot(i, f);
                }
                dec.need_key = false;
            } else if (dec.need_key) return;
            try dec.showExisting(f, &h.grain);
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

    /// The frame set up: its references checked, its job and frames
    /// made, the CDFs and maps it starts from.
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
        const j = try dec.freeJob();
        try dec.makeParses();
        const cur = try dec.freeFrame(h.upscaled_width, h.frame_height);
        cur.refs += 1;
        defer cur.refs -= 1;
        var coded = cur;
        if (h.use_superres) {
            coded = try dec.freeFrame(h.frame_width, h.frame_height);
        }
        dec.job = j;
        j.cur = cur;
        j.coded = coded;
        const n = h.mi_cols * h.mi_rows;
        const n8 = (h.mi_cols >> 1) * (h.mi_rows >> 1);
        if (cur.segs.len != n and !env.resize(u8, &cur.segs, n)) return error.NoMemory;
        if (cur.mvs.len != n8) {
            env.freeSlice(common.MfMv, cur.mvs);
            cur.mvs = &.{};
            cur.mvs = env.slice(common.MfMv, n8) orelse return error.NoMemory;
        }

        // The CDFs it starts from, and where its own go.
        j.cdf_frame = null;
        j.cdf_from = null;
        if (h.primary_ref_frame != common.PRIMARY_REF_NONE) {
            const f = dec.slots[h.ref_frame_idx[h.primary_ref_frame]] orelse return error.Corrupt;
            j.cdf_frame = f;
            j.cdf_from = dec.frame_cdfs[dec.indexOf(f)].?;
        }
        const own = &dec.frame_cdfs[dec.indexOf(cur)];
        if (own.* == null) own.* = env.create(Cdfs) orelse return error.NoMemory;
        j.cdf_to = own.*.?;

        // What the frame reads of its references.
        for (0..8) |i| {
            const f = dec.slots[i] orelse {
                j.info[i] = .{};
                continue;
            };
            const st = &dec.states[i];
            j.info[i] = .{
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
        j.prev_segs = &.{};
        if (h.primary_ref_frame != common.PRIMARY_REF_NONE and h.segmentation_enabled) {
            const ri = &j.info[h.ref_frame_idx[h.primary_ref_frame]];
            if (ri.mi_cols == h.mi_cols and ri.mi_rows == h.mi_rows and ri.segs.len == n) j.prev_segs = ri.segs;
        }
        j.bytes = 0;
        j.ntiles = 0;
    }

    /// Frame `f`'s place in `frames`.
    fn indexOf(dec: *const Decoder, f: *const Frame) usize {
        return (@intFromPtr(f) - @intFromPtr(&dec.frames)) / @sizeOf(Frame);
    }

    /// What reads the tiles for each worker, made here for the workers.
    fn makeParses(dec: *Decoder) Error!void {
        const c = dec.cores orelse return;
        for (dec.parses[0..@min(c.workers, max_workers)]) |*slot| {
            if (slot.* != null) continue;
            const ps = dec.env.create(parse.Parse) orelse return error.NoMemory;
            ps.* = parse.Parse.init(dec.env);
            slot.* = ps;
        }
    }

    /// A tile's bytes kept for the job.
    fn keepTile(dec: *Decoder, num: u32, bytes: []const u8) Error!void {
        const j = dec.job.?;
        const env = dec.env;
        if (!env.grow(u8, &j.data, j.bytes + bytes.len)) return error.NoMemory;
        if (!env.grow(Tile, &j.tiles, j.ntiles + 1)) return error.NoMemory;
        @memcpy(j.data[j.bytes..][0..bytes.len], bytes);
        j.tiles[j.ntiles] = .{ .num = num, .at = j.bytes, .len = bytes.len };
        j.bytes += bytes.len;
        j.ntiles += 1;
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
            try dec.keepTile(t, data[at..][0..size]);
            at += size;
        }
        dec.next_tile = end + 1;
        if (end == num_tiles - 1) {
            dec.in_frame = false;
            try dec.endFrame();
        }
    }

    /// decode_frame_wrapup (7.4): the frame read, put together and
    /// filtered by its job, and the slots set.
    fn endFrame(dec: *Decoder) Error!void {
        const h = &dec.h;
        const seq = &dec.seq;
        const env = dec.env;
        const j = dec.job.?;
        const cur = j.cur;
        const coded = j.coded;
        coded.refs += 1;
        defer coded.refs -= 1;
        cur.refs += 1;
        defer cur.refs -= 1;

        // What the job needs, before anything of the decoder's changes.
        j.again = false;
        j.seq = seq.*;
        j.h = h.*;
        j.refs = @splat(null);
        if (!h.intra) {
            for (0..7) |i| j.refs[i + 1] = dec.slots[h.ref_frame_idx[i]];
        }
        try j.rc.prepare(env);
        try post.prepare(&j.post, env, h, coded, cur);
        j.grained = null;
        if (h.show_frame and seq.film_grain_params_present and h.grain.apply_grain) {
            try grain.prepare(&j.film, env, cur.width);
            j.grained = try dec.freeFrame(cur.width, cur.height);
        }

        // The rest is the job's.
        cur.progress = 0;
        if (j.grained) |g| g.progress = 0;
        dec.job = null;
        dec.begin(j);

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
            dec.setSlot(i, cur);
        }
        if (h.show_frame) dec.show(j.grained orelse cur);
    }

    /// A frame shown again (show_existing_frame): with film grain `g`, a
    /// copy with the grain added by a job, once the frame is done.
    fn showExisting(dec: *Decoder, f: *Frame, g: *const header.Grain) Error!void {
        if (!(dec.seq.film_grain_params_present and g.apply_grain)) return dec.show(f);
        f.refs += 1;
        defer f.refs -= 1;
        const j = try dec.freeJob();
        const copy = try dec.freeFrame(f.width, f.height);
        if (copy.memory.len != f.memory.len) return error.Unsupported;
        try grain.prepare(&j.film, dec.env, f.width);
        j.again = true;
        j.h.grain = g.*;
        j.refs = @splat(null);
        j.cur = f;
        j.coded = f;
        j.grained = copy;
        copy.progress = 0;
        dec.begin(j);
        dec.show(copy);
    }

    /// The output process: `f` handed out at the end of the temporal
    /// unit.
    fn show(dec: *Decoder, f: *Frame) void {
        if (dec.shown) |old| old.queued -= 1;
        f.queued += 1;
        dec.shown = f;
        dec.width = f.width;
        dec.height = f.height;
        dec.bit_depth = f.bit_depth;
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

    /// A frame no slot, job or wait for showing holds, for a `w` by `h`
    /// frame of the sequence's format: one made for it, or another made
    /// anew; when every one is held, once the first job is done.
    fn freeFrame(dec: *Decoder, w: u32, h: u32) Error!*Frame {
        const seq = &dec.seq;
        const alloc_w = (w + 127) & ~@as(u32, 127);
        const alloc_h = (h + 127) & ~@as(u32, 127);
        const bytes: u8 = if (seq.bit_depth > 8) 2 else 1;
        const f = while (true) {
            dec.retire();
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
            if (spare) |f| break f;
            if (!dec.retireOldest()) return error.NoMemory;
        };
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
        f.parsed = 0;
        f.broken = false;
        f.mono = seq.mono;
        f.bit_depth = seq.bit_depth;
        f.primaries = seq.primaries;
        f.transfer = seq.transfer;
        f.matrix = seq.matrix;
        f.full_range = seq.full_range;
        f.peak_nits = dec.peak_nits;
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
                const j = dec.env.create(Job) orelse return error.NoMemory;
                j.* = .{};
                slot.* = j;
                return j;
            }
            if (!dec.retireOldest()) return error.NoMemory;
        }
    }

    /// Job `j` begun, its frames and references held until it is done:
    /// waiting for a worker, one that runs none sent to run them - or run
    /// here without workers.
    fn begin(dec: *Decoder, j: *Job) void {
        j.hold(true);
        j.cores = dec.cores;
        j.done = false;
        j.active = true;
        j.order = dec.job_order;
        dec.job_order +%= 1;
        const c = dec.cores orelse {
            j.decode(&dec.ps);
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
                j.decode(dec.parses[who].?);
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

/// The motion field kept (7.19) of mi rows `from` to `to`: by 8x8, the
/// vectors of the blocks that point back.
fn storeMotionField(seq: *const header.Sequence, h: *const header.Frame, cur: *Frame, out: *const parse.Out, from: u32, to: u32) void {
    const w8 = h.mi_cols >> 1;
    const limit = (1 << 12) - 1;
    for (from >> 1..to >> 1) |y8| {
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

fn freeFrameMemory(env: Env, f: *Frame) void {
    env.freeSlice(u8, f.memory);
    env.freeSlice(common.MfMv, f.mvs);
    env.freeSlice(u8, f.segs);
    f.* = .{};
}

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

/// Workers on threads, waiting by yielding.
const TestCores = struct {
    cores: Cores = undefined,
    jobs: [3]usize = @splat(0),
    args: [3]usize = @splat(0),
    threads: [3]std.Thread = undefined,
    quit: bool = false,

    fn of(ctx: *anyopaque) *TestCores {
        return @ptrCast(@alignCast(ctx));
    }
    fn run(ctx: *anyopaque, worker: u32, job: *const fn (*anyopaque) void, arg: *anyopaque) void {
        const t = of(ctx);
        t.args[worker] = @intFromPtr(arg);
        @atomicStore(usize, &t.jobs[worker], @intFromPtr(job), .seq_cst);
    }
    fn arm(_: *anyopaque, _: u32) void {}
    fn sleep(_: *anyopaque, _: u32) void {
        std.Thread.yield() catch {};
    }
    fn wake(_: *anyopaque) void {}
    fn work(t: *TestCores, i: usize) void {
        while (!@atomicLoad(bool, &t.quit, .acquire)) {
            const job = @atomicRmw(usize, &t.jobs[i], .Xchg, 0, .acq_rel);
            if (job == 0) {
                std.Thread.yield() catch {};
                continue;
            }
            const f: *const fn (*anyopaque) void = @ptrFromInt(job);
            f(@ptrFromInt(t.args[i]));
        }
    }
};

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
fn decodeAll(ivf: []const u8, cores: ?*const Cores, way: Way) !Decoded {
    var ctx: u8 = 0;
    const env: Env = .{ .ctx = &ctx, .alloc = TestMemory.alloc, .free = TestMemory.free };
    const dec = Decoder.create(env) orelse return error.OutOfMemory;
    defer dec.destroy();
    if (cores) |c| dec.useCores(c);
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
test "frames decoded as dav1d decodes them, alone and on three workers, after a seek, a close and damaged ones" {
    var t: TestCores = .{};
    t.cores = .{ .ctx = &t, .workers = 3, .run = TestCores.run, .arm = TestCores.arm, .sleep = TestCores.sleep, .wake = TestCores.wake };
    for (&t.threads, 0..) |*th, i| th.* = try std.Thread.spawn(.{}, TestCores.work, .{ &t, i });
    defer {
        @atomicStore(bool, &t.quit, true, .seq_cst);
        for (t.threads) |th| th.join();
    }
    const streams = [_]struct { ivf: []const u8, expect: Decoded }{
        .{ .ivf = @embedFile("tests/t1.ivf"), .expect = .{ .shown = 24, .hash = 0x4a9ee9e57edf4494 } },
        .{ .ivf = @embedFile("tests/t2.ivf"), .expect = .{ .shown = 6, .hash = 0xef6063783e47e4fd } },
        .{ .ivf = @embedFile("tests/t3.ivf"), .expect = .{ .shown = 10, .hash = 0x92867b231c1cd63d } },
        .{ .ivf = @embedFile("tests/t4.ivf"), .expect = .{ .shown = 12, .hash = 0xbdc14b8d4a731f16 } },
        .{ .ivf = @embedFile("tests/t5.ivf"), .expect = .{ .shown = 8, .hash = 0xc0e64490c5bfaf5c } },
    };
    for (streams) |s| {
        for ([_]?*const Cores{ null, &t.cores }) |cores| {
            try testing.expectEqual(s.expect, try decodeAll(s.ivf, cores, .{}));
            try testing.expectEqual(s.expect, try decodeAll(s.ivf, cores, .{ .eager = true }));
            for ([_]u32{ 3, 6 }) |at| {
                try testing.expectEqual(s.expect, try decodeAll(s.ivf, cores, .{ .reset_after = at }));
                _ = try decodeAll(s.ivf, cores, .{ .stop_after = at });
            }
            // Temporal units cut short: some frames come out, wrong;
            // nothing is caught.
            for ([_]u32{ 1, 5, 8, 15 }) |cut| _ = try decodeAll(s.ivf, cores, .{ .cut = cut });
        }
    }
}
