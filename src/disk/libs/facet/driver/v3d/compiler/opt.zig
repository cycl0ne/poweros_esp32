// SPDX-License-Identifier: MIT
//! Mesa's optimizations of VIR, run on a program before its temporaries
//! are given registers: vir_optimize (vir.c:2907) and the seven passes it
//! runs until none of them makes progress, each a file of Mesa's
//! src/broadcom/compiler - vir_opt_copy_propagate.c,
//! vir_opt_redundant_flags.c, vir_opt_dead_code.c,
//! vir_opt_small_immediates.c, vir_opt_constant_alu.c, vir_opt_alu.c and
//! vir_opt_redundant_setnnmode.c - their 7.1 paths.
//!
//! What is 4.2's alone is left out: copy propagation's refusal of the
//! moves out of the accumulators, and the small immediate that 4.2 has
//! only in raddr_b. The debug prints go too.

const std = @import("std");
const assert = std.debug.assert;
const instr = @import("../qpu/instr.zig");
const pack = @import("../qpu/pack.zig");
const vir = @import("vir.zig");
const list = @import("list.zig");
const Compile = vir.Compile;
const Inst = vir.Inst;
const Block = vir.Block;
const Error = vir.Error;

/// vir_optimize (vir.c:2907): each pass in turn, and all of them again
/// while any of them made progress.
pub fn optimize(c: *Compile) Error!void {
    while (true) {
        var progress = false;
        progress = copyPropagate(c) or progress;
        progress = redundantFlags(c) or progress;
        progress = (try deadCode(c)) or progress;
        progress = smallImmediates(c) or progress;
        progress = (try constantAlu(c)) or progress;
        progress = alu(c) or progress;
        progress = redundantSetnnmode(c) or progress;
        if (!progress) break;
    }
}

// --- vir_opt_copy_propagate.c ------------------------------------------------

/// A move whose destination may be read as its operand
/// (is_copy_mov, vir_opt_copy_propagate.c:37).
fn isCopyMov(maybe: ?*const Inst) bool {
    const inst = maybe orelse return false;
    if (inst.qpu.kind != .alu or (inst.qpu.alu.mul.op != .fmov and inst.qpu.alu.mul.op != .mov)) return false;
    if (inst.dst.file != .temp) return false;
    if (inst.src[0].file != .temp) return false;
    if (inst.qpu.alu.add.output_pack != .none or inst.qpu.alu.mul.output_pack != .none) return false;
    if (inst.qpu.flags.ac != .none or inst.qpu.flags.mc != .none) return false;
    // The moves out of rf1 to rf3 are there for the liveness of W, the
    // centroid's W and Z. The operand is a temporary by now, so this is
    // never so; it is Mesa's all the same. rf0 is not among them: an
    // ldvary writes it without a temporary, which the register allocator
    // keeps every temporary off while the ldvary's is live.
    switch (inst.src[0].file) {
        .reg => switch (inst.src[0].index) {
            1, 2, 3 => return false,
            else => {},
        },
        else => {},
    }
    return true;
}

/// vir_has_unpack (vir_opt_copy_propagate.c:113).
fn hasUnpack(inst: *const Inst, chan: usize) bool {
    assert(chan == 0 or chan == 1);
    if (vir.isAdd(inst)) {
        return if (chan == 0) inst.qpu.alu.add.a.unpack != .none else inst.qpu.alu.add.b.unpack != .none;
    }
    return if (chan == 0) inst.qpu.alu.mul.a.unpack != .none else inst.qpu.alu.mul.b.unpack != .none;
}

/// Each operand of `inst` that a move made read as the move's own
/// operand (try_copy_prop, vir_opt_copy_propagate.c:131). A move is found
/// either as the one definition of an SSA value, whose operand is SSA
/// too, or among the moves seen in the block, whose operands nothing has
/// written since.
fn tryCopyProp(c: *Compile, inst: *Inst, movs: []?*Inst) bool {
    var progress = false;
    for (0..vir.getNsrc(inst)) |i| {
        if (inst.src[i].file != .temp) continue;
        const mov = movs[inst.src[i].index] orelse found: {
            const def = c.defs[inst.src[i].index];
            if (!isCopyMov(def)) continue;
            const d = def.?;
            if (d.src[0].file == .temp and c.defs[d.src[0].index] == null) continue;
            break :found d;
        };
        if (hasUnpack(mov, 0)) {
            // The unpack must mean the same in both.
            if (instr.unpacksF32(&inst.qpu) != instr.unpacksF32(&mov.qpu) or
                instr.unpacksF16(&inst.qpu) != instr.unpacksF16(&mov.qpu)) continue;
            // No unpack on an unpack.
            if (hasUnpack(inst, i)) continue;
            // These cannot take an absolute value.
            if (mov.qpu.alu.mul.a.unpack == .abs) {
                switch (inst.qpu.alu.add.op) {
                    .vfpack, .fround, .ftrunc, .ffloor, .fceil, .fdx, .fdy, .ftoin, .ftoiz, .ftouz, .ftoc => continue,
                    else => {},
                }
            }
            // These only fmov has. Mesa answers no progress here, for the
            // operands before this one too.
            switch (mov.qpu.alu.mul.a.unpack) {
                .sat, .nsat, .max0 => if (inst.qpu.alu.mul.op != .fmov) return false,
                else => {},
            }
        }
        inst.src[i] = mov.src[0];
        if (hasUnpack(mov, 0)) vir.setUnpack(inst, i, mov.qpu.alu.mul.a.unpack);
        progress = true;
    }
    return progress;
}

