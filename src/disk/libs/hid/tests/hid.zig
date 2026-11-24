// SPDX-License-Identifier: MIT
//! Host tests of hid.library: the jump table, the reports' layouts and
//! events (report/), and functions over a keyboard.device and a
//! mouse.device that keep what they are handed (source.zig) - a keyboard
//! and a mouse in one descriptor, each report to its source by its ID,
//! Caps Lock's light to the driver's hook; media keys, a remote's alone
//! and a keyboard's in a report beside its keys; a boot interface read by
//! its boot report where its descriptor does not describe it; a
//! descriptor of nothing the library drives; the sources closed and
//! nothing left.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const hid = sdk.hid;
const utility = sdk.utility;
const ie = sdk.devices.inputevent;
const kb = sdk.devices.keyboard;
const mouse_device = sdk.devices.mouse;
const host = @import("host_rom");
const kexec = host.exec;
const utility_library = host.utility;
const hid_init = @import("../hid_init.zig");
const source = @import("source.zig");
const HIDLibrary = sdk.interface.hid.HIDBase;
const ExecBase = sdk.interface.exec.ExecBase;

const testing = std.testing;

test {
    _ = @import("../hid_lvo.zig");
    _ = @import("../report/report.zig");
}

const KeyboardSource = source.Source(kb.KEYBOARDNAME, kb.KBD_ADDEVENT);
const MouseSource = source.Source(mouse_device.MOUSENAME, mouse_device.MOUSE_ADDEVENT);

/// exec, utility.library, the two stand-in sources and hid.library, made
/// and opened.
const Rig = struct {
    kub: *utility_library.UtilityBase,
    sys: *ExecBase,
    library: *exec.Library,
    hb: *HIDLibrary,
    keyboard: *KeyboardSource.Device,
    mouse: *MouseSource.Device,

    fn init() !Rig {
        const kub = try utility_library.setUp();
        const sys = kexec.SysBase.iface();
        const keyboard = kexec.InitResident(kexec.SysBase, &KeyboardSource.tag, null) orelse return error.NoDevice;
        const pointer = kexec.InitResident(kexec.SysBase, &MouseSource.tag, null) orelse return error.NoDevice;
        const made = kexec.InitResident(kexec.SysBase, &hid_init.hid_library_tag, null) orelse return error.NoLibrary;
        const hb: *HIDLibrary = @ptrCast(sys.OpenLibrary(hid.HIDNAME, 1) orelse return error.NoBase);
        return .{
            .kub = kub,
            .sys = sys,
            .library = @ptrCast(@alignCast(made)),
            .hb = hb,
            .keyboard = KeyboardSource.of(keyboard),
            .mouse = MouseSource.of(pointer),
        };
    }

    /// The library closed and expunged, the stand-ins with it, and
    /// nothing left behind.
    fn deinit(rig: *Rig) !void {
        rig.sys.CloseLibrary(rig.hb.lib());
        _ = rig.sys.RemLibrary(rig.library);
        try testing.expect(kexec.FindName(kexec.SysBase, &kexec.SysBase.lib_list, hid.HIDNAME) == null);
        _ = rig.sys.RemDevice(&rig.keyboard.dev);
        _ = rig.sys.RemDevice(&rig.mouse.dev);
        try utility_library.tearDown(rig.kub);
        kexec.deinit();
    }
};

/// A keyboard, report 1 - the modifiers' bits, a reserved byte, six
/// slots, its LEDs an output report - and a mouse, report 2: three
/// buttons, X, Y and the wheel, each a signed byte. A receiver's, or a
/// keyboard with a touchpad.
const combined = [_]u8{
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01, // Generic Desktop, Keyboard, Application, ID 1
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, // the modifiers
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01, // a reserved byte
    0x95, 0x05, 0x75, 0x01, 0x05, 0x08, 0x19, 0x01, // five LEDs
    0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03,
    0x91, 0x01, // three bits of padding
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65, // six slots
    0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xC0,
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02, // Generic Desktop, Mouse, Application, ID 2
    0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, // Pointer, three buttons
    0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03,
    0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x05,
    0x81, 0x01, // padding
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x09, 0x38, // X, Y, the wheel, relative
    0x15, 0x81, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x03,
    0x81, 0x06, 0xC0, 0xC0,
};

