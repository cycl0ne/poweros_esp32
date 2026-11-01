// SPDX-License-Identifier: MIT
//! The macroblock layer (7.3.5): a macroblock's type, its prediction -
//! intra modes, or reference indices and motion vector differences - its
//! coded block pattern, its change of quantiser and its residual, read
//! with CAVLC (9.2) or CABAC (9.3) into an `Mb`, the coefficients scaled.
//!
//! The neighbours of a macroblock are found by where their samples lie:
//! a neighbouring sample's row in the frame tells the pair it is in and,
//! by that pair's being frame or field, which of its two macroblocks
//! holds it. That is table 6-4 of the standard, and for pictures without
//! MBAFF it reduces to the macroblock to the left and the one above.

const common = @import("common.zig");
const MbInfo = common.MbInfo;
const Kind = common.Kind;
const bits_mod = @import("bits.zig");
const Bits = bits_mod.Bits;
const Error = bits_mod.Error;
const cabac = @import("cabac.zig");
const cavlc = @import("cavlc.zig");
const params = @import("params.zig");
const slice_mod = @import("slice.zig");
const transform = @import("transform.zig");

pub const Shape = enum(u2) { p16x16, p16x8, p8x16, p8x8 };
pub const SubShape = enum(u2) { s8x8, s8x4, s4x8, s4x4 };

/// A partition's lists: bit 0 list 0, bit 1 list 1.
pub const L0: u2 = 1;
pub const L1: u2 = 2;

/// A neighbouring macroblock and the row of it next to the current one,
/// in 4x4 blocks.
pub const Side = struct { xy: u32, row: u8 };

pub const Nb = struct {
    /// The macroblocks holding luma (-1, 0) and (0, -1) (6.4.11.1).
    a: ?u32 = null,
    b: ?u32 = null,
    /// Left of each row of 4x4 luma blocks, and of chroma blocks.
    left: [4]?Side = @splat(null),
    left_c: [4]?Side = @splat(null),
    /// Above right (its last row) and above left.
    c: ?u32 = null,
    d: ?Side = null,
};

/// What a slice's macroblocks are read with, and the macroblock being
/// read: set up by the decoder.
pub const Dec = struct {
    sps: *const params.Sps,
    pps: *const params.Pps,
    hdr: *const slice_mod.Header,
    infos: []MbInfo,
    width: u32,
    mbaff: bool,
    field_pic: bool,
    /// ChromaArrayType.
    cat: u2,
    /// The height of a macroblock's chroma, 0 without.
    mbh_c: u32,
    slice_id: u32,
    scales: *const transform.Scales,
    /// Slice data partitioning: the residual of intra macroblocks from
    /// partition B, of inter ones from C.
    partitioned: bool = false,
    bits: Bits = .{ .data = &.{} },
    bits_b: Bits = .{ .data = &.{} },
    bits_c: Bits = .{ .data = &.{} },
    has_b: bool = false,
    has_c: bool = false,
    eng: cabac.Engine = undefined,
    ctx: [1024]u8 = undefined,
    /// QPY of the macroblock before, and whether it had a non-zero
    /// mb_qp_delta (CABAC's context).
    qp: i32 = 0,
    last_dqp: bool = false,

    // The macroblock being read.
    mb_x: u32 = 0,
    mb_y: u32 = 0,
    xy: u32 = 0,
    field: bool = false,
    nb: Nb = .{},

    fn useCabac(d: *const Dec) bool {
        return d.pps.cabac;
    }

    /// The macroblock holding a neighbouring sample: `dx` macroblocks
    /// across (-1, 0, 1) and row `y` of the current one (-1 above), in a
    /// plane whose macroblocks are `mbh` high; with the row of it.
    pub fn owner(d: *const Dec, dx: i32, y: i32, mbh: u32) ?struct { xy: u32, row: u32 } {
        const nx = @as(i32, @intCast(d.mb_x)) + dx;
        if (nx < 0 or nx >= @as(i32, @intCast(d.width))) return null;
        const ux: u32 = @intCast(nx);
        const w = d.width;
        var xy: u32 = undefined;
        var row: u32 = undefined;
        if (!d.mbaff) {
            if (y < 0) {
                const step: u32 = if (d.field_pic) 2 else 1;
                if (d.mb_y < step) return null;
                xy = (d.mb_y - step) * w + ux;
                row = mbh - 1;
            } else {
                if (dx >= 0) return null;
                xy = d.mb_y * w + ux;
                row = @intCast(y);
            }
        } else {
            const h: i32 = @intCast(mbh);
            const pair_h = 2 * h;
            const pair_y0: i32 = @as(i32, @intCast(d.mb_y >> 1)) * pair_h;
            const bottom: i32 = @intCast(d.mb_y & 1);
            const y0 = if (d.field) pair_y0 + bottom else pair_y0 + bottom * h;
            const yy = y0 + (if (d.field) @as(i32, 2) else 1) * y;
            if (yy < 0) return null;
            const pr = @divFloor(yy, pair_h);
            const o = yy - pr * pair_h;
            const top: u32 = @as(u32, @intCast(2 * pr)) * w + ux;
            if (d.infos[top].slice != d.slice_id) return null;
            if (d.infos[top].flags & common.F_FIELD != 0) {
                xy = top + @as(u32, @intCast(o & 1)) * w;
                row = @intCast(o >> 1);
            } else {
                xy = top + (if (o >= h) w else 0);
                row = @intCast(@mod(o, h));
            }
        }
        if (d.infos[xy].slice != d.slice_id) return null;
        return .{ .xy = xy, .row = row };
    }

    /// The neighbours of the current macroblock, for its field flag as it
    /// is now.
    pub fn neighbours(d: *Dec) void {
        var nb: Nb = .{};
        if (d.owner(-1, 0, 16)) |o| nb.a = o.xy;
        if (d.owner(0, -1, 16)) |o| nb.b = o.xy;
        for (0..4) |r| {
            if (d.owner(-1, @intCast(4 * r), 16)) |o| nb.left[r] = .{ .xy = o.xy, .row = @intCast(o.row >> 2) };
        }
        if (d.mbh_c != 0) {
            for (0..d.mbh_c / 4) |r| {
                if (d.owner(-1, @intCast(4 * r), d.mbh_c)) |o| nb.left_c[r] = .{ .xy = o.xy, .row = @intCast(o.row >> 2) };
            }
        }
        if (d.owner(1, -1, 16)) |o| nb.c = o.xy;
        if (d.owner(-1, -1, 16)) |o| nb.d = .{ .xy = o.xy, .row = @intCast(o.row >> 2) };
        d.nb = nb;
    }

    pub fn info(d: *const Dec, xy: u32) *MbInfo {
        return &d.infos[xy];
    }

    /// The pairs to the left and above, for mb_field_decoding_flag's
    /// context and its inference (7.4.4).
    pub fn pairField(d: *const Dec, left: bool) ?bool {
        const top_y = d.mb_y & ~@as(u32, 1);
        var xy: u32 = undefined;
        if (left) {
            if (d.mb_x == 0) return null;
            xy = top_y * d.width + d.mb_x - 1;
        } else {
            if (top_y < 2) return null;
            xy = (top_y - 2) * d.width + d.mb_x;
        }
        if (d.infos[xy].slice != d.slice_id) return null;
        return d.infos[xy].flags & common.F_FIELD != 0;
    }
};

