// SPDX-License-Identifier: MIT
//! The QPU's instructions of version 7.1, unpacked: what an instruction
//! says before `pack.zig` makes 64 bits of it, and after it reads them
//! back.
//!
//! A port of Mesa's src/broadcom/qpu/qpu_instr.h and qpu_instr.c, of
//! their 7.1 paths alone. 7.1 has no accumulators and no input muxes:
//! every operand is a register file address or a small immediate, and
//! the functions that ask about r3, r4 or r5 answer false there, so they
//! are left out. Mesa's names are kept, in Zig's case, so that what is
//! ported after this - VIR, the scheduler, the register allocator -
//! reads as the C does.

const std = @import("std");

/// The signals an instruction may carry (Mesa's struct v3d_qpu_sig).
/// Which of them may go together is `pack.zig`'s table: what is not in it
/// does not pack.
pub const Sig = packed struct(u17) {
    thrsw: bool = false,
    ldunif: bool = false,
    ldunifa: bool = false,
    ldunifrf: bool = false,
    ldunifarf: bool = false,
    ldtmu: bool = false,
    ldvary: bool = false,
    ldvpm: bool = false,
    ldtlb: bool = false,
    ldtlbu: bool = false,
    ucb: bool = false,
    rotate: bool = false,
    wrtmuc: bool = false,
    /// raddr_a, the add side's first operand, is a small immediate.
    small_imm_a: bool = false,
    /// raddr_b, the add side's second.
    small_imm_b: bool = false,
    /// raddr_c, the mul side's first.
    small_imm_c: bool = false,
    /// raddr_d, the mul side's second.
    small_imm_d: bool = false,

    pub fn eql(a: Sig, b: Sig) bool {
        return @as(u17, @bitCast(a)) == @as(u17, @bitCast(b));
    }
};

pub const Cond = enum(u3) { none, ifa, ifb, ifna, ifnb };

/// A flag push.
pub const Pf = enum(u2) { none, pushz, pushn, pushc };

/// A flag update. The order is the encoding's (`pack.flagsPack`).
pub const Uf = enum(u4) { none, andz, andnz, nornz, norz, andn, andnn, nornn, norn, andc, andnc, nornc, norc };

/// The magic write addresses (Mesa's enum v3d_qpu_waddr): where a write
/// whose `magic_write` is set goes, in place of a register. The r0 to r4
/// and the SFU addresses are reserved on 7.x, and named as Mesa names
/// them all the same.
pub const Waddr = enum(u6) {
    r0 = 0,
    r1 = 1,
    r2 = 2,
    r3 = 3,
    r4 = 4,
    quad = 5,
    nop = 6,
    tlb = 7,
    tlbu = 8,
    unifa = 9,
    tmul = 10,
    tmud = 11,
    tmua = 12,
    tmuau = 13,
    vpm = 14,
    vpmu = 15,
    sync = 16,
    syncu = 17,
    syncb = 18,
    recip = 19,
    rsqrt = 20,
    exp = 21,
    log = 22,
    sin = 23,
    rsqrt2 = 24,
    tmuc = 32,
    tmus = 33,
    tmut = 34,
    tmur = 35,
    tmui = 36,
    tmub = 37,
    tmudref = 38,
    tmuoff = 39,
    tmuscm = 40,
    tmusf = 41,
    tmuslod = 42,
    tmuhs = 43,
    tmuhscm = 44,
    tmuhsf = 45,
    tmuhslod = 46,
    rep = 55,
    _,
};

/// A magic address as the `waddr` of a side holds it.
pub fn magic(waddr: Waddr) u6 {
    return @intFromEnum(waddr);
}

pub const Flags = struct {
    ac: Cond = .none,
    mc: Cond = .none,
    apf: Pf = .none,
    mpf: Pf = .none,
    auf: Uf = .none,
    muf: Uf = .none,
};

