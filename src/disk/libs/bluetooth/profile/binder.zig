// SPDX-License-Identifier: MIT
//! The binder's process (_profile.zig): started for a message, each
//! message's work done in turn, ended once its port is empty and it binds
//! nothing.
//!
//! **up**: each service kept with one of the controller's bonds
//! (kept.zig) that is not bound already offered to the drivers again,
//! made from its record - or a GATT service from its handles and UUID -
//! as ObtainBTServices lists a device's.
//!
//! **bonded**: unless a service of the device is bound already, the
//! device's services listed (ObtainBTServices) - where some driver takes
//! a service over its kind of link - and each offered; the services
//! taken kept with its bond.
//!
//! **gone** and **forget**: the controller's bindings, or the device's,
//! ended - with BTPU_FORGET for forget - each driver told and closed once
//! it drives nothing.
//!
//! The library's own calls go through its jump table; none is made under
//! `binder_lock`, which is held only while the list of bindings changes.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const bluetooth = sdk.bluetooth;
const btprofile = sdk.devices.btprofile;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("../bluetooth_base.zig");
const BluetoothBase = _base.BluetoothBase;
const _service = @import("../service/_service.zig");
const _profile = @import("_profile.zig");
const Message = _profile.Message;
const Bound = _profile.Bound;
const drivers = @import("drivers.zig");
const kept = @import("kept.zig");
const att_client = @import("../att/client.zig");

const binder_name = "bluetooth.library profiles";
/// The drivers' BTProfileBind and BTProfileUnbind run on it, with the
/// library's calls they make.
const stack_bytes = 16384;
/// The most services of one device kept.
const KEPT_MOST = 16;

pub const Start = enum { started, later, failed };

/// The binder started, on the task under `binder_lock`: its process made,
/// which takes the messages queued for it as it begins. `later` where the
/// library's lock is taken; `failed` where the process could not be made.
pub fn start(base: *BluetoothBase) Start {
    const sys = base.sys_base;
    // The open count the binder holds, taken here and handed to dos with
    // it - under the library's lock, which OpenLibrary changes it under,
    // and not waited for: an opener holds it while it waits for the task.
    if (!sys.AttemptSemaphore(&base.lib.lock)) return .later;
    defer sys.ReleaseSemaphore(&base.lib.lock);
    const dl = base.dos orelse return .failed;
    base.lib.open_cnt += 1;
    const tags = [_]sdk.utility.TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&binderMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(@as([*:0]const u8, binder_name)) },
        .{ .tag = dos.NP_StackSize, .data = stack_bytes },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(base) },
        .{ .tag = dos.NP_HoldLibrary, .data = @intFromPtr(&base.lib) },
        .{},
    };
    const process = dl.CreateNewProc(&tags) orelse {
        base.lib.open_cnt -= 1;
        return .failed;
    };
    base.binder = &process.task;
    return .started;
}

fn binderMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const base: *BluetoothBase = @ptrCast(@alignCast(me.user_data orelse return));
    const made = sys.CreateMsgPort();
    sys.ObtainSemaphore(&base.binder_lock);
    const port = made orelse {
        // Nothing done: the messages for it answered as they are.
        while (sys.RemHead(&base.binder_queue)) |node| done(base, @fieldParentPtr("node", node));
        base.binder = null;
        sys.ReleaseSemaphore(&base.binder_lock);
        return;
    };
    base.binder_port = port;
    while (sys.RemHead(&base.binder_queue)) |node| {
        const message: *exec.Message = @fieldParentPtr("node", node);
        sys.PutMsg(port, message);
    }
    sys.ReleaseSemaphore(&base.binder_lock);
    while (true) {
        while (sys.GetMsg(port)) |message| {
            handle(base, message);
            done(base, message);
        }
        // Ended under the lock a message is sent under: none comes after.
        sys.ObtainSemaphore(&base.binder_lock);
        if (port.msg_list.isEmpty() and base.bindings.isEmpty()) {
            base.binder_port = null;
            base.binder = null;
            sys.ReleaseSemaphore(&base.binder_lock);
            break;
        }
        sys.ReleaseSemaphore(&base.binder_lock);
        _ = sys.WaitPort(port);
    }
    sys.DeleteMsgPort(port);
}

