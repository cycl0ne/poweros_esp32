// SPDX-License-Identifier: MPL-2.0
//! The BCM2711's H.265 decoder (CHIP_BCM2711_HEVC): Main and Main 10,
//! 4:2:0, up to 4096 x 4096, decoded from the parameter sets and slice
//! headers the host read (videoparse.library) into frames of 128-byte
//! columns. What its registers mean, and the order its commands go in,
//! are as Raspberry Pi's Linux driver for it (`hevc_dec`, rpi-6.12.y)
//! has them; the code is this file's own.
//!
//! **Two phases.** A picture is decoded twice over. Phase 1 reads the
//! slices' data - its entropy decoding - into two buffers the block
//! keeps between the phases, the prediction units' and the
//! coefficients', each a region for every row of CTBs. It is driven by a
//! list of commands in memory, each a register of the block and its
//! value, which the block writes in order: the slice's data, its
//! contexts' first states, its messages - type, references, weights,
//! deblocking - and then one run of decoding for each tile, or each row
//! of CTBs under wavefront decoding, with markers where each run must
//! end. Writing the list's address starts it; the interrupt controller's
//! ACTIVE1 says it ended, and it went right when the block did every
//! command (CFSTATUS is CFNUM). A buffer that ran out says so in STATUS:
//! it is made twice as large and the phase run again. Phase 2 rebuilds
//! the picture from the two buffers - prediction, transforms, deblocking,
//! SAO - into its frame, from up to 16 references named by their frames'
//! addresses, and writes its motion vectors for the pictures after it to
//! take as their collocated picture. It is started by writing the number
//! of rows; ACTIVE2 says it ended. It says nothing of how it went.
//!
//! **The list's commands** are only partly understood: STATUS waits for
//! the block to stop where it says, TRANSFER keeps or brings back the
//! contexts (a tile's start, wavefront's storage after a row's second
//! CTB), MODE says where to pause, CONTROL starts at a CTB. They are put
//! down here as the Linux driver puts them, including its pause after a
//! row that a slice began past the pause point.
//!
//! **The frames** are NV12 cut into columns 128 bytes wide - 128
//! samples, or 96 of 10 bits, three to a word - each column every row of
//! brightness, then every row of colour pairs, a column's pitch apart;
//! every frame of a stream laid out alike, since the block takes only
//! the current frame's pitch. The block writes no cropping.
//!
//! **Memory** is the system's, at the address the processor has it -
//! the block reaches the first 64 GiB one to one - and written back from
//! the caches before the block reads it, dropped from them after it
//! wrote. Every base is on a 64-byte boundary; registers take addresses
//! and lengths in units of 64 bytes.
//!
//! **Its clock** is the VideoCore firmware's (clock 11), set to its most
//! through the mailbox when the block is started. There is no reset and
//! no power switch; a phase that never ends is waited for no longer than
//! a second, and the block is then taken as dead.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const st = sdk.expansion.systemtags;
const hevc = sdk.videoparse.hevc;
const hardware = sdk.hardware;
const videocore = hardware.videocore;
const ExecBase = sdk.interface.exec.ExecBase;

/// The largest picture the block takes.
pub const most_width: u32 = 4096;
pub const most_height: u32 = 4096;
/// The reference frames a picture names at most.
pub const ref_slots = 16;

// --- registers ----------------------------------------------------------------

// Phase 1's: most of them only the command list writes.
const SPS0: u32 = 0x00;
const SPS1: u32 = 0x04;
const PPS: u32 = 0x08;
const SLICE: u32 = 0x0C;
const TILESTART: u32 = 0x10;
const TILEEND: u32 = 0x14;
const SLICESTART: u32 = 0x18;
const MODE: u32 = 0x1C;
const QP: u32 = 0x30;
const CONTROL: u32 = 0x34;
const STATUS: u32 = 0x38;
const BFBASE: u32 = 0x40;
const BFNUM: u32 = 0x44;
const BFCONTROL: u32 = 0x48;
const PUWBASE: u32 = 0x50;
const PUWSTRIDE: u32 = 0x54;
const COEFFWBASE: u32 = 0x58;
const COEFFWSTRIDE: u32 = 0x5C;
const SLICECMDS: u32 = 0x60;
const BEGINTILEEND: u32 = 0x64;
const TRANSFER: u32 = 0x68;
const CFBASE: u32 = 0x6C;
const CFNUM: u32 = 0x70;
const CFSTATUS: u32 = 0x74;
/// The contexts' first states, the scaling factors and the slice's
/// messages: tables only the command list reaches.
const PROB: u32 = 0x1000;
const SCALING: u32 = 0x2000;
const MESSAGES: u32 = 0x4000;

// Phase 2's, all written by the processor.
const PURBASE: usize = 0x8000;
const PURSTRIDE: usize = 0x8004;
const COEFFRBASE: usize = 0x8008;
const COEFFRSTRIDE: usize = 0x800C;
const NUMROWS: usize = 0x8010;
const CONFIG2: usize = 0x8014;
const OUTYBASE: usize = 0x8018;
const OUTYSTRIDE: usize = 0x801C;
const OUTCBASE: usize = 0x8020;
const OUTCSTRIDE: usize = 0x8024;
const FRAMESIZE: usize = 0x802C;
const MVBASE: usize = 0x8030;
const MVSTRIDE: usize = 0x8034;
const COLBASE: usize = 0x8038;
const COLSTRIDE: usize = 0x803C;
const CURRPOC: usize = 0x8040;
/// The references' frames: 16 of four words, luma base, its pitch,
/// chroma base, its pitch (the pitches unused).
const REFS: usize = 0x9000;

/// The interrupt controller, 64 KiB above the registers: one register,
/// ICTRL. ACTIVE1 and ACTIVE2 latch when a phase ends (written 1 to
/// clear), each only while its enable is set; the bits in `ictrl_zero`
/// are written 0; the block's H.264 and VP9 sources are left off.
pub const intc_offset: usize = 0x1_0000;
pub const ACTIVE1: u32 = 1 << 0;
pub const ACTIVE2: u32 = 1 << 4;
const ACTIVE1_EN: u32 = 1 << 2;
const ACTIVE2_EN: u32 = 1 << 6;
const ictrl_zero: u32 = 0x000F_F800;
const ictrl_ours: u32 = 0x2200_0011;

/// TRANSFER: the contexts kept, or brought back.
const PROB_BACKUP: u32 = 0x1_4500;
const PROB_RELOAD: u32 = 0x1_4014;
/// MODE's pause: after a row's second CTB (wavefront), never (tiles).
const PAUSE_WPP: u32 = 1;
const PAUSE_TILE: u32 = 0xFFFF;
/// STATUS read after phase 1: the coefficients' buffer, or the
/// prediction units', ran out.
pub const COEFF_SHORT: u32 = 1 << 3;
pub const PU_SHORT: u32 = 1 << 4;

/// The firmware's clock for the block, and its tags.
const CLOCK_HEVC: u32 = 11;
const TAG_GET_MAX_CLOCK_RATE: u32 = 0x0003_0004;
const TAG_SET_CLOCK_RATE: u32 = 0x0003_8002;

inline fn at(regs: usize, offset: usize) *volatile u32 {
    return hardware.mmio.reg(regs + offset);
}

// --- the part -------------------------------------------------------------------

/// The block as the board lists it, and the firmware's mailbox its clock
/// is asked through.
pub const Part = struct { regs: usize, irq: u32, mailbox: usize, h264: bool };

/// The board's H.265 block, and its firmware's mailbox; null on a board
/// with either missing.
pub fn find(sys: *ExecBase) ?Part {
    const utility_lib = sys.OpenLibrary(sdk.utility.UTILITYNAME, 0) orelse return null;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return null;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_VIDEODEC, st.CHIP_BCM2711_HEVC) orelse return null;
    const firmware = eb.FindBoardPart(null, st.PARTKIND_FIRMWARE, st.CHIP_RPI_FIRMWARE) orelse return null;
    const regs = ub.GetTagData(st.PART_Address, 0, part.tags);
    const irq = ub.GetTagData(st.PART_Irq, 0, part.tags);
    const mailbox = ub.GetTagData(st.PART_Address, 0, firmware.tags);
    if (regs == 0 or irq == 0 or mailbox == 0) return null;
    // H.264 is the firmware's, behind its queue (decoder/_mmal.zig).
    const queue = eb.FindBoardPart(null, st.PARTKIND_FIRMWARE, st.CHIP_BCM2711_VCHIQ) != null;
    return .{ .regs = regs, .irq = @intCast(irq), .mailbox = mailbox, .h264 = queue };
}

