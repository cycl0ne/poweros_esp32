// SPDX-License-Identifier: MPL-2.0
//! The board's pointer as the pipe's own cursor: fetched by the hub
//! that reads the picture and laid over its pixels by the scaler behind
//! it, so the picture never holds it.
//!
//! **The image** is rtg.library's in `bgra32` - ARGB, clear where the
//! picture shows through and covering fully where it does not - copied
//! into one of two images of the device's memory, 64 pixels a row, and
//! the cursor told to read that one: its address, its size, ARGB with
//! its alpha multiplied in, the rows fetched in chunks as its width
//! takes them (hubp2_cursor_set_attributes), and the scaler's cursor
//! told the same format, without a curve of its own - the firmware's
//! planes pass through every curve unchanged (dpp3_set_cursor_attributes).
//!
//! **Its place** is the image's top left on the picture, as the library
//! gives it: the cursor at it, and where that is off the picture to the
//! left or above, at 0 with its hot spot moved in by as much, so that
//! its image starts as far before the picture's edge; wholly off, it is
//! not shown. The hub starts fetching its rows that many reference
//! cycles into a line as the image's left is pixels into it
//! (hubp2_cursor_set_position, dcn10_build_cursor_pos_update_params).
//!
//! **A mirrored picture** (`mode.writeTurn`) has the pointer turned with
//! it, as the library would lay it into the picture. The cursor's place
//! is in the surface's order and goes with the fetcher's turn as a pixel
//! of the picture does - on an axis mirrored, at the picture's length
//! less one less itself - while its image is laid on the glass as it is,
//! rightwards and down from there, its hot spot taken off on the glass:
//! as this engine shows it, a place's image found on the glass by its
//! checksum (`C:test/Gpu MIRROR`). So on each axis mirrored the image is
//! copied reversed, and the place is where its far edge lies in the
//! surface, on the glass its first pixel; where that is off the glass,
//! at the glass's edge with its hot spot moved in by as much. Where the
//! picture is mirrored left to right, its rows are fetched from the
//! line's start.
//!
//! What the cursor is told is written with the output's cursor locked
//! (mpc1_cursor_lock), so that the pipe's next update takes all of it or
//! none.

const sdk = @import("sdk");
const rtg = sdk.rtg;
const reg = sdk.hardware.mmio.reg;
const dcn = @import("dcn.zig");

/// The largest image, each way, and the bytes of one of the two.
pub const side = 64;
pub const image_bytes = side * side * 4;

/// The hub's cursor, a fetcher's stride apart: its control, its image's
/// address, its size, its place, its hot spot and where its fetch
/// starts; and the request settings it is fetched by.
const cursor_control = 0x0678;
const cursor_address = 0x0679;
const cursor_address_high = 0x067a;
const cursor_size = 0x067b;
const cursor_position = 0x067c;
const cursor_hot_spot = 0x067d;
const cursor_fetch_start = 0x067f;
const cursor_settings = 0x065c;
const fetcher_stride = 0xdc;

/// The scaler's cursor, a scaler's stride apart.
const scaler_cursor_control = 0x0cf1;
const scaler_stride = 0x16b;

/// Each output's cursor lock, in the blender's registers.
const cursor_lock = 0x0513;
const cursor_lock_stride = 5;

/// The hub cursor's control: shown, ARGB with its alpha multiplied in,
/// rows 64 pixels apart, the rows fetched a chunk at a time.
const cursor_on: u32 = 1 << 0;
const mode_shift = 8;
const mode_mask: u32 = 0x7 << mode_shift;
const premultiplied: u32 = 2;
const pitch_mask: u32 = 0x3 << 16;
const pitch_64: u32 = 0;
const chunk_shift = 24;
const chunk_mask: u32 = 0x1f << chunk_shift;
const chunk_8_lines: u32 = 3;
const chunk_16_lines: u32 = 4;
const high_mask: u32 = 0xffff;
/// Its request settings: no shift of when its rows are fetched, and a
/// chunk's request asked for as the vendor asks.
const settings_kept: u32 = 0xffff_0000;
const chunk_adjust: u32 = 3 << 8;

/// The scaler cursor's control: shown, its format, no expansion, no
/// curve of its own.
const scaler_on: u32 = 1 << 0;
const scaler_expansion: u32 = 1 << 1;
const scaler_curve: u32 = 1 << 3;
const scaler_mode_shift = 4;
const scaler_mode_mask: u32 = 0x7 << scaler_mode_shift;

