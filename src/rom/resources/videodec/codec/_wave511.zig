// SPDX-License-Identifier: MPL-2.0
//! The JH7110's video decoder, Chips&Media's WAVE511, as videodec.resource
//! drives it: where the board has it, how it is woken and its firmware
//! started, and the commands a decoder is run by.
//!
//! **Waking it**: the video decoder's power domain on - the JPEG codec
//! shares it - the decoder's clocks let through (its AXI, BPU, VCE and APB
//! clocks, the domain's main clock and bus), and its resets let go, its
//! SRAM's with them. It answers with its product number, 0x5110.
//!
//! **Starting the firmware**: the boot reset - the decoder's bus to memory
//! drained (one backbone for the whole core on the JH7110: VPU_CONFIG0 bit
//! 16 set, 22 and 28 clear), then every block of it reset - and the
//! firmware in a 2 MiB code buffer, a 1 MiB temp buffer after it, the code
//! buffer's first two megabytes mapped where the decoder's processor runs
//! from (two remap pages of 1 MiB), INIT_VPU. The interrupts a decoder
//! waits for are switched on after.
//!
//! **The commands** go through the command registers from 0x100: the
//! instance and its codec, BUSY_STATUS set, the command, HOST_INT_REQ;
//! the firmware clears BUSY_STATUS once it has taken the command, and says
//! in RET_SUCCESS whether it could. INIT_SEQ and DEC_PIC are queued: the
//! firmware runs them and raises an interrupt when one is done, and QUERY
//! GET_RESULT reads what it found. The others are done when BUSY_STATUS
//! clears.
//!
//! **A decode**, as StarFive's own driver runs one (their 6.6 and 6.12
//! kernels' wave5 driver, `starfive,vdec`): CREATE_INSTANCE with a work
//! buffer and the stream's ring buffer; INIT_SEQ once the parameter sets
//! and the first picture are in it, which reads the size and how many
//! frames the stream needs; SET_FB twice - the frames that are shown, in
//! the cores' layout (linear, NV12), then the compressed frames the
//! decoder keeps for reference, each with its motion vectors and its two
//! offset tables, and a task buffer; then DEC_PIC per picture, each
//! answering which frame it decoded into and which is to be shown next. A
//! frame shown is held by the decoder's display flags until the caller
//! gives it back (UPDATE_DISP_FLAG clears its flag).
//!
//! **Memory**: the decoder's address registers are 32 bits wide, so all it
//! reads and writes is below 4 GiB (MEMF_DMA), and it does not see the
//! cores' caches.
//!
//! The registers and their values are from that driver's wave5-regdefine.h,
//! wave5-hw.c and wave5-vpuapi.h (GPL-2.0 or BSD-3-Clause); the power
//! domain, clocks and resets from StarFive's device tree for the JH7110.

const sdk = @import("sdk");
const hardware = sdk.hardware;
const system = hardware.system;
const reg = hardware.mmio.reg;
const st = sdk.expansion.systemtags;
const ExecBase = sdk.interface.exec.ExecBase;

// The decoder's own registers.
const PO_CONF = 0x000;
const VCPU_CUR_PC = 0x004;
const FIO_CTRL_ADDR = 0x020;
const FIO_DATA = 0x024;
const VINT_REASON_USR = 0x030;
const VINT_REASON_CLR = 0x034;
const HOST_INT_REQ = 0x038;
const VINT_CLEAR = 0x03C;
const VPU_INT_STS = 0x044;
const VINT_ENABLE = 0x048;
const VINT_REASON = 0x04C;
const RESET_REQ = 0x050;
const RESET_STATUS = 0x054;
const REMAP_CTRL = 0x060;
const REMAP_VADDR = 0x064;
const REMAP_PADDR = 0x068;
const REMAP_CORE_START = 0x06C;
const BUSY_STATUS = 0x070;
const VPU_CONFIG0 = 0x098;
const PRODUCT_NUMBER = 0x1044;

// The command registers: what each command reads, and answers in.
const CMD_REG_BASE = 0x100;
const CMD_REG_END = 0x200;
const COMMAND = 0x100;
const COMMAND_OPTION = 0x104;
const QUERY_OPTION = 0x104;
const RET_SUCCESS = 0x108;
const RET_FAIL_REASON = 0x10C;
const INSTANCE_INFO = 0x110;
const RET_QUEUE_STATUS = 0x1E0;
const RET_QUEUE_CMD_DONE_INST = 0x1E8;
const RET_SEQ_DONE_INSTANCE_INFO = 0x1FC;

// INIT_VPU.
const ADDR_CODE_BASE = 0x110;
const CODE_SIZE = 0x114;
const CODE_PARAM = 0x118;
const ADDR_TEMP_BASE = 0x11C;
const TEMP_SIZE = 0x120;
const HW_OPTION = 0x12C;
const SEC_AXI_PARAM = 0x180;
// QUERY GET_VPU_INFO's answer.
const RET_FW_VERSION = 0x118;

