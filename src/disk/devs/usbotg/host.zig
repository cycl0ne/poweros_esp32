// SPDX-License-Identifier: MIT
//! A controller as a host: the core brought up, its interrupt, its task,
//! and transfers on its channels.
//!
//! **The core** is reset, told to be a host and to use its own DMA
//! (buffer DMA: a channel reads and writes memory at HCDMA), its FIFO is
//! divided between what comes in and what goes out, and its root port is
//! powered. The high-speed controller runs at full speed for now
//! (HCFG_FSLSSUPP): a hub on it is then a full-speed hub, and a
//! low-speed device behind it is reached as on the full-speed one.
//!
//! **A transfer is put on a channel** when one is free, not a channel
//! per endpoint: eight channels kept by eight open endpoints would be
//! gone with a hub, a keyboard, a mouse and a stick. Its data passes
//! through the channel's buffer in internal memory, in rounds of it - the
//! DMA reaches only that on the S3, and on the P4 the buffer's cache
//! lines are written back before the controller reads and dropped after
//! it writes. A control transfer goes SETUP, data, status on one channel.
//!
//! **NAKs.** A bulk or control endpoint that has nothing yet is asked
//! again by the channel itself until it answers, or until the request's
//! NAK timeout, which the task's tick checks. An interrupt endpoint that
//! has nothing halts the channel: the request is parked and asked again
//! once its interval has passed, so a keyboard nobody types on holds no
//! channel, and costs a wake-up per interval.
//!
//! **The data toggle** is counted from the packets a round moved, and
//! left in the request: the controller's own PID field is not read back.

const sdk = @import("sdk");
const exec = sdk.exec;
const usbhc = sdk.devices.usbhc;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const dwc = sdk.hardware.usb_dwc;
const usb_otg = sdk.hardware.usb_otg;
const d = sdk.usb.descriptors;
const _usbotg = @import("_usbotg.zig");
const Host = _usbotg.Host;
const Channel = _usbotg.Channel;
const reg = _usbotg.reg;
const roothub = @import("roothub.zig");

// --- the core ---------------------------------------------------------------------

/// Until `mask` of `offset`'s register reads `want`, polled every
/// millisecond; false after `ms` of them.
fn pollFor(host: *Host, offset: usize, mask: u32, want: u32, ms: u32) bool {
    var waited: u32 = 0;
    while (reg(host, offset).* & mask != want) : (waited += 1) {
        if (waited >= ms) return false;
        _usbotg.delay(host, 1);
    }
    return true;
}

