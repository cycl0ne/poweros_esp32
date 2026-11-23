// SPDX-License-Identifier: MIT
//! BTGatt: the attributes of an LE device's GATT server read, written and
//! watched - the GATT calls of bluetooth.library at work, and a test of
//! them. Built against the SDK only.
//!
//!   BTGatt DEVICE/A [READ/K] [WRITE/K] [DATA/K] [TEXT/K] [NORESPONSE/S]
//!          [WATCH/K] [INDICATE/S] [RANDOM/S] [CONTROLLER/K/N]
//!
//!   DEVICE             the device: its address - public, or with RANDOM
//!                      its random one - or the name a scan heard
//!   READ <handle>      the attribute's value read and shown, in
//!                      hexadecimal and as text
//!   WRITE <handle> DATA <hex> | TEXT <text> [NORESPONSE]
//!                      the attribute's value written: the bytes DATA
//!                      gives in hexadecimal (0100, or 01:00), or TEXT's
//!                      characters; with NORESPONSE as a Write Command,
//!                      which the device does not answer
//!   WATCH <handle> [INDICATE]
//!                      the characteristic whose value has that handle
//!                      subscribed to, notified - or with INDICATE
//!                      indicated - and each value shown as it comes,
//!                      until CTRL-C, or the link ends
//!   CONTROLLER <n>     the controller to link over; without it, the one
//!                      with a link to the device, else the one that
//!                      found it, else the first that is on
//!
//! A handle is written in hexadecimal - 2A, 002A, 0x002A or $2A - as
//! `Bluetooth SERVICES <device> INFO` shows the values' handles.
//!
//! The block, its link and its values are bluetooth.library's
//! (OpenBTGatt, ReadBTAttribute, WriteBTAttribute, SubscribeBTAttribute,
//! ObtainBTServices, ObtainBTCharacteristics), the values messages on one
//! port.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bluetooth = sdk.bluetooth;
const att = bluetooth.att;
const hci = bluetooth.hci;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const BluetoothBase = sdk.interface.bluetooth.BluetoothBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "BTGatt";
const VERSION_STRING = "\x00$VER: BTGatt 1.0 (23.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DEVICE/A,READ/K,WRITE/K,DATA/K,TEXT/K,NORESPONSE/S,WATCH/K,INDICATE/S,RANDOM/S,CONTROLLER/K/N";
const arg_device = 0;
const arg_read = 1;
const arg_write = 2;
const arg_data = 3;
const arg_text = 4;
const arg_noresponse = 5;
const arg_watch = 6;
const arg_indicate = 7;
const arg_random = 8;
const arg_controller = 9;
const arg_count = 10;

/// What the program keeps: a value read or written at its longest.
const State = struct {
    value: [att.ATT_VALUE_MOST]u8 = undefined,
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

    const actions = @as(u32, @intFromBool(argv[arg_read] != 0)) + @intFromBool(argv[arg_write] != 0) + @intFromBool(argv[arg_watch] != 0);
    if (actions != 1) {
        _ = Printf(dl, "%s: one of READ, WRITE or WATCH, with a handle (Bluetooth SERVICES <device> INFO shows them)\n", .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_ERROR;
    }
    const handle_text: [*:0]const u8 = @ptrFromInt(argv[arg_read] | argv[arg_write] | argv[arg_watch]);
    const handle = parseHandle(handle_text) orelse {
        _ = Printf(dl, "%s: %s is not a handle (002A)\n", .{ @as([*:0]const u8, COMMAND_NAME), handle_text });
        return dos.RETURN_ERROR;
    };

    const bt_lib = sys.OpenLibrary(bluetooth.BLUETOOTHNAME, 1) orelse {
        _ = Printf(dl, "no %s\n", .{@as([*:0]const u8, bluetooth.BLUETOOTHNAME)});
        return dos.RETURN_FAIL;
    };
    defer sys.CloseLibrary(bt_lib);
    const bt: *BluetoothBase = @ptrCast(bt_lib);

    const controller: u32 = if (dos.rdargs.number(argv[arg_controller])) |value| @bitCast(value) else bluetooth.BT_ALL_CONTROLLERS;
    const device_text: [*:0]const u8 = @ptrFromInt(argv[arg_device]);
    const address = deviceOf(bt, controller, device_text, argv[arg_random] != 0) orelse {
        _ = Printf(dl, "%s: no device %s (an address, or a name a scan heard)\n", .{ @as([*:0]const u8, COMMAND_NAME), device_text });
        return dos.RETURN_ERROR;
    };

    const memory = sys.AllocVec(@sizeOf(State), 0) orelse {
        _ = dl.PutStr("no memory\n");
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    const state: *State = @ptrCast(@alignCast(memory));
    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);

    var shown: [18]u8 = undefined;
    _ = Printf(dl, "Opening GATT to %s\n", .{addressText(&address.bytes, &shown)});
    var gatt: ?*bluetooth.BTGatt = null;
    const opened = bt.OpenBTGatt(controller, &address, port, &gatt);
    if (opened != 0) {
        _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), failure(opened) });
        return dos.RETURN_ERROR;
    }
    // Closed before its port goes.
    defer bt.CloseBTGatt(gatt);
    const block = gatt.?;
    _ = Printf(dl, "Open, PDUs of up to %u bytes\n", .{@as(u32, block.mtu)});
    if (argv[arg_read] != 0) return read(dl, bt, block, handle, state);
    if (argv[arg_write] != 0) return write(dl, bt, block, handle, state, &argv);
    return watch(sys, dl, bt, block, handle, argv[arg_indicate] != 0, port);
}

