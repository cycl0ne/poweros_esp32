// SPDX-License-Identifier: MIT
//! NumericPad: a numeric keypad on a keyboard that has none. Built
//! against the SDK only.
//!
//!   NumericPad CX_PRIORITY/K/N
//!
//! While Caps Lock is on, the block of keys on the right of the keyboard
//! is the keypad, laid out as one:
//!
//!     8 9 0 -   the ( ) / * of the pad
//!     I O P [   7 8 9 -
//!     K L ; '   4 5 6 +
//!     , . /     1 2 3
//!     space     0, and Return the pad's Enter
//!
//! Each arrives as the keypad key it stands for, qualifier and all, so a
//! program that tells the keypad from the main keys sees the keypad.
//!
//! The keys of that block that are not part of the pad do nothing while
//! Caps Lock is on: with it on the keyboard is a keypad, not a keyboard
//! in capitals. The keys that type nothing - Backspace, Tab, Escape,
//! Delete, the cursor and function keys, Insert, Page Up, Page Down, Home
//! and End - are left alone and work as they always do, and so does
//! Caps Lock itself, which turns the pad off again.
//!
//! It has no window. The controller (SYS:Commodities/Exchange) can make
//! it inactive and remove it; Ctrl-C from the shell it was started in
//! ends it too. CX_PRIORITY is its place among the commodities.
//!
//! It is meant for the small USB keyboards that have no keypad of their
//! own. A keyboard that has one is unaffected: its keys are already the
//! keypad's and pass through as they are.

const sdk = @import("sdk");
const dos = sdk.dos;
const cx = sdk.commodities;
const ie = sdk.devices.inputevent;
const kbd = sdk.devices.keyboard;
const frame = @import("commodity");
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const CxBase = sdk.interface.commodities.CxBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "NumericPad";
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

/// The highest rawkey that types a character of its own: the block the
/// pad is laid over. A key above it is left alone.
const typing_keys = 0x40;

/// The key on the left becomes the keypad key on the right. Each pair is
/// where the two sit on the keyboard, not what is printed on them.
const laid_over = [_][2]u8{
    .{ 0x08, 0x5A }, // 8 -> (
    .{ 0x09, 0x5B }, // 9 -> )
    .{ 0x0A, 0x5C }, // 0 -> /
    .{ 0x0B, 0x5D }, // - -> *
    .{ 0x17, 0x3D }, // I -> 7
    .{ 0x18, 0x3E }, // O -> 8
    .{ 0x19, 0x3F }, // P -> 9
    .{ 0x1A, 0x4A }, // [ -> -
    .{ 0x27, 0x2D }, // K -> 4
    .{ 0x28, 0x2E }, // L -> 5
    .{ 0x29, 0x2F }, // ; -> 6
    .{ 0x2A, 0x5E }, // ' -> +
    .{ 0x38, 0x1D }, // , -> 1
    .{ 0x39, 0x1E }, // . -> 2
    .{ 0x3A, 0x1F }, // / -> 3
    .{ 0x40, 0x0F }, // the space bar -> 0
};

/// The pad's own keys inside the block, which stand for themselves on a
/// keyboard that has a keypad.
const already_pad = [_]u8{ 0x0F, 0x1D, 0x1E, 0x1F, 0x2D, 0x2E, 0x2F, 0x3C, 0x3D, 0x3E, 0x3F };

/// What each key of the block becomes, or `nothing` for one the pad has
/// no place for.
const nothing = 0xFF;
const pad: [typing_keys + 1]u8 = blk: {
    var made: [typing_keys + 1]u8 = @splat(nothing);
    for (already_pad) |code| made[code] = code;
    for (laid_over) |pair| made[pair[0]] = pair[1];
    break :blk made;
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
        .title = "NumericPad",
        .descr = "Caps Lock makes a keypad",
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

    const filter = cx.CxFilter(cb, null);
    cb.SetFilterIX(filter, &caps_held);
    cb.AttachCxObj(filter, cx.CxCustom(cb, &onto_pad, 0));
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
            // Made inactive, the filter stops matching and the keys
            // arrive as they came: nothing to put back.
            .input, .disabled, .enabled, .show, .hide, .list_changed => {},
        };
    }
    return dos.RETURN_OK;
}

/// A key held with Caps Lock turned into the keypad key it stands for, or
/// taken out of the stream when the pad has no place for it. On
/// input.device's task, inside the network: it may not wait.
fn onto_pad(cb: *CxBase, cxm: *cx.CxMsg, _: *cx.CxObj) callconv(.c) void {
    const event = cb.CxMsgData(cxm) orelse return;
    // Caps Lock is the pad's switch and not a qualifier while it is on.
    event.qualifier &= ~ie.IEQUALIFIER_CAPSLOCK;
    const up = event.code & ie.IECODE_UP_PREFIX;
    const code = event.code & ~@as(u32, ie.IECODE_UP_PREFIX);
    if (code == kbd.RAWKEY_RETURN) {
        event.code = kbd.RAWKEY_KP_ENTER | up;
        event.qualifier |= ie.IEQUALIFIER_NUMERICPAD;
        return;
    }
    // A key that types nothing of its own is left as it came.
    if (code > typing_keys) return;
    const became = pad[code];
    if (became == nothing) {
        // No place on the pad: the key does nothing at all, both strokes
        // of it, so that the pad is a pad and not capitals.
        cb.DisposeCxMsg(cxm);
        return;
    }
    event.code = @as(u32, became) | up;
    event.qualifier |= ie.IEQUALIFIER_NUMERICPAD;
}
