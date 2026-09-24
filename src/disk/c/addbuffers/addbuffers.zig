// SPDX-License-Identifier: MIT
//! AddBuffers: tells a file system to keep more of the medium in memory, and
//! says how many it keeps now. Built against the SDK only.
//!
//!   AddBuffers DRIVE/A,BUFFERS/N
//!
//! It is ACTION_MORE_CACHE to the handler and nothing else: the number is
//! added to what it has, a negative one takes some away, and it answers
//! with the total. Without BUFFERS it asks for none, which reads the
//! current figure.
//!
//! A handler that knows nothing of buffers answers ERROR_ACTION_NOT_KNOWN
//! and that is what is printed. The flash file system has no buffers of its
//! own - it reads the medium through its mapping - so it answers with the
//! number its mountlist gave it and keeps it.

const sdk = @import("sdk");
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "AddBuffers";
const VERSION_STRING = "\x00$VER: AddBuffers 1.0 (16.9.2026)\r\n";

const template = "DRIVE/A,BUFFERS/N";
const arg_drive = 0;
const arg_buffers = 1;

const MSG_CURRENT = "%s has %d buffers\n";
const MSG_INVALID_DEVICE = "Invalid device or volume name '%s'\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const drive = rdargs.string(argv[arg_drive]).?;
    const more: i32 = rdargs.number(argv[arg_buffers]) orelse 0;

    const dp = dl.GetDeviceProc(drive, null) orelse {
        _ = Printf(dl, MSG_INVALID_DEVICE, .{drive});
        return dos.RETURN_ERROR;
    };
    defer dl.FreeDeviceProc(dp);
    const port = dp.port orelse {
        _ = Printf(dl, MSG_INVALID_DEVICE, .{drive});
        return dos.RETURN_ERROR;
    };

    const total = dl.DoPkt(port, @intFromEnum(dos.ActionCode.more_cache), more, 0, 0, 0, 0);
    if (total == dos.DOSFALSE) {
        _ = dl.PrintFault(dl.IoErr(), drive);
        return dos.RETURN_ERROR;
    }
    _ = Printf(dl, MSG_CURRENT, .{ drive, @as(i32, @intCast(total)) });
    return dos.RETURN_OK;
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs: the linker collects unused
/// sections, and a plain constant never reaches the file at all - which is
/// all the comptime reference that used to stand here achieved.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
