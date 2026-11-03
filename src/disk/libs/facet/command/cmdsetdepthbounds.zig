// SPDX-License-Identifier: MIT
//! CmdSetDepthBounds: the depths a pixel is kept between.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: the depth bounds, for a pipeline that leaves them to commands.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdSetDepthBounds(base: *FacetBase, buffer: *facet.CommandBuffer, min: f32, max: f32) void
/// ```
///
/// SINCE: 1.40. LVO -516.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `min`, `max` - the depths, 0 to 1, a pixel's **stored** depth has to
///   lie between to be drawn; outside 0 to 1 they are held to it.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The draws after it, with a pipeline whose depth bounds are dynamic
/// (`DynamicState.depth_bounds`) and whose `depth_bounds_test_enable` is
/// true, drop a pixel whose depth attachment holds a depth outside these.
/// It is the depth already there that is looked at, not the one being
/// drawn, and the test comes before the stencil's: a pixel the bounds drop
/// leaves the stencil as it is.
///
/// A pipeline that gave the numbers itself is not touched by this, and one
/// without `depth_bounds_test_enable` drops nothing whatever is set here.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The two numbers are copied as the command is recorded.
///
/// NOTES:
/// `min` above `max` keeps nothing, as in Vulkan, and a pass whose depth
/// attachment is only in the tiles still has a depth to look at: the
/// clear's, where nothing was drawn. A draw whose bounds are tested is
/// drawn a pixel at a time, as one with a stencil test is, so it costs
/// more than the quads the fast paths walk.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateGraphicsPipelines`, `GetPhysicalDeviceFeatures`, `CmdSetDepthBias`
///
/// EXAMPLES:
/// ```zig
/// // The nearer half of the depth alone: a light's volume, drawn only
/// // where what is there is near enough to be lit.
/// fb.CmdSetDepthBounds(commands, 0, 0.5);
/// ```
pub fn CmdSetDepthBounds(base: *FacetBase, buffer: *facet.CommandBuffer, min: f32, max: f32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.SetDepthBounds{ .min = min, .max = max }, u8, &.{});
}
