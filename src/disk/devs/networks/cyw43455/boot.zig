// SPDX-License-Identifier: MIT
//! The chip's firmware started, for cyw43455.device: what Linux's
//! brcmfmac does between finding the chip and speaking to its firmware,
//! in its order.
//!
//! **Before the firmware.** The ARM held (chip.zig's `setPassive`), the
//! SDIO core kept awake (KSO), an SDIO reset made a reset of the whole
//! chip (WLANRESET in the card's own CCCR register), and a backplane
//! reset made to reload the PMU's settings.
//!
//! **The download.** On the ALP clock: the firmware written to the start
//! of the RAM, the NVRAM image to its end, and the ARM started at the
//! firmware's first word.
//!
//! **After.** The HT clock - the PLL's - asked for and forced on, the
//! firmware told the host's protocol version in its mailbox, and
//! function 2 enabled, which the firmware makes ready once it runs. Then
//! the interrupts the host wants from the SDIO core, the FIFO's
//! watermarks for the CYW43455, and, where the firmware turned the chip's
//! save-restore engine on, what the chip needs for it: the HT clock kept
//! forced, so the chip is never let sleep.
//!
//! **The CLM blob** - which channels and powers each country allows - is
//! the firmware's to be given once it answers commands: in chunks, each
//! with a header that says whether it is the first or the last
//! (`loadClm`).

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const _cyw = @import("_cyw43455.zig");
const host_file = @import("host.zig");
const sdio = @import("sdio.zig");
const backplane = @import("backplane.zig");
const chip_file = @import("chip.zig");
const firmware = @import("firmware.zig");
const sdpcm = @import("sdpcm.zig");
const bcdc = @import("bcdc.zig");
const CywBase = _cyw.CywBase;
const Error = host_file.Error;
const DEVICE_NAME = _cyw.DEVICE_NAME;

/// Function 1's registers past the backplane window: the FIFO's
/// watermark, the device's control, the message-busy control, the
/// wake-up control, and the sleep control and status.
const F1_WATERMARK = 0x10008;
const F1_DEVICE_CTL = 0x10009;
const F1_MESBUSYCTRL = 0x1001D;
const F1_WAKEUPCTRL = 0x1001E;
const F1_SLEEPCSR = 0x1001F;
const DEVCTL_F2WM_ENAB: u8 = 0x10;
const MESBUSYCTRL_ENAB: u8 = 0x80;
const WAKEUPCTRL_HTWAIT: u8 = 1 << 1;
const SLEEPCSR_KSO: u8 = 0x01;
/// The CYW43455's watermarks, Linux's.
const watermark_43455: u8 = 0x60;
const mesbusy_43455: u8 = 0x50;

/// The card's own CCCR registers: its capabilities and its control.
const CCCR_BRCM_CARDCAP = 0xF0;
const CCCR_BRCM_CARDCTRL = 0xF1;
const CARDCAP_CMD14_SUPPORT: u8 = 1 << 1;
const CARDCAP_CMD14_EXT: u8 = 1 << 2;
const CARDCTRL_WLANRESET: u8 = 1 << 1;

/// chipcommon's PMU: its control, its capabilities, and its chip
/// control registers by address and data.
const CC_CAPABILITIES = 0x04;
const CC_CAP_PMU: u32 = 1 << 28;
const PMU_CONTROL = 0x600;
const PMU_CAPABILITIES = 0x604;
const PMU_CHIPCONTROL_ADDR = 0x650;
const PMU_CHIPCONTROL_DATA = 0x654;
const PMU_CTL_RES_RELOAD: u32 = 0x2 << 13;
const PMU_REV_MASK: u32 = 0xFF;
/// Chip control register 3's save-restore engine on the CYW43455.
const PMU_CC3_SR_ENGINE: u32 = 1 << 2;

/// The CLM blob's chunks, Linux's size, and their header: the flags - the
/// first chunk, the last, the downloader's version - the blob's kind, the
/// chunk's length, and a CRC the firmware is not given.
const clm_chunk = 1400;
const DLOAD_HEADER = 12;
const DL_BEGIN: u16 = 0x0002;
const DL_END: u16 = 0x0004;
const DLOAD_HANDLER_VER: u16 = 1 << 12;
const DL_TYPE_CLM: u16 = 2;

/// How long a clock may take to come: Linux's second.
const clock_tries = 200;
const clock_wait_us = 5_000;

fn say(sys: *ExecBase, comptime text: [:0]const u8) void {
    exec.kprintf(sys, "%s: " ++ text ++ "\n", .{@as([*:0]const u8, DEVICE_NAME)});
}

fn sayError(sys: *ExecBase, comptime text: [:0]const u8, err: Error) void {
    exec.kprintf(sys, "%s: " ++ text ++ ": %s\n", .{ @as([*:0]const u8, DEVICE_NAME), @as([*:0]const u8, @errorName(err)) });
}

