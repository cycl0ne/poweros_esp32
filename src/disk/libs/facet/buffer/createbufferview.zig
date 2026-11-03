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
///   `r32g32_sfloat`, `r32g32b32_sfloat` or `r32g32b32a32_sfloat`, which
///   are those whose `buffer_features` say `UNIFORM_TEXEL_BUFFER`.
/// - `info.offset` - the first byte of the texels, a multiple of the
///   format's size.
/// - `info.range` - how many bytes of them, a multiple of the format's
///   size; `facet.WHOLE_SIZE` reaches the end of the buffer.
/// - `view` - where the view goes.
///
/// RESULT:
/// `success`; `error_format_not_supported` for a format no view takes;
/// `error_feature_not_present` where the device has no texel buffers, or
/// the buffer was not made for them; `error_initialization_failed` for an
/// offset or a range that is not the format's size, or a range of no
/// texels, or a buffer with no memory; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The view holds the buffer, the format and the range, and nothing of the
/// bytes: they are read where they lie, as the buffer's memory holds them.
/// So a program writing the buffer through its mapped memory is seen by
/// the next function that reads the view, with no copy anywhere.
///
/// The range is held to the buffer: a range reaching past its end is cut
/// to it, and what is left has to be a texel at least.
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
/// as 0xAARRGGBB, whatever the format.
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
    if (!owner.physical.features.texel_buffers) return .error_feature_not_present;
    const texels = _bufferview.texelsOf(info.format);
    if (texels == .none) return .error_format_not_supported;
    const buffer = _objects.of(Buffer, info.buffer);
    const wanted = facet.BUFFER_USAGE_UNIFORM_TEXEL_BUFFER | facet.BUFFER_USAGE_STORAGE_TEXEL_BUFFER;
    if (buffer.usage & wanted == 0) return .error_feature_not_present;
    if (buffer.data == null) return .error_initialization_failed;
    const size = texels.bytes();
    if (info.offset % size != 0 or info.offset >= buffer.size) return .error_initialization_failed;
    const left = buffer.size - info.offset;
    const bytes = if (info.range == facet.WHOLE_SIZE) left else range: {
        if (info.range % size != 0) return .error_initialization_failed;
        break :range @min(info.range, left);
    };
    if (bytes < size) return .error_initialization_failed;
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
