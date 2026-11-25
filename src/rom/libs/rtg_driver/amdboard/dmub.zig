// SPDX-License-Identifier: MPL-2.0
//! The display controller: the processor inside the display engine that
//! runs the engine's command tables - the video BIOS's tables that set
//! up a link, its PHY and its pixel clock - and the commands a driver
//! sends it, from firmware of its own.
//!
//! **Starting it** is the device's security processor's work and the
//! driver's together. The firmware file (`dcn_<engine>_dmcub.bin`) is
//! handed to amdgpu.resource (LoadGPUFirmware, GPUFIRMWARE_DISPLAY),
//! whose security processor checks the code and points the controller's
//! first windows at it. The driver then stops the controller if it runs
//! - it is asked to stop, and waited for, before it is held in reset -
//! and gives it the memory it runs with: one piece of the device's
//! memory holding a copy of the video BIOS, the two command rings (the
//! inbox the driver writes, the outbox it reads notifications from), the
//! trace buffer and the firmware's state, each reached by the controller
//! through a window of its own address space. The boot options say what
//! the firmware may do; the controller is let out of reset; and its
//! firmware says it runs, and that its mailbox is ready, in its first
//! scratch register.
//!
//! **A command** is 64 bytes in the inbox ring: written at the write
//! place, the gathered writes fenced, and the write place moved on in
//! the register the controller watches. The controller moves the read
//! place past the command once it has done it, and a command that
//! answers leaves its answer in the command's own slot.
//!
//! The sizes of the trace buffer and of the state are what the
//! firmware's file says it wants, in the block of facts its maker put at
//! the end of its code for drivers to read; 64 KiB each where the block
//! is not there.
//!
//! Nothing here runs unless asked for: the board's controls
//! (RTGCTRL_AMD_CONTROLLER, RTGCTRL_AMD_START_CONTROLLER) ask, which
//! `C:test/Gpu DMCUB` does - starting it with the watchdog armed.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const rtg = sdk.rtg;
const err = rtg.errors;
const tags = rtg.tags;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const dcn = @import("dcn.zig");

/// The controller's registers, in 32-bit words from the engine's third
/// address (the one its pipes are counted from).
const control = 0x1f6;
const control_more = 0x200;
const secure_control = 0x1ce;
const hub_reset = 0x342;
const scratch_first = 0x1e3;
const gpint_in = 0x1f8;
const window_base = 0x1a5;
const window_top = 0x1ad;
const window_offset = 0x1b5;
const region5_offset = 0x198;
const region5_top = 0x1a2;
const inbox1_base = 0x1d4;
const inbox1_size = 0x1d5;
const inbox1_write = 0x1d6;
const inbox1_read = 0x1d7;
const outbox0_base = 0x1d8;
const outbox0_size = 0x1d9;
const outbox0_write = 0x1da;
const outbox0_read = 0x1db;
const outbox1_base = 0x1dc;
const outbox1_size = 0x1dd;
const outbox1_write = 0x1de;
const outbox1_read = 0x1df;
const timer = 0x1fd;
const fault_undefined = 0x1fa;
const fault_fetch = 0x1cc;
const fault_write = 0x1cd;
const pipes_disabled = 0x0ca;

/// Their bits.
const control_enable: u32 = 1 << 16;
const control_trace_port: u32 = 1 << 19;
const control_waiting: u32 = 1 << 20;
const more_soft_reset: u32 = 1 << 0;
const hub_reset_controller: u32 = 1 << 8;
const disabled_controller_present: u32 = 1 << 16;
const window_enable: u32 = 1 << 31;
const window_top_mask: u32 = 0x1fff_ffff;

/// The scratch registers the firmware and the driver speak through: the
/// boot status, the answer to a stop, the boot options, the security
/// processor's version.
const scratch_status = 0;
const scratch_stopped = 7;
const scratch_options = 14;
const scratch_security = 15;
const status_running: u32 = 1 << 0;
const status_mailbox_ready: u32 = 1 << 1;

/// The stop asked through the general-purpose interrupt: the command in
/// bits 27-16, the request in bits 31-28; acknowledged when the request
/// bits read 0 again, and answered in scratch 7.
const gpint_stop: u32 = 2 << 16;
const gpint_request: u32 = 1 << 28;
const stopped_answer: u32 = 0xdead_dead;

