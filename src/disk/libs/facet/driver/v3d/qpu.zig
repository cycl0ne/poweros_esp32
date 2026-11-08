// SPDX-License-Identifier: MIT
//! The QPU's instructions of version 7.1, as many as are used here, and the
//! fixed programs made of them (Mesa's src/broadcom/qpu/qpu_pack.c).
//!
//! An instruction is 64 bits and two operations at once, one on the add
//! side and one on the mul side, plus a signal: what is not asked for here
//! is a nop on that side. 7.x has no accumulators: everything is rf0-rf63.

/// A register; rf0 to rf2 hold what the hardware hands a fragment.
pub const Rf = u6;

const SIG_SHIFT = 53;
const SIG_ADDRESS_SHIFT = 46;
const MA: u64 = 1 << 44;
const MM: u64 = 1 << 45;
const WADDR_M_SHIFT = 38;
const WADDR_A_SHIFT = 32;
const OP_ADD_SHIFT = 24;
const RADDR_C_SHIFT = 18;
const RADDR_D_SHIFT = 12;
const RADDR_A_SHIFT = 6;

const OP_MUL_NOP: u64 = 14 << 58;
const OP_ADD_NOP: u64 = 187;
const OP_ADD_LDVPMV_IN: u64 = 188;
const OP_ADD_STVPMV: u64 = 190;
const OP_ADD_MOV: u64 = 249;
/// 1 / a: the form of LDVPMV_IN's opcode with this read address. The result
/// is in its register from the instruction after next, the hardware waiting.
const OP_ADD_RECIP: u64 = 188;
const RECIP_FORM: u64 = 32;
/// fmax of two floats' sizes: their unpack fields say abs, and the higher
/// register first makes it fmax, not fmin.
const OP_ADD_FMAX_ABS: u64 = 128;
/// fadd of two floats as they are: 01 in the unpack fields of each.
const OP_ADD_FADD: u64 = 5;
/// The same for vfpack, two floats into a word of two half-floats.
const OP_ADD_VFPACK: u64 = 53;
/// fmul of two floats as they are, and of the low or the high half-float
/// of its first with the second as it is.
const OP_MUL_FMUL: u64 = 21;
const OP_MUL_FMUL_LOW: u64 = 25;
const OP_MUL_FMUL_HIGH: u64 = 29;
/// The read address that says mov, not one of fmov's forms.
const MOV_FORM: u64 = 3;
/// Written by the mul side's nop, in its raddr_d.
const MUL_NOP_FORM: u64 = 63;

const SIG_THRSW: u64 = 1;
const SIG_LDTMU: u64 = 4;
const SIG_LDVARY: u64 = 8;
const SIG_LDUNIFRF: u64 = 12;
const SIG_SMALL_IMM_A: u64 = 14;
const SIG_WRTMUC: u64 = 18;

const WADDR_NOP: u64 = 6;
pub const WADDR_TLB: u64 = 7;
pub const WADDR_TMUS: u64 = 33;
pub const WADDR_TMUT: u64 = 34;
pub const WADDR_TMUR: u64 = 35;
pub const WADDR_TMUI: u64 = 36;
/// The reference a shadow sample compares with (Mesa's v3d_tex.c:155-157;
/// since 1.142).
pub const WADDR_TMUDREF: u64 = 38;
pub const WADDR_TMUSCM: u64 = 40;

const add_nop: u64 = MA | WADDR_NOP << WADDR_A_SHIFT | OP_ADD_NOP << OP_ADD_SHIFT;
const mul_nop: u64 = OP_MUL_NOP | MM | WADDR_NOP << WADDR_M_SHIFT | MUL_NOP_FORM << RADDR_D_SHIFT;

pub const nop: u64 = mul_nop | add_nop;

/// The switch to another thread, or the program's end when it is the last:
/// it happens after the two instructions that follow it.
pub const thrsw: u64 = nop | SIG_THRSW << SIG_SHIFT;

/// The next uniform into `to`.
pub fn ldunifrf(to: Rf) u64 {
    return nop | SIG_LDUNIFRF << SIG_SHIFT | @as(u64, to) << SIG_ADDRESS_SHIFT;
}

