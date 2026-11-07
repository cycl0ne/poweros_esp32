// SPDX-License-Identifier: MIT
//! The AV1 decoder (AV1 Bitstream & Decoding Process Specification,
//! 2019): videoparse.library's events in, the frames to show out.
//!
//! The library reads the OBUs (5.3): the sequence header, which names the
//! profile, the depth and format of the samples and the tools the frames
//! may use, and each frame's header (5.9), with what it takes from the
//! frames before it - the settings its primary reference left, the
//! references it names, the film grain of a frame shown again. It hands
//! out each frame with the eight reference slots' pictures as its
//! references, and then its tiles, one by one. The decoder keeps each
//! tile's bytes; once the last is there, the rest is a job: the tiles
//! read (parse.zig) into the frame's blocks and coefficients, which
//! leaves the frames after it its CDFs, motion field and segment map; the
//! frame put together a superblock row at a time (recon.zig), and behind
//! the rows deblocked, CDEF filtered, upscaled when it was coded narrower
//! and loop restored (post.zig). A frame shown with film grain is shown
//! as a copy with the grain added (grain.zig), a job of its own once the
//! frame is done.
//!
//! The library's slots name the pictures: the frame decoded into one, a
//! reference by it, the frame a temporal unit shows (VPEV_SHOW) - of a
//! stream in layers the last, as libaom shows by default. The decoder's
//! own frames are as many as it holds: in the library's slots, for its
//! jobs and to be shown; a slot goes back to the library (`giveBack`) as
//! soon as it says VPEV_FREE of it, or with a seek.
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
//! key frame - the same with workers and without. One the decoder cannot
//! decode at all (no memory, a reference missing) leaves it waiting for
//! a key frame.

const sdk = @import("sdk");
const vp = sdk.videoparse;
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

/// The library's slots at most: the eight reference slots' pictures, the
/// frame decoded, the frame shown waiting for its temporal unit's end,
/// and the caller's 32.
pub const max_slots = 10 + 32;
/// Frames decoded at once at most; it divides 256 (`Decoder.crew`).
const max_jobs = 8;
/// Workers used at most.
const max_workers = 8;
/// Frames waiting to be shown at most; one more drops the first.
const max_out = max_jobs + 2;
/// Frames at most: the library's ten slots - the decoder lends none
/// beyond them; for each job its frame, the narrower one it is coded in
/// with superres and its copy with film grain; those waiting to be shown.
const max_frames = 10 + 3 * max_jobs + max_out;

/// A frame to show and when.
pub const Shown = struct { frame: *const Frame, time: i64 };

/// What a worker is handed: the decoder whose jobs it runs, and which
/// worker it is.
const Hand = struct { dec: *Decoder, who: u32 };

/// Where a tile's bytes lie in a job's `data`.
const Tile = struct { num: u32, at: usize, len: usize };