// CREATE_INSTANCE.
const ADDR_WORK_BASE = 0x114;
const WORK_SIZE = 0x118;
const DEC_BS_START_ADDR = 0x11C;
const DEC_BS_SIZE = 0x120;
const BS_PARAM = 0x124;
const ADDR_SEC_AXI = 0x130;
const SEC_AXI_SIZE = 0x134;
const EXT_ADDR = 0x138;
const NUM_CQ_DEPTH_M1 = 0x13C;
const DEC_VCORE_INFO = 0x194;

// INIT_SEQ, DEC_PIC and UPDATE_BS.
const BS_RD_PTR = 0x118;
const BS_WR_PTR = 0x11C;
const BS_OPTION = 0x120;
const SEQ_CHANGE_ENABLE_FLAG = 0x128;
const DEC_USER_MASK = 0x12C;
const DEC_TEMPORAL_ID_PLUS1 = 0x130;
const DEC_FORCE_FB_LATENCY_PLUS1 = 0x134;
const USE_SEC_AXI = 0x150;

// QUERY GET_RESULT: what it reads, and what INIT_SEQ and DEC_PIC found.
const DEC_ADDR_REPORT_BASE = 0x114;
const DEC_REPORT_SIZE = 0x118;
const DEC_REPORT_PARAM = 0x11C;
const RET_DEC_SEQ_PARAM = 0x120;
const RET_DEC_COLOR_SAMPLE_INFO = 0x124;
const RET_DEC_FRAME_RATE_NR = 0x130;
const RET_DEC_FRAME_RATE_DR = 0x134;
const RET_DEC_NUM_REQUIRED_FB = 0x138;
const RET_DEC_NOTIFICATION = 0x144;
const RET_DEC_PIC_SIZE = 0x14C;
const RET_DEC_CROP_TOP_BOTTOM = 0x150;
const RET_DEC_CROP_LEFT_RIGHT = 0x154;
const RET_DEC_DECODED_INDEX = 0x170;
const RET_DEC_DISPLAY_INDEX = 0x174;
const RET_DEC_DISP_IDC = 0x17C;
const RET_VLC_BUF_SIZE = 0x1B0;
const RET_PARAM_BUF_SIZE = 0x1B4;
const RET_DEC_ERR_INFO = 0x1D8;
const RET_DEC_DECODING_SUCCESS = 0x1DC;

// SET_FB.
const SFB_OPTION = 0x104;
const COMMON_PIC_INFO = 0x118;
const PIC_SIZE = 0x11C;
const SET_FB_NUM = 0x120;
const ADDR_LUMA_BASE0 = 0x134;
const ADDR_CB_BASE0 = 0x138;
const ADDR_CR_BASE0 = 0x13C;
const ADDR_FBC_Y_OFFSET0 = 0x13C;
const ADDR_FBC_C_OFFSET0 = 0x140;
const ADDR_MV_COL0 = 0x1B4;
const SET_FB_ADDR_TASK_BUF = 0x1D4;
const SET_FB_TASK_BUF_SIZE = 0x1D8;

// QUERY UPDATE_DISP_FLAG, GET_BS_RD_PTR and SET_BS_RD_PTR.
const DEC_SET_DISP_IDC = 0x118;
const DEC_CLR_DISP_IDC = 0x11C;
const RET_QUERY_DEC_BS_RD_PTR = 0x11C;

// Through the FIO port: the bus between the core and memory.
const COMBINED_BUS_CTRL = 0xFE10;
const COMBINED_BUS_STATUS = 0xFE14;
const BACKBONE_PROG_AXI_ID = 0xFE0C;
const BACKBONE_PROC_EXT_ADDR = 0xFEC0;
const BACKBONE_AXI_PARAM = 0xFEE0;
const FIO_READY: u32 = 1 << 31;
const FIO_WRITE: u32 = 1 << 16;

/// The commands.
const CMD_INIT_VPU: u32 = 0x0001;
const CMD_CREATE_INSTANCE: u32 = 0x0008;
const CMD_FLUSH_INSTANCE: u32 = 0x0010;
const CMD_DESTROY_INSTANCE: u32 = 0x0020;
const CMD_INIT_SEQ: u32 = 0x0040;
const CMD_SET_FB: u32 = 0x0080;
const CMD_DEC_PIC: u32 = 0x0100;
const CMD_QUERY: u32 = 0x4000;
const CMD_UPDATE_BS: u32 = 0x8000;

/// QUERY's options.
const GET_VPU_INFO: u32 = 0;
const GET_RESULT: u32 = 2;
const UPDATE_DISP_FLAG: u32 = 3;
const GET_BS_RD_PTR: u32 = 5;