/// The boot options, as the firmware numbers them: the USB4 display
/// inputs enabled and present, their bandwidth allocation off.
const option_enable_usb4: u32 = 1 << 7;
const option_usb4_present: u32 = 1 << 9;
const option_no_usb4_allocation: u32 = 1 << 27;
const boot_options = option_enable_usb4 | option_usb4_present | option_no_usb4_allocation;

/// Where the controller sees each window, and the rings in the mailbox.
const window_bios = 3;
const window_mailbox = 4;
const window_trace = 5;
const window_state = 6;
const sees_bios: u32 = 0x6300_0000;
const sees_mailbox: u32 = 0x6400_0000;
const sees_trace: u32 = 0x6500_0000;
const sees_state: u32 = 0x6600_0000;
const sees_region5: u32 = 0xa000_0000;
const ring_bytes: u32 = 64 * 128;
const command_bytes: u32 = 64;
/// The trace buffer's entries start past its header.
const trace_entries_at: u32 = 16;

/// The sizes taken where the firmware's file says none.
const default_trace: u32 = 64 * 1024;
const default_state: u32 = 64 * 1024;

/// How long each wait lasts at the most.
const wait_us: u64 = 100_000;

/// The firmware's file: the common header's fields read here, its own
/// field counting the code, the signature's size before and after the
/// code, and the block of facts at the code's end.
const file_header_bytes_at = 0x04;
const file_array_at = 0x18;
const file_code_bytes_at = 0x20;
const file_header_least = 0x28;
const signature_bytes: u32 = 0x100;
const facts_bytes: u32 = 64;
const facts_mark: u32 = 0x444d_5542;
const facts_state_at = 4;
const facts_trace_at = 8;
const facts_version_at = 12;

/// What the firmware's file says of itself: its version, and the sizes
/// of its state and trace buffer - 0 for a size it does not say.
pub const Facts = struct { version: u32 = 0, state: u32 = 0, trace: u32 = 0 };

/// The facts block of the firmware file `file`, looked for where its
/// maker puts it: the 64 bytes that end at most 15 bytes before the
/// signature that follows the code, marked. A file whose headers do not
/// fit it says nothing.
pub fn factsOf(file: []const u8) Facts {
    if (file.len < file_header_least) return .{};
    const header = word(file, file_header_bytes_at);
    const array = word(file, file_array_at);
    const code = word(file, file_code_bytes_at);
    if (header < file_header_least or code < 2 * signature_bytes + facts_bytes) return .{};
    if (@as(u64, array) + code > file.len) return .{};
    const end = array + code - signature_bytes;
    var back: u32 = 0;
    while (back < 16) : (back += 1) {
        const place = end - back - facts_bytes;
        if (place < array + signature_bytes) break;
        if (word(file, place) != facts_mark) continue;
        return .{
            .version = word(file, place + facts_version_at),
            .state = word(file, place + facts_state_at),
            .trace = word(file, place + facts_trace_at),
        };
    }
    return .{};
}

fn word(bytes: []const u8, place: usize) u32 {
    return @as(u32, bytes[place]) | @as(u32, bytes[place + 1]) << 8 | @as(u32, bytes[place + 2]) << 16 | @as(u32, bytes[place + 3]) << 24;
}

/// The memory the controller runs with, once it has been started: the
/// piece of the device's memory, where in it each window starts and how
/// long it is, and where the driver's next command goes.
pub const Controller = struct {
    memory: ?amdgpu.GPUMemory = null,
    bios_at: u32 = 0,
    bios_bytes: u32 = 0,
    mailbox_at: u32 = 0,
    trace_at: u32 = 0,
    trace_bytes: u32 = 0,
    state_at: u32 = 0,
    state_bytes: u32 = 0,
    write: u32 = 0,
    version: u32 = 0,
};

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.block) + offset) * 4);
}

fn scratch(engine: dcn.Engine, n: u32) *volatile u32 {
    return at(engine, scratch_first + n);
}

