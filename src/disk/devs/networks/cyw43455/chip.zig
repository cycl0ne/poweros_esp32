// SPDX-License-Identifier: MIT
//! The chip's cores and RAM, for cyw43455.device: what the firmware is
//! loaded into and started on, as Linux's brcmfmac does it for a chip
//! whose firmware runs on an ARM Cortex-R4.
//!
//! **A core's wrapper.** Every core on the backplane has a wrapper 1 MiB
//! above its registers, whose IOCTL register holds its clock and the
//! core's own control bits, and whose RESET_CTL holds it in reset. A
//! core is disabled by putting it in reset with its clock forced on, and
//! reset by disabling it, letting the reset go, and leaving its clock on
//! with the bits it should run with (`resetCore`).
//!
//! **Passive and active.** The firmware is loaded while the ARM is held
//! halted in reset and the 802.11 core's PHY held too (`setPassive`):
//! the ARM's RAM (its TCM) is the host's to write. It is started by
//! writing its reset vector - the firmware's first word - to address 0,
//! and letting the ARM out of reset without the halt (`setActive`).
//!
//! **The RAM** is at 0x19_8000 on the CYW43455, as big as the ARM's
//! banks add up to; the firmware goes at its start and the NVRAM at its
//! end, where the firmware looks for it.

const host_file = @import("host.zig");
const sdio = @import("sdio.zig");
const backplane = @import("backplane.zig");
const Error = host_file.Error;
const Backplane = backplane.Backplane;
const Chip = backplane.Chip;
const Core = backplane.Core;

/// A wrapper's registers.
const WRAP_IOCTL = 0x408;
const WRAP_RESET_CTL = 0x800;
const IOCTL_CLK: u32 = 0x0001;
const IOCTL_FGC: u32 = 0x0002;
const RESET_CTL_RESET: u32 = 0x0001;
/// The ARM's halt, and the 802.11 core's PHY clock and reset, in their
/// wrappers' IOCTL.
const IOCTL_CPUHALT: u32 = 0x0020;
const IOCTL_PHYCLOCKEN: u32 = 0x0004;
const IOCTL_PHYRESET: u32 = 0x0008;

/// The ARM Cortex-R4's registers: its capabilities - how many TCM banks
/// it has - and a bank's size, by its index.
const CR4_CAP = 0x04;
const CR4_BANKIDX = 0x40;
const CR4_BANKINFO = 0x44;
const CR4_TCBANB_MASK: u32 = 0xF;
const CR4_TCBBNB_MASK: u32 = 0xF0;
const CR4_BSZ_MASK: u32 = 0x7F;
const CR4_BSZ_MULT: u32 = 8192;
const CR4_BLK_1K: u32 = 0x200;

/// Where the CYW43455's RAM starts on the backplane.
pub const ram_base: u32 = 0x19_8000;

/// How often a reset is let go of before it is taken as stuck.
const release_tries = 50;
const release_wait_us = 50;

/// Core `core` held in reset with its clock forced on and `reset` in its
/// control bits - `prereset` while it is put there.
fn disableCore(bp: *Backplane, core: *const Core, prereset: u32, reset: u32, wait: sdio.Wait, context: *anyopaque) Error!void {
    const ioctl = core.wrap + WRAP_IOCTL;
    const reset_ctl = core.wrap + WRAP_RESET_CTL;
    if (try backplane.read32(bp, reset_ctl) & RESET_CTL_RESET == 0) {
        try backplane.write32(bp, ioctl, prereset | IOCTL_FGC | IOCTL_CLK);
        _ = try backplane.read32(bp, ioctl);
        try backplane.write32(bp, reset_ctl, RESET_CTL_RESET);
        wait(context, 20);
        var tries: u32 = 0;
        while (try backplane.read32(bp, reset_ctl) != RESET_CTL_RESET and tries < release_tries) : (tries += 1) {
            wait(context, release_wait_us);
        }
    }
    try backplane.write32(bp, ioctl, reset | IOCTL_FGC | IOCTL_CLK);
    _ = try backplane.read32(bp, ioctl);
}

