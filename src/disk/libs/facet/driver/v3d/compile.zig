// SPDX-License-Identifier: MIT
//! The QPU back end: a SPIR-V fragment module turned into V3D 7.1
//! instructions.
//!
//! Three levels, so that everything checkable is checked on the host:
//!
//! 1. `Program` - what the words asked for, read through `sdk.facet.spirv`:
//!    the varyings, the one colour out, and the body as a list of steps
//!    with every id resolved to a place in that list.
//! 2. `Plan` - registers assigned and instructions chosen, nothing
//!    encoded. Every rule lives here and every test reads here.
//! 3. `qpu.zig`'s encoders, one call an instruction.
//!
//! **A wrong instruction hangs the renderer**, and a hang costs the
//! display and every other client of the V3D until the last one lets go.
//! So nothing here is invented: the only shapes emitted are the ones the
//! hand-written programs in `qpu.zig` already use on the board, and
//! anything else is refused. `qpu.last_section` and `qpu.end_of_program`
//! are spliced in as they are rather than built, because the scoreboard
//! wait is in the first of them.
//!
//! What it will not compile it refuses by name. A refusal is
//! `error_feature_not_present` at the pipeline, never a bad module: the
//! library has already turned down words that are not a module at all
//! (`CreateShaderModule`), so everything that reaches here is a module
//! this device cannot run rather than one that is wrong.
//!
//! **What is not settled, and is paid for rather than guessed.** Two
//! things the source does not state: how long an `ldunifrf` is before the
//! register it wrote may be read, and what the hardware makes of a
//! fragment program that reads fewer varyings than its record declares.
//! Neither is invented here. The first is waited out to the distance the
//! hand-written `flat_code` leaves (`uniform_latency`), padding with
//! `nop`s where the plan is tighter, because a longer wait cannot hurt;
//! the second never arises, because every varying the draw carries costs
//! its three instructions whether the body reads it or not. Both are
//! cheap, and both are the difference between a program like the ones
//! that were written by hand and a program like the ones that might be.
//!
//! **`Work` is one block, and `Code.words` points into it.** A driver
//! compiles every pipeline through the one `Work`, so the words have to
//! be copied into the block the V3D reads before anything else is
//! compiled. `Code.uniforms` is by value for that reason: a pipeline
//! keeps its floats for as long as it lives.
//!
//! **Where the splice goes.** `settle` does not lay the program out as
//! straight-line phases, although a program that does not sample reads
//! like it: the varyings, the body, the splice, the colour. A sampling
//! program interleaves, and the splice lands inside the body - the
//! coordinate writes, `wrtmuc`, the write to S that starts the lookup,
//! *then* the splice, then the two words back and the arithmetic over
//! them (`qpu.texture_color_code`). So the rule is not "between the body
//! and the colour" but **after the last varying read and the last TMU
//! write, before the first tile-buffer write**, and the straight-line
//! reading is what that rule comes to when there is no TMU write to wait
//! for. `sound` reads the distance back off every compiled program
//! rather than trusting the plan to have kept it.
//!
//! Two things follow from the splice being inside the body. Every
//! uniform a sampling program reads is loaded in front of it, because no
//! hand-written program reads the stream in the last thread section. And
//! nothing may touch the tile buffer before it, which is why a texel
//! drawn as it comes is moved out after it and not where the step sits.
//!
//! **The colour convention.** The graph's colours are 0 to 1, as Vulkan
//! has them, and the tile buffer takes half-floats of 0 to 1: a generated
//! program writes its colour out as it computed it, with no scaling. The
//! hand-written forms are the other way round - the program's vertex
//! function wrote `shader.channel`-scaled varyings for the cores, and
//! `_play.zig`'s `Carried.colors_from` divides them back out as the vertex
//! records are written. A pipeline whose fragment program is generated
//! carries its varyings `as_they_are`.
//!
//! **Mesa's back end, beside the plan.** `compileVir` reads the words as
//! `compile` does and hands the steps to `compiler/to_vir.zig`, the port
//! of Mesa's nir_to_vir.c, whose programs are given registers and
//! scheduled by Mesa's allocator and scheduler rather than by the plan.
//! V3DTest's MESA draws the five pictures GENERATED draws with what it
//! makes, and on the CM5 all five come out as the plan's do, to the
//! pixel. Since facet.library 1.137 it is what the library compiles a
//! pipeline's own fragment shader with (`compileThroughMesa`, from
//! driver.zig's `compiled`); `compile`, the plan, is what V3DTest's
//! GENERATED and the tests below still hold to the hand-written programs.

const std = @import("std");
const sdk = @import("sdk");
const spirv = sdk.facet.spirv;
const qpu = @import("qpu.zig");
const vir = @import("compiler/vir.zig");
const to_vir = @import("compiler/to_vir.zig");
const allocate = @import("compiler/allocate.zig");

/// The most ids a module may use. A back end carries its own bound
/// because its tables are one word an id and it holds them on the heap,
/// not on the stack of the call that compiles.
pub const most_ids = 256;
/// The most values a body may compute. 128 since 1.152, where a call of
/// GLSL.std.450 can lower to several.
pub const most_steps = 128;
/// The varyings the hardware carries
/// (`PhysicalDeviceLimits.max_vertex_output_components`).
pub const most_varyings = qpu.most_varyings;
/// The floats a program may read as uniforms of its own.
pub const most_uniforms = 32;
/// The constants a module may declare, read or not.
pub const most_constants = 32;
/// The members the push constants' block may have: one float each fills
/// `shader.MAX_PUSH_CONSTANTS_SIZE`.
pub const most_members = sdk.facet.shader.MAX_PUSH_CONSTANTS_SIZE / 4;
/// The combined image samplers a module may declare. One is read: the
/// TMU is written once and read once here, as in every hand-written
/// program, and a module that declares one it never samples costs
/// nothing.
pub const most_samplers = 16;
/// One for each float a step answers.
pub const most_slots = 4 * most_steps;
/// Instructions chosen, before they are words.
pub const most_acts = 160;
/// The words a program may come to.
pub const most_words = 256;

/// The instructions a program waits between an `ldunifrf` and a read of
/// the register it wrote. The source says nothing either way, and the one
/// distance a hand-written program leaves is `flat_code`'s six
/// (`qpu.zig`); a longer wait cannot hurt and a shorter one is not
/// written down, so the plan is padded out to it rather than guessed at.
pub const uniform_latency = 6;

/// The instructions a program waits between an `ldtmu` and a read of the
/// register it wrote. Every hand-written program that samples issues its
/// two `ldtmu` back to back and reads the first of them in the
/// instruction after the second, which is two; reading one in the very
/// next instruction has never been done on this board, so it is not done
/// here either.
pub const texel_latency = 2;

/// The registers a program of its own keeps values in: rf4 to rf13, since
/// rf0 to rf2 are the hardware's, rf3 is W, and rf14 and rf15 are what
/// every varying read passes through (`qpu.varying`).
pub const registers = qpu.rf_last - qpu.rf_first;

/// Why a module was not compiled. Each of these is this device's answer
/// and not the module's fault: another device may run the same words.
pub const Error = error{
    /// The module asks for something outside `profile` - an opcode, a
    /// capability, a storage class, an image, a stage.
    Refused,
    /// An optional image operand on a sample: a constant texel offset
    /// above all, which the cores apply (`ir.Op.offset`, item 28 of
    /// docs/facet-vulkan10.md) and this device cannot. The sampler's
    /// state is the TMU's whole since 1.140 (`tiling.samplerOf`), but an
    /// offset is not the sampler's: it would be a third configuration
    /// parameter no program here has ever written. A bias, a lod and a
    /// gradient on the sample come back the same way, each being a
    /// different write again. (Since 1.87.)
    Operands,
    /// Not a fragment program.
    Stage,
    /// A type other than a 32-bit float and its vectors of 2 to 4.
    Type,
    /// A variable in a storage class this back end has no answer for:
    /// a uniform, a variable of the function's own, a sampler of
    /// anything but a 2D texture. Also the plan's answer to a module that
    /// reads its push constants, which only Mesa's back end compiles.
    Storage,
    /// Input locations that are not 0 upwards without a gap, or a colour
    /// out that is not location 0.
    Location,
    /// More than one colour out (`several_outputs`), or none.
    Outputs,
    /// More varyings than the hardware carries.
    Varyings,
    /// It drops pixels (`OpKill`), which wants the flag registers.
    Discards,
    /// More than one basic block where it is not a selection Mesa would
    /// flatten: a loop, a branch of no merge, a selection nested in
    /// another, an arm that samples, stores or holds more than
    /// nir_opt_peephole_select takes (since 1.154 a selection whose arms
    /// are within its limit is read, as Mesa flattens it).
    Branches,
    /// An instruction the walk has no answer for, or one whose operands
    /// are not what this back end expects.
    Body,
    /// The body never writes the colour out.
    NoColor,
    /// More values than the tables hold.
    Steps,
    /// More floats of its own than the uniform stream holds here.
    Uniforms,
    /// More values live at once than there are registers. There is no
    /// stack on a QPU, so there is no spilling: the pipeline is refused
    /// and the cores draw it.
    Registers,
    /// More instructions than the code buffer holds.
    TooLong,
    /// More than one sample: the TMU is written once and read once here,
    /// as every hand-written program writes it once and reads it once.
    Samplers,
    /// More combined image samplers *declared* than `most_samplers`.
    /// Not a limit of the device - a module may declare many and sample
    /// one, and that one is all this device has to do - but of the table
    /// that holds where each is bound. Raising `most_samplers` raises it.
    Declared,
    /// A `Location`, `DescriptorSet` or `Binding` literal past what the
    /// tables can tell apart from "never decorated". A module's own
    /// number, so it is held against a bound before it is stored rather
    /// than landing on a sentinel and being read back as absent.
    Numbered,
    /// What Mesa's back end made of it does not pack, or breaks a rule of
    /// qpu_validate (`compileVir`): the port's fault, never the module's.
    Invalid,
};

/// The combined image sampler a module reads, by where the draw binds it.
pub const Sampler = struct {
    set: u32,
    binding: u32,
    /// Whether the program compares what it reads with a reference, an
    /// OpImageSampleDrefImplicitLod: the draw hands the TMU the bound
    /// sampler's comparison then, and refuses it otherwise (since 1.143).
    compared: bool = false,
};

/// What this back end takes. It is narrower than `spirv.facet_profile` on
/// purpose: the library must never refuse words a later device could run,
/// and this list is what *this* device can run today. It grows a family
/// at a time - discard and samplers first.
pub const profile: spirv.Profile = .{
    .capabilities = &.{.shader},
    .opcodes = &.{
        .capability,      .memory_model,       .entry_point,                    .execution_mode,
        .decorate,        .type_void,          .type_float,                     .type_vector,
        .type_pointer,    .type_function,      .constant,                       .constant_composite,
        .variable,        .function,           .label,                          .load,
        // What a real toolchain writes around the instructions: an
        // extended set imported but not used (`ext_inst` is absent, so a
        // call into one is still refused) and the names and source
        // strings glslc always emits. None of them is computation.
        .ext_inst_import, .source,             .source_extension,               .name,
        .member_name,     .store,              .composite_extract,              .composite_construct,
        .f_add,           .f_mul,              .vector_times_scalar,            .returns,
        .function_end,    .type_image,         .type_sampled_image,             .image_sample_implicit_lod,
        // A pixel dropped where a float is less or greater than another,
        // in the one shape a conditional discard has in SPIR-V: the
        // comparison, a selection whose true block is `OpKill` alone, and
        // the merge block the body goes on in (since 1.139). An `OpKill`
        // in any other place is refused by name, `Error.Discards`.
        .kill,            .type_bool,          .f_ord_less_than,                .f_ord_greater_than,
        .selection_merge, .branch_conditional,
        // The same: taken here so that a module carrying a constant texel
        // offset is refused for the operand and not for the integer type
        // the offset's constant is declared with. `profile.image_operands`
        // is empty, so `look` turns the operand away and `compile` answers
        // `Error.Operands`; this list taking `.type_int` is what lets the
        // walk get that far. Since 1.138 an integer is also what an
        // access chain into the push constants is indexed with, and that
        // is the only place one is read: a value of it anywhere else is
        // refused in the body, this back end computing with 32-bit
        // floats and their vectors alone.
        .type_int,
        // The push constants: a block of floats and vectors of them, one
        // member read at a time through an access chain whose indexes
        // are constants (since 1.138).
                              .type_struct,
        .member_decorate, .access_chain,
        // A depth compared with a reference, the TMU told it through
        // TMUDREF (v3d_tex.c:155-157; since 1.143).
              .image_sample_dref_implicit_lod,
        // The float arithmetic, a call of GLSL.std.450 among it, lowered
        // as v3dv's NIR options have Mesa lower it; and a vector's floats
        // named by a shuffle, or a varying's one float by an access chain,
        // which compute nothing (since 1.152).
        .f_sub,
        .f_negate,        .f_div,              .dot,                            .ext_inst,
        // The shuffle, then the other comparisons glslc writes and a float
        // chosen by one (since 1.153), then a selection's arms, their
        // values chosen at its merge and one float of a vector replaced
        // (since 1.154).
        .vector_shuffle,  .f_unord_not_equal,  .f_ord_less_than_equal,          .f_ord_greater_than_equal,
        .select,          .f_ord_equal,        .composite_insert,               .phi,
        .branch,
    },
    .storage_classes = &.{ .input, .output, .function, .uniform_constant, .push_constant },
    .image_dims = &.{.dim_2d},
    .stages = &.{.fragment},
    .most_ids = most_ids,
};

// --- level 1: the program ----------------------------------------------------

/// How many floats a value is.
pub const Kind = enum(u3) {
    f32x1 = 1,
    f32x2 = 2,
    f32x3 = 3,
    f32x4 = 4,

    pub fn parts(kind: Kind) u32 {
        return @intFromEnum(kind);
    }
};

/// What a step does. `component` and `construct` compute nothing: they
/// name floats a step already holds, which is why neither costs an
/// instruction. There is no register-to-register move on the add or the
/// mul side here, so naming rather than copying is not an optimisation,
/// it is the only way.
pub const Tag = enum {
    /// A varying, interpolated over the triangle.
    input,
    /// Floats the draw hands over, one uniform each.
    constant,
    /// How a float compares with another, `at` a `Comparison`: a bool,
    /// which a `discard` reads (since 1.139) and a `select` (since 1.153).
    compare,
    /// `b` where `a`, a `compare`, holds, and `from[0]` where it does not:
    /// NIR's b32csel (nir_to_vir.c:1740-1745; since 1.153). One float.
    select,
    /// 1.0 where `a` is less than `b` and 0.0 where not: NIR's slt, which
    /// GLSL.std.450's Step is made of (nir_to_vir.c:1710-1723; since
    /// 1.153). `b` may be one float, read for each of `a`'s.
    set_less,
    /// The pixel dropped where `a`, a `compare`, holds: what
    /// nir_opt_peephole_select makes of a selection whose block is a
    /// terminate alone (`discard_ok`, nir_to_vir.c:2293), terminate_if.
    discard,
    /// Floats of the push constants, one uniform each: `at` is the word
    /// the first of them is (its byte offset over four). The words are
    /// the draw's, read when the uniform stream is written (since 1.138).
    push,
    /// One float of a value.
    component,
    /// Floats of other values, gathered.
    construct,
    add,
    mul,
    /// The float arithmetic of item 59, each one VIR operation a float as
    /// ntq_emit_alu emits it (since 1.152); Mesa's back end alone compiles
    /// them. `a` less `b` (FSUB, nir_to_vir.c:1441), and the lesser and
    /// the greater of the two (FMIN, FMAX, :1449-1463). `b` may be one
    /// float, read for each of `a`'s, as a `mul`'s may.
    sub,
    min,
    max,
    /// `a` with its sign turned: the sign bit XORed, as Mesa emits a
    /// negation of 32 bits (nir_to_vir.c:1412-1419).
    negate,
    /// `a` without its sign: FMOV with the ABS unpack (:1793-1801).
    abs,
    /// `a` held to 0 to 1: FMOV with the SAT unpack 7.1 has (:1865-1882;
    /// since 1.153).
    sat,
    /// The sine and the cosine of `a`, through the SFU's SIN of a part of
    /// a period (ntq_fsincos, nir_to_vir.c:990-1003), and its sign
    /// (ntq_fsign, :1005-1016; since 1.153).
    sin,
    cos,
    sign,
    /// `a` rounded down, up, towards 0 and to the nearest even (FFLOOR,
    /// FCEIL, FTRUNC, FROUND, :1769-1779).
    floor,
    ceil,
    trunc,
    round,
    /// One over `a`, one over its square root, 2 to its power and its
    /// logarithm to 2: the SFU's (RECIP, RSQRT, EXP, LOG, :1756-1766).
    recip,
    rsqrt,
    exp2,
    log2,
    /// `a` and `b` multiplied float by float and summed: one float, NIR's
    /// fdot as nir_lower_alu_width lowers it on a device that prefers
    /// FMUL and FADD to an FMA, the last floats first (lower_fdot,
    /// nir_lower_alu_width.c:161-173, lower_reduction, :96-127).
    dot,
    /// A texel, read through the TMU. Its four floats are not four
    /// registers: the TMU hands back two words of two half-floats each,
    /// and `Work.slot_half` says which half of which word a float is.
    sample,
    /// A depth compared with `b`, the reference, at `a`: one float, what
    /// passed, the first half of the TMU's first word. Mesa's back end
    /// alone compiles it (`compileVir`; since 1.143).
    sample_compared,
};

/// What a `compare` asks, as NIR has SPIR-V's ordered comparisons and its
/// unordered not-equal (vtn_alu.c:369-381): flt, flt swapped, feq, fneu,
/// fge and fge swapped. `less` and `greater` are 0 and 1, as they were.
pub const Comparison = enum(u32) { less, greater, equal, not_equal, greater_equal, less_equal };

/// Which half of a packed pair of half-floats a float is, where it is one
/// at all. The TMU's two words are the only ones here.
pub const Half = enum { none, low, high };

pub const Step = struct {
    tag: Tag,
    kind: Kind,
    /// The steps it reads.
    a: u16 = 0,
    b: u16 = 0,
    /// `input`: which varying its first float is. `component`: which
    /// float of `a`. `constant`: where its floats start in `pool`.
    /// `push`: which word of the push constants its first float is.
    /// `sample`: which sampler it reads.
    at: u32 = 0,
    /// `construct`: the step each of its floats comes from, and which
    /// float of it.
    from: [4]u16 = @splat(0),
    part: [4]u8 = @splat(0),
};

/// A varying the module declares.
pub const Input = struct {
    location: u32,
    kind: Kind,
    /// Which varying its first float is: the floats of every lower
    /// location, summed. The vertex function writes them in that order,
    /// and `ldvary` reads them in it (`_play.zig`'s `writeRecord`).
    first: u32,
    /// The step that loaded it, or `none` where the body never reads it -
    /// its varyings are still taken, because the hardware hands them over
    /// in order and one cannot be stepped over.
    step: u16 = none,
};

pub const none: u16 = 0xFFFF;

// --- level 2: the plan -------------------------------------------------------

pub const Three = struct { to: qpu.Rf, a: qpu.Rf, b: qpu.Rf };

/// Which of the TMU's coordinate addresses a write goes to. S is the one
/// that starts the lookup, which is why every hand-written program writes
/// it last.
pub const Coordinate = enum {
    s,
    t,

    pub fn waddr(which: Coordinate) u64 {
        return switch (which) {
            .s => qpu.WADDR_TMUS,
            .t => qpu.WADDR_TMUT,
        };
    }
};

/// One instruction, or one shape of them, chosen but not encoded.
pub const Act = union(enum) {
    /// The next varying into `to`: three instructions, since its constant
    /// part reaches rf0 only by the third (`qpu.varying`). `to` is
    /// `qpu.rf_scaled` for a varying the body does not read: the hardware
    /// hands them over in order and one cannot be stepped over, so every
    /// varying the draw carries costs its three instructions, read or not.
    varying: qpu.Rf,
    /// The next uniform into `to`.
    uniform: qpu.Rf,
    fadd: Three,
    fmul: Three,
    /// Nothing, waiting out a latency. There is no scheduler here: where
    /// a value is not ready, the program waits.
    nop,
    /// The wait on the scoreboard and the switch to the last section,
    /// spliced from `qpu.last_section`. Exactly one, and nothing may
    /// touch the tile buffer before it.
    last_section,
    /// A coordinate to the TMU. The write to S is the one that starts
    /// the lookup, so it comes last (`qpu.texture_code`).
    tmu: struct { which: Coordinate, from: qpu.Rf },
    /// The next uniform to the TMU as its next configuration parameter
    /// (`wrtmuc`). Two of them, the texture's state and the sampler's.
    config,
    /// The next word the TMU has for this pixel: two half-floats, which
    /// is what the tile buffer takes and what `fmulLow`/`fmulHigh` read.
    texel: qpu.Rf,
    /// Half of a packed pair as a float, times another float
    /// (`qpu.fmulLow`, `qpu.fmulHigh`). It is the only way to read one
    /// half of a texel: a multiply by a float the program wanted anyway
    /// where there is one, and by a uniform 1 where there is not.
    half: struct { to: qpu.Rf, from: qpu.Rf, high: bool, by: qpu.Rf },
    /// Two floats to the tile buffer as two half-floats.
    color: struct { low: qpu.Rf, high: qpu.Rf },
    /// A pair of half-floats already in the form the tile buffer takes,
    /// moved out as it is: a texel drawn with no arithmetic over it
    /// (`qpu.texture_code`).
    color_packed: qpu.Rf,
    /// The thread switch that ends it and its two delay slots, spliced
    /// from `qpu.end_of_program`.
    end,

    /// How many instructions it comes to.
    pub fn words(made: Act) u32 {
        return switch (made) {
            .varying => 3,
            .uniform, .fadd, .fmul, .color, .nop => 1,
            .tmu, .config, .texel, .half, .color_packed => 1,
            .last_section => qpu.last_section.len,
            .end => qpu.end_of_program.len,
        };
    }
};

/// What a compiled program needs of a draw.
pub const Code = struct {
    /// The instructions, **in `Work.code`**: the next `compile` through
    /// the same `Work` writes over them, so a caller copies them into the
    /// block it gives the V3D before it compiles anything else.
    words: []const u64,
    /// The varyings it reads, which is every varying the draw carries:
    /// what the vertex record holds and what the shader record says. The
    /// program issues exactly this many `ldvary`, as the hand-written
    /// programs do.
    varyings: u32,
    /// The uniform stream, in the order the program reads it. By value,
    /// not a slice: a pipeline keeps it for as long as it lives, and
    /// `Work` is one block a driver compiles everything through.
    uniforms: [most_uniforms]Word,
    uniform_count: u32,
    /// The combined image sampler the program reads, where it reads one.
    /// The draw looks it up in its descriptor sets and writes the two
    /// `.texture` and `.sampler` words of the stream from what it finds.
    sampler: ?Sampler,
    /// The registers it keeps values in, for a test to read.
    registers: u32,
    /// What the shader record says of the program, which Mesa's back end
    /// decides (`compileVir`) and the plan keeps as the hand-written
    /// programs have it: the threads it runs as, whether it reads W for
    /// something besides a centroid varying, and whether the scoreboard is
    /// locked at its first thread switch rather than its last.
    threads: u8 = 4,
    center_w: bool = false,
    lock_scoreboard_on_first_thrsw: bool = false,
    /// Whether the program writes the depth itself, and whether early Z
    /// is to be off for it: both for a program that drops pixels, which
    /// writes the depth the rasterizer made (emit_frag_end,
    /// nir_to_vir.c:2083-2136) and is not tested early, as v3dv packs
    /// them (v3dvx_pipeline.c:454-459). Since 1.139.
    writes_z: bool = false,
    disable_ez: bool = false,

    /// The uniform stream, in the order the program reads it.
    pub fn stream(code: *const Code) []const Word {
        return code.uniforms[0..code.uniform_count];
    }
};

/// One word of the uniform stream. A program of its own reads floats it
/// holds; one that samples also reads the TMU's two configuration
/// parameters, which only a draw can fill in - the texture bound to it
/// and the sampler beside it are not known until then.
pub const Word = union(enum) {
    float: f32,
    /// The texture's state, as the first `wrtmuc` takes it.
    texture,
    /// The sampler's state, as the second takes it.
    sampler,
    /// A word of the push constants, by its place among them (the byte
    /// offset over four): what Mesa's QUNIFORM_UNIFORM is in v3dv, filled
    /// from the command buffer's push constants as the stream is written
    /// (v3dv_uniforms.c:513, v3dv_write_uniforms).
    push: u32,
};

// --- the work ----------------------------------------------------------------

