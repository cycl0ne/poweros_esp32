// SPDX-License-Identifier: MPL-2.0
//! The graphics block's DMA engine: its queue's ring, what the engine
//! writes back, and the jobs put on it.
//!
//! **The ring** is one queue of the engine's first instance, run as the
//! vendor's driver runs its own kernel queue on this engine
//! (sdma_v6_0_gfx_resume_instance), without the scheduler firmware: 64 KiB
//! of the device's own memory the engine reads its packets from, through
//! the graphics hub's aperture, followed by a page it writes back to - how
//! far it has read, in bytes, after every few packets - and that the
//! queue's write pointer is copied into, as its firmware also looks
//! there. A job is told to the engine through its write pointer register
//! (no doorbell), in bytes since the queue started.
//!
//! **A job** is the caller's packets copied into the ring, followed by a
//! fence - the job's number written into the page, uncached - and a trap,
//! which raises the engine's interrupt; then single NOPs up to the next 16
//! words, the ring's alignment. The ring wraps: a packet may run over its
//! end. The interrupt's server counts it and signals the queue's waitable,
//! which a task waiting for a job sleeps on (WaitGPUDMA); the job's
//! number in the page says which have been done. Numbers start at 1 and
//! wrap past 0, and are compared modulo 2^32.
//!
//! The engine's packets are read from memory the CPU writes
//! write-combining, so a fence comes before the write pointer; what the
//! engine writes goes past the block's caches (its writes bypass the L2,
//! the fence is uncached), so the CPU reads it from the memory.
//!
//! **A reset of the whole block** (ResetGPUCompute) lets the engine
//! finish its jobs first and has it rinse the block's caches with one job
//! of its own (`rinse`); the jobs it has not done by then are given up -
//! those after `dma_lost_after` up to `dma_given_up`, which WaitGPUDMA
//! answers false once the queue, started again, reads them done (`lost`).
//! A quarter of the numbers' round later they are forgotten (`longPast`).

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu_base.zig").AMDGPUBase;
const _graphics = @import("../graphics/_graphics.zig");
const Register = _graphics.Register;

// The engine's registers, counted from the graphics block's first address
// but for its control of its firmware, from the second.
pub const CNTL: Register = .{ .segment = 0, .offset = 0x001c };
pub const SEM_WAIT_FAIL_TIMER_CNTL: Register = .{ .segment = 0, .offset = 0x0022 };
pub const STATUS_REG: Register = .{ .segment = 0, .offset = 0x0025 };
pub const WATCHDOG_CNTL: Register = .{ .segment = 0, .offset = 0x002e };
pub const UTCL1_CNTL: Register = .{ .segment = 0, .offset = 0x003c };
pub const UTCL1_PAGE: Register = .{ .segment = 0, .offset = 0x003f };
pub const RB_CNTL: Register = .{ .segment = 0, .offset = 0x0080 };
pub const RB_BASE: Register = .{ .segment = 0, .offset = 0x0081 };
pub const RB_BASE_HI: Register = .{ .segment = 0, .offset = 0x0082 };
pub const RB_RPTR: Register = .{ .segment = 0, .offset = 0x0083 };
pub const RB_RPTR_HI: Register = .{ .segment = 0, .offset = 0x0084 };
pub const RB_WPTR: Register = .{ .segment = 0, .offset = 0x0085 };
pub const RB_WPTR_HI: Register = .{ .segment = 0, .offset = 0x0086 };
pub const RB_RPTR_ADDR_HI: Register = .{ .segment = 0, .offset = 0x0088 };
pub const RB_RPTR_ADDR_LO: Register = .{ .segment = 0, .offset = 0x0089 };
pub const IB_CNTL: Register = .{ .segment = 0, .offset = 0x008a };
pub const DOORBELL: Register = .{ .segment = 0, .offset = 0x0092 };
pub const DOORBELL_OFFSET: Register = .{ .segment = 0, .offset = 0x00ab };
pub const RB_WPTR_POLL_ADDR_HI: Register = .{ .segment = 0, .offset = 0x00b2 };
pub const RB_WPTR_POLL_ADDR_LO: Register = .{ .segment = 0, .offset = 0x00b3 };
pub const MINOR_PTR_UPDATE: Register = .{ .segment = 0, .offset = 0x00b5 };
pub const F32_CNTL: Register = .{ .segment = 1, .offset = 0x589a };

