// SPDX-License-Identifier: MIT
//! What the parts of the AV1 decoder share: memory and the other cores
//! from whoever runs it, a frame's planes, and the numbering of block
//! sizes, transform sizes, modes and references (the specification's).

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
    /// `s` at least `n` elements long, keeping what it holds: grown by
    /// half again at least, so that appending stays cheap.
    pub fn grow(env: Env, comptime T: type, s: *[]T, n: usize) bool {
        if (s.len >= n) return true;
        const len = @max(n, s.len + s.len / 2, 64);
        const fresh = env.slice(T, len) orelse return false;
        @memcpy(fresh[0..s.len], s.*);
        env.freeSlice(T, s.*);
        s.* = fresh;
        return true;
    }
    pub fn create(env: Env, comptime T: type) ?*T {
        const bytes = env.alloc(env.ctx, @sizeOf(T), true) orelse return null;
        return @ptrCast(@alignCast(bytes));
    }
    pub fn destroy(env: Env, comptime T: type, p: *T) void {
        env.free(env.ctx, @ptrCast(p), @sizeOf(T));
    }
};

/// The other cores, from whoever runs the decoder: a worker task on each,
/// and a way to wait - as the other codec modules' decoders have them.
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
        c.until(who, &f.progress, n);
    }

    /// Until `f` is read down to mi row `rows`; `Frame.whole`: all of
    /// it.
    pub fn read(c: *const Cores, who: u32, f: *const Frame, rows: u32) void {
        c.until(who, &f.parsed, rows);
    }

    fn until(c: *const Cores, who: u32, count: *const u32, n: u32) void {
        if (@atomicLoad(u32, count, .acquire) >= n) return;
        while (true) {
            c.arm(c.ctx, who);
            if (@atomicLoad(u32, count, .seq_cst) >= n) return;
            c.sleep(c.ctx, who);
        }
    }
};

pub const NUM_REF_FRAMES = 8;
pub const REFS_PER_FRAME = 7;
pub const PRIMARY_REF_NONE = 7;
pub const MAX_SEGMENTS = 8;
pub const SEG_LVL_ALT_Q = 0;
pub const SEG_LVL_ALT_LF_Y_V = 1;
pub const SEG_LVL_REF_FRAME = 5;
pub const SEG_LVL_SKIP = 6;
pub const SEG_LVL_GLOBALMV = 7;
pub const SEG_LVL_MAX = 8;
pub const MAX_LOOP_FILTER = 63;
pub const WARPEDMODEL_PREC_BITS = 16;

pub const KEY_FRAME = 0;
pub const INTER_FRAME = 1;
pub const INTRA_ONLY_FRAME = 2;
pub const SWITCH_FRAME = 3;

/// The block sizes (`tables` has their dimensions).
pub const BLOCK_4X4 = 0;
pub const BLOCK_4X8 = 1;
pub const BLOCK_8X4 = 2;
pub const BLOCK_8X8 = 3;
pub const BLOCK_8X16 = 4;
pub const BLOCK_16X8 = 5;
pub const BLOCK_16X16 = 6;
pub const BLOCK_16X32 = 7;
pub const BLOCK_32X16 = 8;
pub const BLOCK_32X32 = 9;
pub const BLOCK_32X64 = 10;
pub const BLOCK_64X32 = 11;
pub const BLOCK_64X64 = 12;
pub const BLOCK_64X128 = 13;
pub const BLOCK_128X64 = 14;
pub const BLOCK_128X128 = 15;
pub const BLOCK_4X16 = 16;
pub const BLOCK_16X4 = 17;
pub const BLOCK_8X32 = 18;
pub const BLOCK_32X8 = 19;
pub const BLOCK_16X64 = 20;
pub const BLOCK_64X16 = 21;
pub const BLOCK_INVALID = 22;

