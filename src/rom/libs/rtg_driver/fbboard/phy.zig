// SPDX-License-Identifier: MPL-2.0
//! The JH7110 HDMI transmitter's PHY, Innosilicon's: what its two PLLs
//! are set to for each pixel clock it makes. Nothing here touches the
//! chip, so the host tests hold it.
//!
//! The pre-PLL makes the pixel clock and the TMDS clock (the same, with
//! eight bits a colour) from the 24 MHz reference: a VCO of 24 MHz over
//! `prediv` times `fbdiv` (and a fraction of 2^24ths where `frac` is
//! not 0), divided down by the TMDS dividers a, b, c and the pixel clock
//! dividers a to d. The post-PLL makes the serializer's clock from the
//! TMDS clock. The display controller takes its pixel clock from the
//! pre-PLL too, so a mode is drivable when its pixel clock is one of
//! these, to the kHz.
//!
//! The values are StarFive's (pre_pll_cfg_table and post_pll_cfg_table
//! in their Linux driver, inno_hdmi.c), which drives a monitor at any of
//! these clocks up to 297 MHz; at 148.5 MHz they are what U-Boot sets
//! for 1080p.

/// The pre-PLL for one pixel clock.
pub const Pll = struct {
    pixel_khz: u32,
    prediv: u8,
    fbdiv: u16,
    tmds_a: u2,
    tmds_b: u2,
    tmds_c: u2,
    pclk_a: u5,
    pclk_b: u2,
    pclk_c: u2,
    pclk_d: u5,
    frac: u24 = 0,
};

fn pll(pixel_khz: u32, prediv: u8, fbdiv: u16, tmds_a: u2, tmds_b: u2, tmds_c: u2, pclk_a: u5, pclk_b: u2, pclk_c: u2, pclk_d: u5, frac: u24) Pll {
    return .{ .pixel_khz = pixel_khz, .prediv = prediv, .fbdiv = fbdiv, .tmds_a = tmds_a, .tmds_b = tmds_b, .tmds_c = tmds_c, .pclk_a = pclk_a, .pclk_b = pclk_b, .pclk_c = pclk_c, .pclk_d = pclk_d, .frac = frac };
}

