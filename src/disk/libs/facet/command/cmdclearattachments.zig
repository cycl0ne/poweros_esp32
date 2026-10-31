// SPDX-License-Identifier: MIT
//! CmdClearAttachments: parts of a render pass's attachments cleared, in the middle of it.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const _command = @import("_command.zig");
const _render = @import("../render/_render.zig");

/// Recorded: parts of a render pass's attachments cleared, in the middle of it.
///
/// SYNOPSIS:
/// ```zig
/// fn CmdClearAttachments(base: *FacetBase, buffer: *facet.CommandBuffer, attachment_count: u32, attachments: [*]const facet.ClearAttachment, rect_count: u32, rects: [*]const facet.ClearRect) void
/// ```
///
/// SINCE: 1.16. LVO -400.
///
/// INPUTS:
/// - `buffer` - a command buffer recording.
/// - `attachment_count`, `attachments` - what to clear: IMAGE_ASPECT_COLOR for
///   the colour attachment, and IMAGE_ASPECT_DEPTH and IMAGE_ASPECT_STENCIL.
/// - `rect_count`, `rects` - where: inside the render area.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// Inside a render pass, whatever draws there before or after it. The scissor
/// and the pipeline bound have no part in it, and nothing bound changes.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// What is given is copied as the command is recorded; the images and buffers
/// have to last until it has been played.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CmdBeginRenderPass`
///
/// EXAMPLES:
/// ```zig
/// fb.CmdClearAttachments(commands, 1, @ptrCast(&attachment), 1, @ptrCast(&rect));
/// ```
pub fn CmdClearAttachments(base: *FacetBase, buffer: *facet.CommandBuffer, attachment_count: u32, attachments: [*]const facet.ClearAttachment, rect_count: u32, rects: [*]const facet.ClearRect) void {
    _ = base;
    const made = _command.recording(buffer) orelse return;
    for (attachments[0..attachment_count]) |*attachment| for (rects[0..rect_count]) |*rect| {
        const aspect = attachment.aspect_mask;
        const command = _command.ClearAttachment{
            .aspect_mask = aspect,
            .rect = rect.rect,
            .color = if (aspect & facet.IMAGE_ASPECT_COLOR != 0) _render.colorOf(attachment.clear_value.color) else 0,
            .depth = if (aspect & (facet.IMAGE_ASPECT_DEPTH | facet.IMAGE_ASPECT_STENCIL) != 0) attachment.clear_value.depth_stencil.depth else 0,
            .stencil = if (aspect & (facet.IMAGE_ASPECT_DEPTH | facet.IMAGE_ASPECT_STENCIL) != 0) attachment.clear_value.depth_stencil.stencil else 0,
        };
        _command.record(made, command, u8, &.{});
    };
}
