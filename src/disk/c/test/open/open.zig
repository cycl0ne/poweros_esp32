// SPDX-License-Identifier: MIT
//! Open: has the desktop open a file, a drawer or a disk as a double
//! click on its icon opens it (anvil.library's OpenObject). Built against
//! the SDK only.
//!
//!   Open NAME/A,FILES/M,WAIT/S
//!
//! NAME opens with FILES handed on, as icons picked with it are: a drawer
//! or a disk in its window, a file by the program that opens it. WAIT
//! gives the desktop an end message and waits for it to come back - once
//! the program started has ended, at once for a drawer - and says so.
//! The message is Open's, so Ctrl-C does not end the wait: it only says
//! what Open waits for.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const anvil = sdk.anvil;
const TagItem = sdk.utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const AnvilBase = sdk.interface.anvil.AnvilBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Open";
const VERSION_STRING = "\x00$VER: Open 1.0 (27.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME/A,FILES/M,WAIT/S";
const arg_name = 0;
const arg_files = 1;
const arg_wait = 2;

/// The revision OpenObject came with.
const open_revision = 16;

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [3]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const anvil_lib = sys.OpenLibrary(anvil.ANVILNAME, 1) orelse {
        _ = Printf(dl, "%s: no %s\n", .{ COMMAND_NAME, anvil.ANVILNAME });
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(anvil_lib);
    if (anvil_lib.version == 1 and anvil_lib.revision < open_revision) {
        _ = Printf(dl, "%s: %s is older than 1.%u\n", .{ COMMAND_NAME, anvil.ANVILNAME, @as(u32, open_revision) });
        return dos.RETURN_FAIL;
    }
    const ab: *AnvilBase = @ptrCast(anvil_lib);

    // The end message's port, made only to wait.
    const wait = argv[arg_wait] != 0;
    const port: ?*exec.MsgPort = if (wait) sys.CreateMsgPort() orelse {
        _ = dl.PrintFault(dos.ERROR_NO_FREE_STORE, COMMAND_NAME);
        return dos.RETURN_FAIL;
    } else null;
    defer sys.DeleteMsgPort(port);
    var end_msg = exec.Message{ .reply_port = port, .length = @sizeOf(exec.Message) };

    const files = dos.rdargs.multi(argv[arg_files]);
    var tags: [anvil.OPEN_FILES_MAX + 2]TagItem = undefined;
    var count: usize = 0;
    for (files[0..@min(files.len, anvil.OPEN_FILES_MAX)]) |file| {
        tags[count] = .{ .tag = anvil.ANVO_File, .data = @intFromPtr(file) };
        count += 1;
    }
    if (wait) {
        tags[count] = .{ .tag = anvil.ANVO_EndMsg, .data = @intFromPtr(&end_msg) };
        count += 1;
    }
    tags[count] = .{};

    const name: [*:0]const u8 = @ptrFromInt(argv[arg_name]);
    if (!ab.OpenObject(name, &tags)) {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    }
    _ = Printf(dl, "%s: %s opened\n", .{ COMMAND_NAME, name });
    const waited = port orelse return dos.RETURN_OK;
    while (true) {
        const got = sys.Wait(waited.sigMask() | exec.SIGBREAKF_CTRL_C);
        if (sys.GetMsg(waited) != null) break;
        if (got & exec.SIGBREAKF_CTRL_C != 0) {
            _ = Printf(dl, "%s: waiting on, as the end message is this program's\n", .{COMMAND_NAME});
        }
    }
    _ = Printf(dl, "%s: %s has ended\n", .{ COMMAND_NAME, name });
    return dos.RETURN_OK;
}
