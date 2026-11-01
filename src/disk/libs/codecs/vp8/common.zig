// SPDX-License-Identifier: MIT
//! What the parts of the VP8 decoder share: memory and the other cores
//! from whoever runs it, a frame's planes, what is kept of each
//! macroblock, the frame header and the probabilities that carry from
//! frame to frame.

pub const Error = error{ Corrupt, Unsupported, NoMemory };

/// Memory, from whoever runs the decoder: `alloc` gives `len` bytes on
/// 16, cleared when `clear`; null when there is none.
pub const Env = struct {
    ctx: *anyopaque,
    alloc: *const fn (ctx: *anyopaque, len: usize, clear: bool) ?[*]u8,
    free: *const fn (ctx: *anyopaque, memory: [*]u8, len: usize) void,

    pub fn slice(env: Env, comptime T: type, n: usize) ?[]T {
        if (n == 0) return &.{};
        const bytes = env.alloc(env.ctx, n * @sizeOf(T), true) orelse return null;
        const p: [*]T = @ptrCast(@alignCast(bytes));
        return p[0..n];
    }
    pub fn freeSlice(env: Env, comptime T: type, s: []T) void {
        if (s.len == 0) return;
        env.free(env.ctx, @ptrCast(s.ptr), s.len * @sizeOf(T));
    }
};

/// The other cores, from whoever runs the decoder: a worker task on each,
/// and a way to wait - as h264.vcodec's decoder has them.
pub const Cores = struct {
    ctx: *anyopaque,
    workers: u32,
    /// `job(arg)` run by worker `worker`, which runs nothing else then.
    run: *const fn (ctx: *anyopaque, worker: u32, job: *const fn (arg: *anyopaque) void, arg: *anyopaque) void,
    /// A wait: `arm(who)`, then a look whether what is waited for is
    /// there, and when it is not `sleep(who)`, which returns once `wake`
    /// was called after the `arm`, or sooner; then round again. The
    /// workers are 0 to `workers` - 1, the decoder's caller `workers`.
    arm: *const fn (ctx: *anyopaque, who: u32) void,
    sleep: *const fn (ctx: *anyopaque, who: u32) void,
    /// Something others may wait for changed.
    wake: *const fn (ctx: *anyopaque) void,

    /// Until the first `n` macroblock rows of `f` are final.
    pub fn rows(c: *const Cores, who: u32, f: *const Frame, n: u32) void {
        if (@atomicLoad(u32, &f.progress, .acquire) >= n) return;
        while (true) {
            c.arm(c.ctx, who);
            if (@atomicLoad(u32, &f.progress, .seq_cst) >= n) return;
            c.sleep(c.ctx, who);
        }
    }
};

/// The macroblock modes (RFC 6386 dixie's numbering): the intra ones,
/// then the inter ones.
pub const DC_PRED = 0;
pub const V_PRED = 1;
pub const H_PRED = 2;
pub const TM_PRED = 3;
pub const B_PRED = 4;
pub const NEARESTMV = 5;
pub const NEARMV = 6;
pub const ZEROMV = 7;
pub const NEWMV = 8;
pub const SPLITMV = 9;

/// The subblock modes of B_PRED.
pub const B_DC_PRED = 0;
pub const B_TM_PRED = 1;
pub const B_VE_PRED = 2;
pub const B_HE_PRED = 3;
pub const B_LD_PRED = 4;
pub const B_RD_PRED = 5;
pub const B_VR_PRED = 6;
pub const B_VL_PRED = 7;
pub const B_HD_PRED = 8;
pub const B_HU_PRED = 9;

/// The reference frames, as a macroblock names the one it predicts from;
/// 0 is the frame itself, an intra macroblock's.
pub const INTRA = 0;
pub const LAST = 1;
pub const GOLDEN = 2;
pub const ALTREF = 3;

/// A motion vector in quarter samples of the brightness - eighths of the
/// colour's - as libvpx keeps it in 16 bits.
pub const Mv = extern struct {
    x: i16 = 0,
    y: i16 = 0,

    pub fn raw(m: Mv) u32 {
        return @bitCast(m);
    }
    pub fn eql(a: Mv, b: Mv) bool {
        return a.raw() == b.raw();
    }
    pub fn isZero(m: Mv) bool {
        return m.raw() == 0;
    }
};

