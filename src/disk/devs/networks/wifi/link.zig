// SPDX-License-Identifier: MIT
//! The radio as the network unit's link (sdk/devices/network/unit.zig):
//! frames in and out, and the carrier.
//!
//! **In.** The libraries hand every frame the station receives to
//! `received`, on their own task, as an Ethernet frame. The openers'
//! copy calls may run only on the device's task, so the frame is copied
//! into a ring of buffers in the work block and handed straight back, and
//! the device's task is signalled; it gives each frame to the unit
//! (`deliver`). A frame the ring has no room for is lost and counted.
//!
//! **Out.** A write is built into one buffer and handed to the libraries,
//! which copy it and send it when the air is free; the write is answered
//! as soon as they have it.
//!
//! **The carrier** is the association: the unit is told it has one when
//! the station has joined a network and its keys are in place, and that
//! it has lost it when the station leaves or is thrown off.

const sdk = @import("sdk");
const exec = sdk.exec;
const ethernet = sdk.devices.network.ethernet;
const _wifi = @import("_wifi.zig");
const WifiBase = _wifi.WifiBase;
const _osi = @import("osi/_osi.zig");
const vendor = @import("vendor.zig");

/// Frames that can wait for the device's task.
pub const receive_count = 8;
pub const buffer_bytes = 1536;

/// The ring the libraries' task fills and the device's task empties.
pub const Frames = struct {
    buffers: [receive_count][buffer_bytes]u8 align(4) = undefined,
    lengths: [receive_count]u16 = @splat(0),
    head: u32 = 0,
    count: u32 = 0,
    lost: u32 = 0,
    send: [buffer_bytes]u8 align(4) = undefined,
};

/// The libraries' receive callback: the frame copied into the ring, and
/// given back. The device's base is the adapter's, through the one
/// global: the callback carries no context.
fn received(buffer: ?*anyopaque, length: u16, eb: ?*anyopaque) callconv(.c) i32 {
    defer vendor.esp_wifi_internal_free_rx_buffer(eb);
    const state = _osi.adapter orelse return 0;
    const base: *WifiBase = @ptrCast(@alignCast(state.device orelse return 0));
    const frames = &base.work.?.frames;
    const bytes: [*]const u8 = @ptrCast(buffer orelse return 0);
    const sys = base.sys_base;
    sys.Disable();
    defer sys.Enable();
    if (base.running == 0) return 0;
    if (frames.count == receive_count or length > buffer_bytes) {
        frames.lost += 1;
        return 0;
    }
    const slot = (frames.head + frames.count) % receive_count;
    @memcpy(frames.buffers[slot][0..length], bytes[0..length]);
    frames.lengths[slot] = length;
    frames.count += 1;
    sys.Signal(&base.task, base.frame_mask);
    return 0;
}

/// Frames are handed to the device from now on (the station joined), or
/// no longer.
pub fn hook(on: bool) void {
    _ = vendor.esp_wifi_internal_reg_rxcb(vendor.if_sta, if (on) &received else null);
}

/// Every frame in the ring handed to the unit, on the device's task.
pub fn deliver(base: *WifiBase) void {
    const sys = base.sys_base;
    const frames = &base.work.?.frames;
    while (true) {
        sys.Disable();
        const lost = frames.lost;
        frames.lost = 0;
        if (frames.count == 0) {
            sys.Enable();
            for (0..lost) |_| base.net.overrun();
            return;
        }
        const slot = frames.head;
        const length = frames.lengths[slot];
        sys.Enable();
        for (0..lost) |_| base.net.overrun();
        // The slot stays the task's until it is counted free below; the
        // callback only writes past `count`.
        base.net.receive(frames.buffers[slot][0..length]);
        sys.Disable();
        frames.head = (frames.head + 1) % receive_count;
        frames.count -= 1;
        sys.Enable();
    }
}

/// Every write the unit has, sent.
pub fn startWrites(base: *WifiBase) void {
    const frames = &base.work.?.frames;
    while (base.running != 0) {
        const req = base.net.nextWrite() orelse return;
        const length = base.net.buildFrame(req, &frames.send);
        if (length == 0) continue;
        const sent = vendor.esp_wifi_internal_tx(vendor.if_sta, &frames.send, @intCast(length)) == 0;
        base.net.written(req, sent);
    }
}