/// The moves a write to `inst`'s destination makes stale
/// (apply_kills, vir_opt_copy_propagate.c:239).
fn applyKills(c: *const Compile, movs: []?*Inst, inst: *const Inst) void {
    if (inst.dst.file != .temp) return;
    for (movs[0..c.num_temps]) |*each| {
        const mov = each.* orelse continue;
        if (mov.dst.index == inst.dst.index or (mov.src[0].file == .temp and mov.src[0].index == inst.dst.index)) each.* = null;
    }
}

/// vir_opt_copy_propagate (vir_opt_copy_propagate.c:254). Where its
/// table cannot be had, it makes no progress, as Mesa's does.
pub fn copyPropagate(c: *Compile) bool {
    var progress = false;
    const movs = c.allocator.alloc(?*Inst, c.num_temps) catch return false;
    defer c.allocator.free(movs);
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        // The moves seen in this block alone.
        @memset(movs, null);
        c.cur_block = block;
        var insts = vir.eachInst(block);
        while (insts.next()) |inst| {
            progress = tryCopyProp(c, inst, movs) or progress;
            applyKills(c, movs, inst);
            if (isCopyMov(inst)) movs[inst.dst.index] = inst;
        }
    }
    return progress;
}

// --- vir_opt_redundant_flags.c -----------------------------------------------

/// vir_dce_pf (vir_opt_redundant_flags.c:33).
fn dcePf(inst: *Inst) void {
    assert(inst.qpu.kind == .alu);
    inst.qpu.flags.apf = .none;
    inst.qpu.flags.mpf = .none;
}

/// `write` may have changed what `srcs` reads (vir_sources_modified,
/// vir_opt_redundant_flags.c:46). A register or a magic address is
/// taken to change with anything.
fn sourcesModified(srcs: *const Inst, write: *const Inst) bool {
    for (srcs.src[0..vir.getNsrc(srcs)]) |src| {
        if (write.dst.file == .temp and src.file == .temp and src.index == write.dst.index) return true;
        if (src.file != .temp and src.file != .small_imm) return true;
    }
    return false;
}

/// vir_instr_flags_op_equal (vir_opt_redundant_flags.c:66).
fn flagsOpEqual(a: *const Inst, b: *const Inst) bool {
    for (a.src[0..vir.getNsrc(a)], b.src[0..vir.getNsrc(a)]) |x, y| {
        if (x.file != y.file or x.index != y.index) return false;
    }
    const p = a.qpu;
    const q = b.qpu;
    return p.flags.apf == q.flags.apf and p.flags.mpf == q.flags.mpf and
        p.alu.add.op == q.alu.add.op and p.alu.mul.op == q.alu.mul.op and
        p.alu.add.a.unpack == q.alu.add.a.unpack and p.alu.add.b.unpack == q.alu.add.b.unpack and
        p.alu.add.output_pack == q.alu.add.output_pack and
        p.alu.mul.a.unpack == q.alu.mul.a.unpack and p.alu.mul.b.unpack == q.alu.mul.b.unpack and
        p.alu.mul.output_pack == q.alu.mul.output_pack;
}

/// vir_opt_redundant_flags_block (vir_opt_redundant_flags.c:92). Flags
/// are kept across a thread switch since 4.2.
fn redundantFlagsBlock(c: *Compile, block: *Block) bool {
    var last_flags: ?*Inst = null;
    var progress = false;
    c.cur_block = block;
    var insts = vir.eachInst(block);
    while (insts.next()) |inst| {
        if (inst.qpu.kind != .alu or inst.qpu.flags.auf != .none or inst.qpu.flags.muf != .none) {
            last_flags = null;
            continue;
        }
        if (inst.qpu.flags.apf != .none or inst.qpu.flags.mpf != .none) {
            if (last_flags != null and flagsOpEqual(inst, last_flags.?)) {
                dcePf(inst);
                progress = true;
            } else {
                last_flags = inst;
            }
        }
        if (last_flags) |flags| {
            if (sourcesModified(flags, inst)) last_flags = null;
        }
    }
    return progress;
}

