// SPDX-License-Identifier: MIT
//! What the parts of the VP9 decoder share: memory and the other cores
//! from whoever runs it, a frame's planes, the numbering of block sizes,
//! modes and references, and what is kept of each block of a frame.

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
    /// `s` at `n` elements, cleared; its old contents are gone.
    pub fn resize(env: Env, comptime T: type, s: *[]T, n: usize) bool {
        if (s.len == n) {
            if (n != 0) {
                const bytes: [*]u8 = @ptrCast(s.ptr);
                @memset(bytes[0 .. n * @sizeOf(T)], 0);
            }
            return true;
        }
        env.freeSlice(T, s.*);
        s.* = &.{};
        s.* = env.slice(T, n) orelse return false;
        return true;
    }
};

/// The other cores, from whoever runs the decoder: a worker task on each,
/// and a way to wait - as h264.vcodec's and vp8.vcodec's decoders have
/// them.
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

    /// Until the first `n` lines of `f` are final.
    pub fn lines(c: *const Cores, who: u32, f: *const Frame, n: u32) void {
        if (@atomicLoad(u32, &f.progress, .acquire) >= n) return;
        while (true) {
            c.arm(c.ctx, who);
            if (@atomicLoad(u32, &f.progress, .seq_cst) >= n) return;
            c.sleep(c.ctx, who);
        }
    }
};

/// The block sizes (`tables` has their dimensions).
pub const BLOCK_4X4 = 0;
pub const BLOCK_8X8 = 3;
pub const BLOCK_16X16 = 6;
pub const BLOCK_32X32 = 9;
pub const BLOCK_64X64 = 12;

pub const PARTITION_NONE = 0;
pub const PARTITION_HORZ = 1;
pub const PARTITION_VERT = 2;
pub const PARTITION_SPLIT = 3;

/// The transform sizes.
pub const TX_4X4 = 0;
pub const TX_8X8 = 1;
pub const TX_16X16 = 2;
pub const TX_32X32 = 3;
pub const TX_MODE_SELECT = 4;

/// The intra modes, then the inter ones.
pub const DC_PRED = 0;
pub const V_PRED = 1;
pub const H_PRED = 2;
pub const D45_PRED = 3;
pub const D135_PRED = 4;
pub const D117_PRED = 5;
pub const D153_PRED = 6;
pub const D207_PRED = 7;
pub const D63_PRED = 8;
pub const TM_PRED = 9;
pub const NEARESTMV = 10;
pub const NEARMV = 11;
pub const ZEROMV = 12;
pub const NEWMV = 13;

/// The references a block predicts from: none (a single reference's
/// second), the frame itself (intra), and the three a frame names.
pub const NONE: i8 = -1;
pub const INTRA_FRAME: i8 = 0;
pub const LAST_FRAME: i8 = 1;
pub const GOLDEN_FRAME: i8 = 2;
pub const ALTREF_FRAME: i8 = 3;

/// The interpolation filters; SWITCHABLE is a frame's when each block
/// names its own.
pub const EIGHTTAP = 0;
pub const EIGHTTAP_SMOOTH = 1;
pub const EIGHTTAP_SHARP = 2;
pub const BILINEAR = 3;
pub const SWITCHABLE = 4;

pub const SEG_LVL_ALT_Q = 0;
pub const SEG_LVL_ALT_L = 1;
pub const SEG_LVL_REF_FRAME = 2;
pub const SEG_LVL_SKIP = 3;

pub const CS_RGB = 7;

/// A motion vector in eighths of a brightness sample.
pub const Mv = extern struct {
    row: i16 = 0,
    col: i16 = 0,

    pub fn raw(m: Mv) u32 {
        return @bitCast(m);
    }
    pub fn eql(a: Mv, b: Mv) bool {
        return a.raw() == b.raw();
    }
};

/// A block as the decoder read it: where and how big, how it is
/// predicted, and where its coefficients are.
pub const Block = struct {
    /// Its top left in 8x8 units, and its size.
    row: u16 = 0,
    col: u16 = 0,
    size: u8 = 0,
    tx_size: u8 = 0,
    /// Whether it has coefficients: the bitstream's skip was 0.
    coded: bool = false,
    /// Skip as the loop filter and the next blocks take it: also set for
    /// an inter block of 8x8 or more whose coefficients all end at once.
    skip: bool = false,
    is_inter: bool = false,
    /// Whether its left neighbour is in its tile (AvailL).
    avail_l: bool = false,
    segment_id: u8 = 0,
    filter_level: u8 = 0,
    interp_filter: u8 = 0,
    y_mode: u8 = DC_PRED,
    uv_mode: u8 = DC_PRED,
    /// The modes of the four 4x4s of a block under 8x8; any other's mode
    /// four times.
    sub_modes: [4]u8 = @splat(DC_PRED),
    ref_frame: [2]i8 = .{ INTRA_FRAME, NONE },
    /// The vectors of the four 4x4s by reference, as `sub_modes`.
    mvs: [2][4]Mv = @splat(@splat(.{})),
    /// Its coefficients' first word in the frame's.
    coeffs: u32 = 0,
};

/// What the next frame reads of each 8x8 of this one for its motion
/// vector candidates: the references and the vectors of the block over
/// it (its bottom right 4x4's).
pub const MvRef = extern struct {
    ref_frame: [2]i8 = .{ INTRA_FRAME, NONE },
    mv: [2]Mv = .{ .{}, .{} },
};

/// A frame: three planes of 8-bit samples, or of 16-bit ones above 8 bits.
pub const Frame = struct {
    planes: [3][*]u8 = undefined,
    /// In samples.
    stride: [3]u32 = .{ 0, 0, 0 },
    memory: []u8 = &.{},
    /// The size coded, and the colour's subsampling and depth.
    width: u32 = 0,
    height: u32 = 0,
    ss_x: u1 = 1,
    ss_y: u1 = 1,
    bit_depth: u8 = 8,
    color_space: u8 = 0,
    full_range: bool = false,
    /// The size its planes were made for: whole superblocks.
    alloc_w: u32 = 0,
    alloc_h: u32 = 0,
    alloc_bytes: u8 = 0,
    /// How many lines are final, of the brightness and as many of the
    /// colour, subsampled: for the frames that read it while it is
    /// decoded.
    progress: u32 = 0,
    /// How many references it is, how many jobs decode it or read it,
    /// and how often it waits to be shown.
    refs: u8 = 0,
    pinned: u8 = 0,
    queued: u8 = 0,

    pub fn plane(f: *const Frame, comptime P: type, p: usize) [*]P {
        return @ptrCast(@alignCast(f.planes[p]));
    }
};
