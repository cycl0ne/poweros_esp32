// SPDX-License-Identifier: MIT
//! getdevice.gadget: a unit of a device, typed or asked for.
//!
//! A field with a button beside it. The field holds the device's name
//! and the unit, and the button opens asl.library's device requester; what
//! is picked goes into the field, and a program reads it back or hears it
//! through the gadget's `ICA_TARGET`.
//!
//! Everything the gadget does it does as `sdk/libs/gadgets/getclass.zig` writes it: this file
//! says which requester the button opens and where the attributes are.

const sdk = @import("sdk");
const gd = sdk.gadgets.getdevice;
const _get = sdk.gadgets.getclass;

const Class = _get.Library(.{
    .name = gd.GETDEVICE_CLASS,
    .kind = .device,
    .dummy = gd.GETDEVICE_Dummy,
    .version = 1,
    .revision = 0,
    .date = "12.10.2026",
});

/// The library the class is in; its ROM tag is `Library.resident_tag`.
pub const Library = Class.Made;
comptime {
    _ = Library;
}