/// vir_opt_redundant_flags (vir_opt_redundant_flags.c:138).
pub fn redundantFlags(c: *Compile) bool {
    var progress = false;
    var blocks = c.eachBlock();
    while (blocks.next()) |block| progress = redundantFlagsBlock(c, block) or progress;
    return progress;
}

// --- vir_opt_dead_code.c -----------------------------------------------------

/// dce (vir_opt_dead_code.c:42).
fn dce(c: *Compile, inst: *Inst) void {
    assert(!instr.writesFlags(&inst.qpu));
    c.removeInstruction(inst);
}

/// can_write_to_null (vir_opt_dead_code.c:53): an SFU operation must
/// write a register of the file.
fn canWriteToNull(inst: *const Inst) bool {
    return !instr.usesSfu(&inst.qpu);
}

/// vir_dce_flags (vir_opt_dead_code.c:63).
fn dceFlags(inst: *Inst) void {
    assert(inst.qpu.kind == .alu);
    inst.qpu.flags.apf = .none;
    inst.qpu.flags.mpf = .none;
    inst.qpu.flags.auf = .none;
    inst.qpu.flags.muf = .none;
}

fn isLdunifa(inst: *const Inst) bool {
    return inst.qpu.sig.ldunifa or inst.qpu.sig.ldunifarf;
}

fn writesUnifaReg(inst: *const Inst) bool {
    return inst.dst.file == .magic and inst.dst.index == @intFromEnum(instr.Waddr.unifa);
}

/// The ldunifa is the last of its sequence (check_last_ldunifa,
/// vir_opt_dead_code.c:79): a write to unifa comes after it before
/// another ldunifa does, or nothing does.
fn checkLastLdunifa(inst: *const Inst, block: *Block) bool {
    if (!isLdunifa(inst)) return false;
    var later = list.Each(Inst, "link", .forward){ .head = &block.instructions, .pos = inst.link.next.? };
    while (later.next()) |scan_inst| {
        if (writesUnifaReg(scan_inst)) return true;
        if (isLdunifa(scan_inst)) return false;
    }
    return true;
}

/// The ldunifa is the first of its sequence (check_first_ldunifa,
/// vir_opt_dead_code.c:105), and `unifa` the write that starts it.
fn checkFirstLdunifa(inst: *const Inst, block: *Block, unifa: *?*Inst) bool {
    if (!isLdunifa(inst)) return false;
    var earlier = list.Each(Inst, "link", .backward){ .head = &block.instructions, .pos = inst.link.prev.? };
    while (earlier.next()) |scan_inst| {
        if (writesUnifaReg(scan_inst)) {
            unifa.* = scan_inst;
            return true;
        }
        if (isLdunifa(scan_inst)) return false;
    }
    @panic("could not find starting unifa for ldunifa sequence");
}

/// The sequence's address moved on a word, for its first ldunifa to be
/// taken out (increment_unifa_address, vir_opt_dead_code.c:133).
fn incrementUnifaAddress(c: *Compile, unifa: *Inst) Error!bool {
    const unifa_reg = vir.magicReg(.unifa);
    if (unifa.qpu.kind == .alu and unifa.qpu.alu.mul.op == .mov) {
        c.cursor = vir.afterInst(unifa);
        _ = try c.addDest(.add, unifa_reg, .{ unifa.src[0], try c.uniformUi(4) });
        c.removeInstruction(unifa);
        return true;
    }
    if (unifa.qpu.kind == .alu and unifa.qpu.alu.add.op == .add) {
        c.cursor = vir.afterInst(unifa);
        const tmp = try c.add(.add, .{ unifa.src[1], try c.uniformUi(4) });
        _ = try c.addDest(.add, unifa_reg, .{ unifa.src[0], tmp });
        c.removeInstruction(unifa);
        return true;
    }
    return false;
}

