// SPDX-License-Identifier: MIT
//! A host controller for host tests: a device speaking `DEVIF_USBHC` as a
//! script says, at once - no wires, and no time but what it counts. A test
//! opens unit 0 into a bus's `hc_io` and unit 1, the clock, into its
//! `delay_io`; the bus's control transfers and the pipes usb.library makes
//! on it come here.
//!
//! **The functions** are the script's devices: the root hub, there from
//! the start as a controller's root port is, and devices and hubs hanging
//! off a hub's port, plugged in and pulled out by the test (`plug`,
//! `pull`). A control transfer goes to the function with its address that
//! can be reached - plugged in, below hubs whose ports are enabled -
//! address 0 to the one not yet given one; nothing there is
//! UHIOERR_TIMEOUT. A function answers the standard descriptors, its
//! address and its configuration, and a hub its own descriptor and its
//! ports' status and features - a reset is done at once, the port enabled
//! at the function's speed. Anything else stalls, as does the one request
//! the script names, and a function the script says goes in the middle is
//! pulled after that many control transfers.
//!
//! **A hub's status transfer** (UHCMD_INTXFER) is answered when a port of
//! it has a change, at once or when one comes, its bitmap a bit per such
//! port; a hub pulled answers a held one UHIOERR_DETACHED after its own
//! hub's change is out, so the bus finds it replied when it takes the hub
//! down. AbortIO answers a held one IOERR_ABORTED.
//!
//! **The clock** answers TR_ADDREQUEST at once and adds the time up.
//!
//! **The stream's packets** are numbered from 0 across its transfers, as
//! they come. A packet the script names lost comes back UHIOERR_MISSED
//! with nothing moved; the rest go whole - an OUT packet's bytes kept in
//! `sent`, one after the other, an IN packet filled with the low byte of
//! its number, `short_bytes` long where the script says it comes short.
//!
//! **The frames**: each transfer starts in the frame after the one before
//! it ended, its packets `interval` frames apart. One the script puts a
//! gap before starts that many frames later and says so in `iso_gap`, as
//! a controller whose ring ran dry does; one with `UHF_ISO_FRAME` starts
//! in the frame it asks for. UHCMD_QUERYDEVICE answers the frame now.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const usbhc = sdk.devices.usbhc;
const timer = sdk.devices.timer;
const d = sdk.usb.descriptors;
const ExecBase = sdk.interface.exec.ExecBase;

pub const NAME = "hcstandin.device";
/// The unit that is the bus's clock.
pub const CLOCK_UNIT = 1;

/// No transfer or packet: the script says nothing of one.
pub const none = std.math.maxInt(u32);

/// The most functions a script has, and ports a hub of it has.
pub const max_functions = 8;
pub const max_ports = 4;
/// The root hub's index.
pub const root: u8 = 0;
/// No request stalled.
pub const no_request: u8 = 0xFF;

/// A device of the script.
pub const Function = extern struct {
    /// In the script, and plugged in.
    used: bool = false,
    present: bool = false,
    /// The hub it hangs off and the port: the root hub's mean nothing.
    parent: u8 = 0,
    port: u8 = 0,
    speed: u8 = usbhc.USB_SPEED_FULL,
    /// What the bus made of it: its address, the configuration it set.
    address: u8 = 0,
    configuration: u8 = 0,
    descriptor: d.DeviceDescriptor = .{},
    config: [32]u8 = @splat(0),
    config_length: u8 = 0,
    /// Strings 1 to 3, sent as UTF-16; an empty one stalls.
    strings: [3][16]u8 = @splat(@splat(0)),
    /// A hub's ports: each one's wPortStatus and wPortChange.
    ports: u8 = 0,
    port_status: [max_ports]u16 = @splat(0),
    port_change: [max_ports]u16 = @splat(0),
    /// Its status transfer, held while no port changed.
    held: ?*usbhc.IOUsbHC = null,
    /// The script: the request it stalls - bRequest, and for
    /// GET_DESCRIPTOR the descriptor's type - and the control transfers
    /// it answers before it is pulled.
    stall_request: u8 = no_request,
    stall_kind: u8 = 0,
    pull_after: u32 = none,
    /// The control transfers it answered.
    transfers: u32 = 0,
};