pub const AddOp = enum(u8) {
    fadd,
    faddnf,
    vfpack,
    add,
    sub,
    fsub,
    min,
    max,
    umin,
    umax,
    shl,
    shr,
    asr,
    ror,
    fmin,
    fmax,
    vfmin,
    vfadd,
    vfsub,
    vfcmp,
    vfmov,
    vfabs,
    vfneg,
    vfnab,
    @"and",
    @"or",
    xor,
    vadd,
    vsub,
    not,
    neg,
    flapush,
    flbpush,
    flpop,
    recip,
    setmsf,
    setrevf,
    nop,
    tidx,
    eidx,
    lr,
    vfla,
    vflna,
    vflb,
    vflnb,
    fxcd,
    xcd,
    fycd,
    ycd,
    msf,
    revf,
    vdwwt,
    iid,
    sampid,
    barrierid,
    tmuwt,
    vpmsetup,
    vpmwt,
    flafirst,
    flnafirst,
    ldvpmv_in,
    ldvpmv_out,
    ldvpmd_in,
    ldvpmd_out,
    ldvpmp,
    rsqrt,
    exp,
    log,
    sin,
    rsqrt2,
    ldvpmg_in,
    ldvpmg_out,
    fcmp,
    vfmax,
    fround,
    ftoin,
    ftrunc,
    ftoiz,
    ffloor,
    ftouz,
    fceil,
    ftoc,
    fdx,
    fdy,
    stvpmv,
    stvpmd,
    stvpmp,
    itof,
    clz,
    utof,

    // V3D 7.x
    fmov,
    mov,
    vpack,
    v8pack,
    v10pack,
    v11fpack,
    ballot,
    bcastf,
    alleq,
    allfeq,
    rotq,
    rot,
    shuffle,
    setnnmode_uu,
    setnnmode_su,
    setnnmode_us,
    setnnmode_ss,
};

pub const MulOp = enum(u8) {
    add,
    sub,
    /// Emitted with `multop`, which writes the rtop register, for a 32-bit
    /// multiply.
    umul24,
    /// A 24-bit multiply that takes the rtop register to be 0, which lets
    /// the scheduler leave it alone. It packs as `umul24`.
    umul24_rtop0,
    vfmul,
    smul24,
    multop,
    fmov,
    mov,
    nop,
    fmul,

    // V3D 7.x
    ftounorm16,
    ftosnorm16,
    vftounorm8,
    vftosnorm8,
    funpackunormlo,
    funpackunormhi,
    funpacksnormlo,
    funpacksnormhi,
    vftounorm10lo,
    vftounorm10hi,
    v8dot,
};

pub const OutputPack = enum(u2) {
    none,
    /// To a 16-bit float, in the low 16 bits; the high ones are left.
    l,
    /// To a 16-bit float, in the high 16 bits; the low ones are left.
    h,
};

pub const InputUnpack = enum(u4) {
    /// As it is. The field's own value for it is not 0; 0 is this so that
    /// a new instruction unpacks nothing.
    none,
    /// The absolute value, for some operations only.
    abs,
    /// The low 16 bits, a 16-bit float, as a 32-bit float.
    l,
    /// The high 16 bits likewise.
    h,
    /// Saturated to [0, 1].
    sat,
    /// Saturated to [-1, 1].
    nsat,
    /// Saturated to [0, +inf].
    max0,
    /// To a 16-bit float, replicated to the high bits.
    replicate_32f_16,
    /// The low 16 bits replicated to the high ones.
    replicate_l_16,
    /// The high 16 bits replicated to the low ones.
    replicate_h_16,
    /// The two halves swapped.
    swap_16,
    /// The low 16 bits, a 16-bit integer, as an unsigned 32-bit one.
    ul,
    /// The high 16 bits likewise.
    uh,
    /// The low 16 bits, a 16-bit integer, as a signed 32-bit one.
    il,
    /// The high 16 bits likewise.
    ih,
};

