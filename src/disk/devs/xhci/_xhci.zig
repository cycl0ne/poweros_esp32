// SPDX-License-Identifier: MIT
//! What xhci.device's files share: the device's base, a controller's
//! block - its unit, its task, its rings, its device slots, its root
//! hub - and the small helpers every file uses.
//!
//! **A unit is a controller**: unit n is the nth xHCI function
//! pci.library found (class 0C0330). The first OpenDevice of a unit
//! makes its block and starts it - the function claimed, the controller
//! reset and running, its interrupt hooked: a message-signalled one
//! (MSI or MSI-X, vector 0, the first interrupter's) where pci.library
//! gives it one, its INTx line otherwise - and the last CloseDevice
//! stops it again.
//!
//! **Everything happens on the unit's task.** BeginIO puts a transfer on
//! the unit's port and the task takes it: a root hub request is answered
//! there (roothub.zig), a transfer goes on its endpoint's ring
//! (transfer.zig), and what the controller has to do first - a slot for
//! a device, its endpoints - is asked on the command ring and waited for
//! on the task (slots.zig, controller.zig). The interrupt only clears
//! what the controller raised and wakes the task.
//!
//! **The controller keeps a table of devices; usbhc does not.** A
//! request names a device by its bus address, and the controller wants
//! a slot for each device, made before the device has an address and
//! told where in the tree it is. The device bridges the two from the
//! requests themselves: a hub's port reset says where the next device
//! is, the first request to address 0 after it makes its slot, and the
//! SET_ADDRESS that follows binds the address to it (slots.zig).
//!
//! **Memory the controller reads or writes** is DMA memory, below 4 GiB,
//! in blocks of whole cache lines. What the driver writes there is out
//! before the controller is told, and what the controller wrote is read
//! afresh once the driver hears of it (`toDevice`, `fromDevice`). For a
//! controller that sees the processors' caches (PCIDevice.dma_coherent),
//! as the VisionFive 2's VL805 and QEMU's do, that is a fence each way,
//! which keeps the compiler from holding on to memory too: without the
//! one in `fromDevice` the VL805's root hub found no device behind it.
//! For one that does not, the lines are written back to memory, and
//! dropped from the caches before they are read.

const sdk = @import("sdk");
const exec = sdk.exec;
const usbhc = sdk.devices.usbhc;
const timer = sdk.devices.timer;
const pci = sdk.pci;
const ExecBase = sdk.interface.exec.ExecBase;
const PCIBase = sdk.interface.pci.PCIBase;
const ring = @import("ring.zig");
const regs = @import("regs.zig");

pub const DEVICE_NAME = "xhci.device";

/// How many controllers the device drives at most.
pub const max_units = 2;
/// The device slots a controller is given at most: devices on its bus,
/// hubs among them.
pub const max_slots = 32;
/// The root hub's ports at most: a hub's bitmap holds fifteen, and the
/// USB 2 ones come first.
pub const max_root_ports = 15;
/// TRBs on a transfer ring and on the command ring: a TD is three at most
/// - a control transfer's stages - and one TD is on a ring at a time.
pub const ring_trbs = 32;
/// An isochronous endpoint's: a TD a packet, and `iso_in_flight`
/// requests of up to UHC_ISO_PACKETS packets on it at once, with room to
/// spare. Its 4 KiB are aligned to their size, so the ring never crosses
/// a 64 KiB boundary.
pub const iso_ring_trbs = 256;
pub const iso_in_flight = 4;
/// TRBs on the event ring: a page.
pub const event_trbs = 256;
/// The bytes of a device's configuration the device keeps, from the
/// last time it was read whole: its endpoints, for SET_CONFIGURATION.
pub const config_bytes = 1024;
/// The least of an endpoint's buffer, and how much of a bulk transfer
/// goes in one round of it.
pub const bounce_min: u32 = 4 * 1024;
pub const bulk_round: u32 = 16 * 1024;
/// What every DMA block is aligned to and a whole number of: a cache
/// line, and what the controller wants of a context or a ring.
pub const dma_align: usize = 64;