/// The interrupts: a sequence read (INIT_SEQ), a picture done (DEC_PIC),
/// the stream's buffer read empty.
pub const INT_INIT_SEQ: u32 = 1 << 6;
pub const INT_DEC_PIC: u32 = 1 << 8;
pub const INT_BSBUF_EMPTY: u32 = 1 << 15;
const interrupts = INT_INIT_SEQ | INT_DEC_PIC | INT_BSBUF_EMPTY;

/// RET_FAIL_REASON: the firmware still busy with the instance.
const FAIL_STILL_RUNNING: u32 = 0x1000;

/// The codecs as the firmware numbers them.
pub const STD_HEVC: u32 = 0;
pub const STD_AVC: u32 = 2;

/// RESET_REQ: every block.
const RST_BLOCK_ALL: u32 = 0x3FFF_FFFF;

/// The stream's byte order as the decoder reads it, and the report's.
const BITSTREAM_BIG_ENDIAN: u32 = 0xF;
/// BS_OPTION: each fed piece ends where the write pointer is; the stream
/// ends there.
const BS_EXPLICIT_END: u32 = 1 << 0;
const BS_STREAM_END: u32 = 1 << 1;

/// The changes within a stream the firmware reports (SEQ_CHANGE_ENABLE):
/// H.264's size, depth, number of frames, aspect, signal and timing;
/// H.265's profile, size, depth and number of frames.
const SEQ_CHANGE_AVC: u32 = 1 << 16 | 1 << 18 | 1 << 19 | 1 << 21 | 1 << 23 | 1 << 29;
const SEQ_CHANGE_HEVC: u32 = 1 << 5 | 1 << 16 | 1 << 18 | 1 << 19;

/// COMMON_PIC_INFO: frames in the cores' layout (bit 28), the pixel order
/// (23), the colour differences side by side (16).
const PIC_LINEAR: u32 = 1 << 28;
const PIC_ORDER: u32 = 1 << 23;
const PIC_CBCR_INTERLEAVE: u32 = 1 << 16;

/// The firmware's code buffer, its temp buffer after it, and the remap
/// pages that map the code where the decoder's processor runs it.
pub const code_size: u32 = 2 * 1024 * 1024;
pub const temp_size: u32 = 1024 * 1024;
pub const remap_page: u32 = 1024 * 1024;

/// The work buffer a decoder instance takes.
pub const work_size: u32 = 1784 * 1024;

/// The decoder's SRAM, at its own address 0: given to each instance, as
/// StarFive's driver gives it - which uses none of it for the line
/// buffers (USE_SEC_AXI 0).
const sram_address: u32 = 0;
const sram_size: u32 = 0x2D000;

/// The firmware runs two commands of an instance at once.
const queue_depth: u32 = 2;

/// The most frames of each kind SET_FB takes, and how many go per command.
pub const max_frames = 31;
const frames_per_set = 8;

/// The decoder as the board lists it.
pub const Part = struct {
    regs: usize,
    irq: u32,
};

/// The board's video decoder, if it has a WAVE511.
pub fn find(sys: *ExecBase) ?Part {
    const utility_lib = sys.OpenLibrary(sdk.utility.UTILITYNAME, 0) orelse return null;
    defer sys.CloseLibrary(utility_lib);
    const ub: *sdk.interface.utility.UtilityBase = @ptrCast(utility_lib);
    const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return null;
    defer sys.CloseLibrary(expansion_lib);
    const eb: *sdk.interface.expansion.ExpansionBase = @ptrCast(expansion_lib);
    const part = eb.FindBoardPart(null, st.PARTKIND_VIDEODEC, st.CHIP_JH7110_VDEC) orelse return null;
    const address = ub.GetTagData(st.PART_Address, 0, part.tags);
    const irq = ub.GetTagData(st.PART_Irq, 0, part.tags);
    if (address == 0 or irq == 0) return null;
    return .{ .regs = address, .irq = @intCast(irq) };
}

inline fn at(regs: usize, offset: usize) *volatile u32 {
    return reg(regs + offset);
}

/// The decoder's clocks: its AXI, BPU, VCE and APB clocks, the domain's
/// main clock and bus.
const clocks = [_]u32{
    system.SYSCLK_NOC_BUS_VDEC_AXI, system.SYSCLK_VDEC_MAIN,   system.SYSCLK_WAVE511_APB,
    system.SYSCLK_WAVE511_AXI,      system.SYSCLK_WAVE511_BPU, system.SYSCLK_WAVE511_VCE,
};