/// An operand: a register, or a small immediate where the signal says so.
pub const Input = struct {
    raddr: u6 = 0,
    unpack: InputUnpack = .none,
};

/// The add side. Its defaults are its nop, as Mesa's v3d_qpu_nop() has it.
pub const Add = struct {
    op: AddOp = .nop,
    a: Input = .{},
    b: Input = .{},
    waddr: u6 = magic(.nop),
    magic_write: bool = true,
    output_pack: OutputPack = .none,
};

/// The mul side, likewise.
pub const Mul = struct {
    op: MulOp = .nop,
    a: Input = .{},
    b: Input = .{},
    waddr: u6 = magic(.nop),
    magic_write: bool = true,
    output_pack: OutputPack = .none,
};

pub const Alu = struct {
    add: Add = .{},
    mul: Mul = .{},
};

pub const BranchCond = enum(u3) { always, a0, na0, alla, anyna, anya, allna };

pub const Msfign = enum(u2) {
    /// The multisample flags are not looked at.
    none,
    /// A lane with none of them set - a pixel, or a vertex - does not take
    /// part in the condition.
    p,
    /// A 2x2 quad with none set does not.
    q,
};

/// How a taken branch finds its new address, or its new uniforms. The
/// field for the uniforms is three bits wide and four of its values are
/// named: Mesa keeps what it reads there either way, and so does this.
pub const BranchDest = enum(u3) { abs, rel, link_reg, regfile, _ };

pub const Branch = struct {
    cond: BranchCond = .always,
    msfign: Msfign = .none,
    /// How the new address is had.
    bdi: BranchDest = .abs,
    /// How the new uniforms address is had, where `ub` is set; `abs` and
    /// `rel` load a uniform for it.
    bdu: BranchDest = .abs,
    /// The uniform stream branches too.
    ub: bool = false,
    raddr_a: u6 = 0,
    offset: u32 = 0,
};

pub const Kind = enum { alu, branch };

/// One instruction. Mesa keeps the ALU half and the branch half in a
/// union; here both are kept and the one `kind` does not name stays at
/// its default, so a branch reads as a nop on both ALU sides.
pub const Instr = struct {
    kind: Kind = .alu,
    sig: Sig = .{},
    sig_addr: u6 = 0,
    /// The signal writes a magic address rather than a register.
    sig_magic: bool = false,
    /// Where VIR keeps a small immediate before it is placed in the
    /// operand that reads it (Mesa's raddr_b "holds packed small immediate
    /// in 7.x too"). Unpacking fills both from the word.
    raddr_a: u6 = 0,
    raddr_b: u6 = 0,
    flags: Flags = .{},
    alu: Alu = .{},
    branch: Branch = .{},
};

/// The instruction that does nothing (Mesa's v3d_qpu_nop()).
pub const nop = Instr{};

pub fn magicWaddrName(waddr: u6) ?[]const u8 {
    return switch (@as(Waddr, @enumFromInt(waddr))) {
        .r0 => "r0",
        .r1 => "r1",
        .r2 => "r2",
        .r3 => "r3",
        .r4 => "r4",
        .quad => "quad",
        .nop => "-",
        .tlb => "tlb",
        .tlbu => "tlbu",
        .unifa => "unifa",
        .tmul => "tmul",
        .tmud => "tmud",
        .tmua => "tmua",
        .tmuau => "tmuau",
        .vpm => "vpm",
        .vpmu => "vpmu",
        .sync => "sync",
        .syncu => "syncu",
        .syncb => "syncb",
        .recip => "recip",
        .rsqrt => "rsqrt",
        .exp => "exp",
        .log => "log",
        .sin => "sin",
        .rsqrt2 => "rsqrt2",
        .tmuc => "tmuc",
        .tmus => "tmus",
        .tmut => "tmut",
        .tmur => "tmur",
        .tmui => "tmui",
        .tmub => "tmub",
        .tmudref => "tmudref",
        .tmuoff => "tmuoff",
        .tmuscm => "tmuscm",
        .tmusf => "tmusf",
        .tmuslod => "tmuslod",
        .tmuhs => "tmuhs",
        // Mesa's table names this one as it names tmuscm.
        .tmuhscm => "tmuscm",
        .tmuhsf => "tmuhsf",
        .tmuhslod => "tmuhslod",
        .rep => "rep",
        _ => null,
    };
}