/// What the resource keeps of the block beside its registers: the
/// mailbox, the clock's rate, and what the interrupt server took from
/// ICTRL until a phase's end is waited for.
pub const State = extern struct {
    mailbox: usize = 0,
    rate: u32 = 0,
    raised: u32 = 0,
    done: exec.Waitable = .{},
};

/// The block's clock at its most, and its interrupt controller made to
/// latch the two phases' ends, anything latched before cleared: the
/// clock's rate in Hz, or null when the firmware did not answer.
pub fn start(sys: *ExecBase, regs: usize, mailbox: usize) ?u32 {
    const bytes = 2 * videocore.buffer_bytes;
    const memory = sys.AllocMem(bytes, exec.MEMF_DMA) orelse return null;
    defer sys.FreeMem(memory, bytes);
    const buffer = videocore.bufferIn(memory) orelse return null;
    var most = [_]u32{ CLOCK_HEVC, 0 };
    if (!videocore.call(sys, mailbox, buffer, TAG_GET_MAX_CLOCK_RATE, &most) or most[1] == 0) return null;
    var rate = [_]u32{ CLOCK_HEVC, most[1], 0 };
    if (!videocore.call(sys, mailbox, buffer, TAG_SET_CLOCK_RATE, &rate)) return null;
    const ictrl = at(regs, intc_offset);
    ictrl.* = ACTIVE1_EN | ACTIVE2_EN;
    ictrl.* = ictrl.* & ~ictrl_zero;
    return rate[1];
}

/// The interrupt server's part: what ICTRL latched taken and cleared -
/// ACTIVE1 and ACTIVE2 of it - or null when it latched nothing of the
/// block's.
pub fn takeInterrupt(regs: usize) ?u32 {
    const ictrl = at(regs, intc_offset);
    const raised = ictrl.*;
    if (raised & ictrl_ours == 0) return null;
    ictrl.* = raised & ~ictrl_zero;
    return raised & (ACTIVE1 | ACTIVE2);
}

/// What the block's registers say of where it is, for a phase that did
/// not end: ICTRL, STATUS, and commands done of those given.
pub const Registers = struct { ictrl: u32, status: u32, done: u32, count: u32 };

pub fn registers(regs: usize) Registers {
    return .{ .ictrl = at(regs, intc_offset).*, .status = at(regs, STATUS).*, .done = at(regs, CFSTATUS).*, .count = at(regs, CFNUM).* };
}

/// Phase 1 started on the `count` commands at `list`, into the
/// prediction units' and coefficients' buffers given, `pu_stride` and
/// `coeff_stride` bytes a row of CTBs.
pub fn runPhase1(regs: usize, list: usize, count: u32, pu: usize, pu_stride: u32, coeff: usize, coeff_stride: u32) void {
    at(regs, PUWBASE).* = a64(pu);
    at(regs, PUWSTRIDE).* = pu_stride >> 6;
    at(regs, COEFFWBASE).* = a64(coeff);
    at(regs, COEFFWSTRIDE).* = coeff_stride >> 6;
    at(regs, CFNUM).* = count;
    hardware.barrier.toDevice();
    at(regs, CFBASE).* = a64(list);
}

/// How phase 1 ended: done; a buffer short (COEFF_SHORT, PU_SHORT); or
/// stopped on the stream.
pub const Phase1 = union(enum) { done, short: u32, failed: u32 };

pub fn phase1Ended(regs: usize) Phase1 {
    const done = at(regs, CFSTATUS).*;
    const count = at(regs, CFNUM).*;
    const status = at(regs, STATUS).*;
    if (done == count) return .done;
    if (status & (COEFF_SHORT | PU_SHORT) != 0) return .{ .short = status & (COEFF_SHORT | PU_SHORT) };
    return .{ .failed = done };
}

/// What phase 2 is given: the two buffers phase 1 filled and their
/// strides, the frame it writes and the references' (luma bases; each
/// frame's chroma `layout.chroma` above), the picture's constants, the
/// motion vectors it writes and the collocated picture's (0: none).
pub const Phase2 = struct {
    pu: usize,
    pu_stride: u32,
    coeff: usize,
    coeff_stride: u32,
    frame: usize,
    refs: [ref_slots]usize,
    layout: *const Layout,
    config2: u32,
    framesize: u32,
    poc: i32,
    mv: usize,
    col: usize,
    rows: u32,
};

pub fn runPhase2(regs: usize, p: *const Phase2) void {
    const l = p.layout;
    const pitch = l.pitch >> 6;
    at(regs, PURBASE).* = a64(p.pu);
    at(regs, PURSTRIDE).* = p.pu_stride >> 6;
    at(regs, COEFFRBASE).* = a64(p.coeff);
    at(regs, COEFFRSTRIDE).* = p.coeff_stride >> 6;
    at(regs, OUTYBASE).* = a64(p.frame);
    at(regs, OUTCBASE).* = a64(p.frame + l.chroma);
    at(regs, OUTYSTRIDE).* = pitch;
    at(regs, OUTCSTRIDE).* = pitch;
    for (p.refs, 0..) |frame, i| {
        at(regs, REFS + 16 * i).* = a64(frame);
        at(regs, REFS + 16 * i + 4).* = pitch;
        at(regs, REFS + 16 * i + 8).* = a64(frame + l.chroma);
        at(regs, REFS + 16 * i + 12).* = pitch;
    }
    at(regs, CONFIG2).* = p.config2;
    at(regs, FRAMESIZE).* = p.framesize;
    at(regs, CURRPOC).* = @bitCast(p.poc);
    at(regs, COLSTRIDE).* = l.mv_stride >> 6;
    at(regs, MVSTRIDE).* = l.mv_stride >> 6;
    at(regs, MVBASE).* = if (p.mv != 0) a64(p.mv) else 0;
    at(regs, COLBASE).* = if (p.col != 0) a64(p.col) else 0;
    hardware.barrier.toDevice();
    at(regs, NUMROWS).* = p.rows;
}

/// An address as the registers take it: in units of 64 bytes.
fn a64(address: usize) u32 {
    return @truncate(address >> 6);
}

// --- the frames -------------------------------------------------------------------

/// A stream's frames as the block lays them out, and its buffers' sizes.
pub const Layout = struct {
    width: u32 = 0,
    height: u32 = 0,
    ten: bool = false,
    /// The picture's width in samples the columns hold (a multiple of
    /// 128, or of 96 for 10 bits), and its height in rows (of 8).
    width_al: u32 = 0,
    height_al: u32 = 0,
    columns: u32 = 0,
    /// A column's bytes - its rows of brightness, then of colour pairs,
    /// 128 bytes each - and where its colour starts; the frame's bytes.
    pitch: u32 = 0,
    chroma: u32 = 0,
    bytes: u32 = 0,
    /// The motion vectors' bytes a row, and a frame's.
    mv_stride: u32 = 0,
    mv_bytes: u32 = 0,
    /// The two buffers between the phases, at first.
    pu_bytes: u32 = 0,
    coeff_bytes: u32 = 0,

    pub fn of(width: u32, height: u32, ten: bool) Layout {
        const width_al = if (ten) (width + 2) / 3 + 31 & ~@as(u32, 31) else width + 127 & ~@as(u32, 127);
        const samples = if (ten) width_al * 3 else width_al;
        const height_al = height + 7 & ~@as(u32, 7);
        const pitch = height_al * 3 / 2 * 128;
        const columns = if (ten) samples / 96 else samples / 128;
        const mv_stride = width + 63 & ~@as(u32, 63);
        return .{
            .width = width,
            .height = height,
            .ten = ten,
            .width_al = samples,
            .height_al = height_al,
            .columns = columns,
            .pitch = pitch,
            .chroma = height_al * 128,
            .bytes = columns * pitch,
            .mv_stride = mv_stride,
            .mv_bytes = mv_stride * ((height + 63 & ~@as(u32, 63)) >> 4),
            .pu_bytes = roundUpSize(samples * height_al / 4),
            .coeff_bytes = roundUpSize(samples * height_al),
        };
    }

    pub fn same(a: Layout, b: Layout) bool {
        return a.width == b.width and a.height == b.height and a.ten == b.ten;
    }
};

