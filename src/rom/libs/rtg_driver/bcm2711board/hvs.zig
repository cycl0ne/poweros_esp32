// SPDX-License-Identifier: MPL-2.0
//! The BCM2711's way to its first HDMI port as the VideoCore firmware lit
//! it (CHIP_BCM2711_HVS), as the Compute Module 4 has it: the hardware
//! video scaler (HVS), which reads the picture out of RAM through a display
//! list and composes its planes, and pixel valve 2, which times the HVS's
//! channel out to the HDMI0 controller.
//!
//! **The firmware keeps the mode.** It read the monitor's EDID, set the
//! HDMI0 controller, its PHY and pixel valve 2 going, and shows the
//! framebuffer it handed the kernel through the HVS: a display list of one
//! plane, on the channel that feeds the port (the part's PART_BusUnit).
//! Nothing of that is touched here but the list. A list of the driver's
//! own, in the HVS's list memory where the firmware keeps nothing - above
//! its lists, below the filter kernels it keeps at the top - is what the
//! channel is told to read instead: the picture as a plane, the overlay (a
//! dragged icon) as a second over it, the cursor as a third over both, and
//! the end. A plane is eight words at unity scale (vc4_plane.c's for the
//! HVS5): its control word, its position, its alpha, its size, the context
//! the HVS keeps, the picture's address, the address the HVS has read up
//! to, and its pitch. The picture's are the firmware's own plane's but for
//! the address and the pitch.
//!
//! The list stays where it is once the channel reads it: showing another
//! picture is its address rewritten in place, which the HVS takes up as it
//! starts its next frame (Linux's asynchronous flip), and an image's place
//! and size are its plane's words rewritten; a hidden image is a plane of
//! alpha 0. So a picture and the images change from different tasks
//! without a lock: they write different words.
//!
//! **A flip is taken** once the HVS has started a frame after the address
//! was written: its channel's status counts the frames, and the count read
//! after the write names the last frame that may have started with the
//! old address (`taken`). The frame interrupt comes at the end of a frame's
//! picture, which is near the HVS's next start but on no fixed side of it.
//!
//! The HVS names RAM by the VideoCore's bus address, the ARM's first GiB
//! at 0xC000_0000, so every picture is in that GiB - this board's MEMF_DMA
//! - and read out of RAM past the caches: XRGB8888, which is the library's
//! bgra32; the cursor and the overlay ARGB8888 with premultiplied alpha -
//! clear where it is 0 - as the board's image buffers have them.
//!
//! **Pixel valve 2** raises its interrupt at the start of each frame's
//! vertical front porch, which the firmware leaves off and which is the
//! board's frame interrupt here (`takeInterrupts`). Where its registers
//! are is the port's table (`sdk.hardware.bcm2711.HdmiPort`).
//!
//! **The firmware may take the channel back**, writing a list of its own -
//! a mode it sets again as a monitor is plugged in: `ours` says whether the
//! channel still reads this driver's list, and `start` makes it again. On
//! the way out (`stop`) the channel is given the firmware's list back.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;

/// Whether this is built for the Compute Module 4's chip, whose HVS this
/// drives. The driver is built for every chip, which picks its display at
/// run time; elsewhere nothing here touches a register.
const on_bcm2711 = sdk.hardware.chip == .a64v80;

/// The HVS's registers per channel: its display list's head and its
/// status, whose frame count goes up by one a frame (vc4_regs.h's
/// SCALER_DISPLISTx and SCALER_DISPSTATx).
const DISPLIST0 = 0x20;
const DISPSTAT0 = 0x48;
const DISPSTAT_STRIDE = 0x10;
const STAT_FRAMES_SHIFT = 12;
const STAT_FRAMES: u32 = 0x3F;
/// The list memory, 4096 words 0x4000 into the registers, and where this
/// driver's list starts in it.
const DLIST = 0x4000;
const dlist_words: u32 = 4096;
const list_start: u32 = 0xE00;