/// The controller's registers into `into`, as RTGCTRL_AMD_CONTROLLER
/// answers them.
pub fn read(engine: dcn.Engine, into: *tags.RtgAmdController) void {
    into.present = @intFromBool(at(engine, pipes_disabled).* & disabled_controller_present != 0);
    into.control = at(engine, control).*;
    into.reset = at(engine, control_more).*;
    into.secure = at(engine, secure_control).*;
    into.status = scratch(engine, scratch_status).*;
    into.options = scratch(engine, scratch_options).*;
    into.timer[0] = at(engine, timer).*;
    pause(engine.sys, 1000);
    into.timer[1] = at(engine, timer).*;
    into.inbox = .{ at(engine, inbox1_base).*, at(engine, inbox1_size).*, at(engine, inbox1_read).*, at(engine, inbox1_write).* };
    into.outbox = .{ at(engine, outbox1_base).*, at(engine, outbox1_size).*, at(engine, outbox1_read).*, at(engine, outbox1_write).* };
    for (&into.windows, 0..) |*window, n| {
        const index: u32 = @intCast(n);
        window.* = .{
            at(engine, window_base + index).*,
            at(engine, window_top + index).*,
            at(engine, window_offset + 2 * index).*,
            at(engine, window_offset + 2 * index + 1).*,
        };
    }
    into.faults = .{ at(engine, fault_undefined).*, at(engine, fault_fetch).*, at(engine, fault_write).* };
}

/// Wait until `done` says so, for `wait_us` at the most: whether it did.
fn waitFor(engine: dcn.Engine, comptime done: fn (dcn.Engine) bool) bool {
    const until = engine.sys.UptimeUs() + wait_us;
    while (!done(engine)) {
        if (engine.sys.UptimeUs() > until) return false;
        pause(engine.sys, 10);
    }
    return true;
}

/// `us` microseconds let pass, the task waiting.
fn pause(sys: *ExecBase, us: u64) void {
    var never: exec.Waitable = .{};
    const list = [_]*exec.Waitable{&never};
    _ = sys.WaitForAny(&list, 1, us);
}

fn stopTaken(engine: dcn.Engine) bool {
    return at(engine, gpint_in).* == gpint_stop;
}

fn stopAnswered(engine: dcn.Engine) bool {
    return scratch(engine, scratch_stopped).* == stopped_answer;
}

fn waiting(engine: dcn.Engine) bool {
    return at(engine, control).* & control_waiting != 0;
}

fn upAndReady(engine: dcn.Engine) bool {
    const status = scratch(engine, scratch_status).*;
    return status & status_running != 0 and status & status_mailbox_ready != 0;
}

/// The controller stopped and held in reset, its rings emptied: asked to
/// stop where it runs - enabled and not in reset - acknowledged,
/// answered and waiting, or given up on after each wait, since one that
/// does not answer is held in reset all the same.
fn reset(engine: dcn.Engine) void {
    const enabled = at(engine, control).* & control_enable != 0;
    if (enabled and at(engine, control_more).* & more_soft_reset == 0) {
        at(engine, gpint_in).* = gpint_request | gpint_stop;
        _ = waitFor(engine, stopTaken);
        _ = waitFor(engine, stopAnswered);
        _ = waitFor(engine, waiting);
    }
    if (enabled) {
        at(engine, control_more).* |= more_soft_reset;
        at(engine, hub_reset).* |= hub_reset_controller;
        at(engine, control).* &= ~control_enable;
    }
    for ([_]u32{ inbox1_read, inbox1_write, outbox1_read, outbox1_write, outbox0_read, outbox0_write }) |offset| {
        at(engine, offset).* = 0;
    }
    scratch(engine, scratch_status).* = 0;
    at(engine, gpint_in).* = 0;
}

/// Window `n` set onto `bytes` of the device's memory at `device`, seen
/// by the controller from `sees` on.
fn setWindow(engine: dcn.Engine, n: u32, device: u64, sees: u32, bytes: u32) void {
    at(engine, window_offset + 2 * n).* = @truncate(device);
    at(engine, window_offset + 2 * n + 1).* = @truncate(device >> 32);
    at(engine, window_base + n).* = sees;
    at(engine, window_top + n).* = (sees + bytes) & window_top_mask | window_enable;
}

/// A size rounded up to `alignment`, a power of two.
fn rounded(bytes: u32, alignment: u32) u32 {
    return (bytes + alignment - 1) & ~(alignment - 1);
}

