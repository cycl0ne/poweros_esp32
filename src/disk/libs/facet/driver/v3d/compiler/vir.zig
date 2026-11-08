// SPDX-License-Identifier: MIT
//! Mesa's VIR, the instructions the V3D compiler builds a program of
//! before its temporaries are given registers and its instructions are
//! scheduled into the QPU's: the port of what in Mesa's
//! src/broadcom/compiler/v3d_compiler.h and vir.c is VIR itself, its 7.1
//! paths. A VIR instruction is a QPU instruction (qpu/instr.zig) whose
//! destination and operands are still `Reg`s: a temporary, a register of
//! the register file, a magic address, an immediate, or nothing.
//!
//! Mesa allocates a compile and its blocks with ralloc and frees them
//! with it at once, and its instructions with calloc and free one by one;
//! here all of it comes from the one std.mem.Allocator the compile is
//! made with, and `destroy` gives it back. Where Mesa's allocations are
//! not checked, these answer error.OutOfMemory.
//!
//! What is 4.x alone is left out, as in qpu/: the accumulators, and with
//! them vir_writes_r4_implicitly, which is false on 7.1. What vir.c does
//! with NIR, and the compile strategies around it, come with the port of
//! nir_to_vir.c, as the optimization passes come with theirs.

const std = @import("std");
const assert = std.debug.assert;
const instr = @import("../qpu/instr.zig");
const list = @import("list.zig");
const ra = @import("ra.zig");
const Link = list.Link;

pub const Instr = instr.Instr;
pub const AddOp = instr.AddOp;
pub const MulOp = instr.MulOp;
pub const Waddr = instr.Waddr;
pub const Error = std.mem.Allocator.Error;

/// What a register reference names (enum qfile, v3d_compiler.h:84).
pub const File = enum {
    /// Nothing: an operand not read, or a destination not written.
    null,
    /// A register of the register file, such as the payload's W.
    reg,
    /// A magic address, for what the QPU does beside computing.
    magic,
    /// A temporary, which the register allocator gives a register.
    temp,
    /// A 32-bit immediate in `index`, for an instruction that loads it.
    load_imm,
    /// An immediate in `index` that is to be a small immediate.
    small_imm,
};

/// A register, or a temporary that is to be one (struct qreg,
/// v3d_compiler.h:115).
pub const Reg = struct {
    file: File = .null,
    index: u32 = 0,
};

/// vir_reg (v3d_compiler.h:120).
pub fn reg(file: File, index: u32) Reg {
    return .{ .file = file, .index = index };
}

/// vir_magic_reg (v3d_compiler.h:125).
pub fn magicReg(waddr: Waddr) Reg {
    return .{ .file = .magic, .index = @intFromEnum(waddr) };
}

/// Nothing read and nothing written (vir_nop_reg, v3d_compiler.h:130).
pub fn nopReg() Reg {
    return .{};
}

/// A register as the QPU names it, which the register allocator gives
/// each temporary (struct qpu_reg, v3d_compiler.h:139).
pub const QpuReg = struct {
    magic: bool = false,
    /// The operand is the instruction's small immediate.
    smimm: bool = false,
    index: u6 = 0,
};

/// One VIR instruction (struct qinst, v3d_compiler.h:145).
pub const Inst = struct {
    /// Its place in its block's `instructions`.
    link: Link = .{},
    /// The instruction it is. Its conditions, packing, signals and the
    /// rest are used as they are; the registers it names are replaced by
    /// `dst` and `src` once those have registers.
    qpu: Instr = instr.nop,
    dst: Reg = .{},
    src: [3]Reg = .{ .{}, .{}, .{} },
    is_last_thrsw: bool = false,
    /// The uniform it reads other than through an operand, as its index in
    /// the compile's `uniform_contents`; Mesa's ~0 for none is null.
    uniform: ?u32 = null,
    /// It writes the depth to the tile buffer.
    is_tlb_z_write: bool = false,
    /// For the TMU write that ends a lookup, the ldtmu its results take.
    ldtmu_count: u32 = 0,
    /// Its place in the program, given at register allocation.
    ip: i32 = -1,
};

/// What a uniform holds (enum quniform_contents, v3d_compiler.h:181), in
/// Mesa's order, which vir_dump_uniform prints the number of where it has
/// no name for one.
pub const Uniform = enum(u8) {
    /// The word itself.
    constant,
    /// The word is an index into the push constants.
    uniform,
    viewport_x_scale,
    viewport_y_scale,
    viewport_z_offset,
    viewport_z_scale,
    tmu_config_p0,
    tmu_config_p1,
    image_tmu_config_p0,
    texture_first_level,
    texture_width,
    texture_height,
    texture_depth,
    texture_array_size,
    texture_levels,
    texture_samples,
    ubo_addr,
    texrect_scale_x,
    texrect_scale_y,
    ssbo_offset,
    get_ssbo_size,
    get_ubo_size,
    image_width,
    image_height,
    image_depth,
    image_array_size,
    line_width,
    aa_line_width,
    num_work_groups,
    work_group_base,
    work_group_size,
    spill_offset,
    spill_size_per_thread,
    shared_offset,
    shared_size,
    fb_layers,
    view_index,
    inline_ubo_0,
    inline_ubo_1,
    inline_ubo_2,
    inline_ubo_3,
    draw_id,
    blend_constant_r,
    blend_constant_g,
    blend_constant_b,
    blend_constant_a,
};

/// A unit and an offset in one uniform word (v3d_unit_data_create,
/// v3d_compiler.h:320).
pub fn unitDataCreate(unit: u32, value: u32) u32 {
    assert(value < 1 << 24);
    return unit << 24 | value;
}

