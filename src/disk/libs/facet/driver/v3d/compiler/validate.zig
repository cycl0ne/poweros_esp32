// SPDX-License-Identifier: MIT
//! A QPU program of version 7.1 held to the hardware's instruction
//! restrictions: the port of Mesa's src/broadcom/compiler/qpu_validate.c,
//! its 7.1 paths. Mesa runs it after register allocation and scheduling,
//! over every block's instructions in order, and aborts at the first rule
//! broken, printing the program; this answers that rule and where, and
//! the caller decides what to print.
//!
//! What only 4.x has is left out: the accumulator r4 an SFU result came
//! back in, and the rules of 4.2 alone (LDVARY anywhere in a thread
//! switch's delay slots, any register write after the program's end
//! switch, GFXH-1633, GFXH-1625). On 7.1 an SFU operation is an add
//! opcode and its magic write addresses are reserved, so the SFU rules
//! below can only meet a program that writes one of those, which is
//! refused as such first.

const std = @import("std");
const instr = @import("../qpu/instr.zig");
const Instr = instr.Instr;

pub const Program = struct {
    insts: []const Instr,
    /// The first instruction that writes the depth to the tile buffer,
    /// where one does (Mesa's qinst.is_tlb_z_write).
    first_tlb_z_write: ?usize = null,
    /// The program ends with a last thread section, which two thread
    /// switches in a row open, as every fragment program here does; a
    /// program of one segment has none (Mesa's c->last_thrsw).
    last_thrsw: bool,
};

pub const Failure = struct {
    /// The instruction that broke the rule, or the program's length for
    /// what is found missing at its end.
    ip: usize,
    /// Mesa's own words for the rule.
    message: []const u8,
};

const State = struct {
    last: ?*const Instr = null,
    ip: i64 = 0,
    last_sfu_write: i64 = -10,
    last_branch_ip: i64 = -10,
    last_thrsw_ip: i64 = -10,
    first_tlb_z_write: i64 = std.math.maxInt(i64),
    /// Set at the last-thrsw signal, or from the start in a program of
    /// one segment.
    last_thrsw_found: bool,
    /// Set at the thread switch after the last one.
    thrend_found: bool = false,
    thrsw_count: u32 = 0,
    rtop_hazard: bool = false,
    rtop_valid: bool = false,
};

fn inBranchDelaySlots(state: *const State) bool {
    return state.ip - state.last_branch_ip < 4;
}

fn inThrswDelaySlots(state: *const State) bool {
    return state.ip - state.last_thrsw_ip < 3;
}

/// The reserved ranges of the magic write addresses on 7.x: 0 to 4, 10,
/// 14 and 15, 19 to 31, 47 to 54, 55 to 63.
fn v3d71MagicWaddrIsReserved(waddr: u6) bool {
    return waddr <= 4 or waddr == 10 or
        (waddr >= 14 and waddr <= 15) or
        (waddr >= 19 and waddr <= 31) or
        (waddr >= 47 and waddr <= 54) or
        (waddr >= 55 and waddr <= 63);
}

fn magicWaddrMatches(inst: *const Instr, comptime predicate: fn (u6) bool) bool {
    if (inst.kind != .alu) return false;
    if (inst.alu.add.op != .nop and inst.alu.add.magic_write and predicate(inst.alu.add.waddr)) return true;
    if (inst.alu.mul.op != .nop and inst.alu.mul.magic_write and predicate(inst.alu.mul.waddr)) return true;
    return false;
}

/// Mesa's vir_is_add and vir_is_mul: the side does something.
fn isAdd(inst: *const Instr) bool {
    return inst.kind == .alu and inst.alu.add.op != .nop;
}

fn isMul(inst: *const Instr) bool {
    return inst.kind == .alu and inst.alu.mul.op != .nop;
}

