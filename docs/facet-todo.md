# facet.library: the work list, by where each item stands in Vulkan

What is left to do in facet.library as of **1.58**, each item with where it
bites, what it would take, and **where it stands in Vulkan**, so that a
morning's work is never spent on something Vulkan 1.0 never had.

Its companion is `facet-gaps.md`, which is written for a *program*: what the
library does not have, so that a program need not find out by failing. This
file is written for whoever does the work next. Where the two disagree,
`facet-gaps.md` and the function documentation are the truth and this file
is stale.

**How the standing column reads:**

| Standing | What it means |
|---|---|
| `1.0 core` | Vulkan 1.0's core API has it, with no feature bit to ask for: a gap here is a gap against plain Vulkan 1.0 |
| `1.0 feature` | A core 1.0 feature bit a device may answer no to (`VkPhysicalDeviceFeatures`): facet answers no through `PhysicalDeviceFeatures` the same way |
| `1.0 format` | A core 1.0 format whose support is a format-feature question, which `GetPhysicalDeviceFormatProperties` answers |
| `above 1.0` | An extension or a later Vulkan version: not a 1.0 gap at all, listed so that it is clear which side of the line it falls on |
| `facet's own` | No Vulkan counterpart in either direction |

Nothing in sections 1 to 3 is a defect: every refusal is checked and
answered, and the limits are in the documentation of the call that keeps
them.

---

## 1. Vulkan 1.0, pickable: a revision each

In the order I would do them. "Size" is the shape of the work, not a
promise: small is a day with its tests, medium is a revision of its own,
large wants splitting first.

### 1.1 A cube sampled through a sampler reads inside one face

- **Standing:** `1.0 core`. Seamless filtering across a cube's faces is what
  Vulkan's cube sampling is; a sampler that stops at a face's edge is not it.
- **Where:** `sdk/libs/facet/texture.zig`, the sampler path
  (`sampleBy`, `sampleLayer`, `cubeNear`, `cubeTexel`). The fixed form
  `texture_cube` reads over the seam; `texture_cube_sampled` and
  `texture_cube_array_sampled` (1.53) do not. Away from the seams the two
  agree, so this shows up only on a bilinear sample within half a texel of
  an edge.
- **What it takes:** the four taps of a bilinear sample must come from the
  direction, not from the face's own u and v: map each tap through
  `cubeNear`/`cubeTexel` instead of clamping it inside the face, and mix
  what comes back. The V3D's TMU does this in hardware, so it is a cores
  job only.
- **Size:** medium. Watch the sample cost: this path is already a pixel at
  a time, and `FacetCube`'s V3D tolerance of 5 % exists because the two
  devices choose levels differently.

### 1.2 A 3D texture of levels, sampled through a sampler, reads level 0's slices

- **Standing:** `1.0 core`.
- **Where:** `texture.zig`'s 3D sampler path against `Texture.slicesAt`,
  which the fixed `texture_3d` form uses. A 3D texture has levels of its
  own since 1.46 - half as deep as the one before, never below one slice -
  but the sampler takes the slice from the whole depth at every level, so a
  level past the first reads the wrong slices.
- **What it takes:** the slice count of the level being read, where the
  whole depth is read now; `slicesAt` already answers it.
- **Size:** small to medium. A real wrong answer rather than a missing
  feature, so it ranks above the rest.

### 1.3 A sampled depth image has one level, and is never a volume

- **Standing:** `1.0 core`. Vulkan has no rule against a depth image with
  mip levels; the limit is this library's.
- **Where:** `src/disk/libs/facet/image/_image.zig` (the depth branch of
  `shapeFor` refuses `mip_levels != 1` and a volume),
  `render/createframebuffer.zig`, `driver/cpu/_play.zig` (`planeOf`).
  1.58 gave such an image layers and planes; levels are what is left.
- **What it takes:** a level's rows inside a layer (`layer_bytes` becoming
  a layer's whole pyramid), `depthPlane` carrying the level's own pitch and
  size, a framebuffer drawing into the level its view names, and the
  transfers walking levels as a colour image's already do. A mipmapped
  shadow map is the reason to want it.
- **Size:** medium.

### 1.4 A depth attachment cannot be read as an input attachment

- **Standing:** `1.0 core`. Vulkan takes an input attachment of the depth
  aspect.
