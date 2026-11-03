// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceImageFormatProperties: the largest image of a shape.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _instance = @import("_instance.zig");
const PhysicalDevice = _instance.PhysicalDevice;
const _image = @import("../image/_image.zig");

/// The largest image of a format, type, tiling and usage, or
/// `error_format_not_supported` where there is no such image at all.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPhysicalDeviceImageFormatProperties(base: *FacetBase, physical: *facet.PhysicalDevice, format: facet.Format, image_type: facet.ImageType, tiling: facet.ImageTiling, usage: u32, flags: u32, properties: *facet.ImageFormatProperties) facet.Result
/// ```
///
/// SINCE: 1.36. LVO -504.
///
/// INPUTS:
/// - `physical` - a physical device EnumeratePhysicalDevices listed.
/// - `format` - the format the image would be made with.
/// - `image_type` - `2d` or `3d`; `1d` has no images.
/// - `tiling` - `optimal` or `linear`.
/// - `usage` - the IMAGE_USAGE_* bits it would be made with.
/// - `flags` - the IMAGE_CREATE_* flags, CUBE_COMPATIBLE among them.
/// - `properties` - where the answer is written; zeroed where there is
///   no such image.
///
/// RESULT:
/// `success`, or `error_format_not_supported` where CreateImage would
/// refuse every image of that shape, whatever its extent.
///
/// BEHAVIOR:
/// The question is asked of the same rules CreateImage keeps, so an
/// extent inside what is answered here is made and one outside it is
/// refused - with one exception: an image of the largest extent and the
/// most layers at once may want more memory than a heap holds, which
/// `max_resource_size` says and AllocateMemory finds out.
///
/// What is answered, from the device's own limits
/// (GetPhysicalDeviceProperties):
/// - `max_extent`: `max_image_dimension_2d` square for a 2D image -
///   8192 on this machine's devices - `max_image_dimension_3d` cubed for
///   a 3D one, 256, and 1 deep for every other.
/// - `max_mip_levels`: the levels of `max_extent` where the shape takes
///   levels - a sampled image or one written through - and 1 where it
///   does not, which is an attachment, rows, a depth image and a 3D one.
/// - `max_array_layers`: `max_image_array_layers` for a sampled image,
///   256, and 1 for every other shape, layers being for sampling.
/// - `sample_counts`: 1, one sample a pixel.
/// - `max_resource_size`: the largest heap's bytes.
///
/// An image to be sampled may have sides of any size (since 1.42); its
/// levels are as many as halving the longer side gives, which
/// `max_mip_levels` says.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `properties` is the caller's.
///
/// NOTES:
/// A format may be sampled and drawn into without one image being both:
/// the two lie differently in memory, so the usages are asked about one
/// at a time, as CreateImage takes them.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateImage`, `GetPhysicalDeviceFormatProperties`, `GetPhysicalDeviceProperties`
///
/// EXAMPLES:
/// ```zig
/// var properties: facet.ImageFormatProperties = undefined;
/// const answer = fb.GetPhysicalDeviceImageFormatProperties(physical, .b8g8r8a8_unorm, .@"2d", .optimal, facet.IMAGE_USAGE_SAMPLED, 0, &properties);
/// if (answer == .success) {
///     // 8192 x 8192, 14 levels, 256 layers.
///     const side = properties.max_extent.width;
///     _ = side;
/// }
/// ```
pub fn GetPhysicalDeviceImageFormatProperties(base: *FacetBase, physical: *facet.PhysicalDevice, format: facet.Format, image_type: facet.ImageType, tiling: facet.ImageTiling, usage: u32, flags: u32, properties: *facet.ImageFormatProperties) facet.Result {
    _ = base;
    properties.* = .{};
    const device = _objects.of(PhysicalDevice, physical);
    const volume = image_type == .@"3d";
    const cube = flags & facet.IMAGE_CREATE_CUBE_COMPATIBLE != 0;
    // The smallest image of the shape asked about: one texel, one level,
    // and the six layers a cube wants. What CreateImage says of it is
    // what it says of every image of the shape, the extent apart.
    const probe = facet.ImageCreateInfo{
        .flags = flags,
        .image_type = image_type,
        .format = format,
        .extent = .{ .width = 1, .height = 1, .depth = 1 },
        .mip_levels = 1,
        .array_layers = if (cube) 6 else 1,
        .samples = 1,
        .tiling = tiling,
        .usage = usage,
    };
    const shape = _image.shapeFor(device, &probe) orelse return .error_format_not_supported;
    // What the device said its images may be (GetPhysicalDeviceProperties).
    const limits = &device.properties.limits;
    const side: u32 = if (volume) limits.max_image_dimension_3d else limits.max_image_dimension_2d;
    // Levels and layers are a texture's: an attachment, rows and a depth
    // image are one level, and layers are for sampling.
    const texture = shape.kind == .texture;
    properties.* = .{
        .max_extent = .{ .width = side, .height = side, .depth = if (volume) side else 1 },
        .max_mip_levels = if (texture and !volume) levelsOf(side) else 1,
        .max_array_layers = if (texture and !volume) limits.max_image_array_layers else 1,
        .sample_counts = 1,
        .max_resource_size = largestHeap(&device.memory),
    };
    return .success;
}

/// The levels an image `side` texels across has, down to one texel.
fn levelsOf(side: u32) u32 {
    return 32 - @clz(side);
}

/// The bytes of the largest heap of `memory`.
fn largestHeap(memory: *const facet.PhysicalDeviceMemoryProperties) u64 {
    var most: u64 = 0;
    for (memory.memory_heaps[0..memory.memory_heap_count]) |heap| most = @max(most, heap.size);
    return most;
}
