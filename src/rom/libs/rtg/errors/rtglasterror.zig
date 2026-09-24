// SPDX-License-Identifier: MPL-2.0
//! RtgLastError: The error of the last call on this task that had
//! nowhere to return one: the calls that answer with a pointer.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const utility = sdk.utility;
const TagItem = utility.TagItem;
const Tag = utility.Tag;
const RtgBase = @import("../rtg.zig").RtgBase;

/// Tells what the last call that answers with a pointer went wrong with.
///
/// SYNOPSIS:
/// ```zig
/// fn RtgLastError(rb: *RtgBase) i32
/// ```
///
/// SINCE: 1.0. LVO -200.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The error code, `RTGERR_OK` if none.
///
/// BEHAVIOR:
/// The calls that answer with a pointer - `CreateBoardTagList`,
/// `AllocBitMap` and the like - have nowhere to return an error, so they
/// leave it here.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads one field.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated.
///
/// BUGS:
/// It is one word for the whole library, not one per task: another task's
/// failure can land between a call and this. A caller that cannot be sure
/// passes `RTGA_ErrorPtr` and reads its own.
///
/// SEE ALSO:
/// `RtgErrorText`, `CreateBoardTagList`
///
/// EXAMPLES:
/// ```zig
/// const board = rb.CreateBoardTagList("rgb", null) orelse {
///     report(rb.RtgErrorText(rb.RtgLastError()));
///     return;
/// };
/// ```
pub fn RtgLastError(rb: *RtgBase) i32 {
    return rb.last_error;
}
