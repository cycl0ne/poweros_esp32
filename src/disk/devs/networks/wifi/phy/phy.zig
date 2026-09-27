// SPDX-License-Identifier: MIT
//! The radio's power, clocks and PHY: what has to be true before the
//! radio's libraries touch the MAC, and the PHY library's calibration.
//!
//! **Power** (`powerOn`, once, before the libraries start): the Wi-Fi
//! block's clocks on, the Wi-Fi power domain forced on in RTC_CNTL, the
//! modem's blocks reset once as they power up, and the domain's isolation
//! lifted.
//!
//! **The PHY** (`enable`, whenever the libraries start the radio): the
//! modem's common clocks and the PHY's own, then the PHY library. The
//! first time it calibrates in full from the init data
//! (`register_chipv7_phy`) into a calibration block it keeps, told to
//! leave the USB port's clock running (the console is on it); after that
//! it only wakes (`phy_wakeup_init`). Once a second the PLL is tracked
//! against the temperature (`phy_param_track_tot`), on one of the
//! adapter's timers.
//!
//! The clock and reset registers are shared with the random number
//! generator's clock, so every change is a read-modify-write under
//! Disable.

const sdk = @import("sdk");
const map = sdk.hardware.map;
const _osi = @import("../osi/_osi.zig");
const osi_timer = @import("../osi/timer.zig");
const efuse = @import("efuse.zig");
const init_data_file = @import("init_data.zig");

// --- registers ------------------------------------------------------------

/// RTC_CNTL_DIG_PWC and _DIG_ISO: the Wi-Fi domain's power and isolation.
const dig_pwc = map.RTC_CNTL + 0x90;
const wifi_force_pd: u32 = 1 << 17;
const dig_iso = map.RTC_CNTL + 0x94;
const wifi_force_iso: u32 = 1 << 28;
/// RTC_CNTL_STORE1: the slow clock's calibration, as the boot ROM left it.
const slow_clock_cal = map.RTC_CNTL + 0x54;

/// SYSCON_WIFI_CLK_EN and _WIFI_RST_EN.
const wifi_clk_en = map.SYSCON + 0x14;
const wifi_rst_en = map.SYSCON + 0x18;
/// Every clock of the Wi-Fi block (SYSTEM_WIFI_CLK_EN): the MAC's among
/// them, which nothing else turns on. Without them the MAC does not
/// answer, and the libraries wait for it for good.
const wifi_clocks: u32 = 0x00FB_9FCF;
/// The Wi-Fi and Bluetooth blocks' common clocks.
const common_clocks: u32 = 0x0078_078F;
/// The PHY's calibration clock, and the random number generator's.
const phy_clock: u32 = 0x0040_0000;
const rng_clock: u32 = 1 << 15;
/// The modem's blocks reset as the domain powers up: the baseband, the
/// front end, the MAC, and Bluetooth's.
const reset_at_power_up: u32 = 0x2A1F;
/// The MAC alone.
const mac_reset: u32 = 1 << 2;

fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}

fn change(address: usize, set: u32, clear: u32) void {
    const sys = _osi.get().sys;
    sys.Disable();
    defer sys.Enable();
    reg(address).* = (reg(address).* & ~clear) | set;
}

// --- the PHY library --------------------------------------------------------

/// PHY_RF_CAL_PARTIAL, _NONE, _FULL.
const cal_full: u32 = 2;
/// ESP_CAL_DATA_CHECK_FAIL: the calibration data given was not usable.
const cal_data_check_fail: i32 = 1;

/// esp_phy_calibration_data_t: a version, the MAC, and the PHY's own.
pub const CalData = extern struct {
    version: [4]u8,
    mac: [6]u8,
    opaque_data: [1894]u8,
};

