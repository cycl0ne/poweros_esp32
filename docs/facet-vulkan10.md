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
items 14, 16, 49 and 77 in 1.82, and item 52's half of two in 1.83.** Each
carries a *Done* note below saying what was actually built and where the
item's own description turned out to be wrong - and several did. Things
found while doing them became the items at the end of the list: 77 and 78
from 1.80 and 1.81, and 79, 80 and 81 from 1.82.

Item 52 is the one split between devices: the cores draw every sampler as
of 1.83 and the V3D does not, so the magenta that item is about now
belongs to item 54 alone.

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

One fd line, one LVO wrapper, one file in command/, plus VkImageResolve. While rasterization_samples above 1 is refused there is no legal call a program can make — Vulkan forbids a resolve whose source is single-sampled — so the body is validation and nothing else. The command is a day's work; what it waits on is the whole of item 64. This is the one absent command whose absence no feature bit papers over, because Vulkan 1.0's required limits make 4 colour samples a minimum, so a conformant device genuinely has multisampled images to resolve.

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

*limits / varyings* &mdash; conformance-blocking, large

After: The limits reshape

The single largest limit shortfall: 8 floats of interstage data against a required 64 out of the vertex stage and 64 into the fragment stage. Not a constant to bump — it is the width of what the rasterizer interpolates, so it touches the cores' triangle setup and per-pixel interpolation, the V3D's varying count in the shader record, the IR and the SPIR-V reader's varying plumbing, every fixed form's declared varying count, and shader.Entry.varyings, whose low 8 bits carry the number. The per-triangle vertex store grows eightfold, which is real memory and bandwidth in a tiled rasterizer.

> Verified: src/disk/libs/facet/instance/_instance.zig:39 `pub const max_vertex_output_components = 8;` with the comment "what the library's own objects have room for, whatever the driver"; consumed at driver/cpu/cpu.zig:84 and driver/v3d/driver.zig:114. sdk/libs/facet/shader.zig:56-60 puts the count in Entry.varyings' low 8 bits. Required minimum 64 for both limits (Vulkan 1.0 Required Limits, Core column).

Found independently by: limits, conformance-path.

### 18. Raise maxVertexInputBindings 4 to 16 and maxVertexInputAttributes 8 to 16

*limits / vertex input* &mdash; conformance-blocking, medium

After: The limits reshape

Both below the required minimum of 16. These are the sizes of fixed arrays in the pipeline's vertex-input state, in the command player's bound-buffer table and in both drivers' attribute fetch, so it is mechanical but grows several per-pipeline arrays. maxVertexInputBindingStride is 2048 and exactly meets its floor. Note the spec's footnote: only an implementation enabling VK_KHR_portability_subset may report fewer, and facet is not that.

> Verified: _instance.zig:37-38 `max_vertex_input_bindings = 4;` and `max_vertex_input_attributes = 8;`, reported at cpu.zig:81-82 and driver/v3d/driver.zig:111-112; `.max_vertex_input_binding_stride = 2048` at cpu.zig:84.

Found independently by: limits (2 items), conformance-path.

### 19. Raise the dynamic buffer descriptors from 2 to 8 uniform + 4 storage, and split the one limit in two

*limits / descriptors* &mdash; conformance-blocking, medium

After: The limits reshape

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

facet has no 1D images at all: shapeFor refuses any image_type that is not 2d or 3d in one line, so maxImageDimension1D would be 0 against a required 4096, and no Vulkan 1.0 feature makes 1D images optional. The spec's mandatory format tables are also scoped "for every VkImageType unless otherwise noted", and only the depth/stencil and compressed tables are noted, so every mandatory colour format currently fails the table for 1D. Needs a 1D image kind (rows of one line, or 2D of height 1), the 1D and 1D_ARRAY view types, a 1D sampler path, and both limit fields — a cube is governed today by the 2D limit with nothing said.