/// A message done with: replied where it is UnpairBTDevice's, freed where
/// it is the task's.
pub fn done(base: *BluetoothBase, raw: *exec.Message) void {
    const sys = base.sys_base;
    if (raw.reply_port != null) return sys.ReplyMsg(raw);
    const message: *Message = @fieldParentPtr("message", raw);
    sys.FreeMem(message, @sizeOf(Message));
}

fn handle(base: *BluetoothBase, raw: *exec.Message) void {
    const message: *Message = @fieldParentPtr("message", raw);
    switch (message.kind) {
        .up => up(base, message),
        .bonded => bonded(base, message),
        .gone => endAll(base, message.controller, null, 0),
        .forget => endAll(base, message.controller, message.address, bluetooth.BTPU_FORGET),
    }
}

// --- up -----------------------------------------------------------------------------

/// A controller up: the services kept with each of its bonds offered
/// again, those bound already passed over.
fn up(base: *BluetoothBase, message: *const Message) void {
    const table = drivers.table(base) orelse return;
    if (table.count == 0) return;
    const dl = base.dos orelse return;
    const bt = _base.interface(base);
    const list = bt.ObtainBTBonds(message.controller) orelse return;
    defer bt.ReleaseBTBonds(list);
    var it = list.iterator();
    while (it.next()) |node| {
        const bond: *const bluetooth.BTBond = @ptrCast(@alignCast(node));
        var offering = Offering{ .base = base, .controller = message.controller, .address = bond.address };
        kept.read(base, dl, &message.controller_address, &bond.address, &offering, Offering.each);
    }
}

/// A kept service offered, from its record.
const Offering = struct {
    base: *BluetoothBase,
    controller: u32,
    address: bluetooth.BTAddress,

    fn each(offering: *Offering, service_kept: kept.Kept) void {
        const base = offering.base;
        var made: ?*exec.List = null;
        const result = switch (service_kept) {
            .record => |record| _service.makeOne(base, offering.controller, offering.address, record, &made),
            .gatt => |gatt| _service.makeGatt(base, offering.controller, offering.address, @as([*]const u8, @ptrCast(&gatt))[0..@sizeOf(att_client.ServiceRecord)], &made),
        };
        if (result != 0) return;
        const services = made.?;
        const service: *const bluetooth.BTService = @ptrCast(@alignCast(services.first().?));
        if (_profile.isBound(base, offering.controller, offering.address, service.handle)) {
            base.sys_base.FreeVec(services);
            return;
        }
        _ = bind(base, offering.controller, offering.address, services);
    }
};

// --- bonded -------------------------------------------------------------------------

/// A bond a pairing made: the device's services offered, those taken kept
/// with the bond.
fn bonded(base: *BluetoothBase, message: *const Message) void {
    const controller = message.controller;
    const address = message.address;
    // Bonded again while bound: as it was.
    if (_profile.isBound(base, controller, address, null)) return;
    const table = drivers.table(base) orelse return;
    const over = if (address.kind == bluetooth.BTADDR_BREDR) btprofile.BTMATCH_BREDR else btprofile.BTMATCH_LE;
    if (!drivers.wants(table, over)) return;
    const bt = _base.interface(base);
    var listed: ?*exec.List = null;
    const result = bt.ObtainBTServices(controller, &address, &listed);
    if (result != 0) {
        say(base, "%s: controller %u, %02x:%02x:%02x:%02x:%02x:%02x: its services not listed (%ld)\n", controller, address, .{@as(i64, result)});
        return;
    }
    defer bt.ReleaseBTServices(listed);
    var taken: [KEPT_MOST]*const bluetooth.BTService = undefined;
    var count: usize = 0;
    var it = listed.?.iterator();
    while (it.next()) |node| {
        const service: *const bluetooth.BTService = @ptrCast(@alignCast(node));
        const copy = _service.copy(base, service) orelse continue;
        if (!bind(base, controller, address, copy)) continue;
        if ((service.record != null or service.flags & bluetooth.BTSF_GATT != 0) and count < taken.len) {
            taken[count] = service;
            count += 1;
        }
    }
    if (count == 0) return;
    const dl = base.dos orelse return;
    if (!kept.write(base, dl, &message.controller_address, &address, taken[0..count])) {
        say(base, "%s: controller %u, %02x:%02x:%02x:%02x:%02x:%02x: its services could not be kept\n", controller, address, .{});
    }
}