/// Its resets and the domain's, in the order they are let go; its SRAM's
/// last.
const resets = [_]u32{
    system.SYSRST_NOC_BUS_VDEC_AXI, system.SYSRST_VDEC_MAIN,   system.SYSRST_WAVE511_APB,
    system.SYSRST_WAVE511_AXI,      system.SYSRST_WAVE511_BPU, system.SYSRST_WAVE511_VCE,
    system.SYSRST_AXIMEM0_AXI,
};

/// The decoder's own resets, held again when the firmware's buffers go:
/// the domain's stay as the JPEG codec may need them.
const own_resets = [_]u32{
    system.SYSRST_WAVE511_AXI, system.SYSRST_WAVE511_BPU,
    system.SYSRST_WAVE511_VCE, system.SYSRST_WAVE511_APB,
};

/// The decoder powered, clocked and out of reset; whether it answered.
/// Waits: yes, for the domain and the resets - outside Disable.
/// `waiter.wait(micros)` waits that long: a domain just switched on is
/// given 50 ms, as the display's is.
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
    const product = at(regs, PRODUCT_NUMBER).*;
    return product & 0xFFF0 == 0x5110;
}

/// The decoder's processor stopped, for its code buffer to go.
pub fn halt(sys: *ExecBase) void {
    sys.Disable();
    for (own_resets) |n| system.holdInReset(.sys, n);
    sys.Enable();
}

/// Until `offset` reads `want` under `mask`, or `us` have gone by.
fn waitFor(regs: usize, offset: usize, mask: u32, want: u32, us: u64) bool {
    const until = hardware.systimer.uptimeUs() + us;
    while (hardware.systimer.uptimeUs() < until) {
        if (at(regs, offset).* & mask == want) return true;
    }
    return at(regs, offset).* & mask == want;
}

fn fioRead(regs: usize, address: u32) ?u32 {
    at(regs, FIO_CTRL_ADDR).* = address & 0xFFFF;
    if (!waitFor(regs, FIO_CTRL_ADDR, FIO_READY, FIO_READY, 100_000)) return null;
    return at(regs, FIO_DATA).*;
}

fn fioWrite(regs: usize, address: u32, data: u32) bool {
    at(regs, FIO_DATA).* = data;
    at(regs, FIO_CTRL_ADDR).* = (address & 0xFFFF) | FIO_WRITE;
    return waitFor(regs, FIO_CTRL_ADDR, FIO_READY, FIO_READY, 100_000);
}

/// The boot reset: the bus between the core and memory drained, every
/// block reset. Only the one backbone for the whole core is known
/// (VPU_CONFIG0 bit 16 set, 22 and 28 clear, as the JH7110's is).
fn bootReset(regs: usize) bool {
    at(regs, BUSY_STATUS).* = 0;
    const config0 = at(regs, VPU_CONFIG0).*;
    if (config0 & (1 << 16) == 0 or config0 & (1 << 22 | 1 << 28) != 0) return false;
    _ = fioWrite(regs, COMBINED_BUS_CTRL, 0x7);
    const until = hardware.systimer.uptimeUs() + 500_000;
    const drained = while (hardware.systimer.uptimeUs() < until) {
        if (fioRead(regs, COMBINED_BUS_STATUS) == 0x3F) break true;
    } else false;
    if (!drained) {
        _ = fioWrite(regs, COMBINED_BUS_CTRL, 0);
        return false;
    }
    at(regs, RESET_REQ).* = RST_BLOCK_ALL;
    const reset_done = waitFor(regs, RESET_STATUS, 0xFFFF_FFFF, 0, 500_000);
    at(regs, RESET_REQ).* = 0;
    _ = fioWrite(regs, COMBINED_BUS_CTRL, 0);
    return reset_done;
}

/// The firmware started from `code` - the code buffer, the temp buffer
/// after it, on a 1 MiB boundary below 4 GiB, the firmware in it and out
/// of the caches - and its interrupts switched on: its version, or null
/// if it did not start.
pub fn boot(regs: usize, code: u32) ?u32 {
    if (at(regs, VCPU_CUR_PC).* == 0) clearCommands(regs);
    if (!bootReset(regs)) return null;
    at(regs, PO_CONF).* = 0;
    clearCommands(regs);
    var index: u32 = 0;
    while (index < code_size / remap_page) : (index += 1) {
        at(regs, REMAP_CTRL).* = 1 << 31 | index << 12 | 1 << 11 | ((remap_page >> 12) & 0x1FF);
        at(regs, REMAP_VADDR).* = index * remap_page;
        at(regs, REMAP_PADDR).* = code + index * remap_page;
    }
    at(regs, ADDR_CODE_BASE).* = code;
    at(regs, CODE_SIZE).* = code_size;
    at(regs, CODE_PARAM).* = 0;
    at(regs, ADDR_TEMP_BASE).* = code + code_size;
    at(regs, TEMP_SIZE).* = temp_size;
    at(regs, HW_OPTION).* = 0;
    _ = fioWrite(regs, BACKBONE_PROC_EXT_ADDR, 0);
    _ = fioWrite(regs, BACKBONE_AXI_PARAM, 0);
    at(regs, SEC_AXI_PARAM).* = 0;
    _ = fioWrite(regs, BACKBONE_PROG_AXI_ID, 0);

    at(regs, BUSY_STATUS).* = 1;
    at(regs, COMMAND).* = CMD_INIT_VPU;
    at(regs, REMAP_CORE_START).* = 1;
    if (!waitFor(regs, BUSY_STATUS, 0xFFFF_FFFF, 0, 3_000_000)) return null;
    if (at(regs, RET_SUCCESS).* == 0) return null;

    at(regs, QUERY_OPTION).* = GET_VPU_INFO;
    at(regs, BUSY_STATUS).* = 1;
    at(regs, COMMAND).* = CMD_QUERY;
    at(regs, HOST_INT_REQ).* = 1;
    if (!waitBusy(regs) or at(regs, RET_SUCCESS).* == 0) return null;
    const version = at(regs, RET_FW_VERSION).*;
    at(regs, VINT_ENABLE).* = interrupts;
    return version;
}