/// v3d_unit_data_get_unit (v3d_compiler.h:326).
pub fn unitDataGetUnit(data: u32) u32 {
    return data >> 24;
}

/// v3d_unit_data_get_offset (v3d_compiler.h:331).
pub fn unitDataGetOffset(data: u32) u32 {
    return data & 0xffffff;
}

/// A basic block of VIR instructions (struct qblock, v3d_compiler.h:463).
pub const Block = struct {
    /// Its place in the compile's `blocks`.
    link: Link = .{},
    /// The head of its instructions.
    instructions: Link = .{},
    /// The blocks that go on to it, each once (Mesa's pointer set).
    predecessors: std.ArrayList(*Block) = .empty,
    successors: [2]?*Block = .{ null, null },
    index: u32,
    /// The QPU instructions its first and last instructions became, and
    /// its branch; the scheduler sets them.
    start_qpu_ip: u32 = 0,
    end_qpu_ip: u32 = 0,
    branch_qpu_ip: u32 = 0,
    /// Its place in the uniform stream at its start, and its branch's.
    start_uniform: u32 = 0,
    branch_uniform: u32 = 0,
    /// The branch that ends it was emitted already, by a break or a
    /// continue.
    branch_emitted: bool = false,
    /// What the liveness analysis (live.zig) keeps, a bit for each
    /// temporary: those the block defines whole before reading them, those
    /// it or a block before it defines in part, those it reads before
    /// defining them, and those live where it starts and where it ends.
    def: []u32 = &.{},
    defin: []u32 = &.{},
    defout: []u32 = &.{},
    use: []u32 = &.{},
    live_in: []u32 = &.{},
    live_out: []u32 = &.{},
    /// Its instructions' places in the program: the first, and the one
    /// after the last.
    start_ip: i32 = 0,
    end_ip: i32 = 0,
    /// The block made before it, so that `destroy` finds every block made,
    /// as ralloc has them as the compile's children.
    made_before: ?*Block = null,
};

/// Which side of its link a cursor puts an instruction on (enum
/// vir_cursor_mode, v3d_compiler.h:507).
pub const CursorMode = enum { add, addtail };

/// Where the next instruction goes (struct vir_cursor,
/// v3d_compiler.h:519): after or before a link, which is an
/// instruction's or a block's head.
pub const Cursor = struct {
    mode: CursorMode,
    link: ?*Link,
};

/// vir_before_inst (v3d_compiler.h:525).
pub fn beforeInst(inst: *Inst) Cursor {
    return .{ .mode = .addtail, .link = &inst.link };
}

/// vir_after_inst (v3d_compiler.h:531).
pub fn afterInst(inst: *Inst) Cursor {
    return .{ .mode = .add, .link = &inst.link };
}

/// vir_before_block (v3d_compiler.h:537).
pub fn beforeBlock(block: *Block) Cursor {
    return .{ .mode = .add, .link = &block.instructions };
}

/// vir_after_block (v3d_compiler.h:543).
pub fn afterBlock(block: *Block) Cursor {
    return .{ .mode = .addtail, .link = &block.instructions };
}

/// enum v3d_compilation_result (v3d_compiler.h:548).
pub const Result = enum { succeeded, failed_register_allocation, failed };

/// The stage a program is for (gl_shader_stage, as the compiler asks
/// c->s->info.stage): the V3D runs no tessellation.
pub const Stage = enum { vertex, geometry, fragment, compute };

/// What of struct v3d_compiler (v3d_compiler.h:558), the state kept from
/// one compile to the next, the register allocator uses: the register
/// file as a set, and its classes for each count of threads, 64
/// registers at 1 and 2 and 32 at 4 (vir_init_reg_sets, allocate.zig).
/// Mesa's arrays have room for three counts and fill two; its classes of
/// accumulators are 4.x's.
pub const Compiler = struct {
    regs: *ra.Regs,
    reg_class_any: [2]*ra.Class,
    reg_class_phys: [2]*ra.Class,

    pub fn deinit(compiler: *Compiler) void {
        compiler.regs.destroy();
    }
};

/// What the register allocator knows of each node of its graph (struct
/// v3d_ra_node_info, v3d_compiler.h:579).
pub const RaNodeInfo = struct {
    /// How long its temporary is live, which 4.x's accumulators go by.
    priority: u32 = 0,
    class_bits: u8 = 0,
    /// Its temporary is among those of the program's last instructions.
    is_program_end: bool = false,
    /// Its temporary is not live anywhere.
    unused: bool = false,
    /// It may be given a payload register, which it must not be.
    payload_conflict: bool = false,
    /// Its temporary is an ldunif's, which rf0 spares an ldunifrf.
    try_rf0: bool = false,
};

pub const RaNodes = struct {
    info: []RaNodeInfo = &.{},
    alloc_count: u32 = 0,
};

