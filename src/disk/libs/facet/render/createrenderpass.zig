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
/// there is not, or reads one it draws into itself without saying so in a
/// dependency by region (BEHAVIOR);
/// `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The pass has up to 4 subpasses and up to 8 attachments. A subpass draws
/// into 0 to 4 colour attachments - b8g8r8a8_unorm or r8g8b8a8_unorm - 8 in all
/// the subpasses, and may test against a depth attachment, d16_unorm, s8_uint
/// or d16_unorm_s8_uint.
///
/// A subpass of no colour attachment - a depth attachment alone, the
/// shadow map's pass and the depth pre-pass, or no attachment at all - is
/// taken on a device that draws one (`Capabilities.colorless_subpasses`,
/// the cores' since 1.113), and is `error_feature_not_present` on one
/// that does not. What its fragment function colours goes nowhere: Mesa's
/// lavapipe hands llvmpipe a framebuffer of no colour buffers for it
/// (lvp_execute.c:1974-1980), whose tiles have none to load or store
/// (lp_rast.c:126-131) and whose blending is a loop over none
/// (lp_state_fs.c:3618-3622). A subpass with no attachment at all draws
/// over its render area at the count of samples its pipelines say, as
/// Vulkan has it: one, or four on a device that draws them
/// (`framebuffer_no_attachments_sample_counts`, since 1.114; one alone in
/// 1.113).
///
/// An attachment holds one sample a pixel, or four on a device that draws
/// them (`Capabilities.multisampling`, since 1.100), and every attachment of
/// a subpass holds the same count. A colour attachment of four samples may
/// name a resolve attachment, of one sample and of its format, which its
/// samples are averaged into as the subpass ends: over the render area, in
/// every layer of the framebuffer, each pixel the average of its four
/// samples as the attachment holds them, as CmdResolveImage averages them
/// (since 1.109). An attachment of four samples may be an input attachment
/// as well, read a sample at a time (`shader.Attachment.sampleOf`, since
/// 1.111): from the image's memory where an earlier subpass drew it, and
/// from the tile where the subpass reads what it draws. An attachment on a
/// device without the capability holds one sample: one of more is
/// `error_feature_not_present`. A resolve attachment for a colour of one
/// sample, or of another format or count, and attachments of one subpass
/// whose counts differ, are `error_initialization_failed`, as Vulkan has
/// none of them.
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
/// tile starts from what is there. Both want a device whose
/// `stored_depth` is true - every device since 1.47 - and an image bound
/// to memory something is behind, which CreateFramebuffer holds to;
/// otherwise that is `error_feature_not_present`. A depth the V3D stored
/// may be one of the 65535ths away from the one the cores would have
/// stored: the hardware keeps a deeper number and writes its top 16 bits,
/// which is the same where the depth falls on a 65535th and one more where
/// it does not.
///
/// Since 1.38 the stencil keeps its own the same way, by its own two ops:
/// with `stencil_store_op` STORE each tile's stencil, a byte a pixel, is
/// written into its own plane of the image's rows, and with
/// `stencil_load_op` LOAD each tile starts from what is there. That wants
/// a format that holds a stencil - `s8_uint` or `d16_unorm_s8_uint` - and
/// a device whose `stored_stencil` is true, every device again. A format
/// that holds both keeps each pixel's depth and its stencil beside each
/// other, so the four ops are taken on their own: a pass may store the
/// stencil and leave the depth in the tiles, or the other way round.
///
/// Each pair of ops is for its own plane, as in Vulkan: `load_op` and
/// `store_op` for the depth, `stencil_load_op` and `stencil_store_op` for
/// the stencil (VkAttachmentDescription). A pair whose plane the format
/// has not loads and stores nothing, whatever it says - the stencil's of a
/// `d16_unorm`, the depth's of an `s8_uint` - as Mesa's render passes read
/// each pair only for a plane the format has (vk_render_pass.c:1561-1567,
/// :1833-1839; `v3dv_cmd_buffer_check_needs_load`,
/// v3dv_cmd_buffer.c:1533-1544). Until 1.106 such an op was
/// `error_feature_not_present`.
///
/// Keeping either plane of a format that holds **both** - `d16_unorm_s8_uint`
/// - wants `stored_both` as well (since 1.47): the cores write a pixel's
/// planes where they lie in its four bytes, while a device that stores the
/// whole of a tile buffer, the V3D, writes one plane's pixels one after
/// another and so keeps only a format of that plane alone. There such an
/// op is `error_feature_not_present`, and a `d16_unorm` or an `s8_uint`
/// attachment keeps what it holds.
///
/// Two subpasses share a depth attachment either way. One right after the
/// other and with the same colour attachments too goes on in the tiles of
/// the first, which costs nothing at all. Otherwise - another subpass in
/// between, or other colour attachments, so that the tiles are gone - the
/// pass keeps it for them (since 1.52): the part that drew it last writes
/// it into the image's rows and the next one to name it reads it in, both
/// whatever the attachment's own ops say, those being for the whole pass.
/// So the depth of a pass over a scene is still there for a pass over it
/// again, with the colour of something else drawn between them.
///
/// That wants what keeping it always wants: a device whose `stored_depth`
/// is true for the depth and `stored_stencil` for the stencil - and
/// `stored_both` where the format holds both - and an image with memory
/// something is behind, which CreateFramebuffer holds to
/// (`error_feature_not_present` for a transient one, which has none).
///
/// Since 1.37 a subpass may read attachments as well as draw into them:
/// up to 8 `input_attachments`, each read pixel by pixel at the
/// fragment's own place (`shader.Resources.input`, `shader.Attachment`).
/// Such an attachment is read out of the image's memory, so its format is
/// one whose pixels are kept in rows - b8g8r8a8_unorm, r8g8b8a8_unorm or
/// r5g6b5_unorm_pack16, anything else being
/// `error_format_not_supported` - and what it holds is what an earlier
/// subpass drew, or what its load op left there.
///
/// **A depth attachment is read that way too** since 1.62
/// (`Capabilities.sampled_depth`): one plane of it, the one the
/// view's aspect names, the depth as 0 to 1 and the stencil as the whole
/// number it is (`CreateImageView`, `shader.Attachment`). Where an
/// earlier subpass drew that depth, the part which drew it last writes it
/// into the image's rows for this subpass to read, the way a depth two
/// subpasses share is kept (1.52): so it wants `stored_depth`, a stencil
/// `stored_stencil`, and a format holding both `stored_both`. The image
/// is one made IMAGE_USAGE_INPUT_ATTACHMENT, which for a depth means
/// memory behind it and not the tiles alone - a transient one is refused
/// (CreateImage).
///
/// **A subpass may read the colour attachment it is drawing into** since
/// 1.64, which is Vulkan's self-dependency by region: the subpass names
/// one of its own colour attachments as an input attachment, and the pass
/// carries a `SubpassDependency` of that subpass on itself with
/// DEPENDENCY_BY_REGION. It is read as any input attachment is - the
/// `input_attachment` descriptor written with a view of it, and
/// `shader.Fragments.input` then `colorAt` at the fragment's own place -
/// and what it answers there is the tile, which already holds that pixel
/// (since 1.65). So programmable blending costs no copy here: the pixel
/// is where the tiles are.
///
/// Only the fragment's own pixel is read: the rest of the attachment is
/// in other tiles, drawn on other cores or not yet drawn, and reads as
/// transparent black - which is all Vulkan's by-region dependency
/// promises either. A subpass of several colour attachments drawn
/// together reads the first of them this way and no other; reading the
/// depth attachment it draws into is not among this.
///
/// Without that dependency, drawing into an attachment
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
/// dependencies say nothing of what waits for what - a queue's commands
/// are done one after the other - and are read for one thing alone: a
/// subpass's dependency on itself by region, which lets it read the
/// attachment it draws into (since 1.64).
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
    // One sample a pixel, or four where the device draws them (since 1.100).
    for (attachments, 0..) |attachment, index| {
        if (attachment.samples != 1 and !(attachment.samples == 4 and owner.physical.can.multisampling)) return .error_feature_not_present;
        plan.samples[index] = attachment.samples;
    }
    var drawn: [_render.most_attachments]bool = @splat(false);
    // For each depth attachment, the last part that drew into it, or null
    // where no subpass has yet. A later subpass that draws into the same
    // one, with another subpass's tiles in between, has that part write
    // its depth into the image's rows and reads it in again (since 1.52).
    var depths: [_render.most_attachments]?u32 = @splat(null);
    for (info.subpasses[0..info.subpass_count], 0..) |subpass, number| {
        if (subpass.pipeline_bind_point != .graphics) return .error_feature_not_present;
        // The samples every attachment of the subpass holds, which Vulkan
        // has be one count (VUID-VkSubpassDescription-pColorAttachments-09430,
        // VUID-VkSubpassDescription-pDepthStencilAttachment-01418): the
        // first one named says it (since 1.100).
        var samples: ?u32 = null;
        // The colour attachments of its own this subpass reads: the
        // fragment's own pixel, out of the tile (since 1.64).
        var reads_own: [_render.most_attachments]bool = @splat(false);
        var reads_any = false;
        if (subpass.input_attachment_count != 0) {
            if (!owner.physical.can.input_attachments) return .error_feature_not_present;
            if (subpass.input_attachment_count > _render.most_attachments) return .error_feature_not_present;
            const inputs = subpass.input_attachments orelse return .error_initialization_failed;
            for (inputs[0..subpass.input_attachment_count]) |reference| {
                if (reference.attachment == facet.ATTACHMENT_UNUSED) continue;
                if (reference.attachment >= attachments.len) return .error_initialization_failed;
                const read = attachments[reference.attachment];
                // Read out of the image's memory, pixel by pixel, so an
                // earlier subpass has to have drawn it (or it holds what
                // was loaded): a colour format kept in rows, or since
                // 1.62 a depth format, one plane of which is read where
                // it lies, as a sampled depth image's is
                // (`Capabilities.sampled_depth`).
                const depth_read = _image.hasDepth(read.format) or _image.hasStencil(read.format);
                if (depth_read and !owner.physical.can.sampled_depth) return .error_feature_not_present;
                if (!depth_read and _image.rowFormat(read.format) == .none) return .error_format_not_supported;
                // A depth another subpass drew is in that subpass's
                // tiles, so the part that drew it last writes it into
                // the image's rows for this one to read, the way 1.52
                // does for a depth two subpasses share. Which plane the
                // view takes is the view's own doing, so both are kept
                // where the format holds both.
                if (depth_read) if (depths[reference.attachment]) |earlier| {
                    if (_image.hasDepth(read.format)) {
                        if (!owner.physical.can.stored_depth) return .error_feature_not_present;
                        plan.parts[earlier].stores_depth = true;
                    }
                    if (_image.hasStencil(read.format)) {
                        if (!owner.physical.can.stored_stencil) return .error_feature_not_present;
                        plan.parts[earlier].stores_stencil = true;
                    }
                    if (_image.hasDepth(read.format) and _image.hasStencil(read.format) and !owner.physical.can.stored_both) return .error_feature_not_present;
                };
                // Drawn and read in the same subpass: the pixels being
                // read are the ones being written, which is the
                // fragment's own pixel and nothing else. Since 1.64 that
                // is drawn where it lies, in the tile - the pass saying
                // so in a dependency of the subpass on itself, by region,
                // as Vulkan wants - and the fragment function is given
                // what is already there (`shader.Fragments.keptAt`).
                // Without the dependency it is the loop it always was.
                if (subpass.color_attachments) |colors| {
                    for (colors[0..subpass.color_attachment_count]) |drawn_now| {
                        if (drawn_now.attachment != reference.attachment) continue;
                        if (depth_read or !byRegion(info, @intCast(number))) return .error_initialization_failed;
                        if (!owner.physical.can.input_attachments) return .error_feature_not_present;
                        reads_own[reference.attachment] = true;
                        reads_any = true;
                    }
                }
                if (subpass.depth_stencil_attachment) |depth| if (depth.attachment == reference.attachment) return .error_initialization_failed;
            }
        }
        if (subpass.color_attachment_count > _render.most_colors) return .error_feature_not_present;
        // None, on a device that draws a subpass of none (since 1.113).
        if (subpass.color_attachment_count == 0 and !owner.physical.can.colorless_subpasses) return .error_feature_not_present;
        const colors = colorsOf(subpass);
        // facet.library's own flag: the subpass's colour attachments are
        // drawn together, in one pass over the tiles, by a fragment
        // function that writes all of them at once (since 1.51). Without
        // it the subpass is a part for each of them, played over again.
        const together = subpass.flags & facet.SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER != 0;
        if (together and !owner.physical.can.several_outputs) return .error_feature_not_present;
        if (subpass.flags & ~facet.SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER != 0) return .error_feature_not_present;
        // A subpass that reads what it draws is a part of its own: what it
        // reads is the tile as this part starts, so it does not go on in
        // the part before it (since 1.64).
        if (number > 0 and !reads_any and sameTargets(info.subpasses[number - 1], subpass)) {
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
                samples = depth.samples;
                // Each pair of ops for its own plane, and nothing for a
                // plane the format has not (since 1.106).
                loads_depth = tests_depth and depth.load_op == .load;
                stores_depth = tests_depth and depth.store_op == .store;
                loads_stencil = tests_stencil and depth.stencil_load_op == .load;
                stores_stencil = tests_stencil and depth.stencil_store_op == .store;
                // A subpass that goes on in the tiles of the one before
                // it took the `continue` above, so reaching here with an
                // attachment another subpass has already drawn into
                // means those tiles are gone: what it left has to be in
                // the image's rows to be tested against. The part that
                // drew it last writes it there, and this one reads it in
                // - whatever the attachment's own ops say, which are for
                // the whole pass. (Since 1.52.)
                const shared = depths[reference.attachment];
                if (shared != null) {
                    loads_depth = loads_depth or tests_depth;
                    loads_stencil = loads_stencil or tests_stencil;
                }
                if (loads_depth or stores_depth or (shared != null and tests_depth)) {
                    // A depth that outlives the pass is written into the
                    // image's rows and read back from them, which only a
                    // device that draws in the rasterizer's tiles can do.
                    if (!owner.physical.can.stored_depth) return .error_feature_not_present;
                }
                // The stencil keeps its own, in its own plane of those
                // rows, by its own two ops (1.38).
                if (loads_stencil or stores_stencil or (shared != null and tests_stencil)) {
                    if (!owner.physical.can.stored_stencil) return .error_feature_not_present;
                }
                // A format of both planes keeps either only where the
                // device writes a pixel's planes where they lie in it
                // (`stored_both`, since 1.47): one that stores a tile
                // buffer whole writes a plane's own pixels one after
                // another, which those rows are not.
                if ((loads_depth or stores_depth or loads_stencil or stores_stencil or shared != null) and
                    tests_depth and tests_stencil and !owner.physical.can.stored_both) return .error_feature_not_present;
                // The part that drew it last keeps what it left, so that
                // this subpass can read it in.
                if (shared) |earlier| {
                    if (tests_depth) plan.parts[earlier].stores_depth = true;
                    if (tests_stencil) plan.parts[earlier].stores_stencil = true;
                }
                depth_index = reference.attachment;
            }
        }
        plan.subpasses[number] = .{
            .first_part = plan.part_count,
            // A subpass of no colour attachment is the one part, which
            // draws none (since 1.113).
            .part_count = if (together or colors.len == 0) 1 else subpass.color_attachment_count,
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
        for (colors) |reference| {
            if (reference.attachment >= attachments.len) return .error_initialization_failed;
            const count = attachments[reference.attachment].samples;
            if ((samples orelse count) != count) return .error_initialization_failed;
            samples = count;
        }
        whole.samples = samples orelse 1;
        const resolves: []const facet.AttachmentReference = if (subpass.resolve_attachments) |given| given[0..subpass.color_attachment_count] else &.{};
        for (colors, 0..) |reference, k| {
            const color_index = reference.attachment;
            if (color_index >= attachments.len) return .error_initialization_failed;
            if (color_index == depth_index) return .error_initialization_failed;
            for (colors[0..k]) |earlier| if (earlier.attachment == color_index) return .error_initialization_failed;
            const color = attachments[color_index];
            if (!_surface.drawable(color.format)) return .error_format_not_supported;
            const load: _render.ColorLoad = if (color.load_op == .clear and !drawn[color_index]) .clear else .keep;
            // Its resolve attachment: one sample, of its own format, for a
            // colour of more than one. Vulkan's resolve is at the
            // subpass's end, over the render area:
            // VUID-VkSubpassDescription-pResolveAttachments-00848, -00849
            // and -00850.
            const resolve: ?u32 = if (resolves.len == 0 or resolves[k].attachment == facet.ATTACHMENT_UNUSED) null else resolve: {
                const index = resolves[k].attachment;
                if (index >= attachments.len) return .error_initialization_failed;
                const into = attachments[index];
                if (color.samples == 1 or into.samples != 1 or into.format != color.format) return .error_initialization_failed;
                break :resolve index;
            };
            if (together) {
                // The one part draws them all: a plane of each tile for
                // each of them. What it reads of its own is the first of
                // them, that being the one plane a fragment function is
                // given; another of them read as well is the loop it was.
                if (reads_own[color_index]) {
                    if (k != 0) return .error_initialization_failed;
                    whole.reads_target = true;
                }
                whole.colors[whole.color_count] = color_index;
                whole.color_formats[whole.color_count] = color.format;
                whole.color_loads[whole.color_count] = load;
                whole.resolves[whole.color_count] = resolve;
                whole.color_count += 1;
            } else {
                var part = whole;
                part.colors[0] = color_index;
                part.color_formats[0] = color.format;
                part.color_loads[0] = load;
                part.resolves[0] = resolve;
                part.color_count = 1;
                part.reads_target = reads_own[color_index];
                // Each part is the subpass played again from its begin,
                // so each tests against the depth and the stencil the
                // subpass began with. A part before the last that wrote
                // what it left into the image's rows would have the next
                // one read that in instead, and fail a LESS test wherever
                // it had drawn: only the last keeps them, and they all
                // leave the same (since 1.116).
                if (k + 1 < colors.len) {
                    part.stores_depth = false;
                    part.stores_stencil = false;
                }
                plan.parts[plan.part_count] = part;
                plan.part_count += 1;
            }
        }
        if (together or colors.len == 0) {
            plan.parts[plan.part_count] = whole;
            plan.part_count += 1;
        }
        for (colors) |reference| drawn[reference.attachment] = true;
        // A resolve attachment is written by the subpass as well, so its
        // load op is spent there.
        for (resolves) |reference| if (reference.attachment != facet.ATTACHMENT_UNUSED) {
            drawn[reference.attachment] = true;
        };
        // The last part of this subpass is the one a later subpass that
        // shares the depth attachment has keep it: the parts of a subpass
        // drawn once for each colour attachment all leave the same depth,
        // so the last of them is enough. (Since 1.52.)
        if (depth_index) |index| depths[index] = plan.part_count - 1;
    }
    for (plan.parts[0..plan.part_count]) |part| if (part.depth) |depth| if (drawn[depth]) return .error_initialization_failed;
    const made = _objects.create(base.sys_base, _render.RenderPass) orelse return .error_out_of_host_memory;
    made.* = plan;
    render_pass.* = _objects.handle(facet.RenderPass, made);
    return .success;
}

