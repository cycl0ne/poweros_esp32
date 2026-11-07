// SPDX-License-Identifier: MPL-2.0
//! The security processor: a processor of the device's own that loads
//! every firmware the device's other processors run, and checks it
//! before they run it. Its own system is started by the machine's
//! firmware; a driver talks to it through a command ring it makes, whose
//! control is in the processor's second segment.
//!
//! **The ring** is a page of the device's memory: 64 frames of 64 bytes,
//! each naming a command - a page of its own, the command at its start
//! and the processor's response at 0x360 in it - a fence, and the number
//! the processor writes there once it is done with the command. The ring
//! is made by writing its address and size into three registers and
//! asking for it in the control register, which reads "ready" (its top bit,
//! and no error in its low half) before and after; its write pointer is a
//! register of its own, counted in words, and is moved one frame on for
//! each command.
//!
//! **Its commands** here are the three that put a block's firmware into
//! the processor's protected region: the table of contents loaded, which
//! the processor answers with the size of the region it needs; the region
//! set up, at its address to the device and in the machine; a firmware
//! loaded into it, which it answers with where it put it. Every status it
//! answers is said, since a status that is not 0 is not always a refusal.
//!
//! A firmware file starts with a header of the vendor's: its length, the
//! header's, and where in the file and how long the part is that the
//! processor is given (`payloadOf`).
//!
//! What is said at start is whether its system runs - a register that
//! holds the system's version once it does - and what the ring's control
//! register holds.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const systimer = sdk.hardware.systimer;
const AMDGPUBase = @import("../amdgpu_base.zig").AMDGPUBase;

const owner = amdgpu.AMDGPUNAME;

/// Its registers, counted in 32-bit words from its second address: the
/// ring's control, its write pointer, its address and its size, and the
/// version of its system.
const segment = 1;
const ring_control = 0x80;
const ring_write = 0x83;
const ring_address_low = 0x85;
const ring_address_high = 0x86;
const ring_size = 0x87;
const system_version = 0x91;

/// The control register: ready, with the error in the low half; the ring
/// asked for - the kind a driver's commands go on - and every ring taken
/// down.
const CONTROL_READY: u32 = 0x8000_0000;
const CONTROL_STATE: u32 = 0x8000_FFFF;
const CONTROL_MAKE_RING: u32 = 2 << 16;
const CONTROL_DESTROY_RINGS: u32 = 3 << 16;

/// The processor whose ring and commands are these.
const known = .{ .major = 13, .minor = 0, .revision = 4 };

/// The processor kept in the base where it is the known one.
pub fn take(ab: *AMDGPUBase, processor: amdgpu.GPUBlock) void {
    if (processor.major != known.major or processor.minor != known.minor or processor.revision != known.revision) return;
    if (processor.count <= segment) return;
    ab.security = processor;
    ab.security_known = true;
}

// --- the piece the ring is in ------------------------------------------------

/// The ring, the command page and the fence, a page each, in one piece.
const ring_bytes: u32 = 4096;
const ring_words: u32 = ring_bytes / 4;
const frame_words: u32 = 16;
const command_at: u32 = 4096;
const fence_at: u32 = 8192;
pub const piece_bytes: u32 = 3 * 4096;

/// What a file is staged on, and the protected region: a mebibyte.
pub const staging_alignment: u32 = 1024 * 1024;

// --- the commands --------------------------------------------------------------

pub const COMMAND_SETUP_REGION: u32 = 0x05;
pub const COMMAND_LOAD_FIRMWARE: u32 = 0x06;
pub const COMMAND_LOAD_CONTENTS: u32 = 0x20;

/// Where in the command page: the command, its arguments, and the
/// response - its status, the address a firmware went to, the size of
/// the region the table of contents asks for.
const at_command = 0x008;
pub const at_arguments = 0x01c;
const at_status = 0x360;
const at_address_low = 0x368;
const at_address_high = 0x36c;
const at_region_bytes = 0x370;

/// The region's setup flag: its address in the machine is given.
pub const REGION_MACHINE_ADDRESS: u32 = 1 << 1;

/// What the processor answered.
pub const Response = struct { status: u32, address: u64, region_bytes: u32 };

/// One argument: its byte offset in the command page, and its value.
pub const Argument = struct { at: u32, value: u32 };

fn registers(ab: *const AMDGPUBase) usize {
    return @as(usize, @intCast(ab.info.registers)) + @as(usize, ab.security.addresses[segment]) * 4;
}

fn word(ab: *const AMDGPUBase, offset: u32) *volatile u32 {
    return reg(registers(ab) + offset * 4);
}

fn at(cpu: u64, offset: u32) *volatile u32 {
    return reg(@as(usize, @intCast(cpu)) + offset);
}

fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

/// A wait of so many microseconds, at the least.
fn pause(ab: *AMDGPUBase, us: u32) void {
    var never: exec.Waitable = .{};
    const list = [_]*exec.Waitable{&never};
    _ = ab.sys_base.WaitForAny(&list, 1, us);
}

