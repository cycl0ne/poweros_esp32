// SPDX-License-Identifier: MIT
//! BindImageMemory: an image given its memory.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _image = @import("_image.zig");
const _memory = @import("../memory/_memory.zig");

/// The image bound into a block of memory, at an offset.
///
/// SYNOPSIS:
/// ```zig
/// fn BindImageMemory(base: *FacetBase, device: *facet.Device, image: *facet.Image, memory: *facet.DeviceMemory, offset: u64) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -104.
///
/// INPUTS:
/// - `device` - the device both are of.
/// - `image` - an image not yet bound.
/// - `memory` - the block.
/// - `offset` - where in it the image starts.
///
/// RESULT:
/// `success`; `error_validation_failed` when the image does not fit
/// there - past the block's end, the offset not aligned as
/// GetImageMemoryRequirements says, or a type the image may not be in -
/// or it is bound already, as a swapchain's image always is: Vulkan has
/// those bound as they are handed out
/// (VUID-vkBindImageMemory-memoryOffset-01046, -None-10737, -None-10735,
/// -memory-01047, -image-07460; `error_out_of_device_memory` until 1.134).
///
/// BEHAVIOR:
/// The image's texels are the block's from `offset` on, for as long as
/// both last, undefined until something is copied or drawn into them.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The block stays the caller's to free, after the image is no longer in
/// use.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetImageMemoryRequirements`, `AllocateMemory`, `CreateImageView`
///
/// EXAMPLES:
/// ```zig
/// if (fb.BindImageMemory(device, picture, memory, 0) != .success) return error.NoBind;
/// ```
pub fn BindImageMemory(base: *FacetBase, device: *facet.Device, image: *facet.Image, memory: *facet.DeviceMemory, offset: u64) facet.Result {
    _ = base;
    _ = device;
    const made = _objects.of(_image.Image, image);
    const block = _objects.of(_memory.DeviceMemory, memory);
    // Each of these breaks one of Vulkan's rules: no memory has run out
    // (VUID-vkBindImageMemory-image-07460, -memoryOffset-01046,
    // -memory-01047, -None-10735, -None-10737; since 1.134).
    if (made.memory != null or made.presentable or !_memory.suits(block, offset, _image.requirements(made))) return .error_validation_failed;
    made.memory = block;
    made.offset = offset;
    made.data = _memory.at(block, offset);
    if (_image.hasTexels(made)) made.texels = _image.texelsOver(made, made.data.?) catch unreachable;
    return .success;
}
