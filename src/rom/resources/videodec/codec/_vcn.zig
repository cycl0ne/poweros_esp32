// SPDX-License-Identifier: MPL-2.0
//! An AMD graphics device's video decoder: the video block's processor,
//! which runs firmware the security processor checked and loaded, reads
//! a ring of commands in the device's own memory and decodes what the
//! messages it is handed describe. amdgpu.resource finds it, powers it,
//! loads its firmware and hands out the memory; this drives the one of
//! video block 4.0.2.
//!
//! **Starting it** (`wake`): powered up by the power manager, the
//! decoder's guard against hung register reads is switched off and its
//! power gating left to the firmware, which gates the decoding tiles as
//! it works. Every other write of its start goes into a list, which the
//! security processor applies (`startWrites`): its processor's clock on
//! and the processor held in reset, its interrupt off, its memory
//! interface set to keep its writes in order, its four windows - onto
//! the firmware and onto a stack, both given no address here since the
//! security processor places them in the protected region, onto a
//! context of the firmware's own, and onto the block it shares with the
//! driver, read uncached - then the reset let go of and the interrupt
//! on. The firmware boots from that. A write in the list names its
//! register as the decoder itself numbers it (`inside`). Then its ring:
//! placed, cleared and switched on, with the shared block saying the
//! ring was reset while that happens. A ring that runs a command is the
//! proof it started.
//!
//! **The ring** is the decoder's unified queue: one ring for decoding
//! and encoding, a command a few words - an indirect buffer to run, a
//! fence to write, the end of a submission - and every submission padded
//! to 64 words, the size the decoder fetches. Its write pointer is a
//! register, counted in words; the doorbell the device can also be
//! told through is left as the firmware set it.
//!
//! **A message** is a page the decoder reads: a header that says what it
//! is - a stream made, a picture decoded, a stream ended - and an index
//! of the parts after it. It is handed over by an indirect buffer that
//! names the engine (decoding) and, in one structure, the addresses of
//! the message and of what goes with it: the stream's own context, for
//! every message of that stream.
//!
//! The commands and messages are the ones Linux's amdgpu driver puts on
//! the ring and Mesa's radeonsi puts into the indirect buffer, with the
//! decoder's addresses as the device's memory has them: the memory hub
//! as the firmware leaves it takes them as physical, so no page table is
//! needed.
//!
//! The graphics engine's address configuration, which the decoder is
//! told for tiled surfaces, is the one the decoder's own register holds
//! as the firmware left it: the graphics engine is not started, and the
//! list writes the value back.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const types = sdk.resources.videodec;
const vp = sdk.videoparse;
const reg = sdk.hardware.mmio.reg;
const systimer = sdk.hardware.systimer;
const ExecBase = sdk.interface.exec.ExecBase;
const AMDGPUBase = sdk.interface.amdgpu.AMDGPUBase;

const owner = types.VIDEODECNAME;

/// The video block this drives, and the segment of its registers the
/// decoder's are in.
const video_known = .{ .major = 4, .minor = 0, .revision = 2 };
const segment = 1;

// --- the decoder's registers: 32-bit words from the video block's second
// address ------------------------------------------------------------------

const PGFSM_STATUS = 0x001;
const POWER_STATUS = 0x002;
const GFX10_ADDR_CONFIG = 0x042;
const RB1_DB_CTRL = 0x072;
const RB_ENABLE = 0x085;
const RB_RPTR = 0x0ac;
const RB_WPTR = 0x0ad;
const MASTINT_EN = 0x0e1;
const RB_BASE_LO = 0x0ea;
const RB_BASE_HI = 0x0eb;
const RB_SIZE = 0x0ec;
const STATUS = 0x143;
const CACHE_OFFSET0 = 0x180;
const CACHE_SIZE0 = 0x181;
const CACHE_OFFSET1 = 0x182;
const CACHE_SIZE1 = 0x183;
const CACHE_OFFSET2 = 0x184;
const CACHE_SIZE2 = 0x185;
const NONCACHE_OFFSET0 = 0x192;
const NONCACHE_SIZE0 = 0x193;
const VCPU_CNTL = 0x196;
const MPC_CNTL = 0x1d4;
const MPC_SET_MUXA0 = 0x1d6;
const MPC_SET_MUXB0 = 0x1d8;
const MPC_SET_MUX = 0x1da;
const NC0_BAR_LOW = 0x240;
const NC0_BAR_HIGH = 0x241;
const CACHE_BAR_LOW = 0x244;
const CACHE_BAR_HIGH = 0x245;
const CACHE1_BAR_LOW = 0x270;
const CACHE1_BAR_HIGH = 0x271;
const CACHE2_BAR_LOW = 0x274;
const CACHE2_BAR_HIGH = 0x275;
const LMI_CTRL2 = 0x2ae;
const LMI_CTRL = 0x2b0;

/// Its power status: the status field, 1 to switch the guard against
/// hung register reads off; then power gating on and left to the
/// firmware.
const POWER_STATUS_FIELD: u32 = 0x3;
const POWER_STATUS_GUARD_OFF: u32 = 1;
const POWER_STATUS_DYNAMIC: u32 = (1 << 2) | (1 << 8);

const VCPU_CLK_EN: u32 = 1 << 9;
const VCPU_BLK_RST: u32 = 1 << 28;
/// How long the processor waits on a read of its registers, at most.
const VCPU_TIMEOUT: u32 = 0xFF << 20;
const MASTINT_VCPU_EN: u32 = 1 << 1;
/// The memory interface: its write-clean timer on at 8, requests kept in
/// order, its checksum reset, the memory controller's urgent requests
/// masked, its data and the processor's kept coherent, and the decoder
/// stopped where the firmware fails its check.
const LMI_CTRL_START: u32 = 8 | (1 << 8) | (1 << 9) | (1 << 12) | (1 << 13) | (1 << 14) | (1 << 20) | (1 << 21);
/// Its memory channels on: the most write requests in flight.
const LMI_CTRL2_START: u32 = 0x1f << 17;
const MPC_REPLACEMENT_2: u32 = 2 << 3;
const MPC_MUX_AB: u32 = (1 << 6) | (2 << 12) | (3 << 18) | (4 << 24);
const MPC_MUX: u32 = (1 << 3) | (2 << 6);
const RB_ENABLE_RB1: u32 = 1 << 2;

/// How the decoder itself numbers its registers: by the machine's byte
/// address within the block's megabyte, its video part counted from
/// 0x1fb00, its always-on part from 0x1f800 and placed at 0x30000.
const video_soc: u32 = 0x1fb00;
const video_span: u32 = 0x2600;
const aon_soc: u32 = 0x1f800;
const aon_span: u32 = 0x600;
const aon_inside: u32 = 0x30000;

/// The firmware's own windows: its stack and its context.
const stack_bytes: u32 = 128 * 1024;
const context_bytes: u32 = 512 * 1024;
const shared_bytes: u32 = 4096;
/// The stack, the context and the shared block, in one piece.
pub const vcpu_bytes: u32 = stack_bytes + context_bytes + shared_bytes;
const shared_at: u32 = stack_bytes + context_bytes;

/// The shared block: which of its parts are there - the unified queue,
/// the power manager's interface and the key workaround the 4.0.2
/// firmware wants - the queue on and its mode, the interface the APU's,
/// and the workaround's method, the security processor's handshake.
const SHARED_PRESENT: u32 = (1 << 2) | (1 << 11) | (1 << 4);
const shared_present_at = 0;
const shared_queue_enabled_at = 16;
const shared_queue_mode_at = 17;
const shared_power_interface_at = 120;
const shared_key_method_at = 124;
const QUEUE_RING_RESET: u8 = 1;
const QUEUE_HOLD_OFF: u8 = 2;

// --- the ring and what lies beside it ------------------------------------

const ring_bytes: u32 = 4096;
const ring_words: u32 = ring_bytes / 4;
const fence_at: u32 = ring_bytes;
const ib_at: u32 = fence_at + 4096;
const message_at: u32 = ib_at + 4096;
/// The ring, the fence, the indirect buffer and the message, a page
/// each, in one piece.
pub const ring_piece_bytes: u32 = message_at + 4096;
/// The words a submission is padded to.
const fetch_words: u32 = 64;

const COMMAND_NOP: u32 = 0x0;
const COMMAND_END: u32 = 0x1;
const COMMAND_IB: u32 = 0x2;
const COMMAND_FENCE: u32 = 0x3;
const COMMAND_TRAP: u32 = 0x4;

/// A stream's own context, which the firmware keeps for it.
pub const session_bytes: u32 = 128 * 1024;

/// The decoder's state, kept in videodec.resource's base.
pub const State = extern struct {
    /// amdgpu.resource, and the decoder's registers in the machine; null
    /// and 0 where there is no such decoder.
    gpu: ?*AMDGPUBase = null,
    registers: usize = 0,
    /// The decoder's segment's address, in words, which the decoder's
    /// own numbers of its registers are worked out from.
    segment_base: u32 = 0,
    /// The video block's and the security processor's versions, which
    /// name their firmware's files.
    video: [3]u8 = .{ 0, 0, 0 },
    security: [3]u8 = .{ 0, 0, 0 },
    /// The firmware's own piece, the ring's, where the ring is written
    /// next and the last fence's number; the last stream's number.
    vcpu: amdgpu.GPUMemory = .{},
    ring: amdgpu.GPUMemory = .{},
    wptr: u32 = 0,
    sequence: u32 = 0,
    streams: u32 = 0,
};

fn word(state: *const State, offset: u32) *volatile u32 {
    return reg(state.registers + offset * 4);
}

fn at(cpu: u64, offset: u32) *volatile u32 {
    return reg(@as(usize, @intCast(cpu)) + offset);
}

/// Every write to the device's memory done before the next store - the
/// write pointer's.
fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

/// The decoder found through amdgpu.resource: true with `state` holding
/// the resource, the registers and the versions. Reads only.
pub fn find(sys: *ExecBase, state: *State) bool {
    const gpu: *AMDGPUBase = @ptrCast(@alignCast(sys.OpenResource(amdgpu.AMDGPUNAME) orelse return false));
    var info: amdgpu.GPUInfo = .{};
    if (!gpu.GetGPUInfo(&info)) return false;
    var video: amdgpu.GPUBlock = .{};
    if (!gpu.FindGPUBlock(amdgpu.GPUBLOCK_VIDEO, 0, &video) or video.count <= segment) return false;
    if (video.major != video_known.major or video.minor != video_known.minor or video.revision != video_known.revision) {
        exec.kprintf(sys, "%s: the video block is %d.%d.%d, whose decoder this does not drive\n", .{
            owner, @as(u32, video.major), @as(u32, video.minor), @as(u32, video.revision),
        });
        return false;
    }
    var security: amdgpu.GPUBlock = .{};
    if (!gpu.FindGPUBlock(amdgpu.GPUBLOCK_SECURITY, 0, &security)) return false;
    state.gpu = gpu;
    state.registers = @as(usize, @intCast(info.registers)) + @as(usize, video.addresses[segment]) * 4;
    state.segment_base = video.addresses[segment];
    state.video = .{ video.major, video.minor, video.revision };
    state.security = .{ security.major, security.minor, security.revision };
    return true;
}

/// A file's name in DEVS:firmware/amdgpu/: `prefix`, the version with a
/// line between its parts, `suffix` - into `into`, NUL-ended.
pub fn firmwareName(into: []u8, prefix: []const u8, version: [3]u8, suffix: []const u8) [*:0]const u8 {
    var name: Name = .{ .into = into };
    name.text("DEVS:firmware/amdgpu/");
    name.text(prefix);
    for (version, 0..) |part, n| {
        if (n != 0) name.text("_");
        name.number(part);
    }
    name.text(suffix);
    into[name.len] = 0;
    return @ptrCast(into.ptr);
}

const Name = struct {
    into: []u8,
    len: usize = 0,

    fn text(name: *Name, part: []const u8) void {
        for (part) |c| {
            if (name.len + 1 >= name.into.len) return;
            name.into[name.len] = c;
            name.len += 1;
        }
    }

    fn number(name: *Name, value: u8) void {
        var digits: [3]u8 = undefined;
        var count: usize = 0;
        var left = value;
        while (true) {
            digits[count] = '0' + left % 10;
            count += 1;
            left /= 10;
            if (left == 0) break;
        }
        while (count > 0) {
            count -= 1;
            name.text(digits[count .. count + 1]);
        }
    }
};

