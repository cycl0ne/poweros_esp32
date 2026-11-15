// SPDX-License-Identifier: MPL-2.0
//! The ESP32-P4's MIPI-DSI host and its D-PHY, for the DSI board driver:
//! the link to the panel, its PLL, the commands that bring a panel up, and
//! the video mode that then streams the picture.
//!
//! The D-PHY has no block of its own: it is driven through the host's PHY
//! registers, and its PLL is set through a test interface - a register
//! address and a value clocked in by hand. The PLL multiplies the 20 MHz
//! reference by M/N to the lane rate - the nearest it makes to the rate
//! asked for, and none when that is not near (`pllFor`); its range
//! (hsfreqrange) is looked up by the rate it makes.
//!
//! Commands go in command mode, in low power, as generic packets: a DCS
//! command with no parameter or one is a short packet, anything longer a
//! long one whose payload is pushed into the FIFO a word at a time first.
//! Video mode then sends the picture in bursts, with the timings
//! converted from pixel clocks into the lane's byte clocks.
//!
//! It keeps no state: every call is register writes at `map.DSI_HOST`.
//! The sequence and the values follow ESP-IDF v6.1's mipi_dsi_hal.c and
//! esp_lcd_mipi_dsi_bus.c.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const systimer = sdk.hardware.systimer;

const host = sdk.hardware.map.DSI_HOST;

const pwr_up = host + 0x04;
const clkmgr_cfg = host + 0x08;
const dpi_vcid = host + 0x0C;
const dpi_color_coding = host + 0x10;
const dpi_cfg_pol = host + 0x14;
const pckhdl_cfg = host + 0x2C;
const mode_cfg = host + 0x34;
const vid_mode_cfg = host + 0x38;
const vid_pkt_size = host + 0x3C;
const vid_num_chunks = host + 0x40;
const vid_null_size = host + 0x44;
const vid_hsa_time = host + 0x48;
const vid_hbp_time = host + 0x4C;
const vid_hline_time = host + 0x50;
const vid_vsa_lines = host + 0x54;
const vid_vbp_lines = host + 0x58;
const vid_vfp_lines = host + 0x5C;
const vid_vactive_lines = host + 0x60;
const cmd_mode_cfg = host + 0x68;
const gen_hdr = host + 0x6C;
const gen_pld_data = host + 0x70;
const cmd_pkt_status = host + 0x74;
const to_cnt_cfg = host + 0x78;
const hs_rd_to_cnt = host + 0x7C;
const lp_rd_to_cnt = host + 0x80;
const hs_wr_to_cnt = host + 0x84;
const lp_wr_to_cnt = host + 0x88;
const bta_to_cnt = host + 0x8C;
const lpclk_ctrl = host + 0x94;
const phy_tmr_lpclk_cfg = host + 0x98;
const phy_tmr_cfg = host + 0x9C;
const phy_rstz = host + 0xA0;
const phy_if_cfg = host + 0xA4;
const phy_status = host + 0xB0;
const phy_tst_ctrl0 = host + 0xB4;
const phy_tst_ctrl1 = host + 0xB8;
const phy_tmr_rd_cfg = host + 0xF4;

/// PHY_RSTZ: out of shutdown, out of reset, the clock on, the PLL forced
/// on.
const phy_shutdownz: u32 = 1 << 0;
const phy_rstz_bit: u32 = 1 << 1;
const phy_enableclk: u32 = 1 << 2;
const phy_forcepll: u32 = 1 << 3;
/// PHY_STATUS: the PLL locked; the clock lane and data lanes 0 and 1 in
/// their stop state.
const phy_lock: u32 = 1 << 0;
const stopstate_clk: u32 = 1 << 2;
const stopstate_0: u32 = 1 << 4;
const stopstate_1: u32 = 1 << 7;
/// PHY_TST_CTRL0 and _1: the test interface's clock, its enable (the
/// byte clocked in is an address), and the byte.
const test_clk: u32 = 1 << 1;
const test_en: u32 = 1 << 16;

