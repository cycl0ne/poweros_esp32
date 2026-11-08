// SPDX-License-Identifier: MIT
//! A QPU instruction of version 7.1 to its 64 bits and back.
//!
//! A port of Mesa's src/broadcom/qpu/qpu_pack.c, of its 7.1 paths alone:
//! the signal map, the small immediates, the condition field, the add and
//! mul opcode tables, and the pack and unpack of each side and of a
//! branch. Each answers null where Mesa's answers false, which is an
//! instruction that has no encoding, or a word that is none.
//!
//! An opcode on 7.1 is the opcode field together with an operand field:
//! an operation of no second operand is told apart by the raddr it would
//! have read (raddr_b on the add side, raddr_d on the mul side), and a
//! float operation of one operand keeps its output pack and its input
//! unpack there. FADD and FADDNF, and FMIN and FMAX, share their opcodes
//! and are told apart by the order of their two operands.

const std = @import("std");
const instr = @import("instr.zig");
const Instr = instr.Instr;
const Sig = instr.Sig;
const Flags = instr.Flags;
const AddOp = instr.AddOp;
const MulOp = instr.MulOp;
const InputUnpack = instr.InputUnpack;
const OutputPack = instr.OutputPack;

const Field = struct { shift: u6, mask: u64 };

fn field(comptime high: u6, comptime low: u6) Field {
    const width = @as(u7, high) - low + 1;
    const ones: u64 = if (width == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(width)) - 1;
    return .{ .shift = low, .mask = ones << low };
}

const OP_MUL = field(63, 58);
const SIG = field(57, 53);
const COND = field(52, 46);
const COND_SIG_MAGIC_ADDR: u32 = 1 << 6;
const MM: u64 = 1 << 45;
const MA: u64 = 1 << 44;
const WADDR_M = field(43, 38);
const BRANCH_ADDR_LOW = field(55, 35);
const WADDR_A = field(37, 32);
const BRANCH_COND = field(34, 32);
const BRANCH_ADDR_HIGH = field(31, 24);
const OP_ADD = field(31, 24);
const BRANCH_MSFIGN = field(22, 21);
const RADDR_C = field(23, 18);
const BRANCH_BDU = field(17, 15);
const BRANCH_UB: u64 = 1 << 14;
const BRANCH_BDI = field(13, 12);
const RADDR_D = field(17, 12);
const RADDR_A = field(11, 6);
const RADDR_B = field(5, 0);

fn get(word: u64, comptime f: Field) u32 {
    return @intCast((word & f.mask) >> f.shift);
}

/// `value` in field `f`, which it has to fit (Mesa's QPU_SET_FIELD).
fn set(value: u64, comptime f: Field) u64 {
    const placed = value << f.shift;
    std.debug.assert(placed & ~f.mask == 0);
    return placed & f.mask;
}

/// The signals each of the 32 codes of the signal field carries on 7.1.
/// 23, 28 and 29 are reserved, and so carry none: a code of no signals
/// other than 0 does not unpack.
const sig_map = blk: {
    var map = [_]Sig{.{}} ** 32;
    map[1] = .{ .thrsw = true };
    map[2] = .{ .ldunif = true };
    map[3] = .{ .thrsw = true, .ldunif = true };
    map[4] = .{ .ldtmu = true };
    map[5] = .{ .thrsw = true, .ldtmu = true };
    map[6] = .{ .ldtmu = true, .ldunif = true };
    map[7] = .{ .thrsw = true, .ldtmu = true, .ldunif = true };
    map[8] = .{ .ldvary = true };
    map[9] = .{ .thrsw = true, .ldvary = true };
    map[10] = .{ .ldvary = true, .ldunif = true };
    map[11] = .{ .thrsw = true, .ldvary = true, .ldunif = true };
    map[12] = .{ .ldunifrf = true };
    map[13] = .{ .thrsw = true, .ldunifrf = true };
    map[14] = .{ .small_imm_a = true };
    map[15] = .{ .small_imm_b = true };
    map[16] = .{ .ldtlb = true };
    map[17] = .{ .ldtlbu = true };
    map[18] = .{ .wrtmuc = true };
    map[19] = .{ .thrsw = true, .wrtmuc = true };
    map[20] = .{ .ldvary = true, .wrtmuc = true };
    map[21] = .{ .thrsw = true, .ldvary = true, .wrtmuc = true };
    map[22] = .{ .ucb = true };
    map[24] = .{ .ldunifa = true };
    map[25] = .{ .ldunifarf = true };
    map[26] = .{ .ldtmu = true, .wrtmuc = true };
    map[27] = .{ .thrsw = true, .ldtmu = true, .wrtmuc = true };
    map[30] = .{ .small_imm_c = true };
    map[31] = .{ .small_imm_d = true };
    break :blk map;
};

pub fn sigUnpack(packed_sig: u32) ?Sig {
    if (packed_sig >= sig_map.len) return null;
    const sig = sig_map[packed_sig];
    if (packed_sig != 0 and sig.eql(.{})) return null;
    return sig;
}

pub fn sigPack(sig: Sig) ?u32 {
    for (sig_map, 0..) |each, code| {
        if (each.eql(sig)) return @intCast(code);
    }
    return null;
}