/// The places of the windows in one piece of memory, each from a
/// 256-byte boundary and as long as its contents rounded to 64 bytes;
/// the piece's size, in whole pages.
pub fn layOut(controller: *Controller, bios_bytes: u32, facts: Facts) u32 {
    controller.bios_bytes = rounded(bios_bytes, 64);
    controller.trace_bytes = rounded(if (facts.trace != 0) facts.trace else default_trace, 64);
    controller.state_bytes = rounded(if (facts.state != 0) facts.state else default_state, 64);
    var top: u32 = 0;
    controller.bios_at = 0;
    top = controller.bios_bytes;
    controller.mailbox_at = rounded(top, 256);
    top = controller.mailbox_at + 2 * ring_bytes;
    controller.trace_at = rounded(top, 256);
    top = controller.trace_at + controller.trace_bytes;
    controller.state_at = rounded(top, 256);
    top = controller.state_at + controller.state_bytes;
    return rounded(top, 4096);
}

/// `bytes` of the piece cleared from `offset`, through the mapping that
/// gathers writes.
fn clear(memory: amdgpu.GPUMemory, offset: u32, bytes: u32) void {
    const words: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(memory.cpu)) + offset);
    for (0..bytes / 4) |index| words[index] = 0;
}

/// The controller started, as RTGCTRL_AMD_START_CONTROLLER asks: what
/// it answers, `into` filled in as the controller then stands.
pub fn start(engine: dcn.Engine, controller: *Controller, into: *tags.RtgAmdController) isize {
    const sys = engine.sys;
    into.* = .{};
    if (at(engine, pipes_disabled).* & disabled_controller_present == 0) {
        read(engine, into);
        return err.RTGERR_NOT_SUPPORTED;
    }
    const result = load(engine, controller, into);
    read(engine, into);
    into.firmware = controller.version;
    if (result != err.RTGERR_OK) return result;

    // The question: what the firmware can do, answered in its own slot.
    const memory = controller.memory.?;
    const slot: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(memory.cpu)) + controller.mailbox_at + controller.write);
    const query_caps: u32 = 6;
    const answers: u32 = 1 << 16;
    const payload: u32 = 14 << 24;
    slot[0] = query_caps | answers | payload;
    for (1..command_bytes / 4) |index| slot[index] = 0;
    // The writes gathered so far reach the memory before the controller
    // is told: read back, and fenced.
    for (0..command_bytes / 4) |index| _ = slot[index];
    sdk.hardware.barrier.full();
    controller.write = (controller.write + command_bytes) % ring_bytes;
    at(engine, inbox1_write).* = controller.write;
    const done = struct {
        fn f(engine_: dcn.Engine) bool {
            return at(engine_, inbox1_read).* == at(engine_, inbox1_write).*;
        }
    }.f;
    const answered = waitFor(engine, done);
    read(engine, into);
    into.firmware = controller.version;
    for (&into.reply, 0..) |*reply_word, index| reply_word.* = slot[index];
    const trace: [*]volatile u32 = @ptrFromInt(@as(usize, @intCast(memory.cpu)) + controller.trace_at);
    for (&into.trace, 0..) |*trace_word, index| trace_word.* = trace[index];
    if (!answered) return err.RTGERR_TIMEOUT;
    into.stage = tags.RTG_AMD_STAGE_ANSWERED;
    exec.kprintf(sys, "%s: the display controller runs its firmware %d.%d.%d\n", .{
        dcn.owner, controller.version >> 24, controller.version >> 16 & 0xff, controller.version >> 8 & 0xff,
    });
    return err.RTGERR_OK;
}

