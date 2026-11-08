// SPDX-License-Identifier: MIT
//! A QPU instruction of version 7.1 as text, the way Mesa's disassembler
//! prints it (src/broadcom/qpu/qpu_disasm.c, its 7.1 paths): the add side,
//! the mul side from column 30, and the signals from column 60. The text
//! is what Mesa's tests compare against, so it is kept to the column.

const std = @import("std");
const instr = @import("instr.zig");
const pack = @import("pack.zig");
const Instr = instr.Instr;

/// The longest text an instruction comes to, with room to spare.
pub const most_text = 160;

/// Text appended into a buffer of the caller's. What does not fit is cut
/// off, which `most_text` leaves no room for.
const Text = struct {
    buffer: []u8,
    offset: usize = 0,

    fn append(text: *Text, comptime format: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(text.buffer[text.offset..], format, args) catch {
            text.offset = text.buffer.len;
            return;
        };
        text.offset += written.len;
    }

    fn padTo(text: *Text, column: usize) void {
        while (text.offset < column and text.offset < text.buffer.len) {
            text.buffer[text.offset] = ' ';
            text.offset += 1;
        }
    }
};

const InputClass = enum { add_a, add_b, mul_a, mul_b };

fn raddr(text: *Text, inst: *const Instr, value: u6, class: InputClass) void {
    const is_small_imm = switch (class) {
        .add_a => inst.sig.small_imm_a,
        .add_b => inst.sig.small_imm_b,
        .mul_a => inst.sig.small_imm_c,
        .mul_b => inst.sig.small_imm_d,
    };
    if (is_small_imm) {
        const val = pack.smallImmUnpack(value).?;
        const signed: i32 = @bitCast(val);
        if (signed >= -16 and signed <= 15) {
            text.append("{d}", .{signed});
        } else {
            text.append("0x{x:0>8}", .{val});
        }
    } else {
        text.append("rf{d}", .{value});
    }
}

fn waddr(text: *Text, value: u6, magic: bool) void {
    if (!magic) {
        text.append("rf{d}", .{value});
        return;
    }
    if (instr.magicWaddrName(value)) |name| {
        text.append("{s}", .{name});
    } else {
        text.append("waddr UNKNOWN {d}", .{value});
    }
}

fn add(text: *Text, inst: *const Instr) void {
    const side = &inst.alu.add;
    const has_dst = instr.addOpHasDst(side.op);
    const num_src = instr.addOpNumSrc(side.op);

    text.append("{s}", .{instr.addOpName(side.op)});
    if (!instr.sigWritesAddress(inst.sig)) text.append("{s}", .{instr.condName(inst.flags.ac)});
    text.append("{s}", .{instr.pfName(inst.flags.apf)});
    text.append("{s}", .{instr.ufName(inst.flags.auf)});

    text.append(" ", .{});

    if (has_dst) {
        waddr(text, side.waddr, side.magic_write);
        text.append("{s}", .{instr.packName(side.output_pack)});
    }

    if (num_src >= 1) {
        if (has_dst) text.append(", ", .{});
        raddr(text, inst, side.a.raddr, .add_a);
        text.append("{s}", .{instr.unpackName(side.a.unpack)});
    }

    if (num_src >= 2) {
        text.append(", ", .{});
        raddr(text, inst, side.b.raddr, .add_b);
        text.append("{s}", .{instr.unpackName(side.b.unpack)});
    }
}

fn mul(text: *Text, inst: *const Instr) void {
    const side = &inst.alu.mul;
    const has_dst = instr.mulOpHasDst(side.op);
    const num_src = instr.mulOpNumSrc(side.op);

    text.padTo(30);
    text.append("; ", .{});

    text.append("{s}", .{instr.mulOpName(side.op)});
    if (!instr.sigWritesAddress(inst.sig)) text.append("{s}", .{instr.condName(inst.flags.mc)});
    text.append("{s}", .{instr.pfName(inst.flags.mpf)});
    text.append("{s}", .{instr.ufName(inst.flags.muf)});

    if (side.op == .nop) return;

    text.append(" ", .{});

    if (has_dst) {
        waddr(text, side.waddr, side.magic_write);
        text.append("{s}", .{instr.packName(side.output_pack)});
    }

    if (num_src >= 1) {
        if (has_dst) text.append(", ", .{});
        raddr(text, inst, side.a.raddr, .mul_a);
        text.append("{s}", .{instr.unpackName(side.a.unpack)});
    }

    if (num_src >= 2) {
        text.append(", ", .{});
        raddr(text, inst, side.b.raddr, .mul_b);
        text.append("{s}", .{instr.unpackName(side.b.unpack)});
    }
}