/// A buffer's first size: 3 << ilog2(n), at least 768 - between 1.5 and 3
/// times `n`. The next larger is twice it.
pub fn roundUpSize(n: u32) u32 {
    const log: u5 = if (n < 256) 8 else @intCast(31 - @clz(n));
    return @as(u32, 3) << log;
}

/// Bytes a row of CTBs of a buffer of `bytes`, for a picture `rows` CTBs
/// high, on a 64-byte boundary.
pub fn rowStride(bytes: u32, rows: u32) u32 {
    return bytes / rows & ~@as(u32, 63);
}

/// A frame of `layout` grey, as the block lays it out.
pub fn grey(frame: [*]u8, layout: Layout) void {
    const words: [*]u32 = @ptrCast(@alignCast(frame));
    const value: u32 = if (layout.ten) 512 | 512 << 10 | 512 << 20 else 0x8080_8080;
    @memset(words[0 .. layout.bytes / 4], value);
}

/// The frame `sand` of `layout` copied out as NV12 of 8 bits: its rows of
/// brightness from `y`, its rows of colour pairs from `cbcr`, each
/// `pitch` bytes apart - at least `layout.width_al`. Ten bits are rounded
/// to eight.
pub fn copyOut(sand: [*]const u8, layout: Layout, y: [*]u8, cbcr: [*]u8, pitch: usize) void {
    const rows = layout.height;
    for (0..layout.columns) |c| {
        const column = sand + c * layout.pitch;
        if (layout.ten) {
            const left = c * 96;
            for (0..rows) |r| eight(column + r * 128, y + r * pitch + left);
            for (0..rows / 2) |r| eight(column + layout.chroma + r * 128, cbcr + r * pitch + left);
        } else {
            const left = c * 128;
            for (0..rows) |r| @memcpy((y + r * pitch + left)[0..128], (column + r * 128)[0..128]);
            for (0..rows / 2) |r| @memcpy((cbcr + r * pitch + left)[0..128], (column + layout.chroma + r * 128)[0..128]);
        }
    }
}

/// A 128-byte line of 10-bit samples, three to a word, rounded into 96
/// bytes.
fn eight(line: [*]const u8, into: [*]u8) void {
    const words: [*]const u32 = @ptrCast(@alignCast(line));
    for (0..32) |i| {
        const w = words[i];
        inline for (0..3) |k| {
            const sample = w >> (10 * k) & 0x3FF;
            into[3 * i + k] = @intCast(@min(255, (sample + 2) >> 2));
        }
    }
}

// --- a picture's commands ------------------------------------------------------------

/// A command: a register of the block and the value written into it.
pub const Command = extern struct { addr: u32, data: u32 };

/// A picture's command list, in memory the session owns: `room`
/// commands, `len` of them put down.
pub const Commands = struct {
    list: [*]Command,
    room: u32,
    len: u32 = 0,

    fn put(c: *Commands, addr: u32, data: u32) void {
        // The session makes room for a segment before it is put down.
        std.debug.assert(c.len < c.room);
        c.list[c.len] = .{ .addr = addr, .data = data };
        c.len += 1;
    }

    /// Where the slice data put down at `entry` (`Program.segment`) is.
    pub fn place(c: *Commands, entry: u32, address: usize) void {
        const low: u32 = @intCast(address & 63);
        c.list[entry].data = a64(address);
        c.list[entry + 2].data = low | 0x80;
        c.list[entry + 3].data = low | 0x40;
    }
};

/// A reference as a slice's messages name it: its frame's slot (0 to
/// 15), whether it is a long-term one, its order count.
pub const Ref = struct { slot: u8 = 0, long_term: bool = false, poc: i32 = 0 };

/// The most messages a slice segment has: itself, eight for each of 16
/// references in each list (with weights), deblocking and QP offsets.
pub const max_messages = 2 * 16 * 8 + 3;

/// The size of the scaling factors' table.
pub const scaling_bytes = 4064;

/// The most commands a segment and the end of its picture take, for a
/// picture of `p`'s: its own, and filling up the tiles or rows after the
/// segment before it.
pub fn segmentRoom(p: *const Program) u32 {
    return 4 + 40 + 1 + max_messages + 3 + scaling_bytes / 4 + 1 + 7 + 6 +
        13 * p.h + 8 * p.cols * p.rows;
}

const max_cols = hevc.max_tile_columns;
const max_rows = hevc.max_tile_rows;

const Ctb = struct { x: u32, y: u32 };

/// The run of decoding put down last: its tile, its first CTB, and its
/// slice's QP and constants - the tiles or rows after it filled with them.
const Entry = struct {
    tx: u32 = 0,
    ty: u32 = 0,
    cx: u32 = 0,
    cy: u32 = 0,
    qp: u32 = 0,
    sconst: u32 = 0,
};

