// SPDX-License-Identifier: MPL-2.0
//! An AMD graphics device's JPEG decoder: the block beside the video
//! decoder, in the video block's registers, which amdgpu.resource finds,
//! powers and hands memory to. This drives the one of video block 4.0.2.
//!
//! **What it reads and writes.** The file as it is, but for the segments
//! the decoder has no use for - application data, comments - which are
//! left out of the copy it is given: it reads the tables, the frame and
//! the scan's header itself. It writes the picture's samples in the
//! form the file's sampling has: one plane for grey, three for 4:4:4,
//! brightness and the two differences' plane at half size (NV12) for
//! 4:2:0, and brightness and differences interleaved (YUYV) for 4:2:2.
//! Every piece is in the device's own memory (amdgpu.resource's
//! AllocGPUMemory), the file's copy on a multiple of 256 bytes and a
//! length of 128. The CPU writes those pieces gathered and fences before
//! it moves the ring's write pointer, and reads the samples back by
//! streaming loads.
//!
//! **How it is told.** A ring of commands in the device's memory, read
//! from where the CPU last moved its write pointer to. A command is two
//! words - a register and a value - or a wait: "until this register,
//! masked, reads what the reference register holds". A picture is one
//! indirect buffer of such commands, the ring pointing at it and then
//! writing a fence: a number into memory, which is what the CPU waits
//! for.
//!
//! **Starting it** - the first decode does, `wake`: the power manager
//! powers it up, its power island is let go of and waited for, its clock
//! gating switched off, its memory interface's reset released, and its
//! ring placed and set. Then two checks before any picture: a register
//! written by a command in the ring, then one written from an indirect
//! buffer that ends with a fence. Each step says on the system's lines
//! where it stops. A decoder that would not start is not asked again.
//!
//! The commands are the ones Linux's amdgpu driver puts around an
//! indirect buffer and Mesa's radeonsi puts into one for a picture, with
//! the decoder's addresses as the device's memory has them: the memory
//! hub as the firmware leaves it takes them as physical, so no page
//! table is needed.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const types = sdk.resources.jpeg;
const reg = sdk.hardware.mmio.reg;
const ExecBase = sdk.interface.exec.ExecBase;
const AMDGPUBase = sdk.interface.amdgpu.AMDGPUBase;
const Header = @import("../header/_header.zig").Header;

const owner = types.JPEGNAME;

/// The video block whose JPEG decoder this drives, and the segment of its
/// registers the decoder's are in.
const video_known = .{ .major = 4, .minor = 0, .revision = 2 };
const segment = 1;

// --- the decoder's registers, as the CPU reaches them: 32-bit words from
// the video block's second address ------------------------------------------

const PGFSM_CONFIG = 0x0000;
const PGFSM_STATUS = 0x0001;
const JPEG_POWER_STATUS = 0x0003;
const VCN_JPEG_DB_CTRL = 0x0071;
const JPEG_PITCH = 0x05df;
const JRBC_RB_WPTR = 0x0640;
const JRBC_RB_CNTL = 0x0641;
const JRBC_STATUS = 0x0649;
const JRBC_RB_RPTR = 0x064a;
const JRBC_RB_SIZE = 0x0653;
const LMI_JRBC_RB_VMID = 0x0690;
const LMI_JRBC_RB_BAR_LOW = 0x06a6;
const LMI_JRBC_RB_BAR_HIGH = 0x06a7;
const JMI_CNTL = 0x06d2;
const JPEG_SYS_INT_EN = 0x0701;
const JPEG_CGC_GATE = 0x0720;
const JPEG_CGC_CTRL = 0x0721;

/// The power island: the decoder's two bits of the configuration and the
/// status, and what they hold for "on" (asked and answered).
const UVDJ_PWR_SHIFT = 22;
const UVDJ_PWR_MASK: u32 = 0b11 << UVDJ_PWR_SHIFT;
const UVDJ_PWR_CONFIG_ON: u32 = 1;
const UVDJ_PWR_STATUS_ON: u32 = 0;
/// Its power status: the anti-hang mechanism, and the static power mode.
const POWER_STATUS_ANTI_HANG: u32 = 1 << 0;
const POWER_STATUS_PG_MODE: u32 = 1 << 4;
/// Clock gating: dynamic mode on, the decoder's mode bit off, a delay
/// timer of 1 and an off delay of 4; the gates of the decoder, its second
/// decoder, its memory interface and its ring's bus manager opened.
const CGC_DYN_CLOCK_MODE: u32 = 1 << 0;
const CGC_GATE_DLY_TIMER_1: u32 = 1 << 1;
const CGC_OFF_DELAY_4: u32 = 4 << 5;
const CGC_JPEG_DEC_MODE: u32 = 1 << 16;
const CGC_GATES: u32 = (1 << 0) | (1 << 1) | (1 << 3) | (1 << 4);
const JMI_SOFT_RESET: u32 = 1 << 0;
const SYS_INT_DJRBC: u32 = 1 << 1;
/// The ring's control: fetching stopped, and its read pointer writable.
const RB_NO_FETCH: u32 = 1 << 0;
const RB_RPTR_WR_EN: u32 = 1 << 1;