/// The firmware read and loaded, the controller reset, set up and let
/// out of reset, and waited for: RTGERR_OK once it says it runs and its
/// mailbox is ready, `into.stage` saying how far it got either way.
fn load(engine: dcn.Engine, controller: *Controller, into: *tags.RtgAmdController) isize {
    const sys = engine.sys;
    const gpu = engine.gpu;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return err.RTGERR_NO_FILE;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var security: amdgpu.GPUBlock = .{};
    if (!gpu.FindGPUBlock(amdgpu.GPUBLOCK_SECURITY, 0, &security)) return err.RTGERR_NOT_SUPPORTED;
    var toc_room: [64]u8 = undefined;
    var firmware_room: [64]u8 = undefined;
    const toc_name = path(sys, &toc_room, "psp", .{ security.major, security.minor, security.revision }, "_toc");
    const firmware_name = path(sys, &firmware_room, "dcn", .{ engine.major, engine.minor, engine.revision }, "_dmcub");
    const toc = readFile(sys, dl, toc_name) orelse return err.RTGERR_NO_FILE;
    defer sys.FreeVec(toc.ptr);
    const firmware = readFile(sys, dl, firmware_name) orelse return err.RTGERR_NO_FILE;
    defer sys.FreeVec(firmware.ptr);
    into.stage = tags.RTG_AMD_STAGE_FILES;

    var bios: amdgpu.GPUBios = .{};
    if (!gpu.GetGPUBios(&bios)) {
        exec.kprintf(sys, "%s: the display controller needs the video BIOS, and there is none\n", .{dcn.owner});
        return err.RTGERR_NOT_SUPPORTED;
    }
    const facts = factsOf(firmware);
    controller.version = facts.version;
    var address: u64 = 0;
    if (!gpu.StartGPUSecurity(toc.ptr, @intCast(toc.len)) or
        !gpu.LoadGPUFirmware(amdgpu.GPUFIRMWARE_DISPLAY, firmware.ptr, @intCast(firmware.len), &address))
    {
        exec.kprintf(sys, "%s: the security processor did not load the display controller's firmware\n", .{dcn.owner});
        return err.RTGERR_IO;
    }
    into.stage = tags.RTG_AMD_STAGE_LOADED;

    const bytes = layOut(controller, bios.bytes, facts);
    if (controller.memory) |memory| {
        if (memory.bytes < bytes) return err.RTGERR_NO_MEMORY;
    } else {
        var memory: amdgpu.GPUMemory = .{};
        if (!gpu.AllocGPUMemory(bytes, 4096, &memory)) return err.RTGERR_NO_MEMORY;
        controller.memory = memory;
    }
    const memory = controller.memory.?;

    reset(engine);
    // The video BIOS copied whole into its window, the rest cleared.
    const bios_copy: [*]volatile u8 = @ptrFromInt(@as(usize, @intCast(memory.cpu)) + controller.bios_at);
    for (bios.image.?[0..bios.bytes], 0..) |byte, index| bios_copy[index] = byte;
    clear(memory, controller.mailbox_at, 2 * ring_bytes);
    clear(memory, controller.trace_at, controller.trace_bytes);
    clear(memory, controller.state_at, controller.state_bytes);
    sdk.hardware.barrier.full();

    setWindow(engine, window_bios, memory.device + controller.bios_at, sees_bios, controller.bios_bytes);
    setWindow(engine, window_mailbox, memory.device + controller.mailbox_at, sees_mailbox, 2 * ring_bytes);
    setWindow(engine, window_trace, memory.device + controller.trace_at, sees_trace, controller.trace_bytes);
    const trace_device = memory.device + controller.trace_at;
    at(engine, region5_offset).* = @truncate(trace_device);
    at(engine, region5_offset + 1).* = @truncate(trace_device >> 32);
    at(engine, region5_top).* = (controller.trace_bytes - 1) & window_top_mask | window_enable;
    setWindow(engine, window_state, memory.device + controller.state_at, sees_state, controller.state_bytes);
    at(engine, outbox0_base).* = sees_region5 + trace_entries_at;
    at(engine, outbox0_size).* = controller.trace_bytes - trace_entries_at;
    at(engine, inbox1_base).* = sees_mailbox;
    at(engine, inbox1_size).* = ring_bytes;
    at(engine, outbox1_base).* = sees_mailbox + ring_bytes;
    at(engine, outbox1_size).* = ring_bytes;
    controller.write = 0;
    scratch(engine, scratch_options).* = boot_options;
    into.stage = tags.RTG_AMD_STAGE_SET_UP;

    // Let out of reset: the hub's side first, the security processor's
    // version (none to give), then the controller with its trace port.
    at(engine, hub_reset).* &= ~hub_reset_controller;
    scratch(engine, scratch_security).* = 0;
    at(engine, control).* |= control_enable | control_trace_port;
    at(engine, control_more).* &= ~more_soft_reset;
    if (!waitFor(engine, upAndReady)) {
        exec.kprintf(sys, "%s: the display controller did not come up (status %x)\n", .{ dcn.owner, scratch(engine, scratch_status).* });
        return err.RTGERR_TIMEOUT;
    }
    into.stage = tags.RTG_AMD_STAGE_UP;
    return err.RTGERR_OK;
}

