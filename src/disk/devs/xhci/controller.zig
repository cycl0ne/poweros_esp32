// SPDX-License-Identifier: MIT
//! The controller itself: brought up and stopped, its interrupt, its
//! event ring, and commands.
//!
//! **Bringing it up**, as the specification's chapter 4.2 has it: the
//! function's memory decoding and bus mastering on; the controller taken
//! from the firmware if the firmware says it has it (USB Legacy
//! Support); halted and reset; told how many slots to use, where the
//! device context base address array is - its entry 0 the scratchpad's
//! array, when the controller wants a scratchpad - where the command
//! ring is, and where its event ring's one segment is; its interrupter
//! 0 enabled, moderated to 4000 interrupts a second; then run. The
//! Supported Protocol capabilities say which root ports are USB 2's and
//! which USB 3's: all are the root hub's, the USB 2 ones first
//! (roothub.zig). The memory is made the first time and kept, rings
//! emptied each time.
//!
//! **The interrupt** clears what the controller raised - USBSTS's EINT,
//! the interrupter's IP - and wakes the task, which takes the events
//! (`takeEvents`): a transfer's to transfer.zig, a port's to the root
//! hub, a command's to the command waiting for it.
//!
//! **A command** is put on the command ring, the controller's doorbell
//! rung, and the task waits for its completion, taking every event that
//! comes meanwhile, for at most a second (`command`). What an event
//! leads to is never a command itself: a transfer's end or a halt is
//! noted, and the task's next pass does what follows from it.

const sdk = @import("sdk");
const exec = sdk.exec;
const pci = sdk.pci;
const regs = @import("regs.zig");
const ring = @import("ring.zig");
const Trb = ring.Trb;
const _xhci = @import("_xhci.zig");
const Host = _xhci.Host;
const op = _xhci.op;
const rt = _xhci.rt;
const reg = _xhci.reg;
const roothub = @import("roothub.zig");
const transfer = @import("transfer.zig");
const slots = @import("slots.zig");

/// The interrupter's moderation: 250 µs, in its 250 ns units.
const moderation = 1000;
/// How long a command is waited for, in ms.
const command_ms = 1000;

/// Until `mask` of the operational register at `offset` reads `want`,
/// polled every millisecond; false after `ms` of them.
fn pollFor(host: *Host, offset: usize, mask: u32, want: u32, ms: u32) bool {
    var waited: u32 = 0;
    while (op(host, offset).* & mask != want) : (waited += 1) {
        if (waited >= ms) return false;
        _xhci.delay(host, 1);
    }
    return true;
}

