// SPDX-License-Identifier: MPL-2.0
//! Fault: puts the text for an error code into a buffer.

const sdk = @import("sdk");
const exec = sdk.exec;
const DosBase = @import("../dos_base.zig").DosBase;
const _text = @import("_text.zig");
const text = _text.text;
const Fill = _text.Fill;

/// Puts the text for an error code into a buffer.
///
/// SYNOPSIS:
/// ```zig
/// fn Fault(db: *DosBase, code: i32, header: ?[*:0]const u8, buffer: [*]u8, len: i32) i32
/// ```
///
/// SINCE: 1.0. LVO -484.
///
/// INPUTS:
/// - `code` - the error code: an IoErr code, or one of the shell's
///   (negative).
/// - `header` - put before the text with ": " after it; null for none.
/// - `buffer` - where the text goes.
/// - `len` - the buffer's size in bytes, the NUL included.
///
/// RESULT:
/// The length of the text put in the buffer, the NUL not counted. 0 for a
/// code of 0 or a `len` of 0 or less.
///
/// BEHAVIOR:
/// The text is "header: text", or the text alone for a null header; a code
/// without a text gives "Error <code>". The whole is cut to `len - 1` bytes
/// and ended with a NUL; nothing is written for a code of 0 but the NUL.
/// IoErr is not touched.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: safe. It only reads its inputs and writes the caller's
///   buffer.
/// - Forbid: not needed, and not taken.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The buffer is the caller's.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `PrintFault`, `IoErr`
///
/// EXAMPLES:
/// ```zig
/// var why: [80]u8 = undefined;
/// _ = dos_lib.Fault(dos_lib.IoErr(), "copy", &why, why.len);
/// ```
pub fn Fault(db: *DosBase, code: i32, header: ?[*:0]const u8, buffer: [*]u8, len: i32) i32 {
    if (len <= 0) return 0;
    const size: usize = @intCast(len);
    var f: Fill = .{ .buffer = buffer[0 .. size - 1] };
    if (code != 0) {
        if (header) |h| {
            f.put(h[0..db.utility_base.Strlen(h)]);
            f.put(": ");
        }
        if (text(code)) |t| {
            f.put(t[0..db.utility_base.Strlen(t)]);
        } else {
            var number: [16]u8 = undefined;
            const stream = exec.fmtStream(.{code});
            _ = db.sys_base.RawDoFmt("%d", &stream, null, &number);
            f.put("Error ");
            f.put(number[0..db.utility_base.Strlen(@ptrCast(&number))]);
        }
    }
    buffer[f.n] = 0;
    return @intCast(f.n);
}
