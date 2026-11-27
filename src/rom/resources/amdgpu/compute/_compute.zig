// SPDX-License-Identifier: MPL-2.0
//! The graphics block's compute engine: its scheduler's two pipes, the
//! queue of jobs the system runs on the engine, and the jobs and kernels
//! put on that queue.
//!
//! **The scheduler** is firmware on two pipes of the block's command
//! processor (its third micro engine): the first pipe schedules queues,
//! the second - the mapper - maps them for it. The security processor
//! gave both their code (StartGPUGraphics); StartGPUCompute starts them as
//! the vendor's driver does (mes_v11_0_kiq_hw_init, mes_v11_0_hw_init):
//! both pipes reset, each pointed at its first instruction as its file's
//! header names it, and let run; the mapper's own queue set through its
//! registers; the scheduler's queue mapped by the mapper (MAP_QUEUES); and
//! the scheduler told the block's resources and asked how it is. A call of
//! the scheduler is a frame of 64 words on its queue whose status word it
//! is to write, followed by a frame that asks its status and writes the
//! queue's fence with the call's number: the call is done once the fence
//! has the number and the status word is not 0.
//!
//! **The queue** is the compute engine's first queue (micro engine 1, pipe
//! 0, queue 0), mapped by the scheduler as one of the system's own
//! (ADD_QUEUE with map_legacy_kq), as the vendor's driver maps its kernel
//! compute queues once the scheduler runs (amdgpu_gfx_mes_enable_kcq):
//! the mapper told first which queues are the system's (SET_RESOURCES).
//!
//! **A ring.** Each of the three queues is a ring of words in one piece of
//! the device's memory, beside the description the command processor
//! keeps of the queue (its MQD), the buffer it keeps the ends of jobs in
//! (EOP) and a page it writes back how far it has read to, in words within
//! the ring. An engine is told of new words through the queue's doorbell:
//! a 64-bit write of how many words have been written since the queue
//! started, into the queue's word of the device's doorbell window, after
//! a fence that sends the ring's words - written write-combining - on.
//! What is written is padded to the ring's fetch first: 256 words on the
//! compute engine's queues, 2 on the scheduler's.
//!
//! **A job** on the queue makes the engine's caches see memory as the CPU
//! left it (ACQUIRE_MEM), then holds the caller's packets, then its end
//! (RELEASE_MEM): the caches written back, the job's number written into
//! the page, and the engine's end-of-pipe interrupt raised, which the
//! queue's server counts and signals the queue's waitable with. Numbers
//! start at 1, wrap past 0 and are compared modulo 2^32.
//!
//! **A reset.** Each job's start in the ring and how many of its words
//! are its own packets are kept, at its number's place among 64; a job's
//! words stay in the ring until it is done, so that a reset can write
//! them again. The engine runs a job's kernels while it goes on to the
//! next jobs, and a job's end waits for every job before it: a reset of
//! the queue's waves ends every kernel still running, and the ends of the
//! jobs they belong to come as the queue stops, done or not. So
//! ResetGPUCompute gives up the first job not done and every job whose
//! end comes as the queue stops, and writes the jobs after them again
//! from the ring's start - where no end came, the first one's own packets
//! made NOPs, so that its end, its number, comes in order
//! (amdgpu_ring_set_fence_errors_and_reemit).
//!
//! **A kernel's dispatch** is a job of packets that set the compute
//! engine's registers - where the code is, its resource words, the
//! group's size, where its arguments are - and dispatch its groups
//! (DISPATCH_DIRECT), as Mesa's Vulkan driver dispatches one (RADV). The
//! arguments are copied into one of 64 slots of 256 bytes of the piece,
//! taken in turn; a slot is taken again only once the job that last took
//! it is done.
//!
//! **Scratch.** A kernel's private memory is the queue's scratch, as the
//! vendor's Vulkan driver gives a compute queue its own on this block
//! (radv_emit_compute_scratch): a piece of the device's memory, its
//! address set before each dispatch (COMPUTE_DISPATCH_SCRATCH_BASE) with
//! how many waves it holds for each shader engine and how much each has,
//! in 256 bytes (COMPUTE_TMPRING_SIZE, ac_get_scratch_tmpring_size). A
//! wave has its lanes' private bytes on 256 bytes and 256 more, which
//! makes its count odd and spreads the waves over the memory's channels
//! (ac_compute_scratch_wavesize); the piece holds 32 waves for each
//! compute unit (RADV's scratch_waves), and at least a group's worth for
//! each engine, as a group whose waves cannot all have scratch never
//! starts. The block points each wave's scratch at its own part itself,
//! so a kernel takes no register for it. A wave's size stays as it is
//! while a dispatch may still use the piece, which is why a kernel that
//! needs more waits for the queue to be idle before the piece is made
//! again.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const amdgpu_base = @import("../amdgpu_base.zig");
const AMDGPUBase = amdgpu_base.AMDGPUBase;
const _graphics = @import("../graphics/_graphics.zig");
const _dma = @import("../dma/_dma.zig");
const Register = _graphics.Register;

pub const fence = _dma.fence;
pub const passed = _dma.passed;

// The block's registers the start sets, counted from its first address or
// from its second.
pub const GRBM_GFX_CNTL: Register = .{ .segment = 1, .offset = 0x0900 };
pub const RLC_CP_SCHEDULERS: Register = .{ .segment = 1, .offset = 0x098a };
pub const SH_MEM_CONFIG: Register = .{ .segment = 1, .offset = 0x09e4 };
pub const CP_MEC_CNTL: Register = .{ .segment = 1, .offset = 0x0802 };
pub const CP_ME_CNTL: Register = .{ .segment = 1, .offset = 0x0803 };
pub const CP_MES_CNTL: Register = .{ .segment = 1, .offset = 0x2807 };
pub const CP_MES_PRGRM_CNTR_START: Register = .{ .segment = 1, .offset = 0x2800 };
pub const CP_MES_PRGRM_CNTR_START_HI: Register = .{ .segment = 1, .offset = 0x289d };
pub const CP_MES_GP3_LO: Register = .{ .segment = 1, .offset = 0x2849 };
pub const CP_MES_INSTR_PNTR: Register = .{ .segment = 1, .offset = 0x2813 };
pub const SCRATCH_REG0: Register = .{ .segment = 1, .offset = 0x2040 };
pub const CP_RB_DOORBELL_RANGE_LOWER: Register = .{ .segment = 0, .offset = 0x1dfa };
pub const CP_RB_DOORBELL_RANGE_UPPER: Register = .{ .segment = 0, .offset = 0x1dfb };
pub const CP_MEC_DOORBELL_RANGE_LOWER: Register = .{ .segment = 0, .offset = 0x1dfc };
pub const CP_MEC_DOORBELL_RANGE_UPPER: Register = .{ .segment = 0, .offset = 0x1dfd };
pub const CP_ME1_PIPE0_INT_CNTL: Register = .{ .segment = 0, .offset = 0x1e25 };
pub const GRBM_STATUS: Register = .{ .segment = 0, .offset = 0x0da4 };
pub const CP_CPC_STATUS: Register = .{ .segment = 0, .offset = 0x0e24 };
pub const CP_MEC1_INSTR_PNTR: Register = .{ .segment = 0, .offset = 0x0f48 };
pub const CP_STAT = _graphics.CP_STAT;
// A queue's own registers: those of the queue GRBM_GFX_CNTL selects.
pub const CP_MQD_BASE_ADDR: Register = .{ .segment = 0, .offset = 0x1fa9 };
pub const CP_MQD_BASE_ADDR_HI: Register = .{ .segment = 0, .offset = 0x1faa };
pub const CP_HQD_ACTIVE: Register = .{ .segment = 0, .offset = 0x1fab };
pub const CP_HQD_DEQUEUE_REQUEST: Register = .{ .segment = 0, .offset = 0x1fc1 };
pub const SPI_COMPUTE_QUEUE_RESET: Register = .{ .segment = 0, .offset = 0x1f73 };
pub const CP_HQD_VMID: Register = .{ .segment = 0, .offset = 0x1fac };
pub const CP_HQD_PERSISTENT_STATE: Register = .{ .segment = 0, .offset = 0x1fad };
pub const CP_HQD_PQ_BASE: Register = .{ .segment = 0, .offset = 0x1fb1 };
pub const CP_HQD_PQ_BASE_HI: Register = .{ .segment = 0, .offset = 0x1fb2 };
pub const CP_HQD_PQ_RPTR: Register = .{ .segment = 0, .offset = 0x1fb3 };
pub const CP_HQD_PQ_RPTR_REPORT_ADDR: Register = .{ .segment = 0, .offset = 0x1fb4 };
pub const CP_HQD_PQ_RPTR_REPORT_ADDR_HI: Register = .{ .segment = 0, .offset = 0x1fb5 };
pub const CP_HQD_PQ_WPTR_POLL_ADDR: Register = .{ .segment = 0, .offset = 0x1fb6 };
pub const CP_HQD_PQ_WPTR_POLL_ADDR_HI: Register = .{ .segment = 0, .offset = 0x1fb7 };
pub const CP_HQD_PQ_DOORBELL_CONTROL: Register = .{ .segment = 0, .offset = 0x1fb8 };
pub const CP_HQD_PQ_CONTROL: Register = .{ .segment = 0, .offset = 0x1fba };
pub const CP_MQD_CONTROL: Register = .{ .segment = 0, .offset = 0x1fcb };
pub const CP_HQD_PQ_WPTR_LO: Register = .{ .segment = 0, .offset = 0x1fdf };
pub const CP_HQD_PQ_WPTR_HI: Register = .{ .segment = 0, .offset = 0x1fe0 };
// The engine's registers a dispatch sets, counted from the first address.
pub const COMPUTE_NUM_THREAD_X: u32 = 0x1ba7;
pub const COMPUTE_PGM_LO: u32 = 0x1bac;
pub const COMPUTE_PGM_RSRC1: u32 = 0x1bb2;
pub const COMPUTE_DISPATCH_SCRATCH_BASE_LO: u32 = 0x1bb0;
pub const COMPUTE_RESOURCE_LIMITS: u32 = 0x1bb5;
pub const COMPUTE_TMPRING_SIZE: u32 = 0x1bb8;
pub const COMPUTE_PGM_RSRC3: u32 = 0x1bc8;
pub const COMPUTE_USER_DATA_0: u32 = 0x1be0;

