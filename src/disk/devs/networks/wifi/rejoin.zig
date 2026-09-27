// SPDX-License-Identifier: MIT
//! Joining again after the station has come off a network it was asked to
//! be on.
//!
//! A join that was asked for (S2_SETOPTIONS with a network) stays wanted
//! until it is left (S2INFO_Disassociate). While it is wanted, every time
//! the station comes off the network - thrown off, the beacons gone, or a
//! join refused - it tries again after a pause: one second, then twice as
//! long each time, up to a minute. Joining resets the pause to a second.
//!
//! The first try after the board restarts is often refused: the access
//! point still holds the station from before and throws the new
//! authentication out. The second is let in, a second later.
//!
//! The pause is a timer.device request of the device's own, whose reply
//! wakes the device's task (`mask`); the task then calls `fired`.

const sdk = @import("sdk");
const exec = sdk.exec;
const timer = sdk.devices.timer;
const _wifi = @import("_wifi.zig");
const WifiBase = _wifi.WifiBase;
const vendor = @import("vendor.zig");

/// The first pause, and the longest, in seconds.
const first_pause_s: u32 = 1;
const longest_pause_s: u32 = 60;
/// WIFI_REASON_ASSOC_LEAVE: the station left of its own accord.
const own_leave: u8 = 8;

pub const Rejoin = extern struct {
    port: ?*exec.MsgPort = null,
    request: ?*timer.TimeRequest = null,
    /// Whether the request is out.
    pending: u8 = 0,
    /// Whether a network is wanted.
    wanted: u8 = 0,
    pad: [2]u8 = @splat(0),
    /// The next pause, in seconds.
    pause_s: u32 = first_pause_s,
};

/// The timer made, on the device's task. False if it cannot be had; the
/// station then does not join again by itself.
pub fn open(base: *WifiBase) bool {
    const sys = base.sys_base;
    const rejoin = &base.rejoin;
    const port = sys.CreateMsgPort() orelse return false;
    const request: *timer.TimeRequest = @ptrCast(@alignCast(sys.CreateIORequest(port, @sizeOf(timer.TimeRequest)) orelse {
        sys.DeleteMsgPort(port);
        return false;
    }));
    if (sys.OpenDevice(timer.TIMERNAME, timer.UNIT_VBLANK, &request.node, 0) != 0) {
        sys.DeleteIORequest(&request.node);
        sys.DeleteMsgPort(port);
        return false;
    }
    rejoin.port = port;
    rejoin.request = request;
    return true;
}

/// The signal the pause's end raises; 0 without a timer.
pub fn mask(base: *WifiBase) u32 {
    const port = base.rejoin.port orelse return 0;
    return port.sigMask();
}

/// A network is wanted from now on, or no longer. Either way a pause under
/// way is over: a new join starts at once, and a leave stays left.
pub fn want(base: *WifiBase, on: bool) void {
    cancel(base);
    base.rejoin.wanted = @intFromBool(on);
    base.rejoin.pause_s = first_pause_s;
}

/// The station has joined: the next pause starts short again.
pub fn joined(base: *WifiBase) void {
    cancel(base);
    base.rejoin.pause_s = first_pause_s;
}

/// The station has come off the network for `reason`: if one is wanted,
/// the next try is set for after the pause, and the pause after it
/// doubles. Reason 8 is the station leaving itself - a new join takes it
/// off the network it is on first - and is no reason to try again.
pub fn left(base: *WifiBase, reason: u8) void {
    const rejoin = &base.rejoin;
    if (reason == own_leave) return;
    if (rejoin.wanted == 0 or rejoin.pending != 0) return;
    const request = rejoin.request orelse return;
    request.node.command = timer.TR_ADDREQUEST;
    request.time = timer.TimeVal.fromMicros(@as(u64, rejoin.pause_s) * 1_000_000);
    base.sys_base.SendIO(&request.node);
    rejoin.pending = 1;
    rejoin.pause_s = @min(rejoin.pause_s * 2, longest_pause_s);
}

/// The device's task was woken: if the pause is over, the station tries
/// the wanted network again, with the settings the join left.
pub fn fired(base: *WifiBase) void {
    const rejoin = &base.rejoin;
    const request = rejoin.request orelse return;
    if (rejoin.pending == 0 or base.sys_base.CheckIO(&request.node) == null) return;
    _ = base.sys_base.WaitIO(&request.node);
    rejoin.pending = 0;
    if (rejoin.wanted == 0 or base.net.carrier != 0) return;
    sdk.exec.kprintf(base.sys_base, "%s: joining again\n", .{_wifi.DEVICE_NAME});
    _ = vendor.esp_wifi_connect_internal();
}

fn cancel(base: *WifiBase) void {
    const rejoin = &base.rejoin;
    const request = rejoin.request orelse return;
    if (rejoin.pending == 0) return;
    const sys = base.sys_base;
    if (sys.CheckIO(&request.node) == null) _ = sys.AbortIO(&request.node);
    _ = sys.WaitIO(&request.node);
    rejoin.pending = 0;
}
