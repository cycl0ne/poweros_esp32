// SPDX-License-Identifier: MIT
//! CmdSetDepthBias: what a triangle adds to its depth.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _command = @import("_command.zig");

/// Recorded: the depth bias, for a pipeline that leaves it to commands.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdSetDepthBias(base: *FacetBase, buffer: *facet.CommandBuffer, constant: f32, clamp: f32, slope: f32) void
/// ```
///
/// SINCE: 1.34. LVO -500.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `constant` - how many of the smallest difference the depth
///   attachment holds are added; 65535ths of the range for `d16_unorm`.
/// - `clamp` - the most of the depth range a triangle may be moved by,
///   or the least where it is negative; 0 for no limit.
/// - `slope` - how much of the triangle's steepest slope is added, in
///   depth over a pixel.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The draws after it, with a pipeline whose depth bias is dynamic
/// (`DynamicState.depth_bias`) and whose `depth_bias_enable` is true, move
/// their triangles' depth by these before it is tested and written. A
/// pipeline that gave the numbers itself is not touched by this, and one
/// without `depth_bias_enable` adds nothing whatever is set here.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The three numbers are copied as the command is recorded.
///
/// NOTES:
/// Only triangles are moved, as in Vulkan: points and lines, and triangles
/// drawn as their edges or corners, are drawn where they are. The bias is
/// worked out once a triangle, from the depth plane the rasterizer set up,
/// so it costs nothing a pixel.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateGraphicsPipelines`, `GetPhysicalDeviceFeatures`, `CmdSetBlendConstants`
///
/// EXAMPLES:
/// ```zig
/// // The decal lifted off the wall it is on: a unit of depth, and a
/// // little more where the wall is seen at an angle.
/// fb.CmdSetDepthBias(commands, 1, 0, 1.5);
/// ```
pub fn CmdSetDepthBias(base: *FacetBase, buffer: *facet.CommandBuffer, constant: f32, clamp: f32, slope: f32) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    _command.record(made, _command.SetDepthBias{ .constant = constant, .clamp = clamp, .slope = slope }, u8, &.{});
}