fn clearCommands(regs: usize) void {
    var r: usize = CMD_REG_BASE;
    while (r < CMD_REG_END) : (r += 4) at(regs, r).* = 0;
}

/// For the interrupt server: what the decoder raised, cleared - 0 if
/// nothing - and which instances finished a sequence and which a
/// picture, each instance's bit cleared as it is taken.
pub const Raised = struct {
    reason: u32 = 0,
    seq_done: u32 = 0,
    pic_done: u32 = 0,
};

pub fn takeInterrupt(regs: usize) Raised {
    if (at(regs, VPU_INT_STS).* == 0) return .{};
    const reason = at(regs, VINT_REASON).*;
    at(regs, VINT_REASON_CLR).* = reason;
    at(regs, VINT_CLEAR).* = 1;
    var raised: Raised = .{ .reason = reason };
    if (reason & INT_INIT_SEQ != 0) raised.seq_done = take(regs, RET_SEQ_DONE_INSTANCE_INFO);
    if (reason & INT_DEC_PIC != 0) raised.pic_done = take(regs, RET_QUEUE_CMD_DONE_INST);
    at(regs, VINT_REASON_USR).* = at(regs, VINT_REASON_USR).* & ~reason;
    return raised;
}

/// The instance bits set in `offset`, cleared - those alone, so one the
/// firmware sets meanwhile stays.
fn take(regs: usize, offset: usize) u32 {
    const bits = at(regs, offset).*;
    if (bits != 0) at(regs, offset).* = at(regs, offset).* & ~bits;
    return bits;
}

/// Until the firmware has taken the command: false after a second.
fn waitBusy(regs: usize) bool {
    return waitFor(regs, BUSY_STATUS, 0xFFFF_FFFF, 0, 1_000_000);
}

