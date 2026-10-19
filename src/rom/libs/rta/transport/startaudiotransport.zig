// SPDX-License-Identifier: MPL-2.0
//! StartAudioTransport: Clock a line, take its pads, start its ring.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const _transport = @import("_transport.zig");

/// Starts a line for a sink.
///
/// SYNOPSIS:
/// ```zig
/// fn StartAudioTransport(rb: *RtaBase, io: *rta.AudioTransport, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -92.
///
/// INPUTS:
/// - `io` - the line.
/// - `mode` - the sink's mode: the rate and the bits a sample to clock
///   the line for.
/// - `task` - the task that fills the buffers.
/// - `signal_mask` - the signal raised on it each time a buffer has been
///   played.
///
/// RESULT:
/// `RTAERR_OK`; `RTAERR_IN_USE` for a line already started, or one whose
/// pads another driver holds; `RTAERR_BAD_MODE` for a rate the line
/// cannot be clocked for; `RTAERR_NO_OUTPUT` when no DMA channel is free.
///
/// BEHAVIOR:
/// The line's clocks run, its pads are taken from gpio.resource and
/// driven, and the ring starts on silence. A sink's driver calls it from
/// its own start, at the point its part wants the clocks: a codec after
/// it has been set up, before its volume goes up. Nothing is left taken
/// when it fails.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pads, a DMA channel and the ring's memory are the line's until
/// `StopAudioTransport`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StopAudioTransport`, `AudioTransportBuffer`, `StartSink`
///
/// EXAMPLES:
/// ```zig
/// const code = rb.StartAudioTransport(io, mode, task, signal_mask);
/// if (code != rta.errors.RTAERR_OK) return code;
/// ```
pub fn StartAudioTransport(_: *RtaBase, io: *rta.AudioTransport, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) i32 {
    if (_transport.running(io)) return err.RTAERR_IN_USE;
    const ops = io.ops orelse return err.RTAERR_NOT_SUPPORTED;
    const start = ops.start orelse return err.RTAERR_NOT_SUPPORTED;
    const code = start(io, mode, task, signal_mask);
    if (code == err.RTAERR_OK) io.flags |= rta.transport.AUDIOTF_RUNNING;
    return code;
}
