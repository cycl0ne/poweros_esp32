// SPDX-License-Identifier: MIT
//! CloseVideoStream: a stream given back.

const sdk = @import("sdk");
const vc = sdk.videocodec;
const VideoCodecBase = @import("../videocodec_base.zig").VideoCodecBase;
const _stream = @import("_stream.zig");

/// Closes a stream.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseVideoStream(base: *VideoCodecBase, stream: ?*vc.VideoStream) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `stream`: what OpenVideoStream made, or null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The sound's stream is closed, the decoder of the pictures with every
/// frame still lent, the film - and the file, when the stream opened it
/// (VCA_Name) - and the libraries the stream opened.
///
/// CONTEXT:
/// - Waits: yes, on the file and the chip.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process when it closes a file it opened.
///
/// OWNERSHIP:
/// The stream is gone after the call, and every frame it lent with it:
/// none may be shown after. Neither half may be being decoded while it
/// closes. A handle the program gave (VCA_FileHandle) is still the
/// program's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenVideoStream`
///
/// EXAMPLES:
/// ```zig
/// vcb.CloseVideoStream(film);
/// ```
pub fn CloseVideoStream(_: *VideoCodecBase, stream: ?*vc.VideoStream) void {
    const public = stream orelse return;
    _stream.destroy(_stream.of(public));
}
