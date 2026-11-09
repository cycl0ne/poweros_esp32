// SPDX-License-Identifier: MIT
//! The QPU's instructions put in the order they run in, two operations an
//! instruction where they pair: the port of Mesa's
//! src/broadcom/compiler/qpu_schedule.c, its 7.1 paths. Each block's
//! instructions, their registers given, become the nodes of a DAG of
//! what must come before what, found walking the block forward and then
//! back; then, cycle by cycle, a head of the DAG is chosen by a list
//! scheduler's heuristics, and another merged into it where the two
//! fit. A thread switch is moved back into the instructions before it to
//! fill its two delay slots, and a branch likewise into its three; the
//! program ends with a thread switch of its own.
//!
//! 7.1 has no accumulators and no muxes, so the 4.x paths are left out:
//! the r3 to r5 writes, the mux reads and the merging of raddr_a and
//! raddr_b. So is the debug dump, which only prints.

const std = @import("std");
const assert = std.debug.assert;
const instr = @import("../qpu/instr.zig");
const pack = @import("../qpu/pack.zig");
const list = @import("list.zig");
const dag_mod = @import("dag.zig");
const vir = @import("vir.zig");
const Link = list.Link;
const Dag = dag_mod.Dag;
const Compile = vir.Compile;
const Block = vir.Block;
const Inst = vir.Inst;
const Instr = instr.Instr;
const Waddr = instr.Waddr;
const Error = vir.Error;

fn magic(waddr: Waddr) u6 {
    return instr.magic(waddr);
}

/// An instruction as the scheduler holds it (struct schedule_node,
/// qpu_schedule.c:45). Mesa's latency field, which nothing reads, is left
/// out.
const Node = struct {
    dag: dag_mod.Node = .{},
    link: Link = .{},
    inst: *Inst,
    /// The latest a parent's cycle and latency allow it to start.
    unblocked_time: u32 = 0,
    /// The fewest cycles from it to the program's end, by the slowest
    /// chain of its children.
    delay: u32 = 0,

    fn of(node: *dag_mod.Node) *Node {
        return @fieldParentPtr("dag", node);
    }
};

/// Walking the block back, before and after swap (enum direction,
/// qpu_schedule.c:67).
const Direction = enum { forward, reverse };

/// The last instruction to touch each thing the order is kept for
/// (struct schedule_state, qpu_schedule.c:70).
const State = struct {
    dag: *Dag,
    last_r: [6]?*Node = @splat(null),
    last_rf: [64]?*Node = @splat(null),
    last_sf: ?*Node = null,
    last_vpm_read: ?*Node = null,
    last_tmu_write: ?*Node = null,
    last_tmu_config: ?*Node = null,
    last_tmu_read: ?*Node = null,
    last_tlb: ?*Node = null,
    last_vpm: ?*Node = null,
    last_unif: ?*Node = null,
    last_rtop: ?*Node = null,
    last_unifa: ?*Node = null,
    last_setmsf: ?*Node = null,
    last_nn_mode: ?*Node = null,
    dir: Direction,
};

/// `after` after `before`, or before it walking back; an edge of a read
/// found walking back is a write after a read, which its data says
/// (add_dep, qpu_schedule.c:96): that edge goes first, so the write can
/// pair with the read.
fn addDep(state: *State, before: ?*Node, after: ?*Node, write: bool) Error!void {
    const write_after_read = !write and state.dir == .reverse;
    const edge_data: usize = @intFromBool(write_after_read);
    const b = before orelse return;
    const a = after orelse return;
    assert(b != a);
    if (state.dir == .forward) {
        try state.dag.addEdge(&b.dag, &a.dag, edge_data);
    } else {
        try state.dag.addEdge(&a.dag, &b.dag, edge_data);
    }
}

fn addReadDep(state: *State, before: ?*Node, after: *Node) Error!void {
    try addDep(state, before, after, false);
}

fn addWriteDep(state: *State, before: *?*Node, after: *Node) Error!void {
    try addDep(state, before.*, after, true);
    before.* = after;
}

/// qpu_inst_is_tlb (qpu_schedule.c:133).
fn qpuInstIsTlb(inst: *const Instr) bool {
    if (inst.sig.ldtlb or inst.sig.ldtlbu) return true;
    if (inst.kind != .alu) return false;
    if (inst.alu.add.op != .nop and inst.alu.add.magic_write and
        (inst.alu.add.waddr == magic(.tlb) or inst.alu.add.waddr == magic(.tlbu))) return true;
    if (inst.alu.mul.op != .nop and inst.alu.mul.magic_write and
        (inst.alu.mul.waddr == magic(.tlb) or inst.alu.mul.waddr == magic(.tlbu))) return true;
    return false;
}

/// process_raddr_deps (qpu_schedule.c:179): a register read, after its
/// write.
fn processRaddrDeps(state: *State, n: *Node, raddr: u6, is_small_imm: bool) Error!void {
    if (!is_small_imm) try addReadDep(state, state.last_rf[raddr], n);
}

/// tmu_write_is_sequence_terminator (qpu_schedule.c:189): the write that
/// starts the lookup.
fn tmuWriteIsSequenceTerminator(waddr: u6) bool {
    return switch (@as(Waddr, @enumFromInt(waddr))) {
        .tmus, .tmuscm, .tmusf, .tmuslod, .tmua, .tmuau => true,
        else => false,
    };
}

/// is_tmu_sequence_terminator (qpu_schedule.c:205).
fn isTmuSequenceTerminator(inst: *const Inst) bool {
    if (inst.qpu.kind != .alu) return false;
    if (inst.qpu.alu.add.op != .nop) {
        if (!inst.qpu.alu.add.magic_write) return false;
        return tmuWriteIsSequenceTerminator(inst.qpu.alu.add.waddr);
    }
    if (inst.qpu.alu.mul.op != .nop) {
        if (!inst.qpu.alu.mul.magic_write) return false;
        return tmuWriteIsSequenceTerminator(inst.qpu.alu.mul.waddr);
    }
    return false;
}

/// can_reorder_tmu_write (qpu_schedule.c:226): the configuration writes
/// of a lookup may come in any order, but not its data or its start.
fn canReorderTmuWrite(waddr: u6) bool {
    if (tmuWriteIsSequenceTerminator(waddr)) return false;
    if (waddr == magic(.tmud)) return false;
    return true;
}

/// process_waddr_deps (qpu_schedule.c:238).
fn processWaddrDeps(state: *State, n: *Node, waddr: u6, magic_write: bool) Error!void {
    if (!magic_write) {
        try addWriteDep(state, &state.last_rf[waddr], n);
    } else if (instr.magicWaddrIsTmu(waddr)) {
        if (canReorderTmuWrite(waddr)) {
            try addReadDep(state, state.last_tmu_write, n);
        } else {
            try addWriteDep(state, &state.last_tmu_write, n);
        }
        if (tmuWriteIsSequenceTerminator(waddr)) try addWriteDep(state, &state.last_tmu_config, n);
    } else if (instr.magicWaddrIsSfu(waddr)) {
        // Mesa's v3d_qpu_writes_r4() check, 4.x's.
    } else switch (@as(Waddr, @enumFromInt(waddr))) {
        .r0, .r1, .r2 => try addWriteDep(state, &state.last_r[waddr - magic(.r0)], n),
        // r3, r4 and r5 (quad is r5's address): the checks of their
        // writes are 4.x's.
        .r3, .r4, .quad => {},
        .vpm, .vpmu => try addWriteDep(state, &state.last_vpm, n),
        .tlb, .tlbu => try addWriteDep(state, &state.last_tlb, n),
        // A barrier against every other memory access; ALU operations
        // need none.
        .sync, .syncb, .syncu => {
            try addWriteDep(state, &state.last_tmu_write, n);
            try addWriteDep(state, &state.last_tmu_read, n);
        },
        .unifa => try addWriteDep(state, &state.last_unifa, n),
        .nop => {},
        // Mesa logs it and aborts.
        else => @panic("Unknown waddr"),
    }
}

