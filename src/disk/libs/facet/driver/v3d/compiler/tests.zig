// SPDX-License-Identifier: MIT
//! The tests of the VIR layer (vir.zig, dump.zig, to_qpu.zig), its
//! liveness (live.zig) and its register allocation (allocate.zig): what
//! Mesa's VIR is built into, prints as, is live over, which registers its
//! temporaries are given, and what it becomes once they have them. The
//! text is what Mesa's vir_dump and the QPU disassembler print, the
//! disassembler's own having been held to Mesa's tests in qpu/tests.zig.

const std = @import("std");
const testing = std.testing;
const instr = @import("../qpu/instr.zig");
const pack = @import("../qpu/pack.zig");
const disasm = @import("../qpu/disasm.zig");
const vir = @import("vir.zig");
const dump = @import("dump.zig");
const to_qpu = @import("to_qpu.zig");
const live = @import("live.zig");
const allocate = @import("allocate.zig");
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
    // The lookup's last write, which says how many ldtmus it has.
    const lookup = try c.mulDest(.mov, vir.magicReg(.tmua), .{sum});
    lookup.ldtmu_count = 1;
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

fn expectProgram(c: *const Compile, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, c.qpu_insts.len);
    for (c.qpu_insts, expected) |word, text| {
        var buffer: [disasm.most_text]u8 = undefined;
        try testing.expectEqualStrings(text, disasm.disasm(word, &buffer).?);
    }
}

test "scheduled, a chain keeps its order, and the thread end's signal goes back into an ldtmu" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    try shortProgram(c);

    try testing.expectEqual(@as(?@import("validate.zig").Failure, null), try to_qpu.virToQpu(c, &short_registers));
    try testing.expectEqual(vir.Result.succeeded, c.compilation_result);
    try expectProgram(c, &.{
        qpuText("nop", "nop", "ldunifrf.rf1"),
        qpuText("nop", "nop", "ldunif"),
        qpuText("fadd rf2, rf0, rf1", "nop", ""),
        qpuText("nop", "fmul rf3, rf2, rf1", ""),
        qpuText("nop", "mov tmud, rf3", ""),
        qpuText("nop", "mov tmua, rf2", ""),
        // Not the add after it, which writes a register, nor the tmua
        // write, which reads rf2: the fragment shader's setup may write
        // rf2 and rf3 in the thread end's delay slots.
        qpuText("nop", "nop", "thrsw; ldtmu.rf4"),
        qpuText("add rf5, rf4, 3", "nop", ""),
        qpuText("nop", "nop", ""),
    });
    try testing.expectEqual(@as(u32, 1), c.nop_count);
    // The uniforms in the order they are read.
    try testing.expectEqual(@as(usize, 2), c.uniform_data.len);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, 1.0))), c.uniform_data[0]);
    try testing.expectEqual(@as(u32, @bitCast(@as(f32, 2.0))), c.uniform_data[1]);
    try testing.expect(c.last_thrsw == null);
}

fn regs(comptime indices: []const u6) [indices.len]vir.QpuReg {
    var out: [indices.len]vir.QpuReg = undefined;
    for (indices, &out) |index, *r| r.* = .{ .index = index };
    return out;
}

const no_failure: ?@import("validate.zig").Failure = null;

test "scheduled, independent operations pair: an add or a sub moved to the mul side, a mov to the add side" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const one = try c.uniformF(1.0);
    const two = try c.uniformF(2.0);
    _ = try c.add(.add, .{ one, two });
    _ = try c.add(.fadd, .{ one, two });
    _ = try c.mul(.fmul, .{ one, two });
    _ = try c.add(.sub, .{ one, two });
    _ = try c.mul(.mov, .{one});
    _ = try c.mul(.fmul, .{ one, one });

    try testing.expectEqual(no_failure, try to_qpu.virToQpu(c, &regs(&.{ 1, 2, 3, 4, 5, 6, 7, 8 })));
    try expectProgram(c, &.{
        qpuText("nop", "nop", "ldunifrf.rf1"),
        // The mov into the second ldunif's free mul side, then moved to
        // the add side for the fmul.
        qpuText("mov rf7, rf1", "fmul rf8, rf1, rf1", "ldunifrf.rf2"),
        // The fadd cannot go to the mul side: the add before it does.
        qpuText("fadd rf4, rf1, rf2", "add rf3, rf1, rf2", ""),
        qpuText("sub rf6, rf1, rf2", "fmul rf5, rf1, rf2", ""),
        // Nothing before can take the thread end's signal: each writes
        // a register from its ALUs.
        qpuText("nop", "nop", "thrsw"),
        qpuText("nop", "nop", ""),
        qpuText("nop", "nop", ""),
    });
    try testing.expectEqual(@as(u32, 2), c.nop_count);
    try testing.expectEqual(@as(u32, 0), c.qpu_inst_stalled_count);
}

