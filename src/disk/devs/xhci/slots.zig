// SPDX-License-Identifier: MIT
//! Device slots: what the controller is told of each device, worked out
//! from the requests usb.library sends, which name a device only by its
//! bus address.
//!
//! **Where a device is** comes from the port reset before it: a hub's
//! SET_FEATURE(PORT_RESET) - the root hub's, or one sent down the wire
//! to a hub - is noted (`noteReset`), and whatever was on that port
//! before is let go. The first request to address 0 after it is for the
//! device on that port: its slot is had with Enable Slot and set up with
//! Address Device, its SET_ADDRESS held back (BSR), so the device stays
//! at address 0 and answers its first descriptor there (`defaultSlot`).
//! The route string and root port follow from the hub's slot, the speed
//! and the transaction translator from the request.
//!
//! **SET_ADDRESS** to address 0 is the controller's to send: Address
//! Device again, letting it through this time, and the bus's address is
//! bound to the slot; the request itself goes nowhere (`setAddress`).
//!
//! **SET_CONFIGURATION** has the configuration's endpoints added first
//! (Configure Endpoint), every interface's first setting, as the device
//! sent its configuration the last time it was read whole; an endpoint
//! a transfer names that is not among them - another setting's - is
//! added when the transfer comes (`ensureEndpoint`). So is every
//! isochronous one: a setting of its own, chosen with SET_INTERFACE
//! before its first transfer.
//!
//! **A hub** is told the controller once its hub descriptor has been
//! read: its ports and its TT think time (`hubUpdate`), before anything
//! behind it is reset.
//!
//! **A device that goes** is found from its hub's port status - no
//! connection, or a connection change - and its slot is disabled with
//! everything below it (`portGone`); a slot whose address the bus gives
//! to another device goes too.

const sdk = @import("sdk");
const exec = sdk.exec;
const usbhc = sdk.devices.usbhc;
const d = sdk.usb.descriptors;
const regs = @import("regs.zig");
const ring = @import("ring.zig");
const Trb = ring.Trb;
const _xhci = @import("_xhci.zig");
const Host = _xhci.Host;
const Slot = _xhci.Slot;
const Endpoint = _xhci.Endpoint;
const controller = @import("controller.zig");
const transfer = @import("transfer.zig");

/// How many hubs a device may be behind: a route string holds five.
const max_depth = 5;

// --- the endpoints ----------------------------------------------------------------

/// An endpoint's type in its context, from what kind of transfer it is
/// and its direction.
pub fn kindOf(attributes: u8, in: bool) ?u32 {
    return switch (attributes & d.USB_ENDPOINT_XFERTYPE_MASK) {
        d.USB_ENDPOINT_XFER_CONTROL => regs.EP_CONTROL,
        d.USB_ENDPOINT_XFER_BULK => if (in) regs.EP_BULK_IN else regs.EP_BULK_OUT,
        d.USB_ENDPOINT_XFER_INT => if (in) regs.EP_INTERRUPT_IN else regs.EP_INTERRUPT_OUT,
        else => null,
    };
}

fn isPeriodic(kind: u32) bool {
    return switch (kind) {
        regs.EP_INTERRUPT_IN, regs.EP_INTERRUPT_OUT, regs.EP_ISOCH_IN, regs.EP_ISOCH_OUT => true,
        else => false,
    };
}

fn log2(value: u32) u32 {
    return 31 - @clz(@max(value, 1));
}

/// An interrupt endpoint's interval as its context has it - an exponent
/// of 125 µs - from its descriptor's bInterval: microframes as a power
/// of two at high speed and SuperSpeed, frames at full and low speed.
pub fn intervalOf(speed: u32, b_interval: u8) u32 {
    if (speed >= regs.SPEED_HIGH) return @min(@max(b_interval, 1), 16) - 1;
    return @min(@max(log2(b_interval) + 3, 3), 10);
}

