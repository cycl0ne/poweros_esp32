// SPDX-License-Identifier: MIT
//! picture.datatype: what every still picture is, whatever file it came
//! out of.
//!
//! A format's class - ILBM, PNG, GIF, JPEG - reads its file and hands
//! the pixels over row by row (`PDTM_WRITEPIXELARRAY`) in whatever shape
//! it has them: 8-bit numbers into a palette, 24-bit colour, or colour
//! with coverage. The superclass keeps them, draws them, scales them to
//! whatever room it is given, and hands them back to anyone who asks
//! (`PDTM_READPIXELARRAY`). A format class therefore holds no pixels of
//! its own and knows nothing about drawing.
//!
//! **The picture is kept as pens** - one `graphics.Pen` a pixel,
//! 0xAARRGGBB - whatever it arrived as. The screens are true colour, so
//! that is the one shape that can be drawn in a single call at any size
//! and with any coverage, and converting once when the file is read is
//! cheaper than converting every time it is drawn. `PDTA_SourceMode`
//! still says what the file held, for a program that wants to know and
//! for saving it again.
//!
//! What it costs is four bytes a pixel: a picture of a million pixels is
//! four megabytes. **A picture larger than the machine can hold is kept
//! smaller** - half, a quarter or an eighth of each side - rather than
//! refused, because a picture that can be looked at is worth more than
//! one that cannot. `PDTA_BitMapHeader` then says the size that is
//! kept, which is the size everything that draws, scrolls or saves it
//! works in; `PDTA_SourceWidth` and `PDTA_SourceHeight` say what the
//! file held, and `PDTA_ShrunkBy` by how much the two differ.
//!
//! The scroll units of datatypesclass are pixels here
//! (`DTA_VertUnit` 1), so a scroller gadget driven from `DTA_TopVert`
//! scrolls the picture a pixel at a time.

const utility = @import("../utility/utility.zig");
const graphics = @import("../graphics/graphics.zig");
const classusr = @import("../intuition/classusr.zig");
const datatypesclass = @import("datatypesclass.zig");

/// What a program opens, and the class it then asks for.
pub const PICTURE_LIBRARY = "datatypes/picture.datatype";
pub const PICTUREDTCLASS = "picture.datatype";

pub const PDTA_Dummy = datatypesclass.DTA_Dummy + 200;

/// The picture's shape (`*BitMapHeader`): width, height, depth and how
/// it is masked. Made, set and read; setting it is what gives the object
/// its size, and the pixels are kept from then on.
pub const PDTA_BitMapHeader = PDTA_Dummy + 1;
/// The palette (`[*]ColorRegister`), for a picture that came as numbers
/// into one. Made, set and read; kept for saving, not for drawing.
pub const PDTA_ColorRegisters = PDTA_Dummy + 3;
/// How many of them there are.
pub const PDTA_NumColors = PDTA_Dummy + 9;
/// Where the picture's hot spot is (`*graphics.Point`), for a picture
/// that is a pointer or a brush.
pub const PDTA_Grab = PDTA_Dummy + 14;
/// The screen it will be shown on (`*intuition.Screen`).
pub const PDTA_Screen = PDTA_Dummy + 12;
/// `PBPAFMT_`: the shape the file held, which is what it is saved as.
/// Made, set and read.
pub const PDTA_SourceMode = PDTA_Dummy + 20;
/// The picture itself: `[*]graphics.Pen`, `PDTA_BytesPerRow` apart from
/// one row to the next. Read only, and only good while the object
/// lives.
pub const PDTA_Pixels = PDTA_Dummy + 21;
/// Bytes from one of its rows to the next. Read only.
pub const PDTA_BytesPerRow = PDTA_Dummy + 22;
/// Bool: the picture is drawn to fill the room it is given rather than
/// at its own size. False unless given, so that a picture is shown as
/// it is and scrolled.
pub const PDTA_Scale = PDTA_Dummy + 23;
/// What the file said the picture was, before it was shrunk to fit.
/// The same as the header's size for a picture that was not. Read only.
pub const PDTA_SourceWidth = PDTA_Dummy + 24;
pub const PDTA_SourceHeight = PDTA_Dummy + 25;
/// How much smaller than the file the kept picture is: 1, 2, 4 or 8.
/// Read only.
pub const PDTA_ShrunkBy = PDTA_Dummy + 26;

// --- what the pixels look like ----------------------------------------------