test "scheduled, a write of a register pairs with the read of it before" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const one = try c.uniformF(1.0);
    _ = try c.add(.fadd, .{ one, one });
    _ = try c.mul(.fmul, .{ one, one });

    // The fmul's temporary given the fadd's operand's register, free
    // after the fadd reads it.
    try testing.expectEqual(no_failure, try to_qpu.virToQpu(c, &regs(&.{ 1, 3, 1 })));
    try expectProgram(c, &.{
        qpuText("nop", "nop", "ldunifrf.rf1"),
        qpuText("fadd rf3, rf1, rf1", "fmul rf1, rf1, rf1", ""),
        qpuText("nop", "nop", "thrsw"),
        qpuText("nop", "nop", ""),
        qpuText("nop", "nop", ""),
    });
}

test "scheduled, the last thread switch goes back two instructions and is told by a second in a row" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const one = try c.uniformF(1.0);
    const lookup = try c.mulDest(.mov, vir.magicReg(.tmua), .{one});
    lookup.ldtmu_count = 1;
    try c.emitThrsw();
    const switch_inst = c.last_thrsw.?;
    switch_inst.is_last_thrsw = true;
    const texel = try c.ldtmu();
    _ = try c.add(.fadd, .{ texel, one });

    try testing.expectEqual(no_failure, try to_qpu.virToQpu(c, &regs(&.{ 1, 2, 3 })));
    try expectProgram(c, &.{
        qpuText("nop", "nop", "thrsw; ldunifrf.rf1"),
        qpuText("nop", "mov tmua, rf1", "thrsw"),
        // The ldtmu is not moved before the switch, which is what the
        // switch is for.
        qpuText("nop", "nop", ""),
        qpuText("nop", "nop", "ldtmu.rf2"),
        // fadd's operands in the order it packs in.
        qpuText("fadd rf3, rf1, rf2", "nop", ""),
        // An ldtmu writing rf2 may not be in the thread end.
        qpuText("nop", "nop", "thrsw"),
        qpuText("nop", "nop", ""),
        qpuText("nop", "nop", ""),
    });
    // The compile's last thread switch is the instruction its signal went
    // into.
    try testing.expect(c.last_thrsw.?.qpu.sig.ldunifrf);
    try testing.expect(c.last_thrsw.?.qpu.sig.thrsw);
}

test "scheduled, a branch fills its delay slots from before it, and from its successor where it jumps always" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const entry = c.entryBlock();
    const one = try c.uniformF(1.0);
    const sum = try c.add(.fadd, .{ one, one });
    _ = c.emitNondef(try c.branchInst(.always));
    const skipped = try c.newBlock();
    const target = try c.newBlock();
    try c.linkBlocks(entry, target);
    c.setEmitBlock(skipped);
    _ = try c.mul(.fmul, .{ one, one });
    try c.linkBlocks(skipped, target);
    c.setEmitBlock(target);
    _ = try c.add(.fadd, .{ sum, sum });

    try testing.expectEqual(no_failure, try to_qpu.virToQpu(c, &regs(&.{ 1, 2, 3, 4 })));
    try expectProgram(c, &.{
        qpuText("nop", "nop", "ldunifrf.rf1"),
        // Past the delay slots and one more instruction.
        "bu  16, r:unif",
        // The fadd before the branch moved into its first delay slot, and
        // the target's first instruction copied into the second, which
        // the branch now jumps past. The last is not looked at.
        qpuText("fadd rf2, rf1, rf1", "nop", ""),
        qpuText("fadd rf4, rf2, rf2", "nop", ""),
        qpuText("nop", "nop", ""),
        qpuText("nop", "fmul rf3, rf1, rf1", ""),
        qpuText("fadd rf4, rf2, rf2", "nop", ""),
        qpuText("nop", "nop", "thrsw"),
        qpuText("nop", "nop", ""),
        qpuText("nop", "nop", ""),
    });
    try testing.expectEqual(@as(u32, 0), entry.start_qpu_ip);
    try testing.expectEqual(@as(u32, 1), entry.branch_qpu_ip);
    try testing.expectEqual(@as(u32, 4), entry.end_qpu_ip);
    try testing.expectEqual(@as(u32, 5), skipped.start_qpu_ip);
    try testing.expectEqual(@as(u32, 6), target.start_qpu_ip);
    // The branch's uniform, the jump in the uniforms: none, as the
    // blocks between read none.
    try testing.expectEqual(@as(u32, 1), entry.branch_uniform);
    try testing.expectEqual(@as(u32, 0), c.uniform_data[1]);
    try testing.expectEqual(@as(u32, 3), c.nop_count);
}

