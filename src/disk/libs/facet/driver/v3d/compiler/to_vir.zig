// SPDX-License-Identifier: MIT
//! Mesa's nir_to_vir.c, the paths a fragment program of compile.zig's
//! profile takes through it, and since 1.163 a vertex program's (its
//! LDVPMV_IN and STVPMV, the viewport's words and FTOIN), with
//! v3d_tex.c's sample and vir.c's compile strategies around them: compile.zig's steps made into VIR, which the
//! register allocator, the scheduler and the packer (allocate.zig,
//! schedule.zig, to_qpu.zig) make into the QPU's instructions.
//!
//! Mesa walks NIR; this walks the steps compile.zig reads a module into,
//! which are what the NIR is for this profile once spirv_to_nir and v3d's
//! passes are done with it. Each vector op is an op a float
//! (nir_lower_alu_to_scalar), the scalar of a vector times a scalar is
//! read by every product, a constant is a uniform a float where it is
//! first read (ntq_emit_load_const, nir_to_vir.c:2640), and a component or
//! a construct names floats rather than moving them, as nir_copy_prop
//! leaves them for the ops that read them. A texel's half-floats are read
//! out as floats right after the sample, where nir_lower_tex's packing_16
//! puts the unpacking; the unpacking is an fmov of each half, which is the
//! VIR Mesa makes of a pair of half-floats it reads from the tile buffer
//! (vir_emit_tlb_color_read, nir_to_vir.c:2731) and what vir_opt_alu
//! leaves of NIR's f2f32 of a texel's half (vir_opt_alu.c:51). Then the
//! VIR is optimized as Mesa's is (opt.zig), before it is given registers.
//!
//! Where it is not Mesa's:
//! - Every varying the draw carries is read, in order: the vertex record
//!   holds them all (`_play.zig`'s `writeRecord`), where Mesa's linking
//!   drops what the fragment program does not read.
//! - interpolateAt is not in the profile, so emit_fragment_varying's copy
//!   of the C coefficient for it is left out.
//! - The TMU hands back both of its words whatever the program reads of a
//!   texel: the draw writes P0 asking for both (`tiling.parameter0`),
//!   where Mesa asks for the words read (v3d_tex.c:257).
//! - The colour is moved out where the body ends and not at its OpStore,
//!   which the steps do not keep: what comes after the store is not
//!   handed on.
//! - The key is the one this device's draws have: render target 0, of
//!   16-bit floats, red and blue not swapped, or none (since 1.150), and
//!   of what Mesa's key varies, alpha to coverage and that alone (`Key`). One sample a pixel or four
//!   (since 1.148): the colour is written a pixel at a time either way,
//!   as Mesa writes it without sample shading (msaa_per_sample_output).
//! - nir_schedule, which v3d_attempt_compile runs on the NIR before it is
//!   made VIR (vir.c:2118-2140), is not ported: the VIR is in the order
//!   of the steps, which is the order of the module's instructions with
//!   a vertex program's stores at its end, and the QPU's own scheduler
//!   (schedule.zig) orders it from there.
//! - Of the strategies (vir.c:2214), 0 and 2. 1, 3 and 4 turn off what is
//!   not done here (GCM, loop unrolling, UBO load sorting, moving buffer
//!   loads, TMU pipelining) and so would make the same program, and 5's
//!   fallback scheduler is not ported.
//! - A selection Mesa keeps a branch is one since 1.171, at the top level
//!   alone (ntq_emit_if, nir_to_vir.c:4315-4573, its uniform and its
//!   non-uniform form). What strategy 0 does to it is not ported:
//!   nir_opt_gcm (:2300-2304), which may move an instruction into the one
//!   arm that reads it or out of an arm, where here a step is made where
//!   the walk puts it; and nir_opt_if's rewrites (:2299): two selections
//!   of one condition made one (opt_if_merge, nir_opt_if.c:1345), one of
//!   an empty true arm turned over (opt_if_simplification, :741), and the
//!   condition read in an arm made a constant
//!   (opt_if_evaluate_condition_use, :1016). Each changes the
//!   instructions, not what they compute.
//! - nir_convert_from_ssa is done on the steps (`fromSsa`): its webs,
//!   their interference worked out for the one shape a kept selection
//!   has, where every float is made before it, in an arm, or past it.

const std = @import("std");
const assert = std.debug.assert;
const instr = @import("../qpu/instr.zig");
const vir = @import("vir.zig");
const list = @import("list.zig");
const allocate = @import("allocate.zig");
const to_qpu = @import("to_qpu.zig");
const opt = @import("opt.zig");
const compile = @import("../compile.zig");
const Compile = vir.Compile;
const Inst = vir.Inst;
const Reg = vir.Reg;
const Work = compile.Work;
const Step = compile.Step;
const Comparison = compile.Comparison;
const Logic = compile.Logic;
const Integer = compile.Integer;

pub const Error = vir.Error || error{
    /// No strategy could give the temporaries registers.
    Registers,
    /// What the strategies made does not pack, or breaks a rule of
    /// qpu_validate: the port's fault, never the module's.
    Invalid,
};

/// MAX_TMU_QUEUE_SIZE (v3d_compiler.h:62).
const max_tmu_queue_size = 8;

// The tile buffer's write specifiers (nir_to_vir.c:1930).
const tlb_type_f16_color: u32 = 3 << 6;
const tlb_render_target_shift = 3;
const tlb_sample_mode_per_pixel: u32 = 1 << 2;
const tlb_f16_swap_hi_lo: u32 = 1 << 1;
const tlb_vec_size_4_f16: u32 = 1 << 0;
const tlb_vec_size_2_f16: u32 = 0 << 0;
const tlb_type_depth: u32 = (2 << 6) | (0 << 4);
const tlb_v42_depth_type_invariant: u32 = 0 << 3;

/// What the TMU is to hand back: both words of a texel, each two
/// half-floats, which is what `tiling.parameter0` writes beside the
/// texture's state. TMU Config Parameter 0's return words are its bits
/// 0 to 3 (cle/v3d_packet.xml:1537).
pub const texel_words: u32 = 0b11;

/// A compile strategy, of the fields that change anything here (struct
/// v3d_compiler_strategy, v3d_compiler.h).
const Strategy = struct {
    name: []const u8,
    max_threads: u8,
    min_threads: u8,
    max_tmu_spills: u32,
};

/// Strategies 0 and 2 (vir.c:2214): 4 threads without spilling, then 2
/// with as many spills as it takes.
const strategies = [_]Strategy{
    .{ .name = "default", .max_threads = 4, .min_threads = 4, .max_tmu_spills = 0 },
    .{ .name = "lower thread count", .max_threads = 2, .min_threads = 1, .max_tmu_spills = std.math.maxInt(u32) },
};

/// What a pipeline tells the compiler that its module does not: the part
/// of Mesa's v3d_fs_key (v3d_compiler.h:350-400) this device's pipelines
/// vary (since 1.149).
pub const Key = struct {
    /// Colour 0's alpha cuts the samples the pixel covers: alpha to
    /// coverage, which v3dv keys only for a pipeline of four samples
    /// (v3dv_pipeline.c:1321-1324). The TLB blends here, so it is the
    /// QPU's FTOC at the end (`emitFragEnd`), not
    /// nir_lower_alpha_to_coverage, which is for a key that blends in the
    /// program (vir.c:1293-1299).
    sample_alpha_to_coverage: bool = false,
    /// The render targets the subpass draws, a bit each: Mesa's cbufs,
    /// which v3dv sets for each colour attachment that is not
    /// ATTACHMENT_UNUSED (v3dv_pipeline.c:2137-2142). A part draws one, as
    /// render target 0, or none (since 1.150).
    cbufs: u8 = 1,
};

/// A program compiled: its instructions in `c.qpu_insts`, the uniforms it
/// reads in the order it reads them in `c.uniform_contents` and
/// `c.uniform_data`, up to `c.num_uniforms`, and its threads, varyings and
/// scoreboard lock in the compile's own fields.
pub const Program = struct {
    c: *Compile,
    /// One past the highest register the temporaries were given.
    registers: u32,
    /// W read for something other than a varying that is not centroid
    /// (vir_check_payload_w, nir_to_vir.c:5117), for the shader record.
    uses_center_w: bool,
    /// The program writes Z, and early Z is to be off: prog_data's
    /// writes_z and disable_ez (vir.c:1011-1013), which a program that
    /// drops pixels has, or one that covers by alpha.
    writes_z: bool,
    disable_ez: bool,
    /// It has no thread switch, and starts in its last thread section: a
    /// vertex program's prog_data single_seg (since 1.163), and a compute
    /// program's (since 1.195).
    single_seg: bool,
    /// Its varyings that are flat and that are without perspective, a
    /// bit each, the first 24 of c->flat_shade_flags and
    /// c->noperspective_flags (v3d_set_fs_prog_data_inputs, vir.c:
    /// 985-1003; since 1.190).
    flat_shade_flags: u32 = 0,
    noperspective_flags: u32 = 0,

    pub fn destroy(program: Program) void {
        program.c.destroy();
    }
};

/// One TMU operation waiting for its thread switch and LDTMUs
/// (v3d_compiler.h:631).
const Pending = struct {
    step: u16,
    component_mask: u32,
};

/// What nir_to_vir keeps while it walks: what each step's floats are in
/// (Mesa's def_ht), the varyings, the payload, the colour, and the TMU
/// operations not yet flushed.
const Emit = struct {
    c: *Compile,
    work: *const Work,
    key: Key,
    defs: [compile.most_steps][4]Reg = undefined,
    /// A step's floats are there: a sample's are not until it is
    /// unpacked, nor its words until the TMU is flushed (the def that
    /// ntq_get_src does not find).
    defined: [compile.most_steps]bool = @splat(false),
    /// A sample's words as the TMU hands them back.
    words: [compile.most_steps][4]Reg = undefined,
    words_defined: [compile.most_steps]bool = @splat(false),
    inputs: [compile.most_varyings]Reg = undefined,
    /// A vertex program's loads of the VPM's instance id, base instance
    /// and vertex id (c->iid, c->biid, c->vid; since 1.192).
    system: [6]Reg = undefined,
    start_msf: Reg = .{},
    payload_w: Reg = .{},
    payload_w_centroid: Reg = .{},
    payload_z: Reg = .{},
    /// Where the workgroup's shared memory starts, worked out at the
    /// program's start (c->cs_shared_offset; since 1.203).
    cs_shared_offset: Reg = .{},
    outputs: [4]Reg = undefined,
    flush: [max_tmu_queue_size]Pending = undefined,
    flush_count: u32 = 0,
    output_fifo_size: u32 = 0,
    total_count: u32 = 0,
    uses_center_w: bool = false,
    /// A terminate_if was emitted (c->emitted_discard), which is what
    /// info.fs.uses_discard says of the NIR here.
    uses_discard: bool = false,
    writes_z: bool = false,
    /// info.fs.early_fragment_tests, as emit_frag_end leaves it.
    early_fragment_tests: bool = true,
    /// Where the last load_ubo of a constant offset left unifa: its
    /// block, its buffer and the offset the next ldunifa reads
    /// (c->current_unifa_block, _index and _offset, nir_to_vir.c:
    /// 3398-3415; since 1.160).
    current_unifa_block: ?*vir.Block = null,
    current_unifa_index: u32 = 0,
    current_unifa_offset: u32 = 0,
    /// Whether that buffer is a uniform buffer and not a storage buffer,
    /// whose slots are numbered apart (c->current_unifa_is_ubo; since
    /// 1.164).
    current_unifa_is_ubo: bool = false,
    /// The registers nir_convert_from_ssa makes of the kept selections'
    /// phis, one of each web, which ntq_setup_registers gives a
    /// temporary each (nir_to_vir.c:4850-4863); and the web each float of
    /// a step was coalesced into, which it writes (since 1.171).
    webs: [compile.most_steps]Reg = undefined,
    web_count: u32 = 0,
    web_of: [compile.most_steps][4]Web = @splat(@splat(no_web)),
    /// Where each float is read, a bit each step that reads it, and
    /// whether the colour reads it: `fromSsa`'s, on the heap with the
    /// rest, as nir_from_ssa's merge sets are ralloc'd
    /// (nir_from_ssa.c:164-169, :938; since 1.189).
    uses: [compile.most_steps][4]Mask = undefined,
    at_end: [compile.most_steps][4]bool = undefined,
    /// The web each copy at a way's end is in, by its phi, and whether a
    /// web differs from lane to lane (merge_set's divergent; since
    /// 1.207); and the kept selections and their phis.
    copy_web: [compile.most_steps][2]Web = undefined,
    web_divergent: [compile.most_steps]bool = undefined,
    selections: Selections = .{},
    /// The kept selections being emitted, the innermost last: one is in
    /// an arm of the one before it (since 1.207).
    branches: [compile.most_nesting]If = undefined,
    branch_count: usize = 0,
    /// c->flat_shade_flags and c->noperspective_flags: the inputs that
    /// emit_fragment_varying made flat and without perspective, by the
    /// number it gave each (nir_to_vir.c:1085-1110; since 1.190).
    flat_shade_flags: u32 = 0,
    noperspective_flags: u32 = 0,
};

/// A bit for each step (since 1.189; a u128 of the 128 steps before).
const Mask = std.meta.Int(.unsigned, compile.most_steps);

/// A web's number, up to one a step (since 1.189; a u8 before).
const Web = u16;

/// A float coalesced into no web.
const no_web: Web = std.math.maxInt(Web);

/// A kept selection as ntq_emit_if emits it (nir_to_vir.c:4562): its
/// marks, its blocks, and how it is emitted (since 1.171).
const If = struct {
    begin: u16 = 0,
    otherwise: u16 = 0,
    end: u16 = 0,
    then_block: ?*vir.Block = null,
    else_block: ?*vir.Block = null,
    after_block: ?*vir.Block = null,
    empty_else: bool = false,
    uniform: bool = false,
    was_uniform_control_flow: bool = false,
    was_in_control_flow: bool = false,
};

/// How far ahead of unifa a load_ubo may be and still be reached by
/// ldunifas that read nothing (MAX_UNIFA_SKIP_DISTANCE,
/// v3d_compiler.h:69).
const max_unifa_skip_distance = 16;
/// V3D_CHANNELS (v3d_limits.h): the lanes of a QPU, each a word of every
/// float in scratch (since 1.177).
const vir_channels = 16;

