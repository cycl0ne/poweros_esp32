// SPDX-License-Identifier: MPL-2.0
//! SetTaskEndMsg: a message replied once a task has ended and nothing runs
//! on its stack any more.

const sdk = @import("sdk");

const ExecBase = @import("../exec.zig").ExecBase;
const Task = sdk.exec.Task;
const Message = sdk.exec.Message;

/// Has `msg` replied to its reply port once `task` is gone.
///
/// SYNOPSIS:
/// ```zig
/// fn SetTaskEndMsg(base: *ExecBase, task: ?*Task, msg: ?*Message) void
/// ```
///
/// SINCE: 1.6. LVO -536.
///
/// INPUTS:
/// - `task` - the task; null for the caller.
/// - `msg` - the message, its reply port set; null takes one set before
///   back.
///
/// RESULT:
/// Nothing.
///
/// BEHAVIOR:
/// The message comes back once the task has ended - returned, or
/// `RemTask` - and the core it ran on has switched away from it, so nothing
/// runs on its stack any more; after its memory, if exec allocated it, has
/// been given back. That is the moment the code it ran may be unloaded and
/// the memory it ran in freed, which is what this is for: a server whose
/// sessions run its code, a device whose unit task does, waits for the
/// message before it lets that code go.
///
/// A message rather than a signal, so that one task waiting for many
/// counts every one: signals of the same bit run together, messages queue.
///
/// It is replied from the core's next exception exit after the switch, as
/// an interrupt would reply it - so the reply port signals its task or
/// ignores; a port that causes a software interrupt is not served.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no. It takes Disable.
/// - Locks: none needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The message is exec's from now until it comes back; its reply port must
/// still be there then.
///
/// NOTES:
/// **Set it before the task can end**: in the `Task` handed to `AddTask`
/// (`end_msg`), with dos's `NP_EndMsg` for a process, or from the task
/// itself. A task that ended already is gone, and nothing comes back.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `RemTask`, `AddTaskEndHook`, `AddTask`, `ReplyMsg`
///
/// EXAMPLES:
/// ```zig
/// var ended: Message = .{ .reply_port = port };
/// sys.SetTaskEndMsg(worker, &ended);
/// // ... once its code may go:
/// _ = sys.WaitPort(port);
/// _ = sys.GetMsg(port);
/// ```
pub fn SetTaskEndMsg(base: *ExecBase, task: ?*Task, msg: ?*Message) void {
    const sys = base.iface();
    sys.Disable();
    defer sys.Enable();
    const target = task orelse base.cpu().this_task;
    target.end_msg = msg;
}
