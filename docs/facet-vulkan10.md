# facet.library to Vulkan 1.0: the list

**The decision this document serves, taken 2026-11-06: facet stays 100%
compatible with Vulkan. We are not defining a new standard.** Where Vulkan
specifies a struct, an enum, a name, a result code, a limit or a feature
bit, facet uses Vulkan's. A divergence is not a design choice to be
documented; it is work on this list.

Two refinements were taken with it:

1. **Vulkan's API surface, the Amiga binding.** Identical structs, enums,
   names, semantics and result codes, still called through the LVO table.
   A drop-in `libvulkan.so.1` was considered and *deliberately not* chosen
   for now, so the Khronos CTS is not yet the measure. The items it would
   want are listed at the end, under what they are: deferred by choice,
   not out of reach.
2. **Finish the compiler, no fallback.** A shader the V3D cannot compile
   is a defect to close, not a capability to advertise. So the V3D's
   compiler is on the critical path rather than beside it, and the feature
   bits that exist to say "this device only runs a fixed set of shapes"
   are temporary.
3. **The API is not frozen.** PowerOS is at v0.2, so a changed signature,
   a changed structure or a shifted `_driver.stamp` costs nothing but a
   rebuild: the library and the driver module always ship together in one
   package, and nothing outside this tree depends on either shape. No item
   below should be made worse, or scheduled as though it were expensive,
   to preserve an ABI. A stamp change is still worth *reporting*, because
   the board's `LIBS:facet/v3d.fdriver` goes stale and both files have to
   be replaced in the same `C:Update` - a deployment fact, not a design
   constraint.

`facet-gaps.md` is the companion to this: it records what is absent and
why. This one records what to do about it, in an order. Where the two
disagree, `facet-gaps.md` is older - it is stamped 1.74 and its headline
claim, that there is no shader compiler, has been false since 1.76.

## What is already right, which is most of it

It would be easy to read the length of this list as "facet is not very
Vulkan". The opposite is true, and it is worth saying first because it
decides how the work is shaped.

**The structs are Vulkan's.** `ImageCreateInfo` is `VkImageCreateInfo`'s
thirteen members in Vulkan's order - flags, image type, format, extent,
mip levels, array layers, samples, tiling, usage, sharing mode, the queue
family count and its pointer, initial layout - and the rest follow the
same rule. **The enums carry Vulkan's numbers**, not facet's:
`r5g6b5_unorm_pack16` is 4, `r8_unorm` is 9, `r8g8b8a8_unorm` is 37,
`b8g8r8a8_unorm` is 44, which are `VK_FORMAT_*`'s own values.
`Result` is `enum(i32)` with Vulkan's codes where they overlap.

So the gap is not an API of facet's own. It is:

- `sType` and `pNext` left out of every structure, deliberately;
- three structures that *are* facet's own shape rather than Vulkan's -
  `PhysicalDeviceFeatures`, `PhysicalDeviceLimits`,
  `PhysicalDeviceProperties`;
- breadth: limits, formats, commands and capabilities that are absent or
  below Vulkan's floor;
- a handful of refusals Vulkan does not permit.

The first and the third are additive. The second is where "no new
standard" bites hardest, and it is near the top of the list for that
reason.

## The numbers

Measured against the tree at 1.79. Every count on the left was taken from
the source; every requirement on the right came from the Vulkan 1.0
specification, which is not in this tree - there is no `vk.xml` and no
`vulkan_core.h` anywhere under it.

**That last sentence was read for a long time as meaning the right-hand
column could not be checked. It only meant it could not be checked *from
the tree*.** This machine has the registry header installed, because
`scripts/vulkan-check.sh` compiles against it, and the header is the
registry's own output. Since 1.82 `scripts/vulkan-struct-check.sh` reads it
and holds facet's four physical-device structures against it member for
member; the counts below were confirmed by it, 106 and 55 exactly.

| | facet 1.79 | Vulkan 1.0 |
|---|---|---|
| jump table entries | 126 | - |
| of those, core commands | 113 | ~137 |
| core commands absent | **24** | - |
| `PhysicalDeviceFeatures` | 49 fields, facet's names, Zig `bool` (**1.82: Vulkan's 55 `Bool32`**) | 55 fields, `VkBool32` |
| `PhysicalDeviceLimits` | 26 fields (**1.82: Vulkan's 106, in Vulkan's order**) | 106, measured from the header |
| limits below the required minimum | **9** | - |
| required limits with no field at all | **~50** | - |
| mandatory colour-attachment formats | 3 | 38 |
| mandatory vertex-attribute formats | 6 | 45 |
| 24/32-bit depth format | none | required |
| combined depth+stencil format | none | required |
| samples per pixel | 1, and `samples != 1` refused at CreateImage | 4 required |
| feature fields differing between the cores and the V3D | 20 | - |

`facet-gaps.md` says 124 entries, 2 absent commands and 16 differing
fields. All three are wrong, and the first was wrong when it was written:
the `.fd` has not changed since 1.51. Its "137 core entry points, facet
has 124" double-counts thirteen non-core names - ten WSI calls,
`CreateScreenSurface`, `CreateWindowSurface` and `CmdSetBlendConstantsAt`.

Two things on that table deserve calling out. **`samples != 1` is refused
at image creation, and no Vulkan 1.0 feature bit permits that** - 4x
multisampling is required of every implementation, so this is not a
feature to add but a floor to reach. And `PhysicalDeviceFeatures` is wrong
three ways at once: the names are facet's, the count is 49 against 55, and
the fields are Zig `bool` where `VkBool32` is a `uint32_t` - 49 bytes
against 220.

## The list

These are the items that serve the decision above, in the order the
analysis put them. Items marked *critical path* are the ones the second
refinement - finish the compiler, no fallback - moves onto the main line.

**Items 2, 3, 4, 5 and 7 were done in revision 1.80, item 78 in 1.81,
items 14, 16, 49 and 77 in 1.82, item 52's half of two in 1.83, item 18
in 1.84, item 19 in 1.85, item 21 in 1.86, item 28's half of two in 1.87,
items 82 and 83 in 1.87 and 1.88 - both found while doing other items -
item 61's first row of eight in 1.89, item 17's half of two in 1.90,
item 22's half of two in 1.91, item 83's open question, answered from
Mesa, in 1.92, item 45 in 1.93, item 44 in 1.94 and item 84 in 1.95.**
Each
carries a *Done* note below saying what was actually built and where the
item's own description turned out to be wrong - and several did. Things
found while doing them became the items at the end of the list: 77 and 78
from 1.80 and 1.81, and 79, 80 and 81 from 1.82.

Items 52, 28, 17 and 22 are the ones split between devices: the cores draw
every sampler as of 1.83, sample at a constant texel offset as of 1.87,
carry 64 varyings as of 1.90 and take framebuffers of 256 layers as of
1.91, and the V3D does none of the four - so the magenta item 52 is about
now belongs to item 54 alone, item 28's remainder is a QPU back end that
refuses the operand at pipeline creation, item 17's is a vertex program
that keeps its varyings in registers and so stops at eight, and item 22's
is a render list played once a frame rather than once a layer.

None of the four is the hardware's limit. Mesa's v3dv runs Vulkan on this
same V3D 7.1 with 64 varyings, texel offsets of -8 to 7 and 256
framebuffer layers (`src/broadcom/vulkan/v3dv_device.c`), so each
remainder is the port of named Mesa code, and the items say which. Until
then the V3D's limit is **derived from its own compiler or driver** rather
than written down, so the number cannot drift from what the device
accepts. That pattern started as item 28's answer to one field and is now
how this split is done.

Item 16's *Done* note is the one to read first if you are picking this up,
because the limits reshape it settles is what items 17 to 30 were waiting
for: they are value changes in a structure that has the fields now.

The line and file references in the evidence blockquotes were measured at
commit `af42edb7`, before 1.80 moved code around. They are evidence of
what was found, not a current index: read them as "this is where it was",
and grep for the name if a number no longer lands.

### 1. Re-base docs/facet-gaps.md and facet-todo.md on 1.79 and correct the four headline numbers

*documentation* &mdash; structural, small, also serves the shim

The document is stamped 1.74 and four of its numbers are wrong at 1.79. The jump table holds 126 entries, not 124 — and that was already wrong when the doc was written, since the fd has not changed since 1.51. "Of Vulkan 1.0's roughly 137 core entry points, facet has 124" double-counts 13 non-core names (10 WSI, CreateScreenSurface, CreateWindowSurface, CmdSetBlendConstantsAt), so core coverage is 113 of ~137 and 24 core commands are absent, not 2. "Sixteen of its fields differ between the cores and the V3D" is 20. And the headline "there is no shader compiler ... no SPIR-V, no GLSL, and no compiler for the QPUs" is false on every clause. This is first because eleven later sections lean on that one sentence and every conformance claim rests on the counts.

> docs/facet-gaps.md:11-12, :16-22, :25, :33-35, :41. Measured: `grep -vE '^\s*(//|##|$)' sdk/fd/facet_lib.fd | grep -cE '^\S+ +[A-Za-z_][A-Za-z0-9_]*\('` -> 126; `grep -c '^fn lvo' src/disk/libs/facet/facet_lvo.zig` -> 126; facet_version.zig:1217 LIBRARY_REVISION = 79; wc -l compile.zig 2511, ir.zig 714, spirv.zig 745, qpu.zig 460; scripted diff of cpu.zig:106-215 against driver/v3d/driver.zig:138-256 -> 49 fields, 20 differing, 3 false on both.

Found independently by: doc-staleness, entry-points, objects-commands, features, conformance-path (5 strands, independently).

### 2. Report maxSamplerAnisotropy as 1 on the V3D

*limits / samplers* &mdash; conformance-blocking, small

One line. The V3D reports the library-wide 16 in the same describe() call that sets sampler_anisotropy = false. The spec's unsupported value for maxSamplerAnisotropy is 1, so 16 is a non-conformant report in the generous direction: a program that trusts the limit gets a refusal. Cheapest item on the list.

> src/disk/libs/facet/driver/v3d/driver.zig:130-131 `.max_sampler_anisotropy = _instance.max_sampler_anisotropy` (= 16, _instance.zig:52) with `.sampler_anisotropy = false` at :155; cores set it true at cpu.zig:120. Verified by reading both describe() blocks.

**Done in 1.80**, and it was two lines, not one. The spec reading was
confirmed: the Limit Requirements table gives feature-dependent limits two
required values, and `maxSamplerAnisotropy` is `1 | 16 | min` - 1 is the
required value when `samplerAnisotropy` is false, so reporting 1 is right
and not a conformance regression. The second line is the one the item
missed: `CreateSampler` held `max_anisotropy` to the library's cap of 16
and its BEHAVIOR block claimed it held it to
`PhysicalDeviceLimits.max_sampler_anisotropy`, so dropping the V3D's
report to 1 alone would have made that doc false and left a sampler
holding 16 on a device whose limit said 1. `anisotropyOf` now takes the
device's own limit. Tested in `createsampler.zig` (ten cases, including a
NaN and a limit of 0).

### 3. Stop the V3D advertising a sampled D16_UNORM it then refuses, and give format_properties the device

*formats / driver interface* &mdash; conformance-blocking, small

Two linked fixes. The `.d16_unorm` arm of describe() sets SAMPLED_IMAGE and SAMPLED_IMAGE_FILTER_LINEAR unconditionally, outside the `keeps_blocks` guard every other device-dependent arm uses, while the V3D answers sampled_depth = false and CreateImage refuses a sampled depth image there — so the format query contradicts the refusal. The root cause is that `Ops.format_properties` is a function of the format alone, and one bool stands in for four feature bits with no access to sampled_depth. Change the signature to take the physical device (or its features) and drive describe() off the feature struct. Gating turns the lie into an honest conformance failure that only the TMU work closes, so do both.

> src/disk/libs/facet/driver/_format.zig:75-79 — verified: the d16_unorm arm has no `if (keeps_blocks)` and no sampled_depth test, unlike the compressed arms at :87-100. src/disk/libs/facet/driver/_driver.zig:71 `format_properties: *const fn (format: facet.Format) callconv(.c) facet.FormatProperties`; _format.zig:11-22 the two wrappers differ only in one bool; driver/v3d/driver.zig:54 and :178; image/_image.zig:433.

**Done in 1.80**, wider than the item describes, and with one consequence
the item did not see.

`Ops.format_properties` takes the physical device, both drivers point at
the one `_format.properties`, and the one bool is gone: each of
`kept_compressed`, `kept_floats`, `wide_channels` and `whole_textures` now
answers for its own formats. D16_UNORM's sampled bits follow
`sampled_depth`.

The item stopped at D16_UNORM, but the same contradiction was in the
stencil arm: `s8_uint` and `d16_unorm_s8_uint` shared one arm promising
DEPTH_STENCIL_ATTACHMENT unconditionally, while `CreateRenderPass` refuses
an attachment of the first without `stored_stencil` and of the second
without `stored_both` - and the V3D has the one and not the other. They
are two arms now, each reading its feature.

The consequence: a driver call gained a parameter, and a pointer is the
same size whatever it points at, so `_driver.stamp` did not change and a
stale `LIBS:facet/v3d.fdriver` on the board would have been loaded and
then called with the wrong arguments. The shape sum now reads each call a
field points at - its parameter count and the measure of each parameter
and of its answer - so that module is turned away instead. Two types of
the one size and alignment still read alike; the doc says so.

Confirmed while doing it, and it is the item's own last sentence: **Vulkan
1.0 does require FORMAT_FEATURE_SAMPLED_IMAGE of D16_UNORM** (the Required
Format Support table; a Mesa bug was filed and fixed for exactly this in
2017). Linear filtering is *not* required. So the V3D is short of
conformance here either way - it is now visibly short rather than lying
about it, and only the TMU learning a depth format closes it. That is
tracked by item 56 and named here so nothing records the gating as the end
of the matter.

Tested in `_format.zig`: four tests over synthetic feature structs, one of
them asserting that no single bool could have answered for all four kept
features.

### 4. Add the five missing VkResult codes and stop returning an extension code from a core path

*result codes* &mdash; conformance-blocking, small, also serves the shim

facet.Result is enum(i32), non-exhaustive, and its values are Vulkan's where they overlap — but 3 (VK_EVENT_SET), 4 (VK_EVENT_RESET), -6 (LAYER_NOT_PRESENT), -7 (EXTENSION_NOT_PRESENT) and -9 (INCOMPATIBLE_DRIVER) are absent, and each is required by a command on this list. CreateInstance answers error_initialization_failed where Vulkan requires INCOMPATIBLE_DRIVER for an apiVersion it cannot provide. Separately, CreateShaderModule returns error_invalid_shader_nv (-1000012000), an extension result code a core-only implementation must not return — remap it or add the code to the shim's translation. Purely additive thanks to the `_` tag.

> Verified by enumerating the enum: success=0, not_ready=1, timeout=2, incomplete=5, -1..-5, -8, -10, -11, -12, error_out_of_pool_memory=-1000069000, error_invalid_shader_nv=-1000012000, plus the four surface/swapchain codes. No 3, 4, -6, -7 or -9. sdk/libs/facet/facet.zig:82-122; facet.zig:146-148 for the apiVersion refusal.

Found independently by: entry-points, conformance-path.

**Done in 1.80 — six codes, not five, and the extension-code half of the
item was wrong.**

The five are there, and so is `error_unknown` (-13), which the item
missed: the header carries it with no version tag, every call that answers
a result being allowed to return it. Nothing here answers it yet.
CreateInstance gives `error_incompatible_driver`.

The item says CreateShaderModule "returns error_invalid_shader_nv
(-1000012000), an extension result code a core-only implementation must
not return — remap it". That was not done, and on checking it should not
be: **Khronos's own reference page for `vkCreateShaderModule` does list
VK_ERROR_INVALID_SHADER_NV**, because `VK_NV_glsl_shader` contributes it
for exactly this meaning. Core 1.0 without that extension lists only
success and the two out-of-memory codes - words that are not SPIR-V are
undefined behaviour there rather than a reportable error - so facet is
answering something core 1.0 does not list. But the alternative is
inventing a facet-private number for "this is not a shader", which is
precisely what the decision at the top of this document forbids. Keeping
Khronos's number and letting the shim translate it is the compatible
choice. The enum's doc comment says this, and the one false claim it made
is fixed: `error_invalid_shader_nv` is **one of two** such codes, not the
only one.

The other is `error_out_of_pool_memory` (-1000069000) at
`allocatedescriptorsets.zig:63`, a `VK_KHR_maintenance1` code promoted in
Vulkan 1.1, where core 1.0's `vkAllocateDescriptorSets` lists
`VK_ERROR_FRAGMENTED_POOL`. Same reasoning, same decision, now recorded
rather than unnoticed.

### 5. Refuse specialization_info instead of silently ignoring it

*pipelines* &mdash; conformance-blocking, medium, also serves the shim

PipelineShaderStageCreateInfo.specialization_info exists as an untyped pointer and is read by nothing in the tree — not honoured and not refused, so a pipeline silently ignores the constants it was given, which is the one failure mode worse than a refusal. Minimum honest step is error_feature_not_present on a non-null pointer; the real step is specialising the SPIR-V before compiling it, and the CTS has a large dEQP-VK.pipeline.*.spec_constant family.

> Verified: `grep -rn specialization_info sdk/libs/facet/ src/disk/libs/facet/` returns exactly one line, sdk/libs/facet/facet.zig:1720 `specialization_info: ?*const anyopaque = null,`.

**The minimum honest step was done in 1.80**, with one correction to the
item's wording. The item asks for "`error_feature_not_present` on a
non-null pointer"; refusing on the pointer alone rejects legal Vulkan. A
`VkSpecializationInfo` with `mapEntryCount` 0 specializes nothing, and a
program that fills the struct for every stage and leaves it empty where it
has no constants is doing nothing wrong. The refusal is on
`map_entry_count != 0`, in both CreateGraphicsPipelines and
CreateComputePipelines. The real step - specialising the SPIR-V before
compiling it - is still open and still has the large
`dEQP-VK.pipeline.*.spec_constant` family behind it.

### 6. Say somewhere that the V3D compiles SPIR-V, because the feature contract is now broken

*feature query* &mdash; conformance-blocking, medium

After: Re-base the gap documents on 1.79

The library's stated contract is "a field wherever a create call can refuse something, so a program can ask instead of being told". On the V3D that no longer holds: makePipeline compiles a program's own SPIR-V and draws with it, and refuses a pipeline whose words the back end cannot compile or whose compiled varyings disagree with the entry — with no feature field predicting either. Worse, own_fragment_functions and samplers are both still false there although the device now runs a program's own fragment shader and samples through the bound sampler. Needs either a capability field (compiles_spirv, plus a way to say what the profile covers) or a documented "create the pipeline and read the refusal" contract, and the two fields restated as meaning "without SPIR-V words" rather than "never".

> Verified side by side: src/disk/libs/facet/driver/v3d/driver.zig:443-451 `if (fixed.kind == .none) { if (pipeline.fragment_words.len == 0) return .error_feature_not_present; return compiled(pipeline); }` against :143 `.own_fragment_functions = false` ("Only the fixed forms have QPU programs") and :154 `.samplers = false` ("there is no program that reads a sampler"); refusals at :474 and :478. `grep -n spirv sdk/libs/facet/facet.zig` finds only SHADER_MODULE_CREATE_SPIRV at :1710 — no capability field.

Found independently by: features, semantics, limits, doc-staleness (4 strands).

### 7. Fix the small vocabulary gaps: eight stage/access bits, one image layout, one parameter type

*SDK constants / signatures* &mdash; feature-gap, small

Three trivial additions, grouped because each is a name a Vulkan-ported program writes and does not find. PIPELINE_STAGE_ lacks DRAW_INDIRECT (1<<1), TESSELLATION_CONTROL_SHADER (1<<4), TESSELLATION_EVALUATION_SHADER (1<<5), GEOMETRY_SHADER (1<<6) and COMPUTE_SHADER (1<<11); ACCESS_ lacks INDIRECT_COMMAND_READ (1<<0), INPUT_ATTACHMENT_READ (1<<4) and SHADER_WRITE (1<<6) — and indirect draws, tessellation, compute, input attachments and storage images all exist, so these name features facet already has. ImageLayout skips value 4 (depth_stencil_read_only_optimal). And CmdClearDepthStencilImage takes `u32 layout` where its five sibling commands take `facet.ImageLayout`; ImageLayout is enum(u32) so that one is ABI-identical and breaks nothing. Since the masks are ignored, all of this is source compatibility only.

> sdk/libs/facet/facet.zig:1403-1414 (stage bits 0,2,3,7-10,12-16 defined; 1,4,5,6,11 skipped), :1417-1430 (access bits 1,2,3,5,7-16; 0,4,6 skipped), :942-953 (ImageLayout 0,1,2,3,5,... — 4 skipped); sdk/fd/facet_lib.fd:264 against :242.

Found independently by: objects-commands, entry-points.

**Done in 1.80**, all four parts, plus one name the item did not count.

The eight stage and access bits and `depth_stencil_read_only_optimal` are
in. `SHADER_STAGE_GEOMETRY` (0x08) was missing too, which matters more
than the rest of its family: `SHADER_STAGE_ALL_GRAPHICS` is 0x1F and has
always *included* that bit with no name for it, so a program masking
against it was reading a bit it could not spell.

`CmdClearDepthStencilImage` takes `facet.ImageLayout`. The authority for
that signature is `sdk/fd/facet_lib.fd`, not the generated
`sdk/interface/facet.zig`, so the change goes in the `.fd` and
`./zig build fd` regenerates the interface. Twelve call sites passed a
bare `0` and now pass `.undefined`; the parameter is discarded in the
body, so nothing else moved, and `ImageLayout` is `enum(u32)`, so the ABI
is unchanged.

### 8. Record the refusal surface the gap list has never covered

*documentation* &mdash; structural, medium

After: Re-base the gap documents on 1.79

Three things no document records. (1) CreateShaderModule's two-tier validation, added at 1.75: words no device could run (bad header, a count that walks off the end, an instruction that is not one) get error_invalid_shader_nv, while anything well formed but beyond this device is kept and refused later at the pipeline — a program needs that distinction to tell its own bug from this device's limit. (2) The compiled path's refusals, now the commonest way a V3D pipeline is turned down: no fixed form and no words, words the back end cannot compile (eighteen named reasons), compiled varyings disagreeing with the entry. (3) Since 1.79 a sampler `texture.samplingOf` cannot answer for is not refused at all on either device for a generated pipeline — the texture is dropped and the pixel painted shader.missing (0xFFFF00FF), which falsifies the document's "every refusal is checked and answered with error_feature_not_present".

> src/disk/libs/facet/shader/createshadermodule.zig:98-154; src/disk/libs/facet/driver/v3d/compile.zig:126-180 (the Error set), driver.zig:450, :474, :478; sdk/libs/facet/texture.zig:430-461 and ir.zig:586-597; docs/facet-gaps.md:45-47, verified verbatim: "Nothing below is a defect: every refusal is checked and answered with `error_feature_not_present`". `grep -n CreateShaderModule docs/facet-gaps.md` -> no match.

Found independently by: doc-staleness, semantics.

### 9. Add VkEvent and its eight commands

*entry points / synchronisation* &mdash; conformance-blocking, medium, also serves the shim

After: facet.Result gaining event_set = 3 and event_reset = 4

Eight entry points and eight LVO slots, none of which exists: CreateEvent, DestroyEvent, GetEventStatus, SetEvent, ResetEvent, CmdSetEvent, CmdResetEvent, CmdWaitEvents. Core 1.0 with no feature bit, so a conformant implementation cannot omit them. Needs a two-field struct in sync/_sync.zig beside Fence and Semaphore (both are bare exec.Waitable), five host calls, three new _stream.Op values with their recorders, and both players honouring them where `.barrier => {}` sits — the wait arm blocking the queue task on the waitable. Adding to _stream.Op changes _driver.stamp, so the V3D driver module on the SSD must be rebuilt in lockstep or it refuses to load. The gap documents' reason — that only a multi-queue device gives events something to do — is not merely stale but wrong: a host SetEvent releasing a pending CmdWaitEvents is the spec's own case.

> Verified: `grep -icE 'event' sdk/fd/facet_lib.fd` -> 0; src/disk/libs/facet/sync/ holds only fence and semaphore files; facet.Result has no 3 or 4; src/disk/libs/facet/command/_stream.zig:23-62 has no event op; driver/cpu/_play.zig:176 and driver/v3d/_play.zig:225 are both `.barrier => {}`; driver/_driver.zig:147 sums every _stream.Op field into the module stamp. docs/facet-gaps.md:457-465, docs/facet-todo.md:73.

Found independently by: entry-points, objects-commands, conformance-path (3 strands).

### 10. Add the pipeline cache's four commands, and make the cache real

*entry points / pipelines* &mdash; conformance-blocking, medium, also serves the shim

After: PhysicalDeviceProperties.pipeline_cache_uuid

CreatePipelineCache, DestroyPipelineCache, GetPipelineCacheData, MergePipelineCaches. Core 1.0, no feature bit. The object is already declared and the parameter already plumbed through both pipeline-create calls, so the cheap form is a cache that caches nothing plus a valid 32-byte header from GetPipelineCacheData — which means PhysicalDeviceProperties must first gain pipeline_cache_uuid. The real form now has something to hold: the blob wants the library revision, the _driver.stamp and the device id so a cache from another build is rejected rather than trusted, and the pipeline-create calls want a lookup by a hash of the stage's SPIR-V. Its own justification ("pipelines are cheap to make here, because there is nothing to compile") expired at 1.76: a V3D pipeline with words now takes a Work block, runs the back end and allocates V3D memory that lives as long as the pipeline.

