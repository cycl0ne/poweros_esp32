// SPDX-License-Identifier: MIT
//! The decoder: NAL units in, pictures out in the order they are shown.
//!
//! A picture begins with its first slice segment: its order count, its
//! reference picture set marking the references, the pictures shown
//! before it is decoded, and its store. Each segment's CTUs are decoded
//! into the store as they come; a CTB row that is whole is deblocked and
//! all but its last few lines get their sample adaptive offset. When the
//! next picture begins (or the access unit or the
//! stream ends) the CTBs no segment brought are concealed, the rest of
//! the rows filtered, and the picture goes into the decoded picture
//! buffer, which gives the pictures out in their order.
//!
//! With other cores (`useCores`) a picture is decoded by a worker
//! instead, while the decoder goes on with the units after it: it parses
//! the slice headers, marks the references, builds the lists and hands
//! each segment over. The worker counts the luma rows that are final; a
//! picture that refers to one waits for the rows each block reads. So as
//! many pictures are decoded at once as there are workers, each a little
//! behind the one before.

const bits_mod = @import("bits.zig");
const Bits = bits_mod.Bits;
pub const Error = bits_mod.Error;
const nal = @import("nal.zig");
const params = @import("params.zig");
const slice_mod = @import("slice.zig");
const Header = slice_mod.Header;
const common = @import("common.zig");
const Env = common.Env;
const Store = common.Store;
const dpb_mod = @import("dpb.zig");
const Dpb = dpb_mod.Dpb;
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
        c.depth_y = sps.bit_depth_luma;
        c.depth_c = sps.bit_depth_chroma;
        c.chroma_format = sps.chroma_format_idc;
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
/// what the filters need of the slice, and its RBSP.
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
    limits: params.Limits = .{},
    sps: [16]params.Sps = @splat(.{}),
    pps: [64]params.Pps = @splat(.{}),
    dpb: Dpb = .{},

    // --- the active parameter sets and what follows from them ---
    active_sps: ?*const params.Sps = null,
    active_pps: ?*const params.Pps = null,
    depth_y: u5 = 8,
    depth_c: u5 = 8,
    wide: bool = false,
    scales: transform.Scales = .{},
    /// The decoder's own CTU decoder and filters.
    own: Ctx = .{},

    // --- the picture being decoded ---
    cur: ?*Store = null,
    /// PicOutputFlag.
    cur_output: bool = true,
    rps: dpb_mod.Rps = .{},
    /// The header of the slice's independent segment, and its lists.
    indep: Header = .{},
    lists: picture.Lists = .{},
    num_slices: u16 = 0,
    /// The picture decoded last: what concealment copies. Kept from being
    /// used again while the current picture may need it (`last_kept`).
    last_pic: ?*Store = null,
    last_kept: ?*Store = null,
    /// The light the film was mastered for, in candelas a square metre,
    /// as the last prefix SEI said; 0 until one does.
    peak_nits: u16 = 0,
    /// The picture the last slice segment was of, which a suffix SEI
    /// unit belongs to: null when that picture was passed over.
    sei_pic: ?*Store = null,

    // --- scratch ---
    hdr: Header = .{},
    rbsp: []u8 = &.{},
    time: i64 = 0,
    /// Segments that ended in an error.
    slice_errors: u32 = 0,

    // --- the other cores ---
    cores: ?*const common.Cores = null,
    jobs: [max_jobs]?*Job = @splat(null),
    /// The job decoding the current picture: null while the decoder does.
    job: ?*Job = null,
    job_order: u32 = 0,
    /// The end was sent: a picture still being decoded is waited for.
    flushing: bool = false,
    /// The last picture began is a worker's.
    on_workers: bool = false,
    /// The last picture was finished at the end of its access unit
    /// (`endPicture`): a segment that does not begin another is passed
    /// over.
    ended_early: bool = false,

    /// A decoder with nothing decoded, in memory `env` gives.
    pub fn create(env: Env, limits: params.Limits) ?*Decoder {
        const bytes = env.alloc(env.ctx, @sizeOf(Decoder), false) orelse return null;
        const dec: *Decoder = @ptrCast(@alignCast(bytes));
        dec.* = .{ .env = env, .limits = limits };
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
        for (&dec.dpb.stores) |*s| freeStoreMemory(dec, s);
        dec.own.free(env);
        env.freeSlice(u8, dec.rbsp);
        env.free(env.ctx, @ptrCast(dec), @sizeOf(Decoder));
    }

    // --- units ---------------------------------------------------------------

    /// One NAL unit (without start code or length), from a packet shown
    /// at `time`.
    pub fn decodeUnit(dec: *Decoder, unit: []const u8, time: i64) Error!void {
        if (unit.len < 2) return;
        dec.flushing = false;
        const h = try nal.header(unit);
        // The layers above the base one are another decoder's.
        if (h.layer != 0) return;
        if (!h.isSlice()) dec.ended_early = false;
        switch (h.kind) {
            nal.Type.sps => {
                dec.finishPicture();
                const n = try dec.unescape(unit[2..]);
                var b = Bits.init(dec.rbsp[0..n]);
                var s: params.Sps = .{};
                const id = try params.parseSps(&b, &s, dec.limits);
                if (id >= 16) return error.Corrupt;
                dec.sps[id] = s;
            },
            nal.Type.pps => {
                dec.finishPicture();
                const n = try dec.unescape(unit[2..]);
                var b = Bits.init(dec.rbsp[0..n]);
                var peek = b;
                _ = try peek.ue();
                const sps_id = try peek.ueMax(15);
                var p: params.Pps = .{};
                const id = try params.parsePps(&b, &p, if (dec.sps[sps_id].valid) &dec.sps[sps_id] else null);
                if (id >= 64) return error.Corrupt;
                dec.pps[id] = p;
            },
            nal.Type.prefix_sei => {
                dec.finishPicture();
                const n = try dec.unescape(unit[2..]);
                dec.prefixSei(dec.rbsp[0..n]);
            },
            nal.Type.vps, nal.Type.aud, 41...44, 48...55 => dec.finishPicture(),
            nal.Type.end_of_seq, nal.Type.end_of_stream => {
                dec.finishPicture();
                dec.dpb.first = true;
            },
            nal.Type.suffix_sei => {
                const n = try dec.unescape(unit[2..]);
                dec.suffixSei(dec.rbsp[0..n]);
            },
            else => {
                if (!h.isSlice()) return;
                const n = try dec.unescape(unit[2..]);
                dec.time = time;
                try dec.segment(dec.rbsp[0..n], h);
            },
        }
    }

    /// The access unit ended - a packet of an MP4 or Matroska track is
    /// one - so the picture is finished now rather than when the next one
    /// begins: its worker is done sooner.
    pub fn endPicture(dec: *Decoder) void {
        if (dec.cur == null) return;
        dec.finishPicture();
        dec.ended_early = true;
    }

    /// Everything decoded and every picture put out to be shown.
    pub fn flush(dec: *Decoder) void {
        dec.finishPicture();
        dec.dpb.flush();
        dec.flushing = true;
    }

    /// The next picture to show, or null. It stays valid until `release`.
    /// While the pictures are workers' and that one is still decoded, null
    /// once a worker is free - waited for when none is - so that the units
    /// after it keep the workers busy, as long as no more pictures wait to
    /// be shown than there are workers; past that, and once flushed, the
    /// picture is waited for.
    pub fn next(dec: *Decoder) ?*Store {
        const s = dec.dpb.peekOutput() orelse return null;
        if (!dec.flushing and dec.on_workers and dec.dpb.out_count <= dec.cores.?.workers and
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
        dec.dpb.taken();
    }

    /// Everything dropped, for a seek: the next picture should be an IRAP
    /// picture.
    pub fn reset(dec: *Decoder) void {
        dec.drain();
        dec.releaseLast();
        dec.flushing = false;
        dec.cur = null;
        dec.last_pic = null;
        dec.sei_pic = null;
        while (dec.dpb.peekOutput() != null) dec.dpb.taken();
        dec.dpb.reset();
    }

    fn unescape(dec: *Decoder, payload: []const u8) Error!usize {
        if (dec.rbsp.len < payload.len + 8) {
            dec.env.freeSlice(u8, dec.rbsp);
            dec.rbsp = &.{};
            dec.rbsp = dec.env.slice(u8, payload.len + 64) orelse return error.NoMemory;
        }
        return nal.unescape(payload, dec.rbsp);
    }

    /// A prefix SEI unit: the light the film was mastered for, which is
    /// what a screen's own range has to be mapped from (D.2.28, the
    /// mastering display's colour volume, and D.2.35, the content light
    /// level). The mastering display's maximum is taken, and the
    /// brightest pixel in the film where it says that too and it is
    /// lower - a film is no brighter than its own brightest pixel, and
    /// mapping from a peak it never reaches would darken it for nothing.
    fn prefixSei(dec: *Decoder, rbsp: []const u8) void {
        var b = Bits.init(rbsp);
        var mastering: u32 = 0;
        var content: u32 = 0;
        while (b.moreRbspData()) {
            var kind: u32 = 0;
            while (true) {
                const v = b.u(8);
                kind += v;
                if (v != 0xff or b.overrun()) break;
            }
            var size: u32 = 0;
            while (true) {
                const v = b.u(8);
                size += v;
                if (v != 0xff or b.overrun()) break;
            }
            if (b.overrun() or b.pos + size * 8 > rbsp.len * 8) return;
            const end = b.pos + size * 8;
            if (kind == 137 and size >= 24) {
                // The primaries and the white point are passed over: the
                // curve needs the light alone. The maximum is in ten
                // thousandths of a candela.
                b.pos += 8 * 16;
                const most = b.u(32);
                mastering = most / 10000;
            } else if (kind == 144 and size >= 4) {
                content = b.u(16);
            }
            b.pos = end;
        }
        const peak = if (mastering != 0 and content != 0)
            @min(mastering, content)
        else if (mastering != 0) mastering else content;
        if (peak != 0) dec.peak_nits = @intCast(@min(peak, 10000));
    }

    /// A suffix SEI unit: the decoded picture hash (D.2.20) of the picture
    /// it follows kept with it.
    fn suffixSei(dec: *Decoder, rbsp: []const u8) void {
        const s = dec.sei_pic orelse return;
        var b = Bits.init(rbsp);
        while (b.moreRbspData()) {
            var kind: u32 = 0;
            while (true) {
                const v = b.u(8);
                kind += v;
                if (v != 0xff) break;
            }
            var size: u32 = 0;
            while (true) {
                const v = b.u(8);
                size += v;
                if (v != 0xff or b.overrun()) break;
            }
            if (b.overrun() or b.pos + size * 8 > rbsp.len * 8) return;
            const end = b.pos + size * 8;
            if (kind == 132 and size >= 1) {
                const hash_type = b.u(8);
                const comps: usize = if (dec.active_sps != null and dec.active_sps.?.chroma_format_idc == 0) 1 else 3;
                const each: usize = switch (hash_type) {
                    0 => 16,
                    1 => 2,
                    2 => 4,
                    else => 0,
                };
                if (each != 0 and size >= 1 + comps * each) {
                    for (0..comps) |c| {
                        for (0..each) |i| s.hash[c][i] = @intCast(b.u(8));
                    }
                    s.hash_kind = @intCast(hash_type + 1);
                }
            }
            b.pos = end;
        }
    }

    // --- slice segments ------------------------------------------------------

    fn segment(dec: *Decoder, rbsp: []const u8, unit: nal.Header) Error!void {
        var b = Bits.init(rbsp);
        var peek = b;
        const ids = try slice_mod.peekPps(&peek, unit);
        const pps = &dec.pps[ids.pps];
        if (!pps.valid) return error.Corrupt;
        const sps = &dec.sps[pps.sps_id];
        if (!sps.valid) return error.Corrupt;
        if (ids.first) dec.finishPicture();
        if (dec.cur == null) {
            // More of a picture whose access unit ended, or of one whose
            // first segment was lost.
            if (!ids.first and dec.ended_early) return;
            if (dec.dpb.skipped(unit)) {
                dec.sei_pic = null;
                return;
            }
        } else if (pps != dec.active_pps) return error.Corrupt;
        const hdr = &dec.hdr;
        try slice_mod.parse(&b, hdr, unit, sps, pps, &dec.indep);
        if (dec.cur == null) {
            // A dependent segment needs the header of its slice.
            if (hdr.dependent) return error.Corrupt;
            try dec.startPicture(unit, hdr, sps, pps);
        }
        if (!hdr.dependent) {
            dec.indep = hdr.*;
            if (dec.num_slices == 0xffff) return error.Corrupt;
            dec.num_slices += 1;
            try dec.dpb.buildLists(hdr, &dec.rps, dec.cur.?.poc, &dec.lists);
        } else if (dec.num_slices == 0) return error.Corrupt;
        const idx = dec.num_slices - 1;
        const sl: picture.SliceInfo = .{
            .addr = hdr.slice_addr,
            .beta = hdr.beta_offset,
            .tc = hdr.tc_offset,
            .deblock = !hdr.deblocking_disabled,
            .across = hdr.loop_filter_across_slices,
            .sao_luma = hdr.sao_luma,
            .sao_chroma = hdr.sao_chroma,
        };
        if (dec.job) |j| return dec.post(j, &sl, idx, rbsp.len);
        dec.own.segment(hdr, &dec.lists, &sl, idx, rbsp) catch |e| {
            dec.cur.?.damaged = true;
            dec.slice_errors += 1;
            if (e == error.NoMemory) return e;
        };
    }

    // --- pictures --------------------------------------------------------------

    /// The sequence `sps` made the active one; memory for its pictures when
    /// they changed.
    fn activate(dec: *Decoder, sps: *const params.Sps) Error!void {
        dec.active_sps = sps;
        if (dec.own.info.fits(sps) and dec.own.depth_y == sps.bit_depth_luma and dec.own.depth_c == sps.bit_depth_chroma and
            dec.own.chroma_format == sps.chroma_format_idc) return;
        // New pictures, which begin a sequence: what waits to be shown is
        // left to the picture buffer (C.5.2.2), but nothing of another
        // size is referred to.
        dec.drain();
        for (&dec.dpb.stores) |*s| s.ref = .none;
        dec.last_pic = null;
        if (!dec.own.fit(dec.env, sps)) return error.NoMemory;
        dec.depth_y = sps.bit_depth_luma;
        dec.depth_c = sps.bit_depth_chroma;
        dec.wide = dec.own.wide;
    }

    fn freeStoreMemory(dec: *Decoder, s: *Store) void {
        if (s.memory) |m| dec.env.free(dec.env.ctx, m, s.memory_len);
        s.memory = null;
        s.memory_len = 0;
        dec.env.freeSlice(common.Motion, s.motion);
        s.motion = &.{};
    }

    /// A store's samples and motion for the active sequence.
    fn prepareStore(dec: *Decoder, s: *Store) Error!void {
        const sps = dec.active_sps.?;
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
            3 => {},
        }
        const size: usize = if (dec.wide) 2 else 1;
        const luma = @as(usize, w) * h;
        const chroma = @as(usize, cw) * ch;
        const len = (luma + 2 * chroma) * size;
        const blocks = @as(usize, (w + 15) >> 4) * ((h + 15) >> 4);
        const grey = sps.chroma_format_idc == 0;
        if (s.memory == null or s.memory_len != len or s.width[0] != w or s.width[1] != cw or s.height[0] != h or s.motion.len != blocks or grey) {
            if (s.memory == null or s.memory_len != len or s.width[0] != w or s.width[1] != cw or s.height[0] != h or s.motion.len != blocks) {
                freeStoreMemory(dec, s);
                const m = dec.env.alloc(dec.env.ctx, len, false) orelse return error.NoMemory;
                s.memory = m;
                s.memory_len = len;
                s.motion = dec.env.slice(common.Motion, blocks) orelse return error.NoMemory;
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
        }
    }

    /// A store taken for a picture of the active sequence.
    fn takeStore(dec: *Decoder) Error!*Store {
        const s = try dec.freeStore();
        try dec.prepareStore(s);
        s.in_use = true;
        s.uid = dec.dpb.uid_next;
        dec.dpb.uid_next += 1;
        s.progress = 0;
        s.ref = .none;
        s.output_needed = false;
        s.latency = 0;
        s.generated = false;
        s.time = dec.time;
        s.damaged = false;
        s.hash_kind = 0;
        const sps = dec.active_sps.?;
        s.format = .{
            .x = sps.cropX(),
            .y = sps.cropY(),
            .width = sps.croppedWidth(),
            .height = sps.croppedHeight(),
            .chroma_format = sps.chroma_format_idc,
            .depth_y = sps.bit_depth_luma,
            .depth_c = sps.bit_depth_chroma,
            .matrix = sps.matrix,
            .primaries = sps.colour_primaries,
            .transfer = sps.transfer,
            .full_range = sps.full_range,
            .peak_nits = dec.peak_nits,
        };
        return s;
    }

    fn startPicture(dec: *Decoder, unit: nal.Header, hdr: *const Header, sps: *const params.Sps, pps: *const params.Pps) Error!void {
        try params.checkPps(pps, sps);
        // A worker's picture, or the decoder's own once the workers are done.
        const job = if (dec.parallel()) try dec.freeJob(sps) else null;
        if (job == null) dec.drain();
        dec.on_workers = job != null;
        dec.ended_early = false;
        try dec.activate(sps);
        dec.keepLast();
        dec.active_pps = pps;
        dec.scales.init(if (!sps.scaling_enabled) null else if (pps.scaling_present) &pps.scaling else &sps.scaling);

        const no_rasl = unit.isIrap() and dec.dpb.noRaslOutput(unit);
        const poc = dec.dpb.computePoc(unit, hdr, sps, no_rasl);
        try dec.dpb.applyRps(unit, hdr, sps, poc, no_rasl, &dec.rps);
        // NoOutputOfPriorPicsFlag (C.5.2.2): a CRA picture that begins a
        // sequence drops the pictures of the one before.
        dec.dpb.beforePicture(sps, no_rasl, hdr.no_output_of_prior_pics or unit.kind == nal.Type.cra);
        try dec.generateMissing(sps);

        const s = try dec.takeStore();
        // A reference once decoded; so already, that nothing empties it.
        s.ref = .short;
        s.poc = poc;
        @memset(s.motion, .{});
        dec.cur = s;
        dec.sei_pic = s;
        dec.cur_output = hdr.pic_output;
        dec.num_slices = 0;
        if (job) |j| dec.begin(j, s, sps, pps) else dec.own.begin(sps, pps, &dec.scales, s, null);
    }

    /// Pictures for the references the current picture lacks (8.3.3):
    /// grey, intra, never shown.
    fn generateMissing(dec: *Decoder, sps: *const params.Sps) Error!void {
        for (0..3) |set| {
            for (0..dec.rps.count[set]) |i| {
                if (dec.rps.store[set][i] != null) continue;
                const s = try dec.takeStore();
                s.ref = if (set == dpb_mod.Rps.long) .long else .short;
                s.poc = dec.rps.poc[set][i];
                s.generated = true;
                s.damaged = true;
                @memset(s.motion, .{});
                for (0..3) |p| {
                    const depth = if (p == 0) sps.bit_depth_luma else sps.bit_depth_chroma;
                    const n = s.height[p] * s.stride[p];
                    if (dec.wide) {
                        const d: [*]u16 = @ptrCast(@alignCast(s.planes[p]));
                        @memset(d[0..n], @as(u16, 1) << @intCast(depth - 1));
                    } else @memset(s.planes[p][0..n], 128);
                }
                s.progress = s.height[0];
                dec.rps.store[set][i] = s;
            }
        }
    }

    /// The picture being decoded finished: concealed where segments were
    /// missing, filtered and stored.
    fn finishPicture(dec: *Decoder) void {
        const s = dec.cur orelse return;
        dec.cur = null;
        if (dec.job != null) {
            // Its worker conceals and filters it.
            dec.close();
        } else dec.own.finish(s, dec.last_pic, null);
        dec.releaseLast();
        dec.dpb.store(s, dec.cur_output);
        dec.last_pic = s;
    }

    /// The picture decoded last kept from being used again for the next
    /// one or for those it lacks, which may be concealed from it - alone
    /// as on the workers, whose job holds it too.
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
    /// is room: its header, its slice's lists and its RBSP, which the
    /// decoder takes the slot's buffer for in turn.
    fn post(dec: *Decoder, j: *Job, sl: *const picture.SliceInfo, idx: u16, len: usize) void {
        for (0..2) |l| {
            for (dec.lists.refs[l][0..dec.lists.count[l]]) |r| {
                if (r.store) |rs| dec.pin(j, rs);
            }
        }
        const c = dec.cores.?;
        const posted = j.posted;
        while (posted - @atomicLoad(u32, &j.taken, .acquire) >= job_slices) {
            c.arm(c.ctx, c.workers);
            if (posted - @atomicLoad(u32, &j.taken, .seq_cst) < job_slices) break;
            c.sleep(c.ctx, c.workers);
        }
        const p = &j.slices[posted % job_slices];
        p.hdr = dec.hdr;
        p.lists = dec.lists;
        p.slice = sl.*;
        p.slice_idx = idx;
        const rbsp = p.rbsp;
        p.rbsp = dec.rbsp;
        dec.rbsp = rbsp;
        p.len = len;
        @atomicStore(u32, &j.posted, posted + 1, .seq_cst);
        c.wake(c.ctx);
    }

    /// `s` read by `j`: not used again before `j` is done.
    fn pin(dec: *Decoder, j: *Job, s: *Store) void {
        const bit = @as(u64, 1) << @intCast(dec.dpb.indexOf(s));
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
        while (pins != 0) : (pins &= pins - 1) dec.dpb.stores[@ctz(pins)].pinned -= 1;
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

    /// A store for the next picture; when the only empty ones are still
    /// read by workers, once the first of those is done - or the picture
    /// decoded last, as a last resort.
    fn freeStore(dec: *Decoder) Error!*Store {
        while (true) {
            if (dec.dpb.freeStore()) |s| return s;
            if (dec.retireOldest()) continue;
            // The picture decoded last given up: what is concealed is grey.
            if (dec.last_kept == null) return error.NoMemory;
            dec.releaseLast();
        }
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

/// Workers on threads that wait by yielding: `sleep` returns at once,
/// as it may.
const TestCores = struct {
    cores: common.Cores = undefined,
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

const Decoded = struct { frames: u32 = 0, hash: u64 = 0xcbf29ce484222325 };

const Way = struct {
    /// Each access unit ended as an MP4's packet ends.
    units_end: bool = false,
    /// After so many units: everything dropped, as for a seek, and the
    /// stream decoded from its start again.
    reset_after: ?u32 = null,
    /// After so many units: the decoder closed, whatever it is doing.
    stop_after: ?u32 = null,
};

/// Every picture of an Annex B stream without cropping, in the order
/// shown: how many, and FNV-1a of their planes' bytes (two a sample,
/// low first, for a picture deeper than 8 bits), as ffmpeg's rawvideo
/// has them.
fn decodeAll(stream: []const u8, cores: ?*const common.Cores, way: Way) !Decoded {
    var ctx: u8 = 0;
    const env: Env = .{ .ctx = &ctx, .alloc = TestMemory.alloc, .free = TestMemory.free };
    const dec = Decoder.create(env, .{}) orelse return error.OutOfMemory;
    defer dec.destroy();
    if (cores) |c| dec.useCores(c);
    var got: Decoded = .{};
    var units = nal.AnnexB{ .data = stream };
    var count: u32 = 0;
    while (true) {
        count += 1;
        if (way.stop_after == count) return got;
        if (way.reset_after == count) {
            dec.reset();
            got = .{};
            units = .{ .data = stream };
        }
        if (units.next()) |unit| {
            // A picture's first slice segment (first_slice_segment_in_pic_flag)
            // begins the next.
            const kind = unit[0] >> 1;
            if (way.units_end and kind <= nal.Type.irap_last and unit[2] & 0x80 != 0) dec.endPicture();
            try dec.decodeUnit(unit, 0);
        } else dec.flush();
        while (dec.next()) |s| {
            const size: usize = if (s.format.wide()) 2 else 1;
            for (0..3) |p| {
                for (0..s.height[p]) |r| {
                    for (s.planes[p][r * s.stride[p] * size ..][0 .. s.width[p] * size]) |byte| got.hash = (got.hash ^ byte) *% 0x100000001b3;
                }
            }
            got.frames += 1;
            dec.release();
        }
        if (dec.flushing) return got;
    }
}

// tests/rows.h265: x265 (Main) of ffmpeg's testsrc2 at 128x128, 24
// frames: 16x16 CTBs in three slices a picture and wavefronts, B
// pyramids, weighted prediction, four references, open GOPs (a CRA
// every 12 with RASL pictures before it). tests/wide.h265: 8 frames of
// it in 4:4:4 at 10 bits, with lossless CUs and transform skip. The
// hashes are of ffmpeg's decode.
test "pictures decoded on three workers come out as decoded alone, as ffmpeg decodes them; a seek and a close on the way" {
    const Case = struct { stream: []const u8, frames: u32, hash: u64 };
    const cases = [_]Case{
        .{ .stream = @embedFile("tests/rows.h265"), .frames = 24, .hash = 0x31cd9a7a1c508cfd },
        .{ .stream = @embedFile("tests/wide.h265"), .frames = 8, .hash = 0xce63a1782168d8b9 },
    };
    var t: TestCores = .{};
    t.cores = .{ .ctx = &t, .workers = 3, .run = TestCores.run, .arm = TestCores.arm, .sleep = TestCores.sleep, .wake = TestCores.wake };
    for (&t.threads, 0..) |*th, i| th.* = try std.Thread.spawn(.{}, TestCores.work, .{ &t, i });
    defer {
        @atomicStore(bool, &t.quit, true, .seq_cst);
        for (t.threads) |th| th.join();
    }
    for (cases) |case| {
        const alone = try decodeAll(case.stream, null, .{});
        try testing.expectEqual(case.frames, alone.frames);
        try testing.expectEqual(case.hash, alone.hash);
        try testing.expectEqual(alone, try decodeAll(case.stream, null, .{ .units_end = true }));
        for (0..4) |round| try testing.expectEqual(alone, try decodeAll(case.stream, &t.cores, .{ .units_end = round & 1 != 0 }));
        // A seek and a close with pictures on the workers, at many places.
        var at: u32 = 5;
        while (at < 110) : (at += 7) {
            try testing.expectEqual(alone, try decodeAll(case.stream, &t.cores, .{ .reset_after = at }));
            _ = try decodeAll(case.stream, &t.cores, .{ .stop_after = at, .units_end = at & 1 != 0 });
        }
    }
}