/// A picture as its commands are put down, segment by segment.
pub const Program = struct {
    sps: *const hevc.HevcSps = undefined,
    pps: *const hevc.HevcPps = undefined,
    /// PicWidthInCtbsY and PicHeightInCtbsY.
    w: u32 = 0,
    h: u32 = 0,
    /// Tiles (one, without), and their bounds in CTBs: colBd and rowBd.
    cols: u32 = 1,
    rows: u32 = 1,
    col_bd: [max_cols + 1]u32 = undefined,
    row_bd: [max_rows + 1]u32 = undefined,
    wpp: bool = false,
    /// The scaling factors, put down with the first segment.
    table: [scaling_bytes]u8 = undefined,
    /// Segments put down; the first's slice_temporal_mvp_enabled_flag,
    /// the picture's; SLICESTART of the slice being put down.
    segments: u32 = 0,
    temporal_mvp: bool = false,
    slicestart: u32 = 0,
    e: Entry = .{},

    /// Whether the block takes a picture of these parameter sets: 4:2:0
    /// of 8 or 10 bits alike, Main's tools, no larger than 4096 x 4096,
    /// not wavefront decoding over more than one tile.
    pub fn takes(sps: *const hevc.HevcSps, pps: *const hevc.HevcPps) bool {
        const depth = sps.bit_depth_luma;
        if (sps.chroma_format_idc != 1 or sps.separate_colour_plane or depth != sps.bit_depth_chroma) return false;
        if (depth != 8 and depth != 10) return false;
        if (sps.width == 0 or sps.height == 0 or sps.width > most_width or sps.height > most_height) return false;
        if (sps.log2_ctb > 6 or sps.log2_max_tb > 5) return false;
        if (sps.transform_skip_rotation or sps.transform_skip_context or sps.implicit_rdpcm or sps.explicit_rdpcm or
            sps.extended_precision or sps.intra_smoothing_disabled or sps.high_precision_offsets or sps.persistent_rice or
            sps.cabac_bypass_alignment) return false;
        if (pps.cross_component_prediction or pps.chroma_qp_offset_list_enabled or pps.log2_max_transform_skip_size != 2) return false;
        if (pps.tiles and pps.entropy_coding_sync and pps.num_tile_columns * pps.num_tile_rows > 1) return false;
        return true;
    }

    /// A picture begun: its sizes in CTBs, its tiles' bounds - the uniform
    /// ones worked out (6-3, 6-4) - and its scaling factors.
    pub fn begin(p: *Program, sps: *const hevc.HevcSps, pps: *const hevc.HevcPps) void {
        p.sps = sps;
        p.pps = pps;
        p.w = sps.widthCtbs();
        p.h = sps.heightCtbs();
        p.wpp = pps.entropy_coding_sync;
        p.cols = if (pps.tiles) pps.num_tile_columns else 1;
        p.rows = if (pps.tiles) pps.num_tile_rows else 1;
        bounds(&p.col_bd, p.cols, p.w, pps.uniform_spacing, &pps.column_width);
        bounds(&p.row_bd, p.rows, p.h, pps.uniform_spacing, &pps.row_height);
        if (sps.scaling_enabled) scalingTable(&p.table, if (pps.scaling_present) &pps.scaling else &sps.scaling);
        p.segments = 0;
        p.temporal_mvp = false;
        p.slicestart = 0;
        p.e = .{};
    }

    fn tileX(p: *const Program, x: u32) u32 {
        var t: u32 = 0;
        while (t + 1 < p.cols and x >= p.col_bd[t + 1]) t += 1;
        return t;
    }

    fn tileY(p: *const Program, y: u32) u32 {
        var t: u32 = 0;
        while (t + 1 < p.rows and y >= p.row_bd[t + 1]) t += 1;
        return t;
    }

    /// The CTB before (x, y) in the tile scan: the one left of it in its
    /// tile, the end of the row above in its tile, or the last of the
    /// tile before.
    fn before(p: *const Program, x: u32, y: u32) Ctb {
        const tx = p.tileX(x);
        const ty = p.tileY(y);
        if (x > p.col_bd[tx]) return .{ .x = x - 1, .y = y };
        if (y > p.row_bd[ty]) return .{ .x = p.col_bd[tx + 1] - 1, .y = y - 1 };
        if (tx > 0) return .{ .x = p.col_bd[tx] - 1, .y = p.row_bd[ty + 1] - 1 };
        if (ty > 0) return .{ .x = p.w - 1, .y = p.row_bd[ty] - 1 };
        return .{ .x = 0, .y = 0 };
    }

    /// A slice segment put down: `bytes` of slice data (placed later,
    /// `Commands.place`, at the command this answers) and its messages
    /// (`said`).
    /// A picture's first segment is independent and at CTB 0.
    pub fn segment(p: *Program, c: *Commands, hdr: *const hevc.HevcSliceHeader, said: []const u16, bytes: u32) u32 {
        const address = hdr.segment_address;
        const x = address % p.w;
        const y = address / p.w;
        const prev = if (address != 0) p.before(x, y) else Ctb{ .x = 0, .y = 0 };
        if (p.segments == 0) p.temporal_mvp = hdr.temporal_mvp;
        const independent = !hdr.dependent;
        const sconst = sliceConstants(hdr);
        const qp: u32 = @bitCast(hdr.qp);
        // Where the slice data's commands go: after the fill of the tiles
        // or rows before.
        var entry: u32 = undefined;
        if (p.wpp) {
            if (address != 0) p.wppEndPrevious(c, prev, x, y);
            entry = c.len;
            bitstream(c, bytes);
            var reset_qp = true;
            if (address == 0 or independent or p.w == 1) {
                prob(c, hdr);
            } else if (x == 0) {
                c.put(TRANSFER, PROB_RELOAD);
            } else reset_qp = false;
            p.sliceSegment(c, hdr, said, address == 0);
            p.entryPoint(c, independent, reset_qp, PAUSE_WPP, 0, 0, x, y, qp, sconst);
        } else {
            const tx = p.tileX(x);
            const ty = p.tileY(y);
            if (address != 0) {
                p.tileFill(c, p.tileX(prev.x), p.tileY(prev.y));
                c.put(STATUS, 1 | prev.x << 5 | prev.y << 18);
            }
            entry = c.len;
            bitstream(c, bytes);
            const reset_qp = address == 0 or independent or tx != p.tileX(prev.x) or ty != p.tileY(prev.y);
            if (reset_qp) prob(c, hdr);
            p.sliceSegment(c, hdr, said, address == 0);
            p.entryPoint(c, independent, reset_qp, PAUSE_TILE, tx, ty, x, y, qp, sconst);
        }
        p.segments += 1;
        return entry;
    }

    /// The picture's last segment put down: the tiles or rows after it
    /// filled, and the end.
    pub fn finish(p: *Program, c: *Commands) void {
        if (p.wpp) {
            p.wppFill(c, p.h - 1);
            if (p.e.cx < 2 and p.w > 2) p.wppPause(c, p.h - 1);
        } else p.tileFill(c, p.cols - 1, p.rows - 1);
        c.put(STATUS, 1 | (p.w - 1) << 5 | (p.h - 1) << 18);
    }

    /// SLICECMDS and the messages, the sequence's and picture's
    /// registers, the scaling factors with the picture's first segment,
    /// and SLICESTART.
    fn sliceSegment(p: *Program, c: *Commands, hdr: *const hevc.HevcSliceHeader, said: []const u16, first: bool) void {
        const sps = p.sps;
        const pps = p.pps;
        c.put(SLICECMDS, @as(u32, @intCast(said.len)) | p.segments << 8);
        for (said, 0..) |m, i| c.put(MESSAGES + 4 * @as(u32, @intCast(i)), m);
        c.put(SPS0, @as(u32, sps.log2_min_cb) | @as(u32, sps.log2_ctb) << 4 | @as(u32, sps.log2_min_tb) << 8 |
            @as(u32, sps.log2_max_tb) << 12 | @as(u32, sps.bit_depth_luma) << 16 | @as(u32, sps.bit_depth_chroma) << 20 |
            @as(u32, sps.max_th_depth_intra) << 24 | @as(u32, sps.max_th_depth_inter) << 28);
        c.put(SPS1, @as(u32, sps.pcm_depth_luma) | @as(u32, sps.pcm_depth_chroma) << 4 | @as(u32, sps.log2_min_pcm) << 8 |
            @as(u32, sps.log2_max_pcm) << 12 | @as(u32, sps.chromaArrayType()) << 16 | flag(sps.amp, 18) | flag(sps.pcm, 19) |
            flag(sps.scaling_enabled, 20) | flag(sps.strong_intra_smoothing, 21));
        const cb: u32 = @as(u8, @bitCast(pps.cb_qp_offset +% hdr.cb_qp_offset));
        const cr: u32 = @as(u8, @bitCast(pps.cr_qp_offset +% hdr.cr_qp_offset));
        c.put(PPS, (@as(u32, sps.log2_ctb) - pps.diff_cu_qp_delta_depth) | flag(pps.cu_qp_delta_enabled, 4) |
            flag(pps.transquant_bypass, 5) | flag(pps.transform_skip, 6) | flag(pps.sign_data_hiding, 7) |
            cb << 8 | cr << 16 | flag(pps.constrained_intra_pred, 24));
        if (first and sps.scaling_enabled) {
            var i: u32 = 0;
            while (i < scaling_bytes) : (i += 4) c.put(SCALING + i, std.mem.readInt(u32, p.table[i..][0..4], .little));
        }
        if (!hdr.dependent) p.slicestart = hdr.segment_address % p.w | (hdr.segment_address / p.w) << 16;
        c.put(SLICESTART, p.slicestart);
    }

    /// A run of decoding: from CTB (cx, cy) to the end of tile (tx, ty) -
    /// of row cy under wavefront decoding.
    fn entryPoint(p: *Program, c: *Commands, bte: bool, reset_qp: bool, pause: u32, tx: u32, ty: u32, cx: u32, cy: u32, qp: u32, sconst: u32) void {
        const end_x = p.col_bd[tx + 1] - 1;
        const end_y = if (pause == PAUSE_WPP) cy else p.row_bd[ty + 1] - 1;
        c.put(TILESTART, p.col_bd[tx] | p.row_bd[ty] << 16);
        c.put(TILEEND, end_x | end_y << 16);
        if (bte) c.put(BEGINTILEEND, end_x | end_y << 16);
        c.put(SLICE, sconst | p.lastWidth(end_x) << 17 | p.lastHeight(end_y) << 24);
        if (reset_qp) c.put(QP, 6 * (@as(u32, p.sps.bit_depth_luma) - 8) +% qp);
        c.put(MODE, pause | flag(end_x == p.w - 1, 17) | flag(end_y == p.h - 1, 18));
        c.put(CONTROL, cx | cy << 16);
        p.e = .{ .tx = tx, .ty = ty, .cx = cx, .cy = cy, .qp = qp, .sconst = sconst };
    }

    /// The luma width of the CTBs of column `x`, and height of row `y`.
    fn lastWidth(p: *const Program, x: u32) u32 {
        const size = p.sps.ctbSize();
        const part = p.sps.width & (size - 1);
        return if (x + 1 < p.w or part == 0) size else part;
    }

    fn lastHeight(p: *const Program, y: u32) u32 {
        const size = p.sps.ctbSize();
        const part = p.sps.height & (size - 1);
        return if (y + 1 < p.h or part == 0) size else part;
    }

    // Wavefront decoding: one tile, each row of CTBs a run.

    fn wppPause(p: *const Program, c: *Commands, row: u32) void {
        c.put(STATUS, row << 18 | 0x25);
        c.put(TRANSFER, PROB_BACKUP);
        c.put(MODE, if (row == p.h - 1) 0x7_0000 else 0x3_0000);
        c.put(CONTROL, (row << 16) + 2);
    }

    fn wppFill(p: *Program, c: *Commands, last_y: u32) void {
        while (p.e.cy < last_y) {
            if (p.w > 2) p.wppPause(c, p.e.cy);
            c.put(STATUS, p.e.cy << 18 | (p.w - 1) << 5 | 2);
            // A picture one CTB wide keeps the first state throughout.
            c.put(TRANSFER, if (p.w == 2) PROB_BACKUP else PROB_RELOAD);
            p.entryPoint(c, false, true, PAUSE_WPP, 0, 0, 0, p.e.cy + 1, p.e.qp, p.e.sconst);
        }
    }

    fn wppEndPrevious(p: *Program, c: *Commands, prev: Ctb, x: u32, y: u32) void {
        p.wppFill(c, prev.y);
        if (p.e.cx < 2 and (p.e.cy < y or x > 2) and p.w > 2) p.wppPause(c, prev.y);
        c.put(STATUS, 1 | prev.x << 5 | prev.y << 18);
        if (x == 2 or (p.w == 2 and p.e.cy < y)) c.put(TRANSFER, PROB_BACKUP);
    }

    // Tiles: each tile a run.

    fn tileFill(p: *Program, c: *Commands, last_tx: u32, last_ty: u32) void {
        while (p.e.ty < last_ty or (p.e.ty == last_ty and p.e.tx < last_tx)) {
            var tx = p.e.tx;
            var ty = p.e.ty;
            c.put(STATUS, 2 | (p.col_bd[tx + 1] - 1) << 5 | (p.row_bd[ty + 1] - 1) << 18);
            c.put(TRANSFER, PROB_RELOAD);
            tx += 1;
            if (tx >= p.cols) {
                tx = 0;
                ty += 1;
            }
            p.entryPoint(c, false, true, PAUSE_TILE, tx, ty, p.col_bd[tx], p.row_bd[ty], p.e.qp, p.e.sconst);
        }
    }

    /// CONFIG2, phase 2's picture constants, with the motion vectors
    /// written for later pictures (`keep_mvs`) or not.
    pub fn config2(p: *const Program, keep_mvs: bool) u32 {
        const sps = p.sps;
        const pps = p.pps;
        return @as(u32, sps.bit_depth_luma) | @as(u32, sps.bit_depth_chroma) << 4 | flag(sps.bit_depth_luma > 8, 8) |
            flag(sps.bit_depth_chroma > 8, 9) | @as(u32, sps.log2_ctb) << 10 | flag(pps.constrained_intra_pred, 13) |
            flag(sps.strong_intra_smoothing, 14) | flag(keep_mvs, 15) | @as(u32, pps.log2_parallel_merge_level) << 16 |
            flag(p.temporal_mvp, 19) | flag(sps.pcm_loop_filter_disabled, 20) |
            (@as(u32, @as(u8, @bitCast(pps.cb_qp_offset))) & 31) << 21 | (@as(u32, @as(u8, @bitCast(pps.cr_qp_offset))) & 31) << 26;
    }

    pub fn framesize(p: *const Program) u32 {
        return p.sps.height << 16 | p.sps.width;
    }
};

