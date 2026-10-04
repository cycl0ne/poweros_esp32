// SPDX-License-Identifier: MPL-2.0
//! cores: how many cores the kernel runs on, what each is running and has
//! done, and whether the second one takes any task or only its own.

const _shell = @import("../shell.zig");
const cpu1 = @import("../../../../../arch/esp32s3/cpu1.zig");
const intmatrix = @import("../../../../../arch/esp32s3/intmatrix.zig");
const timer = @import("../../../../../arch/esp32s3/timer.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "cores";
pub const usage = "cores [ping | share on|off]";
pub const help =
    \\  cores                the cores the kernel runs on: what each runs, its
    \\                       dispatches, idle rounds and cross-core interrupts
    \\  cores ping           raise core 1's cross-core interrupt
    \\  cores share on|off   whether core 1 takes any task, or only its own
    \\
;

pub fn run(shell: *Shell, args: *Args) anyerror!void {
    const base = shell.base;
    const sys = base.iface();
    shell.print("%d core(s) built in\n", .{cpu1.cores});
    if (cpu1.cores < 2) return;
    if (!cpu1.isUp()) {
        shell.print("core 1 not running\n", .{});
        return;
    }
    if (args.next()) |word| {
        if (_shell.same(word, "ping")) {
            intmatrix.raiseCrossCore(1);
        } else if (_shell.same(word, "share")) {
            const setting = args.next() orelse return error.Usage;
            const share: u32 = if (_shell.same(setting, "on")) 1 else if (_shell.same(setting, "off")) 0 else return error.Usage;
            sys.Disable();
            base.share_cores = share;
            sys.Enable();
            // Core 1 looks at the ready list again.
            intmatrix.raiseCrossCore(1);
        } else return error.Usage;
    }
    shell.print("core 1 takes %s; it has ticked %u times\n", .{
        @as([*:0]const u8, if (base.share_cores != 0) "any task" else "only its own tasks"),
        timer.core1TickCount(),
    });
    for (0..base.cores_running) |core| {
        // Copied under Disable: the task may end once it is let go.
        var running: [24]u8 = undefined;
        sys.Disable();
        const cpu = &base.cpus[core];
        const task_name = cpu.this_task.name();
        const length = @min(task_name.len, running.len - 1);
        @memcpy(running[0..length], task_name[0..length]);
        running[length] = 0;
        const dispatches = cpu.disp_count;
        const idle_rounds = cpu.idle_count;
        sys.Enable();
        shell.print("core %u: running %s; %u dispatches, %u idle rounds, %u cross-core interrupts\n", .{
            @as(u32, @intCast(core)),
            @as([*:0]const u8, @ptrCast(&running)),
            dispatches,
            idle_rounds,
            intmatrix.cross_core_count[core],
        });
    }
}
