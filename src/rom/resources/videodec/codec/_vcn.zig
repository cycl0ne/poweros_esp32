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
    return switch (codec) {
        types.VDCODEC_H265 => 0x10,
        types.VDCODEC_VP9 => 0x11,
        types.VDCODEC_AV1 => 0x13,
        else => 7,
    };
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
    probs: u64 = 0,
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
        .{ .at = 17, .address = buffers.probs },
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
const PART_VP9: u32 = 0xE;
const PART_AV1: u32 = 0x11;
const PART_DYNAMIC_DPB: u32 = 0x10;

/// What else an indirect buffer for decoding names: the picture's
/// slices, the surface it is written to, its scaling lists (H.264 and
/// H.265) or its probability table (VP9's; AV1's segments and film
/// grain), and the decoder's context for the stream.
const BUFFER_BITSTREAM: u32 = 1 << 2;
const BUFFER_TARGET: u32 = 1 << 3;
const BUFFER_SCALING: u32 = 1 << 9;
const BUFFER_CONTEXT: u32 = 1 << 11;
const BUFFER_PROBS: u32 = 1 << 12;
pub const decode_buffers: u32 = BUFFER_MESSAGE | BUFFER_BITSTREAM | BUFFER_TARGET | BUFFER_SCALING |
    BUFFER_CONTEXT | BUFFER_SESSION;
pub const probs_decode_buffers: u32 = BUFFER_MESSAGE | BUFFER_BITSTREAM | BUFFER_TARGET | BUFFER_PROBS |
    BUFFER_CONTEXT | BUFFER_SESSION;

/// The buffers a picture's message of `codec` goes with.
fn buffersOf(codec: u32) u32 {
    return if (codec == types.VDCODEC_VP9 or codec == types.VDCODEC_AV1) probs_decode_buffers else decode_buffers;
}

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
/// The largest VP9 picture the decoder takes, and the firmware numbers a
/// VP9 stream has: the pictures of its eight reference slots and the one
/// decoded.
pub const vp9_most_width: u32 = 8192;
pub const vp9_most_height: u32 = 4352;
pub const vp9_ids: u32 = 9;
/// The least a VP9 stream is made for: frames that grow up to it are
/// still predicted from the smaller pictures before them.
pub const vp9_least_width: u32 = 1920;
pub const vp9_least_height: u32 = 1088;
/// The largest AV1 picture the decoder takes, and the firmware numbers an
/// AV1 stream has: the pictures of its eight reference slots and the one
/// decoded.
pub const av1_most_width: u32 = 8192;
pub const av1_most_height: u32 = 4352;
pub const av1_ids: u32 = 9;
/// The firmware's numbers for the pictures it decodes and refers to:
/// 0 to 16, the most references and the picture decoded.
pub const most_ids: u32 = 17;

/// Where the scaling lists go in the message's page, and a VP9
/// picture's probability table.
const scaling_at: u32 = 2048;
const probs_at: u32 = 1024;

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

/// A VP9 frame: its uncompressed header's values - the compressed
/// header and the tiles the decoder reads itself, with the sizes of both
/// headers - the loop filter's level for each segment, reference and
/// mode, worked out here, and the firmware's numbers for the pictures of
/// the eight reference slots, for the three the frame refers to and for
/// itself.
pub const Vp9Part = extern struct {
    frame_header_flags: u32 = 0,
    frame_context_idx: u8 = 0,
    reset_frame_context: u8 = 0,
    curr_pic_idx: u8 = 0,
    interp_filter: u8 = 0,
    filter_level: u8 = 0,
    sharpness_level: u8 = 0,
    lf_adj_level: [8][4][2]u8 = @splat(@splat(@splat(0))),
    base_qindex: u8 = 0,
    y_dc_delta_q: i8 = 0,
    uv_ac_delta_q: i8 = 0,
    uv_dc_delta_q: i8 = 0,
    log2_tile_cols: u8 = 0,
    log2_tile_rows: u8 = 0,
    tx_mode: u8 = 0,
    reference_mode: u8 = 0,
    chroma_format: u8 = 0,
    ref_frame_map: [8]u8 = @splat(no_ref),
    frame_refs: [3]u8 = @splat(no_ref),
    ref_frame_sign_bias: [3]u8 = @splat(0),
    frame_to_show: u8 = 0,
    bit_depth_luma_minus8: u8 = 0,
    bit_depth_chroma_minus8: u8 = 0,
    p010_mode: u8 = 0,
    msb_mode: u8 = 0,
    luma_10to8: u8 = 0,
    chroma_10to8: u8 = 0,
    vp9_frame_size: u32 = 0,
    compressed_header_size: u32 = 0,
    uncompressed_header_size: u32 = 0,
    reserved: [2]u8 = @splat(0),
};

/// A VP9 frame's probability table as the decoder reads it from its own
/// buffer: the probabilities' room, unused - the decoder keeps them in
/// the stream's context - and the segmentation: each segment's features'
/// values in a word (the quantizer's 16 bits, the loop filter's 8, the
/// reference's 4, then skip's), the trees' probabilities, whether the
/// values are absolute, each segment's features by bit.
pub const Vp9Tables = extern struct {
    probs: [2304]u8 = @splat(0),
    feature_data: [8]u32 = @splat(0),
    tree_probs: [7]u8 = @splat(0),
    pred_probs: [3]u8 = @splat(0),
    abs_delta: u8 = 0,
    feature_mask: [8]u8 = @splat(0),
    reserved: [205]u8 = @splat(0),
};

/// The whole of a VP9 frame's message.
pub const Vp9Message = extern struct {
    header: MessageHeader = .{},
    codec_index: MessageIndex = .{},
    dpb_index: MessageIndex = .{},
    decode: DecodePart = .{},
    dpb: DpbPart = .{},
    vp9: Vp9Part = .{},
};

comptime {
    if (@sizeOf(MessageHeader) != header_bytes or @sizeOf(DecodePart) != 188 or @sizeOf(DpbPart) != 168 or
        @sizeOf(AvcPart) != 1124 or @sizeOf(AvcScaling) != 224 or @sizeOf(AvcMessage) != 1552 or
        @sizeOf(HevcPart) != 296 or @sizeOf(HevcScaling) != 992 or @sizeOf(HevcMessage) != 724 or
        @sizeOf(Vp9Part) != 120 or @sizeOf(Vp9Tables) != 2560 or @sizeOf(Vp9Message) != 548)
        @compileError("a decoding message's part is not the size the decoder reads");
    if (probs_at + @sizeOf(Vp9Tables) > 4096 or @sizeOf(Vp9Message) > probs_at or @sizeOf(AvcMessage) > scaling_at)
        @compileError("a decoding message's parts overlap in its page");
}

/// The VP9 default probabilities (10.5) as the decoder keeps a set of
/// them in the stream's context, which starts with one: the update
/// masks of the vectors' probabilities first (none), then the
/// coefficients', the modes', the references', the filters', the
/// partitions', the inter modes', skip's, the intra-inter, compound and
/// compound reference ones, the transform sizes' from 32x32 down, the
/// vectors' joints and each vector component's.
pub const vp9_defaults: [2072]u8 = vp9Defaults();

fn vp9Defaults() [2072]u8 {
    @setEvalBranchQuota(100_000);
    const p = vp.vp9.default_probs;
    var out: [2072]u8 = @splat(0);
    var filled: usize = 32;
    const parts = .{
        p.coef,     p.y_mode,    p.uv_mode,  p.single_ref, p.interp_filter, p.partition, p.inter_mode, p.skip,
        p.is_inter, p.comp_mode, p.comp_ref, p.tx32,       p.tx16,          p.tx8,       p.mv_joint,
    };
    inline for (parts) |part| {
        const bytes: [@sizeOf(@TypeOf(part))]u8 = @bitCast(part);
        @memcpy(out[filled..][0..bytes.len], &bytes);
        filled += bytes.len;
    }
    for (0..2) |i| {
        const component = .{
            [1]u8{p.mv_sign[i]}, p.mv_class[i], [1]u8{p.mv_class0_bit[i]}, p.mv_bits[i],
            p.mv_class0_fr[i],   p.mv_fr[i],    [1]u8{p.mv_class0_hp[i]},  [1]u8{p.mv_hp[i]},
        };
        inline for (component) |part| {
            const bytes: [@sizeOf(@TypeOf(part))]u8 = @bitCast(part);
            @memcpy(out[filled..][0..bytes.len], &bytes);
            filled += bytes.len;
        }
    }
    if (filled != 2071) @compileError("the VP9 default probabilities are not laid out as the decoder reads them");
    return out;
}

/// An AV1 frame: its header's values as the decoder takes them - the
/// tiles it reads itself, from where each one is among the frame's bytes
/// - its flags in a word, its sizes and its tiles' starts in
/// superblocks, the firmware's numbers for the pictures of the eight
/// reference slots, for the seven it refers to and for itself, each
/// segment's features, the global motion of each reference, and film
/// grain's values.
pub const Av1Part = extern struct {
    frame_header_flags: u32 = 0,
    current_frame_id: u32 = 0,
    frame_offset: u32 = 0,
    profile: u8 = 0,
    is_annexb: u8 = 0,
    frame_type: u8 = 0,
    primary_ref_frame: u8 = 0,
    curr_pic_idx: u8 = 0,
    sb_size: u8 = 0,
    interp_filter: u8 = 0,
    filter_level: [2]u8 = .{ 0, 0 },
    filter_level_u: u8 = 0,
    filter_level_v: u8 = 0,
    sharpness_level: u8 = 0,
    ref_deltas: [8]i8 = @splat(0),
    mode_deltas: [2]i8 = .{ 0, 0 },
    base_qindex: u8 = 0,
    y_dc_delta_q: i8 = 0,
    u_dc_delta_q: i8 = 0,
    v_dc_delta_q: i8 = 0,
    u_ac_delta_q: i8 = 0,
    v_ac_delta_q: i8 = 0,
    qm_y: u8 = 0,
    qm_u: u8 = 0,
    qm_v: u8 = 0,
    delta_q_res: u8 = 0,
    delta_lf_res: u8 = 0,
    tile_cols: u8 = 0,
    tile_rows: u8 = 0,
    tx_mode: u8 = 0,
    reference_mode: u8 = 0,
    chroma_format: u8 = 0,
    tile_size_bytes: u32 = 0,
    context_update_tile_id: u32 = 0,
    tile_col_start_sb: [65]u32 = @splat(0),
    tile_row_start_sb: [65]u32 = @splat(0),
    max_width: u32 = 0,
    max_height: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    superres_upscaled_width: u32 = 0,
    superres_scale_denominator: u8 = 0,
    order_hint_bits: u8 = 0,
    ref_frame_map: [8]u8 = @splat(no_ref),
    ref_frame_offset: [8]u32 = @splat(0),
    frame_refs: [7]u8 = @splat(no_ref),
    ref_frame_sign_bias: [7]u8 = @splat(0),
    bit_depth_luma_minus8: u8 = 0,
    bit_depth_chroma_minus8: u8 = 0,
    feature_data: [8][8]i32 = @splat(@splat(0)),
    feature_mask: [8]u8 = @splat(0),
    cdef_damping: u8 = 0,
    cdef_bits: u8 = 0,
    cdef_strengths: [16]u16 = @splat(0),
    cdef_uv_strengths: [16]u16 = @splat(0),
    frame_restoration_type: [3]u8 = @splat(0),
    log2_restoration_unit_size_minus5: [3]u8 = @splat(0),
    p010_mode: u8 = 0,
    msb_mode: u8 = 0,
    luma_10to8: u8 = 0,
    chroma_10to8: u8 = 0,
    preskip_segid: u8 = 0,
    last_active_segid: u8 = 0,
    seg_lossless_flag: u8 = 0,
    coded_lossless: u8 = 0,
    film_grain: Av1Grain = .{},
    uncompressed_header_size: u32 = 0,
    global_motion: [8]Av1Warp = @splat(.{}),
    tile_info: [256]Av1Tile = @splat(.{}),
    reserved: [3]u8 = @splat(0),
    av1_intrabc_workaround: u32 = 0,
};