pub const HC = extern struct {
    dev: exec.Device,
    sys: *ExecBase,
    unit: exec.Unit = .{},
    /// The frame the next transfer starts in, and the stream's packets and
    /// transfers so far.
    frame: u32 = 100,
    packets: u32 = 0,
    transfers: u32 = 0,
    /// The script: a bit per packet of the stream's first 64 that is
    /// lost; the transfer a gap of `gap` frames comes before; the packet
    /// that comes short, with `short_bytes`.
    lost: u64 = 0,
    gap_before: u32 = none,
    gap: u16 = 0,
    short_packet: u32 = none,
    short_bytes: u16 = 0,
    /// What the OUT packets brought, one after the other, as much as fits.
    sent: [4096]u8 = @splat(0),
    sent_length: u32 = 0,
    /// The clock: its unit, and the time asked of it, in microseconds.
    clock_unit: exec.Unit = .{},
    clock: u64 = 0,
    functions: [max_functions]Function = @splat(.{}),
};

pub fn hcOf(dev: *exec.Device) *HC {
    return @fieldParentPtr("dev", dev);
}

fn hcInit(dev: *exec.Device, _: ?*anyopaque, sys: *ExecBase) callconv(.c) ?*exec.Device {
    const hc = hcOf(dev);
    const header = dev.*;
    hc.* = .{ .dev = header, .sys = sys };
    return dev;
}

fn hcOpen(dev: *exec.Device, io: *exec.IORequest, unit: u32, _: u32) callconv(.c) i32 {
    io.unit = switch (unit) {
        0 => &hcOf(dev).unit,
        CLOCK_UNIT => &hcOf(dev).clock_unit,
        else => return exec.IOERR_OPENFAIL,
    };
    dev.open_cnt += 1;
    return 0;
}

fn hcClose(dev: *exec.Device, io: *exec.IORequest) callconv(.c) ?*anyopaque {
    io.unit = null;
    dev.open_cnt -= 1;
    return null;
}

fn hcExpunge(dev: *exec.Device) callconv(.c) ?*anyopaque {
    const sys = hcOf(dev).sys;
    sys.DetachLibrary(dev);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(dev) - dev.neg_size);
    sys.FreeMem(start, @as(usize, dev.neg_size) + dev.pos_size);
    return null;
}

fn hcBeginIO(dev: *exec.Device, request: *exec.IORequest) callconv(.c) void {
    const hc = hcOf(dev);
    if (request.unit == &hc.clock_unit) {
        request.err = wait(hc, @ptrCast(@alignCast(request)));
    } else {
        const req: *usbhc.IOUsbHC = @ptrCast(@alignCast(request));
        request.err = serve(hc, req) orelse {
            // Held: answered when a port changes.
            request.flags &= ~exec.IOF_QUICK;
            return;
        };
    }
    if (request.flags & exec.IOF_QUICK == 0) hc.sys.ReplyMsg(&request.message);
}

fn hcAbortIO(dev: *exec.Device, request: *exec.IORequest) callconv(.c) i32 {
    const hc = hcOf(dev);
    for (&hc.functions) |*function| {
        const held = function.held orelse continue;
        if (&held.std.req != request) continue;
        function.held = null;
        request.err = exec.IOERR_ABORTED;
        hc.sys.ReplyMsg(&request.message);
    }
    return 0;
}

/// The clock's one command.
fn wait(hc: *HC, request: *timer.TimeRequest) i8 {
    if (request.node.command != timer.TR_ADDREQUEST) return exec.IOERR_NOCMD;
    hc.clock += request.time.toMicros();
    request.time = .{};
    return 0;
}

