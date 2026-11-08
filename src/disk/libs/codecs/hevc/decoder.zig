// SPDX-License-Identifier: MIT
//! The decoder: videoparse.library's events in, pictures out in the order
//! they are shown. The library reads the stream - the parameter sets, the
//! slice segment headers, the order counts, the reference picture sets,
//! the lists, the bumping - and the decoder decodes the samples, by the
//! slots the library names the pictures by (dpb.zig).
//!
//! **A picture** (VPEV_PICTURE) gets its store, made for the sequence
//! (VPEV_SEQUENCE). Each slice segment (VPEV_SLICE) is decoded into it as
//! it comes; a CTB row that is whole is deblocked and all but its last
//! few lines get their sample adaptive offset. Once its segments are all
//! given (VPEV_DECODE) the CTBs no segment brought are concealed and the
//! rest of the rows filtered. A reference the stream lacks
//! (VPEV_MISSING) is grey. A picture due (VPEV_SHOW) is queued to be
//! shown; one the stream let go of (VPEV_FREE) is given back once nothing
//! reads it (`giveBack`).
//!
//! With other cores (`useCores`) a picture is decoded by a worker
//! instead, while the decoder goes on with the events after it: it hands
//! each segment over with its slice's lists. The worker counts the luma
//! rows that are final; a picture that refers to one waits for the rows
//! each block reads. So as many pictures are decoded at once as there
//! are workers, each a little behind the one before; a store a worker
//! reads is given back once it is done.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const bits_mod = @import("bits.zig");
pub const Error = bits_mod.Error;
const params = @import("params.zig");
const slice_mod = @import("slice.zig");
const Header = slice_mod.Header;
const common = @import("common.zig");
const Env = common.Env;
const Store = common.Store;
const dpb_mod = @import("dpb.zig");
const picture = @import("picture.zig");
const transform = @import("transform.zig");
const ctu = @import("ctu.zig");
const filter = @import("filter.zig");

