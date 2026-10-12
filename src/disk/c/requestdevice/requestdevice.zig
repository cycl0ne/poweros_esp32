// SPDX-License-Identifier: MIT
//! RequestDevice: the shell asks which device and unit, and is told.
//! Built against the SDK only.
//!
//!   RequestDevice SPEAKS,TITLE/K,POSITIVE/K,NEGATIVE/K,DEVICE/K,UNIT/K/N,
//!                 PUBSCREEN/K
//!
//! It puts up asl.library's device requester, which lists the units of
//! the devices that speak SPEAKS - `serial`, `sana2`, `block`, ... as
//! ShowConfig DEVICES names them; every device without it - and writes
//! the device's name in quotes and the unit after it, which is what a
//! command that opens a device takes:
//!
//!   1> RequestDevice serial TITLE="Which line?"
//!   "serial.device" 1
//!
//! DEVICE and UNIT say which line the requester starts on. A requester
//! given up writes nothing and ends with a warning, which is what lets a
//! script tell "nothing picked" from an answer.

const sdk = @import("sdk");
const dos = sdk.dos;
const asl = sdk.asl;
const devices = sdk.expansion.devices;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AslBase = sdk.interface.asl.AslBase;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "RequestDevice";
const VERSION_STRING = "\x00$VER: RequestDevice 1.0 (12.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "SPEAKS,TITLE/K,POSITIVE/K,NEGATIVE/K,DEVICE/K,UNIT/K/N,PUBSCREEN/K";
const arg_speaks = 0;
const arg_title = 1;
const arg_positive = 2;
const arg_negative = 3;
const arg_device = 4;
const arg_unit = 5;
const arg_pubscreen = 6;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOREQUEST = "No requester\n";

fn textLen(text: [*:0]const u8) usize {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return n;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [7]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    var speaks: u32 = 0;
    if (dos.rdargs.string(argv[arg_speaks])) |name| {
        speaks = devices.devifByName(name[0..textLen(name)]);
        if (speaks == 0) {
            _ = Printf(dl, "%s: no command set \"%s\"; one of:", .{ COMMAND_NAME, name });
            var set: u32 = 1;
            while (devices.devifName(set)) |known| : (set += 1) _ = Printf(dl, " %s", .{known});
            _ = dl.PutStr("\n");
            return dos.RETURN_FAIL;
        }
    }

    const asl_lib = sys.OpenLibrary(asl.ASLNAME, 0) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{asl.ASLNAME});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(asl_lib);
    const ab: *AslBase = @ptrCast(asl_lib);

    const ignore = sdk.utility.TAG_IGNORE;
    const unit: u32 = if (dos.rdargs.number(argv[arg_unit])) |given| @bitCast(given) else 0;
    const handle = ab.AllocAslRequest(asl.ASL_DeviceRequest, &[_]TagItem{
        .{ .tag = asl.ASLDR_TitleText, .data = @intFromPtr(dos.rdargs.string(argv[arg_title]) orelse "Select a device") },
        .{ .tag = if (argv[arg_positive] != 0) asl.ASLDR_PositiveText else ignore, .data = argv[arg_positive] },
        .{ .tag = if (argv[arg_negative] != 0) asl.ASLDR_NegativeText else ignore, .data = argv[arg_negative] },
        .{ .tag = if (argv[arg_pubscreen] != 0) asl.ASLDR_PubScreenName else ignore, .data = argv[arg_pubscreen] },
        .{ .tag = if (argv[arg_device] != 0) asl.ASLDR_InitialDevice else ignore, .data = argv[arg_device] },
        .{ .tag = asl.ASLDR_InitialUnit, .data = unit },
        .{ .tag = asl.ASLDR_Speaks, .data = speaks },
        .{},
    }) orelse {
        _ = Printf(dl, MSG_NOREQUEST, .{});
        return dos.RETURN_FAIL;
    };
    defer ab.FreeAslRequest(handle);
    const req: *asl.DeviceRequester = @ptrCast(@alignCast(handle));

    if (!ab.AslRequest(handle, null)) return dos.RETURN_WARN;
    _ = Printf(dl, "\"%s\" %u\n", .{ req.device orelse "", req.unit });
    return dos.RETURN_OK;
}
