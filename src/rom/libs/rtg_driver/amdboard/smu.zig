// SPDX-License-Identifier: MPL-2.0
//! The display's clocks: its mailbox to the device's power manager, the
//! manager's table of clock levels, and the clocks running now.
//!
//! **The mailbox** is the display's own three registers in the power
//! manager's second segment - the message, its argument, and the answer
//! - beside the ones amdgpu.resource sends its messages through, and
//! written by nothing else, so it needs no lock shared with the resource.
//! The answer reads 0 while the manager is busy with a message; a
//! message is sent once it reads anything else: the answer cleared, the
//! argument written - a clock's messages take it in MHz - then the
//! message, and the answer waited for again. What the manager hands back
//! is in the argument register. 1 is done; 0xFF failed, 0xFE a message
//! it does not know, 0xFD one it refuses before something else is done,
//! 0xFC one it refuses while it is busy.
//!
//! **The table of levels** (`TABLE_DPMCLOCKS`) is copied by the manager
//! into memory the device reaches, at an address told it in two halves
//! first: a piece of the device's memory, taken for the copy and given
//! back after.
//!
//! **The clocks running now** are divided from one PLL of the device's
//! clock generator, whose multiplier of a 48 MHz reference the generator
//! holds (`CLK1_CLK_PLL_REQ`, 8 bits whole and 16 bits of fraction); the
//! display clock and the pipes' clock are that PLL's frequency divided by
//! the dividers the engine's own clock block holds (`DENTIST_DISPCLK_CNTL`),
//! each named by a number that stands for a divider counted in quarters.
//!
//! Nothing here is sent unless asked for: the board's controls
//! (RTGCTRL_AMD_*) ask, which `C:test/Gpu CLOCKS` does with the watchdog
//! armed.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const rtg = sdk.rtg;
const err = rtg.errors;
const ExecBase = sdk.interface.exec.ExecBase;
const AMDGPUBase = sdk.interface.amdgpu.AMDGPUBase;
const dcn = @import("dcn.zig");

/// The mailbox's registers, counted in 32-bit words from the power
/// manager's second address.
const manager_segment = 1;
const mailbox_message = 0x283;
const mailbox_argument = 0x293;
const mailbox_answer = 0x29b;

/// The answers.
pub const ANSWER_BUSY: u32 = 0x00;
pub const ANSWER_DONE: u32 = 0x01;

/// The messages sent.
const message_version: u32 = 0x02;
const message_address_high: u32 = 0x0e;
const message_address_low: u32 = 0x0f;
const message_table_out: u32 = 0x10;

/// The manager's table of clock levels, by its number, and what the
/// memory it is copied into starts on: a page, as the manager's tables
/// are handed it.
const table_levels: u32 = 4;
const table_alignment: u32 = 4096;

/// How long an answer is waited for, and how often it is looked at.
const answer_most_us: u64 = 2_000_000;
const answer_step_us: u32 = 10;

/// The PLL's multiplier, in the clock generator's first segment, and the
/// reference it multiplies.
const pll_request = 0x237;
const pll_whole_mask: u32 = 0x1ff;
const pll_fraction_shift = 16;
const reference_khz: u64 = 48_000;
/// How far past its first address the generator's register is.
const generator_reach: u64 = 0x240;

/// The engine's dividers: the display clock's in bits 6-0, the pipes'
/// clock's in bits 30-24.
const dentist = 0x64;
const disp_divider_mask: u32 = 0x7f;
const dpp_divider_shift = 24;

/// The manager's table, as it copies it out (all little-endian): its
/// clocks per level, then the data fabric's states, then the counts.
const Table = extern struct {
    dcf: [8]u32,
    disp: [8]u32,
    dpp: [8]u32,
    soc: [8]u32,
    video: [8]u32,
    decode: [8]u32,
    soc_voltage: [8]u32,
    fabric: [4]extern struct {
        fabric_mhz: u32,
        memory_mhz: u32,
        voltage: u32,
        ratio: u8,
        spare: [3]u8,
    },
    dcf_count: u8,
    disp_count: u8,
    soc_count: u8,
    video_count: u8,
    fabric_count: u8,
    spare: [3]u8,
    min_graphics: u32,
    max_graphics: u32,
};

comptime {
    // As the manager lays it out.
    if (@sizeOf(Table) != 7 * 8 * 4 + 4 * 16 + 8 + 8) @compileError("the manager's table is laid out otherwise");
}

/// Where the mailbox and the clock generator are: the register window as
/// the machine reaches it, and each one's first register in 32-bit words
/// into it - 0 for one the device's table does not name.
pub const Mailbox = struct {
    registers: usize = 0,
    manager: u32 = 0,
    generator: u32 = 0,
};