/// What an instruction must come after and before, walking either way
/// (calculate_deps, qpu_schedule.c:311): for things like "every read of
/// a register between the writes around it".
fn calculateDeps(state: *State, n: *Node) Error!void {
    const qinst = n.inst;
    const inst = &qinst.qpu;
    // Mesa's FIXME: the VPM's input and output segments are taken to be
    // shared, so every read of it comes before every write.
    const separate_vpm_segment = false;

    if (inst.kind == .branch) {
        if (inst.branch.cond != .always) try addReadDep(state, state.last_sf, n);
        // Mesa's XXX: BDI, BDU, ub, raddr_a.
        try addWriteDep(state, &state.last_unif, n);
        return;
    }
    assert(inst.kind == .alu);

    // Mesa's XXX: LOAD_IMM.
    if (instr.addOpNumSrc(inst.alu.add.op) > 0) try processRaddrDeps(state, n, inst.alu.add.a.raddr, inst.sig.small_imm_a);
    if (instr.addOpNumSrc(inst.alu.add.op) > 1) try processRaddrDeps(state, n, inst.alu.add.b.raddr, inst.sig.small_imm_b);
    if (instr.mulOpNumSrc(inst.alu.mul.op) > 0) try processRaddrDeps(state, n, inst.alu.mul.a.raddr, inst.sig.small_imm_c);
    if (instr.mulOpNumSrc(inst.alu.mul.op) > 1) try processRaddrDeps(state, n, inst.alu.mul.b.raddr, inst.sig.small_imm_d);

    switch (inst.alu.add.op) {
        // Its uniform could say whether it reads or writes.
        .vpmsetup => {
            try addWriteDep(state, &state.last_vpm, n);
            try addWriteDep(state, &state.last_vpm_read, n);
        },
        .stvpmv, .stvpmd, .stvpmp => try addWriteDep(state, &state.last_vpm, n),
        .ldvpmv_in, .ldvpmd_in, .ldvpmg_in, .ldvpmp => {
            if (!separate_vpm_segment) try addWriteDep(state, &state.last_vpm, n);
        },
        .vpmwt => try addReadDep(state, state.last_vpm, n),
        .msf => {
            try addReadDep(state, state.last_tlb, n);
            try addReadDep(state, state.last_setmsf, n);
        },
        .setmsf => {
            try addWriteDep(state, &state.last_setmsf, n);
            try addWriteDep(state, &state.last_tmu_write, n);
            try addWriteDep(state, &state.last_tlb, n);
        },
        .setrevf => try addWriteDep(state, &state.last_tlb, n),
        .ballot, .bcastf, .alleq, .allfeq => try addReadDep(state, state.last_setmsf, n),
        // The sign mode a v8dot reads, from this instruction on.
        .setnnmode_uu, .setnnmode_su, .setnnmode_us, .setnnmode_ss => try addWriteDep(state, &state.last_nn_mode, n),
        else => {},
    }

    switch (inst.alu.mul.op) {
        // multop sets rtop, and umul24 reads it and sets it to 0.
        .multop, .umul24 => try addWriteDep(state, &state.last_rtop, n),
        // Kept out of a multop and its umul24.
        .umul24_rtop0 => try addReadDep(state, state.last_rtop, n),
        .v8dot => try addReadDep(state, state.last_nn_mode, n),
        else => {},
    }

    if (inst.alu.add.op != .nop) try processWaddrDeps(state, n, inst.alu.add.waddr, inst.alu.add.magic_write);
    if (inst.alu.mul.op != .nop) try processWaddrDeps(state, n, inst.alu.mul.waddr, inst.alu.mul.magic_write);
    if (instr.sigWritesAddress(inst.sig)) try processWaddrDeps(state, n, inst.sig_addr, inst.sig_magic);

    // The r3, r4 and r5 writes are 4.x's.
    if (instr.writesRf0Implicitly(inst)) try addWriteDep(state, &state.last_rf[0], n);

    // Mesa: more here may need qpu_inst_after_thrsw_valid_in_delay_slot
    // changed too.
    if (inst.sig.thrsw) {
        // The accumulators and the flags are undefined after it.
        for (&state.last_r) |*last| try addWriteDep(state, last, n);
        try addWriteDep(state, &state.last_sf, n);
        try addWriteDep(state, &state.last_rtop, n);
        // What locks the scoreboard stays after the last thread switch.
        try addWriteDep(state, &state.last_tlb, n);
        try addWriteDep(state, &state.last_tmu_write, n);
        try addWriteDep(state, &state.last_tmu_config, n);
    }

    if (instr.waitsOnTmu(inst)) {
        // The TMU's results come out of a FIFO, in order, and after the
        // lookup is started.
        try addWriteDep(state, &state.last_tmu_read, n);
        try addReadDep(state, state.last_tmu_config, n);
    }

    // A wrtmuc may move about within its TMU sequence.
    if (inst.sig.wrtmuc) try addReadDep(state, state.last_tmu_config, n);

    if (inst.sig.ldtlb or inst.sig.ldtlbu) try addWriteDep(state, &state.last_tlb, n);

    if (inst.sig.ldvpm) {
        try addWriteDep(state, &state.last_vpm_read, n);
        // Shared segments: every write after every read.
        if (!separate_vpm_segment) try addWriteDep(state, &state.last_vpm, n);
    }

    // An ldunif, or a uniform read on the side.
    if (vir.hasUniform(qinst)) try addWriteDep(state, &state.last_unif, n);

    // unifa and ldunifa keep their order.
    if (inst.sig.ldunifa or inst.sig.ldunifarf) try addWriteDep(state, &state.last_unifa, n);

    if (instr.readsFlags(inst)) try addReadDep(state, state.last_sf, n);
    if (instr.writesFlags(inst)) try addWriteDep(state, &state.last_sf, n);
}

/// calculate_forward_deps (qpu_schedule.c:546).
fn calculateForwardDeps(dag: *Dag, schedule_list: *Link) Error!void {
    var state: State = .{ .dag = dag, .dir = .forward };
    var nodes = list.Each(Node, "link", .forward){ .head = schedule_list, .pos = schedule_list.next.? };
    while (nodes.next()) |node| try calculateDeps(&state, node);
}

/// calculate_reverse_deps (qpu_schedule.c:561).
fn calculateReverseDeps(dag: *Dag, schedule_list: *Link) Error!void {
    var state: State = .{ .dag = dag, .dir = .reverse };
    var nodes = list.Each(Node, "link", .backward){ .head = schedule_list, .pos = schedule_list.prev.? };
    while (nodes.next()) |node| try calculateDeps(&state, node);
}

/// What choosing the next instruction keeps track of (struct
/// choose_scoreboard, qpu_schedule.c:576), as Mesa starts it: the ticks
/// at -10, so that nothing is too soon after them. Mesa's
/// last_uniforms_reset_tick, which nothing reads, is left out.
const Scoreboard = struct {
    dag: ?*Dag = null,
    tick: i32 = 0,
    last_magic_sfu_write_tick: i32 = -10,
    last_stallable_sfu_reg: u6 = 0,
    last_stallable_sfu_tick: i32 = -10,
    last_ldvary_tick: i32 = -10,
    last_unifa_write_tick: i32 = -10,
    last_thrsw_tick: i32 = -10,
    last_branch_tick: i32 = -10,
    last_setmsf_tick: i32 = -10,
    first_thrsw_emitted: bool = false,
    last_thrsw_emitted: bool = false,
    fixup_ldvary: bool = false,
    ldvary_count: u32 = 0,
    pending_ldtmu_count: i32 = 0,
    first_ldtmu_after_thrsw: bool = true,
    last_implicit_rf0_write_tick: i32 = -10,
    has_rf0_flops_conflict: bool = false,
};

/// reads_too_soon (qpu_schedule.c:623): ldvary writes its C coefficient
/// to rf0 a cycle late. A small immediate's operand is not told apart, as
/// in Mesa.
fn readsTooSoon(sb: *const Scoreboard, raddr: u6) bool {
    return raddr == 0 and sb.tick - sb.last_ldvary_tick <= 1;
}

/// reads_too_soon_after_write (qpu_schedule.c:639).
fn readsTooSoonAfterWrite(sb: *const Scoreboard, qinst: *const Inst) bool {
    const inst = &qinst.qpu;
    // Mesa's XXX: branching off raddr.
    if (inst.kind == .branch) return false;
    if (inst.alu.add.op != .nop) {
        const nsrc = instr.addOpNumSrc(inst.alu.add.op);
        if (nsrc > 0 and readsTooSoon(sb, inst.alu.add.a.raddr)) return true;
        if (nsrc > 1 and readsTooSoon(sb, inst.alu.add.b.raddr)) return true;
    }
    if (inst.alu.mul.op != .nop) {
        const nsrc = instr.mulOpNumSrc(inst.alu.mul.op);
        if (nsrc > 0 and readsTooSoon(sb, inst.alu.mul.a.raddr)) return true;
        if (nsrc > 1 and readsTooSoon(sb, inst.alu.mul.b.raddr)) return true;
    }
    // Mesa's XXX: imm.
    return false;
}

/// writes_too_soon_after_write (qpu_schedule.c:699): nothing writes rf0
/// right after an ldvary, whose own write of it comes then, but another
/// ldvary, whose write is as late. The r4 write after an SFU's is 4.x's.
fn writesTooSoonAfterWrite(sb: *const Scoreboard, qinst: *const Inst) bool {
    const inst = &qinst.qpu;
    return sb.last_ldvary_tick + 1 == sb.tick and
        (instr.writesWaddrExplicitly(inst, 0) or (instr.writesRf0Implicitly(inst) and !inst.sig.ldvary));
}

/// scoreboard_is_locked (qpu_schedule.c:732): the scoreboard wait is done
/// on the first thread switch or the last, as the shader state says.
fn scoreboardIsLocked(sb: *const Scoreboard, lock_scoreboard_on_first_thrsw: bool) bool {
    if (lock_scoreboard_on_first_thrsw) return sb.first_thrsw_emitted and sb.tick - sb.last_thrsw_tick >= 3;
    return sb.last_thrsw_emitted and sb.tick - sb.last_thrsw_tick >= 3;
}

/// pixel_scoreboard_too_soon (qpu_schedule.c:745).
fn pixelScoreboardTooSoon(c: *const Compile, sb: *const Scoreboard, inst: *const Instr) bool {
    return qpuInstIsTlb(inst) and !scoreboardIsLocked(sb, c.lock_scoreboard_on_first_thrsw);
}

/// qpu_instruction_uses_rf (qpu_schedule.c:755).
fn qpuInstructionUsesRf(inst: *const Instr, waddr: u6) bool {
    if (inst.kind != .alu) return false;
    return instr.readsRaddr(inst, waddr);
}

/// read_stalls (qpu_schedule.c:779): the SFU's result read the cycle
/// after it was asked for.
fn readStalls(sb: *const Scoreboard, inst: *const Instr) bool {
    return sb.tick == sb.last_stallable_sfu_tick + 1 and qpuInstructionUsesRf(inst, sb.last_stallable_sfu_reg);
}

/// What a stall takes off an instruction's priority, so that one that
/// stalls comes after every one that does not (MAX_SCHEDULE_PRIORITY,
/// qpu_schedule.c:790).
const max_schedule_priority = 16;

/// get_instruction_priority (qpu_schedule.c:794): the TLB's accesses as
/// late as can be, for more parallelism between shaders, and everything
/// else the same. Mesa's priorities for the TMU's, which it has turned
/// off, are left out.
fn getInstructionPriority(inst: *const Instr) i32 {
    if (qpuInstIsTlb(inst)) return 0;
    return 1;
}

