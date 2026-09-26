// SPDX-License-Identifier: MIT
//! The adapter's queues: a fixed number of fixed-size items, copied in and
//! out, with a timeout on either side. The libraries' own task lives on
//! one (200 items of 8 bytes), and their interrupt handler sends to it.
//!
//! `Ring` is the queue's storage and nothing else - no locks, no waiting -
//! so the host tests take it on its own. A `Queue` is a ring with two
//! lists of waiters, senders for room and receivers for an item; a send or
//! a receive wakes the other side.
//!
//! Two shapes are asked for: `_queue_create` answers the queue itself,
//! `_wifi_create_queue` a small wrapper `{ handle, storage }` whose handle
//! the libraries then pass to the queue calls.

const sdk = @import("sdk");
const exec = sdk.exec;
const _osi = @import("_osi.zig");

/// OSI_QUEUE_SEND_FRONT, _BACK, _OVERWRITE.
pub const send_front = 0;
pub const send_back = 1;
pub const send_overwrite = 2;

/// Fixed-size items in a circle: `head` is the oldest, `count` are held.
pub const Ring = struct {
    items: [*]u8,
    item_size: u32,
    length: u32,
    head: u32 = 0,
    count: u32 = 0,

    fn slot(ring: *Ring, index: u32) []u8 {
        const at = (index % ring.length) * ring.item_size;
        return ring.items[at .. at + ring.item_size];
    }

    /// `item` added at the back (or front); false if the ring is full.
    pub fn put(ring: *Ring, item: [*]const u8, front: bool) bool {
        if (ring.count == ring.length) return false;
        if (front) {
            ring.head = (ring.head + ring.length - 1) % ring.length;
            @memcpy(ring.slot(ring.head), item[0..ring.item_size]);
        } else {
            @memcpy(ring.slot(ring.head + ring.count), item[0..ring.item_size]);
        }
        ring.count += 1;
        return true;
    }

    /// The oldest item copied out and dropped; false if the ring is empty.
    pub fn take(ring: *Ring, item: [*]u8) bool {
        if (ring.count == 0) return false;
        @memcpy(item[0..ring.item_size], ring.slot(ring.head));
        ring.head = (ring.head + 1) % ring.length;
        ring.count -= 1;
        return true;
    }
};

pub const Queue = struct {
    ring: Ring,
    senders: exec.List = .{},
    receivers: exec.List = .{},
};

/// What `_wifi_create_queue` answers (wifi_static_queue_t).
pub const StaticQueue = extern struct {
    handle: ?*Queue,
    storage: ?*anyopaque,
};

pub fn make(length: u32, item_size: u32) ?*Queue {
    if (length == 0 or item_size == 0) return null;
    const memory = _osi.alloc(@sizeOf(Queue) + length * item_size, true, false) orelse return null;
    const queue: *Queue = @ptrCast(@alignCast(memory));
    const items: [*]u8 = @as([*]u8, @ptrCast(memory)) + @sizeOf(Queue);
    queue.* = .{ .ring = .{ .items = items, .item_size = item_size, .length = length } };
    queue.senders.init(.unknown);
    queue.receivers.init(.unknown);
    return queue;
}

pub fn queueCreate(length: u32, item_size: u32) callconv(.c) ?*anyopaque {
    _osi.trace("queue_create");
    return make(length, item_size);
}

pub fn queueDelete(queue: ?*anyopaque) callconv(.c) void {
    _osi.trace("queue_delete");
    _osi.free(queue);
}

pub fn wifiCreateQueue(length: c_int, item_size: c_int) callconv(.c) ?*anyopaque {
    _osi.trace("wifi_create_queue");
    const memory = _osi.alloc(@sizeOf(StaticQueue), true, false) orelse return null;
    const wrapper: *StaticQueue = @ptrCast(@alignCast(memory));
    wrapper.* = .{
        .handle = make(@intCast(length), @intCast(item_size)) orelse {
            _osi.free(memory);
            return null;
        },
        .storage = null,
    };
    return wrapper;
}