/// Everything the compiler needs while it works. It is some kilobytes, so
/// it is a block the driver holds and not a call's stack; nothing here
/// allocates, and a module is read without being trusted.
pub const Work = struct {
    // The module's ids.
    thing: [most_ids]Thing = @splat(.none),
    /// `float`: 32. `vector`: how many floats. `constant`: how many
    /// floats. `variable`: how many floats.
    wide: [most_ids]u8 = @splat(0),
    /// `pointer`: what it points at. `constant`: where its floats start
    /// in `pool`. `variable`: which input or output it is.
    points: [most_ids]u16 = @splat(0),
    /// `pointer` and `variable`: the storage class.
    class: [most_ids]u8 = @splat(0),
    /// From OpDecorate Location, or `none`.
    location: [most_ids]u16 = @splat(none),
    /// From OpDecorate DescriptorSet and Binding, or `none`.
    set: [most_ids]u16 = @splat(none),
    binding: [most_ids]u16 = @splat(none),
    /// Which sampler an id names: the variable, and the value an OpLoad
    /// of it answers. A sampler is not a value a step can hold, so it is
    /// carried beside the steps rather than among them.
    sampler_of: [most_ids]u16 = @splat(none),
    /// Which step a value id answers.
    step_of: [most_ids]u16 = @splat(none),
    /// `member_pointer`: which float of the member it names, or `whole`
    /// where it names all of them.
    chain_part: [most_ids]u8 = @splat(whole),

    /// The push constants' block: the struct type decorated `Block`, the
    /// struct its members' offsets were given for, and the one variable
    /// of it. Each member is a float or a vector of them, with its type
    /// and its byte offset, from OpMemberDecorate Offset.
    block: u16 = none,
    offsets_of: u16 = none,
    /// The id GLSL.std.450 is imported as, where it is: the one extended
    /// set whose calls the walk lowers (since 1.152).
    glsl: u16 = none,
    push_variable: u16 = none,
    member_type: [most_members]u16 = @splat(none),
    member_offset: [most_members]u16 = @splat(none),
    member_count: u32 = 0,

    /// Every constant the module declares, read or not. A float of a
    /// vector's is declared on its own as well, and most of those are
    /// never read: only what the body asks for costs a uniform.
    pool: [4 * most_constants]f32 = @splat(0),
    pool_count: u32 = 0,
    /// The uniform stream, in the order the program reads it: filled as
    /// the plan is laid out, not as the words are read, because where a
    /// sampler's two configuration words sit among the floats is the
    /// order the instructions ask for them.
    stream: [most_uniforms]Word = @splat(.{ .float = 0 }),
    stream_count: u32 = 0,

    /// The combined image samplers the module declares.
    samplers: [most_samplers]Sampler = undefined,
    sampler_count: u32 = 0,
    /// How many times the body samples. One, where it samples at all.
    sample_count: u32 = 0,

    inputs: [most_varyings]Input = undefined,
    input_count: u32 = 0,
    /// The one colour out.
    output: u16 = none,
    output_count: u32 = 0,

    steps: [most_steps]Step = undefined,
    step_count: u32 = 0,
    /// The step the body stored into the colour out.
    stored: u16 = none,
    /// The one step that samples, where there is one.
    sampled: u16 = none,
    varyings: u32 = 0,

    // The plan.
    /// Which float of which step each slot is, and what reads it last.
    slot_of: [most_steps][4]u16 = undefined,
    slot_last: [most_slots]u32 = @splat(0),
    slot_reg: [most_slots]qpu.Rf = @splat(0),
    /// Which half of a packed pair the float is, for the two words the
    /// TMU hands back. Everything else is a register of its own. It is
    /// cleared where the float has been read out into one of its own.
    slot_half: [most_slots]Half = @splat(.none),
    /// Whether the float is a texel's at all, which `slot_half` stops
    /// saying once it has been read out. Settled before anything is
    /// emitted, so that what the program will want can be worked out
    /// ahead of emitting it.
    slot_texel: [most_slots]bool = @splat(false),
    /// The other float of the pair, for one that is packed: the two
    /// share a register, so neither may give it back while the other
    /// still wants it.
    slot_pair: [most_slots]u16 = @splat(none),
    /// Its register is back in the pool: it is given back once, however
    /// many steps come after the one that read it last.
    slot_back: [most_slots]bool = @splat(false),
    slot_count: u32 = 0,
    taken: [registers]bool = @splat(false),
    high_water: u32 = 0,
    /// The register holding the 1 that a packed float is multiplied by to
    /// be read as a float of its own, where one was wanted. It is taken
    /// once and never given back: a program that unpacks a texel once
    /// usually unpacks the rest of it too.
    one: ?qpu.Rf = null,

    acts: [most_acts]Act = undefined,
    act_count: u32 = 0,
    /// The instructions the plan comes to so far, and the first word at
    /// which each register may be read: what `wait` is measured against.
    /// A register an instruction computed may be read by the next one,
    /// so its word is 0; one a signal fills has to be waited out.
    at_word: u32 = 0,
    ready: [registers]u32 = @splat(0),
    /// Whether the splice is behind us. A uniform has never been read
    /// past it on this board.
    spliced: bool = false,

    code: [most_words]u64 = undefined,
    word_count: u32 = 0,

    pub const Thing = enum(u8) { none, other, float, vector, image, sampled_image, pointer, constant, variable, function, value, int, int_constant, structure, member_pointer, boolean, input_part };

    /// `chain_part` of a pointer to a whole member.
    pub const whole: u8 = 0xFF;

    /// The steps the body came to, for a test to read.
    pub fn program(work: *const Work) []const Step {
        return work.steps[0..work.step_count];
    }

    /// The instructions chosen, for a test to read.
    pub fn plan(work: *const Work) []const Act {
        return work.acts[0..work.act_count];
    }
};

/// `words` compiled, or why not. The words are a program's: nothing here
/// follows a pointer out of them, and a module that is not one has
/// already been turned down by `CreateShaderModule`.
pub fn compile(work: *Work, words: []const u32) Error!Code {
    try readModule(work, words);
    // No hand-written program reads a push constant, drops a pixel or
    // compares, so the plan has nothing to hold any of them to: only
    // Mesa's back end compiles them.
    for (work.program()) |each| switch (each.tag) {
        .push => return Error.Storage,
        .discard => return Error.Discards,
        .sample_compared => return Error.Samplers,
        // Nor does any compute beyond a sum and a product.
        .sub, .min, .max, .negate, .abs, .floor, .ceil, .trunc, .round, .recip, .rsqrt, .exp2, .log2, .dot => return Error.Body,
        .select, .set_less, .sat, .sin, .cos, .sign => return Error.Body,
        else => {},
    };
    try settle(work);
    try encode(work);
    return .{
        .words = work.code[0..work.word_count],
        .varyings = work.varyings,
        .uniforms = work.stream,
        .uniform_count = work.stream_count,
        .sampler = if (work.sample_count == 0) null else work.samplers[work.steps[work.sampled].at],
        .registers = work.high_water,
    };
}

/// `words` compiled through Mesa's back end rather than the plan: read as
/// `compileVir` with its working memory taken from `child` for the one
/// compile and given back at its end, all of it in an arena: the register
/// sets as well, which Mesa makes once for the device (v3d_compiler_init,
/// vir.c:535) and which are four classes of 64 registers or fewer here.
/// What it answers is in `work`, as `compile`'s is.
pub fn compileThroughMesa(work: *Work, words: []const u32, child: std.mem.Allocator, key: Key) (Error || std.mem.Allocator.Error)!Code {
    var arena = std.heap.ArenaAllocator.init(child);
    defer arena.deinit();
    const allocator = arena.allocator();
    const compiler = allocate.initRegSets(allocator) catch return error.OutOfMemory;
    return compileVir(work, words, allocator, &compiler, key);
}

/// What the pipeline says beside the words (`to_vir.Key`, since 1.149).
pub const Key = to_vir.Key;

/// `compile` reads them, then made VIR, given registers, scheduled and
/// packed as Mesa's v3d_compile does (compiler/to_vir.zig). V3DTest's
/// MESA draws with what it makes, and the library compiles with it
/// through `compileThroughMesa` (since 1.137).
/// `compiler` is the register sets (`allocate.initRegSets`), made once
/// for every compile.
pub fn compileVir(work: *Work, words: []const u32, allocator: std.mem.Allocator, compiler: *const vir.Compiler, key: Key) (Error || std.mem.Allocator.Error)!Code {
    try readModule(work, words);
    return compileRead(work, allocator, compiler, key);
}

/// The program a subpass of no colour draws with where the pipeline
/// brings no fragment shader of its own, or for a clear: v3dv's noop
/// fragment shader (v3dv_pipeline.c:2616-2645), a body of nothing that
/// Mesa's back end compiles with no render target in the key. Its one TLB
/// write is the depth the rasterizer made, written through (emit_frag_end,
/// nir_to_vir.c:2098-2126), so it writes Z and early Z is off for it. It
/// reads no varying and one uniform, that write's specifier. Since 1.150.
pub fn compileNoColor(work: *Work, allocator: std.mem.Allocator, compiler: *const vir.Compiler) (Error || std.mem.Allocator.Error)!Code {
    work.* = .{};
    return compileRead(work, allocator, compiler, .{ .cbufs = 0 });
}

/// `compileNoColor` with working memory of its own, as
/// `compileThroughMesa`'s.
pub fn compileNoColorThroughMesa(work: *Work, child: std.mem.Allocator) (Error || std.mem.Allocator.Error)!Code {
    var arena = std.heap.ArenaAllocator.init(child);
    defer arena.deinit();
    const allocator = arena.allocator();
    const compiler = allocate.initRegSets(allocator) catch return error.OutOfMemory;
    return compileNoColor(work, allocator, &compiler);
}

/// What `work` holds, read from a module or left empty, made VIR, given
/// registers, scheduled and packed.
fn compileRead(work: *Work, allocator: std.mem.Allocator, compiler: *const vir.Compiler, key: Key) (Error || std.mem.Allocator.Error)!Code {
    const program = to_vir.compileSteps(allocator, compiler, work, key) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Registers => Error.Registers,
        error.Invalid => Error.Invalid,
    };
    defer program.destroy();
    const c = program.c;
    std.debug.assert(c.num_inputs == work.varyings);

    if (c.qpu_insts.len > most_words) return Error.TooLong;
    @memcpy(work.code[0..c.qpu_insts.len], c.qpu_insts);
    work.word_count = @intCast(c.qpu_insts.len);

    // The stream in the order the program reads it, which is the order
    // the scheduler left the uniforms in.
    if (c.num_uniforms > most_uniforms) return Error.Uniforms;
    for (c.uniform_contents[0..c.num_uniforms], c.uniform_data[0..c.num_uniforms], 0..) |contents, data, at| {
        work.stream[at] = switch (contents) {
            .constant => .{ .float = @bitCast(data) },
            // The draw's own words, which `tiling.parameter0` and
            // `parameter1` write as these are: both words of the one
            // texture, and its sampler.
            .tmu_config_p0 => if (data == to_vir.texel_words) .texture else return Error.Invalid,
            .tmu_config_p1 => if (data == 0) .sampler else return Error.Invalid,
            // A word of the push constants: `Step.at` of a `.push`.
            .uniform => .{ .push = data },
            // A spill's offset or size: a draw has no memory to spill to.
            else => return Error.Registers,
        };
    }
    work.stream_count = c.num_uniforms;

    return .{
        .words = work.code[0..work.word_count],
        .varyings = work.varyings,
        .uniforms = work.stream,
        .uniform_count = work.stream_count,
        .sampler = if (work.sample_count == 0) null else samplerRead(work),
        .registers = program.registers,
        .threads = c.threads,
        .center_w = program.uses_center_w,
        .lock_scoreboard_on_first_thrsw = c.lock_scoreboard_on_first_thrsw,
        .writes_z = program.writes_z,
        .disable_ez = program.disable_ez,
    };
}

/// The combined image sampler the program's one sample reads, and whether
/// it compares.
fn samplerRead(work: *const Work) Sampler {
    const taken = work.steps[work.sampled];
    var made = work.samplers[taken.at];
    made.compared = taken.tag == .sample_compared;
    return made;
}

/// The words looked at against the profile and read into `work`: what
/// `compile` and `compileVir` share.
fn readModule(work: *Work, words: []const u32) Error!void {
    work.* = .{};
    const seen = switch (spirv.look(words, profile)) {
        .seen => |each| each,
        .fault => |fault| return switch (fault) {
            .stage_refused => Error.Stage,
            // An image operand, which this device's profile takes none of:
            // said by name so that it can be told from a word the walk
            // simply did not know (since 1.87).
            .image_operand_refused => Error.Operands,
            else => Error.Refused,
        },
    };
    if (seen.stage != .fragment) return Error.Stage;
    // A discard is read in the body: where it is the one shape taken, it
    // is a step, and anywhere else `read` answers `Error.Discards`.
    try read(work, words, seen);
}

// --- reading the words -------------------------------------------------------

/// A module's declarations and then its one block, in the one pass SPIR-V's
/// logical layout allows: the annotations come before the variables they
/// decorate, and every type, constant and variable an instruction names is
/// declared before it.
fn read(work: *Work, words: []const u32, seen: spirv.Seen) Error!void {
    var reader = spirv.Reader.of(words);
    var in_body = false;
    var blocks: u32 = 0;
    var returned = false;
    // Where a selection is in its shape: OpSelectionMerge, then
    // OpBranchConditional to its arms, each a block that ends in an
    // OpBranch to the merge block, or one of them the merge block itself;
    // then the merge block, its OpPhis first. A conditional discard is
    // the same with a true arm of `OpKill` alone and no other (since
    // 1.139). Mesa's nir_opt_peephole_select flattens such a selection
    // into its arms' instructions, both, and a bcsel for each phi
    // (nir_opt_peephole_select.c:508-605), which is what is read here: the
    // arms' steps one after the other, and a `select` of each float a
    // phi chooses (since 1.154).
    var flow: enum { body, branch, arms, arm, killed, merging } = .body;
    var selection: Selection = .{};
    while (reader.next() catch return Error.Refused) |instruction| {
        const operands = instruction.operands();
        if (returned) {
            // Past OpReturn only the function's end may follow.
            if (instruction.op != .function_end) return Error.Body;
            continue;
        }
        // The merge block's phis are over at its first other instruction:
        // the arms are then what nir_opt_peephole_select counts.
        if (flow == .merging and instruction.op != .phi) {
            if (armCost(work, selection.arms_from, selection.arms_to) > peephole_limit) return Error.Branches;
            flow = .body;
        }
        switch (instruction.op) {
            // Nothing to plan for: the module's own declarations, and the
            // annotations a toolchain puts in front of them. They arrive
            // before any function, so they must be named here rather than
            // fall to the body arm below, which would answer Error.Body.
            .capability, .memory_model, .entry_point, .type_void, .type_function => {},
            .source, .source_extension, .name, .member_name => {},
            .ext_inst_import => {
                // Result, Name. GLSL.std.450 is the set whose calls the
                // walk lowers; any other is imported for nothing, and a
                // call into it is refused (since 1.152).
                if (operands.len < 2) return Error.Body;
                const id = try idOf(operands[0]);
                if (literalIs(operands[1..], "GLSL.std.450")) work.glsl = id;
            },
            .execution_mode => {
                // Which mode it is matters: a program compiled as if its
                // origin were the top left and run with it at the bottom
                // left renders upside down, and nothing says so. Only the
                // one facet emits is taken.
                if (operands.len < 2) return Error.Body;
                const mode = std.enums.fromInt(spirv.ExecutionMode, operands[1]) orelse return Error.Refused;
                if (mode != .origin_upper_left) return Error.Refused;
            },
            .decorate => {
                if (operands.len < 2) return Error.Body;
                const id = try idOf(operands[0]);
                const what = std.enums.fromInt(spirv.Decoration, operands[1]) orelse return Error.Refused;
                // A Location, a DescriptorSet and a Binding are read;
                // every other decoration is refused rather than ignored.
                // `Flat` and `NoPerspective` are the reason: a varying
                // decorated either way is not the perspective-correct one
                // `qpu.varying` interpolates, and taking the decoration
                // and dropping it would draw the wrong pixels and say
                // nothing.
                //
                // Which decoration it is is read before how many
                // operands it has, because the three that are taken
                // carry a literal and the ones that are refused do not:
                // a real `OpDecorate %x Flat` is two words of operands,
                // so demanding three would answer `Body` for the one
                // decoration this is here to turn down by name.
                switch (what) {
                    .location, .descriptor_set, .binding => {},
                    // The push constants' block, which carries no
                    // literal. There is one: a uniform buffer would be
                    // the other kind of block, and its storage class is
                    // not in the profile.
                    .block => {
                        if (work.block != none) return Error.Refused;
                        work.block = id;
                        continue;
                    },
                    else => return Error.Refused,
                }
                if (operands.len < 3) return Error.Body;
                // The literal is the module's own number, so it is held
                // against the table before it is stored: `none` is
                // 0xFFFF, and a literal of exactly 65535 would otherwise
                // land on it and be read back as "never decorated".
                if (operands[2] >= @as(u32, none)) return Error.Numbered;
                const value: u16 = @intCast(operands[2]);
                switch (what) {
                    .location => work.location[id] = value,
                    .descriptor_set => work.set[id] = value,
                    .binding => work.binding[id] = value,
                    else => unreachable,
                }
            },
            .member_decorate => {
                // StructureType, Member, Decoration, its literal. The one
                // decoration taken is the member's byte offset, which is
                // where its floats are among the push constants: a word
                // of them each, so it is a multiple of four. A block's
                // other member decorations are for matrices and the
                // vertex stage's built-ins, neither of which is here.
                if (operands.len < 3) return Error.Body;
                const id = try idOf(operands[0]);
                const what = std.enums.fromInt(spirv.Decoration, operands[2]) orelse return Error.Refused;
                if (what != .offset) return Error.Refused;
                if (operands.len < 4) return Error.Body;
                if (work.offsets_of != none and work.offsets_of != id) return Error.Refused;
                work.offsets_of = id;
                const member = operands[1];
                if (member >= most_members) return Error.Storage;
                const offset = operands[3];
                if (offset % 4 != 0 or offset >= sdk.facet.shader.MAX_PUSH_CONSTANTS_SIZE) return Error.Storage;
                work.member_offset[member] = @intCast(offset);
            },
            .type_float => {
                if (operands.len < 2) return Error.Body;
                const id = try idOf(operands[0]);
                if (operands[1] != 32) return Error.Type;
                work.thing[id] = .float;
                work.wide[id] = 1;
            },
            .type_bool => {
                if (operands.len < 1) return Error.Body;
                work.thing[try idOf(operands[0])] = .boolean;
            },
            .type_int => {
                // 32 bits, signed or not: `look` has held the width. It
                // is read as an access chain's index and nowhere else.
                if (operands.len < 3) return Error.Body;
                const id = try idOf(operands[0]);
                if (operands[1] != 32) return Error.Type;
                work.thing[id] = .int;
            },
            .type_struct => {
                // The push constants' block and no other struct: a value
                // of one would be a step of many kinds, and none is. Each
                // member is a float or a vector of them, with an offset
                // that keeps all of its floats inside the push constants.
                if (operands.len < 1) return Error.Body;
                const id = try idOf(operands[0]);
                if (id != work.block or id != work.offsets_of) return Error.Type;
                const members = operands[1..];
                if (members.len == 0 or members.len > most_members) return Error.Storage;
                for (members, 0..) |each, k| {
                    const member = try idOf(each);
                    const kind = try kindOf(work, member);
                    const offset = work.member_offset[k];
                    if (offset == none) return Error.Storage;
                    if (offset + 4 * kind.parts() > sdk.facet.shader.MAX_PUSH_CONSTANTS_SIZE) return Error.Storage;
                    work.member_type[k] = member;
                }
                // An offset given for a member the struct does not have.
                for (work.member_offset[members.len..]) |offset| if (offset != none) return Error.Storage;
                work.member_count = @intCast(members.len);
                work.thing[id] = .structure;
            },
            .type_vector => {
                if (operands.len < 3) return Error.Body;
                const id = try idOf(operands[0]);
                const component = try idOf(operands[1]);
                if (work.thing[component] != .float) return Error.Type;
                if (operands[2] < 2 or operands[2] > 4) return Error.Type;
                work.thing[id] = .vector;
                work.wide[id] = @intCast(operands[2]);
            },
            .type_image => {
                // Result, SampledType, Dim, Depth, Arrayed, MS, Sampled,
                // ImageFormat. `look` has held the dimensionality to the
                // profile's and Sampled to 1 already; what is left is the
                // three that say this is the plain 2D texture the TMU is
                // written for here. An arrayed one wants a layer in TMUI
                // and a multisampled one is not a texture at all - each is
                // its own family, and neither is this one. Depth is
                // taken whatever it says since 1.143: whether a sample
                // compares is its opcode's, not the type's, as SPIR-V has
                // it, and a depth image is read as any texture is.
                if (operands.len < 8) return Error.Body;
                const id = try idOf(operands[0]);
                if (work.thing[try idOf(operands[1])] != .float) return Error.Type;
                if (operands[3] > 2 or operands[4] != 0 or operands[5] != 0) return Error.Refused;
                work.thing[id] = .image;
            },
            .type_sampled_image => {
                if (operands.len < 2) return Error.Body;
                const id = try idOf(operands[0]);
                const image = try idOf(operands[1]);
                if (work.thing[image] != .image) return Error.Type;
                work.thing[id] = .sampled_image;
                work.points[id] = image;
            },
            .type_pointer => {
                if (operands.len < 3) return Error.Body;
                const id = try idOf(operands[0]);
                const class = std.enums.fromInt(spirv.StorageClass, operands[1]) orelse return Error.Refused;
                work.thing[id] = .pointer;
                work.class[id] = @intCast(@intFromEnum(class));
                work.points[id] = try idOf(operands[2]);
            },
            .constant => {
                // ResultType first, then Result: the emitter had this the
                // other way round once, and the oracle caught it.
                if (operands.len < 3) return Error.Body;
                const type_id = try idOf(operands[0]);
                const id = try idOf(operands[1]);
                if (work.thing[type_id] == .int) {
                    // An index into the push constants, read as one by an
                    // access chain. A value past the table's is `none`,
                    // which no member is.
                    work.thing[id] = .int_constant;
                    work.points[id] = if (operands[2] < none) @intCast(operands[2]) else none;
                    continue;
                }
                if (work.thing[type_id] != .float) return Error.Type;
                if (work.pool_count == work.pool.len) return Error.Uniforms;
                work.thing[id] = .constant;
                work.points[id] = @intCast(work.pool_count);
                work.wide[id] = 1;
                work.pool[work.pool_count] = @bitCast(operands[2]);
                work.pool_count += 1;
            },
            .constant_composite => {
                if (operands.len < 2) return Error.Body;
                const type_id = try idOf(operands[0]);
                const id = try idOf(operands[1]);
                if (work.thing[type_id] != .vector) return Error.Type;
                const parts = operands[2..];
                if (parts.len != work.wide[type_id]) return Error.Body;
                if (work.pool_count + parts.len > work.pool.len) return Error.Uniforms;
                work.thing[id] = .constant;
                work.points[id] = @intCast(work.pool_count);
                work.wide[id] = @intCast(parts.len);
                for (parts) |part| {
                    const member = try idOf(part);
                    if (work.thing[member] != .constant or work.wide[member] != 1) return Error.Type;
                    work.pool[work.pool_count] = work.pool[work.points[member]];
                    work.pool_count += 1;
                }
            },
            .variable => {
                if (operands.len < 3) return Error.Body;
                const type_id = try idOf(operands[0]);
                const id = try idOf(operands[1]);
                if (work.thing[type_id] != .pointer) return Error.Type;
                const class = std.enums.fromInt(spirv.StorageClass, operands[2]) orelse return Error.Refused;
                if (@as(u8, @intCast(@intFromEnum(class))) != work.class[type_id]) return Error.Body;
                const pointee = work.points[type_id];
                if (class == .push_constant) {
                    // The block, and once: Vulkan has an entry point use
                    // one push constant variable at most, and a member is
                    // found by its offset, which two blocks would share.
                    if (work.thing[pointee] != .structure) return Error.Storage;
                    if (work.push_variable != none) return Error.Storage;
                    work.thing[id] = .variable;
                    work.class[id] = @intCast(@intFromEnum(class));
                    work.push_variable = id;
                    continue;
                }
                if (class == .uniform_constant) {
                    // A combined image sampler and nothing else. There is
                    // one TMU, it is configured from two words of the
                    // uniform stream, and where those words come from is
                    // the set and the binding the draw looks up.
                    if (work.thing[pointee] != .sampled_image) return Error.Storage;
                    // This is the table's bound, not the device's: what
                    // the device can run is one *sample*, and a module
                    // may declare many samplers and sample one of them.
                    // So it has an error of its own, and a log line can
                    // tell a bound another build could raise from a
                    // limit no build can.
                    if (work.sampler_count == most_samplers) return Error.Declared;
                    if (work.set[id] == none or work.binding[id] == none) return Error.Location;
                    work.thing[id] = .variable;
                    work.class[id] = @intCast(@intFromEnum(class));
                    work.sampler_of[id] = @intCast(work.sampler_count);
                    work.samplers[work.sampler_count] = .{ .set = work.set[id], .binding = work.binding[id] };
                    work.sampler_count += 1;
                    continue;
                }
                const floats = try kindOf(work, pointee);
                work.thing[id] = .variable;
                work.class[id] = @intCast(@intFromEnum(class));
                work.wide[id] = @intCast(floats.parts());
                switch (class) {
                    .input => {
                        if (work.input_count == most_varyings) return Error.Varyings;
                        const at = work.location[id];
                        if (at == none) return Error.Location;
                        work.points[id] = @intCast(work.input_count);
                        work.inputs[work.input_count] = .{ .location = at, .kind = floats, .first = 0 };
                        work.input_count += 1;
                    },
                    .output => {
                        // One colour out, at location 0, of four floats:
                        // what the tile buffer takes without a
                        // configuration of its own (`qpu.zig`).
                        if (work.output_count != 0) return Error.Outputs;
                        if (work.location[id] != 0) return Error.Location;
                        if (floats != .f32x4) return Error.Type;
                        work.output = id;
                        work.output_count = 1;
                    },
                    // A variable of the function's own would want a place
                    // to live, and there is no stack on a QPU.
                    else => return Error.Storage,
                }
            },
            .function => {
                // The one function, and the entry point's: `look`
                // counts the functions but does not say the one it saw
                // is the one the entry point names, and a module may
                // declare a helper that is never called.
                if (operands.len < 2) return Error.Body;
                if (in_body) return Error.Body;
                if (try idOf(operands[1]) != seen.entry) return Error.Body;
                in_body = true;
            },
            .label => {
                if (!in_body or operands.len < 1) return Error.Body;
                const id = operands[0];
                switch (flow) {
                    .body => {
                        // The function's first block: any other is a
                        // selection's.
                        blocks += 1;
                        if (blocks > 1) return Error.Branches;
                        selection.label = id;
                    },
                    .arms => if (id == selection.merge) {
                        if (selection.yes != selection.merge and !selection.seen_yes) return Error.Branches;
                        if (selection.no != selection.merge and !selection.seen_no) return Error.Branches;
                        selection.arms_to = @intCast(work.step_count);
                        selection.label = id;
                        flow = .merging;
                    } else if (id == selection.yes and !selection.seen_yes) {
                        selection.seen_yes = true;
                        selection.arm = id;
                        selection.empty = true;
                        flow = .arm;
                    } else if (id == selection.no and !selection.seen_no) {
                        selection.seen_no = true;
                        selection.arm = id;
                        selection.empty = true;
                        flow = .arm;
                    } else return Error.Branches,
                    // After the block that drops the pixel, the merge
                    // block, where nothing is chosen.
                    .killed => {
                        if (id != selection.merge) return Error.Branches;
                        selection.arms_to = @intCast(work.step_count);
                        selection.label = id;
                        flow = .merging;
                    },
                    .branch, .arm, .merging => return Error.Branches,
                }
            },
            .selection_merge => {
                // MergeBlock, SelectionControl. Whether it asks for the
                // branch flattened or kept is a hint, which Mesa reads
                // only where it cannot flatten; here a selection is
                // flattened or refused. One in an arm is a selection
                // nested in another, which nir_opt_peephole_select takes
                // from the inside out, and is not here.
                if (!in_body or blocks == 0 or flow != .body) return Error.Branches;
                if (operands.len < 2) return Error.Body;
                selection = .{ .merge = operands[0], .header = selection.label, .label = selection.label };
                flow = .branch;
            },
            .branch_conditional => {
                // Condition, True Label, False Label, and maybe weights.
                // One of the two may be the merge block itself: an `if`
                // with no `else`, or the other way about.
                if (flow != .branch) return Error.Branches;
                if (operands.len < 3) return Error.Body;
                const condition = work.step_of[try idOf(operands[0])];
                if (condition == none or work.steps[condition].tag != .compare) return Error.Body;
                selection.condition = condition;
                selection.yes = operands[1];
                selection.no = operands[2];
                if (selection.yes == selection.no) return Error.Branches;
                selection.arms_from = @intCast(work.step_count);
                flow = .arms;
            },
            .branch => {
                // An arm's end, to the merge block. Any other OpBranch is
                // a jump to a block no selection names: a loop's, or one
                // of no structure.
                if (flow != .arm or operands.len < 1 or operands[0] != selection.merge) return Error.Branches;
                flow = .arms;
            },
            .kill => {
                // Only as the true arm of a selection with no other, and
                // alone in it: the conditional discard, which Mesa makes
                // a terminate_if (nir_opt_peephole_select's `discard_ok`).
                // A pixel dropped always, or after other work in its arm,
                // is the family's and refused by its name; one beside an
                // else arm leaves the body going on in two places.
                if (flow != .arm or !selection.empty) return Error.Discards;
                if (selection.arm != selection.yes or selection.no != selection.merge) return Error.Branches;
                _ = try put(work, .{ .tag = .discard, .kind = .f32x1, .a = selection.condition });
                flow = .killed;
            },
            .phi => {
                if (flow != .merging) return Error.Branches;
                try phiOf(work, &selection, operands);
            },
            .returns => {
                if (flow != .body) return Error.Branches;
                returned = true;
            },
            .function_end => {},
            else => {
                if (!in_body or blocks == 0) return Error.Body;
                switch (flow) {
                    .body => {},
                    // An arm Mesa flattens holds ALU work and loads it may
                    // run where the arm is not taken
                    // (block_check_for_allowed_instrs,
                    // nir_opt_peephole_select.c:59-326): a sample, which
                    // is a texture instruction, or the colour stored, is
                    // neither, and the selection stays a branch.
                    .arm => switch (instruction.op) {
                        .store, .image_sample_implicit_lod, .image_sample_dref_implicit_lod => return Error.Branches,
                        else => selection.empty = false,
                    },
                    else => return Error.Branches,
                }
                try step(work, instruction);
            },
        }
    }
    if (work.output_count == 0) return Error.Outputs;
    if (work.stored == none) return Error.NoColor;
    try order(work);
}

