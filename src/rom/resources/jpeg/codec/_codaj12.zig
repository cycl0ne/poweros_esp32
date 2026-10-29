// SPDX-License-Identifier: MPL-2.0
//! The JH7110's JPEG codec, Chips&Media's CODAJ12 ("JPU"), as a decoder:
//! where the board has it, how it is woken, the tables a header gives
//! written into its registers, and a file read from memory into YCbCr
//! planes.
//!
//! **Waking it**: the video decoder's power domain on - it holds the
//! WAVE511 as well - the codec's clocks let through, its resets and the
//! domain's bus let go; then its own reset (INST_CTRL_START bit 2, held
//! until the instance controller reads idle) and its instance 0 enabled.
//! It answers with its version.
//!
//! **A decode**, as StarFive's codaj12 package does one (jpuapi.c's
//! JPU_DecStartOneFrame): the file whole in a buffer of 256-byte pages,
//! its end marked (BBC_STRM_CTRL), so the codec never asks for more. The
//! frame, then the code tables and the quantization tables, then the first
//! two pages from the scan's coded data on fetched into the codec's bit
//! buffer by hand (`gram`), then where the planes go, and PIC_START. The
//! end is PIC_STATUS's done or error, raised on the part's interrupt:
//! the resource's server reads it and writes it back to clear it
//! (`takeStatus`).
//!
//! **A code table** goes in as the codec looks codes up: for each length
//! 1 to 16 the smallest code and the largest - 0xFFFF for a length with
//! none - and where its symbols start (0xFF for none), then the symbols,
//! a DC table's padded to 12 and an AC table's to 162; each word sign
//! extended from its value's top bit, as the codec reads them.
//!
//! **The picture** comes out as planes: grey as one, of brightness,
//! straight into the picture; colour as three at full size - the codec's
//! format converter (O_FMT_444) brings halved colour up - which ycc.zig
//! turns into blue, green and red.
//!
//! **Memory**: the codec's address registers are 32 bits wide, so what it
//! reads and writes is below 4 GiB (MEMF_DMA), and it does not see the
//! cores' caches: the file is written back out of them before the
//! codec reads it, the planes dropped from them after.
//!
//! The registers and their values are from that package's regdefine.h,
//! jpuapi.c and jpuapifunc.c (LGPL-2.1 or BSD-3-Clause); the power
//! domain, clocks and resets from StarFive's device tree for the JH7110.

const sdk = @import("sdk");
const hardware = sdk.hardware;
const system = hardware.system;
const reg = hardware.mmio.reg;
const st = sdk.expansion.systemtags;
const ExecBase = sdk.interface.exec.ExecBase;
const _header = @import("../header/_header.zig");
const Header = _header.Header;

// Instance 0's registers, from the part's address.
const PIC_START = 0x000;
const PIC_STATUS = 0x004;
const PIC_ERRMB = 0x008;
const PIC_SETMB = 0x00C;
const PIC_CTRL = 0x010;
const PIC_SIZE = 0x014;
const MCU_INFO = 0x018;
const ROT_INFO = 0x01C;
const SCL_INFO = 0x020;
const CLP_INFO = 0x028;
const OP_INFO = 0x02C;
const DPB_CONFIG = 0x030;
const DPB_BASE00 = 0x034;
const DPB_BASE01 = 0x038;
const DPB_BASE02 = 0x03C;
const DPB_YSTRIDE = 0x064;
const DPB_CSTRIDE = 0x068;
const HUFF_CTRL = 0x080;
const HUFF_ADDR = 0x084;
const HUFF_DATA = 0x088;
const QMAT_CTRL = 0x090;
const QMAT_DATA = 0x098;
const RST_INTVAL = 0x0B0;
const RST_INDEX = 0x0B4;
const RST_COUNT = 0x0B8;
const INTR_MASK = 0x0C0;
const DPCM_DIFF_Y = 0x0F0;
const DPCM_DIFF_CB = 0x0F4;
const DPCM_DIFF_CR = 0x0F8;
const VERSION_INFO = 0x0FC;
const GBU_CTRL = 0x100;
const GBU_WPTR = 0x114;
const GBU_TCNT = 0x118; // and its upper half at 0x11C
const GBU_BBSR = 0x140;
const GBU_BBER = 0x144;
const GBU_BBIR = 0x148;
const GBU_BBHR = 0x14C;
const GBU_FF_RPTR = 0x160;
const BBC_END_ADDR = 0x208;
const BBC_WR_PTR = 0x20C;
const BBC_EXT_ADDR = 0x214;
const BBC_INT_ADDR = 0x218;
const BBC_DATA_CNT = 0x21C;
const BBC_COMMAND = 0x220;
const BBC_BUSY = 0x224;
const BBC_CTRL = 0x228;
const BBC_CUR_POS = 0x22C;
const BBC_BAS_ADDR = 0x230;
const BBC_STRM_CTRL = 0x234;
const SLICE_INFO = 0x240;
const SLICE_POS = 0x244;
const SLICE_DPB_POS = 0x248;
// The instance controller, shared by the codec's four instances.
const INST_CTRL_START = 0xC00;
const INST_CTRL_STATUS = 0xC04;

