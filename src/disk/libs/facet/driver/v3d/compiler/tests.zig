// SPDX-License-Identifier: MIT
//! The tests of the VIR layer (vir.zig, dump.zig, to_qpu.zig): what Mesa's
//! VIR is built into, prints as, and becomes once its temporaries have
//! registers. The text is what Mesa's vir_dump and the QPU disassembler
//! print, the disassembler's own having been held to Mesa's tests in
//! qpu/tests.zig.

const std = @import("std");
const testing = std.testing;
const instr = @import("../qpu/instr.zig");
const pack = @import("../qpu/pack.zig");
const disasm = @import("../qpu/disasm.zig");
const vir = @import("vir.zig");
const dump = @import("dump.zig");
const to_qpu = @import("to_qpu.zig");
const live = @import("live.zig");
const Compile = vir.Compile;
const Inst = vir.Inst;
const Reg = vir.Reg;

fn expectInst(c: *const Compile, inst: *const Inst, expected: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try dump.inst(&w, c, inst);
    try testing.expectEqualStrings(expected, w.buffered());
}

fn defOf(c: *const Compile, r: Reg) *Inst {
    return c.defs[r.index].?;
}

fn expectOrder(block: *vir.Block, expected: []const *Inst) !void {
    var insts = vir.eachInst(block);
    for (expected) |inst| try testing.expectEqual(inst, insts.next().?);
    try testing.expectEqual(@as(?*Inst, null), insts.next());
}

