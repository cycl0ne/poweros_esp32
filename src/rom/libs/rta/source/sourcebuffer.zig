// SPDX-License-Identifier: MPL-2.0
//! SourceBuffer: The buffer a way in filled last.

const sdk = @import("sdk");
const exec = sdk.exec;
const rta = sdk.rta;
const RtaBase = @import("../rta.zig").RtaBase;
const _source = @import("_source.zig");

/// The buffer of a running source that has just been filled.
///
/// SYNOPSIS:
/// ```zig
/// fn SourceBuffer(rb: *RtaBase, source: *rta.AudioSource) ?[*]const i16
/// ```
///
/// SINCE: 1.3. LVO -152.
///
/// INPUTS:
/// - `source` - a started source.
///
/// RESULT:
/// The buffer: `buffer_frames` stereo frames of 16-bit samples, the two
/// halves of each as the mode's `sides` says. Null when no buffer has
/// been filled since the last one was taken, or the source is not
/// started.
///
/// BEHAVIOR:
/// What comes back is the buffer filled last, which the part is furthest
/// from writing again. A caller woken late - more than one filled since it
/// was last here - gets the latest; the ones it missed are lost, and the
/// source counts them in `overruns`.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do: the one that started the source.
///
/// OWNERSHIP:
/// The buffer is the source's memory, the caller's to read until the ring
/// comes round to it: `buffers - 1` buffers' time.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `StartSource`, `SinkBuffer`
///
/// EXAMPLES:
/// ```zig
/// const frames = rb.SourceBuffer(source) orelse return;
/// keep(frames[0 .. source.buffer_frames * 2]);
/// ```
pub fn SourceBuffer(_: *RtaBase, source: *rta.AudioSource) ?[*]const i16 {
    if (!_source.running(source)) return null;
    const ops = source.ops orelse return null;
    const buffer = ops.buffer orelse return null;
    return buffer(source);
}
