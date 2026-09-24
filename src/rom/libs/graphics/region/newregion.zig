// SPDX-License-Identifier: MPL-2.0
//! NewRegion: an empty region.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const rtg = sdk.rtg;
const TagItem = sdk.utility.TagItem;
const GraphicsBase = @import("../graphics.zig").GraphicsBase;
const _region = @import("_region.zig");
const Region = _region.Region;

/// An empty region.
///
/// SYNOPSIS:
/// ```zig
/// fn NewRegion(gb: *GraphicsBase) ?*Region
/// ```
///
/// SINCE: 0.8. LVO -200.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// A region with nothing in it, or null if there was no memory. An empty
/// region contains no point and meets no rectangle, so it is a safe thing
/// to hold before anything has been put in it.
///
/// BEHAVIOR:
/// The region is the library's own structure behind an opaque pointer: a
/// list of rectangles that never overlap, and their bounds. Nothing is in it
/// until something is added.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It allocates.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `DisposeRegion`, which also frees every rectangle
/// that was put in it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DisposeRegion`, `OrRectRegion`
///
/// EXAMPLES:
/// ```zig
/// const region = gb.NewRegion() orelse return error.NoMemory;
/// defer gb.DisposeRegion(region);
/// ```
pub fn NewRegion(gb: *GraphicsBase) ?*Region {
    const mem = gb.sys_base.AllocVec(@sizeOf(Region), exec.MEMF_CLEAR) orelse return null;
    const region: *Region = @ptrCast(@alignCast(mem));
    region.* = .{};
    return region;
}
