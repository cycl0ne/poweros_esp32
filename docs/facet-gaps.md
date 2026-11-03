# facet.library against Vulkan 1.0: what it does not have

facet.library draws in three dimensions the way Vulkan does - an instance,
physical devices, their memory, buffers and images, render passes,
pipelines, descriptor sets, command buffers played on a queue, and
swapchains that show what is drawn on a screen or in a window. It is not
Vulkan, and does not try to be: it is a library of the same shape, small
enough to be read, with the parts a machine of this size cannot pay for
left out.

This document is the list of what is left out, as of **facet.library
1.43**, so that a program need not find out by failing. It covers the API.
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
Thirteen of its fields differ between the cores and the V3D, which is the
reason a program that wants the GPU should ask rather than take the first
device listed.

Nothing below is a defect: every refusal is checked and answered with
`error_feature_not_present`, and the limits are stated in the
documentation of the call that enforces them.

## Samplers, and what a sampler still cannot ask for

Since 1.28 there are samplers: `CreateSampler`, `DestroySampler`, the
`sampler` and `combined_image_sampler` descriptors, and two fixed forms
that read the sampler bound beside the texture rather than what the program
was compiled with - `shader.FixedKind.texture_sampled` and
`texture_shadow`. Through one a sample has what a fixed form's has not: the
two levels round a point mixed, a bias on the level and a clamp, mirrored
and bordered edges, up to `max_sampler_anisotropy` samples along the longer
axis, and a comparison with a reference in place of a colour.

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
- The fixed forms that sample through a sampler are 2D. A texture of
  layers, a cube map and a 3D texture have forms of their own, which sample
  as they were compiled to; a program's own fragment function can sample
  any of them through a sampler (`texture.sampleBy`, `sampleVolumeBy`).
- No `mirror_clamp_to_edge`, and no border colour but transparent black,
  opaque black and opaque white: Vulkan's int and float border colours are
  the same here, a texel being read as 0 to 1 whatever its format.
- `SamplerCreateInfo.unnormalized_coordinates` is refused: coordinates are
  0 to 1 across the texture.
- `DescriptorSetLayoutBinding.immutable_samplers` is refused rather than
  passed over, so that no program is left thinking its write took.

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

- **Only the cores count the work.** The V3D's occlusion counter is not
  read and what its QPUs were given is not counted, so a pool of either
  kind is refused on it (`PhysicalDeviceFeatures.occlusion_queries`,
  `pipeline_statistics_queries`). Timestamps are kept on every device,
  because the clock is the library's and not a driver's.
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

- **Only the cores keep it** (`PhysicalDeviceFeatures.stored_depth`). The
  V3D draws in tiles of its own and nothing stores their depth to memory
  yet, so a pass that asks for either op is refused there.
- **The stencil keeps its own since 1.38** (`stored_stencil`), by its own
  two ops: a byte a pixel, in its own plane of the same rows. `s8_uint`
  holds it at each pixel's only byte and `d16_unorm_s8_uint` after that
  pixel's depth, and the four ops are taken on their own - a pass may keep
  the stencil and leave the depth in the tiles. An op for a plane the
  format has not is refused.
- **A depth image is a texture since 1.39** (`sampled_depth`): `d16_unorm`
  with `SAMPLED` is sampled out of the very rows the pass stored it into,
  through a sampler, and a shadow sample compares it at all 16 bits. What
  is left out: it is sampled by a sampler alone - the fixed forms' fast
  path is built for blocks, so a form not compiled for `texture.Format.d16`
  paints `shader.missing` - it has one level, no layers and no mipmaps,
  and a sample of the colour rather than a comparison reads the depth as a
  grey of its top 8 bits. A format with a stencil is not sampled at all,
  there being no stencil texel.
- **A transient depth image keeps nothing**, having no memory: a pass that
  stores into one is refused its framebuffer. That is still the cheap way,
  and what every pass that does not ask for this goes on doing.
- Two subpasses still share a depth attachment only one right after the
  other, in the same tiles.

## Images written through, and what they still are not

Since 1.31 a shader function may write an image: an image made with
`IMAGE_USAGE_STORAGE`, written into a set as a `storage_image`, and reached
by `shader.Resources.written`, which gives back the texture to set texels
in (`putLayer`, `setColor`) and read them from (`colorAt`). A compute
function and a fragment function of the program's can both write one. What
is left out:

- **Only the cores write one** (`PhysicalDeviceFeatures.storage_images`).
  The V3D's TMU keeps a texture in a layout of its own, which is not the one
  the library writes, so a set layout with the kind is refused there.
