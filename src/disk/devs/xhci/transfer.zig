// SPDX-License-Identifier: MIT
//! Transfers: requests taken, queued on their endpoint, put on its ring
//! as TDs, and answered from their transfer events.
//!
//! **One TD per ring at a time.** A request waits on its endpoint's list
//! until the one before it is answered; the controller then has the
//! endpoint's ring to itself, and a stop or a halt never leaves another
//! TD behind it to be dealt with. An isochronous endpoint is the one
//! that has more: see below.
//!
//! **A control transfer** is one TD: a Setup Stage TRB with the setup
//! packet in it, a Data Stage TRB when there is data - interrupting on a
//! short packet, which says how much came - and a Status Stage TRB that
//! interrupts as the TD ends. A bulk or interrupt transfer goes in
//! rounds of its endpoint's buffer, a Normal TRB each: an IN round that
//! comes back short ends the transfer; an OUT transfer that asked for it
//! ends with an empty packet. The controller asks an interrupt endpoint
//! at its interval by itself until the device answers.
//!
//! **The data passes through the endpoint's buffer**, DMA memory as big
//! as the largest control or interrupt transfer it had (at least 4 KiB)
//! and aligned to its size, so a TRB's buffer never crosses a 64 KiB
//! boundary; a bulk endpoint's is 16 KiB.
//!
//! **What a transfer's end shows the controller** is kept: a
//! configuration read whole, for SET_CONFIGURATION (slots.zig). A hub's
//! descriptor, and a hub's port status that shows its device gone, are
//! answered only after the task has told the controller (`posted`).
//!
//! **An isochronous transfer** is a TD a packet - an Isoch TRB with the
//! frame it goes in and, where a packet is an interval's bursts, the
//! bursts it takes (`regs.isochBurstFields`) - and up to `iso_in_flight`
//! requests are on the ring at once, so the next is there before the
//! last has played. Where a request starts is `isoPlan`'s: in the frame
//! after the one before it while the stream runs, its packets too late
//! for that marked missed without going on the ring; as soon as the
//! controller can place it (`iso_lead` frames on) when the ring ran dry,
//! the frames between counted as its gap; in the frame it names with
//! UHF_ISO_FRAME. Every
//! TRB interrupts, and its event says what became of its packet; a run
//! of missed TDs the controller tells once, at its end, so every TD the
//! endpoint's `expect` passes on the way to an event's was missed. The
//! event of a request's last TD answers it. Each request's packets go in
//! a slice of the endpoint's buffer, a stride apart (`strideOf`); the
//! slices are taken round in turn, as the requests are answered in turn.
//! Nothing halts and nothing is resent. Taking one back stops the
//! endpoint, answers every one on it and ends the stream.
//!
//! **An error** halts the endpoint on the controller: the request is
//! answered, and the endpoint reset - Reset Endpoint, its ring's dequeue
//! pointer set past the TD - before the next one (`recover`). A request
//! whose NAK timeout passes, or that AbortIO asks for, has its endpoint
//! stopped (Stop Endpoint) and its ring moved on the same way (`cancel`).

const sdk = @import("sdk");
const exec = sdk.exec;
const usbhc = sdk.devices.usbhc;
const timer = sdk.devices.timer;
const d = sdk.usb.descriptors;
const regs = @import("regs.zig");
const ring = @import("ring.zig");
const Trb = ring.Trb;
const _xhci = @import("_xhci.zig");
const Host = _xhci.Host;
const Slot = _xhci.Slot;
const Endpoint = _xhci.Endpoint;
const controller = @import("controller.zig");
const roothub = @import("roothub.zig");
const slots = @import("slots.zig");

// --- requests coming in -----------------------------------------------------------

/// The transfers on the unit's port: the root hub's answered, the rest
/// queued on their endpoints - what the controller is to be told first
/// told.
pub fn takeRequests(host: *Host) void {
    const sys = host.sys;
    while (sys.GetMsg(&host.unit.msg_port)) |msg| {
        const req = _xhci.requestOf(msg);
        req.hc_private[_xhci.PRIV_FLAGS] = 0;
        req.hc_private[_xhci.PRIV_DUE] = 0;
        req.std.actual = 0;
        if (req.address == host.root.address) {
            roothub.handle(host, req);
            continue;
        }
        accept(host, req);
    }
}

fn isRequest(setup: d.SetupPacket, request_type: u8, request: u8) bool {
    return setup.request_type == request_type and setup.request == request;
}

