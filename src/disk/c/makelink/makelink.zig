// SPDX-License-Identifier: MIT
//! MakeLink: a link named FROM to TO. Built against the SDK only.
//!
//!   MakeLink FROM/A,TO/A,HARD/S,FORCE/S
//!
//!   MakeLink Work:Tools SYS:Utilities
//!   MakeLink RAM:readme Work:Docs/ReadMe HARD
//!
//! FROM is the new link's name, TO what it leads to. Without HARD the link
//! is a soft one: it holds TO as it was typed, and Lock and Open follow it
//! - a relative TO from the directory the link is in. TO must be there,
//! looked for from that directory, unless FORCE is given, which makes the
//! link all the same, for a volume that is not in or a file still to
//! come. With HARD the link is a second name for the file TO, on the same
//! volume: either name opens it, and it stays until its last name is
//! deleted. A directory takes no hard link. The return code is 0 for a
//! link made, 20 for one that could not be, with the reason said.

const sdk = @import("sdk");
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const FileLock = dos.FileLock;
const FileInfoBlock = dos.FileInfoBlock;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "MakeLink";
const VERSION_STRING = "\x00$VER: MakeLink 1.0 (18.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FROM/A,TO/A,HARD/S,FORCE/S";
const arg_from = 0;
const arg_to = 1;
const arg_hard = 2;
const arg_force = 3;
const arg_count = 4;

/// No newline: PrintFault's reason follows on the same line.
const MSG_CANTFIND = "Can't find %s: ";
const MSG_DIRLINK = "%s is a directory: a hard link is made only to a file\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const from = rdargs.string(argv[arg_from]).?;
    const to = rdargs.string(argv[arg_to]).?;

    if (argv[arg_hard] == 0) {
        if (argv[arg_force] == 0 and !reachable(dl, from, to)) return notFound(dl, to, dl.IoErr());
        if (!dl.MakeLink(from, @intFromPtr(to), true)) return fail(dl, dl.IoErr());
        return dos.RETURN_OK;
    }

    const object = dl.Lock(to, dos.SHARED_LOCK) orelse return notFound(dl, to, dl.IoErr());
    defer dl.UnLock(object);
    if (isDirectory(dl, object)) {
        _ = Printf(dl, MSG_DIRLINK, .{to});
        return dos.RETURN_FAIL;
    }
    if (!dl.MakeLink(from, @intFromPtr(object), false)) return fail(dl, dl.IoErr());
    return dos.RETURN_OK;
}

/// The reason said, and the return code for a link not made.
fn fail(dl: *DosBase, code: i32) i32 {
    _ = dl.PrintFault(code, COMMAND_NAME);
    return dos.RETURN_FAIL;
}

/// What could not be found and why, and the return code for a link not
/// made.
fn notFound(dl: *DosBase, to: [*:0]const u8, code: i32) i32 {
    _ = Printf(dl, MSG_CANTFIND, .{to});
    _ = dl.PrintFault(code, null);
    return dos.RETURN_FAIL;
}

/// Whether `to` leads somewhere from the directory a link named `from`
/// would be in - where the link follows it from. IoErr says why not.
fn reachable(dl: *DosBase, from: [*:0]const u8, to: [*:0]const u8) bool {
    var dir_name: [dos.path_max + 1:0]u8 = @splat(0);
    const part = dl.PathPart(from);
    const length = @intFromPtr(part) - @intFromPtr(from);
    if (length > dos.path_max) {
        _ = dl.SetIoErr(dos.ERROR_LINE_TOO_LONG);
        return false;
    }
    @memcpy(dir_name[0..length], from[0..length]);
    const dir = dl.Lock(@ptrCast(&dir_name), dos.SHARED_LOCK) orelse return false;
    defer dl.UnLock(dir);
    const old = dl.CurrentDir(dir);
    const found = dl.Lock(to, dos.SHARED_LOCK);
    _ = dl.CurrentDir(old);
    const lock = found orelse return false;
    dl.UnLock(lock);
    return true;
}

fn isDirectory(dl: *DosBase, lock: *FileLock) bool {
    const fib: *FileInfoBlock = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_FIB, null) orelse return false));
    defer dl.FreeDosObject(dos.DOS_FIB, fib);
    return dl.Examine(lock, fib) and dos.isDirectory(fib.dir_entry_type);
}
