// SPDX-License-Identifier: MIT
//! The temporaries given the QPU's registers: the port of Mesa's
//! src/broadcom/compiler/vir_register_allocate.c, its 7.1 paths, on the
//! graph colouring of ra.zig. Each temporary is a node of the graph, and
//! two whose live ranges (live.zig) overlap interfere; so do a temporary
//! live across an instruction that writes rf0 without naming it and a
//! node of its own that stands for rf0. A temporary moved out of a
//! payload register is given that register. Where the graph cannot be
//! coloured, temporaries are spilled until it can be: a uniform is loaded
//! again where it is read, a value the hardware gives again (the tile's
//! coordinates, the element's and the thread's indices, the sample) is
//! asked for again, and anything else is written to the TMU after it is
//! made and read back before it is read, over a thread switch each, so
//! far as the compile strategy allows.
//!
//! 7.1 has no accumulators, so the 4.x paths are left out: the classes
//! of accumulators and r5, and the choices between them and the register
//! file. So is force_register_spills, Mesa's debug option, which is 0.

const std = @import("std");
const assert = std.debug.assert;
const instr = @import("../qpu/instr.zig");
const list = @import("list.zig");
const live = @import("live.zig");
const ra = @import("ra.zig");
const vir = @import("vir.zig");
const Compile = vir.Compile;
const Block = vir.Block;
const Inst = vir.Inst;
const Reg = vir.Reg;
const QpuReg = vir.QpuReg;
const Error = vir.Error;

/// The register file's registers (PHYS_COUNT, vir_register_allocate.c:35).
const phys_count = 64;
/// Nodes that stand for registers written without being named, rf0 alone
/// on 7.1 (IMPLICIT_RF_COUNT, vir_register_allocate.c:33).
const implicit_rf_count = 1;
/// The first register of the file among the set's: none come before it
/// on 7.1 (get_phys_index, vir_register_allocate.c:38).
const phys_index = 0;
/// The lanes of a register (V3D_CHANNELS, common/v3d_limits.h:30).
const channels = 16;

/// The register file (CLASS_BITS_PHYS, vir_register_allocate.c:47); on
/// 7.1 it is any class, there being no accumulators (get_class_bit_any,
/// vir_register_allocate.c:59).
const class_bits_phys: u8 = 1 << 0;
const class_bits_any = class_bits_phys;

fn stageHasPayload(c: *const Compile) bool {
    return c.stage == .fragment or c.stage == .compute;
}

/// temp_to_node (vir_register_allocate.c:78).
fn tempToNode(temp: u32) u32 {
    return temp + implicit_rf_count;
}

/// node_to_temp (vir_register_allocate.c:85).
fn nodeToTemp(node: u32) u32 {
    assert(node >= implicit_rf_count);
    return node - implicit_rf_count;
}

fn getTempClassBits(c: *const Compile, temp: u32) u8 {
    return c.nodes.info[tempToNode(temp)].class_bits;
}

fn setTempClassBits(c: *Compile, temp: u32, class_bits: u8) void {
    c.nodes.info[tempToNode(temp)].class_bits = class_bits;
}

/// choose_reg_class (vir_register_allocate.c:108).
fn chooseRegClass(c: *const Compile, class_bits: u8) *ra.Class {
    const compiler = c.compiler.?;
    if (class_bits == class_bits_phys) return compiler.reg_class_phys[c.thread_index];
    assert(class_bits == class_bits_any);
    return compiler.reg_class_any[c.thread_index];
}

fn chooseRegClassForTemp(c: *const Compile, temp: u32) *ra.Class {
    assert(temp < c.num_temps and temp < c.nodes.alloc_count);
    return chooseRegClass(c, getTempClassBits(c, temp));
}

/// qinst_writes_tmu (vir_register_allocate.c:132).
fn qinstWritesTmu(inst: *const Inst) bool {
    return (inst.dst.file == .magic and instr.magicWaddrIsTmu(@intCast(inst.dst.index))) or inst.qpu.sig.wrtmuc;
}

/// `inst` is a tmuwt or ldtmu that no other ends before the TMU is
/// written again (is_end_of_tmu_sequence, vir_register_allocate.c:141).
fn isEndOfTmuSequence(inst: *Inst, block: *Block) bool {
    var is_tmuwt = inst.qpu.kind == .alu and inst.qpu.alu.add.op == .tmuwt;
    var is_ldtmu = inst.qpu.sig.ldtmu;
    if (!is_tmuwt and !is_ldtmu) return false;

    var scan = list.Each(Inst, "link", .forward){ .head = &block.instructions, .pos = inst.link.next.? };
    while (scan.next()) |scan_inst| {
        is_tmuwt = scan_inst.qpu.kind == .alu and scan_inst.qpu.alu.add.op == .tmuwt;
        is_ldtmu = scan_inst.qpu.sig.ldtmu;
        if (is_tmuwt or is_ldtmu) return false;
        if (qinstWritesTmu(scan_inst)) return true;
    }
    return true;
}

/// vir_is_mov_uniform (vir_register_allocate.c:169).
fn isMovUniform(c: *const Compile, temp: u32) bool {
    const def = c.defs[temp] orelse return false;
    return def.qpu.sig.ldunif;
}

