// SPDX-License-Identifier: MIT
//! A bus: its process, what is plugged into it, and the hubs.
//!
//! **The process** owns the bus. It opens the controller, sets up the
//! root hub - the controller's root port, which answers as a hub - and
//! then waits for hubs to say that a port changed: each hub has an
//! interrupt transfer outstanding on its status endpoint, replied to the
//! process's port. Nothing else changes the bus's devices, so its lists
//! need no lock of their own; the library's list of devices is changed
//! under its semaphore, exclusive, so readers see whole devices.
//!
//! **A device that comes** is found by its hub's port: debounced, reset,
//! its speed taken from the port, asked at address 0 for its first eight
//! bytes (endpoint 0's packet size), given an address, asked for its
//! descriptors, its configuration and its strings, and put in its first
//! configuration. A hub is then the library's own (`hub.zig`'s half
//! here); every other interface is offered to the class drivers
//! (`bind/_bind.zig`).
//!
//! **A device that goes** takes what hangs off it: a hub's children
//! first, then each driver told (USBClassUnbind), then it leaves the list
//! and its address is free again. Addresses are handed out round, so one
//! that was just freed is not given to the next device at once.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const usb = sdk.usb;
const usbhc = sdk.devices.usbhc;
const timer = sdk.devices.timer;
const d = usb.descriptors;
const ExecBase = sdk.interface.exec.ExecBase;
const UsbBase = @import("../usb_base.zig").UsbBase;
const _bind = @import("../bind/_bind.zig");
const _notify = @import("../notify/_notify.zig");

/// The most ports a hub's ports are kept for.
pub const max_ports = 15;
/// A control transfer's limit: a device that NAKs for longer is taken
/// for one that will not answer.
const control_timeout_ms = 1000;

/// A device as the library keeps it: what a program sees first, then
/// what is the library's.
pub const Device = struct {
    public: usb.USBDevice = .{},
    bus: *Bus,
    /// What its strings and configuration are in; freed with it.
    config_memory: ?[*]u8 = null,
    config_size: u32 = 0,
    strings: [3][64]u8 = @splat(@splat(0)),
    /// The language its strings are asked in.
    language: u16 = 0,
    /// Its hub half, if it is one.
    hub: ?*Hub = null,
    /// The hub it hangs off's address and port, for the controller.
    hub_address: u8 = 0,
    hub_port: u8 = 0,
    /// Each interface's binding and the driver that has it.
    bindings: [usb.USB_MAX_INTERFACES]usb.USBBinding = @splat(.{}),
    drivers: [usb.USB_MAX_INTERFACES]?*_bind.Driver = @splat(null),
};

/// A hub's half: its ports, and the transfer that waits for them.
pub const Hub = struct {
    device: *Device,
    ports: u8 = 0,
    /// From a port's power to its being good, in ms.
    power_ms: u32 = 100,
    /// The interrupt transfer on its status endpoint, and its bitmap.
    status: usbhc.IOUsbHC = .{},
    bitmap: [4]u8 = @splat(0),
    /// Whether `status` is out.
    pending: u8 = 0,
    children: [max_ports]?*Device = @splat(null),
};

/// A started bus.
pub const Bus = struct {
    usb_base: *UsbBase,
    number: u32,
    /// The controller: its device's name and unit, and the request it was
    /// opened with.
    hc_name: [*:0]const u8,
    hc_unit: u32,
    hc_io: usbhc.IOUsbHC = .{},
    process: ?*exec.Task = null,
    /// The process's port: control transfers' replies, and the hubs'.
    port: ?*exec.MsgPort = null,
    delay_io: timer.TimeRequest = .{},
    /// The stop, and who waits for it to be done.
    stop_signal: u32 = 0,
    waiter: ?*exec.Task = null,
    waiter_signal: i8 = -1,
    /// What the start came to: 0, or USBERR_*.
    result: i32 = 0,
    /// Addresses in use, a bit each; the next one to try.
    addresses: [4]u32 = .{ 1, 0, 0, 0 },
    next_address: u8 = 1,
    root: ?*Device = null,
};

