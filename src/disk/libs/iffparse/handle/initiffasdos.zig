// SPDX-License-Identifier: MIT
//! InitIFFasDOS: the stream is a file.
//!
//! The hook is the handle's own (`Handle.own_stream`), not a static one:
//! a module keeps no state of its own, and a hook is written to when it
//! is made.

const sdk = @import("sdk");
const dos = sdk.dos;
const utility = sdk.utility;
const iffparse = sdk.iffparse;
const _base = @import("../iffparse_base.zig");
const IFFParseBase = _base.IFFParseBase;

/// The stream of a handle whose `stream` is a dos file handle.
fn fileStream(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    const iff: *iffparse.IFFHandle = @ptrCast(@alignCast(object orelse return 1));
    const cmd: *iffparse.IFFStreamCmd = @ptrCast(@alignCast(message orelse return 1));
    const h = _base.handleOf(iff);
    _ = hook;
    const dl = h.base.dos_base;
    const file: *dos.FileHandle = @ptrFromInt(iff.stream);
    const bytes: isize = @max(cmd.bytes, 0);
    switch (cmd.command) {
        iffparse.IFFCMD_READ => {
            const buf = cmd.buf orelse return 1;
            return @intFromBool(dl.Read(file, buf, bytes) != bytes);
        },
        iffparse.IFFCMD_WRITE => {
            const buf = cmd.buf orelse return 1;
            return @intFromBool(dl.Write(file, buf, bytes) != bytes);
        },
        iffparse.IFFCMD_SEEK => {
            return @intFromBool(dl.Seek(file, cmd.bytes, dos.OFFSET_CURRENT) < 0);
        },
        else => return 0,
    }
}

/// Says a handle's stream is a file.
///
/// SYNOPSIS:
/// ```zig
/// fn InitIFFasDOS(ib: *IFFParseBase, iff: *iffparse.IFFHandle) void
/// ```
///
/// SINCE: 1.0. LVO -32.
///
/// INPUTS:
/// - `iff` - a handle from `AllocIFF`, not open, whose `stream` holds a
///   `*dos.FileHandle` from `Open`.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// The file is taken to seek both ways, which every file on a file
/// system here does. `Read`, `Write` and `Seek` are what the stream then
/// uses, and a short read or write is a failure.
///
/// CONTEXT:
/// - Waits: no, but everything done through the stream afterwards waits
///   on the file system.
/// - Interrupts: no.
/// - Locks: none needed.
/// - Process: a Task will do here; reading or writing the file needs a
///   Process, because dos does.
///
/// OWNERSHIP:
/// The file stays the caller's: it is opened before and closed after,
/// and the library never touches it except through `Read`, `Write` and
/// `Seek`.
///
/// NOTES:
/// A stream that is not a file on a file system - a pipe, a socket -
/// does not seek, and is better given to `InitIFF` with the flags that
/// say so.
///
/// SEE ALSO:
/// `InitIFF`, `InitIFFasClip`, `OpenIFF`
///
/// EXAMPLES:
/// ```zig
/// const file = dl.Open("SYS:Tests/picture.iff", dos.MODE_OLDFILE) orelse return;
/// defer _ = dl.Close(file);
/// iff.stream = @intFromPtr(file);
/// ip.InitIFFasDOS(iff);
/// ```
pub fn InitIFFasDOS(ib: *IFFParseBase, iff: *iffparse.IFFHandle) void {
    const h = _base.handleOf(iff);
    h.own_stream = .{ .entry = &fileStream };
    InitIFF(ib, iff, iffparse.IFFF_FSEEK | iffparse.IFFF_RSEEK, &h.own_stream);
}

const InitIFF = @import("initiff.zig").InitIFF;
