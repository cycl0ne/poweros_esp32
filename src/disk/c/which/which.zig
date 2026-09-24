// SPDX-License-Identifier: MIT
//! Which: where the shell would find a command. Built against the SDK only.
//!
//!   Which FILE/A,NORES/S,RES/S,ALL/S
//!
//! It looks where the shell looks, in the shell's order: the resident list
//! first, then the current directory, then each directory of the command
//! path, then C:. The first thing found is printed and that is the end of
//! it; ALL keeps going and prints every one.
//!
//!   INTERNAL Echo      a built-in of the shell (seg_UC = CMD_INTERNAL)
//!   RES Hello          a program `Resident` put on the list
//!   DH0:C/Dir          a file, by its full path
//!
//! NORES skips the resident list, RES looks at nothing else.
//!
//! A file counts only if the shell could run it: it must not be a
//! directory, and either the S bit is set (a script) or the E bit is clear
//! - the E bit reads backwards, so clear means executable. The one
//! exception: a FILE that ends in ':' is a device, and a directory is
//! allowed to match then.
//!
//! It prints "INTERNAL <name> ;(DISABLED)" for a built-in that has been
//! turned off and carries on looking, but nothing here disables one yet.
//! The search of C: swaps pr_FileSystemTask around GetDeviceProc so that a
//! multi-assign is followed.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Which";
const VERSION_STRING = "\x00$VER: Which 1.0 (16.9.2026)\r\n";

const template = "FILE/A,NORES/S,RES/S,ALL/S";
const arg_file = 0;
const arg_nores = 1;
const arg_res = 2;
const arg_all = 3;

const max_path = 256;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const name = rdargs.string(argv[arg_file]).?;
    const all = argv[arg_all] != 0;
    const res_only = argv[arg_res] != 0;

    const buffer = sys.AllocVec(max_path, exec.MEMF_CLEAR) orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(buffer);
    const path: [*]u8 = @ptrCast(buffer);

    // RETURN_WARN while nothing has been found: the answer for "no".
    var rc: i32 = dos.RETURN_WARN;

    // The resident list, which the shell searches before anything else.
    if (argv[arg_nores] == 0) {
        if (dl.LockSegmentList(true)) |_| {
            defer dl.UnLockSegmentList();
            const found = dl.FindSegment(name, null, true) orelse dl.FindSegment(name, null, false);
            if (found) |segment| switch (segment.uc) {
                dos.CMD_INTERNAL => {
                    _ = Printf(dl, "INTERNAL %s\n", .{name});
                    rc = dos.RETURN_OK;
                },
                dos.CMD_DISABLED => {
                    // Off, so the search goes on past it.
                    _ = Printf(dl, "INTERNAL %s ;(DISABLED)\n", .{name});
                },
                else => {
                    _ = Printf(dl, "RES %s\n", .{name});
                    rc = dos.RETURN_OK;
                },
            };
        }
    }
    if (res_only) return rc;

    // The current directory, read as pr_CurrentDir straight out of the
    // process; there is no call that gives it without swapping it.
    const proc: *dos.Process = @ptrCast(@alignCast(sys.FindTask(null).?));
    var length: usize = 0;
    while (name[length] != 0) length += 1;
    const is_device = length != 0 and name[length - 1] == ':';
    if (all or rc != dos.RETURN_OK) {
        if (testLock(dl, proc.current_dir, name, path, is_device)) rc = dos.RETURN_OK;
    }

    // The command path, and C: after it - but only for a plain name: a
    // name with a path in it has already said where to look.
    if ((all or rc != dos.RETURN_OK) and dl.FilePart(name) == name) {
        if (dl.Cli()) |cli| {
            var node = cli.command_dir;
            while (node) |p| : (node = p.next) {
                if (!all and rc == dos.RETURN_OK) break;
                if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
                    _ = dl.PrintFault(dos.ERROR_BREAK, null);
                    return dos.RETURN_WARN;
                }
                if (testLock(dl, p.lock, name, path, false)) rc = dos.RETURN_OK;
            }
        }

        if (all or rc != dos.RETURN_OK) {
            // C:, and every directory of it if it is a multi-assign. The
            // file system task goes with each one: the lock
            // GetDeviceProc hands back belongs to that handler.
            const was = dl.GetFileSysTask();
            var dp: ?*dos.DevProc = null;
            while (true) {
                if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) {
                    _ = dl.PrintFault(dos.ERROR_BREAK, null);
                    break;
                }
                dp = dl.GetDeviceProc("C:", dp);
                const it = dp orelse break;
                _ = dl.SetFileSysTask(it.port);
                if (testLock(dl, it.lock, name, path, false)) rc = dos.RETURN_OK;
                if (!all and rc == dos.RETURN_OK) break;
                if (it.flags & dos.DVPF_ASSIGN == 0) break;
                if (dl.IoErr() != dos.ERROR_OBJECT_NOT_FOUND) break;
            }
            _ = dl.SetFileSysTask(was);
            if (dp) |it| dl.FreeDeviceProc(it);
        }
    }
    return rc;
}

/// Is `name` in `dir`, and is it something the shell would
/// run? Prints its full path if so.
fn testLock(
    dl: *DosBase,
    dir: ?*dos.FileLock,
    name: [*:0]const u8,
    path: [*]u8,
    device: bool,
) bool {
    const was = dl.CurrentDir(dir);
    defer _ = dl.CurrentDir(was);

    const lock = dl.Lock(name, dos.SHARED_LOCK) orelse return false;
    defer dl.UnLock(lock);

    var fib: dos.FileInfoBlock = .{};
    if (!dl.Examine(lock, &fib)) return false;
    // Not a directory, unless the name was a device's; and either a script
    // or executable (the E bit reads backwards: clear means it may run).
    if (!(fib.dir_entry_type < 0 or device)) return false;
    if (fib.protection & dos.FIBF_SCRIPT == 0 and fib.protection & dos.FIBF_EXECUTE != 0) return false;

    if (!dl.NameFromLock(lock, path, max_path)) return false;
    _ = Printf(dl, "%s\n", .{@as([*:0]const u8, @ptrCast(path))});
    return true;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
