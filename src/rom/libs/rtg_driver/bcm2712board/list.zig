// SPDX-License-Identifier: MPL-2.0
//! The BCM2712's display list: what its video scaler (HVS) reads the
//! picture and the planes over it by.
//!
//! The list is in the HVS's own memory: a plane after another, each a
//! few words - its format and size, where it lies on the display, the
//! context the HVS keeps for it, the picture's address in two words, its
//! pitch - and an end word. The HVS walks it every frame and composes
//! the planes as it goes, each read through a piece of its prefetch
//! memory (UPM) of its own. The list stays where it is once the port
//! runs (`bcm2712.start` writes it); what changes is words of it,
//! rewritten in an order that never leaves a plane half told: the
//! picture's address for a flip (`show`), a word's bits for the picture
//! read backwards (`mirror`), and the cursor's and the overlay's planes
//! whole (`cursor`, `overlay`), each an image of the driver's own shown,
//! hidden or moved.
//!
//! The words are vc4_hvs.c's and vc4_plane.c's, as the BCM2712's HVS
//! takes them.

const sdk = @import("sdk");
const bcm2712 = @import("bcm2712.zig");

const rtg = sdk.rtg;

const CTL0_VALID: u32 = 1 << 30;

const CTL0_NEXT_SHIFT = 24;

const CTL0_ALPHA_MASK_FIXED: u32 = 3 << 18;

const CTL0_UNITY: u32 = 1 << 15;

const CTL0_ORDER_ARGB: u32 = 2 << 13;

const PIXEL_FORMAT_RGBA8888: u32 = 7;

const CTL2_PREMULT: u32 = 1 << 29;

const CTL2_ALPHA_MIX: u32 = 1 << 28;

const CTL2_ALPHA_SHIFT = 4;

const ALPHA_OPAQUE: u32 = 0xFFF;

const CONTEXT: u32 = 0xC0C0_C0C0;

const PTR0_UPM_BASE_SHIFT = 16;

const PTR0_UPM_HANDLE_SHIFT = 10;

pub const plane_words = 9;

const W_POS0 = 1;

const W_CTL2 = 2;

const W_POS2 = 3;

const W_PTR0 = 5;

const W_PTR1 = 6;

const W_PTR2 = 7;

/// A plane read backwards: each row (in its position word), and the rows
/// (in its first pointer word).
const POS0_HFLIP: u32 = 1 << 15;

const PTR0_VFLIP: u32 = 1 << 31;

/// The HVS's prefetch memory, in units of 256 bytes, two lines a plane:
/// the picture's from 0 - room for a row of 4K - then the cursor's and
/// the overlay's, each as a handle of its own.
const UPM_UNIT = 256;

/// A plane of its picture at `address`, `width` by `height` pixels at
/// (x, y), rows `pitch` bytes apart, in the UPM from `upm` as handle
/// `handle`: with alpha its pixels' own (the cursor's), or opaque (the
/// picture's), and seen or not; each row read from its right end, the
/// rows from the bottom up - `address` then the last row's.
pub const Plane = struct {
    address: usize,
    pitch: u32,
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,
    upm: u32,
    handle: u32,
    alpha: bool = false,
    seen: bool = true,
    hflip: bool = false,
    vflip: bool = false,
};

/// The plane's nine words (vc6_plane_mode_set, vc6_plane_allocate_upm).
pub fn planeOf(plane: Plane) [plane_words]u32 {
    const mask = if (plane.alpha) 0 else CTL0_ALPHA_MASK_FIXED;
    const ctl2 = if (plane.seen) CTL2_PREMULT | ALPHA_OPAQUE << CTL2_ALPHA_SHIFT else CTL2_PREMULT | CTL2_ALPHA_MIX;
    return .{
        CTL0_VALID | plane_words << CTL0_NEXT_SHIFT | mask | CTL0_UNITY | CTL0_ORDER_ARGB | PIXEL_FORMAT_RGBA8888,
        (plane.y & 0x1FFF) << 16 | (if (plane.hflip) POS0_HFLIP else 0) | (plane.x & 0x1FFF),
        ctl2,
        (plane.height - 1) << 16 | (plane.width - 1),
        CONTEXT,
        (if (plane.vflip) PTR0_VFLIP else 0) | plane.upm << PTR0_UPM_BASE_SHIFT | plane.handle << PTR0_UPM_HANDLE_SHIFT | upper(plane.address),
        @truncate(plane.address),
        plane.pitch,
        bcm2712.CTL0_END,
    };
}

/// An address's bits above the low 32, as a plane's first pointer word
/// carries them: eight, as far as the HVS reaches.
fn upper(address: usize) u32 {
    return @as(u32, @truncate(@as(u64, address) >> 32)) & 0xFF;
}