/// The values a small immediate may be: -16 to 15, and the powers of two
/// from 2^-8 to 2^7 as floats.
const small_immediates = [48]u32{
    0,                       1,                       2,                       3,
    4,                       5,                       6,                       7,
    8,                       9,                       10,                      11,
    12,                      13,                      14,                      15,
    @bitCast(@as(i32, -16)), @bitCast(@as(i32, -15)), @bitCast(@as(i32, -14)), @bitCast(@as(i32, -13)),
    @bitCast(@as(i32, -12)), @bitCast(@as(i32, -11)), @bitCast(@as(i32, -10)), @bitCast(@as(i32, -9)),
    @bitCast(@as(i32, -8)),  @bitCast(@as(i32, -7)),  @bitCast(@as(i32, -6)),  @bitCast(@as(i32, -5)),
    @bitCast(@as(i32, -4)),  @bitCast(@as(i32, -3)),  @bitCast(@as(i32, -2)),  @bitCast(@as(i32, -1)),
    0x3b800000, // 2.0^-8
    0x3c000000, // 2.0^-7
    0x3c800000, // 2.0^-6
    0x3d000000, // 2.0^-5
    0x3d800000, // 2.0^-4
    0x3e000000, // 2.0^-3
    0x3e800000, // 2.0^-2
    0x3f000000, // 2.0^-1
    0x3f800000, // 2.0^0
    0x40000000, // 2.0^1
    0x40800000, // 2.0^2
    0x41000000, // 2.0^3
    0x41800000, // 2.0^4
    0x42000000, // 2.0^5
    0x42800000, // 2.0^6
    0x43000000, // 2.0^7
};

pub fn smallImmUnpack(packed_small_immediate: u32) ?u32 {
    if (packed_small_immediate >= small_immediates.len) return null;
    return small_immediates[packed_small_immediate];
}

pub fn smallImmPack(value: u32) ?u6 {
    for (small_immediates, 0..) |each, code| {
        if (each == value) return @intCast(code);
    }
    return null;
}

pub fn flagsUnpack(packed_cond: u32) ?Flags {
    const cond_map = [4]instr.Cond{ .ifa, .ifb, .ifna, .ifnb };
    var cond = Flags{};
    if (packed_cond == 0) {
        return cond;
    } else if (packed_cond >> 2 == 0) {
        cond.apf = @enumFromInt(packed_cond & 0x3);
    } else if (packed_cond >> 4 == 0) {
        cond.auf = uf(packed_cond);
    } else if (packed_cond == 0x10) {
        return null;
    } else if (packed_cond >> 2 == 0x4) {
        cond.mpf = @enumFromInt(packed_cond & 0x3);
    } else if (packed_cond >> 4 == 0x1) {
        cond.muf = uf(packed_cond);
    } else if (packed_cond >> 4 == 0x2) {
        cond.ac = @enumFromInt(((packed_cond >> 2) & 0x3) + @intFromEnum(instr.Cond.ifa));
        cond.mpf = @enumFromInt(packed_cond & 0x3);
    } else if (packed_cond >> 4 == 0x3) {
        cond.mc = @enumFromInt(((packed_cond >> 2) & 0x3) + @intFromEnum(instr.Cond.ifa));
        cond.apf = @enumFromInt(packed_cond & 0x3);
    } else if (packed_cond >> 6 != 0) {
        cond.mc = cond_map[(packed_cond >> 4) & 0x3];
        if ((packed_cond >> 2) & 0x3 == 0) {
            cond.ac = cond_map[packed_cond & 0x3];
        } else {
            cond.auf = uf(packed_cond);
        }
    }
    return cond;
}

/// An update of the flags from the low four bits of the field, 4 to 15.
fn uf(packed_cond: u32) instr.Uf {
    return @enumFromInt((packed_cond & 0xf) - 4 + @intFromEnum(instr.Uf.andz));
}

pub fn flagsPack(cond: Flags) ?u32 {
    const AC = 1 << 0;
    const MC = 1 << 1;
    const APF = 1 << 2;
    const MPF = 1 << 3;
    const AUF = 1 << 4;
    const MUF = 1 << 5;
    const Row = struct { flags_present: u8, bits: u32 };
    const flags_table = [_]Row{
        .{ .flags_present = 0, .bits = 0 },
        .{ .flags_present = APF, .bits = 0 },
        .{ .flags_present = AUF, .bits = 0 },
        .{ .flags_present = MPF, .bits = 1 << 4 },
        .{ .flags_present = MUF, .bits = 1 << 4 },
        .{ .flags_present = AC, .bits = 1 << 5 },
        .{ .flags_present = AC | MPF, .bits = 1 << 5 },
        .{ .flags_present = MC, .bits = (1 << 5) | (1 << 4) },
        .{ .flags_present = MC | APF, .bits = (1 << 5) | (1 << 4) },
        .{ .flags_present = MC | AC, .bits = 1 << 6 },
        .{ .flags_present = MC | AUF, .bits = 1 << 6 },
    };

    var flags_present: u8 = 0;
    if (cond.ac != .none) flags_present |= AC;
    if (cond.mc != .none) flags_present |= MC;
    if (cond.apf != .none) flags_present |= APF;
    if (cond.mpf != .none) flags_present |= MPF;
    if (cond.auf != .none) flags_present |= AUF;
    if (cond.muf != .none) flags_present |= MUF;

    const ifa = @intFromEnum(instr.Cond.ifa);
    for (flags_table) |row| {
        if (row.flags_present != flags_present) continue;

        var packed_cond = row.bits;
        packed_cond |= @intFromEnum(cond.apf);
        packed_cond |= @intFromEnum(cond.mpf);

        if (flags_present & AUF != 0) packed_cond |= @as(u32, @intFromEnum(cond.auf)) - @intFromEnum(instr.Uf.andz) + 4;
        if (flags_present & MUF != 0) packed_cond |= @as(u32, @intFromEnum(cond.muf)) - @intFromEnum(instr.Uf.andz) + 4;

        if (flags_present & AC != 0) {
            if (packed_cond & (1 << 6) != 0) {
                packed_cond |= @as(u32, @intFromEnum(cond.ac)) - ifa;
            } else {
                packed_cond |= (@as(u32, @intFromEnum(cond.ac)) - ifa) << 2;
            }
        }

        if (flags_present & MC != 0) {
            if (packed_cond & (1 << 6) != 0) {
                packed_cond |= (@as(u32, @intFromEnum(cond.mc)) - ifa) << 4;
            } else {
                packed_cond |= (@as(u32, @intFromEnum(cond.mc)) - ifa) << 2;
            }
        }

        return packed_cond;
    }
    return null;
}