pub fn wifiDeleteQueue(handle: ?*anyopaque) callconv(.c) void {
    _osi.trace("wifi_delete_queue");
    const wrapper: *StaticQueue = @ptrCast(@alignCast(handle orelse return));
    _osi.free(wrapper.handle);
    _osi.free(wrapper);
}

const Put = struct {
    queue: *Queue,
    item: [*]const u8,
    front: bool,

    fn attempt(put: Put) bool {
        if (!put.queue.ring.put(put.item, put.front)) return false;
        _osi.wakeAll(&put.queue.receivers);
        return true;
    }
};

const Get = struct {
    queue: *Queue,
    item: [*]u8,

    fn attempt(get: Get) bool {
        if (!get.queue.ring.take(get.item)) return false;
        _osi.wakeAll(&get.queue.senders);
        return true;
    }
};

fn send(handle: ?*anyopaque, item: ?*anyopaque, ticks: u32, front: bool) i32 {
    const queue: *Queue = @ptrCast(@alignCast(handle.?));
    const put: Put = .{ .queue = queue, .item = @ptrCast(item.?), .front = front };
    return @intFromBool(_osi.waitUntil(&queue.senders, _osi.deadline(ticks), put, Put.attempt));
}

pub fn queueSend(queue: ?*anyopaque, item: ?*anyopaque, ticks: u32) callconv(.c) i32 {
    return send(queue, item, ticks, false);
}

pub fn queueSendToBack(queue: ?*anyopaque, item: ?*anyopaque, ticks: u32) callconv(.c) i32 {
    return send(queue, item, ticks, false);
}

pub fn queueSendToFront(queue: ?*anyopaque, item: ?*anyopaque, ticks: u32) callconv(.c) i32 {
    return send(queue, item, ticks, true);
}

/// From the libraries' interrupt handler: never waits. No task switch is
/// asked for, since exec makes one on the way out of the interrupt when a
/// woken task should run.
pub fn queueSendFromIsr(handle: ?*anyopaque, item: ?*anyopaque, higher_priority_woken: ?*anyopaque) callconv(.c) i32 {
    if (higher_priority_woken) |woken| @as(*i32, @ptrCast(@alignCast(woken))).* = _osi.no;
    const queue: *Queue = @ptrCast(@alignCast(handle.?));
    const sys = _osi.get().sys;
    sys.Disable();
    defer sys.Enable();
    return @intFromBool(Put.attempt(.{ .queue = queue, .item = @ptrCast(item.?), .front = false }));
}

pub fn queueRecv(handle: ?*anyopaque, item: ?*anyopaque, ticks: u32) callconv(.c) i32 {
    const queue: *Queue = @ptrCast(@alignCast(handle.?));
    const get: Get = .{ .queue = queue, .item = @ptrCast(item.?) };
    return @intFromBool(_osi.waitUntil(&queue.receivers, _osi.deadline(ticks), get, Get.attempt));
}

pub fn queueMsgWaiting(handle: ?*anyopaque) callconv(.c) u32 {
    const queue: *Queue = @ptrCast(@alignCast(handle.?));
    return queue.ring.count;
}

test Ring {
    const testing = @import("std").testing;
    var storage: [3 * 2]u8 = undefined;
    var ring: Ring = .{ .items = &storage, .item_size = 2, .length = 3 };
    var out: [2]u8 = undefined;
    try testing.expect(!ring.take(&out));
    try testing.expect(ring.put("ab", false));
    try testing.expect(ring.put("cd", false));
    try testing.expect(ring.put("zz", true));
    try testing.expect(!ring.put("ef", false));
    try testing.expect(ring.take(&out));
    try testing.expectEqualStrings("zz", &out);
    try testing.expect(ring.take(&out));
    try testing.expectEqualStrings("ab", &out);
    try testing.expect(ring.put("gh", false));
    try testing.expect(ring.put("ij", false));
    try testing.expect(ring.take(&out));
    try testing.expectEqualStrings("cd", &out);
    try testing.expect(ring.take(&out));
    try testing.expectEqualStrings("gh", &out);
    try testing.expect(ring.take(&out));
    try testing.expectEqualStrings("ij", &out);
    try testing.expectEqual(@as(u32, 0), ring.count);
}
