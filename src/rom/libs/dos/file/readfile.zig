// SPDX-License-Identifier: MPL-2.0
//! ReadFile: a file read whole into memory of its own.

const sdk = @import("sdk");
const dos = sdk.dos;
const DosBase = @import("../dos_base.zig").DosBase;

/// Reads the file `name` whole into memory of its own, a NUL after its
/// bytes.
///
/// SYNOPSIS:
/// ```zig
/// fn ReadFile(db: *DosBase, name: [*:0]const u8, most: usize, requirements: u32, length: *usize) ?[*]u8
/// ```
///
/// SINCE: 1.18. LVO -628.
///
/// INPUTS:
/// - `name` - the file, as for Open.
/// - `most` - the most bytes it may have.
/// - `requirements` - what AllocVec is asked for: MEMF_ANY, or
///   MEMF_SYSTEM for bytes that outlive the task, MEMF_INTERNAL for bytes
///   an interrupt reads.
/// - `length` - set to the number of bytes.
///
/// RESULT:
/// The bytes, `length` of them and a NUL after them; null with IoErr()
/// (ERROR_OBJECT_TOO_LARGE for a file of more than `most` bytes,
/// ERROR_NO_FREE_STORE, Open's, Seek's and Read's errors).
///
/// BEHAVIOR:
/// The file is opened MODE_OLDFILE, its size taken from a Seek to its
/// end, and the memory allocated a byte longer than that. Its bytes are
/// read to the end; a file that grew past its size meanwhile is too large
/// for that memory and refused. An empty file is a NUL alone, `length` 0.
///
/// CONTEXT:
/// - Waits: yes, for the handler.
/// - Interrupts: no.
/// - Locks: no spinlock may be held.
/// - Process: a Task will do; a process gets IoErr().
///
/// OWNERSHIP:
/// The memory is the caller's, given back with FreeVec. The file is
/// closed before ReadFile returns.
///
/// NOTES:
/// The NUL makes a text file a C string as it comes; it is not counted
/// in `length`. A file whose handler cannot seek - a console, a pipe - is
/// not read this way: Seek's error comes back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `Open`, `Read`, `Seek`, exec's `AllocVec`
///
/// EXAMPLES:
/// ```zig
/// var length: usize = 0;
/// const bytes = dl.ReadFile("S:Startup-Sequence", 64 * 1024, exec.MEMF_ANY, &length) orelse
///     return dl.PrintFault(dl.IoErr(), "S:Startup-Sequence");
/// defer sys.FreeVec(bytes);
/// const text = bytes[0..length];
/// ```
pub fn ReadFile(db: *DosBase, name: [*:0]const u8, most: usize, requirements: u32, length: *usize) ?[*]u8 {
    const dos_lib = db.iface();
    const sys = db.sys_base;
    length.* = 0;
    const file = dos_lib.Open(name, dos.MODE_OLDFILE) orelse return null;
    defer _ = dos_lib.Close(file);
    if (dos_lib.Seek(file, 0, dos.OFFSET_END) < 0) return null;
    const end = dos_lib.Seek(file, 0, dos.OFFSET_BEGINNING);
    if (end < 0) return null;
    if (@as(u64, @intCast(end)) > most) return refuse(db, dos.ERROR_OBJECT_TOO_LARGE);
    const size: usize = @intCast(end);
    const memory = sys.AllocVec(size + 1, requirements) orelse return refuse(db, dos.ERROR_NO_FREE_STORE);
    const bytes: [*]u8 = @ptrCast(memory);
    // A byte past the size is asked for too: a file that grew shows it.
    var got: usize = 0;
    while (got <= size) {
        const piece = dos_lib.Read(file, bytes + got, @intCast(size + 1 - got));
        if (piece < 0) {
            sys.FreeVec(memory);
            return null;
        }
        if (piece == 0) break;
        got += @intCast(piece);
    }
    if (got > size) {
        sys.FreeVec(memory);
        return refuse(db, dos.ERROR_OBJECT_TOO_LARGE);
    }
    bytes[got] = 0;
    length.* = got;
    return bytes;
}

fn refuse(db: *DosBase, code: i32) ?[*]u8 {
    _ = db.iface().SetIoErr(code);
    return null;
}
