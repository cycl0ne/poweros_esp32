// SPDX-License-Identifier: MIT
//! BTHidDevice: this machine as a Bluetooth keyboard and mouse over
//! BR/EDR - the other side of bthid.device, and a test of it. Built
//! against the SDK only.
//!
//!   BTHidDevice [TO/K] [CONTROLLER/K/N]
//!
//!   BTHidDevice        a HID service with a keyboard and a mouse in one
//!                      report descriptor served (AddBTService), and the
//!                      host's channels to PSMs 17 and 19 taken - only
//!                      over a bonded host's link encrypted with its
//!                      bond's key (BTLSF_SECURE); until CTRL-C
//!   TO <address>       the channels opened to that host instead, control
//!                      first, as a keyboard reconnects; until CTRL-C, or
//!                      the host closes them
//!   CONTROLLER <n>     the controller to open them over
//!
//! Each line typed is sent as key presses, a key down and up a character,
//! as a US keyboard has them - its end of line is not; `MOVE <x> <y>`
//! moves the pointer, `CLICK` presses and lets go of the first button,
//! `CAPS` presses Caps Lock. The LEDs the host sends back are shown, and
//! so is its VIRTUAL_CABLE_UNPLUG, which closes the channels.
//!
//! A machine is a HID host or a HID device on PSMs 17 and 19, not both:
//! the listeners are the machine's. Pair the host with this machine first
//! - `Bluetooth AGENT` here answers its pairing.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bluetooth = sdk.bluetooth;
const hidp = bluetooth.hidp;
const sdp = bluetooth.sdp;
const l2cap = bluetooth.l2cap;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const BluetoothBase = sdk.interface.bluetooth.BluetoothBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "BTHidDevice";
const VERSION_STRING = "\x00$VER: BTHidDevice 1.0 (23.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "TO/K,CONTROLLER/K/N";
const arg_to = 0;
const arg_controller = 1;
const arg_count = 2;

/// How often what is typed is looked for, in microseconds.
const typed_us = 100_000;

// --- the record -------------------------------------------------------------------

fn uint8(comptime value: u8) [2]u8 {
    return .{ sdp.DE_UINT << 3, value };
}
fn uint16(comptime value: u16) [3]u8 {
    return .{ sdp.DE_UINT << 3 | 1, value >> 8, value & 0xFF };
}
fn uuid16(comptime value: u16) [3]u8 {
    return .{ sdp.DE_UUID << 3 | 1, value >> 8, value & 0xFF };
}
fn boolean(comptime value: bool) [2]u8 {
    return .{ sdp.DE_BOOL << 3, @intFromBool(value) };
}
fn text(comptime bytes: []const u8) [headerSize(bytes.len) + bytes.len]u8 {
    return header(sdp.DE_TEXT, bytes.len) ++ bytes[0..bytes.len].*;
}
fn sequence(comptime items: []const u8) [headerSize(items.len) + items.len]u8 {
    return header(sdp.DE_SEQUENCE, items.len) ++ items[0..items.len].*;
}
/// A text's or a sequence's descriptor, with its length in 1 byte or 2.
fn headerSize(comptime length: usize) usize {
    return if (length > 0xFF) 3 else 2;
}
fn header(comptime kind: u8, comptime length: usize) [headerSize(length)]u8 {
    if (length > 0xFF) return .{ kind << 3 | sdp.DE_SIZE_LENGTH16, length >> 8, length & 0xFF };
    return .{ kind << 3 | sdp.DE_SIZE_LENGTH8, length };
}
fn attribute(comptime id: u16, comptime value: []const u8) [3 + value.len]u8 {
    return uint16(id) ++ value[0..value.len].*;
}