/// A wait of so many microseconds, at the least.
fn pause(sys: *ExecBase, us: u32) void {
    var never: exec.Waitable = .{};
    const list = [_]*exec.Waitable{&never};
    _ = sys.WaitForAny(&list, 1, us);
}

/// The decoder's registers and what it last did, said - where a step
/// went wrong.
pub fn report(sys: *ExecBase, state: *const State, why: [*:0]const u8) void {
    exec.kprintf(sys, "%s: the AMD video decoder %s: island %x, power %x, status %x, ring read %x written %x, fence %x of %x\n", .{
        owner,
        why,
        word(state, PGFSM_STATUS).*,
        word(state, POWER_STATUS).*,
        word(state, STATUS).*,
        word(state, RB_RPTR).*,
        word(state, RB_WPTR).*,
        if (state.ring.bytes != 0) at(state.ring.cpu, fence_at).* else 0,
        state.sequence,
    });
}

/// `bytes` of the device's memory at `cpu` set to zero, eight at a time.
pub fn clear(cpu: u64, bytes: u32) void {
    var offset: u32 = 0;
    while (offset < bytes) : (offset += 8) {
        const to: *volatile u64 = @ptrFromInt(@as(usize, @intCast(cpu)) + offset);
        to.* = 0;
    }
}

fn sharedByte(state: *const State, offset: u32) *volatile u8 {
    return @ptrFromInt(@as(usize, @intCast(state.vcpu.cpu)) + shared_at + offset);
}

/// Register `offset` of the decoder's segment at `segment_base` (in
/// words) as the decoder itself numbers it, for a list the security
/// processor applies.
pub fn inside(segment_base: u32, offset: u32) u32 {
    const address = ((segment_base + offset) * 4) & 0xFFFFF;
    if (address >= video_soc and address < video_soc + video_span) return (address - video_soc) >> 2;
    if (address >= aon_soc and address < aon_soc + aon_span) return (address - aon_soc + aon_inside) >> 2;
    return address >> 2;
}

/// The room a start's list has, in writes.
const most_writes = 32;

/// A list of register writes for the security processor to apply: pairs
/// of words, a register as the decoder numbers it and its value.
pub const Writes = struct {
    /// The decoder's segment's address, in words.
    segment_base: u32,
    words: [most_writes * 2]u32 = undefined,
    /// Words written so far.
    count: u32 = 0,

    pub fn add(writes: *Writes, offset: u32, value: u32) void {
        if (writes.count == writes.words.len) return;
        writes.words[writes.count] = inside(writes.segment_base, offset);
        writes.words[writes.count + 1] = value;
        writes.count += 2;
    }

    pub fn bytes(writes: *const Writes) []const u8 {
        const all: [*]const u8 = @ptrCast(&writes.words);
        return all[0 .. writes.count * 4];
    }
};

/// The start's writes, in their order: the processor's clock on and it
/// held in reset, its interrupt off, its memory interface set, its
/// windows, then the reset let go of, the memory channels on and the
/// interrupt on. The windows onto the firmware and onto its stack get no
/// address - the security processor places both in the protected region
/// - and the firmware's no size; `vcpu` is the piece the context and the
/// shared block are in, `tiling` the graphics engine's address
/// configuration.
pub fn startWrites(writes: *Writes, vcpu: u64, tiling: u32) void {
    writes.add(VCPU_CNTL, VCPU_TIMEOUT | VCPU_CLK_EN | VCPU_BLK_RST);
    writes.add(MASTINT_EN, 0);
    writes.add(LMI_CTRL, LMI_CTRL_START);
    writes.add(MPC_CNTL, MPC_REPLACEMENT_2);
    writes.add(MPC_SET_MUXA0, MPC_MUX_AB);
    writes.add(MPC_SET_MUXB0, MPC_MUX_AB);
    writes.add(MPC_SET_MUX, MPC_MUX);
    // The firmware's window and its stack's.
    writes.add(CACHE_BAR_LOW, 0);
    writes.add(CACHE_BAR_HIGH, 0);
    writes.add(CACHE_OFFSET0, 0);
    writes.add(CACHE_SIZE0, 0);
    writes.add(CACHE1_BAR_LOW, 0);
    writes.add(CACHE1_BAR_HIGH, 0);
    writes.add(CACHE_OFFSET1, 0);
    writes.add(CACHE_SIZE1, stack_bytes);
    // Its context, and the block it shares with the driver.
    const context = vcpu + stack_bytes;
    writes.add(CACHE2_BAR_LOW, @truncate(context));
    writes.add(CACHE2_BAR_HIGH, @truncate(context >> 32));
    writes.add(CACHE_OFFSET2, 0);
    writes.add(CACHE_SIZE2, context_bytes);
    const shared = vcpu + shared_at;
    writes.add(NC0_BAR_LOW, @truncate(shared));
    writes.add(NC0_BAR_HIGH, @truncate(shared >> 32));
    writes.add(NONCACHE_OFFSET0, 0);
    writes.add(NONCACHE_SIZE0, shared_bytes);
    writes.add(GFX10_ADDR_CONFIG, tiling);
    writes.add(VCPU_CNTL, VCPU_TIMEOUT | VCPU_CLK_EN);
    writes.add(LMI_CTRL2, LMI_CTRL2_START);
    writes.add(MASTINT_EN, MASTINT_VCPU_EN);
}

/// A window's address, from its two registers.
fn window(state: *const State, low: u32) u64 {
    return @as(u64, word(state, low + 1).*) << 32 | word(state, low).*;
}

/// How long the first command is waited for, while the firmware boots.
const first_read_us: u64 = 1_000_000;
const read_us: u64 = 100_000;

/// The decoder started, its ring running: true once a command on the
/// ring was read. `firmware` is where the security processor put the
/// firmware, said on the system's lines. The caller holds the resource's
/// lock and has the firmware loaded.
pub fn wake(sys: *ExecBase, state: *State, firmware: u64) bool {
    const gpu = state.gpu orelse return false;
    if (!gpu.SetGPUPower(amdgpu.GPUPOWER_VIDEO, 0, true)) {
        exec.kprintf(sys, "%s: the power manager would not power the AMD video decoder up\n", .{owner});
        return false;
    }
    if (state.vcpu.bytes == 0 and !gpu.AllocGPUMemory(vcpu_bytes, 4096, &state.vcpu)) {
        exec.kprintf(sys, "%s: no room for the AMD video decoder's stack and context\n", .{owner});
        return false;
    }
    if (state.ring.bytes == 0 and !gpu.AllocGPUMemory(ring_piece_bytes, 4096, &state.ring)) {
        exec.kprintf(sys, "%s: no room for the AMD video decoder's ring\n", .{owner});
        return false;
    }
    clear(state.vcpu.cpu, vcpu_bytes);
    clear(state.ring.cpu, ring_piece_bytes);
    at(state.vcpu.cpu, shared_at + shared_present_at).* = SHARED_PRESENT;
    sharedByte(state, shared_queue_enabled_at).* = 1;
    sharedByte(state, shared_power_interface_at).* = 1;
    sharedByte(state, shared_key_method_at).* = 2;
    fence();
    const tiling = word(state, GFX10_ADDR_CONFIG).*;
    exec.kprintf(sys, "%s: the AMD video decoder, its firmware at 0x%lx: island %x, power %x, status %x, doorbell %x, tiling %x\n", .{
        owner,
        firmware,
        word(state, PGFSM_STATUS).*,
        word(state, POWER_STATUS).*,
        word(state, STATUS).*,
        word(state, RB1_DB_CTRL).*,
        tiling,
    });

    // The guard off, and the power gating the firmware's.
    word(state, POWER_STATUS).* = (word(state, POWER_STATUS).* & ~POWER_STATUS_FIELD) | POWER_STATUS_GUARD_OFF;
    word(state, POWER_STATUS).* = word(state, POWER_STATUS).* | POWER_STATUS_DYNAMIC;

    // The rest of the start, applied by the security processor.
    var writes: Writes = .{ .segment_base = state.segment_base };
    startWrites(&writes, state.vcpu.device, tiling);
    const list = writes.bytes();
    var answered: u64 = 0;
    if (!gpu.LoadGPUFirmware(amdgpu.GPUFIRMWARE_VIDEO_REGISTERS, list.ptr, @intCast(list.len), &answered)) {
        report(sys, state, "is not started: the security processor did not apply its writes");
        return false;
    }
    exec.kprintf(sys, "%s: the security processor applied the AMD video decoder's %d writes (answer 0x%lx): firmware window 0x%lx of %x, stack window 0x%lx, power %x, status %x\n", .{
        owner,
        writes.count / 2,
        answered,
        window(state, CACHE_BAR_LOW),
        word(state, CACHE_SIZE0).*,
        window(state, CACHE1_BAR_LOW),
        word(state, POWER_STATUS).*,
        word(state, STATUS).*,
    });

    // The ring: placed, cleared while the shared block says it is reset,
    // switched on.
    word(state, RB_BASE_LO).* = @truncate(state.ring.device);
    word(state, RB_BASE_HI).* = @truncate(state.ring.device >> 32);
    word(state, RB_SIZE).* = ring_words;
    word(state, RB_ENABLE).* = word(state, RB_ENABLE).* & ~RB_ENABLE_RB1;
    sharedByte(state, shared_queue_mode_at).* = sharedByte(state, shared_queue_mode_at).* | QUEUE_RING_RESET;
    fence();
    word(state, RB_RPTR).* = 0;
    word(state, RB_WPTR).* = 0;
    word(state, RB_WPTR).* = word(state, RB_RPTR).*;
    state.wptr = word(state, RB_WPTR).*;
    word(state, RB_ENABLE).* = word(state, RB_ENABLE).* | RB_ENABLE_RB1;
    sharedByte(state, shared_queue_mode_at).* = sharedByte(state, shared_queue_mode_at).* & ~(QUEUE_RING_RESET | QUEUE_HOLD_OFF);
    fence();
    exec.kprintf(sys, "%s: the AMD video decoder's ring is at 0x%lx, written from %x (status %x)\n", .{
        owner, state.ring.device, state.wptr, word(state, STATUS).*,
    });

    // A command read: the end of an empty submission.
    const before = word(state, RB_RPTR).*;
    put(state, COMMAND_END);
    commit(state);
    if (!changes(sys, state, before, first_read_us)) {
        report(sys, state, "does not read its ring");
        return false;
    }
    exec.kprintf(sys, "%s: the AMD video decoder reads its ring (read %x, status %x)\n", .{ owner, word(state, RB_RPTR).*, word(state, STATUS).* });
    return true;
}

/// Whether the read pointer moves off `from` within `most_us`.
fn changes(sys: *ExecBase, state: *const State, from: u32, most_us: u64) bool {
    const until = systimer.uptimeUs() + most_us;
    while (word(state, RB_RPTR).* == from) {
        if (systimer.uptimeUs() > until) return false;
        pause(sys, 1000);
    }
    return true;
}

fn put(state: *State, value: u32) void {
    at(state.ring.cpu, state.wptr * 4).* = value;
    state.wptr = (state.wptr + 1) % ring_words;
}

/// The submission padded to what the decoder fetches, and handed over.
fn commit(state: *State) void {
    while (state.wptr % fetch_words != 0) put(state, COMMAND_NOP);
    fence();
    word(state, RB_WPTR).* = state.wptr;
}

/// The indirect buffer of `words` in the ring's piece run, and a fence
/// written after it; its number is the state's last.
fn submit(state: *State, words: u32) void {
    const ib = state.ring.device + ib_at;
    const fence_device = state.ring.device + fence_at;
    state.sequence +%= 1;
    put(state, COMMAND_IB);
    put(state, 0);
    put(state, @truncate(ib));
    put(state, @truncate(ib >> 32));
    put(state, words);
    put(state, COMMAND_FENCE);
    put(state, @truncate(fence_device));
    put(state, @truncate(fence_device >> 32));
    put(state, state.sequence);
    put(state, COMMAND_TRAP);
    put(state, COMMAND_END);
    commit(state);
}

