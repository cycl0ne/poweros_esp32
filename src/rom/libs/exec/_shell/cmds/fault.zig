// SPDX-License-Identifier: MPL-2.0
//! fault [load|ill|stack]: a CPU exception on purpose - a load from an
//! address nothing answers, or an illegal instruction - or a task whose
//! stack runs past its end.

const builtin = @import("builtin");
const sdk = @import("sdk");
const reg = sdk.hardware.mmio.reg;
const _shell = @import("../shell.zig");
const _task = @import("../../task/_task.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "fault";
pub const usage = "fault [load|ill|stack]";
pub const help =
    \\  fault [load|ill|stack]  raise a CPU exception, or run a task off its stack
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const kind = args.next() orelse "load";
    if (_shell.same(kind, "ill")) {
        // Each core's own: Xtensa's ILL, RISC-V's all-zero instruction,
        // AArch64's permanently undefined one.
        switch (builtin.cpu.arch) {
            .riscv32, .riscv64 => asm volatile ("unimp"),
            .aarch64 => asm volatile ("udf #0"),
            else => asm volatile ("ill"),
        }
    } else if (_shell.same(kind, "load")) {
        shell.print("value: %x\n", .{reg(0x10).*});
    } else if (_shell.same(kind, "stack")) {
        const sys = shell.base.iface();
        if (sys.CreateTask("stack fault", 0, &overrun, 4096) == null) shell.print("fault: no memory for the task\n", .{});
    } else return error.Usage;
}

/// The stack the task runs off, and the room below it that what runs over
/// lands in: memory of its own, so nothing else is hurt before the
/// dispatcher's check finds the guard gone at the task's next switch.
const stack_size = 16 * 1024;
const moat_size = 64 * 1024;

/// The task: a block of its own, the upper part its stack - bounds and
/// guard set as NewStackRun sets them - and a call chain that never ends
/// on it, a millisecond a call, so the tick switches it away often.
fn overrun(sys: *sdk.interface.exec.ExecBase) callconv(.c) void {
    const block = sys.AllocMem(moat_size + stack_size, sdk.exec.MEMF_ANY) orelse return;
    const lower = @intFromPtr(block) + moat_size;
    const task = sys.FindTask(null).?;
    const flags: *volatile u8 = &task.flags;
    const sp_lower: *volatile usize = &task.sp_lower;
    const sp_upper: *volatile usize = &task.sp_upper;
    flags.* &= ~(sdk.exec.TF_GUARDED | sdk.exec.TF_WIDEGUARD);
    _task.writeGuard(lower, _task.guard_words);
    sp_lower.* = lower;
    sp_upper.* = lower + stack_size;
    flags.* |= sdk.exec.TF_GUARDED;
    _ = _task.task_hardware.call_on_stack(lower + stack_size, @ptrCast(&deeper), null);
}

/// A call that calls itself, its frame a few hundred bytes, for ever.
noinline fn deeper(arg: ?*anyopaque) callconv(.c) i32 {
    var frame: [256]u8 = undefined;
    const bytes: *volatile [256]u8 = &frame;
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index);
    sdk.hardware.systimer.spinUs(1000);
    return deeper(arg) +% bytes[0];
}