/// A request for a device: its slot found - made, for address 0 - and
/// queued on its endpoint.
fn accept(host: *Host, req: *usbhc.IOUsbHC) void {
    const control = req.std.req.command == usbhc.UHCMD_CONTROLXFER;
    if (req.address == 0 and control and isRequest(req.setup, d.USB_DIR_OUT, d.USB_REQ_SET_ADDRESS)) {
        return _xhci.reply(host, req, slots.setAddress(host, req));
    }
    const slot = (if (req.address == 0) slots.defaultSlot(host, req) else _xhci.slotAt(host, req.address)) orelse {
        return _xhci.reply(host, req, usbhc.UHIOERR_DETACHED);
    };
    var dci: u32 = 1;
    if (control) {
        if (!slots.checkPacketSize(host, slot, req)) return _xhci.reply(host, req, usbhc.UHIOERR_HOSTERROR);
        const setup = req.setup;
        if (isRequest(setup, d.USB_DIR_OUT, d.USB_REQ_SET_CONFIGURATION)) {
            if (!slots.configure(host, slot, @truncate(setup.value))) return _xhci.reply(host, req, usbhc.UHIOERR_HOSTERROR);
        } else if (isRequest(setup, d.USB_DIR_OUT | d.USB_RT_PORT, d.USB_REQ_SET_FEATURE) and
            (setup.value == d.USB_PORT_FEAT_RESET or setup.value == d.USB_PORT_FEAT_BH_PORT_RESET))
        {
            slots.noteReset(host, slot.id, @truncate(setup.index));
        }
    } else {
        dci = regs.dciOf(req.endpoint);
        if (req.std.req.command == usbhc.UHCMD_ISOXFER) {
            req.iso_lost = 0;
            req.iso_gap = 0;
            if (!isoFits(host, req)) return _xhci.reply(host, req, exec.IOERR_BADLENGTH);
        }
        if (dci < 2) return _xhci.reply(host, req, usbhc.UHIOERR_HOSTERROR);
        const refused = slots.ensureEndpoint(host, slot, dci, req);
        if (refused != 0) return _xhci.reply(host, req, refused);
    }
    if (req.nak_timeout != 0 and req.std.req.command != usbhc.UHCMD_ISOXFER) {
        req.hc_private[_xhci.PRIV_FLAGS] |= _xhci.PRIVF_DEADLINE;
        req.hc_private[_xhci.PRIV_DUE] = _xhci.now(host) +% req.nak_timeout;
    }
    host.sys.AddTail(&slot.endpoints[dci].queue, _xhci.nodeOf(req));
}

// --- TDs onto the rings -----------------------------------------------------------

/// Every endpoint with nothing on its ring given its next request.
pub fn schedule(host: *Host) void {
    for (host.slots[1..]) |entry| {
        const slot = entry orelse continue;
        if (!slot.enabled) continue;
        var dci: u32 = 1;
        while (dci <= slot.entries) : (dci += 1) {
            const ep = &slot.endpoints[dci];
            while (_xhci.hasRoom(ep)) {
                const node = host.sys.RemHead(&ep.queue) orelse break;
                const req = _xhci.requestOfNode(node);
                if (_xhci.isIso(ep)) startIso(host, slot, dci, ep, req) else start(host, slot, dci, req);
            }
        }
    }
}

/// An isochronous request's packets: its list's, or its length cut into
/// `iso_packet` bytes; 0 for none.
fn isoPackets(req: *const usbhc.IOUsbHC) u32 {
    if (req.iso_list != null) return req.iso_count;
    const packet = isoPacket(req);
    if (packet == 0) return 0;
    const length: u32 = @intCast(req.std.length);
    return (length + packet - 1) / packet;
}

/// The most an isochronous packet carries: an interval's bytes where the
/// endpoint moves more than a packet an interval - a TD of several wire
/// packets, whose bursts its Isoch TRB says (from xHCI 1.0) - else a
/// packet's.
fn isoMost(host: *const Host, req: *const usbhc.IOUsbHC) u32 {
    const packet: u32 = @max(req.max_packet & 0x7FF, 1);
    if (host.version < 0x100 or req.interval_bytes <= packet) return packet;
    return req.interval_bytes;
}

fn isoPacket(req: *const usbhc.IOUsbHC) u32 {
    return if (req.iso_packet != 0) req.iso_packet else req.max_packet;
}

/// Whether a request's packets fit a transfer: one to UHC_ISO_PACKETS of
/// them, none bigger than `isoMost`, all in its data.
fn isoFits(host: *const Host, req: *const usbhc.IOUsbHC) bool {
    const packets = isoPackets(req);
    if (packets == 0 or packets > usbhc.UHC_ISO_PACKETS) return false;
    const most = isoMost(host, req);
    const list = req.iso_list orelse return isoPacket(req) <= most;
    var total: u32 = 0;
    for (list[0..packets]) |entry| {
        if (entry.length > most) return false;
        total += entry.length;
    }
    return total <= req.std.length;
}

/// Packet `n`'s bytes, and where it lies in the request's data: as its
/// list says, or `iso_packet` each, the last taking what is left.
fn isoAsked(req: *const usbhc.IOUsbHC, n: u32) u32 {
    if (req.iso_list) |list| return list[n].length;
    const packet = isoPacket(req);
    const length: u32 = @intCast(req.std.length);
    return @min(packet, length - n * packet);
}

fn isoOffset(req: *const usbhc.IOUsbHC, n: u32) u32 {
    const list = req.iso_list orelse return n * isoPacket(req);
    var offset: u32 = 0;
    for (list[0..n]) |entry| offset += entry.length;
    return offset;
}

/// Where an isochronous request goes: the frame of its first packet, the
/// frames the endpoint goes without before it, the packets too late to
/// go - or refused, for a frame asked for that cannot be had.
pub const IsoPlan = struct {
    start: u32 = 0,
    gap: u32 = 0,
    late: u32 = 0,
    refused: bool = false,
};