/// vir_opt_dead_code (vir_opt_dead_code.c:158): every instruction whose
/// temporary nothing reads, and which does nothing besides, taken out; a
/// flags write that one after it hides dropped; and where an instruction
/// must stay for its flags or its place in an ldunifa sequence, the
/// destination nothing reads dropped from it.
pub fn deadCode(c: *Compile) Error!bool {
    var progress = false;
    const used = try c.allocator.alloc(bool, c.num_temps);
    defer c.allocator.free(used);
    @memset(used, false);

    // Defuse the check that the cursor's instruction is not removed: a
    // new cursor is set for anything emitted after this.
    c.cursor.link = null;

    var reads = c.eachInstInorder();
    while (reads.next()) |inst| {
        for (inst.src[0..vir.getNsrc(inst)]) |src| {
            if (src.file == .temp) used[src.index] = true;
        }
    }

    var last_multop: ?*Inst = null;
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        var last_flags_write: ?*Inst = null;
        c.cur_block = block;
        var insts = vir.eachInstSafe(block);
        while (insts.next()) |inst| {
            // The flags this reads must still be made for it.
            if (instr.readsFlags(&inst.qpu)) last_flags_write = null;
            if (inst.qpu.kind == .alu and inst.qpu.alu.mul.op == .multop) last_multop = inst;

            if (inst.dst.file != .null and !(inst.dst.file == .temp and !used[inst.dst.index])) continue;

            const is_ldunifa = isLdunifa(inst);
            if (vir.hasSideEffects(inst) and !is_ldunifa) continue;

            var is_first_ldunifa = false;
            var is_last_ldunifa = false;
            var unifa: ?*Inst = null;
            if (is_ldunifa) {
                is_last_ldunifa = checkLastLdunifa(inst, block);
                is_first_ldunifa = checkFirstLdunifa(inst, block, &unifa);
            }

            if (instr.writesFlags(&inst.qpu)) {
                // A flags write this one hides is dropped.
                if (last_flags_write) |hidden| {
                    if (inst.qpu.flags.apf != .none or inst.qpu.flags.mpf != .none) {
                        dceFlags(hidden);
                        progress = true;
                    }
                }
                last_flags_write = inst;
            }

            if (instr.writesFlags(&inst.qpu) or (is_ldunifa and !is_first_ldunifa and !is_last_ldunifa)) {
                // Kept, but not its destination: the allocator would
                // colour it at no cost, and the VIR reads better without.
                if (inst.dst.file == .temp and canWriteToNull(inst)) {
                    c.defs[inst.dst.index] = null;
                    inst.dst.file = .null;
                    progress = true;
                }
                continue;
            }

            // The first ldunifa of a sequence: the address moves on.
            if (is_first_ldunifa) {
                if (!try incrementUnifaAddress(c, unifa.?)) continue;
            }

            // An umul24 takes its multop with it.
            if (inst.qpu.kind == .alu and inst.qpu.alu.mul.op == .umul24) {
                if (last_multop) |multop| {
                    dce(c, multop);
                    last_multop = null;
                }
            }

            assert(inst != last_flags_write);
            dce(c, inst);
            progress = true;
        }
    }
    return progress;
}

// --- vir_opt_small_immediates.c ----------------------------------------------

/// vir_opt_small_immediates (vir_opt_small_immediates.c:42): an operand
/// loaded from a constant uniform that a small immediate can be, made
/// one, one an instruction. Since 7.x any operand may be the small
/// immediate. Only a fragment and a compute program have it: shader-db
/// finds the geometry stages longer for it.
pub fn smallImmediates(c: *Compile) bool {
    var progress = false;
    if (c.stage != .fragment and c.stage != .compute) return progress;

    var insts = c.eachInstInorder();
    while (insts.next()) |inst| {
        if (inst.qpu.kind != .alu) continue;
        const nsrc = vir.getNsrc(inst);

        var uses_small_imm = false;
        for (inst.src[0..nsrc]) |src| {
            if (src.file == .small_imm) uses_small_imm = true;
        }
        if (uses_small_imm) continue;

        for (0..nsrc) |i| {
            if (inst.src[i].file != .temp) continue;
            // A uniform load, of a constant.
            const src_def = c.defs[inst.src[i].index] orelse continue;
            if (!src_def.qpu.sig.ldunif) continue;
            const uniform = src_def.uniform.?;
            if (c.uniform_contents[uniform] != .constant) continue;

            const imm = c.uniform_data[uniform];
            const packed_imm = pack.smallImmPack(imm) orelse continue;

            // No signal already there that a small immediate cannot go
            // with.
            var new_sig = inst.qpu.sig;
            if (vir.isAdd(inst)) {
                if (i == 0) new_sig.small_imm_a = true else new_sig.small_imm_b = true;
            } else {
                if (i == 0) new_sig.small_imm_c = true else new_sig.small_imm_d = true;
            }
            if (pack.sigPack(new_sig) == null) continue;

            inst.qpu.sig.small_imm_a = new_sig.small_imm_a;
            inst.qpu.sig.small_imm_b = new_sig.small_imm_b;
            inst.qpu.sig.small_imm_c = new_sig.small_imm_c;
            inst.qpu.sig.small_imm_d = new_sig.small_imm_d;
            inst.qpu.raddr_b = packed_imm;
            inst.src[i] = .{ .file = .small_imm, .index = imm };
            progress = true;
            break;
        }
    }
    return progress;
}

