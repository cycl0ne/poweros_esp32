// SPDX-License-Identifier: MIT
//! MakeDir: makes directories. Built against the SDK only.
//!
//!   MakeDir NAME/M
//!
//! One directory per name. A name that is already there is an error and so
//! is one that cannot be made, but it carries on with the rest; the
//! return code is RETURN_ERROR if any of them failed. No name at
//! all is RETURN_FAIL - the template has no /A, so ReadArgs lets it
//! through and the command says so itself.

const sdk = @import("sdk");
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "MakeDir";
const VERSION_STRING = "\x00$VER: MakeDir 1.0 (16.9.2026)\r\n";

const template = "NAME/M";
const arg_name = 0;

const MSG_NONAME = "No name given\n";
const MSG_EXISTS = "%s already exists\n";
const MSG_IDUNNO = "Can't create directory %s\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), null);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const names = rdargs.multi(argv[arg_name]);
    if (names.len == 0) {
        _ = dl.PutStr(MSG_NONAME);
        return dos.RETURN_FAIL;
    }

    var rc: i32 = dos.RETURN_OK;
    var code: i32 = 0;
    for (names) |name| {
        // It looks first, so that "already there" is its own message
        // rather than the handler's.
        if (dl.Lock(name, dos.SHARED_LOCK)) |lock| {
            dl.UnLock(lock);
            rc = dos.RETURN_ERROR;
            code = 0;
            _ = Printf(dl, MSG_EXISTS, .{name});
            continue;
        }
        if (dl.CreateDir(name)) |lock| {
            dl.UnLock(lock);
        } else {
            if (rc != dos.RETURN_ERROR) code = dl.IoErr();
            rc = dos.RETURN_ERROR;
            _ = Printf(dl, MSG_IDUNNO, .{name});
        }
    }
    _ = dl.SetIoErr(code);
    return rc;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs: the linker collects unused
/// sections, and a plain constant never reaches the file at all - which is
/// all the comptime reference that used to stand here achieved.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