/// An operation, the opcodes it lies at, and the raddr values that make it
/// that operation (Mesa's struct opcode_desc, raddr_mask). Every row of
/// Mesa's 7.1 tables holds from 7.1 on, so the versions are left out.
fn Desc(comptime Op: type) type {
    return struct {
        first: u8,
        last: u8,
        raddr_mask: u64,
        op: Op,
    };
}

fn bit(comptime n: u6) u64 {
    return @as(u64, 1) << n;
}

/// raddr values `bot` to `top` (Mesa's OP_RANGE).
fn range(comptime bot: u6, comptime top: u6) u64 {
    const count = @as(u7, top) - bot + 1;
    const ones: u64 = if (count == 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(count)) - 1;
    return ones << bot;
}

const any: u64 = ~@as(u64, 0);

fn a(first: u8, last: u8, raddr_mask: u64, op: AddOp) Desc(AddOp) {
    return .{ .first = first, .last = last, .raddr_mask = raddr_mask, .op = op };
}

fn m(first: u8, last: u8, raddr_mask: u64, op: MulOp) Desc(MulOp) {
    return .{ .first = first, .last = last, .raddr_mask = raddr_mask, .op = op };
}

const add_ops = [_]Desc(AddOp){
    // FADD is FADDNF depending on the order of raddr_a and raddr_b.
    a(0, 47, any, .fadd),
    a(0, 47, any, .faddnf),
    a(48, 52, any, .vfadd),
    a(53, 55, any, .vfpack),
    a(56, 56, any, .add),
    a(57, 59, any, .vfpack),
    a(60, 60, any, .sub),
    a(61, 63, any, .vfpack),
    a(64, 111, any, .fsub),
    a(112, 119, any, .vfsub),
    a(120, 120, any, .min),
    a(121, 121, any, .max),
    a(122, 122, any, .umin),
    a(123, 123, any, .umax),
    a(124, 124, any, .shl),
    a(125, 125, any, .shr),
    a(126, 126, any, .asr),
    a(127, 127, any, .ror),
    // FMIN is FMAX depending on the order of raddr_a and raddr_b.
    a(128, 175, any, .fmin),
    a(128, 175, any, .fmax),
    a(176, 180, any, .vfmin),

    a(181, 181, any, .@"and"),
    a(182, 182, any, .@"or"),
    a(183, 183, any, .xor),
    a(184, 184, any, .vadd),
    a(185, 185, any, .vsub),

    a(186, 186, bit(0), .not),
    a(186, 186, bit(1), .neg),
    a(186, 186, bit(2), .flapush),
    a(186, 186, bit(3), .flbpush),
    a(186, 186, bit(4), .flpop),
    a(186, 186, bit(5), .clz),
    a(186, 186, bit(6), .setmsf),
    a(186, 186, bit(7), .setrevf),

    a(187, 187, bit(0), .nop),
    a(187, 187, bit(1), .tidx),
    a(187, 187, bit(2), .eidx),
    a(187, 187, bit(3), .lr),
    a(187, 187, bit(4), .vfla),
    a(187, 187, bit(5), .vflna),
    a(187, 187, bit(6), .vflb),
    a(187, 187, bit(7), .vflnb),
    a(187, 187, bit(8), .xcd),
    a(187, 187, bit(9), .ycd),
    a(187, 187, bit(10), .msf),
    a(187, 187, bit(11), .revf),
    a(187, 187, bit(12), .iid),
    a(187, 187, bit(13), .sampid),
    a(187, 187, bit(14), .barrierid),
    a(187, 187, bit(15), .tmuwt),
    a(187, 187, bit(16), .vpmwt),
    a(187, 187, bit(17), .flafirst),
    a(187, 187, bit(18), .flnafirst),

    a(187, 187, range(32, 34), .fxcd),
    a(187, 187, range(36, 38), .fycd),

    a(187, 187, bit(48), .setnnmode_uu),
    a(187, 187, bit(49), .setnnmode_su),
    a(187, 187, bit(50), .setnnmode_us),
    a(187, 187, bit(51), .setnnmode_ss),

    a(188, 188, bit(0), .ldvpmv_in),
    a(188, 188, bit(1), .ldvpmd_in),
    a(188, 188, bit(2), .ldvpmp),

    a(188, 188, bit(32), .recip),
    a(188, 188, bit(33), .rsqrt),
    a(188, 188, bit(34), .exp),
    a(188, 188, bit(35), .log),
    a(188, 188, bit(36), .sin),
    a(188, 188, bit(37), .rsqrt2),
    a(188, 188, bit(38), .ballot),
    a(188, 188, bit(39), .bcastf),
    a(188, 188, bit(40), .alleq),
    a(188, 188, bit(41), .allfeq),

    a(189, 189, any, .ldvpmg_in),

    // The stvpms are told apart by the waddr field.
    a(190, 190, any, .stvpmv),
    a(190, 190, any, .stvpmd),
    a(190, 190, any, .stvpmp),

    // Op 191's raddr_b 0 to 15 says what is done to each half's sign:
    // bit 0 the low half's set, bit 1 the low half's flipped, bits 2 and 3
    // the high half's likewise. The four that treat the two halves alike
    // are named; the mixed ones are not.
    a(191, 191, bit(0), .vfmov),
    a(191, 191, bit(5), .vfabs),
    a(191, 191, bit(10), .vfneg),
    a(191, 191, bit(15), .vfnab),

    a(192, 207, any, .fcmp),
    a(208, 215, any, .vfcmp),
    a(240, 244, any, .vfmax),

    a(245, 245, range(0, 2), .fround),
    a(245, 245, range(4, 6), .fround),
    a(245, 245, range(8, 10), .fround),
    a(245, 245, range(12, 14), .fround),

    a(245, 245, bit(3), .ftoin),
    a(245, 245, bit(7), .ftoin),
    a(245, 245, bit(11), .ftoin),
    a(245, 245, bit(15), .ftoin),

    a(245, 245, range(16, 18), .ftrunc),
    a(245, 245, range(20, 22), .ftrunc),
    a(245, 245, range(24, 26), .ftrunc),
    a(245, 245, range(28, 30), .ftrunc),

    a(245, 245, bit(19), .ftoiz),
    a(245, 245, bit(23), .ftoiz),
    a(245, 245, bit(27), .ftoiz),
    a(245, 245, bit(31), .ftoiz),

    a(245, 245, range(32, 34), .ffloor),
    a(245, 245, range(36, 38), .ffloor),
    a(245, 245, range(40, 42), .ffloor),
    a(245, 245, range(44, 46), .ffloor),

    a(245, 245, bit(35), .ftouz),
    a(245, 245, bit(39), .ftouz),
    a(245, 245, bit(43), .ftouz),
    a(245, 245, bit(47), .ftouz),

    a(245, 245, range(48, 50), .fceil),
    a(245, 245, range(52, 54), .fceil),
    a(245, 245, range(56, 58), .fceil),
    a(245, 245, range(60, 62), .fceil),

    a(245, 245, bit(51), .ftoc),
    a(245, 245, bit(55), .ftoc),
    a(245, 245, bit(59), .ftoc),
    a(245, 245, bit(63), .ftoc),

    a(246, 246, range(0, 2), .fdx),
    a(246, 246, range(4, 6), .fdx),
    a(246, 246, range(8, 10), .fdx),
    a(246, 246, range(12, 14), .fdx),
    a(246, 246, range(16, 18), .fdy),
    a(246, 246, range(20, 22), .fdy),
    a(246, 246, range(24, 26), .fdy),
    a(246, 246, range(28, 30), .fdy),

    a(246, 246, range(32, 34), .itof),
    a(246, 246, range(36, 38), .utof),

    a(247, 247, any, .vpack),
    a(248, 248, any, .v8pack),

    a(249, 249, range(0, 2), .fmov),
    a(249, 249, range(4, 6), .fmov),
    a(249, 249, range(8, 10), .fmov),
    a(249, 249, range(12, 14), .fmov),
    a(249, 249, range(16, 18), .fmov),
    a(249, 249, range(20, 22), .fmov),
    a(249, 249, range(24, 26), .fmov),

    a(249, 249, bit(3), .mov),
    a(249, 249, bit(7), .mov),
    a(249, 249, bit(11), .mov),
    a(249, 249, bit(15), .mov),
    a(249, 249, bit(19), .mov),

    a(250, 250, any, .v10pack),
    a(251, 251, any, .v11fpack),

    a(252, 252, any, .rotq),
    a(253, 253, any, .rot),
    a(254, 254, any, .shuffle),
};

