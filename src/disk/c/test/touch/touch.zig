// SPDX-License-Identifier: MIT
//! Touch: what the touch panel is, and what it reports. Built against the
//! SDK only.
//!
//!   Touch INFO/S,STATE/S
//!
//! With nothing asked for it opens touch.device and prints every event as
//! it comes - a finger landing, moving, lifting, with its contact id and
//! where - until Ctrl-C. INFO prints what the panel is and stops; STATE
//! prints where every finger is now and stops.
//!
//! A read waits in the device until something happens, so the command
//! waits for either the read or Ctrl-C, and takes the read back with
//! AbortIO when it is the Ctrl-C.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const touch = sdk.devices.touch;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Touch";
const VERSION_STRING = "\x00$VER: Touch 1.0 (19.9.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "INFO/S,STATE/S";
const arg_info = 0;
const arg_state = 1;

const MSG_NODEVICE = "No %s - no touch controller answered\n";
const MSG_INFO = "Panel      GT%s at 0x%02x, firmware %04x, %dx%d, %d contacts at once\n";
const MSG_STATE = "Contacts   %d\n";
const MSG_CONTACT = "  #%-2d %4d,%-4d size %d\n";
const MSG_WAITING = "Touch the panel - Ctrl-C to stop\n";
const MSG_EVENT = "%-4s #%-2d %4d,%-4d size %-4d at %d.%06d\n";
const MSG_DONE = "%d events\n";
const MSG_FAILED = "The read failed: error %d\n";

fn kindName(kind: u32) [*:0]const u8 {
    return switch (kind) {
        touch.TOUCH_DOWN => "down",
        touch.TOUCH_MOVE => "move",
        touch.TOUCH_UP => "up",
        else => "?",
    };
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    var io: exec.IOStdReq = .{};
    io.req.message.reply_port = port;
    io.req.message.length = @sizeOf(exec.IOStdReq);
    if (sys.OpenDevice(touch.TOUCHNAME, 0, &io.req, 0) != 0) {
        _ = Printf(dl, MSG_NODEVICE, .{touch.TOUCHNAME});
        return dos.RETURN_WARN;
    }
    defer sys.CloseDevice(&io.req);

    if (argv[arg_info] != 0) {
        var info: touch.TouchInfo = .{};
        io.req.command = touch.TOUCH_GETINFO;
        io.data = &info;
        io.length = @sizeOf(touch.TouchInfo);
        _ = sys.DoIO(&io.req);
        const product: [*:0]const u8 = @ptrCast(&info.product);
        _ = Printf(dl, MSG_INFO, .{ product, info.address, info.firmware, info.width, info.height, info.max_contacts });
        return dos.RETURN_OK;
    }

    if (argv[arg_state] != 0) {
        var state: touch.TouchState = .{};
        io.req.command = touch.TOUCH_READSTATE;
        io.data = &state;
        io.length = @sizeOf(touch.TouchState);
        _ = sys.DoIO(&io.req);
        _ = Printf(dl, MSG_STATE, .{state.count});
        for (state.contacts[0..state.count]) |c| {
            _ = Printf(dl, MSG_CONTACT, .{ c.id, c.x, c.y, c.size });
        }
        return dos.RETURN_OK;
    }

    // A Ctrl-C from before this command started is not a request to stop it.
    _ = sys.SetSignal(0, exec.SIGBREAKF_CTRL_C);
    _ = Printf(dl, MSG_WAITING, .{});
    var events: [8]touch.TouchEvent = undefined;
    var total: u32 = 0;
    while (true) {
        io.req.command = touch.TOUCH_READEVENT;
        io.data = &events;
        io.length = @sizeOf(@TypeOf(events));
        sys.SendIO(&io.req);
        const got = sys.Wait(port.sigMask() | exec.SIGBREAKF_CTRL_C);
        if (got & exec.SIGBREAKF_CTRL_C != 0 and sys.CheckIO(&io.req) == null) {
            _ = sys.AbortIO(&io.req);
            _ = sys.WaitIO(&io.req);
            break;
        }
        _ = sys.WaitIO(&io.req);
        if (io.req.err != 0) {
            _ = Printf(dl, MSG_FAILED, .{@as(i32, io.req.err)});
            break;
        }
        var at: ?*touch.TouchEvent = if (io.actual > 0) &events[0] else null;
        while (at) |e| : (at = e.next) {
            _ = Printf(dl, MSG_EVENT, .{ kindName(e.kind), e.id, e.x, e.y, e.size, e.time.secs, e.time.micro });
            total += 1;
        }
        if (got & exec.SIGBREAKF_CTRL_C != 0) break;
    }
    _ = Printf(dl, MSG_DONE, .{total});
    return dos.RETURN_OK;
}