/// The value is one the hardware gives whenever asked, with nothing done
/// to it (can_reconstruct_inst, vir_register_allocate.c:177).
fn canReconstructInst(inst: *const Inst) bool {
    if (!vir.isAdd(inst)) return false;
    return switch (inst.qpu.alu.add.op) {
        // None of these reads an operand, so no unpack is looked at;
        // fxcd and fycd have packed forms.
        .fxcd, .fycd, .xcd, .ycd, .iid, .eidx, .tidx, .sampid => inst.qpu.flags.ac == .none and
            inst.qpu.flags.auf == .none and
            inst.qpu.flags.apf == .none and
            inst.qpu.alu.add.output_pack == .none,
        else => false,
    };
}

fn canReconstructTemp(c: *const Compile, temp: u32) bool {
    const def = c.defs[temp] orelse return false;
    return canReconstructInst(def);
}

/// reconstruct_temp (vir_register_allocate.c:214).
fn reconstructTemp(c: *Compile, op: instr.AddOp) Error!Reg {
    return switch (op) {
        .fxcd, .fycd, .xcd, .ycd, .iid, .eidx, .tidx, .sampid => c.add(op, .{}),
        else => unreachable, // "Unexpected opcode for reconstruction"
    };
}

/// How a temporary is spilled (enum temp_spill_type,
/// vir_register_allocate.c:249).
const SpillType = enum { uniform, reconstruct, tmu };

fn getSpillTypeForTemp(c: *const Compile, temp: u32) SpillType {
    if (isMovUniform(c, temp)) return .uniform;
    if (canReconstructTemp(c, temp)) return .reconstruct;
    return .tmu;
}

/// The node to spill: each temporary's cost worked out over the program,
/// or those of the batch's first victim kept, which the spill made zero
/// for the node it spilled and the temporaries it made never have
/// (v3d_choose_spill_node, vir_register_allocate.c:268). A use of a
/// uniform or of a value the hardware gives again costs 1; a TMU spill's
/// use and definition 10, a use three times that inside a TMU operation.
/// Some temporaries are not to be spilled to the TMU at all: across a
/// multop and its umul24, whose rtop does not survive a thread switch;
/// after the last thread switch, where none can be put; where the
/// strategy allows none; and an ldvary's destination.
fn chooseSpillNode(c: *Compile, reuse_costs: bool) Error!?u32 {
    assert(c.num_temps > 1);
    const g = c.g.?;
    if (reuse_costs) return g.getBestSpillNode();

    const tmu_scale: f32 = 10;
    const block_scale: f32 = 1.0;
    const spill_costs = try c.allocator.alloc(f32, c.num_temps);
    defer c.allocator.free(spill_costs);
    @memset(spill_costs, 0.0);
    var in_tmu_operation = false;
    var rtop_hazard = false;
    var started_last_seg = false;

    // Mesa's own note: "XXX: Scale the cost up when inside of a loop."
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        var insts = vir.eachInst(block);
        while (insts.next()) |inst| {
            var is_multop = false;
            var is_umul24 = false;
            if (inst.qpu.kind == .alu) {
                if (inst.qpu.alu.mul.op == .multop) {
                    is_multop = true;
                    rtop_hazard = true;
                } else if (inst.qpu.alu.mul.op == .umul24) {
                    is_umul24 = true;
                }
            }

            const no_spilling = (c.threads > 1 and started_last_seg) or c.max_tmu_spills == 0;

            for (0..vir.getNsrc(inst)) |i| {
                if (inst.src[i].file != .temp) continue;
                const temp = inst.src[i].index;
                if (getSpillTypeForTemp(c, temp) != .tmu) {
                    spill_costs[temp] += block_scale;
                } else if (!no_spilling and (!rtop_hazard or is_multop)) {
                    const tmu_op_scale: f32 = if (in_tmu_operation) 3.0 else 1.0;
                    spill_costs[temp] += block_scale * tmu_scale * tmu_op_scale;
                } else {
                    vir.bitsetClear(c.spillable, temp);
                }
            }

            if (inst.dst.file == .temp) {
                const temp = inst.dst.index;
                if (getSpillTypeForTemp(c, temp) != .tmu) {
                    // Made again where it is read.
                } else if (!no_spilling and (!rtop_hazard or is_umul24)) {
                    spill_costs[temp] += block_scale * tmu_scale;
                } else {
                    vir.bitsetClear(c.spillable, temp);
                }
            }

            // An ldvary's destination spilled would keep its rf0 write
            // live across a thread switch.
            if (inst.qpu.sig.ldvary) {
                assert(inst.dst.file == .temp);
                vir.bitsetClear(c.spillable, inst.dst.index);
            }

            if (inst.is_last_thrsw) started_last_seg = true;

            // Between a TMU setup and its last ldtmu or tmuwt.
            if (isEndOfTmuSequence(inst, block)) in_tmu_operation = false;
            if (qinstWritesTmu(inst)) in_tmu_operation = true;

            if (is_umul24) rtop_hazard = false;
        }
    }

    // A last thread switch is always made, so that every spill comes
    // before the last thread section (vir_emit_last_thrsw).
    assert(started_last_seg);

    for (0..c.num_temps) |i| {
        if (vir.bitsetTest(c.spillable, i)) g.setNodeSpillCost(tempToNode(@intCast(i)), spill_costs[i]);
    }
    return g.getBestSpillNode();
}

/// Room in the nodes' information for the temporary just made, doubled
/// as Mesa doubles it (ensure_nodes, vir_register_allocate.c:398).
fn ensureNodes(c: *Compile) Error!void {
    if (c.num_temps < c.nodes.alloc_count) return;
    c.nodes.alloc_count *= 2;
    // Mesa leaves room for six more, its accumulators' count, on 7.1 too.
    c.nodes.info = try c.allocator.realloc(c.nodes.info, c.nodes.alloc_count + @max(6, implicit_rf_count));
}