extern fn register_chipv7_phy(init: *const init_data_file.InitData, cal: *CalData, mode: u32) callconv(.c) i32;
extern fn phy_wakeup_init() callconv(.c) void;
extern fn phy_close_rf() callconv(.c) void;
extern fn phy_xpd_tsens() callconv(.c) void;
extern fn phy_wait_freq_hw_hop_done() callconv(.c) void;
extern fn phy_param_track_tot(wifi: bool, ble: bool) callconv(.c) void;
extern fn phy_wifi_enable_set(on: u8) callconv(.c) void;
extern fn get_phy_version_str() callconv(.c) [*:0]const u8;
extern fn phy_bbpll_en_usb(on: bool) callconv(.c) void;

/// How often the PLL is tracked.
const track_period_ms = 1000;

pub const Phy = struct {
    /// The calibration block, kept after the first calibration.
    cal: ?*CalData = null,
    calibrated: bool = false,
    enabled: bool = false,
    powered: bool = false,
    /// The PLL's timer: an ETSTimer like the libraries' own.
    track: osi_timer.EtsTimer = .{ .next = null, .expire = 0, .period = 0, .func = null, .arg = null },
};

/// The Wi-Fi domain powered, once.
pub fn powerOn(phy: *Phy) void {
    if (phy.powered) return;
    change(wifi_clk_en, wifi_clocks, 0);
    change(dig_pwc, 0, wifi_force_pd);
    // 10 µs for the domain to come up.
    const until = _osi.now() + 10;
    while (_osi.now() < until) {}
    change(wifi_clk_en, common_clocks, 0);
    change(wifi_rst_en, reset_at_power_up, 0);
    change(wifi_rst_en, 0, reset_at_power_up);
    change(dig_iso, 0, wifi_force_iso);
    change(wifi_clk_en, 0, common_clocks);
    phy.powered = true;
}

/// The PLL tracked, on the timer task, while the PHY is on.
fn trackPll(data: ?*anyopaque) callconv(.c) void {
    const phy: *Phy = @ptrCast(@alignCast(data.?));
    if (phy.enabled) phy_param_track_tot(true, false);
}

/// `_phy_enable`: the clocks on, the PHY calibrated or woken, and the PLL
/// tracked from now on.
pub fn enable(phy: *Phy) void {
    if (phy.enabled) return;
    change(wifi_clk_en, common_clocks | phy_clock | rng_clock, 0);
    if (!phy.calibrated) {
        const state = _osi.get();
        if (state.trace) sdk.exec.kprintf(state.sys, "wifi: phy %s\n", .{get_phy_version_str()});
        const memory = _osi.alloc(@sizeOf(CalData), true, true) orelse return;
        const cal: *CalData = @ptrCast(@alignCast(memory));
        cal.mac = efuse.stationAddress();
        // The PHY's calibration would stop the BBPLL's clock to the USB
        // port, which the console and JTAG run on: it is told to keep it.
        phy_bbpll_en_usb(true);
        _ = register_chipv7_phy(&init_data_file.init_data, cal, cal_full);
        phy.cal = cal;
        phy.calibrated = true;
    } else {
        phy_wakeup_init();
    }
    osi_timer.timerSetfn(&phy.track, @ptrCast(@constCast(&trackPll)), phy);
    osi_timer.timerArm(&phy.track, track_period_ms, true);
    change(wifi_clk_en, 0, phy_clock);
    phy.enabled = true;
    trackPll(phy);
    phy_wifi_enable_set(1);
}

/// `_phy_disable`: the radio and its temperature sensor off, and the
/// common clocks with them. The random number generator's stays on.
pub fn disable(phy: *Phy) void {
    if (!phy.enabled) return;
    phy_wifi_enable_set(0);
    osi_timer.timerDisarm(&phy.track);
    phy_close_rf();
    phy_xpd_tsens();
    phy_wait_freq_hw_hop_done();
    change(wifi_clk_en, 0, common_clocks & ~rng_clock);
    phy.enabled = false;
}

/// `_wifi_reset_mac`.
pub fn resetMac() void {
    change(wifi_rst_en, mac_reset, 0);
    change(wifi_rst_en, 0, mac_reset);
}

/// `_slowclk_cal_get`.
pub fn slowClockCalibration() u32 {
    return reg(slow_clock_cal).*;
}