// Their fields.
pub const TRAP_ENABLE: u32 = 1 << 0;
pub const CTXEMPTY_INT_ENABLE: u32 = 1 << 28;
pub const HALT: u32 = 1 << 0;
pub const TH1_RESET: u32 = 1 << 13;
pub const RB_ENABLE: u32 = 1 << 0;
pub const RB_SIZE_SHIFT = 1;
pub const RB_SIZE_MASK: u32 = 0x1f << RB_SIZE_SHIFT;
pub const WPTR_POLL_ENABLE: u32 = 1 << 8;
pub const F32_WPTR_POLL_ENABLE: u32 = 1 << 11;
pub const RPTR_WRITEBACK_ENABLE: u32 = 1 << 12;
pub const RB_PRIV: u32 = 1 << 23;
pub const IB_ENABLE: u32 = 1 << 0;
pub const DOORBELL_ENABLE: u32 = 1 << 28;
pub const QUEUE_HANG_COUNT_MASK: u32 = 0xff;
pub const REDO_DELAY_MASK: u32 = 0x1f;
pub const RESP_MODE_SHIFT = 9;
pub const RESP_MODE_MASK: u32 = 3 << RESP_MODE_SHIFT;
/// The engine's reads not kept in the L2, its writes past it, and neither
/// kept in the last-level cache: the vendor's defaults.
pub const UTCL1_PAGE_KEEP: u32 = 0x00ff_0fff;
pub const UTCL1_PAGE_POLICIES: u32 = 2 << 12 | 3 << 14 | 1 << 24;

/// The engine's interrupts come as the graphics block's, the trap among
/// them by its own source.
pub const INTERRUPT_CLIENT: u32 = 0x0a;
pub const TRAP_SOURCE: u32 = 0x31;

// The packets the queue writes itself.
pub const OP_NOP: u32 = 0;
pub const OP_WRITE: u32 = 2;
pub const OP_FENCE: u32 = 5;
pub const OP_TRAP: u32 = 6;
pub const FENCE_UNCACHED: u32 = 3 << 16;

/// The graphics block's caches rinsed, five words (SDMA_OP_GCR_REQ): the
/// header, the range's start and end - 0 and 0, every address - and the
/// control at bit 16 of the third word and in the fourth's low three
/// bits, the vendor's (sdma_v6_0_ring_emit_mem_sync): the second level
/// written back and dropped, and the first levels, the vertex, scalar and
/// instruction caches and the metadata's dropped.
pub const OP_GCR_REQ: u32 = 17;
pub const GCR_GLI_INV: u32 = 1 << 0;
pub const GCR_GLM_INV: u32 = 1 << 5;
pub const GCR_GLK_INV: u32 = 1 << 7;
pub const GCR_GLV_INV: u32 = 1 << 8;
pub const GCR_GL1_INV: u32 = 1 << 9;
pub const GCR_GL2_INV: u32 = 1 << 14;
pub const GCR_GL2_WB: u32 = 1 << 15;
pub const rinse_control = GCR_GL2_INV | GCR_GL2_WB | GCR_GLM_INV | GCR_GL1_INV | GCR_GLV_INV | GCR_GLK_INV | GCR_GLI_INV;

/// The packet that rinses the block's caches.
pub fn rinse() [5]u32 {
    return .{ OP_GCR_REQ, 0, rinse_control << 16, rinse_control >> 16, 0 };
}

/// The ring: 64 KiB, the size code its register takes - the power of two
/// its words are - and the alignment every job is padded to, in words.
pub const ring_bytes: u32 = 64 * 1024;
pub const ring_words: u32 = ring_bytes / 4;
pub const ring_size_code: u32 = 14;
pub const job_alignment: u32 = 16;
comptime {
    if (@as(u32, 1) << ring_size_code != ring_words) @compileError("the ring's size code does not match its words");
}
/// The page after it: the read pointer the engine writes back, the write
/// pointer's copy, the fence and the ring test's word, at these bytes.
pub const page_bytes: u32 = 4096;
pub const read_back_at: u32 = ring_bytes;
pub const write_copy_at: u32 = ring_bytes + 8;
pub const fence_at: u32 = ring_bytes + 16;
pub const test_at: u32 = ring_bytes + 20;
/// The words a job's own tail takes: the fence and the trap.
pub const tail_words: u32 = 4 + 2;

