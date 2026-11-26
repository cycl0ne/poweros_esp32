// SPDX-License-Identifier: MPL-2.0
//! The display's clocks set to what its planes ask (`bandwidth.Demand`), as
//! the vendor's clock manager sets them for this engine
//! (dcn314_update_clocks): in two passes round every change of what the
//! pipes read - before it, every clock that goes up (`raise`); after it,
//! once the pipes run on their new schedules, every one that goes down
//! (`lower`) - so nothing runs slower than either side of the change needs
//! while it is made.
//!
//! What is asked of the power manager (`smu.ask`), in MHz rounded up: the
//! least the display controller's clock (DCFCLK) runs at, the least it
//! falls to in deep sleep, the display clock (DISPCLK) - asked for as 100
//! MHz at least - and the pipes' clock (DPPCLK), 100 MHz at least. A pass
//! asks for a clock only where it moves it the pass's way, the second
//! where it moves it either way.
//!
//! Each pipe runs at a share of the pipes' clock that a divider of its own
//! in the engine's clock block makes (`DPPCLKn_DTO_PARAM`, its enable in
//! `DPPCLK_DTO_CTRL`): 255ths of the pipes' clock asked for, rounded up -
//! the pipe the pipes' clock is worked out for at all 255 of them. A pipe
//! that reads nothing has its divider off, which passes it the whole
//! clock. A divider is written in the first pass only where its pipe's
//! share goes up, in the second every one. Where the pipes' clock goes
//! down, the dividers are written first - their pipes' shares of the lower
//! clock, each more of it than before - and the clock lowered after; else
//! the clock is set first, where it or the display clock moved, and the
//! dividers after - in the first pass only where the pipes' clock does not
//! go down from the one the pipes run at.
//!
//! The first pass is preceded once by the manager being told the display
//! is in use, with no idle optimization, and that the engine's deeper
//! power states are not to be entered (`smu.useDisplay`) - which the
//! vendor allows only with no plane lit, or with a panel alone, and the
//! board drives a monitor - and by the watermark sets it picks by the
//! display controller's clock (`smu.sendRanges`). What a pass asked is
//! told the display controller after it (`dmub.notifyClocks`), by the
//! board, which holds the controller.
//!
//! What the manager answers to each clock asked is kept beside it: at
//! least the clock asked, though not the one that runs - the display
//! clock's divider reads back the clock asked, rounded up to the next
//! divider, where the answer can be higher (266 MHz for 247).
//!
//! What runs when the board first asks is where it starts from
//! (`startFrom`): the display clock as the engine reads its divider back,
//! so the first pass does not lower it. The pipes' clock's divider is not
//! read back, nor are the display controller's clocks: those start at 0,
//! as the vendor starts every clock, so the first pass asks for them
//! whichever way they move, and writes the divider of each pipe that
//! reads anything.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const ExecBase = sdk.interface.exec.ExecBase;
const rtg = sdk.rtg;
const dcn = @import("dcn.zig");
const smu = @import("smu.zig");
const bandwidth = @import("bandwidth.zig");

/// The engine's pipes, each with a divider.
pub const pipe_count = 4;

/// The pipes' dividers, in the engine's clock block: each one's phase and
/// modulo - a pipe's clock is the pipes' clock times the phase over the
/// modulo - and their enables, a bit each four apart.
const divider_param = 0x0099;
const divider_control = 0x00b6;
const modulo_shift = 16;
const modulo: u32 = 0xff;
const enable_stride = 4;

/// The least the display clock is asked for and the pipes' clock set to,
/// in kHz.
const display_least_khz: u32 = 100_000;
const pipes_least_khz: u32 = 100_000;