/// `from` to one of the magic addresses.
pub fn movMagic(waddr: u64, from: Rf) u64 {
    return mul_nop | MA | waddr << WADDR_A_SHIFT | OP_ADD_MOV << OP_ADD_SHIFT |
        @as(u64, from) << RADDR_A_SHIFT | MOV_FORM;
}

/// The value at `offset` of the vertex's inputs into `to`. `offset` is a
/// small immediate, whose code for 0 to 15 is the number itself.
pub fn ldvpmIn(to: Rf, offset: u4) u64 {
    return mul_nop | SIG_SMALL_IMM_A << SIG_SHIFT | @as(u64, to) << WADDR_A_SHIFT |
        OP_ADD_LDVPMV_IN << OP_ADD_SHIFT | @as(u64, offset) << RADDR_A_SHIFT;
}

/// `from` to `offset` of the vertex's outputs.
pub fn stvpm(offset: u4, from: Rf) u64 {
    return mul_nop | SIG_SMALL_IMM_A << SIG_SHIFT | OP_ADD_STVPMV << OP_ADD_SHIFT |
        @as(u64, offset) << RADDR_A_SHIFT | from;
}

/// The next varying into `to`, its slope over the triangle, to be
/// multiplied by the pixel's w. Its other part, the constant, reaches rf0
/// by the instruction after next.
pub fn ldvary(to: Rf) u64 {
    return nop | SIG_LDVARY << SIG_SHIFT | @as(u64, to) << SIG_ADDRESS_SHIFT;
}

/// The next value the TMU has for this pixel into `to`.
pub fn ldtmu(to: Rf) u64 {
    return nop | SIG_LDTMU << SIG_SHIFT | @as(u64, to) << SIG_ADDRESS_SHIFT;
}

/// The next uniform to the TMU, as its next configuration parameter.
pub const wrtmuc: u64 = nop | SIG_WRTMUC << SIG_SHIFT;

fn mulSide(opcode: u64, to: Rf, a: Rf, b: Rf) u64 {
    return add_nop | opcode << 58 | @as(u64, to) << WADDR_M_SHIFT |
        @as(u64, a) << RADDR_C_SHIFT | @as(u64, b) << RADDR_D_SHIFT;
}

pub fn fmul(to: Rf, a: Rf, b: Rf) u64 {
    return mulSide(OP_MUL_FMUL, to, a, b);
}

/// `a`'s low half-float, as a float, times `b`.
pub fn fmulLow(to: Rf, a: Rf, b: Rf) u64 {
    return mulSide(OP_MUL_FMUL_LOW, to, a, b);
}

/// `a`'s high half-float, as a float, times `b`.
pub fn fmulHigh(to: Rf, a: Rf, b: Rf) u64 {
    return mulSide(OP_MUL_FMUL_HIGH, to, a, b);
}

/// a + b. Which of the two reads come first is what tells fadd from
/// faddnf, so the lower register is put first.
pub fn fadd(to: Rf, a: Rf, b: Rf) u64 {
    const low = @min(a, b);
    const high = @max(a, b);
    return mul_nop | @as(u64, to) << WADDR_A_SHIFT | OP_ADD_FADD << OP_ADD_SHIFT |
        @as(u64, low) << RADDR_A_SHIFT | high;
}

/// The larger of two floats' sizes. The two have to be different registers.
pub fn fmaxAbs(to: Rf, a: Rf, b: Rf) u64 {
    return mul_nop | @as(u64, to) << WADDR_A_SHIFT | OP_ADD_FMAX_ABS << OP_ADD_SHIFT |
        @as(u64, @max(a, b)) << RADDR_A_SHIFT | @min(a, b);
}

/// 1 / `from`.
pub fn recip(to: Rf, from: Rf) u64 {
    return mul_nop | @as(u64, to) << WADDR_A_SHIFT | OP_ADD_RECIP << OP_ADD_SHIFT |
        @as(u64, from) << RADDR_A_SHIFT | RECIP_FORM;
}

