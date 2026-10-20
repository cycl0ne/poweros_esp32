// SPDX-License-Identifier: MIT
//! A queue: its submissions, in order, and the task that plays them.
//!
//! QueueSubmit puts a submission for each SubmitInfo on the queue's list
//! and signals its `work`; the task wakes, takes them one after the
//! other and plays each - waits for its semaphores, plays its command
//! buffers, signals its semaphores and its fence - and sleeps again when
//! the list is empty. What it plays shares a frame's tiles between the
//! cores (ShareWork), the task doing a part of them itself. QueuePresent
//! puts a submission on the list as well, of the images to be shown once
//! its semaphores are signalled: shown in turn with the work, each
//! returning when the display has taken it up.
//!
//! The task is the device's, made by CreateDevice and ended by
//! DestroyDevice, which waits until nothing runs on its stack any more.
//! On the host the tests' exec runs no other task: the submitting task
//! plays the work itself (`FacetBase.inline_queues`).

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;
const Device = @import("../device/_device.zig").Device;
const _command = @import("../command/_command.zig");
const CommandBuffer = _command.CommandBuffer;
const _sync = @import("../sync/_sync.zig");
const Fence = _sync.Fence;
const Semaphore = _sync.Semaphore;
const _play = @import("../command/_play.zig");
const _swapchain = @import("../swapchain/_swapchain.zig");
const Swapchain = _swapchain.Swapchain;

/// The bytes of a queue's task's stack: the rasterizer's setup and a
/// part of its tiles run on it, and the program's shader functions.
const stack_size = 32 * 1024;

pub const Queue = struct {
    device: *Device,
    family: u32 = 0,
    index: u32 = 0,
    /// Its task's priority, and the task and its stack once started.
    priority: i8 = 0,
    task: exec.Task = .{},
    stack: ?*anyopaque = null,
    started: bool = false,
    /// Signalled when there is work, or the task is to end.
    work: exec.Waitable = .{},
    quit: bool = false,
    /// Signalled while every submission is done.
    idle: exec.Waitable = .{},
    /// The submissions not yet taken, in order, and those not yet done,
    /// under `lock`.
    lock: exec.SignalSemaphore = .{},
    first: ?*Submission = null,
    last: ?*Submission = null,
    outstanding: u32 = 0,
    /// What playing keeps from one command to the next.
    player: _play.Player = .{},
};

/// One SubmitInfo, or one present, its arrays copied in after it.
pub const Submission = struct {
    next: ?*Submission = null,
    waits: []const *Semaphore,
    buffers: []const *CommandBuffer,
    signals: []const *Semaphore,
    fence: ?*Fence,
    /// The images shown once the semaphores are waited for.
    presents: []const Present = &.{},
};

/// An image of a swapchain to be shown.
pub const Present = struct {
    swapchain: *Swapchain,
    index: u32,
};