pub fn deviceOf(public: *usb.USBDevice) *Device {
    return @alignCast(@fieldParentPtr("public", public));
}

// --- the process ------------------------------------------------------------------

/// The bus's process: the controller opened, the root hub set up, then
/// hubs' changes until the bus is stopped.
pub fn busProcess(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const bus: *Bus = @ptrCast(@alignCast(me.user_data.?));
    bus.process = me;
    const stop_bit = sys.AllocSignal(-1);
    bus.port = sys.CreateMsgPort();
    if (stop_bit < 0 or bus.port == null or !openTimer(bus)) {
        bus.result = usb.USBERR_NOMEM;
        return finishStart(bus, stop_bit);
    }
    bus.stop_signal = @as(u32, 1) << @intCast(stop_bit);
    bus.hc_io = .{};
    bus.hc_io.std.req.message.reply_port = bus.port;
    bus.hc_io.std.req.message.length = @sizeOf(usbhc.IOUsbHC);
    if (sys.OpenDevice(bus.hc_name, bus.hc_unit, &bus.hc_io.std.req, 0) != 0) {
        bus.hc_io.std.req.device = null;
        bus.result = usb.USBERR_CONTROLLER;
        return finishStart(bus, stop_bit);
    }
    bus.result = 0;
    told(bus);

    // The root hub, at address 0 until it has one, like any device.
    bus.root = attach(bus, null, 0, usbhc.USB_SPEED_FULL);

    const port_mask = bus.port.?.sigMask();
    while (true) {
        const got = sys.Wait(port_mask | bus.stop_signal);
        if (got & bus.stop_signal != 0) break;
        while (sys.GetMsg(bus.port.?)) |msg| {
            const req: *usbhc.IOUsbHC = @ptrCast(@alignCast(msg));
            const hub: *Hub = @alignCast(@fieldParentPtr("status", req));
            hub.pending = 0;
            hubChanged(bus, hub);
        }
    }

    if (bus.root) |root| detach(bus, root);
    bus.root = null;
    sys.CloseDevice(&bus.hc_io.std.req);
    finishStart(bus, stop_bit);
}

/// The process's end: what it opened let go, and whoever waits told.
fn finishStart(bus: *Bus, stop_bit: i8) void {
    const sys = bus.usb_base.sys_base;
    if (bus.delay_io.node.device != null) sys.CloseDevice(&bus.delay_io.node);
    if (bus.port) |port| sys.DeleteMsgPort(port);
    bus.port = null;
    if (stop_bit >= 0) sys.FreeSignal(stop_bit);
    bus.process = null;
    told(bus);
}

/// Whoever started or stops the bus told that it is done.
fn told(bus: *Bus) void {
    const waiter = bus.waiter orelse return;
    bus.waiter = null;
    bus.usb_base.sys_base.Signal(waiter, @as(u32, 1) << @intCast(bus.waiter_signal));
}

fn openTimer(bus: *Bus) bool {
    bus.delay_io = .{};
    bus.delay_io.node.message.reply_port = bus.port;
    bus.delay_io.node.message.length = @sizeOf(timer.TimeRequest);
    if (bus.usb_base.sys_base.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &bus.delay_io.node, 0) != 0) {
        bus.delay_io.node.device = null;
        return false;
    }
    return true;
}

fn delay(bus: *Bus, ms: u32) void {
    bus.delay_io.node.command = timer.TR_ADDREQUEST;
    bus.delay_io.time = timer.TimeVal.fromMicros(@as(u64, ms) * 1000);
    _ = bus.usb_base.sys_base.DoIO(&bus.delay_io.node);
}

// --- control transfers ------------------------------------------------------------