// Their fields.
pub const MEC_ME1_HALT: u32 = 1 << 30;
pub const MEC_ME2_HALT: u32 = 1 << 28;
pub const ME_HALT: u32 = 1 << 28;
pub const PFP_HALT: u32 = 1 << 26;
pub const MES_PIPE0_RESET: u32 = 1 << 16;
pub const MES_PIPE1_RESET: u32 = 1 << 17;
pub const MES_PIPE0_ACTIVE: u32 = 1 << 26;
pub const MES_PIPE1_ACTIVE: u32 = 1 << 27;
pub const MES_INVALIDATE_ICACHE: u32 = 1 << 4;
pub const MES_HALT: u32 = 1 << 30;
pub const TIME_STAMP_INT_ENABLE: u32 = 1 << 26;
pub const GENERIC0_INT_ENABLE: u32 = 1 << 31;
pub const HQD_VMID_MASK: u32 = 0xf;
/// A queue's dequeue asked with its waves let finish and no group of its
/// dispatches started any more, or with its waves reset
/// (hqd_dequeue_request_type's DRAIN_PIPE and RESET_WAVES); the shader
/// input's state of the queue reset; the queue active; the compute
/// engine's first micro engine's pipe 0 held in reset - the next pipes'
/// bits follow it.
pub const DEQUEUE_DRAIN_PIPE: u32 = 1;
pub const DEQUEUE_RESET_WAVES: u32 = 2;
pub const QUEUE_RESET: u32 = 1 << 0;
pub const HQD_ACTIVE: u32 = 1 << 0;
pub const MEC_ME1_PIPE0_RESET: u32 = 1 << 16;
/// The queues on each of the compute engine's pipes.
pub const queues_per_pipe = 8;
pub const DOORBELL_EN: u32 = 1 << 30;
pub const DOORBELL_OFFSET_SHIFT = 2;
const QUEUE_SIZE_MASK: u32 = 0x3f;
const RPTR_BLOCK_SIZE_SHIFT = 8;
const RPTR_BLOCK_SIZE_MASK: u32 = 0x3f << RPTR_BLOCK_SIZE_SHIFT;
const NO_UPDATE_RPTR: u32 = 1 << 27;
const UNORD_DISPATCH: u32 = 1 << 28;
const PRIV_STATE: u32 = 1 << 30;
const KMD_QUEUE: u32 = 1 << 31;
const QUANTUM_EN: u32 = 1 << 0;
const QUANTUM_SCALE_SHIFT = 4;
const QUANTUM_DURATION_SHIFT = 8;
const EOP_SIZE_MASK: u32 = 0x3f;
// A dispatch's fields.
const RSRC2_SCRATCH_EN: u32 = 1 << 0;
const RSRC2_USER_SGPR_SHIFT = 1;
const RSRC2_USER_SGPR_MASK: u32 = 0x1f << RSRC2_USER_SGPR_SHIFT;
const RSRC2_TRAP_PRESENT: u32 = 1 << 6;
const RSRC2_LDS_SIZE_SHIFT = 15;
const RSRC2_LDS_SIZE_MASK: u32 = 0x1ff << RSRC2_LDS_SIZE_SHIFT;
const TMPRING_WAVES_MASK: u32 = 0xfff;
const TMPRING_WAVESIZE_SHIFT = 12;
const TMPRING_WAVESIZE_MASK: u32 = 0x7fff << TMPRING_WAVESIZE_SHIFT;
/// In a kernel's descriptor's properties, that its stack grows as it
/// runs, past the private bytes it gives (USES_DYNAMIC_STACK).
const COMPUTE_SHADER_EN: u32 = 1 << 0;
const FORCE_START_AT_000: u32 = 1 << 2;
const ORDER_MODE: u32 = 1 << 6;
const CS_W32_EN: u32 = 1 << 15;

/// The defaults of a queue's registers, as the vendor's header has them,
/// which a description starts from.
const EOP_CONTROL_DEFAULT: u32 = 0x0000_0006;
const MQD_CONTROL_DEFAULT: u32 = 0x0000_0100;
const PQ_CONTROL_DEFAULT: u32 = 0x0030_8509;
const PERSISTENT_STATE_DEFAULT: u32 = 0x0be0_5501;
const IB_CONTROL_DEFAULT: u32 = 0x0030_0000;
/// The persistent state's preload size and the least room in an indirect
/// buffer, as the vendor's driver sets them: the defaults' own values.
const PRELOAD_SIZE: u32 = 0x55;
const PRELOAD_SIZE_SHIFT = 8;
const PRELOAD_SIZE_MASK: u32 = 0x3ff << PRELOAD_SIZE_SHIFT;
const MIN_IB_AVAIL_SIZE: u32 = 3;
const MIN_IB_AVAIL_SIZE_SHIFT = 20;
const MIN_IB_AVAIL_SIZE_MASK: u32 = 3 << MIN_IB_AVAIL_SIZE_SHIFT;

/// Memory as the system context's shaders address it: 64-bit addresses,
/// unaligned accesses allowed and three lines of code fetched ahead
/// (DEFAULT_SH_MEM_CONFIG).
pub const SH_MEM_CONFIG_DEFAULT: u32 = 3 << 2 | 3 << 14;

/// The bus block's doorbell window and the window the device's own
/// engines ring doorbells through, counted from its third address.
pub const bus_segment = 2;
pub const RCC_DOORBELL_APER_EN: u32 = 0x00c0;
pub const BIF_DOORBELL_APER_EN: u32 = 1 << 0;
pub const SELFRING_GPA_APER_BASE_HIGH: u32 = 0x00f3;
pub const SELFRING_GPA_APER_BASE_LOW: u32 = 0x00f4;
pub const SELFRING_GPA_APER_CNTL: u32 = 0x00f5;
pub const SELFRING_APER_EN: u32 = 1 << 0;
pub const SELFRING_APER_MODE: u32 = 1 << 1;

/// The end-of-pipe interrupt: its client, the command processor, and its
/// source.
pub const INTERRUPT_CLIENT: u32 = 0x14;
pub const END_SOURCE: u32 = 181;

/// A queue's place in the command processor - its micro engine, pipe and
/// queue - as GRBM_GFX_CNTL selects it.
pub const Queue = struct { me: u32, pipe: u32, queue: u32 };
pub const no_queue: Queue = .{ .me = 0, .pipe = 0, .queue = 0 };
pub const scheduler_queue: Queue = .{ .me = 3, .pipe = 0, .queue = 0 };
pub const mapper_queue: Queue = .{ .me = 3, .pipe = 1, .queue = 0 };
pub const compute_queue: Queue = .{ .me = 1, .pipe = 0, .queue = 0 };

/// The queues' doorbells, in words of the window, as the vendor's driver
/// numbers them: the compute engine's first ring, the scheduler's and the
/// mapper's.
pub const compute_doorbell: u32 = 6;
pub const scheduler_doorbell: u32 = 0x16;
pub const mapper_doorbell: u32 = 0x18;
/// The doorbells each engine answers to, in bytes of the window: the
/// graphics engine's rings', and the compute engine's and the
/// scheduler's.
pub const rb_doorbells_lower: u32 = 0x458;
pub const rb_doorbells_upper: u32 = 0x7f8;
pub const mec_doorbells_lower: u32 = 0;
pub const mec_doorbells_upper: u32 = 0x450;
/// The scheduler's own doorbells, one for each priority, from this word.
pub const aggregated_doorbells: u32 = 0x800;
pub const priority_levels = 5;
/// The doorbell window's least size: the scheduler's doorbells are after
/// its first two pages.
pub const doorbells_least: u64 = (aggregated_doorbells + 2 * priority_levels) * 4;

/// The piece: the three rings, their descriptions, their end-of-pipe
/// buffers, the page the engines write back to, the page the scheduler is
/// handed for the fence of its cleaner, and the slots of arguments.
pub const compute_ring_at: u32 = 0;
pub const compute_ring_bytes: u32 = 64 * 1024;
pub const scheduler_ring_at: u32 = 0x10000;
pub const scheduler_ring_bytes: u32 = 16 * 1024;
pub const mapper_ring_at: u32 = 0x14000;
pub const mapper_ring_bytes: u32 = 8 * 1024;
pub const scheduler_mqd_at: u32 = 0x16000;
pub const mapper_mqd_at: u32 = 0x17000;
pub const compute_mqd_at: u32 = 0x18000;
pub const scheduler_eop_at: u32 = 0x19000;
pub const mapper_eop_at: u32 = 0x1a000;
pub const compute_eop_at: u32 = 0x1b000;
pub const page_at: u32 = 0x1c000;
pub const mapper_read_at: u32 = page_at + 0x00;
pub const mapper_write_at: u32 = page_at + 0x08;
pub const scheduler_read_at: u32 = page_at + 0x10;
pub const scheduler_write_at: u32 = page_at + 0x18;
pub const scheduler_fence_at: u32 = page_at + 0x20;
pub const scheduler_status_at: u32 = page_at + 0x28;
pub const scheduler_context_at: u32 = page_at + 0x40;
pub const scheduler_query_at: u32 = page_at + 0x60;
pub const compute_read_at: u32 = page_at + 0x80;
pub const compute_write_at: u32 = page_at + 0x88;
pub const compute_fence_at: u32 = page_at + 0x90;
pub const cleaner_at: u32 = 0x1d000;
pub const slots_at: u32 = 0x1e000;
pub const slot_bytes: u32 = amdgpu.GPUKERNEL_ARGUMENTS_MAX;
pub const piece_bytes: u32 = slots_at + amdgpu_base.compute_slots * slot_bytes;
pub const compute_ring_words: u32 = compute_ring_bytes / 4;
/// A queue's description, and the end-of-pipe buffer the command
/// processor is given: 2048 bytes, its size code 8 - a buffer of
/// 2^(8+1) words.
pub const mqd_words = 512;
pub const eop_bytes: u32 = 2048;
const eop_size_code: u32 = 8;
comptime {
    if (@as(u32, 1) << (eop_size_code + 1) != eop_bytes / 4) @compileError("the end-of-pipe buffer's size code does not match its bytes");
    if (mqd_words * 4 > mapper_mqd_at - scheduler_mqd_at) @compileError("a queue's description does not fit in its place");
    if (eop_bytes > mapper_eop_at - scheduler_eop_at) @compileError("an end-of-pipe buffer does not fit in its place");
    if (compute_ring_at + compute_ring_bytes > scheduler_ring_at or scheduler_ring_at + scheduler_ring_bytes > mapper_ring_at or
        mapper_ring_at + mapper_ring_bytes > scheduler_mqd_at) @compileError("the rings overlap");
}

/// How long the start waits for a ring's test and the engines to go idle
/// - the vendor's 100 ms - and for a call of the scheduler - its 2.1 s -
/// and how long a job waits for room in the ring at most.
pub const test_most_us: u64 = 100_000;
/// How long a reset waits for the queue to be inactive: the vendor's
/// 100 ms; and as long, first, for its waves to finish as it is drained.
pub const dequeue_most_us: u64 = 100_000;
pub const drain_most_us: u64 = 100_000;
pub const scheduler_most_us: u64 = 2_100_000;
pub const room_most_us: u64 = 1_000_000;

/// The oldest scheduler firmware that maps the system's own queues, and
/// the oldest that takes the second call of resources.
pub const scheduler_maps_from: u32 = 0x47;
pub const scheduler_resources_1_from: u32 = 0x52;
/// The oldest scheduler firmware that is told a queue is removed after
/// its reset.
pub const scheduler_removes_after_reset_from: u32 = 0x60;
pub const scheduler_version_mask: u32 = 0xfff;

// --- the piece and the registers ----------------------------------------------------------

/// The word at byte `at` of the piece, as the CPU reaches it.
pub fn word(ab: *AMDGPUBase, at: u32) *volatile u32 {
    return @ptrFromInt(@as(usize, @intCast(ab.compute.cpu)) + at);
}

pub fn double(ab: *AMDGPUBase, at: u32) *volatile u64 {
    return @ptrFromInt(@as(usize, @intCast(ab.compute.cpu)) + at);
}

/// The words from byte `at` of the piece.
pub fn words(ab: *AMDGPUBase, at: u32) [*]volatile u32 {
    return @ptrFromInt(@as(usize, @intCast(ab.compute.cpu)) + at);
}

