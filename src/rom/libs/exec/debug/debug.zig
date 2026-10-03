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
/// It runs on the stack of whoever called it, and looks at that stack
/// before it starts: a stack that is not sound is said so and the
/// machine halts, rather than the debugger faulting in its turn.
///
/// CONTEXT:
/// - Waits: never. It spins on the ports.
/// - Interrupts: it may be called from one, and from a trap.
/// - Forbid: not needed; nothing else runs while it has the machine.
/// - Process: any task, or none at all.
///
/// NOTES:
/// A dead-end alert offers the debugger for a few seconds before it
/// halts, which is the other way in. `todo/exec/03-debug-shell.md` has
/// breakpoints and the second core, which are not here.
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
