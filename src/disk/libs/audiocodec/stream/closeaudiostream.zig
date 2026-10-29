// SPDX-License-Identifier: MIT
//! CloseAudioStream: a stream given back.

const sdk = @import("sdk");
const ac = sdk.audiocodec;
const AudioCodecBase = @import("../audiocodec_base.zig").AudioCodecBase;
const _stream = @import("_stream.zig");

/// Closes a stream.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseAudioStream(base: *AudioCodecBase, stream: ?*ac.AudioStream) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `stream`: what OpenAudioStream made, or null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A file the stream opened (ACA_Name) is closed; the stream is freed.
///
/// CONTEXT:
/// - Waits: yes, on the file it closes.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a task will do: the one that has the stream - the one that
///   opened it, or one it was handed to (SINCE 1.3) - never two at once.
///
/// OWNERSHIP:
/// The stream is gone after the call. A handle the program gave
/// (ACA_FileHandle) is still the program's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenAudioStream`
///
/// EXAMPLES:
/// ```zig
/// acb.CloseAudioStream(stream);
/// ```
pub fn CloseAudioStream(_: *AudioCodecBase, stream: ?*ac.AudioStream) void {
    const public = stream orelse return;
    _stream.destroy(_stream.streamOf(public));
}