/// READ: the value read and shown.
fn read(dl: *DosBase, bt: *BluetoothBase, block: *bluetooth.BTGatt, handle: u16, state: *State) i32 {
    var length: u32 = 0;
    const result = bt.ReadBTAttribute(block, handle, &state.value, state.value.len, &length);
    if (result != 0) {
        _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), failure(result) });
        return dos.RETURN_ERROR;
    }
    _ = Printf(dl, "%04lx: %u bytes\n", .{ @as(u64, handle), length });
    dump(dl, state.value[0..length]);
    return dos.RETURN_OK;
}

/// WRITE: DATA's bytes or TEXT's characters written.
fn write(dl: *DosBase, bt: *BluetoothBase, block: *bluetooth.BTGatt, handle: u16, state: *State, argv: *const [arg_count]usize) i32 {
    var length: usize = 0;
    if (argv[arg_data] != 0) {
        const text: [*:0]const u8 = @ptrFromInt(argv[arg_data]);
        length = parseBytes(text, &state.value) orelse {
            _ = Printf(dl, "%s: %s is not bytes in hexadecimal (0100, or 01:00), %u at most\n", .{ @as([*:0]const u8, COMMAND_NAME), text, @as(u32, att.ATT_VALUE_MOST) });
            return dos.RETURN_ERROR;
        };
    } else if (argv[arg_text] != 0) {
        const text: [*:0]const u8 = @ptrFromInt(argv[arg_text]);
        while (text[length] != 0) : (length += 1) {
            if (length == state.value.len) {
                _ = Printf(dl, "%s: a value is %u bytes at most\n", .{ @as([*:0]const u8, COMMAND_NAME), @as(u32, att.ATT_VALUE_MOST) });
                return dos.RETURN_ERROR;
            }
            state.value[length] = text[length];
        }
    } else {
        _ = Printf(dl, "%s: WRITE needs DATA or TEXT\n", .{@as([*:0]const u8, COMMAND_NAME)});
        return dos.RETURN_ERROR;
    }
    const no_response = argv[arg_noresponse] != 0;
    const flags: u32 = if (no_response) bluetooth.BTGW_NORESPONSE else 0;
    const result = bt.WriteBTAttribute(block, handle, &state.value, @intCast(length), flags);
    if (result != 0) {
        _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), failure(result) });
        return dos.RETURN_ERROR;
    }
    const how: [*:0]const u8 = if (no_response) "sent" else "written";
    _ = Printf(dl, "%04lx: %u bytes %s\n", .{ @as(u64, handle), @as(u32, @intCast(length)), how });
    return dos.RETURN_OK;
}