/// The magic writes of each kind an instruction makes.
const Writes = struct {
    tmu: u32 = 0,
    sfu: u32 = 0,
    vpm: u32 = 0,
    tlb: u32 = 0,
    tsy: u32 = 0,

    fn count(writes: *Writes, waddr: u6) void {
        if (instr.magicWaddrIsTmu(waddr)) writes.tmu += 1;
        if (instr.magicWaddrIsSfu(waddr)) writes.sfu += 1;
        if (instr.magicWaddrIsVpm(waddr)) writes.vpm += 1;
        if (instr.magicWaddrIsTlb(waddr)) writes.tlb += 1;
        if (instr.magicWaddrIsTsy(waddr)) writes.tsy += 1;
    }
};

fn validateInst(state: *State, inst: *const Instr, is_tlb_z_write: bool) ?[]const u8 {
    if (is_tlb_z_write and state.ip < state.first_tlb_z_write) state.first_tlb_z_write = state.ip;

    const after_tlb_z_write = state.first_tlb_z_write >= 0 and state.ip > state.first_tlb_z_write;

    if (inst.kind == .branch and after_tlb_z_write and
        inst.branch.msfign != .none and
        inst.branch.cond != .always and inst.branch.cond != .a0 and inst.branch.cond != .na0)
    {
        return "Implicit branch MSF read after TLB Z write";
    }

    if (inst.kind == .branch) {
        if (inBranchDelaySlots(state)) return "branch in a branch delay slot.";
        if (inThrswDelaySlots(state)) return "branch in a THRSW delay slot.";
        state.last_branch_ip = state.ip;
        return null;
    }

    if (inst.alu.mul.op == .multop) {
        // An unconditional branch may have its delay slots filled with a
        // copy of the first instructions of the block it goes to, and a
        // walk in order would see a hazard that is not there where the
        // MULTOP was copied and the UMUL24 was not.
        if (!inBranchDelaySlots(state)) state.rtop_valid = true;
    }

    if (inst.alu.mul.op == .umul24) {
        if (state.rtop_hazard) return "UMUL24 reads rtop from MULTOP but it got cleared by a previous THRSW";
        state.rtop_valid = false;
        state.rtop_hazard = false;
    }

    if (inst.alu.add.op == .setmsf and after_tlb_z_write) return "SETMSF after TLB Z write";
    if (after_tlb_z_write and inst.alu.add.op == .msf) return "MSF read after TLB Z write";

    if ((inst.sig.small_imm_a or inst.sig.small_imm_b) and !isAdd(inst)) return "small imm a/b used but no ADD inst";
    if ((inst.sig.small_imm_c or inst.sig.small_imm_d) and !isMul(inst)) return "small imm c/d used but no MUL inst";
    if (@as(u32, @intFromBool(inst.sig.small_imm_a)) + @intFromBool(inst.sig.small_imm_b) +
        @intFromBool(inst.sig.small_imm_c) + @intFromBool(inst.sig.small_imm_d) > 1)
    {
        return "only one small immediate can be enabled per instruction";
    }

    // LDVARY writes its register two instructions later and LDUNIF one,
    // which is illegal to have together.
    if (state.last) |last| {
        if (last.sig.ldvary and (inst.sig.ldunif or inst.sig.ldunifa)) return "LDUNIF after a LDVARY";
    }

    var writes = Writes{};
    if (inst.alu.add.op != .nop and inst.alu.add.magic_write) writes.count(inst.alu.add.waddr);
    if (inst.alu.mul.op != .nop and inst.alu.mul.magic_write) writes.count(inst.alu.mul.waddr);

    if (inThrswDelaySlots(state)) {
        // An SFU started in the delay slots would land in the other
        // thread.
        if (writes.sfu != 0) return "SFU write started during THRSW delay slots ";
        if (inst.sig.ldvary and state.ip - state.last_thrsw_ip == 2) return "LDVARY in 2nd THRSW delay slot";
    }

    if (magicWaddrMatches(inst, v3d71MagicWaddrIsReserved)) return "write to a reserved magic waddr";

    if (state.ip - state.last_sfu_write < 2) {
        if (writes.sfu != 0) return "SFU write too soon after SFU";
    }

    // Mesa notes that the documents allow the VPM with the others and
    // the simulator does not.
    if (writes.tmu + writes.sfu + writes.vpm + writes.tlb + writes.tsy +
        @as(u32, @intFromBool(inst.sig.ldtlb)) + @intFromBool(inst.sig.ldvpm) + @intFromBool(inst.sig.ldtlbu) > 1)
    {
        return "Only one of [TMU, SFU, TSY, TLB read, VPM] allowed";
    }

    if (writes.sfu != 0) state.last_sfu_write = state.ip;

    if (inst.sig.thrsw) {
        if (inBranchDelaySlots(state)) return "THRSW in a branch delay slot.";

        if (state.last_thrsw_found) state.thrend_found = true;

        if (state.last_thrsw_ip == state.ip - 1) {
            // The second of two in a row is the last-thrsw signal.
            if (state.last_thrsw_found) return "Two last-THRSW signals";
            state.last_thrsw_found = true;
        } else {
            if (inThrswDelaySlots(state)) return "THRSW too close to another THRSW.";
            state.thrsw_count += 1;
            state.last_thrsw_ip = state.ip;
        }
    }

    if (state.thrend_found and state.ip - state.last_thrsw_ip <= 2 and inst.kind == .alu) {
        if (inst.alu.add.op != .nop and !inst.alu.add.magic_write) {
            if (state.last_thrsw_ip - state.ip == 0) return "ADD RF write at THREND";
            if (inst.alu.add.waddr == 2 or inst.alu.add.waddr == 3) return "RF2-3 write after THREND";
        }
        if (inst.alu.mul.op != .nop and !inst.alu.mul.magic_write) {
            if (state.last_thrsw_ip - state.ip == 0) return "MUL RF write at THREND";
            if (inst.alu.mul.waddr == 2 or inst.alu.mul.waddr == 3) return "RF2-3 write after THREND";
        }
        if (instr.sigWritesAddress(inst.sig) and !inst.sig_magic and (inst.sig_addr == 2 or inst.sig_addr == 3)) {
            return "RF2-3 write after THREND";
        }
    }

    if (state.rtop_valid and state.ip == state.last_thrsw_ip + 2) {
        state.rtop_hazard = true;
        state.rtop_valid = false;
    }
    return null;
}