/// The core brought up as a host, its root port powered. False if the
/// controller does not answer as a DWC2.
pub fn bringUp(host: *Host) bool {
    usb_otg.powerOn(host.number);
    const id = reg(host, dwc.GSNPSID).*;
    if (id & 0xFFFF_F000 != 0x4F54_2000 and id & 0xFFFF_F000 != 0x4F54_3000 and id & 0xFFFF_F000 != 0x4F54_4000) {
        sdk.exec.kprintf(host.sys, "%s: unit %d: no DWC2 there (0x%x)\n", .{ _usbotg.DEVICE_NAME, host.number, id });
        return false;
    }
    const hwcfg2 = reg(host, dwc.GHWCFG2).*;
    host.channel_count = @min(((hwcfg2 >> dwc.GHWCFG2_NUMHSTCHNL_SHIFT) & 0xF) + 1, _usbotg.max_channels);
    host.fifo_words = reg(host, dwc.GHWCFG3).* >> dwc.GHWCFG3_DFIFODEPTH_SHIFT;
    host.utmi = if (host.controller.utmi) 1 else 0;

    if (host.utmi != 0) {
        // The PHY was left suspended by the boot: the session override
        // off and the PHY's clock running again.
        reg(host, dwc.GOTGCTL).* &= ~dwc.GOTGCTL_BVALIDOVEN;
        reg(host, dwc.PCGCCTL).* &= ~dwc.PCGCCTL_STOPPCLK;
    }

    // The core's reset, from an idle bus to an idle bus.
    _ = pollFor(host, dwc.GRSTCTL, dwc.GRSTCTL_AHBIDL, dwc.GRSTCTL_AHBIDL, 100);
    reg(host, dwc.GRSTCTL).* |= dwc.GRSTCTL_CSFTRST;
    _ = pollFor(host, dwc.GRSTCTL, dwc.GRSTCTL_CSFTRST, 0, 100);
    _ = pollFor(host, dwc.GRSTCTL, dwc.GRSTCTL_AHBIDL, dwc.GRSTCTL_AHBIDL, 100);

    reg(host, dwc.GAHBCFG).* = dwc.GAHBCFG_DMAEN;
    var usbcfg = reg(host, dwc.GUSBCFG).*;
    usbcfg &= ~(dwc.GUSBCFG_SRPCAP | dwc.GUSBCFG_FORCEDEVMODE);
    const otg_mode = hwcfg2 & dwc.GHWCFG2_OTGMODE_MASK;
    // An HNP-capable core drives its data lines' pull-downs itself.
    if (otg_mode == 0) usbcfg |= dwc.GUSBCFG_HNPCAP;
    if (host.utmi != 0) {
        usbcfg = (usbcfg & ~(dwc.GUSBCFG_TOUTCAL_MASK | dwc.GUSBCFG_ULPIUTMISEL | dwc.GUSBCFG_PHYSEL)) |
            5 | dwc.GUSBCFG_PHYIF;
    }
    usbcfg |= dwc.GUSBCFG_FORCEHSTMODE;
    reg(host, dwc.GUSBCFG).* = usbcfg;
    // The forced mode takes up to 25 ms to hold.
    _usbotg.delay(host, 50);
    if (host.utmi != 0 and otg_mode == 0) {
        // The high-speed controller has no session comparators routed to
        // it on this chip: told that a session is there, as the A-device.
        reg(host, dwc.GOTGCTL).* |= dwc.GOTGCTL_VBVALIDOVEN | dwc.GOTGCTL_VBVALIDOVVAL |
            dwc.GOTGCTL_AVALIDOVEN | dwc.GOTGCTL_AVALIDOVVAL;
    }

    // The FIFO: half for what comes in, a quarter for what goes out to
    // bulk and control endpoints, the rest for the periodic ones.
    const rx = host.fifo_words / 2;
    const nptx = host.fifo_words / 4;
    const ptx = host.fifo_words - rx - nptx;
    reg(host, dwc.GRXFSIZ).* = rx;
    reg(host, dwc.GNPTXFSIZ).* = (nptx << 16) | rx;
    reg(host, dwc.HPTXFSIZ).* = (ptx << 16) | (rx + nptx);
    reg(host, dwc.GRSTCTL).* = dwc.GRSTCTL_TXFFLSH | dwc.GRSTCTL_TXFNUM_ALL;
    _ = pollFor(host, dwc.GRSTCTL, dwc.GRSTCTL_TXFFLSH, 0, 10);
    reg(host, dwc.GRSTCTL).* = dwc.GRSTCTL_RXFFLSH;
    _ = pollFor(host, dwc.GRSTCTL, dwc.GRSTCTL_RXFFLSH, 0, 10);

    var hcfg = reg(host, dwc.HCFG).* & ~(dwc.HCFG_FSLSPCLKSEL_MASK | dwc.HCFG_FSLSSUPP);
    if (host.utmi != 0) {
        hcfg |= dwc.HCFG_FSLSSUPP | dwc.HCFG_FSLSPCLKSEL_30_60MHZ;
    } else {
        hcfg |= dwc.HCFG_FSLSPCLKSEL_48MHZ;
    }
    reg(host, dwc.HCFG).* = hcfg;

    // Every channel stopped and quiet.
    var n: u32 = 0;
    while (n < host.channel_count) : (n += 1) {
        reg(host, dwc.hc(n) + dwc.HCINTMSK).* = 0;
        reg(host, dwc.hc(n) + dwc.HCINT).* = dwc.HCINT_ALL;
    }

    reg(host, dwc.GINTMSK).* = 0;
    reg(host, dwc.GINTSTS).* = 0xFFFF_FFFF;
    reg(host, dwc.HAINTMSK).* = (@as(u32, 1) << @intCast(host.channel_count)) - 1;
    reg(host, dwc.GINTMSK).* = dwc.GINTSTS_PRTINT | dwc.GINTSTS_HCHINT | dwc.GINTSTS_DISCONNINT;

    portWrite(host, dwc.HPRT_PRTPWR, 0);
    return true;
}

/// The core's interrupt line let through, once its server is hooked: a
/// line that was raised before the source was routed would otherwise
/// never be seen - the port's connect, for one, is pending from the
/// start.
pub fn interruptsOn(host: *Host) void {
    reg(host, dwc.GAHBCFG).* |= dwc.GAHBCFG_GLBLINTRMSK;
}