/// The node of a temporary a spill made (add_node,
/// vir_register_allocate.c:415), its priority given once the spills are
/// in.
fn addNode(c: *Compile, temp: u32, class_bits: u8) Error!u32 {
    try ensureNodes(c);
    const node = try c.g.?.addNode(chooseRegClass(c, class_bits));
    assert(node == temp + implicit_rf_count);
    c.nodes.info[node] = .{ .class_bits = class_bits };
    return node;
}

/// The spill address of each lane of this thread, worked out once at the
/// program's start: the thread's share of the spill buffer, by a uniform
/// the driver gives, the lane's four bytes, and the buffer's offset
/// (v3d_setup_spill_base, vir_register_allocate.c:438). Its temporaries
/// are not spilled; while spilling, each is given a node, which no payload
/// register may be given where the stage has a payload. C leaves open
/// the order a call's arguments are worked out in, and so the order these
/// instructions come in; here it is the order they are written in.
///
/// As in Mesa, the ldunif reuse is not turned off here, and it has nothing
/// to find: the uniforms of the thread's share and of the offset are new
/// to the compile, and the constant 2, which the program may have loaded
/// already, is looked for back from the cursor to the block's head, among
/// this setup's own instructions, which load no 2.
pub fn setupSpillBase(c: *Compile) Error!void {
    const current_block = c.cur_block;
    c.cur_block = c.entryBlock();
    c.cursor = vir.beforeBlock(c.cur_block.?);

    const start_num_temps = c.num_temps;

    // Each thread in a region of the scratch space of its own, so that
    // the QPUs do not fight over cache lines; the driver keeps one spill
    // buffer for every program, and gives the size of a thread's share.
    const tidx = try c.add(.tidx, .{});
    const size_per_thread = try c.uniform(.spill_size_per_thread, 0);
    const thread_offset = try c.umul(tidx, size_per_thread);

    // Each lane four bytes.
    const eidx = try c.add(.eidx, .{});
    const two = try c.uniformUi(2);
    const element_offset = try c.add(.shl, .{ eidx, two });

    const offsets = try c.add(.add, .{ thread_offset, element_offset });
    const spill_offset = try c.uniform(.spill_offset, 0);
    c.spill_base = try c.add(.add, .{ offsets, spill_offset });

    for (start_num_temps..c.num_temps) |i| {
        vir.bitsetClear(c.spillable, i);
        if (c.spilling) {
            // spill_base is read across thread switches: never an
            // accumulator, of which 7.1 has none anyway.
            const node = try addNode(c, @intCast(i), class_bits_phys);
            c.nodes.info[node].payload_conflict = stageHasPayload(c);
        }
    }

    c.cur_block = current_block;
    c.cursor = vir.afterBlock(c.cur_block.?);
}

/// The address of a spill or a fill, and the rest of it
/// (v3d_emit_spill_tmua, vir_register_allocate.c:510):
///
///     ldunif.spill_offset
///     add tmuau, spill_base, spill_offset
///     thrsw
///
/// and then a tmuwt, for a spill, or an ldtmu into `fill_dst`, for a
/// fill. The TMU write's configuration is per quad, so that lanes of
/// helper invocations are spilled too, but not under a condition, where
/// a lane not written would overwrite what an earlier spill stored.
fn emitSpillTmua(c: *Compile, spill_offset: u32, cond: instr.Cond, ip: i32, fill_dst: ?*Reg) Error!void {
    assert(ip >= 0);

    // Read straight after, with no thread switch between: any class.
    assert(c.disable_ldunif_opt);
    const offset = try c.uniformUi(spill_offset);
    _ = try addNode(c, offset.index, class_bits_any);

    const tmua = vir.magicReg(.tmuau);
    const inst = try c.addDest(.add, tmua, .{ c.spill_base, offset });
    inst.qpu.flags.ac = cond;
    inst.ldtmu_count = 1;
    inst.uniform = try c.getUniformIndex(.constant, if (cond != .none) 0xffffffff else 0xffffff7f);

    try c.emitThrsw();

    // The tmuwt's temporary is not read, and the ldtmu's is at once: on
    // 4.x an accumulator would do, on 7.1 the register file is all there is.
    const temp_class = class_bits_phys;
    if (fill_dst) |dst| {
        dst.* = try c.ldtmu();
        assert(dst.file == .temp);
        _ = try addNode(c, dst.index, temp_class);
    } else {
        const dst = try c.add(.tmuwt, .{});
        assert(dst.file == .temp);
        _ = try addNode(c, dst.index, temp_class);
    }
    // The 4.x temporaries across the new thread switch are kept off the
    // accumulators here.
}

/// An unconditional write with no output pack, which defines the whole
/// register (qinst_writes_full_dst, vir_register_allocate.c:589); a
/// conditional one and a D.l or D.h keep the bits they do not write.
fn qinstWritesFullDst(inst: *const Inst) bool {
    return vir.getCond(inst) == .none and
        inst.qpu.alu.add.output_pack == .none and
        inst.qpu.alu.mul.output_pack == .none;
}

/// What the spill slot holds read into `temp` before `before`, a write
/// of part of it, so that it is defined whole: otherwise it is live into
/// the write, which cannot then be spilled, and the store of all of it
/// would write undefined bits over what the slot held
/// (v3d_emit_fill_for_partial_write, vir_register_allocate.c:602).
fn emitFillForPartialWrite(c: *Compile, temp: Reg, before: *Inst, spill_offset: u32) Error!void {
    var fill: Reg = undefined;
    c.cursor = vir.beforeInst(before);
    try emitSpillTmua(c, spill_offset, .none, before.ip, &fill);
    c.fills += 1;
    _ = try c.mulDest(.mov, temp, .{fill});
}

