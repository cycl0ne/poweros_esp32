// SPDX-License-Identifier: MPL-2.0
//! cores: how many cores the kernel runs on, what each is running and has
//! done, and whether the second one takes any task or only its own.

const _shell = @import("../shell.zig");
const cpu1 = @import("../../../../../arch/esp32s3/cpu1.zig");
const intmatrix = @import("../../../../../arch/esp32s3/intmatrix.zig");
const timer = @import("../../../../../arch/esp32s3/timer.zig");
const rendezvous = @import("../../../../../arch/esp32s3/rendezvous.zig");
const trap = @import("../../../../../arch/esp32s3/trap.zig");
const _cache = @import("../../cache/_cache.zig");
const Shell = _shell.Shell;
const Args = _shell.Args;

pub const name = "cores";
pub const usage = "cores [ping | share on|off | reset]";
pub const help =
    \\  cores                the cores the kernel runs on: what each runs, its
    \\                       dispatches, idle rounds and cross-core interrupts
    \\  cores ping           raise core 1's cross-core interrupt
    \\  cores share on|off   whether core 1 takes any task, or only its own
    \\  cores reset          clear the worst waits and holds below
    \\
    \\  Under each core: the longest it held the system's interrupt lock and the
    \\  longest it waited for it, each with the code that took it (1: an
    \\  exception); the longest a task waited inside Disable for Forbid; the cache
    \\  engine's longest wait and hold; and the longest it was parked. All of them
    \\  hold the core's interrupts off, so they are what makes one late.
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
        } else if (_shell.same(word, "reset")) {
            sys.Disable();
            for (&base.cpus) |*cpu| {
                cpu.lock_held_max = 0;
                cpu.lock_wait_max = 0;
                cpu.forbid_spin_max = 0;
            }
            _cache.engine_wait_max = @splat(0);
            trap.longest = @splat(0);
            trap.line_longest = @splat(@splat(0));
            intmatrix.source_longest = @splat(0);
            _cache.engine_held_max = @splat(0);
            rendezvous.parked_max = @splat(0);
            sys.Enable();
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
    shell.print("device sources over 50 us:", .{});
    for (intmatrix.source_longest, 0..) |cycles, source| {
        const us = cycles / @max(timer.cpu_hz / 1_000_000, 1);
        if (us > 50) shell.print(" %u: %u us", .{ @as(u32, @intCast(source)), us });
    }
    shell.print("\n", .{});
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
        const per_us = @max(timer.cpu_hz / 1_000_000, 1);
        shell.print("  interrupt lock held up to %u us (0x%08x), waited up to %u us (0x%08x); Forbid in Disable %u us\n", .{
            cpu.lock_held_max / per_us,
            @as(u32, @truncate(cpu.lock_held_where)),
            cpu.lock_wait_max / per_us,
            @as(u32, @truncate(cpu.lock_wait_where)),
            cpu.forbid_spin_max / per_us,
        });
        shell.print("  cache engine waited up to %u us, held up to %u us; parked up to %u us\n", .{
            _cache.engine_wait_max[core] / per_us,
            _cache.engine_held_max[core] / per_us,
            rendezvous.parked_max[core] / per_us,
        });
        shell.print("  longest exception %u us (cause %u, lines 0x%08x); lines over 50 us:", .{
            trap.longest[core] / per_us,
            trap.longest_cause[core],
            trap.longest_lines[core],
        });
        for (trap.line_longest[core], 0..) |cycles, line| {
            if (cycles / per_us > 50) shell.print(" %u: %u us", .{ @as(u32, @intCast(line)), cycles / per_us });
        }
        shell.print("\n", .{});
    }
}
