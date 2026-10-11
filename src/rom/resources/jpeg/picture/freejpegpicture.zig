// SPDX-License-Identifier: MPL-2.0
//! FreeJPEGPicture: a decoded picture given back.

const sdk = @import("sdk");
const types = sdk.resources.jpeg;
const JpegBase = @import("../jpeg_base.zig").JpegBase;

/// Gives back a picture DecodeJPEG made.
///
/// SYNOPSIS:
/// ```zig
/// fn FreeJPEGPicture(jb: *JpegBase, picture: *JPEGPicture) void
/// ```
///
/// SINCE: 1.0. LVO -12.
///
/// INPUTS:
/// - `picture` - as DecodeJPEG filled it in.
///
/// RESULT:
/// Nothing. `picture` is all zero afterwards.
///
/// BEHAVIOR:
/// The memory behind the pixels is freed. A picture DecodeJPEG did not
/// make - all zero, as a failed decode leaves it - or one given back
/// already is left alone, so a caller may give back whatever it got.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no: it frees memory.
/// - Locks: none taken. - Process: a Task will do.
///
/// OWNERSHIP:
/// The pixels are gone: nothing may read them afterwards.
///
/// NOTES:
/// The picture is one block, its pixels a cache line into it at most;
/// `memory` and `memory_size` say which, and are the resource's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DecodeJPEG`
///
/// EXAMPLES:
/// ```zig
/// defer jb.FreeJPEGPicture(&picture);
/// ```
pub fn FreeJPEGPicture(jb: *JpegBase, picture: *types.JPEGPicture) void {
    if (picture.memory) |memory| jb.sys_base.FreeMem(memory, picture.memory_size);
    picture.* = .{};
}