/// A macroblock as read.
pub const Mb = struct {
    kind: Kind = .inter,
    skip: bool = false,
    shape: Shape = .p16x16,
    /// The lists of each partition (16x16: [0]; 16x8, 8x16: [0] and [1];
    /// 8x8: each sub-macroblock's).
    pred: [4]u2 = @splat(0),
    sub: [4]SubShape = @splat(.s8x8),
    /// The 8x8 blocks predicted in direct mode.
    direct: u8 = 0,
    /// B_Skip or B_Direct_16x16, not a B_8x8 whose blocks are all direct.
    direct16: bool = false,
    ref: [2][4]i8 = @splat(@splat(-1)),
    /// Each 4x4 block's mvd (raster), both lists.
    mvd: [2][16][2]i32 = @splat(@splat(.{ 0, 0 })),
    /// Intra 4x4 / 8x8 modes by raster 4x4 block.
    i_modes: [16]u8 = @splat(2),
    i16_mode: u8 = 0,
    chroma_mode: u8 = 0,
    t8x8: bool = false,
    cbp: u8 = 0,
    qp: i32 = 0,
    qp_delta: i32 = 0,
    /// TransformBypassModeFlag: the residual is the coefficients.
    lossless: bool = false,
    /// TotalCoeff of each 4x4 block: luma, Cb and Cr on grids four wide.
    nnz: [48]u8 = @splat(0),
    nz8: u16 = 0,
    cbf_dc: u8 = 0,
    /// The scaled coefficients of each 4x4 block (raster) and of each 8x8
    /// block, by plane; the blocks that have any. An SP or SI macroblock's
    /// are its levels as they came, a chroma block's DC level at [0].
    coef: [3][16][16]i32 = undefined,
    coef8: [3][4][64]i32 = undefined,
    mask4: [3]u16 = @splat(0),
    mask8: [3]u8 = @splat(0),
    /// I_PCM's samples: luma, then Cb, then Cr.
    pcm: [3 * 256]u16 = undefined,

    pub fn isIntra(m: *const Mb) bool {
        return m.kind != .inter;
    }

    /// Every field as a new macroblock's, but the coefficients and the
    /// PCM samples: they are written before they are read, and copying
    /// them, as `.{}` does, would be most of the work.
    pub fn reset(m: *Mb) void {
        inline for (@typeInfo(Mb).@"struct".fields) |f| {
            const kept = comptime same(f.name, "coef") or same(f.name, "coef8") or same(f.name, "pcm");
            if (!kept) @field(m, f.name) = f.defaultValue().?;
        }
    }

    fn same(comptime a: []const u8, comptime b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| if (x != y) return false;
        return true;
    }

    /// sMbFlag (8.5.12): SI, or inter in an SP slice; 8.6 puts its levels
    /// together with its prediction.
    pub fn switching(m: *const Mb, slice: slice_mod.Kind) bool {
        return m.kind == .si or (m.kind == .inter and slice == .sp);
    }
};

// --- type tables (7.3.5, tables 7-11 to 7-18) --------------------------------

const MbClass = enum { i, si, p, b };
const MbType = struct { class: MbClass, v: u32 };

/// B_x_y's partitions' lists, by (mb_type - 4) / 2 (table 7-14).
const b_pairs = [9][2]u2{
    .{ L0, L0 },      .{ L1, L1 },      .{ L0, L1 },
    .{ L1, L0 },      .{ L0, L0 | L1 }, .{ L1, L0 | L1 },
    .{ L0 | L1, L0 }, .{ L0 | L1, L1 }, .{ L0 | L1, L0 | L1 },
};

/// B sub-macroblock types (table 7-18): lists and shape; 0 is direct.
const b_sub = [13]struct { pred: u2, shape: SubShape }{
    .{ .pred = 0, .shape = .s8x8 },
    .{ .pred = L0, .shape = .s8x8 },
    .{ .pred = L1, .shape = .s8x8 },
    .{ .pred = L0 | L1, .shape = .s8x8 },
    .{ .pred = L0, .shape = .s8x4 },
    .{ .pred = L0, .shape = .s4x8 },
    .{ .pred = L1, .shape = .s8x4 },
    .{ .pred = L1, .shape = .s4x8 },
    .{ .pred = L0 | L1, .shape = .s8x4 },
    .{ .pred = L0 | L1, .shape = .s4x8 },
    .{ .pred = L0, .shape = .s4x4 },
    .{ .pred = L1, .shape = .s4x4 },
    .{ .pred = L0 | L1, .shape = .s4x4 },
};

/// codeNum to coded_block_pattern (table 9-4): ChromaArrayType 1 or 2,
/// intra and inter; 0 or 3, intra and inter.
const cbp_intra = [48]u8{
    47, 31, 15, 0,  23, 27, 29, 30, 7,  11, 13, 14, 39, 43, 45, 46,
    16, 3,  5,  10, 12, 19, 21, 26, 28, 35, 37, 42, 44, 1,  2,  4,
    8,  17, 18, 20, 24, 6,  9,  22, 25, 32, 33, 34, 36, 40, 38, 41,
};
const cbp_inter = [48]u8{
    0,  16, 1,  2,  4,  8,  32, 3,  5,  10, 12, 15, 47, 7,  11, 13,
    14, 6,  9,  31, 35, 37, 42, 44, 33, 34, 36, 40, 39, 43, 45, 46,
    17, 18, 20, 24, 19, 21, 26, 28, 23, 27, 29, 30, 22, 25, 38, 41,
};
const cbp_intra_gray = [16]u8{ 15, 0, 7, 11, 13, 14, 3, 5, 10, 12, 1, 2, 4, 8, 6, 9 };
const cbp_inter_gray = [16]u8{ 0, 1, 2, 4, 8, 3, 5, 10, 12, 15, 7, 11, 13, 14, 6, 9 };

/// The chroma QP of a luma QP (table 8-15), for qPI from 30 on.
const chroma_qp_tail = [22]u8{ 29, 30, 31, 32, 32, 33, 34, 34, 35, 35, 36, 36, 37, 37, 37, 38, 38, 38, 39, 39, 39, 39 };

/// QPc of a QPY with an offset (8.5.8), without QpBdOffsetC.
pub fn chromaQp(qp_y: i32, offset: i32, qp_bd_c: i32) i32 {
    const qpi = @max(-qp_bd_c, @min(51, qp_y + offset));
    return if (qpi < 30) qpi else chroma_qp_tail[@intCast(qpi - 30)];
}

/// 4:2:2's chroma DC scan: the raster position (row * 2 + column) of each.
const chroma422_dc_scan = [8]u8{ 0, 2, 1, 4, 6, 3, 5, 7 };

// --- CABAC: context index offsets (table 9-34) -------------------------------

const cbf_base = [14]u16{ 85, 89, 93, 97, 101, 1012, 460, 464, 468, 1016, 472, 476, 480, 1020 };
const sig_base = [2][14]u16{
    .{ 105 + 0, 105 + 15, 105 + 29, 105 + 44, 105 + 47, 402, 484 + 0, 484 + 15, 484 + 29, 660, 528 + 0, 528 + 15, 528 + 29, 718 },
    .{ 277 + 0, 277 + 15, 277 + 29, 277 + 44, 277 + 47, 436, 776 + 0, 776 + 15, 776 + 29, 675, 820 + 0, 820 + 15, 820 + 29, 733 },
};
const last_base = [2][14]u16{
    .{ 166 + 0, 166 + 15, 166 + 29, 166 + 44, 166 + 47, 417, 572 + 0, 572 + 15, 572 + 29, 690, 616 + 0, 616 + 15, 616 + 29, 748 },
    .{ 338 + 0, 338 + 15, 338 + 29, 338 + 44, 338 + 47, 451, 864 + 0, 864 + 15, 864 + 29, 699, 908 + 0, 908 + 15, 908 + 29, 757 },
};
const abs_base = [14]u16{ 227 + 0, 227 + 10, 227 + 20, 227 + 30, 227 + 39, 426, 952 + 0, 952 + 10, 952 + 20, 708, 982 + 0, 982 + 10, 982 + 20, 766 };

