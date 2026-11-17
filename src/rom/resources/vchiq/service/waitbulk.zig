// SPDX-License-Identifier: MPL-2.0
//! WaitBulk: a bulk transfer's end waited for.

const sdk = @import("sdk");
const exec = sdk.exec;
const vchiq = sdk.resources.vchiq;
const base = @import("../vchiq_base.zig");
const VchiqBase = base.VchiqBase;

/// Waits for a bulk transfer to be done.
///
/// SYNOPSIS:
/// ```zig
/// fn WaitBulk(vb: *VchiqBase, bulk: *VchiqBulk, timeout_us: u64) u32
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `bulk` - as QueueBulk put it out.
/// - `timeout_us` - how long to wait: 0 only looks, exec.WAIT_FOREVER
///   has no limit.
///
/// RESULT:
/// Its result: VCHIQERR_OK, and `bulk.actual` the bytes moved, or
/// VCHIQERR_ABORTED when the firmware gave it up; VCHIQERR_TIMEOUT when
/// it is still out.
///
/// BEHAVIOR:
/// It waits on `bulk.done` alone; a caller with more to wait for waits
/// on that among the rest (WaitForAny) and reads `bulk.result`.
///
/// CONTEXT:
/// - Waits: yes, up to `timeout_us`.
/// - Interrupts: no.
/// - Locks: none.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Once it is done the bulk and its memory are the caller's again.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `QueueBulk`
///
/// EXAMPLES:
/// ```zig
/// if (vb.WaitBulk(&bulk, 1_000_000) != vchiq.VCHIQERR_OK) return error.Failed;
/// ```
pub fn WaitBulk(vb: *VchiqBase, bulk: *vchiq.VchiqBulk, timeout_us: u64) u32 {
    const sys = vb.sys_base;
    const waits = [_]*exec.Waitable{&bulk.done};
    if (sys.WaitForAny(&waits, waits.len, timeout_us) == exec.WAIT_TIMEOUT) return vchiq.VCHIQERR_TIMEOUT;
    return bulk.result;
}