/// DEVS:firmware/amdgpu/<prefix>_<a>_<b>_<c><suffix>.bin into `room`,
/// through exec's formatter.
fn path(sys: *ExecBase, room: *[64]u8, comptime prefix: [:0]const u8, version: [3]u8, comptime suffix: [:0]const u8) [*:0]const u8 {
    const format = "DEVS:firmware/amdgpu/" ++ prefix ++ "_%u_%u_%u" ++ suffix ++ ".bin";
    const values = .{ @as(u32, version[0]), @as(u32, version[1]), @as(u32, version[2]) };
    comptime exec.checkFormat(format, @TypeOf(values));
    const stream = exec.fmtStream(values);
    var into: Into = .{ .room = room };
    _ = sys.RawDoFmt(format, &stream, &Into.put, &into);
    room[room.len - 1] = 0;
    return @ptrCast(room);
}

/// Where RawDoFmt's characters go: into a room, the rest dropped.
const Into = struct {
    room: *[64]u8,
    len: usize = 0,

    fn put(char: u8, data: ?*anyopaque) callconv(.c) void {
        const into: *Into = @ptrCast(@alignCast(data.?));
        if (into.len < into.room.len) {
            into.room[into.len] = char;
            into.len += 1;
        }
    }
};

/// The file `name` read whole, or null with why said on the log.
fn readFile(sys: *ExecBase, dl: *DosBase, name: [*:0]const u8) ?[]u8 {
    var length: usize = 0;
    const bytes = dl.ReadFile(name, ~@as(usize, 0), exec.MEMF_ANY, &length) orelse {
        exec.kprintf(sys, "%s: %s cannot be read\n", .{ dcn.owner, name });
        return null;
    };
    if (length == 0) {
        sys.FreeVec(bytes);
        exec.kprintf(sys, "%s: %s is empty\n", .{ dcn.owner, name });
        return null;
    }
    return bytes[0..length];
}

// --- tests ------------------------------------------------------------------------

const testing = @import("std").testing;

fn put(room: []u8, offset: usize, value: u32) void {
    room[offset] = @truncate(value);
    room[offset + 1] = @truncate(value >> 8);
    room[offset + 2] = @truncate(value >> 16);
    room[offset + 3] = @truncate(value >> 24);
}

test "the firmware's facts are found where its maker puts them" {
    var file = [_]u8{0} ** 0x1000;
    put(&file, file_header_bytes_at, 0x28);
    put(&file, file_array_at, 0x100);
    put(&file, file_code_bytes_at, 0xe00);
    // The code ends 0x100 before 0x100 + 0xe00; the facts four bytes
    // before that.
    const facts_at = 0x100 + 0xe00 - 0x100 - 4 - 64;
    put(&file, facts_at, facts_mark);
    put(&file, facts_at + facts_state_at, 0xcd00);
    put(&file, facts_at + facts_trace_at, 0x10010);
    put(&file, facts_at + facts_version_at, 0x0800_6500);
    const facts = factsOf(&file);
    try testing.expectEqual(@as(u32, 0x0800_6500), facts.version);
    try testing.expectEqual(@as(u32, 0xcd00), facts.state);
    try testing.expectEqual(@as(u32, 0x10010), facts.trace);

    // Unmarked, or a code count past the file: nothing.
    put(&file, facts_at, 0);
    try testing.expectEqual(@as(u32, 0), factsOf(&file).version);
    put(&file, facts_at, facts_mark);
    put(&file, file_code_bytes_at, 0x1000);
    try testing.expectEqual(@as(u32, 0), factsOf(&file).version);
}

test "the windows are laid out on their boundaries, the whole in pages" {
    var controller: Controller = .{};
    const bytes = layOut(&controller, 16896, .{ .state = 0xcd00, .trace = 0x10010 });
    try testing.expectEqual(@as(u32, 0), controller.bios_at);
    try testing.expectEqual(@as(u32, 16896), controller.bios_bytes);
    try testing.expectEqual(@as(u32, 0x4200), controller.mailbox_at);
    try testing.expectEqual(@as(u32, 0x8200), controller.trace_at);
    try testing.expectEqual(@as(u32, 0x10040), controller.trace_bytes);
    try testing.expectEqual(@as(u32, 0x18300), controller.state_at);
    try testing.expectEqual(@as(u32, 0x25000), bytes);
    // Without the firmware's facts, 64 KiB each.
    _ = layOut(&controller, 100, .{});
    try testing.expectEqual(@as(u32, 0x10000), controller.trace_bytes);
    try testing.expectEqual(@as(u32, 128), controller.bios_bytes);
}