// --- the same registers and others as a command names them --------------

const I_JPEG_CNTL = 0x4000;
const I_JPEG_RB_BASE = 0x4001;
const I_JPEG_RB_WPTR = 0x4002;
const I_JPEG_RB_RPTR = 0x4003;
const I_JPEG_RB_SIZE = 0x4004;
const I_JPEG_INT_EN = 0x400a;
const I_JPEG_TIER_CNTL2 = 0x400f;
const I_JPEG_OUTBUF_CNTL = 0x401c;
const I_JPEG_OUTBUF_WPTR = 0x401d;
const I_JPEG_OUTBUF_RPTR = 0x401e;
const I_JPEG_PITCH = 0x401f;
const I_JPEG_UV_PITCH = 0x4020;
const I_DEC_Y_TILING = 0x4024;
const I_DEC_UV_TILING = 0x4025;
const I_DEC_ADDR_MODE = 0x4027;
const I_GPCOM_CMD = 0x4029;
const I_GPCOM_DATA0 = 0x402a;
const I_GPCOM_DATA1 = 0x402b;
const I_JPEG_INDEX = 0x402c;
const I_JPEG_DATA = 0x402d;
const I_DEC_SOFT_RST = 0x402f;
const I_JRBC_IB_SIZE = 0x4082;
const I_JRBC_RB_REF_DATA = 0x4084;
const I_JRBC_RB_COND_RD_TIMER = 0x4085;
const I_JRBC_IB_COND_RD_TIMER = 0x408e;
const I_JRBC_IB_REF_DATA = 0x408f;
const I_JRBC_STATUS = 0x4089;
const I_LMI_JRBC_IB_VMID = 0x40cf;
const I_LMI_JPEG_VMID = 0x40d1;
const I_LMI_READ_BAR_LOW = 0x40e0;
const I_LMI_READ_BAR_HIGH = 0x40e1;
const I_LMI_WRITE_BAR_LOW = 0x40e2;
const I_LMI_WRITE_BAR_HIGH = 0x40e3;
const I_LMI_IB_BAR_LOW = 0x40e8;
const I_LMI_IB_BAR_HIGH = 0x40e9;
const I_LMI_RB_MEM_WR_BAR_LOW = 0x40ea;
const I_LMI_RB_MEM_WR_BAR_HIGH = 0x40eb;
const I_LMI_RB_MEM_RD_BAR_LOW = 0x40ec;
const I_LMI_RB_MEM_RD_BAR_HIGH = 0x40ed;
const I_JPEG_IH_CTRL = 0x4149;
/// A register outside the decoder: its byte offset into the first, then
/// its value into the second.
const I_EXTERNAL_REG = 0x1bfff;
const I_EXTERNAL_REG_WRITE = 0x18000;

/// A command's first word: the register, the condition and the kind -
/// 0 a write, 2 the indirect buffer run, 3 a wait, 4 a wait for the
/// fence's write, 6 nothing, 7 a trap.
fn command(register: u32, condition: u32, kind: u32) u32 {
    return (register & 0x3FFFF) | (condition & 0xF) << 24 | (kind & 0xF) << 28;
}
const WRITE = 0;
const RUN_IB = 2;
const WAIT = 3;
const WAIT_FENCE = 4;
const NOTHING = 6;
const TRAP = 7;
/// A wait's condition: until the register, masked by the value, reads
/// what the reference register holds.
const UNTIL_EQUAL = 3;
/// How long a wait looks at its register, and how often.
const wait_timer: u32 = 0x01400200;

// --- the ring and what lies beside it ------------------------------------

