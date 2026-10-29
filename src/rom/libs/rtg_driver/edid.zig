// SPDX-License-Identifier: MPL-2.0
//! What a monitor says it takes: its EDID, read by a board's driver over
//! whatever reaches the monitor, taken apart here. Nothing here touches a
//! bus, so the host tests hold all of it.
//!
//! The EDID is blocks of 128 bytes, each summing to zero. The first
//! names the monitor and the modes it takes; an HDMI set usually has a
//! second, CEA-861's extension, with more. A mode is named among the
//! established timings (bits for VESA's old modes), the standard timings
//! (size and refresh, two bytes each), the detailed timings (a mode in
//! full, 18 bytes each - the first block's first is the one the monitor
//! prefers) or the extension's short video descriptors (CEA's numbered
//! modes).
//!
//! A monitor that names a mode without its timing means the standard's:
//! CEA-861's for a numbered mode, VESA's DMT for a size and a refresh.
//! `known` holds those a monitor is likely to name.

pub const Block = [128]u8;

/// A mode in full: the picture, the blanking on each side of the sync and
/// the sync itself, in pixel clocks and lines, the sync pulses' polarity,
/// and the pixel clock.
pub const Timing = struct {
    width: u32,
    height: u32,
    h_front: u32,
    h_sync: u32,
    h_back: u32,
    v_front: u32,
    v_sync: u32,
    v_back: u32,
    pixel_khz: u32,
    hsync_high: bool,
    vsync_high: bool,
    /// CEA-861's number for it, 0 for none.
    vic: u8 = 0,

    pub fn htotal(t: *const Timing) u32 {
        return t.width + t.h_front + t.h_sync + t.h_back;
    }

    pub fn vtotal(t: *const Timing) u32 {
        return t.height + t.v_front + t.v_sync + t.v_back;
    }

    /// Frames a second, in thousandths.
    pub fn milliHz(t: *const Timing) u32 {
        const whole = @as(u64, t.htotal()) * t.vtotal();
        if (whole == 0) return 0;
        return @intCast(@as(u64, t.pixel_khz) * 1_000_000 / whole);
    }

    /// Frames a second, to the nearest.
    pub fn hz(t: *const Timing) u32 {
        return (t.milliHz() + 500) / 1000;
    }

    /// Whether `other` is the same picture at the same refresh.
    pub fn sameAs(t: *const Timing, other: *const Timing) bool {
        return t.width == other.width and t.height == other.height and t.hz() == other.hz();
    }
};