/// A request for `device`'s endpoint 0, replying to `port`.
pub fn controlRequest(device: *const Device, port: *exec.MsgPort) usbhc.IOUsbHC {
    const bus = device.bus;
    var io = usbhc.IOUsbHC{};
    io.std.req.device = bus.hc_io.std.req.device;
    io.std.req.unit = bus.hc_io.std.req.unit;
    io.std.req.message.reply_port = port;
    io.std.req.message.length = @sizeOf(usbhc.IOUsbHC);
    io.std.req.command = usbhc.UHCMD_CONTROLXFER;
    io.address = device.public.address;
    io.speed = device.public.speed;
    io.max_packet = if (device.public.descriptor.max_packet_size0 != 0) device.public.descriptor.max_packet_size0 else 8;
    io.hub_address = device.hub_address;
    io.hub_port = device.hub_port;
    io.nak_timeout = control_timeout_ms;
    return io;
}

/// A control transfer to `device`, replied to `port`: io_Error, and the
/// bytes moved in `actual`.
pub fn controlOn(sys: *ExecBase, device: *const Device, port: *exec.MsgPort, setup: d.SetupPacket, data: ?*anyopaque, actual: ?*u32) i8 {
    var io = controlRequest(device, port);
    io.setup = setup;
    io.std.data = data;
    io.std.length = setup.length;
    _ = sys.DoIO(&io.std.req);
    if (actual) |into| into.* = @intCast(io.std.actual);
    return io.std.req.err;
}

/// A control transfer on the bus's process.
fn control(bus: *Bus, device: *const Device, setup: d.SetupPacket, data: ?*anyopaque, actual: ?*u32) i8 {
    return controlOn(bus.usb_base.sys_base, device, bus.port.?, setup, data, actual);
}

fn setupPacket(request_type: u8, request: u8, value: u16, index: u16, length: u16) d.SetupPacket {
    return .{ .request_type = request_type, .request = request, .value = value, .index = index, .length = length };
}

fn getDescriptor(bus: *Bus, device: *const Device, kind: u8, index: u8, language: u16, into: []u8) ?u32 {
    var got: u32 = 0;
    const setup = setupPacket(d.USB_DIR_IN, d.USB_REQ_GET_DESCRIPTOR, (@as(u16, kind) << 8) | index, language, @intCast(into.len));
    if (control(bus, device, setup, into.ptr, &got) != 0) return null;
    return got;
}

// --- addresses --------------------------------------------------------------------

fn allocAddress(bus: *Bus) ?u8 {
    var tries: u32 = 0;
    while (tries < 127) : (tries += 1) {
        const address = bus.next_address;
        bus.next_address = if (address >= 127) 1 else address + 1;
        const word = address / 32;
        const bit = @as(u32, 1) << @intCast(address % 32);
        if (bus.addresses[word] & bit != 0) continue;
        bus.addresses[word] |= bit;
        return address;
    }
    return null;
}

fn freeAddress(bus: *Bus, address: u8) void {
    if (address == 0) return;
    bus.addresses[address / 32] &= ~(@as(u32, 1) << @intCast(address % 32));
}

// --- a device coming and going ----------------------------------------------------

/// What was plugged into `parent`'s `port` (null, 0: the root hub), at
/// `speed`, set up and offered to its drivers; null if it could not be
/// spoken to at all.
pub fn attach(bus: *Bus, parent: ?*Hub, port: u8, speed: u8) ?*Device {
    const base = bus.usb_base;
    const sys = base.sys_base;
    const memory = sys.AllocMem(@sizeOf(Device), exec.MEMF_CLEAR) orelse return null;
    const device: *Device = @ptrCast(@alignCast(memory));
    device.* = .{ .bus = bus };
    device.public.bus = bus.number;
    device.public.speed = speed;
    device.public.port = port;
    if (parent) |hub| {
        device.public.hub = &hub.device.public;
        device.public.depth = hub.device.public.depth + 1;
        device.hub_address = hub.device.public.address;
        device.hub_port = port;
    }
    device.public.descriptor.max_packet_size0 = if (speed == usbhc.USB_SPEED_LOW) 8 else 64;

    // Endpoint 0's packet size, at address 0: eight bytes are enough,
    // and every device sends them.
    var first: [8]u8 = undefined;
    const first_got = getDescriptor(bus, device, d.USB_DT_DEVICE, 0, 0, &first) orelse 0;
    if (first_got < 8 or first[7] == 0) {
        sys.FreeMem(memory, @sizeOf(Device));
        return null;
    }
    device.public.descriptor.max_packet_size0 = first[7];

    const address = allocAddress(bus) orelse {
        sys.FreeMem(memory, @sizeOf(Device));
        return null;
    };
    if (control(bus, device, setupPacket(d.USB_DIR_OUT, d.USB_REQ_SET_ADDRESS, address, 0, 0), null, null) != 0) {
        freeAddress(bus, address);
        sys.FreeMem(memory, @sizeOf(Device));
        return null;
    }
    device.public.address = address;
    // The device's two milliseconds to take its address.
    delay(bus, 2);

    if (!setUp(bus, device)) device.public.flags |= usb.USBDF_FAILED;
    device.public.node = .{ .type = .unknown, .name = if (device.strings[1][0] != 0) @ptrCast(&device.strings[1]) else null };

    sys.ObtainSemaphore(&base.devices_lock);
    sys.AddTail(&base.devices, &device.public.node);
    sys.ReleaseSemaphore(&base.devices_lock);
    _notify.changed(base);

    if (device.public.flags & usb.USBDF_FAILED != 0) return device;
    if (isHub(device)) {
        hubSetUp(bus, device);
    } else {
        bindAll(bus, device);
    }
    return device;
}

