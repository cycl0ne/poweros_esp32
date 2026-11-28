// SPDX-License-Identifier: MIT
//! Host tests of hid.library: the jump table, the reports' layouts and
//! events (report/), and functions over a keyboard.device and a
//! mouse.device that keep what they are handed (source.zig) - a keyboard
//! and a mouse in one descriptor, each report to its source by its ID,
//! Caps Lock's light to the driver's hook; media keys, a remote's alone
//! and a keyboard's in a report beside its keys; a boot interface read by
//! its boot report where its descriptor does not describe it; a
//! descriptor of nothing the library drives; a receiver's three
//! interfaces as it describes them, its keys as it sends them; the
//! sources closed and nothing left.

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
const layout = @import("../report/layout.zig");
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

/// The 8BitDo Retro Mechanical Keyboard's receiver (2dc8:5201), its three
/// interfaces' report descriptors byte for byte. Interface 2, the
/// keyboard: six slots in report 1 with its LEDs, media keys in report 2,
/// system keys in report 6, a keyboard of bits in report 12 and another
/// in report 10, an eject key in report 17.
const retro_keyboard = [_]u8{
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01, 0x05, 0x07, 0x19, 0xE0,
    0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x05, 0x75, 0x01, 0x05, 0x08,
    0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x26, 0xF1, 0x00, 0x05, 0x07, 0x19,
    0x00, 0x2A, 0xF1, 0x00, 0x81, 0x00, 0xC0, 0x05, 0x0C, 0x09, 0x01, 0xA1,
    0x01, 0x85, 0x02, 0x75, 0x10, 0x95, 0x01, 0x15, 0x01, 0x26, 0x8C, 0x03,
    0x19, 0x01, 0x2A, 0x8C, 0x03, 0x81, 0x00, 0xC0, 0x05, 0x01, 0x09, 0x80,
    0xA1, 0x01, 0x85, 0x06, 0x09, 0x82, 0x09, 0x81, 0x09, 0x83, 0x15, 0x00,
    0x25, 0x01, 0x19, 0x01, 0x29, 0x03, 0x75, 0x01, 0x95, 0x03, 0x81, 0x02,
    0x95, 0x05, 0x81, 0x01, 0xC0, 0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85,
    0x0C, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75,
    0x01, 0x95, 0x08, 0x81, 0x02, 0x15, 0x00, 0x25, 0x01, 0x19, 0x00, 0x29,
    0x77, 0x75, 0x01, 0x95, 0x78, 0x81, 0x02, 0xC0, 0x05, 0x01, 0x09, 0x06,
    0xA1, 0x01, 0x85, 0x0A, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x15, 0x00, 0x25, 0x01,
    0x19, 0x00, 0x29, 0x77, 0x75, 0x01, 0x95, 0x78, 0x81, 0x02, 0xC0, 0x05,
    0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x11, 0x15, 0x00, 0x25, 0x01, 0x75,
    0x01, 0x95, 0x03, 0x81, 0x01, 0x75, 0x01, 0x95, 0x01, 0x05, 0x0C, 0x09,
    0xB8, 0x81, 0x02, 0x06, 0xFF, 0x00, 0x09, 0x03, 0x81, 0x02, 0x75, 0x01,
    0x95, 0x03, 0x81, 0x01, 0xC0,
};

/// Interface 0, its mouse: report 3, five buttons, a 16-bit X and Y, a
/// wheel and a horizontal one.
const retro_mouse = [_]u8{
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x03, 0x09, 0x01, 0xA1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01,
    0x95, 0x05, 0x81, 0x02, 0x75, 0x03, 0x95, 0x01, 0x81, 0x01, 0x05, 0x01,
    0x09, 0x30, 0x09, 0x31, 0x16, 0x01, 0x80, 0x26, 0xFF, 0x7F, 0x75, 0x10,
    0x95, 0x02, 0x81, 0x06, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08,
    0x95, 0x01, 0x81, 0x06, 0x05, 0x0C, 0x0A, 0x38, 0x02, 0x15, 0x81, 0x25,
    0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06, 0xC0, 0xC0,
};

/// Interface 1, the vendor's own: 32-byte reports of its page.
const retro_vendor = [_]u8{
    0x05, 0x8C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0xB1, 0x09, 0x02, 0x15, 0x00,
    0x26, 0xFF, 0x00, 0x75, 0x08, 0x95, 0x20, 0x81, 0x02, 0x85, 0xB2, 0x09,
    0x03, 0x95, 0x20, 0x75, 0x08, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x91, 0x02,
    0x85, 0x54, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x09, 0x07, 0x75, 0x08, 0x95,
    0x20, 0x81, 0x02, 0x85, 0x51, 0x09, 0x08, 0x95, 0x20, 0x75, 0x08, 0x15,
    0x00, 0x26, 0xFF, 0x00, 0x91, 0x02, 0x85, 0x52, 0x09, 0x09, 0x95, 0x20,
    0x75, 0x08, 0x15, 0x00, 0x26, 0xFF, 0x00, 0x91, 0x02, 0xC0,
};