pub const PARTITION_NONE = 0;
pub const PARTITION_HORZ = 1;
pub const PARTITION_VERT = 2;
pub const PARTITION_SPLIT = 3;
pub const PARTITION_HORZ_A = 4;
pub const PARTITION_HORZ_B = 5;
pub const PARTITION_VERT_A = 6;
pub const PARTITION_VERT_B = 7;
pub const PARTITION_HORZ_4 = 8;
pub const PARTITION_VERT_4 = 9;

/// The transform sizes.
pub const TX_4X4 = 0;
pub const TX_8X8 = 1;
pub const TX_16X16 = 2;
pub const TX_32X32 = 3;
pub const TX_64X64 = 4;
pub const TX_4X8 = 5;
pub const TX_8X4 = 6;
pub const TX_8X16 = 7;
pub const TX_16X8 = 8;
pub const TX_16X32 = 9;
pub const TX_32X16 = 10;
pub const TX_32X64 = 11;
pub const TX_64X32 = 12;
pub const TX_4X16 = 13;
pub const TX_16X4 = 14;
pub const TX_8X32 = 15;
pub const TX_32X8 = 16;
pub const TX_16X64 = 17;
pub const TX_64X16 = 18;

pub const ONLY_4X4 = 0;
pub const TX_MODE_LARGEST = 1;
pub const TX_MODE_SELECT = 2;

/// The transform types: the columns' then the rows'.
pub const DCT_DCT = 0;
pub const ADST_DCT = 1;
pub const DCT_ADST = 2;
pub const ADST_ADST = 3;
pub const FLIPADST_DCT = 4;
pub const DCT_FLIPADST = 5;
pub const FLIPADST_FLIPADST = 6;
pub const ADST_FLIPADST = 7;
pub const FLIPADST_ADST = 8;
pub const IDTX = 9;
pub const V_DCT = 10;
pub const H_DCT = 11;
pub const V_ADST = 12;
pub const H_ADST = 13;
pub const V_FLIPADST = 14;
pub const H_FLIPADST = 15;

/// The intra modes, then the inter ones (YMode).
pub const DC_PRED = 0;
pub const V_PRED = 1;
pub const H_PRED = 2;
pub const D45_PRED = 3;
pub const D135_PRED = 4;
pub const D113_PRED = 5;
pub const D157_PRED = 6;
pub const D203_PRED = 7;
pub const D67_PRED = 8;
pub const SMOOTH_PRED = 9;
pub const SMOOTH_V_PRED = 10;
pub const SMOOTH_H_PRED = 11;
pub const PAETH_PRED = 12;
pub const UV_CFL_PRED = 13;
pub const NEARESTMV = 13;
pub const NEARMV = 14;
pub const GLOBALMV = 15;
pub const NEWMV = 16;
pub const NEAREST_NEARESTMV = 17;
pub const NEAR_NEARMV = 18;
pub const NEAREST_NEWMV = 19;
pub const NEW_NEARESTMV = 20;
pub const NEAR_NEWMV = 21;
pub const NEW_NEARMV = 22;
pub const GLOBAL_GLOBALMV = 23;
pub const NEW_NEWMV = 24;

/// The references a block predicts from: none (a single reference's
/// second), the frame itself (intra), and the seven a frame names.
pub const NONE: i8 = -1;
pub const INTRA_FRAME: i8 = 0;
pub const LAST_FRAME: i8 = 1;
pub const LAST2_FRAME: i8 = 2;
pub const LAST3_FRAME: i8 = 3;
pub const GOLDEN_FRAME: i8 = 4;
pub const BWDREF_FRAME: i8 = 5;
pub const ALTREF2_FRAME: i8 = 6;
pub const ALTREF_FRAME: i8 = 7;

/// The interpolation filters; SWITCHABLE is a frame's when each block
/// names its own.
pub const EIGHTTAP = 0;
pub const EIGHTTAP_SMOOTH = 1;
pub const EIGHTTAP_SHARP = 2;
pub const BILINEAR = 3;
pub const SWITCHABLE = 4;

pub const SIMPLE = 0;
pub const OBMC = 1;
pub const LOCALWARP = 2;

