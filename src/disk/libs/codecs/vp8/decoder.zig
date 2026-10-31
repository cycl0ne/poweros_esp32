// SPDX-License-Identifier: MIT
//! The VP8 decoder (RFC 6386): a frame in, the frame to show out - VP8
//! shows its frames in the order they come, those it does not hide.
//!
//! A frame is its header (9, 19.2), the macroblocks' headers in the first
//! partition and their coefficients in one to eight more, a row each in
//! turn. Each row is put together - predicted and its residue added - and
//! the row above it filtered once it is, since intra prediction reads the
//! neighbours unfiltered. The frame then becomes the last frame, the
//! golden or the alternate reference as its header says; the
//! probabilities it changed stay unless it said they are for it alone.

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

/// The frames: the one being decoded and the three references, which may
/// be the same.
const frame_count = 4;

pub const Decoder = struct {
    env: Env,
    frames: [frame_count]Frame = @splat(.{}),
    /// The references by `common.LAST` to `ALTREF`; [0] unused.
    refs: [4]?*Frame = .{ null, null, null, null },
    /// The size shown, and in macroblocks.
    width: u32 = 0,
    height: u32 = 0,
    cols: u32 = 0,
    rows: u32 = 0,
    mbs: []MbInfo = &.{},
    above_nz: []tokens.Nz = &.{},
    hdr: common.Header = .{},
    probs: common.Probs = undefined,
    seg: common.Segmentation = .{},
    deltas: common.Deltas = .{},
    quant: [4]common.Quant = @splat(.{}),
    coeffs: tokens.Coeffs = @splat(@splat(0)),
    /// The partitions of the coefficients.
    parts: [8]Bool = @splat(.{}),
    scratch: recon.Scratch = .{},
    workspace: recon.Workspace = .{},
    /// A key frame was decoded: inter frames have their references.
    keyed: bool = false,
    /// The last key frame's clamping bit, which ffmpeg takes for the
    /// whole byte rather than BT.601's range.
    full_range: bool = false,

    pub fn create(env: Env) ?*Decoder {
        const bytes = env.alloc(env.ctx, @sizeOf(Decoder), true) orelse return null;
        const dec: *Decoder = @ptrCast(@alignCast(bytes));
        dec.* = .{ .env = env };
        return dec;
    }

    pub fn destroy(dec: *Decoder) void {
        const env = dec.env;
        dec.freeFrames();
        env.free(env.ctx, @ptrCast(dec), @sizeOf(Decoder));
    }

    fn freeFrames(dec: *Decoder) void {
        const env = dec.env;
        for (&dec.frames) |*f| {
            if (f.memory.len != 0) env.freeSlice(u8, f.memory);
            f.* = .{};
        }
        dec.refs = .{ null, null, null, null };
        env.freeSlice(MbInfo, dec.mbs);
        env.freeSlice(tokens.Nz, dec.above_nz);
        dec.mbs = &.{};
        dec.above_nz = &.{};
        dec.cols = 0;
        dec.rows = 0;
    }

    /// The references dropped, for a seek: the next frame decoded is a
    /// key frame.
    pub fn reset(dec: *Decoder) void {
        for (&dec.refs) |*r| r.* = null;
        for (&dec.frames) |*f| f.refs = 0;
        dec.keyed = false;
    }

    /// The frames and tables made for `cols` by `rows` macroblocks.
    fn resize(dec: *Decoder, cols: u32, rows: u32) Error!void {
        dec.freeFrames();
        const env = dec.env;
        const w = cols * 16;
        const h = rows * 16;
        const luma: usize = @as(usize, w) * h;
        for (&dec.frames) |*f| {
            const memory = env.slice(u8, luma + luma / 2) orelse return error.NoMemory;
            f.* = .{
                .planes = .{ memory.ptr, memory.ptr + luma, memory.ptr + luma + luma / 4 },
                .stride = .{ w, w / 2, w / 2 },
                .width = .{ w, w / 2, w / 2 },
                .height = .{ h, h / 2, h / 2 },
                .memory = memory,
            };
        }
        dec.mbs = env.slice(MbInfo, @as(usize, cols) * rows) orelse return error.NoMemory;
        dec.above_nz = env.slice(tokens.Nz, cols) orelse return error.NoMemory;
        for (dec.mbs) |*mb| mb.* = .{};
        dec.cols = cols;
        dec.rows = rows;
    }

    /// Frame `data` decoded: the frame to show, or null for one hidden.
    /// A frame not right is passed over; the references stay as they
    /// were.
    pub fn decodeFrame(dec: *Decoder, data: []const u8) Error!?*const Frame {
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
        try dec.readPartitions(rest, hdr.partitions);
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
        for (0..4) |i| {
            for (0..8) |j| {
                for (0..3) |k| {
                    for (0..11) |l| {
                        if (b.read(tables.coeff_update_probs[i][j][k][l]) == 1) dec.probs.coeff[i][j][k][l] = @intCast(b.literal(8));
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
            for (0..2) |i| {
                for (0..19) |j| {
                    if (b.read(tables.mv_update_probs[i][j]) == 1) {
                        const x: u8 = @intCast(b.literal(7));
                        dec.probs.mv[i][j] = if (x != 0) x << 1 else 1;
                    }
                }
            }
        }
        dec.hdr = hdr;

        const cur = dec.freeFrame() orelse return error.Corrupt;
        cur.refs = 1;
        dec.decodeMacroblocks(&b, cur);
        if (!hdr.refresh_entropy) dec.probs = saved;

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
        cur.refs -= 1;
        dec.keyed = true;
        return if (show) cur else null;
    }

    fn setRef(dec: *Decoder, which: usize, f: ?*Frame) void {
        if (dec.refs[which]) |old| old.refs -= 1;
        dec.refs[which] = f;
        if (f) |new| new.refs += 1;
    }

    fn freeFrame(dec: *Decoder) ?*Frame {
        for (&dec.frames) |*f| {
            if (f.refs == 0 and f.memory.len != 0) return f;
        }
        return null;
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
    fn readPartitions(dec: *Decoder, rest: []const u8, count: u8) Error!void {
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
            dec.parts[i] = Bool.init(rest[at..][0..size]);
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

    fn decodeMacroblocks(dec: *Decoder, b: *Bool, cur: *Frame) void {
        const ctx: modes.Ctx = .{ .hdr = &dec.hdr, .probs = &dec.probs, .seg = &dec.seg, .mbs = dec.mbs, .cols = dec.cols, .rows = dec.rows };
        for (dec.above_nz) |*nz| nz.* = @splat(0);
        const filtering = dec.hdr.filter_level != 0;
        for (0..dec.rows) |ru| {
            const r: u32 = @intCast(ru);
            modes.row(&ctx, b, r);
            const part = &dec.parts[r & (dec.hdr.partitions - 1)];
            var left: tokens.Nz = @splat(0);
            for (0..dec.cols) |cu| {
                const c: u32 = @intCast(cu);
                const mb = &dec.mbs[r * dec.cols + c];
                const has_y2 = mb.y_mode != common.B_PRED and mb.y_mode != common.SPLITMV;
                var mask: u32 = 0;
                if (mb.skip) {
                    tokens.skip(&left, &dec.above_nz[c], has_y2);
                } else {
                    mask = tokens.macroblock(part, &dec.probs.coeff, &left, &dec.above_nz[c], &dec.coeffs, has_y2, &dec.quant[mb.segment]);
                }
                mb.inner = mask != 0 or !has_y2;
                if (mb.ref == common.INTRA) {
                    recon.intra(mb, &dec.coeffs, mask, cur, r, c, dec.cols, &dec.workspace);
                } else {
                    const ref = dec.refs[mb.ref] orelse dec.refs[common.LAST].?;
                    recon.inter(mb, &dec.coeffs, mask, cur, ref, r, c, dec.hdr.version, &dec.scratch);
                }
            }
            if (filtering and r > 0) dec.filterRow(cur, r - 1);
        }
        if (filtering) dec.filterRow(cur, dec.rows - 1);
    }

    fn filterRow(dec: *Decoder, cur: *Frame, r: u32) void {
        for (0..dec.cols) |cu| {
            const c: u32 = @intCast(cu);
            const mb = &dec.mbs[r * dec.cols + c];
            const st = filter.strength(&dec.hdr, &dec.seg, &dec.deltas, mb);
            filter.macroblock(cur, dec.hdr.simple_filter, st, mb.inner, r, c);
        }
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

const Decoded = struct { shown: u32 = 0, hidden: u32 = 0, errors: u32 = 0, hash: u64 = 0xcbf29ce484222325 };

const Way = struct {
    /// After so many frames: the references dropped, as for a seek, and
    /// the stream decoded from its start again.
    reset_after: ?u32 = null,
    /// Each frame cut to this part of it, in sixteenths.
    cut: u32 = 16,
};

/// Every frame of an IVF file: how many shown, hidden and not right, and
/// FNV-1a of the planes of those shown at the size shown.
fn decodeAll(dec: *Decoder, ivf: []const u8, way: Way) Decoded {
    const start = std.mem.readInt(u16, ivf[6..8], .little);
    var got: Decoded = .{};
    var at: usize = start;
    var count: u32 = 0;
    while (at + 12 <= ivf.len) {
        count += 1;
        if (way.reset_after == count) {
            dec.reset();
            got = .{};
            at = start;
        }
        const size = std.mem.readInt(u32, ivf[at..][0..4], .little);
        const data = ivf[at + 12 ..][0 .. size * way.cut / 16];
        at += 12 + size;
        const f = (dec.decodeFrame(data) catch {
            got.errors += 1;
            continue;
        }) orelse {
            got.hidden += 1;
            continue;
        };
        const cw = (dec.width + 1) / 2;
        const ch = (dec.height + 1) / 2;
        const size_shown = [3][2]u32{ .{ dec.width, dec.height }, .{ cw, ch }, .{ cw, ch } };
        for (0..3) |p| {
            for (0..size_shown[p][1]) |r| {
                for (f.planes[p][r * f.stride[p] ..][0..size_shown[p][0]]) |byte| got.hash = (got.hash ^ byte) *% 0x100000001b3;
            }
        }
        got.shown += 1;
    }
    return got;
}

// tests/rows.ivf: libvpx (two passes, alternate references, four token
// partitions) of ffmpeg's testsrc2 at 136x104, 24 frames shown and two
// hidden, a key frame every 12. tests/simple.ivf: likewise with profile
// 3 - the bilinear filter, the simple loop filter, whole-sample colour
// vectors - 12 frames. The hashes are of libvpx's decode.
test "frames decoded as libvpx decodes them, after a seek too, and after damaged ones" {
    var ctx: u8 = 0;
    const env: Env = .{ .ctx = &ctx, .alloc = TestMemory.alloc, .free = TestMemory.free };
    const dec = Decoder.create(env) orelse return error.OutOfMemory;
    defer dec.destroy();
    const streams = [_]struct { ivf: []const u8, expect: Decoded }{
        .{ .ivf = @embedFile("tests/rows.ivf"), .expect = .{ .shown = 24, .hidden = 2, .hash = 0xfa41b1b7e0221074 } },
        .{ .ivf = @embedFile("tests/simple.ivf"), .expect = .{ .shown = 12, .hash = 0x5bb6cb6168e1fbf3 } },
    };
    for (streams) |s| {
        try testing.expectEqual(s.expect, decodeAll(dec, s.ivf, .{}));
        for ([_]u32{ 3, 9, 14 }) |at| try testing.expectEqual(s.expect, decodeAll(dec, s.ivf, .{ .reset_after = at }));
        // Frames cut short: some come out, wrong, nothing is caught.
        for ([_]u32{ 1, 5, 8, 15 }) |cut| _ = decodeAll(dec, s.ivf, .{ .cut = cut });
        dec.reset();
        try testing.expectEqual(s.expect, decodeAll(dec, s.ivf, .{}));
    }
}