/// WATCH: the characteristic whose value is `handle` found among the
/// device's, subscribed to, and each value shown as it comes.
fn watch(sys: *ExecBase, dl: *DosBase, bt: *BluetoothBase, block: *bluetooth.BTGatt, handle: u16, indicate: bool, port: *exec.MsgPort) i32 {
    var which: bluetooth.BTCharacteristic = .{};
    const found = characteristicOf(bt, block, handle, &which);
    if (found != 0) {
        _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), failure(found) });
        return dos.RETURN_ERROR;
    }
    if (which.value_handle == 0) {
        _ = Printf(dl, "%s: no characteristic's value has the handle %04lx\n", .{ @as([*:0]const u8, COMMAND_NAME), @as(u64, handle) });
        return dos.RETURN_ERROR;
    }
    const subscribed = bt.SubscribeBTAttribute(block, &which, if (indicate) bluetooth.BTGS_INDICATE else 0);
    if (subscribed != 0) {
        if (subscribed == bluetooth.BTERR_UNSUPPORTED) {
            const how: [*:0]const u8 = if (indicate) "indicated" else "notified";
            _ = Printf(dl, "%s: that value is not %s\n", .{ @as([*:0]const u8, COMMAND_NAME), how });
        } else {
            _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), failure(subscribed) });
        }
        return dos.RETURN_ERROR;
    }
    const how: [*:0]const u8 = if (indicate) "indicated" else "notified";
    _ = Printf(dl, "Watching %04lx, %s; CTRL-C stops\n", .{ @as(u64, handle), how });
    const mask = (@as(u32, 1) << @intCast(port.sig_bit)) | exec.SIGBREAKF_CTRL_C;
    while (true) {
        const got = sys.Wait(mask);
        while (sys.GetMsg(port)) |message| {
            const told: *bluetooth.BTGattMessage = @fieldParentPtr("message", message);
            const kind = told.kind;
            const result = told.result;
            if (kind == bluetooth.BTGM_VALUE) {
                _ = Printf(dl, "%04lx:", .{@as(u64, told.handle)});
                line(dl, if (told.data) |data| data[0..told.length] else &.{});
            }
            sys.ReplyMsg(message);
            if (kind == bluetooth.BTGM_CLOSED) {
                _ = Printf(dl, "The link ended (%s)\n", .{failure(result)});
                return dos.RETURN_OK;
            }
        }
        if (got & exec.SIGBREAKF_CTRL_C != 0) {
            _ = bt.UnsubscribeBTAttribute(block, &which);
            if (block.dropped != 0) _ = Printf(dl, "%u values let go, more coming than were shown\n", .{block.dropped});
            _ = dl.PutStr("***Break\n");
            return dos.RETURN_WARN;
        }
    }
}

/// The characteristic whose value is `handle`, copied to `which` - its
/// value's handle 0 where there is none; 0, or why the device could not
/// be asked.
fn characteristicOf(bt: *BluetoothBase, block: *bluetooth.BTGatt, handle: u16, which: *bluetooth.BTCharacteristic) i32 {
    var services: ?*exec.List = null;
    const asked = bt.ObtainBTServices(block.controller, &block.address, &services);
    if (asked != 0) return asked;
    defer bt.ReleaseBTServices(services);
    var it = services.?.iterator();
    while (it.next()) |node| {
        const service: *bluetooth.BTService = @fieldParentPtr("node", node);
        if (handle < service.handle or handle > service.end_handle) continue;
        var characteristics: ?*exec.List = null;
        const listed = bt.ObtainBTCharacteristics(block, service, &characteristics);
        if (listed != 0) return listed;
        defer bt.ReleaseBTCharacteristics(characteristics);
        var each = characteristics.?.iterator();
        while (each.next()) |one| {
            const characteristic: *bluetooth.BTCharacteristic = @fieldParentPtr("node", one);
            if (characteristic.value_handle != handle) continue;
            which.* = characteristic.*;
            // Its descriptors go with the list.
            which.node = .{};
            which.descriptors = null;
            which.descriptor_count = 0;
            return 0;
        }
    }
    return 0;
}