/// Table 9-43: ctxIdxInc of significant_coeff_flag in 8x8 blocks, frame
/// and field, and of last_significant_coeff_flag (both).
const sig8 = [2][63]u8{
    .{
        0,  1,  2,  3,  4,  5,  5,  4, 4,  3,  3,  4,  4,  4,  5,  5,
        4,  4,  4,  4,  3,  3,  6,  7, 7,  7,  8,  9,  10, 9,  8,  7,
        7,  6,  11, 12, 13, 11, 6,  7, 8,  9,  14, 10, 9,  8,  6,  11,
        12, 13, 11, 6,  9,  14, 10, 9, 11, 12, 13, 11, 14, 10, 12,
    },
    .{
        0, 1,  1,  2,  2,  3,  3,  4,  5,  6,  7,  7,  7,  8,  4,  5,
        6, 9,  10, 10, 8,  11, 12, 11, 9,  9,  10, 10, 8,  11, 12, 11,
        9, 9,  10, 10, 8,  11, 12, 11, 9,  9,  10, 10, 8,  13, 13, 9,
        9, 10, 10, 8,  13, 13, 9,  9,  10, 10, 14, 14, 14, 14, 14,
    },
};
const last8 = [63]u8{
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4,
    5, 5, 5, 5, 6, 6, 6, 6, 7, 7, 7, 7, 8, 8, 8,
};

inline fn bin(d: *Dec, i: usize) u1 {
    return d.eng.decision(&d.ctx[i]);
}

inline fn bypassBits(d: *Dec, k0: u5) u32 {
    // Exp-Golomb of order k, bypass coded (9.3.2.3).
    var k = k0;
    var v: u32 = 0;
    while (d.eng.bypass() == 1) {
        v +%= @as(u32, 1) << k;
        if (k >= 30) break;
        k += 1;
    }
    while (k > 0) {
        k -= 1;
        v +%= @as(u32, d.eng.bypass()) << k;
    }
    return v;
}

// --- neighbour values ----------------------------------------------------------

fn kindIsNxN(k: Kind) bool {
    return k == .i4x4 or k == .i8x8;
}

/// TotalCoeff of the 4x4 block left of / above block (bx, by) of plane
/// `p` (9.2.1), null when there is none; `chroma` for 4:2:0 / 4:2:2's
/// chroma blocks.
fn nnzLeft(d: *const Dec, m: *const Mb, p: usize, bx: u32, by: u32, chroma: bool) ?u8 {
    if (bx > 0) return m.nnz[p * 16 + by * 4 + bx - 1];
    const side = (if (chroma) d.nb.left_c[by] else d.nb.left[by]) orelse return null;
    const n = d.info(side.xy);
    if (d.partitioned and m.isIntra() and d.pps.constrained_intra_pred and n.flags & common.F_INTRA == 0) return 0;
    const last: u32 = if (chroma) 1 else 3;
    return n.nnz[p * 16 + @as(u32, side.row) * 4 + last];
}

fn nnzTop(d: *const Dec, m: *const Mb, p: usize, bx: u32, by: u32, chroma: bool) ?u8 {
    if (by > 0) return m.nnz[p * 16 + (by - 1) * 4 + bx];
    const xy = d.nb.b orelse return null;
    const n = d.info(xy);
    if (d.partitioned and m.isIntra() and d.pps.constrained_intra_pred and n.flags & common.F_INTRA == 0) return 0;
    const last: u32 = if (chroma) d.mbh_c / 4 - 1 else 3;
    return n.nnz[p * 16 + last * 4 + bx];
}

fn ncOf(d: *const Dec, m: *const Mb, p: usize, bx: u32, by: u32, chroma: bool) i32 {
    const a = nnzLeft(d, m, p, bx, by, chroma);
    const b = nnzTop(d, m, p, bx, by, chroma);
    if (a != null and b != null) return (@as(i32, a.?) + b.? + 1) >> 1;
    if (a) |v| return v;
    if (b) |v| return v;
    return 0;
}

/// coded_block_flag of a neighbouring block for CABAC's context (9.3.3.1.1.9):
/// `blk8` for the 8x8 blocks of 4:4:4.
fn cbfNeighbour(d: *const Dec, m: *const Mb, side_xy: ?u32, row: u32, col: u32, p: usize, blk8: bool) u1 {
    const xy = side_xy orelse return @intFromBool(m.isIntra());
    const n = d.info(xy);
    if (n.kind == .ipcm) return 1;
    if (n.flags & common.F_SKIP != 0) return 0;
    if (blk8 and n.flags & common.F_T8X8 == 0) return 0;
    return @intFromBool(n.nnz[p * 16 + row * 4 + col] != 0);
}

fn cbfCtx4(d: *const Dec, m: *const Mb, p: usize, bx: u32, by: u32, chroma: bool, blk8: bool) usize {
    var a: u1 = undefined;
    var b: u1 = undefined;
    if (bx > 0) {
        a = @intFromBool(m.nnz[p * 16 + by * 4 + bx - 1] != 0);
    } else {
        const side = if (chroma) d.nb.left_c[by] else d.nb.left[by];
        a = cbfNeighbour(d, m, if (side) |s| s.xy else null, if (side) |s| s.row else 0, if (chroma) 1 else 3, p, blk8);
    }
    if (by > 0) {
        b = @intFromBool(m.nnz[p * 16 + (by - 1) * 4 + bx] != 0);
    } else {
        const last: u32 = if (chroma) d.mbh_c / 4 - 1 else 3;
        b = cbfNeighbour(d, m, d.nb.b, last, bx, p, blk8);
    }
    return @as(usize, a) + 2 * @as(usize, b);
}

fn cbfDcCtx(d: *const Dec, m: *const Mb, bit: u3) usize {
    var inc: usize = 0;
    for ([2]?u32{ d.nb.a, d.nb.b }, [2]usize{ 1, 2 }) |nxy, w| {
        const cond: bool = if (nxy) |xy| blk: {
            const n = d.info(xy);
            if (n.kind == .ipcm) break :blk true;
            break :blk n.cbf_dc >> bit & 1 != 0;
        } else m.isIntra();
        if (cond) inc += w;
    }
    return inc;
}

/// The intra 4x4 / 8x8 mode of the neighbouring block for the prediction
/// of the mode (8.3.1.1): null when the DC mode is predicted.
fn modeOf(d: *const Dec, xy: ?u32, row: u32, col: u32) ?u8 {
    const n = d.info(xy orelse return null);
    if (n.flags & common.F_INTRA == 0) {
        if (d.pps.constrained_intra_pred) return null;
        return 2;
    }
    // SI predicts as Intra_4x4 does (table 7-12).
    if (!kindIsNxN(n.kind) and n.kind != .si) return 2;
    return n.i_modes[row * 4 + col];
}

fn predMode(d: *const Dec, m: *const Mb, bx: u32, by: u32) u8 {
    const a: ?u8 = if (bx > 0) m.i_modes[by * 4 + bx - 1] else if (d.nb.left[by]) |s| modeOf(d, s.xy, s.row, 3) else null;
    const b: ?u8 = if (by > 0) m.i_modes[(by - 1) * 4 + bx] else modeOf(d, d.nb.b, 3, bx);
    if (a == null or b == null) return 2;
    return @min(a.?, b.?);
}

// --- CAVLC syntax ------------------------------------------------------------------

fn readMbTypeCavlc(d: *Dec, class: MbClass) Error!MbType {
    const b = &d.bits;
    const v = try b.ue();
    return switch (class) {
        .i => if (v > 25) error.Corrupt else .{ .class = .i, .v = v },
        .si => if (v == 0) .{ .class = .si, .v = 0 } else if (v > 26) error.Corrupt else .{ .class = .i, .v = v - 1 },
        .p => if (v < 5) .{ .class = .p, .v = v } else if (v > 30) error.Corrupt else .{ .class = .i, .v = v - 5 },
        .b => if (v < 23) .{ .class = .b, .v = v } else if (v > 48) error.Corrupt else .{ .class = .i, .v = v - 23 },
    };
}

// --- CABAC syntax ----------------------------------------------------------------

fn isI16OrPcm(d: *const Dec, xy: ?u32) bool {
    const n = d.info(xy orelse return false);
    return n.kind == .i16x16 or n.kind == .ipcm;
}