> Verified: the only `PipelineCache` occurrences in sdk/fd/facet_lib.fd are the two create-pipeline parameters at :149 and :228 — no Create/Destroy/GetData/Merge anywhere. sdk/libs/facet/facet.zig:1683 `pub const PipelineCache = opaque {};`; facet.zig:245-255 PhysicalDeviceProperties has no pipeline_cache_uuid; driver/v3d/driver.zig:464-508 `fn compiled`. docs/facet-gaps.md:467-474 (stale reason), docs/facet-todo.md:74 ("This one's reason expires on its own").

Found independently by: entry-points, objects-commands, conformance-path (3 strands).

### 11. Add FlushMappedMemoryRanges and InvalidateMappedMemoryRanges as the no-ops they would be

*entry points / memory* &mdash; conformance-blocking, small, also serves the shim

Two core 1.0 commands that must be present and callable even when every host-visible memory type is HOST_COHERENT, in which case they legally return VK_SUCCESS after checking each range against its mapping. Needs VkMappedMemoryRange (absent) and two LVO slots, plus non_coherent_atom_size in the limits — mandatory even though it is only meaningful once a non-coherent type exists. The documents' premise is correct and their conclusion is not: Vulkan requires the commands to exist, not merely to have work to do.

> Verified: the fd has MapMemory (:41) and UnmapMemory (:43) and no flush/invalidate; both drivers always set HOST_VISIBLE|HOST_COHERENT (driver/cpu/cpu.zig:262, driver/v3d/driver.zig:278); `grep -n non_coherent sdk/libs/facet/facet.zig` finds nothing. docs/facet-gaps.md:549-551.

Found independently by: entry-points, objects-commands, conformance-path (3 strands).

### 12. Add the three sparse entry points as stubs, and the struct members 1.0 requires beside them

*entry points / memory* &mdash; conformance-blocking, small, also serves the shim

Three stubs, three fd lines, three LVOs: GetPhysicalDeviceSparseImageFormatProperties and GetImageSparseMemoryRequirements writing count 0, and QueueBindSparse, which no legal call can reach because no queue family carries a sparse bit. Beside them PhysicalDeviceProperties needs sparse_properties and the features struct the sparse bits, all answering false — Vulkan requires both to be reportable even when every answer is no. The sparse *functionality* is a separate optional capability, and real residency is a different machine: page tables facet may write, where the V3D's MMU is the firmware's.

> Verified: `grep -ci sparse sdk/fd/facet_lib.fd` -> 0; `grep -rn -i sparse sdk/libs/facet/ src/disk/libs/facet/ --include='*.zig'` finds only prose at facet.zig:262 and getphysicaldevicefeatures.zig:48; facet.zig:245-255 has no sparse_properties; facet.zig:976 and :988 are the only two IMAGE_CREATE_ bits, so there are no sparse image flags to refuse; facet.zig:551-553 has no QUEUE_SPARSE_BINDING bit.

Found independently by: entry-points (3 items), objects-commands, formats, conformance-path (4 strands).

### 13. Add CmdResolveImage, as a stub until there is multisampling

*entry points / commands* &mdash; conformance-blocking, small, also serves the shim

After: Multisampling for anything beyond a stub

One fd line, one LVO wrapper, one file in command/, plus VkImageResolve. While rasterization_samples above 1 is refused there is no legal call a program can make — Vulkan forbids a resolve whose source is single-sampled — so the body is validation and nothing else. The command is S5 of item 61's sized plan, about 187 lines of code and 65 of tests with its CPU body; what a legal call waits on is the rest of item 61. (This said "a day's work" until 07.11.2026, and named item 64, which is the synchronisation item.) This is the one absent command whose absence no feature bit papers over, because Vulkan 1.0's required limits make 4 colour samples a minimum, so a conformant device genuinely has multisampled images to resolve.

> Verified: the fd has CmdBlitImage (:216) and CmdCopyImage (:214) and no CmdResolveImage; `awk 'NR>12 && NR<284 && /^[A-Za-z]/' sdk/fd/facet_lib.fd | grep -c Resolve` -> 0. render/createrenderpass.zig:215-216 read verbatim: "// A resolve attachment is multisampling's, which there is none of." then `if (subpass.resolve_attachments != null) return .error_feature_not_present;`. docs/facet-todo.md:67 already calls this the one row a conformant 1.0 device may not refuse.

Found independently by: entry-points, objects-commands, semantics, features, conformance-path (5 strands).

### 14. Fill in PhysicalDeviceProperties' three missing members

*device properties* &mdash; conformance-blocking, small, also serves the shim

**Done in 1.82.** `PhysicalDeviceProperties` is `VkPhysicalDeviceProperties`,
all nine members in Vulkan's order: `device_name` is 256 bytes as
`VK_MAX_PHYSICAL_DEVICE_NAME_SIZE` always asked, `pipeline_cache_uuid` and
`sparse_properties` are there, and `limits` therefore sits where a
conformant caller expects it. `PhysicalDeviceSparseProperties` is a new
structure of five `Bool32`, all false, since no device binds memory a piece
at a time.

The UUID is not filled with zeroes. Vulkan asks that it change whenever
anything that could make a cached pipeline wrong changes, and the driver
module's own `stamp` is already exactly that - the sum of the library's
version and of every shape a module and the library share - so the UUID is
that stamp mixed with what names the device, which makes it move when the
library is rebuilt, when a driver is rebuilt against another library, or
when the device is a different one (`driver/_driver.zig` `cacheUuid`). The
item's worry that this had to wait for the pipeline cache was unfounded:
the member is required whether or not the cache commands exist, and the
stamp is a better source than a cache would have been.

After: The pipeline cache (for the UUID) and the sparse queries (for sparseProperties)

GetPhysicalDeviceProperties has Vulkan's name and arity but fills a struct short of VkPhysicalDeviceProperties by pipelineCacheUUID[16] and sparseProperties, with deviceName 64 bytes where VK_MAX_PHYSICAL_DEVICE_NAME_SIZE is 256 — so `limits` sits at the wrong offset for a conformant caller and two members are absent. Adding them is small but moves `limits`, breaking every program that reads the struct, so it wants doing at the same moment as the limits reshape (item 16) rather than on its own.

> sdk/libs/facet/facet.zig:245-255 — verified the member list is {api_version, driver_version, vendor_id, device_id, device_type, device_name[64], limits}; facet.zig:242 MAX_PHYSICAL_DEVICE_NAME_SIZE = 64. Both drivers fill it at cpu.zig:68-105 and driver/v3d/driver.zig:100-136.

Found independently by: entry-points, objects-commands.

### 15. Widen a query's counter past 32 bits

*query pools* &mdash; conformance-blocking, medium

Pool.counts is [*]u32, written and read with 32-bit atomics and held at its highest rather than wrapping. GetQueryPoolResults honours QUERY_RESULT_64 by writing eight bytes, so a conformant caller that asks for a 64-bit occlusion result and passes 2^32-1 samples is handed a saturated value where Vulkan does not leave it undefined. At 2560x1440 that is about 1165 full-screen depth-passing draws inside one query. Needs a 64-bit atomic, which the library cannot assume because it runs on 32-bit chips too — so either a per-core 32-bit counter summed at the fence, which the tiled rasterizer's part structure already suggests, or a per-driver change on the CM5 alone. A timestamp is already 64 bits because one task writes it whole.

> Verified: src/disk/libs/facet/query/_query.zig:73 `counts: [*]u32,` and :76 `times: [*]u64,`; :116 `@atomicStore(u32, ...)`; query/getquerypoolresults.zig:44-45 "one that will not fit is held at 0xFFFFFFFF, where Vulkan leaves it undefined". docs/facet-gaps.md:135-148 and docs/facet-todo.md:84 both state it and both are still true.

Found independently by: entry-points, semantics.

### 16. Decide what PhysicalDeviceLimits is: 26 facet fields against VkPhysicalDeviceLimits' ~106

*limits / API shape* &mdash; structural, large, also serves the shim

**Done in 1.82, and the counts were right: 106 and 55 exactly.** They are no
longer quoted from the published spec either - this machine has the registry
header installed, because `scripts/vulkan-check.sh` compiles against it, so
`scripts/vulkan-struct-check.sh` reads `vulkan_core.h` and holds all four
structures against it member for member, name for name, type for type and
array length for array length. It has a `--prove` run that tells the
comparison five lies and requires each to come back caught, and the build
carries a test of its own for the counts and the layout so the shape is held
even where no Vulkan header exists.

`PhysicalDeviceLimits` is Vulkan's 106 in Vulkan's order and types.
`min_memory_map_alignment` is `usize`, `max_sampler_anisotropy` and
`timestamp_period` are floats, and
`max_descriptor_set_dynamic_buffers` has split into Vulkan's two.
`tile_size` and `cores` left for the library's own `PhysicalDevice` record;
GetRenderAreaGranularity is Vulkan's way to ask the tile and answers from
there, and the core count was never Vulkan's business.

**One divergence found doing it, and it is not optional.** `sdk/sdk.zig`
requires every structure of the SDK to be 4-byte aligned, 64-bit fields
included, because the ESP32's compiler moves the stack pointer by exactly
the bytes of a call's stack arguments and a call with an odd number of them
leaves what it calls 4 bytes off an 8-byte boundary. So the nine 64-bit
members carry `align(4)`, and C pads before them where this does not: 492
bytes against 504 for the limits, 804 against 824 for the properties.
Features and the sparse properties are byte for byte Vulkan's, 220 and 20,
every member being four bytes. Nothing casts one onto the other and item 68
marshals field by field in any case, so the difference costs nothing - but
it means "Vulkan's layout" is true of the member list and not of the bytes.

The ninety-odd numbers the two devices share live in `_instance.limits`,
which each driver starts from and sets only what its own hardware decides
over; that is what keeps them from drifting apart. Items 17 to 30 are now
value changes in a structure that has the fields.

**And the shortfalls are counted, which is what the reshape was for.**
`src/disk/libs/facet/tests/vulkan_limits.zig` carries Vulkan 1.0's required
value for all 106 - the two-column requirement, so it knows that a feature
reported false *mandates* the Unsupported value rather than permitting
anything, and it reads the device's features to pick between them - and
counts the ones the cores do not meet. **Eighteen**, pinned, and they
account for themselves: two to item 17, two to 18, two to 19, one to 21,
one to 22, two to 28, and eight to item 61's multisampling, with nothing
left over and nothing in the table unaccounted for. Closing an item lowers
the number and the test says so; a limit reported worse than before raises
it and the test says that too. The check proves itself as well: a device
built from the table, on Vulkan's floor everywhere, must pass, and one step
the wrong way in each of the five kinds of requirement must be caught -
which is what says `at_most` is not being read as `at_least`.

This cannot be fixed by raising numbers, and it gates every limits item below it. facet's struct has 26 fields; Vulkan's has about 106. Roughly 25 Vulkan limits have a counterpart and about 81 do not; two facet fields (tile_size, cores) have no Vulkan counterpart; max_descriptor_set_dynamic_buffers folds two Vulkan limits into one; and three types differ — min_memory_map_alignment is u32 where Vulkan uses size_t, max_sampler_anisotropy is u32 where Vulkan's is float, and timestamp_period_ns is u32 nanoseconds where timestampPeriod is a float (1000 maps cleanly; a fractional period cannot be expressed). Worse for any translation, facet's struct is append-only by contract — the comments repeatedly say "a field added at the end, so that none already there moves" — which is how an LVO library keeps its ABI and the exact opposite of Vulkan's frozen layout. So either facet's struct is revised wholesale once, or the shim owns a VkPhysicalDeviceLimits filled from facet plus new sources. Decide before items 17-30, because they all land in whichever struct wins.

**Decided (2026-11-06): revise facet's struct wholesale, and drop the append-only contract with it.** The API is not frozen at v0.2, so the reason the contract existed - an LVO library keeping its ABI across releases - does not apply yet, and it is the one thing standing between this structure and Vulkan's own layout. `PhysicalDeviceLimits` becomes `VkPhysicalDeviceLimits`: Vulkan's ~106 members, in Vulkan's order, with Vulkan's types - so `min_memory_map_alignment` becomes `size_t`-shaped, `max_sampler_anisotropy` and `timestamp_period_ns` become floats (`timestampPeriod`, which also fixes the fractional period that 1000 nanoseconds cannot express), and `max_descriptor_set_dynamic_buffers` splits into Vulkan's two. facet's two extra fields, `tile_size` and `cores`, have no Vulkan counterpart and move out of this structure rather than sitting inside Vulkan's layout. The same decision applies to `PhysicalDeviceFeatures` (item 49) and `PhysicalDeviceProperties` (item 14). Items 17-30 land in Vulkan's struct.

> Verified by script: PhysicalDeviceLimits has exactly 26 fields (sdk/libs/facet/facet.zig), listed — max_image_dimension_2d, max_framebuffer_width/height, max_image_dimension_3d, max_image_array_layers, max_color_attachments, max_vertex_input_bindings/attributes/binding_stride, max_vertex_output_components, max_push_constants_size, max_bound_descriptor_sets, max_per_stage_descriptor_sampled_images/uniform_buffers, min_memory_map_alignment, tile_size, cores, max_sampler_anisotropy, timestamp_period_ns, max_descriptor_set_dynamic_buffers, the three compute limits, max_tessellation_patch_components, point_size_range, point_size_granularity. The append-only contract is stated at facet.zig:207 and :232-234.

Found independently by: limits, conformance-path (the ~85-field fill is the same finding from the shim side).

### 17. Raise maxVertexOutputComponents from 8 to 64, and report maxFragmentInputComponents

*limits / varyings* &mdash; **the cores' half done in 1.90**; the V3D's is the port of Mesa's VPM writes for vertex outputs

After: The limits reshape

**Done on the cores in 1.90, and the rescope below is what it turned out
to be.** The five uncoupled constants are one constant:
`shader.MAX_VARYINGS`, in the SDK beside `MAX_SETS`, read by the limits
table, the cores' rasterizer, the widening path and `ir.zig`. The comptime
tie this item wanted in `cpu.zig` is not needed, because
`driver/cpu/raster/batched.zig` and `driver/_vertices.zig` already import
the SDK's `shader` - so rather than four numbers checked against each
other, there is one number and nothing to check.

`most_stride` was the trap and it was *worse* than the rescope said: a bare
64 is 4 + 60, so it was already four short of the 64 now reported, and a
draw of points or lines above 60 varyings would have drawn nothing and said
nothing. It is `4 + shader.MAX_VARYINGS` now, and the test draws a line
with every varying live - put the bare 64 back and that case alone fails.

The clip path is bucketed. It is the one place a vertex's varyings are a
comptime array, so cutting cost what the array was wide whatever the draw
carried, and widening it to 64 would have charged a two-varying draw about
11 KB of copying a cut triangle against about 1.9 KB. `Clip` is an enum of
8, 16, 32 and 64 now, chosen once a draw and dispatched by an `inline`
switch into `cutUp`, so every draw written before 1.90 fits the narrowest
bucket and pays exactly what it paid then. The bucket list is the single
source: its own test walks every count from 0 to the cap and holds the
bucket chosen for it to be wide enough, because a bucket one step too
narrow makes `cutUp`'s varying copy run off the end of a clip vertex -
which it does, as `panic: index out of bounds: index 64, len 63`, when the
widest bucket is set one short.

The test is the point of the item. A vertex function writes varying *i* as
*i + 1* at every corner, so each interpolates to exactly *i + 1* over the
triangle whatever the perspective and whatever the clipper does to it; the
fragment function reads all 64 back through `shader.Rows(65)` and paints
green only where every one is right, red otherwise. So the *picture* is the
assertion, and a varying lost, truncated or read one row over is a red
pixel rather than nothing at all. Three draws reach three paths with all 64
live: whole (the uncut path, where varyings are read through a pointer),
crossing the near plane (the only way into the clipper, and the only draw
that picks the widest bucket - 1113 green pixels, 0 red), and a line list
(the only way into `_vertices.widen` and so to the `most_stride` guard).
The clipped case also asserts that more primitives came out of clipping
than went in, which is how the test knows it went *through* the clipper
rather than past it.

**The V3D keeps its eight for now, and they are this compiler's, not the
hardware's.** 1.90 called them a real ceiling, and Mesa says otherwise:
v3dv reports `16 * 4` for both limits on this same V3D 7.1
(`v3dv_device.c`, from `V3D_MAX_FS_INPUTS = 64` in
`src/broadcom/common/v3d_limits.h`), its compiler storing each vertex
output into the VPM as it is computed (`vir_STVPMV`, `nir_to_vir.c`)
rather than holding them all in registers. facet's QPU code does hold
them: ten usable registers carry eight varyings and the four floats a
program needs of its own, and the vertex programs are pregenerated, one for
each count. Raising the eight is porting those VPM writes, not writing a
larger number. Until then `driver/v3d/driver.zig` reads both limits off
`compile.most_varyings` - the texel-offset pattern from item 28, twelve
lines above it in the same file - and this device reports 8 where the cores
report 64. Without those two lines it would have inherited 64 and refused
every pipeline above 8 at creation while advertising that it took them,
which is the shape item 28 settled into and the one this item could most
easily have got wrong. `_play.zig`'s index into the pregenerated table is
bounded too, since the cores' number now exceeds that table's length.

And raising the IR's bound made the V3D's own refusal testable for the first
time: `Error.Varyings` had no test in `compile.zig`'s twenty, because a
nine-varying graph could not be built while `ir.zig` refused one at
comptime. There is a twelve-varying graph now, refused as `Error.Varyings`,
and `spirv.look` accepts the same words - so it is the device refusing a
module and not the words being wrong, which is what the two tiers are for.

The pin in tests/vulkan_limits.zig is **8**: item 22's one row and item
61's seven.

What this item said about `shader.Entry.varyings`, the V3D's shader record,
the SPIR-V reader, the fixed forms and the two runtime-sized stores was
wrong, and the rescope below says so in detail. The one thing it was right
about and put in the wrong place is the memory: the cost is on the clip
path, not in the vertex store, and it is now paid only by draws that ask
for it.

**Rescoped in 1.89 against the code, and most of what this item says about
its own size is wrong.** The production change is five uncoupled constants
and a comptime tie that does not exist yet - about ten real lines - and the
tests are the bulk and the point. The five, measured:

1. `instance/_instance.zig` `max_vertex_output_components = 8` → 64. Both
   limits then report 64 with no further edit, because
   `.max_fragment_input_components = max_vertex_output_components` already
   reads the same constant. So the title's "and report
   maxFragmentInputComponents" is already done: the field exists, it is
   reported, and only its value is wrong.
2. `driver/cpu/raster/batched.zig` `most_varyings = 8` → 64. This is the
   one that costs: it widens `setup.ClipVertex(most_varyings)` from 48 to
   272 bytes and `Batch.planes` from 108 to 780.
3. `driver/_vertices.zig` `const most_stride = 64` → at least 68, because
   a stride is 4 + varyings. **This is the item's one way to ship looking
   done.** `_vertices.zig` guards with `if (stride > most_stride or ...)
   return .{}` and `Wide` is all zeroes, so raising the limit and leaving
   this alone makes every draw of points or lines - and of triangles as
   edges or corners - return zero vertices and zero indices above 60
   varyings. No refusal, no log, no `noRoom`, no result code: the picture
   is simply empty, on *both* devices, because that file is shared. Filled
   triangles are what every test draws and they would keep working.
4. `sdk/libs/facet/ir.zig`'s `if (build.varyings > 8) @compileError(...)` -
   a bare literal 8, not the constant. The SDK cannot import `_instance`,
   so either hardcode 64 or hoist the constant into `sdk/libs/facet/facet.zig`
   and have `_instance` read it, which is the better fix: `ir.zig` and
   `shader.zig`'s doc comment would then have one source of truth.
5. `driver/v3d/qpu.zig` `most_varyings = 8`, which `compile.zig` re-exports.

Nothing ties the first of those to the other four today - there is no
comptime check at all. `raster` is a separate Zig module and cannot see
`_instance`, so the tie belongs in `cpu.zig`, which imports both.

**What this item claims is touched and is not.**
`shader.Entry.varyings`' low 8 bits hold 0..255 and `Fixed.bits()` starts
at bit 8, so 64 fits with room to spare and nothing moves - it is not a
blocker in any sense. The V3D's varying count in the shader record is an
8-bit field in a 32-bit word; 64 fits there too. The SPIR-V reader has
nothing to plumb: `input_locations` and `output_locations` are saturating
u32 and the file says in as many words that no caller reads them. Every
fixed form's `Fixed.varyings()` returns that form's own shape - 0, 2, 3, 4
or 6 - and the limit never enters. `driver/cpu/raster/pipeline.zig` is
comptime per config and is untouched.

**And the memory cost is real but in a different place.** Both stores this
item says grow eightfold are *already runtime-sized*: the per-triangle
plane store is `@sizeOf(Triangle) + plane_count * @sizeOf(shader.Plane)`
out of the arena with `plane_count = 1 + state.varyings`, and the
per-vertex store is `vertices * (4 + pipeline.varyings) * 4` out of a
scratch that grows, so a 2-varying draw pays what it pays today and only a
draw that asks for 64 pays more. Per tile the cost is *zero* - the tile
buffers hold colour, depth and stencil and no varyings at all. What does
grow unconditionally is the clip path, because `ClipVertex` is a comptime
array: `setup.cut` would interpolate all 64 slots of every vertex it
generates, `batched.zig` zeroes 256 bytes a corner, and the polygon copy
is 2176 bytes per clip plane over five planes - roughly 11 KB of memcpy per
*cut* triangle against about 1.9 KB today, paid by every clipped draw
whatever its varying count, with `setUpAll`'s clip arrays going from about
528 bytes of stack to about 2992 against a 32 KiB task stack. That is the
one thing to decide before writing code rather than after, and no host test
will catch it. The honest alternative is a runtime-strided clip vertex out
of the arena, which is a genuinely larger change.

**The V3D needs no capability work.** Both refusals already exist and are
already loud, ending in `error_feature_not_present` at pipeline creation,
and the right limit override is the pattern item 28 established twelve
lines away in the same file: `said.max_vertex_output_components =
compile.most_varyings`, so the number follows the capability and cannot
drift when the compiler's cap moves - a cap that is facet's and not the
hardware's, as the Done note above says. The V3D's row
stays a shortfall after this item, honestly reported - the same shape items
52 and 28 settled into. One thing to harden while there: the V3D indexes a
table of pregenerated vertex programs by varying count, and that table is
`qpu.most_varyings + 1` long.

**Raising the IR's bound is what makes the V3D's refusal testable at all.**
`compile.zig` carries twenty host tests and `Error.Varyings` has none,
because a 9-varying graph cannot be built while `ir.zig` refuses one at
comptime. So the SDK constant and the first test of that error go together.

The original description follows.

The single largest limit shortfall: 8 floats of interstage data against a required 64 out of the vertex stage and 64 into the fragment stage. Not a constant to bump — it is the width of what the rasterizer interpolates, so it touches the cores' triangle setup and per-pixel interpolation, the V3D's varying count in the shader record, the IR and the SPIR-V reader's varying plumbing, every fixed form's declared varying count, and shader.Entry.varyings, whose low 8 bits carry the number. The per-triangle vertex store grows eightfold, which is real memory and bandwidth in a tiled rasterizer.

> Verified: src/disk/libs/facet/instance/_instance.zig:39 `pub const max_vertex_output_components = 8;` with the comment "what the library's own objects have room for, whatever the driver"; consumed at driver/cpu/cpu.zig:84 and driver/v3d/driver.zig:114. **That last clause is not merely a stale line number but a wrong mechanism**, found in the 1.89 rescope: `cpu.zig` has no reference to the constant anywhere - it takes `.limits = _instance.limits` whole - and the V3D copies the same struct and then overrides fields. The constant's only consumers outside the limits table itself are the two limit fields and `shader/createshadermodule.zig`'s refusal. sdk/libs/facet/shader.zig:56-60 puts the count in Entry.varyings' low 8 bits. Required minimum 64 for both limits (Vulkan 1.0 Required Limits, Core column).

Found independently by: limits, conformance-path.

### 18. Raise maxVertexInputBindings 4 to 16 and maxVertexInputAttributes 8 to 16

*limits / vertex input* &mdash; conformance-blocking, medium

After: The limits reshape

**Done in 1.84, and it was as mechanical as this said.** Both constants in
`_instance.zig` are 16, which is the whole change: every array they size
grew with them - `Pipeline.bindings` and `Pipeline.attributes` in the
plan, `_vertices.Bound.vertex_buffers` in the record of what a draw was
bound with, the same field in each driver's player, and the stack array
`CmdBindVertexBuffers` copies through - and every refusal in
CreateGraphicsPipelines already read the constants rather than a literal.
About 224 bytes a pipeline and 192 a bound state, and nothing else.

Two things this item did not know. The cores' attribute fetch
(`_vertices.readInputs`) was already general: it loops `attribute_count`
and indexes the two arrays, and the per-vertex input block it fills is
sized `vertices * locations` out of a scratch allocation that grows on
demand, so nothing capped the locations but the array. And **the V3D
needed no change at all**, because it fetches no Vulkan attribute: the
vertex stage runs on the cores for both devices and the hardware is handed
a stream already transformed, so the "attributes" in its shader record are
the position and the varyings. This item's claim of "both drivers'
attribute fetch" was wrong, and in the easy direction.

A drawing test holds it: sixteen bindings and sixteen attributes, location
0 the position from binding 0 and locations 1 to 15 each from a binding of
their own, each carrying its own location's number. The vertex function
sends the triangle past the far plane unless all fifteen arrived, so "the
triangle is there" is the test - and the last value is then made wrong on
purpose and the triangle has to vanish, because otherwise the test would
pass on a library that read eight attributes and left the rest at
(0, 0, 0, 1).

