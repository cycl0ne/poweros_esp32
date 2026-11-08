// SPDX-License-Identifier: MIT
//! realnet.device's own state: the base, a card per controller the
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
//! 256-byte boundary as the controller wants.
//!
//! **The rings.** The receive ring is handed over full and the task
//! gives each descriptor back as it takes its frame, so the controller
//! always has somewhere to put the next one. Writes go out in order: the
//! task fills a send descriptor, hands it over and tells the controller
//! to fetch it, and answers each write when its descriptor comes back.
//! Neither ring has a register saying where it ends - the last
//! descriptor carries the mark - so both are walked by ownership alone.

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
const link = @import("link.zig");
const setup = @import("setup.zig");

pub const DEVICE_NAME = "realnet.device";

/// How many controllers the device takes, one unit each.
pub const max_cards = 4;

/// The descriptors in each ring, and the bytes in one frame buffer. A
/// frame is never longer than 1518 bytes and arrives with its frame
/// check sequence behind it, so one buffer holds one frame whole.
///
/// The receive ring is deep because the line can be: at 2.5 Gbit/s a
/// frame arrives every five microseconds, and the ring is what holds
/// what came in while the task was being woken.
pub const receive_count = 128;
pub const send_count = 64;
pub const buffer_bytes = 2048;

/// How long writes may stand in the controller's hands with none of
/// them completing before it is taken to have stopped working
/// (`stalled`). Three seconds is far longer than any frame takes and
/// far shorter than a connection's own patience, so a controller that
/// stops is started again while what was being sent is still wanted.
pub const stall_seconds: u32 = 3;

/// Where both rings have to start.
pub const ring_align = 256;

/// The frame check sequence a frame arrives with behind it, which is no
/// part of the frame.
pub const crc_bytes = 4;

/// The block a card's controller reads and writes: its two rings and a
/// frame buffer for every descriptor in them.
pub const Work = extern struct {
    receive_ring: [receive_count]ring.Receive = @splat(.{}),
    send_ring: [send_count]ring.Transmit = @splat(.{}),
    receive: [receive_count][buffer_bytes]u8 = @splat(@splat(0)),
    send: [send_count][buffer_bytes]u8 = @splat(@splat(0)),
};

comptime {
    if (@offsetOf(Work, "receive_ring") % ring_align != 0) @compileError("the receive ring is misaligned");
    if (@offsetOf(Work, "send_ring") % ring_align != 0) @compileError("the send ring is misaligned");
    if (buffer_bytes < ethernet.frame_max + crc_bytes) @compileError("a frame buffer is shorter than a frame and its check sequence");
}

/// How a card raises its interrupt: a vector of its own, a message on
/// vector 0, or its interrupt line - which may be shared, so the server
/// answers only where the controller has really raised something.
pub const Signalling = enum(u8) { none, line, message, vector };

/// What a card has raised since the task last looked, as the task reads
/// it: the device's own bits, not the controller's.
pub const raised_work: u32 = 1 << 0;
pub const raised_link: u32 = 1 << 1;
pub const raised_lost: u32 = 1 << 2;
/// The controller said its own working went wrong - a read of RAM that
/// was answered with an error, or a part of it that stopped. Nothing it
/// holds can be trusted after that, so the controller is started again
/// from the beginning (`restart`) rather than carried on with.
pub const raised_fault: u32 = 1 << 3;

pub const Unit = unit_file.Unit(Card);

