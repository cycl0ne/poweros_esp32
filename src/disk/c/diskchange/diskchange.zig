// SPDX-License-Identifier: MIT
//! DiskChange: a handler told to look at its medium again. Built against
//! the SDK only.
//!
//!   DiskChange DEVICE/A
//!
//! A handler for a drive whose medium can be taken out looks at it before
//! every packet, so it notices a card going in or out as soon as anything
//! asks it anything. A drive nobody is using is asked nothing, and its
//! volume on the device list can then be a card that has gone or a card
//! that is not there yet. This asks it one harmless question, which is
//! enough: the handler looks at the medium first and puts its volume
//! where the card now says.
//!
//!   DiskChange SD0:
//!
//! The name is the device's, with or without the colon. A volume's own
//! name will do as well when it is mounted.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "DiskChange";
const VERSION_STRING = "\x00$VER: DiskChange 1.0 (28.09.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DEVICE/A";
const arg_device = 0;

const MSG_NO_HANDLER = "No handler for %s\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    // The name with a colon after it, since that is what names a device
    // rather than a file in the current directory.
    const given = dos.rdargs.string(argv[arg_device]).?;
    var name: [dos.MAX_DEVICE_NAME + 2:0]u8 = @splat(0);
    var i: usize = 0;
    while (given[i] != 0 and i < name.len - 2) : (i += 1) name[i] = given[i];
    if (i == 0 or name[i - 1] != ':') {
        name[i] = ':';
        i += 1;
    }
    name[i] = 0;

    const dp = dl.GetDeviceProc(@ptrCast(&name), null) orelse {
        _ = Printf(dl, MSG_NO_HANDLER, .{@as([*:0]const u8, @ptrCast(&name))});
        return dos.RETURN_ERROR;
    };
    defer dl.FreeDeviceProc(dp);
    const port = dp.port orelse {
        _ = Printf(dl, MSG_NO_HANDLER, .{@as([*:0]const u8, @ptrCast(&name))});
        return dos.RETURN_ERROR;
    };
    // The question itself does not matter; the looking the handler does
    // before answering it is the point.
    _ = dl.DoPkt(port, @intFromEnum(dos.ActionCode.is_filesystem), 0, 0, 0, 0, 0);
    return dos.RETURN_OK;
}