/// What the cursor is told: where its image is, how large, the image's
/// top left on the picture, whether it is shown, and the pixel clock its
/// fetch is timed by.
pub const Cursor = struct {
    address: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    left: i32 = 0,
    top: i32 = 0,
    shown: bool = false,
    pixel_hz: u32 = 0,
    /// How the picture is mirrored, about each axis.
    mirror_x: bool = false,
    mirror_y: bool = false,
};

/// The axes the image is copied reversed on: each one the picture is
/// mirrored about, since the cursor lays it on the glass as it is.
pub const Reversed = struct { x: bool, y: bool };

pub fn reversedOf(mirror_x: bool, mirror_y: bool) Reversed {
    return .{ .x = mirror_x, .y = mirror_y };
}

/// The registers' words for a place: the cursor's place, its hot spot,
/// where its fetch starts in reference cycles, and whether any of it is
/// on the picture `width` by `height`.
pub const Place = struct {
    position: u32,
    hot_spot: u32,
    fetch_start: u32,
    seen: bool,
};

/// The hub's reference, in Hz: the crystal halved, as `mode.zig` has it.
const reference_hz: u64 = 24_000_000;

pub fn placeOf(cursor: Cursor, width: u32, height: u32) Place {
    const left: i64 = cursor.left;
    const top: i64 = cursor.top;
    const seen = cursor.width != 0 and cursor.height != 0 and
        left < width and top < height and left + cursor.width > 0 and top + cursor.height > 0;
    const across = axisOf(left, cursor.width, width, cursor.mirror_x);
    const down = axisOf(top, cursor.height, height, cursor.mirror_y);
    const from_left = @max(left, 0);
    const fetch: u64 = if (cursor.pixel_hz == 0 or cursor.mirror_x) 0 else @as(u64, @intCast(from_left)) * reference_hz / cursor.pixel_hz;
    return .{
        .position = (across.at & 0x3fff) << 16 | (down.at & 0x3fff),
        .hot_spot = across.hot << 16 | down.hot,
        .fetch_start = @intCast(@min(fetch, 0x1fff)),
        .seen = seen and cursor.shown,
    };
}

/// The cursor's place and hot spot on one axis `length` long, for an
/// image `size` long starting at `start` in the surface: where its first
/// pixel on the glass is - its start, or on an axis mirrored where its
/// far edge goes - with its hot spot 0; where that is off the glass, at
/// the glass's edge with its hot spot moved in by as much. The place is
/// in the surface's order, the glass's mirrored on that axis.
fn axisOf(start: i64, size: u32, length: u32, mirrored: bool) struct { at: u32, hot: u32 } {
    const glass = if (mirrored) @as(i64, length) - start - size else start;
    const first = @max(glass, 0);
    const place = if (mirrored) @as(i64, length) - 1 - first else first;
    return .{ .at = @intCast(@max(place, 0)), .hot = @intCast(@min(@max(-glass, 0), side - 1)) };
}

/// The chunk of rows fetched at a time for an image `width` across.
fn chunkOf(width: u32) u32 {
    return if (width <= 32) chunk_16_lines else chunk_8_lines;
}

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.block) + offset) * 4);
}

fn blenderAt(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.blender) + offset) * 4);
}

/// Whether the board's cursor can be had: the output's lock is in the
/// blender's registers.
pub fn reached(engine: dcn.Engine) bool {
    return engine.blender != 0;
}

/// The image `image` copied into `into` - one of the two images, of
/// `image_bytes` - its rows 64 pixels apart and the rest clear, reversed
/// on the axes `reversed` says, and the writes sent on to the device's
/// memory: its width and height as the cursor takes them.
pub fn copyImage(into: [*]u8, image: *const rtg.RtgPointerImage, reversed: Reversed) struct { width: u32, height: u32 } {
    @memset(into[0..image_bytes], 0);
    const width = @min(image.width, side);
    const height = @min(image.height, side);
    var row: u32 = 0;
    while (row < height) : (row += 1) {
        const to_row = if (reversed.y) height - 1 - row else row;
        const from = image.pixels[row * image.pitch ..][0 .. width * 4];
        const to = into[to_row * side * 4 ..][0 .. width * 4];
        if (!reversed.x) {
            @memcpy(to, from);
            continue;
        }
        var column: u32 = 0;
        while (column < width) : (column += 1) {
            @memcpy(to[(width - 1 - column) * 4 ..][0..4], from[column * 4 ..][0..4]);
        }
    }
    sdk.hardware.barrier.full();
    return .{ .width = width, .height = height };
}