/// The core stopped: its interrupt line off, its port unpowered, the
/// controller held in reset.
pub fn shutDown(host: *Host) void {
    reg(host, dwc.GAHBCFG).* &= ~dwc.GAHBCFG_GLBLINTRMSK;
    reg(host, dwc.GINTMSK).* = 0;
    portWrite(host, 0, dwc.HPRT_PRTPWR);
    usb_otg.powerOff(host.number);
}

/// HPRT with `set` set and `clear` cleared, the bits that a 1 changes
/// left out so nothing is cleared or disabled by the write.
pub fn portWrite(host: *Host, set: u32, clear: u32) void {
    const now_value = reg(host, dwc.HPRT).* & ~dwc.HPRT_W1C_MASK;
    reg(host, dwc.HPRT).* = (now_value & ~clear) | set;
}

/// The PHY's clock for what was found on the root port: the full-speed
/// PHY counts a low-speed device's frames on its 6 MHz clock.
pub fn setPortClock(host: *Host) void {
    if (host.utmi != 0) return;
    const speed = (reg(host, dwc.HPRT).* >> dwc.HPRT_PRTSPD_SHIFT) & 3;
    const low = speed == dwc.HPRT_SPD_LOW;
    var hcfg = reg(host, dwc.HCFG).* & ~dwc.HCFG_FSLSPCLKSEL_MASK;
    hcfg |= if (low) 2 else dwc.HCFG_FSLSPCLKSEL_48MHZ;
    reg(host, dwc.HCFG).* = hcfg;
    reg(host, dwc.HFIR).* = if (low) 6000 else 48000;
}

// --- the interrupt ----------------------------------------------------------------

/// The controller's interrupt: what the port and each channel say, read,
/// cleared and left in the block for the task.
pub fn intServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const host: *Host = @ptrCast(@alignCast(is_data.?));
    const status = reg(host, dwc.GINTSTS).* & reg(host, dwc.GINTMSK).*;
    if (status == 0) return 0;
    var port: u32 = 0;
    if (status & dwc.GINTSTS_PRTINT != 0) {
        const hprt = reg(host, dwc.HPRT).*;
        const changed = hprt & (dwc.HPRT_PRTCONNDET | dwc.HPRT_PRTENCHNG | dwc.HPRT_PRTOVRCURRCHNG);
        reg(host, dwc.HPRT).* = (hprt & ~dwc.HPRT_W1C_MASK) | changed;
        port |= changed;
    }
    if (status & dwc.GINTSTS_DISCONNINT != 0) {
        reg(host, dwc.GINTSTS).* = dwc.GINTSTS_DISCONNINT;
        port |= _usbotg.event_disconnect;
    }
    var channels: [_usbotg.max_channels]u32 = @splat(0);
    if (status & dwc.GINTSTS_HCHINT != 0) {
        const haint = reg(host, dwc.HAINT).*;
        var n: u32 = 0;
        while (n < host.channel_count) : (n += 1) {
            if (haint & (@as(u32, 1) << @intCast(n)) == 0) continue;
            const hcint = reg(host, dwc.hc(n) + dwc.HCINT).*;
            reg(host, dwc.hc(n) + dwc.HCINT).* = hcint;
            channels[n] = hcint;
        }
    }
    // No lock: the task takes these inside Disable, which this interrupt
    // never runs in the middle of, on this core or the other.
    host.port_events |= port;
    for (channels, 0..) |hcint, n| host.chan_events[n] |= hcint;
    host.sys.Signal(&host.task, host.int_signal);
    return 1;
}

// --- requests ---------------------------------------------------------------------

/// Whether a request is for the root hub rather than the wire.
fn forRootHub(host: *Host, req: *usbhc.IOUsbHC) bool {
    return req.address == host.root.address;
}