fn cabacIntraType(d: *Dec, base: usize, intra_slice: bool) u32 {
    var st = base;
    const is: usize = @intFromBool(intra_slice);
    if (intra_slice) {
        var inc: usize = 0;
        if (isI16OrPcm(d, d.nb.a)) inc += 1;
        if (isI16OrPcm(d, d.nb.b)) inc += 1;
        if (bin(d, st + inc) == 0) return 0;
        st += 2;
    } else {
        if (bin(d, st) == 0) return 0;
    }
    if (d.eng.terminate() == 1) return 25;
    var t: u32 = 1;
    t += 12 * @as(u32, bin(d, st + 1));
    if (bin(d, st + 2) == 1) t += 4 + 4 * @as(u32, bin(d, st + 2 + is));
    t += 2 * @as(u32, bin(d, st + 3 + is));
    t += bin(d, st + 3 + 2 * is);
    return t;
}

fn readMbTypeCabac(d: *Dec, class: MbClass) Error!MbType {
    switch (class) {
        .i => return .{ .class = .i, .v = cabacIntraType(d, 3, true) },
        .si => {
            var inc: usize = 0;
            for ([2]?u32{ d.nb.a, d.nb.b }) |nxy| {
                if (nxy) |xy| {
                    if (d.info(xy).kind != .si) inc += 1;
                }
            }
            if (bin(d, inc) == 0) return .{ .class = .si, .v = 0 };
            return .{ .class = .i, .v = cabacIntraType(d, 3, true) };
        },
        .p => {
            if (bin(d, 14) == 0) {
                if (bin(d, 15) == 0) return .{ .class = .p, .v = 3 * @as(u32, bin(d, 16)) };
                return .{ .class = .p, .v = 2 - @as(u32, bin(d, 17)) };
            }
            return .{ .class = .i, .v = cabacIntraType(d, 17, false) };
        },
        .b => {
            var inc: usize = 0;
            for ([2]?u32{ d.nb.a, d.nb.b }) |nxy| {
                if (nxy) |xy| {
                    if (d.info(xy).flags & common.F_DIRECT == 0) inc += 1;
                }
            }
            if (bin(d, 27 + inc) == 0) return .{ .class = .b, .v = 0 };
            if (bin(d, 27 + 3) == 0) return .{ .class = .b, .v = 1 + @as(u32, bin(d, 27 + 5)) };
            var bits: u32 = @as(u32, bin(d, 27 + 4)) << 3;
            bits |= @as(u32, bin(d, 27 + 5)) << 2;
            bits |= @as(u32, bin(d, 27 + 5)) << 1;
            bits |= bin(d, 27 + 5);
            if (bits < 8) return .{ .class = .b, .v = bits + 3 };
            if (bits == 13) return .{ .class = .i, .v = cabacIntraType(d, 32, false) };
            if (bits == 14) return .{ .class = .b, .v = 11 };
            if (bits == 15) return .{ .class = .b, .v = 22 };
            bits = (bits << 1) | bin(d, 27 + 5);
            return .{ .class = .b, .v = bits - 4 };
        },
    }
}

/// mb_skip_flag (CABAC), with the neighbours as they are now.
pub fn readSkipCabac(d: *Dec, b_slice: bool) bool {
    var inc: usize = 0;
    for ([2]?u32{ d.nb.a, d.nb.b }) |nxy| {
        if (nxy) |xy| {
            if (d.info(xy).flags & common.F_SKIP == 0) inc += 1;
        }
    }
    return bin(d, (if (b_slice) @as(usize, 24) else 11) + inc) == 1;
}

/// mb_field_decoding_flag (CABAC).
pub fn readFieldCabac(d: *Dec) bool {
    var inc: usize = 0;
    if (d.pairField(true) orelse false) inc += 1;
    if (d.pairField(false) orelse false) inc += 1;
    return bin(d, 70 + inc) == 1;
}

pub fn readEndOfSlice(d: *Dec) bool {
    return d.eng.terminate() == 1;
}

fn readSubCabac(d: *Dec, b_slice: bool) u32 {
    if (!b_slice) {
        if (bin(d, 21) == 1) return 0;
        if (bin(d, 22) == 0) return 1;
        if (bin(d, 23) == 1) return 2;
        return 3;
    }
    if (bin(d, 36) == 0) return 0;
    if (bin(d, 37) == 0) return 1 + @as(u32, bin(d, 39));
    var t: u32 = 3;
    if (bin(d, 38) == 1) {
        if (bin(d, 39) == 1) return 11 + @as(u32, bin(d, 39));
        t += 4;
    }
    t += 2 * @as(u32, bin(d, 39));
    t += bin(d, 39);
    return t;
}

/// The 8x8 block of a 4x4 cell (raster).
inline fn b8Of(cell: u32) u32 {
    return (cell >> 3) * 2 + ((cell & 3) >> 1);
}

fn refCond(d: *const Dec, m: *const Mb, list: usize, x: u32, y: u32, left: bool) bool {
    if ((left and x > 0) or (!left and y > 0)) {
        const cell = if (left) y * 4 + x - 1 else (y - 1) * 4 + x;
        const b8 = b8Of(cell);
        if (m.direct >> @intCast(b8) & 1 != 0) return false;
        return m.ref[list][b8] > 0;
    }
    var xy: u32 = undefined;
    var b8: u32 = undefined;
    if (left) {
        const s = d.nb.left[y] orelse return false;
        xy = s.xy;
        b8 = (@as(u32, s.row) >> 1) * 2 + 1;
    } else {
        xy = d.nb.b orelse return false;
        b8 = 2 + (x >> 1);
    }
    const n = d.info(xy);
    if (n.flags & (common.F_SKIP | common.F_INTRA) != 0) return false;
    if (n.direct8 >> @intCast(b8) & 1 != 0) return false;
    const r = n.ref[list][b8];
    if (d.mbaff and !d.field and n.flags & common.F_FIELD != 0) return r > 1;
    return r > 0;
}

fn readRefCabac(d: *Dec, m: *const Mb, list: usize, x: u32, y: u32) u32 {
    var ctx: usize = @intFromBool(refCond(d, m, list, x, y, true));
    if (refCond(d, m, list, x, y, false)) ctx += 2;
    var r: u32 = 0;
    while (bin(d, 54 + ctx) == 1) {
        r += 1;
        ctx = (ctx >> 2) + 4;
        if (r >= 32) break;
    }
    return r;
}

fn absMvdOf(d: *const Dec, m: *const Mb, list: usize, x: u32, y: u32, comp: usize, left: bool) u32 {
    if ((left and x > 0) or (!left and y > 0)) {
        const cell = if (left) y * 4 + x - 1 else (y - 1) * 4 + x;
        return @min(@abs(m.mvd[list][cell][comp]), 127);
    }
    var xy: u32 = undefined;
    var cell: u32 = undefined;
    if (left) {
        const s = d.nb.left[y] orelse return 0;
        xy = s.xy;
        cell = @as(u32, s.row) * 4 + 3;
    } else {
        xy = d.nb.b orelse return 0;
        cell = 12 + x;
    }
    const n = d.info(xy);
    if (n.flags & (common.F_SKIP | common.F_INTRA) != 0) return 0;
    var v: u32 = n.mvd[list][cell][comp];
    if (comp == 1 and d.mbaff) {
        const nf = n.flags & common.F_FIELD != 0;
        if (!d.field and nf) v *= 2 else if (d.field and !nf) v /= 2;
    }
    return v;
}