/// The mailbox of the device behind `engine`, and its clock generator,
/// as the device's table places them. The manager's place is the one
/// amdgpu.resource's own mailbox is counted from, which is where the
/// display's registers are; a table that places either outside the
/// device's registers names nothing.
pub fn find(engine: dcn.Engine) Mailbox {
    var info: amdgpu.GPUInfo = .{};
    if (!engine.gpu.GetGPUInfo(&info)) return .{};
    var mailbox: Mailbox = .{ .registers = engine.registers };
    var block: amdgpu.GPUBlock = .{};
    if (engine.gpu.FindGPUBlock(amdgpu.GPUBLOCK_POWER, 0, &block) and block.count > manager_segment) {
        const end = (@as(u64, block.addresses[manager_segment]) + mailbox_answer + 1) * 4;
        if (end <= info.registers_bytes) mailbox.manager = block.addresses[manager_segment];
    }
    if (engine.gpu.FindGPUBlock(amdgpu.GPUBLOCK_CLOCKS, 0, &block) and block.count > 0) {
        const end = (@as(u64, block.addresses[0]) + generator_reach) * 4;
        if (end <= info.registers_bytes) mailbox.generator = block.addresses[0];
    }
    return mailbox;
}

/// What a message was answered with: the answer, and what the manager
/// handed back.
pub const Answer = struct { answer: u32, value: u32 };

/// `message` sent with `argument`: what the manager answered, or null
/// where there is no mailbox, or it did not take the last message, or
/// this one, in time.
pub fn send(sys: *ExecBase, mailbox: Mailbox, message: u32, argument: u32) ?Answer {
    if (mailbox.manager == 0) return null;
    const at = mailbox.registers + @as(usize, mailbox.manager) * 4;
    if (!answered(sys, at)) return null;
    reg(at + mailbox_answer * 4).* = ANSWER_BUSY;
    reg(at + mailbox_argument * 4).* = argument;
    reg(at + mailbox_message * 4).* = message;
    if (!answered(sys, at)) return null;
    return .{
        .answer = reg(at + mailbox_answer * 4).*,
        .value = reg(at + mailbox_argument * 4).*,
    };
}

/// Whether the answer register reads other than busy within the time an
/// answer is waited for, by the machine's clock.
fn answered(sys: *ExecBase, at: usize) bool {
    const until = sys.UptimeUs() + answer_most_us;
    while (reg(at + mailbox_answer * 4).* == ANSWER_BUSY) {
        if (sys.UptimeUs() > until) return false;
        var never: exec.Waitable = .{};
        const list = [_]*exec.Waitable{&never};
        _ = sys.WaitForAny(&list, 1, answer_step_us);
    }
    return true;
}

/// The manager's firmware version, as RTGCTRL_AMD_FIRMWARE answers it.
pub fn version(sys: *ExecBase, mailbox: Mailbox) isize {
    const answer = send(sys, mailbox, message_version, 0) orelse return err.RTGERR_TIMEOUT;
    if (answer.answer != ANSWER_DONE) return err.RTGERR_IO;
    return answer.value;
}

/// `clocks` filled in, as RTGCTRL_AMD_CLOCKS answers it.
pub fn clocks(engine: dcn.Engine, mailbox: Mailbox, into: *rtg.tags.RtgAmdClocks) isize {
    const sys = engine.sys;
    into.* = .{};
    running(engine, mailbox, into);
    const firmware = version(sys, mailbox);
    if (firmware < 0) return firmware;
    into.firmware = @intCast(firmware);

    var memory: amdgpu.GPUMemory = .{};
    if (!engine.gpu.AllocGPUMemory(@sizeOf(Table), table_alignment, &memory)) return err.RTGERR_NO_MEMORY;
    defer engine.gpu.FreeGPUMemory(&memory);
    const table: *volatile Table = @ptrFromInt(@as(usize, @intCast(memory.cpu)));
    const bytes: [*]volatile u8 = @ptrCast(table);
    for (0..@sizeOf(Table)) |index| bytes[index] = 0;
    const steps = [_]struct { message: u32, argument: u32 }{
        .{ .message = message_address_high, .argument = @truncate(memory.device >> 32) },
        .{ .message = message_address_low, .argument = @truncate(memory.device) },
        .{ .message = message_table_out, .argument = table_levels },
    };
    for (steps) |step| {
        const answer = send(sys, mailbox, step.message, step.argument) orelse return err.RTGERR_TIMEOUT;
        into.answer = answer.answer;
        into.message = step.message;
        if (answer.answer != ANSWER_DONE) return err.RTGERR_IO;
    }
    const copy: Table = table.*;
    into.dcf_count = @min(copy.dcf_count, rtg.tags.RTG_AMD_LEVELS);
    into.disp_count = @min(copy.disp_count, rtg.tags.RTG_AMD_LEVELS);
    into.soc_count = @min(copy.soc_count, rtg.tags.RTG_AMD_LEVELS);
    into.fabric_count = @min(copy.fabric_count, rtg.tags.RTG_AMD_FABRIC_STATES);
    into.dcf_mhz = copy.dcf;
    into.disp_mhz = copy.disp;
    into.dpp_mhz = copy.dpp;
    into.soc_mhz = copy.soc;
    for (copy.fabric, 0..) |state, index| {
        into.fabric_mhz[index] = state.fabric_mhz;
        into.memory_mhz[index] = state.memory_mhz;
        into.fabric_voltage[index] = state.voltage;
    }
    return err.RTGERR_OK;
}

