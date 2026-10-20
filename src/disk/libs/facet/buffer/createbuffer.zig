// SPDX-License-Identifier: MIT
//! CreateBuffer: a buffer, to be bound into memory.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const Buffer = @import("_buffer.zig").Buffer;

/// A buffer of so many bytes, for what its usage says.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateBuffer(base: *FacetBase, device: *facet.Device, info: *const facet.BufferCreateInfo, buffer: *?*facet.Buffer) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -76.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - its size, and what it is for (BUFFER_USAGE_*).
/// - `buffer` - where the buffer is written; null when it fails.
///
/// RESULT:
/// `success`; `error_out_of_device_memory` for a size of nothing;
/// `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The buffer has no memory until BindBufferMemory binds it into some;
/// GetBufferMemoryRequirements says what it needs. The usage is what the
/// program says it does with it, and is not checked.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer is the caller's, until DestroyBuffer; the memory it is
/// bound into stays the caller's to free.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroyBuffer`, `GetBufferMemoryRequirements`, `BindBufferMemory`
///
/// EXAMPLES:
/// ```zig
/// var vertices: ?*facet.Buffer = null;
/// const info = facet.BufferCreateInfo{ .size = @sizeOf(@TypeOf(cube)), .usage = facet.BUFFER_USAGE_VERTEX_BUFFER };
/// if (fb.CreateBuffer(device, &info, &vertices) != .success) return error.NoBuffer;
/// ```
pub fn CreateBuffer(base: *FacetBase, device: *facet.Device, info: *const facet.BufferCreateInfo, buffer: *?*facet.Buffer) facet.Result {
    buffer.* = null;
    if (info.size == 0) return .error_out_of_device_memory;
    const made = _objects.create(base.sys_base, Buffer) orelse return .error_out_of_host_memory;
    made.* = .{ .device = _objects.of(Device, device), .size = info.size, .usage = info.usage };
    buffer.* = _objects.handle(facet.Buffer, made);
    return .success;
}
