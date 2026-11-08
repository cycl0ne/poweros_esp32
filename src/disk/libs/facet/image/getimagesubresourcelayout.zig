// SPDX-License-Identifier: MIT
//! GetImageSubresourceLayout: where a level of an image is in its memory.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _image = @import("_image.zig");
const Image = _image.Image;

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
/// - `subresource` - which level and which layer: level 0 for an image in
///   rows.
/// - `layout` - where its layout is written.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// For an image in rows - a linear image, and an attachment - the offset
/// is where the layer begins, 0 for the first, `row_pitch` the bytes from
/// one row to the next, `size` and `array_pitch` the pitch times the
/// height: with its memory mapped, the program reads and writes the
/// pixels there. Such an image has layers since 1.91, one after another;
/// a level or a layer it has not got answers all 0. For a texture it is
/// where the level starts and how
/// many bytes it takes, its rows not the program's to know (`row_pitch`
/// 0). A depth attachment answers since 1.63, its rows being real and
/// its levels its own: the offset is where the level of the layer begins,
/// `row_pitch` that level's own pitch, `size` what the level takes and
/// `array_pitch` the whole pyramid one layer holds. One with nothing
/// behind it - a transient one, which lives in the tiles - answers all 0,
/// as does a level or a layer it has not got. On a device that lays out
/// what it samples itself, the V3D, a texture and a sampled depth answer
/// where its driver puts the level of the layer, and how many bytes that
/// takes, with `row_pitch` 0 (since 1.142): the rows are the TMU's, laid
/// out as Mesa's v3dv lays them (`v3d_setup_slices`, v3dv_image.c:112-282).
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
    // A 3D image's level is its slices, which the span of one does not
    // say: it answers as before, where the cores would put the level.
    if (_image.deviceLaid(made) and !made.volume) if (made.device.physical.ops.texture_level) |own| {
        if (made.data == null and made.kind == .depth) return;
        if (subresource.mip_level >= made.levels or subresource.array_layer >= made.layers) return;
        const span = own(made, subresource.mip_level, subresource.array_layer);
        layout.offset = span.at;
        layout.size = span.bytes;
        layout.array_pitch = made.layer_bytes;
        return;
    };
    switch (made.kind) {
        // A layer's rows after the layer before, an attachment having
        // layers since 1.91: as Mesa's v3dv answers, the offset is the
        // layer's (`v3dv_layer_offset`) and the array pitch one layer.
        .rows => {
            if (subresource.mip_level != 0 or subresource.array_layer >= made.layers) return;
            layout.offset = _image.rowsAt(made, 0, subresource.array_layer).at;
            layout.size = made.layer_bytes;
            layout.row_pitch = made.pitch;
            layout.array_pitch = made.layer_bytes;
            layout.depth_pitch = made.layer_bytes;
        },
        .texture => {
            const level = subresource.mip_level;
            if (level >= made.levels) return;
            const start = made.texels.layout[level].start;
            const end: u64 = if (level + 1 < made.levels) made.texels.layout[level + 1].start else made.bytes;
            layout.offset = start;
            layout.size = end - start;
        },
        // Rows of its own for each level of each layer (levels since
        // 1.63): where that level begins, and how wide its rows are.
        .depth => {
            const level = subresource.mip_level;
            if (made.data == null or level >= made.levels or subresource.array_layer >= made.layers) return;
            const rows = _image.rowsAt(made, level, subresource.array_layer);
            const size = _image.levelSize(made, level);
            layout.offset = rows.at;
            layout.row_pitch = rows.pitch;
            layout.size = @as(u64, rows.pitch) * size[1];
            layout.array_pitch = made.layer_bytes;
            layout.depth_pitch = layout.size;
        },
    }
}