test "VIR prints as Mesa's vir_dump prints it" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();

    const one = try c.uniformF(1.0);
    try expectInst(c, defOf(c, one), "nop t0; ldunif (0x3f800000 / 1.000000)");
    const half = try c.uniformF(0.5);
    try expectInst(c, defOf(c, half), "nop t1; ldunif (0x3f000000 / 0.500000)");
    const sum = try c.add(.fadd, .{ one, half });
    try expectInst(c, defOf(c, sum), "fadd t2, t0, t1");
    const product = try c.mul(.fmul, .{ sum, one });
    try expectInst(c, defOf(c, product), "fmul t3, t2, t0");

    // A comparison into the flags, and a move under them.
    const compare = try c.addDest(.fcmp, vir.nopReg(), .{ product, half });
    c.setPf(compare, .pushc);
    try expectInst(c, compare, "fcmp.pushc null, t3, t1");
    try expectInst(c, try c.movCond(.ifa, sum, product), "mov.ifa t2, t3");

    // A result packed and an operand unpacked.
    const low = try c.addDest(.fadd, vir.reg(.reg, 3), .{ one, half });
    vir.setPack(low, .l);
    vir.setUnpack(low, 1, .h);
    try expectInst(c, low, "fadd rf3.l, t0, t1.h");
    try testing.expectEqual(instr.InputUnpack.h, vir.getUnpack(low, 1));
    try testing.expectEqual(instr.OutputPack.l, vir.getPack(low));

    // The TMU written and read, and the tile buffer read.
    try expectInst(c, try c.mulDest(.mov, vir.magicReg(.tmud), .{product}), "mov tmud, t3");
    try expectInst(c, try c.mulDest(.mov, vir.magicReg(.tmua), .{one}), "mov tmua, t0");
    try expectInst(c, defOf(c, try c.ldtmu()), "nop t4; ldtmu.rf0");
    try expectInst(c, defOf(c, try c.tlbRead()), "nop t5; ldtlb.rf0");
    try expectInst(c, defOf(c, try c.tlbuRead(0xffffff3f)), "nop t6; ldtlbu.rf0 (0xffffff3f / -nan)");
    // A magic address with no name, as glibc prints a null string.
    try expectInst(c, try c.mulDest(.mov, vir.reg(.magic, 30), .{one}), "mov (null), t0");

    // Small immediates, printed by Mesa as their packed index says: 0 to
    // 15 as integers, the rest as floats, -1 at 31 among them.
    const t7 = try c.getTemp();
    const three = try c.addDest(.add, t7, .{ one, vir.reg(.small_imm, 3) });
    three.qpu.raddr_b = pack.smallImmPack(3).?;
    three.qpu.sig.small_imm_b = true;
    try expectInst(c, three, "add t7, t0, 3");
    const halved = try c.mulDest(.fmul, t7, .{ one, vir.reg(.small_imm, 0x3f000000) });
    halved.qpu.raddr_b = pack.smallImmPack(0x3f000000).?;
    halved.qpu.sig.small_imm_d = true;
    try expectInst(c, halved, "fmul t7, t0, 0.500000");
    const less = try c.addDest(.add, t7, .{ one, vir.reg(.small_imm, 0xffffffff) });
    less.qpu.raddr_b = pack.smallImmPack(0xffffffff).?;
    less.qpu.sig.small_imm_b = true;
    try expectInst(c, less, "add t7, t0, -nan");

    // Signals, and where they write.
    const varying = try c.nop();
    varying.qpu.sig.ldvary = true;
    try expectInst(c, varying, "nop null; ldvary.rf0");
    const switched = try c.nop();
    switched.qpu.sig.thrsw = true;
    try expectInst(c, switched, "nop null; thrsw");
    const to_unifa = try c.nop();
    to_unifa.qpu.sig.ldunifrf = true;
    to_unifa.qpu.sig_magic = true;
    to_unifa.qpu.sig_addr = instr.magic(.unifa);
    try expectInst(c, to_unifa, "nop null; ldunifrf.unifa");
    to_unifa.qpu.sig_addr = 30;
    try expectInst(c, to_unifa, "nop null; ldunifrf.UNKNOWN30");

    // What else a uniform may hold.
    try expectInst(c, defOf(c, try c.uniform(.uniform, 4)), "nop t8; ldunif (push[4])");
    try expectInst(c, defOf(c, try c.uniform(.tmu_config_p0, vir.unitDataCreate(2, 0x15))), "nop t9; ldunif (tex[2].p0 | 0x15)");
    try expectInst(c, defOf(c, try c.uniform(.ubo_addr, vir.unitDataCreate(1, 16))), "nop t10; ldunif (ubo[1]+0x10)");
    try expectInst(c, defOf(c, try c.uniform(.num_work_groups, 1)), "nop t11; ldunif (num_wg.y)");
    try expectInst(c, defOf(c, try c.uniform(.viewport_x_scale, 0)), "nop t12; ldunif (vp_x_scale)");
    try expectInst(c, defOf(c, try c.uniform(.texture_width, 5)), "nop t13; ldunif (tex[5].width)");
    try expectInst(c, defOf(c, try c.uniform(.blend_constant_r, 7)), "nop t14; ldunif (42 / 0x00000007)");

    // A branch takes the uniform stream along, to a uniform the scheduler
    // fills in.
    try expectInst(c, try c.branch(.anya), "bu.anya  0, r:unif (0x00000000 / 0.000000)");

    // A 32-bit multiply, and a choice of two.
    const wide = try c.umul(one, half);
    try expectInst(c, defOf(c, wide), "umul24 t15, t0, t1");
    const chosen = try c.sel(.ifna, one, half);
    var back = vir.eachInstRev(c.cur_block.?);
    try expectInst(c, back.next().?, "mov.ifna t16, t0");
    try expectInst(c, back.next().?, "mov t16, t1");
    try testing.expectEqual(@as(u32, 16), chosen.index);
    try expectInst(c, back.next().?, "umul24 t15, t0, t1");
    try expectInst(c, back.next().?, "multop null, t0, t1");
}

test "a program prints block by block, with the blocks each goes on to" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const entry = c.cur_block.?;
    const x = try c.uniformF(2.0);
    _ = try c.branch(.a0);
    const then = try c.newBlock();
    const after = try c.newBlock();
    try c.linkBlocks(entry, then);
    try c.linkBlocks(entry, after);
    c.setEmitBlock(then);
    _ = try c.add(.fadd, .{ x, x });
    try c.linkBlocks(then, after);
    c.setEmitBlock(after);
    _ = try c.nop();

    var buffer: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try dump.program(&w, c);
    try testing.expectEqualStrings(
        \\BLOCK 0:
        \\nop t0; ldunif (0x40000000 / 2.000000)
        \\bu.a0  0, r:unif (0x00000000 / 0.000000)
        \\-> BLOCK 1, 2
        \\BLOCK 1:
        \\fadd t1, t0, t0
        \\-> BLOCK 2
        \\BLOCK 2:
        \\nop null
        \\
        \\
    , w.buffered());

    try testing.expectEqual(entry, c.entryBlock());
    try testing.expectEqual(after, c.exitBlock());
    try testing.expectEqualSlices(*vir.Block, &.{ entry, then }, after.predecessors.items);
    var blocks = c.eachBlockRev();
    try testing.expectEqual(after, blocks.next().?);
    try testing.expectEqual(then, blocks.next().?);
    try testing.expectEqual(entry, blocks.next().?);
    try testing.expectEqual(@as(?*vir.Block, null), blocks.next());

    // Both of a block's ways to one block: one predecessor, one successor
    // walked.
    const twice = try c.newBlock();
    const target = try c.newBlock();
    try c.linkBlocks(twice, target);
    try c.linkBlocks(twice, target);
    try testing.expectEqual(@as(usize, 1), target.predecessors.items.len);
    var successors = vir.eachSuccessor(twice);
    try testing.expectEqual(target, successors.next().?);
    try testing.expectEqual(@as(?*vir.Block, null), successors.next());
    successors = vir.eachSuccessor(entry);
    try testing.expectEqual(then, successors.next().?);
    try testing.expectEqual(after, successors.next().?);
    try testing.expectEqual(@as(?*vir.Block, null), successors.next());
}

