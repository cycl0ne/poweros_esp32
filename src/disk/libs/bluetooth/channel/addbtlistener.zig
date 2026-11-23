// SPDX-License-Identifier: MIT
//! AddBTListener: a PSM served, the channels devices open to it taken.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const l2cap = bluetooth.l2cap;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const _channel = @import("_channel.zig");
const l2cap_channels = @import("../l2cap/channels.zig");

/// Serves a PSM: the channels devices open to it are taken, and come to a
/// port.
///
/// SYNOPSIS:
/// ```zig
/// fn AddBTListener(base: *BluetoothBase, psm: u32, port: *exec.MsgPort,
///     flags: u32) ?*bluetooth.BTListener
/// ```
///
/// SINCE: 1.7. LVO -116.
///
/// INPUTS:
/// - `psm` - the protocol's: odd, the low bit of its upper byte clear;
///   one of l2cap.PSM_DYNAMIC_FIRST's and above for one of the program's
///   own. Not l2cap.PSM_SDP, which the library serves.
/// - `port` - where the channels come, and their messages.
/// - `flags` - BTLSF_SECURE: a channel only over a link made secure with
///   a bond; 0 for any link.
///
/// RESULT:
/// A handle for RemBTListener; null without memory, for a PSM another
/// listener serves, PSM_SDP, or one no channel can name.
///
/// BEHAVIOR:
/// A device that opens a channel to the PSM, over a BR/EDR link of any
/// controller, has it taken. Once its configuration is agreed - as
/// OpenBTChannel's is - the channel comes to `port` as a BTCM_OPENED
/// message, `channel` its block, BTCHF_INCOMING in its flags; its frames
/// and its end come to the same port as an opened channel's do. A device
/// that opens one to a PSM nobody serves is told there is no such
/// protocol.
///
/// With BTLSF_SECURE a channel is taken only over a link that is
/// encrypted after an authentication with the key of the bond the two
/// have. A device with a bond whose link is not so yet is told to wait
/// while the library makes it so - or the device does - and its channel
/// is taken once it is; a device without a bond, a link that cannot be
/// made secure, and one that is not so within a minute are refused for
/// their security. A device's keys and moves, say, then come only from
/// a device paired with.
///
/// CONTEXT:
/// - Waits: yes, for the listeners' list.
/// - Interrupts: no.
/// - Locks: none may be held.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The handle is the caller's until RemBTListener; the port must be
/// there until then. A channel that comes is the port's task's - given to
/// it - until CloseBTChannel, whether the listener is still there or not.
///
/// NOTES:
/// The link a device opens a channel over is the device's: it stays when
/// the channel closes. `flags` since 1.9.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemBTListener`, `OpenBTChannel`, `CloseBTChannel`
///
/// EXAMPLES:
/// ```zig
/// const listener = bt.AddBTListener(0x1001, port, 0) orelse return;
/// defer bt.RemBTListener(listener);
/// ```
pub fn AddBTListener(base: *BluetoothBase, psm: u32, port: *exec.MsgPort, flags: u32) ?*bluetooth.BTListener {
    if (!l2cap_channels.validPsm(psm) or psm == l2cap.PSM_SDP) return null;
    const sys = base.sys_base;
    const memory = sys.AllocMem(@sizeOf(_channel.Listener), exec.MEMF_CLEAR) orelse return null;
    const listener: *_channel.Listener = @ptrCast(@alignCast(memory));
    sys.ObtainSemaphore(&base.listeners_lock);
    defer sys.ReleaseSemaphore(&base.listeners_lock);
    if (_channel.findPsm(base, psm) != null) {
        sys.FreeMem(memory, @sizeOf(_channel.Listener));
        return null;
    }
    base.listener_number += 1;
    listener.* = .{ .id = base.listener_number, .psm = @intCast(psm), .secure = flags & bluetooth.BTLSF_SECURE != 0, .port = port };
    sys.AddTail(&base.listeners, &listener.node);
    return @ptrCast(listener);
}