/// A request's answer, or null when it is held.
fn serve(hc: *HC, req: *usbhc.IOUsbHC) ?i8 {
    req.std.actual = 0;
    switch (req.std.req.command) {
        usbhc.UHCMD_ISOXFER => return transfer(hc, req),
        usbhc.UHCMD_CONTROLXFER => return control(hc, req),
        usbhc.UHCMD_INTXFER => return status(hc, req),
        usbhc.UHCMD_QUERYDEVICE => {
            const info: *usbhc.USBHCInfo = @ptrCast(@alignCast(req.std.data.?));
            info.* = .{ .name = "standin", .speed = usbhc.USB_SPEED_FULL, .channels = 4, .ports = 1, .frame = hc.frame & (usbhc.UHC_FRAMES - 1) };
            req.std.actual = @sizeOf(usbhc.USBHCInfo);
            return 0;
        },
        else => return exec.IOERR_NOCMD,
    }
}

/// An isochronous transfer as the script says, at once.
fn transfer(hc: *HC, req: *usbhc.IOUsbHC) i8 {
    const length: u32 = @intCast(req.std.length);
    const packet = if (req.iso_packet != 0) req.iso_packet else req.max_packet;
    const count: u32 = if (req.iso_list != null) req.iso_count else (length + packet - 1) / packet;
    if (count == 0 or count > usbhc.UHC_ISO_PACKETS) return exec.IOERR_BADLENGTH;
    const data: [*]u8 = @ptrCast(req.std.data.?);
    const in = req.endpoint & 0x80 != 0;

    var gap: u32 = if (hc.transfers == hc.gap_before) hc.gap else 0;
    if (req.flags & usbhc.UHF_ISO_FRAME != 0) {
        const ahead = (@as(u32, req.iso_frame) -% hc.frame) & (usbhc.UHC_FRAMES - 1);
        if (ahead > usbhc.UHC_ISO_AHEAD) return usbhc.UHIOERR_MISSED;
        gap = ahead;
    }
    hc.frame +%= gap;
    req.iso_frame = @truncate(hc.frame & (usbhc.UHC_FRAMES - 1));
    req.iso_gap = @truncate(gap);
    req.iso_lost = 0;

    var offset: u32 = 0;
    var n: u32 = 0;
    while (n < count) : (n += 1) {
        const number = hc.packets + n;
        const asked: u32 = if (req.iso_list) |list| list[n].length else @min(packet, length - n * packet);
        const lost = number < 64 and hc.lost & (@as(u64, 1) << @intCast(number)) != 0;
        const got: u32 = if (lost) 0 else if (number == hc.short_packet) @min(hc.short_bytes, asked) else asked;
        if (req.iso_list) |list| {
            list[n].actual = @truncate(got);
            list[n].status = if (lost) usbhc.UHIOERR_MISSED else 0;
        }
        if (lost) req.iso_lost += 1;
        if (in) {
            @memset(data[offset..][0..got], @truncate(number));
        } else {
            const kept = @min(got, hc.sent.len - hc.sent_length);
            @memcpy(hc.sent[hc.sent_length..][0..kept], data[offset..][0..kept]);
            hc.sent_length += kept;
        }
        req.std.actual += got;
        offset += asked;
    }
    hc.packets += count;
    hc.transfers += 1;
    hc.frame +%= count * @max(req.interval, 1);
    return 0;
}

// --- the script --------------------------------------------------------------

/// The root hub, with `ports` ports, plugged in.
pub fn addRoot(hc: *HC, ports: u8) u8 {
    const index = add(hc, root, 0, usbhc.USB_SPEED_FULL, 0, 0, d.USB_CLASS_HUB, .{ "", "", "" });
    hc.functions[index].ports = ports;
    hc.functions[index].present = true;
    return index;
}

/// A hub of `ports` ports on `parent`'s `port`, not plugged in yet.
pub fn addHub(hc: *HC, parent: u8, port: u8, speed: u8, ports: u8) u8 {
    const index = add(hc, parent, port, speed, 0x05E3, 0x0608, d.USB_CLASS_HUB, .{ "", "Hub", "" });
    hc.functions[index].ports = ports;
    return index;
}

