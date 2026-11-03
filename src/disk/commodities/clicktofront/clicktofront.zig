// SPDX-License-Identifier: MIT
//! ClickToFront: a double click brings a window to the front. Built
//! against the SDK only.
//!
//!   ClickToFront CX_PRIORITY/K/N,QUALIFIER/K
//!
//! Two clicks of the left button in a window, within the double-click
//! time, bring that window in front of the others - the window it is
//! covered by does not have to be moved out of the way first. The clicks
//! themselves still reach the window, so a double click that means
//! something there means it as well.
//!
//! QUALIFIER makes it need a key held: it is a qualifier word a filter
//! description takes - SHIFT, LSHIFT, RSHIFT, CTRL, ALT, LALT, RALT,
//! LCOMMAND, RCOMMAND - and SHIFT and ALT are either of their pair. With
//! none given, a plain double click with nothing held does it. Caps Lock
//! never counts either way.
//!
//! It has no window. The controller (SYS:Commodities/Exchange) can make
//! it inactive and remove it; Ctrl-C from the shell it was started in
//! ends it too. CX_PRIORITY is its place among the commodities.
//!
//! The two clicks are counted in the network, where the event's own time
//! is; the window is found and moved on the program's task, which the
//! second click signals - nothing in the network may wait, and both take
//! intuition's screens. The window is the one the pointer stands over as
//! the second click lands, so a double click whose two halves are in
//! different windows brings the second one forward.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const intuition = sdk.intuition;
const wn = sdk.intuition.windows;
const TagItem = sdk.utility.TagItem;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const frame = @import("commodity");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const CxBase = sdk.interface.commodities.CxBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "ClickToFront";
const VERSION = "1.1";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (03.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "CX_PRIORITY/K/N,QUALIFIER/K";
const arg_priority = 0;
const arg_qualifier = 1;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory\n";
const MSG_NOSIGNAL = "No signal left\n";
const MSG_DUPLICATE = "%s runs already\n";
const MSG_BADQUALIFIER = "Not a qualifier: %s\n";

/// The qualifiers that count: the keys someone holds. Caps Lock, the
/// keypad's mark and a key repeating say nothing about what is held, and
/// a click with Caps Lock on is still a click.
const counts: u32 = ie.IEQUALIFIER_LSHIFT | ie.IEQUALIFIER_RSHIFT | ie.IEQUALIFIER_CONTROL |
    ie.IEQUALIFIER_LALT | ie.IEQUALIFIER_RALT | ie.IEQUALIFIER_LCOMMAND | ie.IEQUALIFIER_RCOMMAND |
    ie.IEQUALIFIER_LEFTBUTTON | ie.IEQUALIFIER_MIDBUTTON | ie.IEQUALIFIER_RBUTTON;

/// What the custom object in the network and the program's task share.
/// The custom object's function is handed nothing of the program's own,
/// and this is the one program of its name (NBU_UNIQUE).
const Clicks = struct {
    sys: ?*ExecBase = null,
    ib: ?*IntuitionBase = null,
    task: ?*exec.Task = null,
    mask: u32 = 0,
    /// When the click before this one was, 0 for none to pair with.
    seconds: u32 = 0,
    micros: u32 = 0,
};
var clicks: Clicks = .{};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [2]usize = @splat(0);
    var settings = frame.Settings.read(sys, dl, COMMAND_NAME, template, &argv) orelse return dos.RETURN_FAIL;
    defer settings.done();
    var priority: i32 = 0;
    settings.number("CX_PRIORITY", arg_priority, &priority);
    var qualifier: [64:0]u8 = @splat(0);
    settings.copy("QUALIFIER", arg_qualifier, &qualifier);

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

    // The press, with whatever QUALIFIER names held: a description, so
    // that the qualifier words are the ones every filter takes.
    var description: [128:0]u8 = @splat(0);
    joinDescription(&description, &qualifier);
    var press: cx.InputXpression = .{};
    if (cb.ParseIX(&description, &press) != 0) {
        _ = Printf(dl, MSG_BADQUALIFIER, .{@as([*:0]const u8, &qualifier)});
        return dos.RETURN_ERROR;
    }
    press.qual_mask &= counts;

    const bit = sys.AllocSignal(-1);
    if (bit < 0) {
        _ = Printf(dl, MSG_NOSIGNAL, .{});
        return dos.RETURN_FAIL;
    }
    defer sys.FreeSignal(bit);
    const wake: u32 = @as(u32, 1) << @as(u5, @intCast(bit));
    clicks = .{ .sys = sys, .ib = ib, .task = sys.FindTask(null), .mask = wake };

    const commodity = frame.Commodity.open(sys, cb, .{
        .name = COMMAND_NAME,
        .title = "ClickToFront",
        .descr = "A double click brings a window up",
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

    const presses = cx.CxFilter(cb, null);
    cb.SetFilterIX(presses, &press);
    cb.AttachCxObj(presses, cx.CxCustom(cb, &clicked, 0));
    if (!commodity.attach(presses)) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    commodity.activate(true);

    while (true) {
        const got = sys.Wait(commodity.signals() | wake);
        if (frame.Commodity.stopped(got)) break;
        if (got & wake != 0) toFront(ib);
        while (commodity.next()) |event| switch (event) {
            .end => return dos.RETURN_OK,
            // Made inactive it sees no more clicks; the pair half
            // counted is forgotten, so the first click after it is
            // active again is a first click.
            .disabled => clicks.seconds = 0,
            .input, .enabled, .show, .hide, .list_changed => {},
        };
    }
    return dos.RETURN_OK;
}

/// The window the pointer stands over brought in front of the others.
/// The screens are held throughout, so the window found is still open
/// when it is moved.
fn toFront(ib: *IntuitionBase) void {
    const held = ib.LockIBase(0);
    defer ib.UnlockIBase(held);
    const window = ib.WindowUnderPointer() orelse return;
    // A backdrop window is the ground the others stand on - the desktop's
    // is the whole screen - and brought forward it would cover every one
    // of them. A double click on the ground means nothing here.
    if (windowAttr(ib, window, wn.WA_Flags) & wn.WFLG_BACKDROP != 0) return;
    // Already the frontmost of those on the display: nothing to move. A
    // window put away keeps its place in the list, so the one in front of
    // it is the front window as far as a click is concerned.
    var front = ib.NextWindow(null);
    while (front) |above| : (front = ib.NextWindow(above)) {
        if (windowAttr(ib, above, wn.WA_Hidden) == 0) break;
    }
    if (window == front) return;
    ib.WindowToFront(window);
}

/// One attribute of a window, as a number.
fn windowAttr(ib: *IntuitionBase, window: *intuition.Window, tag: sdk.utility.Tag) usize {
    var value: usize = 0;
    ib.GetWindowAttrs(window, &[_]TagItem{ .{ .tag = tag, .data = @intFromPtr(&value) }, .{} });
    return value;
}

/// A click counted: the second of a pair wakes the task. On
/// input.device's task, inside the network: it may not wait.
fn clicked(cb: *CxBase, cxm: *cx.CxMsg, _: *cx.CxObj) callconv(.c) void {
    const event = cb.CxMsgData(cxm) orelse return;
    const ib = clicks.ib orelse return;
    const seconds: u32 = @bitCast(event.time.secs);
    const micros: u32 = @bitCast(event.time.micro);
    const paired = clicks.seconds != 0 and ib.DoubleClick(clicks.seconds, clicks.micros, seconds, micros);
    if (paired) {
        // The pair is spent: the next click starts a new one, so three
        // clicks are one double click and a first.
        clicks.seconds = 0;
        const sys = clicks.sys orelse return;
        sys.Signal(clicks.task orelse return, clicks.mask);
        return;
    }
    clicks.seconds = seconds;
    clicks.micros = micros;
}

/// "rawmouse <qualifier> mouse_leftpress", the press this commodity
/// watches for.
fn joinDescription(into: *[128:0]u8, qualifier: [*:0]const u8) void {
    var at: usize = 0;
    for ([_][*:0]const u8{ "rawmouse ", qualifier, " mouse_leftpress" }) |part| {
        var i: usize = 0;
        while (part[i] != 0 and at + 1 < into.len) : (i += 1) {
            into[at] = part[i];
            at += 1;
        }
    }
    into[at] = 0;
}