/// The shapes `PDTM_WRITEPIXELARRAY` and `PDTM_READPIXELARRAY` take and
/// answer in.
pub const PBPAFMT_RGB: u32 = 0;
pub const PBPAFMT_RGBA: u32 = 1;
pub const PBPAFMT_ARGB: u32 = 2;
/// Numbers into the palette `PDTA_ColorRegisters` names.
pub const PBPAFMT_LUT8: u32 = 3;
/// One byte a pixel, black to white.
pub const PBPAFMT_GREY8: u32 = 4;

/// How many bytes one pixel of a shape takes.
pub fn formatBytes(format: u32) u32 {
    return switch (format) {
        PBPAFMT_RGB => 3,
        PBPAFMT_RGBA, PBPAFMT_ARGB => 4,
        else => 1,
    };
}

// --- the methods ------------------------------------------------------------

pub const PDTM_Dummy: classusr.MethodID = 0x700;
/// Rows of pixels given to the object, which keeps them.
pub const PDTM_WRITEPIXELARRAY: classusr.MethodID = 0x701;
/// Rows of pixels taken back out of it.
pub const PDTM_READPIXELARRAY: classusr.MethodID = 0x702;
/// The picture made another size, once and for good.
pub const PDTM_SCALE: classusr.MethodID = 0x703;

/// `PDTM_WRITEPIXELARRAY` and `PDTM_READPIXELARRAY`: a rectangle of the
/// picture, in the caller's own shape.
pub const PdtBlitPixelArray = extern struct {
    method_id: classusr.MethodID = PDTM_WRITEPIXELARRAY,
    /// The rows, `bytes_per_row` apart, each pixel in `format`.
    pixel_data: [*]u8,
    /// `PBPAFMT_`.
    format: u32 = PBPAFMT_RGB,
    bytes_per_row: u32 = 0,
    /// Where in the picture the rectangle sits, and how big it is.
    left: u32 = 0,
    top: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

/// `PDTM_SCALE`: the picture itself made another size.
pub const PdtScale = extern struct {
    method_id: classusr.MethodID = PDTM_SCALE,
    new_width: u32 = 0,
    new_height: u32 = 0,
    flags: u32 = 0,
};

// --- what a file says about a picture ---------------------------------------

/// struct BitMapHeader: the shape of a picture, as IFF's `BMHD` chunk
/// holds it and as every format here is read into.
pub const BitMapHeader = extern struct {
    width: u16 = 0,
    height: u16 = 0,
    left: i16 = 0,
    top: i16 = 0,
    /// How many bits a pixel had in the file, for a program that wants
    /// to know; the picture itself is kept in colour.
    depth: u8 = 0,
    /// `msk`: how the file said which pixels are not there.
    masking: u8 = 0,
    /// `cmp`: how the file said its pixels were packed.
    compression: u8 = 0,
    pad: u8 = 0,
    /// The colour that stands for "not there" with `mskHasTransparentColor`.
    transparent: u16 = 0,
    /// How wide and tall a pixel is, as a ratio.
    x_aspect: u8 = 0,
    y_aspect: u8 = 0,
    page_width: i16 = 0,
    page_height: i16 = 0,
};

/// bmh_Masking.
pub const mskNone: u8 = 0;
pub const mskHasMask: u8 = 1;
pub const mskHasTransparentColor: u8 = 2;
pub const mskLasso: u8 = 3;
pub const mskHasAlpha: u8 = 4;

/// bmh_Compression.
pub const cmpNone: u8 = 0;
pub const cmpByteRun1: u8 = 1;

/// One colour of a palette, as a file holds it.
pub const ColorRegister = extern struct {
    red: u8 = 0,
    green: u8 = 0,
    blue: u8 = 0,
};

/// The IFF chunks a picture is made of.
pub const ID_ILBM = @import("../iffparse/iffparse.zig").MakeID("ILBM");
pub const ID_BMHD = @import("../iffparse/iffparse.zig").MakeID("BMHD");
pub const ID_BODY = @import("../iffparse/iffparse.zig").MakeID("BODY");
pub const ID_CMAP = @import("../iffparse/iffparse.zig").MakeID("CMAP");
pub const ID_CAMG = @import("../iffparse/iffparse.zig").MakeID("CAMG");
pub const ID_GRAB = @import("../iffparse/iffparse.zig").MakeID("GRAB");
