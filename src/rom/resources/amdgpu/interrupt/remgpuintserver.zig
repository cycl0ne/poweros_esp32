// SPDX-License-Identifier: MPL-2.0
//! RemGPUIntServer: a server AddGPUIntServer added taken off again.

const sdk = @import("sdk");
const exec = sdk.exec;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;

/// A server AddGPUIntServer added taken off again.
///
/// SYNOPSIS:
/// ```zig
/// fn RemGPUIntServer(ab: *AMDGPUBase, server: *exec.Interrupt) void
/// ```
///
/// SINCE: 1.4. LVO -36.
///
/// INPUTS:
/// - `server` - one added, or one never added.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The server is run no more once this returns. One added several times
/// is taken off each time it was; one not added is nothing. The ring
/// goes on running without servers: entries no server wants are read
/// and passed over.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It takes Disable.
/// - Locks: takes Disable.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The server is the caller's again.
///
/// NOTES:
/// The block's driver switches the interrupt off in its own registers
/// first, so that the block stops raising it.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `AddGPUIntServer`
///
/// EXAMPLES:
/// ```zig
/// ab.RemGPUIntServer(&frame);
/// ```
pub fn RemGPUIntServer(ab: *AMDGPUBase, server: *exec.Interrupt) void {
    const sys = ab.sys_base;
    sys.Disable();
    defer sys.Enable();
    for (&ab.servers) |*slot| {
        if (slot.server == server) slot.* = .{};
    }
}