/// The standard modes a monitor may name by a number, a bit or a size
/// and a refresh, largest first: CEA-861's (with their numbers) and
/// VESA's DMT, as the standards time them.
pub const known = [_]Timing{
    // CEA's 3840x2160p at 60 and 50 Hz: 594 MHz, past HDMI 1.4's 340.
    .{ .width = 3840, .height = 2160, .pixel_khz = 594_000, .h_front = 176, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .hsync_high = true, .vsync_high = true, .vic = 97 },
    .{ .width = 3840, .height = 2160, .pixel_khz = 594_000, .h_front = 1056, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .hsync_high = true, .vsync_high = true, .vic = 96 },
    // CEA's 3840x2160p at 30, 25 and 24 Hz: one line, 297 MHz.
    .{ .width = 3840, .height = 2160, .pixel_khz = 297_000, .h_front = 176, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .hsync_high = true, .vsync_high = true, .vic = 95 },
    .{ .width = 3840, .height = 2160, .pixel_khz = 297_000, .h_front = 1056, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .hsync_high = true, .vsync_high = true, .vic = 94 },
    .{ .width = 3840, .height = 2160, .pixel_khz = 297_000, .h_front = 1276, .h_sync = 88, .h_back = 296, .v_front = 8, .v_sync = 10, .v_back = 72, .hsync_high = true, .vsync_high = true, .vic = 93 },
    // CEA's 1920x1080p at 60 and 50 Hz.
    .{ .width = 1920, .height = 1080, .pixel_khz = 148_500, .h_front = 88, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .hsync_high = true, .vsync_high = true, .vic = 16 },
    .{ .width = 1920, .height = 1080, .pixel_khz = 148_500, .h_front = 528, .h_sync = 44, .h_back = 148, .v_front = 4, .v_sync = 5, .v_back = 36, .hsync_high = true, .vsync_high = true, .vic = 31 },
    // VESA's 1280x1024, 1440x900 and 1280x960 at 60 Hz.
    .{ .width = 1280, .height = 1024, .pixel_khz = 108_000, .h_front = 48, .h_sync = 112, .h_back = 248, .v_front = 1, .v_sync = 3, .v_back = 38, .hsync_high = true, .vsync_high = true },
    .{ .width = 1440, .height = 900, .pixel_khz = 106_500, .h_front = 80, .h_sync = 152, .h_back = 232, .v_front = 3, .v_sync = 6, .v_back = 25, .hsync_high = false, .vsync_high = true },
    .{ .width = 1280, .height = 960, .pixel_khz = 108_000, .h_front = 96, .h_sync = 112, .h_back = 312, .v_front = 1, .v_sync = 3, .v_back = 36, .hsync_high = true, .vsync_high = true },
    // VESA's 1600x900 at 60 Hz, reduced blanking: DMT has no other.
    .{ .width = 1600, .height = 900, .pixel_khz = 108_000, .h_front = 24, .h_sync = 80, .h_back = 96, .v_front = 1, .v_sync = 3, .v_back = 96, .hsync_high = true, .vsync_high = true },
    // VESA's 1366x768, 1360x768 and 1280x800 at 60 Hz.
    .{ .width = 1366, .height = 768, .pixel_khz = 85_500, .h_front = 70, .h_sync = 143, .h_back = 213, .v_front = 3, .v_sync = 3, .v_back = 24, .hsync_high = true, .vsync_high = true },
    .{ .width = 1360, .height = 768, .pixel_khz = 85_500, .h_front = 64, .h_sync = 112, .h_back = 256, .v_front = 3, .v_sync = 6, .v_back = 18, .hsync_high = true, .vsync_high = true },
    .{ .width = 1280, .height = 800, .pixel_khz = 83_500, .h_front = 72, .h_sync = 128, .h_back = 200, .v_front = 3, .v_sync = 6, .v_back = 22, .hsync_high = false, .vsync_high = true },
    // CEA's 1280x720p at 60 and 50 Hz.
    .{ .width = 1280, .height = 720, .pixel_khz = 74_250, .h_front = 110, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .hsync_high = true, .vsync_high = true, .vic = 4 },
    .{ .width = 1280, .height = 720, .pixel_khz = 74_250, .h_front = 440, .h_sync = 40, .h_back = 220, .v_front = 5, .v_sync = 5, .v_back = 20, .hsync_high = true, .vsync_high = true, .vic = 19 },
    // VESA's 1024x768 and 800x600 at 60 Hz.
    .{ .width = 1024, .height = 768, .pixel_khz = 65_000, .h_front = 24, .h_sync = 136, .h_back = 160, .v_front = 3, .v_sync = 6, .v_back = 29, .hsync_high = false, .vsync_high = false },
    .{ .width = 800, .height = 600, .pixel_khz = 40_000, .h_front = 40, .h_sync = 128, .h_back = 88, .v_front = 1, .v_sync = 4, .v_back = 23, .hsync_high = true, .vsync_high = true },
    // CEA's 720x576p at 50 Hz and 720x480p at 60 Hz, each in 4:3 and
    // 16:9 under two numbers.
    .{ .width = 720, .height = 576, .pixel_khz = 27_000, .h_front = 12, .h_sync = 64, .h_back = 68, .v_front = 5, .v_sync = 5, .v_back = 39, .hsync_high = false, .vsync_high = false, .vic = 17 },
    .{ .width = 720, .height = 576, .pixel_khz = 27_000, .h_front = 12, .h_sync = 64, .h_back = 68, .v_front = 5, .v_sync = 5, .v_back = 39, .hsync_high = false, .vsync_high = false, .vic = 18 },
    .{ .width = 720, .height = 480, .pixel_khz = 27_000, .h_front = 16, .h_sync = 62, .h_back = 60, .v_front = 9, .v_sync = 6, .v_back = 30, .hsync_high = false, .vsync_high = false, .vic = 2 },
    .{ .width = 720, .height = 480, .pixel_khz = 27_000, .h_front = 16, .h_sync = 62, .h_back = 60, .v_front = 9, .v_sync = 6, .v_back = 30, .hsync_high = false, .vsync_high = false, .vic = 3 },
    // CEA's and VESA's 640x480 at 60 Hz.
    .{ .width = 640, .height = 480, .pixel_khz = 25_175, .h_front = 16, .h_sync = 96, .h_back = 48, .v_front = 10, .v_sync = 2, .v_back = 33, .hsync_high = false, .vsync_high = false, .vic = 1 },
};

