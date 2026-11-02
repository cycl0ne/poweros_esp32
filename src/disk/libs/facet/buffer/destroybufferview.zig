// SPDX-License-Identifier: MIT
//! DestroyBufferView: a buffer view given back.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const BufferView = @import("_bufferview.zig").BufferView;

/// A buffer view given back.
///
/// SYNOPSIS:
/// ```zig
/// fn DestroyBufferView(base: *FacetBase, device: *facet.Device, view: ?*facet.BufferView) void
/// ```
///
/// SINCE: 1.32. LVO -496.
///
/// INPUTS:
/// - `device` - the device it was made on.
/// - `view` - the view, or null, which does nothing.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The view's memory is given back. The buffer it was made of is untouched:
/// a view holds none of its bytes.
///
/// A set a destroyed view was written into reads bytes that are no longer
/// a view's, as Vulkan has it: the program writes the set again, or does
/// not submit work that reads it.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The view is gone; nothing of the buffer is.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateBufferView`
///
/// EXAMPLES:
/// ```zig
/// fb.DestroyBufferView(device, view);
/// ```
pub fn DestroyBufferView(base: *FacetBase, device: *facet.Device, view: ?*facet.BufferView) void {
    _ = device;
    const made = view orelse return;
    _objects.destroy(base.sys_base, _objects.of(BufferView, made));
}
