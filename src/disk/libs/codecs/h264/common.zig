// SPDX-License-Identifier: MIT
//! What the parts of the decoder share: a picture's store, what is kept
//! of each macroblock, a reference picture, and the block orders.

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

/// The other cores, from whoever runs the decoder: `workers` of them
/// that each run a job given them, numbered from 0, and a way for
/// everyone to wait for the others - the workers and, as number
/// `workers`, the one that runs the decoder.
pub const Cores = struct {
    ctx: *anyopaque,
    workers: u32,
    /// `job(arg)` run by worker `worker`, which runs nothing else then.
    run: *const fn (ctx: *anyopaque, worker: u32, job: *const fn (arg: *anyopaque) void, arg: *anyopaque) void,
    /// A wait: `arm(who)`, then a look whether what is waited for is
    /// there, and when it is not `sleep(who)`, which returns once `wake`
    /// was called after the `arm`, or sooner; then round again.
    arm: *const fn (ctx: *anyopaque, who: u32) void,
    sleep: *const fn (ctx: *anyopaque, who: u32) void,
    /// Something others may wait for changed.
    wake: *const fn (ctx: *anyopaque) void,
};

/// How a picture decoded on a worker waits for the rows of the pictures
/// it refers to.
pub const Sync = struct {
    cores: *const Cores,
    who: u32,

    /// Until the first `rows` macroblock rows of `s` are final.
    pub fn rows(sy: *const Sync, s: *const Store, n: u32) void {
        if (@atomicLoad(u32, &s.progress, .acquire) >= n) return;
        const c = sy.cores;
        while (true) {
            c.arm(c.ctx, sy.who);
            if (@atomicLoad(u32, &s.progress, .seq_cst) >= n) return;
            c.sleep(c.ctx, sy.who);
        }
    }
};

/// The luma4x4BlkIdx order (6.4.3): block k's place, x and y in 4x4
/// blocks, and its raster index y * 4 + x.
pub const blk_x = [16]u8{ 0, 1, 0, 1, 2, 3, 2, 3, 0, 1, 0, 1, 2, 3, 2, 3 };
pub const blk_y = [16]u8{ 0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3 };
pub const blk_raster = [16]u8{ 0, 1, 4, 5, 2, 3, 6, 7, 8, 9, 12, 13, 10, 11, 14, 15 };

/// A macroblock's kind, as far as everything after its parsing cares.
pub const Kind = enum(u8) {
    i4x4,
    i8x8,
    i16x16,
    ipcm,
    si,
    /// Inter, P or B, with its partitions in `MbInfo`.
    inter,
};

pub const F_FIELD: u8 = 1 << 0;
pub const F_T8X8: u8 = 1 << 1;
pub const F_SKIP: u8 = 1 << 2;
/// B_Skip or B_Direct_16x16: the CABAC contexts ask.
pub const F_DIRECT: u8 = 1 << 3;
pub const F_INTRA: u8 = 1 << 4;
/// Decoded in this picture: a neighbour may be looked at.
pub const F_DONE: u8 = 1 << 5;
/// I_PCM: its blocks count as coded, its samples as they are.
pub const F_PCM: u8 = 1 << 6;
/// In an SP or SI slice: the deblocking filter takes it as intra.
pub const F_SWITCH: u8 = 1 << 7;

/// What is kept of each macroblock of the picture being decoded, on the
/// frame's grid: a field picture's macroblocks on the rows of its parity,
/// a pair of MBAFF's top on the even row, its bottom on the odd.
pub const MbInfo = struct {
    /// The slice that decoded it - a number never given twice - so that a
    /// neighbour is there only when it was decoded in the current slice.
    slice: u32 = 0,
    kind: Kind = .inter,
    flags: u8 = 0,
    /// QPY as the deblocking filter takes it: QP'Y 0 for I_PCM, as
    /// libavcodec and the reference decoder take it.
    qp: i8 = 0,
    /// QPc of Cb and Cr, as the deblocking filter takes them.
    qpc: [2]i8 = .{ 0, 0 },
    /// CodedBlockPatternLuma | CodedBlockPatternChroma << 4; I_PCM's as if
    /// everything were coded.
    cbp: u8 = 0,
    /// intra_chroma_pred_mode: 0 for inter macroblocks and I_PCM.
    chroma_mode: u8 = 0,
    /// The 8x8 blocks predicted in direct mode (bit per block).
    direct8: u8 = 0,
    /// The coded_block_flag of the DC blocks: luma (bit 0), Cb (1), Cr
    /// (2); and with 4:4:4 Cb's and Cr's own 16x16 DC (bits 1 and 2 too).
    cbf_dc: u8 = 0,
    /// Intra 4x4 / 8x8 prediction modes, by raster 4x4 block.
    i_modes: [16]u8 = @splat(2),
    /// TotalCoeff of each 4x4 block, raster: luma, then Cb's and Cr's
    /// blocks on a grid four wide.
    nnz: [48]u8 = @splat(0),
    /// Non-zero coefficients of each 8x8 luma block (and of Cb's, Cr's
    /// with 4:4:4), for the deblocking of a macroblock with 8x8 transforms.
    nz8: u16 = 0,
    /// The absolute mvd of each 4x4 block, both lists, saturated at 127.
    mvd: [2][16][2]u8 = @splat(@splat(.{ 0, 0 })),
    /// Reference index per 8x8 block, both lists: -1 for none.
    ref: [2][4]i8 = @splat(@splat(-1)),
    /// The picture each 8x8 block refers to (`RefPic.id`), both lists.
    ref_id: [2][4]u32 = @splat(@splat(0)),
    mv: [2][16][2]i16 = @splat(@splat(.{ 0, 0 })),
    /// Its slice's disable_deblocking_filter_idc and filter offsets.
    filter: u8 = 0,
    alpha_off: i8 = 0,
    beta_off: i8 = 0,
};

