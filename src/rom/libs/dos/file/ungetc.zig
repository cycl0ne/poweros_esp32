// SPDX-License-Identifier: MPL-2.0
//! UnGetC: pushes a character back, for the next FGetC to give again.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const drain = _file.drain;
const stdio = dos.stdio;
const FileHandle = dos.FileHandle;

/// Pushes a character back onto a file handle.
///
/// SYNOPSIS:
/// ```zig
/// fn UnGetC(db: *DosBase, file: ?*FileHandle, character: i32) bool
/// ```
///
/// SINCE: 1.0. LVO -412.
///
/// INPUTS:
/// - `file` - the handle, or null.
/// - `character` - the character (its low 8 bits), or -1 for the last one
///   `FGetC` gave, the end included.
///
/// RESULT:
/// True when it was pushed. False for a null handle, when four are already
/// waiting, when -1 asks for a last character and there is none (nothing
/// read since the last push or since the handle turned around), or when
/// bytes waiting to be written couldn't go out. `IoErr()` is only changed
/// by that last case.
///
/// BEHAVIOR:
/// The characters wait on a stack of `UNGET_MAX` (4) and come back last in,
/// first out, before the buffer. The handle is a reading one from then on.
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
/// Nothing is allocated.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `FGetC`, `Flush`, `ReadArgs`
///
/// EXAMPLES:
/// ```zig
/// const c = dos_lib.FGetC(fh);
/// if (c != '-') _ = dos_lib.UnGetC(fh, -1);
/// ```
pub fn UnGetC(db: *DosBase, file: ?*FileHandle, character: i32) bool {
    const fh = file orelse return false;
    const c: i16 = if (character == -1) fh.last else @as(u8, @truncate(@as(u32, @bitCast(character))));
    if (c == FileHandle.NO_CHAR or fh.unget_count == stdio.UNGET_MAX) return false;
    if (fh.state == .write and !drain(db, fh)) return false;
    // It stands for a byte the file gave when the caller has taken more
    // out of the buffer than is already pushed back; anything else is the
    // caller's own, with no place in the file.
    const was_read = fh.state == .read and c >= 0;
    if (was_read and fh.pos > @popCount(fh.unget_backed)) fh.unget_backed |= @as(u8, 1) << @intCast(fh.unget_count);
    fh.unget[fh.unget_count] = c;
    fh.unget_count += 1;
    fh.last = FileHandle.NO_CHAR;
    fh.state = .read;
    return true;
}
