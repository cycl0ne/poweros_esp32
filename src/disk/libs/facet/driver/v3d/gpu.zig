// SPDX-License-Identifier: MIT
//! The BCM2712's V3D: found, switched on, and what it says it is.
//!
//! Switching it on is three things, in the order Linux does them, and a
//! read of its registers before they are done may halt the machine:
//! - its reset let go, in the power manager (bcm2835-power's GRAFX domain);
//! - its clock on, as fast as the firmware lets it: the VideoCore's firmware
//!   has the clock (clock 5), asked through its mailbox;
//! - its SMS, the state machine that runs its power, told to power up and
//!   then to reset, which leaves the core ready (v3d_idle_sms).
//!
//! It stays on from then on. Powered off through its SMS and its clock
//! stopped, as Linux does when the driver goes, and then switched on again,
//! the whole machine stopped on the CM5 (30.10.2026): why is not known. A
//! later `powerUp` finds the clock on and only resets the SMS, as Linux does
//! after a hang.

const sdk = @import("sdk");
const exec = sdk.exec;
const st = sdk.expansion.systemtags;
const hardware = sdk.hardware;
const videocore = hardware.videocore;
const reg = hardware.mmio.reg;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const ExpansionBase = sdk.interface.expansion.ExpansionBase;
const regs = @import("regs.zig");

const TAG_GET_CLOCK_STATE: u32 = 0x0003_0001;
const TAG_SET_CLOCK_STATE: u32 = 0x0003_8001;
const TAG_GET_CLOCK_RATE: u32 = 0x0003_0002;
const TAG_GET_MAX_CLOCK_RATE: u32 = 0x0003_0004;
const TAG_SET_CLOCK_RATE: u32 = 0x0003_8002;
/// The firmware's number for the V3D's clock.
const CLOCK_V3D: u32 = 5;

/// How long the SMS is given, as Linux gives it.
const sms_wait_us: u64 = 100_000;

/// Where a core's registers and its SMS's are, from the hub's.
const core_offset: usize = 0x8000;
const sms_offset: usize = 0x3_0800;

pub const Clock = struct {
    on: bool,
    hz: u32,
    most_hz: u32,
};

pub const Ident = struct {
    version: u32,
    revision: u32,
    cores: u32,
    with_mmu: bool,
    with_tfu: bool,
    ip_revision: u32,
    slices: u32,
    qpus_per_slice: u32,
    tmus: u32,
    vpm_kib: u32,
    physical_bits: u32,
    virtual_bits: u32,
};