/// What decodes the CTUs of a picture and filters them: the decoder's
/// own, or a job's.
const Ctx = struct {
    st: ctu.State = .{},
    info: picture.Info = .{},
    filter: filter.Filter = .{},
    /// What the arrays were made for, beyond the picture's size.
    depth_y: u5 = 0,
    depth_c: u5 = 0,
    chroma_format: u2 = 0,
    /// The CTB rows decoded, from the top.
    decoded: u32 = 0,
    wide: bool = false,
    /// Told when rows are final, for those who wait for them.
    cores: ?*const common.Cores = null,

    /// The arrays for pictures of `sps`, made anew when they do not fit.
    fn fit(c: *Ctx, env: Env, sps: *const params.Sps) bool {
        if (c.info.fits(sps) and c.depth_y == sps.bit_depth_luma and c.depth_c == sps.bit_depth_chroma and
            c.chroma_format == sps.chroma_format_idc) return true;
        c.free(env);
        if (!c.info.alloc(env, sps) or !c.filter.alloc(env, sps)) {
            c.free(env);
            return false;
        }
        c.depth_y = @intCast(sps.bit_depth_luma);
        c.depth_c = @intCast(sps.bit_depth_chroma);
        c.chroma_format = @intCast(sps.chroma_format_idc);
        c.wide = sps.bit_depth_luma > 8 or sps.bit_depth_chroma > 8;
        return true;
    }

    fn free(c: *Ctx, env: Env) void {
        c.info.free(env);
        c.filter.free(env);
        c.depth_y = 0;
    }

    /// Ready for the picture `s` of `sps` and `pps`.
    fn begin(c: *Ctx, sps: *const params.Sps, pps: *const params.Pps, scales: *const transform.Scales, s: *Store, sync: ?*const common.Sync) void {
        c.info.begin(pps);
        c.filter.begin(sps, pps, &c.info, s);
        c.decoded = 0;
        c.st.sps = sps;
        c.st.pps = pps;
        c.st.info = &c.info;
        c.st.store = s;
        c.st.scales = scales;
        c.st.sync = sync;
        c.st.on_row = onRow;
        // The contexts kept for a wavefront row or a dependent segment,
        // which a segment that broke off may not have kept: nothing of an
        // earlier picture, the same alone as on any worker.
        @memset(&c.st.wpp_ctx, 0);
        @memset(&c.st.ds_ctx, 0);
        c.st.wpp_stat = .{ 0, 0, 0, 0 };
        c.st.ds_stat = .{ 0, 0, 0, 0 };
    }

    /// A CTB row whole: as many rows filtered as that allows.
    fn onRow(st: *ctu.State) void {
        const c: *Ctx = @fieldParentPtr("st", st);
        const info = &c.info;
        while (c.decoded < info.hctb and info.row_done[c.decoded] == info.wctb) c.decoded += 1;
        c.advance();
    }

    fn advance(c: *Ctx) void {
        const before = c.filter.finished;
        if (c.wide) filter.Loop(u16).advance(&c.filter, c.decoded) else filter.Loop(u8).advance(&c.filter, c.decoded);
        if (c.filter.finished != before) {
            if (c.cores) |k| k.wake(k.ctx);
        }
    }

    /// The slice segment `hdr` of the slice `idx`, its RBSP `rbsp`.
    fn segment(c: *Ctx, hdr: *const Header, lists: *const picture.Lists, sl: *const picture.SliceInfo, idx: u16, rbsp: []const u8) Error!void {
        const info = &c.info;
        if (idx >= info.slices.len or hdr.data_offset > rbsp.len) return error.Corrupt;
        // The slice's even when the segment is passed over, for the
        // dependent segments after it - those of a slice not begun are.
        if (!hdr.dependent) {
            info.slices[idx] = sl.*;
            info.num_slices = @as(u32, idx) + 1;
        } else if (idx >= info.num_slices) return error.Corrupt;
        // A segment over CTBs decoded before is passed over.
        if (info.ctb_slice[hdr.segment_address] != picture.Info.no_slice) return error.Corrupt;
        c.st.hdr = hdr;
        c.st.lists = lists;
        c.st.slice_idx = idx;
        const data = rbsp[hdr.data_offset..];
        if (c.wide) try ctu.Decode(u16).segment(&c.st, data) else try ctu.Decode(u8).segment(&c.st, data);
    }

    /// All segments in: the CTBs none brought, and those whose decoding
    /// broke off, concealed - from `src`, the picture decoded before, or
    /// grey - and every row filtered.
    fn finish(c: *Ctx, s: *Store, last: ?*Store, sync: ?*const common.Sync) void {
        const info = &c.info;
        var src = last;
        if (src) |r| {
            if (r == s or r.memory_len != s.memory_len) src = null;
        }
        var waited = false;
        for (info.ctb_slice, info.broken, 0..) |si, broken, rs| {
            if (si != picture.Info.no_slice and !broken) continue;
            s.damaged = true;
            if (src) |r| {
                if (sync != null and !waited) sync.?.rows(r, r.height[0]);
                waited = true;
            }
            concealCtb(c, s, src, @intCast(rs));
        }
        c.decoded = info.hctb;
        c.advance();
    }
};

/// CTB `rs` where no segment brought it: `src`'s samples there, or grey.
fn concealCtb(c: *const Ctx, s: *Store, src: ?*const Store, rs: u32) void {
    const info = &c.info;
    const size: usize = if (c.wide) 2 else 1;
    const ctb = @as(u32, 1) << info.log2_ctb;
    for (0..3) |p| {
        const sw: u5 = if (p == 0 or s.width[p] == s.width[0]) 0 else 1;
        const sh: u5 = if (p == 0 or s.height[p] == s.height[0]) 0 else 1;
        const x0 = ((rs % info.wctb) * ctb) >> sw;
        const y0 = ((rs / info.wctb) * ctb) >> sh;
        if (x0 >= s.width[p] or y0 >= s.height[p]) continue;
        const w = @min(ctb >> sw, s.width[p] - x0);
        const h = @min(ctb >> sh, s.height[p] - y0);
        const depth = if (p == 0) c.depth_y else c.depth_c;
        // A picture without chroma keeps its grey.
        if (p > 0 and c.chroma_format == 0) break;
        for (0..h) |r| {
            const o = ((y0 + r) * s.stride[p] + x0) * size;
            const dst = s.planes[p] + o;
            if (src) |sr| {
                @memcpy(dst[0 .. w * size], (sr.planes[p] + o)[0 .. w * size]);
            } else if (c.wide) {
                const d16: [*]u16 = @ptrCast(@alignCast(dst));
                @memset(d16[0..w], @as(u16, 1) << @intCast(depth - 1));
            } else @memset(dst[0..w], 128);
        }
    }
}