/// One controller: its PCI function, its registers, its rings and its
/// unit. This is the link the unit above it drives.
pub const Card = extern struct {
    base: *RealnetBase,
    sys: *ExecBase,
    pb: *PCIBase,
    function: *pci.PCIDevice,
    /// Where its registers are.
    regs: usize = 0,
    /// Which of the controllers it is, which is two settings and the
    /// speeds it reaches.
    part: *const mac.Part,
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
    /// said again.
    carrier_said: u8 = 0,
    /// Its interrupt server, and what it has raised since the task last
    /// looked.
    int: exec.Interrupt = .{},
    raised: u32 = 0,
    /// The receive descriptor to look at next.
    receive_next: u32 = 0,
    /// When the oldest write still in the controller's hands was given
    /// to it, for telling a busy controller from a stopped one: writes
    /// that stand for `stall_seconds` with nothing completing are a
    /// controller that has stopped working, whatever it says.
    stall_at: timer.TimeVal = .{},
    /// The send descriptor to fill next, the oldest one still in the
    /// controller's hands, and how many are.
    send_next: u32 = 0,
    send_done: u32 = 0,
    send_busy: u32 = 0,
    sending: [send_count]?*net.IOSana2Req = @splat(null),
    /// The multicast table as the groups make it.
    hash: [2]u32 = @splat(0),
    /// The requests' side of the unit.
    net: Unit,

    // --- the unit's link --------------------------------------------------

    /// The link's speed as the unit reports it: what the link came up
    /// at, or the fastest this part goes while there is no carrier.
    pub fn bps(card: *Card) u64 {
        const state = link.state(card.regs);
        return if (state.up) state.bps else card.part.bps;
    }

    pub fn setStation(card: *Card, address: *const ethernet.Address) void {
        mac.setStation(card.regs, address);
    }

    /// The checksums the controller works out for itself. It checks what
    /// comes in and says in the descriptor what it found, so a read of a
    /// packet whose checksums were all there and all right is answered
    /// as checked. Nothing is asked of it on the way out.
    pub fn offload(_: *Card) u32 {
        return net.S2OFFLOADF_RX_CHECKSUMS | net.S2OFFLOADF_RX_CHECKSUMS_IPV6;
    }

    /// The rings set up afresh and the controller started, or the
    /// controller stopped and every write it still had answered.
    pub fn setRunning(card: *Card, on: bool) void {
        const work = card.work orelse return;
        const at = card.regs;
        if (!on) {
            mac.stopReceive(at);
            mac.write8(at, mac.cmd, 0);
            card.running = 0;
            card.sent();
            while (card.send_busy > 0) card.finishSend(false);
            return;
        }
        const block = @intFromPtr(work);
        for (&work.receive_ring, 0..) |*descriptor, slot| {
            ring.give(descriptor, @intFromPtr(&work.receive[slot]), buffer_bytes, slot == receive_count - 1);
        }
        for (&work.send_ring) |*descriptor| descriptor.* = .{};
        card.toDevice(block, @sizeOf(Work));
        card.receive_next = 0;
        card.send_next = 0;
        card.send_done = 0;
        card.send_busy = 0;

        mac.setStation(at, &card.net.station);
        mac.setRings(
            at,
            block + @offsetOf(Work, "receive_ring"),
            block + @offsetOf(Work, "send_ring"),
            buffer_bytes,
        );
        setup.bringUp(at, card.part);
        mac.start(at);
        mac.setGroups(at, &card.hash);
        mac.startReceive(at, card.promiscuous != 0);
        setup.settled(at);
        card.running = 1;
        // Nothing of the interrupt is touched, here or in the stop
        // above: the causes are turned on once, when the task is ready
        // for them (`startInterrupts`), and stay on. The link is the
        // reason - a unit that is off line because its cable is out has
        // to hear the cable go back in, and it hears it on the cause the
        // controller raises. The link is not read here either: a link's
        // `setRunning` must not call back into the unit, which is part
        // way on line while it runs.
        //
        // **Nor is the PHY touched.** It is told once, where the card is
        // made, to negotiate, and it keeps the link by itself from then
        // on. Telling it again here would reset it, which drops the
        // carrier, which takes the unit off the line that this call is
        // putting it on - and the unit comes back on when the link
        // returns, and lands here again.
    }

    /// The card's causes turned on, which is done once the device's
    /// task is there to take them, and the link noted as raised so that
    /// the task reads what the link is doing now.
    pub fn startInterrupts(card: *Card) void {
        if (card.signalling == .none) return;
        mac.enableCauses(card.regs);
        card.raised |= raised_link;
        const base = card.base;
        if (base.ready != 0) card.sys.Signal(&base.task, base.int_mask);
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
    /// The controller is told once at the end that there is something to
    /// fetch, however many descriptors were filled.
    ///
    /// **A stopped controller is noticed here**, which is where a write
    /// is offered and so the one place something is known to be wanted
    /// of it: writes it has held for `stall_seconds` with none of them
    /// completing are a controller that has stopped, and it is started
    /// again before this write is put in a ring it would never leave.
    /// Nothing else would notice - what tells the device a send is done
    /// is the controller's own interrupt, and a controller that has
    /// stopped raises none.
    pub fn startWrites(card: *Card) void {
        const work = card.work orelse return;
        if (card.stalled()) card.restart();
        var filled = false;
        // One descriptor stays free: a ring whose tail catches its head
        // is an empty one.
        while (card.running != 0 and card.send_busy + 1 < send_count) {
            const req = card.net.nextWrite() orelse break;
            const slot = card.send_next;
            const length = card.net.buildFrame(req, &work.send[slot]);
            if (length == 0) continue;
            card.sending[slot] = req;
            card.send_next = (slot + 1) % send_count;
            if (card.send_busy == 0) card.stall_at = card.now();
            card.send_busy += 1;
            const buffer = @intFromPtr(&work.send[slot]);
            card.toDevice(buffer, length);
            ring.send(&work.send_ring[slot], buffer, length, slot == send_count - 1);
            card.toDevice(@intFromPtr(&work.send_ring[slot]), @sizeOf(ring.Transmit));
            filled = true;
        }
        if (filled) mac.pollSend(card.regs);
    }

    pub fn now(card: *Card) timer.TimeVal {
        return card.base.now();
    }

    /// Whether the controller has stopped working: writes it was given
    /// that it has neither sent nor failed for `stall_seconds`. A busy
    /// controller finishes a frame in microseconds, so the length of
    /// this is not a judgement about speed - anything this side of it is
    /// a controller that is not working at all.
    fn stalled(card: *Card) bool {
        if (card.running == 0 or card.send_busy == 0) return false;
        const at = card.stall_at;
        // Before the timer is open there is no clock to tell this by.
        if (at.secs == 0 and at.micro == 0) return false;
        const now_at = card.now();
        if (now_at.secs < at.secs) return false;
        return now_at.secs - at.secs >= stall_seconds;
    }

    /// The controller started again from the beginning: every write it
    /// held answered as failed, its rings laid out afresh and its
    /// receiver turned back on. The unit is left on line - the link is
    /// up, the cable has not moved, and the openers' reads are still
    /// theirs - so this is the rings and the controller and nothing
    /// above them. The PHY is not touched: it is keeping a link that is
    /// not what went wrong.
    pub fn restart(card: *Card) void {
        sdk.exec.kprintf(card.sys, "%s: unit %u: the controller stopped; starting it again\n", .{
            DEVICE_NAME,
            card.number,
        });
        card.setRunning(false);
        card.setRunning(true);
        card.net.overrun();
    }

    // --- the task's side of the rings -------------------------------------

    /// Every frame the controller has put in the ring, handed to the
    /// unit, and its descriptor given back.
    pub fn received(card: *Card) void {
        const work = card.work orelse return;
        while (card.running != 0) {
            const slot = card.receive_next;
            const descriptor: *volatile ring.Receive = &work.receive_ring[slot];
            card.fromDevice(@intFromPtr(descriptor), @sizeOf(ring.Receive));
            const command = descriptor.command;
            if (!ring.done(command)) break;
            const whole = ring.received_first | ring.received_last;
            const bytes = ring.frameBytes(descriptor);
            // What arrives carries its frame check sequence behind it,
            // which is no part of the frame.
            const length = if (bytes > crc_bytes) bytes - crc_bytes else 0;
            if (command & ring.received_fault != 0 or command & whole != whole or
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
            ring.give(descriptor, @intFromPtr(&work.receive[slot]), buffer_bytes, slot == receive_count - 1);
            card.toDevice(@intFromPtr(descriptor), @sizeOf(ring.Receive));
            card.receive_next = (slot + 1) % receive_count;
        }
    }

    /// Every write whose descriptor has come back answered, and the
    /// writes that waited for a descriptor started.
    pub fn sent(card: *Card) void {
        const work = card.work orelse return;
        while (card.send_busy > 0) {
            const slot = card.send_done;
            const descriptor: *volatile ring.Transmit = &work.send_ring[slot];
            card.fromDevice(@intFromPtr(descriptor), @sizeOf(ring.Transmit));
            if (!ring.done(descriptor.command)) break;
            card.finishSend(true);
            // The controller is working: whatever is still in its hands
            // has waited only since now.
            card.stall_at = card.now();
        }
        card.startWrites();
    }

    /// The descriptor at the head of the ring given up, and the write it
    /// carried answered.
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
        const state = link.state(card.regs);
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
pub const RealnetBase = extern struct {
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
    /// while a controller is being set up.
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
    pub fn now(base: *RealnetBase) timer.TimeVal {
        var time: timer.TimeVal = .{};
        if (base.timer_open != 0) {
            const timer_base: *TimerBase = @ptrCast(@alignCast(base.timer_io.node.device.?));
            timer_base.GetSysTime(&time);
        }
        return time;
    }

    /// The task kept for `us` microseconds, for the waits a controller
    /// asks for while it is set up. Without a timer there is nothing to
    /// wait on and the register polls stand in for it.
    pub fn pause(base: *RealnetBase, us: u32) void {
        if (base.timer_open == 0) return;
        base.timer_io.node.command = timer.TR_ADDREQUEST;
        base.timer_io.time = timer.TimeVal.fromMicros(us);
        _ = base.sys_base.DoIO(&base.timer_io.node);
    }
};

pub fn realnetBase(dev: *exec.Device) *RealnetBase {
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