pub const IDENTITY = 0;
pub const TRANSLATION = 1;
pub const ROTZOOM = 2;
pub const AFFINE = 3;

pub const COMPOUND_WEDGE = 0;
pub const COMPOUND_DIFFWTD = 1;
pub const COMPOUND_AVERAGE = 2;
pub const COMPOUND_INTRA = 3;
pub const COMPOUND_DISTANCE = 4;

pub const II_DC_PRED = 0;
pub const II_V_PRED = 1;
pub const II_H_PRED = 2;
pub const II_SMOOTH_PRED = 3;

pub const RESTORE_NONE = 0;
pub const RESTORE_WIENER = 1;
pub const RESTORE_SGRPROJ = 2;
pub const RESTORE_SWITCHABLE = 3;

pub const MC_IDENTITY = 0;

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

/// What a frame keeps of each 8x8 for the motion field of the frames
/// after it (7.19): a reference and its vector, `ref` NONE for none.
pub const MfMv = extern struct {
    mv: Mv = .{},
    ref: i8 = NONE,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

/// A frame: three planes of 8-bit samples, or of 16-bit ones above 8 bits.
pub const Frame = struct {
    planes: [3][*]u8 = undefined,
    /// In samples.
    stride: [3]u32 = .{ 0, 0, 0 },
    memory: []u8 = &.{},
    /// The size, upscaled (UpscaledWidth and FrameHeight), and the
    /// colour's subsampling and depth.
    width: u32 = 0,
    height: u32 = 0,
    ss_x: u1 = 1,
    ss_y: u1 = 1,
    mono: bool = false,
    bit_depth: u8 = 8,
    /// The colour's description: the primaries, the transfer, the matrix
    /// and whether it spans the full range.
    primaries: u8 = 2,
    transfer: u8 = 2,
    matrix: u8 = 2,
    full_range: bool = false,
    /// The size its planes were made for: whole superblocks.
    alloc_w: u32 = 0,
    alloc_h: u32 = 0,
    alloc_bytes: u8 = 0,
    /// The motion field (by 8x8) and the segment map (by 4x4) the frame
    /// leaves for the frames after it, and the CDFs.
    mvs: []MfMv = &.{},
    segs: []u8 = &.{},
    /// How many lines are final, of the brightness and as many of the
    /// colour, subsampled: for the frames that read it while it is
    /// decoded.
    progress: u32 = 0,
    /// The mi rows read, whose motion field is there for the frames after
    /// it; `whole` once all is, its segment map and CDFs too.
    parsed: u32 = 0,
    /// Read wrongly, or predicted from such a frame: not shown, as the
    /// frames after an error are not. Final once it is read, for what it
    /// leaves the frames after it (all zeros when it was read wrongly),
    /// and once a line of it is final, for the rest.
    broken: bool = false,
    /// How many references it is, how many jobs decode it or read it,
    /// and how often it waits to be shown.
    refs: u8 = 0,
    pinned: u8 = 0,
    queued: u8 = 0,

    pub const whole: u32 = 0xFFFF_FFFF;

    pub fn plane(f: *const Frame, comptime P: type, p: usize) [*]P {
        return @ptrCast(@alignCast(f.planes[p]));
    }
};

pub fn clip3(lo: i32, hi: i32, v: i32) i32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}

pub fn round2(x: i32, n: u5) i32 {
    if (n == 0) return x;
    return (x + (@as(i32, 1) << (n - 1))) >> n;
}

pub fn round2_64(x: i64, n: u6) i64 {
    if (n == 0) return x;
    return (x + (@as(i64, 1) << (n - 1))) >> n;
}

/// Round2 of the magnitude, the sign kept.
pub fn round2Signed(x: i64, n: u6) i64 {
    return if (x >= 0) round2_64(x, n) else -round2_64(-x, n);
}

pub fn floorLog2(x: u32) u5 {
    return @intCast(31 - @clz(x));
}

pub fn ceilLog2(x: u32) u5 {
    if (x < 2) return 0;
    return @intCast(32 - @clz(x - 1));
}