/// The same from an interval in milliseconds, as a request carries it.
pub fn intervalOfMs(speed: u32, ms: u16) u32 {
    const exponent = log2(ms) + 3;
    if (speed >= regs.SPEED_HIGH) return @min(exponent, 15);
    return @min(@max(exponent, 3), 10);
}

/// What an endpoint of a configuration is to be: its burst and bytes an
/// interval from its SuperSpeed companion, if it has one.
pub const Spec = struct {
    kind: u32 = 0,
    max_packet: u32 = 0,
    interval: u32 = 0,
    burst: u32 = 0,
    esit: u32 = 0,
};

/// A SuperSpeed endpoint companion at `at` into `spec`. An isochronous
/// endpoint keeps neither: it is served a packet an interval, as each
/// of its transfer's packets is one TD.
fn takeCompanion(config: []const u8, at: usize, spec: *Spec) void {
    if (spec.kind == regs.EP_ISOCH_OUT or spec.kind == regs.EP_ISOCH_IN) return;
    spec.burst = @min(config[at + 2], 15);
    spec.esit = @as(u32, config[at + 4]) | @as(u32, config[at + 5]) << 8;
}

/// The endpoints of configuration `value` in `config` (a configuration
/// descriptor and what follows it): every interface's first setting's,
/// by device context index, isochronous ones left out, each with its
/// SuperSpeed companion if one follows it. A bit per index found; 0 if
/// `config` is not that configuration.
pub fn endpointsOf(config: []const u8, value: u8, speed: u32, into: *[32]Spec) u32 {
    if (config.len < 9 or config[1] != d.USB_DT_CONFIG or config[5] != value) return 0;
    var found: u32 = 0;
    var alternate: u8 = 0;
    // The endpoint just taken, whose companion may come next.
    var last: u32 = 0;
    var at: usize = 0;
    while (at + 2 <= config.len) {
        const length = config[at];
        if (length < 2 or at + length > config.len) break;
        const previous = last;
        last = 0;
        switch (config[at + 1]) {
            d.USB_DT_SS_ENDPOINT_COMP => if (previous != 0 and length >= 6) {
                takeCompanion(config, at, &into[previous]);
            },
            d.USB_DT_INTERFACE => if (length >= 9) {
                alternate = config[at + 3];
            },
            d.USB_DT_ENDPOINT => if (length >= 7 and alternate == 0) {
                const address = config[at + 2];
                const attributes = config[at + 3];
                const packet = @as(u32, config[at + 4]) | @as(u32, config[at + 5]) << 8;
                const in = address & d.USB_DIR_IN != 0;
                if (kindOf(attributes, in)) |kind| {
                    const dci = regs.dciOf(address);
                    if (dci > 1 and found & regs.addFlag(dci) == 0) {
                        into[dci] = .{
                            .kind = kind,
                            .max_packet = packet & 0x7FF,
                            .interval = if (isPeriodic(kind)) intervalOf(speed, config[at + 6]) else 0,
                        };
                        found |= regs.addFlag(dci);
                        last = dci;
                    }
                }
            },
            else => {},
        }
        at += length;
    }
    return found;
}

/// An endpoint's ring there and empty, its cycle state 1: what its
/// context is pointed at when it is added. An isochronous endpoint's is
/// longer; one of the other length is made again.
fn freshRing(host: *Host, ep: *Endpoint) bool {
    const count: u32 = if (_xhci.isIso(ep)) _xhci.iso_ring_trbs else _xhci.ring_trbs;
    if (ep.ring.count != count) {
        const bytes = count * @sizeOf(Trb);
        var raw: ?*anyopaque = null;
        const memory = _xhci.allocDma(host, bytes, if (_xhci.isIso(ep)) bytes else _xhci.dma_align, &raw) orelse return false;
        if (ep.ring_raw) |old| host.sys.FreeMem(old, ep.ring_raw_size);
        ep.ring_raw = raw;
        ep.ring_raw_size = @intCast(_xhci.roundUp(bytes, _xhci.dma_align) + (if (_xhci.isIso(ep)) bytes else _xhci.dma_align));
        const trbs: [*]Trb = @ptrCast(@alignCast(memory));
        ep.ring.init(trbs[0..count]);
    } else {
        ep.ring.reset();
    }
    _xhci.toDevice(host, @intFromPtr(ep.ring.trbs), ep.ring.bytes());
    return true;
}