/// CMD_PKT_STATUS: the command FIFO empty or full, the payload FIFO empty
/// or full.
const gen_cmd_empty: u32 = 1 << 0;
const gen_cmd_full: u32 = 1 << 1;
const gen_pld_w_empty: u32 = 1 << 2;
const gen_pld_w_full: u32 = 1 << 3;

/// CMD_MODE_CFG: every kind of command sent in low power, an
/// acknowledgement asked for after each.
const cmd_mode_low_power: u32 = 0x010F_7F02;
/// VID_MODE_CFG: burst mode, an acknowledgement asked for after each
/// frame, low power allowed in every blanking period and for commands sent
/// while the picture streams - or, for a receiver that needs the link in
/// high speed throughout (an HDMI bridge), the first two alone.
const vid_mode_burst: u32 = 0xFF02;
const vid_mode_burst_high_speed: u32 = 0x4002;
/// PCKHDL_CFG: the end-of-transmission packet sent, ECC and CRC checked on
/// what comes back.
const pckhdl_eotp_ecc_crc: u32 = 0x19;
/// LPCLK_CTRL: the clock lane in high speed, the host free to drop it to
/// low power between transmissions.
const lpclk_auto: u32 = 0x3;
/// PHY_TMR_CFG and PHY_TMR_LPCLK_CFG: how long the data lanes and the
/// clock lane take from low power to high speed and back, in lane byte
/// clocks.
const lane_lp2hs = 104;
const lane_hs2lp = 50;
const clock_lp2hs = 128;
const clock_hs2lp = 46;

/// Data types of the generic and DCS packets sent here.
const dt_dcs_short_write_0 = 0x05;
const dt_dcs_short_write_1 = 0x15;
const dt_dcs_long_write = 0x39;

/// DPI_COLOR_CODING: RGB565 (16-bit, configuration 1), RGB888.
pub const coding_rgb565: u32 = 0;
pub const coding_rgb888: u32 = 5;

/// The reference the D-PHY's PLL multiplies.
pub const pll_reference_hz: u32 = 20_000_000;

/// How long the PHY's PLL and lanes, and a command's FIFO space, are
/// waited for.
const wait_us = 100_000;

/// The PHY's ranges: up to the rate in Mbit/s (inclusive), its
/// hsfreqrange.
const Range = struct { upto: u16, code: u8 };
const ranges = [_]Range{
    .{ .upto = 89, .code = 0x00 },   .{ .upto = 99, .code = 0x10 },   .{ .upto = 109, .code = 0x20 },
    .{ .upto = 129, .code = 0x01 },  .{ .upto = 139, .code = 0x11 },  .{ .upto = 149, .code = 0x21 },
    .{ .upto = 169, .code = 0x02 },  .{ .upto = 179, .code = 0x12 },  .{ .upto = 199, .code = 0x22 },
    .{ .upto = 219, .code = 0x03 },  .{ .upto = 239, .code = 0x13 },  .{ .upto = 249, .code = 0x23 },
    .{ .upto = 269, .code = 0x04 },  .{ .upto = 299, .code = 0x14 },  .{ .upto = 329, .code = 0x05 },
    .{ .upto = 359, .code = 0x15 },  .{ .upto = 399, .code = 0x25 },  .{ .upto = 449, .code = 0x06 },
    .{ .upto = 499, .code = 0x16 },  .{ .upto = 549, .code = 0x07 },  .{ .upto = 599, .code = 0x17 },
    .{ .upto = 649, .code = 0x08 },  .{ .upto = 699, .code = 0x18 },  .{ .upto = 749, .code = 0x09 },
    .{ .upto = 799, .code = 0x19 },  .{ .upto = 849, .code = 0x29 },  .{ .upto = 899, .code = 0x39 },
    .{ .upto = 949, .code = 0x0A },  .{ .upto = 999, .code = 0x1A },  .{ .upto = 1049, .code = 0x2A },
    .{ .upto = 1099, .code = 0x3A }, .{ .upto = 1149, .code = 0x0B }, .{ .upto = 1199, .code = 0x1B },
    .{ .upto = 1249, .code = 0x2B }, .{ .upto = 1299, .code = 0x3B }, .{ .upto = 1349, .code = 0x0C },
    .{ .upto = 1399, .code = 0x1C }, .{ .upto = 1449, .code = 0x2C }, .{ .upto = 1500, .code = 0x3C },
};