/// The ring, then the indirect buffer, then the fence, in one piece of the
/// device's memory.
const ring_bytes: u32 = 4096;
const ring_words: u32 = ring_bytes / 4;
const ib_at: u32 = ring_bytes;
const ib_bytes: u32 = 4096;
const fence_at: u32 = ib_at + ib_bytes;
pub const piece_bytes: u32 = fence_at + 4096;
/// Every job is padded to sixteen words with commands that do nothing.
const job_words: u32 = 16;

/// The decoder's state, kept in jpeg.resource's base.
pub const State = extern struct {
    /// amdgpu.resource, and the decoder's registers in the machine; null
    /// and 0 until the first decode finds them.
    gpu: ?*AMDGPUBase = null,
    registers: usize = 0,
    /// The ring's piece, where the ring writes next, the last fence's
    /// number.
    ring: amdgpu.GPUMemory = .{},
    wptr: u32 = 0,
    sequence: u32 = 0,
    /// Started by the first decode, or would not start.
    awake: bool = false,
    dead: bool = false,
};

fn word(state: *const State, offset: u32) *volatile u32 {
    return reg(state.registers + offset * 4);
}

/// Every write to the device's memory done before the next store - the
/// write pointer's.
fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

/// The decoder found through amdgpu.resource: true with `state` holding
/// the resource and the registers. Reads only.
pub fn find(sys: *ExecBase, state: *State) bool {
    const gpu: *AMDGPUBase = @ptrCast(@alignCast(sys.OpenResource(amdgpu.AMDGPUNAME) orelse return false));
    var info: amdgpu.GPUInfo = .{};
    if (!gpu.GetGPUInfo(&info)) return false;
    var video: amdgpu.GPUBlock = .{};
    if (!gpu.FindGPUBlock(amdgpu.GPUBLOCK_VIDEO, 0, &video) or video.count <= segment) return false;
    if (video.major != video_known.major or video.minor != video_known.minor or video.revision != video_known.revision) {
        exec.kprintf(sys, "%s: the video block is %d.%d.%d, whose JPEG decoder this does not drive\n", .{
            owner, @as(u32, video.major), @as(u32, video.minor), @as(u32, video.revision),
        });
        return false;
    }
    state.gpu = gpu;
    state.registers = @as(usize, @intCast(info.registers)) + @as(usize, video.addresses[segment]) * 4;
    return true;
}

/// How often a register or the fence is looked at while waiting.
const look_us = 50;

/// Waits up to `most_us` for `offset` masked by `mask` to read `want`;
/// `waiter.wait(micros)` waits that long.
fn waitFor(state: *const State, offset: u32, mask: u32, want: u32, most_us: u32, waiter: anytype) bool {
    var waited: u32 = 0;
    while (word(state, offset).* & mask != want) {
        if (waited >= most_us) return false;
        waiter.wait(look_us);
        waited += look_us;
    }
    return true;
}

/// The ring's registers and what it last did, said - where a step went
/// wrong.
pub fn report(sys: *ExecBase, state: *const State, why: [*:0]const u8) void {
    exec.kprintf(sys, "%s: the AMD JPEG decoder %s: power %x %x, ring %x read %x written %x, fence %x of %x\n", .{
        owner,
        why,
        word(state, PGFSM_STATUS).*,
        word(state, JPEG_POWER_STATUS).*,
        word(state, JRBC_STATUS).*,
        word(state, JRBC_RB_RPTR).*,
        word(state, JRBC_RB_WPTR).*,
        if (state.ring.bytes != 0) reg(@intCast(state.ring.cpu + fence_at)).* else 0,
        state.sequence,
    });
}