/// Two floats, as two half-floats in one word, to a magic address.
pub fn vfpackMagic(waddr: u64, low: Rf, high: Rf) u64 {
    return mul_nop | MA | waddr << WADDR_A_SHIFT | OP_ADD_VFPACK << OP_ADD_SHIFT |
        @as(u64, low) << RADDR_A_SHIFT | high;
}

/// The register an instruction writes on each side, the add side first,
/// and null where that side writes none: a nop, or one of the magic
/// addresses, which are not the thread's registers at all. What a
/// generated program is held to reads this (`compile.zig`).
pub fn destinations(instruction: u64) [2]?Rf {
    return .{
        if (instruction & MA != 0) null else @truncate(instruction >> WADDR_A_SHIFT),
        if (instruction & MM != 0) null else @truncate(instruction >> WADDR_M_SHIFT),
    };
}

/// The register an instruction's signal writes, where it has one:
/// `ldunifrf`, `ldvary` and `ldtmu` name it in the signal's own address
/// field and not on either side.
pub fn signalled(instruction: u64) ?Rf {
    return switch (instruction >> SIG_SHIFT & 0x1F) {
        SIG_LDUNIFRF, SIG_LDVARY, SIG_LDTMU => @truncate(instruction >> SIG_ADDRESS_SHIFT),
        else => null,
    };
}

/// A program that copies its `count` first inputs to its first outputs,
/// each through one register: the two share their place in the VPM.
fn PassThrough(comptime count: u4) type {
    return [2 * @as(usize, count) + 3]u64;
}

fn passThrough(comptime count: u4) PassThrough(count) {
    const register: Rf = 3;
    var program: PassThrough(count) = undefined;
    for (0..count) |index| {
        const value: u4 = @intCast(index);
        program[2 * index] = ldvpmIn(register, value);
        program[2 * index + 1] = stvpm(value, register);
    }
    program[2 * @as(usize, count)] = thrsw;
    program[2 * @as(usize, count) + 1] = nop;
    program[2 * @as(usize, count) + 2] = nop;
    return program;
}

/// The binner's: the clip position's 4 and the 2 of the position on screen.
pub const coordinate_program = passThrough(6);

// The renderer's: on-screen x and y, the depth, 1/w, and each varying.
const vertex_0 = passThrough(4);
const vertex_1 = passThrough(5);
const vertex_2 = passThrough(6);
const vertex_3 = passThrough(7);
const vertex_4 = passThrough(8);
const vertex_5 = passThrough(9);
const vertex_6 = passThrough(10);
const vertex_7 = passThrough(11);
const vertex_8 = passThrough(12);

/// The renderer's program for a vertex that carries `varyings` values.
pub fn vertexProgram(varyings: u32) []const u64 {
    return switch (varyings) {
        0 => &vertex_0,
        1 => &vertex_1,
        2 => &vertex_2,
        3 => &vertex_3,
        4 => &vertex_4,
        5 => &vertex_5,
        6 => &vertex_6,
        7 => &vertex_7,
        else => &vertex_8,
    };
}

/// The most varyings a program here takes.
pub const most_varyings = 8;

/// The renderer's program with no varyings.
pub const vertex_program = vertex_0;

/// A fragment program, and what a draw has to give it.
pub const Fragment = struct {
    code: []const u64,
    varyings: u32,
    /// The uniforms it reads, one after the other.
    uniforms: u32,
    /// What the shader record says of it (`cl.Programs`): a program
    /// written here runs four threads and reads W only for its varyings;
    /// one Mesa's back end compiled says its own.
    threads: u8 = 4,
    center_w: bool = false,
    lock_scoreboard_on_first_thrsw: bool = false,
    writes_z: bool = false,
    disable_ez: bool = false,
};

/// How many registers the programs written here and the plan's keep to
/// at four threads. The hardware gives each of four threads 32, as
/// Mesa's allocator has it ("4x has 32", vir_register_allocate.c:1583)
/// and as programs of 23 and 28 from it draw on the CM5 (V3DTest MESA);
/// 16 is what these were written for, and what the plan is held to.
pub const registers = 16;

