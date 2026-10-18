// SPDX-License-Identifier: MPL-2.0
//! timer.device's alarms on the ESP32s: SYSTIMER's alarm 0, the micro
//! timer in one-shot mode, and alarm 1, VBLANK in periodic mode, both on
//! unit 0 - the E-clock, 16 MHz from boot - each with an interrupt source
//! of its own.

const sdk = @import("sdk");
const systimer = sdk.hardware.systimer;
const reg = sdk.hardware.mmio.reg;

/// The E-clock's rate: SYSTIMER's.
pub const eclock_hz: u32 = systimer.SYSTIMER_HZ;
/// ETS_SYSTIMER_TARGET0_INTR_SOURCE (57) and TARGET1 (58).
pub const micro_source: u32 = sdk.hardware.intbits.INTB_SYSTIMER_TARGET0;
pub const vblank_source: u32 = sdk.hardware.intbits.INTB_SYSTIMER_TARGET1;
/// Where the micro timer waits while nothing does.
pub const parked: u64 = (1 << 52) - 1;
/// How far ahead a micro timer target that is already past gets moved.
const min_ahead_ticks: u64 = 2 * (eclock_hz / 1_000_000);

/// The E-clock now.
pub fn now() u64 {
    return systimer.readUnit0();
}

pub fn uptimeUs() u64 {
    return systimer.uptimeUs();
}

/// Set the micro timer to `ticks`. An alarm that is already past doesn't
/// fire on the chip, so it moves to just after now (as ESP-IDF does).
pub fn armMicro(ticks: u64) void {
    var target = ticks;
    while (true) {
        reg(systimer.TARGET0_HI).* = @as(u32, @truncate(target >> 32)) & systimer.VALUE_HI_MASK;
        reg(systimer.TARGET0_LO).* = @truncate(target);
        reg(systimer.COMP0_LOAD).* = 1;
        if (target > systimer.readUnit0() or reg(systimer.INT_RAW).* & systimer.INT_TARGET0 != 0) return;
        target = systimer.readUnit0() + min_ahead_ticks;
    }
}

/// Both alarms quiet until their servers are in place - an interrupt
/// raised before its source is routed is lost, and the line stays high
/// with no new edge - the micro timer parked, VBLANK running every
/// `vblank_period` ticks.
pub fn setUp(vblank_period: u32) void {
    reg(systimer.INT_ENA).* &= ~(systimer.INT_TARGET0 | systimer.INT_TARGET1);
    reg(systimer.TARGET0_CONF).* = 0; // one-shot, on unit 0
    armMicro(parked);
    reg(systimer.TARGET1_CONF).* = systimer.TARGET_PERIOD_MODE | vblank_period; // periodic, on unit 0
    reg(systimer.COMP1_LOAD).* = 1;
    reg(systimer.CONF).* |= systimer.CONF_TARGET0_WORK_EN | systimer.CONF_TARGET1_WORK_EN;
}

/// Both alarms' interrupts on, their servers in place.
pub fn start() void {
    reg(systimer.INT_CLR).* = systimer.INT_TARGET0 | systimer.INT_TARGET1;
    reg(systimer.INT_ENA).* |= systimer.INT_TARGET0 | systimer.INT_TARGET1;
}

/// Both alarms stopped, for the expunge.
pub fn stop() void {
    reg(systimer.INT_ENA).* &= ~(systimer.INT_TARGET0 | systimer.INT_TARGET1);
    reg(systimer.CONF).* &= ~(systimer.CONF_TARGET0_WORK_EN | systimer.CONF_TARGET1_WORK_EN);
    reg(systimer.INT_CLR).* = systimer.INT_TARGET0 | systimer.INT_TARGET1;
}

/// Whether the micro timer raised its interrupt, cleared.
pub fn takeMicro() bool {
    if (reg(systimer.INT_ST).* & systimer.INT_TARGET0 == 0) return false;
    reg(systimer.INT_CLR).* = systimer.INT_TARGET0;
    return true;
}

/// Whether VBLANK raised its interrupt, cleared.
pub fn takeVblank() bool {
    if (reg(systimer.INT_ST).* & systimer.INT_TARGET1 == 0) return false;
    reg(systimer.INT_CLR).* = systimer.INT_TARGET1;
    return true;
}
