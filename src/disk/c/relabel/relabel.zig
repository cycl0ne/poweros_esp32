// SPDX-License-Identifier: MIT
//! Relabel: gives the volume in a drive a new name. Built against the SDK
//! only.
//!
//!   Relabel DRIVE/A,NAME/A
//!
//! DRIVE is a device, a volume or an assign to one, with its colon
//! (`SD0:`, `System:`); NAME the new name, without one. The file system
//! keeps the name where its format does - a FAT card's label is eleven
//! characters in upper case - and the volume is known by it at once. The
//! return code is 0 when the volume has the new name, 20 when not, with
//! the reason said.

const sdk = @import("sdk");
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;

pub const COMMAND_NAME = "Relabel";
const VERSION_STRING = "\x00$VER: Relabel 1.0 (08.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DRIVE/A,NAME/A";

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
    const drive: [*:0]const u8 = @ptrFromInt(argv[0]);
    const name: [*:0]const u8 = @ptrFromInt(argv[1]);
    if (!dl.Relabel(drive, name)) {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    return dos.RETURN_OK;
}