/// A device with one interface of `class` on `parent`'s `port`, not
/// plugged in yet; its strings the manufacturer, product and serial.
pub fn addDevice(hc: *HC, parent: u8, port: u8, speed: u8, vendor: u16, product: u16, class: u8, strings: [3][]const u8) u8 {
    return add(hc, parent, port, speed, vendor, product, class, strings);
}

fn add(hc: *HC, parent: u8, port: u8, speed: u8, vendor: u16, product: u16, class: u8, strings: [3][]const u8) u8 {
    var index: u8 = 0;
    while (hc.functions[index].used) index += 1;
    const function = &hc.functions[index];
    function.* = .{ .used = true, .parent = parent, .port = port, .speed = speed };
    const hub = class == d.USB_CLASS_HUB;
    function.descriptor = .{
        .bcd_usb = 0x0200,
        .device_class = if (hub) d.USB_CLASS_HUB else 0,
        .max_packet_size0 = if (speed == usbhc.USB_SPEED_LOW) 8 else 64,
        .vendor_id = vendor,
        .product_id = product,
        .num_configurations = 1,
    };
    for (strings, 0..) |string, slot| {
        @memcpy(function.strings[slot][0..string.len], string);
    }
    if (strings[0].len != 0) function.descriptor.manufacturer_string = 1;
    if (strings[1].len != 0) function.descriptor.product_string = 2;
    if (strings[2].len != 0) function.descriptor.serial_string = 3;
    // A configuration, an interface of the class, its interrupt IN.
    const config = [_]u8{
        9, d.USB_DT_CONFIG,    25,   0,                       1,                 1,     0,                   0x80, 50,
        9, d.USB_DT_INTERFACE, 0,    0,                       1,                 class, 0,                   0,    0,
        7, d.USB_DT_ENDPOINT,  0x81, d.USB_ENDPOINT_XFER_INT, if (hub) 1 else 8, 0,     if (hub) 12 else 10,
    };
    @memcpy(function.config[0..config.len], &config);
    function.config_length = config.len;
    return index;
}

/// Function `index` plugged into its port.
pub fn plug(hc: *HC, index: u8) void {
    const function = &hc.functions[index];
    function.present = true;
    function.address = 0;
    function.configuration = 0;
    function.transfers = 0;
    const hub = &hc.functions[function.parent];
    hub.port_status[function.port - 1] |= d.USB_PORT_STAT_CONNECTION;
    hub.port_change[function.port - 1] |= d.USB_PORT_STAT_C_CONNECTION;
    changed(hc, function.parent);
}

/// Function `index` pulled out of its port, and with it what hangs off it.
pub fn pull(hc: *HC, index: u8) void {
    const function = &hc.functions[index];
    function.present = false;
    const hub = &hc.functions[function.parent];
    hub.port_status[function.port - 1] &= ~(d.USB_PORT_STAT_CONNECTION | d.USB_PORT_STAT_ENABLE | d.USB_PORT_STAT_LOW_SPEED | d.USB_PORT_STAT_HIGH_SPEED);
    hub.port_change[function.port - 1] |= d.USB_PORT_STAT_C_CONNECTION;
    changed(hc, function.parent);
    // The status transfers of the hubs gone with it end, after the change
    // that says they went.
    for (&hc.functions, 0..) |*gone, at| {
        const held = gone.held orelse continue;
        if (reachable(hc, @intCast(at))) continue;
        gone.held = null;
        held.std.req.err = usbhc.UHIOERR_DETACHED;
        hc.sys.ReplyMsg(&held.std.req.message);
    }
}

/// Whether function `index` can be spoken to: plugged in, and every hub
/// above it plugged in with that port enabled.
pub fn reachable(hc: *const HC, index: u8) bool {
    var at = index;
    while (true) {
        const function = &hc.functions[at];
        if (!function.used or !function.present) return false;
        if (at == root) return true;
        const hub = &hc.functions[function.parent];
        if (hub.port_status[function.port - 1] & d.USB_PORT_STAT_ENABLE == 0) return false;
        at = function.parent;
    }
}