/// v3d_compile (vir.c:2605): the steps compiled under each strategy in
/// turn until one gives every temporary a register. Each attempt starts
/// from the steps again, as Mesa's starts from the NIR. The program is
/// the caller's, given back with `Program.destroy`.
pub fn compileSteps(allocator: std.mem.Allocator, compiler: *const vir.Compiler, work: *const Work, key: Key) Error!Program {
    const e = try allocator.create(Emit);
    defer allocator.destroy(e);
    var failed_register_allocation = false;
    for (strategies) |strategy| {
        const c = try Compile.create(allocator);
        var kept = false;
        defer if (!kept) c.destroy();
        // vir_compile_init (vir.c:573), what of it is the strategy's.
        c.compiler = compiler;
        c.stage = switch (work.stage) {
            .vertex => .vertex,
            .gl_compute => .compute,
            else => .fragment,
        };
        c.threads = strategy.max_threads;
        c.max_tmu_spills = strategy.max_tmu_spills;
        e.* = .{ .c = c, .work = work, .key = key };

        const registers = try attemptCompile(e, strategy);
        switch (c.compilation_result) {
            // Broken shader or driver bug.
            .failed => continue,
            .failed_register_allocation => {
                failed_register_allocation = true;
                continue;
            },
            .succeeded => {},
        }
        kept = true;
        return .{
            .c = c,
            .registers = registers,
            .uses_center_w = e.uses_center_w,
            .writes_z = e.writes_z,
            // !info.fs.early_fragment_tests (vir.c:1013), as
            // emit_frag_end set it.
            .disable_ez = !e.early_fragment_tests,
            // !c->last_thrsw (v3d_set_prog_data, vir.c:1041).
            .single_seg = c.last_thrsw == null,
            .flat_shade_flags = e.flat_shade_flags,
            .noperspective_flags = e.noperspective_flags,
        };
    }
    return if (failed_register_allocation) Error.Registers else Error.Invalid;
}

/// v3d_attempt_compile (vir.c:1955) and v3d_nir_to_vir
/// (nir_to_vir.c:5134), for a fragment program: the VIR, the last thread
/// switch, the tile buffer writes, and then registers and the QPU's
/// instructions. It answers how many registers the program uses.
fn attemptCompile(e: *Emit, strategy: Strategy) Error!u32 {
    const c = e.c;
    try nirToVir(e);
    // The last thread switch before the tile buffer writes.
    const restore = try emitLastThrsw(c);
    // emit_vert_end has nothing to emit at 7.1: GFXH-1684's VPMWT is
    // 4.2's (nir_to_vir.c:2166-2173; since 1.163).
    if (c.stage == .fragment) try emitFragEnd(e);
    try opt.optimize(c);
    schedFlags(c);
    // vir_check_payload_w looks at a fragment program alone.
    if (c.stage == .fragment) checkPayloadW(e);
    return nirToVirFinish(c, strategy, restore);
}

/// nir_to_vir (nir_to_vir.c:4909), for a fragment program: the payload
/// moved out of the registers it comes in, the varyings, and the body.
fn nirToVir(e: *Emit) Error!void {
    const c = e.c;
    // A vertex program's attributes are loaded where the body reads them
    // (since 1.163), and the VPM's values it reads first.
    if (c.stage == .vertex) {
        try setupScratch(e);
        try setupVsInputs(e);
        return emitBlock(e);
    }
    if (c.stage == .compute) {
        // The payload's two words, rf3 and rf2 on 7.1 (nir_to_vir.c:
        // 4953-4954; since 1.194).
        e.system[@intFromEnum(compile.SystemValue.cs_payload0)] = try c.mul(.mov, .{vir.reg(.reg, 3)});
        e.system[@intFromEnum(compile.SystemValue.cs_payload1)] = try c.mul(.mov, .{vir.reg(.reg, 2)});
        if (e.work.shared_size != 0) try setupShared(e);
        try setupScratch(e);
        return emitBlock(e);
    }
    e.start_msf = try c.add(.msf, .{});
    // W is rf3 on 7.1, and rf0 before it.
    e.payload_w = try c.mul(.mov, .{vir.reg(.reg, 3)});
    e.payload_w_centroid = try c.mul(.mov, .{vir.reg(.reg, 1)});
    e.payload_z = try c.mul(.mov, .{vir.reg(.reg, 2)});
    // No primitive id, point or line coordinate is in the profile.
    try setupScratch(e);
    try setupFsInputs(e);
    // ntq_setup_outputs: the colour is location 0, which needs nothing
    // emitted.
    try emitBlock(e);
}

/// ntq_setup_vs_inputs (nir_to_vir.c:2416-2438): an LDVPMV_IN of each of
/// the VPM's values the program reads, in the VPM's order, the row the
/// number loaded before it. Where the coordinate program uses one not,
/// which it reads for the vertex program's sake (`VertexKey`), the load
/// is dead code (since 1.192).
fn setupVsInputs(e: *Emit) Error!void {
    const c = e.c;
    const values = e.work.system_values;
    var vpm_components: u32 = 0;
    for ([_]compile.SystemValue{ .instance_id, .base_instance, .vertex_id }) |which| {
        if (!values.has(which)) continue;
        e.system[@intFromEnum(which)] = try c.add(.ldvpmv_in, .{try c.uniformUi(vpm_components)});
        vpm_components += 1;
    }
}

/// Where the workgroup's shared memory starts, cs_shared_offset
/// (nir_to_vir.c:4967-4992; since 1.203): the dispatch's shared memory
/// (QUNIFORM_SHARED_OFFSET) plus the workgroup's place among those in
/// memory times its bytes. The place is the payload's second word's top
/// half, wg_in_mem, under the local index's bits where the workgroup is
/// more than one invocation, which the index then takes the top of.
fn setupShared(e: *Emit) Error!void {
    const c = e.c;
    var wg_in_mem = try c.add(.shr, .{ e.system[@intFromEnum(compile.SystemValue.cs_payload1)], try c.uniformUi(16) });
    const size = e.work.local_size;
    if (size[0] != 1 or size[1] != 1 or size[2] != 1) {
        const wg_bits: u5 = 16 - @as(u5, compile.localIndexBits(e.work));
        const wg_mask: u32 = (@as(u32, 1) << wg_bits) - 1;
        wg_in_mem = try c.add(.@"and", .{ wg_in_mem, try c.uniformUi(wg_mask) });
    }
    const shared_per_wg = try c.uniformUi(e.work.shared_size);
    e.cs_shared_offset = try c.add(.add, .{ try c.uniform(.shared_offset, 0), try c.umul(wg_in_mem, shared_per_wg) });
}

/// Where the program keeps variables in scratch: spill_base worked out
/// at its start, and the scratch's bytes of each lane in the spill buffer
/// before any spill's (nir_to_vir.c:4997-5000; since 1.177).
fn setupScratch(e: *Emit) Error!void {
    if (e.work.scratch_size == 0) return;
    try allocate.setupSpillBase(e.c);
    e.c.spill_size += vir_channels * e.work.scratch_size;
}

/// ntq_setup_fs_inputs (nir_to_vir.c:2503): each varying in the order of
/// its location, a float at a time (emit_fragment_input,
/// nir_to_vir.c:1123). compile.zig has numbered the floats so already.
fn setupFsInputs(e: *Emit) Error!void {
    var varying: u32 = 0;
    while (varying < e.work.varyings) : (varying += 1) {
        e.inputs[varying] = try emitFragmentVarying(e, varying);
    }
}

/// emit_fragment_varying (nir_to_vir.c:1049-1121): the ldvary, and the C
/// coefficient it leaves in rf0, of the varying's interpolation: with
/// perspective the value times W plus it, without the value plus it, and
/// flat it alone, the input's flag set for the draw (since 1.190; with
/// perspective alone before). A centroid one is no decoration the reading
/// takes.
fn emitFragmentVarying(e: *Emit, varying: u32) Error!Reg {
    const c = e.c;
    const c_reg = vir.reg(.reg, 0);
    const ldvary = try c.addInst(.nop, c.undef, c.undef, c.undef);
    ldvary.qpu.sig.ldvary = true;
    const vary = try c.emitDef(ldvary);
    const i = c.num_inputs;
    c.num_inputs += 1;
    const bit = @as(u32, 1) << @intCast(varying);
    if (e.work.flat_floats & bit != 0) {
        e.flat_shade_flags |= @as(u32, 1) << @intCast(i);
        return emitFlatVarying(c, vary, c_reg);
    }
    if (e.work.noperspective_floats & bit != 0) {
        e.noperspective_flags |= @as(u32, 1) << @intCast(i);
        return emitNoperspectiveVarying(c, vary, c_reg);
    }
    return emitSmoothVarying(c, vary, e.payload_w, c_reg);
}

/// emit_smooth_varying (nir_to_vir.c:1027).
fn emitSmoothVarying(c: *Compile, vary: Reg, w: Reg, c_reg: Reg) Error!Reg {
    return c.add(.fadd, .{ try c.mul(.fmul, .{ vary, w }), c_reg });
}

/// emit_noperspective_varying (nir_to_vir.c:1033-1037; since 1.190).
fn emitNoperspectiveVarying(c: *Compile, vary: Reg, c_reg: Reg) Error!Reg {
    return c.add(.fadd, .{ try c.mul(.mov, .{vary}), c_reg });
}

/// emit_flat_varying (nir_to_vir.c:1040-1046): the ldvary's value moved
/// nowhere, and the C coefficient (since 1.190).
fn emitFlatVarying(c: *Compile, vary: Reg, c_reg: Reg) Error!Reg {
    _ = try c.mulDest(.mov, c.undef, .{vary});
    return c.mul(.mov, .{c_reg});
}

/// ntq_emit_block (nir_to_vir.c:4677) for the one block there is: its
/// steps, the colour's store, and the TMU flushed in the block that used
/// it.
fn emitBlock(e: *Emit) Error!void {
    try fromSsa(e);
    // A register for each web something is in: one merged into another
    // has nothing.
    var held: [compile.most_steps]bool = @splat(false);
    for (e.web_of) |parts| for (parts) |web| {
        if (web != no_web) held[web] = true;
    };
    for (e.webs[0..e.web_count], held[0..e.web_count]) |*web, is| {
        if (is) web.* = try e.c.getTemp();
    }
    for (e.work.steps[0..e.work.step_count], 0..) |each, at| try emitStep(e, each, @intCast(at));
    // A program of no colour has no store to emit (since 1.150).
    if (hasColor(e)) try emitColorWrite(e);
    try flushTmu(e);
}