/// A whole file read into memory from AllocVec, or null - said on the
/// log when it is not there.
fn readFile(base: *CywBase, name: [*:0]const u8) ?[]u8 {
    const sys = base.sys_base;
    const dl = base.dos_base.?;
    const file = dl.Open(name, dos.MODE_OLDFILE) orelse {
        exec.kprintf(sys, "%s: no %s\n", .{ @as([*:0]const u8, DEVICE_NAME), name });
        return null;
    };
    defer _ = dl.Close(file);
    var fib: dos.FileInfoBlock = .{};
    if (!dl.ExamineFH(file, &fib) or fib.size == 0) return null;
    const size: usize = @intCast(fib.size);
    const memory = sys.AllocVec(size, exec.MEMF_ANY) orelse return null;
    const bytes: [*]u8 = @ptrCast(memory);
    if (dl.Read(file, bytes, @intCast(size)) != @as(isize, @intCast(size))) {
        sys.FreeVec(memory);
        return null;
    }
    return bytes[0..size];
}

/// The chip's firmware loaded and started, function 2 ready. False, said
/// on the log, if any of it fails.
pub fn start(base: *CywBase) bool {
    const sys = base.sys_base;
    const code = readFile(base, firmware.name_code) orelse return false;
    defer sys.FreeVec(code.ptr);
    const text = readFile(base, firmware.name_nvram) orelse return false;
    defer sys.FreeVec(text.ptr);
    const image_memory = sys.AllocVec(firmware.imageBound(text), exec.MEMF_ANY) orelse return false;
    defer sys.FreeVec(image_memory);
    const image_bytes: [*]u8 = @ptrCast(image_memory);
    const image = image_bytes[0..firmware.nvramImage(text, image_bytes[0..firmware.imageBound(text)])];
    if (code.len < 4) return false;

    prepare(base) catch |err| {
        sayError(sys, "the chip cannot be prepared", err);
        return false;
    };
    download(base, code, image) catch |err| {
        sayError(sys, "the firmware cannot be loaded", err);
        return false;
    };
    exec.kprintf(sys, "%s: firmware of %u bytes and NVRAM of %u loaded into %u KiB of RAM, ARM started\n", .{
        @as([*:0]const u8, DEVICE_NAME), @as(u32, @intCast(code.len)), @as(u32, @intCast(image.len)), base.ram_size / 1024,
    });
    framesUp(base) catch |err| {
        sayError(sys, "the firmware does not come up", err);
        return false;
    };
    return true;
}

/// The ARM held, the SDIO core kept awake, the card's reset made the
/// chip's, the PMU's settings reloaded at a backplane reset; and the
/// RAM's size and the PMU's revision read.
fn prepare(base: *CywBase) Error!void {
    const bp = &base.backplane;
    const card = &bp.card;
    const chip = &base.chip;
    if (!try chip_file.setPassive(bp, chip, &_cyw.waitOn, base)) return error.Failed;
    base.ram_size = try chip_file.ramSize(bp, chip);
    if (base.ram_size == 0) return error.Failed;
    const sleep = try sdio.read8(card, 1, F1_SLEEPCSR);
    if (sleep & SLEEPCSR_KSO == 0) try sdio.write8(card, 1, F1_SLEEPCSR, sleep | SLEEPCSR_KSO);
    const control = try sdio.read8(card, 0, CCCR_BRCM_CARDCTRL);
    try sdio.write8(card, 0, CCCR_BRCM_CARDCTRL, control | CARDCTRL_WLANRESET);
    const cc = backplane.CHIPCOMMON;
    const pmu = try backplane.read32(bp, cc + PMU_CONTROL);
    try backplane.write32(bp, cc + PMU_CONTROL, pmu | PMU_CTL_RES_RELOAD);
    if (try backplane.read32(bp, cc + CC_CAPABILITIES) & CC_CAP_PMU != 0) {
        base.pmu_rev = try backplane.read32(bp, cc + PMU_CAPABILITIES) & PMU_REV_MASK;
    }
}

/// The firmware and the NVRAM image written on the ALP clock, and the ARM
/// started at the firmware's reset vector; the clock request dropped
/// after, as Linux does.
fn download(base: *CywBase, code: []u8, image: []u8) Error!void {
    const bp = &base.backplane;
    try requestClock(base, backplane.ALP_AVAIL_REQ, backplane.ALP_AVAIL);
    try chip_file.copy(bp, true, chip_file.ram_base, code);
    try chip_file.copy(bp, true, chip_file.ram_base + base.ram_size - @as(u32, @intCast(image.len)), image);
    const reset_vector = std.mem.readInt(u32, code[0..4], .little);
    try chip_file.setActive(bp, &base.chip, reset_vector, &_cyw.waitOn, base);
    try sdio.write8(&bp.card, 1, backplane.CHIPCLKCSR, 0);
}

/// Function 1's clock register asked for `request`, and waited on until
/// `available` shows.
fn requestClock(base: *CywBase, request: u8, available: u8) Error!void {
    const card = &base.backplane.card;
    try sdio.write8(card, 1, backplane.CHIPCLKCSR, request);
    for (0..clock_tries) |_| {
        if (try sdio.read8(card, 1, backplane.CHIPCLKCSR) & available != 0) return;
        base.delay(clock_wait_us);
    }
    return error.Timeout;
}