/// A program being compiled (struct v3d_compile, v3d_compiler.h:597):
/// the part of it the files ported so far use, each field as Mesa names
/// it. The rest comes with the files that use it.
pub const Compile = struct {
    /// Where everything of the compile comes from (Mesa's ralloc context,
    /// and calloc for its instructions).
    allocator: std.mem.Allocator,

    /// For each temporary, the instruction that makes it, where one does.
    defs: []?*Inst = &.{},
    /// Which temporaries may be spilled, a bit each in Mesa's 32-bit words.
    spillable: []u32 = &.{},
    num_temps: u32 = 0,
    /// The operand an instruction does not read.
    undef: Reg = .{},

    /// The program's uniforms: what each holds, and the word it is had
    /// from. Their capacity is Mesa's uniform_array_size.
    uniform_data: []u32 = &.{},
    uniform_contents: []Uniform = &.{},
    num_uniforms: u32 = 0,
    /// Load each uniform with an ldunif of its own, even where one in the
    /// block loaded it already.
    disable_ldunif_opt: bool = false,

    /// Whether each lane runs at the moment: nothing where all do, as at
    /// the top level; otherwise a temporary.
    execute: Reg = .{},

    cursor: Cursor = .{ .mode = .addtail, .link = null },
    /// The head of the program's blocks, in order.
    blocks: Link = .{},
    next_block_index: u32 = 0,
    cur_block: ?*Block = null,
    /// The temporary whose comparison the flags hold, set by a comparison
    /// and dropped by anything else that sets them (-1 for none).
    flags_temp: i32 = -1,
    flags_cond: instr.Cond = .none,
    /// Each temporary's live range, the first and the last instruction it
    /// is live at (live.zig); `live_intervals_valid` says they hold.
    temp_start: []i32 = &.{},
    temp_end: []i32 = &.{},
    live_intervals_valid: bool = false,
    /// The address each spill and fill is made from, where one is.
    spill_base: Reg = .{},

    /// The stage the program is for (c->s->info.stage).
    stage: Stage = .fragment,
    /// The threads the program shares a QPU with, 1, 2 or 4, each thread
    /// switch giving it to another while the TMU answers; at 4 a thread
    /// has half the register file. Mesa's first compile strategy, the
    /// default (vir.c:2215), compiles with 4, as here.
    threads: u8 = 4,
    /// How many TMU spills and fills the register allocator may make:
    /// none in the default strategy, as many as it likes from the third.
    max_tmu_spills: u32 = 0,
    /// The code being emitted is inside control flow.
    in_control_flow: bool = false,
    /// The last thread switch was made outside control flow.
    last_thrsw_at_top_level: bool = false,
    /// The tile buffer has been read, so the scoreboard is locked at the
    /// first thread switch rather than at the last.
    emitted_tlb_load: bool = false,
    lock_scoreboard_on_first_thrsw: bool = false,
    /// The bytes of the spill buffer each thread of each QPU needs.
    spill_size: u32 = 0,
    /// The TMU spills and fills made, for the compile's statistics.
    spills: u32 = 0,
    fills: u32 = 0,
    /// The register allocator is spilling.
    spilling: bool = false,
    /// The temporaries there were when the spill being made began: those
    /// at and above it are the spill's own.
    spill_start_num_temps: u32 = 0,
    /// The program spills to the TMU, which the render's control list is
    /// told of.
    tmu_dirty_rcl: bool = false,

    /// The register sets the allocator allocates from (c->compiler).
    compiler: ?*const Compiler = null,
    /// While registers are allocated: which of the compiler's classes the
    /// threads give, each node's information, and the graph.
    thread_index: u32 = 0,
    nodes: RaNodes = .{},
    g: ?*ra.Graph = null,

    /// The thread switch that starts the program's last thread section,
    /// where it has one.
    last_thrsw: ?*Inst = null,

    /// The program as the QPU runs it, and how many of its instructions
    /// do nothing.
    qpu_insts: []u64 = &.{},
    qpu_inst_count: u32 = 0,
    nop_count: u32 = 0,
    /// Instructions the scheduler could not keep from stalling on an SFU
    /// result.
    qpu_inst_stalled_count: u32 = 0,
    /// The fragment program's inputs, which its ldvarys read; the
    /// scheduler pipelines that many.
    num_inputs: u32 = 0,

    compilation_result: Result = .succeeded,

    /// The block made last, and through it every block made.
    made: ?*Block = null,

    /// A compile with a first block, which instructions go into: what of
    /// vir_compile_init (vir.c:573) is not the NIR's or the strategy's.
    pub fn create(allocator: std.mem.Allocator) Error!*Compile {
        const c = try allocator.create(Compile);
        c.* = .{ .allocator = allocator };
        c.blocks.initHead();
        errdefer c.destroy();
        c.setEmitBlock(try c.newBlock());
        return c;
    }

    /// Everything of the compile given back, itself too
    /// (vir_compile_destroy, vir.c:2755).
    pub fn destroy(c: *Compile) void {
        // Defuse the check that the cursor's instruction is not removed.
        c.cursor.link = null;
        var blocks = c.eachBlock();
        while (blocks.next()) |block| {
            var insts = eachInstSafe(block);
            while (insts.next()) |inst| c.removeInstruction(inst);
        }
        const allocator = c.allocator;
        var made = c.made;
        while (made) |block| {
            made = block.made_before;
            block.predecessors.deinit(allocator);
            freeLiveness(allocator, block);
            allocator.destroy(block);
        }
        allocator.free(c.defs);
        allocator.free(c.spillable);
        allocator.free(c.uniform_data);
        allocator.free(c.uniform_contents);
        allocator.free(c.temp_start);
        allocator.free(c.temp_end);
        allocator.free(c.qpu_insts);
        allocator.free(c.nodes.info);
        if (c.g) |g| g.destroy();
        allocator.destroy(c);
    }

    /// A new temporary (vir_get_temp, vir.c:348). Mesa grows the
    /// definitions to twice their size, 16 at first, and marks each new
    /// temporary as one that may be spilled.
    pub fn getTemp(c: *Compile) Error!Reg {
        const index = c.num_temps;
        if (index + 1 > c.defs.len) {
            const old_size = c.defs.len;
            const size = @max(old_size * 2, 16);
            c.defs = try c.allocator.realloc(c.defs, size);
            @memset(c.defs[old_size..], null);
            const old_words = c.spillable.len;
            c.spillable = try c.allocator.realloc(c.spillable, bitsetWords(size));
            @memset(c.spillable[old_words..], 0);
            for (old_size..size) |at| bitsetSet(c.spillable, at);
        }
        c.num_temps += 1;
        return .{ .file = .temp, .index = index };
    }

    /// `op` on the add side, made but not yet emitted (vir_add_inst,
    /// vir.c:375).
    pub fn addInst(c: *Compile, op: AddOp, dst: Reg, src0: Reg, src1: Reg) Error!*Inst {
        const inst = try c.allocator.create(Inst);
        inst.* = .{ .dst = dst, .src = .{ src0, src1, .{} } };
        inst.qpu.alu.add.op = op;
        return inst;
    }

    /// `op` on the mul side (vir_mul_inst, vir.c:393).
    pub fn mulInst(c: *Compile, op: MulOp, dst: Reg, src0: Reg, src1: Reg) Error!*Inst {
        const inst = try c.allocator.create(Inst);
        inst.* = .{ .dst = dst, .src = .{ src0, src1, .{} } };
        inst.qpu.alu.mul.op = op;
        return inst;
    }

    /// A branch, relative, taking the uniform stream with it to a uniform
    /// the scheduler fills in (vir_branch_inst, vir.c:411).
    pub fn branchInst(c: *Compile, cond: instr.BranchCond) Error!*Inst {
        const inst = try c.allocator.create(Inst);
        errdefer c.allocator.destroy(inst);
        inst.* = .{ .dst = nopReg() };
        inst.qpu.kind = .branch;
        inst.qpu.branch.cond = cond;
        inst.qpu.branch.msfign = .none;
        inst.qpu.branch.bdi = .rel;
        inst.qpu.branch.ub = true;
        inst.qpu.branch.bdu = .rel;
        inst.uniform = try c.getUniformIndex(.constant, 0);
        return inst;
    }

    /// `inst` put where the cursor says, and the cursor after it
    /// (vir_emit, vir.c:432).
    fn emit(c: *Compile, inst: *Inst) void {
        inst.ip = -1;
        const at = c.cursor.link.?;
        switch (c.cursor.mode) {
            .add => inst.link.add(at),
            .addtail => inst.link.addTail(at),
        }
        c.cursor = afterInst(inst);
        c.live_intervals_valid = false;
    }

    /// `inst` made to write a new temporary, emitted, and noted as what
    /// makes it (vir_emit_def, vir.c:451). Where no temporary can be had,
    /// `inst` is given back.
    pub fn emitDef(c: *Compile, inst: *Inst) Error!Reg {
        assert(inst.dst.file == .null);
        // An instruction that makes a value had better write a register.
        if (inst.qpu.kind == .alu) {
            assert(inst.qpu.alu.add.op == .nop or instr.addOpHasDst(inst.qpu.alu.add.op));
            assert(inst.qpu.alu.mul.op == .nop or instr.mulOpHasDst(inst.qpu.alu.mul.op));
        }
        inst.dst = c.getTemp() catch |err| {
            c.allocator.destroy(inst);
            return err;
        };
        if (inst.dst.file == .temp) c.defs[inst.dst.index] = inst;
        c.emit(inst);
        return inst.dst;
    }

    /// `inst` emitted as it is; a temporary it writes is no longer made by
    /// one instruction (vir_emit_nondef, vir.c:476).
    pub fn emitNondef(c: *Compile, inst: *Inst) *Inst {
        if (inst.dst.file == .temp) c.defs[inst.dst.index] = null;
        c.emit(inst);
        return inst;
    }

    /// A new block, in no place yet (vir_new_block, vir.c:487).
    pub fn newBlock(c: *Compile) Error!*Block {
        const block = try c.allocator.create(Block);
        block.* = .{ .index = c.next_block_index, .made_before = c.made };
        block.instructions.initHead();
        c.made = block;
        c.next_block_index += 1;
        return block;
    }

    /// `block` put at the end of the program, and instructions emitted
    /// into it from now (vir_set_emit_block, vir.c:503).
    pub fn setEmitBlock(c: *Compile, block: *Block) void {
        c.cur_block = block;
        c.cursor = afterBlock(block);
        block.link.addTail(&c.blocks);
    }

    /// vir_entry_block (vir.c:511).
    pub fn entryBlock(c: *Compile) *Block {
        return list.firstEntry(Block, "link", &c.blocks);
    }

    /// vir_exit_block (vir.c:517).
    pub fn exitBlock(c: *Compile) *Block {
        return list.lastEntry(Block, "link", &c.blocks);
    }

    /// `successor` noted as a block `predecessor` goes on to: its first,
    /// or its second (vir_link_blocks, vir.c:523).
    pub fn linkBlocks(c: *Compile, predecessor: *Block, successor: *Block) Error!void {
        if (std.mem.indexOfScalar(*Block, successor.predecessors.items, predecessor) == null) {
            try successor.predecessors.append(c.allocator, predecessor);
        }
        if (predecessor.successors[0] != null) {
            assert(predecessor.successors[1] == null);
            predecessor.successors[1] = successor;
        } else {
            predecessor.successors[0] = successor;
        }
    }

    /// `inst` taken out of its block and given back
    /// (vir_remove_instruction, vir.c:2721).
    pub fn removeInstruction(c: *Compile, inst: *Inst) void {
        if (inst.dst.file == .temp) c.defs[inst.dst.index] = null;
        assert(c.cursor.link != &inst.link);
        inst.link.del();
        c.allocator.destroy(inst);
        c.live_intervals_valid = false;
    }

    /// vir_follow_movs (vir.c:2735): Mesa's body is commented out, and it
    /// answers the register it is given.
    pub fn followMovs(c: *Compile, r: Reg) Reg {
        _ = c;
        return r;
    }

    /// The uniform's index in the program's uniforms, which it is put at
    /// the end of where it is not among them (vir_get_uniform_index,
    /// vir.c:2771).
    pub fn getUniformIndex(c: *Compile, contents: Uniform, data: u32) Error!u32 {
        for (c.uniform_contents[0..c.num_uniforms], c.uniform_data[0..c.num_uniforms], 0..) |held, word, at| {
            if (held == contents and word == data) return @intCast(at);
        }
        const added = c.num_uniforms;
        const capacity = @min(c.uniform_data.len, c.uniform_contents.len);
        if (added >= capacity) {
            const size = @max(@max(16, added + 1), capacity * 2);
            c.uniform_data = try c.allocator.realloc(c.uniform_data, size);
            c.uniform_contents = try c.allocator.realloc(c.uniform_contents, size);
        }
        c.num_uniforms += 1;
        c.uniform_contents[added] = contents;
        c.uniform_data[added] = data;
        return added;
    }

    /// The temporary an ldunif of the uniform at `index` wrote earlier in
    /// the current block, where one did and nothing wrote it since
    /// (try_opt_ldunif, vir.c:2811). It looks back through 20
    /// instructions at most, to keep registers free. It starts at the
    /// link before the cursor's, as Mesa does: after an emit that is the
    /// instruction before the one just emitted, which is not looked at.
    fn tryOptLdunif(c: *Compile, index: u32) ?Reg {
        var count: u32 = 20;
        var prev_inst: ?*Inst = null;
        const block = c.cur_block.?;

        // A uniform is reused only from the block being emitted into, so
        // the cursor is in it.
        if (std.debug.runtime_safety) {
            var found = c.cursor.link == &block.instructions;
            var insts = eachInst(block);
            while (insts.next()) |inst| {
                if (&inst.link == c.cursor.link) found = true;
            }
            assert(found);
        }

        var back = list.Each(Inst, "link", .backward){ .head = &block.instructions, .pos = c.cursor.link.?.prev.? };
        while (back.next()) |inst| {
            if ((inst.qpu.sig.ldunif or inst.qpu.sig.ldunifrf) and inst.uniform == index) {
                prev_inst = inst;
                break;
            }
            count -= 1;
            if (count == 0) break;
        }

        const loaded = prev_inst orelse return null;
        // Only one written to a temporary: an ldunif may write a magic
        // address, unifa for one, which cannot be read.
        if (loaded.dst.file != .temp) return null;

        var later = list.Each(Inst, "link", .forward){ .head = &block.instructions, .pos = loaded.link.next.? };
        while (later.next()) |inst| {
            if (inst.dst.file == loaded.dst.file and inst.dst.index == loaded.dst.index) return null;
        }
        return loaded.dst;
    }

    /// The uniform loaded into a temporary, or the temporary an ldunif of
    /// it in this block wrote already (vir_uniform, vir.c:2868).
    pub fn uniform(c: *Compile, contents: Uniform, data: u32) Error!Reg {
        const num_uniforms = c.num_uniforms;
        const index = try c.getUniformIndex(contents, data);
        // Where the uniform was seen before, the last ldunif of it may do.
        const is_new_uniform = num_uniforms != c.num_uniforms;
        if (!is_new_uniform and !c.disable_ldunif_opt) {
            if (c.tryOptLdunif(index)) |ldunif_dst| return ldunif_dst;
        }
        const inst = try c.nop();
        inst.qpu.sig.ldunif = true;
        inst.uniform = index;
        inst.dst = try c.getTemp();
        c.defs[inst.dst.index] = inst;
        return inst.dst;
    }

    /// vir_uniform_ui (v3d_compiler.h:1254).
    pub fn uniformUi(c: *Compile, ui: u32) Error!Reg {
        return c.uniform(.constant, ui);
    }

    /// vir_uniform_f (v3d_compiler.h:1260).
    pub fn uniformF(c: *Compile, f: f32) Error!Reg {
        return c.uniform(.constant, @bitCast(f));
    }

    /// Some lanes may not run here (vir_in_nonuniform_control_flow,
    /// v3d_compiler.h:1248).
    pub fn inNonuniformControlFlow(c: *const Compile) bool {
        return c.execute.file != .null;
    }

    /// The flags `inst` pushes; any comparison they held is dropped
    /// (vir_set_pf, vir.c:275).
    pub fn setPf(c: *Compile, inst: *Inst, pf: instr.Pf) void {
        c.flags_temp = -1;
        if (isAdd(inst)) {
            inst.qpu.flags.apf = pf;
        } else {
            assert(isMul(inst));
            inst.qpu.flags.mpf = pf;
        }
    }

    /// How `inst` updates the flags (vir_set_uf, vir.c:287).
    pub fn setUf(c: *Compile, inst: *Inst, uf: instr.Uf) void {
        c.flags_temp = -1;
        if (isAdd(inst)) {
            inst.qpu.flags.auf = uf;
        } else {
            assert(isMul(inst));
            inst.qpu.flags.muf = uf;
        }
    }

    // What Mesa's VIR_A_ALU0/1/2, VIR_M_ALU0/1/2, VIR_SFU, VIR_SFU2 and
    // VIR_*_NODST_0/1/2 make (v3d_compiler.h:1265-1375), for each op that
    // v3d_compiler.h:1377-1506 names. The op is the argument rather than
    // the name: vir_FADD(c, a, b) is c.add(.fadd, .{ a, b }),
    // vir_MOV_dest(c, d, a) is c.mulDest(.mov, d, .{a}), and
    // vir_STVPMV(c, a, b) is c.addNodst(.stvpmv, .{ a, b }). An operand
    // not given is c.undef, as the macros pass it; VIR_SFU is the add side
    // as VIR_A_ALU1 is.

    fn operands(c: *const Compile, srcs: anytype) [2]Reg {
        var both: [2]Reg = .{ c.undef, c.undef };
        inline for (srcs, 0..) |src, at| both[at] = src;
        return both;
    }

    /// `op` on the add side, written to a new temporary, which is answered.
    pub fn add(c: *Compile, op: AddOp, srcs: anytype) Error!Reg {
        const both = c.operands(srcs);
        return c.emitDef(try c.addInst(op, c.undef, both[0], both[1]));
    }

    /// `op` on the add side, written to `dest` (the macros' `_dest`).
    pub fn addDest(c: *Compile, op: AddOp, dest: Reg, srcs: anytype) Error!*Inst {
        const both = c.operands(srcs);
        return c.emitNondef(try c.addInst(op, dest, both[0], both[1]));
    }

    /// `op` on the add side, written nowhere (VIR_A_NODST_*).
    pub fn addNodst(c: *Compile, op: AddOp, srcs: anytype) Error!*Inst {
        return c.addDest(op, c.undef, srcs);
    }

    /// `op` on the mul side, written to a new temporary.
    pub fn mul(c: *Compile, op: MulOp, srcs: anytype) Error!Reg {
        const both = c.operands(srcs);
        return c.emitDef(try c.mulInst(op, c.undef, both[0], both[1]));
    }

    /// `op` on the mul side, written to `dest`.
    pub fn mulDest(c: *Compile, op: MulOp, dest: Reg, srcs: anytype) Error!*Inst {
        const both = c.operands(srcs);
        return c.emitNondef(try c.mulInst(op, dest, both[0], both[1]));
    }

    /// `op` on the mul side, written nowhere (VIR_M_NODST_*).
    pub fn mulNodst(c: *Compile, op: MulOp, srcs: anytype) Error!*Inst {
        return c.mulDest(op, c.undef, srcs);
    }

    /// A move that happens where `cond` holds (vir_MOV_cond,
    /// v3d_compiler.h:1509).
    pub fn movCond(c: *Compile, cond: instr.Cond, dest: Reg, src: Reg) Error!*Inst {
        const mov = try c.mulDest(.mov, dest, .{src});
        setCond(mov, cond);
        return mov;
    }

    /// `src0` where `cond` holds, else `src1` (vir_SEL,
    /// v3d_compiler.h:1518).
    pub fn sel(c: *Compile, cond: instr.Cond, src0: Reg, src1: Reg) Error!Reg {
        const t = try c.getTemp();
        _ = try c.mulDest(.mov, t, .{src1});
        _ = try c.movCond(cond, t, src0);
        return t;
    }

    /// vir_NOP (v3d_compiler.h:1528).
    pub fn nop(c: *Compile) Error!*Inst {
        return c.emitNondef(try c.addInst(.nop, c.undef, c.undef, c.undef));
    }

    /// A TMU result read into a new temporary (vir_LDTMU,
    /// v3d_compiler.h:1535).
    pub fn ldtmu(c: *Compile) Error!Reg {
        const inst = try c.addInst(.nop, c.undef, c.undef, c.undef);
        inst.qpu.sig.ldtmu = true;
        return c.emitDef(inst);
    }

    /// A thread switch, where the program has another thread to switch
    /// to, and the last one made until another is (vir_emit_thrsw,
    /// nir_to_vir.c:152). Where the tile buffer was read before it, the
    /// scoreboard can no longer be locked at the last.
    pub fn emitThrsw(c: *Compile) Error!void {
        if (c.threads == 1) return;
        const thrsw = try c.nop();
        thrsw.qpu.sig.thrsw = true;
        c.last_thrsw = thrsw;
        c.last_thrsw_at_top_level = !c.in_control_flow;
        if (c.emitted_tlb_load) c.lock_scoreboard_on_first_thrsw = true;
    }

    /// The most temporaries live at any one instruction, a range counting
    /// from its start and not at its end, as the allocator's interference
    /// has it (vir_get_max_temps, vir.c:1343).
    pub fn getMaxTemps(c: *Compile) Error!u32 {
        var max_ip: i32 = 0;
        var insts = c.eachInstInorder();
        while (insts.next()) |_| max_ip += 1;

        // +1 where a range starts and -1 where it ends, then summed.
        const delta = try c.allocator.alloc(i32, @intCast(max_ip + 1));
        defer c.allocator.free(delta);
        @memset(delta, 0);
        for (c.temp_start[0..c.num_temps], c.temp_end[0..c.num_temps]) |start, temp_end| {
            if (start < 0 or start >= max_ip) continue;
            var end = temp_end;
            if (end > max_ip) end = max_ip;
            if (end <= start) continue;
            delta[@intCast(start)] += 1;
            delta[@intCast(end)] -= 1;
        }

        var max_temps: u32 = 0;
        var live: i32 = 0;
        for (delta[0..@intCast(max_ip)]) |d| {
            live += d;
            max_temps = @max(max_temps, @as(u32, @bitCast(live)));
        }
        return max_temps;
    }

    /// A 32-bit multiply: multop, then umul24 (vir_UMUL,
    /// v3d_compiler.h:1545).
    pub fn umul(c: *Compile, src0: Reg, src1: Reg) Error!Reg {
        _ = try c.mulNodst(.multop, .{ src0, src1 });
        return c.mul(.umul24, .{ src0, src1 });
    }

    /// The tile buffer read with its configuration in a uniform
    /// (vir_TLBU_READ, v3d_compiler.h:1552).
    pub fn tlbuRead(c: *Compile, config: u32) Error!Reg {
        assert(config & 0xffffff00 == 0xffffff00);
        const ldtlb = try c.addInst(.nop, c.undef, c.undef, c.undef);
        ldtlb.qpu.sig.ldtlbu = true;
        ldtlb.uniform = c.getUniformIndex(.constant, config) catch |err| {
            c.allocator.destroy(ldtlb);
            return err;
        };
        return c.emitDef(ldtlb);
    }

    /// The tile buffer read as configured before (vir_TLB_READ,
    /// v3d_compiler.h:1564).
    pub fn tlbRead(c: *Compile) Error!Reg {
        const ldtlb = try c.addInst(.nop, c.undef, c.undef, c.undef);
        ldtlb.qpu.sig.ldtlb = true;
        return c.emitDef(ldtlb);
    }

    /// A branch, its uniform filled in at scheduling (vir_BRANCH,
    /// v3d_compiler.h:1573).
    pub fn branch(c: *Compile, cond: instr.BranchCond) Error!*Inst {
        return c.emitNondef(try c.branchInst(cond));
    }

    /// The program's blocks in order (vir_for_each_block,
    /// v3d_compiler.h:1609).
    pub fn eachBlock(c: *Compile) list.Each(Block, "link", .forward) {
        return .{ .head = &c.blocks, .pos = c.blocks.next.? };
    }

    /// vir_for_each_block_rev (v3d_compiler.h:1612).
    pub fn eachBlockRev(c: *Compile) list.Each(Block, "link", .backward) {
        return .{ .head = &c.blocks, .pos = c.blocks.prev.? };
    }

    /// Every instruction of every block, in order
    /// (vir_for_each_inst_inorder, v3d_compiler.h:1631).
    pub fn eachInstInorder(c: *Compile) InOrder(list.Each(Inst, "link", .forward), eachInst) {
        return .{ .blocks = c.eachBlock() };
    }

    /// The same, each instruction's follower read before it is had, so it
    /// may be removed (vir_for_each_inst_inorder_safe,
    /// v3d_compiler.h:1635).
    pub fn eachInstInorderSafe(c: *Compile) InOrder(list.EachSafe(Inst, "link", .forward), eachInstSafe) {
        return .{ .blocks = c.eachBlock() };
    }
};