fn idOf(word: u32) Error!u16 {
    if (word == 0 or word >= most_ids) return Error.Refused;
    return @intCast(word);
}

/// A selection as `read` goes through it.
const Selection = struct {
    /// The merge block, and the block the selection is in.
    merge: u32 = 0,
    header: u32 = 0,
    /// The block the body is in.
    label: u32 = 0,
    /// The true and false labels, either of which may be the merge block,
    /// and whether each arm has been read.
    yes: u32 = 0,
    no: u32 = 0,
    seen_yes: bool = false,
    seen_no: bool = false,
    /// The arm being read, and whether it is still empty.
    arm: u32 = 0,
    empty: bool = true,
    /// The comparison it branches on.
    condition: u16 = none,
    /// The arms' steps: from the first after the branch to the first in
    /// the merge block.
    arms_from: u16 = 0,
    arms_to: u16 = 0,
};

/// The limit v3d's optimization loop gives nir_opt_peephole_select
/// (nir_to_vir.c:2274-2279), `expensive_alu_ok` with it: a selection
/// whose arms are more than this many ALU operations stays a branch.
const peephole_limit = 24;

/// An OpPhi at a flattened selection's merge: ResultType, Result, and a
/// value and its parent block for each way in. Each float is a `select`
/// on the selection's comparison, as nir_lower_phis_to_scalar and then
/// nir_opt_peephole_select make it, a bcsel for each float in order
/// (nir_to_vir.c:2264-2279); where the two ways bring the same float,
/// that float, as nir_opt_remove_phis leaves it (since 1.154).
fn phiOf(work: *Work, selection: *const Selection, operands: []const u32) Error!void {
    if (operands.len != 6) return Error.Branches;
    const kind = try kindOf(work, try idOf(operands[0]));
    const id = try idOf(operands[1]);
    // Which way each value came: an arm's block, or the selection's own
    // where the other label is the merge block.
    var by: [2]u16 = .{ none, none };
    for ([2]usize{ 2, 4 }) |at| {
        const parent = operands[at + 1];
        const side: usize = if (parent == selection.yes and selection.yes != selection.merge)
            0
        else if (parent == selection.no and selection.no != selection.merge)
            1
        else if (parent == selection.header and selection.yes == selection.merge)
            0
        else if (parent == selection.header and selection.no == selection.merge)
            1
        else
            return Error.Branches;
        if (by[side] != none) return Error.Branches;
        by[side] = try operand(work, operands[at], kind);
    }
    var made = Step{ .tag = .construct, .kind = kind };
    for (0..kind.parts()) |k| {
        const yes = partOf(work, by[0], @intCast(k));
        const no = partOf(work, by[1], @intCast(k));
        if (yes.step == no.step and yes.part == no.part) {
            made.from[k] = yes.step;
            made.part[k] = yes.part;
            continue;
        }
        var chosen = Step{ .tag = .select, .kind = .f32x1, .a = selection.condition, .b = try floatOf(work, yes) };
        chosen.from[0] = try floatOf(work, no);
        made.from[k] = try put(work, chosen);
        made.part[k] = 0;
    }
    work.step_of[id] = if (kind == .f32x1)
        (if (work.steps[made.from[0]].kind == .f32x1 and made.part[0] == 0) made.from[0] else try floatOf(work, .{ .step = made.from[0], .part = made.part[0] }))
    else
        try put(work, made);
}

/// A float of a step, named through the components and constructs that
/// only name it: what copy propagation leaves of them.
const Float = struct { step: u16, part: u8 };

fn partOf(work: *const Work, at: u16, k: u8) Float {
    var of: Float = .{ .step = at, .part = k };
    while (true) {
        const each = work.steps[of.step];
        switch (each.tag) {
            .construct => of = .{ .step = each.from[of.part], .part = each.part[of.part] },
            .component => of = .{ .step = each.a, .part = @intCast(each.at) },
            else => return of,
        }
    }
}

/// The float as a step of one: the step itself where it is one float,
/// else a component of it.
fn floatOf(work: *Work, of: Float) Error!u16 {
    if (work.steps[of.step].kind == .f32x1) return of.step;
    return put(work, .{ .tag = .component, .kind = .f32x1, .a = of.step, .at = of.part });
}

/// The ALU operations of a selection's arms as nir_opt_peephole_select
/// counts them (block_check_for_allowed_instrs,
/// nir_opt_peephole_select.c:246-310): a float each, but none for a move,
/// a negation, an absolute value or an fsat, which are expected to
/// become modifiers, nor for a product only summed, which an FMA would
/// take. Mesa counts before nir_opt_algebraic lowers the arms, the first
/// time the loop reaches it; these are the steps after lowering, as many
/// or more, so an arm near the limit may be refused here that Mesa would
/// still flatten, and never the other way about. A step nothing reads is
/// one nir_opt_dce has taken out before the count.
fn armCost(work: *const Work, from: u16, to: u16) u32 {
    var count: u32 = 0;
    for (from..to) |at| {
        const each = work.steps[at];
        switch (each.tag) {
            .input, .constant, .push, .component, .construct, .negate, .abs, .sat => continue,
            else => {},
        }
        var used = false;
        var only_added = true;
        for (work.steps[at + 1 .. work.step_count]) |user| if (readsStep(user, @intCast(at))) {
            used = true;
            if (user.tag != .add) only_added = false;
        };
        if (work.stored == at) {
            used = true;
            only_added = false;
        }
        if (!used) continue;
        if (each.tag == .mul and only_added) continue;
        count += if (each.tag == .dot) work.steps[each.a].kind.parts() else each.kind.parts();
    }
    return count;
}

/// Whether `user` reads the step `target`.
fn readsStep(user: Step, target: u16) bool {
    return switch (user.tag) {
        .input, .constant, .push => false,
        .construct => std.mem.indexOfScalar(u16, user.from[0..user.kind.parts()], target) != null,
        .select => user.a == target or user.b == target or user.from[0] == target,
        .component, .discard, .negate, .abs, .sat, .sin, .cos, .sign, .floor, .ceil, .trunc, .round, .recip, .rsqrt, .exp2, .log2 => user.a == target,
        else => user.a == target or user.b == target,
    };
}

/// A type id as a count of floats.
fn kindOf(work: *const Work, id: u16) Error!Kind {
    return switch (work.thing[id]) {
        .float => .f32x1,
        .vector => std.enums.fromInt(Kind, work.wide[id]) orelse Error.Type,
        else => Error.Type,
    };
}

/// The varyings numbered: the floats of every lower location, summed,
/// which is the order a vertex function writes them in (`ir.Build.input`
/// holds a shader to declaring its locations from 0 upwards, and
/// `_play.zig`'s `writeRecord` lays them down in that order). So the
/// locations have to be 0 upwards without a gap: a module that means
/// another numbering is refused rather than mis-compiled.
///
/// The array is left in the order the variables were declared, because
/// `points` names an input by its place in it.
fn order(work: *Work) Error!void {
    const inputs = work.inputs[0..work.input_count];
    var total: u32 = 0;
    for (inputs, 0..) |each, k| {
        if (each.location >= inputs.len) return Error.Location;
        for (inputs[0..k]) |before| if (before.location == each.location) return Error.Location;
        total += each.kind.parts();
    }
    for (inputs) |*each| {
        var first: u32 = 0;
        for (inputs) |other| if (other.location < each.location) {
            first += other.kind.parts();
        };
        each.first = first;
    }
    if (total > most_varyings) return Error.Varyings;
    work.varyings = total;
}

/// One instruction of the body.
fn step(work: *Work, instruction: spirv.Instruction) Error!void {
    const operands = instruction.operands();
    switch (instruction.op) {
        .store => {
            if (operands.len < 2) return Error.Body;
            const into = try idOf(operands[0]);
            if (into != work.output) return Error.Body;
            work.stored = try operand(work, operands[1], .f32x4);
        },
        .load => {
            if (operands.len < 3) return Error.Body;
            const id = try idOf(operands[1]);
            const from = try idOf(operands[2]);
            if (work.thing[from] == .member_pointer) {
                // Floats of the push constants: a uniform each, which
                // Mesa reads as QUNIFORM_UNIFORM at the word the offset
                // names (ntq_emit_load_uniform, nir_to_vir.c:2880, after
                // v3dv's lower_load_push_constant, v3dv_pipeline.c:571).
                // Two loads of one member are two steps, and the second
                // costs no word of the stream: vir_uniform finds it there
                // already (vir_get_uniform_index, vir.c:2771).
                const kind = try kindOf(work, try idOf(operands[0]));
                if (kind.parts() != work.wide[from]) return Error.Type;
                const member = work.points[from];
                const part: u32 = if (work.chain_part[from] == Work.whole) 0 else work.chain_part[from];
                const at = work.member_offset[member] / 4 + part;
                work.step_of[id] = try put(work, .{ .tag = .push, .kind = kind, .at = at });
                return;
            }
            if (work.thing[from] == .input_part) {
                // One float of a varying, which an access chain named:
                // the varying's step, and the float of it, as Mesa's
                // load_input of one component reads the one varying
                // (since 1.152).
                if (try kindOf(work, try idOf(operands[0])) != .f32x1) return Error.Type;
                const of = try inputStep(work, work.points[from]);
                work.step_of[id] = try put(work, .{ .tag = .component, .kind = .f32x1, .a = of, .at = work.chain_part[from] });
                return;
            }
            if (work.thing[from] != .variable) return Error.Body;
            if (work.class[from] == @intFromEnum(spirv.StorageClass.uniform_constant)) {
                // The sampler itself, which is no value: it says which
                // texture the TMU is to be pointed at, and the only
                // instruction that may read it is a sample.
                work.sampler_of[id] = work.sampler_of[from];
                return;
            }
            if (work.class[from] != @intFromEnum(spirv.StorageClass.input)) return Error.Body;
            work.step_of[id] = try inputStep(work, work.points[from]);
        },
        .access_chain => {
            // ResultType, Result, Base, then the indexes: a member of
            // the push constants, and maybe one float of it, each a
            // constant. An index computed in the body would want the
            // push constants read through the TMU (Mesa's
            // ntq_emit_tmu_general fallback), which is not here.
            if (operands.len < 4 or operands.len > 5) return Error.Body;
            const type_id = try idOf(operands[0]);
            const id = try idOf(operands[1]);
            const base = try idOf(operands[2]);
            if (work.thing[base] == .variable and work.class[base] == @intFromEnum(spirv.StorageClass.input)) {
                // One float of a varying, at a constant index, as glslc
                // writes `vcolor.x` (since 1.152): a pointer to it, read
                // when it is loaded.
                if (operands.len != 4) return Error.Body;
                const which = try indexOf(work, operands[3]);
                if (work.wide[base] == 1 or which >= work.wide[base]) return Error.Body;
                if (work.thing[type_id] != .pointer) return Error.Type;
                if (work.class[type_id] != @intFromEnum(spirv.StorageClass.input)) return Error.Body;
                if (try kindOf(work, work.points[type_id]) != .f32x1) return Error.Type;
                work.thing[id] = .input_part;
                work.points[id] = work.points[base];
                work.chain_part[id] = @intCast(which);
                return;
            }
            if (base != work.push_variable) return Error.Storage;
            const member = try indexOf(work, operands[3]);
            if (member >= work.member_count) return Error.Body;
            const member_kind = try kindOf(work, work.member_type[member]);
            var part: u8 = Work.whole;
            var parts = member_kind.parts();
            if (operands.len == 5) {
                const which = try indexOf(work, operands[4]);
                if (member_kind == .f32x1 or which >= parts) return Error.Body;
                part = @intCast(which);
                parts = 1;
            }
            // A pointer of the push constants' class to what it names.
            if (work.thing[type_id] != .pointer) return Error.Type;
            if (work.class[type_id] != @intFromEnum(spirv.StorageClass.push_constant)) return Error.Body;
            if ((try kindOf(work, work.points[type_id])).parts() != parts) return Error.Type;
            work.thing[id] = .member_pointer;
            work.points[id] = member;
            work.chain_part[id] = part;
            work.wide[id] = @intCast(parts);
        },
        .composite_extract => {
            if (operands.len != 4) return Error.Body;
            const id = try idOf(operands[1]);
            const of = work.step_of[try idOf(operands[2])];
            if (of == none) return Error.Body;
            if (work.steps[of].tag == .compare) return Error.Type;
            if (operands[3] >= work.steps[of].kind.parts()) return Error.Body;
            work.step_of[id] = try put(work, .{ .tag = .component, .kind = .f32x1, .a = of, .at = operands[3] });
        },
        .composite_insert => {
            // ResultType, Result, Object, Composite, one index: the
            // vector with that float replaced, nir_vector_insert_imm's
            // vecN of the others and the one (vtn_composite_insert,
            // spirv_to_nir.c:4612-4650).
            if (operands.len != 5) return Error.Body;
            const kind = try kindOf(work, try idOf(operands[0]));
            const id = try idOf(operands[1]);
            const object = try operand(work, operands[2], .f32x1);
            const composite = try operand(work, operands[3], kind);
            if (operands[4] >= kind.parts()) return Error.Body;
            var made = Step{ .tag = .construct, .kind = kind };
            for (0..kind.parts()) |k| {
                made.from[k] = if (k == operands[4]) object else composite;
                made.part[k] = if (k == operands[4]) 0 else @intCast(k);
            }
            work.step_of[id] = try put(work, made);
        },
        .composite_construct => {
            if (operands.len < 3) return Error.Body;
            const type_id = try idOf(operands[0]);
            const id = try idOf(operands[1]);
            const kind = try kindOf(work, type_id);
            var made = Step{ .tag = .construct, .kind = kind };
            var floats: u32 = 0;
            for (operands[2..]) |each| {
                const each_id = try idOf(each);
                // A constituent is a read, and a constant has no step
                // until something reads it - so this takes the same path
                // `f_add` and `f_mul` take for a constant operand rather
                // than refusing. `vec4(uv.x, uv.y, 0.25, 1.0)`, which is
                // what glslc writes for `vec4(uv, 0.25, 1.0)`, is the
                // common shape; refusing it would also have made the
                // answer depend on whether some unrelated earlier
                // instruction happened to read the same constant first.
                const of = if (work.step_of[each_id] != none)
                    work.step_of[each_id]
                else
                    try operand(work, each, std.enums.fromInt(Kind, work.wide[each_id]) orelse return Error.Type);
                if (of == none) return Error.Body;
                if (work.steps[of].tag == .compare) return Error.Type;
                const parts = work.steps[of].kind.parts();
                var part: u8 = 0;
                while (part < parts) : (part += 1) {
                    if (floats == 4) return Error.Body;
                    made.from[floats] = of;
                    made.part[floats] = part;
                    floats += 1;
                }
            }
            if (floats != kind.parts()) return Error.Body;
            work.step_of[id] = try put(work, made);
        },
        .f_ord_less_than, .f_ord_greater_than, .f_ord_equal, .f_unord_not_equal, .f_ord_greater_than_equal, .f_ord_less_than_equal => {
            // Two floats, and a bool: a vector compared would be a vector
            // of bools, which nothing here reads. FOrdNotEqual and the
            // other unordered ones are bools of several comparisons in NIR
            // (vtn_alu.c:930-1010), and are not here.
            if (operands.len != 4) return Error.Body;
            const type_id = try idOf(operands[0]);
            const id = try idOf(operands[1]);
            if (work.thing[type_id] != .boolean) return Error.Type;
            const a = try operand(work, operands[2], .f32x1);
            const b = try operand(work, operands[3], .f32x1);
            const which: Comparison = switch (instruction.op) {
                .f_ord_less_than => .less,
                .f_ord_greater_than => .greater,
                .f_ord_equal => .equal,
                .f_unord_not_equal => .not_equal,
                .f_ord_greater_than_equal => .greater_equal,
                else => .less_equal,
            };
            work.step_of[id] = try put(work, .{ .tag = .compare, .kind = .f32x1, .a = a, .b = b, .at = @intFromEnum(which) });
        },
        .select => {
            // ResultType, Result, Condition, Object 1, Object 2: NIR's
            // bcsel. Of one float, its condition one bool; a vector
            // chosen wants a vector of bools in SPIR-V 1.0, which nothing
            // here makes (since 1.153).
            if (operands.len != 5) return Error.Body;
            if (try kindOf(work, try idOf(operands[0])) != .f32x1) return Error.Type;
            const id = try idOf(operands[1]);
            const condition = work.step_of[try idOf(operands[2])];
            if (condition == none or work.steps[condition].tag != .compare) return Error.Type;
            const yes = try operand(work, operands[3], .f32x1);
            const no = try operand(work, operands[4], .f32x1);
            var made = Step{ .tag = .select, .kind = .f32x1, .a = condition, .b = yes };
            made.from[0] = no;
            work.step_of[id] = try put(work, made);
        },
        .f_add, .f_mul, .f_sub => {
            if (operands.len != 4) return Error.Body;
            const type_id = try idOf(operands[0]);
            const id = try idOf(operands[1]);
            const kind = try kindOf(work, type_id);
            const a = try operand(work, operands[2], kind);
            const b = try operand(work, operands[3], kind);
            work.step_of[id] = try switch (instruction.op) {
                // A sum one of whose two is negated is a difference, as
                // Mesa's late algebraic pass makes fadd(a, fneg(b)) an
                // fsub where the device has one (nir_opt_algebraic.py:3868,
                // `has_fsub`, v3dv_pipeline.c:207), either way round: the
                // XOR the negation came to is then read by nothing and
                // goes in vir_optimize.
                .f_add => if (work.steps[b].tag == .negate)
                    binary(work, .sub, a, work.steps[b].a)
                else if (work.steps[a].tag == .negate)
                    binary(work, .sub, b, work.steps[a].a)
                else
                    binary(work, .add, a, b),
                .f_mul => binary(work, .mul, a, b),
                else => binary(work, .sub, a, b),
            };
        },
        .f_negate => {
            if (operands.len != 3) return Error.Body;
            const kind = try kindOf(work, try idOf(operands[0]));
            const id = try idOf(operands[1]);
            work.step_of[id] = try unary(work, .negate, try operand(work, operands[2], kind));
        },
        .f_div => {
            // a times one over b, as v3dv has NIR lower it (`lower_fdiv`,
            // v3dv_pipeline.c:193; nir_opt_algebraic.py:1918).
            if (operands.len != 4) return Error.Body;
            const kind = try kindOf(work, try idOf(operands[0]));
            const id = try idOf(operands[1]);
            const a = try operand(work, operands[2], kind);
            const b = try operand(work, operands[3], kind);
            work.step_of[id] = try binary(work, .mul, a, try unary(work, .recip, b));
        },
        .dot => {
            if (operands.len != 4) return Error.Body;
            if (try kindOf(work, try idOf(operands[0])) != .f32x1) return Error.Type;
            const id = try idOf(operands[1]);
            const kind = try kindOfValue(work, operands[2]);
            if (kind == .f32x1) return Error.Type;
            const a = try operand(work, operands[2], kind);
            const b = try operand(work, operands[3], kind);
            work.step_of[id] = try dotOf(work, a, b);
        },
        .vector_shuffle => {
            // ResultType, Result, two vectors, then a float of either for
            // each of the result's: names, as nir_swizzle's are, which a
            // construct of them is. 0xFFFFFFFF, a float left undefined,
            // is refused rather than made up (since 1.152).
            if (operands.len < 6) return Error.Body;
            const kind = try kindOf(work, try idOf(operands[0]));
            const id = try idOf(operands[1]);
            const first_kind = try kindOfValue(work, operands[2]);
            const second_kind = try kindOfValue(work, operands[3]);
            const first = try operand(work, operands[2], first_kind);
            const second = try operand(work, operands[3], second_kind);
            const picks = operands[4..];
            if (picks.len != kind.parts()) return Error.Body;
            var made = Step{ .tag = .construct, .kind = kind };
            for (picks, 0..) |pick, k| {
                if (pick < first_kind.parts()) {
                    made.from[k] = first;
                    made.part[k] = @intCast(pick);
                } else if (pick - first_kind.parts() < second_kind.parts()) {
                    made.from[k] = second;
                    made.part[k] = @intCast(pick - first_kind.parts());
                } else return Error.Body;
            }
            work.step_of[id] = try put(work, made);
        },
        .ext_inst => {
            // ResultType, Result, Set, Instruction, then its operands.
            if (operands.len < 5) return Error.Body;
            const kind = try kindOf(work, try idOf(operands[0]));
            const id = try idOf(operands[1]);
            if (work.glsl == none or try idOf(operands[2]) != work.glsl) return Error.Body;
            work.step_of[id] = try glslCall(work, operands[3], kind, operands[4..]);
        },
        .image_sample_implicit_lod => {
            // ResultType, Result, SampledImage, Coordinate. An image
            // operand past those would be a bias, an offset or a lod,
            // each of which is a different TMU write: none is emitted
            // here, so a module that asks for one is refused.
            if (operands.len != 4) return Error.Body;
            const type_id = try idOf(operands[0]);
            const id = try idOf(operands[1]);
            if (try kindOf(work, type_id) != .f32x4) return Error.Type;
            const which = work.sampler_of[try idOf(operands[2])];
            if (which == none) return Error.Body;
            // The coordinate before the count is raised, so that a second
            // sample is refused for being a second and not for anything
            // its coordinate does.
            const where = try operand(work, operands[3], .f32x2);
            if (work.sample_count != 0) return Error.Samplers;
            const made = try put(work, .{ .tag = .sample, .kind = .f32x4, .a = where, .at = which });
            work.step_of[id] = made;
            work.sampled = made;
            work.sample_count = 1;
        },
        .image_sample_dref_implicit_lod => {
            // ResultType, Result, SampledImage, Coordinate, Dref: one
            // float, compared with the reference (since 1.143). An image
            // operand past them is refused as it is for a plain sample.
            if (operands.len != 5) return Error.Body;
            const type_id = try idOf(operands[0]);
            const id = try idOf(operands[1]);
            if (try kindOf(work, type_id) != .f32x1) return Error.Type;
            const which = work.sampler_of[try idOf(operands[2])];
            if (which == none) return Error.Body;
            const where = try coordinateOf(work, operands[3]);
            const against = try operand(work, operands[4], .f32x1);
            if (work.sample_count != 0) return Error.Samplers;
            const made = try put(work, .{ .tag = .sample_compared, .kind = .f32x1, .a = where, .b = against, .at = which });
            work.step_of[id] = made;
            work.sampled = made;
            work.sample_count = 1;
        },
        .vector_times_scalar => {
            if (operands.len != 4) return Error.Body;
            const type_id = try idOf(operands[0]);
            const id = try idOf(operands[1]);
            const kind = try kindOf(work, type_id);
            if (kind == .f32x1) return Error.Type;
            const vector = try operand(work, operands[2], kind);
            const scalar = try operand(work, operands[3], .f32x1);
            work.step_of[id] = try put(work, .{ .tag = .mul, .kind = kind, .a = vector, .b = scalar });
        },
        else => return Error.Refused,
    }
}

/// A call of GLSL.std.450 in the steps it lowers to: spirv_to_nir's
/// (vtn_glsl450.c:131-180 for one NIR op, :245-277 for the built ones)
/// and then v3dv's NIR options (v3dv_pipeline.c:177-198): fdiv, fsqrt,
/// fpow, ffract and flrp lowered, fsat not at 7.1 (:225), fsub kept
/// (:207). Sin, Cos, Tan, FSign, Step and SmoothStep are here since
/// 1.153. What is left out - the inverse and hyperbolic trigonometry, the
/// integers, Cross, the packing and interpolation - is refused by name,
/// `Error.Body` (since 1.152).
fn glslCall(work: *Work, instruction: u32, kind: Kind, arguments: []const u32) Error!u16 {
    const which = std.enums.fromInt(spirv.Glsl, instruction) orelse return Error.Body;
    switch (which) {
        .round, .round_even, .trunc, .f_abs, .floor, .ceil, .fract, .radians, .degrees => {},
        .pow, .exp, .log, .exp2, .log2, .sqrt, .inverse_sqrt => {},
        .f_min, .f_max, .n_min, .n_max, .f_clamp, .n_clamp, .f_mix, .length, .distance, .normalize => {},
        .sin, .cos, .tan, .f_sign, .step, .smooth_step => {},
        else => return Error.Body,
    }
    const wanted: usize = switch (which) {
        .f_min, .f_max, .n_min, .n_max, .pow, .distance, .step => 2,
        .f_clamp, .n_clamp, .f_mix, .smooth_step => 3,
        else => 1,
    };
    if (arguments.len != wanted) return Error.Body;
    // Length and Distance answer one float of vectors; every other takes
    // operands of the kind it answers.
    const of_kind = switch (which) {
        .length, .distance => try kindOfValue(work, arguments[0]),
        else => kind,
    };
    if ((which == .length or which == .distance) and kind != .f32x1) return Error.Type;
    var x: [3]u16 = undefined;
    for (arguments, 0..) |each, k| x[k] = try operand(work, each, of_kind);
    return switch (which) {
        .round, .round_even => unary(work, .round, x[0]),
        .trunc => unary(work, .trunc, x[0]),
        .f_abs => unary(work, .abs, x[0]),
        .floor => unary(work, .floor, x[0]),
        .ceil => unary(work, .ceil, x[0]),
        // a - ffloor(a) (`lower_ffract`, nir_opt_algebraic.py:546).
        .fract => binary(work, .sub, x[0], try unary(work, .floor, x[0])),
        // fmul_imm(x, M_PI / 180) and (180 / M_PI) (nir_radians,
        // nir_degrees, nir_builtin_builder.h:171-174, 238-241).
        .radians => binary(work, .mul, x[0], try immediate(work, double(std.math.pi / @as(f64, 180.0)))),
        .degrees => binary(work, .mul, x[0], try immediate(work, double(@as(f64, 180.0) / std.math.pi))),
        // fexp2(flog2(a) * b) (`lower_fpow`, nir_opt_algebraic.py:1884).
        .pow => unary(work, .exp2, try binary(work, .mul, try unary(work, .log2, x[0]), x[1])),
        // fexp2(x * M_LOG2E) and flog2(x) * (1 / M_LOG2E) (nir_fexp,
        // nir_flog, nir_builtin_builder.h:112-122).
        .exp => unary(work, .exp2, try binary(work, .mul, x[0], try immediate(work, double(std.math.log2e)))),
        .log => binary(work, .mul, try unary(work, .log2, x[0]), try immediate(work, double(@as(f64, 1.0) / std.math.log2e))),
        .exp2 => unary(work, .exp2, x[0]),
        .log2 => unary(work, .log2, x[0]),
        // frcp(frsq(a)) (`lower_fsqrt`, nir_opt_algebraic.py:1921).
        .sqrt => unary(work, .recip, try unary(work, .rsqrt, x[0])),
        .inverse_sqrt => unary(work, .rsqrt, x[0]),
        .f_min, .n_min => minOf(work, x[0], x[1]),
        .f_max, .n_max => binary(work, .max, x[0], x[1]),
        // fmin(fmax(x, lo), hi) (nir_fclamp, nir_builder.h:1411-1415),
        // fsat where lo and hi are 0.0 and 1.0.
        .f_clamp, .n_clamp => if (isSplat(work, x[1], 0.0) and isSplat(work, x[2], 1.0))
            unary(work, .sat, x[0])
        else
            binary(work, .min, try binary(work, .max, x[0], x[1]), x[2]),
        // fsin and fcos, ntq_fsincos's; ftan their quotient, fdiv lowered
        // (nir_ftan, nir_builtin_builder.h:254-257).
        .sin => unary(work, .sin, x[0]),
        .cos => unary(work, .cos, x[0]),
        .tan => tan: {
            const sine = try unary(work, .sin, x[0]);
            break :tan binary(work, .mul, sine, try unary(work, .recip, try unary(work, .cos, x[0])));
        },
        .f_sign => unary(work, .sign, x[0]),
        // 1.0 - slt(x, edge), the edge the first operand
        // (vtn_glsl450.c:222-243).
        .step => binary(work, .sub, try immediateOf(work, 1.0, kind), try binary(work, .set_less, x[1], x[0])),
        // t = fsat((x - e0) / (e1 - e0)), then t * (t * (3 - 2t)), the
        // 3 - 2t nir_a_minus_bc's ffma_weak(-2, t, 3) split as a device of
        // no FMA has it (nir_smoothstep, nir_builtin_builder.c:139-152;
        // nir_builder.h:1455-1459; nir_opt_algebraic.py:424). Constant
        // edges fold, as NIR folds them.
        .smooth_step => smooth: {
            const two = try immediateOf(work, 2.0, kind);
            const three = try immediateOf(work, 3.0, kind);
            const from = try binary(work, .sub, x[2], x[0]);
            const width = try binary(work, .sub, x[1], x[0]);
            const t = try unary(work, .sat, try binary(work, .mul, from, try unary(work, .recip, width)));
            const less = try binary(work, .add, try binary(work, .mul, try unary(work, .negate, two), t), three);
            break :smooth binary(work, .mul, t, try binary(work, .mul, t, less));
        },
        .f_mix => mix(work, x[0], x[1], x[2]),
        // fsqrt(fdot(v, v)) (nir_fast_length, nir_builtin_builder.c:63-66),
        // its square root lowered as Sqrt's.
        .length => lengthOf(work, x[0]),
        .distance => lengthOf(work, try binary(work, .sub, x[0], x[1])),
        // fdiv(v, fsqrt(fdot(v, v))) (nir_fast_normalize,
        // nir_builtin_builder.h:194-197): lowered, v times
        // frcp(frcp(frsq(d))), the two frcp one fcanonicalize
        // (nir_opt_algebraic.py:1919), which folds away (:161-171).
        .normalize => binary(work, .mul, x[0], try unary(work, .rsqrt, try dotOf(work, x[0], x[0]))),
        else => unreachable,
    };
}

