// SPDX-License-Identifier: MIT
//! A device. It is the program's own, made on the instance's physical
//! device, with its queue (queue/_queue.zig), where its command buffers
//! are played.

const sdk = @import("sdk");
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _instance = @import("../instance/_instance.zig");
const Instance = _instance.Instance;
const PhysicalDevice = _instance.PhysicalDevice;
const Queue = @import("../queue/_queue.zig").Queue;

pub const Device = struct {
    base: *FacetBase,
    sys: *ExecBase,
    instance: *Instance,
    physical: *PhysicalDevice,
    /// The one queue, when the device was made with it.
    queue: Queue,
    has_queue: bool = false,
    /// The blocks of memory allocated and not yet freed.
    allocations: u32 = 0,
};

/// The priority a queue's task runs at for a priority of 0.0 to 1.0 (null:
/// 0.5): -10 to 10 round `maker`'s.
pub fn taskPriority(maker: i8, priority: ?f32) i8 {
    const given = priority orelse 0.5;
    const clamped = if (given >= 0 and given <= 1) given else 0.5; // a NaN as well
    const step: i32 = @intFromFloat(@round((clamped - 0.5) * 20));
    return @intCast(@max(-128, @min(127, @as(i32, maker) + step)));
}