/// A spill of what `inst` writes, after `position` (v3d_emit_tmu_spill,
/// vir_register_allocate.c:616). Where the two are one, `inst` is made to
/// write a new temporary of its class, which is stored under `inst`'s
/// condition; a packed write, which leaves half of each lane, is filled
/// first and stored whole. Otherwise the spill was put off until the TMU
/// sequence `inst` is in ended, and is of `spill_temp`, the temporary
/// made for it then, whole: it may have been written more than once,
/// under conditions too.
fn emitTmuSpill(c: *Compile, inst: *Inst, spill_temp: Reg, position: *Inst, ip: i32, spill_offset: u32) Error!void {
    assert(inst.qpu.kind == .alu);
    assert(inst.dst.file == .temp);

    c.cursor = vir.afterInst(position);

    var cond = vir.getCond(inst);

    if (inst == position) {
        const class_bits = getTempClassBits(c, inst.dst.index);
        inst.dst = try c.getTemp();
        _ = try addNode(c, inst.dst.index, class_bits);

        // A conditional write is stored under its condition, and what
        // the slot held stays; but a packed one writes 16 bits of each
        // lane, so the other 16 are filled first. Mesa's own FIXME: only
        // where an earlier spill left something there is that needed.
        if (inst.qpu.alu.add.output_pack != .none or inst.qpu.alu.mul.output_pack != .none) {
            try emitFillForPartialWrite(c, inst.dst, inst, spill_offset);
            c.cursor = vir.afterInst(position);
            cond = .none;
        }
    } else {
        inst.dst = spill_temp;
        cond = .none;
    }

    const tmp = try c.mulDest(.mov, vir.magicReg(.tmud), .{inst.dst});
    tmp.qpu.flags.mc = cond;

    try emitSpillTmua(c, spill_offset, cond, ip, null);

    c.spills += 1;
    c.tmu_dirty_rcl = true;
}

/// interferes (vir_register_allocate.c:686): the ranges overlap, one
/// ending where the other starts not counting.
fn interferes(t0_start: i32, t0_end: i32, t1_start: i32, t1_end: i32) bool {
    return !(t0_start >= t1_end or t1_start >= t0_end);
}

/// The graph brought up to date after a spill or a batch of them
/// (v3d_update_spill_graph, vir_register_allocate.c:705). A spill keeps
/// the blocks and the order of what it did not touch, so two old
/// temporaries that did not overlap still do not, and their edges hold;
/// the temporaries from `first_new_temp` on are the spills' own and get
/// theirs, and spill_base, read by every TMU spill and fill, grows and
/// may get more. Every range's length is its node's priority again.
fn updateSpillGraph(c: *Compile, first_new_temp: u32, spill_base_edges_dirty: bool, num_temps_before_spills: u32) Error!void {
    assert(first_new_temp <= c.num_temps);
    try live.updateLiveIntervalsAfterSpill(c, num_temps_before_spills);
    assert(c.live_intervals_valid);
    const g = c.g.?;

    var sb_temp: u32 = 0;
    var sb_node: u32 = 0;
    var update_spill_base_edges = false;
    if (spill_base_edges_dirty) {
        assert(c.spill_base.file == .temp);
        assert(c.spill_base.index < c.num_temps);
        sb_temp = c.spill_base.index;
        sb_node = tempToNode(sb_temp);
        assert(c.temp_end[sb_temp] != -1);
        // A spill_base the batch made is among the new temporaries.
        update_spill_base_edges = sb_temp < first_new_temp;
    }

    var i: u32 = 0;
    while (i < c.num_temps) : (i += 1) {
        if (c.temp_end[i] == -1) continue;

        const node_i = tempToNode(i);
        c.nodes.info[node_i].priority = @bitCast(c.temp_end[i] -% c.temp_start[i]);

        var j = @max(i + 1, first_new_temp);
        while (j < c.num_temps) : (j += 1) {
            if (interferes(c.temp_start[i], c.temp_end[i], c.temp_start[j], c.temp_end[j])) {
                try g.addNodeInterference(node_i, tempToNode(j));
            }
        }

        if (update_spill_base_edges and i != sb_temp and
            interferes(c.temp_start[i], c.temp_end[i], c.temp_start[sb_temp], c.temp_end[sb_temp]))
        {
            try g.addNodeInterference(node_i, sb_node);
        }
    }
}