/// The standard mode of that size and refresh; null when `known` has
/// none.
pub fn knownMode(width: u32, height: u32, refresh_hz: u32) ?Timing {
    for (&known) |*mode| {
        if (mode.width == width and mode.height == height and mode.hz() == refresh_hz) return mode.*;
    }
    return null;
}

/// CEA-861's number for `timing`: that of the numbered mode with the same
/// picture, the same totals and the same clock, wherever its sync lies
/// in the blanking; 0 for none.
pub fn vicOf(timing: *const Timing) u8 {
    for (&known) |*mode| {
        if (mode.vic == 0) continue;
        if (mode.width != timing.width or mode.height != timing.height) continue;
        if (mode.htotal() != timing.htotal() or mode.vtotal() != timing.vtotal()) continue;
        if (mode.pixel_khz == timing.pixel_khz) return mode.vic;
    }
    return 0;
}

/// Whether `block` is a first block: it starts with EDID's header.
pub fn isFirst(block: *const Block) bool {
    const header = [8]u8{ 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00 };
    for (header, 0..) |byte, i| {
        if (block[i] != byte) return false;
    }
    return true;
}

/// Whether `block` sums to zero, as every block does that was read as
/// the monitor holds it.
pub fn valid(block: *const Block) bool {
    var sum: u8 = 0;
    for (block) |byte| sum +%= byte;
    return sum == 0;
}

/// Whether `block` is CEA-861's extension.
pub fn isCea(block: *const Block) bool {
    return block[0] == 0x02;
}

/// The monitor's name (descriptor 0xFC), up to 13 characters and
/// NUL-terminated in `into`; empty if it gives none.
pub fn name(first: *const Block, into: *[14]u8) void {
    into.* = @splat(0);
    var at: usize = 54;
    while (at + 18 <= 126) : (at += 18) {
        const d = first[at..][0..18];
        if (d[0] != 0 or d[1] != 0 or d[3] != 0xFC) continue;
        var n: usize = 0;
        while (n < 13 and d[5 + n] != 0x0A) : (n += 1) into[n] = d[5 + n];
        return;
    }
}

/// The detailed timing at byte `at` of `block`: 18 bytes. Null for a
/// descriptor that is something else (its clock is 0), an interlaced
/// mode, or one whose sync does not fit its blanking.
pub fn detailed(block: *const Block, at: usize) ?Timing {
    if (at + 18 > block.len) return null;
    const d = block[at..][0..18];
    const clock_10khz = @as(u32, d[1]) << 8 | d[0];
    if (clock_10khz == 0) return null;
    if (d[17] & 0x80 != 0) return null;
    const h_blank = @as(u32, d[4] & 0xF) << 8 | d[3];
    const v_blank = @as(u32, d[7] & 0xF) << 8 | d[6];
    const h_front = @as(u32, d[11] >> 6) << 8 | d[8];
    const h_sync = @as(u32, (d[11] >> 4) & 3) << 8 | d[9];
    const v_front = @as(u32, (d[11] >> 2) & 3) << 4 | d[10] >> 4;
    const v_sync = @as(u32, d[11] & 3) << 4 | (d[10] & 0xF);
    if (h_front + h_sync > h_blank or v_front + v_sync > v_blank) return null;
    // Digital separate sync (bits 4-3) gives each pulse's polarity in
    // bits 2 and 1; anything else is taken as both low.
    const separate = d[17] & 0x18 == 0x18;
    return .{
        .width = @as(u32, d[4] >> 4) << 8 | d[2],
        .height = @as(u32, d[7] >> 4) << 8 | d[5],
        .h_front = h_front,
        .h_sync = h_sync,
        .h_back = h_blank - h_front - h_sync,
        .v_front = v_front,
        .v_sync = v_sync,
        .v_back = v_blank - v_front - v_sync,
        .pixel_khz = clock_10khz * 10,
        .hsync_high = separate and d[17] & 0x02 != 0,
        .vsync_high = separate and d[17] & 0x04 != 0,
    };
}

