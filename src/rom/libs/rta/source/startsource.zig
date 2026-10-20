// SPDX-License-Identifier: MPL-2.0
//! StartSource: Bring a way in up in a mode and start its ring.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const _source = @import("_source.zig");

/// Brings a way in up and starts the ring it runs on.
///
/// SYNOPSIS:
/// ```zig
/// fn StartSource(rb: *RtaBase, source: *rta.AudioSource, mode: ?*rta.AudioMode, task: *exec.Task, signal_mask: u32) i32
/// ```
///
/// SINCE: 1.3. LVO -144.
///
/// INPUTS:
/// - `source` - the source.
/// - `mode` - one of its modes to record in, or null for its default.
/// - `task` - the task that takes its buffers.
/// - `signal_mask` - the signal to raise on it each time a buffer has
///   been filled.
///
/// RESULT:
/// `RTAERR_OK`; `RTAERR_IN_USE` for a source already started;
/// `RTAERR_BAD_MODE` for a mode that is not the source's, or one at
/// another rate than its line already runs at; `RTAERR_NOT_SUPPORTED`
/// for a source whose driver cannot start it; or what the driver
/// answered - `RTAERR_NO_INPUT` for a part that is not there, `RTAERR_IO`
/// for one that does not answer on its bus.
///
/// BEHAVIOR:
/// The driver brings its part up in that mode - a codec's converter
/// switched on over its bus - and starts the ring. From then on, every
/// time a buffer has been filled, `signal_mask` is raised on `task`, which
/// takes it with `SourceBuffer`. The mode is the source's `mode` from
/// then on. A source on a line whose way out is playing is started at the
/// rate it plays at, or refused: the caller picks the mode that has it.
/// Nothing is left taken when it fails.
///
/// CONTEXT:
/// - Waits: yes. A codec is set up over its bus.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: the driver waits.
/// - Process: a Task will do. Call it on `task`: the driver may make
///   ports and signals of that task's own.
///
/// OWNERSHIP:
/// The source is the caller's to record from until `StopSource`; what the
/// driver took - pads, a DMA channel, memory - is the source's meanwhile.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StopSource`, `SourceBuffer`, `NextSourceMode`, `StartSink`
///
/// EXAMPLES:
/// ```zig
/// if (rb.StartSource(source, null, sys.FindTask(null).?, mask) != rta.errors.RTAERR_OK) return false;
/// ```
pub fn StartSource(_: *RtaBase, source: *rta.AudioSource, mode: ?*rta.AudioMode, task: *exec.Task, signal_mask: u32) i32 {
    if (_source.running(source)) return err.RTAERR_IN_USE;
    const wanted = mode orelse _source.defaultMode(source) orelse return err.RTAERR_BAD_MODE;
    if (!_source.hasMode(source, wanted)) return err.RTAERR_BAD_MODE;
    const ops = source.ops orelse return err.RTAERR_NOT_SUPPORTED;
    const start = ops.start orelse return err.RTAERR_NOT_SUPPORTED;
    const code = start(source, wanted, task, signal_mask);
    if (code != err.RTAERR_OK) return code;
    if (source.mode) |was| was.flags &= ~rta.sinks.AUDIOMF_CURRENT;
    wanted.flags |= rta.sinks.AUDIOMF_CURRENT;
    source.mode = wanted;
    source.flags |= rta.sources.AUDIOSRCF_RUNNING;
    return err.RTAERR_OK;
}
