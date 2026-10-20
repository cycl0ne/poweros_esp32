// SPDX-License-Identifier: MIT
//! DestroyBuffer: a buffer given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Buffer = @import("_buffer.zig").Buffer;

/// The buffer given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyBuffer(base: *FacetBase, device: *facet.Device, buffer: ?*facet.Buffer) void
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `buffer` - the buffer, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// No work the queue has not finished may use it: wait for its fence
/// first. The memory it was bound into stays as it is.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer is gone; its memory is still the caller's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateBuffer`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyBuffer(device, vertices);
/// ```
pub fn DestroyBuffer(base: *FacetBase, device: *facet.Device, buffer: ?*facet.Buffer) void {
    _ = device;
    _objects.destroy(base.sys_base, _objects.of(Buffer, buffer orelse return));
}