/// The detailed timings of the first block and of the extension, in that
/// order, into `into`; how many there were, up to its length. The first
/// is the mode the monitor prefers, if the first block's first descriptor
/// is a timing.
pub fn detailedTimings(first: *const Block, extension: ?*const Block, into: []Timing) usize {
    var count: usize = 0;
    var at: usize = 54;
    while (at + 18 <= 126) : (at += 18) {
        const timing = detailed(first, at) orelse continue;
        if (count == into.len) return count;
        into[count] = timing;
        count += 1;
    }
    const cea = extension orelse return count;
    if (!isCea(cea) or cea[2] < 4) return count;
    at = cea[2];
    while (at + 18 <= 127) : (at += 18) {
        const timing = detailed(cea, at) orelse continue;
        if (count == into.len) return count;
        into[count] = timing;
        count += 1;
    }
    return count;
}

/// A mode as a monitor may name it: a picture at a refresh, and CEA's
/// number for it if it has one.
pub const Named = struct {
    width: u32,
    height: u32,
    refresh_hz: u32 = 60,
    vic: u8 = 0,
};

/// Whether the monitor's EDID - its first block, and the extension when
/// it has one - names `mode`.
pub fn takes(first: *const Block, extension: ?*const Block, mode: Named) bool {
    if (established(first, mode)) return true;
    if (standard(first, mode)) return true;
    var timings: [10]Timing = undefined;
    const count = detailedTimings(first, extension, &timings);
    for (timings[0..count]) |*timing| {
        if (timing.width != mode.width or timing.height != mode.height) continue;
        // Taken at its refresh, give or take a hertz.
        const millihertz = timing.milliHz();
        if (millihertz + 1000 >= mode.refresh_hz * 1000 and millihertz <= mode.refresh_hz * 1000 + 1000) return true;
    }
    if (extension) |cea| {
        if (isCea(cea) and mode.vic != 0 and videoCodes(cea, mode.vic)) return true;
    }
    return false;
}

/// The established timings: bytes 35-37, a bit a mode.
const Established = struct { byte: u8, bit: u3, width: u32, height: u32, refresh_hz: u32 };
const established_bits = [_]Established{
    .{ .byte = 35, .bit = 7, .width = 720, .height = 400, .refresh_hz = 70 },
    .{ .byte = 35, .bit = 6, .width = 720, .height = 400, .refresh_hz = 88 },
    .{ .byte = 35, .bit = 5, .width = 640, .height = 480, .refresh_hz = 60 },
    .{ .byte = 35, .bit = 4, .width = 640, .height = 480, .refresh_hz = 67 },
    .{ .byte = 35, .bit = 3, .width = 640, .height = 480, .refresh_hz = 72 },
    .{ .byte = 35, .bit = 2, .width = 640, .height = 480, .refresh_hz = 75 },
    .{ .byte = 35, .bit = 1, .width = 800, .height = 600, .refresh_hz = 56 },
    .{ .byte = 35, .bit = 0, .width = 800, .height = 600, .refresh_hz = 60 },
    .{ .byte = 36, .bit = 7, .width = 800, .height = 600, .refresh_hz = 72 },
    .{ .byte = 36, .bit = 6, .width = 800, .height = 600, .refresh_hz = 75 },
    .{ .byte = 36, .bit = 5, .width = 832, .height = 624, .refresh_hz = 75 },
    .{ .byte = 36, .bit = 3, .width = 1024, .height = 768, .refresh_hz = 60 },
    .{ .byte = 36, .bit = 2, .width = 1024, .height = 768, .refresh_hz = 70 },
    .{ .byte = 36, .bit = 1, .width = 1024, .height = 768, .refresh_hz = 75 },
    .{ .byte = 36, .bit = 0, .width = 1280, .height = 1024, .refresh_hz = 75 },
    .{ .byte = 37, .bit = 7, .width = 1152, .height = 870, .refresh_hz = 75 },
};