/// The device's descriptors, configuration and strings read, and its
/// first configuration set. False if it did not answer.
fn setUp(bus: *Bus, device: *Device) bool {
    const sys = bus.usb_base.sys_base;
    const descriptor_bytes: *[@sizeOf(d.DeviceDescriptor)]u8 = @ptrCast(&device.public.descriptor);
    const got = getDescriptor(bus, device, d.USB_DT_DEVICE, 0, 0, descriptor_bytes) orelse return false;
    if (got < @sizeOf(d.DeviceDescriptor)) return false;

    var head: [@sizeOf(d.ConfigDescriptor)]u8 = undefined;
    const head_got = getDescriptor(bus, device, d.USB_DT_CONFIG, 0, 0, &head) orelse return false;
    if (head_got < head.len) return false;
    const config_head: *align(1) const d.ConfigDescriptor = @ptrCast(&head);
    const total: u32 = @max(config_head.total_length, @sizeOf(d.ConfigDescriptor));
    const config_memory = sys.AllocMem(total, exec.MEMF_CLEAR) orelse return false;
    device.config_memory = @ptrCast(config_memory);
    device.config_size = total;
    const config_got = getDescriptor(bus, device, d.USB_DT_CONFIG, 0, 0, device.config_memory.?[0..total]) orelse return false;
    device.public.config = device.config_memory;
    device.public.config_length = config_got;

    readStrings(bus, device);

    if (control(bus, device, setupPacket(d.USB_DIR_OUT, d.USB_REQ_SET_CONFIGURATION, config_head.configuration_value, 0, 0), null, null) != 0) return false;
    device.public.flags |= usb.USBDF_CONFIGURED;
    return true;
}

/// The device's language and its three strings, as far as Latin-1 holds
/// them.
fn readStrings(bus: *Bus, device: *Device) void {
    var languages: [4]u8 = undefined;
    const got = getDescriptor(bus, device, d.USB_DT_STRING, 0, 0, &languages) orelse return;
    if (got < 4) return;
    device.language = @as(u16, languages[2]) | @as(u16, languages[3]) << 8;
    const indices = [3]u8{
        device.public.descriptor.manufacturer_string,
        device.public.descriptor.product_string,
        device.public.descriptor.serial_string,
    };
    for (indices, 0..) |index, slot| {
        if (index == 0) continue;
        _ = readString(bus.usb_base.sys_base, device, bus.port.?, index, &device.strings[slot]);
    }
    device.public.manufacturer = if (device.strings[0][0] != 0) @ptrCast(&device.strings[0]) else null;
    device.public.product = if (device.strings[1][0] != 0) @ptrCast(&device.strings[1]) else null;
    device.public.serial = if (device.strings[2][0] != 0) @ptrCast(&device.strings[2]) else null;
}