const mul_ops = [_]Desc(MulOp){
    m(1, 1, any, .add),
    m(2, 2, any, .sub),
    m(3, 3, any, .umul24),
    m(3, 3, any, .umul24_rtop0),
    m(4, 8, any, .vfmul),
    m(9, 9, any, .smul24),
    m(10, 10, any, .multop),

    m(11, 11, any, .v8dot),

    m(14, 14, range(0, 2), .fmov),
    m(14, 14, range(4, 6), .fmov),
    m(14, 14, range(8, 10), .fmov),
    m(14, 14, range(12, 14), .fmov),
    m(14, 14, range(16, 18), .fmov),
    m(14, 14, range(20, 22), .fmov),
    m(14, 14, range(24, 26), .fmov),
    m(14, 14, range(28, 30), .fmov),

    m(14, 14, bit(3), .mov),
    m(14, 14, bit(7), .mov),
    m(14, 14, bit(11), .mov),
    m(14, 14, bit(15), .mov),
    m(14, 14, bit(19), .mov),

    m(14, 14, bit(32), .ftounorm16),
    m(14, 14, bit(33), .ftosnorm16),
    m(14, 14, bit(34), .vftounorm8),
    m(14, 14, bit(35), .vftosnorm8),
    m(14, 14, bit(36), .funpackunormlo),
    m(14, 14, bit(37), .funpackunormhi),
    m(14, 14, bit(38), .funpacksnormlo),
    m(14, 14, bit(39), .funpacksnormhi),
    m(14, 14, bit(48), .vftounorm10lo),
    m(14, 14, bit(49), .vftounorm10hi),

    m(14, 14, bit(63), .nop),

    m(16, 63, any, .fmul),
};