/// A constant of C's doubles, as nir_imm_floatN_t takes one to 32 bits.
fn double(value: f64) f32 {
    return @floatCast(value);
}

/// flrp(x, y, t) as nir_lower_flrp lowers it where there is no FMA and
/// precision is not demanded (vir.c:2084-2085): x(1 - t) + yt where t is a
/// constant, its 1 - t folded, and x + t(y - x) otherwise
/// (convert_flrp_instruction, nir_lower_flrp.c:495-551,
/// replace_with_strict and replace_with_fast, :96-145). Left out is the
/// choice it makes for a flrp sharing its x or its y and its t with
/// another (get_similar_flrp_stats), which shares work and changes no
/// sum's terms but their order.
fn mix(work: *Work, x: u16, y: u16, t: u16) Error!u16 {
    const of_t = work.steps[t];
    if (of_t.tag != .constant) {
        const product = try binary(work, .mul, t, try binary(work, .sub, y, x));
        return binary(work, .add, x, product);
    }
    const parts = of_t.kind.parts();
    if (work.pool_count + parts > work.pool.len) return Error.Uniforms;
    const at = work.pool_count;
    for (0..parts) |k| work.pool[at + k] = 1.0 + -work.pool[of_t.at + k];
    work.pool_count += parts;
    const one_less = try put(work, .{ .tag = .constant, .kind = of_t.kind, .at = at });
    const first = try binary(work, .mul, x, one_less);
    const second = try binary(work, .mul, y, t);
    return binary(work, .add, first, second);
}

/// fsqrt(fdot(v, v)) lowered: frcp(frsq(d)). A float alone is its own
/// dot, an fmul (nir_fdot of one component).
fn lengthOf(work: *Work, v: u16) Error!u16 {
    return unary(work, .recip, try unary(work, .rsqrt, try dotOf(work, v, v)));
}

/// fmin of `a` and `b`, or fsat where it is fmin(fmax(x, 0.0), 1.0), as
/// the algebraic pass makes it either way round (nir_opt_algebraic.py:1095,
/// `lower_fsat` false at 7.1, v3dv_pipeline.c:225). The FMAX is then read
/// by nothing and goes in vir_optimize (since 1.153).
fn minOf(work: *Work, a: u16, b: u16) Error!u16 {
    for ([2][2]u16{ .{ a, b }, .{ b, a } }) |pair| {
        const of = work.steps[pair[0]];
        if (of.tag != .max or !isSplat(work, pair[1], 1.0)) continue;
        if (isSplat(work, of.b, 0.0)) return unary(work, .sat, of.a);
        if (isSplat(work, of.a, 0.0)) return unary(work, .sat, of.b);
    }
    return binary(work, .min, a, b);
}

/// Whether a step is a constant of `value` in every float.
fn isSplat(work: *const Work, step_at: u16, value: f32) bool {
    const of = work.steps[step_at];
    if (of.tag != .constant) return false;
    for (0..of.kind.parts()) |k| {
        if (work.pool[of.at + k] != value) return false;
    }
    return true;
}

/// `value` in each float of `kind`: nir_imm_floatN_t's, which a lowering
/// of a vector reads swizzled to each float of it.
fn immediateOf(work: *Work, value: f32, kind: Kind) Error!u16 {
    const parts = kind.parts();
    if (work.pool_count + parts > work.pool.len) return Error.Uniforms;
    const at = work.pool_count;
    for (0..parts) |k| work.pool[at + k] = value;
    work.pool_count += parts;
    return put(work, .{ .tag = .constant, .kind = kind, .at = at });
}

/// NIR's constant folding (nir_opt_constant_folding, in v3d's
/// optimization loop, nir_to_vir.c:2281): an operation whose operands are
/// all constants is the constant it makes, worked out as nir_opcodes.py
/// has each one in floats, on the host (since 1.153). SmoothStep's
/// constant edges are its common case. Left to the device are the SFU's
/// functions - fexp2, flog2, fsin, fcos - which NIR folds with the host's
/// libm, to no bit the walk could promise.
fn foldedOf(work: *Work, tag: Tag, a: u16, b: ?u16) Error!?u16 {
    switch (tag) {
        .add, .sub, .mul, .min, .max, .set_less, .negate, .abs, .floor, .ceil, .trunc, .round, .recip, .rsqrt, .sat, .sign => {},
        else => return null,
    }
    const of_a = work.steps[a];
    if (of_a.tag != .constant) return null;
    var of_b: Step = of_a;
    if (b) |at| {
        of_b = work.steps[at];
        if (of_b.tag != .constant) return null;
    }
    const parts = of_a.kind.parts();
    if (work.pool_count + parts > work.pool.len) return Error.Uniforms;
    const out = work.pool_count;
    for (0..parts) |k| {
        const x = work.pool[of_a.at + k];
        const y = work.pool[of_b.at + if (of_b.kind == .f32x1) 0 else k];
        work.pool[out + k] = switch (tag) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
            // util_min_num and util_max_num: a NaN loses.
            .min => if (std.math.isNan(x)) y else if (std.math.isNan(y)) x else @min(x, y),
            .max => if (std.math.isNan(x)) y else if (std.math.isNan(y)) x else @max(x, y),
            .set_less => if (x < y) 1.0 else 0.0,
            .negate => -x,
            .abs => @abs(x),
            .floor => @floor(x),
            .ceil => @ceil(x),
            .trunc => @trunc(x),
            .round => roundEven(x),
            .recip => 1.0 / x,
            .rsqrt => 1.0 / @sqrt(x),
            .sat => if (std.math.isNan(x)) 0.0 else @min(@max(x, 0.0), 1.0),
            .sign => if (std.math.isNan(x)) 0.0 else if (x == 0.0) x else if (x > 0.0) 1.0 else -1.0,
            else => unreachable,
        };
    }
    work.pool_count += parts;
    return try put(work, .{ .tag = .constant, .kind = of_a.kind, .at = out });
}

/// _mesa_roundevenf: to the nearest whole float, a half to the even one.
fn roundEven(x: f32) f32 {
    if (@abs(x - @trunc(x)) != 0.5) return @round(x);
    return 2.0 * @round(x / 2.0);
}

/// The dot of two values of one kind; of one float each, their product,
/// as nir_fdot builds it for one component.
fn dotOf(work: *Work, a: u16, b: u16) Error!u16 {
    if (work.steps[a].kind == .f32x1) return binary(work, .mul, a, b);
    return put(work, .{ .tag = .dot, .kind = .f32x1, .a = a, .b = b });
}

/// `tag` of `a`, or the constant it folds to.
fn unary(work: *Work, tag: Tag, a: u16) Error!u16 {
    if (try foldedOf(work, tag, a, null)) |constant| return constant;
    return put(work, .{ .tag = tag, .kind = work.steps[a].kind, .a = a });
}

/// `tag` of `a` and `b`, of `a`'s kind: `b` is of it too, or one float.
/// Or the constant it folds to.
fn binary(work: *Work, tag: Tag, a: u16, b: u16) Error!u16 {
    if (try foldedOf(work, tag, a, b)) |constant| return constant;
    return put(work, .{ .tag = tag, .kind = work.steps[a].kind, .a = a, .b = b });
}

/// A float of the walk's own, a step of one uniform: what NIR's
/// nir_imm_float is where a lowering multiplies by one (since 1.152).
fn immediate(work: *Work, value: f32) Error!u16 {
    if (work.pool_count == work.pool.len) return Error.Uniforms;
    const at = work.pool_count;
    work.pool[at] = value;
    work.pool_count += 1;
    return put(work, .{ .tag = .constant, .kind = .f32x1, .at = at });
}

/// The step of the varying `which`, loaded the first time it is read: a
/// varying is handed over once, so two loads of it are the one step, or
/// the second would take the next varying rather than read this one
/// again.
fn inputStep(work: *Work, which: u16) Error!u16 {
    if (work.inputs[which].step == none) {
        const made = try put(work, .{ .tag = .input, .kind = work.inputs[which].kind, .at = which });
        work.inputs[which].step = made;
    }
    return work.inputs[which].step;
}

/// The kind of what an operand id names: its step's, or a constant's.
fn kindOfValue(work: *const Work, word: u32) Error!Kind {
    const id = try idOf(word);
    if (work.step_of[id] != none) {
        const of = work.steps[work.step_of[id]];
        if (of.tag == .compare) return Error.Type;
        return of.kind;
    }
    if (work.thing[id] != .constant) return Error.Body;
    return std.enums.fromInt(Kind, work.wide[id]) orelse Error.Type;
}

/// Whether a literal string's words are `name`, nul-terminated and padded
/// with zeros to the word.
fn literalIs(words: []const u32, name: []const u8) bool {
    if (words.len != name.len / 4 + 1) return false;
    for (0..words.len * 4) |k| {
        const byte: u8 = @truncate(words[k / 4] >> @intCast(8 * (k % 4)));
        const expected: u8 = if (k < name.len) name[k] else 0;
        if (byte != expected) return false;
    }
    return true;
}

/// An access chain's index: an integer constant's value.
fn indexOf(work: *const Work, word: u32) Error!u16 {
    const id = try idOf(word);
    if (work.thing[id] != .int_constant) return Error.Body;
    return work.points[id];
}

/// An operand id as a step of `kind`. A constant becomes a step of its
/// own the first time it is read, which is one uniform a float.
/// A shadow sample's coordinate: two floats or more, the TMU given the
/// first two. SPIR-V lets a coordinate be wider than its image needs, the
/// floats it does not use after those it does, and glslc's
/// `texture(sampler2DShadow, vec3(uv, reference))` is one: the reference
/// is the third float, extracted from it as the Dref (since 1.143).
fn coordinateOf(work: *Work, word: u32) Error!u16 {
    const id = try idOf(word);
    const kind = if (work.step_of[id] != none)
        work.steps[work.step_of[id]].kind
    else
        std.enums.fromInt(Kind, work.wide[id]) orelse return Error.Type;
    if (kind == .f32x1) return Error.Type;
    return operand(work, word, kind);
}

fn operand(work: *Work, word: u32, kind: Kind) Error!u16 {
    const id = try idOf(word);
    if (work.step_of[id] != none) {
        // A bool is no float, whatever its step's width says.
        if (work.steps[work.step_of[id]].tag == .compare) return Error.Type;
        if (work.steps[work.step_of[id]].kind != kind) return Error.Type;
        return work.step_of[id];
    }
    if (work.thing[id] != .constant) return Error.Body;
    if (work.wide[id] != kind.parts()) return Error.Type;
    // Where its floats are in the pool, not in the stream: what place
    // they take in the stream is the order the instructions ask for them,
    // which is not known until the plan is laid out.
    const made = try put(work, .{ .tag = .constant, .kind = kind, .at = work.points[id] });
    work.step_of[id] = made;
    return made;
}

fn put(work: *Work, made: Step) Error!u16 {
    if (work.step_count == most_steps) return Error.Steps;
    work.steps[work.step_count] = made;
    const at: u16 = @intCast(work.step_count);
    work.step_count += 1;
    return at;
}

// --- level 2: the plan -------------------------------------------------------

/// The steps given registers and instructions, in the order the hardware
/// wants them: the varyings, then the body, then the wait on the
/// scoreboard, and only then the tile buffer.
///
/// The varyings come first because `ldvary` hands them over in order and
/// one cannot be stepped over; everything else follows the body. A
/// program's own floats are read where they are first wanted - a uniform
/// is the next one in the stream wherever its instruction sits, so the
/// order of the stream is the order the steps ask for them and nothing
/// more.
fn settle(work: *Work) Error!void {
    try live(work);
    // Every varying the draw carries, in the order the hardware hands
    // them over - which is by location, whatever order the variables were
    // declared in. One the body does not read still costs its three
    // instructions: `ldvary` takes the next there is and there is no way
    // to step over one, and every hand-written program issues exactly one
    // `ldvary` for each varying its record declares. What the hardware
    // makes of a program that reads fewer than that is not written down
    // anywhere, so none is written here.
    var varying: u32 = 0;
    while (varying < work.varyings) : (varying += 1) {
        const which = ownerOf(work, varying) orelse return Error.Location;
        const each = work.inputs[which];
        if (each.step == none) {
            try act(work, .{ .varying = qpu.rf_scaled });
            continue;
        }
        try act(work, .{ .varying = try take(work, work.slot_of[each.step][varying - each.first]) });
    }
    // The 1 a texel's half is multiplied by to be read as a float of its
    // own, where the program will want one. It is loaded here, with the
    // varyings, and not where it is first wanted: that would be past the
    // splice, and no hand-written program reads a uniform there.
    if (wantsOne(work)) _ = try one(work);
    // And, where the program samples, every float of its own, for the
    // same reason and not only the 1.
    //
    // A program that does not sample reads each where it is first
    // wanted: the splice is then the last thing before the colour, so
    // nothing can fall past it, and reading late is what lets eight
    // varyings and four floats of its own fit ten registers. A sampling
    // program's splice is inside its body - between the write to S and
    // the two words coming back - so a float first wanted after the
    // texel would be an `ldunifrf` in the last thread section. No
    // hand-written program reads the uniform stream there: `flat_code`
    // takes both of its uniforms before `last_section`, and all five
    // sampling programs take their two `wrtmuc` before it. Rather than
    // emit the one shape the file refuses thirty lines below, every
    // uniform goes in front of the splice and `sound` holds the whole
    // program to it. It costs registers held across the sample, and a
    // program that then does not fit is refused as any other is.
    if (work.sample_count != 0) {
        for (work.steps[0..work.step_count], 0..) |each, at| {
            if (each.tag != .constant) continue;
            var part: u32 = 0;
            while (part < each.kind.parts()) : (part += 1) {
                try streamed(work, .{ .float = work.pool[each.at + part] });
                try act(work, .{ .uniform = try take(work, work.slot_of[at][part]) });
            }
        }
    }
    // Then the body, in its own order.
    for (work.steps[0..work.step_count], 0..) |each, at| {
        switch (each.tag) {
            // Loaded above; a component or a construct names floats that
            // are already in registers, so neither costs an instruction.
            .input, .component, .construct => {},
            // Refused by `compile` before the plan is laid out.
            .push => return Error.Storage,
            .compare, .discard => return Error.Discards,
            .sample_compared => return Error.Samplers,
            .sub, .min, .max, .negate, .abs, .floor, .ceil, .trunc, .round, .recip, .rsqrt, .exp2, .log2, .dot => return Error.Body,
            .select, .set_less, .sat, .sin, .cos, .sign => return Error.Body,
            // A float of its own, read where it is first wanted rather
            // than at the top: a uniform is the next one in the stream
            // wherever the instruction sits, and holding them to the end
            // of the program would keep registers for nothing. Where the
            // program samples they are all loaded above instead, because
            // the splice falls inside the body there.
            .constant => if (work.sample_count == 0) {
                var part: u32 = 0;
                while (part < each.kind.parts()) : (part += 1) {
                    try streamed(work, .{ .float = work.pool[each.at + part] });
                    try act(work, .{ .uniform = try take(work, work.slot_of[at][part]) });
                }
            },
            .sample => try sample(work, each, @intCast(at)),
            .add, .mul => {
                const wide = each.kind.parts();
                var part: u32 = 0;
                while (part < wide) : (part += 1) {
                    const a_slot = work.slot_of[each.a][part];
                    // A vector times a scalar reads the one float of the
                    // scalar for each of the vector's.
                    const b_part = if (work.steps[each.b].kind == .f32x1) 0 else part;
                    const b_slot = work.slot_of[each.b][b_part];
                    // A texel's float is half of a packed pair, and
                    // `fmulLow`/`fmulHigh` is the only instruction that
                    // reads one. Where the step is that float times one
                    // that is already in a register, the instruction
                    // *is* the step - which is what
                    // `qpu.texture_color_code` does, and it is why a
                    // texture modulated by the vertices' colour costs
                    // four instructions and not eight.
                    const a_packed = work.slot_half[a_slot] != .none;
                    const b_packed = work.slot_half[b_slot] != .none;
                    if (fuses(each.tag, a_packed, b_packed)) {
                        const from = if (a_packed) a_slot else b_slot;
                        const by = work.slot_reg[if (a_packed) b_slot else a_slot];
                        try wait(work, &.{ by, work.slot_reg[from] }, 0);
                        const to = try destination(work, each, @intCast(at), part, a_slot, b_slot);
                        try act(work, .{ .half = .{
                            .to = to,
                            .from = work.slot_reg[from],
                            .high = work.slot_half[from] == .high,
                            .by = by,
                        } });
                        continue;
                    }
                    // Anything else wants the float in a register of its
                    // own first, which is the same instruction against a
                    // 1 the program reads as a uniform.
                    const a = try plain(work, a_slot);
                    const b = try plain(work, b_slot);
                    try wait(work, &.{ a, b }, 0);
                    const to = try destination(work, each, @intCast(at), part, a_slot, b_slot);
                    try act(work, if (each.tag == .add) .{ .fadd = .{ .to = to, .a = a, .b = b } } else .{ .fmul = .{ .to = to, .a = a, .b = b } });
                }
            },
        }
        release(work, @intCast(at));
    }
    // The wait on the scoreboard, and then the colour: nothing may touch
    // the tile buffer before it. Where the body sampled, the splice is
    // already behind us - it is between the write to S and the words
    // coming back, which is where every hand-written program that
    // samples puts it. Where it did not, it goes here, and what the
    // colour waits for is waited out first so that the two writes stay
    // next to it as they are in `flat_code`.
    const slots = work.slot_of[work.stored];
    // A texel drawn as it is: the two words the TMU handed back are
    // already two pairs of half-floats, which is what the tile buffer
    // takes, so nothing unpacks them and nothing packs them again
    // (`qpu.texture_code`).
    //
    // Only while all four are still in their pairs, though. `plain`
    // reads a half out into a register of its own and points the slot
    // at *that*, and once both halves of a word are out it hands the
    // word's register back to the pool - so a program that draws the
    // texel and also reads a float out of it would otherwise move a
    // single f32, or a register something else now owns, to the tile
    // buffer as if it were two half-floats. Where that has happened the
    // colour below is right: it packs the four floats back, and the 1 it
    // needs is already loaded, because reading a half out non-fused is
    // exactly what makes `wantsOne` true.
    const packed_whole = work.steps[work.stored].tag == .sample and
        work.slot_half[slots[0]] == .low and work.slot_half[slots[1]] == .high and
        work.slot_half[slots[2]] == .low and work.slot_half[slots[3]] == .high;
    if (packed_whole) {
        const first = work.slot_reg[slots[0]];
        const second = work.slot_reg[slots[2]];
        try wait(work, &.{first}, 0);
        try act(work, .{ .color_packed = first });
        try wait(work, &.{second}, 0);
        try act(work, .{ .color_packed = second });
        try act(work, .end);
        return;
    }
    var colour: [4]qpu.Rf = undefined;
    for (&colour, 0..) |*reg, part| reg.* = try plain(work, slots[part]);
    if (work.sample_count == 0) {
        try wait(work, &colour, qpu.last_section.len);
        try act(work, .last_section);
    } else {
        try wait(work, &colour, 0);
    }
    try act(work, .{ .color = .{ .low = colour[0], .high = colour[1] } });
    try act(work, .{ .color = .{ .low = colour[2], .high = colour[3] } });
    try act(work, .end);
}

/// One word onto the uniform stream, in the order the instructions ask
/// for it: `ldunifrf` and `wrtmuc` each take the next there is.
fn streamed(work: *Work, word: Word) Error!void {
    if (work.stream_count == most_uniforms) return Error.Uniforms;
    work.stream[work.stream_count] = word;
    work.stream_count += 1;
}

/// A texel. The coordinate goes to the TMU, T first and S last because
/// the write to S is what starts the lookup; the two configuration words
/// are taken off the uniform stream between them; and then the splice,
/// which is where every hand-written program that samples puts it - the
/// words come back five instructions after S, and the splice is four of
/// them (`qpu.texture_code`, `qpu.texture_color_code`). What comes back
/// is two words of two half-floats, which is the form the tile buffer
/// takes.
fn sample(work: *Work, each: Step, at: u16) Error!void {
    const coordinate = work.slot_of[each.a];
    const s = try plain(work, coordinate[0]);
    const t = try plain(work, coordinate[1]);
    try wait(work, &.{ s, t }, 0);
    try act(work, .{ .tmu = .{ .which = .t, .from = t } });
    try streamed(work, .texture);
    try act(work, .config);
    try streamed(work, .sampler);
    try act(work, .config);
    try act(work, .{ .tmu = .{ .which = .s, .from = s } });
    try act(work, .last_section);
    const slots = work.slot_of[at];
    const first = try take(work, slots[0]);
    const second = try take(work, slots[2]);
    work.slot_reg[slots[1]] = first;
    work.slot_reg[slots[3]] = second;
    for ([4]Half{ .low, .high, .low, .high }, 0..) |half, part| work.slot_half[slots[part]] = half;
    for ([4]u8{ 1, 0, 3, 2 }, 0..) |mate, part| work.slot_pair[slots[part]] = slots[mate];
    try act(work, .{ .texel = first });
    try act(work, .{ .texel = second });
}

/// `slot`'s float in a register of its own. Every float but a texel's
/// already is one; a texel's is half of a packed pair, and the only
/// instruction that reads one is a multiply - so it is multiplied by a 1
/// the program reads as a uniform like any other float it holds.
fn plain(work: *Work, slot: u16) Error!qpu.Rf {
    const half = work.slot_half[slot];
    if (half == .none) return work.slot_reg[slot];
    const from = work.slot_reg[slot];
    const by = try one(work);
    try wait(work, &.{ by, from }, 0);
    const to = try take(work, slot);
    work.slot_half[slot] = .none;
    // The pair's register goes back once neither float is in it any
    // more. While the other half is still packed it is that float's, and
    // `release` gives it back through it.
    const mate = work.slot_pair[slot];
    if (mate == none or work.slot_half[mate] == .none) {
        if (held(from)) |k| work.taken[k] = false;
    }
    try act(work, .{ .half = .{ .to = to, .from = from, .high = half == .high, .by = by } });
    return to;
}

/// The register holding a 1, taken the first time a texel's half has to
/// be read as a float of its own. It is a uniform like any other float
/// the program holds, and it is never given back: a program that unpacks
/// one half usually unpacks the rest.
fn one(work: *Work) Error!qpu.Rf {
    if (work.one) |each| return each;
    // `wantsOne` is meant to have loaded it before the splice. Past the
    // splice a uniform has never been read on this board, so a plan that
    // asks for one here is a mistake in `wantsOne`, and a refusal says
    // so where a hang would not.
    if (work.spliced) return Error.Body;
    if (work.slot_count == most_slots) return Error.Steps;
    const slot: u16 = @intCast(work.slot_count);
    work.slot_count += 1;
    work.slot_last[slot] = most_steps;
    try streamed(work, .{ .float = 1 });
    const to = try take(work, slot);
    try act(work, .{ .uniform = to });
    work.one = to;
    return to;
}

/// Whether this part of a step is the one instruction that reads half of
/// a packed pair and multiplies it in the same breath, which is what
/// `qpu.texture_color_code` does: a multiply with a texel's float on
/// exactly one side.
fn fuses(tag: Tag, a_packed: bool, b_packed: bool) bool {
    return tag == .mul and a_packed != b_packed;
}

/// Whether the program will read a texel's float as a float of its own,
/// which wants the 1 it is multiplied by. It is answered before anything
/// is emitted so the load can sit with the varyings. It may say yes
/// where the plan then finds a fusion for every read - a uniform read
/// and not used costs one instruction, and reading one past the splice
/// costs what nobody here knows.
fn wantsOne(work: *const Work) bool {
    if (work.sample_count == 0) return false;
    for (work.steps[0..work.step_count]) |each| {
        if (each.tag != .add and each.tag != .mul) continue;
        var part: u32 = 0;
        while (part < each.kind.parts()) : (part += 1) {
            const a = work.slot_texel[work.slot_of[each.a][part]];
            const b_part = if (work.steps[each.b].kind == .f32x1) 0 else part;
            const b = work.slot_texel[work.slot_of[each.b][b_part]];
            if ((a or b) and !fuses(each.tag, a, b)) return true;
        }
    }
    // The texel drawn as it is goes to the tile buffer packed, which is
    // the form it came in.
    if (work.steps[work.stored].tag == .sample) return false;
    for (work.slot_of[work.stored][0..4]) |slot| if (work.slot_texel[slot]) return true;
    return false;
}