/// The pixel clocks the pre-PLL makes, lowest first.
pub const plls = [_]Pll{
    pll(25_175, 1, 100, 2, 3, 3, 12, 3, 3, 4, 0xF55555),
    pll(25_200, 1, 100, 2, 3, 3, 12, 3, 3, 4, 0),
    pll(27_000, 1, 90, 3, 2, 2, 10, 3, 3, 4, 0),
    pll(27_027, 1, 90, 3, 2, 2, 10, 3, 3, 4, 0x170A3D),
    pll(28_320, 1, 28, 2, 1, 1, 3, 0, 3, 4, 0x51EB85),
    pll(30_240, 1, 30, 2, 1, 1, 3, 0, 3, 4, 0x3D70A3),
    pll(31_500, 1, 31, 2, 1, 1, 3, 0, 3, 4, 0x7FFFFF),
    pll(33_750, 1, 33, 2, 1, 1, 3, 0, 3, 4, 0xCFFFFF),
    pll(36_000, 1, 36, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(40_000, 1, 80, 2, 2, 2, 12, 2, 2, 2, 0),
    pll(46_970, 1, 46, 2, 1, 1, 3, 0, 3, 4, 0xF851EB),
    pll(49_000, 1, 49, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(49_500, 1, 49, 2, 1, 1, 3, 0, 3, 4, 0x7FFFFF),
    pll(50_000, 1, 50, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(54_000, 1, 54, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(54_054, 1, 54, 2, 1, 1, 3, 0, 3, 4, 0x0DD2F1),
    pll(57_284, 1, 57, 2, 1, 1, 3, 0, 3, 4, 0x48B439),
    pll(58_230, 1, 58, 2, 1, 1, 3, 0, 3, 4, 0x3AE147),
    pll(59_341, 1, 59, 2, 1, 1, 3, 0, 3, 4, 0x574BC6),
    pll(59_400, 1, 99, 3, 1, 1, 1, 3, 3, 4, 0),
    pll(65_000, 1, 130, 2, 2, 2, 12, 0, 2, 2, 0),
    pll(68_250, 1, 68, 2, 1, 1, 3, 0, 3, 4, 0x3FFFFF),
    pll(71_000, 1, 71, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(74_176, 1, 98, 1, 2, 2, 1, 2, 3, 4, 0xE6AE6B),
    pll(74_250, 1, 99, 1, 2, 2, 1, 2, 3, 4, 0),
    pll(75_000, 1, 75, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(78_750, 1, 78, 2, 1, 1, 3, 0, 3, 4, 0xCFFFFF),
    pll(79_500, 1, 79, 2, 1, 1, 3, 0, 3, 4, 0x7FFFFF),
    pll(83_500, 2, 167, 2, 1, 1, 1, 0, 0, 6, 0),
    pll(85_500, 1, 85, 2, 1, 1, 3, 0, 3, 4, 0x7FFFFF),
    pll(85_750, 1, 85, 2, 1, 1, 3, 0, 3, 4, 0xCFFFFF),
    pll(85_800, 1, 85, 2, 1, 1, 3, 0, 3, 4, 0xCCCCCC),
    pll(88_750, 1, 88, 2, 1, 1, 3, 0, 3, 4, 0xCFFFFF),
    pll(89_000, 1, 89, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(89_910, 1, 89, 2, 1, 1, 3, 0, 3, 4, 0xE8F5C1),
    pll(90_000, 1, 90, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(99_000, 1, 99, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(101_000, 1, 101, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(102_250, 1, 102, 2, 1, 1, 3, 0, 3, 4, 0x3FFFFF),
    pll(106_500, 1, 106, 2, 1, 1, 3, 0, 3, 4, 0x7FFFFF),
    pll(108_000, 1, 90, 3, 0, 0, 5, 0, 2, 2, 0),
    pll(118_800, 1, 118, 2, 1, 1, 3, 0, 3, 4, 0xCCCCCC),
    pll(119_000, 1, 119, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(131_481, 1, 131, 2, 1, 1, 3, 0, 3, 4, 0x7B22D1),
    pll(135_000, 1, 135, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(136_750, 1, 136, 2, 1, 1, 3, 0, 3, 4, 0xCFFFFF),
    pll(147_180, 1, 147, 2, 1, 1, 3, 0, 3, 4, 0x2E147A),
    pll(148_352, 1, 98, 1, 1, 1, 1, 2, 2, 2, 0xE6AE6B),
    pll(148_500, 1, 99, 1, 1, 1, 1, 2, 2, 2, 0),
    pll(154_000, 1, 154, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(156_000, 1, 156, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(157_000, 1, 157, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(162_000, 1, 162, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(174_250, 1, 145, 3, 0, 0, 5, 0, 2, 2, 0x355555),
    pll(174_500, 1, 174, 2, 1, 1, 3, 0, 3, 4, 0x7FFFFF),
    pll(174_570, 1, 174, 2, 1, 1, 3, 0, 3, 4, 0x91EB84),
    pll(175_500, 1, 175, 2, 1, 1, 3, 0, 3, 4, 0x7FFFFF),
    pll(185_590, 1, 185, 2, 1, 1, 3, 0, 3, 4, 0x970A3C),
    pll(185_625, 1, 185, 2, 1, 1, 3, 0, 3, 4, 0xA00000),
    pll(187_000, 1, 187, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(198_000, 1, 198, 2, 1, 1, 3, 0, 3, 4, 0),
    pll(241_500, 1, 161, 1, 1, 1, 4, 0, 2, 2, 0),
    pll(241_700, 1, 241, 2, 1, 1, 3, 0, 3, 4, 0xB33332),
    pll(262_750, 1, 262, 2, 1, 1, 3, 0, 3, 4, 0xCFFFFF),
    pll(296_500, 1, 296, 2, 1, 1, 3, 0, 3, 4, 0x7FFFFF),
    pll(296_703, 1, 98, 0, 1, 1, 1, 0, 2, 2, 0xE6AE6B),
    pll(297_000, 1, 99, 0, 1, 1, 1, 0, 2, 2, 0),
};

/// The pre-PLL for `pixel_khz`; null for a clock it does not make.
pub fn find(pixel_khz: u32) ?*const Pll {
    for (&plls) |*entry| {
        if (entry.pixel_khz == pixel_khz) return entry;
    }
    return null;
}

/// Whether the port can send a mode of that pixel clock.
pub fn sends(pixel_khz: u32) bool {
    return find(pixel_khz) != null;
}

/// The pre-PLL's registers 0x1A1-0x1A6 for `entry`, then its fraction's
/// 0x1D1-0x1D3: a fraction is let in by 0x1A2's bits 5-4 at 0, kept out
/// at 3. What the PLL is set to, and what tells which clock it makes.
pub const Image = struct {
    regs: [6]u8,
    frac: [3]u8,
};

pub fn image(entry: *const Pll) Image {
    const fraction_off: u8 = if (entry.frac == 0) 0x30 else 0;
    return .{
        .regs = .{
            entry.prediv,
            0xC0 | fraction_off | @as(u8, @truncate(entry.fbdiv >> 8)),
            @truncate(entry.fbdiv),
            @as(u8, entry.tmds_a) << 4 | @as(u8, entry.tmds_b) << 2 | entry.tmds_c,
            @as(u8, entry.pclk_b) << 5 | entry.pclk_a,
            @as(u8, entry.pclk_c) << 5 | entry.pclk_d,
        },
        .frac = .{ @truncate(entry.frac >> 16), @truncate(entry.frac >> 8), @truncate(entry.frac) },
    };
}

/// The pixel clock the pre-PLL makes when its registers read `regs`
/// (0x1A1-0x1A6) and `frac` (0x1D1-0x1D3); 0 for none of these.
pub fn clockOf(regs: [6]u8, frac: [3]u8) u32 {
    for (&plls) |*entry| {
        const set = image(entry);
        if (!std.mem.eql(u8, &set.regs, &regs)) continue;
        if (entry.frac != 0 and !std.mem.eql(u8, &set.frac, &frac)) continue;
        return entry.pixel_khz;
    }
    return 0;
}

/// The post-PLL for a TMDS clock: 0x1AB, 0x1AC, 0x1AD, then 0x1AA - its
/// post divider on (0x0E) or bypassed (0x02), powered up either way.
pub fn post(pixel_khz: u32) [4]u8 {
    // StarFive's table, by the first row whose clock is not below this.
    if (pixel_khz <= 25_200) return .{ 1, 80, 13, 0x0E };
    if (pixel_khz <= 33_750) return .{ 1, 40, 11, 0x0E };
    if (pixel_khz <= 241_700) return .{ 1, 20, 1, 0x0E };
    return .{ 4, 20, 0, 0x02 };
}

const std = @import("std");
const testing = std.testing;

test "148.5 MHz is U-Boot's 1080p setting" {
    const set = image(find(148_500).?);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0xF0, 0x63, 0x15, 0x41, 0x42 }, &set.regs);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x14, 0x01, 0x0E }, &post(148_500));
}

test "each clock reads back as itself" {
    for (&plls) |*entry| {
        const set = image(entry);
        try testing.expectEqual(entry.pixel_khz, clockOf(set.regs, set.frac));
    }
    try testing.expectEqual(@as(u32, 0), clockOf(.{ 0, 0, 0, 0, 0, 0 }, .{ 0, 0, 0 }));
}

test "the standard modes the port can send" {
    const edid = @import("../edid.zig");
    for (&edid.known) |*mode| {
        try testing.expect(sends(mode.pixel_khz));
    }
    try testing.expect(!sends(146_250)); // 1680x1050 at 60 on DMT's full blanking
    try testing.expect(!sends(594_000)); // 3840x2160 at 60
}
