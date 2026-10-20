// SPDX-License-Identifier: MIT
//! AllocateCommandBuffers: command buffers from a pool.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _command = @import("_command.zig");

/// Command buffers allocated from a pool.
///
/// SYNOPSIS:
/// ```zig
/// fn AllocateCommandBuffers(base: *FacetBase, device: *facet.Device, info: *const facet.CommandBufferAllocateInfo, buffers: [*]?*facet.CommandBuffer) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -132.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - the pool, and how many: primary ones.
/// - `buffers` - where they are written, `info.command_buffer_count` of
///   them; all null when it fails.
///
/// RESULT:
/// `success`; `error_feature_not_present` for secondary command buffers;
/// `error_out_of_host_memory`, none allocated.
///
/// BEHAVIOR:
/// Each buffer starts with nothing recorded, ready for
/// BeginCommandBuffer.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffers are the pool's, given back by FreeCommandBuffers or with it.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FreeCommandBuffers`, `BeginCommandBuffer`
///
/// EXAMPLES:
/// ```zig
/// var commands: [1]?*facet.CommandBuffer = undefined;
/// if (fb.AllocateCommandBuffers(device, &.{ .command_pool = pool.? }, &commands) != .success) return error.NoCommands;
/// ```
pub fn AllocateCommandBuffers(base: *FacetBase, device: *facet.Device, info: *const facet.CommandBufferAllocateInfo, buffers: [*]?*facet.CommandBuffer) facet.Result {
    const count = info.command_buffer_count;
    for (buffers[0..count]) |*buffer| buffer.* = null;
    if (info.level != .primary) return .error_feature_not_present;
    const pool = _objects.of(_command.CommandPool, info.command_pool);
    const sys = base.sys_base;
    for (buffers[0..count], 0..) |*buffer, made_so_far| {
        const made = _objects.create(sys, _command.CommandBuffer) orelse {
            // None of them, as Vulkan has it.
            for (buffers[0..made_so_far]) |*given| {
                _command.unlink(pool, _objects.of(_command.CommandBuffer, given.*.?));
                _objects.destroy(sys, _objects.of(_command.CommandBuffer, given.*.?));
                given.* = null;
            }
            return .error_out_of_host_memory;
        };
        made.* = .{ .device = _objects.of(Device, device), .pool = pool, .next = pool.first };
        if (pool.first) |first| first.previous = made;
        pool.first = made;
        buffer.* = _objects.handle(facet.CommandBuffer, made);
    }
    return .success;
}