/// Film grain's values as the decoder applies them to the picture it
/// writes into the target: the scaling functions' points, the
/// auto-regressive filter's lag, coefficients and shift, how much of
/// the brightness goes into each colour, the random numbers' seed.
pub const Av1Grain = extern struct {
    apply_grain: u8 = 0,
    scaling_points_y: [14][2]u8 = @splat(.{ 0, 0 }),
    num_y_points: u8 = 0,
    scaling_points_cb: [10][2]u8 = @splat(.{ 0, 0 }),
    num_cb_points: u8 = 0,
    scaling_points_cr: [10][2]u8 = @splat(.{ 0, 0 }),
    num_cr_points: u8 = 0,
    scaling_shift: u8 = 0,
    ar_coeff_lag: u8 = 0,
    ar_coeffs_y: [24]i8 = @splat(0),
    ar_coeffs_cb: [25]i8 = @splat(0),
    ar_coeffs_cr: [25]i8 = @splat(0),
    ar_coeff_shift: u8 = 0,
    cb_mult: u8 = 0,
    cb_luma_mult: u8 = 0,
    cb_offset: u16 = 0,
    cr_mult: u8 = 0,
    cr_luma_mult: u8 = 0,
    cr_offset: u16 = 0,
    overlap_flag: u8 = 0,
    clip_to_restricted_range: u8 = 0,
    bit_depth_minus_8: u8 = 0,
    chroma_scaling_from_luma: u8 = 0,
    grain_scale_shift: u8 = 0,
    random_seed: u16 = 0,
};

/// A reference's global motion: its kind and its matrix's six
/// parameters; the two places after them and the shears stay 0.
pub const Av1Warp = extern struct {
    wmtype: u32 = 0,
    wmmat: [8]i32 = @splat(0),
    alpha: i16 = 0,
    beta: i16 = 0,
    gamma: i16 = 0,
    delta: i16 = 0,
};

/// Where a tile is among the frame's bytes, and how many it takes.
pub const Av1Tile = extern struct {
    offset: u32 = 0,
    size: u32 = 0,
};

/// An AV1 frame's tables as the decoder reads them from their own
/// buffer: the segments' features - each one's values, then which are
/// on, by bit - and film grain's: the blocks the grain is taken from,
/// of brightness and of each colour, in rows as the decoder reads them,
/// and the scaling functions as tables of 256.
pub const Av1Tables = extern struct {
    feature_data: [8][8]i16 = @splat(@splat(0)),
    feature_mask: [8]u8 = @splat(0),
    reserved: [120]u8 = @splat(0),
    luma_grain_block: [64][96]i16 = @splat(@splat(0)),
    cb_grain_block: [32][48]i16 = @splat(@splat(0)),
    cr_grain_block: [32][48]i16 = @splat(@splat(0)),
    scaling_lut_y: [256]i16 = @splat(0),
    scaling_lut_cb: [256]i16 = @splat(0),
    scaling_lut_cr: [256]i16 = @splat(0),
    temp_tile_left_seed: [256]u16 = @splat(0),
};

/// The whole of an AV1 frame's message; its tables are too large for the
/// message's page and go into a piece of the stream's own.
pub const Av1Message = extern struct {
    header: MessageHeader = .{},
    codec_index: MessageIndex = .{},
    dpb_index: MessageIndex = .{},
    decode: DecodePart = .{},
    dpb: DpbPart = .{},
    av1: Av1Part = .{},
};

/// An AV1 frame context as the decoder keeps it: a frame's CDFs, each
/// as 32768 less its cumulative probabilities, then 0 and the adaptation
/// counter's 0, each padded to the decoder's length; and the room one
/// takes in the stream's context.
const Av1FrameContext = extern struct {
    txb_skip_cdf: [5][13][3]u16,
    eob_extra_cdf: [5][2][9][3]u16,
    dc_sign_cdf: [2][3][3]u16,
    newmv_cdf: [6][3]u16,
    zeromv_cdf: [2][3]u16,
    refmv_cdf: [6][3]u16,
    drl_cdf: [3][3]u16,
    compound_type_cdf: [22][3]u16,
    interintra_cdf: [4][3]u16,
    wedge_interintra_cdf: [22][3]u16,
    obmc_cdf: [22][3]u16,
    comp_inter_cdf: [5][3]u16,
    single_ref_cdf: [3][6][3]u16,
    comp_ref_type_cdf: [5][3]u16,
    uni_comp_ref_cdf: [3][3][3]u16,
    comp_ref_cdf: [3][3][3]u16,
    comp_bwdref_cdf: [3][2][3]u16,
    txfm_partition_cdf: [21][3]u16,
    skip_mode_cdfs: [3][3]u16,
    skip_cdfs: [3][3]u16,
    intra_inter_cdf: [4][3]u16,
    palette_y_mode_cdf: [9][3][3]u16,
    palette_uv_mode_cdf: [2][3]u16,
    filter_intra_cdfs: [22][3]u16,
    wiener_restore_cdf: [3]u16,
    sgrproj_restore_cdf: [3]u16,
    intrabc_cdf: [3]u16,
    nmvc_0_sign_cdf: [3]u16,
    nmvc_0_class0_hp_cdf: [3]u16,
    nmvc_0_hp_cdf: [3]u16,
    nmvc_0_class0_cdf: [3]u16,
    nmvc_0_bits_cdf: [10][3]u16,
    nmvc_1_sign_cdf: [3]u16,
    nmvc_1_class0_hp_cdf: [3]u16,
    nmvc_1_hp_cdf: [3]u16,
    nmvc_1_class0_cdf: [3]u16,
    nmvc_1_bits_cdf: [10][3]u16,
    ndvc_0_sign_cdf: [3]u16,
    ndvc_0_class0_hp_cdf: [3]u16,
    ndvc_0_hp_cdf: [3]u16,
    ndvc_0_class0_cdf: [3]u16,
    ndvc_0_bits_cdf: [10][3]u16,
    ndvc_1_sign_cdf: [3]u16,
    ndvc_1_class0_hp_cdf: [3]u16,
    ndvc_1_hp_cdf: [3]u16,
    ndvc_1_class0_cdf: [3]u16,
    ndvc_1_bits_cdf: [10][3]u16,
    pred_cdf: [3][3]u16,
    compound_index_cdf: [6][3]u16,
    comp_group_idx_cdf: [6][3]u16,
    reserve0: [8]u16,
    coeff_base_eob_cdf: [5][2][4][4]u16,
    motion_mode_cdf: [22][4]u16,
    switchable_restore_cdf: [4]u16,
    switchable_interp_cdf: [16][4]u16,
    tx_size_cdf: [4][3][4]u16,
    reserve1: [4]u16,
    coeff_base_cdf: [5][2][42][5]u16,
    coeff_br_cdf: [5][2][21][5]u16,
    interintra_mode_cdf: [4][5]u16,
    delta_q_cdf: [5]u16,
    delta_lf_multi_cdf: [4][5]u16,
    delta_lf_cdf: [5]u16,
    nmvc_joints_cdf: [5]u16,
    nmvc_0_class0_fp_cdf: [2][5]u16,
    nmvc_0_fp_cdf: [5]u16,
    nmvc_1_class0_fp_cdf: [2][5]u16,
    nmvc_1_fp_cdf: [5]u16,
    ndvc_joints_cdf: [5]u16,
    ndvc_0_class0_fp_cdf: [2][5]u16,
    ndvc_0_fp_cdf: [5]u16,
    ndvc_1_class0_fp_cdf: [2][5]u16,
    ndvc_1_fp_cdf: [5]u16,
    reserve2: [10]u16,
    eob_flag_cdf16: [2][2][6]u16,
    filter_intra_mode_cdf: [6]u16,
    eob_flag_cdf32: [2][2][7]u16,
    eob_flag_cdf64: [2][2][8]u16,
    palette_y_size_cdf: [9][8]u16,
    palette_uv_size_cdf: [9][8]u16,
    angle_delta_cdf: [8][8]u16,
    reserve3: [6]u16,
    eob_flag_cdf128: [2][2][9]u16,
    inter_compound_mode_cdf: [8][9]u16,
    palette_y_color_index_cdf: [7][5][9]u16,
    palette_uv_color_index_cdf: [7][5][9]u16,
    cfl_sign_cdf: [9]u16,
    tree_cdf: [9]u16,
    spatial_pred_seg_cdf: [3][9]u16,
    reserve4: [1]u16,
    eob_flag_cdf256: [2][2][10]u16,
    eob_flag_cdf512: [2][2][11]u16,
    partition_cdf: [20][11]u16,
    eob_flag_cdf1024: [2][2][12]u16,
    nmvc_0_classes_cdf: [12]u16,
    nmvc_1_classes_cdf: [12]u16,
    ndvc_0_classes_cdf: [12]u16,
    ndvc_1_classes_cdf: [12]u16,
    y_mode_cdf: [4][14]u16,
    kf_y_cdf: [5][5][14]u16,
    reserve5: [10]u16,
    uv_mode_cdf: [2][13][15]u16,
    reserve6: [10]u16,
    wedge_idx_cdf: [22][17]u16,
    intra_ext_tx_cdf: [2][4][13][17]u16,
    inter_ext_tx_cdf: [3][4][17]u16,
    cfl_alpha_cdf: [6][17]u16,
};
pub const av1_frame_context_bytes: u32 = 20480;

comptime {
    if (@sizeOf(Av1Part) != 3584 or @sizeOf(Av1Grain) != 166 or @sizeOf(Av1Warp) != 44 or
        @sizeOf(Av1Tables) != 20736 or @sizeOf(Av1Message) != 4012 or @sizeOf(Av1FrameContext) != 19552)
        @compileError("an AV1 frame's message or tables are not the size the decoder reads");
    if (@sizeOf(Av1Message) > 4096 or @sizeOf(Av1FrameContext) > av1_frame_context_bytes)
        @compileError("an AV1 frame's message does not fit its page, or a frame context its room");
}

/// The AV1 default CDFs (the specification's Default_*_Cdf tables) as
/// the stream's context starts with them: four frame contexts, one for
/// each class of the base quantizer index the coefficients' defaults are
/// by - the firmware takes the one a frame that starts from the defaults
/// needs. A place the specification has no CDF for stays 0.
pub const av1_defaults: [4 * av1_frame_context_bytes]u8 = av1Defaults();

fn av1Defaults() [4 * av1_frame_context_bytes]u8 {
    @setEvalBranchQuota(10_000_000);
    var out: [4 * av1_frame_context_bytes]u8 = @splat(0);
    for (0..4) |class| {
        var words: [@sizeOf(Av1FrameContext) / 2]u16 = @splat(0);
        av1Context(&words, class);
        const bytes: [@sizeOf(Av1FrameContext)]u8 = @bitCast(words);
        @memcpy(out[class * av1_frame_context_bytes ..][0..bytes.len], &bytes);
    }
    return out;
}

