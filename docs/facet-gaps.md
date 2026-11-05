# facet.library against Vulkan 1.0: what it does not have

facet.library draws in three dimensions the way Vulkan does - an instance,
physical devices, their memory, buffers and images, render passes,
pipelines, descriptor sets, command buffers played on a queue, and
swapchains that show what is drawn on a screen or in a window. It is not
Vulkan, and does not try to be: it is a library of the same shape, small
enough to be read, with the parts a machine of this size cannot pay for
left out.

This document is the list of what is left out, as of **facet.library
1.67**, so that a program need not find out by failing. It covers the API.
What a program *can* do is in the function documentation, one file a call,
and in the generated reference (`sdk/docs/autodocs/facet.md`).

The one absence that shapes all the others: **there is no shader
compiler.** A shader is a Zig function of the program, found in a module
stamped `FCTZ` (`sdk/libs/facet/shader.zig`), and called through a function
pointer. There is no SPIR-V, no GLSL, and no compiler for the QPUs of the
BCM2712's V3D, which runs only a fixed handful of fragment forms
(`shader.fixedFragment`) and hands anything else back to the cores.

| Where | What |
|---|---|
| `sdk/fd/facet_lib.fd` | The whole jump table, one line a function: 124 entries |
| `sdk/libs/facet/facet.zig` | The structures and enumerations a program passes |
| `sdk/libs/facet/shader.zig` | Shaders as functions: the stages, their inputs, the fixed forms |
| `sdk/libs/facet/texture.zig` | How a texture is kept and sampled, by a fixed form and through a sampler |
| `src/disk/libs/facet/` | The library: one file a call, its limits in its own documentation |
| `src/disk/libs/facet/driver/cpu/` | The cores' driver: the tiled rasterizer |
| `src/disk/libs/facet/driver/v3d/` | The V3D's driver, a module in `LIBS:facet/` |

Of Vulkan 1.0's roughly 137 core entry points, facet has 124. Two of the
absent ones, `GetInstanceProcAddr` and `GetDeviceProcAddr`, do not apply to
a library called through an LVO table.

What a device will and will not do is answered by
`GetPhysicalDeviceFeatures` (since 1.24), which is Vulkan's call with a
structure of facet's own: a field wherever a create call can refuse
something, and no field for what the library has no call for at all.
Sixteen of its fields differ between the cores and the V3D, which is the
reason a program that wants the GPU should ask rather than take the first
device listed.

Nothing below is a defect: every refusal is checked and answered with
`error_feature_not_present`, and the limits are stated in the
documentation of the call that enforces them.

## Samplers, and what a sampler still cannot ask for

Since 1.28 there are samplers: `CreateSampler`, `DestroySampler`, the
`sampler` and `combined_image_sampler` descriptors, and the fixed forms
that read the sampler bound beside the texture rather than what the program
was compiled with - `shader.FixedKind.texture_sampled` and
`texture_shadow`, and since 1.49 `texture_array_sampled`,
`texture_cube_sampled` and `texture_3d_sampled`. Through one a sample has
what a fixed form's has not: the two levels round a point mixed, a bias on
the level and a clamp, mirrored and bordered edges, up to
`max_sampler_anisotropy` samples along the longer axis, and a comparison
with a reference in place of a colour. All five of Vulkan's address modes
are taken, and a sampler the set layout holds of its own
(`immutable_samplers`).

A fixed form's own sampling is still a choice made at compile time
(`texture.Sampling`: the format, `nearest` or `bilinear`, `wrap` or
`clamp`), and the forms that have one are untouched - that path is fixed
point and a quad at a time, where a sampler's is floats and a pixel at a
time. What is left out:

- **Only the cores sample through a sampler.** The V3D's fragment programs
  are fixed, and none of them reads one, so a pipeline whose form wants a
  sampler is refused there and drawn on the cores
  (`PhysicalDeviceFeatures.samplers`), as a dropping form is. On the V3D
  the TMU is still set from the form's `sampling`.
- A cube read through a sampler reads **over its seams** since 1.60
  (`texture.Texture.sampleCubeBy`), as the fixed form `texture_cube` has
  since 1.46: a tap past a face's edge comes from the face beside it, at
  the texel the direction falls on, so a bilinear sample on a seam mixes
  the texels either side of it and a comparison counts what passed either
  side. The sampler's address modes say nothing of a cube, which has no
  edge of its own; everything else it says - the levels, the bias and
  clamp, the mipmap mode, anisotropy, the comparison - says it here too.
  A quad whose four pixels fall on different faces reads the first level,
  as the fixed forms have it. Until 1.60 such a sample was taken inside
  the one face.
- An array of cubes reads a sampler since 1.53
  (`shader.FixedKind.texture_cube_array_sampled`), at the four
  coordinates `texture_cube_array` takes: the direction, and which cube,
  the nearest there is. Over that cube's seams since 1.60, as a single
  cube's sampled form reads over its own.
- There is no border colour but transparent black, opaque black and opaque
  white, which are all of Vulkan 1.0's six: an int border and a float
  border are the same here, a texel being read as 0 to 1 whatever its
  format. A border of the program's own choosing is an extension
  (VK_EXT_custom_border_color) and is not here.