test "a uniform used again in its block is the ldunif before, as try_opt_ldunif finds it" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();

    const first = try c.uniformF(1.0);
    // The walk back starts at the link before the cursor's, which after an
    // emit is the instruction before the one just emitted: the ldunif
    // just emitted is not found.
    const second = try c.uniformF(1.0);
    try testing.expect(second.index != first.index);
    // One instruction later, the first is.
    try testing.expectEqual(first, try c.uniformF(1.0));
    try testing.expectEqual(@as(u32, 1), c.num_uniforms);

    // Not where the temporary was written since.
    const written = try c.uniformF(2.0);
    _ = try c.mulDest(.mov, written, .{first});
    _ = try c.nop();
    try testing.expect((try c.uniformF(2.0)).index != written.index);

    // Twenty instructions back at most, the one just emitted not counted.
    const far = try c.uniformF(3.0);
    for (0..20) |_| _ = try c.nop();
    try testing.expectEqual(far, try c.uniformF(3.0));
    const too_far = try c.uniformF(4.0);
    for (0..21) |_| _ = try c.nop();
    try testing.expect((try c.uniformF(4.0)).index != too_far.index);

    // Not with the optimization off.
    const near = try c.uniformF(5.0);
    _ = try c.nop();
    c.disable_ldunif_opt = true;
    try testing.expect((try c.uniformF(5.0)).index != near.index);
    c.disable_ldunif_opt = false;

    // Nor from another block: the walk stops at the block's head.
    c.setEmitBlock(try c.newBlock());
    _ = try c.nop();
    _ = try c.nop();
    try testing.expect((try c.uniformF(5.0)).index != near.index);
    try testing.expectEqual(@as(u32, 5), c.num_uniforms);
}

test "temporaries grow as Mesa grows them, each one that may be spilled" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    var last: Reg = undefined;
    for (0..17) |_| last = try c.getTemp();
    try testing.expectEqual(Reg{ .file = .temp, .index = 16 }, last);
    try testing.expectEqual(@as(usize, 32), c.defs.len);
    for (17..33) |_| _ = try c.getTemp();
    try testing.expectEqual(@as(usize, 64), c.defs.len);
    try testing.expectEqual(@as(usize, 2), c.spillable.len);
    for (0..64) |t| {
        try testing.expect(vir.bitsetTest(c.spillable, t));
        try testing.expectEqual(@as(?*Inst, null), c.defs[t]);
    }
    vir.bitsetClear(c.spillable, 40);
    try testing.expect(!vir.bitsetTest(c.spillable, 40));
    try testing.expect(vir.bitsetTest(c.spillable, 41));
}

test "a cursor puts an instruction before or after an instruction or a block's head" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const block = c.cur_block.?;
    const middle = try c.nop();
    c.cursor = vir.beforeBlock(block);
    const first = try c.nop();
    c.cursor = vir.afterBlock(block);
    const last = try c.nop();
    c.cursor = vir.beforeInst(middle);
    const second = try c.nop();
    c.cursor = vir.afterInst(middle);
    const third = try c.nop();
    // An emit leaves the cursor after what it emitted.
    const fourth = try c.nop();
    try expectOrder(block, &.{ first, second, middle, third, fourth, last });

    // A temporary one instruction makes is that instruction's; written by
    // another as well, it is no one's.
    const made = try c.add(.fadd, .{ c.undef, c.undef });
    try testing.expectEqual(c.cursor.link, &defOf(c, made).link);
    const maker = defOf(c, made);
    _ = try c.nop();
    c.removeInstruction(maker);
    try testing.expectEqual(@as(?*Inst, null), c.defs[made.index]);
    const again = try c.add(.fadd, .{ c.undef, c.undef });
    _ = try c.mulDest(.mov, again, .{made});
    try testing.expectEqual(@as(?*Inst, null), c.defs[again.index]);

    c.removeInstruction(second);
    try testing.expectEqual(@as(u32, 8), block.instructions.length());
    var safe = vir.eachInstSafe(block);
    while (safe.next()) |inst| {
        // All but the cursor's, which may not be removed.
        if (&inst.link != c.cursor.link) c.removeInstruction(inst);
    }
    try testing.expect(block.instructions.isSingular());
}