- **Nothing orders two writes.** A frame's work is shared between the
  cores, and groups run in no order, so two functions writing the same texel
  is for the program to avoid - as it is in Vulkan, there being no barrier
  and no atomic here either.
- **The formats are a texture's**: `rgba8888` and `rgb565`. There is no
  format conversion on a write and no `r32` of any kind, and the compressed
  and float formats, being unpacked to 8888 as they are copied in, are not
  written through at all.
- **The view's first level and layer** are what a function writes: there is
  no way to name another level from inside the function.
- A `storage_image` is still not an attachment: an image cannot be drawn
  into and written through in the same pass.

## Texel buffers, and the formats they read

Since 1.32 a buffer's bytes may be read as texels of a format:
`CreateBufferView` makes a view of a range, a `uniform_texel_buffer` or
`storage_texel_buffer` descriptor carries it, and
`shader.Resources.texels` gives the function a `shader.Texels` whose `at`
reads a texel as four floats and `colorAt` as 0xAARRGGBB, whatever the
format. A storage one is written through as well. Every device has them.
What is left out:

- **Seven formats**: `r8g8b8a8_unorm`, `b8g8r8a8_unorm`,
  `r5g6b5_unorm_pack16`, and `r32_sfloat` to `r32g32b32a32_sfloat`. No
  integer texel formats, nothing of 16 bits a channel, and none of the
  compressed ones.
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
a pass of its own either way. What is left out:

- **The blend constants are the pipeline's**, one set shared by all of its
  attachments, as they are in Vulkan; `CmdSetBlendConstants` sets that one
  set.
- **A fragment function still runs once for each attachment**, with
  `shader.Resources.output` saying which: it writes one colour, never
  several at once, so a subpass of several has its commands played over
  again for each rather than drawn once into all of them.
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
  fixed forms, and none of those reads an attachment.
- **An attachment is read out of the image's memory, not out of the
  tile.** So it is read where the image stands - what the subpass before
  it drew and stored - and a subpass cannot read the attachment it is
  drawing into, which would be a loop: that is
  `error_initialization_failed`. Vulkan allows exactly that for the
  fragment's own pixel, which is what `VK_EXT_shader_framebuffer_fetch`
  and the subpass self-dependency are for.
- **A depth attachment is not readable**, because it lives in the
  rasterizer's tiles and has no rows: an input attachment is of
  b8g8r8a8_unorm, r8g8b8a8_unorm or r5g6b5_unorm_pack16. A shadow pass
  that wants the depth still copies it out (`CmdCopyImageToBuffer`).
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
semaphores are the whole of synchronisation.

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

- **Only the cores have them.** The V3D's control lists clip in their own
  way and it has no depth bounds test, so a pipeline that asks for either
  is refused there.
- **A draw with either is walked a pixel at a time**, the way a draw with
  a stencil test is, so it costs more than the quads the fast paths walk.
  Nothing a draw without them costs changes.
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

- **Only the cores move it** (`PhysicalDeviceFeatures.depth_bias`). The
  V3D has a depth offset of its own, a packet this driver does not write
  yet, so a pipeline that asks for a bias is refused there.
- **Only triangles are moved**, as in Vulkan: points and lines, and
  triangles drawn as their edges or corners, are drawn where they are.
- The bias is worked out once a triangle, from the depth plane its set-up
  already had, so it is exact in the depth's own units and costs nothing a
  pixel - but it is the plane that moves, not each pixel, which is what
  Vulkan's wording allows.
- The depth clamp and the depth bounds test are there since 1.40, with
  CmdSetDepthBounds and `DynamicState.depth_bounds`, on the cores alone:
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

`GetPhysicalDeviceImageFormatProperties` says nothing about the memory an
image of the largest extent and the most layers at once would want:
`max_resource_size` and what `AllocateMemory` answers are what there is.

## In the structures, refused by the implementation

These can be asked for and are answered with `error_feature_not_present`.

