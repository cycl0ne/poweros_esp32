// SPDX-License-Identifier: MIT
//! CreateCommandPool: where a device's command buffers come from.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const CommandPool = @import("_command.zig").CommandPool;

/// A pool the device's command buffers are allocated from.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateCommandPool(base: *FacetBase, device: *facet.Device, info: *const facet.CommandPoolCreateInfo, pool: *?*facet.CommandPool) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -120.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - its queue family, 0, and its flags
///   (COMMAND_POOL_CREATE_*).
/// - `pool` - where the pool is written; null when it fails.
///
/// RESULT:
/// `success`; `error_initialization_failed` for a queue family the device
/// has not got; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The pool keeps its command buffers: DestroyCommandPool frees all of
/// them, ResetCommandPool resets all of them. Each buffer may be reset on
/// its own whatever the flags say.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pool is the caller's, until DestroyCommandPool.
///
/// NOTES:
/// A pool and its buffers are used by one task at a time: recording into
/// two buffers of one pool from two tasks at once is the program's to
/// keep apart.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroyCommandPool`, `AllocateCommandBuffers`
///
/// EXAMPLES:
/// ```zig
/// var pool: ?*facet.CommandPool = null;
/// if (fb.CreateCommandPool(device, &.{ .flags = facet.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER }, &pool) != .success) return error.NoPool;
/// ```
pub fn CreateCommandPool(base: *FacetBase, device: *facet.Device, info: *const facet.CommandPoolCreateInfo, pool: *?*facet.CommandPool) facet.Result {
    pool.* = null;
    if (info.queue_family_index != 0) return .error_initialization_failed;
    const made = _objects.create(base.sys_base, CommandPool) orelse return .error_out_of_host_memory;
    made.* = .{ .device = _objects.of(Device, device), .flags = info.flags };
    pool.* = _objects.handle(facet.CommandPool, made);
    return .success;
}