- **Where:** `render/createrenderpass.zig` refuses it, and
  `facet-gaps.md` still gives the old reason - a depth lives in the tiles
  and has no rows. Since 1.39 a depth that is stored *does* have rows, and
  since 1.58 it has planes (`_image.depthPlane`) and layers.
- **What it takes:** accept a depth format for an input reference where
  the image is one whose rows are kept; give the view's `rows` the plane
  (which 1.58 already builds), and `shader.TexelFormat` a depth value so
  that `shader.Attachment.at`/`colorAt` can read a 16-bit depth. Deferred
  shading that wants the depth copies it out today
  (`CmdCopyImageToBuffer`).
- **Size:** small to medium - most of the work was done in 1.58.

### 1.5 A subpass cannot read the attachment it is drawing into

- **Standing:** `1.0 core` for the fragment's own pixel: a subpass
  self-dependency with `VK_DEPENDENCY_BY_REGION_BIT` and an input
  attachment of the same image is how Vulkan 1.0 does programmable
  blending. Reading *another* pixel of it is `above 1.0`
  (`VK_EXT_shader_framebuffer_fetch`).
- **Where:** `render/createrenderpass.zig` answers
  `error_initialization_failed`, because an input attachment is read out of
  the image's memory and a subpass's own attachment is not there yet.
- **What it takes:** on the cores, read the *tile* instead of the image for
  a self-referencing reference: `shader.Resources.input` pointing at the
  tile's plane for that one attachment, the pass accepting the reference
  where it names its own colour attachment by region, and the fragment
  function's own place in the tile. The tiles are where the pixel already
  is, so this is cheaper here than the copy it replaces.
- **Size:** medium.

### 1.6 A clear of a float image writes nothing

- **Standing:** `1.0 format`. `CmdClearColorImage` wants
  `FORMAT_FEATURE_TRANSFER_DST`, which these formats claim.
- **Where:** `driver/_transfer.zig`, `texelOf`: the float formats and the
  compressed ones answer null, so the clear is refused.
- **What it takes:** 1.57 wrote the encoders this needs -
  `texture.putFloatTexel`, `partsOfColor` - so a float clear is now the
  colour turned into the format's own bytes and written a texel at a time
  (or a word at a time where the texel is 4 bytes). A compressed image
  stays as it is: nothing here compresses, which is the format and not the
  library, and its `TRANSFER_DST` is for whole blocks.
- **Size:** small.

### 1.7 Texel-buffer formats: `_snorm`, `_srgb`, the packed ones, three channels

- **Standing:** `1.0 format`.
- **Where:** `shader.TexelFormat` (append only - it is an `enum(u8)` a
  program compiles against), `buffer/_bufferview.zig`'s `texelsOf`,
  `driver/_format.zig`'s `describe`, and `shader.Texels.at`/`intAt`.
- **What it takes:** `_snorm` is the `_sint` number over its largest and is
  nearly free beside 1.54's integer grid. `_srgb` wants the transfer
  function on the way out (a table of 256 is enough for 8 bits).
  `a2b10g10r10` and friends are a shift and a mask. Three-channel 8- and
  16-bit formats are the awkward ones - 3 bytes a texel, which almost no
  hardware carries either - and may stay out.
- **Size:** small, and it splits by format.

### 1.8 Textures and storage images of whole numbers, and of smaller channels

- **Standing:** `1.0 format`.
- **Where:** `texture.Format` (a plain enum - **append at the end only**,
  its values moved once in 1.48 and broke every program on the disk),
  `texture.zig`'s `texelColor`/`setParts`/`partsAt`,
  `image/_decode.zig`, `driver/_format.zig`.
- **What it takes:** `r8g8`, 16-bit channels, and the `_uint`/`_sint`
  formats including `r32_uint` and `r32_sint`. The hard half is not the
  memory but the *read*: a texture answers a colour or four floats, and a
  whole number above 1 is not a colour, so a sampled integer image wants an
  integer read the way `shader.Texels.intAt` got one in 1.54 - say
  `shader.Resources.sampled` handing back something with an `intAt` of its
  own - and the sampler's filtering has no meaning for one (Vulkan says
  nearest only).