/// A plane's words, unity scale, linear RGBA8888 (vc4_plane_mode_set for
/// the HVS5).
const CTL0_END: u32 = 1 << 31;
const CTL0_VALID: u32 = 1 << 30;
const CTL0_SIZE_SHIFT = 24;
const CTL0_SIZE: u32 = 0x3F;
const CTL0_UNITY: u32 = 1 << 15;
const CTL0_ORDER_ARGB: u32 = 2 << 13;
const CTL0_RGB_EXPAND: u32 = 1 << 12;
const CTL0_ALPHA_EXPAND: u32 = 1 << 11;
const CTL0_FORMAT: u32 = 0x1F;
const PIXEL_FORMAT_RGBA8888: u32 = 7;
const CTL2_ALPHA_FIXED: u32 = 1 << 30;
const CTL2_PREMULT: u32 = 1 << 29;
const CTL2_ALPHA_MIX: u32 = 1 << 28;
const CTL2_ALPHA_SHIFT = 4;
const ALPHA_OPAQUE: u32 = 0xFFF;
const CONTEXT: u32 = 0xC0C0_C0C0;
pub const plane_words = 8;
/// Where each word is in a plane.
const W_CTL0 = 0;
const W_POS0 = 1;
const W_CTL2 = 2;
const W_POS2 = 3;
const W_PTR0 = 5;
const W_PITCH = 7;
/// The picture's plane first, the overlay's over it, the cursor's over
/// both, then the end.
const picture_plane = list_start;
const overlay_plane = list_start + plane_words;
const cursor_plane = list_start + 2 * plane_words;
const list_end = list_start + 3 * plane_words;

/// The ARM's first GiB as the VideoCore's bus names it, uncached.
const BUS_ALIAS: u32 = 0xC000_0000;
const FIRST_GIB: usize = 0x4000_0000;

/// Pixel valve 2, HDMI0's: its interrupts' switches and what they raised.
const PV_INTEN = 0x24;
const PV_INTSTAT = 0x28;
const PV_INT_VFP_START: u32 = 1 << 7;

/// The HVS as the firmware left it for the port, and the flip last made.
pub const Hvs = struct {
    /// The registers, as the part names them.
    base: usize,
    /// The channel that feeds the port, and the pixel valve that times it.
    channel: u32,
    pixel_valve: usize,
    /// The mode the firmware lit.
    width: u32,
    height: u32,
    /// Where the firmware's list starts, given back on the way out.
    firmware_list: u32,
    /// The frame count from which the last flip is taken.
    until: u32 = 0,
    /// Given back: the firmware's list is read again, for good.
    stopped: bool = false,
};

fn at(base: usize, offset: usize) *volatile u32 {
    return reg(base + offset);
}

fn head(hvs: *const Hvs) *volatile u32 {
    return reg(hvs.base + DISPLIST0 + @as(usize, hvs.channel) * 4);
}

fn word(hvs: *const Hvs, index: u32) *volatile u32 {
    return reg(hvs.base + DLIST + @as(usize, index) * 4);
}

/// The frames the channel has started, as its status counts them.
fn frames(hvs: *const Hvs) u32 {
    return reg(hvs.base + DISPSTAT0 + @as(usize, hvs.channel) * DISPSTAT_STRIDE).* >> STAT_FRAMES_SHIFT & STAT_FRAMES;
}

/// The bus address of `address`, which is in the ARM's first GiB.
fn busOf(address: usize) u32 {
    return BUS_ALIAS | @as(u32, @intCast(address & (FIRST_GIB - 1)));
}

/// The HVS the part describes, the firmware's list on `channel` showing a
/// picture `width` by `height`: one plane at unity scale, of 32 bits a
/// pixel. Null where it is not that - the firmware lit no picture there,
/// or not this one - and on any other chip. `pixel_valve` is the pixel
/// valve that times the channel.
pub fn find(base: usize, channel: u32, pixel_valve: usize, width: u32, height: u32) ?Hvs {
    if (!on_bcm2711 or base == 0 or pixel_valve == 0 or channel > 2) return null;
    if (width == 0 or height == 0 or width > 0x3FFF or height > 0xFFF) return null;
    var hvs = Hvs{ .base = base, .channel = channel, .pixel_valve = pixel_valve, .width = width, .height = height, .firmware_list = 0 };
    const first = head(&hvs).* & (dlist_words - 1);
    if (first == list_start or first + plane_words >= dlist_words) return null;
    const ctl0 = word(&hvs, first + W_CTL0).*;
    const shows = ctl0 & CTL0_VALID != 0 and ctl0 & CTL0_END == 0 and ctl0 & CTL0_UNITY != 0 and
        ctl0 >> CTL0_SIZE_SHIFT & CTL0_SIZE >= plane_words and ctl0 & CTL0_FORMAT == PIXEL_FORMAT_RGBA8888;
    if (!shows or word(&hvs, first + W_POS2).* != sizeOf(width, height)) return null;
    hvs.firmware_list = first;
    return hvs;
}