fn sigAddr(text: *Text, inst: *const Instr) void {
    if (!inst.sig_magic) {
        text.append(".rf{d}", .{inst.sig_addr});
    } else if (instr.magicWaddrName(inst.sig_addr)) |name| {
        text.append(".{s}", .{name});
    } else {
        text.append(".UNKNOWN{d}", .{inst.sig_addr});
    }
}

fn sig(text: *Text, inst: *const Instr) void {
    const s = inst.sig;
    if (!s.thrsw and !s.ldvary and !s.ldvpm and !s.ldtmu and !s.ldtlb and !s.ldtlbu and
        !s.ldunif and !s.ldunifrf and !s.ldunifa and !s.ldunifarf and !s.wrtmuc) return;

    text.padTo(60);

    if (s.thrsw) text.append("; thrsw", .{});
    if (s.ldvary) {
        text.append("; ldvary", .{});
        sigAddr(text, inst);
    }
    if (s.ldvpm) text.append("; ldvpm", .{});
    if (s.ldtmu) {
        text.append("; ldtmu", .{});
        sigAddr(text, inst);
    }
    if (s.ldtlb) {
        text.append("; ldtlb", .{});
        sigAddr(text, inst);
    }
    if (s.ldtlbu) {
        text.append("; ldtlbu", .{});
        sigAddr(text, inst);
    }
    if (s.ldunif) text.append("; ldunif", .{});
    if (s.ldunifrf) {
        text.append("; ldunifrf", .{});
        sigAddr(text, inst);
    }
    if (s.ldunifa) text.append("; ldunifa", .{});
    if (s.ldunifarf) {
        text.append("; ldunifarf", .{});
        sigAddr(text, inst);
    }
    if (s.wrtmuc) text.append("; wrtmuc", .{});
}

fn branch(text: *Text, inst: *const Instr) void {
    const b = &inst.branch;
    text.append("b", .{});
    if (b.ub) text.append("u", .{});
    text.append("{s}", .{instr.branchCondName(b.cond)});
    text.append("{s}", .{instr.msfignName(b.msfign)});

    switch (b.bdi) {
        .abs => text.append("  zero_addr+0x{x:0>8}", .{b.offset}),
        .rel => text.append("  {d}", .{@as(i32, @bitCast(b.offset))}),
        .link_reg => text.append("  lri", .{}),
        .regfile => text.append("  rf{d}", .{b.raddr_a}),
        _ => {},
    }

    if (b.ub) {
        switch (b.bdu) {
            .abs => text.append(", a:unif", .{}),
            .rel => text.append(", r:unif", .{}),
            .link_reg => text.append(", lri", .{}),
            .regfile => text.append(", rf{d}", .{b.raddr_a}),
            _ => {},
        }
    }
}

/// An instruction as Mesa's v3d_qpu_decode() prints it, in `buffer`.
pub fn decode(inst: *const Instr, buffer: []u8) []const u8 {
    var text = Text{ .buffer = buffer };
    switch (inst.kind) {
        .alu => {
            add(&text, inst);
            mul(&text, inst);
            sig(&text, inst);
        },
        .branch => branch(&text, inst),
    }
    return buffer[0..text.offset];
}

/// A word as Mesa's v3d_qpu_disasm() prints it, or null where the word is
/// no instruction (where Mesa asserts).
pub fn disasm(word: u64, buffer: []u8) ?[]const u8 {
    const inst = pack.unpack(word) orelse return null;
    return decode(&inst, buffer);
}