/// A keyboard - report 1: its modifiers, a byte kept, six keys; its five
/// LEDs back - and a mouse - report 2: three buttons, X, Y and the wheel.
const report_descriptor = keyboard_report ++ mouse_report;
const keyboard_report = [_]u8{
    0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x85, 0x01,
    0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x05,
    0x75, 0x01, 0x05, 0x08, 0x19, 0x01, 0x29, 0x05,
    0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01,
    0x95, 0x06, 0x75, 0x08, 0x15, 0x00, 0x25, 0x65,
    0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00,
    0xC0,
};
const mouse_report = [_]u8{
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x02,
    0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01,
    0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03,
    0x75, 0x01, 0x81, 0x02, 0x95, 0x01, 0x75, 0x05,
    0x81, 0x01, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31,
    0x09, 0x38, 0x15, 0x81, 0x25, 0x7F, 0x75, 0x08,
    0x95, 0x03, 0x81, 0x06, 0xC0, 0xC0,
};
const KEYBOARD_REPORT: u8 = 1;
const MOUSE_REPORT: u8 = 2;

/// The service's attributes, the handle the library's to give.
const record = sequence(&(attribute(sdp.ATTR_SERVICE_CLASS_ID_LIST, &sequence(&uuid16(hidp.UUID_HID))) ++
    attribute(sdp.ATTR_PROTOCOL_DESCRIPTOR_LIST, &sequence(&(sequence(&(uuid16(sdp.UUID_L2CAP) ++ uint16(l2cap.PSM_HID_CONTROL))) ++ sequence(&uuid16(hidp.UUID_HIDP))))) ++
    attribute(sdp.ATTR_BROWSE_GROUP_LIST, &sequence(&uuid16(sdp.UUID_PUBLIC_BROWSE_ROOT))) ++
    attribute(sdp.ATTR_LANGUAGE_BASE_LIST, &sequence(&(uint16(0x656E) ++ uint16(0x006A) ++ uint16(0x0100)))) ++
    attribute(sdp.ATTR_PROFILE_DESCRIPTOR_LIST, &sequence(&sequence(&(uuid16(hidp.UUID_HID) ++ uint16(0x0101))))) ++
    attribute(sdp.ATTR_ADDITIONAL_PROTOCOL_DESCRIPTOR_LISTS, &sequence(&sequence(&(sequence(&(uuid16(sdp.UUID_L2CAP) ++ uint16(l2cap.PSM_HID_INTERRUPT))) ++ sequence(&uuid16(hidp.UUID_HIDP)))))) ++
    attribute(sdp.ATTR_SERVICE_NAME, &text("PowerOS keyboard and mouse")) ++
    attribute(hidp.ATTR_HID_PARSER_VERSION, &uint16(0x0111)) ++
    attribute(hidp.ATTR_HID_DEVICE_SUBCLASS, &uint8(hidp.HID_SUBCLASS_COMBO)) ++
    attribute(hidp.ATTR_HID_COUNTRY_CODE, &uint8(0)) ++
    attribute(hidp.ATTR_HID_VIRTUAL_CABLE, &boolean(true)) ++
    attribute(hidp.ATTR_HID_RECONNECT_INITIATE, &boolean(true)) ++
    attribute(hidp.ATTR_HID_DESCRIPTOR_LIST, &sequence(&sequence(&(uint8(hidp.HID_DESCRIPTOR_REPORT) ++ text(&report_descriptor))))) ++
    attribute(hidp.ATTR_HID_LANGID_BASE_LIST, &sequence(&sequence(&(uint16(0x0409) ++ uint16(0x0100))))) ++
    attribute(hidp.ATTR_HID_PROFILE_VERSION, &uint16(0x0101)) ++
    attribute(hidp.ATTR_HID_SUPERVISION_TIMEOUT, &uint16(0x0C80)) ++
    attribute(hidp.ATTR_HID_NORMALLY_CONNECTABLE, &boolean(false)) ++
    attribute(hidp.ATTR_HID_BOOT_DEVICE, &boolean(false))));

// --- the program ------------------------------------------------------------------