/// An input interpolated as Mesa's emit_fragment_varying does it: the
/// ldvary, its value times w, plus the C coefficient it leaves in rf0.
fn interpolate(c: *Compile, w: Reg) !void {
    const ld = try c.addInst(.nop, c.undef, c.undef, c.undef);
    ld.qpu.sig.ldvary = true;
    const value = try c.emitDef(ld);
    _ = try c.add(.fadd, .{ try c.mul(.fmul, .{ value, w }), vir.reg(.reg, 0) });
}

test "scheduled, a fragment program's ldvarys go first, the second moved up for the first's sum to pair with its product" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    c.num_inputs = 2;
    const w = try c.uniformF(2.0);
    try interpolate(c, w);
    try interpolate(c, w);

    try testing.expectEqual(no_failure, try to_qpu.virToQpu(c, &regs(&.{ 3, 1, 2, 4, 5, 6, 7 })));
    try expectProgram(c, &.{
        // The uniform waits while there are ldvarys to come, as long as
        // something else can go.
        qpuText("nop", "nop", "ldvary.rf1"),
        qpuText("nop", "nop", "ldunifrf.rf3"),
        // The second ldvary, paired with the first's sum, moved up a
        // cycle: its rf0 write lands with the sum, which reads the
        // first's.
        qpuText("nop", "fmul rf2, rf1, rf3", "ldvary.rf5"),
        qpuText("fadd rf4, rf0, rf2", "fmul rf6, rf5, rf3", ""),
        qpuText("fadd rf7, rf0, rf6", "nop", ""),
        qpuText("nop", "nop", "thrsw"),
        qpuText("nop", "nop", ""),
        qpuText("nop", "nop", ""),
    });
}

test "scheduled, an SFU result read the cycle after is counted as a stall, and its latency in the cycles" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const one = try c.uniformF(1.0);
    const r = try c.add(.recip, .{one});
    _ = try c.add(.fadd, .{ r, r });

    to_qpu.generateCode(c, &regs(&.{ 1, 2, 3 }));
    // One cycle for the ldunif, two for the SFU's result.
    try testing.expectEqual(@as(u32, 3), try @import("schedule.zig").qpuScheduleInstructions(c));
    try testing.expectEqual(no_failure, try to_qpu.packCode(c));
    try expectProgram(c, &.{
        qpuText("nop", "nop", "ldunifrf.rf1"),
        qpuText("recip rf2, rf1", "nop", ""),
        qpuText("fadd rf3, rf2, rf2", "nop", ""),
        // An SFU operation may not be in a thread switch's delay slots.
        qpuText("nop", "nop", "thrsw"),
        qpuText("nop", "nop", ""),
        qpuText("nop", "nop", ""),
    });
    try testing.expectEqual(@as(u32, 1), c.qpu_inst_stalled_count);
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

/// interferes (vir_register_allocate.c:686): the ranges overlap, one
/// ending where the other starts not counting.
fn rangesOverlap(c: *const Compile, t0: usize, t1: usize) bool {
    return !(c.temp_start[t0] >= c.temp_end[t1] or c.temp_start[t1] >= c.temp_end[t0]);
}

/// The registers the allocator gave, held to the program as it is now,
/// its ranges found again from the start: each is one of the file's that
/// the threads leave, and no two temporaries live together share one.
fn expectColoured(c: *Compile, registers: []const vir.QpuReg) !void {
    try testing.expectEqual(@as(usize, c.num_temps), registers.len);
    try live.calculateLiveIntervals(c);
    const budget = @as(u32, 64) >> @intCast(c.thread_index);
    for (0..c.num_temps) |i| {
        // Not live anywhere.
        if (c.temp_start[i] > c.temp_end[i]) continue;
        try testing.expect(!registers[i].magic);
        try testing.expect(registers[i].index < budget);
        for (i + 1..c.num_temps) |j| {
            if (c.temp_start[j] > c.temp_end[j]) continue;
            if (rangesOverlap(c, i, j)) try testing.expect(registers[i].index != registers[j].index);
        }
    }
}