Both below the required minimum of 16. These are the sizes of fixed arrays in the pipeline's vertex-input state, in the command player's bound-buffer table and in both drivers' attribute fetch, so it is mechanical but grows several per-pipeline arrays. maxVertexInputBindingStride is 2048 and exactly meets its floor. Note the spec's footnote: only an implementation enabling VK_KHR_portability_subset may report fewer, and facet is not that.

> Verified: _instance.zig:37-38 `max_vertex_input_bindings = 4;` and `max_vertex_input_attributes = 8;`, reported at cpu.zig:81-82 and driver/v3d/driver.zig:111-112; `.max_vertex_input_binding_stride = 2048` at cpu.zig:84.

Found independently by: limits (2 items), conformance-path.

### 19. Raise the dynamic buffer descriptors from 2 to 8 uniform + 4 storage, and split the one limit in two

*limits / descriptors* &mdash; conformance-blocking, medium

After: The limits reshape

**Done in 1.85, and the diagnosis here was right about the cap and wrong
about the shape of the fix.** `shader.MAX_DYNAMIC_OFFSETS` is 12, which is
Vulkan's 8 and 4 added together, and the two limits report 8 and 4. The
reason it is one number and not two: Vulkan's limits are per *pipeline
layout* and put no limit on one set, so a program may spend all twelve on
a single set layout, and that is what a set has to hold. Splitting the
constant in two would have let a set hold 8 uniform or 4 storage but not
8 and 4 together, which is a legal layout.

The field was already split by the 1.82 reshape, so nothing had to be
split here. `Resources.offsets` grew from `[4][2]u32` to `[4][12]u32` -
192 bytes where it was 32, `Resources` from about 200 to about 360 - and
nothing else changed: `shiftOf` already bounded the index by the constant,
`makeSet` already numbered the slots by it, and `CmdBindDescriptorSets`
already allowed `MAX_SETS * MAX_DYNAMIC_OFFSETS` offsets in one call.

**The per-submission arena this item asked for was not needed.** The
offsets are copied once for each draw whose bindings changed, not once a
draw, and the arena they are copied into already exists
(`cpu/_draw.zig`'s `player.drawn orelse target.arena.create`). The 1.43
measurement this item leans on - 11.61 and 11.62 ms against 11.18 to
11.58, about 2 per cent - is a 32-byte difference in that copy, and the
note recording it says the gap is smaller than the test's drift between
batches, so it never separated the copy from the noise.

The library in fact takes twelve in *each* of its four sets, 48 over a
layout, and reports 8 and 4 anyway: 48 would be a promise it cannot keep,
because a layout may put all 48 in one set. A pair that is true of every
arrangement is the only honest report, and Vulkan's floor is exactly that
pair.

facet has one combined cap of 2, enforced per descriptor-set layout and published as a single field. Vulkan has two limits with minimums of 8 (uniform) and 4 (storage), counted per pipeline layout, and a single set layout may legally hold 8 dynamic uniform buffers — which facet refuses at the third. Needs MAX_DYNAMIC_OFFSETS raised, Resources.offsets widened from [MAX_SETS][2]u32, and the field split. It costs what the 1.43 measurement recorded: the offsets are part of what a draw was bound with and are copied for every draw that changed them, so making them a pointer into a per-submission arena is the shape that avoids the copy.

> Verified: sdk/libs/facet/shader.zig:425 MAX_SETS = 4, :438 `pub const MAX_DYNAMIC_OFFSETS = 2;`, :1199 `offsets: [MAX_SETS][MAX_DYNAMIC_OFFSETS]u32`; refusal read verbatim at descriptor/createdescriptorsetlayout.zig:124-127 `dynamic += binding.descriptor_count; if (dynamic > shader.MAX_DYNAMIC_OFFSETS) return .error_feature_not_present;`; published as one field at cpu.zig:92 and driver/v3d/driver.zig:120.

Found independently by: limits, semantics.

### 20. Raise the V3D's maxPerStageDescriptorSampledImages from 1 to 16

*limits / descriptors, V3D driver* &mdash; conformance-blocking, large

The V3D's shader record holds exactly one combined image sampler as an optional single field, so one texture per fragment program is the hard ceiling on that device — sixteen times below the floor. The compiler already handles up to 16, so the gap is entirely in the driver: `Shader.sampler: ?compile.Sampler` must become an array, and the draw-time path that fills the two TMU configuration words must emit a set of them.

> Verified: driver/v3d/driver.zig:118 `.max_per_stage_descriptor_sampled_images = 1,` against cpu.zig:88 `= 16`; the cause is driver/v3d/driver.zig:436 `sampler: ?compile.Sampler,` (one, not an array) while driver/v3d/compile.zig:96 `pub const most_samplers = 16;`. Both devices report max_per_stage_descriptor_uniform_buffers = 12, exactly at the floor.

### 21. Support 1D images and report maxImageDimension1D and maxImageDimensionCube

*limits / images* &mdash; conformance-blocking, medium

After: The limits reshape

**Done in 1.86, and smaller than this said.** A 1D image is a texture one
row high, and that is not a shortcut: the layout this library keeps halves
the longer side alone and allows as many levels as halving it gives
(`texture.Sizes.of`), which for a texture of height 1 is
floor(log2(width)) + 1 - Vulkan's own rule for a 1D image. So the levels,
the layers, the copies, the memory requirements and the sampling are the
ones every texture already had, and `maxImageDimension1D` is the 2D width,
8192. No new image kind and no 1D sampler path were needed.

What did have to be said is which image is which. `Image.line` tells a 1D
image from a 2D image one row high, because Vulkan makes them different
images however alike their texels lie: each refuses the other's view
types. `ImageViewType` gained `1d_array` at 4, which Vulkan has and this
enum was missing. A 1D image is held to a height and a depth of 1, and
CUBE_COMPATIBLE is refused for one.

One trap worth recording. GetPhysicalDeviceImageFormatProperties shapes
its probe image with height = width, so it would have gone on refusing 1D
images after they existed, and `maxImageDimension1D` would have been a
number with nothing behind it - the test that asserted the refusal would
have kept passing and said so. It shapes one row now.

`maxImageDimensionCube` was already met: a cube is six layers of a square
2D image, so the 2D width governs it, which is what this item suspected.

facet has no 1D images at all: shapeFor refuses any image_type that is not 2d or 3d in one line, so maxImageDimension1D would be 0 against a required 4096, and no Vulkan 1.0 feature makes 1D images optional. The spec's mandatory format tables are also scoped "for every VkImageType unless otherwise noted", and only the depth/stencil and compressed tables are noted, so every mandatory colour format currently fails the table for 1D. Needs a 1D image kind (rows of one line, or 2D of height 1), the 1D and 1D_ARRAY view types, a 1D sampler path, and both limit fields — a cube is governed today by the 2D limit with nothing said.

> Verified: src/disk/libs/facet/image/_image.zig:338 `if ((info.image_type != .@"2d" and !volume) or info.samples != 1) return null;` — this one line is both the 1D refusal and the multisampled-image refusal. sdk/libs/facet/facet.zig:921-926 declares ImageType.@"1d" = 0; instance/getphysicaldeviceimageformatproperties.zig:25 "`1d` has no images"; src/disk/c/test/raster/facetprobe.zig:1883 asserts "a 1D image refused". Limits struct has no 1d or cube field.

Found independently by: limits, formats, conformance-path (which listed it as an unknown).

### 22. Support layered framebuffers to 256 layers and report maxFramebufferLayers

*limits / render pass* &mdash; **the cores' half done in 1.91**; the V3D's is the port of v3dv's per-layer render list, about 90 lines and a board check

After: The limits reshape

**Done on the cores in 1.91, as Mesa's lavapipe does it.** The rescope
below held: nothing picks a layer, so a pass clears every layer and draws
into the first, and the work was accepting, reporting and clearing - plus
the two traps it named, both fixed and both tested.

- *Images.* A colour attachment's rows, an input attachment's, a
  transfer-only image's and an unsampled depth attachment's may have
  layers in optimal tiling, a layer's rows after the layer before
  (`layer_bytes`), so `rowsAt`, `readTexel`, `writeTexel`,
  CmdClearColorImage and the copies took them unchanged. Linear tiling
  stays one layer, and a 3D image stays a function's alone: drawing into a
  slice goes through a 2D view of it, which is VK_KHR_maintenance1's, not
  1.0's. GetPhysicalDeviceImageFormatProperties follows, being CreateImage's
  own rules asked, so a colour attachment now answers 256 layers.
- *Framebuffers.* CreateFramebuffer takes 1 to the device's
  `max_framebuffer_layers` and refuses a colour or depth view of fewer
  layers than the framebuffer has - the memory-safety hole named below,
  where a pass would have cleared past the image's last layer.
  `max_framebuffer_layers` is 256, `max_image_array_layers` itself, which
  is also what v3dv reports on this GPU (`v3dv_device.c`).
- *Where a pass draws.* `surfaceOf` begins at the view's `base_layer` (the
  trap below), a rows view's input-attachment pixels begin there too, and
  GetImageSubresourceLayout answers a rows image's layer with its offset
  and an array pitch of one layer.
- *The clears, ported.* lavapipe makes each attachment's surface over
  `framebuffer.layers` layers from the view's base (`handle_begin_rendering`
  through `add_img_view_surface`, lvp_execute.c:1947-2014; Mesa's render
  pass runtime begins with `layerCount = framebuffer->layers`,
  vk_render_pass.c), clears all of them for a CLEAR load op
  (`render_clear`, :1572-1633), and clears a `VkClearRect`'s
  `[baseArrayLayer, baseArrayLayer + layerCount)` from that base
  (`handle_clear_attachments` over `clear_attachment_layers`, :1541-1566
  and :3816-3868). facet does the same: the first layer in the tiles, as
  before, and the layers past it straight into the image's rows
  (`clearLayers` and `clearRectangle`, driver/cpu/_play.zig), through the
  packing a tile is stored with (`raster.fillSurface`, `fillDepth`,
  `fillStencil`), so a 565 layer is dithered exactly as the first and the
  two are the same bytes - which a test compares. A depth or stencil is
  cleared in the other layers where the part keeps it in the image and
  does not load it. A rectangle of the second layer alone no longer clears
  the first (the layer fields used to be dropped), and one of layers past
  the framebuffer's last clears nothing.

Every one of these fixes was reverted in turn against the new tests and
each made a named assertion fail.