/// Whether the control register reads ready within `most_us`.
fn ready(ab: *AMDGPUBase, most_us: u64) bool {
    const until = systimer.uptimeUs() + most_us;
    while (word(ab, ring_control).* & CONTROL_STATE != CONTROL_READY) {
        if (systimer.uptimeUs() > until) return false;
        pause(ab, 1000);
    }
    return true;
}

/// `bytes` at `cpu` set to zero, eight at a time.
pub fn clear(cpu: u64, bytes: u32) void {
    var offset: u32 = 0;
    while (offset < bytes) : (offset += 8) {
        const to: *volatile u64 = @ptrFromInt(@as(usize, @intCast(cpu)) + offset);
        to.* = 0;
    }
}

/// `from` into the device's memory at `cpu`: eight bytes at a time, and
/// what is left one at a time.
pub fn copyIn(cpu: u64, from: []const u8) void {
    const base: usize = @intCast(cpu);
    var offset: usize = 0;
    while (offset + 8 <= from.len) : (offset += 8) {
        const to: *volatile u64 = @ptrFromInt(base + offset);
        to.* = @as(*align(1) const u64, @ptrCast(from.ptr + offset)).*;
    }
    while (offset < from.len) : (offset += 1) {
        const to: *volatile u8 = @ptrFromInt(base + offset);
        to.* = from[offset];
    }
}

/// The ring made in `ab.security_ring`, its fence and command page
/// cleared: true once the processor reads ready again. A ring it will not
/// take is asked for once more after every ring is taken down - a ring of
/// an earlier system's still there.
pub fn makeRing(ab: *AMDGPUBase) bool {
    const sys = ab.sys_base;
    const ring = ab.security_ring;
    clear(ring.cpu, piece_bytes);
    fence();
    if (!ready(ab, 100_000)) {
        exec.kprintf(sys, "%s: the security processor is not ready for a ring (%x)\n", .{ owner, word(ab, ring_control).* });
        return false;
    }
    var tries: u32 = 0;
    while (tries < 2) : (tries += 1) {
        word(ab, ring_address_low).* = @truncate(ring.device);
        word(ab, ring_address_high).* = @truncate(ring.device >> 32);
        word(ab, ring_size).* = ring_bytes;
        word(ab, ring_control).* = CONTROL_MAKE_RING;
        pause(ab, 20_000);
        if (ready(ab, 1_000_000)) {
            exec.kprintf(sys, "%s: the security processor's ring is at 0x%lx, its write pointer %x\n", .{
                owner, ring.device, word(ab, ring_write).*,
            });
            return true;
        }
        exec.kprintf(sys, "%s: the security processor does not take the ring (%x): every ring taken down\n", .{ owner, word(ab, ring_control).* });
        word(ab, ring_control).* = CONTROL_DESTROY_RINGS;
        pause(ab, 20_000);
        if (!ready(ab, 1_000_000)) {
            exec.kprintf(sys, "%s: the security processor does not take its rings down (%x)\n", .{ owner, word(ab, ring_control).* });
            return false;
        }
    }
    return false;
}

/// How long a command is waited for.
const command_most_us: u64 = 5_000_000;

/// `command` with `arguments` put on the ring and waited for: what the
/// processor answered - said, whatever it is - or null where it did not
/// write the command's fence in time.
pub fn submit(ab: *AMDGPUBase, command: u32, arguments: []const Argument) ?Response {
    const sys = ab.sys_base;
    const ring = ab.security_ring;
    const page = ring.cpu + command_at;
    clear(page, 4096);
    at(page, at_command).* = command;
    for (arguments) |argument| at(page, argument.at).* = argument.value;
    ab.security_sequence +%= 1;
    const number = ab.security_sequence;

    const write = word(ab, ring_write).*;
    const frame = ring.cpu + (write % ring_words) / frame_words * 64;
    clear(frame, 64);
    const page_device = ring.device + command_at;
    const fence_device = ring.device + fence_at;
    at(frame, 0x00).* = @truncate(page_device);
    at(frame, 0x04).* = @truncate(page_device >> 32);
    at(frame, 0x0c).* = @truncate(fence_device);
    at(frame, 0x10).* = @truncate(fence_device >> 32);
    at(frame, 0x14).* = number;
    fence();
    word(ab, ring_write).* = (write + frame_words) % ring_words;

    const until = systimer.uptimeUs() + command_most_us;
    while (at(ring.cpu, fence_at).* != number) {
        if (systimer.uptimeUs() > until) {
            exec.kprintf(sys, "%s: the security processor does not answer command %x: control %x, write pointer %x, fence %x of %x\n", .{
                owner, command, word(ab, ring_control).*, word(ab, ring_write).*, at(ring.cpu, fence_at).*, number,
            });
            return null;
        }
        pause(ab, 1000);
    }
    const response: Response = .{
        .status = at(page, at_status).*,
        .address = @as(u64, at(page, at_address_high).*) << 32 | at(page, at_address_low).*,
        .region_bytes = at(page, at_region_bytes).*,
    };
    exec.kprintf(sys, "%s: the security processor answers command %x: status %x, address 0x%lx, region %x\n", .{
        owner, command, response.status, response.address, response.region_bytes,
    });
    return response;
}