/// The lowest and highest lane rate the PHY takes, in Mbit/s.
const rate_min = 80;
const rate_max = 1500;

/// How far the rate the PLL makes may lie from the one asked for, in
/// hundredths of it. The PLL makes the multiples of 10 and of 13 1/3
/// Mbit/s, so from 246 Mbit/s up every rate has a setting inside this;
/// below, the rates furthest from a step have none and are refused. The
/// video timings are worked out from the rate the PLL makes, so a
/// difference this small costs nothing, and it is half the smallest
/// margin of the lanes over the picture a link here was seen to fail at.
const near_percent = 2;

/// The PLL's divider and multiplier for a lane rate, and the rate they
/// give in kbit/s.
pub const Pll = struct { n: u32, m: u32, kbps: u32 };

/// The N and M whose rate is nearest `mbps`: f_ref / N between 5 and
/// 40 MHz, M even - for each N the even M at or below the exact quotient
/// and the next one up. Of two rates as near, the lower: a receiver
/// takes a slow clock better than one past its rating. Of two settings
/// for one rate, the smaller N.
///
/// INPUTS:
/// - `mbps` - the lane rate asked for, in Mbit/s.
///
/// RESULT:
/// The setting; null for a rate outside the PHY's (`rate_min` to
/// `rate_max`), and for one the PLL makes nothing within `near_percent`
/// of.
pub fn pllFor(mbps: u32) ?Pll {
    if (mbps < rate_min or mbps > rate_max) return null;
    const ref_mhz = pll_reference_hz / 1_000_000;
    const asked = mbps * 1000;
    var best: ?Pll = null;
    var best_off: u32 = 0;
    var n: u32 = @max(1, ref_mhz / 40);
    while (n <= ref_mhz / 5) : (n += 1) {
        const below = (mbps * n / ref_mhz) & ~@as(u32, 1);
        for ([_]u32{ below, below + 2 }) |m| {
            if (m == 0) continue;
            const kbps = ref_mhz * m * 1000 / n;
            if (kbps < rate_min * 1000 or kbps > rate_max * 1000) continue;
            const off = if (kbps > asked) kbps - asked else asked - kbps;
            const nearer = if (best) |so_far| off < best_off or (off == best_off and kbps < so_far.kbps) else true;
            if (nearer) {
                best_off = off;
                best = .{ .n = n, .m = m, .kbps = kbps };
            }
        }
    }
    const found = best orelse return null;
    if (best_off * 100 > asked * near_percent) return null;
    return found;
}

fn hsFreqRange(mbps: u32) u8 {
    for (ranges) |range| {
        if (mbps <= range.upto) return range.code;
    }
    return ranges[ranges.len - 1].code;
}

/// One byte into the PHY's test register `address`.
fn testWrite(address: u8, value: u8) void {
    reg(phy_tst_ctrl0).* = 0;
    reg(phy_tst_ctrl1).* = test_en | address;
    reg(phy_tst_ctrl0).* = test_clk;
    reg(phy_tst_ctrl0).* = 0;
    reg(phy_tst_ctrl1).* = value;
    reg(phy_tst_ctrl0).* = test_clk;
    reg(phy_tst_ctrl0).* = 0;
}

