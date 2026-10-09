// SPDX-License-Identifier: MIT
//! LoadAnvil: starts the desktop. Built against the SDK only.
//!
//!   LoadAnvil CLEANUP/S
//!
//! The desktop runs on a process of its own from anvil.library, so the
//! command returns once it is up; run again while it is up, it brings the
//! desktop's screen to the front. CLEANUP places the disks' icons anew
//! down the desktop's edge. The return code is 0 when the desktop runs,
//! 20 when it could not start, with the reason said.

const sdk = @import("sdk");
const dos = sdk.dos;
const anvil = sdk.anvil;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AnvilBase = sdk.interface.anvil.AnvilBase;

pub const COMMAND_NAME = "LoadAnvil";
const VERSION_STRING = "\x00$VER: LoadAnvil 1.0 (08.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "CLEANUP/S";
const ANVIL_VERSION = 1;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const anvil_lib = sys.OpenLibrary(anvil.ANVILNAME, ANVIL_VERSION) orelse {
        _ = dl.PrintFault(dos.ERROR_INVALID_RESIDENT_LIBRARY, COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(anvil_lib);
    const ab: *AnvilBase = @ptrCast(anvil_lib);
    const tags = [_]utility.TagItem{
        .{ .tag = anvil.ANVA_CleanUp, .data = argv[0] },
        .{},
    };
    if (!ab.StartAnvil(&tags)) {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    return dos.RETURN_OK;
}