fn flag(set: bool, bit: u5) u32 {
    return @as(u32, @intFromBool(set)) << bit;
}

/// Tile bounds in CTBs: `count` tiles across `size`, as wide as `given`
/// says but the last - or as near the same as they divide (6-3, 6-4).
fn bounds(into: []u32, count: u32, size: u32, uniform: bool, given: []const u16) void {
    into[0] = 0;
    for (0..count) |i| {
        const width = if (uniform)
            (@as(u32, @intCast(i)) + 1) * size / count - @as(u32, @intCast(i)) * size / count
        else if (i + 1 < count) given[i] else size - into[i];
        into[i + 1] = into[i] + width;
    }
    into[count] = size;
}

/// The slice data's commands, its place filled in later.
fn bitstream(c: *Commands, bytes: u32) void {
    c.put(BFBASE, 0);
    c.put(BFNUM, bytes);
    c.put(BFCONTROL, 0x80);
    c.put(BFCONTROL, 0x40);
}

/// The slice's reference counts in its two lists.
fn refCounts(h: *const hevc.HevcSliceHeader) [2]u32 {
    return switch (h.slice_type) {
        .i => .{ 0, 0 },
        .p => .{ h.num_ref_idx[0], 0 },
        .b => .{ h.num_ref_idx[0], h.num_ref_idx[1] },
    };
}

fn mergeCandidates(h: *const hevc.HevcSliceHeader) u32 {
    return if (h.slice_type == .i) 0 else h.max_num_merge_cand;
}

/// SLICE's part that stays from run to run: the slice's merge
/// candidates, reference counts, type, SAO, mvd_l1_zero_flag.
fn sliceConstants(h: *const hevc.HevcSliceHeader) u32 {
    const n = refCounts(h);
    return mergeCandidates(h) | n[0] << 4 | n[1] << 8 | @as(u32, @intFromEnum(h.slice_type)) << 12 |
        flag(h.sao_luma, 14) | flag(h.sao_chroma, 15) | flag(h.slice_type == .b and h.mvd_l1_zero, 16);
}

/// A slice segment's messages into `into`, how many: the slice - its
/// type, reference counts, whether every reference is before it (8.3.5's
/// NoBackwardPredFlag), merge candidates, collocated list - each
/// reference of its lists as `refs` names them, with their weights, then
/// deblocking and its QP offsets. `poc` is the picture's order count,
/// `temporal_mvp` the picture's slice_temporal_mvp_enabled_flag.
pub fn messages(into: *[max_messages]u16, h: *const hevc.HevcSliceHeader, pps: *const hevc.HevcPps, refs: *const [2][ref_slots]Ref, poc: i32, temporal_mvp: bool) usize {
    var n: usize = 0;
    const counts = refCounts(h);
    const kind: u32 = switch (h.slice_type) {
        .i => 1,
        .p => 2,
        .b => 3,
    };
    const from_l0 = !temporal_mvp or h.slice_type != .b or h.collocated_from_l0;
    var slice = kind | counts[0] << 2 | counts[1] << 6 | mergeCandidates(h) << 11 | flag(from_l0, 14);
    if (h.slice_type != .i) {
        var behind = true;
        for (0..2) |l| for (refs[l][0..counts[l]]) |r| {
            if (poc < r.poc) behind = false;
        };
        slice |= flag(behind, 10);
    }
    into[n] = @intCast(slice);
    n += 1;
    const weighted = h.weighted;
    const w = &h.weights;
    for (0..2) |l| for (0..counts[l]) |i| {
        const r = refs[l][i];
        into[n] = @intCast(r.slot | flag(r.long_term, 4) | if (weighted) @as(u32, 3 << 5) else 0);
        into[n + 1] = @truncate(@as(u32, @bitCast(r.poc)));
        n += 2;
        if (!weighted) continue;
        into[n] = @intCast(w.luma_log2_denom | (@as(u32, @bitCast(@as(i32, w.luma_weight[l][i]))) & 0x1FF) << 3);
        into[n + 1] = @intCast(@as(u32, @bitCast(@as(i32, w.luma_offset[l][i]))) & 0xFF);
        n += 2;
        for (0..2) |k| {
            into[n] = @intCast(w.chroma_log2_denom | (@as(u32, @bitCast(@as(i32, w.chroma_weight[l][i][k]))) & 0x1FF) << 3);
            into[n + 1] = @intCast(@as(u32, @bitCast(@as(i32, w.chroma_offset[l][i][k]))) & 0xFF);
            n += 2;
        }
    };
    const beta: u32 = @as(u8, @bitCast(h.beta_offset >> 1));
    const tc: u32 = @as(u8, @bitCast(h.tc_offset >> 1));
    into[n] = @intCast(beta & 15 | (tc & 15) << 4 | flag(h.deblocking_disabled, 8) |
        flag(h.loop_filter_across_slices, 9) | flag(pps.loop_filter_across_tiles, 10));
    const cb: u32 = @as(u8, @bitCast(h.cb_qp_offset));
    const cr: u32 = @as(u8, @bitCast(h.cr_qp_offset));
    into[n + 1] = @intCast((cr & 31) << 5 | cb & 31);
    return n + 2;
}