/// The PHY up on `lanes` data lanes, its PLL set as `pll` says and its
/// range the one that rate lies in, and waited for until it has locked
/// and every lane rests in its stop state. The rate the PLL gives, in
/// kbit/s; 0 if the PHY never got there.
pub fn startPhy(lanes: u32, pll: Pll) u32 {
    reg(phy_if_cfg).* = (reg(phy_if_cfg).* & ~@as(u32, 0x3)) | (lanes - 1);
    reg(pwr_up).* = 1;
    reg(phy_rstz).* = phy_shutdownz;
    reg(phy_rstz).* = phy_shutdownz | phy_rstz_bit;
    reg(phy_rstz).* = phy_shutdownz | phy_rstz_bit | phy_enableclk;
    reg(phy_rstz).* = phy_shutdownz | phy_rstz_bit | phy_enableclk | phy_forcepll;

    testWrite(0x44, hsFreqRange(pll.kbps / 1000) << 1);
    testWrite(0x19, 0x30);
    testWrite(0x17, @intCast(pll.n - 1));
    testWrite(0x18, @intCast((pll.m - 1) & 0x1F));
    testWrite(0x18, @intCast(0x80 | (((pll.m - 1) >> 5) & 0x0F)));

    if (!waitFor(phy_status, phy_lock, 0)) return 0;
    var stopped = stopstate_clk | stopstate_0;
    if (lanes > 1) stopped |= stopstate_1;
    if (!waitFor(phy_status, stopped, 0)) return 0;
    return pll.kbps;
}

/// Command mode in low power, with the link's timings and its escape
/// clock for a lane rate of `mbps`; every timeout off.
pub fn commandMode(mbps: u32) void {
    reg(mode_cfg).* = 1;
    reg(lpclk_ctrl).* = lpclk_auto;
    reg(phy_tmr_cfg).* = lane_hs2lp << 16 | lane_lp2hs;
    reg(phy_tmr_lpclk_cfg).* = clock_hs2lp << 16 | clock_lp2hs;
    reg(pckhdl_cfg).* = pckhdl_eotp_ecc_crc;
    const byte_mhz = mbps / 8;
    const timeout_div = (byte_mhz + 5) / 10;
    const escape_div = @max(2, (byte_mhz + 9) / 18);
    reg(clkmgr_cfg).* = timeout_div << 8 | escape_div;
    reg(to_cnt_cfg).* = 0;
    reg(hs_rd_to_cnt).* = 0;
    reg(lp_rd_to_cnt).* = 0;
    reg(hs_wr_to_cnt).* = 0;
    reg(lp_wr_to_cnt).* = 0;
    reg(bta_to_cnt).* = 0;
    reg(phy_tmr_rd_cfg).* = 6000;
    reg(phy_if_cfg).* = (reg(phy_if_cfg).* & ~@as(u32, 0xFF00)) | 0x3F << 8;
    reg(cmd_mode_cfg).* = cmd_mode_low_power;
}

/// One DCS command with its parameters; false if the FIFO never had room.
pub fn dcsWrite(command: u8, params: []const u8) bool {
    if (params.len <= 1) {
        if (!waitFor(cmd_pkt_status, 0, gen_cmd_full)) return false;
        const param: u32 = if (params.len == 1) params[0] else 0;
        const dt: u32 = if (params.len == 1) dt_dcs_short_write_1 else dt_dcs_short_write_0;
        reg(gen_hdr).* = param << 16 | @as(u32, command) << 8 | dt;
        return true;
    }
    // The command and its parameters, four bytes to a word, low first.
    const count: u32 = @intCast(1 + params.len);
    var index: u32 = 0;
    while (index < count) {
        var word: u32 = 0;
        var byte_lane: u5 = 0;
        while (byte_lane < 4 and index < count) : ({
            byte_lane += 1;
            index += 1;
        }) {
            const byte: u32 = if (index == 0) command else params[index - 1];
            word |= byte << (byte_lane * 8);
        }
        if (!waitFor(cmd_pkt_status, 0, gen_pld_w_full)) return false;
        reg(gen_pld_data).* = word;
    }
    if (!waitFor(cmd_pkt_status, 0, gen_cmd_full)) return false;
    reg(gen_hdr).* = (count >> 8) << 16 | (count & 0xFF) << 8 | dt_dcs_long_write;
    return true;
}