fn expectRegisters(registers: []const vir.QpuReg, expected: []const u6) !void {
    try testing.expectEqual(expected.len, registers.len);
    for (registers, expected) |r, index| {
        try testing.expect(!r.magic);
        try testing.expectEqual(index, r.index);
    }
}

test "the register sets are the file's 64 registers at 1 and 2 threads and 32 at 4, as Mesa's" {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    const expected_p = [_]u32{ 64, 64, 32, 32 };
    for (expected_p, 0..) |p, index| {
        const class = compiler.regs.classFromIndex(@intCast(index));
        try testing.expectEqual(@as(u32, @intCast(index)), class.index);
        try testing.expectEqual(p, class.p);
        // Single registers, the first 32 in every class: each conflicts
        // with one at most of every class.
        try testing.expectEqual(@as(usize, 4), class.q.len);
        for (class.q) |q| try testing.expectEqual(@as(u32, 1), q);
    }
    try testing.expectEqual(compiler.regs.classFromIndex(0), compiler.reg_class_any[0]);
    try testing.expectEqual(compiler.regs.classFromIndex(1), compiler.reg_class_phys[0]);
    try testing.expectEqual(compiler.regs.classFromIndex(2), compiler.reg_class_any[1]);
    try testing.expectEqual(compiler.regs.classFromIndex(3), compiler.reg_class_phys[1]);
}

test "temporaries are given registers round the file from rf4, rf0 kept, one not live anywhere rf0" {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    c.compiler = &compiler;
    const one = try c.uniformF(1.0);
    const two = try c.uniformF(2.0);
    const sum = try c.add(.fadd, .{ one, two });
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{sum});
    _ = try c.getTemp();

    const registers = (try allocate.registerAllocate(c)).?;
    defer testing.allocator.free(registers);
    // Four threads: the classes of 32 registers.
    try testing.expectEqual(@as(u32, 1), c.thread_index);
    // `one` is live across the second ldunif's rf0 write, and neither
    // ldunif of a fragment program this close to its start tries rf0.
    try expectRegisters(registers, &.{ 4, 5, 6, 0 });
    try expectColoured(c, registers);
    try testing.expectEqual(@as(u32, 0), c.spills + c.fills);
}

test "an ldunif's temporary is tried in rf0 outside a fragment program, where nothing is live across it" {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    c.compiler = &compiler;
    c.stage = .vertex;
    const one = try c.uniformF(1.0);
    const two = try c.uniformF(2.0);
    const sum = try c.add(.fadd, .{ one, two });
    _ = try c.mulDest(.mov, vir.magicReg(.vpm), .{sum});

    const registers = (try allocate.registerAllocate(c)).?;
    defer testing.allocator.free(registers);
    try expectRegisters(registers, &.{ 4, 0, 5 });
    try expectColoured(c, registers);
}

test "a temporary moved out of a payload register is given that register" {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    c.compiler = &compiler;
    const w = try c.mul(.mov, .{vir.reg(.reg, 1)});
    const z = try c.mul(.mov, .{vir.reg(.reg, 3)});
    const sum = try c.add(.fadd, .{ w, z });
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{sum});

    const registers = (try allocate.registerAllocate(c)).?;
    defer testing.allocator.free(registers);
    try expectRegisters(registers, &.{ 1, 3, 4 });
    try expectColoured(c, registers);
}

/// A value the add unit makes of a small immediate, which no uniform
/// defines and the hardware does not give again: only the TMU spills it.
fn smallImmAdd(c: *Compile, value: u32) !Reg {
    const imm = vir.reg(.small_imm, value);
    const sum = try c.add(.add, .{ imm, imm });
    const def = defOf(c, sum);
    def.qpu.raddr_b = pack.smallImmPack(value).?;
    def.qpu.sig.small_imm_b = true;
    return sum;
}

/// A fragment program with more temporaries live together than four
/// threads have registers: `held`, made first and read last, and across
/// it `count` values made one after the other and then summed; then the
/// last thread switch, and the sum written out. With 32 values, `held`
/// and they are 33; the 32 alone fit.
const Overfull = struct { held: Reg, result: Reg };