/// INST_CTRL_START: instance 0 enabled, and the codec's reset.
const INST_ENABLE: u32 = 1 << 0;
const INST_RESET: u32 = 1 << 2;
/// INST_CTRL_STATUS: the controller's state in bits 4 to 7, idle 0, and
/// a bit per instance that has a picture under way.
const INST_STATE_SHIFT = 4;
const INST_BUSY: u32 = 1 << 0;

/// PIC_START: decode a picture.
const START_PIC: u32 = 1 << 4;

/// PIC_STATUS, and the interrupts the decode is told of: the picture
/// done, the codec stopped on an error, and the bit buffer empty - which
/// with the whole file in it is an error too.
pub const STATUS_DONE: u32 = 1 << 0;
pub const STATUS_ERROR: u32 = 1 << 1;
pub const STATUS_EMPTY: u32 = 1 << 2;
const interrupts = STATUS_DONE | STATUS_ERROR | STATUS_EMPTY;

/// PIC_CTRL: the file's own code tables.
const USER_HUFFMAN: u32 = 1 << 6;

/// DPB_CONFIG's output format: as the file is, or brought to 4:4:4.
const OFMT_NONE: u32 = 0;
const OFMT_444: u32 = 3;

/// A page of the bit buffer, which the codec fetches the file in.
pub const page = 256;

/// How many times a wait reads its register before it gives up: far
/// longer than the codec takes.
const patience: u32 = 1_000_000;

/// The codec's clocks: its AXI, core and APB clocks, and the decoder
/// domain's bus, main and JPEG clocks.
const clocks = [_]u32{
    system.SYSCLK_NOC_BUS_VDEC_AXI, system.SYSCLK_VDEC_MAIN,    system.SYSCLK_VDEC_JPG,
    system.SYSCLK_CODAJ12_AXI,      system.SYSCLK_CODAJ12_CORE, system.SYSCLK_CODAJ12_APB,
};

/// Its resets and the domain's, in the order they are let go.
const resets = [_]u32{
    system.SYSRST_NOC_BUS_VDEC_AXI, system.SYSRST_VDEC_MAIN,    system.SYSRST_VDEC_JPG,
    system.SYSRST_CODAJ12_AXI,      system.SYSRST_CODAJ12_CORE, system.SYSRST_CODAJ12_APB,
};

/// The codec as the board lists it.
pub const Part = struct {
    regs: usize,
    irq: u32,
};

/// The board's JPEG codec, if it has a CODAJ12.
pub fn find(sys: *ExecBase) ?Part {
    const utility_lib = sys.OpenLibrary(sdk.utility.UTILITYNAME, 0) orelse return null;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return null;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_JPEG, st.CHIP_JH7110_JPU) orelse return null;
    const address = ub.GetTagData(st.PART_Address, 0, part.tags);
    const irq = ub.GetTagData(st.PART_Irq, 0, part.tags);
    if (address == 0 or irq == 0) return null;
    return .{ .regs = address, .irq = @intCast(irq) };
}

inline fn at(regs: usize, offset: usize) *volatile u32 {
    return reg(regs + offset);
}

/// The codec powered, clocked, out of reset and enabled; whether it
/// answered. Waits: yes, for the domain and the resets - outside
/// Disable. `waiter.wait(micros)` waits that long: a domain just switched
/// on is given 50 ms, as the display's is.
pub fn wake(regs: usize, sys: *ExecBase, waiter: anytype) bool {
    if (!system.powered(system.PD_VDEC)) {
        if (!system.powerOn(system.PD_VDEC)) return false;
        waiter.wait(50_000);
    }
    sys.Disable();
    for (clocks) |n| system.clockOn(.sys, n);
    for (resets) |n| system.releaseReset(.sys, n);
    sys.Enable();
    for (resets) |n| {
        if (!system.waitOutOfReset(.sys, n)) return false;
    }
    if (!reset(regs)) return false;
    at(regs, INST_CTRL_START).* = INST_ENABLE;
    const version = at(regs, VERSION_INFO).*;
    return version != 0 and version != 0xFFFF_FFFF;
}