// --- the input context ------------------------------------------------------------

/// The slot's input context written for a command: what it drops and
/// adds, its slot context, and each endpoint it adds; out to memory.
fn buildInput(host: *Host, slot: *Slot, add: u32, drop: u32) void {
    @memset(slot.input[0.._xhci.inputBytes(host)], 0);
    const control = _xhci.inputContext(host, slot, 0);
    control[regs.ICC_DROP] = drop;
    control[regs.ICC_ADD] = add;
    const context = _xhci.inputContext(host, slot, 1);
    context[0] = regs.slotWord0(slot.route, slot.speed, slot.hub, slot.entries);
    context[1] = regs.slotWord1(slot.root_port, if (slot.hub) slot.hub_ports else 0);
    context[2] = regs.slotWord2(slot.tt_slot, slot.tt_port, slot.ttt);
    var dci: u32 = 1;
    while (dci < 32) : (dci += 1) {
        if (add & regs.addFlag(dci) == 0) continue;
        const ep = &slot.endpoints[dci];
        const words = _xhci.inputContext(host, slot, 1 + dci);
        const pointer = ep.ring.dequeuePointer();
        const periodic = isPeriodic(ep.kind);
        // A periodic endpoint's bytes an interval: its companion's, else
        // a packet's.
        const esit = if (ep.esit != 0) ep.esit else ep.max_packet;
        words[0] = regs.endpointWord0(ep.interval);
        words[1] = regs.endpointWord1(ep.kind, ep.burst, ep.max_packet);
        words[2] = ring.lo(pointer);
        words[3] = ring.hi(pointer);
        words[4] = if (ep.kind == regs.EP_CONTROL)
            regs.endpointWord4(8, 0)
        else if (periodic)
            regs.endpointWord4(esit, esit)
        else
            regs.endpointWord4(3072, 0);
    }
    _xhci.toDevice(host, @intFromPtr(slot.input), _xhci.inputBytes(host));
}

/// A command on a slot that takes its input context.
fn contextCommand(host: *Host, slot: *Slot, kind: u32, flags: u32) u32 {
    const input: u64 = @intFromPtr(slot.input);
    return controller.command(host, .{
        .param_lo = ring.lo(input),
        .param_hi = ring.hi(input),
        .control = regs.typeField(kind) | regs.slotField(slot.id) | flags,
    });
}

fn highestOf(slot: *Slot) u32 {
    var dci: u32 = 31;
    while (dci > 1) : (dci -= 1) {
        if (slot.endpoints[dci].enabled) return dci;
    }
    return 1;
}

// --- a device's slot --------------------------------------------------------------