/// xhci.device's base: what MakeLibrary allocated, and a block per
/// started controller.
pub const XhciBase = extern struct {
    dev: exec.Device,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    pci_base: ?*PCIBase = null,
    /// The xHCI functions pci.library has: the units there are.
    units: u32 = 0,
    hosts: [max_units]?*Host = @splat(null),
    /// Who may start and stop a unit: one opener at a time.
    open_lock: exec.SignalSemaphore = .{},
};

/// An endpoint of a device: its context's state as the driver set it,
/// its ring, its buffer, and the transfers on it.
pub const Endpoint = struct {
    /// It is in the slot's context (endpoint 0 from Address Device on).
    enabled: bool = false,
    /// What it was added as: its type (EP_*), packet size, interval.
    kind: u32 = 0,
    max_packet: u32 = 0,
    interval: u32 = 0,
    /// At SuperSpeed, from its companion descriptor: the packets of a
    /// burst less one, and a periodic one's bytes an interval (0: one
    /// packet's).
    burst: u32 = 0,
    esit: u32 = 0,
    ring: ring.Ring = .{},
    /// The ring's memory, for FreeMem when it is made again another size.
    ring_raw: ?*anyopaque = null,
    ring_raw_size: u32 = 0,
    /// Its buffer: what a transfer's data passes through.
    bounce: ?[*]u8 = null,
    bounce_size: u32 = 0,
    bounce_raw: ?*anyopaque = null,
    bounce_raw_size: u32 = 0,
    /// The request whose TD is on the ring, and those waiting for it.
    current: ?*usbhc.IOUsbHC = null,
    queue: exec.List = .{},
    /// The TD's TRBs: its data stage (0: none) and the one that ends it.
    data_trb: usize = 0,
    last_trb: usize = 0,
    /// This round's bytes; the transfer's moved before it.
    round: u32 = 0,
    done: u32 = 0,
    /// The data stage came back short: `round` is what came.
    short: bool = false,
    /// The empty packet that ends an OUT transfer is still to go.
    zero: bool = false,
    /// The controller halted it: it is reset before the next TD.
    halted: bool = false,
    /// An isochronous endpoint's requests on the ring, oldest first,
    /// `flying` of them; the slice of its buffer the next one's packets
    /// go in, and how far apart they are there.
    flight: exec.List = .{},
    flying: u32 = 0,
    next_slice: u32 = 0,
    stride: u32 = 0,
    /// The ring's next TD to be told of: its event names it, or one past
    /// it (a run of missed TDs is told once, at its end).
    expect: u32 = 0,
    /// A stream runs on it - a request went, and none was taken back
    /// since - and the frame after its last packet (`Host.frame`'s
    /// count).
    streaming: bool = false,
    next_frame: u32 = 0,
};

/// A device slot, and the device in it: where it is in the tree, what
/// the controller has been told of it.
pub const Slot = struct {
    id: u8,
    enabled: bool = false,
    /// Its bus address: 0 while it answers at the default address.
    address: u8 = 0,
    /// Address Device has given it its own address.
    addressed: bool = false,
    /// Its speed (SPEED_*), and where it is: the hub it is plugged into
    /// (a slot, 0 for the root hub), that hub's port, the root port the
    /// way down starts at, the route string, its hubs above it.
    speed: u32 = 0,
    parent: u8 = 0,
    port: u8 = 0,
    root_port: u8 = 0,
    route: u32 = 0,
    depth: u8 = 0,
    /// The transaction translator: its hub's slot and that hub's port.
    tt_slot: u8 = 0,
    tt_port: u8 = 0,
    /// A hub: its ports and its TT think time.
    hub: bool = false,
    hub_ports: u8 = 0,
    ttt: u8 = 0,
    /// The highest endpoint in its context.
    entries: u32 = 1,
    /// Its device context, which the controller writes, and the input
    /// context commands are given: DMA memory, made once.
    output: [*]u8 = undefined,
    input: [*]u8 = undefined,
    /// By device context index; 0 is not one.
    endpoints: [32]Endpoint = @splat(.{}),
    /// Its configuration, as last read whole.
    config: [config_bytes]u8 = undefined,
    config_length: u32 = 0,
};

