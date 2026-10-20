// SPDX-License-Identifier: MPL-2.0
//! SinkControl: A sink's driver asked for something.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;

/// Asks a sink's driver for something: one of the codes every sink reads
/// alike, or one of its own.
///
/// SYNOPSIS:
/// ```zig
/// fn SinkControl(rb: *RtaBase, sink: *rta.AudioSink, what: u32, value: isize) isize
/// ```
///
/// SINCE: 1.0. LVO -80.
///
/// INPUTS:
/// - `sink` - the sink.
/// - `what` - `AUDIOCTRL_VOLUME`, or the driver's own code,
///   `AUDIOCTRL_DRIVER` and up.
/// - `value` - what goes with it.
///
/// RESULT:
/// What the driver answers, or `RTAERR_NOT_SUPPORTED` for a code it does
/// not know or a driver that takes none.
///
/// BEHAVIOR:
/// Passed on to the driver unchanged. `AUDIOCTRL_VOLUME` sets the output's
/// volume at its part and answers the gain left for the buffers
/// (`sdk/libs/rta/sinks.zig`); a sink that answers RTAERR_NOT_SUPPORTED to
/// it has no volume of its own.
///
/// CONTEXT:
/// - Waits: yes, if the driver does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// As the driver documents the code; nothing is kept from `value` for
/// `AUDIOCTRL_VOLUME`.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartSink`, `PlaySinkBuffer`
///
/// EXAMPLES:
/// ```zig
/// const rest = rb.SinkControl(sink, rta.sinks.AUDIOCTRL_VOLUME, rta.sinks.AUDIOGAIN_UNITY / 2);
/// const gain: u32 = if (rest < 0) rta.sinks.AUDIOGAIN_UNITY / 2 else @intCast(rest);
/// ```
pub fn SinkControl(_: *RtaBase, sink: *rta.AudioSink, what: u32, value: isize) isize {
    const ops = sink.ops orelse return err.RTAERR_NOT_SUPPORTED;
    const control = ops.control orelse return err.RTAERR_NOT_SUPPORTED;
    return control(sink, what, value);
}