/// Every command sent: both FIFOs empty.
pub fn commandsSent() bool {
    return waitFor(cmd_pkt_status, gen_cmd_empty | gen_pld_w_empty, 0);
}

/// What video mode needs: the picture's size and its timings, in pixel
/// clocks and lines.
pub const Video = struct {
    width: u32,
    height: u32,
    hsync: u32,
    hbp: u32,
    hfp: u32,
    vsync: u32,
    vbp: u32,
    vfp: u32,
    coding: u32,
    /// Whether the link may drop to low power in the blanking.
    low_power: bool = true,
};

/// `pixels` pixel clocks of `pixel_hz` in byte clocks of a lane running
/// at `kbps`, rounded.
fn byteClocks(pixels: u32, kbps: u32, pixel_hz: u32) u32 {
    const numerator = @as(u64, pixels) * kbps * 1000;
    const denominator = @as(u64, pixel_hz) * 8;
    return @intCast((numerator + denominator / 2) / denominator);
}

/// The picture's packets and timings, for a lane at `kbps` and a pixel
/// clock of `pixel_hz`. Still in command mode: `videoMode` starts it.
pub fn setVideo(video: Video, kbps: u32, pixel_hz: u32) void {
    reg(dpi_vcid).* = 0;
    reg(dpi_color_coding).* = video.coding;
    reg(dpi_cfg_pol).* = 0;
    reg(vid_mode_cfg).* = if (video.low_power) vid_mode_burst else vid_mode_burst_high_speed;
    reg(vid_pkt_size).* = video.width;
    reg(vid_num_chunks).* = 0;
    reg(vid_null_size).* = 0;
    const line = video.hsync + video.hbp + video.width + video.hfp;
    reg(vid_hsa_time).* = byteClocks(video.hsync, kbps, pixel_hz);
    reg(vid_hbp_time).* = byteClocks(video.hbp, kbps, pixel_hz);
    reg(vid_hline_time).* = byteClocks(line, kbps, pixel_hz);
    reg(vid_vsa_lines).* = video.vsync;
    reg(vid_vbp_lines).* = video.vbp;
    reg(vid_vfp_lines).* = video.vfp;
    reg(vid_vactive_lines).* = video.height;
}

/// From command mode to video mode, and back.
pub fn videoMode(on: bool) void {
    reg(mode_cfg).* = if (on) 0 else 1;
}

/// The PHY off.
pub fn stop() void {
    reg(mode_cfg).* = 1;
    reg(phy_rstz).* = 0;
    reg(pwr_up).* = 0;
}

/// Until the bits of `set` read 1 and those of `clear` 0 in `address`;
/// false if they do not within `wait_us`.
fn waitFor(address: usize, set: u32, clear: u32) bool {
    const since = systimer.uptimeUs();
    while (true) {
        const value = reg(address).*;
        if (value & set == set and value & clear == 0) return true;
        if (systimer.uptimeUs() - since > wait_us) return false;
    }
}

// --- tests (host: ./zig build test) -----------------------------------------
//
// What touches no register: the PLL's setting for a lane rate, the PHY's
// ranges and the byte clocks a line is.

const testing = @import("std").testing;
const monitor_modes = @import("monitor.zig").modes;