/// The first of the instruction restrictions ("Summary of Instruction
/// Restrictions") the program breaks, or null where it keeps them all
/// (Mesa's qpu_validate).
pub fn validate(program: Program) ?Failure {
    var state = State{ .last_thrsw_found = !program.last_thrsw };
    for (program.insts, 0..) |*inst, at| {
        const is_tlb_z_write = if (program.first_tlb_z_write) |first| at == first else false;
        if (validateInst(&state, inst, is_tlb_z_write)) |message| return .{ .ip = at, .message = message };
        state.last = inst;
        state.ip += 1;
    }

    const end = program.insts.len;
    if (state.thrsw_count > 1 and !state.last_thrsw_found) {
        return .{ .ip = end, .message = "thread switch found without last-THRSW in program" };
    }
    if (!state.thrend_found) return .{ .ip = end, .message = "No program-end THRSW found" };
    return null;
}

const testing = std.testing;
const pack = @import("../qpu/pack.zig");
const programs = @import("../qpu.zig");

/// A program of words, each unpacked.
fn unpacked(words: []const u64, into: []Instr) []const Instr {
    for (words, into[0..words.len]) |word, *inst| inst.* = pack.unpack(word).?;
    return into[0..words.len];
}

/// The program keeps every rule, or the test says which it broke.
fn expectKept(program: Program) !void {
    if (validate(program)) |failure| {
        std.debug.print("broken at {d}: {s}\n", .{ failure.ip, failure.message });
        return error.TestUnexpectedFailure;
    }
}

