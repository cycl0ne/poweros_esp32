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
fn clear(cpu: u64, bytes: u32) void {
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

/// An indirect buffer handing over the message at `message` with the
/// stream's context at `session`: its words written to `into`.
pub fn messageBuffer(into: []u32, message: u64, session: u64) u32 {
    for (into[0..ib_words]) |*value| value.* = 0;
    into[0] = ENGINE_INFO_SIZE;
    into[1] = ENGINE_INFO;
    into[2] = ENGINE_DECODE;
    into[3] = ib_words * 4;
    into[4] = decode_buffer_words * 4 + 8;
    into[5] = PARAM_DECODE_BUFFER;
    const buffer = into[6..][0..decode_buffer_words];
    buffer[0] = BUFFER_MESSAGE | BUFFER_SESSION;
    buffer[1] = @truncate(message >> 32);
    buffer[2] = @truncate(message);
    buffer[7] = @truncate(session >> 32);
    buffer[8] = @truncate(session);
    return ib_words;
}

/// How long a message is waited for.
const message_most_us: u64 = 1_000_000;

/// The message of `words` in `message` handed to the decoder with the
/// stream's context at `session`, and its fence waited for: true once it
/// is written. The caller holds the resource's lock.
pub fn send(sys: *ExecBase, state: *State, message: []const u32, session: u64, what: [*:0]const u8) bool {
    clear(state.ring.cpu + message_at, 4096);
    for (message, 0..) |value, n| at(state.ring.cpu + message_at, @intCast(n * 4)).* = value;
    var ib: [ib_words]u32 = undefined;
    _ = messageBuffer(&ib, state.ring.device + message_at, session);
    for (ib, 0..) |value, n| at(state.ring.cpu + ib_at, @intCast(n * 4)).* = value;
    submit(state, ib_words);
    if (!waitFence(sys, state, message_most_us)) {
        report(sys, state, what);
        return false;
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