/// How `held` is made: loaded as a uniform, asked of the hardware, which
/// gives it again, or made of a small immediate.
const Held = enum { uniform, reconstructed, tmu };

fn overfullProgram(c: *Compile, how: Held, count: usize) !Overfull {
    const held = switch (how) {
        .uniform => try c.uniformF(1.0),
        .reconstructed => try c.add(.eidx, .{}),
        .tmu => try smallImmAdd(c, 1),
    };
    var values: [33]Reg = undefined;
    for (values[0..count], 0..) |*value, i| value.* = try smallImmAdd(c, @intCast(i % 16));
    var sum = try c.add(.fadd, .{ values[0], values[1] });
    for (values[2..count]) |value| sum = try c.add(.fadd, .{ sum, value });
    const result = try c.add(.fadd, .{ sum, held });
    const end = try c.nop();
    end.qpu.sig.thrsw = true;
    end.is_last_thrsw = true;
    c.last_thrsw = end;
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{result});
    return .{ .held = held, .result = result };
}

test "a uniform spilled is loaded again where it is read, and the rest fit" {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    c.compiler = &compiler;
    const program = try overfullProgram(c, .uniform, 32);
    const held = program.held;
    const before = c.num_temps;
    const read = defOf(c, program.result);

    const registers = (try allocate.registerAllocate(c)).?;
    defer testing.allocator.free(registers);
    try expectColoured(c, registers);
    // Neither stored nor loaded through the TMU.
    try testing.expectEqual(@as(u32, 0), c.spills + c.fills);
    try testing.expectEqual(@as(u32, 0), c.spill_size);
    // Its ldunif gone, and one made before the instruction that read it,
    // for that instruction alone.
    try testing.expectEqual(@as(?*Inst, null), c.defs[held.index]);
    try testing.expectEqual(before + 1, c.num_temps);
    const reload = read.src[1];
    try testing.expectEqual(Reg{ .file = .temp, .index = before }, reload);
    const ldunif = defOf(c, reload);
    try testing.expect(ldunif.qpu.sig.ldunif);
    try testing.expectEqual(@as(?u32, 0), ldunif.uniform);
    try testing.expectEqual(&ldunif.link, read.link.prev.?);
    var each = c.eachInstInorder();
    while (each.next()) |inst| {
        try testing.expect(!(inst.dst.file == .temp and inst.dst.index == held.index));
    }
}

test "the spill base is worked out once at the program's start, its constant 2 loaded again" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const two = try c.uniformUi(2);
    _ = try c.add(.fadd, .{ two, two });
    try allocate.setupSpillBase(c);

    try testing.expectEqual(Reg{ .file = .temp, .index = 10 }, c.spill_base);
    var buffer: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try dump.program(&w, c);
    try testing.expectEqualStrings(
        \\BLOCK 0:
        \\tidx t2
        \\nop t3; ldunif (spill_size_per_thread)
        \\multop null, t2, t3
        \\umul24 t4, t2, t3
        \\eidx t5
        \\nop t6; ldunif (0x00000002 / 0.000000)
        \\shl t7, t5, t6
        \\add t8, t4, t7
        \\nop t9; ldunif (spill_offset)
        \\add t10, t8, t9
        \\nop t0; ldunif (0x00000002 / 0.000000)
        \\fadd t1, t0, t0
        \\
        \\
    , w.buffered());
    // None of its temporaries is spilled; the program's may be.
    for (2..c.num_temps) |t| try testing.expect(!vir.bitsetTest(c.spillable, t));
    try testing.expect(vir.bitsetTest(c.spillable, 0) and vir.bitsetTest(c.spillable, 1));
    // Emitting goes on at the end of the block.
    const after = try c.add(.fadd, .{ two, two });
    try testing.expectEqual(&defOf(c, after).link, c.cur_block.?.instructions.prev.?);
}

fn expectOp(inst: *const Inst, op: instr.AddOp) !void {
    try testing.expectEqual(instr.Kind.alu, inst.qpu.kind);
    try testing.expectEqual(op, inst.qpu.alu.add.op);
}

fn nextInst(inst: *const Inst) *Inst {
    return @fieldParentPtr("link", inst.link.next.?);
}

