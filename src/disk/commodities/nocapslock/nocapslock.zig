// SPDX-License-Identifier: MIT
//! NoCapsLock: makes the Caps Lock key ineffective. Built against the SDK
//! only.
//!
//!   NoCapsLock CX_PRIORITY/K/N
//!
//! The key stays where it is and its light still comes on, but the
//! letters arrive small: every key that reaches the windows while Caps
//! Lock is on arrives as if it were off. Nothing else about the key
//! changes - a program that reads the qualifier itself sees it cleared,
//! and a hotkey that wants Caps Lock held is never met.
//!
//! It has no window. The controller (SYS:Commodities/Exchange) can make
//! it inactive, which leaves Caps Lock working again, and remove it;
//! Ctrl-C from the shell it was started in ends it too.
//!
//! CX_PRIORITY is its place among the commodities: a commodity of lower
//! priority sees the keys with Caps Lock already cleared, one of higher
//! priority sees them as they came.

const sdk = @import("sdk");
const dos = sdk.dos;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const frame = @import("commodity");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const CxBase = sdk.interface.commodities.CxBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "NoCapsLock";
const VERSION = "1.0";
const VERSION_STRING = "\x00$VER: " ++ COMMAND_NAME ++ " " ++ VERSION ++ " (02.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "CX_PRIORITY/K/N";
const arg_priority = 0;

const MSG_NOLIBRARY = "No %s\n";
const MSG_NOMEMORY = "No memory\n";
const MSG_DUPLICATE = "%s runs already\n";

/// Caps Lock on, whatever else is held.
const caps_held: cx.InputXpression = .{
    .class = ie.IECLASS_RAWKEY,
    .code = 0,
    .code_mask = 0,
    .qualifier = ie.IEQUALIFIER_CAPSLOCK,
    .qual_mask = ie.IEQUALIFIER_CAPSLOCK,
};

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

    const cx_lib = sys.OpenLibrary(cx.COMMODITIESNAME, cx.COMMODITIES_VERSION) orelse {
        _ = Printf(dl, MSG_NOLIBRARY, .{@as([*:0]const u8, cx.COMMODITIESNAME)});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(cx_lib);
    const cb: *CxBase = @ptrCast(cx_lib);

    const commodity = frame.Commodity.open(sys, cb, .{
        .name = COMMAND_NAME,
        .title = "NoCapsLock",
        .descr = "Caps Lock does nothing",
        .unique = cx.NBU_UNIQUE | cx.NBU_NOTIFY,
        .pri = priority,
    }) catch |err| {
        switch (err) {
            // The one running was told; it has no window to show.
            error.Duplicate => _ = Printf(dl, MSG_DUPLICATE, .{@as([*:0]const u8, COMMAND_NAME)}),
            error.NoMemory => _ = Printf(dl, MSG_NOMEMORY, .{}),
        }
        return if (err == error.Duplicate) dos.RETURN_WARN else dos.RETURN_FAIL;
    };
    defer commodity.close();

    // The keys with Caps Lock held, each handed to `clear`.
    const filter = cx.CxFilter(cb, null);
    cb.SetFilterIX(filter, &caps_held);
    cb.AttachCxObj(filter, cx.CxCustom(cb, &clear, 0));
    if (!commodity.attach(filter)) {
        _ = Printf(dl, MSG_NOMEMORY, .{});
        return dos.RETURN_FAIL;
    }
    commodity.activate(true);

    while (true) {
        const got = sys.Wait(commodity.signals());
        if (frame.Commodity.stopped(got)) break;
        while (commodity.next()) |event| switch (event) {
            .end => return dos.RETURN_OK,
            // No window, and the list is the controller's business.
            // Made inactive, the filter stops matching and the keys
            // arrive as they came: nothing to put back.
            .input, .disabled, .enabled, .show, .hide, .list_changed => {},
        };
    }
    return dos.RETURN_OK;
}

/// Caps Lock taken off a key on its way through the network. On
/// input.device's task, inside the network: it may not wait.
fn clear(cb: *CxBase, cxm: *cx.CxMsg, _: *cx.CxObj) callconv(.c) void {
    const event = cb.CxMsgData(cxm) orelse return;
    event.qualifier &= ~ie.IEQUALIFIER_CAPSLOCK;
}