/// String `index` of the device as Latin-1 into `into`, NUL-ended: its
/// length, or null if the device has none. Replies to `port`.
pub fn readString(sys: *ExecBase, device: *const Device, port: *exec.MsgPort, index: u8, into: []u8) ?u32 {
    if (into.len == 0) return null;
    var raw: [255]u8 = undefined;
    var got: u32 = 0;
    const setup = setupPacket(d.USB_DIR_IN, d.USB_REQ_GET_DESCRIPTOR, (@as(u16, d.USB_DT_STRING) << 8) | index, device.language, raw.len);
    if (controlOn(sys, device, port, setup, &raw, &got) != 0 or got < 2) return null;
    const length = @min(got, raw[0]);
    var count: u32 = 0;
    var at: u32 = 2;
    while (at + 1 < length and count + 1 < into.len) : (at += 2) {
        const char = @as(u16, raw[at]) | @as(u16, raw[at + 1]) << 8;
        into[count] = if (char < 0x100) @truncate(char) else '?';
        count += 1;
    }
    into[count] = 0;
    return count;
}

fn isHub(device: *const Device) bool {
    if (device.public.descriptor.device_class == d.USB_CLASS_HUB) return true;
    const first = firstInterface(device) orelse return false;
    return first.interface_class == d.USB_CLASS_HUB;
}

/// The descriptor after `offset` in the device's configuration of
/// `kind`, and where it is.
pub fn nextDescriptor(device: *const Device, offset: u32, kind: u8) ?u32 {
    const config = device.public.config orelse return null;
    var at = offset;
    if (at == 0) {
        at = config[0];
    } else {
        at += config[at];
    }
    while (at + 2 <= device.public.config_length) {
        const length = config[at];
        if (length < 2 or at + length > device.public.config_length) return null;
        if (kind == 0 or config[at + 1] == kind) return at;
        at += length;
    }
    return null;
}

fn firstInterface(device: *const Device) ?*align(1) const d.InterfaceDescriptor {
    const at = nextDescriptor(device, 0, d.USB_DT_INTERFACE) orelse return null;
    return @ptrCast(device.public.config.? + at);
}

/// Each interface's first setting offered to the class drivers.
fn bindAll(bus: *Bus, device: *Device) void {
    const base = bus.usb_base;
    var at: u32 = 0;
    while (nextDescriptor(device, at, d.USB_DT_INTERFACE)) |found| : (at = found) {
        const interface: *const d.InterfaceDescriptor = @ptrCast(@alignCast(device.public.config.? + found));
        if (interface.alternate_setting != 0) continue;
        const number = interface.interface_number;
        if (number >= usb.USB_MAX_INTERFACES) continue;
        if (device.public.drivers[number] != null) continue;
        device.bindings[number] = .{ .device = &device.public, .interface = interface };
        if (_bind.offer(base, &device.bindings[number])) |driver| {
            device.drivers[number] = driver;
            device.public.drivers[number] = @ptrCast(&driver.name);
            _notify.changed(base);
        }
    }
}

/// Every driver of the device told it is gone.
fn unbindAll(bus: *Bus, device: *Device) void {
    for (&device.drivers, 0..) |*slot, number| {
        const driver = slot.* orelse continue;
        _bind.unbind(bus.usb_base, driver, &device.bindings[number]);
        slot.* = null;
        device.public.drivers[number] = null;
    }
}

/// A device gone, and everything that hung off it.
pub fn detach(bus: *Bus, device: *Device) void {
    const base = bus.usb_base;
    const sys = base.sys_base;
    if (device.hub) |hub| {
        if (hub.pending != 0) {
            _ = sys.AbortIO(&hub.status.std.req);
            _ = sys.WaitIO(&hub.status.std.req);
            hub.pending = 0;
        }
        for (&hub.children) |*child| {
            if (child.*) |gone| detach(bus, gone);
            child.* = null;
        }
        sys.FreeMem(hub, @sizeOf(Hub));
        device.hub = null;
    }
    unbindAll(bus, device);
    sys.ObtainSemaphore(&base.devices_lock);
    sys.Remove(&device.public.node);
    sys.ReleaseSemaphore(&base.devices_lock);
    freeAddress(bus, device.public.address);
    if (device.config_memory) |config| sys.FreeMem(config, device.config_size);
    sys.FreeMem(device, @sizeOf(Device));
    _notify.changed(base);
}