/// A frame read, put together and filtered, on a worker or by the
/// decoder; or a frame shown given its film grain.
const Job = struct {
    // The decoder's: the cores, the worker that took it, whether it runs
    // and which began first.
    cores: ?*const Cores = null,
    who: u32 = 0,
    active: bool = false,
    order: u32 = 0,
    /// Set by the worker once the frame is done.
    done: bool = false,
    /// A frame shown with film grain: decoded by a job before, its copy
    /// with the grain made once it is done.
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
    /// The CDFs each frame leaves, made with its first job, and what else
    /// it leaves the frames that refer to it (its motion field and
    /// segment map are its own).
    frame_cdfs: [max_frames]?*Cdfs = @splat(null),
    kept: [max_frames]parse.RefInfo = @splat(.{}),
    /// The frame whose VPEV_PICTURE came, until its VPEV_DECODE: its
    /// sequence and header, its slot, the pictures in the eight reference
    /// slots, and its job.
    seq: header.Sequence = .{},
    h: header.Frame = .{},
    pending: bool = false,
    pending_slot: u8 = 0,
    ref_frames: [8]?*Frame = @splat(null),
    job: ?*Job = null,
    /// The picture of each slot the library gave, and the library's slots
    /// by bit: lent with their VPEV_PICTURE, and to be given back
    /// (ReleaseVideoSlot) since their VPEV_FREE or a seek.
    by_slot: [max_slots]?*Frame = @splat(null),
    lent: u64 = 0,
    returned: u64 = 0,
    /// What reads the tiles: the decoder's, and each worker's.
    ps: parse.Parse,
    parses: [max_workers]?*parse.Parse = @splat(null),
    /// Until a key frame: at the start, after a frame the decoder could
    /// not decode, and after a seek.
    need_key: bool = true,

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
    /// frame, and every slot lent goes back to the library.
    pub fn reset(dec: *Decoder) void {
        dec.drain();
        dec.abandon();
        for (0..max_slots) |i| dec.setSlot(i, null);
        dec.returned |= dec.lent;
        dec.lent = 0;
        while (dec.out_count != 0) dec.release();
        dec.flushing = false;
        dec.need_key = true;
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

    /// An event of videoparse.library's: a frame's sequence, header and
    /// references taken from its VPEV_PICTURE, and its job and frames
    /// made; each tile's bytes kept from its VPEV_SLICE; the frame begun
    /// on a worker - or decoded - at its VPEV_DECODE, the picture of the
    /// slot the library gave it. VPEV_SHOW hands the slot's picture out,
    /// unless `drop` - due before what is shown - has it decoded for the
    /// frames after it alone; with film grain, a copy with the grain
    /// added by a job of its own. VPEV_FREE forgets the slot's picture,
    /// which the decoder keeps as long as it needs it.
    pub fn event(dec: *Decoder, e: *const vp.VideoEvent, drop: bool) Error!void {
        switch (e.kind) {
            vp.VPEV_PICTURE => {
                const pic = e.picture orelse return;
                const v = pic.av1 orelse return;
                const s = pic.av1_sequence orelse return;
                if (pic.slot >= max_slots) return error.Corrupt;
                dec.lent |= @as(u64, 1) << @intCast(pic.slot);
                dec.abandon();
                dec.flushing = false;
                dec.seq = header.sequenceOf(s);
                dec.h = header.frameOf(v);
                for (&dec.ref_frames, pic.refs[0..8]) |*f, r| f.* = if (r.slot < max_slots) dec.by_slot[r.slot] else null;
                dec.pending_slot = pic.slot;
                dec.setSlot(pic.slot, null);
                if (dec.h.frame_type == common.KEY_FRAME and dec.h.show_frame) {
                    dec.need_key = false;
                } else if (dec.need_key and !dec.h.intra) return error.Corrupt;
                dec.beginFrame() catch |failure| {
                    dec.need_key = true;
                    return failure;
                };
                dec.pending = true;
            },
            vp.VPEV_SLICE => {
                if (!dec.pending) return;
                const sl = e.slice orelse return;
                dec.keepTile(sl.tile, sl.unit[0..sl.unit_bytes]) catch |failure| {
                    dec.abandon();
                    dec.need_key = true;
                    return failure;
                };
            },
            vp.VPEV_DECODE => {
                if (!dec.pending) return;
                const f = dec.endFrame() catch |failure| {
                    dec.abandon();
                    dec.need_key = true;
                    return failure;
                };
                dec.setSlot(dec.pending_slot, f);
            },
            vp.VPEV_SHOW => {
                const pic = e.picture orelse return;
                const v = pic.av1 orelse return;
                if (e.slot >= max_slots) return;
                // A key frame shown again goes into every reference slot.
                if (v.show_existing_frame and v.frame_type == common.KEY_FRAME) dec.need_key = false;
                if (dec.need_key or drop) return;
                const f = dec.by_slot[e.slot] orelse return;
                try dec.show(f, &header.grainOf(&v.film_grain), e.time);
            },
            vp.VPEV_FREE => if (e.slot < max_slots) {
                dec.setSlot(e.slot, null);
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

    /// The frame whose VPEV_PICTURE came and whose VPEV_DECODE did not
    /// dropped: its frames let go of.
    fn abandon(dec: *Decoder) void {
        if (!dec.pending) return;
        dec.pending = false;
        const j = dec.job orelse return;
        dec.job = null;
        j.cur.refs -= 1;
        if (j.coded != j.cur) j.coded.refs -= 1;
    }

    /// The frame set up: its references checked, its job and frames made
    /// - held until its VPEV_DECODE - the CDFs and maps it starts from.
    fn beginFrame(dec: *Decoder) Error!void {
        const h = &dec.h;
        const seq = &dec.seq;
        const env = dec.env;
        // The references there, of the frame's format and of a size it
        // can be predicted from.
        if (!h.intra) {
            for (h.ref_frame_idx) |idx| {
                const r = dec.ref_frames[idx] orelse return error.Corrupt;
                if (r.bit_depth != seq.bit_depth or r.ss_x != seq.ss_x or r.ss_y != seq.ss_y or r.mono != seq.mono) return error.Corrupt;
                if (2 * h.frame_width < r.width or 2 * h.frame_height < r.height or
                    h.frame_width > 16 * r.width or h.frame_height > 16 * r.height) return error.Corrupt;
            }
        }
        const j = try dec.freeJob();
        try dec.makeParses();
        const cur = try dec.freeFrame(h.upscaled_width, h.frame_height);
        cur.refs += 1;
        errdefer cur.refs -= 1;
        var coded = cur;
        if (h.use_superres) {
            coded = try dec.freeFrame(h.frame_width, h.frame_height);
            coded.refs += 1;
        }
        errdefer if (coded != cur) {
            coded.refs -= 1;
        };
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
            const f = dec.ref_frames[h.ref_frame_idx[h.primary_ref_frame]] orelse return error.Corrupt;
            j.cdf_frame = f;
            j.cdf_from = dec.frame_cdfs[dec.indexOf(f)] orelse return error.Corrupt;
        }
        const own = &dec.frame_cdfs[dec.indexOf(cur)];
        if (own.* == null) own.* = env.create(Cdfs) orelse return error.NoMemory;
        j.cdf_to = own.*.?;

        // What the frame reads of its references.
        for (&j.info, dec.ref_frames) |*info, ref| {
            const f = ref orelse {
                info.* = .{};
                continue;
            };
            info.* = dec.kept[dec.indexOf(f)];
            info.mvs = f.mvs;
            info.segs = f.segs;
        }
        j.prev_segs = &.{};
        if (h.primary_ref_frame != common.PRIMARY_REF_NONE and h.segmentation_enabled) {
            const ri = &j.info[h.ref_frame_idx[h.primary_ref_frame]];
            if (ri.mi_cols == h.mi_cols and ri.mi_rows == h.mi_rows and ri.segs.len == n) j.prev_segs = ri.segs;
        }
        j.bytes = 0;
        j.ntiles = 0;
        dec.job = j;
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

    /// Tile `num`'s bytes kept for the job.
    fn keepTile(dec: *Decoder, num: u32, bytes: []const u8) Error!void {
        const j = dec.job.?;
        const env = dec.env;
        if (num >= dec.h.tile_cols * dec.h.tile_rows) return error.Corrupt;
        if (!env.grow(u8, &j.data, j.bytes + bytes.len)) return error.NoMemory;
        if (!env.grow(Tile, &j.tiles, j.ntiles + 1)) return error.NoMemory;
        @memcpy(j.data[j.bytes..][0..bytes.len], bytes);
        j.tiles[j.ntiles] = .{ .num = num, .at = j.bytes, .len = bytes.len };
        j.bytes += bytes.len;
        j.ntiles += 1;
    }

    /// decode_frame_wrapup (7.4): the frame read, put together and
    /// filtered by its job, and what it leaves the frames after it kept.
    /// The frame it comes to.
    fn endFrame(dec: *Decoder) Error!*Frame {
        const h = &dec.h;
        const seq = &dec.seq;
        const env = dec.env;
        const j = dec.job.?;
        const cur = j.cur;
        const coded = j.coded;

        // What the job needs, before anything of the decoder's changes.
        j.again = false;
        j.seq = seq.*;
        j.h = h.*;
        j.refs = @splat(null);
        if (!h.intra) {
            for (0..7) |i| j.refs[i + 1] = dec.ref_frames[h.ref_frame_idx[i]];
        }
        try j.rc.prepare(env);
        try post.prepare(&j.post, env, h, coded, cur);
        j.grained = null;
        dec.kept[dec.indexOf(cur)] = .{
            .mi_cols = h.mi_cols,
            .mi_rows = h.mi_rows,
            .frame_type = h.frame_type,
            .order_hint = h.order_hint,
            .saved_order_hints = h.order_hints,
            .upscaled_width = h.upscaled_width,
            .frame_height = h.frame_height,
        };

        // The rest is the job's, which holds the frames from now on.
        cur.progress = 0;
        dec.pending = false;
        dec.job = null;
        dec.begin(j);
        cur.refs -= 1;
        if (coded != cur) coded.refs -= 1;
        return cur;
    }

    /// Frame `f` handed out at `time`: with film grain `g`, a copy with
    /// the grain added by a job, once the frame is done.
    fn show(dec: *Decoder, f: *Frame, g: *const header.Grain, time: i64) Error!void {
        if (!(dec.seq.film_grain_params_present and g.apply_grain)) return dec.enqueue(f, time);
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
        dec.enqueue(copy, time);
    }

    /// The output process: `f` to be shown at `time`, the first waiting
    /// dropped when too many do.
    fn enqueue(dec: *Decoder, f: *Frame, time: i64) void {
        if (dec.out_count == max_out) dec.release();
        f.queued += 1;
        dec.queue[(dec.out_first + dec.out_count) % max_out] = .{ .frame = f, .time = time };
        dec.out_count += 1;
        dec.width = f.width;
        dec.height = f.height;
        dec.bit_depth = f.bit_depth;
    }

    fn setSlot(dec: *Decoder, i: usize, f: ?*Frame) void {
        if (dec.by_slot[i]) |old| old.refs -= 1;
        dec.by_slot[i] = f;
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
                    // The frame whose tiles come has its job already.
                    if (!j.active and j != dec.job) return j;
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