/// `a` comes before `b`, counted round.
fn before(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}

/// A request of `packets` packets, `every` frames apart, placed: `now`
/// the frame the controller is in, `lead` how far ahead it must have a
/// TD, `asked` the frame number UHF_ISO_FRAME names. While the stream
/// runs (`flying` requests on the ring) it follows on at `next`, its
/// packets before `now + lead` missed - or, all of them too late, as
/// soon as it can, the frames between its gap. A stream run dry follows
/// on at `next` if that is still ahead, else starts as soon as it can,
/// the frames since its gap. A new stream starts as soon as it can.
pub fn isoPlan(now: u32, lead: u32, streaming: bool, flying: u32, next: u32, asked: ?u16, packets: u32, every: u32) IsoPlan {
    const soonest = now +% lead;
    if (asked) |frame| {
        const ahead = (@as(u32, frame) -% now) & (usbhc.UHC_FRAMES - 1);
        if (ahead < lead or ahead > usbhc.UHC_ISO_AHEAD) return .{ .refused = true };
        const first = now +% ahead;
        return .{ .start = first, .gap = if (streaming and before(next, first)) first -% next else 0 };
    }
    if (!streaming) return .{ .start = soonest };
    if (!before(next, soonest)) return .{ .start = next };
    const behind = soonest -% next;
    if (flying != 0) {
        const late = (behind + every - 1) / every;
        if (late < packets) return .{ .start = next, .late = late };
    }
    return .{ .start = soonest, .gap = behind };
}

/// A packet's frames apart: the endpoint's interval, at least a frame.
fn framesApart(ep: *const Endpoint) u32 {
    if (ep.interval <= 3) return 1;
    return @as(u32, 1) << @intCast(ep.interval - 3);
}

/// An isochronous request's TDs: placed by `isoPlan`, its late packets
/// marked missed, each other packet - an OUT one copied to its place in
/// the next slice of the buffer - an Isoch TRB in its frame, every one
/// interrupting; the request on the endpoint's flight.
fn startIso(host: *Host, slot: *Slot, dci: u32, ep: *Endpoint, req: *usbhc.IOUsbHC) void {
    const slice_bytes = usbhc.UHC_ISO_PACKETS * ep.stride;
    if (!ensureBounce(host, ep, _xhci.iso_in_flight * slice_bytes)) return _xhci.reply(host, req, usbhc.UHIOERR_HOSTERROR);
    const packets = isoPackets(req);
    const every = framesApart(ep);
    const asked: ?u16 = if (req.flags & usbhc.UHF_ISO_FRAME != 0) req.iso_frame else null;
    const plan = isoPlan(_xhci.currentFrame(host), host.iso_lead, ep.streaming, ep.flying, ep.next_frame, asked, packets, every);
    if (plan.refused) return _xhci.reply(host, req, usbhc.UHIOERR_MISSED);
    req.iso_frame = @truncate(plan.start & (usbhc.UHC_FRAMES - 1));
    req.iso_gap = @truncate(@min(plan.gap, 0xFFFF));
    var n: u32 = 0;
    while (n < plan.late) : (n += 1) record(host, ep, req, n, usbhc.UHIOERR_MISSED, 0);

    const slice = ep.next_slice;
    ep.next_slice = (slice + 1) % _xhci.iso_in_flight;
    const area = ep.bounce.? + slice * slice_bytes;
    const in = isIn(req);
    if (ep.flying == 0) ep.expect = ep.ring.enqueue;
    const first = ep.ring.enqueue;
    var last: u32 = first;
    while (n < packets) : (n += 1) {
        const bytes = isoAsked(req, n);
        const into = area + n * ep.stride;
        if (!in) @memcpy(into[0..bytes], dataOf(req)[isoOffset(req, n)..][0..bytes]);
        const buffer: u64 = @intFromPtr(into);
        const bursts = if (host.version < 0x100) 0 else regs.isochBurstFields(bytes, ep.max_packet, ep.burst, slot.speed >= regs.SPEED_SUPER);
        const at = ep.ring.push(.{
            .param_lo = ring.lo(buffer),
            .param_hi = ring.hi(buffer),
            .status = bytes,
            .control = regs.typeField(regs.TRB_ISOCH) | regs.frameIdField(plan.start +% n * every) | bursts | regs.TRB_IOC,
        });
        last = indexOf(ep, at);
    }
    if (!in) _xhci.toDevice(host, @intFromPtr(area), slice_bytes);
    req.hc_private[_xhci.PRIV_LATE] = plan.late;
    req.hc_private[_xhci.PRIV_SPAN] = _xhci.spanOf(first, last, slice);
    host.sys.AddTail(&ep.flight, _xhci.nodeOf(req));
    ep.flying += 1;
    ep.streaming = true;
    ep.next_frame = plan.start +% packets * every;
    _xhci.toDevice(host, @intFromPtr(ep.ring.trbs), ep.ring.bytes());
    _xhci.ringDoorbell(host, slot.id, dci);
}

