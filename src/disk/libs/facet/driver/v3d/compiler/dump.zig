// SPDX-License-Identifier: MIT
//! A compile's VIR as text, the way Mesa prints it: the port of Mesa's
//! src/broadcom/compiler/vir_dump.c, its 7.1 paths. An instruction reads
//! as its op with its condition and flags, the destination and the
//! operands as VIR has them (t3 for a temporary, rf3 for a register,
//! tmud for a magic address), its signals, and the uniform it reads.
//!
//! Mesa prints a float with C's "%f", which `float` does here, and a
//! string it has no name for as glibc does, "(null)". The pressure
//! columns vir_dump prints beside each instruction once the live ranges
//! are known come with the port of vir_live_variables.c.

const std = @import("std");
const instr = @import("../qpu/instr.zig");
const pack = @import("../qpu/pack.zig");
const vir = @import("vir.zig");
const Compile = vir.Compile;
const Inst = vir.Inst;
const Reg = vir.Reg;
const Writer = std.Io.Writer;

/// A float as C's printf "%f" writes the double it is promoted to: six
/// decimals, and glibc's nan, -nan, inf and -inf.
fn float(w: *Writer, value: f32) Writer.Error!void {
    if (std.math.isNan(value)) return w.writeAll(if (std.math.signbit(value)) "-nan" else "nan");
    if (std.math.isInf(value)) return w.writeAll(if (value < 0) "-inf" else "inf");
    try w.print("{d:.6}", .{@as(f64, value)});
}

/// A string Mesa may have none of, as glibc prints a null "%s".
fn name(w: *Writer, text: ?[]const u8) Writer.Error!void {
    try w.writeAll(text orelse "(null)");
}

/// What a uniform holds (vir_dump_uniform, vir_dump.c:30).
pub fn uniform(w: *Writer, contents: vir.Uniform, data: u32) Writer.Error!void {
    const unit = vir.unitDataGetUnit(data);
    const offset = vir.unitDataGetOffset(data);
    const signed: i32 = @bitCast(data);
    switch (contents) {
        .constant => {
            try w.print("0x{x:0>8} / ", .{data});
            try float(w, @bitCast(data));
        },
        .uniform => try w.print("push[{d}]", .{signed}),
        .tmu_config_p0 => try w.print("tex[{d}].p0 | 0x{x}", .{ unit, offset }),
        .tmu_config_p1 => try w.print("tex[{d}].p1 | 0x{x}", .{ unit, offset }),
        .image_tmu_config_p0 => try w.print("img[{d}].p0 | 0x{x}", .{ unit, offset }),
        .texture_width => try w.print("tex[{d}].width", .{signed}),
        .texture_height => try w.print("tex[{d}].height", .{signed}),
        .texture_depth => try w.print("tex[{d}].depth", .{signed}),
        .texture_array_size => try w.print("tex[{d}].array_size", .{signed}),
        .texture_levels => try w.print("tex[{d}].levels", .{signed}),
        .image_width => try w.print("img[{d}].width", .{signed}),
        .image_height => try w.print("img[{d}].height", .{signed}),
        .image_depth => try w.print("img[{d}].depth", .{signed}),
        .image_array_size => try w.print("img[{d}].array_size", .{signed}),
        .spill_offset => try w.writeAll("spill_offset"),
        .spill_size_per_thread => try w.writeAll("spill_size_per_thread"),
        .ubo_addr => try w.print("ubo[{d}]+0x{x}", .{ unit, offset }),
        .ssbo_offset => try w.print("ssbo[{d}]", .{signed}),
        .get_ssbo_size => try w.print("ssbo_size[{d}]", .{signed}),
        .get_ubo_size => try w.print("ubo_size[{d}]", .{signed}),
        .num_work_groups => try w.print("num_wg.{c}", .{if (data < 3) "xyz"[data] else '?'}),
        // The names Mesa's table has, and the number for the rest.
        .line_width => try w.writeAll("line_width"),
        .aa_line_width => try w.writeAll("aa_line_width"),
        .viewport_x_scale => try w.writeAll("vp_x_scale"),
        .viewport_y_scale => try w.writeAll("vp_y_scale"),
        .viewport_z_offset => try w.writeAll("vp_z_offset"),
        .viewport_z_scale => try w.writeAll("vp_z_scale"),
        .shared_offset => try w.writeAll("shared_offset"),
        else => try w.print("{d} / 0x{x:0>8}", .{ @intFromEnum(contents), data }),
    }
}

/// A register as VIR names it (vir_dump_reg, vir_dump.c:141).
fn register(w: *Writer, qinst: *const Inst, r: Reg) Writer.Error!void {
    switch (r.file) {
        .null => try w.writeAll("null"),
        .load_imm => {
            try w.print("0x{x:0>8} (", .{r.index});
            try float(w, @bitCast(r.index));
            try w.writeAll(")");
        },
        .reg => try w.print("rf{d}", .{r.index}),
        .magic => try name(w, instr.magicWaddrName(@intCast(r.index))),
        .small_imm => {
            const unpacked = pack.smallImmUnpack(qinst.qpu.raddr_b).?;
            // Mesa compares the packed index, not the value, against
            // -16..15: the integers 0 to 15 print as such, and -16 to -1,
            // at 16 to 31, print as the floats their bits are.
            const index: i8 = @bitCast(@as(u8, qinst.qpu.raddr_b));
            if (index >= -16 and index <= 15) {
                try w.print("{d}", .{@as(i32, @bitCast(unpacked))});
            } else {
                try float(w, @bitCast(unpacked));
            }
        },
        .temp => try w.print("t{d}", .{r.index}),
    }
}

