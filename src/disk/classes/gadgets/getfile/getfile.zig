// SPDX-License-Identifier: MIT
//! getfile.gadget: the name of a file, typed or asked for.
//!
//! A field with a button beside it. The field holds the whole path and
//! the button opens asl.library's file requester; what is picked goes
//! into the field, and a program reads it back or hears it through the
//! gadget's `ICA_TARGET`.
//!
//! Everything the gadget does it does as `sdk/libs/gadgets/getclass.zig` writes it: this file
//! says which requester the button opens and where the attributes are.

const sdk = @import("sdk");
const gf = sdk.gadgets.getfile;
const _get = sdk.gadgets.getclass;

const Class = _get.Library(.{
    .name = gf.GETFILE_CLASS,
    .kind = .file,
    .dummy = gf.GETFILE_Dummy,
});

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = Class.Made;
comptime {
    _ = Library;
}