/// The units of UPM a plane of rows `pitch` bytes apart takes: two lines
/// of 32-byte words, with one to spare (vc6_upm_size).
pub fn upmUnits(pitch: u32) u32 {
    const line = (pitch + 62) / 32 * 32;
    return (line * 2 + UPM_UNIT - 1) / UPM_UNIT;
}

pub fn writePlane(port: *const bcm2712.Port, first: u32, plane: Plane) void {
    for (planeOf(plane), 0..) |value, i| bcm2712.word(port, first + @as(u32, @intCast(i))).* = value;
}

/// How the picture is turned: mirrored left to right, top to bottom.
pub const Turn = struct { x: bool = false, y: bool = false };

/// An image laid over the picture - the cursor, the overlay: `width` by
/// `height` pixels of ARGB at `address`, rows `pitch` bytes apart, with
/// its piece of the UPM.
pub const Image = struct {
    address: usize,
    pitch: u32,
    width: u32,
    height: u32,
    upm: u32,
    handle: u32,
};

/// The plane of `image`, its top left at (left, top) on a picture
/// `width` by `height` that is turned `turn`: where the turned picture
/// has it, cut to the glass, and read backwards where the picture is.
/// An image wholly off the glass is a hidden pixel.
pub fn imagePlaneOf(image: Image, left: i32, top: i32, width: u32, height: u32, turn: Turn, seen: bool) Plane {
    const w: i32 = @intCast(image.width);
    const h: i32 = @intCast(image.height);
    const glass_w: i32 = @intCast(width);
    const glass_h: i32 = @intCast(height);
    // Its rectangle on the glass, and the part of that on it.
    const box_x = if (turn.x) glass_w - left - w else left;
    const box_y = if (turn.y) glass_h - top - h else top;
    const x = @max(0, box_x);
    const y = @max(0, box_y);
    const right = @min(glass_w, box_x + w);
    const bottom = @min(glass_h, box_y + h);
    var plane: Plane = .{
        .address = image.address,
        .pitch = image.pitch,
        .width = 1,
        .height = 1,
        .upm = image.upm,
        .handle = image.handle,
        .alpha = true,
        .seen = false,
        .hflip = turn.x,
        .vflip = turn.y,
    };
    if (x >= right or y >= bottom) return plane;
    // Columns and rows of the rectangle cut off at the glass's left and
    // top, which are the image's last ones where it is turned that way.
    const cut_x = x - box_x;
    const cut_y = y - box_y;
    const shown_w = right - x;
    const shown_h = bottom - y;
    const column = if (turn.x) w - cut_x - shown_w else cut_x;
    const row = if (turn.y) h - 1 - cut_y else cut_y;
    plane.address = image.address + @as(usize, @intCast(row)) * image.pitch + @as(usize, @intCast(column)) * 4;
    plane.x = @intCast(x);
    plane.y = @intCast(y);
    plane.width = @intCast(shown_w);
    plane.height = @intCast(shown_h);
    plane.seen = seen;
    return plane;
}

/// The picture's plane's size and pitch, and how it is turned, as its
/// words have them.
fn pictureWidth(port: *const bcm2712.Port) u32 {
    return (bcm2712.word(port, bcm2712.picture_plane + W_POS2).* & 0x1FFF) + 1;
}

fn pictureHeight(port: *const bcm2712.Port) u32 {
    return (bcm2712.word(port, bcm2712.picture_plane + W_POS2).* >> 16 & 0x1FFF) + 1;
}

fn turnOf(port: *const bcm2712.Port) Turn {
    return .{
        .x = bcm2712.word(port, bcm2712.picture_plane + W_POS0).* & POS0_HFLIP != 0,
        .y = bcm2712.word(port, bcm2712.picture_plane + W_PTR0).* & PTR0_VFLIP != 0,
    };
}

/// Where the picture's plane starts reading a picture at `address`: its
/// last row where it reads from the bottom up.
fn readFrom(port: *const bcm2712.Port, address: usize, turn: Turn) usize {
    if (!turn.y) return address;
    return address + @as(usize, pictureHeight(port) - 1) * bcm2712.word(port, bcm2712.picture_plane + W_PTR2).*;
}

fn pointPicture(port: *const bcm2712.Port, address: usize, turn: Turn) void {
    const from = readFrom(port, address, turn);
    const flags = bcm2712.word(port, bcm2712.picture_plane + W_PTR0).* & ~(PTR0_VFLIP | 0xFF);
    bcm2712.word(port, bcm2712.picture_plane + W_PTR0).* = flags | (if (turn.y) PTR0_VFLIP else 0) | upper(from);
    bcm2712.word(port, bcm2712.picture_plane + W_PTR1).* = @truncate(from);
}

