// SPDX-License-Identifier: MPL-2.0
//! The picture's checksum, as the display's timing generator computes it
//! over what it sends out - a test tool: a step that should change
//! nothing on the screen is proved by the same checksum before and
//! after it, read over a line that needs no one at the monitor.
//!
//! The generator sums each colour of every pixel of a window into a
//! 16-bit CRC per frame. The window is the whole picture (its visible
//! width and height, made the new one's by a mode set), the sum taken
//! every frame once switched on, and left on: reading it again only
//! reads. The first read switches it on
//! and lets three frames pass, so that the sum read is a whole frame's.

const sdk = @import("sdk");
const exec = sdk.exec;
const reg = sdk.hardware.mmio.reg;
const tags = sdk.rtg.tags;
const err = sdk.rtg.errors;
const ExecBase = sdk.interface.exec.ExecBase;
const dcn = @import("dcn.zig");

/// The timing generator's checksum registers, in 32-bit words from the
/// engine's third address, the first generator's; each next one is a
/// pipe's stride on.
const crc_control = 0x1b68;
const window_a_x = 0x1b69;
const window_a_y = 0x1b6a;
const window_b_x = 0x1b6b;
const window_b_y = 0x1b6c;
const data_red_green = 0x1b6d;
const data_blue = 0x1b6e;
const pipe_stride = 0x80;

/// Its bits: summing on, every frame; the window's end in the upper
/// half of its register.
const crc_on: u32 = 1 << 0;
const crc_every_frame: u32 = 1 << 4;
const window_end_shift = 16;
const window_mask: u32 = 0x7fff;

/// How long three frames at the slowest rate a monitor runs at take.
const settle_us: u64 = 3 * 42_000;

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.block) + offset + engine.pipe * pipe_stride) * 4);
}

/// The window's register: from 0 to `end`.
pub fn window(end: u32) u32 {
    return (end & window_mask) << window_end_shift;
}

/// The checksum of the picture the board's pipe sends now, into `into`:
/// RTGERR_OK, or RTGERR_NO_DISPLAY where the board drives no picture.
pub fn read(engine: dcn.Engine, into: *tags.RtgAmdCrc) isize {
    into.* = .{};
    if (engine.width == 0 or engine.height == 0) return err.RTGERR_NO_DISPLAY;
    if (at(engine, crc_control).* & crc_on == 0) {
        at(engine, crc_control).* = 0;
        at(engine, window_a_x).* = window(engine.width);
        at(engine, window_a_y).* = window(engine.height);
        at(engine, window_b_x).* = window(engine.width);
        at(engine, window_b_y).* = window(engine.height);
        at(engine, crc_control).* = crc_every_frame | crc_on;
        pause(engine.sys, settle_us);
        into.started = 1;
    }
    const red_green = at(engine, data_red_green).*;
    into.red = red_green & 0xffff;
    into.green = red_green >> 16;
    into.blue = at(engine, data_blue).* & 0xffff;
    into.pipe = engine.pipe;
    return err.RTGERR_OK;
}

/// The window made the picture the pipe now scans, where the sum is on:
/// what a mode set has done after it.
pub fn fit(engine: dcn.Engine) void {
    if (at(engine, crc_control).* & crc_on == 0) return;
    at(engine, window_a_x).* = window(engine.width);
    at(engine, window_a_y).* = window(engine.height);
    at(engine, window_b_x).* = window(engine.width);
    at(engine, window_b_y).* = window(engine.height);
}

/// `us` microseconds let pass, the task waiting.
fn pause(sys: *ExecBase, us: u64) void {
    var never: exec.Waitable = .{};
    const list = [_]*exec.Waitable{&never};
    _ = sys.WaitForAny(&list, 1, us);
}

test "the window runs from 0 to the picture's edge" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u32, 2560 << 16), window(2560));
    try testing.expectEqual(@as(u32, 1440 << 16), window(1440));
    try testing.expectEqual(@as(u32, 0x7fff << 16), window(0xffff));
}
