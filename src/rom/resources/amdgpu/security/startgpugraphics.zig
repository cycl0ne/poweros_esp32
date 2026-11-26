// SPDX-License-Identifier: MPL-2.0
//! StartGPUGraphics: the graphics block's firmware loaded by the security
//! processor, the block started on it, and its memory hub turned on once
//! its engines have their code.
//!
//! **The parts.** Each file holds one engine's code, or several parts of
//! it, behind a header of the vendor's that says where each part is; the
//! processor is given each part as a firmware of its own kind (`partsOf`).
//! The command processor's three files are of the header's first version,
//! a part each - the compute engine's up to the jump table at its end,
//! which is left out. The scheduler's two files hold their pipe's code
//! and its data, the power controller's its code and its data, the DMA
//! engine's its two threads'. The RLC's holds the lists and memories its
//! header's version names - 2.1 its three lists, 2.2 its two memories,
//! 2.3 its two helpers' code - and its own code; each is a part where it
//! is not empty, the RLC's own code the last.
//!
//! **The order** is the one the block's RLC takes them from the
//! processor's region in (`load_order`): the DMA engine's, the command
//! processor's, the scheduler's, the power controller's, the RLC's. Each
//! file's header is read before any part is loaded, so a set with a file
//! the resource cannot read is loaded none of. Then the processor is told
//! every part is there, on which the RLC starts handing each engine its
//! code; and the power manager starts the block's power controller (the
//! IMU), which powers the block up for it. Once the engines say they have
//! their code, the block's memory hub is turned on (`_graphics.zig`).

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _security = @import("_security.zig");
const _power = @import("../power/_power.zig");
const _graphics = @import("../graphics/_graphics.zig");

