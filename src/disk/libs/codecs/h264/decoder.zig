// SPDX-License-Identifier: MIT
//! The decoder: videoparse.library's events in, pictures out in the order
//! they are shown. The library reads the stream - the parameter sets, the
//! slice headers, the order counts, the marking, the lists, the bumping -
//! and the decoder decodes the samples, by the slots the library names
//! the pictures by (dpb.zig).
//!
//! **A picture** (VPEV_PICTURE) begins with its first slice: its store
//! made for the sequence (VPEV_SEQUENCE), its slice groups mapped, and
//! each slice (VPEV_SLICE) decoded into it as it comes, each macroblock
//! parsed, its motion derived and its samples put together. Once its
//! slices are all given (VPEV_DECODE) the macroblocks no slice brought
//! are concealed and the picture is filtered. A frame a stream skipped
//! (VPEV_MISSING) is a copy of the last reference picture. A picture due
//! (VPEV_SHOW) is queued to be shown; one the stream let go of
//! (VPEV_FREE) is given back once nothing reads it (`giveBack`).
//!
//! With other cores (`useCores`) a frame whose macroblocks come one after
//! the other is decoded by a worker instead, while the decoder goes on
//! with the events after it: it hands each slice over with its header and
//! lists. The worker conceals, filters each row once the row below it is
//! decoded, and counts the rows that are final; a picture that refers to
//! one waits for the rows each block reads. So as many pictures are
//! decoded at once as there are workers, each a little behind the one
//! before; a store a worker reads is given back once it is done.

const sdk = @import("sdk");
const vp = sdk.videoparse;
const bits_mod = @import("bits.zig");
const Bits = bits_mod.Bits;
pub const Error = bits_mod.Error;
const params = @import("params.zig");
const slice_mod = @import("slice.zig");
const Header = slice_mod.Header;
const common = @import("common.zig");
const Env = common.Env;
const Store = common.Store;
const MbInfo = common.MbInfo;
const Motion = common.Motion;
const RefPic = common.RefPic;
const dpb_mod = @import("dpb.zig");
const mbm = @import("mb.zig");
const mvpred = @import("mvpred.zig");
const recon = @import("recon.zig");
const deblock = @import("deblock.zig");
const transform = @import("transform.zig");
const cabac = @import("cabac.zig");

/// A slice's data partitions B and C (7.3.2.9, 7.3.2.10), as the library
/// gave them: each one's payload and where its data starts.
const Partitions = struct {
    has_b: bool = false,
    b: []const u8 = &.{},
    b_pos: usize = 0,
    has_c: bool = false,
    c: []const u8 = &.{},
    c_pos: usize = 0,
};

/// A picture as its slices are decoded into it - by the decoder itself,
/// or by a job on a worker - and everything that takes.
const Pic = struct {
    store: *Store,
    sps: *const params.Sps,
    pps: *const params.Pps,
    scales: *const transform.Scales,
    /// Its macroblocks: each colour plane's, one after the other.
    infos: []MbInfo,
    mb_map: []const u8,
    mb: *mbm.Mb,
    scratch: *recon.Scratch,
    /// 1 top field, 2 bottom field, 3 frame.
    structure: u2,
    width_mbs: u32,
    height_mbs: u32,
    cat: u2,
    chroma_format: u2,
    depth_y: u5,
    depth_c: u5,
    wide: bool,
    colour_planes: u32,
    first_slice: u32,
    /// What concealment copies.
    last_ref: ?*Store,
    /// A job's: how it waits for the pictures it refers to.
    sync: ?*const common.Sync = null,
    job: ?*Job = null,
};

/// How many of a picture's slices wait for its worker at most; the
/// decoder waits for room when there are more.
const job_slices = 8;
/// Workers used at most.
const max_jobs = 8;

comptime {
    // A job's stores are bits of a u64.
    if (dpb_mod.max_stores > 64) @compileError("too many stores for Job.pins");
}

/// A slice handed to a job: its header and lists as they were when it
/// came, and a copy of its RBSP.
const Posted = struct {
    hdr: Header = .{},
    lists: [2][33]RefPic = @splat(@splat(.{})),
    rbsp: []u8 = &.{},
    len: usize = 0,
    /// Where its data begins, in bits.
    pos: usize = 0,
    slice_id: u32 = 0,
};