> Verified: src/disk/libs/facet/image/_image.zig:338 `if ((info.image_type != .@"2d" and !volume) or info.samples != 1) return null;` — this one line is both the 1D refusal and the multisampled-image refusal. sdk/libs/facet/facet.zig:921-926 declares ImageType.@"1d" = 0; instance/getphysicaldeviceimageformatproperties.zig:25 "`1d` has no images"; src/disk/c/test/raster/facetprobe.zig:1883 asserts "a 1D image refused". Limits struct has no 1d or cube field.

Found independently by: limits, formats, conformance-path (which listed it as an unknown).

### 22. Support layered framebuffers to 256 layers and report maxFramebufferLayers

*limits / render pass* &mdash; conformance-blocking, large

After: The limits reshape

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

*image views / depth* &mdash; conformance-blocking, small

For an image whose kind is depth and which carries IMAGE_USAGE_SAMPLED, CreateImageView routes through depthPlane, which returns null — error_format_not_supported — for an aspect mask naming both planes. Vulkan 1.0 requires a depth/stencil attachment view of a format holding both to name both aspects; separate depth/stencil layouts arrived in 1.2. So a d16_unorm_s8_uint image that is both the pass's depth/stencil attachment and a sampled shadow map cannot have a conformant attachment view: one-plane views work, the two-plane one the attachment needs does not. A plain unsampled depth attachment view is unaffected. Narrow, but a hard refusal of a structure Vulkan requires.

> Verified: image/createimageview.zig:125-131 `const plane = if (_image.sampledDepth(image)) _image.depthPlane(...) orelse return .error_format_not_supported`; _image.zig sampledDepth is `image.kind == .depth and image.usage & IMAGE_USAGE_SAMPLED != 0`. The gap list records the behaviour as a facet choice, not as a Vulkan requirement the attachment view cannot meet.

### 45. Create a timestamp query pool on a machine without timer.device

*query pools* &mdash; conformance-blocking, small

CreateQueryPool refuses QueryType.timestamp outright wherever timestamp_queries is false, which is any machine without timer.device — the host tests run that way, so this bites the shim's own test bed. Vulkan has no mechanism to refuse a timestamp pool: vkCreateQueryPool must succeed, and the device says it cannot time things through timestampValidBits = 0 on the queue family and timestampPeriod. One line in the refusal, plus making CmdWriteTimestamp a recorded no-op and GetQueryPoolResults answer not-available, which _queries.stamped already returns false for.

> Verified verbatim: query/createquerypool.zig:89 `.timestamp => if (!features.timestamp_queries) return .error_feature_not_present,`; driver/_queries.zig:44-52 stamped() already returns false where there is no clock; instance/_instance.zig:88-92 clears the feature on every device when timer.device is absent.

### 46. Give a compute workgroup a barrier

*synchronisation / compute* &mdash; conformance-blocking, large

After: The shape of shader.Groups — serial invocations in one call — having to change

A change to the compute entry's contract, not a call to add. A compute function is called once per workgroup and loops its own invocations serially inside that one call, so the SDK tells a program that "a barrier is the point between two loops over them inside the one call": a shader using barrier() has to be rewritten by hand. Vulkan 1.0 core has OpControlBarrier and OpMemoryBarrier with no feature bit, so a conformant program notices at once. On the cores it needs invocations that can be suspended — coroutines, or the function split into one pass per barrier region — with the SPIR-V reader splitting basic blocks at opcode 224; on the V3D the QPUs have no shared memory the driver drives at all.

> Verified: sdk/libs/facet/shader.zig:1553-1555 for the contract; `grep -nE 'control_barrier|memory_barrier|= 224|= 225' sdk/libs/facet/spirv.zig` returns nothing, so the reader's Op enum has neither; command/cmddispatch.zig:52 "Barriers are taken and need do nothing: the cores run a command at a time". docs/facet-todo.md:83 labels it 1.0 core correctly.

Found independently by: objects-commands, formats (via the atomics item).

### 47. Decide whether an image layout ever means anything

*barriers / layouts* &mdash; structural, months