/// The graphics block's firmware loaded by the security processor, the
/// RLC told to hand each engine its code, the block's power controller
/// started by the power manager, and its memory hub turned on once every
/// engine has its code.
///
/// SYNOPSIS:
/// ```zig
/// fn StartGPUGraphics(ab: *AMDGPUBase, files: *const amdgpu.GPUGraphicsFiles) bool
/// ```
///
/// SINCE: 1.9. LVO -48.
///
/// INPUTS:
/// - `files` - the block's firmware files, each the whole file as it is
///   on the disk (DEVS:firmware/amdgpu/gc_<version>_<part>.bin,
///   sdma_<version>.bin): the command processor's three, the RLC's, the
///   scheduler's two pipes', the power controller's - which may be left
///   out (`image` null), where the machine's firmware holds one - and the
///   DMA engine's.
///
/// RESULT:
/// True once every part is loaded, the RLC told to start, the power
/// controller started, every engine has its code and the hub is on, and
/// at once where an earlier call did all of it. False where a file is not
/// given, or its header is not one the resource reads - the command
/// processor's of another version than the first, the RLC's of another
/// than 2.0 to 2.3, a part outside its file - which is said on the
/// system's lines, and nothing is loaded; where the block is one whose
/// registers the resource does not know (it knows 11.0.1); where
/// StartGPUSecurity has not made the processor ready, the processor does
/// not answer within five seconds, or the device's memory has no room for
/// a part's copy or the hub's page table; where the power manager does
/// not keep the block powered, refuses to start the power controller or
/// does not answer within a second; where either is one whose commands
/// the resource does not know; where the engines do not have their code
/// within 100 ms or the hub does not take its new table - after which
/// every later call answers false at once; and on a machine without the
/// device.
///
/// BEHAVIOR:
/// Every file's parts are worked out first. Then, under the security
/// processor's lock, the power manager is told to keep the block powered
/// (SetGPUPower with GPUPOWER_GRAPHICS), as a block switched off answers
/// no register, and each part is copied into a piece of its own, which
/// the processor is given with the part's kind and which is given back
/// once it answers - the DMA engine's two threads, the command
/// processor's prefetch parser, micro engine and compute engine, the
/// scheduler's code and data for each pipe, the power controller's code
/// and data, the RLC's lists, memories and helpers where they are not
/// empty, and the RLC's own code - after which the processor is told
/// that every part is there, and - under the mailbox's lock - the power
/// manager to start the power controller, which powers the block up and
/// lets the RLC load the engines. Every status the processor answers
/// is put on the system's lines with the part's kind; one that is not 0
/// stops nothing, as the processor answers some parts so that it takes.
/// Then the call waits until the block's command processor is idle
/// (CP_STAT 0) and its RLC says its loading is complete (the top bit of
/// RLC_RLCS_BOOTLOAD_STATUS), and turns its memory hub on: its system
/// aperture over the device's own memory, uncached, its TLB and L2 cache
/// on, and its first context with an empty page table over 512 MiB of
/// the device's addresses (0x7FFF00000000 on), in the device's memory.
///
/// CONTEXT:
/// - Waits: yes, for the processor - a few milliseconds a part, of some
///   twenty, at most five seconds for one - for the power manager, at
///   most a second, and for the engines, at most 100 ms.
/// - Interrupts: no.
/// - Locks: takes the security processor's lock, and the memory lock and
///   the mailbox's lock inside it.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The files stay the caller's; each part is copied. What the processor
/// put into its region stays there, and the block runs from it. The
/// hub's page table, 1 MiB, and its scratch page are taken from the
/// device's memory and kept.
///
/// NOTES:
/// The block is left powered. Its engines are left halted with their
/// code: each is started with its queue (StartGPUDMA, StartGPUCompute).
///
/// BUGS:
/// A command processor of the later kind, whose files' header is of the
/// second version and names its engines' stacks as parts of their own,
/// is refused.
///
/// SEE ALSO:
/// `StartGPUSecurity`, `LoadGPUFirmware`, `SetGPUPower`, `StartGPUDMA`,
/// `StartGPUCompute`
///
/// EXAMPLES:
/// ```zig
/// var files: amdgpu.GPUGraphicsFiles = .{};
/// files.pfp = .{ .image = pfp.ptr, .bytes = @intCast(pfp.len) };
/// // ... me, mec, rlc, mes, mes_kiq, imu, dma the same way ...
/// if (!ab.StartGPUGraphics(&files)) return error.NoGraphics;
/// ```
pub fn StartGPUGraphics(ab: *AMDGPUBase, files: *const amdgpu.GPUGraphicsFiles) bool {
    if (ab.device == null or !ab.security_known or !ab.power_known or !ab.graphics_known) return false;
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);

    var parts: [load_order.len][most_parts]Part = undefined;
    var counts: [load_order.len]usize = @splat(0);
    for (load_order, 0..) |file, index| {
        const given = fileOf(files, file);
        const image = given.image orelse {
            if (file == .imu) continue;
            exec.kprintf(sys, "%s: the graphics block's %s firmware is not given\n", .{ owner, nameOf(file) });
            return false;
        };
        counts[index] = partsOf(file, image[0..given.bytes], &parts[index]) orelse {
            exec.kprintf(sys, "%s: the graphics block's %s firmware of %d bytes has a header the resource does not read\n", .{ owner, nameOf(file), given.bytes });
            return false;
        };
    }

    sys.ObtainSemaphore(&ab.security_lock);
    defer sys.ReleaseSemaphore(&ab.security_lock);
    if (ab.graphics_started) return true;
    if (ab.graphics_failed or ab.security_dead or !ab.security_ready) return false;
    if (!gpu.SetGPUPower(amdgpu.GPUPOWER_GRAPHICS, 0, true)) {
        exec.kprintf(sys, "%s: the power manager does not keep the graphics block powered\n", .{owner});
        return false;
    }
    for (load_order, 0..) |file, index| {
        const image = fileOf(files, file).image orelse continue;
        for (parts[index][0..counts[index]]) |part| {
            const response = _security.staged(ab, image[part.at..][0..part.bytes], _security.COMMAND_LOAD_FIRMWARE, &.{
                .{ .at = _security.at_arguments + 12, .value = part.kind },
            }) orelse return false;
            exec.kprintf(sys, "%s: the graphics block's %s firmware, part of kind %d, %d bytes: status %x\n", .{
                owner, nameOf(file), part.kind, part.bytes, response.status,
            });
        }
    }
    _ = _security.submit(ab, _security.COMMAND_START_RLC, &.{}) orelse {
        ab.security_dead = true;
        return false;
    };
    if (!startController(ab)) return false;
    if (!_graphics.waitForEngines(ab) or !_graphics.turnOnHub(ab)) {
        ab.graphics_failed = true;
        return false;
    }
    // The scheduler's two pipes' first instructions, which StartGPUCompute
    // points them at.
    for ([_]amdgpu.GPUFile{ files.mes, files.mes_kiq }, 0..) |file, pipe| {
        const image = file.image.?[0..file.bytes];
        ab.scheduler_start[pipe] = @as(u64, word(image, scheduler_start_at + 4)) << 32 | word(image, scheduler_start_at);
    }
    ab.graphics_started = true;
    return true;
}

