// SPDX-License-Identifier: MIT
//! The VP8 decoder (RFC 6386): frames in, the frames to show out - VP8
//! shows its frames in the order they come, those it does not hide.
//!
//! A frame is its header (9, 19.2) and the macroblocks' modes in the
//! first partition, their coefficients in one to eight more, a row each
//! in turn. The decoder reads the header and every macroblock's modes;
//! the rest is a job: each row put together - predicted and its residue
//! added - and the row above it filtered once it is, since intra
//! prediction reads the neighbours unfiltered. The frame then becomes the
//! last frame, the golden or the alternate reference as its header says;
//! the probabilities it changed stay unless it said they are for it
//! alone, and so does the segment map.
//!
//! **The cores**: given workers (`useCores`), each job is a worker's, and
//! the decoder goes on with the next frame while it runs - as many frames
//! at once as there are workers. A job counts the rows of its frame that
//! are final (`progress`), and a macroblock waits for the rows of its
//! reference it reads. Without workers the decoder runs each job itself.

const common = @import("common.zig");
const tables = @import("tables.zig");
const Bool = @import("bool.zig").Bool;
const modes = @import("modes.zig");
const tokens = @import("tokens.zig");
const recon = @import("recon.zig");
const filter = @import("filter.zig");
const Env = common.Env;
const Error = common.Error;
const Frame = common.Frame;
const MbInfo = common.MbInfo;
const Cores = common.Cores;

/// Frames decoded at once at most.
const max_jobs = 8;
/// Frames waiting to be shown at most; one more drops the first.
const max_out = max_jobs + 2;
/// Frames at most: the three references, one for each job, and those
/// waiting to be shown.
const max_frames = 3 + max_jobs + max_out;