fn emitStep(e: *Emit, each: Step, at: u16) Error!void {
    const c = e.c;
    const parts = each.kind.parts();
    switch (each.tag) {
        .input => {
            const input = e.work.inputs[each.at];
            if (c.stage == .vertex) {
                // ntq_emit_load_input (nir_to_vir.c:2934-2981): an
                // LDVPMV_IN of each float the program reads, at its place
                // among the VPM's floats (since 1.163). One it does not
                // read nir_opt_dce has taken out, and so is nothing here.
                for (0..parts) |k| {
                    if (input.live & @as(u8, 1) << @intCast(k) != 0)
                        try storeDef(e, at, k, try c.add(.ldvpmv_in, .{try c.uniformUi(@intCast(input.first + k))}))
                    else
                        e.defs[at][k] = c.undef;
                }
            } else for (0..parts) |k| {
                // load_input's MOV of the varying (ntq_emit_load_input,
                // nir_to_vir.c:2960-2977), which copy propagation takes
                // out, unless it writes a phi's register (since 1.171).
                if (e.web_of[at][k] != no_web)
                    try storeDef(e, at, k, try c.mul(.mov, .{e.inputs[input.first + k]}))
                else
                    e.defs[at][k] = e.inputs[input.first + k];
            }
        },
        // emit_store_output_vs (nir_to_vir.c:3074-3082): the float, then
        // the VPM's index as a uniform and the STVPMV of the two
        // (vir_VPM_WRITE, :2160-2163; since 1.163).
        .output => {
            const value = try getSrc(e, each.a, 0);
            _ = try c.addNodst(.stvpmv, .{ try c.uniformUi(each.at), value });
        },
        // load_instance_id, load_base_instance and load_vertex_id, a MOV of
        // what the program's start loaded (nir_to_vir.c:3760-3770), which
        // copy propagation takes out unless it writes a phi's register;
        // and load_first_vertex, a uniform (since 1.192).
        .system => switch (@as(compile.SystemValue, @enumFromInt(each.at))) {
            .first_vertex => try storeDef(e, at, 0, try c.uniform(.first_vertex, 0)),
            // load_base_workgroup_id and load_num_workgroups, a uniform
            // of each word (nir_to_vir.c:3877-3883, :3900-3910; since
            // 1.194).
            .work_group_base_x => try storeDef(e, at, 0, try c.uniform(.work_group_base, 0)),
            .work_group_base_y => try storeDef(e, at, 0, try c.uniform(.work_group_base, 1)),
            .work_group_base_z => try storeDef(e, at, 0, try c.uniform(.work_group_base, 2)),
            .num_work_groups_x => try storeDef(e, at, 0, try c.uniform(.num_work_groups, 0)),
            .num_work_groups_y => try storeDef(e, at, 0, try c.uniform(.num_work_groups, 1)),
            .num_work_groups_z => try storeDef(e, at, 0, try c.uniform(.num_work_groups, 2)),
            else => |which| {
                const loaded = e.system[@intFromEnum(which)];
                if (e.web_of[at][0] != no_web)
                    try storeDef(e, at, 0, try c.mul(.mov, .{loaded}))
                else
                    e.defs[at][0] = loaded;
            },
        },
        // load_viewport_*_scale and _z_offset (nir_to_vir.c:3697-3715).
        .viewport => e.defs[at][0] = try c.uniform(switch (@as(compile.Viewport, @enumFromInt(each.at))) {
            .x_scale => .viewport_x_scale,
            .y_scale => .viewport_y_scale,
            .z_offset => .viewport_z_offset,
            .z_scale => .viewport_z_scale,
        }, 0),
        // f2i32 of fround_even, which ntq_emit_alu makes one FTOIN of the
        // fround_even's source (nir_to_vir.c:1466-1472). The fround_even
        // was visited first and is an FROUND that nothing reads, which
        // vir_opt_dead_code takes out.
        .round_to_int => {
            const value = try getSrc(e, each.a, 0);
            _ = try c.add(.fround, .{value});
            try storeDef(e, at, 0, try c.add(.ftoin, .{value}));
        },
        .constant => {
            for (0..parts) |k| e.defs[at][k] = try c.uniformUi(@bitCast(e.work.pool[each.at + k]));
        },
        .component => e.defs[at][0] = try getSrc(e, each.a, each.at),
        .construct => {
            for (0..parts) |k| e.defs[at][k] = try getSrc(e, each.from[k], each.part[k]);
        },
        // ntq_emit_alu (nir_to_vir.c:1365): the sources, then the op, a
        // float at a time, as nir_lower_alu_to_scalar has left them. FSUB,
        // FMIN and FMAX are the add side's (:1441-1463; since 1.152).
        .add, .mul, .sub, .min, .max => {
            const b_scalar = e.work.steps[each.b].kind == .f32x1;
            for (0..parts) |k| {
                const a = try getSrc(e, each.a, k);
                const b = try getSrc(e, each.b, if (b_scalar) 0 else k);
                try storeDef(e, at, k, switch (each.tag) {
                    .add => try c.add(.fadd, .{ a, b }),
                    .sub => try c.add(.fsub, .{ a, b }),
                    .min => try c.add(.fmin, .{ a, b }),
                    .max => try c.add(.fmax, .{ a, b }),
                    else => try c.mul(.fmul, .{ a, b }),
                });
            }
        },
        // A negation of 32 bits is the sign bit XORed (nir_to_vir.c:1412-1419).
        .negate => for (0..parts) |k| {
            try storeDef(e, at, k, try c.add(.xor, .{ try getSrc(e, each.a, k), try c.uniformUi(@as(u32, 1) << 31) }));
        },
        // fabs: FMOV with the ABS unpack (nir_to_vir.c:1793-1801).
        .abs => for (0..parts) |k| {
            const made = try c.mul(.fmov, .{try getSrc(e, each.a, k)});
            vir.setUnpack(c.defs[made.index].?, 0, .abs);
            try storeDef(e, at, k, made);
        },
        // fsat at 7.1: FMOV with the SAT unpack (nir_to_vir.c:1865-1882;
        // since 1.153).
        .sat => for (0..parts) |k| {
            const made = try c.mul(.fmov, .{try getSrc(e, each.a, k)});
            vir.setUnpack(c.defs[made.index].?, 0, .sat);
            try storeDef(e, at, k, made);
        },
        // fsin and fcos (nir_to_vir.c:1782-1787): ntq_fsincos.
        .sin, .cos => for (0..parts) |k| {
            try storeDef(e, at, k, try sinCos(c, try getSrc(e, each.a, k), each.tag == .cos));
        },
        // fsign (nir_to_vir.c:1788): ntq_fsign.
        .sign => for (0..parts) |k| {
            try storeDef(e, at, k, try sign(c, try getSrc(e, each.a, k)));
        },
        // One operand each, the add side's: the rounding (:1769-1779) and
        // the SFU's, which at 7.1 are add operations written to any
        // register (VIR_SFU, v3d_compiler.h:1331-1346; :1756-1766).
        .floor, .ceil, .trunc, .round, .recip, .rsqrt, .exp2, .log2 => for (0..parts) |k| {
            const op: vir.AddOp = switch (each.tag) {
                .floor => .ffloor,
                .ceil => .fceil,
                .trunc => .ftrunc,
                .round => .fround,
                .recip => .recip,
                .rsqrt => .rsqrt,
                .exp2 => .exp,
                else => .log,
            };
            try storeDef(e, at, k, try c.add(op, .{try getSrc(e, each.a, k)}));
        },
        .sample => {
            try emitTex(e, each, at);
            try unpackTexel(e, at);
        },
        // What passed is where a depth is read, the first half of the
        // first word: one float out, as nir_lower_tex's packing_16 leaves
        // the one component a shadow sample's def has.
        .sample_compared => {
            try emitTex(e, each, at);
            const float = try c.mul(.fmov, .{try getWord(e, at, 0)});
            vir.setUnpack(c.defs[float.index].?, 0, .l);
            e.defs[at][0] = float;
        },
        // ntq_emit_txs (nir_to_vir.c:914-960): the level first, then each
        // size the draw writes of the view as a uniform of its own,
        // minified to the level but an array's layers (since 1.181).
        .texture_size => {
            const level = try getSrc(e, each.from[0], 0);
            const layers = e.work.samplers[each.at].dim == .layers;
            for (0..parts) |k| {
                const array = layers and k == parts - 1;
                const contents: vir.Uniform = if (array) .texture_array_size else switch (k) {
                    0 => .texture_width,
                    1 => .texture_height,
                    else => .texture_depth,
                };
                const size = try c.uniform(contents, each.at);
                try storeDef(e, at, k, if (array) size else try minify(c, size, level));
            }
        },
        // ntq_emit_tex's query_levels (nir_to_vir.c:972-975; since 1.181).
        .texture_levels => try storeDef(e, at, 0, try c.uniform(.texture_levels, each.at)),
        // ntq_emit_alu's comparisons (nir_to_vir.c:1727): the comparison
        // into the flags, and the bool made of them.
        .compare => {
            const cond = try emitComparison(e, each);
            e.defs[at][0] = try condToBool(c, cond);
        },
        // iand, ior and inot of the 0 and ~0 a bool is: AND, OR and NOT
        // (ntq_emit_alu, nir_to_vir.c:1683-1694; since 1.157).
        .logic => {
            const a = try getSrc(e, each.a, 0);
            e.defs[at][0] = switch (@as(Logic, @enumFromInt(each.at))) {
                .iand => try c.add(.@"and", .{ a, try getSrc(e, each.b, 0) }),
                .ior => try c.add(.@"or", .{ a, try getSrc(e, each.b, 0) }),
                .inot => try c.add(.not, .{a}),
            };
        },
        // ntq_emit_alu's integer operations, a word at a time (since
        // 1.165): ADD, SUB, MIN, MAX, UMIN, UMAX, SHL, ASR, SHR, AND, OR,
        // XOR and NOT on the add side (nir_to_vir.c:1656-1694), NEG
        // (:1421), a 32-bit multiply as MULTOP and UMUL24 (vir_UMUL,
        // :1700), iabs the MAX of the word and its NEG (:1805), and the
        // conversions FTOIZ, FTOUZ, ITOF and UTOF (:1466-1516). An f2i32
        // of an fround_even is one FTOIN of the fround_even's source
        // (:1466-1472), the FROUND left for vir_opt_dead_code where
        // nothing else reads it.
        .integer => {
            const op: Integer = @enumFromInt(each.at);
            const b_scalar = !op.unary() and e.work.steps[each.b].kind == .f32x1;
            const rounded = op == .f2i32 and e.work.steps[each.a].tag == .round;
            for (0..parts) |k| {
                if (rounded) {
                    try storeDef(e, at, k, try c.add(.ftoin, .{try getSrc(e, e.work.steps[each.a].a, k)}));
                    continue;
                }
                const a = try getSrc(e, each.a, k);
                const b = if (op.unary()) c.undef else try getSrc(e, each.b, if (b_scalar) 0 else k);
                try storeDef(e, at, k, switch (op) {
                    .iadd => try c.add(.add, .{ a, b }),
                    .isub => try c.add(.sub, .{ a, b }),
                    .imul => try c.umul(a, b),
                    .ineg => try c.add(.neg, .{a}),
                    .iabs => try c.add(.max, .{ a, try c.add(.neg, .{a}) }),
                    .imin => try c.add(.min, .{ a, b }),
                    .imax => try c.add(.max, .{ a, b }),
                    .umin => try c.add(.umin, .{ a, b }),
                    .umax => try c.add(.umax, .{ a, b }),
                    .ishl => try c.add(.shl, .{ a, b }),
                    .ishr => try c.add(.asr, .{ a, b }),
                    .ushr => try c.add(.shr, .{ a, b }),
                    .iand => try c.add(.@"and", .{ a, b }),
                    .ior => try c.add(.@"or", .{ a, b }),
                    .ixor => try c.add(.xor, .{ a, b }),
                    .inot => try c.add(.not, .{a}),
                    .f2i32 => try c.add(.ftoiz, .{a}),
                    .f2u32 => try c.add(.ftouz, .{a}),
                    .i2f32 => try c.add(.itof, .{a}),
                    .u2f32 => try c.add(.utof, .{a}),
                    // b2f32, the bool's ~0 or 0 ANDed with 1.0
                    // (nir_to_vir.c:1521-1523; since 1.178).
                    .b2f32 => try c.add(.@"and", .{ a, try c.uniformF(1.0) }),
                    // b2i32, the AND with 1 (:1524-1528; since 1.188).
                    .b2i32 => try c.add(.@"and", .{ a, try c.uniformUi(1) }),
                    // uclz, CLZ (:1696-1697; since 1.197).
                    .uclz => try c.add(.clz, .{a}),
                    // pack_half_2x16_split, VFPACK (:1809-1811), and
                    // f2f32 of a word's u2u16, an FMOV of its low half
                    // (:1575-1578), the MOV of the u2u16 (:1599-1611)
                    // what copy propagation takes out (since 1.200).
                    .pack_half => try c.add(.vfpack, .{ a, b }),
                    .half_float => half: {
                        const float = try c.mul(.fmov, .{a});
                        vir.setUnpack(c.defs[float.index].?, 0, .l);
                        break :half float;
                    },
                });
            }
        },
        // slt (nir_to_vir.c:1710-1723): the comparison, and 1.0 or 0.0 of
        // the flags, which are remembered as holding it (since 1.153).
        .set_less => {
            const cond = try emitComparison(e, .{ .tag = .compare, .kind = .f32x1, .a = each.a, .b = each.b, .at = @intFromEnum(Comparison.less) });
            const result = try c.mul(.mov, .{try c.sel(cond, try c.uniformF(1.0), try c.uniformF(0.0))});
            c.flags_temp = @intCast(result.index);
            c.flags_cond = cond;
            try storeDef(e, at, 0, result);
        },
        // b32csel (nir_to_vir.c:1740-1745): the sources, then the bool as
        // a condition, the flags where they still hold it, and SEL
        // (since 1.153).
        .select => {
            _ = try getSrc(e, each.a, 0);
            const yes = try getSrc(e, each.b, 0);
            const no = try getSrc(e, each.from[0], 0);
            const cond = try boolToCond(e, each.a);
            try storeDef(e, at, 0, try c.mul(.mov, .{try c.sel(cond, yes, no)}));
        },
        // nir_intrinsic_terminate_if (nir_to_vir.c:3833), outside of any
        // control flow: the pixel's mask cleared where the condition
        // holds.
        .discard => {
            e.uses_discard = true;
            try flushTmu(e);
            const cond = try boolToCond(e, each.a);
            vir.setCond(try c.addDest(.setmsf, vir.nopReg(), .{try c.uniformUi(0)}), cond);
        },
        // try_emit_uniform (nir_to_vir.c:2847): a word of the push
        // constants each, as QUNIFORM_UNIFORM at the offset over four.
        .push => {
            for (0..parts) |k| try storeDef(e, at, k, try c.uniform(.uniform, @intCast(each.at + k)));
        },
        // ntq_emit_intrinsic's load_ubo (nir_to_vir.c:3634-3641): through
        // unifa, which its constant offset always allows here. A
        // load_ssbo too (:3638-3643), of a buffer nothing writes, which is
        // every one in the profile (since 1.164).
        .ubo => try emitLoadUnifa(e, each, at),
        // A load_ssbo of memory the program may write is not read through
        // unifa, which would not see what the program wrote (:3338-3343),
        // but through the TMU (since 1.168).
        .ssbo => {
            if (writable(e, each)) return emitTmuGeneral(e, each, at);
            try emitLoadUnifa(e, each, at);
        },
        // At an offset computed: through unifa where the offset is the
        // same in every lane, and else through the TMU, whose LDTMUs
        // define the floats when it is flushed (:3315-3317, :3634-3643;
        // since 1.167).
        .ubo_indirect, .ssbo_indirect => {
            if (e.work.divergent[each.a] or writable(e, each)) return emitTmuGeneral(e, each, at);
            // Nor under the execute mask where the offset is read out of
            // a web's register, which only the lanes that run wrote
            // (:3318-3336; since 1.171).
            if (e.c.inNonuniformControlFlow() and derivedFromReg(e, each.a)) return emitTmuGeneral(e, each, at);
            try emitLoadUnifa(e, each, at);
        },
        // store_ssbo, through the TMU (:3645-3649; since 1.168). It
        // makes no value.
        .ssbo_store => return emitTmuGeneral(e, each, at),
        // ssbo_atomic and ssbo_atomic_swap, through the TMU too
        // (:3645-3649; since 1.169), whose LDTMU defines the word.
        .ssbo_atomic => return emitTmuGeneral(e, each, at),
        // load_scratch and store_scratch, through the TMU from
        // spill_base (:3657-3668; since 1.177).
        .scratch, .scratch_indirect, .scratch_store => return emitTmuGeneral(e, each, at),
        // load_shared, store_shared, shared_atomic and
        // shared_atomic_swap, through the TMU from cs_shared_offset
        // (:3657-3668; since 1.203).
        .shared, .shared_store, .shared_atomic => return emitTmuGeneral(e, each, at),
        // A barrier: what the TMU holds flushed (:3857-3861; since 1.169).
        .barrier => try flushTmu(e),
        // A compute program's barrier of execution: the TMU flushed, a
        // TSY op that blocks the supergroup's invocations until the last
        // has come to it, and the thread switch it blocks at, with no
        // lookup outstanding (emit_compute_barrier, :3563-3577,
        // :3857-3870; since 1.203).
        .control_barrier => {
            try flushTmu(e);
            _ = try c.addDest(.barrierid, vir.magicReg(.syncb), .{});
            try c.emitThrsw();
        },
        // A kept selection (since 1.171).
        .begin_if => try beginIf(e, at),
        .begin_else => try beginElse(e),
        .end_if => try endIf(e),
        // A phi is its web's register, which both ways have written.
        .phi => e.defs[at][0] = e.webs[e.web_of[at][0]],
    }
    e.defined[at] = true;
}

