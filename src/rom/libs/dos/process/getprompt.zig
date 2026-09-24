// SPDX-License-Identifier: MPL-2.0
//! GetPrompt: copies the running CLI's prompt into a buffer.

const DosBase = @import("../dos_base.zig").DosBase;
const _process = @import("_process.zig");

/// Copies the running CLI's prompt into the caller's buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn GetPrompt(db: *DosBase, buffer: [*]u8, size: u32) bool
/// ```
///
/// SINCE: 1.0. LVO -300.
///
/// INPUTS:
/// - `buffer` - where the text goes, NUL-terminated.
/// - `size` - how many bytes `buffer` has, the NUL included;
///   CLI_MAX_PROMPT holds any prompt.
///
/// RESULT:
/// True when the whole text fitted. False, with IoErr, when it was cut
/// (ERROR_LINE_TOO_LONG), when `size` is 0 (ERROR_LINE_TOO_LONG,
/// nothing written) or when there is no CLI (ERROR_OBJECT_WRONG_TYPE).
///
/// BEHAVIOR:
/// The prompt is copied up to `size - 1` bytes and a NUL put after it,
/// so the buffer always holds a string, even when the answer is false
/// because it was cut. Without a CLI, or from a plain Task, the buffer
/// is made empty.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: not safe; it reads the running task's Process.
/// - Forbid: not needed, and not taken.
/// - Process: a CLI process for an answer; any other caller gets an
///   empty buffer and false.
///
/// OWNERSHIP:
/// Nothing is allocated. The buffer is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetPrompt`, `GetProgramName`
///
/// EXAMPLES:
/// ```zig
/// var prompt: [dos.CLI_MAX_PROMPT]u8 = undefined;
/// _ = dos_lib.GetPrompt(&prompt, prompt.len);
/// ```
pub fn GetPrompt(db: *DosBase, buffer: [*]u8, size: u32) bool {
    return _process.getName(db, .prompt, buffer, size);
}