/// The part of a pipe's surface its cursor is laid over: from (`x`, `y`)
/// on, `width` by `height` - the picture's whole surface, or the part of
/// a plane's surface on the glass, the cursor's place then from that
/// part's top left.
pub const View = struct { x: u32 = 0, y: u32 = 0, width: u32, height: u32 };

/// The cursor of the hub `fetcher` and its scaler, laid over output
/// `output`'s picture where the pipe shows `view`, told `cursor`: its
/// place worked out on the part shown, and the viewport's start added,
/// the cursor's place being in the surface's coordinates.
pub fn write(engine: dcn.Engine, fetcher: u32, output: u32, cursor: Cursor, view: View) void {
    if (!reached(engine)) return;
    const place = placeOf(cursor, view.width, view.height);
    const shown = place.seen and cursor.address != 0;
    const lock = blenderAt(engine, cursor_lock + output * cursor_lock_stride);
    lock.* = 1;
    defer lock.* = 0;
    const hub = fetcher * fetcher_stride;
    if (cursor.address != 0) {
        at(engine, hub + cursor_address_high).* = @truncate(cursor.address >> 32 & high_mask);
        at(engine, hub + cursor_address).* = @truncate(cursor.address);
        at(engine, hub + cursor_size).* = cursor.width << 16 | cursor.height;
        const settings = at(engine, hub + cursor_settings);
        settings.* = (settings.* & settings_kept) | chunk_adjust;
    }
    const control = at(engine, hub + cursor_control);
    var hub_control = control.* & ~(mode_mask | pitch_mask | chunk_mask | cursor_on);
    hub_control |= premultiplied << mode_shift | pitch_64 | chunkOf(cursor.width) << chunk_shift;
    if (shown) hub_control |= cursor_on;
    control.* = hub_control;
    at(engine, hub + cursor_position).* = place.position + (view.x << 16 | view.y);
    at(engine, hub + cursor_hot_spot).* = place.hot_spot;
    at(engine, hub + cursor_fetch_start).* = place.fetch_start;
    const scaler = at(engine, fetcher * scaler_stride + scaler_cursor_control);
    var scaler_control = scaler.* & ~(scaler_mode_mask | scaler_expansion | scaler_curve | scaler_on);
    scaler_control |= premultiplied << scaler_mode_shift;
    if (shown) scaler_control |= scaler_on;
    scaler.* = scaler_control;
}