fn readMvdCabac(d: *Dec, m: *const Mb, list: usize, x: u32, y: u32, comp: usize) i32 {
    const sum = absMvdOf(d, m, list, x, y, comp, true) + absMvdOf(d, m, list, x, y, comp, false);
    var base: usize = if (comp == 0) 40 else 47;
    const inc: usize = if (sum < 3) 0 else if (sum <= 32) 1 else 2;
    if (bin(d, base + inc) == 0) return 0;
    var v: u32 = 1;
    base += 3;
    while (v < 9 and bin(d, base) == 1) {
        if (v < 4) base += 1;
        v += 1;
    }
    if (v >= 9) v += bypassBits(d, 3);
    const neg = d.eng.bypass() == 1;
    const s: i32 = @intCast(@min(v, 1 << 20));
    return if (neg) -s else s;
}

// --- the layer ---------------------------------------------------------------------

/// Reads the rest of a macroblock that is not skipped (7.3.5): its type
/// first. The neighbours must be found already.
pub fn parse(d: *Dec, m: *Mb) Error!void {
    m.reset();
    const h = d.hdr;
    const use_cabac = d.useCabac();
    const class: MbClass = switch (h.kind) {
        .i => .i,
        .si => .si,
        .p, .sp => .p,
        .b => .b,
    };
    const t = if (use_cabac) try readMbTypeCabac(d, class) else try readMbTypeCavlc(d, class);
    switch (t.class) {
        .i => try intraType(d, m, t.v),
        .si => {
            m.kind = .si;
        },
        .p => {
            m.kind = .inter;
            switch (t.v) {
                0 => m.shape = .p16x16,
                1 => m.shape = .p16x8,
                2 => m.shape = .p8x16,
                else => m.shape = .p8x8,
            }
            m.pred = @splat(L0);
            if (t.v == 4) m.ref = .{ @splat(0), @splat(-1) };
        },
        .b => {
            m.kind = .inter;
            switch (t.v) {
                0 => {
                    m.direct = 0xF;
                    m.direct16 = true;
                    m.shape = .p8x8;
                },
                1, 2, 3 => {
                    m.shape = .p16x16;
                    m.pred[0] = @intCast(t.v);
                },
                22 => m.shape = .p8x8,
                else => {
                    m.shape = if (t.v & 1 == 0) .p16x8 else .p8x16;
                    const pair = b_pairs[(t.v - 4) / 2];
                    m.pred[0] = pair[0];
                    m.pred[1] = pair[1];
                },
            }
        },
    }
    if (m.kind == .ipcm) return readPcm(d, m);

    var no_sub_below_8x8 = true;
    const b_direct16 = m.direct16;
    if (m.kind == .inter and m.shape == .p8x8 and !b_direct16) {
        try subMbPred(d, m, t.v == 4, &no_sub_below_8x8);
    } else {
        if (m.kind == .i4x4 and d.pps.transform_8x8) {
            const f = if (use_cabac) blk: {
                var inc: usize = 0;
                for ([2]?u32{ d.nb.a, d.nb.b }) |nxy| {
                    if (nxy) |xy| {
                        if (d.info(xy).flags & common.F_T8X8 != 0) inc += 1;
                    }
                }
                break :blk bin(d, 399 + inc) == 1;
            } else d.bits.flag();
            if (f) {
                m.kind = .i8x8;
                m.t8x8 = true;
            }
        }
        if (!b_direct16) try mbPred(d, m);
    }
    if (m.kind != .i16x16) {
        try readCbp(d, m);
        if (m.cbp & 15 != 0 and d.pps.transform_8x8 and m.kind == .inter and no_sub_below_8x8 and (!b_direct16 or d.sps.direct_8x8_inference)) {
            m.t8x8 = if (use_cabac) blk: {
                var inc: usize = 0;
                for ([2]?u32{ d.nb.a, d.nb.b }) |nxy| {
                    if (nxy) |xy| {
                        if (d.info(xy).flags & common.F_T8X8 != 0) inc += 1;
                    }
                }
                break :blk bin(d, 399 + inc) == 1;
            } else d.bits.flag();
        }
    }
    m.qp = d.qp;
    m.lossless = d.sps.transform_bypass and m.qp + 6 * (@as(i32, d.sps.bit_depth_luma) - 8) == 0;
    if (m.cbp != 0 or m.kind == .i16x16) {
        try readQpDelta(d, m);
        try residual(d, m);
    } else {
        d.last_dqp = false;
    }
}

fn intraType(d: *Dec, m: *Mb, v: u32) Error!void {
    if (v == 0) {
        m.kind = .i4x4;
    } else if (v == 25) {
        m.kind = .ipcm;
    } else {
        m.kind = .i16x16;
        const k = v - 1;
        m.i16_mode = @intCast(k % 4);
        m.cbp = @intCast(((k / 4) % 3) << 4 | (if (k >= 12) @as(u32, 15) else 0));
    }
    _ = d;
}

fn readPcm(d: *Dec, m: *Mb) Error!void {
    var b: Bits = undefined;
    if (d.useCabac()) {
        const at = d.eng.bytePosition();
        if (at > d.bits.data.len) return error.Corrupt;
        b = Bits.init(d.bits.data);
        b.pos = at * 8;
    } else {
        // pcm samples are category 3: partition B when partitioned.
        const src = if (d.partitioned) &d.bits_b else &d.bits;
        src.alignByte();
        b = src.*;
    }
    const dy: u6 = @intCast(d.sps.bit_depth_luma);
    const dc: u6 = @intCast(d.sps.bit_depth_chroma);
    for (0..256) |i| m.pcm[i] = @intCast(b.u(dy));
    if (d.mbh_c != 0) {
        const n = (if (d.cat == 3) @as(usize, 16) else 8) * d.mbh_c;
        for (0..2 * n) |i| m.pcm[256 + i] = @intCast(b.u(dc));
    }
    if (b.overrun()) return error.Corrupt;
    if (d.useCabac()) {
        if (!d.eng.init(d.bits.data, b.pos >> 3)) return error.Corrupt;
    } else if (d.partitioned) d.bits_b = b else d.bits = b;
    m.qp = d.qp;
    m.cbp = 0x2F;
    m.cbf_dc = 7;
    m.nnz = @splat(16);
    d.last_dqp = false;
}

fn mbPred(d: *Dec, m: *Mb) Error!void {
    const use_cabac = d.useCabac();
    if (m.isIntra()) {
        if (m.kind == .i4x4 or m.kind == .si) {
            for (0..16) |k| {
                const r = common.blk_raster[k];
                const bx: u32 = r & 3;
                const by: u32 = r >> 2;
                const pred = predMode(d, m, bx, by);
                m.i_modes[r] = try readMode(d, pred, use_cabac);
            }
        } else if (m.kind == .i8x8) {
            for (0..4) |b8| {
                const bx: u32 = @intCast((b8 & 1) * 2);
                const by: u32 = @intCast((b8 >> 1) * 2);
                const pred = predMode(d, m, bx, by);
                const mode = try readMode(d, pred, use_cabac);
                for ([4]u32{ 0, 1, 4, 5 }) |o| m.i_modes[by * 4 + bx + o] = mode;
            }
        }
        if (d.cat == 1 or d.cat == 2) {
            if (use_cabac) {
                var inc: usize = 0;
                for ([2]?u32{ d.nb.a, d.nb.b }) |nxy| {
                    if (nxy) |xy| {
                        if (d.info(xy).chroma_mode != 0) inc += 1;
                    }
                }
                var v: u8 = 0;
                if (bin(d, 64 + inc) == 1) {
                    v = 1;
                    if (bin(d, 67) == 1) {
                        v = 2;
                        if (bin(d, 67) == 1) v = 3;
                    }
                }
                m.chroma_mode = v;
            } else m.chroma_mode = @intCast(try d.bits.ueMax(3));
        }
        return;
    }
    // Inter, not direct.
    const parts: u32 = if (m.shape == .p16x16) 1 else 2;
    for (0..2) |list| {
        const n = numRefIdx(d, list);
        for (0..parts) |p| {
            if (m.pred[p] >> @intCast(list) & 1 == 0) continue;
            var r: u32 = 0;
            if (n > 1 or d.field != d.field_pic) {
                const x, const y = partOrigin(m.shape, @intCast(p));
                r = if (use_cabac) readRefCabac(d, m, list, x, y) else try d.bits.te(n - 1);
                if (r >= n) return error.Corrupt;
            }
            setRef(m, list, m.shape, @intCast(p), @intCast(r));
        }
    }
    for (0..2) |list| {
        for (0..parts) |p| {
            if (m.pred[p] >> @intCast(list) & 1 == 0) continue;
            const x, const y = partOrigin(m.shape, @intCast(p));
            const mx = if (use_cabac) readMvdCabac(d, m, list, x, y, 0) else try d.bits.se();
            const my = if (use_cabac) readMvdCabac(d, m, list, x, y, 1) else try d.bits.se();
            fillMvd(m, list, x, y, partW(m.shape), partH(m.shape), mx, my);
        }
    }
}