/// A frame's macroblocks put together, on a worker or by the decoder,
/// with everything it needs as the decoder read it.
const Job = struct {
    // The decoder's: the cores, the worker it runs on, whether it runs
    // and which began first.
    cores: ?*const Cores = null,
    who: u32 = 0,
    active: bool = false,
    order: u32 = 0,
    /// Set by the worker once the frame is done.
    done: bool = false,
    cur: *Frame = undefined,
    /// The references by `common.LAST` to `ALTREF`, as the frame began.
    refs: [4]?*Frame = .{ null, null, null, null },
    hdr: common.Header = .{},
    seg: common.Segmentation = .{},
    deltas: common.Deltas = .{},
    quant: [4]common.Quant = @splat(.{}),
    coeff_probs: [4][8][3][11]u8 = undefined,
    parts: [8]Bool = @splat(.{}),
    /// The partitions' bytes, copied when a worker reads them.
    data: []u8 = &.{},
    mbs: []MbInfo = &.{},
    above_nz: []tokens.Nz = &.{},
    cols: u32 = 0,
    rows: u32 = 0,
    coeffs: tokens.Coeffs = @splat(@splat(0)),
    scratch: recon.Scratch = .{},
    workspace: recon.Workspace = .{},

    /// A worker's: the frame, then the decoder told.
    fn run(arg: *anyopaque) void {
        const j: *Job = @ptrCast(@alignCast(arg));
        j.decode();
        @atomicStore(bool, &j.done, true, .seq_cst);
        const c = j.cores.?;
        c.wake(c.ctx);
    }

    fn decode(j: *Job) void {
        const cur = j.cur;
        for (j.above_nz) |*nz| nz.* = @splat(0);
        const filtering = j.hdr.filter_level != 0;
        for (0..j.rows) |ru| {
            const r: u32 = @intCast(ru);
            const part = &j.parts[r & (j.hdr.partitions - 1)];
            var left: tokens.Nz = @splat(0);
            for (0..j.cols) |cu| {
                const c: u32 = @intCast(cu);
                const mb = &j.mbs[r * j.cols + c];
                const has_y2 = mb.y_mode != common.B_PRED and mb.y_mode != common.SPLITMV;
                var mask: u32 = 0;
                if (mb.skip) {
                    tokens.skip(&left, &j.above_nz[c], has_y2);
                } else {
                    mask = tokens.macroblock(part, &j.coeff_probs, &left, &j.above_nz[c], &j.coeffs, has_y2, &j.quant[mb.segment]);
                }
                mb.inner = mask != 0 or !has_y2;
                if (mb.ref == common.INTRA) {
                    recon.intra(mb, &j.coeffs, mask, cur, r, c, j.cols, &j.workspace);
                } else {
                    const ref = j.refs[mb.ref] orelse j.refs[common.LAST].?;
                    j.reach(ref, mb, r);
                    recon.inter(mb, &j.coeffs, mask, cur, ref, r, c, j.hdr.version, &j.scratch);
                }
            }
            if (r > 0) {
                if (filtering) j.filterRow(r - 1);
                // Filtering a row changes the last rows of the one above
                // it: that one is final now.
                j.publish(r - 1);
            }
        }
        if (filtering) j.filterRow(j.rows - 1);
        j.publish(j.rows);
    }

    /// Until the rows of `ref` that a macroblock of row `r` reads are
    /// final: as far down as its vectors point, with the sample the
    /// fraction takes and the filter's taps below, in the brightness and
    /// in the colour.
    fn reach(j: *Job, ref: *const Frame, mb: *const MbInfo, r: u32) void {
        const c = j.cores orelse return;
        if (@atomicLoad(u32, &ref.progress, .acquire) >= j.rows) return;
        var down: i32 = mb.mv.y;
        if (mb.y_mode == common.SPLITMV) {
            for (mb.mvs) |v| down = @max(down, v.y);
        }
        const y: i32 = @intCast(r);
        const luma = @divFloor(y * 16 + 15 + (down >> 2) + 4, 16);
        const chroma = @divFloor(y * 8 + 7 + (down >> 3) + 4, 8);
        const need = @max(1, @min(@as(i32, @intCast(j.rows)), @max(luma, chroma) + 1));
        c.rows(j.who, ref, @intCast(need));
    }

    fn filterRow(j: *Job, r: u32) void {
        for (0..j.cols) |cu| {
            const c: u32 = @intCast(cu);
            const mb = &j.mbs[r * j.cols + c];
            const st = filter.strength(&j.hdr, &j.seg, &j.deltas, mb);
            filter.macroblock(j.cur, j.hdr.simple_filter, st, mb.inner, r, c);
        }
    }

    fn publish(j: *Job, rows: u32) void {
        @atomicStore(u32, &j.cur.progress, rows, .seq_cst);
        if (j.cores) |c| c.wake(c.ctx);
    }

    /// Its frame and references held, each once, or let go.
    fn hold(j: *Job, comptime take: bool) void {
        for (j.refs[1..], 1..) |slot, i| {
            const f = slot orelse continue;
            if (f == j.refs[1] and i > 1 or f == j.refs[2] and i > 2) continue;
            if (take) f.pinned += 1 else f.pinned -= 1;
        }
        if (take) j.cur.pinned += 1 else j.cur.pinned -= 1;
    }
};