/// What the liveness analysis keeps in a block, given back.
pub fn freeLiveness(allocator: std.mem.Allocator, block: *Block) void {
    inline for (.{ "def", "defin", "defout", "use", "live_in", "live_out" }) |field| {
        allocator.free(@field(block, field));
        @field(block, field) = &.{};
    }
}

/// vir_has_uniform (v3d_compiler.h:1102).
pub fn hasUniform(inst: *const Inst) bool {
    return inst.uniform != null;
}

/// The operands `inst` reads (vir_get_nsrc, vir.c:33).
pub fn getNsrc(inst: *const Inst) u2 {
    return switch (inst.qpu.kind) {
        .branch => 0,
        .alu => if (inst.qpu.alu.add.op != .nop)
            instr.addOpNumSrc(inst.qpu.alu.add.op)
        else
            instr.mulOpNumSrc(inst.qpu.alu.mul.op),
    };
}

/// `inst` does something that must be kept beside the value it makes
/// (vir_has_side_effects, vir.c:53).
pub fn hasSideEffects(inst: *const Inst) bool {
    switch (inst.qpu.kind) {
        .branch => return true,
        .alu => {
            switch (inst.qpu.alu.add.op) {
                .setrevf, .setmsf, .vpmsetup, .stvpmv, .stvpmd, .stvpmp, .vpmwt, .tmuwt, .setnnmode_uu, .setnnmode_su, .setnnmode_us, .setnnmode_ss => return true,
                else => {},
            }
            switch (inst.qpu.alu.mul.op) {
                .multop => return true,
                else => {},
            }
        },
    }
    const sig = inst.qpu.sig;
    if (sig.ldtmu or sig.ldvary or sig.ldtlbu or sig.ldtlb or sig.wrtmuc or sig.thrsw) return true;
    // An ldunifa reads a word and moves the address on, as ldunif does;
    // the uniform stream is made again from the uniforms left after
    // compiling, but the unifa address is not, so each is kept.
    if (sig.ldunifa or sig.ldunifarf) return true;
    return false;
}

