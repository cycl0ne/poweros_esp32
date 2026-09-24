// SPDX-License-Identifier: MIT
//! Rename: a name, or several, moved or renamed. Built against the SDK
//! only.
//!
//!   Rename FROM/A/M,TO=AS/A/K,QUIET/S
//!
//! With one FROM, TO is the new name. With more than one, TO must be a
//! directory, and each keeps its own name inside it. QUIET
//! keeps it from saying what it did.
//!
//! Renaming works within one file system only; dos answers
//! ERROR_RENAME_ACROSS_DEVICES otherwise, and this says so rather than
//! copying.

const sdk = @import("sdk");
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Rename";
const VERSION_STRING = "\x00$VER: Rename 1.0 (16.9.2026)\r\n";

const template = "FROM/A/M,TO=AS/A,QUIET/S";

const MSG_NODIR = "Destination \"%s\" is not a directory.\n";
const MSG_RENAME = "Renaming %s as %s\n";
const arg_from = 0;
const arg_to = 1;
const arg_quiet = 2;

const max_path = 256;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const from = rdargs.multi(argv[arg_from]);
    const to = rdargs.string(argv[arg_to]).?;
    const quiet = argv[arg_quiet] != 0;

    // Several names go into a directory, each keeping its own.
    const into_dir = isDir(dl, to);
    if (from.len > 1 and !into_dir) {
        _ = Printf(dl, MSG_NODIR, .{to});
        return dos.RETURN_ERROR;
    }

    var failed = false;
    for (from) |name| {
        var target: [max_path:0]u8 = @splat(0);
        const full: [*:0]const u8 = if (into_dir) blk: {
            if (!join(dl, &target, to, @ptrCast(dl.FilePart(name)))) {
                _ = dl.PrintFault(dos.ERROR_LINE_TOO_LONG, name);
                failed = true;
                continue;
            }
            break :blk @ptrCast(&target);
        } else to;
        if (!dl.Rename(name, full)) {
            _ = dl.PrintFault(dl.IoErr(), name);
            failed = true;
            continue;
        }
        if (!quiet) _ = Printf(dl, MSG_RENAME, .{ name, full });
    }
    return if (failed) dos.RETURN_ERROR else dos.RETURN_OK;
}

fn isDir(dl: *DosBase, name: [*:0]const u8) bool {
    const lock = dl.Lock(name, dos.SHARED_LOCK) orelse return false;
    defer dl.UnLock(lock);
    var fib: dos.FileInfoBlock = .{};
    return dl.Examine(lock, &fib) and fib.dir_entry_type > 0;
}

fn join(dl: *DosBase, into: *[max_path:0]u8, dir: [*:0]const u8, name: [*:0]const u8) bool {
    var i: usize = 0;
    while (dir[i] != 0) : (i += 1) {
        if (i + 1 >= into.len) return false;
        into[i] = dir[i];
    }
    into[i] = 0;
    return dl.AddPart(@ptrCast(into), name, into.len);
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs: the linker collects unused
/// sections, and a plain constant never reaches the file at all - which is
/// all the comptime reference that used to stand here achieved.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