**The V3D's half.** It reports 1 (`driver/v3d/driver.zig`). What it does
already, since 1.91, is begin a frame at the layer and the level a view
names: until then it drew a colour frame and stored a kept depth or stencil
at the image's first byte, with the first level's pitch, whatever the view
said - although depth views had named a layer since 1.58 and a level since
1.63, which the cores honoured. That is v3dv's `v3dv_layer_offset(image,
level, layer)` (v3dv_image.c:379), added to the frame's address and to the
cache ranges either side of the job. It is compiled for the board and not
yet run there. 256 layers is the port of four pieces of v3dvx_cmd_buffer.c:
`NUMBER_OF_LAYERS` ahead of `TILE_BINNING_MODE_CFG`
(`job_emit_binning_prolog`, :82-91); tile lists and tile state for every
layer, at `V3D_TILE_ALLOC_INITIAL_BLOCK_SIZE * layer * draw_tiles_x *
draw_tiles_y` (:762-765, :954-957); and the render list walked once a layer,
each with `MULTICORE_RENDERING_TILE_LIST_SET_BASE`, its own generic tile
list at that layer's addresses and the supertile coordinates
(`cmd_buffer_emit_render_pass_layer_rcl`, :750-799, looped at :1291-1294).
In facet that is a `cl.numberOfLayers` packet writer, `beginBin` and
`writeRender` in `driver/v3d/frame.zig` looping over layers, the two sizes
in `driver/v3d/_play.zig` multiplied by them, and a frame field or two:
about 50 lines. For CmdClearAttachments v3dv draws a quad a layer through
a geometry shader writing `gl_Layer` from a push constant
(v3dv_meta_clear.c:361-410); facet's V3D has no geometry stage, so its
layers past the first would be cleared as on the cores, into the rows with
the cache ranges kept, about 40 lines. Then a board check in facetprobe,
and the pin on the V3D's own count.

**Rescoped in 1.89 against the code, and the premise this item is missing
changes what it is.** Nothing in facet can select a layer: there is no
geometry stage, `spirv.zig`'s `BuiltIn` enum has no `layer`, the profile's
capabilities are `.shader` alone, and `ShaderViewportIndexLayerEXT`,
multiview and a `Layer` output appear nowhere in the tree. facet's *own*
native entry path cannot either - `shader.Vertices` carries inputs,
outputs, the vertex and instance numbers, resources and point sizes, and
no layer. So **"and render into its layers" is unachievable in core Vulkan
1.0 through facet's feature set**, and the two expensive things this item
describes do not exist to build: there is no layer axis for the tile path,
because the tiles only ever hold layer 0, and there is no field to add,
because `max_framebuffer_layers` is already in the struct and already
reported as 1.

What is left is the honest and conformant part: *accept* a layered
framebuffer over a layered view, report 256, and make sure the layers a
draw never reaches are still correct where Vulkan says they must be - which
is the load-op and `CmdClearAttachments` clears, since a render pass
instance clears every layer of the render area. That is one image-layout
fix the existing row and texel machinery already consumes, one refusal to
narrow in `createframebuffer.zig`, two Vulkan-shaped layer fields the
command path currently drops on the floor, one constant, one V3D override,
and one genuinely new memset helper of about fifty lines for the layers a
tile never reaches. Ten library files, about 120 to 150 lines, and the
tests are another 200 or so. Two commits - the cores, then the V3D on the
board - and the first cannot be split into "accept and report" then "clear
the layers", because that would ship a build reporting 256 while a CLEAR
silently left layers 1 to 255 unwritten.

**The way this ships looking done** is `surfaceOf` in
`driver/cpu/_play.zig`, which takes the image's data pointer and pitch
flat and never reads the attachment view's `base_layer` - while `planeOf`
thirty lines below it *does*, through `_image.rowsAt(image, base_level,
base_layer)`. That asymmetry is unreachable today because no layered
colour image can be created. The moment one can, a framebuffer built over
a `2d_array` view with `baseArrayLayer = 3` draws into layer 0 and
overwrites whatever is there. None of this item's natural tests touch it:
"create a 256-layer framebuffer" passes, "clear it and read back layer
200" passes because the layered clear is a memset computed from `rowsAt`
and never goes through `surfaceOf`, "report 256" passes, and the pin drops
- so the audit trail says the item closed. The only test that catches it is
a *draw* through a non-zero base layer with read-back from both that layer
and layer 0, and the item's own framing argues nobody needs to write it,
because layered rendering is unobservable. It mostly is. This is the one
thing that is not, and it is observable through the single-layer form
Vulkan explicitly allows, where a view's `layerCount` may exceed the
framebuffer's `layers`. The same hole on the V3D is its flat frame and
kept-attachment addresses. Beside it, `createframebuffer.zig` checks no
view's `layer_count` against the framebuffer's at all today, which is a
memory-safety question and not only a correctness one, and
`createimageview.zig` builds a row-image view's rows with no `base_layer`
offset.

Both are one-liners to get right and both are invisible to the tests this
item invites, which is the argument for fixing them while the code is open
rather than meeting them later as a board-only divergence.

The original description follows.

CreateFramebuffer refuses any `layers` but 1, in the same condition as the attachment-count check. Vulkan requires maxFramebufferLayers >= 256 with no gating feature, so a conformant driver must accept a layered framebuffer over a layered view and render into its layers. The render pass, the tile store path and both drivers' frame setup gain a layer axis — the V3D's frame is set up for one render-target plane at a time — so this is a real change, not a constant.

> Verified verbatim: src/disk/libs/facet/render/createframebuffer.zig:73 `if (info.attachment_count != pass.attachment_count or info.layers != 1 or info.width == 0 or info.height == 0) return .error_initialization_failed;`. driver/v3d/frame.zig:213-214 for the single-plane frame setup.

### 23. Drop the 2^20 cap on a draw's vertex and index range

*limits / draw commands* &mdash; conformance-blocking, large

After: The limits reshape

CmdDraw refuses a vertex_count over 1048576 at record time, and both drivers drop an indexed draw whose index range reaches it. Vulkan puts no limit on vkCmdDraw's vertexCount at all, and maxDrawIndexedIndexValue's Core minimum is 2^24-1 (2^32-1 only if fullDrawIndexUint32 is reported) — facet accepts IndexType.uint32, so it is claiming 32-bit indices while refusing index values above 2^20. Either remove the record-time refusal and make the drivers chunk or stream a large draw, or stop claiming uint32 indices; either way maxDrawIndexedIndexValue and maxDrawIndirectCount want reporting.

> Verified: _instance.zig:74-77 "The most vertices a draw works, the lowest it reads to the highest. Both drivers hold to it" then `pub const max_draw_vertices = 1 << 20;`; command/cmddraw.zig:74-77 `if (vertex_count > max_draw_vertices) { made.stream.refusal = .error_feature_not_present; return; }`; driver/cpu/_draw.zig:133 and driver/v3d/_play.zig:1072 drop the draw. IndexType.uint32 at facet.zig:2206-2209.

Found independently by: limits, conformance-path.

### 24. Lift the render pass's and descriptor layout's unqueryable caps

*limits / render passes and descriptors* &mdash; conformance-blocking, medium

most_subpasses = 4, most_attachments = 8, most_colors = 4, most_parts = 8 and a descriptor binding number above 255 are all refused. Vulkan publishes maxColorAttachments (minimum 4, which facet meets) but has no limit for subpasses, for a pass's total attachments, for parts, or for a binding number — so there is no number an application can query to learn the cap and nothing for a conformant implementation to refuse on. The binding cap also costs memory: binding_count is max(binding)+1 and the layout allocates a dense array of that many records, so sparse high bindings are expensive as well as refused. Needs heap-allocated plan arrays instead of comptime-fixed ones, and a sparse binding table.

> Verified: render/_render.zig:34-37 `most_attachments = 8`, `most_subpasses = 4`, `most_colors = 4`, `most_parts = 8`; refusals at createrenderpass.zig:203-204, :276, :360; descriptor/createdescriptorsetlayout.zig:104 `if (!_descriptor.known(binding.descriptor_type) or binding.binding > 255) return .error_feature_not_present;` and the dense allocation at :130-131.

### 25. Add the buffer, memory and alignment limits

*limits / buffers and memory* &mdash; conformance-blocking, medium

After: The limits reshape

Eleven limits with a hard Core minimum and no facet field: maxTexelBufferElements (>=65536), maxUniformBufferRange (>=16384), maxStorageBufferRange (>=2^27), maxMemoryAllocationCount (>=4096), maxSamplerAllocationCount (>=4000), bufferImageGranularity (<=131072), minTexelBufferOffsetAlignment, minUniformBufferOffsetAlignment and minStorageBufferOffsetAlignment (each <=256), nonCoherentAtomSize (<=256), plus maxSamplerLodBias (>=2, and facet takes an unbounded lod_bias). facet reports only min_memory_map_alignment, 64, exactly at the floor. No internal cap on texel-buffer elements or buffer ranges exists in the tree, so most of this is establishing and publishing real numbers rather than raising them — but each has to be measured, and the three offset alignments are about what the drivers actually require of a descriptor's offset. CreateBufferView aligns to the texel size instead of to any published alignment, and a dynamic offset is documented as "for the program to keep it aligned" with no alignment to read.

> Verified: the 26-field limits list contains min_memory_map_alignment (set from memory/_memory.zig:12 `pub const alignment = 64;`) and no other buffer, range or alignment field; `grep -rn 'max_texel|texel_buffer_elements|most_texels' src/disk/libs/facet/ sdk/libs/facet/` returns nothing; buffer/createbufferview.zig:111 aligns to `texels.bytes()`.

Found independently by: limits, semantics, conformance-path (3 strands).

### 26. Add the eleven missing descriptor-count limits

*limits / descriptors* &mdash; conformance-blocking, large

After: The two V3D zeros depend on storage-image and input-attachment support on that device

facet reports two of Vulkan's thirteen descriptor-count limits. Missing with hard minimums: maxPerStageDescriptorSamplers (16), StorageBuffers (4), StorageImages (4), InputAttachments (4), maxPerStageResources (128), maxDescriptorSetSamplers (96), UniformBuffers (72), StorageBuffers (24), SampledImages (96), StorageImages (24), InputAttachments (4). Two cannot simply be reported: the V3D refuses storage images and input attachments outright, so it would report 0 against required 4/24 and 4/4, and no Vulkan 1.0 feature makes either kind optional. So this is partly bookkeeping and partly the V3D work in items 58 and 59.

> Verified: the limits struct carries only max_per_stage_descriptor_sampled_images and max_per_stage_descriptor_uniform_buffers, the latter 12 on both devices (cpu.zig:89, driver/v3d/driver.zig:119) and exactly at the floor; driver/v3d/driver.zig:216 `.storage_images = false,` and :225 `.input_attachments = false,`.

### 27. Add the viewport, precision and rasterization limits

*limits / rasterization* &mdash; conformance-blocking, medium

After: The limits reshape

Thirteen fields with Core minimums and no counterpart: maxViewportDimensions ((4096,4096)), viewportBoundsRange ((-8192,8191)), viewportSubPixelBits, subPixelPrecisionBits (>=4), subTexelPrecisionBits (>=4), mipmapPrecisionBits (>=4), discreteQueuePriorities (>=2), lineWidthRange ((1.0, >=8.0-1ULP)), lineWidthGranularity (<=1.0), maxViewports, plus strictLines, standardSampleLocations and timestampComputeAndGraphics, which have no minimum. The capability is mostly there — the cores snap positions to 1/256 of a pixel, which is 8 subpixel bits against a required 4, and CmdSetLineWidth takes arbitrary widths with no cap found — so this is largely measuring and publishing numbers the implementation already honours. maxViewports may legitimately be 1, since multiViewport is optional and facet reports several_viewports = false; the field still has to exist.

> Verified: none of these fields is among the 26. Subpixel precision at driver/cpu/raster/setup.zig:14-15 "Positions are snapped to 1/256 of a pixel (Q16.8)"; line width at facet.zig:1841 `line_width: f32 = 1,` widened at driver/cpu/_draw.zig:261 and driver/v3d/_play.zig:1249; several_viewports verified false in both driver tables.

Found independently by: limits, conformance-path (whose "maxViewports min 16" claim is corrected here).

### 28. Add constant-offset sampling and the texel-offset limits

*limits / sampling* &mdash; conformance-blocking, medium

After: The SPIR-V reader and the IR need the offset operand before the QPU back end can honour it

**The cores' half is done in 1.87, and the item was right that the reader
and the IR came first.** `OpImageSampleImplicitLod` had never had an
operand word read from it: `spirv.look` accepted the four-operand form and
nothing else, so a module carrying ConstOffset was refused for its *length*
rather than for the operand, which is the wrong refusal and says nothing
useful. The reader now decodes the image-operands mask bit by bit, counts
the ids each bit brings (two for Grad), checks every one against the id
bound, and refuses any bit the profile does not list with a fault of its
own, `image_operand_refused`. The fault sits after `too_many_ids` so
`malformed()` keeps it in the *unsupported* tier: a module with an operand
this device will not take is a module this device will not take, not a
broken module.

ConstOffset is the one bit `facet_profile` lists. It needs no SPIR-V
capability - which is exactly why Vulkan requires minTexelOffset and
maxTexelOffset unconditionally and gates the gather pair on
shaderImageGatherExtended, settling the unknown this item pointed at: the
non-constant `Offset` operand is the one that wants the feature, and facet
refuses it.

The offset reaches the sampler as an *instruction* operand, not sampler
state, because that is what SPIR-V makes it: `texture.Point.offset` sits
beside `reference` rather than in `Sampling`, two axes because the IR
samples 2D only, and `sampledAt` adds it to the floored texel coordinates
before the wrap - under the bilinear branch the offset moves `left` and
`top` while the fractions are still taken from the untouched coordinate, so
a half-texel sample one texel to the left is still a half-texel sample.
`ir.Op.offset` carries it from `sampleOffset`/`sampleOffsetBy`, which
`@compileError` outside -8 to 7 and name the two limits in the message.

The V3D's half is not done, and it is refused rather than wrong. The QPUs
take no offset, so `compile.profile` does not list the bit, and the module
is refused at `vkCreateGraphicsPipelines` with `error_feature_not_present` -
at pipeline creation, where a program can still do something about it,
which is strictly better than item 52's draw-time magenta. The device's
`min_texel_offset`/`max_texel_offset` are *derived* from
`profile.takesImageOperand(.const_offset)` rather than written by hand, so
the day the back end learns the operand the limit follows, and until then
the number cannot drift away from what the compiler accepts. That was the
one way this could have shipped broken - the cores' -8/7 inherited by a
device that refuses every use of it - and `facetprobe` checks it on the
board as well, since `describe` does not run on the host.

minTexelOffset (<=-8) and maxTexelOffset (>=7) are required unconditionally: nothing gates SPIR-V's ConstOffset operand on OpImageSample. facet has neither the operand nor the fields, so this is a sampling-path feature on both devices — an offset applied in texels before the fetch — plus the two fields. The gather pair (minTexelGatherOffset, maxTexelGatherOffset) and OpImageGather belong with it, with the caveat in unknowns about whether they are unconditional or ride on shaderImageGatherExtended.

> Verified: `grep -rn 'const_offset|texel_offset|ConstOffset' sdk/libs/facet/ src/disk/libs/facet/ --include='*.zig'` returns nothing; none of the four fields is among the 26.

### 29. Add the fragment-output and compute-dispatch limits

*limits / fragment and compute* &mdash; conformance-blocking, small

After: maxFragmentInputComponents depends on item 17

Four fields with Core minimums: maxFragmentInputComponents (>=64, the same 8-varying cap as item 17), maxFragmentOutputAttachments (>=4, which most_colors = 4 just meets), maxFragmentCombinedOutputResources (>=4) and maxComputeWorkGroupCount ((65535,65535,65535)). CmdDispatch has no group-count check, so the dispatch limit is probably already met and only needs reporting. The three compute limits facet does report are present and plausible.

> Verified: the limits struct reports max_compute_work_group_size, max_compute_work_group_invocations and max_compute_shared_memory_size (set from _instance.zig:66-68 to {1024,1024,64}, 1024, 16 KiB) and no work-group count; render/_render.zig:36 `pub const most_colors = 4;`; no refusal or cap in command/cmddispatch.zig.

### 30. Fill the limits that may conformantly stay at their unsupported values, and decide the tessellation and geometry numbers

*limits / optional features* &mdash; feature-gap, small

After: The limits reshape

About eighteen fields that must exist for a well-formed Vulkan driver but owe no capability work, because the gating feature is optional and the spec's Unsupported column permits 0 or 1: sparseAddressSpaceSize, maxViewports (1), maxDrawIndirectCount (1), maxFragmentDualSrcAttachments (0), min/maxInterpolationOffset and subPixelInterpolationOffsetBits (0 without sampleRateShading), maxClipDistances / maxCullDistances / maxCombinedClipAndCullDistances (0), all eight tessellation limits and all five geometry limits (0 when the features are false). The numbers matter only if the features are claimed: facet's max_tessellation_patch_components is 16 against maxTessellationControlPerPatchOutputComponents' required 120, max_patch_points is 32 which exactly meets maxTessellationPatchSize but is a library constant that is not reported at all, and there is no geometry stage whatever.

> Verified: _instance.zig:42-43 `pub const max_patch_points = 32;` / `pub const max_tessellation_patch_components = 16;`, only the latter reported (cpu.zig:97, driver/v3d/driver.zig:124); none of the eighteen other fields is among the 26; several_viewports false in both tables.

### 31. Add the six mandatory formats that have no facet.Format value

*formats / enumeration* &mdash; conformance-blocking, small

Six formats carrying unconditional mandatory features are absent from the enum: B4G4R4A4_UNORM_PACK16, A1R5G5B5_UNORM_PACK16, A8B8G8R8_SNORM_PACK32, A8B8G8R8_UINT_PACK32, A8B8G8R8_SINT_PACK32 and D32_SFLOAT. The three a8b8g8r8 pack32 ones are byte-identical to their r8g8b8a8 forms on a little-endian machine — facet already says so for the _unorm and _srgb pair — so they are three enum values plus three switch arms. The two packed-16 ones need a new texel layout; D32_SFLOAT is item 35's.

> Verified by enumerating the Format enum (sdk/libs/facet/facet.zig:682-821, 71 members): none of the six is present. facet.zig:804-807 states the little-endian aliasing for the pair that does exist. Noted: docs/facet-todo.md:30-36 claims section 1 is empty and "the texel buffers read every format Vulkan 1.0 asks of them" — wrong by exactly these three pack32 forms.

### 32. Define BLIT_SRC and BLIT_DST and report them

*formats / FormatProperties bitmask* &mdash; conformance-blocking, small

After: Items 33-40 for the formats facet cannot yet draw into or sample

FORMAT_FEATURE_BLIT_SRC (1<<10) and BLIT_DST (1<<11) do not exist in facet's bitmask, so facet reports neither for any format on either device — although CmdBlitImage is in the jump table and documented as taking "images of colour, of any formats". Vulkan mandates BLIT_SRC for 47 formats and BLIT_DST for 38. Defining the bits and setting them for what CmdBlitImage already reads and writes is small; the rest of the coverage rides on items 33-40.

> Verified by listing the constants: facet.zig:825-839 defines bits 0, 1, 3, 4, 6, 7, 8, 9, 12, 14, 15 — Vulkan's bits 2, 5, 10 and 11 (the two atomics and the two blits) are all absent. command/cmdblitimage.zig:22 for the docstring.

### 33. Decode the 45 mandatory vertex-attribute formats

*formats / vertex input* &mdash; conformance-blocking, medium

Vulkan mandates VERTEX_BUFFER for 45 formats; facet reports and implements 6. This is the best value in the formats strand: pure CPU work with no hardware in the way, since the vertex stage runs on the cores for both devices. One decode arm per format family — _unorm, _snorm, _uint, _sint, _sfloat at 8/16/32 bits, one to four channels, plus the packed 32-bit words. Note the narrowness is currently asserted by two tests, so they have to move with it.

> Verified verbatim: pipeline/_pipeline.zig:219-224 `attributeFormat` returns true for exactly `.r32_sfloat, .r32g32_sfloat, .r32g32b32_sfloat, .r32g32b32a32_sfloat, .r8g8b8a8_unorm, .b8g8r8a8_unorm`; :228-250 `decode` has arms for only those six and silently returns (0,0,0,1) otherwise; creategraphicspipelines.zig:315 refuses the rest. Tests assert the narrowness at tests/draw.zig:3256-3261 and src/disk/c/test/raster/facetprobe.zig:1278.

### 34. Make the sRGB, A8B8G8R8_PACK32 and 2-10-10-10 formats real images, not only texel buffers

*formats / sRGB and packed words* &mdash; conformance-blocking, large

After: Item 36 for the attachment half

R8G8B8A8_SRGB, B8G8R8A8_SRGB and A8B8G8R8_SRGB_PACK32 are mandatory for SAMPLED_IMAGE, FILTER_LINEAR, BLIT_SRC, COLOR_ATTACHMENT, BLIT_DST and BLEND; A8B8G8R8_UNORM_PACK32 the same plus vertex and both texel-buffer bits; A2B10G10R10_UNORM_PACK32 for sampled, filter-linear, colour attachment and blend. All exist in the enum and report optimal and linear features of 0 — texel buffer only, so no image of them can be made on either device. The texel-buffer reader already decodes every one, so the work is reaching that decode from the texture path: a texture.Format for each, the sRGB transfer function on the way out of a sample and its inverse on the attachment store with blending in linear space, and a 10/10/10/2 texel for the packed pair. A8B8G8R8_UNORM_PACK32 is nearly free — facet documents it as the same bytes as r8g8b8a8_unorm on a little-endian machine, so it can alias that arm. R8_SRGB and R8G8_SRGB are not mandatory and may stay texel-buffer-only.

> Verified: driver/_format.zig:195-207 is a single arm ending `=> .{ .linear_tiling_features = 0, .optimal_tiling_features = 0, .buffer_features = texels },` and it holds r8_srgb, r8g8_srgb, r8g8b8a8_srgb, b8g8r8a8_srgb, a8b8g8r8_unorm_pack32, a8b8g8r8_srgb_pack32, both a2r10g10b10 and both a2b10g10r10 kinds, r8g8b8a8_snorm and the 16-bit channels. Decode exists for texel buffers at sdk/libs/facet/shader.zig:538-546.

Found independently by: formats (2 items), semantics (1 item) — 3 overlapping findings merged.

### 35. Add a wider depth format and a conformant combined depth+stencil format

*formats / depth-stencil* &mdash; conformance-blocking, large

Vulkan requires DEPTH_STENCIL_ATTACHMENT for at least one of X8_D24_UNORM_PACK32 and D32_SFLOAT, and for at least one of D24_UNORM_S8_UINT and D32_SFLOAT_S8_UINT. facet has none of the four. Its three depth formats are d16_unorm, s8_uint and d16_unorm_s8_uint, and of those only D16_UNORM is in the spec's table at all — S8_UINT and D16_UNORM_S8_UINT are explicitly optional in 1.0, so they earn no credit. Both "at least one of" rules therefore fail. The work reaches the whole depth path: the tile's depth plane is 16 bits (colour 16 KiB plus depth 8 KiB for a 64x64 tile), stored depth rows are 2 bytes a pixel, the V3D's STORE_Z writes the top 16 bits of a deeper hardware number, and sampled depth reads texture.Format.d16. A 24- or 32-bit plane doubles the tile's depth budget, which is the same cache argument that blocks multisampling.

> Verified by enumerating the Format enum's depth members: exactly `d16_unorm = 124`, `s8_uint = 127`, `d16_unorm_s8_uint = 128` — 125 (x8_d24), 126 (d32_sfloat), 129 (d24_s8) and 130 (d32_s8) are absent. driver/_format.zig:75-84 are the only DEPTH_STENCIL_ATTACHMENT entries; image/_image.zig:128-135 and :207-231 for hasDepth/hasStencil and bytesOf.

Found independently by: formats, semantics, conformance-path (3 strands).

### 36. Make the mandatory colour-attachment formats drawable

*formats / colour attachments* &mdash; conformance-blocking, large

Vulkan mandates COLOR_ATTACHMENT for 38 formats and COLOR_ATTACHMENT_BLEND for 14. facet provides 3 of each, hard-coded in a two-line `drawable()` and enforced by CreateImage. The missing 35 are the integer attachments, the three sRGB words, the half- and single-float forms, a2b10g10r10 both ways, a8b8g8r8_*_pack32 and a1r5g5b5. This is the largest piece in the formats strand: the tile buffer keeps 8 bits a channel of BGRA, dithered to 565 on store, so each new format needs a tile representation, a store, a load, a clear and — for the 11 blendable ones — a blend unit at that width. On the V3D the render-target config packets must name the format too. The same fix closes the colour-input-attachment gap, since an input attachment must be of a format rowFormat knows, which is the same three.

> Verified verbatim: src/disk/libs/facet/surface/_surface.zig:78-80 `return format == .b8g8r8a8_unorm or format == .r8g8b8a8_unorm or format == .r5g6b5_unorm_pack16;`; image/_image.zig:498 `if (info.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT != 0 and !drawable(info.format)) return null;`; driver/_format.zig:45-58 are the only arms setting `attachment`; render/createrenderpass.zig:238 for the input-attachment half.

Found independently by: formats, conformance-path, semantics (3 strands).

### 37. Sample the _snorm and half-float formats, and fill the storage-image gaps

*formats / sampled and storage images* &mdash; conformance-blocking, medium

R8_SNORM, R8G8_SNORM and R8G8B8A8_SNORM are mandatory for SAMPLED_IMAGE, BLIT_SRC and FILTER_LINEAR; R16_SFLOAT and R16G16_SFLOAT for those plus COLOR_ATTACHMENT, BLIT_DST and BLEND. All five exist in the enum and report texel-buffer features only. The read path exists for texel buffers, so what is missing is texture.Format entries and the sample/filter path — and for _snorm a signed -1..1 channel the tile's 8-bit unsigned colour cannot hold, so the wide-channel machinery has to take signed channels. Separately 16 formats must report STORAGE_IMAGE and the cores miss two: R8G8B8A8_SNORM and R32G32_SFLOAT, the latter sharing an arm with r32g32b32_sfloat that reports 0 in both tilings, so no image of two floats exists on either device although four of the other float formats do.

> Verified: driver/_format.zig:136 `.r32g32_sfloat, .r32g32b32_sfloat => .{ .linear_tiling_features = 0, .optimal_tiling_features = 0, .buffer_features = vertices | texels }`; :181-207 put r16_sfloat, r16g16_sfloat, r8_snorm, r8g8_snorm, r8g8b8a8_snorm and the three 16-bit _snorm forms in the texel-only arm; image/_image.zig:178-183 wideChannels() covers only the four _unorm wide formats. Noted: docs/facet-gaps.md:770-771 ("There is no r16_sfloat or r16g16") is stale and contradicts the same document twenty lines earlier.

### 38. Finish one complete compressed-format table, and BC is the cheapest

*formats / compressed* &mdash; conformance-blocking, medium

After: The sRGB decode, shared with item 34

Vulkan requires SAMPLED_IMAGE, BLIT_SRC and FILTER_LINEAR in optimalTilingFeatures for every format in at least one of the BC, ETC2/EAC or ASTC tables. facet completes none: 9 of 16 BC (missing BC1_RGB_SRGB, BC1_RGBA_SRGB, BC2_SRGB, BC3_SRGB, BC4_SNORM, BC5_SNORM, BC7_SRGB), 5 of 10 ETC2/EAC (the three ETC2 _SRGB forms and both EAC _SNORM), 0 of 28 ASTC. Cheapest route is the 7 BC formats: four are the sRGB forms of blocks already decoded, sharing the transfer function with item 34, and two are the signed variants of BC4/BC5 already implemented unsigned. Neither document says the three tables are an either/or requirement that facet currently fails entirely.

> Verified: sdk/libs/facet/facet.zig:710-753 is the whole compressed set; driver/_format.zig:87-100 the two compressed arms, read in full above; no occurrence of "astc" under sdk/libs/facet/ or src/disk/libs/facet/ except a prose mention at facet_version.zig:1075. facet_version.zig:1074-1077 calls the omissions deliberate.

### 39. Add the atomic format-feature bits and the atomics behind them

*formats / atomics* &mdash; conformance-blocking, medium

STORAGE_IMAGE_ATOMIC (bit 2) and STORAGE_TEXEL_BUFFER_ATOMIC (bit 5) are mandatory for R32_UINT and R32_SINT, and neither bit exists in facet's set. This is not reporting work: there is no atomic operation anywhere in the shader SDK, and SPIR-V's OpAtomic* on a storage buffer is core under the Shader capability. On the cores it is LL/SC or a lock-free CAS over the texture's words; on the V3D it is the TMU's atomics, which the compiler does not reach. The gap list's "two functions writing the same texel is for the program to avoid - as it is in Vulkan, there being no barrier and no atomic here either" is simply wrong about Vulkan, which has both as core.

> Verified: facet.zig:825-839 skips bits 2 and 5; `grep -n 'atomic|barrier' sdk/libs/facet/shader.zig` finds only :1554, a prose line about compute barriers; driver/_format.zig:35 `const storage = facet.FORMAT_FEATURE_STORAGE_IMAGE;` with no atomic companion. docs/facet-gaps.md:216-225 and :319 for the wrong claim.

Found independently by: formats, semantics.

### 40. Give the V3D the same mandatory format set as the cores

*formats / per-device* &mdash; conformance-blocking, large

After: Item 3 (format_properties seeing the device)

Vulkan's required format support is per physical device and facet lists two. The V3D calls the non-keeping wrapper, which returns 0 optimalTilingFeatures for the wide-channel family (r8g8_unorm, r16_unorm, r16g16_unorm, r16g16b16a16_unorm) and for all eighteen whole-number formats, and drops TRANSFER_SRC from the compressed and float ones — so CreateImage answers error_format_not_supported there for every _uint/_sint and for r8g8_unorm, which is in the mandatory table with SAMPLED_IMAGE, FILTER_LINEAR, COLOR_ATTACHMENT and BLEND. Measured against the table the V3D is 37 of 47 short on SAMPLED_IMAGE where the cores are 18 short, and 12 of 16 short on STORAGE_IMAGE where the cores are 2 short. Closing it means the TMU reading its own channel widths and whole numbers rather than being fed library-unpacked 8888: tiling and TMU-config work plus QPU programs that return integers. Unlike kept_compressed and kept_floats, where the format is still accepted and the library unpacks it, this is a flat refusal.

> Verified: driver/cpu/cpu.zig:46 `.format_properties = &_format.keptProperties` against driver/v3d/driver.zig:54 `.format_properties = &_format.properties`; driver/v3d/driver.zig:173-189 `.wide_channels = false`, `.whole_textures = false`, `.kept_compressed = false`, `.kept_floats = false`; enforcement at image/_image.zig:365 and :371 `if (wholeNumbers(info.format) and !(physical.features.whole_textures and in_texels)) return null;`; the `if (keeps_blocks)` gates at driver/_format.zig:147-180.

Found independently by: formats, features (2 items: wide_channels and whole_textures).

### 41. Honour a non-identity component swizzle on an image view

*image views* &mdash; conformance-blocking, medium

CreateImageView refuses any ComponentMapping that is not the identity, with error_format_not_supported. VkComponentMapping is core 1.0 with no feature or limit gating it: a view of a mandatory sampled format must accept any of r/g/b/a/zero/one in any slot. The structure exists and is read only to be rejected. Lifting it means the swizzle reaching the sampling path — baked into the view's texture.Texture for the cores, or written into the TMU's own swizzle words for the V3D, which tiling.zig already uses for R8. This was found by one strand and is in neither document.

> Verified verbatim: image/createimageview.zig:107 `if (info.format != image.given_format or !identity(info.components)) return .error_format_not_supported;` and :160-166 `fn identity` (each channel from itself or .identity). sdk/libs/facet/facet.zig:1086 ComponentMapping, :1166 `components: ComponentMapping = .{}`.

### 42. Accept VK_IMAGE_CREATE_MUTABLE_FORMAT and a compatible view format

*images / image views* &mdash; conformance-blocking, medium

facet defines two image create flags — CUBE_COMPATIBLE (1<<4, Vulkan's value) and its own PACKED_TEXELS (1<<31) — and reads only those two. Vulkan's MUTABLE_FORMAT (1<<3) is therefore accepted and silently ignored, and CreateImageView then refuses any view whose format differs from the image's. With the flag set a Vulkan application may legally take a view of any format of the same texel block size, which is how a UNORM image is written as UINT or read as sRGB. Needs the view carrying its own texture.Format over the image's memory, which texelsOver and levelsFrom are already parameterised enough to do for same-size formats, plus validating the flag.

> Verified: `grep -n 'IMAGE_CREATE_' sdk/libs/facet/facet.zig` -> only :976 CUBE_COMPATIBLE and :988 PACKED_TEXELS; `grep -n 'info.flags' src/disk/libs/facet/image/_image.zig` -> :345 and :353 only; the view refusal is the same line as item 41.

### 43. Accept a subpass with no colour attachment

*render passes* &mdash; conformance-blocking, medium

CreateRenderPass refuses color_attachment_count == 0, so a depth-only subpass — the canonical shadow-map pass, and the depth pre-pass as Vulkan writes it — cannot be described at all. Vulkan allows colorAttachmentCount = 0 with a depth/stencil attachment and no colour. Lifting it means the render-pass plan, the tile layout and both drivers' part code tolerating zero colour planes: the cores' tile always carries a colour buffer per part and the V3D's render-target configuration names a colour format. facet has PIPELINE_CREATE_DEPTH_PREPASS as its own answer to the same need, which is why this went unnoticed; it is in neither document.

> Verified verbatim: render/createrenderpass.zig:276 `if (subpass.color_attachment_count == 0 or subpass.color_attachment_count > _render.most_colors) return .error_feature_not_present;`.

### 44. Allow a both-aspect view of a sampled depth+stencil image

*image views / depth* &mdash; **done in 1.94**, small

For an image whose kind is depth and which carries IMAGE_USAGE_SAMPLED, CreateImageView routes through depthPlane, which returns null — error_format_not_supported — for an aspect mask naming both planes. Vulkan 1.0 requires a depth/stencil attachment view of a format holding both to name both aspects; separate depth/stencil layouts arrived in 1.2. So a d16_unorm_s8_uint image that is both the pass's depth/stencil attachment and a sampled shadow map cannot have a conformant attachment view: one-plane views work, the two-plane one the attachment needs does not. A plain unsampled depth attachment view is unaffected. Narrow, but a hard refusal of a structure Vulkan requires.

> Verified: image/createimageview.zig:125-131 `const plane = if (_image.sampledDepth(image)) _image.depthPlane(...) orelse return .error_format_not_supported`; _image.zig sampledDepth is `image.kind == .depth and image.usage & IMAGE_USAGE_SAMPLED != 0`. The gap list records the behaviour as a facet choice, not as a Vulkan requirement the attachment view cannot meet.

**Done in 1.94, and the requirement is a little different from what this said.** Vulkan does not require an attachment view to name both aspects. It *allows* a view of a depth/stencil format to name both ("can include both"), and it has an attachment ignore the view's aspect: "When an image view of a depth/stencil image is used as a depth/stencil framebuffer attachment, the aspectMask is ignored and both depth and stencil image subresources are used" (resources.adoc). A descriptor's view must name one (VUID-VkDescriptorImageInfo-imageView-01976). So the refusal turned away a view Vulkan permits, and naming both is how a program would write that view. The same refusal applied to an input-attachment image, through `depthRows`, which uses the same `planeAt`.

The port is lavapipe's: `lvp_CreateImageView` makes the view, and `lvp_create_samplerview` samples the combined format unless the aspect is the stencil alone (lvp_image.c:358), so a both-aspect view's texture is the depth. In facet that is `_image.planeAt` mapping both aspects of a format that holds both to the depth plane. Both aspects of a format with one plane still name a plane it has not got, and are still refused. Nothing changed in the drawing: the cores take an attachment's planes from the image, not from the view (`driver/cpu/_play.zig` `planeAt`), and the V3D samples no depth image at all. A test makes the view, finds its texture the depth plane, and clears and stores both planes through it as a pass's attachment.

The test of the refusals that stay had never reached the aspect check. A `2d` view of all three layers of its image is refused for its layers first, because `layer_count` defaults to `REMAINING`, so it now names one layer. Each of three reverts fails the test alone: the refusal put back, the stencil taken for both, and both taken of a format with one plane.

### 45. Create a timestamp query pool on a machine without timer.device

*query pools* &mdash; **done in 1.93**, small

CreateQueryPool refuses QueryType.timestamp outright wherever timestamp_queries is false, which is any machine without timer.device — the host tests run that way, so this bites the shim's own test bed. Vulkan has no mechanism to refuse a timestamp pool: vkCreateQueryPool must succeed, and the device says it cannot time things through timestampValidBits = 0 on the queue family and timestampPeriod. One line in the refusal, plus making CmdWriteTimestamp a recorded no-op and GetQueryPoolResults answer not-available, which _queries.stamped already returns false for.

> Verified verbatim: query/createquerypool.zig:89 `.timestamp => if (!features.timestamp_queries) return .error_feature_not_present,`; driver/_queries.zig:44-52 stamped() already returns false where there is no clock; instance/_instance.zig:88-92 clears the feature on every device when timer.device is absent.

**Done in 1.93: the refusal was the whole fault, and the item was wrong about what a timestamp does without a clock.** The quote above is not verbatim: the line read `can.timestamp_queries`, and the clearing is in `_instance.describe`. Nor did `_queries.stamped` ever return false for want of a clock. It writes `_base.now`, which is 0 without timer.device, makes the query available, and returns false only for a pool of another kind or a query past its last. That is the right behaviour, and the change asked for here - a recorded no-op, the query left unavailable - would have been wrong:

- The specification gives such a queue's timestamps no meaningful bits, and says of `timestampValidBits` that "Bits outside the valid range are guaranteed to be zeros" (devsandqueues.adoc). With no bits valid, every bit is outside the range, so 0 is the value.
- Writing a timestamp there is invalid usage (VUID-vkCmdWriteTimestamp-timestampValidBits-00829), so nothing conformant reaches it. What one written regardless should not do is hang: a query that never becomes available leaves a `QUERY_RESULT_WAIT` read waiting for ever, and one available at 0 returns.

So one line went, and nothing else in the path changed. In vk.xml, `vkCreateQueryPool`'s error codes are out of host memory and out of device memory, with `VK_ERROR_UNKNOWN` and `VK_ERROR_VALIDATION_FAILED` added since. No kind of pool is refused.

One more fault came with it. `timestamp_compute_and_graphics` stayed true without a clock, beside timestamp bits of 0, and its true says that every graphics and compute queue supports "timestampValidBits of at least 36" (limits.adoc, `limits-timestampComputeAndGraphics`). It is cleared with the other two now.

The host has no timer.device, so the test runs there. The pool is made, a timestamp written into it reads 0 and available without waiting, and the limit reads false. Each of four reverts fails it alone: the refusal put back, the limit left true, the query left unavailable, and a value other than 0.

### 46. Give a compute workgroup a barrier

*synchronisation / compute* &mdash; conformance-blocking, large

After: The shape of shader.Groups — serial invocations in one call — having to change

A change to the compute entry's contract, not a call to add. A compute function is called once per workgroup and loops its own invocations serially inside that one call, so the SDK tells a program that "a barrier is the point between two loops over them inside the one call": a shader using barrier() has to be rewritten by hand. Vulkan 1.0 core has OpControlBarrier and OpMemoryBarrier with no feature bit, so a conformant program notices at once. On the cores it needs invocations that can be suspended — coroutines, or the function split into one pass per barrier region — with the SPIR-V reader splitting basic blocks at opcode 224; on the V3D the QPUs have no shared memory the driver drives at all.

> Verified: sdk/libs/facet/shader.zig:1553-1555 for the contract; `grep -nE 'control_barrier|memory_barrier|= 224|= 225' sdk/libs/facet/spirv.zig` returns nothing, so the reader's Op enum has neither; command/cmddispatch.zig:52 "Barriers are taken and need do nothing: the cores run a command at a time". docs/facet-todo.md:83 labels it 1.0 core correctly.

Found independently by: objects-commands, formats (via the atomics item).

### 47. Decide whether an image layout ever means anything

*barriers / layouts* &mdash; **settled by Mesa, 0 lines**: neither lavapipe nor v3dv gives a layout any meaning in memory, so facet's recorded barrier is already the port

CmdPipelineBarrier discards every memory, buffer and image barrier it is handed along with dependency_flags, and records only the two stage masks; nothing is checked against an attachment reference's layout or a descriptor's imageLayout either. On a serial single-queue device that is behaviourally conformant, and Vulkan permits an implementation whose layouts are all the same layout. But it is also why an image's kind is baked at CreateImage, and so the direct cause of item 48: with no transition there is nowhere for a rows image to become a texture. The decision is whether a barrier ever re-tiles memory — which makes render-to-texture possible and costs a pass over the image — or whether facet states permanently that layouts are nominal and render-to-texture is a copy. Everything in item 48 follows from this answer, so it comes first.

> Verified by reading the whole function: command/cmdpipelinebarrier.zig:67-78 — `_ = dependency_flags; _ = memory_barrier_count; _ = memory_barriers; _ = buffer_barrier_count; _ = buffer_barriers; _ = image_barrier_count; _ = image_barriers;` then records only `_command.Barrier{ .src_stage_mask, .dst_stage_mask }`. image/_image.zig:5-19 "**What an image is for decides how it lies in its memory.** Its kind is settled as it is made"; both players are `.barrier => {}`.

Found independently by: semantics, objects-commands (whose finding is that the no-op is safe today, and why).

**Settled by Mesa, 07.11.2026, and the premise above was wrong.** Neither Mesa driver gives an image layout any meaning in memory:

- lavapipe's `handle_pipeline_barrier` (lvp_execute.c:3435-3506) is `finish_fence` (350-361), which is a stall. Its one other path is for emulated compressed images leaving `VK_IMAGE_LAYOUT_ZERO_INITIALIZED_EXT`, an extension facet does not have. `lvp_TransitionImageLayoutEXT` is `/* no-op */` (lvp_image.c:1068-1073).
- v3dv's `v3dv_cmd_buffer_emit_pipeline_barrier` (v3dv_cmd_buffer.c:3456-3531) reads `oldLayout` only to skip barriers out of UNDEFINED (3484-3487). `v3dv_TransitionImageLayout` is a no-op (v3dv_host_copy.c:479-485).
- Both settle an image's layout at CreateImage (`lvp_alloc_plane`, lvp_image.c:35-165; `v3dv_image_init`, v3dv_image.c:481-483), and both draw into the memory they sample.

So facet's barrier, which records the two stage masks and plays as nothing on both devices, is already what the port would write: 0 lines. The choice above - re-tile at a barrier, or render to a texture by copying - is a false one, because Mesa does neither. And item 48 does not follow from this item. Its cause is that facet picks one of two layouts by usage, where llvmpipe has one layout for every bind.

### 48. Accept an image that is both SAMPLED and COLOR_ATTACHMENT

*images / render to texture* &mdash; port, about 420 lines: about 90 on the cores, about 62 on the V3D, about 11 for a V3D clear, and about 257 of tests and docs

An image's layout is settled at CreateImage from its usage — rows for an attachment, blocks of texels for a texture — and shapeFor returns null for SAMPLED or STORAGE together with COLOR_ATTACHMENT, so the ordinary Vulkan render-to-texture image cannot be made. Vulkan requires B8G8R8A8_UNORM and R8G8B8A8_UNORM to carry both COLOR_ATTACHMENT and SAMPLED in optimalTilingFeatures and gives no mechanism to refuse the combination; facet's own format table advertises attachment, sampled and storage in the one optimal mask, so the report and the refusal contradict each other. This cannot be fixed by adding a check: it needs either a layout transition that re-tiles the image in place, or a rasterizer that stores tiles straight into the texture layout. The workaround programs use today — draw into a rows image, CmdCopyImage into a texture image — is a copy a Vulkan program does not make. The single largest omission from the gap list.

> Verified verbatim: image/_image.zig:481-482 `if (info.usage & (facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_STORAGE) != 0 and !rows_written) { if (info.tiling != .optimal or info.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT != 0) return null;`; _image.zig:18-19 for the stated reason; driver/_format.zig:46-49 advertises all three usages in one mask; getphysicaldeviceimageformatproperties.zig:78-80 says the usages are asked about one at a time; facetprobe.zig:1884 asserts the refusal.

Found independently by: semantics, formats (2 strands, both calling it structural).

**Sized from Mesa, 07.11.2026.** Mesa renders into a texture's own memory, with no copy and no re-tiling:

- llvmpipe lays every texture out the same way whatever it is bound as (`llvmpipe_texture_layout`, lp_texture.c:154-223; `llvmpipe_resource_create_all`, 296-409). The rasteriser writes the mapped level (`init_scene_texture`, lp_scene.c:159-185; `lp_rast_tile_begin`, lp_rast.c:107-138), and the sampler reads the same bytes (`lp_jit_texture_from_pipe`, lp_jit.c:400-437).
- v3dv makes every optimal image UIF whatever its usage (v3dv_image.c:481-483). The TLB's store and load name that layout in their Memory Format and Height in UB fields (`cmd_buffer_render_pass_emit_load` and `_store`, v3dvx_cmd_buffer.c:149-211 and 341-415), and the TMU reads the same slices (`pack_texture_shader_state_helper`, v3dvx_image.c:54-64 and 116-118).

The port has three parts:

- **The cores.** A COLOR_ATTACHMENT|SAMPLED image is kept in rows of levels and layers, in facet's 1.63 layer-major arrangement, and sampled where it lies, as a sampled depth already is. llvmpipe's R8G8B8A8 fetch, red and blue exchanged, comes with it (lp_linear_sampler.c:89-97, 738-758).
- **The V3D.** The existing store and load packets get their Memory Format, for every level, and Height in UB, for UIF levels only, over the UIF layout already ported.
- **A V3D clear.** CmdClearColorImage writes the device's own layout; v3dv clears through the TLB (v3dv_meta_clear.c:70-193).

Two sentences above are wrong. The fix needs neither "a layout transition that re-tiles the image in place" nor a new rasterizer. And STORAGE with COLOR_ATTACHMENT has been made in rows since 1.56: it is refused only for r8g8b8a8, or with levels or layers. The citations have drifted. At 1.91 the refusal is at image/_image.zig:504-505, the format masks at driver/_format.zig:61-74, and the probe's check at facetprobe.zig:1017.

### 49. Reconcile GetPhysicalDeviceFeatures with VkPhysicalDeviceFeatures, and decide what replaces the missing enable step

*features / struct shape* &mdash; **done in 1.82**, also serves the shim

**Done in 1.82, and the item's framing was wrong in a way worth recording.**
`PhysicalDeviceFeatures` is `VkPhysicalDeviceFeatures`, 55 `Bool32` members,
220 bytes where facet's 49 Zig `bool` were 49. facet's 49 are the library's
own record now - `_instance.Capabilities`, read as `physical.can.X` - and
still decide what every create call refuses, which is what they were for.

What the item got wrong: it says "about 35 of facet's fields gate things
Vulkan 1.0 requires unconditionally", which is true of the *functionality*
and says nothing about the features. Measured against the specification's
own "Feature Requirements" section, **Vulkan 1.0 requires exactly one of
the 55** - `robustBufferAccess`, of an implementation not advertising
`VK_KHR_portability_subset` - and the section ends "All other features
defined in the Specification are optional". So reporting a false is usually
honest rather than a defect, and the 49 were never a list of Vulkan
features at all.

And facet has that one feature, which was the surprise. Every buffer a
function reaches is bounded by the descriptor's own range -
`shader.Resources.bufferAt` answers null where the range does not hold the
type, `storageAt` hands back a Zig slice of `range / @sizeOf(T)` elements,
`texels` carries a count worked out the same way - and an attribute read
past the end of its vertex buffer is left at the `(0, 0, 0, 1)` the inputs
were cleared to, which is the behaviour Vulkan's robustness rules name for
exactly that case (`driver/_vertices.zig` `readInputs`).

**A false is not free, though**, and this is the part the item does not
mention: Vulkan's required-limits table gives most limits two values, one
for the feature off and one for it on, and the off value is *mandatory*. So
each answer ties a limit too - `sampler_anisotropy` false forces
`maxSamplerAnisotropy` to 1, `multi_viewport` false forces `maxViewports`
to 1, `shader_clip_distance` false forces `maxClipDistances` to 0, and
`tessellation_shader` false forces all eight `maxTessellation*` to 0.

That last one cost a capability on paper. The library tessellates, but
`spirv.facet_profile` leaves `Profile.stages` at vertex and fragment, so
`takesStage` refuses a tessellation entry point and a program bringing
SPIR-V cannot declare either stage - which is what this call is asked by.
So `tessellation_shader` is false, the eight limits read 0, and what
facet's own Zig surface does is said by `shader.Patch` instead. Item 60 is
the SPIR-V side of it.

Two more were nearly overclaimed and are worth the warning:
`texture_compression_etc2` and `texture_compression_bc` are promises about
a *whole family* of formats, and measured against the header the ETC2 and
EAC family is ten formats where five are here and the BC family is sixteen
where nine are. Neither bit may be set however much of each is decoded;
GetPhysicalDeviceFormatProperties is where a program should look.

**The enable step exists now.** `DeviceCreateInfo.enabled_features` is
Vulkan's `pEnabledFeatures`, compared member by member against what the
device has, answering `error_feature_not_present` - which is the one call
Vulkan lists that code for, and item 81 is the dozen calls facet answers it
from that Vulkan does not. What Vulkan leaves undefined, using a feature
without having enabled it, this library still refuses at the call, which is
a permitted way to implement undefined behaviour and the useful one.

The entry point has Vulkan's name and arity and writes a structure of facet's own: 49 bool fields chosen so there is one wherever a create call can refuse something, against VkPhysicalDeviceFeatures' 55 VkBool32 members overlapping in about 14 places. A conformant caller reading a VkPhysicalDeviceFeatures out of it gets nonsense. Worse, about 35 of facet's fields gate things Vulkan 1.0 requires unconditionally — depth_test, stencil_test, blending, indirect_draws, several_subpasses, texture_arrays, cube_maps, textures_3d, samplers, input_attachments, several_outputs, storage_images, texel_buffers, dynamic_descriptors and the rest — and six are facet's own idea with no Vulkan meaning (own_fragment_functions, sampling_format, compute_on_device, tessellation_on_device, depth_prepass, discarding_fragment_forms). All 35 read true on the cores, so the cores are not blocked by the gates existing; on the V3D eleven read false and each is a conformance block for that device. And VkDeviceCreateInfo's pEnabledFeatures has no counterpart at all, so there is no step at which a program enables a feature — facet simply refuses what a device cannot do at the call that would use it. Vulkan's model, enable at device creation with undefined behaviour if used unenabled, is a different contract for the whole surface and cannot be bolted on. Also fold in the two fields that displace real Vulkan features (tessellation_on_device and compute_on_device answer "where", which Vulkan has no notion of, while tessellationShader has no field) and CommandBufferInheritanceInfo's three missing query members, which mean facet cannot express inheritedQueries rather than merely decline it.

> Verified by script: 49 bool fields; cores set 46 true, V3D 26; 20 differ; 3 false on both. The design is stated at facet.zig:257-268 "There is a field here where a create call can refuse something." facet.zig:663-667 DeviceCreateInfo carries flags and the queue infos only — no enabled-features pointer. facet.zig:1368-1372 CommandBufferInheritanceInfo is render_pass, subpass, framebuffer and nothing else. cpu.zig:113-114 and driver/v3d/driver.zig:147-148 for the two "where it runs" fields.

Found independently by: entry-points, features (3 items), doc-staleness (4 strands).

### 50. Address an input attachment the way Vulkan does, by InputAttachmentIndex

*input attachments* &mdash; structural, large, also serves the shim

In facet, which attachment a fragment function reads is the descriptor it reads it through; input_attachment_index does not exist. In Vulkan the subpass's pInputAttachments index *is* the addressing — a SPIR-V shader carries OpDecorate %x InputAttachmentIndex n and the implementation maps n to the subpass's list. A SPIR-V shader written for Vulkan therefore cannot be compiled against facet's model without rewriting the decoration into a descriptor binding, and there is nothing to infer one from. Not a missing check: a different binding model, and it is load-bearing now that the SPIR-V reader is the input language.

> docs/facet-gaps.md:425-427 states the fact as a small absence; render/createrenderpass.zig:218-275 validates the subpass's input list and never indexes it from a shader; driver/v3d/compile.zig:205 `.image_dims = &.{.dim_2d}` — verified, no SubpassData and no decoration for it.

### 52. Carry sampler state into the IR, so a compiled shader honours the bound sampler instead of painting magenta **[critical path]**

*samplers / shader compiler* &mdash; conformance-blocking, large

After: nothing — it is the compiler path that exists today

**The cores' half is done in 1.83: no sampler makes this device paint
magenta any more.** `ir.zig`'s generated function carries the bound
sampler whole
where `texture.samplingOf` cannot collapse it into a `Sampling`, and
samples through `texture.sampleBy` a pixel at a time - which is the same
call the fixed form `shader.texturedBy` makes with the same sampler, so a
generated shader and a fixed form reached by one sampler paint the same
thing. A test holds the two together bit for bit over eleven samplers
`samplingOf` turns down: the three wraps an `Address` has no word for, a
wrap each way, a filter each way, linear mipmapping, a lod bias, a lod
clamp, anisotropy, a comparison, and unnormalized coordinates. The fast
path is unchanged and still takes a whole quad at a time, so the cost is
paid only by the samples that ask for more.

Two things were decided doing it. The sampler is carried **untouched**,
comparison included: a graph's `sample` is an ordinary sample and has no
reference operand, there being no Dref operation in this IR, so a sampler
with `compare` set compares against 0 - which Vulkan leaves undefined,
since it forbids a `compareEnable` sampler to anything but an
`OpImage*Dref*`, and which is exactly what `texturedBy` already does with
that sampler beside a form that is not a shadow form. Matching the device
to itself was worth more than a tidier answer. And the cross-device
guard this item's magenta was built as still holds: the V3D paints
magenta where the cores now draw, which is a loud difference rather than
a quiet one - magenta is not a plausible picture and cannot be mistaken
for the other device's answer, which is what two plausible pictures would
have been. **The V3D's half is item 54**, which owns the remaining
magenta; closing it ends the difference.

This is the newest problem on the list and a regression on the cores, created at 1.79 and documented nowhere but a revision note. texture.samplingOf collapses a facet.Sampler into a three-field Sampling (format, one filter, one of two wraps) and returns null for a different min/mag filter, linear mipmapping, any lod_bias, any min_lod/max_lod clamp, anisotropy above 1, any compare, unnormalized coordinates, and three of the five address modes. On a null answer BOTH devices drop the texture and paint shader.missing (0xFFFF00FF, magenta) — deliberately wrong so the two devices cannot quietly draw different right answers. So for a generated pipeline the full sampler is now reachable only through the fixed forms on the cores. Lifting it means the IR carrying per-sample sampler state and two back ends honouring it; the cheap half — refuse the pipeline instead of drawing magenta — is small on its own and removes the only wrong-colour-on-purpose outcome in the library, though CreateGraphicsPipelines cannot see the bound sampler, so the clean refusal may have to happen at draw time, which Vulkan has no result code for.

> Verified: sdk/libs/facet/texture.zig:430-461 `samplingOf` with its seven null returns and the docstring "a sampler this cannot answer for is drawn by neither - the pixel is `shader.missing`, which is a wrong colour on purpose ... (Since 1.79.)"; ir.zig:586-597 `if (texture.samplingOf(bound, ...)) |said| ... else { pictures[which] = null; }`; driver/v3d/_play.zig:886-906 samplingBy; shader.zig:1801 `pub const missing: u32 = 0xFFFF_00FF;`.

Found independently by: semantics, features.

### 53. V3D: discard, lowered onto the flag registers **[critical path]**

*V3D compiler* &mdash; conformance-blocking, medium

After: qpu.zig growing condition codes and flag pushes

discarding_fragment_forms is false on the V3D, so the texture_cutout form is refused and drawn on the cores, and the compiler refuses OpKill outright. discard is core Vulkan 1.0 and core SPIR-V under the Shader capability with no feature bit, so a Vulkan fragment shader that discards must work. Needs the condition-flag and setmsf/flag-push machinery in qpu.zig, which the hand-written forms never use, plus the compiler keeping a live coverage mask across the thread sections. OpKill is already in the profile purely so the refusal can name the family rather than say "unknown word" — which is the right design and the right next step, per the IR document's own ordering.

> Verified: driver/v3d/driver.zig:150 `.discarding_fragment_forms = false`; the refusal read verbatim at driver.zig:460 `if (fixed.kind == .texture_cube_array or fixed.discards() or fixed.needsSampler() or pipeline.varyings != fixed.varyings()) return .error_feature_not_present;`; compile.zig:144-145 `Discards` with the comment "It drops pixels (OpKill), which wants the flag registers", thrown at :528; `.kill` kept in the profile at :197-203. docs/facet-ir.md:514-516 schedules discard next.

Found independently by: features, semantics, doc-staleness (3 strands).

### 54. V3D: a QPU program that reads the bound sampler for every form, with unnormalized coordinates and anisotropy **[critical path]**

*V3D compiler and TMU* &mdash; conformance-blocking, large

After: The SPIR-V -> QPU compiler; its 1.77-1.79 sampler path is the beachhead

samplers is false on the V3D, so CreateGraphicsPipelines refuses every fixed form needing one — texture_sampled, texture_shadow, texture_array_sampled, texture_cube_sampled, texture_3d_sampled, texture_cube_array_sampled — and the cores draw them. VK_DESCRIPTOR_TYPE_SAMPLER and COMBINED_IMAGE_SAMPLER are mandatory in Vulkan 1.0 and all sampler state bar anisotropy is unconditional, so for the V3D as a Vulkan device this is a conformance block, not a capability. Two halves: the compiler emitting the TMU sequence for each form — the generated path already does this for OpImageSampleImplicitLod on a 2D combined image sampler, so the shape exists — and a software path for what the TMU cannot express, since writeSamplerState takes only a filter and a wrap. unnormalized_coordinates is false only because samplers is, and Vulkan has no feature bit for it, so it rides in free; sampler_anisotropy is optional in 1.0, so that part is a clean capability (and until it lands, item 2 is the honest report).

**Since 1.83 this item also owns the last `shader.missing` in the library.** Item 52 was the pair of this one: a sampler `texture.samplingOf` could not collapse was drawn by neither device and the pixel was painted magenta on purpose, so that the two could not quietly draw different plausible pictures. The cores carry such a sampler whole now and draw it, so the magenta is this device's alone. `samplingBy` returning null is the only place left in facet where a *sampler* makes a draw paint a wrong colour on purpose; the other `shader.missing` paths, on both devices, are for a texture or a sampler that is not bound where the shader reads, which is a resource that is not there rather than one the device cannot express, and Vulkan calls reading it invalid usage.

> Verified: driver/v3d/driver.zig:154 `.samplers = false` with the comment "there is no program that reads a sampler", :155 `.sampler_anisotropy = false`, :158 `.unnormalized_coordinates = false` ("Nothing here reads a sampler at all"); refusal at driver.zig:460; TMU state is filter+wrap only at driver/v3d/tiling.zig:274 `writeSamplerState(into, filter, wrap)`; what a sampler may ask for at sdk/libs/facet/texture.zig:535-565 against samplingOf at :446-461.

Found independently by: features (3 items: samplers, unnormalized, anisotropy), semantics (2 items) — 5 findings merged.

### 55. V3D: a fragment program that writes several colour attachments in one call **[critical path]**

*V3D compiler* &mdash; conformance-blocking, large

After: The SPIR-V -> QPU compiler; qpu.zig tile-buffer writes

several_outputs is false on the V3D: each fragment program writes one colour, so a subpass of several attachments has its commands played once per attachment. That replay is behaviourally correct and facet's SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER flag is facet's own, so the flag's absence is not a Vulkan gap. What *is* a gap is that the compiler refuses a multi-output module outright with Error.Outputs, so a Vulkan G-buffer shader — maxColorAttachments >= 4, several OpDecorate Location outputs — cannot be compiled for that device at all, and the pipeline is refused rather than drawn. For the V3D exposed as a Vulkan physical device that is a conformance block; within facet it merely sends the draw to the cores. Needs the tile-buffer write path with a configuration per render target, plus the compiler tracking several colour outs.

> Verified: driver/v3d/driver.zig:202 `.several_outputs = false`; compile.zig:140-141 `Outputs` ("More than one colour out (`several_outputs`), or none"); refusals at render/createrenderpass.zig:283 and creategraphicspipelines.zig:265.

### 56. V3D: input attachments, through SubpassData in the compiler's profile **[critical path]**

*V3D compiler* &mdash; conformance-blocking, large

After: SubpassData in the compiler's profile

input_attachments is false on the V3D, so both a set layout with the kind and a subpass with input attachments are refused there. VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT and subpass input attachments are mandatory Vulkan 1.0 — maxPerStageDescriptorInputAttachments and maxDescriptorSetInputAttachments have required minimums of 4 and no feature gates them — so a physical device refusing them entirely is non-conformant as a Vulkan device. The compiler is now the route rather than the blocker: the profile needs SPIR-V's SubpassData dimension and an image read, and the QPU side needs to read either the tile buffer or the attachment's rows, which the cores already do through Fragments.keptAt.

> Verified: driver/v3d/driver.zig:225 `.input_attachments = false`; refusals at render/createrenderpass.zig:222 and :268 and descriptor/createdescriptorsetlayout.zig:112; compile.zig:205 `.image_dims = &.{.dim_2d},` with no dim_subpass_data and no image-read opcode in the list at :188-203.

Found independently by: features, semantics (both conformance-blocking).

### 57. V3D: storage images, in the layout the TMU reads **[critical path]**

*V3D* &mdash; conformance-blocking, large

storage_images is false on the V3D, so a storage_image descriptor layout is refused there. VK_DESCRIPTOR_TYPE_STORAGE_IMAGE is a mandatory Vulkan 1.0 descriptor type and maxPerStageDescriptorStorageImages >= 4 has no gating feature — only shader *writes* are gated, by the optional fragmentStoresAndAtomics and vertexPipelineStoresAndAtomics — so refusing the layout outright is a conformance block even though refusing writes would not be. The stated reason is that a V3D texture lies the way its TMU reads it, which is not the layout the library writes, so a function writing texels would write the wrong layout. Either the library learns to encode and decode the V3D's layout, or a storage image there gets a linear shadow copy. Note the compiler's profile also has no image-write opcode and no storage class that could express one.

> Verified: driver/v3d/driver.zig:216 `.storage_images = false,` with the comment at :213-215 ("A V3D texture lies the way its TMU reads it, which is not the layout the library writes"); refusal at descriptor/createdescriptorsetlayout.zig:107; compile.zig:188-206 has no image write and storage classes only input/output/function/uniform_constant.

### 58. V3D: a sampled depth image through the TMU **[critical path]**

*V3D* &mdash; conformance-blocking, medium

After: V3D samplers (for the compare op); item 3 makes the report honest first

sampled_depth is false on the V3D: an image of d16_unorm with IMAGE_USAGE_SAMPLED is refused there, so a shadow map must be copied rather than sampled where it lies. Vulkan mandates SAMPLED_IMAGE and BLIT_SRC for D16_UNORM on every physical device, so this is the conformance failure that item 3's honest gating exposes. Needs a depth format in the TMU's table, or the library handing the TMU a 16-bit single-channel texture that reads as depth, plus the compare-against-reference path, which is sampler state the TMU cannot express today.

> Verified: driver/v3d/driver.zig:178 `.sampled_depth = false` with the comment "Its texture unit keeps a texture its own way, and knows no depth format"; enforcement at driver/_format.zig:73 and image/_image.zig:433 `if (!physical.features.sampled_depth) return null;`.

Found independently by: features, formats.

### 59. Grow the compiler's profile: integers, branches, uniform buffers, push constants, arrays, cubes and 3D, and a register allocator **[critical path]**

*V3D compiler profile* &mdash; conformance-blocking; a port of Mesa's v3d back end from VIR down, with the 7.1 QPU encoder: about 13,950 required Mesa lines become about 11,950 facet lines, 920 of them items 55 and 60's, plus about 430 for what is optional

The single largest body of work behind every V3D item above, and the place about twenty VkPhysicalDeviceFeatures shader-capability members actually live. At 1.79 the back end takes: the Shader capability; 32-bit float and vectors of 2 to 4 (no int, no bool, no f64); storage classes input, output, function and uniform_constant — so NO uniform buffer and NO push constant read from a fragment shader; 2D images only; the fragment stage only; one basic block, so no branch of any kind; one colour out at location 0; about 28 opcodes (f_add, f_mul, vector_times_scalar, composite extract/construct, one image sample — no f_sub, no f_div, no dot, no ExtInst so no GLSL mix/clamp/pow/sqrt); one TMU sample per shader even where several samplers are declared; and no register spilling. Vulkan 1.0 requires all of the descriptor kinds behind those storage classes of any implementation (12 uniform buffers, 4 storage buffers, 16 sampled images, 4 storage images, 4 input attachments per stage). Growing it means qpu.zig gaining the full add/mul tables, pack/unpack, condition flags, branches with their delay slots and the SFU ops, plus a register allocator and a scheduler. On the cores these features are vacuously satisfied, since a shader is a Zig function that may do anything the CPU can.

> Verified by reading the profile in full: compile.zig:188-207 — `.capabilities = &.{.shader}`, the opcode list, `.storage_classes = &.{ .input, .output, .function, .uniform_constant }`, `.image_dims = &.{.dim_2d}`, `.stages = &.{.fragment}`. The error set naming each limit is compile.zig:126-180 (Type, Storage, Location, Outputs, Varyings, Discards, Branches, Body, NoColor, Steps, Uniforms, Registers, TooLong, Samplers, Declared, Numbered). compile.zig:96 most_samplers = 16 against driver.zig:436's single field. The profile's own comment: "It grows a family at a time - discard and samplers first."

Found independently by: features, semantics, conformance-path, doc-staleness (4 strands).

**Sized from Mesa, 07.11.2026.** The files from VIR down port as they are:

- broadcom/compiler: VIR and its lowering to QPU code, liveness, the register allocator with its spilling, the scheduler and the validator;
- the 7.1 path of broadcom/qpu's qpu_pack.c.

What Mesa does in NIR before VIR is redone in compile.zig's SPIR-V walk. The optional lines are pairing (about 750 Mesa lines), the vir_opt_* passes (about 1,220) and the disassembler (781).

The item's own description is wrong in four places at 1.91:

- The profile has 34 opcodes, not about 28. Two of them, `kill` and `type_int`, are taken only to be refused by name.
- `function` is in the profile, but every Function-storage variable is refused (compile.zig:770-772). Mesa keeps such variables in registers and sends only dynamically indexed arrays to TMU scratch.
- "No register spilling" is not the hardware's limit. Mesa spills on the same QPU: it retries at 2 threads first, then spills through the TMU into a per-thread scratch buffer (vir_register_allocate.c:437-683, 761-1018).
- Mesa's register classes give a 4-way-threaded program 32 registers (PHYS_COUNT 64 shifted by the thread index, vir_register_allocate.c:1219-1224). The 16 that facet keeps to has no Mesa source.

On 7.1 the SFU ops are entries of the add table (qpu_pack.c:658-663) and come with it. A branch has three delay slots and a uniform-stream offset of its own, and divergent control flow needs the execute mask and predicated writes. So compile.zig's one linear word stream becomes one stream per block.

The list above leaves out four things: the VIR layer itself, liveness, the validator, and the uniform stream growing into Mesa's `quniform_contents`. Storage buffers are covered by no item. The citations have drifted: the profile is compile.zig:196-230, the error set 126-184, and the single sampler field driver.zig:523-526.

### 60. Compile SPIR-V vertex and compute stages for the V3D **[critical path]**

*V3D compiler* &mdash; conformance-blocking, large, also serves the shim

After: Item 59

The back end is fragment-only and refuses any other stage by name; the vertex and coordinate programs are still generated by the hand-written passThrough/vertexProgram for the varyings a draw carries. Every CTS graphics test supplies a vertex shader, so even a V3D-only run stops here. Needs the Program/Plan/encode pipeline extended to the vertex stage's quite different shape: VPM reads and writes, the coordinate program, and the binner's varying order that _vertices.zig also fixes.

> Verified: compile.zig:2 "a SPIR-V **fragment** module turned into V3D 7.1 instructions"; compile.zig:527 `if (seen.stage != .fragment) return Error.Stage;`; the profile's `.stages = &.{.fragment}`.

### 61. Multisampling: 4 samples a pixel on both devices, with resolve attachments and CmdResolveImage's body **[critical path]**

*rasterisation* &mdash; conformance-blocking, port, **sized 07.11.2026: 21 commits, about 1,590 lines of code, 1,340 of tests and 90 of docs**

The largest item Goal A cannot skip, and the only one Vulkan 1.0 gives no way to refuse — not through a feature bit, since sampleRateShading, alphaToOne and variableMultisampleRate are all optional, but through the required limits: framebufferColorSampleCounts, framebufferDepthSampleCounts, framebufferStencilSampleCounts, sampledImageColorSampleCounts, sampledImageDepthSampleCounts and sampledImageStencilSampleCounts must each include VK_SAMPLE_COUNT_4_BIT; framebufferNoAttachmentsSampleCounts must include VK_SAMPLE_COUNT_4_BIT too - *not* the 1 bit alone, as this said until 1.89, which is a seventh field wanting 4x and not a sixth; sampledImageIntegerSampleCounts and storageImageSampleCounts must include 1, the latter only while shaderStorageImageMultisample is false, and both are met; `framebufferIntegerColorSampleCounts`, also named here until 1.89, is not a Vulkan 1.0 limit at all and is not among the 106; and maxSampleMaskWords must be at least 1, which is **done in 1.89** - see below. facet published none of those ten fields until 1.82 and now publishes all of them, at their one-sample values - which is exactly why eight of the eighteen limit shortfalls counted by tests/vulkan_limits.zig are this item - and no device has the capability: rasterization_samples above 1, sample shading, alpha-to-coverage and alpha-to-one are refused in CreateGraphicsPipelines; an attachment with samples != 1 and any resolve_attachments are refused in CreateRenderPass; and CreateImage refuses samples != 1 in the same line that refuses 1D images, so a multisampled image cannot be made at all. On the cores: per-sample colour, depth and stencil in the tile store, a sample loop in every load, store, clear and resolve path, the quad walk writing four pixels under one coverage mask, the sample mask, and alpha-to-coverage in the blend path — the to-do document works the budget through, and its arithmetic needs one correction: a 64x64 tile is about 114 KiB live *across* four parts, but `Host.share` gives each part its own core and so its own L1, so the figure to hold against the A76's 64 KiB L1 data cache is the per-core 28.5 KiB now and 112.5 KiB at 4x. Still past it, so the conclusion stands - but it is past it by 1.8x and not 7x, and that matters because the doc's framing points at halving `tile_size`, which pays for 4x exactly and taxes every single-sampled frame, where the per-part run-time block `lay()` already builds for extra colour attachments and would carry sample planes at no cost to a 1x frame. On the V3D the hardware has 4x coverage and the driver writes one sample's worth in all four bits today, so that side is frame setup, the tile store and resolve rather than new silicon.

> Verified verbatim: creategraphicspipelines.zig:378 `if (multisample.rasterization_samples > 1 or multisample.sample_shading_enable or multisample.alpha_to_coverage_enable or multisample.alpha_to_one_enable) return .error_feature_not_present;`; createrenderpass.zig:216 and :255/:307/:378; image/_image.zig:338 `... or info.samples != 1) return null;`; multisampling verified absent from both driver tables so false by default; facet.zig:317 `multisampling: bool = false,` ("No device of this library has it.") and :572-573 `sample_counts: u32 = 0,`; one-sample coverage at driver/v3d/cl.zig:336-341. docs/facet-todo.md section 2 states the conformance point correctly and is not stale.

**The first of its eight rows is done in 1.89, and it needed no new
sample.** `maxSampleMaskWords` was 0 against Vulkan's required 1, and
`PipelineMultisampleStateCreateInfo.sample_mask` was a field nothing read.
At one sample a pixel the mask is bit 0 alone - Vulkan reads
ceil(rasterizationSamples / 32) words and ignores the bits above the sample
count - so honouring it is complete, not a stepping stone: a pipeline whose
mask clears bit 0 covers no sample and draws nothing, and one that sets it
draws as before. A null pointer is every sample covered, which Vulkan says
in as many words.

Where the suppression goes is the whole of the care this needed. The mask
is applied *after* rasterisation, so such a draw is not `draws_nothing`:
the primitive was assembled, the vertex stage ran, and it reached primitive
clipping and came out of it, so `INPUT_ASSEMBLY_VERTICES`,
`INPUT_ASSEMBLY_PRIMITIVES`, `VERTEX_SHADER_INVOCATIONS`,
`CLIPPING_INVOCATIONS` and `CLIPPING_PRIMITIVES` are all owed and only
`FRAGMENT_SHADER_INVOCATIONS` goes to zero. On the cores the triangle is
projected, culled and counted and *then* dropped, in
`raster/batched.zig`'s `SetUp.one` - one test a triangle, nothing per
pixel, nothing allocated. On the V3D the draw simply returns, and that is
exact rather than a shortcut because that device reports
`pipeline_statistics_queries = false`: there is no counter there for a
masked-off draw to owe.

The test asks for the same triangle under six mask words and reads all six
counters each time. `0x0000_0002` and `0xFFFF_FFFE` draw nothing, which is
what proves the bits above bit 0 are ignored rather than ORed in; `null`,
`0x1` and `0xFFFF_FFFF` draw. Three ways of getting it wrong each make it
fail: not reading the mask gives `expected 0, found 2016`; setting
`draws_nothing` instead trips the assertion that it is not set; and doing
that with the assertion removed gives `expected 1, found 0` on the clipping
counter - which is the reason the flag is not reused, caught by the test
rather than by review.

The row count moved the other way too, by one that was already wrong:
`_instance.zig` said "Vulkan requires the 4 bit on six of them, so this is
six shortfalls", where seven of the masks fall short. The pin in
tests/vulkan_limits.zig is 10 now, of which seven are this item.

**Sized from Mesa, 07.11.2026.** Both Mesa drivers multisample, and facet takes the set they share:

- v3dv reports 1|4 on this same V3D 7.1: in all seven rows Vulkan asks for, in the integer row as well, and 1 for storage (`supported_sample_counts`, v3dv_device.c:1024-1027 and 1179-1189). Its standardSampleLocations is false (:1202), and so is variableMultisampleRate (:392).
- lavapipe reports 1|4|8, with the standard locations (`LVP_SAMPLE_COUNTS`, lvp_device.c:81-82; :1094). llvmpipe's 4x positions (`lp_sample_pos_4x`, lp_rast.c:63-66) are Vulkan's standard set.

facet reports 1|4 on both devices, with the standard locations on the cores and not on the V3D. These stay off or refused:

- sampleRateShading, alphaToOne and variableMultisampleRate, which are optional;
- 4x storage images and 4x input attachments;
- 2, 8 and 16 samples.

`can.multisampling` comes to mean four samples a pixel, with no new field. It turns on in K7 for the cores and in V5 for the V3D, and the masks and the format query follow it, so no sample-count bit is reported before the code that draws it. The first five commits are shared, host-tested, and change nothing a shipped device reports. After them the cores and the V3D proceed independently.

| Step | What | Ported from | Code | Tests |
|---|---|---|---|---|
| S1 | **Done in 1.96.** The three optional features decoupled. The seven masks become 1\|4, narrowed to 1 while a device lacks the capability, and no-attachments to 1 until item 43 | v3dv_device.c:1179-1189, :392 | 35 | 35 |
| S2 | A 4x image in sample-major planes, and the format query's 4 bit following CreateImage | lp_texture.c:225-226; lvp_formats.c:362-367 | 70 | 45 |
| S3 | Copies and clears of every sample | lp_texture.c:225-226 | 25 | 30 |
| S4 | Render passes, framebuffers and pipelines take 4 samples and resolve attachments | Vulkan's subpass rules, as v3dv asserts them (v3dv_pipeline.c:1319-1320) | 85 | 50 |
| S5 | CmdResolveImage (item 13), with a CPU body | `resolve_color`, lvp_execute.c:1782-1828; vk_meta_blit_resolve.c:151, :192 | 187 | 65 |
| K1 | Per-sample coverage in setup, binning and the walk | `lp_sample_pos_4x`; lp_setup.c:127-128, :631-632; lp_setup_tri.c:314-324; `do_block_4`, lp_rast_tri_tmp.h:42-80 | 148 | 267 |
| K2 | Sample planes in the tile. Shading once a pixel; per-sample colour writes and occlusion | lp_state_fs.c:822-823, 860-870, 1017-1021, 3651-3672 | 217 | 195 |
| K3 | Per-sample depth and stencil | lp_state_fs.c:926-960, 3437-3439 | 93 | 100 |
| K4 | Alpha to coverage, with lavapipe's dither | lp_state_fs.c:408-474, 1182-1214; lp_bld_blend.c:342-365 | 34 | 40 |
| K5 | Resolve attachments, in the tile before its store | lvp_execute.c:1802-1837; v3dvx_cmd_buffer.c:640-686 | 113 | 125 |
| K6 | Multisampled fetch from a native fragment function | lp_jit.c:399-404; lp_texture.c:1087; lvp_image.c:70-74 | 35 | 45 |
| K7 | 4x turned on for the cores, closing six rows | | 10 | 40 |
| K8 | No-attachment subpasses at 4x, after item 43 | v3dv_cmd_buffer.c:2655-2675 | 15 | 20 |
| V1 | The packet fields: COMMON's MSAA bit and log2 tile size, decimate on loads and stores, oversample, and SAMPLE_STATE's mask | v3d_packet.xml | 23 | 50 |
| V2 | The tile-size chooser, and SAMPLE_STATE per draw at 4x | `v3d_choose_tile_size`, v3d_util.c:105-206; v3dv_cmd_buffer.c:367-413 | 65 | 45 |
| V3 | The 4x layout, 2W x 2H and always UIF, as a fourth image kind | v3dv_image.c:136-140, 180-183; v3d_nir_lower_txf_ms.c:46-51 | 75 | 35 |
| V4 | Binning and rendering a 4x frame, with GFXH-1918 | v3dvx_cmd_buffer.c:206-209, 408-413, 973-984, 1604-1618, 1874-1881 | 76 | 45 |
| V5 | Resolve in the TLB, with S5 as the fallback; 4x turned on for the V3D, closing three rows | v3dvx_cmd_buffer.c:640-686; v3dv_pass.c:138-142, 663-683; `resolve_image_tlb`, v3dv_meta_copy.c:5109 | 110 | 40 |
| V6 | Alpha to coverage on the QPU | nir_to_vir.c:2056-2100; v3dvx_pipeline.c:453, 459 | 110 | 35 |
| V7 | Multisampled fetch through the TMU, after item 59 | v3d_nir_lower_txf_ms.c:46-51 | 45 | 25 |
| V8 | No-attachment subpasses at 4x, after item 43 | `cmd_buffer_restart_job_for_msaa_if_needed`, v3dv_cmd_buffer.c:2676 | 20 | 10 |

Docs add about 75 lines in K7 and 15 in V5. The V3D's sampled depth and stencil rows wait on item 58 and are not among these commits.

Three things this item said are corrected:

- **The tile is not halved.** At 4x a part's tile would hold 112.5 KiB against the A76's 64 KiB of L1, as worked out above, and halving `tile_size` would tax every 1x frame. The three extra sample planes go instead in the per-part run-time block that `lay()` already builds for extra colour attachments, so a 1x frame is unchanged. Whether a 4x frame should halve its own tile, as `v3d_choose_tile_size` does on the V3D, is a measurement for after K7.
- **A pass with a resolve marks every tile dirty.** `finish` draws only dirty tiles, and `begin` marks them dirty only when something is cleared. Without this, a tile loaded with LOAD_OP_LOAD and drawn into by nothing would never be resolved.
- **The pin is 7, and all seven are this item's.** It said 10 at 1.89; item 17's half (1.90) and item 22's half (1.91) have closed since. K7 takes it to 1, and K8 to 0. The verified line above cites creategraphicspipelines.zig:378 and _image.zig:338, which at 1.95 are :414 and :352.

Found independently by: features, limits, semantics, entry-points, conformance-path (all 5 strands that looked at it).

### 62. The optional capabilities facet refuses cleanly: logic ops, several viewports, dual-source blend

*pipeline state / blending* &mdash; feature-gap, large

After: Integer types in the compiler's profile for the V3D half of logicOp

Three optional Vulkan 1.0 features refused with error_feature_not_present, so all three are legal absences and pure capability work. logicOp: logic_op_enable is refused for every attachment on every device though LogicOp is fully enumerated — on the cores a second write path in the tile blender (16 bitwise operations over the tile's 8888 words, bypassing the blend fast path), on the V3D lowering into the fragment program, which is now possible in principle since there is a compiler but needs integer types in its profile. multiViewport: viewport_count != 1 or scissor_count != 1 is refused; needs a per-primitive viewport index the SDK's vertex stage has no slot for and a tile walk comparing against several rectangles, and one viewport is also what keeps the scissor and depth bounds a single state. dualSrcBlend: BlendFactor stops at src_alpha_saturate = 14 and any factor above is refused; needs a fragment function writing two colours for one attachment and a blender reading the second, which is close to the several_outputs plumbing.

> Verified: creategraphicspipelines.zig:412 `if (blend.logic_op_enable) return .error_feature_not_present;` (unconditional, not behind the feature), :471 the viewport/scissor refusal, :428 the factor refusal; logic_ops and several_viewports verified absent from both driver tables; BlendFactor ends at src_alpha_saturate = 14. docs/facet-todo.md section 2's logicOp row ("the QPUs run no program of ours") is now stale.

Found independently by: features (3 items), semantics (3 items) — 6 findings merged.

### 63. Six capabilities measured against Mesa: geometry shaders, ASTC, sparse, robustBufferAccess, V3D pipeline statistics, V3D cube arrays

*missing capabilities* &mdash; feature-gap, about 3,460 estimated facet lines:

- geometry on the cores, about 710;
- ASTC, about 1,410, behind items 32 and 34;
- V3D cube arrays, about 45, plus about 30 with item 59;
- with item 60, QPU geometry, about 780, and V3D robust access, about 80;
- sparse, about 400, behind item 12 and an exec call that maps pages;
- V3D pipeline statistics, 0, which Mesa does not have.

All optional in Vulkan 1.0, all absent, each a clean capability to add rather than a conformance bug — recorded so they are not mistaken for debt. geometryShader: no SHADER_STAGE_GEOMETRY bit at all; needs the stage, an entry kind, and a primitive stream the binner takes from somewhere other than the vertex array. textureCompressionASTC_LDR: no format and no decoder anywhere in the tree. sparseBinding and the residency bits: memory is exec's and bound whole. robustBufferAccess: nothing in the tree, and with it absent out-of-bounds access is undefined, which Vulkan permits. pipelineStatisticsQuery on the V3D: nothing counts what its QPUs were given, so the kind is refused there; needs the binner's and renderer's perfmon counters read as the frame is drawn, the way the occlusion counter already is — not compiler work, which the to-do document's unlock table miscredits. imageCubeArray on the V3D: no QPU program reads the fourth coordinate, so a cube_array view and texture_cube_array are refused; needs Dim::Cube and arrayed images in the profile.

> Verified: BlendFactor and the stage bits as above; `grep -i astc` across sdk/ and src/disk/libs/facet/ hits only prose at facet_version.zig:1075; `grep -i robust` across both trees returns nothing; driver/v3d/driver.zig:166 `.pipeline_statistics_queries = false` (occlusion is true on both, driver.zig:165 and cpu.zig:128), :192 `.cube_arrays = false`; refusals at createquerypool.zig:83-84 and driver.zig:460.

Found independently by: features (3 items), semantics (2 items).

**Sized from Mesa, 07.11.2026, and four statements above are wrong.**

- **Every capability already has its field**, and only sparse lacks its calls (item 12). The fields are `robust_buffer_access`, `geometry_shader`, `texture_compression_astc_ldr` and the sparse features. `SHADER_STAGE_GEOMETRY` has had a name since 1.80. What is missing is the stage itself, which CreateGraphicsPipelines refuses (creategraphicspipelines.zig:261).
- **robustBufferAccess is the one feature Vulkan 1.0 requires, not an optional one.** facet reports it true on every device (getphysicaldevicefeatures.zig:133, tests/facet.zig:188), as v3dv and lavapipe do (v3dv_device.c:329, lvp_device.c:444). On the cores every access is bounded by its descriptor's range. On the V3D it waits for buffer access (items 59 and 60), where v3dv's lowering, keyed on the enabled feature, is about 80 lines (vir.c:2025-2038).
- **V3D pipeline statistics are not a port.** v3dv reports the feature false (v3dv_device.c:358), and its CreateQueryPool takes occlusion, timestamp and performance queries only (v3dv_query.c:258-260). The 7.1 perfmon has no counter for any of the statistics (v3d_performance_counters.h:35-131). Neither the compiler nor the perfmon unlocks them, and they stay refused.
- **ASTC needs a decoder on one device only.** The V3D's TMU samples it natively: the port is v3dv's format table (v3dvx_formats.c:233-261) and the 8- and 16-byte microtile rows. lavapipe decodes on every write into a second RGBA8 plane, because llvmpipe samples no ASTC (lvp_image.c:276-287, lp_screen.c:729-733). That decoder's ~1,000 lines are the largest term, and it was not counted.

Two capabilities are smaller than they looked:

- **Sparse.** v3dv has none (v3dv_device.c:383). lavapipe's is Linux-only: it maps memfd pages into a reserved range with mmap(MAP_FIXED) (lp_texture.c:325-395). Porting it needs an exec call that maps pages at a fixed address, and exec has none.
- **Cube arrays on the V3D** are native in the TMU: TMUI carries the layer and TMUSCM retires the sample (v3d_tex.c:121-128, 377-379).

These figures are estimates, not counts. Items 12, 32, 34, 59 and 60 are prerequisites and are not included.

### 64. The synchronisation capabilities nothing owes today: barrier arrays, subpass dependencies, more than one queue

*synchronisation* &mdash; feature-gap, medium

Grouped because the finding is that nothing is owed, and why — which is worth writing down rather than changing. facet over-synchronises everywhere, so no conformant program can observe the discarded barriers: the queue runs one command buffer to completion before the next, each command finished before the next starts, and the V3D driver flushes every chunk and the target image to the GPU before a job, invalidates after, and invalidates the L2T and slice caches before every bin and every render. Subpass dependencies are read for exactly one question — does this subpass depend on itself by region, which lets a fragment read the tile it is drawing into — and subpasses always run in index order. One queue family of one queue satisfies Vulkan 1.0, which requires only one family supporting graphics and compute. The moment any of that changes — several queues, async compute, the binner overlapping the previous render — the barrier becomes load-bearing and the arrays have to be there to read, which is a struct change plus a per-barrier payload since _command.record already takes a variable-length one. Note the two gap documents use "only one queue" as the reason events are absent, which it is not.

> Verified: cmdpipelinebarrier.zig:67-78 discards all three arrays; queue/_queue.zig:245-254 waits for each command buffer's done before the next; driver/v3d/_play.zig:680-708 rangeToGpu over every chunk and the image before the job and rangeFromGpu after; driver/v3d/engine.zig:108-137 invalidateCaches() before every bin and render; createrenderpass.zig:421-434 `fn byRegion` is the only reader of info.dependencies, and :165-169 says so; getphysicaldevicequeuefamilyproperties.zig:57-66 always answers count 1; createdevice.zig:67-70 refuses more than one queue.

### 76. Give the limits table a required-minimum column, and write the formats section neither document has

*documentation* &mdash; structural, small

After: Items 16-40 settling the real numbers

The last doc item, and it is the one that keeps this list honest after the first pass. The limits table is accurate at 1.79 — every number in it still matches the tree — but it has no required-minimum column and the phrase never appears in the file, so nothing in the repository records that nine limits sit below the spec's floor or that ~81 required limits have no field. Add the column and the rows it omits: the per-stage descriptor counts and their per-device split, the dynamic-buffer count, min_memory_map_alignment, the compute group limits and the 2^20 draw cap. Then add a formats section: the thirteen mandatory feature bits with facet's count against each, per device. The to-do document defines a `1.0 format` standing as "a format-feature question, which GetPhysicalDeviceFormatProperties answers", which is exactly the misconception — for the 56 formats in the mandatory tables there is nothing to answer, the bits must be set — and then uses that standing for no item while declaring its format section empty.

> Verified: `grep -n 'minimum|conforman|required limit|Vulkan requires' docs/facet-gaps.md` returns nothing; `grep -n '1.0 format' docs/facet-todo.md` returns only its definition at :19; docs/facet-todo.md:30-36 "**Nothing is left here.**". Spot-checked the limits table against the tree and it holds: _instance.zig:36-59, _render.zig:34-36, memory/_memory.zig:12.

Found independently by: limits, formats (2 strands).

### 77. Make makeVersion Vulkan's version encoding, so VK_API_VERSION_1_0 is not refused

*versions* &mdash; conformance-blocking, small, also serves the shim

**Done in 1.82, and the comparison was the larger of the two faults.**
`makeApiVersion(variant, major, minor, patch)` and `makeVersion(major,
minor, patch)` pack a version Vulkan's way, with `apiVersionVariant`,
`apiVersionMajor`, `apiVersionMinor` and `apiVersionPatch` to take one
apart. CreateInstance now compares the interface's major and minor version
against the `API_VERSION_1_0` the library has, leaves the patch out of it as
Vulkan asks, and refuses a variant that is not Vulkan's 0. The old
comparison answered a function of the library's revision rather than of the
interface asked for: every Vulkan-shaped number, 1.0 among them, sat above
the ceiling, so all were refused together and raising the revision moved
the ceiling without ever reaching one of them.

Found while doing item 4, and it is the first call a ported program makes.
`facet.makeVersion(major, minor)` is `major << 16 | minor`. Vulkan's
`VK_MAKE_API_VERSION(variant, major, minor, patch)` is
`variant << 29 | major << 22 | minor << 12 | patch`, so Vulkan's own
`VK_API_VERSION_1_0` is 4194304 where facet's `API_VERSION_1_0` is 65536.
`CreateInstance` refuses anything above
`makeVersion(LIBRARY_VERSION, LIBRARY_REVISION)` — 65616 at 1.80 — so a
program that fills `InstanceCreateInfo.api_version` with Vulkan's constant
is turned away with `error_incompatible_driver` at the door. facet's
default hides it: `api_version` defaults to facet's own value, so only a
program that says what Vulkan told it to say is hurt.

This is not a regression from item 4, which only changed the code the
refusal answers with (`error_initialization_failed` before 1.80); the
refusal itself is as old as the comparison. It is a divergence the
decision at the top of this document turns into work.

The change is `major << 22 | minor << 12`, which keeps the ordering the
comparison relies on and leaves 10 bits for a revision (80 fits, and 1023
is the ceiling). It moves every `api_version` number a program may pass,
so it wants the three `makeVersion` callers, `API_VERSION_1_0` and the
`InstanceCreateInfo` default read together — and a patch field decided,
since Vulkan has one and facet's revision is not it.

> sdk/libs/facet/facet.zig:168 `pub fn makeVersion(major: u32, minor: u32) u32 { return major << 16 | minor; }`, :173 `API_VERSION_1_0: u32 = makeVersion(1, 0)`, :186 the default; src/disk/libs/facet/instance/createinstance.zig:77 the refusal. Measured, not inferred: `makeVersion(1, 80)` = 65616 < 4194304.

### 78. Admit the declaration and annotation opcodes, because every real toolchain's module was refused

*SPIR-V front end* &mdash; conformance-blocking, small, critical path

**Done in 1.81.** Not on this list when it was written, and the most
consequential thing found while working through it: no module any real
toolchain produces could be loaded at all.

`OpExtInstImport`, `OpSource`, `OpSourceExtension`, `OpName` and
`OpMemberName` carry no computation - an extended instruction set declared,
and the names and source strings glslang puts around the instructions - and
not one of them was in either opcode list, the library's `facet_profile` or
the V3D's `profile`. The simplest fragment shader glslc can be given,
`ocolor = vcolor;`, imports GLSL.std.450 at its **sixth word**, so every
glslc module was refused there and nothing behind that wall had ever been
reached. `tests/spirv_reference.zig`'s own header had recorded for a long
time that glslc emits exactly these and that they were stripped to make the
minimal hand-written forms - the fact was written down, and the conclusion
that the profile therefore rejected real output was never drawn.

Measured before and after, with glslc on this PC: a trivial fragment shader
is 111 words at `-O0` and at the default, 78 at `-O`, and all three are
`spirv-val --target-env vulkan1.0` clean. Before 1.81 all three were refused;
after it, none of the opcodes any of them uses is outside the V3D's profile.

`ext_inst` - the *use* of an imported set, as against its declaration - is
deliberately still absent, so a module that calls one of GLSL.std.450's
functions is refused for the call and not for the import, which is the
honest answer and the two-tier rule working as intended.

What it buys immediately is evidence, not just reach: glslc's own module for
the interpolated colour now compiles to `qpu.color_fragment`, the program
written by hand and drawn on the board, **word for word**, with an identical
plan. It is kept as `driver/v3d/glslc_reference.zig` - a file of the V3D
module's own, because a Zig module cannot import above its root and
`compile.zig`'s tests are the V3D's - and `scripts/spirv-check.sh` now scans
both reference files, so Khronos' validator vouches for it with the other
seven.

> Measured: `glslc -fshader-stage=frag` on a `#version 450` shader with one
> `vec4` in and one out; opcodes diffed against both profiles. The gate is
> `sdk/libs/facet/spirv.zig`'s `facet_opcodes` and
> `src/disk/libs/facet/driver/v3d/compile.zig`'s `profile.opcodes`; the body
> arm that would have answered `Error.Body` for a header instruction is the
> reason they needed naming in the walk as well as in the list.