/// A move and nothing else: no packing, no unpacking, no condition
/// (vir_is_raw_mov, vir.c:109).
pub fn isRawMov(inst: *const Inst) bool {
    const alu = &inst.qpu.alu;
    if (inst.qpu.kind != .alu or (alu.mul.op != .fmov and alu.mul.op != .mov)) return false;
    if (alu.add.output_pack != .none or alu.mul.output_pack != .none) return false;
    if (alu.add.a.unpack != .none or alu.add.b.unpack != .none or alu.mul.a.unpack != .none or alu.mul.b.unpack != .none) return false;
    if (inst.qpu.flags.ac != .none or inst.qpu.flags.mc != .none) return false;
    return true;
}

/// vir_is_add (vir.c:137).
pub fn isAdd(inst: *const Inst) bool {
    return inst.qpu.kind == .alu and inst.qpu.alu.add.op != .nop;
}

/// vir_is_mul (vir.c:144).
pub fn isMul(inst: *const Inst) bool {
    return inst.qpu.kind == .alu and inst.qpu.alu.mul.op != .nop;
}

/// `inst` writes the TMU, or waits for it (vir_is_tex, vir.c:151).
pub fn isTex(inst: *const Inst) bool {
    if (inst.dst.file == .magic) return instr.magicWaddrIsTmu(@intCast(inst.dst.index));
    if (inst.qpu.kind == .alu and inst.qpu.alu.add.op == .tmuwt) return true;
    return false;
}