/// How many of a picture's segments wait for its worker at most; the
/// decoder waits for room when there are more.
const job_slices = 8;
/// Workers used at most.
const max_jobs = 8;

comptime {
    // A job's stores are bits of a u64.
    if (dpb_mod.max_stores > 64) @compileError("too many stores for Job.pins");
}

/// A slice segment handed to a job: its header, its slice's lists and
/// what the filters need of the slice, and a copy of its RBSP.
const Posted = struct {
    hdr: Header = .{},
    lists: picture.Lists = .{},
    slice: picture.SliceInfo = .{},
    slice_idx: u16 = 0,
    rbsp: []u8 = &.{},
    len: usize = 0,
};

/// A picture decoded by a worker while the decoder goes on with the units
/// after it, its segments handed over as they come. The worker conceals
/// what no segment brought, filters the rows as they are decoded, and
/// counts the rows that are final in the store's `progress`.
const Job = struct {
    dec: *Decoder,
    sync: common.Sync,
    // The decoder's: whether it runs, which began first, and the stores
    // it reads, by their place in the buffer.
    active: bool = false,
    order: u32 = 0,
    pins: u64 = 0,
    // What it decodes with: the decoder's as the picture began.
    ctx: Ctx = .{},
    sps: params.Sps = .{},
    pps: params.Pps = .{},
    scales: transform.Scales = .{},
    store: *Store = undefined,
    last: ?*Store = null,
    slices: [job_slices]Posted = @splat(.{}),
    // Counted by both: the segments handed over and those decoded;
    // whether the picture has all its segments, and whether it is done.
    posted: u32 = 0,
    taken: u32 = 0,
    closed: bool = false,
    done: bool = false,
    // The worker's: the segments that ended in an error.
    errors: u32 = 0,

    /// The worker's part: the segments as they come, then the rest.
    fn run(arg: *anyopaque) void {
        const j: *Job = @ptrCast(@alignCast(arg));
        const c = j.sync.cores;
        const who = j.sync.who;
        while (true) {
            const taken = j.taken;
            if (@atomicLoad(u32, &j.posted, .acquire) != taken) {
                const p = &j.slices[taken % job_slices];
                j.ctx.segment(&p.hdr, &p.lists, &p.slice, p.slice_idx, p.rbsp[0..p.len]) catch {
                    j.store.damaged = true;
                    j.errors += 1;
                };
                @atomicStore(u32, &j.taken, taken + 1, .seq_cst);
                c.wake(c.ctx);
                continue;
            }
            if (@atomicLoad(bool, &j.closed, .acquire) and @atomicLoad(u32, &j.posted, .acquire) == taken) break;
            c.arm(c.ctx, who);
            if (@atomicLoad(u32, &j.posted, .seq_cst) != taken or @atomicLoad(bool, &j.closed, .seq_cst)) continue;
            c.sleep(c.ctx, who);
        }
        j.ctx.finish(j.store, j.last, &j.sync);
        @atomicStore(bool, &j.done, true, .seq_cst);
        c.wake(c.ctx);
    }
};