### 79. CreateBufferView asks a texel buffer's offset for something no Vulkan limit can say

*buffers / limits* &mdash; conformance-blocking, small

Found while filling `minTexelBufferOffsetAlignment` for item 16. Vulkan asks
only that `VkBufferViewCreateInfo::offset` be a multiple of
`minTexelBufferOffsetAlignment`, which the spec requires to be a power of
two. facet asks that it be a multiple of **the format's own texel size**,
and three of the formats a view takes are 12 bytes - `rgb32f`, `rgb32u` and
`rgb32i`. Twelve is not a power of two, so no value of the limit describes
the rule: facet reports 16, and a program that dutifully aligns its offset
to 16 is still refused for a 12-byte format, because 16 is not a multiple of
12.

The number is not the defect; the check is. Either the check uses the limit
it publishes, or the limit stops being publishable - and the first is right,
since nothing about reading three floats from a buffer needs the offset to
be a multiple of twelve.

> `src/disk/libs/facet/buffer/createbufferview.zig` - the refusal is
> `info.offset % size != 0` where `size` is the format's texel bytes, not
> the limit. `sdk/libs/facet/shader.zig` gives `rgb32f` 12 bytes, and
> `rgb32u`/`rgb32i` the same. The limit is `_buffer.alignment`, 16.