/// Which input carries varying `which`.
fn ownerOf(work: *const Work, which: u32) ?u16 {
    for (work.inputs[0..work.input_count], 0..) |each, k| {
        if (which >= each.first and which < each.first + each.kind.parts()) return @intCast(k);
    }
    return null;
}

/// Each step's floats named, and what reads each of them last. A
/// `component` and a `construct` name floats of other steps rather than
/// making any: they are where a step's floats come from, not copies of
/// them.
fn live(work: *Work) Error!void {
    for (work.steps[0..work.step_count], 0..) |each, at| {
        switch (each.tag) {
            .component => {
                work.slot_of[at][0] = work.slot_of[each.a][each.at];
            },
            .construct => {
                var part: u32 = 0;
                while (part < each.kind.parts()) : (part += 1) {
                    work.slot_of[at][part] = work.slot_of[each.from[part]][each.part[part]];
                }
            },
            else => {
                var part: u32 = 0;
                while (part < each.kind.parts()) : (part += 1) {
                    if (work.slot_count == most_slots) return Error.Steps;
                    work.slot_of[at][part] = @intCast(work.slot_count);
                    work.slot_last[work.slot_count] = @intCast(at);
                    work.slot_count += 1;
                }
            },
        }
    }
    // What each float is read by last. Only a step that computes reads:
    // for the others their floats *are* their operands', and whoever
    // reads them reads those.
    for (work.steps[0..work.step_count], 0..) |each, at| {
        switch (each.tag) {
            .add, .mul => {
                for ([2]u16{ each.a, each.b }) |of| {
                    var part: u32 = 0;
                    while (part < work.steps[of].kind.parts()) : (part += 1) {
                        const slot = work.slot_of[of][part];
                        work.slot_last[slot] = @max(work.slot_last[slot], @as(u32, @intCast(at)));
                    }
                }
            },
            // A sample reads its coordinate and nothing else.
            .sample => {
                var part: u32 = 0;
                while (part < work.steps[each.a].kind.parts()) : (part += 1) {
                    const slot = work.slot_of[each.a][part];
                    work.slot_last[slot] = @max(work.slot_last[slot], @as(u32, @intCast(at)));
                }
            },
            else => {},
        }
    }
    // The colour out is read after every step there is. This comes
    // before the pairing below, not after it: the colour may name one
    // float of a texel's word and not the other, and the pair then has
    // to carry the bump across.
    var part: u32 = 0;
    while (part < 4) : (part += 1) {
        const slot = work.slot_of[work.stored][part];
        work.slot_last[slot] = most_steps;
    }
    // A texel's four floats are two registers, a pair of half-floats
    // each. The two that share a register have to die together, or
    // giving one back would take the other's with it.
    for (work.steps[0..work.step_count], 0..) |each, at| {
        if (each.tag != .sample) continue;
        for (work.slot_of[at][0..4]) |slot| work.slot_texel[slot] = true;
        for ([2][2]u8{ .{ 0, 1 }, .{ 2, 3 } }) |pair| {
            const one_slot = work.slot_of[at][pair[0]];
            const other = work.slot_of[at][pair[1]];
            const last = @max(work.slot_last[one_slot], work.slot_last[other]);
            work.slot_last[one_slot] = last;
            work.slot_last[other] = last;
        }
    }
}

/// A register for `slot`, the lowest free one.
fn take(work: *Work, slot: u32) Error!qpu.Rf {
    for (&work.taken, 0..) |*each, k| {
        if (each.*) continue;
        each.* = true;
        work.slot_reg[slot] = @intCast(qpu.rf_first + k);
        work.high_water = @max(work.high_water, @as(u32, @intCast(k + 1)));
        return work.slot_reg[slot];
    }
    return Error.Registers;
}

/// Where this float of step `at` is written. A QPU instruction reads
/// before it writes (`qpu.zig`'s `fmulLow(6, 10, 6)`), so a float that
/// this very instruction reads for the last time may be written over -
/// but only one it reads for *this* part. A scalar read by all four parts
/// of a vector is read again by the parts that follow, and writing over
/// it would hand them what this part computed.
fn destination(work: *Work, each: Step, at: u16, part: u32, a_slot: u16, b_slot: u16) Error!qpu.Rf {
    const slot = work.slot_of[at][part];
    const wide = each.kind.parts();
    // A texel's register is never written over: it holds two floats, and
    // the other one may still be wanted.
    if (work.slot_half[a_slot] == .none and work.steps[each.a].kind.parts() == wide and
        dying(work, a_slot, at) and !readLater(work, each, part, a_slot)) return again(work, a_slot, slot);
    if (work.slot_half[b_slot] == .none and work.steps[each.b].kind.parts() == wide and
        dying(work, b_slot, at) and !readLater(work, each, part, b_slot)) return again(work, b_slot, slot);
    return take(work, slot);
}

/// Whether a part of this step past `part` reads `slot` too.
///
/// `kind.parts()` catches the one float of `OpVectorTimesScalar` read by
/// all four of a vector, but it is not the only way a slot is read
/// twice: `OpCompositeConstruct` names a float per part, and `vec4(l)`
/// names the same one four times. Writing this part's product over it
/// would hand the parts that follow what this part computed, which is
/// what `glslc` makes of `vec4(l) * colour`.
fn readLater(work: *const Work, each: Step, part: u32, slot: u16) bool {
    var k: u32 = part + 1;
    while (k < each.kind.parts()) : (k += 1) {
        if (work.slot_of[each.a][k] == slot) return true;
        const b_part = if (work.steps[each.b].kind == .f32x1) 0 else k;
        if (work.slot_of[each.b][b_part] == slot) return true;
    }
    return false;
}

/// Whether nothing past `at` reads `slot`, and its register is still out.
fn dying(work: *const Work, slot: u16, at: u16) bool {
    return !work.slot_back[slot] and work.slot_last[slot] <= at;
}

/// `was`'s register given to `slot`: the one is written as the other is
/// read, in the one instruction.
fn again(work: *Work, was: u16, slot: u32) qpu.Rf {
    work.slot_back[was] = true;
    work.slot_reg[slot] = work.slot_reg[was];
    return work.slot_reg[slot];
}

/// The registers of every float nothing reads past `at` given back, after
/// the step that read them last has had its own.
fn release(work: *Work, at: u16) void {
    var slot: u32 = 0;
    while (slot < work.slot_count) : (slot += 1) {
        if (work.slot_back[slot] or work.slot_last[slot] > at) continue;
        work.slot_back[slot] = true;
        const reg = work.slot_reg[slot];
        if (reg < qpu.rf_first or reg >= qpu.rf_last) continue;
        work.taken[reg - qpu.rf_first] = false;
    }
}

fn act(work: *Work, made: Act) Error!void {
    if (work.act_count == most_acts) return Error.TooLong;
    work.acts[work.act_count] = made;
    work.act_count += 1;
    // When each register it wrote may be read. A value an instruction
    // computed is there for the next one; a value a signal brings has a
    // latency, and `wait` is what pays it.
    switch (made) {
        .uniform => |to| if (held(to)) |k| {
            work.ready[k] = work.at_word + uniform_latency;
        },
        .texel => |to| if (held(to)) |k| {
            work.ready[k] = work.at_word + texel_latency;
        },
        .varying => |to| if (held(to)) |k| {
            work.ready[k] = 0;
        },
        .fadd, .fmul => |three| if (held(three.to)) |k| {
            work.ready[k] = 0;
        },
        .half => |it| if (held(it.to)) |k| {
            work.ready[k] = 0;
        },
        .last_section => work.spliced = true,
        .color, .color_packed, .tmu, .config, .end, .nop => {},
    }
    work.at_word += made.words();
}

/// Nops enough that every register in `from` may be read `after`
/// instructions past the ones planned so far. There is no scheduler
/// here: where a value is not ready, the program waits.
fn wait(work: *Work, from: []const qpu.Rf, after: u32) Error!void {
    var most: u32 = 0;
    for (from) |reg| {
        const k = held(reg) orelse continue;
        const at = work.at_word + after;
        if (at < work.ready[k]) most = @max(most, work.ready[k] - at);
    }
    var k: u32 = 0;
    while (k < most) : (k += 1) try act(work, .nop);
}

/// Which of the program's own registers `reg` is, or null where it is the
/// hardware's or the scratch every varying read passes through.
fn held(reg: qpu.Rf) ?u32 {
    if (reg < qpu.rf_first or reg >= qpu.rf_last) return null;
    return reg - qpu.rf_first;
}

// --- level 3: the words ------------------------------------------------------

/// The plan encoded, one call an instruction. The destinations are checked
/// again here rather than trusted: a register at or past `qpu.registers`
/// is another thread's, and the renderer hangs rather than says so.
fn encode(work: *Work) Error!void {
    var used: u32 = 0;
    for (work.acts[0..work.act_count]) |each| {
        if (used + each.words() > most_words) return Error.TooLong;
        switch (each) {
            .varying => |to| {
                try thread(to);
                for (qpu.varying(to)) |word| {
                    work.code[used] = word;
                    used += 1;
                }
            },
            .uniform => |to| {
                try thread(to);
                work.code[used] = qpu.ldunifrf(to);
                used += 1;
            },
            .fadd => |three| {
                try thread(three.to);
                work.code[used] = qpu.fadd(three.to, three.a, three.b);
                used += 1;
            },
            .fmul => |three| {
                try thread(three.to);
                work.code[used] = qpu.fmul(three.to, three.a, three.b);
                used += 1;
            },
            .last_section => {
                for (qpu.last_section) |word| {
                    work.code[used] = word;
                    used += 1;
                }
            },
            .color => |pair| {
                try thread(pair.low);
                try thread(pair.high);
                work.code[used] = qpu.vfpackMagic(qpu.WADDR_TLB, pair.low, pair.high);
                used += 1;
            },
            .tmu => |it| {
                try thread(it.from);
                work.code[used] = qpu.movMagic(it.which.waddr(), it.from);
                used += 1;
            },
            .config => {
                work.code[used] = qpu.wrtmuc;
                used += 1;
            },
            .texel => |to| {
                try thread(to);
                work.code[used] = qpu.ldtmu(to);
                used += 1;
            },
            .half => |it| {
                try thread(it.to);
                try thread(it.from);
                try thread(it.by);
                work.code[used] = if (it.high) qpu.fmulHigh(it.to, it.from, it.by) else qpu.fmulLow(it.to, it.from, it.by);
                used += 1;
            },
            .color_packed => |from| {
                try thread(from);
                work.code[used] = qpu.movMagic(qpu.WADDR_TLB, from);
                used += 1;
            },
            .end => {
                for (qpu.end_of_program) |word| {
                    work.code[used] = word;
                    used += 1;
                }
            },
            .nop => {
                work.code[used] = qpu.nop;
                used += 1;
            },
        }
    }
    work.word_count = used;
}

/// Whether a register is one of the thread's own at all. rf14 and rf15
/// are, and a varying read writes them, which is why the plan keeps
/// values out of them and this only catches what no thread has.
fn thread(to: qpu.Rf) Error!void {
    if (to >= qpu.registers) return Error.Registers;
}

// --- the tests ---------------------------------------------------------------

const ir = sdk.facet.ir;
const testing = std.testing;

/// The colour the vertices carry: the one form the V3D already has a
/// hand-written program for, so the generated one is held to it word for
/// word.
/// A module glslc produced, so that a real toolchain's words are held
/// against this back end rather than only facet's own emitter's. It is a
/// file of this module's own because `tests/spirv_reference.zig` is above
/// this module's root and Zig will not import across that.
const reference = @import("glslc_reference.zig");

const Smooth = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.input(0, .f32x4));
    }
});

/// A colour of its own, which the draw hands over as four uniforms.
const Plain = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.constant(.{ 1, 0.5, 0, 1 }));
    }
});

/// A texture sampled at the coordinate the vertices carry, drawn as it
/// comes: `qpu.texture_code`'s shape.
const Textured = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.sample(0, 0, b.input(0, .f32x2)));
    }
});

/// That texel times the colour the vertices carry beside it, which is
/// what `qpu.texture_color_code` does.
const Modulated = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.mul(b.sample(0, 0, b.input(0, .f32x2)), b.input(1, .f32x4)));
    }
});

/// A texel with something added to it. No hand-written program adds to
/// one, so each of its floats has to be read out of the pair it came in
/// before the add can have it.
const Tinted = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.add(b.sample(0, 0, b.input(0, .f32x2)), b.constant(.{ 0.1, 0.2, 0.3, 0 })));
    }
});

/// Two textures at once: there is one TMU, and every hand-written
/// program writes it once and reads it once.
const Twice = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const uv = b.input(0, .f32x2);
        b.color(b.mul(b.sample(0, 0, uv), b.sample(0, 1, uv)));
    }
});

/// A pixel dropped where the texel's alpha is under a half: the plan
/// refuses it, and Mesa's back end compiles it (since 1.139).
const Cutout = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const taken = b.sample(0, 0, b.input(0, .f32x2));
        b.discardIf(b.lessThan(b.component(taken, 3), b.scalar(0.5)));
        b.color(taken);
    }
});

/// The texel a constant offset away, which the cores read (item 28, since
/// 1.87) and this device refuses: `Error.Operands`.
const Offset = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.sampleOffset(0, 0, b.input(0, .f32x2), .{ 1, -2 }));
    }
});

/// A depth compared with the reference the vertices carry, (1, 0, 0, 1)
/// times what passed: `glslc_shadow`'s shader, and `min_shadow`'s
/// (since 1.143).
const Shadowed = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.scale(b.constant(.{ 1, 0, 0, 1 }), b.sampleCompared(0, 0, b.input(0, .f32x2), b.input(1, .f32x1))));
    }
});

/// The colour the vertices carry, dimmed by a float they carry beside it:
/// a vector times a scalar, where the scalar is read again by every part
/// and so may not be written over.
const Dimmed = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const colour = b.input(0, .f32x4);
        const light = b.input(1, .f32x1);
        b.color(b.scale(colour, light));
    }
});

/// Two colours multiplied and a constant added: eight varyings and four
/// floats of its own, which only fit because a dying value's register is
/// written over and a uniform is read where it is wanted.
const Lit = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const made = b.mul(b.input(0, .f32x4), b.input(1, .f32x4));
        b.color(b.add(made, b.constant(.{ 0.1, 0.2, 0.3, 0 })));
    }
});

/// Twelve varyings, which is more than this device holds: ten usable
/// registers take eight of them and the four floats a program needs of
/// its own. The cores carry sixty-four since 1.90 and the QPUs carry
/// eight, so this is a graph the one device draws and the other refuses -
/// and the first graph of its kind that could be *written*, because
/// `ir.zig` refused more than eight varyings at comptime until then and
/// `Error.Varyings` therefore had no test at all. Item 17 of
/// docs/facet-vulkan10.md.
const Wide = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const first = b.input(0, .f32x4);
        const second = b.input(1, .f32x4);
        const third = b.input(2, .f32x4);
        b.color(b.add(b.mul(first, second), third));
    }
});

/// A colour from location 0, with a varying declared after it and never
/// read: the draw still carries it, so the program still takes it.
const Spare = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const colour = b.input(0, .f32x4);
        _ = b.input(1, .f32x2);
        b.color(colour);
    }
});

/// The same the other way round: a varying declared first and never read,
/// which has to be taken before the one that is.
const Later = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        _ = b.input(0, .f32x2);
        b.color(b.input(1, .f32x4));
    }
});

/// `words` with its entry point's stage made vertex, which this back end
/// has no program for.
fn asVertex(comptime words: []const u32) [words.len]u32 {
    comptime {
        var copy: [words.len]u32 = words[0..words.len].*;
        var at: usize = 5;
        while (at < copy.len) {
            const count = copy[at] >> 16;
            if (count == 0) @compileError("a word count of zero");
            if (copy[at] & 0xFFFF == @intFromEnum(spirv.Op.entry_point)) {
                copy[at + 1] = @intFromEnum(spirv.ExecutionModel.vertex);
                return copy;
            }
            at += count;
        }
        @compileError("no OpEntryPoint to change");
    }
}

const vertex_words = asVertex(Smooth.words);

/// `words` with the `at`th instruction of `op` patched: its operand
/// `which` becomes `value`. The word count is left alone, so the caller
/// picks an operand whose form is the same.
fn patched(comptime words: []const u32, comptime op: spirv.Op, comptime at: u32, comptime which: u32, comptime value: u32) [words.len]u32 {
    comptime {
        var copy: [words.len]u32 = words[0..words.len].*;
        var seen: u32 = 0;
        var k: usize = 5;
        while (k < copy.len) {
            const count = copy[k] >> 16;
            if (count == 0) @compileError("a word count of zero");
            if (copy[k] & 0xFFFF == @intFromEnum(op)) {
                if (seen == at) {
                    if (which + 1 >= count) @compileError("that instruction has no such operand");
                    copy[k + 1 + which] = value;
                    return copy;
                }
                seen += 1;
            }
            k += count;
        }
        @compileError("no such instruction to patch");
    }
}

/// The colour drawn with the origin at the bottom left, which would come
/// out upside down if the mode were taken and dropped.
const flipped_words = patched(Smooth.words, .execution_mode, 0, 1, @intFromEnum(spirv.ExecutionMode.origin_lower_left));
/// The varying decorated `Flat`, which `qpu.varying` does not interpolate:
/// the second OpDecorate is the input's. The stray literal of a Location
/// is left where it was, and the decoration is read before anything would
/// look at it.
const flat_words = patched(Smooth.words, .decorate, 1, 1, @intFromEnum(spirv.Decoration.flat));
/// The varying made a built-in, which a fragment program of facet's own
/// has none of.
const built_in_words = patched(Smooth.words, .decorate, 1, 1, @intFromEnum(spirv.Decoration.built_in));
/// A function that is not the one the entry point names.
const other_function_words = patched(Smooth.words, .function, 0, 1, 5);

/// Every rule the hardware does not forgive, read off a compiled program:
/// the registers on both sides and in the signals, one wait on the
/// scoreboard, nothing at the tile buffer before it, and the thread
/// switch and its two delay slots at the end.
fn sound(work: *const Work, code: Code) !void {
    var waits: u32 = 0;
    var first_wait: usize = code.words.len;
    for (code.words, 0..) |instruction, at| {
        for (qpu.destinations(instruction)) |side| if (side) |to| try testing.expect(to < qpu.registers);
        if (qpu.signalled(instruction)) |to| try testing.expect(to < qpu.registers);
        if (instruction == qpu.thrsw and at + 1 < code.words.len and code.words[at + 1] == qpu.thrsw) {
            waits += 1;
            first_wait = @min(first_wait, at);
        }
    }
    try testing.expectEqual(@as(u32, 1), waits);
    const end = code.words[code.words.len - 3 ..];
    try testing.expectEqualSlices(u64, &qpu.end_of_program, end);
    // And in the plan: one `last_section`, with every colour after it
    // and every write to the TMU before it.
    var waited = false;
    var colors: u32 = 0;
    var configs: u32 = 0;
    var texels: u32 = 0;
    var started: ?u32 = null;
    var came_back: ?u32 = null;
    var word: u32 = 0;
    // Which registers hold a word the TMU handed back, as two packed
    // half-floats. Only `fmulLow`/`fmulHigh` and a move to the tile
    // buffer read one as that, so both are held to a register that still
    // is one: `plain` reads a half out into a register of its own and
    // points the slot at that, and once both halves are out the word's
    // register goes back to the pool - so a plan that then moves the
    // slot's register out as a pair would send a single f32, or whatever
    // the pool handed out next, to the tile buffer.
    var packed_word: [qpu.registers]bool = @splat(false);
    // The stream and the loads that pop it, walked together. The draw
    // fills the words by tag and position and the program pops by
    // position, so the pairing is the whole contract of the stream: a
    // load without its word, or a word without its load, shifts every
    // later word and the TMU would be configured from a colour.
    const stream = code.stream();
    var popped: u32 = 0;
    for (work.plan()) |each| {
        // Whatever this writes is no longer a word from the TMU.
        switch (each) {
            .varying, .uniform => |to| if (to >= qpu.rf_first and to < qpu.rf_last) {
                packed_word[to - qpu.rf_first] = false;
            },
            .fadd, .fmul => |three| packed_word[three.to - qpu.rf_first] = false,
            .half => |it| packed_word[it.to - qpu.rf_first] = false,
            else => {},
        }
        switch (each) {
            .last_section => {
                try testing.expect(!waited);
                waited = true;
            },
            .color => |pair| {
                try testing.expect(waited);
                try testing.expect(pair.low < qpu.registers and pair.high < qpu.registers);
                colors += 1;
            },
            .color_packed => |from| {
                try testing.expect(waited);
                try testing.expect(from >= qpu.rf_first and from < qpu.rf_last);
                try testing.expect(packed_word[from - qpu.rf_first]);
                colors += 1;
            },
            .varying => |to| try testing.expect(to >= qpu.rf_first and to < qpu.rf_last or to == qpu.rf_scaled),
            .uniform => |to| {
                try testing.expect(to >= qpu.rf_first and to < qpu.rf_last);
                // Every uniform is read before the splice, whether the
                // program samples or not. No hand-written program reads
                // the stream in the last thread section, so nothing here
                // emits that shape.
                try testing.expect(!waited);
                try testing.expect(popped < stream.len);
                try testing.expect(stream[popped] == .float);
                popped += 1;
            },
            .fadd, .fmul => |three| try testing.expect(three.to >= qpu.rf_first and three.to < qpu.rf_last),
            // The coordinate reaches the TMU before the splice, and the
            // write to S is the last thing before it: that write starts
            // the lookup and the splice is the wait for it.
            .tmu => |it| {
                try testing.expect(!waited);
                try testing.expect(it.from >= qpu.rf_first and it.from < qpu.rf_last);
                if (it.which == .s) started = word;
            },
            .config => {
                try testing.expect(!waited);
                try testing.expect(popped < stream.len);
                // The texture's state first, then the sampler's, which
                // is the order the two `wrtmuc` are issued in.
                if (configs == 0) {
                    try testing.expect(stream[popped] == .texture);
                } else {
                    try testing.expect(stream[popped] == .sampler);
                }
                popped += 1;
                configs += 1;
            },
            .texel => |to| {
                try testing.expect(waited);
                try testing.expect(to >= qpu.rf_first and to < qpu.rf_last);
                packed_word[to - qpu.rf_first] = true;
                if (came_back == null) came_back = word;
                texels += 1;
            },
            .half => |it| {
                try testing.expect(it.to >= qpu.rf_first and it.to < qpu.rf_last and
                    it.from >= qpu.rf_first and it.from < qpu.rf_last and
                    it.by >= qpu.rf_first and it.by < qpu.rf_last);
                try testing.expect(packed_word[it.from - qpu.rf_first]);
            },
            .end, .nop => {},
        }
        word += each.words();
    }
    try testing.expect(waited);
    try testing.expectEqual(@as(u32, 2), colors);
    // A sample is one write to S, two configuration parameters and two
    // words back, the first of them five instructions after the write -
    // four of which are the splice, as `qpu.texture_code` leaves it.
    if (code.sampler == null) {
        try testing.expectEqual(@as(u32, 0), configs);
        try testing.expectEqual(@as(u32, 0), texels);
        try testing.expectEqual(@as(?u32, null), started);
    } else {
        try testing.expectEqual(@as(u32, 2), configs);
        try testing.expectEqual(@as(u32, 2), texels);
        try testing.expectEqual(@as(u32, 5), came_back.? - started.?);
    }
    // Every word of the stream was popped by something, and nothing
    // popped past the end. With the walk above, that is the pairing in
    // both directions.
    try testing.expectEqual(stream.len, popped);
    var configured: u32 = 0;
    for (stream) |each| if (each != .float) {
        configured += 1;
    };
    try testing.expectEqual(configs, configured);
    // One `ldvary` for each varying the record declares, as every
    // hand-written program has: what the hardware makes of a program that
    // reads fewer is written down nowhere.
    var taken: u32 = 0;
    for (work.plan()) |each| if (each == .varying) {
        taken += 1;
    };
    try testing.expectEqual(code.varyings, taken);
    // The words are the plan and nothing else.
    var counted: u32 = 0;
    for (work.plan()) |each| counted += each.words();
    try testing.expectEqual(@as(usize, counted), code.words.len);
    // And every word keeps the rules Mesa holds a finished program to
    // (compiler/validate.zig, its qpu_validate.c), as a fragment program
    // with its last thread section.
    var insts: [most_words]qpu_instr.Instr = undefined;
    for (code.words, insts[0..code.words.len]) |instruction, *inst| inst.* = qpu_pack.unpack(instruction).?;
    if (validator.validate(.{ .insts = insts[0..code.words.len], .last_thrsw = true })) |failure| {
        std.debug.print("broken at {d}: {s}\n", .{ failure.ip, failure.message });
        return error.TestUnexpectedResult;
    }
}

const qpu_instr = @import("qpu/instr.zig");
const qpu_pack = @import("qpu/pack.zig");
const validator = @import("compiler/validate.zig");

test "the interpolated colour comes to the program that was written by hand, word for word" {
    var work: Work = .{};
    const code = try compile(&work, Smooth.words);
    try testing.expectEqualSlices(u64, qpu.color_fragment.code, code.words);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    try testing.expectEqual(qpu.color_fragment.varyings, code.varyings);
    try testing.expectEqual(@as(usize, 0), code.stream().len);
    try testing.expectEqual(@as(u32, 4), code.registers);
    try sound(&work, code);

    // The plan: a varying into each of rf4 to rf7, the wait, the two
    // packs to the tile buffer, the end.
    try testing.expectEqualSlices(Act, &[_]Act{
        .{ .varying = 4 },
        .{ .varying = 5 },
        .{ .varying = 6 },
        .{ .varying = 7 },
        .last_section,
        .{ .color = .{ .low = 4, .high = 5 } },
        .{ .color = .{ .low = 6, .high = 7 } },
        .end,
    }, work.plan());
}

test "glslc's own module for the interpolated colour comes to the hand-written program, word for word" {
    // The same shader as `Smooth`, compiled by glslc instead of emitted by
    // `ir.Build`: 111 words against the 72 of the minimal form, the extra
    // ones being an unused `OpExtInstImport "GLSL.std.450"`, the debug
    // names and source strings, and a `Function` variable the colour goes
    // through. Every one of those was refused before 1.81 - the import at
    // the module's sixth word - so no module any real toolchain produces
    // ever reached this compiler. What it must come to is not merely
    // "something": it is `qpu.color_fragment`, the program written by hand
    // and drawn on the board, which the test above holds `Smooth` to.
    // Both gates take it. `facet_profile` is what CreateShaderModule reads
    // a module against and `profile` is this device's; the import at word
    // six was refused by each of them before 1.81, so the words never got
    // as far as being compiled badly - they got no further than the gate.
    try testing.expect(spirv.look(&reference.glslc_interp, spirv.facet_profile) == .seen);
    try testing.expect(spirv.look(&reference.glslc_interp, profile) == .seen);

    var work: Work = .{};
    const code = try compile(&work, &reference.glslc_interp);
    try testing.expectEqualSlices(u64, qpu.color_fragment.code, code.words);
    try testing.expectEqual(qpu.color_fragment.varyings, code.varyings);
    try testing.expectEqual(@as(usize, 0), code.stream().len);
    try sound(&work, code);

    // And the plan is the same plan, so the extra words cost nothing: they
    // are read and dropped rather than planned around.
    try testing.expectEqualSlices(Act, &[_]Act{
        .{ .varying = 4 },
        .{ .varying = 5 },
        .{ .varying = 6 },
        .{ .varying = 7 },
        .last_section,
        .{ .color = .{ .low = 4, .high = 5 } },
        .{ .color = .{ .low = 6, .high = 7 } },
        .end,
    }, work.plan());
}