/// The function at `address` that can be spoken to.
fn reached(hc: *HC, address: u8) ?u8 {
    var index: u8 = 0;
    while (index < max_functions) : (index += 1) {
        if (reachable(hc, index) and hc.functions[index].address == address) return index;
    }
    return null;
}

/// A hub's held status transfer answered, if a port of it changed.
fn changed(hc: *HC, index: u8) void {
    const function = &hc.functions[index];
    const held = function.held orelse return;
    if (!reachable(hc, index)) return;
    held.std.req.err = bitmap(function, held) orelse return;
    function.held = null;
    hc.sys.ReplyMsg(&held.std.req.message);
}

/// A hub's status: a bit per port that changed, or null for none.
fn bitmap(function: *const Function, req: *usbhc.IOUsbHC) ?i8 {
    const length: u32 = @intCast(req.std.length);
    const data: [*]u8 = @ptrCast(req.std.data.?);
    @memset(data[0..length], 0);
    var any = false;
    var port: u8 = 1;
    while (port <= function.ports) : (port += 1) {
        if (function.port_change[port - 1] == 0 or port / 8 >= length) continue;
        data[port / 8] |= @as(u8, 1) << @intCast(port % 8);
        any = true;
    }
    if (!any) return null;
    req.std.actual = length;
    return 0;
}

/// A hub's status transfer: answered if a port changed, else held.
fn status(hc: *HC, req: *usbhc.IOUsbHC) ?i8 {
    const index = reached(hc, req.address) orelse return usbhc.UHIOERR_DETACHED;
    const function = &hc.functions[index];
    if (function.ports == 0) return usbhc.UHIOERR_STALL;
    if (bitmap(function, req)) |result| return result;
    function.held = req;
    return null;
}

/// A control transfer to the function at its address.
fn control(hc: *HC, req: *usbhc.IOUsbHC) i8 {
    const index = reached(hc, req.address) orelse return usbhc.UHIOERR_TIMEOUT;
    const function = &hc.functions[index];
    function.transfers += 1;
    defer if (function.transfers == function.pull_after) pull(hc, index);
    const setup = req.setup;
    if (setup.request == function.stall_request and (setup.request != d.USB_REQ_GET_DESCRIPTOR or setup.value >> 8 == function.stall_kind)) return usbhc.UHIOERR_STALL;
    const port: u8 = @truncate(setup.index);
    const is_port = port >= 1 and port <= function.ports;
    switch (setup.request_type) {
        d.USB_DIR_IN => {
            if (setup.request != d.USB_REQ_GET_DESCRIPTOR) return usbhc.UHIOERR_STALL;
            return descriptor(function, req, @truncate(setup.value >> 8), @truncate(setup.value));
        },
        d.USB_DIR_OUT => switch (setup.request) {
            d.USB_REQ_SET_ADDRESS => function.address = @truncate(setup.value),
            d.USB_REQ_SET_CONFIGURATION => function.configuration = @truncate(setup.value),
            else => return usbhc.UHIOERR_STALL,
        },
        d.USB_DIR_IN | d.USB_RT_HUB => {
            if (function.ports == 0 or setup.request != d.USB_REQ_GET_DESCRIPTOR) return usbhc.UHIOERR_STALL;
            const hub = d.HubDescriptor{ .num_ports = function.ports, .power_on_to_good = 50 };
            return answer(req, std.mem.asBytes(&hub));
        },
        d.USB_DIR_IN | d.USB_RT_PORT => {
            if (!is_port or setup.request != d.USB_REQ_GET_STATUS) return usbhc.UHIOERR_STALL;
            const port_status = d.PortStatus{ .status = function.port_status[port - 1], .change = function.port_change[port - 1] };
            return answer(req, std.mem.asBytes(&port_status));
        },
        d.USB_DIR_OUT | d.USB_RT_PORT => {
            if (!is_port) return usbhc.UHIOERR_STALL;
            switch (setup.request) {
                d.USB_REQ_SET_FEATURE => setFeature(hc, index, port, setup.value),
                d.USB_REQ_CLEAR_FEATURE => if (setup.value >= d.USB_PORT_FEAT_C_CONNECTION) {
                    function.port_change[port - 1] &= ~(@as(u16, 1) << @intCast(setup.value - d.USB_PORT_FEAT_C_CONNECTION));
                } else if (setup.value == d.USB_PORT_FEAT_ENABLE) {
                    function.port_status[port - 1] &= ~d.USB_PORT_STAT_ENABLE;
                },
                else => return usbhc.UHIOERR_STALL,
            }
        },
        else => return usbhc.UHIOERR_STALL,
    }
    return 0;
}