/// The root hub's state: its address and configuration, and the
/// interrupt transfer that waits for a port to change.
pub const RootHub = struct {
    address: u8 = 0,
    configuration: u8 = 0,
    waiting: ?*usbhc.IOUsbHC = null,
};

/// A started controller: what its task, its interrupt and BeginIO share.
pub const Host = struct {
    dev_base: *XhciBase,
    sys: *ExecBase,
    number: u32,
    function: *pci.PCIDevice,
    /// Whether what it reads and writes in memory sees the processors'
    /// caches (PCIDevice.dma_coherent): then nothing is written back or
    /// dropped for it.
    coherent: bool = false,
    /// Where its register blocks are: BAR0, the operational registers,
    /// the runtime registers, the doorbells.
    regs: usize = 0,
    op: usize = 0,
    rt: usize = 0,
    db: usize = 0,
    /// What the capability registers say.
    version: u32 = 0,
    max_slots: u32 = 0,
    max_ports: u32 = 0,
    context_size: u32 = 32,
    page_size: u32 = 4096,
    scratchpads: u32 = 0,
    power_switched: bool = false,
    /// The root hub's ports: the controller's root ports, the USB 2 ones
    /// first. Each one's PORTSC number, and a bit per USB 3 one (from bit
    /// 1, as the hub numbers them).
    ports: u32 = 0,
    port_map: [max_root_ports]u8 = @splat(0),
    super_ports: u32 = 0,
    unit: exec.Unit = .{},
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    int: exec.Interrupt = .{},
    int_hooked: bool = false,
    /// Whether it is hooked on vector 0 (AllocPCIVectors), not on the
    /// INTx line.
    int_vector: bool = false,
    /// The task's signals: the interrupt, an abort, a command from an
    /// opener (start the controller, or stop it).
    int_signal: u32 = 0,
    abort_signal: u32 = 0,
    command_signal: u32 = 0,
    alive: u8 = 0,
    stopped: u8 = 0,
    /// It came up: running, its interrupt hooked.
    ready: u8 = 0,
    starter: ?*exec.Task = null,
    start_signal: i8 = -1,
    /// The task's own port, for its timers.
    port: ?*exec.MsgPort = null,
    tick_io: timer.TimeRequest = .{},
    tick_armed: u8 = 0,
    tick_due: u32 = 0,
    delay_io: timer.TimeRequest = .{},
    /// The controller's memory, made once: the device context base
    /// address array, the scratchpad, the rings, the segment table.
    memory_made: bool = false,
    dcbaa: [*]volatile u64 = undefined,
    commands: ring.Ring = .{},
    events: ring.EventRing = .{},
    erst: [*]volatile u32 = undefined,
    /// The command waited for: its TRB, and once it is done its code and
    /// the slot it names.
    command_trb: usize = 0,
    command_done: bool = false,
    command_code: u32 = 0,
    command_slot: u32 = 0,
    /// The slots by their ID, made as the controller first hands each
    /// out; and which slot each bus address is.
    slots: [max_slots + 1]?*Slot = @splat(null),
    by_address: [128]u8 = @splat(0),
    /// The slot that answers at address 0 now, if any.
    default_slot: u8 = 0,
    /// The last port reset: the hub's slot (0: the root hub) and the
    /// port; port 0 for none since.
    reset_hub: u8 = 0,
    reset_port: u8 = 0,
    root: RootHub = .{},
    /// Control transfers done that wait for what the task does after
    /// them before they are answered.
    posted: exec.List = .{},
    /// The frames since the controller started, counted on from MFINDEX
    /// each time it is read (`currentFrame`): the frame number read last,
    /// and the millisecond (`now`) it was read at; how many frames ahead
    /// an isochronous TD must be placed.
    frame: u32 = 0,
    frame_seen: u32 = 0,
    frame_ms: u32 = 0,
    iso_lead: u32 = 1,
};

