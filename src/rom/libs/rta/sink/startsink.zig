// SPDX-License-Identifier: MPL-2.0
//! StartSink: Bring the output up and start its ring.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const _sink = @import("_sink.zig");

/// Brings an output up and starts the ring it runs on.
///
/// SYNOPSIS:
/// ```zig
/// fn StartSink(rb: *RtaBase, sink: *rta.AudioSink, task: *exec.Task, signal_mask: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -64.
///
/// INPUTS:
/// - `sink` - the sink.
/// - `task` - the task that fills its buffers.
/// - `signal_mask` - the signal to raise on it each time a buffer has
///   been played.
///
/// RESULT:
/// `RTAERR_OK`; `RTAERR_IN_USE` for a sink already started;
/// `RTAERR_NOT_SUPPORTED` for one whose driver cannot start it; or what
/// the driver answered - `RTAERR_NO_OUTPUT` for a part that is not
/// there, `RTAERR_IO` for one that does not answer on its bus.
///
/// BEHAVIOR:
/// The driver brings its part up in the sink's mode - a codec set up over
/// its bus, an amplifier switched on - and starts the ring on silence.
/// From then on, every time a buffer has been played, `signal_mask` is
/// raised on `task`, which then takes the next buffer with `SinkBuffer`
/// and hands it back filled with `PlaySinkBuffer`. Nothing is left taken
/// when it fails.
///
/// CONTEXT:
/// - Waits: yes. A codec is reset and set up over its bus.
/// - Interrupts: no.
/// - Locks: no spinlock may be held: the driver waits.
/// - Process: a Task will do. Call it on `task`: the driver may make
///   ports and signals of that task's own.
///
/// OWNERSHIP:
/// The sink is the caller's to play through until `StopSink`; what the
/// driver took - pads, a DMA channel, memory - is the sink's meanwhile.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StopSink`, `SinkBuffer`, `PlaySinkBuffer`
///
/// EXAMPLES:
/// ```zig
/// if (rb.StartSink(sink, sys.FindTask(null).?, mask) != rta.errors.RTAERR_OK) return false;
/// ```
pub fn StartSink(_: *RtaBase, sink: *rta.AudioSink, task: *exec.Task, signal_mask: u32) i32 {
    if (_sink.running(sink)) return err.RTAERR_IN_USE;
    const mode = sink.mode orelse return err.RTAERR_BAD_MODE;
    const ops = sink.ops orelse return err.RTAERR_NOT_SUPPORTED;
    const start = ops.start orelse return err.RTAERR_NOT_SUPPORTED;
    const code = start(sink, mode, task, signal_mask);
    if (code == err.RTAERR_OK) sink.flags |= rta.sinks.AUDIOSF_RUNNING;
    return code;
}
