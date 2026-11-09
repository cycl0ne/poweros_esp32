// SPDX-License-Identifier: MIT
//! The QPU instruction port held to what is known of the encoding: Mesa's
//! own test rows (src/broadcom/qpu/tests/qpu_disasm.c), the words the
//! hand-written programs in `../qpu.zig` run on the board, and every
//! value of each field read back and packed again.

const std = @import("std");
const instr = @import("instr.zig");
const pack = @import("pack.zig");
const disasm = @import("disasm.zig");
const programs = @import("../qpu.zig");

const Sample = struct { word: u64, text: []const u8 };

/// Mesa's test rows of version 7.1.
const mesa_alu = [_]Sample{
    // 32-bit input unpacks
    .{ .word = 0x38000411f9190250, .text = "fmov rf17, rf9.sat            ; fmov rf16, rf6.sat" },
    .{ .word = 0x3800000af503f168, .text = "ffloor rf10, rf5.l            ; nop" },
    // small immediates
    .{ .word = 0x39c0000a3803f042, .text = "add rf10, 1, rf2              ; nop" },
    .{ .word = 0x39e0000b3c03f0de, .text = "sub rf11, rf3, -2             ; nop" },
    .{ .word = 0x57c00340bb105000, .text = "nop                           ; fmul rf13, 4, rf5" },
    .{ .word = 0x27e00380bb188000, .text = "nop                           ; smul24 rf14, rf6, 8" },
    // opcodes
    .{ .word = 0x2c000300bb042030, .text = "setnnmode_uu                  ; v8dot rf12, rf1, rf2" },
};

/// Mesa's branch rows. They are 4.2's, and a branch is packed and printed
/// by code that asks no version, so they hold for 7.1's as they are.
const mesa_branch = [_]Sample{
    .{ .word = 0x02000006002034c0, .text = "b.anyap  rf19" },
    .{ .word = 0x02679356b4201000, .text = "b.anyap  -1268280496" },
    .{ .word = 0x02b76a2dd0400000, .text = "b.anynaq  zero_addr+0xd0b76a28" },
    .{ .word = 0x0200000500402000, .text = "b.anynaq  lri" },
    .{ .word = 0x0216fe167301c8c0, .text = "bu.anya  zero_addr+0x7316fe10, rf35" },
    .{ .word = 0x020000050040e000, .text = "bu.anynaq  lri, r:unif" },
    .{ .word = 0x0200000300006000, .text = "bu.na0  lri, a:unif" },
};

/// Packs `word`'s instruction again, its operands swapped first where
/// their order is the opcode, as Mesa's test does to see the two told
/// apart.
fn repacked(word: u64) ?u64 {
    var inst = pack.unpack(word) orelse return null;
    if (inst.kind == .alu) switch (inst.alu.add.op) {
        .fadd, .faddnf, .fmin, .fmax => std.mem.swap(instr.Input, &inst.alu.add.a, &inst.alu.add.b),
        else => {},
    };
    return pack.pack(&inst);
}

fn expectSample(sample: Sample) !void {
    var buffer: [disasm.most_text]u8 = undefined;
    try std.testing.expectEqualStrings(sample.text, disasm.disasm(sample.word, &buffer).?);
    try std.testing.expectEqual(@as(?u64, sample.word), repacked(sample.word));
}

test "Mesa's 7.1 rows disassemble, and pack back, as its own test has them" {
    for (mesa_alu) |sample| try expectSample(sample);
    for (mesa_branch) |sample| try expectSample(sample);
}

/// Every word of every program written by hand, which the board runs.
const hand_written = [_][]const u64{
    &programs.coordinate_program,
    programs.vertexProgram(0),
    programs.vertexProgram(1),
    programs.vertexProgram(2),
    programs.vertexProgram(3),
    programs.vertexProgram(4),
    programs.vertexProgram(5),
    programs.vertexProgram(6),
    programs.vertexProgram(7),
    programs.vertexProgram(8),
    programs.flat_fragment.code,
    programs.color_fragment.code,
    programs.texture_fragment.code,
    programs.texture_color_fragment.code,
    programs.array_fragment.code,
    programs.volume_fragment.code,
    programs.cube_fragment.code,
};

