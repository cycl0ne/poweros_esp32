// SPDX-License-Identifier: MIT
//! GetImageMemoryRequirements: what an image needs of its memory.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _image = @import("_image.zig");

/// What the image needs of the memory it is bound into.
///
/// SYNOPSIS:
/// ```zig
/// fn GetImageMemoryRequirements(base: *FacetBase, device: *facet.Device, image: *facet.Image, requirements: *facet.MemoryRequirements) void
/// ```
///
/// SINCE: 1.0. LVO -100.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `image` - the image.
/// - `requirements` - where they are written.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// An offset aligned to a cache line, 64 bytes. A texture's size is its
/// levels in blocks, an 8888 texel at 8 bytes; rows' are their pitch, the
/// width rounded up to a cache line, times the height. A depth attachment
/// may be in any memory type, the lazily allocated one too, and nothing
/// of its memory is touched; every other image needs a type with memory
/// behind it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `requirements` is the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `BindImageMemory`, `AllocateMemory`
///
/// EXAMPLES:
/// ```zig
/// var needs: facet.MemoryRequirements = undefined;
/// fb.GetImageMemoryRequirements(device, picture, &needs);
/// ```
pub fn GetImageMemoryRequirements(base: *FacetBase, device: *facet.Device, image: *facet.Image, requirements: *facet.MemoryRequirements) void {
    _ = base;
    _ = device;
    requirements.* = _image.requirements(_objects.of(_image.Image, image));
}