pub const Gpu = struct {
    sys: *ExecBase,
    hub: usize,
    core: usize,
    sms: usize,
    power_manager: usize,
    mailbox: usize,
    /// The core's interrupt: finished lists, the binner out of memory.
    irq_core: u32,
    /// The hub's: the MMU's faults, the TFU.
    irq_hub: u32,

    /// The board's V3D; null on a board with none.
    pub fn find(sys: *ExecBase) ?Gpu {
        const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
        defer sys.CloseLibrary(utility_lib);
        const utility: *UtilityBase = @ptrCast(utility_lib);
        const expansion_lib = sys.OpenLibrary(sdk.expansion.EXPANSIONNAME, 1) orelse return null;
        defer sys.CloseLibrary(expansion_lib);
        const eb: *ExpansionBase = @ptrCast(expansion_lib);
        const part = eb.FindBoardPart(null, st.PARTKIND_GPU, st.CHIP_BCM2712_V3D) orelse return null;
        const rtc = eb.FindBoardPart(null, st.PARTKIND_RTC, st.CHIP_RPI_RTC) orelse return null;
        const hub = utility.GetTagData(st.PART_Address, 0, part.tags);
        const power_manager = utility.GetTagData(st.PART_PowerManager, 0, part.tags);
        const mailbox = utility.GetTagData(st.PART_Address, 0, rtc.tags);
        const irq: u32 = @truncate(utility.GetTagData(st.PART_Irq, 0, part.tags));
        if (hub == 0 or power_manager == 0 or mailbox == 0 or irq == 0) return null;
        return .{
            .sys = sys,
            .hub = hub,
            .core = hub + core_offset,
            .sms = hub + sms_offset,
            .power_manager = power_manager,
            .mailbox = mailbox,
            .irq_core = irq,
            // The two lie side by side, as the device tree has them.
            .irq_hub = irq + 1,
        };
    }

    pub fn hubRead(gpu: *const Gpu, offset: usize) u32 {
        return reg(gpu.hub + offset).*;
    }

    pub fn hubWrite(gpu: *const Gpu, offset: usize, value: u32) void {
        reg(gpu.hub + offset).* = value;
    }

    pub fn coreRead(gpu: *const Gpu, offset: usize) u32 {
        return reg(gpu.core + offset).*;
    }

    pub fn coreWrite(gpu: *const Gpu, offset: usize, value: u32) void {
        reg(gpu.core + offset).* = value;
    }

    /// Whether `mask` of a hub register went clear in time.
    pub fn waitHubClear(gpu: *const Gpu, offset: usize, mask: u32, wait_us: u64) bool {
        const until = hardware.systimer.uptimeUs() + wait_us;
        while (hardware.systimer.uptimeUs() < until) {
            if (gpu.hubRead(offset) & mask == 0) return true;
        }
        return false;
    }

    /// The word in the power manager its reset is in: safe at any time.
    pub fn resetWord(gpu: *const Gpu) u32 {
        return reg(gpu.power_manager + regs.PM_GRAFX).*;
    }

    /// The clock as the firmware has it; null when it does not answer.
    pub fn clock(gpu: *const Gpu) ?Clock {
        var mailbox = Mailbox.open(gpu) orelse return null;
        defer mailbox.close();
        var state = [_]u32{ CLOCK_V3D, 0 };
        var rate = [_]u32{ CLOCK_V3D, 0 };
        var most = [_]u32{ CLOCK_V3D, 0 };
        if (!mailbox.ask(TAG_GET_CLOCK_STATE, &state)) return null;
        if (!mailbox.ask(TAG_GET_CLOCK_RATE, &rate)) return null;
        if (!mailbox.ask(TAG_GET_MAX_CLOCK_RATE, &most)) return null;
        return .{ .on = state[1] & 1 != 0, .hz = rate[1], .most_hz = most[1] };
    }

    /// The core out of reset, its clock on as fast as the firmware lets
    /// it, its SMS ready: after this its registers can be read.
    pub fn powerUp(gpu: *const Gpu) error{ NoFirmware, NoSms }!void {
        exec.kprintf(gpu.sys, "v3d: its reset\n", .{});
        const held = gpu.resetWord();
        if (held & regs.PM_V3DRSTN == 0) {
            reg(gpu.power_manager + regs.PM_GRAFX).* = regs.PM_PASSWORD | held | regs.PM_V3DRSTN;
        }
        exec.kprintf(gpu.sys, "v3d: its clock\n", .{});
        var mailbox = Mailbox.open(gpu) orelse return error.NoFirmware;
        defer mailbox.close();
        var running = [_]u32{ CLOCK_V3D, 0 };
        if (!mailbox.ask(TAG_GET_CLOCK_STATE, &running)) return error.NoFirmware;
        if (running[1] & 1 == 0) {
            var most = [_]u32{ CLOCK_V3D, 0 };
            if (!mailbox.ask(TAG_GET_MAX_CLOCK_RATE, &most)) return error.NoFirmware;
            var state = [_]u32{ CLOCK_V3D, 1 };
            if (!mailbox.ask(TAG_SET_CLOCK_STATE, &state)) return error.NoFirmware;
            var rate = [_]u32{ CLOCK_V3D, most[1], 0 };
            if (!mailbox.ask(TAG_SET_CLOCK_RATE, &rate)) return error.NoFirmware;

            exec.kprintf(gpu.sys, "v3d: its SMS\n", .{});
            reg(gpu.sms + regs.SMS_TEE_CS).* = regs.SMS_CLEAR_POWER_OFF;
            if (!gpu.waitSms(regs.SMS_TEE_CS, isIdle)) return error.NoSms;
        }
        exec.kprintf(gpu.sys, "v3d: its reset through the SMS\n", .{});
        reg(gpu.sms + regs.SMS_REE_CS).* = regs.SMS_RESET;
        if (!gpu.waitSms(regs.SMS_REE_CS, isPastReset)) return error.NoSms;

        exec.kprintf(gpu.sys, "v3d: ready\n", .{});
        // Whenever the texture cache is flushed, all of it is.
        gpu.coreWrite(regs.CTL_L2TFLSTA, 0);
        gpu.coreWrite(regs.CTL_L2TFLEND, ~@as(u32, 0));
    }

    fn waitSms(gpu: *const Gpu, offset: usize, comptime done: fn (u32) bool) bool {
        const until = hardware.systimer.uptimeUs() + sms_wait_us;
        while (hardware.systimer.uptimeUs() < until) {
            if (done(reg(gpu.sms + offset).* & regs.SMS_STATE_MASK)) return true;
        }
        return false;
    }

    /// What it says it is: only once it is powered up.
    pub fn identify(gpu: *const Gpu) Ident {
        const hub1 = gpu.hubRead(regs.HUB_IDENT1);
        const hub2 = gpu.hubRead(regs.HUB_IDENT2);
        const hub3 = gpu.hubRead(regs.HUB_IDENT3);
        const core1 = gpu.coreRead(regs.CTL_IDENT1);
        const mmu = gpu.hubRead(regs.MMU_DEBUG_INFO);
        return .{
            .version = hub1 & 0xF,
            .revision = hub1 >> 4 & 0xF,
            .cores = hub1 >> 8 & 0xF,
            .with_tfu = hub1 & 1 << 17 != 0,
            .with_mmu = hub2 & 1 << 8 != 0,
            .ip_revision = hub3 >> 8 & 0xFF,
            .slices = core1 >> 4 & 0xF,
            .qpus_per_slice = core1 >> 8 & 0xF,
            .tmus = core1 >> 12 & 0xF,
            // In units of 8 KiB (Mesa's v3d_device_info.c).
            .vpm_kib = (core1 >> 28 & 0xF) * 8,
            .physical_bits = 30 + (mmu >> 8 & 0xF),
            .virtual_bits = 30 + (mmu >> 4 & 0xF),
        };
    }
};

fn isIdle(state: u32) bool {
    return state == regs.SMS_IDLE;
}

fn isPastReset(state: u32) bool {
    return state != regs.SMS_ISOLATING_FOR_RESET and state != regs.SMS_RESETTING;
}

/// The firmware's mailbox with a buffer to ask through.
const Mailbox = struct {
    sys: *ExecBase,
    at: usize,
    memory: *anyopaque,
    buffer: *align(videocore.buffer_bytes) videocore.Buffer,

    const bytes = 2 * videocore.buffer_bytes;

    fn open(gpu: *const Gpu) ?Mailbox {
        const memory = gpu.sys.AllocMem(bytes, exec.MEMF_DMA) orelse return null;
        const buffer = videocore.bufferIn(memory) orelse {
            gpu.sys.FreeMem(memory, bytes);
            return null;
        };
        return .{ .sys = gpu.sys, .at = gpu.mailbox, .memory = memory, .buffer = buffer };
    }

    fn close(mailbox: *Mailbox) void {
        mailbox.sys.FreeMem(mailbox.memory, bytes);
    }

    fn ask(mailbox: *Mailbox, tag: u32, value: []u32) bool {
        return videocore.call(mailbox.sys, mailbox.at, mailbox.buffer, tag, value);
    }
};
