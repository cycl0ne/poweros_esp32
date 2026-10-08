// SPDX-License-Identifier: MIT
//! Notify: watches files and directories (StartNotify) and prints each
//! change it is told of. Built against the SDK only.
//!
//!   Notify NAME/M/A,COUNT/K/N,INITIAL/S,SIGNAL/S
//!
//! Each NAME is watched - it need not be there yet - and every message
//! that comes is printed with the name it is about, until COUNT of them
//! came or Ctrl-C. INITIAL asks to be told once at the start of each name
//! that is there. SIGNAL asks for a signal instead of a message, and all
//! the names share it, so a change is printed without its name. A name
//! whose handler cannot watch is said, and the rest are watched.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const notify = dos.notify;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Notify";
const VERSION_STRING = "\x00$VER: Notify 1.0 (08.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "NAME/M/A,COUNT/K/N,INITIAL/S,SIGNAL/S";
const arg_name = 0;
const arg_count = 1;
const arg_initial = 2;
const arg_signal = 3;

const names_max = 16;

const MSG_CANNOT = "%s: %s cannot be watched";
const MSG_WATCHING = "Watching %lu names; Ctrl-C stops\n";
const MSG_CHANGED = "%s changed\n";
const MSG_SIGNALLED = "a name changed\n";

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [4]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const given = dos.rdargs.multi(argv[arg_name]);
    const names = given[0..@min(given.len, names_max)];
    const most: u64 = if (dos.rdargs.number(argv[arg_count])) |value| @intCast(@max(value, 0)) else 0;
    const signalled = argv[arg_signal] != 0;

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    const signal = if (signalled) sys.AllocSignal(-1) else -1;
    if (signalled and signal < 0) return dos.RETURN_FAIL;
    defer if (signal >= 0) sys.FreeSignal(signal);

    var requests: [names_max]notify.NotifyRequest = undefined;
    var watched: [names_max]bool = @splat(false);
    var count: u64 = 0;
    for (names, 0..) |name, index| {
        requests[index] = .{
            .name = name,
            .user_data = index,
            .flags = (if (signalled) notify.NRF_SEND_SIGNAL else notify.NRF_SEND_MESSAGE) |
                (if (argv[arg_initial] != 0) notify.NRF_NOTIFY_INITIAL else 0),
            .port = port,
            .task = sys.FindTask(null),
            .signal_number = if (signal >= 0) @intCast(signal) else 0,
        };
        watched[index] = dl.StartNotify(&requests[index]);
        if (!watched[index]) {
            _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
            _ = Printf(dl, MSG_CANNOT ++ "\n", .{ COMMAND_NAME, name });
        } else {
            count += 1;
        }
    }
    defer for (names, 0..) |_, index| {
        if (watched[index]) dl.EndNotify(&requests[index]);
    };
    if (count == 0) return dos.RETURN_WARN;
    _ = Printf(dl, MSG_WATCHING, .{count});
    _ = dl.Flush(dl.Output());

    const wake: u32 = (if (signal >= 0) @as(u32, 1) << @intCast(signal) else port.sigMask()) | exec.SIGBREAKF_CTRL_C;
    var told: u64 = 0;
    while (most == 0 or told < most) {
        const got = sys.Wait(wake);
        if (signal >= 0 and got & (@as(u32, 1) << @intCast(signal)) != 0) {
            _ = Printf(dl, MSG_SIGNALLED, .{});
            told += 1;
        }
        while (sys.GetMsg(port)) |message| {
            const changed: *notify.NotifyMessage = @fieldParentPtr("message", message);
            const index = changed.request.?.user_data;
            sys.ReplyMsg(message);
            _ = Printf(dl, MSG_CHANGED, .{names[index]});
            told += 1;
        }
        _ = dl.Flush(dl.Output());
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
    }
    return dos.RETURN_OK;
}