- `SamplerCreateInfo.unnormalized_coordinates` places the sample in the
  texture's own texels rather than 0 to 1 across it (since 1.67), where
  the device says it reads them
  (`PhysicalDeviceFeatures.unnormalized_coordinates`: the cores do, the
  V3D reads no sampler at all). Vulkan allows little beside it, and each
  of those is `error_initialization_failed`: one filter for both,
  `nearest` mipmapping with `min_lod` and `max_lod` 0, no anisotropy, no
  comparison, and `address_mode_u` and `address_mode_v` either
  `clamp_to_edge` or `clamp_to_border`. A 3D texture's `r` is then counted
  in slices, which Vulkan does not have at all.

The cores and the V3D's texture units still choose a level and its sample
point differently, which is why `C:test/FacetCube CHECK V3D` allows 5 % of
pixels to differ where the rest of the checks allow 0.1 %.

## Query pools, and what a query cannot count

Since 1.29 there are query pools: `CreateQueryPool`, `DestroyQueryPool`,
`GetQueryPoolResults`, `CmdBeginQuery`, `CmdEndQuery`, `CmdResetQueryPool`,
`CmdWriteTimestamp` and `CmdCopyQueryPoolResults`. An occlusion query counts
the samples that passed the tests and the fragment function did not drop; a
statistics query counts what each stage was given; and a timestamp is the
E-clock as the command is played, in microseconds, so
`timestamp_valid_bits` is 64 and `timestamp_period_ns` 1000. What is
counted is added where the work is done, so a frame's cost no longer
reaches the log alone. What is left out:

- **Only the cores count the stages.** The V3D's occlusion counter is read
  since 1.47 - a draw points it at a word of a group of sixteen on a
  boundary of 1024 bytes, as the hardware wants them, and what it counted
  is added to the query as the frame is drawn - so an occlusion pool is
  taken on every device (`PhysicalDeviceFeatures.occlusion_queries`). What
  the QPUs were given is still counted by nothing, so a statistics pool is
  refused there (`pipeline_statistics_queries`). Timestamps are kept on
  every device, because the clock is the library's and not a driver's.
- **Neither geometry statistic counts anything.** There is no geometry
  shader, so `QUERY_PIPELINE_STATISTIC_GEOMETRY_SHADER_INVOCATIONS` and
  `..._GEOMETRY_SHADER_PRIMITIVES` read 0 - which is what Vulkan has a
  statistic of a stage that never ran hold. Until 1.43 a pool that asked
  for either was refused.
- **A counter is 32 bits wide**, because the library runs on machines with
  no 64-bit atomic. It is held at its highest rather than wrapping round, so
  a count that outgrows it is too low and never nonsense. A timestamp is 64
  bits: one task writes it whole.
- **Without timer.device there are no timestamps**: a pool of them is
  refused, and `timestamp_queries`, `timestamp_valid_bits` and
  `timestamp_period_ns` are all 0. The host tests run that way.
- `QUERY_CONTROL_PRECISE` changes nothing: an occlusion query counts the
  samples either way, there being no cheaper answer to give.
- A query's samples are counted as the tiles are drawn, which is where the
  render pass ends - after the command that ended the query, though before
  the submission is done. A program reads the values once its fence is
  signalled, which is what `QUERY_RESULT_WAIT` waits for.

## A depth that outlives its pass, and what it still is not

Since 1.30 a depth attachment of `d16_unorm` may keep what was drawn into
it: with the store op STORE each tile's depth is written into the image's
memory as the tile is drawn, and with the load op LOAD each tile starts
from what is there. So depth can be read back - `CmdCopyImageToBuffer`,
`CmdCopyImage` - written from a buffer, cleared without a pass by
`CmdClearDepthStencilImage`, and a second pass can test against the first
pass's depth. What is left out:

- **Every device keeps it since 1.47** (`PhysicalDeviceFeatures.stored_depth`):
  the V3D stores the tiles' depth to the image's rows and loads it back as
  it does the render target. A depth it stored may be one of the 65535ths
  away from the one the cores would have stored - the hardware keeps a
  deeper number and writes its top 16 bits, which is the same where the
  depth falls on a 65535th and one more where it does not.
- **The stencil keeps its own since 1.38** (`stored_stencil`), by its own
  two ops: a byte a pixel, in its own plane of the same rows. `s8_uint`
  holds it at each pixel's only byte and `d16_unorm_s8_uint` after that
  pixel's depth, and the four ops are taken on their own - a pass may keep
  the stencil and leave the depth in the tiles. An op for a plane the
  format has not is refused. Keeping either plane of a format that holds
  **both** wants `stored_both` as well (1.47): the cores write a pixel's
  planes where they lie in its four bytes, while the V3D writes one
  plane's pixels one after another and so keeps only `d16_unorm` or
  `s8_uint`.
- **A depth image is a texture since 1.39** (`sampled_depth`): a depth
  attachment with `SAMPLED` is sampled out of the very rows the pass
  stored it into, through a sampler, and a shadow sample compares it at
  all 16 bits. Since 1.58 it is any of the three depth formats, and it may
  have **layers**: a view takes the plane its aspect names - the depth,
  read at all 16 bits by a sampler that compares and as a grey of its top
  8 bits by one that does not, or the stencil, read as (red, 0, 0, 1) the
  way one byte of red is - of the layers it names, and a pass draws into
  the layer its framebuffer's view begins at. So the layers of one image
  are the shadow maps of several lights, and the rows of a format holding
  both planes are two textures over the same bytes, four apart
  (`texture.Texture.linearBy`). Since 1.63 it may have **levels** as well,
  as many as halving its longer side gives: a layer holds the whole
  pyramid, a level's rows after the level before it and each as wide as
  that level is, a pass draws into the level its framebuffer's view names
  - that level's size being what the framebuffer has to fit - and a sample
  reads the level it falls on or the one its sampler holds it to. So a
  shadow map and its smaller copies are the levels of one image.
  What is left out: it is never of type `3d`, a slice being nothing a pass
  draws into, and both planes at once are no view, there being no texel of
  the two together.