// --- vir_opt_constant_alu.c --------------------------------------------------

/// The add of constant operands made a uniform load of its result, moved
/// to its destination (opt_constant_add, vir_opt_constant_alu.c:56). Of
/// the add side's operations, add and vfpack.
fn optConstantAdd(c: *Compile, inst: *Inst, values: [2]u32) Error!bool {
    const unif = switch (inst.qpu.alu.add.op) {
        .add => unif: {
            c.cursor = vir.afterInst(inst);
            break :unif try c.uniformUi(values[0] +% values[1]);
        },
        .vfpack => unif: {
            assert(inst.qpu.alu.add.output_pack == .none);
            const packed_halves = @as(u32, floatToHalf(values[1])) << 16 | floatToHalf(values[0]);
            c.cursor = vir.afterInst(inst);
            break :unif try c.uniformUi(packed_halves);
        },
        else => return false,
    };

    // A uniform the instruction loaded beside its work, a tile buffer
    // write's specifier, goes with the move.
    const dst = inst.dst;
    const mov = try c.mulDest(.mov, dst, .{unif});
    mov.uniform = inst.uniform;
    c.removeInstruction(inst);
    if (dst.file == .temp) c.defs[dst.index] = mov;
    return true;
}

/// _mesa_float_to_half: rounded to the nearest, ties to even.
fn floatToHalf(bits: u32) u16 {
    const f: f32 = @bitCast(bits);
    return @bitCast(@as(f16, @floatCast(f)));
}

/// try_opt_constant_alu (vir_opt_constant_alu.c:96).
fn tryOptConstantAlu(c: *Compile, inst: *Inst) Error!bool {
    if (inst.qpu.kind != .alu) return false;
    // Anything but the result written as it is: left.
    if (inst.qpu.alu.add.output_pack != .none or inst.qpu.alu.mul.output_pack != .none) return false;
    if (inst.qpu.flags.ac != .none or inst.qpu.flags.mc != .none) return false;

    const nsrc = vir.getNsrc(inst);
    assert(nsrc <= 2);
    var values: [2]u32 = undefined;
    for (0..nsrc) |i| {
        if (inst.src[i].file == .small_imm) {
            if (pack.smallImmUnpack(inst.qpu.raddr_b)) |value| {
                values[i] = value;
                continue;
            }
        }
        if (inst.src[i].file == .temp) {
            const def = c.defs[inst.src[i].index] orelse return false;
            if ((def.qpu.sig.ldunif or def.qpu.sig.ldunifrf) and c.uniform_contents[def.uniform.?] == .constant) {
                values[i] = c.uniform_data[def.uniform.?];
                continue;
            }
        }
        return false;
    }

    // The mul side's operations are not done.
    if (vir.isAdd(inst)) return optConstantAdd(c, inst, values);
    return false;
}

/// vir_opt_constant_alu (vir_opt_constant_alu.c:153).
pub fn constantAlu(c: *Compile) Error!bool {
    var progress = false;
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        c.cur_block = block;
        var insts = vir.eachInstSafe(block);
        while (insts.next()) |inst| progress = (try tryOptConstantAlu(c, inst)) or progress;
    }
    return progress;
}

// --- vir_opt_alu.c -----------------------------------------------------------

/// has_unpack_l (vir_opt_alu.c:32).
fn hasUnpackL(inst: *const Inst, chan: usize) bool {
    assert(chan == 0 or chan == 1);
    if (vir.isAdd(inst)) {
        return if (chan == 0) inst.qpu.alu.add.a.unpack == .l else inst.qpu.alu.add.b.unpack == .l;
    }
    return if (chan == 0) inst.qpu.alu.mul.a.unpack == .l else inst.qpu.alu.mul.b.unpack == .l;
}

