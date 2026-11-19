// SPDX-License-Identifier: MIT
//! The pixels every call works on: a view's rows, and a colour weighted
//! by its alpha for mixing and back.
//!
//! A weighted colour is four numbers on one scale, 0 to 255 x 255: the
//! alpha times 255, and each channel times the alpha. Sums and averages
//! of weighted colours mix as the eye expects - a see-through pixel adds
//! to the see-through and to nothing else - and `unweighed` divides the
//! alpha out again. A weighted colour kept in a pixel between two passes
//! is that scale divided by 255 (`packWeighed`), alpha and channels a
//! byte each.

const sdk = @import("sdk");
const paintfx = sdk.paintfx;

pub const Weighed = [4]u32;

/// A view that can be worked on: something in it, rows no shorter than
/// its width.
pub fn usable(view: *const paintfx.Pixels) bool {
    return view.width != 0 and view.height != 0 and view.pitch >= view.width;
}

/// The pixels of the row `y`.
pub fn row(view: *const paintfx.Pixels, y: u32) []u32 {
    return view.pixels[@as(usize, y) * view.pitch ..][0..view.width];
}

/// `pixel` weighted by its alpha.
pub fn weighed(pixel: u32) Weighed {
    const alpha = pixel >> 24;
    return .{ alpha * 255, (pixel >> 16 & 0xFF) * alpha, (pixel >> 8 & 0xFF) * alpha, (pixel & 0xFF) * alpha };
}

/// A weighted colour as a pixel again, rounded; see-through when its
/// alpha rounds to none.
pub fn unweighed(colour: Weighed) u32 {
    const alpha = (colour[0] + 127) / 255;
    if (alpha == 0) return 0;
    // The channel is the weighted one over the alpha: c·a / a, with the
    // alpha still on the 255 scale.
    const whole = colour[0];
    var pixel: u32 = @as(u32, @min(alpha, 255)) << 24;
    inline for (1..4) |place| {
        const channel = @min((@as(u64, colour[place]) * 255 + whole / 2) / whole, 255);
        pixel |= @as(u32, @intCast(channel)) << @intCast(8 * (3 - place));
    }
    return pixel;
}

/// A weighted colour kept in a pixel: each number over 255, rounded.
pub fn packWeighed(colour: Weighed) u32 {
    var pixel: u32 = 0;
    inline for (0..4) |place| pixel |= @as(u32, @min((colour[place] + 127) / 255, 255)) << @intCast(8 * (3 - place));
    return pixel;
}

/// A pixel `packWeighed` made, on the weighted scale again.
pub fn unpackWeighed(pixel: u32) Weighed {
    return .{ (pixel >> 24) * 255, (pixel >> 16 & 0xFF) * 255, (pixel >> 8 & 0xFF) * 255, (pixel & 0xFF) * 255 };
}

/// `value` held to a byte.
pub fn byte(value: i32) u32 {
    return @intCast(@max(0, @min(255, value)));
}