/// The register `offset` of the bus block `bus`, counted from its third
/// address.
pub fn busAt(ab: *AMDGPUBase, bus: *const amdgpu.GPUBlock, offset: u32) *volatile u32 {
    return reg(@as(usize, @intCast(ab.info.registers)) + (@as(usize, bus.addresses[bus_segment]) + offset) * 4);
}

/// The queue whose registers the block's queue registers are from then
/// on, and the context its shader registers are those of.
pub fn select(ab: *AMDGPUBase, queue: Queue, vmid: u32) void {
    _graphics.at(ab, GRBM_GFX_CNTL).* = queue.pipe | queue.me << 2 | vmid << 4 | queue.queue << 8;
}

/// A wait of so many microseconds, at the least.
pub fn pause(ab: *AMDGPUBase, us: u32) void {
    var never: exec.Waitable = .{};
    const list = [_]*exec.Waitable{&never};
    _ = ab.sys_base.WaitForAny(&list, 1, us);
}

// --- a queue's description ----------------------------------------------------------------

/// Words of a description (v11_compute_mqd).
const MQD = struct {
    const header = 0;
    const pipelinestat_enable = 11;
    const static_thread_mgmt = [_]usize{ 23, 24, 26, 27 };
    const misc_reserved = 32;
    const base_lo = 128;
    const base_hi = 129;
    const active = 130;
    const vmid = 131;
    const persistent_state = 132;
    const pipe_priority = 133;
    const queue_priority = 134;
    const quantum = 135;
    const pq_base_lo = 136;
    const pq_base_hi = 137;
    const pq_rptr = 138;
    const rptr_report_lo = 139;
    const rptr_report_hi = 140;
    const wptr_poll_lo = 141;
    const wptr_poll_hi = 142;
    const doorbell_control = 143;
    const pq_control = 145;
    const ib_control = 149;
    const iq_timer = 150;
    const dequeue_request = 152;
    const mqd_control = 162;
    const eop_base_lo = 165;
    const eop_base_hi = 166;
    const eop_control = 167;
    const pq_wptr_lo = 182;
    const pq_wptr_hi = 183;
};

/// What a queue's description names: whose it is - the scheduler's pipes'
/// (mes_v11_0_mqd_init) or the compute engine's (gfx_v11_0_compute_mqd_init)
/// - and its own address, its ring's and size, its end-of-pipe buffer's,
/// the words its read pointer is written back to and its write pointer
/// copied into, and its doorbell.
pub const Description = struct {
    kind: enum { scheduler, compute },
    mqd: u64,
    ring: u64,
    ring_bytes: u32,
    eop: u64,
    read_back: u64,
    write_copy: u64,
    doorbell: u32,
};

/// A field of `mask` set to `value` shifted into place, as the vendor's
/// REG_SET_FIELD sets one: what falls outside the mask is lost.
fn field(word_value: u32, mask: u32, shift: u5, value: u32) u32 {
    return (word_value & ~mask) | ((value << shift) & mask);
}

/// The queue's control word (CP_HQD_PQ_CONTROL): its size, the block its
/// read pointer is written back after, dispatches out of order, the
/// queue privileged and the system's own; the scheduler's pipes'
/// without their read pointer updated by the engine. The vendor's driver
/// hands the scheduler's the block size already shifted into place, which
/// the field then drops: its block size is 0.
pub fn pqControl(kind: @FieldType(Description, "kind"), ring_bytes: u32) u32 {
    const queue_size: u32 = @ctz(ring_bytes / 4) - 1;
    const page_words_code: u32 = @ctz(@as(u32, 4096 / 4)) - 1;
    var control = field(PQ_CONTROL_DEFAULT, QUEUE_SIZE_MASK, 0, queue_size);
    const block = if (kind == .scheduler) page_words_code << 8 else page_words_code;
    control = field(control, RPTR_BLOCK_SIZE_MASK, RPTR_BLOCK_SIZE_SHIFT, block);
    control |= UNORD_DISPATCH | PRIV_STATE | KMD_QUEUE;
    if (kind == .scheduler) control |= NO_UPDATE_RPTR;
    return control;
}

/// The description `description` written into `into` - 512 words, the
/// device's memory or an array - as the vendor's driver fills it: every
/// word not named 0.
pub fn describe(into: anytype, description: Description) void {
    for (0..mqd_words) |index| into[index] = 0;
    into[MQD.header] = 0xC031_0800;
    into[MQD.pipelinestat_enable] = 1;
    for (MQD.static_thread_mgmt) |index| into[index] = 0xffff_ffff;
    into[MQD.misc_reserved] = 7;
    const eop = description.eop >> 8;
    into[MQD.eop_base_lo] = @truncate(eop);
    into[MQD.eop_base_hi] = @truncate(eop >> 32);
    into[MQD.eop_control] = field(EOP_CONTROL_DEFAULT, EOP_SIZE_MASK, 0, eop_size_code);
    into[MQD.base_lo] = @as(u32, @truncate(description.mqd)) & 0xffff_fffc;
    into[MQD.base_hi] = @truncate(description.mqd >> 32);
    into[MQD.mqd_control] = MQD_CONTROL_DEFAULT;
    const ring = description.ring >> 8;
    into[MQD.pq_base_lo] = @truncate(ring);
    into[MQD.pq_base_hi] = @truncate(ring >> 32);
    into[MQD.rptr_report_lo] = @as(u32, @truncate(description.read_back)) & 0xffff_fffc;
    into[MQD.rptr_report_hi] = @as(u32, @truncate(description.read_back >> 32)) & 0xffff;
    const poll_mask: u32 = if (description.kind == .scheduler) 0xffff_fff8 else 0xffff_fffc;
    into[MQD.wptr_poll_lo] = @as(u32, @truncate(description.write_copy)) & poll_mask;
    into[MQD.wptr_poll_hi] = @as(u32, @truncate(description.write_copy >> 32)) & 0xffff;
    into[MQD.pq_control] = pqControl(description.kind, description.ring_bytes);
    into[MQD.doorbell_control] = description.doorbell << DOORBELL_OFFSET_SHIFT | DOORBELL_EN;
    into[MQD.persistent_state] = field(PERSISTENT_STATE_DEFAULT, PRELOAD_SIZE_MASK, PRELOAD_SIZE_SHIFT, PRELOAD_SIZE);
    into[MQD.ib_control] = field(IB_CONTROL_DEFAULT, MIN_IB_AVAIL_SIZE_MASK, MIN_IB_AVAIL_SIZE_SHIFT, MIN_IB_AVAIL_SIZE);
    switch (description.kind) {
        // Set going by its registers: active from the start.
        .scheduler => into[MQD.active] = 1,
        // Mapped by the scheduler, at the default priorities.
        .compute => into[MQD.quantum] = QUANTUM_EN | 1 << QUANTUM_SCALE_SHIFT | 1 << QUANTUM_DURATION_SHIFT,
    }
}

/// The queue the block's queue registers select set from its description
/// `mqd`, as the vendor's driver sets the mapper's own
/// (mes_v11_0_queue_init_register): the description's control word written
/// 0, as the vendor's driver writes it.
pub fn setQueue(ab: *AMDGPUBase, mqd: [*]volatile u32) void {
    const at = _graphics.at;
    at(ab, CP_HQD_VMID).* = at(ab, CP_HQD_VMID).* & ~HQD_VMID_MASK;
    at(ab, CP_HQD_PQ_DOORBELL_CONTROL).* = at(ab, CP_HQD_PQ_DOORBELL_CONTROL).* & ~DOORBELL_EN;
    at(ab, CP_MQD_BASE_ADDR).* = mqd[MQD.base_lo];
    at(ab, CP_MQD_BASE_ADDR_HI).* = mqd[MQD.base_hi];
    at(ab, CP_MQD_CONTROL).* = 0;
    at(ab, CP_HQD_PQ_BASE).* = mqd[MQD.pq_base_lo];
    at(ab, CP_HQD_PQ_BASE_HI).* = mqd[MQD.pq_base_hi];
    at(ab, CP_HQD_PQ_RPTR_REPORT_ADDR).* = mqd[MQD.rptr_report_lo];
    at(ab, CP_HQD_PQ_RPTR_REPORT_ADDR_HI).* = mqd[MQD.rptr_report_hi];
    at(ab, CP_HQD_PQ_CONTROL).* = mqd[MQD.pq_control];
    at(ab, CP_HQD_PQ_WPTR_POLL_ADDR).* = mqd[MQD.wptr_poll_lo];
    at(ab, CP_HQD_PQ_WPTR_POLL_ADDR_HI).* = mqd[MQD.wptr_poll_hi];
    at(ab, CP_HQD_PQ_DOORBELL_CONTROL).* = mqd[MQD.doorbell_control];
    at(ab, CP_HQD_PERSISTENT_STATE).* = mqd[MQD.persistent_state];
    at(ab, CP_HQD_ACTIVE).* = mqd[MQD.active];
}

// --- the command processor's packets ------------------------------------------------------

const OP_DISPATCH_DIRECT: u32 = 0x15;
const OP_WRITE_DATA: u32 = amdgpu.GPUPACKET_WRITE_DATA;
const OP_RELEASE_MEM: u32 = 0x49;
const OP_ACQUIRE_MEM: u32 = 0x58;
const OP_SET_SH_REG: u32 = 0x76;
const OP_SET_UCONFIG_REG: u32 = 0x79;
const OP_SET_RESOURCES: u32 = 0xa0;
const OP_MAP_QUEUES: u32 = 0xa2;
/// A packet for the compute engine's shaders.
const SHADER_COMPUTE: u32 = 1 << 1;
/// The first registers the two register-setting packets count from.
const sh_registers_first: u32 = 0x2c00;
const uconfig_registers_first: u32 = 0xc000;

/// A packet's header: its operation and the words after it.
pub fn packet(op: u32, after: u32) u32 {
    return amdgpu.GPUPACKET | op << amdgpu.GPUPACKET_OP_SHIFT | (after - 1) << amdgpu.GPUPACKET_COUNT_SHIFT;
}

/// A NOP of one word - its count the one that means none.
pub const nop: u32 = amdgpu.GPUPACKET | amdgpu.GPUPACKET_NOP << amdgpu.GPUPACKET_OP_SHIFT | 0x3fff << amdgpu.GPUPACKET_COUNT_SHIFT;

/// The caches made to see memory as the CPU left it before a job
/// (gfx_v11_0_emit_mem_sync): the second level written back and dropped,
/// the first level, the vector, scalar and instruction caches dropped.
pub const acquire = [_]u32{
    packet(OP_ACQUIRE_MEM, 7),                                               0, 0xffff_ffff, 0x00ff_ffff, 0, 0, 0x0a,
    1 << 0 | 1 << 4 | 1 << 5 | 1 << 7 | 1 << 8 | 1 << 9 | 1 << 14 | 1 << 15,
};

/// A job's end (gfx_v11_0_ring_emit_fence): once the job's work is done,
/// the caches written back, the 32-bit `value` written at `fence` and the
/// end-of-pipe interrupt raised once the write is confirmed.
pub fn release(fence_at: u64, value: u32) [8]u32 {
    const event_flush_and_invalidate: u32 = 0x14;
    return .{
        packet(OP_RELEASE_MEM, 7),
        1 << 22 | 1 << 21 | 1 << 13 | 1 << 12 | 3 << 25 | event_flush_and_invalidate | 5 << 8,
        1 << 29 | 2 << 24,
        @truncate(fence_at),
        @truncate(fence_at >> 32),
        value,
        0,
        0,
    };
}