/// The transfers that came in on the unit's port: the root hub's
/// answered, the rest queued for a channel.
pub fn takeRequests(host: *Host) void {
    const sys = host.sys;
    while (sys.GetMsg(&host.unit.msg_port)) |msg| {
        const req = _usbotg.requestOf(msg);
        req.hc_private[_usbotg.PRIV_FLAGS] = 0;
        req.hc_private[_usbotg.PRIV_DUE] = 0;
        req.std.actual = 0;
        if (forRootHub(host, req)) {
            roothub.handle(host, req);
            continue;
        }
        if (host.root.status & d.USB_PORT_STAT_ENABLE == 0) {
            _usbotg.reply(host, req, usbhc.UHIOERR_DETACHED);
            continue;
        }
        if (req.nak_timeout != 0) {
            req.hc_private[_usbotg.PRIV_FLAGS] |= _usbotg.PRIVF_DEADLINE;
            req.hc_private[_usbotg.PRIV_DUE] = _usbotg.now(host) +% req.nak_timeout;
        }
        sys.AddTail(&host.waiting, _usbotg.nodeOf(req));
    }
}

/// What the interrupt left: each channel's halt dealt with, the port's
/// changes handed to the root hub.
pub fn takeEvents(host: *Host) void {
    const sys = host.sys;
    var channels: [_usbotg.max_channels]u32 = undefined;
    sys.Disable();
    const port = host.port_events;
    host.port_events = 0;
    channels = host.chan_events;
    host.chan_events = @splat(0);
    sys.Enable();

    if (port != 0) roothub.portChanged(host, port);
    var n: u32 = 0;
    while (n < host.channel_count) : (n += 1) {
        if (channels[n] & dwc.HCINT_CHHLTD == 0) continue;
        if (host.channels[n].request == null) continue;
        halted(host, n, channels[n]);
    }
}

/// Every transfer that can start, started: parked ones whose turn has
/// come first, then waiting ones, while channels are free.
pub fn schedule(host: *Host) void {
    const sys = host.sys;
    const time = _usbotg.now(host);
    var it = host.parked.iterator();
    while (it.next()) |node| {
        const req = _usbotg.requestOfNode(node);
        if (!_usbotg.reached(time, @truncate(req.hc_private[_usbotg.PRIV_DUE]))) continue;
        sys.Remove(node);
        sys.AddHead(&host.waiting, node);
    }
    while (freeChannel(host)) |n| {
        const node = sys.RemHead(&host.waiting) orelse break;
        start(host, n, _usbotg.requestOfNode(node));
    }
    armTick(host, time);
}

fn freeChannel(host: *Host) ?u32 {
    var n: u32 = 0;
    while (n < host.channel_count) : (n += 1) {
        if (host.channels[n].request == null) return n;
    }
    return null;
}

/// The tick armed for the earliest of the parked transfers' turns and
/// the running ones' deadlines; left alone if nothing waits on time.
fn armTick(host: *Host, time: u32) void {
    var due: ?u32 = null;
    var it = host.parked.iterator();
    while (it.next()) |node| {
        const when: u32 = @truncate(_usbotg.requestOfNode(node).hc_private[_usbotg.PRIV_DUE]);
        if (due == null or !_usbotg.reached(when, due.?)) due = when;
    }
    for (host.channels[0..host.channel_count]) |*channel| {
        const req = channel.request orelse continue;
        if (req.hc_private[_usbotg.PRIV_FLAGS] & _usbotg.PRIVF_DEADLINE == 0) continue;
        const when: u32 = @truncate(req.hc_private[_usbotg.PRIV_DUE]);
        if (due == null or !_usbotg.reached(when, due.?)) due = when;
    }
    const when = due orelse return;
    if (host.tick_armed != 0) {
        if (_usbotg.reached(when, host.tick_due)) return;
        dropTick(host);
    }
    const wait_ms: u32 = if (_usbotg.reached(time, when)) 1 else when -% time;
    host.tick_io.node.command = timer.TR_ADDREQUEST;
    host.tick_io.time = timer.TimeVal.fromMicros(@as(u64, wait_ms) * 1000);
    host.sys.SendIO(&host.tick_io.node);
    host.tick_armed = 1;
    host.tick_due = when;
}

pub fn dropTick(host: *Host) void {
    if (host.tick_armed == 0) return;
    _ = host.sys.AbortIO(&host.tick_io.node);
    _ = host.sys.WaitIO(&host.tick_io.node);
    host.tick_armed = 0;
}

/// The tick came: its request taken back, and running transfers past
/// their NAK deadline halted.
pub fn tick(host: *Host) void {
    if (host.tick_armed != 0 and host.sys.CheckIO(&host.tick_io.node) != null) {
        _ = host.sys.WaitIO(&host.tick_io.node);
        host.tick_armed = 0;
    }
    const time = _usbotg.now(host);
    for (host.channels[0..host.channel_count], 0..) |*channel, n| {
        const req = channel.request orelse continue;
        if (req.hc_private[_usbotg.PRIV_FLAGS] & _usbotg.PRIVF_DEADLINE == 0) continue;
        if (!_usbotg.reached(time, @truncate(req.hc_private[_usbotg.PRIV_DUE]))) continue;
        haltChannel(host, @intCast(n));
    }
}

