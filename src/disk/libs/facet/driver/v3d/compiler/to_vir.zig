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

/// The one combined image sampler there is, as Mesa numbers the texture
/// and the sampler for the driver in the high bits of P0 and P1.
const texture_index = 0;
const sampler_index = 0;

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
    /// vertex program's prog_data single_seg (since 1.163).
    single_seg: bool,

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
    start_msf: Reg = .{},
    payload_w: Reg = .{},
    payload_w_centroid: Reg = .{},
    payload_z: Reg = .{},
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
};

/// How far ahead of unifa a load_ubo may be and still be reached by
/// ldunifas that read nothing (MAX_UNIFA_SKIP_DISTANCE,
/// v3d_compiler.h:69).
const max_unifa_skip_distance = 16;

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
        c.stage = if (work.stage == .vertex) .vertex else .fragment;
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
    // A vertex program's inputs are loaded where the body reads them, and
    // it reads no instance, base instance or vertex id
    // (ntq_setup_vs_inputs, nir_to_vir.c:2385-2433; since 1.163).
    if (c.stage == .vertex) return emitBlock(e);
    e.start_msf = try c.add(.msf, .{});
    // W is rf3 on 7.1, and rf0 before it.
    e.payload_w = try c.mul(.mov, .{vir.reg(.reg, 3)});
    e.payload_w_centroid = try c.mul(.mov, .{vir.reg(.reg, 1)});
    e.payload_z = try c.mul(.mov, .{vir.reg(.reg, 2)});
    // No primitive id, point or line coordinate is in the profile.
    try setupFsInputs(e);
    // ntq_setup_outputs: the colour is location 0, which needs nothing
    // emitted.
    try emitBlock(e);
}

/// ntq_setup_fs_inputs (nir_to_vir.c:2503): each varying in the order of
/// its location, a float at a time (emit_fragment_input,
/// nir_to_vir.c:1123). compile.zig has numbered the floats so already.
fn setupFsInputs(e: *Emit) Error!void {
    var varying: u32 = 0;
    while (varying < e.work.varyings) : (varying += 1) {
        e.inputs[varying] = try emitFragmentVarying(e);
    }
}

/// emit_fragment_varying (nir_to_vir.c:1049), for a varying interpolated
/// with perspective, which is all the profile has: the ldvary, and the
/// value times W plus the C coefficient the ldvary leaves in rf0.
fn emitFragmentVarying(e: *Emit) Error!Reg {
    const c = e.c;
    const c_reg = vir.reg(.reg, 0);
    const ldvary = try c.addInst(.nop, c.undef, c.undef, c.undef);
    ldvary.qpu.sig.ldvary = true;
    const vary = try c.emitDef(ldvary);
    c.num_inputs += 1;
    return emitSmoothVarying(c, vary, e.payload_w, c_reg);
}

/// emit_smooth_varying (nir_to_vir.c:1027).
fn emitSmoothVarying(c: *Compile, vary: Reg, w: Reg, c_reg: Reg) Error!Reg {
    return c.add(.fadd, .{ try c.mul(.fmul, .{ vary, w }), c_reg });
}