CmdPipelineBarrier discards every memory, buffer and image barrier it is handed along with dependency_flags, and records only the two stage masks; nothing is checked against an attachment reference's layout or a descriptor's imageLayout either. On a serial single-queue device that is behaviourally conformant, and Vulkan permits an implementation whose layouts are all the same layout. But it is also why an image's kind is baked at CreateImage, and so the direct cause of item 48: with no transition there is nowhere for a rows image to become a texture. The decision is whether a barrier ever re-tiles memory — which makes render-to-texture possible and costs a pass over the image — or whether facet states permanently that layouts are nominal and render-to-texture is a copy. Everything in item 48 follows from this answer, so it comes first.

> Verified by reading the whole function: command/cmdpipelinebarrier.zig:67-78 — `_ = dependency_flags; _ = memory_barrier_count; _ = memory_barriers; _ = buffer_barrier_count; _ = buffer_barriers; _ = image_barrier_count; _ = image_barriers;` then records only `_command.Barrier{ .src_stage_mask, .dst_stage_mask }`. image/_image.zig:5-19 "**What an image is for decides how it lies in its memory.** Its kind is settled as it is made"; both players are `.barrier => {}`.

Found independently by: semantics, objects-commands (whose finding is that the no-op is safe today, and why).

### 48. Accept an image that is both SAMPLED and COLOR_ATTACHMENT

*images / render to texture* &mdash; structural, months

After: Item 47 — image layout meaning something

An image's layout is settled at CreateImage from its usage — rows for an attachment, blocks of texels for a texture — and shapeFor returns null for SAMPLED or STORAGE together with COLOR_ATTACHMENT, so the ordinary Vulkan render-to-texture image cannot be made. Vulkan requires B8G8R8A8_UNORM and R8G8B8A8_UNORM to carry both COLOR_ATTACHMENT and SAMPLED in optimalTilingFeatures and gives no mechanism to refuse the combination; facet's own format table advertises attachment, sampled and storage in the one optimal mask, so the report and the refusal contradict each other. This cannot be fixed by adding a check: it needs either a layout transition that re-tiles the image in place, or a rasterizer that stores tiles straight into the texture layout. The workaround programs use today — draw into a rows image, CmdCopyImage into a texture image — is a copy a Vulkan program does not make. The single largest omission from the gap list.

> Verified verbatim: image/_image.zig:481-482 `if (info.usage & (facet.IMAGE_USAGE_SAMPLED | facet.IMAGE_USAGE_STORAGE) != 0 and !rows_written) { if (info.tiling != .optimal or info.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT != 0) return null;`; _image.zig:18-19 for the stated reason; driver/_format.zig:46-49 advertises all three usages in one mask; getphysicaldeviceimageformatproperties.zig:78-80 says the usages are asked about one at a time; facetprobe.zig:1884 asserts the refusal.

Found independently by: semantics, formats (2 strands, both calling it structural).

### 49. Reconcile GetPhysicalDeviceFeatures with VkPhysicalDeviceFeatures, and decide what replaces the missing enable step

*features / struct shape* &mdash; structural, months, also serves the shim

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

*V3D compiler profile* &mdash; conformance-blocking, months

The single largest body of work behind every V3D item above, and the place about twenty VkPhysicalDeviceFeatures shader-capability members actually live. At 1.79 the back end takes: the Shader capability; 32-bit float and vectors of 2 to 4 (no int, no bool, no f64); storage classes input, output, function and uniform_constant — so NO uniform buffer and NO push constant read from a fragment shader; 2D images only; the fragment stage only; one basic block, so no branch of any kind; one colour out at location 0; about 28 opcodes (f_add, f_mul, vector_times_scalar, composite extract/construct, one image sample — no f_sub, no f_div, no dot, no ExtInst so no GLSL mix/clamp/pow/sqrt); one TMU sample per shader even where several samplers are declared; and no register spilling. Vulkan 1.0 requires all of the descriptor kinds behind those storage classes of any implementation (12 uniform buffers, 4 storage buffers, 16 sampled images, 4 storage images, 4 input attachments per stage). Growing it means qpu.zig gaining the full add/mul tables, pack/unpack, condition flags, branches with their delay slots and the SFU ops, plus a register allocator and a scheduler. On the cores these features are vacuously satisfied, since a shader is a Zig function that may do anything the CPU can.