fn lookupOpcodeFromPacked(comptime Op: type, opcodes: []const Desc(Op), opcode: u32, raddr: u32) ?Desc(Op) {
    for (opcodes) |op_desc| {
        if (opcode < op_desc.first or opcode > op_desc.last) continue;
        if (op_desc.raddr_mask & (@as(u64, 1) << @intCast(raddr)) == 0) continue;
        return op_desc;
    }
    return null;
}

fn lookupOpcodeFromInstr(comptime Op: type, opcodes: []const Desc(Op), op: Op) ?Desc(Op) {
    for (opcodes) |op_desc| {
        if (op_desc.op == op) return op_desc;
    }
    return null;
}

fn float32UnpackUnpack(packed_unpack: u32) ?InputUnpack {
    return switch (packed_unpack) {
        0 => .abs,
        1 => .none,
        2 => .l,
        3 => .h,
        4 => .sat,
        5 => .nsat,
        6 => .max0,
        else => null,
    };
}

fn float32UnpackPack(unpacked: InputUnpack) ?u32 {
    return switch (unpacked) {
        .abs => 0,
        .none => 1,
        .l => 2,
        .h => 3,
        .sat => 4,
        .nsat => 5,
        .max0 => 6,
        else => null,
    };
}

fn int32UnpackUnpack(packed_unpack: u32) ?InputUnpack {
    return switch (packed_unpack) {
        0 => .none,
        1 => .ul,
        2 => .uh,
        3 => .il,
        4 => .ih,
        else => null,
    };
}

fn int32UnpackPack(unpacked: InputUnpack) ?u32 {
    return switch (unpacked) {
        .none => 0,
        .ul => 1,
        .uh => 2,
        .il => 3,
        .ih => 4,
        else => null,
    };
}

fn float16UnpackUnpack(packed_unpack: u32) ?InputUnpack {
    return switch (packed_unpack) {
        0 => .none,
        1 => .replicate_32f_16,
        2 => .replicate_l_16,
        3 => .replicate_h_16,
        4 => .swap_16,
        else => null,
    };
}

fn float16UnpackPack(unpacked: InputUnpack) ?u32 {
    return switch (unpacked) {
        .none => 0,
        .replicate_32f_16 => 1,
        .replicate_l_16 => 2,
        .replicate_h_16 => 3,
        .swap_16 => 4,
        else => null,
    };
}

fn float32PackPack(pack_value: OutputPack) u32 {
    return switch (pack_value) {
        .none => 0,
        .l => 1,
        .h => 2,
    };
}

fn addUnpack(packed_inst: u64, inst: *Instr) bool {
    const op = get(packed_inst, OP_ADD);
    const raddr_a = get(packed_inst, RADDR_A);
    const raddr_b = get(packed_inst, RADDR_B);
    const waddr = get(packed_inst, WADDR_A);

    const desc = lookupOpcodeFromPacked(AddOp, &add_ops, op, raddr_b) orelse return false;
    const add = &inst.alu.add;
    add.op = desc.op;

    // FADD and FADDNF, FMIN and FMAX, are told apart by the order of the
    // operands.
    if (@as(u32, @intFromBool(inst.sig.small_imm_a)) * 256 + ((op >> 2) & 3) * 64 + raddr_a >
        @as(u32, @intFromBool(inst.sig.small_imm_b)) * 256 + (op & 3) * 64 + raddr_b)
    {
        if (add.op == .fmin) add.op = .fmax;
        if (add.op == .fadd) add.op = .faddnf;
    }

    // Some need more than the opcode and the raddr to be told apart.
    switch (add.op) {
        .stvpmv, .stvpmd, .stvpmp => add.op = switch (waddr) {
            0 => .stvpmv,
            1 => .stvpmd,
            2 => .stvpmp,
            else => return false,
        },
        else => {},
    }

    switch (add.op) {
        .fadd, .faddnf, .fsub, .fmin, .fmax, .fcmp, .vfpack => {
            if (add.op != .vfpack and add.op != .fcmp) {
                add.output_pack = @enumFromInt((op >> 4) & 0x3);
            } else {
                add.output_pack = .none;
            }
            add.a.unpack = float32UnpackUnpack((op >> 2) & 0x3) orelse return false;
            add.b.unpack = float32UnpackUnpack((op >> 0) & 0x3) orelse return false;
        },
        .ffloor, .fround, .ftrunc, .fceil, .fdx, .fdy => {
            add.output_pack = @enumFromInt(raddr_b & 0x3);
            add.a.unpack = float32UnpackUnpack((raddr_b >> 2) & 0x3) orelse return false;
        },
        .ftoin, .ftoiz, .ftouz, .ftoc => {
            add.output_pack = .none;
            add.a.unpack = float32UnpackUnpack((raddr_b >> 2) & 0x3) orelse return false;
        },
        .itof, .utof => {
            add.output_pack = @enumFromInt(raddr_b & 0x3);
            add.a.unpack = .none;
        },
        .vfmin, .vfmax, .vfadd => {
            if (op & 0x7 > 4) return false;
            add.a.unpack = float16UnpackUnpack(op & 0x7) orelse return false;
            add.output_pack = .none;
            add.b.unpack = .none;
        },
        .vfsub, .vfcmp => {
            // Mesa leaves the three new 2x16f input unpacks of 7.1 to do.
            if (op & 0x7 > 4) return false;
            add.a.unpack = float16UnpackUnpack(op & 0x7) orelse return false;
            add.output_pack = .none;
            add.b.unpack = .none;
        },
        .vfmov, .vfabs, .vfneg, .vfnab => {
            add.output_pack = .none;
            add.a.unpack = .none;
            add.b.unpack = .none;
        },
        .mov => {
            add.output_pack = .none;
            add.a.unpack = int32UnpackUnpack((raddr_b >> 2) & 0x7) orelse return false;
        },
        .fmov => {
            add.output_pack = @enumFromInt(raddr_b & 0x3);
            // The mul side's fmov has one more form.
            const form = (raddr_b >> 2) & 0x7;
            if (form == 7) return false;
            add.a.unpack = float32UnpackUnpack(form) orelse return false;
        },
        else => {
            add.output_pack = .none;
            add.a.unpack = .none;
            add.b.unpack = .none;
        },
    }

    add.a.raddr = @intCast(raddr_a);
    add.b.raddr = @intCast(raddr_b);
    add.waddr = @intCast(waddr);

    add.magic_write = false;
    if (packed_inst & MA != 0) {
        switch (add.op) {
            .ldvpmv_in => add.op = .ldvpmv_out,
            .ldvpmd_in => add.op = .ldvpmd_out,
            .ldvpmg_in => add.op = .ldvpmg_out,
            else => add.magic_write = true,
        }
    }
    return true;
}

