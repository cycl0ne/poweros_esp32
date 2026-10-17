// SPDX-License-Identifier: MPL-2.0
//! What a monitor behind the HDMI bridge takes, and which picture it gets.
//!
//! The monitor says what it takes in its EDID: a first block of 128
//! bytes, and for an HDMI set usually a second, CEA-861's extension. A mode
//! is taken when it is named anywhere there - among the established
//! timings (bits for VESA's old modes), the standard timings (size and
//! refresh, two bytes each), the detailed timings (a mode in full), or the
//! extension's short video descriptors (CEA's numbered modes).
//!
//! **The modes this board can send** are standard sizes at 60 Hz on the
//! pixel clocks the chip makes - 240 MHz divided by a whole number. Where
//! the standard's clock is not one of them, the mode keeps its line and
//! frame rates, its line count and its sync polarity, which is what a
//! monitor recognises a mode by, and takes the difference in the width of
//! its blanking: 1360x768 and 1280x720 at 80 MHz instead of 85.5 and
//! 74.25, 1024x768 at 60 instead of 65.
//!
//! **Each mode comes with the link's lane rate**, a line a whole number
//! of the lane's byte clocks. The bridge remakes the pixel clock by how
//! full its FIFO keeps, and how much faster than the picture's RGB888 the
//! lanes have to run for that clock to hold still is not one ratio:
//! 1280x720 and 1024x768 hold at a third more, 1360x768 hunts there,
//! whatever its blanking, and holds at half again. The rate in the table
//! is the one each was seen to hold at, read back from the bridge.
//!
//! The largest mode the monitor takes is the one shown; one that names
//! none of them gets the board's own, 800x600 on VESA's timings.

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
    /// CEA-861's number for it, 0 for none.
    vic: u8 = 0,
};

/// The modes beyond the board's own, largest first.
pub const modes = [_]Mode{
    // VESA's 1360x768 at 60 Hz: 1792 x 795 at 85.5 MHz, 47.7 kHz lines.
    // At 80 MHz a line is 1680 clocks, the back porch 112 shorter, and a
    // frame one line shorter. The lanes carry half again the picture:
    // 1440 Mbit/s, under the PHY's 1500; at a third more, 1280, the
    // bridge's clock hunts.
    .{ .width = 1360, .height = 768, .pixel_hz = 80_000_000, .hsync = 112, .hbp = 144, .hfp = 64, .vsync = 6, .vbp = 17, .vfp = 3, .hsync_high = true, .vsync_high = true, .lane_mbps = 1440 },
    // CEA's 1280x720p60 (VIC 4): 1650 x 750 at 74.25 MHz, 45 kHz lines.
    // At 80 MHz a line is 1778 clocks; the 128 more are back porch.
    .{ .width = 1280, .height = 720, .pixel_hz = 80_000_000, .hsync = 40, .hbp = 348, .hfp = 110, .vsync = 5, .vbp = 20, .vfp = 5, .hsync_high = true, .vsync_high = true, .lane_mbps = 1280, .vic = 4 },
    // VESA's 1024x768 at 60 Hz: 1344 x 806 at 65 MHz, 48.4 kHz lines. At
    // 60 MHz a line is 1240 clocks; the back porch is 104 shorter.
    .{ .width = 1024, .height = 768, .pixel_hz = 60_000_000, .hsync = 136, .hbp = 56, .hfp = 24, .vsync = 6, .vbp = 29, .vfp = 3, .hsync_high = false, .vsync_high = false, .lane_mbps = 960 },
};

pub const Edid = [128]u8;

/// Whether the monitor's EDID - its first block, and the extension when
/// it has one - names `mode`.
pub fn takes(first: *const Edid, extension: ?*const Edid, mode: *const Mode) bool {
    if (established(first, mode)) return true;
    if (standard(first, mode)) return true;
    if (detailedIn(first, 54, mode)) return true;
    if (extension) |cea| {
        if (cea[0] == 0x02) {
            if (mode.vic != 0 and videoCodes(cea, mode.vic)) return true;
            if (detailedIn(cea, cea[2], mode)) return true;
        }
    }
    return false;
}

/// The established timings: bytes 35-37, a bit a mode.
fn established(edid: *const Edid, mode: *const Mode) bool {
    if (mode.width == 800 and mode.height == 600) return edid[35] & 0x01 != 0;
    if (mode.width == 1024 and mode.height == 768) return edid[36] & 0x08 != 0;
    return false;
}

/// The standard timings: bytes 38-53, two bytes each - the width as
/// (pixels / 8) - 31, then the aspect (16:10, 4:3, 5:4, 16:9) and the
/// refresh less 60. The form cannot say 1360x768: 1360 at 16:9 is 765
/// lines, and a monitor naming 765 means 768.
fn standard(edid: *const Edid, mode: *const Mode) bool {
    var at: usize = 38;
    while (at < 54) : (at += 2) {
        const first = edid[at];
        const second = edid[at + 1];
        if (first == 0x01 and second == 0x01) continue;
        const width = (@as(u32, first) + 31) * 8;
        const by_aspect: u32 = switch (second >> 6) {
            0 => width * 10 / 16,
            1 => width * 3 / 4,
            2 => width * 4 / 5,
            else => width * 9 / 16,
        };
        const height: u32 = if (width == 1360 and by_aspect == 765) 768 else by_aspect;
        if (width == mode.width and height == mode.height and second & 0x3F == 0) return true;
    }
    return false;
}

