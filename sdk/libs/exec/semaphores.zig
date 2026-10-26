// SPDX-License-Identifier: MIT
//! Signal semaphores (exec/semaphores.h): locks between tasks, held
//! exclusively or shared, and Procure's bids.

const Node = @import("nodes.zig").Node;
const List = @import("lists.zig").List;
const Task = @import("tasks.zig").Task;
const ports = @import("ports.zig");

/// struct SemaphoreRequest: a waiter in ss_WaitQueue.
pub const SemaphoreRequest = extern struct {
    /// sr_Link
    link: Node = .{},
    /// sr_Waiter: the task asking (for a bid, the task that called Procure).
    waiter: ?*Task = null,
    /// Wants it shared.
    shared: bool = false,
    /// Has the semaphore.
    granted: bool = false,
    /// Procure's bid: replied instead of waking the waiter.
    bid: ?*SemaphoreMessage = null,
};

/// The bid's mn_Node.ln_Name: exclusive or shared.
pub const SM_EXCLUSIVE: usize = 0;
pub const SM_SHARED: usize = 1;

/// struct SemaphoreMessage: a bid for Procure.
pub const SemaphoreMessage = extern struct {
    /// ssm_Message: mn_ReplyPort gets it back; ln_Name is SM_EXCLUSIVE or
    /// SM_SHARED.
    msg: ports.Message = .{},
    /// ssm_Semaphore: the semaphore once granted, null if withdrawn.
    semaphore: ?*SignalSemaphore = null,
    /// The bid's place in ss_WaitQueue.
    request: SemaphoreRequest = .{},

    pub fn init(reply_port: *ports.MsgPort, shared: bool) SemaphoreMessage {
        return .{ .msg = .{
            .node = .{ .name = if (shared) @ptrFromInt(SM_SHARED) else null },
            .reply_port = reply_port,
            .length = @sizeOf(SemaphoreMessage),
        } };
    }

    /// Only 0 and 1 are valid; like the ROM, any non-zero ln_Name is
    /// taken as shared.
    pub fn isShared(bid: *const SemaphoreMessage) bool {
        return bid.msg.node.name != null;
    }
};

/// One semaphore a task holds, in its `Task.holds`: which, how often, and
/// whether shared. An entry whose semaphore is null is free.
pub const SemaphoreHold = extern struct {
    semaphore: ?*SignalSemaphore = null,
    count: u16 = 0,
    shared: bool = false,
};

/// A semaphore's `state`: how often it is held - by its owner, or by all
/// its shared holders together - in the low 16 bits.
pub const SEM_HOLDS: u32 = 0xFFFF;
/// Held exclusively, by `owner`.
pub const SEMF_EXCLUSIVE: u32 = 1 << 30;
/// Tasks are queued for it (`wait_queue`): its last release hands it to
/// them, under exec's semaphore lock.
pub const SEMF_WAITERS: u32 = 1 << 31;

/// struct SignalSemaphore. Set it up with InitSemaphore (or AddSemaphore).
pub const SignalSemaphore = extern struct {
    /// ss_Link: NT_SIGNALSEM; name and priority for public semaphores, or
    /// the link for ObtainSemaphoreList.
    link: Node = .{ .type = .signalsem },
    /// ss_NestCount's place, unused since exec 1.22: how often it is held
    /// is in `state`. Kept, so nothing after it moves.
    reserved: i16 = 0,
    /// ss_WaitQueue: SemaphoreRequests, oldest first.
    wait_queue: List = .{},
    /// ss_MultipleLink: the request ObtainSemaphoreList queues.
    multiple_link: SemaphoreRequest = .{},
    /// ss_Owner: the exclusive owner; null when free or held shared.
    owner: ?*Task = null,
    /// In ss_QueueCount's place: how often it is held, whether
    /// exclusively and whether tasks wait (`SEM_HOLDS`, `SEMF_*`); 0 when
    /// free. Changed by exec alone, atomically: a semaphore that can be
    /// had at once is taken and given back with one compare-and-swap on
    /// it, and exec's semaphore lock is taken only to queue for one and to
    /// hand it on.
    state: u32 = 0,

    /// How often it is held: by its owner, or by all its shared holders
    /// together. A moment's answer.
    pub fn nestCount(sem: *const SignalSemaphore) u16 {
        return @truncate(@atomicLoad(u32, &sem.state, .monotonic) & SEM_HOLDS);
    }
};