/// A plane's size word.
fn sizeOf(width: u32, height: u32) u32 {
    return (height & 0xFFF) << 16 | (width & 0x3FFF);
}

/// A plane of `width` by `height` pixels at `address`, rows `pitch` bytes
/// apart, its top left at (x, y) on the glass: opaque (the picture), or
/// with its pixels' own alpha, premultiplied (an image), seen or not.
pub const Plane = struct {
    address: usize,
    pitch: u32,
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,
    alpha: bool = false,
    seen: bool = true,
};

/// The plane's eight words.
pub fn planeOf(plane: Plane) [plane_words]u32 {
    const ctl2 = if (!plane.alpha)
        CTL2_ALPHA_FIXED | ALPHA_OPAQUE << CTL2_ALPHA_SHIFT
    else if (plane.seen)
        CTL2_PREMULT | ALPHA_OPAQUE << CTL2_ALPHA_SHIFT
    else
        CTL2_PREMULT | CTL2_ALPHA_MIX;
    return .{
        CTL0_VALID | plane_words << CTL0_SIZE_SHIFT | CTL0_UNITY | CTL0_ORDER_ARGB | CTL0_RGB_EXPAND | CTL0_ALPHA_EXPAND | PIXEL_FORMAT_RGBA8888,
        (plane.y & 0xFFF) << 16 | (plane.x & 0x3FFF),
        ctl2,
        sizeOf(plane.width, plane.height),
        CONTEXT,
        busOf(plane.address),
        CONTEXT,
        plane.pitch & 0xFFFF,
    };
}

fn writePlane(hvs: *const Hvs, first: u32, plane: Plane) void {
    for (planeOf(plane), 0..) |value, i| word(hvs, first + @as(u32, @intCast(i))).* = value;
}

/// The picture's plane: the whole glass, the picture at `address`.
fn picturePlane(hvs: *const Hvs, address: usize, pitch: u32) Plane {
    return .{ .address = address, .pitch = pitch, .width = hvs.width, .height = hvs.height };
}

/// A hidden image's plane: one clear pixel's worth, read from `address`.
fn hiddenPlane(address: usize) Plane {
    return .{ .address = address, .pitch = 4, .width = 1, .height = 1, .alpha = true, .seen = false };
}

/// The channel reading this driver's list from its next frame on: the
/// picture at `address`, rows `pitch` bytes apart, the overlay and the
/// cursor hidden until they are written; and pixel valve 2's interrupt on
/// at each frame's front porch.
pub fn start(hvs: *Hvs, address: usize, pitch: u32) void {
    if (!on_bcm2711) return;
    writePlane(hvs, picture_plane, picturePlane(hvs, address, pitch));
    writePlane(hvs, overlay_plane, hiddenPlane(address));
    writePlane(hvs, cursor_plane, hiddenPlane(address));
    word(hvs, list_end).* = CTL0_END;
    head(hvs).* = list_start;
    hvs.until = frames(hvs) +% 1 & STAT_FRAMES;
    hvs.stopped = false;
    at(hvs.pixel_valve, PV_INTSTAT).* = PV_INT_VFP_START;
    at(hvs.pixel_valve, PV_INTEN).* = at(hvs.pixel_valve, PV_INTEN).* | PV_INT_VFP_START;
}

/// Whether the channel reads this driver's list: false once the firmware
/// wrote its own, and once it was given back.
pub fn ours(hvs: *const Hvs) bool {
    if (!on_bcm2711 or hvs.stopped) return false;
    return head(hvs).* & (dlist_words - 1) == list_start;
}