/// `spill_temp` spilled (v3d_spill_reg, vir_register_allocate.c:762): a
/// uniform loaded again before each instruction that reads it, a value
/// the hardware gives asked for again, or else stored to the TMU after
/// each write and read back before each read, its definitions given new
/// temporaries. Inside a TMU sequence, between the TMU's setup and its
/// last ldtmu or tmuwt, no other TMU access may come: a fill goes before
/// the sequence, and a spill waits for its end, a temporary of its own
/// taking the writes until then. The temporaries the spill makes are not
/// spilled in turn. Where the graph's update is put off, until the batch
/// of spills ends, its new temporaries have no edges yet.
fn spillReg(c: *Compile, implicit_rf_nodes: []const u32, spill_temp: u32, defer_graph_update: bool, num_temps_before_spills: u32) Error!void {
    const g = c.g.?;
    c.spill_start_num_temps = c.num_temps;
    c.spilling = true;
    defer c.spilling = false;

    const spill_type = getSpillTypeForTemp(c, spill_temp);

    var spill_offset: u32 = 0;
    if (spill_type == .tmu) {
        spill_offset = c.spill_size;
        c.spill_size += channels * @sizeOf(u32);

        if (spill_offset == 0) {
            try setupSpillBase(c);
            // Not rf0, which instructions write without naming it.
            try g.addNodeInterference(tempToNode(c.spill_base.index), implicit_rf_nodes[0]);
        }
    }

    const last_thrsw = c.last_thrsw;
    assert(last_thrsw != null and last_thrsw.?.is_last_thrsw);

    var uniform_index: u32 = ~@as(u32, 0);
    if (spill_type == .uniform) uniform_index = c.defs[spill_temp].?.uniform.?;

    var reconstruct_op: instr.AddOp = .nop;
    if (spill_type == .reconstruct) {
        const orig_def = c.defs[spill_temp].?;
        assert(vir.isAdd(orig_def));
        reconstruct_op = orig_def.qpu.alu.add.op;
    }

    const spill_node = tempToNode(spill_temp);

    // A uniform spilled is loaded again, not reused.
    const had_disable_ldunif_opt = c.disable_ldunif_opt;
    c.disable_ldunif_opt = true;
    defer c.disable_ldunif_opt = had_disable_ldunif_opt;

    var start_of_tmu_sequence: ?*Inst = null;
    var postponed_spill: ?*Inst = null;
    var postponed_spill_temp: Reg = .{};
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        var insts = vir.eachInstSafe(block);
        while (insts.next()) |inst| {
            const ip = inst.ip;

            if (isEndOfTmuSequence(inst, block)) {
                if (postponed_spill) |spill| try emitTmuSpill(c, spill, postponed_spill_temp, inst, ip, spill_offset);
                start_of_tmu_sequence = null;
                postponed_spill = null;
            }

            if (start_of_tmu_sequence == null and qinstWritesTmu(inst)) start_of_tmu_sequence = inst;

            // Fills.
            var filled_src: ?usize = null;
            for (0..vir.getNsrc(inst)) |i| {
                if (inst.src[i].file != .temp or inst.src[i].index != spill_temp) continue;

                if (filled_src) |filled| {
                    inst.src[i] = inst.src[filled];
                    continue;
                }

                c.cursor = vir.beforeInst(inst);

                switch (spill_type) {
                    .uniform => {
                        const unif = try c.uniform(c.uniform_contents[uniform_index], c.uniform_data[uniform_index]);
                        inst.src[i] = unif;
                        // Read by the next instruction: any class.
                        _ = try addNode(c, unif.index, class_bits_any);
                    },
                    .reconstruct => {
                        const temp = try reconstructTemp(c, reconstruct_op);
                        inst.src[i] = temp;
                        // Read by the next instruction: an accumulator would
                        // do on 4.x.
                        _ = try addNode(c, temp.index, class_bits_phys);
                    },
                    .tmu => {
                        if (postponed_spill != null) {
                            // Not stored yet: read where the writes went.
                            inst.src[i] = postponed_spill_temp;
                        } else {
                            var fill_ip = ip;
                            if (start_of_tmu_sequence) |start| {
                                c.cursor = vir.beforeInst(start);
                                fill_ip = start.ip;
                            }
                            try emitSpillTmua(c, spill_offset, .none, fill_ip, &inst.src[i]);
                            c.fills += 1;
                        }
                    },
                }

                filled_src = i;
            }

            // Spills.
            if (inst.dst.file == .temp and inst.dst.index == spill_temp) {
                if (spill_type != .tmu) {
                    c.cursor.link = null;
                    c.removeInstruction(inst);
                } else if (start_of_tmu_sequence) |start| {
                    // Put off to the sequence's end; the writes until
                    // then go to a temporary of their own.
                    if (postponed_spill) |spill| spill.dst = postponed_spill_temp;
                    if (postponed_spill == null or qinstWritesFullDst(inst)) {
                        postponed_spill_temp = try c.getTemp();
                        _ = try addNode(c, postponed_spill_temp.index, c.nodes.info[spill_node].class_bits);

                        // The spill put off may gather several writes,
                        // each whole or in part, and stores all of the
                        // register: one written in part is filled first,
                        // before the sequence, so as not to store
                        // garbage over what the slot held. Mesa's FIXME:
                        // only where an earlier spill left something
                        // there is that needed.
                        if (!qinstWritesFullDst(inst)) try emitFillForPartialWrite(c, postponed_spill_temp, start, spill_offset);
                    }
                    postponed_spill = inst;
                } else {
                    try emitTmuSpill(c, inst, postponed_spill_temp, inst, ip, spill_offset);
                }
            }
        }
    }

    // The last thread switch, not one a fill made.
    c.last_thrsw = last_thrsw;

    // Spilling what the spill made gains nothing.
    for (c.spill_start_num_temps..c.num_temps) |i| vir.bitsetClear(c.spillable, i);

    g.setNodeSpillCost(spill_node, 0);
    g.resetNodeInterference(spill_node);
    vir.bitsetClear(c.spillable, spill_temp);

    var ip: i32 = 0;
    var all = c.eachInstInorder();
    while (all.next()) |inst| {
        inst.ip = ip;
        ip += 1;
    }

    if (!defer_graph_update) try updateSpillGraph(c, c.spill_start_num_temps, spill_type == .tmu, num_temps_before_spills);
}

