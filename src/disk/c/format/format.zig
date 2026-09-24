// SPDX-License-Identifier: MIT
//! Format: a disk emptied and given a name. Built against the SDK only.
//!
//!   Format DRIVE=DEVICE/K/A,NAME/K/A,QUICK/S
//!
//!   Format DRIVE DH0: NAME "System"
//!
//! The template holds only what means anything here. There are no FFS,
//! INTL or NOICONS switches: there is one file system and no Workbench, so
//! a switch that could only be ignored is left out rather than accepted and
//! quietly dropped. There is no NOVERIFY for the same reason: nothing here
//! reads a sector back.
//!
//! QUICK writes a new, empty
//! file system over the old one instead of erasing the medium first. It is
//! what flashfs-handler's ACTION_FORMAT does in either case - a log file
//! system starts a new log and the old records are simply never replayed -
//! so QUICK only says that no erase is expected.
//!
//! It asks before it does anything:
//!
//!   Format: Insert the disk to be formatted in device DH0:
//!   Press RETURN to begin formatting or CTRL-C to abort:
//!
//! Since the answer is read from Input(), a script may feed it a blank
//! line. There is nothing else between a typo and the disk.
//!
//! The device takes either keyword, DRIVE or DEVICE (`DRIVE=DEVICE/K/A`):
//! `Format DRIVE DH0: NAME "Empty"` and `Format DEVICE DH0: NAME "Empty"`
//! both work. It
//! takes a device with or without its colon.
//!
//! The DosType handed to the handler is the device node's own de_DosType,
//! read from the DosList, not a constant: a node mounted from a
//! RigidDiskBlock says which file system it is, and Format has no business
//! deciding that.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const rdargs = dos.rdargs;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Format";
const VERSION_STRING = "\x00$VER: Format 1.0 (16.9.2026)\r\n";

const template = "DRIVE=DEVICE/K/A,NAME/K/A,QUICK/S";
const arg_device = 0;
const arg_name = 1;
const arg_quick = 2;

const MSG_INSERT = "Format: Insert the disk to be formatted in device %s\n";
const MSG_PRESS = "Press RETURN to begin formatting or CTRL-C to abort: ";
const MSG_NOTFS = "%s is not a file system\n";
const MSG_DONE = "Format complete.\n";

/// The most a device name may be: 30, the colon and the NUL.
const max_device = dos.MAX_DEVICE_NAME + 2;

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

    const asked = rdargs.string(argv[arg_device]).?;
    const label = rdargs.string(argv[arg_name]).?;

    // "DH0" and "DH0:" both name the device; the colon is what
    // GetDeviceProc wants, and what the messages read best with.
    var device: [max_device:0]u8 = @splat(0);
    var at: usize = 0;
    while (asked[at] != 0 and asked[at] != ':' and at + 2 < device.len) : (at += 1) {
        device[at] = asked[at];
    }
    if (at == 0 or asked[at] == ':' and asked[at + 1] != 0) {
        _ = dl.PrintFault(dos.ERROR_INVALID_COMPONENT_NAME, asked);
        return dos.RETURN_FAIL;
    }
    device[at] = ':';
    const name: [*:0]const u8 = @ptrCast(&device);

    const dp = dl.GetDeviceProc(name, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), name);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeDeviceProc(dp);
    const port = dp.port orelse {
        _ = Printf(dl, MSG_NOTFS, .{name});
        return dos.RETURN_FAIL;
    };

    // The DosType belongs to the node, not to Format: a node mounted from
    // a RigidDiskBlock carries the file system its partition asked for.
    const dos_type = dosTypeOf(dp);

    _ = Printf(dl, MSG_INSERT, .{name});
    if (!confirm(dl)) {
        _ = dl.PrintFault(dos.ERROR_BREAK, null);
        return dos.RETURN_WARN;
    }

    if (dl.DoPkt(port, @intFromEnum(dos.ActionCode.format), @bitCast(@intFromPtr(label)), @bitCast(@as(usize, dos_type)), 0, 0, 0) == dos.DOSFALSE) {
        _ = dl.PrintFault(dl.IoErr(), name);
        return dos.RETURN_FAIL;
    }
    _ = dl.PutStr(MSG_DONE);
    return dos.RETURN_OK;
}

/// The de_DosType of the device node the name led to, or 0 when the node
/// says nothing (an assign, or a handler mounted without an environment).
fn dosTypeOf(dp: *dos.DevProc) u32 {
    const node = dp.dev_node orelse return 0;
    if (node.type != .device) return 0;
    const startup: ?*const dos.FileSysStartupMsg = @ptrFromInt(node.misc.handler.startup);
    const msg = startup orelse return 0;
    const environ = msg.environ orelse return 0;
    return environ.dos_type;
}

/// RETURN, or Ctrl-C. A line is read rather than a character so that a
/// script can answer with a blank one.
fn confirm(dl: *DosBase) bool {
    _ = dl.PutStr(MSG_PRESS);
    _ = dl.Flush(dl.Output());
    while (true) {
        if (dl.CheckSignal(exec.SIGBREAKF_CTRL_C) != 0) return false;
        const c = dl.FGetC(dl.Input());
        if (c < 0) return false; // end of input, or a broken stream
        if (c == '\n') return true;
    }
}

/// The "$VER:" string every PowerOS module carries, which `Version <file>`
/// looks for. Nothing refers to it, so it needs both an export and a
/// section of its own that program.ld KEEPs.
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;