fn established(first: *const Block, mode: Named) bool {
    for (established_bits) |bit| {
        if (bit.width != mode.width or bit.height != mode.height or bit.refresh_hz != mode.refresh_hz) continue;
        if (first[bit.byte] & (@as(u8, 1) << bit.bit) != 0) return true;
    }
    return false;
}

/// The standard timings: bytes 38-53, two bytes each - the width as
/// (pixels / 8) - 31, then the aspect (16:10, 4:3, 5:4, 16:9) and the
/// refresh less 60. The form cannot say 1360x768: 1360 at 16:9 is 765
/// lines, and a monitor naming 765 means 768.
fn standard(first: *const Block, mode: Named) bool {
    var at: usize = 38;
    while (at < 54) : (at += 2) {
        const width_byte = first[at];
        const second = first[at + 1];
        if (width_byte == 0x01 and second == 0x01) continue;
        const width = (@as(u32, width_byte) + 31) * 8;
        const by_aspect: u32 = switch (second >> 6) {
            0 => width * 10 / 16,
            1 => width * 3 / 4,
            2 => width * 4 / 5,
            else => width * 9 / 16,
        };
        const height: u32 = if (width == 1360 and by_aspect == 765) 768 else by_aspect;
        const refresh_hz = @as(u32, second & 0x3F) + 60;
        if (width == mode.width and height == mode.height and refresh_hz == mode.refresh_hz) return true;
    }
    return false;
}

/// The extension's short video descriptors: in its data block collection
/// (from byte 4 to the byte its third names), the blocks of tag 2, a
/// byte a mode. Codes 129-192 are 1-64 marked native; any other is the
/// number itself.
fn videoCodes(cea: *const Block, vic: u8) bool {
    const end = @min(@as(usize, cea[2]), 127);
    var at: usize = 4;
    while (at < end) {
        const tag = cea[at] >> 5;
        const length = cea[at] & 0x1F;
        if (tag == 2) {
            for (cea[at + 1 ..][0..@min(length, 127 - at - 1)]) |code| {
                const number = if (code >= 129 and code <= 192) code - 128 else code;
                if (number == vic) return true;
            }
        }
        at += 1 + length;
    }
    return false;
}

/// What a monitor says of itself beyond its modes, in the extension's
/// data blocks. Without an extension it is a DVI monitor: none of it.
pub const Sink = struct {
    /// It names HDMI's own block (the IEEE's 00-0C-03): it takes HDMI's
    /// packets - the infoframes, the sound - between the lines.
    hdmi: bool = false,
    /// It plays sound: two channels of LPCM at 32, 44.1 and 48 kHz at the
    /// least (basic audio, the extension's fourth byte).
    audio: bool = false,
    /// Its RGB range may be chosen, full or limited, by the AVI
    /// infoframe (the video capability block's QS).
    quant_selectable: bool = false,
    /// The fastest TMDS clock it takes, in kHz: the HDMI Forum's block's
    /// rate where it has one, else HDMI's block's; 0 where neither says.
    max_tmds_khz: u32 = 0,
    /// It has the status and control data channel (the Forum's block's
    /// SCDC_Present), which a TMDS clock past 340 MHz is scrambled
    /// through.
    scdc: bool = false,
    /// It names the HDMI Forum's block: an HDMI 2.0 monitor, which takes
    /// CEA's numbers above 64 in the AVI infoframe - HDMI 1.4's 4K modes
    /// among them, which an older one takes in HDMI's vendor infoframe.
    forum: bool = false,

    /// The fastest pixel clock it takes at eight bits a colour, in kHz:
    /// past 340 MHz only scrambled, which wants SCDC; else no more than
    /// HDMI 1.4's 340 MHz, or what its HDMI block says if that is less.
    pub fn mostKhz(sink: Sink) u32 {
        if (sink.scdc and sink.max_tmds_khz > hdmi14_khz) return sink.max_tmds_khz;
        if (sink.max_tmds_khz != 0) return @min(sink.max_tmds_khz, hdmi14_khz);
        return hdmi14_khz;
    }
};

/// The fastest TMDS clock unscrambled, HDMI 1.4's.
pub const hdmi14_khz: u32 = 340_000;