/// A decoder instance as the commands name it.
pub const Instance = struct {
    regs: usize,
    id: u32,
    std: u32,

    fn issue(i: Instance, command: u32) void {
        at(i.regs, INSTANCE_INFO).* = i.std << 16 | i.id;
        at(i.regs, BUSY_STATUS).* = 1;
        at(i.regs, COMMAND).* = command;
        at(i.regs, HOST_INT_REQ).* = 1;
    }

    /// The command given and taken: whether it could be.
    fn send(i: Instance, command: u32) bool {
        i.issue(command);
        return waitBusy(i.regs) and at(i.regs, RET_SUCCESS).* != 0;
    }

    fn query(i: Instance, option: u32) bool {
        at(i.regs, QUERY_OPTION).* = option;
        return i.send(CMD_QUERY);
    }

    /// The instance made, with its work buffer and the stream's ring.
    pub fn create(i: Instance, work: u32, ring: u32, ring_size: u32) bool {
        at(i.regs, DEC_VCORE_INFO).* = 1;
        at(i.regs, ADDR_WORK_BASE).* = work;
        at(i.regs, WORK_SIZE).* = work_size;
        at(i.regs, ADDR_SEC_AXI).* = sram_address;
        at(i.regs, SEC_AXI_SIZE).* = sram_size;
        at(i.regs, DEC_BS_START_ADDR).* = ring;
        at(i.regs, DEC_BS_SIZE).* = ring_size;
        at(i.regs, BS_PARAM).* = BITSTREAM_BIG_ENDIAN;
        at(i.regs, EXT_ADDR).* = 0;
        at(i.regs, NUM_CQ_DEPTH_M1).* = queue_depth - 1;
        return i.send(CMD_CREATE_INSTANCE);
    }

    /// The instance gone: false if the firmware would not let it go.
    pub fn destroy(i: Instance) bool {
        var tries: u32 = 0;
        while (tries < 20) : (tries += 1) {
            if (i.send(CMD_DESTROY_INSTANCE)) return true;
            if (at(i.regs, RET_FAIL_REASON).* != FAIL_STILL_RUNNING) return false;
            hardware.systimer.spinUs(1000);
        }
        return false;
    }

    /// What is queued for the instance and not done dropped.
    pub fn flush(i: Instance) bool {
        var tries: u32 = 0;
        while (tries < 20) : (tries += 1) {
            if (i.send(CMD_FLUSH_INSTANCE)) return true;
            if (at(i.regs, RET_FAIL_REASON).* != FAIL_STILL_RUNNING) return false;
            hardware.systimer.spinUs(1000);
        }
        return false;
    }

    fn streamOption(end: bool) u32 {
        return BS_EXPLICIT_END | if (end) BS_STREAM_END else 0;
    }

    /// The sequence read from the stream between `rd` and `wr`: queued,
    /// INT_INIT_SEQ when done.
    pub fn initSeq(i: Instance, rd: u32, wr: u32, end: bool) bool {
        at(i.regs, BS_RD_PTR).* = rd;
        at(i.regs, BS_WR_PTR).* = wr;
        at(i.regs, BS_OPTION).* = streamOption(end);
        at(i.regs, COMMAND_OPTION).* = 1;
        at(i.regs, DEC_USER_MASK).* = 0;
        return i.send(CMD_INIT_SEQ);
    }

    /// The next picture decoded: queued, INT_DEC_PIC when done.
    pub fn decodePicture(i: Instance, rd: u32, wr: u32, end: bool) bool {
        at(i.regs, BS_RD_PTR).* = rd;
        at(i.regs, BS_WR_PTR).* = wr;
        at(i.regs, BS_OPTION).* = streamOption(end);
        at(i.regs, USE_SEC_AXI).* = 0;
        at(i.regs, DEC_USER_MASK).* = 0;
        at(i.regs, COMMAND_OPTION).* = 0;
        at(i.regs, DEC_TEMPORAL_ID_PLUS1).* = 0;
        at(i.regs, SEQ_CHANGE_ENABLE_FLAG).* = if (i.std == STD_AVC) SEQ_CHANGE_AVC else SEQ_CHANGE_HEVC;
        at(i.regs, DEC_FORCE_FB_LATENCY_PLUS1).* = 0;
        return i.send(CMD_DEC_PIC);
    }

    /// The stream's write pointer moved on, and whether it ends there.
    pub fn updateStream(i: Instance, wr: u32, end: bool) bool {
        at(i.regs, BS_OPTION).* = streamOption(end);
        at(i.regs, BS_WR_PTR).* = wr;
        return i.send(CMD_UPDATE_BS);
    }

    /// Where the firmware reads the stream: null if it would not say.
    pub fn readPointer(i: Instance) ?u32 {
        if (!i.query(GET_BS_RD_PTR)) return null;
        return at(i.regs, RET_QUERY_DEC_BS_RD_PTR).*;
    }

    /// The result of the instance's oldest finished command fetched, for
    /// `sequence` or `picture` to read.
    pub fn fetchResult(i: Instance) bool {
        at(i.regs, DEC_ADDR_REPORT_BASE).* = 0;
        at(i.regs, DEC_REPORT_SIZE).* = 0;
        at(i.regs, DEC_REPORT_PARAM).* = BITSTREAM_BIG_ENDIAN;
        return i.query(GET_RESULT);
    }

    /// What INIT_SEQ (or a DEC_PIC that saw the sequence change) found,
    /// after fetchResult.
    pub fn sequence(i: Instance) Sequence {
        const size = at(i.regs, RET_DEC_PIC_SIZE).*;
        const left_right = at(i.regs, RET_DEC_CROP_LEFT_RIGHT).*;
        const top_bottom = at(i.regs, RET_DEC_CROP_TOP_BOTTOM).*;
        const samples = at(i.regs, RET_DEC_COLOR_SAMPLE_INFO).*;
        const param = at(i.regs, RET_DEC_SEQ_PARAM).*;
        return .{
            .ok = at(i.regs, RET_DEC_DECODING_SUCCESS).* == 1,
            .error_info = at(i.regs, RET_DEC_ERR_INFO).*,
            .width = size >> 16,
            .height = size & 0xFFFF,
            .left = left_right >> 16,
            .right = left_right & 0xFFFF,
            .top = top_bottom >> 16,
            .bottom = top_bottom & 0xFFFF,
            .frames = at(i.regs, RET_DEC_NUM_REQUIRED_FB).*,
            .luma_depth = samples & 0xF,
            .chroma_depth = (samples >> 4) & 0xF,
            .profile = (param >> 24) & if (i.std == STD_AVC) @as(u32, 0x7F) else 0x1F,
            .rate_num = at(i.regs, RET_DEC_FRAME_RATE_NR).*,
            .rate_den = at(i.regs, RET_DEC_FRAME_RATE_DR).*,
            .vlc_size = at(i.regs, RET_VLC_BUF_SIZE).*,
            .param_size = at(i.regs, RET_PARAM_BUF_SIZE).*,
        };
    }

    /// What a DEC_PIC did, after fetchResult.
    pub fn picture(i: Instance) Picture {
        return .{
            .decoded = @bitCast(at(i.regs, RET_DEC_DECODED_INDEX).*),
            .shown = @bitCast(at(i.regs, RET_DEC_DISPLAY_INDEX).*),
            .changed = at(i.regs, RET_DEC_NOTIFICATION).* != 0,
            .error_info = at(i.regs, RET_DEC_ERR_INFO).*,
        };
    }

    /// Frame `index` of the shown ones free for the decoder to write
    /// again.
    pub fn releaseFrame(i: Instance, index: u32) bool {
        at(i.regs, DEC_CLR_DISP_IDC).* = @as(u32, 1) << @intCast(index);
        at(i.regs, DEC_SET_DISP_IDC).* = 0;
        return i.query(UPDATE_DISP_FLAG);
    }

    /// The frames given to the decoder: `set.count` of a kind, eight at a
    /// time. Interrupts: none; SET_FB is done when the firmware has taken
    /// it.
    pub fn setFrames(i: Instance, set: FrameSet) bool {
        at(i.regs, PIC_SIZE).* = set.width << 16 | set.height;
        if (!set.linear) {
            at(i.regs, SET_FB_ADDR_TASK_BUF).* = set.task;
            at(i.regs, SET_FB_TASK_BUF_SIZE).* = set.task_size;
        }
        at(i.regs, COMMON_PIC_INFO).* = (if (set.linear) PIC_LINEAR | PIC_CBCR_INTERLEAVE else 0) | PIC_ORDER | set.stride;
        var start: u32 = 0;
        while (start < set.count) : (start += frames_per_set) {
            const n = @min(frames_per_set, set.count - start);
            const first: u32 = if (start == 0) 1 << 3 else 0;
            const last: u32 = if (start + n == set.count) 1 << 4 else 0;
            at(i.regs, SFB_OPTION).* = first | last;
            at(i.regs, SET_FB_NUM).* = start << 8 | (start + n - 1);
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const f = set.frames[start + k];
                const slot = @as(usize, k) << 4;
                at(i.regs, ADDR_LUMA_BASE0 + slot).* = f.y;
                at(i.regs, ADDR_CB_BASE0 + slot).* = f.cb;
                if (set.linear) {
                    at(i.regs, ADDR_CR_BASE0 + slot).* = f.cr;
                    at(i.regs, ADDR_FBC_C_OFFSET0 + slot).* = 0;
                    at(i.regs, ADDR_MV_COL0 + @as(usize, k) * 4).* = 0;
                } else {
                    at(i.regs, ADDR_FBC_Y_OFFSET0 + slot).* = f.y_table;
                    at(i.regs, ADDR_FBC_C_OFFSET0 + slot).* = f.c_table;
                    at(i.regs, ADDR_MV_COL0 + @as(usize, k) * 4).* = f.mv;
                }
            }
            i.issue(CMD_SET_FB);
            if (!waitBusy(i.regs)) return false;
        }
        return at(i.regs, RET_SUCCESS).* != 0;
    }
};