/// nir_src_derived_from_reg: whether a step reads, through steps that
/// compute, a float coalesced into a web.
fn derivedFromReg(e: *const Emit, at: u16) bool {
    const each = e.work.steps[at];
    for (e.web_of[at][0..each.kind.parts()]) |web| if (web != no_web) return true;
    if (each.tag == .phi) return true;
    for (compile.readsOfStep(each)) |field| if (field) |of| {
        if (derivedFromReg(e, of)) return true;
    };
    return false;
}

/// ntq_store_def (nir_to_vir.c:772): a float made, as the step's own, or
/// written into the register of the web it was coalesced into, by the
/// instruction that made it - under the execute mask where the lanes
/// differ - or by a MOV where that instruction cannot be rewritten
/// (since 1.171).
fn storeDef(e: *Emit, at: u16, k: usize, result: Reg) Error!void {
    const web = e.web_of[at][k];
    if (web == no_web) {
        e.defs[at][k] = result;
        return;
    }
    try storeReg(e, e.webs[web], result);
    e.defs[at][k] = e.webs[web];
}

/// The store_reg half of ntq_store_def (nir_to_vir.c:808-847): the last
/// instruction, which made `result`, writes `into` instead. A uniform
/// loaded before and only reused, a load signal under the execute mask,
/// or anything else than the instruction just emitted is moved first.
fn storeReg(e: *Emit, into: Reg, result_in: Reg) Error!void {
    const c = e.c;
    var result = result_in;
    var last = lastInst(c);
    const def = c.defs[result.index];
    const is_reused_uniform = def != null and def.?.qpu.sig.ldunif and def.? != last;
    if (is_reused_uniform or def != last or
        (c.inNonuniformControlFlow() and isLdSignal(last)))
    {
        result = try c.mul(.mov, .{result});
        last = lastInst(c);
    }
    c.defs[last.dst.index] = null;
    last.dst.index = into.index;
    if (c.inNonuniformControlFlow()) {
        c.cursor = vir.beforeInst(last);
        c.setPf(try c.mulDest(.mov, vir.nopReg(), .{c.execute}), .pushz);
        c.cursor = vir.afterInst(last);
        vir.setCond(last, .ifa);
    }
}

fn lastInst(c: *Compile) *Inst {
    return list.entry(Inst, "link", c.cur_block.?.instructions.prev.?);
}

/// is_ld_signal (v3d_compiler.h): a signal that loads into the
/// instruction's register, which no condition holds back.
fn isLdSignal(inst: *const Inst) bool {
    const sig = inst.qpu.sig;
    return sig.ldunif or sig.ldunifa or sig.ldunifrf or sig.ldunifarf or sig.ldtmu or sig.ldvary or sig.ldvpm or sig.ldtlb or sig.ldtlbu;
}

/// ntq_emit_if (nir_to_vir.c:4562), at a kept selection's begin_if: the
/// block before it ends, its TMU flushed (ntq_emit_block, :4677-4692),
/// and the selection is a branch on the condition where every lane goes
/// the same way and nothing outside runs under the execute mask, else
/// under it.
fn beginIf(e: *Emit, at: u16) Error!void {
    const c = e.c;
    try flushTmu(e);
    const steps = e.work.program();
    const marks = branchAt(steps, at);
    const condition = steps[at].a;
    if (e.branch_count == e.branches.len) return Error.Invalid;
    e.branches[e.branch_count] = .{ .begin = marks.begin, .otherwise = marks.otherwise, .end = marks.end };
    e.branch_count += 1;
    const branch = &e.branches[e.branch_count - 1];
    // The false arm's block is empty where it holds nothing, nor any
    // copy into a web (nir_if_first_else_block, :4459-4462).
    branch.empty_else = armCost(e, marks.otherwise, marks.end, 1) == 0;
    branch.was_in_control_flow = c.in_control_flow;
    c.in_control_flow = true;
    branch.uniform = !c.inNonuniformControlFlow() and !e.work.divergent[condition];
    branch.then_block = try c.newBlock();
    branch.after_block = try c.newBlock();
    branch.else_block = if (branch.empty_else) branch.after_block else try c.newBlock();
    if (branch.uniform) {
        // ntq_emit_uniform_if (:4355): jump to the false arm where any
        // lane, of those dispatched and not discarded, takes it.
        const cond = try boolToCond(e, condition);
        const jump = try c.branch(if (cond == .ifa) .anyna else .anya);
        jump.qpu.branch.msfign = .p;
        try c.linkBlocks(c.cur_block.?, branch.else_block.?);
        try c.linkBlocks(c.cur_block.?, branch.then_block.?);
        c.setEmitBlock(branch.then_block.?);
        return;
    }
    // ntq_emit_nonuniform_if (:4455): each lane's execute is 0 where it
    // takes the true arm, else the false arm's block.
    branch.was_uniform_control_flow = false;
    if (!c.inNonuniformControlFlow()) {
        c.execute = try c.mul(.mov, .{try c.uniformUi(0)});
        branch.was_uniform_control_flow = true;
    }
    var cond = try boolToCond(e, condition);
    if (branch.was_uniform_control_flow) {
        cond = invert(cond);
    } else {
        const inst = try c.mulDest(.mov, vir.nopReg(), .{c.execute});
        if (cond == .ifa) {
            c.setUf(inst, .nornz);
        } else {
            c.setUf(inst, .andz);
            cond = .ifa;
        }
    }
    _ = try c.movCond(cond, c.execute, try c.uniformUi(branch.else_block.?.index));
    // The flags for taking the true arm, which is jumped over where no
    // lane takes it, unless it is too small to pay.
    c.setPf(try c.mulDest(.mov, vir.nopReg(), .{c.execute}), .pushz);
    if (!cheap(e, marks.begin, marks.otherwise, 0)) {
        _ = try c.branch(.allna);
        try c.linkBlocks(c.cur_block.?, branch.else_block.?);
    }
    try c.linkBlocks(c.cur_block.?, branch.then_block.?);
    c.setEmitBlock(branch.then_block.?);
}

/// The true arm's end, at the begin_else: its copies into the webs, its
/// TMU flushed, and the false arm's block begun where it has one.
fn beginElse(e: *Emit) Error!void {
    const c = e.c;
    const branch = &e.branches[e.branch_count - 1];
    try emitCopies(e, 0);
    try flushTmu(e);
    if (branch.empty_else) return;
    if (branch.uniform) {
        // At the true arm's end, a jump past the false arm, unless the
        // arm ended in a break or a continue.
        if (!c.cur_block.?.branch_emitted) {
            _ = try c.branch(.always);
            try c.linkBlocks(c.cur_block.?, branch.after_block.?);
        }
        c.setEmitBlock(branch.else_block.?);
        return;
    }
    // Every lane still running points at the merge, and where all do,
    // the false arm is jumped over, unless it is too small to pay.
    c.setPf(try c.mulDest(.mov, vir.nopReg(), .{c.execute}), .pushz);
    _ = try c.movCond(.ifa, c.execute, try c.uniformUi(branch.after_block.?.index));
    if (!cheap(e, branch.otherwise, branch.end, 1)) {
        c.setPf(try c.addDest(.xor, vir.nopReg(), .{ c.execute, try c.uniformUi(branch.after_block.?.index) }), .pushz);
        _ = try c.branch(.alla);
        try c.linkBlocks(c.cur_block.?, branch.after_block.?);
    }
    try c.linkBlocks(c.cur_block.?, branch.else_block.?);
    c.setEmitBlock(branch.else_block.?);
    try activateExecuteForBlock(c);
}

/// The false arm's end, at the end_if: its copies, its TMU flushed, and
/// the merge block, where the lanes the selection held back run again.
fn endIf(e: *Emit) Error!void {
    const c = e.c;
    const branch = &e.branches[e.branch_count - 1];
    try emitCopies(e, 1);
    try flushTmu(e);
    try c.linkBlocks(c.cur_block.?, branch.after_block.?);
    c.setEmitBlock(branch.after_block.?);
    if (!branch.uniform) {
        if (branch.was_uniform_control_flow)
            c.execute = c.undef
        else
            try activateExecuteForBlock(c);
    }
    c.in_control_flow = branch.was_in_control_flow;
    e.branch_count -= 1;
}

/// ntq_activate_execute_for_block (nir_to_vir.c:4315): the lanes whose
/// jump target is this block run again.
fn activateExecuteForBlock(c: *Compile) Error!void {
    c.setPf(try c.addDest(.xor, vir.nopReg(), .{ c.execute, try c.uniformUi(c.cur_block.?.index) }), .pushz);
    _ = try c.movCond(.ifa, c.execute, try c.uniformUi(0));
}

/// v3d_qpu_cond_invert.
fn invert(cond: instr.Cond) instr.Cond {
    return switch (cond) {
        .ifa => .ifna,
        .ifna => .ifa,
        .ifb => .ifnb,
        .ifnb => .ifb,
        .none => .none,
    };
}

/// The phis of the kept selection being emitted, in order.
fn phisOf(e: *const Emit, out: *[compile.most_steps]u16) []const u16 {
    const branch = e.branches[e.branch_count - 1];
    return phisAfter(e.work.program(), .{ .begin = branch.begin, .otherwise = branch.otherwise, .end = branch.end }, out);
}

/// What NIR's block of the arm from `from` to `to` holds, as
/// is_cheap_block counts it (nir_to_vir.c:4323-4352): an ALU operation a
/// float, a constant one load_const, a copy into a web a MOV and a
/// constant's a load_const more. Anything else is past any count.
fn armCost(e: *const Emit, from: u16, to: u16, side: usize) u32 {
    const steps = e.work.program();
    var count: u32 = 0;
    for (steps[from + 1 .. to]) |each| {
        count += switch (each.tag) {
            .component, .construct => 0,
            .constant => 1,
            .add, .mul, .sub, .min, .max, .negate, .abs, .sat, .sin, .cos, .sign, .floor, .ceil, .trunc, .round, .recip, .rsqrt, .exp2, .log2, .set_less, .integer, .round_to_int, .select, .compare, .logic => @intCast(each.kind.parts()),
            else => return std.math.maxInt(u32),
        };
    }
    var phis: [compile.most_steps]u16 = undefined;
    for (phisOf(e, &phis)) |phi| {
        const of = sourceOf(steps[phi], side);
        if (e.web_of[of.step][of.part] == e.web_of[phi][0]) continue;
        count += if (steps[of.step].tag == .constant) 2 else 1;
    }
    return count;
}

/// is_cheap_block: two instructions or fewer, all ALU.
fn cheap(e: *const Emit, from: u16, to: u16, side: usize) bool {
    return armCost(e, from, to, side) < 3;
}

/// The parallel copy at the end of way `side` into the webs of the phis
/// it does not bring coalesced, made MOVs as resolve_parallel_copy makes
/// them (nir_from_ssa.c:718-906): a copy whose web no other copy still
/// reads goes first, and a cycle is broken through a temporary. A
/// constant is a uniform loaded where it is copied, as
/// nir_trivialize_registers's MOV of its load_const reads it.
fn emitCopies(e: *Emit, side: usize) Error!void {
    const c = e.c;
    const steps = e.work.program();
    var phis: [compile.most_steps]u16 = undefined;
    var into: [compile.most_steps]Reg = undefined;
    var from: [compile.most_steps]?Reg = undefined;
    var constant: [compile.most_steps]?u32 = undefined;
    var count: usize = 0;
    for (phisOf(e, &phis)) |phi| {
        const of = sourceOf(steps[phi], side);
        const web = e.web_of[phi][0];
        if (e.web_of[of.step][of.part] == web) continue;
        into[count] = e.webs[web];
        if (steps[of.step].tag == .constant) {
            from[count] = null;
            constant[count] = @bitCast(e.work.pool[steps[of.step].at + of.part]);
        } else {
            from[count] = try getSrc(e, of.step, of.part);
            constant[count] = null;
        }
        count += 1;
    }
    var done: [compile.most_steps]bool = @splat(false);
    var left = count;
    while (left > 0) {
        const ready = for (0..count) |i| {
            if (done[i]) continue;
            const read = for (0..count) |other| {
                if (done[other] or other == i) continue;
                if (from[other]) |src| if (src.file == .temp and src.index == into[i].index) break true;
            } else false;
            if (!read) break i;
        } else null;
        if (ready) |i| {
            const src = if (from[i]) |src| src else try c.uniformUi(constant[i].?);
            try storeReg(e, into[i], try c.mul(.mov, .{src}));
            done[i] = true;
            left -= 1;
            continue;
        }
        // A cycle: the first copy's web is read out into a temporary,
        // which the copies that read it read instead.
        const first = for (0..count) |i| {
            if (!done[i]) break i;
        } else unreachable;
        const saved = try c.mul(.mov, .{into[first]});
        for (0..count) |other| {
            if (done[other]) continue;
            if (from[other]) |src| if (src.file == .temp and src.index == into[first].index) {
                from[other] = saved;
            };
        }
    }
}