/// The power manager told to start the graphics block's power controller,
/// under the mailbox's lock: true once it says done.
fn startController(ab: *AMDGPUBase) bool {
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    sys.ObtainSemaphore(&ab.mailbox_lock);
    defer sys.ReleaseSemaphore(&ab.mailbox_lock);
    const message = _power.MESSAGE_START_GRAPHICS_CONTROLLER;
    const answer = _power.send(ab, ab.power, message, _power.GRAPHICS_CONTROLLER_MAY_SWITCH_OFF) orelse {
        exec.kprintf(sys, "%s: the power manager does not answer message %x\n", .{ owner, message });
        return false;
    };
    if (answer.answer != _power.ANSWER_DONE) {
        exec.kprintf(sys, "%s: the power manager answers %x to message %x\n", .{ owner, answer.answer, message });
        return false;
    }
    return true;
}

/// The set's files, and the order their parts are loaded in.
pub const File = enum { dma, pfp, me, mec, mes, mes_kiq, imu, rlc };
const load_order = [_]File{ .dma, .pfp, .me, .mec, .mes, .mes_kiq, .imu, .rlc };

fn fileOf(files: *const amdgpu.GPUGraphicsFiles, file: File) amdgpu.GPUFile {
    return switch (file) {
        .dma => files.dma,
        .pfp => files.pfp,
        .me => files.me,
        .mec => files.mec,
        .mes => files.mes,
        .mes_kiq => files.mes_kiq,
        .imu => files.imu,
        .rlc => files.rlc,
    };
}

fn nameOf(file: File) [*:0]const u8 {
    return switch (file) {
        .dma => "DMA engine's",
        .pfp => "prefetch parser's",
        .me => "micro engine's",
        .mec => "compute engine's",
        .mes => "scheduler's",
        .mes_kiq => "scheduler's second pipe's",
        .imu => "power controller's",
        .rlc => "RLC's",
    };
}

/// One part of a file: the processor's kind for it, and where it is in
/// the file.
pub const Part = struct { kind: u32, at: u32, bytes: u32 };

/// The most parts one file holds: the RLC's.
pub const most_parts = 8;

/// The processor's kinds for the parts, as it numbers them.
const KIND_MICRO_ENGINE: u32 = 1;
const KIND_PREFETCH_PARSER: u32 = 2;
const KIND_COMPUTE_ENGINE: u32 = 4;
const KIND_RLC_HELPER_V: u32 = 7;
const KIND_RLC: u32 = 8;
const KIND_RLC_LIST_GPM: u32 = 20;
const KIND_RLC_LIST_SRM: u32 = 21;
const KIND_RLC_LIST_CONTROL: u32 = 22;
const KIND_RLC_HELPER_P: u32 = 25;
const KIND_RLC_IRAM: u32 = 26;
const KIND_SCHEDULER: u32 = 33;
const KIND_SCHEDULER_DATA: u32 = 34;
const KIND_RLC_DRAM: u32 = 48;
const KIND_CONTROLLER: u32 = 68;
const KIND_CONTROLLER_DATA: u32 = 69;
const KIND_DMA_THREAD_0: u32 = 71;
const KIND_DMA_THREAD_1: u32 = 72;
const KIND_SECOND_SCHEDULER: u32 = 81;
const KIND_SECOND_SCHEDULER_DATA: u32 = 82;

/// Where each header holds its parts' sizes and places, and the least
/// length of the header with them: the command processor's (version 1);
/// the scheduler's (1); the power controller's (1); the DMA engine's (2);
/// the RLC's, for each of its versions 2.0 to 2.3.
const engine_jump_words_at = 0x28;
const engine_header_least = 0x2c;
const scheduler_code_bytes_at = 0x24;
const scheduler_code_at = 0x28;
const scheduler_data_bytes_at = 0x30;
const scheduler_data_at = 0x34;
const scheduler_header_least = 0x48;
/// Where the scheduler's header holds the address of its first
/// instruction, low word first.
const scheduler_start_at = 0x38;
const controller_code_bytes_at = 0x20;
const controller_data_bytes_at = 0x28;
const controller_header_least = 0x30;
const dma_thread_0_bytes_at = 0x24;
const dma_thread_1_at = 0x30;
const dma_thread_1_bytes_at = 0x34;
const dma_header_least = 0x40;
const rlc_header_least = [_]u32{ 0x68, 0x9c, 0xac, 0xcc };