/// W, as the hardware hands it to a fragment. rf0 to rf2 are the
/// hardware's as well: rf0 carries a varying's constant part.
pub const rf_w: Rf = 3;
/// The first register a program of its own may keep a value in.
pub const rf_first: Rf = 4;
/// Scratch: a varying's two parts, and the depth of the first program's
/// registers. In a threaded program there are 16 of them.
pub const rf_slope: Rf = 14;
pub const rf_scaled: Rf = 15;
/// One past the last register a program of its own may keep a value in:
/// the scratch above is written by every varying it reads.
pub const rf_last: Rf = rf_slope;

/// A varying into `to`: three instructions, as the constant reaches rf0
/// only by the third.
pub fn varying(to: Rf) [3]u64 {
    return .{
        ldvary(rf_slope),
        fmul(rf_scaled, rf_slope, rf_w),
        fadd(to, rf_scaled, 0),
    };
}

pub const end_of_program = [3]u64{ thrsw, nop, nop };

/// The switch to the last section: two thread switches in a row are what
/// tells the hardware it is the last. Every fragment program has it, sampling
/// or not, as the wait on the scoreboard is made here: without it a pixel
/// reaches the tile buffer ahead of one drawn before it at the same place,
/// and the renderer hangs. Two instructions must follow before that buffer
/// is touched, which are the switch's delay slots.
pub const last_section = [4]u64{ thrsw, thrsw, nop, nop };

/// The sample at two floats, in `s` and `t`: T first, the configuration
/// from two uniforms, and the write to S that starts it. Then the last
/// section, where it is read and the tile buffer written.
fn sampled(comptime s: Rf, comptime t: Rf) [9]u64 {
    return [_]u64{
        movMagic(WADDR_TMUT, t),
        wrtmuc,
        wrtmuc,
        movMagic(WADDR_TMUS, s),
    } ++ last_section ++ [_]u64{ldtmu(10)};
}

/// One colour for every pixel, from two uniforms, each of two half-floats:
/// red and green, blue and alpha. The write to the tile buffer needs no
/// configuration of its own: render target 0, half-floats and 4 of them is
/// what it is without.
const flat_code = [_]u64{
    ldunifrf(4),
    ldunifrf(5),
} ++ last_section ++ [_]u64{
    movMagic(WADDR_TLB, 4),
    movMagic(WADDR_TLB, 5),
} ++ end_of_program;

pub const flat_fragment = Fragment{ .code = &flat_code, .varyings = 0, .uniforms = 2 };

/// The colour the vertices carry, as varyings red, green, blue, alpha.
const color_code = varying(4) ++ varying(5) ++ varying(6) ++ varying(7) ++ last_section ++ [_]u64{
    vfpackMagic(WADDR_TLB, 4, 5),
    vfpackMagic(WADDR_TLB, 6, 7),
} ++ end_of_program;

pub const color_fragment = Fragment{ .code = &color_code, .varyings = 4, .uniforms = 0 };

/// A texture at the varyings s and t, with two uniforms: the configuration
/// parameters P0 and P1. It comes back as two words, of two half-floats
/// each, in the form the tile buffer takes.
const texture_code = varying(4) ++ varying(5) ++ sampled(4, 5) ++ [_]u64{
    ldtmu(11),
    movMagic(WADDR_TLB, 10),
    movMagic(WADDR_TLB, 11),
} ++ end_of_program;

pub const texture_fragment = Fragment{ .code = &texture_code, .varyings = 2, .uniforms = 2 };

/// What is left of a sample once it is started by S: the last section, and the
/// two words read and passed on as they are.
const sample_end = last_section ++ [_]u64{
    ldtmu(10),
    ldtmu(11),
    movMagic(WADDR_TLB, 10),
    movMagic(WADDR_TLB, 11),
} ++ end_of_program;