/// What nir_convert_from_ssa (nir_from_ssa.c:927-983, with phi_webs_only
/// and consider_divergence) makes of the kept selections' phis: a web of
/// each, the phi and the copies isolate_phi_nodes_block puts at the end
/// of each way in (:334-382), which coalesce_phi_nodes_block merges
/// (:385-401); then, by aggressive_coalesce_block in the blocks' order
/// (:403-443, :969-971), each float a copy is of, with the web it is in,
/// where the two differ alike and none of the one interferes with any of
/// the other (merge_sets_interfere, :231-332, whose walk finds what a
/// test of every pair finds, `Selections.interfere`). A constant is SSA only
/// and copied (:419-424); a sample's or a load's float is a MOV
/// nir_lower_phis_to_scalar put at the end of its way
/// (nir_lower_phis_to_scalar.c), which is copied too, as is a bool, whose
/// comparison's flags the walk keeps. What is not coalesced is copied
/// into the web where its way ends (`emitCopies`).
///
/// The copy at the merge block's start, of the phi into what reads it
/// (:368-379), joins the phi's web always: the phi is read by it alone,
/// and the copies at the ways' ends are live only there. The phi and it
/// are one float here.
///
/// Since 1.207 a kept selection may be in an arm of another, and a float
/// in a web is coalesced with all of it, as Mesa's merge sets are. Until
/// then the test was worked out for the one shape a selection had, and a
/// float in a web was coalesced only where it was a phi.
fn fromSsa(e: *Emit) Error!void {
    const steps = e.work.program();
    const webs = &e.selections;
    webs.find(steps);
    // Where each float is read, a float being a def of its own once
    // nir_lower_io_to_scalar and nir_lower_alu_to_scalar are done: a bit
    // of each step that reads it, through the components and constructs
    // that only name it, and for a phi the end of the way it comes; and
    // whether the colour reads it. A step that computes reads each float
    // of what it reads.
    const uses = &e.uses;
    const at_end = &e.at_end;
    @memset(uses, @splat(0));
    @memset(at_end, @splat(false));
    var at = steps.len;
    while (at > 0) {
        at -= 1;
        const each = steps[at];
        switch (each.tag) {
            .phi => if (webs.of_phi[at] != no_selection) {
                const marks = webs.marks[webs.of_phi[at]];
                uses[each.a][each.part[0]] |= bitOf(marks.otherwise);
                uses[each.b][each.part[1]] |= bitOf(marks.end);
            },
            .component => uses[each.a][each.at] |= uses[at][0],
            .construct => for (0..each.kind.parts()) |k| {
                uses[each.from[k]][each.part[k]] |= uses[at][k];
            },
            else => for (compile.readsOfStep(each)) |field| if (field) |of| {
                for (&uses[of]) |*part| part.* |= bitOf(@intCast(at));
            },
        }
    }
    if (e.work.stored != compile.none) for (0..steps[e.work.stored].kind.parts()) |k| {
        endRead(steps, at_end, .{ .step = e.work.stored, .part = @intCast(k) });
    };

    for (0..webs.count) |k| for (webs.phisOf(k)) |phi| {
        const web: Web = @intCast(e.web_count);
        e.web_of[phi][0] = web;
        e.copy_web[phi] = .{ web, web };
        e.web_divergent[web] = e.work.divergent[phi];
        e.web_count += 1;
    };
    // Each way's end, where its copies are, in the order of the program,
    // which is the order of its blocks.
    var ways: [2 * compile.most_kept]Way = undefined;
    var way_count: usize = 0;
    for (0..webs.count) |k| for (0..2) |side| {
        const way: Way = .{ .selection = @intCast(k), .side = @intCast(side) };
        var place = way_count;
        while (place > 0 and webs.endOf(ways[place - 1]) > webs.endOf(way)) : (place -= 1) ways[place] = ways[place - 1];
        ways[place] = way;
        way_count += 1;
    };
    for (ways[0..way_count]) |way| for (webs.phisOf(way.selection)) |phi| {
        const of = sourceOf(steps[phi], way.side);
        if (!coalescable(e, webs.marks[way.selection], of, way.side)) continue;
        const into = e.web_of[phi][0];
        const from = e.web_of[of.step][of.part];
        if (from == into) continue;
        const divergent = if (from == no_web) e.work.divergent[of.step] else e.web_divergent[from];
        if (divergent != e.web_divergent[into]) continue;
        if (webs.interfere(e, of, into)) continue;
        join(e, of, into);
    };
}

fn bitOf(at: u16) Mask {
    return @as(Mask, 1) << @intCast(at);
}

/// The steps after `at`.
fn above(at: u16) Mask {
    if (at >= compile.most_steps - 1) return 0;
    return ~((bitOf(at) << 1) - 1);
}

/// The steps after `at`, to `to` and with it.
fn span(at: u16, to: u16) Mask {
    return above(at) & ~above(to);
}

/// A float the colour reads, and what it names.
fn endRead(steps: []const Step, at_end: *[compile.most_steps][4]bool, of: compile.Float) void {
    at_end[of.step][of.part] = true;
    const each = steps[of.step];
    switch (each.tag) {
        .component => endRead(steps, at_end, .{ .step = each.a, .part = @intCast(each.at) }),
        .construct => endRead(steps, at_end, .{ .step = each.from[of.part], .part = each.part[of.part] }),
        else => {},
    }
}

/// A kept selection's marks.
const Marks = struct { begin: u16, otherwise: u16, end: u16 };

/// The marks of the kept selection whose begin_if is `begin`: past those
/// of any selection in its arms (since 1.207).
fn branchAt(steps: []const Step, begin: u16) Marks {
    var marks: Marks = .{ .begin = begin, .otherwise = begin, .end = begin };
    var depth: usize = 0;
    var k = begin + 1;
    while (true) : (k += 1) switch (steps[k].tag) {
        .begin_if => depth += 1,
        .begin_else => if (depth == 0) {
            marks.otherwise = k;
        },
        .end_if => if (depth == 0) {
            marks.end = k;
            return marks;
        } else {
            depth -= 1;
        },
        else => {},
    };
}

/// The phis of the kept selection of `marks`, in order: those of its
/// condition past its end_if, and before the next mark of the level it
/// is at, the begin_if of a selection after it or the end of the arm it
/// is in (since 1.207).
fn phisAfter(steps: []const Step, marks: Marks, out: []u16) []u16 {
    const condition = steps[marks.begin].a;
    var count: usize = 0;
    var k = marks.end + 1;
    while (k < steps.len) : (k += 1) switch (steps[k].tag) {
        .begin_if, .begin_else, .end_if => break,
        .phi => if (steps[k].from[0] == condition) {
            out[count] = k;
            count += 1;
        },
        else => {},
    };
    return out[0..count];
}

/// The float `of` put in the web `web`, and where it is in a web of a
/// selection before, all that web with it, its copies too
/// (merge_merge_sets, nir_from_ssa.c:197-223).
fn join(e: *Emit, of: compile.Float, web: Web) void {
    const was = e.web_of[of.step][of.part];
    if (was == no_web) {
        e.web_of[of.step][of.part] = web;
        e.web_divergent[web] = e.web_divergent[web] or e.work.divergent[of.step];
        return;
    }
    for (&e.web_of) |*parts| for (parts) |*part| {
        if (part.* == was) part.* = web;
    };
    for (&e.copy_web) |*sides| for (sides) |*side| {
        if (side.* == was) side.* = web;
    };
    e.web_divergent[web] = e.web_divergent[web] or e.web_divergent[was];
}

/// The float a phi has from one way: the true arm's, 0, or the false
/// arm's, 1.
fn sourceOf(phi: Step, side: usize) compile.Float {
    return if (side == 0) .{ .step = phi.a, .part = phi.part[0] } else .{ .step = phi.b, .part = phi.part[1] };
}

/// A kept selection's way in to its merge: its true arm's, 0, or its
/// false arm's.
const Way = struct { selection: u8, side: u1 };

/// No kept selection's.
const no_selection: u8 = std.math.maxInt(u8);

/// Whether a float the step at `time` makes after the one made there
/// reads `node`, which is then live where that one is made, as
/// search_for_use_after_instr (nir_liveness.c:247-256) finds it:
/// nir_lower_alu_width makes a vector's operation an instruction a
/// float, in order (nir_lower_alu_width.c:407-432), and each reads the
/// one float of an operand that is a scalar, or a float a construct
/// names twice (since 1.207). Before, the later floats' reads were
/// missed, and a float in an arm made by multiplying with one made
/// before it could share that one's register while the rest still read
/// it.
fn readAgain(steps: []const Step, node: Node, time: Time) bool {
    const each = steps[time.at];
    const operands: [2]?u16 = switch (each.tag) {
        .add, .mul, .sub, .min, .max => .{ each.a, each.b },
        .negate, .abs, .sat, .sin, .cos, .sign, .floor, .ceil, .trunc, .round, .recip, .rsqrt, .exp2, .log2 => .{ each.a, null },
        .integer => integer: {
            const op: Integer = @enumFromInt(each.at);
            // An f2i32 of an fround_even is an FTOIN of what that reads.
            if (op == .f2i32 and steps[each.a].tag == .round) break :integer .{ steps[each.a].a, null };
            break :integer .{ each.a, if (op.unary()) null else each.b };
        },
        else => return false,
    };
    for (time.sub + 1..each.kind.parts()) |k| for (operands) |operand| if (operand) |of| {
        const part: u8 = if (steps[of].kind == .f32x1) 0 else @intCast(k);
        const read = madeOf(steps, .{ .step = of, .part = part });
        if (read.step == node.step and read.part == node.part) return true;
    };
    return false;
}

/// The float a component or a construct names, as the step that makes
/// it has it.
fn madeOf(steps: []const Step, of: compile.Float) compile.Float {
    const each = steps[of.step];
    return switch (each.tag) {
        .component => madeOf(steps, .{ .step = each.a, .part = @intCast(each.at) }),
        .construct => madeOf(steps, .{ .step = each.from[of.part], .part = each.part[of.part] }),
        else => of,
    };
}

/// What a web holds (merge_node): a float, a phi among them, or the copy
/// at the end of the way `side` into the phi `step`.
const Node = struct {
    step: u16,
    part: u8 = 0,
    copy: bool = false,
    side: u1 = 0,
};

/// Where a node is made in the program's order: its step, and its float
/// among the step's, or its phi among the selection's at the end of its
/// way (def_after's order, nir_from_ssa.c:65-79).
const Time = struct {
    at: u16,
    sub: u16,

    fn before(a: Time, b: Time) bool {
        return a.at < b.at or (a.at == b.at and a.sub < b.sub);
    }
};

/// The kept selections as nir_convert_from_ssa meets them: each one's
/// marks and phis, in the order of the begin_ifs; and which selection
/// each phi is of, and its place among the selection's phis.
const Selections = struct {
    marks: [compile.most_kept]Marks = undefined,
    count: usize = 0,
    phis: [compile.most_steps]u16 = undefined,
    phis_from: [compile.most_kept + 1]u16 = undefined,
    of_phi: [compile.most_steps]u8 = undefined,
    place: [compile.most_steps]u16 = undefined,
    /// The nodes of the two webs `interfere` compares.
    nodes: [2][5 * compile.most_steps]Node = undefined,
    steps: []const Step = &.{},

    fn find(webs: *Selections, steps: []const Step) void {
        webs.steps = steps;
        webs.count = 0;
        @memset(&webs.of_phi, no_selection);
        var count: u16 = 0;
        for (steps, 0..) |each, at| {
            if (each.tag != .begin_if) continue;
            const k = webs.count;
            const marks = branchAt(steps, @intCast(at));
            webs.marks[k] = marks;
            webs.phis_from[k] = count;
            for (phisAfter(steps, marks, webs.phis[count..]), 0..) |phi, place| {
                webs.of_phi[phi] = @intCast(k);
                webs.place[phi] = @intCast(place);
                count += 1;
            }
            webs.count += 1;
        }
        webs.phis_from[webs.count] = count;
    }

    fn phisOf(webs: *const Selections, k: usize) []const u16 {
        return webs.phis[webs.phis_from[k]..webs.phis_from[k + 1]];
    }

    /// Where a way's copies are: its selection's begin_else, or its
    /// end_if.
    fn endOf(webs: *const Selections, way: Way) u16 {
        const marks = webs.marks[way.selection];
        return if (way.side == 0) marks.otherwise else marks.end;
    }

    /// The way whose copies are at `at`, if any is.
    fn wayAt(webs: *const Selections, at: u16) ?Way {
        for (webs.marks[0..webs.count], 0..) |marks, k| {
            if (at == marks.otherwise) return .{ .selection = @intCast(k), .side = 0 };
            if (at == marks.end) return .{ .selection = @intCast(k), .side = 1 };
        }
        return null;
    }

    fn timeOf(webs: *const Selections, node: Node) Time {
        if (!node.copy) return .{ .at = node.step, .sub = node.part };
        return .{ .at = webs.endOf(.{ .selection = webs.of_phi[node.step], .side = node.side }), .sub = webs.place[node.step] };
    }

    /// The steps that may run after `at`: those past it, but for the
    /// false arm of each selection whose true arm it is in, or ends.
    fn reach(webs: *const Selections, at: u16) Mask {
        var mask = above(at);
        for (webs.marks[0..webs.count]) |marks| {
            if (marks.begin < at and at <= marks.otherwise) mask &= ~span(marks.otherwise, marks.end);
        }
        return mask;
    }

    /// nir_def_is_live_at (nir_liveness.c:270-290) of `node` where `time`
    /// is, which comes after it: a float read at a step that may run
    /// later, by a copy after it at the end of its way, or by the colour;
    /// a copy, read by its phi alone, at the copies after it at its way's
    /// end, of which it is live out.
    fn liveAt(webs: *const Selections, e: *const Emit, node: Node, time: Time) bool {
        if (node.copy) {
            const own = webs.timeOf(node);
            return time.at == own.at and time.sub > own.sub;
        }
        if (e.at_end[node.step][node.part]) return true;
        if (e.uses[node.step][node.part] & webs.reach(time.at) != 0) return true;
        if (readAgain(webs.steps, node, time)) return true;
        const way = webs.wayAt(time.at) orelse return false;
        for (webs.phisOf(way.selection)) |phi| {
            if (webs.place[phi] <= time.sub) continue;
            const read = sourceOf(webs.steps[phi], way.side);
            if (read.step == node.step and read.part == node.part) return true;
        }
        return false;
    }

    /// nir_defs_interfere (nir_liveness.c:292-312): the one made first is
    /// live where the other is made.
    fn nodesInterfere(webs: *const Selections, e: *const Emit, a: Node, b: Node) bool {
        const at_a = webs.timeOf(a);
        const at_b = webs.timeOf(b);
        if (at_a.at == at_b.at and at_a.sub == at_b.sub) return true;
        return if (at_a.before(at_b)) webs.liveAt(e, a, at_b) else webs.liveAt(e, b, at_a);
    }

    /// What `web` holds, or the float `of` alone where it is in none.
    fn members(webs: *const Selections, e: *const Emit, web: Web, of: compile.Float, out: []Node) []Node {
        if (web == no_web) {
            out[0] = .{ .step = of.step, .part = @intCast(of.part) };
            return out[0..1];
        }
        var count: usize = 0;
        for (e.web_of[0..webs.steps.len], 0..) |parts, step| for (parts, 0..) |part, k| {
            if (part != web) continue;
            out[count] = .{ .step = @intCast(step), .part = @intCast(k) };
            count += 1;
        };
        for (webs.phis[0..webs.phis_from[webs.count]]) |phi| for (e.copy_web[phi], 0..) |side_web, side| {
            if (side_web != web) continue;
            out[count] = .{ .step = phi, .copy = true, .side = @intCast(side) };
            count += 1;
        };
        return out[0..count];
    }

    /// merge_sets_interfere (nir_from_ssa.c:231-303): whether anything of
    /// the web the float `of` is in, or of it alone, interferes with
    /// anything of the web `into`. Mesa's walk tests each node against
    /// the nearest that dominates it, which, the webs being free of
    /// interference within, finds what testing every pair does.
    fn interfere(webs: *Selections, e: *const Emit, of: compile.Float, into: Web) bool {
        const from = webs.members(e, e.web_of[of.step][of.part], of, &webs.nodes[0]);
        const to = webs.members(e, into, of, &webs.nodes[1]);
        for (from) |a| for (to) |b| {
            if (webs.nodesInterfere(e, a, b)) return true;
        };
        return false;
    }
};

