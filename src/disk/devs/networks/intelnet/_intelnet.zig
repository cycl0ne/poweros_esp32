// SPDX-License-Identifier: MIT
//! intelnet.device's own state: the base, a card per controller the
//! machine has, the block of memory each card's rings and frame buffers
//! live in, and the hardware's side of the unit.
//!
//! **A card is a unit.** The device's task serves them all from one
//! port; each card has its own rings, its own interrupt and its own
//! unit, and `exec.Unit` is what a request points at, so the card a
//! request belongs to is found from the request itself (`cardOf`).
//!
//! **Why a block of its own.** The base is wherever MakeLibrary put it.
//! The controller reads and writes its descriptors and its frame buffers
//! itself, so each card's init allocates one block for them that it can
//! reach and that is never moved, aligned so that both rings start on a
//! 128-byte boundary as the controller wants.
//!
//! **The rings.** The receive ring is handed over full and the task
//! gives each descriptor back as it takes its frame, so the controller
//! always has somewhere to put the next one. Writes go out in order: the
//! task fills a send descriptor, moves the ring's tail, and answers each
//! write when its descriptor comes back done. Both rings leave one
//! descriptor unused, because a ring whose head and tail are equal is an
//! empty one (`ring.zig`).

const sdk = @import("sdk");
const exec = sdk.exec;
const net = sdk.devices.network;
const timer = sdk.devices.timer;
const pci = sdk.pci;
const ExecBase = sdk.interface.exec.ExecBase;
const PCIBase = sdk.interface.pci.PCIBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const TimerBase = sdk.interface.timer.TimerBase;
const ethernet = sdk.devices.network.ethernet;
const unit_file = sdk.devices.network.unit;
const mac = @import("mac.zig");
const ring = @import("ring.zig");
const checksum = @import("checksum.zig");
const link = @import("link.zig");
const Family = @import("family/_family.zig").Family;

pub const DEVICE_NAME = "intelnet.device";

/// How many controllers the device takes, one unit each.
pub const max_cards = 4;

/// The descriptors in each ring, which the controller wants in
/// multiples of eight, and the bytes in one frame buffer, which it wants
/// in multiples of 1024. A frame is never longer than 1518 bytes, so one
/// buffer holds one frame.
///
/// The receive ring is deep because the line can be: at 2.5 Gbit/s a
/// frame arrives every five microseconds, and the ring is what holds
/// what came in while the task was being woken. 128 of them is 256 KiB
/// of buffers, which a machine with a PCI slot has, and every one of
/// these drivers runs on such a machine.
pub const receive_count = 128;
pub const send_count = 64;
pub const buffer_bytes = 2048;

/// Where both rings have to start.
pub const ring_align = 128;

/// The block a card's controller reads and writes: its two rings and a
/// frame buffer for every descriptor in them.
pub const Work = extern struct {
    receive_ring: [receive_count]ring.Receive = @splat(.{}),
    send_ring: [send_count]ring.Transmit = @splat(.{}),
    receive: [receive_count][buffer_bytes]u8 = @splat(@splat(0)),
    send: [send_count][buffer_bytes]u8 = @splat(@splat(0)),
};

comptime {
    // The block is allocated on a 128-byte boundary, which puts the
    // first ring on one; the second has to land on one as well.
    if (@offsetOf(Work, "receive_ring") % ring_align != 0) @compileError("the receive ring is misaligned");
    if (@offsetOf(Work, "send_ring") % ring_align != 0) @compileError("the send ring is misaligned");
    if (receive_count % 8 != 0 or send_count % 8 != 0) @compileError("a ring holds a multiple of eight descriptors");
    if (buffer_bytes % 1024 != 0) @compileError("a frame buffer is a multiple of 1024 bytes");
    if (buffer_bytes < ethernet.frame_max) @compileError("a frame buffer is shorter than a frame");
}

/// How a card raises its interrupt: a vector of its own in the extended
/// registers, a message on vector 0 or its interrupt line, both of which
/// put their causes in the first register block, or nothing at all -
/// which a card is refused for.
pub const Signalling = enum(u8) { none, line, message, vector };

