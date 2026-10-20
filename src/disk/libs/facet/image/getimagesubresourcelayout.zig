// SPDX-License-Identifier: MIT
//! GetImageSubresourceLayout: where a level of an image is in its memory.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Image = @import("_image.zig").Image;

/// Where a level of an image lies in its memory, and how its rows do.
///
/// SYNOPSIS:
/// ```zig
/// fn GetImageSubresourceLayout(base: *FacetBase, device: *facet.Device, image: *facet.Image, subresource: *const facet.ImageSubresource, layout: *facet.SubresourceLayout) void
/// ```
///
/// SINCE: 1.0. LVO -108.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `image` - the image.
/// - `subresource` - which level: 0 for an image in rows.
/// - `layout` - where its layout is written.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// For an image in rows - a linear image, and an attachment - the offset
/// is 0, `row_pitch` the bytes from one row to the next, `size` the pitch
/// times the height: with its memory mapped, the program reads and writes
/// the pixels there. For a texture it is where the level starts and how
/// many bytes it takes, its rows not the program's to know (`row_pitch`
/// 0). A depth attachment has nothing to say: all 0.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `layout` is the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateImage`, `MapMemory`
///
/// EXAMPLES:
/// ```zig
/// var layout: facet.SubresourceLayout = undefined;
/// fb.GetImageSubresourceLayout(device, picture, &.{}, &layout);
/// const row = pixels + y * layout.row_pitch;
/// ```
pub fn GetImageSubresourceLayout(base: *FacetBase, device: *facet.Device, image: *facet.Image, subresource: *const facet.ImageSubresource, layout: *facet.SubresourceLayout) void {
    _ = base;
    _ = device;
    const made = _objects.of(Image, image);
    layout.* = .{ .offset = 0, .size = 0, .row_pitch = 0, .array_pitch = 0, .depth_pitch = 0 };
    switch (made.kind) {
        .rows => {
            layout.size = made.bytes;
            layout.row_pitch = made.pitch;
            layout.array_pitch = made.bytes;
            layout.depth_pitch = made.bytes;
        },
        .texture => {
            const level = subresource.mip_level;
            if (level >= made.levels) return;
            const start = made.texels.layout[level].start;
            const end: u64 = if (level + 1 < made.levels) made.texels.layout[level + 1].start else made.bytes;
            layout.offset = start;
            layout.size = end - start;
        },
        .depth => {},
    }
}