pub const Decoder = struct {
    env: Env,
    stores: dpb_mod.Stores = .{},

    // --- the active parameter sets and what follows from them ---
    /// The sequence's and the picture's, copied as each began.
    sps: params.Sps = .{},
    pps: params.Pps = .{},
    /// The sequence being decoded: null before the first.
    active_sps: ?*const params.Sps = null,
    depth_y: u5 = 8,
    depth_c: u5 = 8,
    wide: bool = false,
    scales: transform.Scales = .{},
    /// The decoder's own CTU decoder and filters.
    own: Ctx = .{},

    // --- the picture being decoded ---
    /// What VPEV_PICTURE said of it.
    said: vp.VideoPicture = .{},
    cur: ?*Store = null,
    /// The lists of its slice the last independent segment began.
    lists: picture.Lists = .{},
    num_slices: u16 = 0,
    /// The picture decoded last: what concealment copies. Kept from being
    /// given back while the current picture may need it (`last_kept`).
    last_pic: ?*Store = null,
    last_kept: ?*Store = null,

    // --- scratch ---
    /// Segments that ended in an error.
    slice_errors: u32 = 0,

    // --- the other cores ---
    cores: ?*const common.Cores = null,
    jobs: [max_jobs]?*Job = @splat(null),
    /// The job decoding the current picture: null while the decoder does.
    job: ?*Job = null,
    job_order: u32 = 0,
    /// The end was said: a picture still being decoded is waited for.
    flushing: bool = false,
    /// The last picture began is a worker's.
    on_workers: bool = false,

    /// A decoder with nothing decoded, in memory `env` gives.
    pub fn create(env: Env) ?*Decoder {
        const bytes = env.alloc(env.ctx, @sizeOf(Decoder), false) orelse return null;
        const dec: *Decoder = @ptrCast(@alignCast(bytes));
        dec.* = .{ .env = env };
        return dec;
    }

    /// Pictures decoded on `cores` from now on, as many at once as it has
    /// workers.
    pub fn useCores(dec: *Decoder, cores: *const common.Cores) void {
        dec.cores = cores;
    }

    pub fn destroy(dec: *Decoder) void {
        const env = dec.env;
        dec.drain();
        for (dec.jobs) |slot| {
            const j = slot orelse continue;
            j.ctx.free(env);
            for (&j.slices) |*p| env.freeSlice(u8, p.rbsp);
            env.free(env.ctx, @ptrCast(j), @sizeOf(Job));
        }
        for (&dec.stores.stores) |*s| freeStoreMemory(dec, s);
        dec.own.free(env);
        env.free(env.ctx, @ptrCast(dec), @sizeOf(Decoder));
    }

    // --- events ----------------------------------------------------------------

    /// One of the library's events. An error is the event's picture's or
    /// segment's: the picture is concealed where it lacks, and the next
    /// event is taken as before.
    pub fn event(dec: *Decoder, e: *const vp.VideoEvent) Error!void {
        dec.flushing = false;
        switch (e.kind) {
            vp.VPEV_SEQUENCE => try dec.activate(e.sequence.?),
            vp.VPEV_MISSING => try dec.missing(e.picture.?),
            vp.VPEV_PICTURE => try dec.beginPicture(e.picture.?),
            vp.VPEV_SLICE => try dec.segment(e.slice.?),
            vp.VPEV_DECODE => dec.finishPicture(),
            vp.VPEV_SHOW => dec.stores.show(e.slot, e.time),
            vp.VPEV_FREE => dec.stores.free(e.slot),
            else => {},
        }
    }

    /// A slot to give back to the library (ReleaseVideoSlot), or null:
    /// one the stream let go of, shown and read by no worker.
    pub fn giveBack(dec: *Decoder) ?u32 {
        if (dec.cores != null) dec.retire();
        return dec.stores.giveBack();
    }

    /// The library ran out of slots (VPERR_FULL), which it says between
    /// pictures: until the worker begun first is done, and its stores with
    /// it. False when no worker runs: the slots are the pictures waiting
    /// to be shown, which are to be taken first.
    pub fn makeRoom(dec: *Decoder) bool {
        return dec.retireOldest();
    }

    /// The stream's end was said (VPERR_END): the pictures still being
    /// decoded are waited for when they are asked for.
    pub fn endOfStream(dec: *Decoder) void {
        dec.flushing = true;
    }

    /// The next picture to show, or null. It stays valid until `release`.
    /// While the pictures are workers' and that one is still decoded, null
    /// once a worker is free - waited for when none is - so that the events
    /// after it keep the workers busy, as long as no more pictures wait to
    /// be shown than there are workers; past that, and at the end, the
    /// picture is waited for.
    pub fn next(dec: *Decoder) ?*Store {
        const s = dec.stores.peekOutput() orelse return null;
        if (!dec.flushing and dec.on_workers and dec.stores.out_count <= dec.cores.?.workers and
            @atomicLoad(u32, &s.progress, .acquire) < s.height[0])
        {
            if (dec.idle()) return null;
            dec.retireAny();
            if (@atomicLoad(u32, &s.progress, .acquire) < s.height[0]) return null;
        }
        dec.finished(s);
        return s;
    }

    pub fn release(dec: *Decoder) void {
        dec.stores.taken();
    }

    /// Everything dropped, for a seek, as the library drops it
    /// (ResetVideoParser): every store the decoder holds is given back
    /// (`giveBack`) once no worker reads it.
    pub fn reset(dec: *Decoder) void {
        dec.drain();
        dec.releaseLast();
        dec.flushing = false;
        dec.cur = null;
        dec.last_pic = null;
        dec.stores.forget();
    }

    // --- pictures --------------------------------------------------------------

    /// The sequence `seq` made the active one: the arrays made for its
    /// pictures when they changed, once the workers are done with the last
    /// one's.
    fn activate(dec: *Decoder, seq: *const vp.VideoSequence) Error!void {
        const sps = seq.hevc_sps orelse return error.Corrupt;
        dec.sps = sps.*;
        dec.active_sps = &dec.sps;
        const own = &dec.own;
        if (own.info.fits(sps) and own.depth_y == sps.bit_depth_luma and own.depth_c == sps.bit_depth_chroma and
            own.chroma_format == sps.chroma_format_idc) return;
        dec.drain();
        dec.releaseLast();
        dec.last_pic = null;
        if (!own.fit(dec.env, &dec.sps)) return error.NoMemory;
        dec.depth_y = @intCast(sps.bit_depth_luma);
        dec.depth_c = @intCast(sps.bit_depth_chroma);
        dec.wide = own.wide;
    }

    fn freeStoreMemory(dec: *Decoder, s: *Store) void {
        if (s.memory) |m| dec.env.free(dec.env.ctx, m, s.memory_len);
        s.memory = null;
        s.memory_len = 0;
        dec.env.freeSlice(common.Motion, s.motion);
        s.motion = &.{};
    }

    /// A store's samples and motion for the active sequence, and how it
    /// is shown.
    fn prepareStore(dec: *Decoder, s: *Store) Error!void {
        const sps = dec.active_sps orelse return error.Corrupt;
        const w = sps.width;
        const h = sps.height;
        var cw: u32 = w;
        var ch: u32 = h;
        switch (sps.chroma_format_idc) {
            0, 1 => {
                cw = w / 2;
                ch = h / 2;
            },
            2 => cw = w / 2,
            else => {},
        }
        const size: usize = if (dec.wide) 2 else 1;
        const luma = @as(usize, w) * h;
        const chroma = @as(usize, cw) * ch;
        const len = (luma + 2 * chroma) * size;
        const blocks = @as(usize, (w + 15) >> 4) * ((h + 15) >> 4);
        const grey = sps.chroma_format_idc == 0;
        if (s.memory == null or s.memory_len != len or s.width[0] != w or s.width[1] != cw or s.height[0] != h or s.motion.len != blocks) {
            freeStoreMemory(dec, s);
            const m = dec.env.alloc(dec.env.ctx, len, false) orelse return error.NoMemory;
            s.memory = m;
            s.memory_len = len;
            s.motion = dec.env.slice(common.Motion, blocks) orelse {
                freeStoreMemory(dec, s);
                return error.NoMemory;
            };
            s.planes = .{ m, m + luma * size, m + (luma + chroma) * size };
            s.stride = .{ w, cw, cw };
            s.width = .{ w, cw, cw };
            s.height = .{ h, ch, ch };
        }
        if (grey) {
            // No chroma: grey, as it is shown.
            const g: u16 = @as(u16, 1) << @intCast(sps.bit_depth_chroma - 1);
            if (dec.wide) {
                const c: [*]u16 = @ptrCast(@alignCast(s.planes[1]));
                @memset(c[0 .. 2 * chroma], g);
            } else @memset(s.planes[1][0 .. 2 * chroma], @intCast(g));
        }
        s.format = .{
            .x = sps.cropX(),
            .y = sps.cropY(),
            .width = sps.croppedWidth(),
            .height = sps.croppedHeight(),
            .chroma_format = @intCast(sps.chroma_format_idc),
            .depth_y = @intCast(sps.bit_depth_luma),
            .depth_c = @intCast(sps.bit_depth_chroma),
            .matrix = sps.matrix,
            .primaries = sps.colour_primaries,
            .transfer = sps.transfer,
            .full_range = sps.full_range,
            .peak_nits = dec.said.peak_nits,
        };
    }

    /// A picture said: its slot the decoder's, its parameter sets copied
    /// - a worker decodes with its own copy of them - and it begun: on a
    /// worker, or by the decoder itself once the workers are done.
    fn beginPicture(dec: *Decoder, pic: *const vp.VideoPicture) Error!void {
        dec.finishPicture();
        dec.said = pic.*;
        if (pic.hevc_sps) |sps| dec.sps = sps.*;
        if (pic.hevc_pps) |pps| dec.pps = pps.*;
        const s = dec.stores.take(pic.slot);
        if (dec.active_sps == null) return error.Corrupt;
        const sps = &dec.sps;
        const pps = &dec.pps;
        const job = if (dec.parallel()) try dec.freeJob(sps) else null;
        if (job == null) dec.drain();
        dec.on_workers = job != null;
        dec.keepLast();
        dec.scales.init(if (!sps.scaling_enabled) null else if (pps.scaling_present) &pps.scaling else &sps.scaling);
        try dec.prepareStore(s);
        s.uid = pic.uid;
        s.poc = pic.poc[0];
        s.generated = false;
        s.time = pic.time;
        s.damaged = false;
        s.progress = 0;
        @memset(s.motion, .{});
        dec.cur = s;
        dec.num_slices = 0;
        if (job) |j| dec.begin(j, s, sps, pps) else dec.own.begin(sps, pps, &dec.scales, s, null);
    }

    /// A reference the stream lacks (8.3.3): grey, intra, never shown,
    /// referred to as if it were there.
    fn missing(dec: *Decoder, pic: *const vp.VideoPicture) Error!void {
        dec.finishPicture();
        const s = dec.stores.take(pic.slot);
        try dec.prepareStore(s);
        s.uid = pic.uid;
        s.poc = pic.poc[0];
        s.generated = true;
        s.damaged = true;
        s.time = 0;
        @memset(s.motion, .{});
        const sps = dec.active_sps.?;
        for (0..3) |p| {
            const depth = if (p == 0) sps.bit_depth_luma else sps.bit_depth_chroma;
            const n = s.height[p] * s.stride[p];
            if (dec.wide) {
                const d: [*]u16 = @ptrCast(@alignCast(s.planes[p]));
                @memset(d[0..n], @as(u16, 1) << @intCast(depth - 1));
            } else @memset(s.planes[p][0..n], 128);
        }
        s.progress = s.height[0];
    }

    /// A slice segment of the current picture: decoded, or handed to its
    /// worker.
    fn segment(dec: *Decoder, sl: *const vp.VideoSlice) Error!void {
        const hdr = sl.hevc orelse return error.Corrupt;
        const s = dec.cur orelse return error.Corrupt;
        if (!hdr.dependent) {
            if (dec.num_slices == 0xffff) return error.Corrupt;
            dec.num_slices += 1;
            dec.listsOf(sl, s);
        } else if (dec.num_slices == 0) return error.Corrupt;
        const idx = dec.num_slices - 1;
        const info: picture.SliceInfo = .{
            .addr = hdr.slice_addr,
            .beta = hdr.beta_offset,
            .tc = hdr.tc_offset,
            .deblock = !hdr.deblocking_disabled,
            .across = hdr.loop_filter_across_slices,
            .sao_luma = hdr.sao_luma,
            .sao_chroma = hdr.sao_chroma,
        };
        const rbsp = sl.rbsp[0..sl.rbsp_bytes];
        if (dec.job) |j| return dec.post(j, hdr, &info, idx, rbsp);
        dec.own.segment(hdr, &dec.lists, &info, idx, rbsp) catch |e| {
            s.damaged = true;
            dec.slice_errors += 1;
            if (e == error.NoMemory) return e;
        };
    }

    /// A slice's lists as the decoding takes them: each entry's store,
    /// the collocated picture's, and NoBackwardPredFlag (8.3.5).
    fn listsOf(dec: *Decoder, sl: *const vp.VideoSlice, cur: *const Store) void {
        const lists = &dec.lists;
        lists.* = .{};
        for (0..2) |l| {
            const n = @min(sl.count[l], lists.refs[l].len);
            for (lists.refs[l][0..n], sl.lists[l][0..n]) |*ref, *entry| {
                ref.* = .{ .store = dec.storeOf(entry.slot), .poc = entry.poc[0], .long = entry.long_term, .id = entry.slot };
                if (ref.poc > cur.poc) lists.no_backward = false;
            }
            lists.count[l] = @intCast(n);
        }
        lists.col = dec.storeOf(sl.collocated);
    }

    /// The store of a slot a list names, when it holds a picture.
    fn storeOf(dec: *Decoder, slot: u8) ?*Store {
        if (slot >= dpb_mod.max_stores) return null;
        const s = dec.stores.at(slot);
        if (!s.held or s.memory == null) return null;
        return s;
    }

    /// The picture being decoded finished: concealed where segments were
    /// missing and filtered, by its worker or here.
    fn finishPicture(dec: *Decoder) void {
        const s = dec.cur orelse return;
        dec.cur = null;
        if (dec.job != null) {
            // Its worker conceals and filters it.
            dec.close();
        } else dec.own.finish(s, dec.last_pic, null);
        dec.releaseLast();
        dec.last_pic = s;
    }

    /// The picture decoded last kept from being given back while the next
    /// one may be concealed from it - alone as on the workers, whose job
    /// holds it too.
    fn keepLast(dec: *Decoder) void {
        dec.releaseLast();
        const l = dec.last_pic orelse return;
        l.pinned += 1;
        dec.last_kept = l;
    }

    fn releaseLast(dec: *Decoder) void {
        const l = dec.last_kept orelse return;
        l.pinned -= 1;
        dec.last_kept = null;
    }

    // --- the workers ------------------------------------------------------------

    fn parallel(dec: *const Decoder) bool {
        const c = dec.cores orelse return false;
        return c.workers > 0;
    }

    /// A job for the next picture, its arrays made for `sps`: one that
    /// never ran, one done, or the one begun first once it is done. Null
    /// without the memory for a new one.
    fn freeJob(dec: *Decoder, sps: *const params.Sps) Error!?*Job {
        const c = dec.cores.?;
        const n = @min(c.workers, max_jobs);
        dec.retire();
        const j = find: while (true) {
            for (dec.jobs[0..n], 0..) |*slot, i| {
                if (slot.*) |j| {
                    if (!j.active) break :find j;
                    continue;
                }
                const bytes = dec.env.alloc(dec.env.ctx, @sizeOf(Job), false) orelse return null;
                const j: *Job = @ptrCast(@alignCast(bytes));
                j.* = .{ .dec = dec, .sync = .{ .cores = c, .who = @intCast(i) } };
                slot.* = j;
                break :find j;
            }
            dec.retireAny();
        };
        if (!j.ctx.fit(dec.env, sps)) return null;
        return j;
    }

    /// The current picture `s` handed to `j`'s worker.
    fn begin(dec: *Decoder, j: *Job, s: *Store, sps: *const params.Sps, pps: *const params.Pps) void {
        j.sps = sps.*;
        j.pps = pps.*;
        j.scales = dec.scales;
        j.store = s;
        j.last = dec.last_pic;
        j.ctx.cores = dec.cores;
        j.ctx.begin(&j.sps, &j.pps, &j.scales, s, &j.sync);
        j.posted = 0;
        j.taken = 0;
        j.closed = false;
        j.done = false;
        j.errors = 0;
        j.active = true;
        j.order = dec.job_order;
        dec.job_order +%= 1;
        dec.pin(j, s);
        if (j.last) |r| dec.pin(j, r);
        dec.job = j;
        const c = dec.cores.?;
        c.run(c.ctx, j.sync.who, Job.run, j);
    }

    /// A segment of the current picture handed to its worker, once there
    /// is room: its header, its slice's lists and a copy of its RBSP.
    fn post(dec: *Decoder, j: *Job, hdr: *const Header, info: *const picture.SliceInfo, idx: u16, rbsp: []const u8) Error!void {
        for (0..2) |l| {
            for (dec.lists.refs[l][0..dec.lists.count[l]]) |r| {
                if (r.store) |rs| dec.pin(j, rs);
            }
        }
        if (dec.lists.col) |col| dec.pin(j, col);
        const c = dec.cores.?;
        const posted = j.posted;
        while (posted - @atomicLoad(u32, &j.taken, .acquire) >= job_slices) {
            c.arm(c.ctx, c.workers);
            if (posted - @atomicLoad(u32, &j.taken, .seq_cst) < job_slices) break;
            c.sleep(c.ctx, c.workers);
        }
        const p = &j.slices[posted % job_slices];
        if (p.rbsp.len < rbsp.len) {
            // Room for the segments of a picture that comes later too.
            dec.env.freeSlice(u8, p.rbsp);
            p.rbsp = &.{};
            p.rbsp = dec.env.slice(u8, rbsp.len + rbsp.len / 2 + 64) orelse return error.NoMemory;
        }
        @memcpy(p.rbsp[0..rbsp.len], rbsp);
        p.hdr = hdr.*;
        p.lists = dec.lists;
        p.slice = info.*;
        p.slice_idx = idx;
        p.len = rbsp.len;
        @atomicStore(u32, &j.posted, posted + 1, .seq_cst);
        c.wake(c.ctx);
    }

    /// `s` read by `j`: not given back before `j` is done.
    fn pin(dec: *Decoder, j: *Job, s: *Store) void {
        const bit = @as(u64, 1) << @intCast(dec.stores.slotOf(s));
        if (j.pins & bit != 0) return;
        j.pins |= bit;
        s.pinned += 1;
    }

    /// The current picture's worker told it has all its segments.
    fn close(dec: *Decoder) void {
        const j = dec.job orelse return;
        dec.job = null;
        @atomicStore(bool, &j.closed, true, .seq_cst);
        const c = dec.cores.?;
        c.wake(c.ctx);
    }

    /// The jobs that are done given back their stores.
    fn retire(dec: *Decoder) void {
        for (dec.jobs) |slot| {
            const j = slot orelse continue;
            if (j.active and @atomicLoad(bool, &j.done, .acquire)) dec.retireJob(j);
        }
    }

    fn retireJob(dec: *Decoder, j: *Job) void {
        var pins = j.pins;
        while (pins != 0) : (pins &= pins - 1) dec.stores.stores[@ctz(pins)].pinned -= 1;
        j.pins = 0;
        j.active = false;
        dec.slice_errors += j.errors;
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
        dec.retireJob(j);
        return true;
    }

    /// Until some job is done, which is then retired.
    fn retireAny(dec: *Decoder) void {
        const c = dec.cores.?;
        while (true) {
            c.arm(c.ctx, c.workers);
            for (dec.jobs) |slot| {
                const j = slot orelse continue;
                if (j.active and @atomicLoad(bool, &j.done, .seq_cst)) return dec.retireJob(j);
            }
            c.sleep(c.ctx, c.workers);
        }
    }

    /// Every job done: the decoder goes on alone.
    fn drain(dec: *Decoder) void {
        dec.close();
        while (dec.retireOldest()) {}
    }

    /// Whether a worker has nothing to do.
    fn idle(dec: *Decoder) bool {
        const c = dec.cores orelse return false;
        dec.retire();
        for (dec.jobs[0..@min(c.workers, max_jobs)]) |slot| {
            const j = slot orelse return true;
            if (!j.active) return true;
        }
        return false;
    }

    /// Until every row of `s` is final.
    fn finished(dec: *Decoder, s: *const Store) void {
        const rows = s.height[0];
        if (@atomicLoad(u32, &s.progress, .acquire) >= rows) return;
        const c = dec.cores orelse return;
        const sy: common.Sync = .{ .cores = c, .who = c.workers };
        sy.rows(s, rows);
    }
};