test "what VIR says of its instructions, as vir.c says it" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const a = try c.uniformF(1.0);
    const sum = defOf(c, try c.add(.fadd, .{ a, a }));
    try testing.expectEqual(@as(u2, 2), vir.getNsrc(sum));
    try testing.expect(vir.isAdd(sum) and !vir.isMul(sum));
    try testing.expect(!vir.hasSideEffects(sum));
    try testing.expect(!vir.isRawMov(sum));
    try testing.expectEqual(instr.Cond.none, vir.getCond(sum));

    const mov = defOf(c, try c.mul(.mov, .{a}));
    try testing.expectEqual(@as(u2, 1), vir.getNsrc(mov));
    try testing.expect(vir.isRawMov(mov));
    vir.setCond(mov, .ifb);
    try testing.expectEqual(instr.Cond.ifb, vir.getCond(mov));
    try testing.expect(!vir.isRawMov(mov));

    const tmu = try c.mulDest(.mov, vir.magicReg(.tmua), .{a});
    try testing.expect(vir.isTex(tmu));
    try testing.expect(vir.isTex(try c.addNodst(.tmuwt, .{})));
    try testing.expect(!vir.isTex(mov));
    try testing.expect(vir.hasSideEffects(try c.mulNodst(.multop, .{ a, a })));
    try testing.expect(vir.hasSideEffects(defOf(c, try c.ldtmu())));
    try testing.expect(vir.hasSideEffects(try c.branch(.always)));
    try testing.expectEqual(@as(u2, 0), vir.getNsrc(try c.nop()));
    try testing.expect(!vir.hasSideEffects(defOf(c, a)));

    c.flags_temp = 3;
    c.setUf(sum, .andz);
    try testing.expectEqual(@as(i32, -1), c.flags_temp);
    try testing.expectEqual(instr.Uf.andz, sum.qpu.flags.auf);
    try testing.expect(!c.inNonuniformControlFlow());
    c.execute = try c.getTemp();
    try testing.expect(c.inNonuniformControlFlow());
    try testing.expectEqual(a, c.followMovs(a));

    var count: u32 = 0;
    var each = c.eachInstInorder();
    while (each.next()) |_| count += 1;
    try testing.expectEqual(c.cur_block.?.instructions.length(), count);
}

/// The disassembler's text for an instruction of an add side, a mul side
/// and signals, laid out at its columns.
fn qpuText(comptime add: []const u8, comptime mul: []const u8, comptime sig: []const u8) []const u8 {
    const first = add ++ (" " ** (30 - add.len)) ++ "; " ++ mul;
    if (sig.len == 0) return first;
    return first ++ (" " ** (60 - first.len)) ++ "; " ++ sig;
}

/// A short program with each temporary given a register by hand, as the
/// register allocator will give them.
fn shortProgram(c: *Compile) !void {
    const one = try c.uniformF(1.0);
    const two = try c.uniformF(2.0);
    const sum = try c.add(.fadd, .{ two, one });
    const product = try c.mul(.fmul, .{ sum, one });
    // A move of a register to itself, which is left out.
    _ = try c.mulDest(.mov, product, .{product});
    _ = try c.mulDest(.mov, vir.magicReg(.tmud), .{product});
    _ = try c.mulDest(.mov, vir.magicReg(.tmua), .{sum});
    const texel = try c.ldtmu();
    const three = try c.addDest(.add, try c.getTemp(), .{ texel, vir.reg(.small_imm, 3) });
    three.qpu.raddr_b = pack.smallImmPack(3).?;
    three.qpu.sig.small_imm_b = true;
}

