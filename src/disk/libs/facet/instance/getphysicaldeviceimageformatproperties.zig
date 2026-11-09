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
/// - `image_type` - `1d`, `2d` or `3d`; a `1d` image is a texture of
///   one row, and asks for height and depth 1 (since 1.86).
/// - `tiling` - `optimal` or `linear`.
/// - `usage` - the IMAGE_USAGE_* bits it would be made with.
/// - `flags` - the IMAGE_CREATE_* flags, CUBE_COMPATIBLE among them, and
///   since 1.131 MUTABLE_FORMAT, refused where CreateImage refuses it.
/// - `properties` - where the answer is written; zeroed where there is
///   no such image.
///
/// RESULT:
/// `success`, or `error_format_not_supported` where CreateImage would
/// refuse every image of that shape, whatever its extent - but for two
/// kinds of shape. TRANSIENT_ATTACHMENT alone, with no other usage, is
/// answered as the transfers alone are: no more strictly than
/// TRANSIENT beside a colour attachment, as Vulkan has a usage within
/// another be answered ("Additional Image Capabilities"), and the same
/// where that one is `success`, while on the cores a float or a BC
/// format, which is no colour attachment, is `success` too. CreateImage
/// refuses every such image (VUID-VkImageCreateInfo-usage-00966; since
/// 1.135). And a 3D image neither sampled nor written through, or a
/// colour or input attachment written through as a storage image, is
/// declined, the question being asked at 256 slices, while CreateImage
/// makes many such images a slice deep (docs/facet-vulkan10.md item 94).
///
/// BEHAVIOR:
/// The question is asked of the same rules CreateImage keeps: the image
/// of the largest extent is laid out by the very code CreateImage lays
/// an image out with, so an extent inside what is answered here is made
/// and one outside it is refused, the shapes RESULT names apart.
///
/// What is answered, from the device's own limits
/// (GetPhysicalDeviceProperties) and from what CreateImage takes of
/// them:
/// - `max_extent`: `max_image_dimension_2d` square for a 2D image -
///   8192 on this machine's devices - `max_image_dimension_3d` cubed for
///   a 3D one, 256, and 1 deep for every other.
/// - `max_mip_levels`: the levels of `max_extent`, as many as halving
///   its longest side gives, where the shape takes levels - a sampled
///   image, one written through, a depth attachment since 1.63, a 3D
///   image whose slices have levels of their own, and since 1.119 a
///   colour attachment and any other optimal image kept in rows, which is
///   Vulkan's rule for an optimal image ("the number of levels in the
///   complete mipmap chain") - and 1 where it does not: a linear image, as
///   Vulkan lets it, and on the V3D an image kept in rows
///   (`Ops.texture_memory`).
/// - `max_array_layers`: `max_image_array_layers`, 256, where the shape
///   takes layers - an image a function reads or writes, a sampled or
///   read-back depth attachment among them - and 1 for every other
///   shape, a 3D image's layers being its depth.
/// - `sample_counts`: 1, and 4 as well where CreateImage takes an image
///   of four samples a pixel of the extent and the layers above at one
///   level (since 1.98): a 2D image in optimal tiling, not cube
///   compatible, of a format that is an attachment, drawn into, read as
///   an input attachment, copied or, since 1.110, sampled - and since
///   1.119 sampled and drawn into at once, as one sample is - on a device
///   that draws four samples (`_image.shapeFor`). Where 4 is said, every
///   such image inside these bounds is made.
/// - `max_resource_size`: the bytes an image of all of the above takes,
///   every level of every layer of it (since 1.66), which is what
///   GetImageMemoryRequirements answers for such an image. It may be
///   more memory than any heap holds: AllocateMemory is what finds that
///   out.
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
/// Until 1.119 a format could be sampled and drawn into without one image
/// being both, so a program asked about the usages one at a time. Since
/// then the cores keep such an image in rows and sample it where they
/// lie, as llvmpipe and v3dv both make one; the V3D still answers
/// `error_format_not_supported` for the two at once, its half of
/// docs/facet-vulkan10.md item 48 being to come.
///
/// Until 1.66 `max_resource_size` was the largest heap's bytes, which is
/// a fact about the memory and not about the image, and the levels and
/// the layers were worked out from the kind of image rather than asked
/// of CreateImage - so a depth attachment answered one level where 1.63
/// had given it as many as a colour one has, a sampled depth attachment
/// answered one layer where 1.58 had given it 256, and a 3D image
/// answered one level where its slices have their own.
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
    // A 1D image is a texture of one row, so its height is 1 and its
    // width comes from its own limit (since 1.86).
    const line = image_type == .@"1d";
    const cube = flags & facet.IMAGE_CREATE_CUBE_COMPATIBLE != 0;
    // What the device said its images may be (GetPhysicalDeviceProperties).
    const limits = &device.properties.limits;
    const side: u32 = if (volume)
        limits.max_image_dimension_3d
    else if (line)
        limits.max_image_dimension_1d
    else
        limits.max_image_dimension_2d;
    // The largest image of the shape asked about, written as CreateImage
    // would be asked for it: that extent, one level, and the fewest
    // layers the shape has - the six a cube wants, the depth a 3D image's
    // layers are, and one for the rest. What CreateImage says of it is
    // what it says of every image of the shape, its levels and its layers
    // apart, which are asked after.
    var asked = facet.ImageCreateInfo{
        .flags = flags,
        .image_type = image_type,
        .format = format,
        .extent = .{ .width = side, .height = if (line) 1 else side, .depth = if (volume) side else 1 },
        .mip_levels = 1,
        .array_layers = if (cube and !volume) 6 else 1,
        .samples = 1,
        .tiling = tiling,
        .usage = usage,
    };
    var largest = _image.shapeFor(device, &asked) orelse return .error_format_not_supported;
    // Its levels and its layers, each asked of those same rules rather
    // than worked out here: as many levels as halving the longest side
    // gives, and the device's limit of layers, kept where CreateImage
    // takes them and dropped where it does not. A 3D image's layers are
    // its depth, which the extent holds already.
    asked.mip_levels = levelsOf(side);
    if (_image.shapeFor(device, &asked)) |deeper| largest = deeper else asked.mip_levels = 1;
    if (!volume) {
        const fewest = asked.array_layers;
        asked.array_layers = limits.max_image_array_layers;
        if (_image.shapeFor(device, &asked)) |wider| largest = wider else asked.array_layers = fewest;
    }
    // Four samples a pixel, asked of CreateImage's rules the same way:
    // the largest extent with the most layers at one level, which is all
    // a multisampled image may have (since 1.98). Where that is made,
    // every smaller one is.
    var counts = facet.SAMPLE_COUNT_1;
    var bytes = largest.bytes;
    var four = asked;
    four.mip_levels = 1;
    four.samples = 4;
    if (_image.shapeFor(device, &four)) |multisampled| {
        counts |= facet.SAMPLE_COUNT_4;
        bytes = @max(bytes, multisampled.bytes);
    }
    properties.* = .{
        .max_extent = asked.extent,
        .max_mip_levels = asked.mip_levels,
        .max_array_layers = asked.array_layers,
        .sample_counts = counts,
        // The bytes the largest image takes, every level of every layer of
        // it and every sample: what GetImageMemoryRequirements answers for
        // it, and more than any heap holds where the largest extent and
        // the most layers meet (since 1.66).
        .max_resource_size = bytes,
    };
    return .success;
}

/// The levels an image `side` texels across has, down to one texel.
fn levelsOf(side: u32) u32 {
    return 32 - @clz(side);
}