/// Waits up to `most_us` for the last fence's number to be written.
fn waitFence(sys: *ExecBase, state: *const State, most_us: u64) bool {
    const until = systimer.uptimeUs() + most_us;
    while (at(state.ring.cpu, fence_at).* != state.sequence) {
        if (systimer.uptimeUs() > until) return false;
        pause(sys, 1000);
    }
    return true;
}

// --- messages ----------------------------------------------------------------

/// The kinds of message, and of part a message holds.
const MESSAGE_CREATE: u32 = 0;
const MESSAGE_DESTROY: u32 = 2;
const PART_CREATE: u32 = 1;
const header_bytes: u32 = 40;
const index_bytes: u32 = 16;

/// The streams' kinds, as the decoder numbers them.
pub fn streamKind(codec: u32) u32 {
    return if (codec == types.VDCODEC_H265) 0x10 else 7;
}

/// A message making stream `stream` of `kind` (`streamKind`), as large as
/// `width` by `height` at most: its words written to `into`, how many
/// returned.
pub fn createMessage(into: []u32, stream: u32, kind: u32, width: u32, height: u32) u32 {
    const words = [_]u32{
        header_bytes, header_bytes + index_bytes, 1,  MESSAGE_CREATE, stream, 0,
        PART_CREATE,  header_bytes,               16, 0,              kind,   0,
        width,        height,
    };
    for (words, 0..) |value, n| into[n] = value;
    return words.len;
}

/// A message ending stream `stream`: the header alone, without an index.
pub fn destroyMessage(into: []u32, stream: u32) u32 {
    const words = [_]u32{ header_bytes, header_bytes - index_bytes, 0, MESSAGE_DESTROY, stream, 0 };
    for (words, 0..) |value, n| into[n] = value;
    return words.len;
}

/// What an indirect buffer for decoding names: the message, the stream's
/// context.
const BUFFER_MESSAGE: u32 = 1 << 0;
const BUFFER_SESSION: u32 = 1 << 20;
const ENGINE_INFO_SIZE: u32 = 0x10;
const ENGINE_INFO: u32 = 0x30000001;
const ENGINE_DECODE: u32 = 0x3;
const PARAM_DECODE_BUFFER: u32 = 0x1;
const decode_buffer_words: u32 = 33;
/// The words of such a buffer: the engine's four, the parameter's two,
/// the structure.
pub const ib_words: u32 = 4 + 2 + decode_buffer_words;

/// What an indirect buffer names: which buffers (`BUFFER_*`), and each
/// one's address, 0 for those it does not name.
pub const Buffers = struct {
    flags: u32,
    message: u64,
    session: u64,
    bitstream: u64 = 0,
    context: u64 = 0,
    target: u64 = 0,
    scaling: u64 = 0,
};

/// An indirect buffer handing over `buffers`: its words written to
/// `into`.
pub fn indirectBuffer(into: []u32, buffers: Buffers) u32 {
    for (into[0..ib_words]) |*value| value.* = 0;
    into[0] = ENGINE_INFO_SIZE;
    into[1] = ENGINE_INFO;
    into[2] = ENGINE_DECODE;
    into[3] = ib_words * 4;
    into[4] = decode_buffer_words * 4 + 8;
    into[5] = PARAM_DECODE_BUFFER;
    const buffer = into[6..][0..decode_buffer_words];
    buffer[0] = buffers.flags;
    const named = [_]struct { at: u32, address: u64 }{
        .{ .at = 1, .address = buffers.message },
        .{ .at = 5, .address = buffers.target },
        .{ .at = 7, .address = buffers.session },
        .{ .at = 9, .address = buffers.bitstream },
        .{ .at = 11, .address = buffers.context },
        .{ .at = 21, .address = buffers.scaling },
    };
    for (named) |one| {
        buffer[one.at] = @truncate(one.address >> 32);
        buffer[one.at + 1] = @truncate(one.address);
    }
    return ib_words;
}

/// An indirect buffer handing over the message at `message` with the
/// stream's context at `session`: its words written to `into`.
pub fn messageBuffer(into: []u32, message: u64, session: u64) u32 {
    return indirectBuffer(into, .{ .flags = BUFFER_MESSAGE | BUFFER_SESSION, .message = message, .session = session });
}

/// How long a message is waited for.
const message_most_us: u64 = 1_000_000;

/// The message of `words` in `message` handed to the decoder with the
/// stream's context at `session`, and its fence waited for: true once it
/// is written. The caller holds the resource's lock.
pub fn send(sys: *ExecBase, state: *State, message: []const u32, session: u64, what: [*:0]const u8) bool {
    clear(state.ring.cpu + message_at, 4096);
    for (message, 0..) |value, n| at(state.ring.cpu + message_at, @intCast(n * 4)).* = value;
    handOver(state, .{ .flags = BUFFER_MESSAGE | BUFFER_SESSION, .message = state.ring.device + message_at, .session = session });
    if (!waitFence(sys, state, message_most_us)) {
        report(sys, state, what);
        return false;
    }
    return true;
}

/// The indirect buffer naming `buffers` written and run, a fence after
/// it.
fn handOver(state: *State, buffers: Buffers) void {
    var ib: [ib_words]u32 = undefined;
    _ = indirectBuffer(&ib, buffers);
    for (ib, 0..) |value, n| at(state.ring.cpu + ib_at, @intCast(n * 4)).* = value;
    submit(state, ib_words);
}

// --- a picture decoded ---------------------------------------------------------

/// A decoding message, and the parts it holds: what the picture is, its
/// reference surfaces, the codec's part.
const MESSAGE_DECODE: u32 = 1;
const PART_DECODE: u32 = 2;
const PART_AVC: u32 = 6;
const PART_HEVC: u32 = 0xD;
const PART_DYNAMIC_DPB: u32 = 0x10;

/// What else an indirect buffer for decoding names: the picture's
/// slices, the surface it is written to, its scaling lists and the
/// decoder's context for the stream.
const BUFFER_BITSTREAM: u32 = 1 << 2;
const BUFFER_TARGET: u32 = 1 << 3;
const BUFFER_SCALING: u32 = 1 << 9;
const BUFFER_CONTEXT: u32 = 1 << 11;
pub const decode_buffers: u32 = BUFFER_MESSAGE | BUFFER_BITSTREAM | BUFFER_TARGET | BUFFER_SCALING |
    BUFFER_CONTEXT | BUFFER_SESSION;

/// The references are surfaces of their own, named by each message.
const DECODE_DYNAMIC_DPB: u32 = 1 << 0;
/// A reference surface's layout: blocks of 256 bytes - the one layout
/// the decoder keeps references in - read as the graphics engine of this
/// generation lays surfaces out.
const SWIZZLE_256B_D: u32 = 2;
const ARRAY_MODE_GFX11: u32 = 3;

/// The largest H.264 picture the decoder takes, across and down, and
/// the largest H.265 one.
pub const avc_most: u32 = 4096;
pub const hevc_most_width: u32 = 8192;
pub const hevc_most_height: u32 = 4352;
/// The firmware's numbers for the pictures it decodes and refers to:
/// 0 to 16, the most references and the picture decoded.
pub const most_ids: u32 = 17;

/// Where the scaling lists go in the message's page.
const scaling_at: u32 = 2048;

pub const MessageIndex = extern struct {
    id: u32 = 0,
    offset: u32 = 0,
    size: u32 = 0,
    filled: u32 = 0,
};

pub const MessageHeader = extern struct {
    header_size: u32 = header_bytes,
    total_size: u32 = 0,
    num_buffers: u32 = 0,
    msg_type: u32 = 0,
    stream_handle: u32 = 0,
    feedback_number: u32 = 0,
    index: MessageIndex = .{},
};

/// What a picture is: its stream's kind and size, how large each buffer
/// named is, and how its surfaces are laid out - the references' (`db_`)
/// and the one it is written to (`dt_`), pitches counted in elements.
pub const DecodePart = extern struct {
    stream_type: u32 = 0,
    decode_flags: u32 = 0,
    width_in_samples: u32 = 0,
    height_in_samples: u32 = 0,
    bsd_size: u32 = 0,
    dpb_size: u32 = 0,
    dt_size: u32 = 0,
    sct_size: u32 = 0,
    sc_coeff_size: u32 = 0,
    hw_ctxt_size: u32 = 0,
    sw_ctxt_size: u32 = 0,
    pic_param_size: u32 = 0,
    mb_cntl_size: u32 = 0,
    reserved0: [4]u32 = @splat(0),
    decode_buffer_flags: u32 = 0,
    db_pitch: u32 = 0,
    db_aligned_height: u32 = 0,
    db_tiling_mode: u32 = 0,
    db_swizzle_mode: u32 = 0,
    db_array_mode: u32 = 0,
    db_field_mode: u32 = 0,
    db_surf_tile_config: u32 = 0,
    dt_pitch: u32 = 0,
    dt_uv_pitch: u32 = 0,
    dt_tiling_mode: u32 = 0,
    dt_swizzle_mode: u32 = 0,
    dt_array_mode: u32 = 0,
    dt_field_mode: u32 = 0,
    dt_out_format: u32 = 0,
    dt_surf_tile_config: u32 = 0,
    dt_uv_surf_tile_config: u32 = 0,
    dt_luma_top_offset: u32 = 0,
    dt_luma_bottom_offset: u32 = 0,
    dt_chroma_top_offset: u32 = 0,
    dt_chroma_bottom_offset: u32 = 0,
    dt_chroma_v_top_offset: u32 = 0,
    dt_chroma_v_bottom_offset: u32 = 0,
    mif_wrc_en: u32 = 0,
    db_pitch_uv: u32 = 0,
    reserved1: [20]u8 = @splat(0),
};

/// The picture's reference surfaces: their layout, how many the codec's
/// part names, the surface the picture itself goes to, and each
/// reference's by its place in the codec's part - the brightness's
/// address; the colour follows it.
pub const DpbPart = extern struct {
    config_flags: u32 = 0,
    luma_pitch: u32 = 0,
    luma_aligned_height: u32 = 0,
    luma_aligned_size: u32 = 0,
    chroma_pitch: u32 = 0,
    chroma_aligned_height: u32 = 0,
    chroma_aligned_size: u32 = 0,
    array_size: u32 = 0,
    curr_lo: u32 = 0,
    curr_hi: u32 = 0,
    addr_lo: [16]u32 = @splat(0),
    addr_hi: [16]u32 = @splat(0),
};

/// An H.264 picture: its parameter sets' values, its own frame number
/// and order counts, and its references - each by its place, with the
/// firmware's number for it.
pub const AvcPart = extern struct {
    profile: u32 = 0,
    level: u32 = 0,
    sps_info_flags: u32 = 0,
    pps_info_flags: u32 = 0,
    chroma_format: u8 = 0,
    bit_depth_luma_minus8: u8 = 0,
    bit_depth_chroma_minus8: u8 = 0,
    log2_max_frame_num_minus4: u8 = 0,
    pic_order_cnt_type: u8 = 0,
    log2_max_pic_order_cnt_lsb_minus4: u8 = 0,
    num_ref_frames: u8 = 0,
    reserved_8bit: u8 = 0,
    pic_init_qp_minus26: i8 = 0,
    pic_init_qs_minus26: i8 = 0,
    chroma_qp_index_offset: i8 = 0,
    second_chroma_qp_index_offset: i8 = 0,
    num_slice_groups_minus1: u8 = 0,
    slice_group_map_type: u8 = 0,
    num_ref_idx_l0_active_minus1: u8 = 0,
    num_ref_idx_l1_active_minus1: u8 = 0,
    slice_group_change_rate_minus1: u16 = 0,
    reserved_16bit_1: u16 = 0,
    scaling_list_4x4: [6][16]u8 = @splat(@splat(16)),
    scaling_list_8x8: [2][64]u8 = @splat(@splat(16)),
    frame_num: u32 = 0,
    frame_num_list: [16]u32 = @splat(0),
    curr_field_order_cnt_list: [2]i32 = .{ 0, 0 },
    field_order_cnt_list: [16][2]i32 = @splat(.{ 0, 0 }),
    decoded_pic_idx: u32 = 0,
    curr_pic_ref_frame_num: u32 = 0,
    ref_frame_list: [16]u8 = @splat(0xFF),
    reserved: [122]u32 = @splat(0),
    /// Multiview's part, unused.
    mvc: [140]u8 = @splat(0),
    non_existing_frame_flags: u16 = 0,
    used_for_reference_flags: u32 = 0,
};