- **A transient depth image keeps nothing**, having no memory: a pass that
  stores into one is refused its framebuffer. That is still the cheap way,
  and what every pass that does not ask for this goes on doing.
- Two subpasses share one since 1.52 whether they are next to each other
  or not. Next to each other and with the same colour attachments, the
  second goes on in the first's tiles and it costs nothing; otherwise the
  part that drew it last writes it into the image's rows and the next one
  to name it reads it in, whatever the attachment's own ops say. So that
  wants `stored_depth` (and `stored_stencil`, `stored_both`) and an image
  with memory behind it: a transient one is still refused the framebuffer.

## Images written through, and what they still are not

Since 1.31 a shader function may write an image: an image made with
`IMAGE_USAGE_STORAGE`, written into a set as a `storage_image`, and reached
by `shader.Resources.written`, which gives back the texture to set texels
in (`putLayer`, `setColor`) and read them from (`colorAt`). A compute
function and a fragment function of the program's can both write one. What
is left out:

- **Only the cores write one** (`PhysicalDeviceFeatures.storage_images`).
  The V3D's TMU keeps a texture in a layout of its own, which is not the one
  the library writes, so a set layout with the kind is refused there. Like
  an input attachment, this one waits on a shader compiler for the QPUs
  and not on a packet: a storage image is written by a function of the
  program's, and the V3D runs none of those.
- **Nothing orders two writes.** A frame's work is shared between the
  cores, and groups run in no order, so two functions writing the same texel
  is for the program to avoid - as it is in Vulkan, there being no barrier
  and no atomic here either.
- **The formats are a texture's**: `rgba8888`, `rgb565`, the two smaller
  ones of 1.48 - an 8888 texel kept in its word, and one byte of red, which
  takes the colour's red alone - and since 1.57 the float ones, kept as
  their floats where the device keeps them (`kept_floats`) and written one
  texel at a time by `texture.Texture.setParts` from four floats, with
  `partsAt` reading them back. `r32_sfloat` is one of them, one float a
  texel, sampled as (red, 0, 0, 1). **A compressed image asked for as a
  storage image is still unpacked to 8888**: nothing writes one texel of a
  BC block, which is the format and not the library, and such an image
  wants SAMPLED beside it. There is no `r32_uint` or `r32_sint` image: a
  texture reads a colour or floats, not whole numbers.