fn mulUnpack(packed_inst: u64, inst: *Instr) bool {
    const op = get(packed_inst, OP_MUL);
    const raddr_c = get(packed_inst, RADDR_C);
    const raddr_d = get(packed_inst, RADDR_D);

    const desc = lookupOpcodeFromPacked(MulOp, &mul_ops, op, raddr_d) orelse return false;
    const mul = &inst.alu.mul;
    mul.op = desc.op;

    switch (mul.op) {
        .fmul => {
            mul.output_pack = @enumFromInt(((op >> 4) & 0x3) - 1);
            mul.a.unpack = float32UnpackUnpack((op >> 2) & 0x3) orelse return false;
            mul.b.unpack = float32UnpackUnpack((op >> 0) & 0x3) orelse return false;
        },
        .fmov => {
            mul.output_pack = @enumFromInt(raddr_d & 0x3);
            mul.a.unpack = float32UnpackUnpack((raddr_d >> 2) & 0x7) orelse return false;
        },
        .vfmul => {
            mul.output_pack = .none;
            mul.a.unpack = float16UnpackUnpack(((op & 0x7) -% 4) & 7) orelse return false;
            mul.b.unpack = .none;
        },
        .mov => {
            mul.output_pack = .none;
            mul.a.unpack = int32UnpackUnpack((raddr_d >> 2) & 0x7) orelse return false;
        },
        else => {
            mul.output_pack = .none;
            mul.a.unpack = .none;
            mul.b.unpack = .none;
        },
    }

    mul.a.raddr = @intCast(raddr_c);
    mul.b.raddr = @intCast(raddr_d);
    mul.waddr = @intCast(get(packed_inst, WADDR_M));
    mul.magic_write = packed_inst & MM != 0;
    return true;
}