/// The controller found behind its function and reset: its registers'
/// blocks, what it is, its root hub's ports. False if it does not answer.
pub fn bringUp(host: *Host) bool {
    const sys = host.sys;
    const pb = host.dev_base.pci_base.?;
    const function = host.function;
    const bar = function.bars[0];
    if (bar.address == 0 or bar.flags & pci.PCIBAR_IO != 0) {
        sdk.exec.kprintf(sys, "%s: unit %d: its registers were not placed\n", .{ _xhci.DEVICE_NAME, host.number });
        return false;
    }
    var command_word = pb.ReadPCIConfig(function, pci.PCI_COMMAND, 2);
    command_word |= pci.PCI_COMMAND_MEMORY | pci.PCI_COMMAND_MASTER;
    command_word &= ~@as(u32, pci.PCI_COMMAND_INTX_DISABLE);
    pb.WritePCIConfig(function, pci.PCI_COMMAND, 2, command_word);

    host.regs = @intCast(bar.address);
    const first = reg(host.regs + regs.CAPLENGTH).*;
    if (first == 0xFFFF_FFFF) {
        sdk.exec.kprintf(sys, "%s: unit %d: its registers do not answer\n", .{ _xhci.DEVICE_NAME, host.number });
        return false;
    }
    host.version = first >> 16;
    host.op = host.regs + (first & 0xFF);
    host.rt = host.regs + (reg(host.regs + regs.RTSOFF).* & ~@as(u32, 0x1F));
    host.db = host.regs + (reg(host.regs + regs.DBOFF).* & ~@as(u32, 3));
    const params1 = reg(host.regs + regs.HCSPARAMS1).*;
    const params2 = reg(host.regs + regs.HCSPARAMS2).*;
    const cparams1 = reg(host.regs + regs.HCCPARAMS1).*;
    host.max_slots = @min(regs.maxSlots(params1), _xhci.max_slots);
    host.max_ports = regs.maxPorts(params1);
    host.scratchpads = regs.scratchpads(params2);
    host.iso_lead = regs.istFrames(params2) + 1;
    host.context_size = if (cparams1 & regs.HCC_CSZ != 0) 64 else 32;
    host.power_switched = cparams1 & regs.HCC_PPC != 0;
    host.max_psa_size = regs.maxPsaSize(cparams1);
    var protocols: Protocols = .{};
    walkCapabilities(host, regs.extendedCaps(cparams1), &protocols);
    host.ports = mapPorts(protocols, host.max_ports, &host.port_map, &host.super_ports);

    // Halted, then reset.
    if (op(host, regs.USBSTS).* & regs.USBSTS_HCH == 0) {
        op(host, regs.USBCMD).* &= ~regs.USBCMD_RS;
        _ = pollFor(host, regs.USBSTS, regs.USBSTS_HCH, regs.USBSTS_HCH, 32);
    }
    op(host, regs.USBCMD).* |= regs.USBCMD_HCRST;
    _xhci.delay(host, 1);
    if (!pollFor(host, regs.USBCMD, regs.USBCMD_HCRST, 0, 1000) or
        !pollFor(host, regs.USBSTS, regs.USBSTS_CNR, 0, 1000))
    {
        sdk.exec.kprintf(sys, "%s: unit %d: the controller did not come out of its reset\n", .{ _xhci.DEVICE_NAME, host.number });
        return false;
    }
    const page_bits = op(host, regs.PAGESIZE).* & 0xFFFF;
    host.page_size = if (page_bits == 0) 4096 else @as(u32, 4096) << @intCast(@ctz(page_bits));

    if (!host.memory_made) {
        if (!makeMemory(host)) {
            sdk.exec.kprintf(sys, "%s: unit %d: no memory for its rings\n", .{ _xhci.DEVICE_NAME, host.number });
            return false;
        }
        host.memory_made = true;
    }
    slots.forgetAll(host);
    // MFINDEX starts again from 0 as the controller runs.
    host.frame_seen = 0;
    host.frame_ms = _xhci.now(host);
    return true;
}

/// The root ports each Supported Protocol capability names: the USB 2
/// ones and the USB 3 ones, a run of each.
pub const Protocols = struct {
    usb2_first: u32 = 0,
    usb2_count: u32 = 0,
    usb3_first: u32 = 0,
    usb3_count: u32 = 0,
};

/// The root hub's ports from the controller's: the USB 2 run, then the
/// USB 3 run, `max_root_ports` at most - every port as USB 2 when no
/// capability named any. Their PORTSC numbers into `map`, a bit per USB 3
/// one into `super`; how many there are.
pub fn mapPorts(protocols: Protocols, max_ports: u32, map: *[_xhci.max_root_ports]u8, super: *u32) u32 {
    map.* = @splat(0);
    super.* = 0;
    var count: u32 = 0;
    if (protocols.usb2_count == 0 and protocols.usb3_count == 0) {
        while (count < @min(max_ports, _xhci.max_root_ports)) : (count += 1) map[count] = @intCast(count + 1);
        return count;
    }
    const ranges = [2][2]u32{ .{ protocols.usb2_first, protocols.usb2_count }, .{ protocols.usb3_first, protocols.usb3_count } };
    for (ranges, 0..) |range, usb3| {
        var offset: u32 = 0;
        while (offset < range[1] and count < _xhci.max_root_ports) : (offset += 1) {
            const port = range[0] + offset;
            if (port == 0 or port > max_ports) continue;
            map[count] = @intCast(port);
            count += 1;
            if (usb3 == 1) super.* |= @as(u32, 1) << @intCast(count);
        }
    }
    return count;
}

/// The extended capabilities from `start` (words from BAR0): the
/// controller taken from the firmware, the USB 2 and USB 3 ports found.
fn walkCapabilities(host: *Host, start: u32, protocols: *Protocols) void {
    var offset: usize = @as(usize, start) * 4;
    var seen: u32 = 0;
    while (offset != 0 and seen < 64) : (seen += 1) {
        const at = host.regs + offset;
        const word = reg(at).*;
        switch (word & 0xFF) {
            regs.EXT_LEGACY => takeOver(host, at),
            regs.EXT_PROTOCOL => {
                const ports = reg(at + 8).*;
                const count = (ports >> 8) & 0xFF;
                const major = word >> 24;
                if (major == 2 and count != 0 and protocols.usb2_count == 0) {
                    protocols.usb2_first = ports & 0xFF;
                    protocols.usb2_count = count;
                } else if (major == 3 and count != 0 and protocols.usb3_count == 0) {
                    protocols.usb3_first = ports & 0xFF;
                    protocols.usb3_count = count;
                }
            },
            else => {},
        }
        const next = (word >> 8) & 0xFF;
        if (next == 0) break;
        offset += @as(usize, next) * 4;
    }
}