| What | Where it is refused |
|---|---|
| Multisampling entirely: `rasterization_samples` above 1, sample shading, alpha-to-coverage, alpha-to-one | `pipeline/creategraphicspipelines.zig` |
| An attachment of more than one sample | `render/createrenderpass.zig` |
| Logic operations: `LogicOp` is fully enumerated, `logic_op_enable` is not taken | `pipeline/creategraphicspipelines.zig` |
| Depth clamp or the depth bounds test on a device that has neither: the V3D (`depth_clamp`, `depth_bounds`) | `pipeline/creategraphicspipelines.zig` |
| A depth bias, on a device that moves no depth: the V3D (`depth_bias`) | `pipeline/creategraphicspipelines.zig` |
| More than one viewport or one scissor | `pipeline/creategraphicspipelines.zig` |
| Colour attachments that differ, on a device that blends them all alike: no device of this library is one (`independent_blend`) | `pipeline/creategraphicspipelines.zig` |
| Resolve attachments in a subpass | `render/createrenderpass.zig` |
| An input attachment on a device that reads none: the V3D (`input_attachments`) | `render/createrenderpass.zig` |
| An input attachment of a format whose pixels are not kept in rows, a depth attachment among them | `render/createrenderpass.zig` |
| An image both INPUT_ATTACHMENT and SAMPLED, STORAGE or TRANSIENT_ATTACHMENT | `image/createimage.zig` |
| A depth or stencil op for a plane the format has not, or on a device that keeps neither (`stored_depth`, `stored_stencil`) | `render/createrenderpass.zig` |
| Present modes but `fifo`, though `immediate`, `mailbox` and `fifo_relaxed` are enumerated: a display shows a buffer from its next frame on, and there is no way to ask it for anything else | `swapchain/createswapchain.zig` |
| A swapchain whose images would be SAMPLED: they are drawn into, copied out of and copied into (since 1.43), their pixels being rows and not blocks of texels | `swapchain/createswapchain.zig` |
| An `input_attachment` layout on a device that reads none: the V3D (`input_attachments`) | `descriptor/createdescriptorsetlayout.zig` |
| More dynamic buffer descriptors in one set than `max_descriptor_set_dynamic_buffers` | `descriptor/createdescriptorsetlayout.zig` |
| A `storage_image` layout on the V3D: its TMU keeps a texture its own way | `descriptor/createdescriptorsetlayout.zig` |
| A fixed fragment form that drops pixels, on the V3D: the QPUs have no program that discards | `driver/v3d/driver.zig` |
| A fixed fragment form that samples through a sampler, on the V3D: nor one that reads a sampler | `driver/v3d/driver.zig` |
| An occlusion or a statistics query pool, on the V3D: it counts neither the samples nor the stages | `query/createquerypool.zig` |
| A bit that is no statistic at all. Both of a geometry shader's may be asked for since 1.43 and read 0, there being no such stage to count | `query/createquerypool.zig` |
| A timestamp pool without timer.device: the clock a timestamp is read from | `query/createquerypool.zig` |
| A depth or stencil attachment that loads or stores, on the V3D | `render/createrenderpass.zig` |
| A depth attachment kept, whose image has no memory behind it | `render/createframebuffer.zig` |
| A sampled depth image on a device that samples none: the V3D (`sampled_depth`); one with a stencil in it, a transient one, or one written through as a storage image | `image/createimage.zig` |

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
| Swapchain images | 1 to 4 |
| Samples along a sampler's longer axis | 16 |
| A query's counter | 32 bits, held there |
| A timestamp's unit | 1000 ns, 64 bits of it |

Of textures:

- The sides may be any size since 1.42, with the levels Vulkan has - the
  one before halved, never below one, as many as floor(log2(longer side))
  + 1 - but a width that is not a power of two is **laid out by the next
  one up**: up to 2 x the memory for the widest levels, and nothing for a
  height. Past the width nothing is read. `wrap` round a side that is not
  a power of two costs a division a sample instead of a mask; `clamp`
  costs the same whatever the size.
- A texel is kept as `rgba8888` or `rgb565`, and nothing else. An 8888
  texel takes 64 bits, each channel in 16 of them, so that the four texels
  of a bilinear sample come out of memory ready to mix.
- BC1, BC2, BC3 and the float formats are unpacked to 8 bits a channel as
  they are copied in: no memory is saved, what is above 1 or below 0 in a
  float image is lost, and such an image cannot be copied out of, nor
  another image into it.
- A 3D texture has one level and a depth that is a power of two. There are
  no cube arrays and no ETC.

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

Tessellation divides evenly only, has no point mode - there is no point
rasterization at all, in any pipeline - and its control function sets
nothing but the levels.

## Left out on purpose

Multisampling, logic operations, geometry shaders, several viewports,
sparse memory, events and a pipeline cache are not missing by accident and
are not planned. They cost more than they would give on this hardware, and
both the tiled rasterizer on the cores and the V3D's fixed fragment forms
are built the way they are because of it.
