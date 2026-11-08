// SPDX-License-Identifier: MIT
//! A compile's VIR, its temporaries given registers, made into the QPU's
//! instructions and packed into the words the QPU runs: the port of
//! Mesa's src/broadcom/compiler/vir_to_qpu.c, its 7.1 paths. Mesa does
//! it in one call, v3d_vir_to_qpu, which schedules the instructions
//! between its two halves; until qpu_schedule.c is ported the halves are
//! `generateCode` and `packCode`, called in turn.
//!
//! On 7.1 an operand is a register of the register file or a small
//! immediate, which VIR keeps in raddr_b until it is placed in the
//! operand that reads it; there are no accumulators and no muxes.

const std = @import("std");
const assert = std.debug.assert;
const instr = @import("../qpu/instr.zig");
const pack = @import("../qpu/pack.zig");
const disasm = @import("../qpu/disasm.zig");
const validator = @import("validate.zig");
const vir = @import("vir.zig");
const dump = @import("dump.zig");
const Compile = vir.Compile;
const Inst = vir.Inst;
const Block = vir.Block;
const QpuReg = vir.QpuReg;
const Instr = instr.Instr;

/// qpu_reg (vir_to_qpu.c:29).
fn qpuReg(index: u6) QpuReg {
    return .{ .index = index };
}

/// qpu_magic (vir_to_qpu.c:39).
fn qpuMagic(waddr: u6) QpuReg {
    return .{ .magic = true, .index = waddr };
}

/// An operand placed in the instruction (v3d71_set_src, vir_to_qpu.c:90):
/// a register as itself, and a small immediate moved from raddr_b, where
/// VIR keeps it, to the operand that reads it.
fn setSrc(qpu: *Instr, raddr: *u6, src: QpuReg) void {
    if (src.smimm) {
        assert(qpu.sig.small_imm_a or qpu.sig.small_imm_b or qpu.sig.small_imm_c or qpu.sig.small_imm_d);
        raddr.* = qpu.raddr_b;
        return;
    }
    assert(!src.magic);
    raddr.* = src.index;
}

/// The mul side moves a register to itself (v3d71_mov_src_and_dst_equal,
/// vir_to_qpu.c:199).
fn movSrcAndDstEqual(inst: *const Inst) bool {
    if (inst.qpu.alu.mul.magic_write) return false;
    return inst.qpu.alu.mul.a.raddr == inst.qpu.alu.mul.waddr;
}

/// A lone move of a register to itself, with nothing else to do: no
/// signal, no packing, no condition, no flags (is_no_op_mov,
/// vir_to_qpu.c:226). Only the mul side's mov is looked for: 7.x's add
/// side mov is never emitted.
fn isNoOpMov(inst: *const Inst) bool {
    const qpu = &inst.qpu;
    if (qpu.kind != .alu or qpu.alu.mul.op != .mov or qpu.alu.add.op != .nop or !qpu.sig.eql(.{})) return false;
    if (!movSrcAndDstEqual(inst)) return false;
    if (qpu.alu.mul.a.unpack != .none or qpu.alu.mul.output_pack != .none or
        qpu.flags.mc != .none or qpu.flags.mpf != .none or qpu.flags.muf != .none) return false;
    return true;
}

/// Each instruction of `block` given the registers its destination and
/// operands have, and the uniforms counted; a move left with nothing to
/// do is removed (v3d_generate_code_block, vir_to_qpu.c:261).
fn generateCodeBlock(c: *Compile, block: *Block, temp_registers: []const QpuReg) void {
    var insts = vir.eachInstSafe(block);
    while (insts.next()) |qinst| {
        if (vir.hasUniform(qinst)) c.num_uniforms += 1;

        const nsrc = vir.getNsrc(qinst);
        var src: [3]QpuReg = .{ .{}, .{}, .{} };
        for (0..nsrc) |i| {
            const index = qinst.src[i].index;
            src[i] = switch (qinst.src[i].file) {
                .reg => qpuReg(@intCast(index)),
                .magic => qpuMagic(@intCast(index)),
                // An undefined operand may read anything: rf5, which has
                // no scheduling restrictions.
                .null => qpuReg(5),
                .load_imm => unreachable,
                .temp => temp_registers[index],
                .small_imm => .{ .smimm = true },
            };
        }

        const dst: QpuReg = switch (qinst.dst.file) {
            .null => qpuMagic(instr.magic(.nop)),
            .reg => qpuReg(@intCast(qinst.dst.index)),
            .magic => qpuMagic(@intCast(qinst.dst.index)),
            .temp => temp_registers[qinst.dst.index],
            .small_imm, .load_imm => unreachable,
        };

        const qpu = &qinst.qpu;
        if (qpu.kind == .branch) continue;
        if (qpu.sig.ldunif or qpu.sig.ldunifa) {
            assert(qpu.alu.add.op == .nop);
            assert(qpu.alu.mul.op == .nop);
            // ldunif writes rf0 by itself; anywhere else takes the form
            // that names its register.
            const use_rf = dst.magic or dst.index != 0;
            if (use_rf) {
                if (qpu.sig.ldunif) {
                    qpu.sig.ldunif = false;
                    qpu.sig.ldunifrf = true;
                } else {
                    qpu.sig.ldunifa = false;
                    qpu.sig.ldunifarf = true;
                }
                qpu.sig_addr = dst.index;
                qpu.sig_magic = dst.magic;
            }
        } else if (instr.sigWritesAddress(qpu.sig)) {
            assert(qpu.alu.add.op == .nop);
            assert(qpu.alu.mul.op == .nop);
            qpu.sig_addr = dst.index;
            qpu.sig_magic = dst.magic;
        } else if (qpu.alu.add.op != .nop) {
            assert(qpu.alu.mul.op == .nop);
            if (nsrc >= 1) setSrc(qpu, &qpu.alu.add.a.raddr, src[0]);
            if (nsrc >= 2) setSrc(qpu, &qpu.alu.add.b.raddr, src[1]);
            qpu.alu.add.waddr = dst.index;
            qpu.alu.add.magic_write = dst.magic;
        } else {
            if (nsrc >= 1) setSrc(qpu, &qpu.alu.mul.a.raddr, src[0]);
            if (nsrc >= 2) setSrc(qpu, &qpu.alu.mul.b.raddr, src[1]);
            qpu.alu.mul.waddr = dst.index;
            qpu.alu.mul.magic_write = dst.magic;
            if (isNoOpMov(qinst)) {
                c.removeInstruction(qinst);
                continue;
            }
        }
    }
}

