// SPDX-License-Identifier: MIT
//! CreateBufferView: a range of a buffer read as texels of a format.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _buffer = @import("_buffer.zig");
const Buffer = _buffer.Buffer;
const _bufferview = @import("_bufferview.zig");
const BufferView = _bufferview.BufferView;
const Device = @import("../device/_device.zig").Device;

/// A range of a buffer read as texels of a format, for a texel buffer
/// descriptor.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateBufferView(base: *FacetBase, device: *facet.Device, info: *const facet.BufferViewCreateInfo, view: *?*facet.BufferView) facet.Result
/// ```
///
/// SINCE: 1.32. LVO -492.
///
/// INPUTS:
/// - `device` - the device whose buffer it is.
/// - `info.buffer` - a buffer made with `BUFFER_USAGE_UNIFORM_TEXEL_BUFFER`,
///   or `BUFFER_USAGE_STORAGE_TEXEL_BUFFER` for one a function writes
///   through, and bound to memory.
/// - `info.format` - how the bytes are read: `r8g8b8a8_unorm`,
///   `b8g8r8a8_unorm`, `r5g6b5_unorm_pack16`, `r32_sfloat`,
///   `r32g32_sfloat`, `r32g32b32_sfloat`, `r32g32b32a32_sfloat`; since
///   1.54 one channel, two or four of 8, 16 or 32 bits - a `_unorm` read
///   as 0 to 1, a `_uint` or a `_sint` as the whole number itself, and
///   `r16_sfloat`, `r16g16_sfloat` and `r16g16b16a16_sfloat` as
///   half-floats; and since 1.68 the `_snorm` of the 8- and 16-bit ones,
///   read as -1 to 1, `r8_srgb`, `r8g8_srgb`, `r8g8b8a8_srgb` and
///   `b8g8r8a8_srgb`, read through sRGB's transfer function, the A8B8G8R8
///   words (`_unorm` and `_srgb`, and since 1.127 `_snorm`, `_uint` and
///   `_sint`), the four 2-10-10-10 words, `b10g11r11_ufloat_pack32` and
///   `e5b9g9r9_ufloat_pack32`, and `r32g32b32_uint` and `_sint`. Those
///   are the formats whose `buffer_features` say `UNIFORM_TEXEL_BUFFER`,
///   which `GetPhysicalDeviceFormatProperties` tells and is the same on
///   every device.
/// - `info.offset` - the first byte of the texels, a multiple of
///   `PhysicalDeviceLimits.min_texel_buffer_offset_alignment`, 16, whatever
///   the format's size (since 1.125; a multiple of the format's size
///   before).
/// - `info.range` - how many bytes of them, a multiple of the format's
///   size; `facet.WHOLE_SIZE` reaches the end of the buffer.
/// - `view` - where the view goes.
///
/// RESULT:
/// `success`; `error_feature_not_present` where the device has no texel
/// buffers; `error_validation_failed` for a format no view takes, whose
/// features have neither texel buffer bit
/// (VUID-VkBufferViewCreateInfo-format-08778, -format-08779;
/// `error_format_not_supported` until 1.135), for a buffer not made for
/// them (-buffer-00932; `error_feature_not_present` until 1.133), and for
/// an offset that is not on the limit or is past
/// the buffer's end, a range that is not a multiple of the format's size,
/// is 0, or reaches past the buffer's end, or a buffer with no memory
/// (-buffer-02750, -buffer-02751, -offset-00925, -range-00929,
/// -range-00928, -offset-00931, -buffer-00935;
/// `error_initialization_failed` until 1.134, and a range past the end
/// was cut to it where a texel was left there);
/// `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The view holds the buffer, the format and the range, and nothing of the
/// bytes: they are read where they lie, as the buffer's memory holds them.
/// So a program writing the buffer through its mapped memory is seen by
/// the next function that reads the view, with no copy anywhere.
///
/// A range given is held to the buffer as Vulkan has it: one reaching
/// past its end is refused (VUID-VkBufferViewCreateInfo-offset-00931).
/// Until 1.134 it was cut to the end, and refused only where less than a
/// texel was left there. `WHOLE_SIZE` is the bytes from the offset to the
/// end, as many whole texels as they hold, which Vulkan has be "the
/// nearest smaller multiple" of a texel and does not ask to be one: where
/// less than a texel is left the view has none, and a function reads 0
/// from it, as it does past the last texel of any view
/// (`shader.Texels.at`). Until 1.134 such a view was refused.
///
/// The offset is held to the limit alone, as Vulkan has it
/// (VUID-VkBufferViewCreateInfo-buffer-02750, -buffer-02751, which were
/// -offset-00926 when 1.125 said so): a texel is read a byte at a
/// time, so nothing asks it to start on a multiple of its own size, and
/// three channels of 32 bits, 12 bytes, may start at 16, which no power
/// of two that is a limit could have said otherwise. lavapipe and v3dv
/// look at the offset no further (`lvp_CreateBufferView`,
/// lvp_image.c:785-817; `v3dv_CreateBufferView`, v3dv_image.c:885-940), their
/// limits llvmpipe's 16 (lp_screen.c:288) and the V3D's texture unit's 64
/// (`V3D_TMU_TEXEL_ALIGN`, v3d_limits.h:60), which this library's V3D will
/// want the day its texture unit reads a texel buffer; until then its
/// texel buffers are read by the cores'.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The view is the caller's, given back by `DestroyBufferView`. The buffer
/// has to outlive it, and the view has to outlive every set it is written
/// into and every submission reading one.
///
/// NOTES:
/// This is how a function reads bytes as a format rather than as a Zig
/// type: a storage buffer wants the program and the data to agree on a
/// struct, where a texel buffer reads what a file or another machine
/// handed over. `shader.Resources.texels` gives the function a
/// `shader.Texels`, whose `at` reads a texel as four floats and `colorAt`
/// as 0xAARRGGBB, whatever the format. Since 1.54 `intAt` reads it as four
/// whole numbers as well, and `setInt` writes it from them, which is what
/// a 32-bit integer format wants: a value past 2^24 is more than `at`'s
/// float carries exactly.
///
/// No vertex attribute is read in the formats 1.54 added, and on the V3D
/// no image is kept in one either: there they say `UNIFORM_TEXEL_BUFFER`
/// and `STORAGE_TEXEL_BUFFER` in `buffer_features` and nothing else. On
/// the cores the 16-bit `_unorm` ones and `r8g8_unorm` are images as well
/// since 1.69 (`Capabilities.wide_channels`), and the whole numbers since
/// 1.70 (`Capabilities.whole_textures`). The two that were already image
/// formats, `r8_unorm` and `r16g16b16a16_sfloat`, keep what they had and
/// gain these.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroyBufferView`, `UpdateDescriptorSets`, `CreateDescriptorSetLayout`
///
/// EXAMPLES:
/// ```zig
/// var view: ?*facet.BufferView = null;
/// _ = fb.CreateBufferView(device, &.{ .buffer = buffer.?, .format = .r32g32b32a32_sfloat }, &view);
/// ```
pub fn CreateBufferView(base: *FacetBase, device: *facet.Device, info: *const facet.BufferViewCreateInfo, view: *?*facet.BufferView) facet.Result {
    view.* = null;
    const owner = _objects.of(Device, device);
    if (!owner.physical.can.texel_buffers) return .error_feature_not_present;
    const texels = _bufferview.texelsOf(info.format);
    // VUID-VkBufferViewCreateInfo-format-08778, -format-08779: the formats
    // a view takes are those `_format.describe` gives the texel buffer
    // bits, and no other has either.
    if (texels == .none) return .error_validation_failed;
    const buffer = _objects.of(Buffer, info.buffer);
    const wanted = facet.BUFFER_USAGE_UNIFORM_TEXEL_BUFFER | facet.BUFFER_USAGE_STORAGE_TEXEL_BUFFER;
    if (buffer.usage & wanted == 0) return .error_validation_failed;
    if (buffer.data == null) return .error_validation_failed;
    const size = texels.bytes();
    const alignment = owner.physical.properties.limits.min_texel_buffer_offset_alignment;
    if (info.offset % alignment != 0 or info.offset >= buffer.size) return .error_validation_failed;
    const left = buffer.size - info.offset;
    const bytes = if (info.range == facet.WHOLE_SIZE) left else range: {
        // Of whole texels, some, and within the buffer
        // (VUID-VkBufferViewCreateInfo-range-00929, -range-00928,
        // -offset-00931).
        if (info.range % size != 0 or info.range == 0 or info.range > left) return .error_validation_failed;
        break :range info.range;
    };
    const made = _objects.create(base.sys_base, BufferView) orelse return .error_out_of_host_memory;
    made.* = .{
        .device = owner,
        .buffer = buffer,
        .texels = texels,
        .format = info.format,
        .offset = info.offset,
        .bytes = bytes - bytes % size,
    };
    view.* = _objects.handle(facet.BufferView, made);
    return .success;
}