test "a colour of its own reads four uniforms and no varyings" {
    var work: Work = .{};
    const code = try compile(&work, Plain.words);
    try testing.expectEqual(@as(u32, 0), code.varyings);
    try testing.expectEqualSlices(Word, &[_]Word{
        .{ .float = 1 }, .{ .float = 0.5 }, .{ .float = 0 }, .{ .float = 1 },
    }, code.stream());
    try testing.expectEqual(@as(u32, 4), code.registers);
    try sound(&work, code);
    try testing.expectEqualSlices(Act, &[_]Act{
        .{ .uniform = 4 },
        .{ .uniform = 5 },
        .{ .uniform = 6 },
        .{ .uniform = 7 },
        // rf7 was loaded five instructions before the splice and the
        // writes that follow it, and six is the only distance the board
        // has run.
        .nop,
        .last_section,
        .{ .color = .{ .low = 4, .high = 5 } },
        .{ .color = .{ .low = 6, .high = 7 } },
        .end,
    }, work.plan());
}

test "a vector times a scalar: the scalar is read by every part and is not written over" {
    var work: Work = .{};
    const code = try compile(&work, Dimmed.words);
    try testing.expectEqual(@as(u32, 5), code.varyings);
    try sound(&work, code);
    // rf4 to rf7 the colour, rf8 the light; the product is written over
    // the colour, which dies at the multiply, while rf8 is left alone.
    try testing.expectEqualSlices(Act, &[_]Act{
        .{ .varying = 4 },
        .{ .varying = 5 },
        .{ .varying = 6 },
        .{ .varying = 7 },
        .{ .varying = 8 },
        .{ .fmul = .{ .to = 4, .a = 4, .b = 8 } },
        .{ .fmul = .{ .to = 5, .a = 5, .b = 8 } },
        .{ .fmul = .{ .to = 6, .a = 6, .b = 8 } },
        .{ .fmul = .{ .to = 7, .a = 7, .b = 8 } },
        .last_section,
        .{ .color = .{ .low = 4, .high = 5 } },
        .{ .color = .{ .low = 6, .high = 7 } },
        .end,
    }, work.plan());
}

test "more varyings than the registers hold: refused, and refused as varyings" {
    // Twelve against this device's eight. Before 1.90 this test could not
    // be written: `ir.zig` would not build the graph, so the one refusal
    // in this file that nothing reached was the one for the thing the
    // hardware most plainly cannot do.
    try testing.expectEqual(@as(u32, 12), Wide.varyings);
    try testing.expect(Wide.varyings > most_varyings);
    var work: Work = .{};
    try testing.expectError(Error.Varyings, compile(&work, Wide.words));
    // The widest that does fit still compiles, so this is the ceiling and
    // not a refusal of anything broad. `Lit` carries exactly eight.
    var fits: Work = .{};
    const code = try compile(&fits, Lit.words);
    try testing.expectEqual(@as(u32, most_varyings), code.varyings);
    // And the module is a module: it is the device that refuses it, not
    // the words that are wrong, which is the distinction the two tiers of
    // `spirv.look` are for.
    switch (spirv.look(Wide.words, profile)) {
        .seen => {},
        .fault => |fault| {
            std.debug.print("the wide graph is not a module: {t}\n", .{fault});
            return error.TestUnexpectedResult;
        },
    }
}

test "eight varyings and four floats of its own fit the ten registers there are" {
    var work: Work = .{};
    const code = try compile(&work, Lit.words);
    try testing.expectEqual(@as(u32, 8), code.varyings);
    try testing.expectEqualSlices(Word, &[_]Word{
        .{ .float = 0.1 }, .{ .float = 0.2 }, .{ .float = 0.3 }, .{ .float = 0 },
    }, code.stream());
    // Eight, which is what `Lit`'s plan above comes to. Not
    // `<= registers`: `compile` cannot answer with more than there are -
    // `take` refuses past the tenth - so that would hold for every input
    // including one that overflowed and was turned down.
    try testing.expectEqual(@as(u32, 8), code.registers);
    try sound(&work, code);
    // The eight varyings, the product over the first four, the uniforms
    // in the four the second colour left, and the sum over the product.
    try testing.expectEqualSlices(Act, &[_]Act{
        .{ .varying = 4 },
        .{ .varying = 5 },
        .{ .varying = 6 },
        .{ .varying = 7 },
        .{ .varying = 8 },
        .{ .varying = 9 },
        .{ .varying = 10 },
        .{ .varying = 11 },
        .{ .fmul = .{ .to = 4, .a = 4, .b = 8 } },
        .{ .fmul = .{ .to = 5, .a = 5, .b = 9 } },
        .{ .fmul = .{ .to = 6, .a = 6, .b = 10 } },
        .{ .fmul = .{ .to = 7, .a = 7, .b = 11 } },
        .{ .uniform = 8 },
        .{ .uniform = 9 },
        .{ .uniform = 10 },
        .{ .uniform = 11 },
        // rf8 was loaded four instructions ago, and the sum that reads it
        // waits the other two out.
        .nop,
        .nop,
        .{ .fadd = .{ .to = 4, .a = 4, .b = 8 } },
        .{ .fadd = .{ .to = 5, .a = 5, .b = 9 } },
        .{ .fadd = .{ .to = 6, .a = 6, .b = 10 } },
        .{ .fadd = .{ .to = 7, .a = 7, .b = 11 } },
        .last_section,
        .{ .color = .{ .low = 4, .high = 5 } },
        .{ .color = .{ .low = 6, .high = 7 } },
        .end,
    }, work.plan());
}

test "a varying declared and never read is taken all the same, before and after the one that is" {
    var work: Work = .{};
    const spare = try compile(&work, Spare.words);
    try testing.expectEqual(@as(u32, 6), spare.varyings);
    try sound(&work, spare);
    try testing.expectEqualSlices(Act, &[_]Act{
        .{ .varying = 4 },
        .{ .varying = 5 },
        .{ .varying = 6 },
        .{ .varying = 7 },
        .{ .varying = qpu.rf_scaled },
        .{ .varying = qpu.rf_scaled },
        .last_section,
        .{ .color = .{ .low = 4, .high = 5 } },
        .{ .color = .{ .low = 6, .high = 7 } },
        .end,
    }, work.plan());

    var other: Work = .{};
    const later = try compile(&other, Later.words);
    try testing.expectEqual(@as(u32, 6), later.varyings);
    try sound(&other, later);
    try testing.expectEqualSlices(Act, &[_]Act{
        .{ .varying = qpu.rf_scaled },
        .{ .varying = qpu.rf_scaled },
        .{ .varying = 4 },
        .{ .varying = 5 },
        .{ .varying = 6 },
        .{ .varying = 7 },
        .last_section,
        .{ .color = .{ .low = 4, .high = 5 } },
        .{ .color = .{ .low = 6, .high = 7 } },
        .end,
    }, other.plan());
}

test "what would draw the wrong pixels is refused and not taken and dropped" {
    var work: Work = .{};
    // The origin at the bottom left: the same words otherwise, and a
    // picture upside down.
    try testing.expectError(Error.Refused, compile(&work, &flipped_words));
    // A varying that is not interpolated the way `qpu.varying` does.
    try testing.expectError(Error.Refused, compile(&work, &flat_words));
    try testing.expectError(Error.Refused, compile(&work, &built_in_words));
    // A function that is not the one the entry point names: `look` counts
    // the functions but does not say which is which.
    try testing.expectError(Error.Body, compile(&work, &other_function_words));
    // And the module as it is, so that the patches are what was refused.
    _ = try compile(&work, Smooth.words);
}

test "a texture sampled at a varying is the hand-written program, with the texel where this takes it" {
    var work: Work = .{};
    const code = try compile(&work, Textured.words);
    try testing.expectEqual(@as(u32, 2), code.varyings);
    try testing.expectEqual(Sampler{ .set = 0, .binding = 0 }, code.sampler.?);
    try sound(&work, code);
    // `qpu.texture_code` instruction for instruction, with the two words
    // the TMU hands back in rf6 and rf7 rather than its rf10 and rf11:
    // that program is spliced from a shared `sample_end` whose registers
    // are fixed, and this takes the lowest two free once the coordinate
    // has been written and let go.
    const want = qpu.varying(4) ++ qpu.varying(5) ++ [_]u64{
        qpu.movMagic(qpu.WADDR_TMUT, 5),
        qpu.wrtmuc,
        qpu.wrtmuc,
        qpu.movMagic(qpu.WADDR_TMUS, 4),
    } ++ qpu.last_section ++ [_]u64{
        qpu.ldtmu(6),
        qpu.ldtmu(7),
        qpu.movMagic(qpu.WADDR_TLB, 6),
        qpu.movMagic(qpu.WADDR_TLB, 7),
    } ++ qpu.end_of_program;
    try testing.expectEqualSlices(u64, &want, code.words);
    // Nothing of its own in the stream: the two words are the TMU's, and
    // only a draw knows what they are.
    try testing.expectEqualSlices(Word, &[_]Word{ .texture, .sampler }, code.stream());
}

test "a texture times the colour the vertices carry comes to the program that was written by hand, word for word" {
    var work: Work = .{};
    const code = try compile(&work, Modulated.words);
    try testing.expectEqual(@as(u32, 6), code.varyings);
    try testing.expectEqual(qpu.texture_color_fragment.varyings, code.varyings);
    try sound(&work, code);
    // Six varyings hold rf4 to rf9, so the texel lands in rf10 and rf11
    // as it does in the hand-written program - and each product is
    // written over the colour that went into it, which dies at it.
    try testing.expectEqualSlices(u64, qpu.texture_color_fragment.code, code.words);
    try testing.expectEqualSlices(Word, &[_]Word{ .texture, .sampler }, code.stream());
}

test "a texel added to is read out of its pair first, by a 1 loaded before the splice" {
    var work: Work = .{};
    const code = try compile(&work, Tinted.words);
    try testing.expectEqual(@as(u32, 2), code.varyings);
    try sound(&work, code);
    // The 1 first, then its own floats, then the TMU's two: every float
    // is loaded in front of the splice where the program samples, so
    // they are all asked for before the write to S that configures the
    // TMU.
    try testing.expectEqualSlices(Word, &[_]Word{
        .{ .float = 1 },   .{ .float = 0.1 }, .{ .float = 0.2 },
        .{ .float = 0.3 }, .{ .float = 0 },   .texture,
        .sampler,
    }, code.stream());
    var halves: u32 = 0;
    var adds: u32 = 0;
    var before: u32 = 0;
    var spliced = false;
    for (work.plan()) |each| switch (each) {
        .half => halves += 1,
        .fadd => adds += 1,
        .last_section => spliced = true,
        .uniform => if (!spliced) {
            before += 1;
        },
        else => {},
    };
    // One read per float of the texel, and the four adds over them.
    try testing.expectEqual(@as(u32, 4), halves);
    try testing.expectEqual(@as(u32, 4), adds);
    // Every uniform is read before the splice - the 1 and the four
    // floats of its own - although the adds that want them are all past
    // it. `sound` holds every program to that; this says the number for
    // the one program the suite pins word for word.
    try testing.expectEqual(@as(u32, 5), before);
}

test "what this back end has no program for is refused by name, and nothing is mis-compiled" {
    var work: Work = .{};
    // Two textures: there is one TMU, and every hand-written program
    // writes it once and reads it once.
    try testing.expectError(Error.Samplers, compile(&work, Twice.words));
    // A pixel dropped: no hand-written program does, so the plan says
    // which family it is.
    try testing.expectError(Error.Discards, compile(&work, Cutout.words));
    // A constant texel offset on the sample: the cores apply one, and no
    // program here writes the configuration parameter that carries it,
    // the sampler's own state being all the TMU is told. Said by
    // name, which is what tells it from a word this walk simply did not
    // know - and this is also the only test in the tree that proves the
    // operand reached the *words* at all: the cores read the offset from
    // `ir.Op`, so every test on that side would pass with the emitter
    // writing nothing.
    try testing.expectError(Error.Operands, compile(&work, Offset.words));
    // The same graph with no offset is a program this device compiles,
    // so the refusal above is the operand and not the shape.
    _ = try compile(&work, Textured.words);
    // A vertex program: the V3D runs the library's own for those.
    try testing.expectError(Error.Stage, compile(&work, &vertex_words));
    // Not a module at all, which `CreateShaderModule` turns down before
    // a driver ever sees it; refused here too rather than walked.
    try testing.expectError(Error.Refused, compile(&work, &[_]u32{ 0xDEAD_BEEF, 0, 0, 1, 0 }));
    try testing.expectError(Error.Refused, compile(&work, &[_]u32{}));
}

test "a program compiled twice from the one work is the same program" {
    var work: Work = .{};
    const first = try compile(&work, Lit.words);
    var kept: [most_words]u64 = undefined;
    @memcpy(kept[0..first.words.len], first.words);
    const length = first.words.len;
    const twice = try compile(&work, Lit.words);
    try testing.expectEqualSlices(u64, kept[0..length], twice.words);
}

// --- the shapes `ir.Build` cannot make --------------------------------------

/// A module built by hand, for the shapes the library's own builder does
/// not emit. `ir.Build` has no vector constructor, so everything here
/// that turns on `OpCompositeConstruct` - which `glslc` writes for the
/// commonest lines of GLSL there are - can only be reached this way. The
/// opcode is in `profile` and `step` implements it, so these are words
/// this back end means to take.
fn built(comptime what: struct {
    /// `vec4(uv.x, uv.y, 0.25, 1.0)`: two of the four constituents are
    /// constants, which have no step until something reads them.
    construct_constants: bool = false,
    /// The same, with each constant read by an `OpFMul` first, so the
    /// steps exist by the time the construct names them. The two have to
    /// compile alike: whether an unrelated earlier instruction happened
    /// to read a constant cannot decide whether a module is taken.
    read_first: bool = false,
    /// `vec4(l) * colour`, where `l` is one float varying named by all
    /// four parts of the construct. This is what `glslc` makes of
    /// `vec4(l) * colour`, and the product of part 0 may not be written
    /// over `l` while parts 1 to 3 still read it.
    splat_times: bool = false,
    /// `vec4(texel.r, texel.b, texel.g, l)`: the colour out names three
    /// of the texel's four floats, so one of the two words has a float
    /// nothing names - and the two that share a register have to die
    /// together or the live one's register is handed out while it is
    /// still in it. Three floats and a scalar varying, so it fits the
    /// ten registers there are where a vec4 of its own would not.
    construct_texel: bool = false,
    /// `vec4(texel.r, m.g, m.b, m.a)` with `m = colour + k`: the same,
    /// with a vec4 varying and a vec4 of its own beside the texel. Eleven
    /// floats are live at once, which is one more than there are
    /// registers, so this is refused - and has to be refused for *that*,
    /// not drawn wrongly.
    crowded_texel: bool = false,
    /// How many combined image samplers to declare. One is sampled
    /// whatever the count: the device's limit is one *sample*, and a
    /// module may declare more and sample one of them.
    samplers: u32 = 0,
    /// `OpDecorate %in Flat` with no literal, which is the only shape an
    /// emitter writes - two words of operands and not three.
    bare_flat: bool = false,
    /// A `Binding` literal of exactly 65535, which is `none`.
    sentinel_binding: bool = false,
    /// `OpKill` as the block's terminator: a shader that always drops
    /// its pixel, which is valid SPIR-V and wants the flag registers.
    always_kill: bool = false,
}) []const u32 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var emit = spirv.Emit{};
        const main_id = emit.id();
        const out_id = emit.id();
        const uv_id = emit.id();
        const wants_colour = what.splat_times or what.crowded_texel;
        // `vec4(texel.r, l, l, l)` reads a coordinate at location 0 and
        // one float at location 1.
        const wants_scalar = what.construct_texel;
        const colour_id = if (what.splat_times or what.crowded_texel or what.construct_texel) emit.id() else 0;
        var tex_ids: [most_samplers + 1]u32 = @splat(0);
        for (0..what.samplers) |k| tex_ids[k] = emit.id();

        emit.capability(.shader);
        emit.memoryModel(.logical, .glsl450);
        emit.entryPoint(.fragment, main_id, "main", &.{ out_id, uv_id });
        emit.executionMode(main_id, .origin_upper_left);
        emit.decorate(out_id, .location, &.{0});
        // `vec4(l) * colour` reads the colour at location 0 and the one
        // float at location 1; everything else reads the coordinate at 0.
        // Locations run from 0 upwards with no gap either way.
        emit.decorate(uv_id, .location, &.{if (wants_colour) 1 else 0});
        if (wants_colour) emit.decorate(colour_id, .location, &.{0});
        if (wants_scalar) emit.decorate(colour_id, .location, &.{1});
        if (what.bare_flat) emit.decorate(uv_id, .flat, &.{});
        for (0..what.samplers) |k| {
            emit.decorate(tex_ids[k], .descriptor_set, &.{0});
            emit.decorate(tex_ids[k], .binding, &.{if (what.sentinel_binding) 65535 else @as(u32, @intCast(k))});
        }

        const void_type = emit.typeVoid();
        const function_type = emit.typeFunction(void_type, &.{});
        const float_type = emit.typeFloat(32);
        const vec4 = emit.typeVector(float_type, 4);
        const vec2 = emit.typeVector(float_type, 2);
        emit.variable(emit.typePointer(.output, vec4), out_id, .output);
        // `vec4(l) * colour` wants one float in, everything else a
        // coordinate.
        const in_type = if (what.splat_times) float_type else vec2;
        emit.variable(emit.typePointer(.input, in_type), uv_id, .input);
        if (wants_colour) emit.variable(emit.typePointer(.input, vec4), colour_id, .input);
        if (wants_scalar) emit.variable(emit.typePointer(.input, float_type), colour_id, .input);
        var sampled_type: u32 = 0;
        if (what.samplers != 0) {
            const image = emit.typeImage(float_type, .dim_2d, 0, 0, 0, 1, .unknown);
            sampled_type = emit.typeSampledImage(image);
            for (0..what.samplers) |k| {
                emit.variable(emit.typePointer(.uniform_constant, sampled_type), tex_ids[k], .uniform_constant);
            }
        }
        const quarter = emit.constant(float_type, @bitCast(@as(f32, 0.25)));
        const whole = emit.constant(float_type, @bitCast(@as(f32, 1)));
        const tint = emit.constantComposite(vec4, &.{ quarter, quarter, quarter, whole });

        emit.function(void_type, main_id, function_type);
        emit.label(emit.id());
        const in_value = emit.id();
        emit.at(.load, &.{ in_type, in_value, uv_id });
        var taken: u32 = 0;
        if (what.samplers != 0) {
            const bound = emit.id();
            emit.at(.load, &.{ sampled_type, bound, tex_ids[0] });
            taken = emit.id();
            emit.at(.image_sample_implicit_lod, &.{ vec4, taken, bound, in_value });
        }
        if (what.always_kill) {
            emit.at(.kill, &.{});
            emit.functionEnd();
            return emit.finish();
        }
        if (what.construct_constants) {
            const x = emit.id();
            emit.at(.composite_extract, &.{ float_type, x, in_value, 0 });
            const y = emit.id();
            emit.at(.composite_extract, &.{ float_type, y, in_value, 1 });
            var first = quarter;
            var second = whole;
            if (what.read_first) {
                const p = emit.id();
                emit.at(.f_mul, &.{ float_type, p, x, quarter });
                const q = emit.id();
                emit.at(.f_mul, &.{ float_type, q, y, whole });
                first = p;
                second = q;
            }
            const made = emit.id();
            emit.at(.composite_construct, &.{ vec4, made, x, y, first, second });
            emit.at(.store, &.{ out_id, made });
        } else if (what.splat_times) {
            const splat = emit.id();
            emit.at(.composite_construct, &.{ vec4, splat, in_value, in_value, in_value, in_value });
            const colour = emit.id();
            emit.at(.load, &.{ vec4, colour, colour_id });
            const made = emit.id();
            emit.at(.f_mul, &.{ vec4, made, splat, colour });
            emit.at(.store, &.{ out_id, made });
        } else if (what.construct_texel) {
            const light = emit.id();
            emit.at(.load, &.{ float_type, light, colour_id });
            // Red and green are one word, blue and alpha the other. The
            // colour names red, blue and green and leaves alpha out, so
            // alpha is the float nothing reads.
            var floats: [3]u32 = undefined;
            for (&floats, [3]u32{ 0, 2, 1 }) |*each, which| {
                each.* = emit.id();
                emit.at(.composite_extract, &.{ float_type, each.*, taken, which });
            }
            const made = emit.id();
            emit.at(.composite_construct, &.{ vec4, made, floats[0], floats[1], floats[2], light });
            emit.at(.store, &.{ out_id, made });
        } else if (what.crowded_texel) {
            const colour = emit.id();
            emit.at(.load, &.{ vec4, colour, colour_id });
            const mixed = emit.id();
            emit.at(.f_add, &.{ vec4, mixed, colour, tint });
            const red = emit.id();
            emit.at(.composite_extract, &.{ float_type, red, taken, 0 });
            var rest: [3]u32 = undefined;
            for (&rest, 1..) |*each, part| {
                each.* = emit.id();
                emit.at(.composite_extract, &.{ float_type, each.*, mixed, @intCast(part) });
            }
            const made = emit.id();
            emit.at(.composite_construct, &.{ vec4, made, red, rest[0], rest[1], rest[2] });
            emit.at(.store, &.{ out_id, made });
        } else {
            emit.at(.store, &.{ out_id, taken });
        }
        emit.at(.returns, &.{});
        emit.functionEnd();
        return emit.finish();
    }
}

/// `Smooth` with the input's Location literal made the `none` sentinel,
/// and made larger than a u16 holds. Both are the module's own number
/// landing where the tables keep "never decorated".
const sentinel_location = patched(Smooth.words, .decorate, 1, 2, 65535);
const huge_location = patched(Smooth.words, .decorate, 1, 2, 0xFFFF_FFFF);

/// A texel drawn as it comes, with one of its floats also read out on its
/// own. `sound` holds every program to a `color_packed` register that
/// still holds a word from the TMU; before the guard in `settle` this
/// moved an unpacked f32 to the tile buffer as two half-floats.
const HalfRead = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const taken = b.sample(0, 0, b.input(0, .f32x2));
        _ = b.add(b.component(taken, 0), b.scalar(0.5));
        b.color(taken);
    }
});

/// The same with all four floats read out: before the guard both writes
/// to the tile buffer named registers the pool had handed out again.
const AllRead = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const taken = b.sample(0, 0, b.input(0, .f32x2));
        _ = b.add(taken, b.constant(.{ 0.1, 0.2, 0.3, 0 }));
        b.color(taken);
    }
});

test "a texel read out of its pair is packed back for the colour, not moved out raw" {
    var work: Work = .{};
    // Both of these drew the wrong colour before `settle` came to decide
    // the shortcut per pair rather than per step. `sound` is what holds
    // it now, and it runs on every program the suite compiles.
    for ([2][]const u32{ HalfRead.words, AllRead.words }) |words| {
        const code = try compile(&work, words);
        try sound(&work, code);
        // Packed back by `color`, not moved out by `color_packed`.
        var raw: u32 = 0;
        var packed_back: u32 = 0;
        for (work.plan()) |each| switch (each) {
            .color_packed => raw += 1,
            .color => packed_back += 1,
            else => {},
        };
        try testing.expectEqual(@as(u32, 0), raw);
        try testing.expectEqual(@as(u32, 2), packed_back);
    }
    // And the texel drawn with nothing read out still takes the
    // shortcut, which is the whole point of having one.
    const whole = try compile(&work, Textured.words);
    try sound(&work, whole);
    var raw: u32 = 0;
    for (work.plan()) |each| if (each == .color_packed) {
        raw += 1;
    };
    try testing.expectEqual(@as(u32, 2), raw);
}

test "a float named by all four parts of a construct is not written over by the first part's product" {
    var work: Work = .{};
    // `vec4(l) * colour`. The one float is read by parts 1, 2 and 3
    // after part 0 has computed, so part 0's product may not take its
    // register - which `kind.parts()` alone did not catch, because the
    // construct is four floats wide like the vector it multiplies.
    const code = try compile(&work, comptime built(.{ .splat_times = true }));
    try sound(&work, code);
    var splat: ?qpu.Rf = null;
    var reads: u32 = 0;
    for (work.plan()) |each| switch (each) {
        // Five varyings are carried: the colour's four at location 0
        // and this one float at location 1. They are read in that
        // order, so the last is the one the construct splats.
        .varying => |to| if (to != qpu.rf_scaled) {
            splat = to;
        },
        .fmul => |three| {
            if (splat) |reg| {
                if (three.a == reg or three.b == reg) reads += 1;
                // Only the last of the four may write over it.
                if (three.to == reg) try testing.expectEqual(@as(u32, 4), reads);
            }
        },
        else => {},
    };
    try testing.expectEqual(@as(u32, 4), reads);
}

test "a construct that names one float of a texel's word keeps the other alive" {
    var work: Work = .{};
    // `vec4(texel.r, texel.b, texel.g, l)`: alpha is the one float
    // nothing names, and it shares its register with blue. Before `live`
    // carried the colour's bump across the pair, alpha's slot died at
    // the sample, `release` gave that register back, and the first half
    // read out for the colour was handed it - destroying blue before
    // anything read it.
    const code = try compile(&work, comptime built(.{ .construct_texel = true, .samplers = 1 }));
    try sound(&work, code);
    try testing.expectEqual(@as(?Sampler, .{ .set = 0, .binding = 0 }), code.sampler);
    // The rule, read off the plan rather than waited for as a symptom:
    // whether the wrongly freed register is then handed out depends on
    // which one is lowest and free, so a program can carry the mistake
    // and draw right by luck. The two floats of a word have one last
    // reader between them, and here the colour names three of the four,
    // so both words are read to the end of the program.
    var sampled: ?usize = null;
    for (work.program(), 0..) |each, at| if (each.tag == .sample) {
        sampled = at;
    };
    const texel = work.slot_of[sampled.?];
    for ([2][2]u8{ .{ 0, 1 }, .{ 2, 3 } }) |pair| {
        try testing.expectEqual(work.slot_last[texel[pair[0]]], work.slot_last[texel[pair[1]]]);
        try testing.expectEqual(@as(u32, most_steps), work.slot_last[texel[pair[0]]]);
    }
    // The same with a vec4 varying and a vec4 of its own beside the
    // texel: eleven floats live at once, one more than there are
    // registers. Refused for that, and not drawn wrongly - which is the
    // thing to check, because every uniform of a sampling program is
    // held in front of the splice and that is what makes it eleven.
    try testing.expectError(Error.Registers, compile(&work, comptime built(.{ .crowded_texel = true, .samplers = 1 })));
}

test "a constant may be a constituent of a construct, whatever read it first" {
    var work: Work = .{};
    // `vec4(uv.x, uv.y, 0.25, 1.0)`, which is what glslc writes for
    // `vec4(uv, 0.25, 1.0)`. A constant has no step until something
    // reads it, and a constituent is a read.
    const plain_code = try compile(&work, comptime built(.{ .construct_constants = true }));
    try sound(&work, plain_code);
    try testing.expectEqual(@as(u32, 2), plain_code.uniform_count);
    // The same words with the two constants read by an OpFMul first.
    // Whether an unrelated earlier instruction happened to read them
    // cannot decide whether the module is taken.
    const read_code = try compile(&work, comptime built(.{ .construct_constants = true, .read_first = true }));
    try sound(&work, read_code);
    try testing.expectEqual(@as(u32, 2), read_code.uniform_count);
}

