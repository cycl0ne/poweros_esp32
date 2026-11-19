// SPDX-License-Identifier: MIT
//! SharpenPixels: an unsharp mask - each pixel's difference from a blur
//! of its neighbourhood added to it.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const paintfx = sdk.paintfx;
const PaintFXBase = @import("../paintfx_base.zig").PaintFXBase;
const _pixels = @import("../pixels/_pixels.zig");
const _filter = @import("_filter.zig");

/// Sharpens pixels: each moved away from the blur of the pixels round
/// it, by `amount` percent of the difference.
///
/// SYNOPSIS:
/// ```zig
/// fn SharpenPixels(base: *PaintFXBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, amount: u32, radius: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `from`: the pixels to sharpen.
/// - `into`: where the sharpened pixels go, as large as `from`; it may be
///   `from` itself.
/// - `amount`: how much of the difference is added, in percent, up to
///   1000; 0 copies.
/// - `radius`: the blur the pixels are compared with, as `BlurPixels`
///   takes it: 1 or 2 sharpens edges, 10 and more brings out texture
///   and local contrast.
///
/// RESULT:
/// 0, or `ERROR_NO_FREE_STORE` when there was no memory for the blurred
/// copy - `into` is as it was then - or `ERROR_BAD_NUMBER` when `into`
/// is not `from`'s size.
///
/// BEHAVIOR:
/// `from` is blurred into a copy of the call's own; then each channel of
/// each pixel becomes `c + (c - blurred) · amount / 100`, held to 0 to
/// 255. The alpha stays `from`'s.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not from an interrupt.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pixels stay the caller's. The blurred copy, four bytes a pixel of
/// `from`, is the call's and freed before it answers.
///
/// NOTES:
/// A radius of 0 is taken as 1.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BlurPixels`, `AdjustColours`
///
/// EXAMPLES:
/// ```zig
/// const view = paintfx.Pixels{ .pixels = pixels, .width = 640, .height = 480, .pitch = 640 };
/// _ = fx.SharpenPixels(&view, &view, 150, 1); // the edges
/// _ = fx.SharpenPixels(&view, &view, 40, 16); // the texture
/// ```
pub fn SharpenPixels(base: *PaintFXBase, from: *const paintfx.Pixels, into: *const paintfx.Pixels, amount: u32, radius: u32) i32 {
    if (!_pixels.usable(from) or !_pixels.usable(into)) return 0;
    if (into.width != from.width or into.height != from.height) return dos.ERROR_BAD_NUMBER;
    const sys = base.sys_base;
    const width = from.width;
    const height = from.height;
    const strength: i32 = @intCast(@min(amount, 1000));
    if (strength == 0) {
        if (into.pixels != from.pixels) {
            var y: u32 = 0;
            while (y < height) : (y += 1) @memcpy(_pixels.row(into, y), _pixels.row(from, y));
        }
        return 0;
    }
    const memory = sys.AllocVec(@as(usize, width) * height * 4, exec.MEMF_ANY) orelse return dos.ERROR_NO_FREE_STORE;
    defer sys.FreeVec(memory);
    const blurred = paintfx.Pixels{ .pixels = @ptrCast(@alignCast(memory)), .width = width, .height = height, .pitch = width };
    if (!_filter.blur(sys, from, &blurred, @max(radius, 1))) return dos.ERROR_NO_FREE_STORE;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        for (_pixels.row(into, y), _pixels.row(from, y), _pixels.row(&blurred, y)) |*pixel, plain, soft| {
            var made: u32 = plain & 0xFF000000;
            inline for (0..3) |place| {
                const shift: u5 = @intCast(16 - 8 * place);
                const level: i32 = @intCast(plain >> shift & 0xFF);
                const around: i32 = @intCast(soft >> shift & 0xFF);
                made |= _pixels.byte(level + @divTrunc((level - around) * strength, 100)) << shift;
            }
            pixel.* = made;
        }
    }
    return 0;
}