/// ntq_emit_block (nir_to_vir.c:4677) for the one block there is: its
/// steps, the colour's store, and the TMU flushed in the block that used
/// it.
fn emitBlock(e: *Emit) Error!void {
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
                    e.defs[at][k] = if (input.live & @as(u8, 1) << @intCast(k) != 0)
                        try c.add(.ldvpmv_in, .{try c.uniformUi(@intCast(input.first + k))})
                    else
                        c.undef;
                }
            } else for (0..parts) |k| {
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
            e.defs[at][0] = try c.add(.ftoin, .{value});
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
                e.defs[at][k] = switch (each.tag) {
                    .add => try c.add(.fadd, .{ a, b }),
                    .sub => try c.add(.fsub, .{ a, b }),
                    .min => try c.add(.fmin, .{ a, b }),
                    .max => try c.add(.fmax, .{ a, b }),
                    else => try c.mul(.fmul, .{ a, b }),
                };
            }
        },
        // A negation of 32 bits is the sign bit XORed (nir_to_vir.c:1412-1419).
        .negate => for (0..parts) |k| {
            e.defs[at][k] = try c.add(.xor, .{ try getSrc(e, each.a, k), try c.uniformUi(@as(u32, 1) << 31) });
        },
        // fabs: FMOV with the ABS unpack (nir_to_vir.c:1793-1801).
        .abs => for (0..parts) |k| {
            const made = try c.mul(.fmov, .{try getSrc(e, each.a, k)});
            vir.setUnpack(c.defs[made.index].?, 0, .abs);
            e.defs[at][k] = made;
        },
        // fsat at 7.1: FMOV with the SAT unpack (nir_to_vir.c:1865-1882;
        // since 1.153).
        .sat => for (0..parts) |k| {
            const made = try c.mul(.fmov, .{try getSrc(e, each.a, k)});
            vir.setUnpack(c.defs[made.index].?, 0, .sat);
            e.defs[at][k] = made;
        },
        // fsin and fcos (nir_to_vir.c:1782-1787): ntq_fsincos.
        .sin, .cos => for (0..parts) |k| {
            e.defs[at][k] = try sinCos(c, try getSrc(e, each.a, k), each.tag == .cos);
        },
        // fsign (nir_to_vir.c:1788): ntq_fsign.
        .sign => for (0..parts) |k| {
            e.defs[at][k] = try sign(c, try getSrc(e, each.a, k));
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
            e.defs[at][k] = try c.add(op, .{try getSrc(e, each.a, k)});
        },
        // fdot lowered for a device of no FMA: the products the last
        // float first, each summed onto those before it (lower_reduction,
        // nir_lower_alu_width.c:96-127, reversed as lower_fdot has it where
        // the sum need not be exact, :161-173).
        .dot => {
            const n = e.work.steps[each.a].kind.parts();
            var last: Reg = undefined;
            for (0..n) |i| {
                const channel = n - 1 - i;
                const product = try c.mul(.fmul, .{ try getSrc(e, each.a, channel), try getSrc(e, each.b, channel) });
                last = if (i == 0) product else try c.add(.fadd, .{ last, product });
            }
            e.defs[at][0] = last;
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
                    e.defs[at][k] = try c.add(.ftoin, .{try getSrc(e, e.work.steps[each.a].a, k)});
                    continue;
                }
                const a = try getSrc(e, each.a, k);
                const b = if (op.unary()) c.undef else try getSrc(e, each.b, if (b_scalar) 0 else k);
                e.defs[at][k] = switch (op) {
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
                };
            }
        },
        // slt (nir_to_vir.c:1710-1723): the comparison, and 1.0 or 0.0 of
        // the flags, which are remembered as holding it (since 1.153).
        .set_less => {
            const cond = try emitComparison(e, .{ .tag = .compare, .kind = .f32x1, .a = each.a, .b = each.b, .at = @intFromEnum(Comparison.less) });
            const result = try c.mul(.mov, .{try c.sel(cond, try c.uniformF(1.0), try c.uniformF(0.0))});
            c.flags_temp = @intCast(result.index);
            c.flags_cond = cond;
            e.defs[at][0] = result;
        },
        // b32csel (nir_to_vir.c:1740-1745): the sources, then the bool as
        // a condition, the flags where they still hold it, and SEL
        // (since 1.153).
        .select => {
            _ = try getSrc(e, each.a, 0);
            const yes = try getSrc(e, each.b, 0);
            const no = try getSrc(e, each.from[0], 0);
            const cond = try boolToCond(e, each.a);
            e.defs[at][0] = try c.mul(.mov, .{try c.sel(cond, yes, no)});
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
            for (0..parts) |k| e.defs[at][k] = try c.uniform(.uniform, @intCast(each.at + k));
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
            try emitLoadUnifa(e, each, at);
        },
        // store_ssbo, through the TMU (:3645-3649; since 1.168). It
        // makes no value.
        .ssbo_store => return emitTmuGeneral(e, each, at),
    }
    e.defined[at] = true;
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
        e.defs[at][i] = try c.mul(.mov, .{data});
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
/// step is one, and the bool tested against 0 where it is not.
fn boolToCond(e: *Emit, step: u16) Error!instr.Cond {
    const c = e.c;
    const qsrc = try getSrc(e, step, 0);
    if (qsrc.file == .temp and c.flags_temp == @as(i32, @intCast(qsrc.index))) return c.flags_cond;
    if (e.work.steps[step].tag == .compare) return emitComparison(e, e.work.steps[step]);
    c.setPf(try c.mulDest(.mov, vir.nopReg(), .{qsrc}), .pushz);
    return .ifna;
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
/// texture at a coordinate of two floats, with an implicit level of
/// detail, its texels in 16-bit floats; a `sample_compared` writes the
/// reference too (since 1.143).
fn emitTex(e: *Emit, each: Step, at: u16) Error!void {
    const c = e.c;
    const compared = each.tag == .sample_compared;
    // P0: the words to hand back; P2, the default, regular lookup.
    const return_words = texel_words;

    // get_required_tex_tmu_writes (v3d_tex.c:222): T and S, and the
    // comparator's TMUDREF. The input FIFO has 16 slots across all
    // threads.
    const tmu_writes: u32 = if (compared) 3 else 2;
    while (tmu_writes > 16 / @as(u32, c.threads)) c.threads /= 2;

    // Pipelining it would overflow the TMU's FIFOs: flush what waits.
    const dest_components = @popCount(return_words);
    if (tmuFifoOverflow(e, dest_components)) try flushTmu(e);

    // handle_tex_src (v3d_tex.c:85): S starts the lookup, so it is kept
    // for the end, and T is written first.
    const s = try getSrc(e, each.a, 0);
    _ = try tmuWrite(c, .tmut, try getSrc(e, each.a, 1));
    // The comparator after the coordinate, as NIR's sources come
    // (v3d_tex.c:155-157).
    if (compared) _ = try tmuWrite(c, .tmudref, try getSrc(e, each.b, 0));

    // The texture's number in the high bits of the address, for the
    // driver to put the texture's state there.
    const p0_packed = return_words | texture_index << 24;
    try wrtmuc(c, .tmu_config_p0, p0_packed);

    // P1 is needed: a sample needs a sampler (v3d_tex.c:311-321). Its
    // output 16-bit, the coordinates normalized, and the per-pixel mask
    // on where the sample skips its helper pixels or the program is not
    // a fragment program's (since 1.167): that bit alone, and the
    // sampler's number above it. P2 is the default, so neither it nor
    // the P1 a P2 would need is written.
    const p1_packed: u32 = if (c.stage != .fragment or e.work.skip_helpers[at]) compile.per_pixel_mask else 0;
    try wrtmuc(c, .tmu_config_p1, p1_packed | sampler_index << 24);

    const retiring = try tmuWrite(c, .tmus, s);
    // Mesa's own count, which is the mask of the words rather than how
    // many: the scheduler only holds a lookup back for it.
    retiring.ldtmu_count = return_words;
    try addPendingTmuFlush(e, at, return_words);
}

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
    const is_store = each.tag == .ssbo_store;
    if (is_store) c.tmu_dirty_rcl = true;
    // The offset's step where it is computed, and else the constant one.
    const offset_src: u16 = switch (each.tag) {
        .ubo_indirect, .ssbo_indirect => each.a,
        .ssbo_store => each.from[0],
        else => compile.none,
    };
    const dynamic_src = offset_src != compile.none;
    const const_offset: u32 = if (dynamic_src) 0 else each.at;
    const base_offset = if (each.tag == .ubo_indirect)
        try c.uniform(.ubo_addr, vir.unitDataCreate(@as(u32, each.b) + 1, 0))
    else
        try c.uniform(.ssbo_offset, each.b);

    const parts: u32 = @intCast(each.kind.parts());
    const dest_components: u32 = if (is_store) 0 else parts;
    var tmu_writes: u32 = 0;
    if (is_store) for (0..parts) |k| {
        _ = try getSrc(e, each.a, k);
        tmu_writes += 1;
    };
    tmu_writes += 1;
    if (dynamic_src) _ = try getSrc(e, offset_src, 0);
    while (tmu_writes > 16 / @as(u32, c.threads)) c.threads /= 2;
    if (tmuFifoOverflow(e, dest_components)) try flushTmu(e);

    if (is_store) for (0..parts) |k| {
        _ = try c.mulDest(.mov, vir.magicReg(.tmud), .{try getSrc(e, each.a, k)});
    };
    const num_components = if (is_store) tmu_writes - 1 else parts;
    const perquad = if (!is_store and c.stage == .fragment and !e.work.skip_helpers[at])
        general_tmu_lookup_per_quad
    else
        general_tmu_lookup_per_pixel;
    var config: u32 = 0xffffff00 | tmu_op_regular << 3 | perquad;
    config |= if (num_components == 1)
        general_tmu_lookup_type_32bit_ui
    else
        general_tmu_lookup_type_vec2 + num_components - 2;

    const tmua = vir.magicReg(if (config == ~@as(u32, 0)) .tmua else .tmuau);
    const tmu = if (dynamic_src)
        try c.addDest(.add, tmua, .{ base_offset, try getSrc(e, offset_src, 0) })
    else if (const_offset != 0)
        try c.addDest(.add, tmua, .{ base_offset, try c.uniformUi(const_offset) })
    else
        try c.mulDest(.mov, tmua, .{base_offset});
    if (config != ~@as(u32, 0)) tmu.uniform = try c.getUniformIndex(.constant, config);
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
                .ubo, .ubo_indirect, .ssbo, .ssbo_indirect => true,
                else => false,
            };
            for (0..4) |j| {
                if (pending.component_mask & @as(u32, 1) << @intCast(j) != 0) {
                    const word = try c.mul(.mov, .{try c.ldtmu()});
                    if (general) e.defs[pending.step][j] = word else e.words[pending.step][j] = word;
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