test "spilled to the TMU, a temporary is stored after it is written and read back before it is read" {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    c.compiler = &compiler;
    c.max_tmu_spills = std.math.maxInt(u32);
    const program = try overfullProgram(c, .tmu, 32);
    const write = defOf(c, program.held);
    const read = defOf(c, program.result);

    const registers = (try allocate.registerAllocate(c)).?;
    defer testing.allocator.free(registers);
    try expectColoured(c, registers);
    try testing.expect(c.spills >= 1 and c.fills >= 1);
    try testing.expect(c.spill_size >= 64 and c.spill_size % 64 == 0);
    try testing.expect(c.tmu_dirty_rcl);
    // The last thread switch is still the program's, not a spill's.
    try testing.expect(c.last_thrsw.?.is_last_thrsw);

    // The spill base first, kept off rf0, which the ldunifs write.
    var setup = c.entryBlock().instructions.next.?;
    const setup_ops = [_]instr.AddOp{ .tidx, .nop, .nop, .nop, .eidx, .nop, .shl, .add, .nop, .add };
    for (setup_ops) |op| {
        try expectOp(@fieldParentPtr("link", setup), op);
        setup = setup.next.?;
    }
    const base: *Inst = @fieldParentPtr("link", setup.prev.?);
    try testing.expectEqual(c.spill_base, base.dst);
    try testing.expect(registers[c.spill_base.index].index != 0);

    // The first victim, the longest lived: its write given a temporary
    // of its own and stored, with the address its spill offset, 0.
    try testing.expect(write.dst.index != program.held.index);
    const store = nextInst(write);
    try testing.expectEqual(instr.MulOp.mov, store.qpu.alu.mul.op);
    try testing.expectEqual(vir.magicReg(.tmud), store.dst);
    try testing.expectEqual(write.dst, store.src[0]);
    const offset = nextInst(store);
    try testing.expect(offset.qpu.sig.ldunif);
    try testing.expectEqual(vir.Uniform.constant, c.uniform_contents[offset.uniform.?]);
    try testing.expectEqual(@as(u32, 0), c.uniform_data[offset.uniform.?]);
    const address = nextInst(offset);
    try testing.expectEqual(vir.magicReg(.tmuau), address.dst);
    try testing.expectEqual([2]Reg{ c.spill_base, offset.dst }, address.src[0..2].*);
    try testing.expectEqual(@as(u32, 0xffffff7f), c.uniform_data[address.uniform.?]);
    const thrsw = nextInst(address);
    try testing.expect(thrsw.qpu.sig.thrsw and !thrsw.is_last_thrsw);
    try expectOp(nextInst(thrsw), .tmuwt);

    // And read back into a temporary of its own before it is read.
    const fill = defOf(c, read.src[1]);
    try testing.expect(fill.qpu.sig.ldtmu);
    try testing.expectEqual(&fill.link, read.link.prev.?);
    const fill_thrsw: *Inst = @fieldParentPtr("link", fill.link.prev.?);
    try testing.expect(fill_thrsw.qpu.sig.thrsw);
    const fill_address: *Inst = @fieldParentPtr("link", fill_thrsw.link.prev.?);
    try testing.expectEqual(vir.magicReg(.tmuau), fill_address.dst);
    try testing.expectEqual(c.spill_base, fill_address.src[0]);
}

test "where no temporary can go, the allocation fails, and gives back what it took" {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    c.compiler = &compiler;
    // 33 values live together, and only the uniform to spill: the
    // strategy allows no TMU spill.
    const program = try overfullProgram(c, .uniform, 33);
    const before = c.num_temps;
    try testing.expectEqual(@as(?[]vir.QpuReg, null), try allocate.registerAllocate(c));
    // The uniform was spilled, loaded again where it is read, before the
    // values were found not to fit.
    try testing.expectEqual(before + 1, c.num_temps);
    try testing.expectEqual(@as(?*Inst, null), c.defs[program.held.index]);
    try testing.expectEqual(@as(u32, 0), c.spills + c.fills);
    try testing.expectEqual(@as(usize, 0), c.nodes.info.len);
    try testing.expectEqual(@as(?*@import("ra.zig").Graph, null), c.g);
}

