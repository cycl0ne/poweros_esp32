# facet.library: a shader a device can compile

What a program's shader is today: a Zig function, compiled for the host
CPU, found through a function pointer in a module stamped `FCTZ`
(`sdk/libs/facet/shader.zig`). The V3D cannot run it - the QPUs execute no
program of the library's - so it runs the seven hand-written QPU programs
instead, and `CreateGraphicsPipelines` refuses every pipeline that wants
anything else. `docs/facet-todo.md` section 4 is the plan this document
settles: the shader becomes something a device can **compile**, and the
first thing compiled is the V3D's.

The decision this document records, and its one reason:

> **The shipped form of a shader is a real SPIR-V module.** Not a format
> of facet's own that resembles one. The reason is testing: `spirv-val`
> checks every module the library emits, `glslc` turns any GLSL shader
> into test input, `spirv-dis` makes a failure readable, Mesa's
> `src/broadcom/compiler` is a reference back end **for this exact chip**,
> and a desktop Vulkan driver renders the same module for a reference
> picture. A private format buys none of that, and would have to be
> defended by hand.

The second reason is the one `facet-todo.md:209` gives: the input language
belongs to the library, so each later device costs a back end and nothing
else. Both reasons want the same thing, which is why this is worth doing
properly rather than quickly.

## What a program writes, and what it ships

One source. A shader is recorded at **comptime** as a small graph
(`sdk/libs/facet/ir.zig`), and two artefacts are taken from it:

| Artefact | What it is | Who reads it |
|---|---|---|
| `words` | a SPIR-V 1.0 module, `const`, in the program's rodata | a device that compiles: the V3D, later an RDNA one; `spirv-val` and a desktop driver in the tests |
| the function | a `shader.FragmentFn` the comptime graph expands **inline** over the quad batch | the cores, at today's speed |

The cores keep running Zig, because their fragment ABI is one
`callconv(.c)` call per 64 quads with `@Vector(4, f32)` rows and no
per-pixel branching, and an interpreter cannot meet that bar. The graph is
walked at comptime, so the generated function is as specialised as a
hand-written one: `values[k]` is a comptime index, `inline for` over the
ops leaves no loop, and `exact` stays a comptime parameter rather than a
branch in the quad loop.

```zig
const Textured = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.mul(b.sample(0, 0, b.input(0, .f32x2)), b.input(1, .f32x4)));
    }
}, .{ .varyings = 6 });

// In the module, beside each other, from the one graph:
//   shader.fragment("textured", Textured.fragment, 6)   - the cores
//   Textured.words                                      - every other device
```

`ir.Build` is a recorder: each call appends an operation and answers its
index, which is the only handle a program gets. There is no expression
overloading, no operator precedence and no type inference past what the
operations state, because the graph has to be readable by a back end that
has never heard of Zig.

## How the words reach the library

`shader.Entry` and `shader.Code` **cannot grow**. `Entry` is an `extern
struct` of 32 bytes on aarch64 and 16 on riscv32 (facet ships on the
ESP32-P4 as well); `CreateShaderModule` copies the program's entry array
with the **library's** `@sizeOf(shader.Entry)`, and refuses a module whose
`code_size` is under the **library's** `@sizeOf(shader.Code)`. One field
added to either, and every program already on `DH0:` is read past its own
array or refused outright. 1.48 and 1.58 taught this lesson about
`texture.Format` and `texture.Texture`; it is not to be learned again.

So the words ride **beside** the entries, in a struct whose first fields
are a byte-exact prefix of `Code`, and the library is told to look for
them by a flag:

```zig
/// What ShaderModuleCreateInfo.code points to where the stages ship
/// their SPIR-V as well. Its first fields are `Code`'s, so a library
/// that has not got SHADER_MODULE_CREATE_SPIRV reads it as a `Code` and
/// runs the Zig functions. (Since 1.75.)
pub const Module = extern struct {
    magic: u32 = MAGIC,
    entry_count: u32,
    entries: [*]const Entry,
    /// One a side of `entries`, index for index: entry k's words are
    /// `spirv[k]`, and a `count` of 0 is an entry with none.
    spirv: [*]const Spirv,
    spirv_count: u32,
};

pub const Spirv = extern struct {
    words: [*]const u32,
    count: u32,
};

comptime {
    // The prefix is the compatibility, so it is asserted, not intended.
    if (@offsetOf(Module, "magic") != @offsetOf(Code, "magic")) @compileError("Module's prefix is not Code's");
    if (@offsetOf(Module, "entry_count") != @offsetOf(Code, "entry_count")) @compileError("Module's prefix is not Code's");
    if (@offsetOf(Module, "entries") != @offsetOf(Code, "entries")) @compileError("Module's prefix is not Code's");
    if (@sizeOf(Module) <= @sizeOf(Code)) @compileError("Module must be wider than Code");
}
```