/// Requests AbortIO marked: taken off the lists and answered, or their
/// channel halted, which answers them.
pub fn takeAborts(host: *Host) void {
    for ([_]*exec.List{ &host.waiting, &host.parked }) |list| {
        var it = list.iterator();
        while (it.next()) |node| {
            const req = _usbotg.requestOfNode(node);
            if (req.hc_private[_usbotg.PRIV_ABORT] == 0) continue;
            host.sys.Remove(node);
            _usbotg.reply(host, req, exec.IOERR_ABORTED);
        }
    }
    for (host.channels[0..host.channel_count], 0..) |*channel, n| {
        const req = channel.request orelse continue;
        if (req.hc_private[_usbotg.PRIV_ABORT] != 0) haltChannel(host, @intCast(n));
    }
    roothub.takeAbort(host);
}

/// Every transfer on the wire or waiting answered `err`: the device on
/// the root port went, or the controller stops.
pub fn failAll(host: *Host, err: i8) void {
    for (host.channels[0..host.channel_count], 0..) |*channel, n| {
        const req = channel.request orelse continue;
        haltChannel(host, @intCast(n));
        channel.request = null;
        channel.stage = .idle;
        req.std.actual = channel.done;
        _usbotg.reply(host, req, err);
    }
    for ([_]*exec.List{ &host.waiting, &host.parked }) |list| {
        while (host.sys.RemHead(list)) |node| _usbotg.reply(host, _usbotg.requestOfNode(node), err);
    }
}

// --- channels ---------------------------------------------------------------------

/// A channel stopped where it is; its interrupt then says so.
fn haltChannel(host: *Host, n: u32) void {
    const hcchar = reg(host, dwc.hc(n) + dwc.HCCHAR).*;
    if (hcchar & dwc.HCCHAR_CHENA == 0) return;
    reg(host, dwc.hc(n) + dwc.HCCHAR).* = hcchar | dwc.HCCHAR_CHDIS | dwc.HCCHAR_CHENA;
}

/// A transfer onto channel `n`: a control transfer from its setup stage,
/// the others from their first round.
fn start(host: *Host, n: u32, req: *usbhc.IOUsbHC) void {
    const channel = &host.channels[n];
    channel.* = .{ .bounce = channel.bounce };
    channel.request = req;
    channel.stage = if (req.std.req.command == usbhc.UHCMD_CONTROLXFER) .setup else .data;
    program(host, n);
}

/// The transfer's direction for its current stage: true for IN.
fn stageIn(channel: *const Channel, req: *const usbhc.IOUsbHC) bool {
    return switch (channel.stage) {
        .setup => false,
        .data => if (req.std.req.command == usbhc.UHCMD_CONTROLXFER)
            req.setup.request_type & d.USB_DIR_IN != 0
        else
            req.endpoint & d.USB_DIR_IN != 0,
        // The status stage goes the other way from the data, IN when
        // there was none.
        .status => req.std.length == 0 or req.setup.request_type & d.USB_DIR_IN == 0,
        .idle => false,
    };
}