/// What a reference picture keeps of each of its macroblocks for a later
/// B picture's direct prediction (8.4.1.2): its motion, and whether it
/// was intra or a field macroblock.
pub const Motion = struct {
    mv: [2][16][2]i16 = @splat(@splat(.{ 0, 0 })),
    ref: [2][4]i8 = @splat(@splat(-1)),
    ref_id: [2][4]u32 = @splat(@splat(0)),
    intra: bool = true,
    field: bool = false,
};

pub const RefKind = enum(u8) { none, short, long };

/// A frame store of the decoded picture buffer (C.4): a frame, a
/// complementary field pair, or one field, with its samples and marking.
pub const Store = struct {
    in_use: bool = false,
    uid: u32 = 0,
    /// The samples: luma, Cb, Cr, each `stride` samples apart, of the
    /// whole frame; the bytes of one sample are the store's depth's.
    planes: [3][*]u8 = undefined,
    /// Each plane's row length and size in samples, of the frame.
    stride: [3]usize = .{ 0, 0, 0 },
    width: [3]u32 = .{ 0, 0, 0 },
    height: [3]u32 = .{ 0, 0, 0 },
    memory: ?[*]u8 = null,
    memory_len: usize = 0,
    /// Which fields hold a decoded picture: 1 top, 2 bottom, 3 both.
    fields: u2 = 0,
    /// Coded as one frame (with or without field macroblock pairs), or
    /// as fields.
    frame_coded: bool = false,
    mbaff: bool = false,
    ref: [2]RefKind = .{ .none, .none },
    frame_num: u32 = 0,
    frame_num_wrap: i32 = 0,
    long_term_idx: u32 = 0,
    poc: [2]i32 = .{ 0, 0 },
    output_needed: bool = false,
    non_existing: bool = false,
    idr: bool = false,
    mmco5: bool = false,
    /// When it is shown, as its packet said.
    time: i64 = 0,
    /// Each macroblock's motion: a frame's in frame order, or each field's
    /// in its own half (top first).
    motion: []Motion = &.{},
    /// Whether some slice was missing or damaged.
    damaged: bool = false,
    /// The macroblock rows of the frame that are final, filtered and all:
    /// a picture decoded on a worker counts them up as it goes.
    progress: u32 = 0,
    /// The jobs that read it: it is not used again before they are done.
    pinned: u8 = 0,

    pub fn isRef(s: *const Store) bool {
        return s.ref[0] != .none or s.ref[1] != .none;
    }
    pub fn isShortFrame(s: *const Store) bool {
        return s.ref[0] == .short and s.ref[1] == .short;
    }
    pub fn isLongFrame(s: *const Store) bool {
        return s.ref[0] == .long and s.ref[1] == .long;
    }
    /// PicOrderCnt of the frame or pair: the lower of its fields'.
    pub fn framePoc(s: *const Store) i32 {
        if (s.fields == 1) return s.poc[0];
        if (s.fields == 2) return s.poc[1];
        return @min(s.poc[0], s.poc[1]);
    }
};

/// A reference picture: a frame (structure 3) or a field (1 top, 2
/// bottom) of a store.
pub const RefPic = struct {
    store: ?*Store = null,
    structure: u2 = 3,
    long: bool = false,

    pub fn poc(r: RefPic) i32 {
        const s = r.store.?;
        return switch (r.structure) {
            1 => s.poc[0],
            2 => s.poc[1],
            else => @min(s.poc[0], s.poc[1]),
        };
    }
    /// What tells this picture from every other: the store and the field.
    pub fn id(r: RefPic) u32 {
        const s = r.store orelse return 0;
        return s.uid << 2 | r.structure;
    }
};