/// What the select callback works with (struct
/// v3d_ra_select_callback_data, vir_register_allocate.c:1020).
const SelectCallbackData = struct {
    phys_index: u32,
    /// The register to try first, which goes round the file.
    next_phys: u32,
    nodes: *const vir.RaNodes,
};

/// A register of the file for `node` (v3d_ra_select_rf,
/// vir_register_allocate.c:1106): rf0 for an ldunif's temporary, which
/// keeps it from becoming an ldunifrf, whose destination takes the
/// condition field; otherwise round the file from where the last choice
/// left off, rf0 kept for those until nothing else is left. A temporary of
/// the program's last instructions, or of the spill setup, which comes
/// before the payload is read, starts at rf4: the last three
/// instructions cannot use the early registers.
fn selectRf(v3d_ra: *SelectCallbackData, node: u32, regs: []const u32) ?u32 {
    const info = &v3d_ra.nodes.info[node];
    // A temporary not live anywhere.
    if (info.unused) return 0;

    if (info.try_rf0 and bitTest(regs, v3d_ra.phys_index)) return v3d_ra.phys_index;

    const safe_rf_start = 4;
    if ((info.is_program_end or info.payload_conflict) and v3d_ra.next_phys < safe_rf_start) {
        v3d_ra.next_phys = safe_rf_start;
    }

    for (0..phys_count) |i| {
        const phys_off: u32 = @intCast((v3d_ra.next_phys + i) % phys_count);
        if (phys_off == 0) continue;
        const phys = v3d_ra.phys_index + phys_off;
        if (bitTest(regs, phys)) {
            v3d_ra.next_phys = phys_off + 1;
            return phys;
        }
    }

    if (bitTest(regs, v3d_ra.phys_index)) {
        v3d_ra.next_phys = 1;
        return v3d_ra.phys_index;
    }
    return null;
}

fn bitTest(regs: []const u32, r: u32) bool {
    return regs[r / 32] & (@as(u32, 1) << @intCast(r % 32)) != 0;
}

/// v3d_ra_select_callback (vir_register_allocate.c:1170): on 7.1 there
/// is no accumulator to favour or fall back on, and the register file
/// always has the register the allocator says is left.
fn selectCallback(n: u32, regs: []u32, data: ?*anyopaque, optimistic: bool) u32 {
    _ = optimistic;
    const v3d_ra: *SelectCallbackData = @ptrCast(@alignCast(data.?));
    return selectRf(v3d_ra, n, regs) orelse unreachable; // "RA must pass us at least one possible reg."
}

/// The register sets, made once for every compile (vir_init_reg_sets,
/// vir_register_allocate.c:1194): for 1 and 2 threads all 64 registers of
/// the file, for 4 the first 32, each count a class of any register and
/// one of the file's, which on 7.1 are the same registers. The classes
/// are made in that order, so they are 0 to 3.
pub fn initRegSets(allocator: std.mem.Allocator) Error!vir.Compiler {
    const max_thread_index = 2;
    const regs = try ra.Regs.create(allocator, phys_index + phys_count);
    errdefer regs.destroy();

    var compiler: vir.Compiler = .{ .regs = regs, .reg_class_any = undefined, .reg_class_phys = undefined };
    for (0..max_thread_index) |threads| {
        compiler.reg_class_any[threads] = try regs.allocContigClass(1);
        compiler.reg_class_phys[threads] = try regs.allocContigClass(1);
        for (phys_index..phys_index + (@as(usize, phys_count) >> @intCast(threads))) |i| {
            compiler.reg_class_phys[threads].addReg(@intCast(i));
            compiler.reg_class_any[threads].addReg(@intCast(i));
        }
    }
    try regs.finalize();
    return compiler;
}

/// tmu_spilling_allowed (vir_register_allocate.c:1250).
fn tmuSpillingAllowed(c: *const Compile) bool {
    return c.spills + c.fills < c.max_tmu_spills;
}

/// A payload register on 7.1: W, centroid W and Z in rf1 to rf3 for a
/// fragment program, rf2 and rf3 for a compute one (reg_is_payload,
/// vir_register_allocate.c:1256).
fn regIsPayload(c: *const Compile, r: Reg) bool {
    if (r.file != .reg) return false;
    return switch (c.stage) {
        .fragment => r.index >= 1 and r.index <= 3,
        .compute => r.index == 2 or r.index == 3,
        else => false,
    };
}

/// inst_reads_payload (vir_register_allocate.c:1278).
fn instReadsPayload(c: *const Compile, inst: *const Inst) bool {
    if (inst.qpu.kind != .alu) return false;
    if (regIsPayload(c, inst.dst)) return true;
    if (regIsPayload(c, inst.src[0])) return true;
    if (vir.getNsrc(inst) > 1 and regIsPayload(c, inst.src[1])) return true;
    return false;
}