/// The units an instruction reaches (qpu_schedule.c:839).
const Peripheral = struct {
    const vpm_read: u32 = 1 << 0;
    const vpm_write: u32 = 1 << 1;
    const vpm_wait: u32 = 1 << 2;
    const sfu: u32 = 1 << 3;
    const tmu_write: u32 = 1 << 4;
    const tmu_read: u32 = 1 << 5;
    const tmu_wait: u32 = 1 << 6;
    const tmu_wrtmuc_sig: u32 = 1 << 7;
    const tsy: u32 = 1 << 8;
    const tlb_read: u32 = 1 << 9;
    const tlb_write: u32 = 1 << 10;
};

/// qpu_peripherals (qpu_schedule.c:855).
fn qpuPeripherals(inst: *const Instr) u32 {
    var result: u32 = 0;
    if (instr.readsVpm(inst)) result |= Peripheral.vpm_read;
    if (instr.writesVpm(inst)) result |= Peripheral.vpm_write;
    if (instr.waitsVpm(inst)) result |= Peripheral.vpm_wait;
    if (instr.writesTmu(inst)) result |= Peripheral.tmu_write;
    if (inst.sig.ldtmu) result |= Peripheral.tmu_read;
    if (inst.sig.wrtmuc) result |= Peripheral.tmu_wrtmuc_sig;
    if (instr.usesSfu(inst)) result |= Peripheral.sfu;
    if (instr.readsTlb(inst)) result |= Peripheral.tlb_read;
    if (instr.writesTlb(inst)) result |= Peripheral.tlb_write;
    if (inst.kind == .alu) {
        if (inst.alu.add.op != .nop and inst.alu.add.magic_write and instr.magicWaddrIsTsy(inst.alu.add.waddr)) result |= Peripheral.tsy;
        if (inst.alu.add.op == .tmuwt) result |= Peripheral.tmu_wait;
    }
    return result;
}

/// qpu_compatible_peripheral_access (qpu_schedule.c:896), 7.x's: one
/// access an instruction always; more where at most one of them is of
/// the restricted kinds, but a wrtmuc beside a TMU write that is not
/// tmuc; one TMU read; one TLB access.
fn qpuCompatiblePeripheralAccess(a: *const Instr, b: *const Instr) bool {
    const a_peripherals = qpuPeripherals(a);
    const b_peripherals = qpuPeripherals(b);
    if (@popCount(a_peripherals) + @popCount(b_peripherals) <= 1) return true;

    const restricted = Peripheral.tmu_write | Peripheral.tmu_wrtmuc_sig | Peripheral.tsy |
        Peripheral.tlb_read | Peripheral.sfu | Peripheral.vpm_read | Peripheral.vpm_write;
    const a_restricted = a_peripherals & restricted;
    const b_restricted = b_peripherals & restricted;
    if (a_restricted != 0 and b_restricted != 0) {
        if (!((a_restricted == Peripheral.tmu_wrtmuc_sig and b_restricted == Peripheral.tmu_write and instr.writesTmuNotTmuc(b)) or
            (b_restricted == Peripheral.tmu_wrtmuc_sig and a_restricted == Peripheral.tmu_write and instr.writesTmuNotTmuc(a))))
        {
            return false;
        }
    }

    if (a_peripherals & Peripheral.tmu_read != 0 and b_peripherals & Peripheral.tmu_read != 0) return false;

    const tlb = Peripheral.tlb_write | Peripheral.tlb_read;
    if (a_peripherals & tlb != 0 and b_peripherals & tlb != 0) return false;

    return true;
}

fn smallImmCount(sig: instr.Sig) u32 {
    return @as(u32, @intFromBool(sig.small_imm_a)) + @intFromBool(sig.small_imm_b) +
        @intFromBool(sig.small_imm_c) + @intFromBool(sig.small_imm_d);
}

/// qpu_merge_raddrs (qpu_schedule.c:1008), 7.x's: any registers, but one
/// small immediate an instruction.
fn qpuMergeRaddrs(result: *Instr, add_instr: *const Instr, mul_instr: *const Instr) bool {
    assert(@as(u32, @intFromBool(add_instr.sig.small_imm_a)) + @intFromBool(add_instr.sig.small_imm_b) <= 1);
    assert(!add_instr.sig.small_imm_c and !add_instr.sig.small_imm_d);
    assert(!mul_instr.sig.small_imm_a and !mul_instr.sig.small_imm_b);
    assert(@as(u32, @intFromBool(mul_instr.sig.small_imm_c)) + @intFromBool(mul_instr.sig.small_imm_d) <= 1);

    result.sig.small_imm_a = add_instr.sig.small_imm_a;
    result.sig.small_imm_b = add_instr.sig.small_imm_b;
    result.sig.small_imm_c = mul_instr.sig.small_imm_c;
    result.sig.small_imm_d = mul_instr.sig.small_imm_d;
    return smallImmCount(result.sig) <= 1;
}

/// can_do_add_as_mul (qpu_schedule.c:1109).
fn canDoAddAsMul(op: instr.AddOp) bool {
    return op == .add or op == .sub;
}

/// add_op_as_mul_op (qpu_schedule.c:1121).
fn addOpAsMulOp(op: instr.AddOp) instr.MulOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        else => unreachable,
    };
}

/// The add side's operation moved to the mul side, its flags, packing
/// and small immediate with it (qpu_convert_add_to_mul,
/// qpu_schedule.c:1135).
fn qpuConvertAddToMul(inst: *Instr) void {
    assert(inst.alu.add.op != .nop);
    assert(inst.alu.mul.op == .nop);

    const add = inst.alu.add;
    inst.alu.mul = .{
        .op = addOpAsMulOp(add.op),
        .a = add.a,
        .b = add.b,
        .waddr = add.waddr,
        .magic_write = add.magic_write,
        .output_pack = add.output_pack,
    };
    inst.alu.add.op = .nop;

    inst.flags.mc = inst.flags.ac;
    inst.flags.mpf = inst.flags.apf;
    inst.flags.muf = inst.flags.auf;
    inst.flags.ac = .none;
    inst.flags.apf = .none;
    inst.flags.auf = .none;

    inst.alu.add.output_pack = .none;
    inst.alu.add.a.unpack = .none;
    inst.alu.add.b.unpack = .none;

    assert(!inst.sig.small_imm_c and !inst.sig.small_imm_d);
    assert(@as(u32, @intFromBool(inst.sig.small_imm_a)) + @intFromBool(inst.sig.small_imm_b) <= 1);
    if (inst.sig.small_imm_a) {
        inst.sig.small_imm_c = true;
        inst.sig.small_imm_a = false;
    } else if (inst.sig.small_imm_b) {
        inst.sig.small_imm_d = true;
        inst.sig.small_imm_b = false;
    }
}

/// can_do_mul_as_add (qpu_schedule.c:1174): 7.x's add side has the moves.
fn canDoMulAsAdd(op: instr.MulOp) bool {
    return op == .mov or op == .fmov;
}

/// mul_op_as_add_op (qpu_schedule.c:1186).
fn mulOpAsAddOp(op: instr.MulOp) instr.AddOp {
    return switch (op) {
        .mov => .mov,
        .fmov => .fmov,
        else => unreachable,
    };
}

/// The other way (qpu_convert_mul_to_add, qpu_schedule.c:1200).
fn qpuConvertMulToAdd(inst: *Instr) void {
    assert(inst.alu.mul.op != .nop);
    assert(inst.alu.add.op == .nop);

    const mul = inst.alu.mul;
    inst.alu.add = .{
        .op = mulOpAsAddOp(mul.op),
        .a = mul.a,
        .b = mul.b,
        .waddr = mul.waddr,
        .magic_write = mul.magic_write,
        .output_pack = mul.output_pack,
    };
    inst.alu.mul.op = .nop;

    inst.flags.ac = inst.flags.mc;
    inst.flags.apf = inst.flags.mpf;
    inst.flags.auf = inst.flags.muf;
    inst.flags.mc = .none;
    inst.flags.mpf = .none;
    inst.flags.muf = .none;

    inst.alu.mul.output_pack = .none;
    inst.alu.mul.a.unpack = .none;
    inst.alu.mul.b.unpack = .none;

    assert(!inst.sig.small_imm_a and !inst.sig.small_imm_b);
    assert(@as(u32, @intFromBool(inst.sig.small_imm_c)) + @intFromBool(inst.sig.small_imm_d) <= 1);
    if (inst.sig.small_imm_c) {
        inst.sig.small_imm_a = true;
        inst.sig.small_imm_c = false;
    } else if (inst.sig.small_imm_d) {
        inst.sig.small_imm_b = true;
        inst.sig.small_imm_d = false;
    }
}