/// A value shown in rows of 16 bytes: where in it, its bytes in
/// hexadecimal, its characters - what is not printable as dots.
fn dump(dl: *DosBase, value: []const u8) void {
    var at: usize = 0;
    while (at < value.len) : (at += 16) {
        const row = value[at..@min(at + 16, value.len)];
        _ = Printf(dl, "  %04lx ", .{@as(u64, at)});
        for (row) |byte| _ = Printf(dl, " %02lx", .{@as(u64, byte)});
        for (row.len..16) |_| _ = dl.PutStr("   ");
        var text: [17]u8 = undefined;
        for (row, text[0..row.len]) |byte, *shown| shown.* = if (byte >= 0x20 and byte < 0x7F) byte else '.';
        text[row.len] = 0;
        _ = Printf(dl, "  %s\n", .{@as([*:0]const u8, @ptrCast(&text))});
    }
}

/// A value on the rest of a line: its first 24 bytes in hexadecimal, then
/// as text; how long it is where it is longer.
fn line(dl: *DosBase, value: []const u8) void {
    const shown_most = 24;
    const row = value[0..@min(value.len, shown_most)];
    for (row) |byte| _ = Printf(dl, " %02lx", .{@as(u64, byte)});
    var text: [shown_most + 1]u8 = undefined;
    for (row, text[0..row.len]) |byte, *shown| shown.* = if (byte >= 0x20 and byte < 0x7F) byte else '.';
    text[row.len] = 0;
    _ = Printf(dl, "  %s", .{@as([*:0]const u8, @ptrCast(&text))});
    if (value.len > row.len) _ = Printf(dl, " (%u bytes)", .{@as(u32, @intCast(value.len))});
    _ = dl.PutStr("\n");
}

fn failure(result: i32) [*:0]const u8 {
    if (result <= bluetooth.BTERR_ATT and result > bluetooth.BTERR_ATT - 0x100) {
        return attReason(@intCast(bluetooth.BTERR_ATT - result));
    }
    return switch (result) {
        bluetooth.BTERR_NOMEM => "no memory, or no room for another block or call",
        bluetooth.BTERR_NOCONTROLLER => "no Bluetooth controller",
        bluetooth.BTERR_NOTUP => "the controller is not up",
        bluetooth.BTERR_OFF => "the controller is off (Bluetooth POWER ON)",
        bluetooth.BTERR_UNSUPPORTED => "the controller cannot link over LE",
        bluetooth.BTERR_BUSY => "the controller is making another link",
        bluetooth.BTERR_TIMEOUT => "the device did not answer in time",
        bluetooth.BTERR_PROTOCOL => "the device's answer made no sense",
        bluetooth.BTERR_NOTCONNECTED => "the block is closed",
        bluetooth.BTERR_TOOLONG => "longer than the link's PDUs carry",
        bluetooth.BTERR_DETACHED => "the controller has gone",
        hci.HCI_ERR_CONNECTION_TIMEOUT => "the link was lost",
        hci.HCI_ERR_REMOTE_USER_TERMINATED => "the device ended the link",
        hci.HCI_ERR_LOCAL_HOST_TERMINATED => "this machine ended the link",
        hci.HCI_ERR_FAILED_TO_ESTABLISH => "the device did not answer on the new link",
        else => if (result > 0) "the link could not be made, or was lost" else "it failed",
    };
}

/// What the device's reason for a refusal means.
fn attReason(code: u8) [*:0]const u8 {
    return switch (code) {
        att.ATT_ERR_INVALID_HANDLE => "the device has no such handle",
        att.ATT_ERR_READ_NOT_PERMITTED => "that value may not be read",
        att.ATT_ERR_WRITE_NOT_PERMITTED => "that value may not be written",
        att.ATT_ERR_INVALID_PDU => "the device did not understand the request",
        att.ATT_ERR_INSUFFICIENT_AUTHENTICATION => "the link must be authenticated first (Bluetooth PAIR)",
        att.ATT_ERR_REQUEST_NOT_SUPPORTED => "the device does not take such a request",
        att.ATT_ERR_INVALID_OFFSET => "past the value's end",
        att.ATT_ERR_INSUFFICIENT_AUTHORIZATION => "the device's user has not allowed it",
        att.ATT_ERR_ATTRIBUTE_NOT_FOUND => "no such attribute",
        att.ATT_ERR_ATTRIBUTE_NOT_LONG => "that value is not read in parts",
        att.ATT_ERR_ENCRYPTION_KEY_SIZE => "the link's encryption key is too short",
        att.ATT_ERR_INVALID_VALUE_LENGTH => "the device takes no value of that length",
        att.ATT_ERR_INSUFFICIENT_ENCRYPTION => "the link must be encrypted first (Bluetooth PAIR)",
        att.ATT_ERR_INSUFFICIENT_RESOURCES => "the device has no room for it",
        att.ATT_ERR_DATABASE_OUT_OF_SYNC => "the device's attributes have changed: ask again",
        att.ATT_ERR_VALUE_NOT_ALLOWED => "the device does not take that value",
        0xFD => "the device's configuration of it is not well made",
        0xFE => "the device is busy with it",
        0xFF => "the value is out of the device's range",
        else => "the device refused it",
    };
}