test "a value the hardware gives again is asked for again where it is read" {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    c.compiler = &compiler;
    const program = try overfullProgram(c, .reconstructed, 32);
    const before = c.num_temps;
    const read = defOf(c, program.result);

    const registers = (try allocate.registerAllocate(c)).?;
    defer testing.allocator.free(registers);
    try expectColoured(c, registers);
    try testing.expectEqual(@as(u32, 0), c.spills + c.fills);
    try testing.expectEqual(@as(?*Inst, null), c.defs[program.held.index]);
    try testing.expectEqual(before + 1, c.num_temps);
    const again = defOf(c, read.src[1]);
    try expectOp(again, .eidx);
    try testing.expectEqual(&again.link, read.link.prev.?);
}

test "a spill inside a TMU sequence waits for its end, and a fill inside one goes before its start" {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    c.compiler = &compiler;
    c.max_tmu_spills = std.math.maxInt(u32);

    // A TMU read, and `inside` made while it is under way.
    const address = try smallImmAdd(c, 0);
    _ = try c.mulDest(.mov, vir.magicReg(.tmua), .{address});
    const inside = try smallImmAdd(c, 2);
    const texel = try c.ldtmu();
    const outside = try smallImmAdd(c, 1);
    // 30 values live together, with `inside`, `outside` and `texel` 33.
    var values: [30]Reg = undefined;
    for (&values, 0..) |*value, i| value.* = try smallImmAdd(c, @intCast(i % 16));
    var sum = try c.add(.fadd, .{ values[0], values[1] });
    for (values[2..]) |value| sum = try c.add(.fadd, .{ sum, value });
    // A TMU write, `outside` read while it is under way.
    const data = try c.mulDest(.mov, vir.magicReg(.tmud), .{sum});
    const read_inside = try c.mulDest(.mov, vir.magicReg(.tmua), .{outside});
    const result = try c.ldtmu();
    const total = try c.add(.fadd, .{ result, inside });
    const final = try c.add(.fadd, .{ total, texel });
    const end = try c.nop();
    end.qpu.sig.thrsw = true;
    end.is_last_thrsw = true;
    c.last_thrsw = end;
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{final});
    // The two alone may be spilled, which leaves 32.
    for (0..c.num_temps) |t| {
        if (t != inside.index and t != outside.index) vir.bitsetClear(c.spillable, t);
    }
    const inside_def = defOf(c, inside);
    const texel_def = defOf(c, texel);
    const total_def = defOf(c, total);

    const registers = (try allocate.registerAllocate(c)).?;
    defer testing.allocator.free(registers);
    try expectColoured(c, registers);
    try testing.expectEqual(@as(u32, 2), c.spills);
    try testing.expectEqual(@as(u32, 2), c.fills);
    try testing.expectEqual(@as(u32, 128), c.spill_size);

    // `inside` written to a temporary of its own, stored once the ldtmu
    // has ended the read it was made in the middle of, and read back.
    try testing.expect(inside_def.dst.index != inside.index);
    const store = nextInst(texel_def);
    try testing.expectEqual(vir.magicReg(.tmud), store.dst);
    try testing.expectEqual(inside_def.dst, store.src[0]);
    try testing.expect(defOf(c, total_def.src[1]).qpu.sig.ldtmu);

    // `outside` read back before the write it is read in the middle of.
    const fill = defOf(c, read_inside.src[0]);
    try testing.expect(fill.qpu.sig.ldtmu);
    try testing.expectEqual(&fill.link, data.link.prev.?);
}

fn prevInst(inst: *const Inst) *Inst {
    return @fieldParentPtr("link", inst.link.prev.?);
}

