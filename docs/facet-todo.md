# facet.library: the work list, by where each item stands in Vulkan

What is left to do in facet.library as of **1.74**, each item with where it
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

**Nothing is left here.** Every item this section held has been done, the
last of them in 1.74: the compressed formats are all of BC1 to BC7, the
texel buffers read every format Vulkan 1.0 asks of them, textures are
kept in their own channels and in whole numbers, and a point is as wide as
its vertex says.

What is left of Vulkan 1.0 is in section 3, where each item is bounded by
the hardware or by the shape of the library rather than by the work, and
in section 4, which is the one large piece of work still outstanding - the
QPU shader compiler, and the per-device features that would follow it.
The next revision's work comes from there, from a chip that needs
something in section 2, or from whatever a program asks for and does not
find.

---

## 2. To do when a chip comes in that needs it

Not refused for ever, and not forgotten: refused because **this** hardware
would pay for them and get nothing back. Most of them are feature bits,
and `PhysicalDeviceFeatures` is answered by the *device* - so a driver
written for a chip that has the thing in hardware says yes to it while the
cores and the V3D go on saying no, and no program that asks politely has
to change. That is what the feature structure is for. The two that are
core with no bit of their own - events and a pipeline cache - would simply
start working on a device that brings what they need. Multisampling was a
third, and the one a conformant 1.0 device may not refuse; the cores draw
four samples a pixel since 1.112, and the V3D's is the rest of
docs/facet-vulkan10.md item 61.

The next device the library is likely to meet is an **RDNA 3.5** one, and
most of this table is hardware it has: a blend unit with logic operations
in it, dual-source blending, a geometry stage, sixteen viewports, page
tables for sparse memory, 2x to 8x multisampling with its own resolve, and
several queues. So the column that matters is the last one: what brings the
item in, and what the item costs *here* until then.

| Item | Standing | Why not on this hardware | What brings it in |
|---|---|---|---|
| **Logic operations**, for every attachment | `1.0 feature` (`logicOp`) | They sit where blending sits but are integer operations on the final colour, so they cannot use the blend fast path. Mesa's V3D driver lowers `logicOp` **into the fragment program**, which is the one thing impossible here: the QPUs run no program of ours. So it would be a second blend path on the cores and nothing on the GPU, for the one 1.0 blend feature that predates programmable blending | AMD's blend unit has logic operations in it (which is why RADV answers yes), so an RDNA driver gets them nearly free. The library's side is `logic_op_enable` and `LogicOp`, which are already enumerated and refused in one place |
| **Dual-source blending** (the `SRC1` factors) | `1.0 feature` (`dualSrcBlend`) | Every fragment form writes one colour: the V3D's tile write is literally "render target 0, four half-floats", and `shader.Fragments` carries one colour a quad. 1.51 paid to let a function write several *attachments*; this is two colours for *one* | A chip whose blend unit takes a second source, with a shader stage that can emit it. The SDK's side is one more output convention beside `shader.fragmentOutputs` |
| **Geometry shaders** | `1.0 feature` (`geometryShader`) | The binner's input is a vertex array of known count. A geometry stage turns one primitive into many, so its output wants an allocation sized at run time - a stage and a pass between the vertex work and the binning. Tessellation (1.50) already amplifies, with bounded output and no extra pass. There is no `SHADER_STAGE_GEOMETRY` bit at all; both of its statistics read 0 since 1.43, so a program that counts them is not refused | A chip with the stage in hardware. The library's side is the stage bit, the entry kind in `shader.zig`, and a primitive stream the binner takes from somewhere other than the vertex array |
| **Several viewports and scissors** | `1.0 feature` (`multiViewport`) | A viewport index has to be chosen per primitive in the vertex stage, and the SDK has no slot for one; the tile walk then compares against several rectangles instead of one. One viewport is also what keeps the scissor and the depth bounds a single state | A chip with several viewports (an RDNA one has sixteen), and the use that wants them: one pass into several layers or eyes, which is multiview - Vulkan 1.1, section 5 |
| **Sparse resources** | `1.0 feature` | Memory here is exec's: a block with a physical address, DMA-reachable, bound whole. Sparse wants page-level mapping for each resource and a page table a driver walks, and the V3D's MMU belongs to the firmware. Nothing on an 8 GB board needs an image larger than its memory - the limits are 8192 square and 256 layers | A chip with its own page tables and a driver allowed to write them. Then `QueueBindSparse`, the two sparse queries, and a memory model that maps pages rather than blocks |
| **Events**, and a wait on one inside a command buffer | `1.0 core` | With one queue family of one queue, played in order by one task, a `CmdWaitEvents` is either already satisfied or a deadlock: only the host pair - `SetEvent`, `GetEventStatus` - would mean anything, and a fence already says what it would say | A device with more than one queue, where a wait has something to wait for. Eight calls and eight LVOs, and the player honouring them |
| **A pipeline cache** | `1.0 core` | There is nothing to compile: a pipeline is the create info's state copied into a struct, so the cache would cache a memcpy. The parameter is taken and ignored, which is why no program notices | **The day any device compiles** - the QPU compiler of section 4, or an RDNA back end - a pipeline carries code and a cache earns its name. This one's reason expires on its own |
| **Tessellation point mode** | `1.0 core` | The tessellator's output path builds triangles, or the lines of `isolines`; point mode would be a third path, emitting a point for each tessellated vertex. Points themselves do rasterize - one pixel each - so it is only that path which is missing, for a mode whose use is looking at a tessellation | A chip whose tessellator has the mode, or an hour's work on ours the day somebody wants it. It is the smallest item in this table |

## 3. Vulkan 1.0, bounded by the hardware or by the shape of the library

Not pickable as they stand: each would be a different machine, a different
driver, or a different library.

| Item | Standing | What binds it |
|---|---|---|
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

**Size: about 13,950 Mesa lines to port and about 11,950 facet lines to
write** (item 59 of docs/facet-vulkan10.md, 920 of the facet lines being
items 55 and 60's). Everything else on this list is smaller than step 2 of
it.

### Why step 1 is the one that matters

The QPUs are not the last device without a compiler. An RDNA 3.5 driver
would want the same thing again - a back end of its own, for a wholly
different machine - and so would anything after it. If the input language
is the **library's** (step 1(a): an IR a program's shader is recorded into
at comptime, beside the Zig function the cores run), then each device
after this one costs a back end and nothing else, and a program written
once runs on all of them. If instead each driver invents its own way in,
every device costs the whole of steps 1 to 5 again and programs are
written per device. That is the argument for doing step 1 properly before
any of the rest, however much slower it is to start.

---

## 5. Above Vulkan 1.0: not gaps against 1.0

Listed so that the line is clear. None of these is planned, and none of
them should be called missing. Several of them arrive with the same chip
section 2 is waiting for - subgroups with its waves, multiview with its
viewports, timeline semaphores with its queues - but they are still not
gaps against Vulkan 1.0, and the library answers 1.0.

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