/// The queue made ready, and its task started unless the work is played
/// by whoever submits it. False when the task could not be made.
pub fn start(queue: *Queue, sys: *ExecBase, inline_queue: bool) bool {
    sys.InitSemaphore(&queue.lock);
    sys.SignalWaitable(&queue.idle);
    if (inline_queue) return true;
    const stack = sys.AllocVec(stack_size, exec.MEMF_CLEAR) orelse return false;
    queue.stack = stack;
    queue.task = .{
        .node = .{ .type = .task, .pri = queue.priority, .name = "facet.library queue" },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    _ = sys.AddTask(&queue.task, &queueTask, null);
    queue.started = true;
    return true;
}

/// The queue's task ended and waited for, and what it had given back.
/// False when there was no signal to wait with: the task is left running.
pub fn stop(queue: *Queue, sys: *ExecBase) bool {
    _play.finish(queue);
    if (!queue.started) return true;
    const port = sys.CreateMsgPort() orelse return false;
    defer sys.DeleteMsgPort(port);
    var ended: exec.Message = .{ .reply_port = port };
    sys.SetTaskEndMsg(&queue.task, &ended);
    @atomicStore(bool, &queue.quit, true, .release);
    sys.SignalWaitable(&queue.work);
    while (sys.GetMsg(port) == null) _ = sys.Wait(port.sigMask());
    sys.FreeVec(queue.stack);
    queue.started = false;
    return true;
}

fn queueTask(sys: *ExecBase) callconv(.c) void {
    const queue: *Queue = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const waitables = [1]*exec.Waitable{&queue.work};
    while (true) {
        _ = sys.WaitForAny(&waitables, 1, exec.WAIT_FOREVER);
        sys.ResetWaitable(&queue.work);
        drain(queue, sys);
        if (@atomicLoad(bool, &queue.quit, .acquire)) return;
    }
}

/// `infos` put on the queue, `fence` with the last; with none, `fence`
/// alone, signalled once all before it is done.
pub fn submit(queue: *Queue, sys: *ExecBase, infos: []const facet.SubmitInfo, fence: ?*Fence, inline_queue: bool) facet.Result {
    if (infos.len == 0 and fence == null) return .success;
    const count = @max(infos.len, 1);
    var made: ?*Submission = null;
    var tail: *?*Submission = &made;
    for (0..count) |k| {
        const info: facet.SubmitInfo = if (infos.len == 0) .{} else infos[k];
        const waits = arrayOf(Semaphore, info.wait_semaphores, info.wait_semaphore_count);
        const buffers = arrayOf(CommandBuffer, info.command_buffers, info.command_buffer_count);
        const signals = arrayOf(Semaphore, info.signal_semaphores, info.signal_semaphore_count);
        const submission = makeSubmission(sys, waits, buffers, signals, if (k == count - 1) fence else null, &.{}) orelse {
            freeAll(sys, made);
            return .error_out_of_host_memory;
        };
        tail.* = submission;
        tail = &submission.next;
    }
    var each = made;
    var last = made.?;
    while (each) |submission| : (each = submission.next) {
        for (submission.buffers) |buffer| _ = @atomicRmw(u32, &buffer.pending, .Add, 1, .monotonic);
        last = submission;
    }
    enqueue(queue, sys, made.?, last, @intCast(count), inline_queue);
    return .success;
}

/// The images of `presents` put on the queue, to be shown once `waits`
/// are signalled; false when memory ran out.
pub fn present(queue: *Queue, sys: *ExecBase, waits: []const *Semaphore, presents: []const Present, inline_queue: bool) bool {
    const submission = makeSubmission(sys, waits, &.{}, &.{}, null, presents) orelse return false;
    enqueue(queue, sys, submission, submission, 1, inline_queue);
    return true;
}

/// Submissions `first` to `last`, `count` of them, put at the end of
/// the list, and played.
fn enqueue(queue: *Queue, sys: *ExecBase, first: *Submission, last: *Submission, count: u32, inline_queue: bool) void {
    sys.ObtainSemaphore(&queue.lock);
    if (queue.outstanding == 0) sys.ResetWaitable(&queue.idle);
    queue.outstanding += count;
    if (queue.last) |previous| previous.next = first else queue.first = first;
    queue.last = last;
    sys.ReleaseSemaphore(&queue.lock);
    if (inline_queue) drain(queue, sys) else sys.SignalWaitable(&queue.work);
}

/// A submission of these, its arrays copied; null when memory ran out.
fn makeSubmission(sys: *ExecBase, waits: []const *Semaphore, buffers: []const *CommandBuffer, signals: []const *Semaphore, fence: ?*Fence, presents: []const Present) ?*Submission {
    const pointers = waits.len + buffers.len + signals.len;
    const presents_at = @sizeOf(Submission) + pointers * @sizeOf(usize);
    const memory = sys.AllocVec(presents_at + presents.len * @sizeOf(Present), exec.MEMF_ANY) orelse return null;
    const submission: *Submission = @ptrCast(@alignCast(memory));
    const after: [*]*anyopaque = @ptrFromInt(@intFromPtr(memory) + @sizeOf(Submission));
    const kept_waits: []*Semaphore = @ptrCast(after[0..waits.len]);
    const kept_buffers: []*CommandBuffer = @ptrCast(after[waits.len..][0..buffers.len]);
    const kept_signals: []*Semaphore = @ptrCast(after[waits.len + buffers.len ..][0..signals.len]);
    const kept_presents = @as([*]Present, @ptrFromInt(@intFromPtr(memory) + presents_at))[0..presents.len];
    @memcpy(kept_waits, waits);
    @memcpy(kept_buffers, buffers);
    @memcpy(kept_signals, signals);
    @memcpy(kept_presents, presents);
    submission.* = .{ .waits = kept_waits, .buffers = kept_buffers, .signals = kept_signals, .fence = fence, .presents = kept_presents };
    return submission;
}

/// An array of handles as the library's objects.
fn arrayOf(comptime T: type, handles: anytype, count: u32) []const *T {
    const given = handles orelse return &.{};
    return @as([*]const *T, @ptrCast(given))[0..count];
}

fn freeAll(sys: *ExecBase, first: ?*Submission) void {
    var each = first;
    while (each) |submission| {
        each = submission.next;
        sys.FreeVec(submission);
    }
}

/// Every submission on the list played, in order.
pub fn drain(queue: *Queue, sys: *ExecBase) void {
    while (true) {
        sys.ObtainSemaphore(&queue.lock);
        const taken = queue.first;
        if (taken) |submission| {
            queue.first = submission.next;
            if (queue.first == null) queue.last = null;
        }
        sys.ReleaseSemaphore(&queue.lock);
        const submission = taken orelse return;
        run(queue, sys, submission);
        sys.FreeVec(submission);
        sys.ObtainSemaphore(&queue.lock);
        queue.outstanding -= 1;
        if (queue.outstanding == 0) sys.SignalWaitable(&queue.idle);
        sys.ReleaseSemaphore(&queue.lock);
    }
}

/// One submission: its semaphores waited for and taken, its command
/// buffers played and its images shown, its semaphores and its fence
/// signalled.
fn run(queue: *Queue, sys: *ExecBase, submission: *const Submission) void {
    for (submission.waits) |semaphore| {
        const one = [1]*exec.Waitable{&semaphore.waitable};
        _ = sys.WaitForAny(&one, 1, exec.WAIT_FOREVER);
        sys.ResetWaitable(&semaphore.waitable);
    }
    for (submission.buffers) |buffer| {
        if (buffer.state == .executable) _play.play(queue, buffer);
        if (buffer.one_time) buffer.state = .spent;
        _ = @atomicRmw(u32, &buffer.pending, .Sub, 1, .release);
    }
    for (submission.presents) |each| _swapchain.show(each.swapchain, sys, each.index);
    for (submission.signals) |semaphore| sys.SignalWaitable(&semaphore.waitable);
    if (submission.fence) |fence| sys.SignalWaitable(&fence.waitable);
}

/// Wait until every submission is done.
pub fn waitIdle(queue: *Queue, sys: *ExecBase) void {
    const one = [1]*exec.Waitable{&queue.idle};
    _ = sys.WaitForAny(&one, 1, exec.WAIT_FOREVER);
}