/// The mapper told which of the compute engine's queues are the system's
/// (gfx11_kiq_set_resources): `mask`, a bit for each, and its unmapping
/// latency the vendor's.
pub fn setResources(mask: u64) [8]u32 {
    return .{ packet(OP_SET_RESOURCES, 7), 0xa << 16, @truncate(mask), @truncate(mask >> 32), 0, 0, 0, 0 };
}

/// The mapper told to map the scheduler's queue (gfx11_kiq_map_queues): its
/// place, as the packet numbers the scheduler's engine, its doorbell, its
/// description and its write pointer's copy.
pub fn mapScheduler(mqd: u64, write_copy: u64) [7]u32 {
    const scheduler_me: u32 = 2;
    const scheduler_engine: u32 = 5;
    return .{
        packet(OP_MAP_QUEUES, 6),
        scheduler_queue.queue << 13 | scheduler_queue.pipe << 16 | scheduler_me << 18 | scheduler_engine << 26 | 1 << 29,
        scheduler_doorbell << 2,
        @truncate(mqd),
        @truncate(mqd >> 32),
        @truncate(write_copy),
        @truncate(write_copy >> 32),
    };
}

/// A register written by the mapper (gfx_v11_0_ring_emit_wreg): `register`
/// its number from the start of the device's registers.
pub fn writeRegister(register: u32, value: u32) [5]u32 {
    return .{ packet(OP_WRITE_DATA, 4), 1 << 16, register, 0, value };
}

/// A configuration register set by a queue: `register` its number from
/// the start of the device's registers.
pub fn setConfig(register: u32, value: u32) [3]u32 {
    return .{ packet(OP_SET_UCONFIG_REG, 2), register - uconfig_registers_first, value };
}

/// The words of a kernel's dispatch.
pub const dispatch_words = 35;

/// The scratch a dispatch is told of: the piece's address to the device,
/// and the waves it holds for each shader engine with their size as
/// COMPUTE_TMPRING_SIZE has them; all 0 where the queue has none.
pub const Scratch = struct {
    base: u64 = 0,
    tmpring: u32 = 0,

    /// A piece at `base` of `waves` waves of `wave_bytes` each, shared
    /// between `engines` shader engines.
    pub fn of(base: u64, waves: u32, wave_bytes: u32, engines: u32) Scratch {
        const each = @min(waves / @max(engines, 1), TMPRING_WAVES_MASK);
        return .{ .base = base, .tmpring = each | (wave_bytes >> 8 << TMPRING_WAVESIZE_SHIFT & TMPRING_WAVESIZE_MASK) };
    }
};

/// The private bytes a lane of `kernel` is given: its own, or, where its
/// stack grows as it runs, the more of its own and the dispatch's
/// `stack_bytes` - GPUDISPATCH_STACK_BYTES where that is 0 (ROCclr's
/// dispatch: the device's stack size, 1 KiB unless the program sets
/// another, or the kernel's private segment where that is more).
pub fn laneBytes(kernel: *const amdgpu.GPUKernel, stack_bytes: u32) u64 {
    if (kernel.properties & amdgpu.GPUKERNEL_DYNAMIC_STACK == 0) return kernel.private_bytes;
    const stack = if (stack_bytes == 0) amdgpu.GPUDISPATCH_STACK_BYTES else stack_bytes;
    return @max(stack, kernel.private_bytes);
}

/// The bytes a wave of `kernel` keeps in scratch: its lanes' private
/// bytes (`laneBytes`) on 256 bytes, and 256 more where that makes an
/// even count of them (ac_compute_scratch_wavesize); 0 for a kernel with
/// none.
pub fn waveBytes(kernel: *const amdgpu.GPUKernel, stack_bytes: u32) u64 {
    const private = laneBytes(kernel, stack_bytes);
    if (private == 0) return 0;
    const lanes: u64 = if (kernel.properties & amdgpu.GPUKERNEL_WAVE32 != 0) 32 else 64;
    return (private * lanes + 255) & ~@as(u64, 255) | 256;
}

/// The most a wave may keep in scratch, as COMPUTE_TMPRING_SIZE holds it.
pub const wave_bytes_most: u64 = @as(u64, TMPRING_WAVESIZE_MASK >> TMPRING_WAVESIZE_SHIFT) << 8;

/// The waves a queue's scratch holds on a block of `engines` shader
/// engines and `units` compute units: 32 a unit (RADV's scratch_waves),
/// at least the 32 waves of a group of 1024 threads for each engine, a
/// whole number for each engine and no more than the register holds for
/// one.
pub fn scratchWaves(engines: u32, units: u32) u32 {
    const shared = @max(engines, 1);
    const each = @min(@max(32 * units / shared, 32), TMPRING_WAVES_MASK);
    return each * shared;
}

/// The share of the device's memory the queue's own scratch takes at
/// most, a 32nd. The queue keeps its scratch bound, for every wave, so
/// that the kernels after the one it was made for need none made; one
/// that needs more than that share is given a scratch of its own, made
/// for its dispatch and given back once its job is done, so that a kernel
/// with large private memory does not hold that much of the device's
/// memory from then on.
pub const scratch_kept_share = 32;

/// Whether the queue's own scratch, of `wave_bytes` for each of the
/// `waves` it holds, would take more than its share of the device's
/// `memory_bytes`: a dispatch that needs it is given one of its own
/// instead.
pub fn scratchOnce(wave_bytes: u64, waves: u32, memory_bytes: u64) bool {
    return wave_bytes * waves > memory_bytes / scratch_kept_share;
}

/// The groups of a dispatch of `groups` groups of `group_lanes` lanes
/// each that can be on the `engines` shader engines of `units` compute
/// units at once at most, as the vendor's runtime counts them for a
/// scratch made for one dispatch (calc_dispatch_groups): the groups
/// shared out between the engines, a unit past an even share of them
/// each taking a group more a round of the units; at least the smaller of
/// 16 groups and 256 lanes an engine; for every engine.
pub fn dispatchGroups(groups: [3]u32, group_lanes: u64, engines: u32, units: u32) u64 {
    const total = @as(u64, groups[0]) *| groups[1] *| groups[2];
    const shared: u64 = @max(engines, 1);
    const cu_count: u64 = @max(units, 1);
    const uneven = cu_count - cu_count / shared * shared;
    const rounds = total / cu_count;
    const even_groups = total - rounds * uneven;
    var most = (even_groups +| (shared - 1)) / shared +| (if (uneven != 0) rounds else 0);
    if (most < 16 and group_lanes * most < 256) most = @min((256 + group_lanes - 1) / group_lanes, 16);
    return most *| shared;
}

/// The waves a scratch made for one dispatch holds, as the vendor's
/// runtime sizes one (HandleInsufficientScratch): the waves of the groups
/// that can be on the engines at once (dispatchGroups), in waves of 32
/// lanes where `wave32`, at most `all`, every wave the queue's own holds
/// - a whole number for each engine, as both are.
pub fn onceWaves(groups: [3]u32, threads: [3]u32, wave32: bool, engines: u32, units: u32, all: u32) u32 {
    const lanes: u64 = if (wave32) 32 else 64;
    const group_lanes = @as(u64, threads[0]) * threads[1] * threads[2];
    const waves_a_group = (group_lanes + lanes - 1) / lanes;
    return @intCast(@min(dispatchGroups(groups, group_lanes, engines, units) *| waves_a_group, @as(u64, all)));
}

/// The scratch made for one job given back, under the queue's lock, once
/// that job is done or given up: the device's memory it took is free
/// again.
pub fn giveBackOnce(ab: *AMDGPUBase) void {
    if (ab.scratch_once.bytes == 0 or ab.scratch_once_job == 0) return;
    if (!passed(done(ab), ab.scratch_once_job)) return;
    dropOnce(ab);
}

/// The scratch made for one job given back as it is, under the queue's
/// lock: its job done, or never sent.
pub fn dropOnce(ab: *AMDGPUBase) void {
    const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
    if (ab.scratch_once.bytes != 0) gpu.FreeGPUMemory(&ab.scratch_once);
    ab.scratch_once = .{};
    ab.scratch_once_wave_bytes = 0;
    ab.scratch_once_waves = 0;
    ab.scratch_once_job = 0;
}

/// The groups of 512 bytes the group memory a kernel takes is given in.
pub fn groupBlocks(group_bytes: u32) u32 {
    return (group_bytes + 511) / 512;
}

/// A kernel's dispatch (radv_emit_dispatch_packets), for a block whose
/// first address is `first`: the group's size, the code's address, its
/// resource words - the group memory it takes put in the second - no
/// limits on where its waves run, the queue's scratch, the address of its
/// arguments in its first two scalar registers, and the dispatch of
/// `groups` groups from the first.
pub fn dispatch(into: *[dispatch_words]u32, first: u32, kernel: *const amdgpu.GPUKernel, groups: [3]u32, threads: [3]u32, arguments: u64, scratch: Scratch) void {
    const sh = struct {
        fn at(base: u32, register: u32) u32 {
            return base + register - sh_registers_first;
        }
    };
    const rsrc2 = field(kernel.rsrc2, RSRC2_LDS_SIZE_MASK, RSRC2_LDS_SIZE_SHIFT, groupBlocks(kernel.group_bytes));
    var initiator = COMPUTE_SHADER_EN | FORCE_START_AT_000 | ORDER_MODE;
    if (kernel.properties & amdgpu.GPUKERNEL_WAVE32 != 0) initiator |= CS_W32_EN;
    into.* = .{
        packet(OP_SET_SH_REG, 4),                       sh.at(first, COMPUTE_NUM_THREAD_X), threads[0],                            threads[1],                   threads[2],
        packet(OP_SET_SH_REG, 3),                       sh.at(first, COMPUTE_PGM_LO),       @truncate(kernel.code >> 8),           @truncate(kernel.code >> 40), packet(OP_SET_SH_REG, 3),
        sh.at(first, COMPUTE_PGM_RSRC1),                kernel.rsrc1,                       rsrc2,                                 packet(OP_SET_SH_REG, 2),     sh.at(first, COMPUTE_PGM_RSRC3),
        kernel.rsrc3,                                   packet(OP_SET_SH_REG, 2),           sh.at(first, COMPUTE_RESOURCE_LIMITS), 0,                            packet(OP_SET_SH_REG, 3),
        sh.at(first, COMPUTE_DISPATCH_SCRATCH_BASE_LO), @truncate(scratch.base >> 8),       @truncate(scratch.base >> 40),         packet(OP_SET_SH_REG, 2),     sh.at(first, COMPUTE_TMPRING_SIZE),
        scratch.tmpring,                                packet(OP_SET_SH_REG, 3),           sh.at(first, COMPUTE_USER_DATA_0),     @truncate(arguments),         @truncate(arguments >> 32),
        packet(OP_DISPATCH_DIRECT, 4) | SHADER_COMPUTE, groups[0],                          groups[1],                             groups[2],                    initiator,
    };
}