/// The RLC's parts its header names after the first version, as the
/// header's place of each one's size, the place of where it is, the kind,
/// and the version that names it - in the order they are loaded.
const RlcPart = struct { bytes_at: u32, at: u32, kind: u32, since: u16 };
const rlc_parts = [_]RlcPart{
    .{ .bytes_at = 0x74, .at = 0x78, .kind = KIND_RLC_LIST_CONTROL, .since = 1 },
    .{ .bytes_at = 0x84, .at = 0x88, .kind = KIND_RLC_LIST_GPM, .since = 1 },
    .{ .bytes_at = 0x94, .at = 0x98, .kind = KIND_RLC_LIST_SRM, .since = 1 },
    .{ .bytes_at = 0x9c, .at = 0xa0, .kind = KIND_RLC_IRAM, .since = 2 },
    .{ .bytes_at = 0xa4, .at = 0xa8, .kind = KIND_RLC_DRAM, .since = 2 },
    .{ .bytes_at = 0xb4, .at = 0xb8, .kind = KIND_RLC_HELPER_P, .since = 3 },
    .{ .bytes_at = 0xc4, .at = 0xc8, .kind = KIND_RLC_HELPER_V, .since = 3 },
};

fn word(file: []const u8, offset: usize) u32 {
    return @as(u32, file[offset]) | @as(u32, file[offset + 1]) << 8 | @as(u32, file[offset + 2]) << 16 | @as(u32, file[offset + 3]) << 24;
}

fn half(file: []const u8, offset: usize) u16 {
    return @as(u16, file[offset]) | @as(u16, file[offset + 1]) << 8;
}

/// The parts worked out so far, and whether one lay outside its file.
const Cut = struct {
    into: *[most_parts]Part,
    count: usize = 0,
    outside: bool = false,

    /// A part of `bytes` at `at`, where it is not empty.
    fn add(cut: *Cut, file_bytes: usize, kind: u32, at: u32, bytes: u32) void {
        if (bytes == 0) return;
        if (at > file_bytes or bytes > file_bytes - at) {
            cut.outside = true;
            return;
        }
        cut.into[cut.count] = .{ .kind = kind, .at = at, .bytes = bytes };
        cut.count += 1;
    }
};