/// What `inst` asks of the graph and of its temporaries' classes
/// (update_graph_and_reg_classes_for_inst, vir_register_allocate.c:1296).
fn updateGraphAndRegClassesForInst(c: *Compile, implicit_rf_nodes: []const u32, last_ldvary_ip: i32, has_payload: bool, inst: *Inst) Error!void {
    const g = c.g.?;
    const ip = inst.ip;
    assert(ip >= 0);

    // What is live across an instruction that writes a register without
    // naming it is not in that register (r4 is 4.x's).
    if (instr.writesRf0Implicitly(&inst.qpu)) {
        for (0..c.num_temps) |i| {
            if (c.temp_start[i] < ip and c.temp_end[i] > ip) {
                try g.addNodeInterference(tempToNode(@intCast(i)), implicit_rf_nodes[0]);
            }
        }
    }

    if (inst.qpu.kind == .alu) {
        switch (inst.qpu.alu.add.op) {
            // An LDVPM writes a temporary alone (its MA flag says in or
            // out), and the SFU writes the register file: the file is the
            // only class on 7.1 anyway.
            .ldvpmv_in, .ldvpmv_out, .ldvpmd_in, .ldvpmd_out, .ldvpmp, .ldvpmg_in, .ldvpmg_out, .recip, .rsqrt, .exp, .log, .sin, .rsqrt2 => {
                assert(inst.dst.file == .temp);
                setTempClassBits(c, inst.dst.index, class_bits_phys);
            },
            else => {},
        }
    }

    if (inst.src[0].file == .reg) {
        switch (inst.src[0].index) {
            // 7.x does not put the payload in rf0.
            0 => {},
            // A payload move: its temporary is given the register, and
            // the move goes.
            1, 2, 3 => {
                assert(inst.qpu.alu.mul.op == .mov);
                assert(inst.dst.file == .temp);
                g.setNodeReg(tempToNode(inst.dst.index), phys_index + inst.src[0].index);
            },
            else => {},
        }
    }

    // Not rf0 for a temporary across a range where an ldvary's rf0 write
    // is live: the last ldvary, and a read of rf0 that takes it, bound it.
    if ((inst.src[0].file == .reg and inst.src[0].index == 0) or
        (vir.getNsrc(inst) > 1 and inst.src[1].file == .reg and inst.src[1].index == 0))
    {
        for (0..c.num_temps) |i| {
            if (c.temp_start[i] < ip and c.temp_end[i] > last_ldvary_ip) {
                try g.addNodeInterference(tempToNode(@intCast(i)), implicit_rf_nodes[0]);
            }
        }
    }

    // The spill setup is the one thing emitted before the payload is
    // read, so its temporaries are kept off the payload registers, which
    // they would overwrite first; for a spill setup made before the
    // allocation, for scratch, that is done here. A payload read is in
    // the entry block, which the walk back is bounded by.
    if (c.spill_size > 0 and has_payload and instReadsPayload(c, inst)) {
        const first_block = c.entryBlock();
        var back = list.Each(Inst, "link", .backward){ .head = &first_block.instructions, .pos = inst.link.prev.? };
        while (back.next()) |earlier| {
            if (earlier.qpu.kind != .alu) continue;
            if (earlier.dst.file == .temp) c.nodes.info[tempToNode(earlier.dst.index)].payload_conflict = true;
            if (earlier.src[0].file == .temp) c.nodes.info[tempToNode(earlier.src[0].index)].payload_conflict = true;
            if (vir.getNsrc(earlier) > 1 and earlier.src[1].file == .temp) {
                c.nodes.info[tempToNode(earlier.src[1].index)].payload_conflict = true;
            }
        }
    }

    if (inst.dst.file == .temp) {
        // An ldvary's destination is not rf0, which it writes too.
        if (inst.qpu.sig.ldvary) try g.addNodeInterference(tempToNode(inst.dst.index), implicit_rf_nodes[0]);

        // An ldunif's or ldunifa's destination is tried in rf0, which
        // spares it becoming an ldunifrf; but not near an ldvary, whose
        // rf0 writes would keep them from pairing.
        if ((inst.qpu.sig.ldunif or inst.qpu.sig.ldunifa) and
            (c.stage != .fragment or ip > last_ldvary_ip + 4))
        {
            c.nodes.info[tempToNode(inst.dst.index)].try_rf0 = true;
        }
    }
    // The accumulators lost across a thread switch are 4.x's.
}

/// The temporaries of the last six ALU instructions of a fragment
/// program, which can then be kept off the early registers that the last
/// three instructions cannot use (flag_program_end_nodes,
/// vir_register_allocate.c:1505).
fn flagProgramEndNodes(c: *Compile) void {
    var last_set_count: u32 = 6;
    const last_block = c.exitBlock();
    var insts = vir.eachInstRev(last_block);
    while (insts.next()) |inst| {
        if (inst.qpu.kind != .alu) continue;

        for (0..instr.addOpNumSrc(inst.qpu.alu.add.op)) |i| {
            if (inst.src[i].file == .temp) c.nodes.info[tempToNode(inst.src[i].index)].is_program_end = true;
        }
        for (0..instr.mulOpNumSrc(inst.qpu.alu.mul.op)) |i| {
            if (inst.src[i].file == .temp) c.nodes.info[tempToNode(inst.src[i].index)].is_program_end = true;
        }
        if (inst.dst.file == .temp) c.nodes.info[tempToNode(inst.dst.index)].is_program_end = true;

        last_set_count -= 1;
        if (last_set_count == 0) break;
    }
}

