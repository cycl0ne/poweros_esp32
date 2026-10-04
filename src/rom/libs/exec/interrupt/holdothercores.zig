// SPDX-License-Identifier: MPL-2.0
//! HoldOtherCores: the other cores held still, for what nothing may run
//! beside.

const _interrupt = @import("_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Holds the other cores still until `ReleaseOtherCores`.
///
/// SYNOPSIS:
/// ```zig
/// fn HoldOtherCores(base: *ExecBase) void
/// ```
///
/// SINCE: 1.4. LVO -508.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// Nothing: when it returns, every other core is parked.
///
/// BEHAVIOR:
/// Each other core is asked with its cross-core interrupt and parks in
/// internal RAM with its interrupts masked, calling nothing, so that none
/// of its instructions and none of its stack reach the caches or PSRAM;
/// this returns once all of them say so. What the caller does next may
/// suspend the caches - a flash write - or must see the machine still - the
/// ROM debugger. A core spinning with its interrupts masked parks from its
/// spin. Two cores holding at once: one wins, the other parks for it first.
///
/// With one core running, nothing is done.
///
/// CONTEXT:
/// - Waits: no - it spins until the others are parked.
/// - Interrupts: masked by the caller (Disable): an interrupt in between
///   would run code the held cores' state may not allow.
/// - Forbid: may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The other cores are the caller's until `ReleaseOtherCores`: as short as
/// a flash page or sector, since they do nothing meanwhile.
///
/// NOTES:
/// flash.device holds them around every erase and program.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `ReleaseOtherCores`, `Disable`
///
/// EXAMPLES:
/// ```zig
/// sys.Disable();
/// sys.HoldOtherCores();
/// const ok = spiflash.eraseSector(sector);
/// sys.ReleaseOtherCores();
/// sys.Enable();
/// ```
pub fn HoldOtherCores(_: *ExecBase) void {
    _interrupt.interrupt_hardware.hold_others();
}