The magic stays `FCTZ`. The flag is a bit of
`ShaderModuleCreateInfo.flags`, which **no revision of the library has
ever read** - and the words are pointed at, not copied, exactly as an
entry's name and function already are.

| | What happens |
|---|---|
| New library, old program | Byte for byte what happens today: no flag, no sidecar, the first three fields are all there is. |
| **Old library, new program** | The module is **accepted**: `code_size` passes the `<` check, the magic matches, the entries are at the offsets it expects, the tail is ignored. The program draws on the cores - which is where it draws on such a library anyway. No revision gate in the program, and nothing lost but the GPU path. |
| New library, new program | The flag is set, `code_size` proves the struct is that wide, `spirv_count` must equal `entry_count`, and entry k's words are `spirv[k]`. |
| Stale `v3d.fdriver` | `_driver.stamp` mixes `LIBRARY_REVISION`, so the board's driver module is refused with a log line at **every** revision of this work and must be replaced each time. The V3D then does not appear at all, and every program draws on the cores. |

Index pairing rather than a record of its own means the sidecar carries no
second copy of `_shader.find`'s `(stage, name)` key, and nothing per-entry
that could drift out of step with `Entry`. The library refuses
`spirv_count != entry_count` rather than trusting it: the array is the
program's.

## The subset, and two tiers of refusal

`spirv-val` is not a subset checker. Measured on this machine, it accepts
`Workgroup` variables in a fragment shader, `OpAtomicIAdd`,
`OpTypeRuntimeArray`, `OpDPdx`/`OpDPdy`/`OpFwidth` (plain `Shader`
capability, no extra), `OpImageSampleExplicitLod` with `Grad`, unbounded
loops with `OpPhi` across the header, `OpSwitch`, `OpFunctionCall`,
separate `OpTypeSampler`, `ImageFormat Rgba8` on a sampled image, two
entry points in one module, and any entry-point name. facet refuses those
itself, through three allowlists - capability, opcode, type and storage
class - and `spirv.Profile` is the type that holds one.

Refusal happens in two places, and the difference matters:

| Where | What it refuses | Result |
|---|---|---|
| `CreateShaderModule`, against `spirv.facet_profile` | a module that is **malformed**: a bad header, a word count that walks off the end, an id over the bound, a section out of order, no entry point | `error_invalid_shader_nv` |
| `make_pipeline`, against the **back end's own** `Profile` | a module that is well formed but asks for what this device will not compile | `error_feature_not_present` |

A module that is merely *richer* than facet's subset is not refused by the
library: it is kept, logged, and left for a device that can take it. The
library must never refuse words a later back end could run - that is the
one mistake that costs `facet-todo.md` section 4's steps 1 to 5 twice.

`spirv.zig` holds the format and nothing else. It imports `std` and never
imports `ir.zig`, because **a back end does not need facet's language to
compile facet's SPIR-V - it needs the format.** The build enforces it:
`build.zig:1313` gives the `v3d` module `sdk` and nothing more.

## Where the colour convention is paid

SPIR-V speaks 0 to 1. facet's existing forms do not: a vertex function
writes a channel through `shader.channel(v) = v * 255 + 0.5`, the varying
carries it pre-scaled, and `smoothQuads` does `bytesOf(over_w * w)` with
no scaling of its own. The V3D path undoes it again in `_play.zig`'s
`Carried` union, to hand the QPUs 0 to 1.

The rule, in one line each way:

- **The graph is 0 to 1**, Vulkan's convention, so the words mean to a
  desktop driver what they mean to facet. The conversion lives in exactly
  one place: the generated function's sink, `bytesOf(channel(v))`.
- **A program whose fragment entry is generated does not call
  `shader.channel` in its vertex function.** Its varyings carry 0 to 1.

The hand-written fixed forms are left exactly as they are, and keep
drawing every pipeline that names one. The generated path serves
`FixedKind.none` - a fragment function of the program's own - and nothing
else. So no existing picture changes, `FacetCube CHECK` keeps comparing
the same code that produced its reference, and the fixed forms become the
**oracles** the generated path is proved against rather than something it
replaces.

## The files