- A function names the level and the layer it writes since 1.55
  (`texture.Texture.setColor` and `colorAt` take both, level 0 of layer 0
  being the view's first of each), and a level, a layer or a place the
  view has not got writes nothing and reads transparent black
  (`texture.Texture.holds`). What the view has is `levels`,
  `layer_count`, `width` and `height`. `putLayer` and `peekLayer` are the
  raw pair in the texture's own format and hold to nothing: they are what
  the library's own copies and the samplers use.
- A colour attachment may be written through as a storage image since 1.56
  (CreateImage: COLOR_ATTACHMENT, or INPUT_ATTACHMENT, with STORAGE and
  without SAMPLED, of B8G8R8A8 or R5G6B5, one level and one layer). The
  image stays in rows and those rows are the texture a function writes.
  **The two are not ordered against each other**: a write reaches the rows
  at once, while what a subpass draws reaches them when it stores, so
  writing such an image through while the pass that draws into it is open
  leaves the store to win. Seeding the rows before the pass, or writing
  over them after it, is what this is for. R8G8B8A8 is refused: a texture
  of 8888 is 0xAARRGGBB, as B8G8R8A8's rows are, and nothing reads a word
  with red in its low byte. Sampled and drawn into at once is still
  refused, a sample wanting the blocked layout.

## Texel buffers, and the formats they read

Since 1.32 a buffer's bytes may be read as texels of a format:
`CreateBufferView` makes a view of a range, a `uniform_texel_buffer` or
`storage_texel_buffer` descriptor carries it, and
`shader.Resources.texels` gives the function a `shader.Texels` whose `at`
reads a texel as four floats and `colorAt` as 0xAARRGGBB, whatever the
format. A storage one is written through as well. Every device has them.

Since 1.54 the formats are a regular grid: one channel, two or four of 8,
16 or 32 bits - a `_unorm` read as 0 to 1, a `_uint` or a `_sint` as the
whole number itself, and `r16_sfloat`, `r16g16_sfloat` and
`r16g16b16a16_sfloat` as half-floats - beside the seven that were there
before (8888 either way round, `r5g6b5_unorm_pack16`, and `r32_sfloat` to
`r32g32b32a32_sfloat`). `shader.Texels.intAt` reads a texel as four whole
numbers and `setInt` writes it from them, which the 32-bit integer formats
want: `at`'s float carries 24 bits exactly, so a larger whole number
copied through it comes out changed.

What is left out:

- **No three-channel format but `r5g6b5_unorm_pack16` and
  `r32g32b32_sfloat`**: nothing of `r8g8b8` or `r16g16b16`, which almost
  no hardware carries either.
- **No compressed format, no `_snorm`, no `_srgb` and no packed one but
  565.** A `_snorm` channel would be the `_sint` number divided by its
  largest, and is not here; nor are `a2r10g10b10` and the like.
- **A `_uint` or a `_sint` texel read by `colorAt` saturates**: that call
  holds its parts to 0 and 1 before it makes bytes of them, so any whole
  number above 1 is white. `at` and `intAt` are what such a format is read
  by.
- **A view holds no bytes of its own**: it reads the buffer where it lies,
  so a destroyed view leaves a set pointing at bytes that are no longer a
  view's, as it does in Vulkan.
- Nothing orders two writes through a storage one, there being no barrier
  and no atomic.
- The offset and the range are a whole number of texels, and a range of no
  texels is refused.

## Colour attachments blended each its own way

Since 1.33 `PipelineColorBlendStateCreateInfo.attachments` is one state for
each colour attachment of the subpass, taken on its own: one attachment can
be blended while the next is replaced, each with its own factors, operation
and write mask. Every device has it
(`PhysicalDeviceFeatures.independent_blend`), an attachment being drawn as
a pass of its own either way.

Since 1.51 a subpass's colour attachments may be drawn **together**
instead: SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER in `SubpassDescription.flags`
(facet.library's own), and a fragment entry made by
`shader.fragmentOutputs` writes all of them in the one call
(`shader.Fragments.colorsOf`). The vertices are then worked once, the
triangles binned once and a quad's fragment function called once for every
attachment, each still blended its own way into a plane of each tile's
own - a G-buffer's three or four planes for the price of one pass. Only the
cores do it (`PhysicalDeviceFeatures.several_outputs`), and a pipeline of
such a subpass has to write exactly its attachments
(`error_invalid_shader_nv`). Without the flag a subpass of several is drawn
once for each, as it always was, `shader.Resources.output` saying which.

Blend constants are the pipeline's one set shared by all its attachments,
as in Vulkan, or one set each where
`PipelineColorBlendStateCreateInfo.attachment_constants` gives them -
facet's own since 1.51, because a subpass drawn together has no replay left
to set them between. `CmdSetBlendConstants` sets the one set over all of
them and `CmdSetBlendConstantsAt` one attachment's own. What is left out:

- **The V3D draws them one at a time**: its fragment programs are the
  fixed forms and each writes the one colour, so there a subpass of
  several costs its commands played over again for each.
- Logic operations are still refused, for every attachment
  (`logic_op_enable`), and there is no dual-source blending: the `SRC1`
  factors do not exist.
- `attachment_count` is either none - the default over all of them - or
  exactly the subpass's colour attachments; anything between is
  `error_initialization_failed`.

## Input attachments, and what they still are not

Since 1.37 a subpass reads attachments as well as draws into them:
`SubpassDescription.input_attachments` names them, an `input_attachment`
descriptor says which one a fragment function reads, and the function
reads it pixel by pixel at its own place
(`shader.Resources.input`, `shader.Attachment.colorAt`, `.at`). An image
made with `IMAGE_USAGE_INPUT_ATTACHMENT` keeps its pixels in rows, as a
colour attachment does, and a view of it holds those rows for the set to
point at, so deferred shading, a pass over what was drawn, and reading
one's own G-buffer are all there. All eleven of Vulkan's descriptor kinds
exist now. What is left out:

- **The cores alone read them** (`PhysicalDeviceFeatures.input_attachments`):
  on the V3D no fragment program of the library's is run at all, only the
  fixed forms, and none of those reads an attachment. This one waits on a
  shader compiler for the QPUs, not on a packet: an input attachment is
  read by a fragment function (`shader.Resources.input`), which is the
  program's own code.
- **An attachment another subpass drew is read out of the image's
  memory**, so it is read where the image stands: what that subpass drew
  and stored.
- **A subpass reads the attachment it draws into since 1.64**, which is
  Vulkan's self-dependency by region: the subpass names its own colour
  attachment as an input attachment and the pass carries a
  `SubpassDependency` of that subpass on itself with
  DEPENDENCY_BY_REGION. It is read as any input attachment is - the
  descriptor written with a view of it, then
  `shader.Fragments.input(set, binding, element)` and `colorAt(x, y)` at
  the fragment's own place - and what that answers for the attachment
  being drawn is the **tile**, which already holds the pixel, rather than
  the image's memory, which the pass has not written yet (since 1.65;
  1.64 handed it over beside the quads instead). A fragment function
  reads every input attachment through `Fragments.input` for that reason:
  `Resources.input` is the descriptor as written, and for this one that
  is the wrong memory. Without the dependency it is the loop it was,
  `error_initialization_failed`. What is left out: reading **another**
  pixel of it, which is `VK_EXT_shader_framebuffer_fetch`'s and no part
  of Vulkan 1.0 - the rest of the attachment is in other tiles, on other
  cores or not yet drawn, and reads as transparent black; reading the
  depth attachment the subpass draws into; and, of several colour
  attachments drawn together, any but the first.
- **A depth attachment is readable since 1.62**
  (`PhysicalDeviceFeatures.sampled_depth` beside `input_attachments`):
  the image is made IMAGE_USAGE_INPUT_ATTACHMENT of one of the three
  depth formats, which gives it memory of its own rather than the tiles
  alone - a transient one is refused - and the view's aspect says which
  plane the descriptor reads, the depth as `r16`, 0 to 1 and nearest
  first, or the stencil as `r8u`, the whole number it holds. A format
  that holds both is the two planes inside the same rows, four bytes from
  one pixel to the next (`shader.Attachment.stride`). The part that drew
  the depth writes it into those rows for the later subpass, the way a
  depth two subpasses share is kept, so such a pass wants `stored_depth`,
  a stencil `stored_stencil` and a format of both `stored_both`. A
  colour input attachment is still of b8g8r8a8_unorm, r8g8b8a8_unorm or
  r5g6b5_unorm_pack16, every other colour format being
  `error_format_not_supported`.
- **Nothing is checked against the layout**: `AttachmentReference.layout`
  is taken as it is, as every other layout is, and a program that reads
  an attachment an earlier subpass did not draw gets whatever the load op
  left there.
- `input_attachment_index` does not exist: which attachment a function
  reads is the descriptor it reads it through, not a number in the
  subpass.

## Dynamic buffer descriptors, and what they still are not

Since 1.35 `uniform_buffer_dynamic` and `storage_buffer_dynamic` are
kinds a set layout takes: the descriptor's bytes start where
`CmdBindDescriptorSets`' `dynamic_offsets` says, past where the write put
them, so one set serves draw after draw with a range of its own for each
instead of a set for each. Every device has them
(`PhysicalDeviceFeatures.dynamic_descriptors`). What is left out:

- **A set holds `max_descriptor_set_dynamic_buffers` of them**, two -
  eight across the four sets, which is Vulkan's guarantee for the uniform
  ones of a pipeline layout - and a layout that asks for more is refused.
  The number is low on purpose, and was measured again for 1.43: the
  offsets are part of what a draw was bound with, which is copied for every
  draw that changed it, and with four a set FacetMany drew a frame in
  11.61 ms against 11.18 to 11.58 with two - above every reading two gave,
  by about 2 per cent of the mean.
- A function reaches every element of such a binding since 1.43
  (`shader.Resources.bufferAt`, `storageAt`), as it always could for a
  sampled image or a texel buffer; `buffer` and `storage` still read the
  first.
- The offsets are not checked against the buffer: one past the range
  leaves nothing to read, and a function finds no `T` there rather than
  reading another buffer's bytes.
- An offset is in bytes and is not rounded: it is for the program to keep
  it aligned for what it reads there.

## Object kinds that do not exist

### Events

No `CreateEvent`, `DestroyEvent`, `GetEventStatus`, `SetEvent`,
`ResetEvent`, `CmdSetEvent`, `CmdResetEvent` or `CmdWaitEvents`. Fences and
semaphores are the whole of synchronisation: with one queue family of one
queue, played in order by one task, a `CmdWaitEvents` is either already
satisfied or a deadlock, and the host pair would say no more than a fence
says. A device with more than one queue is what gives them something to
do.

### Pipeline cache

`PipelineCache` is declared, and `CreateGraphicsPipelines` and
`CreateComputePipelines` each take a `?*facet.PipelineCache`, but nothing
makes one: there is no `CreatePipelineCache`, `DestroyPipelineCache`,
`GetPipelineCacheData` or `MergePipelineCaches`. The parameter is there for
the shape of the call and is ignored. Pipelines are cheap to make here,
because there is nothing to compile.

### Sparse resources

No `QueueBindSparse`, `GetImageSparseMemoryRequirements` or
`GetPhysicalDeviceSparseImageFormatProperties`. Memory is bound whole.

## The depth clamp and the depth bounds test

Since 1.40 the last two pieces of depth state Vulkan has are there
(`PhysicalDeviceFeatures.depth_clamp`, `depth_bounds`):
`depth_clamp_enable` draws what lies past the near plane instead of
cutting it away, each pixel's depth held inside the viewport's
`min_depth` and `max_depth`, and `depth_bounds_test_enable` with
`min_depth_bounds`, `max_depth_bounds` and `CmdSetDepthBounds`
(`DynamicState.depth_bounds`) draws a pixel only where the depth already
in the attachment lies between the two. What is left out:

- **Every device has them since 1.47.** The V3D's configuration carries
  the clamp - which turns its clip to the z planes off with it, as Vulkan
  has a depth clamp - and the bounds are a packet of its own.
- **On the cores a draw with either is walked a pixel at a time**, the way
  a draw with a stencil test is, so it costs more than the quads the fast
  paths walk. Nothing a draw without them costs changes, and on the V3D
  neither costs anything: they are bits of the state it was going to
  write.
- A clamped draw is still cut just in front of the eye, where the
  projection stops holding, so geometry that reaches behind the eye is
  cut there rather than drawn from behind - which is what every
  rasterizer with a guard band does.
- The bounds are the pipeline's or a command's, never a range for each
  viewport: there is one viewport.

## The depth bias, and what it still is not

Since 1.34 a pipeline may move its triangles' depth before it is tested
and written: `depth_bias_enable` with its constant, slope and clamp, or
`DynamicState.depth_bias` and `CmdSetDepthBias` to leave the three numbers
to commands. The constant is in the smallest differences the depth
attachment holds - 65535ths of the range for `d16_unorm` - and the slope
is of the triangle's steepest, in depth over a pixel. What is left out:

- **Every device moves it since 1.47** (`PhysicalDeviceFeatures.depth_bias`):
  the V3D's own depth offset packet takes Vulkan's three numbers unscaled
  - the units in the depth buffer's smallest differences, the factor of
  the triangle's slope, the clamp as its limit.
- **Only triangles are moved**, as in Vulkan: points and lines, and
  triangles drawn as their edges or corners, are drawn where they are.
- The bias is worked out once a triangle, from the depth plane its set-up
  already had, so it is exact in the depth's own units and costs nothing a
  pixel - but it is the plane that moves, not each pixel, which is what
  Vulkan's wording allows.
- The depth clamp and the depth bounds test are there since 1.40, with
  CmdSetDepthBounds and `DynamicState.depth_bounds`, and on every device
  since 1.47 - the V3D's configuration has the clamp, which turns the clip
  to the z planes off with it, and its own packet the bounds:
  see their own section above.

## Commands that are absent

- `CmdResolveImage`: there is no multisampling to resolve.

That is the whole of it: every other command of Vulkan 1.0's core that
this library has a stage for is in the table.

## Device queries that are absent

Since 1.36 the three that were missing are there:
`GetPhysicalDeviceImageFormatProperties` answers the largest image of a
format, type, tiling and usage - and `error_format_not_supported` for a
shape there is no image of at all - by asking the rules `CreateImage`
keeps, so the two cannot drift apart; `GetRenderAreaGranularity` is the
device's tile; and `GetDeviceMemoryCommitment` is a block's whole size, or
0 for the lazily allocated type. What is left:

- `FlushMappedMemoryRanges` and `InvalidateMappedMemoryRanges`: no
  non-coherent host memory is offered, so there is nothing to flush.
- `EnumerateInstanceExtensionProperties` and the other three: there is no
  extension and no layer mechanism. Surfaces and swapchains are simply part
  of the table, not behind an extension, and `CreateScreenSurface` and
  `CreateWindowSurface` take the place of a platform's own.

`max_resource_size` is the bytes of the image the rest of that answer
describes - its largest extent, its most levels and its most layers at
once - which is what `GetImageMemoryRequirements` answers for such an
image (since 1.66; before it, the largest heap's size). It is a size, not
a promise of memory: the largest extent and the most layers together come
to more than any heap of this machine holds, and `AllocateMemory` is what
finds that out.

## In the structures, refused by the implementation

These can be asked for and are answered with `error_feature_not_present`.

| What | Where it is refused |
|---|---|
| Multisampling entirely: `rasterization_samples` above 1, sample shading, alpha-to-coverage, alpha-to-one | `pipeline/creategraphicspipelines.zig` |
| An attachment of more than one sample | `render/createrenderpass.zig` |
| Logic operations: `LogicOp` is fully enumerated, `logic_op_enable` is not taken | `pipeline/creategraphicspipelines.zig` |
| Depth clamp, the depth bounds test or a depth bias on a device that has none of them: every device has all three since 1.47 (`depth_clamp`, `depth_bounds`, `depth_bias`) | `pipeline/creategraphicspipelines.zig` |
| More than one viewport or one scissor | `pipeline/creategraphicspipelines.zig` |
| Colour attachments that differ, on a device that blends them all alike: no device of this library is one (`independent_blend`) | `pipeline/creategraphicspipelines.zig` |
| Resolve attachments in a subpass | `render/createrenderpass.zig` |
| An input attachment on a device that reads none: the V3D (`input_attachments`) | `render/createrenderpass.zig` |
| An input attachment of a colour format whose pixels are not kept in rows (a depth format is read since 1.62); a subpass that reads what it draws without a dependency on itself by region (since 1.64) | `render/createrenderpass.zig` |
| An image both INPUT_ATTACHMENT and SAMPLED, STORAGE or TRANSIENT_ATTACHMENT | `image/createimage.zig` |
| A depth or stencil op for a plane the format has not, or on a device that keeps neither (`stored_depth`, `stored_stencil`) | `render/createrenderpass.zig` |
| Present modes but `fifo`, though `immediate`, `mailbox` and `fifo_relaxed` are enumerated: a display shows a buffer from its next frame on, and there is no way to ask it for anything else | `swapchain/createswapchain.zig` |
| A swapchain whose images would be SAMPLED: they are drawn into, copied out of and copied into (since 1.43), their pixels being rows and not blocks of texels | `swapchain/createswapchain.zig` |
| An `input_attachment` layout on a device that reads none: the V3D (`input_attachments`) | `descriptor/createdescriptorsetlayout.zig` |
| More dynamic buffer descriptors in one set than `max_descriptor_set_dynamic_buffers` | `descriptor/createdescriptorsetlayout.zig` |
| A `storage_image` layout on the V3D: its TMU keeps a texture its own way | `descriptor/createdescriptorsetlayout.zig` |
| A fixed fragment form that drops pixels, on the V3D: the QPUs have no program that discards | `driver/v3d/driver.zig` |
| A fixed fragment form that samples through a sampler, on the V3D: nor one that reads a sampler | `driver/v3d/driver.zig` |
| A statistics query pool on the V3D: what its QPUs were given is counted by nothing. An occlusion pool is taken on every device since 1.47 | `query/createquerypool.zig` |
| A bit that is no statistic at all. Both of a geometry shader's may be asked for since 1.43 and read 0, there being no such stage to count | `query/createquerypool.zig` |
| A timestamp pool without timer.device: the clock a timestamp is read from | `query/createquerypool.zig` |
| A depth or stencil attachment of `d16_unorm_s8_uint` that loads or stores, on a device that stores a tile buffer whole: the V3D (`stored_both`, 1.47). Either plane of a format that holds it alone is kept on every device | `render/createrenderpass.zig` |
| A depth attachment kept, whose image has no memory behind it | `render/createframebuffer.zig` |
| A sampled depth image on a device that samples none: the V3D (`sampled_depth`); a transient one, or one written through as a storage image; one of more levels than halving its longer side gives, or of type `3d`. Any of the three depth formats is taken since 1.58 and levels of its own since 1.63, and a view of it names one plane - both at once is refused there (`image/createimageview.zig`) | `image/createimage.zig` |

One consequence does not appear in that table:

- **A form that drops pixels cannot also have the depth pre-pass.** The
  pre-pass settles depth before any fragment function has run, which is the
  opposite of what a dropping form needs, so `PIPELINE_CREATE_DEPTH_PREPASS`
  is simply not taken for one rather than refused
  (`pipeline/creategraphicspipelines.zig`). On the cores such a pipeline has
  its depth written after its fragment function instead; the V3D orders its
  own, and refuses the form for want of a program, not for want of ordering.

Three more things cannot be asked for at all, having nothing to ask with:

- No geometry shader stage: there is no such bit among `SHADER_STAGE_*`.
  Its two statistics can be counted - as 0 - since 1.43; the stage itself
  cannot be written.
- One queue family with one queue, on both devices, which makes
  `SharingMode` nominal. There is nothing to share between: one task plays
  what is submitted, in the order it was.
- A swapchain's images have one array layer, and a swapchain one to four
  images. Since 1.43 an image may be copied out of and into as well as
  drawn into, so a picture of the frame is taken with
  CmdCopyImageToBuffer; it still cannot be sampled.

## The limits

| | |
|---|---|
| Vertex input bindings | 4 |
| Vertex input attributes | 8 |
| Vertex input binding stride | 2048 bytes |
| Vertex output components (varyings) | 8 |
| Push constants | 128 bytes |
| Bound descriptor sets | 4 |
| Image side, 2D | 8192 |
| 3D depth, and array layers | 256 |
| Attachments, subpasses, colour attachments | 8, 4, 4 |
| Patch control points | 32 |
| Floats a patch carries to its evaluation function | 16 |
| Swapchain images | 1 to 4 |
| Samples along a sampler's longer axis | 16 |
| A query's counter | 32 bits, held there |
| A timestamp's unit | 1000 ns, 64 bits of it |
| A line's width | `line_width` pixels, and `CmdSetLineWidth` |
| A point's size | one pixel, whatever the line width says: Vulkan's `PointSize` is written by no shader here |

Of textures:

- The sides may be any size since 1.42, with the levels Vulkan has - the
  one before halved, never below one, as many as floor(log2(longer side))
  + 1 - but a width that is not a power of two is **laid out by the next
  one up**: up to 2 x the memory for the widest levels, and nothing for a
  height. Past the width nothing is read. `wrap` round a side that is not
  a power of two costs a division a sample instead of a mask; `clamp`
  costs the same whatever the size.
- A texel is kept as `rgba8888`, `rgb565`, the blocks of BC1, BC2 or BC3
  (1.44), the floats of the four float formats (1.45), or - since 1.48 -
  one of the two smaller ones. An 8888 texel takes 64 bits by default,
  each channel in 16 of them, so that the four texels of a bilinear
  sample come out of memory ready to mix.
- **A texel smaller than its colour** since 1.48
  (`PhysicalDeviceFeatures.small_texels`, every device): an image of
  `r8_unorm` keeps one byte of red a texel and reads as (red, 0, 0, 1),
  an eighth of what the same texels kept as 8888 take; and
  IMAGE_CREATE_PACKED_TEXELS on a sampled image of 8888 keeps each texel
  in the 32 bits of its word rather than spread over 64, half the memory
  for the spread a sample then does itself. Both are written through as
  storage images and copied both ways. A fixed form reads either at full
  speed where it was compiled for it (`texture.Format.r8`, `argb8888`);
  one compiled for `rgba8888` draws it through the run-time sampler. On
  the V3D an 8888 texel was never spread, so the flag costs nothing and
  changes nothing there, and R8 is a texture type of the TMU's own. There
  is no `r8g8`, no 16-bit channel and no signed or integer one.
- A compressed image is kept in its blocks on a device that samples them
  (`PhysicalDeviceFeatures.kept_compressed`, the cores since 1.44): an
  eighth to a quarter of the memory - 16 x 16 of BC1 is 128 bytes against
  1024 - and the block a sample reads is decoded as it is read, once for
  the four texels where they share one. The blocks are copied in and out
  as they lie, their offsets on a multiple of 4. The V3D has not got it:
  its TMU is fed unpacked texels, so there such an image is unpacked into
  8888 as before, cannot be copied out of, and takes the memory.
- A float image is kept as its floats on a device that samples them
  (`PhysicalDeviceFeatures.kept_floats`, the cores since 1.45): the two
  packed formats take 4 bytes a texel against the 8 an unpacked 8888 texel
  is kept spread in, and what was copied in comes out again. A sample
  still holds each channel inside 0 to 1 and rounds it to 8 bits - the
  tiles and the formats the library draws into have no more - so what is
  above 1 is lost on the way into the tiles rather than in memory. Where
  the device unpacks instead (the V3D), it is as it was: 8888 in memory,
  no copying out.
- A fixed form says the format it samples (`texture.Sampling.format`), and
  that is the one its fast path reads. Since 1.44 a texture of another
  format is drawn all the same, through the run-time sampler, a pixel at a
  time: correct, and slower than the form that matches - so a program that
  wants the fast path asks the device what it keeps and compiles the form
  for it. Before 1.44 such a draw was painted `shader.missing`.
- A 3D texture has levels of its own and any depth since 1.46: a level is
  half as deep as the one before it, never below one slice, and each slice
  carries the whole of its own pyramid - so a level past the first leaves
  the slices past its depth unread, about a sixth of the memory wasted at
  the deepest level. A sampler reads such a texture since 1.49
  (`texture_3d_sampled`), and since 1.59 it reads the slices the level it
  chose has, each level over its own - before that the slice came from the
  whole depth whatever the level, so a level past the first read the wrong
  slice, or memory no copy had written. Which of the two filters decides
  whether the slices either side of the point are mixed is the one the
  level asked for, as it is across the slice.
- An array of cubes since 1.46: a view of type `cube_array` over a
  multiple of six layers, read by a form of
  `shader.FixedKind.texture_cube_array` at four coordinates - the
  direction and which cube, the nearest there is
  (`PhysicalDeviceFeatures.cube_arrays`, the cores), and since 1.53 by
  `texture_cube_array_sampled`, the same four through the sampler bound
  beside it. The V3D has no QPU
  program that reads a fourth coordinate, so it refuses the view and the
  pipeline, and such a draw goes to the cores.
- ETC2 and EAC since 1.46, unpacked into 8888 as they are copied in on
  every device (`etc2_textures`), every mode of the format decoded:
  individual, differential, T, H, planar, punchthrough alpha, and EAC's
  alpha and 11-bit channels. No sampler reads such a block where it lies,
  so the image takes the memory of its texels and cannot be copied out of.
  There is no ETC1 and no ASTC.
- The compressed formats are the four BC ones: no BC4 to BC7, no BC1 with
  1-bit alpha told apart from the opaque one past the punch-through rule,
  and nothing compresses - a blit or a copy into a compressed image from
  an uncompressed one takes nothing.
- The float formats are the five Vulkan ones the library takes:
  `r16g16b16a16_sfloat`, `r32g32b32a32_sfloat`, `b10g11r11_ufloat_pack32`,
  `e5b9g9r9_ufloat_pack32` and `r32_sfloat`. There is no `r16_sfloat` or
  `r16g16`, and no signed or unsigned integer format of any width.
  `CmdClearColorImage` writes such an image since 1.61, with the channels
  of `ClearColorValue.float32` as they stand rather than rounded to a byte
  each, so a red of 2 is a red of 2 afterwards as far as the format
  reaches. What still makes no floats: a blit into a float image, and a
  copy into one from an image of another format, take nothing.

## Compute, as it stands

A compute function is called once for each **workgroup**, not once for each
invocation (`shader.Groups`). Since 1.41 a group holds as many invocations
as the function's entry declares - `shader.computeGroup(name, function,
local, shared)` - and the call is given them to make itself: `Groups.local`
is the group's size, with `localIndex`, `globalInvocation` and
`invocations` to number them by, and `Groups.shared` the bytes they share,
read as values by `sharedAs`. So a reduction over a group, or a tile held
in shared memory, is written the way it is in GLSL, as a loop.

What that does not bring:

- **No barrier.** The invocations of a group run in whatever order the
  function loops over them, one after the other in the one call, so a
  barrier is the point *between two loops* inside that call. There is no
  `CmdPipelineBarrier` equivalent for them, and none is needed.
- **No subgroups**: no ballot, no shuffle, no subgroup size. A group is a
  loop on one core, not a warp.
- **Nothing shared between groups.** The shared block is a worker's own:
  cleared for the first group a worker takes and holding what the group
  before it left after that, so a group that reads what it has not written
  reads leavings. Groups still run in no order, on any core, and no two may
  write the same memory.
- **The limits are small by Vulkan's standards**: 1024 by 1024 by 64
  invocations along the axes, 1024 in a group, and 16 KiB shared
  (`PhysicalDeviceLimits.max_compute_work_group_size`,
  `max_compute_work_group_invocations`,
  `max_compute_shared_memory_size`). A group of more is refused as the
  pipeline is made (`error_feature_not_present`). The group count a
  dispatch asks for is not bounded.

A group runs on a worker's stack, so keep what it puts there small. It
writes storage buffers and, since 1.31, storage images (below). Compute and
tessellation run on the cores whichever device the pipeline was made on.

Tessellation has Vulkan's three spacing modes since 1.50
(`shader.Spacing`), and its control function carries floats of its own to
the evaluation function (`shader.control`, `Patch.ownValues`), up to
`PhysicalDeviceLimits.max_tessellation_patch_components` of them. What it
has not got is **point mode** - the tessellator emits triangles, or the
lines of `isolines`, and nothing emits the patch's points on their own -
and a control function cannot move the patch's vertices or
change how many there are: it says the levels and writes the patch's own
floats, and the evaluation function works from the vertices as the vertex
function left them. Where Vulkan rounds an edge's two short fractional
pieces is undefined; here they go one at each end, so that two patches
sharing an edge cut it the same way from either side.

## Left out for this hardware

Multisampling, logic operations, dual-source blending, geometry shaders,
several viewports, sparse memory, events and a pipeline cache are not
missing by accident. They cost more than they would give on *this*
hardware, and both the tiled rasterizer on the cores and the V3D's fixed
fragment forms are built the way they are because of it: a tile that holds
its samples no longer sits in a core's cache, a logic operation cannot use
the blend fast path and would have to live in a fragment program the QPUs
cannot run, a geometry stage wants an allocation between the vertex work
and the binning, a wait on an event has nothing to wait for behind one
in-order queue, and a pipeline cache has nothing to cache where nothing is
compiled.

None of that is a judgement on the features, and none of it is for ever.
Every one of them is answered by the **device**: a driver for a chip that
has the thing in hardware says yes to it, while the cores and the V3D go
on saying no, and a program that asks `GetPhysicalDeviceFeatures` first
needs no change at all. `docs/facet-todo.md` keeps them as work to do when
such a chip comes in, with what each would cost then.
