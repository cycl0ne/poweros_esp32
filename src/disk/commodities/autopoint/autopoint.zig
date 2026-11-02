// SPDX-License-Identifier: MIT
//! AutoPoint: the window under the pointer is the active one, without a
//! click. Built against the SDK only.
//!
//!   AutoPoint CX_PRIORITY/K/N
//!
//! The pointer carries the keyboard with it: whatever window it comes to
//! rest over is activated, so moving to a window is enough to type into
//! it. Nothing is clicked and nothing comes to the front - the window
//! stays where it is in the depth order, and a window covered at that
//! point is not the one activated.
//!
//! It waits for the pointer to stand still: a window is activated only
//! once the pointer has stopped moving, so a sweep across the screen does
//! not activate every window on the way. While a mouse button is held it
//! does nothing at all, so a drag that passes over another window does
//! not take the keyboard away from the one being dragged in.
//!
//! It has no window. The controller (SYS:Commodities/Exchange) can make
//! it inactive and remove it; Ctrl-C from the shell it was started in
//! ends it too. CX_PRIORITY is its place among the commodities.
//!
//! The work is done on the program's own task: the object in the network
//! only signals it, on each of input.device's ticks with no button held,
//! because activating a window takes intuition's screens and nothing in
//! the network may wait.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const utility = sdk.utility;
const intuition = sdk.intuition;
const sc = intuition.screens;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const frame = @import("commodity");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const CxBase = sdk.interface.commodities.CxBase;
const TagItem = utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "AutoPoint";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (02.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "CX_PRIORITY/K/N";
const arg_priority = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory\n";
const MSG_NOSIGNAL = "No signal left\n";
const MSG_DUPLICATE = "%s runs already\n";

/// A tick of input.device with no mouse button held. The buttons are the
/// only qualifiers that count: it works with Caps Lock on or a shift
/// held like any other.
const quiet_tick: cx.InputXpression = .{
    .class = ie.IECLASS_TIMER,
    .code = 0,
    .code_mask = 0,
    .qualifier = 0,
    .qual_mask = ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_MIDBUTTON | ie.IEQUALIFIER_RBUTTON,
};

/// How far the pointer may have moved since the last tick and still count
/// as standing still, in pixels each way.
const still = 4;

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

    const commodity = frame.Commodity.open(sys, cb, .{
        .name = COMMAND_NAME,
        .title = "AutoPoint",
        .descr = "Activates the window pointed at",
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

    const ticks = cx.CxFilter(cb, null);
    cb.SetFilterIX(ticks, &quiet_tick);
    cb.AttachCxObj(ticks, cx.CxSignal(cb, sys.FindTask(null).?, @intCast(bit)));
    if (!commodity.attach(ticks)) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    commodity.activate(true);

    // Where the pointer was at the tick before, to tell a pointer that
    // has come to rest from one still on its way.
    var was: Place = .{};
    while (true) {
        const got = sys.Wait(commodity.signals() | wake);
        if (frame.Commodity.stopped(got)) break;
        if (got & wake != 0) follow(ib, &was);
        while (commodity.next()) |event| switch (event) {
            .end => return dos.RETURN_OK,
            // Made inactive it stops being signalled; the window that
            // was activated keeps the keyboard, as a clicked one would.
            .input, .disabled, .enabled, .show, .hide, .list_changed => {},
        };
    }
    return dos.RETURN_OK;
}

/// Where the pointer was, on which screen.
const Place = struct { screen: ?*intuition.Screen = null, x: usize = 0, y: usize = 0 };

/// The window the pointer has come to rest over, activated. The screens
/// are held throughout: the window found is still open when it is
/// activated, and the pointer cannot move to another in between.
fn follow(ib: *IntuitionBase, was: *Place) void {
    const held = ib.LockIBase(0);
    defer ib.UnlockIBase(held);
    const screen = ib.FrontScreen() orelse {
        was.* = .{};
        return;
    };
    var now: Place = .{ .screen = screen };
    ib.GetScreenAttrs(screen, &[_]TagItem{
        .{ .tag = sc.SA_MouseX, .data = @intFromPtr(&now.x) },
        .{ .tag = sc.SA_MouseY, .data = @intFromPtr(&now.y) },
        .{},
    });
    const settled = now.screen == was.screen and
        apart(now.x, was.x) <= still and apart(now.y, was.y) <= still;
    was.* = now;
    if (!settled) return;
    const window = ib.WindowUnderPointer() orelse return;
    if (window == ib.ActiveWindow()) return;
    ib.ActivateWindow(window);
}

fn apart(a: usize, b: usize) usize {
    return if (a > b) a - b else b - a;
}