/// The decoder started and checked, the first time a decode needs it:
/// true once the ring and an indirect buffer have both answered. The
/// caller holds the resource's lock; `waiter.wait(micros)` waits that
/// long.
pub fn wake(sys: *ExecBase, state: *State, waiter: anytype) bool {
    const gpu = state.gpu orelse return false;
    if (!gpu.SetGPUPower(amdgpu.GPUPOWER_JPEG, 0, true)) {
        exec.kprintf(sys, "%s: the power manager would not power the AMD JPEG decoder up\n", .{owner});
        return false;
    }

    // Its power island let go of; then the anti-hang mechanism off and
    // the island kept in its static mode.
    word(state, PGFSM_CONFIG).* = UVDJ_PWR_CONFIG_ON << UVDJ_PWR_SHIFT;
    if (!waitFor(state, PGFSM_STATUS, UVDJ_PWR_MASK, UVDJ_PWR_STATUS_ON << UVDJ_PWR_SHIFT, 100_000, waiter)) {
        exec.kprintf(sys, "%s: the AMD JPEG decoder's power island stays off (%x)\n", .{ owner, word(state, PGFSM_STATUS).* });
        return false;
    }
    word(state, JPEG_POWER_STATUS).* = word(state, JPEG_POWER_STATUS).* & ~POWER_STATUS_ANTI_HANG;
    word(state, JPEG_POWER_STATUS).* = word(state, JPEG_POWER_STATUS).* & ~POWER_STATUS_PG_MODE;

    // Clock gating off, its memory interface out of reset, the ring's
    // interrupt on. The tiling configuration a tiled picture would need is
    // left as it is: the picture is written in rows.
    word(state, JPEG_CGC_CTRL).* = (word(state, JPEG_CGC_CTRL).* | CGC_DYN_CLOCK_MODE | CGC_GATE_DLY_TIMER_1 | CGC_OFF_DELAY_4) & ~CGC_JPEG_DEC_MODE;
    word(state, JPEG_CGC_GATE).* = word(state, JPEG_CGC_GATE).* & ~CGC_GATES;
    word(state, JMI_CNTL).* = word(state, JMI_CNTL).* & ~JMI_SOFT_RESET;
    word(state, JPEG_SYS_INT_EN).* = word(state, JPEG_SYS_INT_EN).* | SYS_INT_DJRBC;

    // The ring, and the fence beside it cleared.
    if (state.ring.bytes == 0 and !gpu.AllocGPUMemory(piece_bytes, 4096, &state.ring)) {
        exec.kprintf(sys, "%s: no room for the AMD JPEG decoder's ring\n", .{owner});
        return false;
    }
    clear(state.ring.cpu, piece_bytes);
    word(state, LMI_JRBC_RB_VMID).* = 0;
    word(state, JRBC_RB_CNTL).* = RB_NO_FETCH | RB_RPTR_WR_EN;
    word(state, LMI_JRBC_RB_BAR_LOW).* = @truncate(state.ring.device);
    word(state, LMI_JRBC_RB_BAR_HIGH).* = @truncate(state.ring.device >> 32);
    word(state, JRBC_RB_RPTR).* = 0;
    word(state, JRBC_RB_WPTR).* = 0;
    word(state, JRBC_RB_CNTL).* = RB_RPTR_WR_EN;
    word(state, JRBC_RB_SIZE).* = ring_words;
    state.wptr = word(state, JRBC_RB_WPTR).*;
    exec.kprintf(sys, "%s: the AMD JPEG decoder's ring is at 0x%lx (0x%lx), doorbell %x\n", .{
        owner, state.ring.device, state.ring.cpu, word(state, VCN_JPEG_DB_CTRL).*,
    });

    // A register written by a command in the ring.
    word(state, JPEG_PITCH).* = 0xCAFEDEAD;
    _ = word(state, JPEG_PITCH).*;
    var ring: Writer = .{ .state = state };
    ring.put(command(I_JPEG_PITCH, 0, WRITE), 0xABADCAFE);
    ring.commit();
    if (!waitFor(state, JPEG_PITCH, 0xFFFFFFFF, 0xABADCAFE, 100_000, waiter)) {
        report(sys, state, "does not run its ring");
        return false;
    }

    // One written from an indirect buffer, with a fence after it.
    var ib: Buffer = .{ .at = state.ring.cpu + ib_at };
    ib.put(command(I_JPEG_PITCH, 0, WRITE), 0xDEADBEEF);
    ib.pad();
    if (!submit(state, ib.words) or !waitFence(state, 1_000_000, waiter)) {
        report(sys, state, "does not finish an indirect buffer");
        return false;
    }
    if (word(state, JPEG_PITCH).* != 0xDEADBEEF) {
        report(sys, state, "finishes an indirect buffer without running it");
        return false;
    }
    exec.kprintf(sys, "%s: the AMD JPEG decoder runs its ring and an indirect buffer\n", .{owner});
    return true;
}

/// `bytes` of the device's memory at `cpu` set to zero, eight at a time.
fn clear(cpu: u64, bytes: u32) void {
    var at: u64 = 0;
    while (at < bytes) : (at += 8) {
        const to: *volatile u64 = @ptrFromInt(@as(usize, @intCast(cpu + at)));
        to.* = 0;
    }
}

