// SPDX-License-Identifier: MPL-2.0
//! TIMG0's watchdog (MWDT), which watchdog.resource runs for programs:
//! arm it for a time and an action, feed it, disarm it. After ESP-IDF's
//! mwdt_ll.h. The ESP32-S3's takes a setting as it is written; the
//! ESP32-P4's once CONF_UPDATE_EN says so.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const wdt = hardware.wdt;

const timg0 = wdt.timgBase(0);

pub const ticks_per_ms = 2;
/// CLK_PRESCALE: the watchdog's clock divided down to a tick every 0.5 ms
/// (ESP-IDF's default).
const prescale: u32 = wdt.TIMG_WDT_CLOCK_HZ / (1000 * ticks_per_ms);
/// What makes a written setting count.
const conf_update: u32 = switch (hardware.chip) {
    .esp32s3 => 0,
    .esp32p4 => wdt.WDT_CONF_UPDATE_EN,
};

/// What stage 0 does when its time is up.
pub const Action = enum(u2) { interrupt = 1, reset_cpu = 2, reset_system = 3 };

/// Arm the watchdog: after `ticks` (0.5 ms each) without a feed, stage 0
/// does `action`. The other stages stay off.
pub fn arm(ticks: u32, action: Action) void {
    reg(timg0 + wdt.TIMG_WDT_WPROTECT).* = wdt.WDT_KEY;
    reg(timg0 + wdt.TIMG_WDT_CONFIG0).* = 0;
    reg(timg0 + wdt.TIMG_WDT_CONFIG1).* = prescale << wdt.WDT_CLK_PRESCALE_SHIFT;
    reg(timg0 + wdt.TIMG_WDT_CONFIG2).* = ticks;
    const cpu_reset = if (action == .reset_cpu) wdt.WDT_PROCPU_RESET_EN else 0;
    reg(timg0 + wdt.TIMG_WDT_CONFIG0).* = wdt.WDT_EN | @as(u32, @intFromEnum(action)) << wdt.WDT_STG0_SHIFT | wdt.WDT_RESET_LENGTHS | cpu_reset | conf_update;
    reg(timg0 + wdt.TIMG_WDT_FEED).* = 1;
    reg(timg0 + wdt.TIMG_WDT_WPROTECT).* = 0;
}

/// Start the armed time over.
pub fn feed() void {
    reg(timg0 + wdt.TIMG_WDT_WPROTECT).* = wdt.WDT_KEY;
    reg(timg0 + wdt.TIMG_WDT_FEED).* = 1;
    reg(timg0 + wdt.TIMG_WDT_WPROTECT).* = 0;
}

pub fn disarm() void {
    reg(timg0 + wdt.TIMG_WDT_WPROTECT).* = wdt.WDT_KEY;
    reg(timg0 + wdt.TIMG_WDT_CONFIG0).* = conf_update;
    reg(timg0 + wdt.TIMG_WDT_WPROTECT).* = 0;
}