/// The channel's registers set for its transfer's current stage and
/// round, and the channel started.
fn program(host: *Host, n: u32) void {
    const sys = host.sys;
    const channel = &host.channels[n];
    const req = channel.request.?;
    const mps: u32 = @max(req.max_packet, 1);
    const in = stageIn(channel, req);
    const command = req.std.req.command;
    const total: u32 = @intCast(req.std.length);

    var bytes: u32 = 0;
    var pid: u32 = dwc.HCTSIZ_PID_DATA1;
    var ep_type: u32 = dwc.HCCHAR_EPTYPE_CONTROL;
    switch (channel.stage) {
        .setup => {
            const setup_bytes: *const [8]u8 = @ptrCast(&req.setup);
            @memcpy(channel.bounce[0..8], setup_bytes);
            bytes = 8;
            pid = dwc.HCTSIZ_PID_SETUP;
        },
        .status => {},
        .data => {
            const left = total - channel.done;
            const room = _usbotg.bounce_bytes - _usbotg.bounce_bytes % mps;
            if (in) {
                // Whole packets: the device may send a full one however
                // little is left to fill.
                bytes = @min(((left + mps - 1) / mps) * mps, room);
                if (bytes == 0) bytes = mps;
            } else {
                bytes = @min(left, room);
                if (bytes != 0) {
                    const from: [*]const u8 = @ptrCast(req.std.data.?);
                    @memcpy(channel.bounce[0..bytes], from[channel.done..][0..bytes]);
                }
            }
            if (command != usbhc.UHCMD_CONTROLXFER) {
                pid = if (req.toggle != 0) dwc.HCTSIZ_PID_DATA1 else dwc.HCTSIZ_PID_DATA0;
                ep_type = if (command == usbhc.UHCMD_INTXFER) dwc.HCCHAR_EPTYPE_INTERRUPT else dwc.HCCHAR_EPTYPE_BULK;
            }
        },
        .idle => return,
    }
    const packets: u32 = if (bytes == 0) 1 else (bytes + mps - 1) / mps;
    channel.round_bytes = bytes;
    channel.round_packets = packets;

    // What the controller reads written out of the cache; what it will
    // write over written out too, so no dirty line lands on it later.
    var length = @max(bytes, 4);
    const dma_address = sys.CachePreDMA(channel.bounce, &length, if (in) 0 else exec.DMAF_ReadFromRAM);

    var hcchar: u32 = (mps & dwc.HCCHAR_MPS_MASK) |
        (@as(u32, req.endpoint & d.USB_ENDPOINT_NUMBER_MASK) << dwc.HCCHAR_EPNUM_SHIFT) |
        (ep_type << dwc.HCCHAR_EPTYPE_SHIFT) |
        (@as(u32, 1) << dwc.HCCHAR_EC_SHIFT) |
        (@as(u32, req.address) << dwc.HCCHAR_DEVADDR_SHIFT);
    if (in) hcchar |= dwc.HCCHAR_EPDIR;
    if (_usbotg.isLow(req)) hcchar |= dwc.HCCHAR_LSPDDEV;
    if (ep_type == dwc.HCCHAR_EPTYPE_INTERRUPT) {
        // A periodic transfer goes in the frame after this one.
        if (reg(host, dwc.HFNUM).* & 1 == 0) hcchar |= dwc.HCCHAR_ODDFRM;
    }
    const base = dwc.hc(n);
    reg(host, base + dwc.HCSPLT).* = 0;
    reg(host, base + dwc.HCINT).* = dwc.HCINT_ALL;
    reg(host, base + dwc.HCINTMSK).* = dwc.HCINT_CHHLTD | dwc.HCINT_AHBERR;
    reg(host, base + dwc.HCTSIZ).* = bytes | (packets << dwc.HCTSIZ_PKTCNT_SHIFT) | (pid << dwc.HCTSIZ_PID_SHIFT);
    reg(host, base + dwc.HCDMA).* = @intCast(@intFromPtr(dma_address));
    reg(host, base + dwc.HCCHAR).* = hcchar | dwc.HCCHAR_CHENA;
}

/// The channel's transfer ended, answered `err` with what it moved.
fn finish(host: *Host, n: u32, err: i8) void {
    const channel = &host.channels[n];
    const req = channel.request orelse return;
    channel.request = null;
    channel.stage = .idle;
    req.std.actual = channel.done;
    _usbotg.reply(host, req, err);
}