/// The clocks running now into `into`: the PLL's frequency from the
/// generator, and the display clock and the pipes' clock from the
/// engine's dividers. Read only; nothing where the generator is not
/// known.
fn running(engine: dcn.Engine, mailbox: Mailbox, into: *rtg.tags.RtgAmdClocks) void {
    if (mailbox.generator == 0) return;
    const request = reg(engine.registers + (@as(usize, mailbox.generator) + pll_request) * 4).*;
    into.pll_khz = pllKhz(request);
    const dividers = reg(engine.registers + (@as(usize, engine.clocks) + dentist) * 4).*;
    into.disp_khz = dividedKhz(into.pll_khz, dividers & disp_divider_mask);
    into.dpp_khz = dividedKhz(into.pll_khz, dividers >> dpp_divider_shift & disp_divider_mask);
}

/// The PLL's frequency in kHz from its request register: the reference
/// times the multiplier, its fraction in 16 bits.
pub fn pllKhz(request: u32) u32 {
    const whole: u64 = request & pll_whole_mask;
    const fraction: u64 = request >> pll_fraction_shift;
    return @intCast((whole * reference_khz) + (fraction * reference_khz >> 16));
}

/// A clock in kHz divided from `pll_khz` by the divider the number `id`
/// stands for, in quarters: from 0x08 up in quarters from 2, from 0x40 in
/// halves from 16, from 0x60 in wholes from 32, and from 0x7E in steps of
/// 66 from 62 - which makes 0x7F 128. A number below 0x08 is taken as
/// 0x08, one above 0x7F as 0x7F, as the engine takes them.
pub fn dividedKhz(pll_khz: u32, id: u32) u32 {
    const number: u32 = @min(@max(id, 0x08), 0x7f);
    const quarters: u64 = if (number < 0x40)
        8 + (number - 0x08)
    else if (number < 0x60)
        64 + (number - 0x40) * 2
    else if (number < 0x7e)
        128 + (number - 0x60) * 4
    else
        248 + (number - 0x7e) * 264;
    return @intCast(@as(u64, pll_khz) * 4 / quarters);
}

// --- tests ------------------------------------------------------------------------

const testing = @import("std").testing;

test "the PLL's frequency is the reference times its multiplier, fraction and all" {
    // 75 whole: 3.6 GHz.
    try testing.expectEqual(@as(u32, 3_600_000), pllKhz(75));
    // 75 and a half.
    try testing.expectEqual(@as(u32, 3_624_000), pllKhz(75 | 0x8000 << 16));
    // Bits between the whole and the fraction are not the multiplier's.
    try testing.expectEqual(@as(u32, 3_600_000), pllKhz(75 | 0xf000));
}

test "a divider's number stands for quarters, halves and wholes by its range" {
    // 0x08: 2.00, 0x0c: 3.00, 0x40: 16.0, 0x41: 16.5, 0x60: 32, 0x7e: 62, 0x7f: 128.
    try testing.expectEqual(@as(u32, 1_800_000), dividedKhz(3_600_000, 0x08));
    try testing.expectEqual(@as(u32, 1_200_000), dividedKhz(3_600_000, 0x0c));
    try testing.expectEqual(@as(u32, 225_000), dividedKhz(3_600_000, 0x40));
    try testing.expectEqual(@as(u32, 218_181), dividedKhz(3_600_000, 0x41));
    try testing.expectEqual(@as(u32, 112_500), dividedKhz(3_600_000, 0x60));
    try testing.expectEqual(@as(u32, 58_064), dividedKhz(3_600_000, 0x7e));
    try testing.expectEqual(@as(u32, 28_125), dividedKhz(3_600_000, 0x7f));
    // Below the first number, the first's divider.
    try testing.expectEqual(@as(u32, 1_800_000), dividedKhz(3_600_000, 0x00));
}