pub fn addOpName(op: AddOp) []const u8 {
    return switch (op) {
        .@"and" => "and",
        .@"or" => "or",
        else => @tagName(op),
    };
}

pub fn mulOpName(op: MulOp) []const u8 {
    return @tagName(op);
}

pub fn condName(cond: Cond) []const u8 {
    return switch (cond) {
        .none => "",
        .ifa => ".ifa",
        .ifb => ".ifb",
        .ifna => ".ifna",
        .ifnb => ".ifnb",
    };
}

pub fn branchCondName(cond: BranchCond) []const u8 {
    return switch (cond) {
        .always => "",
        .a0 => ".a0",
        .na0 => ".na0",
        .alla => ".alla",
        .anyna => ".anyna",
        .anya => ".anya",
        .allna => ".allna",
    };
}

pub fn msfignName(msfign: Msfign) []const u8 {
    return switch (msfign) {
        .none => "",
        .p => "p",
        .q => "q",
    };
}

pub fn pfName(pf: Pf) []const u8 {
    return switch (pf) {
        .none => "",
        .pushz => ".pushz",
        .pushn => ".pushn",
        .pushc => ".pushc",
    };
}

pub fn ufName(uf: Uf) []const u8 {
    return switch (uf) {
        .none => "",
        .andz => ".andz",
        .andnz => ".andnz",
        .norz => ".norz",
        .nornz => ".nornz",
        .andn => ".andn",
        .andnn => ".andnn",
        .norn => ".norn",
        .nornn => ".nornn",
        .andc => ".andc",
        .andnc => ".andnc",
        .norc => ".norc",
        .nornc => ".nornc",
    };
}

pub fn packName(pack: OutputPack) []const u8 {
    return switch (pack) {
        .none => "",
        .l => ".l",
        .h => ".h",
    };
}

pub fn unpackName(unpack: InputUnpack) []const u8 {
    return switch (unpack) {
        .none => "",
        .l => ".l",
        .h => ".h",
        .abs => ".abs",
        .replicate_32f_16 => ".ff",
        .replicate_l_16 => ".ll",
        .replicate_h_16 => ".hh",
        .swap_16 => ".swp",
        .sat => ".sat",
        .nsat => ".nsat",
        .max0 => ".max0",
        // Mesa's table has no name for the integer unpacks of mov, and
        // stops there (UNREACHABLE): they are named here instead.
        .ul => ".ul",
        .uh => ".uh",
        .il => ".il",
        .ih => ".ih",
    };
}

// What an operation writes and reads: a destination, a first operand, a
// second.
const D = 1;
const A = 2;
const B = 4;

