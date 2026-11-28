// SPDX-License-Identifier: MIT
//! HIDInput: one of a device's input reports made into events for its
//! sources.

const sdk = @import("sdk");
const exec = sdk.exec;
const hid = sdk.hid;
const ie = sdk.devices.inputevent;
const kb = sdk.devices.keyboard;
const mouse_device = sdk.devices.mouse;
const HIDBase = @import("../hid_base.zig").HIDBase;
const report_file = @import("../report/report.zig");
const _function = @import("_function.zig");
const Function = _function.Function;

/// Hands one of a device's input reports to its function: its keys,
/// media keys, moves, buttons and wheel go to keyboard.device and
/// mouse.device as events.
///
/// SYNOPSIS:
/// ```zig
/// fn HIDInput(base: *HIDBase, function: *hid.HIDFunction, report: [*]const u8,
///     length: u32) void
/// ```
///
/// SINCE: 1.0. LVO -28.
///
/// INPUTS:
/// - `function` - OpenHID's.
/// - `report`, `length` - the report as the device's descriptor lays it
///   out: its ID first where the descriptor gives its reports IDs - a
///   transport that carries the ID beside the report puts it back in
///   front - or the boot protocol's report for a function with HIDF_BOOT.
///
/// RESULT:
/// None.
///
/// BEHAVIOR:
/// A report one of the keyboard's layouts reads becomes the key-ups and
/// then the key-downs from the keys its reports held to the keys they
/// hold with this one, each a RAWKEY event; a report of too many keys at once changes
/// nothing. When Caps Lock goes down, the keyboard's Caps Lock light
/// changes: its LEDs' output report goes to HIDA_OutputHook. A report the
/// consumer control's layout reads becomes the media keys that went up
/// and then down since its last report, each a RAWKEY event. A report the
/// mouse's layout reads becomes a move - or a tablet's place - each
/// button that changed, and the wheel's notches. The events go to their
/// source in one request. A report of an ID none reads is let go.
///
/// CONTEXT:
/// - Waits: yes, while a source takes the events, and in the hook.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do: the one the function's reply port belongs
///   to.
///
/// OWNERSHIP:
/// The report stays the caller's: nothing of it is kept.
///
/// NOTES:
/// The hook is called on this task, within the call, with an
/// HIDOutputMessage that is the library's until it returns.
///
/// BUGS:
/// Only Caps Lock's light is kept; Num Lock's and Scroll Lock's stay dark.
///
/// SEE ALSO:
/// `OpenHID`, `CloseHID`
///
/// EXAMPLES:
/// ```zig
/// // A report that came on the device's interrupt endpoint.
/// hb.HIDInput(function, &buffer, actual);
/// ```
pub fn HIDInput(base: *HIDBase, function: *hid.HIDFunction, report: [*]const u8, length: u32) void {
    const record = _function.functionOf(function);
    const bytes = report[0..length];
    if (function.flags & hid.HIDF_KEYBOARD != 0) keys(base, record, bytes);
    if (function.flags & hid.HIDF_CONSUMER != 0) media(base, record, bytes);
    if (function.flags & (hid.HIDF_MOUSE | hid.HIDF_TABLET) != 0) moves(base, record, bytes);
}

/// A consumer control's report: the media keys that changed to
/// keyboard.device.
fn media(base: *HIDBase, record: *Function, bytes: []const u8) void {
    const held = report_file.consumerKeysOf(&record.consumer, bytes) orelse return;
    const count = report_file.keyEvents(record.media, held, &record.events);
    record.media = held;
    hand(base, &record.keyboard_source, kb.KBD_ADDEVENT, record.events[0..count]);
}

/// A keyboard's report: the keys that changed to keyboard.device, and the
/// light when Caps Lock went down.
fn keys(base: *HIDBase, record: *Function, bytes: []const u8) void {
    // The keyboard report this is, of those its collections send: what it
    // holds now, and what all of them hold together.
    const layouts = 1 + @as(usize, record.more_count);
    const which = for (0..layouts) |i| {
        const one = if (i == 0) &record.keyboard else &record.more_keyboards[i - 1];
        if (one.owns(bytes)) break i;
    } else return;
    const one = if (which == 0) &record.keyboard else &record.more_keyboards[which - 1];
    record.held[which] = report_file.keysOf(one, bytes) orelse return;
    var held: report_file.KeySet = .{};
    for (record.held[0..layouts]) |set| {
        for (&held.bits, set.bits) |*bits, more| bits.* |= more;
    }
    const count = report_file.keyEvents(record.keys, held, &record.events);
    const caps_down = held.has(report_file.RAWKEY_CAPSLOCK) and !record.keys.has(report_file.RAWKEY_CAPSLOCK);
    record.keys = held;
    hand(base, &record.keyboard_source, kb.KBD_ADDEVENT, record.events[0..count]);
    if (caps_down) lights(base, record, record.leds ^ 0x02);
}

/// A mouse's report: its move, its buttons and its wheel to mouse.device.
fn moves(base: *HIDBase, record: *Function, bytes: []const u8) void {
    const count = report_file.mouseEvents(&record.mouse, record.buttons, bytes, &record.events);
    if (record.mouse.owns(bytes)) record.buttons = report_file.buttonsOf(&record.mouse, bytes);
    hand(base, &record.mouse_source, mouse_device.MOUSE_ADDEVENT, record.events[0..count]);
}

/// Events to a source, in one request; none sends nothing.
fn hand(base: *HIDBase, source: *exec.IOStdReq, command: u16, events: []ie.InputEvent) void {
    if (events.len == 0 or source.req.device == null) return;
    source.req.command = command;
    source.data = events.ptr;
    source.length = @intCast(events.len * @sizeOf(ie.InputEvent));
    _ = base.sys_base.DoIO(&source.req);
}

/// The keyboard's LEDs: its LEDs' output report, a byte, to the driver's
/// hook with the report's ID. None for a keyboard without LEDs, or a
/// driver without a hook.
fn lights(base: *HIDBase, record: *Function, leds: u8) void {
    record.leds = leds;
    if (!record.keyboard.leds) return;
    const hook = record.output orelse return;
    var message = hid.HIDOutputMessage{
        .data = @ptrCast(&record.leds),
        .length = 1,
        .id = record.keyboard.led_report_id,
        .kind = hid.HIDREPORT_OUTPUT,
    };
    _ = base.utility.CallHookPkt(hook, &record.public, &message);
}