/// Bytes into the device's memory at `cpu`, eight at a time: `from`'s
/// length is a multiple of eight.
pub fn toDevice(cpu: u64, from: []const u8) void {
    var at: usize = 0;
    while (at < from.len) : (at += 8) {
        const to: *volatile u64 = @ptrFromInt(@as(usize, @intCast(cpu)) + at);
        to.* = @as(*align(1) const u64, @ptrCast(from.ptr + at)).*;
    }
}

/// `bytes` out of the device's memory at `cpu` by streaming loads, which
/// read write-combining memory a whole line at a time where plain loads
/// fetch each word on its own (60 times faster on a Radeon 780M's): a
/// multiple of 64, from a line's start. A fence first, so that nothing
/// written before is still on its way.
pub fn streamFromDevice(to: [*]u8, cpu: u64, bytes: usize) void {
    fence();
    var at: usize = 0;
    while (at < bytes) : (at += 64) {
        asm volatile (
            \\movntdqa (%[from]), %%xmm0
            \\movntdqa 16(%[from]), %%xmm1
            \\movntdqa 32(%[from]), %%xmm2
            \\movntdqa 48(%[from]), %%xmm3
            \\movdqu %%xmm0, (%[to])
            \\movdqu %%xmm1, 16(%[to])
            \\movdqu %%xmm2, 32(%[to])
            \\movdqu %%xmm3, 48(%[to])
            :
            : [from] "r" (@as(usize, @intCast(cpu)) + at),
              [to] "r" (to + at),
            : .{ .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .memory = true });
    }
}

/// Commands written into the ring, from where it was left.
const Writer = struct {
    state: *State,
    written: u32 = 0,

    fn one(w: *Writer, value: u32) void {
        const at = (w.state.wptr + w.written) % ring_words;
        reg(@as(usize, @intCast(w.state.ring.cpu)) + at * 4).* = value;
        w.written += 1;
    }

    fn put(w: *Writer, first: u32, value: u32) void {
        w.one(first);
        w.one(value);
    }

    /// Padded to whole jobs with commands that do nothing, and given to
    /// the decoder.
    fn commit(w: *Writer) void {
        while (w.written % job_words != 0) w.put(command(0, 0, NOTHING), 0);
        w.state.wptr = (w.state.wptr + w.written) % ring_words;
        w.written = 0;
        fence();
        word(w.state, JRBC_RB_WPTR).* = w.state.wptr;
    }
};

/// Commands written into the indirect buffer.
const Buffer = struct {
    at: u64,
    words: u32 = 0,

    fn put(b: *Buffer, first: u32, value: u32) void {
        const to = @as(usize, @intCast(b.at)) + b.words * 4;
        reg(to).* = first;
        reg(to + 4).* = value;
        b.words += 2;
    }

    fn pad(b: *Buffer) void {
        while (b.words % job_words != 0) b.put(command(0, 0, NOTHING), 0);
    }
};

