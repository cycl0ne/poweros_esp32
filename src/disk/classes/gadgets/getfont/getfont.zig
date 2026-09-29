// SPDX-License-Identifier: MIT
//! getfont.gadget: a font, named or asked for.
//!
//! A field with a button beside it. The field shows the font's name and
//! size and the button opens asl.library's font requester; what is
//! picked goes into the field, and a program reads `GETFONT_TextAttr`
//! back or hears it through the gadget's `ICA_TARGET`.
//!
//! Everything the gadget does it does as `sdk/libs/gadgets/getclass.zig` writes it: this file
//! says which requester the button opens and where the attributes are.

const sdk = @import("sdk");
const gfo = sdk.gadgets.getfont;
const _get = sdk.gadgets.getclass;

const Class = _get.Library(.{
    .name = gfo.GETFONT_CLASS,
    .kind = .font,
    .dummy = gfo.GETFONT_Dummy,
});

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = Class.Made;
comptime {
    _ = Library;
}
