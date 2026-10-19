// SPDX-License-Identifier: MPL-2.0
//! SinkControl: Something only this driver knows about.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const err = rta.errors;

/// Asks a sink's driver for something of its own.
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
/// - `what` - the driver's own code, `AUDIOCTRL_DRIVER` and up.
/// - `value` - what goes with it.
///
/// RESULT:
/// What the driver answers, or `RTAERR_NOT_SUPPORTED` for a code it does
/// not know or a driver that takes none.
///
/// BEHAVIOR:
/// Passed on to the driver unchanged.
///
/// CONTEXT:
/// - Waits: yes, if the driver does.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// As the driver documents the code.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartSink`
///
/// EXAMPLES:
/// ```zig
/// const answer = rb.SinkControl(sink, rta.sinks.AUDIOCTRL_DRIVER, 0);
/// ```
pub fn SinkControl(_: *RtaBase, sink: *rta.AudioSink, what: u32, value: isize) isize {
    const ops = sink.ops orelse return err.RTAERR_NOT_SUPPORTED;
    const control = ops.control orelse return err.RTAERR_NOT_SUPPORTED;
    return control(sink, what, value);
}