- **Size:** medium to large. Worth splitting: the unorm ones (`r8g8`, 16-bit
  channels) first, the integer read after.

### 1.9 `unnormalized_coordinates` on a sampler

- **Standing:** `1.0 core`.
- **Where:** `sampler/createsampler.zig` refuses it; coordinates are 0 to 1
  across the texture.
- **What it takes:** carry the bit in `texture.Sampler`, multiply by the
  size where the fraction is used now, and keep Vulkan's restrictions on
  it: nearest only, one level, no compare, clamped edges, no array layer.
  A program reading a texture as a table of values is what asks for it.
- **Size:** small.

### 1.10 A point is one pixel, and no shader writes `PointSize`

- **Standing:** `1.0 core` for `PointSize`; `1.0 feature` for points wider
  than one pixel (`largePoints`).
- **Where:** `driver/_vertices.zig`, `Widening.point`: a point is a
  rectangle half a pixel either way, whatever `line_width` says, and the
  vertex function has nowhere to say a size. Lines do take `line_width` and
  `CmdSetLineWidth`.
- **What it takes:** a place for the size in what a vertex carries
  (`shader.Vertices.output` has the position and the varyings and nothing
  else - this wants a slot, which is an SDK decision), then the widening to
  use it. On the V3D the point size is a packet already written as 1.0
  (`cl.pointSize`).
- **Size:** small, once the SDK slot is decided.

### 1.11 BC4 to BC7

- **Standing:** `1.0 format`, under `textureCompressionBC` - which facet
  says yes to for BC1 to BC3 and no further.
- **Where:** `image/_decode.zig` beside the BC1/BC2/BC3 decoders,
  `texture.Format`, `driver/_format.zig`.
- **What it takes:** BC4 and BC5 are the BC3 alpha block over one and two
  channels and are easy; BC6H (half-float) and BC7 (many modes) are
  substantial decoders on their own. ASTC and ETC1 stay out - ASTC is a
  feature of its own and a far larger decoder, ETC1 is not a Vulkan format.
- **Size:** BC4/BC5 small; BC6H/BC7 medium each.

### 1.12 Events

- **Standing:** `1.0 core`: `CreateEvent`, `DestroyEvent`,
  `GetEventStatus`, `SetEvent`, `ResetEvent`, `CmdSetEvent`,
  `CmdResetEvent`, `CmdWaitEvents`. The one object kind that is absent and
  could exist - a pipeline cache has nothing to cache, sparse memory is
  bound whole.
- **Where:** eight new files and eight LVOs (`sdk/fd/facet_lib.fd`).
- **What it takes:** an object with a flag, the host pair setting and
  reading it, and the player honouring `CmdWaitEvents`. With one in-order
  queue a wait inside a command buffer is either already satisfied or a
  deadlock, so the honest shape is: the host pair works, and a command
  buffer that waits on an event no host has set is refused or returns at
  once. Low value for the work - it is on the list for completeness.
- **Size:** medium, low value.

### 1.13 `max_resource_size` answers the heap, not the image

- **Standing:** `1.0 core` wording:
  `VkImageFormatProperties.maxResourceSize` is what an image of that shape
  may take.
- **Where:** `instance/getphysicaldeviceimageformatproperties.zig` answers
  the largest heap's bytes.
- **What it takes:** the bytes of the largest extent and the most layers of
  that format, from the same rules `CreateImage` keeps - the two already
  share them, so this is one call into `_image.shapeFor`.
- **Size:** trivial.

---

## 2. Vulkan 1.0, left out on purpose

These are not planned. They cost more than they would give on this
hardware, and both the cores' tiled rasterizer and the V3D's fixed
fragment forms are built the way they are because of it. Listed so that
nobody picks one up thinking it was forgotten.

| Item | Standing | Why not |
|---|---|---|
| Multisampling entirely, and `CmdResolveImage` with it | `1.0 core` | Every tile would hold its samples: the memory and the bandwidth are the whole of this rasterizer's budget |
| Logic operations, for every attachment | `1.0 feature` (`logicOp`) | A blend path of its own for something almost nothing asks for |
| Dual-source blending (`SRC1` factors) | `1.0 feature` (`dualSrcBlend`) | Wants a second colour out of every fragment form |
| Geometry shaders | `1.0 feature` (`geometryShader`) | No stage, no bit among `SHADER_STAGE_*`. Its two statistics read 0 since 1.43 |
| Several viewports and scissors | `1.0 feature` (`multiViewport`) | One viewport, one scissor; the bounds and the scissor are the pipeline's or a command's |
| Sparse resources | `1.0 feature` | Memory is bound whole |
| A pipeline cache | `1.0 core` | There is nothing to compile: pipelines are cheap to make. The parameter is taken and ignored |
| Tessellation point mode | `1.0 core` | The tessellator emits triangles, or the lines of `isolines`, and nothing emits a patch's points on their own |

