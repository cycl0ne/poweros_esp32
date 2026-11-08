// SPDX-License-Identifier: MPL-2.0
//! The watchdog in an AMD chipset, which watchdog.resource runs for
//! programs on an x86-64 machine that has one: a count of seconds which,
//! once it runs out without being started over, resets the machine. It
//! counts in the chipset, so a machine whose cores have stopped is reset
//! all the same.
//!
//! **Where it is.** The chipset is a function on PCI - its SMBus
//! controller, vendor 0x1022, device 0x790B - and from revision 0x51 its
//! watchdog is two registers in memory: its control word and its count, at
//! 0xFEB00000, or the same two at 0xFED80B00 in the chipset's own block of
//! registers where that block is switched on. Its power management
//! registers, at 0xFED80300 in that block, say whether the first window is
//! decoded (`DecodeEn`, bit 7, which lets the timer run as well), and
//! whether the watchdog is switched off and how fast it counts (the byte
//! at 3: bits 3:2 off, bits 1:0 the rate, 3 for once a second). An older
//! revision reaches the same registers through an index and a data port,
//! which this does not drive.
//!
//! **Its control word.** Bit 0 runs it; bit 1 says it ran out (written as
//! 1 it is cleared, and a reset leaves it standing, so the next start can
//! tell); bit 2 makes it turn the machine off instead of resetting it,
//! which is never wanted here; bit 3 says the firmware switched it off for
//! good; bit 7, written as 1, starts the count over. The run bit and the
//! restart are two writes. Bit 3 also reads as set while `DecodeEn`'s bit
//! is clear - which is how the firmware leaves it at every start - so it
//! means the firmware's doing only once that bit is set.
//!
//! **What is done when.** `find` finds the chipset and says what its
//! registers hold, the ran-out bit above all, so the line at start says
//! whether the last restart was the watchdog's - and clears that bit, by
//! writing the control word back as it was read, so the next start does
//! not say it again after a restart of another kind. That write leaves the
//! run bit as it was. Nothing else is written until a program arms it - so
//! that a fault in what is done here can never become a reset at every
//! start, which on a machine nobody is sitting at would leave nothing to
//! reach it with.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const reg = sdk.hardware.mmio.reg;
const reg8 = sdk.hardware.mmio.reg8;
const ExecBase = sdk.interface.exec.ExecBase;
const PCIBase = sdk.interface.pci.PCIBase;

const owner = sdk.resources.watchdog.WATCHDOGNAME;

/// The chipset's SMBus function, and the first revision whose watchdog is
/// in memory.
const VENDOR_AMD: u32 = 0x1022;
const DEVICE_SMBUS: u32 = 0x790B;
const REVISION_MMIO: u8 = 0x51;

/// The chipset's own block of registers, its power management registers
/// in it, and the watchdog's two windows.
const ACPI_MMIO: usize = 0xFED8_0000;
const PM: usize = ACPI_MMIO + 0x300;
const WDT_SECOND: usize = ACPI_MMIO + 0xB00;
const WDT: usize = 0xFEB0_0000;

/// The power management bytes.
const PM_DECODE_EN = 0x00;
const DECODE_WDT_TIMER_EN: u8 = 1 << 7;
const PM_DECODE_EN3 = 0x03;
const WATCHDOG_DISABLE: u8 = 0b11 << 2;
const WATCHDOG_FREQ: u8 = 0b11;
const WATCHDOG_FREQ_1HZ: u8 = 0b11;
const PM_ISA_CONTROL = 0x04;
const ISA_MMIO_EN: u8 = 1 << 1;

/// The watchdog's two registers, and the control word's bits.
const WDT_CONTROL = 0x00;
const WDT_COUNT = 0x04;
const CONTROL_RUN: u32 = 1 << 0;
const CONTROL_FIRED: u32 = 1 << 1;
const CONTROL_POWER_OFF: u32 = 1 << 2;
const CONTROL_DISABLED: u32 = 1 << 3;
const CONTROL_TRIGGER: u32 = 1 << 7;

/// The count is sixteen bits of seconds.
const max_seconds: u32 = 0xFFFF;
pub const max_ms: u32 = max_seconds * 1000;

/// What a register reads where nothing answers.
const nothing: u32 = 0xFFFF_FFFF;

