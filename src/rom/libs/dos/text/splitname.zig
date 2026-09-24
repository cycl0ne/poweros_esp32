// SPDX-License-Identifier: MPL-2.0
//! SplitName: takes a path apart one component at a time.

const DosBase = @import("../dos_base.zig").DosBase;

/// Copies one component of a path into a buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn SplitName(db: *DosBase, name: [*:0]const u8, separator: u8, buf: [*]u8, oldpos: i32, size: u32) i32
/// ```
///
/// SINCE: 1.0. LVO -116.
///
/// INPUTS:
/// - `name` - the path.
/// - `separator` - the byte between components, '/' or ':'.
/// - `buf` - where the component goes.
/// - `oldpos` - where in `name` to start: 0 first, then what the last call
///   returned.
/// - `size` - `buf`'s size, the NUL included.
///
/// RESULT:
/// The position after the separator, for the next call; -1 when the
/// component was the last one, when `oldpos` is outside `name`, or when
/// `size` is 0.
///
/// BEHAVIOR:
/// The text from `oldpos` up to the next `separator` (or the end) goes to
/// `buf`, cut to `size` - 1 bytes and ended with a NUL. A cut component
/// still returns the position after its separator, so the walk goes on.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It reads `name` and writes `buf`.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Nothing is allocated. Both buffers stay the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FilePart`, `PathPart`
///
/// EXAMPLES:
/// ```zig
/// var part: [32]u8 = undefined;
/// var pos: i32 = 0;
/// while (pos >= 0) {
///     pos = dos_lib.SplitName("dir/sub/file", '/', &part, pos, part.len);
///     // part holds "dir", then "sub", then "file"
/// }
/// ```
pub fn SplitName(db: *DosBase, name: [*:0]const u8, separator: u8, buf: [*]u8, oldpos: i32, size: u32) i32 {
    if (size == 0) return -1;
    buf[0] = 0;
    const utility_lib = db.utility_base;
    const len = utility_lib.Strlen(name);
    if (oldpos < 0 or oldpos >= len) return -1;
    const start: usize = @intCast(oldpos);
    const end = if (utility_lib.Strchr(name + start, separator)) |at| @intFromPtr(at) - @intFromPtr(name) else len;
    const n = @min(end - start, size - 1);
    @memcpy(buf[0..n], name[start..][0..n]);
    buf[n] = 0;
    return if (end == len) -1 else @intCast(end + 1);
}