/// The two channels to the host, while they are open.
const Channels = struct {
    control: ?*bluetooth.BTChannel = null,
    interrupt: ?*bluetooth.BTChannel = null,
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [arg_count]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);

    const bt_lib = sys.OpenLibrary(bluetooth.BLUETOOTHNAME, 1) orelse {
        _ = Printf(dl, "no %s\n", .{@as([*:0]const u8, bluetooth.BLUETOOTHNAME)});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(bt_lib);
    const bt: *BluetoothBase = @ptrCast(bt_lib);
    const controller: u32 = if (dos.rdargs.number(argv[arg_controller])) |value| @bitCast(value) else bluetooth.BT_ALL_CONTROLLERS;

    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    const service = bt.AddBTService(&record, record.len) orelse {
        _ = Printf(dl, "%s: the HID service could not be added\n", .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_FAIL;
    };
    defer bt.RemBTService(service);

    var channels: Channels = .{};
    defer {
        close(bt, &channels.interrupt);
        close(bt, &channels.control);
    }
    if (argv[arg_to] != 0) {
        const text_address: [*:0]const u8 = @ptrFromInt(argv[arg_to]);
        const bytes = parseAddress(text_address) orelse {
            _ = Printf(dl, "%s: %s is not an address (00:00:5E:EF:10:01)\n", .{ @as([*:0]const u8, COMMAND_NAME), text_address });
            return dos.RETURN_ERROR;
        };
        const host = bluetooth.BTAddress{ .bytes = bytes };
        if (!reconnect(dl, bt, controller, host, port, &channels)) return dos.RETURN_ERROR;
        return run(sys, dl, bt, port, &channels, false);
    }
    const control_listener = bt.AddBTListener(l2cap.PSM_HID_CONTROL, port, bluetooth.BTLSF_SECURE);
    const interrupt_listener = bt.AddBTListener(l2cap.PSM_HID_INTERRUPT, port, bluetooth.BTLSF_SECURE);
    defer {
        bt.RemBTListener(interrupt_listener);
        bt.RemBTListener(control_listener);
        // What the listeners left on the port.
        while (sys.GetMsg(port)) |message| {
            const told: *bluetooth.BTChannelMessage = @fieldParentPtr("message", message);
            const opened = if (told.kind == bluetooth.BTCM_OPENED) told.channel else null;
            sys.ReplyMsg(message);
            bt.CloseBTChannel(opened);
        }
    }
    if (control_listener == null or interrupt_listener == null) {
        _ = Printf(dl, "%s: PSMs 17 and 19 are served already - this machine drives Bluetooth keyboards itself (bthid.device)\n", .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_ERROR;
    }
    _ = dl.PutStr("A keyboard and a mouse, waiting for a bonded host's channels; CTRL-C stops\n");
    return run(sys, dl, bt, port, &channels, true);
}

/// The host's channels opened from here, control first.
fn reconnect(dl: *DosBase, bt: *BluetoothBase, controller: u32, host: bluetooth.BTAddress, port: *exec.MsgPort, channels: *Channels) bool {
    var shown: [18]u8 = undefined;
    _ = Printf(dl, "Opening the channels to %s\n", .{addressText(&host.bytes, &shown)});
    const control = bt.OpenBTChannel(controller, &host, l2cap.PSM_HID_CONTROL, port, &channels.control);
    if (control != 0) {
        _ = Printf(dl, "%s: the control channel: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), failure(control) });
        return false;
    }
    const interrupt = bt.OpenBTChannel(controller, &host, l2cap.PSM_HID_INTERRUPT, port, &channels.interrupt);
    if (interrupt != 0) {
        _ = Printf(dl, "%s: the interrupt channel: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), failure(interrupt) });
        return false;
    }
    _ = dl.PutStr("Connected; each line typed is sent, CTRL-C stops\n");
    return true;
}

/// The channels' messages and what is typed, until CTRL-C - or, where the
/// channels were opened from here, until the host closes them.
fn run(sys: *ExecBase, dl: *DosBase, bt: *BluetoothBase, port: *exec.MsgPort, channels: *Channels, listening: bool) i32 {
    const input = dl.Input();
    var line: [256]u8 = undefined;
    while (true) {
        while (sys.GetMsg(port)) |message| {
            const told: *bluetooth.BTChannelMessage = @fieldParentPtr("message", message);
            const kind = told.kind;
            const channel = told.channel;
            if (kind == bluetooth.BTCM_DATA) {
                if (told.data) |data| {
                    if (heard(dl, bt, channels, channel.?, data[0..told.length])) {
                        sys.ReplyMsg(message);
                        _ = dl.PutStr("The host unplugged: its channels closed\n");
                        close(bt, &channels.interrupt);
                        close(bt, &channels.control);
                        if (!listening) return dos.RETURN_OK;
                        continue;
                    }
                }
            }
            if (kind == bluetooth.BTCM_OPENED) take(dl, bt, channels, channel.?);
            sys.ReplyMsg(message);
            if (kind == bluetooth.BTCM_CLOSED) {
                if (channels.control == channel) channels.control = null;
                if (channels.interrupt == channel) {
                    channels.interrupt = null;
                    _ = dl.PutStr("The host closed the channels\n");
                }
                bt.CloseBTChannel(channel);
                if (!listening and channels.control == null and channels.interrupt == null) return dos.RETURN_OK;
            }
        }
        if (sys.SetSignal(0, exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0) {
            _ = dl.PutStr("***Break\n");
            return dos.RETURN_WARN;
        }
        if (!dl.WaitForChar(input, typed_us)) continue;
        const got = dl.Read(input, &line, line.len);
        if (got <= 0) return dos.RETURN_OK;
        var length: usize = @intCast(got);
        while (length > 0 and (line[length - 1] == '\n' or line[length - 1] == '\r')) length -= 1;
        typed(dl, bt, channels, line[0..length]);
    }
}

/// A host's channel to a listener: kept, in place of one it had.
fn take(dl: *DosBase, bt: *BluetoothBase, channels: *Channels, channel: *bluetooth.BTChannel) void {
    var shown: [18]u8 = undefined;
    const slot = switch (channel.psm) {
        l2cap.PSM_HID_CONTROL => &channels.control,
        l2cap.PSM_HID_INTERRUPT => &channels.interrupt,
        else => return bt.CloseBTChannel(channel),
    };
    close(bt, slot);
    slot.* = channel;
    if (channel.psm == l2cap.PSM_HID_INTERRUPT) _ = Printf(dl, "%s connected; each line typed is sent\n", .{addressText(&channel.address.bytes, &shown)});
}

/// A frame of the host's: its LEDs shown, a request answered; true for
/// its VIRTUAL_CABLE_UNPLUG.
fn heard(dl: *DosBase, bt: *BluetoothBase, channels: *Channels, channel: *bluetooth.BTChannel, data: []const u8) bool {
    if (data.len == 0) return false;
    const kind = data[0] & hidp.HIDP_TYPE_MASK;
    const parameter = data[0] & hidp.HIDP_PARAM_MASK;
    switch (kind) {
        hidp.HIDP_DATA => if (parameter == hidp.HIDP_REPORT_OUTPUT) leds(dl, data[1..]),
        hidp.HIDP_SET_REPORT => {
            if (parameter == hidp.HIDP_REPORT_OUTPUT) leds(dl, data[1..]);
            handshake(bt, channels, hidp.HIDP_HSHK_SUCCESSFUL);
        },
        hidp.HIDP_SET_PROTOCOL => handshake(bt, channels, hidp.HIDP_HSHK_SUCCESSFUL),
        hidp.HIDP_GET_PROTOCOL => {
            const answer = [_]u8{ hidp.HIDP_DATA | hidp.HIDP_REPORT_OTHER, hidp.HIDP_PROTOCOL_REPORT };
            if (channels.control) |control| _ = bt.SendBTChannel(control, &answer, answer.len);
        },
        hidp.HIDP_GET_REPORT => handshake(bt, channels, hidp.HIDP_HSHK_ERR_UNSUPPORTED_REQUEST),
        hidp.HIDP_CONTROL => return parameter == hidp.HIDP_CTRL_VIRTUAL_CABLE_UNPLUG,
        else => if (channel == channels.control) handshake(bt, channels, hidp.HIDP_HSHK_ERR_UNSUPPORTED_REQUEST),
    }
    return false;
}

fn handshake(bt: *BluetoothBase, channels: *Channels, result: u8) void {
    const control = channels.control orelse return;
    const answer = [_]u8{hidp.HIDP_HANDSHAKE | result};
    _ = bt.SendBTChannel(control, &answer, answer.len);
}

/// The keyboard's output report: its ID, then its LEDs.
fn leds(dl: *DosBase, report: []const u8) void {
    if (report.len < 2 or report[0] != KEYBOARD_REPORT) return;
    const bits = report[1];
    _ = Printf(dl, "LEDs: Num Lock %s, Caps Lock %s, Scroll Lock %s\n", .{ onOff(bits & 1), onOff(bits & 2), onOff(bits & 4) });
}

fn onOff(bit: u8) [*:0]const u8 {
    return if (bit != 0) "on" else "off";
}

/// A line typed: MOVE, CLICK, CAPS, or keys.
fn typed(dl: *DosBase, bt: *BluetoothBase, channels: *Channels, line: []const u8) void {
    const channel = channels.interrupt orelse {
        _ = dl.PutStr("Not connected: nothing sent\n");
        return;
    };
    if (startsWith(line, "MOVE ")) {
        var rest = line[5..];
        const x = number(&rest) orelse return usage(dl);
        const y = number(&rest) orelse return usage(dl);
        return mouse(bt, channel, 0, x, y);
    }
    if (same(line, "CLICK")) {
        mouse(bt, channel, 1, 0, 0);
        return mouse(bt, channel, 0, 0, 0);
    }
    if (same(line, "CAPS")) return key(bt, channel, 0, 0x39);
    for (line) |char| {
        const usage_code = usageOf(char) orelse continue;
        key(bt, channel, usage_code.modifiers, usage_code.usage);
    }
}

fn usage(dl: *DosBase) void {
    _ = dl.PutStr("MOVE <x> <y>, from -127 to 127\n");
}

/// A key pressed and let go of.
fn key(bt: *BluetoothBase, channel: *bluetooth.BTChannel, modifiers: u8, usage_code: u8) void {
    const down = [_]u8{ hidp.HIDP_DATA | hidp.HIDP_REPORT_INPUT, KEYBOARD_REPORT, modifiers, 0, usage_code, 0, 0, 0, 0, 0 };
    const up = [_]u8{ hidp.HIDP_DATA | hidp.HIDP_REPORT_INPUT, KEYBOARD_REPORT, 0, 0, 0, 0, 0, 0, 0, 0 };
    _ = bt.SendBTChannel(channel, &down, down.len);
    _ = bt.SendBTChannel(channel, &up, up.len);
}

fn mouse(bt: *BluetoothBase, channel: *bluetooth.BTChannel, buttons: u8, x: i8, y: i8) void {
    const report = [_]u8{ hidp.HIDP_DATA | hidp.HIDP_REPORT_INPUT, MOUSE_REPORT, buttons, @bitCast(x), @bitCast(y), 0 };
    _ = bt.SendBTChannel(channel, &report, report.len);
}

const Usage = struct { modifiers: u8, usage: u8 };
const LEFT_SHIFT: u8 = 0x02;

/// A character's key on a US keyboard.
fn usageOf(char: u8) ?Usage {
    return switch (char) {
        'a'...'z' => .{ .modifiers = 0, .usage = 0x04 + (char - 'a') },
        'A'...'Z' => .{ .modifiers = LEFT_SHIFT, .usage = 0x04 + (char - 'A') },
        '1'...'9' => .{ .modifiers = 0, .usage = 0x1E + (char - '1') },
        '0' => .{ .modifiers = 0, .usage = 0x27 },
        ' ' => .{ .modifiers = 0, .usage = 0x2C },
        '-' => .{ .modifiers = 0, .usage = 0x2D },
        '=' => .{ .modifiers = 0, .usage = 0x2E },
        ';' => .{ .modifiers = 0, .usage = 0x33 },
        ',' => .{ .modifiers = 0, .usage = 0x36 },
        '.' => .{ .modifiers = 0, .usage = 0x37 },
        '/' => .{ .modifiers = 0, .usage = 0x38 },
        else => null,
    };
}

/// A signed number at the start of `rest`, from -127 to 127, past the
/// spaces before it; `rest` moved past it.
fn number(rest: *[]const u8) ?i8 {
    var at: usize = 0;
    while (at < rest.len and rest.*[at] == ' ') at += 1;
    var negative = false;
    if (at < rest.len and rest.*[at] == '-') {
        negative = true;
        at += 1;
    }
    var value: i32 = 0;
    var digits: usize = 0;
    while (at < rest.len and rest.*[at] >= '0' and rest.*[at] <= '9') : (at += 1) {
        value = value * 10 + (rest.*[at] - '0');
        digits += 1;
        if (value > 127) return null;
    }
    if (digits == 0) return null;
    rest.* = rest.*[at..];
    return @intCast(if (negative) -value else value);
}

fn startsWith(line: []const u8, prefix: []const u8) bool {
    return line.len >= prefix.len and same(line[0..prefix.len], prefix);
}

fn same(one: []const u8, other: []const u8) bool {
    if (one.len != other.len) return false;
    for (one, other) |mine, theirs| {
        if (mine != theirs) return false;
    }
    return true;
}

fn close(bt: *BluetoothBase, slot: *?*bluetooth.BTChannel) void {
    const channel = slot.* orelse return;
    slot.* = null;
    bt.CloseBTChannel(channel);
}

fn failure(result: i32) [*:0]const u8 {
    return switch (result) {
        bluetooth.BTERR_NOMEM => "no memory, or no room for another channel",
        bluetooth.BTERR_NOCONTROLLER => "no Bluetooth controller",
        bluetooth.BTERR_NOTUP => "the controller is not up",
        bluetooth.BTERR_OFF => "the controller is off (Bluetooth POWER ON)",
        bluetooth.BTERR_REFUSED => "the host refused the channel - is it bonded with this machine?",
        bluetooth.BTERR_UNSUPPORTED => "the host takes no HID channels",
        bluetooth.BTERR_BUSY => "the host has no room for another channel",
        bluetooth.BTERR_TIMEOUT => "the host did not answer in time",
        bluetooth.BTERR_PROTOCOL => "the host's answer made no sense",
        bluetooth.BTERR_DETACHED => "the controller has gone",
        else => if (result > 0) "the link could not be made, or was lost" else "it failed",
    };
}

/// An address as it is written, the most significant byte first.
fn addressText(address: *const [6]u8, into: *[18]u8) [*:0]const u8 {
    const hex = "0123456789ABCDEF";
    for (0..6) |index| {
        const octet = address[5 - index];
        into[index * 3] = hex[octet >> 4];
        into[index * 3 + 1] = hex[octet & 0xF];
        into[index * 3 + 2] = if (index == 5) 0 else ':';
    }
    return @ptrCast(into);
}

/// An address written as six pairs of hexadecimal digits with colons,
/// the most significant first; null for anything else.
fn parseAddress(text_address: [*:0]const u8) ?[6]u8 {
    var bytes: [6]u8 = undefined;
    var at: usize = 0;
    for (0..6) |index| {
        var octet: u8 = 0;
        for (0..2) |_| {
            const char = text_address[at];
            const digit: u8 = switch (char) {
                '0'...'9' => char - '0',
                'a'...'f' => char - 'a' + 10,
                'A'...'F' => char - 'A' + 10,
                else => return null,
            };
            octet = octet << 4 | digit;
            at += 1;
        }
        bytes[5 - index] = octet;
        if (index < 5) {
            if (text_address[at] != ':') return null;
            at += 1;
        }
    }
    return if (text_address[at] == 0) bytes else null;
}