/// The IEEE's numbers for HDMI's block and the HDMI Forum's, as the
/// block holds them, low byte first.
const oui_hdmi = [3]u8{ 0x03, 0x0C, 0x00 };
const oui_hdmi_forum = [3]u8{ 0xD8, 0x5D, 0xC4 };
/// The extended tags of the video capability block and of the Forum's
/// sink capability block (HF-SCDB), which carries what its vendor block
/// did, at the same places.
const ext_video_capability: u8 = 0x00;
const ext_hf_scdb: u8 = 0x79;

/// What the extension `extension` says of the sink; a DVI monitor's
/// nothing when there is none.
pub fn sinkOf(extension: ?*const Block) Sink {
    var sink: Sink = .{};
    const cea = extension orelse return sink;
    if (!isCea(cea) or cea[1] < 2) return sink;
    sink.audio = cea[3] & 0x40 != 0;
    const end = @min(@as(usize, cea[2]), 127);
    var at: usize = 4;
    while (at < end) {
        const tag = cea[at] >> 5;
        const length: usize = cea[at] & 0x1F;
        if (at + 1 + length > 127) break;
        const block = cea[at..][0 .. 1 + length];
        switch (tag) {
            // A vendor's block: HDMI's, its fastest TMDS clock in its
            // eighth byte, 5 MHz a step; the Forum's, in its sixth, and
            // its flags in the seventh.
            3 => if (length >= 3) {
                if (std.mem.eql(u8, block[1..4], &oui_hdmi)) {
                    sink.hdmi = true;
                    if (length >= 7 and block[7] != 0) sink.max_tmds_khz = @max(sink.max_tmds_khz, @as(u32, block[7]) * 5000);
                } else if (std.mem.eql(u8, block[1..4], &oui_hdmi_forum)) {
                    forumCaps(&sink, block);
                }
            },
            7 => if (length >= 2) switch (block[1]) {
                ext_video_capability => sink.quant_selectable = block[2] & 0x40 != 0,
                ext_hf_scdb => forumCaps(&sink, block),
                else => {},
            },
            else => {},
        }
        at += 1 + length;
    }
    return sink;
}

/// The HDMI Forum's capabilities from its vendor block or its sink
/// capability block, which hold them at the same places: the fastest
/// TMDS character rate in the sixth byte, 5 MHz a step, and SCDC_Present
/// in the seventh's top bit.
fn forumCaps(sink: *Sink, block: []const u8) void {
    sink.forum = true;
    if (block.len < 7) return;
    if (block[5] != 0) sink.max_tmds_khz = @as(u32, block[5]) * 5000;
    sink.scdc = block[6] & 0x80 != 0;
}

const std = @import("std");

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

/// The EDID of a portable 15.6" 1080p monitor, as the VisionFive 2 read
/// it: established 720x400, 640x480, 800x600 and 1024x768; standard
/// 1920x1080 three times, 1440x900, 1400x1050, 1280x1024, 1280x960 and
/// 1280x720; 1080p60 in full with the vertical sync a line early, named
/// "Display"; an extension with VICs 3, 4 and 16 and 1080p60 again.
pub const portable_1080p = [2]Block{
    .{
        0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00, 0x09, 0xe5, 0x56, 0x25, 0x01, 0x01, 0x01, 0x01,
        0x11, 0x22, 0x01, 0x03, 0x80, 0x23, 0x13, 0x78, 0x3e, 0xb4, 0x15, 0xa6, 0x55, 0x4d, 0x9a, 0x27,
        0x0f, 0x50, 0x54, 0xa1, 0x08, 0x00, 0xd1, 0xc0, 0xd1, 0xc0, 0xd1, 0xc0, 0x95, 0x00, 0x90, 0x40,
        0x81, 0x80, 0x81, 0x40, 0x81, 0xc0, 0x02, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40, 0x58, 0x2c,
        0x35, 0x00, 0x58, 0xc2, 0x10, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x00, 0xfc, 0x00, 0x44, 0x69, 0x73,
        0x70, 0x6c, 0x61, 0x79, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x00, 0x00, 0x00, 0xff, 0x00, 0x64,
        0x65, 0x6d, 0x6f, 0x73, 0x65, 0x74, 0x2d, 0x31, 0x0a, 0x20, 0x30, 0x20, 0x00, 0x00, 0x00, 0xfd,
        0x00, 0x28, 0x41, 0x1e, 0x53, 0x12, 0x01, 0x0a, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x01, 0xc9,
    },
    .{
        0x02, 0x03, 0x26, 0xf2, 0x43, 0x03, 0x04, 0x10, 0xe2, 0x00, 0xd5, 0xe3, 0x05, 0xc3, 0x00, 0x23,
        0x09, 0x7f, 0x07, 0x83, 0x01, 0x00, 0x00, 0x67, 0x03, 0x0c, 0x00, 0x10, 0x00, 0x38, 0x3c, 0xe6,
        0x06, 0x05, 0x01, 0x72, 0x72, 0x00, 0x02, 0x3a, 0x80, 0x18, 0x71, 0x38, 0x2d, 0x40, 0x58, 0x2c,
        0x35, 0x00, 0x58, 0xc2, 0x10, 0x00, 0x00, 0x1e, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x36,
    },
};