/// `a` and `b` as one instruction, where they fit in one and it packs
/// (qpu_merge_inst, qpu_schedule.c:1236): `b`'s add operation into
/// `a`'s free add side, or into its free mul side where it is an add or
/// a sub, or `a`'s moved there for it; `b`'s mul operation likewise, a
/// mov or an fmov going to the add side. `result` may be `a`, where the
/// merge is known to succeed.
fn qpuMergeInst(result: *Instr, a: *const Instr, b: *const Instr) bool {
    if (a.kind != .alu or b.kind != .alu) return false;
    if (!qpuCompatiblePeripheralAccess(a, b)) return false;

    var merge = a.*;
    var add_instr: ?*const Instr = null;
    var mul_instr: ?*const Instr = null;

    var mul_inst: Instr = undefined;
    if (b.alu.add.op != .nop) {
        if (a.alu.add.op == .nop) {
            merge.alu.add = b.alu.add;
            merge.flags.ac = b.flags.ac;
            merge.flags.apf = b.flags.apf;
            merge.flags.auf = b.flags.auf;
            add_instr = b;
            mul_instr = a;
        } else if (a.alu.mul.op == .nop and canDoAddAsMul(b.alu.add.op)) {
            // a's add side is taken and its mul side free: b's add
            // operation, or a's, goes there.
            mul_inst = b.*;
            qpuConvertAddToMul(&mul_inst);
            merge.alu.mul = mul_inst.alu.mul;
            merge.flags.mc = mul_inst.flags.mc;
            merge.flags.mpf = mul_inst.flags.mpf;
            merge.flags.muf = mul_inst.flags.muf;
            add_instr = a;
            mul_instr = &mul_inst;
        } else if (a.alu.mul.op == .nop and canDoAddAsMul(a.alu.add.op)) {
            mul_inst = a.*;
            qpuConvertAddToMul(&mul_inst);
            merge = mul_inst;
            merge.alu.add = b.alu.add;
            merge.flags.ac = b.flags.ac;
            merge.flags.apf = b.flags.apf;
            merge.flags.auf = b.flags.auf;
            add_instr = b;
            mul_instr = &mul_inst;
        } else {
            return false;
        }
    }

    var add_inst: Instr = undefined;
    if (b.alu.mul.op != .nop) {
        if (a.alu.mul.op == .nop) {
            merge.alu.mul = b.alu.mul;
            merge.flags.mc = b.flags.mc;
            merge.flags.mpf = b.flags.mpf;
            merge.flags.muf = b.flags.muf;
            mul_instr = b;
            add_instr = a;
        } else if (a.alu.add.op == .nop and canDoMulAsAdd(b.alu.mul.op)) {
            add_inst = b.*;
            qpuConvertMulToAdd(&add_inst);
            merge.alu.add = add_inst.alu.add;
            merge.flags.ac = add_inst.flags.ac;
            merge.flags.apf = add_inst.flags.apf;
            merge.flags.auf = add_inst.flags.auf;
            mul_instr = a;
            add_instr = &add_inst;
        } else if (a.alu.add.op == .nop and canDoMulAsAdd(a.alu.mul.op)) {
            add_inst = a.*;
            qpuConvertMulToAdd(&add_inst);
            merge = add_inst;
            merge.alu.mul = b.alu.mul;
            merge.flags.mc = b.flags.mc;
            merge.flags.mpf = b.flags.mpf;
            merge.flags.muf = b.flags.muf;
            mul_instr = b;
            add_instr = &add_inst;
        } else {
            return false;
        }
    }

    // 7.x reads any registers, but one small immediate an instruction.
    if (add_instr != null and mul_instr != null and !qpuMergeRaddrs(&merge, add_instr.?, mul_instr.?)) return false;

    merge.sig.thrsw = merge.sig.thrsw or b.sig.thrsw;
    merge.sig.ldunif = merge.sig.ldunif or b.sig.ldunif;
    merge.sig.ldunifrf = merge.sig.ldunifrf or b.sig.ldunifrf;
    merge.sig.ldunifa = merge.sig.ldunifa or b.sig.ldunifa;
    merge.sig.ldunifarf = merge.sig.ldunifarf or b.sig.ldunifarf;
    merge.sig.ldtmu = merge.sig.ldtmu or b.sig.ldtmu;
    merge.sig.ldvary = merge.sig.ldvary or b.sig.ldvary;
    merge.sig.ldvpm = merge.sig.ldvpm or b.sig.ldvpm;
    merge.sig.ldtlb = merge.sig.ldtlb or b.sig.ldtlb;
    merge.sig.ldtlbu = merge.sig.ldtlbu or b.sig.ldtlbu;
    merge.sig.ucb = merge.sig.ucb or b.sig.ucb;
    merge.sig.rotate = merge.sig.rotate or b.sig.rotate;
    merge.sig.wrtmuc = merge.sig.wrtmuc or b.sig.wrtmuc;

    if (instr.sigWritesAddress(a.sig) and instr.sigWritesAddress(b.sig)) return false;
    merge.sig_addr |= b.sig_addr;
    merge.sig_magic = merge.sig_magic or b.sig_magic;

    const ok = pack.pack(&merge) != null;
    // The real instructions are not changed where it fails.
    assert(ok or (a != result and b != result));
    result.* = merge;
    return ok;
}

/// try_skip_for_ldvary_pipelining (qpu_schedule.c:1385).
fn trySkipForLdvaryPipelining(inst: *const Instr) bool {
    return inst.sig.ldunif or inst.sig.ldunifrf;
}

/// The DAG head to emit next, or to merge into `prev_inst` where it is
/// given (choose_instruction_to_schedule, qpu_schedule.c:1400): of those
/// the hazards allow, the highest priority, and of those the longest
/// delay to the end, the first found winning a tie. In a fragment shader
/// the uniform loads wait while there are ldvarys to come, so that those
/// pipeline, unless nothing else can go.
fn chooseInstructionToSchedule(c: *Compile, sb: *Scoreboard, prev_inst: ?*Node) ?*Node {
    const dag = sb.dag.?;
    var chosen: ?*Node = null;
    var chosen_prio: i32 = 0;

    // Nothing is paired with a thread switch: emitThrsw does that, filling
    // its delay slots.
    if (prev_inst) |prev| {
        if (prev.inst.qpu.sig.thrsw) return null;
    }

    var ldvary_pipelining = c.stage == .fragment and sb.ldvary_count < c.num_inputs;
    var skipped_insts_for_ldvary_pipelining = false;
    while (true) {
        var heads = list.Each(dag_mod.Node, "link", .forward){ .head = &dag.heads, .pos = dag.heads.next.? };
        while (heads.next()) |head| {
            const n = Node.of(head);
            const inst = &n.inst.qpu;

            if (ldvary_pipelining and trySkipForLdvaryPipelining(inst)) {
                skipped_insts_for_ldvary_pipelining = true;
                continue;
            }

            // The branch waits until it is the last; emitBranch moves it
            // up into its delay slots.
            if (inst.kind == .branch and !dag.heads.isSingular()) continue;

            // Three instructions between a write to unifa and an ldunifa.
            if ((inst.sig.ldunifa or inst.sig.ldunifarf) and sb.tick - sb.last_unifa_write_tick <= 3) continue;

            // "An instruction must not read from a location in physical
            // regfile A or B that was written to by the previous
            // instruction."
            if (readsTooSoonAfterWrite(sb, n.inst)) continue;
            if (writesTooSoonAfterWrite(sb, n.inst)) continue;

            // "Before doing a TLB access a scoreboard wait must have been
            // done."
            if (pixelScoreboardTooSoon(c, sb, inst)) continue;

            // ldunif writes rf0 a cycle sooner than ldvary: not in the
            // cycle the ldvary's write lands.
            if ((inst.sig.ldunif or inst.sig.ldunifa) and sb.tick == sb.last_ldvary_tick + 1) continue;

            // In a thread switch's delay slots, only what may go there.
            if (sb.last_thrsw_tick + 2 >= sb.tick and !qpuInstAfterThrswValidInDelaySlot(sb, n.inst)) continue;

            if (inst.kind == .branch) {
                // Not in the delay slots of another branch or of a unifa
                // write.
                if (sb.last_branch_tick + 3 >= sb.tick) continue;
                if (sb.last_unifa_write_tick + 3 >= sb.tick) continue;
                // No branch with cond != 0, 2, 3 and msfign != 0 right
                // after a setmsf.
                if (sb.last_setmsf_tick == sb.tick - 1 and inst.branch.msfign != .none and
                    inst.branch.cond != .always and inst.branch.cond != .a0 and inst.branch.cond != .na0) continue;
            }

            if (prev_inst) |prev| {
                // A thread switch is paired when it is chosen on its own.
                if (inst.sig.thrsw) continue;

                if (prev.inst.uniform != null and n.inst.uniform != null) continue;

                // Two uniforms in one instruction, an ldunif's or a
                // sideband one and an ldunifa's, the simulator complains
                // of.
                if (vir.hasUniform(prev.inst) and (inst.sig.ldunifa or inst.sig.ldunifarf)) continue;
                if ((prev.inst.qpu.sig.ldunifa or prev.inst.qpu.sig.ldunifarf) and vir.hasUniform(n.inst)) continue;

                // No TLB access merged in before the scoreboard is had.
                if (pixelScoreboardTooSoon(c, sb, inst)) continue;

                // A paired ldvary is moved into the instruction before
                // (fixupPipelinedLdvary), which may not be a thread
                // switch's last delay slot.
                if (inst.sig.ldvary and sb.last_thrsw_tick + 2 == sb.tick - 1) continue;

                // A new lookup beside an ldtmu that may stall, which is
                // not the first after a thread switch, where the TMU's
                // output FIFO could overflow (Mesa's FIXME: whether the
                // ldtmu reads a lookup's first word is not tracked).
                if (prev.inst.qpu.sig.ldtmu and isTmuSequenceTerminator(n.inst) and !sb.first_ldtmu_after_thrsw and
                    sb.pending_ldtmu_count + @as(i32, @intCast(n.inst.ldtmu_count)) > @divTrunc(16, @as(i32, c.threads))) continue;

                var merged_inst: Instr = undefined;
                if (!qpuMergeInst(&merged_inst, &prev.inst.qpu, inst)) continue;
            }

            var prio = getInstructionPriority(inst);

            if (readStalls(sb, inst)) {
                // Nothing that stalls is merged, and it goes after
                // everything that does not.
                if (prev_inst != null) continue;
                prio -= max_schedule_priority;
                assert(prio < 0);
            }

            // Found one. Unless a better one comes along, it will do.
            if (chosen == null) {
                chosen = n;
                chosen_prio = prio;
                continue;
            }

            if (prio > chosen_prio) {
                chosen = n;
                chosen_prio = prio;
            } else if (prio < chosen_prio) {
                continue;
            }

            if (n.delay > chosen.?.delay) {
                chosen = n;
                chosen_prio = prio;
            } else if (n.delay < chosen.?.delay) {
                continue;
            }
        }

        // Nothing found but uniform loads skipped for the ldvarys: again,
        // with them.
        if (chosen == null and prev_inst == null and skipped_insts_for_ldvary_pipelining) {
            skipped_insts_for_ldvary_pipelining = false;
            ldvary_pipelining = false;
            continue;
        }
        break;
    }

    if (chosen) |n| {
        if (n.inst.qpu.sig.ldvary) {
            sb.ldvary_count += 1;
            // A paired ldvary is fixed up for better pipelining.
            if (prev_inst != null) sb.fixup_ldvary = true;
        }
    }
    return chosen;
}