/// The channel given the firmware's list back, from its next frame on,
/// and the frame interrupt off.
pub fn stop(hvs: *Hvs) void {
    if (!on_bcm2711) return;
    hvs.stopped = true;
    if (head(hvs).* & (dlist_words - 1) == list_start) head(hvs).* = hvs.firmware_list;
    at(hvs.pixel_valve, PV_INTEN).* = at(hvs.pixel_valve, PV_INTEN).* & ~PV_INT_VFP_START;
    at(hvs.pixel_valve, PV_INTSTAT).* = PV_INT_VFP_START;
}

/// The picture at `address` shown from the HVS's next frame on: the
/// picture's plane's address rewritten, and the frame from which it is
/// taken noted.
pub fn show(hvs: *Hvs, address: usize) void {
    if (!ours(hvs)) return;
    word(hvs, picture_plane + W_PTR0).* = busOf(address);
    hvs.until = frames(hvs) +% 1 & STAT_FRAMES;
}

/// Whether the HVS has started a frame since the last flip was made -
/// read the new picture, and no longer the old. True where the channel
/// does not read this driver's list: no frame of it will come.
pub fn taken(hvs: *const Hvs) bool {
    if (!ours(hvs)) return true;
    return reached(frames(hvs), hvs.until);
}

/// Whether the frame count `now` is at `until` or past it, the count
/// going round at 64.
fn reached(now: u32, until: u32) bool {
    return (now -% until) & STAT_FRAMES < (STAT_FRAMES + 1) / 2;
}

/// What pixel valve 2 raised since this was last asked, cleared: 0 when
/// the interrupt was not its.
pub fn takeInterrupts(hvs: *const Hvs) u32 {
    if (!on_bcm2711) return 0;
    const raised = at(hvs.pixel_valve, PV_INTSTAT).* & at(hvs.pixel_valve, PV_INTEN).*;
    if (raised != 0) at(hvs.pixel_valve, PV_INTSTAT).* = raised;
    return raised;
}

/// An image's plane rewritten - its words but the first, the address
/// last, so that the HVS does not fetch a new image at an old size.
fn writeImage(hvs: *const Hvs, first: u32, plane: Plane) void {
    const words = planeOf(plane);
    for ([_]usize{ W_CTL2, W_POS0, W_POS2, W_PITCH, W_PTR0 }) |i| word(hvs, first + @as(u32, @intCast(i))).* = words[i];
}

/// The plane of an image laid over the picture, `width` by `height`
/// pixels of ARGB at `address`, rows `pitch` bytes apart, its top left at
/// (left, top): the part of it on the glass, read from where that starts
/// in the image, and a hidden pixel where none of it is.
pub fn imagePlane(glass_width: u32, glass_height: u32, address: usize, pitch: u32, width: u32, height: u32, left: i32, top: i32, seen: bool) Plane {
    const x = @max(0, left);
    const y = @max(0, top);
    const right = @min(@as(i64, glass_width), @as(i64, left) + width);
    const bottom = @min(@as(i64, glass_height), @as(i64, top) + height);
    if (x >= right or y >= bottom) return hiddenPlane(address);
    const column: usize = @intCast(x - left);
    const row: usize = @intCast(y - top);
    return .{
        .address = address + row * pitch + column * 4,
        .pitch = pitch,
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(right - x),
        .height = @intCast(bottom - y),
        .alpha = true,
        .seen = seen,
    };
}

/// The largest cursor image, each way.
pub const cursor_side = 64;

/// The cursor's plane: the image at `address` (`cursor_side` square, or
/// half that when `small`), its hot spot at (x, y) on the picture, shown
/// or not.
pub fn cursor(hvs: *const Hvs, address: usize, small: bool, hot_x: u32, hot_y: u32, x: u32, y: u32, shown: bool) void {
    if (!ours(hvs)) return;
    const side: u32 = if (small) cursor_side / 2 else cursor_side;
    const left = @as(i32, @intCast(x)) - @as(i32, @intCast(hot_x));
    const top = @as(i32, @intCast(y)) - @as(i32, @intCast(hot_y));
    writeImage(hvs, cursor_plane, imagePlane(hvs.width, hvs.height, address, side * 4, side, side, left, top, shown));
}

/// The largest overlay, each way: rtg's.
pub const overlay_side = sdk.rtg.boards.RTG_OVERLAY_MAX;