/// num_ref_idx_lX_active, doubled for a field macroblock of a frame.
fn numRefIdx(d: *const Dec, list: usize) u32 {
    const n: u32 = d.hdr.num_ref_idx[list];
    return if (d.field and !d.field_pic) 2 * n else n;
}

fn readMode(d: *Dec, pred: u8, use_cabac: bool) Error!u8 {
    var flag: bool = undefined;
    var rem: u8 = undefined;
    if (use_cabac) {
        flag = bin(d, 68) == 1;
        if (!flag) {
            rem = bin(d, 69);
            rem |= @as(u8, bin(d, 69)) << 1;
            rem |= @as(u8, bin(d, 69)) << 2;
        }
    } else {
        flag = d.bits.flag();
        if (!flag) rem = @intCast(d.bits.u(3));
    }
    if (flag) return pred;
    return if (rem < pred) rem else rem + 1;
}

pub fn partOrigin(shape: Shape, p: u32) struct { u32, u32 } {
    return switch (shape) {
        .p16x16 => .{ 0, 0 },
        .p16x8 => .{ 0, 2 * p },
        .p8x16 => .{ 2 * p, 0 },
        .p8x8 => .{ (p & 1) * 2, (p >> 1) * 2 },
    };
}
pub fn partW(shape: Shape) u32 {
    return if (shape == .p16x16 or shape == .p16x8) 4 else 2;
}
pub fn partH(shape: Shape) u32 {
    return if (shape == .p16x16 or shape == .p8x16) 4 else 2;
}

fn setRef(m: *Mb, list: usize, shape: Shape, p: u32, r: i8) void {
    switch (shape) {
        .p16x16 => m.ref[list] = @splat(r),
        .p16x8 => {
            m.ref[list][2 * p] = r;
            m.ref[list][2 * p + 1] = r;
        },
        .p8x16 => {
            m.ref[list][p] = r;
            m.ref[list][p + 2] = r;
        },
        .p8x8 => m.ref[list][p] = r,
    }
}

fn fillMvd(m: *Mb, list: usize, x: u32, y: u32, w: u32, hh: u32, mx: i32, my: i32) void {
    for (y..y + hh) |yy| {
        for (x..x + w) |xx| m.mvd[list][yy * 4 + xx] = .{ mx, my };
    }
}

fn subMbPred(d: *Dec, m: *Mb, ref0: bool, no_sub_below_8x8: *bool) Error!void {
    const use_cabac = d.useCabac();
    const b_slice = d.hdr.kind == .b;
    for (0..4) |i| {
        const v = if (use_cabac) readSubCabac(d, b_slice) else try d.bits.ue();
        if (b_slice) {
            if (v > 12) return error.Corrupt;
            if (v == 0) {
                m.direct |= @as(u8, 1) << @intCast(i);
                if (!d.sps.direct_8x8_inference) no_sub_below_8x8.* = false;
                m.sub[i] = .s8x8;
                m.pred[i] = 0;
            } else {
                m.sub[i] = b_sub[v].shape;
                m.pred[i] = b_sub[v].pred;
                if (m.sub[i] != .s8x8) no_sub_below_8x8.* = false;
            }
        } else {
            if (v > 3) return error.Corrupt;
            m.sub[i] = @enumFromInt(v);
            m.pred[i] = L0;
            if (v != 0) no_sub_below_8x8.* = false;
        }
    }
    for (0..2) |list| {
        const n = numRefIdx(d, list);
        for (0..4) |i| {
            if (m.direct >> @intCast(i) & 1 != 0) continue;
            if (m.pred[i] >> @intCast(list) & 1 == 0) continue;
            var r: u32 = 0;
            if ((n > 1 or d.field != d.field_pic) and !ref0) {
                r = if (use_cabac) readRefCabac(d, m, list, @intCast((i & 1) * 2), @intCast((i >> 1) * 2)) else try d.bits.te(n - 1);
                if (r >= n) return error.Corrupt;
            }
            m.ref[list][i] = @intCast(r);
        }
    }
    for (0..2) |list| {
        for (0..4) |i| {
            if (m.direct >> @intCast(i) & 1 != 0) continue;
            if (m.pred[i] >> @intCast(list) & 1 == 0) continue;
            const x0: u32 = @intCast((i & 1) * 2);
            const y0: u32 = @intCast((i >> 1) * 2);
            const w: u32 = if (m.sub[i] == .s8x8 or m.sub[i] == .s8x4) 2 else 1;
            const hh: u32 = if (m.sub[i] == .s8x8 or m.sub[i] == .s4x8) 2 else 1;
            var y = y0;
            while (y < y0 + 2) : (y += hh) {
                var x = x0;
                while (x < x0 + 2) : (x += w) {
                    const mx = if (use_cabac) readMvdCabac(d, m, list, x, y, 0) else try d.bits.se();
                    const my = if (use_cabac) readMvdCabac(d, m, list, x, y, 1) else try d.bits.se();
                    fillMvd(m, list, x, y, w, hh, mx, my);
                }
            }
        }
    }
}

fn readCbp(d: *Dec, m: *Mb) Error!void {
    if (!d.useCabac()) {
        const intra = m.isIntra();
        if (d.cat == 1 or d.cat == 2) {
            const v = try d.bits.ueMax(47);
            m.cbp = if (intra) cbp_intra[v] else cbp_inter[v];
        } else {
            const v = try d.bits.ueMax(15);
            m.cbp = if (intra) cbp_intra_gray[v] else cbp_inter_gray[v];
        }
        return;
    }
    // Luma: a bin per 8x8 block, its context from the blocks left and above.
    var cbp: u8 = 0;
    for (0..4) |b8| {
        const x8 = b8 & 1;
        const y8 = b8 >> 1;
        var cond_a: u1 = 0;
        var cond_b: u1 = 0;
        if (x8 == 1) {
            cond_a = @intFromBool(cbp >> @intCast(b8 - 1) & 1 == 0);
        } else if (d.nb.left[y8 * 2]) |s| {
            const n = d.info(s.xy);
            const nb8: u3 = @intCast((s.row >> 1) * 2 + 1);
            cond_a = @intFromBool(n.cbp >> nb8 & 1 == 0);
        }
        if (y8 == 1) {
            cond_b = @intFromBool(cbp >> @intCast(b8 - 2) & 1 == 0);
        } else if (d.nb.b) |xy| {
            const n = d.info(xy);
            const nb8: u3 = @intCast(2 + x8);
            cond_b = @intFromBool(n.cbp >> nb8 & 1 == 0);
        }
        if (bin(d, 73 + @as(usize, cond_a) + 2 * @as(usize, cond_b)) == 1) cbp |= @as(u8, 1) << @intCast(b8);
    }
    if (d.cat == 1 or d.cat == 2) {
        var ca: u2 = 0;
        var cb: u2 = 0;
        if (d.nb.a) |xy| ca = @intCast(d.info(xy).cbp >> 4 & 3);
        if (d.nb.b) |xy| cb = @intCast(d.info(xy).cbp >> 4 & 3);
        const inc0: usize = @as(usize, @intFromBool(ca != 0)) + 2 * @as(usize, @intFromBool(cb != 0));
        if (bin(d, 77 + inc0) == 1) {
            const inc1: usize = 4 + @as(usize, @intFromBool(ca == 2)) + 2 * @as(usize, @intFromBool(cb == 2));
            cbp |= @as(u8, 1 + @as(u8, bin(d, 77 + inc1))) << 4;
        }
    }
    m.cbp = cbp;
}