/// The indirect buffer of `words` run from the ring, and a fence written
/// after it: the ring's commands around an indirect buffer, for a buffer
/// read with no page table.
fn submit(state: *State, words: u32) bool {
    if (words == 0 or words > ib_bytes / 4) return false;
    const ib = state.ring.device + ib_at;
    const fence_device = state.ring.device + fence_at;
    state.sequence +%= 1;
    var ring: Writer = .{ .state = state };
    // The job's start.
    ring.put(command(I_EXTERNAL_REG, 0, WRITE), 0x68e04);
    ring.put(command(I_EXTERNAL_REG_WRITE, 0, WRITE), 0x80010000);
    // The indirect buffer, and the wait for it to be done.
    ring.put(command(I_JPEG_IH_CTRL, 0, WRITE), 0);
    ring.put(command(I_LMI_JRBC_IB_VMID, 0, WRITE), 0);
    ring.put(command(I_LMI_JPEG_VMID, 0, WRITE), 0);
    ring.put(command(I_LMI_IB_BAR_LOW, 0, WRITE), @truncate(ib));
    ring.put(command(I_LMI_IB_BAR_HIGH, 0, WRITE), @truncate(ib >> 32));
    ring.put(command(I_JRBC_IB_SIZE, 0, WRITE), words);
    ring.put(command(I_LMI_RB_MEM_RD_BAR_LOW, 0, WRITE), @truncate(state.ring.device));
    ring.put(command(I_LMI_RB_MEM_RD_BAR_HIGH, 0, WRITE), @truncate(state.ring.device >> 32));
    ring.put(command(0, 0, RUN_IB), 0);
    ring.put(command(I_JRBC_RB_COND_RD_TIMER, 0, WRITE), wait_timer);
    ring.put(command(I_JRBC_RB_REF_DATA, 0, WRITE), 0x2);
    ring.put(command(I_JRBC_STATUS, UNTIL_EQUAL, WAIT), 0x2);
    // The fence: its number written to memory, then the trap.
    ring.put(command(I_GPCOM_DATA0, 0, WRITE), state.sequence);
    ring.put(command(I_GPCOM_DATA1, 0, WRITE), state.sequence);
    ring.put(command(I_LMI_RB_MEM_WR_BAR_LOW, 0, WRITE), @truncate(fence_device));
    ring.put(command(I_LMI_RB_MEM_WR_BAR_HIGH, 0, WRITE), @truncate(fence_device >> 32));
    ring.put(command(I_GPCOM_CMD, 0, WRITE), 0x8);
    ring.put(command(I_GPCOM_CMD, 0, WAIT_FENCE), 0);
    ring.put(command(I_EXTERNAL_REG, 0, WRITE), 0x3fbc);
    ring.put(command(I_EXTERNAL_REG_WRITE, 0, WRITE), 0x1);
    ring.put(command(0, 0, TRAP), 0);
    // The job's end.
    ring.put(command(I_EXTERNAL_REG, 0, WRITE), 0x68e04);
    ring.put(command(I_EXTERNAL_REG_WRITE, 0, WRITE), 0x00010000);
    ring.commit();
    return true;
}

/// Waits up to `most_us` for the last fence's number to be written;
/// `waiter.wait(micros)` waits that long.
pub fn waitFence(state: *const State, most_us: u64, waiter: anytype) bool {
    const at: usize = @intCast(state.ring.cpu + fence_at);
    var waited: u64 = 0;
    while (reg(at).* != state.sequence) {
        if (waited >= most_us) return false;
        waiter.wait(look_us);
        waited += look_us;
    }
    return true;
}

// --- a picture ---------------------------------------------------------------

/// The segments the decoder reads itself: the frame, the code tables,
/// the quantization tables, the restart interval.
fn kept(code: u8) bool {
    return code == 0xC0 or code == 0xC4 or code == 0xDB or code == 0xDD;
}

/// The file as the decoder is given it, into `out`: its start, the
/// segments it reads before the scan, and everything from the scan on;
/// the length written, or null where the segments do not lie the way the
/// header read them. `out` holds at least the file's length.
pub fn stream(file: []const u8, h: *const Header, out: []u8) ?usize {
    if (h.scan > file.len or out.len < file.len) return null;
    out[0] = 0xFF;
    out[1] = 0xD8;
    var length: usize = 2;
    var at: usize = 2;
    while (at < h.scan) {
        if (file[at] != 0xFF) return null;
        while (at + 1 < h.scan and file[at + 1] == 0xFF) at += 1;
        if (at + 4 > h.scan) return null;
        const code = file[at + 1];
        const body = @as(usize, file[at + 2]) << 8 | file[at + 3];
        const end = at + 2 + body;
        if (body < 2 or end > h.scan) return null;
        if (kept(code)) {
            @memcpy(out[length .. length + (end - at)], file[at..end]);
            length += end - at;
        }
        at = end;
    }
    const rest = file.len - h.scan;
    @memcpy(out[length .. length + rest], file[h.scan..]);
    return length + rest;
}

/// Where a picture's samples go, in its piece of the device's memory:
/// the brightness's pitch, the differences', where each plane starts,
/// and how many bytes all of them take.
pub const Layout = struct {
    pitch: u32,
    uv_pitch: u32,
    /// The first difference plane, the second (three planes only); 0 for
    /// none.
    chroma: u32,
    chromav: u32,
    /// The value the decoder is given for the brightness's pitch, which
    /// for interleaved samples counts pixels rather than bytes.
    pitch_told: u32,
    bytes: u32,
};

/// A row is a multiple of 256 bytes, a plane starts on a page.
const row_step: u32 = 256;
const plane_step: u32 = 4096;

fn up(n: u32, step: u32) u32 {
    return (n + step - 1) / step * step;
}