> Verified by reading the profile in full: compile.zig:188-207 — `.capabilities = &.{.shader}`, the opcode list, `.storage_classes = &.{ .input, .output, .function, .uniform_constant }`, `.image_dims = &.{.dim_2d}`, `.stages = &.{.fragment}`. The error set naming each limit is compile.zig:126-180 (Type, Storage, Location, Outputs, Varyings, Discards, Branches, Body, NoColor, Steps, Uniforms, Registers, TooLong, Samplers, Declared, Numbered). compile.zig:96 most_samplers = 16 against driver.zig:436's single field. The profile's own comment: "It grows a family at a time - discard and samplers first."

Found independently by: features, semantics, conformance-path, doc-staleness (4 strands).

### 60. Compile SPIR-V vertex and compute stages for the V3D **[critical path]**

*V3D compiler* &mdash; conformance-blocking, large, also serves the shim

After: Item 59

The back end is fragment-only and refuses any other stage by name; the vertex and coordinate programs are still generated by the hand-written passThrough/vertexProgram for the varyings a draw carries. Every CTS graphics test supplies a vertex shader, so even a V3D-only run stops here. Needs the Program/Plan/encode pipeline extended to the vertex stage's quite different shape: VPM reads and writes, the coordinate program, and the binner's varying order that _vertices.zig also fixes.

> Verified: compile.zig:2 "a SPIR-V **fragment** module turned into V3D 7.1 instructions"; compile.zig:527 `if (seen.stage != .fragment) return Error.Stage;`; the profile's `.stages = &.{.fragment}`.

### 61. Multisampling: 4 samples a pixel on both devices, with resolve attachments and CmdResolveImage's body **[critical path]**

*rasterisation* &mdash; conformance-blocking, months

The largest item Goal A cannot skip, and the only one Vulkan 1.0 gives no way to refuse — not through a feature bit, since sampleRateShading, alphaToOne and variableMultisampleRate are all optional, but through the required limits: framebufferColorSampleCounts, framebufferDepthSampleCounts, framebufferStencilSampleCounts, sampledImageColorSampleCounts, sampledImageDepthSampleCounts and sampledImageStencilSampleCounts must each include VK_SAMPLE_COUNT_4_BIT; framebufferNoAttachmentsSampleCounts, framebufferIntegerColorSampleCounts, sampledImageIntegerSampleCounts and storageImageSampleCounts must include 1; and maxSampleMaskWords must be at least 1. facet published none of those ten fields until 1.82 and now publishes all of them, at their one-sample values - which is exactly why eight of the eighteen limit shortfalls counted by tests/vulkan_limits.zig are this item - and no device has the capability: rasterization_samples above 1, sample shading, alpha-to-coverage and alpha-to-one are refused in CreateGraphicsPipelines; an attachment with samples != 1 and any resolve_attachments are refused in CreateRenderPass; and CreateImage refuses samples != 1 in the same line that refuses 1D images, so a multisampled image cannot be made at all. On the cores: per-sample colour, depth and stencil in the tile store, a sample loop in every load, store, clear and resolve path, the quad walk writing four pixels under one coverage mask, the sample mask, and alpha-to-coverage in the blend path — the to-do document works the budget through: a 64x64 tile is about 114 KiB live across four parts and 4x makes it ~456 KiB, past the A76's 64 KiB L1 data cache, which is the point of tiling. On the V3D the hardware has 4x coverage and the driver writes one sample's worth in all four bits today, so that side is frame setup, the tile store and resolve rather than new silicon.

> Verified verbatim: creategraphicspipelines.zig:378 `if (multisample.rasterization_samples > 1 or multisample.sample_shading_enable or multisample.alpha_to_coverage_enable or multisample.alpha_to_one_enable) return .error_feature_not_present;`; createrenderpass.zig:216 and :255/:307/:378; image/_image.zig:338 `... or info.samples != 1) return null;`; multisampling verified absent from both driver tables so false by default; facet.zig:317 `multisampling: bool = false,` ("No device of this library has it.") and :572-573 `sample_counts: u32 = 0,`; one-sample coverage at driver/v3d/cl.zig:336-341. docs/facet-todo.md section 2 states the conformance point correctly and is not stale.

