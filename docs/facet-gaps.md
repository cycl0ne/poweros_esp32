# facet.library against Vulkan 1.0: what it does not have

facet.library draws in three dimensions the way Vulkan does - an instance,
physical devices, their memory, buffers and images, render passes,
pipelines, descriptor sets, command buffers played on a queue, and
swapchains that show what is drawn on a screen or in a window. It is not
Vulkan, and does not try to be: it is a library of the same shape, small
enough to be read, with the parts a machine of this size cannot pay for
left out.

This document is the list of what is left out, as of **facet.library
1.22**, so that a program need not find out by failing. It covers the API.
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
| `sdk/fd/facet_lib.fd` | The whole jump table, one line a function: 103 entries |
| `sdk/libs/facet/facet.zig` | The structures and enumerations a program passes |
| `sdk/libs/facet/shader.zig` | Shaders as functions: the stages, their inputs, the fixed forms |
| `sdk/libs/facet/texture.zig` | How a texture is kept and sampled |
| `src/disk/libs/facet/` | The library: one file a call, its limits in its own documentation |
| `src/disk/libs/facet/driver/cpu/` | The cores' driver: the tiled rasterizer |
| `src/disk/libs/facet/driver/v3d/` | The V3D's driver, a module in `LIBS:facet/` |

Of Vulkan 1.0's roughly 137 core entry points, facet has 103. Two of the
absent ones, `GetInstanceProcAddr` and `GetDeviceProcAddr`, do not apply to
a library called through an LVO table.

Nothing below is a defect: every refusal is checked and answered with
`error_feature_not_present`, and the limits are stated in the
documentation of the call that enforces them.

## Object kinds that do not exist

### Samplers

There is no `CreateSampler`, no `DestroySampler`, and no sampler object of
any kind. A texture's filter, its address mode and the format it is kept in
belong to the **pipeline**, fixed when the program is compiled
(`texture.Sampling`), not to an object bound beside the image. What follows:

- No anisotropic filtering.
- No LOD bias and no LOD clamp.
- Only `wrap` and `clamp` past the edges: no mirror, no border colour.
- No filtering between mip levels. The level is "the nearest of the levels
  the texture has" (`sdk/libs/facet/texture.zig`), never two mixed. The
  cores and the V3D's texture units also choose that level and its sample
  point differently, which is why `C:test/FacetCube CHECK V3D` allows 5 %
  of pixels to differ where the rest of the checks allow 0.1 %.
- No comparison or shadow samplers.
- `.sampler` and `.combined_image_sampler` descriptors are refused.

This is the largest single hole in the API: the one place where Vulkan's
object model is replaced by a choice made at compile time.

### Query pools

No `CreateQueryPool`, `DestroyQueryPool`, `GetQueryPoolResults`,
`CmdBeginQuery`, `CmdEndQuery`, `CmdResetQueryPool`, `CmdWriteTimestamp` or
`CmdCopyQueryPoolResults`. Both drivers report `timestamp_valid_bits = 0`.
So there are no occlusion queries, no pipeline statistics and no
timestamps; what a frame costs is measured inside the drivers and written
to the log.

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

### Buffer views

No `CreateBufferView` and no `DestroyBufferView`; the
`uniform_texel_buffer` and `storage_texel_buffer` descriptors are refused.

### Sparse resources

No `QueueBindSparse`, `GetImageSparseMemoryRequirements` or
`GetPhysicalDeviceSparseImageFormatProperties`. Memory is bound whole.

## Commands that are absent

- `CmdUpdateBuffer` and `CmdFillBuffer`: a buffer is written by mapping its
  memory or copying into it, and there is no clearing one.
- `CmdClearColorImage` and `CmdClearDepthStencilImage`: clearing happens
  through an attachment's `load_op`, or `CmdClearAttachments` inside a
  render pass, and nowhere else.
- `CmdResolveImage`: there is no multisampling to resolve.
- `CmdSetDepthBias` and `CmdSetDepthBounds`.