/// `picture` shown from now on, a buffer of the mode the display is in,
/// as the library describes one: the picture's plane's address
/// rewritten. The HVS takes it up as it next fetches.
pub fn show(port: *const bcm2712.Port, picture: *const rtg.RtgBitMap) void {
    const pixels = picture.pixels orelse return;
    if (!bcm2712.running(port)) return;
    pointPicture(port, @intFromPtr(pixels), turnOf(port));
}

/// The picture mirrored as `turn` says from the next frame on, the one
/// at `address` - the one shown - read backwards. The cursor and the
/// overlay are turned with it when they are next written.
pub fn mirror(port: *const bcm2712.Port, address: usize, turn: Turn) void {
    if (!bcm2712.running(port)) return;
    const position = bcm2712.word(port, bcm2712.picture_plane + W_POS0).* & ~POS0_HFLIP;
    bcm2712.word(port, bcm2712.picture_plane + W_POS0).* = position | (if (turn.x) POS0_HFLIP else 0);
    pointPicture(port, address, turn);
}

/// An image's plane rewritten - its words but the first, the address
/// last, so that the HVS does not fetch a new image at an old size.
fn writeImage(port: *const bcm2712.Port, first: u32, plane: Plane) void {
    const words = planeOf(plane);
    for ([_]usize{ W_CTL2, W_POS0, W_POS2, W_PTR2, W_PTR0, W_PTR1 }) |i| bcm2712.word(port, first + @as(u32, @intCast(i))).* = words[i];
}

/// The largest cursor image, each way.
pub const cursor_side = 64;

/// The cursor's plane: the image at `address` (`cursor_side` square, or
/// half that when `small`), its hot spot at (x, y) on the picture, shown
/// or not, turned as the picture is.
pub fn cursor(port: *const bcm2712.Port, address: usize, small: bool, hot_x: u32, hot_y: u32, x: u32, y: u32, shown: bool) void {
    if (!bcm2712.running(port)) return;
    const side: u32 = if (small) cursor_side / 2 else cursor_side;
    const image = Image{ .address = address, .pitch = side * 4, .width = side, .height = side, .upm = bcm2712.upm_cursor, .handle = 1 };
    const left = @as(i32, @intCast(x)) - @as(i32, @intCast(hot_x));
    const top = @as(i32, @intCast(y)) - @as(i32, @intCast(hot_y));
    writeImage(port, bcm2712.cursor_plane, imagePlaneOf(image, left, top, pictureWidth(port), pictureHeight(port), turnOf(port), shown));
}

/// The largest overlay, each way: rtg's.
pub const overlay_side = 160;

/// The overlay's plane: `width` by `height` pixels of the image at
/// `address`, rows `overlay_side` pixels apart, its top left at (left,
/// top) on the picture, shown or not, turned as the picture is.
pub fn overlay(port: *const bcm2712.Port, address: usize, width: u32, height: u32, left: i32, top: i32, shown: bool) void {
    if (!bcm2712.running(port)) return;
    const image = Image{
        .address = address,
        .pitch = overlay_side * 4,
        .width = @max(width, 1),
        .height = @max(height, 1),
        .upm = bcm2712.upm_overlay,
        .handle = 2,
    };
    writeImage(port, bcm2712.overlay_plane, imagePlaneOf(image, left, top, pictureWidth(port), pictureHeight(port), turnOf(port), shown and width != 0 and height != 0));
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the BCM2712's display list: a picture's plane, and the cursor's cut to the picture" {
    const words = planeOf(.{ .address = 0x3000_0000, .pitch = 7680, .width = 1920, .height = 1080, .upm = 0, .handle = 0 });
    try testing.expectEqualSlices(u32, &.{
        0x4900_0000 | 3 << 18 | 1 << 15 | 2 << 13 | 7,
        0,
        0x2000_FFF0,
        1079 << 16 | 1919,
        0xC0C0_C0C0,
        0,
        0x3000_0000,
        7680,
        0x8000_0000,
    }, &words);
    // The cursor at the top left, its hot spot 4 pixels in: 4 columns and
    // rows of it are off the picture.
    const big = Image{ .address = 0x1000, .pitch = 256, .width = 64, .height = 64, .upm = bcm2712.upm_cursor, .handle = 1 };
    const small = Image{ .address = 0x1000, .pitch = 128, .width = 32, .height = 32, .upm = bcm2712.upm_cursor, .handle = 1 };
    const corner = imagePlaneOf(big, -4, -4, 1920, 1080, .{}, true);
    try testing.expectEqual(@as(usize, 0x1000 + 4 * 256 + 4 * 4), corner.address);
    try testing.expectEqual(@as(u32, 0), corner.x);
    try testing.expectEqual(@as(u32, 60), corner.width);
    try testing.expectEqual(@as(u32, 60), corner.height);
    try testing.expectEqual(@as(u32, 256), corner.pitch);
    const cursor_words = planeOf(corner);
    try testing.expectEqual(@as(u32, 0), cursor_words[0] & 3 << 18);
    try testing.expectEqual(@as(u32, 128 << 16 | 1 << 10), cursor_words[5]);
    // At the bottom right, only the hot spot's pixel on it.
    const edge = imagePlaneOf(small, 1919, 1079, 1920, 1080, .{}, true);
    try testing.expectEqual(@as(u32, 1), edge.width);
    try testing.expectEqual(@as(u32, 1), edge.height);
    try testing.expectEqual(@as(u32, 1919), edge.x);
    // Hidden: alpha 0, mixed.
    try testing.expectEqual(@as(u32, 0x3000_0000), planeOf(imagePlaneOf(big, 10, 10, 1920, 1080, .{}, false))[2]);
    // Wholly off the picture: a hidden pixel.
    const gone = imagePlaneOf(big, -64, 10, 1920, 1080, .{}, true);
    try testing.expect(!gone.seen and gone.width == 1 and gone.height == 1);
    // A row of 1920 takes 61 units of UPM, of 4K 121, the cursor's 3:
    // both fit before the cursor's at 128.
    try testing.expectEqual(@as(u32, 61), upmUnits(7680));
    try testing.expectEqual(@as(u32, 121), upmUnits(15360));
    try testing.expectEqual(@as(u32, 3), upmUnits(256));
}