/// Why a kernel cannot be run as a dispatch asks, or null where it can:
/// only the address of its arguments in its first two scalar registers
/// and waves of 32 or 64 lanes are known; private memory of the size its
/// descriptor gives, which a wave's scratch holds; no trap handler, at
/// most 64 KiB of group memory, 256 bytes of arguments and 1024 threads
/// in a group.
pub fn refusal(kernel: *const amdgpu.GPUKernel, groups: [3]u32, threads: [3]u32, argument_bytes: u32, stack_bytes: u32) ?[*:0]const u8 {
    if (kernel.code == 0 or kernel.code & 0xff != 0) return "its code is not on 256 bytes";
    if (kernel.properties & ~(amdgpu.GPUKERNEL_ARGUMENTS | amdgpu.GPUKERNEL_WAVE32 | amdgpu.GPUKERNEL_DYNAMIC_STACK) != 0) return "it takes values in its registers that are not handed to it";
    const user = (kernel.rsrc2 & RSRC2_USER_SGPR_MASK) >> RSRC2_USER_SGPR_SHIFT;
    const meant: u32 = if (kernel.properties & amdgpu.GPUKERNEL_ARGUMENTS != 0) 2 else 0;
    if (user != meant) return "its scalar registers are not the address of its arguments";
    const private = laneBytes(kernel, stack_bytes);
    if (private == 0 and kernel.rsrc2 & RSRC2_SCRATCH_EN != 0) return "it uses scratch memory of no size";
    if (private != 0 and kernel.rsrc2 & RSRC2_SCRATCH_EN == 0) return "its private memory is not given its waves";
    if (waveBytes(kernel, stack_bytes) > wave_bytes_most) return "its private memory is more than a wave's scratch holds";
    if (kernel.rsrc2 & RSRC2_TRAP_PRESENT != 0) return "it needs a trap handler";
    if (kernel.group_bytes > 64 * 1024) return "it takes more than 64 KiB of group memory";
    if (kernel.argument_bytes > amdgpu.GPUKERNEL_ARGUMENTS_MAX or argument_bytes > amdgpu.GPUKERNEL_ARGUMENTS_MAX) return "its arguments take more than 256 bytes";
    var lanes: u64 = 1;
    for (groups, threads) |count, size| {
        if (count == 0 or size == 0 or size > 0xffff) return "a dimension is empty or too large";
        lanes *= size;
    }
    if (lanes > 1024) return "a group has more than 1024 threads";
    return null;
}

// --- the scheduler's frames ---------------------------------------------------------------

/// A frame of a call of the scheduler, and where in it - in bytes - each
/// call has its status.
pub const frame_words = 64;
pub const Frame = [frame_words]u32;
pub const resources_status_at: u32 = 200;
pub const resources_1_status_at: u32 = 4;
pub const add_queue_status_at: u32 = 148;
pub const remove_queue_status_at: u32 = 20;
pub const query_status_at: u32 = 8;

const API_TYPE_SCHEDULER: u32 = 1;
const OP_SET_HW_RESOURCES: u32 = 0;
const OP_ADD_QUEUE: u32 = 2;
const OP_REMOVE_QUEUE: u32 = 3;
const OP_QUERY_SCHEDULER_STATUS: u32 = 11;
const OP_SET_HW_RESOURCES_1: u32 = 19;
const QUEUE_TYPE_COMPUTE: u32 = 1;

fn frameOf(op: u32) Frame {
    var frame: Frame = @splat(0);
    frame[0] = API_TYPE_SCHEDULER | op << 4 | frame_words << 12;
    return frame;
}

fn put64(frame: *Frame, byte: u32, value: u64) void {
    frame[byte / 4] = @truncate(value);
    frame[byte / 4 + 1] = @truncate(value >> 32);
}

/// The call's status written at `fence` as `value` once it is done.
pub fn setStatus(frame: *Frame, status_at: u32, fence_at: u64, value: u64) void {
    put64(frame, status_at, fence_at);
    put64(frame, status_at + 8, value);
}

/// What the scheduler is told of the block (SET_HW_RESOURCES): where it
/// keeps its context and writes the fence of a status asked, and the
/// first five addresses of the graphics block, its memory hub and the
/// interrupt block.
pub const Resources = struct {
    context: u64,
    query_fence: u64,
    graphics: [5]u32,
    memory_hub: [5]u32,
    interrupts: [5]u32,
};

/// The block's resources (mes_v11_0_set_hw_resources), as the vendor's
/// driver hands them on this block: the second half of the contexts each
/// hub has for the scheduler's queues, 4 KiB of the block's global data
/// share, the system's context as the paging one; the third and fourth
/// queues of each of the compute engine's four pipes, the second of each
/// graphics pipe and all but the first two of the DMA engine's for its
/// queues; its own doorbells; no resets, no log, its compute queues in
/// contexts of their own, polling for active queues, and each process's
/// quantum checked as it runs.
pub fn resourcesFrame(resources: Resources) Frame {
    var frame = frameOf(OP_SET_HW_RESOURCES);
    frame[1] = 0xff00;
    frame[2] = 0xff00;
    frame[3] = 0x1000;
    frame[4] = 0;
    for (0..4) |pipe| frame[5 + pipe] = 0xc;
    frame[13] = 2;
    frame[14] = 2;
    frame[15] = 0xfc;
    for (0..priority_levels) |level| frame[17 + level] = aggregated_doorbells + 2 * @as(u32, @intCast(level));
    put64(&frame, 88, resources.context);
    put64(&frame, 96, resources.query_fence);
    for (0..5) |index| {
        frame[26 + index] = resources.graphics[index];
        frame[34 + index] = resources.memory_hub[index];
        frame[42 + index] = resources.interrupts[index];
    }
    const disable_reset: u32 = 1 << 0;
    const use_different_vmid_compute: u32 = 1 << 1;
    const disable_mes_log: u32 = 1 << 2;
    const enable_level_process_quantum_check: u32 = 1 << 6;
    const enable_reg_active_poll: u32 = 1 << 10;
    frame[54] = disable_reset | use_different_vmid_compute | disable_mes_log | enable_level_process_quantum_check | enable_reg_active_poll;
    return frame;
}

/// The second call of resources (mes_v11_0_set_hw_resources_1): its
/// information context on - on bare metal, without one of its own - and
/// where it writes the fence of its cleaner.
pub fn resources1Frame(cleaner_fence: u64) Frame {
    var frame = frameOf(OP_SET_HW_RESOURCES_1);
    frame[7] = 1;
    put64(&frame, 52, cleaner_fence);
    return frame;
}

/// The queue mapped by the scheduler as one of the system's
/// (mes_v11_0_map_legacy_queue): its pipe and queue, doorbell, description
/// and write pointer's copy.
pub fn mapFrame(queue: Queue, doorbell: u32, mqd: u64, write_copy: u64) Frame {
    var frame = frameOf(OP_ADD_QUEUE);
    frame[18] = doorbell;
    put64(&frame, 76, mqd);
    put64(&frame, 84, write_copy);
    frame[27] = QUEUE_TYPE_COMPUTE;
    const map_legacy_kq: u32 = 1 << 13;
    frame[36] = map_legacy_kq;
    frame[48] = queue.pipe;
    frame[49] = queue.queue;
    return frame;
}

/// The queue removed by the scheduler as one of the system's, after its
/// reset (mes_v11_0_unmap_legacy_queue with RESET_QUEUES): its doorbell,
/// pipe and queue, and - where its firmware takes it - that the queue was
/// reset.
pub fn removeFrame(queue: Queue, doorbell: u32, after_reset: bool) Frame {
    var frame = frameOf(OP_REMOVE_QUEUE);
    frame[1] = doorbell;
    const unmap_legacy_queue: u32 = 1 << 3;
    const remove_queue_after_reset: u32 = 1 << 4;
    frame[4] = unmap_legacy_queue | @as(u32, if (after_reset) remove_queue_after_reset else 0);
    frame[9] = queue.pipe;
    frame[10] = queue.queue;
    frame[14] = QUEUE_TYPE_COMPUTE;
    return frame;
}

/// The scheduler's status asked (QUERY_SCHEDULER_STATUS).
pub fn queryFrame() Frame {
    return frameOf(OP_QUERY_SCHEDULER_STATUS);
}

// --- the rings ----------------------------------------------------------------------------

/// The three rings: where each is in the piece and how long, the words
/// what is written to it is padded to and with, its doorbell, and the
/// words its write pointer is copied into and its read pointer written
/// back to.
pub const Ring = enum {
    compute,
    scheduler,
    mapper,

    pub const Layout = struct { at: u32, bytes: u32, fetch: u32, filler: u32, doorbell: u32, write_copy_at: u32, read_back_at: u32 };

    pub fn layout(ring: Ring) Layout {
        return switch (ring) {
            .compute => .{ .at = compute_ring_at, .bytes = compute_ring_bytes, .fetch = 256, .filler = nop, .doorbell = compute_doorbell, .write_copy_at = compute_write_at, .read_back_at = compute_read_at },
            .scheduler => .{ .at = scheduler_ring_at, .bytes = scheduler_ring_bytes, .fetch = 2, .filler = 0, .doorbell = scheduler_doorbell, .write_copy_at = scheduler_write_at, .read_back_at = scheduler_read_at },
            .mapper => .{ .at = mapper_ring_at, .bytes = mapper_ring_bytes, .fetch = 256, .filler = nop, .doorbell = mapper_doorbell, .write_copy_at = mapper_write_at, .read_back_at = mapper_read_at },
        };
    }
};

/// The words written to `ring` since it started.
fn written(ab: *AMDGPUBase, ring: Ring) *u64 {
    return switch (ring) {
        .compute => &ab.compute_written,
        .scheduler => &ab.scheduler_written,
        .mapper => &ab.mapper_written,
    };
}

/// `values` put into `ring` from where it has been written to; the
/// engine is not told yet.
pub fn put(ab: *AMDGPUBase, ring: Ring, values: []const u32) void {
    const layout = ring.layout();
    const count = written(ab, ring);
    for (values) |value| {
        const index: u32 = @intCast(count.* % (layout.bytes / 4));
        word(ab, layout.at + index * 4).* = value;
        count.* += 1;
    }
}

/// What `ring` holds padded to its fetch, its write pointer's copy
/// written, and its engine told by its doorbell after a fence for the
/// ring's words (amdgpu_ring_commit).
pub fn commit(ab: *AMDGPUBase, ring: Ring) void {
    const layout = ring.layout();
    const count = written(ab, ring);
    while (count.* % layout.fetch != 0) put(ab, ring, &.{layout.filler});
    double(ab, layout.write_copy_at).* = count.*;
    fence();
    const bell: *volatile u64 = @ptrFromInt(@as(usize, @intCast(ab.doorbells)) + layout.doorbell * 4);
    bell.* = count.*;
}

/// `ring` tried as the vendor's driver tries a queue of the command
/// processor (gfx_v11_0_ring_test_ring): SCRATCH_REG0 set by the CPU,
/// then by a packet on the ring - the mapper's a register write, the
/// others' a configuration register set - and read back, 100 ms at most.
/// Whatever was put on the ring before goes with it. The mapper's ring
/// and the queue's: the scheduler's takes frames, not packets.
pub fn tryRing(ab: *AMDGPUBase, ring: Ring) bool {
    const sys = ab.sys_base;
    const scratch = _graphics.at(ab, SCRATCH_REG0);
    scratch.* = 0xCAFE_DEAD;
    const register = ab.graphics.addresses[SCRATCH_REG0.segment] + SCRATCH_REG0.offset;
    switch (ring) {
        .mapper => put(ab, ring, &writeRegister(register, 0xDEAD_BEEF)),
        else => put(ab, ring, &setConfig(register, 0xDEAD_BEEF)),
    }
    commit(ab, ring);
    const until = sys.UptimeUs() + test_most_us;
    while (scratch.* != 0xDEAD_BEEF) {
        if (sys.UptimeUs() > until) return false;
    }
    return true;
}