/// A handle in hexadecimal - 2A, 002A, 0x002A or $2A - from 1 to FFFF;
/// null for anything else.
fn parseHandle(text: [*:0]const u8) ?u16 {
    var at: usize = 0;
    if (text[0] == '$') {
        at = 1;
    } else if (text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        at = 2;
    }
    var value: u32 = 0;
    var digits: usize = 0;
    while (text[at] != 0) : (at += 1) {
        value = value << 4 | (hexDigit(text[at]) orelse return null);
        digits += 1;
        if (digits > 4) return null;
    }
    if (digits == 0 or value == 0) return null;
    return @intCast(value);
}

/// Bytes in hexadecimal into `into` - two digits each, a colon or a space
/// between them where it is wanted; how many, or null for anything else.
fn parseBytes(text: [*:0]const u8, into: []u8) ?usize {
    var at: usize = 0;
    var count: usize = 0;
    while (text[at] != 0) {
        if (text[at] == ':' or text[at] == ' ') {
            at += 1;
            continue;
        }
        const high = hexDigit(text[at]) orelse return null;
        const low = hexDigit(text[at + 1]) orelse return null;
        if (count == into.len) return null;
        into[count] = @intCast(high << 4 | low);
        count += 1;
        at += 2;
    }
    return count;
}

fn hexDigit(char: u8) ?u32 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => null,
    };
}

/// The device DEVICE names: an address - public, or random with RANDOM -
/// or the name a scan heard, as it was heard over LE; null for neither.
fn deviceOf(bt: *BluetoothBase, controller: u32, text: [*:0]const u8, random: bool) ?bluetooth.BTAddress {
    if (parseAddress(text)) |bytes| {
        return .{ .bytes = bytes, .kind = if (random) bluetooth.BTADDR_LE_RANDOM else bluetooth.BTADDR_LE_PUBLIC };
    }
    const devices = bt.ObtainBTDevices(controller) orelse return null;
    defer bt.ReleaseBTDevices(devices);
    var it = devices.iterator();
    while (it.next()) |node| {
        const found: *bluetooth.BTDevice = @fieldParentPtr("node", node);
        const name = found.node.name orelse continue;
        if (!sameName(name, text)) continue;
        if (found.address.kind != bluetooth.BTADDR_BREDR) return found.address;
        // Heard over BR/EDR too: its LE address is the same one.
        if (found.flags & bluetooth.BTDF_LE != 0) return .{ .bytes = found.address.bytes, .kind = bluetooth.BTADDR_LE_PUBLIC };
    }
    return null;
}

/// Whether two names are the same, letters' case aside.
fn sameName(one: [*:0]const u8, other: [*:0]const u8) bool {
    var at: usize = 0;
    while (true) : (at += 1) {
        const mine = lower(one[at]);
        if (mine != lower(other[at])) return false;
        if (mine == 0) return true;
    }
}

fn lower(char: u8) u8 {
    return if (char >= 'A' and char <= 'Z') char + ('a' - 'A') else char;
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
fn parseAddress(text: [*:0]const u8) ?[6]u8 {
    var bytes: [6]u8 = undefined;
    var at: usize = 0;
    for (0..6) |index| {
        var octet: u8 = 0;
        for (0..2) |_| {
            octet = octet << 4 | @as(u8, @intCast(hexDigit(text[at]) orelse return null));
            at += 1;
        }
        bytes[5 - index] = octet;
        if (index < 5) {
            if (text[at] != ':') return null;
            at += 1;
        }
    }
    return if (text[at] == 0) bytes else null;
}