/// The cursor of the hub `fetcher` and its scaler off: the pipe lays
/// none, as a film's pipe does - the vendor's for a frame of video.
pub fn off(engine: dcn.Engine, fetcher: u32) void {
    at(engine, fetcher * fetcher_stride + cursor_control).* &= ~cursor_on;
    at(engine, fetcher * scaler_stride + scaler_cursor_control).* &= ~scaler_on;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "the cursor's place: on the picture, off its top left edge, wholly off" {
    const at_2560: u32 = 241_500_000;
    // In the middle: there, no hot spot, its fetch 100 pixels in.
    const middle = placeOf(.{ .width = 32, .height = 32, .left = 100, .top = 50, .shown = true, .pixel_hz = at_2560 }, 2560, 1440);
    try testing.expectEqual(@as(u32, 100 << 16 | 50), middle.position);
    try testing.expectEqual(@as(u32, 0), middle.hot_spot);
    try testing.expectEqual(@as(u32, 100 * 24_000_000 / 241_500_000), middle.fetch_start);
    try testing.expect(middle.seen);
    // Partly off the left and the top: at 0, the hot spot moved in.
    const corner = placeOf(.{ .width = 32, .height = 32, .left = -5, .top = -7, .shown = true, .pixel_hz = at_2560 }, 2560, 1440);
    try testing.expectEqual(@as(u32, 0), corner.position);
    try testing.expectEqual(@as(u32, 5 << 16 | 7), corner.hot_spot);
    try testing.expect(corner.seen);
    // Wholly off, or off the right and the bottom: not seen.
    try testing.expect(!placeOf(.{ .width = 32, .height = 32, .left = -32, .top = 0, .shown = true }, 2560, 1440).seen);
    try testing.expect(!placeOf(.{ .width = 32, .height = 32, .left = 2560, .top = 0, .shown = true }, 2560, 1440).seen);
    try testing.expect(!placeOf(.{ .width = 32, .height = 32, .left = 0, .top = 1440, .shown = true }, 2560, 1440).seen);
    try testing.expect(placeOf(.{ .width = 32, .height = 32, .left = 2559, .top = 1439, .shown = true }, 2560, 1440).seen);
    // Mirrored left to right: its far edge, a pixel's mirror away from
    // the glass's first, fetched from the line's start - the box's
    // engine put a 12 wide image told 300 at 2259 on the glass.
    const across = placeOf(.{ .width = 12, .height = 19, .left = 300 - 11, .top = 200, .shown = true, .pixel_hz = at_2560, .mirror_x = true }, 2560, 1440);
    try testing.expectEqual(@as(u32, 300 << 16 | 200), across.position);
    try testing.expectEqual(@as(u32, 0), across.hot_spot);
    try testing.expectEqual(@as(u32, 0), across.fetch_start);
    // Top to bottom, its far edge off the glass's top: at the glass's
    // edge - the surface's last row - its hot spot moved in.
    const down = placeOf(.{ .width = 32, .height = 32, .left = 10, .top = 1430, .shown = true, .mirror_y = true }, 2560, 1440);
    try testing.expectEqual(@as(u32, 10 << 16 | 1439), down.position);
    try testing.expectEqual(@as(u32, 0 << 16 | 22), down.hot_spot);
    try testing.expect(down.seen);
    // Both, at the surface's top left: its far corner.
    const both = placeOf(.{ .width = 32, .height = 32, .left = -5, .top = -7, .shown = true, .mirror_x = true, .mirror_y = true }, 2560, 1440);
    try testing.expectEqual(@as(u32, 26 << 16 | 24), both.position);
    try testing.expectEqual(@as(u32, 0), both.hot_spot);
    try testing.expect(both.seen);
    try testing.expectEqual(Reversed{ .x = true, .y = false }, reversedOf(true, false));
    try testing.expectEqual(Reversed{ .x = false, .y = true }, reversedOf(false, true));
    // Hidden, or without an image.
    try testing.expect(!placeOf(.{ .width = 32, .height = 32, .left = 10, .top = 10 }, 2560, 1440).seen);
    try testing.expect(!placeOf(.{ .left = 10, .top = 10, .shown = true }, 2560, 1440).seen);
}

test "the cursor's image: rows 64 pixels apart, the rest clear; its fetch's chunks" {
    var pixels: [3 * 8]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @intCast(index + 1);
    // Two pixels a row, rows 8 bytes apart, three rows.
    const image: rtg.RtgPointerImage = .{ .pixels = &pixels, .mask = &pixels, .width = 2, .height = 3, .pitch = 8, .mask_pitch = 1, .hot_x = 0, .hot_y = 0, .format = .bgra32 };
    var into: [image_bytes]u8 = @splat(0xEE);
    const size = copyImage(&into, &image, .{ .x = false, .y = false });
    try testing.expectEqual(@as(u32, 2), size.width);
    try testing.expectEqual(@as(u32, 3), size.height);
    try testing.expectEqualSlices(u8, pixels[0..8], into[0..8]);
    try testing.expectEqualSlices(u8, pixels[8..16], into[side * 4 ..][0..8]);
    try testing.expectEqual(@as(u8, 0), into[8]);
    try testing.expectEqual(@as(u8, 0), into[3 * side * 4]);
    try testing.expectEqual(@as(u8, 0), into[image_bytes - 1]);
    // Reversed both ways: the last row's last pixel first.
    const turned = copyImage(&into, &image, .{ .x = true, .y = true });
    try testing.expectEqual(@as(u32, 2), turned.width);
    try testing.expectEqualSlices(u8, pixels[16 + 4 .. 16 + 8], into[0..4]);
    try testing.expectEqualSlices(u8, pixels[16..20], into[4..8]);
    try testing.expectEqualSlices(u8, pixels[4..8], into[2 * side * 4 ..][0..4]);
    try testing.expectEqual(chunk_16_lines, chunkOf(32));
    try testing.expectEqual(chunk_8_lines, chunkOf(33));
    try testing.expectEqual(chunk_8_lines, chunkOf(64));
}
