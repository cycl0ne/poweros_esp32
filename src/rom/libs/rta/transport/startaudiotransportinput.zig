// SPDX-License-Identifier: MPL-2.0
//! StartAudioTransportInput: Start a line's way in.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;
const _transport = @import("_transport.zig");

/// Starts a line's way in for a source.
///
/// SYNOPSIS:
/// ```zig
/// fn StartAudioTransportInput(rb: *RtaBase, io: *rta.AudioTransport, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) i32
/// ```
///
/// SINCE: 1.3. LVO -156.
///
/// INPUTS:
/// - `io` - the line.
/// - `mode` - the source's mode: the rate and the bits a sample to read
///   the part at.
/// - `task` - the task that takes the buffers.
/// - `signal_mask` - the signal raised on it each time a buffer has been
///   filled.
///
/// RESULT:
/// `RTAERR_OK`; `RTAERR_IN_USE` for a way in already started, or pads
/// another driver holds; `RTAERR_BAD_MODE` for a rate the line cannot be
/// clocked for, or another than its way out runs at;
/// `RTAERR_NO_INPUT` for a line whose part has no data pad toward the
/// chip, or when no DMA channel is free; `RTAERR_NOT_SUPPORTED` for a
/// line that has no way in.
///
/// BEHAVIOR:
/// The line's way in starts beside its way out, on the same clocks: the
/// part's data comes into a ring of its own, and `signal_mask` is raised
/// each time a buffer of it is full. A line whose way out is not playing
/// is started with its clocks - the part needs them to send - and its way
/// out plays silence. A source's driver calls it from its own start, once
/// its part is set up to send. Nothing is left taken when it fails.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The pads, a DMA channel and the ring's memory are the line's until both
/// its ways have stopped.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StopAudioTransportInput`, `AudioTransportInput`, `StartSource`
///
/// EXAMPLES:
/// ```zig
/// const code = rb.StartAudioTransportInput(io, mode, task, signal_mask);
/// if (code != rta.errors.RTAERR_OK) return code;
/// ```
pub fn StartAudioTransportInput(_: *RtaBase, io: *rta.AudioTransport, mode: *const rta.AudioMode, task: *exec.Task, signal_mask: u32) i32 {
    if (_transport.inputRunning(io)) return err.RTAERR_IN_USE;
    const ops = io.ops orelse return err.RTAERR_NOT_SUPPORTED;
    const start = ops.start_input orelse return err.RTAERR_NOT_SUPPORTED;
    const code = start(io, mode, task, signal_mask);
    if (code == err.RTAERR_OK) io.flags |= rta.transport.AUDIOTF_INPUT;
    return code;
}
