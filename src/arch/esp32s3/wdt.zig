// SPDX-License-Identifier: MPL-2.0
//! The watchdogs off at boot. The boot ROM leaves the RTC and TIMG0
//! watchdogs armed in flash-boot mode, so they reset the chip after a few
//! seconds unless they are stopped: disableAll, kmain's first step. The
//! watchdog programs use later is watchdog.resource's; the chip reset
//! itself is exec's ColdReboot.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const wdt = hardware.wdt;

pub fn disableAll() linksection(".iram.text") void {
    @setRuntimeSafety(false);
    reg(wdt.RTC_WDT_WPROTECT).* = wdt.WDT_KEY;
    reg(wdt.RTC_WDT_CONFIG0).* = 0;
    reg(wdt.RTC_WDT_WPROTECT).* = 0;

    for ([_]usize{ wdt.timgBase(0), wdt.timgBase(1) }) |base| {
        reg(base + wdt.TIMG_WDT_WPROTECT).* = wdt.WDT_KEY;
        reg(base + wdt.TIMG_WDT_CONFIG0).* = 0;
        reg(base + wdt.TIMG_WDT_WPROTECT).* = 0;
    }

    // The super watchdog cannot be turned off, but it can feed itself.
    reg(wdt.RTC_SWD_WPROTECT).* = wdt.SWD_KEY;
    reg(wdt.RTC_SWD_CONF).* |= wdt.SWD_AUTO_FEED_EN;
    reg(wdt.RTC_SWD_WPROTECT).* = 0;
}