| File | What it owns | Imports |
|---|---|---|
| `sdk/libs/facet/spirv.zig` | the format: opcodes, enums, the emitter's word buffer and type interning, the reader, `Profile`, `facet_profile` | `std` only |
| `sdk/libs/facet/ir.zig` | the language: `Kind`, `Tag`, `Op`, `Build`, `Graph`, `Fragment`/`Vertex` type forms, the words via `spirv.zig`, the generated core function | `std`, `spirv.zig`, `shader.zig` |
| `src/disk/libs/facet/tests/spirv.zig` | the emitter against validated modules, the reader's refusals | reached from `src/disk/tests.zig` |
| `src/disk/libs/facet/tests/ir.zig` | a generated function against the hand-written fixed form it mirrors | as above |
| `src/disk/libs/facet/driver/v3d/compile.zig` | the QPU back end: SPIR-V words to `u64` instructions | the `v3d` module, host-tested from `v3d.zig` |
| `scripts/spirv-check.sh` | emits the library's modules and runs `spirv-val` over them, skipping with a message where the tool is absent | - |

A test in `sdk/libs/facet/` never runs: `sdk` is always an imported
module and never a test root, which is why `texture.zig`'s own test has
been dead since 1.20. Every test above lives where it is reached.

## The QPU back end

Three levels, so that everything checkable is checked in the pure middle
one, on the host:

1. **`Program`** - what the words asked for, read by `spirv.zig`.
2. **`Plan`** - registers assigned, instructions chosen, nothing encoded.
   Every rule lives here and every test reads here.
3. **`u64` words** - `qpu.zig`'s encoders, one call an instruction.

The rules the hardware does not forgive, as structure rather than
intention:

- `last_section` - two `thrsw` in a row, with the scoreboard wait - is
  **spliced in as a shared constant** from `qpu.zig`, never scheduled and
  never copied. Without it a pixel reaches the tile buffer ahead of one
  drawn before it at the same place and the renderer hangs; a hang sets
  `hardware.broken` on the one `Hardware` every instance of the library
  shares, so it costs the display driver and every other client until the
  last one lets go.
- Registers: next free, except that a dying operand may be the
  destination; over 16 live values the pipeline is refused rather than
  spilled. A threaded fragment program has 16 registers and there is no
  stack on a QPU.
- No scheduler. The latencies are honoured by emitting the same shapes
  the hand-written programs use: `varying()`'s three instructions,
  `ldtmu` after the TMU write, two `nop`s after `recip`.
- Ten registers, not sixteen: rf0 to rf2 are the hardware's, rf3 is W,
  and rf14 and rf15 are what every varying read passes through. So a
  value lives in rf4 to rf13, and `compile.zig`'s `registers` is 10.
- A varying is taken in order and cannot be stepped over: `ldvary` hands
  over the next one there is. So every varying up to the last one the body
  reads costs its three instructions, read or not, and the input locations
  have to be 0 upwards without a gap - that is the numbering a vertex
  function writes (`ir.Build.input` holds a shader to it), and a module
  that means another one is refused rather than mis-compiled.
- A uniform is read where it is first wanted, not at the top: `ldunifrf`
  takes the next one in the stream wherever its instruction sits, so the
  order of the stream is the order the body asks, and a constant does not
  hold a register from the start of the program. It is what lets eight
  varyings and four floats of its own fit ten registers.
- Two things the source does not settle, paid for rather than guessed: how
  long an `ldunifrf` is before its register may be read, and what the
  hardware makes of a program that reads fewer varyings than its record
  declares. The first is waited out to the six instructions `flat_code`
  leaves, with `nop`s where the plan is tighter; the second never arises,
  because every varying the draw carries costs its three instructions
  whether the body reads it or not, as in all seven hand-written programs.
- A decoration the back end does not understand is **refused**, not
  ignored. `Flat` and `NoPerspective` are the reason: a varying decorated
  either way is not what `qpu.varying` interpolates, and a wrong colour
  with no fault behind it is the hardest failure to find. So is
  `OpExecutionMode`: `OriginLowerLeft` compiles to the same words as
  `OriginUpperLeft` and draws the picture upside down, so the mode is read
  and only the one facet emits is taken.
- The first form to reach the GPU is the **interpolated colour**, not flat
  colour: `driver.Programs` has no `flat` field and `loadPrograms` loads
  six programs, so flat has no preloaded program to diff against at run
  time, while `color_fragment` does.
- The first board run is in **`C:test/v3dtest`**, a standalone command, not
  in a pipeline. A hang there costs a reboot; a hang inside the library
  costs the machine's display.

Generated code is allocated per pipeline from `hardware.space.alloc` (its
own block, page-aligned, which `cl.shaderRecord`'s flag bits in the low
bits of a program address require), written, `space.toGpu`'d, and freed in
`unmake_pipeline`. The per-frame chunks cannot hold it: `beginRenderPass`
resets them.

## The test ladder

Each rung is a thing that can fail on its own, cheapest first:

1. **Byte-exact words.** The emitter's output against five modules
   assembled with `spirv-as` and validated with `spirv-val` - `min_flat`
   70 words, `min_interp` 72, `min_tex` 113, `min_texmod` 135,
   `min_discard` 141 - and two of facet's own that an assembler cannot
   give the same ids, validated all the same: `min_vert` 193 against the
   assembler's 200, and `min_scaled` 94. Host test, no tools needed.
