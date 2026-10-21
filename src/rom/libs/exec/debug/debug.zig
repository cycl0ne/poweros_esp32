// SPDX-License-Identifier: MPL-2.0
//! Debug: the machine stopped, and the ROM debugger given the console.

const _debug = @import("_debug.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Stops the machine and gives the console to the ROM debugger.
///
/// SYNOPSIS:
/// ```zig
/// fn Debug(base: *ExecBase, flags: u32) void
/// ```
///
/// SINCE: 1.0. LVO -476.
///
/// INPUTS:
/// - `flags` - none are defined; 0.
///
/// RESULT:
/// Nothing. It comes back when the debugger is told to go on, with the
/// machine as it was found - the interrupt level included.
///
/// BEHAVIOR:
/// Interrupts are masked for as long as the debugger has the machine, so
/// nothing else runs: no task switch, no timer, no driver. It allocates
/// nothing, opens nothing and calls through no jump table, because a
/// debugger that needs a working system is no use when the system is
/// what stopped working.
///
/// It talks on both raw ports at once - UART0 and the chip's own USB
/// port - and takes a character from whichever has one, because which
/// cable is plugged in is not something a stopped machine can ask.
///
/// Once it has the machine it moves to a stack of its own, so a caller's
/// stack that ran past its end, or has little room left, carries none of
/// its work; one that does not look sound is said so. Among its commands
/// are exec's lists - the tasks, libraries, devices, resources, public
/// ports and semaphores, and which task holds which semaphore - read the
/// way `s3>` reads them but with none of their locks taken, since the code
/// it stopped may hold one, and every node checked before it is followed.
///
/// CONTEXT:
/// - Waits: never. It spins on the ports.
/// - Interrupts: it may be called from one, and from a trap.
/// - Locks: none needed; nothing else runs while it has the machine.
/// - Process: any task, or none at all.
///
/// NOTES:
/// A dead-end alert offers the debugger for a few seconds before it
/// halts, and a breakpoint, a watchpoint or a step set in it comes back
/// to it: the other ways in.
///
/// SEE ALSO:
/// `Alert`, `AlertAt`, `ReadLog`
///
/// EXAMPLES:
/// ```zig
/// if (something_impossible) sys.Debug(0);
/// ```
pub fn Debug(base: *ExecBase, flags: u32) void {
    _ = base;
    _ = flags;
    _debug.enter(.asked, null, 0);
}
