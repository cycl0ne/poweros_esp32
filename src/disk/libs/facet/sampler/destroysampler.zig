// SPDX-License-Identifier: MIT
//! DestroySampler: a sampler given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Sampler = @import("_sampler.zig").Sampler;

/// The sampler given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroySampler(base: *FacetBase, device: *facet.Device, sampler: ?*facet.Sampler) void
/// ```
///
/// SINCE: 1.28. LVO -452.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `sampler` - the sampler, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No set written with it may be drawn with any more, and no command
/// buffer that bound such a set may be pending: a set holds the address of
/// what the sampler keeps, and the draws read it as they run.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The sampler is gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateSampler`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroySampler(device, sampler);
/// ```
pub fn DestroySampler(base: *FacetBase, device: *facet.Device, sampler: ?*facet.Sampler) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(Sampler, sampler orelse return));
}