/// A call of the scheduler (mes_v11_0_submit_pkt_and_poll_completion):
/// `frame` with its status to be written as 1, then a frame asking the
/// scheduler's status that writes the call's number as the queue's fence;
/// true once the fence has the number - 2.1 s at most - and the status
/// was written.
pub fn call(ab: *AMDGPUBase, frame: *Frame, status_at: u32) bool {
    const sys = ab.sys_base;
    const status = double(ab, scheduler_status_at);
    status.* = 0;
    setStatus(frame, status_at, ab.compute.device + scheduler_status_at, 1);
    ab.scheduler_calls +%= 1;
    const number = ab.scheduler_calls;
    var query = queryFrame();
    setStatus(&query, query_status_at, ab.compute.device + scheduler_fence_at, number);
    put(ab, .scheduler, frame);
    put(ab, .scheduler, &query);
    commit(ab, .scheduler);
    const until = sys.UptimeUs() + scheduler_most_us;
    while (!passed(word(ab, scheduler_fence_at).*, number)) {
        if (sys.UptimeUs() > until) return false;
    }
    return status.* != 0;
}

// --- the queue's jobs ---------------------------------------------------------------------

/// The words a job of `count` takes in the ring with its start, its end
/// and the padding after them.
pub fn jobWords(count: u32) u32 {
    const whole = @as(u64, count) + acquire.len + 8;
    const fetch: u64 = 256;
    return @intCast(@min((whole + fetch - 1) / fetch * fetch, 0xffff_ffff));
}

/// How far the engine has read the queue's ring, in words within it, as
/// it last wrote that back.
pub fn readBack(ab: *AMDGPUBase) u32 {
    return word(ab, compute_read_at).*;
}

/// The number of the last job the engine has done.
pub fn done(ab: *AMDGPUBase) u32 {
    return word(ab, compute_fence_at).*;
}

/// The number of the job after `job`: numbers go round past 0, which no
/// job has.
pub fn nextJob(job: u32) u32 {
    const next = job +% 1;
    return if (next == 0) 1 else next;
}

/// What the queue keeps of job `job` while it does - until a job 64
/// numbers later is sent; null for one it does not keep.
pub fn record(ab: *AMDGPUBase, job: u32) ?*amdgpu_base.ComputeJob {
    if (job == 0) return null;
    const kept = &ab.compute_jobs[job % amdgpu_base.compute_records];
    return if (kept.number == job) kept else null;
}

/// The words of the ring the jobs not done still have: from the start of
/// the oldest of them to what is written. Where that one is not kept,
/// which the room each job waits for rules out, the words the engine has
/// yet to read.
pub fn keptWords(ab: *AMDGPUBase) u64 {
    const last = done(ab);
    if (passed(last, ab.compute_sent)) return 0;
    const oldest = record(ab, nextJob(last)) orelse return pending(ab.compute_written, readBack(ab));
    return ab.compute_written -% oldest.start;
}

/// The words the engine has yet to read of what is written: its read
/// pointer is a word within the ring.
pub fn pending(count: u64, read: u32) u32 {
    return @intCast((count -% read) & (compute_ring_words - 1));
}

/// `packets` put on the queue as one job - its start, the packets, its
/// end - and the engine told: the job's number, or 0 where the engine
/// does not make room for it within a second. Room is what neither the
/// jobs not done keep - their words stay for a reset to write again -
/// nor the engine has yet to read; with 256 words a job at least, at most
/// 63 jobs are not done at once, fewer than the records the queue keeps.
/// Under the queue's lock.
pub fn send(ab: *AMDGPUBase, packets: []const u32) u32 {
    const sys = ab.sys_base;
    const needed = jobWords(@intCast(packets.len));
    if (needed >= compute_ring_words) return 0;
    const until = sys.UptimeUs() + room_most_us;
    while (@max(pending(ab.compute_written, readBack(ab)), keptWords(ab)) + needed >= compute_ring_words) {
        if (sys.UptimeUs() > until) {
            exec.kprintf(sys, "%s: the compute engine makes no room in its ring: job %u done, read to word %u, %lu written\n", .{
                amdgpu.AMDGPUNAME, done(ab), readBack(ab), ab.compute_written,
            });
            return 0;
        }
        pause(ab, 100);
    }
    return putJob(ab, packets);
}

/// `packets` put on the ring as the next job, its start and how many
/// words its packets are kept at its number's place, and the engine told:
/// the job's number.
pub fn putJob(ab: *AMDGPUBase, packets: []const u32) u32 {
    const number = nextJob(ab.compute_sent);
    const start = ab.compute_written;
    put(ab, .compute, &acquire);
    put(ab, .compute, packets);
    put(ab, .compute, &release(ab.compute.device + compute_fence_at, number));
    ab.compute_jobs[number % amdgpu_base.compute_records] = .{ .number = number, .start = start, .packets = @intCast(packets.len) };
    commit(ab, .compute);
    ab.compute_sent = number;
    return number;
}

/// Whether a reset gave job `job` up, as its record says: one word, read
/// without the queue's lock.
pub fn givenUp(ab: *AMDGPUBase, job: u32) bool {
    return job != 0 and @atomicLoad(u32, &ab.compute_jobs[job % amdgpu_base.compute_records].given_up, .acquire) == job;
}

/// The ring's words from `from` on, counted as the words written to it
/// are, copied into `into` - the words of the jobs not done, kept aside
/// for a reset (amdgpu_ring_backup_unprocessed_commands).
pub fn keepJobs(ab: *AMDGPUBase, from: u64, into: []u32) void {
    const ring = words(ab, compute_ring_at);
    for (into, 0..) |*value, index| value.* = ring[@intCast((from + index) % compute_ring_words)];
}

/// The queue's description made again as its start made it, its ring
/// filled with NOPs and its read and write pointers' copies set to 0
/// (amdgpu_gfx_mqd_reset_restore, which copies back the description it
/// kept: this one is made from the same places).
pub fn renewQueue(ab: *AMDGPUBase) void {
    const device = ab.compute.device;
    describe(words(ab, compute_mqd_at), .{
        .kind = .compute,
        .mqd = device + compute_mqd_at,
        .ring = device + compute_ring_at,
        .ring_bytes = compute_ring_bytes,
        .eop = device + compute_eop_at,
        .read_back = device + compute_read_at,
        .write_copy = device + compute_write_at,
        .doorbell = compute_doorbell,
    });
    const ring = words(ab, compute_ring_at);
    for (0..compute_ring_words) |index| ring[index] = nop;
    double(ab, compute_write_at).* = 0;
    double(ab, compute_read_at).* = 0;
    ab.compute_written = 0;
    fence();
}

/// Jobs `from` to `to` marked given up, or no longer: each one's record's
/// word, which a task waiting reads. How many jobs that is.
pub fn markGivenUp(ab: *AMDGPUBase, from: u32, to: u32, given_up: bool) u32 {
    var each = from;
    var count: u32 = 0;
    for (0..amdgpu_base.compute_records) |_| {
        if (record(ab, each)) |job| @atomicStore(u32, &job.given_up, if (given_up) each else 0, .release);
        count += 1;
        if (each == to) break;
        each = nextJob(each);
    }
    return count;
}

/// The jobs whose words `kept` holds - `first` and every one after it to
/// the last sent - written to the ring again from where it is written to,
/// in order, and the engine told (amdgpu_ring_set_fence_errors_and_reemit);
/// where `blank`, `first`'s own packets made NOPs first, so that its end
/// comes in its place. Each job's start is moved to where its words are
/// now.
pub fn writeAgain(ab: *AMDGPUBase, kept: []u32, first: u32, blank: bool) void {
    const given = record(ab, first) orelse return;
    if (blank) {
        for (kept[acquire.len..][0..given.packets]) |*value| value.* = nop;
    }
    const from = given.start;
    const to = ab.compute_written;
    var each = first;
    for (0..amdgpu_base.compute_records) |_| {
        if (record(ab, each)) |job| job.start = job.start - from + to;
        if (each == ab.compute_sent) break;
        each = nextJob(each);
    }
    put(ab, .compute, kept);
    commit(ab, .compute);
}

/// The last job sent written as done, every job before it with it
/// (amdgpu_fence_driver_force_completion).
pub fn forceDone(ab: *AMDGPUBase) void {
    word(ab, compute_fence_at).* = ab.compute_sent;
    fence();
}

/// The end-of-pipe interrupt's server: counted, and the queue's waitable
/// signalled.
pub fn endServer(data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const ab: *AMDGPUBase = @ptrCast(@alignCast(data.?));
    ab.compute_ends +%= 1;
    ab.sys_base.SignalWaitable(&ab.compute_end);
    return 1;
}

// --- tests --------------------------------------------------------------------------------

const testing = @import("std").testing;

test "the queues' control words, as the vendor's driver makes them" {
    try testing.expectEqual(@as(u32, 0xD830_800B), pqControl(.scheduler, scheduler_ring_bytes));
    try testing.expectEqual(@as(u32, 0xD830_800A), pqControl(.scheduler, mapper_ring_bytes));
    try testing.expectEqual(@as(u32, 0xD030_890D), pqControl(.compute, compute_ring_bytes));
}

test "a queue's description" {
    var mqd: [mqd_words]u32 = @splat(0xffff_ffff);
    describe(&mqd, .{
        .kind = .compute,
        .mqd = 0x80_0001_8000,
        .ring = 0x80_0000_0000,
        .ring_bytes = compute_ring_bytes,
        .eop = 0x80_0001_b000,
        .read_back = 0x80_0001_c080,
        .write_copy = 0x80_0001_c088,
        .doorbell = compute_doorbell,
    });
    try testing.expectEqual(@as(u32, 0xC031_0800), mqd[0]);
    try testing.expectEqual(@as(u32, 1), mqd[11]);
    try testing.expectEqual(@as(u32, 0xffff_ffff), mqd[23]);
    try testing.expectEqual(@as(u32, 0), mqd[25]);
    try testing.expectEqual(@as(u32, 7), mqd[32]);
    try testing.expectEqual(@as(u32, 0x0001_8000), mqd[128]);
    try testing.expectEqual(@as(u32, 0x80), mqd[129]);
    try testing.expectEqual(@as(u32, 0), mqd[130]);
    try testing.expectEqual(@as(u32, 0x0be0_5501), mqd[132]);
    try testing.expectEqual(@as(u32, 0x111), mqd[135]);
    try testing.expectEqual(@as(u32, 0x8000_0000), mqd[136]);
    try testing.expectEqual(@as(u32, 0), mqd[137]);
    try testing.expectEqual(@as(u32, 0x0001_c080), mqd[139]);
    try testing.expectEqual(@as(u32, 0x80), mqd[140]);
    try testing.expectEqual(@as(u32, 0x0001_c088), mqd[141]);
    try testing.expectEqual(@as(u32, 0x4000_0018), mqd[143]);
    try testing.expectEqual(@as(u32, 0xD030_890D), mqd[145]);
    try testing.expectEqual(@as(u32, 0x0030_0000), mqd[149]);
    try testing.expectEqual(@as(u32, 0x100), mqd[162]);
    try testing.expectEqual(@as(u32, 0x8000_01b0), mqd[165]);
    try testing.expectEqual(@as(u32, 0), mqd[166]);
    try testing.expectEqual(@as(u32, 8), mqd[167]);
    try testing.expectEqual(@as(u32, 0), mqd[511]);

    describe(&mqd, .{
        .kind = .scheduler,
        .mqd = 0x80_0001_6000,
        .ring = 0x80_0001_0000,
        .ring_bytes = scheduler_ring_bytes,
        .eop = 0x80_0001_9000,
        .read_back = 0x80_0001_c010,
        .write_copy = 0x80_0001_c01c,
        .doorbell = scheduler_doorbell,
    });
    try testing.expectEqual(@as(u32, 1), mqd[130]);
    try testing.expectEqual(@as(u32, 0), mqd[135]);
    try testing.expectEqual(@as(u32, 0x0001_c018), mqd[141]);
    try testing.expectEqual(@as(u32, 0x4000_0058), mqd[143]);
    try testing.expectEqual(@as(u32, 0xD830_800B), mqd[145]);
    try testing.expectEqual(@as(u32, 0), mqd[150]);
}

