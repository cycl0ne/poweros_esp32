// SPDX-License-Identifier: MPL-2.0
//! ReadPassword: a line typed on a console without its echo.

const sdk = @import("sdk");
const dos = sdk.dos;
const FileHandle = dos.FileHandle;
const DosBase = @import("../dos_base.zig").DosBase;
const _file = @import("_file.zig");
const failWith = _file.failWith;
const utf8 = sdk.utility.utf8;

/// Reads a password, a passphrase or a token as it is typed on the
/// console `file`, nothing of it shown.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadPassword(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, size: usize) isize
/// ```
///
/// SINCE: 1.19, a character taken back whole since 1.22. LVO -640.
///
/// INPUTS:
/// - `file` - the console it is typed on: a process's Input(), or a
///   session's console.
/// - `buffer`, `size` - where the characters go; a NUL after them when
///   there is room.
///
/// RESULT:
/// How many bytes were typed, UTF-8 as the console gives them; -1 when
/// nothing may be taken, the buffer then
/// wiped - IoErr() ERROR_BREAK for Ctrl-C, 0 when the input ended,
/// ERROR_OBJECT_WRONG_TYPE for a `file` that is no console, Read's error.
///
/// BEHAVIOR:
/// The console is put in raw mode, so nothing typed is echoed, and read
/// a byte at a time: Backspace and Delete take the last character back,
/// all of its bytes, Return or a line feed ends the line, Ctrl-C, Ctrl-\
/// and the input's end give it up. A control character else is passed
/// over, and a byte past `size` too. The console is put back in the mode it was
/// in - a RAW: window stays raw - and a newline written to it, so what
/// comes next starts a line of its own.
///
/// CONTEXT:
/// - Waits: yes, for each character typed.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a process, or a task with a console handle of its own.
///
/// OWNERSHIP:
/// The buffer is the caller's, to wipe once the secret is used.
///
/// NOTES:
/// The prompt is the caller's to write and flush before. Bytes typed
/// ahead past the Return stay in the handle's buffer for the next read.
/// A key that sends an escape sequence - an arrow - gives the characters
/// after its escape.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `SetMode`, `Read`, `IsInteractive`, `FGets`
///
/// EXAMPLES:
/// ```zig
/// _ = dl.PutStr("Password: ");
/// _ = dl.Flush(dl.Output());
/// var password: [128]u8 = undefined;
/// const length = dl.ReadPassword(dl.Input(), &password, password.len);
/// if (length < 0) return dos.RETURN_WARN;
/// defer {
///     const wiped: [*]volatile u8 = &password;
///     for (0..password.len) |at| wiped[at] = 0;
/// }
/// ```
pub fn ReadPassword(db: *DosBase, file: ?*FileHandle, buffer: [*]u8, size: usize) isize {
    const dos_lib = db.iface();
    const fh = file orelse return failWith(db, dos.ERROR_INVALID_LOCK, -1);
    if (!dos_lib.IsInteractive(fh)) return failWith(db, dos.ERROR_OBJECT_WRONG_TYPE, -1);
    // The mode it is in, to be put back: a RAW: window stays raw.
    var info: dos.InfoData = .{};
    const raw_before = _file.consoleAction(db, fh, .disk_info, @bitCast(@intFromPtr(&info))) and
        info.disk_type == dos.ID_RAWCON;
    if (!raw_before and !dos_lib.SetMode(fh, 1)) return -1;
    var length: usize = 0;
    var failure: ?i32 = null;
    while (true) {
        var char: [1]u8 = undefined;
        const got = dos_lib.Read(fh, &char, 1);
        if (got < 0) {
            failure = dos_lib.IoErr();
            break;
        }
        if (got == 0 or char[0] == 0x1C) {
            failure = 0;
            break;
        }
        if (char[0] == 3) {
            failure = dos.ERROR_BREAK;
            break;
        }
        if (char[0] == '\r' or char[0] == '\n') break;
        if (char[0] == 8 or char[0] == 127) {
            if (length > 0) length -= utf8.readLast(buffer[0..length]).length;
        } else if (char[0] >= ' ' and length < size) {
            buffer[length] = char[0];
            length += 1;
        }
    }
    if (!raw_before) _ = dos_lib.SetMode(fh, 0);
    _ = dos_lib.Write(fh, "\n", 1);
    if (failure) |code| {
        const wiped: [*]volatile u8 = buffer;
        for (0..size) |at| wiped[at] = 0;
        _ = dos_lib.SetIoErr(code);
        return -1;
    }
    // What a Backspace took back goes too.
    const wiped: [*]volatile u8 = buffer;
    for (length..size) |at| wiped[at] = 0;
    return @intCast(length);
}