test "every word the hand-written programs run on the board reads back, and packs again to itself" {
    var words: usize = 0;
    for (hand_written) |code| {
        for (code) |word| {
            try std.testing.expectEqual(@as(?u64, word), repacked(word));
            words += 1;
        }
    }
    try std.testing.expect(words > 100);
}

test "the hand-written programs' instructions disassemble as Mesa prints them" {
    const rows = [_]Sample{
        .{ .word = programs.nop, .text = "nop                           ; nop" },
        .{ .word = programs.thrsw, .text = "nop                           ; nop                         ; thrsw" },
        .{ .word = programs.ldunifrf(4), .text = "nop                           ; nop                         ; ldunifrf.rf4" },
        .{ .word = programs.ldvary(14), .text = "nop                           ; nop                         ; ldvary.rf14" },
        .{ .word = programs.ldtmu(10), .text = "nop                           ; nop                         ; ldtmu.rf10" },
        .{ .word = programs.wrtmuc, .text = "nop                           ; nop                         ; wrtmuc" },
        .{ .word = programs.movMagic(programs.WADDR_TLB, 4), .text = "mov tlb, rf4                  ; nop" },
        .{ .word = programs.movMagic(programs.WADDR_TMUSCM, 4), .text = "mov tmuscm, rf4               ; nop" },
        .{ .word = programs.ldvpmIn(9, 2), .text = "ldvpmv_in rf9, 2              ; nop" },
        .{ .word = programs.stvpm(2, 9), .text = "stvpmv 2, rf9                 ; nop" },
        .{ .word = programs.fmul(15, 14, 3), .text = "nop                           ; fmul rf15, rf14, rf3" },
        .{ .word = programs.fmulLow(6, 10, 6), .text = "nop                           ; fmul rf6, rf10.l, rf6" },
        .{ .word = programs.fmulHigh(7, 10, 7), .text = "nop                           ; fmul rf7, rf10.h, rf7" },
        .{ .word = programs.fadd(4, 15, 0), .text = "fadd rf4, rf0, rf15           ; nop" },
        .{ .word = programs.fmaxAbs(12, 4, 5), .text = "fmax rf12, rf5.abs, rf4.abs   ; nop" },
        .{ .word = programs.recip(13, 12), .text = "recip rf13, rf12              ; nop" },
        .{ .word = programs.vfpackMagic(programs.WADDR_TLB, 4, 5), .text = "vfpack tlb, rf4, rf5          ; nop" },
    };
    for (rows) |row| try expectSample(row);
}

test "the nop Mesa's compiler starts from is the hand-written programs' nop" {
    try std.testing.expectEqual(@as(?u64, programs.nop), pack.pack(&instr.nop));
    try std.testing.expect(instr.isNop(&pack.unpack(programs.nop).?));
}

/// The nop with one side's fields cleared, for a sweep to fill.
const OP_ADD_FIELDS: u64 = 0xFF << 24 | 0x3F << 32 | 1 << 44 | 0x3F << 6 | 0x3F;
const OP_MUL_FIELDS: u64 = 0x3F << 58 | 0x3F << 38 | 1 << 45 | 0x3F << 18 | 0x3F << 12;

/// The one-operand float operations whose unpack field, read as `abs`,
/// Mesa's unpack takes and its pack refuses (qpu_pack.c, "if (packed ==
/// 0) return false").
fn absNotPacked(inst: *const instr.Instr) bool {
    return switch (inst.alu.add.op) {
        .ffloor, .fround, .ftrunc, .fceil, .fdx, .fdy, .ftoin, .ftoiz, .ftouz, .ftoc => inst.alu.add.a.unpack == .abs,
        else => false,
    };
}