2. **`spirv-val`.** `scripts/spirv-check.sh` over every module the library
   can emit. Skips with a message where SPIRV-Tools is not installed.
3. **The reader's refusals.** A malformed module per rule - bad magic,
   bad bound, a word count off the end, a section out of order, a
   capability outside the allowlist - each refused with its own result.
4. **The generated function against the fixed form.** The same scene
   through `shader.smooth` with pre-scaled planes and through the
   generated function with unscaled ones, pixel for pixel, on the host.
5. **The QPU words against the hand-written program.** `compile.zig`'s
   output for the interpolated colour against `qpu.color_fragment`,
   instruction for instruction, on the host - plus the structural checks
   the existing suite does not make: every destination of every
   instruction below rf16 on **both** the add and the mul side, and
   exactly one `last_section`, in the right place.
6. **The board, standalone.** `C:test/v3dtest GENERATED` renders with
   generated code and checks every pixel against the arithmetic in the
   test. Run on the CM5: the interpolated colour, a colour of its own from
   four uniforms, and a colour dimmed by a fifth varying - 0 wrong of
   866813, 902720 and 885760 pixels, about 750 us a frame each.
7. **The board, in the library.** `C:test/FacetProbe`, `FacetBoth` on both
   devices, `FacetCube CHECK`, `FacetMany` for the draw time. Run on the
   CM5 at 1.76: FacetProbe 726 checks and none failed, FacetCube `CHECK`
   alike, FacetMany 99856 triangles in 11.6 ms a frame of 1920x1080.
   FacetBoth draws every case on both devices and a few of them are a
   handful of pixels apart - 14 of 230400 across a cube's edge, 11 in a
   subpass - which is the cores' rasteriser against the V3D's, in draws
   that ship no SPIR-V at all and go nowhere near `compile.zig`.
8. **A desktop Vulkan driver.** The same module through Mesa on this PC,
   rendering the same triangle, compared with facet's own picture under
   the slack `FacetBoth` already uses. This is the rung that makes the
   choice of SPIR-V pay for itself, and the one that catches a wrong
   reading of the spec rather than a wrong implementation of facet's
   reading of it.

Rungs 1 to 5 run in `./zig build test`. Rung 2 is a script because a
build step that fails where a tool is missing would break the build for
anyone without SPIRV-Tools.

## The order of the work

| # | What | Revision |
|---|---|---|
| 1 | this document | - |
| 2 | `Fixed.fromBits` range-checked, an unknown fixed kind refused in `settle` - a latent `@enumFromInt` on a program's own word, fixed before anything neighbours it | 1.75 |
| 3 | `spirv.zig`: the format, the emitter, the reader, `Profile`; rungs 1 to 3 | 1.75 |
| 4 | `ir.zig`: the graph, the words, the generated core function; rung 4 | 1.75 |
| 5 | the library: `Module`, the flag, `CreateShaderModule`, `settle`, `Pipeline`'s words, `PhysicalDeviceFeatures` | 1.75 |
| 6 | `compile.zig`: the interpolated colour to QPU words; rung 5 | - |
| 7 | the V3D driver: code per pipeline, the shader record, `make_pipeline`; rungs 6 and 7 | 1.76 |
| 8 | rung 8, and a form a family at a time after it - discard and samplers first, since those are what send most draws to the cores today | - |

Step 6 changes nothing a program can see - `compile.zig` is reached from
its own host tests and from nowhere else yet - so it is not a revision.
The driver begins to compile in step 7, and that is.

Steps 1 to 7 are done and on the board: rungs 1 to 5 in `./zig build
test`, rungs 6 and 7 run on the CM5 as the ladder above records. What is
left is step 8.

Steps 2 to 5 are the library's side and are provable on the host. Step 6
is where the days go. `facet-todo.md` section 4 says months for the whole
of it and that is not an exaggeration: what is here is steps 1 and 2 of
its own five, and the scheduler and allocator it describes are deliberately
not attempted - the generated programs are macro expansions of shapes the
hand-written ones already prove.

## What this is not

- **Not a Vulkan driver.** The API stays facet's, called through an LVO
  table, so the Khronos CTS is out of reach without a `libvulkan`-shaped
  shim over facet on the host. What is in reach is the CTS's shaders, as
  input to the compiler.
- **Not a replacement for the fixed forms.** They keep every pipeline that
  names one, and they are the oracles.
- **Not a compiler on the board for anything but the V3D.** The words are
  built at comptime on the PC; nothing parses GLSL anywhere near the CM5.
- **Not compute.** Compute and tessellation stay on the cores, as
  `facet-gaps.md` already records.