/// The first half of v3d_vir_to_qpu (vir_to_qpu.c:470): every block's
/// instructions given registers, `temp_registers` holding each
/// temporary's, and the uniforms counted again as the program will load
/// them. The scheduler follows it.
pub fn generateCode(c: *Compile, temp_registers: []const QpuReg) void {
    c.num_uniforms = 0;
    var blocks = c.eachBlock();
    while (blocks.next()) |block| generateCodeBlock(c, block, temp_registers);
}

/// The QPU instruction reads a uniform (reads_uniform, vir_to_qpu.c:406).
pub fn readsUniform(instruction: u64) bool {
    const qpu = pack.unpack(instruction).?;
    if (qpu.sig.ldunif or qpu.sig.ldunifrf or qpu.sig.ldtlbu or qpu.sig.wrtmuc) return true;
    if (qpu.kind == .branch) return true;
    if (qpu.alu.add.magic_write and instr.magicWaddrLoadsUnif(qpu.alu.add.waddr)) return true;
    if (qpu.alu.mul.magic_write and instr.magicWaddrLoadsUnif(qpu.alu.mul.waddr)) return true;
    return false;
}

/// The packed program a line each, the word, its text, and the uniform it
/// reads (v3d_dump_qpu, vir_to_qpu.c:438): the lines without the one
/// that names the stage and the program, which the compile keeps none of
/// yet.
pub fn dumpQpu(w: *std.Io.Writer, c: *const Compile) std.Io.Writer.Error!void {
    var next_uniform: u32 = 0;
    for (c.qpu_insts[0..c.qpu_inst_count]) |word| {
        var text: [disasm.most_text]u8 = undefined;
        try w.print("0x{x:0>16} {s}", .{ word, disasm.disasm(word, &text).? });
        if (readsUniform(word)) {
            try w.writeAll(" (");
            try dump.uniform(w, c.uniform_contents[next_uniform], c.uniform_data[next_uniform]);
            try w.writeAll(")");
            next_uniform += 1;
        }
        try w.writeAll("\n");
    }
    // The uniforms the words read are the ones the compile counted.
    assert(next_uniform == c.num_uniforms);
    try w.writeAll("\n");
}

/// The second half of v3d_vir_to_qpu (vir_to_qpu.c:483-507): the
/// scheduled program's `qpu_inst_count` instructions packed, in order,
/// into `qpu_insts`, its nops counted, and the program held to the
/// instruction restrictions (qpu_validate). Mesa marks the compile
/// failed where an instruction does not pack, and aborts where a rule is
/// broken, in debug builds alone; here both mark it failed, and where
/// and why is answered.
pub fn packCode(c: *Compile) vir.Error!?validator.Failure {
    c.allocator.free(c.qpu_insts);
    c.qpu_insts = &.{};
    c.qpu_insts = try c.allocator.alloc(u64, c.qpu_inst_count);
    @memset(c.qpu_insts, 0);
    const insts = try c.allocator.alloc(Instr, c.qpu_inst_count);
    defer c.allocator.free(insts);

    var first_tlb_z_write: ?usize = null;
    var i: usize = 0;
    var each = c.eachInstInorder();
    while (each.next()) |inst| {
        const word = pack.pack(&inst.qpu) orelse {
            c.compilation_result = .failed;
            return .{ .ip = i, .message = "Failed to pack instruction" };
        };
        c.qpu_insts[i] = word;
        insts[i] = inst.qpu;
        if (inst.is_tlb_z_write and first_tlb_z_write == null) first_tlb_z_write = i;
        i += 1;
        if (instr.isNop(&inst.qpu)) c.nop_count += 1;
    }
    assert(i == c.qpu_inst_count);

    const program: validator.Program = .{
        .insts = insts,
        .first_tlb_z_write = first_tlb_z_write,
        .last_thrsw = c.last_thrsw != null,
    };
    if (validator.validate(program)) |failure| {
        c.compilation_result = .failed;
        return failure;
    }
    return null;
}