// --- contexts and scaling ------------------------------------------------------------------

/// The contexts' first states for the slice (9.3.2.2), in the block's
/// order, put into PROB, then kept (TRANSFER).
fn prob(c: *Commands, h: *const hevc.HevcSliceHeader) void {
    var states: [prob_bytes]u8 = undefined;
    probStates(&states, h.initType(), h.qp);
    var i: u32 = 0;
    while (i < prob_bytes) : (i += 4) c.put(PROB + i, std.mem.readInt(u32, states[i..][0..4], .little));
    c.put(TRANSFER, PROB_BACKUP);
}

const prob_count = 154;
const prob_bytes = 156;

/// Each context's state as (pStateIdx << 1) | valMps, from its initValue
/// for `init_type` at SliceQpY `qp` (9-6).
fn probStates(into: *[prob_bytes]u8, init_type: u2, qp: i32) void {
    const q = std.math.clamp(qp, 0, 51);
    for (0..prob_count) |i| {
        const value: i32 = prob_init[init_type][i];
        const m = (value >> 4) * 5 - 45;
        const n = ((value & 15) << 3) - 16;
        var pre = 2 * (((m * q) >> 4) + n) - 127;
        pre ^= pre >> 31;
        if (pre > 124) pre = 124 + (pre & 1);
        into[i] = @intCast(pre);
    }
    into[154] = 0;
    into[155] = 0;
}

/// The contexts' initValues (Tables 9-5 to 9-37) by initType, in the
/// order the block keeps them.
const prob_init = [3][prob_count]u8{
    .{
        153, 200, 139, 141, 157, 154, 154, 154, 154, 154, 184, 154, 154,
        154, 184, 63,  154, 154, 154, 154, 154, 154, 154, 154, 154, 154,
        154, 154, 154, 153, 138, 138, 111, 141, 94,  138, 182, 154, 154,
        154, 140, 92,  137, 138, 140, 152, 138, 139, 153, 74,  149, 92,
        139, 107, 122, 152, 140, 179, 166, 182, 140, 227, 122, 197, 110,
        110, 124, 125, 140, 153, 125, 127, 140, 109, 111, 143, 127, 111,
        79,  108, 123, 63,  110, 110, 124, 125, 140, 153, 125, 127, 140,
        109, 111, 143, 127, 111, 79,  108, 123, 63,  91,  171, 134, 141,
        138, 153, 136, 167, 152, 152, 139, 139, 111, 111, 125, 110, 110,
        94,  124, 108, 124, 107, 125, 141, 179, 153, 125, 107, 125, 141,
        179, 153, 125, 107, 125, 141, 179, 153, 125, 140, 139, 182, 182,
        152, 136, 152, 136, 153, 136, 139, 111, 136, 139, 111,
    },
    .{
        153, 185, 107, 139, 126, 197, 185, 201, 154, 149, 154, 139, 154,
        154, 154, 152, 110, 122, 95,  79,  63,  31,  31,  153, 153, 168,
        140, 198, 79,  124, 138, 94,  153, 111, 149, 107, 167, 154, 154,
        154, 154, 196, 196, 167, 154, 152, 167, 182, 182, 134, 149, 136,
        153, 121, 136, 137, 169, 194, 166, 167, 154, 167, 137, 182, 125,
        110, 94,  110, 95,  79,  125, 111, 110, 78,  110, 111, 111, 95,
        94,  108, 123, 108, 125, 110, 94,  110, 95,  79,  125, 111, 110,
        78,  110, 111, 111, 95,  94,  108, 123, 108, 121, 140, 61,  154,
        107, 167, 91,  122, 107, 167, 139, 139, 155, 154, 139, 153, 139,
        123, 123, 63,  153, 166, 183, 140, 136, 153, 154, 166, 183, 140,
        136, 153, 154, 166, 183, 140, 136, 153, 154, 170, 153, 123, 123,
        107, 121, 107, 121, 167, 151, 183, 140, 151, 183, 140,
    },
    .{
        153, 160, 107, 139, 126, 197, 185, 201, 154, 134, 154, 139, 154,
        154, 183, 152, 154, 137, 95,  79,  63,  31,  31,  153, 153, 168,
        169, 198, 79,  224, 167, 122, 153, 111, 149, 92,  167, 154, 154,
        154, 154, 196, 167, 167, 154, 152, 167, 182, 182, 134, 149, 136,
        153, 121, 136, 122, 169, 208, 166, 167, 154, 152, 167, 182, 125,
        110, 124, 110, 95,  94,  125, 111, 111, 79,  125, 126, 111, 111,
        79,  108, 123, 93,  125, 110, 124, 110, 95,  94,  125, 111, 111,
        79,  125, 126, 111, 111, 79,  108, 123, 93,  121, 140, 61,  154,
        107, 167, 91,  107, 107, 167, 139, 139, 170, 154, 139, 153, 139,
        123, 123, 63,  124, 166, 183, 140, 136, 153, 154, 166, 183, 140,
        136, 153, 154, 166, 183, 140, 136, 153, 154, 170, 153, 138, 138,
        122, 121, 122, 121, 167, 151, 183, 140, 151, 183, 140,
    },
};

/// Where the i-th coefficient of an n x n list lies, coded in up-right
/// diagonal order (6.5.3), in raster order: y * n + x.
fn diagonal(comptime n: usize) [n * n]u8 {
    var out: [n * n]u8 = undefined;
    var i: usize = 0;
    var x: isize = 0;
    var y: isize = 0;
    while (i < n * n) {
        while (y >= 0) {
            if (x < n and y < n) {
                out[i] = @intCast(y * n + x);
                i += 1;
            }
            y -= 1;
            x += 1;
        }
        y = x;
        x = 0;
    }
    return out;
}

const diag4 = diagonal(4);
const diag8 = diagonal(8);

/// The scaling factors the block reads, from a set's lists: the 4x4 and
/// 8x8 ones of each of the six matrices as they are, the 16x16 ones from
/// their 8x8 lists each value twice across and down, the two 32x32 ones
/// (intra and inter luma) four times - all in raster order, with the DC
/// in the first place.
fn scalingTable(into: *[scaling_bytes]u8, l: *const hevc.HevcScaling) void {
    var grid: [64]u8 = undefined;
    for (0..6) |m| {
        for (0..16) |i| into[0x10 * m + diag4[i]] = l.coef[0][m][i];
        for (0..64) |i| into[0x60 + 0x40 * m + @as(usize, diag8[i])] = l.coef[1][m][i];
        for (0..64) |i| grid[diag8[i]] = l.coef[2][m][i];
        const base = 0x1E0 + 0x100 * m;
        for (0..16) |y| for (0..16) |x| {
            into[base + 16 * y + x] = grid[8 * (y >> 1) + (x >> 1)];
        };
        into[base] = l.dc[0][m];
    }
    for ([_]usize{ 0, 3 }, 0..) |m, k| {
        for (0..64) |i| grid[diag8[i]] = l.coef[3][m][i];
        const base = 0x7E0 + 0x400 * k;
        for (0..32) |y| for (0..32) |x| {
            into[base + 32 * y + x] = grid[8 * (y >> 2) + (x >> 2)];
        };
        into[base] = l.dc[1][m];
    }
}

