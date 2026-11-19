// SPDX-License-Identifier: MIT
//! paintfx.library's types: Paint's effects and transforms, worked on
//! pixels in memory.
//!
//! The library is Paint's own and lives in its drawer: Paint opens it by
//! its path, `PAINTFXPATH`, the first time it changes colours, blurs,
//! sharpens, scales or turns something, and ramlib loads it in Paint's
//! process, where `PROGDIR:` is that drawer.
//!
//! Every call works on `Pixels`: rows of pixels `0xAARRGGBB`, a `u32`
//! each, `pitch` pixels from the start of one row to the start of the
//! next. A view of part of a larger picture is its first pixel, its own
//! width and height, and the larger picture's width as the pitch.
//!
//! Colours that are mixed - a blur, a smooth scale, a turn - are weighted
//! by their alpha, so a see-through pixel lends no colour to its
//! neighbours, only its see-through.

pub const PAINTFXNAME = "paintfx.library";
/// Where Paint opens it from: its own drawer.
pub const PAINTFXPATH = "PROGDIR:Libs/paintfx.library";

/// Pixels to read or to write: `height` rows of `width` pixels from
/// `pixels` on, `pitch` pixels from one row's start to the next's (at
/// least `width`).
pub const Pixels = extern struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
    pitch: u32,
};

/// The colour changes `AdjustColours` makes; 0 for each changes nothing.
/// They are made in the order of the fields.
pub const Adjust = extern struct {
    /// 0 to 100: the haze lifted - the level the darkest channel of
    /// the picture's pixels keeps taken away, that much of it, and the
    /// rest stretched over the whole range.
    dehaze: u32 = 0,
    /// -100 to 100 each: the channel towards none or towards full - cyan
    /// to red, magenta to green, yellow to blue.
    red: i32 = 0,
    green: i32 = 0,
    blue: i32 = 0,
    /// -100 to 100: darker or lighter, by up to half the range.
    brightness: i32 = 0,
    /// -100 to 100: all grey at -100, two levels a channel at 100.
    contrast: i32 = 0,
    /// -100 to 100: grey at -100, twice as strong at 100.
    saturation: i32 = 0,
    /// -180 to 180: the hue turned, in degrees.
    hue: i32 = 0,
    /// 0 to 100: towards the browns of an old photograph.
    sepia: u32 = 0,
    /// 0 to 100: towards the opposite colour; at 50 everything is grey.
    invert: u32 = 0,
};

/// How `ScalePixels` and `TransformPixels` take a pixel's colour.
/// The nearest pixel: hard edges, the picture's colours only.
pub const PFXSCALE_HARD: u32 = 0;
/// Smooth: shrinking, the average of the pixels a new one covers;
/// growing and turning, a mix of the four nearest.
pub const PFXSCALE_SMOOTH: u32 = 1;

/// One whole in the 16.16 numbers of a `Matrix`.
pub const MATRIX_ONE: i32 = 1 << 16;

/// Where `TransformPixels` takes each pixel from: the centre of the
/// pixel (x, y) of `into`, at (x + 1/2, y + 1/2), is taken from
/// (`xx`·x' + `xy`·y' + `dx`, `yx`·x' + `yy`·y' + `dy`) in `from`, x' and
/// y' being that centre - every number 16.16, `MATRIX_ONE` a whole.
pub const Matrix = extern struct {
    xx: i32 = MATRIX_ONE,
    xy: i32 = 0,
    yx: i32 = 0,
    yy: i32 = MATRIX_ONE,
    dx: i32 = 0,
    dy: i32 = 0,
};
