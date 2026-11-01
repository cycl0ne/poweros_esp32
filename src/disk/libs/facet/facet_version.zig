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
pub const LIBRARY_REVISION = 27;