// --- tests (host: ./zig build test) -----------------------------------------------------

const testing = std.testing;

test "the first sizes of the buffers between the phases, as the Linux driver's" {
    try testing.expectEqual(@as(u32, 0x30_0000), roundUpSize(1920 * 1080));
    try testing.expectEqual(@as(u32, 0xC_0000), roundUpSize(1920 * 1080 / 4));
    try testing.expectEqual(@as(u32, 0x18_0000), roundUpSize(1280 * 720));
    try testing.expectEqual(@as(u32, 0xC0_0000), roundUpSize(3840 * 2160));
    try testing.expectEqual(@as(u32, 768), roundUpSize(10));
    try testing.expectEqual(@as(u32, 2891), rowStride(0x30_0000, 17) >> 6);
    try testing.expectEqual(@as(u32, 722), rowStride(0xC_0000, 17) >> 6);
}

test "frames of 128-byte columns: 1080p of 8 bits, 4K of 10" {
    const hd = Layout.of(1920, 1080, false);
    try testing.expectEqual(@as(u32, 15), hd.columns);
    try testing.expectEqual(@as(u32, 207360), hd.pitch);
    try testing.expectEqual(@as(u32, 138240), hd.chroma);
    try testing.expectEqual(@as(u32, 3110400), hd.bytes);
    try testing.expectEqual(@as(u32, 1920), hd.mv_stride);
    try testing.expectEqual(@as(u32, 130560), hd.mv_bytes);
    const uhd = Layout.of(3840, 2160, true);
    try testing.expectEqual(@as(u32, 40), uhd.columns);
    try testing.expectEqual(@as(u32, 3840), uhd.width_al);
    try testing.expectEqual(@as(u32, 414720), uhd.pitch);
    try testing.expectEqual(@as(u32, 276480), uhd.chroma);
    try testing.expectEqual(@as(u32, 16588800), uhd.bytes);
}

test "a context's first state is (pStateIdx << 1) | valMps" {
    var states: [prob_bytes]u8 = undefined;
    for ([_]i32{ -5, 0, 22, 37, 51, 60 }) |qp| {
        for (0..3) |t| {
            probStates(&states, @intCast(t), qp);
            const q = std.math.clamp(qp, 0, 51);
            for (0..prob_count) |i| {
                const value: i32 = prob_init[t][i];
                const slope = (value >> 4) * 5 - 45;
                const offset = ((value & 15) << 3) - 16;
                const pre = std.math.clamp(((slope * q) >> 4) + offset, 1, 126);
                const mps: u8 = @intFromBool(pre > 63);
                const state: u8 = @intCast(if (mps == 1) pre - 64 else 63 - pre);
                try testing.expectEqual(state << 1 | mps, states[i]);
            }
        }
    }
}

test "the diagonal scans" {
    try testing.expectEqual([_]u8{ 0, 4, 1, 8, 5, 2, 12, 9, 6, 3, 13, 10, 7, 14, 11, 15 }, diag4);
    try testing.expectEqual(@as(u8, 63), diag8[63]);
    try testing.expectEqual(@as(u8, 8), diag8[1]);
}

test "the scaling factors: the default lists, laid out as the block reads them" {
    const lists = hevc.HevcScaling.default();
    var table: [scaling_bytes]u8 = undefined;
    scalingTable(&table, &lists);
    try testing.expectEqual(@as(u8, 16), table[0]);
    // The 8x8 intra list's last coefficient is its bottom right, 115.
    try testing.expectEqual(@as(u8, 115), table[0x60 + 63]);
    // 16x16 intra: DC 16, the bottom right is the 8x8's, 115.
    try testing.expectEqual(@as(u8, 16), table[0x1E0]);
    try testing.expectEqual(@as(u8, 115), table[0x1E0 + 255]);
    // 32x32 inter: the default inter list's last, 91.
    try testing.expectEqual(@as(u8, 91), table[0x7E0 + 0x400 + 1023]);
}

/// A program over room for `n` commands, for the tests.
fn testCommands(comptime n: usize, room: *[n]Command) Commands {
    return .{ .list = room, .room = n };
}

/// The value of the last command to `addr` among `list`.
fn lastTo(list: []const Command, addr: u32) ?u32 {
    var i = list.len;
    while (i > 0) {
        i -= 1;
        if (list[i].addr == addr) return list[i].data;
    }
    return null;
}

fn countTo(list: []const Command, addr: u32) usize {
    var n: usize = 0;
    for (list) |cmd| n += @intFromBool(cmd.addr == addr);
    return n;
}

test "a 1080p picture of one I slice: 60 commands, as the Linux driver puts them" {
    var sps: hevc.HevcSps = .{ .width = 1920, .height = 1080, .log2_ctb = 6, .log2_min_cb = 3, .sao = true };
    var pps: hevc.HevcPps = .{};
    var p: Program = .{};
    try testing.expect(Program.takes(&sps, &pps));
    p.begin(&sps, &pps);
    try testing.expectEqual(@as(u32, 30), p.w);
    try testing.expectEqual(@as(u32, 17), p.h);
    var room: [2000]Command = undefined;
    var c = testCommands(2000, &room);
    const h: hevc.HevcSliceHeader = .{ .first_slice_in_pic = true, .slice_type = .i, .sao_luma = true, .sao_chroma = true, .qp = 30 };
    var msgs: [max_messages]u16 = undefined;
    const refs: [2][ref_slots]Ref = @splat(@splat(.{}));
    const n = messages(&msgs, &h, &pps, &refs, 0, false);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u16, 0x4001), msgs[0]);
    const entry = p.segment(&c, &h, msgs[0..n], 1000);
    try testing.expectEqual(@as(u32, 0), entry);
    p.finish(&c);
    const list = c.list[0..c.len];
    try testing.expectEqual(@as(u32, 60), c.len);
    try testing.expectEqual(@as(?u32, 0x3880_E000), lastTo(list, SLICE));
    try testing.expectEqual(@as(?u32, 0x0010_001D), lastTo(list, TILEEND));
    try testing.expectEqual(@as(?u32, 0x0010_001D), lastTo(list, BEGINTILEEND));
    try testing.expectEqual(@as(?u32, 0x6_FFFF), lastTo(list, MODE));
    try testing.expectEqual(@as(?u32, 30), lastTo(list, QP));
    try testing.expectEqual(@as(u32, 0x0040_03A1), list[59].data);
    try testing.expectEqual(STATUS, list[59].addr);
    c.place(entry, 0x1234_5678);
    try testing.expectEqual(@as(u32, 0x1234_5678 >> 6), list[0].data);
    try testing.expectEqual(@as(u32, 0x38 | 0x80), list[2].data);
    try testing.expectEqual(@as(u32, 0x38 | 0x40), list[3].data);
}

test "a picture of wavefront rows: 88 commands, each row paused after its second CTB" {
    var sps: hevc.HevcSps = .{ .width = 256, .height = 192, .log2_ctb = 6, .log2_min_cb = 3 };
    var pps: hevc.HevcPps = .{ .entropy_coding_sync = true };
    var p: Program = .{};
    p.begin(&sps, &pps);
    var room: [2000]Command = undefined;
    var c = testCommands(2000, &room);
    const h: hevc.HevcSliceHeader = .{ .first_slice_in_pic = true, .slice_type = .i, .qp = 30 };
    var msgs: [max_messages]u16 = undefined;
    const refs: [2][ref_slots]Ref = @splat(@splat(.{}));
    const n = messages(&msgs, &h, &pps, &refs, 0, false);
    _ = p.segment(&c, &h, msgs[0..n], 100);
    p.finish(&c);
    const list = c.list[0..c.len];
    try testing.expectEqual(@as(u32, 88), c.len);
    try testing.expectEqual(@as(usize, 3), countTo(list, CONTROL) - countTo(list, TILESTART));
    try testing.expectEqual(@as(u32, 0x0008_0061), list[87].data);
    try testing.expectEqual(@as(u32, 0x0008_0025), list[83].data);
    try testing.expectEqual(@as(u32, 0x7_0000), list[85].data);
}