/// The low half of a value shifted right by 16 read as the high half of
/// the value itself, so that the shift may go (try_opt_extract_h16,
/// vir_opt_alu.c:62): what NIR makes of a 16-bit extract once it has
/// replaced unpack_half_2x16_split_y with an f2f32. Mesa reads the
/// shift's count's definition without asking whether it has one; here
/// one that has none is passed over.
fn tryOptExtractH16(c: *Compile, inst: *Inst) bool {
    var progress = false;
    for (0..vir.getNsrc(inst)) |i| {
        if (inst.src[i].file != .temp) continue;
        if (!hasUnpackL(inst, i)) continue;
        // Made by a shift right by a constant 16.
        const shr_inst = c.defs[inst.src[i].index] orelse continue;
        if (shr_inst.qpu.alu.add.op != .shr) continue;
        if (shr_inst.src[1].file != .temp) continue;
        const unif_inst = c.defs[shr_inst.src[1].index] orelse continue;
        if (!unif_inst.qpu.sig.ldunif) continue;
        if (c.uniform_data[unif_inst.uniform.?] != 0x10) continue;

        inst.src[i] = shr_inst.src[0];
        vir.setUnpack(inst, i, .h);
        progress = true;
    }
    return progress;
}

/// vir_opt_alu (vir_opt_alu.c:111).
pub fn alu(c: *Compile) bool {
    var progress = false;
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        c.cur_block = block;
        var insts = vir.eachInstSafe(block);
        while (insts.next()) |inst| {
            if (inst.qpu.kind != .alu) continue;
            progress = tryOptExtractH16(c, inst) or progress;
        }
    }
    return progress;
}

// --- vir_opt_redundant_setnnmode.c -------------------------------------------

fn isSetnnmodeOp(op: instr.AddOp) bool {
    return switch (op) {
        .setnnmode_uu, .setnnmode_su, .setnnmode_us, .setnnmode_ss => true,
        else => false,
    };
}

/// A setnnmode of the mode a block is in already taken out
/// (vir_opt_redundant_setnnmode_block, vir_opt_redundant_setnnmode.c:51).
fn redundantSetnnmodeBlock(c: *Compile, block: *Block) bool {
    var progress = false;
    var current_mode: instr.AddOp = .nop;
    c.cur_block = block;
    var insts = vir.eachInstSafe(block);
    while (insts.next()) |inst| {
        if (inst.qpu.kind != .alu) continue;
        const op = inst.qpu.alu.add.op;
        if (!isSetnnmodeOp(op)) continue;
        if (op == current_mode) {
            c.removeInstruction(inst);
            progress = true;
        } else {
            current_mode = op;
        }
    }
    return progress;
}

/// vir_opt_redundant_setnnmode (vir_opt_redundant_setnnmode.c:77).
pub fn redundantSetnnmode(c: *Compile) bool {
    var progress = false;
    var blocks = c.eachBlock();
    while (blocks.next()) |block| progress = redundantSetnnmodeBlock(c, block) or progress;
    return progress;
}

const testing = std.testing;
const dump = @import("dump.zig");
const Reg = vir.Reg;

/// The program as vir_dump prints it, an instruction a line.
fn expectProgram(c: *const Compile, expected: []const []const u8) !void {
    var at: usize = 0;
    var insts = @constCast(c).eachInstInorder();
    while (insts.next()) |inst| : (at += 1) {
        var buffer: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buffer);
        try dump.inst(&w, c, inst);
        if (at >= expected.len) {
            std.debug.print("more than expected: {s}\n", .{w.buffered()});
            return error.TestUnexpectedResult;
        }
        try testing.expectEqualStrings(expected[at], w.buffered());
    }
    try testing.expectEqual(expected.len, at);
}

fn defOf(c: *const Compile, r: Reg) *Inst {
    return c.defs[r.index].?;
}

test "copy propagation reads a move's operand in its place, an fmov's unpack with it, and not a move out of the payload" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const one = try c.uniformF(1.0);
    const two = try c.uniformF(2.0);
    const moved = try c.mul(.mov, .{one});
    const sum = try c.add(.fadd, .{ moved, two });
    const low = try c.mul(.fmov, .{two});
    vir.setUnpack(defOf(c, low), 0, .l);
    const product = try c.mul(.fmul, .{ low, sum });
    const w = try c.mul(.mov, .{vir.reg(.reg, 3)});
    const scaled = try c.add(.fadd, .{ w, product });
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{scaled});

    try testing.expect(copyPropagate(c));
    try expectProgram(c, &.{
        "nop t0; ldunif (0x3f800000 / 1.000000)",
        "nop t1; ldunif (0x40000000 / 2.000000)",
        "mov t2, t0",
        "fadd t3, t0, t1",
        "fmov t4, t1.l",
        "fmul t5, t1.l, t3",
        "mov t6, rf3",
        "fadd t7, t6, t5",
        "mov tlb, t7",
    });
    // Nothing left to propagate; the moves nothing reads are dead code's.
    try testing.expect(!copyPropagate(c));
    try testing.expect(try deadCode(c));
    try expectProgram(c, &.{
        "nop t0; ldunif (0x3f800000 / 1.000000)",
        "nop t1; ldunif (0x40000000 / 2.000000)",
        "fadd t3, t0, t1",
        "fmul t5, t1.l, t3",
        "mov t6, rf3",
        "fadd t7, t6, t5",
        "mov tlb, t7",
    });
}