fn addOpArgs(op: AddOp) u3 {
    return switch (op) {
        .fadd, .faddnf, .vfpack, .add, .sub, .fsub, .min, .max, .umin, .umax, .shl, .shr, .asr, .ror, .fmin, .fmax, .vfmin, .vfadd, .vfsub, .vfcmp => D | A | B,
        .vfmov, .vfabs, .vfneg, .vfnab => D | A,
        .@"and", .@"or", .xor, .vadd, .vsub => D | A | B,
        .not, .neg, .flapush, .flbpush, .flpop, .recip, .setmsf, .setrevf => D | A,
        .nop => 0,
        .tidx, .eidx, .lr, .vfla, .vflna, .vflb, .vflnb, .fxcd, .xcd, .fycd, .ycd => D,
        .msf, .revf, .vdwwt, .iid, .sampid, .barrierid, .tmuwt, .vpmwt, .flafirst, .flnafirst => D,
        .vpmsetup => D | A,
        .ldvpmv_in, .ldvpmv_out, .ldvpmd_in, .ldvpmd_out, .ldvpmp, .rsqrt, .exp, .log, .sin, .rsqrt2 => D | A,
        .ldvpmg_in, .ldvpmg_out => D | A | B,
        .fcmp, .vfmax => D | A | B,
        .fround, .ftoin, .ftrunc, .ftoiz, .ffloor, .ftouz, .fceil, .ftoc, .fdx, .fdy => D | A,
        .stvpmv, .stvpmd, .stvpmp => A | B,
        .itof, .clz, .utof => D | A,
        .mov, .fmov => D | A,
        .vpack, .v8pack, .v10pack, .v11fpack => D | A | B,
        .ballot, .bcastf, .alleq, .allfeq => D | A,
        .rotq, .rot, .shuffle => D | A | B,
        .setnnmode_uu, .setnnmode_su, .setnnmode_us, .setnnmode_ss => 0,
    };
}

fn mulOpArgs(op: MulOp) u3 {
    return switch (op) {
        .add, .sub, .umul24, .umul24_rtop0, .vfmul, .smul24, .multop => D | A | B,
        .fmov => D | A,
        .nop => 0,
        .mov => D | A,
        .fmul => D | A | B,
        .ftounorm16, .ftosnorm16, .vftounorm8, .vftosnorm8, .funpackunormlo, .funpackunormhi, .funpacksnormlo, .funpacksnormhi, .vftounorm10lo, .vftounorm10hi => D | A,
        .v8dot => D | A | B,
    };
}

fn numSrc(args: u3) u2 {
    if (args & B != 0) return 2;
    if (args & A != 0) return 1;
    return 0;
}

pub fn addOpHasDst(op: AddOp) bool {
    return addOpArgs(op) & D != 0;
}

pub fn mulOpHasDst(op: MulOp) bool {
    return mulOpArgs(op) & D != 0;
}

pub fn addOpNumSrc(op: AddOp) u2 {
    return numSrc(addOpArgs(op));
}

pub fn mulOpNumSrc(op: MulOp) u2 {
    return numSrc(mulOpArgs(op));
}

pub fn condInvert(cond: Cond) Cond {
    return switch (cond) {
        .ifa => .ifna,
        .ifna => .ifa,
        .ifb => .ifnb,
        .ifnb => .ifb,
        .none => unreachable,
    };
}

pub fn magicWaddrIsSfu(waddr: u6) bool {
    return switch (@as(Waddr, @enumFromInt(waddr))) {
        .recip, .rsqrt, .exp, .log, .sin, .rsqrt2 => true,
        else => false,
    };
}

pub fn magicWaddrIsTmu(waddr: u6) bool {
    return (waddr >= magic(.tmud) and waddr <= magic(.tmuau)) or
        (waddr >= magic(.tmuc) and waddr <= magic(.tmuhslod));
}

pub fn waitsOnTmu(inst: *const Instr) bool {
    return inst.sig.ldtmu or (inst.kind == .alu and inst.alu.add.op == .tmuwt);
}

pub fn magicWaddrIsTlb(waddr: u6) bool {
    return waddr == magic(.tlb) or waddr == magic(.tlbu);
}

pub fn magicWaddrIsVpm(waddr: u6) bool {
    return waddr == magic(.vpm) or waddr == magic(.vpmu);
}

pub fn magicWaddrIsTsy(waddr: u6) bool {
    return waddr == magic(.sync) or waddr == magic(.syncb) or waddr == magic(.syncu);
}

pub fn magicWaddrLoadsUnif(waddr: u6) bool {
    return switch (@as(Waddr, @enumFromInt(waddr))) {
        .vpmu, .tlbu, .tmuau, .syncu => true,
        else => false,
    };
}