/// The program's end, as the scheduler is to emit it: the last thread
/// switch and its two delay slots.
fn programEnd(c: *Compile) !void {
    const end = try c.nop();
    end.qpu.sig.thrsw = true;
    _ = try c.nop();
    _ = try c.nop();
}

const short_registers = [_]vir.QpuReg{ .{ .index = 1 }, .{ .index = 0 }, .{ .index = 2 }, .{ .index = 3 }, .{ .index = 4 }, .{ .index = 5 } };

fn scheduledAsItIs(c: *Compile) void {
    var count: u32 = 0;
    var each = c.eachInstInorder();
    while (each.next()) |_| count += 1;
    c.qpu_inst_count = count;
}

test "VIR becomes the QPU's instructions with the registers its temporaries are given" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    try shortProgram(c);
    try programEnd(c);

    to_qpu.generateCode(c, &short_registers);
    // The uniforms the program loads, counted again.
    try testing.expectEqual(@as(u32, 2), c.num_uniforms);
    scheduledAsItIs(c);
    try testing.expectEqual(@as(?@import("validate.zig").Failure, null), try to_qpu.packCode(c));
    try testing.expectEqual(vir.Result.succeeded, c.compilation_result);

    const expected = [_][]const u8{
        // An ldunif writes rf0 by itself, and names any other register.
        qpuText("nop", "nop", "ldunifrf.rf1"),
        qpuText("nop", "nop", "ldunif"),
        qpuText("fadd rf2, rf0, rf1", "nop", ""),
        qpuText("nop", "fmul rf3, rf2, rf1", ""),
        qpuText("nop", "mov tmud, rf3", ""),
        qpuText("nop", "mov tmua, rf2", ""),
        qpuText("nop", "nop", "ldtmu.rf4"),
        // The small immediate moved to the operand that reads it.
        qpuText("add rf5, rf4, 3", "nop", ""),
        qpuText("nop", "nop", "thrsw"),
        qpuText("nop", "nop", ""),
        qpuText("nop", "nop", ""),
    };
    try testing.expectEqual(expected.len, c.qpu_insts.len);
    for (c.qpu_insts, expected) |word, text| {
        var buffer: [disasm.most_text]u8 = undefined;
        try testing.expectEqualStrings(text, disasm.disasm(word, &buffer).?);
    }
    try testing.expectEqual(@as(u32, 2), c.nop_count);

    // Each word a line, the uniform it reads after it.
    var out: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try to_qpu.dumpQpu(&w, c);
    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "; ldunifrf.rf1 (0x3f800000 / 1.000000)"));
    try testing.expect(std.mem.endsWith(u8, lines.next().?, "; ldunif (0x40000000 / 2.000000)"));
    const third = lines.next().?;
    try testing.expectEqualStrings(expected[2], third[19..]);
    try testing.expect(std.mem.startsWith(u8, third, "0x"));
    try testing.expect(to_qpu.readsUniform(c.qpu_insts[0]));
    try testing.expect(!to_qpu.readsUniform(c.qpu_insts[2]));
}

test "a program that breaks a rule, or an instruction that does not pack, fails the compile" {
    // No end: the validator's own words, at the program's end.
    {
        const c = try Compile.create(testing.allocator);
        defer c.destroy();
        try shortProgram(c);
        to_qpu.generateCode(c, &short_registers);
        scheduledAsItIs(c);
        const failure = (try to_qpu.packCode(c)).?;
        try testing.expectEqualStrings("No program-end THRSW found", failure.message);
        try testing.expectEqual(@as(usize, c.qpu_inst_count), failure.ip);
        try testing.expectEqual(vir.Result.failed, c.compilation_result);
    }
    // An integer add takes no unpack: the instruction does not pack.
    {
        const c = try Compile.create(testing.allocator);
        defer c.destroy();
        try shortProgram(c);
        const bad = try c.addDest(.add, vir.reg(.reg, 6), .{ vir.reg(.reg, 7), vir.reg(.reg, 8) });
        vir.setUnpack(bad, 0, .h);
        try programEnd(c);
        to_qpu.generateCode(c, &short_registers);
        scheduledAsItIs(c);
        const failure = (try to_qpu.packCode(c)).?;
        try testing.expectEqualStrings("Failed to pack instruction", failure.message);
        try testing.expectEqual(@as(usize, 8), failure.ip);
        try testing.expectEqual(vir.Result.failed, c.compilation_result);
    }
}

