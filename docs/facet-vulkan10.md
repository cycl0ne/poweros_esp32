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
Mesa, in 1.92, item 45 in 1.93, item 44 in 1.94, item 84 in 1.95,
item 61's next six rows of eight, on the cores, in 1.112, item 43's
half of two, the cores', in 1.113, item 61's last row of eight, on the
cores, in 1.114, item 85's half of two, the cores', in 1.115, item 87
in 1.116, item 88 in 1.117, item 86 in 1.118, item 48's half of two,
the cores', in 1.119, item 41 in 1.120, item 89 in 1.121, item 15 in
1.122, item 11 in 1.123, item 12 in 1.124, item 79 in 1.125, item 32 in
1.126, item 31 in 1.127, item 29 in 1.128, item 9 in 1.129, item 10's
first half of two in 1.130, item 42's half of two, the cores', in
1.131, item 90 in 1.132, and item 81 in 1.133.**
Each
carries a *Done* note below saying what was actually built and where the
item's own description turned out to be wrong - and several did. Things
found while doing them became the items at the end of the list: 77 and 78
from 1.80 and 1.81, 79, 80 and 81 from 1.82, 85 and 86 from 1.113,
87 and 88 from scoping item 86, 89 from item 41, 90 from item 42, and 91
from item 81.

Items 52, 28, 17, 22, 61, 43, 85, 48 and 42 are the ones split between devices:
the cores draw every sampler as of 1.83, sample at a constant texel offset
as of 1.87, carry 64 varyings as of 1.90, take framebuffers of 256 layers
as of 1.91, draw four samples a pixel as of 1.112 (in a subpass of no
attachment as of 1.114), a subpass with no colour attachment as of 1.113,
a pipeline of no fragment stage as of 1.115, an image both drawn into
and sampled as of 1.119 and a view of another format of an image as of
1.131, and the V3D did none of the nine until it drew four samples a
pixel in 1.148 and 1.149 (item 61's V1 to V6), and a subpass of no
colour attachment, a pipeline of no fragment stage and a subpass of no
attachment at four in 1.150 (items 43 and 85, and V8) - so the
magenta item 52 is about now belongs to item 54 alone, item 28's
remainder is a QPU back end that refuses the operand at pipeline
creation, item 17's is a vertex program that keeps its varyings in
registers and so stops at eight, item 22's is a render list played once
a frame rather than once a layer, item 61's is its step V7, item 48's
is a store and a load that name the UIF layout, and a clear through the
TLB, and item 42's is a texture state and a render target of the view's
format.

None of the nine is the hardware's limit. Mesa's v3dv runs Vulkan on this
same V3D 7.1 with 64 varyings, texel offsets of -8 to 7, 256 framebuffer
layers, four samples a pixel (`src/broadcom/vulkan/v3dv_device.c`),
subpasses of no colour attachment (v3dvx_cmd_buffer.c:1189-1197),
pipelines of no fragment stage (v3dv_pipeline.c:2616-2642), images
drawn into and sampled, every optimal one being UIF (v3dv_image.c:481-483),
and views of another format of every image, each made MUTABLE
(v3dv_image.c:518-522), so
each remainder is the port of named Mesa code, and the items say which. Until
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

*entry points / synchronisation* &mdash; conformance-blocking, medium, also serves the shim &mdash; **done in 1.129**

After: facet.Result gaining event_set = 3 and event_reset = 4

Eight entry points and eight LVO slots, none of which exists: CreateEvent, DestroyEvent, GetEventStatus, SetEvent, ResetEvent, CmdSetEvent, CmdResetEvent, CmdWaitEvents. Core 1.0 with no feature bit, so a conformant implementation cannot omit them. Needs a two-field struct in sync/_sync.zig beside Fence and Semaphore (both are bare exec.Waitable), five host calls, three new _stream.Op values with their recorders, and both players honouring them where `.barrier => {}` sits — the wait arm blocking the queue task on the waitable. Adding to _stream.Op changes _driver.stamp, so the V3D driver module on the SSD must be rebuilt in lockstep or it refuses to load. The gap documents' reason — that only a multi-queue device gives events something to do — is not merely stale but wrong: a host SetEvent releasing a pending CmdWaitEvents is the spec's own case.

> Verified: `grep -icE 'event' sdk/fd/facet_lib.fd` -> 0; src/disk/libs/facet/sync/ holds only fence and semaphore files; facet.Result has no 3 or 4; src/disk/libs/facet/command/_stream.zig:23-62 has no event op; driver/cpu/_play.zig:176 and driver/v3d/_play.zig:225 are both `.barrier => {}`; driver/_driver.zig:147 sums every _stream.Op field into the module stamp. docs/facet-gaps.md:457-465, docs/facet-todo.md:73.

Found independently by: entry-points, objects-commands, conformance-path (3 strands).

**Done in 1.129**, in 202 lines of code, the generated interface aside,
and 128 of tests, as lavapipe has them: its queue plays a command buffer
one command after the other, as this one does. An event is an exec
waitable, as a fence and a semaphore are - one field, not the two counted
above - made reset (`lvp_CreateEvent`, lvp_device.c:2708-2727), set and
reset by the host at once (:2754-2772), and read by GetEventStatus, which
answers `event_set` or `event_reset` and, as v3dv's does,
`error_device_lost` once the device is lost (`v3dv_GetEventStatus`,
v3dv_event.c:451-459). The three commands are three `_stream.Op` values,
played by one function of sync/_sync.zig that both players call beside
`.barrier => {}`: the set and the reset as lavapipe's `handle_event_set2`
and `handle_event_reset2`, the wait as `handle_wait_events2`
(lvp_execute.c:3401-3433), which holds the queue until each event is set
and leaves it set. Where lavapipe spins, the queue's task sleeps in
WaitForAny, which a SetEvent wakes. CmdWaitEvents records the wait alone:
the CmdPipelineBarrier Mesa's runtime records after it
(`vk_common_CmdWaitEvents`, vk_synchronization.c:307-370) changes nothing
here, and no event at all records nothing, as there. Two things above were
not so. The stamp moves with every revision, `LIBRARY_REVISION` being in
it, so the V3D's module was always built and shipped with the library; the
new ops are nothing more. And a host SetEvent releasing a pending
CmdWaitEvents was Vulkan 1.0's case, not today's spec's, which has the host
set the event before the work that waits for it is submitted (its section
6.6, VUID-vkSetEvent-event-09543), so that a wait has nothing to wait for.
It still works: C:test/FacetProbe has a queue's task wait while the program
sets the event, which the host tests cannot, the task that submits there
playing the work itself. The gap documents' reason - one in-order queue
gives a wait nothing to wait for - is so, and is why events cost nothing
here: lavapipe's queue is the same.

### 10. Add the pipeline cache's four commands, and make the cache real

*entry points / pipelines* &mdash; conformance-blocking, medium, also serves the shim &mdash; **the four commands done in 1.130, as lavapipe has them**; the V3D's cache of its compiled programs is the pipeline half of v3dv_pipeline_cache.c, about 800 of its 1,088 lines of C

After: PhysicalDeviceProperties.pipeline_cache_uuid

CreatePipelineCache, DestroyPipelineCache, GetPipelineCacheData, MergePipelineCaches. Core 1.0, no feature bit. The object is already declared and the parameter already plumbed through both pipeline-create calls, so the cheap form is a cache that caches nothing plus a valid 32-byte header from GetPipelineCacheData — which means PhysicalDeviceProperties must first gain pipeline_cache_uuid. The real form now has something to hold: the blob wants the library revision, the _driver.stamp and the device id so a cache from another build is rejected rather than trusted, and the pipeline-create calls want a lookup by a hash of the stage's SPIR-V. Its own justification ("pipelines are cheap to make here, because there is nothing to compile") expired at 1.76: a V3D pipeline with words now takes a Work block, runs the back end and allocates V3D memory that lives as long as the pipeline.

> Verified: the only `PipelineCache` occurrences in sdk/fd/facet_lib.fd are the two create-pipeline parameters at :149 and :228 — no Create/Destroy/GetData/Merge anywhere. sdk/libs/facet/facet.zig:1683 `pub const PipelineCache = opaque {};`; facet.zig:245-255 PhysicalDeviceProperties has no pipeline_cache_uuid; driver/v3d/driver.zig:464-508 `fn compiled`. docs/facet-gaps.md:467-474 (stale reason), docs/facet-todo.md:74 ("This one's reason expires on its own").

Found independently by: entry-points, objects-commands, conformance-path (3 strands).

**The four commands done in 1.130**, in 100 lines of code, the generated
interface aside, and 75 of tests, as lavapipe has them
(lvp_pipeline_cache.c:26-103): a cache holds no pipeline, is made from
initial data it does not read and merged to no effect, and
GetPipelineCacheData hands out Vulkan's header of 32 bytes alone - its
size, version one, and the device's `vendor_id`, `device_id` and
`pipeline_cache_uuid`, least significant byte first - with `incomplete`
and nothing written where there is no room for it. What it gives is a
header and no pipeline, and Vulkan leaves a cache empty for data from
anywhere else, so the initial data has nothing in it to take.
`pipeline_cache_uuid` was there since 1.82 (`_driver.cacheUuid`), and
moves with the library's revision, which tells data kept from another
build apart. That is the cores' cache whole, as it is lavapipe's.

The V3D's half is what the cache can hold there: since 1.76 the V3D
compiles a pipeline's fragment program from its words (`compiled`,
driver/v3d/driver.zig), and v3dv keeps a pipeline's compiled programs by
a hash of what shapes them - the pipeline half of v3dv_pipeline_cache.c,
`v3dv_pipeline_cache_search_for_pipeline`, `_upload_pipeline`, the blob
writers and readers, `pipeline_cache_load`, MergePipelineCaches and
GetPipelineCacheData, about 800 of its 1,088 lines of C. Its NIR half has
nothing to hold here: the words are what the compile starts from.

### 11. Add FlushMappedMemoryRanges and InvalidateMappedMemoryRanges as the no-ops they would be

*entry points / memory* &mdash; conformance-blocking, small, also serves the shim &mdash; **done in 1.123**

Two core 1.0 commands that must be present and callable even when every host-visible memory type is HOST_COHERENT, in which case they legally return VK_SUCCESS after checking each range against its mapping. Needs VkMappedMemoryRange (absent) and two LVO slots, plus non_coherent_atom_size in the limits — mandatory even though it is only meaningful once a non-coherent type exists. The documents' premise is correct and their conclusion is not: Vulkan requires the commands to exist, not merely to have work to do.

> Verified: the fd has MapMemory (:41) and UnmapMemory (:43) and no flush/invalidate; both drivers always set HOST_VISIBLE|HOST_COHERENT (driver/cpu/cpu.zig:262, driver/v3d/driver.zig:278); `grep -n non_coherent sdk/libs/facet/facet.zig` finds nothing. docs/facet-gaps.md:549-551.

Found independently by: entry-points, objects-commands, conformance-path (3 strands).

**Done in 1.123**, in 35 lines of code, the generated interface aside,
and 36 of tests, as lavapipe and v3dv have them: both answer `VK_SUCCESS` and look at nothing
(`lvp_FlushMappedMemoryRanges` and `lvp_InvalidateMappedMemoryRanges`,
lvp_device.c:2390-2404; `v3dv_FlushMappedMemoryRanges` and
`v3dv_InvalidateMappedMemoryRanges`, v3dv_device.c:2724-2738).
`FlushMappedMemoryRanges` (LVO -528), `InvalidateMappedMemoryRanges` (LVO
-532) and `MappedMemoryRange` are Vulkan's, the structure without sType
and pNext as every structure here is until item 51. The item's checking
of each range against its mapping is not what Mesa does, and Vulkan does
not ask for it: a range outside the mapping, or not rounded to the atom,
is the program's mistake (VUID-VkMappedMemoryRange-size-00685,
VUID-VkMappedMemoryRange-offset-00687), which no call has to find.
`non_coherent_atom_size` was there already, with the limits of 1.82
(item 16): 64, lavapipe's own.

### 12. Add the three sparse entry points as stubs, and the struct members 1.0 requires beside them

*entry points / memory* &mdash; conformance-blocking, small, also serves the shim &mdash; **done in 1.124**

Three stubs, three fd lines, three LVOs: GetPhysicalDeviceSparseImageFormatProperties and GetImageSparseMemoryRequirements writing count 0, and QueueBindSparse, which no legal call can reach because no queue family carries a sparse bit. Beside them PhysicalDeviceProperties needs sparse_properties and the features struct the sparse bits, all answering false — Vulkan requires both to be reportable even when every answer is no. The sparse *functionality* is a separate optional capability, and real residency is a different machine: page tables facet may write, where the V3D's MMU is the firmware's.

> Verified: `grep -ci sparse sdk/fd/facet_lib.fd` -> 0; `grep -rn -i sparse sdk/libs/facet/ src/disk/libs/facet/ --include='*.zig'` finds only prose at facet.zig:262 and getphysicaldevicefeatures.zig:48; facet.zig:245-255 has no sparse_properties; facet.zig:976 and :988 are the only two IMAGE_CREATE_ bits, so there are no sparse image flags to refuse; facet.zig:551-553 has no QUEUE_SPARSE_BINDING bit.

Found independently by: entry-points (3 items), objects-commands, formats, conformance-path (4 strands).

**Done in 1.124**, in 109 lines of code, the generated interface aside,
and 51 of tests, as v3dv has them, v3dv binding no memory sparsely
either: the two queries set the count to 0 and write nothing
(`v3dv_GetPhysicalDeviceSparseImageFormatProperties`,
v3dv_formats.c:818-829; `v3dv_GetImageSparseMemoryRequirements`,
v3dv_device.c:3430-3438), as Vulkan has them answer for arguments
without `VK_IMAGE_CREATE_SPARSE_RESIDENCY_BIT` and for an image not made
with it, and `QueueBindSparse` answers `VK_ERROR_FEATURE_NOT_PRESENT`
(`v3dv_QueueBindSparse`, v3dv_queue.c:1170-1178). They are LVO -536,
-540 and -544, with Vulkan's sparse structures and `QUEUE_SPARSE_BINDING`
beside them. The struct members the item asked for were there before it:
`sparse_properties` with item 14 and the nine sparse features with item
16, both in 1.82. `QueueBindSparse`'s code is not one of the call's own,
a lost device and no memory, which is item 81's kind of finding; no call
a program may make reaches it (VUID-vkQueueBindSparse-queuetype), so it
is v3dv's answer as it stands.

### 13. Add CmdResolveImage, as a stub until there is multisampling

*entry points / commands* &mdash; conformance-blocking, small, also serves the shim

**Done in 1.101, with its body rather than as a stub.** `CmdResolveImage`
(LVO -524) and `ImageResolve` are Vulkan's. The command averages each
pixel's four samples a channel at a time, `(s0+s1+s2+s3+2)>>2`, as
lavapipe's resolve (`handle_resolve_image`, lvp_execute.c:3871-3916) and
Mesa's average (`build_tex_resolve`, vk_meta_blit_resolve.c:134-196) do,
into rows or a texture. It is step S5 of item 61's plan. Until a device
drew four samples no program could make an image to resolve, and the
tests turned the capability on to reach it; the cores draw four since
1.112 (item 61's K7), and the V3D will from V5 on.

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

*query pools* &mdash; conformance-blocking, medium &mdash; **done in 1.122**

Pool.counts is [*]u32, written and read with 32-bit atomics and held at its highest rather than wrapping. GetQueryPoolResults honours QUERY_RESULT_64 by writing eight bytes, so a conformant caller that asks for a 64-bit occlusion result and passes 2^32-1 samples is handed a saturated value where Vulkan does not leave it undefined. At 2560x1440 that is about 1165 full-screen depth-passing draws inside one query. Needs a 64-bit atomic, which the library cannot assume because it runs on 32-bit chips too — so either a per-core 32-bit counter summed at the fence, which the tiled rasterizer's part structure already suggests, or a per-driver change on the CM5 alone. A timestamp is already 64 bits because one task writes it whole.

> Verified: src/disk/libs/facet/query/_query.zig:73 `counts: [*]u32,` and :76 `times: [*]u64,`; :116 `@atomicStore(u32, ...)`; query/getquerypoolresults.zig:44-45 "one that will not fit is held at 0xFFFFFFFF, where Vulkan leaves it undefined". docs/facet-gaps.md:135-148 and docs/facet-todo.md:84 both state it and both are still true.

Found independently by: entry-points, semantics.

**Done in 1.122**, in 54 lines of code and 69 of tests, and as llvmpipe
does it. llvmpipe keeps a 64-bit count for each of its rasterizer threads
(`llvmpipe_query.start` and `end`, lp_query.h:45-46), each thread adding
to its own (`lp_rast_end_query`, lp_rast.c:665-688), and adds them up when
the query is read (`llvmpipe_get_query_result`, lp_query.c:122-129,
196-206). That is the item's counter for each core, with no fence needed
to sum it at: a counter here is `_query.lanes` lanes of 64 bits, one for
each part a frame's tiles are drawn in. A batch adds what it counted to
the lane of the part drawing its tile (`batched.zig` `countUp`, the part
from `Tile.part`), the queue's task adds a draw's numbers, a dispatch's
and the V3D's frame to the first lane, part 0 being its own, and
`_query.valueAt` sums the lanes as it reads them. No lane has two writers,
so no machine needs a 64-bit atomic add: a lane is loaded and stored whole
where the words are 64 bits, and plainly on a 32-bit machine, where a
partial result read while a lane is added to may catch it between its two
words. A counter takes 32 bytes of its pool where it took 4.

A 4-byte result is still held at 0xFFFFFFFF, which Vulkan allows: "the
value may either wrap or saturate" (17.2), not undefined as the item and
the call's documentation had it. The 8-byte one is whole.

Found on the way: batched.zig's tests had never run, the raster module's
test block not naming the file. It is named now, and the test already
there passes.

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

**The pin is 0 since 1.114**: the cores meet all 106, the last being item
61's no-attachments mask. What the V3D still falls short on is the
remainder of the items split between the devices, 28, 17, 22, 61 and 43,
which tests/vulkan_limits.zig lists row by row.

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

**Corrected in 1.97: no compressed format is a 1D image's.** Until then
one was made: a texture of blocks a row high, which nothing tested. Its
layout overflowed working out the gap between a level's rows, and so did
every BC1 or BC4 image with a full chain of levels, at its level 4 texels
across. CreateImage and the format query alike panicked there. A
compressed level's gap is now none, since only the walk over uncompressed
texels reads it, and a compressed 1D image is refused, as both Mesa
drivers refuse one (`lvp_get_image_format_properties`, lvp_formats.c:347-349;
`get_image_format_properties`, v3dv_formats.c:598-602). Vulkan's
compressed format tables are the ones scoped away from 1D, so no
requirement is lost. Item 61's sweep of the format query found it.

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

*limits / fragment and compute* &mdash; conformance-blocking, small &mdash; **done in 1.128**

After: maxFragmentInputComponents depends on item 17

Four fields with Core minimums: maxFragmentInputComponents (>=64, the same 8-varying cap as item 17), maxFragmentOutputAttachments (>=4, which most_colors = 4 just meets), maxFragmentCombinedOutputResources (>=4) and maxComputeWorkGroupCount ((65535,65535,65535)). CmdDispatch has no group-count check, so the dispatch limit is probably already met and only needs reporting. The three compute limits facet does report are present and plausible.

> Verified: the limits struct reports max_compute_work_group_size, max_compute_work_group_invocations and max_compute_shared_memory_size (set from _instance.zig:66-68 to {1024,1024,64}, 1024, 16 KiB) and no work-group count; render/_render.zig:36 `pub const most_colors = 4;`; no refusal or cap in command/cmddispatch.zig.

**Done in 1.128**, in 1 line of code and 5 of tests - and most of it was
done before this list was: item 16's reshape in 1.82 gave the structure
all four fields and set them, maxFragmentInputComponents to the vertex
outputs' number (64 since item 17), maxFragmentOutputAttachments to
`most_colors`, maxFragmentCombinedOutputResources to 0xFFFF, the
maxPerStageResources that bounds the same descriptors and colours, and
maxComputeWorkGroupCount to 2^32 - 1 on each axis. That last was a
promise the dispatcher could not keep: it counts the groups in 64 bits
and multiplies the count again to cut it into parts (`_compute.dispatch`),
so the largest dispatch it admitted overflowed. It is 65535 on each axis
now, as both Mesa drivers have it - llvmpipe's grid (lp_screen.c:167-169)
and the V3D's dispatcher (`V3D_MAX_CSD_WG_COUNT`, v3d_limits.h:81) - with a
test that the largest dispatch the limits admit can be counted. The V3D's
1 for maxFragmentOutputAttachments and maxFragmentCombinedOutputResources,
under Vulkan's 4, is item 55's: a QPU fragment program writes one colour.

### 30. Fill the limits that may conformantly stay at their unsupported values, and decide the tessellation and geometry numbers

*limits / optional features* &mdash; feature-gap, small

After: The limits reshape

About eighteen fields that must exist for a well-formed Vulkan driver but owe no capability work, because the gating feature is optional and the spec's Unsupported column permits 0 or 1: sparseAddressSpaceSize, maxViewports (1), maxDrawIndirectCount (1), maxFragmentDualSrcAttachments (0), min/maxInterpolationOffset and subPixelInterpolationOffsetBits (0 without sampleRateShading), maxClipDistances / maxCullDistances / maxCombinedClipAndCullDistances (0), all eight tessellation limits and all five geometry limits (0 when the features are false). The numbers matter only if the features are claimed: facet's max_tessellation_patch_components is 16 against maxTessellationControlPerPatchOutputComponents' required 120, max_patch_points is 32 which exactly meets maxTessellationPatchSize but is a library constant that is not reported at all, and there is no geometry stage whatever.

> Verified: _instance.zig:42-43 `pub const max_patch_points = 32;` / `pub const max_tessellation_patch_components = 16;`, only the latter reported (cpu.zig:97, driver/v3d/driver.zig:124); none of the eighteen other fields is among the 26; several_viewports false in both tables.

### 31. Add the six mandatory formats that have no facet.Format value

*formats / enumeration* &mdash; conformance-blocking, small &mdash; **done in 1.127**

Six formats carrying unconditional mandatory features are absent from the enum: B4G4R4A4_UNORM_PACK16, A1R5G5B5_UNORM_PACK16, A8B8G8R8_SNORM_PACK32, A8B8G8R8_UINT_PACK32, A8B8G8R8_SINT_PACK32 and D32_SFLOAT. The three a8b8g8r8 pack32 ones are byte-identical to their r8g8b8a8 forms on a little-endian machine — facet already says so for the _unorm and _srgb pair — so they are three enum values plus three switch arms. The two packed-16 ones need a new texel layout; D32_SFLOAT is item 35's.

> Verified by enumerating the Format enum (sdk/libs/facet/facet.zig:682-821, 71 members): none of the six is present. facet.zig:804-807 states the little-endian aliasing for the pair that does exist. Noted: docs/facet-todo.md:30-36 claims section 1 is empty and "the texel buffers read every format Vulkan 1.0 asks of them" — wrong by exactly these three pack32 forms.

**Done in 1.127**, in 39 lines of code and 153 of tests, for five of the
six: D32_SFLOAT stays with item 35, which is where it becomes a depth
format. The three A8B8G8R8 words are their R8G8B8A8 forms under another
name, as v3dv has them - the same texture and render-target types
(src/broadcom/vulkan/v3dvx_formats.c:131-134 beside :191-195) - so they
took a name more in five switches rather than the three arms counted
above: what a texel buffer reads, the format table, and an image's
whole-number test, size and kept format. The two words of 16 bits did not
need a texel layout of their own: they are unpacked into 8 bits a channel
as they are copied in, as ETC2 is, through a decoder beside the float one
(`_decode.texel`), so both devices sample, filter and blit out of them.
v3dv keeps them as the V3D's own RGBA4 and A1_RGB5 textures (:187, :190),
which here would want a texture format of the SDK's and the V3D's texture
state for half the memory. What the five still lack is what their
siblings lack: COLOR_ATTACHMENT, BLIT_DST and blending for A1R5G5B5 and
the A8B8G8R8 whole numbers (36), BLIT_SRC for those whole numbers (36),
SAMPLED_IMAGE and BLIT_SRC for the _snorm word (37), and VERTEX_BUFFER for
the three words (33). docs/facet-todo.md's "the texel buffers read every
format Vulkan 1.0 asks of them" is true since this revision.

### 32. Define BLIT_SRC and BLIT_DST and report them

*formats / FormatProperties bitmask* &mdash; conformance-blocking, small &mdash; **done in 1.126**

After: Items 33-40 for the formats facet cannot yet draw into or sample

FORMAT_FEATURE_BLIT_SRC (1<<10) and BLIT_DST (1<<11) do not exist in facet's bitmask, so facet reports neither for any format on either device — although CmdBlitImage is in the jump table and documented as taking "images of colour, of any formats". Vulkan mandates BLIT_SRC for 47 formats and BLIT_DST for 38. Defining the bits and setting them for what CmdBlitImage already reads and writes is small; the rest of the coverage rides on items 33-40.

> Verified by listing the constants: facet.zig:825-839 defines bits 0, 1, 3, 4, 6, 7, 8, 9, 12, 14, 15 — Vulkan's bits 2, 5, 10 and 11 (the two atomics and the two blits) are all absent. command/cmdblitimage.zig:22 for the docstring.

**Done in 1.126**, in 26 lines of code and 153 of tests. The two bits are
set as v3dv sets them - BLIT_SRC beside SAMPLED_IMAGE in optimal tiling,
BLIT_DST beside COLOR_ATTACHMENT in either (`image_format_plane_features`,
v3dv_formats.c:169-182) - with R8_UNORM a destination as well, as both of
Mesa's drivers have it, and D16_UNORM blitted both ways into an image of
its own format, the processor blitting for both devices (lavapipe's depth
formats, lvp_formats.c:93-104; `handle_blit_image`, lvp_execute.c:3040-3047).
The whole numbers say neither: the blit carries a colour of 8 bits a
channel. That meets BLIT_SRC for 11 of the 47 formats Vulkan asks it of on
the cores and 10 on the V3D, which keeps no R8G8_UNORM, and BLIT_DST for 4
of the 38 on either. Setting the bits found three faults in the blit, all
fixed: a source texel was read into 4 bytes, so R16G16B16A16_UNORM and the
floats kept in rows overran them and every float read as nothing; a blit
into a depth image wrote 2 bytes it never set; and a compressed image kept
in its blocks but made for the transfers alone lay in rows with no texture
over them, which a copy into it wrote through. What is left, by item:
B4G4R4A4, A1R5G5B5 and the three A8B8G8R8 forms the enum lacks (31); the
sRGB words, A8B8G8R8_UNORM and _SRGB, and A2B10G10R10_UNORM (34);
D32_SFLOAT (35); the 21 integer formats both ways, and BLIT_DST for
R8G8_UNORM and the three float formats (36, where they become attachments
and the blit has to write a format at its own width); and the _snorm
forms, R16_SFLOAT, R16G16_SFLOAT and R32G32_SFLOAT (37).

### 33. Decode the 45 mandatory vertex-attribute formats

*formats / vertex input* &mdash; conformance-blocking, medium

Vulkan mandates VERTEX_BUFFER for 45 formats; facet reports and implements 6. This is the best value in the formats strand: pure CPU work with no hardware in the way, since the vertex stage runs on the cores for both devices. One decode arm per format family — _unorm, _snorm, _uint, _sint, _sfloat at 8/16/32 bits, one to four channels, plus the packed 32-bit words. Note the narrowness is currently asserted by tests, so they have to move with it.

> Verified verbatim: pipeline/_pipeline.zig:219-224 `attributeFormat` returns true for exactly `.r32_sfloat, .r32g32_sfloat, .r32g32b32_sfloat, .r32g32b32a32_sfloat, .r8g8b8a8_unorm, .b8g8r8a8_unorm`; :228-250 `decode` has arms for only those six and silently returns (0,0,0,1) otherwise; creategraphicspipelines.zig:315 refuses the rest. Tests assert the narrowness at tests/draw.zig:3256-3261 and src/disk/c/test/raster/facetprobe.zig:1278.
>
> Again on 08.11.2026, the lines having moved: `attributeFormat` is pipeline/_pipeline.zig:260-265 and `decode` :269-291, the six alike; creategraphicspipelines.zig:410 refuses the rest, with `error_validation_failed` since 1.135 (VUID-VkVertexInputAttributeDescription-format-00623: the six are the formats whose features say VERTEX_BUFFER). The tests that assert it have moved but are still there: draw.zig:3256-3261 is tests/draw.zig:3827-3831 (no format of the texel-buffer grid, most of them among the 45, says VERTEX_BUFFER), and facetprobe.zig:1278 is src/disk/c/test/raster/facetprobe.zig:1416, checked at :1436 ("and none of them a vertex format"); tests/draw.zig:16310 expects R8_UNORM's buffer features to be the two texel bits alone. tests/draw.zig:1419-1420 refuses an attribute of r5g6b5_unorm_pack16, which is not among the 45 and stays refused.

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

Vulkan mandates COLOR_ATTACHMENT for 38 formats and COLOR_ATTACHMENT_BLEND for 14. facet provides 3 of each, hard-coded in a two-line `drawable()` and enforced by CreateImage. The missing 35 are the integer attachments, the three sRGB words, the half- and single-float forms, a2b10g10r10 both ways, a8b8g8r8_*_pack32 and a1r5g5b5. This is the largest piece in the formats strand: the tile buffer keeps 8 bits a channel of BGRA, dithered to 565 on store, so each new format needs a tile representation, a store, a load, a clear and — for the 11 blendable ones — a blend unit at that width. On the V3D the render-target config packets must name the format too. The same fix closes the colour-input-attachment gap, since an input attachment must be of a format rowFormat knows, which is the same three. Since 1.126 (item 32) BLIT_DST rides on this as well, set beside COLOR_ATTACHMENT as v3dv sets it: each format made an attachment here becomes a blit's destination, so the blit, which carries 8 bits a channel, has to write it at its own width - a float as a float, a whole number as it is. Since 1.127 (item 31) the A8B8G8R8 whole numbers are their R8G8B8A8 forms under another name, so each follows its form here with one name more; A1R5G5B5 is unpacked as it is copied in, so its attachment needs a tile format of its own and a store that packs it.

> Verified verbatim: src/disk/libs/facet/surface/_surface.zig:78-80 `return format == .b8g8r8a8_unorm or format == .r8g8b8a8_unorm or format == .r5g6b5_unorm_pack16;`; image/_image.zig:498 `if (info.usage & facet.IMAGE_USAGE_COLOR_ATTACHMENT != 0 and !drawable(info.format)) return null;`; driver/_format.zig:45-58 are the only arms setting `attachment`; render/createrenderpass.zig:238 for the input-attachment half.

Found independently by: formats, conformance-path, semantics (3 strands).

### 37. Sample the _snorm and half-float formats, and fill the storage-image gaps

*formats / sampled and storage images* &mdash; conformance-blocking, medium

R8_SNORM, R8G8_SNORM and R8G8B8A8_SNORM are mandatory for SAMPLED_IMAGE, BLIT_SRC and FILTER_LINEAR (and since 1.127 A8B8G8R8_SNORM_PACK32, the same bytes, follows R8G8B8A8_SNORM with one name more); R16_SFLOAT and R16G16_SFLOAT for those plus COLOR_ATTACHMENT, BLIT_DST and BLEND. All five exist in the enum and report texel-buffer features only. The read path exists for texel buffers, so what is missing is texture.Format entries and the sample/filter path — and for _snorm a signed -1..1 channel the tile's 8-bit unsigned colour cannot hold, so the wide-channel machinery has to take signed channels. Separately 16 formats must report STORAGE_IMAGE and the cores miss two: R8G8B8A8_SNORM and R32G32_SFLOAT, the latter sharing an arm with r32g32b32_sfloat that reports 0 in both tilings, so no image of two floats exists on either device although four of the other float formats do.

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

*image views* &mdash; conformance-blocking, medium &mdash; **done in 1.120**, the V3D's half unchecked on the board

CreateImageView refuses any ComponentMapping that is not the identity, with error_format_not_supported. VkComponentMapping is core 1.0 with no feature or limit gating it: a view of a mandatory sampled format must accept any of r/g/b/a/zero/one in any slot. The structure exists and is read only to be rejected. Lifting it means the swizzle reaching the sampling path — baked into the view's texture.Texture for the cores, or written into the TMU's own swizzle words for the V3D, which tiling.zig already uses for R8. This was found by one strand and is in neither document.

> Verified verbatim: image/createimageview.zig:107 `if (info.format != image.given_format or !identity(info.components)) return .error_format_not_supported;` and :160-166 `fn identity` (each channel from itself or .identity). sdk/libs/facet/facet.zig:1086 ComponentMapping, :1166 `components: ComponentMapping = .{}`.

**Done in 1.120, on both devices**, in 120 lines of code and 195 of
tests. Ported from lavapipe, which hands the view's four to the sampler
view (`lvp_create_samplerview`, lvp_image.c:379-382), llvmpipe, which
swizzles each sample once it is made (`apply_sampler_swizzle`,
lp_bld_sample_soa.c:3954-3956), and v3dv, which composes the format's
swizzle with the view's into the TMU's state (v3dv_image.c:828-831,
`pack_texture_shader_state_helper`, v3dvx_image.c:72-75).

- **The cores.** A texture carries the view's swizzle (`texture.Swizzle`,
  `Texture.swizzle`), and every read of a texel applies it: a sample by a
  sampler or by a fixed form's sampling, `colorAt`, `partsAt` and
  `wholesAt`. It is applied to each texel as it is read rather than once
  a sample is made, which comes to the same, a channel taken or a
  constant being mixed alike before a filter or after it; the border and
  what a comparison gave are swizzled as well, as Vulkan replaces a texel
  and compares a depth before it swizzles (20.2.5). A comparison reads
  the texel as it lies.
- **The fixed form's fast path** reads texels as they lie, so a view that
  swizzles goes through the run-time sampler, as llvmpipe's linear path
  takes no swizzle (`lp_linear_check_sampler`,
  lp_linear_sampler.c:918-924).
- **A depth or a stencil.** A swizzle of one takes 0 from the green and
  the blue and 1 from the alpha, lavapipe's `conv_depth_swiz`
  (lvp_image.c:337-347, 389-396). lavapipe applies that to every view of
  one; here a view that swizzles nothing kept the grey a depth reads as
  until 1.121, which was item 89.
- **The V3D.** The TMU's four swizzle fields take the view's over the
  format's own (tiling.zig `writeTextureState`), host-tested to the bit
  and drawn by the board probe, which has not run yet.
- **Where Vulkan has none.** A framebuffer refuses a view that swizzles
  (VUID-VkFramebufferCreateInfo-pAttachments-00884). A storage image and
  an input attachment may not be one
  (VUID-VkWriteDescriptorSet-descriptorType-00336); UpdateDescriptorSets
  has no result to refuse with, so that is left to the program, as Vulkan
  leaves it. A value that is none of the seven is still
  `error_format_not_supported`, until item 81 settles what an invalid
  value answers.

### 42. Accept VK_IMAGE_CREATE_MUTABLE_FORMAT and a compatible view format

*images / image views* &mdash; conformance-blocking, medium &mdash; **the cores' half done in 1.131**; the V3D's is v3dv's view format in the texture state and the render target, about 20 lines and a board check

facet defines two image create flags — CUBE_COMPATIBLE (1<<4, Vulkan's value) and its own PACKED_TEXELS (1<<31) — and reads only those two. Vulkan's MUTABLE_FORMAT (1<<3) is therefore accepted and silently ignored, and CreateImageView then refuses any view whose format differs from the image's. With the flag set a Vulkan application may legally take a view of any format of the same texel block size, which is how a UNORM image is written as UINT or read as sRGB. Needs the view carrying its own texture.Format over the image's memory, which texelsOver and levelsFrom are already parameterised enough to do for same-size formats, plus validating the flag.

> Verified: `grep -n 'IMAGE_CREATE_' sdk/libs/facet/facet.zig` -> only :976 CUBE_COMPATIBLE and :988 PACKED_TEXELS; `grep -n 'info.flags' src/disk/libs/facet/image/_image.zig` -> :345 and :353 only; the view refusal is the same line as item 41.

**The cores' half done in 1.131**, in 108 lines of code, the generated
interface aside, and 236 of tests, as lavapipe has it: a view's format
is handed to the sampler view, the image view and the surface over the
image's one resource (`lvp_CreateImageView`, lvp_image.c:483;
`lvp_create_samplerview`, :350-365; `add_img_view_surface`,
lvp_execute.c:1520-1525), which works because llvmpipe lays every
format's texels out as they lie (`llvmpipe_texture_layout`,
lp_texture.c:154-223). The SDK has IMAGE_CREATE_MUTABLE_FORMAT at
Vulkan's `1 << 3`, a view keeps its own format beside its image's, and
CreateImageView takes one Vulkan has compatible with the image's - of
the same bytes a texel for a colour format, the other of its pair for a
block format, none for depth or stencil (58.1.8) - where the image was
made with the flag. A framebuffer and the cores' surfaces take the
view's format (`create_img_surface`, lvp_execute.c:1506-1518), and so
does what a later subpass reads of it as an input attachment.

Two things the item got wrong. A view could not simply carry its own
texture.Format over the image's memory: on the cores an 8888 texel is
spread over 64 bits (`texture.Format.rgba8888`), which no view of
R32_UINT can read. So an image made with the flag keeps its texels as
they lie first - B8G8R8A8's as the word PACKED_TEXELS keeps, R8G8B8A8's
as the four bytes of 1.110's `rgba8` - and its copies move them as they
are; every other format the cores keep as it lies already. Only then is
a view a texture format put over the same texels (`_image.readAs`). And
"validating the flag" is a walk over the compatible formats: CreateImage
and the format query refuse the flag where a format compatible with the
image's, whose features take the image's usage, could not be read
where the texels lie (`_image.shapeFor`). The refusal then comes where
Vulkan lets it come, rather than at a CreateImageView that Vulkan
expects to succeed. R5G6B5 to sample is the case that showed it:
B4G4R4A4 is of its size, sampled, and kept unpacked on every device. A
B8G8R8A8 image both drawn into and written through is refused for the
same reason, R8G8B8A8's rows having no texture to be written through,
and a format kept unpacked refuses the flag itself.

Found while doing it: CmdCopyImage copies nothing between two formats of
one size that the cores keep differently, which is the copy a view of
another format is the other way of making (item 90).

The V3D's half is v3dv's: it makes every image MUTABLE, its own meta
paths taking views of compatible formats (v3dv_image.c:518-522), and
`create_image_view` (v3dv_image.c:742-845) takes the view's format for
the texture state (`tex.texture_type`, v3dvx_image.c:77, packed at
v3dv_image.c:837) and for the render target's internal type (:808-826).
Here that is the TMU's texture type and the render target's output read
off the view's format rather than the image's (driver/v3d/_play.zig:502,
:900), and the refusal (`Ops.texture_memory`) lifted where the TMU reads
the view's format, B8G8R8A8 and R8G8B8A8 for each other: about 20 lines
and a board check of its own, a view of B8G8R8A8 of an R8G8B8A8 image
sampled and drawn into. C:test/FacetProbe's check of 1.131 writes
through a view of R32_UINT, which the TMU does not read.

### 43. Accept a subpass with no colour attachment

*render passes* &mdash; **the cores' half done in 1.113, the V3D's in 1.150**

CreateRenderPass refuses color_attachment_count == 0, so a depth-only subpass — the canonical shadow-map pass, and the depth pre-pass as Vulkan writes it — cannot be described at all. Vulkan allows colorAttachmentCount = 0 with a depth/stencil attachment and no colour. Lifting it means the render-pass plan, the tile layout and both drivers' part code tolerating zero colour planes: the cores' tile always carries a colour buffer per part and the V3D's render-target configuration names a colour format. facet has PIPELINE_CREATE_DEPTH_PREPASS as its own answer to the same need, which is why this went unnoticed; it is in neither document.

> Verified verbatim: render/createrenderpass.zig:276 `if (subpass.color_attachment_count == 0 or subpass.color_attachment_count > _render.most_colors) return .error_feature_not_present;`.

**The cores' half done in 1.113.** `CreateRenderPass` takes a subpass of
no colour attachment on a device that says it draws one
(`Capabilities.colorless_subpasses`): a depth attachment alone, or no
attachment at all, as the one part of no colour. Vulkan has no feature to
refuse it under, so the V3D's refusal is a shortfall, as its others are.

The port is lavapipe's and llvmpipe's, and it is short because llvmpipe's
colour handling is a loop over the framebuffer's colour buffers wherever
it touches one. lavapipe gives llvmpipe a framebuffer of
`colorAttachmentCount` buffers, which may be none, sized by the render
area (`handle_begin_rendering`, lvp_execute.c:1974-1980); a tile maps
each buffer there is (`lp_rast_tile_begin`, lp_rast.c:126-131); and the
fragment shader's blend is a loop over them too (`generate_fragment`,
lp_state_fs.c:3618-3622), so the shader runs and its colour goes nowhere.
facet's tiles were already loops of that kind - `Target.colorCount` is 0,
so a tile loads and stores no colour plane - and what had to change was
where code took a first colour attachment for granted: the grid's
alignment to a surface's cache lines (`Grid.over`, which now begins at
the area's left), the display a part hands its tiles on to
(`displayOf`, none), two loops over the colours past the first, which
ran from 1 to 0, the viewport of CmdClearAttachments' quad (to the
render area's far corner), and a batch's blend into plane 0, skipped as
llvmpipe skips it. A fragment function is still given its one colour's
room (`output_count` is 1), so a function written for any subpass runs
in this one; an entry of several colours is refused there, as it is in a
subpass of one.

Two things this item did not say:

- **A framebuffer of no views is a size and nothing else**, so
  `FramebufferCreateInfo.attachments` is optional, as Vulkan's
  `pAttachments` is, and every framebuffer is now held to
  `max_framebuffer_width` and `max_framebuffer_height`
  (VUID-VkFramebufferCreateInfo-width-00886, -height-00888). Before, an
  image smaller than the size was refused, which bounded it; with no
  image, nothing did.
- **A subpass of no attachment at all was drawn at one sample a pixel**
  in 1.113, the count a subpass has where no attachment gives it one.
  Vulkan takes it from the pipeline instead, up to
  `framebufferNoAttachmentsSampleCounts`: item 61's K8 does since 1.114,
  and the limits test's pin is 0.

The pre-pass facet already had, `PIPELINE_CREATE_DEPTH_PREPASS`, is
untouched: it is a pipeline's, inside a subpass of colour. A depth
pre-pass as Vulkan writes it - a subpass of the depth alone, then one of
colour tested against what it left - now runs on the cores through the
depth two subpasses share (1.52), which the first stores and the second
loads.

Found while doing it, and added as items 85 and 86: a pipeline with no
fragment stage, and a colour reference of `ATTACHMENT_UNUSED`. Both are
valid Vulkan 1.0, and both are refused.

**The V3D's half done in 1.150**, with item 85's and item 61's V8, which
share its program. It is v3dv's, and the larger part of it is the
compiler's, which the estimate above left out:

- **The frame.** At 7.1 a frame of no colour still configures one render
  target, flagged unused by a stride of 1, which packs to 0
  (v3dvx_cmd_buffer.c:1189-1197; `cl.unusedRenderTarget`). Its tiles
  load, store, resolve and clear no colour, and where nothing is kept
  either a tile's one store is of nothing, as v3dv always emits one
  (v3dvx_cmd_buffer.c:680-685); the depth and the stencil clear between
  tiles by themselves at 7.1, so no CLEAR_RENDER_TARGETS is emitted
  (:544-551, :687-699). The tile is v3d_choose_tile_size's for the
  depth alone, which at one sample and at four is the size it is for
  one target of 32 bits (`Frame.color`, `frame.chooseTile(0, ...)`).
- **The program.** Mesa's key says which render targets a subpass draws,
  `cbufs`, set for each colour attachment that is not unused
  (v3dv_pipeline.c:2137-2142), and a program with none writes no colour
  to the TLB (nir_to_vir.c:1957). Nor are its early fragment tests
  promoted, which needs a colour written (:2073-2081), so it writes the
  rasterizer's Z through as its one TLB write (:2098-2126).
  `compile.Key.cbufs` carries it, and a compiled pipeline is keyed on its
  subpass (`Pipeline.colorless`). The fixed forms and the clears draw
  with v3dv's noop fragment shader instead (v3dv_pipeline.c:2616-2645):
  a body of nothing compiled with no render target, six instructions,
  pinned as `qpu.no_color_fragment` and held to what the ported back end
  makes of it word for word. A fixed form's program writes a colour the
  frame has not and drops no pixel, so what it leaves - the depth and the
  stencil - is what the noop leaves.
- **A subpass whose every colour is unused is one of none** (item 86),
  and is now refused where `colorless_subpasses` is not. Before this the
  V3D took one and read a colour image its part did not have.
- **The pre-pass as Vulkan writes it** - a subpass of the depth alone, then
  one of colour tested against what it left - runs on the V3D through the
  depth two parts share (1.52), as on the cores, the first part storing it
  and the second loading it. Its depth wants memory behind it: a lazily
  allocated one cannot be kept between parts on either device.

FacetBoth 1.18 draws it on the board against the cores: a shadow map in a
pass of it alone, by the fixed form, a compiled shader and no fragment
stage, sampled by the shadow-map cases' quad (3, 5, 3 and 3 pixels of
230400 apart, as the same maps drawn beside a colour are); and the
pre-pass, of no colour attachment and of an unused one, with a depth
CmdClearAttachments inside it (8 or 9 apart, the edges every case has).

**Found after it, and done in 1.151: a kept depth over part of the frame.**
A pass that stores a depth or a stencil it does not load, over a render
area some tile sticks out of, had that tile store its clear over the
pixels outside the area, which Vulkan has the pass leave alone. FacetBoth
1.19 draws a shadow map, then draws over a part of it again in a pass of
the depth alone that clears: 4230 of 230400 apart on 1.150, a band across
the tiles that straddle the area's lower edge, exactly where they lie. The
port is v3dv's two halves of it. Wherever the area is not tile aligned an
attachment that is stored is loaded first, whatever its load op
(`v3dv_cmd_buffer_check_needs_load`, v3dv_cmd_buffer.c:1557-1564), and
the clear inside the area is drawn, as v3dv clears there with
CmdClearAttachments (`cmd_buffer_emit_subpass_clears`,
v3dv_cmd_buffer.c:1430-1488): in `_play.zig`'s `beginRenderPass`, one
rectangle of the colour, the depth or the stencil, cut to the area. The
question of the tiles is the one a resolve in them asks (1.148), so
`frame.resolvesInTiles` is `frame.tilesInArea`. On 1.151 the case is 3
apart, as the map drawn once is; FacetBoth's 208 other cases are as they
were, and FacetProbe is 888 of 888.

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

*images / render to texture* &mdash; port, about 420 lines: about 90 on the cores, about 62 on the V3D, about 11 for a V3D clear, and about 257 of tests and docs &mdash; **the cores' half done in 1.119**; the V3D's is v3dv's store and load of the UIF layout and its TLB clear, about 73 lines and a board check

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

**The cores' half done in 1.119**, in 58 lines of code, 187 of comments
and 429 of tests, against the 90 of code and the 257 of tests and docs
sized. An image made SAMPLED
together with COLOR_ATTACHMENT or INPUT_ATTACHMENT, of one sample or
four, is kept in rows and sampled where a pass drew it, with no copy
between and no transition. llvmpipe does the same: one layout whatever
the image is bound as (`llvmpipe_texture_layout`, lp_texture.c:154-223),
lavapipe handing every image to it (lvp_image.c:87-89, 104). The
rasteriser draws into the level and the layer its view names
(`init_scene_texture`, lp_scene.c:159-185, which `_play.zig` `surfaceAt`
ports), and the sampler reads the same bytes as a texture of levels and
layers (`_image.rowLevels`, as `lp_jit_texture_from_pipe` does,
lp_jit.c:400-437). R8G8B8A8's bytes were already read in rows, red in the
low byte, since 1.110 (row K6). What was built:

- **The layout.** Every rows image in optimal tiling may have levels now,
  the whole chain, in the arrangement depth's levels have had since 1.63:
  per layer the levels one after another, each level's rows 64-byte
  aligned, as llvmpipe aligns a level's rows to the cache line
  (`row_stride`, lp_texture.c:191-195). llvmpipe lays a level's layers
  together instead (`mip_offsets`, 214-217); Vulkan leaves an optimal
  image's arrangement to the implementation, and facet keeps the one
  its depth images and its copies already know. It also closes a breach that was not on the list: Vulkan has `maxMipLevels`
  be the whole chain for every optimal image whatever its usage, and
  until 1.119 the format query answered 1 for a colour attachment.
  `_image.depthPitch`, `depthLevelBytes` and `depthLevelAt` are
  `levelPitch`, `levelBytes` and `levelAt` for that reason, and the rows
  of a level are `rowsAt`'s for every rows image.
- **What follows the level.** A framebuffer's attachment, a copy, a
  blit, a resolve, a clear and an input attachment's view all reach the
  level and the layer named, through `rowsAt` and `levelSize`, and a
  framebuffer wider than its attachment's level is refused as one wider
  than its image was.
- **The fixed form.** A texture kept in rows has a pitch, and the fixed
  form's path that reads texels in blocks does not take one: it draws
  through the run-time sampler, a texel at a time
  (`shader.texturedOther`).
- **Where it is refused.** On a device whose images lie in a layout of
  its own (`Ops.texture_memory`, the V3D), as the format query says; an
  image written through as well (STORAGE), which is item 48's outside
  edge and not its subject; a transient one; a 3D one, whose slices no
  pass of Vulkan 1.0 draws into; and a linear one, no format here being
  sampled in linear tiling (`linear_tiling_features` hold no
  SAMPLED_IMAGE).

The V3D's half is unchanged by this: the TLB's store and load naming the
UIF layout in their Memory Format and Height in UB fields
(v3dvx_cmd_buffer.c:149-211 and 341-415), and CmdClearColorImage through
the TLB (v3dv_meta_clear.c:70-193), about 73 lines and a board check.
Until then the V3D answers `error_format_not_supported` to the format
query and to CreateImage alike, which the probe checks on both devices.

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
reference operand, there being no Dref operation in this IR until 1.143's `sample_compared` (item 58), so a sampler
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

**A module's own discard is done in 1.139** (item 59, "Then discards"): the flags, SETMSF and the Z write are Mesa's, ported. The fixed form `texture_cutout` is what remains here.

### 54. V3D: a QPU program that reads the bound sampler for every form, with unnormalized coordinates and anisotropy **[critical path]**

*V3D compiler and TMU* &mdash; conformance-blocking, large

After: The SPIR-V -> QPU compiler; its 1.77-1.79 sampler path is the beachhead

samplers is false on the V3D, so CreateGraphicsPipelines refuses every fixed form needing one — texture_sampled, texture_shadow, texture_array_sampled, texture_cube_sampled, texture_3d_sampled, texture_cube_array_sampled — and the cores draw them. VK_DESCRIPTOR_TYPE_SAMPLER and COMBINED_IMAGE_SAMPLER are mandatory in Vulkan 1.0 and all sampler state bar anisotropy is unconditional, so for the V3D as a Vulkan device this is a conformance block, not a capability. Two halves: the compiler emitting the TMU sequence for each form — the generated path already does this for OpImageSampleImplicitLod on a 2D combined image sampler, so the shape exists — and a software path for what the TMU cannot express, since writeSamplerState takes only a filter and a wrap. unnormalized_coordinates is false only because samplers is, and Vulkan has no feature bit for it, so it rides in free; sampler_anisotropy is optional in 1.0, so that part is a clean capability (and until it lands, item 2 is the honest report).

**Since 1.83 this item also owns the last `shader.missing` in the library.** Item 52 was the pair of this one: a sampler `texture.samplingOf` could not collapse was drawn by neither device and the pixel was painted magenta on purpose, so that the two could not quietly draw different plausible pictures. The cores carry such a sampler whole now and draw it, so the magenta is this device's alone. `samplingBy` returning null is the only place left in facet where a *sampler* makes a draw paint a wrong colour on purpose; the other `shader.missing` paths, on both devices, are for a texture or a sampler that is not bound where the shader reads, which is a resource that is not there rather than one the device cannot express, and Vulkan calls reading it invalid usage.

**Then the sampler state, in 1.140: the generated path's half of this item.** The "software path for what the TMU cannot express" was not needed. The TMU's state holds every field Vulkan 1.0's sampler has; writeSamplerState wrote two of them.

- `tiling.writeSamplerState` packs each field of v3dv's pack_sampler_state (v3dvx_device.c:203-271): the mag, min and mip filters, the S, T and R wraps from Vulkan's five (:36-42), the three borders, the fixed bias, the minimum and maximum LOD held to 0-15 (:259-260), the compare function, and anisotropy with its maximum (:231-239).
- `tiling.parameter1` sets the unnormalized bit, as v3dv does as it writes the uniform (v3dv_uniforms.c:213-218).
- `tiling.samplerOf` maps facet's own sampler onto that state. The generated path's `sampledBy` takes it in place of `texture.samplingOf`, which is now the cores' fast path alone.

So the magenta of the paragraph above is gone, except for a sampler that compares. The TMU compares only where the program writes TMUDREF (v3d_tex.c:155-157), and the walk takes no Dref sample; that is item 58's.

The V3D now reports these as v3dv does (v3dv_device.c:349, 1153, 1158-1159):

- `sampler_anisotropy` and `unnormalized_coordinates` true;
- `max_sampler_anisotropy` 16, `max_sampler_lod_bias` 14 and `mipmap_precision_bits` 8;
- one sampler a stage, beside its one sampled image.

That left the other half: no fixed form that reads a sampler ran on the V3D, so the cores drew those forms.

On the board:

- V3DTest FILTER draws each of the five wraps, nearest and bilinear, against Vulkan's formulas worked out on the CPU: no pixel wrong.
- FacetBoth 1.12's seven sampler cases are levels mixed and shifted, levels held, a wrap of its own an axis, a white border, mirrored once, four samples along an axis, and texels. Against the cores they are 0 to 16 pixels of 230,400 apart.
- The anisotropic case agrees within five steps a channel, not two. Vulkan leaves anisotropic filtering's samples to the implementation; the case says where the two differ.

**Then the fixed forms, in 1.141: the other half, bar two.** No program was needed for them. The sampler reaches the TMU through configuration parameter 1, which v3dv writes as the draw is recorded (v3dv_uniforms.c:187-221, write_tmu_p1); the program only writes the coordinates. So a form that samples through the bound sampler runs the program of the form it is without one, and `textureUniforms` gives the TMU the sampler through `tiling.samplerOf`.

- `texture_sampled`, `texture_array_sampled`, `texture_cube_sampled` and `texture_3d_sampled` run on the V3D (`samplesHere`, driver/v3d/driver.zig).
- A cube is read over its seams, and its wraps say nothing of it, as Vulkan has it and the cores since 1.60. v3dv packs the wraps as they are (v3dvx_device.c:255-257), and so does this.
- `texture_shadow` stayed refused. The TMU compares only where the program writes TMUDREF (v3d_tex.c:155-157): item 58, done for this form in 1.142.
- `texture_cube_array_sampled` stays refused, with `texture_cube_array`: neither has a program for the fourth coordinate.

`samplers` stays false, because those two are still drawn on the cores.

On the board, FacetBoth 1.13 has 13 cases more:

- 1.140's seven samplers are drawn again, through the fixed sampled form. They are as far from the cores as the generated path is: 0 to 16 pixels of 230,400.
- Six more go through a sampler to an array, a cube and a 3D texture. They are 0 to 14 pixels apart; the cube across an edge has 14, as many as without a sampler.
- All 185 cases stay within one pixel in a thousand.

Running the forms on the V3D brought three faults out, put right in 1.141 too:

- A 3D texture's levels lie as v3d_setup_slices lays them out (v3dv_image.c:112-282): each level its slices one after another. The TMU finds a level from level 0's place, and each slice had been a texture of its own, so past level 0 it read a slice or more from where the level lay.
- A clear of a V3D texture finds the level where the V3D keeps it (`Ops.texture_level`) and writes the image format's texel, not the cores' 64-bit one.
- A clear of a 3D image clears every slice of the level, on both devices: Vulkan's range names its one array layer.

FacetProbe 1.45 checks all three and passes its 864 checks, 362 of them on the V3D.

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

sampled_depth is false on the V3D: an image of d16_unorm with IMAGE_USAGE_SAMPLED is refused there, so a shadow map must be copied rather than sampled where it lies. Vulkan mandates SAMPLED_IMAGE and BLIT_SRC for D16_UNORM on every physical device (BLIT_SRC is met since 1.126, the processor blitting the depth rows; SAMPLED_IMAGE is what is left), so this is the conformance failure that item 3's honest gating exposes. Needs a depth format in the TMU's table, or the library handing the TMU a 16-bit single-channel texture that reads as depth, plus the compare-against-reference path, which is sampler state the TMU cannot express today.

> Verified: driver/v3d/driver.zig:178 `.sampled_depth = false` with the comment "Its texture unit keeps a texture its own way, and knows no depth format"; enforcement at driver/_format.zig:73 and image/_image.zig:433 `if (!physical.features.sampled_depth) return null;`.

Found independently by: features, formats.

**Done for the fixed forms, 1.142: the V3D samples a D16_UNORM where the pass stored it, and compares.** This is v3dv's way, ported:

- **The texture.** D16_UNORM is `DEPTH_COMP16` with `SWIZ_X001`, unfiltered (v3dvx_formats.c:204). `tiling.Texels.d16` is texture type 21 and reads (D, 0, 0, 1), which is what the cores' depth view gives since 1.121.
- **The image.** A sampled depth lies as a texture does on the V3D (`_image.deviceLaid`). Its memory is `Ops.texture_memory`'s, and the pass stores the depth into the level's own tiling, as v3dv stores into a slice's (v3dvx_cmd_buffer.c:396-406). The store and load packets take the memory format and the UIF height (`cl.store`, `cl.load`; v3dv_image.c:247-248). The library's clears, copies and texel reads go through the driver's places for it, as for a texture since 1.141.
- **The comparison.** The program writes the reference to TMUDREF, waddr 38, before TMUS (v3d_tex.c:155-157), and the sampler's function goes into the configuration parameter as v3dv packs it (v3dvx_device.c:262-264): NEVER where compare is off. That is `qpu.shadow_code`, and `texture_shadow` runs on the V3D since 1.142.
- **What stays out.** No FILTER_LINEAR for a depth (`Capabilities.filtered_depth`; v3dv_formats.c:273-276), and no sampled `d16_unorm_s8_uint` (`Capabilities.sampled_stencil`). v3dv's only format of both is D24_UNORM_S8_UINT (v3dvx_formats.c:209), which is not here.

**The generated program, 1.143: a SPIR-V shader that compares, on both devices.** No layer took a Dref sample before, so it goes in at each:

- **The format.** `spirv.Op` has OpImageSampleDrefImplicitLod and ExplicitLod (89, 90). `facet_profile` takes the implicit one, and `look` reads its fifth operand, the reference, before the optional image operands.
- **The IR.** `ir.Build.sampleCompared(set, binding, coordinate, reference)` is a `sample_compared`: one float, what passed. Its words declare the image with Depth 1, as glslc declares a `sampler2DShadow`. `tests/spirv_reference.zig`'s `min_shadow` is written as assembly, assembled with spirv-as and accepted by spirv-val, and the emitter matches it word for word.
- **The cores.** The generated function takes the bound sampler whole through `texture.sampleBy` with the reference, the call the fixed form `texture_shadow` makes (`shader.texturedBy`), and reads what passed out of the red. A host test holds the two together bit for bit over nearest `less`, nearest `greater` and a mixed `less_or_equal`.
- **The V3D.** `compile.zig` reads the sample into a `sample_compared` step, and takes a coordinate wider than two floats. glslc writes `texture(sampler2DShadow, vec3(uv, ref))` with the reference as the coordinate's third float, extracted again as the Dref, which SPIR-V allows.
  - `to_vir.zig`'s `emitTex` writes the comparator to TMUDREF after T and before S, as v3d_tex.c's handle_tex_src does with nir_tex_src_comparator (v3d_tex.c:155-157), so the TMU takes three writes (get_required_tex_tmu_writes, :222).
  - What passed is the low half of the first word the TMU hands back. Mesa's vir_opt_alu folds the unpacking fmov into the instruction that reads it.
  - `compile.Code.sampler.compared` tells the draw, which hands the TMU the bound sampler's comparison and the depth's texture state (`_play.sampledBy`).
  - `glslc_shadow` in `glslc_reference.zig`, glslc's own output, compiles to facet's program word for word.

Item 58 is done for what facet takes: a 2D depth, compared at an implicit level of detail. OpImageSampleDrefExplicitLod is named but not taken, since the IR has no explicit lod for any sample. On the board, FacetBoth 1.15's three shadow-map cases through the generated shader are as far from the cores as through the fixed form (3, 3 and 5 pixels of 230,400, at the same triangle edges), and its other 188 cases are as they were.

On the board: FacetProbe 1.46 passes its 888 checks, 386 of them on the V3D (362 at 1.141). The V3D runs the whole of the sampled-depth part now: 16 bits compared, layers and levels. FacetBoth 1.14's three shadow-map cases are 3, 3 and 5 pixels of 230,400 from the cores, all at triangle edges, as its plain depth cases are.

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

**Begun, 08.11.2026, from the bottom: the QPU's instructions.** `driver/v3d/qpu/` holds Mesa's src/broadcom/qpu of 7.1, which VIR, the scheduler and the register allocator are ported onto next:

- `instr.zig`: an instruction unpacked, and what it reads, writes and waits on (qpu_instr.h, qpu_instr.c);
- `pack.zig`: an instruction to its 64 bits and back - the signal map, the small immediates, the condition field, both opcode tables, each side and a branch (qpu_pack.c's v3d71 paths);
- `disasm.zig`: an instruction as Mesa prints it (qpu_disasm.c).

That is 2,084 lines from Mesa's 4,847, the 4.x paths left out. `qpu/tests.zig` holds them to Mesa's own rows (tests/qpu_disasm.c: its seven of 7.1, and its seven branches, whose code asks no version), to every word the hand-written programs in `qpu.zig` run on the board, and to every opcode with every raddr of either side, every signal and every condition code, each read back and packed again. A script compared the tables with Mesa's row by row, and they are its own: 144 add rows, 33 mul rows, 28 signals, and the operand counts of 107 and 22 operations.

Two places where Mesa reads back what it does not pack again are kept as Mesa has them. The ten one-operand float operations, ffloor to ftoc, read an `abs` unpack that their pack refuses. And fxcd and fycd are three raddr_b values each, read as one operation and packed as the first. Nothing in facet.library calls this yet: compile.zig still emits `qpu.zig`'s words.

**Then the validator**, Mesa's qpu_validate.c, which holds a finished program to the hardware's instruction restrictions: `driver/v3d/compiler/validate.zig`, its 7.1 paths (the r4 of an SFU result and the rules of 4.2 alone are left out). It answers the first rule broken and where, in Mesa's own words, where Mesa aborts. It checks finished programs before Mesa's scheduler is ported to make them. Every hand-written program in `qpu.zig` keeps every rule, and so does every program `compile.zig`'s tests compile, since `sound` now runs it over each.

**Then VIR**, the instructions Mesa's compiler builds a program of before registers and scheduling: what of v3d_compiler.h and vir.c is VIR itself, vir_to_qpu.c and vir_dump.c, in `driver/v3d/compiler/` - `vir.zig` (the registers, instructions, blocks, cursors, uniforms and the emitters Mesa's VIR_* macros make), `to_qpu.zig` (the instructions given the registers their temporaries have, a move of a register to itself dropped, then packed and held to the restrictions) and `dump.zig` (VIR printed as Mesa prints it), on `list.zig`, Mesa's util/list.h, which its cursors stand on. 1,577 lines; the 4.x paths, the NIR's part of vir.c and the passes are left out, and the dump's pressure columns came with the liveness, below. Mesa's ralloc and calloc are one allocator the compile is made with, and a failed allocation is an error rather than a crash. Mesa's own behaviour is kept where it surprises: try_opt_ldunif's walk back starts before the instruction just emitted, so a uniform loaded twice in a row is loaded twice; a small immediate of -16 to -1 prints as a float, the dump comparing its packed index; list_move_to puts an element after the link it names. `compiler/tests.zig` holds the dump to Mesa's printed form, and a short program, given registers by hand, to the disassembler's text of each instruction, packed and kept to every rule. Until qpu_schedule.c is ported, v3d_vir_to_qpu is two halves with nothing scheduled between them, and nothing in facet.library calls any of it.

**Then the liveness**, the first and the last instruction each temporary is live at, over the whole program, which the register allocator builds its interference from: vir_live_variables.c, in `driver/v3d/compiler/live.zig`, 401 lines with its comments, and the dump's pressure columns in `dump.zig`, which vir_dump prints once the ranges hold. Each block alone gives what it defines whole before reading it (def), what it reads before defining it (use), and what it defines even in part (defout); two fixed points then give what is live into and out of each block, from the successors back, and which blocks a definition reaches, a partial one too, from the predecessors on; and a range grows to a block's start where the temporary is live into it and defined before it, and to its end where it is live out of it and defined in it - so that a temporary written first in part, or under a condition, is not live back to the program's start. A half written is a definition where both halves are written in the block, or where no instruction reads the other half; a read under the very condition, and the very flags, that a conditional write in the block was made under is no use of it; and on 7.1 a move out of rf1 to rf3, the payload, makes its temporary live from the start. After a spill the ranges are found again with the blocks' liveness kept, as vir_update_live_intervals_after_spill does, and spill_base's range is drawn over every path back from a block that reads it, a loop's back edge among them. `compiler/tests.zig` holds it to ranges traced by hand from Mesa's code: a straight line, a loop, a conditional first write (which without the definitions reaching each block would be live from ip 0), a read under matching and under other flags, the three cases of a half written, a payload move, and a spill over a loop. Zig prints a signed number given a width with a plus sign of its own, which C's `%4d` does not, so the dump prints the pressure as C does. Nothing in facet.library calls it.

**Then the register allocator**, each temporary given a register of the file: Mesa's graph colouring, util/register_allocate.c, in `driver/v3d/compiler/ra.zig`, 712 lines with its comments and 268 of tests, and the V3D compiler's use of it, vir_register_allocate.c's 7.1 paths, in `allocate.zig`, 1004 lines, with what they share - struct v3d_compiler's register sets, the nodes' information, the stage, and the compile strategy's threads and TMU spill budget - in `vir.zig`. The colouring is Mesa's: simplify pushes every node it can, and where none can be, the one of least q total, the highest numbered on a tie, optimistically; select pops them through the V3D's callback, which goes round the file from rf4 and keeps rf0 for the last, except for an ldunif's or ldunifa's temporary, tried there first unless it is in a fragment program within four instructions of the last ldvary, whose rf0 writes would keep the two from pairing (or of the start, where there is none), and which starts the temporaries of a fragment program's last six instructions, and of the spill setup where the stage has a payload, at rf4 too. Only contiguous classes are ported, which are all the V3D makes, so the conflict lists, the round-robin start, override_p and the graph's serialization are left out; the graph's scratch arrays are zeroed when it grows, where reralloc leaves them. 7.1 has no accumulators, so the 4.x paths go: its classes of any register and of the file's are the same registers, 64 at one and two threads and 32 at four; rf0 is a node of its own, which a temporary live across an instruction that writes rf0 without naming it interferes with, and so do one live from the last ldvary to an explicit read of rf0, an ldvary's destination and spill_base; and a move out of rf1 to rf3 gives its temporary that register. Where the colouring fails, a batch of victims is spilled before the next try - 16 where the pressure is more than 32 over the registers, otherwise one more for every four over - and the graph brought up to date after the batch: a uniform is loaded again where it is read; a value the hardware gives again (fxcd, fycd, xcd, ycd, iid, eidx, tidx, sampid) is asked for again; and anything else, as the strategy allows, is stored to the TMU after each write and read back before each read, over a thread switch each, at an address from a spill base worked out once at the program's start. Inside a TMU sequence a store waits for the sequence's end and a fill goes before its start; a conditional write is stored under its condition, and a packed one filled first and stored whole. C leaves open the order a call's arguments are worked out in, and with it the order of the spill setup's instructions; here they come in the order they are written in. Like Mesa, the setup leaves the ldunif reuse on, which looked like a bug and is not: the reuse looks back only among the setup's own instructions, and none of them loads the constant 2 it asks for. `ra.zig` holds the colouring to Mesa's own tests of the q values (register_allocate_test.cpp's thumb, non-intersecting and aligned classes) and to colourings traced by hand: a triangle on three registers and on two, the spill choice, a forced register, a callback, a reset, a graph grown. `compiler/tests.zig` holds the rest to Mesa's code: the register sets, the registers a fragment program, a vertex program and a payload move are given, traced by hand; and one program each for a uniform reloaded, a value asked for again, a TMU spill with its setup, a TMU sequence's postponed store and early fill, a conditional and a packed write, a batch of two victims, and an allocation that fails - each allocation held to ranges found again from the start, two temporaries live together never in one register. Nothing in facet.library calls it.

**Then the scheduler**, which puts the instructions, their registers given, in the order they run in, two operations to an instruction where they pair: Mesa's qpu_schedule.c, its 7.1 paths, in `driver/v3d/compiler/schedule.zig`, 1,596 lines with its comments and 117 of tests, on `dag.zig`, Mesa's util/dag.c, 197 and 140. Each block's instructions become the nodes of a DAG of what must come before what, found walking the block forward and then back; a read found walking back is an edge of a write after the read, taken out with the read's node, so that the write may go into the same instruction. Each node's delay to the end is found bottom up with Mesa's latencies: 100 cycles from a TMU write to the ldtmu after it, three after an SFU write, two after an SFU operation. Then, a cycle at a time, the head of the highest priority (a TLB access the lowest) and of those the longest delay is chosen, and what fits merged into it: an add or a sub moved to the mul side for it, a mov or an fmov to the add side, one small immediate an instruction, one signal that writes a register, the peripherals one at a time but where 7.x allows two. The hazards are 7.1's: rf0 read or written the cycle after an ldvary, an ldunif in the cycle an ldvary's rf0 write lands, three instructions between a unifa write and an ldunifa, no TLB access before the scoreboard is locked, nothing in a thread switch's delay slots that may not go before it; an SFU result read the cycle after it is counted as a stall. In a fragment program the uniform loads wait while there are ldvarys to come, and a paired ldvary is moved up an instruction, so that the next product pairs with the sum before it. A thread switch is moved back into the instructions before it as far as its two delay slots and their signals allow, the last one followed by a second in a row; a branch, chosen only as the last head, is moved back into its three delay slots, and once every block has its place it is given its offsets in the instructions and in the uniforms, an unconditional one's remaining slots filled from its successor; the program ends with a thread switch of its own and nops for its slots; and the uniforms are renumbered into new arrays, in the order the program reads them. `to_qpu.zig`'s `virToQpu` is now v3d_vir_to_qpu whole: the code generated, scheduled, packed and held to the restrictions. 7.1 has no accumulators and no muxes, so the 4.x paths are left out (the r3 to r5 writes, the mux reads, merging raddr_a and raddr_b, the setmsf rule on branches), and so are the debug dumps, the TMU priorities Mesa has turned off, and the fields nothing reads (the node's latency, the state's time, the scoreboard's last_uniforms_reset_tick); dag_validate answers a node of the cycle where Mesa prints the graph and aborts. Mesa's own behaviour is kept where it surprises: alu_reads_register compares a small immediate's index as if it were a register's; the walk back from the end of a block to its branch starts at the next to last delay slot, so the last is never filled from the successor; and a spill's store counts an ldtmu to come that never does, as vir_register_allocate.c sets it, which only makes pairing a lookup with an ldtmu more careful. Three things are not kept. Where a thread switch's signal goes into an instruction before it, Mesa frees the switch and leaves the compile's last_thrsw pointing at it, of which only whether it is null is read again; here last_thrsw points at the instruction the signal went into. Mesa takes a block's last instruction for the ldvary fixup without asking whether the block has one; here an empty block gets no fixup. And where an allocation fails, which Mesa does not provide for, the instructions not yet back in their block are freed. `compiler/tests.zig` holds it to programs scheduled by hand from Mesa's code: a chain, whose thread end's signal goes into its ldtmu but into neither the add after it nor the tmua write, which reads rf2, which the fragment setup may write in the thread end's slots; independent operations paired, an add moved to the mul side and a mov to the add side; a write paired with the read of its register before it; the last thread switch, moved back two instructions and told by a second; a branch filling a slot from before it and one from its target, past which it then jumps; two ldvarys pipelined; and an SFU result's stall and its cycles - each packed and held to every rule. `schedule.zig` holds the merging and the edges themselves. Nothing in facet.library calls it yet; the SPIR-V walk that emits VIR, nir_to_vir.c's port, comes next.

**Then the SPIR-V walk that emits VIR**, nir_to_vir.c's fragment paths with v3d_tex.c's sample and the compile strategies of vir.c around them: `driver/v3d/compiler/to_vir.zig`, 539 lines with its comments, and `compile.zig`'s `compileVir`, which reads a module as `compile` does and hands its steps to it. Mesa walks NIR; this walks the steps, and what Mesa's NIR passes do for this profile is done in the walk: an op a float, a vector times a scalar the scalar's one float in every product, a constant a uniform a float where it is first read, a component or a construct naming floats as nir_copy_prop leaves them, and a texel's two words read out as four floats right after the sample, an fmov of each half, which is the VIR Mesa makes of a pair of half-floats it reads back from the tile buffer (vir_emit_tlb_color_read). A fragment program starts with Mesa's payload moves (the msf, W out of rf3, the centroid's W out of rf1, Z out of rf2), reads every varying with an ldvary, a product by W and the sum with rf0, and ends with the colour moved out and packed to the tile buffer in two vfpacks, its early fragment tests promoted, so that no Z is written; the specifier is the one the register is preloaded with, so no tlbu. A sample writes T, P0 asking for both words of texture 0, P1 for sampler 0, and S, which retires it with Mesa's ldtmu count, and is flushed when it is first read, with the thread switch and an ldtmu and a move for each word. vir_emit_last_thrsw adds a last thread switch, and where the program has one already, the sample's, adds one all the same, so that a spill cannot come after it; where nothing spilled it is taken out again and the sample's is the last. Strategy 0 is tried, four threads and no spill, then strategy 2, two threads and spills as many as it takes; a spill's uniforms are refused in the stream (`Error.Registers`), as a draw has no memory to spill to, and a program that does not pack or breaks a rule is `Error.Invalid`, the port's fault. `Code` now carries the threads, whether W is read for anything but a centroid varying, and whether the scoreboard is locked at the first thread switch, which a shader record will take from it. Where it is not Mesa's: every varying the draw carries is read, as the vertex record holds them all; interpolateAt's copy of the C coefficient is left out, the profile not having it; the TMU hands back both words whatever is read, as the draw writes P0 for both; the colour is moved out where the body ends, the steps not keeping where its store was; the key is the draws' (render target 0, 16-bit floats, no swap, one sample); and strategies 1, 3 and 4 turn off what is not done here, and 5's fallback scheduler is not ported. What its fixtures compile to is in the next paragraph, the optimizations having changed every program they pin.

**Then the optimizations**, Mesa's vir_optimize and the seven passes it runs until none of them makes progress, their 7.1 paths: `driver/v3d/compiler/opt.zig`, 613 lines with its comments and 271 of tests, which `to_vir.zig` runs where v3d_nir_to_vir does, after the tile buffer writes and before the registers. Copy propagation reads a move's operand in its place, an fmov's unpack with it where the two mean the same, and never a move out of the payload's rf1 to rf3, which are there for W's, the centroid's W's and Z's liveness. Dead code takes out what nothing reads and does nothing besides, an umul24 with its multop; drops a flags write the next one hides; drops the destination of what has to stay for its flags or its place in an ldunifa sequence; and takes out the first or the last ldunifa of one, the first with the address moved on a word. A pass finds what is read before it takes anything out, so a chain goes a link a pass, which the loop is for. Small immediates makes an operand loaded from a constant uniform one where it can be, one an instruction and in a fragment or compute program alone; constant ALU makes an add or a vfpack of constants a uniform of the result; the 16-bit extract reads the low half of a shift right by 16 as the high half of what was shifted; and a setnnmode of the mode the block is in already goes. Redundant flags drops a push the last one made already. Mesa reads the extract's shift count's definition without asking whether there is one; here one with none is passed over. What the plan's fixtures compile to now, each packed and held to every rule: the interpolated colour is nine instructions in 16 registers where the hand-written program is twenty-one, the last thread switch moved up among the ldvarys, which 7.1 lets sit in the first two delay slots of one, and the sums packed where they were made; a colour of its own is two words to the tile buffer, the first a uniform of two half-floats and the second the small immediate 0x3c000000, which is 2^-7 as a float and 0 and 1 as halves; a texture is nine, its lookup started in the delay slots of the thread switch it waits at, which is the last, and its halves packed back for the tile buffer in the thread end's; a texel times the colour reads the texel's halves in its products, as the hand-written fmulLow and fmulHigh do, in 28 registers; a texel added to reads its floats of its own around the switch, Mesa reading the uniform stream in the last section as anywhere else; and nine vectors live at once, which the plan refuses, compile at two threads in 64 registers. Two things a board run had to settle, and the next paragraph's did: Mesa gives 7.1's four threads 32 registers each, where `qpu.registers` keeps the hand-written programs in 16; and Mesa's scheduler writes the tile buffer three instructions after the first switch of the last pair, where the hand-written programs wait four. Nothing in facet.library calls it yet.

**Then the first programs on the board**, what Mesa's back end makes drawn by the V3D: V3DTest's `MESA`, which draws the five pictures its `GENERATED` draws from the same SPIR-V, compiled through `compile.compileThroughMesa` in place of the plan, and checks every pixel against the sums done on the CPU in the same way. The shader record takes what v3dv's pack_shader_state_record takes from the compile (v3dvx_pipeline.c:461-487 and 554-562): four-way threadable only for a program of four threads, the real pixel centre's W where the program reads it, and the wait on the scoreboard at the first thread switch where the compile moved it there. In the Draw Index record this driver uses those are bits 15 and 20 of the first word, where the plain 7.1 record has them at 12 and 17 (v3d_packet.xml, "GL Shader State Record Draw Index"); `cl.Programs` carries the three with the hand-written programs' values as defaults. The compile's memory is an arena over exec's AllocVec for the one compile (`driver/v3d/heap.zig`, 66 lines, the library's first `std.mem.Allocator`), the register sets made in it, where Mesa makes them once for the device (v3d_compiler_init, vir.c:535). On the CM5, after the plan's five: the interpolated colour, nine instructions, 866,813 pixels and none wrong; the colour of its own, six instructions and two uniforms of halves, none wrong; the colour dimmed by a fifth varying, fourteen instructions in 23 registers, none wrong; the texture, nine instructions, its 65,536 texels each where it was put; the texel times the colour, sixteen instructions in 28 registers, 4,096 pixels and none wrong. A frame took 710 to 734 microseconds, the plan's 712 to 756. So the board has Mesa's 32 registers at four threads, two programs past 16 drawing at four threads with every pixel right, and the tile buffer written three instructions after the first switch of the last pair is right as well. The host tests pin the dimmed colour's and the colour of its own's words too, and hold `compileThroughMesa` to `compileVir`'s words with every block of the arena given back. The library did not call it yet; the next paragraph's step made it.

**Then the library compiles through it**, facet.library 1.137: `driver.zig`'s `compiled`, which makes a pipeline's own fragment shader where the module ships its SPIR-V, calls `compile.compileThroughMesa` where it called the plan, and the pipeline's `Shader` keeps the three things the record says of the program, which `_play.zig`'s `sendVertices` hands to `cl.shaderRecord`; a program written by hand passes none and has the defaults. What Mesa's back end refuses is refused as before, `error_feature_not_present`, and drawn by the cores; running out of memory in the arena is `error_out_of_host_memory`. The plan stays: V3DTest's `GENERATED` and the host tests hold it to the hand-written programs. To see it through the library, C:test/FacetBoth 1.9 has five cases called "shipped", the five pictures V3DTest draws, from a module that ships the words beside the functions: the cores run each graph's function and the V3D compiles the words, and the two pictures are compared. With 1.136, the plan's code: the colour, the colour of its own and the dimmed colour each 8 pixels of 230,400 apart, all at the triangles' edges where the V3D leaves the backdrop, and the texture and the texel times the colour none and 1 at worst. With 1.137, Mesa's code: the same, pixel for pixel in the counts. All 160 cases of FacetBoth stay within one in a thousand, and C:test/FacetProbe's 332 checks on the V3D pass. One thing the cases found that is not the compiler's: the V3D samples through no sampler whose `max_lod` holds it to fewer levels than the texture has (`texture.samplingOf`), and SamplerCreateInfo's default `max_lod` is 0, Vulkan's, so a program that leaves it there gets the missing colour on the V3D where the cores sample. FacetBoth asks for `texture.lod_unclamped`, as FacetProbe does. That is item 54's, whose magenta it is: the sampler state's own levels of detail, which v3dv packs from minLod and maxLod (v3dvx_device.c:259-260, pack_sampler_state), beside the view's base and maximum level in the texture state (v3dvx_image.c:68-70), are what lifts this one of its refusals.

**Then the push constants**, facet.library 1.138. Before this, the V3D's profile left out the PushConstant storage class, so a fragment shader that reads push constants was drawn by the cores. v3dv lowers each load_push_constant to a uniform load (lower_load_push_constant, v3dv_pipeline.c:571). ntq_emit_load_uniform (nir_to_vir.c:2880) and try_emit_uniform (nir_to_vir.c:2847) then make each float `vir_uniform(c, QUNIFORM_UNIFORM, offset / 4 + i)`. v3dv_write_uniforms fills that word from the command buffer's push constants (v3dv_uniforms.c:513). The port does the same in three places:

- `compile.zig` reads the block: one struct decorated `Block`, each member a float or a vector of them at an offset that is a multiple of four inside `shader.MAX_PUSH_CONSTANTS_SIZE`. A member is read through an access chain with a constant member index and, where wanted, a constant float index. Each load becomes a step `.push` whose `at` is the word.
- `compiler/to_vir.zig` emits `.uniform` for each float of the step.
- `compileVir` maps the stream's `.uniform` words to `Word.push`, and `_play.zig` writes each from `Resources.push` as the draw is played.

The walk refuses an index computed in the body (Mesa would fall back to a TMU read, `ntq_emit_tmu_general`), a block it cannot hold, and any other struct. The plan has no hand-written program for it and answers `Error.Storage`. `ir.Build.push` writes such a shader, and its function on the cores reads the same floats. The host tests pin the program for a pushed colour. glslc's tinted module (`glslc_reference.glslc_tinted`) and facet's emitter's (`spirv_reference.min_push`) compile to the same 13 instructions and the same stream. On the CM5, FacetBoth 1.10's two push cases are 10 and 8 pixels of 230,400 apart from the cores, all at the triangles' edges like the other shipped colour cases. All 162 cases stay within one in a thousand, and FacetProbe passes 829 of 829.

**Then discards**, facet.library 1.139, which is item 53's for a module's own shader. The walk takes a conditional discard in the shape SPIR-V gives it: a float compared with another (`OpFOrdLessThan`, `OpFOrdGreaterThan`), `OpSelectionMerge`, then `OpBranchConditional` to a block of `OpKill` alone and to the merge block the body goes on in. That is the shape nir_opt_peephole_select with `discard_ok` (nir_to_vir.c:2293) makes a terminate_if of. The port emits it as Mesa does:

- The comparison: FCMP into the flags, pushing N (ntq_emit_comparison, nir_to_vir.c:1173). A greater-than is a less-than with its operands swapped, as spirv_to_nir reads it. The bool made of it (ntq_emit_cond_to_bool) is dead and goes in vir_optimize.
- SETMSF where the flags hold (nir_intrinsic_terminate_if, nir_to_vir.c:3833).
- sched_flags (nir_to_vir.c:4854) moves the flags instruction up.
- With a discard there are no early fragment tests, so the program writes the rasterizer's Z to the tile buffer before the colour (emit_frag_end, nir_to_vir.c:2083-2136).
- The record's "Fragment shader does Z writes" and "Turn off early-z test", bits 12 and 13 (v3dvx_pipeline.c:454-459).

`OpKill` anywhere else is still `Error.Discards`, and so is every discard in the plan. glslc's own cutout (`glslc -O`; without `-O` it keeps the texel in a variable of the function's own, which the walk reads since 1.155) compiles to the same 13 instructions as facet's emitter's. On the CM5, FacetBoth 1.11's cutouts are 0 pixels apart from the cores. A cutout drawn in front of a far triangle found a bug in the cores, not the V3D: a generated function's depth was tested and written before it ran, because only a fixed form said it dropped pixels. The pipeline now reads that from the shipped SPIR-V (`Pipeline.discards`), as llvmpipe reads `info.fs.uses_discard`. That case went from 20,395 pixels apart to 3. What is left of item 53 is the fixed form `texture_cutout`, whose QPU program is written by hand and still refused (`discarding_fragment_forms` false).


**Then the float arithmetic**, facet.library 1.152. Before this the V3D's profile took a sum and a product and nothing else, so a fragment shader that subtracted, divided, took a dot or called GLSL.std.450 was drawn by the cores, and the library's own `spirv.facet_opcodes` refused any call into an imported set at CreateShaderModule: almost every real shader. The port is what spirv_to_nir and v3dv's NIR options make of each, then ntq_emit_alu:

- **The front end.** `ext_inst` is in `facet_opcodes`, and a call is the device's to refuse at the pipeline. The walk lowers GLSL.std.450 as vtn_glsl450.c does (:131-180 for one NIR op, :245-277 for the built ones), then as v3dv asks NIR to lower (v3dv_pipeline.c:177-207): fdiv to a product by frcp, fsqrt to frcp of frsq, fpow to fexp2 of flog2 times b, ffract to a less its floor, flrp by nir_lower_flrp with no FMA (strict for a constant weight, its 1 - t folded; a + t(b - a) otherwise, nir_lower_flrp.c:495-551), Exp and Log by M_LOG2E, FClamp to fmin of fmax, Normalize to the vector times frsq of its dot (the two frcp one fcanonicalize, which folds away), Length and Distance frcp of frsq of the dot. A dot is lower_fdot's: the products, the last float first, each summed onto those before (nir_lower_alu_width.c:161-173, v3dv having no FMA). fadd(a, fneg(b)) is fsub, as the late algebraic pass makes it (nir_opt_algebraic.py:3868).
- **The back end.** `compiler/to_vir.zig` emits ntq_emit_alu's operations (nir_to_vir.c:1412-1463, 1756-1801): FSUB, FMIN, FMAX, the XOR of the sign bit for a negation, FMOV with the ABS unpack, FFLOOR, FCEIL, FTRUNC, FROUND, and the SFU's RECIP, RSQRT, EXP and LOG, which at 7.1 are add operations written to any register.
- **What glslc writes around it.** At `-O` a varying's one float is read through an access chain into the Input variable and a vector's through OpVectorShuffle; both are names now, as Mesa's swizzles and its one-component load_input are.
- **The emitter.** `ir.Build` writes the same - `neg`, `div`, `dot`, `vector`, `constantOf`, and the calls - into the words and into the cores' function, which computes each as the set's specification says.

Left out, and refused by name: the trigonometry (ntq_fsincos), Step and SmoothStep, FSign, Cross, the integer functions, the packing and the interpolation (Sin, Cos, Tan, Step, SmoothStep and FSign are done in 1.153, below).

glslc's `-O` module of a shader that uses most of the family (`glslc_reference.glslc_arith`, 315 words) and facet's emitter's of the same shader compile to the same 37 instructions, word for word, and the host tests hold each operation to where Mesa puts it. On the CM5, FacetBoth 1.20's two cases are 9 and 21 pixels of 230,400 apart from the cores: the first at the triangle's edge, as the shipped colour on the same triangle is 8; the second also where its roundings and Fract jump as a varying crosses a whole number. The other 209 cases are unchanged, and FacetProbe is 888 of 888.

**Then the floats chosen by a comparison**, facet.library 1.153, and with them the rest of GLSL.std.450's float functions. glslc writes a ternary of plain values as OpSelect after a comparison, and every real shader has one; before this the V3D's walk read < and > for a discard alone.

- **The comparisons.** Every one NIR has of SPIR-V's floats (vtn_alu.c:369-381): FOrdEqual feq, FUnordNotEqual fneu (GLSL's !=, which a NaN passes), FOrdGreaterThanEqual fge and FOrdLessThanEqual fge swapped, beside flt and flt swapped. `to_vir.zig` emits them as ntq_emit_comparison does (nir_to_vir.c:1173-1232): FCMP pushing Z for feq and the same inverted for fneu, FCMP b, a pushing C for fge, FCMP a, b pushing N for flt. OpSelect of one float is b32csel (:1740-1745): the flags as they are where they still hold the bool, SEL. FOrdNotEqual and the other unordered ones are bools of two comparisons in NIR (vtn_alu.c:930-1010), and stay refused.
- **The functions.** Sin and Cos are ntq_fsincos (nir_to_vir.c:990-1003), the angle times 1/pi, a half more for the cosine, the SFU's SIN of what is left after FROUND, and the sign bit turned by FTOIN's whole number shifted into it; Tan is fsin over fcos, the division lowered (nir_ftan). FSign is ntq_fsign's three conditional moves (:1005-1016). Step is 1.0 less slt (vtn_glsl450.c:222-243), slt a SEL of 1.0 and 0.0 (nir_to_vir.c:1710-1723). SmoothStep is nir_smoothstep (nir_builtin_builder.c:139-152), its 3 - 2t a product and a sum as ffma_weak is split for a device of no FMA (nir_opt_algebraic.py:424).
- **fsat.** fmin(fmax(x, 0.0), 1.0) is fsat, as the algebraic pass makes it (nir_opt_algebraic.py:1095; `lower_fsat` is false at 7.1, v3dv_pipeline.c:225): one FMOV with the SAT unpack (nir_to_vir.c:1865-1882). 1.152's FClamp to 0.0 and 1.0 was FMAX then FMIN, which is not what Mesa makes.
- **Constant folding.** An operation of constants alone is the constant it makes, as nir_opt_constant_folding does in v3d's optimization loop (nir_to_vir.c:2281), each computed in floats as nir_opcodes.py has it. SmoothStep's constant edges are the common case: its division is one product by 1 / (e1 - e0). The SFU's functions are left to the device: NIR folds them with the host's libm, to no bit the walk could promise.
- **The emitter.** `ir.Build` has `equal`, `notEqual`, `lessEqual`, `greaterEqual`, `select`, `sin`, `cos`, `tan`, `sign`, `step` and `smoothStep`, in the words and in the cores' function.

glslc's `-O` module of a shader that uses each of them (`glslc_reference.glslc_chosen`, 318 words, one block) and facet's emitter's of the same shader (290 words, spirv-val clean) compile to the same words, and the host tests hold each operation to where Mesa puts it: four of ntq_fsincos, six FCMPs each read by the SEL after it, two SAT unpacks, one RECIP. On the CM5, FacetBoth 1.21's new case is 16 pixels of 230,400 apart from the cores, the first at the triangle's edge, the rest where a comparison turns over or Step jumps; the other 211 cases are unchanged, the shipped float arithmetic with its fsat still 9, and FacetProbe is 888 of 888.

Left out still, and refused by name: the inverse and hyperbolic trigonometry, Cross, the integer functions, the packing and the interpolation; and branches, which glslc writes for a ternary whose arms do more than name a value (nir_opt_peephole_select's work).

**Then the selections**, facet.library 1.154. glslc writes an `if` and `else`, and a ternary whose arms do more than name a value, as a selection: OpSelectionMerge, OpBranchConditional to one arm block or two, each ending in an OpBranch to the merge block, and OpPhi there. Mesa does not branch for most of them: v3d's optimization loop runs nir_opt_peephole_select with a limit of 24 and `expensive_alu_ok` (nir_to_vir.c:2274-2279), which moves both arms' instructions in front of the selection and makes each phi a bcsel (nir_opt_peephole_select.c:508-605).

- **The walk** reads a selection the same way: the arms' steps one after the other, then at the merge a `select` of each float a phi chooses, as nir_lower_phis_to_scalar leaves one bcsel a float; a float both ways bring alike is that float, as nir_opt_remove_phis leaves it. Either label may be the merge block itself, and the way in from there is then the selection's own block. OpCompositeInsert, which glslc writes for `c.r = ...`, is a vector with one float replaced (vtn_composite_insert, spirv_to_nir.c:4612-4650). The conditional discard is the same shape with a true arm of OpKill alone, on the same path.
- **Where Mesa keeps the branch, it is refused** (until 1.171, which compiles it to one), `Error.Branches`: an arm that samples or stores (block_check_for_allowed_instrs takes neither, :59-326), a selection inside an arm (until 1.156), and arms of more than 24 ALU operations as that function counts them (:246-310): a move, a negation, an absolute value or an fsat nothing, a product only summed nothing. Mesa counts before nir_opt_algebraic has lowered the arms; the walk counts its steps after lowering, as many or more, so an arm near the limit may be refused (since 1.171, kept a branch) that Mesa flattens, and never the other way about.
- **The emitter.** `ir.Build` has `ifHolds`, `otherwise`, `endIf` and `merged`, held at comptime to SPIR-V's dominance: a value made in an arm is read in that arm, or past the selection through a `merged` of it; a varying read past the branch is loaded before it. The cores run both arms and choose, as the V3D does.

Not ported: the algebraic rules that act on a bcsel once it exists, such as hoisting a product both arms share (`bcsel(a, b * c, b * d)` to `b * bcsel(a, c, d)`, nir_opt_algebraic.py:3475-3505); they save instructions, and a shader is the same without them.

glslc's `-O` module of an `if` and `else` and a ternary of Pow and Exp2 (`glslc_reference.glslc_branch`, 360 words) and facet's emitter's of the same shader (259 words, spirv-val clean) compile to the same words, both arms' work in each, four selects, and two FCMPs, the flags still holding each comparison at its selects. On the CM5, FacetBoth 1.22's case is 8 pixels of 230,400 apart from the cores, the triangle's edge alone, as the shipped colour on the same triangle is; the other 212 cases are unchanged, and FacetProbe is 888 of 888.

**Then the variables**, facet.library 1.155. glslc without `-O` keeps every GLSL local in an OpVariable of the Function class, stores into it and loads it back, through an access chain where it names one float of a vector (`c.r = ...`); so does every toolchain that does not run spirv-opt's mem2reg. v3d's optimization loop runs nir_lower_vars_to_ssa first (nir_to_vir.c:2240), and the variables are values.

- **The walk** keeps, for each float of each variable, the float it holds. A store replaces them, all of them or the one an access chain at a constant index names, which is nir_vector_insert into what it held (rename_variables, nir_lower_vars_to_ssa.c:716-733); a load answers them (:633-689), the stored step itself where it holds that step whole, else a vector of its floats. An initializer is a store at the top of the function.
- **At a flattened selection** each arm starts from what the variables held before the branch, and the merge chooses between what the two ways in leave them: the phi nir_lower_vars_to_ssa puts there, a phi a float after nir_lower_phis_to_scalar, a `select` each after nir_opt_peephole_select. A float both ways bring is that float; where one way brings nothing, a variable stored in one arm and never before, it is the other's, as nir_opt_remove_phis takes a phi with an undef (nir_opt_remove_phis.c:105-175). A store into a variable is no store the pass keeps a branch for; one into the colour out still is.
- **A float read before anything was stored into it** is 0, nir_lower_undef_to_zero's (nir_to_vir.c:2353).
- **Refused, `Error.Storage`**: a variable of the function's own that is a struct, an array or a bool.

glslc's `-O0` modules of the `if` and `else` (`glslc_branch_unoptimized`, 454 words) and of the cutout (`glslc_cutout_unoptimized`, 217 words) compile to the programs of their `-O` modules, word for word, the uniforms too. On the CM5, FacetBoth 1.23's case of the `-O0` module on the V3D against the selections' function on the cores is 8 pixels of 230,400 apart, the triangle's edge alone, as the `-O` module's case is; the other 213 cases are unchanged, and FacetProbe is 888 of 888.

**Then the nesting**, facet.library 1.156. An `else if` is a selection in the false arm of another; glslc writes it so at `-O` and without. nir_opt_peephole_select walks the blocks in order (nir_opt_peephole_select_impl, :607-619) and meets the inner selection's merge block before the outer one's, so the inner is flattened first and the outer's arm is one block by the time the outer is looked at.

- **The walk** keeps a stack of selections, `most_nesting` deep, and reads the inner one as it reads any. The outer arm goes on in the inner merge block, which is the block it ends in and the one a phi at the outer merge names. The outer arms are counted against the limit with the inner one's work and selects in them, as Mesa counts them.
- **Refused**: the shape nir_opt_collapse_if takes before flattening anything (:412-506), a selection of no false arm that is all of the true arm of another of none, made one selection on the iand of the two conditions. That is a bool computed, which is not ported yet; the shape is refused wherever it is, also where Mesa would find a phi it cannot drop and flatten the two after all. A discard in a nested arm is terminate_if of the iand (rewrite_instr, :351-410), `Error.Discards`.
- **The variables' selects at a merge** are in the order Mesa's phis are: nir_phi_builder_finish puts each phi before the block's first (nir_phi_builder.c:272-297), so the variables come in the reverse of the order they were first used in (register_variable_uses, nir_lower_vars_to_ssa.c:501-550), each one's floats in order. 1.155 took them in the order they were declared.
- **The emitter.** `ir.Build.ifHolds` may be said in an arm: what an arm puts down reads what the arms it is nested in made, and a `merged` takes either arm's value or one from where the selection is.

Not ported, as with 1.154's hoisting: the rules that act on a bcsel of bcsels, one of the same condition in an arm, or two of one condition sharing a value (nir_opt_algebraic.py:979-984). None applies to the shaders here, whose nested selects are on conditions of their own.

glslc's nested selections at `-O` (`glslc_nested`, 387 words), the same without `-O` (497 words), and facet's emitter's (309 words, spirv-val clean) compile to the same words: four comparisons and eight selects. On the CM5, FacetBoth 1.24's case of it is 8 pixels of 230,400 apart, the triangle's edge alone, as the other selections' cases are; the other 214 cases are unchanged, and FacetProbe is 888 of 888.

**Then the bools**, facet.library 1.157. glslc writes `a && b` and `a || b` as a selection on `a` whose arm computes `b`, merged by a phi of bools, and `!a` as OpLogicalNot; `!(w < 0.75)` at `-O` is OpFUnordGreaterThanEqual.

- **Bools of bools.** OpLogicalAnd, OpLogicalOr and OpLogicalNot are iand, ior and inot (vtn_alu.c:316-320), a step of their own that to_vir lowers to AND, OR and NOT of the comparisons' bools (ntq_emit_alu, nir_to_vir.c:1683-1694). A select, a branch and a discard take one as they take a comparison (ntq_emit_bool_to_cond, :1262). The unordered comparisons but `==` and `!=` are the inot of the opposite ordered one (vtn_alu.c:953-985).
- **A phi of bools** is a select of bools, as nir_opt_peephole_select makes it, and nir_opt_algebraic's rules on bools follow in a pass over the steps in order until none changes: inot(inot a) is a (nir_opt_algebraic.py:1736); the inot of an feq or fneu read once is the other (:747-748); iand(a, a) and ior(a, a) are a (:1724, :1728); a select on inot(a) is on a with its arms swapped (:978); bcsel(a, a, b) is ior(a, b) and bcsel(a, b, a) is iand(a, b) (:986, :988). So the phi of an `&&` comes to the iand of its two comparisons and the phi of an `||` to their ior, with no select of bools left.
- **The emitter.** `ir.Build` has `both`, `either` and `not`. The cores compute them as GLSL does: a `not` of an ordered comparison holds for a NaN, where the opposite ordered comparison fails. A select, a discard and a selection take them as they take a comparison, and none of them takes a selection's own operations any more.

Not ported: the inot of an flt or fge made the opposite, which wants both floats proven numbers (:745-746); the bcsels made an fmin or fmax (:974-977) and those of bcsels (:979-984); comparisons sharing a float made one of an fmin or fmax (:1157-1190); De Morgan's (:1796-1797). Bool constants, OpLogicalEqual and OpLogicalNotEqual, OpFUnordEqual and OpFOrdNotEqual are refused as before, and so is nir_opt_collapse_if's shape, which wants the iand made before either selection is flattened.

glslc's `&&` and `||` at `-O` (`glslc_logic`, 286 words), the same without `-O` (335 words), and facet's emitter's (196 words, spirv-val clean) compile to the same words: one iand, one ior and one inot of four comparisons, two selects. A shader of each rule on bools compiles to the words of the one written without them. On the CM5, FacetBoth 1.25's case of it is 9 pixels of 230,400 apart, the triangle's edge alone, the first at the pixel every selection case's is; the other 215 cases are unchanged, and FacetProbe is 888 of 888.

**Then Mesa's order**, facet.library 1.158. 1.157 ran the rules over the steps first to last. nir_algebraic_impl pops the last instruction first (nir_search.c:880-906), so a select on a `not` is turned before the `not` is looked at: a select on `not(equal(y, h))` is one on the feq with its arms swapped, not on an fneu. And v3d's loop runs nir_opt_dce and nir_opt_cse before each nir_opt_algebraic (v3d_optimize_nir, nir_to_vir.c:2234-2300); neither was here.

- **The program's order.** The steps are kept in order as a NIR block keeps its instructions. A rule's new steps go where Mesa's builder puts them: before the one rewritten, or after its operand for an inot (nir_replace_instr, :700-718). The array is laid out in that order again at the end. A round is nir_opt_dce, nir_opt_cse and one nir_opt_algebraic, last step first, each step rewritten by the first rule in nir_opt_algebraic.py's order, and what reads a rewritten step looked at again after the rest (nir_algebraic_update_automaton, :617-638). The rounds go on until one changes nothing.
- **nir_opt_cse.** A step equal to an earlier one is that one; the operands of an add, a mul, an iand, an ior, an feq and an fneu may be either way about.
- **Selects of selects.** On the same condition in an arm (nir_opt_algebraic.py:979-980); on one condition in both arms sharing a value (:981-984); of one float twice (:1936); and read once in an arm of another, sharing the other arm's value, one select on the iand or ior of the two conditions (:2512-2515). The last are what nested selections flattened come to: glslc_nested's green and blue are each one select now, on iand(second, inot(first)) and on ior(first, second), six selects left of eight.

Not ported, as before: the rules that want floats proven numbers or not zero (:745-746, :823-838, :974-977, :1910-1913, :2510), the iands and iors of comparisons and of each other (:1157-1190, :1796-1797 and others), the hoisting (:3483-3496), and every rule of a bool constant.

Two shaders of selects of selects compile to the words of the shaders written as Mesa leaves them, one with two iands, an inot and three selects left. On the CM5, FacetBoth 1.26's cases of them are each 8 pixels of 230,400 apart, the triangle's edge alone; the other 216 cases are unchanged, the nested selections' too, and FacetProbe is 888 of 888.

**Then the collapse**, facet.library 1.159. An `if` of no `else` that is all of another's true arm, but for the block before it, was refused from 1.156 to 1.158, as was a discard nested in an arm. v3d's loop meets it in nir_opt_peephole_select, which tries nir_opt_collapse_if at the inner merge block first (nir_opt_peephole_select.c:531-533) and makes the two one selection on the iand of their conditions (:412-506).

- **Where and whether.** The iand is made where Mesa builds it, after the outer arm's block before the inner selection (:487-490), and read only where the two collapse; nir_opt_dce takes it where they do not. Whether they do is decided at the outer merge block as the loop's two passes meet them, limit 0 and then 24 (nir_to_vir.c:2264-2279): the collapse wants the inner arm a block NIR keeps (:425-427), the outer arm's block before it under the limit (:464-471), and each outer phi of an inner one bringing from the other way what the inner one brings from its own, unless the outer selection asks to be flattened (:444-462). Where it cannot, the inner selection is flattened and the outer after it, as before, and :2512-2515 join the selects.
- **A nested discard** is terminate_if of the iand: nir_opt_peephole_select flattens a discard only in its last pass (`discard_ok`), after the collapse. One the collapse does not take is refused.
- **SelectionControl** is read (vtn_selection_control, vtn_structured_cfg.c:1328-1340): Flatten is no limit, DontFlatten a limit of 0 (get_options_for_if, nir_opt_peephole_select.c:329-345). A selection asking not to be flattened is a branch, refused until 1.171; one asking to be is flattened whatever its arms cost.

Not ported: a collapse of selections nested deeper than two; a shape whose outcome depends on whether nir_opt_cse takes a stored constant's load_const for an earlier one; an outer arm that jumps to the inner merge block. Each is refused.

glslc_collapse compiles to one select on the iand of its two comparisons, glslc_nested_discard to terminate_if of theirs, and the two shapes the collapse leaves alone to the selections flattened from the inside out. On the CM5, FacetBoth 1.27's cases of the collapsed selections and the nested discard are 8 and 6 pixels of 230,400 apart, the triangle's edge alone; the other 218 cases are unchanged, and FacetProbe is 888 of 888.

**Then the uniform buffers**, facet.library 1.160. A fragment shader reads `uniform` blocks now: a block in the Uniform storage class at a set and a binding, its members floats and vectors read through access chains of constant indexes, as glslc writes them. vtn and nir_lower_explicit_io make each member's load a load_ubo of the buffer's slot and a constant offset in v3dv's 32bit_index_offset format (v3dv_pipeline.c:415-425), and v3d reads it through unifa (ntq_emit_load_unifa, nir_to_vir.c:3299-3507).

- **The reads.** QUNIFORM_UBO_ADDR of the slot shifted up by one and the offset is loaded by the ldunif straight into unifa, and each float then by an ldunifa. A later load of the same buffer in the block, up to 12 bytes past where unifa stands, reads on from there with ldunifas that read nothing for the gap (:3398-3415); any other load writes unifa again. The scheduler had the three delay slots between a unifa write and an ldunifa already (qpu_schedule.c:1437-1442).
- **The address.** The stream's word says the set, the binding and the offset, and the draw writes the buffer's address there with its descriptor's offset and a dynamic one's (write_ubo_ssbo_uniforms, v3dv_uniforms.c:235-350). The bytes go out of the CPU's caches first. A buffer the program reads and the draw has not bound draws the missing colour.
- **The other passes.** A load_ubo is CSE'd (CAN_REORDER, nir_intrinsics.py:1367) and taken out where nothing reads it. In a selection's arm it keeps the selection a branch, since nothing vtn makes may be speculated (nir_opt_peephole_select.c:132-141), so that shape was refused until 1.171.
- **Dynamic offsets, mended.** Since 1.35 a dynamic offset had eaten into the descriptor's range: a range of 32 shifted by 256 read as not written, however large its buffer. Vulkan moves the window and keeps the range, as v3dv adds the dynamic offset to the address and nothing else. The set now keeps how far each dynamic descriptor may be shifted inside its buffer, the bind checks the offset against it (VUID-vkCmdBindDescriptorSets-pDynamicOffsets-01971), and one shifted past its buffer reads as not written (`shader.SHIFTED_OUT`). FacetBoth's first run of the case found it.

Not ported: nir_opt_load_store_vectorize (nir_to_vir.c:2315-2338) and v3d_nir_sort_constant_ubo_loads (vir.c:1551-1772), which change how often unifa is written and not what is read; arrays, matrices and structs in a block; an index computed in the body, which wants the TMU; storage buffers (read since 1.164, below).

glslc_uniform_buffer compiles to one unifa write and eight ldunifas, one of them over the gap from 20 to 24; glslc_uniform_buffers, two buffers read backwards, to three unifa writes and thirteen ldunifas. On the CM5, FacetBoth 1.28's case of the uniform buffers, one of them dynamic and bound twice at two offsets, is 10 pixels of 230,400 apart, the triangle's edge alone; the other 220 cases are unchanged, and FacetProbe 1.47 is 890 of 890, 387 of them on the V3D.

**Then the arrays and matrices**, facet.library 1.161. A block holds arrays, structs of offsets of their own and column-major matrices, read through access chains of constant indexes, and a fragment shader multiplies with matrices.

- **Offsets.** An access chain comes to the constant nir_lower_explicit_io's arithmetic folds to: a member adds its Offset, an element its ArrayStride times the index, a matrix's column its MatrixStride, a float four bytes (vtn_pointer_dereference, vtn_variables.c). A member with no layout, a stride of no whole word and RowMajor are refused.
- **Matrices.** A whole matrix is loaded column by column (_vtn_variable_load_store, vtn_variables.c:763-780) and held as its columns. Transpose, the three products and a matrix times a scalar are vtn_handle_matrix_alu's (vtn_alu.c:182-237), the outer product :817-823. A product is matrix_multiply's sum, the last column first, each ffma_weak before it made fadd(fmul) as the V3D has no ffma (nir_opt_algebraic.py:424); a transpose remembers what it transposed (spirv_to_nir.c:4486-4510). vtn's matrix FNegate, FAdd and FSub are left out: SPIR-V gives them no matrices, and spirv-opt makes glslc's sums vector arithmetic.

Not ported: an index computed in the body, matrices and arrays carried by a store, a phi or a select, constant matrices (since 1.162, below).

glslc_uniform_nested reads an array, a struct and a vector at six offsets with four unifa writes; glslc_uniform_matrix is one unifa write and nine fmuls and fadds for a mat3 times a vector and its shift; glslc_uniform_matrices takes the rest. On the CM5, FacetBoth 1.29's three cases are 8 pixels of 230,400 apart each, the triangle's edge alone, over a block whose values keep every channel between 0.03 and 0.97; the other 221 cases are unchanged, and FacetProbe is 890 of 890.

**Then constant matrices**, facet.library 1.162. A `const mat3` compiles: each column a load_const of its own, as vtn_const_ssa_value makes it (spirv_to_nir.c:544-552), made steps where the matrix is first read. nir_opt_algebraic's rules for times 1, times 0 and plus 0 (nir_opt_algebraic.py:236-237, 282-283, 292), which Mesa applies float by float after scalarizing, are not ported, so a matrix of 0s and 1s costs more instructions than Mesa's for the same values. glslc_constant_matrix is twelve floats in the stream, nine fmuls and six fadds for the product; on the CM5, FacetBoth 1.30's case of it is 8 pixels of 230,400 apart, the edge alone, the other 224 cases unchanged and FacetProbe 890 of 890.

**Then storage buffers, read**, facet.library 1.164. A fragment or vertex shader reads a `readonly buffer` now. SPIR-V 1.0 puts one in the Uniform class with its block decorated BufferBlock, its last member perhaps a runtime array; the runtime array is taken as the last member of a storage buffer's block alone, read at any constant index, and NonWritable is taken on the variable and its members. nir_lower_explicit_io makes each read a load_ssbo in the format of a load_ubo (v3dv_pipeline.c:418-420).

- **Not the TMU.** Nothing in the profile writes a buffer, so nir_opt_access makes every load ACCESS_NON_WRITEABLE and CAN_REORDER (nir_opt_access.c:225-228, 250-293), and v3d reads such a load at a uniform offset through unifa as it reads a uniform buffer (ntq_emit_load_unifa, nir_to_vir.c:3338-3343). The TMU's general lookup (ntq_emit_tmu_general, :502-725) is for a computed offset or a buffer the program writes, and neither is in the profile yet.
- **The reads.** QUNIFORM_SSBO_OFFSET is the slot itself, not shifted, and the offset is ADDed into unifa from a constant of the stream, or the address MOVed there at offset 0; the ldunif is not made to write unifa itself as a load_ubo's is (:3383-3390, 3416-3446). unifa is read on from where it stands only for the same kind of buffer (`current_unifa_is_ubo`, :3403). vir_uniform takes the result of an ldunif of the same word again where one is among the 20 instructions before (try_opt_ldunif, vir.c:2811), so a second unifa write costs no second address.
- **The address.** The stream's word is the set, the binding and how far into the buffer the program reads, one past its last float. The draw writes the buffer's address and its descriptor's offsets (write_ubo_ssbo_uniforms, v3dv_uniforms.c:235-350), sends its bytes out of the CPU's caches, and draws the missing colour where nothing is bound there or the reads pass the range. A vertex program's buffers are held to the same: where one is not bound the vertex function is called instead.
- **The other passes.** A load_ssbo is CSE'd and taken out where nothing reads it, and keeps a selection's arm a branch, as a load_ubo does (nir_opt_peephole_select.c:132-141).

Not ported: a computed offset; stores and atomics, so vertexPipelineStoresAndAtomics and fragmentStoresAndAtomics stay false; OpArrayLength; the StorageBuffer class of SPIR-V 1.3.

glslc_storage_buffer reads a tint, a scale and values[2] of a runtime array with two unifa writes, the second at 64 past the address, and nine ldunifas, 30 words. On the CM5, FacetBoth 1.32's case of it is 8 pixels of 230,400 apart, the triangle's edge alone, as the uniform buffers' cases are; the other 226 cases are unchanged, and FacetProbe is 890 of 890.

**Then 32-bit integers**, facet.library 1.165. A shader that computes with signed and unsigned integers, scalars and vectors, is compiled by Mesa's back end now. An integer value is words as a float is, and an OpConstant of one is its bits in the pool.

- **The operations.** `.integer` steps are NIR's integer ALU, each word one VIR operation as ntq_emit_alu emits it (nir_to_vir.c:1421-1806): ADD, SUB, MIN, MAX, UMIN, UMAX, SHL, ASR, SHR, AND, OR, XOR and NOT on the add side; NEG; a 32-bit multiply as MULTOP and UMUL24 (vir_UMUL); iabs the MAX of the word and its NEG; and FTOIZ, FTOUZ, ITOF and UTOF, an f2i32 of an fround_even one FTOIN of its source. SPIR-V's ops become NIR's as vtn makes them (vtn_alu.c:290-318, the shifts :1031-1059, the conversions :240-275), and GLSL.std.450's SAbs, SSign, SMin, UMin, SMax, UMax, SClamp and UClamp as vtn_glsl450.c:160-176 and :287-292 do: isign lowered as v3dv has it (nir_opt_algebraic.py:2836), a clamp a max and a min (nir_builder.h:1418-1429). An operation of constants is folded, wrapping.
- **The comparisons.** ieq, ine, ilt, ige, ult and uge, the four NIR has none of read with their operands swapped (vtn_alu.c:388-396), and OpLogicalEqual and OpLogicalNotEqual ieq and ine of bools (:317-318). ntq_emit_comparison makes them an XOR pushing Z, a MIN of the two the other way about pushing C, and a SUB pushing C, inverted for ine, ige and uge (nir_to_vir.c:1173-1232). The inot of one read once is the opposite comparison (nir_opt_algebraic.py:749-754).
- **The other passes.** ineg and iabs cost nothing to nir_opt_peephole_select, as fneg and fabs do (nir_opt_peephole_select.c:247-300). A bool may be a variable of the function's own, which glslc -O0 keeps a comparison in, and a push constant's word read twice is one read, as nir_opt_cse takes load_push_constant and the load_uniform v3dv makes of it (nir_intrinsics.py:1365, :1403; v3dv_pipeline.c:571-580).

Not ported: the divisions and remainders, which v3dv has nir_lower_idiv lower; the integer rules of nir_opt_algebraic but the inot's; an integer varying or attribute, which wants flat interpolation; an integer colour, which wants an integer format of the tile buffer.

glslc_integers takes the colour through three FTOIZs and an FTOUZ and back, and the push constants' integers through two UMULs, the shifts, the bits, the most and least of two each way and six comparisons, 59 words; glslc_integer_compares has its twelve comparisons each with its operands as vtn has them; glslc_integer_nots_O0's nots become ige, uge and ine. On the CM5, FacetBoth 1.33's case of glslc_integers, where an operation computed wrong would move a channel by 4 steps or more, is 8 pixels of 230,400 apart, the triangle's edge alone; the other 227 cases are unchanged, and FacetProbe is 890 of 890.

**Then block reads at offsets computed**, facet.library 1.166. An access chain into a uniform buffer or a storage buffer may index an array, a matrix's columns or a vector's floats with a value the shader computes, where it was refused unless the index was a constant.

- **The offset.** It is nir_lower_explicit_io's: each deref's offset added to its parent's (nir_explicit_io_address_from_deref, nir_lower_explicit_io.c:1288-1302), an element's the index times its stride as nir_amul_imm makes it without amul, a shift of a power of two and a multiply of any other (_nir_mul_imm, nir_builder.h:1160-1182). The sums of constants are folded, and an add of 0 is not made.
- **The rules.** v3d's nir_opt_algebraic then reshapes it, and those of its rules are ported: a product by a power of two a shift (nir_opt_algebraic.py:183, :188, :190), an add of 0 and a product by 0 (:239, :287), a shift or a product of an add of a constant distributed, the product's add read once (:729-731, :736-740), a shift by 0 (:1800), and the constants gathered into one (:2423, :2438). nir_opt_cse takes two constants of the same bits as one, as it takes two load_consts. So `rows[i + 3]` of vec4s is `iadd(ishl(i, 4), 48)`.
- **The read.** Where the offset is the same in every lane, as nir_divergence_analysis finds it (an input differs, and so does whatever reads one; a constant, a push constant and a load at a constant offset do not), ntq_emit_load_unifa writes unifa with the buffer's address plus the offset, a uniform buffer's address at an offset of 0, and reads on with ldunifa; no later load reads on from that address (nir_to_vir.c:3348, :3398-3400, :3441-3444).

Not ported: an offset that differs from lane to lane, which v3d reads through the TMU (ntq_emit_tmu_general, :3315-3317), refused; an index computed into the push constants, which v3dv reads from a buffer of them, refused; the other integer rules of nir_opt_algebraic (:248-249, :597, :732-733, :2413-2435, :3641). A computed offset is the program's to keep within the range bound: Vulkan 1.0 without robustBufferAccess does not check it.

glslc_indexed reads four members of a uniform buffer and four of a storage buffer at indexes of the push constants; its offsets are the shapes Mesa's rules leave, among them `iadd(112, imul(p1, 48))`, which :736 makes only once :729 has left `other + 1` read once. glslc_divergent and glslc_pushed are refused. On the CM5, FacetBoth 1.34's case of block reads at offsets computed, a row of a uniform buffer and a float, two triples' members and a scale of a storage buffer, is 8 pixels of 230,400 apart, the triangle's edge alone; the other 228 cases are unchanged, and FacetProbe is 890 of 890.

**Then block reads at offsets that differ from lane to lane**, facet.library 1.167. Where the offset differs, v3d reads the floats through the TMU's general lookup instead of unifa (ntq_emit_load_unifa, nir_to_vir.c:3315-3317, then ntq_emit_tmu_general, :502-725), and so does the port.

- **The lookup.** The buffer's address is loaded first, a uniform buffer's at an offset of 0; the offset is read, which may flush the TMU, the threads and the output FIFO are checked, and the offset is added to the address into TMUAU with the lookup's configuration as its uniform, `0xffffff00 | 15 << 3 | per-pixel | type`, or into TMUA with none where the configuration is the default, a pixel's 32-bit word (emit_tmu_general_address_write, :438-492). The LDTMUs are owed, and the flush makes them the load's floats.
- **Which lanes.** nir_divergence_analysis's answer is kept for every step (vir.c:2105), and for a fragment program nir_opt_load_skip_helpers's (vir.c:2107-2115): a sample's coordinate wants the helper pixels, for its level of detail is worked out across the quad (nir_opt_load_skip_helpers.c:151-157), and so does a load's offset where the load is not one to skip, which only one that differs is (:98-113). A sample or a load that differs and is read into nothing that wants them skips them (:258-275): the load's lookup is a pixel's, else a quad's (:640-648), and the sample's P1 has its per-pixel mask on (v3d_tex.c:311-321). Every sample at a varying's coordinate drawn into the colour now has it, as Mesa's has.
- **Dead loads.** The steps nir_opt_dce took out are no longer emitted, a varying's excepted: v3d's own dead code elimination keeps a TMU lookup (vir_opt_dead_code.c:207), so a load nothing reads would have cost a lookup that NIR's never made.

Not ported: a load whose offset differs in non-uniform control flow (:456-459, :490-491), there being none in the profile; an index computed into the push constants, still refused.

glslc_divergent is 19 instructions, one TMUAU write of 0xFFFFFFFC and four LDTMUs. glslc_quad's coordinate lookup is a quad's (0xFFFFFF7A), its scale's a pixel's through TMUA, and its sample's P1 has the mask; glslc_steady's sample, at a coordinate the same in every lane, keeps its helper pixels; glslc_dead, at -O0, is the interpolated colour's program word for word. On the CM5, FacetBoth 1.35's case of block reads at offsets that differ from pixel to pixel, a uniform buffer's row and a storage buffer's triple's member at an index the red gives and its scale at one the alpha gives, is 8 pixels of 230,400 apart, the triangle's edge alone; the other 229 cases are unchanged, the textured ones with the mask among them, and FacetProbe is 890 of 890.

**Then storage buffer writes**, facet.library 1.168. A fragment program's store into a storage buffer is a store_ssbo, which v3d writes through the TMU's general lookup (ntq_emit_tmu_general, nir_to_vir.c:502-725), and so does the port.

- **The store.** Each float goes into TMUD (emit_tmu_general_store_writes, :346-392), counted with the address's write before any is emitted, and the address into TMUA or TMUAU. A store's lookup is always a pixel's, so a helper pixel writes nothing (:650-670); a TMUWT is owed instead of LDTMUs, and the program's tmu_dirty_rcl is set (:532-533).
- **Loads beside it.** A load of a buffer the program may write goes through the TMU, not unifa, which would not see the writes (ntq_emit_load_unifa, :3338-3343). Only a load that nir_opt_access makes ACCESS_NON_WRITEABLE still goes through unifa: one of a NonWritable variable or member, or any load where the program writes no buffer. A load at a constant offset that goes through the TMU is a quad's lookup, for a load the same in every lane keeps its helper pixels. Loads that may be written are never merged into one.
- **Early Z.** A program that names a storage buffer no longer has its early fragment tests promoted (info.num_ssbos, :2074). It writes the rasterizer's Z through TLBU. From 1.164 to 1.167 every such program had been promoted.
- **The job.** When any of a job's programs wrote, the caches are cleaned after it, as Linux's CACHE_CLEAN job does (v3d_clean_caches, v3d_gem.c:215-248): TMUWCF, then L2TFLS in clean mode. The memory is HOST_COHERENT, so the storage buffers the job bound are also dropped from the CPU's caches.

Refused: a store in a vertex program, which runs twice, as the coordinate shader too; a store into a uniform buffer, the push constants or a NonWritable member; a store of a matrix. fragmentStoresAndAtomics stays unadvertised until the atomics are ported, since the one feature names both.

glslc_writes is 34 instructions: five TMUD writes, a TMUA and three TMUAU, two TMUWTs and eight LDTMUs. glslc_reads reads its count through unifa and its row through the TMU, and leaves nothing dirty. In glslc_member, a readonly member is read through unifa beside the stores. glslc_vertex_store is refused. On the CM5, FacetBoth 1.36's case of stores is 8 pixels of 230,400 apart, the triangle's edge alone. Its first pass writes a storage buffer's count and the rows the red picks, and its second reads them back. The other 230 cases are unchanged, the storage buffers' among them, now with Z written, and FacetProbe is 890 of 890.

**Then storage buffer atomics and barriers**, facet.library 1.169. A fragment program's integer atomic on a storage buffer's 32-bit word is the ssbo_atomic or ssbo_atomic_swap vtn makes of it (vtn_handle_atomics, spirv_to_nir.c:4288-4480), which v3d sends through the TMU's general lookup as it does a store, and so does the port.

- **The atomic.** Its operation is translate_atomic_op's, and its operands are what fill_common_atomic_sources gives (:3678-3722): an increment is an add of 1, a decrement an add of -1, a subtraction an add of the negation, and a compare-exchange takes its comparator first and its value second. OpAtomicLoad is a load and OpAtomicStore a store (:4372-4396). Every atomic is divergent (nir_divergence_analysis.c:994-1010) and counts as a write of its buffer.
- **On the TMU.** The operation is v3d_general_tmu_op_for_atomic's (nir_to_vir.c:189-208). An add of a constant 1 or -1 becomes the TMU's increment or decrement, which writes no TMUD (v3d_get_op_for_atomic_add, :175-187; :507-519). The operands go into TMUD in order (:400-420), the lookup is a pixel's, a compare-exchange's a pair of words (:650-669), and one LDTMU reads the word the atomic returns.
- **Barriers.** For a storage buffer, UniformMemory is added to the semantics. A release puts a barrier before the atomic and an acquire one after it (vtn_split_barrier_semantics, :2581-2661), and OpMemoryBarrier is a barrier where vtn_emit_memory_barrier makes one (:2847-2862). v3d flushes the TMU at each (nir_to_vir.c:3857-3861). MakeAvailable and MakeVisible need the Vulkan memory model and are refused.

Refused: an atomic in an if-arm, which nir_opt_peephole_select leaves a branch (nir_opt_peephole_select.c:106-236; a branch since 1.171); one on a uniform buffer, the push constants or a NonWritable member; one in a vertex program; one on a float. fragmentStoresAndAtomics stays unadvertised: stores of matrices, arrays and structs are still refused, and a subpass of several colour attachments is replayed per part (item 87), which would repeat its stores.

glslc_atomics is 43 instructions: ten atomics, ten TMUD writes, ten TMUAU, ten LDTMUs and no TMUWT, each configuration its operation's. In glslc_returned, the increment and the decrement write no operand and the compare-exchange writes its comparator before its value. In glslc_ordered, an acquire-release atomic sits between two barriers, and its word is read before the next atomic goes out. Eight mutations of the port each fail the tests. On the CM5, FacetBoth 1.37's case of atomics is 8 pixels of 230,400 apart, the triangle's edge alone. Its first pass changes ten words through every atomic GLSL has, by each pixel, and its second packs them into the colour, beside functions on the cores whose pixels race through real atomics. The words start where a signed minimum or maximum done unsigned, or the other way round, would end elsewhere, and the count is fine enough that a helper pixel's atomics would show. The other 231 cases are unchanged, and FacetProbe is 890 of 890.

**Then fragmentStoresAndAtomics on the V3D**, facet.library 1.170.

- **Matrices stored.** A whole matrix stored into a storage buffer is its columns, each a store of its own at its MatrixStride, as _vtn_variable_load_store walks a matrix for a store as for a load (vtn_variables.c:763-780). A whole array or struct stays refused: the walk holds no value of many kinds.
- **The replay guarded.** A subpass of several colour attachments is drawn a part for each, its commands played again (items 80 and 87), so a program that writes memory would write once for each part, and an atomic would count as many times. The V3D refuses such a pipeline with error_feature_not_present when its program writes. v3dv draws the subpass once, its program writing every render target (item 55), and that lifts the refusal.
- **The feature.** GetPhysicalDeviceFeatures says fragment_stores_and_atomics on the V3D. Its programs store and do atomics through the TMU, a pixel's lookup that a helper pixel and a discarded one take no part in: each discard flushes the TMU before its SETMSF (nir_to_vir.c:3815-3852), and SETMSF orders the TMU writes after it (qpu_schedule.c:407-410). Early Z is off for such programs (1.168), and the caches are cleaned after a job that wrote. The cores compile no SPIR-V, so the feature is false there. vertex_pipeline_stores_and_atomics stays false on both, and no shader writes a storage image (item 39).

glslc_placed stores a mat4 and a std430 mat3x2, the latter's columns 8 bytes apart; a constant 16 in place of the stride fails its test. On the CM5, FacetBoth 1.38 asks each device for a writing program in a subpass of two colours: the V3D refuses it and makes a reading one, and the cores make both. The 232 cases are unchanged, and FacetProbe is 890 of 890.

**Then branches where Mesa keeps them**, facet.library 1.171. A selection whose arm samples, loads from a buffer, stores, does an atomic or waits at a barrier, or whose arms cost more than nir_opt_peephole_select's limit or ask DontFlatten, is compiled to a branch as ntq_emit_if compiles it (nir_to_vir.c:4315-4573), where it was refused.

- **The walk.** compile.zig keeps the selection: its arms laid out true arm first, three marks around them (begin_if, begin_else, end_if), and its phis steps of their own, a float each (nir_lower_phis_to_scalar). A selection kept for its cost has its selects made phis again. Each arm is a region; nir_opt_cse takes an earlier step only where it is in no arm or in the later one's, and a constant or a varying read in an arm or past the merge but made in another arm is made again where it is read, as a load_const of each of two blocks neither dominates stays its own.
- **The blocks.** Where the condition is the same in every channel, ntq_emit_uniform_if (:4355-4452): a jump to the false way's block where any channel the shader runs for has it false (ANYNA or ANYA, msfign P), and one past it at the true arm's end, its delay slots filled from the arm. Where not, ntq_emit_nonuniform_if (:4455-4559): `execute` 0 where the true arm runs and the false way's block index where not, a jump over an arm no channel runs (ALLNA, ALLA) unless the arm is cheap (is_cheap_block, :4325-4352), and ntq_activate_execute_for_block (:4315-4322) where the false way starts. The TMU is flushed at each block's end (ntq_emit_block).
- **Writes under the mask.** In an arm of a non-uniform selection, a write of a phi's register is conditional on `execute` (ntq_store_def), with a MOV first where the value is a uniform's or a signal's, and so is the TMU's general address (ntq_emit_tmu_general); a unifa load there takes only an offset no register gives. Where the last thread switch was in an arm, one more at the top level is the last (vir_emit_last_thrsw).
- **The phis' registers.** nir_convert_from_ssa (nir_from_ssa.c:927-983) as `fromSsa`: a web of each phi, and into it, in the blocks' order, each float of its ways that differs as the phi does and interferes with nothing in it (merge_sets_interfere, :231-332, Boissinot et al.'s test), each float a def of its own as after nir_lower_io_to_scalar and nir_lower_alu_to_scalar. A phi of a selection before is merged with its whole web (merge_merge_sets). A constant is copied, never coalesced. What is not coalesced is copied where its way ends, a way's copies as one parallel copy, a cycle broken through a temporary.

Refused still: a selection in a kept one's arm or a kept one in another's, which Mesa keeps both; more than eight kept in a program; a phi of bools; a store of the colour, or a discard, in a kept arm; a kept selection in a vertex program. Not ported: nir_opt_gcm (nir_to_vir.c:2300-2304) and nir_opt_if's rewrites of a kept selection (opt_if_merge, opt_if_simplification, opt_if_evaluate_condition_use, nir_opt_if.c:1345, :741, :1016), which change the instructions and not what they compute.

glslc_branched, a sample in the true arm and a constant vector in the false, is 38 instructions: the texel moved into the phis' registers under the mask, the constant's four copies in the false way's block past a jump, 0.75 a uniform there and the others small immediates. glslc_stored, a store on a push constant's condition, is 20: one ANYNA jump around an unmasked store and its TMUWT. A varying's float read nowhere past the merge is the phi's own register, and the false way empty; two floats of one varying swapped by a selection are two webs' (a first port took them as one, and the swap test caught it); the same sine in both arms is two sines; 0.3 first read in an arm is loaded again past it; eight selections one after another are one web and their false ways empty, and a ninth, or a branch in a branch, is refused. Of twenty mutations of the port, seventeen fail the tests; the three that pass change only which register a float is copied from. On the CM5, FacetBoth 1.39's two cases of kept branches, one masked and one uniform, are each 8 pixels apart at the triangle's edge, as the other shipped cases are. The other 232 cases are unchanged, and FacetProbe is 890 of 890.

**Then loops, unrolled as Mesa unrolls them**, facet.library 1.172. A loop whose trip count nir_loop_analyze works out is read as nir_opt_loop_unroll's simple_unroll makes it (nir_opt_loop_unroll.c:104-209): its body once for each run, one run after another, and no branch, where it was refused. v3d's compile unrolls (nir_to_vir.c:2344-2349), at v3dv's max_unroll_iterations of 16 (v3dv_pipeline.c:215).

- **The induction variable.** compile.zig's planLoop reads the loop before the walk takes it. The header's phis, and the variables stored into at the loop's top level, which nir_lower_vars_to_ssa makes phis, are the candidates: a constant on the way in, and on the way back an iadd, fadd, imul, fmul, ishl, ishr or ushr of itself and a constant (compute_induction_information, nir_loop_analyze.c:248-332). An isub or fsub is an iadd or fadd of the negation by then (nir_opt_algebraic.py:2401-2402).
- **The test.** The loop's one terminator: a comparison, or an inot of one, of a candidate or its update and a constant made before the loop (get_induction_and_limit_vars, :1050-1077), each SPIR-V comparison the NIR one vtn makes of it, swapped or wrapped in an inot.
- **The trip count.** calculate_iterations' (:929-1048): will_break_on_first_iteration, get_iteration of the span over the step with nir_opcodes.py's integer division, test_iterations' bias of -1 to 1, get_iteration_empirical for a product or a shift, and none for an fmul. A for loop's test at its top is peeled first (opt_loop_peel_initial_break, nir_opt_loop.c:412-502), so the loop tests the update def; a do-while loop is tested at its end. Either way the trip count is the times the loop goes back, and it runs once more.
- **The limits.** check_unrolling_restrictions (nir_opt_loop_unroll.c:898-931): a trip count over 16, or a cost over 16 * 26 by instr_cost (nir_loop_analyze.c:78-167), is refused unless the LoopControl asks Unroll, and a loop of DontUnroll is refused. The walk then reads the loop's blocks again for each run, the header's phis taking their way in first and their way back after.

Refused still: a loop of no trip count the port can work out (to a push constant, by an fmul), a break or a continue in an arm, a second terminator, a loop in a loop, a return in one: what complex_unroll (nir_opt_loop_unroll.c:337-463), or a loop kept (ntq_emit_loop, nir_to_vir.c:4760), would take.

glslc_looped is four sums and no branch, and glslc_looped_plain, its variables form with the test and the update in blocks of their own, is its program to the word. glslc_until, a do-while loop, is three runs, and glslc_stepped, a float from 0 by a quarter, four. A loop never entered is no run, a countdown four, a doubling five. glslc_cheap's 17 runs are unrolled, and 18 are refused unless Unroll asks. DontUnroll, glslc_costly's cost, glslc_bounded, glslc_broken and glslc_loop_in_loop are refused, and calculate_iterations' own `x != 0.9` by 0.2 has no count. Of seven mutations of the port, seven fail the tests. On the CM5, FacetBoth 1.40's three cases of loops, glslc's words on the V3D and the sums written out on the cores, are each 8 pixels apart at the triangle's edge. The other 234 cases are unchanged, and FacetProbe is 890 of 890.

**Then several samples a program**, facet.library 1.173. Mesa's back end takes any number of samples, of one combined image sampler or of several, where a second was refused: each is a TMU lookup of its own (v3d_vir_emit_tex, v3d_tex.c:230), with the two configuration words of its unit.

- **The units.** A unit is a set and binding the program samples, given as v3dv's descriptor_map_add gives the texture map's (v3dv_pipeline.c:516-560): in the order the program first reads each, and a sampler read again keeps the unit it has. to_vir.zig puts the sampler the module declares in P0's and P1's high bits, as v3d_tex.c puts the texture's and the sampler's index (:297-303, :341-348), and compile.zig makes it the unit. `Word.texture` and `Word.sampler` carry the unit, and `Code.sampled` says where each is bound.
- **The draw.** It looks up each unit's texture and sampler and writes their states where the stream names that unit, as write_tmu_p0 and write_tmu_p1 do (v3dv_uniforms.c:139-232). A unit with nothing bound draws the missing colour, as a lone sampler did.
- **The limits.** The V3D says 16 samplers and 16 sampled images a stage, as many as a module may declare (`compile.most_samplers`, and Vulkan's floor; v3dv says 24 and 16), where it said 1. A set's are the library's, since the units are a stage's. That meets the four rows of samplers and sampled images, which tests/vulkan_limits.zig's note on the V3D had not named.

Refused still: a second sample where the plan compiles the program, since its hand-written programs write the TMU once; a sampler that one sample compares through and another does not, since its one state cannot be both.

glslc_two_textures is three lookups: `base` is unit 0, `detail` unit 1, and `base` read again unit 0. Made to read `detail` first, the units swap, and one binding of two sets is two units. glslc_sampled_loop, unrolled, is four lookups of one unit and eight LDTMUs. Of five mutations of the port, five fail the tests; the fifth, a unit told by its binding alone, needed the two sets' test. On the CM5, FacetBoth 1.41's two cases are 0 of 230,400 apart: two textures in two sets, the second the 16-bit one mirrored where the first repeats, and glslc's loop of four samples. The other 237 cases are unchanged, and FacetProbe is 890 of 890.

**Then Mesa's float identities**, facet.library 1.174. A Vulkan 1.0 module has no float controls, so vtn leaves every float operation fast math (vtn_handle_fp_fast_math, vtn_alu.c:472-485), and the walk refuses NoContraction: Mesa's inexact, `nsz` and `nnan` rules hold of every float operation facet reads. The unrolled loops showed what was missing: glslc_looped's first run, of float(i) 0, was still a product by 0 and two sums of it.

- **The rules.** `Order.floatRule`, in nir_opt_algebraic.py's order: an fneg of an fneg (:230); an fadd of a zero (:236-237), and of an fneg and what it negates, a zero (:266-267); an fadd of a value and itself, an fmul by 2.0 (:274); an fmul by a zero, a zero (:277-278), by 1.0 the value (:292), by -1.0 its fneg (:296). An fsub is the fadd of the fneg it is lowered to (:2401), and an fadd of an fneg a rule leaves is the fsub the late rules make (:3868, `has_fsub`). The fcanonicalize a rule leaves goes, as optimize_fcanonicalize takes it out where nothing flushes denormals (:161-163).
- **A float at a time.** Mesa sees each float alone: nir_lower_alu_to_scalar runs before nir_opt_algebraic (v3d_optimize_nir, nir_to_vir.c:2259). A vector some floats of which a rule rewrites and the rest not is a construct of an operation of each float (`Order.split`), so `vec3(shift, 0.0) + v` adds two floats, not three.
- **Not ported.** An fadd of two fmuls sharing a factor (:246), of an fneg and an fadd it cancels into (:271-272), of `a` and an fadd of `a` read once (:275), and the rules of b2f, fsat and fmulz.

glslc_looped is 36 words, from 45: its first run is no instruction. glslc_cheap's first fadd goes, the uniform buffer's program is 20 words and the indexed one's 74, a texel plus (0.1, 0.2, 0.3, 0) three sums, and an alpha times 1.0 the alpha. `Lit`, the plan's test of four floats of its own, adds 0.4 where it added 0. Of 19 mutations of the port, 19 fail the tests. On the CM5, FacetBoth's 239 cases are each as they were at 1.173, and FacetProbe is 890 of 890.

**Then the rest of the fadd rules up to :296, and nir_opt_cse held to every float**, facet.library 1.175.

- **Three more rules.** An fadd of two fmuls sharing a factor is the fmul of it and the fadd of the others (:246), the three commutative operations flipped in the order nir_search tries them (nir_search.c:655-672, the bits as __index_comm_exprs numbers them, nir_algebraic.py:463-480). An fadd of an fneg and an fadd it cancels into is what is left (:271-272). An fadd of `a` and an fadd of `a` read once is the other plus `a` times 2.0 (:275). An fsub is the fadd of the fneg it is lowered to, the inner one too, so (y + x) - x is y and x + (x - y) is x * 2.0 - y.
- **nir_opt_cse.** `equalSteps` held two steps' operands to their first float alone, since 1.158: y * x.x was taken for x * y and for y * x, and so would a vector operation whose operand agreed in its first float only. Every float, and the width, is held to now. None of the suite's programs or FacetBoth's had met it; Factored, the first test of :246, did.

glslc_looped's second run adds v * 0.0625 to a sum of it read once (:275): five fadds and five fmuls, from six and four. Of 15 mutations of the port and the fix, 15 fail the tests. On the CM5, FacetBoth's 239 cases are each as they were at 1.174, and FacetProbe is 890 of 890.

**Then arrays, structs and matrices of the function's own, nir_opt_constant_folding in the loop of passes, and fdot lowered before the rules**, facet.library 1.176.

- **Split variables.** A variable of the function's own that is an array, a struct or a matrix is a variable of each float and vector in it. nir_split_struct_vars splits a struct's members (v3dv_pipeline.c:411), and nir_split_array_vars an array's or a matrix's elements where every index is a constant (nir_to_vir.c:2236; mark_array_deref_used, nir_split_vars.c:502-531; glsl_type_is_array_or_matrix, :999). nir_lower_vars_to_ssa then makes each a value (nir_to_vir.c:2240). An unrolled loop's counter is a constant by then, since nir_opt_loop_unroll runs in the same loop of passes. A chain down to a float, a vector or a float of one is that variable, through as many indexes as the type has. An array of bools is a variable of each.
- **Whole aggregates.** A load or a store of a whole array, struct or matrix is one of each element, as _vtn_variable_load_store makes it (vtn_variables.c:763-781). A constant composite of an array or a struct is a value of each float and vector (vtn_const_ssa_value, spirv_to_nir.c:526-563). So are an OpCompositeConstruct of one (:4744-4756), an OpCompositeExtract from one (:4655-4686), and an OpCompositeInsert into one or into a matrix (:4612-4650). An initializer is stored element by element at the top of the function, as nir_lower_variable_initializers stores it (vk_nir.c:301). glslc does not write one; a module patched to carry two is tested.
- **nir_opt_constant_folding.** It runs after each round of rules (nir_to_vir.c:2281; `Order.fold`), through the floats of a vec and a component. An fsub of constants is a constant, and so is a vec of constants that a rule leaves times one.
- **fdot.** An fdot is its products and sums before the rules, as nir_lower_alu_to_scalar lowers it (v3dv_pipeline.c:404; lower_fdot, nir_lower_alu_width.c:161-173). The last float's product comes first, and no fused multiply-add is made (lower_reduction, :96-127). A rule sees each product: in glslc_local_struct the dot of a member stored (0, 0, 1) and (0, 0, 1) is the constant 1.0, and the fmax of it goes. The `.dot` step is gone, and to_vir's emission of it with it.

Refused still:
- an index the body computes. Mesa makes it an if-else tree for two elements or fewer (nir_lower_indirect_derefs_to_if_else_trees, v3dv_pipeline.c:435) and scratch otherwise (nir_lower_vars_to_scratch, vir.c:2041);
- a load of a whole aggregate that holds a bool;
- more than 32 floats and vectors of the function's own (`most_locals`).

Results:
- glslc_local_array, color times weights[i] summed over a loop of three, is 15 words at -O and at -O0.
- glslc_local_struct is the same operations as glslc -O's values of it.
- glslc_local_taps, an array stored at its counter and an array of structs read through chains of three indexes, is the same words at -O0.
- A matrix stored a column through a chain is the words of glslc -O's OpCompositeInsert.
- glslc_local_palette stores an element in one arm and the whole array in the other: 8 selects and one ior, flattened.
- glslc_stepped has three fmax, from four, since the folding takes a max of two zeros.
- glslc_arith has no dot step.

Of 28 mutations of the port, 25 fail the tests. The three left guard against what glslc's modules never reach: a constant aggregate in a nested selection, and a chain made before a loop and stored through in it. On the CM5, FacetBoth's 239 cases are each as they were at 1.175, and FacetProbe is 890 of 890.

**Then scratch, the pipeline's spill buffer, and nir_opt_copy_prop_vars, nir_opt_dead_write_vars and nir_remove_dead_variables over what is in scratch**, facet.library 1.177.

- **Scratch.** A variable of the function's own that an access chain reaches at an index the body computes, of more than two elements, is in scratch, as nir_lower_vars_to_scratch moves it (vir.c:2041-2044). It is placed where its first such index is found (nir_lower_scratch.c:155-185, :247-258), in the natural layout of four bytes a float (glsl_types.c:3809-3880), and the module is read again with it there (`Scratch`).
- **load_scratch and store_scratch.** Each float of a load or a store is one of its own (v3d_size_align_cb, v3d_nir_lower_load_store_bitsize.c:135-143), at the chain's byte offset (nir_build_deref_offset, nir_deref.c:346-380) times V3D_CHANNELS (v3d_nir_lower_scratch.c:31-43). Each is a general TMU access from spill_base (nir_to_vir.c:578-586), which v3d_setup_spill_base works out at the program's start; the scratch bytes for sixteen lanes are added to the spill size (:4997-5000). A load_scratch is divergent (nir_divergence_analysis.c:989), skips the helper invocations (vir.c:1937-1951), and is no CAN_REORDER for nir_opt_cse (nir_intrinsics.py:1429). It keeps a selection's arm a branch, as a store_scratch does (nir_opt_peephole_select.c:109-129).
- **The copies.** While the variable is still one of derefs, v3d's loop of passes runs nir_opt_copy_prop_vars and nir_opt_dead_write_vars over it (nir_to_vir.c:2249-2250). Each access's deref is a `Path`, compared as nir_compare_deref_paths compares two (nir_deref.c:513-640). An index the body computes counts as the same where nir_opt_cse would make it one SSA value. A load the copies have a value for is that value (nir_opt_copy_prop_vars.c:1124-1229). A store of the value already there is none (:1268-1276). A store takes away the copies it may be of (:1311-1317). Each arm starts from the copies where the selection branched, and its merge keeps none an arm may have stored over (:1531-1566, :966-1001).
- **Dead writes and dead variables.** A store written over in its block, with no load between that may read it, goes (nir_opt_dead_write_vars.c). A kept selection's arms and merge are blocks of their own; a flattened one is in the block around it. A variable left with no load is dead and goes with its stores (nir_remove_dead_variables.c:66-90, :110-170); what is left is placed without it. All three run as the module is read, because whether an arm is kept is decided at its merge, from what the arm still holds.
- **The spill buffer.** A pipeline has one for the most any of its programs needs, four shares for each QPU (pipeline_check_spill_size, v3dv_pipeline.c:1669-1708). A draw gives its address and each thread's share (v3dv_uniforms.c:663-672). These are also the two words a program the register allocator spills reads, which was refused before for want of a buffer.

Refused still:
- two elements or fewer at an index the body computes, which Mesa makes an if-else tree (v3dv_pipeline.c:435-436);
- a bool in scratch;
- scratch in a nested arm.

Results:
- glslc_scratch_table, four vec4s read at a computed index, is 60 words at -O and at -O0: 16 stores and 4 loads.
- glslc_scratch_reread's acc[0] before the store is the initializer's 0.25, no load.
- glslc_scratch_copies keeps 5 of its 7 stores and 2 of its 4 loads.
- glslc_scratch_dead's b is dead, and a is placed at 0.
- glslc_scratch_twice, an index computed twice at -O0, leaves nothing in scratch.
- The disassembly is followed register by register. An address in an arm is spill_base, worked out from the thread's index, plus the index shifted by two and then by four.

Of 37 mutations of the port, 37 fail the tests. On the CM5, FacetBoth's 239 cases are each as they were at 1.176, and its new `shipped scratch` has 18 of 230400 pixels apart. The first of them is at 154,70, where 40 other cases also first differ, the plain `triangles` among them. FacetProbe is 890 of 890.

**Then if-else trees for an index the body computes into two elements or fewer, nir_lower_indirect_derefs_to_if_else_trees for function_temp**, facet.library 1.178.

- **Which accesses.** An access chain into a variable of the function's own is a tree when the arrays its computed indexes index have two elements or fewer between them, the product of their lengths (indirect_array_len, nir_lower_indirect_derefs_to_if_else_trees.c:138-153; v3dv_pipeline.c:432-436). More than two is scratch, as at 1.177.
- **The tree.** Each load and store splits at ilt(index, 1) (emit_indirect_load_store_deref, :35-66), each leaf the element at a constant index (:42-46), and a load's value is the phi of its two arms (:63). A float of a vector is loaded through the tree of the whole vector and extracted; it is stored by loading the vector, inserting the float and storing the vector back (vtn_local_load, vtn_local_store, vtn_variables.c:616-667).
- **The phis.** nir_lower_vars_to_ssa takes the variable in the loop of passes after the trees. nir_phi_builder puts its phis before the block's first instruction (nir_phi_builder.c:272-297), so at a merge they come before those of the variables made SSA earlier (`local_late`).
- **The bcsels.** nir_opt_peephole_select makes each tree one bcsel a float. nir_opt_remove_phis takes a phi of an undef and another source as the other (nir_opt_remove_phis.c:105-175), and one of two equal constants as the constant (:31-58). Constants are equal by their bits, since nir_lower_load_const_to_scalar (v3dv_pipeline.c:427) and nir_opt_cse have made each float one value (`oneFloat`).
- **b2f.** A bcsel of 1.0 and 0.0 is the b2f of its bool, of 0.0 and 1.0 the b2f of its inot, and of -1.0 and -0.0, or of -0.0 and -1.0, the fneg of those (nir_opt_algebraic.py:2080-2083; the zeros by their sign, nir_search.c:278-290). to_vir emits b2f32 as an AND with the uniform 1.0 (nir_to_vir.c:1521-1523).

Refused still:
- a tree in a selection's arm or in a loop, whose flattening nir_opt_peephole_select and the unroll would have to see;
- a tree into a variable that is in scratch;
- a load of a whole aggregate that holds a bool through a tree.

Not ported yet:
- the nsz rules beside the b2f ones (nir_opt_algebraic.py:2084-2087);
- the ilt of an imin or an imax with a constant (:1519, :1527), so a clamped index keeps its clamp in the tree's condition;
- the trees of shader_in (v3dv_pipeline.c:432-433), with no input arrays yet;
- the order of scratch and the unroll in a fragment shader. Mesa moves the variables to scratch (vir.c:2041-2044) before v3d_optimize_nir(c) unrolls (vir.c:2077; the unroll only with c, nir_to_vir.c:2344-2347), and the fragment shader has no early v3d_optimize_nir as the vertex and geometry shaders have (vir.c:1107, :1150). There, an array of more than two elements a loop's counter indexes is in scratch, where facet's walk unrolls first and finds the index constant. A later step.

Results:
- glslc_tree_store, a vec2 stored at a computed index, is three bcsels and no scratch.
- glslc_tree_bools is two b2f and two fneg.
- glslc_tree_late, at -O0, has the two arrays' bcsels in the order Mesa puts their phis.
- glslc_tree_single has one element, and an element never stored that is what the other arm's was.
- glslc_tree_members takes a member, a struct and a matrix's column through a tree.
- glslc_tree_arm and glslc_tree_mixed are refused.

Of 22 mutations of the port, 22 fail the tests. On the CM5, FacetBoth's 240 cases are each as they were at 1.177, and its new `shipped trees` has 11 of 230400 pixels apart. The first of them is at 154,70, the edge pixel where 110 cases first differ. FacetProbe is 890 of 890.

**Then a layer of a 2D array, a 3D texture and a cube, sampled by a compiled program**, facet.library 1.179.

- **The images.** The profile takes Dim 3D and Cube beside 2D, and an arrayed 2D image. A sampled image's `SamplerDim` is a nir_tex_instr's sampler_dim and is_array, carried with its unit. A cube of an array needs SampledCubeArray and is refused.
- **The coordinate.** A sample reads the floats its image names, of a vector that may be wider, as vtn trims it (spirv_to_nir.c:3280-3296).
- **The cube's direction.** It is normalized before the sample, as nir_normalize_cubemap_coords puts it (v3dv_pipeline.c:406; nir_normalize_cubemap_coords.c:30-55): the fabs of its three floats, the fmax of the first two and then the third (nir_fmax_abs_vec_comp, nir_builtin_builder.h:84-91), the frcp of that, and the direction times it.
- **The TMU writes.** v3d_tex.c writes T, then R for a 3D texture and a cube (handle_tex_src, :110-120) and I for a layer, as a float the TMU rounds (:122-127), then the comparator's TMUDREF (:155-157). A cube's lookup starts at TMUSCM rather than TMUS (:380-381). v3d's scheduler may reorder all but the S write (can_reorder_tmu_write, qpu_schedule.c:225-235).
- **The draw.** The texture state is the one the fixed forms of a layer, a cube and a 3D texture read since 1.141. The plan's `compile` refuses every sample but a 2D one, as its programs read s and t alone.

Refused still: a cube of an array; a sample with a bias, a level or an offset. Not ported: (('fabs', ('fneg', a)), ('fabs', a)) (nir_opt_algebraic.py:232), so a direction with a negated float keeps the fneg under the fabs.

Results:
- glslc_cube's three fabs are `.abs` unpacks of its two fmax, as vir_opt_copy_propagate takes them, then a recip and three fmul. TMUT, TMUR and TMUSCM are each written from an fmul.
- glslc_volume writes TMUT, TMUR and TMUS; glslc_layers writes the blue times 3.0 to TMUI.
- glslc_cube_shadow writes TMUDREF before T, and TMUSCM last; glslc_layers_shadow writes TMUT, TMUI, TMUDREF and TMUS.
- glslc_cube_array is refused.

Of 18 mutations of the port, 18 fail the tests, one of them by not compiling. On the CM5, FacetBoth's 241 cases are each as they were at 1.178. Its six new cases are the layered cases again, through glslc's samples rather than the fixed forms. Each is as far apart as the fixed form's (9, 0, 0, 14, 0 and 0 of 230400 pixels), with the same first pixels. FacetProbe is 890 of 890.

**Then a sample at a level, with a bias, and a constant texel offset away, by a compiled program**, facet.library 1.180.

- **What is read.** The profile takes OpImageSampleExplicitLod and OpImageSampleDrefExplicitLod, and the image operands Bias, Lod and ConstOffset. `look` has an explicit level's sample carry its mask.
- **The lookup.** A sample's `Lookup` is a nir_tex_instr's op as vtn makes it (spirv_to_nir.c:3423-3438): tex, txb with the bias, txl with the level. The bias or the level is one float, a source the passes read, rename and replace as any other.
- **The offset.** A ConstOffset is a constant integer vector of as many as the image's coordinate names but a layer (non_array_components, v3d_tex.c:212-214), each -8 to 7. One past that is refused rather than cut to four bits.
- **The TMU writes.** v3d_tex.c writes the bias or the level to TMUB after the comparator (handle_tex_src, :129-150), and counts it among the writes the threads have room for (:222, :265-266). It packs the offsets into P2 and sets P2's disable_autolod for a cube at a level (:142-170), and writes P2 after P1, as a constant, where it is not the default (:349-352, :372-373; V3D42_TMU_CONFIG_PARAMETER_2, v3d_packet.xml:1578-1593). A lookup at a level starts at TMUSLOD, a cube's at TMUSCM still (:380-385).
- **Helper pixels and arms.** A sample at a level wants no helper pixels for its coordinate (nir_tex_instr_has_implicit_derivative, nir_opt_load_skip_helpers.c:151-156), so a read its coordinate comes from may skip them. In a selection's arm it keeps the arm, as any tex does (nir_opt_peephole_select.c:59-326).
- **The plan.** Its `compile` refuses a bias, a level and an offset, which its programs do not write.

Refused still: a gradient (nir_lower_tex's lower_txd, vir.c:802, not ported), an offset the program computes, ConstOffsets and MinLod.

Results:
- glslc_lod writes TMUT, TMUB from an fmul, and TMUSLOD, with no P2; glslc_bias writes TMUB from an fsub, and TMUS.
- P2 is 0x00F0E100 for glslc_offset, 0x00F07800 for glslc_lod_offset, 0x00F00300 for glslc_bias_offset, 0x00FD2100 for glslc_volume_offset and 0x00F0F300 for glslc_layers_offset, each after P1. facet's own `Offset` gives glslc_offset's.
- glslc_cube_lod's P2 is 0x00F00002, and it starts at TMUSCM. glslc_shadow_lod writes TMUDREF and TMUB, then TMUSLOD.
- glslc_cube_shadow_bias makes five TMU writes, and runs at two threads.
- glslc_dependent's first sample skips its helper pixels.
- glslc_divided's level and bias are renamed by nir_opt_cse's pass.
- glslc_lod_arm is glslc_branched's program with TMUB and TMUSLOD.
- glslc_grad is refused, and so are glslc_offset's -2 made -9, glslc_lod_offset's 7 made 8, a Lod and a Bias swapped onto the other sample, and an explicit level's sample with no mask.

Of 28 mutations of the port, 28 fail the tests; two of them first did only by not compiling, and then by a test as variants. On the CM5, FacetBoth's 249 cases are each as they were at 1.179, and four are new:
- glslc's textureLod over levels 0 to 3 is 0 of 230400 pixels apart with the levels mixed.
- At the nearest level it is 270 apart: one column in the middle of the quad, where the level is within a few thousandths of 1.5 and the two round it to different levels.
- glslc's bias from -1 to 1 is 3660 apart, at most 5 a channel: apart in how two levels are mixed, not in which are read.
- The IR's offset of (1, -2) texels is 0 apart.

FacetProbe is 890 of 890. The board's cube has one level, so P2's disable_autolod is checked in the host tests alone.

**Then a texture's size at a level and its levels, by a compiled program**, facet.library 1.181.

- **What is read.** The profile takes the capability ImageQuery, and OpImage, OpImageQuerySizeLod and OpImageQueryLevels. vtn makes them txs with its lod and query_levels (spirv_to_nir.c:3089-3096, :3119-3135, :3384-3386).
- **The steps.** A `texture_size` step has as many integers as nir_tex_instr_dest_size gives the image: two for a 2D image and a cube, three for a 3D one and a 2D array. A `texture_levels` step has one. The level is a source the passes read, rename and replace as any other.
- **The code.** ntq_emit_txs reads the draw's word of each axis, QUNIFORM_TEXTURE_WIDTH, _HEIGHT and _DEPTH. ntq_minify makes each the MAX of its SHR by the level and 1. An array's last is QUNIFORM_TEXTURE_ARRAY_SIZE, not minified (nir_to_vir.c:895-960). query_levels is QUNIFORM_TEXTURE_LEVELS (:972-975).
- **The words.** `compile.Word.texture_size` is a unit and a field. The draw answers it as get_texture_size_from_image_view does (v3dv_uniforms.c:378-414): the view's first level's sides, a 3D image's slices as its depth, its layers and its levels.
- **The unit.** A query reads no sampler state. It takes the unit a sample of its set and binding has, a comparison in it or not, or one of its own (descriptor_map_add, v3dv_pipeline.c:516-561). In a selection's arm it keeps the arm, as any tex does.
- **The plan.** Its `compile` refuses both.
- **The stack.** A pipeline is made on a stack of its own, 128 KiB from exec's NewStackRun. The back end holds about 24 KiB of frames at once, and with FacetBoth's own frames that came to the end of the stack it ran on as a shell command.

Results:
- glslc_size reads two uniforms, each SHR by the immediate 0 and MAX 1, and no P0 or P1. glslc_size_lod's SHRs are by the FTOIZ of the red times 4.0.
- glslc_size_layers' layers are not shifted; glslc_size_volume's depth is shifted by 2; glslc_size_cube has two words. glslc_levels is one word and no SHR.
- glslc_size_sampled's sizes and the sample's P0 and P1 are of one unit. glslc_size_shadow reads the width of a unit a comparison is in, and its height is dead.
- glslc_size_arm keeps its arm. glslc_size_merged's level is the FTOIZ nir_opt_cse keeps. glslc_size_aliased is one unit for two variables at one binding.

Of 25 mutations of the port, 25 fail the tests: one only by not compiling, whose variant a test fails, and two only since glslc_size_merged and glslc_size_aliased.

On the CM5, FacetBoth's 253 cases are each as they were at 1.180. Its three new cases are glslc's textureSize and textureQueryLevels of the texture of levels at levels 0 to 3, of the array at levels 0 to 2, and of the 3D texture; each is 0 of 230400 pixels apart. FacetProbe is 890 of 890.

Two things came up on the board first:
- Before the pipeline had a stack of its own, FacetBoth 1.46 ran past the end of its 32 KiB stack in the shipped kept branches, which 1.45 had drawn on the same stack.
- Its 3D case read no varying. The V3D's pipeline refuses that where the vertex function writes two, so the case reads its level of the first float.

**Then a texel at a level, by a compiled program**, facet.library 1.182.

- **What is read.** The profile takes OpImageFetch. vtn makes it a txf with its lod (spirv_to_nir.c:3069-3076, :3433-3438).
- **The step.** A `sample` step of the lookup `fetch`: its coordinate is integers, and its level is required, as an explicit level's is. It has no implicit derivatives. A cube is no image a texel is fetched of (v3d_tex.c:376).
- **The code.** handle_tex_src writes the integers to TMUT, TMUR or TMUI as the image has them, S last, and the level to TMUB (v3d_tex.c:85-150). TMUSF starts the lookup (:375-377).
- **The configuration.** A fetch reads no sampler state (nir_tex_instr_need_sampler), so P1 is written only where non_default_p1_config says so (v3d_tex.c:312-354). Where the fetch does not skip its helper pixels, because an implicit sample's coordinate it feeds wants them (nir_opt_load_skip_helpers.c:151-156), P1 is the constant of its own bits, the per-pixel mask off. With an offset it is the default constant, the mask on, before P2 (:355-371).
- **The unit.** A fetch's unit is the unit of its set and binding, a comparison in it or not. In a selection's arm it keeps the arm, as any tex does.
- **The plan.** Its `compile` refuses it.

Results:
- glslc_fetch's stream is P0's word alone, with its level to TMUB, TMUSF and two FTOIZ. glslc_fetch_zero writes level 0.
- glslc_fetch_layers' layer goes to TMUI, and glslc_fetch_volume's slice to TMUR.
- glslc_fetch_offset has the default P1 and P2 0x00F0E100. glslc_fetch_dependent's P1 is the constant 0.
- glslc_fetch_sampled's fetch and sample are of one unit; glslc_fetch_aliased is one unit that compares. glslc_fetch_arm keeps its arm.
- A fetch of no level, a cube's, and a MinLod are refused.

Of 18 mutations of the port, 18 fail the tests.

On the CM5, FacetBoth's 254 cases are each as they were at 1.181. Its five new cases are glslc's texelFetch at level 1, of an array's layer 2, of a 3D texture's slice 3, (1, -2) texels away, and a sample at a place the fetched texel moves by whole texels; each is 0 of 230400 pixels apart. FacetProbe is 890 of 890.

The last case first moved its sample by a 4096th of the texel, and was 136 pixels apart. Moved to the centres of texels, where no rounding of the place crosses an edge, it is 0. So the 136 were places near an edge that the V3D and the cores rounded to either side, not the fetch.

**Then a sample with a gradient, by a compiled program**, facet.library 1.183.

- **What is read.** The profile takes the image operand Grad. vtn makes it a txd, its two derivatives sources of their own (spirv_to_nir.c:3441-3448), of an explicit level's sample with no Bias or Lod.
- **The lowering.** v3d lowers every txd (`lower_txd`, vir.c:802; nir_lower_tex.c:1833-1847), and lower_gradient (:855-912) is ported as it reads:
  - a txs at the integer 0 (build_texture_size, :112-118; nir_get_texture_size, nir_builtin_builder.c:459-466) of nir_tex_instr_dest_size's integers, and their i2f32, the first two of an array's (`component_mask`, :868-884);
  - each derivative times it;
  - fmax of the two fsqrt of the fdot of each with itself, frcp of frsq by `lower_fsqrt`;
  - and flog2, the txl's lod (replace_gradient_with_lod, :690-704). v3d writes it to TMUB and starts the lookup at TMUSLOD, as any explicit level's.
- **Shadows, offsets, merging.** A shadow sample's gradient is lowered as any, and an offset is kept. Two gradients of one texture read its size once: nir_opt_cse makes the two txs one.
- **Refused.** A cube's gradient, lower_gradient_cube_map's (:707-852), is not ported. A gradient on an implicit level's sample or on a fetch is no SPIR-V vtn takes.

Results:
- glslc_grad_varying reads two sizes, each SHR and MAX, two ITOF, two RSQRT and RECIP, an FMAX, and a LOG to TMUB.
- glslc_grad_layers reads the first two sizes of three; glslc_grad_volume reads three.
- glslc_grad_shadow writes TMUDREF; glslc_grad_offset has its P2; glslc_grad_twice reads one size.
- glslc_grad, refused until now, has its zero products taken out. glslc_grad_cube is refused.

Of 18 mutations of the port, 18 fail the tests. Three first did only once a test checked the width of the txs and the kind of every product, and in a variant that compiles.

On the CM5, FacetBoth's 259 cases are each as they were at 1.182. Its four new cases:
- glslc's textureGrad of the texture of levels, levels 0 to 3 mixed: 6 of 230400 pixels apart, 3 at worst.
- The same at the nearest level: 429 apart.
- Of the array's layer 2, mixed: 2 apart, 3 at worst.
- textureGradOffset, (1, -2) texels away, the nearest: 191 apart.

Where the nearest are apart is thin lines: the contours where the level is a half. There the V3D's level (its RSQRT, RECIP and LOG, and the TMU's own rounding of it) and the cores' exact one fall either side in a pixel or two. textureLod's nearest is apart the same way, of an exact level, where it is within a few thousandths of 1.5. FacetProbe is 890 of 890.

**Then a cube's sample with a gradient, by a compiled program**, facet.library 1.184.

lower_gradient_cube_map (nir_lower_tex.c:707-852) is ported as it reads. Its coordinate is the one nir_normalize_cubemap_coords made: v3dv's preprocess_nir does that before v3d's nir_lower_tex (v3dv_pipeline.c:406), as `normalizedCube` comes before it here.
- **The face.** cond_z is z's magnitude at least the larger of x's and y's; cond_y is y's at least the larger of x's and z's. Each float of Q, dQdx and dQdy is the bcsel on cond_z of the coordinate's or a derivative's, and of the bcsel on cond_y of its xzy and yzx swizzles (:783-813), a bcsel a float.
- **The quotient rule.** The reciprocal of Q's z; Q's first two times it; each derivative's first two less those times its z, times the reciprocal (:815-834).
- **The level.** fadd(-1.0, fmul(0.5, flog2(L * (L * M)))), M the fmax of the two fdots and L the cube's width at level 0 (:713-715, :836-848). It is the txl's lod, to TMUB, and the lookup starts at TMUSCM.
- **The rules.** Two nested bcsels sharing a value become one on the ior of the conditions. A constant derivative's zero less a product is its fneg, v3d's XOR of the sign.

Results:
- One new test works the steps out on the host (`evaluatedOf`) for directions on each face of each sign and on ties, against the lowering's arithmetic.
- glslc_grad_cube_shadow writes TMUDREF; glslc_grad_cube_constant has its XOR; glslc_grad_cube_varied's derivatives are none along the direction.
- glslc_grad_cube, refused at 1.183, compiles.

Of 20 mutations of the port, 20 fail the tests. Four did only once the ties, the txs's level, and the counts of FMUL and FMAX were tested. Two of those four give the same value either way, and fail only on Mesa's count of instructions: the multiply by a reciprocal that is 1 or -1, and a cond_y of x and y.

On the CM5, FacetBoth's 263 cases are each as they were at 1.183. Its new case is glslc's textureGrad of the cube's +z face, the nearest filter magnified and linear minified: 67 of 230400 pixels apart, 52 at worst. The board's cube has one level, so the level only says which of the two filters is read. It is at or below 0 inside the square where the larger of the face's two coordinates is at most 0.25, and above 0 outside it. The two regions agree. The first pixel apart, at 265,150, is where the face's two are about -0.253 and -0.249, on that square's edge, which is some 365 pixels long; the run draws no map of the rest. FacetProbe is 890 of 890.

**Then two samples of one texture at one coordinate are one**, facet.library 1.185.

nir_opt_cse takes tex instructions (instr_can_rewrite, nir_instr_set.c:47-52), and v3d's loop runs it (nir_to_vir.c:2265). glslc -O leaves two such samples two.
- **The merge.** A sample is now a value the port's nir_opt_cse merges. Its unit, its sources, its lookup (tex, txb, txl or txf) and its texel offset must be those of another sample that dominates it, as nir_instrs_equal's tex compares pack_tex and the sources (:297-327, :695-723).
- **Arms.** The loop runs nir_opt_cse before nir_opt_peephole_select (:2265, :2269-2279), so a tex an arm repeats of one before the selection is gone from the arm when the arm is counted. A sample, a size or a count of levels read in an arm keeps the selection a branch only where no earlier one is the same, outside the arms of a kept selection; and it counts nothing in the arm's cost. One in an arm of a kept selection, or in the other arm, does not dominate, and is not the same.
- **Not ported.** Two variables at one binding are two units here until the passes are done, and their samples are not merged. v3dv lowers the derefs to one index before v3d's nir_opt_cse, which would merge them.

Results:
- One sample each: glslc_sample_twice, _twice_lod, _twice_fetch and _twice_shadow, and _twice_one once the times 1.0 is taken out.
- Two each of _swapped and _bias_lod, and three of _twice_apart.
- Flattened: _twice_arm's arm, to four selects of the one sample; both arms of _twice_nested; and the three arms of glslc_tex_arms_dont_flatten, under DontFlatten's limit of 0.
- Kept: glslc_sample_kept_then_arm, _both_arms, _arm_offset and glslc_tex_arms_kept.

Of 21 mutations of the port, 21 fail the tests. Two first did only once a test had a count of levels and a shadow sample alone in an arm, and one only in a variant that compiles.

On the CM5, FacetBoth's 264 cases are each as they were at 1.184. Its new case is glslc's sample of the texture with the same sample read twice more in an arm, its blue, green, red and alpha times its red: 0 of 230400 pixels apart. FacetProbe is 890 of 890.

**Then an fabs of an fneg is the fabs of what it negates**, facet.library 1.186.

(('fabs', ('fneg', a)), ('fabs', a)) (nir_opt_algebraic.py:232), not ported at 1.179, is now a rule of the port's nir_opt_algebraic, of the floats nir_lower_alu_to_scalar makes an instruction each of (nir_to_vir.c:2259):
- an fabs of a vector fneg is the fabs of the vector;
- an fabs of a vector with a negated float is an fabs a float, that float's of what it negates.

The fneg's XOR, and its uniform of -0.0, go where nothing else reads the fneg. The fabs nir_normalize_cubemap_coords takes of a negated direction's floats reads the floats, and only the direction keeps its fnegs.

Results:
- glslc_abs_negated has no XOR and no uniform; a test works its colour out on the host.
- glslc_cube_negated's fabs are each of the input.

Of 6 mutations of the port, 5 fail the tests. The sixth gives the scalar fabs a split makes a second operand: the same program, as an fabs reads none.

On the CM5, FacetBoth's 265 cases are each as they were at 1.185. Its new case is glslc's sample of the cube at the direction with its first and third negated, the nearest, on the +z instance and so of the -z face: 0 of 230400 pixels apart. FacetProbe is 890 of 890.

**Then the 32-bit integers' divisions and remainders**, facet.library 1.187.

nir_lower_idiv, not ported at 1.165, now is (vir.c:2019-2022; nir_lower_idiv.c:32-94). OpUDiv, OpSDiv, OpUMod, OpSRem and OpSMod are vtn's udiv, idiv, umod, irem and imod (vtn_alu.c:304-310), a float each once nir_lower_alu_to_scalar has run (v3dv_pipeline.c:404):
- an unsigned one is emit_udiv's: the SFU's RECIP of the divisor's u2f32, made an integer of 2^32 less 512 times it; one Newton step of it; the quotient the high word of the dividend times it; and two steps that each take the divisor off the remainder where it is still as large;
- a signed one is emit_idiv's, of the magnitudes: the quotient negated where the operands' XOR is negative, the remainder where the dividend is, and an imod's divisor added where the signs differ and the remainder is not 0;
- each umul_high is nir_lower_alu's (`lower_mul_high`, v3dv_pipeline.c:201; nir_lower_alu.c:119-158): Hacker's Delight's four 16-bit products of the words' halves, each 32-bit product an UMUL24 and a MULTOP.

The lowering's constants are made once for all the floats of an instruction, as nir_opt_cse makes NIR's one. A lowering is 52 to 65 steps: the tables of 128 hold a vector of two divisions, not one of four, and raising most_steps is a step of its own. A divisor that is a constant, or of whose floats one is, is nir_opt_idiv_const's first (vir.c:2018), which is not ported: refused.

Results:
- glslc_udiv, _idiv, _umod and _imod, and an OpSRem of glslc_imod's, are each ten 32-bit products and one RECIP, worked out on the host for every pair of -100 to 100, or 0 to 100.
- glslc_udiv_swapped and glslc_udiv_vector, two divisions each, are worked out the same.
- glslc_idiv_constant and glslc_udiv_part are refused.
- The lowering of two words is worked out for 19 values each way, of every sign and size, the most negative by -1 wrapping.

Of 58 mutations of the port, 57 fail the tests. The 58th makes a lone float's result a construct of one: the same program for glslc_udiv, _idiv and _imod.

On the CM5, FacetBoth's 266 cases are each as they were at 1.186. Its two new cases are glslc's unsigned division and signed modulus of two integers of the colour that span the word, each program checking its result against its own operands: 8 of 230400 pixels apart, the 8 at the triangles' edge every case of their geometry has. FacetProbe is 890 of 890.

The cases check themselves because the two devices' interpolation can make an integer of the colour one apart where a float crosses one. Compared byte for byte, the quotient was 349 pixels apart, each device's right for its own operands: at 120,69 the cores read 210 and 41, the V3D 210 and 40.

**Then a division or remainder by a constant**, facet.library 1.188.

v3dv's preprocess_nir runs nir_opt_algebraic (v3dv_pipeline.c:413, :443) before v3d's nir_opt_idiv_const (vir.c:2018), and both are ported, a float at a time:
- nir_opt_algebraic's divisor rules (nir_opt_algebraic.py:200-217): by 1 the dividend or 0, an imod or irem by -1 0, and by a power of two shifts and masks, v3d leaving `lower_bitops` unset. An idiv's isign is lowered to imin(imax(a, -1), 1) (`lower_isign`, v3dv_pipeline.c:200; nir_opt_algebraic.py:2836).
- nir_opt_idiv_const for another divisor (nir_opt_idiv_const.c:29-152): by 0 a 0; an unsigned one above 2^31 a b2i32 of a comparison, an AND with 1 (nir_to_vir.c:1524-1528); the most negative its own cases; and else Hacker's Delight's multiply by util_compute_fast_udiv_info's or _sdiv_info's magic number (util/fast_idiv_by_const.c:46-237).
- The multiply's uadd_sat is a bcsel (`lower_uadd_sat`, v3dv_pipeline.c:165; nir_opt_algebraic.py:2539), and its imul_high nir_lower_alu's, the high halves' shifts an ishr (nir_lower_alu.c:119-158).

A float whose divisor is not a constant is nir_lower_idiv's, as at 1.187.

Results:
- glslc_udiv_constants (by 7, 4 and 16, and a remainder by 7) is five 32-bit products and no RECIP; glslc_idiv_constants (by -5, 8, 6 and -4) ten.
- 1.187's refused modules compile: glslc_idiv_constant is four products, and glslc_udiv_part's constant float a multiply beside its other float's RECIP, 14 and one.
- The magic numbers are pinned for 3, 5, 6, 7 and 641 unsigned and for 3, 5, 7, -5 and -7 signed.
- Each of the five operations is worked out on the host for 21 dividends by 41 divisors of every sign and size, through the reading and through the builders alone.
- An unsigned division by 2^31 + 1, 3000000000, 2^32 - 16 and 2^32 - 1 is a comparison's b2i32 with no multiply.

Of 53 mutations of the port, 50 fail the tests. The round-up test made strict (fast_idiv_by_const.c:113) is the same program: a remainder half the divisor needs a divisor that is a power of two, which never comes there. The round-down test made strict (:134) and the signed test numerator one larger (:199) changed no divisor in the sweeps tried.

On the CM5, FacetBoth's 268 cases are each as they were at 1.187. Its four new cases are glslc's unsigned divisions and remainders and its signed divisions and moduli by constants of an integer of the colour, each program checking its results against its own dividend: 8 of 230400 pixels apart, the 8 at the triangles' edge every case of their geometry has. FacetProbe is 890 of 890.

Each case is worked out on the host for all 65536 pairs of the colour's integers, and a break of each of the lowering's paths shows in one of them. Two programs of all the checks were 142 and 178 steps, past the tables' 128, and right on the host with the tables raised: they are split into four of 88 to 117.

**Then tables of 256 steps**, facet.library 1.189.

A body may compute 256 values, where it might 128 since 1.152. 1.188's two programs of five divisions by constants and their checks were 142 and 178 steps before their dead ones went, and FacetBoth split them in four. NIR has no such bound, its instructions and nir_from_ssa's sets being allocated as they grow; the port's tables are fixed, on the heap.

- The from-SSA walk's sets of where each float is read are a bit a step: a Mask of `most_steps` bits, where they were a u128.
- They are Emit's, on the heap: 32 KiB of them at 256 steps, the whole of the stack a command is given (CLI_DEFAULT_STACK, 4096 words). A web's number is a u16.
- Work is 70 KiB and Emit 54 KiB. The driver's deepest frames are the algebraic pass's 9.4 KiB, apart from the walk, and the walk's 4.7 KiB and the copies' 8 KiB within it: 12.7 KiB where they were 14.6.

Results:
- glslc_udiv_many and glslc_idiv_many, 1.188's two programs, are 18 and 13 32-bit products and no RECIP, each worked out on the host for all 65536 pairs of the colour's integers.
- glslc_selection_late is glslc_selection_early, a selection kept for its false arm's twelve sines, after six divisions by 7 that put its begin at step 133. It has the same copies and products under the mask, and one more copy of ~0 for each division's uadd_sat.
- 1.187's glslc_integers with its first OpIMul made an OpSDiv (a scalar, where that test said a vector of four) is more than 128 steps and compiles: one RECIP and 11 products.

Of 7 mutations, 4 fail the tests; a walk whose steps after one stop at the 127th fails the late selection. The three left:
- the steps after the 254th none and not the 255th, which only a program of all 256 steps tells;
- a web's no-web 0xFF: the same program, a web being a phi's, and 256 steps holding fewer than 255 phis beside a selection's marks;
- the set of the floats the colour reads left uncleared: the same in a Debug build, where it is 0xAA bytes, whose bool reads false. Set where it is not, it fails.

On the CM5, FacetBoth's 272 cases are each as they were at 1.188, and its two new ones, 1.188's programs whole, are 8 of 230400 pixels apart: the 8 at the triangles' edge every case of their geometry has. FacetProbe is 890 of 890.

**Then flat and non-perspective varyings, and integer ones**, facet.library 1.190.

The reading takes `Flat` and `NoPerspective` of a fragment program's inputs and a vertex program's outputs, as vtn sets var->data.interpolation of them (vtn_variables.c:1370-1374). It refuses either on anything else, or with a literal. A fragment program's integer input is read where it is flat, and a vertex program's integer output is written; an integer attribute is still not ported.

- emit_fragment_varying is ported whole (nir_to_vir.c:1049-1121): with perspective the ldvary's value times W plus the C coefficient, without it the value plus C, and flat C alone, the value moved nowhere (emit_flat_varying, :1040-1046).
- Each input's flag is set by the number it was given, as v3d_set_fs_prog_data_inputs gives prog_data its flags of the first 24 (vir.c:985-1003).
- Every draw of the program writes FLAT_SHADE_FLAGS and NON_PERSPECTIVE_FLAGS, the higher numbered zeroed, or the ZERO_ALL of either where it has none, as v3dv writes them for a pipeline (cmd_buffer_emit_varyings_state, v3dvx_cmd_buffer.c:1756-1831). The binner's list no longer zeroes them once at its start.
- CFG_BITS sets "Direct3D Provoking Vertex": a triangle's first vertex provokes it, Vulkan's, as v3dv sets it for a pipeline that does not ask for the last (v3dvx_pipeline.c:200-210). The V3D took the last.
- A strip's every other triangle is (v_i, v_i+2, v_i+1), Vulkan's, where it was (v_i+1, v_i, v_i+2): the same face, with the first vertex the one that provokes it, on the cores' fixed flat form as on the V3D.
- The plan, which interpolates with perspective alone, refuses a program of either.
- A draw's state at its most, the occlusion query and the branch out are 125 bytes of the 192 a part of the list keeps.

Results:
- glslc_interpolations, a varying of each kind in eight floats, has flags 0x30 and 0xC0, eight ldvarys, six FADDs of C and two moves of it.
- glslc_flat_integer has flags 0xF, four moves of C, four UTOFs and four products; every byte of its varying is worked out on the host.
- The integers made NoPerspective are refused as a type, and Flat on the colour written or on a vertex program's attribute is refused. A vertex program's flat colour is glslc_vertex_as_it_is's words.

Of 28 mutations, 25 fail the tests, the strip's old order the driver's test alone, and the three that only failed to compile fail them made to compile.

On the CM5, FacetBoth's 274 cases are each as they were at 1.189. Its three new ones are glslc's vertex and fragment shaders of a flat colour, of the colour as four flat integers, and of the colour without perspective under a W of 1 + 2 * the blue. They are 5 of 230400 pixels apart: the 5 at the triangles' edge that "shipped vertex shader", the same geometry through a compiled vertex program, has. The cores carry the first vertex's colour at all three corners, and the colour times W read without dividing; the picture without perspective is the smooth one of a W of 1, as it is to be. FacetProbe is 890 of 890.

**Then tables for longer modules**, facet.library 1.191.

A module may use 4096 ids, where it might 256, declare 256 constants, where it might 32, and come to 4096 words, where it might 256; a program may read 256 uniforms, where it might 32. None of the four is Mesa's: vtn allocates its values by the module's bound and each nir_constant as it is read (spirv_to_nir.c), and the uniform stream and the packed instructions grow as they are added (vir_get_uniform_index, vir.c:2771; v3d_vir_to_qpu). The ids ran out first, a GLSL operation being several of them: at 1.189 a chain of 70 operations was refused at 310.

- The tables are fixed and on the heap. Work is 296 KiB, where it was 70, 40 bytes an id.
- A Code's uniforms are Work's, as its words are, and the driver copies them into the program it keeps, which holds 256 of 12 bytes.
- planLoop's reading of each id is Work's: 40 KiB, more than the stack a command is given, where it was 2.5 KiB of the call's own.
- A pipeline is compiled on the driver's own stack of 128 KiB (since 1.181). makePipelineHere's frame is 2.3 KiB, where it was 6.1, and V3DTest's fragments.compiled 0.6 KiB, where it was 3.1. A first draft held a Code's 256 uniforms by value and came to 32.2 and 13.9 KiB, V3DTest's chain past the 32 KiB its command is given.
- An id of 4096 an instruction defines, which `spirv.look` does not hold to the bound, is refused as it is read.
- Facet's own profile keeps its 1024: a module of more is still a module, and the pipeline takes it to discard, as it takes any module `look` cannot read to its end.

Results:
- glslc_many_ids, the colour through 28 products and sums by constants of their own and a loop of three, is 404 ids, 224 uniforms, 460 floats of constants and 257 words. It is worked out on the host for three colours as its f32 products and sums are.
- A bound of 4096 is read, and one of 4097 refused.

Of 6 mutations, all fail the tests. One failed none at first: the test of an id against the tables made `>`, where `look` refuses the bound past 4096 before it, until an OpLoad was given the id 4096.

On the CM5, FacetBoth's 277 cases are each as they were at 1.190. Its new one, glslc_many_ids on the V3D beside its products and sums worked out on the cores, is 8 of 230400 pixels apart: the 8 at the triangles' edge every case of its geometry has. FacetProbe is 890 of 890.

**Then GLSL.std.450's curves and geometry**, facet.library 1.196.

The compiler takes fifteen more of GLSL.std.450's functions, each built as vtn_glsl450.c builds it and lowered as NIR lowers it for the V3D:

- **Asin** is nir_asin's: build_asin, Abramowitz and Stegun's formula 4.4.45 (nir_builtin_builder.c:184-226), and below |x| = 0.21502245 Taylor's x(x²/6 + 1) (:228-237). **Acos** is π/2 less build_asin without Taylor's part (:239-248).
- **Atan** is nir_atan's polynomial of u², u the value or its reciprocal, whichever is at most 1 (:250-298). **Atan2** is nir_atan2's: the point turned a quarter where x ≤ 0, both coordinates scaled by a quarter where the denominator is 1e18 or more, and the angle negated where the smaller of y and the scaled denominator's reciprocal is below 0 (:300-393). The sign of both is nir_copysign's on a device with integers, an IOR of two IANDs (nir_builtin_builder.h:150-168).
- **Sinh, Cosh, Asinh, Acosh and Atanh** are vtn_glsl450.c's sums of fexp, flog and fsqrt (vtn_glsl450.c:352-366, 375-390), fexp and flog being exp2 and log2 scaled (nir_builtin_builder.h:112-121). **Tanh** is nir_tanh_emulated's (nir_builtin_builder.c:480-512), as the V3D's options leave has_tanh false (vtn_glsl450.c:368-373).
- **Fma** is ffma_weak (vtn_glsl450.c:152-155), an FMUL and an FADD, as nir_opt_algebraic splits it for a back end that sets no float_mul_add, as the V3D's sets none (nir_opt_algebraic.py:424).
- **Cross** is nir_cross3's (nir_builtin_builder.c:38-48), and **FaceForward**, **Reflect** and **Refract** are vtn's (vtn_glsl450.c:304-350). Refract's eta is one float, whatever I and N are.
- A comparison or a bcsel of vectors is one of each float, as nir_lower_alu_to_scalar splits it.

Still left out: Modf and Frexp, which give back two values; Ldexp; Determinant and MatrixInverse; FindILsb, FindSMsb and FindUMsb; the packing and unpacking functions; and InterpolateAtCentroid, InterpolateAtSample and InterpolateAtOffset. Integer attributes, which this item also lacks, wait on integer vertex formats: the library reads an attribute in four float32 formats and two unorm8 ones only (`attributeFormat`, pipeline/_pipeline.zig).

Results:
- glslc_inverse_trig, Asin and Acos of vec2s, Atan of a float and Atan2 of two, is 269 words. Its program has 11 bcsels, 8 comparisons, the copysigns' 4 IANDs and 2 IORs, and the B2F32 of Atan2's quarter turn.
- glslc_hyperbolic, the six of the colour, is 305 words: 6 EXP2s, 3 LOG2s, Tanh's FMIN and IOR, and Asinh's SIGN.
- glslc_geometry, Cross, Reflect, FaceForward, Refract and Fma of a normal and a direction the colour turns, is 300 words. FaceForward's and Refract's bcsels are 6, a float each, of 2 comparisons.
- Each is worked out on the host for eight colours, the first two within 1e-4 of std.math's functions and the third within 1e-5 of the same sums. Of the eight colours, 4 face each way and 5 have Refract's k below 0.

The V3D's tests are 338, three new. Of 51 mutations, 46 fail them. Two of those failed none at first: Fma's addend made its multiplier, which was 0.5 as well, and FaceForward's Nref made N, when every colour faced the same way. They fail since the program's Fma multiplies by 0.375 and its Nref is the colour's blue and alpha. The five left change nothing the tests can see:
- copysign's mask made 0x3FFFFFFF, which clears an exponent bit no value below 2 sets: Atan's are at most π/2 and Tanh's at most 1;
- Taylor's part made to begin at 0.015, both formulas being within 7e-5 of asin below 0.215, under the tests' 1e-4;
- Atan's test of |u| ≤ 1 made <, which changes only an Atan of 1, and that by 6.5e-6;
- Atan2's x ≤ 0 made x < 0, which gives the same ±π/2 at x = 0, but at 0 over 0;
- Cross's refusal of vectors other than vec3s, which spirv-val refuses as well and glslc makes none of.

On the CM5 FacetBoth 1.60 has three new cases, "shipped inverse trigonometry", "shipped hyperbolic functions" and "shipped cross, reflect and refract": the colour through glslc's module on the V3D, and through the same functions on the cores. The first two are 8 of 230400 pixels apart, the 8 at the triangles' edge every case of their geometry has. The third is 12: the 8, and 4 on the line where Refract's k is 0, where the picture jumps from the refracted direction to 0 and the two devices' interpolated colours can fall on either side of it. With an eta of 0.66, under which k is never below 0, it is 8. With the cores' functions made wrong on purpose the three are 46,565 apart each, and with the cores' FaceForward always N the third is 1,965: the V3D's program faces both ways where the cores' does. The other 284 cases are each as they were at 1.195, and FacetProbe is 890 of 890.

**Then GLSL.std.450's bit finds**, facet.library 1.197.

FindILsb, FindSMsb and FindUMsb are vtn's find_lsb, ifind_msb and ufind_msb (vtn_glsl450.c:178-180). The V3D lowers all three and has a count of leading zeros (lower_find_lsb, lower_ifind_msb, lower_ufind_msb and has_uclz, v3dv_pipeline.c:194-211), so nir_opt_algebraic makes each 31 − uclz of a word (nir_opt_algebraic.py:2717-2738):

- FindUMsb of x itself;
- FindSMsb of x ^ (x >> 31), which is ~x where x is below 0, so that −1 and the negative powers of two come out right;
- FindILsb of x & −x, its lowest bit alone, find_lsb's u2u32 of a 32-bit word being nothing.

uclz of 0 is 32, so each answers −1 for a word with no bit to find, as GLSL wants. uclz is a new integer step, emitted as CLZ (nir_to_vir.c:1696-1697), which the QPU encoder already had. It is folded where its word is a constant, and worked out on the host.

Results:
- glslc_bit_finds is 334 words: words of two bits the colour sets at 31 places, of none where it says, and signed and turned where it says, and the three finds of them. Its program has a uclz for each of the four finds of vectors, and a CLZ for each of the eight floats of them the colour reads.
- For eight colours, among them words of bit 31, of bit 0, of one bit twice, of none, and of none turned, which is −1, it answers exactly what GLSL's definitions of the finds answer.
- uclz of constants folds to 24 for 0xFF, 0 for 0x80000000 and 32 for 0.

The V3D's tests are 339, one new. Of 16 mutations, 14 fail them. The two left change nothing:
- FindSMsb's shift made 30, which leaves every word's highest bit unlike the sign where it was;
- a uclz counted as reading a second operand, which is step 0, the colour, read anyway.

On the CM5 FacetBoth 1.61's new case, "shipped bit finds", is 56 of 230400 pixels apart: the 8 at the triangles' edge, and 48 that by every sign are pixels where the colour times 31 crosses a whole number between the cores' interpolation and the V3D's, so that the two take their bits a place apart. With 15 places in place of 31 they are 30. With the cores' function made wrong on purpose the case is 46,565 apart. The other 287 cases are each as they were at 1.196, and FacetProbe is 890 of 890.

**Then Modf, Frexp and Ldexp**, facet.library 1.198.

- **ModfStruct** is vtn's (vtn_glsl450.c:546-562). It takes x's sign bit alone, a signed zero, and makes two members with that sign: the fraction of |x|, or the signed zero where |x| is infinite, which an integer comparison with infinity tells; and the whole, ffloor(|x|). Its ffract is lowered (nir_opt_algebraic.py:546) and shares the whole's ffloor.
- **FrexpStruct** is nir_frexp_sig and nir_frexp_exp (vtn_glsl450.c:575-581), as nir_lower_frexp lowers them at 32 bits (nir_lower_frexp.c:29-159), which v3d runs (vir.c:841).
  - The significand is x's sign and mantissa under the exponent of [0.5, 1), where 0 < |x| and x is finite, and x itself otherwise. Its fisfinite is what the late rules make of one under fast math, feq(x, x) (nir_opt_algebraic.py:4233).
  - The exponent is |x|'s bits shifted down 23, plus −126 where x is not 0, the fneu of |x| being that of x (:800).
- **Ldexp** is nir_ldexp (vtn_glsl450.c:408-418). The V3D has no has_ldexp, so it is lowered (nir_opt_algebraic.py:3255-3327).
  - The exponent is held to −254 to 254, and f is multiplied by 2 to its half and by 2 to the rest, so that 2^128 can be reached.
  - Each power of two is made of its bits, (e + 127) << 23, which rule :729 makes (e << 23) + 1.0's bits. Mesa's lowering of the isub (:2402), its reassociations (:2423, :730) and the late isub (:3872) come to the same.
- Both structs are held as a struct value is (since 1.176), and OpCompositeExtract reads their members.

Still left out: Modf and Frexp of a pointer, which glslc does not make; Determinant and MatrixInverse; the packing functions; and the interpolation functions.

Results:
- glslc_modf_frexp is 352 words: ModfStruct and FrexpStruct of the colour made −4 to 4, and Ldexp of the colour by a power of two it picks and back. Frexp's exponent is z's and Modf's whole x's: the pictures' alpha is 1, so w would be 4 at every pixel, its exponent always 3.
- Its program has a bcsel for each float of Modf's fraction, of Frexp's significand and of its exponent's bias. Each of Ldexp's four powers of two is an ishl and an iadd of 1.0's bits.
- For eight colours, among them 0, whole numbers either side of it, −4 and 4, and values down to Frexp's clamp, it answers within 10^−6 what std.math's trunc, frexp and ldexp answer.
- Ldexp of constants folds: 3 by −2 to 0.75; 0.75 by 128 to 0.75 × 2^128, which no one power of two of a float makes; 2^100 by −260, held to −254, to 0; and 1 by 300, held to 254, to infinity.

The V3D's tests are 341, two new. Of 26 mutations, 25 fail them. The one left takes out the check that a struct's two members are of one width: no test hands in such a struct, and spirv-val refuses one.

On the CM5 FacetBoth 1.62's new case, "shipped modf, frexp and ldexp", is 52 of 230400 pixels apart. Each was listed, and each is at the triangles' edge or on a step of the shader, where the cores' interpolation and the V3D's fall either side:

| Pixels | Where | The step |
|---|---|---|
| 8 | The triangles' edge | |
| 6 | c.x crosses a whole number | R by 64 (the fraction) and A by 16 (the whole) together |
| 1 | c.y crosses a whole number | R by 16 |
| 12 | x or y times 7 crosses a whole number | B by Ldexp's step there: 3.4, 9.1 or 22.8, seen as 3 or 4, 9 and 23 |
| 2 | c.z crosses a power of two above 0 | G by 32 − 16: the significand halves, the exponent grows |
| 6 | c.z crosses a power of two below 0 | G by 32 + 16; A puts these at c.z = −2^k |
| 17 | c.z within an octave of 0, under the clamp of −4 | G by 32, or by under 8; A puts these at c.z = 0 |

With the cores' function made wrong on purpose the case is 46,565 apart. The other 288 cases are each as they were at 1.197, and FacetProbe is 890 of 890.

**Then the packing of snorms and unorms**, facet.library 1.199.

- **The packings**, PackUnorm4x8, PackSnorm4x8, PackUnorm2x16 and PackSnorm2x16, are NIR's pack_unorm_4x8 and the others (vtn_glsl450.c:606-609). The V3D's lower_pack_* have them lowered (v3dv_pipeline.c:179-180, 183-184; nir_opt_algebraic.py:2757-2780, the forms of no has_pack_32_4x8):
  - v is held to 0 to 1 by an fsat, or to −1 to 1 by an fmin of an fmax; multiplied by 255, 65535, 127 or 32767; rounded to even; and made an integer, f2u32 or f2i32.
  - Then pack_uvec4_to_uint or pack_uvec2_to_uint, which lower_to_scalar (:203) has nir_lower_alu_width lower (nir_lower_alu_width.c:276-298): each float's low byte or half, extract_u8 or extract_u16 at 0, shifted to its place and or'ed, the first float's lowest.
- **The unpackings**, unpack_unorm_4x8 and the others (vtn_glsl450.c:612-615), are lowered by lower_unpack_* (v3dv_pipeline.c:181-182, 185-186; nir_opt_algebraic.py:2787-2813). The vector of the word's places is made floats by u2f32 or i2f32 and divided by the same numbers, the fdiv a times the frcp of b, which folds. The signed are then held to −1 to 1, as −128 and −32768 would be past it.
- **The extracts** are lower_extract_byte's and lower_extract_word's (v3dv_pipeline.c:168-169; nir_opt_algebraic.py:2740-2754): unsigned, shifted down and masked; signed, shifted up to the top and arithmetically down. Their constants are worked out as they are made, and a shift of 0 is not made. Either would be a step made only for the rules to take out, and the 256 steps would not hold the shaders.
- **New rules**, for i in 1, 2, 16 and 24 (nir_opt_algebraic.py:702-714): an ishl of an iand of the bits the shift keeps is the ishl alone, and an iand of an ishl or a ushr by the bits the shift leaves is the shift alone. ishr and ushr by 0 are their operand (:1803, :1805). So a packing's last place is shifted without its mask, and an unsigned unpacking's last place is shifted down without one.
- A float of a constant is a constant of its own, and a vector of constants one constant, as nir_opt_constant_folding makes them, so that a packing or an unpacking of constants folds.
- On the V3D, f2i32 of an fround_even is one FTOIN, and f2u32 of one an FROUND and an FTOUZ (nir_to_vir.c:1466-1482).
- The host's evaluator works out fsat (nir_opcodes.py:265) and fround_even.
- Rules :2820-2828, which fold an unpacking packed again without rounding, are not ported: what the packing functions make is rounded.

Still left out: PackHalf2x16 and UnpackHalf2x16, next; PackDouble2x32 and UnpackDouble2x32, which are of 64-bit floats, and facet has none (shaderFloat64 is false); Modf and Frexp of a pointer; Determinant and MatrixInverse; and the interpolation functions.

Results:
- **The references.** One shader of all eight is 298 steps, past the 256, so there are two:
  - glslc_packing_bytes, 308 words: PackUnorm4x8 and PackSnorm4x8 of the colour made −1.5 to 1.5, each unpacked again, and PackUnorm2x16 of it unpacked in bytes;
  - glslc_packing_halves, 285 words: PackUnorm2x16 and PackSnorm2x16, each unpacked again, and PackSnorm4x8 unpacked in halves.

  The packing of one width read in the other tells the places' order.
- **The programs:**

  | | iand | ishl | ishr | ushr | ior | f2u32, f2i32 | u2f32, i2f32 | FTOIN | FROUND, FTOUZ |
  |---|---|---|---|---|---|---|---|---|---|
  | Bytes | 13 | 10 | 4 | 6 | 7 | 2, 1 | 2, 1 | 4 | 6, 6 |
  | Halves | 6 | 7 | 4 | 1 | 5 | 1, 2 | 1, 2 | 6 | 2, 2 |

  Each packing of four is three iands, three ishls and three iors, and of two one of each. Each unsigned unpacking of four is three iands and three ushrs, and of two one of each. Each signed unpacking of four is three ishls and four ishrs, and of two one ishl and two ishrs.
- **The values.** For eight colours, among them 0, both ends and past them, and negatives and positives in every place, each answers within 10^−6 what GLSL's definitions answer, rounded to even.
- **Constants** fold, among them 2.5/255, which times 255 is 2.5 and packs to 2; 0.5, which times 255 is 127.5 and packs to 128; and 0x80, which unpacks to −1.
- A packing that answers other than a uint, or an unpacking other than its vector, is refused. Without that check the walk crashes on one.
- The rules' test has 13 cases more: each rule, the constant either side, and shifts and masks it must leave alone.

The V3D's tests are 344, three new. PackDouble2x32 is now the call the refusal test turns Fract into. Of 38 mutations, all 38 fail them.

On the CM5 FacetBoth 1.63's new cases, "shipped packing in bytes" and "shipped packing in halves", are each 8 of 230400 pixels apart, the 8 at the triangles' edge. With the cores' functions made wrong on purpose they are 46,171 and 46,482 apart, fewer than 46,565 where red is already at 1. The other 289 cases are each as they were at 1.198, and FacetProbe is 890 of 890.

**Then the packing of halves**, facet.library 1.200.

- **PackHalf2x16** is NIR's pack_half_2x16 (vtn_glsl450.c:610). lower_pack_half_2x16 (v3dv_pipeline.c:187) has nir_lower_alu_width lower it to pack_half_2x16_split of the vector's two floats (nir_lower_alu_width.c:246-252): the first float's half in the low 16 bits, each half the nearest, a tie to the even (nir_opcodes.py:1059-1060). On the V3D that is one VFPACK (nir_to_vir.c:1809-1811).
- **UnpackHalf2x16** is unpack_half_2x16 (vtn_glsl450.c:616), which lower_unpack_half_2x16 (v3dv_pipeline.c:188) has lowered to the vec2 of f2f32 of each half of unpack_32_2x16 (nir_lower_alu_width.c:267-274).
  - nir_lower_pack (vir.c:2051) makes that unpack_32_2x16_split_x and split_y (nir_lower_packing.c:61-62), which lower_unpack_32_2x16_split (v3dv_pipeline.c:191) makes u2u16 of the word and of the word shifted down by 16 (nir_opt_algebraic.py:2271-2272).
  - u2u16 of a 32-bit value is a MOV (nir_to_vir.c:1599-1611), and f2f32 of a 16-bit one an FMOV of its low half (:1575-1578).
  - Copy propagation puts each FMOV's unpack into what reads it, and try_opt_extract_h16 (vir_opt_alu.c:62) makes the low half of the shifted word the high half of the word, so the shift goes.
- Two new integer operations, pack_half and half_float. The host's evaluator and its folding of constants work them out with Zig's f16, which rounds to the nearest even.

Still left out: PackDouble2x32 and UnpackDouble2x32, which are of 64-bit floats, and facet has none (shaderFloat64 is false); Modf and Frexp of a pointer; Determinant and MatrixInverse; and the interpolation functions. Of GLSL.std.450's packing functions, only the doubles' are missing.

Results:
- **The reference**, glslc_packing_half, 360 words:
  - PackHalf2x16 of the colour made −3 to 3, unpacked again, and its halves' bits read as integers, which tells the halves' order;
  - and 1 + k/4096, with k = floor(16 · colour) of z, and the negative of it of x, packed and unpacked. 1 + k/4096 lies on a half, or a quarter, a half or three quarters of the way to the next, so how far each moves, in 4096ths, e, says how VFPACK rounds. To the nearest, a tie to the even, that is 0, −1, ±2 by the half's last bit, and +1; toward zero it would be 0, −1, −2 and −3.

  A first shader measured instead how far x = c.z · 100 rounds, relative to x, in 2048ths. That term moves by 2048/|x| times any difference between the two devices' interpolated values of x, and the case was 45,693 pixels apart, most of them by 5 to 9 steps of a channel, the same way.
- **The program.** Two pack_half, each a VFPACK, beside the two that write the colour to the tile buffer. Four half_float, each an `.l` or `.h` unpack of what reads it. One SHR is left, of `xy >> 16`, which the shader reads as an integer.
- **The values.** For eight colours, each answers within 10^−6 what GLSL's definitions answer. Their values of k take all four places, and ties both ways: k = 6, 10 and 14.
- **Constants** fold:
  - (1, −2) packs to 0xC000_3C00;
  - 1 + 2^−11 and 1 + 3 · 2^−11, each halfway between two halves, pack to the even of their two, 0x3C00 and 0x3C02;
  - 65520 packs to infinity, 0x7C00, the even, and 65519 to 65504, 0x7BFF;
  - 0x3C00_C000 unpacks to −2 and 1.
- A PackHalf2x16 that answers other than a uint, or an UnpackHalf2x16 other than a vec2, is refused, as the other packings are. Without that check the walk crashes on one.

The V3D's tests are 346, two new. Of 13 mutations, 11 fail them. Of the other two:
- one takes half_float out of the unary operations, which changes nothing: a unary step's second operand is 0, and nothing reads it;
- the other swaps VFPACK's operands, which only the board sees. With that driver on the CM5 the new case is 46,565 pixels apart.

On the CM5 FacetBoth 1.64's new case, "shipped packing of halves", is 32 of 230400 pixels apart, each listed:
- the 8 at the triangles' edge;
- 21 on a step of k that the two devices' interpolations fall either side of, each 1 or 3 4096ths, the size of e's step there;
- 3 on c.x = 0, by 3 or 4, where a half's bits go with the logarithm of a small value.

So VFPACK rounds to the nearest even. With the cores' halves rounded toward zero on purpose the case is 29,585 apart, and with the cores' function made wrong on purpose 46,565. The other 291 cases are each as they were at 1.199, and FacetProbe is 890 of 890.

**Then Determinant and MatrixInverse**, facet.library 1.201.

- **Determinant** is vtn's build_mat_det (vtn_glsl450.c:79-89, 634-637): build_det (:53-77) multiplies column 0 by the vector of its minors, each the determinant of the matrix without that row and column 0 (build_mat_subdet, :28-51), and adds the products' differences in pairs. A 2x2 matrix's minor is the one float left; a larger one's is each other column swizzled to all but the row, a construct of its parts as nir_swizzle makes one.
- **MatrixInverse** is matrix_inverse (:91-121, 639-642): the adjugate, column c's row r the minor without row c and column r, negated where r + c is odd, times the frcp of the determinant. The inverse is held as a matrix value is, for OpCompositeExtract to read.
- Both are of a square matrix alone, as SPIR-V has them; a Determinant that answers other than a float, a MatrixInverse other than its matrix, and either of a matrix not square are refused.
- vtn builds the determinant again for the inverse, and builds the same minors more than once; on the V3D nir_opt_cse shares them (vir.c:2099). This compiler's nir_opt_cse (`Order.cse`, in the algebraic pass since 1.157) shares them too, but only once they are built: until then each is a step of its own, and the 256 steps are counted as steps are made. (Corrected at 1.202: this said the compiler has no CSE.)

Still left out:
- MatrixInverse of a mat4. vtn's cofactors are its 16 minors, each a mat3's determinant, and the determinant again: past the 256 steps, so it is refused (`Error.Steps`). A mat4's determinant is four such minors, and they are most of glslc_determinant4's 160 steps; the inverse's 16 are four times as many, so not building the determinant twice would not be enough.
- PackDouble2x32 and UnpackDouble2x32, which are of 64-bit floats, and facet has none (shaderFloat64 is false).
- Modf and Frexp of a pointer.
- The interpolation functions.

Results:
- **The references:**
  - glslc_matrix_inverse, 450 words: Determinant and MatrixInverse of a mat2 and a mat3 of the colour made −1 to 1, far from singular, the inverses' floats weighted each its own way, so that a float of the wrong row or column shows. Its program is 180 steps and 59 instructions, with an frcp for each inverse.
  - glslc_determinant4, 349 words: Determinant of a mat4, of its upper left mat2 and of the mat2's transpose, and a mat2x3 of it times a vec2. Its program is 160 steps and 56 instructions. One shader of the mat4's and two mat3s' determinants was past the 256 steps.
  - glslc_inverse4, 223 words: MatrixInverse of the mat4, which is refused.
- **The values.** For eight colours each answers within 10^−5 what the matrices answer by other means: the mat2's inverse its closed form, the mat3's the cross products of its columns over their triple product, and each determinant by elimination in f64.
- The refusal test has the Determinants answer a vec4, then has one read the mat2x3, and has the MatrixInverses answer a float.

The V3D's tests are 350, four new. Of 13 mutations, all 13 fail them.

On the CM5 FacetBoth 1.65's new cases, "shipped matrix inverse" and "shipped determinant of a mat4", are each 8 of 230400 pixels apart, the 8 at the triangles' edge. With the cores' function made wrong on purpose each is 46,565 apart. The other 292 cases are each as they were at 1.200, and FacetProbe is 890 of 890.

**Then SPIR-V's bit operations**, facet.library 1.202: OpBitCount, OpBitReverse, OpBitFieldInsert, OpBitFieldSExtract and OpBitFieldUExtract, GLSL's bitCount, bitfieldReverse, bitfieldInsert and bitfieldExtract. They are NIR's bit_count (vtn_alu.c:1074-1080), bitfield_reverse (:330), bitfield_insert, ibitfield_extract and ubitfield_extract (:327-329), which v3dv has lowered (v3dv_pipeline.c:172-175). The V3D has no BFE, BFM or BFI, so:

- **bit_count** is lower_bit_count's count in parallel (nir_lower_alu.c:96-112): pairs, nibbles and bytes summed with masks, then multiplied by 0x01010101 and shifted down by 24.
- **bitfield_reverse** is lower_bitfield_reverse's five swaps (nir_lower_alu.c:49-91): of odd and even bits, of pairs, nibbles and bytes, and of the halves.
- **ibitfield_extract** shifts the word up to the top of the field and arithmetically down by 32 − bits, and is 0 where bits is 0 (nir_opt_algebraic.py:2932-2938). **ubitfield_extract** shifts it down and masks it with (1 << bits) − 1, all ones where bits is 32 (:2940-2946): a shift is by its amount's low five bits.
- **bitfield_insert** is the base's bits outside the mask ((1 << bits) − 1) << offset, or'ed with the insert shifted and masked, and the insert itself where bits is past 31 (:2963-2970). The rule builds the mask twice, and nir_opt_cse leaves one; so does this.
- Offset and Count are one integer whatever Base is. nir_build_alu reads a one-component source in every component, and a construct of the one integer repeated reads it here.
- A constant Count's comparisons are nir_opt_constant_folding's bools, and the bcsel of one its arm (nir_opt_algebraic.py:1933-1934), so the guard is not made; a repeated constant is a constant.

Results:
- **The reference**, glslc_bits, 460 words:
  - the colour made 16 steps a channel, its bits spread over a uvec2 by multiplying;
  - a field of 0 to 32 bits at an offset that keeps it in the word;
  - each result's bits hashed into a channel's top 8, so that a wrong bit shows.

  Its program is 182 steps and 107 instructions.
- **The values.** For 27 colours, of 0, 7 and 15 in each channel (fields of 0, 14 and 32 bits at every offset they allow), and the eight packing colours, each answers within 10^−6 what GLSL's definitions answer: @popCount, @bitReverse, and each field worked out in 64 bits.
- **Constants** fold: bitCount and bitfieldReverse of 0xF00D_1234, and either extract and the insert of fields of 0, 8, 12 and 32 bits.
- **A constant Count** takes the guards away. glslc_bits keeps two ieq and one ult, one for each guard, as nir_opt_cse takes each float's comparison of the one count for the first's. With each Count made the module's int 4, none is left.

The V3D's tests are 353, three new. Of 16 mutations, all 16 fail them.

On the CM5 FacetBoth 1.66's new case, "shipped bit operations", is 42 of 230400 pixels apart, each listed:
- the 8 at the triangles' edge;
- 34 where the two devices' interpolations fall either side of a step of q: 14 of q.x, 8 of q.y and 12 of q.z. Each GPU pixel there is exactly the shader's answer for a q one step away in that channel. The answers of all 4,096 q were worked out to tell.

With the cores' function made wrong on purpose it is 46,565 apart. The other 294 cases are each as they were at 1.201, and FacetProbe is 890 of 890.

### 60. Compile SPIR-V vertex and compute stages for the V3D **[critical path]**

*V3D compiler* &mdash; conformance-blocking, large, also serves the shim

After: Item 59

The back end is fragment-only and refuses any other stage by name; the vertex and coordinate programs are still generated by the hand-written passThrough/vertexProgram for the varyings a draw carries. Every CTS graphics test supplies a vertex shader, so even a V3D-only run stops here. Needs the Program/Plan/encode pipeline extended to the vertex stage's quite different shape: VPM reads and writes, the coordinate program, and the binner's varying order that _vertices.zig also fixes.

> Verified: compile.zig:2 "a SPIR-V **fragment** module turned into V3D 7.1 instructions"; compile.zig:527 `if (seen.stage != .fragment) return Error.Stage;`; the profile's `.stages = &.{.fragment}`.

**The vertex stage first, facet.library 1.163.** A pipeline whose vertex
stage ships SPIR-V beside its function, and whose fragment program is
compiled (no fixed form), runs its vertex shader on the QPU where it draws
triangles. Mesa's back end compiles it twice, as v3dv does
(pipeline_compile_vertex_shader, v3dv_pipeline.c:1990-2020): the vertex
program, keyed by the floats the fragment program reads (used_outputs,
:1461-1473), and the coordinate program the binner runs (is_coord). The
walk takes gl_PerVertex, a Block of BuiltIn members and no offsets, and
its gl_Position, which v3d_nir_lower_vpm_output keeps for the
fixed-function outputs (v3d_nir_lower_io.c:146-153). Each varying's floats
are stored where the fragment program reads them, at the program's end as
nir_move_output_stores_to_end puts them (vir.c:1121); then come
v3d_nir_emit_ff_vpm_outputs's (v3d_nir_lower_io.c:493-586): 1/Wc, the
coordinate program's position, the place on screen - x and y times the
viewport's scale and 1/Wc, FTOIN (nir_to_vir.c:1466-1472) - the vertex
program's Zs and 1/Wc, and 0 for what the fragment program reads and
nothing stored. An attribute is read a float at a time by LDVPMV_IN at its
row (ntq_emit_load_input, nir_to_vir.c:2934-2981), the floats an output is
made of and no others (nir_lower_io_vars_to_scalar and nir_opt_dce,
vir.c:1093-1106; `compile.liveFloats`), and its size is the highest of
those and one (ntq_setup_vs_inputs, nir_to_vir.c:2385-2410). The VPM
segment is shared by input and output, in sectors of eight
(v3d_vs_set_prog_data, vir.c:860-936). The draw converts the attributes to
four floats a location on the CPU, as it did for the vertex function
(`_vertices.readInputs`), gives each driver location a float attribute
record of them, read by each program as far as it reads
(v3dvx_cmd_buffer.c:2686-2771, GFXH-930's rule with it), and writes each
program's stream with the viewport's words (v3dv_uniforms.c:526-552).

- Where it is not v3dv's: the attributes are converted on the CPU and not
  fetched by the VPM in their formats; and the fragment program reads
  every varying it declares, so the vertex program stores them all, where
  Mesa's linking drops what is not read.
- Still the vertex function, as before, and the pipeline not refused: a
  pipeline that tessellates, or draws lines or points (made triangles of
  on the CPU), or has a fixed form or no fragment stage, or whose vertex
  shader the back end refuses.
- Not ported: gl_PointSize, the clip and cull distances, gl_VertexIndex
  and gl_InstanceIndex, integer attributes, a varying stored twice or a
  float of it at a time; and, for both stages, nir_schedule, which
  v3d_attempt_compile runs on the NIR before it is made VIR
  (vir.c:2118-2140): the VIR is in the order of the steps.
- The compute stage is the item's other half.

**Then gl_VertexIndex and gl_InstanceIndex**, facet.library 1.192.

A vertex program reads VertexIndex and InstanceIndex, which vtn reads as SYSTEM_VALUE_VERTEX_ID and _INSTANCE_INDEX (vtn_variables.c:908-921). Any other built-in of a variable is still refused, and so is either of them in a fragment program.

- **The VPM's rows.** Before its attributes the program loads a row for each of its instance id, base instance and vertex id that it reads, in that order (ntq_setup_vs_inputs, nir_to_vir.c:2416-2438). Each attribute's first float comes after them (ntq_emit_load_input, :2948-2961), and the VPM's input is a float more for each (vir.c:894-899).
- **InstanceIndex** is the instance id plus the base instance (nir_lower_system_values.c:202-208).
- **The coordinate program reads the vertex program's rows.** v3dv compiles both of one NIR, whose system values pipeline_lower_nir gathers once the shaders are linked (v3dv_pipeline.c:1875, 1825-1860); a load the coordinate program does not use is dead code. The driver hands the vertex program's values to the coordinate program's compile in its key.
- **GFXH-1602.** Where the coordinate program reads one of them and none of its first driver location, that location takes a row all the same (nir_to_vir.c:2963-2973), and the draw has the VPM load one float of it (v3dvx_cmd_buffer.c:2730-2737).
- **The shader record** says what each program reads, in the Draw Index record's bits 2 to 4 and 7 to 9 (v3dvx_pipeline.c:434-439).

Where it is not v3dv's:
- The draw numbers its vertices from the lowest it draws, the attributes made floats on the CPU from there, so the VPM's vertex id counts from 0. VertexIndex is it plus a uniform of the first vertex: nir_lower_system_values' load_vertex_id where a driver's ids are zero based (:81-83), which v3dv's are not (v3dv_pipeline.c:212). The uniform, `first_vertex`, comes after Mesa's quniform_contents.
- Each instance is a draw of its own, so its instance id is 0 and its base instance the instance, written with Base Vertex Base Instance before the draw (v3dvx_cmd_buffer.c:2821-2829).

Results:
- glslc_vertex_index reads all three rows and glslc_index_place the vertex id alone. Each program's stream says the rows it reads.
- The coordinate program of glslc_index_place takes GFXH-1602's row.
- A coordinate program told no rows reads its attributes a place sooner.
- A coordinate program that reads none of the rows and not its first driver location takes no row: GFXH-1602's is the built-ins' alone.
- VertexId, which Vulkan has not, is refused, and so is VertexIndex on two variables.
- The V3D's tests are 321, six new. Of 19 mutations, 17 fail them. The check that the built-ins decorate an input variable is behind another: a decoration moved off its variable leaves that an integer attribute, refused first. The test of whether a row's value is read is the same as none: layOut has dropped an unread value's step before the rows are counted.

On the CM5, FacetBoth's 278 cases are each as they were at 1.191. Its two new ones draw glslc's two vertex shaders through "shipped smooth": the first triangle as instances 1 and 2, the second from vertex 3 as instance 2, and `indices_32` from vertex 6. They are 11 and 0 of 230400 pixels apart, at the triangles' edges. With the cores' pictures made wrong on purpose, a red an eighth higher and a place a sixteenth further right, they are 53,595 and 74,374 apart: the V3D draws them with its own programs, not with the vertex function. FacetProbe is 890 of 890.

**Then gl_PointSize**, facet.library 1.193.

A vertex program may store gl_PerVertex's gl_PointSize beside its gl_Position, once each. The clip and cull distances are still refused.

- **Both programs store it.** v3dv sets per_vertex_point_size of any vertex shader that writes it, whatever the pipeline draws (v3dv_pipeline.c:1375-1376 for the vertex program, :1418-1419 for the coordinate program). v3d_nir_lower_vs_early's nir_remove_unused_io_vars keeps it, as it keeps every built-in (vir.c:1104; nir_linking_helpers.c:184).
- **Its row** is after the fixed-function outputs, before the varyings: the vertex program's row 4, after its place, Zs and 1/Wc, and the coordinate program's 6, after its position and place (v3d_nir_setup_vpm_layout_vs, v3d_nir_lower_io.c:427-428). The varyings come a row later, and the store keeps its place among theirs (nir_move_output_stores_to_end).
- **What is stored** is the larger of it and 1.0, nir_lower_point_size's fmax (vir.c:1110-1111). nir_opt_constant_folding folds it where the program writes 1.0.
- **The shader record's bit 0** says the VPM holds it: writes_psiz (vir.c:901-902; v3dvx_pipeline.c:379, :402).

A pipeline that draws points is still drawn with the vertex function, its points made triangles on the CPU, so a triangle is all the V3D draws of these; the point size is in its rows unread.

Results:
- glslc_point_size stores the alpha's eight times, at least 1.0, at row 4, and its colour at rows 5 to 8; its coordinate program stores it at row 6.
- glslc_point_one stores 1.0, with no fmax.
- glslc_point_last stores its colour first and the point size after it, at row 4 all the same.
- A second store of it is refused, as is a store to gl_ClipDistance.
- The V3D's tests are 324, three new. Of 12 mutations, all fail them. The draw's handing the record's bit on is the board's to test.

On the CM5, FacetBoth's 280 cases are each as they were at 1.192. Its two new ones draw glslc_point_size and glslc_point_one through "shipped smooth"; each is 5 of 230400 pixels apart, the same 5, first pixel and worst as "shipped vertex shader", the same program without a point size. With the cores' picture made wrong on purpose they are 70,815 apart and the V3D's pixels as they were: the V3D draws them with its own programs, whose varyings it reads from the rows after the point size's. FacetProbe is 890 of 890.

**Then the compute stage, in the compiler**, facet.library 1.194.

A GLCompute module compiles as v3dv compiles a compute pipeline's shader (pipeline_compile_compute, v3dv_pipeline.c:3320): `compileComputeThroughMesa`. Its `Code.compute` says what v3d_cs_set_prog_data says (vir.c:1024-1034): the workgroup's size, and that workgroups may share a supergroup. The device does not run it yet: its dispatches are still the cores' (`_compute.dispatch`), and the CSD job that would run it is the next step.

- **The workgroup** is LocalSize's, or the WorkgroupSize constant's, which takes its place (spirv_to_nir.c:5294-5299, 7424-7435). More than 256 invocations (V3D_MAX_CSD_WG_SIZE, v3d_limits.h:82) is refused: v3dv runs such a workgroup as a loop of 256 (nir_lower_workgroup_size, v3dv_pipeline.c:3300-3311), which is not ported.
- **The CS payload**'s two words are rf3 and rf2 (nir_to_vir.c:4953-4954). The register allocator already kept them for a compute program.
- **WorkgroupId** is the first word's two halves and the second's low half (:3885-3898), plus the dispatch's base, a uniform each (:3900-3910). Mesa adds the base where it lowers the variable (nir_lower_system_values.c:215-218). **NumWorkgroups** is a uniform each (:3877-3883). These are QUNIFORM_WORK_GROUP_BASE and QUNIFORM_NUM_WORK_GROUPS (v3dv_uniforms.c:645-656), the stream's `work_group_base` and `num_work_groups`.
- **LocalInvocationIndex** is the second word's top bits (emit_load_local_invocation_index, :3509-3514). It takes as many bits as the workgroup's size, or 64 if that is larger, rounded up to a power of two, needs (:4963-4964).
- **LocalInvocationId** is made of the index (lower_cs_local_id_to_index, v3dv_pipeline.c:176). It is the index alone where the workgroup is a line (try_lower_id_to_index_1d, nir_lower_system_values.c:492-508), and else the index's remainder and quotients by the size (lower_id_to_index, :456-483); nir_opt_algebraic makes masks and shifts of a power of two.
- **GlobalInvocationId** is (workgroup id + base) * size + local id (:701-709).

A compute program writes its storage buffers and does atomics on them, as a fragment program does. Workgroup memory is refused, and so is OpControlBarrier, which the profile does not take.

Results:
- glslc_compute_ids, a 16x1x1 workgroup, reads its global id and local index; glslc_compute_grid, 4x4x2, reads its local id, workgroup id and count of workgroups; glslc_compute_atomic adds to a word.
- Their streams, the payload's registers, and the masks, shifts and multiplies are as above.
- A WorkgroupSize constant of (1, 1, 1), (1, 16, 1) or (16, 16, 1) overrides LocalSize.
- A workgroup of no invocation, of more than 256, or of no size said is refused. So are Workgroup memory, a fragment program's built-in or execution mode, a vertex program's built-in, and a built-in twice.
- The V3D's tests are 330, six new. Of 35 mutations, 33 fail them. The other two are checks behind others. A WorkgroupSize constant of other than three integers is one that spirv-val refuses and glslc cannot write. A built-in on something other than an input variable leaves that variable an integer input, or a buffer without its binding, and that is refused first.
- The workgroup id and the local id are made anew for the global id and for the program's own read, as NIR makes them: nir_opt_cse's port makes them one, and a mutation that made them once was no different.

On the CM5 nothing draws or dispatches differently: FacetBoth's 282 cases are each as they were at 1.193, and FacetProbe is 890 of 890.

**Then the compute stage on the V3D, through its dispatcher**, facet.library 1.195.

A compute pipeline goes to the driver as a graphics pipeline does: CreateComputePipelines hands `make_pipeline` the entry's SPIR-V beside its function (`Pipeline.compute_words`), and DestroyPipeline calls `unmake_pipeline` for it. The cores' driver leaves the function to run. The V3D's compiles the words as v3dv compiles a compute pipeline's shader (pipeline_compile_compute, v3dv_pipeline.c:3320), into its own memory with a spill buffer where the program needs one. Where it cannot, the function runs on the cores as it did: words the compiler refuses (a workgroup of more than 256 invocations, Workgroup memory, a barrier), a sampler, which a dispatch has none bound for, or a workgroup other than the entry's.

A dispatch outside a render pass runs on the QPUs where the pipeline has a program, and is a job of the compute shader dispatcher (CSD), as cmd_buffer_dispatch makes one (v3dv_cmd_buffer.c:4464-4487). It is run as it is played, as a frame is at its end.

- **The uniforms** are a draw's, read from what compute pipelines bound: their storage and uniform buffers, and their push constants. NumWorkgroups is the dispatch's count along the axis (QUNIFORM_NUM_WORK_GROUPS, v3dv_uniforms.c:645-651), and the base is 0, the only one a dispatch of Vulkan 1.0 has (QUNIFORM_WORK_GROUP_BASE, :653-656). They go in the chunks a frame's do, which the next frame begins again.
- **The seven words** are cmd_buffer_create_csd_job's (v3dv_cmd_buffer.c:4344-4461), in `csd.configuration`. CFG0 to CFG2 are the counts in their top halves. CFG3 is the workgroups a supergroup packs, v3d_csd_choose_workgroups_per_supergroup's (v3d_util.c:32-99), the batches each takes less one, and the workgroup's size, 0 for 256. CFG4 is the count of batches, less one before V3D 7.1.6. CFG5 is the program's address, with SINGLE_SEG for a program that never switches threads (!c->last_thrsw, vir.c:1041) and THREADING for one of four threads, and PROPAGATE_NANS before 7.1, which has made the bit reserved (:4430-4432). CFG6 is the uniforms' address.
- **The job** is Linux's v3d_csd_job_run (v3d_sched.c:329-383): the caches invalidated, CFG1 to CFG6 and CFG7 written, and CFG0 last, which starts it. It is done at INT_CSDDONE (v3d_irq.c:137-140). After it the caches are cleaned, as Linux always cleans them after a CSD job (v3d_submit.c:535-562). The storage buffers go out of the CPU's caches before the job and are dropped from them after it, as a frame's are.
- **An indirect dispatch** reads its counts on the CPU as it is played. v3dv records a CPU job that reads them (cmd_buffer_dispatch_indirect, v3dv_cmd_buffer.c:4508-4556), and the kernel rewrites the CSD job from them (v3d_rewrite_csd_job_wg_counts_from_indirect, v3d_sched.c:393-436). Here the job is made from them, as a direct dispatch's is. A count the CSD's 16 bits do not hold, which only an indirect buffer can give, runs on the cores.
- **A buffer the program reads and the dispatch has not bound** leaves the dispatch to the function, as a draw leaves one to its vertex function.

`compute_on_device` stays false: it says where compute functions run, and those are still the cores'.

Results:
- `csd.configuration` packs 16 workgroups of 4 invocations into a supergroup of 4, of 8 into one of 2, and of 1 into one of 16. 3 invocations take 16 of 100 workgroups, 5 of 12 and 3 of 3; 24 invocations take 2.
- Its words are as above, one less before 7.1.6 or on a V3D before 7.1. No workgroup along an axis, a count past 16 bits, and a workgroup of no invocation or of more than 256 are no dispatch.
- The V3D's tests are 335, five new. Of 24 mutations, 19 fail them. The other five change nothing: Mesa's two shortcuts, which the loop comes to as well; a tie of unused lanes, which no loop of at most 16 meets before it meets none unused; the mask of the workgroup's size, whose only size past 8 bits, 256, sets the bit a supergroup of one sets anyway; and Mesa's assert of a count of batches of all ones.

On the CM5 FacetBoth 1.59 has two new cases, "shipped compute: writes vertices" and "shipped compute: writes a draw's numbers", whose compute shaders the module ships as SPIR-V. The first dispatches three groups of three invocations, and is 0 of 230400 pixels apart. The second dispatches indirectly into a buffer cleared first, and is 11 apart. Those are the same 11 pixels as "compute: writes a draw's numbers", whose draws it writes the same. With the cores' functions made wrong on purpose they are 85,628 and 64,296 apart: the V3D runs its own programs, not the functions. The other 282 cases are each as they were at 1.194, and FacetProbe is 890 of 890.

**Then Workgroup memory and OpControlBarrier**, facet.library 1.203. A compute program may declare variables in Workgroup memory, GLSL's `shared`, and wait at OpControlBarrier, GLSL's barrier(). They are NIR's load_shared, store_shared and shared_atomic, and its barrier of an execution scope.

- **The layout** is v3dv's: lower_compute lays the variables out with nir_lower_vars_to_explicit_types and shared_type_info (v3dv_pipeline.c:3273-3291), through glsl_get_explicit_type_for_size_align (glsl_types.c:2795-2885).
  - A float or an integer is 4 bytes at 4. A vector of n is 4n bytes at 4n, except a vec3, whose 12 are at 16.
  - An array's elements are its element's size, rounded up to its alignment, apart. Its size is that stride times one less than its length, plus the element's own: the last element is not padded.
  - A struct's members follow one another, each at its alignment. The struct is at its widest member's, and its size is rounded up to it.
  - A matrix is its columns, each a column's size rounded up to its alignment apart: a mat3's are 16 apart.
- **The places.** Each variable is after the ones before it in the module, at its alignment (nir_lower_explicit_io.c:2042-2065). A variable nothing loads, stores or chains through takes no place: v3d_optimize_nir's nir_remove_dead_variables has taken it away (nir_to_vir.c:2253-2257). A pass over the words before they are read finds the pointers named.
- **Loads, stores and atomics** go through the TMU, as a storage buffer's do (ntq_emit_tmu_general, nir_to_vir.c:587-588), from cs_shared_offset. A pointer into Workgroup memory is a chain's base, as a block's member is, and an atomic's barriers are of its semantics with WorkgroupMemory added (vtn_mode_to_memory_semantics, vtn_variables.c:2668-2687).
- **cs_shared_offset** is worked out at the program's start (nir_to_vir.c:4967-4992):
  - the payload's second word shifted down by 16, wg_in_mem;
  - masked to the 16 bits the local index leaves, where the workgroup is more than one invocation;
  - times the shared memory's size, and added to QUNIFORM_SHARED_OFFSET, the stream's new `shared_offset`.
- **OpControlBarrier** is vtn_emit_scoped_control_barrier's (spirv_to_nir.c:2813-2845, :4821-4866).
  - Its memory scope counts only where its semantics order memory of a storage class.
  - Of neither memory nor execution wider than the invocation it is nothing (:2831-2832).
  - Else it is the TMU flushed, BARRIERID into SYNCB, and a thread switch, at which the TSY op blocks (emit_compute_barrier, nir_to_vir.c:3563-3577, :3857-3870). Its execution scope counts wherever it is not NONE (:3863): one of the invocation's execution and the workgroup's memory is a TSY op as well.
  - CrossDevice, QueueFamily and ShaderCallKHR scopes are refused (vtn_translate_scope, :2765-2797).
- **The program says it has a barrier** (has_control_barrier, vir.c:1024-1034). Its supergroup then holds no more batches than half the QPUs' threads, so that two run at once while one waits at a barrier (v3d_csd_choose_workgroups_per_supergroup, v3d_util.c:56-67).
- **The dispatch's shared memory** is the program's size times the dispatch's workgroups, as cmd_buffer_create_csd_job allocates it (v3dv_cmd_buffer.c:4435-4437). It is at 4096, in the frame's chunks.

Where it is not v3dv's:
- The shared memory is carved from the frame's chunks, not a buffer object of its own. A dispatch that cannot have it, or whose bytes are past 32 bits, runs on the cores.
- A workgroup has 16 KiB of shared memory, facet's maxComputeSharedMemorySize (instance/_instance.zig), where v3dv's is 32 KiB (V3D_MAX_COMPUTE_SHARED_MEMORY_SIZE, v3d_limits.h:79). A pipeline past it is refused when it is made (createcomputepipelines.zig), and the compiler refuses it too.

Still left out. Each is marked *facet-wide*, missing whatever the device, or *V3D-only*, left out because of the V3D, which a Radeon port has to do (see "What the V3D port leaves for the Radeon's" below):
- **Kept selections in vertex and compute programs.** `keepSelection` keeps a branch in a fragment program alone (`Error.Branches`), so a conditional store, to shared memory or anywhere, refuses the program. *Facet-wide*: the rule is this port's, not Mesa's, and no feature gates it. It is the next step.
- **A bool in shared memory.** shared_type_info makes it 4 bytes, and vtn and nir_lower_explicit_io load it as a comparison of its word. *Facet-wide*, of no feature.
- **An initializer of a Workgroup variable.** It needs VK_KHR_zero_initialize_workgroup_memory (nir_zero_initialize_shared_memory, vir.c:817-829). *Facet-wide*, and after 1.0.
- **Workgroups of more than 256 invocations.** v3dv runs one as a loop of 256 (nir_lower_workgroup_size, v3dv_pipeline.c:3300-3311); here it runs on the cores. *V3D-only*: 256 is the V3D's limit (V3D_MAX_CSD_WG_SIZE, v3d_limits.h:82), and facet's maxComputeWorkGroupInvocations is 1024.
- **A barrier in another stage**, emit_barrier's TSY op (nir_to_vir.c:3580-3613). Vulkan 1.0 has OpControlBarrier in compute and tessellation control shaders alone. *V3D-only*: tessellationShader is off in v3dv (v3dv_device.c:334), and in facet (getphysicaldevicefeatures.zig:161).
- **wa_glslang_cs_barrier** (spirv_to_nir.c:4828-4842), for a glslang older than glslc's, which wrote barrier() with no memory semantics. *Facet-wide*, of old modules alone.
- **Shared memory past 16 KiB.** *Facet-wide*: facet's limit, where v3dv's is 32 KiB.

Results:
- **The references:**
  - glslc_compute_shared, 420 words, an 8x2 workgroup. A uint at 0, a float[16] at 4, mirrored between two barriers, and a vec3[4] at 80, 16 apart: 140 bytes. A counter each invocation adds to by atomicAdd. Its program is 53 instructions, with two BARRIERIDs and ten thread switches. The first BARRIERID is after a TMUWT for the stores before it; the second is after the loads before it are read back.
  - glslc_shared_layout, 468 words, of a workgroup of 4:
    - a struct of a float, a vec3 and a vec2, at 0, 16 and 32, 48 apart;
    - a mat3 at 192, loaded a column at a time at 192, 208 and 224;
    - a counter at 240: 244 bytes.

    Its program is 82 instructions.
  - glslc_shared_matrices, 288 words: two mat2x3s stored and loaded whole, their columns 16 apart and the matrices 32: 64 bytes.
- **The streams** begin 16, 0x3ff and the size, then `shared_offset`: wg_in_mem's shift, its mask of 10 bits, and its product.
- **The layout's own test** has a vec3 at 16, a vec3[4] of 60 bytes, a vec2 at 8, a mat3 of 48 at 16, and a struct of 40 bytes made 48. It refuses a bool, an array of no length, and a float[4097]. A float[4096], 16 KiB, is laid out.
- **The refusals:**
  - Error.Storage: an initializer of total, a Block struct in Workgroup memory, and a Workgroup variable in a fragment program;
  - Error.Refused: OpControlBarrier in a fragment program;
  - Error.Body: a CrossDevice scope.
- **What makes nothing.** A barrier of the invocation's execution and memory makes nothing. So does one of the invocation's execution and no semantics. One of the workgroup's execution and no semantics is still a TSY op.
- **What takes no place.** A float[16] that nothing names takes none. A uint stored into and never read does, before what follows it. values made a float[4079] leaves 16380 bytes; a float[4080] puts places past 16 KiB and is refused.
- **The supergroups** of 3 invocations on 2 QPUs of 2 threads are 5 workgroups with a barrier and 16 without; 24 invocations on 1 QPU of 2 threads are 1 and 2.
- The V3D's tests are 359, six new. Of 34 mutations, 33 fail them. The other takes shared loads out of the loads a selection's phi may coalesce with (`coalescable`). No compute program reaches that while kept selections are a fragment program's.

On the CM5, FacetBoth 1.67's new case, "shipped compute: shared memory and barriers", is 0 of 230400 pixels apart, 2 at worst. It is three groups of three invocations. Each invocation writes its corner's place into a vec2[3] in shared memory, and after a barrier reads the next corner's. Between two barriers each adds its corner's number to a shared uint, and the triangle's blue is that count, 6, in sixteenths. With the cores' function made wrong on purpose, the count in eighths, it is 62,940 apart: the V3D runs its own program, of shared memory and TSY barriers. The other 295 cases are each as they were at 1.202, and FacetProbe is 890 of 890.

**Then the system values that differ from lane to lane**, facet.library 1.204. A fix: until now no system value counted as differing, so a buffer read at an offset made from one was read through unifa, one word for all the lanes, where v3d reads it through the TMU (ntq_emit_load_unifa, nir_to_vir.c:3315-3317, then ntq_emit_tmu_general). `lanes()` in compile.zig, nir_divergence_analysis's port, now has v3dv's answers for them (its options are nir_divergence_multiple_workgroup_per_compute_subgroup alone, v3dv_pipeline.c:217-218):
- **They differ:**
  - a vertex's id, which VertexIndex is made of (nir_divergence_analysis.c:974-975, :1154);
  - its instance's id, which InstanceIndex is made of: it is the same in every lane only with nir_divergence_vertex, which v3dv does not pass (:572-573);
  - the CS payload's two words, which LocalInvocationIndex and LocalInvocationId are made of (:977-979, :1154);
  - and through them WorkgroupId, which v3dv's option makes differ (:611-615): a supergroup's lanes may be more than one workgroup's (v3d_csd_choose_workgroups_per_supergroup). GlobalInvocationId differs as its parts do.
- **They are the same in every lane:** the first vertex and the base instance, which VertexIndex and InstanceIndex add, and the dispatch's count of workgroups and their base (:240-250, :342, falling through to :410).

Which programs it was wrong for: since 1.192, a vertex program reading a uniform buffer, or a storage buffer, at an offset made from VertexIndex or InstanceIndex. Since 1.194, on the V3D since 1.195, a compute program reading a uniform buffer or a readonly storage buffer at an offset made from an invocation's or a workgroup's id. A buffer the program writes was read through the TMU anyway (1.168), and so is every store. No FacetBoth case did either, and none of their results changes.

It matters for the next step too. A selection whose condition is made from an id is a branch under the execute mask, not a uniform branch (beginIf, to_vir.zig); with the ids counted the same in every lane it would have been the uniform one.

Still left out. Each is marked *facet-wide* or *V3D-only*, as above:
- **The system values after Vulkan 1.0:** DrawIndex, BaseVertex and BaseInstance as variables of their own (VK_KHR_shader_draw_parameters, Vulkan 1.1) and the subgroup's ids (Vulkan 1.1). *Facet-wide*, and after 1.0.
- **The divergence analysis's options are v3dv's**, built into `lanes()`. *V3D-only*: a Radeon port takes radv's own, read from its sources (see the list below).

Results:
- **The references:**
  - glslc_compute_readonly, 333 words, a workgroup of 16. A readonly storage buffer is read at the global id, at the workgroup id plus 128, at the local index plus 256 and at the count of workgroups plus 512. The first three go through the TMU, three ldtmus, and the last through unifa, one ldunifa. Before the fix none went through the TMU.
  - glslc_vertex_tints, 266 words. A uniform buffer's vec4 is read at VertexIndex & 3 and at (InstanceIndex & 1) + 4: eight ldtmus and no ldunifa.
- The V3D's tests are 361, two new. Of 9 mutations, all 9 fail them. Each of the four values that differ made the same in every lane is caught, and so is each of four that are the same made to differ (the first vertex, the base instance, the count of workgroups, their base), and the switch taken out.

On the CM5, FacetBoth 1.68's new case, "shipped compute: reads a buffer at each invocation's id", is three groups of three invocations. Each reads its corner's place from a readonly buffer, which the case has written, at its global id, adds the push constants and writes the corner out for the draw. With 1.203's facet.library and v3d.fdriver it is 63,548 of 230,400 pixels apart, 122 at worst: the bug, on the V3D. With 1.204's it is 0 of 230,400 apart, 2 at worst. The other 296 cases are each as they were at 1.203, and FacetProbe is 890 of 890.

**Then kept selections in vertex and compute programs**, facet.library 1.205. Since 1.171 only a fragment program kept a selection a branch: `keepSelection` answered a vertex or a compute program's with Error.Branches. That rule was this port's. ntq_emit_if and the passes before it have nothing of the stage's (nir_to_vir.c:4355-4573), and 1.204 counts the ids that tell a branch under the execute mask from a uniform one. So the selections that stay branches in a fragment program do so in any stage now: a store in an arm, to a storage buffer or to shared memory; a buffer read in one; and arms DontFlatten or the limit keeps.
- **The code is a fragment program's.** Where the condition differs from lane to lane, it is ntq_emit_nonuniform_if's (:4455-4561). The execute mask is set where a lane does not take the arm, and the arm is jumped over where no lane does, unless it is too small to pay (is_cheap_block, :4325, :4505-4507). The TMU's addresses in it are written under the mask. Where the condition is the same in every lane, it is ntq_emit_uniform_if's jump, msfign P (:4396-4400), which Mesa sets whatever the stage.
- **nir_opt_dead_cf**, in every stage, which v3d's loop runs right after nir_opt_dce (nir_to_vir.c:2263-2264). An if with nothing left in its arms and no phi after it is dead (node_is_dead, nir_opt_dead_cf.c:171-271) and is taken out (dead_cf_block, :293-296). This is the coordinate program's case. nir_remove_unused_io_vars leaves it no varyings (vir.c:1097-1105), so an arm that only makes the colour is empty there. So is a vertex program's whose fragment program does not read that varying.
- **nir_opt_peephole_select on an emptied if.** An emptied if whose phis are still read is flattened by the next nir_opt_peephole_select. Arms of no instruction are within any limit, DontFlatten's 0 among them (nir_opt_peephole_select.c:336-341, :548-553). Each phi becomes a bcsel of the condition and its two ways' floats, and the if goes (nir_opt_peephole_select_block, :577-603). `flattenEmptied` does both in the loop: what nir_opt_dce leaves of a kept selection's arms is checked after it, and an emptied one's phis still read become selects, its marks go, and its condition, read by nothing now, goes in the next round's dce. An if with no phi is the same with no select made.
- **Two fixes the vertex programs needed:**
  - `liveFloats` decides which of the attributes and of the VPM's values the program loads, and it counted only an output or a discard as live. So a value that only a branch's condition read was never loaded: the vertex id in `(gl_VertexIndex & 1) == 0`. Its register was never written, and the compile failed in to_qpu. A begin_if is live now, as nir_opt_dce keeps a nir_if's condition. A phi reads only the float it chooses of each way, as nir_lower_phis_to_scalar leaves it, which keeps an attribute no wider than Mesa's.
  - An attribute's LDVPMV_IN set its float directly, where Mesa's ntq_emit_load_input goes through ntq_store_def (nir_to_vir.c:2980-2982). Where the float is a phi's false way, coalesced into the phi's register, nothing wrote that register. It goes through `storeDef` now.

Still left out. Each is marked *facet-wide* or *V3D-only*, as above:
- **A kept selection that dce leaves only flattenable steps in.** Where nir_opt_dce takes out what kept the selection a branch, a read or a texture, but other steps remain in its arms, Mesa's next nir_opt_peephole_select flattens it if they are under its limit. Here it stays a branch. It is met in the coordinate program of a vertex shader whose arm makes both the place and the colour. *Facet-wide*: the decision to keep is made once, in the walk, before the passes. The result is the same; the code is longer.
- **A vertex output stored in an arm** still refuses the program (Error.Branches). The walk keeps gl_Position and each varying as the one value stored (nir_move_output_stores_to_end is not ported); glslc -O stores them after the merge. *Facet-wide*.
- **A kept selection in another.** Only one at the top level is kept, in any stage (`depth != 1`). *Facet-wide*.

Nothing here is the V3D's alone, so the list for the Radeon's has nothing new.

Results:
- **The references:**
  - glslc_compute_branch, 255 words: a store in an arm on a value read at the global id, and a load beside it. The execute mask is set once, the arm is jumped over with `bu.allna`, and both TMU addresses are written under the mask.
  - glslc_compute_uniform_branch, 217 words: a store in an arm on a push constant. A `bu.anynap`, and no mask.
  - glslc_compute_shared_branch, 293 words: one invocation stores into shared memory in its arm, its address under the mask. The barrier is after the branch, at the top level.
  - glslc_vertex_branch, 279 words: a uniform buffer read in an arm, four ldtmus behind a TMUAU written under the mask. Its coordinate program has no branch and pushes no flags: 16 instructions. Nor does a vertex program whose fragment program reads no colour.
  - glslc_vertex_kept, 417 words: two selections DontFlatten keeps, on the vertex's number. The vertex program has two branches. The id is loaded for their conditions alone, c is three floats wide, and the place's x and y are loaded into the registers the arm then writes under the mask. The coordinate program has the place's branch alone.
  - glslc_vertex_kept_phi, 284 words: DontFlatten, a read in the arm, and a place the merge chooses between two values made before it. The vertex program has the branch; its coordinate program has four bcsels and no branch.
- The V3D's tests are 367, six new. Of 9 mutations, all 9 fail them: the emptied if's flattening and its four parts, the marks no longer kept by dce, `liveFloats`' two changes, the stage's rule put back, and the LDVPMV_IN's store.

On the CM5, FacetBoth 1.69 has two new cases.
- **"shipped compute: kept branches, under the mask and uniform"** is 0 of 230400 pixels apart, 2 at worst. It is three groups of three invocations, each writing its corner of a triangle through three kept selections. The red is read and stored in an arm where the corner's own place is above -0.5, under the execute mask. The green and the alpha are stored where the push constants' x and y are above 0; the first is, the second is not. With the cores' function made wrong on purpose, the green's branch not taken, it is 53,998 apart.
- **"shipped vertex branches"** draws the vertex and instance index case's triangles through a vertex shader of two DontFlatten branches. It moves the even vertices' place, which the coordinate program has too, and gives the vertices from the fourth on another colour, which only the vertex program has. It is 12 of 230400 apart, 192 at worst, the triangles' edges; "shipped vertex and instance index", of the same draw, is 11. With the cores' function moving the odd vertices instead, it is 71,907 apart.

The other 297 cases are each as they were at 1.204, and FacetProbe is 890 of 890.

**Then outputs as variables of the function's own**, facet.library 1.206. Until now each output was the one value stored into it. gl_Position, gl_PointSize and a varying were stored once each, and the colour where the body stored it last. A store into any of them in an arm refused the program (Error.Branches), and so did a second store into a vertex output (Error.Outputs). Mesa has none of these rules. v3dv runs nir_lower_io_vars_to_temporaries on the outputs (v3dv_pipeline.c:399-400), which makes each a variable of the function's own. A copy at the function's end stores what it holds into the real output (emit_output_copies_impl, nir_lower_io_vars_to_temporaries.c:133-144). nir_lower_global_vars_to_local and nir_lower_vars_to_ssa then make it values, as any other variable (v3dv_pipeline.c:408, nir_to_vir.c:2240). So an output may be:
- stored in an arm;
- stored more than once;
- stored a float at a time, through a chain;
- and loaded.

glslang without optimization writes all of these, and the CTS's shaders are glslang's.
- **The walk** gives each output a variable when it is declared: a varying, the colour, and gl_PerVertex's gl_Position and gl_PointSize. nir_split_per_member_structs makes each of those two a variable of its own (vk_nir.c:321-325). A store into one, or a load of one, is a variable's: in an arm, a phi at the merge, and a bcsel where the selection is flattened. A chain to a float of gl_Position, or of a varying, is a float of a variable (deref_vec_component, nir_lower_vars_to_ssa.c:586-602).
- **The copies.** `copyOutputs` reads the variables where the walk ends.
  - A float nothing was stored into is an undef, and nir_opt_undef takes its store out (opt_undef_store, nir_opt_undef.c:143-179). So an output never stored is not stored, and of a varying stored in part only those floats are. The rows the fragment program reads and nothing stored are 0, as before. A varying declared and never stored takes none of the eight places.
  - Where an output's variable still holds the value last stored into its whole, the copy stores that value. nir_lower_vars_to_ssa gives the copy's load the store's def (nir_lower_vars_to_ssa.c:723-733).
- **The order of the stores, a fix to 1.193.** nir_move_output_stores_to_end puts them in the order of their slots, the position last (nir_move_output_stores_to_end.c:86-93), and VARYING_SLOT_PSIZ is before VARYING_SLOT_VAR0 (shader_enums.h:350, :381). 1.193 kept the order of the OpStores, which put a point size stored after the varyings after them. It is before them now, and the varyings are in the order of their locations. Each float was at its right row either way, so no picture changes; the order of the instructions does.

Still left out. Each is marked *facet-wide* or *V3D-only*, as above:
- **gl_ClipDistance and gl_CullDistance** are still refused (Error.Outputs). They need nir_lower_clip_vs. Both are on the list below already: shaderClipDistance is *facet-wide*, and shaderCullDistance is *V3D-only*.
- **An output of an array or a struct**, such as `out vec4 colours[2]` or an output block, is refused, as before. *Facet-wide*: nir_lower_io_vars_to_scalar and nir_lower_io take them apart (vir.c:1096-1097, :1114-1116), and no feature gates them.
- **The outputs' variables are among the 32** a program may have (`most_locals`): a vertex program of eight varyings has 22 left for its own. *Facet-wide*: Mesa has no such limit.

Nothing here is the V3D's alone, so the list for the Radeon's has nothing new.

Results:
- **The references**, each compiled without -O:
  - glslc_outputs_arms_frag, 207 words: the colour stored in both arms. Four bcsels and no branch, 19 instructions.
  - glslc_outputs_kept_frag, 230 words: the colour stored, then sampled into in an arm, which keeps the selection a branch. The colour is its four phis: the sample's floats are written into their registers under the mask.
  - glslc_outputs_arms_vert, 420 words:
    - gl_Position stored, and its y again through a chain in an arm;
    - a varying stored, three of its floats again in the arm, and its alpha loaded and halved after the merge;
    - a second varying stored in the other arm alone.

    That is three bcsels: the y, and the red and blue of the colour, whose green is c's green both ways. The second varying is p.xy, its phi of an undef taken out. The coordinate program has the y's bcsel alone.
  - glslc_outputs_part_vert, 255 words: two of a varying's floats stored. The other two rows are given 0 after the fixed-function outputs.
  - glslc_outputs_kept_vert, 383 words: gl_Position and a varying stored in the arms of a selection a uniform buffer's read keeps. The vertex program has eight phis, and the coordinate program has the position's four.
  - glslc_outputs_unstored_vert, 421 words: nine varyings declared and eight stored.
  - glslc_shipped_outputs and glslc_shipped_vertex_outputs: FacetBoth's two new shaders, word for word.
- **The tests.** The V3D's tests are 377, ten new. Three changed:
  - the point size's stores are before the varyings';
  - a second store of it is the value the copy stores, where it was refused;
  - the tests that count a program's variables count the function's own, without the outputs'.

  Of 12 mutations, all 12 fail them.

On the CM5, FacetBoth 1.70 has two new cases, each a shader glslc compiled without -O:
- **"shipped outputs in arms"** is 8 of 230400 pixels apart, 204 at worst: pixels where the colour's red is near 0.5, on whichever side of the selection each device's interpolation puts it. "shipped variables", of the same kind, is 8 apart too. Its fragment shader stores the colour in both arms of a selection, a float of it again in the second, and its alpha after the merge. With the cores' function losing the arm's second store, it is 12,423 apart.
- **"shipped vertex outputs in arms"** is 6 apart, 192 at worst, the triangles' edges. Its vertex shader stores the place and the colour, then stores floats of each again in an arm the back end flattens, where the place's x is above 0. On the vertex's number it stores the place's x again in an arm that DontFlatten keeps a branch, and the colour's alpha after the merges. With the cores' function losing the arm's swap of red and blue, it is 37,922 apart.

The other 299 cases are each as they were at 1.205, and FacetProbe is 890 of 890.

**Then selections kept in the arms of selections kept**, facet.library 1.207. Until now a selection kept a branch had to be at the top level. `keepSelection` refused one in an arm (Error.Branches), and so did any program whose kept arm held a selection a branch. Mesa has no such rule:
- ntq_emit_cf_list emits a nir_if wherever it meets one, in an arm too (nir_to_vir.c:4809-4818).
- ntq_emit_if takes the uniform form only outside non-uniform control flow (:4562-4573).
- Inside it, ntq_emit_nonuniform_if makes the inner mask from the outer's. It keeps the execute it finds and folds the inner condition into it with a MOV of NORNZ, or ANDZ where the condition is inverted (:4482-4492).
- nir_opt_peephole_select flattens no arm that holds control flow (nir_opt_peephole_select.c:538-541). So the selection that holds a kept one is kept too.

The parts:
- **The walk.** A selection's arms are regions in the region it is in (`Work.region_parent`), where until now they were regions of the top level.
  - `dominates` follows a step's regions out. It is nir_opt_cse's dominance (nir_opt_cse.c:76) on this structured program: a step dominates one in its own region or in a region inside that.
  - A selection flattened gives its arms' steps to the region it is in, and gives its regions back where they were the last. glslc_flat_many has seventeen selections in a row, and they fit in the 33 regions.
  - A selection that holds a kept one is kept. Its arm then holds control flow, which no limit flattens.
- **The order.** The steps are laid outermost first: a kept selection's marks around its arms, each arm laid the same way.
- **The back end** keeps a stack of the branches it is in, `most_nesting` deep. A branch's phis are those of its condition after its end_if, up to the next mark of the level it is at. The two selections of SameCondition share one comparison, and each keeps its own phis.
- **The coalescing, nir_from_ssa's as a whole.** Until now it tested a phi against its true way's float only, which was enough while no web met another selection's. NestedWebs shows where it is not: a phi's two floats are made before the outer selection, one each way. The old test would have given z and f one register, but z is live where f is made, and f writes over it.
  - fromSsa now coalesces each way's end in the order of its blocks (aggressive_coalesce_block and aggressive_coalesce_parallel_copy, nir_from_ssa.c:404-443).
  - It merges whole webs (merge_merge_sets, :198-223).
  - It tests every pair of their nodes against each other (merge_sets_interfere, :232-304).
  - Liveness is nir_def_is_live_at's (nir_liveness.c:272-291). A float is live where a step that may run later reads it. A step in the other arm of a selection whose true arm the float is in may not run later.
  - A way's copies are each an instruction of its own, in the order of the phis (nir_from_ssa.c:342-352). So a float that a later copy at a way's end reads is live where the copies before it are made. LaterCopyReads shows it: a uniform float the inner selection's second phi takes is not put in the web its first phi's copies joined.

Two fixes to wrong code that 1.206 shipped. Each is shown on the 1.206 compiler:
- **A float that every float of a vector operation reads.** nir_lower_alu_to_scalar (nir_to_vir.c:2259) makes an instruction of each float, in order (nir_lower_alu_width.c:407-432). So a scalar that a scale reads is live where the scale's first float is made (search_for_use_after_instr, nir_liveness.c:247-256). facet looked for reads at later steps only. A float made before an arm, scaled by in it and brought by the other way, shared the register of the product's first float. The three products after it then read it written over. `readAgain` counts a read at a later float of the same step, and `madeOf` follows a construct to the float it names.
- **A comparison emitted again where it reads a float in a web.** ntq_emit_bool_to_cond emits a bool's comparison again when the flags no longer hold it. ntq_get_alu_parent will not do that for a comparison that reads a load_reg, because a store_reg since may have written the register (nir_to_vir.c:1248-1255). It tests the bool instead (:1277-1281). facet compared again. In a kept arm, three bcsels on v.y < 0.5, with v.y in the red phi's web, compared v.y twice after the first bcsel had written that register under the mask. `readsWeb` is Mesa's rule.

Still left out. Each is marked *facet-wide* or *V3D-only*, as above:
- **nir_opt_collapse_if of a kept selection.** An inner selection kept, all of the outer's true arm, neither with a false arm, is refused (Error.Branches): glslc_nested_collapse, and DeepCostly. Mesa makes the two one selection on the iand of their conditions (nir_opt_peephole_select.c:413-506), which keeps the inner arm a branch. *Facet-wide*, and the next step, 1.208.
- **nir_opt_if's opt_if_evaluate_condition_use** (nir_opt_if.c:1016, run by v3d's loop at nir_to_vir.c:2300), not ported since 1.171, with opt_if_merge and opt_if_simplification. Since 1.207 there is a program it changes: a selection on the condition of the one it is in is kept a second branch. Mesa takes the condition to be true in that arm, and nir_opt_dead_cf then takes out the inner selection. *Facet-wide*: the program is right, only longer, and no feature gates it.
- **The limits.** Selections nest 8 deep (`most_nesting`), 8 are kept in a program (`most_kept`), and their arms are 33 regions. *Facet-wide*: Mesa has none of these limits.

Where the port is not Mesa's but the program is the same: the webs are numbered in the order of the begin_ifs, and Mesa's merge sets in the order of the blocks. That changes which register a web gets, not what the program computes.

Nothing here is the V3D's alone, so the list for the Radeon's has nothing new.

Results:
- **The references**, each compiled with -O but where said:
  - glslc_nested_kept, 262 words: a sample keeps a selection in the arm of one a sample keeps, and the outer arm goes on past the inner merge. Two bu.allna and one bu.alla, with the inner mask NORNZ, in 53 instructions. glslc_nested_kept_o0, 332 words, is the same shader without -O: the same program to the word.
  - glslc_nested_else, 256 words: the kept selection is in the outer's false arm. 54 instructions.
  - glslc_nested_uniform, 411 words: a selection on a varying in one on a push constant, which is uniform (a bu.anynap), with an execute of its own; and one on the push constant in one on a varying, under the mask too (NORNZ). 82 instructions.
  - glslc_nested_store, 228 words: a compute program's store in an arm of a selection whose arm stores. Both addresses are written under their masks. 41 instructions.
  - glslc_nested_vertex, 301 words: uniform buffer reads in nested arms on the vertex's number. The vertex program keeps both, in 83 instructions. The coordinate program reads neither and flattens both, in 16 instructions with no branch.
  - glslc_nested_only, 378 words, without -O: the outer selection is kept only for the kept one in its arm. nir_opt_cse finds the inner arm's v.y * 3.0 made in the outer arm. 53 instructions.
  - glslc_nested_taken, 255 words: the inner arm's sample is the outer's. What is left of the inner arm is four bcsels, which test the comparison's bool. 38 instructions.
  - glslc_nested_collapse, 216 words: nir_opt_collapse_if's shape with the inner arm kept, refused until 1.208.
  - glslc_flat_many, 838 words, without -O: seventeen selections in a row, each flattened. 17 bcsels and no branch.
- **The shapes**, built in the IR, each described at its test: NestedWebs, NestedWhole, FlatInKept, SameCondition, NestedAtStart (a kept selection first in each arm of one, ANDZ in the one and NORNZ in the other), LaterCopyReads, and for the two fixes ScaleInArm, SplatInArm and SelectsInArm.
- **The tests.** The V3D's tests are 390, thirteen new. Two changed:
  - DeepCostly is refused for the collapse, where it was refused for its nesting.
  - glslc_collapse with DontFlatten on the outer selection is a branch over the inner selection's bcsel, where it was refused.

  Of 32 mutations, 30 fail them. Two of those were written again so they compile. Eight failed none at first, and fail since the shapes were added for them:
  - NestedAtStart: the selections laid innermost first, a selection laid that is not in the arm, the region past a merge made the top level's, and ANDZ made NORNZ;
  - SplatInArm: readAgain reading the second operand alone, and madeOf not following a construct;
  - SameCondition, made longer: a selection's phis taken past the next mark of its level;
  - LaterCopyReads: a joined web's copies left out of the tests after.

  The two left change nothing:
  - Two copies at a way's end ordered the other way about. Their phis are one selection's and are both read past it (nir_opt_dce takes a phi nothing reads), so they interfere anyway.
  - The divergence that a web joined into another brings, dropped. fromSsa joins only webs of the same divergence.

On the CM5, FacetBoth 1.71 has two new cases. Each is an IR twin of a host shape, its arm kept a branch by thirteen sums and sines:
- **"shipped nested kept branches"** is 8 of 230400 pixels apart, 252 at worst. Its outer selection keeps the inner one in its arm, under the outer's mask. The inner arm scales a vector by three quarters of the green, made before both, which the inner false way brings to the red. The vector's first float is a quarter of the last sine: the sines come to nearly 1 whatever they start from, and the first draft, with a half of it plus a half, hid the fault under 1/255.
- **"shipped bcsels in a kept arm"** is 8 apart, 240 at worst. Its kept arm has three bcsels on the green being under a half, and the green is what the red's phi brings the other way.

The 8 are the edge pixels where the plain cases first differ: the first is at 154,70, which the V3D leaves the clear colour. With readAgain and readsWeb taken out of the back end, each case is 19,349 apart: the pixels where the red and the green are both under a half. Those are where the inner arm runs, and where a bcsel that compares its first's result again gets the other answer. The other 301 cases are each as they were at 1.206, and FacetProbe is 890 of 890.

### 61. Multisampling: 4 samples a pixel on both devices, with resolve attachments and CmdResolveImage's body **[critical path]**

*rasterisation* &mdash; conformance-blocking, port, **sized 07.11.2026: 21 commits, about 1,590 lines of code, 1,340 of tests and 90 of docs**; **the cores' half done in 1.114**, the V3D's is steps V1 to V8

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

facet reports 1|4 on both devices, with the standard locations on both since 1.148 (V5 settles it against v3dv's false). These stay off or refused:

- sampleRateShading, alphaToOne and variableMultisampleRate, which are optional;
- 4x storage images. 4x input attachments, which this listed too until 1.111, are no option: Vulkan 1.0 reads one through `subpassInputMS` with no feature to refuse it under (SPIR-V's InputAttachment capability; StorageImageMultisample exempts SubpassData), and vkCreateRenderPass has no error to give, so K6b reads them;
- 2, 8 and 16 samples.

`can.multisampling` comes to mean four samples a pixel, with no new field. It turns on in K7 for the cores and in V5 for the V3D, and the masks and the format query follow it, so no sample-count bit is reported before the code that draws it. The first five commits are shared, host-tested, and change nothing a shipped device reports. After them the cores and the V3D proceed independently.

| Step | What | Ported from | Code | Tests |
|---|---|---|---|---|
| S1 | **Done in 1.96.** The three optional features decoupled. The seven masks become 1\|4, narrowed to 1 while a device lacks the capability, and no-attachments to 1 until item 43 | v3dv_device.c:1179-1189, :392 | 35 | 35 |
| S2 | **Done in 1.98.** A 4x image in sample-major planes, and the format query's 4 bit following CreateImage. Layers and input-attachment usage are taken, against the first plan: Vulkan's rule for `sampleCounts` holds the query to the masks for both | lp_texture.c:225-226; lvp_formats.c:362-367 | 70 | 45 |
| S3 | **Done in 1.99.** Copies and clears of every sample; a blit or a buffer copy of a 4x image does nothing, as Vulkan has none | lp_texture.c:225-226; lp_surface.c:40-81 (`lp_resource_copy_ms`), :450 (`llvmpipe_clear_texture`) | 25 | 30 |
| S4 | **Done in 1.100.** Render passes, framebuffers and pipelines take 4 samples and resolve attachments. A resolve counts as its attachment's first use, resolving subpasses are never joined, and a framebuffer's targets without a resolve are set to none. A framebuffer's layers past its first were cleared in sample 0's plane alone until 1.104, which clears every sample's, of the colour, the depth and the stencil (llvmpipe_clear_render_target, lp_surface.c:356-368; llvmpipe_clear_depth_stencil, :429-442) | Vulkan's subpass rules, as v3dv asserts them (v3dv_pipeline.c:1319-1320) | 85 | 50 |
| S5 | **Done in 1.101.** CmdResolveImage (item 13), with a CPU body, into rows or a texture; both players route it there | `resolve_color`, lvp_execute.c:1782-1828; vk_meta_blit_resolve.c:151, :192 | 187 | 65 |
| K1 | **Done in 1.102.** Per-sample coverage in setup, binning and the walk; every caller asks for one sample until K2. Against the first plan, the box at four samples is not llvmpipe's box of whole pixels (lp_setup_tri.c:314-324): it holds the pixels whose samples' columns and rows overlap the triangle's, as the box at one holds those whose centres it covers | `lp_sample_pos_4x`, lp_rast.c:63-66; lp_setup.c:127-128, :632; `do_block_4`, lp_rast_tri_tmp.h:63-72 | 148 | 267 |
| K2 | **Done in 1.103.** Sample planes in the tile. Shading once a pixel; per-sample colour writes, the sample mask and occlusion. Depth and stencil stay one a pixel until K3. Against the first plan, a frame of four already draws without facet's depth pre-pass here, not from K3 on: the pre-pass walks pixels | lp_state_fs.c:860-870, :1076, 1017-1021, 3505-3513, 3651-3672; lp_setup_context.h:311-316 | 217 | 195 |
| K3 | **Done in 1.105.** Per-sample depth and stencil, in planes of their own in each part's block, each cleared, loaded and stored. A sample's depth is taken at its own place, held under the depth clamp, and tested in its own planes. A pixel is shaded where any sample passed. A form that drops pixels holds sixteen depths a quad for after its fragment function. Against the first plan, a batch's held depths at four samples, 2 KiB, go in the part's block and not in the batch, which lives on the stack: 8 KiB for a program's task. Its test found a depth attachment's ops for a plane its format has not refused, against Vulkan; 1.106 takes them, and they keep nothing. A form that drops pixels, drawn a pixel at a time, wrote a dropped pixel's depth and stencil, at one sample and at four, until 1.107: it now tests late where its stencil test writes the stencil and holds its depths back otherwise, llvmpipe's depth modes for a shader that may kill (lp_state_fs.c:772-799) | lp_state_fs.c:907, 926-960, 970, 1047-1050, 1321-1334, 1426-1440, 3437-3439 | 93 | 100 |
| K4 | **Done in 1.108.** Alpha to coverage on the cores, at one sample a pixel and at four: colour 0's alpha, less the dither's threshold at the pixel's place on the surface, keeps sample s of n where it is above s / n. The function writes an 8-bit alpha, so the test is lavapipe's made in integers, 8na > 255k + 2040s. Such a draw holds its depths back, tests late beside a stencil test that writes, as a form that drops pixels does since 1.107, and goes without the depth pre-pass. The V3D refuses it until V6 | lp_state_fs.c:408-474, 1182-1214; lp_bld_blend.c:342-365 | 34 | 40 |
| K5 | **Done in 1.109.** Resolve attachments on the cores: each tile, once its samples are stored, averaged into the resolve over its part of the render area as the surface holds them, so that a pass's resolve is CmdResolveImage's to the byte. Every tile of the area is drawn where a colour is resolved, and the framebuffer's layers past the first are resolved from the image's rows as the part ends | lvp_execute.c:1782-1837, 2053; v3dvx_cmd_buffer.c:640-686 | 113 | 125 |
| K6 | **Done in 1.110.** Multisampled fetch from a native fragment function: a texture keeps its samples' planes apart and `sampleOf` gives one as a texture of one, a sample past the last reading nothing. A sampled colour image of four samples is kept in rows, its rows the texture, R8G8B8A8's bytes read by a texture format of their own; a depth attachment's planes carry their samples. Against the first plan, not a colour attachment as well: one sample of that is not made (item 48), and the format query's sample counts hold the 1 wherever they hold the 4. Since 1.119 both are made, item 48's cores' half | lp_jit.c:399-404; lp_texture.c:1087; lvp_image.c:87-89, 104; lp_bld_sample_soa.c:2170-2187, 2985, 3166-3181 | 35 | 45 |
| K6b | **Done in 1.111.** Input attachments of four samples, read a sample at a time: not in the first plan, which kept them refused, though Vulkan 1.0 reads one through `subpassInputMS` with no feature to refuse it under. An attachment carries its samples, their stride and where its second sample begins, and `sampleOf` gives one sample as an attachment of one, a sample past the last reading nothing: from the image's rows where an earlier subpass drew it, a colour or a depth plane, and from the tile where a subpass reads what it draws. No sample count ties an input attachment to its subpass, so one of one sample reads one of four | lvp_nir_lower_input_attachments.c:49-86; lp_bld_sample_soa.c:2170-2187, 4839, 4941-4956 | 34 | 320 |
| K7 | **Done in 1.112.** 4x turned on for the cores, closing six rows: `Capabilities.multisampling` is theirs, so the three framebuffer masks and the colour, depth and stencil sampled-image masks say 1\|4, and the format query, CreateImage, CreateRenderPass and CreateGraphicsPipelines take four where those masks say it. The tests that turned the capability on to draw four now ask the cores for it, and each refusal is checked on the cores described without it. `standardSampleLocations` stays true: the cores' four places are Vulkan's (setup.zig `sampleOffsets`), as lavapipe says of its own. v3dv says false on the V3D, though the four places its compiler gives are the same ones: V5 is where that is settled | lvp_device.c:81-82, 1072-1081, 1094; v3dv_device.c:1202; nir_to_vir.c:3111-3134 | 10 | 40 |
| K8 | **Done in 1.114.** A subpass of no attachment at 4x, after item 43's cores' half (1.113). Such a subpass has its pipelines' count, so a pipeline of four is taken there, and its first draw lays the tiles again at four where its pipeline has four, as v3dv starts its job again with MSAA before its first draw; the frame counts its draws for that, as v3dv's job does. The no-attachments mask holds the 4 bit on a device with `can.colorless_subpasses`, which closes the last row on the cores. Against the first plan, two pipelines of different counts in one subpass, which Vulkan does not allow without `variableMultisampleRate`, draw at the first's, as v3dv's do; and a pipeline of four bound in a subpass of an attachment of one, against Vulkan too, draws at the attachment's count, since the tiles are laid again over no surface | `cmd_buffer_restart_job_for_msaa_if_needed`, v3dv_cmd_buffer.c:2655-2730, 2906-2912 | 16 | 106 |
| V1 | **Done in 1.144.** The packet fields: COMMON's MSAA bit and the tile's log2 width and height apart, in COMMON and the binner's mode, decimate on loads and stores, oversample, and SAMPLE_STATE's mask. A frame of one sample writes the bits it did. Against the first plan, the binner's mode has no MSAA bit at 7.1, only 4.2's had one (v3dvx_cmd_buffer.c:101-112) | v3d_packet.xml; v3dvx_cmd_buffer.c:206-209, 408-413, 977, 1615-1618; v3dvx_pipeline.c:193-196 | 23 | 50 |
| V2 | **Done in 1.145.** The tile-size chooser, its 7.1 branch, which the frame's tiles, supertiles and binner's memory take where 64 was taken for granted; and SAMPLE_STATE with each draw's mask in a frame of four, with oversampling. Every frame stays of one sample until V4 | `v3d_choose_tile_size`, v3d_util.c:104-182; v3dv_cmd_buffer.c:367-413, 3017-3018; v3dv_pipeline.c:2903-2913 | 65 | 45 |
| V3 | **Done in 1.146.** The 4x layout, 2W x 2H and level 0 always UIF, each pixel's samples a quad of it. Against the first plan, not a fourth image kind: `Image.quads` marks an image of either kind, colour or depth, whose samples its device keeps together, and `sampleOf` gives a sample as the whole memory with the sample named, which `Ops.texture_offset` finds in the quad. Copies, clears and resolves reach every sample so; such an image is not sampled until V7 | v3dv_image.c:136-140, 180-183; v3d_nir_lower_txf_ms.c:46-51 | 75 | 35 |
| V4 | **Done in 1.147.** Binning and rendering a 4x frame: a pass whose colour has four samples, its tile at four, its colour stored where its level lies and every load and store of all four samples. GFXH-1918 asks nothing more, the early depth test being off in every frame here. Seen on the board in V5, which first makes an image of four there | v3dvx_cmd_buffer.c:206-209, 396-413, 973-984, 1604-1618, 1854-1882 | 76 | 45 |
| V5 | **Done in 1.148.** Resolve in the TLB, with S5 as the fallback; 4x turned on for the V3D, closing its three framebuffer rows. The tiles store the colour's average into the resolve's rows before the colour, where every tile they render lies inside the render area or over the framebuffer's edge, and the CPU resolves the area after the frame elsewhere. Against the first plan, aligned to the supertile and not the tile: the renderer renders whole every supertile the area touches, v3dv's as well, so a tile-aligned area alone would let a tile average into the attachment outside it. CmdResolveImage stays on the CPU: `resolve_image_tlb` is not ported. Its sampled colour and depth masks stay at one until V7. `standardSampleLocations` stays true, against v3dv: its compiler's four places are Vulkan's, and FacetBoth 1.16's five cases of four on the board are 22 to 54 pixels of 230400 apart from the cores', each by one sample's worth, where wrong places would part most pixels on an edge | v3dvx_cmd_buffer.c:640-686, 771-795; v3dv_pass.c:663-683; v3dv_cmd_buffer.c:421-446, 957-1005, 1184-1203; nir_to_vir.c:3111-3134 | 110 | 40 |
| V6 | **Done in 1.149.** Alpha to coverage on the QPU: a compiled program of four samples ANDs its alpha's FTOC with MSF into SETMSF before the tile buffer is written, and writes Z through with early Z off, its early tests not promoted. `compile.Key` carries it beside the words, set only at four samples as v3dv's key is, so a pipeline of one draws without it, which until now was refused. Against the first plan, a fixed form of four that asks for it stays refused and on the cores: its hand-written program does not cover, and a fixed form's varyings are carried in another scaling than a compiled program reads, so it cannot take its words' program instead. FacetBoth 1.17's case on the board is 44 pixels of 230400 more than a sample apart from the cores', which dither which samples the alpha covers | nir_to_vir.c:2056-2065, 2073-2108; vir.c:1011-1013; v3dv_pipeline.c:1321-1324; v3dvx_pipeline.c:453, 459 | 110 | 35 |
| V7 | Multisampled fetch through the TMU, after item 59 | v3d_nir_lower_txf_ms.c:46-51 | 45 | 25 |
| V8 | **Done in 1.150.** No-attachment subpasses at 4x, with item 43's V3D half: where a frame's first draw has a pipeline of four and the frame one, the frame starts again at four, of its size and in the tile four samples of no colour take, its tile lists, tile state and binner's list made again, nothing having been binned. A frame of any attachment has that attachment's count, which its pipelines are held to, so only one of none restarts. FacetBoth 1.18 counts a no-attachment subpass's draws with an occlusion query: 422266 samples on the V3D at four against the cores' 422322, and 105571 against 105583 at one. Found on the way: the binner was started at the last 64 KiB part of its list, not the first, so a frame of that many draws lost its binning mode; it starts at the first, as v3dv starts at its job's first block (v3dv_queue.c:733-737) | `cmd_buffer_restart_job_for_msaa_if_needed`, v3dv_cmd_buffer.c:2655-2735, called at :2906 | 40 | 40 |

Docs add about 75 lines in K7 and 15 in V5. The V3D's sampled depth and stencil rows wait on item 58 and are not among these commits.

Three things this item said are corrected:

- **The tile is not halved.** At 4x a part's tile would hold 112.5 KiB against the A76's 64 KiB of L1, as worked out above, and halving `tile_size` would tax every 1x frame. The three extra sample planes go instead in the per-part run-time block that `lay()` already builds for extra colour attachments, so a 1x frame is unchanged. Whether a 4x frame should halve its own tile, as `v3d_choose_tile_size` does on the V3D, is a measurement for after K7.
- **A pass with a resolve marks every tile dirty.** `finish` draws only dirty tiles, and `begin` marks them dirty only when something is cleared. Without this, a tile loaded with LOAD_OP_LOAD and drawn into by nothing would never be resolved.
- **The pin is 0 since 1.114.** It said 10 at 1.89; item 17's half (1.90) and item 22's half (1.91) took it to 7, all seven this item's, K7 to 1, the no-attachments mask, and K8 to 0. The verified line above cites creategraphicspipelines.zig:378 and _image.zig:338, which at 1.95 are :414 and :352.

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

Grouped because the finding is that nothing is owed, and why — which is worth writing down rather than changing. facet over-synchronises everywhere, so no conformant program can observe the discarded barriers: the queue runs one command buffer to completion before the next, each command finished before the next starts, and the V3D driver flushes every chunk and the target image to the GPU before a job, invalidates after, and invalidates the L2T and slice caches before every bin and every render. Subpass dependencies are not read at all since 1.134 — until then they answered one question, whether a subpass depends on itself by region, which a subpass reading the tile it draws into had to — and subpasses always run in index order. One queue family of one queue satisfies Vulkan 1.0, which requires only one family supporting graphics and compute. The moment any of that changes — several queues, async compute, the binner overlapping the previous render — the barrier becomes load-bearing and the arrays have to be there to read, which is a struct change plus a per-barrier payload since _command.record already takes a variable-length one. Note the two gap documents use "only one queue" as the reason events are absent, which it is not.

> Verified: cmdpipelinebarrier.zig:67-78 discards all three arrays; queue/_queue.zig:245-254 waits for each command buffer's done before the next; driver/v3d/_play.zig:680-708 rangeToGpu over every chunk and the image before the job and rangeFromGpu after; driver/v3d/engine.zig:108-137 invalidateCaches() before every bin and render; createrenderpass.zig reads none of info.dependencies since 1.134 (`fn byRegion` was their one reader, item 91); getphysicaldevicequeuefamilyproperties.zig:57-66 always answers count 1; createdevice.zig:75-81 refuses more than one queue.

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

*buffers / limits* &mdash; conformance-blocking, small &mdash; **done in 1.125**

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

**Done in 1.125**, in 2 lines of code and 27 of tests, the first way:
the check uses the limit it publishes, the device's
`min_texel_buffer_offset_alignment`, as Vulkan has it
(VUID-VkBufferViewCreateInfo-offset-00926). A texel is read a byte at a
time (`shader.Texels.at`, `std.mem.readInt`), so nothing here needs more.
lavapipe and v3dv look no further at the offset (`lvp_CreateBufferView`,
lvp_image.c:785-817; `v3dv_CreateBufferView`, v3dv_image.c:885-940);
llvmpipe's limit is 16 as this one is (lp_screen.c:288), and v3dv's is
the texture unit's 64 (`V3D_TMU_TEXEL_ALIGN`, v3d_limits.h:60), which is
what this library's V3D will publish once its texture unit reads a texel
buffer - until then the cores read them. A whole texel that is not a
multiple of 16, which was taken, is refused now, Vulkan forbidding it.

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

*result codes* &mdash; conformance-blocking, medium, also serves the shim &mdash; **done in 1.133**

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
  attachment on the V3D (item 43's remainder), and the other
  conformance-blocking refusals.
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

**Done in 1.133**, in 39 lines of code, the generated interface aside,
and 185 of tests, as the re-scope says: one member,
`error_validation_failed = -1000011001`, and a return value at each
site whose VUID was read. Two of the 72 sites answered for both kinds
and were split - a set layout's kind of descriptor apart from its
binding's number, a render pass of no subpass apart from one of more
than four - so there were 74, and 35 moved: each a feature the device
reports false, a limit it reports, or a value or a bit none of Vulkan
1.0's. The other 39 refuse what Vulkan allows, each a gap with an item
of its own, and keep `error_feature_not_present`; the 133 note in
facet_version.zig lists both. The counts by file above were off - 20 in
CreateRenderPass, 17 in CreateGraphicsPipelines - and there were 49 test
lines, of which 22 expect the new code, besides one in FacetProbe.

Mesa has nothing to port here: its drivers do not validate, and none of
them answers `VK_ERROR_VALIDATION_FAILED`. The one place facet now
answers otherwise than v3dv is QueueBindSparse, which v3dv answers
`VK_ERROR_FEATURE_NOT_PRESENT` (v3dv_queue.c:1172-1178), a code the
call's list does not have; on either device, asking it at all breaks
VUID-vkQueueBindSparse-queuetype.

Reading the VUIDs found one refusal of valid usage among the 35:
CreateSampler turned away a border colour that is none of Vulkan's
wherever it was given, and Vulkan asks for one of its own only where an
address mode clamps to the border (VUID-VkSamplerCreateInfo-addressModeU-01078).
Elsewhere the colour is not read, and it is taken now. The reading also
found two more codes doing this work, which is item 91.

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

### 85. A graphics pipeline with no fragment stage is refused

*pipelines* &mdash; conformance-blocking, small, found while doing item 43 &mdash; **the cores' half done in 1.115, the V3D's in 1.150**

Vulkan 1.0 asks a graphics pipeline for a vertex stage
(VUID-VkGraphicsPipelineCreateInfo-stage-02096) and nothing of a fragment
stage: "If no fragment shader is included in the pipeline, no fragment
shader is executed, and undefined values may be written to all color
attachment outputs" (fragops.adoc, *Fragment Shading*). A shadow map's
pipeline is the program that leaves it out, now that its subpass of the
depth alone can be made (item 43). CreateGraphicsPipelines refuses a
pipeline without one (pipeline/creategraphicspipelines.zig,
`fragment orelse return .error_invalid_shader_nv`).

lavapipe binds a fragment shader of no instructions in its place,
`noop_fs`, built once for the device (lvp_device.c:2048-2052) and bound
where the pipeline has none (`emit_state`, lvp_execute.c:552-554). The
port is the same: a fragment entry of facet's own that writes nothing,
taken where the stages name none, with no varyings for the last stage
before it to be checked against. About 15 lines and a test.

**The cores' half done in 1.115**, in 11 lines of code and 189 of
tests. `settle` takes `noFragment`, a function of no instructions, where
the stages name no fragment one, and checks no varyings against it. Two
things the item did not say:

- **What lands in a colour attachment.** Vulkan leaves it undefined, and
  llvmpipe blends the colour store it allocates for a cbuf and never
  writes (`lp_build_array_alloca`, lp_state_fs.c:826-832), which is
  whatever that memory held. Here each colour attachment's write mask is
  0, so it keeps what it held: deterministic, and as undefined as
  Vulkan's. The function still has the room of as many colours as the
  subpass draws together, so a subpass marked OUTPUTS_TOGETHER takes it.
- **Alpha to coverage changes no sample**, as llvmpipe's applies only
  where the shader writes colour 0 (lp_state_fs.c:1181-1185), which the
  no-op does not.

The V3D refuses such a pipeline where it draws, with
`error_feature_not_present`, at the check it already made for a fragment
stage that ships no SPIR-V (driver/v3d/driver.zig, `makePipeline`); one
that draws nothing it makes with no program since 1.134 (item 91). Its
half is v3dv's: a fragment
shader of no instructions built for the pipeline and compiled
(v3dv_pipeline.c:2616-2642), here a fragment program of the library's own
handed to the back end, with a board check.

**The V3D's half done in 1.150**, with item 43's, whose program it is:
v3dv's noop compiled with no render target in the key, which with no
colour of its own writes no colour in a subpass of colour either, and
writes the rasterizer's Z through (`qpu.no_color_fragment`, held to the
back end's output by a test). `Pipeline.fragment_stage` says the stages
named none; `makePipeline` makes such a pipeline with no program of its
own, and its draws take the device's. Vulkan leaves the colour
undefined; here it keeps what it held, as on the cores. FacetBoth 1.18
draws one in a pass of colour, its depth hiding the glass drawn after
it, and one that draws a shadow map and a pre-pass: 6, 3 and 8 pixels of
230400 apart from the cores.

### 86. A colour reference of ATTACHMENT_UNUSED is refused

*render passes* &mdash; conformance-blocking, small, found while doing item 43 &mdash; **done in 1.118**

A subpass's colour attachment `i` may be `ATTACHMENT_UNUSED` in Vulkan
1.0: what the fragment shader writes at location `i` goes nowhere, and the
locations after it keep their attachments. facet reads the reference as an
attachment's index and refuses it as one past the last
(render/createrenderpass.zig, `color_index >= attachments.len`,
`error_initialization_failed`). Mesa's common render-pass code makes such a
reference a colour attachment with no image view (vk_render_pass.c:1924-1930),
lavapipe a colour buffer with no texture (`handle_begin_rendering`,
lvp_execute.c:1984-1999), and llvmpipe's tile maps none for it
(lp_rast.c:126-131). In facet that is a part's colour slot with no
surface, kept so that the locations after it stay where they are, whose
plane is neither loaded nor stored. A resolve reference of
`ATTACHMENT_UNUSED` is already taken as none. About 30 lines and two
tests.

**Done in 1.118**, in 38 lines of code and 192 of tests, and not as the
item said: the slot with no surface is the together case, and a Vulkan
program never reaches it, `SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER` being
facet's own.

- **Drawn apart, an unused reference is no part at all.** This is how
  every Vulkan program's subpass is drawn. Each part now carries the
  location of its colour (`Part.output`), and four things go by it: the
  location the fragment function writes, the blend state it is mixed by,
  the colour attachment CmdClearAttachments names (`colorAttachment`),
  and whether the target has an alpha. Each was the part's number until
  now, which is the same thing only while no reference is unused. A clear
  of the unused location matches no part, so it does nothing, as Vulkan
  has it.
- **One of the four was wrong regardless of UNUSED.** A part's no-alpha
  flag was set at the first place and read at the part's number, so a
  part past the first, over an `r5g6b5_unorm_pack16` attachment, blended
  by an alpha the attachment does not have. It is set at the location
  now.
- **A query counts the subpass's first part by its number**
  (`player.part`), not by its location: a first part past an unused
  reference is not at 0 (item 87).
- **The blend state is held to the subpass's colours as Vulkan counts
  them** (`Subpass.color_count`,
  VUID-VkGraphicsPipelineCreateInfo-renderPass-07609). Three references,
  one unused, take three blend states though they are two parts.
- **A subpass whose every reference is unused is drawn as a subpass of
  none** (item 43).
- **Drawn together, an unused reference is refused**, with
  `error_feature_not_present`. It would be a plane of the tiles with no
  image behind it, and the tile target has no colour that loads and
  stores nothing; llvmpipe's tile maps no memory for it
  (lp_rast.c:126-131). That is item 80's to bring, once every subpass on
  the cores draws its colours together.
- **The V3D draws every subpass apart**, and reads a part's location the
  same way (driver/v3d/_play.zig). This is unchecked on the board. A
  subpass whose every reference is unused is one of none, which the V3D
  draws as one since item 43's V3D half in 1.150; it took one before, and
  read a colour its part did not have, which this note had wrong.

### 87. A subpass drawn a part for each colour attachment was not played the same way in each part

*render passes / queries* &mdash; conformance-blocking, small, found by a
test while scoping item 86 &mdash; **done in 1.116**

A subpass of several colour attachments without facet's own
`SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER` is a part for each (item 80), and
the player plays its commands again from its begin for each part
(`playStream`'s `repeat`, on both devices). That is the subpass only if
each part does what the subpass does once, and two things did not:

- **Every part wrote back a depth or a stencil the subpass loads and
  stores.** Each separate part is the subpass's `whole` copied
  (render/createrenderpass.zig), with the attachment's `stores_depth` and
  `stores_stencil`, so the first wrote what it left into the image's rows
  and the second read that in and tested against it. A quad drawn under
  a LESS test over a depth cleared to the furthest left the second colour
  attachment as it was cleared everywhere, and a stencil test of EQUAL 0
  with INCREMENT_AND_CLAMP did the same. A G-buffer pass over a depth
  pre-pass's depth does this. The plan is both devices', so the V3D's
  parts did it too.
- **A query counted each draw once for each part.** A query's counters
  are addresses in its pool (`_query.Counters`) that every draw played
  adds to, so an occlusion query read twice the samples that passed and a
  statistics query twice the vertices. On the V3D each part's frame
  pointed the hardware's counter at the query's word.

Mesa has no replay to port: llvmpipe maps a tile of every colour buffer
as the tile begins (`lp_rast_tile_begin`, lp_rast.c:107-137) and shades
it once for all of them, so a draw is tested once and counted once
(`vis_counter`, lp_rast.c:123 and 635-675). The replay is facet's own
until item 80 has every subpass on the cores draw its colours together,
and until item 55 gives the V3D a fragment program of several outputs.
Until then it has to be faithful.

**Done in 1.116**, in 6 lines of code and 146 of tests:

- **Only the last part writes the depth and the stencil back**
  (render/createrenderpass.zig), so each part reads in what the subpass
  began with, and they all leave the same. The plan already assumed that
  where a later subpass reads the depth from this one's last part (1.52).
- **A draw counts into a query in the first part alone**
  (driver/cpu/_draw.zig). On the V3D the frames of the parts after it
  leave the counter stopped, as a frame with no query does (`tallyFor`,
  driver/v3d/_play.zig). That is the path every such frame already takes
  on the board, but this use of it is unchecked there.
- Neither device writes from a fragment function: `fragment_stores_and_atomics`
  is false on both. If that changes, a replayed part must not repeat a
  function's stores either. Since 1.170 the V3D says it writes, and refuses a
  pipeline whose program writes in a subpass drawn a part for each.
- Found alongside, and item 88: only one query counts at a time on the
  cores.

### 88. Only one query counts at a time on the cores

*queries* &mdash; conformance-blocking, small, found with item 87 &mdash; **done in 1.117**

Vulkan lets one query of each type be active at once
(VUID-vkCmdBeginQuery-queryPool-01922 forbids two of the same type), so
an occlusion query and a pipeline-statistics query may be begun
together. The cores' player keeps one `Counting` (`query`,
driver/cpu/_play.zig), and CmdBeginQuery replaces it: an occlusion query
begun before a statistics query counts nothing after that, and read 0
where 4096 samples passed. llvmpipe keeps every query begun in a list
(`active_queries`, lp_setup.c:1475-1483, taken out at 1564-1577) and
bins each into every tile. The port is a slot for each type that counts,
occlusion and statistics, with a draw adding to the counters of both.
The V3D has occlusion alone (its statistics pools are refused, and a
timestamp is never begun), so one is all it can have. About 30 lines and
a test.

**Done in 1.117**, in 41 lines of code and 56 of tests. The player keeps
`_queries.Active` (driver/_queries.zig): an occlusion query and a
statistics query, each in its own place, and the counters gathered
from both, so a draw and a dispatch add to either through one set of
addresses, as before. CmdEndQuery takes out the query it ends and leaves
the other counting. A reset forgets every query of the pool, as it did
the one, though Vulkan does not allow resetting an active one
(VUID-vkCmdResetQueryPool-None-02841).

### 89. A depth sampled as a colour reads a grey, where Vulkan reads (D, 0, 0, 1)

*samplers / depth* &mdash; conformance-blocking, small, found while doing item 41 &mdash; **done in 1.121**

A sample of a depth that does not compare reads it as an opaque grey of
its top 8 bits, (D, D, D, 1) (`texture.Texture.readColor`, the `d16`
case), and that is what a fixed form and a generated shader get. Vulkan
converts a texel by component substitution, "(0,0,0,1) for missing
(R,G,B,A) components" (13.2.2), so a depth reads (D, 0, 0, 1), its D as a
float. `partsAt` already reads it so, at all 16 bits. lavapipe gets there
by a swizzle on every view of a depth or a stencil, the green and the blue
0 and the alpha 1 (`conv_depth_swiz`, lvp_image.c:337-347, applied at
389-396). Since 1.120 a view that swizzles reads the green and the blue as
0 (item 41); one that swizzles nothing keeps the grey. The port is
lavapipe's rule on every such view, a few lines, and the tests and the
probe's pictures that read the grey (tests/draw.zig at the layers of a
sampled depth, and facetprobe.zig). The 8 bits are the colour path's,
which holds 8 a channel; a generated shader reading D at 16 bits is the
larger half.

**Done in 1.121**, in 12 lines of code and 52 of tests, and as
lavapipe does it. llvmpipe reads a depth or a stencil as (Z, Z, Z, 1)
whatever the view, "Correct swizzling will be handled by
apply_sampler_swizzle() later" (`lp_build_format_swizzle_soa`,
lp_bld_format_soa.c:82-101), as `readColor` reads the grey here, and
lavapipe turns every view of one's swizzle by `conv_depth_swiz`, the
identity's too, so the identity's green and blue read 0 and its alpha 1.
Here the texels of every view of a depth or a stencil take that rule
(`createimageview.zig` `depthRead`), and a view of one reads (D, 0, 0, 1)
through a sampler, a fixed form, `colorAt` and `partsAt`, what a
comparison gave standing in the D, and a texel it does not hold
(0, 0, 0, 1). The view itself keeps the swizzle the program gave it,
which is what a framebuffer asks of it and what the V3D's TMU will take
over the format's own, v3dv's depth formats being `SWIZ_X001`
(v3dvx_formats.c:204-206), so a depth attachment's view is still the
identity.

The 8 bits are not this item: every format a sample reads is held at 8
bits a channel on its way into the tiles and into a generated shader's
floats (docs/facet-gaps.md, the wide channels), and `partsAt` and a
comparison read a depth at all 16. The V3D samples no depth yet
(item 58).

### 90. CmdCopyImage copies nothing between two formats of one size that the cores keep differently

*images / copies* &mdash; conformance-blocking, small, found while doing item 42 &mdash; **done in 1.132**

Vulkan copies an image into another of any format of its size: "Color
formats with the same texel block size are considered size-compatible",
and "Copy operations are able to copy between size-compatible formats in
different resources" (58.1.8); VUID-vkCmdCopyImage-srcImage-01548 asks no
more of the two formats than that. What is copied is the bits, as a view
of another format reads them (item 42). The cores copy some of those
pairs only. `copyPlane` (driver/_transfer.zig:34) returns with nothing
copied where one image keeps what it was given and the other does not,
or where both do and their formats differ (:47-48) - R8G8B8A8_UNORM into
R32_UINT, R16G16_UNORM into R32_SFLOAT, R32_UINT into R32_SFLOAT - and
where two block images are not of the one format (:39-40), though their
blocks are of one size: BC6H_UFLOAT into BC6H_SFLOAT, BC1 into BC4. A
block image and an uncompressed one of its block's size (BC1 and
R16G16B16A16_SFLOAT, a block to a texel) are never copied at all.

lavapipe hands every such copy to `resource_copy_region`
(`handle_copy_image`, src/gallium/frontends/lavapipe/lvp_execute.c:2784-2867),
which llvmpipe does as `util_resource_copy_region` over the bytes as
they lie (`lp_resource_copy`, src/gallium/drivers/llvmpipe/lp_surface.c:86-116).
Here `_image.readTexel` and `writeTexel` already move a texel as the
bytes a buffer holds it in, whatever its format, so between two
uncompressed images the two refusals are all that is wrong. Two block
images want `copyBlocks` with the size of their blocks compared rather
than their format, and a block image and a texel one a region counted in blocks on
the one side and in texels on the other, as Vulkan size-adjusts the
destination's offset and extent (26.3).

> Verified: driver/_transfer.zig:39-40 `if (_image.blocked(source) or _image.blocked(destination)) { if (source.format == destination.format) copyBlocks(command, source, destination);`, :47 `if (_image.keptTexels(source) != _image.keptTexels(destination)) return;`, :48 `if (_image.keptTexels(source) and source.format != destination.format) return;`; image/_image.zig:1220-1222, `keptTexels` is a float format, one of wide channels or one of whole numbers.

**Done in 1.132**, in 53 lines of code and 114 of tests, as lavapipe
copies: every region goes to `resource_copy_region`, which llvmpipe
makes over the bytes as they lie, counted in blocks of each format. The
two refusals went, so between two uncompressed images of one size each
texel goes as the bytes a buffer holds it in, whatever each image keeps
it as. Two block images copy their blocks where the blocks are of one
size. A block image and an uncompressed one whose texel is as large as
its block copy a block to a texel or a texel to a block (`copyAcross`):
the region's offsets are each in its own image's texels and its extent
in the source's, so a source of blocks writes a quarter as many texels
each way as the extent says, and a source of texels as many blocks as it
has texels. The item was right in what it said; what it did not say is
the policy for what Vulkan does not have: a block into a texel of
another size is invalid usage (VUID-vkCmdCopyImage-srcImage-01548), and
takes nothing, as two uncompressed images of two sizes already did.

### 91. error_initialization_failed and error_format_not_supported are answered for invalid usage, from calls Vulkan does not list them for

*result codes* &mdash; conformance-blocking, medium, found while doing item 81 &mdash; **done in 1.134 and 1.135**; what the reviews found beside it is 1.137's

Item 81 moved the refusals that answered `error_feature_not_present` for
invalid usage to `error_validation_failed`. Two more codes do the same
work. `error_initialization_failed` is answered at 66 places -
CreateRenderPass 15, CreateGraphicsPipelines 14, CreateFramebuffer 11,
CreateSampler 5, CreateBufferView 4, the screen's surface 3, CreateDevice
3, CreateQueryPool 2, the V3D driver 2, and CreateSwapchain, the window's
surface, CreatePipelineLayout, CreateDescriptorSetLayout,
CreateDescriptorPool, EndCommandBuffer and CreateCommandPool one each -
for a reference past the attachments, a push constant range not on 4
bytes, a pool of no queries, a size that is not the surface's and the
like. Vulkan has it mean "Initialization of an object could not be
completed for implementation-specific reasons", and lists it for
vkCreateInstance, vkEnumeratePhysicalDevices, vkCreateDevice,
vkCreateSwapchainKHR and some calls of extensions, not for most of
those. `error_format_not_supported` is answered at 23 places besides
GetPhysicalDeviceImageFormatProperties - CreateImageView 16,
CreateRenderPass 3, and CreateImage, CreateBufferView, CreateSwapchain
and CreateGraphicsPipelines one each - and core Vulkan lists it for the
format queries alone.

The work is item 81's: each place's VUID read, and
`error_validation_failed` where one forbids what was asked. Where none
does, it is a refusal of valid usage that keeps a code until its own
item, or, for CreateDevice, CreateSwapchain and the surfaces, a cause
outside the program, which keeps the call's own code.
`error_invalid_shader_nv` is not part of it: vk.xml lists
`VK_ERROR_INVALID_SHADER_NV` for vkCreateShaderModule,
vkCreateGraphicsPipelines and vkCreateComputePipelines alike, and item 4
settled keeping it.

> `grep -rn 'error_initialization_failed\|error_format_not_supported' src/disk/libs/facet/ --exclude-dir=tests`, comments aside, 07.11.2026; what each command lists is vk.xml's `errorcodes`.

**The first half, `error_initialization_failed`, done in 1.134**, in
145 lines of code and 455 of tests, comments aside. The count of
66 was right, and of them:

- **52 answer `error_validation_failed`**, each with the rule it breaks
  named beside it or in its call's RESULT, a VUID for all but two. One
  had been read wrong when the work was planned: a colour attachment
  named twice in one subpass has no VUID of its own, but the render pass
  chapter forbids it under VkAttachmentDescription ("A given attachment
  index must not be used multiple times in a single subpass", an input
  attachment beside another use excepted). The other, facet's own blend
  constants for each attachment counted past the 4 colours a subpass may
  have (`_render.most_colors`), nothing reaches: they are counted as the
  subpass's colours, which the blend count is held to before it, and
  CreateRenderPass holds a subpass to 4 colours
  (VUID-VkSubpassDescription-colorAttachmentCount-00845).
- **One answers `error_feature_not_present`**: a colour other than the
  first read as an input attachment, in a subpass whose colours are drawn
  together. Only facet's own `SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER` draws
  them so, and the refusal goes with the flag, item 80.
- **Six were two answers in one, and are split.** Three of
  CreateFramebuffer's - a colour, a resolve and a depth view smaller than
  the size - are `error_validation_failed` for an image smaller than it
  and `error_feature_not_present` for a level smaller than it of an image
  that is not; CreateRenderPass's subpass that reads its own depth
  attachment is `error_validation_failed` for an attachment of a colour
  format and `error_feature_not_present` for one of a depth format. Those
  two refusals are item 92. The other two had a half that refused what
  Vulkan allows, and takes it now: a colour of its own a subpass reads is
  `error_validation_failed` where it is of a depth format, and where it is
  read without a dependency on itself by region - which Vulkan calls a
  feedback loop, and whose reads it leaves undefined where nothing orders
  the write before them - it is drawn as with the dependency; and
  CreateBufferView's view of less than a texel is `error_validation_failed`
  where its range is given, and for WHOLE_SIZE a view of none, which reads 0.
- **Five keep the code**, each a cause outside the program:
  CreateDevice's queue not started, on a call Vulkan lists the code for;
  the screen's and the window's libraries not opened or too old, on
  CreateScreenSurface and CreateWindowSurface, facet's own calls, whose
  RESULT lists it where Vulkan's surface calls list no such code. The
  screen's Screen record and the record of its own buffer not had
  answered it as well, and are `error_out_of_host_memory` now.
- **Two go**, the V3D driver's: AllocateMemory and the fragment program a
  pipeline compiles held the V3D and answered the code where it would not
  come up, which neither call lists. No program reached them. The
  device's queue holds the V3D from CreateDevice to DestroyDevice
  (`_play.open`, driver/v3d/_play.zig:172-182, from `_queue.start`), and
  CreateDevice answers the code where it does not come up; the two count
  one more user of what the queue holds now (`holdAgain`), which cannot
  fail, as v3dv's device works on the hardware its physical device opened
  (src/broadcom/vulkan/v3dv_device.c:1514 `create_physical_device`). Not
  yet run on the board.

Reading the VUIDs found more than the 66:

- CreateGraphicsPipelines looked at states Vulkan does not have it read -
  the viewport, multisample, depth and colour blend states where the
  rasterizer discards, a depth state where the subpass has no depth
  attachment, a blend state where it has no colour one - and refused one
  that was null or held what it did not take. They are not looked at now,
  as Mesa's `vk_graphics_pipeline_state_fill` does not
  (src/vulkan/runtime/vk_graphics_state.c:1482-1493
  `may_have_rasterization`, :1600, :1662-1663, :1701-1702, :1841-1861).
  The V3D's driver refused a discarding pipeline, which has no fragment
  stage (VUID-VkGraphicsPipelineCreateInfo-pStages-06894), as it refused
  every pipeline of none; a pipeline that draws nothing - its rasterizer
  discarding, or every face culled - is taken now, its draw returning
  before any program is needed, and only one of none that draws is
  refused, until item 85's V3D half (done in 1.150). A
  discarding draw on the cores counted as a target's first, and laid a
  subpass of no attachments out for its samples; it does not now. Where
  the first draw that rasterizes lays the tiles again for its samples, it
  starts their arena over, and copies the push constants and descriptors
  again: a discarding draw before it had copied them there, and the copy
  went with the arena.
- CreateBufferView cut a range past the buffer's end to the end, where a
  texel was left there. That breaks VUID-VkBufferViewCreateInfo-offset-00931,
  and is `error_validation_failed` now.
- Two arrays a count says are there were read through when null, and
  panicked: a subpass's colours and a pipeline's blend attachments. They
  are `error_validation_failed`
  (VUID-VkSubpassDescription-pColorAttachments-parameter,
  VUID-VkPipelineColorBlendStateCreateInfo-pAttachments-07353).
- An attachment's samples that are none of Vulkan's - 0, 3, more than 64 -
  were `error_feature_not_present`, and are `error_validation_failed`
  (VUID-VkAttachmentDescription-samples-parameter).
- The memory calls answered memory codes for invalid usage, no memory
  having run out: `error_out_of_device_memory` from CreateBuffer of size 0
  (VUID-VkBufferCreateInfo-size-00912), AllocateMemory of a type the
  device has not got or of no bytes (VUID-vkAllocateMemory-pAllocateInfo-01714,
  VUID-VkMemoryAllocateInfo-allocationSize-07897), and BindBufferMemory and
  BindImageMemory into a type the object may not be in, off its
  alignment, past the block's end or bound already (-memory-01035 and
  -01047, -None-10739 and -10735, -None-10741 and -10737, -buffer-07459
  and -image-07460; a swapchain's image is bound as it is handed out);
  `error_memory_map_failed` from MapMemory of lazily allocated memory,
  which is not HOST_VISIBLE, of a block mapped already, or of a range of
  none or past the end (-memory-00682, -memory-00678, -size-00680,
  -offset-00679, -size-00681). AllocateMemory of more bytes than its
  type's heap holds went on to the device's driver, which answered
  `error_out_of_device_memory`, finding no room for it - or, of the lazily
  allocated type, which takes nothing and never reaches the driver, was
  made, and on the V3D a size from 0xFFFF_D001 to 0xFFFF_FFFF overflowed
  the 32-bit page rounding of `Space.alloc` (driver/v3d/space.zig:107-108)
  and panicked (VUID-vkAllocateMemory-pAllocateInfo-01713);
  GetQueryPoolResults into
  fewer bytes than its results take answered `error_out_of_host_memory`,
  and a stride too large for 64 bits overflowed the sum it was checked
  with (VUID-vkGetQueryPoolResults-dataSize-00817). They are
  `error_validation_failed`, and no call answers `error_memory_map_failed`
  now: MapMemory hands out the block's own address.
- GetImageMemoryRequirements offered the lazily allocated memory type to
  every depth attachment that is not read. Vulkan lets it be offered to
  an image made IMAGE_USAGE_TRANSIENT_ATTACHMENT and to no other
  (VkMemoryRequirements: `memoryTypeBits` "must not refer to" it
  otherwise), and it is now offered to a transient depth attachment
  alone: a transient colour attachment, kept in rows, is offered only the
  types with memory behind them, as before. A transient depth attachment
  read as an input attachment as well, which
  VUID-VkImageCreateInfo-usage-00963 does not forbid, CreateImage does not
  make, and GetPhysicalDeviceImageFormatProperties says so. Vulkan would
  have its memory types be those of a transient depth attachment of its
  format, the lazily allocated type among them (VkMemoryRequirements),
  and bound there nothing would be behind the pixels a later subpass
  reads. A program that makes one after the query declined it breaks
  VUID-VkImageCreateInfo-imageCreateMaxMipLevels-02251, so its
  `error_format_not_supported` is the second half's to read with the
  others; so is that of a transient colour attachment read as an input
  attachment, refused at the same line although no colour image is
  offered the lazily allocated type.
- UpdateDescriptorSets took the sampler of a write into a binding that
  holds samplers of its own for a sampler, before the binding's own took
  its place. Vulkan does not have it read there
  (VUID-VkWriteDescriptorSet-descriptorType-00325 asks for one only where
  the layout holds none), so it may be anything, and a handle that was not
  a sampler's stopped the call on its alignment. It is not looked at now.
- CreateSampler told a device that reads no unnormalized coordinates
  before the five rules such a sampler keeps; the rules come first now.
  Which of `error_validation_failed` and `error_feature_not_present` a
  call answers when it is asked for both is not promised otherwise, which
  the Result's doc says: Vulkan leaves the call undefined either way, and
  CreateRenderPass alone answers each at about twenty places, in the order
  it meets them. CreateFramebuffer
  holds every view to Vulkan's rules before it answers a level it cannot
  draw into.

**The second half, `error_format_not_supported`, done in 1.135**, in
57 lines of code, 257 of tests and 12 of FacetProbe, comments aside. The
count of 23 was right, and GetPhysicalDeviceImageFormatProperties alone
answers the code now, for a shape there is no image of. Of the 23:

- **22 answer `error_validation_failed`**, each with the rule it breaks
  named beside it or in its call's RESULT. CreateImageView's 16: a format
  the image takes no view of (VUID-VkImageViewCreateInfo-image-12397,
  -image-04441 for an image made for no view, -image-01761, and
  -None-02273 with the -usage- rules of the format's features), a swizzle none of Vulkan's (VUID-VkComponentMapping-r-parameter),
  levels or layers the image has not got, or none of them, a view type
  none of Vulkan's or one the image or the layers asked for do not take,
  an image not bound (-image-01020), and a plane its format has not got
  (-subresourceRange-09594). CreateRenderPass's three, an attachment
  whose format's features have not got what its use asks
  (VUID-VkSubpassDescription-pColorAttachments-02648,
  -pDepthStencilAttachment-02650, -pInputAttachments-02647).
  CreateBufferView's format no view takes
  (VUID-VkBufferViewCreateInfo-format-08778, -format-08779),
  CreateGraphicsPipelines's attribute format
  (VUID-VkVertexInputAttributeDescription-format-00623), and
  CreateSwapchain's format that is not the surface's
  (VUID-VkSwapchainCreateInfoKHR-imageFormat-01273, -surface-01270):
  a surface's format is fixed as the surface is made, so that refusal is
  no cause outside the program, as the size's may be.
- **CreateImage's one is split.** GetPhysicalDeviceImageFormatProperties
  asks the rules CreateImage keeps (`_image.shapeFor`, since 1.36) - at
  the largest extent, one level, the fewest layers and one sample, then
  each of the levels, the layers and four samples in turn - so an image
  CreateImage refuses is one the query declines
  (VUID-VkImageCreateInfo-imageCreateMaxMipLevels-02251), one past the
  extent, levels, layers or samples it answers (-extent-02252 to
  -extent-02254, -mipLevels-02255, -arrayLayers-02256, -samples-02258),
  or one that VkImageCreateInfo's own rules forbid whatever the query
  answers: a side, levels or layers of 0 (-extent-00944 to -extent-00946,
  -mipLevels-00947, -arrayLayers-00948); a cube that is not square or has
  fewer than six layers (-flags-08865, -flags-08866); more levels than its
  own extent's chain has (-mipLevels-00958, tests/facet.zig:791); more
  than one sample with more than one level (-samples-02257); or
  TRANSIENT_ATTACHMENT beside other usage or with no attachment usage
  (-usage-00963, -usage-00966). All of these are
  `error_validation_failed` but one kind, which Vulkan allows: a 3D image
  deeper than it is wide and high, of more levels than its width and
  height halve to and no more than its depth does. Vulkan counts the depth in
  the chain (-mipLevels-00958), the query's levels are those of its
  largest extent, whose three sides are alike, and the layout here halves
  the width and the height alone. It is `error_feature_not_present` until
  item 93; `_image.levelsPastSides` tells it apart by asking `shapeFor`
  for the same image of the levels its sides give.

Two of CreateImageView's refused what Vulkan allows, and take it now:

- **A 3D view of one layer.** A 3D image has one layer to Vulkan
  (VUID-VkImageCreateInfo-imageType-00961), and this library keeps its
  slices as its layers (`Image.layers`), so a view's range was held to
  the depth: a `layer_count` of 1, the one count Vulkan has besides
  REMAINING (VUID-VkImageViewCreateInfo-imageViewType-04973), was refused
  for an image deeper than a slice, and one of the whole depth, which
  -04973 and -subresourceRange-06725 forbid, was taken. The range is held
  to the one layer, as Mesa's is (`vk_image_view_init`,
  src/vulkan/runtime/vk_image.c:671), and the view holds every slice, as
  v3dv gives the TMU the depth of the image's first level and the view's
  first level apart from it (src/broadcom/vulkan/v3dvx_image.c:68,
  :79-80).
- **A cube array from any layer.** Vulkan counts a cube array's faces
  from `baseArrayLayer` and asks that the count alone be a multiple of
  six; the first layer had to be one as well. A view's texture begins at
  its first layer (`_image.levelsFrom`) and an array's cube is counted
  from there (`texture.Texture.cubeNear`), so it is taken as the code
  stood, as lavapipe's view begins wherever the range does
  (`lvp_create_samplerview`, src/gallium/frontends/lavapipe/lvp_image.c:372-375).

Reading the VUIDs found more:

- **A 3D view from a level past the first read slices its level has not
  got.** Its texture had the whole depth's slices whatever level it began
  at, so `slicesAt` halved from there and a sample spread `r` over slices
  no copy had written - the fault 1.59 mended for the image's own
  texture, back for such a view. It has the slices of its first level now
  (`texture.Texture.slicesAt` of the image's texture), as Mesa's view
  takes the extent of its first level and is as deep as that
  (vk_image.c:648-649, :695).
- **TRANSIENT_ATTACHMENT was taken beside usage Vulkan does not allow
  with it**: a depth attachment's beside the transfers, a colour image's
  beside them, SAMPLED or STORAGE, and on an image of no attachment
  usage at all. VUID-VkImageCreateInfo-usage-00963 has it beside the
  attachments' usage alone, and -usage-00966 with one of them; CreateImage
  answers `error_validation_failed` for both. `_image.laidOut` refuses the
  first, so the query declines it too. The second CreateImage refuses
  itself, before the image is laid out, and the query answers TRANSIENT
  alone as it answers the transfers alone - as TRANSIENT beside a colour
  attachment for the three formats drawn into, and `success` on the cores
  for a float or a BC format, which is no colour attachment - and so never
  more strictly: Vulkan has the limits of a usage within another be "no
  more strict" (vkGetPhysicalDeviceImageFormatProperties), and neither
  lavapipe nor v3dv reads a TRANSIENT bit there
  (`lvp_get_image_format_properties`,
  src/gallium/frontends/lavapipe/lvp_formats.c; v3dv_formats.c). Nor does
  `_image.viewable` count it as a view's usage any more, so a mutable
  image's views are asked by its attachment's feature alone.
- **CreateImageView looked at a depth image's binding and aspect only
  where the view reads it**, sampled or as an input attachment, though
  its RESULT named the binding rule for every image, and at a colour
  image's aspect not at all. A view of a depth attachment never bound, of
  a plane its format has not got, or of a depth or a stencil of a colour
  image was made. Each is `error_validation_failed` now
  (VUID-VkImageViewCreateInfo-image-01020, -subresourceRange-09594).
  BindImageMemory sets `memory` for the lazily allocated type too, which
  gives an image no bytes, so a transient depth attachment bound there is
  bound, and its view made.
- **On a device that keeps no format of both planes** (`stored_both`,
  the V3D), CreateRenderPass answered `error_feature_not_present` for a
  d16_unorm_s8_uint depth attachment loaded, stored or kept for another
  subpass. That device's format query gives the format no
  DEPTH_STENCIL_ATTACHMENT (`_format.describe`), so each breaks
  VUID-VkSubpassDescription-pDepthStencilAttachment-02650:
  `error_validation_failed`. One that keeps neither plane is still drawn,
  in the tiles alone (item 94). Read as an input attachment after the
  subpass that drew it, such an attachment breaks -pInputAttachments-02647
  as well, and is `error_validation_failed` for it
  (render/createrenderpass.zig:390) on a device without `stored_both`
  that reads a depth as an input attachment. No device is one: the V3D
  reads no input attachment and answers `error_feature_not_present` for
  any, as before (:347).
- **S8_UINT and D16_UNORM_S8_UINT did not say SAMPLED_IMAGE**, although
  CreateImage has made either sampled since 1.58 and Vulkan has a sampled
  image's format say it (Table 102, "Format Feature Dependent Image Usage
  Flags"). On a device that samples a depth (`sampled_depth`, the cores)
  they say it now, and D16_UNORM_S8_UINT its depth plane's FILTER_LINEAR
  too (`_format.describe`), as lavapipe says both of every depth/stencil
  format (`lvp_physical_device_get_format_properties`,
  src/gallium/frontends/lavapipe/lvp_formats.c:93-104).
- FacetProbe asked three things it could not: a 1D view of an image it
  had never bound, which CreateImageView refused for that once the view's
  own rules had passed; a view of both planes of a depth and stencil
  refused, which has been the depth since 1.94; and a stencil op on a
  D16_UNORM attachment refused, which keeps nothing since 1.106. All
  three ask what they meant to now.

Left for 1.137, each to be read as the 23 were - what the review of the
first half found, and the review of this half beside it:

- QueuePresent answers `error_out_of_date` for an image the program does
  not hold (VUID-VkPresentInfoKHR-pImageIndices-01430). A swapchain named
  twice (-pSwapchain-09231) is answered `error_out_of_date` where both
  name one image, the first naming having handed it on, and is presented
  twice, answering `success`, where they name two images the program
  holds. Both are `error_validation_failed`, the second looked for over
  the whole list. Out of date asks the program to make its swapchain
  again, which hides its mistake. Both are to be looked for before
  anything is handed on: a present that runs out of memory gives back
  what it took (`_swapchain.unhand`), but an image of a swapchain out of
  date it has given back already (queuepresent.zig:91), where Vulkan has
  a failed call leave everything as it was.
- QueuePresent answers `error_out_of_date` for each swapchain it meets
  once eight images of one present have been taken
  (`_swapchain.max_presents`; those it refused do not count), and Vulkan
  sets no such limit: a program makes that swapchain again and is refused
  again. The presents go in a list as long as the count, as the
  submission they are copied into already is (`_queue.makeSubmission`).
  It reads a null `wait_semaphores` beside a count as no waits, which
  VUID-VkPresentInfoKHR-pWaitSemaphores-parameter forbids. And it answers
  the last of its swapchains' failures, where Vulkan orders them - the
  device lost, then a surface lost, then out of date (vkQueuePresentKHR's
  body) - so a surface lost before another swapchain out of date answers
  `error_out_of_date`.
- AcquireNextImage answers `error_out_of_date` from a retired swapchain
  (swapchain/_swapchain.zig:118), which
  VUID-vkAcquireNextImageKHR-swapchain-01285 forbids ("Images cannot be
  acquired from a retired swapchain"): `error_validation_failed`, on the
  same reasoning as QueuePresent's.
- CreateSwapchain's size, `error_validation_failed` since 1.134
  (-pNext-07781), cannot tell a program that asked for the wrong size from
  one whose window changed size between its
  GetPhysicalDeviceSurfaceCapabilities and the call. Made at the size
  asked, the swapchain's presents and AcquireNextImage would answer
  `error_out_of_date`, which `_swapchain.fit` does already; Mesa's WSI
  (src/vulkan/wsi, not in the tree read for this) is to be read for it
  first.
- CreateSwapchain looks at the surface's newest swapchain alone
  (`surface.swapchain`, cleared when that one is destroyed), not at
  `old_swapchain`'s surface or whether it is retired: it answers
  `error_native_window_in_use` for any `old_swapchain` but the newest
  while the newest lives - one retired on this surface among them - and
  takes any where there is no newest, one retired after the newest was
  destroyed and one of another surface, which it retires, among them.
  VUID-VkSwapchainCreateInfoKHR-oldSwapchain-01933 has it be one of the
  surface's window and not retired: `error_validation_failed`. Vulkan
  keeps that rule by the native window, not the surface, and
  CreateWindowSurface and CreateScreenSurface make a surface each time
  they are called, so two can lie over one window, and a swapchain of one
  handed to the other is valid there; the cheapest way is a window's
  second surface refused with `error_native_window_in_use`, which
  vkCreateAndroidSurfaceKHR lists, or the rule kept for each window. With
  no `old_swapchain` where only retired swapchains of the window are left,
  Vulkan has `error_native_window_in_use` answered too.
- CreateSwapchain leaves `old_swapchain` as it was where it fails, and
  Vulkan has it retired "even if creation of the new swapchain fails".
  FacetGPU, Boing and Cobra try again with the same `old_swapchain` after
  `error_out_of_device_memory`, which a driver that retires it refuses:
  they are to destroy it and try again with none, which frees its
  pictures as well.
- CreateGraphicsPipelines and CreateComputePipelines answer
  `error_invalid_shader_nv` where the pipeline's stages break a VUID: an
  entry point not found (VUID-VkPipelineShaderStageCreateInfo-pName-00707),
  a stage that is not a graphics one
  (VUID-VkGraphicsPipelineCreateInfo-pStages-06896), no vertex stage
  (-stage-02096), one tessellation stage without the other (-pStages-00729,
  -pStages-00730), a compute stage that is not COMPUTE
  (VUID-VkComputePipelineCreateInfo-stage-00701). A fragment function that
  reads more varyings than the stage before it writes is refused the same
  way (VUID-RuntimeSpirv-OpEntryPoint-08743), and so is one that reads
  fewer, which Vulkan allows: what nothing reads is dropped. Item 4 kept
  that code for words that are not SPIR-V, which core Vulkan leaves
  undefined, and a vk.xml list that has the code is no reason to keep it
  for a VUID, the memory codes having moved although their calls list
  them. `error_validation_failed`, the second half of the varyings taken,
  and the code stays for words no device runs: a fixed form's word or a
  tessellation way that names none (creategraphicspipelines.zig:335,
  :439).
- A fragment function that writes as many colours as its subpass has, in a
  subpass without `SUBPASS_DESCRIPTION_OUTPUTS_TOGETHER`, is refused with
  `error_invalid_shader_nv`. Vulkan allows it: `error_feature_not_present`
  under item 80, which draws such a subpass in parts. On the V3D, whose
  `max_fragment_output_attachments` is 1, a function of more colours
  breaks VUID-RuntimeSpirv-Location-06272: `error_validation_failed` there.
- AllocateDescriptorSets past the pool's sets answers
  `error_out_of_pool_memory`, VK_KHR_maintenance1's code, which item 4 kept
  on purpose. On a 1.0 device without that extension
  VUID-VkDescriptorSetAllocateInfo-apiVersion-07895 forbids the call:
  `error_validation_failed`.

The reviews found more that is not a code answered wrongly, each for an
item of its own or one there is:

- GetPhysicalDeviceImageFormatProperties answers less than Vulkan has it
  answer, and in places more, item 94.
- CreateFramebuffer does not look at a view's type, and
  VUID-VkFramebufferCreateInfo-flags-04113 forbids one of type `3d`.
- Rules of Vulkan's no call reads: an image's SPARSE_ flags
  (VUID-VkImageCreateInfo-flags-00969) and its `initial_layout`
  (-initialLayout-00993); the swapchain's colour space, and its `pre_transform`
  and `composite_alpha` (VUID-VkSwapchainCreateInfoKHR-preTransform-01279,
  -compositeAlpha-01280); a `min_image_count` of 0 or past the surface's
  most (-presentMode-02839, -minImageCount-01272), held to 1 to 4
  instead, so a count of 4 on a screen of fewer answers
  `error_out_of_device_memory`; a stage named twice
  (VUID-VkGraphicsPipelineCreateInfo-stage-06897), an attribute offset
  past `max_vertex_input_attribute_offset`
  (VUID-VkVertexInputAttributeDescription-offset-00622), and a location or
  binding named twice; a texel buffer view past
  `max_texel_buffer_elements` (VUID-VkBufferViewCreateInfo-range-00930),
  which the descriptor holds to it; the descriptors a pool has of each
  type, `pool_sizes` not being read
  (VUID-VkDescriptorSetAllocateInfo-apiVersion-07896); and a present of
  no swapchains (VUID-VkPresentInfoKHR-swapchainCount-arraylength). Each
  is `error_validation_failed` where it is read, item 81's kind; none was
  found to reach anything that breaks.
- GetPhysicalDeviceSurfaceFormats answers a count of 0 for a display it
  does not draw, where Vulkan has it answer one at least; asking it of
  such a surface breaks -surface-06525, so no valid program sees it.
- `_image.compatible` holds two formats to one texel size through
  `texelSize`, which is 0 for the formats no image is made of
  (driver/_format.zig:276-303): R16_SFLOAT and R16G16_SFLOAT; R8, R8G8,
  R8G8B8A8, R16, R16G16 and R16G16B16A16 _SNORM; R8, R8G8, R8G8B8A8 and
  B8G8R8A8 _SRGB; A8B8G8R8_UNORM, _SNORM and _SRGB_PACK32; the
  2-10-10-10 words; and R32G32B32_UINT and _SINT. So it calls them
  compatible with none, where Vulkan's size classes have them compatible. Their
  image features are none, and a view of one is refused for that
  (-None-02273); item 34, which makes images of some, is to give
  `texelSize` their sizes first.

> The 23, and where each went: the 135 note in facet_version.zig;
> `git show c0b3359a:<file> | grep -n error_format_not_supported` beside
> the file now, 08.11.2026.

> The 66, and where each went: the 134 note in facet_version.zig;
> `git show 305d3c74:<file> | grep -n error_initialization_failed` beside
> the file now, 08.11.2026.

### 92. A framebuffer larger than a view's level, and a subpass reading its own depth attachment, are refused

*render passes* &mdash; conformance-blocking, medium, found while doing item 91

Two refusals of valid usage that answered `error_initialization_failed`,
and since 1.134 answer `error_feature_not_present` until this item:

- **A framebuffer larger than the level a view names, of an image that
  is not.** Vulkan holds a framebuffer's size to each attachment's image,
  its first level (VUID-VkFramebufferCreateInfo-flags-04533 and -04534:
  "created with a VkImageCreateInfo::extent.width greater than or equal
  to width"), not to the level the view names, and the render area to
  the framebuffer alone ("must be contained within the framebuffer
  dimensions"). Load, store and resolve act on "the pixels whose x and y
  coordinates fall within the render area on all attachments", which for
  a level smaller than the area are the level's own. A pass here has no
  rows past the level's to draw into, so CreateFramebuffer refuses the
  view (`fitOf`'s `level_smaller`, for a colour, a resolve and a depth
  view), once every view has been held to Vulkan's rules.
  The fix is each attachment's load, clear, store and resolve clipped to
  that attachment's own level, not to the framebuffer: on the cores the
  Target refuses an area past a surface
  (driver/cpu/raster/target.zig:714, `error.OutOfBounds`), a depth or
  stencil Plane carries no size of its own (target.zig:477-484), and
  `clearLayers` writes straight into the rows
  (driver/cpu/_play.zig:440-459); a colour Surface already carries its
  level's size (_play.zig:392-397). The V3D's tile loads and stores want
  the same.
- **A subpass that reads its own depth attachment as an input
  attachment.** Vulkan allows it: an attachment may not be used twice in
  a subpass, "with one exception", an input attachment beside a colour or
  depth/stencil use - "the same view can be used simultaneously as an
  input and color or depth/stencil attachment". The cores keep the depth
  in the tile and read an input attachment from the image's rows, so the
  subpass would read the depth as it was before the pass. CreateRenderPass
  refuses it where the attachment is of a depth format. The fix is the
  depth read from the tile, as a colour attachment read as an input has
  been since 1.65 (`shader.Fragments.input`, then `colorAt`) - which is
  v3dv's answer: an input attachment that is the subpass's own depth
  attachment is read from the tile buffer as `FRAG_RESULT_DEPTH`
  (src/broadcom/vulkan/v3dv_pass.c:122-124, lowered by
  `lower_tlb_input_attachment_instr`, v3dv_pipeline.c:301-355).

> `render/createframebuffer.zig` `fitOf` and its three callers;
> `render/createrenderpass.zig`, the input attachments' loop
> (`depth.attachment == reference.attachment`); the spec's
> VkFramebufferCreateInfo, VkRenderPassBeginInfo::renderArea and
> VkAttachmentDescription's body; 08.11.2026.

### 93. A 3D image deeper than it is wide and high is refused the levels its depth gives, and a 3D sample's level does not count its depth

*images / 3D* &mdash; conformance-blocking, small, found while doing item 91

Vulkan counts a 3D image's chain of levels from the longest of its three
sides - `mipLevels` "must be less than or equal to the number of levels
in the complete mipmap chain based on extent.width, extent.height, and
extent.depth" (VUID-VkImageCreateInfo-mipLevels-00958) - and each level
halves all three, never below one. This library keeps a 3D image's slices
as its layers, each slice a whole texture of the image's levels
`layer_bytes` from the one before, and a level has half the slices of the
one before (`texture.Texture.slicesAt`); but a texture's levels are those
its width and height halve to (`texture.Sizes.of`, where more is
`error.BadSize`). So a 4x4x16 image is made of up to 3 levels, and its 4th
and 5th - a texel each of 2 slices and of 1 - are refused. Since 1.135
CreateImage answers `error_feature_not_present` for them
(`_image.levelsPastSides`); GetPhysicalDeviceImageFormatProperties, whose
`max_mip_levels` is that of its largest extent, 256 on every side, says
the 9 Vulkan has it say.

The port is llvmpipe's layout, the three sides halved alike for each
level (`u_minify` of each, src/gallium/drivers/llvmpipe/lp_texture.c:220-222,
in `llvmpipe_texture_layout`), as lavapipe hands it the image's depth and
levels (`lvp_alloc_plane`, src/gallium/frontends/lavapipe/lvp_image.c:101,
:103). Each slice here holds its own levels, and those past the sides are
a texel wide and high, which `Sizes.widthAt` and `heightAt` hold them to
already; what changes is the count. `Sizes.of`, `Texture.bytes` and the
texture made over the memory are told the depth and count the levels from
the longest side; `_image.laidOut` hands them a 3D image's; and
`levelsPastSides` goes, CreateImage's split with it. About 15 lines, and
25 of tests: the 4x4x16 image's five levels copied into and sampled at
each.

The second half is the level a 3D sample takes. Vulkan's scale factor
counts each coordinate's change times that side of the level - `r`'s
times its depth beside `s`'s and `t`'s times its width and height
("Scale Factor Operation": m~wx~ = |∂r/∂x| × d~base~) - and llvmpipe's
does: `lp_build_rho` multiplies each of the `dims` derivatives by its side
of the first level (src/gallium/auxiliary/gallivm/lp_bld_sample.c:691-713)
and takes the largest of the three (:716-732), the implicit derivatives
counting `r`'s where `dims > 2` (:765-772, :799-809). Here a 3D sample
takes its level from `s` and `t` alone: `texture.Point` carries no
derivative of `r`, the fixed form `texture_3d` hands `texture.levelFor`
those of `s` and `t` (sdk/libs/facet/shader.zig:2041-2045), and
`texture_3d_sampled` those two in its point (:2198-2212, :2222). A volume whose `r` changes
faster than its `s` and `t` is read at too fine a level. The port is the
two derivatives of `r` in the point and the depth in `levelOf` and
`levelFor`: about 20 lines, and 20 of tests, a quad whose `r` alone
changes reading the level its depth gives. The V3D's TMU takes its level
from the three coordinates itself.

Neither half is the V3D's to write, but the board is to show one thing
first: v3dv keeps a 3D image level after level, each level's slices
together (`v3d_setup_plane_slices`, src/broadcom/vulkan/v3dv_image.c:160-178,
:263-264), and this library's V3D keeps each slice's levels together,
handing the TMU `layer_bytes` as the distance from one slice to the next
(driver/v3d/_play.zig:913); which of the two its TMU reads at a level past
the first, no run has asked.

> `texture.Sizes.of` (sdk/libs/facet/texture.zig:1557-1566), `levelOf`
> (:3199-3206) and `levelFor`; `_image.levelsPastSides`; the spec's
> VkImageCreateInfo and "Scale Factor Operation"; 08.11.2026.

### 94. GetPhysicalDeviceImageFormatProperties answers less than Vulkan has it answer, and in places more

*formats / queries* &mdash; conformance-blocking, medium, found while doing item 91

The query asks the rules CreateImage keeps (`_image.shapeFor`), so the two
cannot drift apart, and since 1.135 an image the query declines is
`error_validation_failed` from CreateImage
(VUID-VkImageCreateInfo-imageCreateMaxMipLevels-02251), but for 3D
images one slice deep. The query asks 256 slices, and so declines every
3D image neither sampled nor written through (image/_image.zig:673) and
every one written through as a colour or input attachment, which
`rows_written` takes at one layer alone (:771-775, :818, :827), while
CreateImage makes the one-slice image of three kinds: of a colour format
kept in rows, for the transfers or as a colour or input attachment
(tests/facet.zig:1071, :1081); of B8G8R8A8 or R5G6B5, of one level,
written through as a colour or input attachment; and on the cores, of
compressed blocks, which they keep in a texture's layout whatever the
image is for (`kept_compressed`, image/_image.zig:682, :826-827), for the
transfers or as an input attachment. -02251 allows that, creating any of
them being invalid usage. The other way round, the query answers
TRANSIENT_ATTACHMENT alone as the transfers alone, no more strictly than
beside a colour attachment, as the subset rule below has it, and
CreateImage refuses such an image (-usage-00966; since 1.135). Where
those rules are narrower than Vulkan has a device be, the query's answer
breaks Vulkan's rules for the query itself:

- **`max_resource_size` below 2^31.** It is the bytes of the largest image
  the rest of the answer describes (since 1.66): 256 MiB for a linear
  8192x8192 B8G8R8A8 colour attachment. Vulkan has it "at least 2^31^"
  (VkImageFormatProperties), and lavapipe answers UINT32_MAX
  (`lvp_get_image_format_properties`,
  src/gallium/frontends/lavapipe/lvp_formats.c:447). The bytes or 2^31,
  whichever is more: 1 line, and tests/facet.zig:1207 and :1286 with it.
- **One level and one layer for some optimal 2D images.** Vulkan has an
  optimal 2D image's answer be the whole chain of levels and no fewer
  layers than `max_image_array_layers`. A colour attachment written
  through as a storage image is held to one of each (`rows_written`,
  image/_image.zig:771-775), and on the V3D every image kept in rows to
  one level (:860-863). The first wants its levels and layers laid out as
  the rows of an image sampled where it is drawn are since 1.119, about 10
  lines; the second is item 48's V3D half.
- **Fewer usage bits are refused where more are taken**, which Vulkan
  forbids: the limits for usage that is a subset of another "must be no
  more strict". An image of a small texel, of r8_unorm, of wide channels
  or of whole numbers (image/_image.zig:643, :648, :654, :660), or a 3D one
  deeper than a slice (:673), is made where SAMPLED or STORAGE is among
  its usage and declined where the transfers alone are; a depth or
  stencil format's is declined without DEPTH_STENCIL_ATTACHMENT - SAMPLED
  alone, the transfers alone, TRANSIENT_ATTACHMENT alone - and made with
  it (:744). Kept in a texture's layout, as an image of compressed blocks
  for the transfers alone is since 1.126, the first takes about 5 lines;
  a depth image without the attachment's bit kept in rows as a depth
  attachment is, about 5.
- **A 3D image a colour attachment is declined**, where Vulkan has a
  format's features hold "for every VkImageType" (Required Format
  Support), and lavapipe holds a 3D image's usage to its format's
  features alone, as any other's (`lvp_get_image_format_properties`,
  lvp_formats.c:369-374, :394-434). No pass of
  Vulkan 1.0 draws into one (VUID-VkFramebufferCreateInfo-flags-04113), so
  it is made and never drawn: about 3 lines.
And it answers more than Vulkan lets it where a format's features have
not got the bit a usage wants (Table 102, "Format Feature Dependent Image
Usage Flags"), to which lavapipe and v3dv hold every usage
(`lvp_get_image_format_properties`, lvp_formats.c:394-435;
`get_image_format_properties`, v3dv_formats.c:512-551). The second and
the third were found in the check of this item:

- **On the V3D, a D16_UNORM_S8_UINT depth attachment is made** while the
  format's features say no DEPTH_STENCIL_ATTACHMENT there (`stored_both`),
  and CreateRenderPass takes one that keeps neither plane
  (VUID-VkSubpassDescription-pDepthStencilAttachment-02650); one that
  loads, stores or is kept for another subpass is `error_validation_failed`
  since 1.135 (`error_feature_not_present` before). The query and the
  features are to say the same, testable on the host by a device without
  `stored_both`, as tests/draw.zig's "a device that keeps no format of
  both planes" is.
- **SAMPLED with STORAGE of a BC, ETC2, EAC, B4G4R4A4 or A1R5G5B5 format,
  on either device.** Such an image is unpacked into R8G8B8A8, a block
  having no texel to write (image/_image.zig:682, :687), and made a
  texture a function writes through (:826), as tests/draw.zig:3262-3274
  has it, while those formats' features hold no STORAGE_IMAGE
  (driver/_format.zig:168-192), which Vulkan has STORAGE want. A float
  format is unpacked on the V3D as well and says STORAGE_IMAGE, being
  written through as 8888 there, so it is the feature that is to be
  asked, not the unpacking.
- **An input attachment of a float or BC format, on the cores.** Such an
  image is made and answered, kept in rows or, for blocks, in a texture's
  layout (image/_image.zig:816-819 asks nothing of its format), while the
  format's features hold neither COLOR_ATTACHMENT nor
  DEPTH_STENCIL_ATTACHMENT, one of which Vulkan has INPUT_ATTACHMENT
  want, and CreateRenderPass refuses it as an input attachment
  (VUID-VkSubpassDescription-pInputAttachments-02647). On the V3D such a
  format is unpacked, and an image unpacked without SAMPLED is declined
  already (image/_image.zig:692).

Holding each usage to its feature in `_image.shapeFor`, as both drivers
do, mends all three: about 8 lines, with tests/draw.zig:3262-3274 turned
round and the host's device without `stored_both` asked the D16S8 depth
attachment.

> instance/getphysicaldeviceimageformatproperties.zig; image/_image.zig
> `laidOut`; the spec's VkImageFormatProperties, the query's body and
> Required Format Support; 08.11.2026.

## What the V3D port leaves for the Radeon's

After the V3D, facet's next device is a Radeon, ported from radv as the V3D is from v3dv. Some of what the V3D port leaves out it leaves out because the V3D does not have it. A Radeon has much of it, and its port has to bring it, or it stays missing. This list keeps those together, so that the Radeon port misses nothing. Started at 1.203; each step's "Still left out" since marks its entries *facet-wide* or *V3D-only* the same way. What radv answers for each is still to be read from radv's sources, which the Mesa checkout here does not hold.

**Features v3dv reports off, so the V3D port never does them** (v3dv_device.c:328-393; facet reports each off too, getphysicaldevicefeatures.zig:133-279):
- tessellationShader, and with it OpControlBarrier outside compute shaders (1.203).
- multiDrawIndirect, multiViewport, variableMultisampleRate.
- textureCompressionBC, pipelineStatisticsQuery.
- shaderStorageImageMultisample, shaderStorageImageWriteWithoutFormat.
- shaderCullDistance.
- shaderFloat64, and with it PackDouble2x32 and UnpackDouble2x32 (1.201). shaderInt64.
- shaderResourceResidency, shaderResourceMinLod, and the sparse features.
- The four ...ArrayDynamicIndexing features, which v3dv has only behind its WebGPU override (v3dv_device.c:313, 371-374).

**Limits the V3D sets lower than Vulkan's:**
- A workgroup of more than 256 invocations runs on the cores (V3D_MAX_CSD_WG_SIZE, v3d_limits.h:82; 1.194, 1.203).

**Features v3dv has and facet reports off.** These are facet-wide: the V3D port may still do them from v3dv, and until it does, a Radeon port meets them too.
- geometryShader, and shaderTessellationAndGeometryPointSize.
- sampleRateShading, and with it the InterpolationFunction capability (Vulkan's SPIR-V capability table), so the interpolation functions (1.201). Mesa answers them with the plain varying where the draw is not multisampled (nir_to_vir.c:4075-4081).
- dualSrcBlend, alphaToOne.
- vertexPipelineStoresAndAtomics.
- shaderImageGatherExtended, shaderStorageImageExtendedFormats, shaderStorageImageReadWithoutFormat.
- shaderClipDistance; shaderInt16 on V3D 7.1.
- textureCompressionETC2, textureCompressionASTC_LDR.
- inheritedQueries.
- maxComputeSharedMemorySize: facet's 16 KiB, v3dv's 32 KiB (1.203).

**What the compiler takes from v3dv's options, which a Radeon's takes from radv's:**
- The divergence analysis's options: v3dv's are nir_divergence_multiple_workgroup_per_compute_subgroup alone (v3dv_pipeline.c:217-218), so the workgroup id differs from lane to lane, and with no nir_divergence_vertex the instance id does too. They are built into `lanes()` in compile.zig (1.204).

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
