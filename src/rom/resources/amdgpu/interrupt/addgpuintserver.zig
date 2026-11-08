// SPDX-License-Identifier: MPL-2.0
//! AddGPUIntServer: a server for one of the device's interrupts.

const sdk = @import("sdk");
const exec = sdk.exec;
const AMDGPUBase = @import("../amdgpu.zig").AMDGPUBase;
const _interrupt = @import("_interrupt.zig");

/// A server for one of the device's interrupts: run for each entry the
/// interrupt block writes for `client` and `source`.
///
/// SYNOPSIS:
/// ```zig
/// fn AddGPUIntServer(ab: *AMDGPUBase, client: u32, source: u32,
///     server: *exec.Interrupt) bool
/// ```
///
/// SINCE: 1.4. LVO -32.
///
/// INPUTS:
/// - `client` - the block that raises it (`GPUINT_CLIENT_*`).
/// - `source` - which of that block's interrupts (`GPUINT_DISPLAY_*`
///   and the like, the pipe or fetcher added).
/// - `server` - its `code` an `IntServerFn`, `data` handed to it.
///
/// RESULT:
/// True once the server is on. False where the resource holds as many
/// servers as it keeps, the interrupt block is not one whose ring is
/// known, the ring could not be started - after which it is not tried
/// again - and on a machine without the device.
///
/// BEHAVIOR:
/// The first server starts the ring: a piece of the device's memory for
/// it, the device's message vector from pci.library, and the interrupt
/// block told to write the ring, all said on the raw port. Each entry
/// the block writes is then handed, in the device's message, to every
/// server added for its client and source, which is given the source as
/// its interrupt number; what it answers is not looked at. A server may
/// be added for a client and source that already has one.
///
/// Nothing is switched on at the block that raises the interrupt: its
/// driver does that in the block's own registers once the server is on,
/// and acknowledges it there in the server.
///
/// CONTEXT:
/// - Waits: for another task adding a server; the first, for the ring
///   to start.
/// - Interrupts: no.
/// - Locks: takes the resource's interrupt lock, then Disable.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The server stays the caller's and must stay in place until it is
/// taken off with RemGPUIntServer.
///
/// NOTES:
/// The server runs in the device's message: it must not wait, and what it
/// shares with a task is shared as with any interrupt.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemGPUIntServer`, exec's `AddIntServer`
///
/// EXAMPLES:
/// ```zig
/// frame = .{ .node = .{ .type = .interrupt, .name = "frames" }, .data = screen, .code = &frameServer };
/// if (!ab.AddGPUIntServer(amdgpu.GPUINT_CLIENT_DISPLAY, amdgpu.GPUINT_DISPLAY_UPDATE + pipe, &frame)) return;
/// ```
pub fn AddGPUIntServer(ab: *AMDGPUBase, client: u32, source: u32, server: *exec.Interrupt) bool {
    if (ab.device == null or !ab.interrupts_known) return false;
    const sys = ab.sys_base;
    sys.ObtainSemaphore(&ab.interrupt_lock);
    defer sys.ReleaseSemaphore(&ab.interrupt_lock);
    if (!ab.ih_running) {
        if (ab.ih_failed) return false;
        if (!_interrupt.start(ab)) {
            ab.ih_failed = true;
            return false;
        }
    }
    sys.Disable();
    defer sys.Enable();
    for (&ab.servers) |*slot| {
        if (slot.server != null) continue;
        slot.* = .{ .client = client, .source = source, .server = server };
        return true;
    }
    return false;
}