---

## 3. Vulkan 1.0, bounded by the hardware or by the shape of the library

Not pickable as they stand: each would be a different machine, a different
driver, or a different library.

| Item | Standing | What binds it |
|---|---|---|
| A query's counter is 32 bits, held at its highest | `1.0 core` (64 bits) | No 64-bit atomic on every machine the library runs on. A timestamp is 64 bits: one task writes it whole |
| One queue family of one queue, so `SharingMode` is nominal | `1.0 core` | One task plays what is submitted, in the order it was |
| `fifo` is the one present mode | `above 1.0` (`VK_KHR_swapchain`), part of facet's table | A display shows a buffer from its next frame on, and there is no way to ask it for anything else |
| A swapchain's images cannot be sampled | as above | They are rows, not blocks of texels. Copied both ways since 1.43 |
| No compute barrier, no subgroups | `1.0 core` barrier; subgroups are `above 1.0` (Vulkan 1.1) | A group is a loop inside one call on one core, so a barrier is the point between two loops. There is no warp to ballot |
| Nothing orders two writes through a storage image or a storage texel buffer | `1.0 core` (`CmdPipelineBarrier` exists in the table) | Groups run in no order on any core, as in Vulkan without a barrier; there is no atomic either |
| Nothing is checked against an image layout | `1.0 core` | Layouts are taken as given: there is no layout to transition to on either device |
| The cores and the V3D choose a level and its sample point differently | `1.0 core` (implementation-defined) | Which is why `C:test/FacetCube CHECK` allows the V3D 5 % of pixels where the rest allow 0.1 % |
| A texture's width that is not a power of two is laid out by the next one up | `facet's own` | Up to 2 x the memory for the widest levels; the layout is what makes a bilinear sample one read |

---

## 4. The QPU shader compiler

**The largest open item in the library, and the only one that is not a
revision.** It is listed here once, with what it takes, because a dozen
entries in `facet-gaps.md` are the same sentence: *only the cores do this,
the V3D runs no program of the library's.*

### What is there now

`src/disk/libs/facet/driver/v3d/qpu.zig` (407 lines) is a hand-written
encoder for as much of V3D 7.1 as the driver uses - about twenty
instructions, following Mesa's `src/broadcom/qpu/qpu_pack.c` - and seven
**fixed fragment programs** written in it by hand: flat colour, the
vertices' colour, a texture, a texture times the colour, an array layer, a
3D slice, a cube face. The vertex and coordinate programs are generated by
`passThrough`/`vertexProgram` for the varyings a draw carries.
`cl.zig`'s `shaderRecord` points the hardware at them, and `_play.zig`
fills the uniform stream (two words for a sample: the TMU's P0 and P1).

So the V3D draws what those forms cover and hands everything else to the
cores. `CreateGraphicsPipelines` is where that is decided, and the refusal
is the hook a compiler would replace.

### What it unlocks - all of it Vulkan 1.0 core, and all of it per-device today

| What | Feature bit it would turn on |
|---|---|
| A fragment function of the program's own, on the GPU | - |
| Sampling through a sampler | `samplers` |
| Input attachments | `input_attachments` |
| Storage images, and a storage-image descriptor layout | `storage_images` |
| A fixed form that drops pixels (`discard`) | - |
| Several colour attachments written in one call | `several_outputs` |
| `texture_cube_array` and `texture_cube_array_sampled` | `cube_arrays` |
| Pipeline statistics queries | `pipeline_statistics_queries` |
| Compute on the QPUs, in time | - |

### What it takes, in the order it has to happen

1. **An input language, which is the real decision.** A shader here is a
   Zig function of the program, compiled for the host CPU and found through
   a function pointer in an `FCTZ` module: there is no SPIR-V, no GLSL and
   no Zig compiler on the board, so the QPU cannot be handed the program's
   own code. Three ways out:
   - **(a) An IR beside the function.** `sdk/libs/facet/shader.zig` grows a
     comptime builder - a little SSA or expression graph recorded into the
     module beside the entry - so a program writes its shader once and
     ships both: the Zig function for the cores and the graph for whatever
     can compile it. This is the answer; it is also the part that touches
     every program.
   - **(b) QPU code of the program's own.** The program ships instructions
     it built itself and the driver only links them: uniforms, varyings,
     TMU configuration, the thread switch. A sharp escape hatch for a demo,
     no use to a program that wants to run on both devices.
   - **(c) More fixed forms.** What 1.28 to 1.53 did by hand, one family at
     a time. It is where we are, and it does not reach a program's own
     function.
2. **The instruction set past the subset.** The full add and mul opcode
   tables, small immediates, the pack and unpack modifiers, condition flags
   and `setmsf`/flag pushes for a discard, branches and their three delay
   slots, the SFU operations (recip, rsqrt, exp, log, sin), the tile-buffer
   writes with a configuration of their own, `ldunifa`, and 7.x's
   register-file-only model - no accumulators, everything rf0 to rf63.
   `qpu.zig`'s encoder is the right shape to grow into this, and its tests
   already check encodings against Mesa's disassembler samples.
3. **A register allocator.** A threaded fragment program has 16 registers,
   which is why every `fadd` in the fixed programs writes below rf16 (there
   is a test for it). A compiler wants liveness, allocation and spilling -
   and there is no stack on a QPU, so a spill goes to the VPM or through
   the TMU.
4. **A scheduler that honours the latencies the hand-written programs
   encode by hand.** A varying's constant reaches rf0 only two
   instructions after `ldvary`; `ldtmu` comes after the write to TMUS, and
   only once the sample is started; `thrsw` happens two instructions after
   it is written, and two thread switches in a row are what say "last
   section"; the scoreboard wait sits in that last section, and without it
   a pixel reaches the tile buffer ahead of one drawn before it at the same
   place and **the renderer hangs**. These are the rules that cost days if
   the scheduler gets them wrong.
5. **The shader record and the uniform stream, generated.** Today
   `shaderRecord` is given a varyings count and three program addresses,
   and the uniforms are two words where a sample needs them. A compiled
   program needs both built from what the IR reads: push constants,
   descriptor pointers, every texture's P0/P1, and the order the fragment
   reads its varyings in - which the binner writes in the order the vertex
   program wrote them, so the compiler and `_vertices.zig` have to agree.
6. **Where it lives.** In the driver module, `LIBS:facet/v3d.fdriver`, so
   it ships with the device and not with the library, and runs when a
   pipeline is made. The library's side of it is the IR in the SDK and the
   refusal in `CreateGraphicsPipelines` that becomes a call.
7. **How it is tested.** `qpu.zig`'s unit tests for the encodings; the IR
   run on the cores as well, so that one shader's two paths can be compared
   picture against picture (`C:test/FacetCube CHECK V3D` and the probe's
   checks are the shape of it); and a form at a time brought over, the
   cores staying the fallback for anything the compiler will not take.

### How I would split it

1. The IR and its host interpreter, with the cores running the IR: proves
   it says what programs want to say, and ships value on its own.
2. The encoder's breadth, with tests against Mesa's samples.
3. The allocator and the scheduler, on the simplest form there is (flat
   colour), checked against the hand-written one instruction for
   instruction.
4. Fragment forms, one family at a time, each with its probe checks and its
   picture check; discard and samplers first, since those are what send
   most draws to the cores today.
5. Compute on the QPUs, if ever: it wants the whole of the above plus the
   dispatch path.

**Size: months, not a revision.** Everything else on this list is smaller
than step 2 of it.

---

## 5. Above Vulkan 1.0: not gaps against 1.0

Listed so that the line is clear. None of these is planned, and none of
them should be called missing.

| Item | Where it lives in Vulkan |
|---|---|
| A border colour of the program's own choosing | `VK_EXT_custom_border_color` - facet has all six of 1.0's |
| Reading another pixel of the attachment being drawn | `VK_EXT_shader_framebuffer_fetch`, `VK_EXT_rasterization_order_attachment_access` |
| Subgroups: ballot, shuffle, a subgroup size | Vulkan 1.1 |
| Multiview | Vulkan 1.1 - 1.58's layered depth is the memory for it, not the feature |
| Timeline semaphores | Vulkan 1.2 |
| Descriptor indexing, update-after-bind | Vulkan 1.2 |
| Buffer device addresses | Vulkan 1.2 |
| Dynamic rendering, without render pass objects | Vulkan 1.3 |
| Push descriptors | `VK_KHR_push_descriptor` |
| Transform feedback | `VK_EXT_transform_feedback` |
| Shader atomics past what a group's loop gives | Vulkan 1.1 and its extensions |
| ASTC | `1.0 feature` (`textureCompressionASTC_LDR`), far larger than the BC decoders; out for its size, not its standing |

---

## 6. Where facet goes past Vulkan 1.0

The list would be dishonest without this half: these have no Vulkan
counterpart, and a program that uses one is a facet program.

| What | Since (facet's own revisions) |
|---|---|
| A shader is a Zig function in an `FCTZ` module, called through a pointer - no compiler anywhere | 1.0 |
| `SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER` with `shader.fragmentOutputs`: a subpass's colour attachments written in one call | 1.51 |
| `PipelineColorBlendStateCreateInfo.attachment_constants` and `CmdSetBlendConstantsAt`: blend constants for each attachment | 1.51 |
| `IMAGE_CREATE_PACKED_TEXELS`: an 8888 texel kept in its word rather than spread over 64 bits | 1.48 |
| `PIPELINE_CREATE_DEPTH_PREPASS`: the depth settled before any fragment function runs | 1.1 |
| A colour attachment written through as a storage image, its rows being the texture | 1.56 |
| A depth attachment's planes as two textures over the same rows, `texture.Texture.linearBy` and its `stride` | 1.58 |
| `CreateScreenSurface` and `CreateWindowSurface` in place of a platform's own surface extension | 1.0 |
| `PhysicalDeviceFeatures` as a structure of facet's own: a field wherever a create call can refuse something | 1.24 |

---

## 7. Working notes

The pattern every revision above should follow, and the route that works:

1. Implement, with the host tests beside it
   (`src/disk/libs/facet/tests/`): `./zig build test`.
2. A version note in `src/disk/libs/facet/facet_version.zig` and
   `LIBRARY_REVISION` bumped - what changed, what stays, and why.
3. `docs/facet-gaps.md` where the gap is described, and this file where the
   item is listed.
4. The contracts in the call files that changed (SYNOPSIS, SINCE, INPUTS,
   RESULT, BEHAVIOR, CONTEXT, OWNERSHIP, NOTES, BUGS, SEE ALSO, EXAMPLES),
   then `./zig build autodoc` - `./zig build test` fails if the generated
   reference is stale.
5. Checks in `src/disk/c/test/raster/facetprobe.zig`, and its `$VER`
   bumped.
6. The board: build for `rpi_cm5`, hand the package out with
   `./zig build serve -Dboard=rpi_cm5 -Dserve-port=8099`, then on the
   board `C:net/HTTPGet http://<pc>:8099/system/... TO RAM:...`, `Copy`
   into `LIBS:`, `LIBS:facet/` and `SYS:c/test/<name>`, `Avail FLUSH`.
   **Not** plain `Update FROM`: this tree's package is not the one the
   board was installed from.
   Whenever an SDK struct changes shape or an SDK enum's values move,
   replace **every** `facet*` program on the disk as well as the library
   and `v3d.fdriver` - 1.48 moved `texture.Format`'s values and 1.58 added
   a field to `texture.Texture`, and a stale program reads a texture the
   new library made.
7. Verify on the board: `C:test/FacetProbe` (527 checks at 1.58, both
   devices), `C:test/FacetCube CHECK` (V3D: 15100 the same, 3436 off by 2
   or less, 664 by more, 79 at worst) and `CHECK CORES` (19200 of 19200),
   `C:test/FacetMany` (11.2 to 11.7 ms), `C:test/FacetBoth` (11 / 8 / 11 /
   11 pixels apart).
8. Commit on `rpi-cm5`, fast-forward `main` onto it, push both.