### 80. A Vulkan subpass with several colour attachments is drawn in several parts, so one fragment function may write one colour

*render passes / fragment outputs* &mdash; conformance-blocking, large

Found while filling `maxFragmentOutputAttachments` for item 16, and it is
the cores' half of item 55.

CreateRenderPass gives each colour attachment a part of its own unless the
subpass carries facet's own `SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER`, and
CreateGraphicsPipelines then refuses a fragment function whose output count
is not that part's - which is one. A program using Vulkan's own surface has
no such flag, so a conformant subpass with four colour attachments and a
fragment shader writing four is refused with `error_invalid_shader_nv`,
although `maxColorAttachments` says four and `maxFragmentOutputAttachments`
says four on the cores.

The limits are not where to fix it. Reporting 1 would leave
`maxColorAttachments` saying 4 and would make the two devices
indistinguishable to the probe; the defect is that the flag exists at all,
a Vulkan subpass with several colour attachments meaning what the flag
means. Fold into item 51's decision about facet's own fields and flags.

**Found in 1.91, by reading and not yet by a test:** inside a part that
draws its subpass's colours together, CmdClearAttachments clears the first
colour and no other. `_draw.clearAttachment` draws its quad with
`State.color_count` at its default of 1 and writes the colour only where
`command.output == player.resources.output`, which is 0 for that one part,
so a clear of colour attachment 1 writes nothing anywhere; 1.91's layered
clear (`clearRectangle`) keeps to the same rule rather than differ from the
tiles. Without the flag every colour has a part of its own and the clear is
right. lavapipe clears whichever attachment `colorAttachment` names
(`handle_clear_attachments`), which is what removing the flag gives.

