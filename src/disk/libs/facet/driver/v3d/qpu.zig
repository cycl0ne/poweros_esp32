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
const RADDR_D_SHIFT = 12;
const RADDR_A_SHIFT = 6;

const OP_MUL_NOP: u64 = 14 << 58;
const OP_ADD_NOP: u64 = 187;
const OP_ADD_LDVPMV_IN: u64 = 188;
const OP_ADD_STVPMV: u64 = 190;
const OP_ADD_MOV: u64 = 249;
/// The read address that says mov, not one of fmov's forms.
const MOV_FORM: u64 = 3;
/// Written by the mul side's nop, in its raddr_d.
const MUL_NOP_FORM: u64 = 63;

const SIG_THRSW: u64 = 1;
const SIG_LDUNIFRF: u64 = 12;
const SIG_SMALL_IMM_A: u64 = 14;

const WADDR_NOP: u64 = 6;
pub const WADDR_TLB: u64 = 7;

const mul_nop: u64 = OP_MUL_NOP | MM | WADDR_NOP << WADDR_M_SHIFT | MUL_NOP_FORM << RADDR_D_SHIFT;

pub const nop: u64 = mul_nop | MA | WADDR_NOP << WADDR_A_SHIFT | OP_ADD_NOP << OP_ADD_SHIFT;

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

/// A program that copies its `count` first inputs to its first outputs.
fn PassThrough(comptime count: u4) type {
    return [2 * @as(usize, count) + 3]u64;
}

fn passThrough(comptime count: u4) PassThrough(count) {
    var program: PassThrough(count) = undefined;
    for (0..count) |index| {
        const value: u4 = @intCast(index);
        const register: Rf = @intCast(index + 3);
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

/// The renderer's: on-screen x and y, the depth, 1/w.
pub const vertex_program = passThrough(4);

/// One colour for every pixel, from two uniforms, each of two half-floats:
/// red and green, blue and alpha. The write to the tile buffer needs no
/// configuration of its own: render target 0, half-floats and 4 of them is
/// what it is without.
pub const flat_fragment_program = [_]u64{
    ldunifrf(3),
    ldunifrf(4),
    movMagic(WADDR_TLB, 3),
    movMagic(WADDR_TLB, 4),
    thrsw,
    nop,
    nop,
};

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

test "a value read and written has its offset and registers in place" {
    try std.testing.expectEqual(@as(u64, 0x39C0_0009_BC03_F080) | MM | WADDR_NOP << WADDR_M_SHIFT, ldvpmIn(9, 2));
    try std.testing.expectEqual(@as(u64, 0x39C0_0000_BE03_F089) | MM | WADDR_NOP << WADDR_M_SHIFT, stvpm(2, 9));
}
