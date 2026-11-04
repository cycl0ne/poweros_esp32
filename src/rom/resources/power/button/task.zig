// SPDX-License-Identifier: MPL-2.0
//! The task behind the power button: it waits for the server's signal,
//! tells whoever asked to be told, and where nobody did, turns the
//! machine off itself.
//!
//! **What turning it off means here**: every drive a device feeds is
//! stopped first, so that a file system writes out what it is holding and
//! closes its medium, and only then is the machine turned off. A drive
//! that will not stop - a program still has something open on it - does
//! not hold the machine up: a press of the power button is an answer
//! already given.
//!
//! It is a task rather than the server itself because both halves of the
//! work want what an interrupt may not have: the resource's semaphore,
//! dos.library, and as long as a handler takes.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const drives = dos.blockdrives;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const PowerBase = @import("../power_base.zig").PowerBase;
const _notify = @import("../notify/_notify.zig");
const _machine = @import("../machine/_machine.zig");

/// Enough for dos's packets and the list of drives it gathers.
const stack_size = 8192;
/// Above the programs it is stopping drives for, so that a press is acted
/// on while the machine is busy.
const task_pri = 5;
const task_name = "power.resource";

/// The task started and waited for, on a machine whose button says when
/// it is pressed: it answers with the signal the server is to wake it
/// with, which is the task's own to allocate. False without memory for
/// its stack or a signal for it, and the button is then not taken at
/// all.
pub fn start(pb: *PowerBase) bool {
    const sys = pb.sys_base;
    const bit = sys.AllocSignal(-1);
    if (bit < 0) return false;
    defer sys.FreeSignal(bit);
    const stack = sys.AllocMem(stack_size, exec.MEMF_CLEAR) orelse return false;
    pb.stack = stack;
    pb.starter = sys.FindTask(null);
    pb.start_signal = @as(u32, 1) << @intCast(bit);
    pb.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = task_name },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + stack_size,
    };
    _ = sys.AddTask(&pb.task, &powerTask, null);
    _ = sys.Wait(pb.start_signal);
    return pb.press_signal != 0;
}

fn powerTask(sys: *ExecBase) callconv(.c) void {
    const pb: *PowerBase = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const bit = sys.AllocSignal(-1);
    pb.press_signal = if (bit < 0) 0 else @as(u32, 1) << @intCast(bit);
    if (pb.starter) |starter| {
        const answer = pb.start_signal;
        pb.starter = null;
        sys.Signal(starter, answer);
    }
    // A task with no signal to be woken with has nothing to wait for; its
    // stack stays with the resource, as a running task's would.
    if (pb.press_signal == 0) return;
    while (true) {
        _ = sys.Wait(pb.press_signal);
        sys.ObtainSemaphore(&pb.lock);
        const told = _notify.pressed(pb);
        sys.ReleaseSemaphore(&pb.lock);
        if (!told) turnOff(pb);
    }
}

/// The drives stopped and the machine turned off. Where it does not go
/// off, the drives are let go again: the machine is still running and is
/// to go on being usable.
fn turnOff(pb: *PowerBase) void {
    const sys = pb.sys_base;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0);
    var mounted: drives.List = .{};
    if (dos_lib) |lib| {
        const dl: *DosBase = @ptrCast(lib);
        mounted.gather(dl);
        _ = drives.holdAll(dl, &mounted, null);
    }
    _machine.off();
    // Still here: the machine would not go off.
    if (dos_lib) |lib| {
        const dl: *DosBase = @ptrCast(lib);
        drives.releaseAll(dl, &mounted);
        sys.CloseLibrary(lib);
    }
}
