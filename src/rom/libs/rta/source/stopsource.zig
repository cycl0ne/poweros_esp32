// SPDX-License-Identifier: MPL-2.0
//! StopSource: Stop a way in and give back what it took.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const _source = @import("_source.zig");

/// Stops a way in.
///
/// SYNOPSIS:
/// ```zig
/// fn StopSource(rb: *RtaBase, source: *rta.AudioSource) void
/// ```
///
/// SINCE: 1.3. LVO -148.
///
/// INPUTS:
/// - `source` - the source.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The driver stops the ring, switches its part's converter off and gives
/// back what `StartSource` took. A line whose way out still plays goes on
/// playing. A source that is not started is left alone.
///
/// CONTEXT:
/// - Waits: yes, if the driver does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do. Call it on the task that started the
///   source.
///
/// OWNERSHIP:
/// The pads, the DMA channel and the memory are given back; the source
/// may be started again, or deleted.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartSource`, `DeleteSource`
///
/// EXAMPLES:
/// ```zig
/// rb.StopSource(source);
/// ```
pub fn StopSource(_: *RtaBase, source: *rta.AudioSource) void {
    if (!_source.running(source)) return;
    if (source.ops) |ops| {
        if (ops.stop) |stop| stop(source);
    }
    source.flags &= ~rta.sources.AUDIOSRCF_RUNNING;
}