/// What the manager and the pipes' dividers were last told, in kHz.
pub const Told = struct {
    /// Whether the manager has been told the display is in use and handed
    /// the watermark sets, and whether `startFrom` has read what runs.
    started: bool = false,
    read: bool = false,
    controller_khz: u32 = 0,
    deep_sleep_khz: u32 = 0,
    display_khz: u32 = 0,
    pipes_khz: u32 = 0,
    /// Each pipe's request of its divider, 0 for one off.
    pipe_khz: [pipe_count]u32 = @splat(0),
    /// The pipes' clock the pipes ran at before the change, as the last
    /// pass left it.
    fitted_pipes_khz: u32 = 0,
    /// What the manager answered when each clock was last asked, in MHz:
    /// 0 before it was asked, or where it refused.
    answered_controller_mhz: u32 = 0,
    answered_deep_sleep_mhz: u32 = 0,
    answered_display_mhz: u32 = 0,
    answered_pipes_mhz: u32 = 0,
    /// Whether a message was refused or not answered in the last pass,
    /// and which.
    refused: u32 = 0,
};

/// What a demand asks of each pipe: its share of the pipes' clock, by
/// pipe - 0 for one that reads nothing.
pub const Asked = struct {
    controller_khz: u32,
    deep_sleep_khz: u32,
    display_khz: u32,
    pipes_khz: u32,
    pipe_khz: [pipe_count]u32,
};

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.clocks) + offset) * 4);
}

/// What runs now into `told`, once: the display clock as the engine
/// reads its divider back.
pub fn startFrom(engine: dcn.Engine, mailbox: smu.Mailbox, told: *Told) void {
    if (told.read) return;
    var running: rtg.tags.RtgAmdClocks = .{};
    smu.readRunning(engine, mailbox, &running);
    told.display_khz = running.disp_khz;
    told.read = true;
}

/// Each pipe's divider as the engine holds it into `into`: its phase and
/// modulo, 0 for one off.
pub fn readDividers(engine: dcn.Engine, into: *rtg.tags.RtgAmdClocks) void {
    const control = at(engine, divider_control).*;
    for (0..pipe_count) |pipe| {
        const on = control >> @intCast(pipe * enable_stride) & 1 != 0;
        into.dividers[pipe] = if (on) at(engine, divider_param + @as(u32, @intCast(pipe))).* else 0;
    }
}

/// The first pass, before a change (the module's header says what it
/// asks), `levels` the display controller clock's first four levels for
/// the watermark sets, in MHz.
pub fn raise(engine: dcn.Engine, mailbox: smu.Mailbox, told: *Told, asked: Asked, levels: [4]u32) void {
    told.refused = 0;
    if (!told.started) {
        if (!smu.useDisplay(engine.sys, mailbox)) told.refused = 0x12;
        if (!smu.sendRanges(engine, mailbox, levels)) told.refused = 0x11;
        told.started = true;
    }
    pass(engine, mailbox, told, asked, false);
}

/// The second pass, after a change, once the pipes run on their new
/// schedules.
pub fn lower(engine: dcn.Engine, mailbox: smu.Mailbox, told: *Told, asked: Asked) void {
    told.refused = 0;
    pass(engine, mailbox, told, asked, true);
}

/// Whether a pass sets a clock from `now` to `wanted`: up in either pass,
/// down only in the second.
fn moves(lowers: bool, wanted: u32, now: u32) bool {
    return wanted > now or (lowers and wanted < now);
}

fn pass(engine: dcn.Engine, mailbox: smu.Mailbox, told: *Told, asked: Asked, lowers: bool) void {
    const sys = engine.sys;
    if (moves(lowers, asked.controller_khz, told.controller_khz)) {
        told.controller_khz = asked.controller_khz;
        told.answered_controller_mhz = tell(sys, mailbox, told, smu.message_least_controller_clock, asked.controller_khz);
    }
    if (moves(lowers, asked.deep_sleep_khz, told.deep_sleep_khz)) {
        told.deep_sleep_khz = asked.deep_sleep_khz;
        told.answered_deep_sleep_mhz = tell(sys, mailbox, told, smu.message_deep_sleep_clock, asked.deep_sleep_khz);
    }
    const pipes = @max(asked.pipes_khz, pipes_least_khz);
    var pipes_moved = false;
    var pipes_lowered = false;
    if (moves(lowers, pipes, told.pipes_khz)) {
        pipes_lowered = pipes < told.pipes_khz;
        told.pipes_khz = pipes;
        pipes_moved = true;
    }
    var display_moved = false;
    if (asked.display_khz > 0 and moves(lowers, asked.display_khz, told.display_khz)) {
        told.display_khz = asked.display_khz;
        told.answered_display_mhz = tell(sys, mailbox, told, smu.message_display_clock, @max(asked.display_khz, display_least_khz));
        display_moved = true;
    }
    if (pipes_lowered) {
        // Each pipe's share of the lower clock first, then the clock.
        writeDividers(engine, told, asked, lowers);
        told.answered_pipes_mhz = tell(sys, mailbox, told, smu.message_pipes_clock, told.pipes_khz);
    } else {
        if (pipes_moved or display_moved) told.answered_pipes_mhz = tell(sys, mailbox, told, smu.message_pipes_clock, told.pipes_khz);
        if (lowers or pipes >= told.fitted_pipes_khz) writeDividers(engine, told, asked, lowers);
    }
    if (lowers) told.fitted_pipes_khz = pipes;
}