/// The codec's own reset: what it was doing dropped, its instances
/// enabled as they were. Whether the controller came back to idle.
pub fn reset(regs: usize) bool {
    const control = at(regs, INST_CTRL_START);
    control.* |= INST_RESET;
    var tries: u32 = 0;
    const idle = while (tries < patience) : (tries += 1) {
        if ((at(regs, INST_CTRL_STATUS).* >> INST_STATE_SHIFT) & 0xF == 0) break true;
    } else false;
    control.* &= ~INST_RESET;
    return idle;
}

/// Where a file's coded data starts: past its scan's header. Null if the
/// header runs past the file.
pub fn codedStart(file: []const u8, h: *const Header) ?u32 {
    if (file.len < h.scan + 4) return null;
    const length = @as(u32, file[h.scan + 2]) << 8 | file[h.scan + 3];
    const coded = h.scan + 2 + length;
    return if (coded < file.len) coded else null;
}

/// What a decode reads and writes: the file's copy - `length` bytes on
/// whole pages, two spare pages past it - where its coded data starts,
/// and the planes, `stride` bytes a row each: brightness, and for a
/// colour file the two colour differences.
pub const Frame = struct {
    stream: usize,
    length: u32,
    coded: u32,
    y: usize,
    cb: usize = 0,
    cr: usize = 0,
    stride: u32,
};

/// The file's frame, tables and planes written into the codec, and the
/// decode started; false if the codec did not fetch the file's first
/// pages. Interrupts: the server must be ready for the end.
pub fn start(regs: usize, h: *const Header, f: Frame) bool {
    const grey = h.count == 1;
    const end = f.stream + f.length;

    at(regs, INTR_MASK).* = ~interrupts & 0x3FF;
    at(regs, SLICE_INFO).* = h.padded_height;
    at(regs, SLICE_DPB_POS).* = h.padded_height;
    at(regs, SLICE_POS).* = 0;
    at(regs, PIC_SETMB).* = 0;

    at(regs, BBC_WR_PTR).* = @truncate(end);
    at(regs, BBC_END_ADDR).* = @truncate((end + page - 1) & ~@as(usize, page - 1));
    at(regs, BBC_BAS_ADDR).* = @truncate(f.stream);
    at(regs, GBU_TCNT).* = 0;
    at(regs, GBU_TCNT + 4).* = 0;
    at(regs, PIC_ERRMB).* = 0;

    // Each component's code tables, the first component's in the top bit.
    var dc: u32 = 0;
    var ac: u32 = 0;
    for (h.component) |c| {
        dc = dc << 1 | c.dc;
        ac = ac << 1 | c.ac;
    }
    at(regs, PIC_CTRL).* = ac << 13 | dc << 7 | USER_HUFFMAN;
    at(regs, PIC_SIZE).* = h.padded_width << 16 | h.padded_height;

    // The blocks of a macro-block, the components, and each component's
    // sampling: the first's as blocks across and down of the macro-block
    // (a grey file's four blocks across, the codec's quicker way), the
    // others' 1x1. And how many bus requests the codec keeps open.
    const mcu: struct { blocks: u32, first: u32, bus: u32 } = switch (h.sampling) {
        sdk.resources.jpeg.JPEGSAMP_420 => .{ .blocks = 6, .first = 0x12, .bus = 4 },
        sdk.resources.jpeg.JPEGSAMP_422 => .{ .blocks = 4, .first = 0x11, .bus = 4 },
        sdk.resources.jpeg.JPEGSAMP_444 => .{ .blocks = 3, .first = 0x09, .bus = 8 },
        else => .{ .blocks = 4, .first = 0x21, .bus = 2 },
    };
    const others: u32 = if (grey) 0 else 0x5;
    at(regs, OP_INFO).* = mcu.bus;
    at(regs, MCU_INFO).* = mcu.blocks << 17 | h.count << 14 | mcu.first << 8 | others << 4 | others;
    // Planar, in the cores' byte order; halved colour brought to full size.
    const halved = h.sampling == sdk.resources.jpeg.JPEGSAMP_420 or h.sampling == sdk.resources.jpeg.JPEGSAMP_422;
    at(regs, DPB_CONFIG).* = (if (halved) OFMT_444 else OFMT_NONE) << 9;
    at(regs, RST_INTVAL).* = h.restart;
    at(regs, SCL_INFO).* = 0;

    codeTables(regs, h);
    quantization(regs, h);
    if (!gram(regs, f)) return false;

    // The end of the file: how many pages hold it.
    at(regs, BBC_STRM_CTRL).* = 1 << 31 | (f.length + page - 1) / page;
    at(regs, RST_INDEX).* = 0;
    at(regs, RST_COUNT).* = 0;
    at(regs, DPCM_DIFF_Y).* = 0;
    at(regs, DPCM_DIFF_CB).* = 0;
    at(regs, DPCM_DIFF_CR).* = 0;
    at(regs, GBU_FF_RPTR).* = (f.coded & 0xF) << 3;
    at(regs, GBU_CTRL).* = 3;
    at(regs, ROT_INFO).* = 0;

    at(regs, DPB_BASE00).* = @truncate(f.y);
    at(regs, DPB_BASE01).* = @truncate(f.cb);
    at(regs, DPB_BASE02).* = @truncate(f.cr);
    at(regs, DPB_YSTRIDE).* = f.stride;
    at(regs, DPB_CSTRIDE).* = if (grey) 0 else f.stride;
    at(regs, CLP_INFO).* = 0;
    at(regs, PIC_START).* = START_PIC;
    return true;
}

