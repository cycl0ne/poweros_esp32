// SPDX-License-Identifier: MIT
//! jpeg.resource: the chip's JPEG codec, decoding a file into pixels -
//! the ESP32-P4's; a machine without one has no jpeg.resource, and a
//! program decodes in software there (jpeg.datatype does).
//!
//! ExamineJPEG says what a file is and whether the codec takes it, and
//! what the picture will need; DecodeJPEG decodes it into a picture the
//! resource allocates, which FreeJPEGPicture gives back. One decode at a
//! time: a second caller waits for the first.
//!
//! The codec takes baseline files (SOF0) of 8-bit samples, grey or in
//! three components with their colour at full size or halved across, or
//! across and down (4:4:4, 4:2:2, 4:2:0), up to 16383 pixels either way;
//! two code tables of each kind and the quantization tables 0 to 3. The
//! colour is turned into red, green and blue on the way to memory, with
//! JFIF's full-range matrix.
//!
//! Get its base with OpenResource(JPEGNAME); its functions are in
//! sdk/interface/jpeg.zig.

/// The resource's name, for OpenResource.
pub const JPEGNAME = "jpeg.resource";

/// What ExamineJPEG and DecodeJPEG answer.
pub const JPEGERR_OK: u32 = 0;
/// It does not begin the way a JPEG does.
pub const JPEGERR_NOT_JPEG: u32 = 1;
/// It does, then says something the format does not allow, or ends early.
pub const JPEGERR_CORRUPT: u32 = 2;
/// Something the format allows and the codec does not take: a
/// progressive file, 12-bit or 16-bit tables, four components, another
/// sampling, a picture too large.
pub const JPEGERR_UNSUPPORTED: u32 = 3;
/// No memory for the picture.
pub const JPEGERR_NO_MEMORY: u32 = 4;
/// The codec stopped on the file, or did not finish in time.
pub const JPEGERR_FAILED: u32 = 5;
/// The codec cannot be used: its 2D-DMA channel is someone else's.
pub const JPEGERR_NO_ENGINE: u32 = 6;

/// How a file keeps its colour: grey only, or brightness and two colour
/// differences, those at full size, halved across, or halved across and
/// down.
pub const JPEGSAMP_GREY: u32 = 0;
pub const JPEGSAMP_444: u32 = 1;
pub const JPEGSAMP_422: u32 = 2;
pub const JPEGSAMP_420: u32 = 3;

/// A picture's pixels: three bytes each - blue, green, red, in that order
/// in memory - or one, grey.
pub const JPEGFMT_BGR24: u32 = 1;
pub const JPEGFMT_GREY8: u32 = 2;

/// What ExamineJPEG finds: the picture's size, how it keeps its colour,
/// and what DecodeJPEG will make of it - its format, the bytes from one
/// row to the next, and the bytes it will allocate.
pub const JPEGInfo = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    components: u32 = 0,
    sampling: u32 = 0,
    format: u32 = 0,
    pitch: u32 = 0,
    bytes: u32 = 0,
};

/// A picture DecodeJPEG made: `width` x `height` pixels from `pixels`
/// on, `pitch` bytes from one row to the next (the rows may be longer
/// than the picture is wide, and there may be more of them). The rest is
/// the resource's, for FreeJPEGPicture.
pub const JPEGPicture = extern struct {
    pixels: ?[*]u8 = null,
    pitch: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = 0,
    memory: ?*anyopaque = null,
    memory_size: u32 = 0,
};

/// The resource's base, with its functions.
pub const JpegBase = @import("../interface/jpeg.zig").JpegBase;