/// `part` of a file copied into a piece of its own and handed to the
/// processor with `command`: its address and size the first three
/// arguments, `more` after them. The piece is given back once the
/// processor answers; one it did not answer for in time is kept, since
/// it may still read it, and the processor is taken as gone.
pub fn staged(ab: *AMDGPUBase, part: []const u8, command: u32, more: []const Argument) ?Response {
    const sys = ab.sys_base;
    const gpu: *amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
    var staging: amdgpu.GPUMemory = .{};
    const bytes: u32 = @intCast((part.len + 4095) / 4096 * 4096);
    if (!gpu.AllocGPUMemory(bytes, staging_alignment, &staging)) {
        exec.kprintf(sys, "%s: no room in the device's memory for %ld bytes of firmware\n", .{ owner, @as(u64, part.len) });
        return null;
    }
    copyIn(staging.cpu, part);
    var arguments: [8]Argument = undefined;
    arguments[0] = .{ .at = at_arguments, .value = @truncate(staging.device) };
    arguments[1] = .{ .at = at_arguments + 4, .value = @truncate(staging.device >> 32) };
    arguments[2] = .{ .at = at_arguments + 8, .value = @intCast(part.len) };
    for (more, 0..) |argument, n| arguments[3 + n] = argument;
    const response = submit(ab, command, arguments[0 .. 3 + more.len]) orelse {
        ab.security_dead = true;
        return null;
    };
    gpu.FreeGPUMemory(&staging);
    return response;
}

// --- the files -------------------------------------------------------------------

/// The part of a firmware file the processor is given: where it starts in
/// the file, and how long it is.
pub const Payload = struct { at: u32, bytes: u32 };

fn little(file: []const u8, offset: usize) u32 {
    return @as(u32, file[offset]) | @as(u32, file[offset + 1]) << 8 | @as(u32, file[offset + 2]) << 16 | @as(u32, file[offset + 3]) << 24;
}

/// The vendor's header of `file` read: its own length (which is the
/// file's), the header's, and the part given to the processor - after the
/// header, inside the file. Null for a file whose header says otherwise.
pub fn payloadOf(file: []const u8) ?Payload {
    if (file.len < 0x20) return null;
    const length = little(file, 0x00);
    const header = little(file, 0x04);
    const bytes = little(file, 0x14);
    const offset = little(file, 0x18);
    if (length != file.len or header < 0x20 or header > file.len) return null;
    if (offset < header or offset > file.len or bytes == 0 or bytes > file.len - offset) return null;
    return .{ .at = offset, .bytes = bytes };
}

/// The processor's state, said.
pub fn tell(ab: *AMDGPUBase, processor: amdgpu.GPUBlock) void {
    const sys = ab.sys_base;
    if (processor.count <= segment) return;
    const base = @as(usize, @intCast(ab.info.registers)) + @as(usize, processor.addresses[segment]) * 4;
    const version = reg(base + system_version * 4).*;
    const control = reg(base + ring_control * 4).*;
    exec.kprintf(sys, "%s: the security processor's system %s (%x), its ring control reads %x\n", .{
        owner,
        @as([*:0]const u8, if (version != 0) "runs" else "does not run"),
        version,
        control,
    });
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "a firmware file's header says which part of it the processor is given" {
    var file = [_]u8{0} ** 0x140;
    const put = struct {
        fn word(bytes: []u8, offset: usize, value: u32) void {
            bytes[offset] = @truncate(value);
            bytes[offset + 1] = @truncate(value >> 8);
            bytes[offset + 2] = @truncate(value >> 16);
            bytes[offset + 3] = @truncate(value >> 24);
        }
    };
    put.word(&file, 0x00, file.len);
    put.word(&file, 0x04, 0x20);
    put.word(&file, 0x14, 0x40);
    put.word(&file, 0x18, 0x100);
    const payload = payloadOf(&file).?;
    try testing.expectEqual(@as(u32, 0x100), payload.at);
    try testing.expectEqual(@as(u32, 0x40), payload.bytes);

    // A part past the end, a length that is not the file's, a part that
    // starts inside the header, and a file too short for a header.
    put.word(&file, 0x14, 0x41);
    try testing.expect(payloadOf(&file) == null);
    put.word(&file, 0x14, 0x40);
    put.word(&file, 0x00, file.len + 1);
    try testing.expect(payloadOf(&file) == null);
    put.word(&file, 0x00, file.len);
    put.word(&file, 0x18, 0x10);
    try testing.expect(payloadOf(&file) == null);
    try testing.expect(payloadOf(file[0..0x10]) == null);
}
