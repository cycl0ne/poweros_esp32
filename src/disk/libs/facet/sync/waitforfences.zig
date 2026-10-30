// SPDX-License-Identifier: MIT
//! WaitForFences: waiting for fences.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _sync = @import("_sync.zig");
const exec = sdk.exec;

/// Wait until fences are signalled: all of them, or any.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitForFences(base: *FacetBase, device: *facet.Device, count: u32, fences: [*]const *facet.Fence, wait_all: bool, timeout: u64) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -192.
///
/// INPUTS:
/// - `device` - the device they were made on.
/// - `count`, `fences` - the fences: with `wait_all` false, at most
///   WAIT_MAX (32).
/// - `wait_all` - true to wait for all, false for any one.
/// - `timeout` - nanoseconds at most, rounded up to microseconds and kept
///   to the system tick; 0 only looks; WAIT_FOREVER_NS has no limit.
///
/// RESULT:
/// `success` once they are; `timeout` when the time ran out first;
/// `error_device_lost` once the device is lost, at once if it already is.
///
/// BEHAVIOR:
/// WaitForAny on the fences' waitables: the task sleeps until a queue
/// signals one.
///
/// CONTEXT:
/// - Waits: yes.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The array is the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// With `wait_all` the limit is each fence's, not the whole wait's:
/// waiting for N fences not yet signalled may take up to N times it.
///
/// SEE ALSO:
/// `ResetFences`, `GetFenceStatus`, `QueueSubmit`
///
/// EXAMPLES:
/// ```zig
/// if (fb.WaitForFences(device, 1, @ptrCast(&frame_done), true, facet.WAIT_FOREVER_NS) != .success) return error.Hung;
/// ```
pub fn WaitForFences(base: *FacetBase, device: *facet.Device, count: u32, fences: [*]const *facet.Fence, wait_all: bool, timeout: u64) facet.Result {
    const made = _objects.of(Device, device);
    if (made.isLost()) return .error_device_lost;
    const waited = waitFor(base, count, fences, wait_all, timeout);
    return if (made.isLost()) .error_device_lost else waited;
}

fn waitFor(base: *FacetBase, count: u32, fences: [*]const *facet.Fence, wait_all: bool, timeout: u64) facet.Result {
    const sys = base.sys_base;
    const given = @as([*]const *_sync.Fence, @ptrCast(fences))[0..count];
    const limit = _sync.microseconds(timeout);
    if (wait_all) {
        for (given) |fence| {
            const one = [1]*exec.Waitable{&fence.waitable};
            if (sys.WaitForAny(&one, 1, limit) == exec.WAIT_TIMEOUT) return .timeout;
        }
        return .success;
    }
    var waitables: [exec.WAIT_MAX]*exec.Waitable = undefined;
    const taken = @min(given.len, exec.WAIT_MAX);
    if (taken == 0) return .success;
    for (given[0..taken], waitables[0..taken]) |fence, *waitable| waitable.* = &fence.waitable;
    return if (sys.WaitForAny(&waitables, @intCast(taken), limit) == exec.WAIT_TIMEOUT) .timeout else .success;
}