/// An H.264 picture's scaling lists as the decoder reads them from their
/// own buffer: in raster order, the 8x8 ones of brightness only.
pub const AvcScaling = extern struct {
    m4: [6][16]u8 = @splat(@splat(16)),
    m8: [2][64]u8 = @splat(@splat(16)),
};

/// The whole of an H.264 picture's message, in the order its index
/// lists the parts.
pub const AvcMessage = extern struct {
    header: MessageHeader = .{},
    codec_index: MessageIndex = .{},
    dpb_index: MessageIndex = .{},
    decode: DecodePart = .{},
    dpb: DpbPart = .{},
    avc: AvcPart = .{},
};

/// An H.265 picture: its parameter sets' values, its own order count,
/// its references - each by its place, with the firmware's number for
/// it - and its reference picture set's three sets the picture uses, as
/// places among them; how a sample deeper than 8 bits is written.
pub const HevcPart = extern struct {
    sps_info_flags: u32 = 0,
    pps_info_flags: u32 = 0,
    chroma_format: u8 = 0,
    bit_depth_luma_minus8: u8 = 0,
    bit_depth_chroma_minus8: u8 = 0,
    log2_max_pic_order_cnt_lsb_minus4: u8 = 0,
    sps_max_dec_pic_buffering_minus1: u8 = 0,
    log2_min_luma_coding_block_size_minus3: u8 = 0,
    log2_diff_max_min_luma_coding_block_size: u8 = 0,
    log2_min_transform_block_size_minus2: u8 = 0,
    log2_diff_max_min_transform_block_size: u8 = 0,
    max_transform_hierarchy_depth_inter: u8 = 0,
    max_transform_hierarchy_depth_intra: u8 = 0,
    pcm_sample_bit_depth_luma_minus1: u8 = 0,
    pcm_sample_bit_depth_chroma_minus1: u8 = 0,
    log2_min_pcm_luma_coding_block_size_minus3: u8 = 0,
    log2_diff_max_min_pcm_luma_coding_block_size: u8 = 0,
    num_extra_slice_header_bits: u8 = 0,
    num_short_term_ref_pic_sets: u8 = 0,
    num_long_term_ref_pic_sps: u8 = 0,
    num_ref_idx_l0_default_active_minus1: u8 = 0,
    num_ref_idx_l1_default_active_minus1: u8 = 0,
    pps_cb_qp_offset: i8 = 0,
    pps_cr_qp_offset: i8 = 0,
    pps_beta_offset_div2: i8 = 0,
    pps_tc_offset_div2: i8 = 0,
    diff_cu_qp_delta_depth: u8 = 0,
    num_tile_columns_minus1: u8 = 0,
    num_tile_rows_minus1: u8 = 0,
    log2_parallel_merge_level_minus2: u8 = 0,
    column_width_minus1: [19]u16 = @splat(0),
    row_height_minus1: [21]u16 = @splat(0),
    init_qp_minus26: i8 = 0,
    num_delta_pocs_ref_rps_idx: u8 = 0,
    curr_idx: u8 = 0,
    reserved: u8 = 0,
    curr_poc: i32 = 0,
    ref_pic_list: [16]u8 = @splat(no_ref),
    poc_list: [16]i32 = @splat(0),
    ref_pic_set_st_curr_before: [8]u8 = @splat(0xFF),
    ref_pic_set_st_curr_after: [8]u8 = @splat(0xFF),
    ref_pic_set_lt_curr: [8]u8 = @splat(0xFF),
    scaling_dc_16x16: [6]u8 = @splat(16),
    scaling_dc_32x32: [2]u8 = @splat(16),
    highest_tid: u8 = 0,
    is_non_ref: u8 = 0,
    p010_mode: u8 = 0,
    msb_mode: u8 = 0,
    luma_10to8: u8 = 0,
    chroma_10to8: u8 = 0,
    scaler_10to8: [2]u8 = .{ 0, 0 },
    direct_reflist: [2][15]u8 = @splat(@splat(0)),
    st_rps_bits: u32 = 0,
    reserved_1: [15]u8 = @splat(0),
};

/// An H.265 picture's scaling lists as the decoder reads them from their
/// own buffer: in their coded (up-right diagonal) order, the six of each
/// size and the 32x32 ones of brightness only.
pub const HevcScaling = extern struct {
    m4: [6][16]u8 = @splat(@splat(16)),
    m8: [6][64]u8 = @splat(@splat(16)),
    m16: [6][64]u8 = @splat(@splat(16)),
    m32: [2][64]u8 = @splat(@splat(16)),
};

/// The whole of an H.265 picture's message.
pub const HevcMessage = extern struct {
    header: MessageHeader = .{},
    codec_index: MessageIndex = .{},
    dpb_index: MessageIndex = .{},
    decode: DecodePart = .{},
    dpb: DpbPart = .{},
    hevc: HevcPart = .{},
};

comptime {
    if (@sizeOf(MessageHeader) != header_bytes or @sizeOf(DecodePart) != 188 or @sizeOf(DpbPart) != 168 or
        @sizeOf(AvcPart) != 1124 or @sizeOf(AvcScaling) != 224 or @sizeOf(AvcMessage) != 1552 or
        @sizeOf(HevcPart) != 296 or @sizeOf(HevcScaling) != 992 or @sizeOf(HevcMessage) != 724)
        @compileError("a decoding message's part is not the size the decoder reads");
}

fn alignUp(value: u32, to: u32) u32 {
    return (value + to - 1) / to * to;
}

/// How a stream's surfaces are laid out, for pictures of `width` by
/// `height` (multiples of 16) and `ids` firmware numbers:
///
/// - a reference surface in blocks of 256 bytes, its rows of brightness
///   `ref_pitch` across and `ref_rows` down - both multiples of 32 - its
///   colour pairs right after, at half that each way;
/// - the target, the surface each picture is written to as rows of
///   bytes: `target_pitch` (a multiple of 256) apart, `target_rows` of
///   brightness, then half as many of colour pairs;
/// - the decoder's own context for the stream, `hw_bytes`: for H.264
///   192 bytes a macroblock for each of its numbers.
///
/// An H.265 stream deeper than 8 bits keeps its references in 16 bits a
/// sample (`sample_bytes`), its rows 64 apart; its target is in 8 bits
/// all the same.
pub const Layout = struct {
    width: u32 = 0,
    height: u32 = 0,
    ids: u32 = 0,
    ref_pitch: u32 = 0,
    ref_rows: u32 = 0,
    sample_bytes: u32 = 1,
    target_pitch: u32 = 0,
    target_rows: u32 = 0,
    hw_bytes: u32 = 0,

    pub fn avc(coded_width: u32, coded_height: u32, ids: u32) Layout {
        const width = alignUp(coded_width, 16);
        const height = alignUp(coded_height, 16);
        const across = width / 16;
        const down = alignUp(height / 16, 2);
        return .{
            .width = width,
            .height = height,
            .ids = ids,
            .ref_pitch = alignUp(width, 32),
            .ref_rows = alignUp(height, 32),
            .target_pitch = alignUp(width, 256),
            .target_rows = alignUp(height, 32),
            .hw_bytes = ids * alignUp(across * down * 192, 256),
        };
    }

    /// An H.265 stream of `coded_width` by `coded_height` samples,
    /// `ids` firmware numbers, `deep` past 8 bits, its coding tree blocks
    /// 1 << `log2_ctb` across. The decoder's context is sized for all of
    /// its numbers, whatever the stream uses: 16 bytes for each block of
    /// 16 by 16 samples with a margin of 255 each way, and 52 KiB - or,
    /// for the deeper samples, 16 bytes a block of 16 by 16 in whole
    /// coding tree blocks, with room for the filters' left edge.
    pub fn hevc(coded_width: u32, coded_height: u32, ids: u32, deep: bool, log2_ctb: u8) Layout {
        const rows_on: u32 = if (deep) 64 else 32;
        const width = alignUp(coded_width, 16);
        const height = alignUp(coded_height, 16);
        const hw_bytes = if (!deep)
            (width + 255) / 16 * ((height + 255) / 16) * 16 * most_ids + 52 * 1024
        else blk: {
            const ctb = @as(u32, 1) << @intCast(log2_ctb);
            const across = (width + ctb - 1) / ctb;
            const down = (height + ctb - 1) / ctb;
            const blocks = (ctb / 16) * (ctb / 16);
            const row = alignUp(across * blocks * 16, 256);
            const left_rows = (height * 8 + 2047) / 2048;
            break :blk most_ids * row * down + 4096 / 16 * (32 + 16 * 4) + 2 * (left_rows * 2 * 2048 + 1024);
        };
        return .{
            .width = coded_width,
            .height = coded_height,
            .ids = ids,
            .ref_pitch = alignUp(coded_width, rows_on),
            .ref_rows = alignUp(coded_height, rows_on),
            .sample_bytes = if (deep) 2 else 1,
            .target_pitch = alignUp(coded_width, 256),
            .target_rows = alignUp(coded_height, 32),
            .hw_bytes = hw_bytes,
        };
    }

    /// A reference surface's brightness in bytes.
    pub fn refLuma(l: Layout) u32 {
        return l.ref_pitch * l.ref_rows * l.sample_bytes;
    }

    /// A reference surface's room, on a page.
    pub fn refBytes(l: Layout) u32 {
        return alignUp(l.refLuma() + l.refLuma() / 2, 4096);
    }

    pub fn targetLuma(l: Layout) u32 {
        return l.target_pitch * l.target_rows;
    }

    pub fn targetBytes(l: Layout) u32 {
        return l.targetLuma() + l.targetLuma() / 2;
    }
};

/// The firmware numbers an H.264 stream needs: its references and the
/// picture decoded.
pub fn avcIds(sps: *const vp.h264.H264Sps) u32 {
    return @min(most_ids, @as(u32, @max(sps.max_num_ref_frames, 1)) + 1);
}

/// The decoder's number for an H.264 stream's profile - baseline, main
/// or high, which takes the high profiles' 8-bit 4:2:0 streams - or null
/// for one it does not decode: extended's data partitions, lossless
/// macroblocks, colour planes coded apart.
pub fn avcProfile(sps: *const vp.h264.H264Sps) ?u32 {
    if (sps.separate_colour_plane or sps.transform_bypass) return null;
    return switch (sps.profile_idc) {
        66 => 0,
        77 => 1,
        88 => null,
        else => 2,
    };
}

/// A reference as an H.264 picture's message names it: the firmware's
/// number for it, and whether its surface holds what was decoded.
pub const AvcRef = struct {
    id: u8,
    decoded: bool,
    ref: vp.VideoRef,
};

/// An order count for a field that is not a reference.
const no_poc: i32 = 0x7FFF_FFFF;
/// An H.265 reference place that names no picture.
const no_ref: u8 = 0x7F;

fn flag(set: bool, bit: u5) u32 {
    return @as(u32, @intFromBool(set)) << bit;
}