/// How operand `src`, 0 or 1, is unpacked (vir_set_unpack, vir.c:190).
pub fn setUnpack(inst: *Inst, src: usize, unpack: instr.InputUnpack) void {
    assert(src == 0 or src == 1);
    if (isAdd(inst)) {
        if (src == 0) inst.qpu.alu.add.a.unpack = unpack else inst.qpu.alu.add.b.unpack = unpack;
    } else {
        assert(isMul(inst));
        if (src == 0) inst.qpu.alu.mul.a.unpack = unpack else inst.qpu.alu.mul.b.unpack = unpack;
    }
}

/// How the result is packed (vir_set_pack, vir.c:210).
pub fn setPack(inst: *Inst, pack: instr.OutputPack) void {
    if (isAdd(inst)) {
        inst.qpu.alu.add.output_pack = pack;
    } else {
        assert(isMul(inst));
        inst.qpu.alu.mul.output_pack = pack;
    }
}

/// How operand `src` is unpacked; nothing for what is not ALU work, such
/// as a TMU write or a signal (vir_get_unpack, vir.c:225).
pub fn getUnpack(inst: *const Inst, src: usize) instr.InputUnpack {
    if (inst.qpu.kind != .alu) return .none;
    assert(src == 0 or src == 1);
    if (isAdd(inst)) {
        return if (src == 0) inst.qpu.alu.add.a.unpack else inst.qpu.alu.add.b.unpack;
    }
    return if (src == 0) inst.qpu.alu.mul.a.unpack else inst.qpu.alu.mul.b.unpack;
}