fn addOpReadsVpm(op: AddOp) bool {
    return switch (op) {
        .vpmsetup, .ldvpmv_in, .ldvpmv_out, .ldvpmd_in, .ldvpmd_out, .ldvpmp, .ldvpmg_in, .ldvpmg_out => true,
        else => false,
    };
}

fn addOpWritesVpm(op: AddOp) bool {
    return switch (op) {
        .vpmsetup, .stvpmv, .stvpmd, .stvpmp => true,
        else => false,
    };
}

pub fn readsTlb(inst: *const Instr) bool {
    return inst.sig.ldtlb or inst.sig.ldtlbu;
}

/// The add side writes a magic address of the kind `is` says.
fn addWritesMagic(inst: *const Instr, comptime is: fn (u6) bool) bool {
    return inst.alu.add.op != .nop and inst.alu.add.magic_write and is(inst.alu.add.waddr);
}

fn mulWritesMagic(inst: *const Instr, comptime is: fn (u6) bool) bool {
    return inst.alu.mul.op != .nop and inst.alu.mul.magic_write and is(inst.alu.mul.waddr);
}

pub fn writesTlb(inst: *const Instr) bool {
    return inst.kind == .alu and (addWritesMagic(inst, magicWaddrIsTlb) or mulWritesMagic(inst, magicWaddrIsTlb));
}

pub fn usesTlb(inst: *const Instr) bool {
    return writesTlb(inst) or readsTlb(inst);
}

pub fn usesSfu(inst: *const Instr) bool {
    return instrIsSfu(inst) or instrIsLegacySfu(inst);
}

/// An SFU operation asked for by a write to its magic address rather than
/// by an SFU opcode.
pub fn instrIsLegacySfu(inst: *const Instr) bool {
    return inst.kind == .alu and (addWritesMagic(inst, magicWaddrIsSfu) or mulWritesMagic(inst, magicWaddrIsSfu));
}

pub fn instrIsSfu(inst: *const Instr) bool {
    if (inst.kind != .alu) return false;
    return switch (inst.alu.add.op) {
        .recip, .rsqrt, .exp, .log, .sin, .rsqrt2, .ballot, .bcastf, .alleq, .allfeq, .rotq, .rot, .shuffle => true,
        else => false,
    };
}

pub fn writesTmu(inst: *const Instr) bool {
    return inst.kind == .alu and (addWritesMagic(inst, magicWaddrIsTmu) or mulWritesMagic(inst, magicWaddrIsTmu));
}

pub fn writesTmuNotTmuc(inst: *const Instr) bool {
    return writesTmu(inst) and
        (!inst.alu.add.magic_write or inst.alu.add.waddr != magic(.tmuc)) and
        (!inst.alu.mul.magic_write or inst.alu.mul.waddr != magic(.tmuc));
}

pub fn readsVpm(inst: *const Instr) bool {
    if (inst.sig.ldvpm) return true;
    return inst.kind == .alu and addOpReadsVpm(inst.alu.add.op);
}

pub fn writesVpm(inst: *const Instr) bool {
    if (inst.kind != .alu) return false;
    if (addOpWritesVpm(inst.alu.add.op)) return true;
    return addWritesMagic(inst, magicWaddrIsVpm) or mulWritesMagic(inst, magicWaddrIsVpm);
}

fn isUnifa(waddr: u6) bool {
    return waddr == magic(.unifa);
}

pub fn writesUnifa(inst: *const Instr) bool {
    if (inst.kind != .alu) return false;
    if (addWritesMagic(inst, isUnifa) or mulWritesMagic(inst, isUnifa)) return true;
    return sigWritesAddress(inst.sig) and inst.sig_magic and inst.sig_addr == magic(.unifa);
}

pub fn waitsVpm(inst: *const Instr) bool {
    return inst.kind == .alu and inst.alu.add.op == .vpmwt;
}

pub fn readsOrWritesVpm(inst: *const Instr) bool {
    return readsVpm(inst) or writesVpm(inst);
}

pub fn usesVpm(inst: *const Instr) bool {
    return readsVpm(inst) or writesVpm(inst) or waitsVpm(inst);
}