fn addPack(inst: *const Instr, packed_instr: *u64) bool {
    const add = &inst.alu.add;
    var waddr: u32 = add.waddr;
    var raddr_a: u32 = add.a.raddr;
    var raddr_b: u32 = add.b.raddr;

    const nsrc = instr.addOpNumSrc(add.op);
    const desc = lookupOpcodeFromInstr(AddOp, &add_ops, add.op) orelse return false;

    var opcode: u32 = desc.first;

    // An operation that does not read an operand may be told apart by the
    // raddr it would have read.
    if (nsrc < 2) raddr_b = @ctz(desc.raddr_mask);

    var no_magic_write = false;

    switch (add.op) {
        .stvpmv => {
            waddr = 0;
            no_magic_write = true;
        },
        .stvpmd => {
            waddr = 1;
            no_magic_write = true;
        },
        .stvpmp => {
            waddr = 2;
            no_magic_write = true;
        },
        .ldvpmv_in, .ldvpmd_in, .ldvpmp, .ldvpmg_in => std.debug.assert(!add.magic_write),
        .ldvpmv_out, .ldvpmd_out, .ldvpmg_out => {
            std.debug.assert(!add.magic_write);
            packed_instr.* |= MA;
        },
        else => {},
    }

    switch (add.op) {
        .fadd, .faddnf, .fsub, .fmin, .fmax, .fcmp => {
            if (add.op != .fcmp) opcode |= float32PackPack(add.output_pack) << 4;

            var a_unpack = float32UnpackPack(add.a.unpack) orelse return false;
            var b_unpack = float32UnpackPack(add.b.unpack) orelse return false;

            // These, whose operands commute, are told apart by the order
            // the operands come in.
            const ordering = @as(u32, @intFromBool(inst.sig.small_imm_a)) * 256 + a_unpack * 64 + raddr_a >
                @as(u32, @intFromBool(inst.sig.small_imm_b)) * 256 + b_unpack * 64 + raddr_b;
            if (((add.op == .fmin or add.op == .fadd) and ordering) or
                ((add.op == .fmax or add.op == .faddnf) and !ordering))
            {
                std.mem.swap(u32, &a_unpack, &b_unpack);
                std.mem.swap(u32, &raddr_a, &raddr_b);

                // Swapping raddr_a and raddr_b swaps small_imm_a and
                // small_imm_b with them.
                if (inst.sig.small_imm_a or inst.sig.small_imm_b) {
                    std.debug.assert(inst.sig.small_imm_a != inst.sig.small_imm_b);
                    var new_sig = inst.sig;
                    new_sig.small_imm_a = !inst.sig.small_imm_a;
                    new_sig.small_imm_b = !inst.sig.small_imm_b;
                    const sig = sigPack(new_sig) orelse return false;
                    packed_instr.* &= ~SIG.mask;
                    packed_instr.* |= set(sig, SIG);
                }
            }

            opcode |= a_unpack << 2;
            opcode |= b_unpack << 0;
        },
        .vfpack => {
            if (add.a.unpack == .abs or add.b.unpack == .abs) return false;
            const a_unpack = float32UnpackPack(add.a.unpack) orelse return false;
            const b_unpack = float32UnpackPack(add.b.unpack) orelse return false;
            opcode = (opcode & ~@as(u32, 0x3 << 2)) | (a_unpack << 2);
            opcode = (opcode & ~@as(u32, 0x3 << 0)) | (b_unpack << 0);
        },
        .ffloor, .fround, .ftrunc, .fceil, .fdx, .fdy => {
            raddr_b |= float32PackPack(add.output_pack);
            const unpacked = float32UnpackPack(add.a.unpack) orelse return false;
            if (unpacked == 0) return false;
            // As Mesa's: an unpack past h does not fit the two bits it is
            // given, and lands in the next form's.
            raddr_b = (raddr_b & ~@as(u32, 0x3 << 2)) | unpacked << 2;
        },
        .ftoin, .ftoiz, .ftouz, .ftoc => {
            if (add.output_pack != .none) return false;
            const unpacked = float32UnpackPack(add.a.unpack) orelse return false;
            if (unpacked == 0) return false;
            raddr_b |= (raddr_b & ~@as(u32, 0x3 << 2)) | unpacked << 2;
        },
        .itof, .utof => {
            if (add.a.unpack != .none) return false;
            raddr_b |= float32PackPack(add.output_pack);
        },
        .vfmin, .vfmax, .vfsub, .vfadd, .vfcmp => {
            if (add.output_pack != .none or add.b.unpack != .none) return false;
            opcode |= float16UnpackPack(add.a.unpack) orelse return false;
        },
        .vfmov, .vfabs, .vfneg, .vfnab => {
            if (add.output_pack != .none or add.a.unpack != .none or add.b.unpack != .none) return false;
        },
        .mov => {
            if (add.output_pack != .none) return false;
            raddr_b |= (int32UnpackPack(add.a.unpack) orelse return false) << 2;
        },
        .fmov => {
            raddr_b = float32PackPack(add.output_pack);
            raddr_b |= (float32UnpackPack(add.a.unpack) orelse return false) << 2;
        },
        else => {
            if (add.op != .nop and (add.output_pack != .none or add.a.unpack != .none or add.b.unpack != .none)) return false;
        },
    }

    packed_instr.* |= set(raddr_a, RADDR_A);
    packed_instr.* |= set(raddr_b, RADDR_B);
    packed_instr.* |= set(opcode, OP_ADD);
    packed_instr.* |= set(waddr, WADDR_A);
    if (add.magic_write and !no_magic_write) packed_instr.* |= MA;
    return true;
}

fn mulPack(inst: *const Instr, packed_instr: *u64) bool {
    const mul = &inst.alu.mul;
    const raddr_c: u32 = mul.a.raddr;
    var raddr_d: u32 = mul.b.raddr;
    const nsrc = instr.mulOpNumSrc(mul.op);

    const desc = lookupOpcodeFromInstr(MulOp, &mul_ops, mul.op) orelse return false;
    var opcode: u32 = desc.first;

    // Some have one raddr_d that is theirs; where it carries a packing, it
    // is set below.
    if (nsrc < 2) raddr_d = @ctz(desc.raddr_mask);

    switch (mul.op) {
        .fmul => {
            // No +1, as the first opcode has a 1 in this field already.
            opcode += float32PackPack(mul.output_pack) << 4;
            opcode |= (float32UnpackPack(mul.a.unpack) orelse return false) << 2;
            opcode |= (float32UnpackPack(mul.b.unpack) orelse return false) << 0;
        },
        .fmov => {
            raddr_d |= float32PackPack(mul.output_pack);
            raddr_d |= (float32UnpackPack(mul.a.unpack) orelse return false) << 2;
        },
        .vfmul => {
            if (mul.output_pack != .none) return false;
            const unpacked = float16UnpackPack(mul.a.unpack) orelse return false;
            if (mul.a.unpack == .swap_16) {
                opcode = 8;
            } else {
                opcode |= (unpacked + 4) & 7;
            }
            if (mul.b.unpack != .none) return false;
        },
        .mov => {
            if (mul.output_pack != .none) return false;
            raddr_d |= (int32UnpackPack(mul.a.unpack) orelse return false) << 2;
        },
        else => {
            if (mul.op != .nop and (mul.output_pack != .none or mul.a.unpack != .none or mul.b.unpack != .none)) return false;
        },
    }

    packed_instr.* |= set(raddr_c, RADDR_C);
    packed_instr.* |= set(raddr_d, RADDR_D);
    packed_instr.* |= set(opcode, OP_MUL);
    packed_instr.* |= set(mul.waddr, WADDR_M);
    if (mul.magic_write) packed_instr.* |= MM;
    return true;
}