/// The rate nearest `mbps` of every setting there is - N 1 to 4, M even -
/// in kbit/s as `pllFor` counts them, the lower of two as near; found by
/// trying them all, with the distances in twelfths of a kbit/s so that a
/// third of one is exact.
fn nearestOfAll(mbps: u32) u32 {
    const asked: u64 = @as(u64, mbps) * 12_000;
    var best: u32 = 0;
    var best_off: u64 = ~@as(u64, 0);
    var n: u32 = 1;
    while (n <= 4) : (n += 1) {
        var m: u32 = 2;
        while (m <= 512) : (m += 2) {
            const rate: u64 = 240_000 * @as(u64, m) / n;
            if (rate < rate_min * 12_000 or rate > rate_max * 12_000) continue;
            const off = if (rate > asked) rate - asked else asked - rate;
            const kbps: u32 = @intCast(rate / 12);
            if (off < best_off or (off == best_off and kbps < best)) {
                best_off = off;
                best = kbps;
            }
        }
    }
    return best;
}

test "the PLL: every lane rate the PHY takes gets the nearest setting there is, or none when that is not near" {
    var exact: u32 = 0;
    var inexact: u32 = 0;
    var refused: u32 = 0;
    var mbps: u32 = rate_min;
    while (mbps <= rate_max) : (mbps += 1) {
        const nearest = nearestOfAll(mbps);
        const asked = mbps * 1000;
        const off = if (nearest > asked) nearest - asked else asked - nearest;
        const setting = pllFor(mbps) orelse {
            // Refused only where nothing is near.
            try testing.expect(off * 100 > asked * near_percent);
            refused += 1;
            continue;
        };
        try testing.expectEqual(nearest, setting.kbps);
        try testing.expect(off * 100 <= asked * near_percent);
        // A setting the PLL takes: M even and inside its nine bits, the
        // reference divided to 5 to 40 MHz, and the rate it names.
        try testing.expect(setting.m % 2 == 0 and setting.m >= 2 and setting.m <= 512);
        try testing.expect(pll_reference_hz / setting.n >= 5_000_000 and pll_reference_hz / setting.n <= 40_000_000);
        try testing.expectEqual(pll_reference_hz / 1000 * setting.m / setting.n, setting.kbps);
        if (setting.kbps == asked) exact += 1 else inexact += 1;
    }
    // How many of the 1,421 fall where: a change of the tolerance shows
    // here.
    try testing.expectEqual(@as(u32, 143), exact);
    try testing.expectEqual(@as(u32, 1242), inexact);
    try testing.expectEqual(@as(u32, 36), refused);
}

test "the PLL: the rates the boards' panels and the monitor's modes run at keep their settings" {
    // The two panels', the one a board's list gives its HDMI port, and
    // the three the monitor's modes come with.
    try testing.expectEqual(Pll{ .n = 2, .m = 50, .kbps = 500_000 }, pllFor(500).?);
    try testing.expectEqual(Pll{ .n = 1, .m = 50, .kbps = 1_000_000 }, pllFor(1000).?);
    try testing.expectEqual(Pll{ .n = 4, .m = 130, .kbps = 650_000 }, pllFor(650).?);
    try testing.expectEqual(Pll{ .n = 1, .m = 48, .kbps = 960_000 }, pllFor(960).?);
    try testing.expectEqual(Pll{ .n = 1, .m = 64, .kbps = 1_280_000 }, pllFor(1280).?);
    try testing.expectEqual(Pll{ .n = 1, .m = 72, .kbps = 1_440_000 }, pllFor(1440).?);
    // Whatever modes the monitor's list holds: each gets its rate exactly.
    for (monitor_modes) |mode| try testing.expectEqual(mode.lane_mbps * 1000, pllFor(mode.lane_mbps).?.kbps);
}