/// The codec's part and the scaling lists of the H.264 picture `pic`,
/// decoded with `sps` and `pps` into firmware number `id`, its
/// references `refs` in the order the picture holds them.
pub fn avcPart(part: *AvcPart, scaling: *AvcScaling, sps: *const vp.h264.H264Sps, pps: *const vp.h264.H264Pps, pic: *const vp.VideoPicture, id: u8, refs: []const AvcRef) void {
    part.* = .{};
    part.profile = avcProfile(sps) orelse 2;
    part.level = sps.level_idc;
    part.sps_info_flags = flag(sps.direct_8x8_inference, 0) | flag(sps.mbaff, 1) | flag(sps.frame_mbs_only, 2) |
        flag(sps.delta_pic_order_always_zero, 3) | flag(sps.gaps_allowed, 5);
    part.pps_info_flags = flag(pps.transform_8x8, 0) | flag(pps.redundant_pic_cnt_present, 1) |
        flag(pps.constrained_intra_pred, 2) | flag(pps.deblocking_control, 3) |
        (@as(u32, pps.weighted_bipred_idc & 3) << 4) | flag(pps.weighted_pred, 6) |
        flag(pps.bottom_field_poc_present, 7) | flag(pps.cabac, 8);
    part.chroma_format = sps.chroma_format_idc;
    part.bit_depth_luma_minus8 = sps.bit_depth_luma -| 8;
    part.bit_depth_chroma_minus8 = sps.bit_depth_chroma -| 8;
    part.log2_max_frame_num_minus4 = sps.log2_max_frame_num -| 4;
    part.pic_order_cnt_type = sps.poc_type;
    part.log2_max_pic_order_cnt_lsb_minus4 = sps.log2_max_poc_lsb -| 4;
    part.num_ref_frames = sps.max_num_ref_frames;
    part.pic_init_qp_minus26 = @intCast(pps.init_qp - 26);
    part.pic_init_qs_minus26 = @intCast(pps.init_qs - 26);
    part.chroma_qp_index_offset = @intCast(pps.chroma_qp_offset[0]);
    part.second_chroma_qp_index_offset = @intCast(pps.chroma_qp_offset[1]);
    part.num_slice_groups_minus1 = pps.num_slice_groups -| 1;
    part.slice_group_map_type = pps.slice_group_map_type;
    part.num_ref_idx_l0_active_minus1 = pps.num_ref_idx_default[0] -| 1;
    part.num_ref_idx_l1_active_minus1 = pps.num_ref_idx_default[1] -| 1;
    part.slice_group_change_rate_minus1 = @intCast(pps.change_rate -| 1);
    for (0..6) |k| {
        part.scaling_list_4x4[k] = pps.scaling.m4[k];
        scaling.m4[k] = pps.scaling.m4[k];
    }
    for (0..2) |k| {
        part.scaling_list_8x8[k] = pps.scaling.m8[k];
        scaling.m8[k] = pps.scaling.m8[k];
    }
    part.frame_num = pic.frame_num;
    part.curr_field_order_cnt_list = pic.poc;
    // A first field's pair is not decoded yet: its order count is not
    // known.
    if (pic.structure != 3 and !pic.second_field) part.curr_field_order_cnt_list[if (pic.structure == 1) 1 else 0] = 0;
    part.decoded_pic_idx = id;
    for (refs, 0..) |r, j| {
        const top = r.ref.fields & 1 != 0;
        const bottom = r.ref.fields & 2 != 0;
        part.frame_num_list[j] = r.ref.frame_num;
        part.field_order_cnt_list[j] = .{ if (top) r.ref.poc[0] else no_poc, if (bottom) r.ref.poc[1] else no_poc };
        part.ref_frame_list[j] = r.id | if (r.ref.long_term) @as(u8, 0x80) else 0;
        if (top) part.used_for_reference_flags |= @as(u32, 1) << @intCast(2 * j);
        if (bottom) part.used_for_reference_flags |= @as(u32, 1) << @intCast(2 * j + 1);
        if (!r.decoded) part.non_existing_frame_flags |= @as(u16, 1) << @intCast(j);
    }
    part.curr_pic_ref_frame_num = @intCast(refs.len);
}

/// The rest of an H.264 picture's message: its header and index, what
/// the picture is - stream `stream`'s `number`th, `bitstream_bytes` of
/// slices (a multiple of 128), laid out as `layout` - and its surfaces:
/// `current` for itself, `refs` for its references in the order the
/// codec's part names them.
pub fn avcMessage(m: *AvcMessage, layout: Layout, stream: u32, number: u32, bitstream_bytes: u32, current: u64, refs: []const u64) void {
    pictureMessage(AvcMessage, m, "avc", PART_AVC, types.VDCODEC_H264, layout, stream, number, bitstream_bytes, current, refs);
}

/// The rest of an H.265 picture's message, as `avcMessage` for H.264.
pub fn hevcMessage(m: *HevcMessage, layout: Layout, stream: u32, number: u32, bitstream_bytes: u32, current: u64, refs: []const u64) void {
    pictureMessage(HevcMessage, m, "hevc", PART_HEVC, types.VDCODEC_H265, layout, stream, number, bitstream_bytes, current, refs);
}

/// A picture's message of either codec but its codec's part, which is
/// `part` of `Message` and the part `part_id` of the index.
fn pictureMessage(comptime Message: type, m: *Message, comptime part: []const u8, part_id: u32, codec: u32, layout: Layout, stream: u32, number: u32, bitstream_bytes: u32, current: u64, refs: []const u64) void {
    m.header = .{
        .total_size = @sizeOf(Message),
        .num_buffers = 3,
        .msg_type = MESSAGE_DECODE,
        .stream_handle = stream,
        .feedback_number = number,
        .index = .{ .id = PART_DECODE, .offset = @offsetOf(Message, "decode"), .size = @sizeOf(DecodePart) },
    };
    m.codec_index = .{ .id = part_id, .offset = @offsetOf(Message, part), .size = @sizeOf(@FieldType(Message, part)) };
    m.dpb_index = .{ .id = PART_DYNAMIC_DPB, .offset = @offsetOf(Message, "dpb"), .size = @sizeOf(DpbPart) };
    m.decode = .{
        .stream_type = streamKind(codec),
        .decode_flags = DECODE_DYNAMIC_DPB,
        .width_in_samples = layout.width,
        .height_in_samples = layout.height,
        .bsd_size = bitstream_bytes,
        .dt_size = layout.targetBytes(),
        .hw_ctxt_size = layout.hw_bytes,
        .sw_ctxt_size = session_bytes,
        .decode_buffer_flags = decode_buffers & ~BUFFER_SESSION,
        .db_pitch = layout.ref_pitch,
        .db_aligned_height = layout.ref_rows,
        .db_swizzle_mode = SWIZZLE_256B_D,
        .db_array_mode = ARRAY_MODE_GFX11,
        .dt_pitch = layout.target_pitch,
        .dt_uv_pitch = layout.target_pitch / 2,
        .dt_array_mode = ARRAY_MODE_GFX11,
        .dt_chroma_top_offset = layout.targetLuma(),
        .dt_chroma_bottom_offset = layout.targetLuma(),
        .mif_wrc_en = 1,
        .db_pitch_uv = layout.ref_pitch / 2,
    };
    m.dpb = .{
        .luma_pitch = layout.ref_pitch,
        .luma_aligned_height = layout.ref_rows,
        .luma_aligned_size = layout.refLuma(),
        .chroma_pitch = layout.ref_pitch / 2,
        .chroma_aligned_height = layout.ref_rows / 2,
        .chroma_aligned_size = layout.refLuma() / 2,
        .array_size = @intCast(refs.len),
        .curr_lo = @truncate(current),
        .curr_hi = @truncate(current >> 32),
    };
    for (refs, 0..) |address, j| {
        m.dpb.addr_lo[j] = @truncate(address);
        m.dpb.addr_hi[j] = @truncate(address >> 32);
    }
}

/// The firmware numbers an H.265 stream needs: the pictures its buffer
/// holds, the one decoded among them, and one to spare.
pub fn hevcIds(sps: *const vp.hevc.HevcSps) u32 {
    return @min(most_ids, sps.max_dec_pic_buffering + 1);
}

/// Whether the decoder takes an H.265 stream of `sps`: Main, Main 10 and
/// Main Still Picture - 4:2:0 in 8 or 10 bits, its colour as deep as its
/// brightness - and none of the later profiles' tools.
pub fn hevcTakes(sps: *const vp.hevc.HevcSps) bool {
    if (sps.extensionProfile() or sps.separate_colour_plane or sps.chroma_format_idc != 1) return false;
    if (sps.bit_depth_luma != sps.bit_depth_chroma or (sps.bit_depth_luma != 8 and sps.bit_depth_luma != 10)) return false;
    return !(sps.transform_skip_rotation or sps.transform_skip_context or sps.implicit_rdpcm or sps.explicit_rdpcm or
        sps.extended_precision or sps.intra_smoothing_disabled or sps.high_precision_offsets or sps.persistent_rice or
        sps.cabac_bypass_alignment);
}

/// A reference as an H.265 picture's message names it: the firmware's
/// number for its surface, and its order count.
pub const HevcRef = struct {
    id: u8,
    poc: i32,
};

/// How a sample deeper than 8 bits is written into the 8-bit target:
/// rounded to the nearest.
const DITHER_ROUND: u8 = 2;
/// The same for the scaler, which is not used: its value as Mesa sets it.
const SCALER_10TO8: u8 = 4;

/// The codec's part and the scaling lists of the H.265 picture `pic`,
/// decoded with `sps` and `pps` into firmware number `id`; `refs` names
/// each of the picture's references in its place.
pub fn hevcPart(part: *HevcPart, scaling: *HevcScaling, sps: *const vp.hevc.HevcSps, pps: *const vp.hevc.HevcPps, pic: *const vp.VideoPicture, id: u8, refs: []const HevcRef) void {
    part.* = .{};
    part.sps_info_flags = flag(sps.scaling_enabled, 0) | flag(sps.amp, 1) | flag(sps.sao, 2) | flag(sps.pcm, 3) |
        flag(sps.pcm_loop_filter_disabled, 4) | flag(sps.long_term_present, 5) | flag(sps.temporal_mvp, 6) |
        flag(sps.strong_intra_smoothing, 7) | flag(sps.separate_colour_plane, 8) | flag(pic.st_rps_bits != 0, 11);
    part.st_rps_bits = pic.st_rps_bits;
    part.pps_info_flags = flag(pps.dependent_slice_segments, 0) | flag(pps.output_flag_present, 1) |
        flag(pps.sign_data_hiding, 2) | flag(pps.cabac_init_present, 3) | flag(pps.constrained_intra_pred, 4) |
        flag(pps.transform_skip, 5) | flag(pps.cu_qp_delta_enabled, 6) | flag(pps.slice_chroma_qp_offsets_present, 7) |
        flag(pps.weighted_pred, 8) | flag(pps.weighted_bipred, 9) | flag(pps.transquant_bypass, 10) |
        flag(pps.tiles, 11) | flag(pps.entropy_coding_sync, 12) | flag(pps.uniform_spacing, 13) |
        flag(pps.loop_filter_across_tiles, 14) | flag(pps.loop_filter_across_slices, 15) |
        flag(pps.deblocking_override_enabled, 16) | flag(pps.deblocking_disabled, 17) |
        flag(pps.lists_modification_present, 18) | flag(pps.slice_header_extension_present, 19);
    part.chroma_format = sps.chroma_format_idc;
    part.bit_depth_luma_minus8 = sps.bit_depth_luma -| 8;
    part.bit_depth_chroma_minus8 = sps.bit_depth_chroma -| 8;
    part.log2_max_pic_order_cnt_lsb_minus4 = sps.log2_max_poc_lsb -| 4;
    part.sps_max_dec_pic_buffering_minus1 = @intCast(sps.max_dec_pic_buffering -| 1);
    part.log2_min_luma_coding_block_size_minus3 = sps.log2_min_cb -| 3;
    part.log2_diff_max_min_luma_coding_block_size = sps.log2_ctb -| sps.log2_min_cb;
    part.log2_min_transform_block_size_minus2 = sps.log2_min_tb -| 2;
    part.log2_diff_max_min_transform_block_size = sps.log2_max_tb -| sps.log2_min_tb;
    part.max_transform_hierarchy_depth_inter = sps.max_th_depth_inter;
    part.max_transform_hierarchy_depth_intra = sps.max_th_depth_intra;
    if (sps.pcm) {
        part.pcm_sample_bit_depth_luma_minus1 = sps.pcm_depth_luma -| 1;
        part.pcm_sample_bit_depth_chroma_minus1 = sps.pcm_depth_chroma -| 1;
        part.log2_min_pcm_luma_coding_block_size_minus3 = sps.log2_min_pcm -| 3;
        part.log2_diff_max_min_pcm_luma_coding_block_size = sps.log2_max_pcm -| sps.log2_min_pcm;
    }
    part.num_extra_slice_header_bits = pps.num_extra_slice_header_bits;
    part.num_short_term_ref_pic_sets = sps.num_st_rps;
    part.num_long_term_ref_pic_sps = sps.num_lt_sps;
    part.num_ref_idx_l0_default_active_minus1 = pps.num_ref_idx_default[0] -| 1;
    part.num_ref_idx_l1_default_active_minus1 = pps.num_ref_idx_default[1] -| 1;
    part.pps_cb_qp_offset = pps.cb_qp_offset;
    part.pps_cr_qp_offset = pps.cr_qp_offset;
    part.pps_beta_offset_div2 = @divTrunc(pps.beta_offset, 2);
    part.pps_tc_offset_div2 = @divTrunc(pps.tc_offset, 2);
    part.diff_cu_qp_delta_depth = pps.diff_cu_qp_delta_depth;
    part.log2_parallel_merge_level_minus2 = pps.log2_parallel_merge_level -| 2;
    part.init_qp_minus26 = @intCast(pps.init_qp - 26);
    if (pps.tiles) {
        part.num_tile_columns_minus1 = @intCast(pps.num_tile_columns - 1);
        part.num_tile_rows_minus1 = @intCast(pps.num_tile_rows - 1);
        tileSizes(&part.column_width_minus1, pps, pps.column_width[0..], pps.num_tile_columns, sps.widthCtbs());
        tileSizes(&part.row_height_minus1, pps, pps.row_height[0..], pps.num_tile_rows, sps.heightCtbs());
    }

    part.curr_idx = id;
    part.curr_poc = pic.poc[0];
    for (refs, 0..) |r, j| {
        part.ref_pic_list[j] = r.id;
        part.poc_list[j] = r.poc;
    }
    const sets = [_]struct { into: *[8]u8, set: u32 }{
        .{ .into = &part.ref_pic_set_st_curr_before, .set = vp.VP_RPS_ST_CURR_BEFORE },
        .{ .into = &part.ref_pic_set_st_curr_after, .set = vp.VP_RPS_ST_CURR_AFTER },
        .{ .into = &part.ref_pic_set_lt_curr, .set = vp.VP_RPS_LT_CURR },
    };
    for (sets) |entry| {
        const count = @min(pic.rps_count[entry.set], 8);
        for (pic.rps[entry.set][0..count], 0..) |place, k| entry.into[k] = place;
    }

    scaling.* = .{};
    if (sps.scaling_enabled) {
        const lists = if (pps.scaling_present) &pps.scaling else &sps.scaling;
        for (0..6) |m| {
            @memcpy(&scaling.m4[m], lists.coef[0][m][0..16]);
            scaling.m8[m] = lists.coef[1][m];
            scaling.m16[m] = lists.coef[2][m];
            part.scaling_dc_16x16[m] = lists.dc[0][m];
        }
        for ([_]usize{ 0, 3 }, 0..) |m, k| {
            scaling.m32[k] = lists.coef[3][m];
            part.scaling_dc_32x32[k] = lists.dc[1][m];
        }
    }

    if (sps.bit_depth_luma > 8) {
        part.luma_10to8 = DITHER_ROUND;
        part.chroma_10to8 = DITHER_ROUND;
        part.scaler_10to8 = .{ SCALER_10TO8, SCALER_10TO8 };
    }
}