/// The most a job may wait for room in the ring, and the ring test's
/// wait: the vendor's 100 ms for a test, a second for room.
pub const room_most_us: u64 = 1_000_000;
pub const test_most_us: u64 = 100_000;

pub fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

/// The word at byte `at` of the queue's piece, as the CPU reaches it.
pub fn word(ab: *AMDGPUBase, at: u32) *volatile u32 {
    return @ptrFromInt(@as(usize, @intCast(ab.dma_ring.cpu)) + at);
}

fn double(ab: *AMDGPUBase, at: u32) *volatile u64 {
    return @ptrFromInt(@as(usize, @intCast(ab.dma_ring.cpu)) + at);
}

/// How far the engine has read the ring, in bytes, as it last wrote it
/// back.
pub fn readBack(ab: *AMDGPUBase) u64 {
    return double(ab, read_back_at).*;
}

/// The number of the last job the engine has done.
pub fn done(ab: *AMDGPUBase) u32 {
    return word(ab, fence_at).*;
}

/// Whether job `job` is done by the job `last` that is.
pub fn passed(last: u32, job: u32) bool {
    return @as(i32, @bitCast(last -% job)) >= 0;
}

/// The number of the job after `job`: numbers go round past 0, which no
/// job has.
pub fn nextJob(job: u32) u32 {
    const next = job +% 1;
    return if (next == 0) 1 else next;
}

/// Whether the queue runs, or is being started again by a reset of the
/// whole block - which its calls wait for rather than take it as stopped.
pub fn runs(ab: *AMDGPUBase) bool {
    return ab.dma_running or @atomicLoad(bool, &ab.resetting_block, .acquire);
}

/// Whether a reset of the whole block gave job `job` up, as the base keeps
/// the jobs it did: read without the queue's lock.
pub fn givenUp(ab: *AMDGPUBase, job: u32) bool {
    return lost(@atomicLoad(u32, &ab.dma_lost_after, .acquire), @atomicLoad(u32, &ab.dma_given_up, .acquire), job);
}

/// Whether a reset of the whole block gave job `job` up: one after
/// `lost_after` and not after `given_up`, the jobs that reset found not
/// done.
pub fn lost(lost_after: u32, given_up: u32, job: u32) bool {
    return passed(given_up, job) and !passed(lost_after, job);
}

/// Whether job `number` is a quarter of the numbers' round past
/// `given_up`, the last job a reset gave up: by then no task waits for
/// those, and they are forgotten, so that numbers come round again are
/// not taken as theirs.
pub fn longPast(given_up: u32, number: u32) bool {
    return passed(number, given_up +% (1 << 30));
}

/// The words a job of `words` takes in the ring with its tail and the
/// padding after it.
pub fn jobWords(words: u32) u32 {
    const whole = words + tail_words;
    return (whole + job_alignment - 1) / job_alignment * job_alignment;
}

/// The bytes the engine has yet to read of what is written, whether it
/// writes its read pointer back counted from the start or within the
/// ring.
pub fn pending(written: u64, read: u64) u32 {
    return @intCast((written -% read) & (ring_bytes - 1));
}

/// `value` put into the ring at word `index` from where the queue has
/// written to, which moves on.
fn put(ab: *AMDGPUBase, value: u32) void {
    const index: u32 = @intCast(ab.dma_written / 4 % ring_words);
    word(ab, index * 4).* = value;
    ab.dma_written += 4;
}

/// `packets` put into the ring with the padding after them, and nothing
/// else: the ring's own test, before any job has a number.
pub fn putPadded(ab: *AMDGPUBase, packets: []const u32) void {
    for (packets) |value| put(ab, value);
    const whole: u32 = @intCast(packets.len);
    const padding = (whole + job_alignment - 1) / job_alignment * job_alignment - whole;
    for (0..padding) |_| put(ab, OP_NOP);
}

/// `packets` put into the ring as job `number`, with its fence, its trap
/// and the padding after them - as many words as `jobWords` says. Under
/// the queue's lock; the engine is not told yet.
pub fn putJob(ab: *AMDGPUBase, packets: []const u32, number: u32) void {
    for (packets) |value| put(ab, value);
    const fence_device = ab.dma_ring.device + fence_at;
    put(ab, OP_FENCE | FENCE_UNCACHED);
    put(ab, @truncate(fence_device));
    put(ab, @truncate(fence_device >> 32));
    put(ab, number);
    put(ab, OP_TRAP);
    put(ab, 0);
    const padding = jobWords(@intCast(packets.len)) - @as(u32, @intCast(packets.len)) - tail_words;
    for (0..padding) |_| put(ab, OP_NOP);
}