/// What the output hook was called with, and how often.
const Sent = struct {
    calls: u32 = 0,
    id: u8 = 0,
    kind: u8 = 0,
    bytes: [8]u8 = @splat(0),
    length: u32 = 0,
    function: ?*anyopaque = null,

    fn hookEntry(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
        const sent: *Sent = @ptrCast(@alignCast(hook.data.?));
        const output: *const hid.HIDOutputMessage = @ptrCast(@alignCast(message.?));
        sent.calls += 1;
        sent.function = object;
        sent.id = output.id;
        sent.kind = output.kind;
        sent.length = output.length;
        @memcpy(sent.bytes[0..@min(output.length, sent.bytes.len)], output.data[0..@min(output.length, sent.bytes.len)]);
        return 0;
    }
};

fn input(rig: *Rig, function: *hid.HIDFunction, bytes: []const u8) void {
    rig.hb.HIDInput(function, bytes.ptr, @intCast(bytes.len));
}

test "a keyboard and a mouse in one descriptor: each report to its source by its ID, Caps Lock's light to the hook" {
    var rig = try Rig.init();
    var sent: Sent = .{};
    var hook = utility.Hook{ .entry = &Sent.hookEntry, .data = &sent };
    const tags = [_]utility.TagItem{
        .{ .tag = hid.HIDA_OutputHook, .data = @intFromPtr(&hook) },
        .{ .tag = utility.TAG_DONE, .data = 0 },
    };
    const function = rig.hb.OpenHID(&combined, combined.len, &tags) orelse return error.NotOpened;
    try testing.expectEqual(hid.HIDF_KEYBOARD | hid.HIDF_MOUSE, function.flags);
    try testing.expectEqual(@as(u32, 1), rig.keyboard.opens);
    try testing.expectEqual(@as(u32, 1), rig.mouse.opens);

    // A pressed: the keyboard's, and the mouse is told nothing.
    input(&rig, function, &.{ 0x01, 0x00, 0x00, 0x04, 0, 0, 0, 0, 0 });
    var events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(ie.IECLASS_RAWKEY, events[0].class);
    try testing.expectEqual(@as(u32, 0x20), events[0].code);
    try testing.expectEqual(@as(usize, 0), MouseSource.taken(rig.mouse).len);

    // A move with the left button down: the mouse's.
    input(&rig, function, &.{ 0x02, 0x01, 0x05, 0xFD, 0x00 });
    events = MouseSource.taken(rig.mouse);
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqual(@as(i32, 5), events[0].x);
    try testing.expectEqual(@as(i32, -3), events[0].y);
    try testing.expectEqual(ie.IECODE_LBUTTON, events[1].code);
    try testing.expectEqual(@as(usize, 0), KeyboardSource.taken(rig.keyboard).len);

    // A let go and Caps Lock pressed: its light on, report 1 to the hook.
    input(&rig, function, &.{ 0x01, 0x00, 0x00, 0x39, 0, 0, 0, 0, 0 });
    events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqual(@as(u32, 0x20) | ie.IECODE_UP_PREFIX, events[0].code);
    try testing.expectEqual(@as(u32, 0x62), events[1].code);
    try testing.expectEqual(@as(u32, 1), sent.calls);
    try testing.expectEqual(@as(?*anyopaque, function), sent.function);
    try testing.expectEqual(@as(u8, 1), sent.id);
    try testing.expectEqual(hid.HIDREPORT_OUTPUT, sent.kind);
    try testing.expectEqual(@as(u32, 1), sent.length);
    try testing.expectEqual(@as(u8, 0x02), sent.bytes[0]);

    // Held, and let go: the light stays. Pressed again: off.
    input(&rig, function, &.{ 0x01, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0 });
    input(&rig, function, &.{ 0x01, 0x00, 0x00, 0x39, 0, 0, 0, 0, 0 });
    try testing.expectEqual(@as(u32, 2), sent.calls);
    try testing.expectEqual(@as(u8, 0x00), sent.bytes[0]);
    _ = KeyboardSource.taken(rig.keyboard);

    // A report of an ID neither reads: nothing.
    input(&rig, function, &.{ 0x03, 0x01, 0x02, 0x03 });
    try testing.expectEqual(@as(usize, 0), KeyboardSource.taken(rig.keyboard).len);
    try testing.expectEqual(@as(usize, 0), MouseSource.taken(rig.mouse).len);

    rig.hb.CloseHID(function);
    try testing.expectEqual(@as(u32, 1), rig.keyboard.closes);
    try testing.expectEqual(@as(u32, 1), rig.mouse.closes);
    try rig.deinit();
}

