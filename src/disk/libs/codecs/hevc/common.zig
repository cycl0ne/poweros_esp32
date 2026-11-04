// SPDX-License-Identifier: MIT
//! What the parts of the decoder share: a picture's store, the motion a
//! reference keeps for later pictures, and the memory and cores the
//! decoder is given.

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

    /// Until the first `n` luma rows of `s` are final.
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

/// What a picture keeps of each 16x16 block for the temporal motion
/// vector prediction of later pictures (8.5.3.2.8): the motion of the
/// block's top-left 4x4, the order counts of the pictures it referred
/// to, and which of them were long-term references then.
pub const Motion = struct {
    mv: [2][2]i16 = .{ .{ 0, 0 }, .{ 0, 0 } },
    poc: [2]i32 = .{ 0, 0 },
    /// Bit X: list X used. Bit 2 + X: its picture a long-term reference.
    /// 0: intra, or nothing decoded there.
    flags: u8 = 0,
};

pub const RefKind = enum(u8) { none, short, long };

/// How a picture is shown, as its sequence says (7.4.3.2.1, E.3.1).
pub const Format = struct {
    /// The conformance window, in luma samples.
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    chroma_format: u2 = 1,
    depth_y: u5 = 8,
    depth_c: u5 = 8,
    /// The VUI's matrix_coeffs, colour_primaries, transfer_characteristics
    /// and video_full_range_flag: what the numbers mean, which for a film
    /// of high dynamic range is nothing like a television's.
    matrix: u8 = 2,
    primaries: u8 = 2,
    transfer: u8 = 2,
    full_range: bool = false,
    /// The light the film was mastered for, in candelas a square metre,
    /// from the mastering display's SEI or the content light level's; 0
    /// where the stream says neither.
    peak_nits: u16 = 0,

    /// Whether a sample takes two bytes.
    pub fn wide(f: Format) bool {
        return f.depth_y > 8 or f.depth_c > 8;
    }
};

/// A picture store of the decoded picture buffer (C.5.2).
pub const Store = struct {
    in_use: bool = false,
    uid: u32 = 0,
    /// The samples: luma, Cb, Cr, each `stride` samples apart; the bytes
    /// of one sample are the store's depth's.
    planes: [3][*]u8 = undefined,
    stride: [3]usize = .{ 0, 0, 0 },
    width: [3]u32 = .{ 0, 0, 0 },
    height: [3]u32 = .{ 0, 0, 0 },
    /// How it is shown, as its sequence said when it was decoded: a
    /// picture of the sequence before is shown after the next began.
    format: Format = .{},
    memory: ?[*]u8 = null,
    memory_len: usize = 0,
    ref: RefKind = .none,
    poc: i32 = 0,
    /// slice_pic_order_cnt_lsb: what a long-term entry without its MSB
    /// names it by.
    poc_lsb: u32 = 0,
    output_needed: bool = false,
    /// PicLatencyCount (C.5.2.3).
    latency: u32 = 0,
    /// Made up for a missing reference (8.3.3): never shown.
    generated: bool = false,
    /// When it is shown, as its packet said.
    time: i64 = 0,
    /// Each 16x16 block's motion, by rows.
    motion: []Motion = &.{},
    /// Whether some slice was missing or damaged.
    damaged: bool = false,
    /// The luma rows that are final, filtered and all: a picture decoded
    /// on a worker counts them up as it goes.
    progress: u32 = 0,
    /// The jobs that read it: it is not used again before they are done.
    pinned: u8 = 0,
    /// The decoded picture hash SEI of the picture (D.3.20), when it
    /// came: hash_type + 1 (0: none), and each plane's hash.
    hash_kind: u8 = 0,
    hash: [3][16]u8 = undefined,

    pub fn isRef(s: *const Store) bool {
        return s.ref != .none;
    }
};