/// A picture decoded by a worker while the decoder goes on with the
/// events after it: a frame whose macroblocks come one after the other,
/// its slices handed over as they come. The worker conceals what no slice
/// brought, filters each row once the row below it is decoded, and counts
/// the rows that are final in the store's `progress`.
const Job = struct {
    dec: *Decoder,
    sync: common.Sync,
    // The decoder's: whether it runs, which began first, and the stores
    // it reads, by their slots.
    active: bool = false,
    order: u32 = 0,
    pins: u64 = 0,
    // What it decodes with: the decoder's as the picture began.
    pic: Pic = undefined,
    sps: params.Sps = .{},
    pps: params.Pps = .{},
    scales: transform.Scales = undefined,
    infos: []MbInfo = &.{},
    mb: mbm.Mb = .{},
    scratch: recon.Scratch = .{},
    slices: [job_slices]Posted = @splat(.{}),
    // Counted by both: the slices handed over and those decoded; whether
    // the picture has all its slices, and whether it is done.
    posted: u32 = 0,
    taken: u32 = 0,
    closed: bool = false,
    done: bool = false,
    // The worker's: the macroblock it is at, the rows filtered, and the
    // slices that ended in an error.
    next_addr: u32 = 0,
    filtered: u32 = 0,
    errors: u32 = 0,

    /// The worker's part: the slices as they come, then the rest.
    fn run(arg: *anyopaque) void {
        const j: *Job = @ptrCast(@alignCast(arg));
        const c = j.sync.cores;
        const who = j.sync.who;
        while (true) {
            const taken = j.taken;
            if (@atomicLoad(u32, &j.posted, .acquire) != taken) {
                j.decode(&j.slices[taken % job_slices]);
                @atomicStore(u32, &j.taken, taken + 1, .seq_cst);
                c.wake(c.ctx);
                continue;
            }
            if (@atomicLoad(bool, &j.closed, .acquire) and @atomicLoad(u32, &j.posted, .acquire) == taken) break;
            c.arm(c.ctx, who);
            if (@atomicLoad(u32, &j.posted, .seq_cst) != taken or @atomicLoad(bool, &j.closed, .seq_cst)) continue;
            c.sleep(c.ctx, who);
        }
        j.finish();
        @atomicStore(bool, &j.done, true, .seq_cst);
        c.wake(c.ctx);
    }

    fn decode(j: *Job, p: *const Posted) void {
        // The slices come one after the other: one over macroblocks
        // decoded before is passed over.
        if (p.hdr.first_mb < j.next_addr) return j.failed();
        j.reach(p.hdr.first_mb);
        var b = Bits.init(p.rbsp[0..p.len]);
        b.pos = p.pos;
        sliceData(&j.pic, &b, &p.hdr, &p.lists, p.slice_id, null) catch j.failed();
    }

    fn failed(j: *Job) void {
        j.pic.store.damaged = true;
        j.errors += 1;
    }

    /// The macroblocks before `addr` that no slice brought, concealed.
    fn reach(j: *Job, addr: u32) void {
        const w = j.pic.width_mbs;
        while (j.next_addr < addr) {
            const a = j.next_addr;
            concealMb(&j.pic, false, a % w, a / w);
            j.next_addr = a + 1;
            if (j.next_addr % w == 0) j.advance();
        }
    }

    /// A row decoded: the rows above it filtered but the last, whose
    /// samples the row below took unfiltered, and those above that one
    /// final.
    fn advance(j: *Job) void {
        const decoded = j.next_addr / j.pic.width_mbs;
        if (decoded < j.filtered + 2) return;
        j.filter(decoded - 1);
        j.publish(j.filtered - 1);
    }

    fn filter(j: *Job, to: u32) void {
        const pic = &j.pic;
        const db: deblock.Db = .{
            .store = pic.store,
            .infos = pic.infos,
            .width = pic.width_mbs,
            .rows = pic.height_mbs,
            .mbaff = false,
            .field_pic = false,
            .bottom = false,
            .first_slice = pic.first_slice,
            .cat = pic.cat,
            .mbh_c = mbhC(pic.cat),
            .depth_y = pic.depth_y,
            .depth_c = pic.depth_c,
        };
        if (pic.wide) deblock.Deblock(u16).rows(&db, j.filtered, to) else deblock.Deblock(u8).rows(&db, j.filtered, to);
        j.filtered = to;
    }

    fn publish(j: *Job, rows: u32) void {
        @atomicStore(u32, &j.pic.store.progress, rows, .seq_cst);
        const c = j.sync.cores;
        c.wake(c.ctx);
    }

    /// All slices in: what none brought concealed, every row filtered.
    fn finish(j: *Job) void {
        const pic = &j.pic;
        j.reach(pic.width_mbs * pic.height_mbs);
        j.filter(pic.height_mbs);
        j.publish(pic.height_mbs);
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
    width_mbs: u32 = 0,
    height_mbs: u32 = 0,
    cat: u2 = 0,
    chroma_format: u2 = 0,
    depth_y: u5 = 8,
    depth_c: u5 = 8,
    wide: bool = false,
    /// 1, or 3 with separate colour planes: each plane's macroblocks are
    /// kept apart, in `infos` and in a store's motion, one after the other.
    colour_planes: u32 = 1,
    infos: []MbInfo = &.{},
    /// The slice group of each map unit and each macroblock of a picture.
    unit_map: []u8 = &.{},
    mb_map: []u8 = &.{},
    scales: transform.Scales = undefined,
    /// The scaling lists `scales` were made from, once they were.
    scales_made: bool = false,
    scales_of: params.Scaling = .{},

    // --- the picture being decoded ---
    /// What VPEV_PICTURE said of it; `beginning` until its first slice.
    said: vp.VideoPicture = .{},
    beginning: bool = false,
    cur: ?*Store = null,
    structure: u2 = 3,
    /// Its first slice's header.
    hdr0: Header = .{},
    first_slice: u32 = 0,
    slice_next: u32 = 1,
    second_field: bool = false,
    /// The last reference picture decoded: what concealment copies.
    last_ref: ?*Store = null,
    lists: [2][33]RefPic = @splat(@splat(.{})),

    // --- scratch ---
    mb: mbm.Mb = .{},
    recon: recon.Scratch = .{},
    /// Slices that ended in an error.
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
            env.freeSlice(MbInfo, j.infos);
            for (&j.slices) |*p| env.freeSlice(u8, p.rbsp);
            env.free(env.ctx, @ptrCast(j), @sizeOf(Job));
        }
        for (&dec.stores.stores) |*s| freeStoreMemory(dec, s);
        env.freeSlice(MbInfo, dec.infos);
        env.freeSlice(u8, dec.unit_map);
        env.freeSlice(u8, dec.mb_map);
        env.free(env.ctx, @ptrCast(dec), @sizeOf(Decoder));
    }

    // --- events ----------------------------------------------------------------

    /// One of the library's events. An error is the event's picture's or
    /// slice's: the picture is concealed where it lacks, and the next
    /// event is taken as before.
    pub fn event(dec: *Decoder, e: *const vp.VideoEvent) Error!void {
        dec.flushing = false;
        switch (e.kind) {
            vp.VPEV_SEQUENCE => try dec.activate(e.sequence.?),
            vp.VPEV_MISSING => try dec.missing(e.picture.?),
            vp.VPEV_PICTURE => dec.beginPicture(e.picture.?),
            vp.VPEV_SLICE => try dec.slice(e.slice.?),
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
            @atomicLoad(u32, &s.progress, .acquire) < s.height[0] >> 4)
        {
            if (dec.idle()) return null;
            dec.retireAny();
            if (@atomicLoad(u32, &s.progress, .acquire) < s.height[0] >> 4) return null;
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
        dec.flushing = false;
        dec.beginning = false;
        dec.cur = null;
        dec.last_ref = null;
        dec.stores.forget();
    }

    // --- pictures ------------------------------------------------------------------

    /// The sequence `seq` made the active one: the macroblocks' records
    /// made for its size, once the workers are done with the last one's.
    fn activate(dec: *Decoder, seq: *const vp.VideoSequence) Error!void {
        const sps = seq.h264_sps orelse return error.Corrupt;
        const same = dec.infos.len != 0 and dec.width_mbs == sps.width_mbs and dec.height_mbs == sps.heightMbs() and
            dec.chroma_format == sps.chroma_format_idc and dec.depth_y == sps.bit_depth_luma and
            dec.depth_c == sps.bit_depth_chroma and dec.cat == sps.chromaArrayType() and
            dec.colour_planes == planesOf(sps);
        dec.sps = sps.*;
        dec.active_sps = &dec.sps;
        if (same) return;
        dec.drain();
        dec.last_ref = null;
        const env = dec.env;
        const mbs = sps.width_mbs * sps.heightMbs() * planesOf(sps);
        env.freeSlice(MbInfo, dec.infos);
        dec.infos = &.{};
        env.freeSlice(u8, dec.unit_map);
        dec.unit_map = &.{};
        env.freeSlice(u8, dec.mb_map);
        dec.mb_map = &.{};
        dec.width_mbs = 0;
        dec.infos = env.slice(MbInfo, mbs) orelse return error.NoMemory;
        for (dec.infos) |*i| i.* = .{};
        dec.unit_map = env.slice(u8, sps.width_mbs * sps.height_map_units) orelse return error.NoMemory;
        dec.mb_map = env.slice(u8, sps.width_mbs * sps.heightMbs()) orelse return error.NoMemory;
        dec.width_mbs = sps.width_mbs;
        dec.height_mbs = sps.heightMbs();
        dec.chroma_format = @intCast(sps.chroma_format_idc);
        dec.cat = sps.chromaArrayType();
        dec.depth_y = @intCast(sps.bit_depth_luma);
        dec.depth_c = @intCast(sps.bit_depth_chroma);
        dec.wide = sps.bit_depth_luma > 8 or sps.bit_depth_chroma > 8;
        dec.colour_planes = planesOf(sps);
    }

    fn planesOf(sps: *const params.Sps) u32 {
        return if (sps.separate_colour_plane) 3 else 1;
    }

    fn freeStoreMemory(dec: *Decoder, s: *Store) void {
        if (s.memory) |m| dec.env.free(dec.env.ctx, m, s.memory_len);
        s.memory = null;
        s.memory_len = 0;
        dec.env.freeSlice(Motion, s.motion);
        s.motion = &.{};
    }

    /// A store's samples and motion for the active sequence.
    fn prepareStore(dec: *Decoder, s: *Store) Error!void {
        if (dec.width_mbs == 0) return error.Corrupt;
        const w = dec.width_mbs * 16;
        const h = dec.height_mbs * 16;
        var cw: u32 = w;
        var ch: u32 = h;
        switch (dec.chroma_format) {
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
        const mbs = @as(usize, dec.width_mbs) * dec.height_mbs * dec.colour_planes;
        if (s.memory == null or s.memory_len != len or s.width[0] != w or s.width[1] != cw or s.motion.len != mbs) {
            freeStoreMemory(dec, s);
            const m = dec.env.alloc(dec.env.ctx, len, false) orelse return error.NoMemory;
            s.memory = m;
            s.memory_len = len;
            s.motion = dec.env.slice(Motion, mbs) orelse {
                freeStoreMemory(dec, s);
                return error.NoMemory;
            };
            s.planes = .{ m, m + luma * size, m + (luma + chroma) * size };
            s.stride = .{ w, cw, cw };
            s.width = .{ w, cw, cw };
            s.height = .{ h, ch, ch };
            if (dec.chroma_format == 0) {
                // No chroma: grey, as it is shown.
                const grey: u16 = @as(u16, 1) << @intCast(dec.depth_c - 1);
                if (dec.wide) {
                    const c: [*]u16 = @ptrCast(@alignCast(s.planes[1]));
                    for (0..2 * chroma) |i| c[i] = grey;
                } else {
                    for (0..2 * chroma) |i| s.planes[1][i] = @intCast(grey);
                }
            }
        }
    }

    /// A picture said: its slot the decoder's, and the picture begun with
    /// its first slice, which says how it is coded. Its parameter sets
    /// are copied now: a worker decodes with its own copy of them.
    fn beginPicture(dec: *Decoder, pic: *const vp.VideoPicture) void {
        dec.finishPicture();
        dec.said = pic.*;
        if (pic.h264_sps) |sps| dec.sps = sps.*;
        if (pic.h264_pps) |pps| dec.pps = pps.*;
        if (!pic.second_field) _ = dec.stores.take(pic.slot);
        dec.beginning = true;
    }

    /// The picture VPEV_PICTURE said, begun by its first slice `hdr`: on a
    /// worker, or by the decoder itself once the workers are done.
    /// Until it is begun (`beginning`), it is concealed whole when it is
    /// finished.
    fn startPicture(dec: *Decoder, hdr: *const Header) Error!void {
        const sps = &dec.sps;
        const pps = &dec.pps;
        const pic = &dec.said;
        const job = if (dec.parallel(hdr, sps, pps)) dec.freeJob(sps) else null;
        if (job == null) dec.drain();
        dec.on_workers = job != null;
        dec.makeScales(pps);
        const structure: u2 = @intCast(pic.structure);
        const s = dec.stores.at(pic.slot);
        dec.structure = structure;
        dec.second_field = pic.second_field;
        dec.hdr0 = hdr.*;
        dec.first_slice = dec.slice_next;
        s.poc = pic.poc;
        if (pic.second_field) {
            // The second field of the frame its first field began.
            if (s.memory == null) return error.Corrupt;
            try dec.buildSliceGroups(hdr, sps, pps);
            dec.cur = s;
            s.fields |= structure;
            dec.beginning = false;
            return;
        }
        try dec.prepareStore(s);
        s.uid = pic.uid;
        s.progress = 0;
        s.fields = structure;
        s.frame_coded = !hdr.field_pic;
        s.mbaff = hdr.mbaff(sps);
        s.non_existing = false;
        s.time = pic.time;
        s.damaged = false;
        try dec.buildSliceGroups(hdr, sps, pps);
        dec.cur = s;
        dec.beginning = false;
        if (job) |j| dec.begin(j, s, sps, pps);
    }

    /// The scaling of `pps`'s lists, made again only when they changed.
    fn makeScales(dec: *Decoder, pps: *const params.Pps) void {
        if (dec.scales_made and sameScaling(&dec.scales_of, &pps.scaling)) return;
        dec.scales.init(&pps.scaling.m4, &pps.scaling.m8);
        dec.scales_of = pps.scaling;
        dec.scales_made = true;
    }

    fn sameScaling(a: *const params.Scaling, b: *const params.Scaling) bool {
        for (a.m4, b.m4) |x, y| {
            for (x, y) |p, q| if (p != q) return false;
        }
        for (a.m8, b.m8) |x, y| {
            for (x, y) |p, q| if (p != q) return false;
        }
        return true;
    }

    /// A frame the stream skipped (8.2.5.2): a copy of the last reference
    /// picture, never shown, referred to as if it were there.
    fn missing(dec: *Decoder, pic: *const vp.VideoPicture) Error!void {
        dec.finishPicture();
        const s = dec.stores.take(pic.slot);
        try dec.prepareStore(s);
        s.uid = pic.uid;
        s.progress = dec.height_mbs;
        s.fields = 3;
        s.frame_coded = true;
        s.mbaff = false;
        s.poc = pic.poc;
        s.non_existing = true;
        s.time = 0;
        s.damaged = false;
        if (dec.last_ref) |src| {
            // A store given back since may have come back as this one.
            if (src != s and src.held and src.memory_len == s.memory_len) {
                dec.finished(src);
                @memcpy(s.memory.?[0..s.memory_len], src.memory.?[0..s.memory_len]);
            }
        }
        for (s.motion) |*m| m.* = .{};
    }

    /// A slice of the current picture: decoded, or handed to its worker.
    fn slice(dec: *Decoder, sl: *const vp.VideoSlice) Error!void {
        const hdr = sl.h264 orelse return error.Corrupt;
        if (dec.beginning) try dec.startPicture(hdr);
        const s = dec.cur orelse return error.Corrupt;
        const sps = &dec.sps;
        const pps = &dec.pps;
        // SP and SI are the Extended profile's: 4:2:0, 8 bits, 4x4 transforms.
        if ((hdr.kind == .sp or hdr.kind == .si) and (sps.chroma_format_idc != 1 or sps.bit_depth_luma != 8 or sps.bit_depth_chroma != 8 or pps.transform_8x8)) return error.Unsupported;
        const slice_id = dec.slice_next;
        dec.slice_next += 1;
        for (0..2) |l| {
            for (&dec.lists[l], &sl.lists[l]) |*ref, *entry| ref.* = dec.refOf(entry);
        }
        if (dec.job) |j| {
            // Partitions are the Extended profile's, never a worker's.
            if (sl.partitioned) return error.Corrupt;
            return dec.post(j, sl, slice_id);
        }
        var b = Bits.init(sl.rbsp[0..sl.rbsp_bytes]);
        b.pos = sl.data_bit;
        var parts: Partitions = .{};
        if (sl.partitioned) {
            if (sl.part_b) |data| parts = .{ .has_b = true, .b = data[0..sl.part_b_bytes], .b_pos = sl.part_b_bit };
            if (sl.part_c) |data| {
                parts.has_c = true;
                parts.c = data[0..sl.part_c_bytes];
                parts.c_pos = sl.part_c_bit;
            }
        }
        const pic = dec.picture(s);
        sliceData(&pic, &b, hdr, &dec.lists, slice_id, if (sl.partitioned) &parts else null) catch |e| {
            s.damaged = true;
            dec.slice_errors += 1;
            if (e == error.NoMemory) return e;
        };
    }

    /// A list entry as the decoding takes it: its picture's store, with
    /// the order counts the library gives it now - an operation 5 sets
    /// them anew once the picture is marked.
    fn refOf(dec: *Decoder, entry: *const vp.VideoListEntry) RefPic {
        if (entry.slot == vp.VP_NO_SLOT or entry.slot >= dpb_mod.max_stores) return .{};
        const s = dec.stores.at(entry.slot);
        if (!s.held or s.memory == null) return .{};
        if (s.poc[0] != entry.poc[0] or s.poc[1] != entry.poc[1]) s.poc = entry.poc;
        return .{ .store = s, .structure = @intCast(entry.structure & 3), .long = entry.long_term };
    }

    /// mbToSliceGroupMap (8.2.2) of the picture.
    fn buildSliceGroups(dec: *Decoder, hdr: *const Header, sps: *const params.Sps, pps: *const params.Pps) Error!void {
        if (pps.num_slice_groups <= 1) return;
        const w = sps.width_mbs;
        const hu = sps.height_map_units;
        const units = w * hu;
        const map = dec.unit_map[0..units];
        const n = pps.num_slice_groups;
        const group0 = @min(hdr.slice_group_change_cycle * pps.change_rate, units);
        const dir: u8 = @intFromBool(pps.change_direction);
        switch (pps.slice_group_map_type) {
            0 => {
                var i: u32 = 0;
                while (i < units) {
                    var g: u32 = 0;
                    while (g < n and i < units) : (g += 1) {
                        var j: u32 = 0;
                        while (j < pps.run_length[g] and i + j < units) : (j += 1) map[i + j] = @intCast(g);
                        i += pps.run_length[g];
                    }
                }
            },
            1 => for (0..units) |i| {
                const ii: u32 = @intCast(i);
                map[i] = @intCast(((ii % w) + (((ii / w) * n) / 2)) % n);
            },
            2 => {
                @memset(map, n - 1);
                var g: i32 = @as(i32, n) - 2;
                while (g >= 0) : (g -= 1) {
                    const gi: usize = @intCast(g);
                    const y0 = pps.top_left[gi] / w;
                    const x0 = pps.top_left[gi] % w;
                    const y1 = pps.bottom_right[gi] / w;
                    const x1 = pps.bottom_right[gi] % w;
                    var y = y0;
                    while (y <= y1) : (y += 1) {
                        var x = x0;
                        while (x <= x1) : (x += 1) map[y * w + x] = @intCast(gi);
                    }
                }
            },
            3 => {
                @memset(map, 1);
                const cd: i32 = dir;
                const wi: i32 = @intCast(w);
                const hi: i32 = @intCast(hu);
                var x: i32 = @divTrunc(wi - cd, 2);
                var y: i32 = @divTrunc(hi - cd, 2);
                var left = x;
                var top = y;
                var right = x;
                var bottom = y;
                var xd: i32 = cd - 1;
                var yd: i32 = cd;
                var k: u32 = 0;
                var guard: u32 = 0;
                while (k < group0 and guard < 4 * units + 16) : (guard += 1) {
                    const idx: usize = @intCast(y * wi + x);
                    const vacant = map[idx] == 1;
                    if (vacant) map[idx] = 0;
                    if (xd == -1 and x == left) {
                        left = @max(left - 1, 0);
                        x = left;
                        xd = 0;
                        yd = 2 * cd - 1;
                    } else if (xd == 1 and x == right) {
                        right = @min(right + 1, wi - 1);
                        x = right;
                        xd = 0;
                        yd = 1 - 2 * cd;
                    } else if (yd == -1 and y == top) {
                        top = @max(top - 1, 0);
                        y = top;
                        xd = 1 - 2 * cd;
                        yd = 0;
                    } else if (yd == 1 and y == bottom) {
                        bottom = @min(bottom + 1, hi - 1);
                        y = bottom;
                        xd = 2 * cd - 1;
                        yd = 0;
                    } else {
                        x += xd;
                        y += yd;
                    }
                    if (vacant) k += 1;
                }
            },
            4 => {
                const upper = if (dir != 0) units - group0 else group0;
                for (0..units) |i| map[i] = if (i < upper) dir else 1 - dir;
            },
            5 => {
                const upper = if (dir != 0) units - group0 else group0;
                var k: u32 = 0;
                for (0..w) |j| {
                    for (0..hu) |i| {
                        map[i * w + j] = if (k < upper) dir else 1 - dir;
                        k += 1;
                    }
                }
            },
            6 => {
                const ids = pps.group_ids orelse return error.Corrupt;
                @memcpy(map, ids[0..units]);
            },
            else => return error.Unsupported,
        }
        const mbs = dec.picMbs(hdr);
        const mbaff = hdr.mbaff(sps);
        for (0..mbs) |i| {
            const ii: u32 = @intCast(i);
            dec.mb_map[i] = if (sps.frame_mbs_only or hdr.field_pic)
                map[ii]
            else if (mbaff)
                map[ii / 2]
            else
                map[(ii / (2 * w)) * w + (ii % w)];
        }
    }

    /// PicSizeInMbs of the picture.
    fn picMbs(dec: *const Decoder, hdr: *const Header) u32 {
        const mbs = dec.width_mbs * dec.height_mbs;
        return if (hdr.field_pic) mbs / 2 else mbs;
    }

    /// The picture being decoded finished (VPEV_DECODE): concealed where
    /// slices were missing and filtered, by its worker or here. A picture
    /// none of whose slices could be decoded is the last reference's copy.
    fn finishPicture(dec: *Decoder) void {
        if (dec.beginning) {
            dec.beginning = false;
            dec.blank() catch {};
        }
        const s = dec.cur orelse return;
        dec.cur = null;
        if (dec.job != null) {
            // Its worker conceals and filters it.
            dec.close();
        } else dec.concealAndFilter(s);
        if (dec.said.reference) dec.last_ref = s;
    }

    /// The picture VPEV_PICTURE said, without a slice that began it: made
    /// for the sequence and concealed whole when it is finished.
    fn blank(dec: *Decoder) Error!void {
        const pic = &dec.said;
        const s = dec.stores.at(pic.slot);
        dec.drain();
        dec.on_workers = false;
        dec.structure = 3;
        dec.second_field = false;
        dec.hdr0 = .{};
        dec.first_slice = dec.slice_next;
        if (pic.second_field) {
            if (s.memory == null) return error.Corrupt;
        } else {
            try dec.prepareStore(s);
            s.uid = pic.uid;
            s.fields = 3;
            s.frame_coded = true;
            s.mbaff = false;
            s.non_existing = false;
            s.time = pic.time;
        }
        s.poc = pic.poc;
        s.progress = 0;
        dec.makeScales(&dec.pps);
        dec.cur = s;
    }

    /// The picture the decoder decoded itself finished: the macroblocks no
    /// slice brought concealed, then the whole filtered.
    fn concealAndFilter(dec: *Decoder, s: *Store) void {
        const sps = dec.active_sps.?;
        const hdr = &dec.hdr0;
        const pic = dec.picture(s);
        const step: u32 = if (hdr.field_pic) 2 else 1;
        var mb_y: u32 = if (hdr.field_pic and hdr.bottom_field) 1 else 0;
        while (mb_y < dec.height_mbs) : (mb_y += step) {
            for (0..dec.width_mbs) |x| concealMb(&pic, hdr.field_pic, @intCast(x), mb_y);
        }
        const mbs = dec.width_mbs * dec.height_mbs;
        for (0..dec.colour_planes) |k| {
            // A separate colour plane is filtered as the luma of a picture
            // of its own, with its own macroblocks.
            var view = s.*;
            view.planes[0] = s.planes[k];
            const db: deblock.Db = .{
                .store = &view,
                .infos = dec.infos[k * mbs ..][0..mbs],
                .width = dec.width_mbs,
                .rows = dec.height_mbs,
                .mbaff = hdr.mbaff(sps),
                .field_pic = hdr.field_pic,
                .bottom = hdr.bottom_field,
                .first_slice = dec.first_slice,
                .cat = dec.cat,
                .mbh_c = mbhC(dec.cat),
                .depth_y = dec.depth_y,
                .depth_c = dec.depth_c,
            };
            if (dec.wide) deblock.Deblock(u16).picture(&db) else deblock.Deblock(u8).picture(&db);
        }
        s.progress = dec.height_mbs;
    }

    /// The current picture as the decoder decodes it itself.
    fn picture(dec: *Decoder, s: *Store) Pic {
        return .{
            .store = s,
            .sps = &dec.sps,
            .pps = &dec.pps,
            .scales = &dec.scales,
            .infos = dec.infos,
            .mb_map = dec.mb_map,
            .mb = &dec.mb,
            .scratch = &dec.recon,
            .structure = dec.structure,
            .width_mbs = dec.width_mbs,
            .height_mbs = dec.height_mbs,
            .cat = dec.cat,
            .chroma_format = dec.chroma_format,
            .depth_y = dec.depth_y,
            .depth_c = dec.depth_c,
            .wide = dec.wide,
            .colour_planes = dec.colour_planes,
            .first_slice = dec.first_slice,
            .last_ref = dec.last_ref,
        };
    }

    // --- the workers ------------------------------------------------------------

    /// Whether the picture the slice `hdr` begins is a worker's: a frame
    /// whose macroblocks come one after the other.
    fn parallel(dec: *const Decoder, hdr: *const Header, sps: *const params.Sps, pps: *const params.Pps) bool {
        const c = dec.cores orelse return false;
        if (c.workers == 0) return false;
        if (hdr.field_pic or hdr.mbaff(sps) or sps.separate_colour_plane or pps.num_slice_groups > 1) return false;
        // Baseline without constraint_set1 and Extended may send the
        // slices in any order, Extended in partitions too.
        if (sps.profile_idc == 88 or (sps.profile_idc == 66 and sps.constraint_flags & 0x40 == 0)) return false;
        // Operation 5 changes the picture's numbers once it is marked,
        // while the worker would still read them.
        if (hdr.adaptive_marking) {
            for (hdr.mmco[0..hdr.mmco_count]) |op| {
                if (op.op == 5) return false;
            }
        }
        return true;
    }

    /// A job for the next picture, its macroblocks made for `sps`: one
    /// that never ran, one done, or the one begun first once it is done.
    /// Null without the memory.
    fn freeJob(dec: *Decoder, sps: *const params.Sps) ?*Job {
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
        const mbs = sps.width_mbs * sps.heightMbs();
        if (j.infos.len != mbs) {
            dec.env.freeSlice(MbInfo, j.infos);
            j.infos = &.{};
            j.infos = dec.env.slice(MbInfo, mbs) orelse return null;
            for (j.infos) |*i| i.* = .{};
        }
        return j;
    }

    /// The current picture `s` handed to `j`'s worker.
    fn begin(dec: *Decoder, j: *Job, s: *Store, sps: *const params.Sps, pps: *const params.Pps) void {
        j.sps = sps.*;
        j.pps = pps.*;
        j.scales = dec.scales;
        j.pic = dec.picture(s);
        j.pic.sps = &j.sps;
        j.pic.pps = &j.pps;
        j.pic.scales = &j.scales;
        j.pic.infos = j.infos;
        j.pic.mb_map = &.{};
        j.pic.mb = &j.mb;
        j.pic.scratch = &j.scratch;
        j.pic.sync = &j.sync;
        j.pic.job = j;
        j.posted = 0;
        j.taken = 0;
        j.closed = false;
        j.done = false;
        j.next_addr = 0;
        j.filtered = 0;
        j.errors = 0;
        j.active = true;
        j.order = dec.job_order;
        dec.job_order +%= 1;
        dec.pin(j, s);
        if (j.pic.last_ref) |r| dec.pin(j, r);
        dec.job = j;
        const c = dec.cores.?;
        c.run(c.ctx, j.sync.who, Job.run, j);
    }

    /// A slice of the current picture handed to its worker, once there is
    /// room: its header, its lists and a copy of its RBSP.
    fn post(dec: *Decoder, j: *Job, sl: *const vp.VideoSlice, slice_id: u32) Error!void {
        for (&dec.lists) |*list| {
            for (list) |r| {
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
        const len: usize = sl.rbsp_bytes;
        if (p.rbsp.len < len) {
            // Room for the slices of a picture that comes later too.
            dec.env.freeSlice(u8, p.rbsp);
            p.rbsp = &.{};
            p.rbsp = dec.env.slice(u8, len + len / 2 + 64) orelse return error.NoMemory;
        }
        @memcpy(p.rbsp[0..len], sl.rbsp[0..len]);
        p.hdr = sl.h264.?.*;
        p.lists = dec.lists;
        p.len = len;
        p.pos = sl.data_bit;
        p.slice_id = slice_id;
        @atomicStore(u32, &j.posted, posted + 1, .seq_cst);
        c.wake(c.ctx);
    }

    /// `s` read by `j`: not given back before `j` is done.
    fn pin(dec: *Decoder, j: *Job, s: *Store) void {
        const i = dec.stores.slotOf(s);
        const bit = @as(u64, 1) << @intCast(i);
        if (j.pins & bit != 0) return;
        j.pins |= bit;
        s.pinned += 1;
    }

    /// The current picture's worker told it has all its slices.
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
        if (dec.cores == null) return false;
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
        const rows = s.height[0] >> 4;
        if (@atomicLoad(u32, &s.progress, .acquire) >= rows) return;
        const c = dec.cores orelse return;
        const sy: common.Sync = .{ .cores = c, .who = c.workers };
        sy.rows(s, rows);
    }
};

fn mbhC(cat: u2) u32 {
    return switch (cat) {
        1 => 8,
        2, 3 => 16,
        0 => 0,
    };
}

/// Macroblock (x, mb_y) where no slice brought it, in each plane none
/// did: the last reference picture's samples there, or grey.
fn concealMb(pic: *const Pic, field_pic: bool, x: u32, mb_y: u32) void {
    const s = pic.store;
    const w = pic.width_mbs;
    const xy = mb_y * w + x;
    const planes: usize = if (pic.chroma_format == 0) 1 else 3;
    const sep = pic.colour_planes == 3;
    const mbs = w * pic.height_mbs;
    const step: u32 = if (field_pic) 2 else 1;
    const size: usize = if (pic.wide) 2 else 1;
    // A store emptied since may have come back as this one.
    var src = pic.last_ref;
    if (src) |r| {
        if (r == s or r.memory_len != s.memory_len) src = null;
    }
    for (0..planes) |p| {
        // Separate colour planes are each missing on their own.
        const k: u32 = if (sep) @as(u32, @intCast(p)) * mbs else 0;
        if (pic.infos[k + xy].slice >= pic.first_slice) continue;
        s.damaged = true;
        if (p == 0 or sep) s.motion[k + xy] = .{};
        if (src) |r| {
            if (pic.sync) |sy| sy.rows(r, mb_y + 1);
        }
        const mbw: u32 = if (p == 0) 16 else @intCast(s.width[p] / w);
        const mbh: u32 = if (p == 0) 16 else @intCast(s.height[p] / pic.height_mbs);
        // A field macroblock's rows are every other row.
        const y0: usize = if (field_pic) mbh * (mb_y & ~@as(u32, 1)) + (mb_y & 1) else mbh * mb_y;
        for (0..mbh) |r| {
            const row = y0 + r * step;
            const o = (row * s.stride[p] + @as(usize, x) * mbw) * size;
            const dst = s.planes[p] + o;
            if (src) |sr| {
                @memcpy(dst[0 .. mbw * size], (sr.planes[p] + o)[0 .. mbw * size]);
            } else if (pic.wide) {
                const d16: [*]u16 = @ptrCast(@alignCast(dst));
                const grey: u16 = @as(u16, 1) << @intCast((if (p == 0 or sep) pic.depth_y else pic.depth_c) - 1);
                for (0..mbw) |i| d16[i] = grey;
            } else @memset(dst[0..mbw], 128);
        }
    }
}

fn nextAddr(pic: *const Pic, addr: u32, mbs: u32) u32 {
    if (pic.pps.num_slice_groups <= 1) return addr + 1;
    var i = addr + 1;
    while (i < mbs and pic.mb_map[i] != pic.mb_map[addr]) i += 1;
    return i;
}

// --- slice data -----------------------------------------------------------

/// The macroblocks of a slice decoded into `pic`, its data from `b` on.
fn sliceData(pic: *const Pic, b: *Bits, hdr: *const Header, lists: *const [2][33]RefPic, slice_id: u32, parts: ?*const Partitions) Error!void {
    const sps = pic.sps;
    const pps = pic.pps;
    const s = pic.store;
    const w = pic.width_mbs;
    const mbaff = hdr.mbaff(sps);
    // The macroblocks of the slice's colour plane.
    const base: usize = @as(usize, hdr.colour_plane) * w * pic.height_mbs;
    const infos = pic.infos[base..][0 .. w * pic.height_mbs];
    const motion = s.motion[base..][0 .. w * pic.height_mbs];
    var d: mbm.Dec = .{
        .sps = sps,
        .pps = pps,
        .hdr = hdr,
        .infos = infos,
        .width = w,
        .mbaff = mbaff,
        .field_pic = hdr.field_pic,
        .cat = pic.cat,
        .mbh_c = mbhC(pic.cat),
        .slice_id = slice_id,
        .scales = pic.scales,
    };
    d.bits = b.*;
    if (parts) |p| {
        d.partitioned = true;
        d.has_b = p.has_b;
        d.has_c = p.has_c;
        if (p.has_b) {
            d.bits_b = Bits.init(p.b);
            d.bits_b.pos = p.b_pos;
        }
        if (p.has_c) {
            d.bits_c = Bits.init(p.c);
            d.bits_c.pos = p.c_pos;
        }
    }
    d.qp = hdr.qp;
    const use_cabac = pps.cabac;
    if (use_cabac) {
        d.bits.alignByte();
        if (!d.eng.init(d.bits.data, d.bits.pos >> 3)) return error.Corrupt;
        cabac.initContexts(&d.ctx, hdr.kind == .i or hdr.kind == .si, hdr.cabac_init_idc, hdr.qp);
    }
    const b_slice = hdr.kind == .b;
    var col: ?RefPic = null;
    var col_parity: u1 = 0;
    var col_fieldoff: i32 = 0;
    if (b_slice) {
        col = lists[1][0];
        if (col.?.store) |cs| {
            if (pic.structure == 3) {
                const cur_poc = @min(s.poc[0], s.poc[1]);
                col_parity = @intFromBool(@abs(cs.poc[0] - cur_poc) >= @abs(cs.poc[1] - cur_poc));
            } else if (col.?.structure != pic.structure and !cs.mbaff) {
                col_fieldoff = if (col.?.structure == 1) -1 else 1;
            }
        } else col = null;
    }
    const ctx: mvpred.Ctx = .{
        .lists = lists,
        .cur = s,
        .structure = pic.structure,
        .direct_spatial = hdr.direct_spatial,
        .direct_8x8_inference = sps.direct_8x8_inference,
        .col = col,
        .col_parity = col_parity,
        .col_fieldoff = col_fieldoff,
        .motion_base = base,
        .sync = pic.sync,
    };
    const rc: recon.Rc = .{
        .store = s,
        .scratch = pic.scratch,
        .mv = &ctx,
        .hdr = hdr,
        .depth_y = pic.depth_y,
        .depth_c = pic.depth_c,
        .weighting = if (hdr.weighted) .explicit else if (b_slice and pps.weighted_bipred_idc == 2) .implicit else .none,
        .colour = @intCast(hdr.colour_plane),
        .sync = pic.sync,
    };
    const mbs = if (hdr.field_pic) w * pic.height_mbs / 2 else w * pic.height_mbs;
    const inter_slice = hdr.isInter();
    const switching = hdr.kind == .sp or hdr.kind == .si;
    const bdc: i32 = 6 * (@as(i32, sps.bit_depth_chroma) - 8);
    const bdy: i32 = 6 * (@as(i32, sps.bit_depth_luma) - 8);

    var addr: u32 = hdr.first_mb * @as(u32, if (mbaff) 2 else 1);
    var need_run = true;
    var run_left: u32 = 0;
    var end_after_skip = false;
    var prev_skipped = false;
    var next_skipped = false;
    var field_read = false;
    const m = pic.mb;
    while (true) {
        if (addr >= mbs) return error.Corrupt;
        const top = mbaff and addr & 1 == 0;
        const bottom = mbaff and addr & 1 == 1;
        if (mbaff) {
            const pair = addr >> 1;
            d.mb_x = pair % w;
            d.mb_y = 2 * (pair / w) + (addr & 1);
        } else if (hdr.field_pic) {
            d.mb_x = addr % w;
            d.mb_y = 2 * (addr / w) + @intFromBool(hdr.bottom_field);
        } else {
            d.mb_x = addr % w;
            d.mb_y = addr / w;
        }
        d.xy = d.mb_y * w + d.mb_x;
        if (top) {
            // The pair's field flag as inferred, until it is read.
            d.field = d.pairField(true) orelse d.pairField(false) orelse false;
            field_read = false;
        } else if (!mbaff) d.field = hdr.field_pic;
        d.neighbours();

        var skipped = false;
        if (inter_slice) {
            if (!use_cabac) {
                if (need_run) {
                    run_left = try d.bits.ueMax(mbs - addr);
                    need_run = false;
                    prev_skipped = run_left > 0;
                }
                if (run_left > 0) {
                    skipped = true;
                    run_left -= 1;
                    if (run_left == 0) {
                        end_after_skip = !d.bits.moreRbspData();
                        if (top and !end_after_skip) {
                            // The bottom's field flag comes next: the pair's.
                            d.field = d.bits.flag();
                            field_read = true;
                            d.neighbours();
                        }
                    }
                } else need_run = true;
            } else {
                if (bottom and prev_skipped) {
                    skipped = next_skipped;
                } else skipped = mbm.readSkipCabac(&d, b_slice);
                if (skipped and top) {
                    // The bottom's skip flag, and if it is coded the
                    // pair's field flag, before the top is decoded; the
                    // bottom sees the top as skipped.
                    infos[d.xy].slice = slice_id;
                    infos[d.xy].flags = common.F_SKIP | (if (d.field) common.F_FIELD else 0);
                    d.mb_y += 1;
                    d.xy += w;
                    d.neighbours();
                    next_skipped = mbm.readSkipCabac(&d, b_slice);
                    d.mb_y -= 1;
                    d.xy -= w;
                    if (!next_skipped) {
                        d.field = mbm.readFieldCabac(&d);
                        field_read = true;
                    }
                    d.neighbours();
                }
                prev_skipped = skipped;
            }
        }

        if (skipped) {
            m.reset();
            m.skip = true;
            m.kind = .inter;
            if (b_slice) {
                m.direct = 0xF;
                m.direct16 = true;
                m.shape = .p8x8;
            } else {
                m.shape = .p16x16;
                m.pred = @splat(mbm.L0);
                m.ref = .{ @splat(0), @splat(-1) };
            }
            m.qp = d.qp;
            d.last_dqp = false;
        } else {
            if (mbaff and !field_read and (top or bottom)) {
                d.field = if (use_cabac) mbm.readFieldCabac(&d) else d.bits.flag();
                field_read = true;
                d.neighbours();
            }
            try mbm.parse(&d, m);
            d.qp = m.qp;
        }

        var out: mvpred.Out = .{};
        if (m.kind == .inter) try mvpred.derive(&ctx, &d, m, &out);
        if (pic.wide) recon.Recon(u16).mb(&rc, &d, m, &out) else recon.Recon(u8).mb(&rc, &d, m, &out);

        // What later macroblocks and pictures need of it.
        const info = &infos[d.xy];
        const intra = m.kind != .inter;
        var flags: u8 = 0;
        if (d.field) flags |= common.F_FIELD;
        if (m.t8x8) flags |= common.F_T8X8;
        if (m.skip) flags |= common.F_SKIP;
        if (m.direct16) flags |= common.F_DIRECT;
        if (intra) flags |= common.F_INTRA;
        if (m.kind == .ipcm) flags |= common.F_PCM;
        if (switching) flags |= common.F_SWITCH;
        info.slice = slice_id;
        info.kind = m.kind;
        info.flags = flags | common.F_DONE;
        const qp_db: i32 = if (m.kind == .ipcm) -bdy else m.qp;
        info.qp = @intCast(qp_db);
        info.qpc = .{
            @intCast(mbm.chromaQp(qp_db, pps.chroma_qp_offset[0], bdc)),
            @intCast(mbm.chromaQp(qp_db, pps.chroma_qp_offset[1], bdc)),
        };
        info.cbp = m.cbp;
        info.chroma_mode = if (intra and m.kind != .ipcm) m.chroma_mode else 0;
        info.direct8 = if (m.kind == .inter) m.direct else 0;
        info.cbf_dc = m.cbf_dc;
        info.i_modes = m.i_modes;
        info.nnz = m.nnz;
        info.nz8 = m.nz8;
        info.filter = hdr.disable_deblocking;
        info.alpha_off = hdr.alpha_offset;
        info.beta_off = hdr.beta_offset;
        const mo = &motion[d.xy];
        mo.intra = intra;
        mo.field = d.field;
        for (0..2) |l| {
            for (0..16) |i| {
                for (0..2) |c| {
                    const v = m.mvd[l][i][c];
                    info.mvd[l][i][c] = @intCast(@min(@abs(v), 127));
                }
            }
            for (0..4) |b8| {
                const r = if (intra) -1 else out.ref[l][b8];
                info.ref[l][b8] = r;
                const id: u32 = if (r >= 0) mvpred.refPic(&ctx, &d, l, r).id() else 0;
                info.ref_id[l][b8] = id;
                mo.ref[l][b8] = r;
                mo.ref_id[l][b8] = id;
            }
            for (0..16) |i| {
                const b8 = (i >> 3) * 2 + ((i & 3) >> 1);
                const used = !intra and out.ref[l][b8] >= 0;
                const v: [2]i16 = if (used) .{ @intCast(out.mv[l][i][0]), @intCast(out.mv[l][i][1]) } else .{ 0, 0 };
                info.mv[l][i] = v;
                mo.mv[l][i] = v;
            }
        }
        if (pic.job) |j| {
            j.next_addr = addr + 1;
            if (d.mb_x + 1 == w) j.advance();
        }

        // More?
        var more: bool = undefined;
        if (!use_cabac) {
            more = if (skipped) run_left > 0 or !end_after_skip else d.bits.moreRbspData();
            if (skipped and run_left == 0 and !end_after_skip) need_run = false;
        } else if (top) {
            more = true;
        } else {
            more = !mbm.readEndOfSlice(&d);
        }
        if (!use_cabac and d.bits.overrun()) return error.Corrupt;
        if (use_cabac and d.eng.overrun()) return error.Corrupt;
        if (!more) break;
        addr = nextAddr(pic, addr, mbs);
    }
}