/// The layout of a picture with `h`'s sampling, at its size in whole
/// blocks; null where the decoder does not take the sampling.
pub fn layoutOf(h: *const Header) ?Layout {
    const rows = h.padded_height;
    switch (h.sampling) {
        types.JPEGSAMP_GREY => {
            const pitch = up(h.padded_width, row_step);
            return .{ .pitch = pitch, .uv_pitch = 0, .chroma = 0, .chromav = 0, .pitch_told = pitch, .bytes = up(pitch * rows, plane_step) };
        },
        types.JPEGSAMP_420 => {
            const pitch = up(h.padded_width, row_step);
            const chroma = up(pitch * rows, plane_step);
            return .{ .pitch = pitch, .uv_pitch = pitch, .chroma = chroma, .chromav = 0, .pitch_told = pitch, .bytes = chroma + up(pitch * (rows / 2), plane_step) };
        },
        types.JPEGSAMP_444 => {
            const pitch = up(h.padded_width, row_step);
            const plane = up(pitch * rows, plane_step);
            return .{ .pitch = pitch, .uv_pitch = pitch, .chroma = plane, .chromav = 2 * plane, .pitch_told = pitch, .bytes = 3 * plane };
        },
        types.JPEGSAMP_422 => {
            const pitch = up(h.padded_width * 2, row_step);
            return .{ .pitch = pitch, .uv_pitch = 0, .chroma = 0, .chromav = 0, .pitch_told = pitch / 2, .bytes = up(pitch * rows, plane_step) };
        },
        else => return null,
    }
}

/// The smallest picture the decoder takes either way.
pub const side_least: u32 = 64;

