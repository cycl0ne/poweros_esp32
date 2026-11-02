// SPDX-License-Identifier: MIT
//! MouseBlanker: the pointer out of the way while the keyboard is in use.
//! Built against the SDK only.
//!
//!   MouseBlanker CX_PRIORITY/K/N
//!
//! As soon as a key is typed the pointer stops being drawn, and the first
//! move of the mouse brings it back. Nothing else changes: the pointer is
//! still where it was, a press still reaches whatever it stands over -
//! only the picture of it is not in the way of what is being typed.
//!
//! A key held with a command key is a menu shortcut, where the pointer is
//! wanted: those leave it alone. So does every key once the pointer is
//! already blanked, so holding a key down does not fight the mouse.
//!
//! It has no window. The controller (SYS:Commodities/Exchange) can make
//! it inactive, which brings the pointer back and leaves it alone, and
//! remove it; Ctrl-C from the shell it was started in ends it too, and
//! the pointer comes back either way. CX_PRIORITY is its place among the
//! commodities.
//!
//! The key that blanks the pointer is not kept from the windows: it is
//! typed where it was aimed, and the blanking is all this commodity does
//! with it. The work itself is done on the program's own task - the
//! custom object in the network may not wait, and hiding the pointer
//! takes intuition's screens - so it looks at each event, decides what
//! the pointer should be, and signals the task when that has changed.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const frame = @import("commodity");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const CxBase = sdk.interface.commodities.CxBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "MouseBlanker";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (02.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "CX_PRIORITY/K/N";
const arg_priority = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory\n";
const MSG_NOSIGNAL = "No signal left\n";
const MSG_DUPLICATE = "%s runs already\n";

/// What the custom object in the network and the program's task share:
/// the task to wake, and what the pointer should be. The custom object's
/// function is handed nothing of the program's own, and this is the one
/// program of its name (NBU_UNIQUE).
const Watch = struct {
    sys: ?*ExecBase = null,
    task: ?*exec.Task = null,
    mask: u32 = 0,
    /// What the keys and the mouse say the pointer should be now.
    hidden: bool = false,
};
var watch: Watch = .{};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    var settings = frame.Settings.read(sys, dl, COMMAND_NAME, template, &argv) orelse return dos.RETURN_FAIL;
    defer settings.done();
    var priority: i32 = 0;
    settings.number("CX_PRIORITY", arg_priority, &priority);

    const names = [_][*:0]const u8{ intuition.INTUITIONNAME, cx.COMMODITIESNAME };
    var libraries: [names.len]?*exec.Library = @splat(null);
    defer for (libraries) |lib| sys.CloseLibrary(lib);
    for (names, 0..) |name, i| {
        libraries[i] = sys.OpenLibrary(name, 0) orelse {
            _ = Printf(dl, MSG_NOLIBRARY, .{name});
            return dos.RETURN_FAIL;
        };
    }
    const ib: *IntuitionBase = @ptrCast(libraries[0].?);
    const cb: *CxBase = @ptrCast(libraries[1].?);

    const bit = sys.AllocSignal(-1);
    if (bit < 0) {
        _ = Printf(dl, MSG_NOSIGNAL, .{});
        return dos.RETURN_FAIL;
    }
    defer sys.FreeSignal(bit);
    const wake: u32 = @as(u32, 1) << @as(u5, @intCast(bit));
    watch = .{ .sys = sys, .task = sys.FindTask(null), .mask = wake };

    const commodity = frame.Commodity.open(sys, cb, .{
        .name = COMMAND_NAME,
        .title = "MouseBlanker",
        .descr = "Hides the pointer while typing",
        .unique = cx.NBU_UNIQUE | cx.NBU_NOTIFY,
        .pri = priority,
    }) catch |err| {
        switch (err) {
            error.Duplicate => _ = Printf(dl, MSG_DUPLICATE, .{@as([*:0]const u8, COMMAND_NAME)}),
            error.NoMemory => _ = Printf(dl, MSG_NOMEMORY, .{}),
        }
        return if (err == error.Duplicate) dos.RETURN_WARN else dos.RETURN_FAIL;
    };
    defer commodity.close();
    // However it ends, the pointer is left where it can be seen.
    defer ib.HidePointer(false);

    // Every event, whatever its class: what the pointer should be depends
    // on the keys and on the mouse both.
    if (!commodity.attach(cx.CxCustom(cb, &watched, 0))) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    commodity.activate(true);

    var hidden = false;
    while (true) {
        const got = sys.Wait(commodity.signals() | wake);
        if (frame.Commodity.stopped(got)) break;
        // The state the network last decided on, which may have changed
        // more than once while the task was asleep.
        const want = watch.hidden;
        if (want != hidden) {
            ib.HidePointer(want);
            hidden = want;
        }
        while (commodity.next()) |event| switch (event) {
            .end => return dos.RETURN_OK,
            // Made inactive, it sees no more keys: the pointer comes
            // back and stays until it is active again.
            .disabled => {
                watch.hidden = false;
                if (hidden) {
                    ib.HidePointer(false);
                    hidden = false;
                }
            },
            .input, .enabled, .show, .hide, .list_changed => {},
        };
    }
    return dos.RETURN_OK;
}

/// One event looked at: a key typed hides the pointer, the mouse brings
/// it back, and the task is woken when that has changed. On input.device's
/// task, inside the network: it may not wait, so it only decides and
/// signals.
fn watched(cb: *CxBase, cxm: *cx.CxMsg, _: *cx.CxObj) callconv(.c) void {
    const event = cb.CxMsgData(cxm) orelse return;
    const want = switch (event.class) {
        ie.IECLASS_RAWKEY => blk: {
            // A key going up is the end of one already counted, and a
            // menu shortcut is a key that wants the pointer.
            if (event.code & ie.IECODE_UP_PREFIX != 0) return;
            if (event.qualifier & (ie.IEQUALIFIER_LCOMMAND | ie.IEQUALIFIER_RCOMMAND) != 0) return;
            break :blk true;
        },
        ie.IECLASS_RAWMOUSE, ie.IECLASS_NEWPOINTERPOS => false,
        else => return,
    };
    if (want == watch.hidden) return;
    watch.hidden = want;
    const sys = watch.sys orelse return;
    sys.Signal(watch.task orelse return, watch.mask);
}
