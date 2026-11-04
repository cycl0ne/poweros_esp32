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
/// 32: buffer views - CreateBufferView and DestroyBufferView, and the
/// `uniform_texel_buffer` and `storage_texel_buffer` descriptors. A view is
/// a range of a buffer read as texels of a format, which a function reaches
/// by `shader.Resources.texels`: `shader.Texels.at` reads a texel as four
/// floats and `colorAt` as 0xAARRGGBB whatever the format, and a storage
/// one is set by `set` or `setColor`. It is the library's one way of giving
/// a function bytes read as a format rather than as a Zig type, which is
/// what a file or another machine hands over; the formats are the colour
/// ones and the floats, those whose `buffer_features` now say
/// UNIFORM_TEXEL_BUFFER. Every device has them: a view is bytes and a
/// format, with nothing of a device's own layout in it.
/// 33: a subpass's colour attachments blended each its own way:
/// `PipelineColorBlendStateCreateInfo.attachments` is one state for each of
/// them, taken on its own rather than all having to say the same thing. A
/// pipeline keeps one mixing for each attachment and the draw takes the one
/// for the attachment it is drawing, which is what an attachment being a
/// pass of its own already gave both drivers; the blend constants stay the
/// pipeline's, shared, as Vulkan has them. Every device has it
/// (`PhysicalDeviceFeatures.independent_blend`), and a device without it
/// goes on refusing attachments that differ.
/// 34: the depth bias: `depth_bias_enable` and its three numbers taken as
/// a pipeline is made, `DynamicState.depth_bias` and CmdSetDepthBias
/// leaving them to commands. A triangle's depth is moved before it is
/// tested and written - by so many of the smallest difference the depth
/// holds, and by so much of its steepest slope, held inside a clamp - so
/// the shadow map need not shade itself and the decal need not fight the
/// wall it lies on. The rasterizer works it out once a triangle, as an
/// offset on the depth plane its set-up already had, and nothing is spent
/// a pixel; only triangles are moved, as in Vulkan. It wants a device
/// whose `depth_bias` is true: the cores have it, and the V3D's own depth
/// offset is a packet nothing writes yet, so a pipeline that asks for a
/// bias is refused there.
/// 35: dynamic buffer descriptors: `uniform_buffer_dynamic` and
/// `storage_buffer_dynamic`, whose bytes start where
/// CmdBindDescriptorSets' `dynamic_offsets` says rather than where the
/// write did. One set then serves draw after draw - or dispatch after
/// dispatch - each with a range of its own, instead of a set for each.
/// The set says which of its offsets shifts a slot as it is made
/// (`shader.Slot.dynamic`, in the padding a slot already had), the bind
/// hands the offsets to what the draws read (`shader.Resources.offsets`),
/// and `buffer` and `storage` add it, holding what is left of the range
/// from there. A set holds
/// `PhysicalDeviceLimits.max_descriptor_set_dynamic_buffers` of them -
/// two, the offsets being copied with what a draw was bound with - and
/// CreateDescriptorSetLayout refuses more. Every device has them: a
/// dynamic descriptor is a pointer and a range, and what reads it is a
/// function of the program's.
/// 36: the three device queries Vulkan has and this library had not:
/// GetPhysicalDeviceImageFormatProperties, which answers the largest
/// image of a format, type, tiling and usage - and refuses a shape there
/// is no image of at all - by asking CreateImage's own rules
/// (`_image.shapeFor`), so the two cannot drift apart;
/// GetRenderAreaGranularity, which is the device's tile, the frame being
/// drawn tile by tile either way; and GetDeviceMemoryCommitment, which is
/// a block's whole size, or 0 for the lazily allocated type, whose
/// transient attachments live in the tiles and never in memory. Nothing
/// of what the library does changes: these only say what it already did.
/// 37: input attachments: a subpass reads what an earlier one drew,
/// pixel by pixel at the fragment's own place
/// (`SubpassDescription.input_attachments`, the `input_attachment`
/// descriptor, `shader.Resources.input`, `shader.Attachment`). An image
/// made with IMAGE_USAGE_INPUT_ATTACHMENT keeps its pixels in rows, as a
/// colour attachment does, and a view of it holds those rows for a set to
/// point at (`ImageView.rows`), so the one texel decoder reads them a row
/// at a time and nothing is copied or kept twice. CreateRenderPass holds
/// the pass to what can be read: a format whose pixels are in rows, one
/// sample, and not an attachment the same subpass draws into, which would
/// be a loop. All eleven of Vulkan's descriptor kinds are there now. The
/// cores read them; on the V3D no fragment program of its own runs, so
/// its `input_attachments` is false.
/// 38: a stencil that outlives its pass: `stencil_load_op` LOAD and
/// `stencil_store_op` STORE, a byte a pixel read into each tile before it
/// is drawn and written back after, as 1.30's depth is
/// (`PhysicalDeviceFeatures.stored_stencil`). `s8_uint` keeps it at each
/// pixel's only byte and `d16_unorm_s8_uint` after that pixel's depth,
/// which is what the planes' stride is for, so the four ops are taken on
/// their own: a pass may keep the stencil and leave the depth in the
/// tiles, or the other way round. Both formats are transferred now, so a
/// stencil is read back and written by CmdCopyImageToBuffer and
/// CmdCopyBufferToImage, and CmdClearDepthStencilImage clears either
/// plane by the range's aspects. The cores keep it; the V3D stores
/// neither.
/// 39: a depth image sampled where it lies
/// (`PhysicalDeviceFeatures.sampled_depth`): `d16_unorm` with
/// IMAGE_USAGE_SAMPLED, its rows both what a pass stores its depth into
/// and the texture a sampler reads (`texture.Format.d16`, a texture of
/// one level kept in rows rather than blocks, `texture.Texture.linear`).
/// So a shadow map is drawn into an image and sampled out of it with
/// nothing copied and nothing kept twice. A shadow sample compares the
/// depth at all 16 bits of it, where a colour texture's red channel gives
/// 8; a sample of the colour reads a depth as a grey of its top 8 bits,
/// and the fixed forms' fast path, which is built for blocks, paints
/// `shader.missing` unless the form was compiled for `.d16`. The cores
/// have it; the V3D's texture unit knows no depth format.
/// `texture.Texture` grew a field for it, so every program that samples
/// a texture has to be replaced along with the library, as a driver has:
/// the struct is laid out by the compiler, and an old binary reads a new
/// one through the old offsets without a word.
/// 40: the depth clamp and the depth bounds test, the last two of
/// `PipelineRasterizationStateCreateInfo` and
/// `PipelineDepthStencilStateCreateInfo` that were refused
/// (`PhysicalDeviceFeatures.depth_clamp`, `depth_bounds`), with
/// CmdSetDepthBounds and `DynamicState.depth_bounds` for the two numbers.
/// A draw that clamps is cut just in front of the eye rather than at the
/// near plane (`setup.ClipPlane.ahead`), keeps the triangle's own depth
/// plane - the vertices' depth is no longer bent to 0 to 1
/// (`setup.project`'s `free`) - and holds each pixel's own inside the
/// viewport's range as it reads it, so a shadow volume reaching behind the
/// eye is drawn whole. A draw that tests bounds drops a pixel whose
/// attachment already holds a depth outside them, before the stencil test
/// as in Vulkan, and wants only a pass with a depth attachment, not a
/// depth test of its own. Both go by the way a stencil test goes by, a
/// pixel at a time, so the fast quad paths are untouched and nothing a
/// draw without them costs changes. On the way: a draw with a stencil test
/// whose fragment form may drop a pixel no longer writes the depths it
/// never gathered.
/// 41: a compute group of many invocations, which share memory. A compute
/// entry declares its workgroup (`shader.computeGroup`): the invocations
/// along each axis and the bytes they share, in the word a vertex entry
/// keeps its varyings in, so no struct moved. The call gets them as
/// `shader.Groups.local` and `shader.Groups.shared`, with
/// `localIndex`, `globalInvocation`, `invocations` and `sharedAs` to read
/// them by. A group is still one call of the function, which makes the
/// invocations itself: a barrier is the point between two loops over them
/// inside that call, and there are no subgroups. The shared memory is a
/// block for each worker of the dispatch, found as it starts and given
/// back as it ends, cleared for the first group a worker takes; a group
/// has it to itself while it runs. The limits say what a group may hold -
/// 1024 by 1024 by 64, 1024 invocations in all, 16 KiB shared
/// (`PhysicalDeviceLimits.max_compute_work_group_size`,
/// `max_compute_work_group_invocations`,
/// `max_compute_shared_memory_size`) - and a pipeline of a group over them
/// is refused rather than cut to fit. A statistics query now counts the
/// invocations rather than the groups, which for a `shader.compute` entry
/// is the same number. Both devices have it: a compute function has always
/// run on the cores.
/// 42: a texture of any size. A sampled image's sides need not be powers
/// of two: its levels are Vulkan's - the one before halved, never below
/// one, as many as floor(log2(longer side)) + 1 - and a width that is not
/// a power of two is laid out in blocks by the next one up
/// (`texture.Level.blocks_shift`), so that a texel's place stays a shift
/// and nothing a draw does costs more. That is up to 2 x the memory for
/// the widest levels and nothing for a height, which is kept in as many
/// rows of blocks as it has. Past the width nothing is read: a sample is
/// held inside the level's own width, which the level carries.
/// `clamp` costs the same whatever the size. `wrap` tiles by masking bits
/// where both sides are powers of two (`texture.Level.tiles`) and by a
/// division where they are not, which is correct and some cycles a sample;
/// a sampler's `repeat` and `mirrored_repeat` were already a division.
/// A view of levels from `base` on is laid out as the image laid them out
/// (`texture.Texture.from`), not as a texture of that level's own size
/// would be - 9 across is kept by 16, and its second level by 8, not by 4.
/// The V3D needed nothing: its own tiling always worked from the size it
/// was given. `texture.Level` grew a field for all this, so every program
/// that samples a texture has to be replaced along with the library, as a
/// driver has.
/// 43: the smaller edges, four of them. A swapchain's images may be
/// copied out of and into as well as drawn into - TRANSFER_SRC and
/// TRANSFER_DST in `SwapchainCreateInfo.image_usage`, which
/// `supported_usage_flags` now says - so a picture of the frame is taken
/// with CmdCopyImageToBuffer and nothing has to be drawn twice; sampling
/// one is still refused, a display's buffer being rows and not blocks of
/// texels. A statistics query pool may ask for a geometry shader's two
/// statistics, which read 0, as Vulkan has a statistic of a stage that
/// never ran, rather than being refused. A shader function reaches every
/// element of a binding that is an array of buffers
/// (`shader.Resources.bufferAt`, `storageAt`), not its first alone, as it
/// always could for images and texel buffers. A set still holds two
/// dynamic buffer descriptors (`shader.MAX_DYNAMIC_OFFSETS`): four were
/// built and measured, and FacetMany drew a frame in 11.61 ms with them
/// against 11.18 to 11.58 over seven runs with two - above every reading
/// two gave, the offsets being copied with what a draw was bound with - so
/// the limit stays where it is, with the numbers now written down beside
/// it.
/// 44: compressed textures kept compressed. A sampled image of BC1, BC2 or
/// BC3 lies in its blocks as it was copied in on a device that samples them
/// (`PhysicalDeviceFeatures.kept_compressed`, the cores; the V3D is fed
/// unpacked texels and unpacks as before): an eighth to a quarter of the
/// memory the texels take - 16 x 16 of BC1 is 128 bytes against 1024 - and
/// a sample decodes the block it reads, the four texels it mixes coming out
/// of one block where they share it. The blocks are copied in and out as
/// they lie, by CmdCopyBufferToImage, CmdCopyImageToBuffer and CmdCopyImage
/// between two images of the one format, their offsets on a multiple of 4;
/// BC now says TRANSFER_SRC in GetPhysicalDeviceFormatProperties there.
/// `texture.Format` grew the four formats and `Sampling.format` takes them,
/// so a program samples a kept image through a form that says so
/// (`shader.fixedFragment`). A form built for another format than the
/// texture holds no longer paints `shader.missing`: it is drawn through the
/// run-time sampler, a pixel at a time, which reads whatever a texture
/// holds - correct, and slower than the form that matches. The one decoder
/// is the SDK's (`texture.blockOf`), which the unpacking copy uses as well,
/// so both paths read the same colours.
/// 45: float textures kept as their floats. A sampled image of
/// `r16g16b16a16_sfloat`, `r32g32b32a32_sfloat`, `b10g11r11_ufloat_pack32`
/// or `e5b9g9r9_ufloat_pack32` lies as it was copied in on a device that
/// samples it (`PhysicalDeviceFeatures.kept_floats`, the cores): the two
/// packed formats take 4 bytes a texel against the 8 an unpacked 8888 one
/// is kept spread in, and what went in comes out again - the floats are
/// copied in and out as they lie, by CmdCopyBufferToImage,
/// CmdCopyImageToBuffer and CmdCopyImage between two images of the one
/// format, so these formats now say TRANSFER_SRC there. A sample holds
/// each channel inside 0 to 1 and rounds it to 8 bits, the tiles having no
/// more, so what is drawn is what the unpacking copy drew: the one decoder
/// is the SDK's (`texture.floatTexel`), which that copy goes through as
/// well. `texture.Format` grew `rgba16f`, `rgba32f`, `rg11b10f` and
/// `rgb9e5`, and `Texture.putTexels`/`texelsAt` move a kept texel's bytes;
/// nothing writes one a texel at a time, so a blit into such an image, a
/// clear of it, and a storage image of a float format are refused or
/// unpacked as before. The V3D's TMU is fed unpacked texels, so there an
/// image is unpacked into 8888 as it always was.
/// 46: the other texture shapes. A 3D image may have levels of its own and
/// a depth that is not a power of two: a level is half as deep as the one
/// before it and never less than one slice (`texture.Texture.slicesAt`),
/// each slice carrying the whole of its own pyramid, so the layout is the
/// layered one and a level past the first leaves the slices past its depth
/// unread - about a sixth of the memory wasted at the deepest level, for no
/// new layout. A copy into a level of such an image addresses that level's
/// slices, and a sample picks the level from the quad's step as a 2D one
/// does. A view may be of cubes one after another, of type `cube_array`
/// over a multiple of six layers of an image made CUBE_COMPATIBLE, its
/// first layer beginning a cube: a form of `shader.FixedKind`
/// `texture_cube_array` reads it at four coordinates - the direction and
/// then which cube, the nearest there is, held inside the array
/// (`PhysicalDeviceFeatures.cube_arrays`, the cores;
/// `texture.Texture.sampleCubeIn`, `cubeNear`). No QPU program reads a
/// fourth coordinate, so the V3D refuses the view and the pipeline, and
/// such a draw goes to the cores. ETC2 and EAC are taken as well -
/// `etc2_r8g8b8_unorm_block`, `etc2_r8g8b8a1_unorm_block`,
/// `etc2_r8g8b8a8_unorm_block`, `eac_r11_unorm_block` and
/// `eac_r11g11_unorm_block`, Vulkan's `textureCompressionETC2` - unpacked
/// into 8888 as they are copied in on every device, every mode of the
/// format decoded from the specification: individual, differential, T, H,
/// planar, the punchthrough alpha, and EAC's alpha and 11-bit channels. No
/// sampler of this library reads such a block where it lies, so an ETC2
/// image is never kept in its blocks and never copied out of, which
/// GetPhysicalDeviceFormatProperties says.
/// 47: the V3D catching up on the depth and the counting. Its own depth
/// offset packet is written where a pipeline asks for a bias
/// (`PhysicalDeviceFeatures.depth_bias`): the units are the depth buffer's
/// smallest differences and the factor the triangle's slope, each the top
/// 16 bits of a float as the hardware takes them, with the clamp as its
/// limit - Vulkan's three numbers, unscaled. Its configuration has a depth
/// clamp (`depth_clamp`, which turns the clip to the z planes off with it)
/// and a depth bounds test of its own packet (`depth_bounds`). The tiles'
/// depth and stencil are stored to an image's rows and loaded back from
/// them as the render target is (`stored_depth`, `stored_stencil`): the
/// hardware writes one plane's pixels one after another, so the image's
/// format holds that plane alone - `d16_unorm` or `s8_uint` - and keeping
/// either plane of `d16_unorm_s8_uint` wants the new `stored_both`, which
/// the cores have and the V3D has not. A depth the V3D stored may be one
/// of the 65535ths away from the cores': it keeps a deeper number and
/// writes its top 16 bits. And the hardware's occlusion counter is read
/// (`occlusion_queries`): a draw points it at a word of a group of sixteen
/// on a boundary of 1024 bytes, as the hardware wants them, and what it
/// counted is added to the query as the frame is drawn. The CPU's caches
/// are dropped for the depth image and those words after the job, as they
/// always were for the colour. What the QPUs were given is still counted
/// by nothing, so a statistics pool is refused there.
/// What is left of that list wants a shader compiler for the QPUs, which
/// there is none of: an input attachment is read by a fragment function
/// (`shader.Resources.input`) and a storage image written by one, and the
/// V3D runs none of the program's functions, only the fixed forms. Neither
/// is a packet this driver could write.
/// What stays: `fifo` is the one present mode, there being no way to ask a
/// display to show a buffer before its next frame; one queue family of one
/// queue; a counter of 32 bits, for want of a 64-bit atomic on every
/// machine the library runs on; and no point mode in tessellation, there
/// being no point rasterization at all.
pub const LIBRARY_REVISION = 47;
