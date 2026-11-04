// SPDX-License-Identifier: MIT
//! CreateRenderPass: a render pass.

const sdk = @import("sdk");
const facet = sdk.facet;
const FacetBase = @import("../facet_base.zig").FacetBase;
const _objects = @import("../_objects.zig");
const Device = @import("../device/_device.zig").Device;
const _render = @import("_render.zig");
const _image = @import("../image/_image.zig");
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
/// - `info` - the attachments and the subpasses that draw into them.
/// - `render_pass` - where the render pass is written; null when it fails.
///
/// RESULT:
/// `success`; `error_feature_not_present` for a pass facet.library does
/// not draw (BEHAVIOR); `error_format_not_supported` for an attachment in
/// a format it cannot draw into, or read as an input attachment;
/// `error_initialization_failed` for a subpass that names an attachment
/// there is not, or reads one it draws into itself;
/// `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The pass has up to 4 subpasses and up to 8 attachments. A subpass draws
/// into 1 to 4 colour attachments - b8g8r8a8_unorm or r8g8b8a8_unorm - 8 in all
/// the subpasses, and may test against a depth attachment, d16_unorm, s8_uint
/// or d16_unorm_s8_uint. No resolve or multisampled attachments.
///
/// The subpasses are drawn one after another. A colour attachment's load op
/// CLEAR clears the render area the first time a subpass names it; LOAD,
/// DONT_CARE and later subpasses keep what the image holds. What is drawn is
/// stored, whatever its store op.
///
/// The depth attachment lives in the rasterizer's tiles, and its load op
/// CLEAR or DONT_CARE - both clear it - and its store op DONT_CARE leave it
/// there, costing no memory at all. Since 1.30 it may outlive the pass
/// instead: with the store op STORE each tile's depth is written into the
/// image's memory as the tile is drawn, and with the load op LOAD each
/// tile starts from what is there. Both want a format that holds a depth
/// and a device whose `stored_depth` is true - every device since 1.47 -
/// and an image bound to memory something is behind, which
/// CreateFramebuffer holds to; otherwise that is
/// `error_feature_not_present`. A depth the V3D stored may be one of the
/// 65535ths away from the one the cores would have stored: the hardware
/// keeps a deeper number and writes its top 16 bits, which is the same
/// where the depth falls on a 65535th and one more where it does not.
///
/// Since 1.38 the stencil keeps its own the same way, by its own two ops:
/// with `stencil_store_op` STORE each tile's stencil, a byte a pixel, is
/// written into its own plane of the image's rows, and with
/// `stencil_load_op` LOAD each tile starts from what is there. That wants
/// a format that holds a stencil - `s8_uint` or `d16_unorm_s8_uint` - and
/// a device whose `stored_stencil` is true, every device again. A format
/// that holds both keeps each pixel's depth and its stencil beside each
/// other, so the four ops are taken on their own: a pass may store the
/// stencil and leave the depth in the tiles, or the other way round. An
/// op for a plane the format has not is `error_feature_not_present`.
///
/// Keeping either plane of a format that holds **both** - `d16_unorm_s8_uint`
/// - wants `stored_both` as well (since 1.47): the cores write a pixel's
/// planes where they lie in its four bytes, while a device that stores the
/// whole of a tile buffer, the V3D, writes one plane's pixels one after
/// another and so keeps only a format of that plane alone. There such an
/// op is `error_feature_not_present`, and a `d16_unorm` or an `s8_uint`
/// attachment keeps what it holds.
///
/// So two subpasses share a depth attachment only one right after the other
/// and with the same colour attachments too, when the second goes on in the
/// tiles of the first; otherwise that is `error_feature_not_present`.
///
/// Since 1.37 a subpass may read attachments as well as draw into them:
/// up to 8 `input_attachments`, each read pixel by pixel at the
/// fragment's own place (`shader.Resources.input`, `shader.Attachment`).
/// Such an attachment is read out of the image's memory, so its format is
/// one whose pixels are kept in rows - b8g8r8a8_unorm, r8g8b8a8_unorm or
/// r5g6b5_unorm_pack16, anything else being
/// `error_format_not_supported` - and what it holds is what an earlier
/// subpass drew, or what its load op left there. A depth attachment is
/// not read that way: it lives in the tiles. Drawing into an attachment
/// and reading it in the same subpass is a loop, which is
/// `error_initialization_failed`, and only a device whose
/// `input_attachments` is true reads any - the cores, not the V3D -
/// others answering `error_feature_not_present`. The pass does not say
/// which descriptor a subpass reads one through: the set written with the
/// `input_attachment` descriptor does (UpdateDescriptorSets), and the
/// image wants IMAGE_USAGE_INPUT_ATTACHMENT (CreateImage).
///
/// A subpass of several colour attachments is drawn once for each, its commands
/// played over, so it costs that much more: its fragment function is called for
/// each, and `shader.Resources.output` says for which. A fixed fragment
/// function has one colour, which every attachment gets.
///
/// Since 1.51 such a subpass may be drawn **together** instead, in one
/// pass over the tiles: SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER in its
/// `flags`, facet.library's own, and every pipeline of it has a fragment
/// entry that writes exactly its colour attachments in the one call
/// (`shader.fragmentOutputs`, `shader.Fragments.colorsOf`); one that does
/// not is `error_invalid_shader_nv` (CreateGraphicsPipelines). The
/// vertices are worked once, the triangles binned once and a quad's
/// fragment function called once for all of them - a G-buffer's three or
/// four planes for the price of one - and each attachment is still
/// blended its own way, into a plane of each tile's own. The flag wants a
/// device whose `several_outputs` is true: the cores, not the V3D, whose
/// fragment programs are the fixed forms and each write the one colour;
/// there it is `error_feature_not_present`, and a subpass without it is
/// drawn as it always was. Any other bit in `flags` is
/// `error_feature_not_present` too.
///
/// Attachments a subpass does not name are left as they are. The
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
    if (info.subpass_count == 0 or info.subpass_count > _render.most_subpasses) return .error_feature_not_present;
    if (info.attachment_count > _render.most_attachments) return .error_feature_not_present;
    const attachments: []const facet.AttachmentDescription = if (info.attachments) |given| given[0..info.attachment_count] else &.{};
    var plan = _render.RenderPass{ .device = owner, .attachment_count = info.attachment_count, .subpass_count = info.subpass_count };
    var drawn: [_render.most_attachments]bool = @splat(false);
    var depths: [_render.most_attachments]bool = @splat(false);
    for (info.subpasses[0..info.subpass_count], 0..) |subpass, number| {
        if (subpass.pipeline_bind_point != .graphics) return .error_feature_not_present;
        // A resolve attachment is multisampling's, which there is none of.
        if (subpass.resolve_attachments != null) return .error_feature_not_present;
        if (subpass.input_attachment_count != 0) {
            if (!owner.physical.features.input_attachments) return .error_feature_not_present;
            if (subpass.input_attachment_count > _render.most_attachments) return .error_feature_not_present;
            const inputs = subpass.input_attachments orelse return .error_initialization_failed;
            for (inputs[0..subpass.input_attachment_count]) |reference| {
                if (reference.attachment == facet.ATTACHMENT_UNUSED) continue;
                if (reference.attachment >= attachments.len) return .error_initialization_failed;
                const read = attachments[reference.attachment];
                // Read out of the image's memory, pixel by pixel, so it
                // is a colour format kept in rows and an earlier subpass
                // has to have drawn it (or it holds what was loaded).
                if (_image.rowFormat(read.format) == .none) return .error_format_not_supported;
                if (read.samples != 1) return .error_feature_not_present;
                // Drawn and read in the same subpass is a loop: the
                // pixels being read are the ones being written.
                if (subpass.color_attachments) |colors| {
                    for (colors[0..subpass.color_attachment_count]) |drawn_now| {
                        if (drawn_now.attachment == reference.attachment) return .error_initialization_failed;
                    }
                }
                if (subpass.depth_stencil_attachment) |depth| if (depth.attachment == reference.attachment) return .error_initialization_failed;
            }
        }
        if (subpass.color_attachment_count == 0 or subpass.color_attachment_count > _render.most_colors) return .error_feature_not_present;
        const colors = subpass.color_attachments.?[0..subpass.color_attachment_count];
        // facet.library's own flag: the subpass's colour attachments are
        // drawn together, in one pass over the tiles, by a fragment
        // function that writes all of them at once (since 1.51). Without
        // it the subpass is a part for each of them, played over again.
        const together = subpass.flags & facet.SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER != 0;
        if (together and !owner.physical.features.several_outputs) return .error_feature_not_present;
        if (subpass.flags & ~facet.SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER != 0) return .error_feature_not_present;
        if (number > 0 and sameTargets(info.subpasses[number - 1], subpass)) {
            plan.subpasses[number] = plan.subpasses[number - 1];
            plan.subpasses[number].joined = true;
            continue;
        }
        var depth_index: ?u32 = null;
        var tests_depth = false;
        var tests_stencil = false;
        var loads_depth = false;
        var stores_depth = false;
        var loads_stencil = false;
        var stores_stencil = false;
        if (subpass.depth_stencil_attachment) |reference| {
            if (reference.attachment != facet.ATTACHMENT_UNUSED) {
                if (reference.attachment >= attachments.len) return .error_initialization_failed;
                const depth = attachments[reference.attachment];
                tests_depth = _image.hasDepth(depth.format);
                tests_stencil = _image.hasStencil(depth.format);
                if (!tests_depth and !tests_stencil) return .error_format_not_supported;
                if (depth.samples != 1) return .error_feature_not_present;
                loads_depth = depth.load_op == .load;
                stores_depth = depth.store_op == .store;
                loads_stencil = depth.stencil_load_op == .load;
                stores_stencil = depth.stencil_store_op == .store;
                if (loads_depth or stores_depth) {
                    // A depth that outlives the pass is written into the
                    // image's rows and read back from them, which only a
                    // device that draws in the rasterizer's tiles can do,
                    // and only for a format whose rows hold a depth.
                    if (!owner.physical.features.stored_depth) return .error_feature_not_present;
                    if (!tests_depth) return .error_feature_not_present;
                }
                // The stencil keeps its own, in its own plane of those
                // rows, by its own two ops (1.38).
                if (loads_stencil or stores_stencil) {
                    if (!owner.physical.features.stored_stencil) return .error_feature_not_present;
                    if (!tests_stencil) return .error_feature_not_present;
                }
                // A format of both planes keeps either only where the
                // device writes a pixel's planes where they lie in it
                // (`stored_both`, since 1.47): one that stores a tile
                // buffer whole writes a plane's own pixels one after
                // another, which those rows are not.
                if ((loads_depth or stores_depth or loads_stencil or stores_stencil) and
                    tests_depth and tests_stencil and !owner.physical.features.stored_both) return .error_feature_not_present;
                // Two subpasses share it only in the same tiles.
                if (depths[reference.attachment]) return .error_feature_not_present;
                depths[reference.attachment] = true;
                depth_index = reference.attachment;
            }
        }
        plan.subpasses[number] = .{
            .first_part = plan.part_count,
            .part_count = if (together) 1 else subpass.color_attachment_count,
            .joined = false,
        };
        if (plan.part_count + plan.subpasses[number].part_count > _render.most_parts) return .error_feature_not_present;
        var whole = _render.Part{
            .color_count = 0,
            .depth = depth_index,
            .tests_depth = tests_depth,
            .tests_stencil = tests_stencil,
            .loads_depth = loads_depth,
            .stores_depth = stores_depth,
            .loads_stencil = loads_stencil,
            .stores_stencil = stores_stencil,
        };
        for (colors, 0..) |reference, k| {
            const color_index = reference.attachment;
            if (color_index >= attachments.len) return .error_initialization_failed;
            if (color_index == depth_index) return .error_initialization_failed;
            for (colors[0..k]) |earlier| if (earlier.attachment == color_index) return .error_initialization_failed;
            const color = attachments[color_index];
            if (!_surface.drawable(color.format)) return .error_format_not_supported;
            if (color.samples != 1) return .error_feature_not_present;
            const load: _render.ColorLoad = if (color.load_op == .clear and !drawn[color_index]) .clear else .keep;
            if (together) {
                // The one part draws them all: a plane of each tile for
                // each of them.
                whole.colors[whole.color_count] = color_index;
                whole.color_formats[whole.color_count] = color.format;
                whole.color_loads[whole.color_count] = load;
                whole.color_count += 1;
            } else {
                var part = whole;
                part.colors[0] = color_index;
                part.color_formats[0] = color.format;
                part.color_loads[0] = load;
                part.color_count = 1;
                plan.parts[plan.part_count] = part;
                plan.part_count += 1;
            }
        }
        if (together) {
            plan.parts[plan.part_count] = whole;
            plan.part_count += 1;
        }
        for (colors) |reference| drawn[reference.attachment] = true;
    }
    for (plan.parts[0..plan.part_count]) |part| if (part.depth) |depth| if (drawn[depth]) return .error_initialization_failed;
    const made = _objects.create(base.sys_base, _render.RenderPass) orelse return .error_out_of_host_memory;
    made.* = plan;
    render_pass.* = _objects.handle(facet.RenderPass, made);
    return .success;
}

/// Whether a subpass draws into just what the one before it does, the
/// same way round.
fn sameTargets(before: facet.SubpassDescription, subpass: facet.SubpassDescription) bool {
    if (before.color_attachment_count != subpass.color_attachment_count) return false;
    if (before.flags != subpass.flags) return false;
    for (before.color_attachments.?[0..before.color_attachment_count], subpass.color_attachments.?[0..subpass.color_attachment_count]) |a, b| {
        if (a.attachment != b.attachment) return false;
    }
    return depthOf(before) == depthOf(subpass);
}

fn depthOf(subpass: facet.SubpassDescription) u32 {
    const reference = subpass.depth_stencil_attachment orelse return facet.ATTACHMENT_UNUSED;
    return reference.attachment;
}