/// The widths of `count` tile columns (or the heights of rows) less
/// one, in coding tree blocks of a picture `ctbs` across: as `sizes`
/// says them - all but the last - or spread evenly (6-3, 6-4).
fn tileSizes(into: []u16, pps: *const vp.hevc.HevcPps, sizes: []const u16, count: u32, ctbs: u32) void {
    var used: u32 = 0;
    for (0..@min(count, into.len)) |k| {
        const i: u32 = @intCast(k);
        const size = if (pps.uniform_spacing)
            (i + 1) * ctbs / count - i * ctbs / count
        else if (i + 1 < count) sizes[k] else ctbs -| used;
        used += size;
        into[k] = @intCast(size -| 1);
    }
}

/// `from` written to the device's memory at `cpu`, eight bytes at a time.
pub fn copyToDevice(cpu: u64, from: []const u8) void {
    const whole = from.len / 8 * 8;
    var offset: usize = 0;
    while (offset < whole) : (offset += 8) {
        const to: *volatile u64 = @ptrFromInt(@as(usize, @intCast(cpu)) + offset);
        to.* = @as(*align(1) const u64, @ptrCast(from.ptr + offset)).*;
    }
    if (whole < from.len) {
        var last: u64 = 0;
        for (from[whole..], 0..) |byte, n| last |= @as(u64, byte) << @intCast(n * 8);
        const to: *volatile u64 = @ptrFromInt(@as(usize, @intCast(cpu)) + whole);
        to.* = last;
    }
}

/// `bytes` of the device's memory at `cpu` (a multiple of 8) set to
/// `value`, eight bytes at a time.
pub fn fillDevice(cpu: u64, bytes: u32, value: u64) void {
    var offset: u32 = 0;
    while (offset < bytes) : (offset += 8) {
        const to: *volatile u64 = @ptrFromInt(@as(usize, @intCast(cpu)) + offset);
        to.* = value;
    }
}

/// `bytes` out of the device's memory at `cpu` by streaming loads, which
/// read write-combining memory a whole line at a time where plain loads
/// fetch each word on its own: a multiple of 64, from a line's start. A
/// fence first, so that nothing written before is still on its way.
pub fn streamFromDevice(to: [*]u8, cpu: u64, bytes: usize) void {
    fence();
    var offset: usize = 0;
    while (offset < bytes) : (offset += 64) {
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
            : [from] "r" (@as(usize, @intCast(cpu)) + offset),
              [to] "r" (to + offset),
            : .{ .xmm0 = true, .xmm1 = true, .xmm2 = true, .xmm3 = true, .memory = true });
    }
}

/// A picture's message `message` and its scaling lists (an AvcMessage
/// and AvcScaling, or an HevcMessage and HevcScaling) written into the
/// ring's piece and handed to the decoder with the stream's other
/// buffers (`buffers`, whose message and scaling lists are filled in
/// here). Its fence is the state's last; `fenced` waits for it. The
/// caller holds the resource's lock.
pub fn decodePicture(state: *State, message: anytype, scaling: anytype, buffers: Buffers) void {
    const page = state.ring.cpu + message_at;
    copyToDevice(page, @as([*]const u8, @ptrCast(message))[0..@sizeOf(@TypeOf(message.*))]);
    copyToDevice(page + scaling_at, @as([*]const u8, @ptrCast(scaling))[0..@sizeOf(@TypeOf(scaling.*))]);
    var named = buffers;
    named.flags = decode_buffers;
    named.message = state.ring.device + message_at;
    named.scaling = state.ring.device + message_at + scaling_at;
    fence();
    handOver(state, named);
}

/// How often a picture's fence is looked at.
const look_us: u32 = 100;

/// Waits up to `most_us` for the last fence's number to be written,
/// `waiter.wait(micros)` waiting that long between looks.
pub fn fenced(state: *const State, most_us: u64, waiter: anytype) bool {
    var waited: u64 = 0;
    while (at(state.ring.cpu, fence_at).* != state.sequence) {
        if (waited >= most_us) return false;
        waiter.wait(look_us);
        waited += look_us;
    }
    return true;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the start's values and the firmware's names" {
    try testing.expectEqual(@as(u32, 0x00307308), LMI_CTRL_START);
    try testing.expectEqual(@as(u32, 0x003E0000), LMI_CTRL2_START);
    try testing.expectEqual(@as(u32, 0x1FF00200), VCPU_TIMEOUT | VCPU_CLK_EN | VCPU_BLK_RST);
    try testing.expectEqual(@as(u32, 0x040C2040), MPC_MUX_AB);
    try testing.expectEqual(@as(u32, 0x88), MPC_MUX);
    var room: [64]u8 = undefined;
    try testing.expectEqualStrings("DEVS:firmware/amdgpu/vcn_4_0_2.bin", @import("std").mem.span(firmwareName(&room, "vcn_", .{ 4, 0, 2 }, ".bin")));
    try testing.expectEqualStrings("DEVS:firmware/amdgpu/psp_13_0_4_toc.bin", @import("std").mem.span(firmwareName(&room, "psp_", .{ 13, 0, 4 }, "_toc.bin")));
}

test "a register as the decoder numbers it" {
    // The video block's second address on the Radeon 780M: its words
    // from 0xc0 on are the video part, those below the always-on part.
    const base = 0x7E00;
    try testing.expectEqual(@as(u32, 0xD6), inside(base, VCPU_CNTL));
    try testing.expectEqual(@as(u32, 0x21), inside(base, MASTINT_EN));
    try testing.expectEqual(@as(u32, 0x1EE), inside(base, LMI_CTRL2));
    try testing.expectEqual(@as(u32, 0x0), inside(base, 0xC0));
    try testing.expectEqual(@as(u32, 0xC042), inside(base, GFX10_ADDR_CONFIG));
    try testing.expectEqual(@as(u32, 0xC002), inside(base, POWER_STATUS));
}

test "the start's list: its writes in their order, the windows placed" {
    var writes: Writes = .{ .segment_base = 0x7E00 };
    startWrites(&writes, 0x80_0420_0000, 0x4345);
    try testing.expectEqual(@as(u32, 27 * 2), writes.count);
    try testing.expectEqual(@as(usize, 27 * 8), writes.bytes().len);
    const words = writes.words[0..writes.count];
    try testing.expectEqualSlices(u32, &.{ 0xD6, 0x1FF00200, 0x21, 0 }, words[0..4]);
    try testing.expectEqualSlices(u32, &.{ 0x21, 0x2 }, words[52..54]);
    // The firmware's window given nothing, the context's after the stack,
    // the shared block's after the context.
    try testing.expectEqualSlices(u32, &.{ inside(0x7E00, CACHE_BAR_LOW), 0, inside(0x7E00, CACHE_BAR_HIGH), 0 }, words[14..18]);
    try testing.expectEqualSlices(u32, &.{ inside(0x7E00, CACHE2_BAR_LOW), 0x04220000, inside(0x7E00, CACHE2_BAR_HIGH), 0x80 }, words[30..34]);
    try testing.expectEqualSlices(u32, &.{ inside(0x7E00, NC0_BAR_LOW), 0x042A0000 }, words[38..40]);
    try testing.expectEqualSlices(u32, &.{ 0xC042, 0x4345 }, words[46..48]);
}

test "a stream's messages are the words the decoder reads" {
    var words: [16]u32 = undefined;
    // As Linux's own check of the decoder sends them.
    const create = [_]u32{ 0x28, 0x38, 1, 0, 0x55, 0, 1, 0x28, 0x10, 0, 7, 0, 0x780, 0x440 };
    try testing.expectEqual(@as(u32, create.len), createMessage(&words, 0x55, streamKind(types.VDCODEC_H264), 1920, 1088));
    try testing.expectEqualSlices(u32, &create, words[0..create.len]);
    try testing.expectEqual(@as(u32, 0x10), streamKind(types.VDCODEC_H265));
    const destroy = [_]u32{ 0x28, 0x18, 0, 2, 0x55, 0 };
    try testing.expectEqual(@as(u32, destroy.len), destroyMessage(&words, 0x55));
    try testing.expectEqualSlices(u32, &destroy, words[0..destroy.len]);
}

test "an indirect buffer names the message and the stream's context" {
    var ib: [ib_words]u32 = undefined;
    try testing.expectEqual(@as(u32, 39), messageBuffer(&ib, 0x80_1234_5000, 0x80_0042_0000));
    try testing.expectEqualSlices(u32, &.{ 0x10, 0x30000001, 3, 156, 140, 1, 0x00100001, 0x80, 0x12345000 }, ib[0..9]);
    try testing.expectEqual(@as(u32, 0x80), ib[13]);
    try testing.expectEqual(@as(u32, 0x00420000), ib[14]);
    for (ib[15..]) |value| try testing.expectEqual(@as(u32, 0), value);
}

