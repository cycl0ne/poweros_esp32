// SPDX-License-Identifier: MIT
//! The profile drivers' binder, as the rest of the library reaches it: the
//! messages it is sent, the services it has bound, and what ObtainBTBonds
//! reads of them.
//!
//! **The binder** (binder.zig) is a process of the library's own, which
//! offers bonded devices' services to the profile drivers in
//! DEVS:bluetooth/ (drivers.zig): a driver's BTProfileBind may call the
//! library and wait, which the library's task, answering those calls,
//! cannot. The task starts it for a message when it does not run, and it
//! ends once it has nothing on its port and binds nothing - so a binder
//! that does not run binds nothing.
//!
//! **Its start** is the task's (`startWanted`), on its next pass after a
//! message that wants it: the binder holds the library open, and the
//! task takes the library's lock for that only where it is free - an
//! opener holds it while it waits for the task (controller/board.zig) -
//! trying again a moment later where it is not. Until the binder has its
//! port, its messages wait on the base's queue.
//!
//! **Its messages**: `up` - a controller came up: the services kept with
//! its bonds offered again; `bonded` - a pairing made a bond: the device's
//! services listed and offered, those taken kept with the bond; `gone` - a
//! controller went: its bindings ended; `forget` - UnpairBTDevice ends a
//! bond: the device's bindings ended with BTPU_FORGET. The task's are
//! one-way and freed by the binder; UnpairBTDevice's is replied, the call
//! waiting for it.
//!
//! **The bindings** - a Bound each, the BTBinding its driver keeps - are
//! on the base's list. The binder alone changes it, under `binder_lock`,
//! which it never holds while it waits: the task takes the lock to send
//! to it, and ObtainBTBonds to read the drivers' names.

const sdk = @import("sdk");
const exec = sdk.exec;
const bluetooth = sdk.bluetooth;
const BluetoothBase = @import("../bluetooth_base.zig").BluetoothBase;
const drivers = @import("drivers.zig");
const binder = @import("binder.zig");

pub const Kind = enum(u8) { up, bonded, gone, forget };

/// A message to the binder.
pub const Message = extern struct {
    message: exec.Message = .{},
    kind: Kind = .up,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The controller (BTController.id), and its address - its bonds'
    /// directory's name.
    controller: u32 = 0,
    controller_address: [6]u8 = @splat(0),
    /// `bonded`'s and `forget`'s device.
    address: bluetooth.BTAddress = .{},
};

/// One binding: the BTBinding its driver keeps, the driver, and the list
/// of one service `public.service` is in - the binder's, freed with it.
pub const Bound = struct {
    node: exec.Node = .{},
    public: bluetooth.BTBinding = .{},
    driver: *drivers.Driver,
    services: *exec.List,
};

pub fn boundOf(node: *exec.Node) *Bound {
    return @alignCast(@fieldParentPtr("node", node));
}

/// A one-way message from the task: made and sent - the binder to be
/// started for it where `start` and it does not run. False where it could
/// not be made, or the binder neither runs nor is to start.
pub fn tell(base: *BluetoothBase, kind: Kind, controller: u32, controller_address: [6]u8, address: bluetooth.BTAddress, start: bool) bool {
    const sys = base.sys_base;
    const memory = sys.AllocMem(@sizeOf(Message), exec.MEMF_CLEAR) orelse return false;
    const message: *Message = @ptrCast(@alignCast(memory));
    message.* = .{ .kind = kind, .controller = controller, .controller_address = controller_address, .address = address };
    message.message.length = @sizeOf(Message);
    if (send(base, message, start)) return true;
    sys.FreeMem(memory, @sizeOf(Message));
    return false;
}

/// UnpairBTDevice's: the device's bindings ended with BTPU_FORGET, the
/// caller waiting until they are. Nothing where the binder neither runs
/// nor is to start - it binds nothing then - or the caller is the binder
/// itself.
pub fn forget(base: *BluetoothBase, controller: u32, address: bluetooth.BTAddress) void {
    const sys = base.sys_base;
    const me = sys.FindTask(null);
    sys.ObtainSemaphoreShared(&base.binder_lock);
    const own = base.binder == me;
    sys.ReleaseSemaphore(&base.binder_lock);
    if (own) return;
    const reply = sys.CreateMsgPort() orelse return;
    defer sys.DeleteMsgPort(reply);
    var message = Message{ .kind = .forget, .controller = controller, .address = address };
    message.message.reply_port = reply;
    message.message.length = @sizeOf(Message);
    if (!send(base, &message, false)) return;
    _ = sys.WaitPort(reply);
    _ = sys.GetMsg(reply);
}