// --- hubs -------------------------------------------------------------------------

fn hubRequest(bus: *Bus, hub: *Hub, request_type: u8, request: u8, value: u16, port: u8, data: ?*anyopaque, length: u16) i8 {
    return control(bus, hub.device, setupPacket(request_type, request, value, port, length), data, null);
}

fn portStatus(bus: *Bus, hub: *Hub, port: u8) ?d.PortStatus {
    var status: d.PortStatus = .{};
    if (hubRequest(bus, hub, d.USB_DIR_IN | d.USB_RT_PORT, d.USB_REQ_GET_STATUS, 0, port, &status, 4) != 0) return null;
    return status;
}

fn setPortFeature(bus: *Bus, hub: *Hub, port: u8, feature: u16) i8 {
    return hubRequest(bus, hub, d.USB_DIR_OUT | d.USB_RT_PORT, d.USB_REQ_SET_FEATURE, feature, port, null, 0);
}

fn clearPortFeature(bus: *Bus, hub: *Hub, port: u8, feature: u16) i8 {
    return hubRequest(bus, hub, d.USB_DIR_OUT | d.USB_RT_PORT, d.USB_REQ_CLEAR_FEATURE, feature, port, null, 0);
}

/// A hub made the library's: its descriptor read, its ports powered,
/// what is already plugged in found, and its status transfer sent.
fn hubSetUp(bus: *Bus, device: *Device) void {
    const sys = bus.usb_base.sys_base;
    const memory = sys.AllocMem(@sizeOf(Hub), exec.MEMF_CLEAR) orelse return;
    const hub: *Hub = @ptrCast(@alignCast(memory));
    hub.* = .{ .device = device };
    device.hub = hub;
    device.public.flags |= usb.USBDF_HUB;
    device.public.drivers[0] = "usb.library";

    var descriptor: d.HubDescriptor = .{};
    const descriptor_bytes: *[@sizeOf(d.HubDescriptor)]u8 = @ptrCast(&descriptor);
    if (hubRequest(bus, hub, d.USB_DIR_IN | d.USB_RT_HUB, d.USB_REQ_GET_DESCRIPTOR, @as(u16, d.USB_DT_HUB) << 8, 0, descriptor_bytes, @sizeOf(d.HubDescriptor)) != 0) return;
    hub.ports = @min(descriptor.num_ports, max_ports);
    hub.power_ms = @max(@as(u32, descriptor.power_on_to_good) * 2, 20);

    var port: u8 = 1;
    while (port <= hub.ports) : (port += 1) _ = setPortFeature(bus, hub, port, d.USB_PORT_FEAT_POWER);
    delay(bus, hub.power_ms);

    port = 1;
    while (port <= hub.ports) : (port += 1) portChanged(bus, hub, port);

    // The status endpoint: the hub interface's interrupt IN.
    const config = device.public.config orelse return;
    var at: u32 = 0;
    while (nextDescriptor(device, at, d.USB_DT_ENDPOINT)) |found| : (at = found) {
        const endpoint: *align(1) const d.EndpointDescriptor = @ptrCast(config + found);
        if (endpoint.endpoint_address & d.USB_DIR_IN == 0) continue;
        if (endpoint.attributes & d.USB_ENDPOINT_XFERTYPE_MASK != d.USB_ENDPOINT_XFER_INT) continue;
        var io = controlRequest(device, bus.port.?);
        io.std.req.command = usbhc.UHCMD_INTXFER;
        io.endpoint = endpoint.endpoint_address;
        io.max_packet = @max(endpoint.max_packet_size & 0x7FF, 1);
        io.interval = @max(endpoint.interval, 1);
        io.nak_timeout = 0;
        hub.status = io;
        sendStatus(bus, hub);
        return;
    }
}

