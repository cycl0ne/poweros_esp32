// SPDX-License-Identifier: MPL-2.0
//! OpenService: one of the firmware's services opened, the queue started
//! for the first.

const sdk = @import("sdk");
const exec = sdk.exec;
const vchiq = sdk.resources.vchiq;
const base = @import("../vchiq_base.zig");
const VchiqBase = base.VchiqBase;
const Service = base.Service;
const queue = @import("../link/_queue.zig");

/// Opens one of the firmware's services.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenService(vb: *VchiqBase, fourcc: u32, version: u32,
///     version_min: u32, err: ?*u32) ?*VchiqService
/// ```
///
/// SINCE: 1.0. LVO -4.
///
/// INPUTS:
/// - `fourcc` - the service's name, vchiq.fourcc("mmal").
/// - `version` - the version of the service's protocol the caller
///   speaks, and `version_min` the oldest it still speaks: the firmware
///   refuses a caller whose versions do not meet its own.
/// - `err` - VCHIQERR_OK, or why it failed; null if not wanted.
///
/// RESULT:
/// The service, or null and in `err` why not: VCHIQERR_NO_FIRMWARE when
/// there is no queue - no VCHIQ on the board, no memory kept for it, a
/// firmware that does not take it or does not connect; VCHIQERR_REFUSED
/// when the firmware has no such service, or not in those versions;
/// VCHIQERR_TIMEOUT when it did not answer in a second; VCHIQERR_BUSY
/// when seven services are open; VCHIQERR_NO_MEMORY.
///
/// BEHAVIOR:
/// The first call starts the queue: it lays the queue out in the memory
/// the kernel kept for it (PART_SharedMemory), starts the resource's
/// task, hooks the doorbell's interrupt, hands the memory to the
/// firmware through the mailbox and exchanges CONNECTs with it. A queue
/// that would not start stays dead until the machine is restarted. Then
/// an OPEN goes to the firmware, and its answer is waited for.
///
/// CONTEXT:
/// - Waits: yes, for the firmware - a second at most for each step.
/// - Interrupts: no.
/// - Locks: the resource's start lock, for the call.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The service is the caller's until CloseService.
///
/// BUGS:
/// An OPEN the firmware answers after the second is not closed again.
///
/// SEE ALSO:
/// `CloseService`, `SendMessage`, `ReceiveMessage`
///
/// EXAMPLES:
/// ```zig
/// var err: u32 = 0;
/// const mmal = vb.OpenService(vchiq.fourcc("mmal"), 15, 10, &err) orelse return err;
/// defer vb.CloseService(mmal);
/// ```
pub fn OpenService(vb: *VchiqBase, fourcc: u32, version: u32, version_min: u32, err: ?*u32) ?*vchiq.VchiqService {
    const sys = vb.sys_base;
    sys.ObtainSemaphore(&vb.start_lock);
    defer sys.ReleaseSemaphore(&vb.start_lock);
    const started = queue.start(vb);
    if (started != vchiq.VCHIQERR_OK) return failed(err, started);
    const port = for (vb.services[1..], 1..) |slot, n| {
        if (slot == null) break n;
    } else return failed(err, vchiq.VCHIQERR_BUSY);
    const memory = sys.AllocMem(@sizeOf(Service), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return failed(err, vchiq.VCHIQERR_NO_MEMORY);
    const s: *Service = @ptrCast(@alignCast(memory));
    s.* = .{ .vb = vb, .localport = @intCast(port) };
    {
        sys.ObtainSemaphore(&vb.list_lock);
        defer sys.ReleaseSemaphore(&vb.list_lock);
        vb.services[port] = s;
    }
    const opened = queue.open(vb, s, fourcc, version, version_min);
    if (opened != vchiq.VCHIQERR_OK) {
        queue.forget(vb, s);
        sys.FreeMem(memory, @sizeOf(Service));
        return failed(err, opened);
    }
    if (err) |e| e.* = vchiq.VCHIQERR_OK;
    return s.handle();
}

fn failed(err: ?*u32, why: u32) ?*vchiq.VchiqService {
    if (err) |e| e.* = why;
    return null;
}