test "dead code: what nothing reads goes, an umul24 with its multop; what does something stays; a flags write loses its destination" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const one = try c.uniformF(1.0);
    _ = try c.add(.msf, .{});
    // An ldvary nothing reads: the hardware hands the varyings over in
    // order, so it stays, and so does its destination.
    const ld = try c.addInst(.nop, c.undef, c.undef, c.undef);
    ld.qpu.sig.ldvary = true;
    _ = try c.emitDef(ld);
    // A comparison whose difference nothing reads, for its flags.
    const compare = try c.add(.fsub, .{ one, one });
    c.setPf(defOf(c, compare), .pushz);
    _ = try c.umul(one, one);
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{one});

    try testing.expect(try deadCode(c));
    try expectProgram(c, &.{
        "nop t0; ldunif (0x3f800000 / 1.000000)",
        "nop t2; ldvary.rf0",
        "fsub.pushz null, t0, t0",
        "mov tlb, t0",
    });
    try testing.expect(!try deadCode(c));
}

test "dead code: a flags write the next one hides loses its flags, and then goes" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const one = try c.uniformF(1.0);
    const first = try c.addNodst(.fcmp, .{ one, one });
    c.setPf(first, .pushz);
    const second = try c.addNodst(.fcmp, .{ one, one });
    c.setPf(second, .pushn);
    _ = try c.movCond(.ifa, vir.magicReg(.tlb), one);

    try testing.expect(try deadCode(c));
    try expectProgram(c, &.{
        "nop t0; ldunif (0x3f800000 / 1.000000)",
        "fcmp null, t0, t0",
        "fcmp.pushn null, t0, t0",
        "mov.ifa tlb, t0",
    });
    try testing.expect(try deadCode(c));
    try expectProgram(c, &.{
        "nop t0; ldunif (0x3f800000 / 1.000000)",
        "fcmp.pushn null, t0, t0",
        "mov.ifa tlb, t0",
    });
}

test "small immediates: a constant uniform that one can be is made one, one an instruction" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const x = try c.uniformF(0.1);
    const one = try c.uniformF(1.0);
    const two = try c.uniformF(2.0);
    const sum = try c.add(.fadd, .{ x, one });
    const both = try c.add(.fadd, .{ one, two });
    const product = try c.mul(.fmul, .{ sum, both });
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{product});

    try testing.expect(smallImmediates(c));
    try expectProgram(c, &.{
        "nop t0; ldunif (0x3dcccccd / 0.100000)",
        "nop t1; ldunif (0x3f800000 / 1.000000)",
        "nop t2; ldunif (0x40000000 / 2.000000)",
        // 0.1 is not one of them; 1 is, and it is the add's second.
        "fadd t3, t0, 1.000000",
        // Its first is taken, and its second must stay a register.
        "fadd t4, 1.000000, t2",
        "fmul t5, t3, t4",
        "mov tlb, t5",
    });
    try testing.expect(defOf(c, sum).qpu.sig.small_imm_b);
    try testing.expect(defOf(c, both).qpu.sig.small_imm_a);
    try testing.expect(!smallImmediates(c));
}

test "constant alu: an add and a vfpack of constants become a uniform of the result, moved where they wrote" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const three = try c.uniformUi(3);
    const four = try c.uniformUi(4);
    const seven = try c.add(.add, .{ three, four });
    const one = try c.uniformF(1.0);
    const half = try c.uniformF(0.5);
    _ = try c.addDest(.vfpack, vir.magicReg(.tlb), .{ one, half });
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{seven});

    try testing.expect(try constantAlu(c));
    try expectProgram(c, &.{
        "nop t0; ldunif (0x00000003 / 0.000000)",
        "nop t1; ldunif (0x00000004 / 0.000000)",
        "nop t5; ldunif (0x00000007 / 0.000000)",
        "mov t2, t5",
        "nop t3; ldunif (0x3f800000 / 1.000000)",
        "nop t4; ldunif (0x3f000000 / 0.500000)",
        // 1 and 0.5 as half-floats, 0x3c00 and 0x3800, the first low.
        "nop t6; ldunif (0x38003c00 / 0.000031)",
        "mov tlb, t6",
        "mov tlb, t2",
    });
    try testing.expectEqual(defOf(c, seven).qpu.alu.mul.op, .mov);
}