test "the PLL: between two settings the nearer, midway the lower, and none outside the PHY's rates" {
    // Above and below what was asked, whichever is nearer.
    try testing.expectEqual(@as(u32, 90_000), pllFor(89).?.kbps);
    try testing.expectEqual(Pll{ .n = 1, .m = 6, .kbps = 120_000 }, pllFor(119).?);
    try testing.expectEqual(Pll{ .n = 1, .m = 50, .kbps = 1_000_000 }, pllFor(999).?);
    // A third of the reference: 13 1/3 Mbit/s a step.
    try testing.expectEqual(Pll{ .n = 3, .m = 14, .kbps = 93_333 }, pllFor(93).?);
    try testing.expectEqual(Pll{ .n = 3, .m = 224, .kbps = 1_493_333 }, pllFor(1496).?);
    // Midway between two: the lower.
    try testing.expectEqual(@as(u32, 270_000), pllFor(275).?.kbps);
    try testing.expectEqual(@as(u32, 280_000), pllFor(285).?.kbps);
    // Further than the tolerance from any: none. From 246 up there is
    // always one.
    try testing.expect(pllFor(85) == null);
    try testing.expect(pllFor(115) == null);
    try testing.expect(pllFor(245) == null);
    try testing.expect(pllFor(246) != null);
    // Outside the PHY's rates nothing, and nothing traps.
    try testing.expect(pllFor(0) == null);
    try testing.expect(pllFor(rate_min - 1) == null);
    try testing.expect(pllFor(rate_max + 1) == null);
    try testing.expect(pllFor(~@as(u32, 0)) == null);
    try testing.expectEqual(@as(u32, 80_000), pllFor(rate_min).?.kbps);
    try testing.expectEqual(@as(u32, 1_500_000), pllFor(rate_max).?.kbps);
}

test "the PHY's ranges: each rate in the one that holds it" {
    // The table rises, ends at the PHY's highest rate, and every code
    // fits the register it goes into shifted by one.
    for (ranges[1..], ranges[0 .. ranges.len - 1]) |range, before| try testing.expect(range.upto > before.upto);
    try testing.expectEqual(@as(u16, rate_max), ranges[ranges.len - 1].upto);
    for (ranges) |range| try testing.expect(range.code < 0x80);
    try testing.expectEqual(@as(u8, 0x00), hsFreqRange(80));
    try testing.expectEqual(@as(u8, 0x00), hsFreqRange(89));
    try testing.expectEqual(@as(u8, 0x10), hsFreqRange(90));
    try testing.expectEqual(@as(u8, 0x10), hsFreqRange(93));
    try testing.expectEqual(@as(u8, 0x07), hsFreqRange(500));
    try testing.expectEqual(@as(u8, 0x18), hsFreqRange(650));
    try testing.expectEqual(@as(u8, 0x2A), hsFreqRange(1000));
    try testing.expectEqual(@as(u8, 0x1A), hsFreqRange(960));
    try testing.expectEqual(@as(u8, 0x3B), hsFreqRange(1280));
    try testing.expectEqual(@as(u8, 0x2C), hsFreqRange(1440));
    try testing.expectEqual(@as(u8, 0x3C), hsFreqRange(1500));
}

test "a line in the lane's byte clocks: to the nearest, and whole for the HDMI modes' rates" {
    // The P4-PC's panel: 514 pixel clocks of 16 MHz at 500 Mbit/s are
    // 2007.8 byte clocks, and its back porch of 20 is 78.1.
    try testing.expectEqual(@as(u32, 2008), byteClocks(514, 500_000, 16_000_000));
    try testing.expectEqual(@as(u32, 78), byteClocks(20, 500_000, 16_000_000));
    // 800x600 over HDMI: 1056 clocks of 40 MHz at 650 Mbit/s, whole.
    try testing.expectEqual(@as(u32, 2145), byteClocks(1056, 650_000, 40_000_000));
    // The monitor's modes: a line of each is whole byte clocks.
    for (monitor_modes) |mode| {
        const line = mode.width + mode.hsync + mode.hbp + mode.hfp;
        const bits = @as(u64, line) * mode.lane_mbps * 1_000_000;
        try testing.expectEqual(@as(u64, 0), bits % (@as(u64, mode.pixel_hz) * 8));
        try testing.expectEqual(bits / (@as(u64, mode.pixel_hz) * 8), byteClocks(line, mode.lane_mbps * 1000, mode.pixel_hz));
    }
}