/// hc_private[0]: the request's flags.
pub const PRIV_FLAGS = 0;
/// hc_private[1]: its deadline, in the task's milliseconds, with
/// PRIVF_DEADLINE.
pub const PRIV_DUE = 1;
/// hc_private[1], an isochronous request's: its packets too late for
/// the ring, missed before its first TD.
pub const PRIV_LATE = 1;
/// hc_private[2]: an isochronous request's TDs on the ring - the index
/// of its first TRB and its last - and the slice of the buffer it uses
/// (`spanOf`).
pub const PRIV_SPAN = 2;
/// hc_private[3]: AbortIO asked for it - written by BeginIO and AbortIO
/// only.
pub const PRIV_ABORT = 3;
pub const PRIVF_DEADLINE: usize = 1 << 0;

/// An isochronous request's PRIV_SPAN, and its parts.
pub fn spanOf(first: u32, last: u32, slice: u32) usize {
    return first | last << 12 | slice << 24;
}
pub fn spanFirst(span: usize) u32 {
    return @intCast(span & 0xFFF);
}
pub fn spanLast(span: usize) u32 {
    return @intCast((span >> 12) & 0xFFF);
}
pub fn spanSlice(span: usize) u32 {
    return @intCast((span >> 24) & 0xFF);
}

/// Whether an endpoint is an isochronous one: several requests on its
/// ring at once.
pub fn isIso(ep: *const Endpoint) bool {
    return ep.kind == regs.EP_ISOCH_OUT or ep.kind == regs.EP_ISOCH_IN;
}

/// Whether the endpoint can have its next request on the ring now.
pub fn hasRoom(ep: *const Endpoint) bool {
    if (!ep.enabled or ep.halted) return false;
    if (isIso(ep)) return ep.flying < iso_in_flight;
    return ep.current == null;
}

pub fn baseOf(dev: *exec.Device) *XhciBase {
    return @alignCast(@fieldParentPtr("dev", dev));
}

pub fn hostOf(io: *exec.IORequest) *Host {
    return @alignCast(@fieldParentPtr("unit", io.unit.?));
}

pub fn hcOf(io: *exec.IORequest) *usbhc.IOUsbHC {
    return @ptrCast(@alignCast(io));
}

pub fn requestOf(msg: *exec.Message) *usbhc.IOUsbHC {
    return @ptrCast(@alignCast(msg));
}

pub fn nodeOf(req: *usbhc.IOUsbHC) *exec.Node {
    return &req.std.req.message.node;
}

pub fn requestOfNode(node: *exec.Node) *usbhc.IOUsbHC {
    const msg: *exec.Message = @fieldParentPtr("node", node);
    return requestOf(msg);
}

pub inline fn reg(address: usize) *volatile u32 {
    return @ptrFromInt(address);
}

/// An operational register, and a runtime one.
pub inline fn op(host: *const Host, offset: usize) *volatile u32 {
    return reg(host.op + offset);
}

pub inline fn rt(host: *const Host, offset: usize) *volatile u32 {
    return reg(host.rt + offset);
}

/// The frames since the controller started: MFINDEX's frame number, its
/// steps since the last read added (`framesSince`).
pub fn currentFrame(host: *Host) u32 {
    const number = (rt(host, regs.MFINDEX).* & 0x3FFF) >> 3;
    const ms = now(host);
    host.frame +%= framesSince(host.frame_seen, number, ms -% host.frame_ms);
    host.frame_seen = number;
    host.frame_ms = ms;
    return host.frame;
}

/// The frames gone from frame number `seen` to `number`, `elapsed_ms`
/// apart: the number's steps, and as many whole rounds of its 2048 as
/// the clock says went by besides - a frame is a millisecond.
pub fn framesSince(seen: u32, number: u32, elapsed_ms: u32) u32 {
    const steps = (number -% seen) & 0x7FF;
    if (elapsed_ms <= steps) return steps;
    const rounds = (elapsed_ms - steps + 1024) / 2048;
    return steps + rounds * 2048;
}

/// A 64-bit register written as two words, low first.
pub fn write64(address: usize, value: u64) void {
    reg(address).* = @truncate(value);
    reg(address + 4).* = @truncate(value >> 32);
}

/// Slot `slot`'s doorbell rung for its endpoint `target` (0, target 0:
/// the command ring's). What was written for the controller is out to
/// memory before it hears.
pub fn ringDoorbell(host: *const Host, slot: u32, target: u32) void {
    asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    reg(host.db + 4 * @as(usize, slot)).* = target;
}