Found independently by: features, limits, semantics, entry-points, conformance-path (all 5 strands that looked at it).

### 62. The optional capabilities facet refuses cleanly: logic ops, several viewports, dual-source blend

*pipeline state / blending* &mdash; feature-gap, large

After: Integer types in the compiler's profile for the V3D half of logicOp

Three optional Vulkan 1.0 features refused with error_feature_not_present, so all three are legal absences and pure capability work. logicOp: logic_op_enable is refused for every attachment on every device though LogicOp is fully enumerated — on the cores a second write path in the tile blender (16 bitwise operations over the tile's 8888 words, bypassing the blend fast path), on the V3D lowering into the fragment program, which is now possible in principle since there is a compiler but needs integer types in its profile. multiViewport: viewport_count != 1 or scissor_count != 1 is refused; needs a per-primitive viewport index the SDK's vertex stage has no slot for and a tile walk comparing against several rectangles, and one viewport is also what keeps the scissor and depth bounds a single state. dualSrcBlend: BlendFactor stops at src_alpha_saturate = 14 and any factor above is refused; needs a fragment function writing two colours for one attachment and a blender reading the second, which is close to the several_outputs plumbing.

> Verified: creategraphicspipelines.zig:412 `if (blend.logic_op_enable) return .error_feature_not_present;` (unconditional, not behind the feature), :471 the viewport/scissor refusal, :428 the factor refusal; logic_ops and several_viewports verified absent from both driver tables; BlendFactor ends at src_alpha_saturate = 14. docs/facet-todo.md section 2's logicOp row ("the QPUs run no program of ours") is now stale.

Found independently by: features (3 items), semantics (3 items) — 6 findings merged.

### 63. The optional capabilities with no call and no field: geometry shaders, ASTC, real sparse, robustBufferAccess, V3D pipeline statistics, cube arrays

*missing capabilities* &mdash; feature-gap, months

All optional in Vulkan 1.0, all absent, each a clean capability to add rather than a conformance bug — recorded so they are not mistaken for debt. geometryShader: no SHADER_STAGE_GEOMETRY bit at all; needs the stage, an entry kind, and a primitive stream the binner takes from somewhere other than the vertex array. textureCompressionASTC_LDR: no format and no decoder anywhere in the tree. sparseBinding and the residency bits: memory is exec's and bound whole. robustBufferAccess: nothing in the tree, and with it absent out-of-bounds access is undefined, which Vulkan permits. pipelineStatisticsQuery on the V3D: nothing counts what its QPUs were given, so the kind is refused there; needs the binner's and renderer's perfmon counters read as the frame is drawn, the way the occlusion counter already is — not compiler work, which the to-do document's unlock table miscredits. imageCubeArray on the V3D: no QPU program reads the fourth coordinate, so a cube_array view and texture_cube_array are refused; needs Dim::Cube and arrayed images in the profile.

> Verified: BlendFactor and the stage bits as above; `grep -i astc` across sdk/ and src/disk/libs/facet/ hits only prose at facet_version.zig:1075; `grep -i robust` across both trees returns nothing; driver/v3d/driver.zig:166 `.pipeline_statistics_queries = false` (occlusion is true on both, driver.zig:165 and cpu.zig:128), :192 `.cube_arrays = false`; refusals at createquerypool.zig:83-84 and driver.zig:460.

Found independently by: features (3 items), semantics (2 items).

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

*structures* &mdash; structural, months

facet's create-infos are Vulkan's shape minus sType/pNext and plus fields of facet's own: PipelineColorBlendStateCreateInfo.attachment_constants (one set of blend constants per attachment where Vulkan has one), SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER in SubpassDescription.flags, IMAGE_CREATE_PACKED_TEXELS at bit 31, PIPELINE_CREATE_DEPTH_PREPASS, SHADER_MODULE_CREATE_SPIRV, CmdSetBlendConstantsAt occupying an LVO slot a Vulkan-ordered table would not have, and attachment_count = 0 meaning "the default over all of them" where Vulkan requires it to equal the subpass's colour count. None can be fixed by adding code: a Vulkan-source program's initialisers do not compile and a Vulkan binary's structs do not match. Deciding whether these become real extension structs behind pNext or are dropped is the shape question, and it is the one that decides whether anything above can be called conformance at all.

> Verified: PipelineColorBlendStateCreateInfo's members are flags, logic_op_enable, logic_op, attachment_count, attachments, blend_constants, attachment_constants with no sType/pNext; facet.zig:988 PACKED_TEXELS at bit 31, :1710 SHADER_MODULE_CREATE_SPIRV; createrenderpass.zig:282-284; creategraphicspipelines.zig:413. docs/facet-gaps.md:1-9 is honest that the library "is not Vulkan, and does not try to be".

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

*shaders* &mdash; structural, months

After: Item 68

The item that decides whether a host CTS run is possible at all, and it cannot be fixed by adding code to the shim. vkCreateShaderModule is handed SPIR-V and nothing else; facet's shader module is a shader.Code whose every Entry carries a non-optional native function pointer, with SPIR-V riding beside it since 1.75 as a hint for a device that compiles. The cores driver has no SPIR-V path whatsoever, and the IR was deliberately built as a comptime construct precisely because an interpreter cannot meet the cores' fragment ABI — one call per 64 quads, a plane at a time in @Vector(4,f32), no branching a pixel. So a shim that must accept arbitrary SPIR-V at runtime has no executor on the host. What it takes is a third back end: SPIR-V to x86-64 (and later aarch64) machine code at pipeline-creation time, meeting that batch ABI, with its own register allocator and scheduler — the same order of work as the QPU back end, and broader, since it must cover the CTS's whole shader corpus rather than one family at a time. Nothing in Goal B can be tested before it exists.

> Verified: sdk/libs/facet/shader.zig:49-55 `function: *const anyopaque,` — not optional; `grep -rln spirv src/disk/libs/facet/driver/cpu/` returns nothing; shader/createshadermodule.zig:60-62 "A device without a processor of its own ignores the words and calls the function"; sdk/libs/facet/ir.zig:17-24 "The cores keep running Zig because their fragment ABI is a batch ... and an interpreter cannot meet that. The graph is walked at **comptime**"; facet.zig:1695-1710 for the Code-or-Module-with-SPIR-V shape.

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

*CTS / board* &mdash; structural, months

deqp-vk is C++17 with CMake, threads, dlopen and a filesystem; PowerOS has no libc or POSIX layer to host it and nothing in the tree provides one. So the V3D — the device that will have a runtime SPIR-V back end long before the cores do — is the device the CTS can never be pointed at, without either a POSIX personality for PowerOS or a remote-driven deqp protocol that does not exist here. The practical consequence to accept up front: a conformance claim would be for the cores device on a host, and the V3D would stay covered by facet's own ladder, including its rung-8 cross-check against the real desktop drivers on this machine. Neither document states this.

> Verified: `ls src/disk/libs/` lists 27 libraries — anvil, asl, audiocodec, bsdsocket, codecs, commodities, compression, crypto, datatypes, diskfont, facet, filter, hello, http, icon, iffparse, locale, media, modbus, pci, rdb, smb, tls, truetype, usb, videocodec, wpa — none a libc or POSIX layer. scripts/vulkan-check.sh:1-6 is the existing cross-check asset.

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
- Whether minTexelGatherOffset and maxTexelGatherOffset are required unconditionally or ride on the optional shaderImageGatherExtended. minTexelOffset and maxTexelOffset (ConstOffset on OpImageSample) I am confident are unconditional; if the gather pair is gated, item 28 shrinks by half.
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
- **"The V3D's pipeline statistics are unlocked by the shader compiler"** (docs/facet-todo.md section 4's unlock table): wrong. They need the binner's and renderer's perfmon registers read as the frame is drawn, not code generation. Noted in item 63.