/// The controller taken from firmware that says it has it: asked for,
/// up to a second waited for, and its SMIs off.
fn takeOver(host: *Host, at: usize) void {
    if (reg(at).* & regs.LEGACY_BIOS_OWNED != 0) {
        reg(at).* = reg(at).* | regs.LEGACY_OS_OWNED;
        var waited: u32 = 0;
        while (reg(at).* & regs.LEGACY_BIOS_OWNED != 0 and waited < 1000) : (waited += 1) _xhci.delay(host, 1);
        if (reg(at).* & regs.LEGACY_BIOS_OWNED != 0) {
            sdk.exec.kprintf(host.sys, "%s: unit %d: the firmware kept the controller; taken anyway\n", .{ _xhci.DEVICE_NAME, host.number });
        }
    }
    reg(at + 4).* = (reg(at + 4).* & regs.LEGACY_DISABLE_SMI) | regs.LEGACY_SMI_EVENTS;
}

/// The controller's memory: the device context base address array with
/// the scratchpad's in entry 0, the command ring, the event ring and its
/// segment table.
fn makeMemory(host: *Host) bool {
    const dcbaa = _xhci.allocDma(host, (_xhci.max_slots + 1) * 8, _xhci.dma_align, null) orelse return false;
    host.dcbaa = @ptrCast(@alignCast(dcbaa));
    if (host.scratchpads != 0) {
        const array = _xhci.allocDma(host, host.scratchpads * 8, _xhci.dma_align, null) orelse return false;
        const entries: [*]volatile u64 = @ptrCast(@alignCast(array));
        var n: u32 = 0;
        while (n < host.scratchpads) : (n += 1) {
            const page = _xhci.allocDma(host, host.page_size, host.page_size, null) orelse return false;
            entries[n] = @intFromPtr(page);
        }
        _xhci.toDevice(host, @intFromPtr(array), host.scratchpads * 8);
        host.dcbaa[0] = @intFromPtr(array);
    }
    const commands = _xhci.allocDma(host, _xhci.ring_trbs * @sizeOf(Trb), _xhci.dma_align, null) orelse return false;
    const command_trbs: [*]Trb = @ptrCast(@alignCast(commands));
    host.commands.init(command_trbs[0.._xhci.ring_trbs]);
    // A page, aligned to one: never across a 64 KiB boundary.
    const events = _xhci.allocDma(host, _xhci.event_trbs * @sizeOf(Trb), 4096, null) orelse return false;
    const event_trbs: [*]Trb = @ptrCast(@alignCast(events));
    host.events.init(event_trbs[0.._xhci.event_trbs]);
    const erst = _xhci.allocDma(host, 16, _xhci.dma_align, null) orelse return false;
    host.erst = @ptrCast(@alignCast(erst));
    return true;
}

/// The controller told where everything is and run: false if it does
/// not start.
pub fn run(host: *Host) bool {
    // Every slot's entry empty again, the scratchpad's kept.
    var n: usize = 1;
    while (n <= _xhci.max_slots) : (n += 1) host.dcbaa[n] = 0;
    _xhci.toDevice(host, @intFromPtr(host.dcbaa), (_xhci.max_slots + 1) * 8);
    host.commands.reset();
    _xhci.toDevice(host, @intFromPtr(host.commands.trbs), host.commands.bytes());
    host.events.init(host.events.trbs[0..host.events.count]);
    _xhci.toDevice(host, @intFromPtr(host.events.trbs), host.events.bytes());
    const segment: u64 = @intFromPtr(host.events.trbs);
    host.erst[0] = ring.lo(segment);
    host.erst[1] = ring.hi(segment);
    host.erst[2] = host.events.count;
    host.erst[3] = 0;
    _xhci.toDevice(host, @intFromPtr(host.erst), 16);

    op(host, regs.CONFIG).* = (op(host, regs.CONFIG).* & ~@as(u32, 0xFF)) | host.max_slots;
    _xhci.write64(host.op + regs.DCBAAP, @intFromPtr(host.dcbaa));
    _xhci.write64(host.op + regs.CRCR, host.commands.dequeuePointer());
    rt(host, regs.ERSTSZ).* = 1;
    _xhci.write64(host.rt + regs.ERDP, host.events.dequeueAddress());
    _xhci.write64(host.rt + regs.ERSTBA, @intFromPtr(host.erst));
    rt(host, regs.IMOD).* = moderation;
    rt(host, regs.IMAN).* = regs.IMAN_IE | regs.IMAN_IP;
    op(host, regs.USBSTS).* = regs.USBSTS_EINT | regs.USBSTS_PCD | regs.USBSTS_HSE;
    op(host, regs.USBCMD).* = regs.USBCMD_RS | regs.USBCMD_INTE | regs.USBCMD_HSEE;
    if (!pollFor(host, regs.USBSTS, regs.USBSTS_HCH, 0, 100)) {
        sdk.exec.kprintf(host.sys, "%s: unit %d: the controller did not start\n", .{ _xhci.DEVICE_NAME, host.number });
        return false;
    }
    return true;
}