/// A stream's sequence, as INIT_SEQ read it.
pub const Sequence = struct {
    ok: bool = false,
    error_info: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    left: u32 = 0,
    right: u32 = 0,
    top: u32 = 0,
    bottom: u32 = 0,
    frames: u32 = 0,
    luma_depth: u32 = 0,
    chroma_depth: u32 = 0,
    profile: u32 = 0,
    rate_num: u32 = 0,
    rate_den: u32 = 0,
    vlc_size: u32 = 0,
    param_size: u32 = 0,
};

/// A DEC_PIC's answer: the frame it decoded into - DECODED_SKIPPED for a
/// picture it passed over, DECODED_NONE for none - and the frame to be
/// shown next - SHOWN_END after the last, SHOWN_NONE for none yet - and
/// whether the sequence changed.
pub const Picture = struct {
    decoded: i32,
    shown: i32,
    changed: bool,
    error_info: u32,
};
pub const DECODED_NONE: i32 = -1;
pub const DECODED_SKIPPED: i32 = -2;
pub const SHOWN_END: i32 = -1;
pub const SHOWN_NONE: i32 = -3;

/// A frame's addresses, as SET_FB takes them: the planes, and for a
/// compressed one its two offset tables and its motion vectors.
pub const Frame = struct {
    y: u32 = 0,
    cb: u32 = 0,
    cr: u32 = 0,
    y_table: u32 = 0,
    c_table: u32 = 0,
    mv: u32 = 0,
};

