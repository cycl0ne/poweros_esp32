// SPDX-License-Identifier: MPL-2.0
//! How the Compute Module 4 restarts itself: through the watchdog in the
//! chip's power manager, as Linux's bcm2835_wdt does - the firmware has no
//! PSCI to ask (`boards.before_reset`).
//!
//! The watchdog counts PM_WDOG down in ticks of about 15 µs, and at nought
//! does what PM_RSTC's WRCFG says: a full reset of the chip, after which
//! the bootloader starts again - from the eMMC, or from the PC over USB
//! while the board's BOOT switch is on. Both registers take a write only
//! with the power manager's password in their top byte.
//!
//! **The firmware is told first** (NOTIFY_REBOOT), as Linux tells it
//! before every restart (its raspberrypi firmware driver): only then does
//! the flag for a tried start (SET_REBOOT_FLAGS, which C:Reboot TRYBOOT
//! and the ROM shell's `reboot tryboot` set) reach the bootloader -
//! untold, the next start is a plain one. The bootloader clears it again,
//! so a tried start is one start. The notice goes in memory the firmware
//! reads, taken while exec is up (`keepNotice`), since a reset has no
//! exec to ask: past the mailbox's lock, which nothing that runs after a
//! reset is asked for needs, and past the caches by hand. A firmware that
//! does not answer in a second is reset all the same.
//!
//! **Which partition** a tried start is from is autoboot.txt's
//! `[tryboot]` section, which the bootloader in the module's EEPROM reads
//! as a condition from its 2022-10-18 release on. Before that it reads
//! the section as if it were `[all]`, and starts from the last
//! `boot_partition` the file names, tried or not; the tried start is told
//! as one all the same. A bootloader from 2022-03-10 on renews itself
//! from the eMMC: pieeprom.upd, a release's image with the module's own
//! configuration in it, and pieeprom.sig, its SHA-256 and time, in the
//! partition it starts from - this module's went from 2022-04-26 to
//! 2026-10-30 so.

const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const hwcpu = sdk.hardware.cpu;
const exec = sdk.exec;
const videocore = sdk.hardware.videocore;
const ExecBase = sdk.interface.exec.ExecBase;
const system = @import("system.zig");
const domains = @import("domains.zig");

const PM_RSTC: usize = 0x1C;
const PM_WDOG: usize = 0x24;
const PM_PASSWORD: u32 = 0x5A00_0000;
const PM_RSTC_WRCFG_CLR: u32 = 0xFFFF_FFCF;
const PM_RSTC_WRCFG_FULL_RESET: u32 = 0x20;

const MAIL0_READ: usize = 0x00;
const MAIL0_STATUS: usize = 0x18;
const MAIL1_WRITE: usize = 0x20;
const MAIL1_STATUS: usize = 0x38;
const STATUS_FULL: u32 = 1 << 31;
const STATUS_EMPTY: u32 = 1 << 30;
const CHANNEL_PROPERTY: u32 = 8;

/// Linux's RPI_FIRMWARE_NOTIFY_REBOOT: the machine is about to restart.
const TAG_NOTIFY_REBOOT: u32 = 0x0003_0048;

/// Where the notice is written; null until exec has given the memory, and
/// on a start over USB, where the firmware answers nothing of the kind
/// (`domains.zig`).
var notice: ?*align(videocore.buffer_bytes) videocore.Buffer = null;

/// The memory for the notice, MEMF_DMA, taken once exec is up and kept
/// (`boards.reset_notice`).
pub fn keepNotice(sys: *ExecBase) void {
    if (system.boot_mode == domains.BOOT_MODE_RPIBOOT) return;
    const memory = sys.AllocMem(2 * videocore.buffer_bytes, exec.MEMF_DMA) orelse return;
    notice = videocore.bufferIn(memory);
}

/// The machine reset by the watchdog, ten ticks from now, the firmware
/// told first; it does not come back.
pub fn reset() void {
    tellFirmware();
    reg(system.power_manager + PM_WDOG).* = PM_PASSWORD | 10;
    const rstc = reg(system.power_manager + PM_RSTC).*;
    reg(system.power_manager + PM_RSTC).* = PM_PASSWORD | (rstc & PM_RSTC_WRCFG_CLR) | PM_RSTC_WRCFG_FULL_RESET;
    while (true) asm volatile ("wfi");
}

/// NOTIFY_REBOOT sent on the property channel and its answer waited for,
/// a second at the most.
fn tellFirmware() void {
    const buffer = notice orelse return;
    _ = videocore.message(buffer, TAG_NOTIFY_REBOOT, &.{});
    pushOut(buffer);
    const mailbox = system.mailbox;
    const until = hwcpu.time() + hwcpu.counterFrequency();
    while (reg(mailbox + MAIL1_STATUS).* & STATUS_FULL != 0) {
        if (hwcpu.time() > until) return;
    }
    const sent = videocore.busAddress(mailbox, @intFromPtr(buffer)) | CHANNEL_PROPERTY;
    reg(mailbox + MAIL1_WRITE).* = sent;
    while (hwcpu.time() <= until) {
        if (reg(mailbox + MAIL0_STATUS).* & STATUS_EMPTY == 0) {
            if (reg(mailbox + MAIL0_READ).* == sent) return;
        }
    }
}

/// The notice's line written back to memory and dropped from the caches,
/// so the firmware reads what was written.
fn pushOut(buffer: *align(videocore.buffer_bytes) videocore.Buffer) void {
    asm volatile (
        \\dc civac, %[at]
        \\dsb sy
        :
        : [at] "r" (@intFromPtr(buffer)),
        : .{ .memory = true });
}
