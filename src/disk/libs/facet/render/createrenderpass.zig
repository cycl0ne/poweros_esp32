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
/// not draw (BEHAVIOR); `error_validation_failed` for no subpass at all, or
/// a subpass of another bind point than graphics, of more colour
/// attachments than `PhysicalDeviceLimits.max_color_attachments`, or of a
/// flag that is none of Vulkan's or facet.library's own
/// (VUID-VkRenderPassCreateInfo-subpassCount-arraylength,
/// VUID-VkSubpassDescription-pipelineBindPoint-04952,
/// -colorAttachmentCount-00845, -flags-parameter;
/// `error_feature_not_present` until 1.133);
/// `error_validation_failed` as well for an attachment whose format's
/// features have not got what its use asks: COLOR_ATTACHMENT for a
/// colour, DEPTH_STENCIL_ATTACHMENT for a depth, and one of the two for an
/// input attachment (VUID-VkSubpassDescription-pColorAttachments-02648,
/// -pDepthStencilAttachment-02650, -pInputAttachments-02647;
/// `error_format_not_supported` until 1.135, and `error_feature_not_present`
/// for a d16_unorm_s8_uint one that keeps a plane on a device without
/// `stored_both`) - though a d16_unorm_s8_uint depth attachment that keeps
/// neither plane is drawn on such a device, the V3D, whose format query
/// gives it no DEPTH_STENCIL_ATTACHMENT (BEHAVIOR; docs/facet-vulkan10.md
/// item 94), as an s8_uint one that keeps nothing would be on a device
/// without `stored_stencil`, which no device is, one that keeps its
/// stencil being `error_feature_not_present` there -
/// for an attachment of a count of
/// samples that is none of Vulkan's (VUID-VkAttachmentDescription-samples-parameter;
/// `error_feature_not_present` until 1.134), and for a subpass that names
/// an attachment there is not, or none where it counts some; attachments
/// of one subpass of different counts of samples; a resolve attachment
/// for an unused colour or one of one sample, or of more than one sample
/// or another format than its colour's; a colour attachment that is the
/// depth attachment as well, or one named twice; a colour attachment of
/// a depth format that it reads as an input attachment as well, or a
/// depth attachment of a colour format that it reads so
/// (VUID-VkRenderPassCreateInfo-attachment-00834,
/// VUID-VkSubpassDescription-pInputAttachments-parameter,
/// -pColorAttachments-parameter, -pColorAttachments-09430,
/// -pDepthStencilAttachment-01418, -pResolveAttachments-00847 to -00850,
/// -pDepthStencilAttachment-04438, -pColorAttachments-02648,
/// -pDepthStencilAttachment-02650, and for the one named twice the render
/// pass chapter under VkAttachmentDescription: "A given attachment index
/// must not be used multiple times in a single subpass";
/// `error_initialization_failed` until 1.134);
/// `error_feature_not_present` for a subpass that reads its own depth
/// attachment, which Vulkan allows and this library does not draw
/// (docs/facet-vulkan10.md item 92), and for one of colours drawn together
/// that reads another than the first, which only this library's own
/// SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER asks for (item 80; both
/// `error_initialization_failed` until 1.134); `error_out_of_host_memory`.
///
/// BEHAVIOR:
/// The pass has up to 4 subpasses and up to 8 attachments. A subpass draws
/// into 0 to 4 colour attachments - b8g8r8a8_unorm, r8g8b8a8_unorm or
/// r5g6b5_unorm_pack16 - 8 in all
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
/// whose counts differ, are `error_validation_failed`, as Vulkan has none
/// of them (`error_initialization_failed` until 1.134).
///
/// A colour attachment of a subpass may be ATTACHMENT_UNUSED: what the
/// fragment function writes at that location is discarded, and the
/// locations after it keep their attachments, as Vulkan has it (since
/// 1.118). Mesa's render pass gives such a reference no image view
/// (vk_render_pass.c:1924-1930), and lavapipe gives it no colour buffer
/// (lvp_execute.c:1984-1999). A subpass drawn a part for each colour
/// attachment has no part for it, and one whose every colour is unused is
/// drawn as a subpass of none. One whose colours go together
/// (SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER) would have a plane in its tiles
/// with no image behind it, and is `error_feature_not_present`. A resolve
/// attachment for an unused colour is `error_validation_failed`
/// (VUID-VkSubpassDescription-pResolveAttachments-00847;
/// `error_initialization_failed` until 1.134).
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
/// op is `error_validation_failed`, GetPhysicalDeviceFormatProperties
/// giving the format no DEPTH_STENCIL_ATTACHMENT on such a device
/// (VUID-VkSubpassDescription-pDepthStencilAttachment-02650;
/// `error_feature_not_present` until 1.135), and a `d16_unorm` or an
/// `s8_uint` attachment keeps what it holds. A `d16_unorm_s8_uint`
/// attachment that keeps neither plane is drawn there all the same, in
/// the tiles alone, though it breaks the same rule
/// (docs/facet-vulkan10.md item 94).
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
/// r5g6b5_unorm_pack16, anything else being `error_validation_failed`
/// (since 1.135; `error_format_not_supported` before), as no other colour
/// format has COLOR_ATTACHMENT - and what it holds is what an earlier
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
/// 1.64: the subpass names one of its own colour attachments as an input
/// attachment, which Vulkan allows - "the same view can be used
/// simultaneously as an input and color or depth/stencil attachment".
/// Until 1.134 the pass also had to carry Vulkan's self-dependency by
/// region, a `SubpassDependency` of that subpass on itself with
/// DEPENDENCY_BY_REGION; it is not read now. It is read as any input attachment is - the
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
/// together reads the first of them this way, and another of them is
/// `error_feature_not_present`: only the library's own flag draws them
/// together, and that goes with the flag (docs/facet-vulkan10.md item 80).
/// Reading the depth attachment it draws into is not among this either,
/// and is `error_feature_not_present` as well (item 92; both
/// `error_initialization_failed` until 1.134).
///
/// Without that dependency the subpass is drawn the same way since 1.134.
/// Vulkan allows such a pass - a feedback loop, whose reads it leaves
/// undefined where nothing orders the write before them - and the tile's
/// pixel is an answer it allows; until then the pass was refused, with
/// `error_initialization_failed`. Only a device whose `input_attachments`
/// is true reads any - the cores, not the V3D - others answering
/// `error_feature_not_present`. The pass does not say
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
/// drawn as it always was. Any other bit in `flags` is none of Vulkan
/// 1.0's (VUID-VkSubpassDescription-flags-parameter): `error_validation_failed`
/// since 1.133, `error_feature_not_present` before.
///
/// Attachments a subpass does not name are left as they are. The
/// dependencies say nothing of what waits for what - a queue's commands
/// are done one after the other - and are not read. From 1.64 to 1.133
/// one thing was read of them: a subpass's dependency on itself by
/// region, without which it could not read the attachment it draws into.
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
    if (info.subpass_count == 0) return .error_validation_failed;
    if (info.subpass_count > _render.most_subpasses) return .error_feature_not_present;
    if (info.attachment_count > _render.most_attachments) return .error_feature_not_present;
    const attachments: []const facet.AttachmentDescription = if (info.attachments) |given| given[0..info.attachment_count] else &.{};
    var plan = _render.RenderPass{ .device = owner, .attachment_count = info.attachment_count, .subpass_count = info.subpass_count };
    // One of Vulkan's counts, a power of two up to 64
    // (VUID-VkAttachmentDescription-samples-parameter; since 1.134,
    // `error_feature_not_present` before), and of those one sample a
    // pixel, or four where the device draws them (since 1.100).
    for (attachments, 0..) |attachment, index| {
        const samples = attachment.samples;
        if (samples == 0 or samples > 64 or samples & (samples - 1) != 0) return .error_validation_failed;
        if (samples != 1 and !(samples == 4 and owner.physical.can.multisampling)) return .error_feature_not_present;
        plan.samples[index] = samples;
    }
    var drawn: [_render.most_attachments]bool = @splat(false);
    // For each depth attachment, the last part that drew into it, or null
    // where no subpass has yet. A later subpass that draws into the same
    // one, with another subpass's tiles in between, has that part write
    // its depth into the image's rows and reads it in again (since 1.52).
    var depths: [_render.most_attachments]?u32 = @splat(null);
    for (info.subpasses[0..info.subpass_count], 0..) |subpass, number| {
        if (subpass.pipeline_bind_point != .graphics) return .error_validation_failed;
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
            // VUID-VkSubpassDescription-pInputAttachments-parameter.
            const inputs = subpass.input_attachments orelse return .error_validation_failed;
            for (inputs[0..subpass.input_attachment_count]) |reference| {
                if (reference.attachment == facet.ATTACHMENT_UNUSED) continue;
                // VUID-VkRenderPassCreateInfo-attachment-00834.
                if (reference.attachment >= attachments.len) return .error_validation_failed;
                const read = attachments[reference.attachment];
                // Read out of the image's memory, pixel by pixel, so an
                // earlier subpass has to have drawn it (or it holds what
                // was loaded): a colour format kept in rows, or since
                // 1.62 a depth format, one plane of which is read where
                // it lies, as a sampled depth image's is
                // (`Capabilities.sampled_depth`).
                const depth_read = _image.hasDepth(read.format) or _image.hasStencil(read.format);
                if (depth_read and !owner.physical.can.sampled_depth) return .error_feature_not_present;
                // VUID-VkSubpassDescription-pInputAttachments-02647: the
                // colour formats kept in rows are those `_format.describe`
                // gives COLOR_ATTACHMENT.
                if (!depth_read and _image.rowFormat(read.format) == .none) return .error_validation_failed;
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
                    // Where both are not kept, `_format.describe` gives a
                    // format of both planes neither COLOR_ATTACHMENT nor
                    // DEPTH_STENCIL_ATTACHMENT
                    // (VUID-VkSubpassDescription-pInputAttachments-02647;
                    // `error_feature_not_present` until 1.135). No device
                    // reaches here today: the V3D reads no input
                    // attachment.
                    if (_image.hasDepth(read.format) and _image.hasStencil(read.format) and !owner.physical.can.stored_both) return .error_validation_failed;
                };
                // Drawn and read in the same subpass: the pixels being
                // read are the ones being written, which is the
                // fragment's own pixel and nothing else. Since 1.64 that
                // is drawn where it lies, in the tile, and the fragment
                // function is given what is already there
                // (`shader.Fragments.keptAt`). Until 1.134 the pass had to
                // say so in a dependency of the subpass on itself, by
                // region; Vulkan allows the loop without one and leaves
                // what it reads undefined, and it is drawn the same way.
                if (subpass.color_attachments) |colors| {
                    for (colors[0..subpass.color_attachment_count]) |drawn_now| {
                        if (drawn_now.attachment != reference.attachment) continue;
                        // A colour attachment of a depth format, which no
                        // device draws into (VUID-VkSubpassDescription-pColorAttachments-02648).
                        if (depth_read) return .error_validation_failed;
                        if (!owner.physical.can.input_attachments) return .error_feature_not_present;
                        reads_own[reference.attachment] = true;
                        reads_any = true;
                    }
                }
                // Its own depth attachment, tested and read at once in a
                // layout of both, which Vulkan allows: the depth is in the
                // tile, and an input attachment is read from the image's
                // rows (docs/facet-vulkan10.md item 92). An attachment of a
                // colour format is no depth attachment at all
                // (VUID-VkSubpassDescription-pDepthStencilAttachment-02650).
                if (subpass.depth_stencil_attachment) |depth| {
                    if (depth.attachment == reference.attachment) return if (depth_read) .error_feature_not_present else .error_validation_failed;
                }
            }
        }
        // The device's `max_color_attachments` (VUID-VkSubpassDescription-colorAttachmentCount-00845).
        if (subpass.color_attachment_count > _render.most_colors) return .error_validation_failed;
        // None, on a device that draws a subpass of none (since 1.113).
        if (subpass.color_attachment_count == 0 and !owner.physical.can.colorless_subpasses) return .error_feature_not_present;
        // VUID-VkSubpassDescription-pColorAttachments-parameter (since
        // 1.134; a panic before).
        if (subpass.color_attachment_count != 0 and subpass.color_attachments == null) return .error_validation_failed;
        const colors = colorsOf(subpass);
        // facet.library's own flag: the subpass's colour attachments are
        // drawn together, in one pass over the tiles, by a fragment
        // function that writes all of them at once (since 1.51). Without
        // it the subpass is a part for each of them, played over again.
        const together = subpass.flags & facet.SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER != 0;
        if (together and !owner.physical.can.several_outputs) return .error_feature_not_present;
        if (subpass.flags & ~facet.SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER != 0) return .error_validation_failed;
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
                // VUID-VkRenderPassCreateInfo-attachment-00834.
                if (reference.attachment >= attachments.len) return .error_validation_failed;
                const depth = attachments[reference.attachment];
                tests_depth = _image.hasDepth(depth.format);
                tests_stencil = _image.hasStencil(depth.format);
                // VUID-VkSubpassDescription-pDepthStencilAttachment-02650.
                if (!tests_depth and !tests_stencil) return .error_validation_failed;
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
                // another, which those rows are not. Where it does not,
                // `_format.describe` gives such a format no
                // DEPTH_STENCIL_ATTACHMENT
                // (VUID-VkSubpassDescription-pDepthStencilAttachment-02650;
                // `error_feature_not_present` until 1.135). One that keeps
                // neither plane is drawn there all the same, in the tiles
                // alone, though it breaks the same rule
                // (docs/facet-vulkan10.md item 94).
                if ((loads_depth or stores_depth or loads_stencil or stores_stencil or shared != null) and
                    tests_depth and tests_stencil and !owner.physical.can.stored_both) return .error_validation_failed;
                // The part that drew it last keeps what it left, so that
                // this subpass can read it in.
                if (shared) |earlier| {
                    if (tests_depth) plan.parts[earlier].stores_depth = true;
                    if (tests_stencil) plan.parts[earlier].stores_stencil = true;
                }
                depth_index = reference.attachment;
            }
        }
        // The colour attachments it draws: those not named
        // ATTACHMENT_UNUSED, writes to whose location are discarded (since
        // 1.118). Drawn apart, an unused one is no part at all, and the
        // parts after it keep their locations (`Part.output`). Drawn
        // together, it would be a plane of the tiles with no image behind
        // it, which a part cannot have yet.
        var used: u32 = 0;
        for (colors) |reference| {
            if (reference.attachment != facet.ATTACHMENT_UNUSED) {
                used += 1;
            } else if (together) return .error_feature_not_present;
        }
        plan.subpasses[number] = .{
            .first_part = plan.part_count,
            // A subpass of no colour attachment is the one part, which
            // draws none (since 1.113), as is one whose every colour is
            // unused (since 1.118).
            .part_count = if (together or used == 0) 1 else used,
            .color_count = subpass.color_attachment_count,
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
            if (reference.attachment == facet.ATTACHMENT_UNUSED) continue;
            // VUID-VkRenderPassCreateInfo-attachment-00834.
            if (reference.attachment >= attachments.len) return .error_validation_failed;
            const count = attachments[reference.attachment].samples;
            // VUID-VkSubpassDescription-pColorAttachments-09430,
            // -pDepthStencilAttachment-01418.
            if ((samples orelse count) != count) return .error_validation_failed;
            samples = count;
        }
        whole.samples = samples orelse 1;
        const resolves: []const facet.AttachmentReference = if (subpass.resolve_attachments) |given| given[0..subpass.color_attachment_count] else &.{};
        for (colors, 0..) |reference, k| {
            const color_index = reference.attachment;
            if (color_index == facet.ATTACHMENT_UNUSED) {
                // Nothing to resolve where nothing is drawn
                // (VUID-VkSubpassDescription-pResolveAttachments-00847).
                if (resolves.len != 0 and resolves[k].attachment != facet.ATTACHMENT_UNUSED) return .error_validation_failed;
                continue;
            }
            // Past the attachments, which the loop above has refused
            // already (-attachment-00834), or the depth attachment as well
            // (VUID-VkSubpassDescription-pDepthStencilAttachment-04438).
            if (color_index >= attachments.len) return .error_validation_failed;
            if (color_index == depth_index) return .error_validation_failed;
            // At two locations of the subpass: "A given attachment index
            // must not be used multiple times in a single subpass", other
            // than as an input attachment beside its other use (the render
            // pass chapter, under VkAttachmentDescription).
            for (colors[0..k]) |earlier| if (earlier.attachment == color_index) return .error_validation_failed;
            const color = attachments[color_index];
            // VUID-VkSubpassDescription-pColorAttachments-02648.
            if (!_surface.drawable(color.format)) return .error_validation_failed;
            const load: _render.ColorLoad = if (color.load_op == .clear and !drawn[color_index]) .clear else .keep;
            // Its resolve attachment: one sample, of its own format, for a
            // colour of more than one. Vulkan's resolve is at the
            // subpass's end, over the render area:
            // VUID-VkSubpassDescription-pResolveAttachments-00848, -00849
            // and -00850.
            const resolve: ?u32 = if (resolves.len == 0 or resolves[k].attachment == facet.ATTACHMENT_UNUSED) null else resolve: {
                const index = resolves[k].attachment;
                // VUID-VkRenderPassCreateInfo-attachment-00834.
                if (index >= attachments.len) return .error_validation_failed;
                const into = attachments[index];
                if (color.samples == 1 or into.samples != 1 or into.format != color.format) return .error_validation_failed;
                break :resolve index;
            };
            if (together) {
                // The one part draws them all: a plane of each tile for
                // each of them. What it reads of its own is the first of
                // them, that being the one plane a fragment function is
                // given. Another of them read as well is one this library
                // does not draw; only its own flag draws colours together,
                // and this goes with it (docs/facet-vulkan10.md item 80).
                if (reads_own[color_index]) {
                    if (k != 0) return .error_feature_not_present;
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
                part.output = @intCast(k);
                plan.parts[plan.part_count] = part;
                plan.part_count += 1;
            }
        }
        if (together or used == 0) {
            plan.parts[plan.part_count] = whole;
            plan.part_count += 1;
        }
        // Each part is the subpass played again from its begin, so each
        // tests against the depth and the stencil the subpass began with.
        // A part before the last that wrote what it left into the image's
        // rows would have the next one read that in instead, and fail a
        // LESS test wherever it had drawn: only the last keeps them, and
        // they all leave the same (since 1.116).
        for (plan.parts[plan.subpasses[number].first_part .. plan.part_count - 1]) |*part| {
            part.stores_depth = false;
            part.stores_stencil = false;
        }
        for (colors) |reference| if (reference.attachment != facet.ATTACHMENT_UNUSED) {
            drawn[reference.attachment] = true;
        };
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
    // A depth attachment drawn as a colour as well, in one subpass or
    // another: no format is both (VUID-VkSubpassDescription-pColorAttachments-02648,
    // -pDepthStencilAttachment-02650), and the checks above have refused
    // either the one or the other already.
    for (plan.parts[0..plan.part_count]) |part| if (part.depth) |depth| if (drawn[depth]) return .error_validation_failed;
    const made = _objects.create(base.sys_base, _render.RenderPass) orelse return .error_out_of_host_memory;
    made.* = plan;
    render_pass.* = _objects.handle(facet.RenderPass, made);
    return .success;
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
