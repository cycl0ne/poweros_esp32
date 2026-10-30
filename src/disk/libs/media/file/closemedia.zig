// SPDX-License-Identifier: MIT
//! CloseMedia: a file given back.

const sdk = @import("sdk");
const media = sdk.media;
const MediaBase = @import("../media_base.zig").MediaBase;
const _file = @import("_file.zig");

/// Closes a container file.
///
/// SYNOPSIS:
/// ```zig
/// fn CloseMedia(base: *MediaBase, file: ?*media.MediaFile) void
/// ```
///
/// SINCE: 1.0. LVO -24.
///
/// INPUTS:
/// - `file`: what OpenMedia made, or null.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A file it opened (MDA_Name) is closed; its index, its tracks' buffers
/// and its chapters are freed with it.
///
/// CONTEXT:
/// - Waits: yes, on the file it closes.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a task will do; a process when it closes a file it opened.
///
/// OWNERSHIP:
/// The file is gone after the call, and every packet, setup, text and
/// picture it handed out with it. No track may be read while it closes. A
/// handle the program gave (MDA_FileHandle) is still the program's.
///
/// NOTES:
/// None.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenMedia`
///
/// EXAMPLES:
/// ```zig
/// mb.CloseMedia(film);
/// ```
pub fn CloseMedia(_: *MediaBase, file: ?*media.MediaFile) void {
    const public = file orelse return;
    _file.destroy(_file.fileOf(public));
}