/// A keyboard's media keys in report 3, beside its keys in report 1: a
/// consumer control of one slot of 16 bits, usages 0 to 0x3FF.
const keyboard_media = combined[0..65].* ++ [_]u8{
    0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x03, // Consumer, Consumer Control, Application, ID 3
    0x15, 0x00, 0x26, 0xFF, 0x03, 0x19, 0x00, 0x2A, // usages 0 to 0x3FF
    0xFF, 0x03, 0x75, 0x10, 0x95, 0x01, 0x81, 0x00, // one slot of 16 bits
    0xC0,
};

/// A remote control's media keys alone, as bits in report 2: next,
/// previous, stop, play/pause, mute, volume up, volume down, and the
/// calculator.
const remote = [_]u8{
    0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x02, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x08, 0x09, 0xB5, 0x09, 0xB6, 0x09, 0xB7, 0x09, 0xCD,
    0x09, 0xE2, 0x09, 0xE9, 0x09, 0xEA, 0x0A, 0x92, 0x01, 0x81, 0x02, 0xC0,
};

test "media keys: a remote's alone, and a keyboard's beside its keys, each report read by its own layout" {
    var rig = try Rig.init();
    // The remote: a source of keyboard.device, nothing of mouse.device.
    const function = rig.hb.OpenHID(&remote, remote.len, null) orelse return error.NotOpened;
    try testing.expectEqual(hid.HIDF_CONSUMER, function.flags);
    try testing.expectEqual(@as(u32, 1), rig.keyboard.opens);
    try testing.expectEqual(@as(u32, 0), rig.mouse.opens);
    // Media keys alone are no keyboard.
    try testing.expectEqual(kb.KBDF_SOURCE | kb.KBDF_MEDIA, rig.keyboard.flags);
    // Play/pause pressed, then volume up with it, then both let go.
    input(&rig, function, &.{ 0x02, 0x08 });
    var events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(kb.RAWKEY_MEDIA_PLAYPAUSE, events[0].code);
    input(&rig, function, &.{ 0x02, 0x28 });
    events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(kb.RAWKEY_VOLUMEUP, events[0].code);
    input(&rig, function, &.{ 0x02, 0x00 });
    events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqual(kb.RAWKEY_MEDIA_PLAYPAUSE | ie.IECODE_UP_PREFIX, events[0].code);
    try testing.expectEqual(kb.RAWKEY_VOLUMEUP | ie.IECODE_UP_PREFIX, events[1].code);
    // The calculator is no key.
    input(&rig, function, &.{ 0x02, 0x80 });
    try testing.expectEqual(@as(usize, 0), KeyboardSource.taken(rig.keyboard).len);
    rig.hb.CloseHID(function);

    // The keyboard: its keys and its media keys, one source.
    const both = rig.hb.OpenHID(&keyboard_media, keyboard_media.len, null) orelse return error.NotOpened;
    try testing.expectEqual(hid.HIDF_KEYBOARD | hid.HIDF_CONSUMER, both.flags);
    try testing.expectEqual(@as(u32, 2), rig.keyboard.opens);
    try testing.expectEqual(kb.KBDF_SOURCE, rig.keyboard.flags);
    // A held, then next pressed: the media report does not let A go.
    input(&rig, both, &.{ 0x01, 0x00, 0x00, 0x04, 0, 0, 0, 0, 0 });
    events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(@as(u32, 0x20), events[0].code);
    input(&rig, both, &.{ 0x03, 0xB5, 0x00 });
    events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(kb.RAWKEY_MEDIA_NEXT, events[0].code);
    // Next let go, and the keyboard's report does not touch it.
    input(&rig, both, &.{ 0x03, 0x00, 0x00 });
    events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(kb.RAWKEY_MEDIA_NEXT | ie.IECODE_UP_PREFIX, events[0].code);
    input(&rig, both, &.{ 0x01, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0 });
    events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(@as(u32, 0x20) | ie.IECODE_UP_PREFIX, events[0].code);
    rig.hb.CloseHID(both);
    try testing.expectEqual(@as(u32, 2), rig.keyboard.closes);
    try rig.deinit();
}