test "the portable monitor's blocks are whole, its name and preferred mode read" {
    try testing.expect(isFirst(&portable_1080p[0]));
    try testing.expect(valid(&portable_1080p[0]));
    try testing.expect(valid(&portable_1080p[1]));
    try testing.expect(isCea(&portable_1080p[1]));
    var monitor_name: [14]u8 = undefined;
    name(&portable_1080p[0], &monitor_name);
    try testing.expectEqualStrings("Display", monitor_name[0..7]);
    try testing.expectEqual(@as(u8, 0), monitor_name[7]);

    const preferred = detailed(&portable_1080p[0], 54).?;
    try testing.expectEqual(@as(u32, 1920), preferred.width);
    try testing.expectEqual(@as(u32, 1080), preferred.height);
    try testing.expectEqual(@as(u32, 148_500), preferred.pixel_khz);
    try testing.expectEqual(@as(u32, 88), preferred.h_front);
    try testing.expectEqual(@as(u32, 44), preferred.h_sync);
    try testing.expectEqual(@as(u32, 148), preferred.h_back);
    try testing.expectEqual(@as(u32, 3), preferred.v_front);
    try testing.expectEqual(@as(u32, 5), preferred.v_sync);
    try testing.expectEqual(@as(u32, 37), preferred.v_back);
    try testing.expect(preferred.hsync_high and preferred.vsync_high);
    try testing.expectEqual(@as(u32, 60), preferred.hz());
    // CEA's 1080p60 by its totals, though the sync lies a line earlier.
    try testing.expectEqual(@as(u8, 16), vicOf(&preferred));
    // The name and the range limits are not timings.
    try testing.expectEqual(@as(?Timing, null), detailed(&portable_1080p[0], 72));
    try testing.expectEqual(@as(?Timing, null), detailed(&portable_1080p[0], 108));
    var timings: [10]Timing = undefined;
    try testing.expectEqual(@as(usize, 2), detailedTimings(&portable_1080p[0], &portable_1080p[1], &timings));
}

test "what the portable monitor names, and what it does not" {
    const first = &portable_1080p[0];
    const cea = &portable_1080p[1];
    try testing.expect(takes(first, cea, .{ .width = 1920, .height = 1080, .vic = 16 }));
    try testing.expect(takes(first, cea, .{ .width = 1440, .height = 900 }));
    try testing.expect(takes(first, cea, .{ .width = 1400, .height = 1050 }));
    try testing.expect(takes(first, cea, .{ .width = 1280, .height = 1024 }));
    try testing.expect(takes(first, cea, .{ .width = 1280, .height = 720, .vic = 4 }));
    try testing.expect(takes(first, cea, .{ .width = 1024, .height = 768 }));
    try testing.expect(takes(first, cea, .{ .width = 800, .height = 600 }));
    try testing.expect(takes(first, cea, .{ .width = 640, .height = 480, .vic = 1 }));
    try testing.expect(takes(first, cea, .{ .width = 720, .height = 400, .refresh_hz = 70 }));
    try testing.expect(takes(first, cea, .{ .width = 720, .height = 480, .vic = 3 }));
    try testing.expect(!takes(first, cea, .{ .width = 720, .height = 480, .vic = 2 }));
    try testing.expect(!takes(first, cea, .{ .width = 1920, .height = 1080, .refresh_hz = 50, .vic = 31 }));
    try testing.expect(!takes(first, cea, .{ .width = 1280, .height = 720, .refresh_hz = 50, .vic = 19 }));
    try testing.expect(!takes(first, cea, .{ .width = 3840, .height = 2160, .refresh_hz = 30, .vic = 95 }));
    try testing.expect(!takes(first, cea, .{ .width = 1600, .height = 900 }));
    try testing.expect(!takes(first, null, .{ .width = 720, .height = 480, .vic = 3 }));
}