/// What became of an isochronous request's packet `n`: its list told,
/// its bytes counted - an IN packet's copied to its place in the data -
/// a lost one counted.
fn record(host: *Host, ep: *Endpoint, req: *usbhc.IOUsbHC, n: u32, status: i8, got: u32) void {
    if (req.iso_list) |list| {
        list[n].actual = @truncate(got);
        list[n].status = status;
    }
    if (status != 0) req.iso_lost += 1;
    if (got == 0) return;
    req.std.actual += got;
    if (!isIn(req)) return;
    const slice = _xhci.spanSlice(req.hc_private[_xhci.PRIV_SPAN]);
    const from = ep.bounce.? + slice * usbhc.UHC_ISO_PACKETS * ep.stride + n * ep.stride;
    _xhci.fromDevice(host, @intFromPtr(from), got);
    @memcpy(dataOf(req)[isoOffset(req, n)..][0..got], from[0..got]);
}

/// A TRB's place on its endpoint's ring, from its address.
fn indexOf(ep: *const Endpoint, address: usize) u32 {
    return @intCast((address - @intFromPtr(ep.ring.trbs)) / @sizeOf(Trb));
}

/// How many TDs on from `from` the one at `index` is, on a ring of
/// `count` TRBs: its last is the Link, which is none.
pub fn ringDistance(from: u32, index: u32, count: u32) u32 {
    return (index + count - 1 - from) % (count - 1);
}

/// The TD after the one at `index`, past the Link.
fn nextIndex(index: u32, count: u32) u32 {
    return if (index + 1 == count - 1) 0 else index + 1;
}

fn isIn(req: *const usbhc.IOUsbHC) bool {
    if (req.std.req.command == usbhc.UHCMD_CONTROLXFER) return req.setup.request_type & d.USB_DIR_IN != 0;
    return req.endpoint & d.USB_DIR_IN != 0;
}

fn dataOf(req: *const usbhc.IOUsbHC) [*]u8 {
    return @ptrCast(req.std.data.?);
}

/// The endpoint's buffer at least `bytes` big: made, or made again
/// bigger, aligned to its size. False without the memory.
fn ensureBounce(host: *Host, ep: *Endpoint, bytes: u32) bool {
    if (ep.bounce != null and ep.bounce_size >= bytes) return true;
    var size = _xhci.bounce_min;
    while (size < bytes) size *= 2;
    var raw: ?*anyopaque = null;
    const memory = _xhci.allocDma(host, size, size, &raw) orelse return false;
    if (ep.bounce_raw) |old| host.sys.FreeMem(old, ep.bounce_raw_size);
    ep.bounce = memory;
    ep.bounce_size = size;
    ep.bounce_raw = raw;
    ep.bounce_raw_size = @intCast(_xhci.roundUp(size, _xhci.dma_align) + size);
    return true;
}

fn start(host: *Host, slot: *Slot, dci: u32, req: *usbhc.IOUsbHC) void {
    const ep = &slot.endpoints[dci];
    ep.current = req;
    ep.done = 0;
    ep.short = false;
    ep.zero = false;
    if (req.std.req.command == usbhc.UHCMD_CONTROLXFER) {
        if (!startControl(host, slot, ep, req)) finish(host, slot, ep, usbhc.UHIOERR_HOSTERROR);
        return;
    }
    const length: u32 = @intCast(req.std.length);
    ep.zero = !isIn(req) and req.flags & usbhc.UHF_ZERO_PACKET != 0 and length != 0 and length % ep.max_packet == 0;
    if (!startRound(host, slot, dci, ep, req)) finish(host, slot, ep, usbhc.UHIOERR_HOSTERROR);
}

/// A control transfer's TD: setup, data, status.
fn startControl(host: *Host, slot: *Slot, ep: *Endpoint, req: *usbhc.IOUsbHC) bool {
    const setup = req.setup;
    const length: u32 = @min(@as(u32, @intCast(req.std.length)), setup.length);
    const in = setup.request_type & d.USB_DIR_IN != 0;
    if (length != 0) {
        if (!ensureBounce(host, ep, length)) return false;
        if (!in) {
            @memcpy(ep.bounce.?[0..length], dataOf(req)[0..length]);
            _xhci.toDevice(host, @intFromPtr(ep.bounce.?), length);
        }
    }
    const bytes: [8]u8 = @bitCast(setup);
    const transfer_type = if (length == 0) regs.TRT_NONE else if (in) regs.TRT_IN else regs.TRT_OUT;
    _ = ep.ring.push(.{
        .param_lo = @bitCast(bytes[0..4].*),
        .param_hi = @bitCast(bytes[4..8].*),
        .status = 8,
        .control = regs.typeField(regs.TRB_SETUP) | regs.TRB_IDT | transfer_type,
    });
    ep.data_trb = 0;
    if (length != 0) {
        const buffer: u64 = @intFromPtr(ep.bounce.?);
        ep.data_trb = ep.ring.push(.{
            .param_lo = ring.lo(buffer),
            .param_hi = ring.hi(buffer),
            .status = length,
            .control = regs.typeField(regs.TRB_DATA) | regs.TRB_ISP | (if (in) regs.TRB_DIR_IN else 0),
        });
    }
    // The status stage goes the other way from the data, IN without any.
    const status_in = length == 0 or !in;
    ep.last_trb = ep.ring.push(.{ .control = regs.typeField(regs.TRB_STATUS) | regs.TRB_IOC | (if (status_in) regs.TRB_DIR_IN else 0) });
    ep.round = length;
    _xhci.toDevice(host, @intFromPtr(ep.ring.trbs), ep.ring.bytes());
    _xhci.ringDoorbell(host, slot.id, 1);
    return true;
}