fn sendStatus(bus: *Bus, hub: *Hub) void {
    hub.bitmap = @splat(0);
    hub.status.std.data = &hub.bitmap;
    hub.status.std.length = @min((@as(u32, hub.ports) + 8) / 8, hub.bitmap.len);
    hub.pending = 1;
    bus.usb_base.sys_base.SendIO(&hub.status.std.req);
}

/// A hub's status transfer came back: each port it names looked at, and
/// the transfer sent again.
fn hubChanged(bus: *Bus, hub: *Hub) void {
    const err = hub.status.std.req.err;
    if (err == usbhc.UHIOERR_DETACHED or err == exec.IOERR_ABORTED) return;
    if (err == 0) {
        var port: u8 = 1;
        while (port <= hub.ports) : (port += 1) {
            if (hub.bitmap[port / 8] & (@as(u8, 1) << @intCast(port % 8)) != 0) portChanged(bus, hub, port);
        }
    } else {
        // A transfer that failed is tried again after a breath, rather
        // than at once and for ever.
        delay(bus, 100);
    }
    sendStatus(bus, hub);
}

/// One port of a hub looked at: its changes cleared, and what was plugged
/// in or pulled out dealt with.
fn portChanged(bus: *Bus, hub: *Hub, port: u8) void {
    const status = portStatus(bus, hub, port) orelse return;
    const change = status.change;
    if (change & d.USB_PORT_STAT_C_ENABLE != 0) _ = clearPortFeature(bus, hub, port, d.USB_PORT_FEAT_C_ENABLE);
    if (change & d.USB_PORT_STAT_C_SUSPEND != 0) _ = clearPortFeature(bus, hub, port, d.USB_PORT_FEAT_C_SUSPEND);
    if (change & d.USB_PORT_STAT_C_OVERCURRENT != 0) _ = clearPortFeature(bus, hub, port, d.USB_PORT_FEAT_C_OVER_CURRENT);
    if (change & d.USB_PORT_STAT_C_RESET != 0) _ = clearPortFeature(bus, hub, port, d.USB_PORT_FEAT_C_RESET);
    const connection_changed = change & d.USB_PORT_STAT_C_CONNECTION != 0;
    if (connection_changed) _ = clearPortFeature(bus, hub, port, d.USB_PORT_FEAT_C_CONNECTION);
    const child = hub.children[port - 1];
    if (child != null and (connection_changed or status.status & d.USB_PORT_STAT_CONNECTION == 0)) {
        detach(bus, child.?);
        hub.children[port - 1] = null;
    }
    if (hub.children[port - 1] == null and status.status & d.USB_PORT_STAT_CONNECTION != 0) {
        connect(bus, hub, port);
    }
}

/// Something plugged into a port: debounced, reset, set up.
fn connect(bus: *Bus, hub: *Hub, port: u8) void {
    delay(bus, 100);
    var status = portStatus(bus, hub, port) orelse return;
    if (status.status & d.USB_PORT_STAT_CONNECTION == 0) return;
    if (setPortFeature(bus, hub, port, d.USB_PORT_FEAT_RESET) != 0) return;
    var waited: u32 = 0;
    while (waited < 500) : (waited += 10) {
        delay(bus, 10);
        status = portStatus(bus, hub, port) orelse return;
        if (status.change & d.USB_PORT_STAT_C_RESET != 0 or status.status & d.USB_PORT_STAT_RESET == 0) break;
    }
    _ = clearPortFeature(bus, hub, port, d.USB_PORT_FEAT_C_RESET);
    if (status.status & d.USB_PORT_STAT_ENABLE == 0) return;
    const speed: u8 = if (status.status & d.USB_PORT_STAT_LOW_SPEED != 0)
        usbhc.USB_SPEED_LOW
    else if (status.status & d.USB_PORT_STAT_HIGH_SPEED != 0)
        usbhc.USB_SPEED_HIGH
    else
        usbhc.USB_SPEED_FULL;
    // The device's ten milliseconds to recover from the reset.
    delay(bus, 10);
    hub.children[port - 1] = attach(bus, hub, port, speed);
}
