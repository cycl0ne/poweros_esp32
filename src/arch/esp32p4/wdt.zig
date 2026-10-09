// SPDX-License-Identifier: MPL-2.0
//! The watchdogs the ROM leaves running, stopped: first thing at boot,
//! or the chip resets under the kernel within a second.

const hardware = @import("sdk").hardware;
const reg = hardware.mmio.reg;
const wdt = hardware.wdt;

pub fn disableAll() void {
    reg(wdt.LP_WDT_WPROTECT).* = wdt.WDT_KEY;
    reg(wdt.LP_WDT_CONFIG0).* = 0;
    reg(wdt.LP_WDT_WPROTECT).* = 0;

    for ([_]usize{ wdt.timgBase(0), wdt.timgBase(1) }) |base| {
        reg(base + wdt.TIMG_WDT_WPROTECT).* = wdt.WDT_KEY;
        reg(base + wdt.TIMG_WDT_CONFIG0).* = 0;
        reg(base + wdt.TIMG_WDT_WPROTECT).* = 0;
    }

    // The super watchdog cannot be turned off, but it can feed itself.
    reg(wdt.LP_WDT_SWD_WPROTECT).* = wdt.SWD_KEY;
    reg(wdt.LP_WDT_SWD_CONFIG).* |= wdt.SWD_AUTO_FEED_EN;
    reg(wdt.LP_WDT_SWD_WPROTECT).* = 0;
}