// --- bindings -----------------------------------------------------------------------

/// A service - the one in `services`, a list of its own - offered to the
/// drivers, and bound to the one that takes it: false where none does,
/// the list freed then.
pub fn bind(base: *BluetoothBase, controller: u32, address: bluetooth.BTAddress, services: *exec.List) bool {
    const sys = base.sys_base;
    const memory = sys.AllocMem(@sizeOf(Bound), exec.MEMF_CLEAR) orelse {
        sys.FreeVec(services);
        return false;
    };
    const bound: *Bound = @ptrCast(@alignCast(memory));
    const service: *const bluetooth.BTService = @ptrCast(@alignCast(services.first().?));
    bound.* = .{ .public = .{ .controller = controller, .address = address, .service = service }, .driver = undefined, .services = services };
    const driver = drivers.offer(base, &bound.public) orelse {
        sys.FreeMem(memory, @sizeOf(Bound));
        sys.FreeVec(services);
        return false;
    };
    bound.driver = driver;
    sys.ObtainSemaphore(&base.binder_lock);
    sys.AddTail(&base.bindings, &bound.node);
    sys.ReleaseSemaphore(&base.binder_lock);
    const name: [*:0]const u8 = @ptrCast(&driver.name);
    say(base, "%s: controller %u, %02x:%02x:%02x:%02x:%02x:%02x: service 0x%04x bound to %s\n", controller, address, .{ @as(u32, service.class16), name });
    return true;
}

/// The bindings of a controller - every one's with BT_ALL_CONTROLLERS -
/// or only a device's, ended: each driver told, with `flags`.
pub fn endAll(base: *BluetoothBase, controller: u32, address: ?bluetooth.BTAddress, flags: u32) void {
    var it = base.bindings.iterator();
    while (it.next()) |node| {
        const bound = _profile.boundOf(node);
        if (controller != bluetooth.BT_ALL_CONTROLLERS and bound.public.controller != controller) continue;
        if (address) |wanted| {
            if (!_profile.sameAddress(bound.public.address, wanted)) continue;
        }
        end(base, bound, flags);
    }
}

/// One binding ended: off the list, its driver told, its memory freed.
fn end(base: *BluetoothBase, bound: *Bound, flags: u32) void {
    const sys = base.sys_base;
    sys.ObtainSemaphore(&base.binder_lock);
    sys.Remove(&bound.node);
    sys.ReleaseSemaphore(&base.binder_lock);
    drivers.unbind(base, bound.driver, &bound.public, flags);
    sys.FreeVec(bound.services);
    sys.FreeMem(bound, @sizeOf(Bound));
}

/// A line in the log about a device: the binder's name, the controller and
/// the address, most significant first, then `rest`.
fn say(base: *BluetoothBase, comptime format: [:0]const u8, controller: u32, address: bluetooth.BTAddress, rest: anytype) void {
    const bytes = address.bytes;
    const name: [*:0]const u8 = binder_name;
    exec.kprintf(base.sys_base, format, .{ name, controller, @as(u32, bytes[5]), @as(u32, bytes[4]), @as(u32, bytes[3]), @as(u32, bytes[2]), @as(u32, bytes[1]), @as(u32, bytes[0]) } ++ rest);
}
