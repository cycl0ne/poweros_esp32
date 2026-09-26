// SPDX-License-Identifier: MIT
//! The radio's events: the libraries post each one through the adapter
//! (`_event_post`) with the base `WIFI_EVENT`, an id and a little data -
//! the station started, a scan is done, the station joined or left a
//! network. Each is copied into a ring in the adapter and the device's
//! task is signalled; the task takes them there and acts on them, so
//! nothing the libraries' own task does waits on the device.
//!
//! An event the ring has no room for is dropped and counted. Events
//! carry nothing the device cannot ask for again (a scan's results are
//! fetched, not posted), so a lost one costs a retry at most.

const sdk = @import("sdk");
const _osi = @import("osi/_osi.zig");

/// ESP_EVENT_DEFINE_BASE(WIFI_EVENT): the base the libraries post with.
export const WIFI_EVENT: [*:0]const u8 = "WIFI_EVENT";

/// wifi_event_t, the ones the device acts on.
pub const ready = 0;
pub const scan_done = 1;
pub const sta_start = 2;
pub const sta_stop = 3;
pub const sta_connected = 4;
pub const sta_disconnected = 5;

/// An event's data, as much of it as the device reads.
pub const data_bytes = 48;

pub const Event = struct {
    id: i32 = 0,
    length: u32 = 0,
    data: [data_bytes]u8 = @splat(0),
};

pub const ring_length = 8;

/// The events not yet taken, and the task told of new ones.
pub const Events = struct {
    ring: [ring_length]Event = @splat(.{}),
    head: u32 = 0,
    count: u32 = 0,
    dropped: u32 = 0,
    task: ?*sdk.exec.Task = null,
    signal: u32 = 0,
};

pub fn post(base: ?[*:0]const u8, id: i32, data: ?*const anyopaque, size: usize, _: u32) callconv(.c) i32 {
    const state = _osi.adapter orelse return -1;
    if (base != WIFI_EVENT) return 0;
    if (state.trace) sdk.exec.kprintf(state.sys, "wifi: event %ld\n", .{@as(i64, id)});
    const events = &state.events;
    const sys = state.sys;
    sys.Disable();
    defer sys.Enable();
    if (events.count == ring_length) {
        events.dropped += 1;
        return 0;
    }
    const slot = &events.ring[(events.head + events.count) % ring_length];
    const kept = @min(size, data_bytes);
    slot.* = .{ .id = id, .length = @intCast(kept) };
    if (data) |bytes| @memcpy(slot.data[0..kept], @as([*]const u8, @ptrCast(bytes))[0..kept]);
    events.count += 1;
    if (events.task) |task| sys.Signal(task, events.signal);
    return 0;
}

/// The oldest event, taken; null when there is none.
pub fn take(events: *Events, sys: *sdk.interface.exec.ExecBase) ?Event {
    sys.Disable();
    defer sys.Enable();
    if (events.count == 0) return null;
    const event = events.ring[events.head];
    events.head = (events.head + 1) % ring_length;
    events.count -= 1;
    return event;
}