fn expectRange(c: *const Compile, t: Reg, start: i32, end: i32) !void {
    try testing.expectEqual(start, c.temp_start[t.index]);
    try testing.expectEqual(end, c.temp_end[t.index]);
}

test "a block's ranges run from each definition to its last read, and print with the pressure" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const one = try c.uniformF(1.0);
    const two = try c.uniformF(2.0);
    const sum = try c.add(.fadd, .{ one, two });
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{sum});
    try live.calculateLiveIntervals(c);

    try expectRange(c, one, 0, 2);
    try expectRange(c, two, 1, 2);
    try expectRange(c, sum, 2, 3);
    const block = c.cur_block.?;
    try testing.expectEqual(@as(u32, 0b111), block.def[0]);
    try testing.expectEqual(@as(u32, 0), block.use[0] | block.live_in[0] | block.live_out[0]);
    try testing.expectEqual(@as(i32, 0), block.start_ip);
    try testing.expectEqual(@as(i32, 4), block.end_ip);

    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try dump.program(&w, c);
    try testing.expectEqualStrings(
        \\BLOCK 0:
        \\P   1 S   0       nop t0; ldunif (0x3f800000 / 1.000000)
        \\P   2 S   1       nop t1; ldunif (0x40000000 / 2.000000)
        \\P   3 S   2 E   0, E   1 fadd t2, t0, t1
        \\P   1       E   2 mov tlb, t2
        \\
        \\
    , w.buffered());
}

test "a value read around a loop is live to the loop's end, as Mesa's two fixed points have it" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const entry = c.cur_block.?;
    const x = try c.uniformF(1.0);
    const y = try c.uniformF(2.0);
    const loop = try c.newBlock();
    c.setEmitBlock(loop);
    const sum = try c.add(.fadd, .{ x, y });
    _ = try c.mulDest(.mov, x, .{sum});
    const after = try c.newBlock();
    c.setEmitBlock(after);
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{x});
    try c.linkBlocks(entry, loop);
    try c.linkBlocks(loop, loop);
    try c.linkBlocks(loop, after);
    try live.calculateLiveIntervals(c);

    // x is read before the loop writes it again, so the loop uses it; y
    // is only read. Both are live all around the loop.
    try testing.expectEqual(@as(u32, 0b011), entry.def[0]);
    try testing.expectEqual(@as(u32, 0b100), loop.def[0]);
    try testing.expectEqual(@as(u32, 0b011), loop.use[0]);
    try testing.expectEqual(@as(u32, 0b001), after.use[0]);
    try testing.expectEqual(@as(u32, 0b000), entry.live_in[0]);
    try testing.expectEqual(@as(u32, 0b011), entry.live_out[0]);
    try testing.expectEqual(@as(u32, 0b011), loop.live_in[0]);
    try testing.expectEqual(@as(u32, 0b011), loop.live_out[0]);
    try testing.expectEqual(@as(u32, 0b001), after.live_in[0]);
    try testing.expectEqual(@as(u32, 0b000), after.live_out[0]);
    // What reaches each block, a definition in part included.
    try testing.expectEqual(@as(u32, 0b000), entry.defin[0]);
    try testing.expectEqual(@as(u32, 0b011), entry.defout[0]);
    try testing.expectEqual(@as(u32, 0b111), loop.defin[0]);
    try testing.expectEqual(@as(u32, 0b111), loop.defout[0]);
    try testing.expectEqual(@as(u32, 0b111), after.defin[0]);

    try expectRange(c, x, 0, 4);
    // y's last read is at 2, but it is live out of the loop's end, at 4.
    try expectRange(c, y, 1, 4);
    try expectRange(c, sum, 2, 3);
}

test "a conditional first write is not live back to the program's start" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const entry = c.cur_block.?;
    const x = try c.uniformF(1.0);
    c.setPf(try c.addDest(.fcmp, vir.nopReg(), .{ x, x }), .pushz);
    const next = try c.newBlock();
    c.setEmitBlock(next);
    const t = try c.getTemp();
    _ = try c.movCond(.ifa, t, x);
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{t});
    try c.linkBlocks(entry, next);
    try live.calculateLiveIntervals(c);

    // Read whole after a write under a condition, t is used in the block
    // and so live into the program; but no definition of it reaches the
    // block's start, and its range stays its own.
    try testing.expect(vir.bitsetTest(next.use, t.index));
    try testing.expect(vir.bitsetTest(entry.live_in, t.index));
    try testing.expect(!vir.bitsetTest(next.defin, t.index));
    try expectRange(c, t, 2, 3);
    try expectRange(c, x, 0, 2);
}