fn readQpDelta(d: *Dec, m: *Mb) Error!void {
    const bd: i32 = 6 * (@as(i32, d.sps.bit_depth_luma) - 8);
    var delta: i32 = 0;
    if (d.useCabac()) {
        if (bin(d, 60 + @as(usize, @intFromBool(d.last_dqp))) == 1) {
            var v: i32 = 1;
            var ctx: usize = 2;
            while (bin(d, 60 + ctx) == 1) {
                ctx = 3;
                v += 1;
                if (v > 2 * (52 + bd)) return error.Corrupt;
            }
            delta = if (v & 1 != 0) (v + 1) >> 1 else -((v + 1) >> 1);
        }
    } else {
        delta = try d.bits.se();
    }
    if (delta < -(26 + @divTrunc(bd, 2)) or delta > 25 + @divTrunc(bd, 2)) return error.Corrupt;
    m.qp_delta = delta;
    d.last_dqp = delta != 0;
    m.qp = @mod(d.qp + delta + 52 + 2 * bd, 52 + bd) - bd;
}

// --- residual ------------------------------------------------------------------

/// What a block is, for CABAC's contexts (ctxBlockCat, table 9-42), by
/// plane: luma DC, AC, 4x4, 8x8 (Cb and Cr of 4:4:4 alike); chroma DC
/// and AC of 4:2:0 / 4:2:2.
const Cat = struct {
    const dc16 = [3]u8{ 0, 6, 10 };
    const ac = [3]u8{ 1, 7, 11 };
    const blk4 = [3]u8{ 2, 8, 12 };
    const blk8 = [3]u8{ 5, 9, 13 };
    const chroma_dc: u8 = 3;
    const chroma_ac: u8 = 4;
};

/// A block's levels in scan order, `levels[0 .. max]`, CABAC (7.3.5.3.3);
/// with the context of its coded_block_flag already found (or null when
/// it has none). The count of non-zero levels.
fn cabacBlock(d: *Dec, levels: []i32, max: u32, cat: u8, cbf_ctx: ?usize) u32 {
    if (cbf_ctx) |c| {
        if (bin(d, cbf_base[cat] + c) == 0) return 0;
    }
    const fld: usize = @intFromBool(d.field);
    const sig = sig_base[fld][cat];
    const lst = last_base[fld][cat];
    var index: [64]u8 = undefined;
    var count: u32 = 0;
    var i: u32 = 0;
    const num_c8x8: u32 = if (d.cat == 2) 2 else 1;
    var ended = false;
    while (i + 1 < max) : (i += 1) {
        var inc_s: usize = i;
        var inc_l: usize = i;
        if (max == 64) {
            inc_s = sig8[fld][i];
            inc_l = last8[i];
        } else if (cat == Cat.chroma_dc) {
            inc_s = @min(i / num_c8x8, 2);
            inc_l = inc_s;
        }
        if (bin(d, sig + inc_s) == 1) {
            index[count] = @intCast(i);
            count += 1;
            if (bin(d, lst + inc_l) == 1) {
                ended = true;
                break;
            }
        }
    }
    if (!ended) {
        index[count] = @intCast(max - 1);
        count += 1;
    }
    const abs_ctx = abs_base[cat];
    const gt1_max: u32 = if (cat == Cat.chroma_dc) 3 else 4;
    var eq1: u32 = 0;
    var gt1: u32 = 0;
    var k = count;
    while (k > 0) {
        k -= 1;
        const inc0: usize = if (gt1 != 0) 0 else @min(4, 1 + eq1);
        var v: u32 = 0;
        if (bin(d, abs_ctx + inc0) == 1) {
            v = 1;
            const inc1: usize = 5 + @min(gt1_max, gt1);
            while (v < 14 and bin(d, abs_ctx + inc1) == 1) v += 1;
            if (v >= 14) v += bypassBits(d, 0);
        }
        const abs = v + 1;
        if (abs == 1) eq1 += 1 else gt1 += 1;
        const s: i32 = @intCast(@min(abs, 1 << 24));
        levels[index[k]] = if (d.eng.bypass() == 1) -s else s;
    }
    return count;
}

fn resBits(d: *Dec, m: *const Mb) *Bits {
    if (!d.partitioned) return &d.bits;
    return if (m.isIntra()) &d.bits_b else &d.bits_c;
}

fn resPresent(d: *const Dec, m: *const Mb) bool {
    if (!d.partitioned) return true;
    return if (m.isIntra()) d.has_b else d.has_c;
}

/// QP' of each plane: luma, Cb, Cr, with QpBdOffset.
fn planeQps(d: *const Dec, qp_y: i32) [3]i32 {
    const bdy: i32 = 6 * (@as(i32, d.sps.bit_depth_luma) - 8);
    const bdc: i32 = 6 * (@as(i32, d.sps.bit_depth_chroma) - 8);
    if (d.cat == 0) return .{ qp_y + bdy, qp_y + bdy, qp_y + bdy };
    return .{
        qp_y + bdy,
        chromaQp(qp_y, d.pps.chroma_qp_offset[0], bdc) + bdc,
        chromaQp(qp_y, d.pps.chroma_qp_offset[1], bdc) + bdc,
    };
}

fn residual(d: *Dec, m: *Mb) Error!void {
    m.lossless = d.sps.transform_bypass and m.qp + 6 * (@as(i32, d.sps.bit_depth_luma) - 8) == 0;
    if (!resPresent(d, m)) return;
    const qps = planeQps(d, m.qp);
    try residualLuma(d, m, 0, qps[0]);
    if (d.cat == 3) {
        try residualLuma(d, m, 1, qps[1]);
        try residualLuma(d, m, 2, qps[2]);
    } else if (d.cat == 1 or d.cat == 2) {
        try residualChroma(d, m, qps);
    }
    if (resBits(d, m).overrun()) return error.Corrupt;
}

/// The scaling list of a plane: 4x4 index (table 7-2's order), and the
/// 8x8 one.
pub fn list4(d: *const Dec, m: *const Mb, p: usize) usize {
    const plane = if (d.sps.separate_colour_plane) d.hdr.colour_plane else p;
    return plane + (if (m.isIntra()) @as(usize, 0) else 3);
}
fn list8(d: *const Dec, m: *const Mb, p: usize) usize {
    const plane = if (d.sps.separate_colour_plane) d.hdr.colour_plane else p;
    return 2 * @as(usize, plane) + (if (m.isIntra()) @as(usize, 0) else 1);
}

fn scan4(d: *const Dec) *const [16]u8 {
    return if (d.field) &transform.field4 else &params.zigzag4;
}
fn scan8(d: *const Dec) *const [64]u8 {
    return if (d.field) &transform.field8 else &params.zigzag8;
}