test "an H.264 picture's message is laid out as the decoder reads it" {
    try testing.expectEqual(@as(usize, 40), @offsetOf(AvcMessage, "codec_index"));
    try testing.expectEqual(@as(usize, 56), @offsetOf(AvcMessage, "dpb_index"));
    try testing.expectEqual(@as(usize, 72), @offsetOf(AvcMessage, "decode"));
    try testing.expectEqual(@as(usize, 260), @offsetOf(AvcMessage, "dpb"));
    try testing.expectEqual(@as(usize, 428), @offsetOf(AvcMessage, "avc"));
    try testing.expectEqual(@as(usize, 68), @offsetOf(DecodePart, "decode_buffer_flags"));
    try testing.expectEqual(@as(usize, 84), @offsetOf(DecodePart, "db_swizzle_mode"));
    try testing.expectEqual(@as(usize, 100), @offsetOf(DecodePart, "dt_pitch"));
    try testing.expectEqual(@as(usize, 144), @offsetOf(DecodePart, "dt_chroma_top_offset"));
    try testing.expectEqual(@as(usize, 160), @offsetOf(DecodePart, "mif_wrc_en"));
    try testing.expectEqual(@as(usize, 164), @offsetOf(DecodePart, "db_pitch_uv"));
    try testing.expectEqual(@as(usize, 40), @offsetOf(DpbPart, "addr_lo"));
    try testing.expectEqual(@as(usize, 104), @offsetOf(DpbPart, "addr_hi"));
    try testing.expectEqual(@as(usize, 36), @offsetOf(AvcPart, "scaling_list_4x4"));
    try testing.expectEqual(@as(usize, 132), @offsetOf(AvcPart, "scaling_list_8x8"));
    try testing.expectEqual(@as(usize, 260), @offsetOf(AvcPart, "frame_num"));
    try testing.expectEqual(@as(usize, 264), @offsetOf(AvcPart, "frame_num_list"));
    try testing.expectEqual(@as(usize, 328), @offsetOf(AvcPart, "curr_field_order_cnt_list"));
    try testing.expectEqual(@as(usize, 336), @offsetOf(AvcPart, "field_order_cnt_list"));
    try testing.expectEqual(@as(usize, 464), @offsetOf(AvcPart, "decoded_pic_idx"));
    try testing.expectEqual(@as(usize, 468), @offsetOf(AvcPart, "curr_pic_ref_frame_num"));
    try testing.expectEqual(@as(usize, 472), @offsetOf(AvcPart, "ref_frame_list"));
    try testing.expectEqual(@as(usize, 976), @offsetOf(AvcPart, "mvc"));
    try testing.expectEqual(@as(usize, 1116), @offsetOf(AvcPart, "non_existing_frame_flags"));
    try testing.expectEqual(@as(usize, 1120), @offsetOf(AvcPart, "used_for_reference_flags"));
    try testing.expect(scaling_at >= @sizeOf(AvcMessage) and scaling_at % 256 == 0 and scaling_at + @sizeOf(AvcScaling) <= 4096);
}

test "a decoding buffer names every buffer where the decoder looks for it" {
    var ib: [ib_words]u32 = undefined;
    _ = indirectBuffer(&ib, .{
        .flags = decode_buffers,
        .message = 0x80_0000_1000,
        .session = 0x81_0000_2000,
        .bitstream = 0x82_0000_3000,
        .context = 0x83_0000_4000,
        .target = 0x84_0000_5000,
        .scaling = 0x85_0000_6000,
    });
    // Mesa's flags for an H.264 picture on this generation.
    try testing.expectEqual(@as(u32, 0x00100A0D), ib[6]);
    const buffer = ib[6..];
    try testing.expectEqualSlices(u32, &.{ 0x80, 0x1000 }, buffer[1..3]);
    try testing.expectEqualSlices(u32, &.{ 0, 0 }, buffer[3..5]);
    try testing.expectEqualSlices(u32, &.{ 0x84, 0x5000 }, buffer[5..7]);
    try testing.expectEqualSlices(u32, &.{ 0x81, 0x2000 }, buffer[7..9]);
    try testing.expectEqualSlices(u32, &.{ 0x82, 0x3000 }, buffer[9..11]);
    try testing.expectEqualSlices(u32, &.{ 0x83, 0x4000 }, buffer[11..13]);
    try testing.expectEqualSlices(u32, &.{ 0x85, 0x6000 }, buffer[21..23]);
}

test "a 1080p stream's surfaces and context" {
    const l = Layout.avc(1920, 1080, 5);
    try testing.expectEqual(@as(u32, 1920), l.width);
    try testing.expectEqual(@as(u32, 1088), l.height);
    try testing.expectEqual(@as(u32, 1920), l.ref_pitch);
    try testing.expectEqual(@as(u32, 1088), l.ref_rows);
    try testing.expectEqual(@as(u32, 2048), l.target_pitch);
    try testing.expectEqual(@as(u32, 1088), l.target_rows);
    // 120 x 68 macroblocks, 192 bytes each, for each of the five numbers.
    try testing.expectEqual(@as(u32, 5 * 120 * 68 * 192), l.hw_bytes);
    try testing.expectEqual(@as(u32, 1920 * 1088), l.refLuma());
    try testing.expectEqual(@as(u32, 0), l.refBytes() % 4096);
    try testing.expect(l.refBytes() >= 1920 * 1088 * 3 / 2);
    try testing.expectEqual(@as(u32, 2048 * 1088 * 3 / 2), l.targetBytes());
    // A small one: its macroblock rows counted in pairs, each number's
    // share on 256 bytes.
    const small = Layout.avc(176, 144, 2);
    try testing.expectEqual(@as(u32, 2 * 21248), small.hw_bytes);
    try testing.expectEqual(@as(u32, 192), small.ref_pitch);
    try testing.expectEqual(@as(u32, 160), small.ref_rows);
    try testing.expectEqual(@as(u32, 256), small.target_pitch);
}

test "an H.264 picture's message: its parameter sets, references and surfaces" {
    var sps: vp.h264.H264Sps = .{ .profile_idc = 100, .level_idc = 41, .max_num_ref_frames = 4, .frame_mbs_only = true, .direct_8x8_inference = true, .log2_max_frame_num = 9, .log2_max_poc_lsb = 6 };
    try testing.expectEqual(@as(u32, 5), avcIds(&sps));
    sps.max_num_ref_frames = 0;
    try testing.expectEqual(@as(u32, 2), avcIds(&sps));
    sps.max_num_ref_frames = 16;
    try testing.expectEqual(@as(u32, 17), avcIds(&sps));
    try testing.expectEqual(@as(?u32, 2), avcProfile(&sps));
    sps.profile_idc = 88;
    try testing.expectEqual(@as(?u32, null), avcProfile(&sps));
    sps.profile_idc = 66;
    try testing.expectEqual(@as(?u32, 0), avcProfile(&sps));
    sps.profile_idc = 100;
    sps.transform_bypass = true;
    try testing.expectEqual(@as(?u32, null), avcProfile(&sps));
    sps.transform_bypass = false;

    var pps: vp.h264.H264Pps = .{ .cabac = true, .transform_8x8 = true, .weighted_bipred_idc = 2, .deblocking_control = true, .init_qp = 24, .chroma_qp_offset = .{ -2, 3 }, .num_ref_idx_default = .{ 3, 1 } };
    pps.scaling.m4[3][0] = 7;
    pps.scaling.m8[1][63] = 9;
    // A bottom field, the second of its pair, with a frame and a
    // long-term field pair's bottom field for references, the second
    // never decoded.
    var pic: vp.VideoPicture = .{ .slot = 4, .structure = 2, .second_field = true, .frame_num = 7, .poc = .{ 14, 15 } };
    const refs = [_]AvcRef{
        .{ .id = 2, .decoded = true, .ref = .{ .slot = 1, .fields = 3, .frame_num = 6, .poc = .{ 12, 13 } } },
        .{ .id = 0, .decoded = false, .ref = .{ .slot = 0, .fields = 2, .long_term = true, .frame_num = 1, .poc = .{ 2, 3 } } },
    };
    var message: AvcMessage = .{};
    var scaling: AvcScaling = .{};
    avcPart(&message.avc, &scaling, &sps, &pps, &pic, 3, &refs);
    const avc = &message.avc;
    try testing.expectEqual(@as(u32, 2), avc.profile);
    try testing.expectEqual(@as(u32, 41), avc.level);
    try testing.expectEqual(@as(u32, 0b101), avc.sps_info_flags);
    try testing.expectEqual(@as(u32, 1 | 8 | (2 << 4) | 0x100), avc.pps_info_flags);
    try testing.expectEqual(@as(u8, 5), avc.log2_max_frame_num_minus4);
    try testing.expectEqual(@as(u8, 2), avc.log2_max_pic_order_cnt_lsb_minus4);
    try testing.expectEqual(@as(i8, -2), avc.pic_init_qp_minus26);
    try testing.expectEqual(@as(i8, -2), avc.chroma_qp_index_offset);
    try testing.expectEqual(@as(i8, 3), avc.second_chroma_qp_index_offset);
    try testing.expectEqual(@as(u8, 2), avc.num_ref_idx_l0_active_minus1);
    try testing.expectEqual(@as(u8, 7), avc.scaling_list_4x4[3][0]);
    try testing.expectEqual(@as(u8, 9), scaling.m8[1][63]);
    try testing.expectEqual(@as(u8, 16), scaling.m8[0][0]);
    try testing.expectEqual(@as(u32, 7), avc.frame_num);
    try testing.expectEqual([2]i32{ 14, 15 }, avc.curr_field_order_cnt_list);
    try testing.expectEqual(@as(u32, 3), avc.decoded_pic_idx);
    try testing.expectEqual(@as(u32, 2), avc.curr_pic_ref_frame_num);
    try testing.expectEqualSlices(u8, &.{ 2, 0x80, 0xFF }, avc.ref_frame_list[0..3]);
    try testing.expectEqual([2]i32{ 12, 13 }, avc.field_order_cnt_list[0]);
    try testing.expectEqual([2]i32{ no_poc, 3 }, avc.field_order_cnt_list[1]);
    try testing.expectEqual(@as(u32, 0b1011), avc.used_for_reference_flags);
    try testing.expectEqual(@as(u16, 0b10), avc.non_existing_frame_flags);
    try testing.expectEqual(@as(u32, 1), avc.frame_num_list[1]);

    // A first top field: its pair's order count is not known yet.
    pic = .{ .slot = 4, .structure = 1, .frame_num = 7, .poc = .{ 14, 14 } };
    avcPart(&message.avc, &scaling, &sps, &pps, &pic, 3, &.{});
    try testing.expectEqual([2]i32{ 14, 0 }, message.avc.curr_field_order_cnt_list);
    try testing.expectEqual(@as(u32, 0), message.avc.curr_pic_ref_frame_num);

    const layout = Layout.avc(1920, 1080, 5);
    avcMessage(&message, layout, 0x55, 9, 4096, 0x80_0100_0000, &.{ 0x80_0200_0000, 0x80_0300_0000 });
    const words: [*]const u32 = @ptrCast(&message);
    try testing.expectEqualSlices(u32, &.{ 40, 1552, 3, 1, 0x55, 9, 2, 72, 188, 0, 6, 428, 1124, 0, 0x10, 260, 168, 0 }, words[0..18]);
    const decode = &message.decode;
    try testing.expectEqual(@as(u32, 7), decode.stream_type);
    try testing.expectEqual(@as(u32, 1), decode.decode_flags);
    try testing.expectEqual(@as(u32, 0x00000A0D), decode.decode_buffer_flags);
    try testing.expectEqual(@as(u32, 1088), decode.height_in_samples);
    try testing.expectEqual(@as(u32, 2048 / 2), decode.dt_uv_pitch);
    try testing.expectEqual(@as(u32, 2048 * 1088), decode.dt_chroma_top_offset);
    try testing.expectEqual(@as(u32, 5 * 120 * 68 * 192), decode.hw_ctxt_size);
    try testing.expectEqual(@as(u32, 2), decode.db_swizzle_mode);
    try testing.expectEqual(@as(u32, 3), decode.db_array_mode);
    try testing.expectEqual(@as(u32, 0), decode.dt_swizzle_mode);
    try testing.expectEqual(@as(u32, 2), message.dpb.array_size);
    try testing.expectEqual(@as(u32, 0x0100_0000), message.dpb.curr_lo);
    try testing.expectEqual(@as(u32, 0x80), message.dpb.curr_hi);
    try testing.expectEqual(@as(u32, 0x0300_0000), message.dpb.addr_lo[1]);
    try testing.expectEqual(@as(u32, 1920 * 1088 / 2), message.dpb.chroma_aligned_size);
}

