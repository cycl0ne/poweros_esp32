// SPDX-License-Identifier: MIT
//! DestroyQueryPool: a query pool given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Pool = @import("_query.zig").Pool;

/// The pool given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyQueryPool(base: *FacetBase, device: *facet.Device, pool: ?*facet.QueryPool) void
/// ```
///
/// SINCE: 1.29. LVO -460.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `pool` - the pool, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No command buffer that names it may be pending: the queue's task and the
/// cores that draw the tiles write its values as the work is done.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pool is gone.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateQueryPool`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyQueryPool(device, counted);
/// ```
pub fn DestroyQueryPool(base: *FacetBase, device: *facet.Device, pool: ?*facet.QueryPool) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(Pool, pool orelse return));
}