/// Core `core` disabled, then let out of reset with its clock on and
/// `postreset` in its control bits.
fn resetCore(bp: *Backplane, core: *const Core, prereset: u32, reset: u32, postreset: u32, wait: sdio.Wait, context: *anyopaque) Error!void {
    try disableCore(bp, core, prereset, reset, wait, context);
    const reset_ctl = core.wrap + WRAP_RESET_CTL;
    var tries: u32 = 0;
    while (try backplane.read32(bp, reset_ctl) & RESET_CTL_RESET != 0 and tries < release_tries) : (tries += 1) {
        try backplane.write32(bp, reset_ctl, 0);
        wait(context, release_wait_us);
    }
    const ioctl = core.wrap + WRAP_IOCTL;
    try backplane.write32(bp, ioctl, postreset | IOCTL_CLK);
    _ = try backplane.read32(bp, ioctl);
}

/// The ARM halted in reset and the 802.11 core's PHY with it, so the RAM
/// can be written. False for a chip without the cores.
pub fn setPassive(bp: *Backplane, chip: *const Chip, wait: sdio.Wait, context: *anyopaque) Error!bool {
    const arm = chip.core(backplane.CORE_ARM_CR4) orelse return false;
    const d11 = chip.core(backplane.CORE_80211) orelse return false;
    const halted = try backplane.read32(bp, arm.wrap + WRAP_IOCTL) & IOCTL_CPUHALT;
    try resetCore(bp, arm, halted, IOCTL_CPUHALT, IOCTL_CPUHALT, wait, context);
    try disableCore(bp, d11, IOCTL_PHYRESET | IOCTL_PHYCLOCKEN, IOCTL_PHYCLOCKEN, wait, context);
    return true;
}

/// The ARM started at `reset_vector`: the SDIO core's interrupts cleared,
/// the vector written to address 0, the ARM let out of reset unhalted.
pub fn setActive(bp: *Backplane, chip: *const Chip, reset_vector: u32, wait: sdio.Wait, context: *anyopaque) Error!void {
    const sdio_core = chip.core(backplane.CORE_SDIO_DEV).?;
    try backplane.write32(bp, sdio_core.base + SD_INTSTATUS, 0xFFFF_FFFF);
    try backplane.write32(bp, 0, reset_vector);
    try resetCore(bp, chip.core(backplane.CORE_ARM_CR4).?, IOCTL_CPUHALT, 0, 0, wait, context);
}

/// The SDIO core's registers: its interrupts, the host's mask of them,
/// and the mailboxes between host and firmware.
pub const SD_INTSTATUS = 0x20;
pub const SD_HOSTINTMASK = 0x24;
pub const SD_TOSBMAILBOX = 0x40;
pub const SD_TOHOSTMAILBOX = 0x44;
pub const SD_TOSBMAILBOXDATA = 0x48;
pub const SD_TOHOSTMAILBOXDATA = 0x4C;

/// How big the ARM's RAM is: its banks added up.
pub fn ramSize(bp: *Backplane, chip: *const Chip) Error!u32 {
    const arm = chip.core(backplane.CORE_ARM_CR4) orelse return 0;
    const caps = try backplane.read32(bp, arm.base + CR4_CAP);
    const banks = (caps & CR4_TCBANB_MASK) + ((caps & CR4_TCBBNB_MASK) >> 4);
    var size: u32 = 0;
    for (0..banks) |index| {
        try backplane.write32(bp, arm.base + CR4_BANKIDX, @intCast(index));
        const info = try backplane.read32(bp, arm.base + CR4_BANKINFO);
        const block: u32 = if (info & CR4_BLK_1K != 0) CR4_BSZ_MULT >> 3 else CR4_BSZ_MULT;
        size += ((info & CR4_BSZ_MASK) + 1) * block;
    }
    return size;
}

/// The most bytes one command moves: 256 of function 1's blocks.
const piece_bytes = 256 * 64;

/// `buffer` written to the backplane from `address` on, or read from it:
/// a window at a time, each in whole blocks of function 1 and the bytes
/// left over.
pub fn copy(bp: *Backplane, write: bool, address: u32, buffer: []u8) Error!void {
    var at = address;
    var done: usize = 0;
    while (done < buffer.len) {
        const offset = at & 0x7FFF;
        const in_window: usize = 0x8000 - offset;
        const left = buffer.len - done;
        var length = @min(left, in_window, piece_bytes);
        if (length >= 64) length -= length % 64;
        try backplane.access(bp, write, at, buffer[done..][0..length]);
        at += @intCast(length);
        done += length;
    }
}