/// Where a step is to a kept selection: before it, in its true arm, in
/// its false arm, or past it.
const Where = enum { before, yes, no, after };

fn whereOf(marks: Marks, at: u16) Where {
    if (at < marks.begin) return .before;
    if (at < marks.otherwise) return .yes;
    if (at < marks.end) return .no;
    return .after;
}

/// Whether a float may be coalesced into a web at all: a phi, whose
/// copy at its merge's start is what a later way's copy reads; or one
/// the walk makes one instruction of, in a block its way goes through.
fn coalescable(e: *const Emit, marks: Marks, of: compile.Float, side: usize) bool {
    const each = e.work.steps[of.step];
    if (each.tag == .phi) return true;
    const scalar = each.kind == .f32x1;
    const made = switch (each.tag) {
        .add, .mul, .sub, .min, .max, .negate, .abs, .sat, .sin, .cos, .sign, .floor, .ceil, .trunc, .round, .recip, .rsqrt, .exp2, .log2, .set_less, .integer, .round_to_int, .input => true,
        .select => !compile.isBool(e.work, of.step),
        .push, .ubo, .ssbo, .ubo_indirect, .ssbo_indirect, .ssbo_atomic, .scratch, .scratch_indirect, .shared, .shared_atomic => scalar,
        else => false,
    };
    if (!made) return false;
    return switch (whereOf(marks, of.step)) {
        .before => true,
        .yes => side == 0,
        .no => side == 1,
        .after => false,
    };
}

/// ntq_emit_load_unifa (nir_to_vir.c:3299-3507), for what the profile
/// has: a load_ubo of 32-bit floats at a constant offset, outside of any
/// control flow, so its offset is uniform and derived from no register.
/// unifa is written with the buffer's address and the offset, and each
/// ldunifa reads a word and moves it on by four; a load in the same
/// block and buffer a little past the last one reads on from there,
/// with ldunifas that read nothing to step over the gap, instead of
/// writing unifa again (since 1.160). A load_ssbo the same, of a buffer
/// nothing writes (:3338-3343): its address is QUNIFORM_SSBO_OFFSET,
/// which the offset is added to in the program (since 1.164). An offset
/// the program computes is added to either's address, the uniform buffer's
/// at an offset of 0, and leaves no address to read on from
/// (:3348, :3398-3400, :3441-3444; since 1.166).
fn emitLoadUnifa(e: *Emit, each: Step, at: u16) Error!void {
    const c = e.c;
    const is_ssbo = each.tag == .ssbo or each.tag == .ssbo_indirect;
    // Every ldunifa moves the address on by 4 bytes, so the current
    // offset is 4 bytes past the last load's.
    const max_unifa_skip_dist: u32 = max_unifa_skip_distance - 4;
    // An offset the program computes, the same in every lane
    // (`compile.lanes`), is added to the buffer's address (since 1.166).
    const dynamic_src = each.tag == .ubo_indirect or each.tag == .ssbo_indirect;
    const const_offset: u32 = if (dynamic_src) 0 else each.at;
    // QUNIFORM_UBO_ADDR takes the buffer's index shifted up by one, 0
    // being the push constants' in Vulkan; a storage buffer's is its own.
    const index = @as(u32, each.b) + @intFromBool(!is_ssbo);

    // Only a constant offset's address is kept to skip to.
    var skip_unifa = false;
    var ldunifa_skips: u32 = 0;
    if (dynamic_src) {
        e.current_unifa_block = null;
    } else if (c.cur_block == e.current_unifa_block and
        e.current_unifa_is_ubo == !is_ssbo and
        e.current_unifa_index == index and
        e.current_unifa_offset <= const_offset and
        e.current_unifa_offset + max_unifa_skip_dist >= const_offset)
    {
        skip_unifa = true;
        ldunifa_skips = (const_offset - e.current_unifa_offset) / 4;
    } else {
        e.current_unifa_block = c.cur_block;
        e.current_unifa_is_ubo = !is_ssbo;
        e.current_unifa_index = index;
        e.current_unifa_offset = const_offset;
    }

    if (!skip_unifa) {
        const base_offset = if (!is_ssbo)
            try c.uniform(.ubo_addr, vir.unitDataCreate(index, const_offset))
        else
            try c.uniform(.ssbo_offset, index);
        const unifa = vir.magicReg(.unifa);
        if (dynamic_src) {
            _ = try c.addDest(.add, unifa, .{ base_offset, try getSrc(e, each.a, 0) });
        } else if (!is_ssbo) {
            // The ldunif made to load into unifa itself, where it is the
            // one just emitted rather than an earlier one reused, which
            // saves the MOV.
            const block = c.cur_block.?;
            const last = list.entry(Inst, "link", block.instructions.prev.?);
            if (c.defs[base_offset.index] == last) {
                last.dst = unifa;
                c.defs[base_offset.index] = null;
            } else {
                _ = try c.mulDest(.mov, unifa, .{base_offset});
            }
        } else if (const_offset != 0) {
            _ = try c.addDest(.add, unifa, .{ base_offset, try c.uniformUi(const_offset) });
        } else {
            _ = try c.mulDest(.mov, unifa, .{base_offset});
        }
    } else {
        for (0..ldunifa_skips) |_| _ = try emitLdunifa(e, false);
    }

    for (0..each.kind.parts()) |i| {
        const data = try emitLdunifa(e, true);
        try storeDef(e, at, i, try c.mul(.mov, .{data}));
    }
}

/// emit_ldunifa (nir_to_vir.c:3246): a word read through unifa, kept
/// where `kept` says so, and the offset moved on.
fn emitLdunifa(e: *Emit, kept: bool) Error!Reg {
    const c = e.c;
    const ldunifa = try c.addInst(.nop, c.undef, c.undef, c.undef);
    ldunifa.qpu.sig.ldunifa = true;
    const result = if (kept) try c.emitDef(ldunifa) else blk: {
        _ = c.emitNondef(ldunifa);
        break :blk c.undef;
    };
    e.current_unifa_offset += 4;
    return result;
}

/// ntq_emit_comparison (nir_to_vir.c:1173-1232): FCMP a, b pushing Z for
/// feq, the same inverted for fneu, FCMP b, a pushing C for fge and
/// FCMP a, b pushing N for flt. NIR has no greater-than and no
/// less-or-equal: spirv_to_nir reads OpFOrdGreaterThan as flt and
/// OpFOrdLessThanEqual as fge, each with its operands swapped
/// (vtn_nir_alu_op_for_spirv_opcode, vtn_alu.c:369-381). The integer
/// ones (since 1.165): XOR a, b pushing Z for ieq, inverted for ine; MIN
/// b, a pushing C for ilt, inverted for ige; SUB a, b pushing C for ult,
/// inverted for uge; the operands already swapped where vtn swaps them.
fn emitComparison(e: *Emit, compare: Step) Error!instr.Cond {
    const c = e.c;
    const a = try getSrc(e, compare.a, 0);
    const b = try getSrc(e, compare.b, 0);
    const which: Comparison = @enumFromInt(compare.at);
    const swapped = which == .greater or which == .less_equal;
    const src0 = if (swapped) b else a;
    const src1 = if (swapped) a else b;
    switch (which) {
        .equal, .not_equal => c.setPf(try c.addDest(.fcmp, vir.nopReg(), .{ src0, src1 }), .pushz),
        .greater_equal, .less_equal => c.setPf(try c.addDest(.fcmp, vir.nopReg(), .{ src1, src0 }), .pushc),
        .less, .greater => c.setPf(try c.addDest(.fcmp, vir.nopReg(), .{ src0, src1 }), .pushn),
        .int_equal, .int_not_equal => c.setPf(try c.addDest(.xor, vir.nopReg(), .{ src0, src1 }), .pushz),
        .int_less, .int_greater_equal => c.setPf(try c.addDest(.min, vir.nopReg(), .{ src1, src0 }), .pushc),
        .uint_less, .uint_greater_equal => c.setPf(try c.addDest(.sub, vir.nopReg(), .{ src0, src1 }), .pushc),
    }
    return switch (which) {
        .not_equal, .int_not_equal, .int_greater_equal, .uint_greater_equal => .ifna,
        else => .ifa,
    };
}

/// ntq_fsincos (nir_to_vir.c:990-1003): the angle in periods of pi, a
/// half more for the cosine, the SFU's SIN of what is left of it after
/// the nearest whole one, and the sign turned for an odd one: the whole
/// number shifted by 31 (the -1 the shift reads five bits of) into the
/// sign bit.
fn sinCos(c: *Compile, src: Reg, is_cos: bool) Error!Reg {
    var input = try c.mul(.fmul, .{ src, try c.uniformF(@floatCast(@as(f64, 1.0) / std.math.pi)) });
    if (is_cos) input = try c.add(.fadd, .{ input, try c.uniformF(0.5) });
    const periods = try c.add(.fround, .{input});
    const sin_output = try c.add(.sin, .{try c.add(.fsub, .{ input, periods })});
    return c.add(.xor, .{ sin_output, try c.add(.shl, .{ try c.add(.ftoin, .{periods}), try c.uniformUi(@bitCast(@as(i32, -1))) }) });
}

/// ntq_fsign (nir_to_vir.c:1005-1016): 0.0, then 1.0 where the float is
/// not zero, then -1.0 where it is negative, each a conditional move
/// after an FMOV that pushes the flags.
fn sign(c: *Compile, src: Reg) Error!Reg {
    const t = try c.getTemp();
    _ = try c.mulDest(.mov, t, .{try c.uniformF(0.0)});
    c.setPf(try c.mulDest(.fmov, vir.nopReg(), .{src}), .pushz);
    _ = try c.movCond(.ifna, t, try c.uniformF(1.0));
    c.setPf(try c.mulDest(.fmov, vir.nopReg(), .{src}), .pushn);
    _ = try c.movCond(.ifa, t, try c.uniformF(-1.0));
    return c.mul(.mov, .{t});
}

/// ntq_emit_cond_to_bool (nir_to_vir.c:1284): ~0 where the condition
/// holds, 0 where not, and the flags remembered as holding it.
fn condToBool(c: *Compile, cond: instr.Cond) Error!Reg {
    const result = try c.mul(.mov, .{try c.sel(cond, try c.uniformUi(~@as(u32, 0)), try c.uniformUi(0))});
    c.flags_temp = @intCast(result.index);
    c.flags_cond = cond;
    return result;
}

/// ntq_emit_bool_to_cond (nir_to_vir.c:1262): the flags as they are where
/// they still hold the bool, the comparison emitted again where its
/// step is one, and the bool tested against 0 where it is not, or where
/// the comparison reads a float in a web: ntq_get_alu_parent
/// (:1239-1258) will not emit again what reads a load_reg, which a
/// store_reg since may have written (since 1.207; before, a comparison
/// read again after a phi's register it read was written in an arm).
fn boolToCond(e: *Emit, step: u16) Error!instr.Cond {
    const c = e.c;
    const qsrc = try getSrc(e, step, 0);
    if (qsrc.file == .temp and c.flags_temp == @as(i32, @intCast(qsrc.index))) return c.flags_cond;
    const compare = e.work.steps[step];
    if (compare.tag == .compare and !readsWeb(e, compare)) return emitComparison(e, compare);
    c.setPf(try c.mulDest(.mov, vir.nopReg(), .{qsrc}), .pushz);
    return .ifna;
}

/// Whether a comparison reads a float that is in a web.
fn readsWeb(e: *const Emit, compare: Step) bool {
    for ([_]u16{ compare.a, compare.b }) |of| {
        const read = madeOf(e.work.program(), .{ .step = of, .part = 0 });
        if (e.web_of[read.step][read.part] != no_web) return true;
    }
    return false;
}

/// ntq_get_src (nir_to_vir.c:856): a float of a step, which a TMU
/// operation not yet flushed may still owe.
fn getSrc(e: *Emit, step: u16, i: usize) Error!Reg {
    if (!e.defined[step]) try flushTmu(e);
    assert(e.defined[step]);
    return e.defs[step][i];
}

/// A word of a sample, as ntq_get_src has it for the sample's own def.
fn getWord(e: *Emit, step: u16, i: usize) Error!Reg {
    if (!e.words_defined[step]) try flushTmu(e);
    assert(e.words_defined[step]);
    return e.words[step][i];
}

/// The texel's two words read out as four floats, red and green from the
/// first, blue and alpha from the second, each low half first
/// (vir_emit_tlb_color_read's unpacking, nir_to_vir.c:2731).
fn unpackTexel(e: *Emit, at: u16) Error!void {
    const c = e.c;
    for (0..2) |word| {
        const pair = try getWord(e, at, word);
        for ([_]instr.InputUnpack{ .l, .h }, 0..) |half, k| {
            const float = try c.mul(.fmov, .{pair});
            vir.setUnpack(c.defs[float.index].?, 0, half);
            e.defs[at][word * 2 + k] = float;
        }
    }
}

/// ntq_emit_color_write (nir_to_vir.c:3020): the colour moved out of what
/// the body made it in.
/// The program writes a colour: Mesa's output_color_var[0], which the
/// steps have where the module stores one. Every module compiled does,
/// and the program of no colour (`compileNoColor`) does not.
fn hasColor(e: *const Emit) bool {
    return e.work.output_count != 0;
}