/// Frame context `words` filled with the default CDFs, the
/// coefficients' of quantizer class `class`.
fn av1Context(words: []u16, class: usize) void {
    const d = vp.av1.cdfs;
    putCdfs(words, "txb_skip_cdf", 0, d.default_txb_skip_cdf[class]);
    putCdfs(words, "eob_extra_cdf", 0, d.default_eob_extra_cdf[class]);
    putCdfs(words, "dc_sign_cdf", 0, d.default_dc_sign_cdf[class]);
    putCdfs(words, "newmv_cdf", 0, d.default_new_mv_cdf);
    putCdfs(words, "zeromv_cdf", 0, d.default_zero_mv_cdf);
    putCdfs(words, "refmv_cdf", 0, d.default_ref_mv_cdf);
    putCdfs(words, "drl_cdf", 0, d.default_drl_mode_cdf);
    putCdfs(words, "compound_type_cdf", 0, d.default_compound_type_cdf);
    // Block sizes from 8x8 on: the first, 4x4's, is a place of its own.
    putCdfs(words, "interintra_cdf", 1, d.default_inter_intra_cdf);
    putCdfs(words, "wedge_interintra_cdf", 0, d.default_wedge_inter_intra_cdf);
    putCdfs(words, "obmc_cdf", 0, d.default_use_obmc_cdf);
    putCdfs(words, "comp_inter_cdf", 0, d.default_comp_mode_cdf);
    putCdfs(words, "single_ref_cdf", 0, d.default_single_ref_cdf);
    putCdfs(words, "comp_ref_type_cdf", 0, d.default_comp_ref_type_cdf);
    putCdfs(words, "uni_comp_ref_cdf", 0, d.default_uni_comp_ref_cdf);
    putCdfs(words, "comp_ref_cdf", 0, d.default_comp_ref_cdf);
    putCdfs(words, "comp_bwdref_cdf", 0, d.default_comp_bwd_ref_cdf);
    putCdfs(words, "txfm_partition_cdf", 0, d.default_txfm_split_cdf);
    putCdfs(words, "skip_mode_cdfs", 0, d.default_skip_mode_cdf);
    putCdfs(words, "skip_cdfs", 0, d.default_skip_cdf);
    putCdfs(words, "intra_inter_cdf", 0, d.default_is_inter_cdf);
    putCdfs(words, "palette_y_mode_cdf", 0, d.default_palette_y_mode_cdf);
    putCdfs(words, "palette_uv_mode_cdf", 0, d.default_palette_uv_mode_cdf);
    putCdfs(words, "filter_intra_cdfs", 0, d.default_filter_intra_cdf);
    putCdfs(words, "wiener_restore_cdf", 0, d.default_use_wiener_cdf);
    putCdfs(words, "sgrproj_restore_cdf", 0, d.default_use_sgrproj_cdf);
    putCdfs(words, "intrabc_cdf", 0, d.default_intrabc_cdf);
    // The motion vectors' and intra block copy's vectors: each of the two
    // components.
    inline for (.{ "nmvc", "ndvc" }) |kind| {
        inline for (.{ "_0_", "_1_" }, 0..) |component, c| {
            const p = kind ++ component;
            putCdfs(words, p ++ "sign_cdf", 0, d.default_mv_sign_cdf);
            putCdfs(words, p ++ "class0_hp_cdf", 0, d.default_mv_class0_hp_cdf);
            putCdfs(words, p ++ "hp_cdf", 0, d.default_mv_hp_cdf);
            putCdfs(words, p ++ "class0_cdf", 0, d.default_mv_class0_bit_cdf);
            putCdfs(words, p ++ "bits_cdf", 0, d.default_mv_bit_cdf);
            putCdfs(words, p ++ "class0_fp_cdf", 0, d.default_mv_class0_fr_cdf[c]);
            putCdfs(words, p ++ "fp_cdf", 0, d.default_mv_fr_cdf[c]);
            putCdfs(words, p ++ "classes_cdf", 0, d.default_mv_class_cdf[c]);
        }
        putCdfs(words, kind ++ "_joints_cdf", 0, d.default_mv_joint_cdf);
    }
    putCdfs(words, "pred_cdf", 0, d.default_segment_id_predicted_cdf);
    putCdfs(words, "compound_index_cdf", 0, d.default_compound_idx_cdf);
    putCdfs(words, "comp_group_idx_cdf", 0, d.default_comp_group_idx_cdf);
    putCdfs(words, "coeff_base_eob_cdf", 0, d.default_coeff_base_eob_cdf[class]);
    putCdfs(words, "motion_mode_cdf", 0, d.default_motion_mode_cdf);
    putCdfs(words, "switchable_restore_cdf", 0, d.default_restoration_type_cdf);
    putCdfs(words, "switchable_interp_cdf", 0, d.default_interp_filter_cdf);
    // The transform sizes' depth, by the largest size, 8x8 first.
    putCdfs(words, "tx_size_cdf", 0, d.default_tx_8x8_cdf);
    putCdfs(words, "tx_size_cdf", 3, d.default_tx_16x16_cdf);
    putCdfs(words, "tx_size_cdf", 6, d.default_tx_32x32_cdf);
    putCdfs(words, "tx_size_cdf", 9, d.default_tx_64x64_cdf);
    putCdfs(words, "coeff_base_cdf", 0, d.default_coeff_base_cdf[class]);
    putCdfs(words, "coeff_br_cdf", 0, d.default_coeff_br_cdf[class]);
    putCdfs(words, "interintra_mode_cdf", 1, d.default_inter_intra_mode_cdf);
    putCdfs(words, "delta_q_cdf", 0, d.default_delta_q_cdf);
    for (0..4) |i| putCdfs(words, "delta_lf_multi_cdf", i, d.default_delta_lf_cdf);
    putCdfs(words, "delta_lf_cdf", 0, d.default_delta_lf_cdf);
    putCdfs(words, "eob_flag_cdf16", 0, d.default_eob_pt_16_cdf[class]);
    putCdfs(words, "filter_intra_mode_cdf", 0, d.default_filter_intra_mode_cdf);
    putCdfs(words, "eob_flag_cdf32", 0, d.default_eob_pt_32_cdf[class]);
    putCdfs(words, "eob_flag_cdf64", 0, d.default_eob_pt_64_cdf[class]);
    putCdfs(words, "palette_y_size_cdf", 0, d.default_palette_y_size_cdf);
    putCdfs(words, "palette_uv_size_cdf", 0, d.default_palette_uv_size_cdf);
    putCdfs(words, "angle_delta_cdf", 0, d.default_angle_delta_cdf);
    putCdfs(words, "eob_flag_cdf128", 0, d.default_eob_pt_128_cdf[class]);
    putCdfs(words, "inter_compound_mode_cdf", 0, d.default_compound_mode_cdf);
    // The palettes' colour indices, by the palette's size from 2.
    inline for (.{ "2", "3", "4", "5", "6", "7", "8" }, 0..) |size, n| {
        putCdfs(words, "palette_y_color_index_cdf", n * 5, @field(d, "default_palette_size_" ++ size ++ "_y_color_cdf"));
        putCdfs(words, "palette_uv_color_index_cdf", n * 5, @field(d, "default_palette_size_" ++ size ++ "_uv_color_cdf"));
    }
    putCdfs(words, "cfl_sign_cdf", 0, d.default_cfl_sign_cdf);
    putCdfs(words, "spatial_pred_seg_cdf", 0, d.default_segment_id_cdf);
    putCdfs(words, "eob_flag_cdf256", 0, d.default_eob_pt_256_cdf[class]);
    // 512 and 1024 have one context each: the second place stays 0.
    for (0..2) |plane| {
        putCdfs(words, "eob_flag_cdf512", plane * 2, d.default_eob_pt_512_cdf[class][plane]);
        putCdfs(words, "eob_flag_cdf1024", plane * 2, d.default_eob_pt_1024_cdf[class][plane]);
    }
    // Partitions by block size, four contexts each.
    putCdfs(words, "partition_cdf", 0, d.default_partition_w8_cdf);
    putCdfs(words, "partition_cdf", 4, d.default_partition_w16_cdf);
    putCdfs(words, "partition_cdf", 8, d.default_partition_w32_cdf);
    putCdfs(words, "partition_cdf", 12, d.default_partition_w64_cdf);
    putCdfs(words, "partition_cdf", 16, d.default_partition_w128_cdf);
    putCdfs(words, "y_mode_cdf", 0, d.default_y_mode_cdf);
    putCdfs(words, "kf_y_cdf", 0, d.default_intra_frame_y_mode_cdf);
    putCdfs(words, "uv_mode_cdf", 0, d.default_uv_mode_cfl_not_allowed_cdf);
    putCdfs(words, "uv_mode_cdf", 13, d.default_uv_mode_cfl_allowed_cdf);
    putCdfs(words, "wedge_idx_cdf", 0, d.default_wedge_index_cdf);
    // The transform types: intra set 1 for 4x4 and 8x8, set 2 for 4x4 to
    // 16x16; inter set 1 for 4x4 and 8x8, set 2 for 16x16, set 3 for all
    // four.
    putCdfs(words, "intra_ext_tx_cdf", 0, d.default_intra_tx_type_set1_cdf);
    putCdfs(words, "intra_ext_tx_cdf", 4 * 13, d.default_intra_tx_type_set2_cdf);
    putCdfs(words, "inter_ext_tx_cdf", 0, d.default_inter_tx_type_set1_cdf);
    putCdfs(words, "inter_ext_tx_cdf", 4 + 2, d.default_inter_tx_type_set2_cdf);
    putCdfs(words, "inter_ext_tx_cdf", 8, d.default_inter_tx_type_set3_cdf);
    putCdfs(words, "cfl_alpha_cdf", 0, d.default_cfl_alpha_cdf);
}

/// The CDFs of `from`, each in the specification's form - its
/// cumulative probabilities up to 32768, then the counter - written into
/// field `name` of the frame context in `words` from its `skip`th row
/// on, one to a row.
fn putCdfs(words: []u16, comptime name: []const u8, skip: usize, from: anytype) void {
    const Field = @FieldType(Av1FrameContext, name);
    const row = innermost(Field);
    const From = @TypeOf(from);
    const length = innermost(From);
    const flat: [@sizeOf(From) / 2]u16 = @bitCast(from);
    const rows = flat.len / length;
    if (length > row or (skip + rows) * row > @sizeOf(Field) / 2) @panic("a default CDF does not fit its place");
    const first = @offsetOf(Av1FrameContext, name) / 2 + skip * row;
    for (0..rows) |r| {
        for (0..length - 1) |i| words[first + r * row + i] = 32768 - flat[r * length + i];
    }
}

/// The length of an array's innermost arrays.
fn innermost(comptime T: type) usize {
    const info = @typeInfo(T).array;
    return if (@typeInfo(info.child) == .array) innermost(info.child) else info.len;
}

/// An AV1 stream's context, for any size: thirteen frame contexts - the
/// four of default CDFs, and one for each of the nine firmware numbers -
/// then for each number 512 bytes and five times 256 for each of 64 by
/// 34 superblocks of 128 samples; and the rows of superblocks the loop
/// filter, the upscaling, the output and film grain keep, each the
/// larger of what superblocks of 64 and of 128 samples take for the
/// largest picture, twice; and 68 blocks of 512 bytes.
pub const av1_context_bytes: u32 = av1ContextBytes();

