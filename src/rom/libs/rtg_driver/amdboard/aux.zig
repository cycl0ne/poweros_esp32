// SPDX-License-Identifier: MPL-2.0
//! A socket's AUX channel made ready for the display controller to use.
//!
//! Each DDC line's two pins serve either I2C - an HDMI or DVI monitor's
//! EDID - or DisplayPort's AUX channel, by the pad's mode; and each line
//! has an AUX engine of its own, which drives the channel. Before the
//! controller is sent an AUX transaction on a line, the line's pad is put
//! into AUX mode - its mode bit set, its I2C mode cleared - and the
//! engine switched on, reset on the way where it was off; then the
//! engine is asked for and given back once, which settles who may use its
//! registers. An engine the controller holds for itself is left alone,
//! and the transaction not sent. The controller does the transaction
//! itself.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const dcn = @import("dcn.zig");

/// How many lines there are with an AUX engine.
pub const lines = 5;

/// The first line's pad mask register and each next one's step; the
/// register holding every pad's I2C mode.
const pad_mask_at = 0x28d0;
const pad_mask_stride = 4;
const pad_control_5 = 0x291d;

/// The first engine's control and arbitration registers and each next
/// engine's step.
const aux_control_at = 0x1f50;
const aux_arbitration_at = 0x1f52;
const aux_status_at = 0x1f54;
const aux_receive_at = 0x1f5a;
const aux_stride = 0x1c;

/// Their bits.
const pad_aux_mode: u32 = 1 << 16;
const pad_i2c_mode_first: u32 = 1 << 12;
const aux_enable: u32 = 1 << 0;
const aux_reset: u32 = 1 << 4;
const aux_reset_done: u32 = 1 << 5;
const arbitration_owner_mask: u32 = 0x3 << 2;
const arbitration_controller_owns: u32 = 2 << 2;
const arbitration_request: u32 = 1 << 16;
const arbitration_done: u32 = 1 << 17;

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.block) + offset) * 4);
}

/// Where line `line`'s registers are.
pub fn padMask(line: u32) u32 {
    return pad_mask_at + line * pad_mask_stride;
}

pub fn auxControl(line: u32) u32 {
    return aux_control_at + line * aux_stride;
}

/// Line `line`'s engine's control, arbitration, status and receive
/// registers into `into`.
pub fn read(engine: dcn.Engine, line: u32, into: *[4]u32) void {
    if (line >= lines) return;
    const step = line * aux_stride;
    into.* = .{
        at(engine, aux_control_at + step).*,
        at(engine, aux_arbitration_at + step).*,
        at(engine, aux_status_at + step).*,
        at(engine, aux_receive_at + step).*,
    };
}

/// Line `line`'s pad in AUX mode and its engine on: false for a line
/// that has none, or whose engine the controller holds.
pub fn ready(engine: dcn.Engine, line: u32) bool {
    if (line >= lines) return false;
    const mask = at(engine, padMask(line));
    if (mask.* & pad_aux_mode == 0) mask.* |= pad_aux_mode;
    const pads = at(engine, pad_control_5);
    pads.* &= ~(pad_i2c_mode_first << @intCast(line));

    const arbitration = at(engine, aux_arbitration_at + line * aux_stride);
    if (arbitration.* & arbitration_owner_mask == arbitration_controller_owns) return false;
    const control = at(engine, auxControl(line));
    if (control.* & aux_enable == 0) {
        control.* |= aux_enable | aux_reset;
        waitFor(engine.sys, control, aux_reset_done, aux_reset_done);
        control.* &= ~aux_reset;
        waitFor(engine.sys, control, aux_reset_done, 0);
    }
    // Asked for and given back: whoever used its registers last is done.
    arbitration.* |= arbitration_request;
    arbitration.* = arbitration.* & ~arbitration_request | arbitration_done;
    return true;
}

/// `register` waited for until its `bits` read `value`, 11 times a
/// microsecond's wait at the most, as long as the engine's reset takes.
fn waitFor(sys: *ExecBase, register: *volatile u32, bits: u32, value: u32) void {
    var tries: u32 = 0;
    while (tries < 11 and register.* & bits != value) : (tries += 1) {
        var never: exec.Waitable = .{};
        const list = [_]*exec.Waitable{&never};
        _ = sys.WaitForAny(&list, 1, 1);
    }
}

test "each line's registers are a step on" {
    const testing = @import("std").testing;
    try testing.expectEqual(@as(u32, 0x28d0), padMask(0));
    try testing.expectEqual(@as(u32, 0x28e0), padMask(4));
    try testing.expectEqual(@as(u32, 0x1f50), auxControl(0));
    try testing.expectEqual(@as(u32, 0x1f6c), auxControl(1));
}
