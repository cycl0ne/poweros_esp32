// SPDX-License-Identifier: MIT
//! The QPU back end: a SPIR-V fragment module turned into V3D 7.1
//! instructions, and since 1.163 a vertex module too, through Mesa's
//! back end alone (`compileVertexThroughMesa`): the vertex program and
//! the coordinate program v3dv makes of one vertex shader.
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
//! compiled. `Code.uniforms` points into it too, and the driver keeps the
//! floats by value in its own `Shader` for as long as the pipeline lives
//! (since 1.191: a Code held its 32 by value before, and at 256 the
//! frames that hold a Code would be kilobytes more).
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
/// not on the stack of the call that compiles. vtn has none, its values
/// allocated by the module's bound (vtn_builder's `values`,
/// spirv_to_nir.c); the port's tables are fixed, 40 bytes an id, and 4096
/// since 1.191, where it was 256 and ran out before the steps did: a
/// GLSL operation is several ids, its loads, constants and vectors
/// beside it.
pub const most_ids = 4096;
/// The most values a body may compute. 128 since 1.152, where a call of
/// GLSL.std.450 can lower to several; 256 since 1.189, where a program
/// of several divisions by constants is more than 128.
pub const most_steps = 256;
/// The varyings the hardware carries
/// (`PhysicalDeviceLimits.max_vertex_output_components`).
pub const most_varyings = qpu.most_varyings;
/// The floats a program may read as uniforms of its own. Mesa's grow as
/// they are added (vir_get_uniform_index, vir.c:2771); a Code and a
/// Shader hold them by value, 12 bytes each. 32 until 1.191, where a
/// module of more ids and constants came to read more; 256 since, as
/// many as the steps.
pub const most_uniforms = 256;
/// The constants a module may declare, read or not, each of up to four
/// floats in `Work.pool`. vtn allocates each nir_constant as it is read;
/// 32 until 1.191, 256 since.
pub const most_constants = 256;
/// The members a block may have: one float each fills
/// `shader.MAX_PUSH_CONSTANTS_SIZE`, and a uniform buffer's are held to
/// as many.
pub const most_members = sdk.facet.shader.MAX_PUSH_CONSTANTS_SIZE / 4;
/// The structs with member Offsets a module may declare: the push
/// constants', its uniform buffers' (since 1.160), and the structs inside
/// them (since 1.161).
pub const most_blocks = 8;
/// The matrices a body may hold as values: each its columns' steps
/// (since 1.161).
pub const most_matrices = 32;
/// The uniform buffers a module may declare: v3dv's MAX_UNIFORM_BUFFERS
/// (v3dv_limits.h), the descriptor map's slots for them (since 1.160).
pub const most_ubos = 16;
/// The combined image samplers a module may declare. One is read: the
/// TMU is written once and read once here, as in every hand-written
/// program, and a module that declares one it never samples costs
/// nothing.
pub const most_samplers = 16;
/// The variables of the function's own a module may declare, each a
/// float or a vector of them; since 1.176 each float or vector of a
/// struct, an array or a matrix of the function's own counts as one, as
/// nir_split_struct_vars and nir_split_array_vars make each a variable of
/// its own. `Work.used` has a bit for each.
pub const most_locals = 32;
/// The floats and vectors the aggregates the body holds as values come to
/// all together, each held once (since 1.176).
pub const most_leaves = 256;
/// The members the structs a module declares that are no block may have
/// all together (since 1.176).
pub const most_struct_members = 64;
/// The variables of the function's own that may live in scratch memory,
/// and the bytes of it a program may have: each lane's, of which the
/// spill buffer holds sixteen for each thread (since 1.177).
pub const most_scratch_variables = 8;
pub const most_scratch = 1024;

/// The variables of the function's own an access chain reaches at an
/// index the body computes, of more elements than
/// nir_lower_indirect_derefs_to_if_else_trees takes (v3dv_pipeline.c:
/// 435-436): nir_lower_vars_to_scratch moves each into scratch memory,
/// every load and store of it a load_scratch and a store_scratch
/// (vir.c:2041-2044). Each is given its place in the order an index was
/// first computed into it, as the pass finds them (nir_lower_scratch.c:
/// 155-185) and places them (:247-258), its bytes the natural layout's
/// (`scratchFloats`). The walk finds one where it reaches such an index,
/// and is begun again with it here (`readStage`; since 1.177).
pub const Scratch = struct {
    ids: [most_scratch_variables]u16 = undefined,
    bytes: [most_scratch_variables]u16 = undefined,
    /// One the program is found to load nothing of, once
    /// nir_opt_copy_prop_vars has taken what it can: nir_remove_dead_variables
    /// takes it out, and its stores (nir_remove_dead_variables.c:66-90,
    /// :110-170), before nir_lower_vars_to_scratch places what is left
    /// (`deadScratch`). It has no bytes, and its stores are made and then
    /// dropped (since 1.177).
    dead: [most_scratch_variables]bool = undefined,
    count: u32 = 0,
    /// The variables of the function's own an access chain reaches at
    /// indexes the body computes of two or fewer elements, of whose loads
    /// and stores nir_lower_indirect_derefs_to_if_else_trees makes if-else
    /// trees (`local_tree`): nir_lower_vars_to_ssa takes them in the loop
    /// of passes v3dv runs after it (v3dv_pipeline.c:432-439), not in the
    /// one before, and puts the phis it gives them at a merge before those
    /// the first gave the others there (`merge`). The walk finds one where
    /// it reaches a load or a store of it through such an index, and is
    /// begun again with it here (since 1.178).
    trees: [most_scratch_variables]u16 = undefined,
    tree_count: u32 = 0,

    /// Where the variable `id` is in scratch, or null where it is not.
    fn placeOf(scratch: *const Scratch, id: u16) ?u16 {
        var at: u16 = 0;
        for (scratch.ids[0..scratch.count], scratch.bytes[0..scratch.count], scratch.dead[0..scratch.count]) |each, bytes, dead| {
            if (each == id) return if (dead) 0 else at;
            if (!dead) at += bytes;
        }
        return null;
    }

    /// Which of the variables `id` is.
    fn indexOf(scratch: *const Scratch, id: u16) ?u8 {
        for (scratch.ids[0..scratch.count], 0..) |each, k| {
            if (each == id) return @intCast(k);
        }
        return null;
    }

    fn size(scratch: *const Scratch) u32 {
        var bytes: u32 = 0;
        for (scratch.bytes[0..scratch.count], scratch.dead[0..scratch.count]) |each, dead| {
            if (!dead) bytes += each;
        }
        return bytes;
    }

    fn same(scratch: *const Scratch, other: *const Scratch) bool {
        if (scratch.count != other.count or scratch.tree_count != other.tree_count) return false;
        for (0..scratch.count) |k| {
            if (scratch.ids[k] != other.ids[k] or scratch.dead[k] != other.dead[k]) return false;
        }
        return std.mem.eql(u16, scratch.trees[0..scratch.tree_count], other.trees[0..other.tree_count]);
    }

    /// Whether `id` is one of `trees`.
    fn isTree(scratch: *const Scratch, id: u16) bool {
        return std.mem.indexOfScalar(u16, scratch.trees[0..scratch.tree_count], id) != null;
    }
};

/// The levels a deref of a float in scratch may have below its variable.
pub const most_levels = 8;
/// The scratch pointers a program may make.
pub const most_pointer_paths = 64;

/// A deref of one float of a variable in scratch, as
/// nir_opt_copy_prop_vars and nir_opt_dead_write_vars compare two
/// (`comparePaths`): the variable, then each array's element, matrix's
/// column, struct's member and vector's float on the way down, a constant
/// or the step of the index the body computes. Both passes run in v3d's
/// loop of passes (nir_to_vir.c:2249-2250) while the variable is still
/// one of derefs, before nir_lower_vars_to_scratch (since 1.177).
pub const Path = struct {
    variable: u8 = 0,
    count: u8 = 0,
    /// The levels that are an index the body computes, a bit each.
    computed: u8 = 0,
    levels: [most_levels]u16 = undefined,

    fn push(path: *Path, level: u16, computed: bool) Error!void {
        if (path.count == most_levels) return Error.Storage;
        path.levels[path.count] = level;
        if (computed) path.computed |= @as(u8, 1) << @intCast(path.count);
        path.count += 1;
    }

    fn isComputed(path: *const Path, k: usize) bool {
        return path.computed >> @intCast(k) & 1 != 0;
    }
};

/// nir_opt_copy_prop_vars's copies (nir_opt_copy_prop_vars.c:1063-1457)
/// of the floats of the variables in scratch: each one a load or a store
/// has given a value, by the step whose `Path` names it, and the float
/// that is its value. Mesa's entry is a vector's, its floats each a
/// component of it, and a load of one takes what of it there is
/// (load_from_ssa_entry_value, :747-850): one of each float is the same
/// (since 1.177).
pub const Copies = struct {
    paths: [most_steps]u16 = undefined,
    values: [most_steps]u16 = undefined,
    count: u16 = 0,

    fn remove(copies: *Copies, k: usize) void {
        copies.count -= 1;
        copies.paths[k] = copies.paths[copies.count];
        copies.values[k] = copies.values[copies.count];
    }
};
/// How deep selections may be nested in each other's arms.
pub const most_nesting = 8;
/// One for each float a step answers.
pub const most_slots = 4 * most_steps;
/// Instructions chosen, before they are words.
pub const most_acts = 160;
/// The words a program may come to. Mesa's qpu_insts grow as the
/// program is packed (v3d_vir_to_qpu, vir_to_qpu.c); 256 until 1.191,
/// where 256 steps lowered and their uniforms' loads came to more, and
/// 4096 since, 32 KiB of `Work.code`.
pub const most_words = 4096;

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
    /// A type other than a 32-bit float and its vectors of 2 to 4, or
    /// since 1.165 a 32-bit integer and its vectors; or an integer where
    /// none is taken: a varying, an attribute or a colour, which want
    /// flat interpolation and integer formats this back end has not got.
    Type,
    /// A variable in a storage class this back end has no answer for:
    /// a uniform, a variable of the function's own that is no float, no
    /// integer, no bool, no vector of them and no array, struct or matrix
    /// of those, a sampler of anything but a 2D texture. Since 1.176 also
    /// an element of an aggregate of the function's own at an index the
    /// body computes, and a load of the whole of one that holds a bool.
    /// Also the plan's answer to a module that reads its push constants,
    /// which only Mesa's back end compiles.
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
    /// More than one basic block where it is not what the walk takes: a
    /// loop of no trip count nir_loop_analyze finds, over
    /// nir_opt_loop_unroll's limits, asking DontUnroll, or with a break, a
    /// continue or a loop in it (since 1.172 a loop Mesa unrolls is read
    /// unrolled); a branch of no merge; a selection kept a branch (since
    /// 1.171) in another's arm or with one in its arm, a ninth, a phi of
    /// bools, the colour stored or a pixel dropped in its arm, or one in a
    /// vertex program; selections nested deeper than `most_nesting`
    /// (since 1.154 a selection whose arms are within its limit is read,
    /// as Mesa flattens it; since 1.156 one nested in another's arm).
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
    /// More values live at once than there are registers. The plan does
    /// not spill; Mesa's back end spills through the TMU into the
    /// pipeline's spill buffer (vir_register_allocate.c:761-1018; the
    /// buffer since 1.177), and answers this where even that fails.
    Registers,
    /// More instructions than the code buffer holds.
    TooLong,
    /// More than one sample where the plan compiles the program, as every
    /// hand-written program writes the TMU once and reads it once; or a
    /// sampler one sample compares through and another does not, whose
    /// one state cannot be both (since 1.173 Mesa's back end takes
    /// several samples, of one sampler or of several).
    Samplers,
    /// More combined image samplers *declared* than `most_samplers`.
    /// Not a limit of the device - a module may declare many and sample
    /// one, and that one is all this device has to do - but of the table
    /// that holds where each is bound. Raising `most_samplers` raises it.
    /// Since 1.160 also more uniform buffers than `most_ubos`, or more
    /// blocks than `most_blocks`.
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
    /// What its image's coordinate names (since 1.179).
    dim: SamplerDim = .flat,
};

/// What a sampled image's coordinate names, as a nir_tex_instr's
/// sampler_dim and is_array have it, and so which of the TMU's registers
/// a sample writes (handle_tex_src, v3d_tex.c:99-127; since 1.179).
pub const SamplerDim = enum(u8) {
    /// GLSL_SAMPLER_DIM_2D: s and t, in TMUS and TMUT.
    flat,
    /// GLSL_SAMPLER_DIM_2D arrayed: s and t, and the layer in TMUI as a
    /// float, which the TMU rounds.
    layers,
    /// GLSL_SAMPLER_DIM_3D: s, t and r, r in TMUR.
    volume,
    /// GLSL_SAMPLER_DIM_CUBE: a direction, normalized
    /// (nir_normalize_cubemap_coords, v3dv_pipeline.c:406), its third
    /// float in TMUR and the lookup started at TMUSCM rather than TMUS
    /// (v3d_tex.c:380-381). A cube of an array is refused, as
    /// SampledCubeArray is not in the profile.
    cube,

    /// glsl_get_sampler_dim_coordinate_components and the layer
    /// (spirv_to_nir.c:3280-3283): the floats of the coordinate a sample
    /// reads.
    pub fn components(dim: SamplerDim) u8 {
        return if (dim == .flat) 2 else 3;
    }
};

/// What this back end takes. It is narrower than `spirv.facet_profile` on
/// purpose: the library must never refuse words a later device could run,
/// and this list is what *this* device can run today. It grows a family
/// at a time - discard and samplers first.
pub const profile: spirv.Profile = .{
    // ImageQuery, which an image's size and levels need (since 1.181).
    .capabilities = &.{ .shader, .image_query },
    .opcodes = &.{
        .capability,                   .memory_model,                   .entry_point,                    .execution_mode,
        .decorate,                     .type_void,                      .type_float,                     .type_vector,
        .type_pointer,                 .type_function,                  .constant,                       .constant_composite,
        .variable,                     .function,                       .label,                          .load,
        // What a real toolchain writes around the instructions: an
        // extended set imported but not used (`ext_inst` is absent, so a
        // call into one is still refused) and the names and source
        // strings glslc always emits. None of them is computation.
        .ext_inst_import,              .source,                         .source_extension,               .name,
        .member_name,                  .store,                          .composite_extract,              .composite_construct,
        .f_add,                        .f_mul,                          .vector_times_scalar,            .returns,
        .function_end,                 .type_image,                     .type_sampled_image,             .image_sample_implicit_lod,
        // A pixel dropped where a float is less or greater than another,
        // in the one shape a conditional discard has in SPIR-V: the
        // comparison, a selection whose true block is `OpKill` alone, and
        // the merge block the body goes on in (since 1.139). An `OpKill`
        // in any other place is refused by name, `Error.Discards`.
        .kill,                         .type_bool,                      .f_ord_less_than,                .f_ord_greater_than,
        .selection_merge,              .branch_conditional,
        // The integer type a constant texel offset is declared with,
        // first taken so that such a module was refused for the operand
        // (`Error.Operands`) and since 1.180 read as the offset P2 carries
        // (`profile.image_operands`). Since 1.138 an integer is also what
        // an access chain into the push constants is indexed with, and
        // since 1.165 a value of its own.
                    .type_int,
        // The push constants: a block of floats and vectors of them, one
        // member read at a time through an access chain whose indexes
        // are constants (since 1.138); then arrays, structs and matrices
        // in a block, and the matrix arithmetic vtn lowers to columns of
        // vector arithmetic (since 1.161).
                              .type_struct,
        .member_decorate,              .access_chain,                   .type_array,                     .type_matrix,
        .matrix_times_vector,          .vector_times_matrix,            .matrix_times_matrix,            .matrix_times_scalar,
        .transpose,                    .outer_product,
        // A depth compared with a reference, the TMU told it through
        // TMUDREF (v3d_tex.c:155-157; since 1.143).
                         .image_sample_dref_implicit_lod,
        // The float arithmetic, a call of GLSL.std.450 among it, lowered
        // as v3dv's NIR options have Mesa lower it; and a vector's floats
        // named by a shuffle, or a varying's one float by an access chain,
        // which compute nothing (since 1.152).
        .f_sub,
        .f_negate,                     .f_div,                          .dot,                            .ext_inst,
        // The shuffle, then the other comparisons glslc writes and a float
        // chosen by one (since 1.153), then a selection's arms, their
        // values chosen at its merge and one float of a vector replaced
        // (since 1.154).
        .vector_shuffle,               .f_unord_not_equal,              .f_ord_less_than_equal,          .f_ord_greater_than_equal,
        .select,                       .f_ord_equal,                    .composite_insert,               .phi,
        .branch,
        // Then bools of bools and the unordered comparisons, as glslc
        // writes &&, || and ! (since 1.157).
                              .logical_and,                    .f_unord_greater_than_equal,     .f_unord_greater_than,
        .logical_or,                   .f_unord_less_than,              .f_unord_less_than_equal,        .logical_not,
        // A storage buffer's last member, read at constant indexes
        // (since 1.164).
        .type_runtime_array,
        // 32-bit integers: their arithmetic, bits and comparisons, and
        // their conversions to and from floats, as ntq_emit_alu emits
        // them (since 1.165). The divisions and remainders v3d has
        // nir_lower_idiv lower to a sequence of float and integer steps
        // (since 1.187).
                  .i_add,                          .i_sub,                          .i_mul,
        .u_div,                        .s_div,                          .u_mod,                          .s_rem,
        .s_mod,                        .s_negate,                       .shift_left_logical,             .shift_right_logical,
        .shift_right_arithmetic,       .bitwise_and,                    .bitwise_or,                     .bitwise_xor,
        .not,                          .bitcast,                        .convert_f_to_s,                 .convert_f_to_u,
        .convert_s_to_f,               .convert_u_to_f,                 .i_equal,                        .i_not_equal,
        .s_less_than,                  .s_less_than_equal,              .s_greater_than,                 .s_greater_than_equal,
        .u_less_than,                  .u_less_than_equal,              .u_greater_than,                 .u_greater_than_equal,
        .logical_equal,                .logical_not_equal,
        // A storage buffer's atomics, as vtn makes them ssbo_atomic and
        // ssbo_atomic_swap, a load_ssbo and a store_ssbo, and the barriers
        // their memory semantics and OpMemoryBarrier ask for
        // (vtn_handle_atomics, spirv_to_nir.c:4288-4480; since 1.169).
                     .memory_barrier,                 .atomic_load,
        .atomic_store,                 .atomic_exchange,                .atomic_i_increment,             .atomic_compare_exchange,
        .atomic_compare_exchange_weak, .atomic_i_decrement,             .atomic_i_add,                   .atomic_i_sub,
        .atomic_s_min,                 .atomic_u_min,                   .atomic_s_max,                   .atomic_u_max,
        .atomic_and,                   .atomic_or,                      .atomic_xor,
        // A loop, unrolled as nir_opt_loop_unroll unrolls it (since
        // 1.172).
                            .loop_merge,
        // A sample at a level the program gives, NIR's txl (since 1.180);
        // and a sampled image's image, its size at a level and its levels,
        // NIR's txs and query_levels (since 1.181); and a texel of the
        // image at a level, NIR's txf (since 1.182).
        .image,                        .image_fetch,                    .image_query_size_lod,           .image_query_levels,
        .image_sample_explicit_lod,    .image_sample_dref_explicit_lod,
    },
    .storage_classes = &.{ .input, .output, .function, .uniform_constant, .push_constant, .uniform },
    .image_dims = &.{ .dim_2d, .dim_3d, .cube },
    // A bias, a level and a constant texel offset, TMUB's and P2's
    // (handle_tex_src, v3d_tex.c:129-170; since 1.180); and a gradient,
    // which nir_lower_tex's lower_txd makes a level (vir.c:802; since
    // 1.183). An offset the program computes wants ImageGatherExtended.
    .image_operands = &.{ .bias, .lod, .grad, .const_offset },
    // The vertex stage since 1.163 (docs/facet-vulkan10.md item 60).
    .stages = &.{ .fragment, .vertex },
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
    /// A varying, interpolated over the triangle; in a vertex program an
    /// attribute, read from the VPM (since 1.163).
    input,
    /// Floats the draw hands over, one uniform each.
    constant,
    /// How a float compares with another, `at` a `Comparison`: a bool,
    /// which a `discard` reads (since 1.139) and a `select` (since 1.153);
    /// or an integer with another, or a bool with another (since 1.165).
    compare,
    /// `a` and `b`, `a` or `b`, or not `a`, `at` a `Logic`: a bool of
    /// bools, NIR's iand, ior and inot, which v3d emits as AND, OR and NOT
    /// of the 0 and ~0 a bool is (nir_to_vir.c:1683-1694; since 1.157).
    logic,
    /// `b` where `a`, a bool, holds, and `from[0]` where it does not:
    /// NIR's b32csel (nir_to_vir.c:1740-1745; since 1.153). One float, or
    /// one bool where the two are bools (since 1.157).
    select,
    /// 1.0 where `a` is less than `b` and 0.0 where not: NIR's slt, which
    /// GLSL.std.450's Step is made of (nir_to_vir.c:1710-1723; since
    /// 1.153). `b` may be one float, read for each of `a`'s.
    set_less,
    /// The pixel dropped where `a`, a bool, holds: what
    /// nir_opt_peephole_select makes of a selection whose block is a
    /// terminate alone (`discard_ok`, nir_to_vir.c:2293), terminate_if.
    discard,
    /// Floats of the push constants, one uniform each: `at` is the word
    /// the first of them is (its byte offset over four). The words are
    /// the draw's, read when the uniform stream is written (since 1.138).
    push,
    /// Floats of a uniform buffer, NIR's load_ubo of a constant offset:
    /// `b` is the buffer's slot in v3dv's descriptor map (`Work.ubos`)
    /// and `at` the byte offset of the first float. v3d reads them
    /// through unifa (ntq_emit_load_unifa, nir_to_vir.c:3299; since
    /// 1.160).
    ubo,
    /// Floats of a storage buffer, NIR's load_ssbo of a constant offset,
    /// as `ubo` holds them: `b` the buffer's slot, `at` the byte offset.
    /// Where the program writes no buffer, or the memory is NonWritable,
    /// nir_opt_access has made the load ACCESS_NON_WRITEABLE and
    /// CAN_REORDER (nir_opt_access.c:250-293), `non_writeable`, and v3d
    /// reads it through unifa as it reads a uniform buffer
    /// (ntq_emit_load_unifa, nir_to_vir.c:3338-3343; since 1.164); else
    /// through the TMU (since 1.168).
    ssbo,
    /// Floats of a uniform buffer at an offset the program computes,
    /// NIR's load_ubo of an offset no constant: `a` is the step of the
    /// byte offset, an integer, and `b` the buffer's slot, as a `ubo`'s.
    /// Where the offset is the same in every lane v3d reads them through
    /// unifa all the same, the offset added to the buffer's address
    /// (ntq_emit_load_unifa, nir_to_vir.c:3315-3317, :3348, :3398-3400,
    /// :3441-3444; since 1.166); where it is not, through the TMU's
    /// general lookup (ntq_emit_tmu_general, :502-725; `lanes`, since
    /// 1.167).
    ubo_indirect,
    /// Floats of a storage buffer at an offset the program computes, as
    /// `ubo_indirect` holds them (since 1.166).
    ssbo_indirect,
    /// NIR's store_ssbo: the floats of `a` written into a storage buffer,
    /// `b` its slot and `at` the byte offset of the first, or, where
    /// `from[0]` is no `none`, at the offset that step computes. v3d
    /// writes them through the TMU (ntq_emit_tmu_general,
    /// nir_to_vir.c:502-725; since 1.168). It makes no value.
    ssbo_store,
    /// NIR's ssbo_atomic and ssbo_atomic_swap: `atomic` the operation, on
    /// the 32-bit word of a storage buffer at `at`, `b` its slot, or at
    /// the offset `from[0]` computes where it is no `none`; `a` the
    /// operand, and `from[1]` the second, cmpxchg's, where it is no
    /// `none`: the first is the comparator then, as vtn orders them
    /// (fill_common_atomic_sources, spirv_to_nir.c:3698-3702). Its value
    /// is the word as it was. v3d writes the operands into TMUD and reads
    /// the word back (ntq_emit_tmu_general, nir_to_vir.c:502-725; since
    /// 1.169).
    ssbo_atomic,
    /// NIR's load_scratch, a float of a variable of the function's own
    /// that nir_lower_vars_to_scratch moved into scratch memory (vir.c:
    /// 2041-2044; since 1.177), at `at`: the byte offset already times
    /// V3D_CHANNELS, as v3d_nir_lower_scratch makes it
    /// (v3d_nir_lower_scratch.c:31-43), from spill_base, the lane's own
    /// place in the spill buffer. v3d reads it through the TMU
    /// (ntq_emit_tmu_general, nir_to_vir.c:583-586). One load of it is
    /// never taken for another, which load_scratch's flags do not let
    /// nir_opt_cse do (no CAN_REORDER, nir_intrinsics.py:1429).
    scratch,
    /// The same at the offset the step `a` computes.
    scratch_indirect,
    /// NIR's store_scratch: the float `a` written at `at`, or at the
    /// offset `from[0]` computes where it is no `none`, as `scratch`
    /// reads it. It makes no value.
    scratch_store,
    /// NIR's barrier, of memory: what the TMU has been given is flushed
    /// before anything after it is (nir_to_vir.c:3857-3861; since 1.169).
    /// It makes no value.
    barrier,
    /// 32-bit integers, or floats made integers or integers floats: NIR's
    /// integer ALU, `at` an `Integer`, each word of `a` (and `b`) one VIR
    /// operation as ntq_emit_alu emits it (nir_to_vir.c:1421-1806; since
    /// 1.165). A value's words are a float's or an integer's as the
    /// operation that made it says; `kind` is how many there are.
    integer,
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
    /// A texel, read through the TMU. Its four floats are not four
    /// registers: the TMU hands back two words of two half-floats each,
    /// and `Work.slot_half` says which half of which word a float is.
    sample,
    /// A depth compared with `b`, the reference, at `a`: one float, what
    /// passed, the first half of the TMU's first word. Mesa's back end
    /// alone compiles it (`compileVir`; since 1.143).
    sample_compared,
    /// The size of the image `at` samples at the level `from[0]`, an
    /// integer: NIR's txs, which v3d computes from the uniforms the draw
    /// writes of the view (ntq_emit_txs, nir_to_vir.c:914-960). `kind` is
    /// nir_tex_instr_dest_size's (since 1.181).
    texture_size,
    /// How many levels the view `at` samples has, NIR's query_levels: a
    /// uniform the draw writes (ntq_emit_tex, nir_to_vir.c:972-975; since
    /// 1.181).
    texture_levels,
    /// A vertex program's float `a` written to the VPM at `at`, one
    /// float as v3d_nir_store_output stores each (v3d_nir_lower_io.c:
    /// 72-92): a varying where the fragment program reads it, or one of
    /// the fixed-function outputs the position makes (since 1.163).
    output,
    /// A word of the draw's viewport, `at` which: its x scale, y scale,
    /// z offset or z scale, QUNIFORM_VIEWPORT_* in that order, which v3dv
    /// writes as the uniform stream is (v3dv_uniforms.c:526-552; since
    /// 1.163).
    viewport,
    /// A vertex program's value of the draw's, `at` a `SystemValue`: one
    /// of the VPM's three before the attributes, or the first vertex, a
    /// uniform (since 1.192).
    system,
    /// `a` rounded to the nearest whole number, the even one at a half,
    /// as a 32-bit integer: NIR's f2i32 of fround_even, which v3d emits
    /// as FTOIN (ntq_emit_alu, nir_to_vir.c:1465-1472; since 1.163).
    round_to_int,
    /// A selection kept a branch, the nir_if nir_opt_peephole_select did
    /// not flatten (since 1.171): `a` its condition. The steps after it
    /// to the `begin_else` are its true arm, those after that to the
    /// `end_if` its false arm, each a block of its own.
    begin_if,
    begin_else,
    end_if,
    /// A float the two ways into a kept selection's merge bring, a phi as
    /// nir_lower_phis_to_scalar leaves it (since 1.171): `a` and
    /// `part[0]` the true arm's float, `b` and `part[1]` the false arm's,
    /// `from[0]` the selection's condition.
    phi,
};

/// What a `compare` asks, as NIR has SPIR-V's ordered comparisons and its
/// unordered not-equal (vtn_alu.c:369-381): flt, flt swapped, feq, fneu,
/// fge and fge swapped. `less` and `greater` are 0 and 1, as they were.
pub const Comparison = enum(u32) {
    less,
    greater,
    equal,
    not_equal,
    greater_equal,
    less_equal,
    /// Of 32-bit integers, or of bools, which are 0 and ~0 (since 1.165):
    /// NIR's ieq, ine, ilt, ige, ult and uge, which vtn makes of SPIR-V's
    /// with the two swapped where it has no comparison of its own
    /// (vtn_nir_alu_op_for_spirv_opcode, vtn_alu.c:388-396).
    int_equal,
    int_not_equal,
    int_less,
    int_greater_equal,
    uint_less,
    uint_greater_equal,
};

/// What a `logic` makes of its bools.
pub const Logic = enum(u32) { iand, ior, inot };

/// What an `integer` step does, by NIR's name for it (since 1.165): the
/// arithmetic, the bits, and the conversions to and from floats. NIR's
/// iclamp and uclamp are a max and a min, and isign a max and a min too
/// (`lower_isign`, nir_opt_algebraic.py:2836).
pub const Integer = enum(u32) {
    iadd,
    isub,
    imul,
    ineg,
    iabs,
    imin,
    imax,
    umin,
    umax,
    ishl,
    ishr,
    ushr,
    iand,
    ior,
    ixor,
    inot,
    f2i32,
    f2u32,
    i2f32,
    u2f32,
    /// A bool made a float, 1.0 or 0.0: what nir_opt_algebraic makes of
    /// a bcsel of the two (:2080-2083), which v3d emits as the AND of the
    /// bool's ~0 or 0 and 1.0 (nir_to_vir.c:1521-1523; since 1.178).
    b2f32,
    /// A bool made an integer, 1 or 0: nir_opt_idiv_const's nir_b2iN
    /// (nir_opt_idiv_const.c:37-39, :75), the AND of the bool's ~0 or 0
    /// and 1 (nir_to_vir.c:1524-1528; since 1.188).
    b2i32,

    /// Whether it reads one value, not two.
    pub fn unary(op: Integer) bool {
        return switch (op) {
            .ineg, .iabs, .inot, .f2i32, .f2u32, .i2f32, .u2f32, .b2f32, .b2i32 => true,
            else => false,
        };
    }

    /// Whether its two may be either way round (NIR_OP_IS_2SRC_COMMUTATIVE).
    pub fn commutes(op: Integer) bool {
        return switch (op) {
            .iadd, .imul, .imin, .imax, .umin, .umax, .iand, .ior, .ixor => true,
            else => false,
        };
    }
};

/// Whether a step is a bool: a comparison, a bool of bools, or one of two
/// bools chosen.
pub fn isBool(work: *const Work, at: u16) bool {
    const each = work.steps[at];
    return switch (each.tag) {
        .compare, .logic => true,
        .select => isBool(work, each.b),
        .phi => isBool(work, each.a),
        else => false,
    };
}

/// Which half of a packed pair of half-floats a float is, where it is one
/// at all. The TMU's two words are the only ones here.
pub const Half = enum { none, low, high };

/// An `ssbo_atomic`'s operation: NIR's nir_atomic_op, of the ones vtn
/// makes of a storage buffer's integer atomics (translate_atomic_op,
/// spirv_to_nir.c; since 1.169). ISub is iadd of the operand negated,
/// and IIncrement and IDecrement iadd of 1 and -1.
pub const Atomic = enum(u8) { iadd, imin, umin, imax, umax, iand, ior, ixor, xchg, cmpxchg };

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
    /// `ssbo`, `ssbo_indirect`: the load's ACCESS_NON_WRITEABLE, which
    /// vtn gives a load through a member or of a variable decorated
    /// NonWritable (vtn_variables.c:397, :512, :1666-1667; since 1.168).
    non_writeable: bool = false,
    /// An `ssbo_atomic`'s operation (since 1.169).
    atomic: Atomic = .iadd,
    /// A `sample`'s or a `sample_compared`'s level of detail, its bias or
    /// its level `from[0]` (since 1.180).
    lookup: Lookup = .implicit,
    /// A sample's ConstOffset, in texels along s, t and r, each -8 to 7
    /// (since 1.180).
    offsets: [3]i8 = @splat(0),
};

/// How a sample's level of detail is found, a nir_tex_instr's op: from
/// the quad's derivatives, NIR's tex; from them and a bias, txb
/// (nir_tex_src_bias); or at a level the program gives, txl
/// (nir_tex_src_lod). vtn makes each of the image operands Bias and Lod
/// (vtn_handle_texture, spirv_to_nir.c:3423-3438; since 1.180).
pub const Lookup = enum(u8) {
    implicit,
    bias,
    lod,
    /// A texel of the image at a level, NIR's txf with its lod source: an
    /// integer coordinate and level, and no sampler state
    /// (nir_tex_instr_need_sampler, nir.c; since 1.182).
    fetch,

    /// nir_tex_instr_has_implicit_derivative: whether the quad's helper
    /// pixels are needed for the coordinate.
    pub fn derived(lookup: Lookup) bool {
        return lookup == .implicit or lookup == .bias;
    }
};

/// Where a step is: in no arm of a kept selection, 0, or in one of its
/// arms, the true one's odd and the false one's the even after it, the
/// first kept selection's 1 and 2 (since 1.171).
pub const Region = u8;

/// A selection kept a branch, as `read` leaves it for the list to lay
/// out (since 1.171): the steps of its arms, the true arm's first where
/// the module had it second, and its three marks put down around them.
pub const Kept = struct {
    from: u16,
    split: u16,
    to: u16,
    false_first: bool,
    marks: [3]u16,
};

/// The most selections a program keeps branches.
pub const most_kept = 8;

/// A varying the module declares.
/// How a fragment program's varying is interpolated: vtn's
/// var->data.interpolation of its decoration (vtn_variables.c:1370-1374),
/// none of either smooth. Since 1.190.
pub const Interpolation = enum(u2) { smooth, flat, noperspective };

pub const Input = struct {
    location: u32,
    kind: Kind,
    /// Its `Flat` or `NoPerspective`, a fragment program's (since 1.190).
    interpolation: Interpolation = .smooth,
    /// Which varying its first float is: the floats of every lower
    /// location, summed. The vertex function writes them in that order,
    /// and `ldvary` reads them in it (`_play.zig`'s `writeRecord`). A
    /// vertex program's attribute: which float of the VPM's input its
    /// first is, the floats every lower driver location reads summed
    /// (ntq_emit_load_input, nir_to_vir.c:2960-2977).
    first: u32,
    /// The step that loaded it, or `none` where the body never reads it -
    /// its varyings are still taken, because the hardware hands them over
    /// in order and one cannot be stepped over.
    step: u16 = none,
    /// A vertex program's attribute: the floats of it the program reads,
    /// a bit each, which are what nir_lower_io_vars_to_scalar and
    /// nir_opt_dce leave of it (v3d_nir_lower_vs_early, vir.c:1093-1106).
    live: u8 = 0,
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
    /// The uniform stream, in the order the program reads it: `Work`'s, as
    /// the words are, for the driver to copy before it compiles again
    /// (since 1.191; by value before).
    uniforms: []const Word,
    uniform_count: u32,
    /// The combined image samplers the program reads, by unit. The draw
    /// looks each up in its descriptor sets and writes the `.texture` and
    /// `.sampler` words of the stream of that unit from what it finds. A
    /// unit is a set and binding the program samples, numbered as
    /// descriptor_map_add numbers the texture map (v3dv_pipeline.c:
    /// 516-560): in the order the program first reads each (since 1.173;
    /// one sampler before).
    samplers: [most_samplers]Sampler = undefined,
    sampler_count: u32 = 0,
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
    /// The program writes through the TMU - a storage buffer, or a spill
    /// - so the job's caches are to be cleaned after it: prog_data's
    /// tmu_dirty_rcl (vir.c:1048), which v3dv gathers into the job's
    /// (v3dvx_cmd_buffer.c:2559-2564; since 1.168).
    tmu_dirty_rcl: bool = false,
    /// The bytes of the spill buffer each thread of each QPU needs, its
    /// spills' and its scratch's (prog_data's spill_size, v3d_set_prog_data,
    /// vir.c:1033): what the pipeline's buffer is made for
    /// (pipeline_check_spill_size, v3dv_pipeline.c:1669-1708; since 1.177).
    spill_size: u32 = 0,
    /// The varyings that are flat and that are interpolated without
    /// perspective, a bit each: prog_data's flat_shade_flags and
    /// noperspective_flags of the first 24 (v3d_set_fs_prog_data_inputs,
    /// vir.c:985-1003), which the draw writes as v3dv does
    /// (cmd_buffer_emit_varyings_state, v3dvx_cmd_buffer.c:1793-1831;
    /// since 1.190).
    flat_shade_flags: u32 = 0,
    noperspective_flags: u32 = 0,
    /// A vertex program's, for its shader record and its attribute
    /// records (`v3d_vs_prog_data`, v3d_vs_set_prog_data, vir.c:860-936;
    /// since 1.163): the floats of each attribute it reads by driver
    /// location and each one's location; its VPM segment in sectors of
    /// eight, input and output shared; and whether it starts in its last
    /// thread section, which one that has no thread switch does
    /// (single_seg, !c->last_thrsw).
    vertex: VertexProgram = .{},

    /// The uniform stream, in the order the program reads it.
    pub fn stream(code: *const Code) []const Word {
        return code.uniforms[0..code.uniform_count];
    }

    /// The combined image samplers, by unit.
    pub fn sampled(code: *const Code) []const Sampler {
        return code.samplers[0..code.sampler_count];
    }
};

/// One word of the uniform stream. A program of its own reads floats it
/// holds; one that samples also reads the TMU's two configuration
/// parameters, which only a draw can fill in - the texture bound to it
/// and the sampler beside it are not known until then.
pub const Word = union(enum) {
    float: f32,
    /// The state of a unit's texture, as a sample's first `wrtmuc` takes
    /// it: Mesa's QUNIFORM_TMU_CONFIG_P0, the unit in its high bits
    /// (v3d_tex.c:297-303), which the draw writes as the texture's state
    /// there (write_tmu_p0, v3dv_uniforms.c:139-185). `Code.sampled` says
    /// where each unit is bound (since 1.173).
    texture: u8,
    /// The state of a unit's sampler, as the second takes it
    /// (QUNIFORM_TMU_CONFIG_P1, v3d_tex.c:341-348; write_tmu_p1,
    /// v3dv_uniforms.c:187-232).
    sampler: SamplerWord,
    /// A word of the push constants, by its place among them (the byte
    /// offset over four): what Mesa's QUNIFORM_UNIFORM is in v3dv, filled
    /// from the command buffer's push constants as the stream is written
    /// (v3dv_uniforms.c:513, v3dv_write_uniforms).
    push: u32,
    /// Where a uniform buffer's floats are, `offset` bytes into the
    /// buffer bound at `set`, `binding`: Mesa's QUNIFORM_UBO_ADDR, whose
    /// unit is the descriptor map's slot, looked up here already, and
    /// which the draw writes as the buffer's address and its descriptor's
    /// offsets plus this (write_ubo_ssbo_uniforms, v3dv_uniforms.c:
    /// 235-350; since 1.160).
    ubo: UboAddress,
    /// A word of the draw's viewport (`Viewport`; since 1.163).
    viewport: Viewport,
    /// The first vertex the draw numbers its vertices from, which the
    /// VPM's vertex id counts from (`vir.Uniform.first_vertex`; since
    /// 1.192).
    first_vertex,
    /// Where a storage buffer is, bound at `set`, `binding`: Mesa's
    /// QUNIFORM_SSBO_OFFSET, which the draw writes as the buffer's address
    /// and its descriptor's offsets, the program adding the offset it
    /// reads at (write_ubo_ssbo_uniforms, v3dv_uniforms.c:235-350; since
    /// 1.164).
    ssbo: StorageAddress,
    /// Where the pipeline's spill buffer is, and the bytes of it each
    /// thread has: QUNIFORM_SPILL_OFFSET and QUNIFORM_SPILL_SIZE_PER_THREAD,
    /// which v3dv writes as the buffer's address and the size it was made
    /// for (v3dv_uniforms.c:663-672). The program works out its lanes'
    /// place in it from them (v3d_setup_spill_base, `allocate.setupSpillBase`;
    /// since 1.177).
    spill_offset,
    spill_size_per_thread,
    /// A size of the view a unit samples, or its levels: Mesa's
    /// QUNIFORM_TEXTURE_WIDTH, _HEIGHT, _DEPTH, _ARRAY_SIZE and _LEVELS,
    /// which v3dv writes from the view's extent, layers and levels
    /// (get_texture_size_from_image_view, v3dv_uniforms.c:378-414; since
    /// 1.181).
    texture_size: TextureSize,
};

/// A `.texture_size` word: the unit, and which of its view's sizes.
pub const TextureSize = struct {
    unit: u8 = 0,
    field: Field = .width,

    pub const Field = enum(u8) { width, height, depth, array_size, levels };
};

/// A `.sampler` word: the unit, and the bits the program sets of the
/// sampler's state, `per_pixel_mask` where helper pixels skip the sample
/// (v3d_tex.c:313-321; since 1.167), else none.
pub const SamplerWord = struct { unit: u8 = 0, bits: u32 = 0 };

/// TMU Config Parameter 1's Per-pixel mask enable (v3d_packet.xml:1544):
/// the lookup made for the pixels the quad covers alone, its helper
/// pixels left out (since 1.167).
pub const per_pixel_mask: u32 = 1 << 2;

/// What a `.viewport` step reads, as v3dv writes QUNIFORM_VIEWPORT_X_SCALE,
/// _Y_SCALE, _Z_OFFSET and _Z_SCALE (v3dv_uniforms.c:526-552): the
/// viewport's half width and half height in the clipper's 1/64ths of a
/// pixel, its minDepth, and maxDepth less minDepth.
pub const Viewport = enum(u8) { x_scale, y_scale, z_offset, z_scale };

/// What a `.system` step reads: the VPM's instance id, base instance or
/// vertex id, which ntq_setup_vs_inputs loads at the program's start
/// (nir_to_vir.c:2416-2438), or the first vertex, a uniform (since 1.192).
pub const SystemValue = enum(u8) { instance_id, base_instance, vertex_id, first_vertex };

/// Which of the VPM's three values a vertex program reads, each a row
/// before the attributes, in this order: v3d_vs_prog_data's uses_iid,
/// uses_biid and uses_vid (v3d_compiler.h:973), which the shader record
/// says of each program (v3dvx_pipeline.c:434-439; since 1.192).
pub const SystemValues = packed struct(u8) {
    instance_id: bool = false,
    base_instance: bool = false,
    vertex_id: bool = false,
    _: u5 = 0,

    /// The rows they take, which the attributes come after.
    pub fn count(values: SystemValues) u32 {
        return @as(u32, @intFromBool(values.instance_id)) + @intFromBool(values.base_instance) + @intFromBool(values.vertex_id);
    }

    pub fn has(values: SystemValues, which: SystemValue) bool {
        return switch (which) {
            .instance_id => values.instance_id,
            .base_instance => values.base_instance,
            .vertex_id => values.vertex_id,
            .first_vertex => false,
        };
    }
};

/// A uniform buffer's address as the stream holds it.
pub const UboAddress = struct {
    set: u16,
    binding: u16,
    offset: u32,
};

/// A storage buffer's address as the stream holds it, and `reach`, how
/// many of its bytes the program reads from its start: one past the last
/// of the floats its loads read at a constant offset, or its stores write
/// there (since 1.168), which the draw holds to the descriptor's range
/// (since 1.164).
pub const StorageAddress = struct {
    set: u16,
    binding: u16,
    reach: u32,
};

/// A struct with member Offsets: one decorated Block, the push constants'
/// or a uniform buffer's, or a struct inside one (since 1.161). Each
/// member has its type and its byte offset, from OpMemberDecorate Offset,
/// and a matrix member, or an array of matrices, the MatrixStride its
/// columns are apart.
pub const Block = struct {
    type_id: u16 = none,
    member_type: [most_members]u16 = @splat(none),
    member_offset: [most_members]u16 = @splat(none),
    member_stride: [most_members]u16 = @splat(none),
    member_count: u32 = 0,
    /// Its OpTypeStruct read.
    declared: bool = false,
    /// A vertex program's gl_PerVertex: each member's BuiltIn, or `none`,
    /// and no Offsets (since 1.163).
    member_builtin: [most_members]u16 = @splat(none),
    per_vertex: bool = false,
    /// Decorated BufferBlock: a storage buffer's, as SPIR-V 1.0 has one
    /// (since 1.164).
    storage: bool = false,
    /// Each member's NonWritable (since 1.168).
    member_non_writable: [most_members]bool = @splat(false),
    /// Its last member is a runtime array, which only a storage buffer's
    /// block may have, and nothing may hold.
    runtime: bool = false,
};

/// What a vertex program is besides its instructions (`Code.vertex`).
pub const VertexProgram = struct {
    vattr_sizes: [most_attributes]u8 = @splat(0),
    attribute_location: [most_attributes]u8 = @splat(0),
    attribute_count: u8 = 0,
    vpm_output_sectors: u8 = 0,
    single_seg: bool = false,
    /// The VPM's values it reads before the attributes (since 1.192).
    system_values: SystemValues = .{},
    /// GFXH-1602: a coordinate program that reads one of them and not its
    /// first driver location, which takes a row all the same, the draw
    /// telling the VPM to load one float of it (ntq_emit_load_input,
    /// nir_to_vir.c:2963-2973; v3dvx_cmd_buffer.c:2730-2740; since 1.192).
    first_row: bool = false,
    /// It writes gl_PointSize, a row of the VPM's after the fixed-function
    /// outputs: prog_data's writes_psiz (vir.c:901-902), which the shader
    /// record's bit 0 says (v3dvx_pipeline.c:379, :402; since 1.193).
    point_size: bool = false,
};

/// What a vertex program is compiled for beside its words: v3dv's
/// v3d_vs_key, of what this device's pipelines vary (since 1.163).
pub const VertexKey = struct {
    /// The binner's program, the coordinate shader: the position and its
    /// place on screen alone, as v3dv compiles the vertex shader a second
    /// time with `is_coord` (v3d_nir_setup_vpm_layout_vs,
    /// v3d_nir_lower_io.c:400-435).
    coordinate: bool = false,
    /// The varyings the fragment program reads: how many floats of each
    /// location, from location 0 up, in the order it reads them, which is
    /// the key's used_outputs (v3d_varying_slot_vpm_offset, :79-102). A
    /// fragment program of this device reads its locations from 0 up with
    /// no gap (`order`).
    reads: [most_varyings]u8 = @splat(0),
    /// The vertex program's `SystemValues`, which the coordinate program
    /// reads rows for as well: v3dv compiles both of the one NIR, whose
    /// system_values_read pipeline_lower_nir gathers before either
    /// (v3dv_pipeline.c:1875), and the coordinate program's reads of what
    /// it does not use are dead code (vir_opt_dead_code; since 1.192).
    system_values: SystemValues = .{},
};

/// A vertex program's attributes, by location: how many floats of each it
/// reads, from the first up (`c->vattr_sizes`, ntq_setup_vs_inputs,
/// nir_to_vir.c:2385-2410; since 1.163).
pub const most_attributes = 16;

/// A uniform buffer the module declares: its block, and where the draw
/// binds it.
pub const Ubo = struct {
    block: u16,
    set: u16,
    binding: u16,
    /// A storage buffer, whose block is BufferBlock: its loads are
    /// `.ssbo` steps and its address QUNIFORM_SSBO_OFFSET (since 1.164).
    storage: bool = false,
};

/// A matrix the body holds as a value: the steps of its columns, each a
/// vector of its rows, as vtn holds one, a vtn_ssa_value of `elems`
/// (since 1.161).
pub const Matrix = struct {
    columns: [4]u16 = @splat(none),
    count: u8 = 0,
    /// The matrix this one is the transpose of, where `transposeOf` made
    /// it: what transposing it again answers, and what `multiplied` reads
    /// where both of its matrices are transposes (vtn_ssa_value's
    /// `transposed`, spirv_to_nir.c:4486-4510).
    transposed: u16 = none,
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
    /// From OpDecorate Flat and NoPerspective (since 1.190).
    interpolation: [most_ids]Interpolation = @splat(.smooth),
    /// From OpDecorate DescriptorSet and Binding, or `none`.
    set: [most_ids]u16 = @splat(none),
    binding: [most_ids]u16 = @splat(none),
    /// Which sampler an id names: the variable, and the value an OpLoad
    /// of it answers. A sampler is not a value a step can hold, so it is
    /// carried beside the steps rather than among them.
    sampler_of: [most_ids]u16 = @splat(none),
    /// An image type's, and a sampled image type's, `SamplerDim` (since
    /// 1.179).
    sampler_dim: [most_ids]SamplerDim = @splat(.flat),
    /// Which step a value id answers.
    step_of: [most_ids]u16 = @splat(none),
    /// `member_pointer`: which float of the member it names, or `whole`
    /// where it names all of them.
    chain_part: [most_ids]u8 = @splat(whole),

    /// `member_pointer`: the variable of the block it is a member of,
    /// the push constants' or a uniform buffer's (since 1.160). A
    /// `local_aggregate` or a `scratch_pointer`: the variable of the
    /// function's own it is of, or is (since 1.177).
    chain_base: [most_ids]u16 = @splat(none),
    /// `member_pointer`: the byte offset of what it names in the block,
    /// and the MatrixStride of the matrices it is in or names, `none`
    /// where there are none (since 1.161). A `scratch_pointer`: the byte
    /// offset in scratch, its variable's place there added in, and no
    /// stride (since 1.177).
    chain_offset: [most_ids]u16 = @splat(0),
    chain_stride: [most_ids]u16 = @splat(none),
    /// `member_pointer`: where an index of the chain is no constant, the
    /// step of the byte offset, which `chain_offset` is then not; `none`
    /// where every index is one (since 1.166). A `scratch_pointer`: the
    /// step of the bytes the computed indexes add, `chain_offset` the
    /// constant ones' (since 1.177).
    chain_dynamic: [most_ids]u16 = @splat(none),
    /// A variable decorated NonWritable, and a `member_pointer` through
    /// such a variable or a member decorated so: vtn's access, gathered
    /// down the chain (vtn_variables.c:397, :512; since 1.168).
    non_writable: [most_ids]bool = @splat(false),
    /// The program writes a storage buffer: nir_opt_access's
    /// buffers_written, without which every load of one is
    /// ACCESS_NON_WRITEABLE (nir_opt_access.c:266-272; since 1.168).
    buffers_written: bool = false,
    /// An access chain names a storage buffer's variable: info.num_ssbos
    /// is not 0, the variables vtn keeps being those the body names
    /// (spirv_to_nir.c:7533-7551; since 1.168).
    uses_ssbo: bool = false,
    /// `array`: how many elements, and the ArrayStride they are apart,
    /// which an OpDecorate may give before the type is declared
    /// (since 1.161).
    length: [most_ids]u16 = @splat(0),
    array_stride: [most_ids]u16 = @splat(none),
    /// The type of a `local_aggregate`, an `aggregate_value` or a
    /// `constant_aggregate`: an array, a struct that is no block, or a
    /// matrix of the function's own (since 1.176).
    aggregate: [most_ids]u16 = @splat(none),
    /// The variables of the function's own that live in scratch memory
    /// (`Scratch`), and the bytes of it the program has: the shader's
    /// scratch_size (nir_lower_scratch.c:247-258; since 1.177).
    scratch: Scratch = .{},
    scratch_size: u32 = 0,
    /// A `scratch_pointer`'s deref: its `Path`'s place in `pointer_paths`
    /// (since 1.177).
    chain_path: [most_ids]u8 = @splat(0),
    /// A `scratch_pointer`: how many elements, columns and floats the
    /// indexes the body computes count together down its chain,
    /// nir_lower_indirect_derefs_to_if_else_trees's indirect_array_len
    /// (:138-146; since 1.178).
    chain_elements: [most_ids]u16 = @splat(1),
    /// A `local_tree`: the step of the index the body computes, which the
    /// if of nir_lower_indirect_derefs_to_if_else_trees tests, and how
    /// many of the variables nir_split_array_vars makes the element the
    /// else arm names is past the one the then arm does, which is
    /// `points`; the rest of the chain from there `aggregate` and
    /// `chain_part` (since 1.178).
    tree_index: [most_ids]u16 = @splat(none),
    tree_apart: [most_ids]u16 = @splat(0),
    /// `planLoop`'s reading of what each id of a loop is, which at 4096
    /// ids is more than the stack a command is given (since 1.191; the
    /// call's own before).
    loop_defined: [most_ids]Defined = undefined,
    pointer_paths: [most_pointer_paths]Path = undefined,
    pointer_path_count: u32 = 0,
    /// The deref of the float a load_scratch or a store_scratch step is
    /// of, until the program is laid out (since 1.177).
    step_path: [most_steps]Path = undefined,
    /// nir_opt_copy_prop_vars's copies where the walk is (`Copies`), and
    /// those where each selection it is in branched, which each arm starts
    /// from as copy_prop_vars_cf_node clones them for it, and its merge
    /// is left with less what may be what the arms stored
    /// (nir_opt_copy_prop_vars.c:1531-1566, invalidate_copies_for_cf_node,
    /// :966-1001; since 1.177).
    copies: Copies = .{},
    copies_before: [most_nesting]Copies = undefined,
    /// nir_opt_dead_write_vars's unused writes in the block the walk is in
    /// (remove_dead_write_vars_local, nir_opt_dead_write_vars.c): the
    /// store_scratch steps nothing has read what they stored since, and
    /// those where each selection branched, a block that goes on past its
    /// merge where nir_opt_peephole_select flattens it. A store found
    /// written over is `unwritten` (since 1.177).
    unused: [most_steps]u16 = undefined,
    unused_count: u16 = 0,
    unused_before: [most_nesting][most_steps]u16 = undefined,
    unused_before_count: [most_nesting]u16 = undefined,
    unwritten: [most_steps]bool = @splat(false),
    /// The floats and vectors of the aggregates the body holds, in the
    /// order nir_split_struct_vars and nir_split_array_vars split them,
    /// which is the order _vtn_variable_load_store walks them in
    /// (vtn_variables.c:763-781): an `aggregate_value`'s `points` is its
    /// first here, each a step, and a `constant_aggregate`'s, each the id
    /// of a constant, made a step where it is read as a constant is
    /// (since 1.176).
    leaves: [most_leaves]u16 = undefined,
    leaf_count: u32 = 0,
    /// The members of the structs that are no block: a `plain_struct`'s
    /// `points` is its first here and `wide` how many (since 1.176).
    struct_members: [most_struct_members]u16 = undefined,
    struct_member_count: u32 = 0,
    /// The matrices the body holds: a `matrix_value`'s `points` is its
    /// place here (since 1.161). A `constant_matrix`'s is too, its
    /// columns the ids of their constants until it is first read
    /// (since 1.162).
    matrices: [most_matrices]Matrix = undefined,
    matrix_count: u32 = 0,

    /// The structs decorated `Block`, the push constants' and the uniform
    /// buffers' (since 1.160), each found by its type.
    blocks: [most_blocks]Block = @splat(.{}),
    block_count: u32 = 0,
    /// The id GLSL.std.450 is imported as, where it is: the one extended
    /// set whose calls the walk lowers (since 1.152).
    glsl: u16 = none,
    /// The push constants' one variable; its `points` is its block.
    push_variable: u16 = none,
    /// The uniform buffers, in the order their variables are declared:
    /// each variable's `points` is its place here, which is the slot of
    /// v3dv's descriptor map for it (`Code.ubos`; since 1.160).
    ubos: [most_ubos]Ubo = undefined,
    ubo_count: u32 = 0,

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
    /// How many times the body samples (more than once since 1.173).
    sample_count: u32 = 0,

    inputs: [most_varyings]Input = undefined,
    input_count: u32 = 0,
    /// The one colour out.
    output: u16 = none,
    output_count: u32 = 0,

    /// The stage the module is a program of, and what a vertex program
    /// is compiled for (since 1.163).
    stage: spirv.ExecutionModel = .fragment,
    vertex_key: VertexKey = .{},
    /// A vertex program's gl_PerVertex variable, and the position stored
    /// into it.
    per_vertex: u16 = none,
    position: u16 = none,
    /// A vertex program's VertexIndex and InstanceIndex variables, the
    /// value each loads, and the `.system` steps of each `SystemValue`,
    /// each made once (since 1.192).
    system_ids: [2]u16 = .{ none, none },
    system_value: [2]u16 = .{ none, none },
    system_step: [4]u16 = @splat(none),
    /// What `attributes` found of them (`VertexProgram`).
    system_values: SystemValues = .{},
    first_row: bool = false,
    /// A vertex program's outputs at a location: each variable's
    /// `location` says where, and the fragment program's floats it has
    /// stored, a bit each, which the rest are stored 0 beside
    /// (v3d_nir_emit_ff_vpm_outputs, v3d_nir_lower_io.c:569-586).
    varyings_stored: u32 = 0,
    /// Where in the VPM the varyings start, after the fixed-function
    /// outputs, and how many floats it is written in all
    /// (`c->vpm_output_size`, v3d_nir_setup_vpm_layout_vs).
    varyings_vpm_offset: u32 = 0,
    vpm_output_size: u32 = 0,
    /// How many floats of each attribute the program reads, by its
    /// driver location, and the location each driver location is: the
    /// inputs numbered from 0 in the order of their locations, as
    /// nir_assign_io_var_locations numbers them before the compile
    /// (lower_vs_io, v3dv_pipeline.c:1057).
    vattr_sizes: [most_attributes]u8 = @splat(0),
    attribute_location: [most_attributes]u8 = @splat(0),
    attribute_count: u32 = 0,
    /// The varyings stored, in the order of their OpStores, which
    /// nir_move_output_stores_to_end keeps at the end of the program
    /// (v3d_nir_lower_vs_early, vir.c:1121): each the value's step and
    /// the variable it went into.
    varying_values: [most_varyings]u16 = undefined,
    varying_into: [most_varyings]u16 = undefined,
    varying_count: u32 = 0,
    /// The point size stored, nir_lower_point_size's fmax of it and 1.0
    /// (since 1.193), and how many varyings were stored before it.
    point_size: u16 = none,
    point_size_order: u32 = 0,

    steps: [most_steps]Step = undefined,
    step_count: u32 = 0,
    /// The step the body stored into the colour out.
    stored: u16 = none,
    /// The function's own variables, as nir_lower_vars_to_ssa makes
    /// them values (since 1.155): how many floats each is, and which
    /// float each of its floats holds where the walk has got to, a
    /// `step` of `none` where nothing was stored into it yet. At a
    /// selection, what they held before its arms, and what each arm
    /// leaves them holding.
    local_kind: [most_locals]Kind = undefined,
    /// Whether a variable of the function's own holds a bool (since
    /// 1.165).
    local_bool: [most_locals]bool = undefined,
    /// Whether a variable of the function's own is one of an aggregate an
    /// if-else tree reaches (`Scratch.trees`; since 1.178).
    local_late: [most_locals]bool = @splat(false),
    local_count: u32 = 0,
    values: Values = undefined,
    before: [most_nesting]Values = undefined,
    ends: [most_nesting][2]Values = undefined,
    /// The variables in the order they were first stored into or loaded
    /// from, which is the order nir_lower_vars_to_ssa gives the phi
    /// builder their values (register_variable_uses,
    /// nir_lower_vars_to_ssa.c:501-550; since 1.156).
    first_used: [most_locals]u8 = undefined,
    used_count: u32 = 0,
    used: u32 = 0,
    /// The first step that samples, where there is one: the plan's one.
    sampled: u16 = none,
    varyings: u32 = 0,
    /// The varyings, a bit each, that are flat and that are interpolated
    /// without perspective, as `order` numbers them (since 1.190).
    flat_floats: u8 = 0,
    noperspective_floats: u8 = 0,

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

    /// What `lanes` finds of each step of the program laid out: whether
    /// it differs from lane to lane, and whether a sample or a load that
    /// does may leave helper pixels out (since 1.167).
    divergent: [most_steps]bool = @splat(false),
    skip_helpers: [most_steps]bool = @splat(false),

    /// Each step's region (`Region`), the one `read` is in, and the
    /// selections it kept branches (since 1.171).
    region: [most_steps]Region = @splat(0),
    current_region: Region = 0,
    kept: [most_kept]Kept = undefined,
    kept_count: u8 = 0,

    pub const Thing = enum(u8) { none, other, float, vector, image, sampled_image, pointer, constant, variable, function, value, int, int_constant, structure, member_pointer, boolean, input_part, local_part, array, matrix, matrix_value, constant_matrix, position_pointer, point_size_pointer, plain_struct, local_aggregate, aggregate_value, constant_aggregate, scratch_pointer, local_tree };

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
    // Every hand-written program's varyings are `qpu.varying`'s, with
    // perspective (since 1.190, where the reading takes the others).
    if (work.flat_floats != 0 or work.noperspective_floats != 0) return Error.Refused;
    // No hand-written program reads a push constant or a uniform buffer,
    // drops a pixel or compares, so the plan has nothing to hold any of
    // them to: only Mesa's back end compiles them.
    // Every hand-written program that samples writes the TMU once and
    // reads it once.
    if (work.sample_count > 1) return Error.Samplers;
    for (work.program()) |each| switch (each.tag) {
        .push, .ubo, .ssbo, .ubo_indirect, .ssbo_indirect, .ssbo_store, .ssbo_atomic, .barrier, .scratch, .scratch_indirect, .scratch_store => return Error.Storage,
        .discard => return Error.Discards,
        .sample_compared => return Error.Samplers,
        // Every one reads a 2D texture at s and t (since 1.179), at the
        // level the quad gives and at no offset: a bias, a level and an
        // offset are operands no hand-written program takes.
        .sample => if (work.samplers[each.at].dim != .flat) {
            return Error.Samplers;
        } else if (each.lookup != .implicit or !std.mem.eql(i8, &each.offsets, &.{ 0, 0, 0 })) {
            return Error.Operands;
        },
        // Nor does one ask for an image's size (since 1.181).
        .texture_size, .texture_levels => return Error.Samplers,
        // Nor does any compute beyond a sum and a product.
        .sub, .min, .max, .negate, .abs, .floor, .ceil, .trunc, .round, .recip, .rsqrt, .exp2, .log2 => return Error.Body,
        .select, .set_less, .sat, .sin, .cos, .sign, .logic, .integer => return Error.Body,
        // Nor branches.
        .begin_if, .begin_else, .end_if, .phi => return Error.Branches,
        else => {},
    };
    try settle(work);
    try encode(work);
    var made: Code = .{
        .words = work.code[0..work.word_count],
        .varyings = work.varyings,
        .uniforms = work.stream[0..work.stream_count],
        .uniform_count = work.stream_count,
        .registers = work.high_water,
    };
    if (work.sample_count != 0) {
        made.samplers[0] = work.samplers[work.steps[work.sampled].at];
        made.sampler_count = 1;
    }
    return made;
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

/// A vertex program's words compiled through Mesa's back end for `key`:
/// the vertex program the renderer runs, or the coordinate program the
/// binner runs, as v3dv compiles both of one shader
/// (pipeline_compile_vertex_shader, v3dv_pipeline.c:1990-2020). Its
/// working memory is `compileThroughMesa`'s (since 1.163).
pub fn compileVertexThroughMesa(work: *Work, words: []const u32, child: std.mem.Allocator, key: VertexKey) (Error || std.mem.Allocator.Error)!Code {
    var arena = std.heap.ArenaAllocator.init(child);
    defer arena.deinit();
    const allocator = arena.allocator();
    const compiler = allocate.initRegSets(allocator) catch return error.OutOfMemory;
    return compileVertexVir(work, words, allocator, &compiler, key);
}

/// `compileVertexThroughMesa` with the register sets the caller's.
pub fn compileVertexVir(work: *Work, words: []const u32, allocator: std.mem.Allocator, compiler: *const vir.Compiler, key: VertexKey) (Error || std.mem.Allocator.Error)!Code {
    try readStage(work, words, .vertex, key);
    return compileRead(work, allocator, compiler, .{});
}

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
    lanes(work);
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

    var units: Units = .{};
    try units.of(work);

    // The stream in the order the program reads it, which is the order
    // the scheduler left the uniforms in.
    if (c.num_uniforms > most_uniforms) return Error.Uniforms;
    for (c.uniform_contents[0..c.num_uniforms], c.uniform_data[0..c.num_uniforms], 0..) |contents, data, at| {
        work.stream[at] = switch (contents) {
            .constant => .{ .float = @bitCast(data) },
            // The draw's own words, which `tiling.parameter0` and
            // `parameter1` write as these are: both words of a unit's
            // texture, and its sampler, with the per-pixel mask the
            // program sets of it (since 1.167). The unit `to_vir` puts in
            // the high bits is the sampler the module declares, made the
            // program's own here (since 1.173).
            .tmu_config_p0 => if (vir.unitDataGetOffset(data) == to_vir.texel_words) .{ .texture = try units.at(vir.unitDataGetUnit(data)) } else return Error.Invalid,
            .tmu_config_p1 => if (vir.unitDataGetOffset(data) & ~per_pixel_mask == 0) .{ .sampler = .{ .unit = try units.at(vir.unitDataGetUnit(data)), .bits = vir.unitDataGetOffset(data) } } else return Error.Invalid,
            // A word of the push constants: `Step.at` of a `.push`.
            .uniform => .{ .push = data },
            // A uniform buffer's address: the unit is the buffer's slot
            // shifted up by one, as ntq_emit_load_unifa gives it.
            .ubo_addr => ubo: {
                const unit = vir.unitDataGetUnit(data);
                if (unit == 0 or unit > work.ubo_count) return Error.Invalid;
                const bound = work.ubos[unit - 1];
                if (bound.storage) return Error.Invalid;
                break :ubo .{ .ubo = .{ .set = bound.set, .binding = bound.binding, .offset = vir.unitDataGetOffset(data) } };
            },
            // A storage buffer's address: the slot itself, not shifted
            // (ntq_emit_load_unifa, nir_to_vir.c:3383-3390), and how far
            // the program reads into it (since 1.164).
            .ssbo_offset => ssbo: {
                if (data >= work.ubo_count) return Error.Invalid;
                const bound = work.ubos[data];
                if (!bound.storage) return Error.Invalid;
                break :ssbo .{ .ssbo = .{ .set = bound.set, .binding = bound.binding, .reach = reachOf(work, @intCast(data)) } };
            },
            // A word of the draw's viewport (since 1.163).
            .viewport_x_scale => .{ .viewport = .x_scale },
            .viewport_y_scale => .{ .viewport = .y_scale },
            .viewport_z_offset => .{ .viewport = .z_offset },
            .viewport_z_scale => .{ .viewport = .z_scale },
            // The draw's first vertex (since 1.192).
            .first_vertex => .first_vertex,
            // The spill buffer's (since 1.177).
            .spill_offset => .spill_offset,
            .spill_size_per_thread => .spill_size_per_thread,
            // A size of a unit's view, or its levels (since 1.181).
            .texture_width => .{ .texture_size = .{ .unit = try units.at(data), .field = .width } },
            .texture_height => .{ .texture_size = .{ .unit = try units.at(data), .field = .height } },
            .texture_depth => .{ .texture_size = .{ .unit = try units.at(data), .field = .depth } },
            .texture_array_size => .{ .texture_size = .{ .unit = try units.at(data), .field = .array_size } },
            .texture_levels => .{ .texture_size = .{ .unit = try units.at(data), .field = .levels } },
            else => return Error.Invalid,
        };
    }
    work.stream_count = c.num_uniforms;

    return .{
        .words = work.code[0..work.word_count],
        .varyings = work.varyings,
        .uniforms = work.stream[0..work.stream_count],
        .uniform_count = work.stream_count,
        .samplers = units.samplers,
        .sampler_count = units.count,
        .registers = program.registers,
        .threads = c.threads,
        .center_w = program.uses_center_w,
        .lock_scoreboard_on_first_thrsw = c.lock_scoreboard_on_first_thrsw,
        .writes_z = program.writes_z,
        .disable_ez = program.disable_ez,
        .tmu_dirty_rcl = c.tmu_dirty_rcl,
        .spill_size = c.spill_size,
        .flat_shade_flags = program.flat_shade_flags,
        .noperspective_flags = program.noperspective_flags,
        .vertex = if (work.stage == .vertex) vertexProgram(work, program.single_seg) else .{},
    };
}

/// What v3d_vs_set_prog_data says of a vertex program (vir.c:860-936):
/// its attributes' sizes, and its VPM segment, input and output shared,
/// in sectors of eight floats.
fn vertexProgram(work: *const Work, single_seg: bool) VertexProgram {
    var made = VertexProgram{ .attribute_count = @intCast(work.attribute_count), .single_seg = single_seg, .system_values = work.system_values, .first_row = work.first_row, .point_size = work.point_size != none };
    // A row each of the VPM's values it reads (vir.c:894-899), and none for
    // GFXH-1602's.
    var input_size: u32 = work.system_values.count();
    for (0..work.attribute_count) |driver| {
        made.vattr_sizes[driver] = work.vattr_sizes[driver];
        made.attribute_location[driver] = work.attribute_location[driver];
        input_size += work.vattr_sizes[driver];
    }
    const input_sectors = (input_size + 7) / 8;
    const output_sectors = (work.vpm_output_size + 7) / 8;
    made.vpm_output_sectors = @intCast(@max(output_sectors, input_sectors));
    return made;
}

/// The units of the samplers the program's samples read, as
/// descriptor_map_add gives them (v3dv_pipeline.c:516-561): a set and
/// binding a unit, the one it already has where an earlier sample read
/// it, in the program's order; and whether each compares (since 1.173).
const Units = struct {
    samplers: [most_samplers]Sampler = undefined,
    count: u32 = 0,
    /// The unit of each sampler the module declares, or `no_unit`.
    of_declared: [most_samplers]u8 = @splat(no_unit),

    const no_unit: u8 = 0xFF;

    /// The unit of a set and binding, if an earlier step gave it one.
    fn find(units: *const Units, declared: Sampler) ?u8 {
        for (units.samplers[0..units.count], 0..) |known, k| {
            if (known.set == declared.set and known.binding == declared.binding) return @intCast(k);
        }
        return null;
    }

    fn of(units: *Units, work: *const Work) Error!void {
        for (work.program()) |each| {
            if (each.tag != .sample and each.tag != .sample_compared) continue;
            // A fetch reads no sampler state: it is the queries' below.
            if (each.lookup == .fetch) continue;
            const compared = each.tag == .sample_compared;
            const declared = work.samplers[each.at];
            const unit: u8 = units.find(declared) orelse made: {
                units.samplers[units.count] = declared;
                units.samplers[units.count].compared = compared;
                units.count += 1;
                break :made @intCast(units.count - 1);
            };
            // One sampler state for the unit: a comparison is in it or
            // not, and a sample of the other kind would read it wrongly.
            if (units.samplers[unit].compared != compared) return Error.Samplers;
            units.of_declared[each.at] = unit;
        }
        // A query of an image's reads its view and no sampler state, so
        // it takes the unit a sample made, or one of its own that no
        // comparison is in (since 1.181); and so does a fetch, whose P1
        // is a constant (v3d_tex.c:350-354; since 1.182).
        for (work.program()) |each| {
            const fetches = each.tag == .sample and each.lookup == .fetch;
            if (each.tag != .texture_size and each.tag != .texture_levels and !fetches) continue;
            if (units.of_declared[each.at] != no_unit) continue;
            const declared = work.samplers[each.at];
            const unit: u8 = units.find(declared) orelse made: {
                units.samplers[units.count] = declared;
                units.count += 1;
                break :made @intCast(units.count - 1);
            };
            units.of_declared[each.at] = unit;
        }
    }

    /// The unit of the sampler the module declares `declared`th.
    fn at(units: *const Units, declared: u32) Error!u8 {
        if (declared >= most_samplers or units.of_declared[declared] == no_unit) return Error.Invalid;
        return units.of_declared[declared];
    }
};

/// The words looked at against the profile and read into `work`: what
/// `compile` and `compileVir` share.
fn readModule(work: *Work, words: []const u32) Error!void {
    return readStage(work, words, .fragment, .{});
}

/// The words of a program of `stage`, read into `work`; a vertex program
/// for `key` (since 1.163).
fn readStage(work: *Work, words: []const u32, stage: spirv.ExecutionModel, key: VertexKey) Error!void {
    // The variables found to live in scratch so far, each a walk of its
    // own (since 1.177).
    var scratch: Scratch = .{};
    while (true) {
        work.* = .{ .stage = stage, .vertex_key = key, .scratch = scratch, .scratch_size = scratch.size() };
        // The VPM's layout, v3d_nir_setup_vpm_layout_vs (v3d_nir_lower_io.c:
        // 400-435): the coordinate program's position first, then the place
        // on screen; the vertex program's place, its Zs and 1/Wc. A point
        // size's row after them is added where the program writes one
        // (`finishVertex`; since 1.193).
        if (stage == .vertex) work.varyings_vpm_offset = if (key.coordinate) 4 + 2 else 2 + 1 + 1;
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
        if (seen.stage != stage) return Error.Stage;
        // A discard is read in the body: where it is the one shape taken, it
        // is a step, and anywhere else `read` answers `Error.Discards`.
        read(work, words, seen) catch |err| {
            // A variable the walk found to want scratch: the walk again,
            // with it there.
            if (err != Error.Storage or work.scratch.same(&scratch)) return err;
            scratch = work.scratch;
            continue;
        };
        return;
    }
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
    //
    // A selection may be in an arm of another, and is flattened first:
    // the pass walks the blocks in order (nir_opt_peephole_select_impl,
    // :607-619), and reaches the inner one's merge block, with the inner
    // selection before it, ahead of the outer one's, whose arm is then
    // one block. The outer arm goes on in the inner merge block, which is
    // where it ends and the block a phi of the outer merge names (since
    // 1.156).
    var flow: Flow = .body;
    var nest: [most_nesting]Selection = @splat(.{});
    var depth: u32 = 0;
    // The block the walk is in.
    var label: u32 = 0;
    // A loop, unrolled as nir_opt_loop_unroll unrolls it: the walk goes
    // through its words once for each time Mesa's copy of them runs, and
    // back to its header for the next (since 1.172).
    var loop: Loop = .{};
    // The block a top-level OpBranch goes to, which is the next, and the
    // block it left, a phi's way in.
    var jumped: u32 = 0;
    var came_from: u32 = 0;
    // A header's phis, set together once all are read.
    var settled: [most_settled]Settled = undefined;
    var settling: u32 = 0;
    // A block of phis of two ways in, which is a loop's header.
    var two_ways = false;
    // Where the block a top-level branch went to starts, and what the
    // variables held and how many steps there were there: a loop's, where
    // it is one.
    var block_at: u32 = 0;
    var entry_values: Values = undefined;
    var entry_steps: u16 = 0;
    while (reader.next() catch return Error.Refused) |instruction| {
        const operands = instruction.operands();
        if (returned) {
            // Past OpReturn only the function's end may follow.
            if (instruction.op != .function_end) return Error.Body;
            continue;
        }
        if (settling > 0 and instruction.op != .phi) {
            for (settled[0..settling]) |each| work.step_of[each.id] = each.step;
            settling = 0;
        }
        // The merge block's phis are over at its first other instruction:
        // the arms are then what nir_opt_peephole_select counts, and the
        // walk is back where the selection was.
        if (flow == .merging and instruction.op != .phi) {
            const inner = nest[depth - 1];
            // One the selection in it collapsed into is an empty
            // selection: nir_opt_collapse_if counted the block before the
            // inner one, and the inner one is flattened on its own arm.
            // One over the limit is kept a branch, as one whose arm holds
            // what is not flattened (since 1.171); the arms of one
            // flattened are in the block it is in.
            const kept = inner.kept or (!inner.collapsed and armCost(work, inner.arms_from, inner.arms_to) > limitOf(inner.control, peephole_limit));
            if (kept)
                try keepSelection(work, &inner, depth)
            else if (depth == 1)
                @memset(work.region[inner.arms_from..inner.arms_to], 0);
            // To nir_opt_dead_write_vars the merge of one kept is a block
            // of its own; one flattened is in the block before it, which
            // its arms are in too, and which goes on (since 1.177).
            if (inner.seen_yes or inner.seen_no) {
                if (kept) {
                    work.unused_count = 0;
                } else {
                    const before = work.unused_before_count[depth - 1];
                    @memcpy(work.unused[0..before], work.unused_before[depth - 1][0..before]);
                    work.unused_count = before;
                }
            }
            flow = inner.outside;
            depth -= 1;
            if (depth > 0) {
                const outer = &nest[depth - 1];
                outer.lone = inner.no == inner.merge or inner.quiet_no;
                if (inner.iand != none) outer.held = .{
                    .iand = inner.iand,
                    .condition = inner.condition,
                    .selects_from = inner.arms_to,
                    .selects_to = @intCast(work.step_count),
                    .cost = armCost(work, inner.arms_from, inner.arms_to),
                    .control = inner.control,
                    .emptiness = if (inner.killed or !inner.quiet_yes) .kept else if (inner.constant_yes) .unsure else .empty,
                    .killed = inner.killed,
                };
            }
        }
        const selection = &nest[if (depth == 0) 0 else depth - 1];
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
                // every other decoration is refused rather than ignored,
                // as taking one and dropping it would draw the wrong
                // pixels and say nothing.
                //
                // Which decoration it is is read before how many
                // operands it has, because the three that are taken
                // carry a literal and others do not: a real `OpDecorate
                // %x Flat` is two words of operands, so demanding three
                // would answer `Body` for a decoration that is refused
                // by name, or taken.
                switch (what) {
                    // How a varying is interpolated, which is its own
                    // and no literal: one with a literal is no decoration
                    // vtn reads (since 1.190; refused before, as
                    // `qpu.varying` does not, and the plan still is).
                    .flat, .no_perspective => {
                        if (operands.len != 2) return Error.Refused;
                        work.interpolation[id] = if (what == .flat) .flat else .noperspective;
                        continue;
                    },
                    // A vertex program's VertexIndex or InstanceIndex,
                    // which vtn reads as SYSTEM_VALUE_VERTEX_ID and
                    // _INSTANCE_INDEX (vtn_variables.c:908-921; since
                    // 1.192). Any other built-in of a variable, and either
                    // of a fragment program, is still refused, and so is
                    // either on two variables.
                    .built_in => {
                        if (operands.len != 3 or work.stage != .vertex) return Error.Refused;
                        const which: usize = switch (operands[2]) {
                            @intFromEnum(spirv.BuiltIn.vertex_index) => 0,
                            @intFromEnum(spirv.BuiltIn.instance_index) => 1,
                            else => return Error.Refused,
                        };
                        if (work.system_ids[which] != none) return Error.Refused;
                        work.system_ids[which] = id;
                        continue;
                    },
                    .location, .descriptor_set, .binding => {},
                    // How far an array's elements are apart in a block
                    // (since 1.161).
                    .array_stride => {},
                    // A block, which carries no literal: the push
                    // constants', or a uniform buffer's (since 1.160).
                    .block => {
                        _ = try blockOf(work, id);
                        continue;
                    },
                    // A storage buffer's, as SPIR-V 1.0 declares one
                    // (since 1.164).
                    .buffer_block => {
                        (try blockOf(work, id)).storage = true;
                        continue;
                    },
                    // A buffer the program may not write: its loads are
                    // ACCESS_NON_WRITEABLE (vtn_variables.c:1666-1667;
                    // since 1.168).
                    .non_writable => {
                        work.non_writable[id] = true;
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
                    // A word apart at least: ldunifa reads words.
                    .array_stride => {
                        if (value == 0 or value % 4 != 0) return Error.Storage;
                        work.array_stride[id] = value;
                    },
                    else => unreachable,
                }
            },
            .member_decorate => {
                // StructureType, Member, Decoration, its literal. The
                // member's byte offset is where its floats are in the
                // block: a word of them each, so it is a multiple of
                // four. Whether they fit is for the variable to say,
                // whose class tells the push constants from a uniform
                // buffer. A matrix member's MatrixStride is how far its
                // columns are apart, and ColMajor is how they are laid
                // out anyway (since 1.161); RowMajor, whose columns are
                // not a vector's floats side by side, and the vertex
                // stage's built-ins are not here.
                if (operands.len < 3) return Error.Body;
                const id = try idOf(operands[0]);
                const what = std.enums.fromInt(spirv.Decoration, operands[2]) orelse return Error.Refused;
                if (what == .built_in and work.stage == .vertex) {
                    // gl_PerVertex's members, which glslc declares whole
                    // whatever the program writes of them (since 1.163).
                    if (operands.len < 4) return Error.Body;
                    if (operands[1] >= most_members or operands[3] >= none) return Error.Storage;
                    const block = try blockOf(work, id);
                    block.member_builtin[operands[1]] = @intCast(operands[3]);
                    block.per_vertex = true;
                    continue;
                }
                if (what != .offset and what != .matrix_stride and what != .col_major and what != .non_writable) return Error.Refused;
                const block = try blockOf(work, id);
                const member = operands[1];
                if (member >= most_members) return Error.Storage;
                // A storage buffer's member NonWritable, which a load
                // through it is (vtn_handle_access_qualifier,
                // spirv_to_nir.c:1568-1575, :1627-1628; since 1.168).
                if (what == .non_writable) {
                    block.member_non_writable[member] = true;
                    continue;
                }
                if (what == .col_major) continue;
                if (operands.len < 4) return Error.Body;
                const literal = operands[3];
                if (literal % 4 != 0 or literal >= none) return Error.Storage;
                if (what == .matrix_stride) {
                    if (literal == 0) return Error.Storage;
                    block.member_stride[member] = @intCast(literal);
                    continue;
                }
                block.member_offset[member] = @intCast(literal);
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
                // A block, or a struct in one. Each member is a float, a
                // vector, a matrix, an array or a struct of offsets of its
                // own (since 1.161), with an offset, and all of it inside
                // the block.
                if (operands.len < 1) return Error.Body;
                const id = try idOf(operands[0]);
                const block = findBlock(work, id) orelse {
                    // A struct of no offsets, which a variable of the
                    // function's own may be of, or an array of those or a
                    // struct of them: floats, integers, bools, vectors,
                    // matrices, and arrays and structs of those (since
                    // 1.176). A bool in a variable of one is a variable of
                    // its own, as a float is, and a load of the whole of
                    // one holding a bool is refused.
                    const members = operands[1..];
                    if (members.len == 0 or members.len > 0xFF) return Error.Storage;
                    if (work.struct_member_count + members.len > work.struct_members.len) return Error.Storage;
                    work.thing[id] = .plain_struct;
                    work.points[id] = @intCast(work.struct_member_count);
                    work.wide[id] = @intCast(members.len);
                    for (members) |each| {
                        const member = try idOf(each);
                        switch (work.thing[member]) {
                            .float, .int, .boolean, .vector, .matrix, .plain_struct => {},
                            .array => if (isRuntime(work, member)) return Error.Type,
                            else => return Error.Type,
                        }
                        work.struct_members[work.struct_member_count] = member;
                        work.struct_member_count += 1;
                    }
                    continue;
                };
                const members = operands[1..];
                if (members.len == 0 or members.len > most_members) return Error.Storage;
                if (block.per_vertex) {
                    // gl_PerVertex: every member a built-in, and none of
                    // them laid out, its values the VPM's (since 1.163).
                    for (members, 0..) |each, k| {
                        if (block.member_builtin[k] == none or block.member_offset[k] != none) return Error.Storage;
                        block.member_type[k] = try idOf(each);
                    }
                    block.member_count = @intCast(members.len);
                    block.declared = true;
                    work.thing[id] = .structure;
                    continue;
                }
                for (members, 0..) |each, k| {
                    const member = try idOf(each);
                    const offset = block.member_offset[k];
                    if (offset == none) return Error.Storage;
                    if (work.thing[member] == .structure) {
                        // A struct whose last member is a runtime array
                        // is a storage buffer's block, which nothing holds.
                        const inner = findBlock(work, member) orelse return Error.Type;
                        if (inner.runtime) return Error.Storage;
                    }
                    if (isRuntime(work, member)) {
                        // A runtime array, the last member of a storage
                        // buffer's block alone; it counts no bytes here
                        // (since 1.164).
                        if (k != members.len - 1 or !block.storage) return Error.Storage;
                        block.runtime = true;
                    }
                    if (offset + try sizeOf(work, member, block.member_stride[k]) >= none) return Error.Storage;
                    block.member_type[k] = member;
                }
                // An offset given for a member the struct does not have.
                for (block.member_offset[members.len..]) |offset| if (offset != none) return Error.Storage;
                block.member_count = @intCast(members.len);
                block.declared = true;
                work.thing[id] = .structure;
            },
            .type_vector => {
                if (operands.len < 3) return Error.Body;
                const id = try idOf(operands[0]);
                const component = try idOf(operands[1]);
                // Of floats, or of 32-bit integers (since 1.165).
                if (work.thing[component] != .float and work.thing[component] != .int) return Error.Type;
                if (operands[2] < 2 or operands[2] > 4) return Error.Type;
                work.thing[id] = .vector;
                work.wide[id] = @intCast(operands[2]);
                // Its float, which an access chain into it names.
                work.points[id] = component;
            },
            .type_matrix => {
                // Result, ColumnType, ColumnCount: a vector of floats
                // each (since 1.161).
                if (operands.len < 3) return Error.Body;
                const id = try idOf(operands[0]);
                const column = try idOf(operands[1]);
                if (work.thing[column] != .vector or isIntegerType(work, column)) return Error.Type;
                if (operands[2] < 2 or operands[2] > 4) return Error.Type;
                work.thing[id] = .matrix;
                work.points[id] = column;
                work.wide[id] = @intCast(operands[2]);
            },
            .type_array => {
                // Result, ElementType, Length, the length an integer
                // constant: what a block holds, each element ArrayStride
                // apart (since 1.161). A value of one is no step, as a
                // struct's is not.
                if (operands.len < 3) return Error.Body;
                const id = try idOf(operands[0]);
                const element = try idOf(operands[1]);
                // An integer's too, a word as a float's (since 1.169).
                switch (work.thing[element]) {
                    .float, .int, .vector, .matrix, .array, .structure => {},
                    // Of bools, or of structs of no offsets, which a
                    // variable of the function's own may be (since
                    // 1.176).
                    .boolean, .plain_struct => {},
                    else => return Error.Type,
                }
                if (isRuntime(work, element)) return Error.Type;
                const count = try indexOf(work, operands[2]);
                if (count == 0 or count == none) return Error.Storage;
                work.thing[id] = .array;
                work.points[id] = element;
                work.length[id] = count;
            },
            .type_runtime_array => {
                // Result, ElementType: an array of no length, the last
                // member of a storage buffer's block, its elements
                // ArrayStride apart. An access chain reaches any element
                // of it, at a constant index (since 1.164). Its length is
                // 0, which no array of a length has.
                if (operands.len < 2) return Error.Body;
                const id = try idOf(operands[0]);
                const element = try idOf(operands[1]);
                // An integer's too, a word as a float's (since 1.169).
                switch (work.thing[element]) {
                    .float, .int, .vector, .matrix, .array, .structure => {},
                    else => return Error.Type,
                }
                if (isRuntime(work, element)) return Error.Type;
                work.thing[id] = .array;
                work.points[id] = element;
                work.length[id] = 0;
            },
            .type_image => {
                // Result, SampledType, Dim, Depth, Arrayed, MS, Sampled,
                // ImageFormat. `look` has held the dimensionality to the
                // profile's and Sampled to 1 already: a 2D image, a 3D
                // one or a cube (since 1.179), each its `SamplerDim`. An
                // arrayed 2D one has its layer in TMUI; a cube of an
                // array needs SampledCubeArray, which `look` refuses, and
                // a 3D one cannot be arrayed (SPIR-V's OpTypeImage). A
                // multisampled one is not a texture at all. Depth is
                // taken whatever it says since 1.143: whether a sample
                // compares is its opcode's, not the type's, as SPIR-V has
                // it, and a depth image is read as any texture is.
                if (operands.len < 8) return Error.Body;
                const id = try idOf(operands[0]);
                if (work.thing[try idOf(operands[1])] != .float) return Error.Type;
                if (operands[3] > 2 or operands[4] > 1 or operands[5] != 0) return Error.Refused;
                const dim: spirv.Dim = @enumFromInt(operands[2]);
                const arrayed = operands[4] == 1;
                work.sampler_dim[id] = switch (dim) {
                    .dim_2d => if (arrayed) .layers else .flat,
                    .dim_3d => if (arrayed) return Error.Refused else .volume,
                    .cube => if (arrayed) return Error.Refused else .cube,
                    else => return Error.Refused,
                };
                work.thing[id] = .image;
            },
            .type_sampled_image => {
                if (operands.len < 2) return Error.Body;
                const id = try idOf(operands[0]);
                const image = try idOf(operands[1]);
                if (work.thing[image] != .image) return Error.Type;
                work.thing[id] = .sampled_image;
                work.points[id] = image;
                work.sampler_dim[id] = work.sampler_dim[image];
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
                if (work.thing[type_id] != .float and work.thing[type_id] != .int) return Error.Type;
                if (work.pool_count == work.pool.len) return Error.Uniforms;
                if (work.thing[type_id] == .int) {
                    // An index into a block, read as one by an access
                    // chain (`indexOf`), or since 1.165 an integer, a
                    // word of the pool as a float's is.
                    work.thing[id] = .int_constant;
                    work.points[id] = @intCast(work.pool_count);
                    work.wide[id] = 1;
                    work.pool[work.pool_count] = @bitCast(operands[2]);
                    work.pool_count += 1;
                    continue;
                }
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
                if (work.thing[type_id] == .matrix) {
                    // A matrix of constant columns, as vtn_const_ssa_value
                    // makes one: each column a load_const of its own
                    // (spirv_to_nir.c:544-552). Its columns are the ids
                    // of their constants here, steps the first time the
                    // matrix is read (`matrixOf`), as a constant is
                    // (since 1.162).
                    const columns = operands[2..];
                    if (columns.len != work.wide[type_id]) return Error.Body;
                    var made = Matrix{ .count = @intCast(columns.len) };
                    for (columns, 0..) |column, k| {
                        const member = try idOf(column);
                        if (work.thing[member] != .constant or work.wide[member] != work.wide[work.points[type_id]]) return Error.Type;
                        made.columns[k] = member;
                    }
                    work.thing[id] = .constant_matrix;
                    work.points[id] = try keptMatrix(work, made);
                    work.wide[id] = made.count;
                    continue;
                }
                if (work.thing[type_id] == .array or work.thing[type_id] == .plain_struct) {
                    // An array's or a struct's constant, which a variable
                    // of the function's own may start with or be stored
                    // from: the constants of its floats and vectors, in
                    // order, each made a step where it is read, as
                    // vtn_const_ssa_value builds the load_const of each
                    // element (spirv_to_nir.c:526-563). A constant read
                    // again is the step made the first time, the one
                    // load_const nir_opt_cse makes of them (since 1.176).
                    const members = operands[2..];
                    const count: usize = if (work.thing[type_id] == .array) work.length[type_id] else work.wide[type_id];
                    if (isRuntime(work, type_id) or members.len != count) return Error.Body;
                    const first = work.leaf_count;
                    for (members, 0..) |each, k| {
                        const member = try idOf(each);
                        const member_type = if (work.thing[type_id] == .array) work.points[type_id] else work.struct_members[work.points[type_id] + k];
                        try constantLeaves(work, member, member_type);
                    }
                    work.thing[id] = .constant_aggregate;
                    work.points[id] = @intCast(first);
                    work.aggregate[id] = type_id;
                    continue;
                }
                if (work.thing[type_id] != .vector) return Error.Type;
                const parts = operands[2..];
                if (parts.len != work.wide[type_id]) return Error.Body;
                if (work.pool_count + parts.len > work.pool.len) return Error.Uniforms;
                work.thing[id] = .constant;
                work.points[id] = @intCast(work.pool_count);
                work.wide[id] = @intCast(parts.len);
                for (parts) |part| {
                    const member = try idOf(part);
                    if (!isConstant(work, member) or work.wide[member] != 1) return Error.Type;
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
                    // All of its floats are inside the push constants.
                    if (work.thing[pointee] != .structure) return Error.Storage;
                    if (work.push_variable != none) return Error.Storage;
                    const block = findBlock(work, pointee) orelse return Error.Storage;
                    if (try sizeOf(work, pointee, none) > sdk.facet.shader.MAX_PUSH_CONSTANTS_SIZE) return Error.Storage;
                    work.thing[id] = .variable;
                    work.class[id] = @intCast(@intFromEnum(class));
                    work.points[id] = @intCast(block - &work.blocks[0]);
                    work.push_variable = id;
                    continue;
                }
                if (class == .uniform) {
                    // A uniform buffer: a block at a set and a binding,
                    // which v3dv's descriptor map gives a slot
                    // (lower_vulkan_resource_index, v3dv_pipeline.c), and
                    // the draw the buffer bound there (since 1.160). Or a
                    // storage buffer, whose block is BufferBlock, which
                    // SPIR-V 1.0 puts in this class too (since 1.164).
                    if (work.thing[pointee] != .structure) return Error.Storage;
                    const block = findBlock(work, pointee) orelse return Error.Storage;
                    if (work.set[id] == none or work.binding[id] == none) return Error.Location;
                    if (work.ubo_count == most_ubos) return Error.Declared;
                    work.thing[id] = .variable;
                    work.class[id] = @intCast(@intFromEnum(class));
                    work.points[id] = @intCast(work.ubo_count);
                    work.ubos[work.ubo_count] = .{ .block = @intCast(block - &work.blocks[0]), .set = work.set[id], .binding = work.binding[id], .storage = block.storage };
                    work.ubo_count += 1;
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
                    work.samplers[work.sampler_count] = .{ .set = work.set[id], .binding = work.binding[id], .dim = work.sampler_dim[pointee] };
                    work.sampler_count += 1;
                    continue;
                }
                if (class == .function) {
                    // A variable of the function's own, which Mesa makes
                    // values (nir_lower_vars_to_ssa, nir_to_vir.c:2240):
                    // a float or a vector of them, declared at the top of
                    // the first block as SPIR-V has it, and maybe given a
                    // constant to start with (since 1.155).
                    // A bool too, which glslc -O0 keeps a comparison in
                    // (since 1.165).
                    if (!in_body or blocks != 1 or flow != .body) return Error.Body;
                    switch (work.thing[pointee]) {
                        .array, .plain_struct, .matrix => if (work.scratch.placeOf(id)) |place| {
                            // One an access chain reaches at an index the
                            // body computes: in scratch memory at its
                            // place, each load and store of it a
                            // load_scratch and a store_scratch
                            // (nir_lower_vars_to_scratch, vir.c:2041-2044;
                            // `Scratch`), its initializer stored there at
                            // the top of the function (since 1.177).
                            work.thing[id] = .scratch_pointer;
                            work.class[id] = @intCast(@intFromEnum(class));
                            work.points[id] = pointee;
                            work.chain_base[id] = id;
                            work.chain_offset[id] = place;
                            work.chain_dynamic[id] = none;
                            work.chain_elements[id] = 1;
                            work.chain_path[id] = try pointerPath(work, .{ .variable = work.scratch.indexOf(id).? });
                            if (operands.len == 4) {
                                const initial = try idOf(operands[3]);
                                if (work.thing[initial] != .constant_aggregate and work.thing[initial] != .constant_matrix) return Error.Body;
                                try storeScratch(work, id, operands[3]);
                            } else if (operands.len != 3) return Error.Body;
                            continue;
                        } else {
                            // An array, a struct or a matrix: a variable of
                            // each of its floats and vectors, as
                            // nir_split_struct_vars splits a struct's
                            // members (v3dv_pipeline.c:411) and
                            // nir_split_array_vars an array's or a
                            // matrix's elements where every index is a
                            // constant (nir_to_vir.c:2236,
                            // mark_array_deref_used, nir_split_vars.c:
                            // 502-531), and nir_lower_vars_to_ssa makes
                            // each a value (since 1.176). An unrolled
                            // loop's counter is a constant by then, as
                            // nir_opt_loop_unroll runs in the same loop of
                            // passes.
                            var leaves: [most_locals]Leaf = undefined;
                            const count = try leafKinds(work, pointee, &leaves);
                            if (work.local_count + count > most_locals) return Error.Storage;
                            const first = work.local_count;
                            for (leaves[0..count], first..) |leaf, local| {
                                work.local_kind[local] = leaf.kind;
                                work.local_bool[local] = leaf.is_bool;
                                work.local_late[local] = work.scratch.isTree(id);
                                work.values[local] = @splat(unstored);
                            }
                            work.local_count += @intCast(count);
                            work.thing[id] = .local_aggregate;
                            work.class[id] = @intCast(@intFromEnum(class));
                            work.points[id] = @intCast(first);
                            work.aggregate[id] = pointee;
                            work.chain_base[id] = id;
                            if (operands.len == 4) {
                                // nir_lower_variable_initializers' stores,
                                // of each in order.
                                if (work.thing[try idOf(operands[3])] != .constant_aggregate and work.thing[try idOf(operands[3])] != .constant_matrix) return Error.Body;
                                try storeAggregate(work, id, operands[3]);
                            } else if (operands.len != 3) return Error.Body;
                            continue;
                        },
                        else => {},
                    }
                    const is_bool = work.thing[pointee] == .boolean;
                    const kind = if (is_bool) .f32x1 else kindOf(work, pointee) catch return Error.Storage;
                    if (work.local_count == most_locals) return Error.Storage;
                    const local = work.local_count;
                    work.thing[id] = .variable;
                    work.class[id] = @intCast(@intFromEnum(class));
                    work.points[id] = @intCast(local);
                    work.wide[id] = @intCast(kind.parts());
                    work.local_kind[local] = kind;
                    work.local_bool[local] = is_bool;
                    work.values[local] = @splat(unstored);
                    work.local_count += 1;
                    if (operands.len == 4) {
                        // There is no bool constant to start one with.
                        if (is_bool) return Error.Body;
                        // nir_lower_variable_initializers' store, at the
                        // top of the function.
                        if (!isConstant(work, try idOf(operands[3]))) return Error.Body;
                        const first = try operand(work, operands[3], kind);
                        for (0..kind.parts()) |k| work.values[local][k] = partOf(work, first, @intCast(k));
                        touch(work, @intCast(local));
                    } else if (operands.len != 3) return Error.Body;
                    continue;
                }
                if (class == .output and work.stage == .vertex and work.thing[pointee] == .structure) {
                    // gl_PerVertex, once (since 1.163).
                    const block = findBlock(work, pointee) orelse return Error.Storage;
                    if (!block.per_vertex or work.per_vertex != none) return Error.Outputs;
                    work.thing[id] = .variable;
                    work.class[id] = @intCast(@intFromEnum(class));
                    work.points[id] = @intCast(block - &work.blocks[0]);
                    work.per_vertex = id;
                    continue;
                }
                if (class == .input and systemOf(work, id) != null) {
                    // VertexIndex or InstanceIndex: a 32-bit integer, as
                    // Vulkan has them, of no location (since 1.192).
                    if (!isIntegerType(work, pointee) or try kindOf(work, pointee) != .f32x1) return Error.Type;
                    if (operands.len != 3) return Error.Body;
                    work.thing[id] = .variable;
                    work.class[id] = @intCast(@intFromEnum(class));
                    work.wide[id] = 1;
                    continue;
                }
                const floats = try kindOf(work, pointee);
                // An integer varying is a vertex program's to write, and a
                // fragment program's to read where it is Flat, as Vulkan
                // has it (since 1.190). An integer attribute is not
                // ported, and the tile buffer takes floats (since 1.165).
                if (isIntegerType(work, pointee) and class != .function) {
                    const varying = if (work.stage == .vertex) class == .output else class == .input and work.interpolation[id] == .flat;
                    if (!varying) return Error.Type;
                }
                work.thing[id] = .variable;
                work.class[id] = @intCast(@intFromEnum(class));
                work.wide[id] = @intCast(floats.parts());
                switch (class) {
                    .input => {
                        if (work.input_count == most_varyings) return Error.Varyings;
                        const at = work.location[id];
                        if (at == none) return Error.Location;
                        if (work.stage == .vertex and at >= most_attributes) return Error.Location;
                        work.points[id] = @intCast(work.input_count);
                        work.inputs[work.input_count] = .{ .location = at, .kind = floats, .first = 0, .interpolation = work.interpolation[id] };
                        work.input_count += 1;
                    },
                    // A vertex program's varying: at a location, which
                    // says where the fragment program reads it (since
                    // 1.163).
                    .output => if (work.stage == .vertex) {
                        if (work.location[id] == none) return Error.Location;
                    } else {
                        // One colour out, at location 0, of four floats:
                        // what the tile buffer takes without a
                        // configuration of its own (`qpu.zig`).
                        if (work.output_count != 0) return Error.Outputs;
                        if (work.location[id] != 0) return Error.Location;
                        if (floats != .f32x4) return Error.Type;
                        work.output = id;
                        work.output_count = 1;
                    },
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
                label = id;
                switch (flow) {
                    .body => {
                        // The function's first block; any other is a
                        // selection's, or one a top-level OpBranch went
                        // to: a loop's header, a block of a loop's, or
                        // its merge block (since 1.172).
                        blocks += 1;
                        if (blocks > 1) {
                            if (id != jumped) return Error.Branches;
                            jumped = 0;
                            if (loop.leaving and id == loop.merge) loop = .{};
                            if (!loop.active) {
                                block_at = @intCast(reader.at);
                                entry_values = work.values;
                                entry_steps = @intCast(work.step_count);
                            }
                        }
                    },
                    .arms => if (id == selection.merge) {
                        if (selection.yes != selection.merge and !selection.seen_yes) return Error.Branches;
                        if (selection.no != selection.merge and !selection.seen_no) return Error.Branches;
                        // The merge block is where the selection was, and
                        // where an arm read alone ends.
                        if (depth == 1) work.current_region = 0;
                        if (!selection.seen_yes or !selection.seen_no) selection.split = @intCast(work.step_count);
                        // A way in that is no arm leaves the variables
                        // as they were before the branch.
                        const level = depth - 1;
                        if (selection.yes == selection.merge) work.ends[level][0] = work.before[level];
                        if (selection.no == selection.merge) work.ends[level][1] = work.before[level];
                        // nir_opt_collapse_if (nir_opt_peephole_select.c:
                        // 412-506) takes a selection of no false arm that
                        // is all of the true arm of another of none, but
                        // for the block before it, into one selection on
                        // the two conditions' iand, ahead of flattening
                        // either (since 1.159). Where the inner selection
                        // or the outer has a false arm that leaves nothing
                        // in NIR, whether NIR's block is empty is not known
                        // here, and the shape is refused as before.
                        const no_else = selection.no == selection.merge or selection.quiet_no;
                        if (selection.collapses and no_else) {
                            if (selection.held.iand == none) return Error.Branches;
                            selection.collapsed = try collapseOf(work, selection, level, reader);
                        }
                        // A discard nested in an arm is terminate_if of
                        // the iand, which only the collapse makes.
                        if (selection.held.killed and !selection.collapsed) return Error.Discards;
                        if (selection.collapsed) {
                            // The inner selection is on the iand now.
                            const inner = selection.held;
                            for (work.steps[inner.selects_from..inner.selects_to]) |*each| {
                                if (each.tag == .select and each.a == inner.condition) each.a = inner.iand;
                            }
                        }
                        selection.arms_to = @intCast(work.step_count);
                        mergeCopies(work, selection, depth);
                        try merge(work, selection, level);
                        flow = .merging;
                    } else if (id == selection.yes and !selection.seen_yes) {
                        selection.armed(work, id, depth);
                        selection.seen_yes = true;
                        selection.enter(id);
                        flow = .arm;
                    } else if (id == selection.no and !selection.seen_no) {
                        selection.armed(work, id, depth);
                        selection.seen_no = true;
                        selection.enter(id);
                        flow = .arm;
                    } else return Error.Branches,
                    // After the block that drops the pixel, the merge
                    // block, where nothing is chosen.
                    .killed => {
                        if (id != selection.merge) return Error.Branches;
                        selection.arms_to = @intCast(work.step_count);
                        mergeCopies(work, selection, depth);
                        flow = .merging;
                    },
                    .branch, .arm, .merging => return Error.Branches,
                }
            },
            .selection_merge => {
                // MergeBlock, SelectionControl. Whether it asks for the
                // branch flattened or kept is a hint, which Mesa reads
                // only where it cannot flatten; here a selection is
                // flattened or refused. One in an arm is nested in that
                // selection, and taken first (since 1.156).
                if (!in_body or blocks == 0) return Error.Branches;
                if (flow != .body and flow != .arm) return Error.Branches;
                if (operands.len < 2) return Error.Body;
                if (depth == most_nesting) return Error.Branches;
                if (flow == .arm) {
                    selection.empty = false;
                    selection.quiet = false;
                    selection.lone = false;
                    selection.inner += 1;
                }
                // SelectionControl, which vtn reads as DontFlatten where
                // that is set, else Flatten, and fails on any other bit
                // (vtn_selection_control, vtn_structured_cfg.c:1328-1340).
                if (operands[1] != 0 and operands[1] & (flatten | dont_flatten) == 0) return Error.Branches;
                nest[depth] = .{ .merge = operands[0], .header = label, .outside = flow, .control = operands[1] };
                depth += 1;
                flow = .branch;
            },
            .branch_conditional => if (flow == .body) {
                // A loop's test, of no selection: taken where Mesa's
                // count says, as the comparison nothing reads any more
                // (since 1.172).
                if (!loop.active or two_ways or operands.len < 3) return Error.Branches;
                const out: usize = if (operands[1] == loop.merge) 1 else if (operands[2] == loop.merge) 2 else return Error.Branches;
                const on = operands[3 - out];
                came_from = label;
                if (loop.done < loop.continues) {
                    if (on == loop.header) {
                        if (loop.done == 0) try checkLoopCost(work, &loop);
                        loop.done += 1;
                        reader.at = loop.header_at;
                        label = loop.header;
                    } else jumped = on;
                } else {
                    if (loop.done == 0) try checkLoopCost(work, &loop);
                    loop.leaving = true;
                    jumped = loop.merge;
                    reader.at = loop.merge_at;
                }
            } else {
                // Condition, True Label, False Label, and maybe weights.
                // One of the two may be the merge block itself: an `if`
                // with no `else`, or the other way about.
                if (flow != .branch) return Error.Branches;
                if (operands.len < 3) return Error.Body;
                const condition = work.step_of[try idOf(operands[0])];
                if (condition == none or !isBool(work, condition)) return Error.Body;
                selection.condition = condition;
                selection.yes = operands[1];
                selection.no = operands[2];
                if (selection.yes == selection.no) return Error.Branches;
                // nir_opt_collapse_if's iand of this condition and the one
                // of the selection it is in, where it builds it: after the
                // block before this selection (:487-490). Made wherever
                // the two may collapse, and read only where they do; a
                // selection deeper in is not taken (since 1.159).
                if (depth == 2) {
                    const outer = &nest[0];
                    if (outer.arm == outer.yes and outer.no == outer.merge and outer.inner == 1 and selection.no == selection.merge)
                        selection.iand = try put(work, logicOf(.iand, condition, outer.condition));
                }
                selection.arms_from = @intCast(work.step_count);
                // A selection in no other may be kept a branch: its arms
                // are read into regions of their own until it is known
                // whether it is (since 1.171).
                if (depth == 1) selection.region = 2 * work.kept_count + 1;
                work.before[depth - 1] = work.values;
                flow = .arms;
            },
            .branch => if (flow == .body) {
                // To a loop's header, or a block of a loop or after one:
                // the next. The way back to a header is to its words
                // again, for the next trip (since 1.172).
                if (two_ways or operands.len < 1) return Error.Branches;
                const to = operands[0];
                came_from = label;
                if (loop.active and to == loop.header) {
                    if (loop.done == 0) try checkLoopCost(work, &loop);
                    loop.done += 1;
                    reader.at = loop.header_at;
                    label = loop.header;
                } else jumped = to;
            } else {
                // An arm's end, to the merge block. Any other OpBranch is
                // a jump to a block no selection names, or of no
                // structure.
                if (flow != .arm or operands.len < 1 or operands[0] != selection.merge) return Error.Branches;
                // What the arm leaves the variables holding, and the
                // other arm begins from what they held before. The block
                // it ends in is the way in a phi names.
                const side: u1 = if (selection.arm == selection.yes) 0 else 1;
                work.ends[depth - 1][side] = work.values;
                work.values = work.before[depth - 1];
                selection.ends_in[side] = label;
                if (side == 0) {
                    selection.collapses = selection.inner == 1 and selection.lone;
                    selection.quiet_yes = selection.quiet;
                    selection.constant_yes = selection.constant;
                } else selection.quiet_no = selection.quiet;
                flow = .arms;
            },
            .kill => {
                // Only as the true arm of a selection with no other, and
                // alone in it: the conditional discard, which Mesa makes
                // a terminate_if (nir_opt_peephole_select's `discard_ok`).
                // A pixel dropped always, or after other work in its arm,
                // is the family's and refused by its name; one beside an
                // else arm leaves the body going on in two places.
                // One in a nested selection's arm is terminate_if of the
                // two conditions' iand, once nir_opt_collapse_if has made
                // the two one (rewrite_instr, :351-410; since 1.159).
                if (flow != .arm or !selection.empty) return Error.Discards;
                if (depth > 1 and selection.iand == none) return Error.Discards;
                if (selection.arm != selection.yes or selection.no != selection.merge) return Error.Branches;
                _ = try put(work, .{ .tag = .discard, .kind = .f32x1, .a = if (depth > 1) selection.iand else selection.condition });
                selection.killed = true;
                flow = .killed;
            },
            .phi => if (flow == .body) {
                // A loop header's: on its trips after the first, the
                // value of the way back; else the value of the way the
                // walk came (since 1.172).
                if (blocks < 2 or settling == settled.len) return Error.Branches;
                const back = loop.active and label == loop.header;
                if (!back and operands.len > 4) two_ways = true;
                settled[settling] = try loopPhiOf(work, operands, if (back) loop.entered_from else came_from, back);
                settling += 1;
            } else {
                if (flow != .merging) return Error.Branches;
                try phiOf(work, selection, operands);
            },
            .loop_merge => {
                // MergeBlock, ContinueTarget, LoopControl and its
                // literals: a loop, planned the first time through its
                // header (since 1.172). Mesa keeps a loop in a loop, in
                // a selection's arm, or one asked not to be unrolled, a
                // loop; so is one nir_loop_analyze finds no trip count
                // of, and one over the limits.
                if (loop.active and label == loop.header) continue;
                if (flow != .body or loop.active or blocks < 2 or block_at == 0) return Error.Branches;
                if (operands.len < 3) return Error.Body;
                const control = operands[2];
                if (control & ~loop_controls != 0) return Error.Refused;
                if (control & loop_dont_unroll != 0) return Error.Branches;
                loop = .{
                    .header = label,
                    .merge = operands[0],
                    .header_at = block_at,
                    .entered_from = came_from,
                    .force = control & loop_unroll != 0,
                    .from = entry_steps,
                };
                try planLoop(work, reader.words, &loop, operands[1], &entry_values);
                loop.active = true;
                two_ways = false;
            },
            .returns => {
                if (flow != .body) return Error.Branches;
                returned = true;
            },
            .function_end => {},
            else => {
                if (!in_body or blocks == 0) return Error.Body;
                // A load or a store through an if-else tree in an arm or a
                // loop. The selection it is in stays a branch through the
                // loop of passes before the trees are made, where the
                // variable's loads and stores are still derefs
                // (nir_opt_peephole_select.c:109-129), and is flattened in
                // the one after with the tree's own; a loop has the tree's
                // instructions in its body when nir_opt_loop_unroll, in the
                // compile's own loop of passes, counts its cost
                // (nir_to_vir.c:2344-2347). Neither is here: refused (since
                // 1.178).
                if ((flow != .body or loop.active) and accessesTree(work, instruction)) return Error.Branches;
                var texture = false;
                switch (flow) {
                    .body => {},
                    // An arm Mesa flattens holds ALU work and loads it may
                    // run where the arm is not taken
                    // (block_check_for_allowed_instrs,
                    // nir_opt_peephole_select.c:59-326): a sample, which
                    // is a texture instruction, or the colour stored, is
                    // neither, and the selection stays a branch.
                    // Such a selection is kept a branch (since 1.171).
                    .arm => switch (instruction.op) {
                        // A query of the image's is a tex instruction too
                        // (since 1.181). One the arm repeats of a tex
                        // before the selection is not: v3d's loop runs
                        // nir_opt_cse before nir_opt_peephole_select
                        // (nir_to_vir.c:2265, :2269-2279), which finds
                        // the arm without it (since 1.185).
                        .image_sample_implicit_lod, .image_sample_dref_implicit_lod, .image_sample_explicit_lod, .image_sample_dref_explicit_lod, .image_fetch, .image_query_size_lod, .image_query_levels => texture = true,
                        // An atomic or a barrier is neither either: it
                        // would run where the arm is not taken (since
                        // 1.169).
                        .atomic_load, .atomic_store, .atomic_exchange, .atomic_compare_exchange, .atomic_compare_exchange_weak, .atomic_i_increment, .atomic_i_decrement, .atomic_i_add, .atomic_i_sub, .atomic_s_min, .atomic_u_min, .atomic_s_max, .atomic_u_max, .atomic_and, .atomic_or, .atomic_xor, .memory_barrier => try selection.keep(work, depth),
                        // A store into a variable of the function's own
                        // is a value the merge chooses, a load and a store
                        // nir_lower_vars_to_ssa leaves none of (since
                        // 1.155); one into the colour out is a store.
                        .store => if (storesLocal(work, operands)) {
                            selection.empty = false;
                            // A constant stored leaves the load_const vtn
                            // builds for it in the block (vtn_const_ssa_value),
                            // unless nir_opt_cse finds one before it: whether
                            // the block is empty in NIR is not known here.
                            if (storesConstant(work, operands)) {
                                selection.constant = true;
                                if (selection.held.iand != none) selection.held.constant_after = true;
                            }
                        } else if (storesBuffer(work, operands) or storesScratch(work, operands)) {
                            // A store_ssbo or a store_scratch is an
                            // intrinsic block_check_for_allowed_instrs lets
                            // none of through (nir_opt_peephole_select.c:109-129;
                            // scratch since 1.177).
                            try selection.keep(work, depth);
                        } else return Error.Branches,
                        else => {
                            selection.empty = false;
                            if (!quietOf(work, instruction)) {
                                selection.quiet = false;
                                selection.lone = false;
                            }
                        },
                    },
                    else => return Error.Branches,
                }
                try step(work, instruction);
                if (texture and !takenBefore(work, work.step_of[try idOf(operands[1])])) try selection.keep(work, depth);
            },
        }
    }
    if (loop.active or jumped != 0) return Error.Branches;
    try interpolatedVaryings(work);
    if (work.stage == .vertex) return finishVertex(work);
    if (work.output_count == 0) return Error.Outputs;
    if (work.stored == none) return Error.NoColor;
    try algebraic(work);
    try order(work);
}

/// A `Flat` or a `NoPerspective` decorates a fragment program's input or a
/// vertex program's output, the varyings vtn reads it of
/// (vtn_variables.c:1370-1374); of anything else it is refused, not
/// dropped (since 1.190).
fn interpolatedVaryings(work: *const Work) Error!void {
    const varying: spirv.StorageClass = if (work.stage == .vertex) .output else .input;
    for (work.interpolation, 0..) |each, id| {
        if (each == .smooth) continue;
        if (work.thing[id] != .variable or work.class[id] != @intFromEnum(varying)) return Error.Refused;
    }
}

/// A vertex program's end: its varyings stored where the fragment program
/// reads them, the outputs the position makes, the program optimized, and
/// what of its attributes it reads (since 1.163).
fn finishVertex(work: *Work) Error!void {
    if (work.position == none) return Error.Outputs;
    // VertexIndex and InstanceIndex decorate an input variable alone.
    for (work.system_ids) |id| {
        if (id != none and (work.thing[id] != .variable or work.class[id] != @intFromEnum(spirv.StorageClass.input))) return Error.Refused;
    }
    // gl_PointSize's row after the fixed-function outputs, before the
    // varyings: per_vertex_point_size, which v3dv sets of any vertex
    // shader that writes it whatever the pipeline draws (v3dv_pipeline.c:
    // 1375-1376, 1418-1419), and v3d_nir_setup_vpm_layout_vs's
    // psiz_vpm_offset (v3d_nir_lower_io.c:427-428; since 1.193).
    const point_size_at = work.varyings_vpm_offset;
    if (work.point_size != none) work.varyings_vpm_offset += 1;
    for (work.varying_values[0..work.varying_count], work.varying_into[0..work.varying_count], 0..) |value, into, k| {
        if (work.point_size != none and k == work.point_size_order) try output(work, work.point_size, point_size_at);
        try storeVarying(work, value, work.location[into], work.wide[into]);
    }
    if (work.point_size != none and work.point_size_order == work.varying_count) try output(work, work.point_size, point_size_at);
    try fixedOutputs(work);
    try algebraic(work);
    try attributes(work);
}

/// Where the fragment program reads `component` of `location` among the
/// floats it reads, or null where it does not: v3d_varying_slot_vpm_offset
/// (v3d_nir_lower_io.c:93-121), of the key's used_outputs, which are the
/// fragment program's floats in order. The coordinate program's are none:
/// they would be transform feedback's (pipeline_populate_v3d_vs_key,
/// v3dv_pipeline.c:1422-1429).
fn slotOf(key: *const VertexKey, location: u32, component: u32) ?u32 {
    if (key.coordinate or location >= most_varyings or component >= key.reads[location]) return null;
    var before: u32 = 0;
    for (key.reads[0..location]) |each| before += each;
    return before + component;
}

/// The floats the fragment program reads of how many of them there are.
fn usedOutputs(key: *const VertexKey) u32 {
    if (key.coordinate) return 0;
    var count: u32 = 0;
    for (key.reads) |each| count += each;
    return count;
}

/// One varying's stores, a float each where the fragment program reads it
/// (v3d_nir_lower_vpm_output, v3d_nir_lower_io.c:194-217).
fn storeVarying(work: *Work, value: u16, location: u32, floats: u32) Error!void {
    for (0..floats) |k| {
        const slot = slotOf(&work.vertex_key, location, @intCast(k)) orelse continue;
        const bit = @as(u32, 1) << @intCast(slot);
        work.varyings_stored |= bit;
        try output(work, try floatOf(work, partOf(work, value, @intCast(k))), work.varyings_vpm_offset + slot);
    }
}

fn output(work: *Work, value: u16, at: u32) Error!void {
    _ = try put(work, .{ .tag = .output, .kind = .f32x1, .a = value, .at = at });
}

/// v3d_nir_emit_ff_vpm_outputs (v3d_nir_lower_io.c:493-586), where the
/// program ends: 1/Wc; the coordinate program's position; the place on
/// screen, each of x and y times its scale and 1/Wc rounded to 1/64ths
/// of a pixel; the vertex program's Zs and 1/Wc; and 0 for what the
/// fragment program reads and nothing stored.
fn fixedOutputs(work: *Work) Error!void {
    var position: [4]u16 = undefined;
    for (&position, 0..) |*each, k| each.* = try floatOf(work, partOf(work, work.position, @intCast(k)));
    const rcp_wc = try unary(work, .recip, position[3]);
    const coordinate = work.vertex_key.coordinate;
    if (coordinate) for (position, 0..) |each, k| try output(work, each, @intCast(k));
    const vp: u32 = if (coordinate) 4 else 0;
    for (0..2) |k| {
        const scale = try put(work, .{ .tag = .viewport, .kind = .f32x1, .at = @intFromEnum(if (k == 0) Viewport.x_scale else Viewport.y_scale) });
        const scaled = try binary(work, .mul, try binary(work, .mul, position[k], scale), rcp_wc);
        try output(work, try put(work, .{ .tag = .round_to_int, .kind = .f32x1, .a = scaled }), vp + @as(u32, @intCast(k)));
    }
    if (!coordinate) {
        const scale = try put(work, .{ .tag = .viewport, .kind = .f32x1, .at = @intFromEnum(Viewport.z_scale) });
        const z = try binary(work, .mul, try binary(work, .mul, position[2], scale), rcp_wc);
        const offset = try put(work, .{ .tag = .viewport, .kind = .f32x1, .at = @intFromEnum(Viewport.z_offset) });
        try output(work, try binary(work, .add, z, offset), 2);
        try output(work, rcp_wc, 3);
    }
    for (0..usedOutputs(&work.vertex_key)) |slot| {
        if (work.varyings_stored & @as(u32, 1) << @intCast(slot) != 0) continue;
        try output(work, try immediate(work, 0), work.varyings_vpm_offset + @as(u32, @intCast(slot)));
    }
}

/// The floats of each step something live reads, a bit each: what
/// nir_opt_dce leaves of a program nir_lower_alu_to_scalar has made a
/// float an instruction. An output and a discard are live, and so is
/// what a live float is computed from: the same float of an operand of
/// an operation float by float, the one of a scalar, and every float of
/// what anything else reads.
fn liveFloats(work: *const Work) [most_steps]u8 {
    var reads: [most_steps]u8 = @splat(0);
    var at = work.step_count;
    while (at > 0) {
        at -= 1;
        const each = work.steps[at];
        if (each.tag == .output or each.tag == .discard) reads[at] = 1;
        const floats = reads[at];
        if (floats == 0) continue;
        switch (each.tag) {
            .component => reads[each.a] |= @as(u8, 1) << @intCast(each.at),
            .construct => for (0..each.kind.parts()) |k| {
                if (floats & @as(u8, 1) << @intCast(k) != 0) reads[each.from[k]] |= @as(u8, 1) << @intCast(each.part[k]);
            },
            .add, .mul, .sub, .min, .max, .negate, .abs, .sat, .sin, .cos, .sign, .floor, .ceil, .trunc, .round, .recip, .rsqrt, .exp2, .log2, .round_to_int, .select, .logic, .compare, .set_less, .output, .discard => {
                for (readsOf(each)) |field| if (field) |operand_at| {
                    reads[operand_at] |= if (work.steps[operand_at].kind == .f32x1) 1 else floats;
                };
            },
            else => for (readsOf(each)) |field| if (field) |operand_at| {
                reads[operand_at] |= @intCast((@as(u32, 1) << @intCast(work.steps[operand_at].kind.parts())) - 1);
            },
        }
    }
    return reads;
}

/// The attributes numbered by location, and the floats of each the
/// program reads: the highest it reads and those below it, which is what
/// the VPM is given (ntq_setup_vs_inputs, nir_to_vir.c:2385-2410). Then
/// the VPM's output, the fixed-function outputs and the varyings
/// (v3d_nir_setup_vpm_layout_vs, :434).
///
/// Before the attributes, a row of each of the VPM's values the program
/// reads (ntq_setup_vs_inputs, :2416-2438): what nir_opt_dce leaves of its
/// loads, which pipeline_lower_nir gathers (v3dv_pipeline.c:1875) once the
/// vertex shader is linked to the fragment shader (link_shaders,
/// :1825-1860), so what the vertex program reads, and the coordinate
/// program the vertex program's (`VertexKey.system_values`). An
/// attribute's first float is after them (ntq_emit_load_input,
/// nir_to_vir.c:2948-2961), and in the coordinate program GFXH-1602's row
/// of the first driver location where it reads none of it (:2963-2973;
/// since 1.192).
fn attributes(work: *Work) Error!void {
    const inputs = work.inputs[0..work.input_count];
    for (inputs, 0..) |each, k| {
        for (inputs[0..k]) |before| if (before.location == each.location) return Error.Location;
    }
    const reads = liveFloats(work);
    const coordinate = work.vertex_key.coordinate;
    var values: SystemValues = if (coordinate) work.vertex_key.system_values else .{};
    for ([_]SystemValue{ .instance_id, .base_instance, .vertex_id }) |which| {
        const at = work.system_step[@intFromEnum(which)];
        if (at == none or reads[at] == 0) continue;
        switch (which) {
            .instance_id => values.instance_id = true,
            .base_instance => values.base_instance = true,
            .vertex_id => values.vertex_id = true,
            .first_vertex => unreachable,
        }
    }
    work.system_values = values;
    const builtins = values.count();
    var first: u32 = builtins;
    var driver: u32 = 0;
    for (0..most_attributes) |location| {
        const which = for (inputs, 0..) |each, k| {
            if (each.location == location) break k;
        } else continue;
        const each = &inputs[which];
        each.live = if (each.step != none) reads[each.step] else 0;
        const size: u8 = if (each.live == 0) 0 else 8 - @clz(each.live);
        each.first = first;
        first += size;
        if (driver == 0 and coordinate and size == 0 and builtins > 0) {
            first += 1;
            work.first_row = true;
        }
        work.vattr_sizes[driver] = size;
        work.attribute_location[driver] = @intCast(location);
        driver += 1;
    }
    work.attribute_count = driver;
    work.vpm_output_size = @max(1, work.varyings_vpm_offset + usedOutputs(&work.vertex_key));
}

fn idOf(word: u32) Error!u16 {
    if (word == 0 or word >= most_ids) return Error.Refused;
    return @intCast(word);
}

// --- loops -------------------------------------------------------------------
//
// A loop is unrolled as Mesa unrolls it (since 1.172). v3dv sets
// max_unroll_iterations to 16 (v3dv_pipeline.c:215), and v3d's
// optimization loop runs nir_opt_loop_unroll where it has a compile
// (nir_to_vir.c:2344-2349), under every strategy facet ports
// (vir.c:2214-2221). Before that, the preprocessing's own rounds of
// v3d_optimize_nir (v3dv_pipeline.c:413, 443), which never unroll, have
// run nir_opt_loop (nir_to_vir.c:2287): a loop whose first test follows
// its first block is peeled into do-while form there
// (opt_loop_peel_initial_break, nir_opt_loop.c:412-502), the first test
// before it and in it the test after the step. So the trip count
// nir_loop_analyze finds is one less than the times the body runs, for a
// for loop as for a do-while.
//
// simple_unroll (nir_opt_loop_unroll.c:104-209) puts the loop's blocks
// before its test once, and then, for each trip, the blocks after it and
// those before it again. The walk does the same: it goes through the
// loop's words once for each time Mesa's copy of them runs, each header
// phi the value its way in brings, and leaves to the merge block when
// the trips are done. What is left is straight-line steps, and the test
// of each trip a comparison nothing reads, which nir_opt_dce takes.

/// LoopControl's bits (SPIR-V 3.23): Unroll, DontUnroll, and the seven
/// vtn reads as none (vtn_loop_control, vtn_structured_cfg.c:1458-1478);
/// any other is vtn_fail.
const loop_unroll: u32 = 0x1;
const loop_dont_unroll: u32 = 0x2;
const loop_controls: u32 = 0x1ff;

/// v3dv's max_unroll_iterations (v3dv_pipeline.c:215) and
/// nir_opt_loop_unroll's LOOP_UNROLL_LIMIT (nir_opt_loop_unroll.c:36):
/// a loop of a known trip count is unrolled where its count is at most
/// the first, and its cost times its count at most the two multiplied
/// (check_unrolling_restrictions, :898-931).
const max_unroll_iterations = 16;
const loop_unroll_limit = 26;

/// A loop as `read` unrolls it.
const Loop = struct {
    /// Its header block, and the block after it.
    header: u32 = 0,
    merge: u32 = 0,
    /// Where the header's instructions start, past its OpLabel, and where
    /// the merge block's OpLabel is: where each trip starts again, and
    /// where the walk goes on when they are done.
    header_at: u32 = 0,
    merge_at: u32 = 0,
    /// The block that branched into the header: its phis' way in.
    entered_from: u32 = 0,
    /// How many times the test's way on is taken, and how many of them
    /// the walk has gone.
    continues: u32 = 0,
    done: u32 = 0,
    /// The trip count Mesa holds to its limits.
    trips: u32 = 0,
    /// LoopControl's Unroll, which unrolls past the limits
    /// (check_unrolling_restrictions, :901-902).
    force: bool = false,
    /// The steps before its first trip, which `loopCost` counts from.
    from: u16 = 0,
    active: bool = false,
    leaving: bool = false,
};

/// A header phi's value for a trip, set with the others once all are
/// read: a block's phis take their values together.
const Settled = struct { id: u16, step: u16 };
const most_settled = 16;

/// What `planLoop` keeps of each id the loop makes: the instruction, its
/// first two operands, where it is in the loop's words, and whether it is
/// at the loop's top level, in no selection's arm
/// (compute_induction_information's test that a source's block is the
/// loop's own, nir_loop_analyze.c:275-279). An OpLoad of a variable of the
/// function's own holds the value it reads: the id last stored into it
/// on the way there, or the variable with `local_bit` where the trip has
/// stored nothing into it yet, which is the phi nir_lower_vars_to_ssa
/// puts in the header; 0 where it is not known.
const Defined = struct {
    op: spirv.Op = .nop,
    a: u16 = 0,
    b: u16 = 0,
    order: u16 = 0,
    top: bool = false,
};
const local_bit: u16 = 0x8000;

/// NIR's comparisons a loop's test may be (nir_is_supported_terminator_
/// condition, nir_loop_analyze.h:107-118).
const Cmp = enum { flt, fge, feq, fneu, ilt, ige, ieq, ine, ult, uge };

/// The operations an induction variable steps by
/// (compute_induction_information, nir_loop_analyze.c:296-301).
const Update = enum { iadd, fadd, imul, fmul, ishl, ishr, ushr };

/// A basic induction variable: a header phi of a constant way in, whose
/// way back is one of `Update` of it and a constant.
const Induction = struct {
    init: u32,
    update: Update,
    step: u32,
    phi_first: bool,

    /// The update def from the phi's value.
    fn next(induction: Induction, value: u32) u32 {
        return if (induction.phi_first) updated(induction.update, value, induction.step) else updated(induction.update, induction.step, value);
    }
};

/// The loop's test as nir_loop_analyze has it: the comparison, its
/// constant, which side that is on, whether the loop goes on where the
/// comparison holds (`invert_cond`), and whether it compares the update
/// def rather than the phi.
const Test = struct {
    cmp: Cmp,
    limit: u32,
    limit_rhs: bool,
    invert: bool,
    on_def: bool,

    /// Whether the loop leaves at the test where the phi holds `value`.
    fn breaks(test_of: Test, induction: Induction, value: u32) bool {
        const tested = if (test_of.on_def) induction.next(value) else value;
        const holds = if (test_of.limit_rhs) comparedBits(test_of.cmp, tested, test_of.limit) else comparedBits(test_of.cmp, test_of.limit, tested);
        return if (test_of.invert) !holds else holds;
    }
};

/// A 32-bit comparison as nir_eval_const_opcode folds it.
fn comparedBits(cmp: Cmp, x: u32, y: u32) bool {
    const fx: f32 = @bitCast(x);
    const fy: f32 = @bitCast(y);
    const sx: i32 = @bitCast(x);
    const sy: i32 = @bitCast(y);
    return switch (cmp) {
        .flt => fx < fy,
        .fge => fx >= fy,
        .feq => fx == fy,
        .fneu => fx != fy,
        .ilt => sx < sy,
        .ige => sx >= sy,
        .ieq => x == y,
        .ine => x != y,
        .ult => x < y,
        .uge => x >= y,
    };
}

/// A 32-bit update as nir_eval_const_opcode folds it, a shift by the low
/// five bits of its amount (nir_opcodes.py).
fn updated(update: Update, x: u32, y: u32) u32 {
    return switch (update) {
        .iadd => x +% y,
        .imul => x *% y,
        .fadd => @bitCast(@as(f32, @bitCast(x)) + @as(f32, @bitCast(y))),
        .fmul => @bitCast(@as(f32, @bitCast(x)) * @as(f32, @bitCast(y))),
        .ishl => x << @intCast(y & 31),
        .ishr => @bitCast(@as(i32, @bitCast(x)) >> @intCast(y & 31)),
        .ushr => x >> @intCast(y & 31),
    };
}

/// invert_comparison_if_needed (nir_loop_analyze.c:719-749).
fn invertedIf(cmp: Cmp, invert: bool) Cmp {
    if (!invert) return cmp;
    return switch (cmp) {
        .fge => .flt,
        .ige => .ilt,
        .uge => .ult,
        .flt => .fge,
        .ilt => .ige,
        .ult => .uge,
        .feq => .fneu,
        .ieq => .ine,
        .fneu => .feq,
        .ine => .ieq,
    };
}

/// get_iteration (nir_loop_analyze.c:751-820): the trip count of an
/// induction stepped by addition, from the span to the limit; null for
/// its -1.
fn getIteration(test_of: Test, induction: Induction) ?i32 {
    const initial = induction.init;
    const stride = induction.step;
    const limit = test_of.limit;
    switch (invertedIf(test_of.cmp, test_of.invert)) {
        // In order for execution to be here, limit is initial; the loop
        // runs once unless the step is zero (:760-766).
        .ine => return if (stride == 0) null else 1,
        .ige, .ilt, .ieq => {
            const span: i32 = @bitCast(limit -% initial);
            const by: i32 = @bitCast(stride);
            // nir_opcodes.py's idiv and udiv (:869-870): 0 where they
            // divide by 0, or the least int by -1.
            const iter: u32 = if (by == 0 or (span == std.math.minInt(i32) and by == -1)) 0 else @bitCast(@divTrunc(span, by));
            return if (iter > std.math.maxInt(i32)) null else @intCast(iter);
        },
        .uge, .ult => {
            const span = limit -% initial;
            const iter: u32 = if (stride == 0) 0 else span / stride;
            return if (iter > std.math.maxInt(i32)) null else @intCast(iter);
        },
        // (initial + step) == initial ? -1 : 1 (:782-797).
        .fneu => {
            const span: f32 = @as(f32, @bitCast(initial)) + @as(f32, @bitCast(stride));
            return if (span == @as(f32, @bitCast(initial))) null else 1;
        },
        .fge, .flt, .feq => {
            const span = @as(f32, @bitCast(limit)) - @as(f32, @bitCast(initial));
            const quotient = span / @as(f32, @bitCast(stride));
            // f2i64, then the count read as an int: what is out of
            // range or not a number comes to -1 on either host's
            // conversion.
            if (std.math.isNan(quotient) or @abs(quotient) >= 9.2e18) return null;
            const iter: i64 = @intFromFloat(quotient);
            if (iter < 0) return null;
            return @bitCast(@as(u32, @truncate(@as(u64, @intCast(iter)))));
        },
    }
}

/// test_iterations (nir_loop_analyze.c:880-927): whether the loop leaves
/// at the test after `iter` steps, the phi `initial` plus `iter` times
/// the step.
fn testIterations(iter: i32, test_of: Test, induction: Induction) bool {
    const float = induction.update == .fadd;
    const count: u32 = if (float) @bitCast(@as(f32, @floatFromInt(iter))) else @bitCast(iter);
    const product = updated(if (float) .fmul else .imul, count, induction.step);
    const sum = updated(if (float) .fadd else .iadd, product, induction.init);
    const holds = if (test_of.limit_rhs) comparedBits(test_of.cmp, sum, test_of.limit) else comparedBits(test_of.cmp, test_of.limit, sum);
    return if (test_of.invert) !holds else holds;
}

/// calculate_iterations (nir_loop_analyze.c:929-1048), with
/// will_break_on_first_iteration (:861-878) and get_iteration_empirical
/// (:822-859): the loop's trip count, or null for its -1.
fn tripCount(test_of: Test, induction: Induction) ?u32 {
    // A test of the update def steps the initial value first (:957-969).
    const trip_offset: i32 = if (test_of.on_def) 1 else 0;
    if (test_of.breaks(induction, induction.init)) return 0;
    const iter = switch (induction.update) {
        .iadd, .fadd => getIteration(test_of, induction) orelse return null,
        // A floating-point product is not counted (:992-999).
        .fmul => return null,
        // The others are tried, a trip at a time (:1000-1006).
        .imul, .ishl, .ishr, .ushr => {
            var count: u32 = 0;
            var value = induction.init;
            while (count <= max_unroll_iterations) : (count += 1) {
                if (test_of.breaks(induction, value)) return count;
                value = induction.next(value);
            }
            return null;
        },
    };
    if (iter < 0) return null;
    const actual = invertedIf(test_of.cmp, test_of.invert);
    if (actual == .ine or actual == .fneu) return @intCast(iter);
    // The count tested a trip either way, for an ill-formed loop or one
    // off by one (:1022-1045).
    var bias: i32 = -1;
    while (bias <= 1) : (bias += 1) {
        const biased = @as(i64, iter) + bias;
        if (biased < 1 or biased > std.math.maxInt(i32)) continue;
        if (testIterations(@intCast(biased), test_of, induction)) return @intCast(biased - trip_offset);
    }
    return null;
}

/// The comparison NIR makes of a SPIR-V one, its operands swapped where
/// NIR has only the other way about (vtn_alu.c:369-396), and wrapped in
/// an inot for the unordered ones (vtn_alu.c:953-985).
const Compared = struct { cmp: Cmp, swap: bool = false, negate: bool = false };
fn comparedOf(op: spirv.Op) ?Compared {
    return switch (op) {
        .s_less_than => .{ .cmp = .ilt },
        .s_greater_than => .{ .cmp = .ilt, .swap = true },
        .s_greater_than_equal => .{ .cmp = .ige },
        .s_less_than_equal => .{ .cmp = .ige, .swap = true },
        .u_less_than => .{ .cmp = .ult },
        .u_greater_than => .{ .cmp = .ult, .swap = true },
        .u_greater_than_equal => .{ .cmp = .uge },
        .u_less_than_equal => .{ .cmp = .uge, .swap = true },
        .i_equal => .{ .cmp = .ieq },
        .i_not_equal => .{ .cmp = .ine },
        .f_ord_less_than => .{ .cmp = .flt },
        .f_ord_greater_than => .{ .cmp = .flt, .swap = true },
        .f_ord_greater_than_equal => .{ .cmp = .fge },
        .f_ord_less_than_equal => .{ .cmp = .fge, .swap = true },
        .f_ord_equal => .{ .cmp = .feq },
        .f_unord_not_equal => .{ .cmp = .fneu },
        .f_unord_less_than => .{ .cmp = .fge, .negate = true },
        .f_unord_greater_than => .{ .cmp = .fge, .swap = true, .negate = true },
        .f_unord_less_than_equal => .{ .cmp = .flt, .swap = true, .negate = true },
        .f_unord_greater_than_equal => .{ .cmp = .flt, .negate = true },
        else => null,
    };
}

/// The instructions of the profile that make no result, which `planLoop`
/// does not take an id from.
fn makesNothing(op: spirv.Op) bool {
    return switch (op) {
        .store, .branch, .branch_conditional, .selection_merge, .loop_merge, .label, .returns, .return_value, .function_end, .kill, .memory_barrier, .atomic_store, .nop => true,
        else => false,
    };
}

/// The 32 bits of a float a variable holds, where it is a constant.
fn floatBits(work: *const Work, of: Float) ?u32 {
    if (of.step == none) return null;
    const each = work.steps[of.step];
    if (each.tag != .constant or of.part >= each.kind.parts()) return null;
    return @bitCast(work.pool[each.at + of.part]);
}

/// A constant float or integer the walk holds for an id made before the
/// loop: its 32 bits, from its step, or from the pool where it is an
/// OpConstant no instruction has read yet.
fn constantBits(work: *const Work, id: u16) ?u32 {
    const at = work.step_of[id];
    if (at == none) {
        if (!isConstant(work, id) or work.wide[id] != 1) return null;
        return @bitCast(work.pool[work.points[id]]);
    }
    const of = work.steps[at];
    if (of.tag != .constant or of.kind != .f32x1) return null;
    return @bitCast(work.pool[of.at]);
}

/// nir_loop_analyze for the loop whose header `loop` names
/// (find_loop_terminators, compute_induction_information and
/// find_trip_count, nir_loop_analyze.c:248-398, 1141-1366): its words
/// read through once, without a step made, for the one test it leaves
/// at, the basic induction variable that test compares with a constant,
/// and the trip count of the two. A loop of no such test, or of more than
/// one way out or back - a break or a continue in an arm, a second
/// conditional branch out, a loop in it - is one nir_loop_analyze finds
/// no exact count of, or complex_loop, and Mesa keeps it a loop:
/// `Error.Branches`.
fn planLoop(work: *Work, words: []const u32, loop: *Loop, continue_target: u32, entry: *const Values) Error!void {
    const defined = &work.loop_defined;
    @memset(defined, .{});
    var reader = spirv.Reader{ .words = words, .at = loop.header_at };
    var merges: [most_nesting]u32 = undefined;
    var open: u32 = 0;
    // The id last stored into each variable at the top level, and which
    // were stored into in an arm, whose phi is not a basic induction.
    var stored: [most_locals]u16 = @splat(0);
    var in_arm: [most_locals]bool = @splat(false);
    // The header's phis: each its value on the way in and on the way back.
    const Phi = struct { id: u16, values: [2]u16, parents: [2]u32 };
    var phis: [most_settled]Phi = undefined;
    var phi_count: u32 = 0;
    const Leaving = struct { condition: u16, yes: u32, no: u32, order: u16 };
    var leaving: ?Leaving = null;
    var back_edges: u32 = 0;
    var back_from: u32 = 0;
    // A selection before the test: the test is then not the first
    // control flow after the header block, which the peel asks for.
    var selection_before = false;
    var heading = false;
    var place: u16 = 0;
    var label = loop.header;
    var headers: u32 = 0;
    while (true) {
        const at: u32 = @intCast(reader.at);
        const instruction = (reader.next() catch return Error.Refused) orelse return Error.Branches;
        const operands = instruction.operands();
        place +|= 1;
        switch (instruction.op) {
            .label => {
                if (operands.len < 1) return Error.Body;
                const id = operands[0];
                if (id == loop.merge) {
                    if (open != 0) return Error.Branches;
                    loop.merge_at = at;
                    break;
                }
                if (open > 0 and id == merges[open - 1]) open -= 1;
                label = id;
            },
            .loop_merge => {
                headers += 1;
                if (headers > 1) return Error.Branches;
            },
            .selection_merge => {
                if (operands.len < 1) return Error.Body;
                if (open == merges.len) return Error.Branches;
                merges[open] = operands[0];
                open += 1;
                heading = true;
                if (leaving == null) selection_before = true;
            },
            .branch_conditional => {
                if (heading) {
                    // A selection's: neither way may leave the loop or
                    // go to its continue target but through its merge.
                    heading = false;
                    if (operands.len < 3) return Error.Body;
                    for (operands[1..3]) |to| {
                        if (to == loop.merge or to == loop.header) return Error.Branches;
                        if (to == continue_target and merges[open - 1] != continue_target) return Error.Branches;
                    }
                    continue;
                }
                // A conditional branch of no selection: the loop's test.
                // One in an arm, or a second, is a break or a continue
                // that leaves the loop complex.
                if (open != 0 or leaving != null or operands.len < 3) return Error.Branches;
                const yes = operands[1];
                const no = operands[2];
                if (yes == no or (yes != loop.merge and no != loop.merge)) return Error.Branches;
                leaving = .{ .condition = try idOf(operands[0]), .yes = yes, .no = no, .order = place };
                if ((if (yes == loop.merge) no else yes) == loop.header) {
                    back_edges += 1;
                    back_from = label;
                }
            },
            .branch => {
                if (operands.len < 1) return Error.Body;
                const to = operands[0];
                if (to == loop.header) {
                    if (open != 0) return Error.Branches;
                    back_edges += 1;
                    back_from = label;
                } else if (to == loop.merge) {
                    return Error.Branches;
                } else if (to == continue_target and open != 0 and merges[open - 1] != continue_target) {
                    return Error.Branches;
                }
            },
            .phi => {
                if (operands.len < 2) return Error.Body;
                const id = try idOf(operands[1]);
                defined[id] = .{ .op = .phi, .order = place, .top = open == 0 };
                if (label == loop.header) {
                    if (operands.len != 6 or phi_count == phis.len) return Error.Branches;
                    phis[phi_count] = .{ .id = id, .values = .{ try idOf(operands[2]), try idOf(operands[4]) }, .parents = .{ operands[3], operands[5] } };
                    phi_count += 1;
                }
            },
            .load => {
                if (operands.len < 3) return Error.Body;
                const id = try idOf(operands[1]);
                const from = try idOf(operands[2]);
                var value: u16 = 0;
                if (isLocal(work, from) and open == 0) {
                    const local = work.points[from];
                    if (!in_arm[local]) value = if (stored[local] == 0) local_bit | local else stored[local];
                }
                defined[id] = .{ .op = .load, .a = value, .order = place, .top = open == 0 };
            },
            .store => {
                if (operands.len < 2) return Error.Body;
                const into = try idOf(operands[0]);
                if (isLocal(work, into)) {
                    const local = work.points[into];
                    if (open == 0) stored[local] = try idOf(operands[1]) else in_arm[local] = true;
                } else if (work.thing[into] == .local_aggregate) {
                    // The whole of an aggregate, or a chain into one whose
                    // index the loop computes: none of its variables is
                    // one an induction is found in (since 1.176).
                    const first = work.points[into];
                    for (first..first + try leafCount(work, work.aggregate[into])) |local| in_arm[local] = true;
                } else if (defined[into].op == .access_chain and defined[into].a & local_bit != 0) {
                    const first = defined[into].a & ~local_bit;
                    for (first..first + @max(defined[into].b, 1)) |local| in_arm[local] = true;
                } else if (defined[into].op == .nop and work.thing[into] == .local_part) {
                    in_arm[work.points[into]] = true;
                }
            },
            .access_chain => {
                if (operands.len < 3) return Error.Body;
                const id = try idOf(operands[1]);
                const base = try idOf(operands[2]);
                // Into an aggregate of the function's own, the variables
                // it may come to: `b` of them from `a` (since 1.176).
                defined[id] = if (work.thing[base] == .local_aggregate)
                    .{ .op = .access_chain, .a = local_bit | work.points[base], .b = try leafCount(work, work.aggregate[base]), .order = place }
                else if (defined[base].op == .access_chain and defined[base].a & local_bit != 0)
                    .{ .op = .access_chain, .a = defined[base].a, .b = defined[base].b, .order = place }
                else
                    .{ .op = .access_chain, .a = if (isLocal(work, base)) local_bit | work.points[base] else 0, .order = place };
            },
            .returns, .return_value, .function_end => return Error.Branches,
            else => if (!makesNothing(instruction.op) and operands.len >= 2) {
                const id = try idOf(operands[1]);
                const a: u16 = if (operands.len > 2 and operands[2] < most_ids) @intCast(operands[2]) else 0;
                const b: u16 = if (operands.len > 3 and operands[3] < most_ids) @intCast(operands[3]) else 0;
                defined[id] = .{ .op = instruction.op, .a = a, .b = b, .order = place, .top = open == 0 };
            },
        }
    }
    const test_branch = leaving orelse return Error.Branches;
    if (back_edges != 1) return Error.Branches;

    // Each candidate for a basic induction variable: a header phi, or a
    // variable stored into at the top level, which nir_lower_vars_to_ssa
    // makes one. Its value on the way in, and the id of its way back.
    const Candidate = struct { basis: u16, init: ?u32, back: u16, induction: ?Induction = null };
    var candidates: [most_settled + most_locals]Candidate = undefined;
    var count: u32 = 0;
    for (phis[0..phi_count]) |phi| {
        const in_side: usize = if (phi.parents[0] == loop.entered_from) 0 else if (phi.parents[1] == loop.entered_from) 1 else return Error.Branches;
        if (phi.parents[1 - in_side] != back_from) return Error.Branches;
        candidates[count] = .{ .basis = phi.id, .init = constantBits(work, phi.values[in_side]), .back = resolved(defined, phi.values[1 - in_side]) };
        count += 1;
    }
    for (0..most_locals) |local| {
        if (stored[local] == 0 or in_arm[local]) continue;
        const entering = entry[local][0];
        const init: ?u32 = if (work.local_kind[local] == .f32x1 and entering.step != none) floatBits(work, entering) else null;
        candidates[count] = .{ .basis = local_bit | @as(u16, @intCast(local)), .init = init, .back = resolved(defined, stored[local]) };
        count += 1;
    }
    // compute_induction_information: the way back an Update of the phi
    // and a constant, at the top level. An isub or an fsub of a constant
    // is an iadd or an fadd of its negation by then: nir_opt_algebraic
    // lowers the two (nir_opt_algebraic.py:2401-2402) and folds the
    // negation.
    var constant_back = false;
    for (candidates[0..count]) |*candidate| {
        const back = candidate.back;
        if (back & local_bit == 0 and defined[back].op == .nop and constantBits(work, back) != null) constant_back = true;
        const init = candidate.init orelse continue;
        if (back & local_bit != 0) continue;
        const of = defined[back];
        if (!of.top) continue;
        const update: Update = switch (of.op) {
            .i_add, .i_sub => .iadd,
            .f_add, .f_sub => .fadd,
            .i_mul => .imul,
            .f_mul => .fmul,
            .shift_left_logical => .ishl,
            .shift_right_arithmetic => .ishr,
            .shift_right_logical => .ushr,
            else => continue,
        };
        const sub = of.op == .i_sub or of.op == .f_sub;
        var made: ?Induction = null;
        if (of.a != 0 and resolved(defined, of.a) == candidate.basis and of.b != 0 and defined[of.b].op == .nop) {
            if (constantBits(work, of.b)) |stride| {
                const by = if (!sub) stride else if (update == .iadd) 0 -% stride else stride ^ 0x8000_0000;
                made = .{ .init = init, .update = update, .step = by, .phi_first = true };
            }
        } else if (!sub and of.b != 0 and resolved(defined, of.b) == candidate.basis and of.a != 0 and defined[of.a].op == .nop) {
            if (constantBits(work, of.a)) |stride| made = .{ .init = init, .update = update, .step = stride, .phi_first = false };
        }
        candidate.induction = made;
    }

    // find_trip_count: the test's comparison, an inot of one unwrapped,
    // one side an induction variable or its update def, the other a
    // constant (get_induction_and_limit_vars, :1050-1077, the left side
    // first).
    var invert = test_branch.no == loop.merge;
    var at = resolved(defined, test_branch.condition);
    if (at & local_bit != 0) return Error.Branches;
    if (defined[at].op == .logical_not and defined[at].top) {
        at = resolved(defined, defined[at].a);
        if (at & local_bit != 0) return Error.Branches;
        invert = !invert;
    }
    const comparison = defined[at];
    if (!comparison.top) return Error.Branches;
    const shape = comparedOf(comparison.op) orelse return Error.Branches;
    if (shape.negate) invert = !invert;
    const sides: [2]u16 = if (shape.swap) .{ comparison.b, comparison.a } else .{ comparison.a, comparison.b };
    const Side = struct { candidate: u32, on_def: bool };
    var found: [2]?Side = .{ null, null };
    for (sides, &found) |side, *each| {
        if (side == 0) continue;
        const value = resolved(defined, side);
        for (candidates[0..count], 0..) |candidate, k| {
            if (candidate.induction == null) continue;
            if (value == candidate.basis) each.* = .{ .candidate = @intCast(k), .on_def = false };
            if (value == candidate.back) each.* = .{ .candidate = @intCast(k), .on_def = true };
        }
    }
    const limit_rhs = found[0] != null;
    const ind = found[0] orelse found[1] orelse return Error.Branches;
    const limit_id = sides[if (limit_rhs) 1 else 0];
    if (limit_id == 0) return Error.Branches;
    const limit_at = resolved(defined, limit_id);
    if (limit_at & local_bit != 0 or defined[limit_at].op != .nop) return Error.Branches;
    const limit = constantBits(work, limit_at) orelse return Error.Branches;
    const induction = candidates[ind.candidate].induction.?;
    const update_order = defined[candidates[ind.candidate].back].order;

    const straight = !selection_before;
    const last = (if (test_branch.yes == loop.merge) test_branch.no else test_branch.yes) == loop.header;
    const test_of = Test{ .cmp = shape.cmp, .limit = limit, .limit_rhs = limit_rhs, .invert = invert, .on_def = true };
    if (straight and !last and !ind.on_def and update_order > test_branch.order) {
        // A for or a while loop: its first test peeled, constant here,
        // and the loop in do-while form, the test of the update def. One
        // that is never entered is no loop once nir_opt_dead_cf has
        // taken the peeled branch.
        var first = test_of;
        first.on_def = false;
        if (first.breaks(induction, induction.init)) {
            loop.trips = 0;
            loop.continues = 0;
            return;
        }
        loop.trips = tripCount(test_of, induction) orelse return Error.Branches;
        loop.continues = loop.trips + 1;
    } else if (last and ind.on_def) {
        // A do-while loop, its test the last of it. One whose header has
        // a phi of a constant way back, or that asks to be unrolled, is
        // peeled as well where the test is its first control flow
        // (should_peel_initial_break, nir_opt_loop.c:352-410), which is
        // not done here.
        if (straight and (loop.force or constant_back)) return Error.Branches;
        loop.trips = tripCount(test_of, induction) orelse return Error.Branches;
        loop.continues = loop.trips;
    } else return Error.Branches;
    if (!loop.force and loop.trips > max_unroll_iterations) return Error.Branches;
    if (loop.continues > most_steps) return Error.Steps;
}

/// An id through the loads of variables `planLoop` read: the value a load
/// reads, or the variable's phi with `local_bit`.
fn resolved(defined: *const [most_ids]Defined, id: u16) u16 {
    var at = id;
    var hops: u32 = 0;
    while (at & local_bit == 0 and defined[at].op == .load and defined[at].a != 0 and hops < most_ids) : (hops += 1) at = defined[at].a;
    return at;
}

/// instr_cost (nir_loop_analyze.c:78-167) summed over the steps one trip
/// of the loop made: an intrinsic or a texture instruction 1, an ALU
/// operation 1 for each float, as NIR is scalar by then (nir_to_vir.c:
/// 2259), and none for a vec, a move, a constant, an operation of
/// constants alone (is_const_after_unrolling, which the walk has folded),
/// or a product only summed, which an FMA takes. Mesa counts the loop's
/// NIR before it is unrolled; these are the steps of its first trip after
/// the walk's lowering, in which an operation of the phis' constant ways
/// in may have been folded, so a loop near the limit may be unrolled here
/// that Mesa keeps a loop.
fn loopCost(work: *const Work, from: u16, to: u16) u32 {
    var cost: u32 = 0;
    for (from..to) |at| {
        const each = work.steps[at];
        switch (each.tag) {
            .constant, .component, .construct, .phi, .begin_if, .begin_else, .end_if => continue,
            .input => {
                cost += each.kind.parts();
                continue;
            },
            .push, .ubo, .ssbo, .ubo_indirect, .ssbo_indirect, .ssbo_store, .ssbo_atomic, .barrier, .scratch, .scratch_indirect, .scratch_store, .discard, .sample, .sample_compared, .output, .viewport, .system => {
                cost += 1;
                continue;
            },
            else => {},
        }
        var constants = true;
        for (readsOfStep(each)) |field| if (field) |of| {
            if (work.steps[of].tag != .constant) constants = false;
        };
        if (constants) continue;
        if (each.tag == .mul) {
            var only_added = true;
            var used = false;
            for (work.steps[at + 1 .. to]) |user| if (readsStep(user, @intCast(at))) {
                used = true;
                if (user.tag != .add) only_added = false;
            };
            if (used and only_added) continue;
        }
        cost += each.kind.parts();
    }
    return cost;
}

/// check_unrolling_restrictions' cost (nir_opt_loop_unroll.c:924-928),
/// once the loop's first trip is made.
fn checkLoopCost(work: *const Work, loop: *const Loop) Error!void {
    if (loop.force or loop.trips == 0) return;
    const cost = loopCost(work, loop.from, @intCast(work.step_count));
    if (cost * loop.trips > max_unroll_iterations * loop_unroll_limit) return Error.Branches;
}

/// A header phi's value for this trip: on the way in, the value of the
/// block the walk came from; on the way back, the other.
fn loopPhiOf(work: *Work, operands: []const u32, from: u32, back: bool) Error!Settled {
    if (operands.len < 4 or operands.len % 2 != 0 or operands.len > 6) return Error.Branches;
    const type_id = try idOf(operands[0]);
    const boolean = work.thing[type_id] == .boolean;
    const id = try idOf(operands[1]);
    var chosen: ?u32 = null;
    var at: usize = 2;
    while (at < operands.len) : (at += 2) {
        const parent = operands[at + 1];
        if ((parent == from) != back) {
            if (chosen != null) return Error.Branches;
            chosen = operands[at];
        }
    }
    const value = chosen orelse return Error.Branches;
    const step_at = if (boolean) try boolOf(work, value) else try operand(work, value, try kindOf(work, type_id));
    return .{ .id = id, .step = step_at };
}

/// Where `read` is in a selection's shape: its OpSelectionMerge, its
/// OpBranchConditional, between its arms, in one, past an OpKill, or at
/// its merge block's phis; or in no selection's.
const Flow = enum { body, branch, arms, arm, killed, merging };

/// A selection as `read` goes through it.
const Selection = struct {
    /// The merge block, the block the selection is in, and where `read`
    /// goes back to past the merge: the body, or the arm of the selection
    /// it is in.
    merge: u32 = 0,
    header: u32 = 0,
    outside: Flow = .body,
    /// The true and false labels, either of which may be the merge block,
    /// whether each arm has been read, and the block each ended in.
    yes: u32 = 0,
    no: u32 = 0,
    seen_yes: bool = false,
    seen_no: bool = false,
    ends_in: [2]u32 = .{ 0, 0 },
    /// The arm being read, and whether it is still empty.
    arm: u32 = 0,
    empty: bool = true,
    /// For nir_opt_collapse_if's shape: whether the arm holds nothing NIR
    /// keeps once nir_lower_vars_to_ssa has run, how many selections are
    /// nested in it, and whether the last of them had no false arm and
    /// the arm has held nothing kept since. Then whether the true arm was
    /// all one such selection, and whether the false arm held nothing.
    quiet: bool = true,
    inner: u32 = 0,
    lone: bool = false,
    collapses: bool = false,
    quiet_no: bool = false,
    /// Its SelectionControl, which sets the limit it is flattened under
    /// (since 1.159).
    control: u32 = 0,
    /// For nir_opt_collapse_if: the iand of its condition and the outer
    /// selection's, where the two may collapse; whether its true arm was
    /// quiet, and stored a constant, as it ended; whether a constant was
    /// stored in the arm being read; whether its arm is a discard; for an
    /// outer selection, what the one nested in its arm left, and whether
    /// that one collapsed into it.
    iand: u16 = none,
    quiet_yes: bool = false,
    constant_yes: bool = false,
    constant: bool = false,
    killed: bool = false,
    held: Held = .{},
    collapsed: bool = false,
    /// The comparison it branches on.
    condition: u16 = none,
    /// The arms' steps: from the first after the branch to the first in
    /// the merge block.
    arms_from: u16 = 0,
    arms_to: u16 = 0,
    /// Kept a branch (since 1.171): an arm holds what
    /// nir_opt_peephole_select flattens nothing of. Its arms' regions,
    /// the true arm's and the one after it; the first step of the arm
    /// read second; whether the false arm came first in the module; and
    /// whether a variable came to the merge from one way only.
    kept: bool = false,
    region: Region = 0,
    split: u16 = 0,
    false_first: bool = false,
    one_way: bool = false,

    /// An arm holds what is not flattened: the selection is kept a branch,
    /// where it is in no other (since 1.171). A vertex program's are not
    /// yet.
    fn keep(selection: *Selection, work: *const Work, depth: u32) Error!void {
        if (depth != 1 or work.stage != .fragment) return Error.Branches;
        selection.kept = true;
        selection.empty = false;
        selection.quiet = false;
        selection.lone = false;
    }

    /// An arm's first block: the step its steps start at, where it is the
    /// second arm, and the region they are in.
    /// Each arm starts from the copies where the selection branched, as
    /// copy_prop_vars_cf_node clones them for it (nir_opt_copy_prop_vars.c:
    /// 1531-1557), and is a block of its own to nir_opt_dead_write_vars
    /// (since 1.177).
    fn armed(selection: *Selection, work: *Work, arm: u32, depth: u32) void {
        if (selection.seen_yes or selection.seen_no) {
            selection.split = @intCast(work.step_count);
        } else {
            selection.false_first = arm == selection.no;
            work.copies_before[depth - 1] = work.copies;
            @memcpy(work.unused_before[depth - 1][0..work.unused_count], work.unused[0..work.unused_count]);
            work.unused_before_count[depth - 1] = work.unused_count;
        }
        work.copies = work.copies_before[depth - 1];
        work.unused_count = 0;
        if (depth == 1) work.current_region = selection.region + @intFromBool(arm != selection.yes);
    }

    fn enter(selection: *Selection, arm: u32) void {
        selection.arm = arm;
        selection.empty = true;
        selection.quiet = true;
        selection.constant = false;
        selection.inner = 0;
        selection.lone = false;
    }
};

/// Whether the tex step `at`, read in an arm, is one nir_opt_cse takes for
/// one before it that `oneValue` finds the same and that is there wherever
/// the arm is (`dominates`): in no arm of a kept selection, nor of one
/// still being read, whose arms are each a region of their own until the
/// merge (since 1.171). The steps of the arm itself are in its region
/// (since 1.185).
fn takenBefore(work: *const Work, at: u16) bool {
    for (0..at) |k| {
        const earlier: u16 = @intCast(k);
        if (work.region[earlier] != 0) continue;
        if (oneValue(work, .{ .step = earlier, .part = 0 }, .{ .step = at, .part = 0 }, most_value_depth)) return true;
    }
    return false;
}

/// What a selection nested in an arm leaves the one it is in, for
/// nir_opt_collapse_if: its iand and condition, the selects its merge
/// made, its true arm's cost, its SelectionControl, whether its true arm
/// is a block NIR keeps, and whether it is a discard; and whether a
/// constant was stored in the outer arm after it, a load_const in the
/// block after the inner selection that nir_opt_cse may or may not take.
const Held = struct {
    iand: u16 = none,
    condition: u16 = none,
    selects_from: u16 = 0,
    selects_to: u16 = 0,
    cost: u32 = 0,
    control: u32 = 0,
    emptiness: Emptiness = .kept,
    killed: bool = false,
    constant_after: bool = false,
};

/// Whether an arm's block is empty in NIR: it holds an instruction, it
/// holds none, or it stored a constant whose load_const nir_opt_cse may
/// take for one before it.
const Emptiness = enum { kept, empty, unsure };

/// SelectionControl's Flatten and DontFlatten.
const flatten: u32 = 1;
const dont_flatten: u32 = 2;

/// The limit a selection of SelectionControl `control` is flattened
/// under in a pass of `limit`: none for one that asks to be flattened, 0
/// for one that asks not to be (get_options_for_if,
/// nir_opt_peephole_select.c:329-345; since 1.159).
fn limitOf(control: u32, limit: u32) u32 {
    if (control & dont_flatten != 0) return 0;
    if (control & flatten != 0) return std.math.maxInt(u32) - 1;
    return limit;
}

/// Whether nir_opt_collapse_if takes the selection nested in `outer`'s
/// true arm into it, as v3d's optimization loop meets the two
/// (nir_to_vir.c:2264-2279): nir_opt_peephole_select with a limit of 0,
/// then of 24, each trying the collapse at the inner merge block first
/// (nir_opt_peephole_select_block, :531-533) and flattening the inner
/// selection where it cannot. The collapse wants the inner arm a block
/// NIR keeps (:425-427), the outer arm's block before the inner
/// selection under the limit (:464-471), and, unless the outer selection
/// asks to be flattened, each outer phi of an inner one to bring from the
/// other way what the inner one brings from its own (:444-462). A
/// discard is flattened only by the pass after, so it waits for the
/// collapse (since 1.159).
fn collapseOf(work: *Work, outer: *const Selection, level: u32, reader: spirv.Reader) Error!bool {
    const inner = outer.held;
    const first = armCost(work, outer.arms_from, inner.iand);
    const trivial = outer.control & flatten != 0 or try droppable(work, outer, level, reader);
    for ([2]u32{ 0, peephole_limit }) |limit| {
        if (trivial and first <= limitOf(outer.control, limit)) {
            if (inner.constant_after) return Error.Branches;
            return switch (inner.emptiness) {
                .kept => true,
                .empty => false,
                .unsure => Error.Branches,
            };
        }
        if (!inner.killed and inner.cost <= limitOf(inner.control, limit)) return false;
    }
    return false;
}

/// Whether every float the outer merge chooses of a select the inner
/// merge made comes the other way as the inner select's own false float:
/// the variables of the function's own as the arms left them, and the
/// merge block's phis, read ahead of the walk.
fn droppable(work: *Work, outer: *const Selection, level: u32, reader: spirv.Reader) Error!bool {
    for (0..work.local_count) |local| {
        for (0..work.local_kind[local].parts()) |k| {
            const yes = work.ends[level][0][local][k];
            const no = work.ends[level][1][local][k];
            if (!innerSelect(work, &outer.held, yes)) continue;
            if (no.step == none or !sameFloats(partOf(work, work.steps[yes.step].from[0], 0), no)) return false;
        }
    }
    var ahead = reader;
    while (ahead.next() catch return Error.Refused) |instruction| {
        if (instruction.op != .phi) break;
        const operands = instruction.operands();
        if (operands.len != 6) return Error.Branches;
        const type_id = try idOf(operands[0]);
        const parts: u32 = if (work.thing[type_id] == .boolean) 1 else (try kindOf(work, type_id)).parts();
        var by: [2]u16 = .{ none, none };
        for ([2]usize{ 2, 4 }) |at| {
            const parent = operands[at + 1];
            const side: usize = if (parent == outer.ends_in[0]) 0 else if (parent == outer.header) 1 else return Error.Branches;
            by[side] = work.step_of[try idOf(operands[at])];
        }
        // A constant no step has read yet is no select of the inner merge,
        // nor the float one brings.
        if (by[0] == none) continue;
        for (0..parts) |k| {
            const yes = partOf(work, by[0], @intCast(k));
            if (!innerSelect(work, &outer.held, yes)) continue;
            if (by[1] == none) return false;
            if (!sameFloats(partOf(work, work.steps[yes.step].from[0], 0), partOf(work, by[1], @intCast(k)))) return false;
        }
    }
    return true;
}

/// Whether a float is a select the merge of the selection `inner` names
/// made.
fn innerSelect(work: *const Work, inner: *const Held, of: Float) bool {
    return of.step != none and of.part == 0 and of.step >= inner.selects_from and of.step < inner.selects_to and work.steps[of.step].tag == .select;
}

/// Whether the outer merge of a collapse takes the float `yes` as it is:
/// a select of the inner merge whose false float is `no`, which
/// nir_opt_collapse_if's phi is of both ways (:474-485).
fn dropped(work: *const Work, selection: *const Selection, yes: Float, no: Float) bool {
    if (!selection.collapsed or no.step == none) return false;
    if (!innerSelect(work, &selection.held, yes)) return false;
    return sameFloats(partOf(work, work.steps[yes.step].from[0], 0), partOf(work, no.step, no.part));
}

fn sameFloats(a: Float, b: Float) bool {
    return a.step == b.step and a.part == b.part;
}

/// Whether a store into a variable of the function's own stores a
/// constant.
fn storesConstant(work: *const Work, operands: []const u32) bool {
    if (operands.len < 2) return false;
    const id = idOf(operands[1]) catch return false;
    return work.thing[id] == .constant or work.thing[id] == .constant_aggregate;
}

/// Whether an instruction in an arm is one nir_lower_vars_to_ssa leaves
/// nothing of: a variable of the function's own named, loaded or stored
/// into. Every other leaves an instruction in the arm's block.
fn quietOf(work: *const Work, instruction: spirv.Instruction) bool {
    const operands = instruction.operands();
    return switch (instruction.op) {
        .store => storesLocal(work, operands),
        .load, .access_chain => operands.len >= 3 and pointsLocal(work, operands[2]),
        else => false,
    };
}

/// Whether an OpStore's pointer is into a storage buffer.
fn storesBuffer(work: *const Work, operands: []const u32) bool {
    if (operands.len < 1) return false;
    const id = idOf(operands[0]) catch return false;
    return work.thing[id] == .member_pointer;
}

/// Whether an OpStore's pointer is into scratch (since 1.177).
fn storesScratch(work: *const Work, operands: []const u32) bool {
    if (operands.len < 1) return false;
    const id = idOf(operands[0]) catch return false;
    return work.thing[id] == .scratch_pointer;
}

fn pointsLocal(work: *const Work, word: u32) bool {
    const id = idOf(word) catch return false;
    return isLocal(work, id) or work.thing[id] == .local_part or work.thing[id] == .local_aggregate or work.thing[id] == .local_tree;
}

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
    // A phi of bools, as glslc writes && and ||: one bcsel of the two
    // (since 1.157).
    const type_id = try idOf(operands[0]);
    const boolean = work.thing[type_id] == .boolean;
    const kind: Kind = if (boolean) .f32x1 else try kindOf(work, type_id);
    const id = try idOf(operands[1]);
    // Which way each value came: an arm's block, or the selection's own
    // where the other label is the merge block.
    var by: [2]u16 = .{ none, none };
    for ([2]usize{ 2, 4 }) |at| {
        const parent = operands[at + 1];
        const side: usize = if (parent == selection.ends_in[0] and selection.yes != selection.merge)
            0
        else if (parent == selection.ends_in[1] and selection.no != selection.merge)
            1
        else if (parent == selection.header and selection.yes == selection.merge)
            0
        else if (parent == selection.header and selection.no == selection.merge)
            1
        else
            return Error.Branches;
        if (by[side] != none) return Error.Branches;
        by[side] = if (boolean) try boolOf(work, operands[at]) else try operand(work, operands[at], kind);
    }
    if (boolean) {
        // A kept selection's phi of bools is not yet (since 1.171).
        if (selection.kept) return Error.Branches;
        var chosen = Step{ .tag = .select, .kind = .f32x1, .a = selection.condition, .b = by[0] };
        chosen.from[0] = by[1];
        const kept = by[0] == by[1] or dropped(work, selection, .{ .step = by[0], .part = 0 }, .{ .step = by[1], .part = 0 });
        work.step_of[id] = if (kept) by[0] else try put(work, chosen);
        return;
    }
    var made = Step{ .tag = .construct, .kind = kind };
    for (0..kind.parts()) |k| {
        const yes = partOf(work, by[0], @intCast(k));
        const no = partOf(work, by[1], @intCast(k));
        if ((yes.step == no.step and yes.part == no.part) or dropped(work, selection, yes, no)) {
            made.from[k] = yes.step;
            made.part[k] = yes.part;
            continue;
        }
        if (selection.kept) {
            made.from[k] = try put(work, phiStep(selection.condition, yes, no));
            made.part[k] = 0;
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
pub const Float = struct { step: u16, part: u8 };

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

/// The floats of the function's variables, for each the float it holds.
const Values = [most_locals][4]Float;

/// A float of a variable nothing was stored into.
const unstored: Float = .{ .step = none, .part = 0 };

fn isLocal(work: *const Work, id: u16) bool {
    return work.thing[id] == .variable and work.class[id] == @intFromEnum(spirv.StorageClass.function);
}

/// Whether an OpStore's pointer is a variable of the function's own, or
/// one float of one.
fn storesLocal(work: *const Work, operands: []const u32) bool {
    return operands.len >= 1 and pointsLocal(work, operands[0]);
}

/// A variable stored into or loaded from, the first time: it is next in
/// the order nir_lower_vars_to_ssa takes them in.
fn touch(work: *Work, local: u16) void {
    const bit = @as(u32, 1) << @intCast(local);
    if (work.used & bit != 0) return;
    work.used |= bit;
    work.first_used[work.used_count] = @intCast(local);
    work.used_count += 1;
}

/// The float a variable holds, where one was stored, else 0: an undef
/// read is nir_lower_undef_to_zero's 0 (nir_to_vir.c:2353).
fn heldOf(work: *Work, of: Float) Error!Float {
    if (of.step != none) return of;
    return .{ .step = try immediateOf(work, 0, .f32x1), .part = 0 };
}

/// A variable of the function's own as the value a load of it answers:
/// the step it was stored from where it holds that step's floats in
/// order, else a vector of the floats it holds, which copy propagation
/// sees through as it sees through nir_lower_vars_to_ssa's moves.
fn localOf(work: *Work, local: u16) Error!u16 {
    const kind = work.local_kind[local];
    var holds: [4]Float = undefined;
    for (0..kind.parts()) |k| holds[k] = try heldOf(work, work.values[local][k]);
    return valueOf(work, kind, holds);
}

/// The value of `kind` whose floats are `holds`, as `localOf` makes it.
fn valueOf(work: *Work, kind: Kind, holds: [4]Float) Error!u16 {
    if (kind == .f32x1) return floatOf(work, holds[0]);
    const whole = for (0..kind.parts()) |k| {
        if (holds[k].step != holds[0].step or holds[k].part != k) break false;
    } else work.steps[holds[0].step].kind == kind;
    if (whole) return holds[0].step;
    var made = Step{ .tag = .construct, .kind = kind };
    for (0..kind.parts()) |k| {
        made.from[k] = holds[k].step;
        made.part[k] = holds[k].part;
    }
    return put(work, made);
}

/// A float, an integer, a vector of them or a bool of an aggregate of
/// the function's own: what kind of variable nir_split_struct_vars or
/// nir_split_array_vars makes of it (since 1.176).
const Leaf = struct { kind: Kind, is_bool: bool = false };

/// The floats, vectors and bools of `type_id`, in order, into `out`, and
/// how many: the variables nir_split_struct_vars and nir_split_array_vars
/// make a variable of the function's own of an aggregate type, each of
/// them a variable of its own, a matrix's columns among them as an
/// array's elements (glsl_type_is_array_or_matrix, nir_split_vars.c:999).
/// A struct or an array of more of them than `most_locals` is refused
/// (since 1.176).
fn leafKinds(work: *const Work, type_id: u16, out: []Leaf) Error!usize {
    switch (work.thing[type_id]) {
        .float, .int, .vector, .boolean => {
            if (out.len == 0) return Error.Storage;
            out[0] = if (work.thing[type_id] == .boolean) .{ .kind = .f32x1, .is_bool = true } else .{ .kind = try kindOf(work, type_id) };
            return 1;
        },
        .matrix => {
            const count = work.wide[type_id];
            if (out.len < count) return Error.Storage;
            @memset(out[0..count], .{ .kind = try kindOf(work, work.points[type_id]) });
            return count;
        },
        .array => {
            if (isRuntime(work, type_id)) return Error.Storage;
            const each = try leafKinds(work, work.points[type_id], out);
            const length = work.length[type_id];
            if (each * length > out.len) return Error.Storage;
            for (1..length) |e| @memcpy(out[e * each ..][0..each], out[0..each]);
            return each * length;
        },
        .plain_struct => {
            var at: usize = 0;
            for (structMembers(work, type_id)) |member| at += try leafKinds(work, member, out[at..]);
            return at;
        },
        else => return Error.Storage,
    }
}

/// How many floats, vectors and bools `type_id` is of (`leafKinds`).
fn leafCount(work: *const Work, type_id: u16) Error!u16 {
    var kinds: [most_locals]Leaf = undefined;
    return @intCast(try leafKinds(work, type_id, &kinds));
}

/// The members of a struct that is no block, by their types.
fn structMembers(work: *const Work, type_id: u16) []const u16 {
    return work.struct_members[work.points[type_id]..][0..work.wide[type_id]];
}

/// The type of element or member `k` of an array or a struct.
fn memberType(work: *const Work, type_id: u16, k: usize) u16 {
    if (work.thing[type_id] == .array) return work.points[type_id];
    return work.struct_members[work.points[type_id] + k];
}

/// How many elements or members an array or a struct has.
fn memberCount(work: *const Work, type_id: u16) u16 {
    if (work.thing[type_id] == .array) return work.length[type_id];
    return work.wide[type_id];
}

/// Element, member or column `index` of an aggregate type: the first of
/// its floats and vectors among the aggregate's, and its type, as
/// nir_split_struct_vars and nir_split_array_vars number the variables
/// they make (since 1.176).
const Within = struct { leaf: u16, type_id: u16 };

fn within(work: *const Work, type_id: u16, index: u32) Error!Within {
    switch (work.thing[type_id]) {
        .array => {
            if (index >= work.length[type_id]) return Error.Body;
            const element = work.points[type_id];
            return .{ .leaf = @intCast(index * try leafCount(work, element)), .type_id = element };
        },
        .plain_struct => {
            const members = structMembers(work, type_id);
            if (index >= members.len) return Error.Body;
            var leaf: u16 = 0;
            for (members[0..index]) |member| leaf += try leafCount(work, member);
            return .{ .leaf = leaf, .type_id = members[index] };
        },
        .matrix => {
            if (index >= work.wide[type_id]) return Error.Body;
            return .{ .leaf = @intCast(index), .type_id = work.points[type_id] };
        },
        else => return Error.Body,
    }
}

/// An index of an element or a column of a variable of the function's
/// own: an integer constant, or a value the walk folded to one, which an
/// unrolled loop's counter is (since 1.176). One the body computes is
/// refused; `localIndexOrNull` says it is one.
fn localIndexOf(work: *const Work, word: u32) Error!u32 {
    return try localIndexOrNull(work, word) orelse Error.Storage;
}

/// `localIndexOf`'s constant, or null where the body computes the index
/// (since 1.177).
fn localIndexOrNull(work: *const Work, word: u32) Error!?u32 {
    const id = try idOf(word);
    if (work.thing[id] == .int_constant) return @as(u32, @bitCast(work.pool[work.points[id]]));
    const of = work.step_of[id];
    if (of == none or work.steps[of].tag != .constant or work.steps[of].kind != .f32x1) return null;
    return @as(u32, @bitCast(work.pool[work.steps[of].at]));
}

/// `leaf` put down after the aggregates' others.
fn putLeaf(work: *Work, leaf: u16) Error!void {
    if (work.leaf_count == most_leaves) return Error.Steps;
    work.leaves[work.leaf_count] = leaf;
    work.leaf_count += 1;
}

/// The constants of the floats and vectors of the constant `id`, of type
/// `type_id`, put down after the others: a float's or a vector's own, a
/// matrix's columns', or an array's or a struct's (since 1.176).
fn constantLeaves(work: *Work, id: u16, type_id: u16) Error!void {
    switch (work.thing[type_id]) {
        .float, .int, .vector => {
            if (!isConstant(work, id) or work.wide[id] != (try kindOf(work, type_id)).parts()) return Error.Type;
            try putLeaf(work, id);
        },
        .matrix => {
            if (work.thing[id] != .constant_matrix or work.wide[id] != work.wide[type_id]) return Error.Type;
            const whole = work.matrices[work.points[id]];
            for (whole.columns[0..whole.count]) |column| try putLeaf(work, column);
        },
        .array, .plain_struct => {
            if (work.thing[id] != .constant_aggregate or work.aggregate[id] != type_id) return Error.Type;
            const first = work.points[id];
            for (0..try leafCount(work, type_id)) |k| try putLeaf(work, work.leaves[first + k]);
        },
        else => return Error.Type,
    }
}

/// The steps of the floats and vectors of the value `word`, of type
/// `type_id`, into `out`, and how many: a float's or a vector's, a
/// matrix's columns, or an array's or a struct's in order, a constant's
/// each made a step as `operand` makes one (since 1.176).
fn leafSteps(work: *Work, word: u32, type_id: u16, out: []u16) Error!usize {
    switch (work.thing[type_id]) {
        .float, .int, .vector => {
            if (out.len == 0) return Error.Storage;
            out[0] = try operand(work, word, try kindOf(work, type_id));
            return 1;
        },
        .matrix => {
            const whole = work.matrices[try matrixOf(work, word)];
            if (whole.count != work.wide[type_id] or out.len < whole.count) return Error.Type;
            const rows = try kindOf(work, work.points[type_id]);
            for (whole.columns[0..whole.count], 0..) |column, c| {
                if (work.steps[column].kind != rows) return Error.Type;
                out[c] = column;
            }
            return whole.count;
        },
        .array, .plain_struct => {
            const id = try idOf(word);
            if (work.aggregate[id] != type_id) return Error.Type;
            var kinds: [most_leaves]Leaf = undefined;
            const count = try leafKinds(work, type_id, &kinds);
            if (out.len < count) return Error.Storage;
            const first = work.points[id];
            switch (work.thing[id]) {
                .aggregate_value => @memcpy(out[0..count], work.leaves[first..][0..count]),
                .constant_aggregate => for (0..count) |k| {
                    out[k] = try operand(work, work.leaves[first + k], kinds[k].kind);
                },
                else => return Error.Type,
            }
            return count;
        },
        else => return Error.Type,
    }
}

/// `id` the value of type `type_id` whose floats and vectors are the
/// steps `made`: an aggregate's, or a matrix's columns (since 1.176).
fn holdAggregate(work: *Work, id: u16, type_id: u16, made: []const u16) Error!void {
    if (work.thing[type_id] == .matrix) {
        var whole = Matrix{ .count = @intCast(made.len) };
        @memcpy(whole.columns[0..made.len], made);
        return holdMatrix(work, id, whole);
    }
    if (work.leaf_count + made.len > most_leaves) return Error.Steps;
    const first = work.leaf_count;
    @memcpy(work.leaves[first..][0..made.len], made);
    work.leaf_count += @intCast(made.len);
    work.thing[id] = .aggregate_value;
    work.points[id] = @intCast(first);
    work.aggregate[id] = type_id;
}

/// The value `word` stored into the whole of the aggregate of the
/// function's own `into`: each of its floats and vectors into the
/// variable nir_split_struct_vars or nir_split_array_vars made of it, in
/// order, as _vtn_variable_load_store stores an aggregate element by
/// element (vtn_variables.c:763-781; since 1.176).
fn storeAggregate(work: *Work, into: u16, word: u32) Error!void {
    var made: [most_locals]u16 = undefined;
    const count = try leafSteps(work, word, work.aggregate[into], &made);
    for (made[0..count], 0..) |value, k| {
        const local: u16 = @intCast(work.points[into] + k);
        for (0..work.local_kind[local].parts()) |part| work.values[local][part] = partOf(work, value, @intCast(part));
        touch(work, local);
    }
}

/// An access chain into an aggregate of the function's own, of the
/// variable `root`, come to indexes the body computes that count more
/// elements and columns than nir_lower_indirect_derefs_to_if_else_trees
/// makes an if-else tree of (v3dv_pipeline.c:435-436,
/// nir_lower_indirect_derefs_to_if_else_trees.c:138-153; `local_tree`,
/// since 1.178): the variable goes into scratch memory
/// (nir_lower_vars_to_scratch, vir.c:2041-2044), and the walk stops to be
/// begun again with it there (`Scratch`, `readStage`; since 1.177).
fn wantScratch(work: *Work, root: u16) Error!void {
    if (work.scratch.count == most_scratch_variables) return Error.Storage;
    const bytes = 4 * try scratchFloats(work, work.aggregate[root]);
    if (work.scratch.size() + bytes > most_scratch) return Error.Storage;
    work.scratch.ids[work.scratch.count] = root;
    work.scratch.bytes[work.scratch.count] = @intCast(bytes);
    work.scratch.dead[work.scratch.count] = false;
    work.scratch.count += 1;
    return Error.Storage;
}

/// How many elements and columns the indexes the body computes count
/// together, down the chain `indexes` from the type `from`:
/// nir_lower_indirect_derefs_to_if_else_trees's indirect_array_len, each
/// such index's array's or matrix's glsl_get_length
/// (nir_lower_indirect_derefs_to_if_else_trees.c:138-146; since 1.178).
/// A vector's float the chain itself takes, at a constant index.
fn computedElements(work: *const Work, from: u16, indexes: []const u32) Error!u32 {
    var at = from;
    var elements: u32 = 1;
    for (indexes) |each| {
        switch (work.thing[at]) {
            .array, .matrix => {
                if (try localIndexOrNull(work, each) == null) elements *|= elementsOf(work, at);
                at = work.points[at];
            },
            .plain_struct => {
                const which = try indexOf(work, each);
                const members = structMembers(work, at);
                if (which >= members.len) return Error.Body;
                at = members[which];
            },
            .vector => break,
            else => return Error.Body,
        }
    }
    return elements;
}

/// An array's elements, or a matrix's columns.
fn elementsOf(work: *const Work, type_id: u16) u32 {
    return if (work.thing[type_id] == .array) work.length[type_id] else work.wide[type_id];
}

/// A load or a store of a variable in scratch through indexes the body
/// computes that count two or fewer elements, columns and floats
/// together: nir_lower_indirect_derefs_to_if_else_trees makes an if-else
/// tree of it before nir_lower_vars_to_scratch moves the variable
/// (v3dv_pipeline.c:432-436, vir.c:2041-2044), whose arms are then a
/// load_scratch or a store_scratch at a constant offset each, a branch
/// Mesa keeps. That is not here: refused (since 1.178).
fn checkScratchTree(work: *const Work, pointer: u16) Error!void {
    if (work.pointer_paths[work.chain_path[pointer]].computed != 0 and work.chain_elements[pointer] <= 2) return Error.Storage;
}

/// `id` a pointer through an if-else tree (`local_tree`), its chain on
/// from `base` come to the type `at`, `points` and `chain_part` set:
/// `index` is the step of the index into two the tree's if tests, and
/// `apart` how many variables the element it names in the else arm is
/// past the one in the then arm (since 1.178).
fn holdTree(work: *Work, id: u16, base: u16, at: u16, index: u16, apart: u16) void {
    work.thing[id] = .local_tree;
    work.class[id] = @intCast(@intFromEnum(spirv.StorageClass.function));
    work.aggregate[id] = at;
    work.chain_base[id] = work.chain_base[base];
    work.tree_index[id] = index;
    work.tree_apart[id] = apart;
}

/// The variable `root` is one an if-else tree reaches: where the walk did
/// not know it, it is begun again knowing it (`Scratch.trees`; since
/// 1.178).
fn lateTree(work: *Work, root: u16) Error!void {
    if (work.scratch.isTree(root)) return;
    if (work.scratch.tree_count == most_scratch_variables) return Error.Storage;
    work.scratch.trees[work.scratch.tree_count] = root;
    work.scratch.tree_count += 1;
    return Error.Storage;
}

/// The ilt an if-else tree's if tests, of the index and the middle of
/// the two elements, 1 (nir_ilt_imm,
/// nir_lower_indirect_derefs_to_if_else_trees.c:47-54): one of each tree,
/// which nir_opt_cse makes one (since 1.178).
fn treeCondition(work: *Work, pointer: u16) Error!u16 {
    const middle = try integerSplat(work, .f32x1, 1);
    return put(work, .{ .tag = .compare, .kind = .f32x1, .a = work.tree_index[pointer], .b = middle, .at = @intFromEnum(Comparison.int_less) });
}

/// The float a phi of `yes` and `no` on `condition` comes to where its
/// if's arms are left empty, as nir_lower_vars_to_ssa leaves an if-else
/// tree's: one both bring, or one where the other brings an undef,
/// nir_opt_remove_phis takes (nir_opt_remove_phis.c:105-175), else
/// nir_opt_peephole_select makes it a bcsel, the then arm's first, as at a
/// selection's merge (`merge`; since 1.178).
fn chosenOf(work: *Work, condition: u16, yes: Float, no: Float) Error!Float {
    if (sameFloats(yes, no) or no.step == none) return yes;
    if (yes.step == none) return no;
    var made = Step{ .tag = .select, .kind = .f32x1, .a = condition, .b = try floatOf(work, yes) };
    made.from[0] = try floatOf(work, no);
    return .{ .step = try put(work, made), .part = 0 };
}

/// A load through an if-else tree (`local_tree`): of each of the floats,
/// vectors and matrix columns it names, vtn's load of one at a time
/// (_vtn_local_load_store, vtn_variables.c:763-781), the tree
/// nir_lower_indirect_derefs_to_if_else_trees makes, its ilt, a load of
/// the element of each arm and the phi of the two (:35-108). Of one float
/// of a vector, the vector's, of which the float is the
/// nir_vector_extract (vtn_local_load, vtn_variables.c:616-641).
/// nir_lower_vars_to_ssa gives each load what the element holds, and the
/// phi is chosen a float at a time (`chosenOf`). One of bools is refused,
/// as an aggregate's is (since 1.178).
fn loadTree(work: *Work, id: u16, from: u16, type_id: u16) Error!void {
    try lateTree(work, work.chain_base[from]);
    const at = work.aggregate[from];
    const first = work.points[from];
    const apart = work.tree_apart[from];
    if (work.chain_part[from] != Work.whole) {
        if (try kindOf(work, type_id) != .f32x1) return Error.Type;
        const other = first + apart;
        const condition = try treeCondition(work, from);
        touch(work, first);
        touch(work, other);
        const k = work.chain_part[from];
        work.step_of[id] = try floatOf(work, try heldOf(work, try chosenOf(work, condition, work.values[first][k], work.values[other][k])));
        return;
    }
    if (type_id != at) return Error.Type;
    if (work.thing[at] == .boolean) return Error.Storage;
    var made: [most_locals]u16 = undefined;
    const count = try leafCount(work, at);
    for (made[0..count], 0..) |*each, l| {
        const then: u16 = @intCast(first + l);
        const other = then + apart;
        if (work.local_bool[then]) return Error.Storage;
        const condition = try treeCondition(work, from);
        touch(work, then);
        touch(work, other);
        const kind = work.local_kind[then];
        var holds: [4]Float = undefined;
        for (0..kind.parts()) |k| holds[k] = try heldOf(work, try chosenOf(work, condition, work.values[then][k], work.values[other][k]));
        each.* = try valueOf(work, kind, holds);
    }
    switch (work.thing[at]) {
        .float, .int, .vector => work.step_of[id] = made[0],
        else => try holdAggregate(work, id, at, made[0..count]),
    }
}

/// A store through an if-else tree (`local_tree`): of each of the
/// floats, vectors and matrix columns it names, vtn's store of one at a
/// time (vtn_variables.c:763-781), the tree of a store into the element
/// of each arm (nir_lower_indirect_derefs_to_if_else_trees.c:35-110). Of
/// one float of a vector, vtn loads the vector, inserts the float and
/// stores the vector (vtn_local_store, vtn_variables.c:644-667), a tree
/// each. At each store's tree's merge nir_lower_vars_to_ssa gives the
/// two elements their phis (`storeChosen`). One of bools is refused (since
/// 1.178).
fn storeTree(work: *Work, into: u16, word: u32) Error!void {
    try lateTree(work, work.chain_base[into]);
    const at = work.aggregate[into];
    const first = work.points[into];
    const apart = work.tree_apart[into];
    if (work.thing[at] == .boolean) return Error.Storage;
    if (work.chain_part[into] != Work.whole) {
        if (work.local_bool[first]) return Error.Storage;
        const stored = try operand(work, word, .f32x1);
        const other = first + apart;
        const loaded = try treeCondition(work, into);
        touch(work, first);
        touch(work, other);
        var floats: [4]Float = undefined;
        for (0..work.local_kind[first].parts()) |k| {
            floats[k] = if (k == work.chain_part[into]) partOf(work, stored, 0) else try chosenOf(work, loaded, work.values[first][k], work.values[other][k]);
        }
        return storeChosen(work, try treeCondition(work, into), first, apart, floats);
    }
    var made: [most_locals]u16 = undefined;
    const count = try leafSteps(work, word, at, &made);
    for (made[0..count], 0..) |value, l| {
        const then: u16 = @intCast(first + l);
        if (work.local_bool[then]) return Error.Storage;
        var floats: [4]Float = undefined;
        for (0..work.local_kind[then].parts()) |k| floats[k] = partOf(work, value, @intCast(k));
        try storeChosen(work, try treeCondition(work, into), then, apart, floats);
    }
}

/// The merge of an if-else tree of a store of `floats` into the element
/// `then` in its then arm and the one `apart` past it in its else arm:
/// nir_lower_vars_to_ssa gives each a phi of what was stored and what it
/// held, the then arm's first, each chosen a float at a time
/// (`chosenOf`), and the phi builder puts the two down in the reverse of
/// the order the elements were first used in (`merge`; since 1.178).
fn storeChosen(work: *Work, condition: u16, then: u16, apart: u16, floats: [4]Float) Error!void {
    const other = then + apart;
    touch(work, then);
    touch(work, other);
    const phis: [2]u16 = if (usedAt(work, then) < usedAt(work, other)) .{ other, then } else .{ then, other };
    for (phis) |local| {
        for (0..work.local_kind[local].parts()) |k| {
            const was = work.values[local][k];
            work.values[local][k] = if (local == then) try chosenOf(work, condition, floats[k], was) else try chosenOf(work, condition, was, floats[k]);
        }
    }
}

/// Where a variable `touch` was given is in the order they were first
/// used in.
fn usedAt(work: *const Work, local: u16) usize {
    return std.mem.indexOfScalar(u8, work.first_used[0..work.used_count], @intCast(local)).?;
}

/// Whether an instruction loads or stores through an if-else tree
/// (`local_tree`; since 1.178).
fn accessesTree(work: *const Work, instruction: spirv.Instruction) bool {
    const operands = instruction.operands();
    const at: usize = switch (instruction.op) {
        .load => 2,
        .store => 0,
        else => return false,
    };
    if (operands.len <= at) return false;
    const id = idOf(operands[at]) catch return false;
    return work.thing[id] == .local_tree;
}

/// The floats of `type_id` in scratch, a quarter of the bytes
/// glsl_get_natural_size_align_bytes gives it, the layout v3d moves
/// variables to scratch in (vir.c:2041-2044; glsl_types.c:3809-3880):
/// each float and integer four bytes aligned to four, a vector's and a
/// matrix's one after another, and so an array's elements and a struct's
/// members with nothing between them. A bool would be a 32-bit one there
/// (nir_b2b32, nir_lower_scratch.c:57-58), which no step here makes of a
/// condition: refused, as is a runtime array (since 1.177).
fn scratchFloats(work: *const Work, type_id: u16) Error!u32 {
    return switch (work.thing[type_id]) {
        .float, .int => 1,
        .vector => if (work.thing[work.points[type_id]] == .boolean) Error.Storage else work.wide[type_id],
        .matrix => work.wide[type_id] * try scratchFloats(work, work.points[type_id]),
        .array => if (isRuntime(work, type_id)) Error.Storage else work.length[type_id] * try scratchFloats(work, work.points[type_id]),
        .plain_struct => sum: {
            var floats: u32 = 0;
            for (structMembers(work, type_id)) |member| floats += try scratchFloats(work, member);
            break :sum floats;
        },
        else => Error.Storage,
    };
}

/// Where a float `bytes` past what the scratch pointer `pointer` names is,
/// as v3d's TMU is given it: the variable's place, the chain's offset and
/// the float's (nir_iadd_imm, nir_lower_scratch.c:39-41, and the
/// component's chunk, nir_lower_mem_access_bit_sizes, since v3d keeps
/// one float to each load_scratch, v3d_size_align_cb,
/// v3d_nir_lower_load_store_bitsize.c:135-143), times V3D_CHANNELS, each
/// lane's word of a float one after another from spill_base
/// (v3d_nir_scratch_offset, v3d_nir_lower_scratch.c:31-43), as
/// nir_imul_imm builds it, a shift by four. A constant where every index
/// was one, else the step (since 1.177).
fn scratchAt(work: *Work, pointer: u16, bytes: u32) Error!struct { dynamic: u16, offset: u32 } {
    const offset = @as(u32, work.chain_offset[pointer]) + bytes;
    const dynamic = work.chain_dynamic[pointer];
    if (dynamic == none) return .{ .dynamic = none, .offset = offset * 16 };
    const sum = if (offset == 0) dynamic else try integerOf(work, .iadd, dynamic, try integerSplat(work, .f32x1, @intCast(offset)));
    return .{ .dynamic = try strideTimes(work, sum, 16), .offset = 0 };
}

/// What the scratch pointer `from` names, loaded into `id`: each float
/// one of its own (`loadScratchFloat`), a vector's put together again,
/// and an aggregate's floats and vectors in order, as
/// _vtn_variable_load_store loads one element by element
/// (vtn_variables.c:763-781; since 1.177).
fn loadScratch(work: *Work, id: u16, from: u16) Error!void {
    try checkScratchTree(work, from);
    const type_id = work.points[from];
    var kinds: [most_leaves]Leaf = undefined;
    const count = try leafKinds(work, type_id, &kinds);
    var made: [most_leaves]u16 = undefined;
    var floats: u32 = 0;
    for (kinds[0..count], 0..) |leaf, k| {
        if (leaf.is_bool) return Error.Storage;
        var vector = Step{ .tag = .construct, .kind = leaf.kind };
        for (0..leaf.kind.parts()) |part| {
            vector.from[part] = try loadScratchFloat(work, from, floats);
            vector.part[part] = 0;
            floats += 1;
        }
        made[k] = if (leaf.kind == .f32x1) vector.from[0] else try put(work, vector);
    }
    switch (work.thing[type_id]) {
        .float, .int, .vector => work.step_of[id] = made[0],
        else => try holdAggregate(work, id, type_id, made[0..count]),
    }
}

/// The value `word` stored where the scratch pointer `into` names, each
/// float on its own (`storeScratchFloat`), an aggregate's floats and
/// vectors in order (vtn_variables.c:763-781; since 1.177).
fn storeScratch(work: *Work, into: u16, word: u32) Error!void {
    try checkScratchTree(work, into);
    var made: [most_leaves]u16 = undefined;
    const count = try leafSteps(work, word, work.points[into], &made);
    var floats: u32 = 0;
    for (made[0..count]) |value| {
        for (0..work.steps[value].kind.parts()) |part| {
            try storeScratchFloat(work, into, floats, try floatOf(work, partOf(work, value, @intCast(part))));
            floats += 1;
        }
    }
}

/// The `float`th float of what the scratch pointer `from` names: the
/// value nir_opt_copy_prop_vars has for its deref, where it has one
/// (nir_opt_copy_prop_vars.c:1124-1229), and else a load_scratch of it
/// (`scratchAt`), which is then the copy's value (:1206-1228) and reads
/// what an unused write of its block that may be of it stored
/// (clear_unused_for_read, nir_opt_dead_write_vars.c; since 1.177).
fn loadScratchFloat(work: *Work, from: u16, float: u32) Error!u16 {
    const path = try floatPath(work, from, float);
    if (copyOf(work, &path)) |k| return work.copies.values[k];
    const at = try scratchAt(work, from, 4 * float);
    const made = if (at.dynamic == none)
        try put(work, .{ .tag = .scratch, .kind = .f32x1, .at = at.offset })
    else
        try put(work, .{ .tag = .scratch_indirect, .kind = .f32x1, .a = at.dynamic });
    work.step_path[made] = path;
    try addCopy(work, made, made);
    var k: usize = 0;
    while (k < work.unused_count) {
        if (comparePaths(work, &path, &work.step_path[work.unused[k]]) != .disjoint) {
            work.unused_count -= 1;
            work.unused[k] = work.unused[work.unused_count];
        } else k += 1;
    }
    return made;
}

/// `value` stored as the `float`th float of what the scratch pointer
/// `into` names. Where nir_opt_copy_prop_vars's copy of its deref is the
/// value, the store is none (nir_opt_copy_prop_vars.c:1268-1276). Else it
/// is a store_scratch (`scratchAt`): the copies that may be of the float
/// and are not of it go, and its own is the value
/// (get_entry_and_kill_aliases, :1311-1317); and an unused write of its
/// block of the same float is written over, and dropped
/// (update_unused_writes, nir_opt_dead_write_vars.c; since 1.177).
fn storeScratchFloat(work: *Work, into: u16, float: u32, value: u16) Error!void {
    const path = try floatPath(work, into, float);
    if (copyOf(work, &path)) |k| if (sameFloat(work, work.copies.values[k], value)) return;
    const at = try scratchAt(work, into, 4 * float);
    const made = try put(work, .{ .tag = .scratch_store, .kind = .f32x1, .a = value, .at = at.offset, .from = .{ at.dynamic, 0, 0, 0 } });
    work.step_path[made] = path;
    var k: usize = 0;
    while (k < work.unused_count) {
        const earlier = work.unused[k];
        if (comparePaths(work, &path, &work.step_path[earlier]) == .equal) {
            work.unwritten[earlier] = true;
            work.unused_count -= 1;
            work.unused[k] = work.unused[work.unused_count];
        } else k += 1;
    }
    work.unused[work.unused_count] = made;
    work.unused_count += 1;
    k = 0;
    while (k < work.copies.count) {
        if (comparePaths(work, &path, &work.step_path[work.copies.paths[k]]) == .may_alias) work.copies.remove(k) else k += 1;
    }
    if (copyOf(work, &path)) |equal| work.copies.values[equal] = value else try addCopy(work, made, value);
}

/// The copy of the deref `path`, where there is one.
fn copyOf(work: *const Work, path: *const Path) ?usize {
    for (work.copies.paths[0..work.copies.count], 0..) |of, k| {
        if (comparePaths(work, path, &work.step_path[of]) == .equal) return k;
    }
    return null;
}

fn addCopy(work: *Work, path: u16, value: u16) Error!void {
    if (work.copies.count == most_steps) return Error.Steps;
    work.copies.paths[work.copies.count] = path;
    work.copies.values[work.copies.count] = value;
    work.copies.count += 1;
}

/// A selection's merge: the copies where it branched, less those that may
/// be of a float an arm stored (invalidate_copies_for_cf_node,
/// nir_opt_copy_prop_vars.c:966-1001; since 1.177).
fn mergeCopies(work: *Work, selection: *const Selection, depth: u32) void {
    if (!selection.seen_yes and !selection.seen_no) return;
    work.copies = work.copies_before[depth - 1];
    for (work.steps[selection.arms_from..work.step_count], selection.arms_from..) |each, at| {
        if (each.tag != .scratch_store) continue;
        var k: usize = 0;
        while (k < work.copies.count) {
            if (comparePaths(work, &work.step_path[at], &work.step_path[work.copies.paths[k]]) != .disjoint) work.copies.remove(k) else k += 1;
        }
    }
}

/// A scratch pointer's deref, kept for those made from it.
fn pointerPath(work: *Work, path: Path) Error!u8 {
    if (work.pointer_path_count == most_pointer_paths) return Error.Storage;
    work.pointer_paths[work.pointer_path_count] = path;
    work.pointer_path_count += 1;
    return @intCast(work.pointer_path_count - 1);
}

/// The deref of the `float`th float of what the scratch pointer `pointer`
/// names: the pointer's, then the element, column, member or float of
/// each level below it the float is in, in the natural layout's order
/// (`scratchFloats`; since 1.177).
fn floatPath(work: *const Work, pointer: u16, float: u32) Error!Path {
    var path = work.pointer_paths[work.chain_path[pointer]];
    var at = work.points[pointer];
    var left = float;
    while (true) switch (work.thing[at]) {
        .float, .int => return path,
        .vector => {
            try path.push(@intCast(left), false);
            return path;
        },
        .array, .matrix => {
            const next = work.points[at];
            const floats = try scratchFloats(work, next);
            try path.push(@intCast(left / floats), false);
            left %= floats;
            at = next;
        },
        .plain_struct => for (structMembers(work, at), 0..) |member, m| {
            const floats = try scratchFloats(work, member);
            if (left < floats) {
                try path.push(@intCast(m), false);
                at = member;
                break;
            }
            left -= floats;
        } else return Error.Storage,
        else => return Error.Storage,
    };
}

const Aliasing = enum { disjoint, may_alias, equal };

/// nir_compare_deref_paths of the derefs of two floats in scratch
/// (nir_deref.c:513-640, :643-720): of two variables, they do not alias;
/// a level of two constants that differ, two elements, members or floats
/// apart, neither; and they are the same deref where every level is, an
/// index the body computes where it is the one SSA value (`oneValue`;
/// since 1.177).
fn comparePaths(work: *const Work, a: *const Path, b: *const Path) Aliasing {
    if (a.variable != b.variable) return .disjoint;
    var equal = a.count == b.count;
    for (0..@min(a.count, b.count)) |k| {
        const left = a.isComputed(k);
        const right = b.isComputed(k);
        if (!left and !right) {
            if (a.levels[k] != b.levels[k]) return .disjoint;
        } else if (!left or !right or !oneValue(work, partOf(work, a.levels[k], 0), partOf(work, b.levels[k], 0), most_value_depth)) {
            equal = false;
        }
    }
    return if (equal) .equal else .may_alias;
}

/// How deep `oneValue` looks into the operands of two steps.
const most_value_depth = 8;

/// Whether two floats are one SSA value once nir_opt_cse has run in the
/// loop of passes (nir_to_vir.c:2264), which it does before the next
/// nir_opt_copy_prop_vars: the same float, or two equalSteps would take for
/// one were their operands each the one value already (since 1.177).
fn oneValue(work: *const Work, x: Float, y: Float, depth: u32) bool {
    if (x.step == y.step and x.part == y.part) return true;
    if (depth == 0 or x.part != y.part) return false;
    const p = work.steps[x.step];
    const q = work.steps[y.step];
    if (p.tag != q.tag or p.kind != q.kind) return false;
    if (p.tag == .constant or p.tag == .push) return equalSteps(work, p, q);
    if (!computes(p.tag) or p.at != q.at or !sameLookup(p, q)) return false;
    if (sameOperands(work, readsOf(p), readsOf(q), depth)) return true;
    if (!commutes(p)) return false;
    return sameOperands(work, .{ readsOf(p)[1], readsOf(p)[0], null, null }, readsOf(q), depth);
}

fn sameOperands(work: *const Work, left: [4]?u16, right: [4]?u16, depth: u32) bool {
    for (left, right) |l, r| {
        if ((l == null) != (r == null)) return false;
        const a = l orelse continue;
        const b = r.?;
        const kind = work.steps[a].kind;
        if (kind != work.steps[b].kind) return false;
        for (0..kind.parts()) |k| {
            if (!oneValue(work, partOf(work, a, @intCast(k)), partOf(work, b, @intCast(k)), depth - 1)) return false;
        }
    }
    return true;
}

/// OpCompositeInsert into an array, a struct or a matrix: ResultType,
/// Result, Object, Composite, the indexes. vtn_composite_insert's copy of
/// the composite with the element, the member, the column or the float the
/// indexes say replaced (spirv_to_nir.c:4612-4650): a float of a vector, a
/// vecN of the others and the one as nir_vector_insert_imm makes it (since
/// 1.176). A matrix's shape is held to its type's by `leafSteps`.
fn insertAggregate(work: *Work, operands: []const u32) Error!void {
    const type_id = try idOf(operands[0]);
    const id = try idOf(operands[1]);
    const into = try idOf(operands[3]);
    if (work.thing[type_id] != .matrix and work.aggregate[into] != type_id) return Error.Type;
    var made: [most_locals]u16 = undefined;
    const count = try leafSteps(work, operands[3], type_id, &made);
    var leaf: u16 = 0;
    var at = type_id;
    const indexes = operands[4..];
    for (indexes, 0..) |index, k| {
        if (work.thing[at] == .vector) {
            if (k != indexes.len - 1 or index >= work.wide[at]) return Error.Body;
            const kind = try kindOf(work, at);
            const object = try operand(work, operands[2], .f32x1);
            var vector = Step{ .tag = .construct, .kind = kind };
            for (0..kind.parts()) |p| {
                vector.from[p] = if (p == index) object else made[leaf];
                vector.part[p] = if (p == index) 0 else @intCast(p);
            }
            made[leaf] = try put(work, vector);
            return holdAggregate(work, id, type_id, made[0..count]);
        }
        const next = try within(work, at, index);
        leaf += next.leaf;
        at = next.type_id;
    }
    _ = try leafSteps(work, operands[2], at, made[leaf..count]);
    return holdAggregate(work, id, type_id, made[0..count]);
}

/// The variables at a flattened selection's merge. nir_lower_vars_to_ssa
/// gives the merge block a phi of each variable two ways bring different
/// values of, nir_lower_phis_to_scalar makes it a phi of each float, and
/// nir_opt_peephole_select a bcsel of each: a `select` on the selection's
/// comparison. A float both ways bring is that float, and where one way
/// brings nothing - a variable stored into in one arm only and never
/// before - the other's, as nir_opt_remove_phis takes a phi with an undef
/// source for its other (nir_opt_remove_phis.c:105-175; since 1.155).
///
/// The phis are in the order nir_phi_builder_finish puts them down, each
/// before the block's first (nir_phi_builder.c:272-297): the variables in
/// the reverse of the order they were first used in, and each one's
/// floats in order after
/// nir_lower_phis_to_scalar, which puts each before the vector's
/// (nir_lower_phis_to_scalar.c:195-218; since 1.156). Those of the
/// variables an if-else tree reaches come before the others' (since
/// 1.178).
///
/// A kept selection's merge has a phi of each float instead (since
/// 1.171), and one way that brings nothing brings nir_lower_undef_to_zero's
/// 0: the other's float is not there where the phi is
/// (nir_opt_remove_phis.c:133-140).
fn merge(work: *Work, selection: *Selection, level: u32) Error!void {
    const condition = selection.condition;
    // Those of the variables an if-else tree reaches first: the loop of
    // passes after the trees gives them their phis, each put before the
    // merge block's first instruction, which is then a phi the loop before
    // gave one of the others (since 1.178).
    for ([2]bool{ true, false }) |late| {
        var at = work.used_count;
        while (at > 0) {
            at -= 1;
            const local = work.first_used[at];
            if (work.local_late[local] != late) continue;
            for (0..work.local_kind[local].parts()) |k| {
                const yes = work.ends[level][0][local][k];
                const no = work.ends[level][1][local][k];
                if (yes.step != none and no.step != none and !(yes.step == no.step and yes.part == no.part)) {
                    if (work.local_bool[local] and selection.kept) return Error.Branches;
                }
                if ((yes.step == none) != (no.step == none)) {
                    if (work.local_bool[local] and selection.kept) return Error.Branches;
                    selection.one_way = true;
                }
                work.values[local][k] = if (yes.step == no.step and yes.part == no.part)
                    yes
                else if (selection.kept)
                    .{ .step = try put(work, phiStep(condition, try heldOf(work, yes), try heldOf(work, no))), .part = 0 }
                else if (yes.step == none)
                    no
                else if (no.step == none)
                    yes
                else if (dropped(work, selection, yes, no))
                    yes
                else chosen: {
                    var made = Step{ .tag = .select, .kind = .f32x1, .a = condition, .b = try floatOf(work, yes) };
                    made.from[0] = try floatOf(work, no);
                    break :chosen .{ .step = try put(work, made), .part = 0 };
                };
            }
        }
    }
}

/// A kept selection's phi of the float `yes` brings and the float `no`
/// does (since 1.171).
fn phiStep(condition: u16, yes: Float, no: Float) Step {
    var made = Step{ .tag = .phi, .kind = .f32x1, .a = yes.step, .b = no.step };
    made.part[0] = yes.part;
    made.part[1] = no.part;
    made.from[0] = condition;
    return made;
}

/// A selection kept a branch, at its merge block's first instruction past
/// its phis (since 1.171): one an arm of which holds what
/// nir_opt_peephole_select does not flatten, or whose arms are over its
/// limit. Its selects are its phis, where it was kept for the limit, and
/// its marks are put down. Only one in no other selection, of no other
/// in it, is kept.
fn keepSelection(work: *Work, selection: *const Selection, depth: u32) Error!void {
    if (depth != 1 or work.stage != .fragment) return Error.Branches;
    if (selection.inner != 0 or selection.collapsed or selection.killed) return Error.Branches;
    if (work.kept_count == most_kept) return Error.Branches;
    if (!selection.kept) {
        if (selection.one_way) return Error.Branches;
        for (work.steps[selection.arms_to..work.step_count]) |*each| {
            if (each.tag != .select or each.a != selection.condition) continue;
            if (isBool(work, each.b)) return Error.Branches;
            each.* = phiStep(selection.condition, partOf(work, each.b, 0), partOf(work, each.from[0], 0));
        }
    }
    const marks: [3]u16 = .{
        try put(work, .{ .tag = .begin_if, .kind = .f32x1, .a = selection.condition }),
        try put(work, .{ .tag = .begin_else, .kind = .f32x1 }),
        try put(work, .{ .tag = .end_if, .kind = .f32x1 }),
    };
    work.kept[work.kept_count] = .{
        .from = selection.arms_from,
        .split = selection.split,
        .to = selection.arms_to,
        .false_first = selection.false_first,
        .marks = marks,
    };
    work.kept_count += 1;
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
            // A tex in an arm that is flattened is one nir_opt_cse took
            // for one before the selection (`takenBefore`), which is not
            // in the arm when it is counted (since 1.185).
            .sample, .sample_compared, .texture_size, .texture_levels => continue,
            // A load_ubo is let through only where it may be speculated
            // (nir_opt_peephole_select.c:132-141), which none from vtn
            // may: no limit flattens its arm (since 1.160). A load_ssbo
            // is held to the same (since 1.164). A load_deref of a
            // variable of the function's own that is still one, which a
            // load_scratch is made of later, is let through by none
            // (nir_opt_peephole_select.c:109-129), nor is a store_deref
            // (since 1.177).
            .ubo, .ssbo, .ubo_indirect, .ssbo_indirect, .ssbo_store, .ssbo_atomic, .barrier, .scratch, .scratch_indirect, .scratch_store => return std.math.maxInt(u32),
            // ineg and iabs are move-like, as fneg and fabs are
            // (nir_opt_peephole_select.c:251-264; since 1.165).
            .integer => switch (@as(Integer, @enumFromInt(each.at))) {
                .ineg, .iabs => continue,
                else => {},
            },
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
        // A float a variable holds after the merge, where the other way
        // in left it nothing to choose against, is read later.
        for (work.values[0..work.local_count]) |holds| for (holds) |each_float| if (each_float.step == at) {
            used = true;
            only_added = false;
        };
        if (!used) continue;
        if (each.tag == .mul and only_added) continue;
        count += each.kind.parts();
    }
    return count;
}

/// Whether `user` reads the step `target`.
fn readsStep(user: Step, target: u16) bool {
    for (readsOf(user)) |field| if (field) |of| {
        if (of == target) return true;
    };
    return false;
}

/// An operand id as a bool step: a comparison, a bool of bools or a bool
/// chosen. A bool constant is not here.
fn boolOf(work: *const Work, word: u32) Error!u16 {
    const at = work.step_of[try idOf(word)];
    if (at == none) return Error.Body;
    if (!isBool(work, at)) return Error.Type;
    return at;
}

/// What v3d's optimization loop does to the body once
/// nir_opt_peephole_select has flattened it, round after round until one
/// changes nothing (v3d_optimize_nir, nir_to_vir.c:2234-2300): nir_opt_dce
/// takes out what nothing live reads, nir_opt_cse takes a step equal to an
/// earlier one for that one, and nir_opt_algebraic rewrites (since 1.157;
/// as Mesa runs them since 1.158). The steps are kept in the list of the
/// program, as a NIR block keeps its instructions, so that a step a rule
/// makes goes where Mesa's builder puts it, and laid out in that list
/// again at the end.
///
/// The rules, in the list nir_opt_algebraic.py lists them, which is the
/// list they are tried in (nir_algebraic_instr, nir_search.c:809-838):
///
/// - Of an address's arithmetic, and of the integers it is made of
///   (`Order.addressRule`; since 1.166): an imul by a power of two a
///   shift, and by minus one an ineg of a shift (:183, :188, :190);
///   (('iadd', a, 0), a) (:239) and (('imul', a, 0), 0) (:287); a shift
///   or a product of an iadd of a constant made the sum of the two
///   shifted or multiplied, the product's iadd read once (:729-731,
///   :736-740); (('ishl', a, 0), a) (:1800); and a constant gathered
///   past an iadd of two that are none (:2423) and into an iadd's own
///   constant (:2438). A rule's operation of constants is the constant it
///   folds to, there, a round before nir_opt_constant_folding would make
///   it.
/// - Of floats (`Order.floatRule`; since 1.174), which a Vulkan 1.0
///   module leaves fast math: (('fneg', ('fneg', a)), a) (:230);
///   (('fabs', ('fneg', a)), ('fabs', a)) (:232; since 1.186); an fadd
///   of a zero, the other operand (:236-237); of two fmuls sharing a
///   factor, the fmul of it and the fadd of the others (:246; since
///   1.175); of an fneg and what it negates, a zero (:266-267); of an
///   fneg and an fadd it cancels into, what is left (:271-272; since
///   1.175); (('fadd', a, a), ('fmul', a, 2.0)) (:274); of `a` and an
///   fadd of `a` read once, the other plus `a` times 2.0 (:275; since
///   1.175); an fmul by a zero, a zero (:277-278), by 1.0 the other
///   operand (:292) and by -1.0 its fneg (:296); an fsub as the fadd of an
///   fneg it is lowered to (:2401), and an fadd of an fneg that fsub, as
///   the late rules make it (:3868). A vector a rule takes some floats of
///   and not the rest is taken a float at a time (`Order.split`), as
///   nir_lower_alu_to_scalar has left it.
/// - (('inot', ('feq(is_used_once)', a, b)), ('fneu', a, b)) and the
///   other way about (:747-748), and the same of the integer comparisons,
///   ilt and ige, ult and uge, ieq and ine (:749-754; since 1.165), the
///   new comparison put after the old one (nir_replace_instr, :700-718);
///   (('inot', ('inot', a)), a) (:1736).
/// - (('iand', a, a), a) and (('ior', a, a), a) (:1724, :1728).
/// - (('bcsel', ('inot', a), b, c), ('bcsel', a, c, b)) (:978); a bcsel
///   in an arm of one on the same condition, that arm of it (:979-980);
///   two bcsels on one condition in the two arms, sharing a value, one
///   bcsel of them (:981-984); (('bcsel', a, a, b), ('ior', a, b)) and
///   (('bcsel', a, b, a), ('iand', a, b)) (:986, :988), what glslc's
///   phis of || and && come to; (('bcsel', a, b, b), b) (:1936); and a
///   bcsel read once in an arm of another, sharing the other arm's value,
///   one bcsel on the iand or ior of the two conditions (:2512-2515),
///   what two nested selections flattened come to.
///
/// Not ported: the bcsels made an fmin or fmax, an fabs or an fsqrt, or a
/// float itself, which want floats proven numbers or not zero (:823-838,
/// :974-977, :1910-1913, :2510); the inot of an flt or fge made the
/// opposite, which wants the same (:745-746); the iands and iors of
/// comparisons sharing a float (:1157-1190) and of iands and iors
/// (:1796-1797 and others); the bcsels of two of one operation hoisted
/// (:3483-3496); and every rule of a bool constant, which is not here.
/// Of integers: an iadd of two products or shifts sharing an operand
/// (:248-249), a shift of three iadds (:732-733), a product of a shift
/// (:597), the products of a negation and of products reassociated
/// (:2413, :2419, :2435, :3641), and every other rule of an integer
/// operation the shader computes itself. Of floats: the rules of b2f,
/// fsat and fmulz, which are not steps here, and every other rule of a
/// float operation.
fn algebraic(work: *Work) Error!void {
    try deadScratch(work);
    var list = Order.start(work);
    // The stores nir_opt_dead_write_vars found written over, and those of
    // a variable nir_remove_dead_variables takes out (since 1.177).
    for (work.unwritten[0..work.step_count], 0..) |unwritten, at| {
        if (unwritten) list.removed[at] = true;
    }
    try list.rematerialize(work);
    while (true) {
        list.dce(work);
        const merged = list.cse(work);
        const rewrote = try list.run(work);
        const folded = try list.fold(work);
        if (!merged and !rewrote and !folded) break;
    }
    list.layOut(work);
}

/// nir_remove_dead_variables over the variables in scratch, which v3d's
/// loop of passes runs after nir_opt_copy_prop_vars (nir_to_vir.c:
/// 2253-2257): one the program loads nothing of, once the copies are
/// taken, is used for no load and is dead, its stores taken out with it
/// (add_var_use_deref, nir_remove_dead_variables.c:66-90;
/// remove_dead_var_writes, :110-170). nir_lower_vars_to_scratch then
/// places what is left, so the walk is begun again with it marked
/// (`Scratch.dead`; since 1.177).
fn deadScratch(work: *Work) Error!void {
    var loaded: [most_scratch_variables]bool = @splat(false);
    for (work.program(), 0..) |each, at| {
        if (each.tag == .scratch or each.tag == .scratch_indirect) loaded[work.step_path[at].variable] = true;
    }
    var found = false;
    for (0..work.scratch.count) |k| {
        if (loaded[k] or work.scratch.dead[k]) continue;
        work.scratch.dead[k] = true;
        found = true;
    }
    if (found) return Error.Storage;
    for (work.program(), 0..) |each, at| {
        if (each.tag == .scratch_store and work.scratch.dead[work.step_path[at].variable]) work.unwritten[at] = true;
    }
}

/// The steps in the list of the program, which a rule's new steps are
/// put into between others; and which of them are out of it.
const Order = struct {
    next: [most_steps]u16 = @splat(none),
    prev: [most_steps]u16 = @splat(none),
    first: u16 = none,
    last: u16 = none,
    /// Rewritten by a rule, or found equal to an earlier step: nothing
    /// reads it any more.
    removed: [most_steps]bool = @splat(false),
    /// Read by nothing live when the round began: nir_opt_dce took it
    /// out. A step that a rule leaves unread in a round is still there
    /// until the next, as Mesa's is, and is still counted as a use.
    gone: [most_steps]bool = @splat(false),

    /// The steps in the order they were read, but for a kept
    /// selection's: its marks around its arms, and the true arm first,
    /// as vtn builds the nir_if's then_list before its else_list
    /// whatever the order of the module's blocks (since 1.171).
    fn start(work: *const Work) Order {
        var list: Order = .{};
        var marked: [most_steps]bool = @splat(false);
        for (work.kept[0..work.kept_count]) |kept| for (kept.marks) |mark| {
            marked[mark] = true;
        };
        var at: u16 = 0;
        for (work.kept[0..work.kept_count]) |kept| {
            while (at < kept.from) : (at += 1) if (!marked[at]) list.append(at);
            const first: [2]u16 = .{ kept.from, kept.split };
            const second: [2]u16 = .{ kept.split, kept.to };
            const yes = if (kept.false_first) second else first;
            const no = if (kept.false_first) first else second;
            list.append(kept.marks[0]);
            for (yes[0]..yes[1]) |each| list.append(@intCast(each));
            list.append(kept.marks[1]);
            for (no[0]..no[1]) |each| list.append(@intCast(each));
            list.append(kept.marks[2]);
            at = kept.to;
        }
        while (at < work.step_count) : (at += 1) if (!marked[at]) list.append(at);
        return list;
    }

    fn append(list: *Order, at: u16) void {
        list.prev[at] = list.last;
        if (list.last != none) list.next[list.last] = at else list.first = at;
        list.last = at;
    }

    /// A constant or a varying read in an arm of a kept selection, and
    /// read again where that arm is not: the walk keeps one step of each,
    /// where vtn makes a load_const and nir_lower_io a load_input at each
    /// read (vtn_const_ssa_value, spirv_to_nir.c), and nir_opt_cse
    /// keeps one only where it dominates. Each read that it does not
    /// dominate is of a step of its own, put before the reader (since
    /// 1.171).
    fn rematerialize(list: *Order, work: *Work) Error!void {
        if (work.kept_count == 0) return;
        var at = list.first;
        while (at != none) : (at = list.next[at]) {
            const each = work.steps[at];
            if (each.tag == .phi) continue;
            for (readsOf(each)) |field| if (field) |of| {
                const tag = work.steps[of].tag;
                if (tag != .constant and tag != .input) continue;
                if (dominates(work, of, at) or !readsStep(work.steps[at], of)) continue;
                const made = list.link(work, at, try put(work, work.steps[of]));
                rereads(&work.steps[at], of, made);
            };
        }
    }

    fn present(list: *const Order, at: u16) bool {
        return !list.removed[at] and !list.gone[at];
    }

    /// A new step, put in the program before `at`.
    fn before(list: *Order, work: *Work, at: u16, adding: Step) Error!u16 {
        return list.link(work, at, try put(work, adding));
    }

    /// One nir_opt_constant_folding, after each nir_opt_algebraic as
    /// v3d's loop of passes has it (nir_to_vir.c:2280-2281): an operation
    /// of floats whose operands are constants, through the vecs and the
    /// components that name them, is the constant it makes (`foldedOf`),
    /// and what read it reads that (since 1.176). The sum of two
    /// constant factors the fadd rule of :246 builds is one, which the
    /// next round's fmul of a one (:292) may take out.
    fn fold(list: *Order, work: *Work) Error!bool {
        var progress = false;
        var at = list.first;
        while (at != none) : (at = list.next[at]) {
            if (!list.present(at)) continue;
            const each = work.steps[at];
            const b: ?u16 = switch (each.tag) {
                .add, .sub, .mul, .min, .max, .set_less => each.b,
                .negate, .abs, .floor, .ceil, .trunc, .round, .recip, .rsqrt, .sat, .sign => null,
                else => continue,
            };
            if (work.steps[each.a].kind != each.kind) continue;
            const constant = try foldedOf(work, each.tag, each.a, b) orelse continue;
            _ = list.replaced(work, at, list.link(work, at, constant));
            progress = true;
        }
        return progress;
    }

    /// `op` of `a` and `b`, which a rule builds, put before `at`: where
    /// both are constants, the constant nir_opt_constant_folding makes of
    /// it there, a round before Mesa's would (since 1.166).
    fn integerBefore(list: *Order, work: *Work, at: u16, op: Integer, a: u16, b: u16) Error!u16 {
        if (try foldedInteger(work, op, a, b)) |constant| return list.link(work, at, constant);
        return list.before(work, at, integerStep(op, work.steps[a].kind, a, b));
    }

    /// A constant of `f` of each word of the constant `from`, put before
    /// `at`: the constant a rule's operation of a constant folds to.
    fn mappedBefore(list: *Order, work: *Work, at: u16, from: u16, comptime f: fn (u32) u32) Error!u16 {
        const of = work.steps[from];
        const parts = of.kind.parts();
        if (work.pool_count + parts > work.pool.len) return Error.Uniforms;
        const out = work.pool_count;
        for (0..parts) |k| work.pool[out + k] = @bitCast(f(@bitCast(work.pool[of.at + k])));
        work.pool_count += parts;
        return list.before(work, at, .{ .tag = .constant, .kind = of.kind, .at = out });
    }

    /// A step `put` already, put in the program before `at`, in its
    /// region.
    fn link(list: *Order, work: *Work, at: u16, new: u16) u16 {
        work.region[new] = work.region[at];
        const earlier = list.prev[at];
        list.prev[new] = earlier;
        list.next[new] = at;
        list.prev[at] = new;
        if (earlier != none) list.next[earlier] = new else list.first = new;
        return new;
    }

    /// A new step, put in the program after `at`.
    fn after(list: *Order, work: *Work, at: u16, adding: Step) Error!u16 {
        const new = try put(work, adding);
        work.region[new] = work.region[at];
        const later = list.next[at];
        list.next[new] = later;
        list.prev[new] = at;
        list.next[at] = new;
        if (later != none) list.prev[later] = new else list.last = new;
        return new;
    }

    /// nir_opt_dce: live is the colour's step, a discard, and what a live
    /// step reads.
    fn dce(list: *Order, work: *const Work) void {
        var reached: [most_steps]bool = @splat(false);
        if (work.stored != none) reached[work.stored] = true;
        var at = list.last;
        while (at != none) : (at = list.prev[at]) {
            if (list.removed[at]) continue;
            const each = work.steps[at];
            // What writes memory, or orders it, is kept whatever reads it
            // (nir_instr_can_remove, nir_opt_dce.c; since 1.168 and 1.169).
            if (each.tag == .discard or each.tag == .output or each.tag == .ssbo_store or each.tag == .ssbo_atomic or each.tag == .barrier or each.tag == .scratch_store) reached[at] = true;
            // A kept selection's marks are its nir_if, which no pass but
            // nir_opt_dead_cf takes out (since 1.171).
            if (each.tag == .begin_if or each.tag == .begin_else or each.tag == .end_if) reached[at] = true;
            if (!reached[at]) continue;
            for (readsOf(each)) |field| if (field) |operand_at| {
                reached[operand_at] = true;
            };
        }
        for (0..work.step_count) |k| {
            if (!reached[k]) list.gone[k] = true;
        }
    }

    /// nir_opt_cse: a step equal to one before it - the same operation of
    /// the same floats, the two of an operation that does not mind their
    /// list either way about - is that one (nir_instrs_equal,
    /// nir_instr_set.c). A push constant's word read twice is one read
    /// too: load_push_constant, and the load_uniform v3dv makes of it
    /// (lower_load_push_constant, v3dv_pipeline.c:571-580), are
    /// CAN_ELIMINATE and CAN_REORDER (nir_intrinsics.py:1365, :1403), and
    /// glslc -O0 loads one through an access chain each time it is read
    /// (since 1.165). Two constants of the same words are one load_const
    /// (nir_instrs_equal, nir_instr_set.c), which the constants a lowering
    /// makes are as much as the module's (since 1.166). Two samples of one
    /// unit, lookup, offset and sources are one tex (`sameLookup`;
    /// instr_can_rewrite, nir_instr_set.c:47-52), which spirv-opt leaves
    /// two (since 1.185). Varyings are each one step already, and a
    /// discard is no value.
    fn cse(list: *Order, work: *Work) bool {
        var progress = false;
        var at = list.first;
        while (at != none) : (at = list.next[at]) {
            const tag = work.steps[at].tag;
            if (!list.present(at) or !(computes(tag) or tag == .push or tag == .constant)) continue;
            var earlier = list.first;
            while (earlier != at) : (earlier = list.next[earlier]) {
                if (!list.present(earlier)) continue;
                // nir_instr_set's equal instruction is one that dominates
                // (nir_instr_set_add_or_rewrite, nir_instr_set.c): not one
                // in an arm of a kept selection, for a step outside it or
                // in its other arm (since 1.171).
                if (!dominates(work, earlier, at)) continue;
                if (!equalSteps(work, work.steps[earlier], work.steps[at])) continue;
                replaceUses(work, at, earlier);
                list.removed[at] = true;
                progress = true;
                break;
            }
        }
        return progress;
    }

    /// How many times the steps still in the program, and the colour
    /// stored, read `at`: what is_used_once counts.
    fn usesOf(list: *const Order, work: *const Work, at: u16) u32 {
        var count: u32 = if (work.stored == at) 1 else 0;
        for (work.steps[0..work.step_count], 0..) |user, k| {
            if (!list.present(@intCast(k))) continue;
            for (readsOf(user)) |field| if (field) |operand_at| {
                if (operand_at == at) count += 1;
            };
        }
        return count;
    }

    /// One nir_opt_algebraic: the steps from the last to the first, as
    /// nir_algebraic_impl pops them (nir_search.c:880-906), each rewritten
    /// by the first rule that matches it. What reads the step a rule leaves
    /// in its place is looked at again after the rest
    /// (nir_algebraic_update_automaton, :617-638); the new step itself is
    /// not, until the next round.
    fn run(list: *Order, work: *Work) Error!bool {
        var queue: [4 * most_steps]u16 = undefined;
        var head: usize = 0;
        var tail: usize = 0;
        var at = list.last;
        while (at != none) : (at = list.prev[at]) {
            if (!list.present(at) or !computes(work.steps[at].tag)) continue;
            queue[tail] = at;
            tail += 1;
        }
        var progress = false;
        while (head < tail) {
            const each = queue[head];
            head += 1;
            if (!list.present(each)) continue;
            const left = try list.rule(work, each) orelse continue;
            progress = true;
            for (work.steps[0..work.step_count], 0..) |user, k| {
                if (!list.present(@intCast(k)) or !computes(user.tag) or !readsStep(user, left)) continue;
                if (tail == queue.len) return Error.Steps;
                queue[tail] = @intCast(k);
                tail += 1;
            }
        }
        return progress;
    }

    /// `at` rewritten by the first rule that matches it, and the step it
    /// leaves in its place, or null.
    fn rule(list: *Order, work: *Work, at: u16) Error!?u16 {
        const each = work.steps[at];
        switch (each.tag) {
            .logic => switch (@as(Logic, @enumFromInt(each.at))) {
                .inot => {
                    const operand_step = work.steps[each.a];
                    if (operand_step.tag == .compare and list.usesOf(work, each.a) == 1) {
                        const flipped: ?Comparison = switch (@as(Comparison, @enumFromInt(operand_step.at))) {
                            .equal => .not_equal,
                            .not_equal => .equal,
                            .int_less => .int_greater_equal,
                            .int_greater_equal => .int_less,
                            .uint_less => .uint_greater_equal,
                            .uint_greater_equal => .uint_less,
                            .int_equal => .int_not_equal,
                            .int_not_equal => .int_equal,
                            else => null,
                        };
                        if (flipped) |into| {
                            // An inot of an instruction is built after
                            // that instruction, not before the inot.
                            const flipped_at = try list.after(work, each.a, .{ .tag = .compare, .kind = .f32x1, .a = operand_step.a, .b = operand_step.b, .at = @intFromEnum(into) });
                            return list.replaced(work, at, flipped_at);
                        }
                    }
                    if (operand_step.tag == .logic and operand_step.at == @intFromEnum(Logic.inot)) return list.replaced(work, at, operand_step.a);
                },
                .iand, .ior => if (each.a == each.b) return list.replaced(work, at, each.a),
            },
            .integer => if (try list.addressRule(work, at)) |left| return left,
            .select => {
                const condition = each.a;
                const yes = each.b;
                const no = each.from[0];
                const on = work.steps[condition];
                if (on.tag == .logic and on.at == @intFromEnum(Logic.inot))
                    return try list.rebuilt(work, at, selectOf(on.a, no, yes));
                const y = work.steps[yes];
                const n = work.steps[no];
                const yes_select = y.tag == .select;
                const no_select = n.tag == .select;
                if (yes_select and y.a == condition) return try list.rebuilt(work, at, selectOf(condition, y.b, no));
                if (no_select and n.a == condition) return try list.rebuilt(work, at, selectOf(condition, yes, n.from[0]));
                if (yes_select and no_select and y.a == n.a) {
                    const once = list.usesOf(work, no) == 1 or list.usesOf(work, yes) == 1;
                    if (once and sameFloat(work, y.b, n.b)) {
                        const inner = try list.before(work, at, selectOf(condition, y.from[0], n.from[0]));
                        return try list.rebuilt(work, at, selectOf(y.a, y.b, inner));
                    }
                    if (once and sameFloat(work, y.from[0], n.from[0])) {
                        const inner = try list.before(work, at, selectOf(condition, y.b, n.b));
                        return try list.rebuilt(work, at, selectOf(y.a, inner, y.from[0]));
                    }
                }
                if (yes == condition) return try list.rebuilt(work, at, logicOf(.ior, condition, no));
                if (no == condition) return try list.rebuilt(work, at, logicOf(.iand, condition, yes));
                if (sameFloat(work, yes, no)) return list.replaced(work, at, yes);
                if (try list.boolFloatRule(work, at, condition, yes, no)) |left| return left;
                if (yes_select and list.usesOf(work, yes) == 1) {
                    if (sameFloat(work, y.from[0], no)) {
                        const both = try list.before(work, at, logicOf(.iand, condition, y.a));
                        return try list.rebuilt(work, at, selectOf(both, y.b, no));
                    }
                    if (sameFloat(work, y.b, no)) {
                        const turned = try list.before(work, at, logicOf(.inot, y.a, 0));
                        const both = try list.before(work, at, logicOf(.iand, condition, turned));
                        return try list.rebuilt(work, at, selectOf(both, y.from[0], no));
                    }
                }
                if (no_select and list.usesOf(work, no) == 1) {
                    if (sameFloat(work, n.b, yes)) {
                        const either = try list.before(work, at, logicOf(.ior, condition, n.a));
                        return try list.rebuilt(work, at, selectOf(either, yes, n.from[0]));
                    }
                    if (sameFloat(work, n.from[0], yes)) {
                        const turned = try list.before(work, at, logicOf(.inot, condition, 0));
                        const both = try list.before(work, at, logicOf(.iand, n.a, turned));
                        return try list.rebuilt(work, at, selectOf(both, n.b, yes));
                    }
                }
            },
            .negate, .abs, .add, .sub, .mul => if (try list.floatRule(work, at)) |left| return left,
            else => {},
        }
        return null;
    }

    /// The identities of float arithmetic (since 1.174): `at`, an fneg,
    /// an fabs, an fadd, an fsub or an fmul, rewritten by the first that
    /// matches it, in the list's order, its operands either way about
    /// where it commutes, and the step it leaves in its place, or null.
    ///
    /// A Vulkan 1.0 module has no float controls and decorates nothing
    /// FPFastMathMode, so vtn leaves every float operation
    /// nir_fp_fast_math (vtn_handle_fp_fast_math, vtn_alu.c:472-485); the
    /// walk refuses NoContraction, which would make one nir_fp_exact. So
    /// the inexact (`~`), `nsz` and `nnan` rules hold of every one here.
    /// The fcanonicalize a rule leaves is taken out by
    /// optimize_fcanonicalize (:161-163): no module asks the V3D to flush
    /// denormals. An fsub is what nir_opt_algebraic lowers to an fadd of
    /// the fneg (:2401) and makes again late on a device that has one
    /// (:3868, `has_fsub`, v3dv_pipeline.c:207): its rules are the fadd's
    /// of that fneg, the fneg of a constant folded; and an fadd of an fneg
    /// a rule leaves is that fsub, as the walk makes one of an fadd it
    /// reads.
    ///
    /// Not ported: the rules of b2f, fsat and fmulz, which are not steps
    /// here. The rules of two operations (:246, :271-272, :275) take a
    /// vector whole, not a float at a time.
    fn floatRule(list: *Order, work: *Work, at: u16) Error!?u16 {
        const each = work.steps[at];
        const pairs = [2][2]u16{ .{ each.a, each.b }, .{ each.b, each.a } };
        switch (each.tag) {
            // (('fneg', ('fneg', a)), ('fcanonicalize', a)) (:230).
            .negate => if (try list.negatedBefore(work, at, each.a)) |inner| return list.replaced(work, at, inner),
            // (('fabs', ('fneg', a)), ('fabs', a)) (:232; since 1.186).
            .abs => if (try list.negatedBefore(work, at, each.a)) |inner| return try list.rebuilt(work, at, .{ .tag = .abs, .kind = each.kind, .a = inner }),
            .add => {
                // (('fadd(nsz)', a, 0.0), ('fcanonicalize', a)) and
                // (('fadd', a, -0.0), ('fcanonicalize', a)) (:236-237).
                for (pairs) |pair| if (allConstant(work, pair[1], isSignedZero) and work.steps[pair[0]].kind == each.kind) return list.replaced(work, at, pair[0]);
                // (('~fadd', ('fmul', a, b), ('fmul', a, c)),
                // ('fmul', a, ('fadd', b, c))) (:246; since 1.175).
                if (try list.factored(work, at)) |left| return left;
                // (('~fadd', ('fneg', a), a), 0.0) and
                // (('fadd(nnan)', ('fneg', a), a), 0.0) (:266-267).
                for (pairs) |pair| if (negatesValue(work, pair[0], pair[1])) return list.replaced(work, at, try list.splatBefore(work, at, each.kind, 0));
                // (('~fadd', ('fneg', a), ('fadd', a, b)), b) and
                // (('~fadd', a, ('fadd', ('fneg', a), b)), b) (:271-272;
                // since 1.175).
                if (try list.cancelled(work, at)) |left| return left;
                // (('fadd', a, a), ('fmul', a, 2.0)) (:274).
                if (sameValue(work, each.a, each.b)) return try list.rebuilt(work, at, .{ .tag = .mul, .kind = each.kind, .a = each.a, .b = try list.splatBefore(work, at, .f32x1, @bitCast(@as(f32, 2))) });
                // (('fadd(contract)', a, ('fadd(is_used_once)', a, b)),
                // ('fadd', b, ('fmul', a, 2.0))) (:275; since 1.175).
                if (try list.contracted(work, at)) |left| return left;
                // (('fadd@32', a, ('fneg', 'b')), ('fsub', 'a', 'b'),
                // 'options->has_fsub') (:3868), late.
                for (pairs) |pair| if (work.steps[pair[0]].kind == each.kind) {
                    if (try list.negatedBefore(work, at, pair[1])) |inner| return try list.rebuilt(work, at, .{ .tag = .sub, .kind = each.kind, .a = pair[0], .b = inner });
                };
            },
            .sub => {
                // `a` less a zero: an fadd of the zero's fneg (:236-237).
                if (allConstant(work, each.b, isSignedZero) and work.steps[each.a].kind == each.kind) return list.replaced(work, at, each.a);
                // A zero less `b`: an fadd of the zero and the fneg of
                // `b`, that fneg (:236-237).
                if (allConstant(work, each.a, isSignedZero) and work.steps[each.b].kind == each.kind) return try list.rebuilt(work, at, .{ .tag = .negate, .kind = each.kind, .a = each.b });
                // `a` less itself: an fadd of `a` and its fneg (:266-267).
                if (sameValue(work, each.a, each.b)) return list.replaced(work, at, try list.splatBefore(work, at, each.kind, 0));
                // The fadd's (:271-272, :275; since 1.175).
                if (try list.cancelled(work, at)) |left| return left;
                if (try list.contracted(work, at)) |left| return left;
                // `a` less an fneg of `c`: an fadd of an fneg of an fneg
                // (:230).
                if (try list.negatedBefore(work, at, each.b)) |inner| return try list.rebuilt(work, at, .{ .tag = .add, .kind = each.kind, .a = each.a, .b = inner });
            },
            .mul => {
                // (('fmul(nsz,nnan)', 'a', 0.0), 0.0) and the same of
                // -0.0 (:277-278).
                for (pairs) |pair| if (allConstant(work, pair[1], isSignedZero)) return list.replaced(work, at, try list.splatBefore(work, at, each.kind, 0));
                // (('fmul', a, 1.0), ('fcanonicalize', a)) (:292).
                for (pairs) |pair| if (allConstant(work, pair[1], isFloatOne) and work.steps[pair[0]].kind == each.kind) return list.replaced(work, at, pair[0]);
                // (('fmul', a, -1.0), ('fneg', a)) (:296).
                for (pairs) |pair| if (allConstant(work, pair[1], isFloatMinusOne) and work.steps[pair[0]].kind == each.kind) return try list.rebuilt(work, at, .{ .tag = .negate, .kind = each.kind, .a = pair[0] });
            },
            else => return null,
        }
        return list.split(work, at);
    }

    /// (('~fadd', ('fmul', a, b), ('fmul', a, c)), ('fmul', a, ('fadd',
    /// b, c))) (:246) of the fadd `at`: its three commutative operations
    /// flipped in the order nir_search tries them, the bit of each in its
    /// place in the pattern (match_expression, nir_search.c:355-380 and
    /// :655-672; __index_comm_exprs, nir_algebraic.py:463-480). A vector
    /// is the product's first operand, as an operation float by float
    /// reads a scalar second.
    fn factored(list: *Order, work: *Work, at: u16) Error!?u16 {
        const each = work.steps[at];
        if (work.steps[each.a].tag != .mul or work.steps[each.b].tag != .mul) return null;
        for (0..8) |comb| {
            const left = work.steps[if (comb & 1 != 0) each.b else each.a];
            const right = work.steps[if (comb & 1 != 0) each.a else each.b];
            const a = if (comb & 2 != 0) left.b else left.a;
            const b = if (comb & 2 != 0) left.a else left.b;
            const other = if (comb & 4 != 0) right.b else right.a;
            const c = if (comb & 4 != 0) right.a else right.b;
            if (!sameValue(work, a, other)) continue;
            const sum = if (work.steps[b].kind == .f32x1)
                try list.before(work, at, .{ .tag = .add, .kind = work.steps[c].kind, .a = c, .b = b })
            else
                try list.before(work, at, .{ .tag = .add, .kind = work.steps[b].kind, .a = b, .b = c });
            const product: Step = if (work.steps[a].kind == each.kind)
                .{ .tag = .mul, .kind = each.kind, .a = a, .b = sum }
            else
                .{ .tag = .mul, .kind = each.kind, .a = sum, .b = a };
            if (work.steps[product.a].kind != each.kind) return null;
            return try list.rebuilt(work, at, product);
        }
        return null;
    }

    /// (('~fadd', ('fneg', a), ('fadd', a, b)), b) and (('~fadd', a,
    /// ('fadd', ('fneg', a), b)), b) (:271-272) of the fadd or fsub `at`,
    /// an fsub the fadd of the fneg it is lowered to (:2401), the inner
    /// fadd as well.
    fn cancelled(list: *Order, work: *Work, at: u16) Error!?u16 {
        const outer = addendsOf(work, at) orelse return null;
        inline for (.{ false, true }) |second| {
            for (0..4) |comb| {
                const p = outer[if (comb & 1 != 0) 1 else 0];
                const q = outer[if (comb & 1 != 0) 0 else 1];
                if (q.turned) continue;
                const inner = addendsOf(work, q.at) orelse continue;
                const i = inner[if (comb & 2 != 0) 1 else 0];
                const kept = inner[if (comb & 2 != 0) 0 else 1];
                const matched = if (!second)
                    !i.turned and sameNegated(work, p, i.at)
                else
                    !p.turned and sameNegated(work, i, p.at);
                if (!matched) continue;
                const left = try list.addendBefore(work, at, kept);
                if (work.steps[left].kind != work.steps[at].kind) return null;
                return list.replaced(work, at, left);
            }
        }
        return null;
    }

    /// (('fadd(contract)', a, ('fadd(is_used_once)', a, b)), ('fadd', b,
    /// ('fmul', a, 2.0))) (:275) of the fadd or fsub `at`, either an fsub
    /// the fadd of the fneg it is lowered to; an fadd of an fneg made the
    /// fsub the late rules make of it (:3868).
    fn contracted(list: *Order, work: *Work, at: u16) Error!?u16 {
        const each = work.steps[at];
        const outer = addendsOf(work, at) orelse return null;
        for (0..4) |comb| {
            const a = outer[if (comb & 1 != 0) 1 else 0];
            const q = outer[if (comb & 1 != 0) 0 else 1];
            if (a.turned or q.turned or list.usesOf(work, q.at) != 1) continue;
            const inner = addendsOf(work, q.at) orelse continue;
            const other = inner[if (comb & 2 != 0) 1 else 0];
            const b = inner[if (comb & 2 != 0) 0 else 1];
            if (other.turned or !sameValue(work, a.at, other.at)) continue;
            if (work.steps[a.at].kind != each.kind) return null;
            if (!b.turned and work.steps[b.at].kind != each.kind) return null;
            const doubled = try list.before(work, at, .{ .tag = .mul, .kind = each.kind, .a = a.at, .b = try list.splatBefore(work, at, .f32x1, @bitCast(@as(f32, 2))) });
            if (b.turned) return try list.rebuilt(work, at, .{ .tag = .sub, .kind = each.kind, .a = doubled, .b = b.at });
            return try list.rebuilt(work, at, .{ .tag = .add, .kind = each.kind, .a = b.at, .b = doubled });
        }
        return null;
    }

    /// An addend as a step: an fsub's second its fneg, put before `at`.
    fn addendBefore(list: *Order, work: *Work, at: u16, of: Addend) Error!u16 {
        if (!of.turned) return of.at;
        return list.before(work, at, .{ .tag = .negate, .kind = work.steps[of.at].kind, .a = of.at });
    }

    /// A vector fneg, fabs, fadd, fsub or fmul a rule above would rewrite
    /// a float of and not the whole: nir_lower_alu_to_scalar has made it an
    /// instruction a float before nir_opt_algebraic sees it
    /// (v3d_optimize_nir, nir_to_vir.c:2259; preprocess_nir,
    /// v3dv_pipeline.c:404), so the rule rewrites that float alone. It is
    /// a construct of the operation of each float, a constant float a
    /// constant of its own, which the rules take one by one in the next
    /// round.
    fn split(list: *Order, work: *Work, at: u16) Error!?u16 {
        const each = work.steps[at];
        if (each.kind == .f32x1) return null;
        const parts = each.kind.parts();
        const folds = for (0..parts) |k| {
            if (floatFolds(work, each, @intCast(k))) break true;
        } else false;
        if (!folds) return null;
        var made = Step{ .tag = .construct, .kind = each.kind };
        for (0..parts) |k| {
            var scalar = Step{ .tag = each.tag, .kind = .f32x1, .a = try list.floatBefore(work, at, operandPart(work, each.a, @intCast(k))) };
            if (each.tag != .negate and each.tag != .abs) scalar.b = try list.floatBefore(work, at, operandPart(work, each.b, @intCast(k)));
            made.from[k] = try list.before(work, at, scalar);
            made.part[k] = 0;
        }
        return try list.rebuilt(work, at, made);
    }

    /// What `of` is the fneg of, where it is one, as a step of its kind;
    /// a float of one named through a component, as a step of its own.
    fn negatedBefore(list: *Order, work: *Work, at: u16, of: u16) Error!?u16 {
        if (work.steps[of].tag == .negate) return work.steps[of].a;
        if (work.steps[of].kind != .f32x1) return null;
        const float = partOf(work, of, 0);
        const turned = work.steps[float.step];
        if (turned.tag != .negate) return null;
        return try list.floatBefore(work, at, partOf(work, turned.a, float.part));
    }

    /// A float as a step of one, put before `at`: the step itself where it
    /// is one float, a constant of its own where it is a constant's, else
    /// a component of it.
    fn floatBefore(list: *Order, work: *Work, at: u16, of: Float) Error!u16 {
        if (floatBits(work, of)) |word| return list.splatBefore(work, at, .f32x1, word);
        if (work.steps[of.step].kind == .f32x1) return of.step;
        return list.before(work, at, .{ .tag = .component, .kind = .f32x1, .a = of.step, .at = of.part });
    }

    /// A constant of `kind`, each word `word`, put before `at`: the
    /// constant a float rule leaves.
    fn splatBefore(list: *Order, work: *Work, at: u16, kind: Kind, word: u32) Error!u16 {
        const parts = kind.parts();
        if (work.pool_count + parts > work.pool.len) return Error.Uniforms;
        const out = work.pool_count;
        for (0..parts) |k| work.pool[out + k] = @bitCast(word);
        work.pool_count += parts;
        return list.before(work, at, .{ .tag = .constant, .kind = kind, .at = out });
    }

    /// The rules of an address's arithmetic (since 1.166): `at`, an
    /// integer operation, rewritten by the first that matches it, and the
    /// step it leaves in its place, or null. A commutative operation's
    /// operands are matched either way about (nir_search.c:358-380);
    /// none of these matches two ways, a constant being where the other
    /// operand is no constant.
    fn addressRule(list: *Order, work: *Work, at: u16) Error!?u16 {
        const each = work.steps[at];
        const op: Integer = @enumFromInt(each.at);
        const pairs = [2][2]u16{ .{ each.a, each.b }, .{ each.b, each.a } };
        switch (op) {
            .iadd => {
                // (('iadd', a, 0), a) (:239).
                for (pairs) |pair| if (isZero(work, pair[1])) return list.replaced(work, at, pair[0]);
                // (('iadd', ('iadd(is_used_once)', 'a(is_not_const)',
                // 'b(is_not_const)'), '#c'), ('iadd', ('iadd', a, c), b))
                // (:2423).
                for (pairs) |pair| {
                    const inner = work.steps[pair[0]];
                    if (!isIntegerOp(inner, .iadd) or !isConstantStep(work, pair[1])) continue;
                    if (isConstantStep(work, inner.a) or isConstantStep(work, inner.b) or list.usesOf(work, pair[0]) != 1) continue;
                    const sum = try list.integerBefore(work, at, .iadd, inner.a, pair[1]);
                    return try list.rebuilt(work, at, integerStep(.iadd, each.kind, sum, inner.b));
                }
                // (('iadd', '#a', ('iadd', b, '#c')), ('iadd', ('iadd', a,
                // c), b)) (:2438).
                for (pairs) |pair| {
                    const inner = work.steps[pair[1]];
                    if (!isConstantStep(work, pair[0]) or !isIntegerOp(inner, .iadd)) continue;
                    for ([2][2]u16{ .{ inner.a, inner.b }, .{ inner.b, inner.a } }) |in| {
                        if (!isConstantStep(work, in[1])) continue;
                        const sum = try list.integerBefore(work, at, .iadd, pair[0], in[1]);
                        return try list.rebuilt(work, at, integerStep(.iadd, each.kind, sum, in[0]));
                    }
                }
            },
            // (('ishl', ('iadd', a, '#b'), '#c'), ('iadd', ('ishl', a, c),
            // ('ishl', b, c))) (:729); (('ishl', ('iadd(is_used_once)',
            // ('iadd', a, '#b'), c), '#d'), ('iadd', ('ishl', ('iadd', a,
            // c), d), ('ishl', b, d))) (:730-731), which takes the
            // ishl twin of :739 (:741-742) as well.
            // Then (('ishl', a, 0), a) (:1800).
            .ishl => if (isConstantStep(work, each.b)) {
                if (try list.distributed(work, at, .ishl, each.a, each.b, false)) |left| return left;
                if (isZero(work, each.b)) return list.replaced(work, at, each.a);
            },
            .imul => for (pairs) |pair| {
                const by = pair[1];
                if (!isConstantStep(work, by)) continue;
                // (('imul', a, '#b(is_pos_power_of_two)'), ('ishl', a,
                // ('find_lsb', b))) (:183), and of 0x80000000 a shift by
                // 31 (:188), v3dv's options not lowering bit operations
                // (v3dv_pipeline_get_nir_options, v3dv_pipeline.c:164-
                // 222); a one is 1 << 0, and
                // (('ishl', a, 0), a) takes that out a round on.
                if (allWords(work, by, isPositivePowerOfTwo) or allWords(work, by, isSignBit)) {
                    const shift = try list.mappedBefore(work, at, by, lowestBit);
                    return try list.rebuilt(work, at, integerStep(.ishl, each.kind, pair[0], shift));
                }
                // (('imul', a, '#b(is_neg_power_of_two)'), ('ineg',
                // ('ishl', a, ('find_lsb', ('iabs', b)))))) (:190), which
                // a minus one is as well.
                if (allWords(work, by, isNegativePowerOfTwo)) {
                    const shift = try list.mappedBefore(work, at, by, lowestBit);
                    const shifted = try list.before(work, at, integerStep(.ishl, each.kind, pair[0], shift));
                    return try list.rebuilt(work, at, integerStep(.ineg, each.kind, shifted, 0));
                }
                // (('imul', a, 0), 0) (:287).
                if (isZero(work, by)) return list.replaced(work, at, by);
                // (('imul', ('iadd(is_used_once)', a, '#b'), '#c'),
                // ('iadd', ('imul', a, c), ('imul', b, c))) (:736);
                // (('imul', ('iadd(is_used_once)', ('iadd(is_used_once)',
                // a, '#b'), c), '#d'), ('iadd', ('imul', ('iadd', a, c),
                // d), ('imul', b, d))) (:739-740).
                if (try list.distributed(work, at, .imul, pair[0], by, true)) |left| return left;
            },
            else => {},
        }
        return null;
    }

    /// `op` of `sum`, an iadd of `a` and a constant `b` or of such and
    /// `c`, by the constant `by`: `op` of `a` (plus `c`) by it, plus `op`
    /// of `b` by it. `once` holds the iadd of `a` and `b` to being read
    /// once, as the imul rule does and the ishl rule does not; the outer
    /// iadd of the second is held to it in both.
    fn distributed(list: *Order, work: *Work, at: u16, op: Integer, sum: u16, by: u16, once: bool) Error!?u16 {
        const kind = work.steps[at].kind;
        const outer = work.steps[sum];
        if (!isIntegerOp(outer, .iadd)) return null;
        const outer_pairs = [2][2]u16{ .{ outer.a, outer.b }, .{ outer.b, outer.a } };
        if (!once or list.usesOf(work, sum) == 1) for (outer_pairs) |pair| {
            if (!isConstantStep(work, pair[1])) continue;
            const left = try list.integerBefore(work, at, op, pair[0], by);
            const right = try list.integerBefore(work, at, op, pair[1], by);
            return try list.rebuilt(work, at, integerStep(.iadd, kind, left, right));
        };
        if (list.usesOf(work, sum) != 1) return null;
        for (outer_pairs) |pair| {
            const inner = work.steps[pair[0]];
            if (!isIntegerOp(inner, .iadd)) continue;
            if (once and list.usesOf(work, pair[0]) != 1) continue;
            for ([2][2]u16{ .{ inner.a, inner.b }, .{ inner.b, inner.a } }) |in| {
                if (!isConstantStep(work, in[1])) continue;
                const both = try list.integerBefore(work, at, .iadd, in[0], pair[1]);
                const left = try list.integerBefore(work, at, op, both, by);
                const right = try list.integerBefore(work, at, op, in[1], by);
                return try list.rebuilt(work, at, integerStep(.iadd, kind, left, right));
            }
        }
        return null;
    }

    /// A bcsel of 1.0 and 0.0, the b2f of its bool; of 0.0 and 1.0, the
    /// b2f of the inot; of -1.0 and -0.0, and of -0.0 and -1.0, the fneg
    /// of those (nir_opt_algebraic.py:2075-2083), each constant matched by
    /// its value and a zero by its sign too (match_value, nir_search.c:
    /// 278-290; since 1.178). Not ported: the four that want the bcsel
    /// used as nothing but a float (`is_only_used_as_float_nsz`,
    /// :2084-2087).
    fn boolFloatRule(list: *Order, work: *Work, at: u16, condition: u16, yes: u16, no: u16) Error!?u16 {
        const plus_one: u32 = @bitCast(@as(f32, 1.0));
        const minus_one: u32 = @bitCast(@as(f32, -1.0));
        const minus_zero: u32 = @bitCast(@as(f32, -0.0));
        const left = floatBits(work, partOf(work, yes, 0)) orelse return null;
        const right = floatBits(work, partOf(work, no, 0)) orelse return null;
        const straight = (left == plus_one and right == 0) or (left == minus_one and right == minus_zero);
        const turned = (left == 0 and right == plus_one) or (left == minus_zero and right == minus_one);
        if (!straight and !turned) return null;
        const of = if (turned) try list.before(work, at, logicOf(.inot, condition, 0)) else condition;
        const made = integerStep(.b2f32, .f32x1, of, 0);
        if (left != minus_one and right != minus_one) return try list.rebuilt(work, at, made);
        const float = try list.before(work, at, made);
        return try list.rebuilt(work, at, .{ .tag = .negate, .kind = .f32x1, .a = float });
    }

    /// The rule's last new step put before `at`, and `at` out.
    fn rebuilt(list: *Order, work: *Work, at: u16, last: Step) Error!u16 {
        return list.replaced(work, at, try list.before(work, at, last));
    }

    /// What read `at` reads `to`, and `at` is out.
    fn replaced(list: *Order, work: *Work, at: u16, to: u16) u16 {
        replaceUses(work, at, to);
        list.removed[at] = true;
        return to;
    }

    /// The steps laid out in the program's list again, those out of it
    /// dropped, and what names a step renamed. What nir_opt_dce took out
    /// is dropped too, but for a varying, which `to_vir` reads where the
    /// program does (since 1.167): v3d's own dead code elimination keeps
    /// a TMU operation (vir_has_side_effects, vir_opt_dead_code.c:207), so
    /// a sample or a load that nothing reads would cost the TMU a lookup
    /// that NIR's never made. A sample dropped leaves no sampler, and the
    /// samples are counted again, the first of them `sampled`.
    fn layOut(list: *const Order, work: *Work) void {
        var renamed: [most_steps]u16 = @splat(none);
        var kept: [most_steps]Step = undefined;
        var count: u16 = 0;
        var at = list.first;
        while (at != none) : (at = list.next[at]) {
            if (list.removed[at]) continue;
            if (list.gone[at] and work.steps[at].tag != .input) continue;
            renamed[at] = count;
            kept[count] = work.steps[at];
            count += 1;
        }
        for (kept[0..count]) |*each| renameReads(each, &renamed);
        @memcpy(work.steps[0..count], kept[0..count]);
        work.step_count = count;
        if (work.stored != none) work.stored = renamed[work.stored];
        work.sampled = none;
        work.sample_count = 0;
        for (work.steps[0..count], 0..) |each, place| {
            if (each.tag != .sample and each.tag != .sample_compared) continue;
            if (work.sampled == none) work.sampled = @intCast(place);
            work.sample_count += 1;
        }
        for (work.inputs[0..work.input_count]) |*each| {
            if (each.step != none) each.step = renamed[each.step];
        }
        // A `.system` step dropped is a value the program does not read
        // (since 1.192).
        for (&work.system_step) |*each| {
            if (each.* != none) each.* = renamed[each.*];
        }
        for (&work.system_value) |*each| {
            if (each.* != none) each.* = renamed[each.*];
        }
        for (&work.step_of) |*each| {
            if (each.* != none) each.* = renamed[each.*];
        }
    }
};

fn integerStep(op: Integer, kind: Kind, a: u16, b: u16) Step {
    return .{ .tag = .integer, .kind = kind, .a = a, .b = b, .at = @intFromEnum(op) };
}

fn isIntegerOp(each: Step, op: Integer) bool {
    return each.tag == .integer and each.at == @intFromEnum(op);
}

fn isConstantStep(work: *const Work, at: u16) bool {
    return work.steps[at].tag == .constant;
}

/// Whether `f` holds of every word of the constant `at`.
fn allWords(work: *const Work, at: u16, comptime f: fn (u32) bool) bool {
    const each = work.steps[at];
    for (work.pool[each.at..][0..each.kind.parts()]) |word| if (!f(@bitCast(word))) return false;
    return true;
}

/// Whether every float of `at` is a constant `f` holds of, named through
/// the components and constructs that name it: a load_const, or a vec of
/// them, which nir_opt_constant_folding makes one (since 1.174).
fn allConstant(work: *const Work, at: u16, comptime f: fn (u32) bool) bool {
    for (0..work.steps[at].kind.parts()) |k| {
        const word = floatBits(work, partOf(work, at, @intCast(k))) orelse return false;
        if (!f(word)) return false;
    }
    return true;
}

fn isSignedZero(word: u32) bool {
    return word & 0x7FFF_FFFF == 0;
}

fn isFloatOne(word: u32) bool {
    return word == @as(u32, @bitCast(@as(f32, 1)));
}

fn isFloatMinusOne(word: u32) bool {
    return word == @as(u32, @bitCast(@as(f32, -1)));
}

/// is_pos_power_of_two (nir_search_helpers.h:38-66), of imul's integer
/// operands: a power of two above nothing.
fn isPositivePowerOfTwo(word: u32) bool {
    const value: i32 = @bitCast(word);
    return value > 0 and std.math.isPowerOfTwo(word);
}

/// is_neg_power_of_two: minus a power of two, but not the least integer,
/// whose minus is itself.
fn isNegativePowerOfTwo(word: u32) bool {
    const value: i32 = @bitCast(word);
    return value < 0 and word != 0x8000_0000 and std.math.isPowerOfTwo(0 -% word);
}

fn isSignBit(word: u32) bool {
    return word == 0x8000_0000;
}

/// find_lsb, of a power of two or of minus one: the iabs of a negative
/// one has its lowest bit where the one itself does.
fn lowestBit(word: u32) u32 {
    return @ctz(word);
}

/// Whether `at` is a constant of zeros.
fn isZero(work: *const Work, at: u16) bool {
    const each = work.steps[at];
    if (each.tag != .constant) return false;
    for (work.pool[each.at..][0..each.kind.parts()]) |word| if (@as(u32, @bitCast(word)) != 0) return false;
    return true;
}

fn selectOf(condition: u16, yes: u16, no: u16) Step {
    var made = Step{ .tag = .select, .kind = .f32x1, .a = condition, .b = yes };
    made.from[0] = no;
    return made;
}

fn compareOf(which: Comparison, a: u16, b: u16) Step {
    return .{ .tag = .compare, .kind = .f32x1, .a = a, .b = b, .at = @intFromEnum(which) };
}

fn logicOf(which: Logic, a: u16, b: u16) Step {
    return .{ .tag = .logic, .kind = .f32x1, .a = a, .b = b, .at = @intFromEnum(which) };
}

/// Whether two steps name the same float, through the components and
/// constructs that only name it: one SSA value in NIR, which a rule's
/// variable matches twice.
/// An operand of an fadd: an fsub's second is its fneg (since 1.175).
const Addend = struct { at: u16, turned: bool = false };

/// The two an fadd adds, or an fsub, as the fadd of the fneg
/// nir_opt_algebraic lowers it to (:2401).
fn addendsOf(work: *const Work, at: u16) ?[2]Addend {
    const each = work.steps[at];
    return switch (each.tag) {
        .add => .{ .{ .at = each.a }, .{ .at = each.b } },
        .sub => .{ .{ .at = each.a }, .{ .at = each.b, .turned = true } },
        else => null,
    };
}

/// Whether `of` is the fneg of the value `at`: an fneg step of it, or an
/// fsub's second that is it.
fn sameNegated(work: *const Work, of: Addend, at: u16) bool {
    if (of.turned) return sameValue(work, of.at, at);
    const turned = work.steps[of.at];
    return turned.tag == .negate and sameValue(work, turned.a, at);
}

/// The float `k` of an operand of an operation float by float: of a
/// scalar, its one (since 1.174).
fn operandPart(work: *const Work, at: u16, k: u8) Float {
    return partOf(work, at, if (work.steps[at].kind == .f32x1) 0 else k);
}

/// Whether `x` is a float of an fneg of `y` (since 1.174).
fn negates(work: *const Work, x: Float, y: Float) bool {
    const turned = work.steps[x.step];
    return turned.tag == .negate and sameFloats(partOf(work, turned.a, x.part), y);
}

/// Whether `x` is the fneg of `y`, float for float (since 1.174).
fn negatesValue(work: *const Work, x: u16, y: u16) bool {
    const kind = work.steps[x].kind;
    if (kind != work.steps[y].kind) return false;
    for (0..kind.parts()) |k| if (!negates(work, partOf(work, x, @intCast(k)), partOf(work, y, @intCast(k)))) return false;
    return true;
}

fn isZeroBits(bits: ?u32) bool {
    return if (bits) |word| isSignedZero(word) else false;
}

/// A zero, a one or a minus one: a factor an fmul rule takes.
fn isFactorBits(bits: ?u32) bool {
    const word = bits orelse return false;
    return isSignedZero(word) or isFloatOne(word) or isFloatMinusOne(word);
}

/// Whether a rule of `Order.floatRule` rewrites the float `k` of the
/// vector operation `each`, taken alone (since 1.174).
fn floatFolds(work: *const Work, each: Step, k: u8) bool {
    const a = operandPart(work, each.a, k);
    if (each.tag == .negate or each.tag == .abs) return work.steps[a.step].tag == .negate;
    const b = operandPart(work, each.b, k);
    const left = floatBits(work, a);
    const right = floatBits(work, b);
    return switch (each.tag) {
        .add => isZeroBits(left) or isZeroBits(right) or sameFloats(a, b) or work.steps[a.step].tag == .negate or work.steps[b.step].tag == .negate,
        .sub => isZeroBits(left) or isZeroBits(right) or sameFloats(a, b) or work.steps[b.step].tag == .negate,
        .mul => isFactorBits(left) or isFactorBits(right),
        else => false,
    };
}

/// Whether two steps are the same value, float for float: what NIR's
/// one SSA value is, a match of `a` twice in a rule (since 1.174).
fn sameValue(work: *const Work, a: u16, b: u16) bool {
    const kind = work.steps[a].kind;
    if (kind != work.steps[b].kind) return false;
    for (0..kind.parts()) |k| {
        if (!oneFloat(work, partOf(work, a, @intCast(k)), partOf(work, b, @intCast(k)))) return false;
    }
    return true;
}

fn sameFloat(work: *const Work, a: u16, b: u16) bool {
    return oneFloat(work, partOf(work, a, 0), partOf(work, b, 0));
}

/// Whether two floats are one SSA value: the same float of one step, or
/// two constants of the same bits, which nir_lower_load_const_to_scalar
/// has made load_consts of one float each (v3dv_pipeline.c:427) and
/// nir_opt_cse then makes one, as it makes one of a vector's floats and
/// another's (since 1.178).
fn oneFloat(work: *const Work, left: Float, right: Float) bool {
    if (left.step == right.step and left.part == right.part) return true;
    const x = floatBits(work, left) orelse return false;
    return floatBits(work, right) == x;
}

/// Whether a step is an ALU instruction in NIR, which nir_opt_algebraic
/// and nir_opt_cse look at, or a load_ubo, which nir_opt_cse takes as it
/// takes one (CAN_REORDER, nir_intrinsics.py:1367; since 1.160). A
/// component and a construct only name floats.
fn computes(tag: Tag) bool {
    return switch (tag) {
        .input, .constant, .push, .component, .construct, .discard, .output, .viewport, .system, .ssbo_store, .ssbo_atomic, .barrier, .begin_if, .begin_else, .end_if, .phi, .scratch, .scratch_indirect, .scratch_store => false,
        else => true,
    };
}

/// Whether two steps compute the same: one operation, its own operand,
/// and the same floats, an add's, a mul's, an iand's, an ior's and an
/// feq's or fneu's in either order (NIR_OP_IS_2SRC_COMMUTATIVE). Every
/// float of an operand is the same, and so is its width: until 1.175 the
/// first float alone was held to, so `y * x.x` was taken for `x * y`.
fn equalSteps(work: *const Work, a: Step, b: Step) bool {
    // A constant's words are in the pool, where `at` says (since 1.166).
    if (a.tag == .constant and b.tag == .constant) {
        if (a.kind != b.kind) return false;
        for (0..a.kind.parts()) |k| {
            if (@as(u32, @bitCast(work.pool[a.at + k])) != @as(u32, @bitCast(work.pool[b.at + k]))) return false;
        }
        return true;
    }
    if (a.tag != b.tag or a.kind != b.kind or a.at != b.at) return false;
    if (!sameLookup(a, b)) return false;
    // A load_ssbo of memory the program may write is no CAN_REORDER,
    // which nir_opt_access gives only memory it may not
    // (nir_opt_access.c:289-290), so nir_opt_cse leaves it be (since
    // 1.168).
    if ((a.tag == .ssbo or a.tag == .ssbo_indirect) and work.buffers_written and !(a.non_writeable and b.non_writeable)) return false;
    // A load_ubo's buffer is its `b`, which is no step, and a
    // load_ssbo's, which CAN_REORDER lets nir_opt_cse take as well
    // (nir_instr_set.c; since 1.164).
    if (a.tag == .ubo or a.tag == .ssbo) return a.b == b.b;
    // Its offset too, which is a step (since 1.166).
    if (a.tag == .ubo_indirect or a.tag == .ssbo_indirect) return a.b == b.b and sameFloat(work, a.a, b.a);
    const left = readsOf(a);
    const right = readsOf(b);
    var straight = true;
    for (left, right) |x, y| {
        if ((x == null) != (y == null)) return false;
        if (x) |operand_at| if (!sameValue(work, operand_at, y.?)) {
            straight = false;
        };
    }
    if (straight) return true;
    return commutes(a) and sameValue(work, a.a, b.b) and sameValue(work, a.b, b.a);
}

/// Whether two steps of one tag and unit look the same up, where they are
/// samples: nir_instrs_equal's tex has one op - tex, txb, txl or txf -
/// and one texel offset, which pack_tex and the sources hold
/// (nir_instr_set.c:297-327, :695-723), besides the sources `readsOf`
/// gives. Two variables at one binding are two units here until `Units`
/// makes them one, after the passes, and their samples are not merged,
/// where v3dv's lowering of the derefs to one index before v3d's
/// nir_opt_cse would merge them: not ported (since 1.185).
fn sameLookup(a: Step, b: Step) bool {
    if (a.tag != .sample and a.tag != .sample_compared) return true;
    return a.lookup == b.lookup and std.mem.eql(i8, &a.offsets, &b.offsets);
}

/// Whether a step's two operands may be either way about
/// (NIR_OP_IS_2SRC_COMMUTATIVE).
fn commutes(each: Step) bool {
    return switch (each.tag) {
        .add, .mul, .min, .max => true,
        .logic => each.at != @intFromEnum(Logic.inot),
        .compare => switch (@as(Comparison, @enumFromInt(each.at))) {
            .equal, .not_equal, .int_equal, .int_not_equal => true,
            else => false,
        },
        .integer => @as(Integer, @enumFromInt(each.at)).commutes(),
        else => false,
    };
}

/// What a step reads, field by field.
fn readsOf(each: Step) [4]?u16 {
    return switch (each.tag) {
        .input, .constant, .push, .ubo, .ssbo, .viewport, .system, .begin_else, .end_if, .scratch => .{ null, null, null, null },
        // A phi reads its two floats where each way ends, which is where
        // nir_convert_from_ssa copies them (since 1.171); the condition
        // is the begin_if's.
        .phi => .{ each.a, each.b, null, null },
        .begin_if => .{ each.a, null, null, null },
        .construct => .{
            each.from[0],
            if (each.kind.parts() > 1) each.from[1] else null,
            if (each.kind.parts() > 2) each.from[2] else null,
            if (each.kind.parts() > 3) each.from[3] else null,
        },
        .select => .{ each.a, each.b, each.from[0], null },
        .logic => .{ each.a, if (each.at != @intFromEnum(Logic.inot)) each.b else null, null, null },
        .integer => .{ each.a, if (!@as(Integer, @enumFromInt(each.at)).unary()) each.b else null, null, null },
        .component, .discard, .negate, .abs, .sat, .sin, .cos, .sign, .floor, .ceil, .trunc, .round, .recip, .rsqrt, .exp2, .log2, .output, .round_to_int, .ubo_indirect, .ssbo_indirect, .scratch_indirect => .{ each.a, null, null, null },
        .compare, .set_less, .add, .mul, .sub, .min, .max => .{ each.a, each.b, null, null },
        // A sample's bias or level too (since 1.180).
        .sample => .{ each.a, null, if (each.lookup != .implicit) each.from[0] else null, null },
        .sample_compared => .{ each.a, each.b, if (each.lookup != .implicit) each.from[0] else null, null },
        // A size's level (since 1.181).
        .texture_size => .{ each.from[0], null, null, null },
        .texture_levels => .{ null, null, null, null },
        .ssbo_store, .scratch_store => .{ each.a, if (each.from[0] != none) each.from[0] else null, null, null },
        .ssbo_atomic => .{ each.a, if (each.from[0] != none) each.from[0] else null, if (each.from[1] != none) each.from[1] else null, null },
        .barrier => .{ null, null, null, null },
    };
}

/// The steps a step reads, for the back end (since 1.171).
pub fn readsOfStep(each: Step) [4]?u16 {
    return readsOf(each);
}

/// Whether the step `earlier` is there wherever the later step `at` is:
/// it is in no arm of a kept selection, or in the arm `at` is in (since
/// 1.171).
fn dominates(work: *const Work, earlier: u16, at: u16) bool {
    return work.region[earlier] == 0 or work.region[earlier] == work.region[at];
}

/// What of `each` read `from` reads `to`.
fn rereads(each: *Step, from: u16, to: u16) void {
    var renamed: [most_steps]u16 = undefined;
    for (&renamed, 0..) |*name, k| name.* = @intCast(k);
    renamed[from] = to;
    renameReads(each, &renamed);
}

/// A step's reads renamed.
fn renameReads(each: *Step, renamed: *const [most_steps]u16) void {
    const reads = readsOf(each.*);
    switch (each.tag) {
        .construct => for (each.from[0..each.kind.parts()]) |*of| {
            of.* = renamed[of.*];
        },
        .select => {
            each.a = renamed[each.a];
            each.b = renamed[each.b];
            each.from[0] = renamed[each.from[0]];
        },
        .phi => {
            each.a = renamed[each.a];
            each.b = renamed[each.b];
            each.from[0] = renamed[each.from[0]];
        },
        .ssbo_store, .ssbo_atomic, .scratch_store => {
            each.a = renamed[each.a];
            if (each.from[0] != none) each.from[0] = renamed[each.from[0]];
            if (each.tag == .ssbo_atomic and each.from[1] != none) each.from[1] = renamed[each.from[1]];
        },
        .sample, .sample_compared => {
            each.a = renamed[each.a];
            if (each.tag == .sample_compared) each.b = renamed[each.b];
            if (each.lookup != .implicit) each.from[0] = renamed[each.from[0]];
        },
        .texture_size => each.from[0] = renamed[each.from[0]],
        .texture_levels => {},
        else => {
            if (reads[0] != null) each.a = renamed[each.a];
            if (reads[1] != null) each.b = renamed[each.b];
        },
    }
}

/// How many times the steps after `at`, and the colour stored, read it.
fn usesOf(work: *const Work, at: u16) u32 {
    var count: u32 = if (work.stored == at) 1 else 0;
    for (work.steps[at + 1 .. work.step_count]) |user| {
        for (readsOf(user)) |field| if (field) |of| {
            if (of == at) count += 1;
        };
    }
    return count;
}

/// What read `from` reads `to`.
fn replaceUses(work: *Work, from: u16, to: u16) void {
    if (work.stored == from) work.stored = to;
    for (work.steps[0..work.step_count]) |*user| {
        switch (user.tag) {
            .input, .constant, .push, .ubo, .ssbo, .barrier, .scratch => {},
            .construct => for (user.from[0..user.kind.parts()]) |*of| {
                if (of.* == from) of.* = to;
            },
            .select => {
                if (user.a == from) user.a = to;
                if (user.b == from) user.b = to;
                if (user.from[0] == from) user.from[0] = to;
            },
            .ssbo_store, .ssbo_atomic, .scratch_store => {
                if (user.a == from) user.a = to;
                if (user.from[0] == from) user.from[0] = to;
                if (user.tag == .ssbo_atomic and user.from[1] == from) user.from[1] = to;
            },
            .sample, .sample_compared => {
                if (user.a == from) user.a = to;
                if (user.tag == .sample_compared and user.b == from) user.b = to;
                if (user.lookup != .implicit and user.from[0] == from) user.from[0] = to;
            },
            .texture_size => if (user.from[0] == from) {
                user.from[0] = to;
            },
            .texture_levels => {},
            else => {
                const reads = readsOf(user.*);
                if (reads[0] != null and user.a == from) user.a = to;
                if (reads[1] != null and user.b == from) user.b = to;
            },
        }
    }
}

/// A type id as a count of floats.
fn kindOf(work: *const Work, id: u16) Error!Kind {
    return switch (work.thing[id]) {
        // A 32-bit integer is a word as a float is (since 1.165).
        .float, .int => .f32x1,
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
    // Which of them are flat and which are without perspective, as
    // emit_fragment_varying sets the program's flags of them
    // (nir_to_vir.c:1103-1110; since 1.190).
    work.flat_floats = 0;
    work.noperspective_floats = 0;
    for (inputs) |each| {
        const floats: u8 = @intCast(((@as(u32, 1) << @intCast(each.kind.parts())) - 1) << @intCast(each.first));
        switch (each.interpolation) {
            .smooth => {},
            .flat => work.flat_floats |= floats,
            .noperspective => work.noperspective_floats |= floats,
        }
    }
}

/// One instruction of the body.
fn step(work: *Work, instruction: spirv.Instruction) Error!void {
    const operands = instruction.operands();
    switch (instruction.op) {
        .store => {
            if (operands.len < 2) return Error.Body;
            const into = try idOf(operands[0]);
            if (work.thing[into] == .local_part) {
                // One float of a variable of the function's own:
                // nir_lower_vars_to_ssa's nir_vector_insert into what it
                // held (rename_variables, nir_lower_vars_to_ssa.c:716-722).
                const value = try operand(work, operands[1], .f32x1);
                work.values[work.points[into]][work.chain_part[into]] = partOf(work, value, 0);
                touch(work, work.points[into]);
                return;
            }
            if (work.thing[into] == .local_aggregate) {
                // The whole of an array, a struct or a matrix of the
                // function's own (since 1.176).
                return storeAggregate(work, into, operands[1]);
            }
            if (work.thing[into] == .local_tree) {
                // Through an if-else tree (since 1.178).
                return storeTree(work, into, operands[1]);
            }
            if (work.thing[into] == .scratch_pointer) {
                // Into a variable in scratch, each float its own
                // store_scratch (since 1.177).
                return storeScratch(work, into, operands[1]);
            }
            if (isLocal(work, into)) {
                // The whole of one: what it holds is the value stored
                // (nir_lower_vars_to_ssa.c:723-733).
                const local = work.points[into];
                const kind = work.local_kind[local];
                const value = if (work.local_bool[local]) try boolOf(work, operands[1]) else try operand(work, operands[1], kind);
                for (0..kind.parts()) |k| work.values[local][k] = partOf(work, value, @intCast(k));
                touch(work, local);
                return;
            }
            if (work.thing[into] == .position_pointer) {
                // gl_Position: kept for the fixed-function outputs, as
                // v3d_nir_lower_vpm_output keeps state->pos and stores
                // nothing for it (v3d_nir_lower_io.c:146-153; since
                // 1.163).
                if (work.position != none) return Error.Outputs;
                work.position = try operand(work, operands[1], .f32x4);
                return;
            }
            if (work.thing[into] == .point_size_pointer) {
                // gl_PointSize, at least 1.0: nir_lower_point_size's fmax,
                // which v3d_nir_lower_vs_early runs where the program
                // writes it (vir.c:1110-1111, nir_lower_point_size.c), and
                // stored with the varyings, in the order of the stores
                // (since 1.193). Once, as gl_Position is.
                if (work.point_size != none) return Error.Outputs;
                work.point_size = try binary(work, .max, try operand(work, operands[1], .f32x1), try immediate(work, 1.0));
                work.point_size_order = work.varying_count;
                return;
            }
            if (work.stage == .vertex and work.thing[into] == .variable and work.class[into] == @intFromEnum(spirv.StorageClass.output)) {
                // A varying, stored where the program ends
                // (nir_move_output_stores_to_end), once: a second store
                // into one would want nir_opt_dead_write_vars.
                const kind = std.enums.fromInt(Kind, work.wide[into]) orelse return Error.Type;
                for (work.varying_into[0..work.varying_count]) |each| if (each == into) return Error.Outputs;
                if (work.varying_count == most_varyings) return Error.Outputs;
                work.varying_values[work.varying_count] = try operand(work, operands[1], kind);
                work.varying_into[work.varying_count] = into;
                work.varying_count += 1;
                return;
            }
            if (work.thing[into] == .member_pointer) {
                // Floats of a storage buffer, written where the chain
                // came to (since 1.168). A whole matrix is its columns,
                // each stored on its own, MatrixStride apart, as
                // _vtn_variable_load_store walks a matrix's for a store
                // as for a load (vtn_variables.c:763-780) and
                // nir_lower_explicit_io gives each its offset (since
                // 1.170). A whole array or struct is a value of many
                // kinds, which the walk holds none of, and is refused.
                const pointee = work.points[into];
                const base = work.chain_base[into];
                const offset: u32 = work.chain_offset[into];
                if (work.thing[pointee] == .matrix) {
                    const column = try kindOf(work, work.points[pointee]);
                    const whole = work.matrices[try matrixOf(work, operands[1])];
                    if (whole.count != work.wide[pointee]) return Error.Type;
                    for (whole.columns[0..whole.count], 0..) |each, c| {
                        if (work.steps[each].kind != column) return Error.Type;
                        try blockStore(work, base, work.chain_dynamic[into], offset + @as(u32, @intCast(c)) * work.chain_stride[into], work.non_writable[into], each, column);
                    }
                    return;
                }
                const kind = try kindOf(work, pointee);
                const value = try operand(work, operands[1], kind);
                try blockStore(work, base, work.chain_dynamic[into], offset, work.non_writable[into], value, kind);
                return;
            }
            if (into != work.output) return Error.Body;
            work.stored = try operand(work, operands[1], .f32x4);
        },
        // OpAtomicLoad and OpAtomicStore: a load_deref and a store_deref,
        // ACCESS_ATOMIC and COHERENT, which v3d reads and writes as any
        // load_ssbo and store_ssbo, between the barriers their semantics
        // ask for (vtn_handle_atomics, spirv_to_nir.c:4372-4396,
        // :4435-4477; since 1.169).
        .atomic_load => {
            if (operands.len != 5) return Error.Body;
            const id = try idOf(operands[1]);
            const from = try idOf(operands[2]);
            const pointee = try atomicPointee(work, from);
            if (try idOf(operands[0]) != pointee) return Error.Type;
            const barriers = try atomicBarriers(try uintOf(work, operands[4]));
            if (barriers.before) _ = try put(work, .{ .tag = .barrier, .kind = .f32x1 });
            work.step_of[id] = try blockLoad(work, work.chain_base[from], work.chain_dynamic[from], work.chain_offset[from], .f32x1, work.non_writable[from]);
            if (barriers.after) _ = try put(work, .{ .tag = .barrier, .kind = .f32x1 });
        },
        .atomic_store => {
            if (operands.len != 4) return Error.Body;
            const into = try idOf(operands[0]);
            _ = try atomicPointee(work, into);
            const barriers = try atomicBarriers(try uintOf(work, operands[2]));
            const value = try operand(work, operands[3], .f32x1);
            if (barriers.before) _ = try put(work, .{ .tag = .barrier, .kind = .f32x1 });
            try blockStore(work, work.chain_base[into], work.chain_dynamic[into], work.chain_offset[into], work.non_writable[into], value, .f32x1);
            if (barriers.after) _ = try put(work, .{ .tag = .barrier, .kind = .f32x1 });
        },
        .atomic_exchange, .atomic_compare_exchange, .atomic_compare_exchange_weak, .atomic_i_increment, .atomic_i_decrement, .atomic_i_add, .atomic_i_sub, .atomic_s_min, .atomic_u_min, .atomic_s_max, .atomic_u_max, .atomic_and, .atomic_or, .atomic_xor => try atomicOf(work, instruction.op, operands),
        // OpMemoryBarrier: NIR's barrier where vtn_emit_memory_barrier
        // makes one (spirv_to_nir.c:4814-4818; since 1.169).
        .memory_barrier => {
            if (operands.len != 2) return Error.Body;
            _ = try uintOf(work, operands[0]);
            if (try memoryBarrier(try uintOf(work, operands[1]))) _ = try put(work, .{ .tag = .barrier, .kind = .f32x1 });
        },
        .load => {
            if (operands.len < 3) return Error.Body;
            const id = try idOf(operands[1]);
            const from = try idOf(operands[2]);
            if (work.thing[from] == .member_pointer) {
                // Floats of a block, at the offset the chain came to. A
                // whole matrix is its columns, each loaded on its own,
                // MatrixStride apart, as _vtn_variable_load_store walks a
                // matrix's (vtn_variables.c:763-780) and
                // nir_lower_explicit_io gives each its offset (since
                // 1.161). A whole array or struct would be a value of
                // many kinds, and is refused.
                const pointee = work.points[from];
                if (try idOf(operands[0]) != pointee) return Error.Type;
                const base = work.chain_base[from];
                const offset: u32 = work.chain_offset[from];
                const dynamic = work.chain_dynamic[from];
                if (work.thing[pointee] == .matrix) {
                    const column = try kindOf(work, work.points[pointee]);
                    var made = Matrix{ .count = work.wide[pointee] };
                    for (0..made.count) |c| {
                        made.columns[c] = try blockLoad(work, base, dynamic, offset + @as(u32, @intCast(c)) * work.chain_stride[from], column, work.non_writable[from]);
                    }
                    try holdMatrix(work, id, made);
                    return;
                }
                work.step_of[id] = try blockLoad(work, base, dynamic, offset, try kindOf(work, pointee), work.non_writable[from]);
                return;
            }
            if (work.thing[from] == .scratch_pointer) {
                // What a variable in scratch holds where the chain came
                // to, each float its own load_scratch (since 1.177).
                if (try idOf(operands[0]) != work.points[from]) return Error.Type;
                return loadScratch(work, id, from);
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
            if (work.thing[from] == .local_tree) {
                // Through an if-else tree (since 1.178).
                return loadTree(work, id, from, try idOf(operands[0]));
            }
            if (work.thing[from] == .local_part) {
                // One float of a variable of the function's own: what it
                // holds, nir_vector_extract of the value
                // (nir_lower_vars_to_ssa.c:676-687; since 1.155).
                if (try kindOf(work, try idOf(operands[0])) != .f32x1) return Error.Type;
                const holds = try heldOf(work, work.values[work.points[from]][work.chain_part[from]]);
                work.step_of[id] = try floatOf(work, holds);
                touch(work, work.points[from]);
                return;
            }
            if (work.thing[from] == .local_aggregate) {
                // The whole of an array, a struct or a matrix of the
                // function's own: each of its floats and vectors loaded in
                // order, as _vtn_variable_load_store loads an aggregate
                // element by element (vtn_variables.c:763-781), each what
                // its variable holds (since 1.176).
                // One of bools would be a value of steps of no float,
                // which an aggregate's are, and is refused.
                const type_id = work.aggregate[from];
                if (try idOf(operands[0]) != type_id) return Error.Type;
                var made: [most_locals]u16 = undefined;
                const count = try leafCount(work, type_id);
                for (made[0..count], 0..) |*each, k| {
                    const local: u16 = @intCast(work.points[from] + k);
                    if (work.local_bool[local]) return Error.Storage;
                    each.* = try localOf(work, local);
                    touch(work, local);
                }
                return holdAggregate(work, id, type_id, made[0..count]);
            }
            if (isLocal(work, from)) {
                // The whole of one, nir_phi_builder_value_get_block_def's
                // value where the walk has got to
                // (nir_lower_vars_to_ssa.c:633-689).
                const local = work.points[from];
                if (work.local_bool[local]) {
                    // A bool's value is the step that made it, or a
                    // select of such at a merge; one stored nowhere would
                    // be an undef, which nothing here is made of.
                    if (work.thing[try idOf(operands[0])] != .boolean) return Error.Type;
                    const value = work.values[local][0];
                    if (value.step == none) return Error.Body;
                    work.step_of[id] = value.step;
                    touch(work, local);
                    return;
                }
                if (try kindOf(work, try idOf(operands[0])) != work.local_kind[local]) return Error.Type;
                work.step_of[id] = try localOf(work, local);
                touch(work, local);
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
            if (systemOf(work, from)) |which| {
                if (try kindOf(work, try idOf(operands[0])) != .f32x1) return Error.Type;
                work.step_of[id] = try systemValueOf(work, which);
                return;
            }
            work.step_of[id] = try inputStep(work, work.points[from]);
        },
        .access_chain => {
            // ResultType, Result, Base, then the indexes, each a
            // constant: a member of the push constants or of a uniform
            // buffer, through its structs, arrays and matrices to a float
            // (since 1.161). An index computed in the body would want the
            // offset computed too (ntq_emit_load_unifa's dynamic_src,
            // nir_to_vir.c:3349), which is not here.
            if (operands.len < 4) return Error.Body;
            const type_id = try idOf(operands[0]);
            const id = try idOf(operands[1]);
            const base = try idOf(operands[2]);
            if (base == work.per_vertex) {
                // gl_PerVertex's gl_Position (since 1.163) and gl_PointSize
                // (since 1.193), the members a program here may store. The
                // clip and cull distances would want nir_lower_clip_vs.
                if (operands.len != 4) return Error.Outputs;
                const which = try indexOf(work, operands[3]);
                const block = &work.blocks[work.points[base]];
                if (which >= block.member_count) return Error.Outputs;
                const builtin = block.member_builtin[which];
                if (builtin != @intFromEnum(spirv.BuiltIn.position) and builtin != @intFromEnum(spirv.BuiltIn.point_size)) return Error.Outputs;
                const position = builtin == @intFromEnum(spirv.BuiltIn.position);
                const wanted: Kind = if (position) .f32x4 else .f32x1;
                if (work.thing[type_id] != .pointer or work.points[type_id] != block.member_type[which]) return Error.Type;
                if (try kindOf(work, block.member_type[which]) != wanted) return Error.Type;
                work.thing[id] = if (position) .position_pointer else .point_size_pointer;
                return;
            }
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
            if (work.thing[base] == .local_aggregate or work.thing[base] == .local_tree) {
                // An element, a member or a column of an array, a struct
                // or a matrix of the function's own, through as many as
                // the indexes say: the variable nir_split_struct_vars or
                // nir_split_array_vars made of a float or a vector, or of
                // an aggregate the next chain or a load goes on from, or
                // one float of a vector as below (since 1.176). A member's
                // index is a constant, as SPIR-V has it; an element's or a
                // column's may be a value the walk folded to one
                // (`localIndexOf`).
                // Or one the body computes. Where those from the variable
                // on count two or fewer elements and columns together,
                // nir_lower_indirect_derefs_to_if_else_trees makes an
                // if-else tree of each load and store through the chain,
                // one into an array or a matrix of two its two arms
                // (`local_tree`) and one into one of a single element
                // that element (v3dv_pipeline.c:435-436,
                // nir_lower_indirect_derefs_to_if_else_trees.c:35-66,
                // :138-153; since 1.178). Where they count more, the
                // variable goes into scratch (since 1.177).
                if (work.thing[type_id] != .pointer) return Error.Type;
                if (work.class[type_id] != @intFromEnum(spirv.StorageClass.function)) return Error.Body;
                const tree = work.thing[base] == .local_tree;
                var leaf = work.points[base];
                var at = work.aggregate[base];
                var index_step: u16 = if (tree) work.tree_index[base] else none;
                var apart: u16 = if (tree) work.tree_apart[base] else 0;
                const indexes = operands[3..];
                const elements = (if (tree) @as(u32, 2) else 1) *| try computedElements(work, at, indexes);
                if (elements > 2) return wantScratch(work, work.chain_base[base]);
                for (indexes, 0..) |each, k| {
                    if (work.thing[at] == .vector) {
                        if (k != indexes.len - 1) return Error.Body;
                        const which = try indexOf(work, each);
                        if (which >= work.wide[at]) return Error.Body;
                        if (try kindOf(work, work.points[type_id]) != .f32x1) return Error.Type;
                        work.points[id] = leaf;
                        work.chain_part[id] = @intCast(which);
                        if (index_step != none) {
                            holdTree(work, id, base, at, index_step, apart);
                            return;
                        }
                        work.thing[id] = .local_part;
                        return;
                    }
                    const computed = work.thing[at] != .plain_struct and try localIndexOrNull(work, each) == null;
                    if (computed and elementsOf(work, at) == 2) {
                        index_step = try operand(work, each, .f32x1);
                        apart = (try within(work, at, 1)).leaf;
                    }
                    const index = if (work.thing[at] == .plain_struct) try indexOf(work, each) else if (computed) 0 else try localIndexOf(work, each);
                    const next = try within(work, at, index);
                    leaf += next.leaf;
                    at = next.type_id;
                }
                if (work.points[type_id] != at) return Error.Type;
                if (index_step != none) {
                    work.points[id] = leaf;
                    work.chain_part[id] = Work.whole;
                    holdTree(work, id, base, at, index_step, apart);
                    return;
                }
                switch (work.thing[at]) {
                    .float, .int, .vector, .boolean => {
                        work.thing[id] = .variable;
                        work.class[id] = work.class[type_id];
                        work.points[id] = leaf;
                        work.wide[id] = @intCast(work.local_kind[leaf].parts());
                    },
                    else => {
                        work.thing[id] = .local_aggregate;
                        work.class[id] = work.class[type_id];
                        work.points[id] = leaf;
                        work.aggregate[id] = at;
                        work.chain_base[id] = work.chain_base[base];
                    },
                }
                return;
            }
            if (work.thing[base] == .scratch_pointer) {
                // Into a variable in scratch memory: the byte offset of
                // what the chain comes to, as nir_build_deref_offset adds
                // it up for nir_lower_vars_to_scratch (nir_deref.c:
                // 346-380, nir_lower_scratch.c:39-41) in the natural
                // layout (`scratchFloats`): an element or a column its
                // floats times four on from the one before, a float of a
                // vector four bytes, and a member after the floats of
                // those before it. An index the body computes is a step
                // of the offset, the index times the stride as
                // nir_amul_imm makes it (`strideTimes`), the constant ones
                // added up apart from it, as the UBO's chains keep them
                // (since 1.177).
                if (work.thing[type_id] != .pointer) return Error.Type;
                if (work.class[type_id] != @intFromEnum(spirv.StorageClass.function)) return Error.Body;
                var at = work.points[base];
                var offset: u32 = work.chain_offset[base];
                var dynamic = work.chain_dynamic[base];
                var path = work.pointer_paths[work.chain_path[base]];
                var elements: u32 = work.chain_elements[base];
                for (operands[3..]) |each| {
                    const index = try localIndexOrNull(work, each);
                    var apart: u32 = 4;
                    var count: u32 = 0;
                    var next: u16 = undefined;
                    switch (work.thing[at]) {
                        .array, .matrix => {
                            next = work.points[at];
                            apart = 4 * try scratchFloats(work, next);
                            count = if (work.thing[at] == .array) work.length[at] else work.wide[at];
                        },
                        .vector => {
                            next = work.points[at];
                            count = work.wide[at];
                        },
                        .plain_struct => {
                            const which = index orelse return Error.Body;
                            const members = structMembers(work, at);
                            if (which >= members.len) return Error.Body;
                            for (members[0..which]) |member| offset += 4 * try scratchFloats(work, member);
                            try path.push(@intCast(which), false);
                            at = members[which];
                            continue;
                        },
                        else => return Error.Body,
                    }
                    at = next;
                    if (index) |which| {
                        if (which >= count) return Error.Body;
                        offset += which * apart;
                        try path.push(@intCast(which), false);
                        continue;
                    }
                    const computed = try operand(work, each, .f32x1);
                    try path.push(computed, true);
                    elements *|= count;
                    const term = try strideTimes(work, computed, apart);
                    dynamic = if (dynamic != none) try integerOf(work, .iadd, dynamic, term) else term;
                }
                if (work.points[type_id] != at) return Error.Type;
                if (offset >= most_scratch) return Error.Storage;
                work.thing[id] = .scratch_pointer;
                work.class[id] = work.class[type_id];
                work.points[id] = at;
                work.chain_base[id] = work.chain_base[base];
                work.chain_offset[id] = @intCast(offset);
                work.chain_dynamic[id] = dynamic;
                work.chain_elements[id] = @intCast(@min(elements, std.math.maxInt(u16)));
                work.chain_path[id] = try pointerPath(work, path);
                return;
            }
            if (isLocal(work, base)) {
                // One float of a vector of the function's own, at a
                // constant index, as glslc without -O writes `c.r = x`: a
                // pointer to it, which a store replaces and a load reads
                // (deref_vec_component, nir_lower_vars_to_ssa.c:586-602;
                // since 1.155).
                if (operands.len != 4) return Error.Body;
                const which = try indexOf(work, operands[3]);
                if (work.wide[base] == 1 or which >= work.wide[base]) return Error.Body;
                if (work.thing[type_id] != .pointer) return Error.Type;
                if (work.class[type_id] != @intFromEnum(spirv.StorageClass.function)) return Error.Body;
                if (try kindOf(work, work.points[type_id]) != .f32x1) return Error.Type;
                work.thing[id] = .local_part;
                work.points[id] = work.points[base];
                work.chain_part[id] = @intCast(which);
                return;
            }
            // A member of the push constants, or of a uniform buffer
            // (since 1.160), or of one of those a chain named already
            // (since 1.161): the byte offset vtn's explicit layout gives
            // it, which is the constant nir_lower_explicit_io's
            // arithmetic folds to (vtn_pointer_dereference,
            // vtn_variables.c). A member adds its Offset and an element
            // its ArrayStride times the index; a matrix's column adds its
            // MatrixStride, and a vector's float four bytes.
            //
            // An index of an element, a column or a float may be no
            // constant (since 1.166): from it on the offset is a step,
            // nir_lower_explicit_io's sum of each deref's offset and its
            // parent's (nir_explicit_io_address_from_deref,
            // nir_lower_explicit_io.c:1288-1302), the element's the index
            // times its stride as nir_amul_imm makes it (:1240-1252,
            // `strideTimes`). Those sums of constants come to the constant
            // nir_opt_constant_folding makes of them, and an add of none
            // is not made, as (('iadd', a, 0), a) (nir_opt_algebraic.py:
            // 239) takes it out. The push constants' words are uniforms,
            // which an index computed would read from v3dv's buffer of
            // them, which is not here: refused.
            var variable: u16 = base;
            var offset: u32 = 0;
            var dynamic: u16 = none;
            var pointee: u16 = none;
            var stride: u16 = none;
            // The variable's NonWritable, or the chain's it goes on from,
            // and every member's it goes through (since 1.168).
            var non_writable = work.non_writable[base];
            if (work.thing[base] == .member_pointer) {
                variable = work.chain_base[base];
                offset = work.chain_offset[base];
                dynamic = work.chain_dynamic[base];
                pointee = work.points[base];
                stride = work.chain_stride[base];
            } else if (base == work.push_variable or (work.thing[base] == .variable and work.class[base] == @intFromEnum(spirv.StorageClass.uniform))) {
                pointee = blockOfVariable(work, base).type_id;
            } else return Error.Storage;
            for (operands[3..]) |each| {
                // An index no constant: its step, and the bytes the
                // elements, columns or floats it counts are apart.
                var computed: u16 = none;
                var apart: u32 = 0;
                const index: u32 = if (work.thing[try idOf(each)] == .int_constant) try indexOf(work, each) else at: {
                    if (variable == work.push_variable) return Error.Storage;
                    computed = try operand(work, each, .f32x1);
                    break :at 0;
                };
                // What a constant index adds.
                var adds: u32 = 0;
                switch (work.thing[pointee]) {
                    .structure => {
                        if (computed != none) return Error.Body;
                        const block = findBlock(work, pointee) orelse return Error.Body;
                        if (index >= block.member_count) return Error.Body;
                        if (block.member_non_writable[index]) non_writable = true;
                        adds = block.member_offset[index];
                        stride = block.member_stride[index];
                        pointee = block.member_type[index];
                    },
                    .array => {
                        // A runtime array's elements are all the draw's
                        // to have bound (since 1.164), and an index
                        // computed is the program's to keep among them.
                        if (!isRuntime(work, pointee) and index >= work.length[pointee]) return Error.Body;
                        apart = work.array_stride[pointee];
                        if (computed != none and apart == none) return Error.Storage;
                        adds = index * apart;
                        pointee = work.points[pointee];
                    },
                    .matrix => {
                        if (index >= work.wide[pointee] or stride == none) return Error.Body;
                        apart = stride;
                        adds = index * apart;
                        pointee = work.points[pointee];
                        stride = none;
                    },
                    .vector => {
                        if (index >= work.wide[pointee]) return Error.Body;
                        apart = 4;
                        adds = 4 * index;
                        pointee = work.points[pointee];
                    },
                    else => return Error.Body,
                }
                if (computed == none and dynamic == none) {
                    offset = std.math.add(u32, offset, adds) catch return Error.Storage;
                    continue;
                }
                if (offset >= none or adds >= none) return Error.Storage;
                // A constant of none adds nothing, nor does an index
                // times a stride of none.
                const term = if (computed == none)
                    (if (adds != 0) try integerSplat(work, .f32x1, @intCast(adds)) else continue)
                else if (apart != 0)
                    try strideTimes(work, computed, apart)
                else
                    continue;
                dynamic = if (dynamic != none)
                    try integerOf(work, .iadd, dynamic, term)
                else if (offset != 0)
                    try integerOf(work, .iadd, try integerSplat(work, .f32x1, @intCast(offset)), term)
                else
                    term;
                offset = 0;
            }
            if (offset >= none) return Error.Storage;
            // A pointer of the block's class to what it names.
            if (work.thing[type_id] != .pointer) return Error.Type;
            if (work.class[type_id] != work.class[variable]) return Error.Body;
            if (work.points[type_id] != pointee) return Error.Type;
            work.thing[id] = .member_pointer;
            work.points[id] = pointee;
            work.chain_base[id] = variable;
            work.chain_offset[id] = @intCast(offset);
            work.chain_stride[id] = stride;
            work.chain_dynamic[id] = dynamic;
            work.non_writable[id] = non_writable;
            if (variable != work.push_variable and work.ubos[work.points[variable]].storage) work.uses_ssbo = true;
        },
        .composite_extract => {
            if (operands.len < 4) return Error.Body;
            const id = try idOf(operands[1]);
            const composite = try idOf(operands[2]);
            if (work.thing[composite] == .aggregate_value or work.thing[composite] == .constant_aggregate) {
                // An element or a member of an array or a struct, through
                // as many as the indexes say, as vtn_composite_extract
                // walks `elems` (spirv_to_nir.c:4655-4686): its floats
                // and vectors among the aggregate's, a matrix of its
                // columns, or one float of a vector of them (since 1.176).
                const constant = work.thing[composite] == .constant_aggregate;
                var leaf = work.points[composite];
                var at = work.aggregate[composite];
                const indexes = operands[3..];
                for (indexes, 0..) |index, k| {
                    if (work.thing[at] == .vector) {
                        if (k != indexes.len - 1 or index >= work.wide[at]) return Error.Body;
                        if (try kindOf(work, try idOf(operands[0])) != .f32x1) return Error.Type;
                        const of = if (constant) try operand(work, work.leaves[leaf], try kindOf(work, at)) else work.leaves[leaf];
                        work.step_of[id] = try put(work, .{ .tag = .component, .kind = .f32x1, .a = of, .at = index });
                        return;
                    }
                    const next = try within(work, at, index);
                    leaf += next.leaf;
                    at = next.type_id;
                }
                if (try idOf(operands[0]) != at) return Error.Type;
                var kinds: [most_locals]Leaf = undefined;
                const count = try leafKinds(work, at, &kinds);
                switch (work.thing[at]) {
                    .float, .int, .vector => work.step_of[id] = if (constant) try operand(work, work.leaves[leaf], kinds[0].kind) else work.leaves[leaf],
                    .matrix => {
                        var whole = Matrix{ .count = @intCast(count) };
                        for (whole.columns[0..count], 0..) |*column, c| {
                            column.* = if (constant) try operand(work, work.leaves[leaf + c], kinds[c].kind) else work.leaves[leaf + c];
                        }
                        try holdMatrix(work, id, whole);
                    },
                    .array, .plain_struct => {
                        work.thing[id] = work.thing[composite];
                        work.points[id] = leaf;
                        work.aggregate[id] = at;
                    },
                    else => return Error.Type,
                }
                return;
            }
            if (work.thing[composite] == .constant_matrix) _ = try matrixOf(work, operands[2]);
            if (work.thing[composite] == .matrix_value) {
                // A matrix's column, or one float of it: the column's
                // step, and the float of that as of any vector
                // (vtn_composite_extract, then vtn_vector_extract;
                // since 1.161).
                if (operands.len > 5) return Error.Body;
                const whole = work.matrices[work.points[composite]];
                if (operands[3] >= whole.count) return Error.Body;
                const column = whole.columns[operands[3]];
                if (operands.len == 4) {
                    if (try kindOf(work, try idOf(operands[0])) != work.steps[column].kind) return Error.Type;
                    work.step_of[id] = column;
                    return;
                }
                if (try kindOf(work, try idOf(operands[0])) != .f32x1) return Error.Type;
                if (operands[4] >= work.steps[column].kind.parts()) return Error.Body;
                work.step_of[id] = try put(work, .{ .tag = .component, .kind = .f32x1, .a = column, .at = operands[4] });
                return;
            }
            if (operands.len != 4) return Error.Body;
            const of = work.step_of[composite];
            if (of == none) return Error.Body;
            if (isBool(work, of)) return Error.Type;
            if (operands[3] >= work.steps[of].kind.parts()) return Error.Body;
            work.step_of[id] = try put(work, .{ .tag = .component, .kind = .f32x1, .a = of, .at = operands[3] });
        },
        .composite_insert => {
            // ResultType, Result, Object, Composite, one index: the
            // vector with that float replaced, nir_vector_insert_imm's
            // vecN of the others and the one (vtn_composite_insert,
            // spirv_to_nir.c:4612-4650).
            if (operands.len >= 5) {
                const into = try idOf(operands[3]);
                switch (work.thing[into]) {
                    // Into an array, a struct or a matrix: a copy of it
                    // with an element, a member, a column or a float
                    // replaced (since 1.176).
                    .aggregate_value, .constant_aggregate, .matrix_value, .constant_matrix => return insertAggregate(work, operands),
                    else => {},
                }
            }
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
            if (work.thing[type_id] == .array or work.thing[type_id] == .plain_struct) {
                // An array or a struct of its elements or members, the
                // vtn_ssa_value of `elems` vtn makes of them
                // (vtn_handle_composite, spirv_to_nir.c:4744-4756): the
                // floats and vectors of each, in order (since 1.176).
                const parts = operands[2..];
                if (isRuntime(work, type_id) or parts.len != memberCount(work, type_id)) return Error.Body;
                var made: [most_locals]u16 = undefined;
                var count: usize = 0;
                for (parts, 0..) |each, k| count += try leafSteps(work, each, memberType(work, type_id, k), made[count..]);
                if (count != try leafCount(work, type_id)) return Error.Type;
                return holdAggregate(work, id, type_id, made[0..count]);
            }
            if (work.thing[type_id] == .matrix) {
                // A matrix of its columns, each a vector of its rows: the
                // vtn_ssa_value of `elems` vtn makes of them
                // (vtn_handle_composite, spirv_to_nir.c; since 1.161).
                const columns = operands[2..];
                if (columns.len != work.wide[type_id]) return Error.Body;
                const rows = try kindOf(work, work.points[type_id]);
                var made = Matrix{ .count = @intCast(columns.len) };
                for (columns, 0..) |each, c| made.columns[c] = try operand(work, each, rows);
                try holdMatrix(work, id, made);
                return;
            }
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
                if (isBool(work, of)) return Error.Type;
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
        .f_unord_less_than, .f_unord_greater_than, .f_unord_less_than_equal, .f_unord_greater_than_equal => {
            // FUnordLessThan(a, b) is !FOrdGreaterThanEqual(a, b), and so
            // on: the inot of the ordered comparison that is its opposite
            // (vtn_alu.c:953-985), NaN or not (since 1.157).
            if (operands.len != 4) return Error.Body;
            const type_id = try idOf(operands[0]);
            const id = try idOf(operands[1]);
            if (work.thing[type_id] != .boolean) return Error.Type;
            const a = try operand(work, operands[2], .f32x1);
            const b = try operand(work, operands[3], .f32x1);
            const opposite: Comparison = switch (instruction.op) {
                .f_unord_less_than => .greater_equal,
                .f_unord_greater_than => .less_equal,
                .f_unord_less_than_equal => .greater,
                else => .less,
            };
            const compared = try put(work, .{ .tag = .compare, .kind = .f32x1, .a = a, .b = b, .at = @intFromEnum(opposite) });
            work.step_of[id] = try put(work, .{ .tag = .logic, .kind = .f32x1, .a = compared, .at = @intFromEnum(Logic.inot) });
        },
        .logical_and, .logical_or, .logical_not => {
            // ResultType, Result, one bool or two: NIR's iand, ior and
            // inot (vtn_alu.c:316-320; since 1.157).
            const not = instruction.op == .logical_not;
            if (operands.len != @as(usize, if (not) 3 else 4)) return Error.Body;
            if (work.thing[try idOf(operands[0])] != .boolean) return Error.Type;
            const id = try idOf(operands[1]);
            const a = try boolOf(work, operands[2]);
            const b = if (not) 0 else try boolOf(work, operands[3]);
            const which: Logic = switch (instruction.op) {
                .logical_and => .iand,
                .logical_or => .ior,
                else => .inot,
            };
            work.step_of[id] = try put(work, .{ .tag = .logic, .kind = .f32x1, .a = a, .b = b, .at = @intFromEnum(which) });
        },
        .select => {
            // ResultType, Result, Condition, Object 1, Object 2: NIR's
            // bcsel. Of one float, its condition one bool; a vector
            // chosen wants a vector of bools in SPIR-V 1.0, which nothing
            // here makes (since 1.153).
            if (operands.len != 5) return Error.Body;
            const type_id = try idOf(operands[0]);
            const id = try idOf(operands[1]);
            const condition = work.step_of[try idOf(operands[2])];
            if (condition == none or !isBool(work, condition)) return Error.Type;
            // One of two bools, a bcsel of them (since 1.157).
            const boolean = work.thing[type_id] == .boolean;
            if (!boolean and try kindOf(work, type_id) != .f32x1) return Error.Type;
            const yes = if (boolean) try boolOf(work, operands[3]) else try operand(work, operands[3], .f32x1);
            const no = if (boolean) try boolOf(work, operands[4]) else try operand(work, operands[4], .f32x1);
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
        .i_add, .i_sub, .i_mul, .shift_left_logical, .shift_right_logical, .shift_right_arithmetic, .bitwise_and, .bitwise_or, .bitwise_xor => {
            // ResultType, Result, two integers or vectors of them, NIR's
            // iadd, isub, imul, ishl, ushr, ishr, iand, ior and ixor
            // (vtn_nir_alu_op_for_spirv_opcode, vtn_alu.c:290-316). A
            // shift's amount is already 32 bits here, so vtn's u2u32 of it
            // (vtn_alu.c:1031-1059) is nothing (since 1.165).
            if (operands.len != 4) return Error.Body;
            const type_id = try idOf(operands[0]);
            if (!isIntegerType(work, type_id)) return Error.Type;
            const kind = try kindOf(work, type_id);
            const id = try idOf(operands[1]);
            const a = try operand(work, operands[2], kind);
            const b = try operand(work, operands[3], kind);
            const op: Integer = switch (instruction.op) {
                .i_add => .iadd,
                .i_sub => .isub,
                .i_mul => .imul,
                .shift_left_logical => .ishl,
                .shift_right_logical => .ushr,
                .shift_right_arithmetic => .ishr,
                .bitwise_and => .iand,
                .bitwise_or => .ior,
                else => .ixor,
            };
            work.step_of[id] = try integerOf(work, op, a, b);
        },
        .u_div, .s_div, .u_mod, .s_rem, .s_mod => {
            // ResultType, Result, two integers or vectors of them: vtn's
            // udiv, idiv, umod, irem and imod (vtn_alu.c:304-310), each
            // float an instruction of its own once nir_lower_alu_to_scalar
            // has run (v3dv_pipeline.c:404), which nir_lower_idiv lowers
            // (vir.c:2019-2022; `dividedOf`; since 1.187). A float whose
            // divisor is a constant is nir_opt_algebraic's and
            // nir_opt_idiv_const's first (`constantDividedOf`; since
            // 1.188).
            if (operands.len != 4) return Error.Body;
            const type_id = try idOf(operands[0]);
            if (!isIntegerType(work, type_id)) return Error.Type;
            const kind = try kindOf(work, type_id);
            const id = try idOf(operands[1]);
            const a = try operand(work, operands[2], kind);
            const b = try operand(work, operands[3], kind);
            const op: Division = switch (instruction.op) {
                .u_div => .udiv,
                .s_div => .idiv,
                .u_mod => .umod,
                .s_rem => .irem,
                else => .imod,
            };
            var words: ?DivisionWords = null;
            var made = Step{ .tag = .construct, .kind = kind };
            for (0..kind.parts()) |k| {
                const numer = try floatStep(work, partOf(work, a, @intCast(k)));
                const divisor = partOf(work, b, @intCast(k));
                if (floatBits(work, divisor)) |d| {
                    made.from[k] = try constantDividedOf(work, op, numer, d);
                    continue;
                }
                if (words == null) words = try DivisionWords.of(work, op);
                made.from[k] = try dividedOf(work, op, numer, try floatStep(work, divisor), words.?);
            }
            work.step_of[id] = if (kind == .f32x1) made.from[0] else try put(work, made);
        },
        .s_negate, .not => {
            if (operands.len != 3) return Error.Body;
            const type_id = try idOf(operands[0]);
            if (!isIntegerType(work, type_id)) return Error.Type;
            const id = try idOf(operands[1]);
            const a = try operand(work, operands[2], try kindOf(work, type_id));
            work.step_of[id] = try integerOf(work, if (instruction.op == .s_negate) .ineg else .inot, a, null);
        },
        .convert_f_to_s, .convert_f_to_u, .convert_s_to_f, .convert_u_to_f => {
            // f2i32, f2u32, i2f32 and u2f32 (vtn_handle_convert,
            // vtn_alu.c:240-275), of 32 bits each way (since 1.165).
            if (operands.len != 3) return Error.Body;
            const type_id = try idOf(operands[0]);
            const to_integer = instruction.op == .convert_f_to_s or instruction.op == .convert_f_to_u;
            if (isIntegerType(work, type_id) != to_integer) return Error.Type;
            const kind = try kindOf(work, type_id);
            const id = try idOf(operands[1]);
            const a = try operand(work, operands[2], kind);
            const op: Integer = switch (instruction.op) {
                .convert_f_to_s => .f2i32,
                .convert_f_to_u => .f2u32,
                .convert_s_to_f => .i2f32,
                else => .u2f32,
            };
            work.step_of[id] = try integerOf(work, op, a, null);
        },
        .bitcast => {
            // The same words read as another type's, NIR's mov of them:
            // nothing to emit, as many words either way (since 1.165).
            if (operands.len != 3) return Error.Body;
            const kind = try kindOf(work, try idOf(operands[0]));
            const id = try idOf(operands[1]);
            work.step_of[id] = try operand(work, operands[2], kind);
        },
        .i_equal, .i_not_equal, .s_less_than, .s_greater_than, .s_less_than_equal, .s_greater_than_equal, .u_less_than, .u_greater_than, .u_less_than_equal, .u_greater_than_equal => {
            // Two integers, and a bool: ieq, ine, ilt, ige, ult and uge,
            // the two swapped for the four NIR has no comparison of
            // (vtn_alu.c:388-396; since 1.165).
            if (operands.len != 4) return Error.Body;
            if (work.thing[try idOf(operands[0])] != .boolean) return Error.Type;
            const id = try idOf(operands[1]);
            const x = try operand(work, operands[2], .f32x1);
            const y = try operand(work, operands[3], .f32x1);
            const swap = switch (instruction.op) {
                .s_greater_than, .s_less_than_equal, .u_greater_than, .u_less_than_equal => true,
                else => false,
            };
            const which: Comparison = switch (instruction.op) {
                .i_equal => .int_equal,
                .i_not_equal => .int_not_equal,
                .s_less_than, .s_greater_than => .int_less,
                .s_less_than_equal, .s_greater_than_equal => .int_greater_equal,
                .u_less_than, .u_greater_than => .uint_less,
                else => .uint_greater_equal,
            };
            work.step_of[id] = try put(work, .{ .tag = .compare, .kind = .f32x1, .a = if (swap) y else x, .b = if (swap) x else y, .at = @intFromEnum(which) });
        },
        .logical_equal, .logical_not_equal => {
            // Two bools compared, ieq and ine of them (vtn_alu.c:317-318),
            // which nir_lower_bool_to_int32 makes of their 0 and ~0
            // (since 1.165).
            if (operands.len != 4) return Error.Body;
            if (work.thing[try idOf(operands[0])] != .boolean) return Error.Type;
            const id = try idOf(operands[1]);
            const a = try boolOf(work, operands[2]);
            const b = try boolOf(work, operands[3]);
            const which: Comparison = if (instruction.op == .logical_equal) .int_equal else .int_not_equal;
            work.step_of[id] = try put(work, .{ .tag = .compare, .kind = .f32x1, .a = a, .b = b, .at = @intFromEnum(which) });
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
        .image_sample_implicit_lod, .image_sample_explicit_lod, .image_sample_dref_implicit_lod, .image_sample_dref_explicit_lod, .image_fetch => try readSample(work, instruction.op, operands),
        .image => {
            // ResultType, Result, SampledImage: the image of a sampled
            // image, which vtn reads as the same texture deref
            // (vtn_handle_texture, spirv_to_nir.c:2996-3004), and so the
            // same unit here. Nothing to compute (since 1.181).
            if (operands.len != 3) return Error.Body;
            const id = try idOf(operands[1]);
            const which = work.sampler_of[try idOf(operands[2])];
            if (which == none) return Error.Body;
            work.sampler_of[id] = which;
        },
        .image_query_size_lod => {
            // ResultType, Result, Image, Level of Detail: vtn's txs with
            // its lod source (spirv_to_nir.c:3384-3386), as many integers
            // as nir_tex_instr_dest_size gives the image (nir.c): two for
            // a 2D image and a cube, three for a 3D one and a 2D array,
            // the array's layers last (since 1.181).
            if (operands.len != 4) return Error.Body;
            const type_id = try idOf(operands[0]);
            if (!isIntegerType(work, type_id)) return Error.Type;
            const id = try idOf(operands[1]);
            const which = work.sampler_of[try idOf(operands[2])];
            if (which == none) return Error.Body;
            const kind = try kindOf(work, type_id);
            const sizes: u32 = switch (work.samplers[which].dim) {
                .flat, .cube => 2,
                .layers, .volume => 3,
            };
            if (kind.parts() != sizes) return Error.Type;
            const level = try operand(work, operands[3], .f32x1);
            work.step_of[id] = try put(work, .{ .tag = .texture_size, .kind = kind, .at = which, .from = .{ level, 0, 0, 0 } });
        },
        .image_query_levels => {
            // ResultType, Result, Image: vtn's query_levels, one integer
            // (spirv_to_nir.c:3119-3135; since 1.181).
            if (operands.len != 3) return Error.Body;
            const type_id = try idOf(operands[0]);
            if (!isIntegerType(work, type_id) or try kindOf(work, type_id) != .f32x1) return Error.Type;
            const id = try idOf(operands[1]);
            const which = work.sampler_of[try idOf(operands[2])];
            if (which == none) return Error.Body;
            work.step_of[id] = try put(work, .{ .tag = .texture_levels, .kind = .f32x1, .at = which });
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
        .transpose, .matrix_times_scalar, .matrix_times_vector, .vector_times_matrix, .matrix_times_matrix, .outer_product => {
            // vtn_handle_matrix_alu's matrix opcodes (vtn_alu.c:182-237)
            // and OpOuterProduct (:817-823), on matrices held as their
            // columns (since 1.161). The ones it takes for matrices that
            // SPIR-V gives scalars and vectors alone - FNegate, FAdd and
            // FSub - spirv-val refuses, and so does this.
            const binary_op = instruction.op != .transpose;
            if (operands.len != @as(usize, if (binary_op) 4 else 3)) return Error.Body;
            const type_id = try idOf(operands[0]);
            const id = try idOf(operands[1]);
            switch (instruction.op) {
                .transpose => {
                    const of = try matrixOf(work, operands[2]);
                    try holdShaped(work, id, type_id, work.matrices[try transposeOf(work, of)]);
                },
                .matrix_times_scalar => {
                    const of = try matrixOf(work, operands[2]);
                    const scalar = try operand(work, operands[3], .f32x1);
                    const scaled = work.matrices[of];
                    // Of a transpose, the transpose of the original
                    // times it, which keeps its `transposed` (:216-223).
                    const made = if (scaled.transposed != none)
                        work.matrices[try transposeOf(work, try keptMatrix(work, try timesScalar(work, work.matrices[scaled.transposed], scalar)))]
                    else
                        try timesScalar(work, scaled, scalar);
                    try holdShaped(work, id, type_id, made);
                },
                .matrix_times_vector, .matrix_times_matrix => {
                    const left = work.matrices[try matrixOf(work, operands[2])];
                    const right = if (instruction.op == .matrix_times_matrix)
                        work.matrices[try matrixOf(work, operands[3])]
                    else
                        try wrapped(work, operands[3]);
                    try holdProduct(work, id, type_id, try multiplied(work, left, right));
                },
                .vector_times_matrix => {
                    // matrix_multiply(transpose(M), v) (:225-233).
                    const of = try matrixOf(work, operands[3]);
                    const vector = try wrapped(work, operands[2]);
                    try holdProduct(work, id, type_id, try multiplied(work, work.matrices[try transposeOf(work, of)], vector));
                },
                .outer_product => {
                    // A column for each float of the second: the first
                    // times it.
                    const first = try operand(work, operands[2], try kindOfValue(work, operands[2]));
                    const second = try operand(work, operands[3], try kindOfValue(work, operands[3]));
                    var made = Matrix{ .count = @intCast(work.steps[second].kind.parts()) };
                    for (0..made.count) |i| made.columns[i] = try binary(work, .mul, first, try channelOf(work, second, @intCast(i)));
                    try holdShaped(work, id, type_id, made);
                },
                else => unreachable,
            }
        },
        else => return Error.Refused,
    }
}

/// A block's floats at `offset`, a load of `variable`'s: a load_ubo of the
/// descriptor map's slot and the offset for a uniform buffer, as vtn and
/// nir_lower_explicit_io make it in v3dv's 32bit_index_offset format
/// (v3dv_pipeline.c:415-425; since 1.160), and the push constants' word
/// for them, which Mesa reads as QUNIFORM_UNIFORM at the word the offset
/// names (ntq_emit_load_uniform, nir_to_vir.c:2880, after v3dv's
/// lower_load_push_constant, v3dv_pipeline.c:571). Two loads of one
/// member are two steps, and the second costs no word of the stream:
/// vir_uniform finds it there already (vir_get_uniform_index,
/// vir.c:2771). A storage buffer's is a load_ssbo, which the same pass
/// makes in the same format (v3dv_pipeline.c:418-420; since 1.164).
fn blockLoad(work: *Work, variable: u16, dynamic: u16, offset: u32, kind: Kind, non_writable: bool) Error!u16 {
    if (offset >= none) return Error.Storage;
    if (variable != work.push_variable) {
        const slot = work.points[variable];
        const storage = work.ubos[slot].storage;
        if (dynamic != none) {
            // At an offset computed: a column past a matrix's first adds
            // its own to it, as the deref of it does (since 1.166).
            const at = if (offset == 0) dynamic else try integerOf(work, .iadd, dynamic, try integerSplat(work, .f32x1, @intCast(offset)));
            return put(work, .{ .tag = if (storage) .ssbo_indirect else .ubo_indirect, .kind = kind, .a = at, .b = slot, .non_writeable = storage and non_writable });
        }
        return put(work, .{ .tag = if (storage) .ssbo else .ubo, .kind = kind, .b = slot, .at = offset, .non_writeable = storage and non_writable });
    }
    if (dynamic != none) return Error.Storage;
    return put(work, .{ .tag = .push, .kind = kind, .at = offset / 4 });
}

/// A store_ssbo of `value` at `offset` into `variable`'s buffer, or at the
/// offset `dynamic` computes, as vtn and nir_lower_explicit_io make it in
/// v3dv's 32bit_index_offset format, the same as a load's
/// (v3dv_pipeline.c:415-425; since 1.168). The push constants and a
/// uniform buffer are not the program's to write, nor is what is
/// NonWritable. A vertex program's is refused: v3dv runs it twice, as
/// the coordinate program too.
fn blockStore(work: *Work, variable: u16, dynamic: u16, offset: u32, non_writable: bool, value: u16, kind: Kind) Error!void {
    if (offset >= none or variable == work.push_variable) return Error.Storage;
    const slot = work.points[variable];
    if (!work.ubos[slot].storage or non_writable) return Error.Storage;
    if (work.stage != .fragment) return Error.Storage;
    const at = if (dynamic == none or offset == 0) dynamic else try integerOf(work, .iadd, dynamic, try integerSplat(work, .f32x1, @intCast(offset)));
    work.buffers_written = true;
    _ = try put(work, .{ .tag = .ssbo_store, .kind = kind, .a = value, .b = slot, .at = if (dynamic == none) offset else 0, .from = .{ at, 0, 0, 0 } });
}

/// The word an atomic's pointer names: a 32-bit integer of a storage
/// buffer, where an access chain came to (since 1.169).
fn atomicPointee(work: *const Work, pointer: u16) Error!u16 {
    if (work.thing[pointer] != .member_pointer) return Error.Storage;
    const pointee = work.points[pointer];
    if (work.thing[pointee] != .int) return Error.Type;
    return pointee;
}

/// An integer atomic of a storage buffer, as vtn_handle_atomics makes it
/// (spirv_to_nir.c:4288-4480): the operation translate_atomic_op names,
/// its operands as fill_common_atomic_sources gives them (:3678-3722) -
/// IIncrement and IDecrement an immediate 1 and -1, ISub its value
/// negated, and CompareExchange its Comparator before its Value - and
/// the barriers its semantics ask for, with the storage buffer's own
/// UniformMemory added (:4447-4477). Then the ssbo_atomic of the buffer
/// nir_lower_explicit_io makes of it, at the offset a load's would be
/// (since 1.169).
fn atomicOf(work: *Work, op: spirv.Op, operands: []const u32) Error!void {
    const swap = op == .atomic_compare_exchange or op == .atomic_compare_exchange_weak;
    const takes: usize = switch (op) {
        .atomic_i_increment, .atomic_i_decrement => 5,
        .atomic_compare_exchange, .atomic_compare_exchange_weak => 8,
        else => 6,
    };
    if (operands.len != takes) return Error.Body;
    const id = try idOf(operands[1]);
    const into = try idOf(operands[2]);
    const pointee = try atomicPointee(work, into);
    if (try idOf(operands[0]) != pointee) return Error.Type;
    _ = try uintOf(work, operands[3]);
    // CompareExchange's Unequal semantics are not read (:4318-4321).
    const barriers = try atomicBarriers(try uintOf(work, operands[4]));
    const atomic: Atomic = switch (op) {
        .atomic_i_increment, .atomic_i_decrement, .atomic_i_add, .atomic_i_sub => .iadd,
        .atomic_s_min => .imin,
        .atomic_u_min => .umin,
        .atomic_s_max => .imax,
        .atomic_u_max => .umax,
        .atomic_and => .iand,
        .atomic_or => .ior,
        .atomic_xor => .ixor,
        .atomic_exchange => .xchg,
        else => .cmpxchg,
    };
    const first: u16 = switch (op) {
        .atomic_i_increment => try integerSplat(work, .f32x1, 1),
        .atomic_i_decrement => try integerSplat(work, .f32x1, -1),
        .atomic_i_sub => try integerOf(work, .ineg, try operand(work, operands[5], .f32x1), null),
        .atomic_compare_exchange, .atomic_compare_exchange_weak => try operand(work, operands[7], .f32x1),
        else => try operand(work, operands[5], .f32x1),
    };
    const second: u16 = if (swap) try operand(work, operands[6], .f32x1) else none;
    if (barriers.before) _ = try put(work, .{ .tag = .barrier, .kind = .f32x1 });
    work.step_of[id] = try blockAtomic(work, work.chain_base[into], work.chain_dynamic[into], work.chain_offset[into], work.non_writable[into], atomic, first, second);
    if (barriers.after) _ = try put(work, .{ .tag = .barrier, .kind = .f32x1 });
}

/// An ssbo_atomic on the word at `offset` of `variable`'s buffer, or at
/// the offset `dynamic` computes, held to what `blockStore` holds a store
/// to (since 1.169).
fn blockAtomic(work: *Work, variable: u16, dynamic: u16, offset: u32, non_writable: bool, atomic: Atomic, first: u16, second: u16) Error!u16 {
    if (offset >= none or variable == work.push_variable) return Error.Storage;
    const slot = work.points[variable];
    if (!work.ubos[slot].storage or non_writable) return Error.Storage;
    if (work.stage != .fragment) return Error.Storage;
    const at = if (dynamic == none or offset == 0) dynamic else try integerOf(work, .iadd, dynamic, try integerSplat(work, .f32x1, @intCast(offset)));
    work.buffers_written = true;
    return put(work, .{ .tag = .ssbo_atomic, .kind = .f32x1, .a = first, .b = slot, .at = if (dynamic == none) offset else 0, .from = .{ at, second, 0, 0 }, .atomic = atomic });
}

/// SPIR-V's memory semantics, the bits vtn reads (spirv.h).
const Semantics = struct {
    const acquire: u32 = 0x2;
    const release: u32 = 0x4;
    const acquire_release: u32 = 0x8;
    const sequentially_consistent: u32 = 0x10;
    const uniform_memory: u32 = 0x40;
    const subgroup_memory: u32 = 0x80;
    const workgroup_memory: u32 = 0x100;
    const cross_workgroup_memory: u32 = 0x200;
    const atomic_counter_memory: u32 = 0x400;
    const image_memory: u32 = 0x800;
    const output_memory: u32 = 0x1000;
    const make_available: u32 = 0x2000;
    const make_visible: u32 = 0x4000;
    /// The orders: acquire, release, acquire_release and
    /// sequentially_consistent.
    const orders: u32 = 0x1e;
    /// The storage classes: uniform_memory up to output_memory.
    const storage: u32 = 0x1fc0;
};

/// Where an atomic of a storage buffer has a barrier: before it, of its
/// release, and after it, of its acquire, as vtn_split_barrier_semantics
/// splits its semantics with the buffer's UniformMemory added
/// (spirv_to_nir.c:2581-2661, :4447-4477), and vtn_emit_memory_barrier
/// makes one of each part that is any (:2847-2862). More than one order
/// is AcquireRelease (:2604-2613); SequentiallyConsistent is too
/// (:2635). MakeAvailable and MakeVisible want the VulkanMemoryModel
/// capability (:2710-2720), which the profile does not take.
fn atomicBarriers(given: u32) Error!struct { before: bool, after: bool } {
    const semantics = given | Semantics.uniform_memory;
    if (semantics & (Semantics.make_available | Semantics.make_visible) != 0) return Error.Body;
    var ordered = semantics & Semantics.orders;
    if (@popCount(ordered) > 1) ordered = Semantics.acquire_release;
    const storage = semantics & Semantics.storage;
    const before: u32 = if (ordered & (Semantics.release | Semantics.acquire_release | Semantics.sequentially_consistent) != 0) Semantics.release | storage else 0;
    const after: u32 = if (ordered & (Semantics.acquire | Semantics.acquire_release | Semantics.sequentially_consistent) != 0) Semantics.acquire | storage else 0;
    return .{ .before = before != 0 and try memoryBarrier(before), .after = after != 0 and try memoryBarrier(after) };
}

/// Whether vtn_emit_memory_barrier makes a barrier of `semantics`
/// (spirv_to_nir.c:2847-2862): its NIR semantics, of its order
/// (:2664-2700), and its modes, of its storage, Vulkan's ignoring
/// SubgroupMemory, CrossWorkgroupMemory and AtomicCounterMemory
/// (:2727-2768), both any after optimize_barrier (:2801-2811). v3d
/// flushes the TMU at each, whatever its modes (nir_to_vir.c:3857-3861).
fn memoryBarrier(semantics: u32) Error!bool {
    if (semantics & (Semantics.make_available | Semantics.make_visible) != 0) return Error.Body;
    const ordered = semantics & Semantics.orders != 0;
    const kept = semantics & ~(Semantics.subgroup_memory | Semantics.cross_workgroup_memory | Semantics.atomic_counter_memory);
    // No mode is shared alone with an order, which optimize_barrier
    // leaves as it is: only MakeAvailable and MakeVisible go.
    const modes = kept & (Semantics.uniform_memory | Semantics.image_memory | Semantics.workgroup_memory | Semantics.output_memory);
    return ordered and modes != 0;
}

/// A constant's 32-bit word, an integer's: a scope or memory semantics
/// (vtn_constant_uint; since 1.169).
fn uintOf(work: *const Work, word: u32) Error!u32 {
    const id = try idOf(word);
    if (work.thing[id] != .int_constant) return Error.Body;
    return @bitCast(work.pool[work.points[id]]);
}

/// Which steps differ from lane to lane, nir_divergence_analysis's
/// answer (v3d_attempt_compile runs it, vir.c:2105), and of a fragment
/// program's samples and loads that do, which helper pixels may skip,
/// nir_opt_load_skip_helpers's (vir.c:2107-2115; since 1.167).
///
/// A varying differs, a flat one too where v3dv's options do not say one
/// primitive fills a subgroup (v3dv_pipeline.c:217-218), and so does a
/// vertex program's attribute (load_interpolated_input, load_input;
/// nir_divergence_analysis.c:472-489, :932); an ALU operation (:139-160),
/// a sample (visit_tex, :1185) and a load at an offset computed
/// (:655-671) where an operand does. A constant, a push constant
/// (:888-900), the viewport and a load at a constant offset do not. v3d
/// reads a load at an offset that differs through the TMU
/// (ntq_emit_load_unifa, nir_to_vir.c:3315-3317, then
/// ntq_emit_tmu_general); one at an offset that does not, through unifa.
///
/// A step's helper pixels are wanted where it is read, step by step, into
/// what a sample's coordinate is - an implicit level of detail is worked
/// out across the quad (nir_opt_load_skip_helpers.c:151-157) - and into a
/// load's offset where the load is not one to skip, which only one that
/// differs is (no_add_divergence, :99-113, :222-232). A discard is
/// v3dv's demote_if (discard_is_demote, v3dv_pipeline.c:219), which wants
/// none (:28-70). A sample or a load that differs and is read into
/// nothing that wants them skips them: ACCESS_SKIP_HELPERS, or the
/// sample's skip_helpers (:258-275).
fn lanes(work: *Work) void {
    const steps = work.program();
    work.divergent = @splat(false);
    work.skip_helpers = @splat(false);
    for (steps, 0..) |each, at| {
        // An atomic's word differs too, whatever its operands
        // (nir_divergence_analysis.c:994-1010; since 1.169).
        // As does a load_scratch, whatever its offset (:989; since 1.177).
        if (each.tag == .input or each.tag == .ssbo_atomic or each.tag == .scratch or each.tag == .scratch_indirect) work.divergent[at] = true;
        for (readsOf(each)) |field| if (field) |of| {
            if (work.divergent[of]) work.divergent[at] = true;
        };
        // A phi of a selection whose condition differs differs
        // (visit_if_merge_phi, nir_divergence_analysis.c:1478-1500; since
        // 1.171).
        if (each.tag == .phi and work.divergent[each.from[0]]) work.divergent[at] = true;
    }
    if (work.stage != .fragment) return;
    var needs: [most_steps]bool = @splat(false);
    var at = steps.len;
    while (at > 0) {
        at -= 1;
        const each = steps[at];
        switch (each.tag) {
            // The coordinate of a sample whose level the quad's
            // derivatives give (nir_tex_instr_has_implicit_derivative,
            // nir_opt_load_skip_helpers.c:151-156); a bias, a level and
            // a reference need none (since 1.180).
            .sample, .sample_compared => if (each.lookup.derived()) {
                needs[each.a] = true;
            },
            .ubo_indirect, .ssbo_indirect, .scratch_indirect => if (!work.divergent[at]) {
                needs[each.a] = true;
            },
            else => {},
        }
        if (!needs[at]) continue;
        for (readsOf(each)) |field| if (field) |of| {
            needs[of] = true;
        };
    }
    for (steps, 0..) |each, k| switch (each.tag) {
        // v3d's callback lets a load_scratch skip them too
        // (intrinsic_try_skip_helpers, vir.c:1937-1951; since 1.177).
        .sample, .sample_compared, .ubo_indirect, .ssbo_indirect, .scratch, .scratch_indirect => work.skip_helpers[k] = work.divergent[k] and !needs[k],
        else => {},
    };
}

/// `index` times `stride`, as nir_amul_imm builds it (_nir_mul_imm,
/// nir_builder.h:1160-1182) where the shader has no amul, as v3d's has
/// not: the index itself of a stride of one, shifted of a power of two,
/// and multiplied of any other (since 1.166). A stride of 0 makes an
/// add of nothing, which the access chain does not make.
fn strideTimes(work: *Work, index: u16, stride: u32) Error!u16 {
    if (stride == 1) return index;
    if (std.math.isPowerOfTwo(stride)) return integerOf(work, .ishl, index, try integerSplat(work, .f32x1, std.math.log2_int(u32, stride)));
    return integerOf(work, .imul, index, try integerSplat(work, .f32x1, @intCast(stride)));
}

/// How many bytes a value of `type_id` takes in a block, a matrix's
/// columns `stride` apart: what vtn's explicit layout gives it, the last
/// column or element ending it (since 1.161). A matrix with no
/// MatrixStride and an array with no ArrayStride have no layout, and are
/// refused.
fn sizeOf(work: *Work, type_id: u16, stride: u16) Error!u32 {
    switch (work.thing[type_id]) {
        .float, .int => return 4,
        .vector => return 4 * @as(u32, work.wide[type_id]),
        .matrix => {
            if (stride == none) return Error.Storage;
            return (@as(u32, work.wide[type_id]) - 1) * stride + try sizeOf(work, work.points[type_id], none);
        },
        .array => {
            const apart = work.array_stride[type_id];
            if (apart == none) return Error.Storage;
            // A runtime array: what the buffer holds of it is the draw's.
            if (work.length[type_id] == 0) return 0;
            return (@as(u32, work.length[type_id]) - 1) * apart + try sizeOf(work, work.points[type_id], stride);
        },
        .structure => {
            const block = findBlock(work, type_id) orelse return Error.Type;
            if (!block.declared) return Error.Type;
            var end: u32 = 0;
            for (block.member_type[0..block.member_count], block.member_offset[0..block.member_count], block.member_stride[0..block.member_count]) |member, offset, apart| {
                end = @max(end, offset + try sizeOf(work, member, apart));
            }
            return end;
        },
        else => return Error.Type,
    }
}

/// How many bytes of storage buffer `slot` the program reads from its
/// start: one past the last float of its last-reaching load (since
/// 1.164), store (since 1.168) or atomic (since 1.169). One at an offset
/// computed reaches where the program says, which is its own to keep
/// within the range bound, as Vulkan without robustBufferAccess has it:
/// it counts for nothing here (since 1.166).
fn reachOf(work: *const Work, slot: u16) u32 {
    var reach: u32 = 0;
    for (work.program()) |each| {
        const constant = each.tag == .ssbo or ((each.tag == .ssbo_store or each.tag == .ssbo_atomic) and each.from[0] == none);
        if (constant and each.b == slot) reach = @max(reach, each.at + 4 * @as(u32, each.kind.parts()));
    }
    return reach;
}

/// Whether `type_id` is a runtime array (since 1.164).
fn isRuntime(work: *const Work, type_id: u16) bool {
    return work.thing[type_id] == .array and work.length[type_id] == 0;
}

/// The matrix `word` names, by its place in `Work.matrices`. A constant
/// one is made a value the first time it is read: its columns' constants
/// become steps there, as any constant does where it is first wanted
/// (`operand`), and it keeps its place (since 1.162).
fn matrixOf(work: *Work, word: u32) Error!u16 {
    const id = try idOf(word);
    if (work.thing[id] == .constant_matrix) {
        const at = work.points[id];
        const waiting = &work.matrices[at];
        for (waiting.columns[0..waiting.count]) |*column| {
            const kind = std.enums.fromInt(Kind, work.wide[column.*]) orelse return Error.Type;
            column.* = try operand(work, column.*, kind);
        }
        work.thing[id] = .matrix_value;
    }
    if (work.thing[id] != .matrix_value) return Error.Type;
    return work.points[id];
}

/// `made` kept among the matrices, by its place there.
fn keptMatrix(work: *Work, made: Matrix) Error!u16 {
    if (work.matrix_count == most_matrices) return Error.Steps;
    const at: u16 = @intCast(work.matrix_count);
    work.matrices[at] = made;
    work.matrix_count += 1;
    return at;
}

/// `id` the value of `made`.
fn holdMatrix(work: *Work, id: u16, made: Matrix) Error!void {
    work.thing[id] = .matrix_value;
    work.points[id] = try keptMatrix(work, made);
}

/// `id` the value of `made`, which has to be the matrix `type_id` says:
/// as many columns, each as many floats.
fn holdShaped(work: *Work, id: u16, type_id: u16, made: Matrix) Error!void {
    if (work.thing[type_id] != .matrix or work.wide[type_id] != made.count) return Error.Type;
    const rows = try kindOf(work, work.points[type_id]);
    for (made.columns[0..made.count]) |column| if (work.steps[column].kind != rows) return Error.Type;
    try holdMatrix(work, id, made);
}

/// `id` a product: a vector where it has one column and `type_id` is a
/// vector, as unwrap_matrix answers it (vtn_alu.c:35-42), and a matrix
/// otherwise.
fn holdProduct(work: *Work, id: u16, type_id: u16, made: Matrix) Error!void {
    if (work.thing[type_id] == .matrix) return holdShaped(work, id, type_id, made);
    if (made.count != 1 or try kindOf(work, type_id) != work.steps[made.columns[0]].kind) return Error.Type;
    work.step_of[id] = made.columns[0];
}

/// A vector as a matrix of one column, as wrap_matrix makes one
/// (vtn_alu.c:18-33): no transpose of anything.
fn wrapped(work: *Work, word: u32) Error!Matrix {
    const kind = try kindOfValue(work, word);
    if (kind == .f32x1) return Error.Type;
    var made = Matrix{ .count = 1 };
    made.columns[0] = try operand(work, word, kind);
    return made;
}

/// Float `k` of `of`: nir_channel, which of one float is that float.
fn channelOf(work: *Work, of: u16, k: u8) Error!u16 {
    if (work.steps[of].kind == .f32x1) return of;
    return put(work, .{ .tag = .component, .kind = .f32x1, .a = of, .at = k });
}

/// The transpose of matrix `of`, by its place among the matrices:
/// vtn_ssa_transpose (spirv_to_nir.c:4486-4510), whose column `i` is the
/// vector of every column's float `i`, and which remembers what it is the
/// transpose of - so a transpose of a transpose is the matrix itself.
fn transposeOf(work: *Work, of: u16) Error!u16 {
    const source = work.matrices[of];
    if (source.transposed != none) return source.transposed;
    const rows = work.steps[source.columns[0]].kind.parts();
    const across = std.enums.fromInt(Kind, source.count) orelse return Error.Type;
    var made = Matrix{ .count = @intCast(rows), .transposed = of };
    for (0..rows) |i| {
        var column = Step{ .tag = .construct, .kind = across };
        for (0..source.count) |j| {
            column.from[j] = source.columns[j];
            column.part[j] = @intCast(i);
        }
        made.columns[i] = try put(work, column);
    }
    return keptMatrix(work, made);
}

/// Each column of `of` times `scalar`: mat_times_scalar (vtn_alu.c:
/// 100-114).
fn timesScalar(work: *Work, of: Matrix, scalar: u16) Error!Matrix {
    var made = Matrix{ .count = of.count };
    for (of.columns[0..of.count], 0..) |column, i| made.columns[i] = try binary(work, .mul, column, scalar);
    return made;
}

/// `left` times `right`, matrices or vectors wrapped as one column:
/// matrix_multiply (vtn_alu.c:45-98). Column `i` is the sum of `left`'s
/// columns, each times float `j` of `right`'s column `i`: the last one's
/// fmul, then an ffma_weak for each before it, last to first - which
/// nir_opt_algebraic makes fadd(fmul(a, b), c) on a device with no ffma,
/// as the V3D has none (nir_opt_algebraic.py:424). Where both are
/// transposes, it is the transpose of the originals multiplied the other
/// way round, with the counts the transposes had (:69-77).
fn multiplied(work: *Work, left: Matrix, right: Matrix) Error!Matrix {
    const left_columns = left.count;
    const right_columns = right.count;
    var src0 = left;
    var src1 = right;
    var transpose_result = false;
    if (left.transposed != none and right.transposed != none) {
        src1 = work.matrices[left.transposed];
        src0 = work.matrices[right.transposed];
        transpose_result = true;
    }
    // Where the counts the transposes had are not the originals', which
    // only matrices that are not square bring about, Mesa reads past
    // them: refused.
    if (src0.count < left_columns or src1.count < right_columns) return Error.Type;
    var made = Matrix{ .count = right_columns };
    for (0..right_columns) |i| {
        const column = src1.columns[i];
        if (work.steps[column].kind.parts() < left_columns) return Error.Type;
        var sum = try binary(work, .mul, src0.columns[left_columns - 1], try channelOf(work, column, left_columns - 1));
        var j: u8 = left_columns - 1;
        while (j > 0) {
            j -= 1;
            sum = try binary(work, .add, try binary(work, .mul, src0.columns[j], try channelOf(work, column, j)), sum);
        }
        made.columns[i] = sum;
    }
    if (transpose_result) return work.matrices[try transposeOf(work, try keptMatrix(work, made))];
    return made;
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
        // Of integers (since 1.165).
        .s_abs, .s_sign, .s_min, .u_min, .s_max, .u_max, .s_clamp, .u_clamp => {},
        else => return Error.Body,
    }
    const wanted: usize = switch (which) {
        .f_min, .f_max, .n_min, .n_max, .pow, .distance, .step => 2,
        .s_min, .u_min, .s_max, .u_max => 2,
        .f_clamp, .n_clamp, .f_mix, .smooth_step, .s_clamp, .u_clamp => 3,
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
        // iabs, imin, umin, imax, umax (vtn_glsl450.c:160-176), iclamp
        // and uclamp a min of a max (:287-292, nir_builder.h:1418-1429),
        // and isign lowered (`lower_isign`, nir_opt_algebraic.py:2836):
        // integers alone, as SPIR-V has them (since 1.165).
        .s_abs, .s_sign, .s_min, .u_min, .s_max, .u_max, .s_clamp, .u_clamp => switch (which) {
            .s_abs => integerOf(work, .iabs, x[0], null),
            .s_sign => integerOf(work, .imin, try integerOf(work, .imax, x[0], try integerSplat(work, kind, -1)), try integerSplat(work, kind, 1)),
            .s_min => integerOf(work, .imin, x[0], x[1]),
            .u_min => integerOf(work, .umin, x[0], x[1]),
            .s_max => integerOf(work, .imax, x[0], x[1]),
            .u_max => integerOf(work, .umax, x[0], x[1]),
            .s_clamp => integerOf(work, .imin, try integerOf(work, .imax, x[0], x[1]), x[2]),
            else => integerOf(work, .umin, try integerOf(work, .umax, x[0], x[1]), x[2]),
        },
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
    // Each float of a constant, or of a vec or a component of one, which
    // nir_opt_constant_folding makes a load_const first (since 1.176).
    const parts = work.steps[a].kind.parts();
    var xs: [4]f32 = undefined;
    var ys: [4]f32 = undefined;
    for (0..parts) |k| {
        xs[k] = @bitCast(floatBits(work, partOf(work, a, @intCast(k))) orelse return null);
        ys[k] = xs[k];
        if (b) |at| {
            const j: u8 = if (work.steps[at].kind == .f32x1) 0 else @intCast(k);
            ys[k] = @bitCast(floatBits(work, partOf(work, at, j)) orelse return null);
        }
    }
    if (work.pool_count + parts > work.pool.len) return Error.Uniforms;
    const out = work.pool_count;
    for (0..parts) |k| {
        const x = xs[k];
        const y = ys[k];
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
    return try put(work, .{ .tag = .constant, .kind = work.steps[a].kind, .at = out });
}

/// _mesa_roundevenf: to the nearest whole float, a half to the even one.
fn roundEven(x: f32) f32 {
    if (@abs(x - @trunc(x)) != 0.5) return @round(x);
    return 2.0 * @round(x / 2.0);
}

/// The dot of two values of one kind; of one float each, their product,
/// as nir_fdot builds it for one component. Of vectors, what
/// nir_lower_alu_to_scalar lowers an fdot to before nir_opt_algebraic sees
/// it (preprocess_nir, v3dv_pipeline.c:404): the product of each float,
/// the last float's first, each summed onto those before it, as lower_fdot
/// has it where the sum need not be exact and the device prefers no fused
/// multiply-add (lower_reduction, nir_lower_alu_width.c:96-127 and
/// :161-173), so that the rules take a product of a zero or a one out
/// (since 1.176). Until then it was `to_vir`'s to lower, after the rules.
fn dotOf(work: *Work, a: u16, b: u16) Error!u16 {
    const parts = work.steps[a].kind.parts();
    if (parts == 1) return binary(work, .mul, a, b);
    var last: u16 = none;
    for (0..parts) |i| {
        const channel: u8 = @intCast(parts - 1 - i);
        const product = try binary(work, .mul, try floatOf(work, partOf(work, a, channel)), try floatOf(work, partOf(work, b, channel)));
        last = if (i == 0) product else try binary(work, .add, last, product);
    }
    return last;
}

/// `tag` of `a`, or the constant it folds to.
fn unary(work: *Work, tag: Tag, a: u16) Error!u16 {
    if (try foldedOf(work, tag, a, null)) |constant| return constant;
    return put(work, .{ .tag = tag, .kind = work.steps[a].kind, .a = a });
}

/// `tag` of `a` and `b`, of `a`'s kind: `b` is of it too, or one float.
/// Or the constant it folds to.
fn integerOf(work: *Work, op: Integer, a: u16, b: ?u16) Error!u16 {
    if (try foldedInteger(work, op, a, b)) |constant| return constant;
    return put(work, .{ .tag = .integer, .kind = work.steps[a].kind, .a = a, .b = b orelse 0, .at = @intFromEnum(op) });
}

/// The divisions and remainders of 32-bit integers nir_lower_idiv lowers
/// (inst_is_idiv, nir_lower_idiv.c:155-176).
const Division = enum { udiv, idiv, umod, irem, imod };

/// A float as a step of one, read while the module is: the step itself
/// where it is one float, else a component of it.
fn floatStep(work: *Work, of: Float) Error!u16 {
    if (work.steps[of.step].kind == .f32x1) return of.step;
    return put(work, .{ .tag = .component, .kind = .f32x1, .a = of.step, .at = of.part });
}

/// An integer constant of one word.
fn wordConstant(work: *Work, value: u32) Error!u16 {
    return immediate(work, @bitCast(value));
}

/// The constants nir_lower_idiv's lowering is of (its nir_imm_int and
/// nir_imm_float, nir_lower_idiv.c:32-94, and umul_high's,
/// nir_lower_alu.c:119-158), made once for all the floats of an
/// instruction. NIR makes each anew and nir_opt_cse makes them one again;
/// here the tables would not hold a vector of two divisions while they
/// were apart (since 1.187).
const DivisionWords = struct {
    /// 2^32 less 512, the float the reciprocal is scaled by.
    scale: u16,
    /// The 1 a refinement step adds to the quotient.
    one: u16,
    /// umul_high's 16, the shift of a word's high half.
    shift: u16,
    /// umul_high's 0xFFFF, the mask of a word's low half.
    mask: u16,
    /// The 0 the signs are compared with, of a signed operation alone.
    zero: ?u16,

    fn of(work: *Work, op: Division) Error!DivisionWords {
        return .{
            .scale = try immediate(work, 4294966784.0),
            .one = try wordConstant(work, 1),
            .shift = try wordConstant(work, 16),
            .mask = try wordConstant(work, 0xFFFF),
            .zero = if (op == .udiv or op == .umod) null else try wordConstant(work, 0),
        };
    }
};

/// nir_lower_idiv's lowering of a 32-bit division or remainder of one
/// float each (lower_idiv, nir_lower_idiv.c:137-153): an unsigned one
/// emit_udiv's (:32-65), a signed one emit_idiv's of the magnitudes
/// (:69-94). The floats it builds are nir_fp_exact (:145), which no float
/// rule here would touch anyway: an frcp of a u2f32 and an fmul of it by
/// a constant of no rule's (since 1.187).
fn dividedOf(work: *Work, op: Division, numer: u16, denom: u16, words: DivisionWords) Error!u16 {
    switch (op) {
        .udiv, .umod => return unsignedDivided(work, numer, denom, op == .umod, words),
        else => {},
    }
    const zero = words.zero.?;
    const lhs = try integerOf(work, .iabs, numer, null);
    const rhs = try integerOf(work, .iabs, denom, null);
    if (op == .idiv) {
        // (numer < 0) ^ (denom < 0), the sign bit of their XOR.
        const d_sign = try put(work, compareOf(.int_less, try integerOf(work, .ixor, numer, denom), zero));
        const res = try unsignedDivided(work, lhs, rhs, false, words);
        return put(work, selectOf(d_sign, try integerOf(work, .ineg, res, null), res));
    }
    const lh_sign = try put(work, compareOf(.int_less, numer, zero));
    const rh_sign = try put(work, compareOf(.int_less, denom, zero));
    var res = try unsignedDivided(work, lhs, rhs, true, words);
    res = try put(work, selectOf(lh_sign, try integerOf(work, .ineg, res, null), res));
    if (op == .imod) {
        var cond = try put(work, compareOf(.int_equal, res, zero));
        cond = try put(work, logicOf(.ior, try put(work, compareOf(.int_equal, lh_sign, rh_sign)), cond));
        res = try put(work, selectOf(cond, res, try integerOf(work, .iadd, res, denom)));
    }
    return res;
}

/// emit_udiv (nir_lower_idiv.c:32-65): the reciprocal of the divisor made
/// an integer of 2^32 less 512 times it, one Newton step of it, the
/// quotient the high word of the dividend times it, and two steps that
/// each take the divisor off the remainder where it is still as large;
/// the quotient, or with `modulo` the remainder.
fn unsignedDivided(work: *Work, numer: u16, denom: u16, modulo: bool, words: DivisionWords) Error!u16 {
    var rcp = try unary(work, .recip, try integerOf(work, .u2f32, denom, null));
    rcp = try integerOf(work, .f2u32, try binary(work, .mul, rcp, words.scale), null);
    const neg_rcp_times_denom = try integerOf(work, .imul, rcp, try integerOf(work, .ineg, denom, null));
    rcp = try integerOf(work, .iadd, rcp, try mulHigh(work, rcp, neg_rcp_times_denom, false, words.shift, words.mask));
    // An estimate of the quotient and the remainder, then two steps.
    var quotient = try mulHigh(work, numer, rcp, false, words.shift, words.mask);
    const num_s_remainder = try integerOf(work, .imul, quotient, denom);
    var remainder = try integerOf(work, .isub, numer, num_s_remainder);
    var remainder_ge_den = try put(work, compareOf(.uint_greater_equal, remainder, denom));
    if (!modulo) quotient = try put(work, selectOf(remainder_ge_den, try integerOf(work, .iadd, quotient, words.one), quotient));
    remainder = try put(work, selectOf(remainder_ge_den, try integerOf(work, .isub, remainder, denom), remainder));
    remainder_ge_den = try put(work, compareOf(.uint_greater_equal, remainder, denom));
    if (modulo) return put(work, selectOf(remainder_ge_den, try integerOf(work, .isub, remainder, denom), remainder));
    return put(work, selectOf(remainder_ge_den, try integerOf(work, .iadd, quotient, words.one), quotient));
}

/// The umul_high or imul_high nir_lower_alu makes four 16-bit products
/// of, v3d asking it to (`lower_mul_high`, v3dv_pipeline.c:201):
/// Hacker's Delight's Figure 8-2 of the two words' halves
/// (nir_lower_alu.c:119-158), `signed` one's shifts of a high half an
/// ishr, the unsigned one's a ushr (since 1.187; signed since 1.188).
fn mulHigh(work: *Work, src0: u16, src1: u16, signed: bool, cshift: u16, cmask: u16) Error!u16 {
    const shr: Integer = if (signed) .ishr else .ushr;
    const src0l = try integerOf(work, .iand, src0, cmask);
    const src1l = try integerOf(work, .iand, src1, cmask);
    const src0h = try integerOf(work, shr, src0, cshift);
    const src1h = try integerOf(work, shr, src1, cshift);
    const lo = try integerOf(work, .imul, src0l, src1l);
    const m1 = try integerOf(work, .imul, src0l, src1h);
    const m2 = try integerOf(work, .imul, src0h, src1l);
    var hi = try integerOf(work, .imul, src0h, src1h);
    const t = try integerOf(work, .iadd, m2, try integerOf(work, .ushr, lo, cshift));
    var w1 = try integerOf(work, .iand, t, cmask);
    const w2 = try integerOf(work, shr, t, cshift);
    w1 = try integerOf(work, .iadd, m1, w1);
    hi = try integerOf(work, .iadd, hi, try integerOf(work, .iadd, try integerOf(work, shr, w1, cshift), w2));
    return hi;
}

/// A high word of a product with a constant, its 16 and 0xFFFF made
/// for it as nir_lower_alu makes them (nir_lower_alu.c:134-135; since
/// 1.188).
fn constantMulHigh(work: *Work, n: u16, multiplier: u32, signed: bool) Error!u16 {
    const cshift = try wordConstant(work, 16);
    const cmask = try wordConstant(work, 0xFFFF);
    return mulHigh(work, n, try wordConstant(work, multiplier), signed, cshift, cmask);
}

/// A bool step of `which` of two integers.
fn comparisonStep(work: *Work, which: Comparison, a: u16, b: u16) Error!u16 {
    return put(work, compareOf(which, a, b));
}

/// A bcsel of two integers.
fn selectStep(work: *Work, condition: u16, yes: u16, no: u16) Error!u16 {
    return put(work, selectOf(condition, yes, no));
}

/// A division or remainder of a float by a constant word. v3dv's
/// preprocess_nir runs nir_opt_algebraic (v3dv_pipeline.c:413, :443)
/// before v3d's nir_opt_idiv_const (vir.c:2018): a divisor of 1, -1 or
/// a power of two is the algebraic rules' (`algebraicDivided`), the rest
/// nir_opt_idiv_const's (nir_opt_idiv_const.c:155-221), the divisor a
/// word of the unsigned operations, sign-extended of the signed
/// (:183-194; since 1.188).
fn constantDividedOf(work: *Work, op: Division, n: u16, d: u32) Error!u16 {
    if (try algebraicDivided(work, op, n, d)) |made| return made;
    return switch (op) {
        .udiv => udivByConstant(work, n, d),
        .umod => umodByConstant(work, n, d),
        .idiv => idivByConstant(work, n, @bitCast(d)),
        .irem => iremByConstant(work, n, @bitCast(d)),
        .imod => imodByConstant(work, n, @bitCast(d)),
    };
}

/// nir_opt_algebraic's rules of a division or remainder by a constant
/// (nir_opt_algebraic.py:200-217), v3d leaving `lower_bitops` unset:
/// by 1 the dividend or 0, an imod or irem by -1 0, and by a power of
/// two a shift or a mask. is_pos_power_of_two is of the word for udiv
/// and umod and of a positive integer for the others, and
/// is_neg_power_of_two of a negative one but the most negative
/// (nir_search_helpers.h:39-93). find_lsb of the constant folds; the
/// isign of idiv's is lowered (`lower_isign`, v3dv_pipeline.c:200;
/// nir_opt_algebraic.py:2836): imin(imax(a, -1), 1). Null for another
/// divisor (since 1.188).
fn algebraicDivided(work: *Work, op: Division, n: u16, d: u32) Error!?u16 {
    const signed: i32 = @bitCast(d);
    if (d == 1) return switch (op) {
        .udiv, .idiv => n,
        else => try wordConstant(work, 0),
    };
    if (signed == -1 and (op == .imod or op == .irem)) return try wordConstant(work, 0);
    const word_power = d != 0 and d & (d - 1) == 0;
    const positive_power = signed > 0 and word_power;
    const negative_power = signed < 0 and signed != std.math.minInt(i32) and std.math.isPowerOfTwo(@abs(signed));
    const magnitude: u32 = @abs(signed);
    switch (op) {
        .udiv => if (word_power) return try integerOf(work, .ushr, n, try wordConstant(work, @ctz(d))),
        .umod => if (word_power) return try integerOf(work, .iand, n, try wordConstant(work, d - 1)),
        .idiv => if (positive_power or negative_power) {
            const sign = try integerOf(work, .imin, try integerOf(work, .imax, n, try wordConstant(work, 0xFFFF_FFFF)), try wordConstant(work, 1));
            const quotient = try integerOf(work, .imul, sign, try integerOf(work, .ushr, try integerOf(work, .iabs, n, null), try wordConstant(work, @ctz(magnitude))));
            return if (negative_power) try integerOf(work, .ineg, quotient, null) else quotient;
        },
        .imod => {
            if (positive_power) return try integerOf(work, .iand, n, try wordConstant(work, d - 1));
            if (negative_power) {
                const b = try wordConstant(work, d);
                const either = try integerOf(work, .ior, n, b);
                return try selectStep(work, try comparisonStep(work, .int_equal, either, b), try wordConstant(work, 0), either);
            }
        },
        // irem(a, b) = a - ((a < 0 ? (a + b - 1) : a) & -b), of a
        // negative power of two that of its iabs (:213-217).
        .irem => if (positive_power or negative_power) {
            const negative = try comparisonStep(work, .int_less, n, try wordConstant(work, 0));
            const rounded = try selectStep(work, negative, try integerOf(work, .iadd, n, try wordConstant(work, magnitude - 1)), n);
            return try integerOf(work, .isub, n, try integerOf(work, .iand, rounded, try wordConstant(work, 0 -% magnitude)));
        },
    }
    return null;
}

/// build_udiv (nir_opt_idiv_const.c:29-56): by 0 a 0; by the largest
/// word whether the dividend is it, by one above the largest integer
/// whether it is as large, by a power of two a ushr; else Hacker's
/// Delight's multiply of `fastUdivInfo`, a uadd_sat as v3d lowers it
/// (`lower_uadd_sat`, v3dv_pipeline.c:165; nir_opt_algebraic.py:2539):
/// the sum, or ~0 where it is less than the dividend (since 1.188).
fn udivByConstant(work: *Work, n: u16, d: u32) Error!u16 {
    if (d == 0) return wordConstant(work, 0);
    if (d == 0xFFFF_FFFF) return integerOf(work, .b2i32, try comparisonStep(work, .int_equal, n, try wordConstant(work, d)), null);
    if (d > 0x7FFF_FFFF) return integerOf(work, .b2i32, try comparisonStep(work, .uint_greater_equal, n, try wordConstant(work, d)), null);
    if (d & (d - 1) == 0) return integerOf(work, .ushr, n, try wordConstant(work, @ctz(d)));
    const m = fastUdivInfo(d, 32, 32);
    var q = n;
    if (m.pre_shift != 0) q = try integerOf(work, .ushr, q, try wordConstant(work, m.pre_shift));
    if (m.increment != 0) {
        const sum = try integerOf(work, .iadd, q, try wordConstant(work, m.increment));
        q = try selectStep(work, try comparisonStep(work, .uint_less, sum, q), try wordConstant(work, 0xFFFF_FFFF), sum);
    }
    q = try constantMulHigh(work, q, @truncate(m.multiplier), false);
    if (m.post_shift != 0) q = try integerOf(work, .ushr, q, try wordConstant(work, m.post_shift));
    return q;
}

/// build_umod (nir_opt_idiv_const.c:58-68): by 0 a 0, by a power of two
/// a mask, else the dividend less the quotient times the divisor (since
/// 1.188).
fn umodByConstant(work: *Work, n: u16, d: u32) Error!u16 {
    if (d == 0) return wordConstant(work, 0);
    if (d & (d - 1) == 0) return integerOf(work, .iand, n, try wordConstant(work, d - 1));
    return integerOf(work, .isub, n, try integerOf(work, .imul, try udivByConstant(work, n, d), try wordConstant(work, d)));
}

/// build_idiv (nir_opt_idiv_const.c:70-106): by the most negative
/// whether the dividend is it; by 0 a 0, by 1 the dividend, by -1 its
/// ineg; by a power of two's size the shifted magnitude, negated where
/// the signs differ; else the imul_high of `fastSdivInfo`'s multiplier,
/// the dividend added or taken off where the two signs differ, the
/// shift, and 1 more where it is negative (since 1.188).
fn idivByConstant(work: *Work, n: u16, d: i32) Error!u16 {
    if (d == std.math.minInt(i32)) return integerOf(work, .b2i32, try comparisonStep(work, .int_equal, n, try wordConstant(work, @bitCast(d))), null);
    if (d == 0) return wordConstant(work, 0);
    if (d == 1) return n;
    if (d == -1) return integerOf(work, .ineg, n, null);
    const abs_d: u32 = @abs(d);
    if (abs_d & (abs_d - 1) == 0) {
        const uq = try integerOf(work, .ushr, try integerOf(work, .iabs, n, null), try wordConstant(work, @ctz(abs_d)));
        const n_neg = try comparisonStep(work, .int_less, n, try wordConstant(work, 0));
        const neg = if (d < 0) try put(work, logicOf(.inot, n_neg, 0)) else n_neg;
        return selectStep(work, neg, try integerOf(work, .ineg, uq, null), uq);
    }
    const m = fastSdivInfo(d, 32);
    var res = try constantMulHigh(work, n, @truncate(@as(u64, @bitCast(m.multiplier))), true);
    if (d > 0 and m.multiplier < 0) res = try integerOf(work, .iadd, res, n);
    if (d < 0 and m.multiplier > 0) res = try integerOf(work, .isub, res, n);
    if (m.shift != 0) res = try integerOf(work, .ishr, res, try wordConstant(work, m.shift));
    return integerOf(work, .iadd, res, try integerOf(work, .ushr, res, try wordConstant(work, 31)));
}

/// build_irem (nir_opt_idiv_const.c:108-126): by 0 a 0; by the most
/// negative the dividend, or 0 where it is it; else of the divisor's
/// size, by a power of two the algebraic rule's mask, by another the
/// dividend less the quotient times it (since 1.188).
fn iremByConstant(work: *Work, n: u16, d: i32) Error!u16 {
    if (d == 0) return wordConstant(work, 0);
    if (d == std.math.minInt(i32)) return selectStep(work, try comparisonStep(work, .int_equal, n, try wordConstant(work, @bitCast(d))), try wordConstant(work, 0), n);
    const abs_d: u32 = @abs(d);
    if (abs_d & (abs_d - 1) == 0) {
        const rounded = try selectStep(work, try comparisonStep(work, .int_less, n, try wordConstant(work, 0)), try integerOf(work, .iadd, n, try wordConstant(work, abs_d - 1)), n);
        return integerOf(work, .isub, n, try integerOf(work, .iand, rounded, try wordConstant(work, 0 -% abs_d)));
    }
    return integerOf(work, .isub, n, try integerOf(work, .imul, try idivByConstant(work, n, @intCast(abs_d)), try wordConstant(work, abs_d)));
}

/// build_imod (nir_opt_idiv_const.c:128-152): by 0 a 0; by the most
/// negative the dividend where it is negative but not it or is 0, else
/// it plus the most negative; by a power of two the algebraic rules'
/// mask or bcsel; else the irem, with the divisor added where it is not
/// 0 and the dividend's sign is not the divisor's (since 1.188).
fn imodByConstant(work: *Work, n: u16, d: i32) Error!u16 {
    if (d == 0) return wordConstant(work, 0);
    if (d == std.math.minInt(i32)) {
        const int_min = try wordConstant(work, @bitCast(d));
        const is_neg_not_int_min = try comparisonStep(work, .uint_less, int_min, n);
        const is_zero = try comparisonStep(work, .int_equal, n, try wordConstant(work, 0));
        return selectStep(work, try put(work, logicOf(.ior, is_neg_not_int_min, is_zero)), n, try integerOf(work, .iadd, int_min, n));
    }
    if (d > 0 and std.math.isPowerOfTwo(@as(u32, @intCast(d)))) return integerOf(work, .iand, n, try wordConstant(work, @as(u32, @intCast(d)) - 1));
    if (d < 0 and std.math.isPowerOfTwo(@abs(d))) {
        const d_def = try wordConstant(work, @bitCast(d));
        const res = try integerOf(work, .ior, n, d_def);
        return selectStep(work, try comparisonStep(work, .int_equal, res, d_def), try wordConstant(work, 0), res);
    }
    const rem = try iremByConstant(work, n, d);
    const zero = try wordConstant(work, 0);
    const sign_same = if (d < 0) try comparisonStep(work, .int_less, n, zero) else try comparisonStep(work, .int_greater_equal, n, zero);
    const rem_zero = try comparisonStep(work, .int_equal, rem, zero);
    return selectStep(work, try put(work, logicOf(.ior, rem_zero, sign_same)), rem, try integerOf(work, .iadd, rem, try wordConstant(work, @bitCast(d))));
}

/// util_fast_udiv_info: the multiplier, the shifts before and after it
/// and the increment of an unsigned division by a constant.
const FastUdivInfo = struct { multiplier: u64, pre_shift: u32, post_shift: u32, increment: u32 };

/// util_compute_fast_udiv_info (util/fast_idiv_by_const.c:46-170):
/// Hacker's Delight's round-up multiplier of the first power of two that
/// works, or of an odd divisor the round-down one and an increment, or
/// of an even one that of its odd part after a shift (since 1.188).
fn fastUdivInfo(d: u64, num_bits: u32, uint_bits: u32) FastUdivInfo {
    if (d & (d -% 1) == 0) {
        const div_shift: u32 = 63 - @clz(d);
        if (div_shift != 0) return .{ .multiplier = @as(u64, 1) << @intCast(uint_bits - div_shift), .pre_shift = 0, .post_shift = 0, .increment = 0 };
        return .{ .multiplier = @as(u64, std.math.maxInt(u64)) >> @intCast(64 - uint_bits), .pre_shift = 0, .post_shift = 0, .increment = 1 };
    }
    const extra_shift = uint_bits - num_bits;
    const initial_power_of_2 = @as(u64, 1) << @intCast(uint_bits - 1);
    var quotient = initial_power_of_2 / d;
    var remainder = initial_power_of_2 % d;
    var ceil_log_2_d: u32 = 0;
    var tmp = d;
    while (tmp > 0) : (tmp >>= 1) ceil_log_2_d += 1;
    var down_multiplier: u64 = 0;
    var down_exponent: u32 = 0;
    var has_magic_down = false;
    var exponent: u32 = 0;
    while (true) : (exponent += 1) {
        if (remainder >= d - remainder) {
            quotient = quotient *% 2 +% 1;
            remainder = remainder *% 2 -% d;
        } else {
            quotient = quotient *% 2;
            remainder = remainder *% 2;
        }
        if (exponent + extra_shift >= ceil_log_2_d or (d - remainder) <= (@as(u64, 1) << @intCast(exponent + extra_shift))) break;
        if (!has_magic_down and remainder <= (@as(u64, 1) << @intCast(exponent + extra_shift))) {
            has_magic_down = true;
            down_multiplier = quotient;
            down_exponent = exponent;
        }
    }
    if (exponent < ceil_log_2_d) return .{ .multiplier = quotient +% 1, .pre_shift = 0, .post_shift = exponent, .increment = 0 };
    if (d & 1 != 0) return .{ .multiplier = down_multiplier, .pre_shift = 0, .post_shift = down_exponent, .increment = 1 };
    var pre_shift: u32 = 0;
    var shifted_d = d;
    while (shifted_d & 1 == 0) {
        shifted_d >>= 1;
        pre_shift += 1;
    }
    var result = fastUdivInfo(shifted_d, num_bits - pre_shift, uint_bits);
    result.pre_shift = pre_shift;
    return result;
}

/// util_fast_sdiv_info: the multiplier and the shift of a signed division
/// by a constant.
const FastSdivInfo = struct { multiplier: i64, shift: u32 };

/// util_compute_fast_sdiv_info (util/fast_idiv_by_const.c:172-237):
/// Hacker's Delight's magic number of a signed divisor of neither 0, 1
/// nor -1, the first exponent at which the test numerator's quotient is
/// not less than the divisor's remainder's complement (since 1.188).
fn fastSdivInfo(d: i64, sint_bits: u32) FastSdivInfo {
    const abs_d: u64 = @abs(d);
    var exponent: u32 = sint_bits - 1;
    const initial_power_of_2 = @as(u64, 1) << @intCast(exponent);
    const tmp = initial_power_of_2 + @intFromBool(d < 0);
    const abs_test_numer = tmp - 1 - tmp % abs_d;
    var quotient1 = initial_power_of_2 / abs_test_numer;
    var remainder1 = initial_power_of_2 % abs_test_numer;
    var quotient2 = initial_power_of_2 / abs_d;
    var remainder2 = initial_power_of_2 % abs_d;
    while (true) {
        exponent += 1;
        quotient1 *%= 2;
        remainder1 *%= 2;
        if (remainder1 >= abs_test_numer) {
            quotient1 += 1;
            remainder1 -= abs_test_numer;
        }
        quotient2 *%= 2;
        remainder2 *%= 2;
        if (remainder2 >= abs_d) {
            quotient2 += 1;
            remainder2 -= abs_d;
        }
        const delta = abs_d - remainder2;
        if (!(quotient1 < delta or (quotient1 == delta and remainder1 == 0))) break;
    }
    // util_sign_extend of the low sint_bits.
    const low = (quotient2 +% 1) << @intCast(64 - sint_bits);
    var multiplier: i64 = @as(i64, @bitCast(low)) >> @intCast(64 - sint_bits);
    if (d < 0) multiplier = -multiplier;
    return .{ .multiplier = multiplier, .shift = exponent - sint_bits };
}

/// nir_opt_constant_folding of an integer operation whose operands are
/// constants: the words it comes to, wrapping as NIR's 32-bit arithmetic
/// does, a shift by the low five bits of its amount (nir_opcodes.py), and
/// a float made an integer held to the integers' range, as Zig's own
/// conversion is not (since 1.165).
fn foldedInteger(work: *Work, op: Integer, a: u16, b: ?u16) Error!?u16 {
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
        const x: u32 = @bitCast(work.pool[of_a.at + k]);
        const y: u32 = @bitCast(work.pool[of_b.at + k]);
        const sx: i32 = @bitCast(x);
        const sy: i32 = @bitCast(y);
        const f: f32 = @bitCast(x);
        const word: u32 = switch (op) {
            .iadd => x +% y,
            .isub => x -% y,
            .imul => x *% y,
            .ineg => 0 -% x,
            .iabs => @bitCast(if (sx < 0) 0 -% sx else sx),
            .imin => @bitCast(@min(sx, sy)),
            .imax => @bitCast(@max(sx, sy)),
            .umin => @min(x, y),
            .umax => @max(x, y),
            .ishl => x << @intCast(y & 31),
            .ishr => @bitCast(sx >> @intCast(y & 31)),
            .ushr => x >> @intCast(y & 31),
            .iand => x & y,
            .ior => x | y,
            .ixor => x ^ y,
            .inot => ~x,
            .f2i32 => @bitCast(if (std.math.isNan(f)) 0 else @as(i32, @intFromFloat(@min(@max(@trunc(f), -2147483648.0), 2147483520.0)))),
            .f2u32 => if (std.math.isNan(f)) 0 else @as(u32, @intFromFloat(@min(@max(@trunc(f), 0.0), 4294967040.0))),
            .i2f32 => @bitCast(@as(f32, @floatFromInt(sx))),
            .u2f32 => @bitCast(@as(f32, @floatFromInt(x))),
            .b2f32 => if (x != 0) @as(u32, @bitCast(@as(f32, 1.0))) else 0,
            .b2i32 => if (x != 0) 1 else 0,
        };
        work.pool[out + k] = @bitCast(word);
    }
    work.pool_count += parts;
    return try put(work, .{ .tag = .constant, .kind = of_a.kind, .at = out });
}

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

/// Which of VertexIndex (0) and InstanceIndex (1) the variable `id` is,
/// or null (since 1.192).
fn systemOf(work: *const Work, id: u16) ?usize {
    for (work.system_ids, 0..) |each, which| if (each == id) return which;
    return null;
}

/// A `.system` step of `which`, made the first time it is read.
fn systemStep(work: *Work, which: SystemValue) Error!u16 {
    const at = &work.system_step[@intFromEnum(which)];
    if (at.* == none) at.* = try put(work, .{ .tag = .system, .kind = .f32x1, .at = @intFromEnum(which) });
    return at.*;
}

/// What VertexIndex or InstanceIndex loads, made the first time it is
/// read: as nir_lower_system_values lowers each (since 1.192).
fn systemValueOf(work: *Work, which: usize) Error!u16 {
    if (work.system_value[which] == none) work.system_value[which] = if (which == 0)
        // load_vertex_id, where the ids are zero based: the VPM's id plus
        // the first vertex (nir_lower_system_values.c:81-83). v3dv's are
        // not zero based (v3dv_pipeline.c:212), the hardware counting from
        // the draw's first vertex; this device's draws number their
        // vertices from the lowest they draw (`_play.zig`).
        try integerOf(work, .iadd, try systemStep(work, .vertex_id), try systemStep(work, .first_vertex))
    else
        // SYSTEM_VALUE_INSTANCE_INDEX: load_instance_id plus
        // load_base_instance (nir_lower_system_values.c:202-208), each a
        // row of the VPM's.
        try integerOf(work, .iadd, try systemStep(work, .instance_id), try systemStep(work, .base_instance));
    return work.system_value[which];
}

/// The kind of what an operand id names: its step's, or a constant's.
fn kindOfValue(work: *const Work, word: u32) Error!Kind {
    const id = try idOf(word);
    if (work.step_of[id] != none) {
        if (isBool(work, work.step_of[id])) return Error.Type;
        return work.steps[work.step_of[id]].kind;
    }
    if (!isConstant(work, id)) return Error.Body;
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
/// The block of struct type `id`, made where it is not yet one: a
/// decoration may name it before or after another's (since 1.160).
fn blockOf(work: *Work, id: u16) Error!*Block {
    if (findBlock(work, id)) |found| return found;
    if (work.block_count == most_blocks) return Error.Declared;
    const made = &work.blocks[work.block_count];
    made.* = .{ .type_id = id };
    work.block_count += 1;
    return made;
}

fn findBlock(work: *Work, id: u16) ?*Block {
    for (work.blocks[0..work.block_count]) |*each| if (each.type_id == id) return each;
    return null;
}

/// The block a variable of the push constants or of a uniform buffer is
/// of: its `points` names it, the block for the one and the uniform
/// buffer for the other.
fn blockOfVariable(work: *const Work, variable: u16) *const Block {
    if (variable == work.push_variable) return &work.blocks[work.points[variable]];
    return &work.blocks[work.ubos[work.points[variable]].block];
}

fn indexOf(work: *const Work, word: u32) Error!u16 {
    const id = try idOf(word);
    if (work.thing[id] != .int_constant) return Error.Body;
    // A value past the table's is `none`, which no member is.
    const value: u32 = @bitCast(work.pool[work.points[id]]);
    return if (value < none) @intCast(value) else none;
}

/// `value` in each word of `kind`, a constant step: the immediate an
/// integer lowering builds (since 1.165).
fn integerSplat(work: *Work, kind: Kind, value: i32) Error!u16 {
    const parts = kind.parts();
    if (work.pool_count + parts > work.pool.len) return Error.Uniforms;
    const at = work.pool_count;
    for (0..parts) |k| work.pool[at + k] = @bitCast(value);
    work.pool_count += parts;
    return put(work, .{ .tag = .constant, .kind = kind, .at = at });
}

/// Whether `id` is a constant of the pool's: a float's, a vector's, or
/// since 1.165 an integer's.
fn isConstant(work: *const Work, id: u16) bool {
    return work.thing[id] == .constant or work.thing[id] == .int_constant;
}

/// Whether `type_id` is an integer or a vector of them (since 1.165).
fn isIntegerType(work: *const Work, type_id: u16) bool {
    return switch (work.thing[type_id]) {
        .int => true,
        .vector => work.thing[work.points[type_id]] == .int,
        else => false,
    };
}

/// An operand id as a step of `kind`. A constant becomes a step of its
/// own the first time it is read, which is one uniform a float.
/// An OpImageSample: ResultType, Result, SampledImage, Coordinate, a
/// Dref sample's reference (since 1.143), and then the image operands, a
/// mask and an id for each bit set, in the order the bits run. vtn makes
/// a nir_tex_instr of it (vtn_handle_texture, spirv_to_nir.c:3420-3465):
/// a Bias makes the tex a txb and a Lod is an explicit level's txl, each
/// the one float a source of its own (`Lookup`); a ConstOffset is the
/// texels a constant integer vector moves the sample by, as many as the
/// image's coordinate names but a layer (since 1.180). `look` has held
/// the operands to the profile's: no offset the program computes.
///
/// A Grad is vtn's txd, its two derivatives sources of their own
/// (spirv_to_nir.c:3441-3448), of an explicit level's sample with no Bias
/// or Lod. v3d lowers every txd (`lower_txd`, vir.c:802; nir_lower_tex.c:
/// 1833-1847), so it is the txl `gradientLevel` makes here (since 1.183).
///
/// An OpImageFetch has an Image where a sample has its SampledImage, an
/// integer coordinate, and its Lod: vtn's txf with the lod a source
/// (spirv_to_nir.c:3069-3076, :3433-3438), which GLSL's texelFetch always
/// gives and a fetch here must have. A fetch of a cube is no SPIR-V
/// (OpImageFetch's Dim), and v3d_tex.c asserts it (:376). Its ConstOffset
/// goes to P2 as a sample's does (handle_tex_src, :158-170; since 1.182).
fn readSample(work: *Work, op: spirv.Op, operands: []const u32) Error!void {
    const compared = op == .image_sample_dref_implicit_lod or op == .image_sample_dref_explicit_lod;
    const fetch = op == .image_fetch;
    const explicit = op == .image_sample_explicit_lod or op == .image_sample_dref_explicit_lod or fetch;
    const fixed: usize = if (compared) 5 else 4;
    if (operands.len < fixed) return Error.Body;
    const type_id = try idOf(operands[0]);
    const id = try idOf(operands[1]);
    if (try kindOf(work, type_id) != if (compared) Kind.f32x1 else Kind.f32x4) return Error.Type;
    const which = work.sampler_of[try idOf(operands[2])];
    if (which == none) return Error.Body;
    const dim = work.samplers[which].dim;
    if (fetch and dim == .cube) return Error.Body;
    var made: Step = .{
        .tag = if (compared) .sample_compared else .sample,
        .kind = if (compared) .f32x1 else .f32x4,
        .a = try sampledAt(work, operands[3], dim),
        // One float, compared with the reference (since 1.143).
        .b = if (compared) try operand(work, operands[4], .f32x1) else 0,
        .at = which,
        .from = .{ none, 0, 0, 0 },
    };
    if (operands.len > fixed) {
        const mask = operands[fixed];
        var next = fixed + 1;
        const bias = @intFromEnum(spirv.ImageOperands.bias);
        const lod = @intFromEnum(spirv.ImageOperands.lod);
        const grad = @intFromEnum(spirv.ImageOperands.grad);
        const const_offset = @intFromEnum(spirv.ImageOperands.const_offset);
        if (mask & ~(bias | lod | grad | const_offset) != 0) return Error.Operands;
        if (mask & (bias | lod) != 0) {
            if (next >= operands.len) return Error.Body;
            // A bias is an implicit level's and a level an explicit
            // one's (spirv_to_nir.c:3423-3438).
            if ((mask & bias != 0) == explicit or mask & bias != 0 and mask & lod != 0) return Error.Body;
            made.lookup = if (mask & bias != 0) .bias else if (fetch) .fetch else .lod;
            made.from[0] = try operand(work, operands[next], .f32x1);
            next += 1;
        }
        if (mask & grad != 0) {
            // A txd is a txl's (spirv_to_nir.c:3442), not a fetch's, and
            // SPIR-V gives a sample one of Bias, Lod and Grad.
            if (next + 1 >= operands.len) return Error.Body;
            if (!explicit or fetch or mask & (bias | lod) != 0) return Error.Body;
            made.lookup = .lod;
            made.from[0] = try gradientLevel(work, which, dim, made.a, operands[next], operands[next + 1]);
            next += 2;
        }
        if (mask & const_offset != 0) {
            if (next >= operands.len) return Error.Body;
            made.offsets = try texelOffsets(work, operands[next], dim);
            next += 1;
        }
        if (next != operands.len) return Error.Body;
    }
    // An explicit level's sample has its Lod or its Grad (since 1.183); a
    // fetch its Lod (since 1.182).
    if (explicit and made.lookup != if (fetch) Lookup.fetch else Lookup.lod) return Error.Operands;
    const at = try put(work, made);
    work.step_of[id] = at;
    if (work.sampled == none) work.sampled = at;
    work.sample_count += 1;
}

/// lower_gradient (nir_lower_tex.c:855-912): the level a gradient's
/// sample is taken at, which replace_gradient_with_lod makes the txl's
/// lod (:690-704). The size of level 0, a txs at the integer 0
/// (build_texture_size, :112-118; nir_get_texture_size,
/// nir_builtin_builder.c:459-466), of nir_tex_instr_dest_size's integers,
/// the first two of an array's (`component_mask`), made floats; each
/// derivative times it; the longer of the two, each the square root of
/// its dot with itself; and that length's logarithm to 2. A derivative
/// has as many floats as the coordinate names but a layer.
///
/// A cube's is `cubeGradientLevel` (since 1.184; refused at 1.183).
fn gradientLevel(work: *Work, which: u16, dim: SamplerDim, coordinate: u16, dx: u32, dy: u32) Error!u16 {
    if (dim == .cube) return cubeGradientLevel(work, which, coordinate, dx, dy);
    const count: u8 = if (dim == .layers) 2 else dim.components();
    const kind = std.enums.fromInt(Kind, count) orelse return Error.Type;
    const ddx = try operand(work, dx, kind);
    const ddy = try operand(work, dy, kind);
    const sizes: Kind = if (dim == .flat) .f32x2 else .f32x3;
    const size = try put(work, .{ .tag = .texture_size, .kind = sizes, .at = which, .from = .{ try immediate(work, 0.0), 0, 0, 0 } });
    // nir_channels of the i2f32 (:881-884): an array's layers are read
    // by nothing, and nir_opt_dce takes them out once
    // nir_lower_alu_to_scalar has made each float its own
    // (nir_to_vir.c:2259).
    var floats = try integerOf(work, .i2f32, size, null);
    if (sizes.parts() != count) {
        var first: Step = .{ .tag = .construct, .kind = kind };
        for (0..count) |k| {
            first.from[k] = floats;
            first.part[k] = @intCast(k);
        }
        floats = try put(work, first);
    }
    const across = try binary(work, .mul, ddx, floats);
    const down = try binary(work, .mul, ddy, floats);
    const rho = try binary(work, .max, try lengthOf(work, across), try lengthOf(work, down));
    return unary(work, .log2, rho);
}

/// lower_gradient_cube_map (nir_lower_tex.c:707-852): a cube's gradient
/// made a level, the derivatives taken onto the face the coordinate falls
/// on through the quotient rule. The coordinate is the one
/// nir_normalize_cubemap_coords made (v3dv_pipeline.c:406), which comes
/// before v3d's nir_lower_tex, as `normalizedCube` comes before this.
///
/// - The face: cond_z, the magnitude of z at least the larger of x's
///   and y's, and cond_y, of y at least the larger of x's and z's; each
///   float of Q, dQdx and dQdy the bcsel on cond_z of the coordinate's, or
///   of a derivative's, and of the bcsel on cond_y of its xzy and yzx
///   swizzles (:783-813), which nir_lower_alu_to_scalar makes a bcsel a
///   float (nir_to_vir.c:2259). Q's second is z either way under cond_z,
///   which (('bcsel', a, b, b), b) takes out.
/// - The quotient rule: the reciprocal of Q's z; Q's first two times it;
///   and each derivative's first two less those times its z, times the
///   reciprocal (:815-834).
/// - The level: fadd(-1.0, fmul(0.5, flog2(L * (L * M)))), M the fmax of
///   the two derivatives' fdot with themselves and L the cube's width at
///   level 0 made a float (:713-715, :836-848), which
///   replace_gradient_with_lod makes the txl's lod (:690-704, :851).
fn cubeGradientLevel(work: *Work, which: u16, coordinate: u16, dx: u32, dy: u32) Error!u16 {
    const size = try put(work, .{ .tag = .texture_size, .kind = .f32x2, .at = which, .from = .{ try immediate(work, 0.0), 0, 0, 0 } });
    const floats = try integerOf(work, .i2f32, size, null);
    const ddx = try operand(work, dx, .f32x3);
    const ddy = try operand(work, dy, .f32x3);
    const magnitudes = try put(work, .{ .tag = .abs, .kind = .f32x3, .a = coordinate });
    var abs_p: [3]u16 = undefined;
    for (&abs_p, 0..) |*each, k| each.* = try floatOf(work, partOf(work, magnitudes, @intCast(k)));
    const on_z = try put(work, .{ .tag = .compare, .kind = .f32x1, .a = abs_p[2], .b = try binary(work, .max, abs_p[0], abs_p[1]), .at = @intFromEnum(Comparison.greater_equal) });
    const on_y = try put(work, .{ .tag = .compare, .kind = .f32x1, .a = abs_p[1], .b = try binary(work, .max, abs_p[0], abs_p[2]), .at = @intFromEnum(Comparison.greater_equal) });
    const yzx = [3]u8{ 1, 2, 0 };
    const xzy = [3]u8{ 0, 2, 1 };
    var faced: [3][3]u16 = undefined;
    for (&faced, [3]u16{ coordinate, ddx, ddy }) |*each, vector| {
        var parts: [3]u16 = undefined;
        for (&parts, 0..) |*part, k| part.* = try floatOf(work, partOf(work, vector, @intCast(k)));
        var inner: [3]u16 = undefined;
        for (&inner, 0..) |*chosen, k| chosen.* = try put(work, selectOf(on_y, parts[xzy[k]], parts[yzx[k]]));
        for (&each.*, 0..) |*chosen, k| chosen.* = try put(work, selectOf(on_z, parts[k], inner[k]));
    }
    const rcp_q_z = try unary(work, .recip, faced[0][2]);
    const q_xy = try pairOf(work, faced[0][0], faced[0][1]);
    const tmp = try binary(work, .mul, q_xy, rcp_q_z);
    var onto: [2]u16 = undefined;
    for (&onto, faced[1..]) |*each, d| {
        const moved = try binary(work, .sub, try pairOf(work, d[0], d[1]), try binary(work, .mul, tmp, d[2]));
        each.* = try binary(work, .mul, moved, rcp_q_z);
    }
    const most = try binary(work, .max, try dotOf(work, onto[0], onto[0]), try dotOf(work, onto[1], onto[1]));
    const across = try floatOf(work, partOf(work, floats, 0));
    const scaled = try binary(work, .mul, across, try binary(work, .mul, across, most));
    const halved = try binary(work, .mul, try immediate(work, 0.5), try unary(work, .log2, scaled));
    return binary(work, .add, try immediate(work, -1.0), halved);
}

/// Two floats as a vector of two: nir_trim_vector's, of floats each a step.
fn pairOf(work: *Work, first: u16, second: u16) Error!u16 {
    var made: Step = .{ .tag = .construct, .kind = .f32x2 };
    made.from[0] = first;
    made.from[1] = second;
    return put(work, made);
}

/// A ConstOffset: a constant integer, or vector of them, of as many as
/// the image's coordinate names but a layer (non_array_components,
/// v3d_tex.c:212-214), each -8 to 7, V3D_MIN_TEXEL_OFFSET and
/// V3D_MAX_TEXEL_OFFSET, which handle_tex_src packs into P2 (:158-170).
/// SPIR-V gives a cube none; one past the device's limits is refused
/// rather than cut to its four bits (since 1.180).
fn texelOffsets(work: *const Work, word: u32, dim: SamplerDim) Error![3]i8 {
    const id = try idOf(word);
    const count: u8 = if (dim == .layers) 2 else dim.components();
    if (dim == .cube) return Error.Body;
    if (!isConstant(work, id) or work.wide[id] != count) return Error.Type;
    var made: [3]i8 = @splat(0);
    for (made[0..count], 0..) |*each, k| {
        const value: i32 = @bitCast(work.pool[work.points[id] + k]);
        if (value < -8 or value > 7) return Error.Operands;
        each.* = @intCast(value);
    }
    return made;
}

/// A sample's coordinate: the floats its image's `SamplerDim` names, or
/// more, the TMU given those. SPIR-V lets a coordinate be wider than its
/// image needs, the floats it does not use after those it does, and vtn
/// trims it (spirv_to_nir.c:3294-3296): glslc's
/// `texture(sampler2DShadow, vec3(uv, reference))` is one, the reference
/// the third float, extracted from it as the Dref (since 1.143), and a
/// plain sample's since 1.179. A cube's is normalized
/// (`normalizedCube`).
fn sampledAt(work: *Work, word: u32, dim: SamplerDim) Error!u16 {
    const id = try idOf(word);
    const kind = if (work.step_of[id] != none)
        work.steps[work.step_of[id]].kind
    else
        std.enums.fromInt(Kind, work.wide[id]) orelse return Error.Type;
    if (kind.parts() < dim.components()) return Error.Type;
    const coordinate = try operand(work, word, kind);
    return if (dim == .cube) normalizedCube(work, coordinate) else coordinate;
}

/// nir_normalize_cubemap_coords (v3dv_pipeline.c:406;
/// nir_normalize_cubemap_coords.c:30-55), put before the sample as it
/// puts its instructions: the direction, the coordinate's first three
/// floats (nir_trim_vector), times the reciprocal of the largest of
/// their magnitudes, which nir_fmax_abs_vec_comp finds from the first
/// (nir_builtin_builder.h:84-91). The TMU finds the face and the place on
/// it from what is left (since 1.179).
fn normalizedCube(work: *Work, coordinate: u16) Error!u16 {
    var direction = coordinate;
    if (work.steps[coordinate].kind != .f32x3) {
        var trimmed: Step = .{ .tag = .construct, .kind = .f32x3 };
        for (0..3) |k| {
            const of = partOf(work, coordinate, @intCast(k));
            trimmed.from[k] = of.step;
            trimmed.part[k] = of.part;
        }
        direction = try put(work, trimmed);
    }
    const magnitudes = try put(work, .{ .tag = .abs, .kind = .f32x3, .a = direction });
    var largest = try floatOf(work, .{ .step = magnitudes, .part = 0 });
    for (1..3) |k| {
        const next = try floatOf(work, .{ .step = magnitudes, .part = @intCast(k) });
        largest = try put(work, .{ .tag = .max, .kind = .f32x1, .a = largest, .b = next });
    }
    const reciprocal = try put(work, .{ .tag = .recip, .kind = .f32x1, .a = largest });
    return put(work, .{ .tag = .mul, .kind = .f32x3, .a = direction, .b = reciprocal });
}

fn operand(work: *Work, word: u32, kind: Kind) Error!u16 {
    const id = try idOf(word);
    if (work.step_of[id] != none) {
        // A bool is no float, whatever its step's width says.
        if (isBool(work, work.step_of[id])) return Error.Type;
        if (work.steps[work.step_of[id]].kind != kind) return Error.Type;
        return work.step_of[id];
    }
    if (!isConstant(work, id)) return Error.Body;
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
    work.region[at] = work.current_region;
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
            .push, .ubo, .ssbo, .ubo_indirect, .ssbo_indirect, .ssbo_store, .ssbo_atomic, .barrier, .scratch, .scratch_indirect, .scratch_store => return Error.Storage,
            .compare, .discard => return Error.Discards,
            .sample_compared, .texture_size, .texture_levels => return Error.Samplers,
            .begin_if, .begin_else, .end_if, .phi => return Error.Branches,
            .sub, .min, .max, .negate, .abs, .floor, .ceil, .trunc, .round, .recip, .rsqrt, .exp2, .log2 => return Error.Body,
            .select, .set_less, .sat, .sin, .cos, .sign, .logic, .integer => return Error.Body,
            // A vertex program's: `compile` reads a fragment program alone.
            .output, .viewport, .system, .round_to_int => return Error.Stage,
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
    try streamed(work, .{ .texture = 0 });
    try act(work, .config);
    try streamed(work, .{ .sampler = .{} });
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
/// 1.87) and the plan refuses, `Error.Operands`; Mesa's back end puts it
/// in P2 since 1.180.
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
/// written over and a uniform is read where it is wanted. None of the
/// four is a zero, which an fadd takes out (nir_opt_algebraic.py:236).
const Lit = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const made = b.mul(b.input(0, .f32x4), b.input(1, .f32x4));
        b.color(b.add(made, b.constant(.{ 0.1, 0.2, 0.3, 0.4 })));
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

/// `words` with the `at`th instruction of `op` made one of `to`, of the
/// same operands: an IAdd an IMul, a comparison another.
fn retyped(comptime words: []const u32, comptime op: spirv.Op, comptime at: u32, comptime to: spirv.Op) [words.len]u32 {
    comptime {
        var copy: [words.len]u32 = words[0..words.len].*;
        var seen: u32 = 0;
        var k: usize = 5;
        while (k < copy.len) {
            const count = copy[k] >> 16;
            if (count == 0) @compileError("a word count of zero");
            if (copy[k] & 0xFFFF == @intFromEnum(op)) {
                if (seen == at) {
                    copy[k] = (count << 16) | @intFromEnum(to);
                    return copy;
                }
                seen += 1;
            }
            k += count;
        }
        @compileError("no such instruction to retype");
    }
}

/// `words` with the first OpStore into the variable `id` taken out and
/// what it stores made the variable's initializer, as a module glslc does
/// not write would carry it: nir_lower_variable_initializers' work
/// (vk_nir.c:301) undone. The OpVariable grows by a word and the
/// store's three go.
fn initialized(comptime words: []const u32, comptime id: u32) [words.len - 2]u32 {
    comptime {
        @setEvalBranchQuota(100_000);
        var variable_at: usize = 0;
        var store_at: usize = 0;
        var value: u32 = 0;
        var k: usize = 5;
        while (k < words.len) {
            const count = words[k] >> 16;
            if (count == 0) @compileError("a word count of zero");
            const op = words[k] & 0xFFFF;
            if (op == @intFromEnum(spirv.Op.variable) and words[k + 2] == id) {
                if (count != 4) @compileError("the variable has an initializer already");
                variable_at = k;
            }
            if (op == @intFromEnum(spirv.Op.store) and words[k + 1] == id and store_at == 0) {
                if (variable_at == 0) @compileError("a store before the variable");
                store_at = k;
                value = words[k + 2];
            }
            k += count;
        }
        if (variable_at == 0 or store_at == 0) @compileError("no such variable stored into");
        var out: [words.len - 2]u32 = undefined;
        var n: usize = 0;
        k = 0;
        while (k < words.len) {
            if (k < 5) {
                out[n] = words[k];
                n += 1;
                k += 1;
                continue;
            }
            const count = words[k] >> 16;
            if (k == store_at) {
                k += count;
                continue;
            }
            for (0..count) |i| out[n + i] = words[k + i];
            if (k == variable_at) {
                out[n] = ((count + 1) << 16) | (words[k] & 0xFFFF);
                out[n + count] = value;
                n += 1;
            }
            n += count;
            k += count;
        }
        return out;
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
    if (code.sampled().len == 0) {
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
        .{ .float = 0.1 }, .{ .float = 0.2 }, .{ .float = 0.3 }, .{ .float = 0.4 },
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
    try testing.expectEqual(Sampler{ .set = 0, .binding = 0 }, code.sampled()[0]);
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
    try testing.expectEqualSlices(Word, &[_]Word{ .{ .texture = 0 }, .{ .sampler = .{} } }, code.stream());
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
    try testing.expectEqualSlices(Word, &[_]Word{ .{ .texture = 0 }, .{ .sampler = .{} } }, code.stream());
}

test "a texel added to is read out of its pair first, by a 1 loaded before the splice" {
    var work: Work = .{};
    const code = try compile(&work, Tinted.words);
    try testing.expectEqual(@as(u32, 2), code.varyings);
    try sound(&work, code);
    // The 1 first, then its own floats, then the TMU's two: every float
    // is loaded in front of the splice where the program samples, so
    // they are all asked for before the write to S that configures the
    // TMU. The fourth float's sum, with 0, is the texel's float itself
    // (nir_opt_algebraic.py:236; since 1.174).
    try testing.expectEqualSlices(Word, &[_]Word{
        .{ .float = 1 },   .{ .float = 0.1 }, .{ .float = 0.2 },
        .{ .float = 0.3 }, .{ .texture = 0 }, .{ .sampler = .{} },
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
    // One read per float of the texel, and the three adds over them.
    try testing.expectEqual(@as(u32, 4), halves);
    try testing.expectEqual(@as(u32, 3), adds);
    // Every uniform is read before the splice - the 1 and the three
    // floats of its own - although the adds that want them are all past
    // it. `sound` holds every program to that; this says the number for
    // the one program the suite pins word for word.
    try testing.expectEqual(@as(u32, 4), before);
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
    // hand-written program here writes the configuration parameter that
    // carries it, the sampler's own state being all the TMU is told
    // (Mesa's back end writes it since 1.180). Said by
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
/// moved an unpacked f32 to the tile buffer as two half-floats. Since
/// 1.167 nir_opt_dce takes the read out, nothing reading it.
const HalfRead = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const taken = b.sample(0, 0, b.input(0, .f32x2));
        _ = b.add(b.component(taken, 0), b.scalar(0.5));
        b.color(taken);
    }
});

/// The same with all four floats read out: before the guard both writes
/// to the tile buffer named registers the pool had handed out again.
/// These reads are taken out too.
const AllRead = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const taken = b.sample(0, 0, b.input(0, .f32x2));
        _ = b.add(taken, b.constant(.{ 0.1, 0.2, 0.3, 0 }));
        b.color(taken);
    }
});

test "a texel read out of its pair, into nothing that is read, is drawn as it comes" {
    // nir_opt_dce takes the reads out (since 1.167), so the texel is
    // still in its pairs and takes the shortcut, as the texel drawn with
    // nothing read out does. `settle` packs a texel read out of its
    // pairs back for the colour; a read that is live, in a program that
    // draws the texel as it comes, would want a discard, which `ir` has
    // none of.
    var work: Work = .{};
    for ([3][]const u32{ HalfRead.words, AllRead.words, Textured.words }) |words| {
        const code = try compile(&work, words);
        try sound(&work, code);
        var raw: u32 = 0;
        for (work.plan()) |each| if (each == .color_packed) {
            raw += 1;
        };
        try testing.expectEqual(@as(u32, 2), raw);
    }
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
    try testing.expectEqual(Sampler{ .set = 0, .binding = 0 }, code.sampled()[0]);
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
    // cannot decide whether the module is taken. The product by 1.0 is
    // the float itself (nir_opt_algebraic.py:292; since 1.174), so the
    // 0.25 is the one uniform.
    const read_code = try compile(&work, comptime built(.{ .construct_constants = true, .read_first = true }));
    try sound(&work, read_code);
    try testing.expectEqual(@as(u32, 1), read_code.uniform_count);
}

test "a module may declare more samplers than it samples" {
    var work: Work = .{};
    // The device's limit is one *sample*: one TMU, written once and read
    // once. How many are declared is this back end's table, so it is a
    // refusal of its own and not the device's.
    const code = try compile(&work, comptime built(.{ .samplers = 5 }));
    try sound(&work, code);
    try testing.expectEqual(Sampler{ .set = 0, .binding = 0 }, code.sampled()[0]);
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
    // was here to turn down by name; the reading takes it since 1.190,
    // and the plan, which interpolates with perspective alone, still
    // refuses it.
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
/// No two are one operation of the same floats, which nir_opt_cse would
/// make one (since 1.158).
const Crowded = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const a = b.input(0, .f32x4);
        const c = b.input(1, .f32x4);
        const made = [_]u16{
            b.mul(a, c),           b.add(a, c),           b.mul(a, a),
            b.mul(c, c),           b.add(a, a),           b.add(c, c),
            b.mul(b.add(a, c), c), b.add(b.mul(a, c), a), b.mul(b.add(a, a), c),
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
    try testing.expectEqual(Sampler{ .set = 0, .binding = 0 }, code.sampled()[0]);
    // The draw's two words, as the hand-written program reads them.
    try testing.expectEqualSlices(Word, &[_]Word{ .{ .texture = 0 }, .{ .sampler = .{ .bits = per_pixel_mask } } }, code.stream());
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
    try testing.expectEqual(Sampler{ .set = 0, .binding = 0, .compared = true }, code.sampled()[0]);
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
    try testing.expectEqual(Sampler{ .set = 0, .binding = 0, .compared = true }, glslc.sampled()[0]);
    // The plan refuses it, as it refuses facet's own.
    var plan: Work = .{};
    try testing.expectError(Error.Samplers, compile(&plan, &reference.glslc_shadow));
}

/// A TMU register `code` writes and the register it moves there, as the
/// disassembler names them: `tmut` and `rf18`.
const TmuWrite = struct {
    name: []const u8,
    source: []const u8,
};

/// The TMU writes of `code` in the order it makes them, their names in
/// `names`.
fn tmuWrites(code: Code, names: *[8][2][16]u8, into: *[8]TmuWrite) []TmuWrite {
    var buffer: [disasm.most_text]u8 = undefined;
    var count: usize = 0;
    for (code.words) |word| {
        var line = disasm.disasm(word, &buffer).?;
        while (std.mem.indexOf(u8, line, "mov tmu")) |found| {
            const start = found + "mov ".len;
            const comma = std.mem.indexOfScalarPos(u8, line, start, ',').?;
            var end = comma + 2;
            while (end < line.len and line[end] != ' ' and line[end] != ';') end += 1;
            const name = line[start..comma];
            const source = line[comma + 2 .. end];
            @memcpy(names[count][0][0..name.len], name);
            @memcpy(names[count][1][0..source.len], source);
            into[count] = .{ .name = names[count][0][0..name.len], .source = names[count][1][0..source.len] };
            count += 1;
            line = line[end..];
        }
    }
    return into[0..count];
}

/// That `code` writes the TMU registers `expected` in that order, each
/// from a register of its own.
fn expectTmuWrites(code: Code, expected: []const []const u8) !void {
    var names: [8][2][16]u8 = undefined;
    var into: [8]TmuWrite = undefined;
    const writes = tmuWrites(code, &names, &into);
    try testing.expectEqual(expected.len, writes.len);
    for (expected, writes, 0..) |want, got, k| {
        try testing.expectEqualStrings(want, got.name);
        for (writes[0..k]) |before| try testing.expect(!std.mem.eql(u8, before.source, got.source));
    }
}

/// The register `code` moves to the TMU register `name`.
fn tmuSource(code: Code, name: []const u8, names: *[8][2][16]u8, into: *[8]TmuWrite) ?[]const u8 {
    for (tmuWrites(code, names, into)) |each| {
        if (std.mem.eql(u8, each.name, name)) return each.source;
    }
    return null;
}

/// Whether an instruction of `code` writes `register` with `op`: whether
/// a line holds `op register,`.
fn writtenWith(code: Code, op: []const u8, register: []const u8) bool {
    var buffer: [disasm.most_text]u8 = undefined;
    var wanted: [32]u8 = undefined;
    const pattern = std.fmt.bufPrint(&wanted, "{s} {s},", .{ op, register }) catch return false;
    for (code.words) |word| {
        if (std.mem.indexOf(u8, disasm.disasm(word, &buffer).?, pattern) != null) return true;
    }
    return false;
}

test "a cube is sampled at its direction made as long as its largest magnitude, as nir_normalize_cubemap_coords puts it before the sample: its third float to TMUR, and the lookup started at TMUSCM" {
    // nir_normalize_cubemap_coords (v3dv_pipeline.c:406;
    // nir_normalize_cubemap_coords.c:30-55): the fabs of the direction,
    // nir_fmax_abs_vec_comp's fmax of the first two and then the third,
    // its frcp, and the direction times it. v3d_tex.c writes T and R
    // (:110-120) and starts the lookup at TMUSCM (:380-381), last
    // (since 1.179).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_cube);
    try testing.expectEqual(SamplerDim.cube, code.sampled()[0].dim);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .abs));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .max));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .recip));
    const sampled = for (work.program()) |each| {
        if (each.tag == .sample) break each;
    } else return error.TestUnexpectedResult;
    const normalized = work.steps[sampled.a];
    try testing.expectEqual(Tag.mul, normalized.tag);
    try testing.expectEqual(Kind.f32x3, normalized.kind);
    for (0..3) |k| try testing.expect(isInputPart(&work, normalized.a, @intCast(k), @intCast(k)));
    const reciprocal = work.steps[normalized.b];
    try testing.expectEqual(Tag.recip, reciprocal.tag);
    const largest = work.steps[reciprocal.a];
    try testing.expectEqual(Tag.max, largest.tag);
    const first_two = work.steps[largest.a];
    try testing.expectEqual(Tag.max, first_two.tag);
    const magnitude = partOf(&work, largest.b, 0);
    try testing.expectEqual(Tag.abs, work.steps[magnitude.step].tag);
    try testing.expectEqual(@as(u8, 2), magnitude.part);
    try testing.expectEqual(@as(u8, 0), partOf(&work, first_two.a, 0).part);
    try testing.expectEqual(@as(u8, 1), partOf(&work, first_two.b, 0).part);
    // The fabs is no instruction of its own: vir_opt_copy_propagate
    // takes the fmov's abs unpack into the fmax that reads it.
    try expectTmuWrites(code, &.{ "tmut", "tmur", "tmuscm" });
    // Each of the three is a float of the direction times the reciprocal.
    var names: [8][2][16]u8 = undefined;
    var into: [8]TmuWrite = undefined;
    for ([_][]const u8{ "tmut", "tmur", "tmuscm" }) |name| try testing.expect(writtenWith(code, "fmul", tmuSource(code, name, &names, &into).?));
    var buffer: [disasm.most_text]u8 = undefined;
    var unpacked: u32 = 0;
    for (code.words) |word| {
        const line = disasm.disasm(word, &buffer).?;
        if (std.mem.indexOf(u8, line, "fmax") != null) unpacked += @intCast(std.mem.count(u8, line, ".abs"));
        try testing.expect(std.mem.indexOf(u8, line, "fmov") == null);
    }
    try testing.expectEqual(@as(u32, 3), unpacked);
}

test "a 3D texture's third float is written to TMUR and a layer of an array to TMUI, a float the TMU rounds, the lookup started at TMUS" {
    // handle_tex_src (v3d_tex.c:110-127): non_array_components is three
    // for a 3D texture, so R, and two for an array, its layer the last
    // float to I; neither is normalized (since 1.179).
    var volume: Work = .{};
    const volume_code = try throughMesa(&volume, &reference.glslc_volume);
    try testing.expectEqual(SamplerDim.volume, volume_code.sampled()[0].dim);
    try testing.expectEqual(@as(usize, 0), stepsOf(&volume, .recip));
    try expectTmuWrites(volume_code, &.{ "tmut", "tmur", "tmus" });
    var layers: Work = .{};
    const layers_code = try throughMesa(&layers, &reference.glslc_layers);
    try testing.expectEqual(SamplerDim.layers, layers_code.sampled()[0].dim);
    try testing.expectEqual(@as(usize, 0), stepsOf(&layers, .recip));
    try expectTmuWrites(layers_code, &.{ "tmut", "tmui", "tmus" });
    var names: [8][2][16]u8 = undefined;
    var into: [8]TmuWrite = undefined;
    try testing.expect(writtenWith(layers_code, "fmul", tmuSource(layers_code, "tmui", &names, &into).?));
    const sampled = for (layers.program()) |each| {
        if (each.tag == .sample) break each;
    } else return error.TestUnexpectedResult;
    // The layer is the blue times 3.0, as it is, with no rounding.
    const layer = work: {
        const of = partOf(&layers, sampled.a, 2);
        break :work layers.steps[of.step];
    };
    try testing.expectEqual(Tag.mul, layer.tag);
    try testing.expect(isInputPart(&layers, layer.a, 0, 2));
    // The plan reads a 2D texture alone.
    var plan: Work = .{};
    try testing.expectError(Error.Samplers, compile(&plan, &reference.glslc_volume));
}

test "a cube or an array of depths compared takes the floats its image names of a wider coordinate, the cube's direction its first three normalized, and the reference its own" {
    // vtn trims the coordinate to what the image names
    // (spirv_to_nir.c:3294-3296): glslc's vec4 of a direction and the
    // reference is the direction to nir_normalize_cubemap_coords, and
    // the place and the layer to TMUT and TMUI; the reference, the
    // Dref, goes to TMUDREF (v3d_tex.c:155-157), which v3d's scheduler
    // may put before T (can_reorder_tmu_write, qpu_schedule.c:225-235),
    // S last (since 1.179).
    var cube: Work = .{};
    const cube_code = try throughMesa(&cube, &reference.glslc_cube_shadow);
    try testing.expectEqual(Sampler{ .set = 0, .binding = 0, .compared = true, .dim = .cube }, cube_code.sampled()[0]);
    const compared = for (cube.program()) |each| {
        if (each.tag == .sample_compared) break each;
    } else return error.TestUnexpectedResult;
    const normalized = cube.steps[compared.a];
    try testing.expectEqual(Tag.mul, normalized.tag);
    try testing.expectEqual(Kind.f32x3, normalized.kind);
    for (0..3) |k| try testing.expect(isInputPart(&cube, normalized.a, @intCast(k), @intCast(k)));
    try testing.expect(isInputPart(&cube, compared.b, 0, 3));
    var names: [8][2][16]u8 = undefined;
    var into: [8]TmuWrite = undefined;
    const writes = tmuWrites(cube_code, &names, &into);
    try testing.expectEqual(@as(usize, 4), writes.len);
    try testing.expectEqualStrings("tmuscm", writes[3].name);
    for ([_][]const u8{ "tmut", "tmur", "tmuscm" }) |name| try testing.expect(writtenWith(cube_code, "fmul", tmuSource(cube_code, name, &names, &into).?));
    try testing.expect(!writtenWith(cube_code, "fmul", tmuSource(cube_code, "tmudref", &names, &into).?));
    var layers: Work = .{};
    const layers_code = try throughMesa(&layers, &reference.glslc_layers_shadow);
    try testing.expectEqual(Sampler{ .set = 0, .binding = 0, .compared = true, .dim = .layers }, layers_code.sampled()[0]);
    try expectTmuWrites(layers_code, &.{ "tmut", "tmui", "tmudref", "tmus" });
    try testing.expect(writtenWith(layers_code, "fmul", tmuSource(layers_code, "tmui", &names, &into).?));
}

test "a cube of an array is refused, which needs SampledCubeArray" {
    var work: Work = .{};
    try testing.expectError(Error.Refused, throughMesa(&work, &reference.glslc_cube_array));
}

/// The uniform stream of a sample whose P2 is `p2`: its texture, its
/// sampler with the per-pixel mask, and the constant P2 after them.
fn sampledStream(p2: ?u32) [3]Word {
    return .{ .{ .texture = 0 }, .{ .sampler = .{ .bits = per_pixel_mask } }, .{ .float = @bitCast(p2 orelse 0) } };
}

/// That `code` writes the TMU registers `expected`, each once, in any
/// order but the one that starts the lookup, `last`, last: v3d's
/// scheduler reorders every TMU write but S (can_reorder_tmu_write,
/// qpu_schedule.c:225-235).
fn expectTmuWritesEnding(code: Code, expected: []const []const u8, last: []const u8) !void {
    var names: [8][2][16]u8 = undefined;
    var into: [8]TmuWrite = undefined;
    const writes = tmuWrites(code, &names, &into);
    try testing.expectEqual(expected.len + 1, writes.len);
    try testing.expectEqualStrings(last, writes[writes.len - 1].name);
    for (expected) |want| {
        var seen: usize = 0;
        for (writes[0 .. writes.len - 1]) |got| seen += @intFromBool(std.mem.eql(u8, want, got.name));
        try testing.expectEqual(@as(usize, 1), seen);
    }
}

/// The one sample of `work`'s program.
fn onlySample(work: *const Work) !Step {
    var found: ?Step = null;
    for (work.program()) |each| if (each.tag == .sample or each.tag == .sample_compared) {
        if (found != null) return error.TestUnexpectedResult;
        found = each;
    };
    return found orelse error.TestUnexpectedResult;
}

test "a sample at a level the program gives writes the level to TMUB and starts the lookup at TMUSLOD, which disables the automatic level, P2 its default and not written" {
    // vtn's txl, the Lod a source of its own (spirv_to_nir.c:3434-3439);
    // handle_tex_src writes it to TMUB (v3d_tex.c:135-150) and
    // v3d_vir_emit_tex starts the lookup at TMUSLOD (:382-383). P2 is
    // the default, so the stream is P0 and P1 alone (:349-352; since
    // 1.180).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_lod);
    const sampled = try onlySample(&work);
    try testing.expectEqual(Lookup.lod, sampled.lookup);
    const level = work.steps[sampled.from[0]];
    try testing.expectEqual(Tag.mul, level.tag);
    try testing.expect(isInputPart(&work, level.a, 0, 2));
    try testing.expectEqual(Tag.constant, work.steps[level.b].tag);
    try testing.expectEqual(@as(f32, 4.0), work.pool[work.steps[level.b].at]);
    try expectTmuWrites(code, &.{ "tmut", "tmub", "tmuslod" });
    var names: [8][2][16]u8 = undefined;
    var into: [8]TmuWrite = undefined;
    try testing.expect(writtenWith(code, "fmul", tmuSource(code, "tmub", &names, &into).?));
    try testing.expectEqualSlices(Word, sampledStream(null)[0..2], code.stream());
    // A depth compared at a level: the reference to TMUDREF beside it.
    var shadow: Work = .{};
    const shadow_code = try throughMesa(&shadow, &reference.glslc_shadow_lod);
    const compared = try onlySample(&shadow);
    try testing.expectEqual(Tag.sample_compared, compared.tag);
    try testing.expectEqual(Lookup.lod, compared.lookup);
    try testing.expectEqual(Tag.constant, shadow.steps[compared.from[0]].tag);
    try testing.expectEqual(@as(f32, 1.0), shadow.pool[shadow.steps[compared.from[0]].at]);
    try expectTmuWritesEnding(shadow_code, &.{ "tmut", "tmudref", "tmub" }, "tmuslod");
    try testing.expectEqualSlices(Word, sampledStream(null)[0..2], shadow_code.stream());
}

test "a bias is written to TMUB, the level the quad gives biased by it, and the lookup started at TMUS" {
    // vtn's txb (spirv_to_nir.c:3424-3432), the bias to TMUB
    // (v3d_tex.c:129-133); the lookup is a regular one, TMUS (:384-385;
    // since 1.180).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_bias);
    const sampled = try onlySample(&work);
    try testing.expectEqual(Lookup.bias, sampled.lookup);
    try testing.expectEqual(Tag.sub, work.steps[sampled.from[0]].tag);
    try expectTmuWrites(code, &.{ "tmut", "tmub", "tmus" });
    var names: [8][2][16]u8 = undefined;
    var into: [8]TmuWrite = undefined;
    try testing.expect(writtenWith(code, "fsub", tmuSource(code, "tmub", &names, &into).?));
    try testing.expectEqualSlices(Word, sampledStream(null)[0..2], code.stream());
}

test "a constant offset is P2's, written after P1 as a constant of the uniform stream, four bits for each axis the image's coordinate names but a layer" {
    // handle_tex_src (v3d_tex.c:158-170) packs the offset's components
    // into P2's offset_s, offset_t and offset_r, as many as
    // non_array_components; the P2 is no longer the default, so it is
    // written, as a constant (:349-352, :372-373). V3D42_TMU_CONFIG_
    // PARAMETER_2: the op 15 at bit 20, r at 16, t at 12, s at 8
    // (v3d_packet.xml:1578-1593; since 1.180).
    const cases = .{
        .{ "glslc_offset", [3]i8{ 1, -2, 0 }, 0x00F0E100, Lookup.implicit, &[_][]const u8{ "tmut", "tmus" } },
        .{ "glslc_lod_offset", [3]i8{ -8, 7, 0 }, 0x00F07800, Lookup.lod, &[_][]const u8{ "tmut", "tmub", "tmuslod" } },
        .{ "glslc_bias_offset", [3]i8{ 3, 0, 0 }, 0x00F00300, Lookup.bias, &[_][]const u8{ "tmut", "tmub", "tmus" } },
        .{ "glslc_volume_offset", [3]i8{ 1, 2, -3 }, 0x00FD2100, Lookup.implicit, &[_][]const u8{ "tmut", "tmur", "tmus" } },
        .{ "glslc_layers_offset", [3]i8{ 3, -1, 0 }, 0x00F0F300, Lookup.implicit, &[_][]const u8{ "tmut", "tmui", "tmus" } },
    };
    inline for (cases) |case| {
        var work: Work = .{};
        const code = try throughMesa(&work, &@field(reference, case[0]));
        const sampled = try onlySample(&work);
        try testing.expectEqual(case[1], sampled.offsets);
        try testing.expectEqual(case[3], sampled.lookup);
        const stream = code.stream();
        const expected = sampledStream(case[2]);
        // A layer's scale may come before the sample's words.
        try testing.expectEqualSlices(Word, &expected, stream[stream.len - 3 ..]);
        const last = case[4][case[4].len - 1];
        try expectTmuWritesEnding(code, case[4][0 .. case[4].len - 1], last);
    }
    // facet's own emitter writes the offset as glslc does.
    var emitted: Work = .{};
    const emitted_code = try throughMesa(&emitted, Offset.words);
    try testing.expectEqualSlices(Word, &sampledStream(0x00F0E100), emitted_code.stream());
    // The plan writes no P2: a hand-written program has no offset.
    var plan: Work = .{};
    try testing.expectError(Error.Operands, compile(&plan, &reference.glslc_offset));
}

test "a cube at a level the program gives has P2 disable the automatic level, as TMUSCM does not, and is started at TMUSCM" {
    // handle_tex_src (v3d_tex.c:142-148) sets disable_autolod for a
    // cube's txl, which TMUSLOD would otherwise imply; the cube's own
    // lookup is TMUSCM (:380-381), and the level goes to TMUB after the
    // coordinate (since 1.180).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_cube_lod);
    const sampled = try onlySample(&work);
    try testing.expectEqual(Lookup.lod, sampled.lookup);
    try testing.expectEqual(Tag.mul, work.steps[sampled.from[0]].tag);
    try expectTmuWritesEnding(code, &.{ "tmut", "tmur", "tmub" }, "tmuscm");
    const stream = code.stream();
    try testing.expectEqualSlices(Word, &sampledStream(0x00F00002), stream[stream.len - 3 ..]);
}

test "a cube of depths compared with a bias is five TMU writes, which two threads have room for and four do not" {
    // get_required_tex_tmu_writes (v3d_tex.c:222) counts T, R, the
    // reference, the bias and S; v3d_vir_emit_tex halves the threads
    // while they are more than 16 over the threads (:265-266; since
    // 1.180).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_cube_shadow_bias);
    const sampled = try onlySample(&work);
    try testing.expectEqual(Tag.sample_compared, sampled.tag);
    try testing.expectEqual(Lookup.bias, sampled.lookup);
    // The bias is the second varying, its one float.
    try testing.expectEqual(Tag.input, work.steps[sampled.from[0]].tag);
    try testing.expectEqual(@as(u16, 1), work.steps[sampled.from[0]].at);
    try expectTmuWritesEnding(code, &.{ "tmut", "tmur", "tmudref", "tmub" }, "tmuscm");
    try testing.expectEqual(@as(u8, 2), code.threads);
    try testing.expectEqualSlices(Word, sampledStream(null)[0..2], code.stream());
}

test "a level and a bias are reads the passes rename as any other: nir_opt_cse's takes the level computed again and renumbers the bias after it" {
    // glslc -O0 keeps color.z / 4.0 three times; v3dv's lower_fdiv
    // makes each the multiplication by the constant's reciprocal
    // (v3dv_pipeline.c:193; nir_opt_algebraic.py:1918), and nir_opt_cse
    // leaves one of the three, which the level reads: the bias's
    // quotient, after the second, moves down a place (since 1.180).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_divided);
    var lookups: [2]Lookup = undefined;
    var count: usize = 0;
    for (work.program()) |each| if (each.tag == .sample) {
        lookups[count] = each.lookup;
        const quotient = work.steps[each.from[0]];
        try testing.expectEqual(Tag.mul, quotient.tag);
        try testing.expectEqual(Kind.f32x1, quotient.kind);
        const part: u8 = if (each.lookup == .lod) 2 else 3;
        try testing.expect(isInputPart(&work, quotient.a, 0, part));
        try testing.expectEqual(@as(f32, if (each.lookup == .lod) 0.25 else 0.5), work.pool[work.steps[quotient.b].at]);
        count += 1;
    };
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqual([2]Lookup{ .lod, .bias }, lookups);
    try testing.expectEqual(@as(usize, 1), countOf(code, "tmuslod"));
    try testing.expectEqual(@as(usize, 2), countOf(code, "mov tmub"));
}

test "a sample at a level in a selection's arm keeps the arm, as an implicit level's does: glslc_branched's program, the level to TMUB and the lookup at TMUSLOD" {
    // A tex instruction is none that block_check_for_allowed_instrs lets
    // through (nir_opt_peephole_select.c:59-326), whatever its op (since
    // 1.180).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_lod_arm);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 4), stepsOf(&work, .phi));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .select));
    try testing.expectEqual(@as(usize, 1), countOf(code, "bu.allna"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "bu.alla"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmub, 0x3f800000"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "tmuslod"));
    var branched: Work = .{};
    const implicit = try throughMesa(&branched, &reference.glslc_branched);
    try testing.expectEqualSlices(Word, implicit.stream(), code.stream());
}

test "a sample at a level the program gives wants no helper pixels for its coordinate, so the read its coordinate comes from skips them too" {
    // nir_opt_load_skip_helpers (:151-156): only a sample whose level the
    // quad's derivatives give, nir_tex_instr_has_implicit_derivative,
    // needs its coordinate in the helper pixels. A txl's coordinate the
    // texel of another sample: that sample's result wanted in no helper
    // pixel, its P1 has the per-pixel mask (v3d_tex.c:311-321; since
    // 1.180).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_dependent);
    var samples: usize = 0;
    for (work.program(), 0..) |each, at| if (each.tag == .sample) {
        try testing.expect(work.skip_helpers[at]);
        try testing.expectEqual(if (samples == 0) Lookup.implicit else Lookup.lod, each.lookup);
        samples += 1;
    };
    try testing.expectEqual(@as(usize, 2), samples);
    const sampler: Word = .{ .sampler = .{ .bits = per_pixel_mask } };
    try testing.expectEqualSlices(Word, &.{ .{ .texture = 0 }, sampler, .{ .texture = 0 }, sampler }, code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(code, "tmuslod"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmus,"));
}

/// glslc_offset's -2 made -9: an offset past V3D_MAX_TEXEL_OFFSET, which
/// P2's four bits would wrap, and the reading refuses rather than cuts.
/// Until 1.184 the tests' operand refused was a cube's gradient, and
/// until 1.183 any gradient.
const offset_too_far = made: {
    var far = reference.glslc_offset;
    var rewritten: usize = 0;
    for (far[5..], 5..) |word, k| if (word == 0x0004002B and far[k + 3] == @as(u32, @bitCast(@as(i32, -2)))) {
        far[k + 3] = @bitCast(@as(i32, -9));
        rewritten += 1;
    };
    if (rewritten != 1) @compileError("glslc_offset's -2 is not where it was");
    break :made far;
};

test "a sample's image operands are refused for what the device does not take, and for what SPIR-V forbids" {
    var work: Work = .{};
    try testing.expectError(Error.Operands, throughMesa(&work, &offset_too_far));
    // And glslc_lod_offset's 7 made 8.
    var past = reference.glslc_lod_offset;
    var rewritten: usize = 0;
    for (past[5..], 5..) |word, k| if (word == 0x0004002B and past[k + 3] == 7) {
        past[k + 3] = 8;
        rewritten += 1;
    };
    try testing.expectEqual(@as(usize, 1), rewritten);
    try testing.expectError(Error.Operands, throughMesa(&work, &past));
    // An explicit level's sample with no image operands: SPIR-V has it
    // carry a Lod or a Grad, and `look` finds it cut short.
    var short = reference.glslc_lod;
    rewritten = 0;
    for (&short) |*word| if (word.* == (7 << 16 | 88)) {
        word.* = 5 << 16 | 88;
        rewritten += 1;
    };
    try testing.expectEqual(@as(usize, 1), rewritten);
    try testing.expectEqual(spirv.Fault.truncated_instruction, spirv.look(&short, profile).fault);
    // A Lod on an implicit level's sample, and a Bias on an explicit
    // one's: vtn asserts neither (spirv_to_nir.c:3425-3427, :3435-3436).
    inline for (.{ .{ "glslc_lod", 88, 87 }, .{ "glslc_bias", 87, 88 } }) |case| {
        var swapped = @field(reference, case[0]);
        var changed: usize = 0;
        for (&swapped) |*word| if (word.* & 0xffff == case[1] and word.* >> 16 >= 5) {
            word.* = word.* & 0xffff0000 | case[2];
            changed += 1;
        };
        try testing.expectEqual(@as(usize, 1), changed);
        try testing.expectError(Error.Body, throughMesa(&work, &swapped));
    }
    // A level is read by the plan nowhere (glslc_bias's arithmetic is
    // refused there before its sample is).
    var plan: Work = .{};
    try testing.expectError(Error.Operands, compile(&plan, &reference.glslc_lod));
}

/// The words a program asks of the view `unit` samples, in order.
fn sizesOf(comptime fields: []const TextureSize.Field) [fields.len]Word {
    var made: [fields.len]Word = undefined;
    for (&made, fields) |*each, field| each.* = .{ .texture_size = .{ .field = field } };
    return made;
}

test "a texture's size at a level is the draw's word of each axis, shifted right by the level and at least 1, as ntq_emit_txs and ntq_minify make it" {
    // vtn's txs of the image of the sampled image, with its lod
    // (spirv_to_nir.c:3089-3096, :3119-3135, :3384-3386); ntq_emit_txs reads a
    // QUNIFORM_TEXTURE_WIDTH and _HEIGHT of the unit, and ntq_minify
    // makes each the MAX of its SHR by the level and 1
    // (nir_to_vir.c:895-960). The level 0 is a small immediate; no
    // sampler state is read, so the stream has no P0 or P1 (since 1.181).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_size);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .texture_size));
    try testing.expectEqualSlices(Word, &sizesOf(&.{ .width, .height }), code.stream());
    try testing.expectEqual(@as(usize, 2), countOf(code, "shr "));
    try testing.expectEqual(@as(usize, 2), countOf(code, ", 0 "));
    try testing.expectEqual(@as(usize, 2), countOf(code, "max "));
    try testing.expectEqual(@as(usize, 2), countOf(code, "itof "));
    // The unit is the program's, for the draw to find its view.
    try testing.expectEqual(@as(usize, 1), code.sampled().len);
    // A level that differs from pixel to pixel: the FTOIZ of the red
    // times 4.0 is what both sizes are shifted by.
    var lod: Work = .{};
    const lod_code = try throughMesa(&lod, &reference.glslc_size_lod);
    try testing.expectEqualSlices(Word, &sizesOf(&.{ .width, .height }), lod_code.stream());
    for (lod.program()) |each| if (each.tag == .texture_size) {
        try testing.expect(isIntegerOp(lod.steps[each.from[0]], .f2i32));
    };
    try testing.expectEqual(@as(usize, 1), countOf(lod_code, "ftoiz "));
    try testing.expectEqual(@as(usize, 2), countOf(lod_code, "shr "));
    // The plan has no program for it.
    var plan: Work = .{};
    try testing.expectError(Error.Samplers, compile(&plan, &reference.glslc_size));
}

test "a 2D array's layers are its size's last integer, not minified; a 3D texture's depth is, and a cube's size is two" {
    // ntq_emit_txs takes QUNIFORM_TEXTURE_ARRAY_SIZE for an array's last
    // and leaves it as it is (nir_to_vir.c:929-930, :944-947), and _DEPTH for a 3D
    // texture's third (since 1.181).
    var layers: Work = .{};
    const layers_code = try throughMesa(&layers, &reference.glslc_size_layers);
    try testing.expectEqualSlices(Word, &sizesOf(&.{ .width, .height, .array_size }), layers_code.stream());
    try testing.expectEqual(@as(usize, 2), countOf(layers_code, "shr "));
    try testing.expectEqual(@as(usize, 2), countOf(layers_code, "max "));
    var volume: Work = .{};
    const volume_code = try throughMesa(&volume, &reference.glslc_size_volume);
    try testing.expectEqualSlices(Word, &sizesOf(&.{ .width, .height, .depth }), volume_code.stream());
    try testing.expectEqual(@as(usize, 3), countOf(volume_code, "shr "));
    try testing.expectEqual(@as(usize, 3), countOf(volume_code, ", 2 "));
    var cube: Work = .{};
    const cube_code = try throughMesa(&cube, &reference.glslc_size_cube);
    try testing.expectEqualSlices(Word, &sizesOf(&.{ .width, .height }), cube_code.stream());
    try testing.expectEqual(@as(usize, 2), countOf(cube_code, "shr "));
}

test "a texture's levels are the draw's word of them, as ntq_emit_tex reads query_levels" {
    // QUNIFORM_TEXTURE_LEVELS (nir_to_vir.c:972-975), v3dv's view's
    // level count (v3dv_uniforms.c:408-409; since 1.181).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_levels);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .texture_levels));
    try testing.expectEqualSlices(Word, &sizesOf(&.{.levels}), code.stream());
    try testing.expectEqual(@as(usize, 0), countOf(code, "shr "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "itof "));
}

test "a query and a sample of one texture are one unit, a comparison in it or not, and a size nothing reads is no word" {
    // The query's unit is the sample's; the sample's P0 and P1 and the
    // sizes are the stream's in the order the program reads them.
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_size_sampled);
    try testing.expectEqual(@as(usize, 1), code.sampled().len);
    const sampler: Word = .{ .sampler = .{ .bits = per_pixel_mask } };
    try testing.expectEqualSlices(Word, &(sizesOf(&.{ .width, .height }) ++ [_]Word{ .{ .texture = 0 }, sampler }), code.stream());
    // A unit a comparison is in: the query reads no sampler state, so it
    // is no other sampler's. The width alone is read, and the height's
    // SHR, MAX and uniform are dead (vir_opt_dead_code).
    var shadow: Work = .{};
    const shadow_code = try throughMesa(&shadow, &reference.glslc_size_shadow);
    try testing.expectEqual(@as(usize, 1), shadow_code.sampled().len);
    try testing.expect(shadow_code.sampled()[0].compared);
    try testing.expectEqualSlices(Word, &[_]Word{ .{ .texture = 0 }, sampler, .{ .texture_size = .{ .field = .width } } }, shadow_code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(shadow_code, "shr "));
    // Two variables at one set and binding are one unit, the query's
    // the sample's (descriptor_map_add, v3dv_pipeline.c:516-561).
    var aliased: Work = .{};
    const aliased_code = try throughMesa(&aliased, &reference.glslc_size_aliased);
    try testing.expectEqual(@as(usize, 1), aliased_code.sampled().len);
    try testing.expectEqualSlices(Word, &[_]Word{ .{ .texture = 0 }, sampler, .{ .texture_size = .{ .field = .width } } }, aliased_code.stream());
}

test "a query in a selection's arm keeps the arm, as any tex instruction does" {
    // block_check_for_allowed_instrs lets no tex instruction through
    // (nir_opt_peephole_select.c:59-326; since 1.181).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_size_arm);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .select));
    try testing.expectEqual(@as(usize, 2), countOf(code, "shr "));
}

test "a query's level that nir_opt_cse makes an earlier step's is read from that step" {
    // glslc -O0 computes the level twice; nir_opt_cse rewrites the
    // query's source to the first FTOIZ (nir_instr_set.c), and the one
    // left is what both the SHRs and the float read (since 1.181).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_size_merged);
    try testing.expectEqualSlices(Word, &sizesOf(&.{ .width, .height }), code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(code, "ftoiz "));
    try testing.expectEqual(@as(usize, 2), countOf(code, "shr "));
    for (work.program()) |each| if (each.tag == .texture_size) {
        try testing.expect(isIntegerOp(work.steps[each.from[0]], .f2i32));
    };
}

/// glslc_fetch's words with its OpImageFetch's Lod taken out, mask and
/// all: a fetch of no level.
const fetch_of_no_level = made: {
    const words = reference.glslc_fetch;
    const at = std.mem.indexOfScalar(u32, &words, 0x0007005F).?;
    var cut: [words.len - 2]u32 = undefined;
    for (0..at) |k| cut[k] = words[k];
    cut[at] = 0x0005005F;
    for (1..5) |k| cut[at + k] = words[at + k];
    for (at + 7..words.len) |k| cut[k - 2] = words[k];
    break :made cut;
};

test "a texel at a level is vtn's txf, its integers to TMUT and TMUB and its lookup started at TMUSF, as v3d_vir_emit_tex makes it" {
    // OpImageFetch's txf with its lod (spirv_to_nir.c:3069-3076,
    // :3433-3438): the coordinate's integers, T first and S last, the
    // level to TMUB, and TMUSF (v3d_tex.c:85-150, :375-377). No sampler
    // state is read: the fetch skips its helper pixels, so neither P1 nor
    // P2 is written and the stream is P0's word alone (:312-371; since
    // 1.182).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_fetch);
    var fetches: usize = 0;
    for (work.program()) |each| if (each.tag == .sample) {
        try testing.expectEqual(Lookup.fetch, each.lookup);
        try testing.expect(isIntegerOp(work.steps[each.a], .f2i32) or work.steps[each.a].tag == .construct);
        fetches += 1;
    };
    try testing.expectEqual(@as(usize, 1), fetches);
    try testing.expectEqualSlices(Word, &[_]Word{.{ .texture = 0 }}, code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmub, 1"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmut, "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmusf, "));
    try testing.expectEqual(@as(usize, 0), countOf(code, "mov tmus, "));
    try testing.expectEqual(@as(usize, 0), countOf(code, "tmuslod"));
    try testing.expectEqual(@as(usize, 2), countOf(code, "ftoiz "));
    try testing.expectEqual(@as(usize, 1), code.sampled().len);
    // A txf has no implicit derivatives, as a txl has none
    // (nir_tex_instr_has_implicit_derivative, nir.c).
    try testing.expect(!Lookup.fetch.derived());
    // Level 0 is written as any other.
    var zero: Work = .{};
    const zero_code = try throughMesa(&zero, &reference.glslc_fetch_zero);
    try testing.expectEqual(@as(usize, 1), countOf(zero_code, "mov tmub, 0"));
    try testing.expectEqual(@as(usize, 1), countOf(zero_code, "mov tmusf, "));
    // A fetch with no Lod is refused, as an explicit level's sample with
    // none is. The plan's programs compute no integer, so the FTOIZ of
    // the coordinate is refused before the fetch is reached.
    var bare: Work = .{};
    try testing.expectError(Error.Operands, throughMesa(&bare, &fetch_of_no_level));
    var plan: Work = .{};
    try testing.expectError(Error.Body, compile(&plan, &reference.glslc_fetch));
}

test "a texel of an array's layer is the layer's integer to TMUI, and of a 3D texture's slice to TMUR" {
    // handle_tex_src's coordinate (v3d_tex.c:99-127; since 1.182).
    var layers: Work = .{};
    const layers_code = try throughMesa(&layers, &reference.glslc_fetch_layers);
    try testing.expectEqual(@as(usize, 1), countOf(layers_code, "mov tmui, 2"));
    try testing.expectEqual(@as(usize, 1), countOf(layers_code, "mov tmub, 1"));
    try testing.expectEqual(@as(usize, 1), countOf(layers_code, "mov tmusf, "));
    try testing.expectEqual(@as(usize, 0), countOf(layers_code, "tmur"));
    var volume: Work = .{};
    const volume_code = try throughMesa(&volume, &reference.glslc_fetch_volume);
    try testing.expectEqual(@as(usize, 1), countOf(volume_code, "mov tmur, 3"));
    try testing.expectEqual(@as(usize, 1), countOf(volume_code, "mov tmub, 0"));
    try testing.expectEqual(@as(usize, 0), countOf(volume_code, "tmui"));
}

test "a texel a constant offset away has P2 after the default P1, both constants, and no sampler state" {
    // needs_p2_config with no sampler: P1 is p1_unpacked_default, the
    // per-pixel mask, then P2 (v3d_tex.c:355-371; since 1.182).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_fetch_offset);
    const p1: Word = .{ .float = @bitCast(per_pixel_mask) };
    const p2: Word = .{ .float = @bitCast(@as(u32, 0x00F0E100)) };
    try testing.expectEqualSlices(Word, &[_]Word{ .{ .texture = 0 }, p1, p2 }, code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmusf, "));
}

test "a texel and a sample of one texture are one unit, the sample's P1 the sampler's and a shadow sample's too" {
    // The fetch's P0 alone, beside the sample's P0 and P1
    // (v3d_tex.c:340-348; since 1.182).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_fetch_sampled);
    try testing.expectEqual(@as(usize, 1), code.sampled().len);
    const sampler: Word = .{ .sampler = .{ .bits = per_pixel_mask } };
    try testing.expectEqualSlices(Word, &[_]Word{ .{ .texture = 0 }, sampler, .{ .texture = 0 } }, code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmus, "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmusf, "));
    // A fetch reads no sampler state, so a comparison in the unit is no
    // other sampler's: a shadow sample of one variable and a fetch of
    // another at its binding are one unit that compares
    // (descriptor_map_add, v3dv_pipeline.c:516-561).
    var aliased: Work = .{};
    const aliased_code = try throughMesa(&aliased, &reference.glslc_fetch_aliased);
    try testing.expectEqual(@as(usize, 1), aliased_code.sampled().len);
    try testing.expect(aliased_code.sampled()[0].compared);
    try testing.expectEqualSlices(Word, &[_]Word{ .{ .texture = 0 }, sampler, .{ .texture = 0 } }, aliased_code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(aliased_code, "tmudref"));
}

test "a texel the helper pixels need writes P1, the constant of the per-pixel mask off; a cube's texel and a MinLod are refused" {
    // An implicit sample at the place the texel gives wants the texel in
    // its helper pixels (nir_opt_load_skip_helpers.c:151-156), so the
    // fetch does not skip them: non_default_p1_config, and with no
    // sampler P1 is the constant of its own bits (v3d_tex.c:312-354;
    // since 1.182).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_fetch_dependent);
    const sampler: Word = .{ .sampler = .{ .bits = per_pixel_mask } };
    try testing.expectEqualSlices(Word, &[_]Word{ .{ .texture = 0 }, .{ .float = 0 }, .{ .texture = 0 }, sampler }, code.stream());
    // A cube is no image a texel is fetched of (OpImageFetch's Dim;
    // v3d_tex.c:376): glslc_fetch's image made a cube.
    var cube = reference.glslc_fetch;
    const image = std.mem.indexOfScalar(u32, &cube, 0x00090019).?;
    try testing.expectEqual(@as(u32, 1), cube[image + 3]);
    cube[image + 3] = 3;
    var cubed: Work = .{};
    try testing.expectError(Error.Body, throughMesa(&cubed, &cube));
    // `look` holds a fetch's image operands to the profile's, as a
    // sample's: its Lod made a MinLod.
    var min_lod = reference.glslc_fetch;
    const fetch = std.mem.indexOfScalar(u32, &min_lod, 0x0007005F).?;
    try testing.expectEqual(@as(u32, 2), min_lod[fetch + 5]);
    min_lod[fetch + 5] = 0x80;
    try testing.expectEqual(spirv.Fault.image_operand_refused, spirv.look(&min_lod, profile).fault);
}

test "a texel in a selection's arm keeps the arm, as any tex instruction does" {
    // block_check_for_allowed_instrs (nir_opt_peephole_select.c:59-326;
    // since 1.182).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_fetch_arm);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .select));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmusf, "));
}

test "a gradient is lower_gradient's level: the size of level 0 made floats, the longer derivative's length, its LOG to TMUB and TMUSLOD" {
    // vtn's txd (spirv_to_nir.c:3441-3448) lowered by lower_txd
    // (vir.c:802; nir_lower_tex.c:855-912): a txs at the integer 0, its
    // i2f32, each derivative times it, fmax of the two fsqrt of fdot -
    // frcp of frsq (`lower_fsqrt`) - and flog2, the txl's lod (:690-704;
    // since 1.183).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_grad_varying);
    const sampler: Word = .{ .sampler = .{ .bits = per_pixel_mask } };
    const width: Word = .{ .texture_size = .{ .field = .width } };
    const height: Word = .{ .texture_size = .{ .field = .height } };
    try testing.expectEqualSlices(Word, &[_]Word{ width, height, .{ .texture = 0 }, sampler }, code.stream());
    var sizes: usize = 0;
    for (work.program()) |each| switch (each.tag) {
        .texture_size => {
            // nir_tex_instr_dest_size's two of a 2D image.
            try testing.expectEqual(Kind.f32x2, each.kind);
            try testing.expect(isSplat(&work, each.from[0], 0.0));
            sizes += 1;
        },
        .sample => {
            try testing.expectEqual(Lookup.lod, each.lookup);
            try testing.expectEqual(Tag.log2, work.steps[each.from[0]].tag);
            try testing.expectEqual(Tag.max, work.steps[work.steps[each.from[0]].a].tag);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), sizes);
    try testing.expectEqual(@as(usize, 2), countOf(code, "shr "));
    try testing.expectEqual(@as(usize, 2), countOf(code, "itof "));
    try testing.expectEqual(@as(usize, 2), countOf(code, "rsqrt "));
    try testing.expectEqual(@as(usize, 2), countOf(code, "recip "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "fmax "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "log "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmub, "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmuslod, "));
    try testing.expectEqual(@as(usize, 0), countOf(code, "mov tmus, "));
    // Four FADDs of the varyings, and one of each dot.
    try testing.expectEqual(@as(usize, 6), countOf(code, "fadd "));
    // glslc_grad's constant derivatives each have a zero, whose product
    // the rules take out: no FADD in either dot, and the 0.01 a uniform.
    var constant: Work = .{};
    const constant_code = try throughMesa(&constant, &reference.glslc_grad);
    const hundredth: Word = .{ .float = @bitCast(@as(f32, 0.01)) };
    try testing.expectEqualSlices(Word, &[_]Word{ width, height, hundredth, .{ .texture = 0 }, sampler }, constant_code.stream());
    try testing.expectEqual(@as(usize, 2), countOf(constant_code, "fadd "));
    try testing.expectEqual(@as(usize, 2), countOf(constant_code, "rsqrt "));
    // The plan's programs compute no size, and refuse the txs.
    var plan: Work = .{};
    try testing.expectError(Error.Samplers, compile(&plan, &reference.glslc_grad_varying));
}

test "a gradient of an array's layer reads the first two sizes, of a 3D texture three, and one with an offset has P2" {
    // lower_gradient's component_mask (nir_lower_tex.c:868-884): an
    // array's layers are no axis a derivative has (since 1.183).
    const sampler: Word = .{ .sampler = .{ .bits = per_pixel_mask } };
    const width: Word = .{ .texture_size = .{ .field = .width } };
    const height: Word = .{ .texture_size = .{ .field = .height } };
    var layers: Work = .{};
    const layers_code = try throughMesa(&layers, &reference.glslc_grad_layers);
    try testing.expectEqualSlices(Word, &[_]Word{ width, height, .{ .texture = 0 }, sampler }, layers_code.stream());
    // The array's three integers made three floats, and two of them
    // taken: every product of a derivative is of one kind.
    var converted: usize = 0;
    for (layers.program()) |each| switch (each.tag) {
        .texture_size => try testing.expectEqual(Kind.f32x3, each.kind),
        .integer => if (each.at == @intFromEnum(Integer.i2f32)) {
            try testing.expectEqual(Kind.f32x3, each.kind);
            converted += 1;
        },
        .mul => {
            const b = layers.steps[each.b].kind;
            try testing.expect(b == each.kind or b == .f32x1);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), converted);
    try testing.expectEqual(@as(usize, 1), countOf(layers_code, "mov tmui, "));
    try testing.expectEqual(@as(usize, 1), countOf(layers_code, "mov tmuslod, "));
    var volume: Work = .{};
    const volume_code = try throughMesa(&volume, &reference.glslc_grad_volume);
    const depth: Word = .{ .texture_size = .{ .field = .depth } };
    try testing.expectEqualSlices(Word, &[_]Word{ width, height, depth, .{ .texture = 0 }, sampler }, volume_code.stream());
    try testing.expectEqual(@as(usize, 3), countOf(volume_code, "shr "));
    try testing.expectEqual(@as(usize, 1), countOf(volume_code, "mov tmur, "));
    try testing.expectEqual(@as(usize, 1), countOf(volume_code, "mov tmuslod, "));
    // The txl keeps the txd's offset (replace_gradient_with_lod, :690-704).
    var offset: Work = .{};
    const offset_code = try throughMesa(&offset, &reference.glslc_grad_offset);
    const p2: Word = .{ .float = @bitCast(@as(u32, 0x00F0E100)) };
    try testing.expectEqualSlices(Word, &[_]Word{ width, height, .{ .texture = 0 }, sampler, p2 }, offset_code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(offset_code, "mov tmuslod, "));
}

test "a shadow sample with a gradient compares at the level the gradient gives" {
    // lower_txd lowers a shadow txd as any (nir_lower_tex.c:1833-1847):
    // TMUDREF, the level to TMUB, TMUSLOD (since 1.183).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_grad_shadow);
    const sampler: Word = .{ .sampler = .{ .bits = per_pixel_mask } };
    const width: Word = .{ .texture_size = .{ .field = .width } };
    const height: Word = .{ .texture_size = .{ .field = .height } };
    try testing.expectEqualSlices(Word, &[_]Word{ width, height, .{ .texture = 0 }, sampler }, code.stream());
    try testing.expectEqual(@as(usize, 1), code.sampled().len);
    try testing.expect(code.sampled()[0].compared);
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmudref, "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmub, "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmuslod, "));
}

test "two gradients of one texture read its size once, the two txs one by nir_opt_cse" {
    // Each txd's lowering makes a txs at level 0 of its texture
    // (nir_get_texture_size, nir_builtin_builder.c:459-466), and
    // nir_opt_cse makes the second the first (nir_to_vir.c:2265; since
    // 1.183).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_grad_twice);
    const sampler: Word = .{ .sampler = .{ .bits = per_pixel_mask } };
    const width: Word = .{ .texture_size = .{ .field = .width } };
    const height: Word = .{ .texture_size = .{ .field = .height } };
    try testing.expectEqualSlices(Word, &[_]Word{ width, height, .{ .texture = 0 }, sampler, .{ .texture = 0 }, sampler }, code.stream());
    try testing.expectEqual(@as(usize, 2), countOf(code, "shr "));
    try testing.expectEqual(@as(usize, 2), countOf(code, "log "));
    try testing.expectEqual(@as(usize, 2), countOf(code, "mov tmuslod, "));
}

/// How many of a stream's words are a texture's first word: one for each
/// sample the program takes.
fn texturesOf(code: Code) usize {
    var count: usize = 0;
    for (code.stream()) |word| if (word == .texture) {
        count += 1;
    };
    return count;
}

test "two samples of one unit, lookup and coordinate are one tex, at an implicit level, at an explicit one, of a texel and of a shadow" {
    // nir_opt_cse (nir_to_vir.c:2265) of tex instructions
    // (instr_can_rewrite, nir_instr_set.c:47-52), whose op, texel offset
    // and sources nir_instrs_equal compares (:695-723; pack_tex,
    // :297-327), and which spirv-opt leaves two (since 1.185).
    const cases = .{
        .{ &reference.glslc_sample_twice, "mov tmus, ", Lookup.implicit, Tag.sample },
        .{ &reference.glslc_sample_twice_lod, "mov tmuslod, ", Lookup.lod, Tag.sample },
        .{ &reference.glslc_sample_twice_fetch, "mov tmusf, ", Lookup.fetch, Tag.sample },
        .{ &reference.glslc_sample_twice_shadow, "mov tmudref, ", Lookup.implicit, Tag.sample_compared },
    };
    inline for (cases) |case| {
        var work: Work = .{};
        const code = try throughMesa(&work, case[0]);
        try testing.expectEqual(@as(usize, 1), stepsOf(&work, .sample) + stepsOf(&work, .sample_compared));
        try testing.expectEqual(@as(u32, 1), work.sample_count);
        try testing.expectEqual(@as(usize, 1), texturesOf(code));
        try testing.expectEqual(@as(usize, 1), countOf(code, case[1]));
        for (work.program()) |each| if (each.tag == case[3]) {
            try testing.expectEqual(case[2], each.lookup);
        };
    }
    // The shadow's coordinate goes in TMUS after its reference.
    var shadow: Work = .{};
    try testing.expectEqual(@as(usize, 1), countOf(try throughMesa(&shadow, &reference.glslc_sample_twice_shadow), "mov tmus, "));
    // A coordinate times 1.0 is the coordinate once nir_opt_algebraic has
    // made the fmul an fcanonicalize and taken that out
    // (nir_opt_algebraic.py:292, :161-163), and the two samples one in the
    // loop's next nir_opt_cse.
    var unit: Work = .{};
    const code = try throughMesa(&unit, &reference.glslc_sample_twice_one);
    try testing.expectEqual(@as(usize, 1), stepsOf(&unit, .sample));
    try testing.expectEqual(@as(usize, 0), stepsOf(&unit, .mul));
    try testing.expectEqual(@as(usize, 1), texturesOf(code));
}

test "samples whose coordinate, texel offset or lookup are not another's are each a tex of their own" {
    // nir_instrs_equal's tex (nir_instr_set.c:695-723): the colour's
    // first two either way about are two coordinates; a texel away, and
    // at level 0, the same coordinate in a txb, a tex with an offset and
    // a txl (since 1.185).
    var swapped: Work = .{};
    const two = try throughMesa(&swapped, &reference.glslc_sample_swapped);
    try testing.expectEqual(@as(usize, 2), stepsOf(&swapped, .sample));
    try testing.expectEqual(@as(usize, 2), texturesOf(two));
    try testing.expectEqual(@as(usize, 2), countOf(two, "mov tmus, "));
    var apart: Work = .{};
    const three = try throughMesa(&apart, &reference.glslc_sample_twice_apart);
    try testing.expectEqual(@as(usize, 3), stepsOf(&apart, .sample));
    try testing.expectEqual(@as(u32, 3), apart.sample_count);
    try testing.expectEqual(@as(usize, 3), texturesOf(three));
    try testing.expectEqual(@as(usize, 2), countOf(three, "mov tmus, "));
    try testing.expectEqual(@as(usize, 1), countOf(three, "mov tmuslod, "));
    var moved: usize = 0;
    for (apart.program()) |each| if (each.tag == .sample) {
        if (each.offsets[0] == 1) {
            try testing.expectEqual(Lookup.implicit, each.lookup);
            try testing.expectEqualSlices(i8, &.{ 1, 0, 0 }, &each.offsets);
            moved += 1;
        } else try testing.expectEqualSlices(i8, &.{ 0, 0, 0 }, &each.offsets);
    };
    try testing.expectEqual(@as(usize, 1), moved);
    // A bias and a level of the same value are a txb and a txl.
    var biased: Work = .{};
    const lookups = try throughMesa(&biased, &reference.glslc_sample_bias_lod);
    try testing.expectEqual(@as(usize, 2), stepsOf(&biased, .sample));
    try testing.expectEqual(@as(usize, 2), texturesOf(lookups));
    var seen: [2]bool = @splat(false);
    for (biased.program()) |each| if (each.tag == .sample) switch (each.lookup) {
        .bias => seen[0] = true,
        .lod => seen[1] = true,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual([2]bool{ true, true }, seen);
}

test "a sample an arm repeats of one before the selection is gone from the arm nir_opt_peephole_select counts: the selection is flattened" {
    // v3d's loop runs nir_opt_cse before nir_opt_peephole_select
    // (nir_to_vir.c:2265, :2269-2279): the arm's tex is the one before
    // it, and the arm's fmuls are bcsels (since 1.185).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_sample_twice_arm);
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(u8, 0), work.kept_count);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .sample));
    try testing.expectEqual(@as(usize, 4), stepsOf(&work, .select));
    try testing.expectEqual(@as(usize, 1), texturesOf(code));
    try testing.expectEqual(@as(usize, 0), countOf(code, "bu."));
    // Each float is the product where the colour's blue is under 0.5, the
    // sample where it is not: the product of the one sample and its red.
    var taken_at: u16 = none;
    for (work.program(), 0..) |each, k| if (each.tag == .sample) {
        taken_at = @intCast(k);
    };
    var parts: [4]bool = @splat(false);
    for (work.program()) |each| if (each.tag == .select) {
        const taken = work.steps[each.b];
        const not = work.steps[each.from[0]];
        try testing.expectEqual(Tag.component, taken.tag);
        try testing.expectEqual(Tag.component, not.tag);
        try testing.expectEqual(taken_at, not.a);
        try testing.expectEqual(taken.at, not.at);
        const product = work.steps[taken.a];
        try testing.expectEqual(Tag.mul, product.tag);
        try testing.expectEqual(taken_at, product.a);
        try testing.expectEqual(Tag.component, work.steps[product.b].tag);
        try testing.expectEqual(taken_at, work.steps[product.b].a);
        try testing.expectEqual(@as(u32, 0), work.steps[product.b].at);
        try testing.expectEqual(Tag.compare, work.steps[each.a].tag);
        parts[taken.at] = true;
    };
    try testing.expectEqual([4]bool{ true, true, true, true }, parts);
    // In an arm of an arm too: both are flattened, the outer arm's
    // product by 2.0 and the inner's by the green of the one sample.
    var nested: Work = .{};
    const flat = try throughMesa(&nested, &reference.glslc_sample_twice_nested);
    try testing.expectEqual(@as(usize, 0), stepsOf(&nested, .begin_if));
    try testing.expectEqual(@as(usize, 1), stepsOf(&nested, .sample));
    try testing.expectEqual(@as(usize, 8), stepsOf(&nested, .select));
    try testing.expectEqual(@as(usize, 0), countOf(flat, "bu."));
    // A selection that asks not to be flattened is flattened under a
    // limit of 0 (get_options_for_if, nir_opt_peephole_select.c:329-345),
    // which an arm of moves alone is under (:251-264): the arms' sample,
    // size and levels are the ones before them, and none is left.
    var unflat: Work = .{};
    const asked = try throughMesa(&unflat, &reference.glslc_tex_arms_dont_flatten);
    try testing.expectEqual(@as(usize, 0), stepsOf(&unflat, .begin_if));
    try testing.expectEqual(@as(usize, 1), stepsOf(&unflat, .sample));
    try testing.expectEqual(@as(usize, 1), stepsOf(&unflat, .texture_size));
    try testing.expectEqual(@as(usize, 1), stepsOf(&unflat, .texture_levels));
    try testing.expectEqual(@as(usize, 0), countOf(asked, "bu."));
}

test "a sample an arm repeats of one in an arm of another selection, or of the other arm, keeps the selection a branch" {
    // nir_instr_set takes only an equal instruction that dominates
    // (nir_instr_set_add_or_rewrite, nir_instr_set.c): one in an arm of
    // a kept selection does not dominate the next selection's arm, nor
    // one arm's the other's, and each arm keeps its tex (since 1.185).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_sample_kept_then_arm);
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(u8, 2), work.kept_count);
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .sample));
    try testing.expectEqual(@as(usize, 2), countOf(code, "mov tmus, "));
    var both: Work = .{};
    const arms = try throughMesa(&both, &reference.glslc_sample_both_arms);
    try testing.expectEqual(@as(usize, 1), stepsOf(&both, .begin_if));
    try testing.expectEqual(@as(u8, 1), both.kept_count);
    try testing.expectEqual(@as(usize, 2), stepsOf(&both, .sample));
    try testing.expectEqual(@as(usize, 2), countOf(arms, "mov tmus, "));
    // An arm's sample a texel away from the one before is another tex.
    var away: Work = .{};
    const offset = try throughMesa(&away, &reference.glslc_sample_arm_offset);
    try testing.expectEqual(@as(usize, 1), stepsOf(&away, .begin_if));
    try testing.expectEqual(@as(u8, 1), away.kept_count);
    try testing.expectEqual(@as(usize, 2), stepsOf(&away, .sample));
    try testing.expectEqual(@as(usize, 2), texturesOf(offset));
    // A shadow sample, one at a level and a query of the levels alone in
    // an arm are each a tex there, and each arm is kept.
    var alone: Work = .{};
    const kept = try throughMesa(&alone, &reference.glslc_tex_arms_kept);
    try testing.expectEqual(@as(usize, 3), stepsOf(&alone, .begin_if));
    try testing.expectEqual(@as(u8, 3), alone.kept_count);
    try testing.expectEqual(@as(usize, 2), stepsOf(&alone, .sample_compared));
    try testing.expectEqual(@as(usize, 1), stepsOf(&alone, .texture_levels));
    try testing.expectEqual(@as(usize, 2), countOf(kept, "mov tmudref, "));
}

test "an fabs of an fneg is the fabs of what it negates, a float or a vector at a time: the V3D's ABS unpack of it, and no XOR" {
    // (('fabs', ('fneg', a)), ('fabs', a)) (nir_opt_algebraic.py:232), of
    // each float nir_lower_alu_to_scalar makes an instruction of
    // (nir_to_vir.c:2259; since 1.186). The vector of the negated alpha
    // and the red is two fabs, the second the red's own.
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_abs_negated);
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .negate));
    try testing.expectEqual(@as(usize, 3), stepsOf(&work, .abs));
    try testing.expectEqual(@as(usize, 0), countOf(code, "xor "));
    try testing.expectEqual(@as(usize, 0), code.stream().len);
    for (work.program()) |each| if (each.tag == .abs) {
        for (0..work.steps[each.a].kind.parts()) |k| {
            try testing.expectEqual(Tag.input, work.steps[partOf(&work, each.a, @intCast(k)).step].tag);
        }
    };
    const color = [4]f32{ -0.25, 0.5, -0.75, 1.0 };
    try testing.expectEqual([4]f32{ 0.25, 0.75, 1.0, 0.75 }, evaluatedOf(&work, work.stored, color, 0));
    // The fabs nir_normalize_cubemap_coords takes of each float of a
    // direction (nir_normalize_cubemap_coords.c:30-55) is of the float
    // itself where the direction negates it, and the two fnegs are the
    // direction's alone.
    var cube: Work = .{};
    const sky = try throughMesa(&cube, &reference.glslc_cube_negated);
    try testing.expectEqual(@as(usize, 2), stepsOf(&cube, .negate));
    try testing.expectEqual(@as(usize, 3), stepsOf(&cube, .abs));
    try testing.expectEqual(@as(usize, 2), countOf(sky, "xor "));
    for (cube.program()) |each| if (each.tag == .abs) {
        try testing.expectEqual(Kind.f32x1, each.kind);
        try testing.expectEqual(Tag.input, cube.steps[partOf(&cube, each.a, 0).step].tag);
    };
}

/// glslc_imod's OpSMod made OpSRem, which glslc makes of no GLSL.
const glslc_irem = reopcoded(&reference.glslc_imod, .s_mod, 0, .s_rem);

/// An integer a quarter off, away from zero: what a float of the colour
/// is made, scaled, for the conversion towards zero to give the integer.
fn quarterOff(x: i32) f32 {
    return @as(f32, @floatFromInt(x)) + if (x < 0) @as(f32, -0.25) else 0.25;
}

test "a 32-bit division or remainder is nir_lower_idiv's: a Newton step of the reciprocal, the high words of four 16-bit products, two steps of the remainder, worked out on the host for every pair the colour gives" {
    // emit_udiv and emit_idiv (nir_lower_idiv.c:32-94; vir.c:2019-2022)
    // and the umul_high nir_lower_alu lowers (nir_lower_alu.c:119-158;
    // `lower_mul_high`, v3dv_pipeline.c:201; since 1.187).
    const cases = .{
        .{ &reference.glslc_udiv, Division.udiv },
        .{ &reference.glslc_umod, Division.umod },
        .{ &reference.glslc_idiv, Division.idiv },
        .{ &reference.glslc_imod, Division.imod },
        .{ &glslc_irem, Division.irem },
    };
    inline for (cases) |case| {
        var work: Work = .{};
        const code = try throughMesa(&work, case[0]);
        // Ten 32-bit multiplies, each MULTOP and UMUL24 (vir_UMUL): four
        // in each umul_high, the reciprocal's times the negated divisor,
        // and the quotient's times the divisor.
        try testing.expectEqual(@as(usize, 10), countOf(code, "umul24 "));
        try testing.expectEqual(@as(usize, 10), countOf(code, "multop "));
        try testing.expectEqual(@as(usize, 1), countOf(code, "recip "));
        const signed = case[1] == .idiv or case[1] == .imod or case[1] == .irem;
        const low: i32 = if (signed) -100 else 0;
        var n: i32 = low;
        while (n <= 100) : (n += 1) {
            var d: i32 = low;
            while (d <= 100) : (d += 1) {
                if (d == 0) continue;
                const color: [4]f32 = if (signed)
                    .{ (quarterOff(n) + 100.0) / 200.0, (quarterOff(d) + 100.0) / 200.0, 0, 0 }
                else
                    .{ quarterOff(n) / 100.0, quarterOff(d) / 100.0, 0, 0 };
                const x: f32 = if (signed) color[0] * 200.0 - 100.0 else color[0] * 100.0;
                const y: f32 = if (signed) color[1] * 200.0 - 100.0 else color[1] * 100.0;
                const numer: i32 = @intFromFloat(x);
                const denom: i32 = @intFromFloat(y);
                if (denom == 0) continue;
                const expected: i32 = switch (case[1]) {
                    .udiv => @intCast(@as(u32, @intCast(numer)) / @as(u32, @intCast(denom))),
                    .umod => @intCast(@as(u32, @intCast(numer)) % @as(u32, @intCast(denom))),
                    .idiv => @divTrunc(numer, denom),
                    .irem => @rem(numer, denom),
                    .imod => @mod(numer, denom),
                };
                const found = evaluatedOf(&work, work.stored, color, 0)[0];
                try testing.expectEqual(@as(f32, @floatFromInt(expected)), found);
            }
        }
    }
}

test "nir_lower_idiv's lowering of two words is the quotient or remainder of every sign and size, the largest and the most negative too" {
    // dividedOf of two components of the varying, its floats the
    // integers' bits, worked out on the host with an exact reciprocal:
    // the integer arithmetic of emit_udiv and emit_idiv alone
    // (nir_lower_idiv.c:32-94; since 1.187). INT_MIN over -1 wraps, as
    // emit_idiv makes it: SPIR-V leaves it undefined, and NIR's opcode
    // folds it to 0 (nir_opcodes.py:869).
    const values = [_]u32{ 0, 1, 2, 3, 7, 10, 255, 256, 65535, 65536, 65537, 1 << 24, 0x7FFF_FFFF, 0x8000_0000, 0x8000_0001, 0xFFFF_FFFE, 0xFFFF_FFFF, 123456789, 0xDEAD_BEEF };
    const ops = [_]Division{ .udiv, .umod, .idiv, .irem, .imod };
    for (ops) |op| for (values) |numer| for (values) |denom| {
        if (denom == 0) continue;
        var work: Work = .{};
        const varying = try put(&work, .{ .tag = .input, .kind = .f32x4 });
        const a = try floatStep(&work, partOf(&work, varying, 0));
        const b = try floatStep(&work, partOf(&work, varying, 1));
        const result = try dividedOf(&work, op, a, b, try DivisionWords.of(&work, op));
        const color = [4]f32{ @bitCast(numer), @bitCast(denom), 0, 0 };
        const found: u32 = @bitCast(evaluatedOf(&work, result, color, 0)[0]);
        const n: i32 = @bitCast(numer);
        const d: i32 = @bitCast(denom);
        const expected: u32 = switch (op) {
            .udiv => numer / denom,
            .umod => numer % denom,
            .idiv => if (n == std.math.minInt(i32) and d == -1) numer else @bitCast(@divTrunc(n, d)),
            .irem => if (d == -1) 0 else @bitCast(@rem(n, d)),
            .imod => if (d == -1) 0 else @bitCast(@mod(n, d)),
        };
        testing.expectEqual(expected, found) catch |err| {
            std.debug.print("{s} of {x} and {x}\n", .{ @tagName(op), numer, denom });
            return err;
        };
    };
}

test "a division of two vectors of two is a lowering a float, of one set of constants: each float its own quotient" {
    // The OpUDiv of uvec2s nir_lower_alu_to_scalar splits
    // (v3dv_pipeline.c:404), each float lowered (since 1.187).
    // glslc_udiv_swapped's v / v.yx, and glslc_udiv_vector's v.xy / v.zw
    // of a uvec4, its blue and alpha here its green and red.
    inline for (.{ &reference.glslc_udiv_swapped, &reference.glslc_udiv_vector }) |module| {
        var work: Work = .{};
        const code = try throughMesa(&work, module);
        try testing.expectEqual(@as(usize, 20), countOf(code, "umul24 "));
        try testing.expectEqual(@as(usize, 2), countOf(code, "recip "));
        var n: i32 = 1;
        while (n <= 100) : (n += 1) {
            var d: i32 = 1;
            while (d <= 100) : (d += 1) {
                const color = [4]f32{ quarterOff(n) / 100.0, quarterOff(d) / 100.0, quarterOff(d) / 100.0, quarterOff(n) / 100.0 };
                const x: u32 = @intFromFloat(color[0] * 100.0);
                const y: u32 = @intFromFloat(color[1] * 100.0);
                if (x == 0 or y == 0) continue;
                const found = evaluatedOf(&work, work.stored, color, 0);
                try testing.expectEqual(@as(f32, @floatFromInt(x / y)), found[0]);
                try testing.expectEqual(@as(f32, @floatFromInt(y / x)), found[1]);
            }
        }
    }
}

/// What Mesa's lowerings make of a division or remainder of two words,
/// SPIR-V's undefined ones included: 0 by 0 (nir_opt_idiv_const.c:33,
/// :61, :79, :112, :132), and the most negative by -1 itself, an
/// overflow's wrap.
fn dividedWord(op: Division, numer: u32, denom: u32) u32 {
    if (denom == 0) return 0;
    const n: i32 = @bitCast(numer);
    const d: i32 = @bitCast(denom);
    return switch (op) {
        .udiv => numer / denom,
        .umod => numer % denom,
        .idiv => if (n == std.math.minInt(i32) and d == -1) numer else @bitCast(@divTrunc(n, d)),
        .irem => if (d == -1) 0 else @bitCast(@rem(n, d)),
        .imod => if (d == -1) 0 else @bitCast(@mod(n, d)),
    };
}

test "glslc's divisions by constants are multiplies by magic numbers, shifts and masks, no reciprocal, worked out on the host" {
    // nir_opt_idiv_const's (vir.c:2018) and nir_opt_algebraic's
    // (nir_opt_algebraic.py:200-217), nir_opt_cse making the two
    // quotients by 7 one (since 1.188).
    const Case = struct { module: []const u32, products: usize, signed: bool };
    const cases = [_]Case{
        // By 7, its remainder the quotient times 7; by 4 and 16 a shift
        // and a mask.
        .{ .module = &reference.glslc_udiv_constants, .products = 5, .signed = false },
        // By -5, 6 (an irem of the quotient by 6) and 8 (an imul by the
        // isign), and -4 a bcsel of an ior.
        .{ .module = &reference.glslc_idiv_constants, .products = 10, .signed = true },
        .{ .module = &reference.glslc_idiv_constant, .products = 4, .signed = true },
        // Of glslc_udiv_part's two divisions the first lowered by
        // nir_lower_idiv, the second by 3.
        .{ .module = &reference.glslc_udiv_part, .products = 14, .signed = false },
    };
    for (cases, 0..) |case, which| {
        var work: Work = .{};
        const code = try throughMesa(&work, case.module);
        try testing.expectEqual(case.products, countOf(code, "umul24 "));
        try testing.expectEqual(@as(usize, if (which == 3) 1 else 0), countOf(code, "recip "));
        const low: i32 = if (case.signed) -100 else 0;
        var x: i32 = low;
        while (x <= 100) : (x += 1) {
            var y: i32 = 1;
            while (y <= (if (which == 3) @as(i32, 100) else 1)) : (y += 1) {
                const color: [4]f32 = if (case.signed)
                    .{ (quarterOff(x) + 100.0) / 200.0, 0.5, 0, 0 }
                else
                    .{ quarterOff(x) / 100.0, quarterOff(y) / 100.0, 0, 0 };
                const n: i32 = @intFromFloat(if (case.signed) color[0] * 200.0 - 100.0 else color[0] * 100.0);
                const m: i32 = @intFromFloat(color[1] * 100.0);
                const expected: [4]f32 = switch (which) {
                    0 => .{ @floatFromInt(@divTrunc(n, 7)), @floatFromInt(@rem(n, 7)), @floatFromInt(@divTrunc(n, 4)), @floatFromInt(@rem(n, 16)) },
                    1 => .{ @floatFromInt(@divTrunc(n, -5)), @floatFromInt(@mod(n, 6)), @floatFromInt(@divTrunc(n, 8)), @floatFromInt(-@mod(-n, 4)) },
                    2 => .{ @floatFromInt(@divTrunc(n, 3)), 0, 0, 1 },
                    else => .{ @floatFromInt(@divTrunc(n, m)), @floatFromInt(@divTrunc(m, 3)), 0, 1 },
                };
                try testing.expectEqual(expected, evaluatedOf(&work, work.stored, color, 0));
            }
        }
    }
}

test "Hacker's Delight's magic numbers are util_compute_fast_udiv_info's and _sdiv_info's" {
    // Hacker's Delight, figures 10-1 and 10-2, of 32 bits; an odd divisor
    // whose round-up multiplier would take 33 bits is the round-down one
    // and an increment (util/fast_idiv_by_const.c:146-151; since 1.188).
    try testing.expectEqual(FastUdivInfo{ .multiplier = 0xAAAA_AAAB, .pre_shift = 0, .post_shift = 1, .increment = 0 }, fastUdivInfo(3, 32, 32));
    try testing.expectEqual(FastUdivInfo{ .multiplier = 0xCCCC_CCCD, .pre_shift = 0, .post_shift = 2, .increment = 0 }, fastUdivInfo(5, 32, 32));
    try testing.expectEqual(FastUdivInfo{ .multiplier = 0xAAAA_AAAB, .pre_shift = 0, .post_shift = 2, .increment = 0 }, fastUdivInfo(6, 32, 32));
    try testing.expectEqual(@as(u32, 1), fastUdivInfo(7, 32, 32).increment);
    // 641 divides 2^32 + 1: 6700417, of no shift, the first exponent's.
    try testing.expectEqual(FastUdivInfo{ .multiplier = 6700417, .pre_shift = 0, .post_shift = 0, .increment = 0 }, fastUdivInfo(641, 32, 32));
    try testing.expectEqual(FastSdivInfo{ .multiplier = 0x5555_5556, .shift = 0 }, fastSdivInfo(3, 32));
    try testing.expectEqual(FastSdivInfo{ .multiplier = 0x6666_6667, .shift = 1 }, fastSdivInfo(5, 32));
    try testing.expectEqual(FastSdivInfo{ .multiplier = @as(i32, @bitCast(@as(u32, 0x9249_2493))), .shift = 2 }, fastSdivInfo(7, 32));
    try testing.expectEqual(FastSdivInfo{ .multiplier = @as(i32, @bitCast(@as(u32, 0x9999_9999))), .shift = 1 }, fastSdivInfo(-5, 32));
    try testing.expectEqual(FastSdivInfo{ .multiplier = 0x6DB6_DB6D, .shift = 2 }, fastSdivInfo(-7, 32));
}

test "five divisions by constants and their checks are more steps than the tables of 128 held, and each program is right for every integer of the colour" {
    // The programs FacetBoth 1.53 split in four, at 142 and 178 steps
    // before their dead ones went (since 1.189).
    const modules = [_]struct { words: []const u32, products: usize }{
        .{ .words = &reference.glslc_udiv_many, .products = 18 },
        .{ .words = &reference.glslc_idiv_many, .products = 13 },
    };
    for (modules) |module| {
        var work: Work = .{};
        const code = try throughMesa(&work, module.words);
        try testing.expectEqual(@as(usize, 0), countOf(code, "recip "));
        try testing.expectEqual(module.products, countOf(code, "umul24 "));
        var x: u32 = 0;
        while (x < 256) : (x += 1) {
            var y: u32 = 0;
            while (y < 256) : (y += 1) {
                const color = [4]f32{ (@as(f32, @floatFromInt(x)) + 0.25) / 255.0, (@as(f32, @floatFromInt(y)) + 0.25) / 255.0, 0, 0 };
                try testing.expectEqual([4]f32{ color[0], 1.0, color[1], 1.0 }, evaluatedOf(&work, work.stored, color, 0));
            }
        }
    }
}

test "an unsigned division by a word above 2^31 is a b2i32 of whether the dividend is as large, or of the largest word that it is it: no multiply" {
    // build_udiv (nir_opt_idiv_const.c:36-39), the quotient 0 or 1
    // (since 1.188).
    for ([_]u32{ 0x8000_0001, 3000000000, 0xFFFF_FFF0, 0xFFFF_FFFF }) |d| {
        var work: Work = .{};
        const varying = try put(&work, .{ .tag = .input, .kind = .f32x4 });
        const n = try floatStep(&work, partOf(&work, varying, 0));
        const result = try constantDividedOf(&work, .udiv, n, d);
        try testing.expect(isIntegerOp(work.steps[result], .b2i32));
        try testing.expectEqual(@as(usize, 0), integerOpsOf(&work, .imul));
        const which = work.steps[work.steps[result].a];
        try testing.expectEqual(if (d == 0xFFFF_FFFF) Comparison.int_equal else Comparison.uint_greater_equal, @as(Comparison, @enumFromInt(which.at)));
    }
}

test "a division or remainder by a constant word is nir_opt_algebraic's or nir_opt_idiv_const's, worked out for every sign and size of both" {
    // constantDividedOf of a component of the varying, its float the
    // dividend's bits: the rules of 1, -1 and powers of two, and
    // nir_opt_idiv_const's multiply by the magic number and its cases of
    // 0, the largest word and the most negative. nir_opt_idiv_const's own
    // build_ of each divisor too, its cases of 1, -1 and powers of two
    // those the rules leave it none of (since 1.188).
    const numers = [_]u32{ 0, 1, 2, 3, 6, 7, 10, 255, 1000, 65535, 65536, 1 << 24, 123456789, 0x7FFF_FFFE, 0x7FFF_FFFF, 0x8000_0000, 0x8000_0001, 0xDEAD_BEEF, 0xFFFF_FFF0, 0xFFFF_FFFE, 0xFFFF_FFFF };
    const denoms = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 25, 100, 641, 1000, 65535, 65536, 65537, 0x7FFF_FFFF, 0x8000_0000, 0x8000_0001, 0xFFFF_FFF0, 0xFFFF_FFFE, 0xFFFF_FFFF, 0xFFFF_FFFD, 0xFFFF_FFFC, 0xFFFF_FFFB, 0xFFFF_FFFA, 0xFFFF_FFF9, 0xFFFF_FFF8, 0xFFFF_FF9C, 0xFFFF_0000, 0xC000_0000, 0x4000_0000, 0x5555_5555, 14, 28, 56, 0x8000_0002, 0xFFFF_FFF2 };
    const ops = [_]Division{ .udiv, .umod, .idiv, .irem, .imod };
    for (ops) |op| for (denoms) |denom| for (0..2) |alone| {
        var work: Work = .{};
        const varying = try put(&work, .{ .tag = .input, .kind = .f32x4 });
        const n = try floatStep(&work, partOf(&work, varying, 0));
        const result = if (alone == 0) try constantDividedOf(&work, op, n, denom) else switch (op) {
            .udiv => try udivByConstant(&work, n, denom),
            .umod => try umodByConstant(&work, n, denom),
            .idiv => try idivByConstant(&work, n, @bitCast(denom)),
            .irem => try iremByConstant(&work, n, @bitCast(denom)),
            .imod => try imodByConstant(&work, n, @bitCast(denom)),
        };
        for (numers) |numer| {
            const color = [4]f32{ @bitCast(numer), 0, 0, 0 };
            const found: u32 = @bitCast(evaluatedOf(&work, result, color, 0)[0]);
            testing.expectEqual(dividedWord(op, numer, denom), found) catch |err| {
                std.debug.print("{s} of {x} by {x}, alone {d}\n", .{ @tagName(op), numer, denom, alone });
                return err;
            };
        }
    };
}

test "a cube's gradient is lower_gradient_cube_map's level: the face's quotient rule, -1 plus half the LOG of L times L times M, to TMUB and TMUSCM" {
    // nir_lower_tex.c:707-852 of the coordinate
    // nir_normalize_cubemap_coords made (v3dv_pipeline.c:406; since
    // 1.184).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_grad_cube);
    const sampler: Word = .{ .sampler = .{ .bits = per_pixel_mask } };
    const width: Word = .{ .texture_size = .{ .field = .width } };
    const minus_one: Word = .{ .float = -1.0 };
    const p2: Word = .{ .float = @bitCast(@as(u32, 0x00F00002)) };
    // L is the width alone: the height the i2f32 makes is read by
    // nothing (:840).
    try testing.expectEqualSlices(Word, &[_]Word{ width, minus_one, .{ .texture = 0 }, sampler, p2 }, code.stream());
    var levels: usize = 0;
    for (work.program()) |each| if (each.tag == .sample) {
        try testing.expectEqual(Lookup.lod, each.lookup);
        const lod = work.steps[each.from[0]];
        try testing.expectEqual(Tag.add, lod.tag);
        try testing.expect(isSplat(&work, lod.a, -1.0));
        const halved = work.steps[lod.b];
        try testing.expectEqual(Tag.mul, halved.tag);
        try testing.expect(isSplat(&work, halved.a, 0.5));
        try testing.expectEqual(Tag.log2, work.steps[halved.b].tag);
        levels += 1;
    };
    try testing.expectEqual(@as(usize, 1), levels);
    try testing.expectEqual(@as(usize, 1), countOf(code, "shr "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "itof "));
    // The normalization's reciprocal and Q's z's.
    try testing.expectEqual(@as(usize, 2), countOf(code, "recip "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "log "));
    try testing.expectEqual(@as(usize, 0), countOf(code, "rsqrt "));
    // The two derivatives' first two, each less tmp times its z.
    try testing.expectEqual(@as(usize, 4), countOf(code, "fsub "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmub, "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmuscm, "));
    // A shadow cube's gradient is lowered as any (:1833-1847), and
    // compares at the level.
    var shadow: Work = .{};
    const shadow_code = try throughMesa(&shadow, &reference.glslc_grad_cube_shadow);
    try testing.expect(shadow_code.sampled()[0].compared);
    try testing.expectEqual(@as(usize, 1), countOf(shadow_code, "mov tmudref, "));
    try testing.expectEqual(@as(usize, 1), countOf(shadow_code, "mov tmuscm, "));
    try testing.expectEqual(@as(usize, 1), countOf(shadow_code, "log "));
}

/// The floats a step comes to, worked out on the host for a test: of a
/// program whose one varying is `color` and whose texture is `width`
/// texels wide at level 0, as far as a gradient's level and a division
/// read them. A bool is 1.0 or 0.0, an integer its bits (since 1.184).
/// The steps are worked out once each, in the program's order, as a
/// division reads its values many times over (since 1.187).
fn evaluatedOf(work: *const Work, at: u16, color: [4]f32, width: i32) [4]f32 {
    var values: [most_steps]?[4]f32 = @splat(null);
    for (0..at + 1) |k| values[k] = evaluatedStep(work, &values, @intCast(k), color, width);
    return values[at] orelse @panic("a step the host does not work out");
}

/// One step's floats, of the steps before it in `values`: none where
/// the host has no rule for its tag, which a step read panics on.
fn evaluatedStep(work: *const Work, values: *const [most_steps]?[4]f32, at: u16, color: [4]f32, width: i32) ?[4]f32 {
    const each = work.steps[at];
    const parts = each.kind.parts();
    const of = struct {
        fn read(all: *const [most_steps]?[4]f32, step_at: u16) [4]f32 {
            return all[step_at] orelse @panic("a step read before it is worked out");
        }
    }.read;
    var out: [4]f32 = @splat(0);
    switch (each.tag) {
        .input => out = color,
        .constant => for (0..parts) |k| {
            out[k] = work.pool[each.at + k];
        },
        .component => out[0] = of(values, each.a)[each.at],
        .construct => for (0..parts) |k| {
            out[k] = of(values, each.from[k])[each.part[k]];
        },
        .texture_size => for (0..parts) |k| {
            out[k] = @bitCast(width);
        },
        .integer => {
            const x = of(values, each.a);
            const op: Integer = @enumFromInt(each.at);
            const y = if (op.unary()) x else of(values, each.b);
            const single = !op.unary() and work.steps[each.b].kind == .f32x1;
            for (0..parts) |k| {
                const u: u32 = @bitCast(x[k]);
                const v: u32 = @bitCast(y[if (single) 0 else k]);
                const i: i32 = @bitCast(u);
                const j: i32 = @bitCast(v);
                out[k] = switch (op) {
                    .i2f32 => @floatFromInt(i),
                    .u2f32 => @floatFromInt(u),
                    .f2i32 => @bitCast(std.math.lossyCast(i32, x[k])),
                    .f2u32 => @bitCast(std.math.lossyCast(u32, x[k])),
                    // A bool here is 1.0 or 0.0, the V3D's ~0 or 0.
                    .b2f32 => if (x[k] != 0) 1.0 else 0.0,
                    .b2i32 => @bitCast(@as(u32, if (x[k] != 0) 1 else 0)),
                    else => @bitCast(switch (op) {
                        .iadd => u +% v,
                        .isub => u -% v,
                        .imul => u *% v,
                        .ineg => 0 -% u,
                        .iabs => @as(u32, @bitCast(if (i < 0) 0 -% i else i)),
                        .imin => @as(u32, @bitCast(@min(i, j))),
                        .imax => @as(u32, @bitCast(@max(i, j))),
                        .umin => @min(u, v),
                        .umax => @max(u, v),
                        .ishl => u << @intCast(v & 31),
                        .ishr => @as(u32, @bitCast(i >> @intCast(v & 31))),
                        .ushr => u >> @intCast(v & 31),
                        .iand => u & v,
                        .ior => u | v,
                        .ixor => u ^ v,
                        .inot => ~u,
                        else => @panic("an integer operation the host does not work out"),
                    }),
                };
            }
        },
        .abs, .negate, .recip, .log2, .floor => {
            const x = of(values, each.a);
            for (0..parts) |k| out[k] = switch (each.tag) {
                .abs => @abs(x[k]),
                .negate => -x[k],
                .recip => 1.0 / x[k],
                .floor => @floor(x[k]),
                else => @log2(x[k]),
            };
        },
        .add, .sub, .mul, .max => {
            const x = of(values, each.a);
            const y = of(values, each.b);
            const single = work.steps[each.b].kind == .f32x1;
            for (0..parts) |k| {
                const b = y[if (single) 0 else k];
                out[k] = switch (each.tag) {
                    .add => x[k] + b,
                    .sub => x[k] - b,
                    .mul => x[k] * b,
                    else => @max(x[k], b),
                };
            }
        },
        .compare => {
            const x = of(values, each.a)[0];
            const y = of(values, each.b)[0];
            const u: u32 = @bitCast(x);
            const v: u32 = @bitCast(y);
            const holds = switch (@as(Comparison, @enumFromInt(each.at))) {
                .less => x < y,
                .greater => x > y,
                .equal => x == y,
                .not_equal => x != y,
                .greater_equal => x >= y,
                .less_equal => x <= y,
                .int_equal => u == v,
                .int_not_equal => u != v,
                .int_less => @as(i32, @bitCast(u)) < @as(i32, @bitCast(v)),
                .int_greater_equal => @as(i32, @bitCast(u)) >= @as(i32, @bitCast(v)),
                .uint_less => u < v,
                .uint_greater_equal => u >= v,
            };
            out[0] = if (holds) 1.0 else 0.0;
        },
        .logic => {
            const x = of(values, each.a)[0] != 0;
            const y = of(values, each.b)[0] != 0;
            out[0] = if (switch (@as(Logic, @enumFromInt(each.at))) {
                .iand => x and y,
                .ior => x or y,
                .inot => !x,
            }) 1.0 else 0.0;
        },
        .select => {
            const chosen = if (of(values, each.a)[0] != 0) each.b else each.from[0];
            out[0] = of(values, chosen)[0];
        },
        else => return null,
    }
    return out;
}

/// lower_gradient_cube_map's level worked out as it reads, of `direction`
/// normalized as nir_normalize_cubemap_coords has it: the face, the
/// quotient rule, -1 plus half the log of L * (L * M) (nir_lower_tex.c:
/// 783-848; since 1.184).
fn cubeLevel(direction: [3]f32, ddx: [3]f32, ddy: [3]f32, width: f32) f32 {
    const largest = @max(@max(@abs(direction[0]), @abs(direction[1])), @abs(direction[2]));
    var p: [3]f32 = undefined;
    for (&p, direction) |*each, d| each.* = d * (1.0 / largest);
    const ax = @abs(p[0]);
    const ay = @abs(p[1]);
    const az = @abs(p[2]);
    const face: [3]u8 = if (az >= @max(ax, ay)) .{ 0, 1, 2 } else if (ay >= @max(ax, az)) .{ 0, 2, 1 } else .{ 1, 2, 0 };
    const recip = 1.0 / p[face[2]];
    var most: f32 = 0;
    for ([2][3]f32{ ddx, ddy }) |d| {
        var length: f32 = 0;
        for (0..2) |k| {
            const onto = (d[face[k]] - p[face[k]] * recip * d[face[2]]) * recip;
            length += onto * onto;
        }
        most = @max(most, length);
    }
    return -1.0 + 0.5 * @log2(width * (width * most));
}

test "a cube's gradient is the level lower_gradient_cube_map makes, on each face of each sign" {
    // The steps after the passes, worked out for colours whose direction
    // falls on z, y and x, each way, against the level the lowering's own
    // arithmetic gives (since 1.184).
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_grad_cube_varied);
    var lod: u16 = none;
    for (work.program()) |each| if (each.tag == .sample) {
        lod = each.from[0];
    };
    try testing.expect(lod != none);
    var sizes: usize = 0;
    for (work.program()) |each| if (each.tag == .texture_size) {
        // A cube's txs is two integers, of level 0.
        try testing.expectEqual(Kind.f32x2, each.kind);
        try testing.expect(isSplat(&work, each.from[0], 0.0));
        sizes += 1;
    };
    try testing.expectEqual(@as(usize, 1), sizes);
    const colors = [_][4]f32{
        .{ 0.2, -0.3, 0.9, 0.7 },
        .{ 0.3, 0.2, -0.7, -0.4 },
        .{ 0.1, -0.95, 0.4, 0.6 },
        .{ -0.5, 0.8, 0.3, 0.2 },
        .{ -0.8, 0.3, 0.5, -0.9 },
        .{ 0.9, -0.6, -0.1, 0.3 },
        // Ties: z's magnitude x's, which fge puts on z, and x's y's,
        // which it puts on y.
        .{ 0.5, -0.3, -0.5, 0.4 },
        .{ 0.4, -0.4, 0.2, -0.3 },
    };
    for (colors) |color| {
        const direction = [3]f32{ color[0], color[1], color[2] };
        const ddx = [3]f32{ color[3], color[0], 0.25 };
        const ddy = [3]f32{ color[2] * 0.5, color[0] * 0.5, color[1] * 0.5 };
        const expected = cubeLevel(direction, ddx, ddy, 64.0);
        const found = evaluatedOf(&work, lod, color, 64)[0];
        try testing.expectApproxEqAbs(expected, found, 1e-4);
    }
    // Each derivative's two onto the face are times rcp_Q_z although the
    // normalized coordinate's Q.z is 1 or -1 (:828-834): 27 FMULs, the
    // varyings' 4, the normalization's 3, dPdy's halves 3, tmp's 2, tmp
    // times each z 4, rcp_Q_z's 4, the dots' 4, L * (L * M) 2 and the
    // half 1.
    var code_work: Work = .{};
    const code = try throughMesa(&code_work, &reference.glslc_grad_cube_varied);
    try testing.expectEqual(@as(usize, 27), countOf(code, "fmul "));
    // And 5 FMAXes: the normalization's 2, cond_z's of x and y, cond_y's
    // of x and z - which a cond_y of x and y would make the same
    // value, and one fewer - and M's (:791-792, :837).
    try testing.expectEqual(@as(usize, 5), countOf(code, "fmax "));
}

test "a cube's constant gradient keeps its zeros' selections, the fsub of a zero an fneg" {
    // dPdx (0.01, 0, 0) and dPdy (0, 0.01, 0): each float of dQdx and
    // dQdy a bcsel of the constants, and a zero less tmp times its z the
    // fadd of the zero and the fneg (nir_opt_algebraic.py:2401), the zero
    // taken out (:236) and the fneg v3d's XOR of the sign bit
    // (nir_to_vir.c:1412-1419; since 1.184).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_grad_cube_constant);
    try testing.expectEqual(@as(usize, 1), countOf(code, "log "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmuscm, "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "xor "));
}

test "a gradient is refused on an implicit level's sample and on a fetch" {
    // vtn asserts a txd is a txl (spirv_to_nir.c:3442): glslc_grad_varying's
    // OpImageSampleExplicitLod made OpImageSampleImplicitLod.
    var implicit = reference.glslc_grad_varying;
    var rewritten: usize = 0;
    for (&implicit) |*word| if (word.* & 0xFFFF == 88) {
        word.* = word.* & 0xFFFF0000 | 87;
        rewritten += 1;
    };
    try testing.expectEqual(@as(usize, 1), rewritten);
    var made: Work = .{};
    try testing.expectError(Error.Body, throughMesa(&made, &implicit));
    // And glslc_fetch's Lod made a Grad of the level and the coordinate.
    var fetch = reference.glslc_fetch;
    const at = std.mem.indexOfScalar(u32, &fetch, 0x0007005F).?;
    try testing.expectEqual(@as(u32, 2), fetch[at + 5]);
    var grad: [fetch.len + 1]u32 = undefined;
    for (0..at) |k| grad[k] = fetch[k];
    grad[at] = 0x0008005F;
    for (1..5) |k| grad[at + k] = fetch[at + k];
    grad[at + 5] = 4;
    grad[at + 6] = fetch[at + 6];
    grad[at + 7] = fetch[at + 4];
    for (at + 7..fetch.len) |k| grad[k + 1] = fetch[k];
    var fetched: Work = .{};
    try testing.expectError(Error.Body, throughMesa(&fetched, &grad));
}

test "through Mesa's back end, a texel times the colour reads the texel's halves in its products" {
    var work: Work = .{};
    const code = try throughMesa(&work, Modulated.words);
    try testing.expectEqual(@as(u32, 6), code.varyings);
    try testing.expectEqual(@as(u8, 4), code.threads);
    try testing.expectEqualSlices(Word, &[_]Word{ .{ .texture = 0 }, .{ .sampler = .{ .bits = per_pixel_mask } } }, code.stream());
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
        .{ .texture = 0 }, .{ .sampler = .{ .bits = per_pixel_mask } },
        .{ .float = 0.1 }, .{ .float = 0.2 },
        .{ .float = 0.3 },
    }, code.stream());
    try expectText(code, &.{
        text("nop", "nop", "ldvary.rf4; wrtmuc"),
        text("nop", "fmul rf5, rf4, rf3", "ldvary.rf7; wrtmuc"),
        // The floats of its own, read around the thread switch: Mesa
        // reads the uniform stream in the last section as anywhere else,
        // each an ldunif to rf0 its sum reads the instruction after. The
        // fourth, 0, has no sum: the texel's float is written itself
        // (nir_opt_algebraic.py:236, a float at a time; since 1.174).
        text("fadd rf6, rf0, rf5", "fmul rf8, rf7, rf3", ""),
        text("fadd rf9, rf0, rf8", "nop", "thrsw; ldunif"),
        text("nop", "mov tmut, rf9", "thrsw"),
        text("nop", "mov tmus, rf6", ""),
        text("nop", "nop", "ldtmu.rf10"),
        text("fadd rf12, rf0, rf10.l", "nop", "ldtmu.rf11; ldunif"),
        text("fadd rf13, rf0, rf10.h", "nop", "ldunif"),
        text("fadd rf14, rf0, rf11.l", "nop", ""),
        text("vfpack tlb, rf12, rf13", "nop", "thrsw"),
        text("vfpack tlb, rf14, rf11.h", "nop", ""),
        text("nop", "nop", ""),
    });
}

test "through Mesa's back end, what does not fit 4 threads is compiled at 2, where the plan refuses it" {
    var work: Work = .{};
    try testing.expectError(Error.Registers, compile(&work, Crowded.words));
    const code = try throughMesa(&work, Crowded.words);
    // Strategy 0 failed to allocate; strategy 2's two threads have all 64
    // registers, and it fits them without a spill (a spill's uniforms a
    // draw fills since 1.177, from the pipeline's spill buffer).
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
    try testing.expectError(Error.Operands, throughMesa(&work, &offset_too_far));
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
    try testing.expectEqual(@as(usize, 0), code.sampled().len);
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
    try testing.expectError(Error.Operands, compileThroughMesa(&work, &offset_too_far, testing.allocator, .{}));
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
        // A branch is the whole line, with no mul side.
        const cut = std.mem.indexOf(u8, line, ";") orelse line.len;
        const side = if (!mul_side) line[0..cut] else if (cut < line.len) std.mem.trimStart(u8, line[cut + 1 ..], " ") else "";
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
    // as Sqrt's is, each dot its products and sums (since 1.176); Pow LOG
    // then EXP; FClamp to 0.0 and 1.0 an fsat, as the algebraic pass
    // makes it (since 1.153), and the negated x the FMAX's other operand;
    // Fract FFLOOR and FSUB.
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

/// glslc_nested's shader through the IR: an `else if`, and an `if` and
/// `else` in the true arm of a selection of no false arm, in the order
/// glslc writes them, each float the vector's arms change merged one by
/// one (since 1.156).
const Nested = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const half = b.scalar(0.5);
        const quarter = b.scalar(0.25);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const z = b.component(v, 2);
        const w = b.component(v, 3);
        const first = b.ifHolds(b.lessThan(x, quarter));
        const red_first = b.mul(y, b.scalar(2));
        b.otherwise(first);
        const second = b.ifHolds(b.lessThan(x, half));
        const green_second = b.sin(b.mul(z, b.scalar(3)));
        b.otherwise(second);
        const blue_third = b.add(w, b.scalar(0.125));
        b.endIf(second);
        const red_else = b.merged(second, half, x);
        const green_else = b.merged(second, green_second, y);
        const blue_else = b.merged(second, z, blue_third);
        b.endIf(first);
        const red = b.merged(first, red_first, red_else);
        const green = b.merged(first, y, green_else);
        const blue = b.merged(first, z, blue_else);
        const third = b.ifHolds(b.greaterThan(w, half));
        const fourth = b.ifHolds(b.greaterThan(y, half));
        const product = b.mul(x, y);
        b.otherwise(fourth);
        const power = b.exp2(y);
        b.endIf(fourth);
        const chosen = b.merged(fourth, product, power);
        const scaled = b.add(b.mul(chosen, half), quarter);
        b.endIf(third);
        const alpha = b.merged(third, scaled, z);
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

test "a selection Mesa leaves a branch is a branch: an arm over the limit, a sample in one; a jump elsewhere is refused" {
    // Twelve sums and sines are 24, nir_opt_peephole_select's limit, and
    // flattened; thirteen are 26 and stay a branch, which ntq_emit_if
    // emits as one. With no false arm, the way past the true one is the
    // selection's own block.
    var work: Work = .{};
    _ = try throughMesa(&work, Costly(12).words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .select));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .begin_if));
    var costly: Work = .{};
    const code = try throughMesa(&costly, Costly(13).words);
    try testing.expectEqual(@as(usize, 0), stepsOf(&costly, .select));
    try testing.expectEqual(@as(usize, 1), stepsOf(&costly, .begin_if));
    try testing.expectEqual(@as(usize, 1), stepsOf(&costly, .phi));
    try testing.expectEqual(@as(usize, 13), stepsOf(&costly, .sin));
    // The condition the varying's, so the channels part
    // (ntq_emit_nonuniform_if): `execute` 0 where the true arm runs and
    // the false way's block where not, and the arm jumped over where no
    // channel runs it (ALLNA). `x` is read after the merge, so the false
    // way is a copy of it into the phi's register
    // (nir_convert_from_ssa): a block of one move, cheap (is_cheap_block),
    // and no jump past it. The arm's last XOR and the copy write the
    // phi's register under the mask (ntq_store_def), and the false way's
    // block takes the channels waiting for it (ntq_activate_execute_for_block).
    try testing.expectEqual(@as(usize, 1), countOf(code, "bu."));
    try testing.expectEqual(@as(usize, 1), countOf(code, "bu.allna"));
    try testing.expectEqual(@as(usize, 1), opsOf(code, "xor.ifa"));
    try testing.expectEqual(@as(usize, 1), opsOf(code, "mov.ifna"));
    try testing.expectEqual(@as(usize, 3), opsOf(code, "mov.ifa"));
    try testing.expectEqual(@as(usize, 1), opsOf(code, "xor.pushz"));
    try testing.expectEqual(@as(usize, 3), opsOf(code, "mov.pushz"));
    try testing.expectEqual(@as(usize, 128), code.words.len);
    // The branch's word of the stream the way past the arm's five
    // (qpu_set_branch_targets): (6 - (0 + 1)) * 4.
    const stream = code.stream();
    try testing.expectEqual(@as(usize, 6), stream.len);
    try testing.expectEqual(@as(u32, 20), @as(u32, @bitCast(stream[0].float)));
    // A sample is a texture instruction, which the pass leaves in its
    // arm. The varying is the phi's other way and read nowhere after the
    // merge, so it is the phi's register itself: moved into it before the
    // selection (ntq_emit_load_input's MOV), the false way empty
    // (empty_else_block) and the true arm's jump to the merge.
    var sampled: Work = .{};
    const arm = try throughMesa(&sampled, &reference.glslc_sampled_arm);
    try testing.expectEqual(@as(usize, 1), stepsOf(&sampled, .sample));
    try testing.expectEqual(@as(usize, 4), stepsOf(&sampled, .phi));
    try testing.expectEqual(@as(usize, 1), countOf(arm, "bu.allna"));
    try testing.expectEqual(@as(usize, 1), countOf(arm, "bu."));
    try testing.expectEqual(@as(usize, 0), opsOf(arm, "xor.pushz"));
    try testing.expectEqual(@as(usize, 1), opsOf(arm, "mov.ifna"));
    try testing.expectEqual(@as(usize, 4), opsOf(arm, "mov.ifa"));
    try testing.expectEqual(@as(usize, 27), arm.words.len);
    try expectStream(&[_]Word{ .{ .float = @bitCast(@as(u32, 8)) }, .{ .texture = 0 }, .{ .sampler = .{ .bits = 4 } } }, arm.stream());
    // The first arm's end a jump to the second arm rather than the merge.
    try testing.expectError(Error.Branches, throughMesa(&work, &comptime patched(&reference.glslc_branch, .branch, 0, 0, 41)));
    // A phi naming a block that is neither arm.
    try testing.expectError(Error.Branches, throughMesa(&work, &comptime patched(&reference.glslc_branch, .phi, 0, 3, 5)));
}

test "through Mesa's back end, glslc's sample in one arm and a constant in the other: the false way's block is the constant's copies" {
    // nir_opt_peephole_select leaves the sample in its arm, and the
    // condition is the varying's: ntq_emit_nonuniform_if. The texel's
    // floats are moved into the phi's registers under the mask where the
    // true arm ends (nir_lower_phis_to_scalar's MOVs); the constant's are
    // SSA only and copied where the false way ends (nir_from_ssa.c:419-424),
    // in a block past a jump to the merge that the true arm's channels
    // take (ALLA), after ntq_activate_execute_for_block. 0.25, 0.5 and 1
    // are small immediates and 0.75 a uniform. The stream holds the jumps'
    // offsets: past the true arm's texture, sampler and second jump, and
    // past the 0.75.
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_branched);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 4), stepsOf(&work, .phi));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .select));
    try testing.expectEqual(@as(usize, 1), countOf(code, "bu.allna"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "bu.alla"));
    // Four copies each way, and `execute` set to the merge's block where
    // the true arm ends and to 0 where the false way's channels start.
    try testing.expectEqual(@as(usize, 8 + 2), opsOf(code, "mov.ifa"));
    try testing.expectEqual(@as(usize, 2), opsOf(code, "xor.pushz"));
    try testing.expectEqual(@as(usize, 38), code.words.len);
    try expectStream(&[_]Word{ .{ .float = @bitCast(@as(u32, 12)) }, .{ .texture = 0 }, .{ .sampler = .{ .bits = 4 } }, .{ .float = @bitCast(@as(u32, 4)) }, .{ .float = 0.75 } }, code.stream());
}

test "through Mesa's back end, glslc's store in an arm on a push constant: a uniform branch, the store unmasked" {
    // A store is a write nir_opt_peephole_select leaves in its arm, and
    // the condition is a push constant's, the same in every channel:
    // ntq_emit_uniform_if, one jump past the arm where any channel the
    // shader runs for has it false (ANYNA, msfign P), and the arm's TMU
    // writes unmasked, there being no mask (vir_in_nonuniform_control_flow).
    // Its TMUWT is in its arm (ntq_emit_block's ntq_flush_tmu).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_stored);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .phi));
    try testing.expectEqual(@as(usize, 1), countOf(code, "bu.anynap"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "bu."));
    try testing.expectEqual(@as(usize, 0), countOf(code, ".ifa"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "pushz"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "tmuwt"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmua,"));
    try testing.expect(code.writes_z);
    try testing.expectEqual(@as(usize, 20), code.words.len);
    try expectStream(&[_]Word{ .{ .push = 0 }, .{ .float = @bitCast(@as(u32, 4)) }, .{ .ssbo = .{ .set = 0, .binding = 0, .reach = 4 } }, .{ .float = @bitCast(@as(u32, 0xffffff84)) } }, code.stream());
}

/// A selection over the limit in the arm of another: a branch in a
/// branch.
const DeepCostly = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const x = b.component(v, 0);
        const half = b.scalar(0.5);
        const outer = b.ifHolds(b.lessThan(b.component(v, 1), half));
        const inner = b.ifHolds(b.lessThan(x, half));
        var made = x;
        inline for (0..13) |_| made = b.sin(b.add(made, half));
        b.endIf(inner);
        const chosen = b.merged(inner, made, x);
        b.endIf(outer);
        const last = b.merged(outer, chosen, x);
        b.color(b.vector(&.{ last, x, x, x }));
    }
});

/// `count` selections one after another, each a uniform buffer's float
/// in its arm.
fn Arms(comptime count: usize) type {
    return ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const v = b.input(0, .f32x4);
            var made = b.component(v, 0);
            inline for (0..count) |k| {
                const at = b.ifHolds(b.lessThan(made, b.scalar(0.1 * @as(f32, @floatFromInt(k + 1)))));
                const loaded = b.uniform(0, 0, 4 * k, .f32x1);
                b.endIf(at);
                made = b.merged(at, loaded, made);
            }
            b.color(b.vector(&.{ made, made, made, made }));
        }
    });
}

test "a branch in a branch, and a ninth branch, are refused" {
    // Mesa keeps both (nir_opt_peephole_select flattens no arm that holds
    // control flow); a kept selection here is one at the top level.
    var work: Work = .{};
    try testing.expectError(Error.Branches, throughMesa(&work, DeepCostly.words));
    // Eight are kept, one after another, each its own blocks. Each phi is
    // the next one's false way and read nowhere else past it, so
    // aggressive_coalesce_block merges the webs whole (merge_merge_sets):
    // one register, each false way empty, and each true arm's load moved
    // into it under the mask.
    var eight: Work = .{};
    const code = try throughMesa(&eight, Arms(8).words);
    try testing.expectEqual(@as(usize, 8), stepsOf(&eight, .begin_if));
    try testing.expectEqual(@as(usize, 8), countOf(code, "bu.allna"));
    try testing.expectEqual(@as(usize, 8), countOf(code, "bu."));
    try testing.expectEqual(@as(usize, 0), opsOf(code, "xor.pushz"));
    try testing.expectEqual(@as(usize, 8), opsOf(code, "mov.ifa"));
    var nine: Work = .{};
    try testing.expectError(Error.Branches, throughMesa(&nine, Arms(9).words));
}

/// A selection kept for its false arm's cost, with the same sine in both
/// arms, a product made before it that the false arm reads after the
/// sine its phi takes from there, and 0.3, no small immediate, read
/// first in the true arm and again past the merge.
const Shared = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const half = b.scalar(0.5);
        const odd = b.scalar(0.3);
        const twice = b.mul(y, b.scalar(2.0));
        const at = b.ifHolds(b.lessThan(x, half));
        const yes = b.mul(b.sin(y), odd);
        b.otherwise(at);
        const sine = b.sin(y);
        var made = sine;
        inline for (0..12) |_| made = b.sin(b.add(made, half));
        const summed = b.add(twice, made);
        b.endIf(at);
        const first = b.merged(at, twice, sine);
        const second = b.merged(at, yes, summed);
        b.color(b.vector(&.{ first, second, b.mul(x, odd), x }));
    }
});

test "a kept selection's arms share nothing, and a web holds no float while another in it is still read" {
    var work: Work = .{};
    const code = try throughMesa(&work, Shared.words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    // The false arm's sine is its own: the true arm's dominates it not, so
    // nir_opt_cse leaves it (nir_instr_set.c's dominance check), and the
    // false arm does not read a register the true arm's jump may skip.
    try testing.expectEqual(@as(usize, 1 + 1 + 12), opsOf(code, "sin"));
    // `twice` is the first phi's true way, made before the selection and
    // read past it by nothing else: that phi's register. The false arm
    // reads it after the sine the phi takes from there, so the sine is
    // live where `twice` still is and interferes (nir_def_is_live_at):
    // it is copied into the register where the false arm ends, after the
    // sum read it, and not made there. The second phi's ways are made in
    // its register under the mask. So one copy, and `execute` set where
    // the true arm ends and where the false way's channels start.
    try testing.expectEqual(@as(usize, 1 + 2), opsOf(code, "mov.ifa"));
    try testing.expectEqual(@as(usize, 1), opsOf(code, "fmul.ifa"));
    try testing.expectEqual(@as(usize, 1), opsOf(code, "fadd.ifa"));
    // 0.3 is loaded where each block reads it, the true arm's load not
    // being there where its jump skips the arm (load_consts in blocks
    // neither dominates, which nir_opt_cse keeps two).
    var odd: usize = 0;
    for (code.stream()) |word| {
        if (word == .float and word.float == 0.3) odd += 1;
    }
    try testing.expectEqual(@as(usize, 2), odd);
}

/// A uniform buffer's float, scaled, in a selection's arm, the varying's
/// other floats read past the merge, one of them by a product.
const ScaledInArm = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const x = b.component(v, 0);
        const chosen = b.ifHolds(b.lessThan(x, b.scalar(0.5)));
        const scaled = b.mul(b.uniform(0, 0, 0, .f32x1), b.scalar(3.0));
        b.endIf(chosen);
        const red = b.merged(chosen, scaled, x);
        b.color(b.vector(&.{ red, b.mul(b.component(v, 1), b.scalar(2.0)), b.component(v, 2), b.component(v, 3) }));
    }
});

test "a phi's way coalesced is a float of its own, and one uniform where the phi is not is copied" {
    // The varying's red is read past the merge by nothing, its green by a
    // product: each float is a def of its own (nir_lower_io_to_scalar),
    // so the red is the phi's register and the false way empty. The
    // scaled load is uniform where the phi is not, so it is not coalesced
    // (nir_from_ssa.c:428-430): its product is made unmasked and moved
    // into the phi's register under the mask.
    var work: Work = .{};
    const code = try throughMesa(&work, ScaledInArm.words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 1), countOf(code, "bu."));
    try testing.expectEqual(@as(usize, 0), opsOf(code, "xor.pushz"));
    try testing.expectEqual(@as(usize, 1), opsOf(code, "mov.ifa"));
    try testing.expectEqual(@as(usize, 0), opsOf(code, "fmul.ifa"));
}

/// A selection kept for its true arm's cost, and two floats of the
/// varying swapped by it: green takes the blue's way where the true arm
/// is and the green's where not, and blue the other way about.
const Swapped = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const z = b.component(v, 2);
        const half = b.scalar(0.5);
        const at = b.ifHolds(b.lessThan(x, half));
        var made = x;
        inline for (0..13) |_| made = b.sin(b.add(made, half));
        b.endIf(at);
        const red = b.merged(at, made, x);
        const green = b.merged(at, z, y);
        const blue = b.merged(at, y, z);
        b.color(b.vector(&.{ red, green, blue, b.scalar(1) }));
    }
});

test "two floats of one varying, each one way of a phi, are two webs' and not one's" {
    // Each float is a load of its own (nir_lower_io_to_scalar), so the
    // green's is made before the blue's and read where the true arm ends,
    // past where the blue's is made: they interfere (nir_defs_interfere),
    // and the blue phi's register holds the green alone. Green's phi takes
    // the blue float where the true arm ends, which the blue phi's false
    // way reads where it ends, so that is a copy each way. The varying's
    // red is the red phi's false way, its register.
    var work: Work = .{};
    const code = try throughMesa(&work, Swapped.words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 3), stepsOf(&work, .phi));
    // Unmasked before the selection: the red and the green moved into
    // the registers of the phis they are a way of, and `execute` 0.
    try testing.expectEqual(@as(usize, 2 + 1), opsOf(code, "mov"));
    // Copied where the true arm ends: the blue float into green's
    // register; where the false way ends: the green float into green's
    // and the blue into blue's. And `execute` set at each.
    try testing.expectEqual(@as(usize, 3 + 2), opsOf(code, "mov.ifa"));
}

test "a kept selection past the 128th step is coalesced as it is before it: the same copies under the mask" {
    // The walk's sets of where each float is read are a bit a step, and
    // the steps after one all the bits above it (since 1.189).
    var early: Work = .{};
    const first = try throughMesa(&early, &reference.glslc_selection_early);
    var late: Work = .{};
    const second = try throughMesa(&late, &reference.glslc_selection_late);
    var begin: usize = 0;
    while (late.steps[begin].tag != .begin_if) begin += 1;
    try testing.expect(begin > 128);
    try testing.expectEqual(@as(usize, 1), stepsOf(&late, .begin_if));
    try testing.expectEqual(@as(usize, 2), stepsOf(&late, .phi));
    inline for (.{ "fmul.ifa", "fadd.ifa", "sin" }) |op| {
        try testing.expectEqual(opsOf(first, op), opsOf(second, op));
    }
    try testing.expectEqual(@as(usize, 1 + 1 + 12), opsOf(second, "sin"));
    // The selection's three copies under the mask, and each division's
    // uadd_sat a bcsel of ~0, by 7 having an increment.
    try testing.expectEqual(@as(usize, 3), opsOf(first, "mov.ifa"));
    try testing.expectEqual(@as(usize, 3 + 6), opsOf(second, "mov.ifa"));
}

/// A selection kept for its true arm's cost on a push constant's
/// condition, a product in its false arm, and the varying read past it.
const PushedCostly = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const x = b.component(v, 0);
        const half = b.scalar(0.5);
        const at = b.ifHolds(b.lessThan(b.push(0, .f32x1), half));
        var made = x;
        inline for (0..13) |_| made = b.sin(b.add(made, half));
        b.otherwise(at);
        const other = b.mul(x, b.scalar(0.75));
        b.endIf(at);
        const red = b.merged(at, made, other);
        b.color(b.vector(&.{ red, x, x, x }));
    }
});

test "a kept selection on a push constant is ntq_emit_uniform_if's: a jump each way, nothing masked" {
    // The condition is the same in every channel, so the program jumps to
    // the false way's block where any channel it runs for has it false
    // (ANYNA, msfign P), and the true arm ends in a jump past it, its
    // delay slots filled from the arm (qpu_schedule.c's emit_branch). Both
    // ways are made in the phi's register, the varying's red read past it
    // being no way of it, and no write is masked: there is no `execute`.
    var work: Work = .{};
    const code = try throughMesa(&work, PushedCostly.words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 1), countOf(code, "bu.anynap"));
    try testing.expectEqual(@as(usize, 1), sideOps(code, "bu", false));
    try testing.expectEqual(@as(usize, 2), countOf(code, "bu"));
    try testing.expectEqual(@as(usize, 0), countOf(code, ".if"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "pushz"));
    // The jumps' words: past the true arm's five uniforms and its own
    // jump's, (8 - 2) * 4, and past the false way's 0.75, (9 - 8) * 4.
    const stream = code.stream();
    try testing.expectEqual(@as(usize, 9), stream.len);
    try testing.expectEqual(Word{ .push = 0 }, stream[0]);
    try testing.expectEqual(@as(u32, 24), @as(u32, @bitCast(stream[1].float)));
    try testing.expectEqual(@as(u32, 4), @as(u32, @bitCast(stream[7].float)));
    try testing.expectEqual(@as(f32, 0.75), stream[8].float);
}

test "through Mesa's back end, glslc's if and else without -O: its variables made values, and the optimized module's program to the word" {
    // `c` and `k` in variables of the function's own, floats of `c`
    // stored through access chains in the arms: nir_lower_vars_to_ssa
    // makes them the values the optimized module's phis choose, and the
    // program is the same, its uniforms too.
    var theirs: Work = .{};
    const optimized = try throughMesa(&theirs, &reference.glslc_branch);
    const kept = try testing.allocator.dupe(u64, optimized.words);
    defer testing.allocator.free(kept);
    const stream_kept = try testing.allocator.dupe(Word, optimized.stream());
    defer testing.allocator.free(stream_kept);
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_branch_unoptimized);
    try testing.expectEqual(@as(u32, 3), work.local_count);
    try testing.expectEqual(@as(usize, 4), stepsOf(&work, .select));
    try testing.expectEqualSlices(u64, kept, code.words);
    try testing.expectEqual(stream_kept.len, code.stream().len);
    for (stream_kept, code.stream()) |a, b| try testing.expectEqual(a, b);
    var plan: Work = .{};
    try testing.expectError(Error.Body, compile(&plan, &reference.glslc_branch_unoptimized));
}

test "through Mesa's back end, glslc's discard without -O: the texel in a variable of its own, and the optimized module's program to the word" {
    var theirs: Work = .{};
    const optimized = try throughMesa(&theirs, &reference.glslc_cutout);
    const kept = try testing.allocator.dupe(u64, optimized.words);
    defer testing.allocator.free(kept);
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_cutout_unoptimized);
    try testing.expectEqualSlices(u64, kept, code.words);
    try testing.expect(code.writes_z and code.disable_ez);
    var plan: Work = .{};
    try testing.expectError(Error.Discards, compile(&plan, &reference.glslc_cutout_unoptimized));
}

test "a variable of the function's own read before anything is stored into it is 0, and one stored one way only is what that way stored" {
    // The texel stored into the colour out rather than `texel`: the
    // alpha and then the colour are loaded from a variable that holds
    // nothing, which is 0 (nir_lower_undef_to_zero).
    var work: Work = .{};
    _ = try throughMesa(&work, &comptime patched(&reference.glslc_cutout_unoptimized, .store, 0, 0, 32));
    const colour = work.steps[work.stored];
    try testing.expectEqual(Tag.construct, colour.tag);
    for (colour.from[0..4]) |each| {
        try testing.expectEqual(Tag.constant, work.steps[each].tag);
        try testing.expectEqual(@as(f32, 0), work.pool[work.steps[each].at]);
    }
    // The ternary's false arm stored into the other float: `k` is stored
    // in the true arm only, so the merge takes it without a select, and
    // the other float, stored in the false arm only, likewise. Three
    // selects are left, the vector's.
    var one_way: Work = .{};
    _ = try throughMesa(&one_way, &comptime patched(&reference.glslc_branch_unoptimized, .store, 6, 0, 51));
    try testing.expectEqual(@as(usize, 3), stepsOf(&one_way, .select));
}

test "a variable of the function's own of a block's struct, or loaded as what it is not, is refused" {
    // The bools' pointer type made a pointer to the push constants'
    // struct.
    var work: Work = .{};
    try testing.expectError(Error.Storage, throughMesa(&work, &comptime patched(&reference.glslc_integer_nots_O0, .type_pointer, 0, 2, 13)));
    // `texel`'s pointer type made a pointer to a bool: a variable there
    // may be (since 1.165), but the vector loaded from it is no bool.
    try testing.expectError(Error.Type, throughMesa(&work, &comptime patched(&reference.glslc_cutout_unoptimized, .type_pointer, 0, 2, 26)));
    // The colour out stored in an arm is still a store Mesa leaves there.
    try testing.expectError(Error.Branches, throughMesa(&work, &comptime patched(&reference.glslc_branch_unoptimized, .store, 1, 0, 71)));
}

test "through Mesa's back end, glslc's nested selections: the inner flattened first, the outer's phis naming the inner merge block" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_nested);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    // Four comparisons, one a selection. The `else if`: three floats of
    // the colour chosen by the inner selection, then by the outer. Green's
    // outer select keeps y where the inner one keeps it too, and blue's z:
    // each is one select, on iand(second, inot(first)) and on ior(first,
    // second) (nir_opt_algebraic.py:2515, :2514). The `if` in the true arm
    // of one with no false arm: `k` chosen by each.
    try testing.expectEqual(@as(usize, 4), liveOf(&work, .compare));
    try testing.expectEqual(@as(usize, 6), liveOf(&work, .select));
    try testing.expectEqual(@as(usize, 1), liveLogicOf(&work, .iand));
    try testing.expectEqual(@as(usize, 1), liveLogicOf(&work, .ior));
    try testing.expectEqual(@as(usize, 1), liveLogicOf(&work, .inot));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .sin));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .exp2));
    var plan: Work = .{};
    try testing.expectError(Error.Body, compile(&plan, &reference.glslc_nested));
}

test "through Mesa's back end, glslc's nested selections without -O are the optimized module's program, to the word" {
    var theirs: Work = .{};
    const optimized = try throughMesa(&theirs, &reference.glslc_nested);
    const kept = try testing.allocator.dupe(u64, optimized.words);
    defer testing.allocator.free(kept);
    const stream_kept = try testing.allocator.dupe(Word, optimized.stream());
    defer testing.allocator.free(stream_kept);
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_nested_unoptimized);
    try testing.expectEqual(@as(usize, 6), liveOf(&work, .select));
    try testing.expectEqualSlices(u64, kept, code.words);
    try testing.expectEqual(stream_kept.len, code.stream().len);
    for (stream_kept, code.stream()) |a, b| try testing.expectEqual(a, b);
}

test "through Mesa's back end, glslc's nested selections are facet's, to the word" {
    var theirs: Work = .{};
    const glslc = try throughMesa(&theirs, &reference.glslc_nested);
    var ours: Work = .{};
    const facet_made = try throughMesa(&ours, Nested.words);
    try testing.expectEqualSlices(u64, glslc.words, facet_made.words);
    try testing.expectEqual(glslc.stream().len, facet_made.stream().len);
    for (glslc.stream(), facet_made.stream()) |a, b| try testing.expectEqual(a, b);
}

/// glslc_collapse's shader in the IR: an `if` of no `else` that is all of
/// the true arm of another of none but for its comparison.
const Collapsed = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const half = b.scalar(0.5);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const z = b.component(v, 2);
        const w = b.component(v, 3);
        const outer = b.ifHolds(b.lessThan(x, half));
        const inner = b.ifHolds(b.lessThan(y, half));
        const sine = b.sin(b.mul(z, b.scalar(3)));
        b.endIf(inner);
        const red_inner = b.merged(inner, sine, x);
        b.endIf(outer);
        const red = b.merged(outer, red_inner, x);
        b.color(b.vector(&.{ red, y, z, w }));
    }
});

/// How many of a program's instructions say `name` as the disassembler
/// prints them.
/// The stream word for word, a float by its bits: the TMU's
/// configuration of a general lookup is a NaN as a float (since 1.167).
fn expectStream(expected: []const Word, found: []const Word) !void {
    try testing.expectEqual(expected.len, found.len);
    for (expected, found) |want, got| switch (want) {
        .float => |bits| {
            try testing.expect(got == .float);
            try testing.expectEqual(@as(u32, @bitCast(bits)), @as(u32, @bitCast(got.float)));
        },
        else => try testing.expectEqual(want, got),
    };
}

fn countOf(code: Code, name: []const u8) usize {
    var count: usize = 0;
    for (code.words) |word| {
        var buffer: [disasm.most_text]u8 = undefined;
        if (std.mem.indexOf(u8, disasm.disasm(word, &buffer).?, name) != null) count += 1;
    }
    return count;
}

/// How many of a program's operations, of either side, are `op`.
fn opsOf(code: Code, comptime op: []const u8) usize {
    return sideOps(code, op, false) + sideOps(code, op, true);
}

/// The live step of the tag `tag`, the first, or none.
fn liveStepOf(work: *const Work, tag: Tag) u16 {
    const reached = liveMask(work);
    for (work.program(), 0..) |each, at| {
        if (each.tag == tag and reached[at]) return @intCast(at);
    }
    return none;
}

test "through Mesa's back end, nir_opt_collapse_if: a selection that is all of another's true arm is one on the iand of the two conditions" {
    var work: Work = .{};
    const glslc = try throughMesa(&work, &reference.glslc_collapse);
    // One select, of red, on iand(inner, outer), which is built after the
    // inner comparison and before the inner arm's work.
    try testing.expectEqual(@as(usize, 1), liveOf(&work, .select));
    try testing.expectEqual(@as(usize, 1), liveLogicOf(&work, .iand));
    const both = liveStepOf(&work, .logic);
    const select = liveStepOf(&work, .select);
    try testing.expectEqual(both, work.steps[select].a);
    try testing.expectEqual(Comparison.less, @as(Comparison, @enumFromInt(work.steps[work.steps[both].a].at)));
    try testing.expect(work.steps[both].a > work.steps[both].b);
    try testing.expect(both < liveStepOf(&work, .sin));
    const kept = try testing.allocator.dupe(u64, glslc.words);
    defer testing.allocator.free(kept);
    // The module without -O, and facet's emitter's, to the word.
    inline for (.{ &reference.glslc_collapse_unoptimized, Collapsed.words }) |words| {
        var other: Work = .{};
        const code = try throughMesa(&other, words);
        try testing.expectEqualSlices(u64, kept, code.words);
    }
}

test "through Mesa's back end, a discard nested in an arm is terminate_if of the two conditions' iand" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_nested_discard);
    const discard = liveStepOf(&work, .discard);
    try testing.expect(discard != none);
    try testing.expectEqual(Tag.logic, work.steps[work.steps[discard].a].tag);
    try testing.expectEqual(@as(usize, 1), liveLogicOf(&work, .iand));
    try testing.expectEqual(@as(usize, 0), liveOf(&work, .select));
    try testing.expectEqual(@as(usize, 1), countOf(code, "and "));
}

test "through Mesa's back end, where nir_opt_collapse_if leaves two selections they are flattened from the inside out" {
    // The outer phi takes the float stored before the inner selection,
    // which the inner one does not: two selects, and no iand.
    var kept: Work = .{};
    _ = try throughMesa(&kept, &reference.glslc_collapse_kept);
    try testing.expectEqual(@as(usize, 2), liveOf(&kept, .select));
    try testing.expectEqual(@as(usize, 0), liveLogicOf(&kept, .iand));
    // The inner arm a constant alone: flattened by the first pass, before
    // the collapse could be, and the select of a select one on the iand
    // of the outer condition and the inner (nir_opt_algebraic.py:2512),
    // built where the outer select was.
    var free: Work = .{};
    _ = try throughMesa(&free, &reference.glslc_collapse_free);
    try testing.expectEqual(@as(usize, 1), liveOf(&free, .select));
    try testing.expectEqual(@as(usize, 1), liveLogicOf(&free, .iand));
    const both = liveStepOf(&free, .logic);
    try testing.expect(free.steps[both].a < free.steps[both].b);
    // The outer selection asking to be flattened: its phi is not looked
    // at, the two collapse, and the outer select stays.
    var asked: Work = .{};
    _ = try throughMesa(&asked, &comptime patched(&reference.glslc_collapse_kept, .selection_merge, 0, 1, flatten));
    try testing.expectEqual(@as(usize, 2), liveOf(&asked, .select));
    try testing.expectEqual(@as(usize, 1), liveLogicOf(&asked, .iand));
}

test "a selection is flattened under the limit its SelectionControl sets, and one asking not to be is a branch" {
    // DontFlatten: a limit of 0, which an arm of a multiply passes not,
    // and the first selection is ntq_emit_if's: its true arm a sine's and
    // its false arm a square root's, neither cheap (is_cheap_block), so a
    // jump over each. The second asks nothing and is flattened still.
    var work: Work = .{};
    const branch = try throughMesa(&work, &comptime patched(&reference.glslc_branch, .selection_merge, 0, 1, dont_flatten));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 3), stepsOf(&work, .phi));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .select));
    try testing.expectEqual(@as(usize, 1), countOf(branch, "bu.allna"));
    try testing.expectEqual(@as(usize, 1), countOf(branch, "bu.alla"));
    try testing.expectEqual(@as(usize, 2), countOf(branch, "bu."));
    try testing.expectEqual(@as(usize, 45), branch.words.len);
    // The outer selection of glslc_collapse asking not to be: no collapse
    // past its comparison, and the outer arm, a selection in it, then
    // refused as a branch: no selection in a kept one is kept.
    try testing.expectError(Error.Branches, throughMesa(&work, &comptime patched(&reference.glslc_collapse, .selection_merge, 0, 1, dont_flatten)));
    // A control of neither bit, which vtn fails.
    try testing.expectError(Error.Branches, throughMesa(&work, &comptime patched(&reference.glslc_branch, .selection_merge, 0, 1, 4)));
    // Flatten is the same program where the arms are under 24 anyway.
    var unasked: Work = .{};
    const kept = try throughMesa(&unasked, &reference.glslc_branch);
    const words = try testing.allocator.dupe(u64, kept.words);
    defer testing.allocator.free(words);
    var asked: Work = .{};
    const code = try throughMesa(&asked, &comptime patched(&reference.glslc_branch, .selection_merge, 0, 1, flatten));
    try testing.expectEqualSlices(u64, words, code.words);
}

test "an outer arm that jumps to the inner merge block, where its own merge is due, is refused" {
    var work: Work = .{};
    try testing.expectError(Error.Branches, throughMesa(&work, &comptime patched(&reference.glslc_nested, .branch, 3, 0, 36)));
}

/// Which steps are live: the colour's, each discard, and what a live
/// step reads.
fn liveMask(work: *const Work) [most_steps]bool {
    var reached: [most_steps]bool = @splat(false);
    if (work.stored != none) reached[work.stored] = true;
    var at = work.step_count;
    while (at > 0) {
        at -= 1;
        const each = work.steps[at];
        if (each.tag == .discard) reached[at] = true;
        if (!reached[at]) continue;
        for (readsOf(each)) |field| if (field) |operand_at| {
            reached[operand_at] = true;
        };
    }
    return reached;
}

/// How many of the live steps are of the tag `tag`.
fn liveOf(work: *const Work, tag: Tag) usize {
    const reached = liveMask(work);
    var count: usize = 0;
    for (work.program(), 0..) |each, at| {
        if (each.tag == tag and reached[at]) count += 1;
    }
    return count;
}

fn liveCompareOf(work: *const Work, which: Comparison) usize {
    const reached = liveMask(work);
    var count: usize = 0;
    for (work.program(), 0..) |each, at| {
        if (each.tag == .compare and each.at == @intFromEnum(which) and reached[at]) count += 1;
    }
    return count;
}

/// The push constant's word a step reads, where it reads one.
fn pushWordOf(work: *const Work, at: u16) ?u32 {
    const each = work.steps[at];
    return if (each.tag == .push) each.at else null;
}

test "through Mesa's back end, 32-bit integers are the add side's integer operations, a multiply MULTOP and UMUL24, and the conversions to and from floats" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_integers);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    // The colour times 255.0, the push constants' words where they are
    // first read, and the integers that are no small immediates: 100,
    // the clamp's top and the green's, 25, 40, 32, 20 and 27. The 0, 2,
    // 3, 5, 12, 8 and 4 are; then 1 / 255.0, for each of the two floats
    // the vec4's fmul reads it for after try_opt_ldunif's 20 instructions
    // (vir.c:2811).
    const push = struct {
        fn of(at: u32) Word {
            return .{ .push = at };
        }
    }.of;
    const int = struct {
        fn of(value: u32) Word {
            return .{ .float = @bitCast(value) };
        }
    }.of;
    try testing.expectEqualSlices(Word, &.{
        .{ .float = 255.0 }, push(0), int(100), int(100), push(1),                   push(2),                   push(3), push(6), push(4), int(25), push(5), push(7),
        int(40),             int(32), int(20),  int(27),  .{ .float = 1.0 / 255.0 }, .{ .float = 1.0 / 255.0 },
    }, code.stream());
    // The colour made integers, an FTOIZ of each word read (nir_to_vir.c:
    // 1466-1477): not the green's, which nir_opt_dce has taken out; the
    // green an FTOUZ. Three ITOFs and three UTOFs back (:1478-1516).
    try testing.expectEqual(@as(usize, 3), countOf(code, "ftoiz"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "ftouz"));
    try testing.expectEqual(@as(usize, 3), countOf(code, "itof"));
    try testing.expectEqual(@as(usize, 3), countOf(code, "utof"));
    // The two products: MULTOP then UMUL24 (vir_UMUL, :1700).
    try testing.expectEqual(@as(usize, 2), countOf(code, "multop"));
    try testing.expectEqual(@as(usize, 2), countOf(code, "umul24"));
    // -s.y, and the abs the MAX of the sum and its NEG (:1805).
    try testing.expectEqual(@as(usize, 2), countOf(code, "neg "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "shl "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "asr "));
    try testing.expectEqual(@as(usize, 3), countOf(code, "shr "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "not "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "umax "));
    try testing.expectEqual(@as(usize, 2), countOf(code, "umin "));
    // s.y < s.z and s.z >= s.y a MIN pushing C, u.x < u.y and u.x > u.y a
    // SUB, and == and != an XOR pushing Z (ntq_emit_comparison,
    // :1173-1232).
    try testing.expectEqual(@as(usize, 2), countOf(code, "min.pushc"));
    try testing.expectEqual(@as(usize, 2), countOf(code, "sub.pushc"));
    try testing.expectEqual(@as(usize, 2), countOf(code, "xor.pushz"));
    try testing.expectEqual(@as(usize, 59), code.words.len);
    // The plan has no hand-written program to hold one to.
    var plan: Work = .{};
    try testing.expectError(Error.Body, compile(&plan, &reference.glslc_integers));
}

test "through Mesa's back end, the integer comparisons are XOR, MIN and SUB pushing the flags, the four NIR has none of read the other way about" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_integer_compares);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    try testing.expectEqualSlices(Word, &.{ .{ .push = 0 }, .{ .push = 1 }, .{ .push = 2 }, .{ .push = 3 } }, code.stream());
    // s.x > s.y is ilt(s.y, s.x), s.x >= s.y ige(s.x, s.y) and s.x <= s.y
    // ige(s.y, s.x), and the same of u.x and u.y unsigned
    // (vtn_alu.c:388-396); then s.x == s.y.
    const Seen = struct { which: Comparison, a: ?u32, b: ?u32 };
    const expected = [_]Seen{
        .{ .which = .int_less, .a = 1, .b = 0 },
        .{ .which = .int_greater_equal, .a = 0, .b = 1 },
        .{ .which = .int_greater_equal, .a = 1, .b = 0 },
        .{ .which = .uint_less, .a = 3, .b = 2 },
        .{ .which = .uint_greater_equal, .a = 2, .b = 3 },
        .{ .which = .uint_greater_equal, .a = 3, .b = 2 },
        .{ .which = .int_equal, .a = 0, .b = 1 },
    };
    var seen: [12]Seen = undefined;
    var count: usize = 0;
    const reached = liveMask(&work);
    for (work.program(), 0..) |each, at| {
        if (each.tag != .compare or !reached[at]) continue;
        seen[count] = .{ .which = @enumFromInt(each.at), .a = pushWordOf(&work, each.a), .b = pushWordOf(&work, each.b) };
        count += 1;
    }
    // level != u.x, and the bools' ==, !=, == and !=: ieq and ine of
    // their 0 and ~0 (vtn_alu.c:317-318). Three of each.
    try testing.expectEqual(@as(usize, 12), count);
    try testing.expectEqualSlices(Seen, &expected, seen[0..expected.len]);
    try testing.expectEqual(@as(usize, 3), liveCompareOf(&work, .int_equal));
    try testing.expectEqual(@as(usize, 3), liveCompareOf(&work, .int_not_equal));
    try testing.expectEqual(@as(usize, 3), countOf(code, "min.pushc"));
    try testing.expectEqual(@as(usize, 3), countOf(code, "sub.pushc"));
    try testing.expectEqual(@as(usize, 6), countOf(code, "xor.pushz"));
    // The level: FTOUZ, and UTOF back.
    try testing.expectEqual(@as(usize, 1), countOf(code, "ftouz"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "utof"));
    // same ? 1.0 : 0.0: the b2f of the bool nir_opt_algebraic makes of
    // the bcsel (:2080), the AND of its ~0 or 0 and 1.0
    // (nir_to_vir.c:1521-1523), and no select (since 1.178).
    try testing.expectEqual(@as(usize, 1), integerOpsOf(&work, .b2f32));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .select));
    try testing.expectEqual(@as(usize, 41), code.words.len);
}

test "through Mesa's back end, the not of an integer comparison read once is the opposite comparison" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_integer_nots_O0);
    // Each not reaches an iand rather than a select, so it is the inot
    // nir_opt_algebraic rewrites (nir_opt_algebraic.py:749-754), not the
    // bcsel (:978): ilt, ult and ieq are ige, uge and ine, and the iands
    // read those.
    try testing.expectEqual(@as(usize, 0), liveLogicOf(&work, .inot));
    try testing.expectEqual(@as(usize, 3), liveLogicOf(&work, .iand));
    try testing.expectEqual(@as(usize, 1), liveCompareOf(&work, .int_greater_equal));
    try testing.expectEqual(@as(usize, 1), liveCompareOf(&work, .uint_greater_equal));
    try testing.expectEqual(@as(usize, 1), liveCompareOf(&work, .int_not_equal));
    try testing.expectEqual(@as(usize, 0), liveCompareOf(&work, .int_less));
    try testing.expectEqual(@as(usize, 0), liveCompareOf(&work, .uint_less));
    try testing.expectEqual(@as(usize, 0), liveCompareOf(&work, .int_equal));
    try testing.expectEqual(@as(usize, 0), countOf(code, "not "));
    // glslc -O0 loads s.x and s.y again for the ==: nir_opt_cse takes the
    // second load_uniform of each for the first, so each word is in the
    // stream once.
    try testing.expectEqualSlices(Word, &.{ .{ .push = 0 }, .{ .push = 1 }, .{ .push = 2 }, .{ .push = 3 }, .{ .float = 0.75 } }, code.stream());
    // The colour's alpha, a product by 1.0, is the float itself
    // (nir_opt_algebraic.py:292, a float at a time; since 1.174).
    try testing.expectEqual(@as(usize, 31), code.words.len);
}

/// x * 1, then + 0, - (-0), fneg twice and * -1: the fneg of x, which y
/// less is y + x (since 1.174).
const Identities = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        const y = b.input(1, .f32x4);
        const once = b.add(b.mul(x, b.constant(.{ 1, 1, 1, 1 })), b.constant(.{ 0, 0, 0, 0 }));
        const twice = b.neg(b.neg(b.sub(once, b.constant(.{ -0.0, -0.0, -0.0, -0.0 }))));
        b.color(b.sub(y, b.mul(twice, b.constant(.{ -1, -1, -1, -1 }))));
    }
});

/// x * 0, y - y and -x + x: a zero, and their sums of it zero too.
const Cancelled = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        const y = b.input(1, .f32x4);
        b.color(b.add(b.add(b.mul(x, b.constant(.{ 0, 0, 0, 0 })), b.sub(y, y)), b.add(b.neg(x), x)));
    }
});

/// x + x, and 0 - y.
const Doubled = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        const y = b.input(1, .f32x4);
        b.color(b.mul(b.add(x, x), b.sub(b.constant(.{ 0, 0, 0, 0 }), y)));
    }
});

/// x plus (0.5, 0, 0.25, -0), and that times (1, -1, 0, 2): a float of
/// each a rule rewrites, the others not.
const PartlyFolded = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        const sum = b.add(x, b.constant(.{ 0.5, 0, 0.25, -0.0 }));
        b.color(b.mul(sum, b.constant(.{ 1, -1, 0, 2 })));
    }
});

/// The operands the other way about: 0 + x, 1 * that, y + -y; and x
/// plus itself swizzled, two floats of which are the same float.
const Mirrored = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        const y = b.input(1, .f32x4);
        const same = b.mul(b.constant(.{ 1, 1, 1, 1 }), b.add(b.constant(.{ 0, 0, 0, 0 }), x));
        const swizzled = b.vector(&.{ b.component(x, 1), b.component(x, 0), b.component(x, 2), b.component(x, 3) });
        b.color(b.add(b.add(swizzled, same), b.add(y, b.neg(y))));
    }
});

/// x plus floats of its own fneg, x.y's and x.x's, and y.z and y.w:
/// differences, not zeros, and sums; and x less y's fneg's x and z.
const Crossed = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        const y = b.input(1, .f32x4);
        const turned = b.neg(x);
        const unlike = b.add(x, b.vector(&.{ b.component(turned, 1), b.component(turned, 0), b.component(y, 2), b.component(y, 3) }));
        const ny = b.neg(y);
        b.color(b.mul(unlike, b.sub(x, b.vector(&.{ b.component(ny, 0), b.component(y, 1), b.component(ny, 2), b.component(y, 3) }))));
    }
});

/// An fneg of a float of an fneg, and a float less a float of one.
const Through = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        const y = b.input(1, .f32x4);
        const back = b.neg(b.component(b.neg(y), 0));
        const plus = b.sub(b.component(y, 1), b.component(b.neg(x), 1));
        b.color(b.vector(&.{ back, plus, b.component(x, 2), b.component(x, 3) }));
    }
});

/// x * y + z * x, z y swizzled, and y * x.x + y * x.y: a factor in
/// common.
const Factored = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        const y = b.input(1, .f32x4);
        const z = b.vector(&.{ b.component(y, 3), b.component(y, 2), b.component(y, 1), b.component(y, 0) });
        const common = b.add(b.mul(x, y), b.mul(z, x));
        const scaled = b.add(b.scale(y, b.component(x, 0)), b.scale(y, b.component(x, 1)));
        b.color(b.mul(common, scaled));
    }
});

/// y * x.x + z * x.x, z y swizzled: the factor in common the scalar.
const FactoredByScalar = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        const y = b.input(1, .f32x4);
        const z = b.vector(&.{ b.component(y, 3), b.component(y, 2), b.component(y, 1), b.component(y, 0) });
        b.color(b.add(b.scale(y, b.component(x, 0)), b.scale(z, b.component(x, 0))));
    }
});

/// y * x.x + y * x: the sum of a scalar and a vector, the vector its
/// first operand.
const FactoredMixed = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        const y = b.input(1, .f32x4);
        b.color(b.add(b.scale(y, b.component(x, 0)), b.mul(y, x)));
    }
});

/// -x + (x - y): the fneg of y.
const CancelledToNegated = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        b.color(b.add(b.neg(x), b.sub(x, b.input(1, .f32x4))));
    }
});

/// What a sum and an fneg cancel to, four ways: -x + (x + y),
/// x + (-x + y), (y + x) - x and x + (y - x), each y.
const CancelledSums = [_][]const u32{
    ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const x = b.input(0, .f32x4);
            b.color(b.add(b.neg(x), b.add(x, b.input(1, .f32x4))));
        }
    }).words,
    ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const x = b.input(0, .f32x4);
            b.color(b.add(x, b.add(b.neg(x), b.input(1, .f32x4))));
        }
    }).words,
    ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const x = b.input(0, .f32x4);
            b.color(b.sub(b.add(b.input(1, .f32x4), x), x));
        }
    }).words,
    ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const x = b.input(0, .f32x4);
            b.color(b.add(x, b.sub(b.input(1, .f32x4), x)));
        }
    }).words,
};

/// x + (x + y), the inner sum read once; x + (x - y); and x + (x + y)
/// where x + y is read again.
const Contracted = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        const y = b.input(1, .f32x4);
        b.color(b.mul(b.add(x, b.add(x, y)), b.add(x, b.sub(x, y))));
    }
});

const ContractedNot = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const x = b.input(0, .f32x4);
        const y = b.input(1, .f32x4);
        const inner = b.add(x, y);
        b.color(b.mul(b.add(x, inner), inner));
    }
});

/// x * y and y * x.x, then y * x and y * x.x: the same first float,
/// either way about, and not the same product.
const FirstFloatAlike = [_][]const u32{
    ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const x = b.input(0, .f32x4);
            const y = b.input(1, .f32x4);
            b.color(b.max(b.mul(x, y), b.scale(y, b.component(x, 0))));
        }
    }).words,
    ir.Fragment(struct {
        pub fn body(b: *ir.Build) void {
            const x = b.input(0, .f32x4);
            const y = b.input(1, .f32x4);
            b.color(b.max(b.mul(y, x), b.scale(y, b.component(x, 0))));
        }
    }).words,
};

test "nir_opt_cse takes a step for another only where every float of each operand is the same" {
    // y * x.x is x * y, and y * x, in its first float alone: two
    // products, and the fmax of the two (since 1.175).
    for (FirstFloatAlike) |words| {
        var work: Work = .{};
        _ = try throughMesa(&work, words);
        try testing.expectEqual(@as(usize, 2), stepsOf(&work, .mul));
        try testing.expectEqual(@as(usize, 1), stepsOf(&work, .max));
        for (work.program()) |each| if (each.tag == .max) try testing.expect(each.a != each.b);
    }
}

test "the fadds nir_opt_algebraic rewrites of fadds and fmuls: a factor in common, a sum an fneg cancels, a value added to a sum of it read once" {
    // x * (y + z) (:246), the second product's operands flipped; and
    // y * (x.x + x.y), the sum of the two scalars.
    var work: Work = .{};
    _ = try throughMesa(&work, Factored.words);
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .add));
    try testing.expectEqual(@as(usize, 3), stepsOf(&work, .mul));
    var scalar_sums: usize = 0;
    for (work.program()) |each| {
        if (each.tag == .add and each.kind == .f32x1) scalar_sums += 1;
    }
    try testing.expectEqual(@as(usize, 1), scalar_sums);
    // (y + z) * x.x: the vector the product's first operand.
    work = .{};
    _ = try throughMesa(&work, FactoredByScalar.words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .add));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .mul));
    for (work.program()) |each| if (each.tag == .mul) {
        try testing.expectEqual(Kind.f32x4, work.steps[each.a].kind);
        try testing.expectEqual(Kind.f32x1, work.steps[each.b].kind);
    };
    // y * (x + x.x), a float at a time: x.x * 2.0 and x.y, x.z and x.w
    // plus x.x.
    work = .{};
    _ = try throughMesa(&work, FactoredMixed.words);
    try testing.expectEqual(@as(usize, 3), stepsOf(&work, .add));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .mul));
    // Each y, written as it is (:271-272; an fsub its fadd of the fneg).
    for (CancelledSums) |words| {
        work = .{};
        _ = try throughMesa(&work, words);
        for ([_]Tag{ .add, .sub, .negate, .mul }) |tag| try testing.expectEqual(@as(usize, 0), stepsOf(&work, tag));
    }
    // The fneg of y, the fsub's second.
    work = .{};
    _ = try throughMesa(&work, CancelledToNegated.words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .negate));
    for ([_]Tag{ .add, .sub, .mul }) |tag| try testing.expectEqual(@as(usize, 0), stepsOf(&work, tag));
    // y + x * 2.0 and x * 2.0 - y (:275, :3868), x * 2.0 made once.
    work = .{};
    _ = try throughMesa(&work, Contracted.words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .add));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .sub));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .mul));
    // Read again, x + y is kept: two fadds.
    work = .{};
    _ = try throughMesa(&work, ContractedNot.words);
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .add));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .mul));
}

test "the float identities of nir_opt_algebraic: a sum of a zero, a product of a zero or a one, an fneg twice and a value less itself, the whole vector or a float at a time" {
    // y - fneg(x) is y + x: one fadd, and nothing else computed.
    var work: Work = .{};
    _ = try throughMesa(&work, Identities.words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .add));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .mul));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .sub));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .negate));
    // A zero, written as it is: a constant and no instruction of it.
    work = .{};
    const zero = try throughMesa(&work, Cancelled.words);
    for ([_]Tag{ .add, .mul, .sub, .negate }) |tag| try testing.expectEqual(@as(usize, 0), stepsOf(&work, tag));
    try testing.expectEqual(@as(usize, 0), opsOf(zero, "fadd") + opsOf(zero, "fmul"));
    // x + x is x * 2.0 (:274), and 0 - y the fneg of y.
    work = .{};
    _ = try throughMesa(&work, Doubled.words);
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .add));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .sub));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .negate));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .mul));
    // A float at a time (nir_lower_alu_to_scalar): x.x + 0.5 and
    // x.z + 0.25 are sums, x.y and x.w the floats themselves; then
    // x.x + 0.5 itself, the fneg of x.y, a zero and x.w * 2.0. The zero
    // leaves x.z + 0.25 unread, and no instruction makes it.
    work = .{};
    const partly = try throughMesa(&work, PartlyFolded.words);
    for (work.program()) |each| switch (each.tag) {
        .add, .mul, .negate => try testing.expectEqual(Kind.f32x1, each.kind),
        .sub => return error.TestUnexpectedResult,
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .negate));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .mul));
    try testing.expectEqual(@as(usize, 1), countOf(partly, "fadd rf14, rf6, 0x3f000000"));
    try testing.expectEqual(@as(usize, 0), countOf(partly, "0x3e800000"));
    try testing.expectEqual(@as(usize, 1), countOf(partly, "xor "));
    try testing.expectEqual(@as(usize, 1), countOf(partly, "fmul rf17, rf13, 0x40000000"));
    try testing.expectEqual(@as(usize, 1), countOf(partly, "vfpack tlb, 0, rf17"));
    // Either operand the constant or the fneg; and the swizzle's z and w
    // are x.z and x.w twice, products by 2.0, its x and y x.y + x.x and
    // x.x + x.y, which nir_opt_cse takes for one sum.
    work = .{};
    _ = try throughMesa(&work, Mirrored.words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .add));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .mul));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .negate));
    for (work.program()) |each| switch (each.tag) {
        .add, .mul => try testing.expectEqual(Kind.f32x1, each.kind),
        else => {},
    };
    // x.x - x.y and x.y - x.x (:3868), x.z + y.z and x.w + y.w; then
    // x.x + y.x, x.y - y.y, x.z + y.z again and x.w - y.w; and the
    // product of the two, of four floats.
    work = .{};
    _ = try throughMesa(&work, Crossed.words);
    try testing.expectEqual(@as(usize, 3), stepsOf(&work, .add));
    try testing.expectEqual(@as(usize, 4), stepsOf(&work, .sub));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .negate));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .mul));
    // Through a component: y.x itself, and y.y + x.y.
    work = .{};
    _ = try throughMesa(&work, Through.words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .add));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .sub));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .negate));
}

test "an integer operation of constants is folded as NIR's 32-bit arithmetic is: wrapping, a shift by five bits of its amount, a float made one held to the range" {
    var work: Work = .{};
    const of = struct {
        fn word(w: *Work, value: u32) !u16 {
            const at = w.pool_count;
            w.pool[at] = @bitCast(value);
            w.pool_count += 1;
            return put(w, .{ .tag = .constant, .kind = .f32x1, .at = at });
        }
        fn folded(w: *Work, op: Integer, a: u32, b: ?u32) !u32 {
            const x = try word(w, a);
            const y: ?u16 = if (b) |value| try word(w, value) else null;
            const made = try integerOf(w, op, x, y);
            try testing.expectEqual(Tag.constant, w.steps[made].tag);
            return @bitCast(w.pool[w.steps[made].at]);
        }
    };
    const minus = struct {
        fn word(value: i32) u32 {
            return @bitCast(value);
        }
    }.word;
    const bits = struct {
        fn word(value: f32) u32 {
            return @bitCast(value);
        }
    }.word;
    try testing.expectEqual(@as(u32, 0), try of.folded(&work, .iadd, 0xFFFFFFFF, 1));
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), try of.folded(&work, .isub, 0, 1));
    try testing.expectEqual(@as(u32, 0x80000000), try of.folded(&work, .imul, 0x40000000, 2));
    try testing.expectEqual(@as(u32, 0x80000000), try of.folded(&work, .ineg, 0x80000000, null));
    try testing.expectEqual(@as(u32, 0x80000000), try of.folded(&work, .iabs, 0x80000000, null));
    try testing.expectEqual(@as(u32, 5), try of.folded(&work, .iabs, minus(-5), null));
    try testing.expectEqual(minus(-1), try of.folded(&work, .imin, 1, minus(-1)));
    try testing.expectEqual(@as(u32, 1), try of.folded(&work, .umin, 1, minus(-1)));
    try testing.expectEqual(@as(u32, 1), try of.folded(&work, .imax, 1, minus(-1)));
    try testing.expectEqual(minus(-1), try of.folded(&work, .umax, 1, minus(-1)));
    try testing.expectEqual(@as(u32, 2), try of.folded(&work, .ishl, 1, 33));
    try testing.expectEqual(minus(-1), try of.folded(&work, .ishr, 0x80000000, 63));
    try testing.expectEqual(@as(u32, 1), try of.folded(&work, .ushr, 0x80000000, 31));
    try testing.expectEqual(@as(u32, 0x0F), try of.folded(&work, .iand, 0xFF, 0x0F));
    try testing.expectEqual(@as(u32, 0xFF), try of.folded(&work, .ior, 0xF0, 0x0F));
    try testing.expectEqual(@as(u32, 0xF0), try of.folded(&work, .ixor, 0xFF, 0x0F));
    try testing.expectEqual(@as(u32, 0xFFFFFF00), try of.folded(&work, .inot, 0xFF, null));
    // Towards zero, as FTOIZ and FTOUZ are.
    try testing.expectEqual(minus(-3), try of.folded(&work, .f2i32, bits(-3.75), null));
    try testing.expectEqual(@as(u32, 3), try of.folded(&work, .f2u32, bits(3.75), null));
    // Out of the range Vulkan leaves undefined, and a NaN: held to it, 0.
    try testing.expectEqual(@as(u32, 0x7FFFFF80), try of.folded(&work, .f2i32, bits(1e20), null));
    try testing.expectEqual(@as(u32, 0x80000000), try of.folded(&work, .f2i32, bits(-1e20), null));
    try testing.expectEqual(@as(u32, 0), try of.folded(&work, .f2i32, bits(std.math.nan(f32)), null));
    try testing.expectEqual(@as(u32, 0), try of.folded(&work, .f2u32, bits(-5.0), null));
    try testing.expectEqual(bits(-2.0), try of.folded(&work, .i2f32, minus(-2), null));
    try testing.expectEqual(bits(4294967296.0), try of.folded(&work, .u2f32, 0xFFFFFFFF, null));
    // A step of anything but constants is not folded.
    const input = try put(&work, .{ .tag = .input, .kind = .f32x1 });
    try testing.expectEqual(Tag.integer, work.steps[try integerOf(&work, .iadd, input, try of.word(&work, 1))].tag);
}

test "a 32-bit integer is computed, compared and converted, but no varying and no colour is one, and a division of it fits the tables" {
    // The colour in made a vector of integers, the push constants' ivec4:
    // a varying of them would want flat interpolation, which is not
    // ported, and is refused by its type. The colour out the same: it
    // would want an integer format of the tile buffer.
    var work: Work = .{};
    try testing.expectError(Error.Type, throughMesa(&work, &comptime patched(&reference.glslc_integers, .type_pointer, 0, 2, 7)));
    try testing.expectError(Error.Type, throughMesa(&work, &comptime patched(&reference.glslc_integers, .type_pointer, 5, 2, 7)));
    // Its first OpIMul, the push constants' s.y times s.z, made OpSDiv:
    // nir_lower_idiv's lowering of it on top of the program's other
    // steps, more than the tables of 128 held (since 1.187) and fewer
    // than 256 (since 1.189). Its RECIP and ten 32-bit products, beside
    // the program's other one.
    var divided: Work = .{};
    const code = try throughMesa(&divided, &comptime reopcoded(&reference.glslc_integers, .i_mul, 0, .s_div));
    try testing.expect(divided.step_count > 128);
    try testing.expectEqual(@as(usize, 1), countOf(code, "recip "));
    try testing.expectEqual(@as(usize, 11), countOf(code, "umul24 "));
}

/// `words` with the `at`th instruction of `op` made one of `into`, its
/// operands as they were.
fn reopcoded(comptime words: []const u32, comptime op: spirv.Op, comptime at: u32, comptime into: spirv.Op) [words.len]u32 {
    comptime {
        var copy: [words.len]u32 = words[0..words.len].*;
        var seen: u32 = 0;
        var k: usize = 5;
        while (k < copy.len) {
            const count = copy[k] >> 16;
            if (count == 0) @compileError("a word count of zero");
            if (copy[k] & 0xFFFF == @intFromEnum(op)) {
                if (seen == at) {
                    copy[k] = count << 16 | @intFromEnum(into);
                    return copy;
                }
                seen += 1;
            }
            k += count;
        }
        @compileError("no such instruction to change");
    }
}

fn liveLogicOf(work: *const Work, which: Logic) usize {
    const reached = liveMask(work);
    var count: usize = 0;
    for (work.program(), 0..) |each, at| {
        if (each.tag == .logic and each.at == @intFromEnum(which) and reached[at]) count += 1;
    }
    return count;
}

test "through Mesa's back end, glslc's && and ||: each a selection flattened, its phi of bools an iand or an ior" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_logic);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    // The && phi's bcsel(a, b, a) is iand(a, b); the || one's
    // bcsel(inot(a), b, a) is bcsel(a, a, b), then ior(a, b). The
    // second comparison of the || is the inot of FOrdLessThan that
    // OpFUnordGreaterThanEqual is.
    try testing.expectEqual(@as(usize, 1), liveLogicOf(&work, .iand));
    try testing.expectEqual(@as(usize, 1), liveLogicOf(&work, .ior));
    try testing.expectEqual(@as(usize, 1), liveLogicOf(&work, .inot));
    try testing.expectEqual(@as(usize, 2), liveOf(&work, .select));
    // AND, OR and NOT each once in the program.
    var counts = [3]usize{ 0, 0, 0 };
    for (code.words) |word| {
        var buffer: [disasm.most_text]u8 = undefined;
        const line = disasm.disasm(word, &buffer).?;
        for ([_][]const u8{ "and ", "or ", "not " }, &counts) |name, *count| {
            if (std.mem.indexOf(u8, line, name) != null) count.* += 1;
        }
    }
    try testing.expectEqual([3]usize{ 1, 1, 1 }, counts);
    var plan: Work = .{};
    try testing.expectError(Error.Body, compile(&plan, &reference.glslc_logic));
}

test "through Mesa's back end, glslc's && and || without -O are the optimized module's program, to the word" {
    var theirs: Work = .{};
    const optimized = try throughMesa(&theirs, &reference.glslc_logic);
    const kept = try testing.allocator.dupe(u64, optimized.words);
    defer testing.allocator.free(kept);
    const stream_kept = try testing.allocator.dupe(Word, optimized.stream());
    defer testing.allocator.free(stream_kept);
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_logic_unoptimized);
    try testing.expectEqualSlices(u64, kept, code.words);
    try testing.expectEqual(stream_kept.len, code.stream().len);
    for (stream_kept, code.stream()) |a, b| try testing.expectEqual(a, b);
}

/// glslc_logic's shader in the IR: its && and || as `both` and `either`,
/// which is what its short circuits come to where their right sides only
/// compare, and its `!(w < 0.75)` a `not` of the comparison.
const Bools = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const half = b.scalar(0.5);
        const quarter = b.scalar(0.25);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const z = b.component(v, 2);
        const w = b.component(v, 3);
        const first = b.ifHolds(b.both(b.lessThan(x, half), b.greaterThan(y, quarter)));
        const doubled = b.mul(z, b.scalar(2));
        b.endIf(first);
        const red = b.merged(first, doubled, x);
        const second = b.ifHolds(b.either(b.lessThan(z, quarter), b.not(b.lessThan(w, b.scalar(0.75)))));
        b.endIf(second);
        const green = b.merged(second, half, y);
        b.color(b.vector(&.{ red, green, z, w }));
    }
});

test "through Mesa's back end, glslc's && and || are facet's both and either, to the word" {
    var theirs: Work = .{};
    const glslc = try throughMesa(&theirs, &reference.glslc_logic);
    var ours: Work = .{};
    const facet_made = try throughMesa(&ours, Bools.words);
    try testing.expectEqualSlices(u64, glslc.words, facet_made.words);
    try testing.expectEqual(glslc.stream().len, facet_made.stream().len);
    for (glslc.stream(), facet_made.stream()) |a, b| try testing.expectEqual(a, b);
}

/// Bools that nir_opt_algebraic takes apart: a `not` of a `not`, a `not`
/// of an equality, an `and` of a comparison with itself, and a select on a
/// `not`.
const Turned = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const half = b.scalar(0.5);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const z = b.component(v, 2);
        const w = b.component(v, 3);
        const red = b.select(b.not(b.not(b.lessThan(x, half))), y, z);
        const green = b.select(b.not(b.equal(y, half)), x, w);
        const kept = b.lessThan(z, half);
        const blue = b.select(b.not(b.both(kept, kept)), x, y);
        b.color(b.vector(&.{ red, green, blue, w }));
    }
});

/// What nir_opt_algebraic leaves of Turned, written so. It pops the last
/// instruction first (nir_search.c:880-906), so a select on a `not` is
/// turned before the `not` is looked at: the `not` of the equality is
/// left unread, not made an fneu.
const Untangled = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const half = b.scalar(0.5);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const z = b.component(v, 2);
        const w = b.component(v, 3);
        const red = b.select(b.lessThan(x, half), y, z);
        const green = b.select(b.equal(y, half), w, x);
        const blue = b.select(b.lessThan(z, half), y, x);
        b.color(b.vector(&.{ red, green, blue, w }));
    }
});

test "through Mesa's back end, nir_opt_algebraic's rules on bools: what they leave is the program of the shader written without them" {
    var written: Work = .{};
    const untangled = try throughMesa(&written, Untangled.words);
    const kept = try testing.allocator.dupe(u64, untangled.words);
    defer testing.allocator.free(kept);
    var work: Work = .{};
    const code = try throughMesa(&work, Turned.words);
    try testing.expectEqualSlices(u64, kept, code.words);
    // The select on inot(a) is on a, its arms swapped, inot(inot a) is a,
    // and iand(a, a) is a: no NOT and no AND is left.
    for (code.words) |word| {
        var buffer: [disasm.most_text]u8 = undefined;
        const line = disasm.disasm(word, &buffer).?;
        try testing.expect(std.mem.indexOf(u8, line, "not ") == null);
        try testing.expect(std.mem.indexOf(u8, line, "and ") == null);
    }
}

/// Selects of selects nir_opt_algebraic makes one or two of: on the same
/// condition in an arm (nir_opt_algebraic.py:979, :980), and on one
/// condition in both arms, sharing a value (:981, :983).
const Nests = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const half = b.scalar(0.5);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const z = b.component(v, 2);
        const w = b.component(v, 3);
        const lt = b.lessThan(x, half);
        const gt = b.greaterThan(y, half);
        const red = b.select(lt, b.select(lt, x, y), z);
        const green = b.select(lt, y, b.select(lt, z, w));
        const blue = b.select(lt, b.select(gt, z, x), b.select(gt, z, w));
        const alpha = b.select(lt, b.select(gt, w, y), b.select(gt, x, y));
        b.color(b.vector(&.{ red, green, blue, alpha }));
    }
});

/// What Mesa leaves of Nests, written so: the new selects where the old
/// outer one was, the inner of two first.
const NestsLeft = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const half = b.scalar(0.5);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const z = b.component(v, 2);
        const w = b.component(v, 3);
        const lt = b.lessThan(x, half);
        const gt = b.greaterThan(y, half);
        const red = b.select(lt, x, z);
        const green = b.select(lt, y, w);
        const blue = b.select(gt, z, b.select(lt, x, w));
        const alpha = b.select(gt, b.select(lt, w, x), y);
        b.color(b.vector(&.{ red, green, blue, alpha }));
    }
});

/// A select of one float twice (:1936), a select read once in an arm of
/// another that shares its other arm's float (:2512, :2513), and two
/// selects alike, which nir_opt_cse makes one before the select of them is
/// a select of one float twice.
const Joined = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const half = b.scalar(0.5);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const z = b.component(v, 2);
        const w = b.component(v, 3);
        const lt = b.lessThan(x, half);
        const gt = b.greaterThan(y, half);
        const red = b.select(lt, w, w);
        const green = b.select(lt, b.select(gt, y, z), z);
        const blue = b.select(lt, b.select(gt, z, x), z);
        const alpha = b.select(gt, b.select(lt, w, x), b.select(lt, w, x));
        b.color(b.vector(&.{ red, green, blue, alpha }));
    }
});

/// What Mesa leaves of Joined, written so: the iands where the selects of
/// them are, an inot before its iand.
const JoinedLeft = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const half = b.scalar(0.5);
        const x = b.component(v, 0);
        const y = b.component(v, 1);
        const z = b.component(v, 2);
        const w = b.component(v, 3);
        const lt = b.lessThan(x, half);
        const gt = b.greaterThan(y, half);
        const green = b.select(b.both(lt, gt), y, z);
        const blue = b.select(b.both(lt, b.not(gt)), x, z);
        const alpha = b.select(lt, w, x);
        b.color(b.vector(&.{ w, green, blue, alpha }));
    }
});

test "through Mesa's back end, selects of selects: what nir_opt_algebraic and nir_opt_cse leave is the program of the shader written so" {
    inline for (.{ .{ Nests, NestsLeft }, .{ Joined, JoinedLeft } }) |pair| {
        var written: Work = .{};
        const left = try throughMesa(&written, pair[1].words);
        const kept = try testing.allocator.dupe(u64, left.words);
        defer testing.allocator.free(kept);
        var work: Work = .{};
        const code = try throughMesa(&work, pair[0].words);
        try testing.expectEqualSlices(u64, kept, code.words);
    }
    // Joined's iands, and its inot of the second comparison.
    var work: Work = .{};
    _ = try throughMesa(&work, Joined.words);
    try testing.expectEqual(@as(usize, 2), liveLogicOf(&work, .iand));
    try testing.expectEqual(@as(usize, 1), liveLogicOf(&work, .inot));
    try testing.expectEqual(@as(usize, 3), liveOf(&work, .select));
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

/// `reference.glslc_uniform_buffer`'s shader as facet's emitter writes it:
/// the colour times a uniform buffer's tint and strength, plus its shift.
const Material = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const tint = b.uniform(0, 0, 0, .f32x4);
        const strength = b.uniform(0, 0, 16, .f32x1);
        const shift = b.uniform(0, 0, 24, .f32x2);
        const r = b.add(b.mul(b.mul(b.component(v, 0), b.component(tint, 0)), strength), b.component(shift, 0));
        const g = b.add(b.mul(b.mul(b.component(v, 1), b.component(tint, 1)), strength), b.component(shift, 1));
        const bl = b.add(b.mul(b.mul(b.component(v, 2), b.component(tint, 2)), strength), b.scalar(0));
        b.color(b.vector(&.{ r, g, bl, b.component(v, 3) }));
    }
});

test "through Mesa's back end, a uniform buffer's members are read through unifa: written once, and stepped on by ldunifa" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_uniform_buffer);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    // One word of the stream, the buffer's address at offset 0, which an
    // ldunif loads into unifa itself; the tint's four floats, the
    // strength's one, an ldunifa that reads nothing from 20 to 24, and
    // the shift's two (ntq_emit_load_unifa, nir_to_vir.c:3398-3459).
    try testing.expectEqualSlices(Word, &.{.{ .ubo = .{ .set = 0, .binding = 0, .offset = 0 } }}, code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(code, "ldunifrf.unifa"));
    try testing.expectEqual(@as(usize, 8), countOf(code, "ldunifa"));
    // The shift's z, 0.0, adds nothing to the sum's (:236, a float at a
    // time; since 1.174).
    try testing.expectEqual(@as(usize, 20), code.words.len);
    // facet's emitter's module of the same shader: the same reads.
    var ours: Work = .{};
    const emitted = try throughMesa(&ours, Material.words);
    try testing.expectEqualSlices(Word, code.stream(), emitted.stream());
    try testing.expectEqual(@as(usize, 1), countOf(emitted, "ldunifrf.unifa"));
    try testing.expectEqual(@as(usize, 8), countOf(emitted, "ldunifa"));
    try testing.expectEqual(@as(usize, 20), emitted.words.len);
    // The plan has no hand-written program to hold one to.
    var plan: Work = .{};
    try testing.expectError(Error.Storage, compile(&plan, &reference.glslc_uniform_buffer));
}

test "through Mesa's back end, a load before the last one's, or of another uniform buffer, writes unifa again" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_uniform_buffers);
    // light.far at 64, then light.color at 0, before it: unifa again;
    // light.near at 16 reads on from color's end; mix_by.amount is in
    // the other buffer, at set 1, binding 2.
    try testing.expectEqualSlices(Word, &.{
        .{ .ubo = .{ .set = 0, .binding = 0, .offset = 64 } },
        .{ .ubo = .{ .set = 0, .binding = 0, .offset = 0 } },
        .{ .ubo = .{ .set = 1, .binding = 2, .offset = 0 } },
    }, code.stream());
    try testing.expectEqual(@as(usize, 3), countOf(code, "ldunifrf.unifa"));
    try testing.expectEqual(@as(usize, 13), countOf(code, "ldunifa"));
}

/// One member read twice, which nir_opt_cse makes one load_ubo.
const ReadTwice = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        b.color(b.add(b.uniform(0, 0, 0, .f32x4), b.mul(b.input(0, .f32x4), b.uniform(0, 0, 0, .f32x4))));
    }
});

/// A uniform buffer read in a selection's arm.
const ReadInArm = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const v = b.input(0, .f32x4);
        const x = b.component(v, 0);
        const chosen = b.ifHolds(b.lessThan(x, b.scalar(0.5)));
        const loaded = b.uniform(0, 0, 0, .f32x1);
        b.endIf(chosen);
        const red = b.merged(chosen, loaded, x);
        b.color(b.vector(&.{ red, b.component(v, 1), b.component(v, 2), b.component(v, 3) }));
    }
});

test "through Mesa's back end, two loads of one member are one, and a load in an arm keeps its selection a branch" {
    var work: Work = .{};
    const code = try throughMesa(&work, ReadTwice.words);
    // nir_opt_cse takes a load_ubo as it takes an ALU instruction
    // (CAN_REORDER, nir_intrinsics.py:1367): four ldunifas, not eight.
    try testing.expectEqual(@as(usize, 4), countOf(code, "ldunifa"));
    try testing.expectEqual(@as(usize, 1), code.stream().len);
    // No load_ubo is speculated (nir_opt_peephole_select.c:132-141), so
    // its arm is a branch. The varying's float is the phi's other way and
    // read nowhere past the merge, so it is the phi's register, moved
    // into before the selection, and the false way is empty
    // (empty_else_block). The load's float is uniform where the phi is
    // not, so not coalesced (nir_from_ssa.c:428-430) but moved into the
    // phi's register under the mask, the ldunifa being a signal's
    // (ntq_store_def). Its offset is a constant, so unifa is written in
    // the arm (ntq_emit_load_unifa).
    var armed: Work = .{};
    const branch = try throughMesa(&armed, ReadInArm.words);
    try testing.expectEqual(@as(usize, 1), stepsOf(&armed, .begin_if));
    try testing.expectEqual(@as(usize, 1), stepsOf(&armed, .phi));
    try testing.expectEqual(@as(usize, 1), countOf(branch, "bu.allna"));
    try testing.expectEqual(@as(usize, 1), countOf(branch, "bu."));
    try testing.expectEqual(@as(usize, 1), opsOf(branch, "mov.ifa"));
    try testing.expectEqual(@as(usize, 0), opsOf(branch, "xor.pushz"));
    try testing.expectEqual(@as(usize, 1), countOf(branch, "ldunifrf.unifa"));
    try testing.expectEqual(@as(usize, 25), branch.words.len);
    try expectStream(&[_]Word{ .{ .float = @bitCast(@as(u32, 4)) }, .{ .ubo = .{ .set = 0, .binding = 0, .offset = 0 } } }, branch.stream());
}

test "through Mesa's back end, a uniform buffer's block made BufferBlock is a storage buffer, and a uniform buffer bound nowhere is refused" {
    // glslc_uniform_buffer's `OpDecorate %16 Block` made BufferBlock.
    var stored = reference.glslc_uniform_buffer;
    var at: usize = 5;
    var found = false;
    while (at < stored.len) {
        const count = stored[at] >> 16;
        if (stored[at] == 0x00030047 and stored[at + 1] == 16 and stored[at + 2] == @intFromEnum(spirv.Decoration.block)) {
            stored[at + 2] = @intFromEnum(spirv.Decoration.buffer_block);
            found = true;
        }
        at += count;
    }
    try testing.expect(found);
    // The same eight ldunifas as the uniform buffer's, from unifa written
    // once: the buffer's address, which reaches to the shift's end at 32,
    // and a MOV into unifa, which a load_ssbo's ldunif is not made to
    // write itself (nir_to_vir.c:3421-3446; since 1.164). A program that
    // names a storage buffer has its early fragment tests not promoted
    // and writes Z: the TLBU's configuration last (nir_to_vir.c:2074,
    // :2098-2124; since 1.168).
    var work: Work = .{};
    const code = try throughMesa(&work, &stored);
    try expectStream(&.{
        .{ .ssbo = .{ .set = 0, .binding = 0, .reach = 32 } },
        .{ .float = @bitCast(@as(u32, 0xffffff84)) },
    }, code.stream());
    try testing.expectEqual(@as(usize, 0), countOf(code, "ldunifrf.unifa"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov unifa"));
    try testing.expectEqual(@as(usize, 8), countOf(code, "ldunifa"));
    // Its DescriptorSet made a second Binding: a buffer of no set.
    var unset = reference.glslc_uniform_buffer;
    at = 5;
    found = false;
    while (at < unset.len) {
        const count = unset[at] >> 16;
        if (unset[at] == 0x00040047 and unset[at + 1] == 18 and unset[at + 2] == @intFromEnum(spirv.Decoration.descriptor_set)) {
            unset[at + 2] = @intFromEnum(spirv.Decoration.binding);
            found = true;
        }
        at += count;
    }
    try testing.expect(found);
    var unbound: Work = .{};
    try testing.expectError(Error.Location, throughMesa(&unbound, &unset));
}

test "through Mesa's back end, a storage buffer is read through unifa, its runtime array at the offset its stride gives" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_storage_buffer);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    // Three load_ssbos: the tint at 0, the scale at 16, read on from the
    // tint's end, and values[2] at 32 + 2 * 16, past where a skip
    // reaches: unifa again, the address the ldunif before loaded, which
    // vir_uniform takes again (try_opt_ldunif, vir.c:2811), plus 64,
    // a constant of the stream (nir_to_vir.c:3439-3446). Then Z's
    // configuration, a storage buffer's program's (since 1.168).
    try expectStream(&.{
        .{ .ssbo = .{ .set = 0, .binding = 0, .reach = 80 } },
        .{ .float = @bitCast(@as(u32, 64)) },
        .{ .float = @bitCast(@as(u32, 0xffffff84)) },
    }, code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov unifa"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "add unifa"));
    try testing.expectEqual(@as(usize, 9), countOf(code, "ldunifa"));
    try testing.expectEqual(@as(usize, 30), code.words.len);
    var steps: usize = 0;
    for (work.program()) |each| {
        if (each.tag == .ssbo) steps += 1;
        try testing.expect(each.tag != .ubo);
    }
    try testing.expectEqual(@as(usize, 3), steps);
    // The plan has no hand-written program to hold one to.
    var plan: Work = .{};
    try testing.expectError(Error.Storage, compile(&plan, &reference.glslc_storage_buffer));
}

test "a runtime array is a storage buffer's last member, and nothing else's" {
    // BufferBlock made Block: a uniform buffer with a runtime array.
    var work: Work = .{};
    try testing.expectError(Error.Storage, throughMesa(&work, &comptime patched(&reference.glslc_storage_buffer, .decorate, 3, 1, @intFromEnum(spirv.Decoration.block))));
    // The scale and the values swapped in the struct: the runtime array
    // its second member, at 16, and not its last.
    const swapped = comptime patched(&patched(&reference.glslc_storage_buffer, .type_struct, 0, 2, 13), .type_struct, 0, 3, 6);
    var middle: Work = .{};
    try testing.expectError(Error.Storage, throughMesa(&middle, &swapped));
}

test "through Mesa's back end, a block's arrays and structs are read at the offsets their strides and members give" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_uniform_nested);
    // palette[2] at 32, then palette[0] at 0, behind it: unifa again;
    // tint.color at 48, past where a skip reaches, again; tint.amount at
    // 64 reads on, and so does last at 80, over three floats that are
    // read for nothing; palette[1].w at 28 writes it a fourth time.
    try testing.expectEqualSlices(Word, &.{
        .{ .ubo = .{ .set = 0, .binding = 0, .offset = 32 } },
        .{ .ubo = .{ .set = 0, .binding = 0, .offset = 0 } },
        .{ .ubo = .{ .set = 0, .binding = 0, .offset = 48 } },
        .{ .ubo = .{ .set = 0, .binding = 0, .offset = 28 } },
    }, code.stream());
    try testing.expectEqual(@as(usize, 4), countOf(code, "ldunifrf.unifa"));
    // 4 + 4 + 4 + 1 + 3 + 4 + 1, less last.w, which nothing reads and
    // no ldunifa after it steps over.
    try testing.expectEqual(@as(usize, 20), countOf(code, "ldunifa"));
    try testing.expectEqual(@as(usize, 47), code.words.len);
    var plan: Work = .{};
    try testing.expectError(Error.Storage, compile(&plan, &reference.glslc_uniform_nested));
}

test "through Mesa's back end, a matrix in a block is loaded column by column, and a matrix times a vector is matrix_multiply's sum" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_uniform_matrix);
    // One unifa write: the three columns at 0, 16 and 32, a float read
    // for nothing between each, then shift at 48; its w, which nothing
    // reads, is the last and dropped.
    try testing.expectEqualSlices(Word, &.{.{ .ubo = .{ .set = 0, .binding = 0, .offset = 0 } }}, code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(code, "ldunifrf.unifa"));
    try testing.expectEqual(@as(usize, 15), countOf(code, "ldunifa"));
    // Each of the three rows: the last column times z, then the second
    // times y and the first times x added on, then the shift - nine
    // fmuls and nine fadds beside the varyings' four of each.
    try testing.expectEqual(@as(usize, 13), countOf(code, "fmul"));
    try testing.expectEqual(@as(usize, 13), countOf(code, "fadd"));
    try testing.expectEqual(@as(usize, 30), code.words.len);
}

test "through Mesa's back end, the matrix arithmetic SPIR-V has: transposes, products, a scalar, an outer product, columns extracted" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_uniform_matrices);
    // a, b and c read on from one unifa write at 0, two floats for
    // nothing between columns; pad at 112 for the outer product reads on
    // as well, and pad.x after it writes unifa again. The -0 is the
    // negation's, an XOR of the sign (ntq_emit_alu's fneg).
    try testing.expectEqualSlices(Word, &.{
        .{ .ubo = .{ .set = 0, .binding = 0, .offset = 0 } },
        .{ .float = -0.0 },
        .{ .ubo = .{ .set = 0, .binding = 0, .offset = 112 } },
    }, code.stream());
    try testing.expectEqual(@as(usize, 2), countOf(code, "ldunifrf.unifa"));
    try testing.expectEqual(@as(usize, 33), countOf(code, "ldunifa"));
    try testing.expectEqual(@as(usize, 29), countOf(code, "fmul"));
    try testing.expectEqual(@as(usize, 25), countOf(code, "fadd"));
    try testing.expectEqual(@as(usize, 4), countOf(code, "fsub"));
    try testing.expectEqual(@as(usize, 51), code.words.len);
}

test "through Mesa's back end, a constant matrix is its columns' constants, read where the product first wants them" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_constant_matrix);
    // The vector subtracted, then the three columns: vtn makes a
    // constant's load_const where its value is first wanted, and the
    // matrix is wanted whole by OpMatrixTimesVector, after the FSub.
    try testing.expectEqualSlices(Word, &.{
        .{ .float = 0.90625 },  .{ .float = 0.84375 },  .{ .float = 0.46875 },
        .{ .float = -0.78125 }, .{ .float = -0.28125 }, .{ .float = -0.5625 },
        .{ .float = -0.4375 },  .{ .float = -0.53125 }, .{ .float = -0.3125 },
        .{ .float = -0.375 },   .{ .float = -0.71875 }, .{ .float = -0.8125 },
    }, code.stream());
    try testing.expectEqual(@as(usize, 12), countOf(code, "ldunif"));
    // Three fsubs; then each row the last column times z, and the second
    // times y and the first times x added on: nine fmuls and six fadds
    // beside the varyings' four of each.
    try testing.expectEqual(@as(usize, 3), countOf(code, "fsub"));
    try testing.expectEqual(@as(usize, 13), countOf(code, "fmul"));
    try testing.expectEqual(@as(usize, 10), countOf(code, "fadd"));
    try testing.expectEqual(@as(usize, 24), code.words.len);
}

test "a constant matrix of other than its columns' shape, or of other than constant columns, is refused" {
    var work: Work = .{};
    // The matrix's last column its own first float, %12: a float, not a
    // column.
    const float_column = comptime patched(&reference.glslc_constant_matrix, .constant_composite, 3, 4, 12);
    try testing.expectError(Error.Type, throughMesa(&work, &float_column));
    // The matrix type made one of two columns: the constant's three are
    // one too many.
    work = .{};
    const two_columns = comptime patched(&reference.glslc_constant_matrix, .type_matrix, 0, 2, 2);
    try testing.expectError(Error.Body, throughMesa(&work, &two_columns));
}

test "a transpose of a transpose is the matrix itself, and two transposes multiplied are the transpose of the other product" {
    // vtn_ssa_transpose remembers what it transposed (spirv_to_nir.c:
    // 4486-4510), and matrix_multiply reads that where both of its are
    // transposes (vtn_alu.c:69-77).
    var work: Work = .{};
    var a = Matrix{ .count = 2 };
    var b = Matrix{ .count = 2 };
    for (0..2) |c| {
        a.columns[c] = try put(&work, .{ .tag = .ubo, .kind = .f32x2, .at = @intCast(16 * c) });
        b.columns[c] = try put(&work, .{ .tag = .ubo, .kind = .f32x2, .at = @intCast(32 + 16 * c) });
    }
    const at_a = try keptMatrix(&work, a);
    const at_b = try keptMatrix(&work, b);
    const ta = try transposeOf(&work, at_a);
    const before = work.step_count;
    try testing.expectEqual(at_a, try transposeOf(&work, ta));
    try testing.expectEqual(before, work.step_count);
    // Column 0 of the transpose is the vector of both columns' first
    // floats.
    const first = work.steps[work.matrices[ta].columns[0]];
    try testing.expectEqual(Tag.construct, first.tag);
    try testing.expectEqualSlices(u16, &.{ a.columns[0], a.columns[1] }, first.from[0..2]);
    try testing.expectEqualSlices(u8, &.{ 0, 0 }, first.part[0..2]);
    // transpose(A) times transpose(B): the transpose of B times A, whose
    // column 0 is B's first column times A's first column's x, added to
    // B's second times its y.
    const tb = try transposeOf(&work, at_b);
    const product = try multiplied(&work, work.matrices[ta], work.matrices[tb]);
    try testing.expect(product.transposed != none);
    const sum = work.steps[work.matrices[product.transposed].columns[0]];
    try testing.expectEqual(Tag.add, sum.tag);
    const head = work.steps[sum.a];
    const last = work.steps[sum.b];
    try testing.expectEqual(Tag.mul, head.tag);
    try testing.expectEqual(Tag.mul, last.tag);
    try testing.expectEqual(b.columns[0], head.a);
    try testing.expectEqual(b.columns[1], last.a);
    try testing.expectEqual(a.columns[0], work.steps[head.b].a);
    try testing.expectEqual(@as(u32, 0), work.steps[head.b].at);
    try testing.expectEqual(@as(u32, 1), work.steps[last.b].at);
}

test "a block without its strides, an index past an array, a row-major matrix and a stride of no whole word are refused" {
    // nested's ArrayStride made a Location: the array has no layout.
    var work: Work = .{};
    try testing.expectError(Error.Storage, throughMesa(&work, &comptime patched(&reference.glslc_uniform_nested, .decorate, 1, 1, @intFromEnum(spirv.Decoration.location))));
    // Of 18 bytes, which ldunifa's words do not land on.
    try testing.expectError(Error.Storage, throughMesa(&work, &comptime patched(&reference.glslc_uniform_nested, .decorate, 1, 2, 18)));
    // palette[3], one past its end.
    try testing.expectError(Error.Body, throughMesa(&work, &comptime patched(&reference.glslc_uniform_nested, .access_chain, 0, 4, 14)));
    // matrix's MatrixStride made a second Offset: no stride for its
    // columns.
    try testing.expectError(Error.Storage, throughMesa(&work, &comptime patched(&reference.glslc_uniform_matrix, .member_decorate, 1, 2, @intFromEnum(spirv.Decoration.offset))));
    try testing.expectError(Error.Storage, throughMesa(&work, &comptime patched(&reference.glslc_uniform_matrix, .member_decorate, 1, 3, 0)));
    // Its ColMajor made RowMajor, whose columns are not a vector's floats
    // side by side.
    try testing.expectError(Error.Refused, throughMesa(&work, &comptime patched(&reference.glslc_uniform_matrix, .member_decorate, 0, 2, @intFromEnum(spirv.Decoration.row_major))));
}

test "through Mesa's back end, a block read at an offset computed, the same in every lane, writes unifa with the buffer's address plus the offset" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_indexed);
    // Each load's offset as v3d's nir_opt_algebraic leaves it, in the
    // order of the loads: the index shifted where its stride is a power
    // of two and multiplied where it is not, the constant of the deref
    // chain added before it. other + 1 is read by two chains, so its
    // shift by 4 is distributed (:729) and its product by 48 a round
    // after, the shift having left it read once (:736); every constant
    // then gathered into one (:2438).
    const expected = [_]struct { tag: Tag, kind: Kind, shape: []const u8 }{
        // tints[which], at 0 and 16 apart.
        .{ .tag = .ubo_indirect, .kind = .f32x4, .shape = "ishl(p0, 4)" },
        // weights[other + 1], at 64 and 16 apart (std140).
        .{ .tag = .ubo_indirect, .kind = .f32x1, .shape = "iadd(80, ishl(p1, 4))" },
        // turns[which], at 128 and 32 apart: its columns 16 apart.
        .{ .tag = .ubo_indirect, .kind = .f32x2, .shape = "iadd(128, ishl(p0, 5))" },
        .{ .tag = .ubo_indirect, .kind = .f32x2, .shape = "iadd(144, ishl(p0, 5))" },
        // triples[which].b and triples[other + 1].c, at 32 and 48 apart.
        .{ .tag = .ssbo_indirect, .kind = .f32x4, .shape = "iadd(48, imul(p0, 48))" },
        .{ .tag = .ssbo_indirect, .kind = .f32x4, .shape = "iadd(112, imul(p1, 48))" },
        // scale[other], at 16 and 4 apart (std430), and base[which].
        .{ .tag = .ssbo_indirect, .kind = .f32x1, .shape = "iadd(16, ishl(p1, 2))" },
        .{ .tag = .ssbo_indirect, .kind = .f32x1, .shape = "ishl(p0, 2)" },
    };
    var found: usize = 0;
    for (work.program()) |each| {
        try testing.expect(each.tag != .ubo and each.tag != .ssbo);
        if (each.tag != .ubo_indirect and each.tag != .ssbo_indirect) continue;
        try testing.expect(found < expected.len);
        try testing.expectEqual(expected[found].tag, each.tag);
        try testing.expectEqual(expected[found].kind, each.kind);
        var shape = shapeOf(&work, each.a);
        try testing.expectEqualStrings(expected[found].shape, shape.text());
        found += 1;
    }
    try testing.expectEqual(expected.len, found);
    // Each an ADD of the address and the offset into unifa
    // (nir_to_vir.c:3441-3444), the uniform buffer's address of an
    // offset of 0, and loaded again where the last load of it is past
    // try_opt_ldunif's reach (vir.c:2811); the constants that are no
    // small immediates; and a storage buffer's address, which no load at
    // a constant offset reaches into (`reachOf`).
    const int = struct {
        fn of(value: u32) Word {
            return .{ .float = @bitCast(value) };
        }
    }.of;
    const ubo: Word = .{ .ubo = .{ .set = 0, .binding = 0, .offset = 0 } };
    const ssbo: Word = .{ .ssbo = .{ .set = 0, .binding = 1, .reach = 0 } };
    // The order the scheduler leaves them in, of the steps nir_opt_dce
    // leaves (since 1.167), and Z's configuration last, a storage
    // buffer's program's (since 1.168).
    try expectStream(&.{ .{ .push = 0 }, ubo, .{ .push = 1 }, int(80), int(128), int(16), int(144), ubo, int(48), ssbo, int(112), ssbo, int(0xffffff84) }, code.stream());
    try testing.expectEqual(@as(usize, 8), countOf(code, "add unifa"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "mov unifa"));
    // 4 + 1 + 2 + 2 + 4 + 4 + 1 + 1 words: no load reads on from the
    // last one's address, which an offset computed does not keep
    // (:3398-3400).
    try testing.expectEqual(@as(usize, 19), countOf(code, "ldunifa"));
    try testing.expectEqual(@as(usize, 5), countOf(code, "shl "));
    try testing.expectEqual(@as(usize, 2), countOf(code, "multop"));
    try testing.expectEqual(@as(usize, 2), countOf(code, "umul24"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "tmu"));
    // The two floats of 0.0 added to the colour's last two add nothing
    // (:236, a float at a time; since 1.174).
    try testing.expectEqual(@as(usize, 74), code.words.len);
}

test "through Mesa's back end, a block read at an offset that differs from lane to lane is the TMU's general lookup, a pixel's where nothing wants the helper pixels" {
    // The index the colour's red gives: an offset that differs, which
    // ntq_emit_load_unifa leaves to the TMU (nir_to_vir.c:3315-3317).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_divergent);
    var load: u16 = none;
    for (work.program(), 0..) |each, at| if (each.tag == .ubo_indirect) {
        load = @intCast(at);
    };
    try testing.expect(load != none);
    try testing.expect(work.divergent[load]);
    // Read into the colour alone: ACCESS_SKIP_HELPERS
    // (nir_opt_load_skip_helpers.c:258-275).
    try testing.expect(work.skip_helpers[load]);
    // The buffer's address of an offset of 0 (:563-574), and the
    // configuration TMUAU takes (:640-670): a regular lookup (:213-226),
    // a pixel's, of four words.
    const ubo: Word = .{ .ubo = .{ .set = 0, .binding = 0, .offset = 0 } };
    const config: u32 = 0xffffff00 | 15 << 3 | 1 << 7 | 4;
    try testing.expectEqual(@as(u32, 0xFFFFFFFC), config);
    try expectStream(&.{ .{ .float = 3 }, ubo, .{ .float = @bitCast(config) } }, code.stream());
    try testing.expectEqual(@as(usize, 0), code.sampled().len);
    try testing.expectEqual(@as(u8, 4), code.threads);
    // The ADD of the address and the offset into TMUAU (:466-488), the
    // thread switch the flush makes the last, a pair, and an LDTMU for
    // each float (ntq_flush_tmu, :266-300).
    try expectText(code, &.{
        text("nop", "nop", "ldvary.rf4"),
        text("nop", "fmul rf5, rf4, rf3", "ldvary.rf7"),
        text("fadd rf6, rf0, rf5", "fmul rf8, rf7, rf3", "ldvary.rf10"),
        text("fadd rf9, rf0, rf8", "fmul rf11, rf10, rf3", "ldvary.rf13"),
        text("fadd rf12, rf0, rf11", "fmul rf14, rf13, rf3", "ldunifrf.rf16"),
        text("fadd rf15, rf0, rf14", "fmul rf17, rf6, rf16", "ldunif"),
        text("ftoiz rf18, rf17", "nop", ""),
        text("shl rf19, rf18, 4", "nop", ""),
        text("add tmuau, rf0, rf19", "nop", "thrsw"),
        text("nop", "nop", "thrsw"),
        text("nop", "nop", ""),
        text("nop", "nop", "ldtmu.rf20"),
        text("nop", "fmul rf24, rf6, rf20", "ldtmu.rf21"),
        text("nop", "fmul rf25, rf9, rf21", "ldtmu.rf22"),
        text("vfpack tlb, rf24, rf25", "fmul rf26, rf12, rf22", "ldtmu.rf23"),
        text("nop", "fmul rf27, rf15, rf23", ""),
        text("vfpack tlb, rf26, rf27", "nop", "thrsw"),
        text("nop", "nop", ""),
        text("nop", "nop", ""),
    });
}

test "through Mesa's back end, a load at an offset that differs, read into a sample's coordinate, is a quad's; one read into the colour alone a pixel's, of the default configuration" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_quad);
    var coordinate: u16 = none;
    var scale: u16 = none;
    var sampled: u16 = none;
    for (work.program(), 0..) |each, at| switch (each.tag) {
        .ubo_indirect => if (each.kind == .f32x2) {
            coordinate = @intCast(at);
        } else {
            scale = @intCast(at);
        },
        .sample => sampled = @intCast(at),
        else => {},
    };
    try testing.expect(coordinate != none and scale != none and sampled != none);
    // The sample's level of detail is worked out across the quad, so its
    // coordinate wants the helper pixels (nir_opt_load_skip_helpers.c:
    // 151-157); the sample and the scale, read into the colour alone, do
    // not (:258-275).
    try testing.expect(!work.skip_helpers[coordinate]);
    try testing.expect(work.skip_helpers[scale]);
    try testing.expect(work.skip_helpers[sampled]);
    // The coordinate's lookup a quad's, of two words (nir_to_vir.c:
    // 640-670): TMUAU and its configuration. The scale's a pixel's, of a
    // 32-bit word, which is the default and goes to TMUA with no
    // uniform (:463-467, :485-488). The sample's P1 with the per-pixel
    // mask (v3d_tex.c:311-321).
    const ubo: Word = .{ .ubo = .{ .set = 0, .binding = 0, .offset = 0 } };
    const quad_config: u32 = 0xffffff00 | 15 << 3 | 0 << 7 | 2;
    try testing.expectEqual(@as(u32, 0xFFFFFF7A), quad_config);
    try expectStream(&.{
        .{ .float = 3 },                             ubo,
        .{ .float = @bitCast(quad_config) },         .{ .texture = 0 },
        .{ .sampler = .{ .bits = per_pixel_mask } }, .{ .float = @bitCast(@as(u32, 64)) },
        ubo,
    }, code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(code, "add tmuau, "));
    try testing.expectEqual(@as(usize, 1), countOf(code, "add tmua, "));
    try testing.expectEqual(@as(usize, 5), countOf(code, "ldtmu"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "unifa"));
    try testing.expectEqual(Sampler{ .set = 0, .binding = 1 }, code.sampled()[0]);
}

test "through Mesa's back end, a sample at a coordinate the same in every lane keeps its helper pixels" {
    // The coordinate read at an index of the push constants: through
    // unifa, and nothing of the sample differs from lane to lane, so
    // nir_opt_load_skip_helpers leaves it alone (add_load_to_worklist,
    // :98-113) and P1's per-pixel mask is off (v3d_tex.c:311-321).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_steady);
    for (work.program(), 0..) |each, at| if (each.tag == .sample) {
        try testing.expect(!work.divergent[at]);
        try testing.expect(!work.skip_helpers[at]);
    };
    const ubo: Word = .{ .ubo = .{ .set = 0, .binding = 0, .offset = 0 } };
    try testing.expectEqualSlices(Word, &.{ .{ .push = 0 }, ubo, .{ .texture = 0 }, .{ .sampler = .{} } }, code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(code, "add unifa"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "tmua"));
}

test "through Mesa's back end, a load that nothing reads is not in the program" {
    // glslc -O0 stores it into a variable nothing loads; nir_opt_dce
    // takes the load out, where v3d's own dead code elimination would
    // keep the TMU's lookup (vir_opt_dead_code.c:207). What is left is
    // the interpolated colour (since 1.167).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_dead);
    for (work.program()) |each| try testing.expect(each.tag == .input);
    var smooth: Work = .{};
    const colour = try throughMesa(&smooth, Smooth.words);
    try testing.expectEqualSlices(u64, colour.words, code.words);
    try testing.expectEqual(@as(usize, 0), code.stream().len);
}

test "through Mesa's back end, a storage buffer is written through the TMU, a pixel's, and read where it is written through the TMU too" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_writes);
    var stores: usize = 0;
    var load: u16 = none;
    for (work.program(), 0..) |each, at| switch (each.tag) {
        .ssbo_store => stores += 1,
        .ssbo => load = @intCast(at),
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), stores);
    try testing.expect(load != none and !work.steps[load].non_writeable);
    try testing.expect(work.buffers_written and work.uses_ssbo);
    const int = struct {
        fn of(value: u32) Word {
            return .{ .float = @bitCast(value) };
        }
    }.of;
    const written: Word = .{ .ssbo = .{ .set = 0, .binding = 1, .reach = 32 } };
    // The count's 2.0 into TMUD and the address alone into TMUA, a
    // pixel's 32-bit word, the default configuration (nir_to_vir.c:
    // 456-492); the row through TMUAU, its four floats a pixel's vec4,
    // 0xffffff00 | 15 << 3 | 1 << 7 | 4 (:650-670): a store's lookup is
    // never a quad's. The last, a load of a buffer the program writes,
    // through the TMU at its constant offset 16 and not unifa
    // (:3338-3343): a quad's, for a load the same in every lane does not
    // skip the helper pixels (no_add_divergence,
    // nir_opt_load_skip_helpers.c:99-113). And Z, for a program that
    // names a storage buffer writes it (since 1.168).
    try expectStream(&.{ int(0x3fc00000), written, int(48), .{ .ubo = .{ .set = 0, .binding = 0, .offset = 0 } }, int(0xfffffffc), int(32), written, int(0xfffffffc), int(16), int(0xffffff7c), int(0xffffff84) }, code.stream());
    try testing.expectEqual(@as(usize, 5), countOf(code, "mov tmud"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmua,"));
    try testing.expectEqual(@as(usize, 3), countOf(code, "add tmuau"));
    // Each flush waits for the stores before it: one TMUWT however many
    // there are (ntq_flush_tmu, nir_to_vir.c:266-299).
    try testing.expectEqual(@as(usize, 2), countOf(code, "tmuwt"));
    try testing.expectEqual(@as(usize, 8), countOf(code, "ldtmu"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "unifa"));
    try testing.expect(code.tmu_dirty_rcl);
    try testing.expect(code.writes_z and code.disable_ez);
    try testing.expectEqual(@as(usize, 34), code.words.len);
}

test "through Mesa's back end, a readonly buffer is read through unifa where the program writes none, and a readonly member where it writes the rest" {
    // NonWritable on the variable and each member, and no store: the
    // count through unifa, the row at an index that differs through the
    // TMU, a pixel's, and nothing left dirty.
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_reads);
    try testing.expect(!work.buffers_written and work.uses_ssbo);
    try expectStream(&.{
        .{ .float = @bitCast(@as(u32, 0x3fc00000)) },
        .{ .float = @bitCast(@as(u32, 32)) },
        .{ .ssbo = .{ .set = 0, .binding = 1, .reach = 4 } },
        .{ .float = @bitCast(@as(u32, 0xfffffffc)) },
        .{ .float = @bitCast(@as(u32, 0xffffff84)) },
    }, code.stream());
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov unifa"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "ldunifa"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "add tmuau"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "tmud"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "tmuwt"));
    try testing.expect(!code.tmu_dirty_rcl);
    try testing.expect(code.writes_z and code.disable_ez);
    try testing.expectEqual(@as(usize, 25), code.words.len);
    // A readonly count in a buffer the program writes the rows of: its
    // member's NonWritable makes the load ACCESS_NON_WRITEABLE all the
    // same (nir_opt_access.c), through unifa; the last, of a member that
    // is not, through the TMU.
    var member: Work = .{};
    const written = try throughMesa(&member, &reference.glslc_member);
    try testing.expect(member.buffers_written);
    try testing.expectEqual(@as(usize, 1), countOf(written, "ldunifa"));
    try testing.expectEqual(@as(usize, 4), countOf(written, "mov tmud"));
    try testing.expectEqual(@as(usize, 2), countOf(written, "add tmuau"));
    try testing.expectEqual(@as(usize, 1), countOf(written, "tmuwt"));
    try testing.expect(written.tmu_dirty_rcl);
}

test "through Mesa's back end, a whole matrix stored into a storage buffer is its columns, each stored at its MatrixStride" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_placed);
    // The mat4's four columns 16 bytes apart, the mat3x2's three 8 apart
    // from 64, as std430 lays them and the decorations say
    // (_vtn_variable_load_store, vtn_variables.c:763-780).
    const offsets = [_]u32{ 0, 16, 32, 48, 64, 72, 80 };
    const kinds = [_]Kind{ .f32x4, .f32x4, .f32x4, .f32x4, .f32x2, .f32x2, .f32x2 };
    var count: usize = 0;
    for (work.program()) |each| {
        if (each.tag != .ssbo_store) continue;
        try testing.expect(count < offsets.len);
        try testing.expectEqual(offsets[count], each.at);
        try testing.expectEqual(kinds[count], each.kind);
        try testing.expectEqual(@as(u16, none), each.from[0]);
        count += 1;
    }
    try testing.expectEqual(offsets.len, count);
    const int = struct {
        fn of(value: u32) Word {
            return .{ .float = @bitCast(value) };
        }
    }.of;
    const placed: Word = .{ .ssbo = .{ .set = 0, .binding = 1, .reach = 88 } };
    // A column of four floats 0xfffffffc, of two 0xfffffffa
    // (nir_to_vir.c:650-670), each through TMUAU at its offset.
    try expectStream(&.{
        .{ .ubo = .{ .set = 0, .binding = 0, .offset = 0 } }, placed,          int(0xfffffffc), int(16),         int(0xfffffffc), int(32),
        int(0xfffffffc),                                      int(48),         int(0xfffffffc), placed,          int(64),         int(0xfffffffa),
        int(72),                                              int(0xfffffffa), int(80),         int(0xfffffffa), int(0xffffff84),
    }, code.stream());
    try testing.expectEqual(@as(usize, 22), countOf(code, "mov tmud"));
    try testing.expectEqual(@as(usize, 7), countOf(code, "tmuau"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "tmuwt"));
    try testing.expect(code.tmu_dirty_rcl);
    try testing.expectEqual(@as(usize, 57), code.words.len);
}

test "a store into a uniform buffer, or in a vertex program, is refused" {
    // glslc_writes's `OpDecorate %22 BufferBlock` made Block: the buffer
    // it writes is a uniform buffer.
    var uniform: Work = .{};
    try testing.expectError(Error.Storage, throughMesa(&uniform, &comptime patched(&reference.glslc_writes, .decorate, 2, 1, @intFromEnum(spirv.Decoration.block))));
    // A vertex program runs as the coordinate shader too, and would
    // write twice.
    var vertex: Work = .{};
    try testing.expectError(Error.Storage, vertexThroughMesa(&vertex, &reference.glslc_vertex_store, .{}));
}

test "through Mesa's back end, a storage buffer's atomics are the TMU's own operations, an add of 1 its increment, each a pixel's and each read back" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_atomics);
    // The ten in their order: translate_atomic_op's operations
    // (spirv_to_nir.c), each at its member's offset, each divergent
    // (nir_divergence_analysis.c:994-1010), the compare-exchange's value
    // its second operand (fill_common_atomic_sources, :3698-3702).
    const ops = [_]Atomic{ .iadd, .iadd, .ior, .imax, .imin, .iand, .xchg, .cmpxchg, .umin, .umax };
    var seen: usize = 0;
    for (work.program(), 0..) |each, at| {
        if (each.tag != .ssbo_atomic) continue;
        try testing.expect(seen < ops.len);
        try testing.expectEqual(ops[seen], each.atomic);
        try testing.expectEqual(@as(u32, @intCast(4 * seen)), each.at);
        try testing.expectEqual(@as(u16, none), each.from[0]);
        try testing.expectEqual(each.atomic == .cmpxchg, each.from[1] != none);
        try testing.expect(work.divergent[at]);
        seen += 1;
    }
    try testing.expectEqual(ops.len, seen);
    try testing.expect(work.buffers_written and work.uses_ssbo);
    const int = struct {
        fn of(value: u32) Word {
            return .{ .float = @bitCast(value) };
        }
    }.of;
    const counters: Word = .{ .ssbo = .{ .set = 0, .binding = 1, .reach = 40 } };
    // Each atomic through TMUAU, its configuration 0xffffff00 | op << 3
    // | 1 << 7 | 7, a pixel's 32-bit word (nir_to_vir.c:650-669): the add
    // of 1 the increment, op 8 (v3d_get_op_for_atomic_add, :175-187),
    // the add of 3 the add, 0; or 9, signed max 7 and min 6, and 8, the
    // exchange 2, the compare-exchange 3 and a pixel's two words, 2
    // (:666-667), unsigned min 4 and max 5 (v3d_general_tmu_op_for_atomic,
    // :189-208). The offsets past 15 are uniforms, 4 to 12 small
    // immediates.
    try expectStream(&.{
        int(0x3fc00000), counters, int(0xffffffc7), int(0xffffff87), int(0xffffffcf), int(0xffffffbf), int(16),
        int(0xffffffb7), counters, int(20),         int(0xffffffc7), int(24),         int(0xffffff97), int(28),
        int(0xffffff9a), int(32),  int(0xffffffa7), counters,        int(36),         int(0xffffffaf), int(0xffffff84),
    }, code.stream());
    // The increment writes no TMUD (atomic_add_replaced, :507-519): nine
    // operands and the compare-exchange's second. Each returns its word,
    // read though the program reads none (nir_intrinsic_dest_components,
    // :612), and nothing waits on a write alone: no TMUWT
    // (ntq_flush_tmu, :266-299).
    try testing.expectEqual(@as(usize, 10), countOf(code, "mov tmud"));
    try testing.expectEqual(@as(usize, 10), countOf(code, "tmuau"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "tmua,"));
    try testing.expectEqual(@as(usize, 10), countOf(code, "ldtmu"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "tmuwt"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "unifa"));
    try testing.expect(code.tmu_dirty_rcl);
    try testing.expect(code.writes_z and code.disable_ez);
    try testing.expectEqual(@as(usize, 43), code.words.len);
}

test "through Mesa's back end, an atomic's result is a value, the decrement writes no operand either, and a barrier flushes the TMU" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_returned);
    var atomics: [4]u16 = @splat(none);
    var count: usize = 0;
    var barriers: usize = 0;
    for (work.program(), 0..) |each, at| switch (each.tag) {
        .ssbo_atomic => {
            try testing.expect(count < atomics.len);
            atomics[count] = @intCast(at);
            count += 1;
        },
        .barrier => barriers += 1,
        else => {},
    };
    try testing.expectEqual(@as(usize, 4), count);
    try testing.expectEqual(@as(usize, 1), barriers);
    const steps = work.program();
    // The add of 1 at the index the colour gives, its offset dynamic;
    // the add of 0xffffffff, ixor, and the compare-exchange of the first
    // two's results: the comparator first, the value second
    // (fill_common_atomic_sources, spirv_to_nir.c:3698-3702).
    try testing.expect(steps[atomics[0]].from[0] != none);
    try testing.expectEqual(Atomic.iadd, steps[atomics[1]].atomic);
    try testing.expectEqual(Atomic.ixor, steps[atomics[2]].atomic);
    try testing.expectEqual(Atomic.cmpxchg, steps[atomics[3]].atomic);
    try testing.expectEqual(atomics[0], steps[atomics[3]].a);
    try testing.expectEqual(atomics[1], steps[atomics[3]].from[1]);
    const int = struct {
        fn of(value: u32) Word {
            return .{ .float = @bitCast(value) };
        }
    }.of;
    // The increment 8 and the decrement 9 (v3d_get_op_for_atomic_add,
    // nir_to_vir.c:175-187), the xor 10, the compare-exchange 3, a
    // pixel's two words.
    try expectStream(&.{ int(0x3fc00000), .{ .ssbo = .{ .set = 0, .binding = 1, .reach = 20 } }, int(0xffffffc7), int(0xffffffcf), int(0xffffffd7), int(16), int(0xffffff9a), int(0x3a83126f), int(0xffffff84) }, code.stream());
    // Neither writes TMUD: the xor's 5, then the comparator and the value
    // (emit_tmu_general_atomic_writes, :400-420).
    try testing.expectEqual(@as(usize, 3), countOf(code, "mov tmud"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov tmud, 5"));
    // The first two results, read into registers in the order the
    // atomics went out, written to TMUD in that order.
    var lines: [64][disasm.most_text]u8 = undefined;
    var texts: [64][]const u8 = undefined;
    try testing.expect(code.words.len <= lines.len);
    for (code.words, 0..) |word, at| texts[at] = disasm.disasm(word, &lines[at]).?;
    var loaded: [2][]const u8 = undefined;
    var found: usize = 0;
    for (texts[0..code.words.len]) |line| {
        if (found == loaded.len) break;
        const k = std.mem.indexOf(u8, line, "ldtmu.") orelse continue;
        var end = k + "ldtmu.".len;
        while (end < line.len and line[end] != ';' and line[end] != ' ') end += 1;
        loaded[found] = line[k + "ldtmu.".len .. end];
        found += 1;
    }
    try testing.expectEqual(loaded.len, found);
    var written: [2]?usize = .{ null, null };
    for (loaded, 0..) |register, k| {
        var name: [32]u8 = undefined;
        const move = try std.fmt.bufPrint(&name, "mov tmud, {s}", .{register});
        for (texts[0..code.words.len], 0..) |line, at| {
            const i = std.mem.indexOf(u8, line, move) orelse continue;
            const after = i + move.len;
            if (after < line.len and std.ascii.isDigit(line[after])) continue;
            written[k] = at;
            break;
        }
    }
    try testing.expect(written[0] != null and written[1] != null and written[0].? < written[1].?);
    try testing.expectEqual(@as(usize, 4), countOf(code, "ldtmu"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "tmuwt"));
    try testing.expect(code.tmu_dirty_rcl);
    try testing.expectEqual(@as(usize, 27), code.words.len);
}

test "through Mesa's back end, an acquire-release atomic has a barrier before and after it, and the relaxed one none" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_ordered);
    // Semantics 72, AcquireRelease | UniformMemory: release, a barrier
    // before; acquire, a barrier after (vtn_split_barrier_semantics,
    // spirv_to_nir.c:2581-2661). The add of 2 relaxed, 0, none.
    var tags: [8]Tag = undefined;
    var count: usize = 0;
    for (work.program()) |each| switch (each.tag) {
        .ssbo_atomic, .barrier => {
            try testing.expect(count < tags.len);
            tags[count] = each.tag;
            count += 1;
        },
        else => {},
    };
    try testing.expectEqualSlices(Tag, &.{ .barrier, .ssbo_atomic, .barrier, .ssbo_atomic }, tags[0..count]);
    // The barrier after is a flush (nir_to_vir.c:3857-3861): the first's
    // word read before the second goes out.
    var read_first: ?usize = null;
    var second: ?usize = null;
    for (code.words, 0..) |word, at| {
        var buffer: [disasm.most_text]u8 = undefined;
        const line = disasm.disasm(word, &buffer).?;
        if (read_first == null and std.mem.indexOf(u8, line, "ldtmu") != null) read_first = at;
        if (std.mem.indexOf(u8, line, "mov tmud, 2") != null) second = at;
    }
    try testing.expect(read_first != null and second != null and read_first.? < second.?);
    try testing.expectEqual(@as(usize, 2), countOf(code, "ldtmu"));
    try testing.expectEqual(@as(usize, 17), code.words.len);
}

test "through Mesa's back end, a readonly buffer's words an atomic program wrote are read through unifa, and nothing is left dirty" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_counted);
    try testing.expect(!work.buffers_written and work.uses_ssbo);
    const int = struct {
        fn of(value: u32) Word {
            return .{ .float = @bitCast(value) };
        }
    }.of;
    const counters: Word = .{ .ssbo = .{ .set = 0, .binding = 1, .reach = 40 } };
    // The ten words through unifa, its address set at 8, at 20 and at
    // the start, the base held in two registers; 64, the 2 added to the
    // highest before its shift by 5 shifted itself (nir_opt_algebraic.py:
    // 728); then the factors past the small immediates: 1/512, 1/65536,
    // 1/196608 and 1/255. 1/64, 1/32 and the colour's 1/16 are small
    // immediates.
    try expectStream(&.{ counters, int(64), counters, int(20), int(0x3b000000), int(0x37800000), int(0x36aaaaab), int(0x3b808081), int(0xffffff84) }, code.stream());
    try testing.expectEqual(@as(usize, 13), countOf(code, "ldunifa"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "tmu"));
    try testing.expect(!code.tmu_dirty_rcl);
    try testing.expectEqual(@as(usize, 46), code.words.len);
}

test "an atomic in an arm is a branch, and one on a uniform buffer, or in a vertex program, is refused" {
    // An atomic is a write peephole_select cannot make a select of
    // (block_check_for_allowed_instrs, nir_opt_peephole_select.c:106-236),
    // so its arm is a branch. Its address goes to the TMU under the mask
    // (ntq_emit_tmu_general), so a channel that does not take the arm
    // adds nothing. Its thread switch is in the arm, so the last one is
    // another at the top level (vir_emit_last_thrsw): the arm's, the
    // pair, and the end's.
    var armed: Work = .{};
    const code = try throughMesa(&armed, &reference.glslc_armed);
    try testing.expectEqual(@as(usize, 1), stepsOf(&armed, .begin_if));
    try testing.expectEqual(@as(usize, 1), stepsOf(&armed, .ssbo_atomic));
    try testing.expectEqual(@as(usize, 1), countOf(code, "mov.ifa tmuau"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "bu.allna"));
    try testing.expectEqual(@as(usize, 4), countOf(code, "thrsw"));
    try testing.expect(code.writes_z);
    try testing.expectEqual(@as(usize, 23), code.words.len);
    // glslc_atomics's `OpDecorate %21 BufferBlock` made Block.
    var uniform: Work = .{};
    try testing.expectError(Error.Storage, throughMesa(&uniform, &comptime patched(&reference.glslc_atomics, .decorate, 1, 1, @intFromEnum(spirv.Decoration.block))));
    // The coordinate shader would add as well.
    var vertex: Work = .{};
    try testing.expectError(Error.Storage, vertexThroughMesa(&vertex, &reference.glslc_vertex_atomic, .{}));
}

test "an index computed into the push constants is refused, and the plan holds no block read" {
    // push.colors[push.which], which v3dv reads from its buffer of the
    // push constants.
    var work: Work = .{};
    try testing.expectError(Error.Storage, throughMesa(&work, &reference.glslc_pushed));
    // The plan has no hand-written program to hold a block read to.
    var plan: Work = .{};
    try testing.expectError(Error.Storage, compile(&plan, &reference.glslc_indexed));
}

test "nir_opt_algebraic's rules of an address's arithmetic, each on the integer operations it matches" {
    const Case = struct {
        shape: []const u8,
        build: *const fn (*Work) Error!u16,
    };
    const of = struct {
        fn push(work: *Work, word: u32) Error!u16 {
            return put(work, .{ .tag = .push, .kind = .f32x1, .at = word });
        }
        fn int(work: *Work, value: i32) Error!u16 {
            return integerSplat(work, .f32x1, value);
        }
        fn op(work: *Work, which: Integer, a: u16, b: u16) Error!u16 {
            return put(work, integerStep(which, .f32x1, a, b));
        }
        // :183, :190 and :188: a product by a power of two a shift.
        fn eight(work: *Work) Error!u16 {
            return op(work, .imul, try push(work, 0), try int(work, 8));
        }
        fn minus_four(work: *Work) Error!u16 {
            return op(work, .imul, try push(work, 0), try int(work, -4));
        }
        fn sign(work: *Work) Error!u16 {
            return op(work, .imul, try push(work, 0), try int(work, std.math.minInt(i32)));
        }
        // :287, and :183 then :1800 of a one before the other operand.
        fn zero(work: *Work) Error!u16 {
            return op(work, .imul, try push(work, 0), try int(work, 0));
        }
        fn one(work: *Work) Error!u16 {
            return op(work, .imul, try int(work, 1), try push(work, 0));
        }
        // :239.
        fn none_added(work: *Work) Error!u16 {
            return op(work, .iadd, try int(work, 0), try push(work, 0));
        }
        // :2423 and :2438.
        fn gathered(work: *Work) Error!u16 {
            return op(work, .iadd, try op(work, .iadd, try push(work, 0), try push(work, 1)), try int(work, 5));
        }
        fn folded(work: *Work) Error!u16 {
            return op(work, .iadd, try int(work, 3), try op(work, .iadd, try push(work, 0), try int(work, 4)));
        }
        // :729, its iadd's constant first, and of an iadd read twice.
        fn shifted(work: *Work) Error!u16 {
            return op(work, .ishl, try op(work, .iadd, try int(work, 1), try push(work, 0)), try int(work, 4));
        }
        fn shifted_twice(work: *Work) Error!u16 {
            const sum = try op(work, .iadd, try push(work, 0), try int(work, 1));
            return op(work, .iadd, try op(work, .ishl, sum, try int(work, 4)), sum);
        }
        // :730 and :739.
        fn shifted_sum(work: *Work) Error!u16 {
            const inner = try op(work, .iadd, try push(work, 0), try int(work, 1));
            return op(work, .ishl, try op(work, .iadd, inner, try push(work, 1)), try int(work, 2));
        }
        fn multiplied_sum(work: *Work) Error!u16 {
            const inner = try op(work, .iadd, try push(work, 0), try int(work, 2));
            return op(work, .imul, try op(work, .iadd, inner, try push(work, 1)), try int(work, 3));
        }
        // :736, and not of an iadd read twice.
        fn multiplied(work: *Work) Error!u16 {
            return op(work, .imul, try op(work, .iadd, try push(work, 0), try int(work, 1)), try int(work, 3));
        }
        fn multiplied_twice(work: *Work) Error!u16 {
            const sum = try op(work, .iadd, try push(work, 0), try int(work, 1));
            return op(work, .iadd, try op(work, .imul, sum, try int(work, 3)), sum);
        }
    };
    const cases = [_]Case{
        .{ .shape = "ishl(p0, 3)", .build = &of.eight },
        .{ .shape = "ineg(ishl(p0, 2))", .build = &of.minus_four },
        .{ .shape = "ishl(p0, 31)", .build = &of.sign },
        .{ .shape = "0", .build = &of.zero },
        .{ .shape = "p0", .build = &of.one },
        .{ .shape = "p0", .build = &of.none_added },
        .{ .shape = "iadd(iadd(p0, 5), p1)", .build = &of.gathered },
        .{ .shape = "iadd(7, p0)", .build = &of.folded },
        .{ .shape = "iadd(ishl(p0, 4), 16)", .build = &of.shifted },
        .{ .shape = "iadd(iadd(ishl(p0, 4), 16), iadd(p0, 1))", .build = &of.shifted_twice },
        .{ .shape = "iadd(ishl(iadd(p0, p1), 2), 4)", .build = &of.shifted_sum },
        .{ .shape = "iadd(imul(iadd(p0, p1), 3), 6)", .build = &of.multiplied_sum },
        .{ .shape = "iadd(imul(p0, 3), 3)", .build = &of.multiplied },
        .{ .shape = "iadd(imul(iadd(p0, 1), 3), iadd(p0, 1))", .build = &of.multiplied_twice },
    };
    for (cases) |case| {
        var work: Work = .{};
        work.stored = try case.build(&work);
        try algebraic(&work);
        var shape = shapeOf(&work, work.stored);
        try testing.expectEqualStrings(case.shape, shape.text());
    }
}

/// An integer value as the steps make it: a constant's first word, a
/// push constant's word, and an operation of those.
const Shape = struct {
    buffer: [256]u8 = undefined,
    len: usize = 0,

    fn add(shape: *Shape, text_of: []const u8) void {
        @memcpy(shape.buffer[shape.len..][0..text_of.len], text_of);
        shape.len += text_of.len;
    }

    fn of(shape: *Shape, work: *const Work, at: u16) void {
        const each = work.steps[at];
        var digits: [16]u8 = undefined;
        switch (each.tag) {
            .constant => shape.add(std.fmt.bufPrint(&digits, "{d}", .{@as(i32, @bitCast(work.pool[each.at]))}) catch unreachable),
            .push => shape.add(std.fmt.bufPrint(&digits, "p{d}", .{each.at}) catch unreachable),
            .integer => {
                const op: Integer = @enumFromInt(each.at);
                shape.add(@tagName(op));
                shape.add("(");
                shape.of(work, each.a);
                if (!op.unary()) {
                    shape.add(", ");
                    shape.of(work, each.b);
                }
                shape.add(")");
            },
            else => shape.add(@tagName(each.tag)),
        }
    }

    fn text(shape: *const Shape) []const u8 {
        return shape.buffer[0..shape.len];
    }
};

fn shapeOf(work: *const Work, at: u16) Shape {
    var shape: Shape = .{};
    shape.of(work, at);
    return shape;
}

/// The index of a VPM row as the stream holds it, a constant's bits.
fn vpmIndex(row: u32) Word {
    return .{ .float = @bitCast(row) };
}

fn vertexThroughMesa(work: *Work, words: []const u32, key: VertexKey) !Code {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    return compileVertexVir(work, words, testing.allocator, &compiler, key);
}

test "through Mesa's back end, a vertex shader is a vertex program: its attributes read from the VPM, its varyings and the fixed-function outputs written to it" {
    var work: Work = .{};
    var key = VertexKey{};
    key.reads[0] = 4;
    const code = try vertexThroughMesa(&work, &reference.glslc_vertex_as_it_is, key);
    // The inputs by location: p, c and moved at driver locations 0, 1
    // and 2, all of each read.
    try testing.expectEqual(@as(u8, 3), code.vertex.attribute_count);
    try testing.expectEqualSlices(u8, &.{ 0, 1, 3 }, code.vertex.attribute_location[0..3]);
    try testing.expectEqualSlices(u8, &.{ 4, 4, 2 }, code.vertex.vattr_sizes[0..3]);
    // Ten floats in and eight out (the place, Zs, 1/Wc and the colour):
    // the input's two sectors, which the output shares.
    try testing.expectEqual(@as(u8, 2), code.vertex.vpm_output_sectors);
    // No thread switch but the end's: it starts in its last section.
    try testing.expect(code.vertex.single_seg);
    try testing.expectEqual(@as(u8, 4), code.threads);
    // A load of each float where it is first read, p's, moved's, then c's
    // at rows 4 to 7, which the colour is stored back into; then the place
    // at rows 0 and 1, Zs at 2 and 1/Wc at 3, each with the viewport's
    // word it is scaled by.
    try testing.expectEqualSlices(Word, &.{
        vpmIndex(0),               vpmIndex(1), vpmIndex(2),               vpmIndex(3),
        vpmIndex(8),               vpmIndex(9), vpmIndex(4),               vpmIndex(5),
        vpmIndex(6),               vpmIndex(7), .{ .viewport = .x_scale }, vpmIndex(0),
        .{ .viewport = .y_scale }, vpmIndex(1), .{ .viewport = .z_scale }, .{ .viewport = .z_offset },
        vpmIndex(2),               vpmIndex(3),
    }, code.stream());
    try testing.expectEqual(@as(usize, 10), countOf(code, "ldvpmv_in"));
    try testing.expectEqual(@as(usize, 8), countOf(code, "stvpmv"));
    // moved times W twice, then x and y each times its scale and 1/Wc,
    // and z the same; the place's two sums and Zs's.
    try testing.expectEqual(@as(usize, 8), countOf(code, "fmul"));
    try testing.expectEqual(@as(usize, 3), countOf(code, "fadd"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "recip"));
    // The place on screen rounded to the nearest 1/64th, the fround_even
    // a dead FROUND beside it.
    try testing.expectEqual(@as(usize, 2), countOf(code, "ftoin"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "fround"));
    try testing.expectEqual(@as(usize, 31), code.words.len);
}

test "through Mesa's back end, the coordinate program writes the position and its place on screen alone, and reads only what they are made of" {
    var work: Work = .{};
    var key = VertexKey{ .coordinate = true };
    key.reads[0] = 4;
    const code = try vertexThroughMesa(&work, &reference.glslc_vertex_as_it_is, key);
    // c is read by no output, so none of it is loaded: moved is VPM rows
    // 4 and 5, which the place on screen is written back into.
    try testing.expectEqual(@as(u8, 3), code.vertex.attribute_count);
    try testing.expectEqualSlices(u8, &.{ 4, 0, 2 }, code.vertex.vattr_sizes[0..3]);
    try testing.expectEqual(@as(u8, 1), code.vertex.vpm_output_sectors);
    try testing.expect(code.vertex.single_seg);
    try testing.expectEqualSlices(Word, &.{
        vpmIndex(0), vpmIndex(1), vpmIndex(2),               vpmIndex(3),
        vpmIndex(4), vpmIndex(5), .{ .viewport = .x_scale }, .{ .viewport = .y_scale },
        vpmIndex(5),
    }, code.stream());
    try testing.expectEqual(@as(usize, 6), countOf(code, "ldvpmv_in"));
    try testing.expectEqual(@as(usize, 6), countOf(code, "stvpmv"));
    try testing.expectEqual(@as(usize, 6), countOf(code, "fmul"));
    try testing.expectEqual(@as(usize, 2), countOf(code, "fadd"));
    try testing.expectEqual(@as(usize, 2), countOf(code, "ftoin"));
    try testing.expectEqual(@as(usize, 19), code.words.len);
}

test "a vertex program stores what the fragment program reads alone, 0 where nothing was stored, and loads what that is made of" {
    var work: Work = .{};
    // Two floats of location 0 and one of location 1: the colour's red
    // and green, and a float nothing writes.
    var key = VertexKey{};
    key.reads[0] = 2;
    key.reads[1] = 1;
    const code = try vertexThroughMesa(&work, &reference.glslc_vertex_as_it_is, key);
    // c's first two floats alone (nir_lower_io_vars_to_scalar and
    // nir_opt_dce, v3d_nir_lower_vs_early).
    try testing.expectEqualSlices(u8, &.{ 4, 2, 2 }, code.vertex.vattr_sizes[0..3]);
    try testing.expectEqual(@as(usize, 8), countOf(code, "ldvpmv_in"));
    // The two, then the four fixed ones, then the 0.
    try testing.expectEqual(@as(usize, 7), countOf(code, "stvpmv"));
    // Four fixed and three varyings: one sector out, but the eight in
    // are one too.
    try testing.expectEqual(@as(u8, 1), code.vertex.vpm_output_sectors);
}

test "a vertex shader that writes other than gl_Position and gl_PointSize of gl_PerVertex, or is read as a fragment shader, is refused" {
    var work: Work = .{};
    // The store's access chain at member 2, gl_ClipDistance: %30, a 2.
    const clip_distance = comptime patched(&reference.glslc_vertex_as_it_is, .access_chain, 2, 3, 30);
    try testing.expectError(Error.Outputs, vertexThroughMesa(&work, &clip_distance, .{}));
    // At member 1, gl_PointSize, whose float is not the vec4 the chain's
    // type points to.
    work = .{};
    const point_size = comptime patched(&reference.glslc_vertex_as_it_is, .access_chain, 2, 3, 9);
    try testing.expectError(Error.Type, vertexThroughMesa(&work, &point_size, .{}));
    work = .{};
    try testing.expectError(Error.Stage, throughMesa(&work, &reference.glslc_vertex_as_it_is));
}

test "a loop of a constant trip count is unrolled as nir_opt_loop_unroll unrolls it: four runs, no branch; its variables form the optimized module's program to the word" {
    // `for (int i = 0; i < 4; i++)`: the test at the top, so
    // opt_loop_peel_initial_break peels the first run, the loop then
    // tests the update def, and its trip count is 3 (find_trip_count's
    // trip_offset); simple_unroll makes the peeled run and three more.
    // float(i) of each is a constant, and v * 0.0625 is made once. The
    // first run's float(i) is 0, its product 0 (nir_opt_algebraic.py:277)
    // and its two sums the other operand (:236; since 1.174), so the sum
    // is v * 0.0625 itself; the second run adds it to a sum of it read
    // once, which is that sum's other operand plus it times 2.0 (:275;
    // since 1.175).
    var theirs: Work = .{};
    const optimized = try throughMesa(&theirs, &reference.glslc_looped);
    try testing.expectEqual(@as(usize, 5), stepsOf(&theirs, .add));
    try testing.expectEqual(@as(usize, 5), stepsOf(&theirs, .mul));
    try testing.expectEqual(@as(usize, 0), stepsOf(&theirs, .begin_if));
    try testing.expectEqual(@as(usize, 0), countOf(optimized, "bu"));
    try testing.expectEqual(@as(usize, 0), countOf(optimized, ".if"));
    const kept = try testing.allocator.dupe(u64, optimized.words);
    defer testing.allocator.free(kept);
    const stream_kept = try testing.allocator.dupe(Word, optimized.stream());
    defer testing.allocator.free(stream_kept);
    // The variables form: `sum` and `i` in variables, the test in a block
    // of its own and the update in the continue block.
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_looped_plain);
    try testing.expectEqual(@as(u32, 2), work.local_count);
    try testing.expectEqualSlices(u64, kept, code.words);
    try testing.expectEqual(stream_kept.len, code.stream().len);
    for (stream_kept, code.stream()) |a, b| try testing.expectEqual(a, b);
}

test "a loop that leaves at its first test is no run; one whose test is at its end runs once more than it steps" {
    // i < 0 from 0: will_break_on_first_iteration, a trip count of 0, and
    // the peeled run is the loop's break alone: the sum is its zero.
    var work: Work = .{};
    const never = comptime patched(&reference.glslc_looped, .constant, 2, 2, 0);
    _ = try throughMesa(&work, &never);
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .add));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .mul));
    // do { ... i++; } while (i < 3): the test of the update def at the
    // loop's end, nothing to peel, a trip count of 3 and three runs.
    work = .{};
    _ = try throughMesa(&work, &reference.glslc_until);
    try testing.expectEqual(@as(usize, 3), stepsOf(&work, .max));
    try testing.expectEqual(@as(usize, 3), stepsOf(&work, .mul));
    // A float from 0 by 0.25 while under 1: get_iteration's fsub and
    // fdiv, 4, and test_iterations' check of 3 to 5. The first run's
    // product is of 0.0, which (('fmul(nsz,nnan)', 'a', 0.0), 0.0)
    // (nir_opt_algebraic.py:277) makes a zero, and its fmax of that and
    // the sum's zero is the zero nir_opt_constant_folding makes of it
    // (since 1.176): three.
    work = .{};
    _ = try throughMesa(&work, &reference.glslc_stepped);
    try testing.expectEqual(@as(usize, 3), stepsOf(&work, .max));
}

test "a loop counted down, or by a product, is counted as nir_loop_analyze counts it" {
    // for (int i = 3; i >= 0; i--): the isub an iadd of -1
    // (nir_opt_algebraic.py), the test an ige; runs at 3, 2, 1 and 0.
    var work: Work = .{};
    const down = comptime patched(&patched(&patched(&retyped(&retyped(&reference.glslc_cheap, .i_add, 0, .i_sub), .s_less_than, 0, .s_greater_than_equal), .constant, 0, 2, 3), .constant, 1, 2, 0), .constant, 2, 2, 1);
    _ = try throughMesa(&work, &down);
    try testing.expectEqual(@as(usize, 4), stepsOf(&work, .max));
    // for (int i = 1; i < 17; i *= 2): get_iteration_empirical, a run at
    // 1, 2, 4, 8 and 16.
    work = .{};
    const doubled = comptime patched(&patched(&retyped(&reference.glslc_cheap, .i_add, 0, .i_mul), .constant, 0, 2, 1), .constant, 2, 2, 2);
    _ = try throughMesa(&work, &doubled);
    try testing.expectEqual(@as(usize, 5), stepsOf(&work, .max));
    // x *= 0.25 of a float: an fmul is not counted (calculate_iterations),
    // so the loop is not unrolled, and a loop kept is refused.
    work = .{};
    const scaled = comptime retyped(&reference.glslc_stepped, .f_add, 0, .f_mul);
    try testing.expectError(Error.Branches, throughMesa(&work, &scaled));
}

test "a loop is unrolled to 16 trips and a cost of 16 * 26, more where its LoopControl asks, and none where it asks not to be" {
    // 17 runs of an fadd and an fmax of four floats: a trip count of 16,
    // max_unroll_iterations (v3dv_pipeline.c), at a cost of 16 * 8. The
    // first run's fadd is of the sum's 0.0, which the unrolled program
    // does not keep (nir_opt_algebraic.py:236; since 1.174).
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_cheap);
    try testing.expectEqual(@as(usize, 16), stepsOf(&work, .add));
    try testing.expectEqual(@as(usize, 17), stepsOf(&work, .max));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .begin_if));
    // 18 runs are 17 trips, over the limit (check_unrolling_restrictions)...
    work = .{};
    const longer = comptime patched(&reference.glslc_cheap, .constant, 1, 2, 18);
    try testing.expectError(Error.Branches, throughMesa(&work, &longer));
    // ...but not for a loop of Unroll, which is unrolled whatever it costs.
    work = .{};
    const asked = comptime patched(&longer, .loop_merge, 0, 2, 1);
    _ = try throughMesa(&work, &asked);
    try testing.expectEqual(@as(usize, 18), stepsOf(&work, .max));
    // DontUnroll: the loop kept, which is refused.
    work = .{};
    const kept = comptime patched(&reference.glslc_looped, .loop_merge, 0, 2, 2);
    try testing.expectError(Error.Branches, throughMesa(&work, &kept));
    // 17 runs of twelve operations of four floats: a cost of 16 * 48,
    // over 16 * 26.
    work = .{};
    try testing.expectError(Error.Branches, throughMesa(&work, &reference.glslc_costly));
}

test "a loop to a push constant, one left by a break, and one in another are refused" {
    // No trip count, a second terminator, and a loop not innermost: what
    // only complex_unroll or a loop kept (ntq_emit_loop) would take.
    var work: Work = .{};
    try testing.expectError(Error.Branches, throughMesa(&work, &reference.glslc_bounded));
    work = .{};
    try testing.expectError(Error.Branches, throughMesa(&work, &reference.glslc_broken));
    work = .{};
    try testing.expectError(Error.Branches, throughMesa(&work, &reference.glslc_loop_in_loop));
}

test "calculate_iterations: a count Mesa's bias test finds no exit for, a loop peeled, and an ine of no step" {
    const bits = struct {
        fn of(x: f32) u32 {
            return @bitCast(x);
        }
    }.of;
    // for (float x = 0.0; x != 0.9; x += 0.2), nir_loop_analyze.c's own
    // example: 4.5 runs, and 3, 4 or 5 of 0.2 are no 0.9.
    const never: Test = .{ .cmp = .fneu, .limit = bits(0.9), .limit_rhs = true, .invert = true, .on_def = false };
    try testing.expectEqual(@as(?u32, null), tripCount(never, .{ .init = bits(0.0), .update = .fadd, .step = bits(0.2), .phi_first = true }));
    // i < 4 from 0 by 1, tested after the update once peeled: 3 trips.
    const peeled: Test = .{ .cmp = .ilt, .limit = 4, .limit_rhs = true, .invert = true, .on_def = true };
    const counted: Induction = .{ .init = 0, .update = .iadd, .step = 1, .phi_first = true };
    try testing.expectEqual(@as(?u32, 3), tripCount(peeled, counted));
    // The same not peeled: 4.
    var unpeeled = peeled;
    unpeeled.on_def = false;
    try testing.expectEqual(@as(?u32, 4), tripCount(unpeeled, counted));
    // while (i == 5) from 5: by 1 a run, by 0 never left.
    const same: Test = .{ .cmp = .ieq, .limit = 5, .limit_rhs = true, .invert = true, .on_def = false };
    try testing.expectEqual(@as(?u32, 1), tripCount(same, .{ .init = 5, .update = .iadd, .step = 1, .phi_first = true }));
    try testing.expectEqual(@as(?u32, null), tripCount(same, .{ .init = 5, .update = .iadd, .step = 0, .phi_first = true }));
}

/// Two samplers at one binding of two sets: two units, the set telling
/// them apart as descriptor_map_add's does.
const TwoSets = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const uv = b.input(0, .f32x2);
        b.color(b.mul(b.sample(0, 0, uv), b.sample(1, 0, uv)));
    }
});

/// One sampler read twice, compared once and once not: the TMU is given
/// one state for it, which holds a comparison or does not.
const MixedCompare = ir.Fragment(struct {
    pub fn body(b: *ir.Build) void {
        const uv = b.input(0, .f32x2);
        b.color(b.scale(b.sample(0, 0, uv), b.sampleCompared(0, 0, uv, b.input(1, .f32x1))));
    }
});

test "through Mesa's back end, two textures are two units, given as descriptor_map_add gives them, and a sampler read again keeps its unit" {
    // glslc's `base` at 0, 0, `detail` at 1, 2, and `base` again: three
    // lookups, each its two configuration words of its unit, and two
    // words back each (texel_words).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_two_textures);
    try testing.expectEqualSlices(Sampler, &.{ .{ .set = 0, .binding = 0 }, .{ .set = 1, .binding = 2 } }, code.sampled());
    try expectStream(&.{
        .{ .texture = 0 }, .{ .sampler = .{ .unit = 0, .bits = per_pixel_mask } },
        .{ .texture = 1 }, .{ .sampler = .{ .unit = 1, .bits = per_pixel_mask } },
        .{ .texture = 0 }, .{ .sampler = .{ .unit = 0, .bits = per_pixel_mask } },
    }, code.stream());
    try testing.expectEqual(@as(usize, 3), countOf(code, "tmus"));
    try testing.expectEqual(@as(usize, 6), countOf(code, "ldtmu"));
    // The first sample made one of `detail`, declared second: the units
    // are in the order the program reads the samplers, not the module
    // declares them. The load of `base` the first sample reads, %14, is
    // the first OpLoad, of %13 made of %20.
    work = .{};
    const swapped = comptime patched(&reference.glslc_two_textures, .load, 0, 2, 20);
    const other = try throughMesa(&work, &swapped);
    try testing.expectEqualSlices(Sampler, &.{ .{ .set = 1, .binding = 2 }, .{ .set = 0, .binding = 0 } }, other.sampled());
    try testing.expectEqual(Word{ .texture = 0 }, other.stream()[0]);
    try testing.expectEqual(Word{ .texture = 0 }, other.stream()[2]);
    try testing.expectEqual(Word{ .texture = 1 }, other.stream()[4]);
    // The ir's two samplers of one set, and two of one binding in two.
    work = .{};
    const twice = try throughMesa(&work, Twice.words);
    try testing.expectEqualSlices(Sampler, &.{ .{ .set = 0, .binding = 0 }, .{ .set = 0, .binding = 1 } }, twice.sampled());
    work = .{};
    const sets = try throughMesa(&work, TwoSets.words);
    try testing.expectEqualSlices(Sampler, &.{ .{ .set = 0, .binding = 0 }, .{ .set = 1, .binding = 0 } }, sets.sampled());
    // The plan has one TMU lookup a program still.
    work = .{};
    try testing.expectError(Error.Samplers, compile(&work, &reference.glslc_two_textures));
}

test "through Mesa's back end, a loop of four samples is four lookups of one unit, and a sampler compared once and once not is refused" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_sampled_loop);
    try testing.expectEqualSlices(Sampler, &.{.{ .set = 0, .binding = 0 }}, code.sampled());
    var textures: usize = 0;
    for (code.stream()) |word| switch (word) {
        .texture => |unit| {
            try testing.expectEqual(@as(u8, 0), unit);
            textures += 1;
        },
        .sampler => |each| try testing.expectEqual(@as(u8, 0), each.unit),
        else => {},
    };
    try testing.expectEqual(@as(usize, 4), textures);
    try testing.expectEqual(@as(usize, 4), countOf(code, "tmus"));
    try testing.expectEqual(@as(usize, 8), countOf(code, "ldtmu"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "bu"));
    work = .{};
    try testing.expectError(Error.Samplers, throughMesa(&work, MixedCompare.words));
}

test "an array of the function's own a loop Mesa unrolls indexes is a variable of each element, as nir_split_array_vars makes it" {
    // weights[i] at the counter of each run, a constant once the loop is
    // unrolled (since 1.176). The sum of color times each element is
    // color times (0.25 + 0.5) + 0.25: the factor gathered (:246), the
    // sum of constants the 1.0 nir_opt_constant_folding makes of it, and
    // the product of a one taken out (:292). What is left is color times
    // scale[0] and scale[1] added, an fmul and an fadd of each float
    // besides each varying's six.
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_local_array);
    try testing.expectEqual(@as(u32, 3), work.local_count);
    try testing.expectEqual(@as(usize, 15), code.words.len);
    try testing.expectEqual(@as(usize, 6 + 4), opsOf(code, "fmul"));
    try testing.expectEqual(@as(usize, 6 + 4), opsOf(code, "fadd"));
    try testing.expectEqual(@as(usize, 0), code.stream().len);
    // At -O0 both arrays, the sum and the counter are variables, each
    // element of `scale` stored and loaded through a chain: the same
    // words.
    var kept: Work = .{};
    const same = try throughMesa(&kept, &reference.glslc_local_array_kept);
    try testing.expectEqual(@as(u32, 3 + 2 + 1 + 1), kept.local_count);
    try testing.expectEqualSlices(u64, code.words, same.words);
}

test "a struct of the function's own is a variable of each member, as nir_split_struct_vars makes it, a whole one loaded and stored member by member" {
    // l and m, each a vec3 and a float; m stored from a load of the whole
    // of l, member by member (vtn_variables.c:763-781; since 1.176).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_local_struct);
    try testing.expectEqual(@as(u32, 4), work.local_count);
    // The dot of m.dir and (0, 0, 1) its products and sums, as
    // nir_lower_alu_to_scalar lowers it: 1.0 times 1.0, the constant 1.0,
    // and the fmuls of 0.0 zeros (:277), each fadd of a zero the other
    // (:236). Its fmax of 0.0 is the constant 1.0 too, and color.rgb times
    // it color.rgb (:292): the operations of glslc -O's values, in which a
    // product of 1.0 is all that is left of the dot, color's four
    // varyings and m.power times color.rgb. spirv-opt has taken `uv` out
    // of that module, whose two floats the walk still reads here, their
    // interpolation unread (since 1.167).
    try testing.expectEqual(@as(usize, 0), opsOf(code, "fmax"));
    try testing.expectEqual(@as(usize, 4 + 4), opsOf(code, "fmul"));
    try testing.expectEqual(@as(usize, 4), opsOf(code, "fadd"));
    try testing.expectEqual(@as(usize, 14), code.words.len);
    var values: Work = .{};
    const same = try throughMesa(&values, &reference.glslc_local_struct_values);
    try testing.expectEqual(@as(u32, 0), values.local_count);
    try testing.expectEqual(@as(u32, 6), code.varyings);
    try testing.expectEqual(@as(u32, 4), same.varyings);
    inline for (.{ "fmax", "fmul", "fadd", "vfpack" }) |op| try testing.expectEqual(opsOf(same, op), opsOf(code, op));
    try testing.expectEqual(same.words.len, code.words.len);
}

test "an array a loop stores into at its counter, and an array of structs from a constant of it, read through chains to a float of a member" {
    // acc[i] stored in each run, its counter a constant there (since
    // 1.176): color.x times 0.0, 1.0, 2.0 and 3.0. acc[0] + acc[1] is
    // color.x, a zero (:277) and color.x (:292) summed (:236); the others
    // an fmul of color.x each, acc[2]'s times taps[1].weight again, and
    // acc[3] + taps[0].offset.y an fadd. Of color only its x is read, one
    // varying's fmul and fadd.
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_local_taps);
    try testing.expectEqual(@as(u32, 4), work.local_count);
    try testing.expectEqual(@as(usize, 1 + 3), opsOf(code, "fmul"));
    try testing.expectEqual(@as(usize, 1 + 1), opsOf(code, "fadd"));
    // At -O0 the counter and the array of structs are variables too, the
    // latter stored from a constant array of structs and read through
    // chains of three indexes, the last a float of a vector: i, acc, and
    // a vec2 and a float of each tap.
    var kept: Work = .{};
    const same = try throughMesa(&kept, &reference.glslc_local_taps_kept);
    try testing.expectEqual(@as(u32, 1 + 4 + 2 * 2), kept.local_count);
    try testing.expectEqualSlices(u64, code.words, same.words);
    try testing.expectEqual(code.stream().len, same.stream().len);
    for (code.stream(), same.stream()) |a, b| try testing.expectEqual(a, b);
}

test "an element of an aggregate of the function's own at an index the body computes is in scratch, and one past its end, or a member at no constant, is refused" {
    // weights[uv.x]: an index no unrolled loop's counter makes a
    // constant (since 1.176), of three vec4s, which no if-else tree
    // takes: in scratch, 48 bytes of each lane (since 1.177).
    var work: Work = .{};
    const computed = comptime patched(&reference.glslc_local_array, .access_chain, 2, 3, 30);
    const code = try throughMesa(&work, &computed);
    try testing.expectEqual(@as(u32, 48), work.scratch_size);
    try testing.expectEqual(@as(u32, 16 * 48), code.spill_size);
    // acc[4], of an array of four.
    work = .{};
    const past = comptime patched(&reference.glslc_local_taps_kept, .access_chain, 2, 3, 16);
    try testing.expectError(Error.Body, throughMesa(&work, &past));
    // taps[1].(i): a member's index is a constant, as SPIR-V has it.
    work = .{};
    const member = comptime patched(&reference.glslc_local_taps_kept, .access_chain, 5, 4, 25);
    try testing.expectError(Error.Body, throughMesa(&work, &member));
}

test "a matrix of the function's own is a variable of each column, a column stored through a chain and the whole loaded for a product" {
    // m's two columns, and v (since 1.176).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_local_matrix);
    try testing.expectEqual(@as(u32, 2 + 1), work.local_count);
    // glslc -O's values: the column put into the matrix by an
    // OpCompositeInsert, vtn_composite_insert's copy with the column
    // replaced (since 1.176). The same words.
    var values: Work = .{};
    const same = try throughMesa(&values, &reference.glslc_local_matrix_values);
    try testing.expectEqual(@as(u32, 0), values.local_count);
    try testing.expectEqualSlices(u64, same.words, code.words);
}

test "an array of bools of the function's own is a variable of each, and a load of the whole of one is refused" {
    // flags[1]'s comparison chooses the factor; flags[0]'s, which nothing
    // reads, is taken out (since 1.176).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_local_bools);
    try testing.expectEqual(@as(u32, 2), work.local_count);
    try testing.expectEqual(@as(usize, 1), countOf(code, "fcmp"));
    // The load of flags[1] made one of the whole array.
    work = .{};
    const whole = comptime patched(&patched(&reference.glslc_local_bools, .load, 3, 0, 9), .load, 3, 2, 11);
    try testing.expectError(Error.Storage, throughMesa(&work, &whole));
}

test "an array of the function's own stored in selections' arms: an element in one, the whole array in the other, each float chosen at the merge" {
    // pal and alt, two vec4s each. The arms store nothing but variables
    // of the function's own, through a chain or whole, and are flattened
    // (since 1.176): pal[1] is 1.0 where either comparison holds, the
    // inner select folded into the outer on an ior of the two
    // (nir_opt_algebraic.py:2514), and pal[0] alt[0]'s 0.25 where the
    // second does; a select of each float.
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_local_palette);
    try testing.expectEqual(@as(u32, 2 + 2), work.local_count);
    try testing.expectEqual(@as(usize, 2), liveOf(&work, .compare));
    try testing.expectEqual(@as(usize, 8), liveOf(&work, .select));
    try testing.expectEqual(@as(usize, 1), liveLogicOf(&work, .ior));
    try testing.expectEqual(@as(usize, 0), liveOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 31), code.words.len);
}

test "a struct of a matrix and a float, stored from one stored nowhere and made again in an arm, a float of its column read through three indexes" {
    // p and unset, two columns and a float each, and k (since 1.176).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_local_pair);
    try testing.expectEqual(@as(u32, 3 + 3 + 1), work.local_count);
    // In the order they are first used, which is the order
    // nir_lower_vars_to_ssa gives their values to the phi builder: unset,
    // loaded whole before anything is stored, then p, then k.
    try testing.expectEqualSlices(u8, &.{ 3, 4, 5, 0, 1, 2, 6 }, work.first_used[0..work.used_count]);
    // p.m[1] is (z, w) either way, which no select chooses; p.w, p.m[0].x
    // and k's four floats are chosen.
    try testing.expectEqual(@as(usize, 1), liveOf(&work, .compare));
    try testing.expectEqual(@as(usize, 6), liveOf(&work, .select));
    try testing.expectEqual(@as(usize, 21), code.words.len);
    // The first float out is color.w, the second of p.m[1], a chain of
    // three indexes to it, plus a select.
    const sum = liveStepOf(&work, .add);
    const first = partOf(&work, work.steps[sum].a, 0);
    try testing.expectEqual(Tag.input, work.steps[first.step].tag);
    try testing.expectEqual(@as(u8, 3), first.part);
}

test "nir_opt_constant_folding after each round of rules: an fsub of constants, a vec of constants a rule leaves times one, and a dot's products the last float first" {
    // color.x * 0.0 is a zero (:277), 0.0 + 0.5 0.5 (:236), and a - 0.25
    // the 0.25 constant folding makes of it; vec2(color.y * 0.0 + 0.5,
    // 0.25) * 3.0 a vec of two constants times 3.0, (1.5, 0.75), which no
    // rule takes a float at a time (since 1.176).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_folds);
    try testing.expectEqual(@as(usize, 0), liveOf(&work, .sub));
    // What is left is the dot of color.xyz and (0.5, 0.25, 2.0): z's
    // product first, y's added to it, then x's (lower_reduction,
    // nir_lower_alu_width.c:96-127).
    try testing.expectEqual(@as(usize, 3), liveOf(&work, .mul));
    try testing.expectEqual(@as(usize, 2), liveOf(&work, .add));
    const product = liveStepOf(&work, .mul);
    try testing.expectEqual(@as(u8, 2), partOf(&work, work.steps[product].a, 0).part);
    try testing.expectEqual(@as(usize, 13), code.words.len);
}

test "a struct or an array made by OpCompositeConstruct is read by OpCompositeExtract, down to a float of a member or an element" {
    // y is (color.zw, 0.5)'s second float, p the struct's float member,
    // e the first float of the second element, color.wzyx: color.w each
    // (since 1.176), and 1.0.
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_aggregate_values);
    try testing.expectEqual(@as(u32, 3), work.local_count);
    const out = work.steps[work.stored];
    for (0..3) |k| {
        const float = partOf(&work, work.stored, @intCast(k));
        try testing.expectEqual(Tag.input, work.steps[float.step].tag);
        try testing.expectEqual(@as(u8, 3), float.part);
    }
    try testing.expectEqual(Tag.construct, out.tag);
    try testing.expectEqual(@as(usize, 0), liveOf(&work, .mul));
}

test "a variable of the function's own given a constant to start with, an array's or a vector's, is stored at the top of the function as nir_lower_variable_initializers stores it" {
    // weights and sum of glslc -O0's module, each stored first from a
    // constant, given it as an initializer instead, which glslc does not
    // write: the same words and stream. sum starts at 0.5: started at
    // zero, it came out the same with the initializer lost.
    const start = comptime patched(&reference.glslc_local_array_kept, .store, 3, 1, 16);
    const words = comptime initialized(&initialized(&start, 12), 39);
    var work: Work = .{};
    const code = try throughMesa(&work, &words);
    var kept: Work = .{};
    const same = try throughMesa(&kept, &start);
    try testing.expectEqual(kept.local_count, work.local_count);
    try testing.expectEqualSlices(u64, same.words, code.words);
    try testing.expectEqualSlices(Word, same.stream(), code.stream());
    var zero: Work = .{};
    const from_zero = try throughMesa(&zero, &reference.glslc_local_array_kept);
    try testing.expect(!std.mem.eql(u64, from_zero.words, code.words));
    // An initializer that is no constant is refused: the array's made
    // the counter's zero.
    var other: Work = .{};
    try testing.expectError(Error.Body, throughMesa(&other, &comptime patched(&words, .variable, 3, 3, 23)));
}

/// How many of the stream's words are `tag`'s.
fn streamWordsOf(code: Code, tag: std.meta.Tag(Word)) usize {
    var count: usize = 0;
    for (code.stream()) |word| {
        if (word == tag) count += 1;
    }
    return count;
}

/// A program's disassembly, a line of each instruction, for the tests
/// that follow a register back to the instruction that wrote it.
const Lines = struct {
    bytes: [most_lines][disasm.most_text]u8 = undefined,
    len: [most_lines]usize = undefined,
    count: usize = 0,

    const most_lines = 128;

    fn of(code: Code) !Lines {
        var lines: Lines = .{};
        try testing.expect(code.words.len <= most_lines);
        for (code.words) |word| {
            const made = disasm.disasm(word, &lines.bytes[lines.count]).?;
            lines.len[lines.count] = made.len;
            lines.count += 1;
        }
        return lines;
    }

    fn line(lines: *const Lines, k: usize) []const u8 {
        return lines.bytes[k][0..lines.len[k]];
    }

    /// The `which`th of an instruction's halves, the add's, the mul's or
    /// its signals', each trimmed.
    fn half(lines: *const Lines, k: usize, which: usize) []const u8 {
        var parts = std.mem.splitScalar(u8, lines.line(k), ';');
        var n: usize = 0;
        while (parts.next()) |part| : (n += 1) {
            if (n == which) return std.mem.trim(u8, part, " ");
        }
        return "";
    }

    /// A half's operation, with its condition: `add.ifa` of
    /// `add.ifa tmua, rf10, rf26`.
    fn opOf(said: []const u8) []const u8 {
        return said[0 .. std.mem.indexOfScalar(u8, said, ' ') orelse said.len];
    }

    /// A half's `n`th register named, its destination first.
    fn operandOf(said: []const u8, n: usize) []const u8 {
        const space = std.mem.indexOfScalar(u8, said, ' ') orelse return "";
        var each = std.mem.splitSequence(u8, said[space + 1 ..], ", ");
        var k: usize = 0;
        while (each.next()) |named| : (k += 1) {
            if (k == n) return std.mem.trim(u8, named, " ");
        }
        return "";
    }

    /// The instruction before `before` whose add or mul writes `register`.
    fn writerOf(lines: *const Lines, before: usize, register: []const u8) ?struct { line: usize, half: []const u8 } {
        var k = before;
        while (k > 0) {
            k -= 1;
            for (0..2) |which| {
                const said = lines.half(k, which);
                if (!std.mem.eql(u8, opOf(said), "nop") and std.mem.eql(u8, operandOf(said, 0), register)) return .{ .line = k, .half = said };
            }
        }
        return null;
    }

    /// Whether `register` before `before` is worked out from the thread's
    /// index, as spill_base is (v3d_setup_spill_base,
    /// vir_register_allocate.c:438-492).
    fn fromTidx(lines: *const Lines, before: usize, register: []const u8, depth: u32) bool {
        if (depth == 0) return false;
        const writer = lines.writerOf(before, register) orelse return false;
        if (std.mem.eql(u8, opOf(writer.half), "tidx")) return true;
        for (1..3) |n| {
            const named = operandOf(writer.half, n);
            if (std.mem.startsWith(u8, named, "rf") and lines.fromTidx(writer.line, named, depth - 1)) return true;
        }
        return false;
    }

    /// The one TMU address written under the execute mask, the access an
    /// arm kept makes: its base must be spill_base, and its offset the
    /// index the body computes, a float's four bytes apart, sixteen times
    /// that (v3d_nir_scratch_offset, v3d_nir_lower_scratch.c:31-43); every
    /// other address the program writes from the same base.
    fn expectArmedScratch(lines: *const Lines) !void {
        var armed: ?usize = null;
        var base: []const u8 = "";
        for (0..lines.count) |k| for (0..2) |which| {
            const said = lines.half(k, which);
            if (!std.mem.eql(u8, operandOf(said, 0), "tmua")) continue;
            if (base.len == 0) base = operandOf(said, 1);
            try testing.expectEqualStrings(base, operandOf(said, 1));
            if (std.mem.endsWith(u8, opOf(said), ".ifa")) {
                try testing.expectEqual(@as(?usize, null), armed);
                armed = k;
            }
        };
        try testing.expect(lines.fromTidx(armed.?, base, 6));
        const said = lines.half(armed.?, 0);
        const times16 = lines.writerOf(armed.?, operandOf(said, 2)).?;
        try testing.expectEqualStrings("shl", opOf(times16.half));
        try testing.expectEqualStrings("4", operandOf(times16.half, 2));
        const stride = lines.writerOf(times16.line, operandOf(times16.half, 1)).?;
        try testing.expectEqualStrings("shl", opOf(stride.half));
        try testing.expectEqualStrings("2", operandOf(stride.half, 2));
    }
};

test "an array of the function's own read at an index the body computes, of more than two elements, lives in scratch, each float a load_scratch or a store_scratch through the TMU from spill_base" {
    // table[i], four vec4s stored whole from a constant: 64 bytes of each
    // lane's, nir_lower_vars_to_scratch's (vir.c:2041-2044; since 1.177),
    // and sixteen times that of each thread's share of the spill buffer.
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_scratch_table);
    try testing.expectEqual(@as(u32, 64), work.scratch_size);
    try testing.expectEqual(@as(u32, 16 * 64), code.spill_size);
    try testing.expect(code.tmu_dirty_rcl);
    // The constant a store_scratch each float, at its byte offset times
    // the sixteen lanes (v3d_nir_lower_scratch.c:31-43); table[i] a
    // load_scratch each float, at i times the vec4's sixteen bytes, times
    // the lanes again, plus the float's four bytes times them.
    try testing.expectEqual(@as(usize, 16), stepsOf(&work, .scratch_store));
    try testing.expectEqual(@as(usize, 4), liveOf(&work, .scratch_indirect));
    var expected: u32 = 0;
    for (work.program()) |each| if (each.tag == .scratch_store) {
        try testing.expectEqual(expected, each.at);
        try testing.expectEqual(none, each.from[0]);
        expected += 4 * 16;
    };
    // An address of each, spill_base plus the offset, every one a pixel's
    // 32-bit word: a load that helper pixels skip (vir.c:1937-1951) and a
    // store, the TMU's default configuration.
    try testing.expectEqual(@as(usize, 16 + 4), countOf(code, "tmua"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "tmuau"));
    // spill_base, worked out once at the start from the thread's index,
    // the lane's and the stream's two words (v3d_setup_spill_base).
    try testing.expectEqual(@as(usize, 1), countOf(code, "tidx"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "eidx"));
    try testing.expectEqual(@as(usize, 1), streamWordsOf(code, .spill_offset));
    try testing.expectEqual(@as(usize, 1), streamWordsOf(code, .spill_size_per_thread));
    // glslc -O0: i a variable of the function's own as well, the same
    // words.
    var kept: Work = .{};
    const same = try throughMesa(&kept, &reference.glslc_scratch_table_kept);
    try testing.expectEqualSlices(u64, code.words, same.words);
}

test "a load_scratch before a kept selection, the value its phi takes where the arm is not, is coalesced into the phi's float" {
    // ramp[i] before the selection and ramp[j] in its arm: the block
    // before ends with its TMU flushed in uniform control flow
    // (ntq_emit_block, nir_to_vir.c:4676-4689), its MOV writing the phi's
    // register whole, and the arm's under the execute mask (:809-838);
    // the empty else is no block of copies (since 1.177).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_scratch_merge);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .scratch_indirect));
    const lines = try Lines.of(code);
    try lines.expectArmedScratch();
    var loaded: [2][]const u8 = .{ "", "" };
    var moves: [2][]const u8 = .{ "", "" };
    var into: [2][]const u8 = .{ "", "" };
    var count: usize = 0;
    var colour: []const u8 = "";
    for (0..lines.count) |k| {
        for (0..2) |which| {
            const said = lines.half(k, which);
            for (0..count) |n| {
                if (std.mem.eql(u8, Lines.operandOf(said, 1), loaded[n]) and std.mem.startsWith(u8, Lines.opOf(said), "mov")) {
                    moves[n] = Lines.opOf(said);
                    into[n] = Lines.operandOf(said, 0);
                }
            }
            if (colour.len == 0 and std.mem.eql(u8, Lines.opOf(said), "vfpack")) colour = Lines.operandOf(said, 1);
        }
        const signals = lines.half(k, 2);
        if (std.mem.indexOf(u8, signals, "ldtmu.")) |at| {
            const rest = signals[at + "ldtmu.".len ..];
            try testing.expect(count < 2);
            loaded[count] = rest[0 .. std.mem.indexOfAny(u8, rest, "; ") orelse rest.len];
            count += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expectEqualStrings("mov", moves[0]);
    try testing.expectEqualStrings("mov.ifa", moves[1]);
    try testing.expectEqualStrings(colour, into[0]);
    try testing.expectEqualStrings(colour, into[1]);
    for (0..lines.count) |k| try testing.expect(std.mem.indexOf(u8, lines.line(k), "xor.pushz") == null);
}

test "an array in scratch stored into at an index the body computes, and an element of it loaded before and after, each its own load_scratch" {
    // acc's four floats stored from 0.25 each, acc[i] stored color.y, and
    // each float read at its constant offset (since 1.177).
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_scratch_slots);
    try testing.expectEqual(@as(u32, 16), work.scratch_size);
    try testing.expectEqual(@as(usize, 4 + 1), stepsOf(&work, .scratch_store));
    try testing.expectEqual(@as(usize, 4), liveOf(&work, .scratch));
    var computed: usize = 0;
    for (work.program()) |each| if (each.tag == .scratch_store and each.from[0] != none) {
        computed += 1;
        const value = partOf(&work, each.a, 0);
        try testing.expectEqual(Tag.input, work.steps[value.step].tag);
        try testing.expectEqual(@as(u8, 1), value.part);
    };
    try testing.expectEqual(@as(usize, 1), computed);
    // acc[0] before the store is the initializer's 0.25, the value
    // nir_opt_copy_prop_vars has for it (nir_opt_copy_prop_vars.c:
    // 1124-1229); after the store at an index the body computes, which
    // may be any of them, acc[0], acc[1] and acc[3] are loads.
    work = .{};
    _ = try throughMesa(&work, &reference.glslc_scratch_reread);
    try testing.expectEqual(@as(usize, 3), liveOf(&work, .scratch));
    const before = partOf(&work, work.stored, 0);
    try testing.expectEqual(Tag.constant, work.steps[before.step].tag);
    try testing.expectEqual(@as(f32, 0.25), work.pool[work.steps[before.step].at + before.part]);
    var stored: ?usize = null;
    for (work.program(), 0..) |each, at| {
        if (each.tag == .scratch_store and each.from[0] != none) stored = at;
        if (each.tag == .scratch) try testing.expect(stored != null);
    }
    // A load_scratch is divergent whatever its offset
    // (nir_divergence_analysis.c:989), and v3d's callback lets it skip
    // the helper invocations (intrinsic_try_skip_helpers, vir.c:
    // 1937-1951), no derivative reading it.
    for (work.program(), 0..) |each, at| if (each.tag == .scratch) {
        try testing.expect(work.divergent[at]);
        try testing.expect(work.skip_helpers[at]);
    };
}

test "nir_opt_copy_prop_vars takes a load of a float in scratch whose value it has and a store of the value there, and nir_opt_dead_write_vars a store written over unread" {
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_scratch_copies);
    // The initializer's a[2] written over by color.z, nothing read
    // between (update_unused_writes, nir_opt_dead_write_vars.c); a[i] = q
    // the value a[i] has (nir_opt_copy_prop_vars.c:1268-1276; since
    // 1.177).
    var offsets: [8]u32 = undefined;
    var count: usize = 0;
    var computed: usize = 0;
    for (work.program()) |each| if (each.tag == .scratch_store) {
        if (each.from[0] != none) {
            computed += 1;
            continue;
        }
        offsets[count] = each.at / 16;
        count += 1;
    };
    try testing.expectEqualSlices(u32, &.{ 0, 4, 12, 8 }, offsets[0..count]);
    try testing.expectEqual(@as(usize, 1), computed);
    // p the initializer's a[1], and q color.y as a[i] was stored; r and
    // a[3] loads, the store at an index the body computes having taken
    // the copies of a[2] and a[3], which it may be of.
    const p = partOf(&work, work.stored, 0);
    try testing.expectEqual(Tag.constant, work.steps[p.step].tag);
    try testing.expectEqual(@as(f32, 0.375), work.pool[work.steps[p.step].at + p.part]);
    const q = partOf(&work, work.stored, 1);
    try testing.expectEqual(Tag.input, work.steps[q.step].tag);
    try testing.expectEqual(@as(u8, 1), q.part);
    for ([_]u8{ 2, 3 }, [_]u32{ 8, 12 }) |part, bytes| {
        const loaded = partOf(&work, work.stored, part);
        try testing.expectEqual(Tag.scratch, work.steps[loaded.step].tag);
        try testing.expectEqual(bytes * 16, work.steps[loaded.step].at);
    }
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .scratch));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .scratch_indirect));
}

test "a variable in scratch every load of which nir_opt_copy_prop_vars takes is dead, its stores with it, and the one left is placed alone" {
    // b[i] read back as stored, in the block and in the arm: no load of
    // b is left, nir_remove_dead_variables takes b and its stores
    // (nir_remove_dead_variables.c:66-90, :110-170), and
    // nir_lower_vars_to_scratch places a at 0. The arm left only an fmul,
    // nir_opt_peephole_select flattens it (since 1.177).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_scratch_dead);
    try testing.expectEqual(@as(usize, 2), work.scratch.count);
    try testing.expect(work.scratch.dead[0] and !work.scratch.dead[1]);
    try testing.expectEqual(@as(u32, 16), work.scratch_size);
    try testing.expectEqual(@as(u32, 16 * 16), code.spill_size);
    var offsets: [8]u32 = undefined;
    var count: usize = 0;
    for (work.program()) |each| if (each.tag == .scratch_store) {
        try testing.expectEqual(none, each.from[0]);
        offsets[count] = each.at / 16;
        count += 1;
    };
    try testing.expectEqualSlices(u32, &.{ 0, 4, 8, 12 }, offsets[0..count]);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .scratch_indirect));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .scratch));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .begin_if));
}

test "a load of a float in scratch at an index the body computes reads every store before it, and a store written over in a block a flattened selection is in goes" {
    // s = a[i] may be a[1], so the initializer's store of it stays
    // (clear_unused_for_read, nir_opt_dead_write_vars.c); a[1] = color.y
    // is written over by a[1] = t with the selection between flattened,
    // in one block (update_unused_writes). a[1] and a[2] are then the
    // copies' t and 0.625 (since 1.177).
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_scratch_blocks);
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .begin_if));
    var offsets: [8]u32 = undefined;
    var count: usize = 0;
    for (work.program()) |each| if (each.tag == .scratch_store) {
        try testing.expectEqual(none, each.from[0]);
        offsets[count] = each.at / 16;
        count += 1;
    };
    try testing.expectEqualSlices(u32, &.{ 0, 4, 8, 12, 4 }, offsets[0..count]);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .scratch_indirect));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .scratch));
    const third = partOf(&work, work.stored, 2);
    try testing.expectEqual(Tag.constant, work.steps[third.step].tag);
    try testing.expectEqual(@as(f32, 0.625), work.pool[work.steps[third.step].at + third.part]);
}

test "each arm of a selection starts from the copies before it, and its merge keeps none a store in an arm may be of" {
    // a[2] = color.y in the true arm is no copy to the false arm, whose
    // a[2] is a load; past the merge, a[i] = color.w may have been
    // written over, and a[2] and a[i] are loads
    // (copy_prop_vars_cf_node, nir_opt_copy_prop_vars.c:1531-1566;
    // since 1.177).
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_scratch_arms);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 6), stepsOf(&work, .scratch_store));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .scratch));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .scratch_indirect));
}

test "an index computed twice is one value to nir_opt_copy_prop_vars once nir_opt_cse has made it one, and an array only read back as stored is in no scratch" {
    // glslc -O0 computes int(color.x * 3.99) for the store and again for
    // the load: one SSA value after nir_opt_cse (nir_to_vir.c:2264), the
    // load the copy's color.y, and a, loaded nowhere, dead
    // (nir_remove_dead_variables.c:66-90; since 1.177).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_scratch_twice);
    try testing.expectEqual(@as(u32, 0), work.scratch_size);
    try testing.expectEqual(@as(u32, 0), code.spill_size);
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .scratch_store));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .scratch_indirect));
    const first = partOf(&work, work.stored, 0);
    try testing.expectEqual(Tag.input, work.steps[first.step].tag);
    try testing.expectEqual(@as(u8, 1), first.part);
    try testing.expectEqual(@as(usize, 0), streamWordsOf(code, .spill_offset));
}

test "an array of structs in scratch: members two floats apart, and a kept selection's merge a block of its own to nir_opt_dead_write_vars" {
    // p[0].x stored in the false arm and again after the merge: two
    // blocks, and the arm's store stays (remove_dead_write_vars_local,
    // nir_opt_dead_write_vars.c). p[2].x is the initializer's, no store
    // since of a float it may be (since 1.177).
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_scratch_pairs);
    try testing.expectEqual(@as(u32, 24), work.scratch_size);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    var offsets: [10]u32 = undefined;
    var count: usize = 0;
    for (work.program()) |each| if (each.tag == .scratch_store) {
        try testing.expectEqual(none, each.from[0]);
        offsets[count] = each.at / 16;
        count += 1;
    };
    try testing.expectEqualSlices(u32, &.{ 0, 4, 8, 12, 16, 20, 12, 0, 0 }, offsets[0..count]);
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .scratch_indirect));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .scratch));
    const third = partOf(&work, work.stored, 2);
    try testing.expectEqual(Tag.constant, work.steps[third.step].tag);
    try testing.expectEqual(@as(f32, 0.625), work.pool[work.steps[third.step].at + third.part]);
}

test "FacetBoth's scratch case: eight floats in scratch, one stored at a computed index, read back as stored and at three others" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_scratch_both);
    try testing.expectEqual(@as(u32, 32), work.scratch_size);
    try testing.expectEqual(@as(u32, 16 * 32), code.spill_size);
    try testing.expectEqual(@as(usize, 8 + 1), stepsOf(&work, .scratch_store));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .scratch_indirect));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .scratch));
    const second = partOf(&work, work.stored, 1);
    try testing.expectEqual(Tag.input, work.steps[second.step].tag);
    try testing.expectEqual(@as(u8, 2), second.part);
}

test "two arrays in scratch are placed in the order an index is first computed into each" {
    // b, declared after a, is indexed first: nir_lower_vars_to_scratch
    // places b at 0 and a after its sixteen bytes (nir_lower_scratch.c:
    // 155-185, :247-258; since 1.177). The stores of a's three floats come
    // first, as the module stores a first.
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_scratch_order);
    try testing.expectEqual(@as(u32, 16 + 12), work.scratch_size);
    var offsets: [7]u32 = undefined;
    var count: usize = 0;
    for (work.program()) |each| if (each.tag == .scratch_store) {
        offsets[count] = each.at / 16;
        count += 1;
    };
    try testing.expectEqualSlices(u32, &.{ 16, 20, 24, 0, 4, 8, 12 }, offsets[0..count]);
}

/// Whether the float `at` names is float `k` of the varyings' input.
fn isInputFloat(work: *const Work, at: u16, k: u8) bool {
    return isInputPart(work, at, 0, k);
}

/// Whether float `part` of the step `at` is float `k` of the varyings'
/// input.
fn isInputPart(work: *const Work, at: u16, part: u8, k: u8) bool {
    const float = partOf(work, at, part);
    return work.steps[float.step].tag == .input and float.part == k;
}

/// How many of a program's integer operations are `op`.
fn integerOpsOf(work: *const Work, op: Integer) usize {
    var count: usize = 0;
    for (work.program()) |each| {
        if (isIntegerOp(each, op)) count += 1;
    }
    return count;
}

/// The program's selects, in order, into `out`, and how many.
fn selectsOf(work: *const Work, out: []u16) usize {
    var count: usize = 0;
    for (work.program(), 0..) |each, at| if (each.tag == .select) {
        if (count < out.len) out[count] = @intCast(at);
        count += 1;
    };
    return count;
}

/// The ilt an if-else tree's if tests: of the index and the integer 1.
fn expectTreeCondition(work: *const Work, at: u16) !void {
    const each = work.steps[at];
    try testing.expectEqual(Tag.compare, each.tag);
    try testing.expectEqual(@as(u32, @intFromEnum(Comparison.int_less)), each.at);
    try testing.expectEqual(@as(?u32, 1), floatBits(work, partOf(work, each.b, 0)));
}

test "a load at an index the body computes into an array of two of the function's own is an if-else tree, a bcsel of each float, of two constants the constant or the b2f nir_opt_algebraic makes" {
    // two[i], two vec4s: nir_lower_indirect_derefs_to_if_else_trees makes
    // if (i < 1) two[0] else two[1] of the load (v3dv_pipeline.c:435-436,
    // nir_lower_indirect_derefs_to_if_else_trees.c:35-66),
    // nir_lower_vars_to_ssa each arm's load the constant the element holds,
    // and nir_opt_peephole_select each float's phi a bcsel on the ilt: of
    // 1.0 and 0.0 the b2f of the ilt and of 0.0 and 1.0 the b2f of its
    // inot (nir_opt_algebraic.py:2080-2081), of 0.0 and 0.0 and of 1.0 and
    // 1.0 the constant, the two load_consts one to nir_opt_remove_phis
    // (nir_opt_remove_phis.c:31-58). Nothing in scratch (since 1.178).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_scratch_pair);
    try testing.expectEqual(@as(u32, 0), work.scratch_size);
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .scratch));
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .select));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .compare));
    try testing.expectEqual(@as(usize, 2), integerOpsOf(&work, .b2f32));
    const x = work.steps[partOf(&work, work.stored, 0).step];
    try testing.expect(isIntegerOp(x, .b2f32));
    try expectTreeCondition(&work, x.a);
    try testing.expectEqual(@as(?u32, 0), floatBits(&work, partOf(&work, work.stored, 1)));
    const z = work.steps[partOf(&work, work.stored, 2).step];
    try testing.expect(isIntegerOp(z, .b2f32));
    try testing.expectEqual(Tag.logic, work.steps[z.a].tag);
    try testing.expectEqual(x.a, work.steps[z.a].a);
    try testing.expectEqual(@as(?u32, @bitCast(@as(f32, 1.0))), floatBits(&work, partOf(&work, work.stored, 3)));
    // Each b2f the AND of the bool and 1.0, and the inot a NOT
    // (nir_to_vir.c:1521-1523, :1683-1694).
    try testing.expectEqual(@as(usize, 2), countOf(code, "and "));
    try testing.expectEqual(@as(usize, 2), countOf(code, ", 0x3f800000    ;"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "not "));
}

test "a store at an index the body computes into an array of two of the function's own is an if-else tree whose merge chooses each element, the one first used later first" {
    // two[0] = y, two[1] = z, two[i] = w; then two[0], two[1], two[j] and
    // two[i]. The store's tree has a phi of each element at its merge, of
    // two[1] then of two[0], the reverse of the order they were first
    // stored into (nir_phi_builder.c:272-297): bcsel(i < 1, z, w) and
    // bcsel(i < 1, w, y). two[j] is a bcsel of the two on j < 1; two[i]
    // one of them on i < 1, which nir_opt_algebraic takes to w
    // (:979-980, :1936), the two ilts of i one to nir_opt_cse (since
    // 1.178).
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_tree_store);
    try testing.expectEqual(@as(u32, 0), work.scratch_size);
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .compare));
    var selects: [4]u16 = undefined;
    try testing.expectEqual(@as(usize, 3), selectsOf(&work, &selects));
    const program = work.program();
    const by_i = program[selects[0]].a;
    try expectTreeCondition(&work, by_i);
    try testing.expect(isInputFloat(&work, program[selects[0]].b, 2));
    try testing.expect(isInputFloat(&work, program[selects[0]].from[0], 3));
    try testing.expectEqual(by_i, program[selects[1]].a);
    try testing.expect(isInputFloat(&work, program[selects[1]].b, 3));
    try testing.expect(isInputFloat(&work, program[selects[1]].from[0], 1));
    const by_j = program[selects[2]].a;
    try expectTreeCondition(&work, by_j);
    try testing.expect(by_j != by_i);
    try testing.expectEqual(selects[1], program[selects[2]].b);
    try testing.expectEqual(selects[0], program[selects[2]].from[0]);
    try testing.expectEqual(selects[1], partOf(&work, work.stored, 0).step);
    try testing.expectEqual(selects[0], partOf(&work, work.stored, 1).step);
    try testing.expectEqual(selects[2], partOf(&work, work.stored, 2).step);
    try testing.expect(isInputPart(&work, work.stored, 3, 3));
}

test "a member, a struct and a matrix's column through an if-else tree, and a float of a vector stored through one is the vector loaded, the float inserted and the vector stored" {
    // S pair[2], mat2 m: picked = pair[i] is a tree of each of S's two
    // members, m[i] one of the column, its bcsels nir_opt_cse makes those
    // of picked.a; pair[i].b = y one of the member, pair[1].b of it the
    // bcsel(i < 1, x, y) its merge chose (vtn_variables.c:763-781; since
    // 1.178).
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_tree_members);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .compare));
    var selects: [6]u16 = undefined;
    try testing.expectEqual(@as(usize, 4), selectsOf(&work, &selects));
    const program = work.program();
    const expected = [4][2]u8{ .{ 0, 2 }, .{ 1, 3 }, .{ 2, 0 }, .{ 0, 1 } };
    for (selects[0..4], expected) |at, pair| {
        try expectTreeCondition(&work, program[at].a);
        try testing.expect(isInputFloat(&work, program[at].b, pair[0]));
        try testing.expect(isInputFloat(&work, program[at].from[0], pair[1]));
    }
    for (selects[0..4], 0..) |at, k| try testing.expectEqual(at, partOf(&work, work.stored, @intCast(k)).step);
    // two[i].y = w * 0.5, two vec2s: the tree of the vector's load, its
    // x then nir_opt_algebraic's; the store's merge two[1] first, then
    // two[0] (vtn_local_store, vtn_variables.c:644-667).
    work = .{};
    _ = try throughMesa(&work, &reference.glslc_tree_part);
    try testing.expectEqual(@as(usize, 2), selectsOf(&work, &selects));
    const half = work.program()[selects[0]].from[0];
    try testing.expectEqual(Tag.mul, work.steps[half].tag);
    try testing.expect(isInputFloat(&work, work.program()[selects[0]].b, 3));
    try testing.expectEqual(half, work.program()[selects[1]].b);
    try testing.expect(isInputFloat(&work, work.program()[selects[1]].from[0], 1));
    try testing.expect(isInputPart(&work, work.stored, 0, 0));
    try testing.expectEqual(selects[1], partOf(&work, work.stored, 1).step);
    try testing.expect(isInputPart(&work, work.stored, 2, 2));
    try testing.expectEqual(selects[0], partOf(&work, work.stored, 3).step);
}

test "an index the body computes into one element is that element, a float of a vector loaded through a tree its bcsel, and an element nothing was stored into takes what the other arm's was" {
    // single[i] is single[0], color.z (nir_lower_indirect_derefs_to_if_else_trees.c:
    // 42-46); two[j].y the bcsel(j < 1, y, w) of the vector's tree
    // (vtn_local_load, vtn_variables.c:616-641). unset[i] = yx leaves each
    // element yx, its phis' undefs taken by nir_opt_remove_phis
    // (nir_opt_remove_phis.c:117-120): unset[j].x is y and unset[1].y x,
    // with no bcsel, and i's ilt read by nothing (since 1.178).
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_tree_single);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .compare));
    var selects: [2]u16 = undefined;
    try testing.expectEqual(@as(usize, 1), selectsOf(&work, &selects));
    const chosen = work.program()[selects[0]];
    try expectTreeCondition(&work, chosen.a);
    try testing.expect(isInputFloat(&work, chosen.b, 1));
    try testing.expect(isInputFloat(&work, chosen.from[0], 3));
    try testing.expect(isInputPart(&work, work.stored, 0, 2));
    try testing.expectEqual(selects[0], partOf(&work, work.stored, 1).step);
    try testing.expect(isInputPart(&work, work.stored, 2, 1));
    try testing.expect(isInputPart(&work, work.stored, 3, 0));
}

test "the phis of an array an if-else tree reaches are put down at a merge before the others', and a tree in an arm or one into scratch is refused" {
    // glslc -O0 keeps two and other variables, each stored into in the
    // arm: other was first used after two[0], but two's phis are given in
    // the loop of passes after the trees, before the block's first
    // instruction, so two[0]'s bcsel comes first (since 1.178).
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_tree_late);
    var selects: [4]u16 = undefined;
    try testing.expectEqual(@as(usize, 3), selectsOf(&work, &selects));
    const program = work.program();
    try testing.expectEqual(Tag.mul, work.steps[program[selects[0]].b].tag);
    try testing.expect(isInputFloat(&work, program[selects[0]].from[0], 1));
    try testing.expect(isInputFloat(&work, program[selects[1]].from[0], 0));
    try expectTreeCondition(&work, program[selects[2]].a);
    try testing.expectEqual(selects[0], program[selects[2]].b);
    try testing.expectEqual(selects[1], partOf(&work, work.stored, 1).step);
    // A load through a tree in an arm, which Mesa flattens with the
    // tree's only in the loop of passes after it.
    work = .{};
    try testing.expectError(Error.Branches, throughMesa(&work, &reference.glslc_tree_arm));
    // big[2][j] is a tree of scratch loads at constant offsets in kept
    // arms, once big[i][j] has put the array in scratch.
    work = .{};
    try testing.expectError(Error.Storage, throughMesa(&work, &reference.glslc_tree_mixed));
}

test "a bcsel of 1.0 and 0.0 is the b2f of its bool, of 0.0 and 1.0 the b2f of the inot, and of -1.0 and -0.0 the fneg of those" {
    // nir_opt_algebraic.py:2080-2083, the b2fs and the inot one each to
    // nir_opt_cse (since 1.178).
    var work: Work = .{};
    _ = try throughMesa(&work, &reference.glslc_tree_bools);
    try testing.expectEqual(@as(usize, 0), stepsOf(&work, .select));
    try testing.expectEqual(@as(usize, 2), integerOpsOf(&work, .b2f32));
    try testing.expectEqual(@as(usize, 2), stepsOf(&work, .negate));
    const straight = partOf(&work, work.stored, 0).step;
    const turned = partOf(&work, work.stored, 1).step;
    try testing.expect(isIntegerOp(work.steps[straight], .b2f32));
    try testing.expectEqual(Tag.compare, work.steps[work.steps[straight].a].tag);
    try testing.expect(isIntegerOp(work.steps[turned], .b2f32));
    try testing.expectEqual(Tag.logic, work.steps[work.steps[turned].a].tag);
    const minus = work.steps[partOf(&work, work.stored, 2).step];
    try testing.expectEqual(Tag.negate, minus.tag);
    try testing.expectEqual(straight, minus.a);
    const minus_turned = work.steps[partOf(&work, work.stored, 3).step];
    try testing.expectEqual(Tag.negate, minus_turned.tag);
    try testing.expectEqual(turned, minus_turned.a);
}

test "a store_scratch in a selection's arm keeps the arm, and is written under the execute mask" {
    // nir_opt_peephole_select lets no load_deref or store_deref of a
    // variable of the function's own through (nir_opt_peephole_select.c:
    // 109-129), so the arm is kept (since 1.177).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_scratch_armed);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 4 + 1), stepsOf(&work, .scratch_store));
    // The arm's address written for the lanes that run
    // (emit_tmu_general_address_write, nir_to_vir.c:457-459, :490-491).
    var conditioned: usize = 0;
    for (code.words) |word| {
        var buffer: [disasm.most_text]u8 = undefined;
        const line = disasm.disasm(word, &buffer).?;
        if (std.mem.indexOf(u8, line, "tmua") != null and std.mem.indexOf(u8, line, ".ifa") != null) conditioned += 1;
    }
    try testing.expectEqual(@as(usize, 1), conditioned);
    const lines = try Lines.of(code);
    try lines.expectArmedScratch();
}

test "a load_scratch in a selection's arm keeps the arm, the float it loads moved into the phi's under the execute mask" {
    // Neither a load_deref of a variable of the function's own nor a
    // load_scratch is an instruction nir_opt_peephole_select lets through
    // (nir_opt_peephole_select.c:109-129), so the arm is kept (since
    // 1.177).
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_scratch_lookup);
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .begin_if));
    try testing.expectEqual(@as(usize, 4), stepsOf(&work, .scratch_store));
    try testing.expectEqual(@as(usize, 1), stepsOf(&work, .scratch_indirect));
    const lines = try Lines.of(code);
    try lines.expectArmedScratch();
    // The phi's float in a register of its own, which nir_from_ssa
    // coalesces the load into: the flush moves each float the TMU
    // returns (vir_MOV(c, vir_LDTMU(c)), nir_to_vir.c:280-281), and
    // ntq_store_def makes that MOV write the phi's register, under the
    // execute mask in the arm (:809-838).
    var loaded: []const u8 = "";
    var moved: []const u8 = "";
    for (0..lines.count) |k| {
        const signals = lines.half(k, 2);
        if (std.mem.indexOf(u8, signals, "ldtmu.")) |at| {
            const rest = signals[at + "ldtmu.".len ..];
            try testing.expectEqual(@as(usize, 0), loaded.len);
            loaded = rest[0 .. std.mem.indexOfAny(u8, rest, "; ") orelse rest.len];
        }
        for (0..2) |which| {
            const said = lines.half(k, which);
            if (loaded.len > 0 and std.mem.eql(u8, Lines.opOf(said), "mov.ifa") and std.mem.eql(u8, Lines.operandOf(said, 1), loaded)) {
                moved = Lines.operandOf(said, 0);
            }
            if (std.mem.eql(u8, Lines.opOf(said), "vfpack") and moved.len > 0) {
                try testing.expectEqualStrings(moved, Lines.operandOf(said, 1));
            }
        }
    }
    try testing.expect(moved.len > 0);
}

test "a varying of each interpolation is emit_fragment_varying's: with perspective times W plus C, without it plus C, flat C alone, and the program's flags say which" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_interpolations);
    // The ldvarys in the varyings' order: the colour 0 to 3, the flat pair
    // 4 and 5, the pair without perspective 6 and 7 (nir_to_vir.c:
    // 1085-1110, vir.c:985-1003; since 1.190).
    try testing.expectEqual(@as(u32, 8), code.varyings);
    try testing.expectEqual(@as(u32, 0x30), code.flat_shade_flags);
    try testing.expectEqual(@as(u32, 0xC0), code.noperspective_flags);
    try testing.expectEqual(@as(usize, 8), countOf(code, "ldvary"));
    // The colour's four times W and the four products; an fadd of C for
    // each of the colour and the pair without perspective, whose MOV is
    // copied into it; the flat pair's C moved out of rf0, its ldvary's
    // value moved nowhere and dropped.
    try testing.expectEqual(@as(usize, 8), countOf(code, "fmul"));
    try testing.expectEqual(@as(usize, 6), countOf(code, "fadd"));
    try testing.expectEqual(@as(usize, 2), countOf(code, "mov "));
    // The plan interpolates with perspective alone, and refuses it.
    work = .{};
    try testing.expectError(Error.Refused, compile(&work, &reference.glslc_interpolations));
}

test "an integer varying is read flat, its bits the C coefficient, and its floats are made of them" {
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_flat_integer);
    try testing.expectEqual(@as(u32, 0xF), code.flat_shade_flags);
    try testing.expectEqual(@as(u32, 0), code.noperspective_flags);
    // Each C moved out and made a float, then times 1/255: no W.
    try testing.expectEqual(@as(usize, 4), countOf(code, "mov "));
    try testing.expectEqual(@as(usize, 4), countOf(code, "utof"));
    try testing.expectEqual(@as(usize, 4), countOf(code, "fmul"));
    try testing.expectEqual(@as(usize, 0), countOf(code, "fadd"));
    // The steps of every byte, the varying's floats its bits (since 1.190).
    const scale: f32 = @bitCast(@as(u32, 0x3B80_8081));
    for (0..256) |v| {
        const bits: f32 = @bitCast(@as(u32, @intCast(v)));
        const other: f32 = @bitCast(@as(u32, @intCast(255 - v)));
        const made = evaluatedOf(&work, work.stored, .{ bits, other, bits, other }, 0);
        const value = @as(f32, @floatFromInt(v)) * scale;
        const rest = @as(f32, @floatFromInt(255 - v)) * scale;
        try testing.expectEqual([4]f32{ value, rest, value, rest }, made);
    }
}

test "the reading takes Flat and NoPerspective of a fragment program's inputs and a vertex program's outputs alone, and an integer input that is flat" {
    var work: Work = .{};
    // The flat integers interpolated without perspective instead, which a
    // fragment program's integer input may not be.
    try testing.expectError(Error.Type, throughMesa(&work, &comptime patched(&reference.glslc_flat_integer, .decorate, 1, 1, @intFromEnum(spirv.Decoration.no_perspective))));
    // The colour's Flat moved to the output it writes, `%9`.
    work = .{};
    try testing.expectError(Error.Refused, throughMesa(&work, &comptime patched(&reference.glslc_flat_color, .decorate, 1, 0, 9)));
    // A vertex program's Flat moved from its varying to the attribute p,
    // `%17`.
    work = .{};
    var key = VertexKey{};
    key.reads[0] = 4;
    try testing.expectError(Error.Refused, vertexThroughMesa(&work, &comptime patched(&reference.glslc_vertex_flat, .decorate, 3, 0, 17), key));
    // Flat and NoPerspective alone are taken.
    work = .{};
    const flat = try throughMesa(&work, &reference.glslc_flat_color);
    try testing.expectEqual(@as(u32, 0xF), flat.flat_shade_flags);
    work = .{};
    const straight = try throughMesa(&work, &reference.glslc_noperspective_color);
    try testing.expectEqual(@as(u32, 0xF), straight.noperspective_flags);
    try testing.expectEqual(@as(usize, 0), countOf(straight, "fmul"));
}

test "a vertex program hands on a flat varying, integers and a varying without perspective as it hands on any, and its coordinate program too" {
    var key = VertexKey{};
    key.reads[0] = 4;
    // Flat changes nothing of a vertex program: the words are
    // glslc_vertex_as_it_is's (since 1.190).
    var work: Work = .{};
    const as_it_is = try vertexThroughMesa(&work, &reference.glslc_vertex_as_it_is, key);
    const plain_words = try testing.allocator.dupe(u64, as_it_is.words);
    defer testing.allocator.free(plain_words);
    work = .{};
    const flat = try vertexThroughMesa(&work, &reference.glslc_vertex_flat, key);
    try testing.expectEqualSlices(u64, plain_words, flat.words);
    // The colour made four integers, FTOUZ's, stored as they are.
    work = .{};
    const integers = try vertexThroughMesa(&work, &reference.glslc_vertex_flat_integer, key);
    try testing.expectEqual(@as(usize, 4), countOf(integers, "ftouz"));
    try testing.expectEqual(@as(usize, 8), countOf(integers, "stvpmv"));
    work = .{};
    const straight = try vertexThroughMesa(&work, &reference.glslc_vertex_noperspective, key);
    try testing.expectEqual(@as(usize, 8), countOf(straight, "stvpmv"));
    try testing.expectEqual(@as(usize, 1), countOf(straight, "recip"));
    for ([_][]const u32{ &reference.glslc_vertex_flat, &reference.glslc_vertex_flat_integer, &reference.glslc_vertex_noperspective }) |words| {
        work = .{};
        _ = try vertexThroughMesa(&work, words, .{ .coordinate = true });
    }
}

test "a module of more than 256 ids, 32 constants and 256 words is read, its loop planned of ids past 256, and worked out as its products and sums are" {
    // 404 ids (since 1.191; refused before, as more than the tables).
    try testing.expectEqual(@as(u32, 404), reference.glslc_many_ids[3]);
    var work: Work = .{};
    const code = try throughMesa(&work, &reference.glslc_many_ids);
    try testing.expectEqual(@as(u32, 4), code.varyings);
    // And past every table it would have filled before: 224 uniforms, one
    // for each constant, where there were 32; 460 floats of constants,
    // where there were 128; 257 words, where there were 256.
    try testing.expectEqual(@as(u32, 224), code.uniform_count);
    try testing.expectEqual(@as(u32, 460), work.pool_count);
    try testing.expect(code.words.len > 256);
    const colors = [_][4]f32{ .{ 0, 0, 0, 0 }, .{ 0.25, 0.5, 0.75, 1 }, .{ 1, 0.125, 0.0625, 0.5 } };
    for (colors) |color| {
        var a = color;
        for (0..28) |k| {
            for (&a, 0..) |*each, c| {
                const j: f32 = @floatFromInt(4 * k + c + 1);
                each.* = each.* * (1.0 + j / 1024.0) + -(j / 2048.0);
            }
        }
        for (0..3) |_| {
            for (&a) |*each| each.* = each.* * 0.5 + 0.25;
        }
        try testing.expectEqual(a, evaluatedOf(&work, work.stored, color, 0));
    }
}

test "a module's bound is held to the tables: 4096 ids are read, and 4097 refused, and so is an id of 4096 the bound does not say" {
    var words = reference.glslc_flat_color;
    words[3] = most_ids;
    var work: Work = .{};
    _ = try throughMesa(&work, &words);
    words[3] = most_ids + 1;
    work = .{};
    try testing.expectError(Error.Refused, throughMesa(&work, &words));
    // An OpLoad's result id of 4096, which `look` does not hold to the
    // bound: the tables refuse it as they read it.
    work = .{};
    try testing.expectError(Error.Refused, throughMesa(&work, &comptime patched(&reference.glslc_flat_color, .load, 0, 1, most_ids)));
}

/// The instructions that add integers, on either side: Mesa prints the
/// operation `add`, and a float's `fadd`.
fn integerAdds(code: Code) usize {
    var count: usize = 0;
    for (code.words) |word| {
        var buffer: [disasm.most_text]u8 = undefined;
        const printed = disasm.disasm(word, &buffer).?;
        count += @intFromBool(std.mem.startsWith(u8, printed, "add ")) + std.mem.count(u8, printed, " add ");
    }
    return count;
}

const all_three = SystemValues{ .instance_id = true, .base_instance = true, .vertex_id = true };

test "through Mesa's back end, a vertex program reads the VPM's instance id, base instance and vertex id before its attributes: InstanceIndex the first two summed, VertexIndex the id and the draw's first vertex" {
    var work: Work = .{};
    var key = VertexKey{};
    key.reads[0] = 4;
    const code = try vertexThroughMesa(&work, &reference.glslc_vertex_index, key);
    try testing.expectEqual(all_three, code.vertex.system_values);
    try testing.expect(!code.vertex.first_row);
    // p whole and c as far as its green.
    try testing.expectEqualSlices(u8, &.{ 4, 2 }, code.vertex.vattr_sizes[0..2]);
    // Nine floats in, three of them the VPM's values (vir.c:894-899), and
    // eight out: the input's two sectors, which the output shares.
    try testing.expectEqual(@as(u8, 2), code.vertex.vpm_output_sectors);
    // The three at rows 0 to 2, p at 3 to 6 and c's green at 8; the
    // products' constants, the first vertex, the colour's 1; then what
    // is stored where.
    try testing.expectEqualSlices(Word, &.{
        vpmIndex(0),         vpmIndex(1),               vpmIndex(2),                vpmIndex(3),
        vpmIndex(4),         vpmIndex(5),               vpmIndex(6),                .{ .float = 0.25 },
        .{ .float = 0.125 }, .first_vertex,             .{ .float = 0.0625 },       vpmIndex(8),
        .{ .float = 1 },     vpmIndex(4),               vpmIndex(5),                vpmIndex(6),
        vpmIndex(7),         .{ .viewport = .x_scale }, vpmIndex(0),                .{ .viewport = .y_scale },
        vpmIndex(1),         .{ .viewport = .z_scale }, .{ .viewport = .z_offset }, vpmIndex(2),
        vpmIndex(3),
    }, code.stream());
    try testing.expectEqual(@as(usize, 8), countOf(code, "ldvpmv_in"));
    // InstanceIndex's sum and VertexIndex's, each made a float.
    try testing.expectEqual(@as(usize, 2), integerAdds(code));
    try testing.expectEqual(@as(usize, 2), countOf(code, "itof"));
}

test "through Mesa's back end, the coordinate program reads the rows the vertex program does, and loads only what its position is made of" {
    var work: Work = .{};
    var key = VertexKey{ .coordinate = true, .system_values = all_three };
    key.reads[0] = 4;
    const code = try vertexThroughMesa(&work, &reference.glslc_vertex_index, key);
    // The vertex id's row is the vertex program's (`VertexKey`), and its
    // load dead code: p is rows 3 to 6, as it is there.
    try testing.expectEqual(all_three, code.vertex.system_values);
    try testing.expectEqualSlices(u8, &.{ 4, 0 }, code.vertex.vattr_sizes[0..2]);
    try testing.expectEqualSlices(Word, &.{
        vpmIndex(0),               vpmIndex(1),         vpmIndex(3),               vpmIndex(4), vpmIndex(5), vpmIndex(6),
        .{ .float = 0.25 },        .{ .float = 0.125 }, vpmIndex(0),               vpmIndex(1), vpmIndex(2), vpmIndex(3),
        .{ .viewport = .x_scale }, vpmIndex(4),         .{ .viewport = .y_scale }, vpmIndex(5),
    }, code.stream());
    try testing.expectEqual(@as(usize, 6), countOf(code, "ldvpmv_in"));
    try testing.expectEqual(@as(usize, 1), integerAdds(code));
    // Told none, it would read p from row 2, which the record of the
    // vertex program's id puts the id in.
    work = .{};
    key.system_values = .{};
    const alone = try vertexThroughMesa(&work, &reference.glslc_vertex_index, key);
    try testing.expectEqual(SystemValues{ .instance_id = true, .base_instance = true }, alone.vertex.system_values);
    try testing.expectEqualSlices(Word, &.{ vpmIndex(0), vpmIndex(1), vpmIndex(2), vpmIndex(3), vpmIndex(4), vpmIndex(5) }, alone.stream()[0..6]);
}

test "GFXH-1602: a coordinate program that reads the vertex id and not its first driver location reads past a row of it" {
    var work: Work = .{};
    var key = VertexKey{};
    key.reads[0] = 4;
    const vertex = try vertexThroughMesa(&work, &reference.glslc_index_place, key);
    // The vertex program: the id at row 0, p's x and y at 1 and 2, and c
    // as far as its blue at 3 to 5.
    try testing.expectEqual(SystemValues{ .vertex_id = true }, vertex.vertex.system_values);
    try testing.expect(!vertex.vertex.first_row);
    try testing.expectEqualSlices(u8, &.{ 2, 3 }, vertex.vertex.vattr_sizes[0..2]);
    try testing.expectEqualSlices(Word, &.{ vpmIndex(0), vpmIndex(3), vpmIndex(4), vpmIndex(5), .first_vertex }, vertex.stream()[0..5]);
    try testing.expectEqual(@as(usize, 6), countOf(vertex, "ldvpmv_in"));
    // The coordinate program reads no p: its first driver location takes
    // a row all the same (ntq_emit_load_input, nir_to_vir.c:2963-2973),
    // which the draw has the VPM load one float into, and c is 2 to 4.
    work = .{};
    key.coordinate = true;
    key.system_values = vertex.vertex.system_values;
    const coordinate = try vertexThroughMesa(&work, &reference.glslc_index_place, key);
    try testing.expect(coordinate.vertex.first_row);
    try testing.expectEqualSlices(u8, &.{ 0, 3 }, coordinate.vertex.vattr_sizes[0..2]);
    try testing.expectEqualSlices(Word, &.{ vpmIndex(0), vpmIndex(2), vpmIndex(3), vpmIndex(4), .first_vertex }, coordinate.stream()[0..5]);
    try testing.expectEqual(@as(usize, 4), countOf(coordinate, "ldvpmv_in"));
    try testing.expectEqual(@as(usize, 1), integerAdds(coordinate));
    // Its row is none of the input's (vir.c:860-899): one for the id and
    // three for c, one sector.
    try testing.expectEqual(@as(u8, 1), coordinate.vertex.vpm_output_sectors);
}

test "GFXH-1602 is the built-ins' alone: a coordinate program that reads neither them nor its first driver location reads its attributes from row 0" {
    // vertex_flat with p and c swapped: c at location 0, which only the
    // varying is made of, and p at 1.
    const swapped = comptime patched(&patched(&reference.glslc_vertex_flat, .decorate, 1, 2, 1), .decorate, 5, 2, 0);
    var work: Work = .{};
    var key = VertexKey{ .coordinate = true };
    key.reads[0] = 4;
    const code = try vertexThroughMesa(&work, &swapped, key);
    try testing.expectEqual(SystemValues{}, code.vertex.system_values);
    try testing.expect(!code.vertex.first_row);
    try testing.expectEqualSlices(u8, &.{ 0, 4, 2 }, code.vertex.vattr_sizes[0..3]);
    try testing.expectEqual(@as(usize, 6), countOf(code, "ldvpmv_in"));
    try testing.expectEqualSlices(Word, &.{ vpmIndex(0), vpmIndex(1), vpmIndex(2), vpmIndex(3), vpmIndex(4), vpmIndex(5) }, code.stream()[0..6]);
}

test "VertexIndex and InstanceIndex are a vertex program's, of an input variable each: any other built-in of a variable is refused" {
    var key = VertexKey{};
    key.reads[0] = 4;
    // InstanceIndex made VertexId, which Vulkan has not.
    var work: Work = .{};
    try testing.expectError(Error.Refused, vertexThroughMesa(&work, &comptime patched(&reference.glslc_vertex_index, .decorate, 0, 2, 5), key));
    // Both variables VertexIndex.
    work = .{};
    try testing.expectError(Error.Refused, vertexThroughMesa(&work, &comptime patched(&reference.glslc_vertex_index, .decorate, 0, 2, @intFromEnum(spirv.BuiltIn.vertex_index)), key));
    // And in a fragment program, as before.
    work = .{};
    try testing.expectError(Error.Refused, throughMesa(&work, &comptime patched(&reference.glslc_flat_color, .decorate, 0, 1, @intFromEnum(spirv.Decoration.built_in))));
}

/// The VPM rows a program's stores are of, in the order of its steps.
fn outputRows(work: *const Work, into: []u32) []u32 {
    var count: usize = 0;
    for (work.steps[0..work.step_count]) |each| {
        if (each.tag != .output) continue;
        into[count] = each.at;
        count += 1;
    }
    return into[0..count];
}

test "through Mesa's back end, a vertex program that writes gl_PointSize stores the larger of it and 1.0 in the VPM's row after the fixed-function outputs, and its varyings a row later" {
    var work: Work = .{};
    var key = VertexKey{};
    key.reads[0] = 4;
    const code = try vertexThroughMesa(&work, &reference.glslc_point_size, key);
    try testing.expect(code.vertex.point_size);
    try testing.expectEqualSlices(u8, &.{ 4, 4, 2 }, code.vertex.vattr_sizes[0..3]);
    // Stored where the program stores it, before the colour, and the
    // fixed-function outputs after both.
    var rows: [16]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 4, 5, 6, 7, 8, 0, 1, 2, 3 }, outputRows(&work, &rows));
    // The four fixed, the point size and the colour's four.
    try testing.expectEqual(@as(usize, 9), countOf(code, "stvpmv"));
    try testing.expectEqual(@as(usize, 1), countOf(code, "fmax"));
    try testing.expectEqual(@as(u8, 2), code.vertex.vpm_output_sectors);
    // glslc_vertex_as_it_is's stream, which stores the colour at rows 4
    // to 7 with the uniforms its loads read, and here the alpha's 8 and
    // the fmax's 1.0, and the colour's last float at row 8: the point
    // size at row 4 (v3d_nir_lower_io.c:427-428).
    try testing.expectEqualSlices(Word, &.{
        vpmIndex(0), vpmIndex(1),               vpmIndex(2),                vpmIndex(3),
        vpmIndex(8), vpmIndex(9),               vpmIndex(4),                vpmIndex(5),
        vpmIndex(6), vpmIndex(7),               .{ .float = 8 },            .{ .float = 1 },
        vpmIndex(8), .{ .viewport = .x_scale }, vpmIndex(0),                .{ .viewport = .y_scale },
        vpmIndex(1), .{ .viewport = .z_scale }, .{ .viewport = .z_offset }, vpmIndex(2),
        vpmIndex(3),
    }, code.stream());
    const before = try vertexThroughMesa(&work, &reference.glslc_vertex_as_it_is, key);
    try testing.expect(!before.vertex.point_size);
    try testing.expectEqual(@as(usize, 8), countOf(before, "stvpmv"));
    // The coordinate program writes it too, at row 6 after the position
    // and the place on screen, and loads the alpha it is made of.
    work = .{};
    key.coordinate = true;
    const coordinate = try vertexThroughMesa(&work, &reference.glslc_point_size, key);
    try testing.expect(coordinate.vertex.point_size);
    try testing.expectEqualSlices(u8, &.{ 4, 4, 2 }, coordinate.vertex.vattr_sizes[0..3]);
    try testing.expectEqual(@as(usize, 7), countOf(coordinate, "stvpmv"));
    try testing.expectEqual(@as(usize, 7), countOf(coordinate, "ldvpmv_in"));
    try testing.expectEqualSlices(Word, &.{
        vpmIndex(0),               vpmIndex(1),     vpmIndex(2),               vpmIndex(3), vpmIndex(8), vpmIndex(9), vpmIndex(7),
        .{ .float = 8 },           .{ .float = 1 }, vpmIndex(6),               vpmIndex(0), vpmIndex(1), vpmIndex(2), vpmIndex(3),
        .{ .viewport = .x_scale }, vpmIndex(4),     .{ .viewport = .y_scale }, vpmIndex(5),
    }, coordinate.stream());
}

test "a point size of 1.0 is stored as it is, the fmax of it and 1.0 folded, as nir_opt_constant_folding folds it" {
    var work: Work = .{};
    var key = VertexKey{};
    key.reads[0] = 4;
    const code = try vertexThroughMesa(&work, &reference.glslc_point_one, key);
    try testing.expect(code.vertex.point_size);
    try testing.expectEqual(@as(usize, 0), countOf(code, "fmax"));
    try testing.expectEqual(@as(usize, 9), countOf(code, "stvpmv"));
    try testing.expectEqualSlices(Word, &.{
        vpmIndex(0),     vpmIndex(1),               vpmIndex(2), vpmIndex(3),               vpmIndex(8),                vpmIndex(9),
        .{ .float = 1 }, vpmIndex(4),               vpmIndex(5), vpmIndex(6),               vpmIndex(7),                .{ .viewport = .x_scale },
        vpmIndex(0),     .{ .viewport = .y_scale }, vpmIndex(1), .{ .viewport = .z_scale }, .{ .viewport = .z_offset }, vpmIndex(2),
        vpmIndex(3),
    }, code.stream());
    // A second store of it, the colour's made one of 1.0 into %43, is
    // refused, as a second of gl_Position is.
    work = .{};
    const twice = comptime patched(&patched(&reference.glslc_point_one, .store, 2, 0, 43), .store, 2, 1, 41);
    try testing.expectError(Error.Outputs, vertexThroughMesa(&work, &twice, key));
}

test "a point size stored after the varyings is stored after them, at its row all the same" {
    var work: Work = .{};
    var key = VertexKey{};
    key.reads[0] = 4;
    const code = try vertexThroughMesa(&work, &reference.glslc_point_last, key);
    try testing.expect(code.vertex.point_size);
    try testing.expectEqual(@as(usize, 9), countOf(code, "stvpmv"));
    var rows: [16]u32 = undefined;
    try testing.expectEqualSlices(u32, &.{ 5, 6, 7, 8, 4, 0, 1, 2, 3 }, outputRows(&work, &rows));
    // The colour at rows 5 to 8, then the point size at row 4, as
    // nir_move_output_stores_to_end keeps the stores' order.
    try testing.expectEqualSlices(Word, &.{
        vpmIndex(4),               vpmIndex(5), vpmIndex(6),               vpmIndex(7),     vpmIndex(0),               vpmIndex(1),                vpmIndex(2), vpmIndex(3),
        vpmIndex(8),               vpmIndex(9), .{ .float = 8 },           .{ .float = 1 }, vpmIndex(5),               vpmIndex(6),                vpmIndex(7), vpmIndex(4),
        .{ .viewport = .x_scale }, vpmIndex(0), .{ .viewport = .y_scale }, vpmIndex(1),     .{ .viewport = .z_scale }, .{ .viewport = .z_offset }, vpmIndex(2), vpmIndex(3),
    }, code.stream());
}