test "every program written by hand keeps the restrictions Mesa holds a program to" {
    var buffer: [64]Instr = undefined;
    // The binner's and the renderer's vertex programs are one segment.
    try expectKept(.{ .insts = unpacked(&programs.coordinate_program, &buffer), .last_thrsw = false });
    for (0..programs.most_varyings + 1) |varyings| {
        try expectKept(.{ .insts = unpacked(programs.vertexProgram(@intCast(varyings)), &buffer), .last_thrsw = false });
    }
    // Every fragment program has its last section.
    const fragments = [_]programs.Fragment{ programs.flat_fragment, programs.color_fragment, programs.texture_fragment, programs.texture_color_fragment, programs.array_fragment, programs.volume_fragment, programs.cube_fragment };
    for (fragments) |fragment| {
        try expectKept(.{ .insts = unpacked(fragment.code, &buffer), .last_thrsw = true });
    }
}

fn expectBroken(insts: []const Instr, last_thrsw: bool, ip: usize, message: []const u8) !void {
    const failure = validate(.{ .insts = insts, .last_thrsw = last_thrsw }) orelse return error.TestExpectedFailure;
    try testing.expectEqualStrings(message, failure.message);
    try testing.expectEqual(ip, failure.ip);
}

const nop = instr.nop;
const thrsw = Instr{ .sig = .{ .thrsw = true } };

fn ldvary(to: u6) Instr {
    return .{ .sig = .{ .ldvary = true }, .sig_addr = to };
}

/// A float add of two registers into another, or into a magic address.
fn fadd(waddr: u6, magic_write: bool) Instr {
    return .{ .alu = .{ .add = .{ .op = .fadd, .a = .{ .raddr = 4 }, .b = .{ .raddr = 5 }, .waddr = waddr, .magic_write = magic_write } } };
}

test "the end of a program, and the thread switches before it" {
    try expectBroken(&.{ nop, nop }, false, 2, "No program-end THRSW found");
    try expectBroken(&.{ nop, thrsw, nop, thrsw, nop, nop }, false, 3, "THRSW too close to another THRSW.");
    try expectBroken(&.{ thrsw, nop, nop, nop, thrsw, nop, nop }, true, 7, "thread switch found without last-THRSW in program");
    try expectBroken(&.{ thrsw, thrsw, nop, nop, thrsw, thrsw, nop, nop }, true, 5, "Two last-THRSW signals");
    // What the end switch and its two delay slots may not write.
    try expectBroken(&.{ fadd(4, false), thrsw, fadd(2, false), nop }, false, 2, "RF2-3 write after THREND");
    var at_end = fadd(4, false);
    at_end.sig.thrsw = true;
    try expectBroken(&.{ nop, at_end, nop, nop }, false, 1, "ADD RF write at THREND");
    // A magic write is no register, and may be made there.
    var magic_at_end = fadd(instr.magic(.tlb), true);
    magic_at_end.sig.thrsw = true;
    try expectKept(.{ .insts = &.{ nop, magic_at_end, nop, nop }, .last_thrsw = false });
}

test "the signals and the magic writes an instruction may make" {
    try expectBroken(&.{ thrsw, nop, ldvary(4), nop, nop }, false, 2, "LDVARY in 2nd THRSW delay slot");
    try expectBroken(&.{ ldvary(4), .{ .sig = .{ .ldunif = true } }, thrsw, nop, nop }, false, 1, "LDUNIF after a LDVARY");
    try expectBroken(&.{ fadd(19, true), thrsw, nop, nop }, false, 0, "write to a reserved magic waddr");
    var two = fadd(instr.magic(.tmut), true);
    two.alu.mul = .{ .op = .mov, .a = .{ .raddr = 4 }, .waddr = instr.magic(.tlb), .magic_write = true };
    try expectBroken(&.{ two, thrsw, nop, nop }, false, 0, "Only one of [TMU, SFU, TSY, TLB read, VPM] allowed");
    try expectBroken(&.{ .{ .sig = .{ .small_imm_a = true } }, thrsw, nop, nop }, false, 0, "small imm a/b used but no ADD inst");
    try expectBroken(&.{ thrsw, .{ .kind = .branch }, nop, nop }, false, 1, "branch in a THRSW delay slot.");
}
