// SPDX-License-Identifier: MIT
//! CreateRenderPass: a render pass.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _render = @import("_render.zig");
const _surface = @import("../surface/_surface.zig");

/// A render pass: the attachments it draws into, what each starts with and what is kept of it.
///
/// SYNOPSIS:
/// ```zig
/// fn CreateRenderPass(base: *FacetBase, device: *facet.Device, info: *const facet.RenderPassCreateInfo, render_pass: *?*facet.RenderPass) facet.Result
/// ```
///
/// SINCE: 1.0. LVO -204.
///
/// INPUTS:
/// - `device` - the device.
/// - `info` - the attachments and the one subpass that draws into them.
/// - `render_pass` - where the render pass is written; null when it fails.
///
/// RESULT:
/// `success`; `error_feature_not_present` for a pass facet.library does
/// not draw (BEHAVIOR); `error_format_not_supported` for an attachment in
/// a format it cannot draw into; `error_initialization_failed` for a
/// subpass that names an attachment there is not; `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The pass has one subpass, which draws into one colour attachment -
/// b8g8r8a8_unorm or r8g8b8a8_unorm - and may test against a depth
/// attachment, d16_unorm. No input, resolve or multisampled attachments.
///
/// The colour attachment's load op CLEAR clears the render area; LOAD and
/// DONT_CARE keep what the image holds. What is drawn is stored, whatever
/// its store op. The depth attachment's load op is CLEAR or DONT_CARE -
/// both clear it - and its store op DONT_CARE: the depth lives in the
/// rasterizer's tiles alone and is never stored.
///
/// Attachments the subpass does not name are left as they are. The
/// dependencies are not looked at: a queue's commands are done one after
/// the other.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The render pass is the caller's, until DestroyRenderPass. The arrays
/// in `info` are read during the call alone.
///
/// NOTES:
/// LOAD and DONT_CARE are the same: a tile nothing is drawn into is
/// neither read nor written, so keeping costs nothing there, where clearing
/// writes every tile.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateFramebuffer`, `CmdBeginRenderPass`, `DestroyRenderPass`
///
/// EXAMPLES:
/// ```zig
/// const color = facet.AttachmentDescription{ .format = .b8g8r8a8_unorm, .load_op = .clear, .store_op = .store, .final_layout = .present_src };
/// const color_ref = facet.AttachmentReference{ .attachment = 0, .layout = .color_attachment_optimal };
/// const subpass = facet.SubpassDescription{ .color_attachment_count = 1, .color_attachments = @ptrCast(&color_ref) };
/// var pass: ?*facet.RenderPass = null;
/// _ = fb.CreateRenderPass(device, &.{ .attachment_count = 1, .attachments = @ptrCast(&color), .subpass_count = 1, .subpasses = @ptrCast(&subpass) }, &pass);
/// ```
pub fn CreateRenderPass(base: *FacetBase, device: *facet.Device, info: *const facet.RenderPassCreateInfo, render_pass: *?*facet.RenderPass) facet.Result {
    render_pass.* = null;
    const owner = _objects.of(Device, device);
    if (info.subpass_count != 1) return .error_feature_not_present;
    const attachments: []const facet.AttachmentDescription = if (info.attachments) |given| given[0..info.attachment_count] else &.{};
    const subpass = info.subpasses[0];
    if (subpass.pipeline_bind_point != .graphics) return .error_feature_not_present;
    if (subpass.input_attachment_count != 0 or subpass.resolve_attachments != null) return .error_feature_not_present;
    if (subpass.color_attachment_count != 1) return .error_feature_not_present;
    const color_index = subpass.color_attachments.?[0].attachment;
    if (color_index >= attachments.len) return .error_initialization_failed;
    const color = attachments[color_index];
    if (!_surface.drawable(color.format)) return .error_format_not_supported;
    if (color.samples != 1) return .error_feature_not_present;
    var depth_index: ?u32 = null;
    if (subpass.depth_stencil_attachment) |reference| {
        if (reference.attachment != facet.ATTACHMENT_UNUSED) {
            if (reference.attachment >= attachments.len or reference.attachment == color_index) return .error_initialization_failed;
            const depth = attachments[reference.attachment];
            if (depth.format != .d16_unorm) return .error_format_not_supported;
            if (depth.samples != 1 or depth.load_op == .load or depth.store_op == .store) return .error_feature_not_present;
            depth_index = reference.attachment;
        }
    }
    const made = _objects.create(base.sys_base, _render.RenderPass) orelse return .error_out_of_host_memory;
    made.* = .{
        .device = owner,
        .attachment_count = info.attachment_count,
        .color = color_index,
        .depth = depth_index,
        .color_format = color.format,
        .color_load = if (color.load_op == .clear) .clear else .keep,
    };
    render_pass.* = _objects.handle(facet.RenderPass, made);
    return .success;
}
