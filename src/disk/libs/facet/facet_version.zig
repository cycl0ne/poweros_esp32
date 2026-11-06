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
/// 48: a texel kept smaller than the colour it reads as
/// (`PhysicalDeviceFeatures.small_texels`, on every device). An image of
/// `r8_unorm` keeps one byte of red a texel and reads as (red, 0, 0, 1),
/// the way Vulkan reads a one-channel format - an eighth of what the same
/// texels kept as 8888 take, which is what a mask, a height field or a
/// lightmap costs now (`texture.Format.r8`). And
/// IMAGE_CREATE_PACKED_TEXELS on a sampled image of 8888 keeps each texel
/// in the 32 bits of its word rather than spread over 64
/// (`texture.Format.argb8888`): half the memory and half the cache it
/// fills, for the spread a sample then does itself, which is the trade the
/// other way round from the one the spread texel was made for. A fixed
/// form compiled for either format reads it at full speed; one compiled
/// for `rgba8888` draws it through the run-time sampler, as it does any
/// other format it was not built for, so a program asks the device what it
/// keeps and compiles for that. Both are written through as storage images
/// as well - the word takes the whole colour, the byte its red - and both
/// are copied in and out as they lie. On the V3D a texel was never spread,
/// so the flag costs nothing and changes nothing there, and R8 is a
/// texture type of the TMU's own, read with the swizzles of the channels
/// it has not: its microtile is 8 x 8 rather than 4 x 4, one byte a texel
/// being 64 bytes all the same (`driver/v3d/tiling.zig`).
/// 49: the shapes past 2D read through a sampler, and a sampler a set
/// layout holds. Three fixed forms join the two that read the sampler
/// bound beside the texture: `shader.FixedKind.texture_array_sampled`,
/// `texture_cube_sampled` and `texture_3d_sampled`, each at the three
/// coordinates its own form has (`shader.layeredBy`) - so an array, a
/// cube or a 3D texture has the two levels round a point mixed, a bias and
/// a clamp on them, mirrored and bordered edges and anisotropy, which the
/// forms compiled for a sampling have not. A cube's sample is taken inside
/// the face the direction falls on, its u and v and their steps the
/// face's, so a bilinear sample on a seam mixes that face's edge rather
/// than reading over into the next, which `texture_cube` does. The V3D
/// refuses them as it refuses the other two, no QPU program reading a
/// sampler.
/// `mirror_clamp_to_edge` is the fifth of Vulkan's address modes and the
/// last of them this library had not got: a coordinate below 0 reads the
/// texture turned round once, and one past the far side the far edge's
/// texels. The three border colours are all of Vulkan's six - an int
/// border and a float border are the same here, a texel being read as 0
/// to 1 whatever its format.
/// And `DescriptorSetLayoutBinding.immutable_samplers` is taken on every
/// device (`PhysicalDeviceFeatures.immutable_samplers`): the layout holds
/// one sampler for each descriptor of a `sampler` or
/// `combined_image_sampler` binding, every set made of it starts with them
/// in its slots (`shader.Slot.fixed_sampler`), a write of a combined image
/// sampler brings the texture and leaves the sampler, and a write of a
/// sampler alone changes nothing. A set keeps the addresses, so the layout
/// may go while the sets live on.
/// 50: tessellation spends the fraction of a level, and a patch carries
/// what its control function worked out. `shader.Spacing` is Vulkan's
/// three spacing modes, said by the evaluation entry: `equal`, which is
/// what there was before, rounds the level up and cuts the edge into
/// pieces all of one length; `fractional_even` and `fractional_odd` round
/// it up to an even or an odd number of pieces and give the fraction to
/// two short ones, so a level that follows the camera moves the vertices
/// rather than jumping them. The two short pieces go one at each end of
/// the edge, where Vulkan leaves their place undefined: two patches
/// sharing an edge walk it opposite ways round, and only a pattern that
/// is its own mirror leaves no crack between them. An inner ring takes
/// the same pattern, windowed in by one piece a ring, which under equal
/// spacing is the even cut it always was.
/// `shader.control` now says how many floats the patch carries from the
/// control function to the evaluation function
/// (`shader.Patch.ownValues`): the control function writes them, the
/// evaluation function reads them back, and nothing between the two calls
/// touches them - a normal of the whole patch, a displacement, a colour
/// worked out once rather than at every vertex. They live in the draw's
/// own memory, one run of them for each patch, and
/// `PhysicalDeviceLimits.max_tessellation_patch_components` says how many
/// a patch may have.
/// Fixed on the way: what is drawn with tessellation carries the
/// evaluation function's varyings, where the pipeline took the vertex
/// function's. An evaluation function that handed on more than the vertex
/// function did wrote past the room there was for it, and the fragment
/// function read what was never written - a colour of nothing, where the
/// patch's own floats are what the evaluation function makes it from.
/// 51: a subpass's colour attachments drawn together, one fragment call
/// writing all of them. SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER in a
/// `SubpassDescription.flags` - facet.library's own, Vulkan having no bit
/// for it - says so, and every pipeline of that subpass has a fragment
/// entry from `shader.fragmentOutputs` declaring exactly its colour
/// attachments. The function then finds `Fragments.output_count` above 1
/// and each attachment's colours after the one before
/// (`Fragments.colorsOf`), and writes them all in the one call. Before
/// this the subpass was drawn once for each attachment, its commands
/// played over again with `Resources.output` saying which: the vertices
/// worked again, the triangles binned again and every quad's fragment
/// function called again. A G-buffer of three or four planes now costs
/// one pass over all of it.
/// The tiles hold a colour plane for each attachment, and the room for a
/// batch's colours for all of them, out of memory of the part's own:
/// a frame of the one colour keeps the 24 KiB buffer and the stack it had,
/// and pays nothing for this. Each attachment is still blended its own
/// way, by its own mixing, into its own plane. Only the cores do it
/// (`PhysicalDeviceFeatures.several_outputs`); on the V3D the flag is
/// `error_feature_not_present`, its fragment programs being the fixed
/// forms and each writing the one colour.
/// Blend constants may be one set for each attachment as well - facet's
/// own again, where Vulkan has the one set a pipeline shares - by
/// `PipelineColorBlendStateCreateInfo.attachment_constants` or by the new
/// CmdSetBlendConstantsAt (LVO -520). A subpass drawn together has no
/// replay left to set them between, so without this its attachments could
/// not be blended by constants of their own at all.
/// 52: two subpasses share a depth attachment with another in between.
/// Before this they shared one only when the second went on in the tiles
/// of the first - right after it and into the same colour attachments -
/// and anything else was `error_feature_not_present`. Now the pass keeps
/// it for them: the part that drew it last writes its depth, and its
/// stencil, into the image's rows, and the next part to name that
/// attachment reads them in as it starts. Neither the attachment's load
/// op nor its store op says so; they are for the whole pass, and what
/// goes on inside it is the pass's own doing. So a pass over a scene can
/// draw something else into another picture and then come back and test
/// against the depth it left.
/// It is the machinery a depth that outlives its pass has had since 1.30
/// put to another use, so it wants the same of the device
/// (`stored_depth`, `stored_stencil`, `stored_both` for a format of both)
/// and the same of the image: memory something is behind, a transient one
/// having none, which CreateFramebuffer says. Where the tiles can be
/// shared they still are, and that pass pays nothing.
/// 53: an array of cubes read through the sampler bound beside it
/// (`shader.FixedKind.texture_cube_array_sampled`), at the four
/// coordinates `texture_cube_array` takes: the direction, and which cube,
/// the nearest there is. It was the one shape with no sampler form left
/// after 1.49, which gave the other three theirs, because it takes a
/// fourth coordinate where `shader.layeredBy` carried three; now that
/// function reads a fifth plane for the forms that want it.
/// The sample is taken inside the face of that cube the direction falls
/// on, its own u and v and their steps the face's, as a single cube's
/// sampled form has it - so the sampler's edges are that face's and a
/// bilinear sample on a seam mixes the edge's texels, where
/// `texture_cube_array` reads over the seam into the next face of the same
/// cube. The cube is picked a pixel at a time, so a quad may read four
/// cubes, and the level is the quad's.
/// Only the cores (`PhysicalDeviceFeatures.samplers` and `cube_arrays`):
/// the V3D has no QPU program that reads a sampler, nor one that reads a
/// fourth coordinate, so it refuses such a pipeline twice over.
/// 54: the formats a texel buffer reads, a regular grid of them. Before
/// this there were seven - 8888 either way round, 565 and one float to
/// four - so a buffer of whole numbers, or of 16 bits a channel, had no
/// view that read it and the program had to read the bytes itself through
/// a storage buffer, which wants it and the data to agree on a struct.
/// Now one channel, two or four of 8, 16 or 32 bits: `_unorm` read as 0
/// to 1, `_uint` and `_sint` as the whole number itself, and
/// `r16_sfloat`, `r16g16_sfloat` and `r16g16b16a16_sfloat` as
/// half-floats. Twenty-five formats more, every one of them a texel
/// buffer and nothing else - no image is kept in them and no vertex
/// attribute is read in one - but for `r8_unorm` and
/// `r16g16b16a16_sfloat`, which were already image formats and keep what
/// they had.
/// `shader.Texels` reads the lot as before, by `at` into four floats or
/// by `colorAt` into 0xAARRGGBB. For the integer formats it also reads
/// `intAt` into four whole numbers and writes `setInt` from them, because
/// a float carries 24 bits exactly and a 32-bit whole number is more than
/// that: a value past 2^24 copied through `at` comes out changed, and
/// through `intAt` it does not. A number past what a channel holds is cut
/// to the largest or the smallest it does, not wrapped.
/// Every device, the formats being read by the library and not by any
/// hardware: `TexelFormat.channelBits` and `kind` say how, and a view
/// reads the buffer where it lies as it always did.
/// 55: a storage image's level and layer named from inside the function.
/// `shader.Resources.written` gave back the view's texture before this
/// too, and `texture.Texture.setColor` and `colorAt` took a level and a
/// layer, but nothing held them to what was there: a function naming a
/// level the view has not got read `layout[lod]` where nothing had been
/// laid out and wrote wherever that pointed. So the level and the layer a
/// function could rely on were the view's first, and an image of layers
/// written through was refused unless it was sampled as well.
/// Now both calls hold to what the texture has (`texture.Texture.holds`):
/// a level, a layer or a place it has not got writes nothing and reads
/// transparent black, as a texel buffer past its last texel reads as 0
/// and an input attachment outside its rows as transparent black. So a
/// function may name any of the view's levels and any of its layers, and
/// `levels`, `layer_count`, `width` and `height` say what those are.
/// `putLayer` and `peekLayer` stay the raw pair in the texture's own
/// format, holding to nothing: they are what the library's own copies and
/// the samplers use, and holding there would cost a frame something. The
/// samplers hold every place to the level before they read it anyway.
/// A storage image may have layers without being sampled as well, which
/// `CreateImage` refused before: an image written through and never read
/// by a sample is as good a reason for layers as sampling is.
/// 56: a colour attachment written through as a storage image. Before
/// this an image was one or the other - CreateImage refused SAMPLED or
/// STORAGE together with COLOR_ATTACHMENT, a texture and an attachment
/// lying differently - so a function could not write the picture a pass
/// draws into, and a program seeding one had to draw it or copy it in.
/// Now COLOR_ATTACHMENT, or INPUT_ATTACHMENT, with STORAGE and without
/// SAMPLED: the image stays in rows, as an attachment is, and those rows
/// are the texture a function writes (`texture.Texture.linear`, which is
/// how a sampled depth has been read since 1.39). One level and one
/// layer, and of `b8g8r8a8_unorm` or `r5g6b5_unorm_pack16`:
/// `r8g8b8a8_unorm` is refused, a texture of 8888 being 0xAARRGGBB as
/// B8G8R8A8's rows are, and nothing reading a word with red in its low
/// byte. FORMAT_FEATURE_STORAGE_IMAGE in a format's linear features says
/// which, linear tiling being rows either way.
/// What it does not do is order the two against each other. A write
/// through the storage image reaches the rows at once; what a subpass
/// draws reaches them when it stores, at the end of its part. So a
/// function may seed the rows before a pass draws into them, or write
/// over them after it has ended, and writing them while that pass is open
/// leaves the store to win - which is what Vulkan says of the same thing
/// without a barrier. Nothing is refused for it, there being no barrier
/// here to ask for.
/// Only the cores, as every storage image is
/// (`PhysicalDeviceFeatures.storage_images`).
/// 57: the formats a storage image is written through in. Before this a
/// float image asked for as one was unpacked into 8888, whatever the
/// device kept for a sampled one, because `putLayer`'s one word of a
/// texel had nothing to say about four floats; and there was no `r32` of
/// any kind.
/// Now a float image keeps its floats where the device keeps them
/// (`kept_floats`) whether a function writes it or not, and
/// `texture.Texture.setParts` writes one texel of them while `partsAt`
/// reads it - four floats either way, a colour format's channels as 0 to
/// 1 and a float format's as they lie. `setColor` on a float texture
/// writes the colour's channels as 0 to 1 rather than nothing, which is
/// all a colour ever said. A whole number above 1, which no colour could
/// carry, now survives a write and a read: that is what keeping floats is
/// for.
/// `r32_sfloat` is an image format as well, `texture.Format.r32f`: one
/// float a texel, sampled as (red, 0, 0, 1) the way one byte of red is,
/// written through as the float it is. A height field, a mask or an
/// accumulation buffer is kept in it, in a quarter of what 8888 spread
/// over 64 bits takes and with the whole of a float's range.
/// The encoders are the decoders of 1.45 run backwards - `halfOf` beside
/// `ofHalf`, `partsOf` beside `ofParts`, and a shared exponent worked out
/// from the largest of the three - so what goes in comes out again as far
/// as the format holds it.
/// A compressed image asked for as a storage image is still unpacked into
/// 8888: nothing writes one texel of a BC block, and that is the format,
/// not the library.
/// 58: a sampled depth image's shape. Before this it was of `d16_unorm`
/// alone, of one layer, and a format with a stencil in it was refused as
/// sampled outright: there was nowhere to say which plane a view read,
/// and a depth image's memory was one layer's rows however many layers
/// were asked for - so a second layer shared the first one's pixels.
/// Now any of the three depth formats is sampled, and such an image has
/// layers: `layer_bytes` of rows each, on a cache line, which
/// `GetImageMemoryRequirements` asks for and a pass writes the one its
/// framebuffer's view begins at. A view takes the plane its aspect names
/// - IMAGE_ASPECT_DEPTH read at all 16 bits by a sampler that compares
/// and as a grey of its top 8 by one that does not, IMAGE_ASPECT_STENCIL
/// read as (red, 0, 0, 1) the way one byte of red is - so the rows of a
/// format holding both are two textures over the same bytes, four apart.
/// `texture.Texture.linearBy` is what carries that: a `stride` from one
/// texel to the next other than the format's own size, 0 meaning its own.
/// Both planes at once is refused, there being no texel of the two
/// together; an aspect naming neither plane, IMAGE_ASPECT_COLOR being the
/// default, is the format's own plane, which is what every view of such
/// an image asked for before this.
/// `texture.Texture.setParts` and `partsAt` read and write a `d16` texel
/// as well, as the whole 16 bits in 0 to 1: a function given a depth
/// plane reads a depth as a number rather than as a grey.
/// CmdClearDepthStencilImage clears the layers its range names rather
/// than the first alone.
/// What stays a gap: levels of its own, so no mipmapped shadow map, and
/// no depth image of type `3d`. A pass draws into rows, and a level or a
/// slice is nothing it draws into.
/// Only the cores: the V3D's texture unit knows no depth format
/// (`PhysicalDeviceFeatures.sampled_depth`).
/// 59: a 3D texture of levels read through a sampler. Before this the
/// coordinate through the texture was taken over the whole depth whatever
/// level the sample read, while a level has half the slices of the one
/// before it (`texture.Texture.slicesAt`): a level past the first read the
/// wrong slice, and past the slices that level has it read memory no copy
/// had written. The fixed form `texture_3d` was right all along; it is the
/// sampler's path, `texture_3d_sampled` since 1.49, that was not.
/// Now the level comes first and the slice after it: `r` is taken over the
/// slices that level has, and where `mipmap` is `linear` each of the two
/// levels is read over its own and the two mixed. Which of the sampler's
/// filters decides whether the slices either side of the point are mixed
/// is the one the level asked for, as it already was across a slice -
/// before, it was mixed only where both filters were `bilinear`.
/// `sampleBy` and `sampleVolumeBy` now share what they settle first:
/// `chosenLevel` gives the level, the samples along the longer axis and
/// the filter, and `levelsOf` the levels to read and how much of the
/// second.
/// 60: a cube read through a sampler reads over its seams. Before this
/// the sample was taken inside the face the direction fell on, as a plain
/// 2D sample of that layer: a bilinear tap past the face's edge was held
/// there by the sampler's own `wrap`, so a seam mixed the edge's texels
/// twice and the sampler's edges stood in for a cube's, which has none.
/// The fixed form `texture_cube` has read over them since 1.46.
/// Now `texture.Texture.sampleCubeBy` is what `texture_cube_sampled` and
/// `texture_cube_array_sampled` call, and a tap past a face's edge comes
/// from the face beside it, at the texel the direction falls on
/// (`cubePlace`, the place `cubeTexel` has read since 1.46). A comparison
/// counts what passed either side of a seam the same way, so a shadow map
/// of all six ways is sampled as one picture. The sampler's `wrap` says
/// nothing of a cube; its levels, bias, clamp, mipmap mode, anisotropy
/// and comparison say what they say everywhere.
/// A quad whose four pixels fall on different faces takes the first
/// level, as the fixed forms do: the steps across a seam are two faces'
/// and measure nothing.
/// `sampledAt` and `tapped` now read through a `Reads` - one layer as it
/// lies, or a cube's face - so the filtering, the comparison, the
/// anisotropy and the levels are the one path for both.
/// 61: `CmdClearColorImage` writes a float image, with the channels it
/// was given. Before this the clear found no texel it could make of the
/// colour for a format that keeps what it was told - R16G16B16A16_SFLOAT,
/// R32G32B32A32_SFLOAT, B10G11R11_UFLOAT_PACK32, E5B9G9R9_UFLOAT_PACK32,
/// R32_SFLOAT - and wrote nothing at all, saying so in the log, although
/// every one of them claims FORMAT_FEATURE_TRANSFER_DST and a copy into
/// one has moved floats since 1.57.
/// Now the four floats of `ClearColorValue.float32` are put into the
/// format's own texel by `texture.putFloatTexel`, the encoder a copy into
/// such an image uses, and that texel is written over every texel of the
/// levels and layers named. The channels go in as they stand, not rounded
/// to a byte each: a red of 2 and a blue of 0.5 are what the image holds
/// afterwards, as far as the format reaches, and what a format cannot
/// hold - a green below 0 where it has no sign - it holds at its own
/// limit, the same way a copy of that texel would. A clear of 16 bytes a
/// texel fills by 16 (`Texel.sixteen`).
/// A compressed image is still the one this cannot write: its texels go
/// in as whole blocks, nothing here compresses, and that is the format
/// and not the library. A depth image is `CmdClearDepthStencilImage`'s,
/// as it was.
/// 62: a depth attachment is read as an input attachment. Before this
/// `CreateRenderPass` answered `error_format_not_supported` for an input
/// reference of a depth format, the reason being that a depth lives in
/// the tiles and has no rows to read - which has not been so since 1.39,
/// when a sampled depth gained memory of its own, nor since 1.58, when
/// each of the three formats gained planes and layers.
/// Now an image made IMAGE_USAGE_INPUT_ATTACHMENT of a depth format is
/// the same rows a sampler reads (`PhysicalDeviceFeatures.sampled_depth`,
/// and no transient one), a view of it carries the plane its aspect
/// names as `shader.Attachment` (`_image.depthRows`), and
/// `UpdateDescriptorSets` writes that into an `input_attachment`
/// descriptor. The depth reads as `r16`, 0 to 1 and nearest first, and
/// the stencil as `r8u`, the whole number it holds.
/// A format that holds both is two planes inside the same rows, four
/// bytes from one pixel to the next: `shader.Attachment` and
/// `shader.Texels` gained a `stride` for that, 0 being the format's own
/// size, which is every other attachment. The part of the pass that drew
/// the depth last writes it into the image's rows for the later subpass
/// to read, the way 1.52 does for a depth two subpasses share, so such a
/// pass wants `stored_depth`, a stencil `stored_stencil`, and a format
/// of both `stored_both`.
/// 63: a depth attachment has levels of its own. Before this
/// `CreateImage` refused `mip_levels` past one for a depth format, the
/// reason being that what a pass draws into is rows and a level is not;
/// but a level is rows as well, and 1.58 had already given such an image
/// layers of them.
/// Now a depth image takes as many levels as halving its longer side
/// gives. A layer holds the whole pyramid: a level's rows after the level
/// before it, each level's pitch as wide as that level is and each level
/// on a cache line (`_image.depthPitch`, `depthLevelAt`, `rowsAt`), and
/// the pyramid again for each layer. A pass draws into the level its
/// framebuffer's view names, that level's size being what the framebuffer
/// has to fit; a sample reads the levels the view names, each in its own
/// rows; `CmdClearDepthStencilImage` clears the levels its range names;
/// and the transfers read and write the level they are given.
/// `GetImageSubresourceLayout` answers for such an image now, where it
/// answered 0: the level's offset in its layer, its own pitch, what it
/// takes and what a layer takes.
/// A texture kept in rows carries a level's own pitch and start for that
/// (`texture.Level.pitch`, `texture.Texture.linearLevel`), so a sample of
/// one reads the level it chose out of that level's rows rather than the
/// first level's. So a shadow map and its smaller copies are the levels
/// of one image, drawn into one by one and sampled as one texture.
/// 64: a subpass reads the colour attachment it is drawing into. Before
/// this `CreateRenderPass` answered `error_initialization_failed` for an
/// input reference naming an attachment the subpass draws - a loop, the
/// pixels being read the ones being written - so programmable blending
/// meant a pass of its own and a copy.
/// Now it is Vulkan's self-dependency by region: the subpass names its
/// own colour attachment as an input attachment and the pass carries a
/// `SubpassDependency` of that subpass on itself with
/// DEPENDENCY_BY_REGION (which the dependencies are read for, and for
/// nothing else). The fragment function is then given the fragment's own
/// pixel as the tile already holds it, so the read costs nothing but the
/// load: the pixel is where the tiles are, which is cheaper here than the
/// copy it replaces. It was handed over beside the quads at first
/// (`shader.Fragments.keptAt`); 1.65 made it the descriptor's own read,
/// which is what it should have been from the start.
/// A subpass that reads what it draws is a part of its own, never joined
/// to the part before it, since what it reads is the tile as that part
/// starts. One of several colour attachments drawn together reads the
/// first of them and no other; the depth attachment it draws into it
/// does not read, and neither does it read another pixel.
/// 65: a subpass reads what it draws through the descriptor of it, as
/// every other input attachment is read. 1.64 handed the tile to the
/// fragment function beside its quads (`shader.Fragments.keptAt`),
/// because the tiles are drawn on every core at once and one descriptor
/// cannot say where each core's tile is: so a program declared the
/// attachment the Vulkan way and then read it another way, which is two
/// ways of saying one thing.
/// Now `shader.Fragments.input(set, binding, element)` is what a fragment
/// function reads an input attachment with. It answers the descriptor as
/// written for an attachment an earlier subpass drew - the image's rows,
/// as before - and, where the descriptor names the attachment this very
/// part is drawing into, the tile instead. What it compares is the
/// attachment's own first pixel, which every view of that image points
/// at, so any view of it is known for what it is.
/// A `shader.Attachment` carries the pixel its first column and its first
/// row stand for (`left` and `top`, the tile's corner for the tile), so
/// `colorAt(x, y)` and `at(x, y)` read a pixel at its own place on the
/// attachment whichever of the two it is, and what the tile does not
/// cover reads as transparent black - the fragment's own pixel being all
/// a dependency by region promises.
/// `keptAt` and the `target_pitch` beside it are gone; `Resources.input`
/// is unchanged and still answers the descriptor as written, which for
/// the attachment being drawn is memory the pass has not written yet.
/// `Fragments` points at that tile's attachment rather than holding one,
/// and the rasterizer keeps it with the batch: a batch begins once for
/// each triangle in each tile, so the two words it begins with are the
/// two 1.64 had - 99856 triangles over 60 frames of 1920x1080 measured
/// 11.2 to 11.6 ms with the pointer against 11.7 to 11.9 ms with the
/// attachment itself.
/// 66: `GetPhysicalDeviceImageFormatProperties` answers the largest
/// image, not the largest heap. `max_resource_size` was the bytes of the
/// biggest memory heap - a fact about the memory and nothing about the
/// image asked about - where Vulkan has it as what an image of that shape
/// may take, every level of every layer of it. Now the call writes the
/// create info of the largest image of the shape and lays it out with the
/// very code `CreateImage` lays an image out with (`_image.shapeFor`),
/// and answers the bytes of that - what `GetImageMemoryRequirements` then
/// answers for such an image, to the byte.
/// Its levels and its layers are asked of those same rules rather than
/// worked out from the kind of image, which is what had left them behind:
/// a depth attachment answered one level where 1.63 gives it as many as a
/// colour one has, a sampled depth attachment answered one layer where
/// 1.58 gives it 256, and a 3D image answered one level where each of its
/// slices has its own. Every answer is a maximum, so each of them only
/// grew; an extent, a level count or a layer count inside what is
/// answered is made, and one outside it refused, as before.
/// 67: a sampler places its sample in texels where it is asked to, rather
/// than 0 to 1 across the texture: Vulkan's `unnormalizedCoordinates`, for
/// a program that reads a texture as a table of values and knows which
/// texel it wants. `CreateSampler` refused the bit outright since 1.28, so
/// such a program scaled by the texture's size itself and sampled 0 to 1 -
/// which is the size in two places, and loses the texel at the far edge to
/// the rounding.
/// `texture.Sampler` carries it (`unnormalized`), and the one place a
/// sample turns a coordinate into texels reads it (`sampledAt`): a texture
/// of any shape read through such a sampler takes the point as texels of
/// the level, and a 3D one's `r` as slices, which keeps every axis in the
/// same units. The fixed forms and a fragment function of the program's
/// are untouched: what changes is the sampler the texture is bound beside.
/// Vulkan asks five things of such a sampler and all five are held to,
/// each an `error_initialization_failed`: one filter for both (which is
/// why the filter a sample would choose from how fast the coordinates
/// change need not be worked out at all), `nearest` mipmapping with
/// `min_lod` and `max_lod` 0, no anisotropy, no comparison, and an edge
/// held or bordered across and down. `address_mode_w` is taken as it is
/// given, Vulkan having no 3D texture read this way.
/// The cores say yes to it (`PhysicalDeviceFeatures.unnormalized_coordinates`);
/// the V3D reads no sampler at all, so it says no, as it does to the rest
/// of what a sampler says.
/// 68: the rest of the formats a texel buffer reads. 1.54 laid out a
/// regular grid - one channel, two or four, of 8, 16 or 32 bits, as 0 to
/// 1, as a whole number or as a float - and left four kinds outside it,
/// which a program reading a file or another machine's bytes is as likely
/// to meet as any: `_snorm`, `_srgb`, the words whose channels are packed
/// into them, and three channels of 32 bits.
/// `_snorm` is the signed number over the largest the channel holds, -1
/// to 1, with the value below that reading as -1 as well, as Vulkan has
/// it. `_srgb` reads its three colour channels through sRGB's transfer
/// function and its alpha straight - a table of the 256 values worked out
/// as the program is compiled - so a picture written down the way a file
/// keeps it is read as light; `intAt` and `setInt` are still the bytes as
/// they lie. `a2b10g10r10` and `a2r10g10b10`, unorm and uint, are a shift
/// and a mask, and `shader.TexelFormat.packing` is where every packed
/// format's channels lie - `rgb565` became one of those rather than a
/// case of its own. `a8b8g8r8_unorm_pack32` and `a8b8g8r8_srgb_pack32`
/// are the same bytes as `r8g8b8a8_unorm` and `r8g8b8a8_srgb` on a
/// little-endian machine, so they are those texels read under another
/// name. `b10g11r11_ufloat_pack32` and `e5b9g9r9_ufloat_pack32` are read
/// and written by the very code a texture of the format uses
/// (`texture.floatParts`, `putFloatTexel`), so a buffer and an image of
/// one of them agree to the bit.
/// `TexelKind` has `snorm` and `srgb` beside its kinds, and
/// `channelMost` answers 127 and 32767 for a signed channel, the sign
/// having its bit.
/// What is still out: the three-channel formats of 8 and of 16 bits, 3 or
/// 6 bytes a texel being what almost no hardware carries either, and the
/// `_uscaled` and `_sscaled` kinds, which nothing here has a use for.
/// 69: a texture keeps channels of its own where the device says so
/// (`PhysicalDeviceFeatures.wide_channels`): `r8g8_unorm`, two bytes a
/// texel, and `r16_unorm`, `r16g16_unorm` and `r16g16b16a16_unorm`, 16
/// bits a channel. A texel buffer has read all four since 1.54, but an
/// image of one of them was refused: a texture held an 8888 colour and
/// nothing else, so a height field, a shadow map of a program's own or a
/// table of values at more than 8 bits a channel had to be a float
/// texture, four or eight bytes where two would do, or be scaled into
/// 8888 and lose what it was for.
/// They go the way a float texture's texels have gone since 1.45: kept as
/// they lie. A copy in writes the bytes as they are given and a copy out
/// reads them back unchanged, to the bit, and a copy between two images of
/// the one format moves them whole (`_image.keptTexels`, which is what the
/// transfers now ask rather than whether the texels are floats). A sample
/// reads the colour of each channel's top 8 bits, which is all a tile's
/// colour holds (`texture.channelColor`), while
/// `texture.Texture.partsAt` and `setParts` give and take the whole of
/// every channel - so a function writing through such a storage image
/// writes 16 bits of it, and reads its own 16 bits back.
/// `texture.Format` has `rg8`, `r16`, `rg16` and `rgba16`, and
/// `channelParts`, `putChannelParts` and `channelColor` are where a
/// channel's bits are turned into 0 to 1 and back; a fixed fragment form
/// built for one of them samples it directly
/// (`shader.Sampling.format`), and one built for 8888 draws it through
/// the run-time sampler as before. A clear writes each channel at the
/// width that channel has.
/// Like a small texel, such an image is for a function to read or to
/// write: one that is only copied into and out of is refused, as is a
/// colour attachment of the format, and the V3D refuses them all, its
/// texture unit being fed what the library unpacked -
/// `GetPhysicalDeviceFormatProperties` says the format is sampled by
/// nothing there, while the texel buffer stands on either device.
/// 70: a texture keeps whole numbers where the device says so
/// (`PhysicalDeviceFeatures.whole_textures`): Vulkan's `_uint` and
/// `_sint` formats, one channel, two or four, of 8, 16 or 32 bits. That
/// clears the other half of 1.69's work - a texel buffer has read all
/// eighteen since 1.54, while an image of one was refused, because a
/// texture answered a colour or four floats and a whole number is
/// neither: 300 is no colour, and 2^24 + 1 is no float.
/// So the read is the new part. `texture.Texture.wholesAt` gives the four
/// numbers a texel keeps, as `shader.Texels.intAt` gives a texel
/// buffer's, and `setWholes` writes them, each held to what its channel
/// holds - 300 into a byte is 255, -5 into an unsigned channel is 0, and
/// 70000 into 16 bits signed is 32767. Both answer every format, not only
/// the new ones: a texture of 8888 gives its colour's four channels as 0
/// to 255, and one whose channels are its own gives the numbers those
/// channels hold. `partsAt` and `setParts` give and take the same numbers
/// as floats, which carry 24 bits of one exactly, and a sample holds each
/// to 0 to 1 and over 255, the way a texel buffer of the format reads one
/// (`texture.wholeColor`): a number above 0 is its channel at the full.
/// The texels lie as they were copied in, as a float one's and a
/// channel one's do (`_image.keptTexels`), so a copy in and a copy out
/// agree to the bit and a copy between two images of the one format moves
/// them whole. `CmdClearColorImage` reads `uint32` of the colour for such
/// an image, or `int32` where the format is signed, as Vulkan has it:
/// `float32` could not say 70000 at all.
/// `texture.Format` has the eighteen appended - `r8u` to `rgba32i` -
/// beside `wholes` and `wholesOf`, which say how many numbers a format
/// holds, how wide each is and whether it is signed, and
/// `wholeParts`/`putWholeParts` are where those bits become numbers and
/// back. A fixed fragment form built for one of them samples it directly
/// (`shader.Sampling.format`), and one built for 8888 draws it through
/// the run-time sampler as before.
/// `GetPhysicalDeviceFormatProperties` says such a format is sampled and
/// written through where the device keeps it, and never filtered linearly
/// or drawn into on any device: there is nothing to mix between two whole
/// numbers, and nothing blends one. Like a small texel, such an image is
/// for a function to read or to write - one that is only copied into and
/// out of is refused - and the V3D refuses them all, its texture unit
/// being fed what the library unpacked.
/// 71: a point is as wide as its vertex says. Vulkan's `PointSize` was
/// written by no function here: a point was one pixel, whatever
/// `line_width` said, because `shader.Vertices` had the position and the
/// varyings and nowhere to put a size - so a program that wanted a wide
/// point drew a quad of its own, with the vertices, the indices and the
/// matrix that costs.
/// `shader.Vertices.setPointSize(k, size)` is that place: a float a
/// vertex, in pixels across and down, written into `sizes` - an array of
/// its own beside the outputs rather than a slot in them, so that no
/// varying moves and a fragment function reads what it always read. The
/// library fills it with 1 before the call, so a function that writes
/// none draws the one-pixel point it always drew, and `pointSize(k)`
/// reads back what was written.
/// The widening is where it lands (`_vertices.Widening.point`): the
/// rectangle a point becomes is the size across and down about the
/// vertex, where it was half a pixel either way. The size is held inside
/// `PhysicalDeviceLimits.point_size_range`, which is new beside
/// `point_size_granularity` - Vulkan's `pointSizeRange` and
/// `pointSizeGranularity` - so 0 and a NaN draw one pixel and 1000 draws
/// 256, the widest the library makes. The granularity is 0: every size
/// between the ends is drawn as it is.
/// Both devices do it, and neither has a feature bit for it: a point is
/// widened into a rectangle on the cores whichever device draws the
/// frame, so the V3D's own point size (`cl.pointSize`, written as 1)
/// never comes into it, and a range whose end is above 1 is what Vulkan's
/// `largePoints` says. A draw of `point_list` has them, and so does one
/// of triangles drawn as their corners (`POLYGON_MODE_POINT`); a pipeline
/// that tessellates makes its points of vertices the vertex function
/// never saw, so `sizes` is null there and such a point is one pixel.
/// 72: BC4 and BC5, one channel and two. The block is the very block BC3
/// keeps its alpha in - two endpoints of 8 bits and three bits for each
/// of the sixteen texels, six values between the ends or four and the two
/// past them, as the endpoints' order says - over red alone and over red
/// and green. So the decoder was already here: `texture.blockOf` reads
/// `blockAlphas` once for BC4 and twice for BC5, and the texels read as
/// (red, 0, 0, 1) and (red, green, 0, 1), as Vulkan reads a format of
/// fewer channels.
/// `bc4_unorm_block` and `bc5_unorm_block` are the facet formats, 8 bytes
/// a block and 16 against the 64 and 128 their texels take unpacked, and
/// `texture.Format` has `bc4` and `bc5` appended. They go the way BC1 to
/// BC3 go: kept in their blocks on a device that samples them
/// (`PhysicalDeviceFeatures.kept_compressed`, the cores), copied in and
/// out as they lie with their offsets on a multiple of 4, unpacked into
/// 8888 on a device whose texture unit is fed texels (the V3D), and
/// sampled by a form built for the format or through the run-time sampler
/// by one built for 8888. Neither is a colour attachment and nothing
/// compresses into one.
/// The `_snorm` pair is not here: a texture holds 0 to 1, and -1 to 1
/// wants the read a whole number got in 1.70. BC6H and BC7 are still out,
/// and they are decoders of their own rather than a block this library
/// already had.
/// 73: BC7, four channels in the same sixteen bytes. Where BC1 to BC5
/// hold two endpoints and one index a texel, a BC7 block is cut into one,
/// two or three subsets by one of 64 patterns, each subset with two
/// endpoints of its own and each texel an index saying how far between
/// them it stands. One of eight modes says how many bits every one of
/// those takes, whether a p-bit stands under each endpoint or one is
/// shared by a subset's pair, and whether a second set of indices moves
/// the alpha apart from the colour - with a rotation that then swaps that
/// alpha into the red, the green or the blue. It is the one block of
/// these to hold a smooth alpha beside a sharp colour, which is what BC3
/// cannot: a quarter of the memory the texels take, against BC1's eighth.
/// `texture.bc7Block` reads one: the mode is the zeros of the low byte
/// before its first 1, the fields follow it lowest bit first, a channel
/// is scaled to a byte by putting the p-bit under it and repeating the
/// top bits into what is left, and the one index each subset is anchored
/// at has a bit fewer - the endpoints being ordered so its top bit would
/// be 0. A low byte of nothing is reserved by the format, and reads as
/// transparent black rather than refusing the block. The tables are the
/// specification's: `bc7_two` and `bc7_three` for the patterns,
/// `bc7_anchor_two`, `bc7_anchor_three_second` and
/// `bc7_anchor_three_third` for the anchors, and the weights of 2, 3 and
/// 4 bits out of 64.
/// `bc7_unorm_block` is the facet format and `texture.Format` has `bc7`
/// appended, 16 bytes a block against the 128 its texels take unpacked.
/// It goes the way the others go: kept in its blocks on a device that
/// samples them (`PhysicalDeviceFeatures.kept_compressed`, the cores),
/// copied in and out as it lies, unpacked into 8888 on a device whose
/// texture unit is fed texels (the V3D), and sampled by a form built for
/// the format or through the run-time sampler by one built for 8888. It
/// is no colour attachment and nothing compresses into one. The `_srgb`
/// form is not here: a texture of this library is read as it lies. BC6H
/// is still out: its endpoints are half-floats, and its texels run past
/// 1, which is a float texture's ground rather than a colour's.
/// 74: BC6H, three channels of half float in sixteen bytes a block, and
/// the last of the BC formats. It is the one of them that holds a texture
/// whose channels run past 1 - a light probe, a sky, an exposure a frame
/// is drawn from - and it has no alpha at all. The block is cut into one
/// subset or two the way BC7's is, with the same partition table over its
/// first 32 rows and the same anchors, but the endpoints are whole
/// numbers that stand for half floats: one of fourteen modes says how
/// many bits the first endpoint's channels take, how many the others take
/// as offsets on it, and where in the block every one of those sits - a
/// field at a time, a channel's bits in several places, and the
/// high-precision modes holding the top bits of the first endpoint in
/// reverse.
/// `texture.bc6hHalves` reads one: the mode is the low two bits of the
/// block where they are under 2 and the low five otherwise, the fields
/// are the specification's Table.F (`bc6_fields`, `bc6_modes`), an
/// offset endpoint is sign-extended from its own width and added to the
/// first wrapped at the first's width, and the endpoints are then
/// unquantized over the 16 bits of a half float, interpolated as whole
/// numbers, and scaled by 31/64 unsigned or 31/32 signed into the half
/// float the format means - the scaling first and the sign after it, so
/// that a small negative value whose magnitude scales to nothing is 0 and
/// not -0, which is what the hardware references do. So the interpolation is linear in what a half
/// float's bits stand for rather than in its value, which is the format's
/// own doing. A mode the format reserves - 19, 23, 27 and 31 - reads as
/// opaque black.
/// `bc6h_ufloat_block` and `bc6h_sfloat_block` are the facet formats,
/// `_ufloat` holding nothing under 0 and `_sfloat` running either way,
/// and `texture.Format` has `bc6hu` and `bc6hs` appended. A sample reads
/// such a texel held between 0 and 1 and rounded to 8 bits, the way a
/// float texel is read (`floatTexel`), and `Texture.partsAt` gives a
/// function the halves themselves - which is where the channels past 1
/// are to be had, a colour of 8 bits a channel having nothing to say
/// about them. Otherwise it goes the way the other blocks go: kept as it
/// lies on a device that samples blocks (`kept_compressed`, the cores),
/// copied in and out as it lies, unpacked into 8888 where the texture
/// unit is fed texels (the V3D, which loses what is above 1 as the copy
/// is made), and no colour attachment.
/// That is BC1 to BC7 whole. What stays out of the compressed formats is
/// the `_snorm` pair of BC4 and BC5 and the `_srgb` forms, a texture
/// holding 0 to 1 and being read as it lies; ASTC, which is a feature of
/// its own and a far larger decoder; and ETC1, which is no Vulkan format.
/// Nothing compresses into any of them.
/// What stays: `fifo` is the one present mode, there being no way to ask a
/// display to show a buffer before its next frame; one queue family of one
/// queue; a counter of 32 bits, for want of a 64-bit atomic on every
/// machine the library runs on; and no point mode in tessellation, the
/// tessellator emitting triangles or the lines of `isolines` and nothing
/// emitting a patch's points on their own.
/// 75: a fragment entry's fixed form is read and not trusted. The kind is
/// a byte of the program's own `varyings` word, and `Fixed.fromBits` read
/// it as a `FixedKind` whatever it held: `@enumFromInt` of a value the
/// enumeration has not got, which is a panic where there are checks and
/// nothing at all where there are none, reached by any program that passes
/// a word of its own making to `shader.fragment`. It answers with a null
/// now, `Entry.fixed` with it, and `CreateGraphicsPipelines` refuses such
/// a pipeline with `error_invalid_shader_nv`. Nothing a program wrote with
/// `shader.fixedFragment` reads differently - those bits always named a
/// form - but `Entry.fixed` answers an optional, so a program that reads it
/// itself says `orelse`.
/// 75: a shader can ship as SPIR-V beside its function. A program that
/// wants a device with a processor of its own to compile its fragment
/// shader passes a `shader.Module` where it passed a `shader.Code` and
/// sets `SHADER_MODULE_CREATE_SPIRV` in `ShaderModuleCreateInfo.flags`,
/// which no library read before. `Module` begins in the three fields of
/// `Code`, asserted at compile time to lie at the same offsets, so an
/// older library reads the entries out of it and calls the functions,
/// knowing nothing of the words; and a program that ships no words is
/// unchanged. `CreateShaderModule` looks the words over and refuses only
/// what no device could ever run - a bad header, a word count that walks
/// off the end, an instruction that is not one - with
/// `error_invalid_shader_nv`; what is well formed but beyond this device
/// it keeps, and `CreateGraphicsPipelines` carries it to the driver in
/// `Pipeline.fragment_words`, where `make_pipeline` answers
/// `error_feature_not_present` for a shader it cannot make code of. A
/// device without a processor of its own, and one handed a module with no
/// words, calls the Zig function as it always has.
/// 76: the V3D compiles a fragment shader of the program's own. A
/// pipeline with no fixed form (`FixedKind.none`) was refused by the V3D's
/// driver and drawn on the cores; where the program shipped the shader's
/// SPIR-V beside the function (`shader.Module`, 1.75) the driver now reads
/// it, makes QPU instructions of it
/// (`driver/v3d/compile.zig`), puts them in a block of the V3D's own that
/// lives as long as the pipeline, and draws with them. What the back end
/// cannot compile is refused as it always was, with
/// `error_feature_not_present`, and the cores draw it: a program loses
/// nothing by shipping words the device will not take.
///
/// The varyings of such a pipeline go to the hardware as the vertex
/// function wrote them. A fixed form's are `shader.channel`-scaled - 0 to
/// 255.5, for the cores - and the driver divides that back out as it
/// writes the vertex records; a generated shader's are 0 to 1, as Vulkan
/// has them and as the tile buffer takes them, and the graph's own
/// function does the scaling where it writes a pixel. So a program with a
/// generated fragment entry does not call `shader.channel` in its vertex
/// function.
pub const LIBRARY_REVISION = 76;
