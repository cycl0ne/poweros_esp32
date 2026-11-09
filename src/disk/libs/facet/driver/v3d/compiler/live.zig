// SPDX-License-Identifier: MIT
//! Where each temporary is live: the port of Mesa's
//! src/broadcom/compiler/vir_live_variables.c, its 7.1 paths. Each
//! temporary is given the first and the last instruction it is live at,
//! over the whole program, which the register allocator builds its
//! interference from.
//!
//! Each block is first looked at alone: what it defines whole before
//! reading it (def), what it reads before defining it (use), and what it
//! defines even in part (defout). Then two fixed points are found over
//! the blocks: what is live where each block starts and ends, from the
//! successors back; and which blocks a definition, even a partial one,
//! reaches, from the predecessors on. A temporary's range then grows to
//! the start of a block it is live into and defined before, and to the
//! end of one it is live out of and defined in, so that a value written
//! in part or under a condition, first, does not stay live back to the
//! program's start.

const std = @import("std");
const vir = @import("vir.zig");
const Compile = vir.Compile;
const Block = vir.Block;
const Inst = vir.Inst;
const Reg = vir.Reg;
const Error = vir.Error;

/// No instruction is at or past it (MAX_INSTRUCTION,
/// vir_live_variables.c:25): a range not yet begun starts here.
const max_instruction: i32 = 1 << 30;

/// The conditional or partial writes of a temporary in a block (struct
/// partial_update_state, vir_live_variables.c:32).
const PartialUpdateState = struct {
    /// The instruction that writes it under a condition, or in part.
    inst: ?*Inst = null,
    /// The one that set the flags that condition reads.
    flags_inst: ?*Inst = null,
    /// It was written whole in its low half, and in its high half, without
    /// a condition: both make it defined whole.
    has_pack_l: bool = false,
    has_pack_h: bool = false,
};

/// Which halves of a temporary any instruction reads
/// (vir_live_variables.c:49-51): a read of all 32 bits reads both.
const temp_read_lo: u8 = 1 << 0;
const temp_read_hi: u8 = 1 << 1;
const temp_read_full: u8 = temp_read_lo | temp_read_hi;

/// The temporary a register is, or null for any other register
/// (vir_reg_to_var, vir_live_variables.c:54).
fn regToVar(r: Reg) ?u32 {
    if (r.file == .temp) return r.index;
    return null;
}

/// Which halves of each temporary the program reads, so that a write of
/// one half is a whole definition where the other is never read
/// (vir_compute_temp_read_flags, vir_live_variables.c:69).
fn computeTempReadFlags(c: *Compile) Error![]u8 {
    const flags = try c.allocator.alloc(u8, c.num_temps);
    @memset(flags, 0);
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        var insts = vir.eachInst(block);
        while (insts.next()) |inst| {
            const nsrc = vir.getNsrc(inst);
            for (0..nsrc) |i| {
                if (inst.src[i].file != .temp) continue;
                const variable = inst.src[i].index;
                switch (vir.getUnpack(inst, i)) {
                    .l => flags[variable] |= temp_read_lo,
                    .h => flags[variable] |= temp_read_hi,
                    else => flags[variable] |= temp_read_full,
                }
            }
        }
    }
    return flags;
}

fn widen(c: *Compile, variable: u32, ip: i32) void {
    c.temp_start[variable] = @min(c.temp_start[variable], ip);
    c.temp_end[variable] = @max(c.temp_end[variable], ip);
}

/// A read of `src` at `ip` (vir_setup_use, vir_live_variables.c:103):
/// noted in the block's `use` where the block has not defined it whole
/// before, unless it reads under the very condition, from the very
/// flags, that an earlier write in the block wrote it under.
fn setupUse(c: *Compile, block: *Block, ip: i32, partial_update: []PartialUpdateState, inst: *Inst, src: Reg, flags_inst: ?*Inst) void {
    const variable = regToVar(src) orelse return;
    widen(c, variable, ip);

    if (!vir.bitsetTest(block.def, variable)) {
        if (vir.bitsetTest(block.defout, variable)) {
            const state = &partial_update[variable];
            if (state.inst) |written| {
                if (vir.getCond(inst) == vir.getCond(written) and flags_inst == state.flags_inst) return;
            }
        }
        vir.bitsetSet(block.use, variable);
    }
}

