// SPDX-License-Identifier: MIT
//! BTEcho: L2CAP channels to and from the devices around - the channel
//! calls of bluetooth.library at work, and a test of them. Built against
//! the SDK only.
//!
//!   BTEcho [PSM/K/N] [TO/K] [CONTROLLER/K/N]
//!
//!   BTEcho [PSM <n>]   the PSM served - 8193 (0x2001) where none is
//!                      given: each channel a device opens to it is taken,
//!                      said as it opens and closes, and every frame on it
//!                      sent back as it came; until CTRL-C
//!   TO <address> [PSM <n>]
//!                      a channel opened to the device's PSM: each line
//!                      typed sent as a frame, without its end of line,
//!                      and each frame that comes shown; until CTRL-C, or
//!                      the device closes it
//!   CONTROLLER <n>     the controller to open it over; without it, the
//!                      one with a link to the device, else the one that
//!                      found it, else the first that is on
//!
//! The default PSM is past 0x10FF: a Linux machine hands the PSMs from
//! 0x1001 to 0x10FF to its own services as they start, and a channel to
//! one of those waits for its user to allow it.
//!
//! The channels are bluetooth.library's (OpenBTChannel, AddBTListener,
//! SendBTChannel, CloseBTChannel), their frames messages on one port.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bluetooth = sdk.bluetooth;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const BluetoothBase = sdk.interface.bluetooth.BluetoothBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "BTEcho";
const VERSION_STRING = "\x00$VER: BTEcho 1.0 (23.11.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "PSM/K/N,TO/K,CONTROLLER/K/N";
const arg_psm = 0;
const arg_to = 1;
const arg_controller = 2;
const arg_count = 3;

/// The PSM served, or opened to, where none is given.
const default_psm: u32 = 0x2001;
/// How many channels a listener keeps open at once.
const channels_most = 8;
/// How often what is typed is looked for, in microseconds.
const typed_us = 100_000;

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

    const psm: u32 = if (dos.rdargs.number(argv[arg_psm])) |value| @bitCast(value) else default_psm;
    const controller: u32 = if (dos.rdargs.number(argv[arg_controller])) |value| @bitCast(value) else bluetooth.BT_ALL_CONTROLLERS;
    const port = sys.CreateMsgPort() orelse return dos.RETURN_FAIL;
    defer sys.DeleteMsgPort(port);
    if (argv[arg_to] != 0) return talk(sys, dl, bt, controller, @ptrFromInt(argv[arg_to]), psm, port);
    return serve(sys, dl, bt, psm, port);
}

/// The channels devices open to `psm` taken, and their frames sent back.
fn serve(sys: *ExecBase, dl: *DosBase, bt: *BluetoothBase, psm: u32, port: *exec.MsgPort) i32 {
    const listener = bt.AddBTListener(psm, port) orelse {
        _ = Printf(dl, "%s: PSM %lu is served already, or is not one a channel can name\n", .{ @as([*:0]const u8, COMMAND_NAME), @as(u64, psm) });
        return dos.RETURN_ERROR;
    };
    var open: [channels_most]?*bluetooth.BTChannel = @splat(null);
    defer finish(sys, bt, listener, port, &open);
    _ = Printf(dl, "Serving PSM %lu; CTRL-C stops\n", .{@as(u64, psm)});
    const mask = (@as(u32, 1) << @intCast(port.sig_bit)) | exec.SIGBREAKF_CTRL_C;
    while (true) {
        const got = sys.Wait(mask);
        while (sys.GetMsg(port)) |message| {
            const told: *bluetooth.BTChannelMessage = @fieldParentPtr("message", message);
            const channel = told.channel.?;
            var shown: [18]u8 = undefined;
            switch (told.kind) {
                bluetooth.BTCM_OPENED => {
                    if (!keep(&open, channel)) {
                        _ = Printf(dl, "%s opened a channel: closed again, %lu are open\n", .{ addressText(&channel.address.bytes, &shown), @as(u64, channels_most) });
                        sys.ReplyMsg(message);
                        // What came about it meanwhile is taken back.
                        bt.CloseBTChannel(channel);
                        continue;
                    }
                    _ = Printf(dl, "%s opened a channel, frames of %u bytes each way at most\n", .{ addressText(&channel.address.bytes, &shown), @as(u32, @min(channel.mtu_in, channel.mtu_out)) });
                },
                bluetooth.BTCM_DATA => {
                    const length = told.length;
                    const sent = bt.SendBTChannel(channel, told.data orelse "", @min(length, channel.mtu_out));
                    if (sent != 0) _ = Printf(dl, "%s: %u bytes not sent back: %s\n", .{ addressText(&channel.address.bytes, &shown), length, failure(sent) });
                },
                bluetooth.BTCM_CLOSED => {
                    _ = Printf(dl, "%s closed its channel", .{addressText(&channel.address.bytes, &shown)});
                    if (told.result != 0) _ = Printf(dl, " (%s)", .{failure(told.result)});
                    _ = dl.PutStr("\n");
                    sys.ReplyMsg(message);
                    forget(&open, channel);
                    bt.CloseBTChannel(channel);
                    continue;
                },
                else => {},
            }
            sys.ReplyMsg(message);
        }
        if (got & exec.SIGBREAKF_CTRL_C != 0) {
            _ = dl.PutStr("***Break\n");
            return dos.RETURN_WARN;
        }
    }
}

/// `channel` among the open ones; false when they are as many as there
/// is room for.
fn keep(open: *[channels_most]?*bluetooth.BTChannel, channel: *bluetooth.BTChannel) bool {
    for (open) |*slot| {
        if (slot.* != null) continue;
        slot.* = channel;
        return true;
    }
    return false;
}