fn emitColorWrite(e: *Emit) Error!void {
    for (&e.outputs, 0..) |*output, k| output.* = try e.c.mul(.mov, .{try getSrc(e, e.work.stored, k)});
}

/// vir_TMU_WRITE (v3d_tex.c:34).
fn tmuWrite(c: *Compile, waddr: vir.Waddr, val: Reg) Error!*Inst {
    return c.mulDest(.mov, vir.magicReg(waddr), .{val});
}

/// vir_WRTMUC (v3d_tex.c:57): a TMU configuration parameter, from the
/// uniform stream.
fn wrtmuc(c: *Compile, contents: vir.Uniform, data: u32) Error!void {
    const inst = try c.nop();
    inst.qpu.sig.wrtmuc = true;
    inst.uniform = try c.getUniformIndex(contents, data);
}

/// v3d_vir_emit_tex (v3d_tex.c:230), for what the profile samples: a 2D
/// texture, a layer of an array, a 3D texture or a cube (since 1.179), at
/// the coordinate its `SamplerDim` names, with an implicit level of detail,
/// its texels in 16-bit floats; a `sample_compared` writes the reference
/// too (since 1.143).
fn emitTex(e: *Emit, each: Step, at: u16) Error!void {
    const c = e.c;
    const compared = each.tag == .sample_compared;
    const dim = e.work.samplers[each.at].dim;
    // P0: the words to hand back; P2, the default, regular lookup.
    const return_words = texel_words;

    // get_required_tex_tmu_writes (v3d_tex.c:222): S and T, R or I where
    // the image has a third float, the comparator's TMUDREF, and a bias's
    // or a level's TMUB (since 1.180), which a fetch of a sample has not
    // (since 1.209). The input FIFO has 16 slots across all threads.
    const tmu_writes: u32 = 2 + @as(u32, @intFromBool(dim != .flat)) + @intFromBool(compared) + @intFromBool(each.lookup.leveled());
    while (tmu_writes > 16 / @as(u32, c.threads)) c.threads /= 2;

    // Pipelining it would overflow the TMU's FIFOs: flush what waits.
    const dest_components = @popCount(return_words);
    if (tmuFifoOverflow(e, dest_components)) try flushTmu(e);

    // handle_tex_src (v3d_tex.c:85): S starts the lookup, so it is kept
    // for the end, and T is written first; then a 3D texture's and a
    // cube's third float to TMUR (:115-120) and a layer to TMUI
    // (:122-127), the floats past the image's left unread.
    const s = try getSrc(e, each.a, 0);
    _ = try tmuWrite(c, .tmut, try getSrc(e, each.a, 1));
    switch (dim) {
        .flat => {},
        .volume, .cube => _ = try tmuWrite(c, .tmur, try getSrc(e, each.a, 2)),
        .layers => _ = try tmuWrite(c, .tmui, try getSrc(e, each.a, 2)),
    }
    // The comparator after the coordinate, as NIR's sources come
    // (v3d_tex.c:155-157).
    if (compared) _ = try tmuWrite(c, .tmudref, try getSrc(e, each.b, 0));
    // A bias, or a level, after it, as vtn orders the sources
    // (spirv_to_nir.c:3420-3438): each one float to TMUB (v3d_tex.c:
    // 129-150; since 1.180).
    if (each.lookup.leveled()) _ = try tmuWrite(c, .tmub, try getSrc(e, each.from[0], 0));

    // The texture's number in the high bits of the address, for the
    // driver to put the texture's state there (v3d_tex.c:297-301): here
    // the sampler the module declares, which `compile` makes the
    // program's unit (since 1.173).
    const p0_packed = return_words | @as(u32, each.at) << 24;
    try wrtmuc(c, .tmu_config_p0, p0_packed);

    // P1 is needed: a sample needs a sampler (v3d_tex.c:311-321). Its
    // output 16-bit, the coordinates normalized, and the per-pixel mask
    // on where the sample skips its helper pixels or the program is not
    // a fragment program's (since 1.167): that bit alone, and the
    // sampler's number above it. P2 is the default, so neither it nor
    // the P1 a P2 would need is written.
    const p1_packed: u32 = if (c.stage != .fragment or e.work.skip_helpers[at]) compile.per_pixel_mask else 0;
    // P2 after it where it is not the default (v3d_tex.c:349-352, :372-
    // 373), a constant the uniform stream carries: a ConstOffset's texels
    // in its offset fields, as many as the image's coordinate names but
    // a layer (:158-170), and a cube's level disabling the automatic one,
    // which TMUSLOD does for every other image (:135-150; since 1.180).
    const p2_packed = texConfigP2(each.offsets, each.lookup == .lod and dim == .cube);
    const needs_p2 = p2_packed != p2_default;
    if (!each.lookup.fetches()) {
        try wrtmuc(c, .tmu_config_p1, p1_packed | @as(u32, each.at) << 24);
    } else if (c.stage == .fragment and !e.work.skip_helpers[at]) {
        // A fetch needs no sampler, so its P1 is the constant of its own
        // bits where they are not the default, a fragment program's
        // fetch that reads its helper pixels: the per-pixel mask off
        // (v3d_tex.c:312-354) - or, where P2 is written, the default's,
        // which a P2 needs before it (:355-368; since 1.182).
        try wrtmuc(c, .constant, p1_packed);
    } else if (needs_p2) {
        try wrtmuc(c, .constant, compile.per_pixel_mask);
    }
    if (needs_p2) try wrtmuc(c, .constant, p2_packed);

    // A fetch's lookup is started at TMUSF (v3d_tex.c:375-377; since
    // 1.182), a sample's too (since 1.209), a cube's at TMUSCM
    // (:378-379), and one at a level the program gives at TMUSLOD
    // (:380-381).
    const retiring = try tmuWrite(c, if (each.lookup.fetches()) .tmusf else if (dim == .cube) .tmuscm else if (each.lookup == .lod) .tmuslod else .tmus, s);
    // Mesa's own count, which is the mask of the words rather than how
    // many: the scheduler only holds a lookup back for it.
    retiring.ldtmu_count = return_words;
    try addPendingTmuFlush(e, at, return_words);
}

/// ntq_minify (nir_to_vir.c:895-912): a size at a level, the level 0
/// size shifted right by it and at least 1. v3dv gives no null
/// descriptor here, so a size of 0 is not kept (since 1.181).
fn minify(c: *Compile, size: Reg, level: Reg) Error!Reg {
    return c.add(.max, .{ try c.add(.shr, .{ size, level }), try c.uniformUi(1) });
}

/// TMU configuration parameter 2 as V3D42_TMU_CONFIG_PARAMETER_2_pack
/// packs it (v3d_packet.xml:1578-1593): the operation in bits 20-23, the
/// offsets along r, t and s four bits each at 16, 12 and 8, the automatic
/// level disabled at bit 1. A sample's is V3D_TMU_OP_REGULAR and the
/// fields it sets, a gather's, a gradient's and a level query's fields
/// not taken here (since 1.180).
fn texConfigP2(offsets: [3]i8, disable_autolod: bool) u32 {
    var packed_word: u32 = tmu_op_regular << 20 | @as(u32, @intFromBool(disable_autolod)) << 1;
    for (offsets, 0..) |offset, k| {
        const nibble: u32 = @as(u4, @bitCast(@as(i4, @intCast(offset))));
        packed_word |= nibble << @intCast(8 + 4 * k);
    }
    return packed_word;
}

/// p2_unpacked_default (v3d_tex.c:35-37) packed: a regular lookup.
const p2_default: u32 = tmu_op_regular << 20;

/// The TMU's general lookup, as its configuration word has it
/// (nir_to_vir.c:43-52): the lookup a quad's or a pixel's, and what it
/// reads.
const general_tmu_lookup_per_quad: u32 = 0 << 7;
const general_tmu_lookup_per_pixel: u32 = 1 << 7;
const general_tmu_lookup_type_vec2: u32 = 2;
const general_tmu_lookup_type_32bit_ui: u32 = 7;
/// V3D_TMU_OP_REGULAR (v3d_packet.xml:99), a load's operation
/// (v3d_general_tmu_op, nir_to_vir.c:213-226).
const tmu_op_regular: u32 = 15;

/// The TMU's operations an atomic is (v3d_packet.xml:87-100).
const TmuOp = struct {
    const write_add_read_prefetch: u32 = 0;
    const write_xchg_read_flush: u32 = 2;
    const write_cmpxchg_read_flush: u32 = 3;
    const write_umin_full_l1_clear: u32 = 4;
    const write_umax: u32 = 5;
    const write_smin: u32 = 6;
    const write_smax: u32 = 7;
    const write_and_read_inc: u32 = 8;
    const write_or_read_dec: u32 = 9;
    const write_xor_read_not: u32 = 10;
};

/// v3d_general_tmu_op_for_atomic (nir_to_vir.c:189-208): an atomic's TMU
/// operation, an iadd of a constant 1 or -1 the TMU's own increment or
/// decrement (v3d_get_op_for_atomic_add, :175-187).
fn atomicTmuOp(e: *const Emit, each: Step) u32 {
    return switch (each.atomic) {
        .iadd => if (constantWord(e, each.a)) |word| switch (word) {
            1 => TmuOp.write_and_read_inc,
            0xffffffff => TmuOp.write_or_read_dec,
            else => TmuOp.write_add_read_prefetch,
        } else TmuOp.write_add_read_prefetch,
        .imin => TmuOp.write_smin,
        .umin => TmuOp.write_umin_full_l1_clear,
        .imax => TmuOp.write_smax,
        .umax => TmuOp.write_umax,
        .iand => TmuOp.write_and_read_inc,
        .ior => TmuOp.write_or_read_dec,
        .ixor => TmuOp.write_xor_read_not,
        .xchg => TmuOp.write_xchg_read_flush,
        .cmpxchg => TmuOp.write_cmpxchg_read_flush,
    };
}

/// A step's word where it is a constant of one, as nir_src_is_const
/// finds it.
fn constantWord(e: *const Emit, step: u16) ?u32 {
    const each = e.work.steps[step];
    if (each.tag != .constant or each.kind != .f32x1) return null;
    return @bitCast(e.work.pool[each.at]);
}

/// A load_ssbo of memory the program may write: one that is not
/// ACCESS_NON_WRITEABLE, which nir_opt_access makes every load of a
/// program that writes no buffer (nir_opt_access.c:266-272; since 1.168).
fn writable(e: *const Emit, each: Step) bool {
    return (each.tag == .ssbo or each.tag == .ssbo_indirect) and !each.non_writeable and e.work.buffers_written;
}

/// ntq_emit_tmu_general (nir_to_vir.c:502-725), for a load_ubo or a
/// load_ssbo at an offset that differs from lane to lane (since 1.167), a
/// load_ssbo of memory the program may write and a store_ssbo (since
/// 1.168). The buffer's address first, a uniform buffer's slot shifted up
/// by one at an offset of 0 and a storage buffer's own (:560-603). Then
/// the count Mesa makes before it emits: a TMUD write for each float a
/// store writes, whose value is read (emit_tmu_general_store_writes,
/// :346-392), and one for the address, whose offset is read where it is
/// computed (:449-454) - either may flush what the TMU holds; the threads
/// that leaves room for, and a flush where the output FIFO would overflow
/// (:690-701). Then the writes themselves: the floats into TMUD, and the
/// offset added to the address into TMUAU, with the configuration as its
/// uniform, or into TMUA where the configuration is the default, a
/// pixel's 32-bit word (:456-492). A load's lookup is a quad's in a
/// fragment program, unless its helper pixels are skipped
/// (ACCESS_SKIP_HELPERS, :640-648), and a store's a pixel's; either reads
/// or writes a 32-bit word or as many as it has (:650-670). The LDTMUs
/// are owed, or a store's TMUWT (:702-710), and a store leaves the job's
/// caches to be cleaned (tmu_dirty_rcl, :532-533).
fn emitTmuGeneral(e: *Emit, each: Step, at: u16) Error!void {
    const c = e.c;
    const is_store = each.tag == .ssbo_store or each.tag == .scratch_store or each.tag == .shared_store;
    const is_atomic = each.tag == .ssbo_atomic or each.tag == .shared_atomic;
    const tmu_op = if (is_atomic) atomicTmuOp(e, each) else tmu_op_regular;
    // An iadd made an increment or a decrement writes no operand
    // (:507-519).
    const atomic_add_replaced = is_atomic and each.atomic == .iadd and
        (tmu_op == TmuOp.write_and_read_inc or tmu_op == TmuOp.write_or_read_dec);
    if (is_store or is_atomic) c.tmu_dirty_rcl = true;
    // The offset's step where it is computed, and else the constant one.
    const offset_src: u16 = switch (each.tag) {
        .ubo_indirect, .ssbo_indirect, .scratch_indirect, .shared => each.a,
        .ssbo_store, .ssbo_atomic, .scratch_store, .shared_store, .shared_atomic => each.from[0],
        else => compile.none,
    };
    const dynamic_src = offset_src != compile.none;
    const const_offset: u32 = if (dynamic_src) 0 else each.at;
    // Scratch has no buffer: its base is spill_base, which the program
    // worked out at its start (:578-586; since 1.177).
    const is_scratch = each.tag == .scratch or each.tag == .scratch_indirect or each.tag == .scratch_store;
    // Shared memory neither: its base is cs_shared_offset, the
    // workgroup's place in it (:587-588; since 1.203).
    const is_shared = each.tag == .shared or each.tag == .shared_store or each.tag == .shared_atomic;
    const base_offset = if (is_scratch)
        c.spill_base
    else if (is_shared)
        e.cs_shared_offset
    else if (each.tag == .ubo_indirect)
        try c.uniform(.ubo_addr, vir.unitDataCreate(@as(u32, each.b) + 1, 0))
    else
        try c.uniform(.ssbo_offset, each.b);

    const parts: u32 = @intCast(each.kind.parts());
    const dest_components: u32 = if (is_store) 0 else parts;
    // An atomic's operands, the second cmpxchg's
    // (emit_tmu_general_atomic_writes, :400-420).
    const operands: []const u16 = if (!is_atomic or atomic_add_replaced)
        &.{}
    else if (each.atomic == .cmpxchg)
        &.{ each.a, each.from[1] }
    else
        &.{each.a};
    var tmu_writes: u32 = 0;
    if (is_store) for (0..parts) |k| {
        _ = try getSrc(e, each.a, k);
        tmu_writes += 1;
    };
    for (operands) |operand| {
        _ = try getSrc(e, operand, 0);
        tmu_writes += 1;
    }
    tmu_writes += 1;
    if (dynamic_src) _ = try getSrc(e, offset_src, 0);
    while (tmu_writes > 16 / @as(u32, c.threads)) c.threads /= 2;
    if (tmuFifoOverflow(e, dest_components)) try flushTmu(e);

    if (is_store) for (0..parts) |k| {
        _ = try c.mulDest(.mov, vir.magicReg(.tmud), .{try getSrc(e, each.a, k)});
    };
    for (operands) |operand| _ = try c.mulDest(.mov, vir.magicReg(.tmud), .{try getSrc(e, operand, 0)});
    const is_load = !is_store and !is_atomic;
    const num_components = if (is_load) parts else tmu_writes - 1;
    const perquad = if (is_load and c.stage == .fragment and !e.work.skip_helpers[at])
        general_tmu_lookup_per_quad
    else
        general_tmu_lookup_per_pixel;
    var config: u32 = 0xffffff00 | tmu_op << 3 | perquad;
    // An atomic's word is a 32-bit one, cmpxchg's a pair (:666-669).
    config |= if (tmu_op == TmuOp.write_cmpxchg_read_flush)
        general_tmu_lookup_type_vec2
    else if (is_atomic or num_components == 1)
        general_tmu_lookup_type_32bit_ui
    else
        general_tmu_lookup_type_vec2 + num_components - 2;

    // Under the execute mask, the address is written for the lanes that
    // run (emit_tmu_general_address_write, :457-459, :490-491; since
    // 1.171).
    if (c.inNonuniformControlFlow()) c.setPf(try c.mulDest(.mov, vir.nopReg(), .{c.execute}), .pushz);
    const tmua = vir.magicReg(if (config == ~@as(u32, 0)) .tmua else .tmuau);
    const tmu = if (dynamic_src)
        try c.addDest(.add, tmua, .{ base_offset, try getSrc(e, offset_src, 0) })
    else if (const_offset != 0)
        try c.addDest(.add, tmua, .{ base_offset, try c.uniformUi(const_offset) })
    else
        try c.mulDest(.mov, tmua, .{base_offset});
    if (config != ~@as(u32, 0)) tmu.uniform = try c.getUniformIndex(.constant, config);
    if (c.inNonuniformControlFlow()) vir.setCond(tmu, .ifa);
    tmu.ldtmu_count = dest_components;
    try addPendingTmuFlush(e, at, (@as(u32, 1) << @intCast(dest_components)) - 1);
}