/// A write at `ip` (vir_setup_def, vir_live_variables.c:144): noted in
/// `defout`, and in `def` where it defines the temporary whole before the
/// block reads it. A write without a condition and without packing does;
/// so do one of each half, and one of a half where the other half is
/// never read.
fn setupDef(c: *Compile, block: *Block, ip: i32, partial_update: []PartialUpdateState, temp_read_flags: []const u8, inst: *Inst, flags_inst: ?*Inst) void {
    if (inst.qpu.kind != .alu) return;
    const variable = regToVar(inst.dst) orelse return;
    widen(c, variable, ip);

    vir.bitsetSet(block.defout, variable);

    // Already a def that hides what came before, or read in the block
    // first: nothing more to know.
    if (vir.bitsetTest(block.use, variable) or vir.bitsetTest(block.def, variable)) return;

    const is_unconditional = inst.qpu.flags.ac == .none and inst.qpu.flags.mc == .none;

    if (is_unconditional and inst.qpu.alu.add.output_pack == .none and inst.qpu.alu.mul.output_pack == .none) {
        vir.bitsetSet(block.def, variable);
        return;
    }

    const state = &partial_update[variable];
    if (is_unconditional) {
        const pack = vir.getPack(inst);
        if (pack == .l) state.has_pack_l = true;
        if (pack == .h) state.has_pack_h = true;

        // Both halves written in the block.
        if (state.has_pack_l and state.has_pack_h) {
            vir.bitsetSet(block.def, variable);
            return;
        }

        // The half written is all that is read: a read of all 32 bits
        // reads both halves.
        const rflags = temp_read_flags[variable];
        const needs_hi = rflags & temp_read_hi != 0;
        const needs_lo = rflags & temp_read_lo != 0;
        if (pack == .l and !needs_hi) {
            vir.bitsetSet(block.def, variable);
            return;
        }
        if (pack == .h and !needs_lo) {
            vir.bitsetSet(block.def, variable);
            return;
        }
    }

    // A conditional write, for setupUse to match a read against.
    if (inst.qpu.flags.ac != .none or inst.qpu.flags.mc != .none) {
        state.inst = inst;
        state.flags_inst = flags_inst;
    }
}

/// Each block's def, use and defout, its instructions' places in the
/// program, and each temporary's range over the instructions that name
/// it (vir_setup_def_use, vir_live_variables.c:252).
fn setupDefUse(c: *Compile) Error!void {
    const partial_update = try c.allocator.alloc(PartialUpdateState, c.num_temps);
    defer c.allocator.free(partial_update);
    const temp_read_flags = try computeTempReadFlags(c);
    defer c.allocator.free(temp_read_flags);

    var ip: i32 = 0;
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        block.start_ip = ip;
        @memset(partial_update, .{});
        var flags_inst: ?*Inst = null;

        var insts = vir.eachInst(block);
        while (insts.next()) |inst| {
            for (0..vir.getNsrc(inst)) |i| setupUse(c, block, ip, partial_update, inst, inst.src[i], flags_inst);
            setupDef(c, block, ip, partial_update, temp_read_flags, inst, flags_inst);

            if (inst.qpu.flags.apf != .none or inst.qpu.flags.mpf != .none) flags_inst = inst;
            if (inst.qpu.flags.auf != .none or inst.qpu.flags.muf != .none) flags_inst = null;

            payload(c, inst);
            ip += 1;
        }
        block.end_ip = ip;
    }
}