/// update_scoreboard_for_magic_waddr (qpu_schedule.c:1652).
fn updateScoreboardForMagicWaddr(sb: *Scoreboard, waddr: u6) void {
    if (instr.magicWaddrIsSfu(waddr)) {
        sb.last_magic_sfu_write_tick = sb.tick;
    } else if (waddr == magic(.unifa)) {
        sb.last_unifa_write_tick = sb.tick;
    }
}

/// update_scoreboard_for_sfu_stall_waddr (qpu_schedule.c:1663).
fn updateScoreboardForSfuStallWaddr(sb: *Scoreboard, inst: *const Instr) void {
    if (instr.instrIsSfu(inst)) {
        sb.last_stallable_sfu_reg = inst.alu.add.waddr;
        sb.last_stallable_sfu_tick = sb.tick;
    }
}

/// update_scoreboard_tmu_tracking (qpu_schedule.c:1673): whether an
/// ldtmu came since the last thread switch, and how many the lookups
/// still have coming.
fn updateScoreboardTmuTracking(sb: *Scoreboard, qinst: *const Inst) void {
    if (sb.tick == sb.last_thrsw_tick + 2) sb.first_ldtmu_after_thrsw = true;
    sb.pending_ldtmu_count += @intCast(qinst.ldtmu_count);
    if (qinst.qpu.sig.ldtmu) {
        assert(sb.pending_ldtmu_count > 0);
        sb.pending_ldtmu_count -= 1;
        sb.first_ldtmu_after_thrsw = false;
    }
}

/// set_has_rf0_flops_conflict (qpu_schedule.c:1692).
fn setHasRf0FlopsConflict(sb: *Scoreboard, inst: *const Instr) void {
    if (sb.last_implicit_rf0_write_tick == sb.tick and instr.sigWritesAddress(inst.sig) and !inst.sig_magic) {
        sb.has_rf0_flops_conflict = true;
    }
}

/// update_scoreboard_for_rf0_flops (qpu_schedule.c:1703): rf0 is
/// undefined in the new thread section where its last write was an
/// implicit one that another signal's write to the register file came
/// with, and the section's last instruction has such a signal too.
/// emitThrsw keeps those out of the last delay slot where this says so.
fn updateScoreboardForRf0Flops(sb: *Scoreboard, inst: *const Instr) void {
    // An explicit write of rf0, or a new thread section, starts over.
    if (instr.writesWaddrExplicitly(inst, 0) or sb.tick - sb.last_thrsw_tick == 3) {
        sb.last_implicit_rf0_write_tick = -10;
        sb.has_rf0_flops_conflict = false;
    }
    if (instr.writesRf0Implicitly(inst)) {
        sb.last_implicit_rf0_write_tick = if (inst.sig.ldvary) sb.tick + 1 else sb.tick;
    }
    setHasRf0FlopsConflict(sb, inst);
}

/// update_scoreboard_for_chosen (qpu_schedule.c:1748).
fn updateScoreboardForChosen(sb: *Scoreboard, qinst: *const Inst) void {
    const inst = &qinst.qpu;
    if (inst.kind == .branch) return;

    if (inst.alu.add.op != .nop) {
        if (inst.alu.add.magic_write) {
            updateScoreboardForMagicWaddr(sb, inst.alu.add.waddr);
        } else {
            updateScoreboardForSfuStallWaddr(sb, inst);
        }
        if (inst.alu.add.op == .setmsf) sb.last_setmsf_tick = sb.tick;
    }
    if (inst.alu.mul.op != .nop and inst.alu.mul.magic_write) updateScoreboardForMagicWaddr(sb, inst.alu.mul.waddr);
    if (instr.sigWritesAddress(inst.sig) and inst.sig_magic) updateScoreboardForMagicWaddr(sb, inst.sig_addr);
    if (inst.sig.ldvary) sb.last_ldvary_tick = sb.tick;

    updateScoreboardForRf0Flops(sb, inst);
    updateScoreboardTmuTracking(sb, qinst);
}

/// magic_waddr_latency (qpu_schedule.c:1823): a texture lookup's result
/// taken to be a long way off (Mesa's FIXME: it is put on the last
/// lookup before the ldtmu, not its own), and an SFU's three cycles.
fn magicWaddrLatency(waddr: u6, after: *const Instr) u32 {
    if (instr.magicWaddrIsTmu(waddr) and instr.waitsOnTmu(after)) return 100;
    // What depends on an SFU write is taken to read its result.
    if (instr.magicWaddrIsSfu(waddr)) return 3;
    return 1;
}

/// instruction_latency (qpu_schedule.c:1859).
fn instructionLatency(before: *const Node, after: *const Node) u32 {
    const before_inst = &before.inst.qpu;
    const after_inst = &after.inst.qpu;
    var latency: u32 = 1;
    if (before_inst.kind != .alu or after_inst.kind != .alu) return latency;
    if (instr.instrIsSfu(before_inst)) return 2;
    if (before_inst.alu.add.op != .nop and before_inst.alu.add.magic_write) {
        latency = @max(latency, magicWaddrLatency(before_inst.alu.add.waddr, after_inst));
    }
    if (before_inst.alu.mul.op != .nop and before_inst.alu.mul.magic_write) {
        latency = @max(latency, magicWaddrLatency(before_inst.alu.mul.waddr, after_inst));
    }
    return latency;
}

/// A node's delay, from its children's (compute_delay,
/// qpu_schedule.c:1894), called on the DAG bottom up.
fn computeDelay(node: *dag_mod.Node, data: ?*anyopaque) void {
    _ = data;
    const n = Node.of(node);
    n.delay = 1;
    for (n.dag.edges.items) |edge| {
        const child = Node.of(edge.child.?);
        n.delay = @max(n.delay, child.delay + instructionLatency(n, child));
    }
}

/// A head taken out of the DAG with its edges of writes after reads
/// alone (pre_remove_head, qpu_schedule.c:1915), so that a write may be
/// merged into the instruction its read is in; markInstructionScheduled
/// takes the rest.
fn preRemoveHead(dag: *Dag, n: *Node) void {
    n.dag.link.delInit();
    for (n.dag.edges.items) |*edge| {
        if (edge.data != 0) dag.removeEdge(edge);
    }
}

/// mark_instruction_scheduled (qpu_schedule.c:1926): the children may
/// start once the node's latency to them has passed.
fn markInstructionScheduled(dag: *Dag, time: u32, node: ?*Node) void {
    const n = node orelse return;
    for (n.dag.edges.items) |edge| {
        const child = Node.of(edge.child orelse continue);
        const latency = instructionLatency(n, child);
        child.unblocked_time = @max(child.unblocked_time, time + latency);
    }
    dag.pruneHead(&n.dag);
}

/// insert_scheduled_instruction (qpu_schedule.c:1950).
fn insertScheduledInstruction(c: *Compile, block: *Block, sb: *Scoreboard, inst: *Inst) void {
    inst.link.addTail(&block.instructions);
    updateScoreboardForChosen(sb, inst);
    c.qpu_inst_count += 1;
    sb.tick += 1;
}

/// vir_nop (qpu_schedule.c:1963).
fn virNop(c: *Compile) Error!*Inst {
    const undef = vir.nopReg();
    return c.addInst(.nop, undef, undef, undef);
}

/// emit_nop (qpu_schedule.c:1971).
fn emitNop(c: *Compile, block: *Block, sb: *Scoreboard) Error!void {
    insertScheduledInstruction(c, block, sb, try virNop(c));
}

/// What may be in the thread end's instruction, `slot` 0, or in its delay
/// slots (qpu_inst_valid_in_thrend_slot, qpu_schedule.c:1979), 7.x's.
fn qpuInstValidInThrendSlot(qinst: *const Inst, slot: u32) bool {
    const inst = &qinst.qpu;
    if (slot == 2 and qinst.is_tlb_z_write) return false;
    if (slot > 0 and qinst.uniform != null) return false;
    if (inst.sig.ldvary) return false;
    if (inst.kind == .alu) {
        // The thread end writes no register from its ALUs.
        if (slot == 0 and (!inst.alu.add.magic_write or !inst.alu.mul.magic_write)) return false;
        // The fragment shader's setup may overwrite rf2 and rf3 in the
        // delay slots.
        if (instr.readsRaddr(inst, 2) or instr.readsRaddr(inst, 3)) return false;
        if (instr.writesWaddrExplicitly(inst, 2) or instr.writesWaddrExplicitly(inst, 3)) return false;
    }
    return true;
}

/// An instruction scheduled before a thread switch, which the switch is
/// moved back into, `slot` from the end (qpu_inst_before_thrsw_valid_in_
/// delay_slot, qpu_schedule.c:2070), 7.x's.
fn qpuInstBeforeThrswValidInDelaySlot(sb: *const Scoreboard, qinst: *const Inst, slot: u32) bool {
    // No SFU result landing in the other thread.
    if (slot > 0 and instr.instrIsSfu(&qinst.qpu)) return false;
    if (qinst.qpu.sig.ldvary and slot == 2) return false;
    // A unifa write and the three instructions after it may not overlap
    // the cycle the switch happens in, two after its instruction.
    if (instr.writesUnifa(&qinst.qpu)) return false;
    // See updateScoreboardForRf0Flops.
    if (slot == 2 and instr.sigWritesAddress(qinst.qpu.sig) and !qinst.qpu.sig_magic) {
        if (sb.has_rf0_flops_conflict) return false;
        if (sb.last_implicit_rf0_write_tick == sb.tick) return false;
    }
    return true;
}