/// Channel `n` has halted, with `hcint` saying why: the next round or
/// stage started, the request parked, or answered.
fn halted(host: *Host, n: u32, hcint: u32) void {
    const sys = host.sys;
    const channel = &host.channels[n];
    const req = channel.request.?;
    const flags = req.hc_private[_usbotg.PRIV_FLAGS];

    if (req.hc_private[_usbotg.PRIV_ABORT] != 0) return finish(host, n, exec.IOERR_ABORTED);
    if (hcint & dwc.HCINT_AHBERR != 0) return finish(host, n, usbhc.UHIOERR_HOSTERROR);
    if (hcint & dwc.HCINT_STALL != 0) {
        req.toggle = 0;
        return finish(host, n, usbhc.UHIOERR_STALL);
    }
    if (hcint & dwc.HCINT_BBLERR != 0) return finish(host, n, usbhc.UHIOERR_OVERFLOW);
    if (hcint & (dwc.HCINT_XACTERR | dwc.HCINT_DATATGLERR | dwc.HCINT_FRMOVRUN) != 0) {
        channel.errors += 1;
        if (channel.errors >= _usbotg.max_errors) return finish(host, n, usbhc.UHIOERR_CRCERROR);
        return program(host, n);
    }
    // An interrupt endpoint that sent packets and then had nothing more
    // has ended the transfer with what it sent: what came is kept.
    const nak_after_data = hcint & dwc.HCINT_NAK != 0 and req.std.req.command == usbhc.UHCMD_INTXFER and
        channel.stage == .data and stageIn(channel, req) and
        channel.round_bytes -| (reg(host, dwc.hc(n) + dwc.HCTSIZ).* & dwc.HCTSIZ_XFERSIZE_MASK) != 0;
    if (hcint & dwc.HCINT_XFERCOMPL == 0 and !nak_after_data) {
        if (flags & _usbotg.PRIVF_DEADLINE != 0 and
            _usbotg.reached(_usbotg.now(host), @truncate(req.hc_private[_usbotg.PRIV_DUE])))
            return finish(host, n, usbhc.UHIOERR_NAKTIMEOUT);
        if (hcint & dwc.HCINT_NAK != 0 and req.std.req.command == usbhc.UHCMD_INTXFER) {
            // Nothing yet: asked again once its interval has passed.
            channel.request = null;
            channel.stage = .idle;
            req.hc_private[_usbotg.PRIV_DUE] = _usbotg.now(host) +% @max(req.interval, 1);
            sys.AddTail(&host.parked, _usbotg.nodeOf(req));
            return;
        }
        // Halted for no reason it gave: started again.
        return program(host, n);
    }
    channel.errors = 0;

    const tsiz = reg(host, dwc.hc(n) + dwc.HCTSIZ).*;
    const bytes_left = tsiz & dwc.HCTSIZ_XFERSIZE_MASK;
    const packets_left = (tsiz & dwc.HCTSIZ_PKTCNT_MASK) >> dwc.HCTSIZ_PKTCNT_SHIFT;
    const in = stageIn(channel, req);
    var packets = channel.round_packets -| packets_left;
    // What an IN round moved is what its size field no longer counts. An
    // OUT round's is its packets': the ESP32-P4's high-speed core leaves
    // the size of an OUT transfer as it was programmed and counts only
    // the packets down - read as bytes, a block sent whole would look
    // unsent, and go again.
    const moved = if (in)
        channel.round_bytes -| bytes_left
    else
        @min(channel.round_bytes, packets * @as(u32, @max(req.max_packet, 1)));
    if (packets == 0) packets = 1;

    switch (channel.stage) {
        .setup => {
            channel.stage = if (req.std.length == 0) .status else .data;
            return program(host, n);
        },
        .status => return finish(host, n, 0),
        .data => {},
        .idle => return,
    }

    const total: u32 = @intCast(req.std.length);
    var err: i8 = 0;
    if (req.std.req.command != usbhc.UHCMD_CONTROLXFER and packets & 1 != 0) req.toggle ^= 1;
    if (in) {
        var length = moved;
        sys.CachePostDMA(channel.bounce, &length, 0);
        const room = total - channel.done;
        const take = @min(moved, room);
        if (take != 0) {
            const into: [*]u8 = @ptrCast(req.std.data.?);
            @memcpy(into[channel.done..][0..take], channel.bounce[0..take]);
        }
        if (moved > room) err = usbhc.UHIOERR_OVERFLOW;
        channel.done += take;
    } else {
        channel.done += moved;
    }
    const short = (in and moved < channel.round_bytes) or nak_after_data;
    if (err != 0) return finish(host, n, err);
    if (short and req.flags & usbhc.UHF_SHORT_NOT_OK != 0) return finish(host, n, usbhc.UHIOERR_RUNTPACKET);
    if (!short and channel.done < total) return program(host, n);
    if (!in and !channel.zero_sent and channel.done != 0 and req.flags & usbhc.UHF_ZERO_PACKET != 0 and
        channel.done % @max(req.max_packet, 1) == 0 and req.std.req.command == usbhc.UHCMD_BULKXFER)
    {
        // A whole number of packets, ended with an empty one.
        channel.zero_sent = true;
        return program(host, n);
    }
    if (req.std.req.command == usbhc.UHCMD_CONTROLXFER) {
        channel.stage = .status;
        return program(host, n);
    }
    finish(host, n, 0);
}
