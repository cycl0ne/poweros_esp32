// SPDX-License-Identifier: MPL-2.0
//! RtaLastError: What the last call that answers with a pointer went wrong
//! with.

const sdk = @import("sdk");
const exec = sdk.exec;
const RtaBase = @import("../rta.zig").RtaBase;

/// Why the last create failed.
///
/// SYNOPSIS:
/// ```zig
/// fn RtaLastError(rb: *RtaBase) i32
/// ```
///
/// SINCE: 1.0. LVO -108.
///
/// INPUTS:
/// None.
///
/// RESULT:
/// The `RTAERR_` code the last call that answers with a pointer left, or
/// that `DeleteSink` or `DeleteAudioTransport` left when it refused.
/// `RTAERR_OK` after one that worked.
///
/// BEHAVIOR:
/// It is one word for the whole library, not one per task.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing.
///
/// NOTES:
/// A caller that cannot be sure it was the last to fail passes
/// `RTAA_ErrorPtr` and reads its own.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RtaErrorText`, `CreateSinkTagList`
///
/// EXAMPLES:
/// ```zig
/// const sink = rb.CreateSinkTagList("es8311", tags) orelse return rb.RtaLastError();
/// ```
pub fn RtaLastError(rb: *RtaBase) i32 {
    return rb.last_error;
}