/// For the interrupt server: what the codec raised, cleared; 0 if
/// nothing.
pub fn takeStatus(regs: usize) u32 {
    const status = at(regs, PIC_STATUS).*;
    if (status != 0) at(regs, PIC_STATUS).* = status;
    return status;
}

/// The decode over, ended well or not: the codec ready for the next.
pub fn finish(regs: usize) void {
    const status = at(regs, PIC_STATUS).*;
    if (status != 0) at(regs, PIC_STATUS).* = status;
    at(regs, PIC_START).* = 0;
    at(regs, INST_CTRL_STATUS).* &= ~INST_BUSY;
}

/// The first two pages from the coded data's on fetched into the bit
/// buffer, its pointers set at the coded data's first byte, and the
/// fetching left to the codec from the page after.
fn gram(regs: usize, f: Frame) bool {
    const first = f.coded >> 8;
    var p = first;
    while (p < first + 2) : (p += 1) {
        at(regs, BBC_CUR_POS).* = p;
        at(regs, BBC_EXT_ADDR).* = @truncate(f.stream + (@as(usize, p) << 8));
        at(regs, BBC_INT_ADDR).* = (p & 1) << 6;
        at(regs, BBC_DATA_CNT).* = page / 4;
        at(regs, BBC_COMMAND).* = 0;
        var tries: u32 = 0;
        while (at(regs, BBC_BUSY).* != 0) : (tries += 1) {
            if (tries == patience) return false;
        }
    }
    at(regs, BBC_CUR_POS).* = first + 2;
    at(regs, BBC_CTRL).* = 1;
    // The word the coded data starts in: of the two pages, the second
    // half for an odd one.
    at(regs, GBU_WPTR).* = ((f.coded & 0xF0) >> 2) + (if (first & 1 != 0) @as(u32, 64) else 0);
    at(regs, GBU_BBSR).* = 0;
    at(regs, GBU_BBER).* = page / 4 * 2 - 1;
    const half: u32 = if (first & 1 != 0) 0 else page / 4;
    at(regs, GBU_BBIR).* = half;
    at(regs, GBU_BBHR).* = half;
    at(regs, GBU_CTRL).* = 4;
    at(regs, GBU_FF_RPTR).* = (f.coded & 0xF) << 3;
    return true;
}

/// A value as the code table registers take it: sign extended from bit
/// `top`.
fn extended(value: u32, comptime top: u5) u32 {
    return if (value & (@as(u32, 1) << top) != 0) value | ~((@as(u32, 1) << (top + 1)) - 1) else value;
}

/// What the codec looks a table's codes up by: for each length the
/// smallest code, the largest, and where its symbols start.
const Lookup = struct {
    min: [16]u32 = undefined,
    max: [16]u32 = undefined,
    ptr: [16]u32 = undefined,
};

fn lookupOf(table: *const _header.CodeTable) Lookup {
    var l: Lookup = .{};
    var code: u32 = 0;
    var symbols: u32 = 0;
    var started = false;
    for (table.counts, 0..) |count, i| {
        if (count != 0) {
            l.ptr[i] = symbols;
            symbols += count;
            l.min[i] = code & 0xFFFF;
            l.max[i] = (code + count - 1) & 0xFFFF;
            started = true;
            code = (code + count) << 1;
        } else {
            l.ptr[i] = 0xFF;
            l.min[i] = 0xFFFF;
            l.max[i] = 0xFFFF;
            if (started) code <<= 1;
        }
    }
    return l;
}