/// The payload's registers - on 7.1 a fragment program's W, centroid W
/// and Z in rf1 to rf3, a compute program's in rf2 and rf3 - are moved
/// into temporaries, which the register allocator puts in those very
/// registers: live from the program's start (vir_live_variables.c:292-
/// 310, 524-532). The destination is the temporary moved into, as nir_to_vir
/// emits each such move.
fn payload(c: *Compile, inst: *const Inst) void {
    if (inst.src[0].file == .reg) {
        const min_payload_r = 1;
        const max_payload_r = 3;
        if (inst.src[0].index >= min_payload_r and inst.src[0].index <= max_payload_r) {
            c.temp_start[inst.dst.index] = 0;
        }
    }
}

/// One round of what is live into and out of each block, the blocks
/// walked from the last (vir_live_variables_dataflow,
/// vir_live_variables.c:321): whether anything changed.
fn dataflow(c: *Compile, bitset_words: usize) bool {
    var cont = false;
    var blocks = c.eachBlockRev();
    while (blocks.next()) |block| {
        // Live out of it: whatever a successor has live in.
        var successors = vir.eachSuccessor(block);
        while (successors.next()) |succ| {
            for (0..bitset_words) |i| {
                const new_live_out = succ.live_in[i] & ~block.live_out[i];
                if (new_live_out != 0) {
                    block.live_out[i] |= new_live_out;
                    cont = true;
                }
            }
        }
        // Live into it: what it reads first, and what is live out of it
        // that it does not define whole.
        for (0..bitset_words) |i| {
            const new_live_in = block.use[i] | (block.live_out[i] & ~block.def[i]);
            if (new_live_in & ~block.live_in[i] != 0) {
                block.live_in[i] |= new_live_in;
                cont = true;
            }
        }
    }
    return cont;
}

/// One round of which blocks a definition reaches, even a partial one,
/// carried on to the successors (vir_live_variables_defin_defout_dataflow,
/// vir_live_variables.c:357): so that a conditional first write does not
/// make a temporary live back to the start of the program.
fn definDefoutDataflow(c: *Compile, bitset_words: usize) bool {
    var cont = false;
    var blocks = c.eachBlockRev();
    while (blocks.next()) |block| {
        var successors = vir.eachSuccessor(block);
        while (successors.next()) |succ| {
            for (0..bitset_words) |i| {
                const new_def = block.defout[i] & ~succ.defin[i];
                succ.defin[i] |= new_def;
                succ.defout[i] |= new_def;
                cont = cont or new_def != 0;
            }
        }
    }
    return cont;
}

/// Each range of the first `num_vars` temporaries grown to the start of a
/// block it is live into and defined before, and to the end of one it is
/// live out of and defined in (vir_compute_start_end,
/// vir_live_variables.c:388). A temporary with no range is not used.
fn computeStartEnd(c: *Compile, num_vars: u32) void {
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        for (0..num_vars) |i| {
            if (c.temp_end[i] == -1) continue;
            const variable: u32 = @intCast(i);
            if (vir.bitsetTest(block.live_in, i) and vir.bitsetTest(block.defin, i)) widen(c, variable, block.start_ip);
            if (vir.bitsetTest(block.live_out, i) and vir.bitsetTest(block.defout, i)) widen(c, variable, block.end_ip);
        }
    }
}