/// How the side that writes the destination packs it (vir_get_pack,
/// vir.c:242).
pub fn getPack(inst: *const Inst) instr.OutputPack {
    if (isMul(inst)) return inst.qpu.alu.mul.output_pack;
    return inst.qpu.alu.add.output_pack;
}

/// The condition `inst` runs under (vir_set_cond, vir.c:251).
pub fn setCond(inst: *Inst, cond: instr.Cond) void {
    if (isAdd(inst)) {
        inst.qpu.flags.ac = cond;
    } else {
        assert(isMul(inst));
        inst.qpu.flags.mc = cond;
    }
}

/// vir_get_cond (vir.c:262).
pub fn getCond(inst: *const Inst) instr.Cond {
    assert(inst.qpu.kind == .alu);
    if (isAdd(inst)) return inst.qpu.flags.ac;
    if (isMul(inst)) return inst.qpu.flags.mc;
    return .none;
}

/// A block's instructions in order (vir_for_each_inst,
/// v3d_compiler.h:1622).
pub fn eachInst(block: *Block) list.Each(Inst, "link", .forward) {
    return .{ .head = &block.instructions, .pos = block.instructions.next.? };
}

/// vir_for_each_inst_rev (v3d_compiler.h:1625).
pub fn eachInstRev(block: *Block) list.Each(Inst, "link", .backward) {
    return .{ .head = &block.instructions, .pos = block.instructions.prev.? };
}