test "the standard modes are timed as the standards have them" {
    for (&known) |*mode| {
        const refresh = mode.hz();
        try testing.expect(refresh == 60 or refresh == 50 or refresh == 30 or refresh == 25 or refresh == 24);
    }
    try testing.expectEqual(@as(u32, 2200), knownMode(1920, 1080, 60).?.htotal());
    try testing.expectEqual(@as(u32, 1125), knownMode(1920, 1080, 60).?.vtotal());
    try testing.expectEqual(@as(u32, 2640), knownMode(1920, 1080, 50).?.htotal());
    try testing.expectEqual(@as(u32, 4400), knownMode(3840, 2160, 30).?.htotal());
    try testing.expectEqual(@as(u32, 1344), knownMode(1024, 768, 60).?.htotal());
    try testing.expectEqual(@as(?Timing, null), knownMode(1920, 1200, 60));
}

test "the portable monitor is an HDMI sink with sound, to 300 MHz" {
    const sink = sinkOf(&portable_1080p[1]);
    try testing.expect(sink.hdmi);
    try testing.expect(sink.audio);
    try testing.expect(sink.quant_selectable);
    try testing.expect(!sink.scdc);
    try testing.expectEqual(@as(u32, 300_000), sink.max_tmds_khz);
    try testing.expectEqual(@as(u32, 300_000), sink.mostKhz());
    // Without an extension, a DVI monitor, to HDMI 1.4's clock.
    const dvi = sinkOf(null);
    try testing.expect(!dvi.hdmi and !dvi.audio);
    try testing.expectEqual(hdmi14_khz, dvi.mostKhz());
}

test "an HDMI 2.0 monitor's Forum block: 600 MHz, scrambled" {
    var cea: Block = @splat(0);
    cea[0] = 0x02;
    cea[1] = 0x03;
    cea[3] = 0x40;
    // HDMI's block, then the Forum's: version 1, 120 x 5 MHz, SCDC.
    const blocks = [_]u8{ 0x65, 0x03, 0x0C, 0x00, 0x10, 0x00, 0x67, 0xD8, 0x5D, 0xC4, 0x01, 0x78, 0x80 };
    @memcpy(cea[4..][0..blocks.len], &blocks);
    cea[2] = 4 + blocks.len;
    var sink = sinkOf(&cea);
    try testing.expect(sink.hdmi and sink.audio and sink.scdc);
    try testing.expectEqual(@as(u32, 600_000), sink.mostKhz());
    // The same in the sink capability block, an extended tag.
    const scdb = [_]u8{ 0xE6, 0x79, 0x00, 0x00, 0x01, 0x78, 0x80 };
    @memset(cea[4..], 0);
    @memcpy(cea[4..][0..scdb.len], &scdb);
    cea[2] = 4 + scdb.len;
    sink = sinkOf(&cea);
    try testing.expect(!sink.hdmi and sink.scdc);
    try testing.expectEqual(@as(u32, 600_000), sink.mostKhz());
    // Without SCDC no more than 340 MHz.
    cea[10] = 0;
    try testing.expectEqual(hdmi14_khz, sinkOf(&cea).mostKhz());
}

test "a native video code counts as its number" {
    var cea: Block = @splat(0);
    cea[0] = 0x02;
    cea[2] = 8;
    cea[4] = 2 << 5 | 3;
    cea[5] = 0x90; // 16, native
    cea[6] = 0x5F; // 95: no native bit above 64
    cea[7] = 0x02;
    try testing.expect(videoCodes(&cea, 16));
    try testing.expect(videoCodes(&cea, 95));
    try testing.expect(videoCodes(&cea, 2));
    try testing.expect(!videoCodes(&cea, 4));
}
