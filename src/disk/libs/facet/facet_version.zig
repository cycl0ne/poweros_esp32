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
/// (`Capabilities.samplers`). A layout's `immutable_samplers` and
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
/// (`Capabilities.independent_blend`), and a device without it
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
/// (`Capabilities.stored_stencil`). `s8_uint` keeps it at each
/// pixel's only byte and `d16_unorm_s8_uint` after that pixel's depth,
/// which is what the planes' stride is for, so the four ops are taken on
/// their own: a pass may keep the stencil and leave the depth in the
/// tiles, or the other way round. Both formats are transferred now, so a
/// stencil is read back and written by CmdCopyImageToBuffer and
/// CmdCopyBufferToImage, and CmdClearDepthStencilImage clears either
/// plane by the range's aspects. The cores keep it; the V3D stores
/// neither.
/// 39: a depth image sampled where it lies
/// (`Capabilities.sampled_depth`): `d16_unorm` with
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
/// (`Capabilities.depth_clamp`, `depth_bounds`), with
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
/// (`Capabilities.kept_compressed`, the cores; the V3D is fed
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
/// samples it (`Capabilities.kept_floats`, the cores): the two
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
/// (`Capabilities.cube_arrays`, the cores;
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
/// (`Capabilities.depth_bias`): the units are the depth buffer's
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
/// (`Capabilities.small_texels`, on every device). An image of
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
/// device (`Capabilities.immutable_samplers`): the layout holds
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
/// (`Capabilities.several_outputs`); on the V3D the flag is
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
/// Only the cores (`Capabilities.samplers` and `cube_arrays`):
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
/// (`Capabilities.storage_images`).
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
/// (`Capabilities.sampled_depth`).
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
/// the same rows a sampler reads (`Capabilities.sampled_depth`,
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
/// The cores say yes to it (`Capabilities.unnormalized_coordinates`);
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
/// (`Capabilities.wide_channels`): `r8g8_unorm`, two bytes a
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
/// (`Capabilities.whole_textures`): Vulkan's `_uint` and
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
/// (`Capabilities.kept_compressed`, the cores), copied in and
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
/// samples them (`Capabilities.kept_compressed`, the cores),
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
/// 77: the V3D's compiler reads a texture. A fragment module that
/// declares a combined image sampler and samples it with
/// `OpImageSampleImplicitLod` now makes QPU instructions like the ones
/// written by hand: a texture drawn as it comes is `qpu.texture_code`'s
/// shape, and that texel times the colour the vertices carry is
/// `qpu.texture_color_code` word for word. The texel is not four
/// registers - the TMU hands back two words of two half-floats, which is
/// the form the tile buffer takes - so a program that does arithmetic
/// over it reads each float out with `fmulLow`/`fmulHigh` against a 1 it
/// holds as a uniform, which is the one instruction on this hardware
/// that reads half of a pair.
///
/// Two words of such a program's uniform stream are the TMU's
/// configuration, and only a draw can fill them in: the texture and the
/// sampler are bound to the set and the binding the module names, not to
/// the pipeline. So the draw looks them up where the module said and
/// writes them where the program reads them. A sampler asking for
/// something the TMU's state cannot say - a different filter each way,
/// a wrap that is none of its two, mipmapping, a level held or shifted,
/// anisotropy, a comparison, a border - is not drawn wrongly: the draw
/// paints `shader.missing`'s colour, as it does for a texture that is
/// not bound at all.
/// 78: what the V3D's compiler takes and what it draws, corrected. Eight
/// adversarial reviews of 77 found six defects, three of them a wrong
/// picture and all three reachable from a module a compiler writes.
///
/// A texel drawn as it comes went to the tile buffer in the form it
/// arrived in, which is right only while all four of its floats are
/// still in their pairs; a program that drew the texel *and* read a
/// float out of it moved a single f32, or a register handed out again,
/// out as two half-floats. The two floats sharing a word now also die
/// together when the colour names one of them and not the other. And a
/// product no longer takes the register of an operand that a later part
/// of the same step still reads, which `vec4(l) * colour` - the
/// commonest line of GLSL there is - did.
///
/// Three things are now taken that were refused: a constant as a
/// constituent of `OpCompositeConstruct`, so `vec4(uv, 0.25, 1.0)`
/// compiles; more combined image samplers declared than are sampled,
/// since this device's limit is one *sample*; and `OpDecorate` with a
/// literal of 65535, which used to land on an in-band sentinel. Two
/// refusals are newly named - `Declared` for the table's own bound and
/// `Numbered` for a literal past it - and a shader that always drops its
/// pixel is refused as a discard rather than as a word nobody knows.
///
/// A module read without being trusted no longer panics: `look` added
/// one to a `Location` literal unguarded, so `Location 4294967295`
/// overflowed inside `CreateShaderModule` in a ReleaseSafe build.
///
/// Where a program samples, every float of its own is now read before
/// the thread switch rather than where it is first wanted. No
/// hand-written program reads the uniform stream in the last thread
/// section, and 77 emitted up to four such reads while refusing to emit
/// one. It costs registers held across the sample, so a program with a
/// vec4 varying, a vec4 of its own and a texel is refused for want of
/// registers and the cores draw it.
///
/// And the cores can draw a generated shader that samples at all: the
/// function such a graph generates did not compile, which no test had
/// found because every sampling graph had been asked only for its words.
/// 79: a generated shader samples as the **bound sampler** says, on
/// whichever device draws it. Vulkan puts filtering in the sampler
/// object and SPIR-V has nowhere to carry what a shader asked for, so
/// the V3D has always read the sampler the draw bound; the cores read
/// the comptime `Sampling` the graph recorded instead, and the two drew
/// one pipeline two ways - a plain `b.sample` came out bilinear on the
/// cores whatever was bound, and whatever was bound on the V3D. Both now
/// go through `texture.samplingOf`, which is in neither device for that
/// reason, and a sampler it cannot answer for - a filter each way, one
/// of the three wraps the TMU has no word for, mipmapping, a level held
/// or shifted, anisotropy, a comparison - is drawn by neither: the pixel
/// is `shader.missing`, a wrong colour on purpose rather than two
/// devices quietly drawing different right ones.
///
/// That `missing` is now the right wrong colour. The cores' sampling
/// read each of its channels one byte over - alpha where red belonged -
/// and put a half-step on top that the texel's own conversion does not
/// have, so a texture that was not bound came out white rather than
/// magenta. Both conversions are one function now.
///
/// `CmdBindPipeline` records nothing for a pipeline from another device.
/// `Pipeline.driver` is the compiling driver's own object and every
/// driver reads that field as its own kind, so drawing with another
/// device's pipeline handed the hardware whatever lay there. Vulkan
/// requires the two to come from one device; both drivers are covered by
/// the one check.
/// 80: five of `docs/facet-vulkan10.md`'s items, which are all about
/// being the Vulkan 1.0 a program was written against rather than
/// something near it.
///
/// **What a format does is the device's answer, not the format's.**
/// `Ops.format_properties` is given the physical device being asked, and
/// both drivers point at the one `_format.properties`, which reads every
/// answer that differs between two devices off the features that device
/// described itself with: whether it keeps a compressed image's blocks, a
/// float one's floats, a texture's own channels or its whole numbers as it
/// was given them, and whether it samples a depth image where its rows
/// lie. One bool used to stand in for those four and nothing at all for
/// `sampled_depth`, so GetPhysicalDeviceFormatProperties said D16_UNORM
/// was sampled and filtered on every device while CreateImage refused
/// such an image on the V3D; `s8_uint` and `d16_unorm_s8_uint` likewise
/// said they were attachments where CreateRenderPass turns them down
/// without `stored_stencil` and `stored_both`. The query and the refusal
/// now agree. Vulkan 1.0 does require SAMPLED_IMAGE of D16_UNORM, so the
/// V3D is short of conformance here either way: it is short of it visibly
/// now, and the way to close it is for the TMU to learn a depth format.
///
/// Because that driver call gained a parameter and a pointer is the same
/// size whatever it points at, the shape sum behind `_driver.stamp` now
/// reads each call a field points at - how many parameters it takes and
/// the measure of each and of its answer - so a module built against the
/// old call is turned away rather than loaded and called wrongly.
///
/// **A device without anisotropy says 1.** The V3D's
/// `max_sampler_anisotropy` was the library's 16 while
/// `sampler_anisotropy` was false, which promised a program samples it
/// would then not get; Vulkan's required value for a device without the
/// feature is 1, and that is what it says. CreateSampler holds a sampler
/// to the device's own limit instead of the library's cap, so the two
/// cannot disagree again.
///
/// **The core result codes that were missing**, so that a program
/// switching on Vulkan's names finds them: `event_set`, `event_reset`,
/// `error_layer_not_present`, `error_extension_not_present`,
/// `error_incompatible_driver` and `error_unknown`. CreateInstance
/// answers `error_incompatible_driver` for an interface newer than the
/// library's, which is Vulkan's code for it, rather than
/// `error_initialization_failed`.
///
/// **Specialization constants are refused, not dropped.** A pipeline
/// stage carrying them was made with them ignored, which drew or ran
/// something the program had not asked for; it is now
/// `error_feature_not_present`. Only where there are any: a
/// `SpecializationInfo` of no entries specializes nothing in Vulkan, and
/// a program that fills the struct for every stage is not turned away.
///
/// **The core enum values and bit names that were missing**:
/// `ImageLayout.depth_stencil_read_only_optimal`, the rest of
/// VkPipelineStageFlagBits' and VkAccessFlagBits' core bits, and
/// `SHADER_STAGE_GEOMETRY`, whose bit `SHADER_STAGE_ALL_GRAPHICS` had
/// always included without a name for it. CmdClearDepthStencilImage takes
/// a `facet.ImageLayout` like its five sibling commands rather than a bare
/// `u32`; the enum is `enum(u32)`, so no call changes.
/// 81: **a module a real toolchain made is no longer refused at its
/// sixth word.** `OpExtInstImport`, `OpSource`, `OpSourceExtension`,
/// `OpName` and `OpMemberName` say nothing a device runs - an extended
/// instruction set declared, and the names and source strings glslang
/// puts around the instructions - and not one of them was in either
/// opcode list, the library's `facet_profile` or the V3D's. The simplest
/// fragment shader glslc can be given, `ocolor = vcolor;`, imports
/// GLSL.std.450 at its sixth word, so *every* module any real toolchain
/// produces was turned away there, and nothing behind that wall had ever
/// been reached. The five are taken now. `ext_inst`, which is the use of
/// an imported set rather than its declaration, is still absent: a module
/// that calls one of GLSL.std.450's functions is refused for the call,
/// which is the honest answer, and no longer for the import.
///
/// What that buys immediately is evidence rather than a capability.
/// glslc's own 111-word module for the interpolated colour - against the
/// 72 of the hand-written minimal form - now compiles to
/// `qpu.color_fragment`, the program written by hand and drawn on the
/// board, **word for word**, with the same plan: the extra words are read
/// and dropped rather than planned around. It is kept as
/// `driver/v3d/glslc_reference.zig` and `scripts/spirv-check.sh` hands it
/// to Khronos' validator with the other seven reference modules, so this
/// back end is now held against a real compiler's output and not only
/// against facet's own emitter's.
/// 82: **the version encoding is Vulkan's, and so are the four
/// physical-device structures.**
///
/// `makeVersion` was `major << 16 | minor`, carrying the library's own
/// version and revision rather than an interface version. Vulkan packs a
/// version as `variant << 29 | major << 22 | minor << 12 | patch`, so
/// Vulkan's own `VK_API_VERSION_1_0` is 4194304 where facet's
/// `API_VERSION_1_0` was 65536 - and CreateInstance refused anything above
/// `makeVersion(LIBRARY_VERSION, LIBRARY_REVISION)`, 65617 at 1.81. A
/// program that filled `InstanceCreateInfo.api_version` with the constant
/// Vulkan told it to use was therefore turned away at the first call it
/// made, with `error_incompatible_driver`. facet's own default hid it: the
/// field defaults to facet's value, so only a program saying what Vulkan
/// says was hurt.
///
/// `makeApiVersion(variant, major, minor, patch)` and
/// `makeVersion(major, minor, patch)` pack one now, and
/// `apiVersionVariant`, `apiVersionMajor`, `apiVersionMinor` and
/// `apiVersionPatch` take one apart - Vulkan's four macros, with Vulkan's
/// field widths, held to the header's own numbers by a test.
///
/// The comparison in CreateInstance changed with them, and that was the
/// larger of the two faults. It compared the whole word against the
/// library's revision; it now compares the interface's major and minor
/// version against the `API_VERSION_1_0` this library has, leaves the
/// patch out of it - Vulkan asks that an implementation take any patch of
/// a version it supports - and refuses a variant that is not Vulkan's 0.
/// What the old comparison answered was a function of the library's
/// revision and not of the interface asked for: every Vulkan-shaped
/// version number, 1.0 among them, sat above a ceiling of 65617, so all
/// of them were refused together and raising the revision moved the
/// ceiling without ever reaching one of them.
///
/// **The structures.** `PhysicalDeviceLimits` carried 26 fields of this
/// library's own choosing where Vulkan has 106. `PhysicalDeviceFeatures`
/// carried 49 Zig `bool`s where Vulkan has 55 `VkBool32`, which is 49
/// bytes against 220. `PhysicalDeviceProperties` carried five members
/// where Vulkan has nine, with no `pipelineCacheUUID` and no
/// `sparseProperties`, and `VkPhysicalDeviceSparseProperties` had no
/// counterpart at all. A program written against Vulkan's own headers and
/// bound to this library's jump table therefore read a different field
/// from the one it named, in three structures out of four, and nothing
/// said so: the shapes agreed on their first member and diverged after it.
///
/// All four are Vulkan's now - member for member, in Vulkan's order, with
/// Vulkan's types. `Bool32 = u32` with `TRUE` and `FALSE` rather than
/// Zig's `bool`, `UUID_SIZE`, `MAX_PHYSICAL_DEVICE_NAME_SIZE` 256 rather
/// than 64, and the `SAMPLE_COUNT_*` bits this library had none of at all.
/// `_driver.cacheUuid` fills `pipelineCacheUUID` from the driver stamp, so
/// a cache one build wrote is not taken up by another.
/// `scripts/vulkan-struct-check.sh` holds the four against the installed
/// `vulkan_core.h`, which is the registry's own output, and the build's
/// own gate is the test block in sdk/libs/facet/facet.zig, which pins the
/// member counts and the sizes without needing a header to be installed.
///
/// They are not *byte* for byte, and cannot be. sdk/sdk.zig forbids an
/// 8-byte-aligned extern struct anywhere in this SDK, because the Xtensa
/// compiler moves the stack pointer by exactly the bytes of a call's stack
/// arguments and an odd count would leave the callee 4 bytes off an
/// 8-byte boundary. So the nine 64-bit limits are `u64 align(4)`, this
/// SDK's house style, and the structure is 492 bytes against Vulkan's
/// 504. Features, at 220, and SparseProperties, at 20, are identical.
///
/// The 49 capability bits the features structure used to carry were never
/// Vulkan's and are not lost: they are `_instance.Capabilities` now, which
/// is what the library's own code asks, and
/// `instance/getphysicaldevicefeatures.zig` maps them onto Vulkan's 55
/// with a reason written against each. Filling them honestly turned up two
/// things worth knowing. Vulkan 1.0 requires exactly one of the 55 -
/// `robustBufferAccess`, unless an implementation advertises
/// `VK_KHR_portability_subset`, which this one does not - and a feature
/// reported false *mandates* the matching Unsupported limit value rather
/// than merely permitting it. That is why `tessellationShader` false puts
/// all eight tessellation limits at 0 and `samplerAnisotropy` false puts
/// `maxSamplerAnisotropy` at 1. The ninety-odd numbers both devices agree
/// on sit in `_instance.limits`, with the V3D overriding about eighteen of
/// them downward, so the two cannot drift apart unnoticed.
///
/// What the reshape was for was to make the shortfalls countable, and
/// src/disk/libs/facet/tests/vulkan_limits.zig counts them: Vulkan 1.0's
/// required value for every one of the 106, the feature each one hangs
/// on, and the number the cores do not meet - eighteen, pinned, and
/// accounted for item by item against docs/facet-vulkan10.md.
///
/// 83: **a generated shader on the cores draws every sampler, instead of
/// painting magenta for the ones a `Sampling` cannot say.**
///
/// 1.79 put the filtering of a generated shader in the bound sampler,
/// because that is where Vulkan puts it and SPIR-V has nowhere to carry
/// what a shader asked for. `texture.samplingOf` collapses a sampler into
/// the three fields a `Sampling` has - a format, one filter, one of two
/// wraps - and answers null for a different filter each way, a different
/// wrap each way, linear mipmapping, a lod bias, a lod clamp, anisotropy
/// above 1, a comparison, unnormalized coordinates, and three of the five
/// wraps. On null **both** devices dropped the texture and painted
/// `shader.missing`, 0xFFFF00FF, which is magenta: a wrong colour on
/// purpose, so that one pipeline could not be drawn two plausible ways
/// depending on which device took it.
///
/// It cost more than it was worth on the cores, because the cores can
/// already sample through the whole of a sampler: `texture.sampleBy` is
/// what the fixed form `shader.texturedBy` calls, and it does the levels
/// mixed, a bias and a clamp on them, mirrored and bordered edges,
/// anisotropy and unnormalized coordinates. So a program reaching a
/// generated pipeline through any sampler of depth drew magenta on a
/// device that would have drawn it correctly through a fixed form.
///
/// `ir.zig` carries the sampler now. Where `samplingOf` answers, the fast
/// path is unchanged and still samples a whole quad at a time; where it
/// does not, `sampleThrough` takes the sampler a pixel at a time through
/// `sampleBy`, with the quad's own steps for how fast the coordinates
/// change, as a GPU takes them. A test holds the generated function
/// against `texturedBy` bit for bit over eleven such samplers, which is
/// the agreement that matters: one sampler draws one thing on this device
/// whichever path takes it.
///
/// The sampler is carried **untouched**, comparison included. A graph's
/// `sample` is an ordinary sample with no reference operand - this IR has
/// no Dref operation - so a sampler with `compare` set compares against
/// 0. Vulkan leaves that undefined, since it forbids a `compareEnable`
/// sampler to anything but an `OpImage*Dref*`, and it is already what
/// `texturedBy` does with such a sampler beside a form that is not a
/// shadow form. Clearing the comparison would have drawn a tidier colour
/// and made the two paths of one device disagree, which is the one thing
/// worth avoiding here.
///
/// **The V3D still paints magenta for those samplers**, its TMU state
/// having no word for them, so one pipeline is now drawn right on the
/// cores and wrong there. That is deliberate and it is loud: magenta is
/// not a plausible picture, so it cannot be taken for the other device's
/// answer, which is what two plausible pictures would have been. Item 54
/// of docs/facet-vulkan10.md is that half - a QPU program that reads the
/// bound sampler - and closing it ends the difference.
///
/// 84: **sixteen vertex bindings and sixteen attributes, which is the
/// floor Vulkan puts under both.**
///
/// `maxVertexInputBindings` and `maxVertexInputAttributes` were 4 and 8
/// against a required 16 apiece, and only an implementation advertising
/// `VK_KHR_portability_subset` may report fewer, which this is not. A
/// pipeline asking for a fifth binding or a ninth attribute was turned
/// away with `error_feature_not_present`. Item 18 of
/// docs/facet-vulkan10.md.
///
/// The two constants in `instance/_instance.zig` are the change. Every
/// array they size grew with them - `Pipeline.bindings` and
/// `Pipeline.attributes` in the plan, `_vertices.Bound.vertex_buffers` in
/// the record of what a draw was bound with, the same field in each
/// driver's player, and the array `CmdBindVertexBuffers` copies through -
/// and every refusal already read the constants rather than a literal.
/// About 224 bytes a pipeline and 192 a bound state.
///
/// Nothing else needed touching, for two reasons worth writing down. The
/// cores' fetch, `_vertices.readInputs`, was already general: it loops
/// `attribute_count` and indexes the two arrays, and the per-vertex input
/// block is sized `vertices * locations` out of a scratch allocation that
/// grows on demand, so the array was the only cap. And the V3D fetches no
/// Vulkan attribute at all - the vertex stage runs on the cores for both
/// devices and the hardware takes a stream already transformed, so the
/// "attributes" in its shader record are the position and the varyings.
///
/// The test draws with all sixteen: location 0 the position from binding
/// 0, locations 1 to 15 each from a binding of its own and each carrying
/// its own location's number, and a vertex function that sends the
/// triangle past the far plane unless every one arrived. Then the last
/// value is made wrong and the triangle has to vanish, because a test
/// that only checks the triangle is there would pass on a library that
/// read eight attributes and left the rest at (0, 0, 0, 1).
///
/// `tests/vulkan_limits.zig` counts sixteen shortfalls now where it
/// counted eighteen, which is how this revision is held: the number is
/// pinned and the file says which item each remaining one belongs to.
///
/// 85: **one set layout holds twelve dynamic buffer descriptors, and the
/// two limits report Vulkan's own eight and four.**
///
/// `shader.MAX_DYNAMIC_OFFSETS` was 2 and CreateDescriptorSetLayout
/// refused the third dynamic buffer descriptor of a set, whatever the
/// other three sets held. The reasoning written beside the constant was
/// that four sets of two is the eight a pipeline layout may hold - which
/// is true of a layout and false of a set. Vulkan's two limits,
/// `maxDescriptorSetUniformBuffersDynamic` (at least 8) and
/// `maxDescriptorSetStorageBuffersDynamic` (at least 4), are per layout
/// and put no limit on one set, so a program is entitled to spend all
/// twelve on a single set layout and facet turned that layout away. Item
/// 19 of docs/facet-vulkan10.md.
///
/// Twelve now, which is those two added together: a layout within
/// Vulkan's floor fits in one set however it spreads them. The two limits
/// report 8 and 4 rather than the constant. The library in fact takes
/// twelve in *each* of its four sets, 48 over a layout, but 48 would be a
/// promise it cannot keep - a layout may put all 48 in one set, and a set
/// holds twelve - so what is reported is the pair that is true of every
/// arrangement, which is Vulkan's own.
///
/// `Resources.offsets` is `[MAX_SETS][12]u32`, 192 bytes where two a set
/// was 32, so `Resources` goes from about 200 bytes to about 360. The
/// cores copy it into the frame's arena once for each draw whose bindings
/// changed, which is the cost the constant was held at 2 for. The 1.43
/// measurement of four a set - FacetMany at 11.61 and 11.62 ms against
/// 11.18 to 11.58 ms with two, about 2 per cent of the mean and less than
/// that test's drift between batches - never separated the copy from the
/// noise, and a conformance floor is not a thing to trade against it
/// either way.
///
/// Two tests moved with it. The array-binding test asked for
/// `MAX_DYNAMIC_OFFSETS` elements where what it tests is an array of four
/// - its shader reads four and checks the fifth is absent - so it says
/// four now and no longer moves when the cap does. And the dynamic-offset
/// test makes the layout Vulkan entitles a program to, 8 uniform and 4
/// storage in one set, allocates a set from it and reads back that all
/// twelve slots were numbered 1 to 12: with the old cap the last ten said
/// "not shifted" instead.
///
/// 86: **1D images, which are textures of one row.**
///
/// `shapeFor` refused any `image_type` but `2d` and `3d` in one line, so
/// facet had no 1D images at all, `maxImageDimension1D` read 0 against a
/// required 4096, and no feature of Vulkan 1.0 makes them optional. The
/// mandatory format tables are scoped "for every VkImageType unless
/// otherwise noted", and only the depth/stencil and compressed tables are
/// noted, so every mandatory colour format failed its table for 1D. Item
/// 21 of docs/facet-vulkan10.md.
///
/// A 1D image is a texture one row high. That is not a shortcut: the
/// layout this library keeps halves the longer side alone and allows as
/// many levels as halving it gives (`texture.Sizes.of`), which comes to
/// floor(log2(width)) + 1 for a texture of height 1 - Vulkan's own rule
/// for a 1D image. So the levels, the layers, the copies, the memory
/// requirements and the sampling are the ones every texture already has,
/// and `max_image_dimension_1d` is the 2D width, 8192.
///
/// What had to be said is which image is which. `Image.line` tells a 1D
/// image from a 2D image one row high, because Vulkan makes them
/// different images however alike their texels lie: the 1D view types are
/// the one's and the 2D view types are the other's, and each refuses the
/// other's. `ImageViewType` gained `1d_array` at 4, which Vulkan has and
/// this enum was missing. A 1D image is held to a height and a depth of
/// 1, and `IMAGE_CREATE_CUBE_COMPATIBLE` is refused for one.
///
/// GetPhysicalDeviceImageFormatProperties shaped its probe image with
/// height = width, so it would have gone on refusing 1D images after they
/// existed and the limit would have been a number with nothing behind it.
/// It shapes one row now and answers from `max_image_dimension_1d`.
///
/// The test writes eight texels in through CmdCopyBufferToImage and reads
/// them back out through CmdCopyImageToBuffer, then reads the view's own
/// texture texel by texel and samples across the middle of each; it holds
/// the four view types a 1D image refuses and the two a 2D image refuses,
/// the levels of a 1D image with several, a 1D array and its view type,
/// and the four shapes that are not 1D images. facetprobe, which asserted
/// "a 1D image refused", asserts the shape and the view rules instead.
///
/// 87: **Sampling at a constant texel offset, on the cores.**
///
/// Vulkan requires `minTexelOffset` at most -8 and `maxTexelOffset` at
/// least 7 of every implementation, with no feature to gate them, because
/// SPIR-V's `ConstOffset` image operand needs no capability. facet
/// reported 0 at both ends and had neither the operand nor the offset.
/// Item 28 of docs/facet-vulkan10.md.
///
/// `spirv.look` had never read an operand word out of
/// `OpImageSampleImplicitLod`: it took the four-operand form and refused
/// anything longer as `truncated_instruction`, so a module carrying
/// ConstOffset was turned away for its length rather than for the
/// operand. It decodes the image-operands mask now, bit by bit, counting
/// the ids each bit brings - two for Grad - holding every one against the
/// id bound, and refusing a bit the profile does not list with a fault of
/// its own, `image_operand_refused`. That fault sits after `too_many_ids`
/// so `malformed()` keeps it in the *unsupported* tier: an operand this
/// device will not take is not a broken module.
///
/// The offset is an instruction operand and not sampler state, which is
/// what SPIR-V makes it. `texture.Point.offset` sits beside `reference`,
/// two axes because the IR samples 2D only, and `sampledAt` adds it to
/// the floored texel coordinates before the wrap: in the bilinear branch
/// the offset moves `left` and `top` while the fractions are still taken
/// from the untouched coordinate, so a half-texel sample one texel over
/// is still a half-texel sample. `ir.sampleOffset`/`sampleOffsetBy` carry
/// it, and `@compileError` outside -8 to 7 naming the two limits.
///
/// The V3D refuses it rather than getting it wrong. The QPUs take no
/// offset, so `compile.profile` does not list the bit and
/// `vkCreateGraphicsPipelines` answers `error_feature_not_present` - at
/// pipeline creation, where a program can still do something about it,
/// not at draw time. The device's two limits are *derived* from
/// `profile.takesImageOperand(.const_offset)` rather than written down, so
/// they cannot drift from what the compiler accepts, and facetprobe holds
/// a device that offsets to -8 and 7 and one that does not to 0 at both
/// ends.
///
/// The words are held against Khronos' own tools:
/// tests/spirv_reference.zig gained `min_offset`, hand-written assembly
/// through `spirv-as` and clean under `spirv-val --target-env vulkan1.0`,
/// and the IR's emitted module is compared to it word for word. Ten
/// offsets are sampled through both paths - a sampler
/// `texture.samplingOf` collapses and a `mirrored_repeat` one it cannot -
/// and four patched operand masks each come back refused and not
/// malformed.
///
/// One defect fell out of it, item 82. `CreateShaderModule` did
/// `@ptrCast(@alignCast(info.code))` before reading `magic`, and
/// `@alignCast` *panics* in a safe build when the pointer is not already
/// aligned - so the call that exists to refuse memory that is not a
/// `shader.Code` aborted inside the library for the one kind of garbage
/// that is 4-aligned, which a word array often is. It checks
/// `@intFromPtr(info.code) % @alignOf(shader.Code)` and answers
/// `error_invalid_shader_nv` now. Eight is what this API asks of that
/// pointer: it points at a struct holding a pointer, not at Vulkan's
/// `pCode`, which is only ever read as `[]const u32` behind
/// `Spirv.words`.
///
/// 88: **Two pipeline-statistics counters that did not count.**
///
/// Found while scoping item 61, and silent because the only tests of
/// these counters were of the plumbing - which counter lands in which
/// slot of a packed result, and that a counter saturates - never of a
/// value a real draw produces. Item 83 of docs/facet-vulkan10.md.
///
/// `driver/cpu/_draw.zig` returned at its first line on
/// `pipeline.draws_nothing`, which is set for `rasterizer_discard_enable`
/// and for a `cull_mode` of `CULL_MODE_FRONT_AND_BACK`, and every
/// `_query.add` in the function is below that line. So
/// `INPUT_ASSEMBLY_VERTICES`, `INPUT_ASSEMBLY_PRIMITIVES` and
/// `VERTEX_SHADER_INVOCATIONS` all read 0 for such a draw. Vulkan's one
/// licence to leave a counter alone here covers the clipping pair alone:
/// "if rasterizerDiscardEnable is enabled, the clipping input and output
/// primitives counters may not be incremented". Input assembly and the
/// vertex stage are before rasterisation and did their work. The bail is
/// below the three counters now, which leaves the clipping pair at zero,
/// as that sentence allows.
///
/// The vertex function is still not run for such a draw, and that is
/// honest only because `vertex_pipeline_stores_and_atomics` is false on
/// both devices: a vertex function writes its outputs and nothing else,
/// and the outputs of a draw that rasterises nothing cannot be read. The
/// day a device claims that feature this has to run the stage, which is
/// said beside the bail and not only in the item.
///
/// `INPUT_ASSEMBLY_PRIMITIVES` was `corner_count / 3` whatever the
/// topology, but `_vertices.assemble` writes one corner for a point, two
/// for a line and three for a triangle: a point list of twelve counted
/// four primitives and a line list of six lines counted four. Only the
/// triangle topologies were right, and the one test that checked a value
/// drew a triangle list. `_vertices.cornersPerPrimitive` is the divisor
/// now - one, two, three, or a patch's control points - and it is held
/// against `mostCorners`, the same rule counted the other way round.
///
/// A new test draws the same twelve vertices under five topologies and
/// under both draws-nothing pipelines and reads all six counters. Putting
/// either defect back makes it fail: `expected 12, found 4` for the
/// divisor, `expected 24, found 0` for the bail.
///
/// One thing beside them is left unsettled and written down rather than
/// guessed: `CLIPPING_PRIMITIVES` is wired to a count taken after face
/// culling, where Vulkan counts what the *clipping* stage output, and
/// whether a culled triangle must be counted turns on a clause the
/// queries chapter does not disambiguate. Item 83 has the text and what
/// would settle it.
///
/// 89: **The sample mask, which at one sample a pixel is one bit.**
///
/// `PhysicalDeviceLimits.max_sample_mask_words` was 0 against Vulkan's
/// required 1, and `PipelineMultisampleStateCreateInfo.sample_mask` was a
/// field nothing read. The first of item 61's eight rows, and the only one
/// of them needing no new sample: Vulkan reads
/// ceil(rasterization_samples / 32) words of the mask and ignores the bits
/// above the sample count, so with one sample a pixel the mask is bit 0
/// alone. Honouring it is complete and not a stepping stone - a pipeline
/// whose mask clears bit 0 covers no sample and draws nothing, one that
/// sets it draws as before, and a null pointer is every sample covered,
/// which Vulkan says in as many words.
///
/// Where the suppression goes is the whole of the care this needed. The
/// mask is applied *after* rasterisation, so such a draw is **not**
/// `draws_nothing`: the primitive was assembled, the vertex stage ran, and
/// it reached primitive clipping and came out of it, so
/// `INPUT_ASSEMBLY_VERTICES`, `INPUT_ASSEMBLY_PRIMITIVES`,
/// `VERTEX_SHADER_INVOCATIONS`, `CLIPPING_INVOCATIONS` and
/// `CLIPPING_PRIMITIVES` are all owed and only
/// `FRAGMENT_SHADER_INVOCATIONS` goes to zero - which is 1.88's lesson
/// applied before it could be repeated. On the cores the triangle is
/// projected, culled and counted and then dropped, in
/// `raster/batched.zig`'s `SetUp.one`: one test a triangle, nothing a
/// pixel, nothing allocated. `State.sample_mask` keeps the whole word
/// rather than a bool, because those are the per-sample bits a 4x walk
/// will read. On the V3D the draw returns, and that is exact rather than a
/// shortcut because that device reports `pipeline_statistics_queries =
/// false` - there is no counter there for a masked-off draw to owe.
///
/// The test asks for one triangle under six mask words and reads all six
/// counters each time. `0x00000002` and `0xFFFFFFFE` draw nothing, which
/// proves the bits above bit 0 are ignored rather than ORed in; `null`,
/// `0x1` and `0xFFFFFFFF` draw. Three ways of getting it wrong each make
/// it fail: not reading the mask gives `expected 0, found 2016`; setting
/// `draws_nothing` instead trips the assertion that it is not set; and
/// doing that with the assertion removed gives `expected 1, found 0` on
/// the clipping counter.
///
/// One count was already wrong beside it. `_instance.zig` said "Vulkan
/// requires the 4 bit on six of them, so this is six shortfalls", where
/// *seven* of the sample-count masks fall short:
/// `framebufferNoAttachmentsSampleCounts` wants 1|4 like the other three
/// framebuffer masks, not the 1 bit alone. The two that are met are the
/// integer sampled-image mask and the storage-image mask, the latter only
/// while `shader_storage_image_multisample` is false. The pin in
/// tests/vulkan_limits.zig is 10 now - item 17's two, item 22's one, and
/// seven of this item.
///
/// 90: **Sixty-four varyings on the cores, which is both ends of Vulkan's
/// pair.**
///
/// `maxVertexOutputComponents` and `maxFragmentInputComponents` were both
/// 8 against a required 64 - the largest single entry in the pinned
/// shortfall and two of its rows. Item 17 of docs/facet-vulkan10.md, the
/// cores' half of two.
///
/// The number was written in five uncoupled places: this library's limits
/// table, the cores' rasterizer, the vertex widening path, `ir.zig`'s
/// comptime bound and the V3D's QPU ceiling, with nothing tying them
/// together. Four of them read `shader.MAX_VARYINGS` now, in the SDK
/// beside `MAX_SETS`; the fifth is the V3D's and stays its own, because
/// it is that device's compiler's cap. (This said "a real ceiling" until
/// 1.91, which Mesa shows it is not: see 91.)
///
/// `most_stride` in `driver/_vertices.zig` was the one way this could
/// have shipped looking done, and it was worse than it looked: a bare 64
/// is 4 + 60, four short of the 64 reported, and `widen` answers an
/// over-wide stride with an all-zero `Wide` - a draw of points or lines
/// that draws *nothing* and says nothing, on both devices, since that
/// file is shared. It is `4 + shader.MAX_VARYINGS` now.
///
/// The clip path is bucketed, because it is the one place a vertex's
/// varyings are a comptime array: cutting a triangle costs what the array
/// is wide whatever the draw carries, so widening it to 64 outright would
/// have charged a two-varying draw about 11 KB of copying a cut triangle
/// against about 1.9 KB. `Clip` is an enum of 8, 16, 32 and 64, chosen
/// once a draw and dispatched by an `inline` switch into `cutUp`, so
/// every draw written before this fits the narrowest bucket and pays what
/// it paid then. Nothing else in the rasterizer needed bucketing: the
/// per-triangle planes and the per-vertex outputs are sized at run time
/// from the pipeline's own count, and the tiles hold no varyings at all.
///
/// The test is the point. A vertex function writes varying *i* as *i + 1*
/// at every corner, so each interpolates to exactly *i + 1* over the
/// triangle whatever the perspective and whatever the clipper does; the
/// fragment function reads all 64 back through `shader.Rows(65)` and
/// paints green only where every one is right. The picture is the
/// assertion. Three draws reach three paths with all 64 live: whole,
/// crossing the near plane - the only way into the clipper and the only
/// draw picking the widest bucket - and a line list, the only way into
/// `widen` and so to the `most_stride` guard. The clipped case also
/// asserts more primitives came out of clipping than went in, so the test
/// knows it went through the clipper rather than past it.
///
/// The V3D reports 8, read off `compile.most_varyings` the way item 28
/// reads the texel offsets off its profile twelve lines above. Ten usable
/// registers hold eight varyings and the four floats a program needs of
/// its own, and the vertex programs are pregenerated, one a count. Without
/// those two lines this device would have inherited 64 and refused every
/// pipeline above 8 at creation while advertising it took them.
/// `_play.zig`'s index into that table is bounded too, since the cores'
/// number now exceeds its length.
///
/// Raising the IR's bound made the V3D's own refusal testable for the
/// first time: `Error.Varyings` had no test among `compile.zig`'s twenty,
/// because a nine-varying graph could not be built while `ir.zig` refused
/// one at comptime. There is a twelve-varying graph now, refused as
/// `Error.Varyings`, whose words `spirv.look` accepts - the device
/// refusing a module, not the words being wrong.
///
/// One thing was found and left: `spirv.look` writes the same number to
/// `Seen.input_locations` and `Seen.output_locations`, which are
/// documented as two. Nothing reads either, and tests/ir.zig asserts they
/// are equal with the reason beside it rather than asserting what they
/// ought to be. Item 84.
///
/// The pin in tests/vulkan_limits.zig is 8: item 22's one row and item
/// 61's seven.
///
/// 91: **Framebuffers of 256 layers on the cores, played as Mesa's lavapipe
/// plays them.**
///
/// `maxFramebufferLayers` was 1 against a required 256, and
/// CreateFramebuffer refused any other number. Item 22 of
/// docs/facet-vulkan10.md, the cores' half of two, and the first item done
/// as a port: the design is lavapipe's
/// (src/gallium/frontends/lavapipe/lvp_execute.c, Mesa cbf692da) and the
/// numbers are v3dv's.
///
/// Nothing in Vulkan 1.0 picks a layer but a geometry shader's `Layer`, and
/// no device here has a geometry stage, so a pass draws into the first
/// layer and clears all of them. lavapipe makes each attachment's surface
/// over the framebuffer's layers from the view's base
/// (`handle_begin_rendering`), clears every one for a CLEAR load op
/// (`render_clear`), and clears a `VkClearRect`'s `[baseArrayLayer,
/// baseArrayLayer + layerCount)` from that base (`handle_clear_attachments`
/// over `clear_attachment_layers`). facet does the same: the first layer in
/// the tiles as before, and the layers past it straight into the image's
/// rows (`clearLayers` and `clearRectangle`, driver/cpu/_play.zig), through
/// the packing a tile is stored with (`raster.fillSurface`, `fillDepth`,
/// `fillStencil`), so a 565 layer is dithered exactly as the first and a
/// test holds the two to the same bytes.
///
/// To have layers at all, an image kept in rows - a colour attachment, an
/// input attachment, an image a transfer alone touches - and a depth
/// attachment never sampled may have them in optimal tiling, a layer's rows
/// after the one before. Every path that read a layer already went through
/// `rowsAt` and took them unchanged; a swapchain image says its one layer's
/// size too. A 3D image is still a function's alone, a slice being drawn
/// into through a 2D view of it, which is Vulkan 1.1's. CreateFramebuffer
/// takes 1 to the device's own limit and refuses a view of fewer layers than
/// the framebuffer has, which would have cleared past the image's last.
///
/// Two things were already wrong. `surfaceOf` ignored the colour view's
/// `base_layer`, so what drew into a view of the second layer would have
/// gone into the first: unreachable while no colour image had a second
/// layer, and invisible to every test this item invites except a draw read
/// back from both layers, which is the one written. And CmdClearAttachments
/// dropped `ClearRect`'s layer fields, so a rectangle of the second layer
/// alone would have cleared the first.
///
/// The V3D reports 1. Its render list is played once a frame, and v3dv's
/// once a layer (`cmd_buffer_emit_render_pass_layer_rcl`,
/// src/broadcom/vulkan/v3dvx_cmd_buffer.c) is the port that number waits
/// on, sized in item 22. What it does since 1.91 is begin at the layer and
/// the level a view names, as v3dv adds `v3dv_layer_offset` to every load
/// and store: until now it drew a colour frame, and stored a kept depth or
/// stencil, at the image's first byte with the first level's pitch,
/// whatever the view said - although depth views have named a layer since
/// 1.58 and a level since 1.63. The cache ranges either side of the job
/// follow the same offset. Compiled for the board, not yet run on it.
///
/// Mesa corrects 1.90 as well: v3dv carries 64 varyings on this same V3D
/// 7.1 (`v3dv_device.c`), so the V3D's 8 are this library's QPU code -
/// every varying held in a register, the programs pregenerated - and not
/// the hardware's ceiling 1.90 called them. The comments say so now, and
/// item 17 names the port: Mesa's compiler stores each vertex output into
/// the VPM as it is made (`vir_STVPMV`, src/broadcom/compiler).
///
/// The pin in tests/vulkan_limits.zig is 7, all of them item 61's.
///
/// 92: **The clipping counters counted as llvmpipe counts them, and a cull
/// of every face that culls no line and no point.**
///
/// Item 83 of docs/facet-vulkan10.md left one question open: whether a
/// back-face-culled triangle owes `CLIPPING_PRIMITIVES`, which the
/// specification's one sentence on it leaves to a reading. Mesa had already
/// answered it. llvmpipe counts `c_primitives` at the top of
/// lp_setup_tri.c's `triangle_cw`, `triangle_ccw` and `triangle_both`,
/// before the face is culled or the area worked out, and once at the top of
/// `try_setup_line` and of a point's setup; gallium's draw module counts
/// `c_invocations` as the primitives handed to its clip stage, decomposed
/// by kind (`draw_stats_clipper_primitives`, draw_context.c), after the
/// vertex, tessellation and geometry stages and before anything is culled.
/// facet now does both: `stats.pieces` counts each triangle the clipper
/// lets through to setup, whole or a piece of one it cut, before setup can
/// drop it, and `stats.clipped` is those pieces with the rectangle a line
/// or a point is widened into counted once; the draw counts what goes into
/// clipping from its primitives - input assembly's, or the evaluation's
/// under tessellation.
///
/// Four counts were wrong, and the open question was only the first. A
/// culled triangle, one with no area and one covering no pixel's centre
/// counted nothing out of clipping. A line or a point counted twice going
/// in and twice coming out, being two triangles to the rasterizer, and a
/// triangle drawn as its edges six times going in. A cull of every face
/// counted nothing into clipping, and 1.88 called that the specification's
/// licence, which is for `rasterizer_discard_enable` alone; the draw module
/// counts those primitives in, and setup's `triangle_noop` lets none out,
/// as here (`Pipeline.culls_everything`). And a tessellated draw that drew
/// nothing ran neither tessellation function, so counted neither stage.
///
/// One was not a counter at all: `CULL_MODE_FRONT_AND_BACK` drew no line
/// and no point. A line or a point has no face, Vulkan culls polygons, and
/// llvmpipe's `triangle_noop` stands in for its triangle function and for
/// nothing else; such a pipeline is no longer `draws_nothing` unless what
/// it draws is triangles.
///
/// Where facet and llvmpipe still differ, both are inside the
/// specification's "zero or more" for a primitive with no sample inside: a
/// triangle wholly outside the view is rejected at the view's side here and
/// at llvmpipe's guard band there (lp_context.c turns the draw module's
/// guard band on), and llvmpipe itself counts a culled triangle when its
/// setup culls it and not when the draw module's cull stage does, which it
/// runs for a draw that needs clipping. facet counts it in both cases.
///
/// A test draws each case and reads both counters: a culled triangle, one
/// of no area, one between four pixels' centres and one wholly outside; a
/// polygon drawn as its edges and as its corners, one face culled; a line
/// cut at the near plane and a point behind it; lines and points under a
/// cull of every face; and a tessellated patch drawn, culled whole and
/// discarded. Putting any of the eight changes back fails it, among them
/// `expected 12, found 24` for a line counted twice, `expected 8, found 0`
/// for the cull counted as a discard, and `expected 1, found 0` for a
/// culled triangle.
///
/// 93: **A timestamp pool made on a machine without timer.device.**
///
/// Item 45 of docs/facet-vulkan10.md. CreateQueryPool refused a timestamp
/// pool wherever the library had no clock, and Vulkan has no refusal of a
/// kind of pool: vk.xml gives `vkCreateQueryPool` no error but memory's
/// (and, later, `VK_ERROR_UNKNOWN` and `VK_ERROR_VALIDATION_FAILED`). A
/// device says it cannot time things through its queue family's
/// `timestampValidBits` of 0, which facet already said, and the pool is
/// made now.
///
/// A timestamp written into it all the same, which is invalid usage on
/// such a queue (VUID-vkCmdWriteTimestamp-timestampValidBits-00829), is 0
/// and available, as `_queries.stamped` already had it: the specification
/// says the bits outside the valid range are zeros, and with none valid
/// that is every bit. The item asked for the query left unavailable
/// instead, which would leave a `QUERY_RESULT_WAIT` read waiting for ever,
/// and said `stamped` already did that, which it never did.
///
/// `timestamp_compute_and_graphics` stayed true without a clock, beside
/// timestamp bits of 0, and Vulkan's true promises at least 36 of them on
/// every graphics and compute queue: it is cleared with them.
///
/// The host has no timer.device, so the test runs there: the pool is
/// made, a timestamp written into it reads 0 without waiting, and the
/// limit reads false. Each of four changes put back fails it alone:
/// `expected .success, found .error_feature_not_present` for the refusal,
/// `expected 0, found 1` for the limit left true and for a value other
/// than 0, and `expected .success, found .not_ready` for the query left
/// unavailable.
///
/// 94: **A view of both planes of a sampled depth+stencil image.**
///
/// Item 44 of docs/facet-vulkan10.md. CreateImageView refused a view
/// naming both aspects of a `d16_unorm_s8_uint` image made SAMPLED or
/// INPUT_ATTACHMENT, so an image that was both a pass's depth/stencil
/// attachment and a shadow map had no view of both its planes to give a
/// framebuffer. Vulkan allows one ("can include both", resources.adoc),
/// keeps it out of descriptors (VUID-VkDescriptorImageInfo-imageView-01976),
/// and has an attachment draw into both planes whatever its view names.
/// The view is made now, and its texture is the depth: what lavapipe's
/// sampler view of both reads, `lvp_create_samplerview` taking the stencil
/// for the stencil alone. The cores drew into both planes already, from the
/// image rather than the view (`_play.planeAt`), so nothing changed there.
///
/// Both aspects of a format holding one plane alone are still refused:
/// they name a plane it has not got.
///
/// A test makes the view, finds its texture the depth plane, and clears
/// both planes through it as a pass's attachment, reading each back in two
/// tiles. The test of the refusals that stay had never reached the aspect:
/// a `2d` view of all three layers of its image is refused for its layers
/// first, `layer_count` being `REMAINING` unless it is given, so it names
/// one layer now. Each of three changes put back fails it alone:
/// `expected .success, found .error_format_not_supported` for the
/// refusal, `expected .d16, found .r8` for the stencil taken for both, and
/// `expected .error_format_not_supported, found .success` for both taken
/// of a format with one plane.
///
/// 95: **`spirv.Seen` no longer claims to count a module's locations.**
///
/// Item 84 of docs/facet-vulkan10.md. `Seen.input_locations` and
/// `output_locations` were documented as the largest `Location` on an
/// input and on an output, and `look` wrote the largest of any to both,
/// not telling one side from the other; nothing read either. Counting them
/// as documented means matching a decoration's target to its variable's
/// storage class. The V3D's back end already does that, with its own table
/// of locations by id read beside each variable (driver/v3d/compile.zig),
/// and Mesa does it in the translation: `var_decoration_cb` applies a
/// `Location` with the variable's mode beside it (vtn_variables.c:1705),
/// and `nir_shader_gather_info` sets `inputs_read` and `outputs_written`
/// from what was translated (nir_gather_info.c `set_io_mask`). So the two
/// fields are gone rather than mended, and
/// all `look` reads of a `Location` is that its literal is there: a
/// decoration cut short before it is `truncated_instruction`, as it was,
/// and a test says so now. Taking that check out fails it, `expected
/// .truncated_instruction, found .bad_word_count`: the literal's place is
/// read as the next instruction.
///
/// tests/ir.zig asserted the two were equal, with the reason beside it;
/// it asserts the widest graph's sixteen inputs and one output instead.
///
/// 96: **The seven sample-count masks say one sample and four, held to
/// what a device draws, and the three optional multisample features no
/// longer follow the capability.**
///
/// Step S1 of item 61 of docs/facet-vulkan10.md. `_instance.limits` says
/// 1|4 in the seven masks Vulkan asks the 4 bit of, as v3dv does on this
/// GPU (`supported_sample_counts`, v3dv_device.c) and lavapipe on the
/// cores with 8 beside it. `narrowSampleCounts`, run after each driver's
/// describe, holds the seven to the 1 bit on a device without
/// `can.multisampling`, which is every device still. It holds the
/// no-attachments mask to it on every device until such a subpass may be
/// made (item 43), and a bit a driver cleared stays clear. What any device
/// reports is unchanged.
///
/// `sample_rate_shading`, `alpha_to_one` and `variable_multisample_rate`
/// were `of(can.multisampling)`, so all three would have been claimed the
/// day a device drew four samples. They are optional, and Vulkan's three
/// interpolation-offset limits come with the first. They are false now
/// whatever the device draws: both Mesa drivers have the first two, and
/// they are a port of their own after item 61.
///
/// A test reads the masks through the API, describes the cores again as a
/// device with the capability, and runs the narrowing over the V3D's
/// zeros, which only the board can describe. Each of six changes put back
/// fails it:
/// - describing without the narrowing, which also gives `expected 7,
///   found 0` in the limits pin;
/// - leaving the no-attachments mask or the sampled stencil mask
///   unnarrowed, which also gives `expected 7, found 6` there;
/// - setting a mask rather than ANDing it, which fails on the V3D's zeros
///   alone;
/// - tying either feature to the capability again, `expected 0, found 1`.
///
/// 97: **A BC1 or BC4 image with a full chain of levels no longer
/// overflows its layout, and no compressed image is 1D.**
///
/// `texture.Level.of` worked out `row_gap` - the bits between a row's low
/// two and its others, for the wrapping walk over texels of `shift`
/// bytes - for every format. A block of 8 bytes is narrower than the 16
/// texels the gap counts in, so for a level 4 texels across or narrower
/// it underflowed. CreateImage of such an image, and the format query,
/// whose largest image has every level, panicked with `integer overflow`.
/// Nothing reads the gap of a compressed level, which is read a block at a
/// time (`blockAt`), so it is 0 there now.
///
/// A 1D image of a compressed format, made since 1.86, is refused now, as
/// lavapipe and v3dv refuse it (`lvp_get_image_format_properties`,
/// `v3dv_get_image_format_properties`). Its blocks are four rows high, and
/// Vulkan scopes the compressed format tables away from 1D. ETC2 and EAC,
/// unpacked as they are copied in, are refused as 1D the same way.
///
/// Found by the sweep step S2 of docs/facet-vulkan10.md item 61 makes of
/// the format query, over every format, type, tiling, usage and flag. A
/// test makes BC1, BC1 with alpha, BC4 and BC3 images of five levels and
/// asks the query for the largest, and finds the 1D one refused by both
/// calls. Each change put back fails it: the gap as it was panics with
/// `integer overflow` at texture.zig's line again, and the 1D image made
/// gives `expected .error_format_not_supported, found .success`.
///
/// 98: **CreateImage makes an image of four samples a pixel, and the
/// format query says 4 exactly where it does.**
///
/// Step S2 of item 61 of docs/facet-vulkan10.md. On a device with
/// `can.multisampling`, which none has yet, `samples = 4` is taken for a
/// 2D image in optimal tiling with one level, not cube compatible, whose
/// usage is attachment, input-attachment and transfer bits only, of a
/// format with a colour or depth/stencil attachment feature. Each sample
/// is a plane of the one-sample image's bytes, every layer of it, one
/// after another, as llvmpipe lays a texture out
/// (`llvmpipe_texture_layout`, `sample_stride`): `Image.sample_bytes` is
/// a plane's size and `bytes` four of them. A device whose images are laid
/// out by its driver (`ops.texture_memory`, the V3D's) is refused until
/// its layout of four samples (step V3).
///
/// GetPhysicalDeviceImageFormatProperties asks `shapeFor` for the asked
/// image with one level and four samples, and says 4 beside 1 where it is
/// made, with `max_resource_size` the larger of the two. Vulkan holds the
/// answer to the seven masks for every usage it does not exclude, so the
/// plan's refusal of layers and of input attachments was dropped: such an
/// image is made, and a render pass reading an attachment of four samples
/// stays refused (createrenderpass.zig).
///
/// A test makes the image of every shape, format and count the rule names
/// and of none it does not, and sweeps the query over every format, type,
/// tiling, flag and usage with and without the capability, comparing its
/// answer with what CreateImage makes. Each of eleven changes put back
/// fails it: the planes not multiplied, any format taken, the query
/// never saying 4 (`expected 5, found 1`), the query probing every level,
/// the capability not asked (which fails the older image test too),
/// SAMPLED taken, input attachments refused, any count up to 4, levels,
/// cube images, or linear and 3D images taken.
///
/// 99: **An image of four samples is copied and cleared plane by plane,
/// and a blit or a buffer copy leaves it alone.**
///
/// Step S3 of item 61 of docs/facet-vulkan10.md. CmdCopyImage copies each
/// sample's plane into the same sample's plane of the other image, as
/// llvmpipe does (`lp_resource_copy_ms`, lp_surface.c), through
/// `_image.sampleOf`: a plane as an image of one sample, so what reads and
/// writes texels is unchanged. Images of two counts are not copied, which
/// Vulkan has them never be (VUID-vkCmdCopyImage-srcImage-00136).
/// CmdClearColorImage and CmdClearDepthStencilImage clear every plane, as
/// `llvmpipe_clear_texture` clears each sample. CmdBlitImage,
/// CmdCopyImageToBuffer and CmdCopyBufferToImage do nothing with an image
/// of four samples, which Vulkan has none of them take
/// (VUID-vkCmdBlitImage-srcImage-00233, -dstImage-00234,
/// VUID-vkCmdCopyImageToBuffer-srcImage-07973,
/// VUID-vkCmdCopyBufferToImage-dstImage-07973). `Image.sample_bytes` has
/// no default now, so every place an image is made says it, a swapchain's
/// as well.
///
/// No device has the capability yet, so what any program sees is
/// unchanged. A test makes a 4x image of two layers with the capability
/// turned on, marks each texel of it with its sample, layer and place,
/// clears another, copies a rectangle from one layer to the other, and
/// then tries a blit, a copy into a 1x image and a copy to and from a
/// buffer, none of which may write. It clears a 4x depth image too. Each
/// of nine changes put back fails it: a copy of the first plane alone,
/// from the source's first plane into each, between two counts, a plane
/// not offset, either clear of the first plane alone, and each of the
/// three refusals taken away.
///
/// 100: **A render pass, a framebuffer and a pipeline may have four
/// samples a pixel, and a colour attachment of four a resolve
/// attachment.**
///
/// Step S4 of item 61 of docs/facet-vulkan10.md. On a device with
/// `can.multisampling`, which none has yet, CreateRenderPass takes
/// attachments of four samples where each subpass's colour and depth
/// attachments hold one count (VUID-VkSubpassDescription-pColorAttachments-09430,
/// -pDepthStencilAttachment-01418), and keeps it in `Part.samples`. A
/// colour attachment of four may name a resolve attachment of one sample
/// and its own format (-pResolveAttachments-00848, -00849, -00850), kept
/// in `Part.resolves`. The resolve is the attachment's first use, so a
/// later subpass drawing into it keeps what it holds, and a subpass that
/// resolves never goes on in the tiles of the one before. An input
/// attachment of four samples stays refused, as do counts the device does
/// not draw.
///
/// CreateFramebuffer holds each view's image to its attachment's count
/// (VUID-VkFramebufferCreateInfo-pAttachments-00881) and a resolve's view
/// to rows of the colour's format that hold the render area, kept in
/// `Target.resolves`. The targets are set a field at a time out of an
/// undefined array, so a part without a resolve has its own set to none
/// as well: the proof found it left as whatever was there.
///
/// CreateGraphicsPipelines takes `rasterization_samples` of 4 where the
/// subpass has four
/// (VUID-VkGraphicsPipelineCreateInfo-multisampledRenderToSingleSampled-06853),
/// kept in `Pipeline.samples`. Sample shading, alpha to one and alpha to
/// coverage stay refused. v3dv asserts that a pipeline's count is 1 or 4
/// (v3dv_pipeline.c:1319-1320) and leaves the rest to Vulkan's valid
/// usage. These calls refuse what Vulkan has no program do, as this
/// library does elsewhere. Nothing is drawn with four samples yet: steps
/// K1 to K7 do that on the cores, V1 to V5 on the V3D, and each turns the
/// capability on at its end.
///
/// The SDK's `ImageCreateInfo.samples`, `AttachmentDescription.samples`,
/// `SubpassDescription.resolve_attachments` and
/// `PipelineMultisampleStateCreateInfo.rasterization_samples` say so. The
/// first had gone on saying one sample after 1.98 made four.
///
/// A test turns the capability on and makes such a pass, framebuffer and
/// pipeline, and is refused every mismatch Vulkan has none of. Each of
/// nineteen changes put back fails it:
/// - an attachment of two samples, or of four without the capability,
///   taken;
/// - a subpass's counts not compared;
/// - a part's count, a resolve or a resolve view not kept;
/// - a resolve of a one-sample colour, of four samples or of another
///   format taken;
/// - a resolve not counted as the attachment's first use;
/// - resolving subpasses joined;
/// - an input attachment of four taken;
/// - a view's count not compared, or a resolve view of another format
///   taken;
/// - a target without a resolve left undefined;
/// - a pipeline of two samples, of a count other than its subpass's, or
///   with alpha to coverage, taken, or its count not kept.
///
/// 101: **CmdResolveImage, LVO -524: each pixel the average of its four
/// samples.**
///
/// Step S5 of item 61 of docs/facet-vulkan10.md, and item 13. The command
/// and `facet.ImageResolve` are Vulkan's, and the body is the cores' for
/// both devices. lavapipe resolves a region by a NEAREST blit
/// (`handle_resolve_image`, lvp_execute.c:3871-3916), and Mesa's resolve
/// adds the samples and multiplies by one over their count
/// (`build_tex_resolve`, vk_meta_blit_resolve.c:134-196). Vulkan has the
/// write take one of the two values nearest to that, and it should take
/// the nearer (Fixed-Point Data Conversions). `_transfer.resolveImage`
/// does the same in whole numbers, (s0 + s1 + s2 + s3 + 2) >> 2 for each
/// channel, the nearest value with a tie taken upward: `average8888`
/// takes two 8-bit channels a word at a time, in lanes of 16 bits that
/// never carry, and `average565` the three of R5G6B5. The destination is
/// written through its own layout, rows or a texture.
///
/// A source not of four samples, a destination of more than one or two
/// formats resolve nothing, Vulkan having no program give them
/// (VUID-vkCmdResolveImage-srcImage-00257, -dstImage-00259,
/// -srcImage-12546). No device makes an image of four samples yet, so a
/// program's call still has nothing to do; the V3D's player hands the
/// command to the same body until step V5 resolves in its tile buffer.
///
/// A test holds the average to the plan's ties - 255, 255, 255 and 0 give
/// 191; 0, 0, 1 and 1 give 1; 0, 0, 0 and 1 give 0 - and to the formula
/// a channel at a time over ten thousand random words, and `ImageResolve`
/// to VkImageResolve's 68 bytes. A second one, with the capability turned
/// on, resolves three rectangles of a 4x image of two layers, one cut at
/// the destination's edge, into rows and into a texture, and a 565 one,
/// and is refused the three Vulkan has none of. Each of twelve changes
/// put back fails one of them:
/// - the even channels or the odd ones not rounded, or the lanes not
///   masked;
/// - the green of 565 not rounded;
/// - one plane read for every sample;
/// - a destination of four samples, or of another format, taken;
/// - the source's layer or offset, or the destination's offset, not the
///   region's;
/// - the destination's edge not cut;
/// - the cores playing the command as nothing.
///
/// The compiler refuses a player of the cores that leaves the command
/// out altogether: its switch must name every command, the `_` prong
/// being only for numbers that have no name.
///
/// 102: **The cores tell which of a pixel's four samples a triangle
/// holds: in its box, in the tiles it is binned into and in the runs the
/// walk hands on.**
///
/// Step K1 of item 61 of docs/facet-vulkan10.md. Nothing draws four
/// samples yet: every caller asks for one, until K2 puts the samples in
/// the tile.
///
/// `setup.sampleOffsets` has Vulkan's standard positions of four samples,
/// llvmpipe's `lp_sample_pos_4x` (lp_rast.c:63-66) in the fixed point it
/// makes of them (lp_setup.c:127-128), taken from the pixel's centre,
/// where this library's edges are; at four llvmpipe moves its edges to the
/// pixel's corner instead (lp_setup.c:632). An edge's value at a sample is
/// the centre's and what the offset adds (`Edge.offsetBy`), a whole
/// number, so the top-left rule holds for each sample as it does for the
/// centre, and two triangles on an edge share its samples out between
/// them.
///
/// `setup.onSurface` takes the count. At four its box holds the pixels
/// whose samples' columns and rows, from 32 to 224 of a pixel from its
/// corner, overlap the triangle's, as at one it holds those whose centres
/// it covers; llvmpipe's box of whole pixels (lp_setup_tri.c:314-324)
/// holds more. Each edge keeps what the most inside of a pixel's samples
/// adds (`Edge.inmost`), and binning adds it to a tile's most inside
/// corner (`touches`).
///
/// `walk.quads` takes it too. At four each sample crosses each edge on
/// its own, as llvmpipe tests each sample against each plane
/// (`do_block_4`, lp_rast_tri_tmp.h:63-72), and a pair of rows hands on
/// four runs a row. `walk.sampleMask` makes them a quad's samples, bit
/// 4s + i sample s of pixel i, and `walk.pixelsOf` its pixels with any of
/// them. An edge along the rows holds some of a row's samples and not the
/// others: it takes off the rows its most inside sample is outside, and
/// each row asks it of the others. At one sample a pixel the walk does
/// what it did: 2400 triangles, each drawn on five pipelines, came out
/// the same bytes before and after.
///
/// A test sets up, bins and walks random triangles of seven shapes -
/// anywhere, small, slivers, on the samples' grid and with an edge along
/// the rows or the columns - at four samples a pixel and at one, and holds
/// every sample to its own test against the vertices, at the positions as
/// Vulkan's table has them: each inside handed on once and no other, and
/// every tile with one binned. A second lays the edge two triangles share
/// through samples, down a column of them, along a row and across them at
/// four slopes, and finds each sample on it in one of the two and none in
/// both. A third bins a sliver whose one sample in a tile is in the
/// tile's corner pixel, which that pixel's centre alone leaves out. Each
/// of fifteen changes put back fails one of them:
/// - a tile binned by its corner's centre alone, or `inmost` never set;
/// - the centre's box at four samples;
/// - samples 1 and 2 swapped, or sample 0 a 256th of a pixel to the left
///   or the right;
/// - a sample's y offset taken the wrong way, or its x offset for its y;
/// - every sample crossing an edge where the centre does;
/// - an edge along the rows asked of no sample, or its rows taken off at
///   the centre;
/// - the top-left rule dropped at four samples;
/// - a mask's samples a bit apart rather than four, or sample 3 left out
///   of a quad's pixels;
/// - a row's runs taken as empty when its first sample's is.
///
/// 103: **The cores draw four samples a pixel in colour: a plane for each
/// sample in the tile, a pixel shaded once, and each sample written and
/// counted as its own coverage says.**
///
/// Step K2 of item 61 of docs/facet-vulkan10.md. No device draws four
/// samples yet: the capability stays off until K7, and the tests turn it
/// on.
///
/// A frame of four samples (`Attachments.samples`, the render pass's)
/// keeps samples 1 to 3 of each colour attachment in planes of their own.
/// They sit after the extra attachments' planes, in the block each part has
/// beside its buffer (`Tile.samplePlane`). The buffer, and a frame of one
/// sample, are as they were. Every plane is cleared, loaded and stored
/// on its own, from and into its own plane of the image
/// (`Surface.sample_bytes`).
///
/// The walk hands on each sample's runs (1.102). A quad's samples are cut
/// to the pipeline's sample mask, each of its four bits spread over its
/// sample's four (`Shading.sample_bits`), as llvmpipe ANDs each sample's
/// coverage with that sample's bit (lp_state_fs.c:3505-3513). A pixel with
/// any sample left is shaded once, its fragment function given those
/// pixels as `covered`. llvmpipe likewise runs its shader once, under the
/// samples' masks ORed together (lp_state_fs.c:860-870), unless it shades
/// by sample (:1076). The colour goes into the plane of each sample
/// covered, blended with that sample's own (`Batch.put`): llvmpipe blends
/// its one colour into each sample's plane under that sample's mask
/// (lp_state_fs.c:3651-3672). An occlusion query counts the samples
/// (lp_state_fs.c:1017-1021, :1443-1448). A triangle whose mask holds
/// none of the frame's samples stops after setup, as at one sample
/// (lp_setup_context.h:311-316).
///
/// The depth and the stencil are still one a pixel, tested and written at
/// its centre, until K3. A frame of four draws without the depth
/// pre-pass, whose walk is of pixels. At one sample a pixel nothing
/// changes: 200 triangles through five pipelines, and an occlusion query
/// over them, came out the same bytes before and after. The pipelines test
/// depth, ask for the pre-pass, add, mix, and mask every sample away.
///
/// Three tests turn the capability on and draw into images of four
/// samples. Every plane is written by hand first, and each plane is then
/// held, pixel by pixel, to each sample tested against the triangle's
/// corners.
/// - One draws a triangle across four tiles, cut by the render area,
///   through a pipeline that asks for the depth pre-pass. It counts the
///   fragment function's pixels and the query's samples. A second pass
///   then loads, draws another triangle, and drops its odd columns.
/// - One blends three draws over the whole attachment, each under a sample
///   mask of its own: added, mixed one and one, and stored. A pass of one
///   sample on the same queue comes before them, and a rectangle of the
///   attachment is cleared after them.
/// - One draws three attachments together.
///
/// Each of thirty changes put back fails one of them:
/// - every plane but the first left uncleared, unloaded or unstored, or
///   every plane of the image taken for its first;
/// - the samples' planes laid over the extra planes, the batch's colours
///   over the samples' planes, or every attachment's samples in the
///   first's;
/// - no room for the samples' planes, the room not kept, or a target laid
///   out for one sample drawing four;
/// - the image's planes or the frame's samples not given;
/// - a frame of four walked or set up as one;
/// - the sample mask's bit 0 alone tested, the mask spread over a pixel's
///   samples, or not applied;
/// - the depth pre-pass at four samples;
/// - the quads looked for in sample 0's runs alone, or to the nearest
///   run's end, or the upper rows' runs taken for the lower;
/// - a quad's pixels those of its sample 0, or its mask not kept;
/// - a full batch put as one sample, or the first sample's plane alone
///   written;
/// - a dropped pixel's samples written, a kept pixel's written into every
///   plane, or each plane by the mirrored sample's bits;
/// - the query given pixels, or a dropped pixel's samples.
///
/// 104: **A framebuffer's layers past its first are cleared in every
/// sample of an image of four samples, not in the first alone.**
///
/// A fix to step S4 of item 61 of docs/facet-vulkan10.md, which let a
/// framebuffer of four samples a pixel have layers. The tiles draw only
/// into a framebuffer's first layer; the others are cleared straight into
/// the image's rows (1.91), by a load op and by CmdClearAttachments. Of an
/// image of four samples that cleared sample 0's plane alone. 1.103 said in
/// `raster.fillSurface`'s comment that such an image had the one layer,
/// which is wrong: 1.98 takes layers for it. Each sample's plane of each of
/// those layers is cleared now, of the colour, the depth and the stencil,
/// as llvmpipe clears a surface of more than one sample a sample at a time
/// (`llvmpipe_clear_render_target`, lp_surface.c:356-368;
/// `llvmpipe_clear_depth_stencil`, :429-442). `surfaceAt` and `planeAt`
/// take the sample whose plane they give. `Surface.sample_bytes`'s comment
/// said it was 0 at one sample a pixel; an image of one sample gives its
/// whole size there, which a frame of one sample never reads.
///
/// No device draws four samples yet, and an image of one sample is
/// cleared as before. A test turns the capability on and marks every byte
/// of a colour image and of a depth-and-stencil image, both of four samples
/// and two layers. It clears both in a render area short of them on every
/// side, then clears a corner of the second layer in colour and another in
/// depth and stencil. Every sample's plane of the second layer is held to
/// the clears inside the area and to the marks outside it, and the byte
/// after each pixel's depth and stencil stays marked. Each of twelve
/// changes put back fails it:
/// - for each of the two ways of clearing, its colour, its depth or its
///   stencil written into sample 0's plane four times;
/// - for each of the two, its colour, or its depth and stencil, cleared in
///   one sample;
/// - a sample's plane not reached by `surfaceAt`, or by `planeAt`.
///
/// 105: **The cores test four samples a pixel in depth and in stencil,
/// each sample in planes of its own and at its own place in the pixel.**
///
/// Step K3 of item 61 of docs/facet-vulkan10.md. No device draws four
/// samples yet: the capability stays off until K7, and the tests turn it
/// on.
///
/// A frame of four samples keeps samples 1 to 3 of the depth and of the
/// stencil in planes of their own (`Tile.depthPlane`,
/// `Tile.stencilPlane`). They sit after the colour samples' planes, in the
/// block each part has beside its buffer. Each is cleared, loaded and
/// stored on its own, from and into its own plane of the image
/// (`Attachments.Plane.sample_bytes`), as each colour sample's has been
/// since 1.103. A frame of one sample is laid out as before.
///
/// A sample's depth is the triangle's plane at the sample's own place,
/// stepped along the row from where that sample's own run starts
/// (`Depth.atSample`, `sampleDepths`). llvmpipe likewise interpolates the
/// depth at each sample's position (lp_state_fs.c:946-956), and holds it
/// in the range as a pixel's is held (:970, :350-400). Each sample is then
/// tested in its own planes, the stencil and then the depth, by the
/// pipeline's ops, as a pixel is at one sample: llvmpipe runs its early
/// depth and stencil test once for each sample (lp_state_fs.c:907). Only
/// the samples that pass have their colour written and are counted. A
/// pixel is shaded where any is left, under their masks ORed together
/// (:1047-1050), and a quad with none left is not shaded at all.
///
/// A form that drops pixels holds its depths back for after its fragment
/// function, sixteen a quad at four samples (`Tile.batch_depths`), and
/// then writes each sample's depth for the pixels the function left.
/// llvmpipe writes each sample's depth after its shader, under that
/// sample's mask ANDed with the shader's (lp_state_fs.c:1321-1334,
/// :1426-1440).
///
/// At one sample a pixel nothing changes. 360 triangles went through nine
/// pipelines into a depth beside a stencil, under an occlusion query, and
/// came out the same bytes before and after. The pipelines test less and
/// less-or-equal, ask for the pre-pass, add, replace the stencil and then
/// test it, clamp the depth inside a narrow viewport range, test depth
/// bounds, drop pixels, and mask every sample away.
///
/// Three tests turn the capability on and draw into images of four
/// samples. Each works out every sample's value from the triangles'
/// corners and depths at that sample's own place, and holds the sample to
/// it:
/// - Two triangles cross, along a line that runs through pixels. Some
///   pixels' samples go to both. Some samples go to the triangle a test at
///   the centre would not have picked. The first triangle is a cut-out
///   that drops every other four columns, so its depths wait for its
///   fragment function. The second's quads are counted as they are shaded,
///   and those wholly behind the first are not. A second pass loads both
///   attachments and draws a flat triangle against each sample's loaded
///   depth. All of this runs for a depth alone and for one beside a
///   stencil, whose planes keep their clear.
/// - The stencil: the first triangle replaces it, and the second tests it
///   and inverts, zeroes or increments it, each sample by its own depth
///   test. All five outcomes are found. A second pass loads, and draws
///   where the stencil it loaded says.
/// - Under the depth clamp, a triangle's depths run past both ends of a
///   narrow viewport range. Some samples are held at either end, and some
///   lie between them.
///
/// 1.103's test of colour attachments drawn together now has a depth of
/// four samples beside them. 1.104's test of layers now holds the first
/// layer's depth and stencil in every sample. A test of `target.zig` lays
/// out a part's block at one sample and at four, for one to four colour
/// attachments. It holds everything a tile is handed past its buffer
/// inside the block, and apart from everything else. On the board the
/// parts draw at once, so a block too small runs into the next part's. The
/// host tests draw one part after another and would not see it: two of
/// the changes below passed every draw test before this one was written.
///
/// Each of twenty-seven changes put back fails one of them:
/// - each sample's depth or stencil cleared, loaded or stored as sample
///   0's; an image's pixel taken without its sample's plane, or `planeAt`
///   giving none;
/// - the depth planes laid over the colour samples', the stencil's over
///   the depth's, a batch's depths over the stencil's, or the colours past
///   the first over a batch's depths;
/// - a part's block without room for the samples' depths and stencils, or
///   for a batch's depths;
/// - each sample's depth taken at the pixel's centre, with the clamp or
///   without it, or from sample 0's run;
/// - each sample tested at sample 0's depth, against sample 0's stored
///   depth, or in sample 0's stencil;
/// - the samples, or the pixels shaded, not cut by the tests;
/// - a held depth held as sample 0's, written into sample 0's plane,
///   written for every pixel, or read as sample 0's;
/// - a clamped depth not held inside the viewport's range.
///
/// 106: **A depth attachment's pair of ops for a plane its format has not
/// does nothing, as in Vulkan, and no longer refuses the render pass.**
///
/// Vulkan's `loadOp` and `storeOp` are the depth's, and `stencilLoadOp`
/// and `stencilStoreOp` the stencil's (VkAttachmentDescription). Since
/// 1.38 CreateRenderPass answered `error_feature_not_present` for a
/// stencil kept of a `d16_unorm` and for a depth kept of an `s8_uint`: a
/// pass Vulkan takes, which a program may well make with LOAD and STORE
/// in all four. Each pair is now read only for a plane the format has, as
/// Mesa's render passes read them (vk_render_pass.c:1561-1567,
/// :1833-1839; `v3dv_cmd_buffer_check_needs_load`,
/// v3dv_cmd_buffer.c:1533-1544), and a pair for a plane it has not keeps
/// nothing. A device that keeps no stencil takes a depth alone whose
/// stencil's ops say to keep it, as there is none to keep.
///
/// K3's test of depths at four samples (1.105) found it: its `d16_unorm`
/// attachment needed the stencil's two ops as DONT_CARE to be made at
/// all. It now gives both of its formats the same four. The render pass
/// test's two cases of such ops move from those refused to those taken,
/// each part said to load and store neither plane. Each of four changes
/// put back fails it: the stencil's load op or store op read for a format
/// without a stencil, or the depth's for one without a depth.
///
/// 107: **A form that drops pixels, drawn a pixel at a time, leaves the
/// depth and the stencil of a pixel it drops as they were.**
///
/// A draw with a stencil test, the depth clamp or a depth bounds test goes
/// a pixel at a time (batched.zig), and it wrote each pixel's depth and
/// stencil as it tested them, before the fragment function had run: the
/// cut-out form's dropped pixels left both behind. That way now takes
/// llvmpipe's depth modes for a shader that may kill
/// (lp_state_fs.c:772-799). Where the stencil test writes the stencil -
/// either face's write mask not 0 - the stencil and depth tests wait for
/// the fragment function and test the pixels it left, at the depths taken
/// in the walk (`Shading.late`; lp_state_fs.c:1366-1424), so every quad
/// covered is shaded, as llvmpipe shades before a late test. Otherwise the
/// tests are made in the walk and the depth alone waits, written for the
/// pixels left as the other ways of drawing already wrote it
/// (lp_state_fs.c:1426-1440). At four samples a pixel the same, a sample
/// at a time. A draw that drops nothing is drawn as before.
///
/// Found while porting K4 of item 61, whose alpha to coverage drops
/// samples the same way. The new test draws the cut-out over a slanted
/// triangle at one sample and at four: a stencil replaced, one inverted
/// where its test fails, one failed and never written, one written only
/// by the face not seen, and the depth clamp alone; and a form that drops
/// nothing under the inverting test, which is still tested in the walk.
/// It reads back every sample's colour, depth and stencil, and the
/// fragment invocations, which tell a test made late from one made in
/// the walk. The front's test would zero the stencil, which tells the
/// faces apart. K3's test of four samples' depths takes its cut-out
/// texture from a helper the two now share. Against 1.106 the new test
/// fails: a dropped pixel's stencil was 0x10, not the clear's 0x03. Each
/// of 19 changes put back fails it.
///
/// 108: **Alpha to coverage on the cores, dithered as lavapipe dithers
/// it.** Step K4 of item 61 of docs/facet-vulkan10.md.
///
/// `alpha_to_coverage_enable` has no feature in Vulkan 1.0, which has
/// every implementation do it, and CreateGraphicsPipelines refused it on
/// every device until now. The cores take it, at one sample a pixel and
/// at four. After the fragment function, colour 0's alpha less a
/// threshold of a 2 x 2 ordered dither by the pixel's place on the
/// surface - 1/8, 5/8, 7/8 or 3/8 of one sample's share
/// (lp_state_fs.c:408-444) - keeps sample s of n where it is above s / n
/// (:447-474, :1207-1211), and at one sample the pixel where it is above 0
/// (lp_bld_blend.c:342-365, lp_state_fs.c:1193-1197). lavapipe always
/// dithers (lvp_execute.c:1139-1142). The function writes an 8-bit alpha,
/// so the test is made in integers: 8na > 255k + 2040s, k the threshold
/// in eighths, which no alpha ties. lavapipe compares the shader's alpha
/// as a float, so one within half an 8-bit step of a threshold may fall
/// the other way here; Vulkan specifies no algorithm for it. A draw with
/// it holds its depths back, and tests late beside a stencil test that
/// writes, as a form that drops pixels does since 1.107
/// (lp_state_fs.c:772-776), and goes without the depth pre-pass. The V3D
/// refuses it until V6.
///
/// Tests: bands of eight alphas over a frame of four samples a pixel and
/// six over one of one, the render area a row down so that the quads'
/// rows start odd on the surface. Each sample's colour, depth and stencil
/// is held to the samples kept, worked out by hand for each alpha and
/// place, under a depth alone that asks for the depth pre-pass and under
/// a stencil test that writes, and an occlusion query to their count.
/// The multisample test takes alpha to coverage and keeps it with the
/// pipeline, where it refused it. Each of fifteen changes put back fails
/// one of them.
///
/// 109: **The cores resolve a colour of four samples into its resolve
/// attachment as the subpass ends.** Step K5 of item 61 of
/// docs/facet-vulkan10.md. No device draws four samples yet: the
/// capability stays off until K7, and the tests turn it on.
///
/// lavapipe blits the multisampled image into the resolve attachment over
/// the render area, in every layer of the framebuffer, as the rendering
/// ends (`resolve_color`, lvp_execute.c:1782-1827, from
/// `handle_end_rendering`, :2053), and v3dv resolves a tile at a time in
/// its tile buffer, before the multisampled store
/// (v3dvx_cmd_buffer.c:640-686). Here each tile, once its samples are
/// stored, has them averaged into the resolve over its part of the render
/// area, as the surface now holds them (`raster.resolveSurface`), while
/// their rows are still in the part's cache: a pass's resolve is
/// CmdResolveImage's average to the byte, a 565 sample's dither and all.
/// The two averages of 1.101 move into the raster module for it, which
/// v3d.fdriver now imports, its CmdResolveImage being the cores' until V5.
/// Where a colour is resolved, every tile of the area is drawn: one the
/// pass loads and draws nothing into is resolved all the same, from what
/// it loaded. The framebuffer's layers past the first, which no tile
/// reaches, are resolved from the image's rows as the part ends. The tiles
/// of a colour resolved into a swapchain's image are handed on to its
/// display (`_play.displayOf`).
///
/// Tests: a pass of four samples in 8888 and in 565, over two layers of
/// four tiles, its render area short of the framebuffer on every side and
/// its resolve's image larger than the framebuffer, at another pitch.
/// Cleared and drawn, then loaded from samples marked by hand and drawn
/// into the first tile alone: in both layers each pixel of the area is
/// the average of its four samples as the pass stored them, the three
/// tiles nothing drew into resolved from what they loaded, and nothing
/// past the area written. Three colours drawn together, the first without
/// a resolve and the others with one each, against each sample's
/// coverage. A surface resolved alone: cut to both surfaces, and nothing
/// given to one of another format. And the display the tiles are handed
/// on to. Each of nineteen changes put back fails one of them.
///
/// 110: **A fragment function fetches each sample of an image of four
/// samples a pixel, where the image lies.** Step K6 of item 61 of
/// docs/facet-vulkan10.md. No device draws four samples yet: the
/// capability stays off until K7, and the tests turn it on.
///
/// llvmpipe samples a texture of several samples where it lies, its
/// sample count kept where its fetch holds a sample number to it and its
/// stride beside the levels' offsets (`lp_jit_texture`, lp_jit.c:399-404).
/// The fetch adds the stride times the sample to a texel's offset, and
/// reads zero for a sample past the count (`lp_build_sample_ms_offset`,
/// lp_bld_sample_soa.c:2170-2187, :2985, :3166-3181), as a map of one
/// sample adds it (lp_texture.c:1087); lavapipe's sampler view of a
/// multisampled image is that same resource (lvp_image.c:87-89, :104).
/// Here a texture has `samples` and `sample_bytes` (sdk.facet.texture),
/// and `Texture.sampleOf` gives one sample as a texture of one: a sample
/// past the last is a texture of no layers, every texel of which reads
/// transparent black and takes nothing written. A colour image of four
/// samples that is sampled is kept in rows, as one drawn into is, and its
/// rows are the texture (`_image.sampledRows`): R8G8B8A8's four bytes read
/// as they lie by a texture format of their own, `texture.Format.rgba8`,
/// B8G8R8A8's word as `argb8888` and R5G6B5 as `rgb565`. A depth
/// attachment's planes, sampled where they lie since 1.39, carry their
/// samples the same way. Not a colour attachment as well, against the
/// first plan: one sample of that is not made (item 48), so the format
/// query refuses the usage, and Vulkan has its sample counts hold the 1
/// wherever they hold the 4. With the capability the query says 1 and 4
/// for a sampled image of each format an attachment is drawn in, as
/// `sampledImageColorSampleCounts` and `sampledImageDepthSampleCounts`
/// ask.
///
/// Tests: a texture of four samples over planes of two layers, each
/// sample's texel a plane further on, a sample past the last reading
/// transparent black by every read and taking nothing written, and
/// R8G8B8A8's bytes read and written in their order. An image of four
/// samples in each colour format an attachment is drawn in, its samples
/// marked by hand in an image a pass draws into and copied into the one
/// sampled, and a depth and stencil image's two planes marked by hand:
/// each fetched at every pixel by a fragment function, four samples into
/// four attachments drawn together, through a view of one layer and one
/// of two, from the first sample and from the second, the last attachment
/// then given the sample past the last. CreateImage takes a sampled image
/// of four samples in rows, four times an attachment's bytes, and refuses
/// it as a colour attachment, an input attachment or a storage image as
/// well; the format query says 4 for it. Each of 24 changes put back
/// fails one of them.
///
/// 111: **An input attachment of four samples a pixel is read a sample at
/// a time.** Step K6b of item 61 of docs/facet-vulkan10.md, which the
/// plan did not have: it kept such an input attachment refused, and
/// CreateRenderPass refused one with `error_feature_not_present`. Vulkan
/// 1.0 reads one through `subpassInputMS` with no feature to refuse it
/// under - SPIR-V's InputAttachment capability, StorageImageMultisample
/// exempting SubpassData - and vkCreateRenderPass has no such error to
/// give, so a device reporting four samples has to read them. No device
/// draws four samples yet: the capability stays off until K7, and the
/// tests turn it on.
///
/// lavapipe makes every subpass load, of one sample or of several, an
/// image load at the fragment's place, the sample number passed on
/// (`try_lower_input_load`, lvp_nir_lower_input_attachments.c:49-86, the
/// sample at :75), and llvmpipe's image load adds the sample times its
/// stride to the texel's offset, reading nothing for a sample past the
/// count (`lp_build_img_op_soa`, lp_bld_sample_soa.c:4839, :4941-4956;
/// `lp_build_sample_ms_offset`, :2170-2187). Here an attachment has
/// `samples`, `sample_bytes` and `others`, where its second sample begins
/// (sdk.facet.shader.Attachment), and `Attachment.sampleOf` gives one
/// sample as an attachment of one, a sample past the last reading
/// transparent black. A view of a colour image of four samples kept in
/// rows hands on each sample's rows a plane after the one before, and a
/// depth attachment's planes do the same (`_image.depthRows`); a subpass
/// that reads what it draws is given the tile, whose samples past the
/// first lie in planes of their own (`Tile.samplePlane`). No sample count
/// ties an input attachment to its subpass, as Vulkan has none: a subpass
/// of one sample reads one of four, which is how Vulkan's conformance
/// tests read an attachment of several samples back.
///
/// Tests: an attachment of four samples, sample 0 where it begins and the
/// others where it says, one past the last reading transparent black,
/// and one of one sample itself. A colour image of four samples in each
/// format an attachment is drawn in, marked by hand, loaded and painted
/// in two samples under a sample mask by one subpass, and a depth and
/// stencil one whose depth and stencil two samples are written in: read
/// by the next subpass, of one sample, a sample into each of four
/// attachments drawn together, from the first sample and from the
/// second, the last attachment then given the sample past the last; the
/// descriptor's attachment holds every sample's rows. A subpass of four
/// samples over four tiles reading what it draws, each sample of the
/// fragment's own pixel as the tile loaded it put into all four.
/// CreateRenderPass takes an input attachment of four samples. Each of
/// 15 changes put back fails one of them.
///
/// 112: **The cores draw four samples a pixel.** Step K7 of item 61 of
/// docs/facet-vulkan10.md: `Capabilities.multisampling` is the cores',
/// which K1 to K6b drew four samples with in the tests alone, the tests
/// turning it on. So the three framebuffer sample-count masks and the
/// colour, depth and stencil sampled-image masks say one sample and four,
/// as lavapipe's do on the same cores (`LVP_SAMPLE_COUNTS`,
/// lvp_device.c:81-82, :1072-1081, with eight beside them, which this
/// library does not draw), and the format query, CreateImage,
/// CreateRenderPass and CreateGraphicsPipelines take four where those
/// masks say it. Six of the seven rows Vulkan 1.0's limits still had
/// against the cores are met; the seventh, the no-attachments mask, waits
/// on a subpass with no attachments (item 43, then K8). The integer and
/// the storage sampled-image masks keep one sample, all Vulkan asks of
/// them while `shader_storage_image_multisample` is false.
/// `standardSampleLocations` stays true: the cores' four places are
/// Vulkan's (raster/setup.zig `sampleOffsets`), as lavapipe says of its
/// own (lvp_device.c:1094). The V3D does not draw four until V5.
///
/// Tests: the cores say they draw four, and their masks hold one sample
/// and four in the six rows and one in the other three, at the standard
/// places; described again without the capability, one in every row.
/// Their format query says one and four for a sampled image and a colour
/// attachment, and where it says four, the bytes of its largest image
/// are the larger of the largest image of one sample and of four, each
/// made: a sampled colour image of four is kept in rows, a word a pixel
/// in each sample's plane, and one of one in a texture of two words a
/// texel. CreateImage refuses two samples and eight, and CreateRenderPass
/// takes an attachment of four, refuses two and eight, and refuses four
/// beside a depth attachment of one. Without the capability the cores
/// make no image of four and
/// refuse a render pass and a pipeline of four. Every test that drew four
/// asks the cores for the capability instead of turning it on. The limits
/// test's pin is 1. The capability taken back fails 23 of them, and
/// each of six other changes fails one of them.
///
/// 113: **A subpass with no colour attachment.** The cores' half of item
/// 43 of docs/facet-vulkan10.md: CreateRenderPass took a subpass of one to
/// four colour attachments, so the shadow map's pass - a depth attachment
/// alone - and the depth pre-pass as Vulkan writes it could not be
/// described, though Vulkan 1.0 has no feature to refuse them under. It
/// takes none now on a device that draws such a subpass
/// (`Capabilities.colorless_subpasses`, the cores'): the one part, of no
/// colour, with a depth or with no attachment at all. The port is
/// lavapipe's and llvmpipe's: lavapipe hands llvmpipe a framebuffer of no
/// colour buffers (lvp_execute.c:1974-1980), whose tiles map none
/// (lp_rast.c:126-131) and whose blending loops over none
/// (lp_state_fs.c:3618-3622). So the cores' tiles load and store no
/// colour plane, a batch blends into none, and the fragment function
/// still has its one colour's room, which goes nowhere; an entry of
/// several colours is refused there, as in a subpass of one. Where the
/// code took a first colour for granted it no longer does: the grid's
/// alignment to a surface's lines, the display a part hands its tiles
/// on to, two loops from 1 to the colour count, and the viewport of
/// CmdClearAttachments' quad. A subpass of no attachment at all is drawn
/// over its render area at one sample a pixel, so the no-attachments
/// mask keeps the 1 bit alone until item 61's K8.
/// `FramebufferCreateInfo.attachments` is optional, as Vulkan's is, for a
/// framebuffer of no views, and a framebuffer's size is held to the
/// device's `max_framebuffer_width` and `max_framebuffer_height`
/// (VUID-VkFramebufferCreateInfo-width-00886, -height-00888), which no
/// image bounds where there are none. The V3D refuses the subpass until
/// v3dv's unused render target is ported (v3dvx_cmd_buffer.c:1189-1197).
///
/// Tests: the cores say they draw it; CreateRenderPass makes a subpass of
/// the depth alone the one part, of no colour, makes two of them in a row
/// the second going on in the first's tiles, and refuses one without the
/// capability; a subpass of no attachment is the eighth part after seven
/// of colour, and refused as a ninth. A shadow map's pass: its depth drawn, a corner of it
/// cleared in the middle of the pass, stored and read back; its function
/// called and told of the one colour it writes, and an entry of three
/// colours refused. The same at four samples a pixel, each sample's depth
/// where the triangle covers it. A depth pre-pass as Vulkan writes it: a
/// subpass of colour tested against what the one of the depth alone
/// left, the green that one drew in nowhere. A subpass of no attachment
/// at all: its framebuffer of no views made, one past either of the
/// device's sizes refused, as is a null for a pass of one view, and an
/// occlusion query counting the pixels of a render area away from the
/// framebuffer's corner and none outside it. Each of 17 changes put back
/// fails at least one of them. The blend skipped where there is no
/// colour is not among them: it saves work and changes nothing a test
/// can see.
///
/// 114: **A subpass of no attachment at four samples a pixel.** Item 61's
/// K8 of docs/facet-vulkan10.md, its last row on the cores: such a
/// subpass has no count of its own and draws at its pipelines', one of
/// `framebuffer_no_attachments_sample_counts` (Vulkan's "rules for a
/// zero-attachment subpass", VUID-VkGraphicsPipelineCreateInfo-subpass-00758),
/// and that mask held the 1 bit alone in 1.113. CreateGraphicsPipelines
/// takes a pipeline of four for a subpass of no attachment, and of no
/// other count than its attachments' for any other subpass. The port is
/// v3dv's: it starts a subpass's frame at one sample where no attachment
/// says otherwise and, before the first draw of a pipeline of four,
/// starts it again with MSAA (`cmd_buffer_restart_job_for_msaa_if_needed`,
/// v3dv_cmd_buffer.c:2655-2730, guarded by the job's `draw_count`, which
/// is counted at 2912). So the cores' first draw in such a subpass lays
/// its tiles again at four and begins the frame again, and the frame
/// counts its draws (`Stats.draws`). A pipeline of another count after
/// the first draw, which Vulkan does not allow while
/// `variable_multisample_rate` is off (VUID-vkCmdBindPipeline-pipeline-00781),
/// draws at the first's, as v3dv's does. The tiles are laid again over
/// no surface, so a pipeline of four bound in a subpass of an attachment
/// of one, which Vulkan does not allow either
/// (VUID-vkCmdDraw-renderPass-02684), draws at the attachment's count.
/// The no-attachments mask holds the 4 bit on a device with
/// `can.colorless_subpasses` that draws four, so the cores meet all of
/// Vulkan's 106 limits and the limits test's pin is 0. The V3D keeps the
/// 1 bit until item 43's V3D half and item 61's V8.
///
/// Tests: the cores say the 4 bit, and say the 1 bit alone described
/// without `colorless_subpasses`, as the V3D is; the limits test's pin is
/// 0. A subpass of no attachment at all takes a pipeline of four and one
/// of one; an occlusion query counts every sample a triangle in eighths
/// of a pixel covers at four, every pixel whose centre it covers at one,
/// and at four again after a pass of one. Two pipelines of different
/// counts in one subpass count at the first's, in either order. Over a
/// colour, a depth and a stencil attachment of one sample, a pipeline of
/// four is refused, and bound all the same draws at one: the colour
/// drawn at the triangle's centres, and each counting them. Each of
/// 14 changes put back fails at least one of them.
///
/// 115: **A pipeline of no fragment stage.** The cores' half of item 85
/// of docs/facet-vulkan10.md: CreateGraphicsPipelines refused a pipeline
/// without a fragment stage, though Vulkan 1.0 asks for a vertex stage
/// alone (VUID-VkGraphicsPipelineCreateInfo-stage-02096), and the shadow
/// map's pipeline - a depth drawn, no colour - is the program that leaves
/// it out. The port is lavapipe's: it binds `noop_fs`, a fragment shader
/// of no instructions built once for the device (lvp_device.c:2048-2052),
/// where a pipeline has none (lvp_execute.c:552-554). Here that is
/// `noFragment`, a function that writes nothing and drops no pixel, and
/// no varyings are checked against it. Vulkan leaves what lands in a
/// colour attachment undefined; llvmpipe blends a colour store it never
/// writes (lp_state_fs.c:826-832), and here each colour attachment's write
/// mask is 0, so it keeps what it held. The function has the room of as
/// many colours as the subpass draws together. Alpha to coverage changes
/// no sample, as llvmpipe applies it only where the shader writes colour 0
/// (lp_state_fs.c:1181-1185). The V3D refuses such a pipeline, there
/// being no SPIR-V for its back end to compile, until v3dv's no-op
/// fragment shader is ported (v3dv_pipeline.c:2616-2642).
///
/// Tests: the shadow map's pass drawn by a pipeline of the vertex stage
/// alone writes the same depths as one with a fragment function, and its
/// vertex function's three varyings are taken, where a fragment function
/// of none beside them is refused. Over two colour attachments drawn
/// together, each keeps its clear while an occlusion query counts every
/// pixel drawn. With alpha to coverage at four samples, a function's alpha
/// of 0 covers no sample and no function leaves every sample the triangle
/// covers. Each of 5 changes put back fails at least one of them.
///
/// 116: **A subpass drawn a part for each colour attachment, played the
/// same way in each.** Item 87 of docs/facet-vulkan10.md, found by a
/// test while scoping item 86. Without `SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER`
/// a subpass of several colour attachments is a part for each, its
/// commands played again from its begin for each part (item 80), and two
/// things the replay did were not what the subpass does once. Every part
/// wrote back a depth or a stencil the subpass loads and stores, so the
/// parts after the first read in what the first had left and tested
/// against that: a quad under a LESS test over a depth cleared to the
/// furthest left every colour attachment past the first as it was
/// cleared, and a stencil test of what the subpass began with did the
/// same. Only the last part writes them back now, so each reads in what
/// the subpass began with and they all leave the same, which a later
/// subpass reading the depth from the last part (1.52) already assumed.
/// The plan is both devices', so the V3D's parts follow it. And a query
/// counted each draw once for each part: an occlusion query read twice
/// the samples that passed, a statistics query twice the vertices. A
/// draw counts in the first part alone now, and on the V3D the frames of
/// the parts after it leave the hardware's counter stopped, as a frame
/// with no query does (`tallyFor`; unchecked on the board). Mesa has no
/// such replay to port: llvmpipe maps a tile of every colour buffer as
/// the tile begins and shades it once for all of them
/// (`lp_rast_tile_begin`, lp_rast.c:107-137), so a draw is tested and
/// counted once (`vis_counter`, lp_rast.c:123 and 635-675). The replay is
/// facet's until item 80 on the cores and item 55 on the V3D.
///
/// Tests: over a depth of `d16_unorm` and a stencil of `s8_uint`, each
/// loaded and stored, a subpass of two colour attachments apart is two
/// parts that both read the plane in and of which the last alone writes
/// it back; a quad drawn nearer than the depth, or where the stencil is
/// 0 and counting it up, colours both attachments everywhere, and leaves
/// its depth, or the stencil counted up once. Over the same two
/// attachments, an occlusion query over the pass and one inside its
/// subpass each count every pixel once, and a statistics query six
/// vertices given, six shaded and two triangles clipped. Each of 5
/// changes put back fails at least one of them.
///
/// 117: **An occlusion query and a statistics query, counted at once.**
/// Item 88 of docs/facet-vulkan10.md, found with item 87. Vulkan lets a
/// query of each type be active together and no two of one type
/// (VUID-vkCmdBeginQuery-queryPool-01922), so an occlusion query and a
/// pipeline-statistics query may be begun one after the other. The cores'
/// player kept one query, and CmdBeginQuery replaced it: an occlusion
/// query begun before a statistics query counted nothing after that.
/// The port is llvmpipe's list of every query begun, each binned into
/// every tile (`active_queries`, lp_setup.c:1475-1483, taken out at
/// 1564-1577), here a place for each type that counts
/// (`_queries.Active`), with a draw and a dispatch adding to the counters
/// of both. CmdEndQuery takes out the one it ends and leaves the other
/// counting. The V3D has occlusion pools alone, its statistics pools
/// being refused, so one is all it can have.
///
/// Tests: an occlusion query and a statistics query begun one after the
/// other, and ended one after the other, around two passes of a triangle
/// with one of them ended between: the one begun second and ended first
/// counts the one pass, the other both, either way round. Each of 6
/// changes put back fails it.
///
/// 118: **A colour reference of ATTACHMENT_UNUSED.** Item 86 of
/// docs/facet-vulkan10.md, found while doing item 43. Vulkan 1.0 lets a
/// subpass's colour attachment be ATTACHMENT_UNUSED: what the fragment
/// shader writes at that location is discarded, and the locations after
/// it keep their attachments. CreateRenderPass refused it as an
/// attachment past the last. Mesa's render pass gives such a reference
/// no image view (vk_render_pass.c:1924-1930), and lavapipe gives it no
/// colour buffer (lvp_execute.c:1984-1999). Here, a subpass drawn a part
/// for each colour attachment, the way every Vulkan program's is, has no
/// part for it. Each part carries the location of its colour
/// (`Part.output`), which the fragment function writes, which picks its
/// blend state and the clear CmdClearAttachments names, and at which its
/// target says it has no alpha. The last was set at the first place and
/// read at the part's number, so a part past the first over an
/// `r5g6b5_unorm_pack16` attachment blended by an alpha it has not got;
/// it is set at the location now. A query counts the first part by its
/// number (`player.part`). The blend state is held to the subpass's
/// colours as Vulkan counts them, the unused ones too (`Subpass.color_count`,
/// VUID-VkGraphicsPipelineCreateInfo-renderPass-07609). A subpass whose
/// every colour is unused is drawn as a subpass of none. One whose colours
/// go together refuses an unused one, a plane of the tiles with no image
/// behind it being nothing the target has yet (item 80), and a resolve
/// attachment for an unused colour is refused
/// (VUID-VkSubpassDescription-pResolveAttachments-00847). The V3D reads a
/// part's location the same way; unchecked on the board.
///
/// Tests: three colour references, the second unused, are two parts at
/// locations 0 and 2, taking three blend states and refusing two. A
/// left-half quad colours the first attachment at location 0 and the
/// second by the third blend state. Each keeps its own clear over the
/// right half. A clear of location 1 changes nothing, and one of location
/// 2 clears the second attachment alone. An occlusion query counts the
/// draw once. Two unused references over a depth are one part of no
/// colour that keeps the quad's depth, its pipeline taking two blend
/// states. An unused reference drawn together, a resolve for one, and a
/// reference past the attachments are refused. Past an unused reference,
/// the one part over a 565 attachment blends a destination alpha of 1,
/// and its query counts both draws. Each of 12 changes put back
/// fails at least one of them.
///
/// 119: **An image drawn into and sampled, on the cores.** The cores' half
/// of item 48 of docs/facet-vulkan10.md. Vulkan requires B8G8R8A8 and
/// R8G8B8A8 to be drawn into and sampled in optimal tiling, and has no way
/// to refuse the two together; CreateImage refused an image of both, so a
/// program drew into rows and copied them into a texture, a copy no Vulkan
/// program makes. Mesa renders into a texture's own memory: llvmpipe lays a
/// texture out one way whatever it is bound as (`llvmpipe_texture_layout`,
/// lp_texture.c:154-223), its rasteriser writes the level and the layer a
/// surface names (`init_scene_texture`, lp_scene.c:159-185), and its
/// sampler reads the same bytes. Here an image made SAMPLED beside
/// COLOR_ATTACHMENT or INPUT_ATTACHMENT, of one sample or four, is kept in
/// rows and sampled where it lies (`_image.sampledRows`), as a sampled
/// depth and a sampled image of four samples already were. Every rows image
/// in optimal tiling may have levels now, the whole chain, laid out as
/// depth's levels have been since 1.63, and the format query says so:
/// Vulkan's `maxMipLevels` is the whole chain for every optimal image
/// whatever its usage, and the query answered 1 for a colour attachment.
/// `_image.depthPitch`, `depthLevelBytes` and `depthLevelAt` are
/// `levelPitch`, `levelBytes` and `levelAt` for that reason, and
/// `rowLayers` is `rowLevels`. A pass draws into its view's level and layer
/// (`_play.zig` `surfaceAt`, which a resolve attachment's goes through as
/// well), a copy, a blit and a clear reach the level they name
/// (`_transfer.zig` `spanOf`), a framebuffer is held to its attachments'
/// levels, and an input attachment's view holds its level's rows. A texture
/// kept in rows is not read in blocks by a fixed form compiled for its
/// format: it is drawn through the run-time sampler (`shader.textured`).
/// The V3D refuses such an image, its images lying in a layout of its own
/// (`Ops.texture_memory`), and the format query there says so; its half is
/// v3dv's store and load of the UIF layout and its TLB clear.
///
/// Tests: on a 32 x 32 image of three levels and two layers, of each of the
/// three formats, a clear of every level and layer, a pass drawing into
/// level 1 of layer 1 through a view of it, and a blit of that level into
/// level 2 leave each in its own rows, a sampler reads each level back at
/// its lod, and the fixed form reads the level its view names. Four samples
/// resolved into level 1 of the other layer fill that level's rows alone,
/// and the view of it holds them, at their own pitch, for an input
/// attachment. A framebuffer wider than the level, its colour attachment's
/// or its resolve attachment's, is refused. The format query answers the
/// whole chain of levels for a colour attachment, sampled or not, and
/// CreateImage takes them and refuses one level more; on a device of a
/// layout of its own both refuse. Each of 14 changes put back fails at
/// least one of them.
///
/// 120: **An image view's component swizzle.** Item 41 of
/// docs/facet-vulkan10.md. Vulkan 1.0 lets every view take any of its
/// seven sources in each of the four channels, with no feature or limit
/// gating it; CreateImageView refused all but the identity. lavapipe hands
/// the view's four to the sampler view (`lvp_create_samplerview`,
/// lvp_image.c:379-382) and llvmpipe swizzles each sample once it is made
/// (`apply_sampler_swizzle`, lp_bld_sample_soa.c:3954-3956). Here a
/// texture carries the view's swizzle (`texture.Swizzle`,
/// `Texture.swizzle`), and every read of a texel applies it: a sample by a
/// sampler or by a fixed form's sampling, `colorAt`, `partsAt` and
/// `wholesAt`. It is applied to each texel as it is read rather than once
/// a sample is made, which comes to the same, a channel taken or a
/// constant being mixed alike before a filter or after it. The border and
/// what a comparison gave are swizzled as well, Vulkan replacing a texel
/// and comparing a depth before it swizzles, and a comparison reads the
/// texel as it lies (`readColor`). The fixed form's fast path reads
/// texels as they lie, so a view that swizzles goes through the run-time
/// sampler, as llvmpipe's linear path takes no swizzle
/// (`lp_linear_check_sampler`, lp_linear_sampler.c:918-924). A swizzle of
/// a depth takes 0 from the green and the blue and 1 from the alpha,
/// lavapipe's `conv_depth_swiz` (lvp_image.c:337-347, 389-396); a view of
/// one that swizzles nothing keeps the grey a depth reads as, where Vulkan
/// reads (D, 0, 0, 1), which is item 89, found here. The V3D's TMU takes
/// the view's four over the format's own, v3dv's
/// `util_format_compose_swizzles` (v3dv_image.c:828-831) packed into the
/// texture shader state (`pack_texture_shader_state_helper`,
/// v3dvx_image.c:72-75), in `tiling.writeTextureState`; unchecked on the
/// board. A framebuffer refuses a view that swizzles
/// (VUID-VkFramebufferCreateInfo-pAttachments-00884). A storage image and
/// an input attachment may not be one
/// (VUID-VkWriteDescriptorSet-descriptorType-00336), which is left to the
/// program, UpdateDescriptorSets having no result to refuse with. A value
/// that is none of the seven is refused as before.
///
/// Tests: each of the seven sources in each channel is taken, and a value
/// past them refused. A view that takes red from the blue, green from
/// zero, blue from one and alpha from the red reads its texels so through
/// `colorAt`, `partsAt` and `wholesAt`, a texel it does not hold reads the
/// swizzled zero, a sampler reads it nearest and mixed, its border and a
/// 3D texture's past its last slice swizzled too, and a comparison reads
/// its red as it lies. A fixed form of the texture's own format draws it
/// swizzled, through the run-time sampler, where the plain view takes the
/// fast path. A depth's view of one, red, green and alpha resolves to one,
/// red, zero and one, and its comparisons - always, never, and greater and
/// less than a depth of a quarter, nearest and mixed - compare the depth
/// as it lies and read swizzled. A
/// framebuffer refuses a view that swaps red and blue and takes one whose
/// swizzle is given as the identity's own sources. The V3D's texture state
/// packs the composed four, for a format of its own swizzle and for one
/// without, and the board probe draws a swizzled view. Each of 20
/// changes put back fails at least one of them.
///
/// 121: **A depth and a stencil read as Vulkan reads them.** Item 89 of
/// docs/facet-vulkan10.md, found while doing item 41. A sample of a depth
/// that does not compare read it as an opaque grey, (D, D, D, 1), and so
/// did a fixed form's and a generated shader's; Vulkan converts the texel
/// by "(0,0,0,1) for missing (R,G,B,A) components" (13.2.2), so it reads
/// (D, 0, 0, 1). llvmpipe reads a depth or a stencil as the grey this
/// library does, "Correct swizzling will be handled by
/// apply_sampler_swizzle() later" (`lp_build_format_swizzle_soa`,
/// lp_bld_format_soa.c:82-101), and lavapipe turns the swizzle of every
/// view of one, the identity's too, so that the green and the blue read 0
/// and the alpha 1 (`conv_depth_swiz`, lvp_image.c:337-347, 389-396).
/// Here the texels of every view of a depth or a stencil take that rule
/// (`createimageview.zig` `depthRead`), where 1.120 gave it only to a view
/// that swizzles. So such a view reads (D, 0, 0, 1) through a sampler, a
/// fixed form, `colorAt` and `partsAt`, what a comparison gave stands in
/// the D, (1, 0, 0, 1) for a pass and (0, 0, 0, 1) for a fail, and a texel
/// it does not hold reads (0, 0, 0, 1). The view itself keeps the swizzle
/// the program gave it, which a framebuffer asks to be the identity and
/// which the V3D's TMU will take over the format's own, v3dv's depth
/// formats being `SWIZ_X001` (v3dvx_formats.c:204-206); the V3D samples no
/// depth yet (item 58). The 8 bits through the colour path are every
/// format's; `partsAt` and a comparison read all 16.
///
/// Tests: of an image of a depth of a quarter and a stencil of 0x30, the
/// view of each plane that swizzles nothing reads (D, 0, 0, 1) and
/// (S, 0, 0, 1) through `colorAt` and a sampler, nearest and mixed, its
/// floats the depth at all 16 bits, a texel it does not hold (0, 0, 0, 1),
/// and a comparison (1, 0, 0, 1) where greater and (0, 0, 0, 1) where
/// less, nearest and mixed; a view that takes its alpha from the red and
/// its green from the alpha reads (D, 1, 0, D), composed over the rule; and
/// each view is still the identity. The tests that drew a sampled depth's
/// layers, levels and planes read its red alone, a shadow sample passes
/// as red rather than white, and a stencil fetched past its last sample
/// reads (0, 0, 0, 1). The board probe's shadow checks say the same. Each
/// of 6 changes put back fails at least one of them.
///
/// 122: **A query counts in 64 bits.** Item 15 of docs/facet-vulkan10.md.
/// A query's counter was 32 bits, added to atomically by every part that
/// drew tiles and held at its highest, so a result asked for in 8 bytes
/// read 0xFFFFFFFF once more samples than that had passed; Vulkan's
/// values are 64 bits, and only a 4-byte result of one too big for it may
/// "either wrap or saturate" (17.2). llvmpipe keeps a 64-bit count for
/// each of its rasterizer threads (`llvmpipe_query.start` and `end`,
/// lp_query.h:45-46), each thread adding to its own (`lp_rast_end_query`,
/// lp_rast.c:665-688), and sums them when the query is read
/// (`llvmpipe_get_query_result`, lp_query.c:122-129, 196-206). A counter
/// here is kept so: `_query.lanes` lanes of 64 bits, one for each part a
/// frame's tiles are drawn in. A batch adds what it counted to the lane of
/// the part drawing its tile (`batched.zig` `countUp`, the part from
/// `Tile.part`), the queue's task what it counts - a draw's numbers, a
/// dispatch's, the V3D's frame - to the first lane, part 0 being its own,
/// and a value is the sum of the lanes (`_query.valueAt`). No lane has two
/// writers, so none needs an atomic add, which a 32-bit machine has not
/// got for 64 bits: a lane is loaded and stored whole where the machine's
/// words are 64 bits, and a partial result read on a 32-bit one may catch
/// a lane between its two words. A 4-byte result is still held at
/// 0xFFFFFFFF. A counter takes 32 bytes of its pool, where it took 4.
///
/// batched.zig's tests had never run: the raster's tests did not name the
/// file, and a file no test names keeps its tests to itself. They run now,
/// the one already there passing as it stood.
///
/// Tests: a counter's lanes add up, one past 2^32 is read whole, and a
/// reset clears every lane; an occlusion count past 32 bits, of what each
/// part and the queue's task added, reads whole in 8 bytes and held at
/// 0xFFFFFFFF in 4; a batch's pixels and samples are counted in the lane of
/// its tile's part and in no other, at one sample a pixel and at four; and
/// a tile says which part draws it. Each of 8 changes put back fails at
/// least one of them.
///
/// 123: **FlushMappedMemoryRanges and InvalidateMappedMemoryRanges.** Item
/// 11 of docs/facet-vulkan10.md. Vulkan 1.0 has every implementation carry
/// the two, and a program written for memory that is not coherent calls
/// them; this library had neither. They are lavapipe's and v3dv's, which
/// answer `success` and look at nothing (`lvp_FlushMappedMemoryRanges` and
/// `lvp_InvalidateMappedMemoryRanges`, lvp_device.c:2390-2404;
/// `v3dv_FlushMappedMemoryRanges` and `v3dv_InvalidateMappedMemoryRanges`,
/// v3dv_device.c:2724-2738): every memory type that maps is host-coherent
/// on either device, so there is nothing to flush or invalidate, and a
/// range outside its mapping or off the atom is the program's mistake
/// (VUID-VkMappedMemoryRange-size-00685, -offset-00687), which no call has
/// to find. `FlushMappedMemoryRanges` is LVO -528,
/// `InvalidateMappedMemoryRanges` LVO -532, and `MappedMemoryRange`
/// Vulkan's VkMappedMemoryRange without sType and pNext, as every
/// structure here is until item 51, its offset 0 and its size `WHOLE_SIZE`
/// where it says nothing.
///
/// Tests: every memory type that maps is coherent and the atom is 64
/// bytes; both calls, through the library's table, answer `success` for a
/// range of two atoms and one to the end of the mapping, and leave the
/// mapped bytes as they were written. Each of 5 changes put back fails at
/// least one of them.
///
/// 124: **The three sparse calls.** Item 12 of docs/facet-vulkan10.md.
/// Vulkan 1.0 has every implementation carry
/// GetPhysicalDeviceSparseImageFormatProperties,
/// GetImageSparseMemoryRequirements and QueueBindSparse, whether or not it
/// binds memory sparsely; this library had none of them, though its
/// features and `sparse_properties` already said it binds none (1.82).
/// They are v3dv's, which binds none either: the two queries set their
/// count to 0 and write nothing
/// (`v3dv_GetPhysicalDeviceSparseImageFormatProperties`,
/// v3dv_formats.c:818-829; `v3dv_GetImageSparseMemoryRequirements`,
/// v3dv_device.c:3430-3438), which is what Vulkan has a device answer for
/// arguments without `IMAGE_CREATE_SPARSE_RESIDENCY` and for an image not
/// made with it, and the bind is refused with `error_feature_not_present`
/// (`v3dv_QueueBindSparse`, v3dv_queue.c:1170-1178), which no call a
/// program may make reaches: Vulkan has the queue be of a family with
/// `QUEUE_SPARSE_BINDING` (VUID-vkQueueBindSparse-queuetype), and none is.
/// They are LVO -536, -540 and -544. Beside them are Vulkan's sparse
/// structures - `SparseImageFormatProperties`,
/// `SparseImageMemoryRequirements`, `SparseMemoryBind`,
/// `SparseImageMemoryBind`, the three bind infos and `BindSparseInfo` -
/// with their flags and `QUEUE_SPARSE_BINDING`, the bind info without
/// sType and pNext, as every structure here is until item 51.
///
/// Tests: no family binds sparse memory and no feature says any is bound;
/// for two formats at one sample and four, and a 3D linear one, the
/// count comes back 0 and nothing is written; an image asks nothing of
/// sparse memory; a bind is refused and its fence is not signalled; and
/// the structures that carry no sType are Vulkan's sizes. Each of 6
/// changes put back fails at least one of them.
///
/// 125: **A texel buffer's offset is the limit's.** Item 79 of
/// docs/facet-vulkan10.md, found while filling the limits for item 16.
/// CreateBufferView asked a texel buffer's offset to be a multiple of the
/// format's texel size, which for the 12 bytes of three channels of 32
/// bits no power of two can say, so a program that aligned its offset to
/// the published `min_texel_buffer_offset_alignment`, 16, was refused for
/// those formats. Vulkan asks the limit alone
/// (VUID-VkBufferViewCreateInfo-offset-00926), and nothing here asks more,
/// a texel being read a byte at a time; so the offset is held to the
/// device's limit now. lavapipe and v3dv look no further at it
/// (`lvp_CreateBufferView`, lvp_image.c:785-817; `v3dv_CreateBufferView`,
/// v3dv_image.c:885-940); llvmpipe's limit is 16 too (lp_screen.c:288),
/// v3dv's the texture unit's 64 (`V3D_TMU_TEXEL_ALIGN`, v3d_limits.h:60),
/// which the V3D here will want once its texture unit reads a texel
/// buffer. A whole texel that is not a multiple of the limit, which was
/// taken, is refused, as Vulkan forbids it.
///
/// Tests: the limit is 16; for every format of the texel buffer grid a
/// view from byte 16 is made and is the whole texels past it, and for the
/// two of 12 bytes reads the words that lie there; and a whole texel short
/// of 16 is refused. Each of 4 changes put back fails at least one of them.
///
/// 126: **A blit says which formats it takes.** Item 32 of
/// docs/facet-vulkan10.md. FORMAT_FEATURE_BLIT_SRC and BLIT_DST did not
/// exist, so no format said either on either device, though CmdBlitImage
/// has been in the table since 1.16. They are set as v3dv sets them:
/// BLIT_SRC beside SAMPLED_IMAGE in optimal tiling, BLIT_DST beside
/// COLOR_ATTACHMENT in either tiling (`image_format_plane_features`,
/// src/broadcom/vulkan/v3dv_formats.c:169-182). R8_UNORM is a blit's
/// destination as well, as both of Mesa's drivers have it, and D16_UNORM
/// is blitted both ways, into an image of its own format and without a
/// filter (VUID-vkCmdBlitImage-srcImage-00231, -00232), as lavapipe has a
/// depth format (lvp_formats.c:93-104). The processor blits for both
/// devices, so the V3D's D16_UNORM says so although its texture unit
/// samples no depth. The whole numbers say neither: a blit carries a
/// colour of 8 bits a channel. That is 11 of the 47 formats Vulkan asks
/// BLIT_SRC of on the cores and 10 on the V3D, and 4 of the 38 it asks
/// BLIT_DST of on either; the rest wait on items 31, 34, 35, 36 and 37.
///
/// Setting them found three faults in what a blit reads and writes. The
/// colour of a source texel was read into 4 bytes: a texel of
/// R16G16B16A16_UNORM, 8 bytes, was not read at all and its colour made of
/// what lay in and past those 4; a texel of floats kept in rows, 8 or 16
/// bytes, was copied into them; and a float texel read as nothing even
/// where it fit, `_image.colorOfBytes` knowing no float format. It is read
/// into 16 now, and a float as a sample reads it. A blit into a depth
/// image wrote 2 bytes it never set; it moves the nearest pixel's depth
/// now, as lavapipe's blit of the depth aspect does (`handle_blit_image`,
/// src/gallium/frontends/lavapipe/lvp_execute.c:3040-3047). And a
/// compressed image kept in its blocks but made for the transfers alone
/// lay in rows with no texture laid over them, which a copy into it wrote
/// through: it is a texture whatever it is for.
///
/// Tests: of every format, each that says BLIT_SRC is made for the
/// transfers alone where CreateImage makes such an image, and sampled,
/// copied into, and blitted into 8888 as the colour a sample reads, worked
/// out by the decoders an image is unpacked through; each that says
/// BLIT_DST is blitted into in each tiling that says so and read back in
/// its own bytes; D16_UNORM is blitted into itself turned round; and no
/// whole number, stencil or linear source says a blit. Each of 10 changes
/// put back fails it.
///
/// 127: **The five formats Vulkan asks for that had no value.** Item 31 of
/// docs/facet-vulkan10.md. B4G4R4A4_UNORM_PACK16, A1R5G5B5_UNORM_PACK16
/// and A8B8G8R8_SNORM, _UINT and _SINT_PACK32 carry features Vulkan 1.0
/// asks of every device, and `facet.Format` named none of them, so a
/// program could not even ask. The three A8B8G8R8 words are the bytes of
/// the R8G8B8A8 format of the same name on a little-endian machine, as
/// the `_unorm` and `_srgb` pair already were, and each is now what its
/// R8G8B8A8 form is: the same texel buffer, the whole numbers the same
/// texture where the device keeps them, and the same features on either
/// device, as v3dv gives each pair the one texture type
/// (src/broadcom/vulkan/v3dvx_formats.c:131-134, :191-195). The two words
/// of 16 bits are unpacked into 8 bits a channel as they are copied in, on
/// every device, as ETC2 is (`_decode.texel`), each channel widened by
/// repeating its bits as R5G6B5's are: sampled, filtered, a blit's source
/// and copied into, in optimal tiling. v3dv samples both where they lie
/// (v3dvx_formats.c:187, :190), which no sampler here does. That meets
/// all B4G4R4A4 is asked and the sampled half of A1R5G5B5, whose
/// attachment half waits on item 36 with the other colour attachments,
/// and BLIT_SRC for 13 of the 47 formats on the cores and 12 on the V3D.
/// D32_SFLOAT, the sixth format the item named, is item 35's.
///
/// Tests: each A8B8G8R8 word says what its R8G8B8A8 form says on either
/// device, and the two of 16 bits say SAMPLED_IMAGE, the filter, BLIT_SRC
/// and TRANSFER_DST on either; a function sees the same of a texel-buffer
/// view of each A8B8G8R8 word as of its R8G8B8A8 form over the same
/// bytes, and something different for each of the five kinds; images of
/// the whole numbers keep R8G8B8A8's texels, copy back byte for byte,
/// clear to the numbers given, and are refused where the device keeps no
/// whole numbers; images of the two words of 16 bits are refused in
/// linear tiling and for the transfers alone, and hold the colour each
/// word is sampled as; and the blit test blits both. Each of 15 changes
/// put back fails at least one of them.
///
/// 128: **A dispatch has no more groups than it can count.** Item 29 of
/// docs/facet-vulkan10.md, the part of it that was left. maxComputeWorkGroupCount
/// said 2^32 - 1 on each axis, and a dispatch counts its groups in 64
/// bits and multiplies that count again to cut the groups into parts
/// (`_compute.dispatch`), so the largest dispatch it admitted, 2^96 groups,
/// overflowed the count: a safe build stops there, and a fast one runs
/// the wrong groups. It is 65535 on each axis now, as llvmpipe's grid has
/// it (`llvmpipe_init_compute_caps`, src/gallium/drivers/llvmpipe/
/// lp_screen.c:167-169) and the V3D's dispatcher (`V3D_MAX_CSD_WG_COUNT`,
/// src/broadcom/common/v3d_limits.h:81), which is Vulkan's floor. The
/// item's other three numbers have been there since 1.82, where the limits
/// became Vulkan's: maxFragmentInputComponents is the vertex outputs' 64,
/// maxFragmentOutputAttachments the four colours a subpass holds, and
/// maxFragmentCombinedOutputResources 0xFFFF, which is maxPerStageResources
/// and so bounds the same descriptors and colours. The V3D's 1 for each of
/// the two fragment outputs is item 55's: a QPU fragment program writes
/// one colour.
///
/// Tests: the largest dispatch the limits admit, times the parts a
/// dispatch is cut into, fits in 64 bits, beside Vulkan's floor of 65535,
/// which was held already. Putting the old number back fails it.
///
/// 129: **Events.** Item 9 of docs/facet-vulkan10.md. Vulkan 1.0 has every
/// implementation carry CreateEvent, DestroyEvent, GetEventStatus,
/// SetEvent, ResetEvent, CmdSetEvent, CmdResetEvent and CmdWaitEvents, and
/// no feature to say a device has none; the library had none of them. They
/// are LVO -548 to -576, ported from lavapipe, whose queue plays a command
/// buffer as this one does, one command after the other. An event is an
/// exec waitable, as a fence and a semaphore are (sync/_sync.zig), made
/// reset as lavapipe's is (`lvp_CreateEvent`, src/gallium/frontends/
/// lavapipe/lvp_device.c:2708-2727), set by SetEvent and reset by
/// ResetEvent at once (:2754-2772), and read by GetEventStatus, which
/// answers `event_set` or `event_reset` - the codes 1.80 added for it - and
/// `error_device_lost` once the device is lost, as v3dv's does
/// (`v3dv_GetEventStatus`, src/broadcom/vulkan/v3dv_event.c:451-459).
/// CmdSetEvent, CmdResetEvent and CmdWaitEvents are three commands of the
/// stream, which both drivers play through one function, beside the
/// barrier: the set and the reset as lavapipe's `handle_event_set2` and
/// `handle_event_reset2` (lvp_execute.c:3401-3422), and the wait as
/// `handle_wait_events2` (:3424-3433), which holds the queue until each
/// event is set and leaves it set - sleeping in WaitForAny where lavapipe
/// spins, so that a SetEvent wakes it. The work before a set is done when
/// it is played, on either device, and so is all the work before a wait.
/// CmdWaitEvents records the wait alone: the barrier Mesa's runtime
/// records after it (`vk_common_CmdWaitEvents`,
/// src/vulkan/runtime/vk_synchronization.c:307-370) is CmdPipelineBarrier's,
/// which changes nothing here, and no event at all records nothing, as
/// there.
///
/// Tests: events are made reset, and set and reset by the host and by a
/// queue's work, a secondary command buffer's too; a wait for one the
/// queue set before and one the host set before the submission lets the
/// work after it go on and leaves both set; a wait for no event records
/// nothing; and a lost device answers `error_device_lost`. Each of 15
/// changes put back fails them. C:test/FacetProbe has a queue's task wait
/// for an event the host sets only once the work is submitted, which the
/// host tests cannot: there the task that submits plays the work.
///
/// 130: **A pipeline cache's four calls.** The first half of item 10 of
/// docs/facet-vulkan10.md. Vulkan 1.0 has every implementation carry
/// CreatePipelineCache, DestroyPipelineCache, GetPipelineCacheData and
/// MergePipelineCaches; the library declared the handle, took it in both
/// pipeline calls and made none. They are LVO -580 to -592, as lavapipe has
/// them (src/gallium/frontends/lavapipe/lvp_pipeline_cache.c:26-103): a
/// cache holds no pipeline, is made from initial data it does not read and
/// merged to no effect, and GetPipelineCacheData hands out Vulkan's header
/// of 32 bytes alone, its numbers least significant byte first - its size,
/// version one, and the device's `vendor_id`, `device_id` and
/// `pipeline_cache_uuid` - with `incomplete` and nothing written where
/// there is no room for it. What it gives is a header and no pipeline, and
/// data from anywhere else leaves a cache empty in Vulkan as well, so the
/// initial data has nothing in it to take. The SDK has Vulkan's
/// PipelineCacheCreateInfo, without sType and pNext as every structure is
/// until item 51, PipelineCacheHeaderVersion and
/// PipelineCacheHeaderVersionOne. That is the cores' cache whole, as it is
/// lavapipe's. The V3D compiles a pipeline's programs since 1.76, and
/// keeping them is the item's other half, v3dv's cache.
///
/// Tests: the header is 32 bytes of the device's own numbers - set for the
/// test to the V3D's, the cores' being 0 - with nothing after it; with no
/// room for it nothing is written and the size is 0; a cache made from
/// what one gave gives the same; caches merge; and a pipeline is made with
/// one. Each of 13 changes put back fails them. C:test/FacetProbe holds
/// each device's header against its properties.
///
/// 131: **Views of another format.** The cores' half of item 42 of
/// docs/facet-vulkan10.md. Vulkan 1.0 has an image made
/// IMAGE_CREATE_MUTABLE_FORMAT take views of a format compatible with its
/// own - of the same bytes a texel for a colour format, the other of its
/// pair for a block format, none for depth or stencil - each of which
/// reads and writes the same texels its own way. The library had no such
/// flag, and CreateImageView took the image's own format alone. The SDK
/// has IMAGE_CREATE_MUTABLE_FORMAT, `1 << 3` as Vulkan has it, and a
/// view's format may be another compatible one where the image was made
/// with it. That is lavapipe's view, which hands the view's format to the
/// sampler view, the image view and the surface over the one resource
/// (`lvp_CreateImageView`, src/gallium/frontends/lavapipe/lvp_image.c:483;
/// `add_img_view_surface`, lvp_execute.c:1520-1525), llvmpipe keeping
/// every format's texels as they lie (`llvmpipe_texture_layout`,
/// src/gallium/drivers/llvmpipe/lp_texture.c:154-223).
///
/// The cores kept an 8888 texel spread over 64 bits, which no view of
/// R32_UINT can read, so an image made with the flag keeps its texels as
/// they lie: B8G8R8A8's as the word PACKED_TEXELS keeps (since 1.48),
/// R8G8B8A8's as the four bytes the rows of a sampled image of four
/// samples keep (`texture.Format.rgba8`, since 1.110), and every other
/// format as the cores keep it already. A view of another format takes
/// the same texels with a texture format of its own (`_image.readAs`), a
/// framebuffer and the cores' surfaces take the view's format, and a copy
/// moves such an image's bytes as they lie, as it does a float image's.
/// CreateImage and the format query refuse the flag where a compatible
/// format whose features take the image's usage could not be read where
/// the texels lie (`_image.shapeFor`): an R5G6B5 image to sample,
/// B4G4R4A4 being sampled and kept unpacked, and a B8G8R8A8 image both
/// drawn into and written through, whose rows have no texture to write
/// R8G8B8A8 through. A format kept unpacked refuses it too, and so does
/// the V3D, whose half is v3dv's: the texture state and the render
/// target type of the view's format (`create_image_view`,
/// src/broadcom/vulkan/v3dv_image.c:742-845, the texture type at
/// v3dvx_image.c:77), v3dv making every image MUTABLE
/// (v3dv_image.c:518-522).
///
/// Tests: an R8G8B8A8 image made with the flag keeps its bytes as they
/// lie, and views of R32_UINT, R8G8B8A8_UINT, B8G8R8A8_UNORM and
/// R16G16_UNORM read them each its own way, two of them sampled as well;
/// views of another size, of depth and stencil, and of a format whose
/// features do not take the image's usage are refused; what a view
/// writes the copies find again where it lies, a copy to an image without
/// the flag moves the colours, and a clear is the bytes of its colour; a
/// pass draws through a view of R8G8B8A8 of a B8G8R8A8 image, whose
/// framebuffer takes the view's format and not the image's, and a later
/// subpass reads the pixels as an input attachment each view's own way; a
/// block image takes a view of the other of its pair and not of another
/// pair; the format query and CreateImage agree for each format and usage
/// tried; and a device of a layout of its own refuses the flag. Each of 22
/// changes put back fails them. C:test/FacetProbe has the cores read and
/// write such an image through a storage view of R32_UINT, and a device
/// whose format query refuses the flag refuse the image as well.
///
/// 132: **CmdCopyImage between two formats of one size.** Item 90 of
/// docs/facet-vulkan10.md, found while doing item 42. Vulkan copies an
/// image into another of any format of its size - "Color formats with the
/// same texel block size are considered size-compatible", and copies are
/// made between such formats (58.1.8, which
/// VUID-vkCmdCopyImage-srcImage-01548 asks of the two) - and what it
/// copies is the bits. The cores copied some of those pairs only: none
/// where one image kept its texels as it was given them and the other not,
/// or both did in formats of their own - R8G8B8A8_UNORM into R32_UINT,
/// R16G16_UNORM into R32_SFLOAT - none between block images of two
/// formats, BC1 into BC4 among them, and none at all between a block image
/// and a texel one. Now a texel goes as the bytes a buffer holds it in,
/// which `_image.readTexel` and `writeTexel` already moved whatever the
/// format, between any two uncompressed images of one size; two block
/// images copy their blocks where the blocks are of one size; and a block
/// image and an uncompressed one whose texel is as large as its block copy
/// each block as a texel (`copyAcross`), the region's offsets each in its
/// own image's texels and its extent in the source's, as Vulkan
/// size-adjusts it (26.3). That is lavapipe's copy, which hands each one
/// to `resource_copy_region` (`handle_copy_image`,
/// src/gallium/frontends/lavapipe/lvp_execute.c:2784-2867), and llvmpipe
/// copies the bytes as they lie (`lp_resource_copy`,
/// src/gallium/drivers/llvmpipe/lp_surface.c:86-116). The V3D plays the
/// copy through the same function, and of the formats it keeps only
/// B8G8R8A8 and R8G8B8A8 are of one size, which it copied already.
///
/// Tests: R8G8B8A8_UNORM into R32_UINT and back, B8G8R8A8_UNORM into
/// R16G16_UINT, R16G16_UNORM into R32_SFLOAT and R32_UINT into R32_SFLOAT
/// each give back the bytes copied in; BC6H_UFLOAT into BC6H_SFLOAT and
/// BC1 into BC4 the blocks; BC1's four blocks become an R32G32_UINT
/// image's four texels and those another BC1 image's blocks; a column of
/// blocks, one block and one texel go where the offsets say and nothing
/// else moves; and a block into a texel of another size takes nothing.
/// Each of 12 changes put back fails them.
///
/// 133: **What breaks Vulkan's rules is `error_validation_failed`.** Item
/// 81 of docs/facet-vulkan10.md. Vulkan lists `VK_ERROR_FEATURE_NOT_PRESENT`
/// for vkCreateDevice alone, and facet answered it from a dozen other
/// calls. vk.xml has `VK_ERROR_VALIDATION_FAILED` in version 1.0's own
/// block ("Retroactively promoted from VK_EXT_debug_report for
/// compatibility with VulkanSC"), with the extension's number,
/// -1000011001, and the specification says: "Any command returning a
/// VkResult may return VK_ERROR_VALIDATION_FAILED if a violation of valid
/// usage is detected." `facet.Result` has it now, and each refusal was read
/// against the valid usage of its call. Where a VUID forbids what was asked
/// of a device that reports what this one does, the answer is
/// `error_validation_failed`; where none does, facet refuses what Vulkan
/// allows, and that keeps `error_feature_not_present` until the item that
/// takes the refusal away. Mesa's drivers look for neither and answer
/// neither, but for v3dv's QueueBindSparse, which answers
/// `VK_ERROR_FEATURE_NOT_PRESENT` (src/broadcom/vulkan/v3dv_queue.c:1172-1178),
/// a code Vulkan does not list for the call.
///
/// Moved, 35 places: a command buffer level, a buffer view of a buffer not
/// made for one, a pipeline layout past `max_bound_descriptor_sets` or
/// `max_push_constants_size`, a swapchain's usage, layers or present mode
/// that the surface has not got, QueueBindSparse on a queue that binds
/// nothing, a workgroup past the compute limits, a kind of descriptor, a
/// sampler's filter, mipmap mode, address mode, compare operation or border
/// colour, a query kind or statistic none of Vulkan's, statistics without
/// the feature; and of a pipeline, the vertex bindings, strides, attributes
/// and locations past the limits, the topologies of adjacency, a polygon
/// mode, blend factor or blend operation none of Vulkan 1.0's, a sample
/// count no subpass can have, a feature the device reports false
/// (`depth_clamp`, `depth_bounds`, `independent_blend`, `logic_op`,
/// `multi_viewport`, `dual_src_blend`, `sample_rate_shading`,
/// `alpha_to_one`), and more floats for a patch than the library carries;
/// and of a render pass, no subpass, a subpass bound to compute, more colour
/// attachments than `max_color_attachments`, a flag none of Vulkan's or
/// facet's. Kept, 39: a draw's vertex count (item 23), what the V3D has not
/// got that Vulkan requires, specialization constants, occlusion queries
/// where none are counted, a depth bias where none is taken, the render
/// pass's bounds of four subpasses and eight attachments, sample counts no
/// device draws in a render pass, depth and stencil the device does not
/// keep, a binding numbered past 255, the descriptors past what a set
/// holds, and the V3D's refusals of a pipeline.
///
/// Found while reading the VUIDs: CreateSampler refused a border colour
/// that is none of Vulkan's wherever it was given, and Vulkan asks for one
/// of its own only where an address mode clamps to the border
/// (VUID-VkSamplerCreateInfo-addressModeU-01078); elsewhere it is not
/// read, and it is taken now. And `error_initialization_failed` is
/// answered for invalid usage too, from calls Vulkan does not list it for:
/// item 91.
///
/// Tests: the 22 that expected `error_feature_not_present` of these expect
/// `error_validation_failed`; a pipeline layout of a set more than the
/// device binds, or push constants past its limit or starting past it, is
/// refused, and as many made; a query pool of a kind none of Vulkan's, and
/// of statistics on a device whose features say it counts none, is
/// refused, and occlusion queries where none are counted stay
/// `error_feature_not_present`; a render pass of five colour attachments,
/// of no subpass, or of a subpass of compute is refused, and of four made;
/// a sampler of a filter, mipmap mode or address mode none of Vulkan's, or
/// of such a border colour where an address mode clamps to it, is refused,
/// and that colour taken where none does; a pipeline of a binding or a
/// location past sixteen, of seventeen attributes, of lines with adjacency,
/// a logic op, or two viewports or none is refused; so is a swapchain of
/// two layers or of mailbox; a binding numbered 256 stays
/// `error_feature_not_present`; and the code is Vulkan's number. Each of
/// 38 changes put back fails them. C:test/FacetProbe expects the new code
/// for a workgroup over the limits.
///
/// 134: **What breaks Vulkan's rules and answered
/// `error_initialization_failed`, or a memory code, is
/// `error_validation_failed`.** The first half of item 91 of
/// docs/facet-vulkan10.md. Vulkan has `VK_ERROR_INITIALIZATION_FAILED` mean
/// "Initialization of an object could not be completed for
/// implementation-specific reasons", and of Vulkan 1.0's calls and the
/// surfaces' lists it for vkCreateInstance, vkEnumeratePhysicalDevices,
/// vkCreateDevice and vkCreateSwapchainKHR; facet answered it at 66 places,
/// most of them for what was asked wrongly. Each was read against its
/// call's valid usage, as 1.133's were.
///
/// Moved, 52 places: a command buffer ended that is not recording; a
/// command pool or a queue of a family there is not, more than one queue,
/// or two infos for one family; a descriptor pool of no sets; a binding
/// named twice; a push constant range off 4 bytes or of none; a query pool
/// of no queries, or of statistics that count none; a swapchain not of
/// the surface's size; a sampler of unnormalized coordinates beside what
/// Vulkan does not allow with them; a buffer view of a buffer without
/// memory, off its alignment, or of a range not of whole texels; of a
/// pipeline, a subpass the pass has not got, an
/// attribute of a binding not given, a tessellation state missing where
/// there are tessellation stages, or a topology or control points it does
/// not take, a patch list without them, samples other than the subpass's,
/// a stencil or depth compare operation or a stencil op none of Vulkan's, a
/// blend count other than the subpass's colours, a viewport state, or its
/// viewports or scissors, missing, and blend constants for each attachment
/// counted past the 4 colours a subpass may have, which nothing reaches;
/// of a render pass, a reference to an attachment there is not, inputs
/// that are null where they are
/// counted, attachments of one subpass of different samples, a resolve for
/// an unused colour, of one sample or into more than one or another format,
/// a colour that is the depth attachment as well or is named twice, and an
/// attachment one subpass draws as a colour and another as a depth, which
/// nothing reaches either; of a
/// framebuffer, views that do not fit its pass - another number of them,
/// none where it has some, other samples, a swizzle, an image not made for
/// the attachment or of another format, fewer layers than the
/// framebuffer - and a size or layers of none or past the device's limits.
///
/// Split, 6: three of CreateFramebuffer's, a view smaller than the size,
/// which is `error_validation_failed` for an image smaller than it and
/// `error_feature_not_present` for a level smaller than it of an image
/// that is not (item 92); a subpass reading its own depth attachment,
/// `error_validation_failed` for an attachment of a colour format and
/// `error_feature_not_present` for one of a depth format (item 92); and two
/// whose other half refused what Vulkan allows, and takes it now - a
/// colour of its own a subpass reads, `error_validation_failed` where the
/// attachment is of a depth format and drawn without a dependency on
/// itself by region where it is not, a feedback loop Vulkan leaves
/// undefined where nothing orders the write before the read, drawn as with
/// the dependency, so that subpass dependencies are not read at all
/// (`byRegion` is gone); and CreateBufferView's view of less than a texel,
/// `error_validation_failed` where its range is given, and a view of none,
/// which reads 0, for WHOLE_SIZE. To `error_feature_not_present`, 1: of
/// colours drawn together, one but the first read as an input attachment,
/// which only facet's own SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER asks for
/// (item 80). Kept, 5, causes outside the program: CreateDevice's queue
/// not started, on a call Vulkan lists the code for; and the screen's and
/// the window's libraries not opened or too old, on facet's own surface
/// calls, whose RESULT lists it where Vulkan's surface calls list no such
/// code. The screen's Screen record and its own buffer's record not had
/// are `error_out_of_host_memory` now. Gone, 2: the V3D driver's
/// AllocateMemory and fragment program held the V3D and answered the code
/// where it would not come up, which neither call lists, and no program
/// reached them - the device's queue holds it from CreateDevice to
/// DestroyDevice, and CreateDevice answers the code where it does not come
/// up. They count one more user of what the queue holds now, which cannot
/// fail, as v3dv's device works on the hardware its physical device
/// opened. Not yet run on the board.
///
/// Found while reading the VUIDs:
/// - CreateGraphicsPipelines looked at states Vulkan does not have it read
///   - the viewport, multisample, depth and colour blend states where the
///   rasterizer discards, the depth state where the subpass has no depth
///   attachment, the blend state where it has no colour one - and refused
///   one that was null or held what it did not take. They are not read
///   now, as Mesa's `vk_graphics_pipeline_state_fill` does not
///   (src/vulkan/runtime/vk_graphics_state.c:1482-1493
///   `may_have_rasterization`, :1600, :1662-1663, :1701-1702, :1841-1861);
///   a discarding pipeline has one sample, no depth test and no blend. A
///   discarding draw on the cores no longer counts as a target's first, so
///   a subpass of no attachments is laid out for the samples of the first
///   draw that rasterizes; laying the tiles again, that draw copies the
///   push constants and descriptors again, the arena a discarding draw
///   before it copied them into having started over. The V3D's driver
///   makes no program for a pipeline that draws nothing, which its draw
///   returns from before one is needed. It refused a discarding pipeline,
///   which has no fragment stage
///   (VUID-VkGraphicsPipelineCreateInfo-pStages-06894), as it refused
///   every pipeline of none; one of none that draws it refuses still,
///   until item 85's V3D half. Not yet run on the board.
/// - Arrays a count says are there were read through where null, and
///   panicked: a subpass's colours and a pipeline's blend attachments
///   (VUID-VkSubpassDescription-pColorAttachments-parameter,
///   VUID-VkPipelineColorBlendStateCreateInfo-pAttachments-07353).
/// - An attachment's samples none of Vulkan's were
///   `error_feature_not_present` (VUID-VkAttachmentDescription-samples-parameter),
///   and CreateBufferView cut a range past the buffer's end to it where a
///   texel was left there (VUID-VkBufferViewCreateInfo-offset-00931).
/// - The memory calls answered memory codes where no memory had run out:
///   CreateBuffer of size 0, AllocateMemory of a type the device has not
///   got, of no bytes or of more than the type's heap holds - which the
///   lazily allocated type, taking nothing, was made at -
///   BindBufferMemory and BindImageMemory into a type the object may not
///   be in, off its alignment, past the block's end or bound already,
///   `error_out_of_device_memory`; MapMemory of lazily allocated memory,
///   which is not HOST_VISIBLE, of a block mapped already, or of a range
///   of none or past the end, `error_memory_map_failed`; and
///   GetQueryPoolResults into fewer bytes than its results take,
///   `error_out_of_host_memory`, a stride too large for 64 bits
///   overflowing the sum it was checked with. No call answers
///   `error_memory_map_failed` now. On the V3D, AllocateMemory of a size
///   from 0xFFFF_D001 to 0xFFFF_FFFF, past its heap, overflowed the 32-bit
///   page rounding of its block and panicked; the heap's size is looked at
///   first now.
/// - GetImageMemoryRequirements offered the lazily allocated type to every
///   depth attachment that is not read; Vulkan has it offered to an image
///   made IMAGE_USAGE_TRANSIENT_ATTACHMENT alone (VkMemoryRequirements),
///   and so it is now.
/// - UpdateDescriptorSets took the sampler of a write into a binding that
///   holds samplers of its own for one, before the binding's own took its
///   place: a handle that was not a sampler's stopped the call on its
///   alignment. Vulkan does not have it read there
///   (VUID-VkWriteDescriptorSet-descriptorType-00325), and it is not.
/// - CreateSampler told a device that reads no unnormalized coordinates
///   before the rules such a sampler keeps; the rules come first.
///   Otherwise which of the two codes a call asked for both answers is not
///   promised (`Result.error_validation_failed`), and CreateFramebuffer
///   holds every view to Vulkan's rules before it answers what it cannot
///   draw.
///
/// Tests: the 62 test lines that expected `error_initialization_failed`
/// or a memory code of these expect `error_validation_failed` or
/// `error_feature_not_present`, and what no test asked before is asked
/// now: of a render pass, inputs null or past the attachments, a colour
/// that is the depth attachment or of a depth format read as an input, a
/// resolve past the attachments, 3, 0 or 128 samples, a null colour list,
/// and the second of colours drawn together read; of a pipeline, a patch
/// list without tessellation, tessellation without its state, stencil and
/// depth operations none of Vulkan's, and a viewport state or its arrays
/// missing; of a framebuffer, a resolve or a depth image smaller than it,
/// a resolve of fewer layers, and a level smaller than it answered after a
/// later view's rule; a buffer view of a buffer bound to nothing or of a
/// range of none; a command pool of another family, a descriptor pool of
/// no sets, push constant ranges off 4 bytes or of none, and two queue
/// infos; and a sampler's rules, held before the capability on a device
/// that reads no unnormalized coordinates. A subpass reading what it draws
/// is drawn alike with the dependency and without, and its own depth
/// attachment is refused as a depth and as a colour; a zero-texel
/// WHOLE_SIZE view reads 0 and a range past the end is refused; a
/// discarding pipeline is made with every other state null, and states it
/// does not read are not looked at, while a pipeline that reads them is
/// refused for them; a subpass of no attachments takes its samples from
/// the first draw that rasterizes, and the draw after a discarding one
/// reads its own push constants; memory is refused bound twice, off its
/// alignment, past its end or into a type it may not be in, allocated past
/// its heap, and mapped twice, of none or past the end; a query's results
/// are refused into too few bytes and at a stride past 64 bits; a depth
/// attachment that is not transient is not offered the lazily allocated
/// type; and a sampler a binding does not read is not looked at. Each of
/// 103 changes put back fails them: 79 at the same expectation in two runs
/// of batches, each time beside other changes, and 24 alone. No host test
/// opens a screen or runs the V3D, so the screen's records not had and the
/// V3D's pipeline that draws nothing are not among them. C:test/FacetProbe
/// expects the new code for five refusals.
///
/// 135: **What breaks Vulkan's rules and answered
/// `error_format_not_supported` is `error_validation_failed`.** The second
/// half of item 91 of docs/facet-vulkan10.md. Core Vulkan lists
/// `VK_ERROR_FORMAT_NOT_SUPPORTED` for the format queries alone, and facet
/// answered it at 23 places besides GetPhysicalDeviceImageFormatProperties,
/// which alone answers it now, for a shape there is no image of.
///
/// Moved, 22 places: CreateImageView's 16 - a format the image takes no
/// view of, a swizzle none of Vulkan's, levels or layers the image has not
/// got or none of them, a type that is none of Vulkan's or that the image
/// or the layers asked for do not take, an image not bound, and a plane
/// its format has not got; CreateRenderPass's 3, an attachment whose
/// format's features have not got what its use asks; CreateBufferView's
/// format no view takes; CreateGraphicsPipelines's attribute format; and
/// CreateSwapchain's format that is not the surface's, which is fixed as
/// the surface is made, so that nothing outside the program changes it.
///
/// Split, 1: CreateImage's. GetPhysicalDeviceImageFormatProperties asks
/// the rules CreateImage keeps (`_image.shapeFor`), so an image CreateImage
/// refuses is one that query declines
/// (VUID-VkImageCreateInfo-imageCreateMaxMipLevels-02251), one past the
/// extent, levels, layers or samples it answers (-extent-02252 to
/// -extent-02254, -mipLevels-02255, -arrayLayers-02256, -samples-02258),
/// or one VkImageCreateInfo's own rules forbid whatever it answers: a
/// side, levels or layers of 0 (-extent-00944 to -extent-00946,
/// -mipLevels-00947, -arrayLayers-00948), a cube that is not square or of
/// fewer than six layers (-flags-08865, -flags-08866), more levels than
/// its own extent's chain (-mipLevels-00958), more than one sample with
/// more than one level (-samples-02257), or TRANSIENT_ATTACHMENT beside
/// other usage or with no attachment usage (-usage-00963, -usage-00966).
/// All are `error_validation_failed` but one kind, which Vulkan allows: a
/// 3D image deeper than it is wide and high, of more levels than its width
/// and height halve to and no more than its depth does (-mipLevels-00958
/// counts the depth), which the layout here, halving the width and height
/// alone, has no levels for. It is `error_feature_not_present`, until
/// item 93 (`_image.levelsPastSides`).
///
/// Two of CreateImageView's refused what Vulkan allows, and take it now:
/// - A 3D view of one layer. A 3D image has one layer to Vulkan
///   (VUID-VkImageCreateInfo-imageType-00961), and a view's range was held
///   to the image's depth, which this library keeps as its layers: a
///   `layer_count` of 1 was refused for an image deeper than a slice, and
///   one of the whole depth, which Vulkan forbids (-imageViewType-04973),
///   taken. The range is held to the one layer, as Mesa's is
///   (`vk_image_view_init`, src/vulkan/runtime/vk_image.c:671), and the
///   view holds every slice, as v3dv's texture state is given the depth
///   of the image's first level and the view's first level apart from it
///   (src/broadcom/vulkan/v3dvx_image.c:68, :79-80).
/// - A cube array from any layer. Vulkan counts a cube array's faces from
///   `baseArrayLayer` and asks a multiple of six of the count alone, and
///   the first layer had to be one as well. The view's texture begins at
///   its first layer already, as lavapipe's does
///   (`lvp_create_samplerview`, src/gallium/frontends/lavapipe/lvp_image.c:372-375).
///
/// Found while reading the VUIDs:
/// - A 3D view from a level past the first had the whole depth's slices
///   at it, so a sample spread `r` over slices that level has not got,
///   which no copy wrote. It has the slices of its first level now, as
///   Mesa's view has the extent of its first level and is as deep as that
///   (vk_image.c:648-649, :695).
/// - TRANSIENT_ATTACHMENT was taken beside usage Vulkan does not allow
///   with it - a depth attachment's beside the transfers, a colour image's
///   beside them, SAMPLED or STORAGE - and on an image of no attachment
///   usage (VUID-VkImageCreateInfo-usage-00963, -usage-00966). CreateImage
///   refuses both. The format query declines the first; the second it
///   answers as it answers the transfers alone, which is no more strictly
///   than TRANSIENT beside a colour attachment, as Vulkan has a usage
///   within another be answered ("Additional Image Capabilities"), so
///   CreateImage asks that rule itself, and a
///   mutable image's views are asked by its attachment's feature, TRANSIENT
///   being no view's usage of its own (`_image.viewable`).
/// - CreateImageView looked at a depth image's binding and aspect only
///   where the view reads it, though its RESULT named the binding rule
///   for every image, and at a colour image's aspect not at all: a view
///   of a depth attachment never bound, of a plane its format has not
///   got, or of a depth or a stencil of a colour image was made. Each is
///   `error_validation_failed` (VUID-VkImageViewCreateInfo-image-01020,
///   -subresourceRange-09594).
///   BindImageMemory sets `memory` for the lazily allocated type too, so
///   a transient depth attachment bound there is bound, and its view made.
/// - On a device that keeps no format of both planes (`stored_both`, the
///   V3D), CreateRenderPass answered `error_feature_not_present` for a
///   d16_unorm_s8_uint depth attachment loaded, stored or kept for another
///   subpass. That device's format query gives the format no
///   DEPTH_STENCIL_ATTACHMENT, so each breaks
///   VUID-VkSubpassDescription-pDepthStencilAttachment-02650:
///   `error_validation_failed`. One that keeps neither plane is drawn in
///   the tiles, as before (docs/facet-vulkan10.md item 94). One read as an
///   input attachment after the subpass that drew it breaks
///   -pInputAttachments-02647 there and is `error_validation_failed` too,
///   on such a device that reads a depth as an input attachment; none
///   does, the V3D answering `error_feature_not_present` for any input
///   attachment, as before.
/// - S8_UINT and D16_UNORM_S8_UINT did not say SAMPLED_IMAGE, although
///   CreateImage has made either sampled since 1.58 and Vulkan has a
///   sampled image's format say it (Table 102). On a device that samples
///   a depth they say it now, and the second its depth plane's
///   FILTER_LINEAR, as lavapipe's do
///   (`lvp_physical_device_get_format_properties`,
///   src/gallium/frontends/lavapipe/lvp_formats.c:93-104).
///
/// Tests: the 57 expectations that answered error_format_not_supported here
/// expect error_validation_failed, and so do FacetProbe's five. New ones
/// ask what no test asked before - views of levels, layers, types and cube
/// arrays an image does not take, of an image not bound, of an aspect its
/// format has not got and of a format its kind does not read;
/// TRANSIENT_ATTACHMENT beside the transfers, SAMPLED or STORAGE, at four
/// samples and alone, with the format query's answer for each; a 3D image
/// of more levels than its sides give; a swapchain on a display of no
/// format facet draws in, asked for the display's own; and a kept
/// D16_UNORM_S8_UINT attachment on a device without stored_both - and check
/// the fixes: a 3D view of one layer holding every slice, and one from the
/// second level sampling that level's two slices; a cube array from the
/// third layer; S8_UINT and D16_UNORM_S8_UINT saying SAMPLED_IMAGE where a
/// depth is sampled and nowhere else. Each of 47 changes put back alone
/// fails them but two, the refusals of a sampled depth's plane and of an
/// input attachment's rows, which the binding and aspect checks before them
/// leave nothing to refuse: those are asserted now. No host test runs the
/// V3D, so its kept D16_UNORM_S8_UINT is asked of a host device without
/// stored_both. C:test/FacetProbe has not run on the board yet: the board
/// runs main's kernel, whose Task this branch's programs do not match until
/// main is merged in.
///
/// 136: **A depth or a stencil the V3D keeps through a frame that does not
/// load it is what the V3D stored.** The range of the image a frame keeps
/// its depth or its stencil in went out of the CPU's caches before the
/// frame only where the frame loads it, and was dropped from them after a
/// store. On this machine a line is dropped with a write-back first
/// (exec's CachePostDMA, `dc civac`), so a line the CPU had left dirty
/// there landed over what the V3D stored: a CmdClearDepthStencilImage,
/// which the CPU writes on this device, before a pass that clears the
/// depth and stores it read back as the clear before the pass. The range
/// goes out before every frame that keeps it now, as the colour image's
/// always has. The cores read and write their own memory, and QEMU's
/// machine sees the caches, so neither could show it.
///
/// Tests: no host test runs the V3D. On the board, after main was merged
/// into this branch, C:test/FacetProbe 1.43 failed its two checks of a
/// depth kept through a view of an image's second layer with 1.135's
/// v3d.fdriver - wanted 16384, found 65535, the clear before the pass - and
/// passes them with this one: 332 checks on the V3D and 497 on the cores,
/// none failed. It had not run on the board since 1.79.
///
/// 137: **The V3D compiles a program's own fragment shader with the back
/// end ported from Mesa.** A pipeline of no fixed form whose module ships
/// its SPIR-V was compiled by the plan (`driver/v3d/compile.zig`'s
/// `compile`), whose programs keep to 16 registers and four threads and
/// refuse what does not fit. It is compiled now as Mesa's v3d_compile does
/// it (`compile.compileThroughMesa`, `driver/v3d/compiler/`): VIR made of
/// the steps, optimized, given registers - 32 a thread at four threads,
/// and 64 at two where four do not fit - scheduled, and packed. The
/// shader record says what the compile decided, as v3dv's
/// pack_shader_state_record does: four-way threadable only for a program
/// of four threads, the real pixel centre's W where it reads it, and the
/// wait on the scoreboard at the first thread switch where it moved it
/// there. The programs are shorter - the interpolated colour nine
/// instructions where the plan's was twenty-one - and some the plan
/// refused are drawn by the V3D now. What it refuses the cores draw, as
/// before. The compiler's lists and graphs are in an arena of the calling
/// task's for the one compile, over AllocVec (`driver/v3d/heap.zig`).
///
/// Tests: the host's do not run the V3D. On the board, C:test/FacetBoth
/// 1.9's five cases of a module that ships its fragment shaders' SPIR-V -
/// an interpolated colour, a colour of its own, a colour dimmed by a
/// fifth varying, a texture, a texel times the colour - compared with
/// the cores: with 1.136's v3d.fdriver, the plan's code, and with this
/// one, Mesa's, the same counts, 8 of 230,400 pixels apart at the
/// triangles' edges for the first three and none for the textures. All
/// 160 of its cases stay within one pixel in a thousand, and
/// C:test/FacetProbe passes its 332 checks on the V3D. V3DTest MESA drew
/// the same five from the V3D's own objects first, with no pixel wrong.
///
/// 138: **The V3D compiles a fragment shader that reads the push
/// constants.** Until now the V3D's profile left out their storage class,
/// so such a pipeline was drawn by the cores. The V3D reads them as v3dv
/// does. Its lowering (lower_load_push_constant, v3dv_pipeline.c:571)
/// makes each read a uniform load. ntq_emit_load_uniform
/// (nir_to_vir.c:2880) then asks for each float as a word of the uniform
/// stream, QUNIFORM_UNIFORM at the byte offset over four. The draw writes
/// that word from the push constants the command buffer set before it, as
/// v3dv_write_uniforms does (v3dv_uniforms.c:513). The walk takes the
/// block: one struct decorated `Block`, each member a float or a vector
/// of them, each at an offset that is a multiple of four inside
/// `shader.MAX_PUSH_CONSTANTS_SIZE`. A member is read through an access
/// chain whose indexes are constants: a member, and maybe one float of
/// it. It refuses an index computed in the body, a block it cannot hold
/// and any other struct. The plan has no hand-written program to hold
/// one to and answers `Error.Storage`. `ir.Build.push` writes such a
/// shader, and the cores' function reads the floats from
/// `Resources.push`.
///
/// Tests:
///
/// - V3D tests: 129 (3 new). A colour pushed is four push words, packed
///   for the tile buffer. The tinted module compiles from glslc's words
///   and from facet's emitter to the same 13 instructions and the same
///   stream. Each kind of block the walk refuses is refused.
/// - tests/ir.zig: the emitter's words held to `min_push`, and the cores'
///   function held to the constant it should come to.
/// - spirv-check: 11 modules, `min_push` and `glslc_tinted` among them.
/// - On the board: C:test/FacetBoth 1.10 has two cases more. In one a
///   colour is pushed, drawn, then pushed again in part and drawn again.
///   In the other the vertices' colour is scaled by a pushed float and a
///   pushed colour is added. Against the cores they are 10 and 8 pixels
///   of 230,400 apart. All of those pixels are at the triangles' edges,
///   where the V3D leaves the backdrop, as in the other shipped colour
///   cases. Those five count as they did with 1.137. All 162 cases stay
///   within one pixel in a thousand. C:test/FacetProbe passes its 829
///   checks, 332 of them on the V3D.
///
/// 139: **The V3D compiles a fragment shader that drops pixels.** Until now
/// such a module was refused by the V3D's walk, `Error.Discards`, and
/// drawn by the cores. The walk takes a conditional discard in the one
/// shape it has in SPIR-V: a float compared with another
/// (`OpFOrdLessThan`, `OpFOrdGreaterThan`), then `OpSelectionMerge`, then
/// `OpBranchConditional` to a block of `OpKill` alone and to the merge
/// block the body goes on in. That shape is what nir_opt_peephole_select
/// with `discard_ok` (nir_to_vir.c:2293) makes a terminate_if of, and it
/// is ported as Mesa emits one:
///
/// - The comparison is FCMP into the flags, pushing N
///   (ntq_emit_comparison, nir_to_vir.c:1173). A greater-than is a
///   less-than with its operands swapped, as spirv_to_nir reads it.
/// - SETMSF clears the pixel's mask where the condition holds
///   (nir_to_vir.c:3833).
/// - sched_flags (nir_to_vir.c:4854) moves the flags instruction up.
/// - A program that drops pixels has no early fragment tests, so it
///   writes Z itself: the rasterizer's Z, written through to the tile
///   buffer before the colour (emit_frag_end, nir_to_vir.c:2083-2136).
/// - The shader record says so, as v3dv packs it
///   (v3dvx_pipeline.c:454-459): "Fragment shader does Z writes" and
///   "Turn off early-z test", bits 12 and 13 of the Draw Index record.
///
/// An `OpKill` anywhere else, a branch of any other shape and a bool read
/// as a float are refused. The plan answers `Error.Discards` for every
/// discard, by name.
///
/// **And the cores' depth waits for a generated function that drops
/// pixels.** The cores tested and wrote a pipeline's depth before its
/// fragment function unless its fixed form dropped pixels, and nothing in
/// a generated entry says that it does. So a dropped pixel of one kept its
/// depth and hid what was drawn behind it later. The pipeline now reads
/// that from the SPIR-V shipped beside the function (`Pipeline.discards`:
/// `spirv.look`'s `discards`, or words it could not read to the end), as
/// llvmpipe goes by `info.fs.uses_discard`. FacetBoth found it, the V3D
/// being right where the cores were not.
///
/// Tests:
///
/// - 3032 host tests.
/// - V3D tests: 132. The cutout's 13 instructions are pinned: the
///   alpha's half compared in place, SETMSF where it holds, the Z write
///   from the rasterizer before the colour. glslc's own cutout
///   (`glslc_cutout`, from `glslc -O`) compiles to the same words. The
///   other shapes are refused, and the record's two bits are pinned.
/// - tests/draw.zig's cut-out test runs for the graph that means the
///   fixed form, its words shipped: the far quad shows where the near
///   one dropped its pixels. With the cores' old line put back it fails
///   there, black where blue should be.
/// - On the board: C:test/FacetBoth 1.11 has three cases more: the
///   texture dropped where its red is under a half, where it is over,
///   and the first drawn in front of the far triangle. The first two are
///   0 pixels of 230,400 apart from the cores. The third was 20,395 apart
///   before the cores' fix, all where the V3D showed the far triangle
///   through a dropped pixel and the cores did not. It is 3 apart with
///   the fix, at the triangle's edge. All 165 cases stay within one pixel
///   in a thousand, and C:test/FacetProbe passes its 829 checks.
///
/// 140: **The V3D samples through the whole of a sampler.** Until now its
/// TMU was told a filter and a wrap, and a generated program bound beside
/// any other sampler drew `shader.missing`. That covered mixed or held
/// levels, a bias, a mirrored or bordered edge, wraps apart by axis,
/// anisotropy and texels. Now the state is packed as v3dv's
/// pack_sampler_state packs it (v3dvx_device.c:203-271), field for field,
/// at the places v3d_packet.xml:1712-1737 gives:
///
/// - the mag, min and mip filters;
/// - the S, T and R wraps, from Vulkan's five (:36-42);
/// - the three borders Vulkan 1.0 has;
/// - the fixed bias, s8.8;
/// - the minimum and maximum LOD, u4.8, held to 0-15 (:259-260);
/// - the compare function;
/// - anisotropy, 2 to 16 samples (:231-239).
///
/// Configuration parameter 1 carries the unnormalized bit, as v3dv sets
/// it from the sampler (v3dv_uniforms.c:213-218). `tiling.samplerOf`
/// makes the state from facet's own sampler. A sampler that compares is
/// the one it turns down: the TMU compares only where the program writes
/// TMUDREF (v3d_tex.c:155-157), and the walk has no Dref sample.
///
/// The V3D now reports `sampler_anisotropy` and
/// `unnormalized_coordinates` true, `max_sampler_anisotropy` 16,
/// `max_sampler_lod_bias` 14 and `mipmap_precision_bits` 8, as v3dv
/// does (v3dv_device.c:349, 1153, 1158-1159). It reports one sampler a
/// stage, beside its one sampled image. The fixed forms that read a
/// sampler are still refused there (`samplers`, item 54's other half).
///
/// Tests:
///
/// - 3036 host tests, the V3D's four new among them.
/// - V3D tests: 136 (4 new). A fixed form's state packs to the words it
///   always had. Each field of a sampler of every kind lands where
///   v3d_packet.xml has it. Anisotropy and the borders map as v3dv maps
///   them. A comparing sampler is turned down, and a wild bias or a NaN
///   stays in its field.
/// - On the board, C:test/V3DTest 0.3 FILTER draws nearest and bilinear
///   through each of the TMU's five wraps, the border white, against
///   Vulkan's formulas worked out on the CPU: no pixel wrong in any of
///   the ten.
/// - C:test/FacetBoth 1.12 draws a shipped texture through seven samplers
///   more, against the cores. Levels mixed and shifted: 1 pixel of
///   230,400 apart. Levels held to 3 and 4: none. Mirrored across and
///   held down: 16. A white border: 2. Mirrored once: none. In texels:
///   none. Four samples along an axis: none at five steps, against two
///   for every other case, because Vulkan leaves those samples to the
///   implementation (`Case.slack`).
/// - All 172 cases stay within one pixel in a thousand.
/// - C:test/FacetProbe 1.44 holds every device to a sampler in texels,
///   which Vulkan has no feature to turn off. It reads whether fixed
///   forms read a sampler off the device type, since the V3D's
///   anisotropy no longer says so. It passes its 834 checks, 337 of them
///   on the V3D.
///
/// 141: **The V3D draws the fixed forms that read a sampler.** Until now
/// it refused every form that wanted one (`samplers`), and the cores drew
/// them. Now four of the six run on the V3D: `texture_sampled`,
/// `texture_array_sampled`, `texture_cube_sampled` and
/// `texture_3d_sampled`. No new QPU program was needed. Each runs the
/// program of the form it is without a sampler. The program writes only
/// the coordinates; the sampler reaches the TMU through configuration
/// parameter 1, which v3dv writes as the draw is recorded
/// (v3dv_uniforms.c:187-221, write_tmu_p1). `textureUniforms` does the
/// same: it gives the TMU the bound sampler whole, through
/// `tiling.samplerOf` as in 1.140, in place of the form's own filter and
/// wrap.
///
/// A cube is read over its seams, and the sampler's wraps say nothing of
/// it, as Vulkan has it and as the cores have read it since 1.60. v3dv
/// packs the wraps as they are whatever the view (v3dvx_device.c:255-257),
/// and so does this. Two forms stay refused (`samplesHere`):
///
/// - `texture_shadow` compares, and the TMU compares only where the
///   program writes TMUDREF (v3d_tex.c:155-157). That is item 58's.
/// - `texture_cube_array_sampled` reads a fourth coordinate, as
///   `texture_cube_array` does, and neither has a program.
///
/// `samplers` stays false, since not every form that wants a sampler
/// runs here. Its docs and `needsSampler`'s say which do. The shader.zig
/// docs of the two cube forms said the wraps held a cube's edges. They
/// have not since 1.60, and the docs now say so.
///
/// **What the V3D's sampled forms showed, put right:**
///
/// - **A 3D texture's levels lie as v3dv lays them out.** Each slice was a
///   texture of its own, as a layer is. The TMU finds a level from level
///   0's place, counting every slice of each smaller level, so past level
///   0 it read a slice or more from where the level lay. FacetProbe's
///   level 1 read 0 where its first slice was. `tiling.layoutOf` takes
///   the depth now, as v3d_setup_slices does (v3dv_image.c:112-282): a
///   level is its slices one after another, from level 1 on as many as a
///   power of two gives (:132-134, :174-178). The texture state steps
///   from slice to slice by level 0's (:135, v3dvx_image.c:107).
///   `Ops.texture_memory` takes the depth and `texture_offset` the layer,
///   so the driver places a 3D image's slices; the library placed them
///   as layers before.
/// - **A clear of a V3D texture writes the V3D's texels where it keeps
///   them.** `clearColorImage` found a level, and made its texel, as the
///   cores keep them. The V3D's level 0 lies last, so one level of a
///   texture of levels was cleared over another's place. An 8888 texel
///   went in as the cores' 64 bits, every second word read back as a
///   texel, alpha 0. A new `Ops.texture_level` says where the level lies,
///   and the texel is the image format's, as `_image.readTexel` reads it.
/// - **A clear of a 3D image clears every slice of the level, on every
///   device.** Vulkan's range names a 3D image's one array layer.
///   `clearColorImage` took the slices for layers, so a range of one
///   layer cleared the first slice alone.
///
/// Tests:
///
/// - 3038 host tests, two new, the V3D's below among them. A clear of
///   each level of a 3D image of four slices, its range one layer, reads
///   back every slice of each level its colour.
/// - 137 V3D tests, one new: a 3D texture's levels lie as v3d_setup_slices
///   has them. Level 1's two slices come just before level 0's four, a
///   slice's bytes apart. Six slices are four at level 1, not three. A
///   texture that is not 3D lies as before.
/// - On the board, C:test/FacetBoth 1.13 has 13 cases more. The seven
///   samplers of 1.140's shipped texture are drawn again through the
///   fixed sampled form. They are as far from the cores as the shipped
///   texture is: 1, 0, 16, 2, 0, 0 and 0 pixels of 230,400. Six more go
///   through a sampler to a layer, a cube and a 3D texture:
///   - an array's levels mixed and shifted: 9 apart;
///   - past the last layer: 0;
///   - a cube's +z: 0;
///   - a cube across an edge: 14, as many as the cube without a sampler;
///   - a 3D texture bordered in white: 0;
///   - a slice held to its edges: 0.
/// - All 185 cases stay within one pixel in a thousand.
/// - C:test/FacetProbe 1.45 no longer turns the V3D's sampled forms down
///   before it asks. It expects a pipeline of the cube-array form where a
///   device draws it and a refusal where it does not, and makes a view of
///   cubes as an array only where the device has them. It reads the held
///   and wide cases through a 2D view of the cube's first face. That
///   reached 1.59's 3D texture of levels on the V3D, whose four checks
///   failed until the layout was v3dv's. Four checks are new: a clear of
///   each level of a texture of levels and of a 3D texture, each level
///   read back whole. All four failed on the V3D, alpha 0, until the
///   clear wrote its texels. FacetProbe passes its
///   864 checks, 362 of them on the V3D (337 at 1.140).
///
/// 142: **The V3D samples a depth where the pass stored it, and compares
/// (docs/facet-vulkan10.md item 58, for the fixed forms).** Until now it
/// refused a D16_UNORM image with SAMPLED, and Vulkan requires
/// SAMPLED_IMAGE of that format on every device. It is v3dv's way, ported:
///
/// - **The image lies as a texture does.** A sampled depth takes its
///   memory from `Ops.texture_memory` (`_image.deviceLaid`, now true of
///   one as of a texture), and the pass stores the depth into the level's
///   tiling, as v3dv stores into a slice's (v3dvx_cmd_buffer.c:396-406).
///   `cl.store` and `cl.load` take the memory format at bit 4 and the UIF
///   height in UB-blocks (v3dv_image.c:247-248), and `frame.Kept` carries
///   them. The library's clears, copies in and texel reads of it go
///   through the driver's places, as a texture's have since 1.141, and
///   GetImageSubresourceLayout answers a level there as for a texture:
///   where the driver puts it, its rows the TMU's (`row_pitch` 0).
/// - **The TMU reads it as DEPTH_COMP16.** That is texture type 21 with
///   `SWIZ_X001`, unfiltered (v3dvx_formats.c:204): `tiling.Texels.d16`,
///   which reads (D, 0, 0, 1), as the cores' depth view has since 1.121.
///   A comparison's result stands where the depth would.
/// - **The comparison.** `qpu.shadow_code` writes the reference to
///   TMUDREF, waddr 38, before TMUS (v3d_tex.c:155-157).
///   `tiling.samplerOf` packs the sampler's function as v3dv does, or
///   NEVER where compare is off (v3dvx_device.c:262-264), and refused
///   compare until now. `texture_shadow` runs on the V3D, so five of the
///   six fixed forms that read a sampler do, all but
///   `texture_cube_array_sampled`.
/// - **What stays out, said by two new `Capabilities`.**
///   - `filtered_depth`: no FILTER_LINEAR for a depth on the V3D, since
///     v3dv's D16_UNORM does not filter (v3dv_formats.c:273-276).
///   - `sampled_stencil`: no sampled `d16_unorm_s8_uint` or `s8_uint`
///     there, v3dv's one format of both being D24_UNORM_S8_UINT
///     (v3dvx_formats.c:209). CreateImage refuses one.
///   The cores keep both. `sampled_image_depth_sample_counts` is 1 on the
///   V3D now, where it was 0.
///
/// A generated program that compares, OpImageSampleDref*, is still
/// refused on the V3D: that is the rest of item 58.
///
/// Tests:
///
/// - The host tests, and the V3D's 137: the compare bits of the sampler
///   state, `.d16`'s swizzle, and a Z store in UIF_XOR.
/// - On the board, C:test/FacetProbe 1.46 passes its 888 checks, 386 of
///   them on the V3D (362 at 1.141). Its sampled-depth part drew with a
///   CPU function and ran on the cores alone; it draws with the fixed
///   forms `color` and `texture_shadow` now, and the V3D runs all of it.
///   Every check passed on the board the first time: 16 bits compared,
///   the layer a view names and the level a sampler holds it to.
///   - A sampled depth image that holds a stencil is expected where a
///     device samples one, and refused elsewhere (`Can.sampled_stencil`).
///   - A depth image of levels is held to the cores' pyramid only where
///     the device answers its rows, and elsewhere to its levels lying in
///     its memory.
/// - C:test/FacetBoth 1.14 has three cases more, each a shadow map as
///   big as the picture, drawn and then compared with over the whole of
///   it, a texel a pixel:
///   - the far and the near triangle, reference a half, `less`: 3 of
///     230,400 apart;
///   - the same at 0.6, `greater`: 3 apart;
///   - a fan whose depth slopes across the reference: 5 apart.
///   All are at triangle edges, as its plain depth cases are (4 to 9).
///   The other 185 cases are as they were at 1.141, and all 188 within
///   one pixel in a thousand.
pub const LIBRARY_REVISION = 142;