/// A bulk or interrupt transfer's next round: as much as is left, up to
/// the round's size - an empty one for the packet that ends an OUT.
fn startRound(host: *Host, slot: *Slot, dci: u32, ep: *Endpoint, req: *usbhc.IOUsbHC) bool {
    const length: u32 = @intCast(req.std.length);
    const most: u32 = if (ep.kind == regs.EP_BULK_IN or ep.kind == regs.EP_BULK_OUT) _xhci.bulk_round else 64 * 1024;
    const round = @min(length - ep.done, most);
    if (!ensureBounce(host, ep, @max(round, 1))) return false;
    if (!isIn(req) and round != 0) {
        @memcpy(ep.bounce.?[0..round], dataOf(req)[ep.done..][0..round]);
        _xhci.toDevice(host, @intFromPtr(ep.bounce.?), round);
    }
    const buffer: u64 = @intFromPtr(ep.bounce.?);
    ep.data_trb = 0;
    ep.last_trb = ep.ring.push(.{
        .param_lo = ring.lo(buffer),
        .param_hi = ring.hi(buffer),
        .status = round,
        .control = regs.typeField(regs.TRB_NORMAL) | regs.TRB_ISP | regs.TRB_IOC,
    });
    ep.round = round;
    _xhci.toDevice(host, @intFromPtr(ep.ring.trbs), ep.ring.bytes());
    _xhci.ringDoorbell(host, slot.id, dci);
    return true;
}

// --- transfer events --------------------------------------------------------------

/// What a completion code says, as io_Error.
fn errorOf(code: u32) i8 {
    return switch (code) {
        regs.CC_STALL => usbhc.UHIOERR_STALL,
        regs.CC_TRANSACTION, regs.CC_SPLIT_TRANSACTION => usbhc.UHIOERR_CRCERROR,
        regs.CC_BABBLE => usbhc.UHIOERR_OVERFLOW,
        else => usbhc.UHIOERR_HOSTERROR,
    };
}

/// A transfer event: the TD it ends answered, or its next round put on
/// the ring. Taken while the task may be waiting for a command, so it
/// asks none: a halt is noted for `recover`.
pub fn completed(host: *Host, event: Trb) void {
    const id = regs.eventSlot(event.control);
    const dci = regs.eventEndpoint(event.control);
    if (id == 0 or id > _xhci.max_slots or dci == 0) return;
    const slot = host.slots[id] orelse return;
    if (!slot.enabled) return;
    const ep = &slot.endpoints[dci];
    if (_xhci.isIso(ep)) return isoCompleted(host, ep, event);
    const req = ep.current orelse return;
    const code = regs.completionCode(event.status);
    // A stop's own event: `cancel` deals with its TD.
    if (code == regs.CC_STOPPED or code == regs.CC_STOPPED_LENGTH_INVALID or code == regs.CC_STOPPED_SHORT_PACKET) return;
    const pointer = event.param();
    const ok = code == regs.CC_SUCCESS or code == regs.CC_SHORT_PACKET;

    if (pointer != ep.last_trb) {
        // A control transfer's data stage came back short: the status
        // stage follows. Anything else ends the TD here.
        if (pointer == ep.data_trb and code == regs.CC_SHORT_PACKET) {
            ep.short = true;
            ep.round -|= regs.residual(event.status);
            return;
        }
        if (ok) return;
        ep.halted = true;
        return finish(host, slot, ep, errorOf(code));
    }
    if (!ok) {
        ep.halted = true;
        return finish(host, slot, ep, errorOf(code));
    }

    var got = ep.round;
    if (ep.data_trb == 0 and code == regs.CC_SHORT_PACKET) {
        got -|= regs.residual(event.status);
        ep.short = true;
    }
    if (isIn(req) and got != 0) {
        _xhci.fromDevice(host, @intFromPtr(ep.bounce.?), got);
        @memcpy(dataOf(req)[ep.done..][0..got], ep.bounce.?[0..got]);
    }
    ep.done += got;
    const length: u32 = @intCast(req.std.length);
    if (req.std.req.command != usbhc.UHCMD_CONTROLXFER and !ep.short) {
        if (ep.done < length or ep.zero) {
            if (ep.done >= length) ep.zero = false;
            if (startRound(host, slot, dci, ep, req)) return;
            return finish(host, slot, ep, usbhc.UHIOERR_HOSTERROR);
        }
    }
    const runt = ep.short and ep.done < length and req.flags & usbhc.UHF_SHORT_NOT_OK != 0;
    finish(host, slot, ep, if (runt) usbhc.UHIOERR_RUNTPACKET else 0);
}