pub const Decoder = struct {
    env: Env,
    frames: [max_frames]Frame = @splat(.{}),
    /// The references by `common.LAST` to `ALTREF`; [0] unused.
    refs: [4]?*Frame = .{ null, null, null, null },
    /// The size shown, and in macroblocks.
    width: u32 = 0,
    height: u32 = 0,
    cols: u32 = 0,
    rows: u32 = 0,
    /// Each macroblock's segment, which stays until a frame gives it
    /// anew.
    segments: []u8 = &.{},
    hdr: common.Header = .{},
    probs: common.Probs = undefined,
    seg: common.Segmentation = .{},
    deltas: common.Deltas = .{},
    quant: [4]common.Quant = @splat(.{}),
    /// A key frame was decoded: inter frames have their references.
    keyed: bool = false,
    /// The last key frame's clamping bit, which ffmpeg takes for the
    /// whole byte rather than BT.601's range.
    full_range: bool = false,

    // --- the frames to show ---
    out: [max_out]*Frame = undefined,
    out_first: u32 = 0,
    out_count: u32 = 0,
    /// The end was sent: a frame still being decoded is waited for.
    flushing: bool = false,

    // --- the other cores ---
    cores: ?*const Cores = null,
    jobs: [max_jobs]?*Job = @splat(null),
    job_order: u32 = 0,

    pub fn create(env: Env) ?*Decoder {
        const bytes = env.alloc(env.ctx, @sizeOf(Decoder), true) orelse return null;
        const dec: *Decoder = @ptrCast(@alignCast(bytes));
        dec.* = .{ .env = env };
        return dec;
    }

    /// Frames decoded on `cores` from now on, as many at once as it has
    /// workers.
    pub fn useCores(dec: *Decoder, cores: *const Cores) void {
        dec.cores = cores;
    }

    pub fn destroy(dec: *Decoder) void {
        const env = dec.env;
        dec.drain();
        for (dec.jobs) |slot| {
            const j = slot orelse continue;
            env.freeSlice(u8, j.data);
            env.freeSlice(MbInfo, j.mbs);
            env.freeSlice(tokens.Nz, j.above_nz);
            env.free(env.ctx, @ptrCast(j), @sizeOf(Job));
        }
        for (&dec.frames) |*f| env.freeSlice(u8, f.memory);
        env.freeSlice(u8, dec.segments);
        env.free(env.ctx, @ptrCast(dec), @sizeOf(Decoder));
    }

    /// Everything dropped, for a seek: the next frame decoded is a key
    /// frame.
    pub fn reset(dec: *Decoder) void {
        dec.drain();
        for (common.LAST..4) |i| dec.setRef(i, null);
        while (dec.out_count != 0) dec.release();
        dec.flushing = false;
        dec.keyed = false;
    }

    /// The next frame to show, or null. It stays valid until `release`.
    /// While the frames are workers' and one of them is free, null: the
    /// frames after it first, so that the worker decodes while the frame
    /// is shown - as long as no more wait to be shown than there are
    /// workers. One a worker still decodes is waited for.
    pub fn next(dec: *Decoder) ?*const Frame {
        if (dec.out_count == 0) return null;
        const f = dec.out[dec.out_first];
        if (dec.cores) |c| {
            if (!dec.flushing and dec.out_count <= c.workers and dec.idle()) return null;
            c.rows(c.workers, f, f.height[0] / 16);
        }
        return f;
    }

    pub fn release(dec: *Decoder) void {
        if (dec.out_count == 0) return;
        dec.out[dec.out_first].queued = false;
        dec.out_first = (dec.out_first + 1) % max_out;
        dec.out_count -= 1;
    }

    /// The end of the stream: every frame decoded is handed out.
    pub fn flush(dec: *Decoder) void {
        dec.flushing = true;
    }

    /// The segment map made for `cols` by `rows` macroblocks, the
    /// references dropped; the frames are made anew as they are needed.
    fn resize(dec: *Decoder, cols: u32, rows: u32) Error!void {
        dec.drain();
        for (common.LAST..4) |i| dec.setRef(i, null);
        const env = dec.env;
        env.freeSlice(u8, dec.segments);
        dec.segments = &.{};
        dec.cols = 0;
        dec.rows = 0;
        dec.segments = env.slice(u8, @as(usize, cols) * rows) orelse return error.NoMemory;
        dec.cols = cols;
        dec.rows = rows;
    }

    /// Frame `data` decoded, shown at `time`: the frame it shows is
    /// handed out by `next`, unless `drop` - due before what is shown -
    /// has it decoded for the frames after it alone. A frame not right is
    /// passed over; the references stay as they were.
    pub fn decodeFrame(dec: *Decoder, data: []const u8, time: i64, drop: bool) Error!void {
        dec.flushing = false;
        if (data.len < 3) return error.Corrupt;
        const tag = @as(u32, data[0]) | @as(u32, data[1]) << 8 | @as(u32, data[2]) << 16;
        const key = tag & 1 == 0;
        const version: u3 = @intCast((tag >> 1) & 7);
        const show = (tag >> 4) & 1 == 1;
        const first_size = tag >> 5;
        if (version > 3) return error.Unsupported;
        var at: usize = 3;
        if (key) {
            if (data.len < 10) return error.Corrupt;
            if (data[3] != 0x9d or data[4] != 0x01 or data[5] != 0x2a) return error.Corrupt;
            const w = (@as(u32, data[6]) | @as(u32, data[7]) << 8) & 0x3FFF;
            const h = (@as(u32, data[8]) | @as(u32, data[9]) << 8) & 0x3FFF;
            if (w == 0 or h == 0) return error.Corrupt;
            at = 10;
            const cols = (w + 15) / 16;
            const rows = (h + 15) / 16;
            if (cols != dec.cols or rows != dec.rows) {
                dec.keyed = false;
                try dec.resize(cols, rows);
            }
            dec.width = w;
            dec.height = h;
        } else if (!dec.keyed) return error.Corrupt;
        if (first_size > data.len - at) return error.Corrupt;
        var b = Bool.init(data[at..][0..first_size]);
        const rest = data[at + first_size ..];

        // What the frame is decoded with - a job, its tables, a frame -
        // before anything of the decoder's changes. A worker reads the
        // partitions after the packet is gone: they are copied.
        const j = try dec.freeJob();
        try dec.fit(j, if (dec.cores != null) rest.len else 0);
        const cur = try dec.freeFrame();
        const parts: []const u8 = if (dec.cores == null) rest else copied: {
            @memcpy(j.data[0..rest.len], rest);
            break :copied j.data[0..rest.len];
        };

        var hdr: common.Header = .{ .key = key, .version = version, .show = show };
        if (key) {
            // The colour space, BT.601 the one there is, and whether the
            // samples need clamping - always done - which ffmpeg takes
            // for the whole byte.
            _ = b.flag();
            dec.full_range = b.flag();
            dec.seg = .{};
            dec.deltas = .{};
        }
        dec.readSegmentation(&b);
        hdr.simple_filter = b.flag();
        hdr.filter_level = @intCast(b.literal(6));
        hdr.sharpness = @intCast(b.literal(3));
        dec.deltas.enabled = b.flag();
        if (dec.deltas.enabled and b.flag()) {
            for (&dec.deltas.ref) |*d| {
                if (b.flag()) d.* = @intCast(signed(&b, 6));
            }
            for (&dec.deltas.mode) |*d| {
                if (b.flag()) d.* = @intCast(signed(&b, 6));
            }
        }
        hdr.partitions = @as(u8, 1) << @intCast(b.literal(2));
        try readPartitions(j, parts, hdr.partitions);
        dec.readQuant(&b);
        if (key) {
            hdr.refresh_golden = true;
            hdr.refresh_alt = true;
        } else {
            hdr.refresh_golden = b.flag();
            hdr.refresh_alt = b.flag();
            if (!hdr.refresh_golden) hdr.copy_golden = @intCast(b.literal(2));
            if (!hdr.refresh_alt) hdr.copy_alt = @intCast(b.literal(2));
            hdr.sign_bias[common.GOLDEN] = b.flag();
            hdr.sign_bias[common.ALTREF] = b.flag();
        }
        hdr.refresh_entropy = b.flag();
        hdr.refresh_last = if (key) true else b.flag();
        if (key) {
            dec.probs = .{
                .coeff = tables.default_coeff_probs,
                .mv = tables.default_mv_probs,
                .y_mode = tables.default_y_mode_probs,
                .uv_mode = tables.default_uv_mode_probs,
            };
        }
        const saved = dec.probs;
        for (&dec.probs.coeff, &tables.coeff_update_probs) |*kind, *updates| {
            for (kind, updates) |*band, *band_updates| {
                for (band, band_updates) |*ctx, *ctx_updates| {
                    for (ctx, ctx_updates) |*p, u| {
                        if (b.read(u) == 1) p.* = @intCast(b.literal(8));
                    }
                }
            }
        }
        hdr.skip_enabled = b.flag();
        if (hdr.skip_enabled) hdr.prob_skip = @intCast(b.literal(8));
        if (!key) {
            hdr.prob_intra = @intCast(b.literal(8));
            hdr.prob_last = @intCast(b.literal(8));
            hdr.prob_golden = @intCast(b.literal(8));
            if (b.flag()) {
                for (&dec.probs.y_mode) |*p| p.* = @intCast(b.literal(8));
            }
            if (b.flag()) {
                for (&dec.probs.uv_mode) |*p| p.* = @intCast(b.literal(8));
            }
            for (&dec.probs.mv, &tables.mv_update_probs) |*component, *updates| {
                for (component, updates) |*p, u| {
                    if (b.read(u) == 1) {
                        const x: u8 = @intCast(b.literal(7));
                        p.* = if (x != 0) x << 1 else 1;
                    }
                }
            }
        }
        dec.hdr = hdr;

        // The macroblocks' modes, read here; the rest is the job's.
        j.hdr = hdr;
        j.seg = dec.seg;
        j.deltas = dec.deltas;
        j.quant = dec.quant;
        j.coeff_probs = dec.probs.coeff;
        j.refs = dec.refs;
        j.cur = cur;
        j.cols = dec.cols;
        j.rows = dec.rows;
        const ctx: modes.Ctx = .{ .hdr = &dec.hdr, .probs = &dec.probs, .seg = &dec.seg, .segments = dec.segments, .mbs = j.mbs, .cols = dec.cols, .rows = dec.rows };
        for (0..dec.rows) |r| modes.row(&ctx, &b, @intCast(r));
        if (!hdr.refresh_entropy) dec.probs = saved;
        cur.progress = 0;
        cur.time = time;
        cur.shown_width = dec.width;
        cur.shown_height = dec.height;
        cur.full_range = dec.full_range;
        dec.begin(j);

        // The references (9.7, 9.8): the alternate's copy first, as
        // libvpx makes it, then the golden's, then the refreshes.
        switch (hdr.copy_alt) {
            1 => dec.setRef(common.ALTREF, dec.refs[common.LAST]),
            2 => dec.setRef(common.ALTREF, dec.refs[common.GOLDEN]),
            else => {},
        }
        switch (hdr.copy_golden) {
            1 => dec.setRef(common.GOLDEN, dec.refs[common.LAST]),
            2 => dec.setRef(common.GOLDEN, dec.refs[common.ALTREF]),
            else => {},
        }
        if (hdr.refresh_golden) dec.setRef(common.GOLDEN, cur);
        if (hdr.refresh_alt) dec.setRef(common.ALTREF, cur);
        if (hdr.refresh_last) dec.setRef(common.LAST, cur);
        dec.keyed = true;
        if (show and !drop) dec.queue(cur);
    }

    fn setRef(dec: *Decoder, which: usize, f: ?*Frame) void {
        if (dec.refs[which]) |old| old.refs -= 1;
        dec.refs[which] = f;
        if (f) |new| new.refs += 1;
    }

    fn queue(dec: *Decoder, f: *Frame) void {
        if (dec.out_count == max_out) dec.release();
        dec.out[(dec.out_first + dec.out_count) % max_out] = f;
        dec.out_count += 1;
        f.queued = true;
    }

    /// A sign after an `n`-bit magnitude.
    fn signed(b: *Bool, n: u5) i32 {
        const v: i32 = @intCast(b.literal(n));
        return if (b.flag()) -v else v;
    }

    fn readSegmentation(dec: *Decoder, b: *Bool) void {
        const seg = &dec.seg;
        seg.enabled = b.flag();
        if (!seg.enabled) {
            seg.update_map = false;
            seg.update_data = false;
            return;
        }
        seg.update_map = b.flag();
        seg.update_data = b.flag();
        if (seg.update_data) {
            seg.absolute = b.flag();
            for (&seg.quant) |*q| q.* = @intCast(b.maybeSigned(7));
            for (&seg.filter) |*f| f.* = @intCast(b.maybeSigned(6));
        }
        if (seg.update_map) {
            for (&seg.tree_probs) |*p| p.* = if (b.flag()) @intCast(b.literal(8)) else 255;
        }
    }

    /// The coefficient partitions' sizes, three bytes each but the last's,
    /// after the first partition.
    fn readPartitions(j: *Job, rest: []const u8, count: u8) Error!void {
        const table = 3 * @as(usize, count - 1);
        if (rest.len < table) return error.Corrupt;
        var at = table;
        for (0..count) |i| {
            var size: usize = rest.len - at;
            if (i + 1 < count) {
                const s = rest[3 * i ..];
                size = @as(usize, s[0]) | @as(usize, s[1]) << 8 | @as(usize, s[2]) << 16;
                if (size > rest.len - at) return error.Corrupt;
            }
            j.parts[i] = Bool.init(rest[at..][0..size]);
            at += size;
        }
    }

    /// The quantiser indices (9.6) and each segment's factors (14.1), as
    /// libvpx makes them: the segment's index kept to 0..127 before each
    /// kind's delta is added.
    fn readQuant(dec: *Decoder, b: *Bool) void {
        const base: i32 = @intCast(b.literal(7));
        const y_dc = b.maybeSigned(4);
        const y2_dc = b.maybeSigned(4);
        const y2_ac = b.maybeSigned(4);
        const uv_dc = b.maybeSigned(4);
        const uv_ac = b.maybeSigned(4);
        for (&dec.quant, 0..) |*q, i| {
            var index = base;
            if (dec.seg.enabled) index = if (dec.seg.absolute) dec.seg.quant[i] else base + dec.seg.quant[i];
            index = @intCast(clampQ(index));
            q.y = .{ @intCast(tables.dc_q[clampQ(index + y_dc)]), @intCast(tables.ac_q[@intCast(index)]) };
            const y2ac: u32 = @as(u32, tables.ac_q[clampQ(index + y2_ac)]) * 155 / 100;
            q.y2 = .{ @intCast(@as(u32, tables.dc_q[clampQ(index + y2_dc)]) * 2), @intCast(@max(y2ac, 8)) };
            q.uv = .{ @intCast(@min(tables.dc_q[clampQ(index + uv_dc)], 132)), @intCast(tables.ac_q[clampQ(index + uv_ac)]) };
        }
    }

    fn clampQ(v: i32) usize {
        return @intCast(@max(0, @min(127, v)));
    }

    // --- the jobs -------------------------------------------------------------

    /// A job not running: made while there are fewer than the workers -
    /// one without them - and when every one runs, the first once it is
    /// done.
    fn freeJob(dec: *Decoder) Error!*Job {
        const n: usize = if (dec.cores) |c| @max(1, @min(c.workers, max_jobs)) else 1;
        while (true) {
            dec.retire();
            for (dec.jobs[0..n], 0..) |*slot, i| {
                if (slot.*) |j| {
                    if (!j.active) return j;
                    continue;
                }
                const bytes = dec.env.alloc(dec.env.ctx, @sizeOf(Job), true) orelse return error.NoMemory;
                const j: *Job = @ptrCast(@alignCast(bytes));
                j.* = .{ .who = @intCast(i) };
                slot.* = j;
                return j;
            }
            if (!dec.retireOldest()) return error.NoMemory;
        }
    }

    /// Job `j`'s tables for the frame's size, and room for `data` bytes
    /// of partitions.
    fn fit(dec: *Decoder, j: *Job, data: usize) Error!void {
        const env = dec.env;
        const count = @as(usize, dec.cols) * dec.rows;
        if (j.mbs.len != count) {
            env.freeSlice(MbInfo, j.mbs);
            env.freeSlice(tokens.Nz, j.above_nz);
            j.mbs = &.{};
            j.above_nz = &.{};
            const mbs = env.slice(MbInfo, count) orelse return error.NoMemory;
            j.above_nz = env.slice(tokens.Nz, dec.cols) orelse {
                env.freeSlice(MbInfo, mbs);
                return error.NoMemory;
            };
            j.mbs = mbs;
        }
        if (j.data.len < data) {
            env.freeSlice(u8, j.data);
            j.data = &.{};
            j.data = env.slice(u8, data + data / 4) orelse return error.NoMemory;
        }
    }

    /// A frame no reference, job or wait for showing holds, of the size
    /// decoded: one made, or one of another size made anew, when there is
    /// none; when every one is held, once the first job is done.
    fn freeFrame(dec: *Decoder) Error!*Frame {
        const w = dec.cols * 16;
        const h = dec.rows * 16;
        while (true) {
            dec.retire();
            var spare: ?*Frame = null;
            for (&dec.frames) |*f| {
                if (f.refs != 0 or f.pinned != 0 or f.queued) continue;
                if (f.memory.len != 0 and f.width[0] == w and f.height[0] == h) return f;
                if (spare == null) spare = f;
            }
            if (spare) |f| {
                if (dec.make(f, w, h)) return f;
            }
            if (!dec.retireOldest()) return error.NoMemory;
        }
    }

    /// Frame `f`'s planes made for `w` by `h`.
    fn make(dec: *Decoder, f: *Frame, w: u32, h: u32) bool {
        const env = dec.env;
        env.freeSlice(u8, f.memory);
        f.* = .{};
        const luma: usize = @as(usize, w) * h;
        const memory = env.slice(u8, luma + luma / 2) orelse return false;
        f.* = .{
            .planes = .{ memory.ptr, memory.ptr + luma, memory.ptr + luma + luma / 4 },
            .stride = .{ w, w / 2, w / 2 },
            .width = .{ w, w / 2, w / 2 },
            .height = .{ h, h / 2, h / 2 },
            .memory = memory,
        };
        return true;
    }

    /// Job `j` begun, its frame and references held until it is done: on
    /// its worker, or run here without workers.
    fn begin(dec: *Decoder, j: *Job) void {
        j.hold(true);
        j.cores = dec.cores;
        j.done = false;
        j.active = true;
        j.order = dec.job_order;
        dec.job_order +%= 1;
        if (dec.cores) |c| return c.run(c.ctx, j.who, Job.run, j);
        j.decode();
        j.hold(false);
        j.active = false;
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

    /// Every job done: the decoder goes on alone.
    fn drain(dec: *Decoder) void {
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
};

// --- tests (host: ./zig build test) -----------------------------------------

const std = @import("std");
const testing = std.testing;

/// Workers on threads that wait by yielding: `sleep` returns at once,
/// as it may.
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
    /// After so many frames: everything dropped, as for a seek, and the
    /// stream decoded from its start again.
    reset_after: ?u32 = null,
    /// After so many frames: the decoder closed, whatever it is doing.
    stop_after: ?u32 = null,
    /// Each frame cut to this part of it, in sixteenths.
    cut: u32 = 16,
    /// Each frame taken as soon as there is one, as a program would not.
    eager: bool = false,
};

/// Every frame of an IVF file shown, in a decoder made for it: how many
/// shown and not right, and FNV-1a of their planes at the size shown.
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
        while (dec.next()) |f| {
            for (0..3) |p| {
                const w = if (p == 0) f.shown_width else (f.shown_width + 1) / 2;
                const h = if (p == 0) f.shown_height else (f.shown_height + 1) / 2;
                for (0..h) |r| {
                    for (f.planes[p][r * f.stride[p] ..][0..w]) |byte| got.hash = (got.hash ^ byte) *% 0x100000001b3;
                }
            }
            got.shown += 1;
            dec.release();
            if (!way.eager) break;
        }
        if (dec.flushing and dec.out_count == 0) return got;
    }
}