/// A message put on the binder's port - or, until it has one, on the
/// base's queue, which it takes as it begins. Where the binder neither
/// runs nor is to start, `start` has the task start it; a message without
/// it is not sent then: false.
fn send(base: *BluetoothBase, message: *Message, start: bool) bool {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.binder_lock);
    defer sys.ReleaseSemaphore(&base.binder_lock);
    if (base.binder_port) |port| {
        sys.PutMsg(port, &message.message);
        return true;
    }
    if (base.binder == null and !base.binder_wanted) {
        if (!start) return false;
        base.binder_wanted = true;
    }
    sys.AddTail(&base.binder_queue, &message.message.node);
    return true;
}

/// On the task: the binder started where a message wants it - or, where
/// the library's lock is taken, left to be tried again (`startPending`).
/// False where it could not be started: the messages that waited for it
/// done with, UnpairBTDevice's answered.
pub fn startWanted(base: *BluetoothBase) bool {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.binder_lock);
    defer sys.ReleaseSemaphore(&base.binder_lock);
    if (!base.binder_wanted) return true;
    switch (binder.start(base)) {
        .started => base.binder_wanted = false,
        .later => {},
        .failed => {
            base.binder_wanted = false;
            while (sys.RemHead(&base.binder_queue)) |node| {
                const message: *exec.Message = @fieldParentPtr("node", node);
                binder.done(base, message);
            }
            return false;
        },
    }
    return true;
}

/// Whether the binder is still to be started: the task tries again soon,
/// and does not end meanwhile.
pub fn startPending(base: *BluetoothBase) bool {
    const sys = base.sys_base;
    sys.ObtainSemaphoreShared(&base.binder_lock);
    defer sys.ReleaseSemaphore(&base.binder_lock);
    return base.binder_wanted;
}

/// Whether one of the device's services is bound - with `handle`, the
/// service whose record has that handle. Under `binder_lock`, or on the
/// binder.
pub fn isBound(base: *BluetoothBase, controller: u32, address: bluetooth.BTAddress, handle: ?u32) bool {
    var it = base.bindings.iterator();
    while (it.next()) |node| {
        const bound = boundOf(node);
        if (bound.public.controller != controller or !sameAddress(bound.public.address, address)) continue;
        if (handle) |wanted| {
            if (bound.public.service.?.handle != wanted) continue;
        }
        return true;
    }
    return false;
}

/// The names of the drivers bound to a device's services, a comma between
/// two, into `into` - as many as fit, ended by a NUL.
pub fn driversOf(base: *BluetoothBase, controller: u32, address: bluetooth.BTAddress, into: []u8) void {
    const sys = base.sys_base;
    into[0] = 0;
    sys.ObtainSemaphoreShared(&base.binder_lock);
    defer sys.ReleaseSemaphore(&base.binder_lock);
    var at: usize = 0;
    var it = base.bindings.iterator();
    while (it.next()) |node| {
        const bound = boundOf(node);
        if (bound.public.controller != controller or !sameAddress(bound.public.address, address)) continue;
        const name = drivers.nameOf(bound.driver);
        if (contains(into[0..at], name)) continue;
        const comma: usize = if (at == 0) 0 else 2;
        if (at + comma + name.len + 1 > into.len) break;
        if (comma != 0) {
            @memcpy(into[at..][0..2], ", ");
            at += 2;
        }
        @memcpy(into[at..][0..name.len], name);
        at += name.len;
        into[at] = 0;
    }
}

/// Whether a list of names, a comma between two, has `name`.
fn contains(names: []const u8, name: []const u8) bool {
    var start: usize = 0;
    while (start < names.len) {
        var end = start;
        while (end < names.len and names[end] != ',') end += 1;
        if (end - start == name.len) {
            var same = true;
            for (names[start..end], name) |have, want| {
                if (have != want) same = false;
            }
            if (same) return true;
        }
        start = end + 2;
    }
    return false;
}

pub fn sameAddress(one: bluetooth.BTAddress, other: bluetooth.BTAddress) bool {
    if (one.kind != other.kind) return false;
    for (one.bytes, other.bytes) |mine, theirs| {
        if (mine != theirs) return false;
    }
    return true;
}