> `src/disk/libs/facet/render/createrenderpass.zig` splits a subpass into
> parts; `src/disk/libs/facet/pipeline/creategraphicspipelines.zig` refuses
> on `outputs != pass.parts[subpass.first_part].color_count` and gates
> `outputs > 1` on `can.several_outputs`.
> `sdk/libs/facet/facet.zig`'s `SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER` is bit
> 31, where Vulkan reserves the high flag bits.

### 81. error_feature_not_present is returned from calls Vulkan does not list it for

*result codes* &mdash; conformance-blocking, medium, also serves the shim

Found while measuring item 49 against the specification. Vulkan lists
`VK_ERROR_FEATURE_NOT_PRESENT` for `vkCreateDevice` alone: "If any requested
feature is not supported, vkCreateDevice must return
VK_ERROR_FEATURE_NOT_PRESENT." facet answers it from a dozen other calls -
CreateGraphicsPipelines, CreateComputePipelines, CreateRenderPass,
CreateDescriptorSetLayout, CreateBufferView, CreateSampler,
CreateQueryPool - where Vulkan's lists do not have it, which is the same
shape of fault item 4 fixed for `error_format_not_supported`.

It is not a small fix, because there is nothing obviously better to answer.
Vulkan's model is that a program enables what it means to use and the
implementation's behaviour is undefined if it uses more; facet refuses at
the call instead, which is a *permitted* way to implement undefined
behaviour and a far more useful one, but the code it refuses with is not a
code Vulkan allows there. The honest options are a code Vulkan does list
for those calls, or accepting the divergence and writing it down - and this
item is the writing down.

Item 49's own work went in at 1.82: `DeviceCreateInfo.enabled_features`
exists, is compared member by member against what the device has, and
answers `error_feature_not_present` - which is the one place Vulkan does
list it.

> `grep -rn 'error_feature_not_present' src/disk/libs/facet/` - the calls
> above. `src/disk/libs/facet/device/createdevice.zig` is the conformant
> one, since 1.82.

**Re-scoped 07.11.2026, from the specification as it stands now.** The
premise above, that no code Vulkan lists fits, no longer holds:

- vk.xml has `VK_ERROR_VALIDATION_FAILED` "Retroactively promoted from
  VK_EXT_debug_report for compatibility with VulkanSC" into Vulkan 1.0's
  own feature block.
- Every call named above lists it among its error codes.
- fundamentals.adoc says: "Any command returning a VkResult may return
  VK_ERROR_VALIDATION_FAILED if a violation of valid usage is detected."
- Its value is the extension's, -1000011001, which a program built
  against 1.0 headers knows as `VK_ERROR_VALIDATION_FAILED_EXT`.

So the item becomes a classification rather than a write-up, because the
refusals split two ways:

- **Invalid usage detected.** A feature the device lacks or the program
  did not enable, a limit exceeded, a bit or an enum value that is none of
  Vulkan's. These answer `error_validation_failed`, which `facet.Result`
  does not have yet.
- **Valid usage facet cannot do.** For example a subpass with no colour
  attachment (item 43), and the other conformance-blocking refusals.
  Nothing there is invalid, so no code is honest. Each is its own item,
  and each keeps `error_feature_not_present` until its item removes the
  refusal.

The size, counted: 72 code sites in 14 library files return
`error_feature_not_present` outside `CreateDevice`, with 23 in
CreateRenderPass, 16 in CreateGraphicsPipelines, 8 in
CreateDescriptorSetLayout and 7 in CreateSampler. There are 42 test lines
beside them. Each site needs its VUID read before it moves, and that
reading is the work. The code change is one enum member and one return
value per site.

### 82. CreateShaderModule panicked on an under-aligned `code` instead of refusing it

*entry points / shaders* &mdash; **done in 1.87**, small, found while doing item 28

Found by a test crash in 1.87, from an unrelated change that moved a SPIR-V
word array four bytes. `CreateShaderModule` did
`@ptrCast(@alignCast(info.code))` to a `*const shader.Code` before reading
`magic`, and `@alignCast` is a *panic* in a safe build when the pointer
does not already carry the alignment. `info.code` is a `*const anyopaque`
and `@alignOf(shader.Code)` is 8, so the call that exists to *refuse*
memory that is not a `shader.Code` aborted inside the library for the one
kind of garbage that is 4-aligned - which a word array often is. The test
at tests/draw.zig:649, whose whole point is that a bare `[N]u32` is turned
away, had been passing only because its array happened to land on 8.

1.87 checks `@intFromPtr(info.code) % @alignOf(shader.Code)` and answers
`error_invalid_shader_nv`, the code this call already uses for memory it
cannot read as a module. That closes it: eight bytes is what facet's own
API asks of this pointer, because what it points at is a struct holding a
pointer, not a word array.

Worth writing down because it *looks* like a conformance hole and is not.
Vulkan's `pCode` is `const uint32_t*` and promises 4 bytes - but `pCode` is
never this pointer. facet's `code` is a `shader.Code`, and under
`SHADER_MODULE_CREATE_SPIRV` a `shader.Module`, with the words reached
through `Spirv.words` behind it; a shim would build that struct from
`pCode` in storage of its own, correctly aligned by construction, and the
words themselves are only ever read as `[]const u32`. The structure
question this belongs to is item 51's.

> Verified by the crash: `src/disk/libs/facet/shader/createshadermodule.zig`
> before 1.87; `sdk/libs/facet/shader.zig:123` `Code` holds
> `entries: [*]const Entry`, so its alignment is a pointer's.

### 83. The pipeline-statistics counters a draw owes, which two of them did not pay

*queries / pipeline statistics* &mdash; **done in 1.88; its open question answered from Mesa, and four more counts fixed, in 1.92**, small, found while scoping item 61

Two defects in one block of `driver/cpu/_draw.zig`, both of them silent
because the only tests of these counters were of the *plumbing* - which
counter lands in which slot of a packed result, and that a counter
saturates - and never of a value a real draw produces.

**A draw that drew nothing counted nothing.** `draw()` returned at its
first line on `pipeline.draws_nothing`, which is set for
`rasterizer_discard_enable` and for a `cull_mode` of
`CULL_MODE_FRONT_AND_BACK`, and every `_query.add` in the function is
below that line. So `INPUT_ASSEMBLY_VERTICES`, `INPUT_ASSEMBLY_PRIMITIVES`
and `VERTEX_SHADER_INVOCATIONS` all read 0 for such a draw. Vulkan gives
exactly one licence to leave a counter alone here, and it is not that one:
*"If a pipeline has `rasterizerDiscardEnable` enabled, implementations
**may** discard primitives after the final pre-rasterization shader stage.
As a result, if `rasterizerDiscardEnable` is enabled, the clipping input
and output primitives counters **may** not be incremented."* The clipping
pair, and nothing else. Input assembly and the vertex stage are *before*
rasterisation and did their work, so what they processed is what they
processed. The bail is below the three counters now, which leaves the
clipping pair at zero - which that sentence allows.

The vertex function itself is still not run, and that is honest only
because `vertex_pipeline_stores_and_atomics` is false on both devices: a
vertex function writes its outputs and nothing else, and the outputs of a
draw that rasterises nothing cannot be read, so the count is the only
observable. The day a device claims that feature, this has to run the
stage for real - which is why the reason is written beside the bail and
not only here.

**`INPUT_ASSEMBLY_PRIMITIVES` divided by three whatever the topology.**
`_vertices.assemble` writes one corner for a point, two for a line and
three for a triangle, and the counter was `corner_count / 3`. So a point
list of twelve points counted four primitives, a line list of six lines
counted four, and a line strip of eleven segments counted seven. Only the
triangle topologies were ever right, and the one test that checked a value
drew a triangle list. `_vertices.cornersPerPrimitive` is the divisor now -
one, two, three, or a patch's control points - and it is held against
`mostCorners`, which is the same rule counted the other way round.

Both are caught by a new test that draws the same twelve vertices under
five topologies and under both draws-nothing pipelines and reads all six
counters. Putting either defect back makes it fail: `expected 12, found 4`
for the divisor, `expected 24, found 0` for the bail.

**One thing is left unsettled, and it is written down rather than
guessed.** `CLIPPING_PRIMITIVES` is wired to `target.stats.set_up`, which
counts triangles that survived *face culling and viewport setup*, where
Vulkan counts primitives output by the *clipping* stage - and culling
comes after clipping. Whether a back-face-culled triangle must be counted
turns on one clause: *"If at least one vertex of the input primitive lies
inside the clipping volume, and either the primitive is not rasterized
according to the Basic Polygon Rasterization rules, or at least one sample
point for a fragment lies within the rasterized triangle according to
those rules, the counter is incremented by one or more."* "Not rasterized
according to the Basic Polygon Rasterization rules" reads either as *is
not a polygon* - a point or a line, which those rules do not govern - or
as *was not rasterized at all*, which a culled triangle was not. The
queries chapter does not say which, has no note on culling, and names
these counters nowhere else. The second reading is the stronger literal
one, and the `rasterizerDiscardEnable` carve-out above is evidence for it:
under the first reading a discarded triangle is still a polygon with no
sample inside, so the "zero or more" branch would already cover it and the
carve-out would be unnecessary. That is an inference about why a sentence
exists, not a rule, so it is not enough to call facet's count a defect. If
the second reading is right, ordinary back-face culling undercounts this
one counter on the commonest draw there is, and that is worth settling
from `primsrast.html` (whether culling is inside the Basic Polygon
Rasterization rules) and `vertexpostproc.html` (the order of clipping and
culling) before anything is changed.

> Verified by the two reverts above, and by
> `grep -rn 'input_primitives\|input_vertices\|vertex_invocations' src/disk/libs/facet/tests/ src/disk/libs/facet/query/`
> before 1.88: every hit was in `query/_query.zig`'s own unit tests of the
> slot layout, plus the one triangle-list draw in `tests/draw.zig`.
> Normative text from the Vulkan Queries chapter, Pipeline Statistics
> Queries.

**Answered in 1.92, by Mesa rather than by a reading.** The question above
was the wrong place to start: lavapipe is a conformant Vulkan
implementation, and llvmpipe, which draws for it, had already decided.

- *A culled triangle is counted.* llvmpipe counts `c_primitives` at the top
  of `triangle_cw`, `triangle_ccw` and `triangle_both`
  (src/gallium/drivers/llvmpipe/lp_setup_tri.c, lines 1147-1149,
  1176-1178 and 1199-1201 at Mesa cbf692da), before `calc_fixed_position`
  gives the area's sign and before the face is culled on it. A triangle of
  no area and one covering no pixel's centre are counted the same way. A
  line is counted once at the top of `try_setup_line` (lp_setup_line.c:292)
  and a point once in its setup (lp_setup_point.c:449).
- *What goes into clipping is the primitives, before any cull.* gallium's
  draw module counts `c_invocations` in `draw_stats_clipper_primitives`
  (src/gallium/auxiliary/draw/draw_context.c:1223), decomposing the
  primitives the vertex, tessellation and geometry stages hand on by kind;
  lp_setup_vbuf.c:693 adds them in unless the rasterizer is discarded.
- *A cull of every face is no discard.* `lp_setup_choose_triangle` gives
  that cull `triangle_noop` (lp_setup_tri.c:1258), which counts nothing out;
  the draw module has counted the primitives in. So 1.88's sentence above,
  that the specification's licence "leaves the clipping pair at zero", was
  right for `rasterizer_discard_enable` and wrong for the cull: that
  licence names the discard alone.

facet counted four things differently, and counts them as llvmpipe does
now: a culled, an empty and a pixel-less triangle counted nothing out of
clipping; a line or a point counted two in and two out, being two
triangles to the rasterizer, and a triangle drawn as its edges six in; a
cull of every face counted nothing in; and a tessellated draw that drew
nothing ran neither tessellation function, so counted neither stage. A
fifth was not a counter: `CULL_MODE_FRONT_AND_BACK` drew no line and no
point, which have no face - Vulkan culls polygons, and `triangle_noop`
stands in for llvmpipe's triangle function alone.

Two differences are left, both inside the specification's "zero or more"
for a primitive with no sample inside: a triangle wholly outside the view
is rejected at the view's side here and at llvmpipe's guard band there
(lp_context.c:390 turns the draw module's on); and llvmpipe counts a culled
triangle when its setup culls it but not when the draw module's own cull
stage does (draw_pipe_validate.c:243, run for a draw that needs clipping),
where facet counts it either way.

> Verified by reverting each of the eight changes in turn: every one fails
> the extended test in tests/draw.zig - `expected 12, found 24` for a line
> counted twice, `expected 8, found 0` and `expected 24, found 0` for the
> cull counted as a discard, `expected 1, found 0` for a culled triangle,
> and the `draws_nothing` assertion for lines culled under
> `CULL_MODE_FRONT_AND_BACK`. The gallium files are not in this tree's
> sparse Mesa checkout and were read from Mesa cbf692da's own tree.

### 84. spirv.look's input_locations and output_locations are the same number

*shader words / SPIR-V reader* &mdash; **done in 1.95**, small, found while doing item 17

`Seen.input_locations` and `Seen.output_locations` are documented as "the
largest `Location` decorated on an input and on an output, and one more, so
that a back end knows how many varyings are in play" - two numbers. `look`
writes the same value to both: it takes the `Location` from an `OpDecorate`
and maxes it into each counter without telling an input variable from an
output one, which would mean correlating the decoration's target id with the
storage class of the `OpVariable` it names, in either order.

Harmless today and said to be: the file states that no caller reads either
field. It is a wrong answer nothing asks for. But item 17's V3D half is the
plausible first reader - a back end sizing its varying table would ask
exactly this - and the answer it would get for a sixteen-input,
one-output fragment module is sixteen for both.

`tests/ir.zig` asserts the two are *equal* rather than asserting what they
ought to be, with the reason written beside it, so the day a back end asks,
the test says what it will get rather than quietly agreeing with the doc
comment.

> Verified: sdk/libs/facet/spirv.zig, the `.decorate` arm -
> `seen.input_locations = @max(seen.input_locations, operands[2] +| 1);`
> followed by the same line for `output_locations`. The sixty-four-varying
> graph in tests/ir.zig reports 16 for both.

**Done in 1.95, by taking the two fields out rather than mending them.**
The plausible first reader named above already reads the locations
itself. The V3D's back end keeps a table of locations by id
(driver/v3d/compile.zig `Work.location`), fills it from each `OpDecorate`,
and reads it at the `OpVariable` it decorates, in the one pass SPIR-V's
logical layout allows. That is where Mesa has the answer too.
spirv_to_nir applies a `Location` in `var_decoration_cb`, with the
variable's mode beside it (src/compiler/spirv/vtn_variables.c:1705), and
`nir_shader_gather_info` then sets `inputs_read` and `outputs_written`
from the translated shader (nir_gather_info.c `set_io_mask`, lines 145
and 181). The IR here carries its own count too (`Entry.varyingCount`).
A pre-scan answer would be a second source of the same fact, and it was
the wrong one, so `Seen` no longer has it. All
`look` reads of a `Location` now is that its literal is present. A test
pins that: it had none. The tests/ir.zig assertion of equality became
one of the widest graph's sixteen inputs and one output.

## Deferred by the decision, not out of reach

A drop-in `libvulkan.so.1` was not chosen, so these are not scheduled.
They are kept here because the analysis found something worth knowing: the
shim itself is the *small* part. facet's structures are Vulkan's fields in
Vulkan's order with Vulkan's enum numbers, so each converter is a
field-by-field copy rather than a translation, and shipping a drop-in
`.so` rather than a Khronos ICD deletes the loader manifest and the four
`vk_icd*` exports entirely.

What stops it is not the shim. It is that **the cores have no runtime
SPIR-V path at all** - `shader.Entry.function` is a non-optional native
pointer, the graph is walked at comptime, and `vkCreateShaderModule` takes
SPIR-V and nothing else - and that **PowerOS cannot host `deqp-vk`**,
having no libc and no POSIX layer, so the CM5 and its V3D are foreclosed
and only a host build of the cores' driver could ever be tested.

### 51. Decide what to do about facet's own fields inside the Vulkan-shaped structures

*structures* &mdash; structural; decided 06.11.2026 as Vulkan's own structures, sized below

facet's create-infos are Vulkan's shape minus sType/pNext and plus fields of facet's own: PipelineColorBlendStateCreateInfo.attachment_constants (one set of blend constants per attachment where Vulkan has one), SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER in SubpassDescription.flags, IMAGE_CREATE_PACKED_TEXELS at bit 31, PIPELINE_CREATE_DEPTH_PREPASS, SHADER_MODULE_CREATE_SPIRV, CmdSetBlendConstantsAt occupying an LVO slot a Vulkan-ordered table would not have, and attachment_count = 0 meaning "the default over all of them" where Vulkan requires it to equal the subpass's colour count. None can be fixed by adding code: a Vulkan-source program's initialisers do not compile and a Vulkan binary's structs do not match. Deciding whether these become real extension structs behind pNext or are dropped is the shape question, and it is the one that decides whether anything above can be called conformance at all.

> Verified: PipelineColorBlendStateCreateInfo's members are flags, logic_op_enable, logic_op, attachment_count, attachments, blend_constants, attachment_constants with no sType/pNext; facet.zig:988 PACKED_TEXELS at bit 31, :1710 SHADER_MODULE_CREATE_SPIRV; createrenderpass.zig:282-284; creategraphicspipelines.zig:413. docs/facet-gaps.md:1-9 is honest that the library "is not Vulkan, and does not try to be".

**Decided 06.11.2026, sized 07.11.2026.** The decision was Vulkan's API surface with an Amiga binding: "identical structs, enums, names, semantics and result codes to Vulkan 1.0, still called through the LVO table". So the shape question has its answer. The sentence above, that none of this can be fixed by adding code, is wrong on both counts:

- **sType and pNext** go onto Vulkan 1.0's 47 structures that carry them; facet's SDK has neither member anywhere (`grep -c s_type sdk/libs/facet/facet.zig` is 0). Each gets two members with defaults, its own `StructureType` and null, so a Zig caller's initialiser keeps compiling and a C caller's structure matches. That is about 150 lines in sdk/libs/facet/facet.zig with the `StructureType` enum, and scripts/vulkan-struct-check.sh proves the layouts against the headers.
- **facet's own shapes come out:** `attachment_constants` with `CmdSetBlendConstantsAt`, `SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER`, `IMAGE_CREATE_PACKED_TEXELS`, `PIPELINE_CREATE_DEPTH_PREPASS`, and `attachment_count` = 0 as a default. Their SDK names appear in 15 library files outside the tests, on 11 test lines, and in one program, FacetProbe (`grep -rlE` over the five names, 07.11.2026). Removing OUTPUTS_TOGETHER makes what it means the meaning of every subpass, which is item 80. CmdClearAttachments then has to clear the attachment it names inside a part that draws several, as lavapipe's `handle_clear_attachments` does; that is the fault 1.91 found.
- **`SHADER_MODULE_CREATE_SPIRV` waits on item 71.** Until the cores have a SPIR-V back end, it is how a module says which kind of code it carries.

Found independently by: semantics, entry-points (as the sType/pNext item).

### 65. Ship the shim as a drop-in libvulkan.so.1, not a Khronos ICD

*shim / loader interface* &mdash; structural, small

A shared object exporting the vk* symbols directly, on LD_LIBRARY_PATH or beside deqp-vk, linking host_rom's exec plus facet.library plus the translation layer. This skips the whole ICD interface: no JSON manifest, no VK_DRIVER_FILES / VK_ICD_FILENAMES, no vk_icdNegotiateLoaderICDInterfaceVersion, no vk_icdGetInstanceProcAddr, no vk_icdGetPhysicalDeviceProcAddr. Decide it first, because the ICD route costs the loader work and buys nothing for a CTS run — and because the Khronos loader overwrites the first word of every dispatchable object, which facet's objects use for a live pointer. SwiftShader is the precedent and is a conformant implementation shipping its own libvulkan. The gap document's framing of the shim as larger than it is comes from assuming the ICD route.

> facet's dispatchable objects all carry a live pointer at offset 0: _objects.zig:27-34 "A handle is the object's address", with Instance.base, PhysicalDevice.instance, Device.base, Queue.device, CommandBuffer.device as first fields. Host plumbing already proven: scripts/vulkan-check.sh:51-61 builds a C program against vulkan.h and -lvulkan on this machine. docs/facet-ir.md:616 says the CTS is "out of reach without a `libvulkan`-shaped shim over facet on the host".

### 66. Wrap the five dispatchable handle types, and settle the handle width

*shim / handles* &mdash; structural, small

After: Item 65

Shim-owned wrappers for VkInstance, VkPhysicalDevice, VkDevice, VkQueue and VkCommandBuffer, each a plain C struct holding a pointer slot plus the facet handle, with a map back. facet cannot be passed through, because a handle is the object's own address and every dispatchable object keeps a live pointer at offset 0 — under the loader that word is clobbered and the object corrupted, and under a drop-in libvulkan the wrapper is still wanted to hold the FacetBase every LVO call takes as implicit arg 0. Non-dispatchable handles are a safe zero-extend on any 64-bit host, which is why this is the shim's problem and not facet's: every facet object is `opaque {}` passed as a real pointer, while Vulkan's non-dispatchable handles are uint64_t on every platform, wider than a pointer on the 32-bit chips facet still targets. Two `bool` parameters also want widening to VkBool32 — WaitForFences's wait_all and GetPhysicalDeviceSurfaceSupport's `*bool supported`, the only two in the table, where a conformant caller writes or reads four bytes.

> _objects.zig:27-34 and the five first fields (instance/_instance.zig:14-15, :24-25; device/_device.zig:15-16; queue/_queue.zig:38-39; command/_command.zig:34-35). facet.zig:852 `pub const Buffer = opaque {};` and 24 more such declarations. sdk/fd/facet_lib.fd:109 and :180 are the only two `bool` occurrences in the file.

Found independently by: conformance-path, entry-points (the handle-width and VkBool32 findings).

### 67. Write vkGetInstanceProcAddr, vkGetDeviceProcAddr and the four Enumerate* calls

*shim / entry points* &mdash; conformance-blocking, small

After: Item 66

Nothing can be added to facet to supply the two proc-addr calls: an exec library is reached by its base pointer and a negative LVO offset fixed at build time from the .fd, so there is no name-to-pointer lookup to expose, and vkGetInstanceProcAddr is the symbol a loader must find. The shim must originate them, as a name-to-thunk table over every vk* command it offers, each thunk supplying FacetBase. Beside them go vkEnumerateInstanceLayerProperties, vkEnumerateInstanceExtensionProperties, vkEnumerateDeviceLayerProperties and vkEnumerateDeviceExtensionProperties — core 1.0, the two instance ones the only commands a conformant implementation must answer with no instance in hand, and all four satisfiable with count = 0 (VkLayerProperties and VkExtensionProperties are absent from the SDK). Answering zero extensions is also the cheap resolution for the WSI question: thirteen of facet's 126 entries are not core, eleven of them extension commands held in core position whose arity matches their KHR counterparts exactly minus pAllocator, and with zero extensions advertised the whole dEQP-VK.wsi.* family reports NotSupported, which is an allowed status.

> Verified: sdk/fd/facet_lib.fd:11 `##bias 4` with one LVO slot a line; facet_lvo.zig:698 `pub const vectors = [_]*const anyopaque{` with 126 vec(lvo…) entries and the assertion `4 + decls.len == vectors.len` at :836; calling convention at facet_lvo.zig:295 `fn lvoCreateInstance(base: *FacetBase, ...) callconv(.c)`. facet.zig:139-149 InstanceCreateInfo has no enabled-layer or extension arrays; facet.zig:663-667 DeviceCreateInfo neither. The 13 non-core entries are fd:76-87 (surfaces and swapchains) plus :283 CmdSetBlendConstantsAt.

Found independently by: entry-points, objects-commands, conformance-path (3 strands).

### 68. Marshal the ~92 create-info structs field by field, and detect every pNext chain

*shim / struct translation* &mdash; structural, medium

After: Item 67

A per-struct converter in both directions. The good news is that facet's structs are Vulkan's in Vulkan's field order under snake_case names, so each converter is a copy rather than a reinterpretation — but a cast or memcpy is never valid, for two reasons. No facet struct has sType or pNext, so every field sits 16 bytes earlier than in the C struct; and facet declares its 64-bit fields `u64 align(4)`, so even shared fields differ in offset (VkBufferCreateInfo::size is at offset 24, facet's at 4). The absence of pNext is the harder half: there is nowhere to put or read any extension struct the CTS passes, so the shim must detect and reject or drop every chain it is handed — and it makes the extension *mechanism*, as opposed to the four enumeration calls, unreachable by addition.