/// The detailed timings in `block` from byte `start` on, 18 bytes each, up
/// to the block's checksum; a descriptor whose clock is 0 is something
/// else and is passed over. Taken at 60 Hz, give or take a hertz.
fn detailedIn(block: *const Edid, start: usize, mode: *const Mode) bool {
    if (start < 4) return false;
    var at = start;
    while (at + 18 <= 127) : (at += 18) {
        const timing = block[at..][0..18];
        const clock_10khz = @as(u32, timing[1]) << 8 | timing[0];
        if (clock_10khz == 0) continue;
        const h_active = @as(u32, timing[4] >> 4) << 8 | timing[2];
        const h_blank = @as(u32, timing[4] & 0xF) << 8 | timing[3];
        const v_active = @as(u32, timing[7] >> 4) << 8 | timing[5];
        const v_blank = @as(u32, timing[7] & 0xF) << 8 | timing[6];
        if (h_active != mode.width or v_active != mode.height) continue;
        const total = (h_active + h_blank) * (v_active + v_blank);
        if (total == 0) continue;
        const millihertz = @as(u64, clock_10khz) * 10_000 * 1000 / total;
        if (millihertz >= 59_000 and millihertz <= 61_000) return true;
    }
    return false;
}

/// The extension's short video descriptors: in its data block collection
/// (from byte 4 to the byte its third names), the blocks of tag 2, a
/// byte a mode, the code in its low seven bits.
fn videoCodes(cea: *const Edid, vic: u8) bool {
    const end = @min(@as(usize, cea[2]), 127);
    var at: usize = 4;
    while (at < end) {
        const tag = cea[at] >> 5;
        const length = cea[at] & 0x1F;
        if (tag == 2) {
            for (cea[at + 1 ..][0..length]) |code| {
                if (code & 0x7F == vic) return true;
            }
        }
        at += 1 + length;
    }
    return false;
}

/// The largest of `modes` the monitor takes; null for none of them.
pub fn best(first: *const Edid, extension: ?*const Edid) ?*const Mode {
    for (&modes) |*mode| {
        if (takes(first, extension, mode)) return mode;
    }
    return null;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "a monitor that names 720p in its extension gets it; one that names nothing larger gets none" {
    var first: Edid = @splat(0);
    first[35] = 0x01; // 800x600 at 60
    try testing.expectEqual(@as(?*const Mode, null), best(&first, null));
    var cea: Edid = @splat(0);
    cea[0] = 0x02;
    cea[2] = 8; // the detailed timings start at 8
    cea[4] = 2 << 5 | 3; // video: three codes
    cea[5] = 0x10; // 1080p60
    cea[6] = 0x84; // 720p60, native
    cea[7] = 0x03; // 480p
    try testing.expectEqual(@as(u32, 1280), best(&first, &cea).?.width);
}

test "1024x768 from the established bits, and from a standard timing" {
    var first: Edid = @splat(0);
    first[36] = 0x08;
    try testing.expectEqual(@as(u32, 1024), best(&first, null).?.width);
    first[36] = 0;
    for (38..54) |i| first[i] = 0x01;
    first[38] = 1024 / 8 - 31;
    first[39] = 1 << 6; // 4:3, 60 Hz
    try testing.expectEqual(@as(u32, 1024), best(&first, null).?.width);
}

test "a detailed timing of 1280x720 at 60 Hz" {
    var first: Edid = @splat(0);
    // 74.25 MHz, 1280 + 370 across, 720 + 30 down.
    const timing = first[54..72];
    timing[0] = 0x01;
    timing[1] = 0x1D; // 7425 x 10 kHz
    timing[2] = 0x00;
    timing[3] = 0x72;
    timing[4] = 0x51;
    timing[5] = 0xD0;
    timing[6] = 0x1E;
    timing[7] = 0x20;
    try testing.expectEqual(@as(u32, 1280), best(&first, null).?.width);
}

test "1360x768 from a detailed timing, and from a standard timing's 765 lines" {
    var first: Edid = @splat(0);
    // 85.5 MHz, 1360 + 432 across, 768 + 27 down.
    const timing = first[54..72];
    timing[0] = 0x66;
    timing[1] = 0x21; // 8550 x 10 kHz
    timing[2] = 0x50;
    timing[3] = 0xB0;
    timing[4] = 0x51;
    timing[5] = 0x00;
    timing[6] = 0x1B;
    timing[7] = 0x30;
    try testing.expectEqual(@as(u32, 1360), best(&first, null).?.width);
    @memset(first[54..72], 0);
    try testing.expectEqual(@as(?*const Mode, null), best(&first, null));
    for (38..54) |i| first[i] = 0x01;
    first[38] = 1360 / 8 - 31;
    first[39] = 3 << 6; // 16:9, 60 Hz
    try testing.expectEqual(@as(u32, 768), best(&first, null).?.height);
}

test "a 1080p monitor that lists 720p among its standard timings gets it" {
    // The first block of a portable 1080p monitor: established 640x480,
    // 720x400, 800x600 and 1024x768; standard 1920x1080 three times,
    // 1440x900, 1400x1050, 1280x1024, 1280x960, 1280x720; 1080p60 in
    // full.
    var first: Edid = @splat(0);
    first[35] = 0xA1;
    first[36] = 0x08;
    const standards = [16]u8{ 0xD1, 0xC0, 0xD1, 0xC0, 0xD1, 0xC0, 0x95, 0x00, 0x90, 0x40, 0x81, 0x80, 0x81, 0x40, 0x81, 0xC0 };
    @memcpy(first[38..54], &standards);
    const full_hd = [18]u8{ 0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 0x58, 0x2C, 0x45, 0x00, 0x58, 0xC2, 0x10, 0x00, 0x00, 0x1E };
    @memcpy(first[54..72], &full_hd);
    try testing.expectEqual(@as(u32, 720), best(&first, null).?.height);
}
