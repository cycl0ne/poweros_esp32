// SPDX-License-Identifier: MPL-2.0
//! AlertAt: raises an alert for a place the caller names, with a line of
//! text - what a panic handler reports a failed check with.
//!
//! Like Alert it goes through nothing replaceable and allocates nothing.

const _interrupt = @import("_interrupt.zig");

const ExecBase = @import("../exec.zig").ExecBase;

/// Reports a problem found at a place the caller names, with what went
/// wrong in words, and for a dead end stops.
///
/// SYNOPSIS:
/// ```zig
/// fn AlertAt(_: *ExecBase, alert_num: u32, where: usize, text: ?[*:0]const u8) void
/// ```
///
/// SINCE: 1.0. LVO -466.
///
/// INPUTS:
/// - `alert_num` - what went wrong, with `AT_DeadEnd` set if the machine
///   cannot carry on.
/// - `where` - the Guru's second number: the address the trouble is about.
///   A return address or an exact program counter will do.
/// - `text` - a line saying what went wrong, or null for none.
///
/// RESULT:
/// Nothing, and for `AT_DeadEnd` it does not return at all.
///
/// BEHAVIOR:
/// `Alert` with two things added: the caller chooses the address instead
/// of being named itself, and the text is shown with the alert. The display
/// names the code `where` lies in - the ROM, or a file loaded from disk and
/// the offset into it.
///
/// A panic handler is the caller it is for: the address is the failed
/// check's, handed to the handler, and the text is the check's message.
///
/// CONTEXT:
/// - Waits: no, and it must not.
/// - Interrupts: safe.
/// - Locks: none taken, none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. `text` is only read, while the alert is shown.
///
/// NOTES:
/// The text is cut at 96 characters on the display. A caller without a
/// base finds exec through `AbsExecBase`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Alert`, `SetTrapCode`
///
/// EXAMPLES:
/// ```zig
/// sys.AlertAt(exec.AT_DeadEnd | exec.AN_ProgramPanic, ret_addr, "integer overflow");
/// ```
pub fn AlertAt(_: *ExecBase, alert_num: u32, where: usize, text: ?[*:0]const u8) void {
    _interrupt.alertAt(alert_num, where, text);
}