test "the packets a start and a job write" {
    try testing.expectEqual(@as(u32, 0xFFFF_1000), nop);
    try testing.expectEqual(@as(u32, 0xC006_5800), acquire[0]);
    try testing.expectEqual(@as(u32, 0x0000_C3B1), acquire[7]);
    const end = release(0x80_0001_c090, 7);
    try testing.expectEqual(@as(u32, 0xC006_4900), end[0]);
    try testing.expectEqual(@as(u32, 0x0660_3514), end[1]);
    try testing.expectEqual(@as(u32, 0x2200_0000), end[2]);
    try testing.expectEqual(@as(u32, 0x0001_c090), end[3]);
    try testing.expectEqual(@as(u32, 0x80), end[4]);
    try testing.expectEqual(@as(u32, 7), end[5]);
    const resources = setResources(~@as(u64, 0));
    try testing.expectEqual(@as(u32, 0xC006_A000), resources[0]);
    try testing.expectEqual(@as(u32, 0x000A_0000), resources[1]);
    try testing.expectEqual(@as(u32, 0xffff_ffff), resources[3]);
    const map = mapScheduler(0x80_0001_6000, 0x80_0001_c018);
    try testing.expectEqual(@as(u32, 0xC005_A200), map[0]);
    try testing.expectEqual(@as(u32, 0x3408_0000), map[1]);
    try testing.expectEqual(@as(u32, 0x58), map[2]);
    try testing.expectEqual(@as(u32, 0x0001_c018), map[5]);
    const scratch = 0xa000 + SCRATCH_REG0.offset;
    try testing.expectEqualSlices(u32, &.{ 0xC003_3700, 1 << 16, 0xc040, 0, 0xDEAD_BEEF }, &writeRegister(scratch, 0xDEAD_BEEF));
    try testing.expectEqualSlices(u32, &.{ 0xC001_7900, 0x40, 0xDEAD_BEEF }, &setConfig(scratch, 0xDEAD_BEEF));
    try testing.expectEqual(@as(u32, 256), jobWords(0));
    try testing.expectEqual(@as(u32, 256), jobWords(240));
    try testing.expectEqual(@as(u32, 512), jobWords(241));
}

test "a kernel's dispatch" {
    const kernel: amdgpu.GPUKernel = .{
        .code = 0x80_0402_1500,
        .rsrc1 = 0xe0af_0100,
        .rsrc2 = 0x84,
        .rsrc3 = 0x10,
        .argument_bytes = 16,
        .group_bytes = 1000,
        .properties = amdgpu.GPUKERNEL_ARGUMENTS | amdgpu.GPUKERNEL_WAVE32,
    };
    var words_out: [dispatch_words]u32 = undefined;
    dispatch(&words_out, 0x1260, &kernel, .{ 4, 1, 1 }, .{ 64, 1, 1 }, 0x80_0001_e100, .{});
    try testing.expectEqualSlices(u32, &.{
        0xC003_7600, 0x1260 + 0x1ba7 - 0x2c00, 64,             1,           1,
        0xC002_7600, 0x020c,                   0x8004_0215,    0,           0xC002_7600,
        0x0212,      0xe0af_0100,              0x84 | 2 << 15, 0xC001_7600, 0x0228,
        0x10,        0xC001_7600,              0x0215,         0,           0xC002_7600,
        0x0210,      0,                        0,              0xC001_7600, 0x0218,
        0,           0xC002_7600,              0x0240,         0x0001_e100, 0x80,
        0xC003_1502, 4,                        1,              1,           1 | 1 << 2 | 1 << 6 | 1 << 15,
    }, &words_out);
    dispatch(&words_out, 0x1260, &kernel, .{ 4, 1, 1 }, .{ 64, 1, 1 }, 0x80_0001_e100, Scratch.of(0x80_0400_0000, 384, 16640, 1));
    try testing.expectEqualSlices(u32, &.{ 0xC002_7600, 0x0210, 0x8004_0000, 0, 0xC001_7600, 0x0218, 384 | 65 << 12 }, words_out[19..26]);
    try testing.expectEqual(@as(u32, 384 | 2 << 12), Scratch.of(0, 768, 512, 2).tmpring);
    try testing.expect(refusal(&kernel, .{ 4, 1, 1 }, .{ 64, 1, 1 }, 16, 0) == null);
    try testing.expect(refusal(&kernel, .{ 4, 1, 1 }, .{ 64, 32, 1 }, 16, 0) != null);
    try testing.expect(refusal(&kernel, .{ 0, 1, 1 }, .{ 64, 1, 1 }, 16, 0) != null);
    try testing.expect(refusal(&kernel, .{ 1, 1, 1 }, .{ 64, 1, 1 }, 257, 0) != null);
    var scratch = kernel;
    scratch.private_bytes = 16;
    try testing.expect(refusal(&scratch, .{ 1, 1, 1 }, .{ 64, 1, 1 }, 16, 0) != null);
    scratch.rsrc2 |= RSRC2_SCRATCH_EN;
    try testing.expect(refusal(&scratch, .{ 1, 1, 1 }, .{ 64, 1, 1 }, 16, 0) == null);
    scratch.private_bytes = 0;
    try testing.expect(refusal(&scratch, .{ 1, 1, 1 }, .{ 64, 1, 1 }, 16, 0) != null);
    scratch.private_bytes = 1 << 20;
    try testing.expect(refusal(&scratch, .{ 1, 1, 1 }, .{ 64, 1, 1 }, 16, 0) != null);
    // A stack that grows is given the dispatch's bytes, 1 KiB where it
    // names none - with no private bytes of its own too - and refused
    // past what a wave's scratch holds.
    var dynamic = scratch;
    dynamic.private_bytes = 16;
    dynamic.properties |= amdgpu.GPUKERNEL_DYNAMIC_STACK;
    try testing.expect(refusal(&dynamic, .{ 1, 1, 1 }, .{ 64, 1, 1 }, 16, 0) == null);
    dynamic.private_bytes = 0;
    try testing.expect(refusal(&dynamic, .{ 1, 1, 1 }, .{ 64, 1, 1 }, 16, 0) == null);
    try testing.expect(refusal(&dynamic, .{ 1, 1, 1 }, .{ 64, 1, 1 }, 16, 1 << 20) != null);
    var dispatch_pointer = kernel;
    dispatch_pointer.properties |= 1 << 1;
    try testing.expect(refusal(&dispatch_pointer, .{ 1, 1, 1 }, .{ 64, 1, 1 }, 16, 0) != null);
    try testing.expectEqual(@as(u32, 0), groupBlocks(0));
    try testing.expectEqual(@as(u32, 1), groupBlocks(512));
    try testing.expectEqual(@as(u32, 128), groupBlocks(65536));
}

test "a wave's scratch, and how many waves the queue's holds" {
    var kernel: amdgpu.GPUKernel = .{ .properties = amdgpu.GPUKERNEL_WAVE32 };
    try testing.expectEqual(@as(u64, 0), waveBytes(&kernel, 0));
    kernel.private_bytes = 516;
    try testing.expectEqual(@as(u64, 16640), waveBytes(&kernel, 0));
    kernel.private_bytes = 1;
    try testing.expectEqual(@as(u64, 256), waveBytes(&kernel, 0));
    kernel.private_bytes = 16;
    try testing.expectEqual(@as(u64, 768), waveBytes(&kernel, 0));
    // A fixed stack takes no notice of the dispatch's bytes.
    try testing.expectEqual(@as(u64, 768), waveBytes(&kernel, 4096));
    kernel.properties = 0;
    try testing.expectEqual(@as(u64, 1280), waveBytes(&kernel, 0));
    // A stack that grows: 1 KiB a lane where the dispatch names none, the
    // dispatch's bytes, and the kernel's own where those are more.
    kernel.properties = amdgpu.GPUKERNEL_WAVE32 | amdgpu.GPUKERNEL_DYNAMIC_STACK;
    kernel.private_bytes = 32;
    try testing.expectEqual(@as(u64, 1024), laneBytes(&kernel, 0));
    try testing.expectEqual(@as(u64, 32 * 1024 + 256), waveBytes(&kernel, 0));
    try testing.expectEqual(@as(u64, 4096), laneBytes(&kernel, 4096));
    try testing.expectEqual(@as(u64, 32), laneBytes(&kernel, 16));
    kernel.private_bytes = 2048;
    try testing.expectEqual(@as(u64, 2048), laneBytes(&kernel, 0));
    try testing.expectEqual(@as(u32, 384), scratchWaves(1, 12));
    try testing.expectEqual(@as(u32, 32), scratchWaves(1, 0));
    try testing.expectEqual(@as(u32, 64), scratchWaves(2, 1));
    try testing.expectEqual(@as(u32, 3072), scratchWaves(6, 96));
    try testing.expectEqual(@as(u32, 4095), scratchWaves(1, 200));
}