/// The engine told of everything written: the write pointer's copy, then
/// its register, after a fence that sends the ring's words on.
pub fn tell(ab: *AMDGPUBase) void {
    fence();
    double(ab, write_copy_at).* = ab.dma_written;
    _graphics.at(ab, RB_WPTR).* = @truncate(ab.dma_written);
    _graphics.at(ab, RB_WPTR_HI).* = @truncate(ab.dma_written >> 32);
}

/// The trap's server: counted, and the queue's waitable signalled.
pub fn trapServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const ab: *AMDGPUBase = @ptrCast(@alignCast(data.?));
    ab.dma_traps +%= 1;
    ab.sys_base.SignalWaitable(&ab.dma_trap);
    return 1;
}

// --- tests --------------------------------------------------------------------------------

const testing = @import("std").testing;

test "a job's words with its fence, its trap and the padding" {
    try testing.expectEqual(@as(u32, 16), jobWords(0));
    try testing.expectEqual(@as(u32, 16), jobWords(10));
    try testing.expectEqual(@as(u32, 32), jobWords(11));
    try testing.expectEqual(@as(u32, 16), jobWords(5));
}

test "job numbers compared past their wrap" {
    try testing.expect(passed(1, 1));
    try testing.expect(passed(2, 1));
    try testing.expect(!passed(0, 1));
    try testing.expect(!passed(1, 2));
    try testing.expect(passed(3, 0xffff_fffe));
    try testing.expect(!passed(0xffff_fffe, 3));
    try testing.expectEqual(@as(u32, 2), nextJob(1));
    try testing.expectEqual(@as(u32, 1), nextJob(0xffff_ffff));
}

test "the jobs a reset of the block gave up, past the wrap" {
    // None before any reset.
    try testing.expect(!lost(0, 0, 1));
    try testing.expect(!lost(0, 0, 0x8000_0001));
    // Jobs 6 to 9 given up: 5 was done, 10 is sent after.
    try testing.expect(!lost(5, 9, 5));
    try testing.expect(lost(5, 9, 6));
    try testing.expect(lost(5, 9, 9));
    try testing.expect(!lost(5, 9, 10));
    // Across the wrap: 0xffff_fffe done, up to 2 given up.
    try testing.expect(lost(0xffff_fffe, 2, 0xffff_ffff));
    try testing.expect(lost(0xffff_fffe, 2, 1));
    try testing.expect(!lost(0xffff_fffe, 2, 3));
    // Forgotten a quarter of the round on, past the wrap too.
    try testing.expect(!longPast(9, 10));
    try testing.expect(!longPast(9, 8 + (1 << 30)));
    try testing.expect(longPast(9, 9 + (1 << 30)));
    try testing.expect(longPast(0xffff_fff0, 0x3fff_fff0));
    try testing.expect(!longPast(0xffff_fff0, 5));
}

test "the cache rinse, as the vendor's driver writes it" {
    // sdma_v6_0_ring_emit_mem_sync: GL2_INV | GL2_WB | GLM_INV | GL1_INV |
    // GLV_INV | GLK_INV | GLI_INV(1) = 0xc3a1.
    try testing.expectEqual(@as(u32, 0xc3a1), rinse_control);
    try testing.expectEqualSlices(u32, &.{ 17, 0, 0xc3a1_0000, 0, 0 }, &rinse());
    try testing.expectEqual(@as(u32, 16), jobWords(rinse().len));
}

test "what the engine has yet to read, its read pointer counted either way" {
    try testing.expectEqual(@as(u32, 0), pending(0, 0));
    try testing.expectEqual(@as(u32, 64), pending(64, 0));
    try testing.expectEqual(@as(u32, 64), pending(ring_bytes + 64, ring_bytes));
    try testing.expectEqual(@as(u32, 64), pending(ring_bytes + 64, 0));
    try testing.expectEqual(@as(u32, 128), pending(ring_bytes + 64, ring_bytes - 64));
}
