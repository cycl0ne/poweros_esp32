// SPDX-License-Identifier: MPL-2.0
//! The display engine's hot-plug lines: one per socket's HPD pin, five
//! in all, each sensing whether a monitor is at the far end.
//!
//! A line raises its interrupt when what it senses matches the polarity
//! it is told to wait for - so the polarity is always set to the opposite
//! of what it senses now, and turned again each time it raises one: a
//! plug wakes it, then an unplug, and so on. All five raise the same
//! source of the device's interrupt ring; which line it was is read from
//! the lines' own status registers, each acknowledged at its own control
//! register. Only a line the engine has switched on (its control's enable
//! bit, which the firmware sets for the sockets it uses) senses at all;
//! the others are switched on here, so that every socket is heard.
//!
//! What a line has done is counted beside the board (`Lines`), for
//! RTGCTRL_AMD_EVENTS to answer.

const sdk = @import("sdk");
const amdgpu = sdk.resources.amdgpu;
const exec = sdk.exec;
const reg = sdk.hardware.mmio.reg;
const tags = sdk.rtg.tags;
const dcn = @import("dcn.zig");

/// How many lines the engine has.
pub const count = tags.RTG_AMD_HOT_PLUG_LINES;

/// The first line's registers, in 32-bit words from the engine's third
/// address; each next line's are `stride` on.
const status_at = 0x1f14;
const int_control_at = 0x1f15;
const control_at = 0x1f16;
const stride = 8;

/// Their bits: the line raised its interrupt, what it senses (and that
/// after the line's filter), the interrupt's acknowledge, the polarity
/// waited for, the interrupt on, the line on.
pub const status_raised: u32 = 1 << 0;
pub const status_sense: u32 = 1 << 1;
pub const status_sense_delayed: u32 = 1 << 4;
const int_ack: u32 = 1 << 0;
const int_polarity: u32 = 1 << 8;
const int_enable: u32 = 1 << 16;
pub const control_enable: u32 = 1 << 28;

/// What the lines have done since they were first listened to.
pub const Lines = struct {
    listening: bool = false,
    interrupts: u32 = 0,
    changes: [count]u32 = @splat(0),
};

fn at(engine: dcn.Engine, line: u32, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.block) + offset + line * stride) * 4);
}

/// Each line's status and control registers into `into`.
pub fn read(engine: dcn.Engine, into: *tags.RtgAmdEvents) void {
    for (0..count) |index| {
        const line: u32 = @intCast(index);
        into.line_status[index] = at(engine, line, status_at).*;
        into.line_control[index] = at(engine, line, control_at).*;
    }
}

/// The polarity a line is told to wait for: the opposite of what it
/// senses.
pub fn polarityFor(status: u32) u32 {
    return if (status & status_sense_delayed != 0) 0 else int_polarity;
}

/// Every line switched on and listened to, `server` added for the
/// lines' source: whether the server could be added.
pub fn listen(engine: dcn.Engine, lines: *Lines, server: *exec.Interrupt) bool {
    if (lines.listening) return true;
    if (!engine.gpu.AddGPUIntServer(amdgpu.GPUINT_CLIENT_DISPLAY, amdgpu.GPUINT_DISPLAY_HOT_PLUG, server)) return false;
    lines.listening = true;
    for (0..count) |index| {
        const line: u32 = @intCast(index);
        const control = at(engine, line, control_at);
        if (control.* & control_enable == 0) control.* |= control_enable;
    }
    // The server turns the same registers on whichever core takes the
    // device's message.
    engine.sys.Disable();
    defer engine.sys.Enable();
    for (0..count) |index| {
        const line: u32 = @intCast(index);
        const status = at(engine, line, status_at).*;
        const int_control = at(engine, line, int_control_at);
        int_control.* = int_control.* & ~int_polarity | polarityFor(status) | int_ack | int_enable;
    }
    return true;
}

/// The lines' interrupts off and the server taken off.
pub fn unlisten(engine: dcn.Engine, lines: *Lines, server: *exec.Interrupt) void {
    if (!lines.listening) return;
    engine.sys.Disable();
    for (0..count) |index| {
        const int_control = at(engine, @intCast(index), int_control_at);
        int_control.* = int_control.* & ~int_enable | int_ack;
    }
    engine.sys.Enable();
    engine.gpu.RemGPUIntServer(server);
    lines.listening = false;
}

/// Line `line` (0 to 4) told to wait for what it senses now, so that
/// it raises its interrupt at once - which the server counts and turns
/// back. False for no such line or lines not listened to.
pub fn poke(engine: dcn.Engine, lines: *Lines, line: u32) bool {
    if (line >= count or !lines.listening) return false;
    engine.sys.Disable();
    defer engine.sys.Enable();
    const status = at(engine, line, status_at).*;
    const int_control = at(engine, line, int_control_at);
    int_control.* = int_control.* & ~int_polarity | (polarityFor(status) ^ int_polarity);
    return true;
}

/// In the server: each line that raised its interrupt counted,
/// acknowledged and turned to wait for the opposite.
pub fn take(engine: dcn.Engine, lines: *Lines) void {
    lines.interrupts +%= 1;
    for (0..count) |index| {
        const line: u32 = @intCast(index);
        const status = at(engine, line, status_at).*;
        if (status & status_raised == 0) continue;
        lines.changes[index] +%= 1;
        const int_control = at(engine, line, int_control_at);
        int_control.* = int_control.* & ~int_polarity | polarityFor(status) | int_ack;
    }
}

test "a line waits for the opposite of what it senses" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u32, 0), polarityFor(status_sense_delayed | status_sense));
    try testing.expectEqual(int_polarity, polarityFor(0));
    // The undelayed sense alone is not taken: the filter has not passed it.
    try testing.expectEqual(int_polarity, polarityFor(status_sense));
}