test "a scratch made for one dispatch" {
    // The queue's own takes a 32nd of the device's memory at most: of
    // the NucBox's 512 MiB, 384 waves of 33024 bytes are kept, of 65792
    // made for one job.
    try testing.expect(!scratchOnce(33024, 384, 512 << 20));
    try testing.expect(scratchOnce(65792, 384, 512 << 20));
    try testing.expect(!scratchOnce((16 << 20) / 384, 384, 512 << 20));
    // The groups that can be on the engines at once: every group of a
    // dispatch on one engine...
    try testing.expectEqual(@as(u64, 32), dispatchGroups(.{ 32, 1, 1 }, 64, 1, 12));
    try testing.expectEqual(@as(u64, 256), dispatchGroups(.{ 256, 1, 1 }, 64, 1, 12));
    // ... at least the smaller of 16 groups and 256 lanes an engine...
    try testing.expectEqual(@as(u64, 4), dispatchGroups(.{ 2, 1, 1 }, 64, 1, 12));
    try testing.expectEqual(@as(u64, 16), dispatchGroups(.{ 1, 1, 1 }, 1, 1, 12));
    try testing.expectEqual(@as(u64, 8), dispatchGroups(.{ 1, 1, 1 }, 64, 2, 12));
    // ... shared out between them, the unit past an even share taking a
    // group more each round of the 13: 93 groups shared, 7 rounds.
    try testing.expectEqual(@as(u64, 108), dispatchGroups(.{ 100, 1, 1 }, 64, 2, 13));
    try testing.expectEqual(@as(u64, 100), dispatchGroups(.{ 10, 10, 1 }, 64, 2, 12));
    // Counts past what the device takes stop at the largest a word holds.
    try testing.expect(dispatchGroups(.{ 0xffff_ffff, 0xffff_ffff, 0xffff_ffff }, 64, 2, 12) >= 1 << 63);
    // Their waves, at most every wave the queue's holds.
    try testing.expectEqual(@as(u32, 64), onceWaves(.{ 32, 1, 1 }, .{ 64, 1, 1 }, true, 1, 12, 384));
    try testing.expectEqual(@as(u32, 384), onceWaves(.{ 256, 1, 1 }, .{ 64, 1, 1 }, true, 1, 12, 384));
    try testing.expectEqual(@as(u32, 32), onceWaves(.{ 32, 1, 1 }, .{ 64, 1, 1 }, false, 1, 12, 384));
    try testing.expectEqual(@as(u32, 8), onceWaves(.{ 2, 1, 1 }, .{ 64, 1, 1 }, true, 1, 12, 384));
    try testing.expectEqual(@as(u32, 24), onceWaves(.{ 1, 1, 1 }, .{ 65, 1, 1 }, true, 2, 12, 768));
    try testing.expectEqual(@as(u32, 384), onceWaves(.{ 0xffff_ffff, 0xffff_ffff, 1 }, .{ 1024, 1, 1 }, true, 1, 12, 384));
}

test "the scheduler's frames, at the places the vendor's header gives" {
    var frame = resourcesFrame(.{
        .context = 0x80_0001_c040,
        .query_fence = 0x80_0001_c060,
        .graphics = .{ 0x1260, 0xa000, 0x1c000, 0x2402c00, 0 },
        .memory_hub = .{ 0x1a000, 0x2408800, 0, 0, 0 },
        .interrupts = .{ 0x4280, 0x2400c00, 0, 0, 0 },
    });
    try testing.expectEqual(@as(u32, 0x0004_0001), frame[0]);
    try testing.expectEqual(@as(u32, 0xff00), frame[1]);
    try testing.expectEqual(@as(u32, 0x1000), frame[3]);
    try testing.expectEqualSlices(u32, &.{ 0xc, 0xc, 0xc, 0xc, 0, 0, 0, 0, 2, 2, 0xfc, 0 }, frame[5..17]);
    try testing.expectEqualSlices(u32, &.{ 0x800, 0x802, 0x804, 0x806, 0x808 }, frame[17..22]);
    try testing.expectEqual(@as(u32, 0x0001_c040), frame[22]);
    try testing.expectEqual(@as(u32, 0x80), frame[23]);
    try testing.expectEqual(@as(u32, 0x0001_c060), frame[24]);
    try testing.expectEqual(@as(u32, 0xa000), frame[27]);
    try testing.expectEqual(@as(u32, 0x2408800), frame[35]);
    try testing.expectEqual(@as(u32, 0x2400c00), frame[43]);
    try testing.expectEqual(@as(u32, 0x447), frame[54]);
    try testing.expectEqual(@as(u32, 0), frame[55]);
    setStatus(&frame, resources_status_at, 0x80_0001_c028, 1);
    try testing.expectEqualSlices(u32, &.{ 0x0001_c028, 0x80, 1, 0 }, frame[50..54]);

    const second = resources1Frame(0x80_0001_d000);
    try testing.expectEqual(@as(u32, 0x0004_0131), second[0]);
    try testing.expectEqual(@as(u32, 1), second[7]);
    try testing.expectEqual(@as(u32, 0x0001_d000), second[13]);

    const map = mapFrame(compute_queue, compute_doorbell, 0x80_0001_8000, 0x80_0001_c088);
    try testing.expectEqual(@as(u32, 0x0004_0021), map[0]);
    try testing.expectEqual(@as(u32, 6), map[18]);
    try testing.expectEqual(@as(u32, 0x0001_8000), map[19]);
    try testing.expectEqual(@as(u32, 0x0001_c088), map[21]);
    try testing.expectEqual(@as(u32, 1), map[27]);
    try testing.expectEqual(@as(u32, 0x2000), map[36]);
    try testing.expectEqual(@as(u32, 0), map[48]);
    try testing.expectEqual(@as(u32, 0), map[49]);
    try testing.expectEqual(@as(u32, 0x0004_00b1), queryFrame()[0]);

    var remove = removeFrame(compute_queue, compute_doorbell, true);
    try testing.expectEqual(@as(u32, 0x0004_0031), remove[0]);
    try testing.expectEqual(@as(u32, 6), remove[1]);
    try testing.expectEqual(@as(u32, 1 << 3 | 1 << 4), remove[4]);
    try testing.expectEqual(@as(u32, 0), remove[9]);
    try testing.expectEqual(@as(u32, 0), remove[10]);
    try testing.expectEqual(@as(u32, 1), remove[14]);
    setStatus(&remove, remove_queue_status_at, 0x80_0001_c028, 1);
    try testing.expectEqualSlices(u32, &.{ 0x0001_c028, 0x80, 1, 0 }, remove[5..9]);
    try testing.expectEqual(@as(u32, 1 << 3), removeFrame(compute_queue, compute_doorbell, false)[4]);
}

test "a job's number, past 0" {
    try testing.expectEqual(@as(u32, 2), nextJob(1));
    try testing.expectEqual(@as(u32, 1), nextJob(0xffff_ffff));
    try testing.expectEqual(@as(u32, 1), nextJob(0));
}

test "the jobs not done, kept aside and written again from the ring's start" {
    // The piece up to its page, and the doorbell, in the host's memory;
    // three jobs put on the ring after the 256 words of its test.
    const piece = try testing.allocator.alloc(u32, (page_at + 0x100) / 4);
    defer testing.allocator.free(piece);
    @memset(piece, 0);
    var bell: u64 = 0;
    var ab: AMDGPUBase = undefined;
    ab.compute = .{ .cpu = @intFromPtr(piece.ptr), .device = 0x80_0000_0000, .bytes = @intCast(piece.len * 4) };
    ab.doorbells = @intFromPtr(&bell) - compute_doorbell * 4;
    ab.compute_written = 256;
    ab.compute_sent = 0xffff_fffe;
    ab.compute_jobs = @splat(.{});
    word(&ab, compute_fence_at).* = 0xffff_fffe;
    try testing.expectEqual(@as(u64, 0), keptWords(&ab));
    const packets = [_]u32{ 0x1111_1111, 0x2222_2222, 0x3333_3333 };
    try testing.expectEqual(@as(u32, 0xffff_ffff), putJob(&ab, &packets));
    try testing.expectEqual(@as(u32, 1), putJob(&ab, &packets));
    try testing.expectEqual(@as(u32, 2), putJob(&ab, packets[0..1]));
    try testing.expectEqual(@as(u64, 4 * 256), ab.compute_written);
    try testing.expectEqual(@as(u64, 4 * 256), bell);
    try testing.expectEqual(@as(u64, 3 * 256), keptWords(&ab));
    try testing.expectEqual(@as(u64, 512), record(&ab, 1).?.start);

    // The first job done; the second hangs. Its words and the third's
    // kept, the queue made new, the ring's test put first; then the two
    // written again, the second's packets NOPs and its end in place.
    word(&ab, compute_fence_at).* = 0xffff_ffff;
    try testing.expectEqual(@as(u64, 2 * 256), keptWords(&ab));
    var kept: [2 * 256]u32 = undefined;
    keepJobs(&ab, record(&ab, 1).?.start, &kept);
    renewQueue(&ab);
    try testing.expectEqual(@as(u64, 0), ab.compute_written);
    const ring = piece[compute_ring_at / 4 ..][0..compute_ring_words];
    try testing.expectEqual(nop, ring[600]);
    try testing.expectEqual(@as(u32, 0xC031_0800), piece[compute_mqd_at / 4]);
    put(&ab, .compute, &setConfig(uconfig_registers_first + 0x40, 0xDEAD_BEEF));
    commit(&ab, .compute);
    try testing.expectEqual(@as(u32, 2), markGivenUp(&ab, 1, 2, true));
    try testing.expectEqual(@as(u32, 1), markGivenUp(&ab, 2, 2, false));
    writeAgain(&ab, &kept, 1, true);
    try testing.expectEqualSlices(u32, &acquire, ring[256..][0..acquire.len]);
    try testing.expectEqualSlices(u32, &.{ nop, nop, nop }, ring[256 + acquire.len ..][0..3]);
    try testing.expectEqualSlices(u32, &release(@as(u64, 0x80_0000_0000) + compute_fence_at, 1), ring[256 + acquire.len + 3 ..][0..8]);
    try testing.expectEqual(@as(u32, 0x1111_1111), ring[512 + acquire.len]);
    try testing.expectEqualSlices(u32, &release(@as(u64, 0x80_0000_0000) + compute_fence_at, 2), ring[512 + acquire.len + 1 ..][0..8]);
    try testing.expectEqual(@as(u64, 3 * 256), ab.compute_written);
    try testing.expectEqual(@as(u64, 3 * 256), bell);
    try testing.expectEqual(@as(u64, 256), record(&ab, 1).?.start);
    try testing.expectEqual(@as(u64, 512), record(&ab, 2).?.start);
    try testing.expect(givenUp(&ab, 1));
    try testing.expect(!givenUp(&ab, 2));
    try testing.expect(!givenUp(&ab, 0xffff_ffff));
    try testing.expectEqual(@as(u64, 2 * 256), keptWords(&ab));

    // Written again whole, from the second on: its packets kept.
    keepJobs(&ab, record(&ab, 2).?.start, kept[0..256]);
    writeAgain(&ab, kept[0..256], 2, false);
    try testing.expectEqual(@as(u32, 0x1111_1111), ring[768 + acquire.len]);
    try testing.expectEqual(@as(u64, 768), record(&ab, 2).?.start);
    try testing.expectEqual(@as(u64, 4 * 256), ab.compute_written);

    // Given up again: every job not done is, and the last is done.
    _ = markGivenUp(&ab, 1, 2, true);
    forceDone(&ab);
    try testing.expect(givenUp(&ab, 2));
    try testing.expectEqual(@as(u32, 2), done(&ab));
    try testing.expectEqual(@as(u64, 0), keptWords(&ab));

    // A job 64 numbers later takes the record's place.
    ab.compute_sent = 65;
    _ = putJob(&ab, &packets);
    try testing.expect(record(&ab, 2) == null);
    try testing.expect(!givenUp(&ab, 2));
}

test "what the engine has yet to read of its ring" {
    try testing.expectEqual(@as(u32, 0), pending(0, 0));
    try testing.expectEqual(@as(u32, 256), pending(256, 0));
    try testing.expectEqual(@as(u32, 256), pending(compute_ring_words + 256, 0));
    try testing.expectEqual(@as(u32, 512), pending(compute_ring_words + 256, compute_ring_words - 256));
}