/// What a TD's completion code makes of its packet.
pub fn isoStatus(code: u32) i8 {
    return switch (code) {
        regs.CC_SUCCESS, regs.CC_SHORT_PACKET => 0,
        regs.CC_MISSED_SERVICE => usbhc.UHIOERR_MISSED,
        regs.CC_TRANSACTION, regs.CC_SPLIT_TRANSACTION => usbhc.UHIOERR_CRCERROR,
        regs.CC_BABBLE => usbhc.UHIOERR_OVERFLOW,
        else => usbhc.UHIOERR_HOSTERROR,
    };
}

/// An isochronous endpoint's event: the packet of the TD it names told
/// what became of it, every TD before it with no event of its own told
/// it was missed, and each request whose last TD that passes answered. A
/// ring run dry or full names no TD: what it cost is the next request's
/// gap.
fn isoCompleted(host: *Host, ep: *Endpoint, event: Trb) void {
    const code = regs.completionCode(event.status);
    if (code == regs.CC_STOPPED or code == regs.CC_STOPPED_LENGTH_INVALID or code == regs.CC_STOPPED_SHORT_PACKET) return;
    if (code == regs.CC_RING_UNDERRUN or code == regs.CC_RING_OVERRUN) return;
    const pointer = event.param();
    const start_address: u64 = @intFromPtr(ep.ring.trbs);
    if (pointer < start_address or pointer >= start_address + ep.ring.bytes()) return;
    const at = indexOf(ep, @intCast(pointer));
    const tail = ep.flight.last() orelse return;
    const count = ep.ring.count;
    // A TRB of no request on the ring, or one already told.
    if (ringDistance(ep.expect, at, count) > ringDistance(ep.expect, _xhci.spanLast(_xhci.requestOfNode(tail).hc_private[_xhci.PRIV_SPAN]), count)) return;
    while (ep.flight.first()) |node| {
        const req = _xhci.requestOfNode(node);
        const span = req.hc_private[_xhci.PRIV_SPAN];
        const index = ep.expect;
        const n: u32 = @intCast(req.hc_private[_xhci.PRIV_LATE] + ringDistance(_xhci.spanFirst(span), index, count));
        if (index == at) {
            const status = isoStatus(code);
            const asked = isoAsked(req, n);
            const got = if (status == 0) asked -| regs.residual(event.status) else 0;
            record(host, ep, req, n, status, got);
        } else {
            record(host, ep, req, n, usbhc.UHIOERR_MISSED, 0);
        }
        ep.expect = nextIndex(index, count);
        if (index == _xhci.spanLast(span)) {
            host.sys.Remove(node);
            ep.flying -= 1;
            _xhci.reply(host, req, 0);
        }
        if (index == at) break;
    }
}

/// An isochronous endpoint's requests taken back: the endpoint stopped,
/// its ring moved past them, each answered `err` - those that ended
/// meanwhile answered as they ended.
fn cancelIso(host: *Host, slot: *Slot, dci: u32, err: i8) void {
    const ep = &slot.endpoints[dci];
    const code = controller.command(host, .{ .control = regs.typeField(regs.TRB_STOP_ENDPOINT) | regs.endpointField(dci) | regs.slotField(slot.id) });
    if (code == regs.CC_SUCCESS) moveDequeue(host, slot, dci);
    dropFlight(host, ep, err);
}

/// Every request on an isochronous endpoint's ring answered `err`, and
/// its stream ended: the next request starts a new one.
fn dropFlight(host: *Host, ep: *Endpoint, err: i8) void {
    while (host.sys.RemHead(&ep.flight)) |node| {
        const req = _xhci.requestOfNode(node);
        _xhci.reply(host, req, err);
    }
    ep.flying = 0;
    ep.streaming = false;
}

/// The endpoint's TD ended: its request answered `err` - or posted, if
/// the task has the controller to tell first.
fn finish(host: *Host, slot: *Slot, ep: *Endpoint, err: i8) void {
    const req = ep.current orelse return;
    ep.current = null;
    ep.data_trb = 0;
    ep.last_trb = 0;
    req.std.actual = ep.done;
    if (err == 0 and req.std.req.command == usbhc.UHCMD_CONTROLXFER and kept(slot, req)) {
        host.sys.AddTail(&host.posted, _xhci.nodeOf(req));
        return;
    }
    _xhci.reply(host, req, err);
}

