// SPDX-License-Identifier: MPL-2.0
//! SetPrompt: sets the running CLI's prompt.

const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");

/// Sets the running CLI's prompt.
///
/// SYNOPSIS:
/// ```zig
/// fn SetPrompt(db: *DosBase, name: [*:0]const u8) bool
/// ```
///
/// SINCE: 1.0. LVO -296.
///
/// INPUTS:
/// - `name` - the new text; it may point into the CLI's own buffer.
///
/// RESULT:
/// True when it was set. False, with IoErr, when there is no CLI
/// (ERROR_OBJECT_WRONG_TYPE) or the text doesn't fit
/// (ERROR_LINE_TOO_LONG).
///
/// BEHAVIOR:
/// The text is copied into the CLI's own buffer, which holds
/// CLI_MAX_PROMPT bytes with the NUL. A text that doesn't fit is
/// refused whole and the old one kept, rather than stored cut.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not safe; it reads and changes the running task's
///   Process.
/// - Forbid: not needed, and not taken; only the running process
///   touches these fields.
/// - Process: a CLI process; any other caller gets false.
///
/// OWNERSHIP:
/// The text is copied; `name` stays the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `GetPrompt`, `SetProgramName`
///
/// EXAMPLES:
/// ```zig
/// _ = dos_lib.SetPrompt("%N.%S> ");
/// ```
pub fn SetPrompt(db: *DosBase, name: [*:0]const u8) bool {
    return _process.setName(db, .prompt, name);
}