/// Slot `id`'s block, made the first time the controller hands it out:
/// its contexts in DMA memory, its endpoints' lists.
fn blockOf(host: *Host, id: u32) ?*Slot {
    if (host.slots[id]) |slot| return slot;
    const sys = host.sys;
    const memory = sys.AllocMem(@sizeOf(Slot), exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    const slot: *Slot = @ptrCast(@alignCast(memory));
    const output = _xhci.allocDma(host, _xhci.outputBytes(host), _xhci.dma_align, null) orelse {
        sys.FreeMem(memory, @sizeOf(Slot));
        return null;
    };
    const input = _xhci.allocDma(host, _xhci.inputBytes(host), _xhci.dma_align, null) orelse {
        sys.FreeMem(memory, @sizeOf(Slot));
        return null;
    };
    slot.* = .{ .id = @intCast(id), .output = output, .input = input };
    for (&slot.endpoints) |*ep| {
        sys.NewList(&ep.queue);
        sys.NewList(&ep.flight);
    }
    host.slots[id] = slot;
    return slot;
}

/// A slot's device state cleared for a new device; its memory - the
/// contexts, the rings, the buffers - kept.
fn clear(slot: *Slot) void {
    for (&slot.endpoints) |*ep| {
        ep.* = .{
            .ring = ep.ring,
            .ring_raw = ep.ring_raw,
            .ring_raw_size = ep.ring_raw_size,
            .flight = ep.flight,
            .bounce = ep.bounce,
            .bounce_size = ep.bounce_size,
            .bounce_raw = ep.bounce_raw,
            .bounce_raw_size = ep.bounce_raw_size,
            .queue = ep.queue,
        };
    }
    slot.enabled = false;
    slot.address = 0;
    slot.addressed = false;
    slot.speed = 0;
    slot.parent = 0;
    slot.port = 0;
    slot.root_port = 0;
    slot.route = 0;
    slot.depth = 0;
    slot.tt_slot = 0;
    slot.tt_port = 0;
    slot.hub = false;
    slot.hub_ports = 0;
    slot.ttt = 0;
    slot.entries = 1;
    slot.config_length = 0;
}

/// A port reset: whatever was on the hub's port let go - and a slot that
/// never got its address - and the port noted as where the next device
/// at address 0 is.
pub fn noteReset(host: *Host, hub: u8, port: u8) void {
    portGone(host, hub, port);
    if (host.default_slot != 0) {
        if (host.slots[host.default_slot]) |slot| disable(host, slot);
    }
    host.reset_hub = hub;
    host.reset_port = port;
}

/// What usbhc calls a speed, as the slot context has it.
fn speedOf(speed: u8) u32 {
    return switch (speed) {
        usbhc.USB_SPEED_LOW => regs.SPEED_LOW,
        usbhc.USB_SPEED_HIGH => regs.SPEED_HIGH,
        usbhc.USB_SPEED_SUPER => regs.SPEED_SUPER,
        else => regs.SPEED_FULL,
    };
}

/// The slot that answers at address 0: the one made since the last port
/// reset, or one made now for the device on that port. Null when no
/// port was reset, or the controller would not have it.
pub fn defaultSlot(host: *Host, req: *const usbhc.IOUsbHC) ?*Slot {
    if (_xhci.slotAt(host, 0)) |slot| return slot;
    if (host.reset_port == 0) return null;
    const port = host.reset_port;
    var root_port: u32 = 0;
    var route: u32 = 0;
    var depth: u8 = 0;
    if (host.reset_hub == 0) {
        if (port > host.ports) return null;
        root_port = host.port_map[port - 1];
    } else {
        const hub = host.slots[host.reset_hub] orelse return null;
        if (!hub.enabled or hub.depth + 1 > max_depth) return null;
        root_port = hub.root_port;
        depth = hub.depth + 1;
        route = hub.route | @as(u32, @min(port, 15)) << @intCast(4 * @as(u32, hub.depth));
    }

    if (controller.command(host, .{ .control = regs.typeField(regs.TRB_ENABLE_SLOT) }) != regs.CC_SUCCESS) return null;
    const id = host.command_slot;
    if (id == 0 or id > _xhci.max_slots) return null;
    const slot = blockOf(host, id) orelse {
        _ = controller.command(host, .{ .control = regs.typeField(regs.TRB_DISABLE_SLOT) | regs.slotField(id) });
        return null;
    };
    clear(slot);
    slot.enabled = true;
    slot.speed = speedOf(req.speed);
    slot.parent = host.reset_hub;
    slot.port = port;
    slot.root_port = @intCast(root_port);
    slot.route = route;
    slot.depth = depth;
    if (req.hub_address != 0 and (slot.speed == regs.SPEED_FULL or slot.speed == regs.SPEED_LOW)) {
        slot.tt_slot = host.by_address[req.hub_address & 0x7F];
        slot.tt_port = req.hub_port;
    }
    const ep0 = &slot.endpoints[1];
    ep0.kind = regs.EP_CONTROL;
    ep0.max_packet = @max(req.max_packet, 8);
    if (!freshRing(host, ep0)) {
        disable(host, slot);
        return null;
    }
    ep0.enabled = true;

    // The device context zeroed and given the controller.
    @memset(slot.output[0.._xhci.outputBytes(host)], 0);
    _xhci.toDevice(host, @intFromPtr(slot.output), _xhci.outputBytes(host));
    host.dcbaa[id] = @intFromPtr(slot.output);
    _xhci.toDevice(host, @intFromPtr(&host.dcbaa[id]), 8);

    buildInput(host, slot, regs.ADD_SLOT | regs.addFlag(1), 0);
    const code = contextCommand(host, slot, regs.TRB_ADDRESS_DEVICE, regs.TRB_BSR);
    if (code != regs.CC_SUCCESS) {
        sdk.exec.kprintf(host.sys, "%s: unit %d: a device on port %d was not taken (%d)\n", .{ _xhci.DEVICE_NAME, host.number, @as(u32, port), code });
        disable(host, slot);
        return null;
    }
    host.default_slot = slot.id;
    host.reset_port = 0;
    return slot;
}

/// SET_ADDRESS to the device at address 0: Address Device lets the
/// controller's own SET_ADDRESS through, and the bus's address is bound
/// to the slot. 0, or the request's error.
pub fn setAddress(host: *Host, req: *const usbhc.IOUsbHC) i8 {
    const slot = defaultSlot(host, req) orelse return usbhc.UHIOERR_DETACHED;
    const address: u8 = @truncate(req.setup.value & 0x7F);
    if (address == 0) return usbhc.UHIOERR_STALL;
    if (host.by_address[address] != 0 and host.by_address[address] != slot.id) {
        if (host.slots[host.by_address[address]]) |stale| disable(host, stale);
    }
    // Endpoint 0's packet size as the bus has it now, and its ring where
    // it is: a TD or two went on it already.
    slot.endpoints[1].max_packet = @max(req.max_packet, 8);
    buildInput(host, slot, regs.ADD_SLOT | regs.addFlag(1), 0);
    const code = contextCommand(host, slot, regs.TRB_ADDRESS_DEVICE, 0);
    if (code != regs.CC_SUCCESS) {
        sdk.exec.kprintf(host.sys, "%s: unit %d: a device's address was not set (%d)\n", .{ _xhci.DEVICE_NAME, host.number, code });
        return if (code == regs.CC_TRANSACTION) usbhc.UHIOERR_CRCERROR else usbhc.UHIOERR_HOSTERROR;
    }
    slot.addressed = true;
    slot.address = address;
    host.by_address[address] = slot.id;
    host.default_slot = 0;
    return 0;
}

/// Endpoint 0's packet size as the request says, the controller told if
/// it changed. False if it would not have it.
pub fn checkPacketSize(host: *Host, slot: *Slot, req: *const usbhc.IOUsbHC) bool {
    const ep0 = &slot.endpoints[1];
    const size: u32 = @max(req.max_packet, 8);
    if (size == ep0.max_packet) return true;
    ep0.max_packet = size;
    buildInput(host, slot, regs.addFlag(1), 0);
    return contextCommand(host, slot, regs.TRB_EVALUATE_CONTEXT, 0) == regs.CC_SUCCESS;
}

/// SET_CONFIGURATION(`value`) about to go: every endpoint there was
/// dropped, the configuration's added. False if the controller would not
/// have them.
pub fn configure(host: *Host, slot: *Slot, value: u8) bool {
    var drop: u32 = 0;
    var dci: u32 = 2;
    while (dci < 32) : (dci += 1) {
        if (slot.endpoints[dci].enabled) drop |= regs.addFlag(dci);
    }
    var specs: [32]Spec = @splat(.{});
    const add = if (value == 0) 0 else endpointsOf(slot.config[0..slot.config_length], value, slot.speed, &specs);
    if (add == 0 and drop == 0) return true;
    dci = 2;
    while (dci < 32) : (dci += 1) {
        const ep = &slot.endpoints[dci];
        if (drop & regs.addFlag(dci) != 0) ep.enabled = false;
        if (add & regs.addFlag(dci) == 0) continue;
        ep.kind = specs[dci].kind;
        ep.max_packet = specs[dci].max_packet;
        ep.interval = specs[dci].interval;
        ep.burst = specs[dci].burst;
        ep.esit = specs[dci].esit;
        if (!freshRing(host, ep)) return false;
        ep.enabled = true;
    }
    slot.entries = highestOf(slot);
    buildInput(host, slot, regs.ADD_SLOT | add, drop);
    const code = contextCommand(host, slot, regs.TRB_CONFIGURE_ENDPOINT, 0);
    if (code == regs.CC_SUCCESS) return true;
    sdk.exec.kprintf(host.sys, "%s: unit %d: configuration %d's endpoints were not taken (%d)\n", .{ _xhci.DEVICE_NAME, host.number, @as(u32, value), code });
    dci = 2;
    while (dci < 32) : (dci += 1) slot.endpoints[dci].enabled = false;
    slot.entries = 1;
    return false;
}

/// The endpoint a transfer is for there as the transfer says it is: added
/// if it is not in the slot's context, added afresh if it is there as
/// something else. 0, or why the controller would not have it:
/// UHIOERR_BANDWIDTH when its frames have no room for it.
pub fn ensureEndpoint(host: *Host, slot: *Slot, dci: u32, req: *const usbhc.IOUsbHC) i8 {
    const ep = &slot.endpoints[dci];
    const in = req.endpoint & d.USB_DIR_IN != 0;
    const kind: u32 = switch (req.std.req.command) {
        usbhc.UHCMD_BULKXFER => if (in) regs.EP_BULK_IN else regs.EP_BULK_OUT,
        usbhc.UHCMD_ISOXFER => if (in) regs.EP_ISOCH_IN else regs.EP_ISOCH_OUT,
        else => if (in) regs.EP_INTERRUPT_IN else regs.EP_INTERRUPT_OUT,
    };
    const packet: u32 = @max(req.max_packet & 0x7FF, 1);
    if (ep.enabled and ep.kind == kind and ep.max_packet == packet) return 0;
    const drop = if (ep.enabled) regs.addFlag(dci) else 0;
    ep.enabled = false;
    ep.kind = kind;
    ep.max_packet = packet;
    ep.interval = if (isPeriodic(kind)) intervalOfMs(slot.speed, req.interval) else 0;
    var spec = Spec{ .kind = kind };
    if (slot.speed >= regs.SPEED_SUPER) companionOf(slot.config[0..slot.config_length], req.endpoint, &spec);
    ep.burst = spec.burst;
    ep.esit = spec.esit;
    ep.stride = strideOf(packet);
    ep.next_slice = 0;
    ep.expect = 0;
    ep.streaming = false;
    if (!freshRing(host, ep)) return usbhc.UHIOERR_HOSTERROR;
    ep.enabled = true;
    slot.entries = highestOf(slot);
    buildInput(host, slot, regs.ADD_SLOT | regs.addFlag(dci), drop);
    const code = contextCommand(host, slot, regs.TRB_CONFIGURE_ENDPOINT, 0);
    if (code == regs.CC_SUCCESS) return 0;
    ep.enabled = false;
    slot.entries = highestOf(slot);
    return if (code == regs.CC_BANDWIDTH) usbhc.UHIOERR_BANDWIDTH else usbhc.UHIOERR_HOSTERROR;
}

/// The SuperSpeed companion of the endpoint at `address` in `config`, in
/// whichever setting it is first found, into `spec`; nothing if it has
/// none.
pub fn companionOf(config: []const u8, address: u8, spec: *Spec) void {
    var at: usize = 0;
    while (at + 2 <= config.len) {
        const length = config[at];
        if (length < 2 or at + length > config.len) return;
        if (config[at + 1] == d.USB_DT_ENDPOINT and length >= 7 and config[at + 2] == address) {
            const next = at + length;
            if (next + 6 <= config.len and config[next] >= 6 and config[next + 1] == d.USB_DT_SS_ENDPOINT_COMP) {
                takeCompanion(config, next, spec);
            }
            return;
        }
        at += length;
    }
}

/// How far apart an isochronous endpoint's packets lie in its buffer: a
/// power of two, at least a cache line, so a packet never crosses a
/// 64 KiB boundary in a buffer aligned to its size.
pub fn strideOf(max_packet: u32) u32 {
    var stride: u32 = @intCast(_xhci.dma_align);
    while (stride < max_packet) stride *= 2;
    return stride;
}

/// A hub's descriptor read: the slot told it is a hub, its ports and, at
/// high speed, its TT think time.
pub fn hubUpdate(host: *Host, slot: *Slot, descriptor: []const u8) void {
    if (descriptor.len < 5) return;
    slot.hub = true;
    slot.hub_ports = descriptor[2];
    const characteristics = @as(u32, descriptor[3]) | @as(u32, descriptor[4]) << 8;
    slot.ttt = if (slot.speed == regs.SPEED_HIGH) @intCast((characteristics >> 5) & 3) else 0;
    buildInput(host, slot, regs.ADD_SLOT, 0);
    // Before 1.0 the controller took a slot's hub fields by Evaluate
    // Context.
    const kind = if (host.version > 0x95) regs.TRB_CONFIGURE_ENDPOINT else regs.TRB_EVALUATE_CONTEXT;
    const code = contextCommand(host, slot, kind, 0);
    if (code != regs.CC_SUCCESS) {
        sdk.exec.kprintf(host.sys, "%s: unit %d: a hub was not taken as one (%d)\n", .{ _xhci.DEVICE_NAME, host.number, code });
    }
}

/// Whatever was on `hub`'s port `port` (hub 0: the root hub) gone: its
/// slot disabled, and everything below it.
pub fn portGone(host: *Host, hub: u8, port: u8) void {
    for (host.slots[1..]) |entry| {
        const slot = entry orelse continue;
        if (slot.enabled and slot.parent == hub and slot.port == port) disable(host, slot);
    }
}

/// A slot let go: what hangs off it first, its transfers answered
/// UHIOERR_DETACHED, Disable Slot, and its address free.
pub fn disable(host: *Host, slot: *Slot) void {
    if (!slot.enabled) return;
    slot.enabled = false;
    for (host.slots[1..]) |entry| {
        const child = entry orelse continue;
        if (child.enabled and child.parent == slot.id) disable(host, child);
    }
    transfer.failSlot(host, slot, usbhc.UHIOERR_DETACHED);
    _ = controller.command(host, .{ .control = regs.typeField(regs.TRB_DISABLE_SLOT) | regs.slotField(slot.id) });
    host.dcbaa[slot.id] = 0;
    _xhci.toDevice(host, @intFromPtr(&host.dcbaa[slot.id]), 8);
    if (slot.address != 0 and host.by_address[slot.address] == slot.id) host.by_address[slot.address] = 0;
    if (host.default_slot == slot.id) host.default_slot = 0;
    clear(slot);
}

/// Every slot forgotten, as the controller is reset: nothing is told it.
pub fn forgetAll(host: *Host) void {
    for (host.slots[1..]) |entry| {
        const slot = entry orelse continue;
        clear(slot);
    }
    host.by_address = @splat(0);
    host.default_slot = 0;
    host.reset_hub = 0;
    host.reset_port = 0;
}