/// What a control transfer that went well shows the controller: a
/// configuration read whole kept. True for one the task is to see before
/// it is answered: a hub's descriptor, or a port status showing a device
/// gone.
fn kept(slot: *Slot, req: *usbhc.IOUsbHC) bool {
    const setup = req.setup;
    const got: u32 = @intCast(req.std.actual);
    if (got == 0) return false;
    const data = dataOf(req)[0..got];
    if (isRequest(setup, d.USB_DIR_IN, d.USB_REQ_GET_DESCRIPTOR)) {
        if (setup.value >> 8 == d.USB_DT_CONFIG and got >= 4) {
            const total = @as(u32, data[2]) | @as(u32, data[3]) << 8;
            if (total <= got and total <= _xhci.config_bytes) {
                @memcpy(slot.config[0..total], data[0..total]);
                slot.config_length = total;
            }
        }
        return false;
    }
    if (isRequest(setup, d.USB_DIR_IN | d.USB_RT_HUB, d.USB_REQ_GET_DESCRIPTOR)) {
        const kind = setup.value >> 8;
        return kind == d.USB_DT_HUB or kind == d.USB_DT_SS_HUB;
    }
    if (isRequest(setup, d.USB_DIR_IN | d.USB_RT_PORT, d.USB_REQ_GET_STATUS) and got >= 4) {
        const status = @as(u16, data[0]) | @as(u16, data[1]) << 8;
        const change = @as(u16, data[2]) | @as(u16, data[3]) << 8;
        return status & d.USB_PORT_STAT_CONNECTION == 0 or change & d.USB_PORT_STAT_C_CONNECTION != 0;
    }
    return false;
}

/// The posted transfers - each went well - the controller told what they
/// showed, then each answered.
pub fn finishPosted(host: *Host) void {
    while (host.sys.RemHead(&host.posted)) |node| {
        const req = _xhci.requestOfNode(node);
        if (_xhci.slotAt(host, req.address)) |slot| {
            const got: u32 = @intCast(req.std.actual);
            const data = dataOf(req)[0..got];
            if (req.setup.request == d.USB_REQ_GET_DESCRIPTOR) {
                slots.hubUpdate(host, slot, data);
            } else {
                slots.portGone(host, slot.id, @truncate(req.setup.index));
            }
        }
        _xhci.reply(host, req, 0);
    }
}

// --- halts, stops, deadlines ------------------------------------------------------

/// A stopped or halted endpoint's ring moved past what was on it: the
/// next TD starts where the next TRB goes.
fn moveDequeue(host: *Host, slot: *Slot, dci: u32) void {
    const ep = &slot.endpoints[dci];
    const pointer = ep.ring.dequeuePointer();
    _ = controller.command(host, .{
        .param_lo = ring.lo(pointer),
        .param_hi = ring.hi(pointer),
        .control = regs.typeField(regs.TRB_SET_TR_DEQUEUE) | regs.endpointField(dci) | regs.slotField(slot.id),
    });
}

fn resetEndpoint(host: *Host, slot: *Slot, dci: u32) u32 {
    return controller.command(host, .{ .control = regs.typeField(regs.TRB_RESET_ENDPOINT) | regs.endpointField(dci) | regs.slotField(slot.id) });
}

/// Every endpoint the controller halted reset and moved on.
pub fn recover(host: *Host) void {
    for (host.slots[1..]) |entry| {
        const slot = entry orelse continue;
        if (!slot.enabled) continue;
        var dci: u32 = 1;
        while (dci <= slot.entries) : (dci += 1) {
            const ep = &slot.endpoints[dci];
            if (!ep.halted) continue;
            ep.halted = false;
            if (resetEndpoint(host, slot, dci) == regs.CC_SUCCESS) moveDequeue(host, slot, dci);
        }
    }
}

/// The TD on an endpoint taken back: the endpoint stopped, its ring moved
/// on, its request answered `err` - unless it ended meanwhile.
fn cancel(host: *Host, slot: *Slot, dci: u32, err: i8) void {
    const ep = &slot.endpoints[dci];
    const req = ep.current orelse return;
    var code = controller.command(host, .{ .control = regs.typeField(regs.TRB_STOP_ENDPOINT) | regs.endpointField(dci) | regs.slotField(slot.id) });
    if (ep.current != req) return;
    // A halted endpoint does not stop; it is reset instead.
    if (code == regs.CC_CONTEXT_STATE) code = resetEndpoint(host, slot, dci);
    if (code == regs.CC_SUCCESS) moveDequeue(host, slot, dci);
    ep.halted = false;
    ep.current = null;
    ep.data_trb = 0;
    ep.last_trb = 0;
    req.std.actual = ep.done;
    _xhci.reply(host, req, err);
}

fn pastDeadline(req: *const usbhc.IOUsbHC, time: u32) bool {
    if (req.hc_private[_xhci.PRIV_FLAGS] & _xhci.PRIVF_DEADLINE == 0) return false;
    return _xhci.reached(time, @truncate(req.hc_private[_xhci.PRIV_DUE]));
}

/// The tick taken back, and every request past its NAK deadline
/// answered UHIOERR_NAKTIMEOUT.
pub fn tick(host: *Host) void {
    if (host.tick_armed != 0 and host.sys.CheckIO(&host.tick_io.node) != null) {
        _ = host.sys.WaitIO(&host.tick_io.node);
        host.tick_armed = 0;
    }
    const time = _xhci.now(host);
    for (host.slots[1..]) |entry| {
        const slot = entry orelse continue;
        if (!slot.enabled) continue;
        var dci: u32 = 1;
        while (dci <= slot.entries) : (dci += 1) {
            const ep = &slot.endpoints[dci];
            var it = ep.queue.iterator();
            while (it.next()) |node| {
                const req = _xhci.requestOfNode(node);
                if (!pastDeadline(req, time)) continue;
                host.sys.Remove(node);
                _xhci.reply(host, req, usbhc.UHIOERR_NAKTIMEOUT);
            }
            const req = ep.current orelse continue;
            if (pastDeadline(req, time)) cancel(host, slot, dci, usbhc.UHIOERR_NAKTIMEOUT);
        }
    }
}

