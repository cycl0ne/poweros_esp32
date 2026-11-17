// SPDX-License-Identifier: MPL-2.0
//! vchiq.resource's base: where the queue is - the doorbells, their
//! interrupt, the firmware's mailbox and the memory the kernel kept for
//! it - whether it runs, the task that reads what the firmware sends, the
//! locks, where the ARM is in its own slots and the firmware's, and the
//! services open, by their port.

const sdk = @import("sdk");
const exec = sdk.exec;
const vchiq = sdk.resources.vchiq;
const ExecBase = sdk.interface.exec.ExecBase;

/// How many services may be open at once. Port 0 is not given out: a
/// CLOSE to port 0 is the firmware's answer to an OPEN it refused.
pub const max_services = 8;

/// The queue: not started until the first service is opened, then
/// running - or dead, when the firmware did not take it.
pub const STATE_ASLEEP: u32 = 0;
pub const STATE_RUNNING: u32 = 1;
pub const STATE_DEAD: u32 = 2;

/// A service's state: an OPEN sent and no answer yet; open; a CLOSE sent
/// and the firmware's not yet; closed, by either side; refused.
pub const SERVICE_OPENING: u32 = 1;
pub const SERVICE_OPEN: u32 = 2;
pub const SERVICE_CLOSESENT: u32 = 3;
pub const SERVICE_CLOSED: u32 = 4;
pub const SERVICE_REFUSED: u32 = 5;

/// A message the firmware sent a service, copied out of its slot: the
/// bytes follow.
pub const Message = extern struct {
    next: ?*Message = null,
    size: u32 = 0,
    pad: u32 = 0,

    pub fn bytes(m: *Message) [*]u8 {
        return @as([*]u8, @ptrCast(m)) + @sizeOf(Message);
    }
};

/// The bulks of one direction out with the firmware, oldest first: they
/// are done in that order.
pub const Bulks = extern struct {
    first: ?*vchiq.VchiqBulk = null,
    last: ?*vchiq.VchiqBulk = null,
    count: u32 = 0,
};

/// A service open with the firmware: what the handle OpenService gives
/// points at.
pub const Service = extern struct {
    vb: *VchiqBase,
    state: u32 = SERVICE_OPENING,
    /// The ARM's port, its place in `services`, and the firmware's, from
    /// its OPENACK.
    localport: u32,
    remoteport: u32 = 0,
    /// The version of the service the firmware said it speaks.
    peer_version: u32 = 0,
    /// Signalled when `state` changes.
    changed: exec.Waitable = .{},
    /// Signalled while a message waits in `first`, and when the service
    /// is closed.
    arrived: exec.Waitable = .{},
    first: ?*Message = null,
    last: ?*Message = null,
    /// The bulks out, by direction (VCHIQBULK_*).
    bulks: [2]Bulks = .{ .{}, .{} },

    pub fn of(service: *vchiq.VchiqService) *Service {
        return @ptrCast(@alignCast(service));
    }

    pub fn handle(s: *Service) *vchiq.VchiqService {
        return @ptrCast(s);
    }
};

pub const VchiqBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// STATE_*, changed under `start_lock`.
    state: u32,
    /// The doorbells, their interrupt, and the firmware's mailbox.
    regs: usize,
    irq: u32,
    mailbox: usize,
    /// The memory the kernel kept, as the ARM has it and as the
    /// VideoCore names it, and its size; 0 when there is none.
    memory: usize,
    bus: u32,
    memory_bytes: usize,
    /// Held while the queue is started and services are opened.
    start_lock: exec.SignalSemaphore,
    /// Held while a message is written into the ARM's slots: one sender
    /// at a time, and none while the firmware has paused the queue.
    tx_lock: exec.SignalSemaphore,
    /// Held while the services' lists and states change.
    list_lock: exec.SignalSemaphore,
    /// The task that reads what the firmware sends, and the server on the
    /// doorbell that wakes it.
    task: ?*exec.Task,
    server: exec.Interrupt,
    hooked: bool,
    /// Signalled by the doorbell: for the task, and for a sender waiting
    /// for a slot the firmware gives back.
    rung: exec.Waitable,
    space: exec.Waitable,
    /// Signalled when the firmware's CONNECT came.
    connected: exec.Waitable,
    /// Where the ARM is in its own slots, past the last message it wrote,
    /// and in the firmware's, past the last it read: both counted in
    /// bytes from the start, as the shared state counts them.
    tx_pos: u32,
    rx_pos: u32,
    /// Whether the firmware paused the queue: the task holds `tx_lock`
    /// until it resumes it.
    paused: bool,
    /// The pagelists and fragments in use, a bit each.
    pagelists: u64,
    fragments: u64,
    /// The services open, by their port; port 0 stays empty.
    services: [max_services]?*Service,
};