/// What the driver wrote at [address, address + bytes) out to memory,
/// for the controller to read. Where it sees the caches the writes are
/// only ordered before the register write that tells it, as Linux's
/// writel orders them (`fence w, o`).
pub fn toDevice(host: *const Host, address: usize, bytes: usize) void {
    if (host.coherent) {
        asm volatile ("fence w, o" ::: .{ .memory = true });
        return;
    }
    if (bytes == 0) return;
    var length: u32 = @intCast(bytes);
    _ = host.sys.CachePreDMA(@ptrFromInt(address), &length, 0);
}

/// The caches' copy of [address, address + bytes) dropped, so what the
/// controller wrote there is read. Where it sees the caches the reads are
/// only ordered after the register read that said it was written, as
/// Linux's readl orders them (`fence i, r`), and the compiler keeps
/// nothing of that memory from before.
pub fn fromDevice(host: *const Host, address: usize, bytes: usize) void {
    if (host.coherent) {
        asm volatile ("fence i, r" ::: .{ .memory = true });
        return;
    }
    if (bytes == 0) return;
    var length: u32 = @intCast(bytes);
    host.sys.CachePostDMA(@ptrFromInt(address), &length, 0);
}

/// A block of DMA memory, `bytes` of it at `alignment`, zeroed and out
/// of the caches; the raw block it is in, for FreeMem, in `raw`.
pub fn allocDma(host: *const Host, bytes: usize, alignment: usize, raw: ?*?*anyopaque) ?[*]u8 {
    const size = roundUp(bytes, dma_align);
    const raw_size = size + alignment;
    const memory = host.sys.AllocMem(@intCast(raw_size), exec.MEMF_DMA | exec.MEMF_CLEAR | exec.MEMF_SYSTEM) orelse return null;
    if (raw) |into| into.* = memory;
    const start = roundUp(@intFromPtr(memory), alignment);
    toDevice(host, start, size);
    return @ptrFromInt(start);
}

pub fn roundUp(value: usize, to: usize) usize {
    return (value + to - 1) & ~(to - 1);
}

/// The task's clock: milliseconds since the system started, wrapping.
pub fn now(host: *Host) u32 {
    var t: timer.TimeVal = .{};
    const tmb: *sdk.interface.timer.TimerBase = @ptrCast(host.delay_io.node.device.?);
    tmb.GetSysTime(&t);
    return @truncate(t.toMicros() / 1000);
}

/// Whether `a` is at or after `b` on the wrapping clock.
pub fn reached(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

/// `ms` milliseconds waited out on the task.
pub fn delay(host: *Host, ms: u32) void {
    host.delay_io.node.command = timer.TR_ADDREQUEST;
    host.delay_io.time = timer.TimeVal.fromMicros(@as(u64, ms) * 1000);
    _ = host.sys.DoIO(&host.delay_io.node);
}

/// A request answered: its error, and replied.
pub fn reply(host: *Host, req: *usbhc.IOUsbHC, err: i8) void {
    req.std.req.err = err;
    host.sys.ReplyIO(&req.std.req);
}

/// The slot a bus address is, if it is one.
pub fn slotAt(host: *Host, address: u8) ?*Slot {
    const id = if (address == 0) host.default_slot else host.by_address[address & 0x7F];
    if (id == 0) return null;
    const slot = host.slots[id] orelse return null;
    return if (slot.enabled) slot else null;
}

/// A slot's context `index` in its input context (0 the input control
/// context, 1 the slot's, 1 + DCI an endpoint's) and in its device
/// context (0 the slot's, DCI an endpoint's).
pub fn inputContext(host: *const Host, slot: *Slot, index: u32) [*]volatile u32 {
    return @ptrCast(@alignCast(slot.input + index * host.context_size));
}

pub fn outputContext(host: *const Host, slot: *Slot, index: u32) [*]volatile u32 {
    return @ptrCast(@alignCast(slot.output + index * host.context_size));
}

pub fn inputBytes(host: *const Host) usize {
    return 33 * @as(usize, host.context_size);
}

pub fn outputBytes(host: *const Host) usize {
    return 32 * @as(usize, host.context_size);
}