/// What a card has raised since the task last looked, as the task reads
/// it: the device's own bits, not the controller's.
pub const raised_work: u32 = 1 << 0;
pub const raised_link: u32 = 1 << 1;
pub const raised_lost: u32 = 1 << 2;

pub const Unit = unit_file.Unit(Card);

/// One controller: its PCI function, its registers, its rings and its
/// unit. This is the link the unit above it drives.
pub const Card = extern struct {
    base: *IntelnetBase,
    sys: *ExecBase,
    pb: *PCIBase,
    function: *pci.PCIDevice,
    /// Where its registers are. Which of them the interrupt block is at
    /// comes from its family, the one place the generations differ.
    regs: usize = 0,
    family: *const Family,
    /// The block its controller reads and writes, and the allocation it
    /// was aligned out of, which is what has to be given back.
    work: ?*Work = null,
    work_memory: usize = 0,
    work_bytes: usize = 0,
    /// Its unit, which a request points at, and the unit's number.
    unit: exec.Unit,
    number: u32 = 0,
    /// Whether what the controller reads and writes in RAM sees the
    /// processors' caches: then nothing is written back or thrown away
    /// around a descriptor or a buffer.
    coherent: bool = false,
    /// How it raises its interrupt, whether it is receiving and sending,
    /// and whether it takes every frame there is.
    signalling: Signalling = .none,
    running: u8 = 0,
    promiscuous: u8 = 0,
    /// What the last line about the link said, so that only a change is
    /// said again. It starts at 0: the controller has just been reset,
    /// so there is no carrier yet, and a cable that is out when the
    /// machine starts is not news.
    carrier_said: u8 = 0,
    /// Its interrupt server, and what it has raised since the task last
    /// looked.
    int: exec.Interrupt = .{},
    raised: u32 = 0,
    /// The receive descriptor to look at next, and the last one the
    /// controller has been given.
    receive_next: u32 = 0,
    receive_tail: u32 = 0,
    /// The send descriptor to fill next, the oldest one still in the
    /// controller's hands, and how many are.
    send_next: u32 = 0,
    send_done: u32 = 0,
    send_busy: u32 = 0,
    sending: [send_count]?*net.IOSana2Req = @splat(null),
    /// The multicast table as the groups make it.
    hash: [mac.groups_words]u32 = @splat(0),
    /// The requests' side of the unit.
    net: Unit,

    // --- the unit's link --------------------------------------------------

    /// The link's speed as the unit reports it: what the link came up
    /// at, or the fastest this part goes while there is no carrier.
    /// Two generations with two speeds share this device, and a link
    /// negotiates its own, so there is no one number to name.
    pub fn bps(card: *Card) u64 {
        const state = link.state(card.regs, card.family);
        return if (state.up) state.bps else card.family.bps;
    }

    pub fn setStation(card: *Card, address: *const ethernet.Address) void {
        mac.setStation(card.regs, address);
    }

    /// The checksums the controller works out for itself. Both families'
    /// are checked on the way in, and a read whose packet came through
    /// with every one of them right is answered as checked. On the way
    /// out it finishes an IPv4 packet's, which is what the write
    /// descriptors ask it for.
    pub fn offload(_: *Card) u32 {
        return net.S2OFFLOADF_RX_CHECKSUMS | net.S2OFFLOADF_RX_CHECKSUMS_IPV6 |
            net.S2OFFLOADF_TX_CHECKSUMS;
    }

    /// The rings set up afresh and the controller started, or the
    /// controller stopped and every write it still had answered.
    pub fn setRunning(card: *Card, on: bool) void {
        const work = card.work orelse return;
        if (!on) {
            mac.stopReceive(card.regs);
            mac.stopTransmit(card.regs);
            ring.stop(card.regs);
            card.running = 0;
            card.sent();
            while (card.send_busy > 0) card.finishSend(false);
            return;
        }
        const at = @intFromPtr(work);
        for (&work.receive_ring, 0..) |*descriptor, slot| {
            ring.give(descriptor, @intFromPtr(&work.receive[slot]));
        }
        for (&work.send_ring) |*descriptor| descriptor.* = .{};
        card.toDevice(at, @sizeOf(Work));
        card.receive_next = 0;
        card.receive_tail = receive_count - 1;
        card.send_next = 0;
        card.send_done = 0;
        card.send_busy = 0;
        if (!ring.startReceive(card.regs, at + @offsetOf(Work, "receive_ring"), receive_count, buffer_bytes) or
            !ring.startTransmit(card.regs, at + @offsetOf(Work, "send_ring"), send_count))
        {
            // The console line is the whole report. Nothing in the
            // unit's link can refuse to run, and this is no place to say
            // it another way: the unit is part way on line here, and a
            // link that talks back to it from inside `setRunning` is
            // what the comment at the end of this function is about.
            sdk.exec.kprintf(card.sys, "%s: unit %u: its queues do not start\n", .{ DEVICE_NAME, card.number });
            card.running = 0;
            return;
        }
        mac.setGroups(card.regs, &card.hash);
        mac.startReceive(card.regs, card.promiscuous != 0);
        mac.startTransmit(card.regs);
        card.running = 1;
        // Nothing of the interrupt is touched, here or in the stop
        // above: the causes are turned on once, when the task is ready
        // for them (`startInterrupts`), and stay on. The link is the
        // reason - a unit that is off line because its cable is out has
        // to hear the cable go back in, and it hears it on the cause the
        // controller raises. The link is not read here either: a link's
        // `setRunning` must not call back into the unit, which is part
        // way on line while it runs.
    }

    /// The card's causes turned on, which is done once the device's task
    /// is there to take them, and the link's raised by hand so that the
    /// task reads what the link is doing now. From here on every change
    /// reaches the unit whether it is running or not.
    pub fn startInterrupts(card: *Card) void {
        switch (card.signalling) {
            .vector => mac.vectorInterrupts(card.regs, card.family),
            .line, .message => mac.lineInterrupts(card.regs, card.family),
            .none => return,
        }
        mac.raise(card.regs, card.family, mac.cause_lsc);
    }

    /// The groups the controller takes: the hash table written from
    /// those that were joined, and the blunt bits where every group or
    /// every frame is wanted.
    pub fn setFilter(card: *Card, groups: []const unit_file.Group, promiscuous: bool) void {
        card.hash = @splat(0);
        for (groups) |group| {
            if (group.users == 0) continue;
            const bit = mac.groupHash(&group.address);
            card.hash[bit >> 5] |= @as(u32, 1) << @truncate(bit);
        }
        card.promiscuous = @intFromBool(promiscuous);
        if (card.running == 0) return;
        mac.setGroups(card.regs, &card.hash);
        mac.startReceive(card.regs, promiscuous);
    }

    /// Every free send descriptor given a write, while there are writes.
    ///
    /// A write that asks for its checksums takes two descriptors: a
    /// context descriptor saying where its headers end, and the frame's
    /// own behind it. The two are written together and the controller is
    /// told about both at once, so it never sees a context descriptor
    /// with nothing behind it.
    pub fn startWrites(card: *Card) void {
        const work = card.work orelse return;
        var filled = false;
        // Two descriptors stay free: enough for a write that wants a
        // context descriptor in front of it, and a ring whose tail
        // catches its head is an empty one.
        while (card.running != 0 and card.send_busy + 2 < send_count) {
            const req = card.net.nextWrite() orelse break;
            // Whether a context descriptor is wanted is the request's to
            // say, and is known before the frame is built - the frame
            // goes in the slot behind the context descriptor's.
            const asked = req.req.flags & net.SANA2IOF_CHECKSUM != 0;
            const front = card.send_next;
            const slot = if (asked) (front + 1) % send_count else front;
            const length = card.net.buildFrame(req, &work.send[slot]);
            if (length == 0) continue;
            const headers = if (asked) checksum.seed(work.send[slot][0..length]) else null;
            if (asked) {
                // A context descriptor goes in front whenever one was
                // asked for, even where the frame turned out not to be a
                // packet the controller can finish: the slot is spoken
                // for by then, and a context descriptor nothing uses is
                // the harmless thing to leave in it.
                const lengths = headers orelse checksum.plain;
                ring.context(&work.send_ring[front], lengths.mac, lengths.ip, lengths.tcp);
                card.toDevice(@intFromPtr(&work.send_ring[front]), @sizeOf(ring.Transmit));
                card.sending[front] = null;
                card.send_busy += 1;
            }
            card.sending[slot] = req;
            card.send_next = (slot + 1) % send_count;
            card.send_busy += 1;
            const buffer = @intFromPtr(&work.send[slot]);
            card.toDevice(buffer, length);
            ring.send(&work.send_ring[slot], buffer, length, headers != null);
            card.toDevice(@intFromPtr(&work.send_ring[slot]), @sizeOf(ring.Transmit));
            filled = true;
        }
        if (filled) ring.transmitTail(card.regs, card.send_next);
    }

    pub fn now(card: *Card) timer.TimeVal {
        return card.base.now();
    }

    // --- the task's side of the rings -------------------------------------

    /// Every frame the controller has put in the ring, handed to the
    /// unit, and its descriptor given back.
    pub fn received(card: *Card) void {
        const work = card.work orelse return;
        var taken = false;
        while (card.running != 0) {
            const slot = card.receive_next;
            const descriptor: *volatile ring.Receive = &work.receive_ring[slot];
            card.fromDevice(@intFromPtr(descriptor), @sizeOf(ring.Receive));
            const status = descriptor.status;
            if (status & ring.received_done == 0) break;
            const length = ring.frameBytes(descriptor);
            if (status & ring.received_faults != 0 or status & ring.received_last == 0 or
                length == 0 or length > buffer_bytes)
            {
                // A frame longer than one buffer arrives as several
                // descriptors; nothing here asks for frames that long,
                // so one is as damaged as a bad checksum is.
                card.net.damaged();
            } else {
                const buffer = &work.receive[slot];
                card.fromDevice(@intFromPtr(buffer), length);
                const checked: u8 = if (ring.receivedChecked(descriptor)) net.SANA2IOF_CHECKSUM else 0;
                card.net.receiveWith(buffer[0..length], checked);
            }
            ring.give(descriptor, @intFromPtr(&work.receive[slot]));
            card.toDevice(@intFromPtr(descriptor), @sizeOf(ring.Receive));
            card.receive_tail = slot;
            card.receive_next = (slot + 1) % receive_count;
            taken = true;
        }
        // The descriptors given back are handed over together: the
        // controller only has to be told where the driver's side of the
        // ring now ends.
        if (taken) ring.receiveTail(card.regs, card.receive_tail);
    }

    /// Every write whose descriptor has come back answered, and the
    /// writes that waited for a descriptor started.
    ///
    /// A context descriptor is never written back - it is not a frame -
    /// so the pair is retired on the status of the frame's own
    /// descriptor, which is the one behind it.
    pub fn sent(card: *Card) void {
        const work = card.work orelse return;
        while (card.send_busy > 0) {
            const context = card.sending[card.send_done] == null;
            const slot = if (context) (card.send_done + 1) % send_count else card.send_done;
            const descriptor: *volatile ring.Transmit = &work.send_ring[slot];
            card.fromDevice(@intFromPtr(descriptor), @sizeOf(ring.Transmit));
            if (descriptor.status & ring.sent_done == 0) break;
            if (context) card.finishSend(true);
            card.finishSend(true);
        }
        card.startWrites();
    }

    /// The descriptor at the head of the ring given up, and the write it
    /// carried answered. A context descriptor carries none, and goes
    /// with nothing said.
    fn finishSend(card: *Card, done: bool) void {
        const slot = card.send_done;
        card.send_done = (slot + 1) % send_count;
        card.send_busy -= 1;
        const req = card.sending[slot] orelse return;
        card.sending[slot] = null;
        card.net.written(req, done);
    }

    /// The link read and the unit told, which takes it on and off line
    /// with it - and which may stop or start the rings from inside, so
    /// nothing after the call may count on either. A change is said once
    /// on the console: a cable going in or out is worth a line, and the
    /// same state read twice is not.
    pub fn linkChanged(card: *Card) void {
        const state = link.state(card.regs, card.family);
        const now_said: u8 = @intFromBool(state.up);
        if (card.carrier_said != now_said) {
            card.carrier_said = now_said;
            if (state.up) {
                sdk.exec.kprintf(card.sys, "%s: unit %u: link up, %u Mbit/s, %s\n", .{
                    DEVICE_NAME,
                    card.number,
                    @as(u32, @intCast(state.bps / 1_000_000)),
                    if (state.full_duplex) "full duplex" else "half duplex",
                });
            } else {
                sdk.exec.kprintf(card.sys, "%s: unit %u: no carrier\n", .{ DEVICE_NAME, card.number });
            }
        }
        card.net.setCarrier(state.up);
    }

    // --- the caches -------------------------------------------------------

    /// What the processors wrote, written back for the controller.
    pub fn toDevice(card: *Card, address: usize, bytes: usize) void {
        if (bytes == 0 or card.coherent) return;
        var length: u32 = @intCast(bytes);
        _ = card.sys.CachePreDMA(@ptrFromInt(address), &length, 0);
    }

    /// What the controller wrote, read past the processors' caches.
    pub fn fromDevice(card: *Card, address: usize, bytes: usize) void {
        if (bytes == 0 or card.coherent) return;
        var length: u32 = @intCast(bytes);
        card.sys.CachePostDMA(@ptrFromInt(address), &length, 0);
    }
};

