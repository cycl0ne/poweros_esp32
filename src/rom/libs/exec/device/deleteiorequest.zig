// SPDX-License-Identifier: MPL-2.0
//! DeleteIORequest: frees a request `CreateIORequest` made, by the size it
//! remembered in its message.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const IORequest = sdk.exec.IORequest;

/// Frees a request from `CreateIORequest`.
///
/// SYNOPSIS:
/// ```zig
/// fn DeleteIORequest(base: *ExecBase, io: ?*IORequest) void
/// ```
///
/// SINCE: 1.0. LVO -368.
///
/// INPUTS:
/// - `io` - one from `CreateIORequest`, or null, which does nothing.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The size is read from the request itself, so the caller need not
/// remember it.
///
/// **Its device must be closed first**, and nothing may still be
/// outstanding on it: a device holding a freed request writes into memory
/// that is now someone else's.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It frees memory.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The memory is the system's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CreateIORequest`, `CloseDevice`
///
/// EXAMPLES:
/// ```zig
/// defer sys.DeleteIORequest(io);
/// ```
pub fn DeleteIORequest(base: *ExecBase, io: ?*IORequest) void {
    const request = io orelse return;
    base.iface().FreeMem(request, request.message.length);
}
