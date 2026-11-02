// SPDX-License-Identifier: MIT
//! facet.library's version: what its driver modules are stamped with too,
//! here so that they need nothing of its ROM tag.

pub const LIBRARY_VERSION = 1;
/// 1: a window closed under its surface is found gone, never drawn into,
/// and the surface answers `error_surface_lost` (intuition 0.47's
/// window numbers); the depth pre-pass, a pipeline's own
/// (`PIPELINE_CREATE_DEPTH_PREPASS`).
/// 2: displays of 565 and colour attachments of R5G6B5: the tiles stay
/// 8 bits a channel, dithered 4 x 4 into 16 bits as they are stored;
/// command buffers recorded on the 32-bit chips too, whose chunks put
/// the commands 4 bytes off the 8 they are aligned to.
/// 3: a window's pixels read from intuition 0.49 (`WA_PixelFormat`).
/// 4: a triangle's edges sorted the way its rows are walked once, as it
/// is set up, not again in every tile it touches.
/// 5: a window on a composed screen shows a swapchain's picture as it is
/// (layers 0.7's `ShowLayerPicture`), not copied into the window first.
/// 6: what draws is a driver behind each physical device's table
/// (driver/), the cores the first; nothing a program sees changes.
/// 7: the BCM2712's V3D a second physical device, listed after the cores;
/// fragment functions of fixed forms (`shader.fixedFragment`), the only ones
/// it runs, and the cores run too.
/// 8: a device whose driver cannot carry on is lost: `error_device_lost`,
/// nothing more played, and no image shown that may not be finished.
/// 9: a window's picture that is late for the display's frame is shown at once,
/// not a whole frame later.
/// 10: a colour can be added to what is there, as much as its alpha says:
/// SRC_ALPHA and ONE.
/// 11: a limit on waiting for all of several fences is the whole wait's, not
/// each fence's.
/// 12: any blend factors and operation, the alpha's its own; blend constants,
/// and CmdSetBlendConstants; the colour write mask.
/// 13: on a screen, a swapchain and the one it was handed on from have no
/// image in common.
/// 14: points and lines, and triangles drawn as their edges or corners;
/// CmdSetLineWidth.
/// 15: the stencil test, on an attachment of s8_uint or d16_unorm_s8_uint;
/// CmdSetStencilCompareMask, CmdSetStencilWriteMask, CmdSetStencilReference.
/// 16: CmdCopyImage, CmdBlitImage, CmdCopyImageToBuffer, CmdClearAttachments.
/// 17: CmdDrawIndirect, CmdDrawIndexedIndirect, secondary command buffers and
/// CmdExecuteCommands.
/// 18: compute functions, on the cores: CreateComputePipelines, CmdDispatch,
/// CmdDispatchIndirect.
/// 19: tessellation, on the cores.
/// 20: textures of layers, cube maps and 3D textures, with their fixed forms
/// of fragment function; BC1, BC2, BC3 and float textures, unpacked as they
/// are copied in.
/// 21: several subpasses and CmdNextSubpass; several colour attachments, drawn
/// one after another.
/// 22: drivers but the cores' are modules in LIBS:facet/, looked for by the
/// first instance; the V3D's is v3d.fdriver, no longer in the library.
/// 23: a draw of more vertices than the library works is refused as it is
/// recorded, by `EndCommandBuffer`; whatever is left out of a frame while it
/// is played says so in the log, on the cores as well as on the V3D, naming
/// what it was instead of nothing or a line without a cause; memory above
/// the V3D's 32-bit reach is given back rather than truncated.
/// 24: GetPhysicalDeviceFeatures: what a device does, a field for each thing
/// a create call can refuse, so that a program asks rather than being told
/// `error_feature_not_present`. The cores and the V3D differ in five of them:
/// the two that say which device the cores are, the two the V3D's fixed forms
/// and TMU cost it, and the depth pre-pass, which is the rasterizer's alone.
/// 25: a fragment function of a form that drops pixels clears their bit in
/// `shader.Quad.kept`, and such a pipeline has its depth written after the
/// function instead of before it, so that a dropped pixel hides nothing
/// behind it. The first such form is `texture_cutout`, on the cores; the V3D
/// refuses it until it has a program for it. The branch this leaves in the
/// walk costs a draw that never drops a pixel about 1 %: 281.8 ms against
/// 278.9 for a million triangles on the CM5's cores, measured against the
/// same kernel with 24's walk in it.
/// 26: a render pass over part of an image no longer reads the image for the
/// tiles that part covers whole. They are cleared by the renderer like any
/// other and drawn over, so what was read for them was thrown away; only the
/// tiles at the part's edge, which must keep the pixels outside it, are read.
/// On the V3D a frame of 1920x1080 inside 2560x1440 falls from 5.812 ms to
/// 4.034, with the whole 2560x1440 unchanged at 4.017. A window is the
/// normal case on a desktop, and this is what one cost.
/// 27: CmdFillBuffer, CmdUpdateBuffer and CmdClearColorImage, which take a
/// staging buffer, a map and a submit out of a small write, and let an image
/// be cleared without a render pass over it. The bytes CmdUpdateBuffer
/// writes become the command buffer's own as it is recorded, so at most
/// 65536 of them; the clear writes whole levels, which is right whatever
/// order a level's texels are kept in - though not how wide one is, an 8888
/// texel being kept spread over 64 bits in a texture.
/// 28: samplers - CreateSampler and DestroySampler, the `sampler` and
/// `combined_image_sampler` descriptors, and two fixed forms that sample
/// through the one bound beside the texture rather than as the program was
/// compiled: `texture_sampled` and `texture_shadow`. A sampler is what the
/// fixed path has no room for: the two levels round a point mixed, a bias
/// on the level and a clamp, mirrored and bordered edges, up to 16 samples
/// along the longer axis, and a comparison with a reference in place of a
/// colour. It is read for every sample, by floats and a pixel at a time
/// (`texture.sampleBy`), where a fixed form's sampling is fixed point and a
/// quad at a time - which is why both are here and the fixed forms are
/// untouched. No QPU program reads a sampler, so such a pipeline is refused
/// on the V3D and drawn on the cores, as a dropping form is
/// (`PhysicalDeviceFeatures.samplers`). A layout's `immutable_samplers` and
/// a sampler's `unnormalized_coordinates` are refused rather than passed
/// over, so that no program is left thinking they took.
/// 29: query pools - CreateQueryPool, DestroyQueryPool,
/// GetQueryPoolResults, CmdBeginQuery, CmdEndQuery, CmdResetQueryPool,
/// CmdWriteTimestamp and CmdCopyQueryPoolResults. An occlusion query counts
/// the samples that passed the tests, added by the tiles as they are drawn;
/// a statistics query counts what each stage was given, added where the
/// work is done - the draw's own numbers as it is played, the triangles
/// clipping kept from the rasterizer's own count, the pixels the fragment
/// function was called for from the tiles; and a timestamp is the E-clock as
/// the command is played, so `timestamp_valid_bits` is 64 and
/// `timestamp_period_ns` 1000 where the library has timer.device, and all
/// three are 0 where it has not. A counter is 32 bits wide, because the
/// library runs on machines with no 64-bit atomic, and is held at its
/// highest rather than wrapping round. There is no geometry shader, so
/// neither geometry statistic is counted and a pool that asks for one is
/// refused. The V3D counts neither samples nor stages - its occlusion
/// counter is not read and what its QPUs were given is not counted - so
/// pools of both kinds are refused on it and only timestamps are kept.
/// 30: a depth attachment that outlives its render pass. With the store op
/// STORE each tile's depth is written into the image's memory as the tile
/// is drawn, and with the load op LOAD each tile starts from what is there,
/// so depth can be read back - CmdCopyImageToBuffer, CmdCopyImage - and a
/// shadow map made from it. A depth image is rows like a colour
/// attachment's, takes TRANSFER_SRC and TRANSFER_DST, and is cleared
/// without a pass by CmdClearDepthStencilImage. Both want `d16_unorm` and a
/// device whose `stored_depth` is true: the cores hold the depth in their
/// tiles and can write it out, the V3D has no such path yet and refuses
/// such a pass. The stencil still has no plane of its own, and a transient
/// depth image still costs no memory traffic at all - which is what every
/// pass that does not ask for this goes on doing.
/// 31: `storage_image` descriptors - an image a shader function writes
/// through. A set layout takes the kind, a write takes an image made with
/// IMAGE_USAGE_STORAGE, and the function reaches it by
/// `shader.Resources.written`, which gives the texture to write with
/// `putLayer` or `setColor` and read with `colorAt`; the slot says whether
/// a write is allowed (`shader.Slot.writable`, in the padding a slot
/// already had, so a slot is as wide as it was). A compute function and a
/// fragment function of the program's can both write one, and nothing
/// orders their writes against each other: a frame is shared between the
/// cores, as it is in Vulkan. It wants a device whose `storage_images` is
/// true - the cores, where the texels lie the way the library keeps them -
/// and not the V3D, whose TMU has a layout of its own. An image written
/// through may be sampled too, and is read back by a transfer.
pub const LIBRARY_REVISION = 31;