fn forget(open: *[channels_most]?*bluetooth.BTChannel, channel: *bluetooth.BTChannel) void {
    for (open) |*slot| {
        if (slot.* == channel) slot.* = null;
    }
}

/// The listener taken away - nothing new comes then - the channels whose
/// BTCM_OPENED is still on the port closed, and the others with them.
fn finish(sys: *ExecBase, bt: *BluetoothBase, listener: *bluetooth.BTListener, port: *exec.MsgPort, open: *[channels_most]?*bluetooth.BTChannel) void {
    bt.RemBTListener(listener);
    while (sys.GetMsg(port)) |message| {
        const told: *bluetooth.BTChannelMessage = @fieldParentPtr("message", message);
        const opened = if (told.kind == bluetooth.BTCM_OPENED) told.channel else null;
        sys.ReplyMsg(message);
        bt.CloseBTChannel(opened);
    }
    for (open) |channel| bt.CloseBTChannel(channel);
}

/// A channel opened to the device's `psm`: what is typed sent, what comes
/// shown.
fn talk(sys: *ExecBase, dl: *DosBase, bt: *BluetoothBase, controller: u32, text: [*:0]const u8, psm: u32, port: *exec.MsgPort) i32 {
    const bytes = parseAddress(text) orelse {
        _ = Printf(dl, "%s: %s is not an address (00:00:5E:EF:10:01)\n", .{ @as([*:0]const u8, COMMAND_NAME), text });
        return dos.RETURN_ERROR;
    };
    const address = bluetooth.BTAddress{ .bytes = bytes };
    var shown: [18]u8 = undefined;
    _ = Printf(dl, "Opening a channel to PSM %lu of %s\n", .{ @as(u64, psm), addressText(&address.bytes, &shown) });
    var channel: ?*bluetooth.BTChannel = null;
    const opened = bt.OpenBTChannel(controller, &address, psm, port, &channel);
    if (opened != 0) {
        _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), failure(opened) });
        return dos.RETURN_ERROR;
    }
    defer bt.CloseBTChannel(channel);
    const open = channel.?;
    _ = Printf(dl, "Open, frames of %u bytes each way at most; each line typed is sent, CTRL-C stops\n", .{@as(u32, @min(open.mtu_in, open.mtu_out))});
    const input = dl.Input();
    var line: [1024]u8 = undefined;
    while (true) {
        while (sys.GetMsg(port)) |message| {
            const told: *bluetooth.BTChannelMessage = @fieldParentPtr("message", message);
            const kind = told.kind;
            const result = told.result;
            if (kind == bluetooth.BTCM_DATA) {
                if (told.data) |frame| show(dl, frame[0..told.length]);
            }
            sys.ReplyMsg(message);
            if (kind == bluetooth.BTCM_CLOSED) {
                _ = dl.PutStr("The device closed the channel");
                if (result != 0) _ = Printf(dl, " (%s)", .{failure(result)});
                _ = dl.PutStr("\n");
                return dos.RETURN_OK;
            }
        }
        if (sys.SetSignal(0, exec.SIGBREAKF_CTRL_C) & exec.SIGBREAKF_CTRL_C != 0) {
            _ = dl.PutStr("***Break\n");
            return dos.RETURN_WARN;
        }
        if (!dl.WaitForChar(input, typed_us)) continue;
        const got = dl.Read(input, &line, @min(line.len, open.mtu_out));
        if (got <= 0) return dos.RETURN_OK;
        var length: usize = @intCast(got);
        while (length > 0 and (line[length - 1] == '\n' or line[length - 1] == '\r')) length -= 1;
        const sent = bt.SendBTChannel(open, &line, @intCast(length));
        if (sent != 0) {
            _ = Printf(dl, "%s: %s\n", .{ @as([*:0]const u8, COMMAND_NAME), failure(sent) });
            return dos.RETURN_ERROR;
        }
    }
}

/// A frame shown as text, what is not printable as dots.
fn show(dl: *DosBase, frame: []const u8) void {
    var text: [256]u8 = undefined;
    const length = @min(frame.len, text.len - 1);
    for (frame[0..length], text[0..length]) |byte, *shown| {
        shown.* = if (byte >= 0x20 and byte < 0x7F) byte else '.';
    }
    text[length] = 0;
    _ = Printf(dl, "< %s", .{@as([*:0]const u8, @ptrCast(&text))});
    if (frame.len > length) _ = Printf(dl, " (%u bytes)", .{@as(u32, @intCast(frame.len))});
    _ = dl.PutStr("\n");
}

fn failure(result: i32) [*:0]const u8 {
    return switch (result) {
        bluetooth.BTERR_NOMEM => "no memory, or no room for another channel",
        bluetooth.BTERR_NOCONTROLLER => "no Bluetooth controller",
        bluetooth.BTERR_NOTUP => "the controller is not up",
        bluetooth.BTERR_OFF => "the controller is off (Bluetooth POWER ON)",
        bluetooth.BTERR_REFUSED => "the device refused the channel",
        bluetooth.BTERR_UNSUPPORTED => "the device has no such protocol",
        bluetooth.BTERR_BUSY => "the device has no room for another channel",
        bluetooth.BTERR_TIMEOUT => "the device did not answer in time",
        bluetooth.BTERR_PROTOCOL => "the device's answer made no sense",
        bluetooth.BTERR_NOTCONNECTED => "the channel is closed",
        bluetooth.BTERR_TOOLONG => "longer than the device takes",
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
fn parseAddress(text: [*:0]const u8) ?[6]u8 {
    var bytes: [6]u8 = undefined;
    var at: usize = 0;
    for (0..6) |index| {
        var octet: u8 = 0;
        for (0..2) |_| {
            const char = text[at];
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
            if (text[at] != ':') return null;
            at += 1;
        }
    }
    return if (text[at] == 0) bytes else null;
}