test "a picture of four tiles: 84 commands, each tile its run" {
    var sps: hevc.HevcSps = .{ .width = 256, .height = 128, .log2_ctb = 6, .log2_min_cb = 3 };
    var pps: hevc.HevcPps = .{ .tiles = true, .num_tile_columns = 2, .num_tile_rows = 2 };
    var p: Program = .{};
    p.begin(&sps, &pps);
    try testing.expectEqual([3]u32{ 0, 2, 4 }, p.col_bd[0..3].*);
    try testing.expectEqual([3]u32{ 0, 1, 2 }, p.row_bd[0..3].*);
    var room: [2000]Command = undefined;
    var c = testCommands(2000, &room);
    const h: hevc.HevcSliceHeader = .{ .first_slice_in_pic = true, .slice_type = .i, .qp = 30 };
    var msgs: [max_messages]u16 = undefined;
    const refs: [2][ref_slots]Ref = @splat(@splat(.{}));
    const n = messages(&msgs, &h, &pps, &refs, 0, false);
    _ = p.segment(&c, &h, msgs[0..n], 100);
    p.finish(&c);
    const list = c.list[0..c.len];
    try testing.expectEqual(@as(u32, 84), c.len);
    try testing.expectEqual(@as(usize, 4), countTo(list, TILESTART));
    try testing.expectEqual(@as(?u32, 0x0001_0002), lastTo(list, TILESTART));
    try testing.expectEqual(@as(u32, 0x0004_0061), list[83].data);
}

test "a second slice's data is placed at its own commands, after the fill before it" {
    var sps: hevc.HevcSps = .{ .width = 256, .height = 192, .log2_ctb = 6, .log2_min_cb = 3 };
    var msgs: [max_messages]u16 = undefined;
    const refs: [2][ref_slots]Ref = @splat(@splat(.{}));
    for ([_]hevc.HevcPps{ .{ .entropy_coding_sync = true }, .{ .tiles = true, .num_tile_columns = 2, .num_tile_rows = 1 } }) |pps| {
        var p: Program = .{};
        p.begin(&sps, &pps);
        var room: [2000]Command = undefined;
        var c = testCommands(2000, &room);
        var h: hevc.HevcSliceHeader = .{ .first_slice_in_pic = true, .slice_type = .i, .qp = 30 };
        const n = messages(&msgs, &h, &pps, &refs, 0, false);
        const first = p.segment(&c, &h, msgs[0..n], 100);
        h.first_slice_in_pic = false;
        h.segment_address = if (pps.tiles) 2 else 4;
        const second = p.segment(&c, &h, msgs[0..n], 50);
        p.finish(&c);
        try testing.expectEqual(@as(u32, 0), first);
        try testing.expect(second > first + 4);
        for ([_]u32{ first, second }) |e| {
            try testing.expectEqual(BFBASE, c.list[e].addr);
            try testing.expectEqual(BFNUM, c.list[e + 1].addr);
            try testing.expectEqual(BFCONTROL, c.list[e + 2].addr);
            try testing.expectEqual(BFCONTROL, c.list[e + 3].addr);
        }
        try testing.expectEqual(@as(u32, 50), c.list[second + 1].data);
        try testing.expectEqual(STATUS, c.list[second - 1].addr);
    }
}

test "the CTB before another in the tile scan" {
    var sps: hevc.HevcSps = .{ .width = 256, .height = 128, .log2_ctb = 6, .log2_min_cb = 3 };
    var pps: hevc.HevcPps = .{ .tiles = true, .num_tile_columns = 2, .num_tile_rows = 2 };
    var p: Program = .{};
    p.begin(&sps, &pps);
    try testing.expectEqual(Ctb{ .x = 2, .y = 0 }, p.before(3, 0));
    try testing.expectEqual(Ctb{ .x = 1, .y = 0 }, p.before(2, 0));
    try testing.expectEqual(Ctb{ .x = 3, .y = 0 }, p.before(0, 1));
    try testing.expectEqual(Ctb{ .x = 1, .y = 1 }, p.before(2, 1));
}

test "CONFIG2 of an 8-bit and a 10-bit picture, as the Linux driver's" {
    var sps: hevc.HevcSps = .{ .width = 1920, .height = 1080, .log2_ctb = 6, .strong_intra_smoothing = true, .temporal_mvp = true };
    var pps: hevc.HevcPps = .{};
    var p: Program = .{};
    p.begin(&sps, &pps);
    p.temporal_mvp = true;
    try testing.expectEqual(@as(u32, 0x000A_D888), p.config2(true));
    sps.bit_depth_luma = 10;
    sps.bit_depth_chroma = 10;
    try testing.expectEqual(@as(u32, 0x000A_DBAA), p.config2(true));
    try testing.expectEqual(@as(u32, 0x0438_0780), p.framesize());
}

test "a weighted P slice's messages: each reference eight words" {
    var h: hevc.HevcSliceHeader = .{ .slice_type = .p, .num_ref_idx = .{ 2, 0 }, .weighted = true, .max_num_merge_cand = 5 };
    h.weights.luma_log2_denom = 6;
    h.weights.chroma_log2_denom = 6;
    h.weights.luma_weight[0] = @splat(64);
    h.weights.chroma_weight[0] = @splat(.{ 64, 64 });
    h.weights.luma_offset[0][1] = -3;
    const pps: hevc.HevcPps = .{};
    var refs: [2][ref_slots]Ref = @splat(@splat(.{}));
    refs[0][0] = .{ .slot = 1, .poc = 8 };
    refs[0][1] = .{ .slot = 2, .poc = 4, .long_term = true };
    var msgs: [max_messages]u16 = undefined;
    const n = messages(&msgs, &h, &pps, &refs, 10, false);
    try testing.expectEqual(@as(usize, 1 + 2 * 8 + 2), n);
    // P, two references, all before it, five candidates, list 0.
    try testing.expectEqual(@as(u16, 2 | 2 << 2 | 1 << 10 | 5 << 11 | 1 << 14), msgs[0]);
    try testing.expectEqual(@as(u16, 1 | 3 << 5), msgs[1]);
    try testing.expectEqual(@as(u16, 8), msgs[2]);
    try testing.expectEqual(@as(u16, 6 | 64 << 3), msgs[3]);
    try testing.expectEqual(@as(u16, 2 | 1 << 4 | 3 << 5), msgs[9]);
    try testing.expectEqual(@as(u16, 0xFD), msgs[12]);
}

test "a frame of columns copied out as NV12, 8 bits and 10" {
    const l8 = Layout.of(200, 16, false);
    var sand8: [2 * 24 * 128]u8 align(4) = undefined;
    for (&sand8, 0..) |*b, i| b.* = @truncate(i);
    var out8: [256 * 24]u8 = undefined;
    copyOut(&sand8, l8, &out8, out8[256 * 16 ..].ptr, 256);
    try testing.expectEqual(sand8[0], out8[0]);
    try testing.expectEqual(sand8[l8.pitch + 3 * 128 + 5], out8[3 * 256 + 128 + 5]);
    try testing.expectEqual(sand8[l8.chroma + 2 * 128 + 7], out8[256 * 16 + 2 * 256 + 7]);
    const l10 = Layout.of(96, 8, true);
    var sand10: [12 * 128]u8 align(4) = @splat(0);
    std.mem.writeInt(u32, sand10[0..4], 1023 | 512 << 10 | 3 << 20, .little);
    var out10: [96 * 12]u8 = undefined;
    copyOut(&sand10, l10, &out10, out10[96 * 8 ..].ptr, 96);
    try testing.expectEqual([3]u8{ 255, 128, 1 }, out10[0..3].*);
}