/// What is kept of each macroblock of a frame.
pub const MbInfo = struct {
    y_mode: u8 = DC_PRED,
    uv_mode: u8 = DC_PRED,
    ref: u8 = INTRA,
    segment: u8 = 0,
    /// The bitstream's mb_skip_coeff.
    skip: bool = false,
    /// Its subblock edges are filtered: it has coefficients, or is
    /// predicted in parts.
    inner: bool = false,
    /// SPLITMV's partitioning: as `tables.mv_partitions` numbers them.
    split: u8 = 0,
    mv: Mv = .{},
    /// B_PRED's subblock modes; any other intra mode's as the subblocks'
    /// neighbours take it.
    b_modes: [16]u8 = @splat(B_DC_PRED),
    /// SPLITMV's vectors, by subblock.
    mvs: [16]Mv = @splat(.{}),
};

/// A frame: its three planes, the size in whole macroblocks.
pub const Frame = struct {
    planes: [3][*]u8 = undefined,
    stride: [3]u32 = .{ 0, 0, 0 },
    /// The planes' size: the macroblocks'.
    width: [3]u32 = .{ 0, 0, 0 },
    height: [3]u32 = .{ 0, 0, 0 },
    memory: []u8 = &.{},
    /// The size shown, and when: the time its packet came with.
    shown_width: u32 = 0,
    shown_height: u32 = 0,
    time: i64 = 0,
    /// Its key frame's clamping bit, which ffmpeg takes for the whole
    /// byte rather than BT.601's range.
    full_range: bool = false,
    /// The macroblock rows that are final, for the frames that read it
    /// while it is decoded.
    progress: u32 = 0,
    /// How many references it is, and how many jobs decode it or read
    /// it; whether it waits to be shown, or is.
    refs: u8 = 0,
    pinned: u8 = 0,
    queued: bool = false,
};

/// The probabilities a frame may change and the next frames keep.
pub const Probs = struct {
    coeff: [4][8][3][11]u8,
    mv: [2][19]u8,
    y_mode: [4]u8,
    uv_mode: [3]u8,
};

/// Segmentation (RFC 6386 9.3), which stays until a frame changes it.
pub const Segmentation = struct {
    enabled: bool = false,
    update_map: bool = false,
    update_data: bool = false,
    absolute: bool = false,
    quant: [4]i8 = .{ 0, 0, 0, 0 },
    filter: [4]i8 = .{ 0, 0, 0, 0 },
    tree_probs: [3]u8 = .{ 255, 255, 255 },
};

/// The loop filter's adjustments by reference and mode (9.4), which stay
/// too.
pub const Deltas = struct {
    enabled: bool = false,
    ref: [4]i8 = .{ 0, 0, 0, 0 },
    mode: [4]i8 = .{ 0, 0, 0, 0 },
};

/// What the rest of a frame needs of its header.
pub const Header = struct {
    key: bool = false,
    version: u3 = 0,
    show: bool = true,
    simple_filter: bool = false,
    filter_level: u8 = 0,
    sharpness: u8 = 0,
    partitions: u8 = 1,
    refresh_golden: bool = false,
    refresh_alt: bool = false,
    copy_golden: u8 = 0,
    copy_alt: u8 = 0,
    sign_bias: [4]bool = .{ false, false, false, false },
    refresh_entropy: bool = true,
    refresh_last: bool = true,
    skip_enabled: bool = false,
    prob_skip: u8 = 0,
    prob_intra: u8 = 0,
    prob_last: u8 = 0,
    prob_golden: u8 = 0,
};

/// The dequantisation factors of a segment: DC and AC of the brightness,
/// of its second-order block, and of the colour.
pub const Quant = struct {
    y: [2]i16 = .{ 0, 0 },
    y2: [2]i16 = .{ 0, 0 },
    uv: [2]i16 = .{ 0, 0 },
};
