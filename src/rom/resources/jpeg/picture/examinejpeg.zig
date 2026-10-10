// SPDX-License-Identifier: MPL-2.0
//! ExamineJPEG: what a file is, and whether the codec takes it.

const sdk = @import("sdk");
const exec = sdk.exec;
const types = sdk.resources.jpeg;
const JpegBase = @import("../jpeg_base.zig").JpegBase;
const _header = @import("../header/_header.zig");

/// Says what a JPEG file is and whether the codec decodes it.
///
/// SYNOPSIS:
/// ```zig
/// fn ExamineJPEG(jb: *JpegBase, file: [*]const u8, length: u32,
///     info: *JPEGInfo) u32
/// ```
///
/// SINCE: 1.0. LVO -4.
///
/// INPUTS:
/// - `file` - the file's bytes, from its start.
/// - `length` - how many there are.
/// - `info` - filled in.
///
/// RESULT:
/// JPEGERR_OK, and `info` holds the picture's size, its components and
/// sampling (JPEGSAMP_*), and what DecodeJPEG will make of it: its format
/// (JPEGFMT_*), the bytes from one row to the next and the bytes it will
/// allocate. Otherwise why not: JPEGERR_NOT_JPEG, JPEGERR_CORRUPT, or
/// JPEGERR_UNSUPPORTED for a file the codec does not take (see
/// sdk/resources/jpeg.zig), JPEGERR_NO_MEMORY when there is not room to
/// read the headers in - `info` is then all zero.
///
/// BEHAVIOR:
/// The headers are read up to the scan; the picture itself is not
/// looked at, so a file whose scan is damaged is examined well and fails
/// in DecodeJPEG. A decoded picture is whole blocks of the file's
/// sampling, so `pitch` and `bytes` can be larger than the size says.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no: it allocates.
/// - Locks: none taken. - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is kept: `file` is only read, and only during the call.
///
/// NOTES:
/// It answers the same with the codec in use, and without one
/// (JPEGERR_NO_ENGINE comes from DecodeJPEG only).
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `DecodeJPEG`, `FreeJPEGPicture`
///
/// EXAMPLES:
/// ```zig
/// var info: sdk.resources.jpeg.JPEGInfo = .{};
/// if (jb.ExamineJPEG(bytes.ptr, @intCast(bytes.len), &info) == jpeg.JPEGERR_OK and
///     info.bytes <= sys.AvailMem(exec.MEMF_ANY)) { ... }
/// ```
pub fn ExamineJPEG(jb: *JpegBase, file: [*]const u8, length: u32, info: *types.JPEGInfo) u32 {
    info.* = .{};
    const sys = jb.sys_base;
    const memory = sys.AllocVec(@sizeOf(_header.Header), exec.MEMF_ANY) orelse return types.JPEGERR_NO_MEMORY;
    defer sys.FreeVec(memory);
    const h: *_header.Header = @ptrCast(@alignCast(memory));
    _header.read(file[0..length], h) catch |failure| return _header.errorOf(failure);
    info.* = _header.infoOf(h);
    return types.JPEGERR_OK;
}