/// Each temporary's register of the file, or null where spilling cannot
/// make them fit, as the compile strategy has it (v3d_register_allocate,
/// vir_register_allocate.c:1548). The registers are the caller's, freed
/// with the compile's allocator.
///
/// A failed colouring is what takes the time, so a batch of temporaries
/// is spilled before the next: the most where the pressure is far over
/// the registers the threads leave, otherwise one more for every four
/// over, down to one as it comes near, so that the last colouring lands.
pub fn registerAllocate(c: *Compile) Error!?[]QpuReg {
    var implicit_rf_nodes: [implicit_rf_count]u32 = undefined;
    const num_ra_nodes = c.num_temps + implicit_rf_count;

    c.nodes = .{ .alloc_count = c.num_temps, .info = try c.allocator.alloc(vir.RaNodeInfo, num_ra_nodes) };
    defer {
        c.allocator.free(c.nodes.info);
        c.nodes = .{};
        if (c.g) |g| g.destroy();
        c.g = null;
    }

    // Start at rf4, to keep the tile buffer's writes off rf2 and rf3.
    var callback_data: SelectCallbackData = .{ .phys_index = phys_index, .next_phys = 4, .nodes = &c.nodes };

    const num_temps_before_spills = c.num_temps;

    if (!c.live_intervals_valid) try live.calculateLiveIntervals(c);

    // 1, 2 and 4 threads to the classes' 0, 0 and 1.
    c.thread_index = @ctz(@as(u32, c.threads));
    if (c.thread_index >= 1) c.thread_index -= 1;

    c.g = try ra.Graph.create(c.allocator, c.compiler.?.regs, num_ra_nodes);
    const g = c.g.?;
    g.setSelectRegCallback(selectCallback, &callback_data);

    // A node given rf0, which instructions write without naming it, for
    // temporaries to interfere with: classes of their own would take a
    // lot of memory to set up.
    for (0..num_ra_nodes) |at| {
        const i: u32 = @intCast(at);
        c.nodes.info[i] = .{};
        if (i < implicit_rf_count) {
            implicit_rf_nodes[i] = i;
            g.setNodeReg(implicit_rf_nodes[i], phys_index + i);
        } else {
            const t = nodeToTemp(i);
            c.nodes.info[i].priority = @bitCast(c.temp_end[t] -% c.temp_start[t]);
            c.nodes.info[i].class_bits = class_bits_any;
        }
    }

    // The instructions' restrictions on the classes, and the edges they
    // add. The ldunifs' rf0 writes are temporaries, and the liveness has
    // them; an ldvary writes rf0 itself, whose range the last ldvary
    // marks, one past it as Mesa counts.
    var ip: i32 = 0;
    var last_ldvary_ip: i32 = -1;
    const has_payload = stageHasPayload(c);
    var insts = c.eachInstInorder();
    while (insts.next()) |inst| {
        inst.ip = ip;
        ip += 1;
        if (inst.qpu.sig.ldvary) last_ldvary_ip = ip;
        try updateGraphAndRegClassesForInst(c, &implicit_rf_nodes, last_ldvary_ip, has_payload, inst);
    }

    // For a fragment program alone: kept off the registers the last
    // instructions cannot use, its last thread switch may come earlier;
    // the other stages end in VPM stores with a small immediate, whose
    // signals keep the thread switch where it is anyway.
    if (c.stage == .fragment) flagProgramEndNodes(c);

    for (0..c.num_temps) |i| g.setNodeClass(tempToNode(@intCast(i)), chooseRegClassForTemp(c, @intCast(i)));

    // The edges of the live ranges, and the temporaries not live at all.
    var i: u32 = 0;
    while (i < c.num_temps) : (i += 1) {
        if (c.temp_start[i] > c.temp_end[i]) c.nodes.info[tempToNode(i)].unused = true;
        var j = i + 1;
        while (j < c.num_temps) : (j += 1) {
            if (interferes(c.temp_start[i], c.temp_end[i], c.temp_start[j], c.temp_end[j])) {
                try g.addNodeInterference(tempToNode(i), tempToNode(j));
            }
        }
    }

    while (true) {
        if (try g.allocate()) break;

        const bulk_spill_cap: u32 = 16;
        const budget = @as(u32, phys_count) >> @intCast(c.thread_index);
        const pressure = try c.getMaxTemps();
        const excess = if (pressure > budget) pressure - budget else 0;
        const batch: u32 = if (excess > 2 * bulk_spill_cap) bulk_spill_cap else excess / 4 + 1;
        assert(batch > 0);

        // With no accumulators to keep track of between victims, a batch
        // is spilled before the graph is brought up to date: its new
        // temporaries have no edges until then, and are not spillable,
        // so no victim after the first is one of them.
        const defer_graph_update = batch > 1;
        const first_batch_temp = c.num_temps;
        var spill_base_edges_dirty = false;

        var k: u32 = 0;
        while (k < batch) : (k += 1) {
            const node = (try chooseSpillNode(c, k > 0)) orelse {
                if (k > 0) break;
                return null;
            };
            const temp = nodeToTemp(node);
            const spill_type = getSpillTypeForTemp(c, temp);
            if (spill_type == .tmu and !tmuSpillingAllowed(c)) {
                if (k > 0) break;
                return null;
            }

            spill_base_edges_dirty = spill_base_edges_dirty or spill_type == .tmu;
            try spillReg(c, &implicit_rf_nodes, temp, defer_graph_update, num_temps_before_spills);
            assert(!vir.bitsetTest(c.spillable, temp));
            if (c.spills + c.fills > c.max_tmu_spills) return null;
        }

        if (defer_graph_update) {
            if (std.debug.runtime_safety) {
                for (first_batch_temp..c.num_temps) |t| assert(!vir.bitsetTest(c.spillable, t));
            }
            try updateSpillGraph(c, first_batch_temp, spill_base_edges_dirty, num_temps_before_spills);
        }
    }

    // Allocated: each temporary's register, all of them the file's on 7.1.
    const temp_registers = try c.allocator.alloc(QpuReg, c.num_temps);
    for (temp_registers, 0..) |*r, t| {
        const ra_reg = g.getNodeReg(tempToNode(@intCast(t)));
        r.* = .{ .magic = false, .index = @intCast(ra_reg - phys_index) };
    }
    return temp_registers;
}