/// A hub's port powered or reset: a reset is done at once, the port
/// enabled at the speed of what is in it, and that at address 0 again.
fn setFeature(hc: *HC, index: u8, port: u8, feature: u16) void {
    const hub = &hc.functions[index];
    switch (feature) {
        d.USB_PORT_FEAT_POWER => hub.port_status[port - 1] |= d.USB_PORT_STAT_POWER,
        d.USB_PORT_FEAT_RESET => {
            if (hub.port_status[port - 1] & d.USB_PORT_STAT_CONNECTION == 0) return;
            for (&hc.functions) |*child| {
                if (!child.used or !child.present or child.parent != index or child.port != port) continue;
                child.address = 0;
                child.configuration = 0;
                hub.port_status[port - 1] |= d.USB_PORT_STAT_ENABLE | switch (child.speed) {
                    usbhc.USB_SPEED_LOW => d.USB_PORT_STAT_LOW_SPEED,
                    usbhc.USB_SPEED_HIGH => d.USB_PORT_STAT_HIGH_SPEED,
                    else => 0,
                };
                hub.port_change[port - 1] |= d.USB_PORT_STAT_C_RESET;
            }
        },
        else => {},
    }
}

/// A standard descriptor of the function.
fn descriptor(function: *const Function, req: *usbhc.IOUsbHC, kind: u8, index: u8) i8 {
    switch (kind) {
        d.USB_DT_DEVICE => return answer(req, std.mem.asBytes(&function.descriptor)),
        d.USB_DT_CONFIG => return answer(req, function.config[0..function.config_length]),
        d.USB_DT_STRING => {
            // String 0: the one language, English (US).
            if (index == 0) return answer(req, &.{ 4, d.USB_DT_STRING, 0x09, 0x04 });
            if (index > 3) return usbhc.UHIOERR_STALL;
            const text = std.mem.sliceTo(&function.strings[index - 1], 0);
            if (text.len == 0) return usbhc.UHIOERR_STALL;
            var raw: [2 + 2 * 16]u8 = undefined;
            raw[0] = @intCast(2 + 2 * text.len);
            raw[1] = d.USB_DT_STRING;
            for (text, 0..) |char, at| {
                raw[2 + 2 * at] = char;
                raw[3 + 2 * at] = 0;
            }
            return answer(req, raw[0..raw[0]]);
        },
        else => return usbhc.UHIOERR_STALL,
    }
}

/// `bytes` as a control transfer's data, as much as it asked for.
fn answer(req: *usbhc.IOUsbHC, bytes: []const u8) i8 {
    const length = @min(bytes.len, @as(usize, @intCast(req.std.length)));
    const data: [*]u8 = @ptrCast(req.std.data.?);
    @memcpy(data[0..length], bytes[0..length]);
    req.std.actual = @intCast(length);
    return 0;
}

const hc_vectors = [_]*const anyopaque{
    exec.vec(hcOpen),
    exec.vec(hcClose),
    exec.vec(hcExpunge),
    exec.vec(exec.libExtFunc),
    exec.vec(hcBeginIO),
    exec.vec(hcAbortIO),
};

const hc_table = exec.InitTable{
    .data_size = @sizeOf(HC),
    .vectors = &hc_vectors,
    .vector_count = hc_vectors.len,
    .init = &hcInit,
};

pub const tag: exec.Resident = .{
    .match_tag = &tag,
    .flags = exec.RTF_AUTOINIT,
    .version = 1,
    .type = .device,
    .pri = 0,
    .name = NAME,
    .id_string = "hcstandin.device 1.1",
    .init = &hc_table,
};