test "bytes go to the device's memory eight at a time, the last ones padded" {
    var room: [24]u8 align(8) = @splat(0xEE);
    copyToDevice(@intFromPtr(&room), &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 });
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0, 0, 0, 0, 0, 0xEE }, room[0..17]);
}

test "an H.265 picture's message is laid out as the decoder reads it" {
    try testing.expectEqual(@as(usize, 428), @offsetOf(HevcMessage, "hevc"));
    try testing.expectEqual(@as(usize, 23), @offsetOf(HevcPart, "num_extra_slice_header_bits"));
    try testing.expectEqual(@as(usize, 28), @offsetOf(HevcPart, "pps_cb_qp_offset"));
    try testing.expectEqual(@as(usize, 36), @offsetOf(HevcPart, "column_width_minus1"));
    try testing.expectEqual(@as(usize, 74), @offsetOf(HevcPart, "row_height_minus1"));
    try testing.expectEqual(@as(usize, 116), @offsetOf(HevcPart, "init_qp_minus26"));
    try testing.expectEqual(@as(usize, 118), @offsetOf(HevcPart, "curr_idx"));
    try testing.expectEqual(@as(usize, 120), @offsetOf(HevcPart, "curr_poc"));
    try testing.expectEqual(@as(usize, 124), @offsetOf(HevcPart, "ref_pic_list"));
    try testing.expectEqual(@as(usize, 140), @offsetOf(HevcPart, "poc_list"));
    try testing.expectEqual(@as(usize, 204), @offsetOf(HevcPart, "ref_pic_set_st_curr_before"));
    try testing.expectEqual(@as(usize, 212), @offsetOf(HevcPart, "ref_pic_set_st_curr_after"));
    try testing.expectEqual(@as(usize, 220), @offsetOf(HevcPart, "ref_pic_set_lt_curr"));
    try testing.expectEqual(@as(usize, 228), @offsetOf(HevcPart, "scaling_dc_16x16"));
    try testing.expectEqual(@as(usize, 234), @offsetOf(HevcPart, "scaling_dc_32x32"));
    try testing.expectEqual(@as(usize, 236), @offsetOf(HevcPart, "highest_tid"));
    try testing.expectEqual(@as(usize, 238), @offsetOf(HevcPart, "p010_mode"));
    try testing.expectEqual(@as(usize, 240), @offsetOf(HevcPart, "luma_10to8"));
    try testing.expectEqual(@as(usize, 242), @offsetOf(HevcPart, "scaler_10to8"));
    try testing.expectEqual(@as(usize, 244), @offsetOf(HevcPart, "direct_reflist"));
    try testing.expectEqual(@as(usize, 276), @offsetOf(HevcPart, "st_rps_bits"));
    try testing.expectEqual(@as(usize, 96), @offsetOf(HevcScaling, "m8"));
    try testing.expectEqual(@as(usize, 480), @offsetOf(HevcScaling, "m16"));
    try testing.expectEqual(@as(usize, 864), @offsetOf(HevcScaling, "m32"));
    try testing.expect(scaling_at >= @sizeOf(HevcMessage) and scaling_at + @sizeOf(HevcScaling) <= 4096);
}

test "an H.265 stream's surfaces and context, in 8 bits and in 10" {
    const l = Layout.hevc(1920, 1080, 6, false, 6);
    try testing.expectEqual(@as(u32, 1920), l.width);
    try testing.expectEqual(@as(u32, 1080), l.height);
    try testing.expectEqual(@as(u32, 1920), l.ref_pitch);
    try testing.expectEqual(@as(u32, 1088), l.ref_rows);
    try testing.expectEqual(@as(u32, 1), l.sample_bytes);
    try testing.expectEqual(@as(u32, 2048), l.target_pitch);
    // 135 by 83 blocks with the margin, 16 bytes each for 17 numbers, and
    // 52 KiB.
    try testing.expectEqual(@as(u32, 135 * 83 * 16 * 17 + 52 * 1024), l.hw_bytes);
    const deep = Layout.hevc(3840, 2160, 7, true, 6);
    try testing.expectEqual(@as(u32, 3840), deep.ref_pitch);
    try testing.expectEqual(@as(u32, 2176), deep.ref_rows);
    try testing.expectEqual(@as(u32, 3840 * 2176 * 2), deep.refLuma());
    // 60 by 34 blocks of 64, a row 15360 bytes, 9 rows of the left edge.
    try testing.expectEqual(@as(u32, 17 * 15360 * 34 + 256 * 96 + 2 * (9 * 2 * 2048 + 1024)), deep.hw_bytes);
}

test "an H.265 picture's message: its parameter sets, references and sets" {
    var sps: vp.hevc.HevcSps = .{ .profile_idc = 2, .chroma_format_idc = 1, .bit_depth_luma = 10, .bit_depth_chroma = 10, .log2_max_poc_lsb = 8, .max_dec_pic_buffering = 5, .log2_min_cb = 3, .log2_ctb = 6, .log2_min_tb = 2, .log2_max_tb = 5, .max_th_depth_inter = 1, .sao = true, .amp = true, .temporal_mvp = true, .strong_intra_smoothing = true, .num_st_rps = 4, .scaling_enabled = true };
    sps.scaling = vp.hevc.HevcScaling.default();
    try testing.expect(hevcTakes(&sps));
    try testing.expectEqual(@as(u32, 6), hevcIds(&sps));
    sps.chroma_format_idc = 2;
    try testing.expect(!hevcTakes(&sps));
    sps.chroma_format_idc = 1;
    sps.bit_depth_chroma = 8;
    try testing.expect(!hevcTakes(&sps));
    sps.bit_depth_chroma = 10;

    var pps: vp.hevc.HevcPps = .{ .cabac_init_present = true, .sign_data_hiding = true, .loop_filter_across_slices = true, .beta_offset = -4, .tc_offset = 6, .cb_qp_offset = -1, .init_qp = 30, .num_ref_idx_default = .{ 3, 2 }, .log2_parallel_merge_level = 4, .tiles = true, .num_tile_columns = 3, .num_tile_rows = 2, .uniform_spacing = true };
    pps.scaling = vp.hevc.HevcScaling.default();
    pps.scaling.coef[3][3][5] = 77;
    pps.scaling.dc[1][3] = 20;
    pps.scaling.coef[0][2][15] = 9;
    pps.scaling_present = true;
    sps.width = 1920;
    sps.height = 1080;

    // Three references: two before (POC 6, then 4) and one after (8),
    // the third not used by the picture; the sets name their places.
    var pic: vp.VideoPicture = .{ .slot = 5, .poc = .{ 7, 7 }, .st_rps_bits = 13, .ref_count = 3 };
    pic.rps_count = .{ 1, 1, 1, 0, 0 };
    pic.rps[0][0] = 1;
    pic.rps[1][0] = 0;
    pic.rps[2][0] = 2;
    const refs = [_]HevcRef{ .{ .id = 4, .poc = 8 }, .{ .id = 1, .poc = 6 }, .{ .id = 2, .poc = 4 } };
    var message: HevcMessage = .{};
    var scaling: HevcScaling = .{};
    hevcPart(&message.hevc, &scaling, &sps, &pps, &pic, 3, &refs);
    const h = &message.hevc;
    try testing.expectEqual(@as(u32, 1 | 2 | 4 | (1 << 6) | (1 << 7) | (1 << 11)), h.sps_info_flags);
    try testing.expectEqual(@as(u32, 13), h.st_rps_bits);
    try testing.expectEqual(@as(u32, 4 | 8 | (1 << 11) | (1 << 13) | (1 << 14) | (1 << 15)), h.pps_info_flags);
    try testing.expectEqual(@as(u8, 2), h.bit_depth_luma_minus8);
    try testing.expectEqual(@as(u8, 4), h.log2_max_pic_order_cnt_lsb_minus4);
    try testing.expectEqual(@as(u8, 4), h.sps_max_dec_pic_buffering_minus1);
    try testing.expectEqual(@as(u8, 3), h.log2_diff_max_min_luma_coding_block_size);
    try testing.expectEqual(@as(u8, 3), h.log2_diff_max_min_transform_block_size);
    try testing.expectEqual(@as(i8, -2), h.pps_beta_offset_div2);
    try testing.expectEqual(@as(i8, 3), h.pps_tc_offset_div2);
    try testing.expectEqual(@as(i8, -1), h.pps_cb_qp_offset);
    try testing.expectEqual(@as(i8, 4), h.init_qp_minus26);
    try testing.expectEqual(@as(u8, 2), h.num_ref_idx_l0_default_active_minus1);
    try testing.expectEqual(@as(u8, 2), h.log2_parallel_merge_level_minus2);
    // 30 by 17 blocks of 64 in three columns and two rows, evenly.
    try testing.expectEqual(@as(u8, 2), h.num_tile_columns_minus1);
    try testing.expectEqualSlices(u16, &.{ 9, 9, 9, 0 }, h.column_width_minus1[0..4]);
    try testing.expectEqualSlices(u16, &.{ 7, 8, 0 }, h.row_height_minus1[0..3]);
    try testing.expectEqual(@as(u8, 3), h.curr_idx);
    try testing.expectEqual(@as(i32, 7), h.curr_poc);
    try testing.expectEqualSlices(u8, &.{ 4, 1, 2, no_ref }, h.ref_pic_list[0..4]);
    try testing.expectEqualSlices(i32, &.{ 8, 6, 4 }, h.poc_list[0..3]);
    try testing.expectEqualSlices(u8, &.{ 1, 0xFF }, h.ref_pic_set_st_curr_before[0..2]);
    try testing.expectEqualSlices(u8, &.{ 0, 0xFF }, h.ref_pic_set_st_curr_after[0..2]);
    try testing.expectEqual(@as(u8, 0xFF), h.ref_pic_set_lt_curr[0]);
    // The picture's own lists, the 32x32 ones the brightness's.
    try testing.expectEqual(@as(u8, 77), scaling.m32[1][5]);
    try testing.expectEqual(@as(u8, 20), h.scaling_dc_32x32[1]);
    try testing.expectEqual(@as(u8, 9), scaling.m4[2][15]);
    try testing.expectEqual(@as(u8, 16), scaling.m8[0][0]);
    try testing.expectEqual(@as(u8, 115), scaling.m16[0][63]);
    // 10 bits rounded into the 8-bit target.
    try testing.expectEqual(DITHER_ROUND, h.luma_10to8);
    try testing.expectEqual(@as(u8, 0), h.p010_mode);

    const layout = Layout.hevc(1920, 1080, 6, true, 6);
    hevcMessage(&message, layout, 0x55, 9, 4096, 0x80_0100_0000, &.{ 0x80_0200_0000, 0x80_0300_0000, 0x80_0400_0000 });
    const words: [*]const u32 = @ptrCast(&message);
    try testing.expectEqualSlices(u32, &.{ 40, 724, 3, 1, 0x55, 9, 2, 72, 188, 0, 0xD, 428, 296, 0, 0x10, 260, 168, 0 }, words[0..18]);
    try testing.expectEqual(@as(u32, 0x10), message.decode.stream_type);
    try testing.expectEqual(@as(u32, 1080), message.decode.height_in_samples);
    try testing.expectEqual(@as(u32, 1920), message.decode.db_pitch);
    try testing.expectEqual(@as(u32, 1088), message.decode.db_aligned_height);
    try testing.expectEqual(@as(u32, 3), message.dpb.array_size);
    try testing.expectEqual(@as(u32, 1920 * 1088 * 2), message.dpb.luma_aligned_size);
    try testing.expectEqual(@as(u32, 1920 / 2), message.dpb.chroma_pitch);
}