fn av1ContextBytes() u32 {
    const frames = (av1_ids + 4) * av1_frame_context_bytes;
    const pictures = av1_ids * 64 * 34 * (512 + 5 * 256);
    const pitch_64 = alignUp(32 * 68, 256) * 2;
    const pitch_128 = alignUp(32 * 34, 256) * 2;
    // Each buffer's rows, for superblocks of 64 and of 128.
    const kept = [_][2]u32{ .{ 1728, 3008 }, .{ 3232, 6208 }, .{ 1312, 2336 }, .{ 384, 640 } };
    var rows: u32 = 0;
    for (kept) |k| rows += @max(pitch_64 * (alignUp(k[0], 64) / 64), pitch_128 * (alignUp(k[1], 64) / 64));
    return frames + pictures + 2 * rows + 68 * 512;
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

    /// A VP9 stream of `width` by `height` samples, `deep` past 8 bits:
    /// its references' rows on 64 samples each way, and the decoder's
    /// context as large for any size - five sets of probabilities, the
    /// vectors and segment maps of the frames, the left edges of the
    /// tiles, and for the deeper samples their own edges too.
    pub fn vp9(width: u32, height: u32, deep: bool) Layout {
        const deep_bytes: u32 = if (deep) 8 * 2 * 4096 else 0;
        return .{
            .width = width,
            .height = height,
            .ids = vp9_ids,
            .ref_pitch = alignUp(width, 64),
            .ref_rows = alignUp(height, 64),
            .sample_bytes = if (deep) 2 else 1,
            .target_pitch = alignUp(width, 256),
            .target_rows = alignUp(height, 32),
            .hw_bytes = 2304 * 5 + 32 * 2 * 128 * 68 + 9 * 64 * 2 * 128 * 68 + 8 * 2 * 2 * 8192 + deep_bytes,
        };
    }

    /// An AV1 stream of `width` by `height` samples, `deep` past 8 bits:
    /// laid out as VP9's, with an AV1 stream's context.
    pub fn av1(width: u32, height: u32, deep: bool) Layout {
        var layout = vp9(width, height, deep);
        layout.ids = av1_ids;
        layout.hw_bytes = av1_context_bytes;
        return layout;
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

/// The rest of a VP9 frame's message, as `avcMessage`: `refs` are the
/// eight reference slots' surfaces, by slot.
pub fn vp9Message(m: *Vp9Message, layout: Layout, stream: u32, number: u32, bitstream_bytes: u32, current: u64, refs: *const [8]u64) void {
    pictureMessage(Vp9Message, m, "vp9", PART_VP9, types.VDCODEC_VP9, layout, stream, number, bitstream_bytes, current, refs);
}

/// The rest of an AV1 frame's message, as `vp9Message`.
pub fn av1Message(m: *Av1Message, layout: Layout, stream: u32, number: u32, bitstream_bytes: u32, current: u64, refs: *const [8]u64) void {
    pictureMessage(Av1Message, m, "av1", PART_AV1, types.VDCODEC_AV1, layout, stream, number, bitstream_bytes, current, refs);
}

/// A picture's message of any codec but its codec's part, which is
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
        .decode_buffer_flags = buffersOf(codec) & ~BUFFER_SESSION,
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

/// The codec's part and the probability table of the VP9 frame of
/// header `h`, decoded into firmware number `id`; `map` holds the
/// firmware's number for the picture of each reference slot (`no_ref`
/// for an empty one). The loop filter's levels are worked out as the
/// frame's filter takes them (8.8.1): each segment's level, as its
/// feature says - itself or a change of the frame's - and that changed
/// by the reference's and the mode's deltas, twice over where the
/// frame's level is 32 or more.
pub fn vp9Part(part: *Vp9Part, tables: *Vp9Tables, h: *const vp.vp9.Vp9Header, id: u8, map: *const [8]u8) void {
    const v9 = vp.vp9;
    const sg = &h.segmentation;
    const lf = &h.loop_filter;
    part.* = .{};
    part.frame_header_flags = flag(h.frame_type != v9.KEY_FRAME, 1) | flag(h.error_resilient_mode, 2) |
        flag(h.intra_only, 3) | flag(h.allow_high_precision_mv, 4) | flag(h.refresh_frame_context, 5) |
        flag(h.frame_parallel_decoding_mode, 6) | flag(sg.enabled, 7) | flag(sg.enabled and sg.update_map, 8) |
        flag(sg.enabled and sg.temporal_update, 9) | flag(sg.enabled and sg.update_data, 10) |
        flag(lf.delta_enabled, 11) | flag(lf.delta_update, 12) | flag(h.use_prev_frame_mvs, 13) |
        // The decoder is given the uncompressed header's values, and reads
        // the frame from its start.
        flag(true, 14);
    // A frame that resets what came before uses the first context.
    part.frame_context_idx = if (h.reset_past) 0 else h.frame_context_idx;
    part.reset_frame_context = h.reset_frame_context;
    part.curr_pic_idx = id;
    part.interp_filter = h.interp_filter;
    part.filter_level = lf.level;
    part.sharpness_level = lf.sharpness;
    part.base_qindex = h.base_q_idx;
    part.y_dc_delta_q = h.delta_q_y_dc;
    part.uv_ac_delta_q = h.delta_q_uv_ac;
    part.uv_dc_delta_q = h.delta_q_uv_dc;
    part.log2_tile_cols = h.tile_cols_log2;
    part.log2_tile_rows = h.tile_rows_log2;
    part.chroma_format = 1;
    part.bit_depth_luma_minus8 = h.bit_depth -| 8;
    part.bit_depth_chroma_minus8 = h.bit_depth -| 8;
    part.uncompressed_header_size = h.uncompressed_bytes;
    part.compressed_header_size = h.compressed_bytes;
    if (h.bit_depth > 8) {
        part.luma_10to8 = DITHER_ROUND;
        part.chroma_10to8 = DITHER_ROUND;
    }

    const shift: u5 = @intCast(lf.level >> 5);
    for (0..8) |seg| {
        var level: i32 = lf.level;
        if (sg.active(@intCast(seg), v9.SEG_LVL_ALT_L)) {
            const data: i32 = sg.feature_data[seg][v9.SEG_LVL_ALT_L];
            level = filterLevel(if (sg.abs_delta) data else data + level);
        }
        const levels = &part.lf_adj_level[seg];
        if (!lf.delta_enabled) {
            levels[0][0] = @intCast(level);
            for (levels[1..]) |*by_mode| by_mode.* = .{ @intCast(level), @intCast(level) };
            continue;
        }
        levels[0][0] = @intCast(filterLevel(level + (@as(i32, lf.ref_deltas[0]) << shift)));
        for (levels[1..], 1..) |*by_mode, ref| {
            for (by_mode, 0..) |*out, mode| {
                const changed = level + ((@as(i32, lf.ref_deltas[ref]) + lf.mode_deltas[mode]) << shift);
                out.* = @intCast(filterLevel(changed));
            }
        }
    }

    part.ref_frame_map = map.*;
    for (0..3) |i| {
        part.frame_refs[i] = map[h.ref_frame_idx[i] & 7];
        part.ref_frame_sign_bias[i] = @intFromBool(h.ref_frame_sign_bias[i + 1]);
    }

    tables.* = .{};
    if (sg.enabled) {
        for (0..8) |seg| {
            const d = sg.feature_data[seg];
            tables.feature_data[seg] = @as(u32, @as(u16, @bitCast(d[0]))) |
                (@as(u32, @as(u8, @truncate(@as(u16, @bitCast(d[1]))))) << 16) |
                (@as(u32, @as(u4, @truncate(@as(u16, @bitCast(d[2]))))) << 24) |
                (@as(u32, @as(u4, @truncate(@as(u16, @bitCast(d[3]))))) << 28);
            var mask: u8 = 0;
            for (sg.feature_enabled[seg], 0..) |on, feature| mask |= @as(u8, @intFromBool(on)) << @intCast(feature);
            tables.feature_mask[seg] = mask;
        }
        tables.tree_probs = sg.tree_probs;
        tables.pred_probs = sg.pred_probs;
        tables.abs_delta = @intFromBool(sg.abs_delta);
    }
}

/// The flags of an AV1 frame's part, a bit each (its header's and its
/// sequence header's).
const AV1_SHOW_FRAME: u5 = 0;
const AV1_DISABLE_CDF_UPDATE: u5 = 1;
const AV1_REFRESH_FRAME_CONTEXT: u5 = 2;
const AV1_INTRA_ONLY: u5 = 3;
const AV1_ALLOW_INTRABC: u5 = 4;
const AV1_ALLOW_HIGH_PRECISION_MV: u5 = 5;
const AV1_MONOCHROME: u5 = 6;
const AV1_SKIP_MODE_FLAG: u5 = 7;
const AV1_USING_QMATRIX: u5 = 8;
const AV1_ENABLE_FILTER_INTRA: u5 = 9;
const AV1_ENABLE_INTRA_EDGE_FILTER: u5 = 10;
const AV1_ENABLE_INTERINTRA_COMPOUND: u5 = 11;
const AV1_ENABLE_MASKED_COMPOUND: u5 = 12;
const AV1_ALLOW_WARPED_MOTION: u5 = 13;
const AV1_ENABLE_DUAL_FILTER: u5 = 14;
const AV1_ENABLE_ORDER_HINT: u5 = 15;
const AV1_ENABLE_JNT_COMP: u5 = 16;
const AV1_ALLOW_REF_FRAME_MVS: u5 = 17;
const AV1_ALLOW_SCREEN_CONTENT_TOOLS: u5 = 18;
const AV1_FORCE_INTEGER_MV: u5 = 19;
const AV1_MODE_REF_DELTA_ENABLED: u5 = 20;
const AV1_MODE_REF_DELTA_UPDATE: u5 = 21;
const AV1_DELTA_Q_PRESENT: u5 = 22;
const AV1_DELTA_LF_PRESENT: u5 = 23;
const AV1_REDUCED_TX_SET: u5 = 24;
const AV1_SEGMENTATION_ENABLED: u5 = 25;
const AV1_SEGMENTATION_UPDATE_MAP: u5 = 26;
const AV1_SEGMENTATION_TEMPORAL_UPDATE: u5 = 27;
const AV1_DELTA_LF_MULTI: u5 = 28;
const AV1_SWITCHABLE_MOTION_MODE: u5 = 29;
const AV1_DISABLE_REF_FRAME_MVS: u5 = 31;

/// The most points a film grain scaling function has, of brightness and
/// of each colour, and the most tiles a frame's part says where they are.
const av1_most_y_points = 14;
const av1_most_chroma_points = 10;
pub const av1_most_tiles = 256;

/// The codec's part and the tables of the AV1 frame of header `h`, read
/// with sequence header `seq` and decoded into firmware number `id` in a
/// stream laid out as `layout`. `map` holds the firmware's number for the
/// picture of each reference slot (`no_ref` for an empty one) - a key
/// frame that is shown refers to none - and `tiles` where each tile is
/// among the frame's bytes; film grain's tables are made in `blocks`.
///
/// The header's values go as they are but these: the quantizer matrices
/// as 0xF0 and the level, or 0xFF for none; the delta resolutions as the
/// step itself; the tiles' starts in superblocks, and the end after the
/// last; CDEF's strengths as the primary's times 4 and the secondary as
/// coded; the restoration unit's size as its logarithm less 5 (3 where
/// no plane is restored); each reference's sign bias by its place among
/// the seven; samples deeper than 8 bits rounded into the 8-bit target.
pub fn av1Part(part: *Av1Part, tables: *Av1Tables, blocks: *Av1GrainBlocks, seq: *const vp.av1.Av1Sequence, h: *const vp.av1.Av1FrameHeader, layout: Layout, id: u8, map: *const [8]u8, tiles: []const Av1Tile) void {
    const av1 = vp.av1;
    part.* = .{};
    part.frame_header_flags = flag(h.show_frame, AV1_SHOW_FRAME) | flag(h.disable_cdf_update, AV1_DISABLE_CDF_UPDATE) |
        flag(!h.disable_frame_end_update_cdf, AV1_REFRESH_FRAME_CONTEXT) |
        flag(h.frame_type == av1.INTRA_ONLY_FRAME, AV1_INTRA_ONLY) | flag(h.allow_intrabc, AV1_ALLOW_INTRABC) |
        flag(h.allow_high_precision_mv, AV1_ALLOW_HIGH_PRECISION_MV) | flag(seq.mono_chrome, AV1_MONOCHROME) |
        flag(h.skip_mode_present, AV1_SKIP_MODE_FLAG) | flag(h.using_qmatrix, AV1_USING_QMATRIX) |
        flag(seq.enable_filter_intra, AV1_ENABLE_FILTER_INTRA) | flag(seq.enable_intra_edge_filter, AV1_ENABLE_INTRA_EDGE_FILTER) |
        flag(seq.enable_interintra_compound, AV1_ENABLE_INTERINTRA_COMPOUND) |
        flag(seq.enable_masked_compound, AV1_ENABLE_MASKED_COMPOUND) | flag(h.allow_warped_motion, AV1_ALLOW_WARPED_MOTION) |
        flag(seq.enable_dual_filter, AV1_ENABLE_DUAL_FILTER) | flag(seq.enable_order_hint, AV1_ENABLE_ORDER_HINT) |
        flag(seq.enable_jnt_comp, AV1_ENABLE_JNT_COMP) | flag(h.use_ref_frame_mvs, AV1_ALLOW_REF_FRAME_MVS) |
        flag(h.allow_screen_content_tools, AV1_ALLOW_SCREEN_CONTENT_TOOLS) | flag(h.force_integer_mv, AV1_FORCE_INTEGER_MV) |
        flag(h.loop_filter_delta_enabled, AV1_MODE_REF_DELTA_ENABLED) |
        flag(h.loop_filter_delta_update, AV1_MODE_REF_DELTA_UPDATE) | flag(h.delta_q_present, AV1_DELTA_Q_PRESENT) |
        flag(h.delta_lf_present, AV1_DELTA_LF_PRESENT) | flag(h.reduced_tx_set, AV1_REDUCED_TX_SET) |
        flag(h.segmentation_enabled, AV1_SEGMENTATION_ENABLED) | flag(h.segmentation_update_map, AV1_SEGMENTATION_UPDATE_MAP) |
        flag(h.segmentation_temporal_update, AV1_SEGMENTATION_TEMPORAL_UPDATE) | flag(h.delta_lf_multi, AV1_DELTA_LF_MULTI) |
        flag(h.is_motion_mode_switchable, AV1_SWITCHABLE_MOTION_MODE) | flag(!seq.enable_ref_frame_mvs, AV1_DISABLE_REF_FRAME_MVS);
    part.current_frame_id = h.current_frame_id;
    part.frame_offset = h.order_hint;
    part.profile = seq.seq_profile;
    part.frame_type = h.frame_type;
    part.primary_ref_frame = h.primary_ref_frame;
    part.curr_pic_idx = id;
    part.sb_size = @intFromBool(seq.use_128x128_superblock);
    part.interp_filter = h.interpolation_filter;
    part.filter_level = .{ h.loop_filter_level[0], h.loop_filter_level[1] };
    part.filter_level_u = h.loop_filter_level[2];
    part.filter_level_v = h.loop_filter_level[3];
    part.sharpness_level = h.loop_filter_sharpness;
    part.ref_deltas = h.loop_filter_ref_deltas;
    part.mode_deltas = h.loop_filter_mode_deltas;
    part.base_qindex = h.base_q_idx;
    part.y_dc_delta_q = h.delta_q_y_dc;
    part.u_dc_delta_q = h.delta_q_u_dc;
    part.v_dc_delta_q = h.delta_q_v_dc;
    part.u_ac_delta_q = h.delta_q_u_ac;
    part.v_ac_delta_q = h.delta_q_v_ac;
    part.qm_y = if (h.using_qmatrix) h.qm_y | 0xF0 else 0xFF;
    part.qm_u = if (h.using_qmatrix) h.qm_u | 0xF0 else 0xFF;
    part.qm_v = if (h.using_qmatrix) h.qm_v | 0xF0 else 0xFF;
    part.delta_q_res = @as(u8, 1) << @intCast(h.delta_q_res);
    part.delta_lf_res = @as(u8, 1) << @intCast(h.delta_lf_res);
    part.tile_cols = @intCast(h.tile_cols);
    part.tile_rows = @intCast(h.tile_rows);
    part.tx_mode = h.tx_mode;
    part.reference_mode = if (h.reference_select) 2 else 0;
    part.chroma_format = if (seq.mono_chrome) 0 else 1;
    part.tile_size_bytes = 0xFF;
    part.context_update_tile_id = h.context_update_tile_id;
    const sb_shift: u5 = if (seq.use_128x128_superblock) 5 else 4;
    const sb_mis = @as(u32, 1) << sb_shift;
    for (0..h.tile_cols) |i| part.tile_col_start_sb[i] = h.mi_col_starts[i] >> sb_shift;
    part.tile_col_start_sb[h.tile_cols] = (h.mi_cols + sb_mis - 1) >> sb_shift;
    for (0..h.tile_rows) |i| part.tile_row_start_sb[i] = h.mi_row_starts[i] >> sb_shift;
    part.tile_row_start_sb[h.tile_rows] = (h.mi_rows + sb_mis - 1) >> sb_shift;
    part.max_width = layout.width;
    part.max_height = layout.height;
    part.width = h.frame_width;
    part.height = h.frame_height;
    part.superres_upscaled_width = h.upscaled_width;
    part.superres_scale_denominator = @intCast(h.superres_denom);
    part.order_hint_bits = seq.order_hint_bits;
    if (h.frame_type != av1.KEY_FRAME or !h.show_frame) part.ref_frame_map = map.*;
    for (0..7) |i| {
        part.frame_refs[i] = part.ref_frame_map[h.ref_frame_idx[i] & 7];
        part.ref_frame_sign_bias[i] = @intFromBool(h.ref_frame_sign_bias[av1.LAST_FRAME + i]);
    }
    part.bit_depth_luma_minus8 = seq.bit_depth - 8;
    part.bit_depth_chroma_minus8 = seq.bit_depth - 8;
    for (0..av1.MAX_SEGMENTS) |seg| {
        var mask: u8 = 0;
        for (0..av1.SEG_LVL_MAX) |feature| {
            part.feature_data[seg][feature] = h.feature_data[seg][feature];
            if (h.feature_enabled[seg][feature]) mask |= @as(u8, 1) << @intCast(feature);
        }
        part.feature_mask[seg] = mask;
        if (h.lossless[seg]) part.seg_lossless_flag |= @as(u8, 1) << @intCast(seg);
    }
    tables.feature_data = h.feature_data;
    tables.feature_mask = part.feature_mask;
    part.preskip_segid = @intFromBool(h.seg_id_pre_skip);
    part.last_active_segid = h.last_active_seg_id;
    part.cdef_damping = h.cdef_damping;
    part.cdef_bits = h.cdef_bits;
    for (0..8) |i| {
        part.cdef_strengths[i] = cdefStrength(h.cdef_y_pri_strength[i], h.cdef_y_sec_strength[i]);
        part.cdef_uv_strengths[i] = cdefStrength(h.cdef_uv_pri_strength[i], h.cdef_uv_sec_strength[i]);
    }
    part.frame_restoration_type = h.frame_restoration_type;
    for (&part.log2_restoration_unit_size_minus5, h.loop_restoration_size) |*log2_minus5, size| {
        log2_minus5.* = if (h.uses_lr) @as(u8, @intCast(31 - @clz(@max(size, 32)))) - 5 else 3;
    }
    if (seq.bit_depth > 8) {
        part.luma_10to8 = DITHER_ROUND;
        part.chroma_10to8 = DITHER_ROUND;
    }
    // Film grain where the frame has it: the decoder applies it to the
    // target, the reference surface keeps the picture without.
    const grain = &h.film_grain;
    if (grain.apply_grain) {
        const fg = &part.film_grain;
        fg.apply_grain = 1;
        fg.random_seed = grain.grain_seed;
        fg.grain_scale_shift = grain.grain_scale_shift;
        fg.scaling_shift = grain.grain_scaling_minus_8 + 8;
        fg.chroma_scaling_from_luma = @intFromBool(grain.chroma_scaling_from_luma);
        fg.num_y_points = @min(grain.num_y_points, av1_most_y_points);
        fg.num_cb_points = @min(grain.num_cb_points, av1_most_chroma_points);
        fg.num_cr_points = @min(grain.num_cr_points, av1_most_chroma_points);
        for (0..fg.num_y_points) |i| fg.scaling_points_y[i] = .{ grain.point_y_value[i], grain.point_y_scaling[i] };
        for (0..fg.num_cb_points) |i| fg.scaling_points_cb[i] = .{ grain.point_cb_value[i], grain.point_cb_scaling[i] };
        for (0..fg.num_cr_points) |i| fg.scaling_points_cr[i] = .{ grain.point_cr_value[i], grain.point_cr_scaling[i] };
        fg.ar_coeff_lag = @min(grain.ar_coeff_lag, 3);
        fg.ar_coeff_shift = grain.ar_coeff_shift_minus_6 + 6;
        for (&fg.ar_coeffs_y, grain.ar_coeffs_y_plus_128) |*c, plus| c.* = @intCast(@as(i16, plus) - 128);
        for (&fg.ar_coeffs_cb, grain.ar_coeffs_cb_plus_128) |*c, plus| c.* = @intCast(@as(i16, plus) - 128);
        for (&fg.ar_coeffs_cr, grain.ar_coeffs_cr_plus_128) |*c, plus| c.* = @intCast(@as(i16, plus) - 128);
        fg.cb_mult = grain.cb_mult;
        fg.cb_luma_mult = grain.cb_luma_mult;
        fg.cb_offset = grain.cb_offset;
        fg.cr_mult = grain.cr_mult;
        fg.cr_luma_mult = grain.cr_luma_mult;
        fg.cr_offset = grain.cr_offset;
        fg.overlap_flag = @intFromBool(grain.overlap_flag);
        fg.clip_to_restricted_range = @intFromBool(grain.clip_to_restricted_range);
        fg.bit_depth_minus_8 = seq.bit_depth - 8;
        filmGrain(tables, blocks, fg);
    }
    for (part.global_motion[av1.LAST_FRAME..], av1.LAST_FRAME..) |*warp, ref| {
        warp.wmtype = h.gm_type[ref];
        for (warp.wmmat[0..6], h.gm_params[ref]) |*into, param| into.* = param;
    }
    const count = @min(tiles.len, part.tile_info.len);
    @memcpy(part.tile_info[0..count], tiles[0..count]);
}

/// A CDEF strength as the decoder takes it: the primary's times 4, and
/// the secondary as coded - 3 where it is 4.
fn cdefStrength(primary: u8, secondary: u8) u16 {
    const coded: u16 = if (secondary == 4) 3 else secondary;
    return @as(u16, primary) << 2 | coded;
}

/// Film grain's blocks while they are made: brightness's 73 rows of 82
/// samples, each colour's 38 of 44 (4:2:0).
pub const Av1GrainBlocks = struct {
    luma: [73][82]i16 = undefined,
    cb: [38][44]i16 = undefined,
    cr: [38][44]i16 = undefined,
};

/// Film grain's tables for the values `grain` (7.18.3.3), its blocks
/// made in `blocks`: white noise taken from the Gaussian sequence by a
/// shift register, the brightness's seeded with the frame's seed and each
/// colour's with it changed, then each filtered auto-regressively - the
/// colours with the brightness at their place mixed in - and kept to
/// the samples' range. What the decoder takes of them goes into its rows
/// of the tables: brightness's 64 rows from row and column 9, a gap of 64
/// after each four; each colour's 32 from row and column 6, a gap after
/// each eight. The scaling functions are tables of 256, straight between
/// their points.
pub fn filmGrain(tables: *Av1Tables, blocks: *Av1GrainBlocks, grain: *const Av1Grain) void {
    const bit_depth: u5 = @intCast(grain.bit_depth_minus_8 + 8);
    const center = @as(i32, 128) << (bit_depth - 8);
    const least = -center;
    const most = (@as(i32, 256) << (bit_depth - 8)) - 1 - center;
    const shift: u5 = @intCast(12 - @as(u32, bit_depth) + grain.grain_scale_shift);
    const lag: usize = grain.ar_coeff_lag;
    const ar_shift: u5 = @intCast(grain.ar_coeff_shift);

    var seed = grain.random_seed;
    for (&blocks.luma) |*row| {
        for (row) |*sample| sample.* = @intCast(round2(if (grain.num_y_points > 0) gaussian(&seed) else 0, shift));
    }
    for (3..blocks.luma.len) |y| {
        for (3..blocks.luma[0].len - 3) |x| {
            var sum: i32 = 0;
            var pos: usize = 0;
            near: for (y - lag..y + 1) |row| {
                for (x - lag..x + lag + 1) |column| {
                    if (row == y and column == x) break :near;
                    sum += @as(i32, blocks.luma[row][column]) * grain.ar_coeffs_y[pos];
                    pos += 1;
                }
            }
            blocks.luma[y][x] = @intCast(@max(least, @min(most, blocks.luma[y][x] + round2(sum, ar_shift))));
        }
    }

    const cb_noise = grain.num_cb_points > 0 or grain.chroma_scaling_from_luma != 0;
    const cr_noise = grain.num_cr_points > 0 or grain.chroma_scaling_from_luma != 0;
    seed = grain.random_seed ^ 0xb524;
    for (&blocks.cb) |*row| {
        for (row) |*sample| sample.* = @intCast(round2(if (cb_noise) gaussian(&seed) else 0, shift));
    }
    seed = grain.random_seed ^ 0x49d8;
    for (&blocks.cr) |*row| {
        for (row) |*sample| sample.* = @intCast(round2(if (cr_noise) gaussian(&seed) else 0, shift));
    }
    for (3..blocks.cb.len) |y| {
        for (3..blocks.cb[0].len - 3) |x| {
            var sum_cb: i32 = 0;
            var sum_cr: i32 = 0;
            var pos: usize = 0;
            near: for (y - lag..y + 1) |row| {
                for (x - lag..x + lag + 1) |column| {
                    const c_cb: i32 = grain.ar_coeffs_cb[pos];
                    const c_cr: i32 = grain.ar_coeffs_cr[pos];
                    if (row == y and column == x) {
                        // The brightness at this place: the four samples
                        // a colour sample covers, averaged.
                        if (grain.num_y_points > 0) {
                            const luma_x = ((x - 3) << 1) + 3;
                            const luma_y = ((y - 3) << 1) + 3;
                            var luma: i32 = 0;
                            for (0..2) |i| {
                                for (0..2) |j| luma += blocks.luma[luma_y + i][luma_x + j];
                            }
                            luma = round2(luma, 2);
                            sum_cb += luma * c_cb;
                            sum_cr += luma * c_cr;
                        }
                        break :near;
                    }
                    sum_cb += @as(i32, blocks.cb[row][column]) * c_cb;
                    sum_cr += @as(i32, blocks.cr[row][column]) * c_cr;
                    pos += 1;
                }
            }
            blocks.cb[y][x] = @intCast(@max(least, @min(most, blocks.cb[y][x] + round2(sum_cb, ar_shift))));
            blocks.cr[y][x] = @intCast(@max(least, @min(most, blocks.cr[y][x] + round2(sum_cr, ar_shift))));
        }
    }

    const luma_out: *[64 * 96]i16 = @ptrCast(&tables.luma_grain_block);
    for (0..64) |i| {
        const row = luma_out[i * 80 + i / 4 * 64 ..][0..80];
        for (row, 0..) |*sample, j| sample.* = if (9 + j < blocks.luma[0].len) blocks.luma[9 + i][9 + j] else 0;
    }
    const cb_out: *[32 * 48]i16 = @ptrCast(&tables.cb_grain_block);
    const cr_out: *[32 * 48]i16 = @ptrCast(&tables.cr_grain_block);
    for (0..32) |i| {
        const first = i * 40 + i / 8 * 64;
        for (0..40) |j| {
            const within = 6 + j < blocks.cb[0].len;
            cb_out[first + j] = if (within) blocks.cb[6 + i][6 + j] else 0;
            cr_out[first + j] = if (within) blocks.cr[6 + i][6 + j] else 0;
        }
    }

    tables.scaling_lut_y = @splat(0);
    grainScaling(&tables.scaling_lut_y, grain.scaling_points_y[0..grain.num_y_points]);
    if (grain.chroma_scaling_from_luma != 0) {
        tables.scaling_lut_cb = tables.scaling_lut_y;
        tables.scaling_lut_cr = tables.scaling_lut_y;
    } else {
        tables.scaling_lut_cb = @splat(0);
        tables.scaling_lut_cr = @splat(0);
        grainScaling(&tables.scaling_lut_cb, grain.scaling_points_cb[0..grain.num_cb_points]);
        grainScaling(&tables.scaling_lut_cr, grain.scaling_points_cr[0..grain.num_cr_points]);
    }
}

/// The next of film grain's white noise: the shift register `seed` moved
/// on, its top 11 bits picking a value of the Gaussian sequence.
fn gaussian(seed: *u16) i32 {
    const value = seed.*;
    const bit = (value ^ (value >> 1) ^ (value >> 3) ^ (value >> 12)) & 1;
    seed.* = (value >> 1) | (bit << 15);
    return vp.av1.gaussian_sequence[seed.* >> 5];
}

/// `value` divided by 2 to the `bits`, rounded (Round2).
fn round2(value: i32, bits: u5) i32 {
    return (value + ((@as(i32, 1) << bits) >> 1)) >> bits;
}

/// A scaling function of `points` (value, scaling) as a table: the first
/// point's scaling before it, straight lines between the points in steps
/// of 1/65536, the last point's after it. A function without points stays
/// as it is.
fn grainScaling(table: *[256]i16, points: []const [2]u8) void {
    if (points.len == 0) return;
    for (table[0..points[0][0]]) |*entry| entry.* = points[0][1];
    for (points[0 .. points.len - 1], points[1..]) |from, to| {
        const delta_y = @as(i32, to[1]) - from[1];
        const delta_x = @as(i32, to[0]) - from[0];
        if (delta_x <= 0) continue;
        const delta: i64 = @as(i64, delta_y) * @divTrunc(65536 + (delta_x >> 1), delta_x);
        for (0..@intCast(delta_x)) |x| {
            const step: i32 = @intCast((@as(i64, @intCast(x)) * delta + 32768) >> 16);
            table[from[0] + x] = @intCast(@as(i32, from[1]) + step);
        }
    }
    const last = points[points.len - 1];
    for (table[last[0]..]) |*entry| entry.* = last[1];
}

/// A loop filter level kept to 0 to MAX_LOOP_FILTER.
fn filterLevel(level: i32) i32 {
    const most: i32 = vp.vp9.MAX_LOOP_FILTER;
    return if (level < 0) 0 else if (level > most) most else level;
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

/// A picture's message `message` and its tables - an AvcMessage and its
/// AvcScaling, an HevcMessage and its HevcScaling, or a Vp9Message and
/// its Vp9Tables - written into the ring's piece and handed to the
/// decoder with the stream's other buffers (`buffers`, whose message and
/// tables are filled in here). Its fence is the state's last; `fenced`
/// waits for it. The caller holds the resource's lock.
pub fn decodePicture(state: *State, message: anytype, tables: anytype, buffers: Buffers) void {
    const vp9 = @TypeOf(tables.*) == Vp9Tables;
    const tables_at = if (vp9) probs_at else scaling_at;
    copyToDevice(state.ring.cpu + message_at + tables_at, @as([*]const u8, @ptrCast(tables))[0..@sizeOf(@TypeOf(tables.*))]);
    var named = buffers;
    if (vp9) {
        named.flags = probs_decode_buffers;
        named.probs = state.ring.device + message_at + tables_at;
    } else {
        named.flags = decode_buffers;
        named.scaling = state.ring.device + message_at + tables_at;
    }
    handPicture(state, message, named);
}

/// An AV1 frame's message, as `decodePicture`, and its tables written
/// into the stream's piece `tables_piece`.
pub fn decodeAv1Picture(state: *State, message: *const Av1Message, tables: *const Av1Tables, tables_piece: amdgpu.GPUMemory, buffers: Buffers) void {
    copyToDevice(tables_piece.cpu, @as([*]const u8, @ptrCast(tables))[0..@sizeOf(Av1Tables)]);
    var named = buffers;
    named.flags = probs_decode_buffers;
    named.probs = tables_piece.device;
    handPicture(state, message, named);
}

/// The message written into the ring's piece and handed to the decoder
/// with `buffers`, which name it there.
fn handPicture(state: *State, message: anytype, buffers: Buffers) void {
    copyToDevice(state.ring.cpu + message_at, @as([*]const u8, @ptrCast(message))[0..@sizeOf(@TypeOf(message.*))]);
    var named = buffers;
    named.message = state.ring.device + message_at;
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

test "a VP9 frame's message is laid out as the decoder reads it" {
    try testing.expectEqual(@as(usize, 428), @offsetOf(Vp9Message, "vp9"));
    try testing.expectEqual(@as(usize, 4), @offsetOf(Vp9Part, "frame_context_idx"));
    try testing.expectEqual(@as(usize, 10), @offsetOf(Vp9Part, "lf_adj_level"));
    try testing.expectEqual(@as(usize, 74), @offsetOf(Vp9Part, "base_qindex"));
    try testing.expectEqual(@as(usize, 78), @offsetOf(Vp9Part, "log2_tile_cols"));
    try testing.expectEqual(@as(usize, 82), @offsetOf(Vp9Part, "chroma_format"));
    try testing.expectEqual(@as(usize, 83), @offsetOf(Vp9Part, "ref_frame_map"));
    try testing.expectEqual(@as(usize, 91), @offsetOf(Vp9Part, "frame_refs"));
    try testing.expectEqual(@as(usize, 94), @offsetOf(Vp9Part, "ref_frame_sign_bias"));
    try testing.expectEqual(@as(usize, 98), @offsetOf(Vp9Part, "bit_depth_luma_minus8"));
    try testing.expectEqual(@as(usize, 102), @offsetOf(Vp9Part, "luma_10to8"));
    try testing.expectEqual(@as(usize, 104), @offsetOf(Vp9Part, "vp9_frame_size"));
    try testing.expectEqual(@as(usize, 112), @offsetOf(Vp9Part, "uncompressed_header_size"));
    try testing.expectEqual(@as(usize, 2304), @offsetOf(Vp9Tables, "feature_data"));
    try testing.expectEqual(@as(usize, 2336), @offsetOf(Vp9Tables, "tree_probs"));
    try testing.expectEqual(@as(usize, 2346), @offsetOf(Vp9Tables, "abs_delta"));
    try testing.expectEqual(@as(usize, 2347), @offsetOf(Vp9Tables, "feature_mask"));
    try testing.expectEqual(@as(u32, 0x11), streamKind(types.VDCODEC_VP9));
}

test "the VP9 default probabilities laid out are Mesa's bytes" {
    // FNV-1a of the 2072 bytes Mesa's table fill writes
    // (ac_vcn_vp9_fill_probs_table), taken from its sources.
    var hash: u64 = 0xcbf29ce484222325;
    for (vp9_defaults) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    try testing.expectEqual(@as(u64, 0x62de58118a055ac9), hash);
    try testing.expectEqualSlices(u8, &.{ 195, 29, 183, 84 }, vp9_defaults[32..36]);
}

test "a VP9 stream's surfaces and context, in 8 bits and in 10" {
    const l = Layout.vp9(1920, 1080, false);
    try testing.expectEqual(@as(u32, 9), l.ids);
    try testing.expectEqual(@as(u32, 1920), l.ref_pitch);
    try testing.expectEqual(@as(u32, 1088), l.ref_rows);
    try testing.expectEqual(@as(u32, 1), l.sample_bytes);
    try testing.expectEqual(@as(u32, 2048), l.target_pitch);
    try testing.expectEqual(@as(u32, 10_857_728), l.hw_bytes);
    const deep = Layout.vp9(3840, 2160, true);
    try testing.expectEqual(@as(u32, 2176), deep.ref_rows);
    try testing.expectEqual(@as(u32, 3840 * 2176 * 2), deep.refLuma());
    try testing.expectEqual(@as(u32, 10_857_728 + 65_536), deep.hw_bytes);
    const small = Layout.vp9(136, 104, false);
    try testing.expectEqual(@as(u32, 192), small.ref_pitch);
    try testing.expectEqual(@as(u32, 128), small.ref_rows);
    try testing.expectEqual(@as(u32, 256), small.target_pitch);
}

test "a VP9 frame's message: its flags, filter levels, references and segments" {
    const v9 = vp.vp9;
    var h: v9.Vp9Header = .{
        .frame_type = v9.NON_KEY_FRAME,
        .frame_is_intra = false,
        .allow_high_precision_mv = true,
        .refresh_frame_context = true,
        .frame_parallel_decoding_mode = false,
        .use_prev_frame_mvs = true,
        .frame_context_idx = 2,
        .reset_frame_context = 0,
        .interp_filter = v9.FILTER_EIGHTTAP_SHARP,
        .base_q_idx = 60,
        .delta_q_y_dc = -2,
        .tile_cols_log2 = 1,
        .bit_depth = 10,
        .ref_frame_idx = .{ 0, 3, 5 },
        .ref_frame_sign_bias = .{ false, false, false, true },
        .uncompressed_bytes = 20,
        .compressed_bytes = 50,
    };
    h.loop_filter = .{ .level = 36, .sharpness = 2, .delta_enabled = true, .mode_deltas = .{ 0, -1 } };
    const sg = &h.segmentation;
    sg.enabled = true;
    sg.update_map = true;
    sg.tree_probs = .{ 10, 20, 30, 40, 50, 60, 70 };
    sg.pred_probs = .{ 1, 2, 3 };
    sg.feature_enabled[2] = .{ true, true, false, false };
    sg.feature_data[2] = .{ -17, -10, 0, 0 };
    sg.feature_enabled[5][v9.SEG_LVL_REF_FRAME] = true;
    sg.feature_data[5][v9.SEG_LVL_REF_FRAME] = 1;
    sg.feature_enabled[6][v9.SEG_LVL_SKIP] = true;
    const map = [8]u8{ 4, 1, no_ref, 6, 2, 0, 3, 8 };

    var message: Vp9Message = .{};
    var tables: Vp9Tables = .{};
    vp9Part(&message.vp9, &tables, &h, 7, &map);
    const part = &message.vp9;
    // Not a key frame, high-precision vectors, the context refreshed,
    // segmentation and its map, the filter's deltas, the vectors before,
    // the uncompressed header given.
    try testing.expectEqual(@as(u32, 0x69B2), part.frame_header_flags);
    try testing.expectEqual(@as(u8, 2), part.frame_context_idx);
    try testing.expectEqual(@as(u8, 7), part.curr_pic_idx);
    try testing.expectEqual(@as(u8, v9.FILTER_EIGHTTAP_SHARP), part.interp_filter);
    try testing.expectEqual(@as(u8, 36), part.filter_level);
    try testing.expectEqual(@as(i8, -2), part.y_dc_delta_q);
    try testing.expectEqual(@as(u8, 1), part.log2_tile_cols);
    try testing.expectEqual(@as(u8, 2), part.bit_depth_luma_minus8);
    try testing.expectEqual(DITHER_ROUND, part.luma_10to8);
    try testing.expectEqual(@as(u32, 20), part.uncompressed_header_size);
    try testing.expectEqual(@as(u32, 50), part.compressed_header_size);
    // Level 36: each delta counts twice. Segment 2's level is 10 lower.
    try testing.expectEqual([4][2]u8{ .{ 38, 0 }, .{ 36, 34 }, .{ 34, 32 }, .{ 34, 32 } }, part.lf_adj_level[0]);
    try testing.expectEqual([4][2]u8{ .{ 28, 0 }, .{ 26, 24 }, .{ 24, 22 }, .{ 24, 22 } }, part.lf_adj_level[2]);
    try testing.expectEqualSlices(u8, &map, &part.ref_frame_map);
    try testing.expectEqualSlices(u8, &.{ 4, 6, 0 }, &part.frame_refs);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 1 }, &part.ref_frame_sign_bias);
    try testing.expectEqual(@as(u32, 0x00F6_FFEF), tables.feature_data[2]);
    try testing.expectEqual(@as(u8, 3), tables.feature_mask[2]);
    try testing.expectEqual(@as(u32, 0x0100_0000), tables.feature_data[5]);
    try testing.expectEqual(@as(u8, 4), tables.feature_mask[5]);
    try testing.expectEqual(@as(u8, 8), tables.feature_mask[6]);
    try testing.expectEqualSlices(u8, &sg.tree_probs, &tables.tree_probs);
    try testing.expectEqualSlices(u8, &sg.pred_probs, &tables.pred_probs);

    // A key frame that resets what came before: the first context,
    // no deltas, no segments.
    var key: v9.Vp9Header = .{ .frame_context_idx = 3, .reset_past = true, .reset_frame_context = 3 };
    key.loop_filter.level = 10;
    vp9Part(&message.vp9, &tables, &key, 0, &map);
    try testing.expectEqual(@as(u32, 1 << 14 | 1 << 6), part.frame_header_flags);
    try testing.expectEqual(@as(u8, 0), part.frame_context_idx);
    try testing.expectEqual(@as(u8, 3), part.reset_frame_context);
    for (part.lf_adj_level) |levels| try testing.expectEqual([4][2]u8{ .{ 10, 0 }, .{ 10, 10 }, .{ 10, 10 }, .{ 10, 10 } }, levels);
    try testing.expectEqual(@as(u8, 0), part.luma_10to8);
    try testing.expectEqual(Vp9Tables{}, tables);

    // The rest: VP9's stream, the probability table among the buffers,
    // the eight slots' surfaces.
    var surfaces: [8]u64 = undefined;
    for (&surfaces, 0..) |*address, j| address.* = 0x1_0000_0000 + j * 0x10_0000;
    vp9Message(&message, Layout.vp9(1920, 1080, false), 3, 9, 4096, 0x2_0000_0000, &surfaces);
    try testing.expectEqual(@as(u32, @sizeOf(Vp9Message)), message.header.total_size);
    try testing.expectEqual(MessageIndex{ .id = PART_VP9, .offset = 428, .size = 120 }, message.codec_index);
    try testing.expectEqual(@as(u32, 0x11), message.decode.stream_type);
    try testing.expectEqual(@as(u32, 0x180D), message.decode.decode_buffer_flags);
    try testing.expectEqual(@as(u32, 10_857_728), message.decode.hw_ctxt_size);
    try testing.expectEqual(@as(u32, 8), message.dpb.array_size);
    try testing.expectEqual(@as(u32, 0x0030_0000), message.dpb.addr_lo[3]);
    try testing.expectEqual(@as(u32, 1), message.dpb.addr_hi[7]);
    try testing.expectEqual(@as(u32, 2), message.dpb.curr_hi);

    var ib: [ib_words]u32 = undefined;
    _ = indirectBuffer(&ib, .{ .flags = probs_decode_buffers, .message = 0x1000, .session = 0x2000, .probs = 0x3_0000_0400 });
    try testing.expectEqual(probs_decode_buffers, ib[6]);
    try testing.expectEqual(@as(u32, 3), ib[6 + 17]);
    try testing.expectEqual(@as(u32, 0x400), ib[6 + 18]);
}

test "an AV1 frame's message is laid out as the decoder reads it" {
    try testing.expectEqual(@as(usize, 428), @offsetOf(Av1Message, "av1"));
    // Places in the part, as Mesa's structure has them.
    const places = .{
        .{ "current_frame_id", 4 },          .{ "profile", 12 },                     .{ "curr_pic_idx", 16 },
        .{ "ref_deltas", 24 },               .{ "base_qindex", 34 },                 .{ "qm_y", 40 },
        .{ "tile_cols", 45 },                .{ "chroma_format", 49 },               .{ "tile_size_bytes", 52 },
        .{ "tile_col_start_sb", 60 },        .{ "tile_row_start_sb", 320 },          .{ "max_width", 580 },
        .{ "superres_upscaled_width", 596 }, .{ "superres_scale_denominator", 600 }, .{ "order_hint_bits", 601 },
        .{ "ref_frame_map", 602 },           .{ "ref_frame_offset", 612 },           .{ "frame_refs", 644 },
        .{ "ref_frame_sign_bias", 651 },     .{ "bit_depth_luma_minus8", 658 },      .{ "feature_data", 660 },
        .{ "feature_mask", 916 },            .{ "cdef_damping", 924 },               .{ "cdef_strengths", 926 },
        .{ "cdef_uv_strengths", 958 },       .{ "frame_restoration_type", 990 },     .{ "log2_restoration_unit_size_minus5", 993 },
        .{ "p010_mode", 996 },               .{ "seg_lossless_flag", 1002 },         .{ "coded_lossless", 1003 },
        .{ "film_grain", 1004 },             .{ "uncompressed_header_size", 1172 },  .{ "global_motion", 1176 },
        .{ "tile_info", 1528 },              .{ "reserved", 3576 },                  .{ "av1_intrabc_workaround", 3580 },
    };
    inline for (places) |place| try testing.expectEqual(@as(usize, place[1]), @offsetOf(Av1Part, place[0]));
    try testing.expectEqual(@as(usize, 29), @offsetOf(Av1Grain, "num_y_points"));
    try testing.expectEqual(@as(usize, 74), @offsetOf(Av1Grain, "ar_coeffs_y"));
    try testing.expectEqual(@as(usize, 148), @offsetOf(Av1Grain, "ar_coeff_shift"));
    try testing.expectEqual(@as(usize, 152), @offsetOf(Av1Grain, "cb_offset"));
    try testing.expectEqual(@as(usize, 156), @offsetOf(Av1Grain, "cr_offset"));
    try testing.expectEqual(@as(usize, 164), @offsetOf(Av1Grain, "random_seed"));
    try testing.expectEqual(@as(usize, 36), @offsetOf(Av1Warp, "alpha"));
    try testing.expectEqual(@as(usize, 128), @offsetOf(Av1Tables, "feature_mask"));
    try testing.expectEqual(@as(usize, 256), @offsetOf(Av1Tables, "luma_grain_block"));
    try testing.expectEqual(@as(usize, 18688), @offsetOf(Av1Tables, "scaling_lut_y"));
    try testing.expectEqual(@as(usize, 13136), @offsetOf(Av1FrameContext, "kf_y_cdf"));
    try testing.expectEqual(@as(usize, 19348), @offsetOf(Av1FrameContext, "cfl_alpha_cdf"));
    try testing.expectEqual(@as(u32, 0x13), streamKind(types.VDCODEC_AV1));
}

test "the AV1 default CDFs laid out are Mesa's bytes" {
    // FNV-1a of the four frame contexts as Mesa fills them
    // (ac_vcn_av1_init_probs, video block 4's layout), taken from its
    // sources - but for the 1280 places no stream reads, which it fills
    // with values of its own and which stay 0 here.
    var hash: u64 = 0xcbf29ce484222325;
    for (av1_defaults) |byte| hash = (hash ^ byte) *% 0x100000001b3;
    try testing.expectEqual(@as(u64, 0x4c1ce26006be83c8), hash);
    const words: *const [av1_defaults.len / 2]u16 = @ptrCast(@alignCast(&av1_defaults));
    const context = av1_frame_context_bytes / 2;
    // Mesa's words: the coefficients' by the quantizer's class, the rest
    // the same in each.
    try testing.expectEqual(@as(u16, 919), words[0]);
    try testing.expectEqual(@as(u16, 5881), words[3 * context]);
    try testing.expectEqualSlices(u16, &.{ 17180, 15741, 13430, 12550, 12086, 11658, 10943, 9524, 8579, 4603, 3675, 2302, 0, 0 }, words[13136 / 2 ..][0..14]);
    try testing.expectEqualSlices(u16, &.{ 25131, 12049, 1367, 287, 111, 80, 76, 72, 68, 64, 60, 56, 52, 48, 44, 0, 0 }, words[3 * context + 19348 / 2 ..][0..17]);
    try testing.expectEqualSlices(u16, &.{ 17171, 11839, 8197, 6062, 5104, 3947, 3167, 2197, 866, 0, 0 }, words[(12392 + 4 * 22) / 2 ..][0..11]);
    try testing.expectEqualSlices(u16, &.{ 4096, 1792, 910, 448, 217, 112, 28, 11, 6, 1, 0, 0 }, words[(12952 + 24) / 2 ..][0..12]);
    try testing.expectEqualSlices(u16, &.{ 23191, 20302, 15029, 12018, 10707, 9553, 8167, 7285, 6925, 712, 0, 0 }, words[2 * context + (12832 + 48) / 2 ..][0..12]);
}

test "an AV1 stream's surfaces and context" {
    try testing.expectEqual(@as(u32, 36_389_888), av1_context_bytes);
    const layout = Layout.av1(3840, 2160, true);
    try testing.expectEqual(@as(u32, 9), layout.ids);
    try testing.expectEqual(@as(u32, 3840), layout.ref_pitch);
    try testing.expectEqual(@as(u32, 2176), layout.ref_rows);
    try testing.expectEqual(@as(u32, 2), layout.sample_bytes);
    try testing.expectEqual(@as(u32, 3840), layout.target_pitch);
    try testing.expectEqual(@as(u32, 2176), layout.target_rows);
    try testing.expectEqual(av1_context_bytes, layout.hw_bytes);
}

/// Film grain's values for a test: in 8 bits with the farthest lag and
/// a scaling function of each plane's own, or in 10 with the nearest and
/// the colours scaled as the brightness.
fn testGrain(deep: bool) Av1Grain {
    var g: Av1Grain = .{ .apply_grain = 1 };
    if (!deep) {
        g.random_seed = 0x1234;
        g.ar_coeff_lag = 3;
        g.ar_coeff_shift = 7;
        g.num_y_points = 3;
        g.scaling_points_y[0..3].* = .{ .{ 16, 20 }, .{ 80, 60 }, .{ 200, 30 } };
        g.num_cb_points = 2;
        g.scaling_points_cb[0..2].* = .{ .{ 0, 10 }, .{ 255, 90 } };
        g.num_cr_points = 1;
        g.scaling_points_cr[0] = .{ 128, 50 };
        for (&g.ar_coeffs_y, 0..) |*c, i| c.* = @intCast(@as(i32, @intCast(i * 7 % 23)) - 11);
        for (&g.ar_coeffs_cb, &g.ar_coeffs_cr, 0..) |*cb, *cr, i| {
            cb.* = @intCast(@as(i32, @intCast(i * 5 % 19)) - 9);
            cr.* = @intCast(12 - @as(i32, @intCast(i * 3 % 25)));
        }
    } else {
        g.random_seed = 0xBEEF;
        g.bit_depth_minus_8 = 2;
        g.grain_scale_shift = 1;
        g.ar_coeff_lag = 1;
        g.ar_coeff_shift = 6;
        g.chroma_scaling_from_luma = 1;
        g.num_y_points = 2;
        g.scaling_points_y[0..2].* = .{ .{ 0, 64 }, .{ 255, 0 } };
        for (g.ar_coeffs_y[0..4], 0..) |*c, i| c.* = @intCast(30 - 20 * @as(i32, @intCast(i)));
        for (g.ar_coeffs_cb[0..5], g.ar_coeffs_cr[0..5], 0..) |*cb, *cr, i| {
            cb.* = @intCast(-40 + 17 * @as(i32, @intCast(i)));
            cr.* = @intCast(25 - 9 * @as(i32, @intCast(i)));
        }
    }
    return g;
}

test "film grain's tables are Mesa's bytes" {
    // FNV-1a of the buffer Mesa's ac_vcn_av1_init_film_grain_buffer
    // writes for the same values (video block 4's rows), the columns it
    // leaves unset as 0.
    var tables: Av1Tables = .{};
    var blocks: Av1GrainBlocks = .{};
    for ([_]bool{ false, true }, [_]u64{ 0xbbdec6edc956846e, 0x15f031294a8a1b88 }) |deep, expect| {
        tables = .{};
        const g = testGrain(deep);
        filmGrain(&tables, &blocks, &g);
        var hash: u64 = 0xcbf29ce484222325;
        const bytes: *const [@sizeOf(Av1Tables)]u8 = @ptrCast(&tables);
        for (bytes[@offsetOf(Av1Tables, "luma_grain_block")..]) |byte| hash = (hash ^ byte) *% 0x100000001b3;
        try testing.expectEqual(expect, hash);
    }
    // The 10-bit one's first samples, and its scaling falling from 64.
    try testing.expectEqualSlices(i16, &.{ 138, -38, -22, 59 }, tables.luma_grain_block[0][0..4]);
    try testing.expectEqual(@as(i16, -165), tables.cb_grain_block[1][0]);
    try testing.expectEqual(@as(i16, 54), tables.scaling_lut_y[40]);
    try testing.expectEqual(@as(i16, 39), tables.scaling_lut_cb[100]);
}

test "an AV1 frame's message: its flags, tiles, references, segments and film grain" {
    const av1 = vp.av1;
    var seq: av1.Av1Sequence = .{ .enable_filter_intra = true, .enable_order_hint = true, .enable_jnt_comp = true, .order_hint_bits = 7, .bit_depth = 10 };
    var h: av1.Av1FrameHeader = .{
        .frame_type = av1.INTER_FRAME,
        .showable_frame = true,
        .disable_frame_end_update_cdf = false,
        .primary_ref_frame = 2,
        .order_hint = 9,
        .ref_frame_idx = .{ 6, 5, 4, 3, 2, 1, 0 },
        .interpolation_filter = av1.SWITCHABLE,
        .use_superres = true,
        .superres_denom = 12,
        .upscaled_width = 1920,
        .frame_width = 1280,
        .frame_height = 1080,
        .mi_cols = 320,
        .mi_rows = 270,
        .tile_cols = 2,
        .tile_rows = 1,
        .context_update_tile_id = 1,
        .base_q_idx = 100,
        .delta_q_u_ac = -3,
        .using_qmatrix = true,
        .qm_y = 5,
        .qm_u = 6,
        .qm_v = 7,
        .delta_q_present = true,
        .delta_q_res = 2,
        .delta_lf_res = 1,
        .segmentation_enabled = true,
        .seg_id_pre_skip = true,
        .last_active_seg_id = 5,
        .loop_filter_level = .{ 10, 12, 3, 4 },
        .loop_filter_sharpness = 2,
        .cdef_damping = 5,
        .cdef_bits = 2,
        .frame_restoration_type = .{ av1.RESTORE_WIENER, av1.RESTORE_NONE, av1.RESTORE_SGRPROJ },
        .loop_restoration_size = .{ 128, 64, 64 },
        .uses_lr = true,
        .tx_mode = av1.TX_MODE_SELECT,
        .reference_select = true,
    };
    h.mi_col_starts[0..3].* = .{ 0, 160, 320 };
    h.mi_row_starts[0..2].* = .{ 0, 270 };
    h.feature_enabled[3][av1.SEG_LVL_ALT_Q] = true;
    h.feature_data[3][av1.SEG_LVL_ALT_Q] = -100;
    h.feature_enabled[5][av1.SEG_LVL_REF_FRAME] = true;
    h.feature_data[5][av1.SEG_LVL_REF_FRAME] = 4;
    h.lossless[2] = true;
    h.cdef_y_pri_strength[1] = 7;
    h.cdef_y_sec_strength[1] = 4;
    h.cdef_uv_pri_strength[2] = 3;
    h.cdef_uv_sec_strength[2] = 2;
    h.ref_frame_sign_bias[av1.BWDREF_FRAME] = true;
    h.ref_frame_sign_bias[av1.ALTREF2_FRAME] = true;
    h.ref_frame_sign_bias[av1.ALTREF_FRAME] = true;
    h.gm_type[av1.LAST_FRAME] = av1.ROTZOOM;
    h.gm_params[av1.LAST_FRAME] = .{ 1, 2, 65540, -3, 3, 65532 };
    h.film_grain = .{
        .apply_grain = true,
        .grain_seed = 0x1234,
        .num_y_points = 3,
        .grain_scaling_minus_8 = 3,
        .ar_coeff_lag = 3,
        .ar_coeff_shift_minus_6 = 1,
        .cb_mult = 128,
        .cr_offset = 256,
        .overlap_flag = true,
    };
    h.film_grain.point_y_value[0..3].* = .{ 16, 80, 200 };
    h.film_grain.point_y_scaling[0..3].* = .{ 20, 60, 30 };
    h.film_grain.ar_coeffs_y_plus_128 = @splat(128);
    h.film_grain.ar_coeffs_y_plus_128[0] = 100;
    h.film_grain.ar_coeffs_cb_plus_128 = @splat(128);
    h.film_grain.ar_coeffs_cr_plus_128 = @splat(140);

    var part: Av1Part = undefined;
    var tables: Av1Tables = .{};
    var blocks: Av1GrainBlocks = .{};
    const layout = Layout.av1(1920, 1088, true);
    const map = [8]u8{ 4, 1, no_ref, 3, 0, 2, 6, 7 };
    const tiles = [_]Av1Tile{ .{ .offset = 0, .size = 1000 }, .{ .offset = 1000, .size = 500 } };
    av1Part(&part, &tables, &blocks, &seq, &h, layout, 8, &map, &tiles);

    // Refreshes its context, its flags from the header and the sequence;
    // not shown.
    const flags = (1 << AV1_REFRESH_FRAME_CONTEXT) | (1 << AV1_USING_QMATRIX) | (1 << AV1_ENABLE_FILTER_INTRA) |
        (1 << AV1_ENABLE_ORDER_HINT) | (1 << AV1_ENABLE_JNT_COMP) | (1 << AV1_DELTA_Q_PRESENT) |
        (1 << AV1_SEGMENTATION_ENABLED) | (1 << AV1_DISABLE_REF_FRAME_MVS);
    try testing.expectEqual(@as(u32, flags), part.frame_header_flags);
    try testing.expectEqual(@as(u32, 9), part.frame_offset);
    try testing.expectEqual(@as(u8, 8), part.curr_pic_idx);
    try testing.expectEqual(@as(u8, 2), part.primary_ref_frame);
    try testing.expectEqual(av1.SWITCHABLE, part.interp_filter);
    try testing.expectEqual([2]u8{ 10, 12 }, part.filter_level);
    try testing.expectEqual(@as(u8, 4), part.filter_level_v);
    try testing.expectEqual([8]i8{ 1, 0, 0, 0, -1, 0, -1, -1 }, part.ref_deltas);
    try testing.expectEqual(@as(i8, -3), part.u_ac_delta_q);
    try testing.expectEqualSlices(u8, &.{ 0xF5, 0xF6, 0xF7 }, &.{ part.qm_y, part.qm_u, part.qm_v });
    try testing.expectEqual(@as(u8, 4), part.delta_q_res);
    try testing.expectEqual(@as(u8, 2), part.delta_lf_res);
    try testing.expectEqual(@as(u8, 2), part.reference_mode);
    try testing.expectEqual(@as(u8, 1), part.chroma_format);
    try testing.expectEqual(@as(u32, 0xFF), part.tile_size_bytes);
    try testing.expectEqual(@as(u32, 1), part.context_update_tile_id);
    // Superblocks of 64: 16 units of 4 samples each.
    try testing.expectEqualSlices(u32, &.{ 0, 10, 20, 0 }, part.tile_col_start_sb[0..4]);
    try testing.expectEqualSlices(u32, &.{ 0, 17, 0 }, part.tile_row_start_sb[0..3]);
    // The stream's size, the frame's coded and upscaled.
    try testing.expectEqualSlices(u32, &.{ 1920, 1088, 1280, 1080, 1920 }, &.{ part.max_width, part.max_height, part.width, part.height, part.superres_upscaled_width });
    try testing.expectEqual(@as(u8, 12), part.superres_scale_denominator);
    try testing.expectEqual(@as(u8, 7), part.order_hint_bits);
    try testing.expectEqual(map, part.ref_frame_map);
    try testing.expectEqual([7]u8{ 6, 2, 0, 3, no_ref, 1, 4 }, part.frame_refs);
    try testing.expectEqual([7]u8{ 0, 0, 0, 0, 1, 1, 1 }, part.ref_frame_sign_bias);
    try testing.expectEqual(@as(u8, 2), part.bit_depth_luma_minus8);
    try testing.expectEqual(DITHER_ROUND, part.luma_10to8);
    // Segments: the quantizer's change of segment 3, segment 5's
    // reference; segment 2 lossless.
    try testing.expectEqual(@as(i32, -100), part.feature_data[3][0]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1, 0, 0x20, 0, 0 }, &part.feature_mask);
    try testing.expectEqual(@as(i16, 4), tables.feature_data[5][5]);
    try testing.expectEqual(part.feature_mask, tables.feature_mask);
    try testing.expectEqual(@as(u8, 0x04), part.seg_lossless_flag);
    try testing.expectEqual(@as(u8, 1), part.preskip_segid);
    try testing.expectEqual(@as(u8, 5), part.last_active_segid);
    try testing.expectEqual(@as(u8, 5), part.cdef_damping);
    try testing.expectEqual(@as(u16, 7 << 2 | 3), part.cdef_strengths[1]);
    try testing.expectEqual(@as(u16, 3 << 2 | 2), part.cdef_uv_strengths[2]);
    try testing.expectEqual([3]u8{ av1.RESTORE_WIENER, av1.RESTORE_NONE, av1.RESTORE_SGRPROJ }, part.frame_restoration_type);
    try testing.expectEqual([3]u8{ 2, 1, 1 }, part.log2_restoration_unit_size_minus5);
    // Global motion from the first reference on.
    try testing.expectEqual(@as(u32, 0), part.global_motion[0].wmtype);
    try testing.expectEqual(@as(u32, av1.ROTZOOM), part.global_motion[1].wmtype);
    try testing.expectEqualSlices(i32, &.{ 1, 2, 65540, -3, 3, 65532, 0, 0 }, &part.global_motion[1].wmmat);
    try testing.expectEqualSlices(i32, &.{ 0, 0, 65536, 0, 0, 65536 }, part.global_motion[7].wmmat[0..6]);
    try testing.expectEqual(tiles[1], part.tile_info[1]);
    try testing.expectEqual(Av1Tile{}, part.tile_info[2]);
    // Film grain's values as the decoder takes them, and its tables made.
    const fg = part.film_grain;
    try testing.expectEqual(@as(u8, 1), fg.apply_grain);
    try testing.expectEqual(@as(u8, 11), fg.scaling_shift);
    try testing.expectEqual(@as(u8, 7), fg.ar_coeff_shift);
    try testing.expectEqual(@as(u8, 2), fg.bit_depth_minus_8);
    try testing.expectEqual([2]u8{ 80, 60 }, fg.scaling_points_y[1]);
    try testing.expectEqual(@as(i8, -28), fg.ar_coeffs_y[0]);
    try testing.expectEqual(@as(i8, 12), fg.ar_coeffs_cr[24]);
    try testing.expectEqual(@as(u16, 256), fg.cr_offset);
    try testing.expectEqual(@as(u16, 0x1234), fg.random_seed);
    try testing.expectEqual(@as(i16, 20), tables.scaling_lut_y[0]);

    // A key frame shown refers to nothing; without film grain the tables'
    // grain stays as it was.
    h.frame_type = av1.KEY_FRAME;
    h.show_frame = true;
    h.film_grain.apply_grain = false;
    h.uses_lr = false;
    seq.bit_depth = 8;
    av1Part(&part, &tables, &blocks, &seq, &h, layout, 0, &map, tiles[0..1]);
    try testing.expectEqual([8]u8{ no_ref, no_ref, no_ref, no_ref, no_ref, no_ref, no_ref, no_ref }, part.ref_frame_map);
    try testing.expectEqual([7]u8{ no_ref, no_ref, no_ref, no_ref, no_ref, no_ref, no_ref }, part.frame_refs);
    try testing.expectEqual(@as(u32, 1), part.frame_header_flags & 1);
    try testing.expectEqual(Av1Grain{}, part.film_grain);
    try testing.expectEqual([3]u8{ 3, 3, 3 }, part.log2_restoration_unit_size_minus5);
    try testing.expectEqual(@as(u8, 0), part.luma_10to8);
    try testing.expectEqual(@as(i16, 20), tables.scaling_lut_y[0]);

    // The rest: AV1's stream, the tables among the buffers, the eight
    // slots' surfaces.
    var message: Av1Message = .{};
    var surfaces: [8]u64 = undefined;
    for (&surfaces, 0..) |*address, j| address.* = 0x1_0000_0000 + j * 0x10_0000;
    av1Message(&message, Layout.av1(1920, 1080, false), 3, 9, 4096, 0x2_0000_0000, &surfaces);
    try testing.expectEqual(@as(u32, @sizeOf(Av1Message)), message.header.total_size);
    try testing.expectEqual(MessageIndex{ .id = PART_AV1, .offset = 428, .size = 3584 }, message.codec_index);
    try testing.expectEqual(@as(u32, 0x13), message.decode.stream_type);
    try testing.expectEqual(@as(u32, 0x180D), message.decode.decode_buffer_flags);
    try testing.expectEqual(@as(u32, 36_389_888), message.decode.hw_ctxt_size);
    try testing.expectEqual(@as(u32, 1088), message.decode.db_aligned_height);
    try testing.expectEqual(@as(u32, 8), message.dpb.array_size);
}