/// The tick armed for the earliest deadline, or every few milliseconds
/// while the controller's interrupt is not hooked; left alone if nothing
/// waits on time.
pub fn armTick(host: *Host) void {
    const time = _xhci.now(host);
    var due: ?u32 = if (host.int_hooked) null else time +% 5;
    for (host.slots[1..]) |entry| {
        const slot = entry orelse continue;
        if (!slot.enabled) continue;
        var dci: u32 = 1;
        while (dci <= slot.entries) : (dci += 1) {
            const ep = &slot.endpoints[dci];
            var it = ep.queue.iterator();
            while (it.next()) |node| earliest(&due, _xhci.requestOfNode(node));
            if (ep.current) |req| earliest(&due, req);
        }
    }
    const when = due orelse return;
    if (host.tick_armed != 0) {
        if (_xhci.reached(when, host.tick_due)) return;
        dropTick(host);
    }
    const wait_ms: u32 = if (_xhci.reached(time, when)) 1 else when -% time;
    host.tick_io.node.command = timer.TR_ADDREQUEST;
    host.tick_io.time = timer.TimeVal.fromMicros(@as(u64, wait_ms) * 1000);
    host.sys.SendIO(&host.tick_io.node);
    host.tick_armed = 1;
    host.tick_due = when;
}

fn earliest(due: *?u32, req: *const usbhc.IOUsbHC) void {
    if (req.hc_private[_xhci.PRIV_FLAGS] & _xhci.PRIVF_DEADLINE == 0) return;
    const when: u32 = @truncate(req.hc_private[_xhci.PRIV_DUE]);
    if (due.* == null or !_xhci.reached(when, due.*.?)) due.* = when;
}

pub fn dropTick(host: *Host) void {
    if (host.tick_armed == 0) return;
    _ = host.sys.AbortIO(&host.tick_io.node);
    _ = host.sys.WaitIO(&host.tick_io.node);
    host.tick_armed = 0;
}

/// Requests AbortIO marked: taken off their lists and answered, or their
/// TD taken back, which answers them.
pub fn takeAborts(host: *Host) void {
    for (host.slots[1..]) |entry| {
        const slot = entry orelse continue;
        if (!slot.enabled) continue;
        var dci: u32 = 1;
        while (dci <= slot.entries) : (dci += 1) {
            const ep = &slot.endpoints[dci];
            var it = ep.queue.iterator();
            while (it.next()) |node| {
                const req = _xhci.requestOfNode(node);
                if (req.hc_private[_xhci.PRIV_ABORT] == 0) continue;
                host.sys.Remove(node);
                _xhci.reply(host, req, exec.IOERR_ABORTED);
            }
            if (_xhci.isIso(ep)) {
                var flying = ep.flight.iterator();
                while (flying.next()) |node| {
                    if (_xhci.requestOfNode(node).hc_private[_xhci.PRIV_ABORT] == 0) continue;
                    cancelIso(host, slot, dci, exec.IOERR_ABORTED);
                    break;
                }
                continue;
            }
            const req = ep.current orelse continue;
            if (req.hc_private[_xhci.PRIV_ABORT] != 0) cancel(host, slot, dci, exec.IOERR_ABORTED);
        }
    }
    roothub.takeAbort(host);
}

/// Whether the task has more to do before it waits: a posted transfer,
/// an endpoint to reset, a request to start.
pub fn pending(host: *Host) bool {
    if (!host.posted.isEmpty()) return true;
    for (host.slots[1..]) |entry| {
        const slot = entry orelse continue;
        if (!slot.enabled) continue;
        var dci: u32 = 1;
        while (dci <= slot.entries) : (dci += 1) {
            const ep = &slot.endpoints[dci];
            if (ep.halted) return true;
            if (_xhci.hasRoom(ep) and !ep.queue.isEmpty()) return true;
        }
    }
    return false;
}

/// Every request of a slot answered `err`: what is on its rings and what
/// waits. The controller is not told: the slot goes, or the controller
/// stops.
pub fn failSlot(host: *Host, slot: *Slot, err: i8) void {
    for (&slot.endpoints) |*ep| {
        if (ep.current) |req| {
            ep.current = null;
            ep.data_trb = 0;
            ep.last_trb = 0;
            req.std.actual = ep.done;
            _xhci.reply(host, req, err);
        }
        ep.halted = false;
        dropFlight(host, ep, err);
        while (host.sys.RemHead(&ep.queue)) |node| _xhci.reply(host, _xhci.requestOfNode(node), err);
    }
}

/// Every request answered `err`, as the controller stops.
pub fn failAll(host: *Host, err: i8) void {
    for (host.slots[1..]) |entry| {
        const slot = entry orelse continue;
        failSlot(host, slot, err);
    }
    while (host.sys.RemHead(&host.posted)) |node| _xhci.reply(host, _xhci.requestOfNode(node), err);
}