/// One SET_FB's frames: of one kind, the same size and stride.
pub const FrameSet = struct {
    linear: bool,
    width: u32,
    height: u32,
    stride: u32,
    frames: []const Frame,
    count: u32,
    task: u32 = 0,
    task_size: u32 = 0,
};

// --- the sizes of what a stream needs -------------------------------------------

inline fn alignUp(v: u32, a: u32) u32 {
    return (v + a - 1) / a * a;
}

/// What a page of the decoder's memory is aligned to, and the margin
/// StarFive's driver leaves past each of its buffers.
pub const page: u32 = 4096;
const margin: u32 = 4096;

/// The sizes of a stream's frames and of what goes with them, for a
/// picture coded at `width` x `height`.
pub const Layout = struct {
    /// A shown frame: NV12 rows of `stride` bytes, `rows` of them, the
    /// colour differences after the brightness.
    stride: u32,
    rows: u32,
    linear_luma: u32,
    linear_bytes: u32,
    /// A compressed frame: its planes, its offset tables, its motion
    /// vectors.
    fbc_luma: u32,
    fbc_bytes: u32,
    y_table: u32,
    c_table: u32,
    mv: u32,

    pub fn of(std: u32, width: u32, height: u32) Layout {
        const stride = alignUp(width, 32);
        const rows = alignUp(height, 16);
        const fbc_rows = alignUp(rows, 32);
        const fbc_luma = stride * fbc_rows;
        const fbc_chroma = alignUp(stride / 2, 16) * fbc_rows;
        const mv = if (std == STD_AVC)
            ((alignUp(width, 256) / 16) * (alignUp(height, 16) / 16) + 16) * 80
        else
            ((width + 63) / 64) * ((height + 63) / 64) * 256 + 64;
        const y_table = alignUp(alignUp(height, 64) * alignUp(width, 256) / 32, 16);
        const c_table = alignUp(alignUp(height, 64) * alignUp(width / 2, 256) / 32, 16);
        return .{
            .stride = stride,
            .rows = rows,
            .linear_luma = stride * rows,
            .linear_bytes = stride * rows * 3 / 2,
            .fbc_luma = fbc_luma,
            .fbc_bytes = fbc_luma + fbc_chroma,
            .y_table = alignUp(y_table, margin) + margin,
            .c_table = alignUp(c_table, margin) + margin,
            .mv = alignUp(alignUp(mv, 16), margin) + margin,
        };
    }
};

/// The task buffer SET_FB is given: two of the VLC buffer and one
/// parameter buffer per command the firmware runs at once.
pub fn taskSize(seq: Sequence) u32 {
    return seq.vlc_size * 2 + seq.param_size * queue_depth;
}

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "1080p H.264: the frames' and their companions' sizes as StarFive's driver makes them" {
    const l = Layout.of(STD_AVC, 1920, 1088);
    try testing.expectEqual(@as(u32, 1920), l.stride);
    try testing.expectEqual(@as(u32, 1088), l.rows);
    try testing.expectEqual(@as(u32, 1920 * 1088), l.linear_luma);
    try testing.expectEqual(@as(u32, 1920 * 1088 * 3 / 2), l.linear_bytes);
    // The compressed planes: 1088 rows (already on 32), chroma 960 wide.
    try testing.expectEqual(@as(u32, 1920 * 1088 + 960 * 1088), l.fbc_bytes);
    // ((2048 / 16) * 68 + 16) * 80 = 697600, on 4 KiB and a margin.
    try testing.expectEqual(@as(u32, 700416 + 4096), l.mv);
    // 1088 * 2048 / 32 = 69632; 1088 * 1024 / 32 = 34816.
    try testing.expectEqual(@as(u32, 69632 + 4096), l.y_table);
    try testing.expectEqual(@as(u32, 36864 + 4096), l.c_table);
}

test "an odd size: rows of 32, a height on 16, H.265's motion vectors per 64x64 block" {
    const l = Layout.of(STD_HEVC, 1000, 562);
    try testing.expectEqual(@as(u32, 1024), l.stride);
    try testing.expectEqual(@as(u32, 576), l.rows);
    try testing.expectEqual(@as(u32, 1024 * 576 * 3 / 2), l.linear_bytes);
    // 16 x 9 blocks of 256 bytes, and 64.
    try testing.expectEqual(@as(u32, 40960 + 4096), l.mv);
}

test "the task buffer: two VLC buffers, a parameter buffer per queued command" {
    try testing.expectEqual(@as(u32, 2 * 1000 + 2 * 300), taskSize(.{ .vlc_size = 1000, .param_size = 300 }));
}
