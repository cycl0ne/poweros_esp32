// SPDX-License-Identifier: MIT
//! CreateDevice: a device of the program's own.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _features = @import("../instance/getphysicaldevicefeatures.zig");
const PhysicalDevice = @import("../instance/_instance.zig").PhysicalDevice;
const _device = @import("_device.zig");
const Device = _device.Device;
const _queue = @import("../queue/_queue.zig");

/// A device of the program's own, with its queue.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateDevice(base: *FacetBase, physical: *facet.PhysicalDevice, info: *const facet.DeviceCreateInfo, device: *?*facet.Device) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -44.
///
/// INPUTS:
/// - `physical` - the physical device it is made on.
/// - `info` - its queues: none, or one of family 0.
/// - `device` - where the device is written; null when it fails.
///
/// RESULT:
/// `success`; `error_validation_failed` for queues the device has not
/// got - of a family other than its one, more than one, or the family
/// asked for twice (VUID-VkDeviceQueueCreateInfo-queueFamilyIndex-00381,
/// -queueCount-00382, VUID-VkDeviceCreateInfo-queueFamilyIndex-02802,
/// -pQueueCreateInfos-06755; `error_initialization_failed` until 1.134);
/// `error_feature_not_present` for a feature asked for that the device
/// has not got; `error_initialization_failed` when the device's queue
/// cannot be started - the V3D's hardware not coming up, or the memory
/// the queue's player or its task's stack wants not being had;
/// `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The device's queue plays its command buffers on a task of its own,
/// at the priority the queue was given: 0.5 the caller's own, 0.0 ten
/// below it, 1.0 ten above.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The device is the caller's, until DestroyDevice; it has to go before
/// the instance it was made from.
///
/// NOTES:
/// A device has no features to switch on: what it does, it does.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DestroyDevice`, `GetDeviceQueue`, `GetPhysicalDeviceQueueFamilyProperties`
///
/// EXAMPLES:
/// ```zig
/// const queue_info = facet.DeviceQueueCreateInfo{ .queue_family_index = 0 };
/// var device: ?*facet.Device = null;
/// if (fb.CreateDevice(physical, &.{ .queue_create_info_count = 1, .queue_create_infos = @ptrCast(&queue_info) }, &device) != .success) return error.NoDevice;
/// defer fb.DestroyDevice(device);
/// ```
pub fn CreateDevice(base: *FacetBase, physical: *facet.PhysicalDevice, info: *const facet.DeviceCreateInfo, device: *?*facet.Device) facet.Result {
    device.* = null;
    const owner = _objects.of(PhysicalDevice, physical);
    const asked: []const facet.DeviceQueueCreateInfo = if (info.queue_create_infos) |infos| infos[0..info.queue_create_info_count] else &.{};
    // One family of one queue: a second entry asks for it again, which
    // is more queues than it has (-pQueueCreateInfos-06755, and with the
    // same flags -queueFamilyIndex-02802), or for a family there is not.
    if (asked.len > 1) return .error_validation_failed;
    var priority: ?f32 = null;
    for (asked) |queue| {
        if (queue.queue_family_index != 0 or queue.queue_count > 1) return .error_validation_failed;
        if (queue.queue_count == 1) {
            if (queue.queue_priorities) |priorities| priority = priorities[0];
        }
    }
    // Vulkan's enable step: a feature asked for that this device has not
    // got makes the whole device error_feature_not_present. Compared member
    // by member over the structure rather than by name, so a feature added
    // later is covered without this being touched.
    if (info.enabled_features) |wanted| {
        const had = _features.vulkanOf(&owner.can);
        inline for (@typeInfo(facet.PhysicalDeviceFeatures).@"struct".fields) |field| {
            if (@field(wanted, field.name) != facet.FALSE and @field(had, field.name) == facet.FALSE) {
                return .error_feature_not_present;
            }
        }
    }
    const has_queue = asked.len == 1 and asked[0].queue_count == 1;
    const sys = base.sys_base;
    const made = _objects.create(sys, Device) orelse return .error_out_of_host_memory;
    const maker = sys.FindTask(null).?;
    made.* = .{
        .base = base,
        .sys = sys,
        .instance = owner.instance,
        .physical = owner,
        .queue = .{ .device = made, .priority = _device.taskPriority(maker.node.pri, priority) },
        .has_queue = has_queue,
    };
    if (!_queue.start(&made.queue, sys, base.inline_queues or !has_queue)) {
        _objects.destroy(sys, made);
        return .error_initialization_failed;
    }
    owner.instance.devices += 1;
    device.* = _objects.handle(facet.Device, made);
    return .success;
}