/// An instruction scheduled after a thread switch, in its delay slots,
/// which moves it before the switch (qpu_inst_after_thrsw_valid_in_
/// delay_slot, qpu_schedule.c:2132), 7.x's.
fn qpuInstAfterThrswValidInDelaySlot(sb: *const Scoreboard, qinst: *const Inst) bool {
    // The switch's own instruction is never one of these: switches are
    // merged back by hand.
    const slot: u32 = @intCast(sb.tick - sb.last_thrsw_tick);
    assert(slot >= 1 and slot <= 2);

    // No thread switch before the last one has happened.
    if (qinst.qpu.sig.thrsw) return false;
    if (!qpuInstBeforeThrswValidInDelaySlot(sb, qinst, slot)) return false;
    // No TLB access before the scoreboard wait, at the last switch.
    if (qpuInstIsTlb(&qinst.qpu)) return false;
    if (qinst.qpu.kind == .branch) return false;
    // A switch needs a lookup or a TSY wait outstanding, and a lookup
    // moved before it may overflow the TMU's output FIFO.
    if (instr.writesTmu(&qinst.qpu) or qinst.qpu.sig.wrtmuc) return false;
    // Waiting on the TMU before the switch is what the switch avoids.
    if (instr.waitsOnTmu(&qinst.qpu)) return false;
    // multop writes rtop, which the switch does not keep. The
    // accumulators' writes are 4.x's.
    if (qinst.qpu.alu.mul.op == .multop) return false;
    // Nor does it keep the flags.
    if (instr.writesFlags(&qinst.qpu)) return false;
    // A TSY sync happens at the next switch: one moved into the delay
    // slots of the one before would happen there.
    if (qinst.qpu.alu.add.op == .barrierid) return false;
    return true;
}

/// valid_thrsw_sequence (qpu_schedule.c:2221): `count` instructions from
/// `first` on.
fn validThrswSequence(sb: *const Scoreboard, first: *Inst, count: u32, is_thrend: bool) bool {
    var qinst = first;
    for (0..count) |at| {
        const slot: u32 = @intCast(at);
        if (!qpuInstBeforeThrswValidInDelaySlot(sb, qinst, slot)) return false;
        if (is_thrend and !qpuInstValidInThrendSlot(qinst, slot)) return false;
        if (slot + 1 < count) qinst = list.entry(Inst, "link", qinst.link.next.?);
    }
    return true;
}

/// A thread switch emitted, moved back into the instructions before it
/// as far as its two delay slots allow (emit_thrsw, qpu_schedule.c:2250);
/// the last one is followed by another, which tells the hardware, and the
/// thread end by enough nops for its delay slots. The cycles it added are
/// answered.
///
/// Where the signal goes into an instruction before, Mesa frees `inst`
/// and leaves the compile's last_thrsw pointing at it, of which only
/// whether it is null is read again; here the instruction is put on
/// `dead`, which the caller frees, and last_thrsw is pointed at the
/// instruction the signal went into. Where it fails `inst` is in no list,
/// for the caller to free.
fn emitThrsw(c: *Compile, block: *Block, sb: *Scoreboard, inst: *Inst, is_thrend: bool, dead: *Link) Error!u32 {
    var time: u32 = 0;
    // Nothing but the signal.
    assert(inst.qpu.kind == .alu);
    assert(inst.qpu.alu.add.op == .nop);
    assert(inst.qpu.alu.mul.op == .nop);

    // Not in the delay slots of a thread switch or a branch.
    while (sb.last_thrsw_tick + 2 >= sb.tick) {
        try emitNop(c, block, sb);
        time += 1;
    }
    while (sb.last_branch_tick + 3 >= sb.tick) {
        try emitNop(c, block, sb);
        time += 1;
    }

    // How far back the signal can go.
    var slots_filled: i32 = 0;
    var invalid_sig_count: i32 = 0;
    var invalid_seq_count: i32 = 0;
    var last_thrsw_after_invalid_ok = false;
    var merge_inst: ?*Inst = null;
    var prevs = vir.eachInstRev(block);
    while (prevs.next()) |prev_inst| {
        // Not before the last switch has happened.
        if (sb.last_thrsw_tick + 3 > sb.tick - (slots_filled + 1)) break;

        cont: {
            // Where the sequence is not valid, one further back may be.
            if (!validThrswSequence(sb, prev_inst, @intCast(slots_filled + 1), is_thrend)) {
                invalid_seq_count += 1;
                break :cont;
            }
            // Nor where the signals do not go together.
            var sig = prev_inst.qpu.sig;
            sig.thrsw = true;
            if (pack.sigPack(sig) == null) {
                invalid_sig_count += 1;
                break :cont;
            }
            // The last switch needs two instructions in a row that can
            // take the signal: past one that cannot, the first that can
            // is only noted.
            if (inst.is_last_thrsw and invalid_sig_count > 0 and !last_thrsw_after_invalid_ok) {
                last_thrsw_after_invalid_ok = true;
                invalid_sig_count += 1;
                break :cont;
            }
            last_thrsw_after_invalid_ok = false;
            invalid_sig_count = 0;
            invalid_seq_count = 0;
            merge_inst = prev_inst;
        }
        slots_filled += 1;
        if (slots_filled == 3) break;
    }

    // Back to the last place it could go, past those it could not.
    assert((invalid_sig_count == 0 and invalid_seq_count == 0) or slots_filled >= invalid_sig_count + invalid_seq_count);
    slots_filled -= invalid_sig_count;
    slots_filled -= invalid_seq_count;

    var merged = false;
    if (merge_inst) |into| {
        into.qpu.sig.thrsw = true;
        merged = true;
        sb.last_thrsw_tick = sb.tick - slots_filled;
    } else {
        sb.last_thrsw_tick = sb.tick;
        insertScheduledInstruction(c, block, sb, inst);
        time += 1;
        slots_filled += 1;
        merge_inst = inst;
    }

    sb.first_thrsw_emitted = true;

    // The last switch but the thread end is told by two in a row.
    if (inst.is_last_thrsw) {
        if (slots_filled <= 1) {
            try emitNop(c, block, sb);
            time += 1;
        }
        const second_inst = list.entry(Inst, "link", merge_inst.?.link.next.?);
        second_inst.qpu.sig.thrsw = true;
        sb.last_thrsw_emitted = true;
    }

    // The thread end executes within the program.
    if (is_thrend) {
        var i: i32 = 0;
        while (i < 3 - slots_filled) : (i += 1) {
            try emitNop(c, block, sb);
            time += 1;
        }
    }

    if (merged) {
        if (c.last_thrsw == inst) c.last_thrsw = merge_inst;
        inst.link.addTail(dead);
    }
    return time;
}

/// qpu_inst_valid_in_branch_delay_slot (qpu_schedule.c:2397).
fn qpuInstValidInBranchDelaySlot(inst: *const Inst) bool {
    if (inst.qpu.kind == .branch) return false;
    if (inst.qpu.sig.thrsw) return false;
    if (instr.writesUnifa(&inst.qpu)) return false;
    if (vir.hasUniform(inst)) return false;
    return true;
}

/// A branch emitted and moved back into the instructions before it to
/// fill its three delay slots, nops filling the rest (emit_branch,
/// qpu_schedule.c:2415). The setmsf restriction on the branch is 4.x's.
fn emitBranch(c: *Compile, block: *Block, sb: *Scoreboard, inst: *Inst) Error!void {
    assert(inst.qpu.kind == .branch);

    // Not chosen for the delay slots of a thread switch, a branch or a
    // unifa write.
    const branch_tick = sb.tick;
    assert(sb.last_thrsw_tick + 2 < branch_tick);
    assert(sb.last_branch_tick + 3 < branch_tick);
    assert(sb.last_unifa_write_tick + 3 < branch_tick);

    insertScheduledInstruction(c, block, sb, inst);

    var slots_filled: i32 = 0;
    while (slots_filled < 3 and block.instructions.next != &inst.link) {
        const prev_inst = list.entry(Inst, "link", inst.link.prev.?);
        assert(prev_inst.qpu.kind != .branch);

        // Not into the delay slots of something else.
        if (sb.last_branch_tick + 3 >= branch_tick - slots_filled - 1) break;
        if (sb.last_thrsw_tick + 2 >= branch_tick - slots_filled - 1) break;
        if (sb.last_unifa_write_tick + 3 >= branch_tick - slots_filled - 1) break;
        // Nor into an ldvary sequence, whose rf0 write it may break.
        if (sb.last_ldvary_tick + 2 >= branch_tick - slots_filled) break;
        // Nor before the flags its condition reads are written.
        if (instr.writesFlags(&prev_inst.qpu) and inst.qpu.branch.cond != .always) break;
        if (!qpuInstValidInBranchDelaySlot(prev_inst)) break;

        prev_inst.link.del();
        prev_inst.link.add(&inst.link);
        slots_filled += 1;
    }

    block.branch_qpu_ip = c.qpu_inst_count - 1 - @as(u32, @intCast(slots_filled));
    sb.last_branch_tick = branch_tick - slots_filled;

    // The rest of the delay slots; for an unconditional branch,
    // setBranchTargets fills them from the successor where it can.
    var i: i32 = 0;
    while (i < 3 - slots_filled) : (i += 1) try emitNop(c, block, sb);
}

/// alu_reads_register (qpu_schedule.c:2518), 7.x's: the side's operands'
/// addresses compared, a small immediate's too, as in Mesa.
fn aluReadsRegister(inst: *const Instr, add: bool, is_magic: bool, index: u6) bool {
    assert(!is_magic);
    const num_src = if (add) instr.addOpNumSrc(inst.alu.add.op) else instr.mulOpNumSrc(inst.alu.mul.op);
    const raddr_a = if (add) inst.alu.add.a.raddr else inst.alu.mul.a.raddr;
    const raddr_b = if (add) inst.alu.add.b.raddr else inst.alu.mul.b.raddr;
    if (num_src > 0 and raddr_a == index) return true;
    if (num_src > 1 and raddr_b == index) return true;
    return false;
}