/// The parts of `image`, the set's file `file`, into `into` in the order
/// they are loaded: how many, or null where its header is not one this
/// reads or names a part outside the file. An empty part is left out.
pub fn partsOf(file: File, image: []const u8, into: *[most_parts]Part) ?usize {
    const common = _security.payloadOf(image) orelse return null;
    const header_bytes = word(image, 0x04);
    const major = half(image, 0x08);
    const minor = half(image, 0x0a);
    var cut: Cut = .{ .into = into };
    switch (file) {
        .pfp, .me, .mec => {
            if (major != 1 or header_bytes < engine_header_least) return null;
            var bytes = common.bytes;
            const kind = switch (file) {
                .pfp => KIND_PREFETCH_PARSER,
                .me => KIND_MICRO_ENGINE,
                else => blk: {
                    const jump = @as(u64, word(image, engine_jump_words_at)) * 4;
                    if (jump >= bytes) return null;
                    bytes -= @intCast(jump);
                    break :blk KIND_COMPUTE_ENGINE;
                },
            };
            cut.add(image.len, kind, common.at, bytes);
        },
        .mes, .mes_kiq => {
            if (major != 1 or header_bytes < scheduler_header_least) return null;
            const second = file == .mes_kiq;
            cut.add(image.len, if (second) KIND_SECOND_SCHEDULER else KIND_SCHEDULER, word(image, scheduler_code_at), word(image, scheduler_code_bytes_at));
            cut.add(image.len, if (second) KIND_SECOND_SCHEDULER_DATA else KIND_SCHEDULER_DATA, word(image, scheduler_data_at), word(image, scheduler_data_bytes_at));
        },
        .imu => {
            if (major != 1 or header_bytes < controller_header_least) return null;
            const code_bytes = word(image, controller_code_bytes_at);
            cut.add(image.len, KIND_CONTROLLER, common.at, code_bytes);
            if (code_bytes > image.len - common.at) return null;
            cut.add(image.len, KIND_CONTROLLER_DATA, common.at + code_bytes, word(image, controller_data_bytes_at));
        },
        .dma => {
            if (major != 2 or header_bytes < dma_header_least) return null;
            cut.add(image.len, KIND_DMA_THREAD_0, common.at, word(image, dma_thread_0_bytes_at));
            cut.add(image.len, KIND_DMA_THREAD_1, word(image, dma_thread_1_at), word(image, dma_thread_1_bytes_at));
        },
        .rlc => {
            if (major != 2 or minor >= rlc_header_least.len or header_bytes < rlc_header_least[minor]) return null;
            for (rlc_parts) |part| {
                if (minor < part.since) continue;
                cut.add(image.len, part.kind, word(image, part.at), word(image, part.bytes_at));
            }
            cut.add(image.len, KIND_RLC, common.at, common.bytes);
        },
    }
    if (cut.outside or cut.count == 0) return null;
    return cut.count;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

/// A file of `bytes` whose header is `header_bytes` long, of version
/// `major`.`minor`, its common part `common_bytes` at 0x100.
fn fileOfVersion(buffer: []u8, header_bytes: u32, major: u16, minor: u16, common_bytes: u32) void {
    @memset(buffer, 0);
    put(buffer, 0x00, @intCast(buffer.len));
    put(buffer, 0x04, header_bytes);
    buffer[0x08] = @truncate(major);
    buffer[0x0a] = @truncate(minor);
    put(buffer, 0x14, common_bytes);
    put(buffer, 0x18, 0x100);
}

fn put(buffer: []u8, offset: usize, value: u32) void {
    buffer[offset] = @truncate(value);
    buffer[offset + 1] = @truncate(value >> 8);
    buffer[offset + 2] = @truncate(value >> 16);
    buffer[offset + 3] = @truncate(value >> 24);
}

test "the command processor's files: a part each, the compute engine's without its jump table" {
    var buffer = [_]u8{0} ** 0x1100;
    var parts: [most_parts]Part = undefined;
    fileOfVersion(&buffer, 0x2c, 1, 0, 0x1000);
    try testing.expectEqual(@as(?usize, 1), partsOf(.pfp, &buffer, &parts));
    try testing.expectEqual(Part{ .kind = KIND_PREFETCH_PARSER, .at = 0x100, .bytes = 0x1000 }, parts[0]);
    try testing.expectEqual(@as(?usize, 1), partsOf(.me, &buffer, &parts));
    try testing.expectEqual(KIND_MICRO_ENGINE, parts[0].kind);
    put(&buffer, engine_jump_words_at, 0x40);
    try testing.expectEqual(@as(?usize, 1), partsOf(.mec, &buffer, &parts));
    try testing.expectEqual(Part{ .kind = KIND_COMPUTE_ENGINE, .at = 0x100, .bytes = 0x1000 - 0x100 }, parts[0]);
    // The later kind, whose header is of the second version, and a jump
    // table as long as the code.
    fileOfVersion(&buffer, 0x2c, 2, 0, 0x1000);
    try testing.expect(partsOf(.pfp, &buffer, &parts) == null);
    fileOfVersion(&buffer, 0x2c, 1, 0, 0x1000);
    put(&buffer, engine_jump_words_at, 0x400);
    try testing.expect(partsOf(.mec, &buffer, &parts) == null);
}

test "the scheduler's, the power controller's and the DMA engine's two parts each" {
    var buffer = [_]u8{0} ** 0x1100;
    var parts: [most_parts]Part = undefined;
    fileOfVersion(&buffer, 0x48, 1, 0, 0x1000);
    put(&buffer, scheduler_code_bytes_at, 0x800);
    put(&buffer, scheduler_code_at, 0x100);
    put(&buffer, scheduler_data_bytes_at, 0x400);
    put(&buffer, scheduler_data_at, 0x900);
    try testing.expectEqual(@as(?usize, 2), partsOf(.mes, &buffer, &parts));
    try testing.expectEqual(Part{ .kind = KIND_SCHEDULER, .at = 0x100, .bytes = 0x800 }, parts[0]);
    try testing.expectEqual(Part{ .kind = KIND_SCHEDULER_DATA, .at = 0x900, .bytes = 0x400 }, parts[1]);
    try testing.expectEqual(@as(?usize, 2), partsOf(.mes_kiq, &buffer, &parts));
    try testing.expectEqual(KIND_SECOND_SCHEDULER, parts[0].kind);
    try testing.expectEqual(KIND_SECOND_SCHEDULER_DATA, parts[1].kind);
    // Data past the file's end.
    put(&buffer, scheduler_data_bytes_at, 0x900);
    try testing.expect(partsOf(.mes, &buffer, &parts) == null);

    fileOfVersion(&buffer, 0x30, 1, 0, 0x1000);
    put(&buffer, controller_code_bytes_at, 0x600);
    put(&buffer, controller_data_bytes_at, 0x600);
    try testing.expectEqual(@as(?usize, 2), partsOf(.imu, &buffer, &parts));
    try testing.expectEqual(Part{ .kind = KIND_CONTROLLER, .at = 0x100, .bytes = 0x600 }, parts[0]);
    try testing.expectEqual(Part{ .kind = KIND_CONTROLLER_DATA, .at = 0x700, .bytes = 0x600 }, parts[1]);

    fileOfVersion(&buffer, 0x40, 2, 0, 0x1000);
    put(&buffer, dma_thread_0_bytes_at, 0x700);
    put(&buffer, dma_thread_1_at, 0x800);
    put(&buffer, dma_thread_1_bytes_at, 0x900);
    try testing.expectEqual(@as(?usize, 2), partsOf(.dma, &buffer, &parts));
    try testing.expectEqual(Part{ .kind = KIND_DMA_THREAD_0, .at = 0x100, .bytes = 0x700 }, parts[0]);
    try testing.expectEqual(Part{ .kind = KIND_DMA_THREAD_1, .at = 0x800, .bytes = 0x900 }, parts[1]);
    // A header too short for its version.
    fileOfVersion(&buffer, 0x3c, 2, 0, 0x1000);
    try testing.expect(partsOf(.dma, &buffer, &parts) == null);
}

test "the RLC's parts by its header's version, the empty ones left out, its own code last" {
    var buffer = [_]u8{0} ** 0x2000;
    var parts: [most_parts]Part = undefined;
    fileOfVersion(&buffer, 0xcc, 2, 3, 0x100);
    // Its lists - the control list empty - its memories and one helper.
    put(&buffer, 0x84, 0x100);
    put(&buffer, 0x88, 0x200);
    put(&buffer, 0x94, 0x100);
    put(&buffer, 0x98, 0x300);
    put(&buffer, 0x9c, 0x100);
    put(&buffer, 0xa0, 0x400);
    put(&buffer, 0xa4, 0x100);
    put(&buffer, 0xa8, 0x500);
    put(&buffer, 0xb4, 0x100);
    put(&buffer, 0xb8, 0x600);
    try testing.expectEqual(@as(?usize, 6), partsOf(.rlc, &buffer, &parts));
    const kinds = [_]u32{ KIND_RLC_LIST_GPM, KIND_RLC_LIST_SRM, KIND_RLC_IRAM, KIND_RLC_DRAM, KIND_RLC_HELPER_P, KIND_RLC };
    for (kinds, parts[0..6]) |kind, part| try testing.expectEqual(kind, part.kind);
    try testing.expectEqual(Part{ .kind = KIND_RLC, .at = 0x100, .bytes = 0x100 }, parts[5]);
    // Version 2.1 names the lists alone; 2.4 is not one this reads.
    buffer[0x0a] = 1;
    try testing.expectEqual(@as(?usize, 3), partsOf(.rlc, &buffer, &parts));
    buffer[0x0a] = 4;
    try testing.expect(partsOf(.rlc, &buffer, &parts) == null);
    // A memory past the file's end.
    buffer[0x0a] = 3;
    put(&buffer, 0xa0, 0x1f80);
    try testing.expect(partsOf(.rlc, &buffer, &parts) == null);
}

test "the set is loaded in the order the RLC takes it" {
    try testing.expectEqualSlices(File, &.{ .dma, .pfp, .me, .mec, .mes, .mes_kiq, .imu, .rlc }, &load_order);
}
