// SPDX-License-Identifier: MIT
//! GetPhysicalDeviceFormatProperties: what a device does with a format.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const PhysicalDevice = @import("_instance.zig").PhysicalDevice;

/// What the device does with a format, in each tiling and in a buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPhysicalDeviceFormatProperties(base: *FacetBase, physical: *facet.PhysicalDevice, format: facet.Format, properties: *facet.FormatProperties) void
/// ```
///
/// SINCE: 1.0. LVO -72.
///
/// INPUTS:
/// - `physical` - a physical device EnumeratePhysicalDevices listed.
/// - `format` - the format.
/// - `properties` - where its features are written: none for a format
///   facet.library does not know.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// - B8G8R8A8_UNORM and R8G8B8A8_UNORM: colour attachments, blended, in
///   either tiling; sampled, filtered, in optimal tiling; copied to and
///   from; a vertex's value.
/// - R5G6B5_UNORM_PACK16: colour attachments, blended, in either tiling;
///   sampled, filtered, in optimal tiling; copied.
/// - D16_UNORM: a depth attachment, in optimal tiling, and copied both
///   ways; sampled and filtered as well on a device that samples a depth
///   where its rows lie (`Capabilities.sampled_depth`), and not
///   on one that does not, which refuses such an image at CreateImage
///   (since 1.80).
/// - R32_SFLOAT to R32G32B32A32_SFLOAT: a vertex's value.
/// - R8_UNORM: sampled, filtered, written through as a storage image, in
///   optimal tiling, and copied both ways. One byte a texel, read as
///   (red, 0, 0, 1) (`Capabilities.small_texels`, since 1.48);
///   never an attachment and never a buffer's.
/// - BC1, BC2, BC3, R16G16B16A16_SFLOAT, R32G32B32A32_SFLOAT,
///   B10G11R11_UFLOAT and E5B9G9R9_UFLOAT: sampled, filtered, in optimal
///   tiling, and copied into. A device that samples such a texel where it
///   lies keeps it as it was copied in and is copied out of as well
///   (`kept_compressed` since 1.44, `kept_floats` since 1.45, and
///   TRANSFER_SRC here says which); one that does not keeps it as 8 bits a
///   channel, floats cut to 0 to 1, taking B8G8R8A8's memory and holding
///   no more than it.
/// - ETC2 and EAC - ETC2_R8G8B8, ETC2_R8G8B8A1, ETC2_R8G8B8A8, EAC_R11 and
///   EAC_R11G11: sampled, filtered, in optimal tiling, and copied into.
///   No sampler of this library reads such a block, so they are always
///   unpacked to 8 bits a channel and never copied out of (since 1.46).
/// - B4G4R4A4_UNORM_PACK16 and A1R5G5B5_UNORM_PACK16: sampled, filtered,
///   in optimal tiling, and copied into. No sampler of this library reads
///   four channels in 16 bits either, so they are always unpacked to 8
///   bits a channel as ETC2 is, and never copied out of (since 1.127).
/// - A8B8G8R8_SNORM_PACK32, _UINT_PACK32 and _SINT_PACK32: what
///   R8G8B8A8_SNORM, _UINT and _SINT say, on either device, being the same
///   bytes (since 1.127).
/// - Blits (since 1.126): BLIT_SRC, in optimal tiling, beside every colour
///   format sampled there but those of whole numbers, a blit reading the
///   texel as a sample does; BLIT_DST beside the three colour attachments
///   in either tiling, and beside R8_UNORM. D16_UNORM says both, a depth
///   going into an image of its own format. No blit carries a whole number
///   or a stencil, and none reads an image in linear tiling.
///
/// Every answer that differs between two devices of one machine is read
/// off that device's `PhysicalDeviceFeatures` (since 1.80): what it keeps
/// as it was given it - a compressed image's blocks, a float one's floats,
/// a texture's own channels, its whole numbers - and whether it samples a
/// depth where its rows lie. A format the device keeps none of says nothing
/// of an image here, only of a buffer where it has one, which is the same
/// answer CreateImage gives. Before that the reply depended on the format
/// alone but for one bool, and said a sampled D16_UNORM on every device.
///
/// An image to be sampled may have sides of any size (since 1.42). One of
/// B8G8R8A8 or R8G8B8A8 may keep its texel in the 32 bits of its word
/// rather than spread over 64 (IMAGE_CREATE_PACKED_TEXELS, since 1.48);
/// the format's features are the same either way.
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
/// A colour attachment is not sampled as well: the two lie differently in
/// memory (CreateImage).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateImage`, `GetPhysicalDeviceFeatures`
///
/// EXAMPLES:
/// ```zig
/// var properties: facet.FormatProperties = undefined;
/// fb.GetPhysicalDeviceFormatProperties(physical, .r5g6b5_unorm_pack16, &properties);
/// const can_sample = properties.optimal_tiling_features & facet.FORMAT_FEATURE_SAMPLED_IMAGE != 0;
/// ```
pub fn GetPhysicalDeviceFormatProperties(base: *FacetBase, physical: *facet.PhysicalDevice, format: facet.Format, properties: *facet.FormatProperties) void {
    _ = base;
    const asked = _objects.of(PhysicalDevice, physical);
    properties.* = asked.ops.format_properties(asked, format);
}