/// The HT clock up and forced, the protocol's version in the firmware's
/// mailbox, function 2 enabled and ready, the SDIO core's interrupts and
/// watermarks set; and save-restore set up where the firmware turned it
/// on, the clock put back where it did not.
fn framesUp(base: *CywBase) Error!void {
    const sys = base.sys_base;
    const bp = &base.backplane;
    const card = &bp.card;
    const sdio_core = base.chip.core(backplane.CORE_SDIO_DEV).?;
    try requestClock(base, backplane.HT_AVAIL_REQ, backplane.HT_AVAIL);
    const saved = try sdio.read8(card, 1, backplane.CHIPCLKCSR);
    try sdio.write8(card, 1, backplane.CHIPCLKCSR, saved | backplane.FORCE_HT);
    try backplane.write32(bp, sdio_core.base + chip_file.SD_TOSBMAILBOXDATA, sdpcm.SDPCM_PROT_VERSION << sdpcm.SMB_DATA_VERSION_SHIFT);
    sdio.enable(card, 2, &_cyw.waitOn, base) catch |err| {
        const mailbox = backplane.read32(bp, sdio_core.base + chip_file.SD_TOHOSTMAILBOXDATA) catch 0;
        exec.kprintf(sys, "%s: function 2 never ready, the firmware's mailbox %08x\n", .{ @as([*:0]const u8, DEVICE_NAME), mailbox });
        return err;
    };
    try backplane.write32(bp, sdio_core.base + chip_file.SD_HOSTINTMASK, sdpcm.host_int_mask);
    try sdio.write8(card, 1, F1_WATERMARK, watermark_43455);
    const devctl = try sdio.read8(card, 1, F1_DEVICE_CTL);
    try sdio.write8(card, 1, F1_DEVICE_CTL, devctl | DEVCTL_F2WM_ENAB);
    try sdio.write8(card, 1, F1_MESBUSYCTRL, mesbusy_43455 | MESBUSYCTRL_ENAB);
    if (try saveRestore(base)) {
        const wake = try sdio.read8(card, 1, F1_WAKEUPCTRL);
        try sdio.write8(card, 1, F1_WAKEUPCTRL, wake | WAKEUPCTRL_HTWAIT);
        try sdio.write8(card, 0, CCCR_BRCM_CARDCAP, CARDCAP_CMD14_SUPPORT | CARDCAP_CMD14_EXT);
        try sdio.write8(card, 1, backplane.CHIPCLKCSR, backplane.FORCE_HT);
        base.save_restore = 1;
    } else {
        try sdio.write8(card, 1, backplane.CHIPCLKCSR, saved);
    }
}

/// Whether the firmware turned the chip's save-restore engine on: a PMU
/// of revision 17 or later, bit 2 of its chip control register 3.
fn saveRestore(base: *CywBase) Error!bool {
    if (base.pmu_rev < 17) return false;
    const bp = &base.backplane;
    const cc = backplane.CHIPCOMMON;
    try backplane.write32(bp, cc + PMU_CHIPCONTROL_ADDR, 3);
    return try backplane.read32(bp, cc + PMU_CHIPCONTROL_DATA) & PMU_CC3_SR_ENGINE != 0;
}

/// The CLM blob given to the firmware, which has none of its own: whether
/// it took it. False, said on the log with the firmware's status, if not.
pub fn loadClm(base: *CywBase) bool {
    const sys = base.sys_base;
    const blob = readFile(base, firmware.name_clm) orelse return false;
    defer sys.FreeVec(blob.ptr);
    var chunk: [DLOAD_HEADER + clm_chunk]u8 = undefined;
    var flags = DL_BEGIN | DLOAD_HANDLER_VER;
    var at: usize = 0;
    while (at < blob.len) {
        const length = @min(blob.len - at, clm_chunk);
        if (at + length == blob.len) flags |= DL_END;
        std.mem.writeInt(u16, chunk[0..2], flags, .little);
        std.mem.writeInt(u16, chunk[2..4], DL_TYPE_CLM, .little);
        std.mem.writeInt(u32, chunk[4..8], @intCast(length), .little);
        std.mem.writeInt(u32, chunk[8..12], 0, .little);
        @memcpy(chunk[DLOAD_HEADER..][0..length], blob[at..][0..length]);
        const status = bcdc.setVar(base, "clmload", chunk[0 .. DLOAD_HEADER + length]) catch |err| {
            sayError(sys, "the CLM blob cannot be loaded", err);
            return false;
        };
        if (status != 0) {
            var result: [4]u8 = @splat(0);
            _ = bcdc.getVar(base, "clmload_status", &result) catch {};
            exec.kprintf(sys, "%s: the firmware refuses the CLM blob: %d, its status %u\n", .{
                @as([*:0]const u8, DEVICE_NAME), status, std.mem.readInt(u32, &result, .little),
            });
            return false;
        }
        flags &= ~DL_BEGIN;
        at += length;
    }
    return true;
}