/// A mouse alone, without IDs: the boot mouse's report described.
const mouse_only = [_]u8{
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x09, 0x01,
    0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, 0x29, 0x03,
    0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01,
    0x81, 0x02, 0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x81,
    0x25, 0x7F, 0x75, 0x08, 0x95, 0x02, 0x81, 0x06,
    0xC0, 0xC0,
};

test "a boot keyboard whose descriptor describes no keyboard: its boot report alone, on the port it names" {
    var rig = try Rig.init();
    const port = rig.sys.CreateMsgPort() orelse return error.NoPort;
    const tags = [_]utility.TagItem{
        .{ .tag = hid.HIDA_Boot, .data = hid.HIDBOOT_KEYBOARD },
        .{ .tag = hid.HIDA_ReplyPort, .data = @intFromPtr(port) },
        .{ .tag = utility.TAG_DONE, .data = 0 },
    };
    const function = rig.hb.OpenHID(&mouse_only, mouse_only.len, &tags) orelse return error.NotOpened;
    try testing.expectEqual(hid.HIDF_KEYBOARD | hid.HIDF_BOOT, function.flags);
    try testing.expectEqual(@as(u32, 1), rig.keyboard.opens);
    try testing.expectEqual(@as(u32, 0), rig.mouse.opens);

    // The boot report: no ID, the modifiers, a reserved byte, six slots.
    input(&rig, function, &.{ 0x02, 0x00, 0x04, 0, 0, 0, 0, 0 });
    const events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqual(@as(u32, 0x20), events[0].code);
    try testing.expectEqual(@as(u32, 0x60), events[1].code); // the left Shift

    // Caps Lock without a hook: nothing sent, nothing broken.
    input(&rig, function, &.{ 0x00, 0x00, 0x39, 0, 0, 0, 0, 0 });
    _ = KeyboardSource.taken(rig.keyboard);

    rig.hb.CloseHID(function);
    rig.sys.DeleteMsgPort(port);
    try rig.deinit();
}

test "a boot mouse whose descriptor describes it is read by its descriptor; one of nothing it drives is refused" {
    var rig = try Rig.init();
    const boot_mouse = [_]utility.TagItem{
        .{ .tag = hid.HIDA_Boot, .data = hid.HIDBOOT_MOUSE },
        .{ .tag = utility.TAG_DONE, .data = 0 },
    };
    const function = rig.hb.OpenHID(&mouse_only, mouse_only.len, &boot_mouse) orelse return error.NotOpened;
    try testing.expectEqual(hid.HIDF_MOUSE, function.flags);
    input(&rig, function, &.{ 0x02, 0x00, 0x07 });
    const events = MouseSource.taken(rig.mouse);
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqual(@as(i32, 7), events[0].y);
    try testing.expectEqual(ie.IECODE_RBUTTON, events[1].code);
    rig.hb.CloseHID(function);

    // A gamepad: Generic Desktop, Game Pad - nothing the library drives.
    const gamepad = [_]u8{ 0x05, 0x01, 0x09, 0x05, 0xA1, 0x01, 0x05, 0x09, 0x19, 0x01, 0x29, 0x08, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0xC0 };
    try testing.expect(rig.hb.OpenHID(&gamepad, gamepad.len, null) == null);
    try testing.expect(rig.hb.OpenHID(null, 0, null) == null);
    try testing.expectEqual(@as(u32, 1), rig.mouse.opens);
    try testing.expectEqual(@as(u32, 0), rig.keyboard.opens);
    rig.hb.CloseHID(null);
    try rig.deinit();
}