/// The device's base: the task that answers every request, the port it
/// takes them from, and the cards.
pub const IntelnetBase = extern struct {
    dev: exec.Device,
    /// SysBase, to call exec through its jump table.
    sys_base: *ExecBase,
    /// utility.library, for the tag lists OpenDevice is handed, and
    /// pci.library, which the cards are found through.
    utility: ?*UtilityBase = null,
    pci_base: ?*PCIBase = null,
    /// The task every request runs on - the openers' copy calls run only
    /// there - and the port it takes them from. One port for every card:
    /// the request says which (`cardOf`).
    task: exec.Task,
    port: exec.MsgPort,
    stack: ?*anyopaque = null,
    /// The task's signal every card's interrupt raises.
    int_mask: u32 = 0,
    /// For the system time a unit goes online at, and for the waits
    /// while a controller is being reset.
    timer_io: timer.TimeRequest = .{},
    timer_open: u8 = 0,
    /// Whether the task is ready for requests.
    ready: u8 = 0,
    pad: [2]u8 = @splat(0),
    /// The cards, in the order they were found.
    cards: [max_cards]?*Card = @splat(null),
    card_count: u32 = 0,
    /// The task that started this one, and the signal it waits on until
    /// the task takes requests.
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    pad2: [3]u8 = @splat(0),
    /// What the device was loaded from, for its expunge to hand back.
    seg_list: ?*anyopaque = null,

    /// The system time, 0 before the timer is open.
    pub fn now(base: *IntelnetBase) timer.TimeVal {
        var time: timer.TimeVal = .{};
        if (base.timer_open != 0) {
            const timer_base: *TimerBase = @ptrCast(@alignCast(base.timer_io.node.device.?));
            timer_base.GetSysTime(&time);
        }
        return time;
    }

    /// The task kept for `us` microseconds, for the waits a controller
    /// asks for while it resets. Without a timer there is nothing to
    /// wait on and the register polls stand in for it.
    pub fn pause(base: *IntelnetBase, us: u32) void {
        if (base.timer_open == 0) return;
        base.timer_io.node.command = timer.TR_ADDREQUEST;
        base.timer_io.time = timer.TimeVal.fromMicros(us);
        _ = base.sys_base.DoIO(&base.timer_io.node);
    }
};

pub fn intelnetBase(dev: *exec.Device) *IntelnetBase {
    return @fieldParentPtr("dev", dev);
}

/// The card a request's unit is.
pub fn cardOf(io: *exec.IORequest) *Card {
    return @alignCast(@fieldParentPtr("unit", io.unit.?));
}

pub fn sanaReq(io: *exec.IORequest) *net.IOSana2Req {
    return @alignCast(@fieldParentPtr("req", io));
}

/// The request a message on the task's port belongs to.
pub fn requestOf(msg: *exec.Message) *exec.IORequest {
    return @fieldParentPtr("message", msg);
}