test "the BCM2712's display list turned: the picture and an image read backwards" {
    const flipped = planeOf(.{ .address = 0x3000_0000 + 1079 * 7680, .pitch = 7680, .width = 1920, .height = 1080, .upm = 0, .handle = 0, .hflip = true, .vflip = true });
    try testing.expectEqual(@as(u32, 1 << 15), flipped[1]);
    try testing.expectEqual(@as(u32, 1 << 31), flipped[5]);
    try testing.expectEqual(@as(u32, 0x3000_0000 + 1079 * 7680), flipped[6]);

    // Mirrored left to right, a 64-pixel cursor at (100, 50) is at
    // 1920 - 164 on the glass, read from its own first column backwards.
    const big = Image{ .address = 0x1000, .pitch = 256, .width = 64, .height = 64, .upm = bcm2712.upm_cursor, .handle = 1 };
    const across = imagePlaneOf(big, 100, 50, 1920, 1080, .{ .x = true }, true);
    try testing.expectEqual(@as(u32, 1920 - 164), across.x);
    try testing.expectEqual(@as(u32, 50), across.y);
    try testing.expectEqual(@as(usize, 0x1000), across.address);
    try testing.expect(across.hflip and !across.vflip and across.width == 64);
    // At the picture's left edge, 4 columns off: on the glass it is 4
    // columns off the right, which are the image's first 4 - so it is
    // read from column 4, 60 wide.
    const left_edge = imagePlaneOf(big, -4, 50, 1920, 1080, .{ .x = true }, true);
    try testing.expectEqual(@as(u32, 1920 - 60), left_edge.x);
    try testing.expectEqual(@as(u32, 60), left_edge.width);
    try testing.expectEqual(@as(usize, 0x1000 + 4 * 4), left_edge.address);
    // At the picture's right edge, 4 columns off: on the glass 4 off the
    // left, the image's last 4 - read from column 0.
    const right_edge = imagePlaneOf(big, 1920 - 60, 50, 1920, 1080, .{ .x = true }, true);
    try testing.expectEqual(@as(u32, 0), right_edge.x);
    try testing.expectEqual(@as(u32, 60), right_edge.width);
    try testing.expectEqual(@as(usize, 0x1000), right_edge.address);
    // Upside down, 4 rows off the picture's top: on the glass 4 off the
    // bottom, the image's first 4; read from row 63 upwards, 60 rows.
    const top_edge = imagePlaneOf(big, 100, -4, 1920, 1080, .{ .y = true }, true);
    try testing.expectEqual(@as(u32, 1080 - 60), top_edge.y);
    try testing.expectEqual(@as(u32, 60), top_edge.height);
    try testing.expectEqual(@as(usize, 0x1000 + 63 * 256), top_edge.address);
    try testing.expect(top_edge.vflip);
    // 4 rows off the picture's bottom: on the glass 4 off the top, the
    // image's last 4; read from row 59 upwards.
    const bottom_edge = imagePlaneOf(big, 100, 1080 - 60, 1920, 1080, .{ .y = true }, true);
    try testing.expectEqual(@as(u32, 0), bottom_edge.y);
    try testing.expectEqual(@as(u32, 60), bottom_edge.height);
    try testing.expectEqual(@as(usize, 0x1000 + 59 * 256), bottom_edge.address);
}