/// The controller halted: nothing more on its rings, no interrupts.
pub fn shutDown(host: *Host) void {
    op(host, regs.USBCMD).* &= ~(regs.USBCMD_RS | regs.USBCMD_INTE);
    _ = pollFor(host, regs.USBSTS, regs.USBSTS_HCH, regs.USBSTS_HCH, 32);
    rt(host, regs.IMAN).* = regs.IMAN_IP;
}

// --- the interrupt ----------------------------------------------------------------

/// The controller's interrupt: what it raised cleared, the task woken.
/// Not the controller's if it raised nothing - the line is shared.
pub fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const host: *Host = @ptrCast(@alignCast(is_data.?));
    const status = op(host, regs.USBSTS).*;
    if (status == 0xFFFF_FFFF or status & (regs.USBSTS_EINT | regs.USBSTS_HSE) == 0) return 0;
    op(host, regs.USBSTS).* = status & (regs.USBSTS_EINT | regs.USBSTS_PCD | regs.USBSTS_HSE);
    rt(host, regs.IMAN).* = regs.IMAN_IE | regs.IMAN_IP;
    host.sys.Signal(&host.task, host.int_signal);
    return 1;
}

// --- events -----------------------------------------------------------------------

/// Every event the controller has written taken, and the controller told
/// how far.
pub fn takeEvents(host: *Host) void {
    _xhci.fromDevice(host, @intFromPtr(host.events.trbs), host.events.bytes());
    var taken = false;
    while (host.events.peek()) |event| {
        host.events.advance();
        taken = true;
        switch (regs.trbType(event.control)) {
            regs.TRB_COMMAND_COMPLETION => {
                if (host.command_trb != 0 and event.param() == host.command_trb) {
                    host.command_code = regs.completionCode(event.status);
                    host.command_slot = regs.eventSlot(event.control);
                    host.command_done = true;
                }
            },
            regs.TRB_TRANSFER_EVENT => transfer.completed(host, event),
            regs.TRB_PORT_STATUS_CHANGE => roothub.portChanged(host),
            regs.TRB_HOST_CONTROLLER => {
                sdk.exec.kprintf(host.sys, "%s: unit %d: the controller says %d\n", .{ _xhci.DEVICE_NAME, host.number, regs.completionCode(event.status) });
            },
            else => {},
        }
    }
    if (taken) _xhci.write64(host.rt + regs.ERDP, host.events.dequeueAddress() | regs.ERDP_EHB);
}

// --- commands ---------------------------------------------------------------------

/// A command given the controller and waited for: its completion code,
/// with the slot it names in `command_slot`; 0 if it did not come.
pub fn command(host: *Host, trb: Trb) u32 {
    const address = host.commands.push(trb);
    _xhci.toDevice(host, @intFromPtr(host.commands.trbs), host.commands.bytes());
    host.command_trb = address;
    host.command_done = false;
    host.command_slot = 0;
    _xhci.ringDoorbell(host, 0, 0);
    var waited: u32 = 0;
    while (true) {
        takeEvents(host);
        if (host.command_done) break;
        if (waited >= command_ms) {
            sdk.exec.kprintf(host.sys, "%s: unit %d: command %d was not answered\n", .{ _xhci.DEVICE_NAME, host.number, regs.trbType(trb.control) });
            host.command_trb = 0;
            return 0;
        }
        _xhci.delay(host, 1);
        waited += 1;
    }
    host.command_trb = 0;
    return host.command_code;
}
