// SPDX-License-Identifier: MPL-2.0
//! The power button: the hardware it is reported on started, and the
//! server on the line it raises.
//!
//! The server does as little as a server must: it reads whether this is
//! the button, clears it so the line drops - the line is held down while
//! the hardware has something to report, so a press left uncleared would
//! raise it again at once, forever - and wakes the resource's task. Who
//! is told, and whether the machine goes off, is the task's business:
//! both want the resource's semaphore, which an interrupt may not take.

const sdk = @import("sdk");
const exec = sdk.exec;
const vec = exec.vec;
const PowerBase = @import("../power_base.zig").PowerBase;
const acpipm = @import("../source/acpipm.zig");
const task = @import("task.zig");

/// The hardware started, the task that answers a press started with it,
/// and the server put on the line. In that order, and all of it or none:
/// the server wakes the task, so there is no server before there is a
/// task to wake, and no press is taken before the hardware is in the
/// mode that reports one. False where the board named no line, the
/// hardware would not start, or the task did not - and then the machine
/// has no button as far as this system is concerned.
pub fn start(pb: *PowerBase) bool {
    const sys = pb.sys_base;
    if (!pb.hardware.button) return false;
    if (pb.source == 0) return false;
    if (!acpipm.start(pb.hardware)) return false;
    pb.started = true;
    if (!task.start(pb)) return false;
    pb.server = .{
        .node = .{ .type = .interrupt, .name = "power.resource" },
        .data = pb,
        .code = vec(buttonServer),
    };
    sys.AddIntServer(pb.source, &pb.server);
    pb.hooked = true;
    return true;
}

/// The server on the line the machine's power management raises. The line
/// is shared with everything else that hardware reports, so a press that
/// is not there is not this server's interrupt.
fn buttonServer(is_data: ?*anyopaque, int_number: u32) callconv(.c) i32 {
    _ = int_number;
    const pb: *PowerBase = @ptrCast(@alignCast(is_data.?));
    if (!acpipm.pressed(pb.hardware)) return 0;
    acpipm.clear(pb.hardware);
    pb.sys_base.Signal(&pb.task, pb.press_signal);
    return 1;
}