test "alu: the low half of a shift right by 16 is read as the high half of what was shifted" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const pair = try c.ldtmu();
    const shifted = try c.add(.shr, .{ pair, try c.uniformUi(16) });
    const high = try c.mul(.fmov, .{shifted});
    vir.setUnpack(defOf(c, high), 0, .l);
    _ = try c.mulDest(.mov, vir.magicReg(.tlb), .{high});

    try testing.expect(alu(c));
    // The shift goes, and its count the pass after: a pass finds what is
    // read before it takes anything out, so a chain goes a link a pass.
    try testing.expect(try deadCode(c));
    try expectProgram(c, &.{
        "nop t0; ldtmu.rf0",
        "nop t1; ldunif (0x00000010 / 0.000000)",
        "fmov t3, t0.h",
        "mov tlb, t3",
    });
    try testing.expect(try deadCode(c));
    try expectProgram(c, &.{
        "nop t0; ldtmu.rf0",
        "fmov t3, t0.h",
        "mov tlb, t3",
    });
}

test "redundant flags: the same comparison pushed again over the same operands pushes nothing" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    const one = try c.uniformF(1.0);
    const two = try c.uniformF(2.0);
    c.setPf(try c.addNodst(.fcmp, .{ one, two }), .pushz);
    c.setPf(try c.addNodst(.fcmp, .{ one, two }), .pushz);
    _ = try c.movCond(.ifa, vir.magicReg(.tlb), one);
    // A register read is taken to change with anything after it.
    c.setPf(try c.addNodst(.fcmp, .{ vir.reg(.reg, 3), two }), .pushz);
    c.setPf(try c.addNodst(.fcmp, .{ vir.reg(.reg, 3), two }), .pushz);

    try testing.expect(redundantFlags(c));
    try expectProgram(c, &.{
        "nop t0; ldunif (0x3f800000 / 1.000000)",
        "nop t1; ldunif (0x40000000 / 2.000000)",
        "fcmp.pushz null, t0, t1",
        "fcmp null, t0, t1",
        "mov.ifa tlb, t0",
        "fcmp.pushz null, rf3, t1",
        "fcmp.pushz null, rf3, t1",
    });
}

test "redundant setnnmode: a mode set again in the block is not set again" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    _ = try c.addNodst(.setnnmode_ss, .{});
    _ = try c.addNodst(.setnnmode_ss, .{});
    _ = try c.addNodst(.setnnmode_uu, .{});
    _ = try c.addNodst(.setnnmode_ss, .{});

    try testing.expect(redundantSetnnmode(c));
    try expectProgram(c, &.{ "setnnmode_ss null", "setnnmode_uu null", "setnnmode_ss null" });
    try testing.expect(!redundantSetnnmode(c));
}

test "the passes run until none makes progress: a colour moved twice is packed from where it was made" {
    const c = try Compile.create(testing.allocator);
    defer c.destroy();
    _ = try c.add(.msf, .{});
    const w = try c.mul(.mov, .{vir.reg(.reg, 3)});
    _ = try c.mul(.mov, .{vir.reg(.reg, 1)});
    var floats: [4]Reg = undefined;
    for (&floats) |*float| {
        const ld = try c.addInst(.nop, c.undef, c.undef, c.undef);
        ld.qpu.sig.ldvary = true;
        float.* = try c.add(.fadd, .{ try c.mul(.fmul, .{ try c.emitDef(ld), w }), vir.reg(.reg, 0) });
    }
    var moved: [4]Reg = undefined;
    for (&moved, floats) |*out, float| out.* = try c.mul(.mov, .{try c.mul(.mov, .{float})});
    _ = try c.addDest(.vfpack, vir.magicReg(.tlb), .{ moved[0], moved[1] });
    _ = try c.addDest(.vfpack, vir.magicReg(.tlb), .{ moved[2], moved[3] });

    try optimize(c);
    try expectProgram(c, &.{
        "mov t1, rf3",
        "nop t3; ldvary.rf0",
        "fmul t4, t3, t1",
        "fadd t5, t4, rf0",
        "nop t6; ldvary.rf0",
        "fmul t7, t6, t1",
        "fadd t8, t7, rf0",
        "nop t9; ldvary.rf0",
        "fmul t10, t9, t1",
        "fadd t11, t10, rf0",
        "nop t12; ldvary.rf0",
        "fmul t13, t12, t1",
        "fadd t14, t13, rf0",
        "vfpack tlb, t5, t8",
        "vfpack tlb, t11, t14",
    });
}