/// A clock asked of the manager: the MHz it answered, or 0 where it
/// refused - which `told.refused` keeps.
fn tell(sys: *ExecBase, mailbox: smu.Mailbox, told: *Told, message: u32, khz: u32) u32 {
    return smu.ask(sys, mailbox, message, khz) orelse {
        told.refused = message;
        return 0;
    };
}

/// Each pipe's divider told its share of the pipes' clock as `told` now
/// holds it: every one in the second pass, in the first only those whose
/// share goes up.
fn writeDividers(engine: dcn.Engine, told: *Told, asked: Asked, lowers: bool) void {
    for (0..pipe_count) |pipe| {
        const wanted = asked.pipe_khz[pipe];
        if (!lowers and told.pipe_khz[pipe] >= wanted) continue;
        const enable = @as(u32, 1) << @intCast(pipe * enable_stride);
        const control = at(engine, divider_control);
        if (wanted == 0 or told.pipes_khz == 0) {
            control.* &= ~enable;
        } else {
            at(engine, divider_param + @as(u32, @intCast(pipe))).* = phaseOf(wanted, told.pipes_khz) | modulo << modulo_shift;
            control.* |= enable;
        }
        told.pipe_khz[pipe] = wanted;
    }
}

/// A pipe's phase for `wanted_khz` of `pipes_khz`, in 255ths rounded up,
/// all of them at most.
pub fn phaseOf(wanted_khz: u32, pipes_khz: u32) u32 {
    const phase = (@as(u64, modulo) * wanted_khz + pipes_khz - 1) / pipes_khz;
    return @intCast(@min(phase, modulo));
}

/// What a demand asks of the pipes, `pipes` naming the pipe of each of its
/// planes in their order.
pub fn askedOf(demand: *const bandwidth.Demand, pipes: []const u32) Asked {
    var asked: Asked = .{
        .controller_khz = demand.controller_khz,
        .deep_sleep_khz = demand.clocks.deep_sleep_hz / 1000,
        .display_khz = demand.clocks.display_khz,
        .pipes_khz = demand.clocks.pipes_khz,
        .pipe_khz = @splat(0),
    };
    for (pipes, 0..) |pipe, index| asked.pipe_khz[pipe] = demand.clocks.pipe_khz[index];
    return asked;
}

// --- tests ------------------------------------------------------------------------

const testing = @import("std").testing;

test "a pipe's share of the pipes' clock in 255ths, rounded up" {
    try testing.expectEqual(@as(u32, 255), phaseOf(243_257, 243_257));
    try testing.expectEqual(@as(u32, 114), phaseOf(243_598, 546_988));
    try testing.expectEqual(@as(u32, 52), phaseOf(243_257, 1_200_000));
    try testing.expectEqual(@as(u32, 255), phaseOf(300_000, 243_257));
}

test "the first pass raises only, the second lowers" {
    try testing.expect(moves(false, 2, 1));
    try testing.expect(!moves(false, 1, 2));
    try testing.expect(moves(true, 1, 2));
    try testing.expect(!moves(true, 2, 2));
}
