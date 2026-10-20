// SPDX-License-Identifier: MIT
//! CmdBeginRenderPass: a render pass begun.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const _render = @import("../render/_render.zig");

/// Recorded: a render pass begun, drawing into a framebuffer.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdBeginRenderPass(base: *FacetBase, buffer: *facet.CommandBuffer, info: *const facet.RenderPassBeginInfo, contents: facet.SubpassContents) void
/// ```
///
/// SINCE: 1.0. LVO -276.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `info` - the render pass, the framebuffer, the rectangle drawn in, and
///   the clear values: one for each attachment, in their order, up to the
///   last that is cleared.
/// - `contents` - `inline`: the draws are recorded in this buffer.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Played, the rasterizer's frame begins over the render area of the
/// framebuffer's colour attachment, cut to the framebuffer: cleared to the
/// colour attachment's clear value where its load op is CLEAR, else kept,
/// and with the depth cleared to the depth attachment's - 1.0 where it has
/// none - as each tile starts. The draws until CmdEndRenderPass are
/// gathered; the tiles are drawn and stored when it ends. A pass begun in
/// another ends it first.
///
/// The tiles keep 8 bits a channel whatever the colour attachment's
/// format, and are drawn and blended so. Stored into R5G6B5 they are
/// dithered, 4 x 4 ordered over the image's pixels; kept from one, a pixel
/// is read as the least colour that packs to it again, so that what no
/// draw covers is stored as it was.
///
/// A pass whose framebuffer's colour image is not bound draws nothing.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The clear values are copied as the command is recorded. The render
/// pass, the framebuffer and its views have to last until the work is
/// done.
///
/// NOTES:
/// Draws are recorded between CmdBeginRenderPass and CmdEndRenderPass; a
/// draw recorded outside a pass draws nothing.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdEndRenderPass`, `CreateRenderPass`, `CreateFramebuffer`
///
/// EXAMPLES:
/// ```zig
/// const clear = facet.ClearValue{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };
/// fb.CmdBeginRenderPass(commands, &.{ .render_pass = pass.?, .framebuffer = frame.?, .render_area = .{ .extent = .{ .width = 800, .height = 600 } }, .clear_value_count = 1, .clear_values = @ptrCast(&clear) }, .@"inline");
/// ```
pub fn CmdBeginRenderPass(base: *FacetBase, buffer: *facet.CommandBuffer, info: *const facet.RenderPassBeginInfo, contents: facet.SubpassContents) void {
    _ = base;
    _ = contents;
    const made = _command.recording(buffer) orelse return;
    const pass = _objects.of(_render.RenderPass, info.render_pass);
    const clears: []const facet.ClearValue = if (info.clear_values) |values| values[0..info.clear_value_count] else &.{};
    const command = _command.BeginRenderPass{
        .render_pass = pass,
        .framebuffer = _objects.of(_render.Framebuffer, info.framebuffer),
        .area = info.render_area,
        .clear_color = if (pass.color < clears.len) _render.colorOf(clears[pass.color].color) else 0xFF00_0000,
        .clear_depth = if (pass.depth) |depth| (if (depth < clears.len) _render.depthOf(clears[depth].depth_stencil) else 0xFFFF) else 0xFFFF,
    };
    _command.record(made, command, u8, &.{});
}