/// The same, each one's follower read before it is had, so it may be
/// removed (vir_for_each_inst_safe, v3d_compiler.h:1628).
pub fn eachInstSafe(block: *Block) list.EachSafe(Inst, "link", .forward) {
    return .{ .head = &block.instructions, .pos = block.instructions.next.? };
}

/// The blocks `block` goes on to, each once (vir_for_each_successor,
/// v3d_compiler.h:1616).
pub fn eachSuccessor(block: *Block) Successors {
    return .{ .block = block, .at = block.successors[0] };
}

pub const Successors = struct {
    block: *Block,
    at: ?*Block,

    pub fn next(it: *Successors) ?*Block {
        const succ = it.at orelse return null;
        it.at = if (succ == it.block.successors[1]) null else it.block.successors[1];
        return succ;
    }
};

/// Every instruction of every block, the blocks walked as
/// vir_for_each_block walks them and each one's instructions as `start`
/// walks those.
pub fn InOrder(comptime Insts: type, comptime start: fn (*Block) Insts) type {
    return struct {
        blocks: list.Each(Block, "link", .forward),
        insts: ?Insts = null,

        pub fn next(it: *@This()) ?*Inst {
            while (true) {
                if (it.insts) |*insts| {
                    if (insts.next()) |inst| return inst;
                }
                const block = it.blocks.next() orelse return null;
                it.insts = start(block);
            }
        }
    };
}

/// BITSET_WORDS: the 32-bit words `bits` bits take.
pub fn bitsetWords(bits: usize) usize {
    return (bits + 31) / 32;
}

/// BITSET_SET.
pub fn bitsetSet(words: []u32, bit: usize) void {
    words[bit / 32] |= @as(u32, 1) << @intCast(bit % 32);
}

/// BITSET_CLEAR.
pub fn bitsetClear(words: []u32, bit: usize) void {
    words[bit / 32] &= ~(@as(u32, 1) << @intCast(bit % 32));
}

/// BITSET_TEST.
pub fn bitsetTest(words: []const u32, bit: usize) bool {
    return words[bit / 32] & (@as(u32, 1) << @intCast(bit % 32)) != 0;
}
