// SPDX-License-Identifier: MIT
//! IDtoStr: an id written out as text.

const sdk = @import("sdk");
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;

/// Writes an id out as text.
///
/// SYNOPSIS:
/// ```zig
/// fn IDtoStr(ib: *IFFParseBase, id: u32, buf: *[5]u8) [*:0]u8
/// ```
///
/// SINCE: 1.0. LVO -176.
///
/// INPUTS:
/// - `id` - four characters as a number.
/// - `buf` - five bytes to write them and a NUL into.
///
/// RESULT:
/// `buf` again, as a C string.
///
/// BEHAVIOR:
/// The four characters go in as they are, whatever they are: an id that
/// is not printable comes out as it stands, which is what a program
/// printing an error about a file wants to see.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// `buf` stays the caller's.
///
/// NOTES:
/// Five bytes, not four: the NUL is what makes it a string.
///
/// SEE ALSO:
/// `GoodID`, `CurrentChunk`
///
/// EXAMPLES:
/// ```zig
/// var name: [5]u8 = undefined;
/// _ = Printf(dl, "chunk %s\n", .{ip.IDtoStr(chunk.id, &name)});
/// ```
pub fn IDtoStr(ib: *IFFParseBase, id: u32, buf: *[5]u8) [*:0]u8 {
    _ = ib;
    buf[0] = @truncate(id >> 24);
    buf[1] = @truncate(id >> 16);
    buf[2] = @truncate(id >> 8);
    buf[3] = @truncate(id);
    buf[4] = 0;
    return @ptrCast(buf);
}