`DynamicState` names `depth_bias` and `depth_bounds`, but the pipeline
takes neither and both features are refused when it is made, so a pipeline
that lists them is made without them.

## Device queries that are absent

- **`GetPhysicalDeviceFeatures`.** There is no feature structure at all. A
  program discovers what a device will not do by being told
  `error_feature_not_present` when it asks for it. The two devices do
  differ - 16 sampled images a stage on the cores against 1 on the V3D, and
  fragment functions of a program's own on the cores only - so what is
  reported of a device is its properties, its limits, its queue family and
  its memory, and nothing else.
- `GetPhysicalDeviceImageFormatProperties`: what an image may be is in
  `CreateImage`'s documentation, and `error_format_not_supported` says when
  it may not.
- `GetRenderAreaGranularity`.
- `FlushMappedMemoryRanges` and `InvalidateMappedMemoryRanges`: no
  non-coherent host memory is offered, so there is nothing to flush.
- `GetDeviceMemoryCommitment`.
- `EnumerateInstanceExtensionProperties` and the other three: there is no
  extension and no layer mechanism. Surfaces and swapchains are simply part
  of the table, not behind an extension, and `CreateScreenSurface` and
  `CreateWindowSurface` take the place of a platform's own.

## In the structures, refused by the implementation

These can be asked for and are answered with `error_feature_not_present`.

| What | Where it is refused |
|---|---|
| Multisampling entirely: `rasterization_samples` above 1, sample shading, alpha-to-coverage, alpha-to-one | `pipeline/creategraphicspipelines.zig` |
| An attachment of more than one sample | `render/createrenderpass.zig` |
| Logic operations: `LogicOp` is fully enumerated, `logic_op_enable` is not taken | `pipeline/creategraphicspipelines.zig` |
| Depth clamp, depth bias, the depth bounds test | `pipeline/creategraphicspipelines.zig` |
| More than one viewport or one scissor | `pipeline/creategraphicspipelines.zig` |
| Colour attachments blended each its own way: with several, all must be identical | `pipeline/creategraphicspipelines.zig` |
| Input attachments and resolve attachments in a subpass | `render/createrenderpass.zig` |
| A depth attachment that loads or stores, and its stencil likewise | `render/createrenderpass.zig` |
| Present modes but `fifo`, though `immediate`, `mailbox` and `fifo_relaxed` are enumerated | `swapchain/createswapchain.zig` |
| Descriptors but `sampled_image`, `uniform_buffer` and `storage_buffer` | `descriptor/_descriptor.zig` |

Two consequences do not appear in that table:

- **Depth does not outlive a render pass.** It lives in the tiles, and
  survives only between subpasses that have the same attachments. Nothing
  reads it back, so there are no shadow maps and nothing deferred.
- **`CmdBindDescriptorSets`' `dynamic_offsets` is never used**, because
  neither dynamic buffer descriptor is taken.

Three more things cannot be asked for at all, having nothing to ask with:

- No geometry shader stage: there is no such bit among `SHADER_STAGE_*`.
- One queue family with one queue, on both devices, which makes
  `SharingMode` nominal.
- A swapchain's images are colour attachments and nothing else, with one
  array layer and one to four images, so they can be neither sampled nor
  copied from.

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

Of textures:

- The sides are powers of two.
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
invocation (`shader.Groups`). So there is no local invocation number, no
memory shared within a group, no barrier and no subgroups; a group runs on
a worker's stack, on any core, in no order. With no `storage_image`
descriptor it writes storage buffers and nothing else. Compute and
tessellation run on the cores whichever device the pipeline was made on.

Tessellation divides evenly only, has no point mode, and its control
function sets nothing but the levels.

## Left out on purpose

Multisampling, logic operations, geometry shaders, several viewports,
sparse memory, events and a pipeline cache are not missing by accident and
are not planned. They cost more than they would give on this hardware, and
both the tiled rasterizer on the cores and the V3D's fixed fragment forms
are built the way they are because of it.