/// spill_base, defined once at the program's entry, kept live from the
/// start and over every path back from a block that reads it, through a
/// loop's back edge too (vir_extend_spill_base_live_interval,
/// vir_live_variables.c:427).
fn extendSpillBaseLiveInterval(c: *Compile, sb_temp: u32) Error!void {
    const live_in = try c.allocator.alloc(bool, c.next_block_index);
    defer c.allocator.free(live_in);
    @memset(live_in, false);
    const worklist = try c.allocator.alloc(*Block, c.next_block_index);
    defer c.allocator.free(worklist);
    var count: usize = 0;
    const entry = c.entryBlock();

    c.temp_start[sb_temp] = 0;

    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        if (block == entry) continue;
        var insts = vir.eachInst(block);
        while (insts.next()) |inst| {
            for (0..vir.getNsrc(inst)) |s| {
                if (inst.src[s].file == .temp and inst.src[s].index == sb_temp) {
                    live_in[block.index] = true;
                    break;
                }
            }
            if (live_in[block.index]) {
                worklist[count] = block;
                count += 1;
                break;
            }
        }
    }

    while (count > 0) {
        count -= 1;
        const block = worklist[count];
        for (block.predecessors.items) |pred| {
            c.temp_end[sb_temp] = @max(c.temp_end[sb_temp], pred.end_ip);
            if (pred != entry and !live_in[pred.index]) {
                live_in[pred.index] = true;
                worklist[count] = pred;
                count += 1;
            }
        }
    }
}

/// The ranges made again after the register allocator spilled, the
/// blocks' liveness kept: spilling moves no temporary to another block,
/// so what is live into and out of each block still holds for the
/// temporaries there were, `num_temps_before_spills` of them; the
/// instructions' places, and every range, are found again
/// (vir_update_live_intervals_after_spill, vir_live_variables.c:491).
pub fn updateLiveIntervalsAfterSpill(c: *Compile, num_temps_before_spills: u32) Error!void {
    c.temp_start = try c.allocator.realloc(c.temp_start, c.num_temps);
    c.temp_end = try c.allocator.realloc(c.temp_end, c.num_temps);
    @memset(c.temp_start, max_instruction);
    @memset(c.temp_end, -1);

    var ip: i32 = 0;
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        block.start_ip = ip;
        var insts = vir.eachInst(block);
        while (insts.next()) |inst| {
            inst.ip = ip;
            for (0..vir.getNsrc(inst)) |s| {
                if (inst.src[s].file != .temp) continue;
                widen(c, inst.src[s].index, ip);
            }
            if (inst.qpu.kind == .alu and inst.dst.file == .temp) widen(c, inst.dst.index, ip);
            payload(c, inst);
            ip += 1;
        }
        block.end_ip = ip;
    }

    // Grown over the blocks as their liveness says.
    computeStartEnd(c, num_temps_before_spills);

    // Made again, spill_base's range is spill_base's own, whether or not
    // this spill added to it.
    if (c.spill_base.file == .temp) try extendSpillBaseLiveInterval(c, c.spill_base.index);

    c.live_intervals_valid = true;
}

/// Each temporary's live range, and each block's liveness
/// (vir_calculate_live_intervals, vir_live_variables.c:552). It may be
/// called again, once the program is changed to be allocated.
pub fn calculateLiveIntervals(c: *Compile) Error!void {
    const bitset_words = vir.bitsetWords(c.num_temps);

    c.allocator.free(c.temp_start);
    c.allocator.free(c.temp_end);
    c.temp_start = &.{};
    c.temp_end = &.{};
    var blocks = c.eachBlock();
    while (blocks.next()) |block| vir.freeLiveness(c.allocator, block);

    c.temp_start = try c.allocator.alloc(i32, c.num_temps);
    c.temp_end = try c.allocator.alloc(i32, c.num_temps);
    @memset(c.temp_start, max_instruction);
    @memset(c.temp_end, -1);

    blocks = c.eachBlock();
    while (blocks.next()) |block| {
        inline for (.{ "def", "defin", "defout", "use", "live_in", "live_out" }) |field| {
            const words = try c.allocator.alloc(u32, bitset_words);
            @memset(words, 0);
            @field(block, field) = words;
        }
    }

    try setupDefUse(c);

    while (dataflow(c, bitset_words)) {}
    while (definDefoutDataflow(c, bitset_words)) {}

    computeStartEnd(c, c.num_temps);

    c.live_intervals_valid = true;
}