/// Where a signal writes (vir_dump_sig_addr, vir_dump.c:188).
fn sigAddr(w: *Writer, qpu: *const instr.Instr) Writer.Error!void {
    if (!qpu.sig_magic) return w.print("rf{d}", .{qpu.sig_addr});
    if (instr.magicWaddrName(qpu.sig_addr)) |text| {
        try w.writeAll(text);
    } else {
        try w.print("UNKNOWN{d}", .{qpu.sig_addr});
    }
}

/// The signals, each after "; " (vir_dump_sig, vir_dump.c:204).
fn signals(w: *Writer, qinst: *const Inst) Writer.Error!void {
    const sig = qinst.qpu.sig;
    if (sig.thrsw) try w.writeAll("; thrsw");
    if (sig.ldvary) {
        try w.writeAll("; ldvary.");
        try sigAddr(w, &qinst.qpu);
    }
    if (sig.ldvpm) try w.writeAll("; ldvpm");
    if (sig.ldtmu) {
        try w.writeAll("; ldtmu.");
        try sigAddr(w, &qinst.qpu);
    }
    if (sig.ldtlb) {
        try w.writeAll("; ldtlb.");
        try sigAddr(w, &qinst.qpu);
    }
    if (sig.ldtlbu) {
        try w.writeAll("; ldtlbu.");
        try sigAddr(w, &qinst.qpu);
    }
    if (sig.ldunif) try w.writeAll("; ldunif");
    if (sig.ldunifrf) {
        try w.writeAll("; ldunifrf.");
        try sigAddr(w, &qinst.qpu);
    }
    if (sig.ldunifa) try w.writeAll("; ldunifa");
    if (sig.ldunifarf) {
        try w.writeAll("; ldunifarf.");
        try sigAddr(w, &qinst.qpu);
    }
    if (sig.wrtmuc) try w.writeAll("; wrtmuc");
}

/// An ALU instruction: the side that works, or the mul side's nop where
/// neither does (vir_dump_alu, vir_dump.c:256).
fn alu(w: *Writer, qinst: *const Inst) Writer.Error!void {
    const qpu = &qinst.qpu;
    const nsrc = vir.getNsrc(qinst);
    var unpack: [2]instr.InputUnpack = undefined;
    if (qpu.alu.add.op != .nop) {
        try w.print("{s}{s}{s}{s} ", .{ instr.addOpName(qpu.alu.add.op), instr.condName(qpu.flags.ac), instr.pfName(qpu.flags.apf), instr.ufName(qpu.flags.auf) });
        try register(w, qinst, qinst.dst);
        try w.writeAll(instr.packName(qpu.alu.add.output_pack));
        unpack = .{ qpu.alu.add.a.unpack, qpu.alu.add.b.unpack };
    } else {
        try w.print("{s}{s}{s}{s} ", .{ instr.mulOpName(qpu.alu.mul.op), instr.condName(qpu.flags.mc), instr.pfName(qpu.flags.mpf), instr.ufName(qpu.flags.muf) });
        try register(w, qinst, qinst.dst);
        try w.writeAll(instr.packName(qpu.alu.mul.output_pack));
        unpack = .{ qpu.alu.mul.a.unpack, qpu.alu.mul.b.unpack };
    }
    for (0..nsrc) |at| {
        try w.writeAll(", ");
        try register(w, qinst, qinst.src[at]);
        try w.writeAll(instr.unpackName(unpack[at]));
    }
    try signals(w, qinst);
}

/// One instruction, and the uniform it reads (vir_dump_inst,
/// vir_dump.c:306).
pub fn inst(w: *Writer, c: *const Compile, each: *const Inst) Writer.Error!void {
    const qpu = &each.qpu;
    switch (qpu.kind) {
        .alu => try alu(w, each),
        .branch => {
            try w.print("b{s}{s}{s}", .{ if (qpu.branch.ub) "u" else "", instr.branchCondName(qpu.branch.cond), instr.msfignName(qpu.branch.msfign) });
            switch (qpu.branch.bdi) {
                .abs => try w.print("  zero_addr+0x{x:0>8}", .{qpu.branch.offset}),
                .rel => try w.print("  {d}", .{@as(i32, @bitCast(qpu.branch.offset))}),
                .link_reg => try w.writeAll("  lri"),
                .regfile => try w.print("  rf{d}", .{qpu.branch.raddr_a}),
                _ => {},
            }
            if (qpu.branch.ub) {
                switch (qpu.branch.bdu) {
                    .abs => try w.writeAll(", a:unif"),
                    .rel => try w.writeAll(", r:unif"),
                    .link_reg => try w.writeAll(", lri"),
                    .regfile => try w.print(", rf{d}", .{qpu.branch.raddr_a}),
                    _ => {},
                }
            }
        },
    }
    if (each.uniform) |index| {
        try w.writeAll(" (");
        try uniform(w, c.uniform_contents[index], c.uniform_data[index]);
        try w.writeAll(")");
    }
}

/// Every block, its instructions a line each and the blocks it goes on
/// to (vir_dump, vir_dump.c:378).
pub fn program(w: *Writer, c: *Compile) Writer.Error!void {
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        try w.print("BLOCK {d}:\n", .{block.index});
        var insts = vir.eachInst(block);
        while (insts.next()) |each| {
            try inst(w, c, each);
            try w.writeAll("\n");
        }
        if (block.successors[1]) |second| {
            try w.print("-> BLOCK {d}, {d}\n", .{ block.successors[0].?.index, second.index });
        } else if (block.successors[0]) |first| {
            try w.print("-> BLOCK {d}\n", .{first.index});
        }
    }
    try w.writeAll("\n");
}