/// ldvary, ldunif and ldunifa write rf0 on 7.x, without naming it.
pub fn writesRf0Implicitly(inst: *const Instr) bool {
    return inst.sig.ldvary or inst.sig.ldunif or inst.sig.ldunifa;
}

/// The instruction reads register `raddr`, through an operand that is not
/// a small immediate (Mesa's v3d71_qpu_reads_raddr).
pub fn readsRaddr(inst: *const Instr, raddr: u6) bool {
    const add_nsrc = addOpNumSrc(inst.alu.add.op);
    const mul_nsrc = mulOpNumSrc(inst.alu.mul.op);
    return (add_nsrc > 0 and !inst.sig.small_imm_a and inst.alu.add.a.raddr == raddr) or
        (add_nsrc > 1 and !inst.sig.small_imm_b and inst.alu.add.b.raddr == raddr) or
        (mul_nsrc > 0 and !inst.sig.small_imm_c and inst.alu.mul.a.raddr == raddr) or
        (mul_nsrc > 1 and !inst.sig.small_imm_d and inst.alu.mul.b.raddr == raddr);
}

/// The instruction names register `waddr` as what it writes, on a side or
/// in its signal (Mesa's v3d71_qpu_writes_waddr_explicitly).
pub fn writesWaddrExplicitly(inst: *const Instr, waddr: u6) bool {
    if (inst.kind != .alu) return false;
    if (addOpHasDst(inst.alu.add.op) and !inst.alu.add.magic_write and inst.alu.add.waddr == waddr) return true;
    if (mulOpHasDst(inst.alu.mul.op) and !inst.alu.mul.magic_write and inst.alu.mul.waddr == waddr) return true;
    return sigWritesAddress(inst.sig) and !inst.sig_magic and inst.sig_addr == waddr;
}

/// The signal names what it writes, in the condition field, which it then
/// has for itself.
pub fn sigWritesAddress(sig: Sig) bool {
    return sig.ldunifrf or sig.ldunifarf or sig.ldvary or sig.ldtmu or sig.ldtlb or sig.ldtlbu;
}

pub fn readsFlags(inst: *const Instr) bool {
    switch (inst.kind) {
        .branch => return inst.branch.cond != .always,
        .alu => {
            if (inst.flags.ac != .none or inst.flags.mc != .none or inst.flags.auf != .none or inst.flags.muf != .none) return true;
            return switch (inst.alu.add.op) {
                .vfla, .vflna, .vflb, .vflnb, .flapush, .flbpush, .flafirst, .flnafirst => true,
                else => false,
            };
        },
    }
}

pub fn writesFlags(inst: *const Instr) bool {
    return inst.flags.apf != .none or inst.flags.mpf != .none or inst.flags.auf != .none or inst.flags.muf != .none;
}

pub fn unpacksF32(inst: *const Instr) bool {
    if (inst.kind != .alu) return false;
    switch (inst.alu.add.op) {
        .fadd, .faddnf, .fsub, .fmin, .fmax, .fcmp, .fround, .ftrunc, .ffloor, .fceil, .fdx, .fdy, .ftoin, .ftoiz, .ftouz, .ftoc, .vfpack => return true,
        else => {},
    }
    return switch (inst.alu.mul.op) {
        .fmov, .fmul => true,
        else => false,
    };
}

pub fn unpacksF16(inst: *const Instr) bool {
    if (inst.kind != .alu) return false;
    switch (inst.alu.add.op) {
        .vfmin, .vfmax, .vfadd, .vfsub, .vfcmp => return true,
        else => {},
    }
    return inst.alu.mul.op == .vfmul;
}

pub fn isNop(inst: *const Instr) bool {
    if (inst.kind != .alu) return false;
    if (inst.alu.add.op != .nop) return false;
    if (inst.alu.mul.op != .nop) return false;
    return inst.sig.eql(.{});
}