> Verified: `grep -c 's_type|sType|pNext|p_next|next:' sdk/libs/facet/facet.zig` -> 0, against `grep -c 'extern struct'` -> 92. Offsets: facet.zig:894-901 BufferCreateInfo (flags, then `size: u64 align(4)`), :1006-1021 ImageCreateInfo, :2053-2071 GraphicsPipelineCreateInfo with the full nine-substruct chain in Vulkan's order.

Found independently by: conformance-path, entry-points, objects-commands (3 strands).

### 69. Honour VkAllocationCallbacks, and decide where pAllocator lives

*shim / allocation* &mdash; conformance-blocking, medium

After: Item 68

No facet entry point takes an allocator; every object is an AllocVec block of the calling task's. Every facet entry point whose name matches a Vulkan command carries exactly Vulkan's parameter list minus `const VkAllocationCallbacks* pAllocator`, and no other arity difference exists anywhere in the table — 42 of facet's entry points correspond to core commands that take it and not one has it. Either thread it through the library, which changes 42 LVO signatures at once and is an ABI break for every existing facet program, or give the shim its own exec memory header backed by the application's callbacks so a failing callback surfaces as VK_ERROR_OUT_OF_HOST_MEMORY from the right call. The CTS does not treat this as optional: dEQP-VK.api.object_management.alloc_callback_fail.* fails each allocation in turn and checks both the result code and that nothing leaked.

> Verified: `grep -c 'AllocationCallbacks|allocator:' sdk/fd/facet_lib.fd` -> 0; fd:12-13 `CreateInstance(*const facet.InstanceCreateInfo info, *?*facet.Instance instance)` has no allocator, and neither has any of the 126 entries; _objects.zig:12-21 "Every object is a block of the calling task's (AllocVec, cleared)". A scripted comparison against the registry found no DIFF rows for any of the 113 shared names once pAllocator was discounted.

Found independently by: conformance-path, entry-points (2 strands).

### 70. Fill VkPhysicalDeviceLimits' ~81 absent members from facet plus new sources

*shim / limits* &mdash; conformance-blocking, medium

After: Item 68; items 25-30 supply the real numbers

The shim needs its own VkPhysicalDeviceLimits, not a cast: 25 of Vulkan's members can be filled from facet's 26 fields (with three type conversions — size_t, float anisotropy, float timestampPeriod), and about 81 have nowhere to read from today. Most are items 25-30's work landing here; the rest the shim can synthesise honestly. This is the point at which the CTS starts checking, since it reads and validates nearly all of them.

> The 26-field list verified by script (see item 16). facet.zig:200 `max_sampler_anisotropy: u32` and :204 `timestamp_period_ns: u32` are the two type mismatches against Vulkan's floats; min_memory_map_alignment is u32 against size_t.

Found independently by: conformance-path, limits.

### 71. Build a runtime SPIR-V back end for the cores

*shaders* &mdash; port + replacement, about 8,760 facet lines:

- one run-time SPIR-V front end with its passes, about 4,630, after `vk_spirv_to_nir` and spirv_to_nir, shared with the V3D;
- an interpreter over the 64-quad batch, about 3,550, where lavapipe has gallivm, with no Mesa C to port;
- about 580 of ABI and pipeline plumbing;
- no emitter, register allocator or scheduler.

After: nothing has to come first. Item 51 decides how a bare `pCode` reaches CreateShaderModule.

The item that decides whether a host CTS run is possible at all, and it cannot be fixed by adding code to the shim. vkCreateShaderModule is handed SPIR-V and nothing else; facet's shader module is a shader.Code whose every Entry carries a non-optional native function pointer, with SPIR-V riding beside it since 1.75 as a hint for a device that compiles. The cores driver has no SPIR-V path whatsoever, and the IR was deliberately built as a comptime construct precisely because an interpreter cannot meet the cores' fragment ABI — one call per 64 quads, a plane at a time in @Vector(4,f32), no branching a pixel. So a shim that must accept arbitrary SPIR-V at runtime has no executor on the host. What it takes is a third back end: SPIR-V to x86-64 (and later aarch64) machine code at pipeline-creation time, meeting that batch ABI, with its own register allocator and scheduler — the same order of work as the QPU back end, and broader, since it must cover the CTS's whole shader corpus rather than one family at a time. Nothing in Goal B can be tested before it exists.

> Verified: sdk/libs/facet/shader.zig:49-55 `function: *const anyopaque,` — not optional; `grep -rln spirv src/disk/libs/facet/driver/cpu/` returns nothing; shader/createshadermodule.zig:60-62 "A device without a processor of its own ignores the words and calls the function"; sdk/libs/facet/ir.zig:17-24 "The cores keep running Zig because their fragment ABI is a batch ... and an interpreter cannot meet that. The graph is walked at **comptime**"; facet.zig:1695-1710 for the Code-or-Module-with-SPIR-V shape.

**Sized from Mesa, 07.11.2026, and the design above was wrong.**

Mesa has one SPIR-V front end for both drivers. v3dv (v3dv_pipeline.c:476) and lavapipe (lvp_pipeline.c:422) both go through `vk_pipeline_shader_stage_to_nir` (vk_pipeline.c:167-233) and `vk_spirv_to_nir` (vk_nir.c:246-350). They translate at pipeline creation, with the entry point's name and the specialization; vkCreateShaderModule only copies the words (vk_shader_module.c:42-43). facet's equivalent is one run-time front end, which the V3D shares.

Behind that front end, lavapipe needs LLVM and llvmpipe a JIT, and Mesa has no CPU machine-code emitter to port. So the cores get an interpreter over facet's 64-quad batch, sixteen times llvmpipe's 4x4 block.

The sentence above that an interpreter cannot meet the cores' fragment ABI is wrong. The ABI is a C call (`FragmentFn`, shader.zig:1775). A trampoline that walks a run-time program over the batch meets it, once `Fragments` carries a program pointer and the facing. Mesa's SoA code does not branch a pixel either: it runs every lane under an execution mask.

Nor is it only a host CTS run that needs this. Under the decision that facet is Vulkan, any PowerOS program must be able to hand vkCreateShaderModule SPIR-V alone, and the cores run every vertex, tessellation and compute stage today.

The softest number is the translation's, about 3,280 lines of the front end's 4,630. It is extrapolated from compile.zig's density, not counted against a list of opcodes. "Goal B" is defined nowhere in this document. The facet.zig citation is stale: ShaderModuleCreateInfo is at facet.zig:2017-2027 at 1.91.

### 72. Decide what a single-core, non-preemptive host exec means for the run

*host runtime* &mdash; structural, medium

After: Item 65

On the host, exec has one core and no task switching, which is why facet's host tests set FacetBase.inline_queues and let the submitting task play the queue. A libvulkan shim inherits that: no device queue task, no parallel tiles, no concurrency for the CTS's multithreaded families (dEQP-VK.api.object_management.multithreaded_*, the synchronization suite). Either establish that those cases are acceptably slow and still correct under inline queues, or give the host exec real task switching — a change to exec, not to facet. Needs measuring before it can be sized. The good news either side of it: facet.library already stands the whole library up on the host through host_rom's exec, and 123 host tests make every call through the jump table, including drawing the FacetCube scene and presenting through a swapchain on a window.

> src/rom/libs/exec/exec.zig:4010 "The waiting half would need task switching the host has not got", :3117 "No workers: the host has one core", :3169; src/disk/libs/facet/facet_base.zig:27 `inline_queues: bool = false,` ("Set by the host tests, whose exec runs no task but theirs"); verified the host test surface: src/disk/libs/facet/tests/ holds facet.zig, draw.zig, ir.zig, present.zig, spirv.zig and spirv_reference.zig.

### 73. Build VK-GL-CTS on the host and get a first run to completion

*CTS* &mdash; structural, medium

After: Item 71

Clone VK-GL-CTS at a release tag, run external/fetch_sources.py (zlib, libpng, jsoncpp, glslang, vulkan-docs, SPIRV-Tools), configure out-of-source with CMake 3.20 or newer plus python3-lxml and a C++ toolchain, build, then run deqp-vk with --deqp-caselist-file=external/vulkancts/mustpass/main/vk-default.txt --deqp-log-images=disable --deqp-log-shader-sources=disable. Passing means every case ends in Pass, NotSupported, QualityWarning, CompatibilityWarning or Waiver. All ordinary host work — the machine already compiles against vulkan.h and -lvulkan — but no case can even start until the shim exists and SPIR-V has an executor, and the first run is where the true size of Goal A's remaining debt becomes measurable rather than estimated.

> scripts/vulkan-check.sh:40-61 already requires cc, glslc, vulkan.h and -lvulkan and skips cleanly when absent, so the host toolchain is proven in-tree. docs/facet-ir.md:610-618 is the only mention of the CTS in the tree and says it "wants a `libvulkan`-shaped shim over facet before a single test of it can run".

### 74. Accept that the CTS cannot run on the CM5, and decide what that costs the V3D

*CTS / board* &mdash; decision + port, about 1,050 facet lines for the route Mesa's own CI takes; no PowerOS conformance claim either way

deqp-vk is C++17 with CMake, threads, dlopen and a filesystem; PowerOS has no libc or POSIX layer to host it and nothing in the tree provides one. So the V3D — the device that will have a runtime SPIR-V back end long before the cores do — is the device the CTS can never be pointed at, without either a POSIX personality for PowerOS or a remote-driven deqp protocol that does not exist here. The practical consequence to accept up front: a conformance claim would be for the cores device on a host, and the V3D would stay covered by facet's own ladder, including its rung-8 cross-check against the real desktop drivers on this machine. Neither document states this.

> Verified: `ls src/disk/libs/` lists 27 libraries — anvil, asl, audiocodec, bsdsocket, codecs, commodities, compression, crypto, datatypes, diskfont, facet, filter, hello, http, icon, iffparse, locale, media, modbus, pci, rdb, smb, tls, truetype, usb, videocodec, wpa — none a libc or POSIX layer. scripts/vulkan-check.sh:1-6 is the existing cross-check asset.

**Sized from Mesa, 07.11.2026: the limit is PowerOS, not the board.** Mesa runs deqp-vk's vk-main mustpass on the V3D 7.1 generation (`renderer_check` "V3D 7.1.7", deqp-broadcom-rpi5-vk.toml:1-5), on Raspberry Pi 5 boards booted into Linux with the v3d module. So the V3D is not a device the CTS can never be pointed at.

The route that sizes:

- facet's driver/v3d runs over a v3d DRM back end under Linux on this CM5, in place of gpu.zig, space.zig and engine.zig (671 lines);
- the back end is modelled on v3dv_bo.c (590 lines), on v3dv_queue.c's submit and sync path (about 557 lines in 11 functions) and on v3d_submit_util.c (107);
- the cores run on the PC.

That comes to about 1,050 facet lines with the syncobj and BO-list path. Fails, flakes and skips would be tracked as Mesa tracks them in broadcom-rpi5-*.txt. Mesa's lists are for V3D 7.1.7 and facet records this board as 7.1.10, so they are a model, not lists to reuse.

It would be a conformance run of facet's driver code under Linux, not a PowerOS claim, because a submission names its CPU and its OS (item 75). Whether Linux goes onto this CM5 at all is the owner's decision. The bench keeps the eMMC unwritten, and the SSD's DH0: and DH1: belong to PowerOS.

Three more statements above need correcting:

- "Long before the cores" rests on item 71's machine-code premise. With one shared front end, both devices get SPIR-V together.
- Rung 8 never runs the V3D: scripts/vulkan-check.sh draws facet's modules with this machine's desktop drivers.
- sdk/libs/exec/libc.zig exists, with memcpy, memmove and memset only. So the conclusion that there is no libc or POSIX layer stands, though the evidence missed it.

### 75. Budget the formal side: adopter status and the submission package

*conformance process* &mdash; structural, medium

After: Item 73

Passing the mustpass list is not conformance. Khronos requires signing the Adopters Agreement for Vulkan (no membership needed), complying with the Process Document, then uploading a submission: the full TestResults-<build type>-<fraction>-of-<total>.qpa logs from every driver build and fraction, the output of git status and git log from the CTS tree, any patches on the release tag as git format-patch output, and a STATEMENT-<adopter> file carrying CONFORM_VERSION, PRODUCT, CPU and OS — all in a gzipped tarball named VK<major><minor>_<adopter>[_info].tgz and nothing else. The CTS build must come from a clean repository; any other change needs a waiver. There is a review period, and until a submission is made only restricted "expected to pass" wording may be used with the Vulkan marks. The fee is the gate in practice, and the figure found is stale (see unknowns).

> VK-GL-CTS external/vulkancts/README.md for the four-part package, the tarball naming and the clean-repo and waiver rules; khronos.org/conformance and the Khronos trademark guidelines for the Adopters Agreement, the Process Document and the restricted wording. Neither facet document mentions the formal process at all.

## What the analysis itself was unsure of

Carried forward verbatim rather than resolved, because each would change
an item above:

- There is no Vulkan registry anywhere in this tree: no vk.xml, no vulkan_core.h. So the ~137 core-command denominator, every required-limit minimum and every mandatory-format row quoted in this list comes from outside the tree. The 126 numerator is measured three ways; the 113/24 split follows from a command list I cannot cite from here. Any number in this list that is a *spec* number should be re-checked against the registry before it is scheduled.
- ~~VkPhysicalDeviceLimits' member count: the limits strand counted 106 from Vulkan-Headers, the conformance-path strand said "about 110".~~ **Settled: 106.** Counted from `/usr/include/vulkan/vulkan_core.h` (VK_HEADER_VERSION 363) by `scripts/vulkan-struct-check.sh`, which also settles the other three: 55 features, 5 sparse properties, 9 properties. The old "26 of ~106" figure was right.
- ~~Whether minTexelGatherOffset and maxTexelGatherOffset are required unconditionally or ride on the optional shaderImageGatherExtended.~~ **Settled: they ride on the feature, and item 28 does shrink by half.** The spec's Required Limits table makes both of the gather pair depend on `shaderImageGatherExtended` with an unsupported value of 0, where minTexelOffset and maxTexelOffset carry no feature at all - which is what `src/disk/libs/facet/tests/vulkan_limits.zig` holds, measured from the table rather than remembered (rows `min_texel_gather_offset` and `max_texel_gather_offset` name the feature; `min_texel_offset` and `max_texel_offset` do not). facet reports `shaderImageGatherExtended` false and has no OpImageGather, so 0 is the mandatory value for the gather pair and the two counted shortfalls are the sample pair alone.
- Whether Vulkan 1.0 strictly requires vkQueueBindSparse's entry point to be *present* when no queue family advertises VK_QUEUE_SPARSE_BINDING_BIT. I kept it conformance-blocking because all 137 core commands are in the 1.0 dispatch table, but 1.0's wording about vkGetDeviceProcAddr and unsupported-feature commands is looser than the 1.2+ text and I found no clause settling it.
- Whether the V3D can honour the 8192 maxImageDimension2D it reports. I found no clamp anywhere under driver/v3d/ and the value is the library-wide constant shared with the cores. Mesa's v3d_limits.h defines V3D_MAX_IMAGE_DIMENSION as 4096 with a comment that the hardware can address 16384 but hangs when that is exposed. This would be a limit reported too *high*, which is off the below-minimum axis but would fail the CTS, and it wants measuring on the board before the 8192 is trusted on that device.
- Whether the HOST_CACHED memory types (MEMF_EXTERNAL regions) are genuinely coherent against the RP1's DMA engines on the CM5. If they are not, FlushMappedMemoryRanges and InvalidateMappedMemoryRanges become real work rather than no-ops, and nonCoherentAtomSize becomes a number that matters. A hardware question; this analysis was read-only and did not touch the board.
- The V3D's supported sample counts. cl.zig:336-341 writes coverage in four bits, which suggests 4 samples, but no register description in the tree states the set, so the V3D half of item 61 is sized on an inference.
- Whether facet's internal ceilings on texel-buffer elements, uniform-buffer range and storage-buffer range clear Vulkan's floors (65536, 16384, 2^27). I found no cap in the tree, which suggests the real ceiling is whatever the allocation is — but "no cap found" is not a measured number.
- The cores' subTexelPrecisionBits and mipmapPrecisionBits (each required >= 4). Position snap is 8 subpixel bits, comfortably over its floor, but the texel-coordinate and mip-level fractional precision was not traced to a bit count, and the V3D's TMU numbers are the hardware's.
- Whether `texture.samplingOf` returning null should refuse the *pipeline* instead of painting magenta. CreateGraphicsPipelines cannot see the bound sampler — it is bound per draw — so a clean refusal may have to happen at draw time, which Vulkan has no result code for. This is the crux of item 52 and worth deciding before the larger IR work.
- How many LVO slots can still be appended. The 22 conformance-blocking commands would take the table from 126 to about 148; nothing in the .fd or facet_lvo.zig states a ceiling and FacetBase's layout below the table was not examined.
- Why docs/facet-gaps.md said 124 when the .fd has held 126 since 1.51. Neither 126 nor the 113 core-named count lands on 124, so what was counted could not be reconstructed.
- Whether a BC-compressed 3D image actually works. Vulkan's BC table is scoped to 2D *and* 3D and shapeFor allows a volume image of a kept-block format on paper, but it was not established that the slice layout and the block decoder agree.
- Whether the cores driver plus exec behave correctly linked into a shared object rather than a test binary (relocation model, the AddMemList region's lifetime, no signal handlers). A .so was not attempted; building was out of scope.
- Whether the host exec could be given task switching at reasonable cost. exec.zig:4010 says it has none; the scheduler was not read, so item 72's size is a guess.
- The current Khronos Vulkan adopter fee. The figure the conformance-path strand found ($95,000 member / $120,000 non-member) is labelled 2020 and the Process Document is the authority.
- Unrelated to this list but it would corrupt any conformance baseline: src/disk/c/test/raster/facetcube.zig:97-112 records `FacetCube CHECK CORES` as DIFFERENT on the CM5 as of 01.11.2026 — 4154 of 19200 pixels beyond the slack, 197 at worst against the 19 allowed — with the cause unproven and noted as the next thing to measure. That is an open defect on the cores path, not a 1.75-1.79 compiler item, and it should be settled before any pixel-accuracy claim is made.

## What was found and then withdrawn

Eight claims were downgraded or narrowed on a second look. They are kept
because a withdrawn claim is as useful as a kept one - it stops the next
reader re-finding it:

- **V3D `stored_both` (combined depth+stencil load/store): conformance-blocking -> feature-gap.** The features strand called it conformance-blocking because Vulkan requires a combined depth-stencil format. It does — but of D24_UNORM_S8_UINT or D32_SFLOAT_S8_UINT, not of D16_UNORM_S8_UINT, which is explicitly optional in Vulkan 1.0. So refusing load/store on facet's own optional format is a clean capability gap; the real debt is having none of the four mandatory formats at all, which is now folded into item 35. The semantics strand had this right.
- **maxViewports "required minimum 16": wrong.** The conformance-path strand listed it among the below-minimum limits. The required value is 16 only when multiViewport is supported; with the feature false the conformant value is 1. The field must exist, the number is fine, so it moves into the bookkeeping item 27 and out of the nine-limits-below-the-floor count. The limits strand had this right.
- **maxDrawIndexedIndexValue "must be 2^32-1": overstated.** The Core minimum is 2^24-1; 2^32-1 applies only if fullDrawIndexUint32 is reported true. Still conformance-blocking, because facet's effective cap is 2^20 and it accepts IndexType.uint32 — but the floor quoted in item 23 is 2^24-1, and declining fullDrawIndexUint32 is a legitimate half-answer the strands did not consider.
- **V3D `storage_images`: feature-gap -> conformance-blocking (an upgrade).** The semantics strand reasoned from fragmentStoresAndAtomics and vertexPipelineStoresAndAtomics, which are indeed optional — but those gate shader *writes*, not the descriptor type. VK_DESCRIPTOR_TYPE_STORAGE_IMAGE is mandatory and maxPerStageDescriptorStorageImages >= 4 has no gating feature, so refusing the descriptor *layout* outright is a conformance block. The features strand had this right, for a reason it did not state.
- **V3D `several_outputs`: narrowed rather than downgraded.** The two strands disagreed (conformance-blocking vs feature-gap) and both are half right. facet's SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER flag is facet's own and its absence is no Vulkan gap, and the replay path draws all the attachments correctly. What is conformance-blocking is narrower and real: the compiler refuses a multi-output module by name, so a Vulkan G-buffer shader cannot be compiled for the V3D as a Vulkan physical device at all.
- **The four layer/extension enumeration commands: relocated, not downgraded.** Still conformance-blocking for a Vulkan implementation, but their home is the shim (item 67), where they answer zero, not facet's LVO table — adding four slots to the .fd buys nothing a program can use, since there is no extension mechanism to enumerate into.
- **"Keep the barrier's arrays" and "read a subpass dependency": kept as feature-gaps owing nothing today, and I verified why** — the queue waits for each command buffer's `done` before the next, and the V3D flushes and invalidates unconditionally around every job. Worth recording because the gap documents say neither, and because these become load-bearing the instant anything is allowed to overlap.
- **"The V3D's pipeline statistics are unlocked by the shader compiler"** (docs/facet-todo.md section 4's unlock table): wrong, and so was this document's correction until 07.11.2026, which said they needed the perfmon read as the frame is drawn. Neither unlocks them: v3dv has no pipeline statistics (v3dv_device.c:358, v3dv_query.c:258-260), and the V3D 7.1 perfmon has no counter for them (v3d_performance_counters.h:35-131). See item 63.