/// The overlay's plane: `width` by `height` pixels of the image at
/// `address`, rows `overlay_side` pixels apart, its top left at (left,
/// top) on the picture, shown or not.
pub fn overlay(hvs: *const Hvs, address: usize, width: u32, height: u32, left: i32, top: i32, shown: bool) void {
    if (!ours(hvs)) return;
    const seen = shown and width != 0 and height != 0;
    writeImage(hvs, overlay_plane, imagePlane(hvs.width, hvs.height, address, overlay_side * 4, @max(width, 1), @max(height, 1), left, top, seen));
}

const std = @import("std");
const testing = std.testing;

test "the BCM2711's HVS: the picture's plane is the firmware's own" {
    // The plane the CM4's firmware writes for a 1920x1080 framebuffer at
    // 0x3E3CF000, rows 7680 bytes apart, as read from its list.
    const words = planeOf(.{ .address = 0x3E3C_F000, .pitch = 7680, .width = 1920, .height = 1080 });
    try testing.expectEqual(@as(u32, 0x4800_D807), words[W_CTL0]);
    try testing.expectEqual(@as(u32, 0), words[W_POS0]);
    try testing.expectEqual(@as(u32, 0x4000_FFF0), words[W_CTL2]);
    try testing.expectEqual(@as(u32, 0x0438_0780), words[W_POS2]);
    try testing.expectEqual(@as(u32, 0xFE3C_F000), words[W_PTR0]);
    try testing.expectEqual(@as(u32, 0x1E00), words[W_PITCH]);
}

test "the BCM2711's HVS: an image's plane, seen and hidden" {
    const seen = planeOf(.{ .address = 0x1000_0000, .pitch = 256, .x = 100, .y = 200, .width = 64, .height = 64, .alpha = true });
    try testing.expectEqual(@as(u32, 0x2000_FFF0), seen[W_CTL2]);
    try testing.expectEqual(@as(u32, 200 << 16 | 100), seen[W_POS0]);
    try testing.expectEqual(@as(u32, 64 << 16 | 64), seen[W_POS2]);
    try testing.expectEqual(@as(u32, 0xD000_0000), seen[W_PTR0]);
    const hidden = planeOf(hiddenPlane(0x1000_0000));
    try testing.expectEqual(@as(u32, 0x3000_0000), hidden[W_CTL2]);
    try testing.expectEqual(@as(u32, 1 << 16 | 1), hidden[W_POS2]);
}

test "the BCM2711's HVS: an image cut to the glass, and one wholly off it" {
    // 64x64 at (-10, 1070) on 1920x1080: 54 columns from its 11th, 10 rows.
    const cut = imagePlane(1920, 1080, 0x1000_0000, 256, 64, 64, -10, 1070, true);
    try testing.expectEqual(@as(usize, 0x1000_0000 + 10 * 4), cut.address);
    try testing.expectEqual(@as(u32, 0), cut.x);
    try testing.expectEqual(@as(u32, 1070), cut.y);
    try testing.expectEqual(@as(u32, 54), cut.width);
    try testing.expectEqual(@as(u32, 10), cut.height);
    try testing.expect(cut.seen);
    // From the top left: its rows from the 6th, its columns from the 4th.
    const corner = imagePlane(1920, 1080, 0x1000_0000, 256, 64, 64, -3, -5, true);
    try testing.expectEqual(@as(usize, 0x1000_0000 + 5 * 256 + 3 * 4), corner.address);
    try testing.expectEqual(@as(u32, 61), corner.width);
    try testing.expectEqual(@as(u32, 59), corner.height);
    // Past the right edge: a hidden pixel.
    const off = imagePlane(1920, 1080, 0x1000_0000, 256, 64, 64, 1920, 0, true);
    try testing.expect(!off.seen);
    try testing.expectEqual(@as(u32, 1), off.width);
}

test "the BCM2711's HVS: a flip is taken from the frame after it, the count going round" {
    try testing.expect(!reached(9, 10));
    try testing.expect(reached(10, 10));
    try testing.expect(reached(11, 10));
    // Made at frame 63: taken from 0 on.
    try testing.expect(!reached(63, 0));
    try testing.expect(reached(0, 0));
    try testing.expect(reached(1, 0));
}