/// The four code tables, DC 0 and 1, then AC 0 and 1.
fn codeTables(regs: usize, h: *const Header) void {
    const order = [4]*const _header.CodeTable{ &h.code[0][0], &h.code[0][1], &h.code[1][0], &h.code[1][1] };
    var lookups: [4]Lookup = undefined;
    for (order, &lookups) |table, *l| l.* = lookupOf(table);
    const data = at(regs, HUFF_DATA);

    at(regs, HUFF_CTRL).* = 0x003;
    for (lookups) |l| for (l.min) |v| {
        data.* = extended(v, 15);
    };
    at(regs, HUFF_CTRL).* = 0x403;
    at(regs, HUFF_ADDR).* = 0x440;
    for (lookups) |l| for (l.max) |v| {
        data.* = extended(v, 15);
    };
    at(regs, HUFF_CTRL).* = 0x803;
    at(regs, HUFF_ADDR).* = 0x880;
    for (lookups) |l| for (l.ptr) |v| {
        data.* = extended(v, 7);
    };
    at(regs, HUFF_CTRL).* = 0xC03;
    for (order, 0..) |table, i| {
        // A DC table's symbols, its codes up to 12 bits long, in 12
        // places; an AC table's in 162.
        const places: u32 = if (i < 2) 12 else 162;
        var count: u32 = 0;
        for (table.counts[0..if (i < 2) 12 else 16]) |n| count += n;
        for (table.symbols[0..@min(count, 256)]) |symbol| data.* = extended(symbol, 7);
        var pad = count;
        while (pad < places) : (pad += 1) data.* = 0xFFFF_FFFF;
    }
    at(regs, HUFF_CTRL).* = 0;
}

/// Each component's quantization table, in the file's zigzag order; a
/// grey file's as three of table 0, as the codec wants three.
fn quantization(regs: usize, h: *const Header) void {
    const select = [3]u32{ 0x03, 0x43, 0x83 };
    for (select, 0..) |ctrl, i| {
        const table = if (i < h.count) h.component[i].table else 0;
        at(regs, QMAT_CTRL).* = ctrl;
        for (_header.zigzag) |natural| at(regs, QMAT_DATA).* = h.quantization[table][natural];
        at(regs, QMAT_CTRL).* = 0;
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "a code table's lookup: the codes of each length, where their symbols start" {
    // The standard luminance DC table: one code of 2 bits, five of 3,
    // one each of 4 to 9.
    var table: _header.CodeTable = .{};
    table.counts = .{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
    const l = lookupOf(&table);
    try testing.expectEqual(@as(u32, 0xFFFF), l.min[0]);
    try testing.expectEqual(@as(u32, 0xFF), l.ptr[0]);
    try testing.expectEqual(@as(u32, 0b00), l.min[1]);
    try testing.expectEqual(@as(u32, 0b00), l.max[1]);
    try testing.expectEqual(@as(u32, 0), l.ptr[1]);
    try testing.expectEqual(@as(u32, 0b010), l.min[2]);
    try testing.expectEqual(@as(u32, 0b110), l.max[2]);
    try testing.expectEqual(@as(u32, 1), l.ptr[2]);
    try testing.expectEqual(@as(u32, 0b1110), l.min[3]);
    try testing.expectEqual(@as(u32, 6), l.ptr[3]);
    try testing.expectEqual(@as(u32, 0b111111110), l.min[8]);
    try testing.expectEqual(@as(u32, 0xFFFF), l.max[9]);
}

test "the registers' sign extension" {
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), extended(0xFFFF, 15));
    try testing.expectEqual(@as(u32, 0x7FFF), extended(0x7FFF, 15));
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), extended(0xFF, 7));
    try testing.expectEqual(@as(u32, 0xFFFF_FFA2), extended(0xA2, 7));
    try testing.expectEqual(@as(u32, 0x12), extended(0x12, 7));
}

test "where the coded data starts: past the scan's header" {
    var h: Header = .{};
    const file = @embedFile("../../../../disk/tests/datatypes/Garden.jpg");
    try _header.read(file, &h);
    const coded = codedStart(file, &h).?;
    // Three components: a header of 12 bytes after its marker.
    try testing.expectEqual(h.scan + 2 + 12, coded);
    try testing.expectEqual(@as(?u32, null), codedStart(file[0 .. h.scan + 3], &h));
}
