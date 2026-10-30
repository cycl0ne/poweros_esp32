// SPDX-License-Identifier: MPL-2.0
//! A fan on one of the RP1's PWM channels, as the CM5 IO board's fan
//! connector and the Pi 5's have it: PWM1's channel 3, out on the RP1's
//! GPIO45, a period of 41566 ns (24 kHz), inverted - the board inverts it
//! again - and the fan's speed counted by the RP1 into a register of the
//! PWM block, in turns a minute. That is Linux's device tree for the CM5
//! (cooling_fan), and this does what its drivers do with it (pwm-rp1.c,
//! clk-rp1.c, pinctrl-rp1.c, pwm-fan.c):
//!
//! - the PWM block's clock from the RP1's 50 MHz crystal, undivided, and
//!   on;
//! - the channel trailing-edge modulated and inverted, its range the
//!   period in ticks of that clock and its duty the speed asked, switched
//!   on, and the block told to take the new values;
//! - the pin given to the PWM block, its pad an output with its pull-down.
//!
//! A speed is 0 to 255, as pwm-fan has it: the share of the period the
//! fan is driven. The pins there is code for are the ones a fan has been
//! seen on: GPIO45.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;

/// Where a pin's PWM is: the block, its clock's control register in the
/// RP1's clock block, the channel, and the pin's function that is that
/// channel.
const Route = struct {
    gpio: u8,
    pwm: usize,
    clock_ctrl: usize,
    channel: u2,
    function: u32,
};

const routes = [_]Route{
    .{ .gpio = 45, .pwm = 0x9_C000, .clock_ctrl = 0x84, .channel = 3, .function = 0 },
};

/// The RP1's clock block, from its peripherals; a clock's divider follows
/// its control register, the integer part first.
const CLOCKS: usize = 0x1_8000;
const CLK_DIV_INT: usize = 0x4;
const CLK_DIV_FRAC: usize = 0x8;
const CLK_CTRL_ENABLE: u32 = 1 << 11;
const CLK_CTRL_AUXSRC_MASK: u32 = 0x1F << 5;
/// The PWM clocks' source that is the crystal.
const AUXSRC_XOSC: u32 = 2 << 5;

/// A PWM block's registers.
const PWM_GLOBAL_CTRL: usize = 0x000;
const SET_UPDATE: u32 = 1 << 31;
fn channelCtrl(channel: u2) usize {
    return 0x014 + @as(usize, channel) * 16;
}
fn channelRange(channel: u2) usize {
    return 0x018 + @as(usize, channel) * 16;
}
fn channelDuty(channel: u2) usize {
    return 0x020 + @as(usize, channel) * 16;
}
/// Trailing-edge modulation, its FIFO's pop masked: what a channel is set
/// to before it is used.
const CHANNEL_DEFAULT: u32 = (1 << 8) | (1 << 0);
const CHANNEL_INVERTED: u32 = 1 << 3;
/// Where the RP1 keeps the fan's turns a minute (cooling_fan's
/// rpm-offset).
const RPM: usize = 0x3C;

/// The RP1's GPIO: each bank's control registers (two words a pin, the
/// control second) and its pads (a word a pin), from the peripherals.
const IO_BANKS: usize = 0xD_0000;
const PADS: usize = 0xF_0000;
const Bank = struct { first: u8, count: u8, io: usize, pads: usize };
const banks = [_]Bank{
    .{ .first = 0, .count = 28, .io = 0x0000, .pads = 0x0004 },
    .{ .first = 28, .count = 6, .io = 0x4000, .pads = 0x4004 },
    .{ .first = 34, .count = 20, .io = 0x8000, .pads = 0x8004 },
};
const GPIO_CTRL: usize = 0x4;
const CTRL_FUNCSEL_MASK: u32 = 0x1F;
/// The output and its enable from the function, not overridden.
const CTRL_OVERRIDES_MASK: u32 = 0xF << 12;
const PAD_PULL_MASK: u32 = 3 << 2;
const PAD_PULL_DOWN: u32 = 1 << 2;
const PAD_IN_ENABLE: u32 = 1 << 6;
const PAD_OUT_DISABLE: u32 = 1 << 7;

/// The period, and the PWM clock's tick, in nanoseconds.
const period_ns: u32 = 41_566;
const tick_ns: u32 = 20;
/// The period in ticks: the channel's range.
pub const range_ticks: u32 = (period_ns + tick_ns / 2) / tick_ns;

/// The fastest a fan turns.
pub const full: u8 = 255;

/// The duty for `speed`, in ticks: pwm-fan's share of the period, rounded
/// up, then to the nearest tick, as pwm-rp1 rounds it.
pub fn dutyTicks(speed: u8) u32 {
    const duty_ns = (@as(u32, speed) * (period_ns - 1) + full - 1) / full;
    return (duty_ns + tick_ns / 2) / tick_ns;
}

fn routeOf(gpio: u8) ?Route {
    for (routes) |route| {
        if (route.gpio == gpio) return route;
    }
    return null;
}

/// The fan on `gpio` of the RP1 whose peripherals are at `base` turning at
/// `speed`: false for a pin there is no code for.
pub fn start(base: usize, gpio: u8, speed: u8) bool {
    const route = routeOf(gpio) orelse return false;
    const clock = base + CLOCKS + route.clock_ctrl;
    reg(clock + CLK_DIV_INT).* = 1;
    reg(clock + CLK_DIV_FRAC).* = 0;
    reg(clock).* = (reg(clock).* & ~CLK_CTRL_AUXSRC_MASK) | AUXSRC_XOSC;
    reg(clock).* |= CLK_CTRL_ENABLE;

    const pwm = base + route.pwm;
    reg(pwm + channelCtrl(route.channel)).* = CHANNEL_DEFAULT;
    reg(pwm + channelDuty(route.channel)).* = dutyTicks(speed);
    reg(pwm + channelRange(route.channel)).* = range_ticks;
    reg(pwm + channelCtrl(route.channel)).* |= CHANNEL_INVERTED;
    reg(pwm + PWM_GLOBAL_CTRL).* |= @as(u32, 1) << route.channel;
    reg(pwm + PWM_GLOBAL_CTRL).* |= SET_UPDATE;

    for (banks) |bank| {
        if (gpio < bank.first or gpio >= bank.first + bank.count) continue;
        const index: usize = gpio - bank.first;
        const pad = base + PADS + bank.pads + index * 4;
        reg(pad).* = (reg(pad).* & ~(PAD_PULL_MASK | PAD_OUT_DISABLE)) | PAD_IN_ENABLE | PAD_PULL_DOWN;
        const ctrl = base + IO_BANKS + bank.io + index * 8 + GPIO_CTRL;
        reg(ctrl).* = (reg(ctrl).* & ~(CTRL_FUNCSEL_MASK | CTRL_OVERRIDES_MASK)) | route.function;
    }
    return true;
}

/// The fan on `gpio` turning at `speed`.
pub fn set(base: usize, gpio: u8, speed: u8) void {
    const route = routeOf(gpio) orelse return;
    const pwm = base + route.pwm;
    reg(pwm + channelDuty(route.channel)).* = dutyTicks(speed);
    reg(pwm + PWM_GLOBAL_CTRL).* |= SET_UPDATE;
}

/// The fan's turns a minute, as the RP1 counts them; 0 standing.
pub fn rpm(base: usize, gpio: u8) u32 {
    const route = routeOf(gpio) orelse return 0;
    return reg(base + route.pwm + RPM).*;
}