test "a module may declare more samplers than it samples" {
    var work: Work = .{};
    // The device's limit is one *sample*: one TMU, written once and read
    // once. How many are declared is this back end's table, so it is a
    // refusal of its own and not the device's.
    const code = try compile(&work, comptime built(.{ .samplers = 5 }));
    try sound(&work, code);
    try testing.expectEqual(@as(?Sampler, .{ .set = 0, .binding = 0 }), code.sampler);
    // Past the table, and said as the table and not as the hardware.
    try testing.expectError(Error.Declared, compile(&work, comptime built(.{ .samplers = most_samplers + 1 })));
}

test "a module's own numbers are held against the tables before they are stored" {
    var work: Work = .{};
    // 65535 is `none`. Stored, it would be read back as "never
    // decorated" and the sampler refused for want of a binding.
    try testing.expectError(Error.Numbered, compile(&work, comptime built(.{ .samplers = 1, .sentinel_binding = true })));
    try testing.expectError(Error.Numbered, compile(&work, &sentinel_location));
    try testing.expectError(Error.Numbered, compile(&work, &huge_location));
}

test "a decoration this back end does not take is refused by name, whatever its arity" {
    var work: Work = .{};
    // A real `OpDecorate %in Flat` is two words of operands and no
    // literal. Reading how many operands there are before reading which
    // decoration it is answered `Body` for exactly the decoration this
    // is here to turn down by name.
    try testing.expectError(Error.Refused, compile(&work, comptime built(.{ .bare_flat = true })));
    // And the three-operand shape a patch makes, which is the one the
    // suite tested before.
    try testing.expectError(Error.Refused, compile(&work, &flat_words));
}

test "a shader that always drops its pixel is refused as a discard and not as an unknown word" {
    var work: Work = .{};
    // `OpKill` is in `profile` for the one shape a conditional discard
    // has; anywhere else it is refused by the family's name. Through
    // Mesa's back end too: the walk refuses it before either back end
    // sees a step.
    try testing.expectError(Error.Discards, compile(&work, comptime built(.{ .always_kill = true })));
    try testing.expectError(Error.Discards, throughMesa(&work, comptime built(.{ .always_kill = true })));
}

const disasm = @import("qpu/disasm.zig");

/// Nine vectors made before any is summed: 44 floats live at once, more
/// than the 32 registers a 4-threaded program has under Mesa's allocator.
const Crowded = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const a = b.input(0, .f32x4);
        const c = b.input(1, .f32x4);
        const made = [_]u16{
            b.mul(a, c), b.add(a, c), b.mul(a, a),
            b.mul(c, c), b.add(a, a), b.add(c, c),
            b.mul(c, a), b.add(c, a), b.mul(a, c),
        };
        var sum = made[0];
        for (made[1..]) |each| sum = b.add(sum, each);
        b.color(sum);
    }
});

/// What Mesa's back end makes of `words`, with register sets of its own.
fn throughMesa(work: *Work, words: []const u32) !Code {
    return throughMesaKeyed(work, words, .{});
}

fn throughMesaKeyed(work: *Work, words: []const u32, key: Key) !Code {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    return compileVir(work, words, testing.allocator, &compiler, key);
}

/// An instruction as Mesa's disassembler prints it: the add side, the mul
/// side, the signals.
fn text(comptime add: []const u8, comptime mul: []const u8, comptime sig: []const u8) []const u8 {
    // Padded to its column where it is shorter than it, as the
    // disassembler pads it.
    const first = add ++ (" " ** (30 -| add.len)) ++ "; " ++ mul;
    if (sig.len == 0) return first;
    return first ++ (" " ** (60 -| first.len)) ++ "; " ++ sig;
}

fn expectText(code: Code, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, code.words.len);
    for (code.words, expected) |word, line| {
        var buffer: [disasm.most_text]u8 = undefined;
        try testing.expectEqualStrings(line, disasm.disasm(word, &buffer).?);
    }
}

test "through Mesa's back end, the interpolated colour is nine instructions, the last thread switch among the varyings" {
    var work: Work = .{};
    const code = try throughMesa(&work, Smooth.words);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    try testing.expectEqual(@as(usize, 0), code.stream().len);
    try testing.expectEqual(@as(u8, 4), code.threads);
    // W is read for the varyings, and the scoreboard locked at the last
    // thread switch, as the hand-written programs have it.
    try testing.expect(code.center_w);
    try testing.expect(!code.lock_scoreboard_on_first_thrsw);
    // Within the 16 registers `qpu.registers` keeps the hand-written
    // programs in.
    try testing.expectEqual(@as(u32, 16), code.registers);
    try expectText(code, &.{
        // W is read where it comes, rf3: its temporary was given the
        // register it was moved out of, and the move left out. The
        // msf and the moves of the centroid's W and Z are dead code.
        text("nop", "nop", "ldvary.rf4"),
        text("nop", "fmul rf5, rf4, rf3", "ldvary.rf7"),
        // The last thread switch, a pair, moved up among the ldvarys,
        // which 7.1 lets sit in the first two delay slots of one.
        text("fadd rf6, rf0, rf5", "fmul rf8, rf7, rf3", "thrsw; ldvary.rf10"),
        text("fadd rf9, rf0, rf8", "fmul rf11, rf10, rf3", "thrsw; ldvary.rf13"),
        text("fadd rf12, rf0, rf11", "fmul rf14, rf13, rf3", ""),
        text("fadd rf15, rf0, rf14", "nop", ""),
        // The sums packed where they were made, copy propagation having
        // taken the colour's moves out; the second pack in the delay slot
        // of the thread end.
        text("vfpack tlb, rf6, rf9", "nop", "thrsw"),
        text("vfpack tlb, rf12, rf15", "nop", ""),
        text("nop", "nop", ""),
    });
    // Where the hand-written program is twenty-one.
    try testing.expectEqual(@as(usize, 21), qpu.color_fragment.code.len);
}

test "through Mesa's back end, a colour of its own is two words to the tile buffer, one of them a uniform" {
    var work: Work = .{};
    const code = try throughMesa(&work, Plain.words);
    try testing.expectEqual(@as(u32, 0), code.varyings);
    // 0.5 and 1 as half-floats, 0x3800 high and 0x3c00 low.
    try testing.expectEqualSlices(Word, &[_]Word{.{ .float = @bitCast(@as(u32, 0x3800_3c00)) }}, code.stream());
    // No varying, so nothing reads W.
    try testing.expect(!code.center_w);
    try expectText(code, &.{
        // The last section first: nothing has to come before it.
        text("nop", "nop", "thrsw"),
        text("nop", "nop", "thrsw"),
        text("nop", "nop", "ldunifrf.rf4"),
        // Each vfpack of two constants is a uniform of the two
        // half-floats (vir_opt_constant_alu), moved to the tile buffer;
        // the second, 0 and 1, is 0x3c000000, which is 2^-7 as a float
        // and so a small immediate.
        text("nop", "mov tlb, rf4", "thrsw"),
        text("nop", "mov tlb, 0x3c000000", ""),
        text("nop", "nop", ""),
    });
}

test "through Mesa's back end, a texture: the lookup started in the delay slots of the last thread switch" {
    var work: Work = .{};
    const code = try throughMesa(&work, Textured.words);
    try testing.expectEqual(@as(u32, 2), code.varyings);
    try testing.expectEqual(Sampler{ .set = 0, .binding = 0 }, code.sampler.?);
    // The draw's two words, as the hand-written program reads them.
    try testing.expectEqualSlices(Word, &[_]Word{ .texture, .sampler }, code.stream());
    try testing.expectEqual(@as(u32, 12), code.registers);
    try expectText(code, &.{
        // The configuration first: the scheduler lets the two wrtmuc go
        // ahead of T, as long as S, which starts the lookup, comes last.
        text("nop", "nop", "ldvary.rf4; wrtmuc"),
        text("nop", "fmul rf5, rf4, rf3", "ldvary.rf7; wrtmuc"),
        text("fadd rf6, rf0, rf5", "fmul rf8, rf7, rf3", ""),
        // The last thread switch is the one the sample waits at: the
        // lookup is started in its delay slots, and both words are read
        // after it. vir_emit_last_thrsw added a pair of its own, taken
        // out again when nothing spilled.
        text("fadd rf9, rf0, rf8", "nop", "thrsw"),
        text("nop", "mov tmut, rf9", "thrsw"),
        text("nop", "mov tmus, rf6", ""),
        // The thread end's signal goes into the first ldtmu, and the
        // halves are packed back for the tile buffer in its delay slots.
        text("nop", "nop", "thrsw; ldtmu.rf10"),
        text("vfpack tlb, rf10.l, rf10.h", "nop", "ldtmu.rf11"),
        text("vfpack tlb, rf11.l, rf11.h", "nop", ""),
    });
}

test "through Mesa's back end, a depth compared: the reference to TMUDREF after T and before S, and what passed the first word's low half" {
    var work: Work = .{};
    const code = try throughMesa(&work, Shadowed.words);
    try testing.expectEqual(@as(u32, 3), code.varyings);
    // The draw is told the program compares, and hands the TMU the
    // sampler's comparison and a depth.
    try testing.expectEqual(Sampler{ .set = 0, .binding = 0, .compared = true }, code.sampler.?);
    // v3d_tex.c's order: the coordinate's T, the comparator, then S last,
    // which starts the lookup; and both words read back, as P0 asks.
    var buffer: [disasm.most_text]u8 = undefined;
    var t_at: ?usize = null;
    var dref_at: ?usize = null;
    var s_at: ?usize = null;
    var ldtmu: u32 = 0;
    var read_low = false;
    var first_word: ?[]const u8 = null;
    var named: [16]u8 = undefined;
    for (code.words, 0..) |word, at| {
        const line = disasm.disasm(word, &buffer).?;
        if (std.mem.indexOf(u8, line, "mov tmut,") != null) t_at = at;
        if (std.mem.indexOf(u8, line, "mov tmudref,") != null) dref_at = at;
        if (std.mem.indexOf(u8, line, "mov tmus,") != null) s_at = at;
        if (first_word) |register| {
            if (std.mem.indexOf(u8, line, register) != null) read_low = true;
        }
        if (std.mem.indexOf(u8, line, "ldtmu.")) |found| {
            ldtmu += 1;
            // The first word's register, as an operand of its low half:
            // `rfN.l`.
            if (first_word == null) {
                const start = found + "ldtmu.".len;
                var end = start;
                while (end < line.len and line[end] != ' ' and line[end] != ';') end += 1;
                first_word = try std.fmt.bufPrint(&named, "{s}.l", .{line[start..end]});
            }
        }
    }
    try testing.expect(t_at.? < dref_at.? and dref_at.? < s_at.?);
    try testing.expectEqual(@as(u32, 2), ldtmu);
    // What passed is the first word's low half, read where it is used:
    // vir_opt_alu folds the unpacking fmov into the product, as Mesa
    // does (`fmul rf15, 0x3f800000, rf13.l`).
    try testing.expect(read_low);
    // The plan has no program to hold it to.
    var planned: Work = .{};
    try testing.expectError(Error.Samplers, compile(&planned, Shadowed.words));
}

test "through Mesa's back end, glslc's shadow sample is facet's, to the word: its coordinate of three floats given the TMU as two" {
    var work: Work = .{};
    const code = try throughMesa(&work, Shadowed.words);
    const kept = try testing.allocator.dupe(u64, code.words);
    defer testing.allocator.free(kept);
    var theirs: Work = .{};
    const glslc = try throughMesa(&theirs, &reference.glslc_shadow);
    try testing.expectEqualSlices(u64, kept, glslc.words);
    try testing.expectEqual(Sampler{ .set = 0, .binding = 0, .compared = true }, glslc.sampler.?);
    // The plan refuses it, as it refuses facet's own.
    var plan: Work = .{};
    try testing.expectError(Error.Samplers, compile(&plan, &reference.glslc_shadow));
}

test "through Mesa's back end, a texel times the colour reads the texel's halves in its products" {
    var work: Work = .{};
    const code = try throughMesa(&work, Modulated.words);
    try testing.expectEqual(@as(u32, 6), code.varyings);
    try testing.expectEqual(@as(u8, 4), code.threads);
    try testing.expectEqualSlices(Word, &[_]Word{ .texture, .sampler }, code.stream());
    // Mesa's allocator gives 7.1's four threads 32 registers each and
    // goes round them from rf4, where `qpu.registers` keeps the
    // hand-written programs in 16. The board has the 32: V3DTest MESA
    // draws this program at four threads with every pixel right.
    try testing.expectEqual(@as(u32, 28), code.registers);
    try testing.expect(code.registers > qpu.registers);
    try expectText(code, &.{
        text("nop", "nop", "ldvary.rf4; wrtmuc"),
        text("nop", "fmul rf5, rf4, rf3", "ldvary.rf7; wrtmuc"),
        text("fadd rf6, rf0, rf5", "fmul rf8, rf7, rf3", "ldvary.rf10"),
        text("fadd rf9, rf0, rf8", "fmul rf11, rf10, rf3", "ldvary.rf13"),
        text("fadd rf12, rf0, rf11", "fmul rf14, rf13, rf3", "ldvary.rf16"),
        text("fadd rf15, rf0, rf14", "mov tmut, rf9", "thrsw"),
        text("mov tmus, rf6", "fmul rf17, rf16, rf3", "thrsw; ldvary.rf19"),
        text("fadd rf18, rf0, rf17", "fmul rf20, rf19, rf3", ""),
        text("fadd rf21, rf0, rf20", "nop", "ldtmu.rf22"),
        // Each half read straight out of the texel's word by the
        // product, as the hand-written fmulLow and fmulHigh read it.
        text("nop", "fmul rf24, rf22.l, rf12", "ldtmu.rf23"),
        text("nop", "fmul rf25, rf22.h, rf15", ""),
        text("vfpack tlb, rf24, rf25", "fmul rf26, rf23.l, rf18", ""),
        text("nop", "fmul rf27, rf23.h, rf21", ""),
        text("vfpack tlb, rf26, rf27", "nop", "thrsw"),
        text("nop", "nop", ""),
        text("nop", "nop", ""),
    });
}

test "through Mesa's back end, a texel added to: the floats of its own read around the thread switch" {
    var work: Work = .{};
    const code = try throughMesa(&work, Tinted.words);
    try testing.expectEqualSlices(Word, &[_]Word{
        .texture,          .sampler,
        .{ .float = 0.1 }, .{ .float = 0.2 },
        .{ .float = 0.3 },
    }, code.stream());
    try expectText(code, &.{
        text("nop", "nop", "ldvary.rf4; wrtmuc"),
        text("nop", "fmul rf5, rf4, rf3", "ldvary.rf7; wrtmuc"),
        // The floats of its own, read around the thread switch: Mesa
        // reads the uniform stream in the last section as anywhere else.
        // The third, 0.3, is an ldunif to rf0, which its sum reads five
        // instructions on, and the fourth, 0, a small immediate.
        text("fadd rf6, rf0, rf5", "fmul rf8, rf7, rf3", "ldunifrf.rf12"),
        text("fadd rf9, rf0, rf8", "nop", "thrsw; ldunifrf.rf13"),
        text("nop", "mov tmut, rf9", "thrsw; ldunif"),
        text("nop", "mov tmus, rf6", ""),
        text("nop", "nop", "ldtmu.rf10"),
        text("fadd rf14, rf12, rf10.l", "nop", "ldtmu.rf11"),
        text("fadd rf15, rf13, rf10.h", "nop", ""),
        text("fadd rf16, rf0, rf11.l", "nop", ""),
        text("fadd rf17, rf11.h, 0", "nop", ""),
        text("vfpack tlb, rf14, rf15", "nop", "thrsw"),
        text("vfpack tlb, rf16, rf17", "nop", ""),
        text("nop", "nop", ""),
    });
}

test "through Mesa's back end, what does not fit 4 threads is compiled at 2, where the plan refuses it" {
    var work: Work = .{};
    try testing.expectError(Error.Registers, compile(&work, Crowded.words));
    const code = try throughMesa(&work, Crowded.words);
    // Strategy 0 failed to allocate; strategy 2's two threads have all 64
    // registers, and it fits them without a spill: a spill would have
    // put the spill's uniforms in the stream, which a draw cannot fill.
    try testing.expectEqual(@as(u8, 2), code.threads);
    try testing.expectEqual(@as(u32, 64), code.registers);
    try testing.expectEqual(@as(u32, 8), code.varyings);
    try testing.expectEqual(@as(usize, 0), code.stream().len);
    // It ends as every program does: the thread end's signal, and its
    // two delay slots.
    var buffer: [disasm.most_text]u8 = undefined;
    try testing.expect(std.mem.endsWith(u8, disasm.disasm(code.words[code.words.len - 3], &buffer).?, "thrsw"));
}

test "through Mesa's back end, a module is refused for what the reading refuses, by the same name" {
    var work: Work = .{};
    try testing.expectError(Error.Samplers, throughMesa(&work, Twice.words));
    try testing.expectError(Error.Operands, throughMesa(&work, Offset.words));
    try testing.expectError(Error.Stage, throughMesa(&work, &vertex_words));
    try testing.expectError(Error.Varyings, throughMesa(&work, Wide.words));
    try testing.expectError(Error.Refused, throughMesa(&work, &flat_words));
    try testing.expectError(Error.Refused, throughMesa(&work, &[_]u32{}));
}

test "through Mesa's back end, a program compiled twice from the one work is the same program" {
    var work: Work = .{};
    const first = try throughMesa(&work, Modulated.words);
    var kept: [most_words]u64 = undefined;
    const length = first.words.len;
    @memcpy(kept[0..length], first.words);
    _ = try throughMesa(&work, Smooth.words);
    const second = try throughMesa(&work, Modulated.words);
    try testing.expectEqualSlices(u64, kept[0..length], second.words);
}

test "through Mesa's back end, a vector times a varying scalar is fourteen instructions, in more registers than the plan keeps to" {
    var work: Work = .{};
    const code = try throughMesa(&work, Dimmed.words);
    try testing.expectEqual(@as(u32, 5), code.varyings);
    try testing.expectEqual(@as(usize, 0), code.stream().len);
    try testing.expectEqual(@as(u8, 4), code.threads);
    try testing.expect(code.center_w);
    try testing.expect(!code.lock_scoreboard_on_first_thrsw);
    // Past `qpu.registers` and within the 32 Mesa gives four threads.
    try testing.expectEqual(@as(u32, 23), code.registers);
    try expectText(code, &.{
        text("nop", "nop", "ldvary.rf4"),
        text("nop", "fmul rf5, rf4, rf3", "ldvary.rf7"),
        text("fadd rf6, rf0, rf5", "fmul rf8, rf7, rf3", "ldvary.rf10"),
        text("fadd rf9, rf0, rf8", "fmul rf11, rf10, rf3", "ldvary.rf13"),
        text("fadd rf12, rf0, rf11", "fmul rf14, rf13, rf3", "thrsw; ldvary.rf16"),
        text("fadd rf15, rf0, rf14", "fmul rf17, rf16, rf3", "thrsw"),
        text("fadd rf18, rf0, rf17", "nop", ""),
        text("nop", "fmul rf19, rf6, rf18", ""),
        text("nop", "fmul rf20, rf9, rf18", ""),
        text("vfpack tlb, rf19, rf20", "fmul rf21, rf12, rf18", ""),
        text("nop", "fmul rf22, rf15, rf18", ""),
        text("vfpack tlb, rf21, rf22", "nop", "thrsw"),
        text("nop", "nop", ""),
        text("nop", "nop", ""),
    });
}

/// V3DTest's colour of its own (c/test/v3d/fragments.zig), which its MESA
/// draws.
const Quarters = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.constant(.{ 0.25, 0.5, 0.75, 1 }));
    }
});

test "through Mesa's back end, four constants are two uniforms of halves, packed as it compiles" {
    var work: Work = .{};
    const code = try throughMesa(&work, Quarters.words);
    try testing.expectEqual(@as(u32, 0), code.varyings);
    try testing.expect(!code.center_w);
    // 0.25 and 0.5 as halves, 0x3400 and 0x3800; 0.75 and 1, 0x3a00 and
    // 0x3c00.
    try testing.expectEqualSlices(Word, &.{ .{ .float = @bitCast(@as(u32, 0x3800_3400)) }, .{ .float = @bitCast(@as(u32, 0x3c00_3a00)) } }, code.stream());
    try expectText(code, &.{
        text("nop", "nop", "thrsw"),
        text("nop", "nop", "thrsw"),
        text("nop", "nop", "ldunifrf.rf4"),
        text("nop", "mov tlb, rf4", "thrsw; ldunifrf.rf5"),
        text("nop", "mov tlb, rf5", ""),
        text("nop", "nop", ""),
    });
}

/// A colour the draw pushes: four words of the push constants.
const Pushed = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.push(0, .f32x4));
    }
});

/// The colour the vertices carry times a float pushed, plus a vector
/// pushed: what `reference.glslc_tinted` is, as facet's emitter writes it.
const PushTinted = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.add(b.scale(b.input(0, .f32x4), b.push(16, .f32x1)), b.push(0, .f32x4)));
    }
});

test "through Mesa's back end, a colour pushed is four uniforms of the push constants, packed for the tile buffer" {
    var work: Work = .{};
    const code = try throughMesa(&work, Pushed.words);
    try testing.expectEqual(@as(u32, 0), code.varyings);
    try testing.expect(!code.center_w);
    // The draw's words, not the module's: nothing is folded, as
    // `Quarters`' four constants are into two words of halves.
    try testing.expectEqualSlices(Word, &.{ .{ .push = 0 }, .{ .push = 1 }, .{ .push = 2 }, .{ .push = 3 } }, code.stream());
    try expectText(code, &.{
        text("nop", "nop", "thrsw; ldunifrf.rf4"),
        text("nop", "nop", "thrsw; ldunifrf.rf5"),
        text("nop", "nop", "ldunifrf.rf6"),
        text("vfpack tlb, rf4, rf5", "nop", "thrsw; ldunifrf.rf7"),
        text("vfpack tlb, rf6, rf7", "nop", ""),
        text("nop", "nop", ""),
    });
    // The plan has no hand-written program to hold one to.
    var plan: Work = .{};
    try testing.expectError(Error.Storage, compile(&plan, Pushed.words));
}

test "through Mesa's back end, glslc's push constants are facet's: a float and a vector of them, read once each" {
    var work: Work = .{};
    const code = try throughMesa(&work, PushTinted.words);
    const kept = try testing.allocator.dupe(u64, code.words);
    defer testing.allocator.free(kept);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    try testing.expect(code.center_w);
    // The float at 16 is word 4, read once for the four products.
    try testing.expectEqualSlices(Word, &.{ .{ .push = 4 }, .{ .push = 0 }, .{ .push = 1 }, .{ .push = 2 }, .{ .push = 3 } }, code.stream());
    try testing.expectEqual(@as(usize, 13), code.words.len);
    // glslang reads the varying before the float and declares its types
    // in another order, with names around them; what is made is the same
    // program to the word.
    var theirs: Work = .{};
    const glslc = try throughMesa(&theirs, &reference.glslc_tinted);
    try testing.expectEqualSlices(u64, kept, glslc.words);
    try testing.expectEqualSlices(Word, code.stream(), glslc.stream());
    var plan: Work = .{};
    try testing.expectError(Error.Storage, compile(&plan, &reference.glslc_tinted));
}

test "push constants the tables cannot hold, or that are not a block of floats, are refused" {
    const tinted = &reference.glslc_tinted;
    const max = sdk.facet.shader.MAX_PUSH_CONSTANTS_SIZE;
    var work: Work = .{};
    // The second OpMemberDecorate is the float's, `%13 1 Offset 16`. An
    // offset not on a word: a uniform is a word.
    try testing.expectError(Error.Storage, throughMesa(&work, &comptime patched(tinted, .member_decorate, 1, 3, 18)));
    // Past the push constants, and inside them with the float past them.
    try testing.expectError(Error.Storage, throughMesa(&work, &comptime patched(tinted, .member_decorate, 1, 3, max)));
    _ = try throughMesa(&work, &comptime patched(tinted, .member_decorate, 1, 3, max - 4));
    // The vector's, `%13 0 Offset 0`, moved to where its last float is
    // past them.
    try testing.expectError(Error.Storage, throughMesa(&work, &comptime patched(tinted, .member_decorate, 0, 3, max - 12)));
    // A member's decoration that is not its offset.
    try testing.expectError(Error.Refused, throughMesa(&work, &comptime patched(tinted, .member_decorate, 1, 2, @intFromEnum(spirv.Decoration.row_major))));
    // The first OpConstant, `%17 = OpConstant %16 1`, is the float's
    // index: a member the block does not have.
    try testing.expectError(Error.Body, throughMesa(&work, &comptime patched(tinted, .constant, 0, 2, 2)));
    // The block decorated `Flat` instead of `Block`.
    try testing.expectError(Error.Refused, throughMesa(&work, &comptime patched(tinted, .decorate, 2, 1, @intFromEnum(spirv.Decoration.flat))));
}

test "through Mesa's back end, a pixel dropped: the comparison into the flags, SETMSF where it holds, and Z written through" {
    var work: Work = .{};
    const code = try throughMesa(&work, Cutout.words);
    try testing.expectEqual(@as(u32, 2), code.varyings);
    try testing.expect(code.writes_z);
    try testing.expect(code.disable_ez);
    // The two configuration words, and the depth's write specifier:
    // TLB_TYPE_DEPTH, invariant, per pixel (nir_to_vir.c:2115-2134). The
    // half the alpha is compared with, and the 0 SETMSF writes, are
    // small immediates; the bool made of the flags is dead and gone.
    // The specifier is a NaN as a float, so it is held by its bits.
    const stream = code.stream();
    try testing.expectEqual(@as(usize, 3), stream.len);
    try testing.expect(stream[0] == .texture and stream[1] == .sampler);
    try testing.expectEqual(@as(u32, 0xffffff84), @as(u32, @bitCast(stream[2].float)));
    try expectText(code, &.{
        text("nop", "nop", "ldvary.rf4; wrtmuc"),
        text("nop", "fmul rf5, rf4, rf3", "ldvary.rf7; wrtmuc"),
        text("fadd rf6, rf0, rf5", "fmul rf8, rf7, rf3", ""),
        text("fadd rf9, rf0, rf8", "nop", "thrsw"),
        text("nop", "mov tmut, rf9", "thrsw"),
        text("nop", "mov tmus, rf6", ""),
        text("nop", "nop", "ldtmu.rf10"),
        text("nop", "nop", "ldtmu.rf11"),
        // The alpha is the second word's high half, read as it is by
        // the comparison: the unpack was copied into it.
        text("fcmp.pushn -, rf11.h, 0x3f000000", "nop", ""),
        text("setmsf.ifa -, 0", "nop", ""),
        // Z from the rasterizer, its source anything (rf5, as
        // vir_to_qpu.c:290 has a null source), before the colour.
        text("nop", "mov tlbu, rf5", "thrsw"),
        text("vfpack tlb, rf10.l, rf10.h", "nop", ""),
        text("vfpack tlb, rf11.l, rf11.h", "nop", ""),
    });
}