/// An ldvary merged into `inst` moved up into the instruction before, so
/// that the ldvary sequences pipeline (fixup_pipelined_ldvary,
/// qpu_schedule.c:2613): its multiply may then be merged into `inst`.
/// Mesa takes the block's last instruction without asking whether there
/// is one; here an empty block answers false.
fn fixupPipelinedLdvary(sb: *Scoreboard, block: *Block, inst: *Instr) bool {
    assert(inst.kind == .alu);
    assert(inst.sig.ldvary);
    const ldvary_magic = inst.sig_magic;
    const ldvary_index = inst.sig_addr;

    // `inst` may not read what the ldvary writes.
    if (aluReadsRegister(inst, true, ldvary_magic, ldvary_index)) return false;
    if (aluReadsRegister(inst, false, ldvary_magic, ldvary_index)) return false;

    // Nor have another signal writing rf0 in the instruction after the
    // ldvary: ldunif is the only one that goes with ldvary.
    if (inst.sig.ldunif) return false;

    if (block.instructions.isEmpty()) return false;
    const prev = list.entry(Inst, "link", block.instructions.prev.?);
    if (prev.qpu.kind != .alu) return false;

    // The instruction before may not write what the ldvary writes.
    if (prev.qpu.alu.add.op != .nop and prev.qpu.alu.add.magic_write == ldvary_magic and prev.qpu.alu.add.waddr == ldvary_index) return false;
    if (prev.qpu.alu.mul.op != .nop and prev.qpu.alu.mul.magic_write == ldvary_magic and prev.qpu.alu.mul.waddr == ldvary_index) return false;

    // Nor have a signal of its own that writes.
    if (instr.sigWritesAddress(prev.qpu.sig)) return false;
    var new_sig = prev.qpu.sig;
    new_sig.ldvary = true;
    if (pack.sigPack(new_sig) == null) return false;

    // Nor use the flags: the ldvary's destination goes in the condition
    // field.
    if (instr.writesFlags(&prev.qpu)) return false;
    if (instr.readsFlags(&prev.qpu)) return false;

    // Kept out of a thread switch's last delay slot when it was paired.
    assert(sb.last_thrsw_tick + 2 != sb.tick - 1);

    prev.qpu.sig.ldvary = true;
    prev.qpu.sig_magic = ldvary_magic;
    prev.qpu.sig_addr = ldvary_index;
    sb.last_ldvary_tick = sb.tick - 1;

    inst.sig.ldvary = false;
    inst.sig_magic = false;
    inst.sig_addr = 0;

    // The ldvary's late rf0 write now lands in `inst`.
    sb.last_implicit_rf0_write_tick = sb.tick;
    setHasRf0FlopsConflict(sb, inst);

    // Nothing else in `inst` writes rf0: the dependencies kept an
    // instruction that does from being paired with the ldvary.
    assert(!instr.writesRf0Implicitly(inst) and !instr.writesWaddrExplicitly(inst, 0));
    return true;
}

/// The block's DAG emptied an instruction a cycle (schedule_instructions,
/// qpu_schedule.c:2733): the head chosen, what merges into it merged,
/// a nop where nothing can go, and the uniforms numbered in the order
/// they are now read. The cycles it took are answered.
fn scheduleInstructions(c: *Compile, sb: *Scoreboard, block: *Block, orig_uniform_contents: []const vir.Uniform, orig_uniform_data: []const u32, next_uniform: *u32, dead: *Link) Error!u32 {
    const dag = sb.dag.?;
    var time: u32 = 0;

    while (!dag.heads.isEmpty()) {
        const chosen = chooseInstructionToSchedule(c, sb, null);
        const qinst = if (chosen) |n| n.inst else try virNop(c);
        const inst = &qinst.qpu;

        // The merged ones are marked scheduled once the merging is done.
        var merged_list: Link = .{};
        merged_list.initHead();

        if (chosen) |n| {
            time = @max(n.unblocked_time, time);
            preRemoveHead(dag, n);

            while (chooseInstructionToSchedule(c, sb, n)) |merge| {
                time = @max(merge.unblocked_time, time);
                preRemoveHead(dag, merge);
                // Mesa reuses the link of the setup list, which is not
                // walked again, without taking it out; here it is.
                merge.link.del();
                merge.link.addTail(&merged_list);
                const ok = qpuMergeInst(inst, inst, &merge.inst.qpu);
                assert(ok);
                if (merge.inst.uniform) |u| n.inst.uniform = u;
                n.inst.ldtmu_count += merge.inst.ldtmu_count;

                if (sb.fixup_ldvary) {
                    sb.fixup_ldvary = false;
                    // The ldvary scheduled now, so that what follows it
                    // in its sequence may merge into this instruction.
                    if (fixupPipelinedLdvary(sb, block, inst)) markInstructionScheduled(dag, time, merge);
                }
            }
            if (readStalls(sb, inst)) c.qpu_inst_stalled_count += 1;
        }

        // The uniform renumbered for where it is now; setBranchTargets
        // still writes a branch's through this.
        if (qinst.uniform) |u| {
            if (inst.kind == .branch) block.branch_uniform = next_uniform.*;
            c.uniform_data[next_uniform.*] = orig_uniform_data[u];
            c.uniform_contents[next_uniform.*] = orig_uniform_contents[u];
            qinst.uniform = next_uniform.*;
            next_uniform.* += 1;
        }

        // The children of what was scheduled may become heads.
        markInstructionScheduled(dag, time, chosen);
        var merges = list.EachSafe(Node, "link", .forward){ .head = &merged_list, .pos = merged_list.next.? };
        while (merges.next()) |merge| {
            markInstructionScheduled(dag, time, merge);
            // The merged instruction is not put back into the block.
            merge.inst.link.addTail(dead);
        }

        if (inst.sig.thrsw) {
            time += try emitThrsw(c, block, sb, qinst, false, dead);
        } else if (inst.kind == .branch) {
            try emitBranch(c, block, sb, qinst);
        } else {
            insertScheduledInstruction(c, block, sb, qinst);
        }
    }
    return time;
}

fn freeDead(c: *Compile, dead: *Link) void {
    var insts = list.EachSafe(Inst, "link", .forward){ .head = dead, .pos = dead.next.? };
    while (insts.next()) |inst| c.allocator.destroy(inst);
    dead.initHead();
}

/// One block scheduled (qpu_schedule_instructions_block,
/// qpu_schedule.c:2873): its instructions taken out into nodes, their
/// dependencies found both ways, each node's delay, then the schedule.
///
/// Mesa does not fail. Here an allocation may: then the instructions
/// not yet back in the block are freed, and the block holds what was
/// scheduled.
fn scheduleInstructionsBlock(c: *Compile, sb: *Scoreboard, block: *Block, orig_uniform_contents: []const vir.Uniform, orig_uniform_data: []const u32, next_uniform: *u32) Error!u32 {
    const allocator = c.allocator;
    const nodes = try allocator.alloc(Node, block.instructions.length());
    defer allocator.free(nodes);

    var dag: Dag = undefined;
    dag.init(allocator);
    var setup_list: Link = .{};
    setup_list.initHead();
    var dead: Link = .{};
    dead.initHead();

    // Each instruction in a node.
    for (nodes) |*n| {
        const qinst = list.entry(Inst, "link", block.instructions.next.?);
        n.* = .{ .inst = qinst };
        dag.initNode(&n.dag);
        qinst.link.del();
        n.link.addTail(&setup_list);
    }
    assert(block.instructions.isEmpty());

    sb.dag = &dag;
    defer sb.dag = null;
    defer for (nodes) |*n| n.dag.deinit(allocator);
    defer freeDead(c, &dead);
    // An instruction neither in the block nor dead is in no list.
    errdefer for (nodes) |*n| {
        if (n.inst.link.next == null) {
            if (c.last_thrsw == n.inst) c.last_thrsw = null;
            allocator.destroy(n.inst);
        }
    };

    try calculateForwardDeps(&dag, &setup_list);
    try calculateReverseDeps(&dag, &setup_list);
    try dag.traverseBottomUp(computeDelay, null);

    return scheduleInstructions(c, sb, block, orig_uniform_contents, orig_uniform_data, next_uniform, &dead);
}

/// A block's branch_qpu_ip where it has no branch.
const no_branch = std.math.maxInt(u32);