test "the 8BitDo receiver: its keys in report 1, and as bits in reports 12 and 10, its media keys, its mouse; the vendor's interface refused" {
    var rig = try Rig.init();
    const keyboard = rig.hb.OpenHID(&retro_keyboard, retro_keyboard.len, null) orelse return error.NotOpened;
    try testing.expectEqual(hid.HIDF_KEYBOARD | hid.HIDF_CONSUMER, keyboard.flags);
    // a, b, c, space, Return, then the left Shift and a with it: each
    // report as the receiver sent it, nine bytes.
    const typed = [_][9]u8{
        .{ 0x01, 0x00, 0x00, 0x04, 0, 0, 0, 0, 0 }, .{ 0x01, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0 },
        .{ 0x01, 0x00, 0x00, 0x05, 0, 0, 0, 0, 0 }, .{ 0x01, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0 },
        .{ 0x01, 0x00, 0x00, 0x06, 0, 0, 0, 0, 0 }, .{ 0x01, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0 },
        .{ 0x01, 0x00, 0x00, 0x2C, 0, 0, 0, 0, 0 }, .{ 0x01, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0 },
        .{ 0x01, 0x00, 0x00, 0x28, 0, 0, 0, 0, 0 }, .{ 0x01, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0 },
        .{ 0x01, 0x02, 0x00, 0x00, 0, 0, 0, 0, 0 }, .{ 0x01, 0x02, 0x00, 0x04, 0, 0, 0, 0, 0 },
        .{ 0x01, 0x02, 0x00, 0x00, 0, 0, 0, 0, 0 }, .{ 0x01, 0x00, 0x00, 0x00, 0, 0, 0, 0, 0 },
    };
    const codes = [_]u32{
        0x20, 0x20 | ie.IECODE_UP_PREFIX, // a
        0x35, 0x35 | ie.IECODE_UP_PREFIX, // b
        0x33, 0x33 | ie.IECODE_UP_PREFIX, // c
        0x40, 0x40 | ie.IECODE_UP_PREFIX, // space
        0x44, 0x44 | ie.IECODE_UP_PREFIX, // Return
        0x60, 0x20, 0x20 | ie.IECODE_UP_PREFIX, 0x60 | ie.IECODE_UP_PREFIX, // the left Shift, a with it
    };
    var seen: usize = 0;
    for (typed) |report| {
        input(&rig, keyboard, &report);
        for (KeyboardSource.taken(rig.keyboard)) |event| {
            try testing.expect(seen < codes.len);
            try testing.expectEqual(ie.IECLASS_RAWKEY, event.class);
            try testing.expectEqual(codes[seen], event.code);
            seen += 1;
        }
    }
    try testing.expectEqual(codes.len, seen);
    // Volume up in report 2, a slot of 16 bits, and let go.
    input(&rig, keyboard, &.{ 0x02, 0xE9, 0x00 });
    var events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(kb.RAWKEY_VOLUMEUP, events[0].code);
    input(&rig, keyboard, &.{ 0x02, 0x00, 0x00 });
    events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(kb.RAWKEY_VOLUMEUP | ie.IECODE_UP_PREFIX, events[0].code);

    // What the receiver sends on a Raspberry Pi 4: every key as a bit, in
    // report 12 - the modifiers' byte, then usages 0 to 0x77. a (usage 4),
    // then the left Shift with it, then both let go; then b in report 10.
    const bits_typed = [_][17]u8{
        .{ 0x0C, 0x00, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0x0C, 0x02, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0x0C, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0x0A, 0x00, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0x0A, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
    };
    const bits_codes = [_]u32{
        0x20, // a
        0x60, // the left Shift
        0x20 | ie.IECODE_UP_PREFIX,
        0x60 | ie.IECODE_UP_PREFIX,
        0x35, 0x35 | ie.IECODE_UP_PREFIX, // b
    };
    seen = 0;
    for (bits_typed) |report| {
        input(&rig, keyboard, &report);
        for (KeyboardSource.taken(rig.keyboard)) |event| {
            try testing.expect(seen < bits_codes.len);
            try testing.expectEqual(ie.IECLASS_RAWKEY, event.class);
            try testing.expectEqual(bits_codes[seen], event.code);
            seen += 1;
        }
    }
    try testing.expectEqual(bits_codes.len, seen);
    rig.hb.CloseHID(keyboard);

    // The mouse: right by 5, up by 3, the left button down.
    const mouse = rig.hb.OpenHID(&retro_mouse, retro_mouse.len, null) orelse return error.NotOpened;
    try testing.expectEqual(hid.HIDF_MOUSE, mouse.flags);
    input(&rig, mouse, &.{ 0x03, 0x01, 0x05, 0x00, 0xFD, 0xFF, 0x00, 0x00 });
    events = MouseSource.taken(rig.mouse);
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expectEqual(@as(i32, 5), events[0].x);
    try testing.expectEqual(@as(i32, -3), events[0].y);
    try testing.expectEqual(ie.IECODE_LBUTTON, events[1].code);
    rig.hb.CloseHID(mouse);

    // The vendor's interface is nothing the library drives.
    try testing.expect(rig.hb.OpenHID(&retro_vendor, retro_vendor.len, null) == null);
    try rig.deinit();
}

/// Where the receiver's first keyboard collection, report 1's, ends: its
/// End Collection is the descriptor's 67th byte.
const report_1_end = 67;

test "the 8BitDo receiver's keyboards: reports 1, 12 and 10, in that order, report 1's with its slots and its LEDs; a collection given twice read once" {
    var found: [layout.KEYBOARDS_MOST]layout.KeyboardLayout = undefined;
    try testing.expectEqual(@as(usize, 3), layout.keyboardLayouts(&retro_keyboard, &found));
    try testing.expectEqual(@as(u8, 1), found[0].report_id);
    try testing.expectEqual(@as(u8, 6), found[0].slots.count);
    try testing.expect(found[0].leds);
    try testing.expectEqual(@as(u8, 12), found[1].report_id);
    try testing.expectEqual(@as(u8, 0), found[1].slots.size);
    try testing.expect(found[1].bits_count != 0);
    try testing.expectEqual(@as(u8, 10), found[2].report_id);
    try testing.expectEqual(@as(u8, 0xC0), retro_keyboard[report_1_end - 1]);
    const report_1_twice = retro_keyboard[0..report_1_end].* ++ retro_keyboard[0..report_1_end].*;
    try testing.expectEqual(@as(usize, 1), layout.keyboardLayouts(&report_1_twice, &found));
}

test "the 8BitDo receiver: a key held in report 12 down through reports 10 and 1, one held in two reports up once both let go, Caps Lock in report 12 lighting report 1's LEDs" {
    var rig = try Rig.init();
    var sent: Sent = .{};
    var hook = utility.Hook{ .entry = &Sent.hookEntry, .data = &sent };
    const tags = [_]utility.TagItem{
        .{ .tag = hid.HIDA_OutputHook, .data = @intFromPtr(&hook) },
        .{ .tag = utility.TAG_DONE, .data = 0 },
    };
    const keyboard = rig.hb.OpenHID(&retro_keyboard, retro_keyboard.len, &tags) orelse return error.NotOpened;
    // Reports 12 and 10: the modifiers, then a bit for each key from usage
    // 0 on - A's (4) in the third byte, Caps Lock's (0x39) in the tenth.
    const a_in_12 = [17]u8{ 0x0C, 0x00, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const a_in_10 = [17]u8{ 0x0A, 0x00, 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const caps_in_12 = [17]u8{ 0x0C, 0x00, 0, 0, 0, 0, 0, 0, 0, 0x02, 0, 0, 0, 0, 0, 0, 0 };
    const none_in_12 = [17]u8{ 0x0C, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const none_in_10 = [17]u8{ 0x0A, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const none_in_1 = [9]u8{ 0x01, 0, 0, 0, 0, 0, 0, 0, 0 };

    // A down in report 12; reports 10 and 1 holding nothing leave it down.
    input(&rig, keyboard, &a_in_12);
    var events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(@as(u32, 0x20), events[0].code);
    input(&rig, keyboard, &none_in_10);
    try testing.expectEqual(@as(usize, 0), KeyboardSource.taken(rig.keyboard).len);
    input(&rig, keyboard, &none_in_1);
    try testing.expectEqual(@as(usize, 0), KeyboardSource.taken(rig.keyboard).len);
    input(&rig, keyboard, &none_in_12);
    events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(@as(u32, 0x20) | ie.IECODE_UP_PREFIX, events[0].code);

    // A held in reports 12 and 10: down once, up once both let go.
    input(&rig, keyboard, &a_in_12);
    try testing.expectEqual(@as(usize, 1), KeyboardSource.taken(rig.keyboard).len);
    input(&rig, keyboard, &a_in_10);
    try testing.expectEqual(@as(usize, 0), KeyboardSource.taken(rig.keyboard).len);
    input(&rig, keyboard, &none_in_12);
    try testing.expectEqual(@as(usize, 0), KeyboardSource.taken(rig.keyboard).len);
    input(&rig, keyboard, &none_in_10);
    events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(@as(u32, 0x20) | ie.IECODE_UP_PREFIX, events[0].code);

    // Caps Lock in report 12: its light on, through report 1's LEDs.
    input(&rig, keyboard, &caps_in_12);
    events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(@as(u32, 0x62), events[0].code);
    try testing.expectEqual(@as(u32, 1), sent.calls);
    try testing.expectEqual(@as(u8, 1), sent.id);
    try testing.expectEqual(hid.HIDREPORT_OUTPUT, sent.kind);
    try testing.expectEqual(@as(u32, 1), sent.length);
    try testing.expectEqual(@as(u8, 0x02), sent.bytes[0]);
    // Let go: the light stays.
    input(&rig, keyboard, &none_in_12);
    events = KeyboardSource.taken(rig.keyboard);
    try testing.expectEqual(@as(usize, 1), events.len);
    try testing.expectEqual(@as(u32, 0x62) | ie.IECODE_UP_PREFIX, events[0].code);
    try testing.expectEqual(@as(u32, 1), sent.calls);
    rig.hb.CloseHID(keyboard);
    try rig.deinit();
}