test "every add opcode and raddr_b that reads back packs again to itself, but for two of Mesa's own" {
    var read: u32 = 0;
    var refused: u32 = 0;
    var plain: u32 = 0;
    var seen = std.EnumSet(instr.AddOp).initEmpty();
    for (0..256) |op| {
        for (0..64) |raddr_b| {
            // raddr_a rf7, a register written: rf9.
            const word = (programs.nop & ~OP_ADD_FIELDS) | @as(u64, op) << 24 | 9 << 32 | 7 << 6 | @as(u64, raddr_b);
            const inst = pack.unpack(word) orelse continue;
            read += 1;
            seen.insert(inst.alu.add.op);
            if (pack.pack(&inst)) |again| {
                if (again == word) continue;
                // fxcd and fycd are three raddr_b values each, 32 to 34
                // and 36 to 38, which Mesa reads as the one operation and
                // packs as the first of them.
                try std.testing.expect(inst.alu.add.op == .fxcd or inst.alu.add.op == .fycd);
                try std.testing.expectEqual(word & ~@as(u64, 3), again);
                plain += 1;
            } else {
                try std.testing.expect(absNotPacked(&inst));
                refused += 1;
            }
        }
    }
    // Ten operations: the six with an output pack, in each of its three
    // forms, and the four with none.
    try std.testing.expectEqual(@as(u32, 6 * 3 + 4 * 1), refused);
    try std.testing.expectEqual(@as(u32, 2 * 2), plain);
    // What a word can say on the add side: all but what is written as
    // another (faddnf and fmax are only ever the order of fadd's and
    // fmin's operands, and the out forms of ldvpm want the magic bit) and
    // the stvpms not 0 (a waddr of 9 is none of them).
    for (std.enums.values(instr.AddOp)) |op| {
        const unreachable_here = switch (op) {
            .ldvpmv_out, .ldvpmd_out, .ldvpmg_out, .stvpmv, .stvpmd, .stvpmp, .vdwwt, .vpmsetup => true,
            else => false,
        };
        try std.testing.expectEqual(!unreachable_here, seen.contains(op));
    }
    try std.testing.expect(read > 4000);
}

test "every mul opcode and raddr_d that reads back packs again to itself" {
    var seen = std.EnumSet(instr.MulOp).initEmpty();
    for (1..64) |op| {
        for (0..64) |raddr_d| {
            const word = (programs.nop & ~OP_MUL_FIELDS) | @as(u64, op) << 58 | 9 << 38 | 7 << 18 | @as(u64, raddr_d) << 12;
            const inst = pack.unpack(word) orelse continue;
            seen.insert(inst.alu.mul.op);
            try std.testing.expectEqual(@as(?u64, word), pack.pack(&inst));
        }
    }
    for (std.enums.values(instr.MulOp)) |op| {
        // umul24_rtop0 packs as umul24, and so reads back as it.
        try std.testing.expectEqual(op != .umul24_rtop0, seen.contains(op));
    }
}

test "every signal code but the reserved ones reads back and packs again to itself" {
    for (0..32) |code| {
        const word = (programs.nop & ~(@as(u64, 0x1F) << 53)) | @as(u64, code) << 53;
        const reserved = code == 23 or code == 28 or code == 29;
        if (pack.unpack(word)) |inst| {
            try std.testing.expect(!reserved);
            try std.testing.expectEqual(@as(?u64, word), pack.pack(&inst));
        } else {
            try std.testing.expect(reserved);
        }
    }
}

test "every condition code but 0x10 reads back and packs again to itself" {
    for (0..128) |code| {
        const word = programs.nop | @as(u64, code) << 46;
        if (pack.unpack(word)) |inst| {
            try std.testing.expect(code != 0x10);
            try std.testing.expectEqual(@as(?u64, word), pack.pack(&inst));
        } else {
            try std.testing.expectEqual(@as(usize, 0x10), code);
        }
    }
}

test "a signal that writes a register keeps its address where the condition was" {
    var inst = instr.nop;
    inst.sig = .{ .ldtmu = true };
    inst.sig_addr = 11;
    const word = pack.pack(&inst).?;
    try std.testing.expectEqual(programs.ldtmu(11), word);
    // And has no room for a condition beside it.
    inst.flags.ac = .ifa;
    try std.testing.expectEqual(@as(?u64, null), pack.pack(&inst));
}