/// Whether the pass says this subpass depends on itself, by region: what
/// Vulkan asks for of a subpass that reads the attachment it is drawing
/// into, and what tells this library to hand the tile's pixels to the
/// fragment function. (Since 1.64.)
fn byRegion(info: *const facet.RenderPassCreateInfo, subpass: u32) bool {
    const given = info.dependencies orelse return false;
    for (given[0..info.dependency_count]) |one| {
        if (one.src_subpass == subpass and one.dst_subpass == subpass and
            one.dependency_flags & facet.DEPENDENCY_BY_REGION != 0) return true;
    }
    return false;
}

/// Whether a subpass draws into just what the one before it does, the
/// same way round.
fn sameTargets(before: facet.SubpassDescription, subpass: facet.SubpassDescription) bool {
    if (before.color_attachment_count != subpass.color_attachment_count) return false;
    // The one before resolves as it ends, which its tiles going on would
    // put after this one's drawing (since 1.100).
    if (before.resolve_attachments != null or subpass.resolve_attachments != null) return false;
    if (before.flags != subpass.flags) return false;
    for (colorsOf(before), colorsOf(subpass)) |a, b| {
        if (a.attachment != b.attachment) return false;
    }
    return depthOf(before) == depthOf(subpass);
}

fn depthOf(subpass: facet.SubpassDescription) u32 {
    const reference = subpass.depth_stencil_attachment orelse return facet.ATTACHMENT_UNUSED;
    return reference.attachment;
}

/// A subpass's colour attachments: none where it has none, whose pointer
/// Vulkan lets be null (since 1.113).
fn colorsOf(subpass: facet.SubpassDescription) []const facet.AttachmentReference {
    if (subpass.color_attachment_count == 0) return &.{};
    return subpass.color_attachments.?[0..subpass.color_attachment_count];
}