fn residualLuma(d: *Dec, m: *Mb, p: usize, qp: i32) Error!void {
    const use_cabac = d.useCabac();
    const b = resBits(d, m);
    const sc = scan4(d);
    const qp6: usize = @intCast(@mod(qp, 6));
    const raw = m.lossless or m.switching(d.hdr.kind);
    var levels: [64]i32 = undefined;
    if (m.kind == .i16x16) {
        levels = @splat(0);
        var n: u32 = undefined;
        if (use_cabac) {
            n = cabacBlock(d, levels[0..16], 16, Cat.dc16[p], cbfDcCtx(d, m, @intCast(p)));
        } else {
            n = try cavlc.residualBlock(b, ncOf(d, m, p, 0, 0, false), levels[0..16], 0, 15, 16);
        }
        if (n != 0) {
            m.cbf_dc |= @as(u8, 1) << @intCast(p);
            var dc: [16]i32 = @splat(0);
            for (0..16) |i| dc[sc[i]] = levels[i];
            var out: [16]i32 = undefined;
            if (m.lossless) {
                out = dc;
            } else {
                transform.lumaDc(&dc, &out, d.scales.s4[list4(d, m, p)][qp6][0], qp);
            }
            for (0..16) |r| {
                if (out[r] != 0) {
                    initBlock(m, p, r);
                    m.coef[p][r][0] = out[r];
                }
            }
        }
    }
    for (0..4) |b8| {
        const has = m.cbp >> @intCast(b8) & 1 != 0;
        if (m.t8x8) {
            if (!has) continue;
            levels = @splat(0);
            var total: u32 = 0;
            if (use_cabac) {
                const bx: u32 = @intCast((b8 & 1) * 2);
                const by: u32 = @intCast((b8 >> 1) * 2);
                const ctx: ?usize = if (d.cat == 3) cbfCtx4(d, m, p, bx, by, false, true) else null;
                total = cabacBlock(d, levels[0..64], 64, Cat.blk8[p], ctx);
                for ([4]u32{ 0, 1, 4, 5 }) |o| m.nnz[p * 16 + by * 4 + bx + o] = @intCast(total);
            } else {
                for (0..4) |k| {
                    const r: u32 = common.blk_raster[b8 * 4 + k];
                    var part: [16]i32 = @splat(0);
                    const n = try cavlc.residualBlock(b, ncOf(d, m, p, r & 3, r >> 2, false), &part, 0, 15, 16);
                    m.nnz[p * 16 + r] = @intCast(n);
                    total += n;
                    for (0..16) |i| levels[4 * i + k] = part[i];
                }
            }
            if (total == 0) continue;
            m.nz8 |= @as(u16, 1) << @intCast(p * 4 + b8);
            const c = &m.coef8[p][b8];
            c.* = @splat(0);
            const s8 = scan8(d);
            for (0..64) |i| c[s8[i]] = levels[i];
            if (!m.lossless) transform.scale8(c, &d.scales.s8[list8(d, m, p)][@intCast(@mod(qp, 6))], qp);
            m.mask8[p] |= @as(u8, 1) << @intCast(b8);
            continue;
        }
        for (0..4) |k| {
            const r: u32 = common.blk_raster[b8 * 4 + k];
            if (!has) continue;
            const bx = r & 3;
            const by = r >> 2;
            levels = @splat(0);
            const ac = m.kind == .i16x16;
            var n: u32 = undefined;
            if (use_cabac) {
                const cat = if (ac) Cat.ac[p] else Cat.blk4[p];
                n = cabacBlock(d, levels[0..16], if (ac) 15 else 16, cat, cbfCtx4(d, m, p, bx, by, false, false));
            } else {
                n = try cavlc.residualBlock(b, ncOf(d, m, p, bx, by, false), levels[0..16], 0, if (ac) 14 else 15, if (ac) 15 else 16);
            }
            m.nnz[p * 16 + r] = @intCast(n);
            if (n == 0) continue;
            initBlock(m, p, r);
            const c = &m.coef[p][r];
            if (ac) {
                for (0..15) |i| c[sc[i + 1]] = levels[i];
            } else {
                for (0..16) |i| c[sc[i]] = levels[i];
            }
            if (!raw) transform.scale4(c, &d.scales.s4[list4(d, m, p)][qp6], qp, ac);
        }
    }
}

/// A block about to get coefficients, cleared the first time.
fn initBlock(m: *Mb, p: usize, r: usize) void {
    const bit = @as(u16, 1) << @intCast(r);
    if (m.mask4[p] & bit == 0) {
        m.coef[p][r] = @splat(0);
        m.mask4[p] |= bit;
    }
}

fn residualChroma(d: *Dec, m: *Mb, qps: [3]i32) Error!void {
    const use_cabac = d.useCabac();
    const b = resBits(d, m);
    const n8: u32 = if (d.cat == 2) 2 else 1;
    const blocks = 4 * n8;
    const sc = scan4(d);
    const raw = m.lossless or m.switching(d.hdr.kind);
    if (m.cbp >> 4 != 0) {
        for (0..2) |c| {
            const p = c + 1;
            var levels: [16]i32 = @splat(0);
            var n: u32 = undefined;
            if (use_cabac) {
                n = cabacBlock(d, levels[0..blocks], blocks, Cat.chroma_dc, cbfDcCtx(d, m, @intCast(p)));
            } else {
                n = try cavlc.residualBlock(b, if (d.cat == 2) cavlc.nc_chroma422_dc else cavlc.nc_chroma_dc, levels[0..blocks], 0, blocks - 1, blocks);
            }
            if (n == 0) continue;
            m.cbf_dc |= @as(u8, 1) << @intCast(p);
            const qp = qps[p];
            const list = list4(d, m, p);
            var dc: [8]i32 = @splat(0);
            if (d.cat == 1) {
                for (0..4) |i| dc[i] = levels[i];
                if (!raw) transform.chromaDc420(dc[0..4], d.scales.s4[list][@intCast(@mod(qp, 6))][0], qp);
            } else {
                for (0..8) |i| dc[chroma422_dc_scan[i]] = levels[i];
                if (!m.lossless) {
                    var ls: [6]u32 = undefined;
                    for (0..6) |q| ls[q] = d.scales.s4[list][q][0];
                    transform.chromaDc422(&dc, &ls, qp);
                }
            }
            for (0..blocks) |k| {
                if (dc[k] == 0) continue;
                const r: u32 = @intCast((k >> 1) * 4 + (k & 1));
                initBlock(m, p, r);
                m.coef[p][r][0] = dc[k];
            }
        }
    }
    if (m.cbp >> 4 == 2) {
        for (0..2) |c| {
            const p = c + 1;
            const qp = qps[p];
            const list = list4(d, m, p);
            for (0..blocks) |k| {
                const bx: u32 = @intCast(k & 1);
                const by: u32 = @intCast(k >> 1);
                const r = by * 4 + bx;
                var levels: [16]i32 = @splat(0);
                var n: u32 = undefined;
                if (use_cabac) {
                    n = cabacBlock(d, levels[0..15], 15, Cat.chroma_ac, cbfCtx4(d, m, p, bx, by, true, false));
                } else {
                    n = try cavlc.residualBlock(b, ncOf(d, m, p, bx, by, true), levels[0..15], 0, 14, 15);
                }
                m.nnz[p * 16 + r] = @intCast(n);
                if (n == 0) continue;
                initBlock(m, p, r);
                const cf = &m.coef[p][r];
                for (0..15) |i| cf[sc[i + 1]] = levels[i];
                if (!raw) transform.scale4(cf, &d.scales.s4[list][@intCast(@mod(qp, 6))], qp, true);
            }
        }
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "chroma QP follows table 8-15; the type tables hold together" {
    try testing.expectEqual(@as(i32, 29), chromaQp(30, 0, 0));
    try testing.expectEqual(@as(i32, 39), chromaQp(51, 0, 0));
    try testing.expectEqual(@as(i32, 39), chromaQp(45, 12, 0));
    try testing.expectEqual(@as(i32, -12), chromaQp(-20, 0, 12));
    try testing.expectEqual(@as(u8, 47), cbp_intra[0]);
    try testing.expectEqual(@as(u8, 0), cbp_inter[0]);
    // B_L1_Bi_8x16 is mb_type 15: its first partition list 1, the second both.
    try testing.expectEqual(L1, b_pairs[(15 - 4) / 2][0]);
    try testing.expectEqual(L0 | L1, b_pairs[(15 - 4) / 2][1]);
    _ = &parse;
    _ = &readSkipCabac;
    _ = &readFieldCabac;
    _ = &readEndOfSlice;
}
