// SPDX-License-Identifier: MIT
//! jpeg.datatype's own attribute, beside picture.datatype's: which
//! decoder reads a file.
//!
//! On a machine with a JPEG codec (jpeg.resource) jpeg.datatype hands
//! the file to it when it takes the file and the decoded picture fits,
//! and decodes in software otherwise. JDTA_Decoder given at `OM_NEW`
//! chooses; asked with `OM_GET`, it says which one did.

const dtc = @import("datatypesclass.zig");

/// The class library, and the class it holds.
pub const JPEG_LIBRARY = "datatypes/jpeg.datatype";
pub const JPEGDTCLASS = "jpeg.datatype";

pub const JDTA_Dummy = dtc.DTA_Dummy + 1000;
/// u32. At `OM_NEW`, which decoder may read the file: JDEC_ANY (the
/// codec where it takes the file, else software), JDEC_SOFTWARE, or
/// JDEC_CODEC (the codec or no object). With `OM_GET`, which one did:
/// JDEC_SOFTWARE or JDEC_CODEC.
pub const JDTA_Decoder = JDTA_Dummy + 1;

pub const JDEC_ANY: u32 = 0;
pub const JDEC_SOFTWARE: u32 = 1;
pub const JDEC_CODEC: u32 = 2;