test "a write of part of a spilled temporary: under a condition stored under it, packed filled first and stored whole" {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    c.compiler = &compiler;
    c.max_tmu_spills = std.math.maxInt(u32);

    const masked = try smallImmAdd(c, 1);
    const halved = try smallImmAdd(c, 2);
    const kept = try smallImmAdd(c, 3);
    const k = try smallImmAdd(c, 4);
    const compare = try c.addDest(.fcmp, vir.nopReg(), .{ k, k });
    c.setPf(compare, .pushz);
    const conditional = try c.movCond(.ifa, masked, k);
    const packed_write = try c.addDest(.fadd, halved, .{ k, k });
    vir.setPack(packed_write, .l);
    // 30 values live together, with the three 33.
    var values: [30]Reg = undefined;
    for (&values, 0..) |*value, i| value.* = try smallImmAdd(c, @intCast(i % 16));
    var sum = try c.add(.fadd, .{ values[0], values[1] });
    for (values[2..]) |value| sum = try c.add(.fadd, .{ sum, value });
    const first = try c.add(.fadd, .{ sum, masked });
    const second = try c.add(.fadd, .{ first, halved });
    const third = try c.add(.fadd, .{ second, kept });
    const end = try c.nop();
    end.qpu.sig.thrsw = true;
    end.is_last_thrsw = true;
    c.last_thrsw = end;
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{third});
    for (0..c.num_temps) |t| {
        if (t != masked.index and t != halved.index) vir.bitsetClear(c.spillable, t);
    }

    const registers = (try allocate.registerAllocate(c)).?;
    defer testing.allocator.free(registers);
    try expectColoured(c, registers);
    // Two stores of each, a fill of each where it is read, and one more
    // before the packed write.
    try testing.expectEqual(@as(u32, 4), c.spills);
    try testing.expectEqual(@as(u32, 3), c.fills);
    try testing.expectEqual(@as(u32, 128), c.spill_size);

    // The conditional write stored under its condition, its lanes alone.
    try testing.expect(conditional.dst.index != masked.index);
    const store = nextInst(conditional);
    try testing.expectEqual(vir.magicReg(.tmud), store.dst);
    try testing.expectEqual(conditional.dst, store.src[0]);
    try testing.expectEqual(instr.Cond.ifa, store.qpu.flags.mc);
    const address = nextInst(nextInst(store));
    try testing.expectEqual(vir.magicReg(.tmuau), address.dst);
    try testing.expectEqual(instr.Cond.ifa, address.qpu.flags.ac);
    try testing.expectEqual(@as(u32, 0xffffffff), c.uniform_data[address.uniform.?]);

    // The packed write's other half filled from the slot before it, and
    // all of it stored, per quad.
    const whole = prevInst(packed_write);
    try testing.expectEqual(instr.MulOp.mov, whole.qpu.alu.mul.op);
    try testing.expectEqual(packed_write.dst, whole.dst);
    try testing.expect(defOf(c, whole.src[0]).qpu.sig.ldtmu);
    const packed_store = nextInst(packed_write);
    try testing.expectEqual(vir.magicReg(.tmud), packed_store.dst);
    try testing.expectEqual(instr.Cond.none, packed_store.qpu.flags.mc);
    const packed_address = nextInst(nextInst(packed_store));
    try testing.expectEqual(@as(u32, 0xffffff7f), c.uniform_data[packed_address.uniform.?]);
}

test "far over the registers, a batch of victims is spilled before the graph is brought up to date" {
    var compiler = try allocate.initRegSets(testing.allocator);
    defer compiler.deinit();
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    c.compiler = &compiler;

    // Four uniforms read last and 32 values: 36 live together, four over,
    // so the first batch is of two.
    var uniforms: [4]Reg = undefined;
    for (&uniforms, 0..) |*u, i| u.* = try c.uniformF(@floatFromInt(i + 1));
    var values: [32]Reg = undefined;
    for (&values, 0..) |*value, i| value.* = try smallImmAdd(c, @intCast(i % 16));
    var sum = try c.add(.fadd, .{ values[0], values[1] });
    for (values[2..]) |value| sum = try c.add(.fadd, .{ sum, value });
    var reads: [4]*Inst = undefined;
    for (uniforms, &reads) |u, *read| {
        sum = try c.add(.fadd, .{ sum, u });
        read.* = defOf(c, sum);
    }
    const end = try c.nop();
    end.qpu.sig.thrsw = true;
    end.is_last_thrsw = true;
    c.last_thrsw = end;
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{sum});
    try live.calculateLiveIntervals(c);
    try testing.expectEqual(@as(u32, 36), try c.getMaxTemps());
    const before = c.num_temps;

    const registers = (try allocate.registerAllocate(c)).?;
    defer testing.allocator.free(registers);
    try expectColoured(c, registers);
    try testing.expectEqual(@as(u32, 0), c.spills + c.fills);
    // All four loaded again where they are read, each its own uniform.
    try testing.expectEqual(before + 4, c.num_temps);
    for (uniforms, reads, 0..) |u, read, i| {
        try testing.expectEqual(@as(?*Inst, null), c.defs[u.index]);
        const reload = defOf(c, read.src[1]);
        try testing.expect(reload.qpu.sig.ldunif);
        try testing.expectEqual(@as(?u32, @intCast(i)), reload.uniform);
        try testing.expectEqual(&reload.link, read.link.prev.?);
    }
}
