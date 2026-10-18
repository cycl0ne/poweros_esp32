// SPDX-License-Identifier: MPL-2.0
//! timer.device's alarms on a machine under SBI firmware: the kernel's
//! alarms 0 (the micro timer, one shot) and 1 (VBLANK, periodic), which
//! it keeps beside its tick on the hart's one comparator and raises as
//! interrupts of their own (sdk.hardware.systimer). The E-clock is the
//! `time` counter in microseconds, whatever the timebase.

const sdk = @import("sdk");
const systimer = sdk.hardware.systimer;
const intbits = sdk.hardware.intbits;

pub const eclock_hz: u32 = 1_000_000;
pub const micro_source: u32 = intbits.INTB_ALARM0;
pub const vblank_source: u32 = intbits.INTB_ALARM1;
pub const parked: u64 = systimer.never;

const micro = 0;
const vblank = 1;

/// VBLANK's period, from `setUp` until `start`.
var vblank_ticks: u64 = 0;

/// The E-clock now.
pub fn now() u64 {
    return systimer.uptimeUs();
}

pub fn uptimeUs() u64 {
    return systimer.uptimeUs();
}

/// E-clock ticks, microseconds, in the timebase's units.
fn toTime(ticks: u64) u64 {
    if (ticks == parked) return systimer.never;
    return ticks * (systimer.timebase_hz / 1_000_000);
}

/// The micro timer set to `ticks`; one already past comes due at once.
pub fn armMicro(ticks: u64) void {
    systimer.setAlarm(micro, toTime(ticks), 0);
}

/// Both alarms parked until their servers are in place, VBLANK's period
/// kept for `start`.
pub fn setUp(vblank_period: u32) void {
    vblank_ticks = vblank_period;
    systimer.setAlarm(micro, systimer.never, 0);
    systimer.setAlarm(vblank, systimer.never, 0);
}

/// VBLANK running, its server in place.
pub fn start() void {
    systimer.setAlarm(vblank, systimer.read() + toTime(vblank_ticks), toTime(vblank_ticks));
}

/// Both alarms parked, for the expunge.
pub fn stop() void {
    systimer.setAlarm(micro, systimer.never, 0);
    systimer.setAlarm(vblank, systimer.never, 0);
}

pub fn takeMicro() bool {
    return systimer.takeAlarm(micro);
}

pub fn takeVblank() bool {
    return systimer.takeAlarm(vblank);
}
