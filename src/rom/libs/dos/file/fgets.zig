// SPDX-License-Identifier: MPL-2.0
//! FGets: reads a line from a file into the caller's buffer.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const FileHandle = dos.FileHandle;

/// Reads a line from a file.
///
/// SYNOPSIS:
/// ```zig
/// fn FGets(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, size: u32) ?[*]u8
/// ```
///
/// SINCE: 1.0. LVO -428.
///
/// INPUTS:
/// - `file` - the handle.
/// - `buffer` - where the line goes.
/// - `size` - the buffer's size, the NUL included.
///
/// RESULT:
/// `buffer`, holding at most `size - 1` bytes, the newline kept when it
/// fitted, and a NUL. Null when `size` is 0, or when the end or an error
/// comes before any byte (`IoErr()` 0 at the end, the reason on an error).
///
/// BEHAVIOR:
/// Bytes come from `FGetC` until a '\n', the end, or a full buffer. A line
/// longer than the buffer comes in pieces: the next call reads on where
/// this one stopped.
///
/// CONTEXT:
/// - Waits: only when the buffer has to go to or come from the handler;
///   then it sends a packet and waits for the answer.
/// - Interrupts: no. It may wait.
/// - Forbid: not taken, and never to be held around it: it may wait.
/// - Process: a Task will do. One handle is one caller's: two tasks sharing
///   a handle take turns themselves.
///
/// OWNERSHIP:
/// Nothing is allocated. The line is in the caller's buffer.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FGetC`, `FPuts`, `ReadItem`
///
/// EXAMPLES:
/// ```zig
/// var line: [256]u8 = undefined;
/// while (dos_lib.FGets(fh, &line, line.len)) |text| {
///     _ = dos_lib.PutStr(@ptrCast(text));
/// }
/// ```
pub fn FGets(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, size: u32) ?[*]u8 {
    const dos_lib = db.iface();
    if (size == 0) return null;
    var n: u32 = 0;
    while (n + 1 < size) {
        const c = dos_lib.FGetC(file);
        if (c < 0) {
            if (n == 0) return null;
            break;
        }
        buffer[n] = @intCast(c);
        n += 1;
        if (c == '\n') break;
    }
    buffer[n] = 0;
    return buffer;
}