/// The picture's indirect buffer written and run: the file's copy of
/// `stream_bytes` (a multiple of 128) at `stream_device`, the samples to
/// `target_device` laid out as `layout`. The caller holds the resource's
/// lock and waits for the fence.
pub fn decode(state: *State, stream_device: u64, stream_bytes: u32, target_device: u64, layout: Layout) bool {
    var ib: Buffer = .{ .at = state.ring.cpu + ib_at };
    // The decoder reset, and waited for as it goes in and comes out.
    ib.put(command(I_DEC_SOFT_RST, 0, WRITE), 1);
    ib.put(command(I_JRBC_IB_COND_RD_TIMER, 0, WRITE), wait_timer);
    ib.put(command(I_JRBC_IB_REF_DATA, 0, WRITE), 1 << 16);
    ib.put(command(I_DEC_SOFT_RST, UNTIL_EQUAL, WAIT), 1 << 16);
    ib.put(command(I_DEC_SOFT_RST, 0, WRITE), 0);
    ib.put(command(I_JRBC_IB_REF_DATA, 0, WRITE), 0);
    ib.put(command(I_DEC_SOFT_RST, UNTIL_EQUAL, WAIT), 1 << 16);
    // The file.
    ib.put(command(I_LMI_READ_BAR_HIGH, 0, WRITE), @truncate(stream_device >> 32));
    ib.put(command(I_LMI_READ_BAR_LOW, 0, WRITE), @truncate(stream_device));
    ib.put(command(I_JPEG_RB_BASE, 0, WRITE), 0);
    ib.put(command(I_JPEG_RB_SIZE, 0, WRITE), 0xFFFFFFF0);
    ib.put(command(I_JPEG_RB_WPTR, 0, WRITE), stream_bytes >> 2);
    // The picture: its pitches in sixteens, in rows, and its planes.
    ib.put(command(I_JPEG_PITCH, 0, WRITE), layout.pitch_told >> 4);
    ib.put(command(I_JPEG_UV_PITCH, 0, WRITE), layout.uv_pitch >> 4);
    ib.put(command(I_DEC_ADDR_MODE, 0, WRITE), 0);
    ib.put(command(I_DEC_Y_TILING, 0, WRITE), 0);
    ib.put(command(I_DEC_UV_TILING, 0, WRITE), 0);
    ib.put(command(I_LMI_WRITE_BAR_HIGH, 0, WRITE), @truncate(target_device >> 32));
    ib.put(command(I_LMI_WRITE_BAR_LOW, 0, WRITE), @truncate(target_device));
    ib.put(command(I_JPEG_INDEX, 0, WRITE), 0);
    ib.put(command(I_JPEG_DATA, 0, WRITE), 0);
    ib.put(command(I_JPEG_INDEX, 0, WRITE), 1);
    ib.put(command(I_JPEG_DATA, 0, WRITE), layout.chroma);
    if (layout.chromav != 0) {
        ib.put(command(I_JPEG_INDEX, 0, WRITE), 2);
        ib.put(command(I_JPEG_DATA, 0, WRITE), layout.chromav);
    }
    ib.put(command(I_JPEG_TIER_CNTL2, 0, WRITE), 0);
    ib.put(command(I_JPEG_OUTBUF_RPTR, 0, WRITE), 0);
    ib.put(command(I_JPEG_OUTBUF_CNTL, 0, WRITE), (0x00001587 & ~@as(u32, 0x180)) | 0x80 | 0x40);
    ib.put(command(I_JPEG_INT_EN, 0, WRITE), 0xFFFFFFFE);
    // Started; waited for until the whole file is read and the picture
    // written out; stopped.
    ib.put(command(I_JPEG_CNTL, 0, WRITE), 0x6);
    ib.put(command(I_JRBC_IB_REF_DATA, 0, WRITE), stream_bytes >> 2);
    ib.put(command(I_JRBC_IB_COND_RD_TIMER, 0, WRITE), wait_timer);
    ib.put(command(I_JPEG_RB_RPTR, UNTIL_EQUAL, WAIT), 0xFFFFFFFF);
    ib.put(command(I_JRBC_IB_REF_DATA, 0, WRITE), 0xFFFFFFFF);
    ib.put(command(I_JPEG_OUTBUF_WPTR, UNTIL_EQUAL, WAIT), 0x1);
    ib.put(command(I_JPEG_CNTL, 0, WRITE), 0x4);
    ib.pad();
    return submit(state, ib.words);
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the decoder's copy of a file keeps its tables, frame and scan, and nothing else" {
    // SOI, an APP0, a DQT, a COM, a SOF0 with fill bytes before it, then
    // the scan and the end.
    const file = [_]u8{
        0xFF, 0xD8,
        0xFF, 0xE0, 0x00, 0x04, 'J',  'F',
        0xFF, 0xDB, 0x00, 0x03, 0x01,
        0xFF, 0xFE, 0x00, 0x03, '!',
        0xFF, 0xFF, 0xC0, 0x00, 0x03, 0x08,
        0xFF, 0xDA, 0x00, 0x02, 0x12, 0x34,
        0xFF, 0xD9,
    };
    var h: Header = .{};
    h.scan = 24;
    var out: [file.len]u8 = undefined;
    const length = stream(&file, &h, &out).?;
    try testing.expectEqualSlices(u8, &.{
        0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x03, 0x01, 0xFF, 0xC0, 0x00, 0x03, 0x08,
        0xFF, 0xDA, 0x00, 0x02, 0x12, 0x34, 0xFF, 0xD9,
    }, out[0..length]);

    // A segment that runs past the scan is refused.
    h.scan = 10;
    try testing.expect(stream(&file, &h, &out) == null);
}

test "each sampling's planes: rows of 256 bytes, planes on pages" {
    var h: Header = .{ .padded_width = 128, .padded_height = 80 };
    h.sampling = types.JPEGSAMP_420;
    const nv12 = layoutOf(&h).?;
    try testing.expectEqual(@as(u32, 256), nv12.pitch);
    try testing.expectEqual(@as(u32, 20480), nv12.chroma);
    try testing.expectEqual(@as(u32, 20480 + 12288), nv12.bytes);
    h.sampling = types.JPEGSAMP_444;
    const planes = layoutOf(&h).?;
    try testing.expectEqual(@as(u32, 2 * 20480), planes.chromav);
    h.sampling = types.JPEGSAMP_422;
    const pairs = layoutOf(&h).?;
    try testing.expectEqual(@as(u32, 256), pairs.pitch);
    try testing.expectEqual(@as(u32, 128), pairs.pitch_told);
    try testing.expectEqual(@as(u32, 0), pairs.chroma);
    h.sampling = types.JPEGSAMP_GREY;
    try testing.expectEqual(@as(u32, 0), layoutOf(&h).?.chroma);
}

test "a command's first word" {
    try testing.expectEqual(@as(u32, 0x0000401f), command(I_JPEG_PITCH, 0, WRITE));
    try testing.expectEqual(@as(u32, 0x3300402f), command(I_DEC_SOFT_RST, UNTIL_EQUAL, WAIT));
    try testing.expectEqual(@as(u32, 0x60000000), command(0, 0, NOTHING));
}