test "a read under the condition and flags a write was made under is no use of it" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const block = c.cur_block.?;
    const x = try c.uniformF(1.0);
    c.setPf(try c.addDest(.fcmp, vir.nopReg(), .{ x, x }), .pushz);
    const t = try c.getTemp();
    const u = try c.getTemp();
    _ = try c.movCond(.ifa, t, x);
    _ = try c.movCond(.ifa, u, t);
    try live.calculateLiveIntervals(c);
    try testing.expect(!vir.bitsetTest(block.use, t.index));
    try testing.expect(vir.bitsetTest(block.defout, t.index));

    // New flags, and the same condition reads other flags: a use.
    const v = try c.getTemp();
    c.setPf(try c.addDest(.fcmp, vir.nopReg(), .{ x, x }), .pushn);
    _ = try c.movCond(.ifa, v, t);
    try live.calculateLiveIntervals(c);
    try testing.expect(vir.bitsetTest(block.use, t.index));
}

test "a half written is a definition where both halves are, or where the other is never read" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const block = c.cur_block.?;
    const x = try c.uniformF(1.0);

    // Both halves.
    const both = try c.getTemp();
    vir.setPack(try c.addDest(.fadd, both, .{ x, x }), .l);
    vir.setPack(try c.addDest(.fadd, both, .{ x, x }), .h);
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{both});
    // The low half, and only the low half read.
    const low = try c.getTemp();
    vir.setPack(try c.addDest(.fadd, low, .{ x, x }), .l);
    vir.setUnpack(try c.mulDest(.fmul, vir.magicReg(.tlb), .{ low, x }), 0, .l);
    // The low half, and the whole read.
    const whole = try c.getTemp();
    vir.setPack(try c.addDest(.fadd, whole, .{ x, x }), .l);
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{whole});
    try live.calculateLiveIntervals(c);

    try testing.expect(vir.bitsetTest(block.def, both.index));
    try testing.expect(vir.bitsetTest(block.def, low.index));
    try testing.expect(!vir.bitsetTest(block.def, whole.index));
    try testing.expect(vir.bitsetTest(block.use, whole.index));
    try testing.expect(!vir.bitsetTest(block.use, both.index));
}

test "a payload register moved into a temporary is live from the start" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    _ = try c.uniformF(1.0);
    _ = try c.nop();
    const w = try c.mul(.mov, .{vir.reg(.reg, 3)});
    const r0 = try c.mul(.mov, .{vir.reg(.reg, 0)});
    _ = try c.add(.fadd, .{ w, r0 });
    try live.calculateLiveIntervals(c);
    try expectRange(c, w, 0, 4);
    try expectRange(c, r0, 3, 4);
}

test "after a spill the ranges are found again, spill_base's over the loop it is read in" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const entry = c.cur_block.?;
    const value = try c.uniformF(1.0);
    const loop = try c.newBlock();
    c.setEmitBlock(loop);
    const sum = try c.add(.fadd, .{ value, value });
    _ = try c.nop();
    _ = try c.nop();
    const after = try c.newBlock();
    c.setEmitBlock(after);
    _ = try c.nop();
    try c.linkBlocks(entry, loop);
    try c.linkBlocks(loop, loop);
    try c.linkBlocks(loop, after);
    try live.calculateLiveIntervals(c);
    const before = c.num_temps;

    // As a spill makes them: the base, loaded at the end of the entry
    // block, and read at the loop's start.
    c.cursor = vir.afterBlock(entry);
    const base = try c.uniform(.spill_offset, 0);
    c.spill_base = base;
    c.cursor = vir.beforeInst(defOf(c, sum));
    const address = try c.add(.add, .{ base, base });
    try live.updateLiveIntervalsAfterSpill(c, before);

    try testing.expectEqual(@as(i32, 3), defOf(c, sum).ip);
    try testing.expectEqual(@as(i32, 2), loop.start_ip);
    try testing.expectEqual(@as(i32, 6), loop.end_ip);
    try expectRange(c, value, 0, 6);
    try expectRange(c, sum, 3, 3);
    // Only its reads would give it 1 to 2; it is live from the start, and
    // to the loop's end, which goes back to where it is read.
    try expectRange(c, base, 0, 6);
    try expectRange(c, address, 2, 2);
}