/// A layer of an array: varyings s, t and the layer, which the TMU takes as a
/// float, as Mesa gives it.
const array_code = varying(4) ++ varying(5) ++ varying(6) ++ [_]u64{
    movMagic(WADDR_TMUT, 5),
    movMagic(WADDR_TMUI, 6),
    wrtmuc,
    wrtmuc,
    movMagic(WADDR_TMUS, 4),
} ++ sample_end;

pub const array_fragment = Fragment{ .code = &array_code, .varyings = 3, .uniforms = 2 };

/// A 3D texture: varyings s, t and r.
const volume_code = varying(4) ++ varying(5) ++ varying(6) ++ [_]u64{
    movMagic(WADDR_TMUT, 5),
    movMagic(WADDR_TMUR, 6),
    wrtmuc,
    wrtmuc,
    movMagic(WADDR_TMUS, 4),
} ++ sample_end;

pub const volume_fragment = Fragment{ .code = &volume_code, .varyings = 3, .uniforms = 2 };

/// A shadow sample: varyings s, t and the reference, which goes to
/// TMUDREF before S starts the lookup, as handle_tex_src writes a
/// comparator (Mesa's v3d_tex.c:155-157; since 1.142). The TMU compares
/// with the sampler's function, and what passed comes back where the
/// depth would, in red (`tiling.Texels.d16`).
const shadow_code = varying(4) ++ varying(5) ++ varying(6) ++ [_]u64{
    movMagic(WADDR_TMUT, 5),
    movMagic(WADDR_TMUDREF, 6),
    wrtmuc,
    wrtmuc,
    movMagic(WADDR_TMUS, 4),
} ++ sample_end;

pub const shadow_fragment = Fragment{ .code = &shadow_code, .varyings = 3, .uniforms = 2 };

/// A cube map: varyings x, y and z. The TMU takes a direction whose largest
/// part is 1 (Mesa's nir_normalize_cubemap_coords), so it is divided by that.
const cube_code = varying(4) ++ varying(5) ++ varying(6) ++ [_]u64{
    fmaxAbs(12, 4, 5),
    fmaxAbs(12, 12, 6),
    recip(13, 12),
    nop,
    nop,
    fmul(4, 4, 13),
    fmul(5, 5, 13),
    fmul(6, 6, 13),
    movMagic(WADDR_TMUT, 5),
    movMagic(WADDR_TMUR, 6),
    wrtmuc,
    wrtmuc,
    movMagic(WADDR_TMUSCM, 4),
} ++ sample_end;

pub const cube_fragment = Fragment{ .code = &cube_code, .varyings = 3, .uniforms = 2 };

/// A texture as `texture_code` has it, times the colour of the vertices:
/// varyings s, t, red, green, blue, alpha.
const texture_color_code = varying(4) ++ varying(5) ++ varying(6) ++ varying(7) ++ varying(8) ++ varying(9) ++ sampled(4, 5) ++ [_]u64{
    ldtmu(11),
    fmulLow(6, 10, 6),
    fmulHigh(7, 10, 7),
    fmulLow(8, 11, 8),
    fmulHigh(9, 11, 9),
    vfpackMagic(WADDR_TLB, 6, 7),
    vfpackMagic(WADDR_TLB, 8, 9),
} ++ end_of_program;

pub const texture_color_fragment = Fragment{ .code = &texture_color_code, .varyings = 6, .uniforms = 2 };

const std = @import("std");

test "nop is what 7.1 calls it" {
    // Both sides nop; Mesa's disassembler reads this as "nop ; nop".
    try std.testing.expectEqual(@as(u64, 0x3800_3186_BB03_F000), nop);
}

test "the fields lie where Mesa's samples have them" {
    // "add rf10, 1, rf2 ; nop", from Mesa's qpu_disasm tests: the same
    // fields as ldvpmIn and stvpm use, with the add opcode swapped in.
    const sample: u64 = 0x39C0_000A_3803_F042;
    const add_opcode: u64 = 56;
    const encoded = SIG_SMALL_IMM_A << SIG_SHIFT | OP_MUL_NOP | MUL_NOP_FORM << RADDR_D_SHIFT |
        @as(u64, 10) << WADDR_A_SHIFT | add_opcode << OP_ADD_SHIFT | @as(u64, 1) << RADDR_A_SHIFT | 2;
    try std.testing.expectEqual(sample, encoded);
}