// tests/rows.ivf: libvpx (two passes, alternate references, four token
// partitions) of ffmpeg's testsrc2 at 136x104, 24 frames shown and two
// hidden, a key frame every 12. tests/simple.ivf: likewise with profile
// 3 - the bilinear filter, the simple loop filter, whole-sample colour
// vectors - 12 frames. The hashes are of libvpx's decode.
test "frames decoded as libvpx decodes them, alone and on three workers, after a seek, a close and damaged ones" {
    var t: TestCores = .{};
    t.cores = .{ .ctx = &t, .workers = 3, .run = TestCores.run, .arm = TestCores.arm, .sleep = TestCores.sleep, .wake = TestCores.wake };
    for (&t.threads, 0..) |*th, i| th.* = try std.Thread.spawn(.{}, TestCores.work, .{ &t, i });
    defer {
        @atomicStore(bool, &t.quit, true, .seq_cst);
        for (t.threads) |th| th.join();
    }
    const streams = [_]struct { ivf: []const u8, expect: Decoded }{
        .{ .ivf = @embedFile("tests/rows.ivf"), .expect = .{ .shown = 24, .hash = 0xfa41b1b7e0221074 } },
        .{ .ivf = @embedFile("tests/simple.ivf"), .expect = .{ .shown = 12, .hash = 0x5bb6cb6168e1fbf3 } },
    };
    for (streams) |s| {
        for ([_]?*const Cores{ null, &t.cores }) |cores| {
            try testing.expectEqual(s.expect, try decodeAll(s.ivf, cores, .{}));
            try testing.expectEqual(s.expect, try decodeAll(s.ivf, cores, .{ .eager = true }));
            for ([_]u32{ 3, 9, 14 }) |at| {
                try testing.expectEqual(s.expect, try decodeAll(s.ivf, cores, .{ .reset_after = at }));
                _ = try decodeAll(s.ivf, cores, .{ .stop_after = at });
            }
            // Frames cut short: some come out, wrong; nothing is caught.
            for ([_]u32{ 1, 5, 8, 15 }) |cut| _ = try decodeAll(s.ivf, cores, .{ .cut = cut });
        }
    }
}