/// The chipset found and said: the watchdog's registers, which ArmWatchdog
/// switches on, or 0 where there is no chipset whose watchdog this drives.
/// Its ran-out bit is cleared once said; nothing else is written. Said
/// only where there is a chipset of the kind, so a machine without one
/// starts as quietly as before.
pub fn find(sys: *ExecBase) usize {
    const lib = sys.OpenLibrary(pci.PCINAME, 1) orelse return 0;
    defer sys.CloseLibrary(lib);
    const base: *PCIBase = @ptrCast(lib);
    const smbus = base.FindPCIDevice(null, VENDOR_AMD, DEVICE_SMBUS) orelse return 0;
    if (smbus.revision < REVISION_MMIO) {
        exec.kprintf(sys, "%s: the chipset is revision %x, whose watchdog this does not drive\n", .{ owner, @as(u32, smbus.revision) });
        return 0;
    }

    const decode = reg8(PM + PM_DECODE_EN).*;
    const config = reg8(PM + PM_DECODE_EN3).*;
    const isa = reg8(PM + PM_ISA_CONTROL).*;
    // Its control word, from whichever window answers now.
    const window: usize = if (decode & DECODE_WDT_TIMER_EN != 0) WDT else if (isa & ISA_MMIO_EN != 0) WDT_SECOND else 0;
    const control: u32 = if (window != 0) reg(window + WDT_CONTROL).* else nothing;

    exec.kprintf(sys, "%s: the chipset's watchdog (revision %x), power management %x %x %x, control %x\n", .{
        owner, @as(u32, smbus.revision), @as(u32, decode), @as(u32, config), @as(u32, isa), control,
    });
    if (control == nothing) {
        exec.kprintf(sys, "%s:   its registers do not answer until it is armed\n", .{owner});
        return WDT;
    }
    if (decode & DECODE_WDT_TIMER_EN != 0 and control & CONTROL_DISABLED != 0) {
        exec.kprintf(sys, "%s:   the firmware switched it off\n", .{owner});
    }
    if (control & CONTROL_RUN != 0) exec.kprintf(sys, "%s:   it is running\n", .{owner});
    if (control & CONTROL_FIRED != 0) {
        exec.kprintf(sys, "%s:   the last restart was its own\n", .{owner});
        reg(window + WDT_CONTROL).* = control;
    }
    return WDT;
}

/// Its registers switched on, counting in seconds, a reset when the time
/// is up, `millis` rounded up to whole seconds, and running. False, with
/// it not running, where it is not there, the window cannot be switched
/// on, or the firmware switched it off for good.
pub fn arm(registers: usize, millis: u32) bool {
    if (registers == 0) return false;
    const decode = reg8(PM + PM_DECODE_EN);
    if (decode.* & DECODE_WDT_TIMER_EN == 0) decode.* = decode.* | DECODE_WDT_TIMER_EN;
    if (decode.* & DECODE_WDT_TIMER_EN == 0) return false;
    const config = reg8(PM + PM_DECODE_EN3);
    config.* = (config.* & ~(WATCHDOG_DISABLE | WATCHDOG_FREQ)) | WATCHDOG_FREQ_1HZ;

    const control = reg(registers + WDT_CONTROL);
    var word = control.*;
    if (word == nothing or word & CONTROL_DISABLED != 0) return false;
    // A reset, and the ran-out bit cleared by writing it back.
    word &= ~(CONTROL_POWER_OFF | CONTROL_TRIGGER);
    control.* = word;
    reg(registers + WDT_COUNT).* = (millis + 999) / 1000;
    word = control.* | CONTROL_RUN;
    control.* = word;
    control.* = word | CONTROL_TRIGGER;
    return true;
}

/// The count started over.
pub fn feed(registers: usize) void {
    if (registers == 0) return;
    const control = reg(registers + WDT_CONTROL);
    control.* = control.* | CONTROL_TRIGGER;
}

/// It stops counting; its registers stay switched on.
pub fn disarm(registers: usize) void {
    if (registers == 0) return;
    const control = reg(registers + WDT_CONTROL);
    const word = control.*;
    if (word == nothing) return;
    control.* = word & ~(CONTROL_RUN | CONTROL_TRIGGER);
}