test "fmul and fadd read and write where qpu_pack.c puts them" {
    const made = fmul(1, 2, 3);
    try std.testing.expectEqual(@as(u64, 21), made >> 58);
    try std.testing.expectEqual(@as(u64, 1), made >> WADDR_M_SHIFT & 63);
    try std.testing.expectEqual(@as(u64, 2), made >> RADDR_C_SHIFT & 63);
    try std.testing.expectEqual(@as(u64, 3), made >> RADDR_D_SHIFT & 63);
    try std.testing.expectEqual(@as(u64, 0), made & MM);
    try std.testing.expectEqual(MA, made & MA);
    // Whichever way round it is asked for, the lower register reads first.
    try std.testing.expectEqual(fadd(4, 0, 15), fadd(4, 15, 0));
    try std.testing.expectEqual(@as(u64, 15), fadd(4, 15, 0) & 63);
    try std.testing.expectEqual(@as(u64, 0), fadd(4, 15, 0) >> RADDR_A_SHIFT & 63);
}

test "a program keeps to the registers a thread has, on both sides and in its signals" {
    const programs = [_]Fragment{ flat_fragment, color_fragment, texture_fragment, texture_color_fragment, array_fragment, cube_fragment, volume_fragment, shadow_fragment };
    for (programs) |fragment| {
        var waits: u32 = 0;
        for (fragment.code, 0..) |instruction, at| {
            for (destinations(instruction)) |side| if (side) |to| try std.testing.expect(to < registers);
            if (signalled(instruction)) |to| try std.testing.expect(to < registers);
            // The wait on the scoreboard: two thread switches in a row,
            // and exactly one of them in a program.
            if (instruction == thrsw and at + 1 < fragment.code.len and fragment.code[at + 1] == thrsw) waits += 1;
        }
        try std.testing.expectEqual(@as(u32, 1), waits);
        // Each ends in a thread switch and its two delay slots.
        const end = fragment.code[fragment.code.len - 3 ..];
        try std.testing.expectEqual(thrsw, end[0]);
        try std.testing.expectEqual(nop, end[1]);
        try std.testing.expectEqual(nop, end[2]);
    }
}

test "the destinations of the instructions that have them are read off where qpu_pack.c has them" {
    try std.testing.expectEqual([2]?Rf{ 9, null }, destinations(fadd(9, 1, 2)));
    try std.testing.expectEqual([2]?Rf{ null, 11 }, destinations(fmul(11, 1, 2)));
    try std.testing.expectEqual([2]?Rf{ null, null }, destinations(nop));
    // A magic address is not a register, on either side.
    try std.testing.expectEqual([2]?Rf{ null, null }, destinations(movMagic(WADDR_TLB, 4)));
    try std.testing.expectEqual([2]?Rf{ null, null }, destinations(vfpackMagic(WADDR_TLB, 4, 5)));
    // The loads name their register in the signal's own field.
    try std.testing.expectEqual(@as(?Rf, 7), signalled(ldunifrf(7)));
    try std.testing.expectEqual(@as(?Rf, 8), signalled(ldvary(8)));
    try std.testing.expectEqual(@as(?Rf, 10), signalled(ldtmu(10)));
    try std.testing.expectEqual(@as(?Rf, null), signalled(nop));
    try std.testing.expectEqual(@as(?Rf, null), signalled(thrsw));
    try std.testing.expectEqual(@as(?Rf, null), signalled(wrtmuc));
}

test "a value read and written has its offset and registers in place" {
    try std.testing.expectEqual(@as(u64, 0x39C0_0009_BC03_F080) | MM | WADDR_NOP << WADDR_M_SHIFT, ldvpmIn(9, 2));
    try std.testing.expectEqual(@as(u64, 0x39C0_0000_BE03_F089) | MM | WADDR_NOP << WADDR_M_SHIFT, stvpm(2, 9));
}