/// ntq_tmu_fifo_overflow (nir_to_vir.c:252): whether `components` more
/// LDTMUs would overflow the TMU's output FIFO, which cannot stall.
fn tmuFifoOverflow(e: *const Emit, components: u32) bool {
    if (e.flush_count >= max_tmu_queue_size) return true;
    return components > 0 and e.output_fifo_size + components > 16 / @as(u32, e.c.threads);
}

/// ntq_flush_tmu (nir_to_vir.c:266): the thread switch, and the LDTMUs or
/// the TMUWT, for every TMU operation waiting. A sample's words are
/// unpacked after, and a general load's are its floats (since 1.167;
/// at a constant offset, since 1.168).
fn flushTmu(e: *Emit) Error!void {
    if (e.flush_count == 0) return;
    const c = e.c;
    try c.emitThrsw();

    var emitted_tmuwt = false;
    for (e.flush[0..e.flush_count]) |pending| {
        if (pending.component_mask > 0) {
            const tag = e.work.steps[pending.step].tag;
            const general = switch (tag) {
                .ubo, .ubo_indirect, .ssbo, .ssbo_indirect, .ssbo_atomic, .scratch, .scratch_indirect, .shared, .shared_atomic => true,
                else => false,
            };
            for (0..4) |j| {
                if (pending.component_mask & @as(u32, 1) << @intCast(j) != 0) {
                    const word = try c.mul(.mov, .{try c.ldtmu()});
                    if (general) try storeDef(e, pending.step, j, word) else e.words[pending.step][j] = word;
                }
            }
            if (general) e.defined[pending.step] = true else e.words_defined[pending.step] = true;
        } else if (!emitted_tmuwt) {
            _ = try c.addNodst(.tmuwt, .{});
            emitted_tmuwt = true;
        }
    }
    e.output_fifo_size = 0;
    e.flush_count = 0;
}

/// ntq_add_pending_tmu_flush (nir_to_vir.c:302): a thread switch and
/// LDTMUs owed for a TMU operation. Every value here is SSA, so there are
/// no registers waiting on it.
fn addPendingTmuFlush(e: *Emit, step: u16, component_mask: u32) Error!void {
    const num_components = @popCount(component_mask);
    assert(!tmuFifoOverflow(e, num_components));
    if (num_components > 0) e.output_fifo_size += num_components;
    e.flush[e.flush_count] = .{ .step = step, .component_mask = component_mask };
    e.flush_count += 1;
    e.total_count += 1;
}

/// What vir_emit_last_thrsw keeps to undo what it adds.
const Restore = struct {
    last_thrsw: ?*Inst,
    scoreboard_lock: bool,
};

/// vir_emit_last_thrsw (nir_to_vir.c:5059): a last thread switch at the
/// top level, which spilling cannot put another after. Where the program
/// has one already, another is added all the same, and taken out again
/// where nothing spills (vir_restore_last_thrsw).
fn emitLastThrsw(c: *Compile) Error!Restore {
    var restore: Restore = .{ .last_thrsw = c.last_thrsw, .scoreboard_lock = false };

    // A last thread switch in conditional code: another, to flag as the
    // last.
    if (c.last_thrsw != null and !c.last_thrsw_at_top_level) try c.emitThrsw();

    // A fragment program has a last thread switch, to emit as a pair.
    if (c.last_thrsw == null and c.stage == .fragment) try c.emitThrsw();

    // None added yet: one now, so that any spill comes before it.
    if (restore.last_thrsw == c.last_thrsw) {
        if (restore.last_thrsw) |thrsw| thrsw.is_last_thrsw = false;
        restore.scoreboard_lock = c.lock_scoreboard_on_first_thrsw;
        try c.emitThrsw();
    } else {
        restore.last_thrsw = c.last_thrsw;
    }

    c.last_thrsw.?.is_last_thrsw = true;
    return restore;
}

/// vir_restore_last_thrsw (nir_to_vir.c:5099).
fn restoreLastThrsw(c: *Compile, restore: Restore) void {
    c.removeInstruction(c.last_thrsw.?);
    c.last_thrsw = restore.last_thrsw;
    if (c.last_thrsw) |thrsw| thrsw.is_last_thrsw = true;
    c.lock_scoreboard_on_first_thrsw = restore.scoreboard_lock;
}

/// emit_frag_end (nir_to_vir.c:2041), for a program that writes no depth,
/// no sample mask and no image or buffer, and writes a colour: its early
/// fragment tests are promoted unless it discards or covers by alpha,
/// nothing reads Z, and Z is written through where they are not.
fn emitFragEnd(e: *Emit) Error!void {
    const c = e.c;
    // Alpha to coverage where the TLB blends (nir_to_vir.c:2056-2065):
    // the samples FTOC makes of colour 0's alpha, kept of those the pixel
    // has (since 1.149).
    if (e.key.sample_alpha_to_coverage and hasColor(e)) {
        const covered = try c.add(.@"and", .{ try c.add(.msf, .{}), try c.add(.ftoc, .{e.outputs[3]}) });
        _ = try c.addDest(.setmsf, vir.nopReg(), .{covered});
    }
    // A colour the TLB takes: render target 0 is among the key's, and
    // the program writes it (nir_to_vir.c:2050-2054).
    const has_any_tlb_color_write = e.key.cbufs & 1 != 0 and hasColor(e);
    // There is no image or sample mask, so early_fragment_tests is
    // promoted where a colour is written, no storage buffer is named
    // (info.num_ssbos, :2074; since 1.168), nothing discards and nothing
    // covers by alpha (nir_to_vir.c:2073-2081; v3dv has no
    // can_earlyz_with_discard), and where it is not the program writes Z
    // (nir_to_vir.c:2098): a program of no colour always does, its one
    // TLB write, where Mesa also says it discards (:2125-2126), which
    // nothing after reads here. It has no gl_FragDepth, so that Z is the
    // one the rasterizer made, written through as it is.
    e.early_fragment_tests = has_any_tlb_color_write and !e.work.uses_ssbo and !e.uses_discard and !e.key.sample_alpha_to_coverage;
    if (!e.early_fragment_tests) {
        e.writes_z = true;
        const inst = try c.mulDest(.mov, vir.magicReg(.tlbu), .{vir.nopReg()});
        // The spec says PER_PIXEL is ignored for invariant writes, but
        // the simulator demands it (nir_to_vir.c:2120).
        const tlb_specifier = tlb_type_depth | tlb_v42_depth_type_invariant | tlb_sample_mode_per_pixel;
        inst.uniform = try c.getUniformIndex(.constant, tlb_specifier | 0xffffff00);
        inst.is_tlb_z_write = true;
    }
    try emitTlbColorWrite(e, 0);
}

/// sched_flags (nir_to_vir.c:4902) for the one block there is: each
/// instruction that writes the flags and nothing else moved up to just
/// after the last instruction it must follow, so that what it reads is
/// live no longer than it has to be.
fn schedFlags(c: *Compile) void {
    var blocks = c.eachBlock();
    while (blocks.next()) |block| schedFlagsInBlock(block);
}

/// sched_flags_in_block (nir_to_vir.c:4854).
fn schedFlagsInBlock(block: *vir.Block) void {
    var flags_inst: ?*Inst = null;
    var insts = list.EachSafe(Inst, "link", .backward){ .head = &block.instructions, .pos = block.instructions.prev.? };
    while (insts.next()) |inst| {
        // What would keep the flags instruction from moving earlier than
        // this one: it reads what this one writes, or this one reads or
        // writes the flags.
        if (flags_inst) |flags| {
            if (readsReg(flags, inst.dst) or instr.writesFlags(&inst.qpu) or instr.readsFlags(&inst.qpu)) {
                flags.link.moveTo(&inst.link);
                flags_inst = null;
            }
        }
        // Only an instruction that does nothing but write the flags.
        if (inst.qpu.kind != .alu or inst.dst.file != .null or !instr.writesFlags(&inst.qpu)) continue;
        assert(flags_inst == null);
        flags_inst = inst;
    }
    // At the top of the block, where nothing held it back.
    if (flags_inst) |flags| flags.link.moveTo(&block.instructions);
}

/// vir_inst_reads_reg (nir_to_vir.c:4843).
fn readsReg(inst: *const Inst, r: Reg) bool {
    for (inst.src[0..vir.getNsrc(inst)]) |src| {
        if (src.file == r.file and src.index == r.index) return true;
    }
    return false;
}

/// vir_emit_tlb_color_write (nir_to_vir.c:1955), for a render target of
/// 16-bit floats and one sample a pixel: two pairs packed to the tile
/// buffer, the first with its specifier where it is not the one the
/// register is preloaded with.
fn emitTlbColorWrite(e: *Emit, rt: u32) Error!void {
    const c = e.c;
    if (e.key.cbufs & (@as(u8, 1) << @intCast(rt)) == 0 or !hasColor(e)) return;
    const num_components = 4;
    var conf: u32 = 0xffffff00;
    conf |= tlb_sample_mode_per_pixel;
    conf |= (7 - rt) << tlb_render_target_shift;
    conf |= tlb_type_f16_color | tlb_f16_swap_hi_lo;
    conf |= if (num_components >= 3) tlb_vec_size_4_f16 else tlb_vec_size_2_f16;

    const color = e.outputs;
    const inst = try c.addDest(.vfpack, vir.magicReg(.tlb), .{ color[0], color[1] });
    if (conf != ~@as(u32, 0)) {
        inst.dst = vir.magicReg(.tlbu);
        inst.uniform = try c.getUniformIndex(.constant, conf);
    }
    if (num_components >= 3) _ = try c.addDest(.vfpack, vir.magicReg(.tlb), .{ color[2], color[3] });
}

/// vir_check_payload_w (nir_to_vir.c:5117).
fn checkPayloadW(e: *Emit) void {
    var insts = e.c.eachInstInorder();
    while (insts.next()) |inst| {
        for (inst.src[0..vir.getNsrc(inst)]) |src| {
            if (src.file == e.payload_w.file and src.index == e.payload_w.index) {
                e.uses_center_w = true;
                return;
            }
        }
    }
}

/// v3d_nir_to_vir_finish (nir_to_vir.c:5219): registers for the
/// temporaries, at fewer threads where they do not fit and the strategy
/// lets it go lower; the last thread switch put back where nothing
/// spilled; and the QPU's instructions. It answers one past the highest
/// register given.
fn nirToVirFinish(c: *Compile, strategy: Strategy, restore: Restore) Error!u32 {
    const min_threads = 2;
    const temp_registers = while (true) {
        if (try allocate.registerAllocate(c)) |registers| {
            assert(c.spills + c.fills <= c.max_tmu_spills);
            break registers;
        }
        if (c.threads <= @max(strategy.min_threads, min_threads)) {
            c.compilation_result = .failed_register_allocation;
            return 0;
        }
        c.spills = 0;
        c.fills = 0;
        c.threads /= 2;
        // One thread, which the minimum of 2 keeps from happening:
        // vir_remove_thrsw is not ported.
        assert(c.threads > 1);
    };
    defer c.allocator.free(temp_registers);

    if (c.spills == 0 and c.last_thrsw != restore.last_thrsw) restoreLastThrsw(c, restore);

    var registers: u32 = 0;
    for (temp_registers) |r| registers = @max(registers, @as(u32, r.index) + 1);
    if (try to_qpu.virToQpu(c, temp_registers) != null) assert(c.compilation_result == .failed);
    return registers;
}