fn unpackAlu(packed_instr: u64) ?Instr {
    var inst = Instr{ .kind = .alu };
    inst.sig = sigUnpack(get(packed_instr, SIG)) orelse return null;

    const packed_cond = get(packed_instr, COND);
    if (instr.sigWritesAddress(inst.sig)) {
        inst.sig_addr = @intCast(packed_cond & ~COND_SIG_MAGIC_ADDR);
        inst.sig_magic = packed_cond & COND_SIG_MAGIC_ADDR != 0;
        inst.flags = .{};
    } else {
        inst.flags = flagsUnpack(packed_cond) orelse return null;
    }

    // On 7.1 the raddrs are the operands' own, which the sides' unpack
    // sets; the instruction's are kept as Mesa keeps them.
    inst.raddr_a = @intCast(get(packed_instr, RADDR_A));
    inst.raddr_b = @intCast(get(packed_instr, RADDR_B));

    if (!addUnpack(packed_instr, &inst)) return null;
    if (!mulUnpack(packed_instr, &inst)) return null;
    return inst;
}

fn unpackBranch(packed_instr: u64) ?Instr {
    var inst = Instr{ .kind = .branch };
    const branch = &inst.branch;

    // 0 is always, and 2 to 7 are a0 to allna. Mesa's arithmetic reads 1
    // as always too (A0 + (1 - 2) wraps to 0), and so does this.
    const cond = get(packed_instr, BRANCH_COND);
    branch.cond = if (cond < 2) .always else @enumFromInt(@intFromEnum(instr.BranchCond.a0) + (cond - 2));

    const msfign = get(packed_instr, BRANCH_MSFIGN);
    if (msfign == 3) return null;
    branch.msfign = @enumFromInt(msfign);

    branch.bdi = @enumFromInt(get(packed_instr, BRANCH_BDI));

    branch.ub = packed_instr & BRANCH_UB != 0;
    if (branch.ub) branch.bdu = @enumFromInt(get(packed_instr, BRANCH_BDU));

    branch.raddr_a = @intCast(get(packed_instr, RADDR_A));

    branch.offset = 0;
    branch.offset +%= get(packed_instr, BRANCH_ADDR_LOW) << 3;
    branch.offset +%= get(packed_instr, BRANCH_ADDR_HIGH) << 24;
    return inst;
}

/// The instruction a word is, or null where it is none.
pub fn unpack(packed_instr: u64) ?Instr {
    if (get(packed_instr, OP_MUL) != 0) return unpackAlu(packed_instr);
    const sig = get(packed_instr, SIG);
    if (sig & 24 == 16) return unpackBranch(packed_instr);
    return null;
}

fn packAlu(inst: *const Instr) ?u64 {
    var packed_instr: u64 = 0;
    const sig = sigPack(inst.sig) orelse return null;
    packed_instr |= set(sig, SIG);

    if (!addPack(inst, &packed_instr)) return null;
    if (!mulPack(inst, &packed_instr)) return null;

    var flags: u32 = undefined;
    if (instr.sigWritesAddress(inst.sig)) {
        const none = inst.flags;
        if (none.ac != .none or none.mc != .none or none.apf != .none or none.mpf != .none or none.auf != .none or none.muf != .none) return null;
        flags = inst.sig_addr;
        if (inst.sig_magic) flags |= COND_SIG_MAGIC_ADDR;
    } else {
        flags = flagsPack(inst.flags) orelse return null;
    }
    packed_instr |= set(flags, COND);
    return packed_instr;
}

fn packBranch(inst: *const Instr) u64 {
    const branch = &inst.branch;
    var packed_instr: u64 = set(16, SIG);

    if (branch.cond != .always) {
        packed_instr |= set(2 + (@as(u32, @intFromEnum(branch.cond)) - @intFromEnum(instr.BranchCond.a0)), BRANCH_COND);
    }

    packed_instr |= set(@intFromEnum(branch.msfign), BRANCH_MSFIGN);
    packed_instr |= set(@intFromEnum(branch.bdi), BRANCH_BDI);

    if (branch.ub) {
        packed_instr |= BRANCH_UB;
        packed_instr |= set(@intFromEnum(branch.bdu), BRANCH_BDU);
    }

    switch (branch.bdi) {
        .abs, .rel => {
            packed_instr |= set(@intFromEnum(branch.msfign), BRANCH_MSFIGN);
            packed_instr |= set((branch.offset & ~@as(u32, 0xff000000)) >> 3, BRANCH_ADDR_LOW);
            packed_instr |= set(branch.offset >> 24, BRANCH_ADDR_HIGH);
        },
        else => {},
    }

    if (branch.bdi == .regfile or branch.bdu == .regfile) packed_instr |= set(branch.raddr_a, RADDR_A);
    return packed_instr;
}

/// The 64 bits an instruction is, or null where it has no encoding.
pub fn pack(inst: *const Instr) ?u64 {
    return switch (inst.kind) {
        .alu => packAlu(inst),
        .branch => packBranch(inst),
    };
}