test "through Mesa's back end, alpha to coverage: FTOC of the colour's alpha, kept of MSF by SETMSF, then Z written through before the colour" {
    var work: Work = .{};
    const code = try throughMesaKeyed(&work, Smooth.words, .{ .sample_alpha_to_coverage = true });
    try testing.expectEqual(@as(u32, 4), code.varyings);
    // Early Z off and Z written, as for a discard (nir_to_vir.c:2073-2081,
    // 2098): the one uniform is the depth's write specifier.
    try testing.expect(code.writes_z);
    try testing.expect(code.disable_ez);
    const stream = code.stream();
    try testing.expectEqual(@as(usize, 1), stream.len);
    try testing.expectEqual(@as(u32, 0xffffff84), @as(u32, @bitCast(stream[0].float)));
    // Where each is, by its line's add side: the alpha's FTOC, MSF and
    // the AND of the two, SETMSF of that with no condition, then Z and
    // the colour.
    const Seen = struct { ftoc: ?usize = null, msf: ?usize = null, both: ?usize = null, setmsf: ?usize = null, z: ?usize = null, color: ?usize = null, alpha_pair: ?usize = null };
    var seen: Seen = .{};
    var lines: [most_words][disasm.most_text]u8 = undefined;
    var texts: [most_words][]const u8 = undefined;
    for (code.words, 0..) |word, k| {
        texts[k] = disasm.disasm(word, &lines[k]).?;
        const line = texts[k];
        const add_side = line[0 .. std.mem.indexOf(u8, line, ";") orelse line.len];
        if (std.mem.startsWith(u8, add_side, "ftoc ")) seen.ftoc = k;
        if (std.mem.startsWith(u8, add_side, "msf ")) seen.msf = k;
        if (std.mem.startsWith(u8, add_side, "and ")) seen.both = k;
        if (std.mem.startsWith(u8, add_side, "setmsf ")) {
            try testing.expect(std.mem.startsWith(u8, add_side, "setmsf -, "));
            seen.setmsf = k;
        }
        if (std.mem.indexOf(u8, line, "mov tlbu") != null) seen.z = k;
        if (std.mem.indexOf(u8, line, "vfpack tlb") != null) {
            if (seen.color == null) seen.color = k else seen.alpha_pair = k;
        }
    }
    const ftoc = seen.ftoc orelse return error.NoFtoc;
    const msf = seen.msf orelse return error.NoMsf;
    const both = seen.both orelse return error.NoAnd;
    const setmsf = seen.setmsf orelse return error.NoSetmsf;
    try testing.expect(ftoc < both and msf < both and both < setmsf);
    try testing.expect(setmsf < (seen.z orelse return error.NoZ));
    try testing.expect(seen.z.? < (seen.color orelse return error.NoColor));
    // The FTOC reads what the colour's alpha is in: the last source of
    // the second pair the tile buffer is written.
    const second_pair = texts[seen.alpha_pair orelse return error.NoAlpha];
    const packed_side = second_pair[0 .. std.mem.indexOf(u8, second_pair, ";") orelse second_pair.len];
    const alpha = packed_side[std.mem.lastIndexOf(u8, packed_side, "rf") orelse return error.NoAlpha ..];
    const alpha_register = alpha[0 .. std.mem.indexOfAny(u8, alpha, ". ") orelse alpha.len];
    const ftoc_side = texts[ftoc][0 .. std.mem.indexOf(u8, texts[ftoc], ";") orelse texts[ftoc].len];
    try testing.expect(std.mem.endsWith(u8, std.mem.trimEnd(u8, ftoc_side, " "), alpha_register));
    // Without the key, none of it, as before.
    var unkeyed: Work = .{};
    const without = try throughMesa(&unkeyed, Smooth.words);
    try testing.expect(!without.writes_z and !without.disable_ez);
    for (without.words) |word| {
        var buffer: [disasm.most_text]u8 = undefined;
        const line = disasm.disasm(word, &buffer).?;
        try testing.expect(std.mem.indexOf(u8, line, "ftoc") == null and std.mem.indexOf(u8, line, "setmsf") == null);
    }
}

test "through Mesa's back end, the program of no colour is qpu.zig's, to the word" {
    var work: Work = .{};
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    const code = try compileNoColor(&work, testing.allocator, &compiler);
    try testing.expectEqualSlices(u64, qpu.no_color_fragment.code, code.words);
    // No varying, the depth's write specifier its one uniform, and what
    // the shader record says of it as qpu.zig has it.
    try testing.expectEqual(qpu.no_color_fragment.varyings, code.varyings);
    try testing.expectEqual(@as(u32, qpu.no_color_fragment.uniforms), code.uniform_count);
    try testing.expectEqual(qpu.no_color_specifier, @as(u32, @bitCast(code.stream()[0].float)));
    try testing.expectEqual(qpu.no_color_fragment.threads, code.threads);
    try testing.expectEqual(qpu.no_color_fragment.center_w, code.center_w);
    try testing.expectEqual(qpu.no_color_fragment.lock_scoreboard_on_first_thrsw, code.lock_scoreboard_on_first_thrsw);
    try testing.expect(code.writes_z and qpu.no_color_fragment.writes_z);
    try testing.expect(code.disable_ez and qpu.no_color_fragment.disable_ez);
    try testing.expectEqual(@as(?Sampler, null), code.sampler);
    // Its one TLB write is the depth, in the program's end.
    var buffer: [disasm.most_text]u8 = undefined;
    try testing.expectEqualStrings("nop                           ; mov tlbu, rf5               ; thrsw", disasm.disasm(code.words[3], &buffer).?);
    // And the same through the arena the library compiles in.
    var arena_work: Work = .{};
    const through = try compileNoColorThroughMesa(&arena_work, testing.allocator);
    try testing.expectEqualSlices(u64, qpu.no_color_fragment.code, through.words);
}

test "through Mesa's back end, a module's colour in a key of no render target: not written, Z written through" {
    var work: Work = .{};
    const code = try throughMesaKeyed(&work, Smooth.words, .{ .cbufs = 0 });
    try testing.expect(code.writes_z and code.disable_ez);
    try testing.expectEqual(@as(usize, 1), code.stream().len);
    try testing.expectEqual(qpu.no_color_specifier, @as(u32, @bitCast(code.stream()[0].float)));
    var z: u32 = 0;
    for (code.words) |word| {
        var buffer: [disasm.most_text]u8 = undefined;
        const line = disasm.disasm(word, &buffer).?;
        try testing.expect(std.mem.indexOf(u8, line, "vfpack") == null and std.mem.indexOf(u8, line, "tlb,") == null);
        if (std.mem.indexOf(u8, line, "mov tlbu") != null) z += 1;
    }
    try testing.expectEqual(@as(u32, 1), z);
    // Its varyings are still read, as every program here reads them all.
    try testing.expectEqual(@as(u32, 4), code.varyings);
}

test "through Mesa's back end, glslc's discard is facet's, to the word" {
    var work: Work = .{};
    const code = try throughMesa(&work, Cutout.words);
    const kept = try testing.allocator.dupe(u64, code.words);
    defer testing.allocator.free(kept);
    var theirs: Work = .{};
    const glslc = try throughMesa(&theirs, &reference.glslc_cutout);
    try testing.expectEqualSlices(u64, kept, glslc.words);
    try testing.expect(glslc.writes_z and glslc.disable_ez);
    var plan: Work = .{};
    try testing.expectError(Error.Discards, compile(&plan, &reference.glslc_cutout));
}

test "a discard in any shape but the one is refused, and nothing is compiled of it" {
    var work: Work = .{};
    // The selection's false label not its merge block: the body would go
    // on somewhere else.
    try testing.expectError(Error.Branches, throughMesa(&work, &comptime patched(Cutout.words, .branch_conditional, 0, 2, 24)));
    // The branch on something that is not a comparison: the colour.
    try testing.expectError(Error.Body, throughMesa(&work, &comptime patched(Cutout.words, .branch_conditional, 0, 0, 20)));
    // A comparison read as a float.
    try testing.expectError(Error.Type, throughMesa(&work, &comptime patched(Cutout.words, .store, 0, 1, 22)));
}

test "compileThroughMesa makes what compileVir does, its memory given back" {
    // `testing.allocator` under the arena says whether every block of it
    // went back.
    inline for (.{ Smooth.words, Dimmed.words, Quarters.words, Textured.words, Modulated.words, Pushed.words, PushTinted.words, Cutout.words }) |words| {
        var work: Work = .{};
        const once = try throughMesa(&work, words);
        const kept = try testing.allocator.dupe(u64, once.words);
        defer testing.allocator.free(kept);
        var second: Work = .{};
        const code = try compileThroughMesa(&second, words, testing.allocator, .{});
        try testing.expectEqualSlices(u64, kept, code.words);
        try testing.expectEqual(once.threads, code.threads);
        try testing.expectEqual(once.uniform_count, code.uniform_count);
    }
    // And a refusal gives back the register sets it was made after.
    var work: Work = .{};
    try testing.expectError(Error.Samplers, compileThroughMesa(&work, Twice.words, testing.allocator, .{}));
}

/// glslc's float arithmetic (`reference.glslc_arith`) as facet's emitter
/// writes it, in the same order: what the cores draw beside the V3D.
const Arithmetic = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const z = b.component(v, 2);
        const w = b.component(v, 3);
        const half = b.scalar(0.5);
        const n = b.normalize(b.sub(b.vector(&.{ x, y, z }), b.constantOf(.f32x3, .{ 0.5, 0.5, 0.5, 0 })));
        const lit = b.clamp(b.dot(n, b.constantOf(.f32x3, .{ 0.267, 0.535, 0.802, 0 })), b.scalar(0), b.scalar(1));
        const red = b.mix(x, lit, b.scalar(0.25));
        const green = b.mul(b.fract(b.mul(y, b.scalar(3))), half);
        const blue = b.max(b.mul(b.sqrt(b.abs(b.sub(z, half))), b.pow(w, b.scalar(2.2))), b.neg(x));
        const alpha = b.mul(b.length(b.vector(&.{ x, y })), half);
        b.color(b.vector(&.{ red, green, blue, alpha }));
    }
});

/// How many steps of `tag` the walk made.
fn stepsOf(work: *const Work, tag: Tag) usize {
    var count: usize = 0;
    for (work.program()) |each| {
        if (each.tag == tag) count += 1;
    }
    return count;
}

/// How many of a program's instructions have `op` on their add side, or
/// on their mul side.
fn sideOps(code: Code, comptime op: []const u8, mul_side: bool) usize {
    var count: usize = 0;
    for (code.words) |word| {
        var buffer: [disasm.most_text]u8 = undefined;
        const line = disasm.disasm(word, &buffer).?;
        const cut = std.mem.indexOf(u8, line, ";") orelse line.len;
        const side = if (mul_side) std.mem.trimStart(u8, line[cut + 1 ..], " ") else line[0..cut];
        if (std.mem.startsWith(u8, side, op ++ " ")) count += 1;
    }
    return count;
}

test "through Mesa's back end, glslc's float arithmetic: GLSL.std.450 lowered as v3dv has NIR lower it" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_arith);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    try testing.expectEqual(@as(u8, 4), code.threads);
    // The walk's lowering: Normalize a dot and RSQRT, the dot of the
    // constant a second, Length a third, its square root RSQRT and RECIP
    // as Sqrt's is; Pow LOG then EXP; FClamp to 0.0 and 1.0 an fsat, as
    // the algebraic pass makes it (since 1.153), and the negated x the
    // FMAX's other operand; Fract FFLOOR and FSUB.
    try testing.expectEqual(@as(usize, 3), stepsOf(&work, .dot));
    try testing.expectEqual(@as(usize, 3), stepsOf(&work, .rsqrt));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .recip));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .log2));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .exp2));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .max));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .min));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .sat));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .floor));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .abs));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .negate));
    // The program has each of them where Mesa puts it: the SFU's and the
    // rounding on the add side, FABS and fsat an FMOV's unpack on the mul
    // side, the negation an XOR of the sign bit.
    try testing.expectEqual(@as(usize, 3), sideOps(code, "rsqrt", false));
    try testing.expectEqual(@as(usize, 2), sideOps(code, "recip", false));
    try testing.expectEqual(@as(usize, 1), sideOps(code, "log", false));
    try testing.expectEqual(@as(usize, 1), sideOps(code, "exp", false));
    try testing.expectEqual(@as(usize, 1), sideOps(code, "ffloor", false));
    try testing.expectEqual(@as(usize, 1), sideOps(code, "fmax", false));
    try testing.expectEqual(@as(usize, 0), sideOps(code, "fmin", false));
    try testing.expectEqual(@as(usize, 1), sideOps(code, "xor", false));
    // FABS and fsat are FMOVs of the mul side in VIR, which the scheduler
    // may move to the add side at 7.1, as Mesa's qpu_convert_mul_to_add
    // does.
    try testing.expectEqual(@as(usize, 2), sideOps(code, "fmov", true) + sideOps(code, "fmov", false));
    var unpacked = false;
    var saturated = false;
    for (code.words) |word| {
        var buffer: [disasm.most_text]u8 = undefined;
        const line = disasm.disasm(word, &buffer).?;
        if (std.mem.indexOf(u8, line, "fmov") != null and std.mem.indexOf(u8, line, ".abs") != null) unpacked = true;
        if (std.mem.indexOf(u8, line, "fmov") != null and std.mem.indexOf(u8, line, ".sat") != null) saturated = true;
    }
    try testing.expect(unpacked and saturated);
    // FMix's weight is the constant 0.25: x(1 - t) + yt, its 1 - t folded
    // to 0.75, which is a uniform; and the sign bit the XOR reads is one.
    var folded = false;
    var sign = false;
    for (code.stream()) |word| switch (word) {
        .float => |value| {
            if (value == 0.75) folded = true;
            if (@as(u32, @bitCast(value)) == 0x8000_0000) sign = true;
        },
        else => {},
    };
    try testing.expect(folded and sign);
    // The plan computes sums and products alone.
    var plan: Work = .{};
    try testing.expectError(Error.Body, compile(&plan, &reference.glslc_arith));
}

test "through Mesa's back end, glslc's float arithmetic is facet's, to the word" {
    var theirs: Work = .{};
    const glslc = try throughMesa(&theirs, &reference.glslc_arith);
    var ours: Work = .{};
    const facet_made = try throughMesa(&ours, Arithmetic.words);
    try testing.expectEqualSlices(u64, glslc.words, facet_made.words);
    try testing.expectEqual(glslc.stream().len, facet_made.stream().len);
    for (glslc.stream(), facet_made.stream()) |a, b| try testing.expectEqual(a, b);
}

/// glslc_chosen's shader through the IR: the same operations in the
/// order glslc writes them.
const Chosen = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const half = b.scalar(0.5);
        const six = b.scalar(6);
        const quarter = b.scalar(0.25);
        const x = b.component(v, 0);
        const sine = b.add(b.mul(b.sin(b.mul(x, six)), half), half);
        const y = b.component(v, 1);
        const cosine = b.add(b.mul(b.cos(b.mul(y, six)), half), half);
        const z = b.component(v, 2);
        const tangent = b.clamp(b.mul(b.tan(z), quarter), b.scalar(0), b.scalar(1));
        const green = b.select(b.lessThan(x, y), sine, cosine);
        const stepped = b.step(b.scalar(0.3), x);
        const eased = b.smoothStep(b.scalar(0.2), b.scalar(0.8), y);
        const blue = b.select(b.greaterEqual(z, half), stepped, eased);
        const signed = b.add(b.mul(b.sign(b.sub(x, half)), quarter), half);
        const unequal = b.select(b.notEqual(x, y), b.scalar(0.75), b.scalar(1));
        const equal = b.select(b.equal(y, z), quarter, unequal);
        const alpha = b.select(b.lessEqual(x, z), signed, equal);
        b.color(b.vector(&.{ green, blue, tangent, alpha }));
    }
});

test "through Mesa's back end, glslc's chosen floats: the comparisons, OpSelect and the rest of the float functions as Mesa lowers them" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_chosen);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    // Five comparisons, each read by an OpSelect, in the order glslc
    // writes them; Step one slt.
    var asked: [5]Comparison = undefined;
    var compares: usize = 0;
    for (work.program()) |each| if (each.tag == .compare) {
        asked[compares] = @enumFromInt(each.at);
        compares += 1;
    };
    try testing.expectEqual(@as(usize, 5), compares);
    try testing.expectEqualSlices(Comparison, &.{ .less, .greater_equal, .not_equal, .equal, .less_equal }, &asked);
    try testing.expectEqual(@as(usize, 5), stepsOf(&work, .select));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .set_less));
    // Sin, Cos and Tan's two, which is the one quotient left: SmoothStep's
    // one over its constant edges' width is folded. FClamp to 0.0 and 1.0
    // and SmoothStep's t are fsat, FSign ntq_fsign's.
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .sin));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .cos));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .recip));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .sat));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .sign));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .min) + stepsOf(&work, .max) + stepsOf(&work, .negate));
    // ntq_fsincos four times: FROUND, the SFU's SIN, FTOIN, the SHL into
    // the sign bit and its XOR, each on the add side. Six FCMPs, each with
    // the flags it pushes after its name: the five, and slt's, each read
    // by the SEL right after it while the flags still hold it.
    for ([_][]const u8{ "fround", "sin", "ftoin", "shl", "xor", "fcmp" }, [_]usize{ 4, 4, 4, 4, 4, 6 }) |op, wanted| {
        var count: usize = 0;
        for (code.words) |word| {
            var buffer: [disasm.most_text]u8 = undefined;
            const line = disasm.disasm(word, &buffer).?;
            const cut = std.mem.indexOf(u8, line, ";") orelse line.len;
            if (std.mem.startsWith(u8, line[0..cut], op)) count += 1;
        }
        try testing.expectEqual(wanted, count);
    }
    try testing.expectEqual(@as(usize, 1), sideOps(code, "recip", false));
    // The fsat FMOVs and FSign's two, which push the flags.
    var saturated: usize = 0;
    for (code.words) |word| {
        var buffer: [disasm.most_text]u8 = undefined;
        const line = disasm.disasm(word, &buffer).?;
        if (std.mem.indexOf(u8, line, "fmov") != null and std.mem.indexOf(u8, line, ".sat") != null) saturated += 1;
    }
    try testing.expectEqual(@as(usize, 2), saturated);
    // The folded constants are uniforms: 1 / (0.8 - 0.2) in floats, and
    // -2.0; and 1 / pi, which ntq_fsincos multiplies by.
    var width = false;
    var minus_two = false;
    var over_pi = false;
    for (code.stream()) |word| switch (word) {
        .float => |value| {
            if (value == @as(f32, 1.0) / (@as(f32, 0.8) - @as(f32, 0.2))) width = true;
            if (value == -2.0) minus_two = true;
            if (value == @as(f32, @floatCast(@as(f64, 1.0) / std.math.pi))) over_pi = true;
        },
        else => {},
    };
    try testing.expect(width and minus_two and over_pi);
    // The plan computes sums and products alone.
    var plan: Work = .{};
    try testing.expectError(Error.Body, compile(&plan, &reference.glslc_chosen));
}

test "through Mesa's back end, glslc's chosen floats are facet's, to the word" {
    var theirs: Work = .{};
    const glslc = try throughMesa(&theirs, &reference.glslc_chosen);
    var ours: Work = .{};
    const facet_made = try throughMesa(&ours, Chosen.words);
    try testing.expectEqualSlices(u64, glslc.words, facet_made.words);
    try testing.expectEqual(glslc.stream().len, facet_made.stream().len);
    for (glslc.stream(), facet_made.stream()) |a, b| try testing.expectEqual(a, b);
}

test "a constant operation folds, as NIR folds it, and a vector OpSelect or FOrdNotEqual is refused" {
    // Each fold as nir_opcodes.py has it in floats.
    var work: Work = .{};
    const a = try immediateOf(&work, 0.8, .f32x1);
    const b = try immediateOf(&work, 0.2, .f32x1);
    const width = try binary(&work, .sub, a, b);
    try testing.expectEqual(Tag.constant, work.steps[width].tag);
    try testing.expectEqual(@as(f32, 0.8) - @as(f32, 0.2), work.pool[work.steps[width].at]);
    const over = try unary(&work, .recip, width);
    try testing.expectEqual(@as(f32, 1.0) / (@as(f32, 0.8) - @as(f32, 0.2)), work.pool[work.steps[over].at]);
    for ([_][2]f32{ .{ 2.5, 2.0 }, .{ 3.5, 4.0 }, .{ -2.5, -2.0 }, .{ 0.4, 0.0 }, .{ 1.6, 2.0 } }) |pair| {
        const made = try unary(&work, .round, try immediateOf(&work, pair[0], .f32x1));
        try testing.expectEqual(pair[1], work.pool[work.steps[made].at]);
    }
    const saturated = try unary(&work, .sat, try immediateOf(&work, 1.5, .f32x1));
    try testing.expectEqual(@as(f32, 1.0), work.pool[work.steps[saturated].at]);
    const signed = try unary(&work, .sign, try immediateOf(&work, -0.25, .f32x1));
    try testing.expectEqual(@as(f32, -1.0), work.pool[work.steps[signed].at]);
    // The SFU's functions are the device's, folded or not.
    const sine = try unary(&work, .sin, a);
    try testing.expectEqual(Tag.sin, work.steps[sine].tag);
    // The <= made a != of no order, FOrdNotEqual (182), which NIR makes of
    // two comparisons: refused, as every opcode the profile leaves out is.
    var unordered = reference.glslc_chosen;
    var at: usize = spirv.header_words;
    var changed: usize = 0;
    while (at < unordered.len) : (at += unordered[at] >> 16) {
        if (unordered[at] & 0xFFFF == @intFromEnum(spirv.Op.f_ord_less_than_equal)) {
            unordered[at] = (unordered[at] & 0xFFFF_0000) | 182;
            changed += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), changed);
    var refused: Work = .{};
    try testing.expectError(Error.Refused, throughMesa(&refused, &unordered));
}

/// glslc_branch's shader through the IR: the selections and their arms in
/// the order glslc writes them, the vector's three floats each arm
/// changes merged one by one.
const Branched = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const half = b.scalar(0.5);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const z = b.component(v, 2);
        const w = b.component(v, 3);
        const first = b.ifHolds(b.lessThan(x, half));
        const red_yes = b.add(b.mul(b.sin(b.mul(y, b.scalar(3))), half), half);
        const green_yes = b.mul(z, w);
        b.otherwise(first);
        const red_no = b.mul(y, b.scalar(0.25));
        const blue_no = b.sqrt(z);
        b.endIf(first);
        const red = b.merged(first, red_yes, red_no);
        const green = b.merged(first, green_yes, y);
        const blue = b.merged(first, z, blue_no);
        const second = b.ifHolds(b.greaterThan(w, half));
        const alpha_yes = b.add(b.pow(x, b.scalar(2)), b.scalar(0.1));
        b.otherwise(second);
        const alpha_no = b.mul(b.exp2(y), b.scalar(0.25));
        b.endIf(second);
        const alpha = b.merged(second, alpha_yes, alpha_no);
        b.color(b.vector(&.{ red, green, blue, alpha }));
    }
});

/// A selection with no false arm whose true arm is `pairs` sums and
/// sines: two ALU operations each as nir_opt_peephole_select counts them.
fn Costly(comptime pairs: usize) type {
    return ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const v = b.input(0, .f32x4);
            const x = b.component(v, 0);
            const half = b.scalar(0.5);
            const at = b.ifHolds(b.lessThan(x, half));
            var made = x;
            inline for (0..pairs) |_| made = b.sin(b.add(made, half));
            b.endIf(at);
            const chosen = b.merged(at, made, x);
            b.color(b.vector(&.{ chosen, x, x, x }));
        }
    });
}

test "through Mesa's back end, glslc's if and else: flattened as nir_opt_peephole_select flattens them" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_branch);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    // Both arms' work, one after the other: the first true arm's sine,
    // its false arm's square root (RSQRT and RECIP), the second's Pow
    // (LOG and EXP) and Exp2.
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .sin));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .rsqrt));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .recip));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .log2));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .exp2));
    // A select for each float a phi chooses: three of the vector, whose
    // fourth comes the same both ways (nir_opt_remove_phis), and the one
    // float.
    try testing.expectEqual(@as(usize, 4), stepsOf(&work, .select));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .compare));
    // Two FCMPs: each select finds the flags still holding its
    // selection's comparison, nothing in the arms having pushed others.
    var compares: usize = 0;
    for (code.words) |word| {
        var buffer: [disasm.most_text]u8 = undefined;
        const line = disasm.disasm(word, &buffer).?;
        if (std.mem.startsWith(u8, line, "fcmp")) compares += 1;
    }
    try testing.expectEqual(@as(usize, 2), compares);
    // The plan computes sums and products alone.
    var plan: Work = .{};
    try testing.expectError(Error.Body, compile(&plan, &reference.glslc_branch));
}

test "through Mesa's back end, glslc's if and else is facet's, to the word" {
    var theirs: Work = .{};
    const glslc = try throughMesa(&theirs, &reference.glslc_branch);
    var ours: Work = .{};
    const facet_made = try throughMesa(&ours, Branched.words);
    try testing.expectEqualSlices(u64, glslc.words, facet_made.words);
    try testing.expectEqual(glslc.stream().len, facet_made.stream().len);
    for (glslc.stream(), facet_made.stream()) |a, b| try testing.expectEqual(a, b);
}

test "a selection Mesa leaves a branch is refused: an arm over the limit, a sample in one, a jump elsewhere" {
    // Twelve sums and sines are 24, nir_opt_peephole_select's limit, and
    // flattened; thirteen are 26 and stay a branch. With no false arm,
    // the way past the true one is the selection's own block.
    var work: Work = .{};
    _ = try throughMesa(&work, Costly(12).words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .select));
    try testing.expectError(Error.Branches, throughMesa(&work, Costly(13).words));
    // A sample is a texture instruction, which the pass leaves in its
    // arm.
    try testing.expectError(Error.Branches, throughMesa(&work, &reference.glslc_sampled_arm));
    // The first arm's end a jump to the second arm rather than the merge.
    try testing.expectError(Error.Branches, throughMesa(&work, &comptime patched(&reference.glslc_branch, .branch, 0, 0, 41)));
    // A phi naming a block that is neither arm.
    try testing.expectError(Error.Branches, throughMesa(&work, &comptime patched(&reference.glslc_branch, .phi, 0, 3, 5)));
}

test "a call the walk does not lower, or into a set that is not GLSL.std.450, is refused" {
    var work: Work = .{};
    // Fract (10) made Asin (16), which the walk leaves out: one operand
    // each, so it is the call that is refused and not its operands.
    var sine = reference.glslc_arith;
    var calls: usize = 0;
    var at: usize = spirv.header_words;
    while (at < sine.len) : (at += sine[at] >> 16) {
        if (sine[at] & 0xFFFF == @intFromEnum(spirv.Op.ext_inst) and sine[at + 4] == @intFromEnum(spirv.Glsl.fract)) {
            sine[at + 4] = @intFromEnum(spirv.Glsl.asin);
            calls += 1;
        }
    }
    try testing.expectEqual(@as(usize, 1), calls);
    try testing.expectError(Error.Body, throughMesa(&work, &sine));
    // The set imported under another name: every call into it refused.
    var other = reference.glslc_arith;
    at = spirv.header_words;
    while (at < other.len) : (at += other[at] >> 16) {
        if (other[at] & 0xFFFF == @intFromEnum(spirv.Op.ext_inst_import)) other[at + 2] ^= 0x20;
    }
    try testing.expectError(Error.Body, throughMesa(&work, &other));
}
