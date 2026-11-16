// SPDX-License-Identifier: MPL-2.0
//! The modes the DSI host sends to a monitor behind the HDMI bridge.
//!
//! **What the host can send** are standard sizes at 60 Hz on the pixel
//! clocks the chip makes - 240 MHz divided by a whole number. Where the
//! standard's clock is not one of them, the mode keeps its line and
//! frame rates, its line count and its sync polarity, which is what a
//! monitor recognises a mode by, and takes the difference in the width of
//! its blanking: 1360x768 and 1280x720 at 80 MHz instead of 85.5 and
//! 74.25, 1024x768 at 60 instead of 65. So a mode rtg.library lists for
//! the board - made of what the monitor's EDID names, in the standard's
//! timing - is sent in the timing of this table for its size
//! (`forSize`), and the board says it can make a timing when the table
//! has its size at 60 Hz (`dsiboard.checkMode`).
//!
//! **Each mode comes with the link's lane rate**, a line a whole number
//! of the lane's byte clocks. The bridge remakes the pixel clock by how
//! full its FIFO keeps, and how much faster than the picture's RGB888 the
//! lanes have to run for that clock to hold still is not one ratio:
//! 1280x720 and 1024x768 hold at a third more, 1360x768 hunts there,
//! whatever its blanking, and holds at half again. The rate in the table
//! is the one each was seen to hold at, read back from the bridge.
//!
//! The board's own mode, 800x600 on VESA's timings, is the part's: its
//! tags give it, and it is what a monitor that names none of these gets.

/// A mode as the DSI board drives it: the picture, its timings in pixel
/// clocks and lines, the sync polarity, the pixel clock, and the lane rate
/// on two lanes.
pub const Mode = struct {
    width: u32,
    height: u32,
    pixel_hz: u32,
    hsync: u32,
    hbp: u32,
    hfp: u32,
    vsync: u32,
    vbp: u32,
    vfp: u32,
    hsync_high: bool,
    vsync_high: bool,
    lane_mbps: u32,
};

/// The modes beyond the board's own, largest first.
pub const modes = [_]Mode{
    // VESA's 1360x768 at 60 Hz: 1792 x 795 at 85.5 MHz, 47.7 kHz lines.
    // At 80 MHz a line is 1680 clocks, the back porch 112 shorter, and a
    // frame one line shorter. The lanes carry half again the picture:
    // 1440 Mbit/s, under the PHY's 1500; at a third more, 1280, the
    // bridge's clock hunts.
    .{ .width = 1360, .height = 768, .pixel_hz = 80_000_000, .hsync = 112, .hbp = 144, .hfp = 64, .vsync = 6, .vbp = 17, .vfp = 3, .hsync_high = true, .vsync_high = true, .lane_mbps = 1440 },
    // CEA's 1280x720p60: 1650 x 750 at 74.25 MHz, 45 kHz lines. At 80 MHz
    // a line is 1778 clocks; the 128 more are back porch.
    .{ .width = 1280, .height = 720, .pixel_hz = 80_000_000, .hsync = 40, .hbp = 348, .hfp = 110, .vsync = 5, .vbp = 20, .vfp = 5, .hsync_high = true, .vsync_high = true, .lane_mbps = 1280 },
    // VESA's 1024x768 at 60 Hz: 1344 x 806 at 65 MHz, 48.4 kHz lines. At
    // 60 MHz a line is 1240 clocks; the back porch is 104 shorter.
    .{ .width = 1024, .height = 768, .pixel_hz = 60_000_000, .hsync = 136, .hbp = 56, .hfp = 24, .vsync = 6, .vbp = 29, .vfp = 3, .hsync_high = false, .vsync_high = false, .lane_mbps = 960 },
};

/// The mode of that size the host sends; null where it has none.
pub fn forSize(width: u32, height: u32) ?*const Mode {
    for (&modes) |*mode| {
        if (mode.width == width and mode.height == height) return mode;
    }
    return null;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the modes the host sends, by their size; each near 60 frames a second" {
    try testing.expectEqual(@as(u32, 1280), forSize(1280, 720).?.lane_mbps);
    try testing.expectEqual(@as(u32, 60_000_000), forSize(1024, 768).?.pixel_hz);
    try testing.expectEqual(@as(?*const Mode, null), forSize(1920, 1080));
    try testing.expectEqual(@as(?*const Mode, null), forSize(800, 600));
    for (&modes) |*mode| {
        const line = mode.hsync + mode.hbp + mode.width + mode.hfp;
        const lines = mode.vsync + mode.vbp + mode.height + mode.vfp;
        const millihertz = @as(u64, mode.pixel_hz) * 1000 / (@as(u64, line) * lines);
        try testing.expect(millihertz > 59_500 and millihertz < 60_500);
    }
}
