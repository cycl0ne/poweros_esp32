// SPDX-License-Identifier: MPL-2.0
//! ColdReboot: resets the machine. Interrupts go off first and stay off:
//! what follows is a reset, so there is nothing for an interrupt to return
//! to. exec sets the chip's software system reset itself, as it drives its
//! own raw port.

const ExecBase = @import("../exec.zig").ExecBase;

/// Resets the machine.
///
/// SYNOPSIS:
/// ```zig
/// fn ColdReboot(base: *ExecBase) noreturn
/// ```
///
/// SINCE: 1.0. LVO -400.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// It does not return.
///
/// BEHAVIOR:
/// Interrupts go off and the chip's software system reset is set. Nothing
/// is shut down first: **no file system is flushed**, no device is told, no
/// task is asked to finish. Anything that has to survive must be on the
/// medium before this is called.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe - it turns them off itself.
/// - Forbid: not needed. Nothing that follows cares.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated, and nothing is given back either.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Alert`
///
/// EXAMPLES:
/// ```zig
/// sys.ColdReboot();
/// ```
pub fn ColdReboot(base: *ExecBase) noreturn {
    base.iface().Disable();
    reset();
}

const hardware = @import("sdk").hardware;

/// The software system reset: SW_SYS_RST resets the whole chip. It does
/// not come back.
fn reset() noreturn {
    hardware.mmio.reg(hardware.rtc_cntl.OPTIONS0).* |= hardware.rtc_cntl.OPTIONS0_SW_SYS_RST;
    while (true) {}
}