/// Each branch given its offsets, in the instructions and in the
/// uniforms, now that the blocks have their places; an unconditional
/// branch's delay slots filled with its successor's first instructions
/// where they can go there (qpu_set_branch_targets, qpu_schedule.c:2916).
///
/// As in Mesa, the walk back to the branch starts at the next to last
/// instruction, so the last delay slot is never filled from the
/// successor.
fn setBranchTargets(c: *Compile) void {
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        // The program's end block has no branch.
        const successor = block.successors[0] orelse continue;

        // Without a branch, the successor follows.
        if (block.branch_qpu_ip == no_branch) {
            assert(block.end_qpu_ip +% 1 == successor.start_qpu_ip);
            continue;
        }

        // Back through the delay slots to the branch.
        var branch: ?*Inst = null;
        var link = block.instructions.prev.?;
        var delay_slot_count: i32 = -1;
        var delay_slots_start: ?*Inst = null;
        for (0..3) |i| {
            link = link.prev.?;
            const inst = list.entry(Inst, "link", link);
            if (delay_slot_count == -1) {
                if (!instr.isNop(&inst.qpu)) {
                    delay_slot_count = @intCast(i);
                } else {
                    delay_slots_start = inst;
                }
            }
            if (inst.qpu.kind == .branch) {
                branch = inst;
                break;
            }
        }
        const br = branch.?;
        assert(br.qpu.kind == .branch);
        assert(delay_slot_count >= 0 and delay_slot_count <= 3);
        assert(delay_slot_count == 0 or delay_slots_start != null);

        // The successor where the branch is not taken is right after the
        // delay slots.
        assert(block.successors[1] == null or block.successors[1].?.start_qpu_ip == block.branch_qpu_ip + 4);

        br.qpu.branch.offset = (successor.start_qpu_ip -% (block.branch_qpu_ip + 4)) *% @sizeOf(u64);

        // The uniform stream's jump, through the branch's own uniform: the
        // word at its old index may be shared.
        const uniform = br.uniform.?;
        assert(c.uniform_contents[uniform] == .constant);
        c.uniform_data[uniform] = (successor.start_uniform -% (block.branch_uniform + 1)) *% 4;

        // Mesa's FIXME: a conditional branch's could be filled too, the
        // instructions predicated as the branch is.
        if (br.qpu.branch.cond == .always) {
            const successor_insts = &successor.instructions;
            const count = @min(@as(u32, @intCast(delay_slot_count)), successor_insts.length());
            var slots_filled: u32 = 0;
            if (count > 0) {
                var s_inst = list.entry(Inst, "link", successor_insts.next.?);
                var slot = delay_slots_start.?;
                while (slots_filled < count and qpuInstValidInBranchDelaySlot(s_inst)) {
                    slot.qpu = s_inst.qpu;
                    slots_filled += 1;
                    if (slots_filled == count) break;
                    s_inst = list.entry(Inst, "link", s_inst.link.next.?);
                    slot = list.entry(Inst, "link", slot.link.next.?);
                }
            }
            br.qpu.branch.offset +%= slots_filled * @sizeOf(u64);
        }
    }
}

/// The compile's program scheduled, block by block, the uniforms
/// renumbered into new arrays in the order the program reads them, the
/// thread end emitted and the branches given their targets
/// (v3d_qpu_schedule_instructions, qpu_schedule.c:2990). The cycles it
/// takes are answered. It follows generateCode, which counted the
/// uniforms the program reads in num_uniforms.
pub fn qpuScheduleInstructions(c: *Compile) Error!u32 {
    const allocator = c.allocator;
    const end_block = list.lastEntry(Block, "link", &c.blocks);

    // The uniforms are reordered as the instructions are: the old ones
    // kept for the scheduling, then given back.
    const contents = try allocator.alloc(vir.Uniform, c.num_uniforms);
    const data = allocator.alloc(u32, c.num_uniforms) catch |err| {
        allocator.free(contents);
        return err;
    };
    const uniform_contents = c.uniform_contents;
    const uniform_data = c.uniform_data;
    defer allocator.free(uniform_contents);
    defer allocator.free(uniform_data);
    c.uniform_contents = contents;
    c.uniform_data = data;
    var next_uniform: u32 = 0;

    var sb: Scoreboard = .{};
    var cycles: u32 = 0;
    var blocks = c.eachBlock();
    while (blocks.next()) |block| {
        block.start_qpu_ip = c.qpu_inst_count;
        block.branch_qpu_ip = no_branch;
        block.start_uniform = next_uniform;
        cycles += try scheduleInstructionsBlock(c, &sb, block, uniform_contents, uniform_data, &next_uniform);
        // Mesa's unsigned arithmetic: an empty first block ends at ~0.
        block.end_qpu_ip = c.qpu_inst_count -% 1;
    }

    // The thread end.
    var dead: Link = .{};
    dead.initHead();
    defer freeDead(c, &dead);
    const thrsw = try virNop(c);
    errdefer if (thrsw.link.next == null) allocator.destroy(thrsw);
    thrsw.qpu.sig.thrsw = true;
    _ = try emitThrsw(c, end_block, &sb, thrsw, true, &dead);

    setBranchTargets(c);

    assert(next_uniform == c.num_uniforms);
    return cycles;
}

const testing = std.testing;

fn addOp(op: instr.AddOp, waddr: u6, a: u6, b: u6) Instr {
    var inst: Instr = .{};
    inst.alu.add = .{ .op = op, .a = .{ .raddr = a }, .b = .{ .raddr = b }, .waddr = waddr, .magic_write = false };
    return inst;
}

fn mulOp(op: instr.MulOp, waddr: u6, a: u6, b: u6) Instr {
    var inst: Instr = .{};
    inst.alu.mul = .{ .op = op, .a = .{ .raddr = a }, .b = .{ .raddr = b }, .waddr = waddr, .magic_write = false };
    return inst;
}

fn magicMov(waddr: Waddr, a: u6) Instr {
    var inst = mulOp(.mov, magic(waddr), a, 0);
    inst.alu.mul.magic_write = true;
    return inst;
}

test "two instructions merge with one small immediate between them, which an add moved to the mul side takes along" {
    var merged: Instr = undefined;
    const three = pack.smallImmPack(3).?;

    var a = addOp(.add, 1, 2, three);
    a.sig.small_imm_b = true;
    var b = mulOp(.fmul, 3, 4, pack.smallImmPack(1).?);
    b.sig.small_imm_d = true;
    try testing.expect(!qpuMergeInst(&merged, &a, &b));
    b.sig.small_imm_d = false;
    b.alu.mul.b.raddr = 5;
    try testing.expect(qpuMergeInst(&merged, &a, &b));
    try testing.expect(merged.sig.small_imm_b and !merged.sig.small_imm_d);
    try testing.expectEqual(instr.MulOp.fmul, merged.alu.mul.op);

    // The add, which cannot stay on the add side, goes to the mul side:
    // its small immediate from b to d.
    const fadd = addOp(.fadd, 6, 7, 8);
    try testing.expect(qpuMergeInst(&merged, &fadd, &a));
    try testing.expectEqual(instr.AddOp.fadd, merged.alu.add.op);
    try testing.expectEqual(instr.MulOp.add, merged.alu.mul.op);
    try testing.expectEqual(@as(u6, 1), merged.alu.mul.waddr);
    try testing.expect(merged.sig.small_imm_d and !merged.sig.small_imm_b);
    // The other way round, the first add is the one moved.
    try testing.expect(qpuMergeInst(&merged, &a, &fadd));
    try testing.expectEqual(instr.AddOp.fadd, merged.alu.add.op);
    try testing.expectEqual(instr.MulOp.add, merged.alu.mul.op);
    try testing.expect(merged.sig.small_imm_d);

    // Two fadds have nowhere to go.
    try testing.expect(!qpuMergeInst(&merged, &fadd, &addOp(.fadd, 9, 10, 11)));
}

test "two signals writing registers do not merge, and the peripherals are reached one at a time but where 7.x allows" {
    var merged: Instr = undefined;

    var ldunifrf: Instr = .{};
    ldunifrf.sig.ldunifrf = true;
    ldunifrf.sig_addr = 1;
    var ldtmu: Instr = .{};
    ldtmu.sig.ldtmu = true;
    ldtmu.sig_addr = 2;
    try testing.expect(!qpuMergeInst(&merged, &ldunifrf, &ldtmu));
    // One of them beside an operation.
    try testing.expect(qpuMergeInst(&merged, &ldtmu, &addOp(.fadd, 3, 4, 5)));
    try testing.expectEqual(@as(u6, 2), merged.sig_addr);

    // Two TMU writes, or one and an SFU operation, are two of the
    // restricted kinds.
    const tmud = magicMov(.tmud, 1);
    var tmua = addOp(.add, magic(.tmua), 2, 3);
    tmua.alu.add.magic_write = true;
    try testing.expect(!qpuMergeInst(&merged, &tmud, &tmua));
    try testing.expect(!qpuMergeInst(&merged, &addOp(.recip, 4, 5, 0), &tmud));
    // An operation that reaches none goes beside one.
    try testing.expect(qpuMergeInst(&merged, &addOp(.fadd, 4, 5, 6), &tmud));

    // A wrtmuc beside a TMU write, but not beside a write of tmuc.
    var wrtmuc: Instr = .{};
    wrtmuc.sig.wrtmuc = true;
    try testing.expect(qpuMergeInst(&merged, &wrtmuc, &magicMov(.tmus, 1)));
    try testing.expect(!qpuMergeInst(&merged, &wrtmuc, &magicMov(.tmuc, 1)));
    try testing.expectEqual(Peripheral.tmu_wrtmuc_sig, qpuPeripherals(&wrtmuc));
    try testing.expectEqual(Peripheral.tmu_write | Peripheral.tmu_read, qpuPeripherals(&blk: {
        var both = magicMov(.tmud, 1);
        both.sig.ldtmu = true;
        both.sig_addr = 2;
        break :blk both;
    }));
}

test "a register read before a write of it walking back is an edge the write may pair across" {
    const allocator = testing.allocator;
    var read = Inst{ .qpu = addOp(.fadd, 2, 1, 1) };
    var write = Inst{ .qpu = mulOp(.fmul, 1, 3, 3) };
    var nodes = [_]Node{ .{ .inst = &read }, .{ .inst = &write } };
    var dag: Dag = undefined;
    dag.init(allocator);
    defer for (&nodes) |*n| n.dag.deinit(allocator);
    var setup: Link = .{};
    setup.initHead();
    for (&nodes) |*n| {
        dag.initNode(&n.dag);
        n.link.addTail(&setup);
    }
    try calculateForwardDeps(&dag, &setup);
    try testing.expectEqual(@as(usize, 0), nodes[0].dag.edges.items.len);
    try calculateReverseDeps(&dag, &setup);
    try testing.expectEqual(@as(usize, 1), nodes[0].dag.edges.items.len);
    try testing.expectEqual(&nodes[1].dag, nodes[0].dag.edges.items[0].child.?);
    try testing.expectEqual(@as(usize, 1), nodes[0].dag.edges.items[0].data);

    // Taken out as a head, the read lets the write be one too.
    preRemoveHead(&dag, &nodes[0]);
    try testing.expectEqual(&nodes[1].dag, list.firstEntry(dag_mod.Node, "link", &dag.heads));
    try testing.expect(dag.heads.isSingular());
}