test "fadd and faddnf, fmin and fmax, are the order of the operands" {
    var inst = instr.nop;
    inst.alu.add = .{ .op = .fadd, .a = .{ .raddr = 9 }, .b = .{ .raddr = 3 }, .waddr = 4, .magic_write = false };
    const fadd = pack.pack(&inst).?;
    inst.alu.add.op = .faddnf;
    const faddnf = pack.pack(&inst).?;
    try std.testing.expect(fadd != faddnf);
    try std.testing.expectEqual(instr.AddOp.fadd, pack.unpack(fadd).?.alu.add.op);
    try std.testing.expectEqual(instr.AddOp.faddnf, pack.unpack(faddnf).?.alu.add.op);
    // Only the operands' order differs.
    try std.testing.expectEqual(fadd & ~@as(u64, 0xFFF), faddnf & ~@as(u64, 0xFFF));
    // With a small immediate, the signal swaps with the operands.
    inst.alu.add.op = .fmax;
    inst.sig = .{ .small_imm_a = true };
    inst.alu.add.a.raddr = pack.smallImmPack(@bitCast(@as(f32, 1.0))).?;
    const fmax = pack.pack(&inst).?;
    const back = pack.unpack(fmax).?;
    try std.testing.expectEqual(instr.AddOp.fmax, back.alu.add.op);
    try std.testing.expect(back.sig.small_imm_a != back.sig.small_imm_b);
}

test "a branch packs and reads back with its condition, its address and its uniforms" {
    const branches = [_]instr.Branch{
        .{ .cond = .always, .bdi = .rel, .offset = 64 },
        .{ .cond = .anyna, .msfign = .q, .bdi = .rel, .offset = @bitCast(@as(i32, -128)) },
        .{ .cond = .alla, .bdi = .abs, .ub = true, .bdu = .rel, .offset = 0x0012_3450 },
        .{ .cond = .na0, .bdi = .regfile, .raddr_a = 21 },
        .{ .cond = .a0, .bdi = .link_reg, .ub = true, .bdu = .regfile, .raddr_a = 5 },
    };
    for (branches) |each| {
        const inst = instr.Instr{ .kind = .branch, .branch = each };
        const word = pack.pack(&inst).?;
        const back = pack.unpack(word).?;
        try std.testing.expectEqual(instr.Kind.branch, back.kind);
        try std.testing.expectEqual(each.cond, back.branch.cond);
        try std.testing.expectEqual(each.msfign, back.branch.msfign);
        try std.testing.expectEqual(each.bdi, back.branch.bdi);
        try std.testing.expectEqual(each.ub, back.branch.ub);
        if (each.ub) try std.testing.expectEqual(each.bdu, back.branch.bdu);
        if (each.bdi == .abs or each.bdi == .rel) try std.testing.expectEqual(each.offset, back.branch.offset);
        if (each.bdi == .regfile or each.bdu == .regfile) try std.testing.expectEqual(each.raddr_a, back.branch.raddr_a);
        try std.testing.expectEqual(@as(?u64, word), pack.pack(&back));
    }
}

test "the small immediates are Mesa's 48" {
    try std.testing.expectEqual(@as(?u6, 0), pack.smallImmPack(0));
    try std.testing.expectEqual(@as(?u6, 15), pack.smallImmPack(15));
    try std.testing.expectEqual(@as(?u6, 16), pack.smallImmPack(@bitCast(@as(i32, -16))));
    try std.testing.expectEqual(@as(?u6, 31), pack.smallImmPack(@bitCast(@as(i32, -1))));
    try std.testing.expectEqual(@as(?u6, 40), pack.smallImmPack(@bitCast(@as(f32, 1.0))));
    try std.testing.expectEqual(@as(?u6, 47), pack.smallImmPack(@bitCast(@as(f32, 128.0))));
    try std.testing.expectEqual(@as(?u6, null), pack.smallImmPack(16));
    try std.testing.expectEqual(@as(?u32, null), pack.smallImmUnpack(48));
}
