// SPDX-License-Identifier: MPL-2.0
//! A small bare-metal kernel for the ESP32-S3.

const std = @import("std");
const builtin = @import("builtin");
const alert = @import("arch/esp32s3/alert.zig");
const bootstrap = @import("bootstrap.zig");
const clock = @import("arch/esp32s3/clock.zig");
const context = @import("arch/esp32s3/context.zig");
const cpu = @import("arch/esp32s3/cpu.zig");
const exec = @import("rom/libs/exec/exec.zig");
const flashmap = @import("arch/esp32s3/flashmap.zig");
const intmatrix = @import("arch/esp32s3/intmatrix.zig");
const layout = @import("arch/esp32s3/layout.zig");
const psram = @import("arch/esp32s3/psram.zig");
const ram = @import("arch/esp32s3/ram.zig");
const shell = @import("rom/libs/exec/_shell/shell.zig");
const timer = @import("arch/esp32s3/timer.zig");
const wdt = @import("arch/esp32s3/wdt.zig");

comptime {
    _ = @import("arch/esp32s3/trap.zig"); // exports xtensa_exception for start.S
    // Resident modules: ROM tags in .resident, found by exec's boot scan.
    _ = @import("rom/devs/timer/timer.zig");
    _ = @import("rom/devs/flash/flash.zig");
    _ = @import("rom/devs/serial/serial.zig");
    _ = @import("rom/devs/usbserial/usbserial.zig");
    _ = @import("rom/devs/input/input.zig");
    _ = @import("rom/libs/keymap/keymap.zig");
    _ = @import("rom/devs/console/console.zig");
    _ = @import("rom/libs/utility/utility.zig");
    _ = @import("rom/libs/expansion/expansion.zig");
    _ = @import("rom/resources/gpio/gpio.zig");
    // The board's description: its system tag list, a ROM tag of its own,
    // and the drivers its parts want.
    _ = &@import("boards/boards.zig").system.system_tag;
    _ = @import("boards/boards.zig").romtags;
    _ = @import("rom/libs/dos/dos.zig");
    _ = @import("rom/libs/ramlib/ramlib.zig");
    _ = @import("rom/handler/nil/nil.zig");
    _ = @import("rom/handler/ram/ram.zig");
    _ = @import("rom/handler/con/con.zig");
    _ = @import("rom/handler/pipe/pipe.zig");
    _ = @import("rom/handler/flashfs/flashfs.zig");
    _ = @import("rom/shell/shell.zig");
    _ = @import("rom/resources/watchdog/watchdog.zig");
    _ = @import("rom/resources/dma/dma.zig");
    _ = @import("rom/resources/platform/platform.zig");
    _ = @import("rom/libs/rtg/rtg.zig");
    _ = @import("rom/libs/graphics/graphics.zig");
    _ = @import("rom/libs/layers/layers.zig");
    _ = @import("rom/libs/intuition/intuition.zig");
    // The system's release, for a program to ask the running system.
    _ = @import("rom/release.zig");
}

pub const panic = std.debug.FullPanic(exec.kernelPanic);

/// The kernel prints with exec's kprintf; std.log isn't used, and says
/// nothing.
pub const std_options: std.Options = .{ .logFn = noLog };

fn noLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

/// Called from _start before kmain, from IRAM: what runs before the
/// kernel's code in flash is mapped, or while the flash clock changes. So
/// it and everything it calls are in .iram.text, without runtime safety
/// (tools/ressize.zig checks that nothing here calls into flash).
export fn kernel_early() linksection(".iram.text") callconv(.c) void {
    @setRuntimeSafety(false);
    wdt.disableAll();
    if (!flashmap.find()) flashmap.halt("\r\n*** FATAL: the kernel's code isn't in flash after its RAM segments\r\n");
    clock.init();
    psram.init() catch |err| {
        psram.init_error = err;
    };
    flashmap.map();
}

/// Called from _start after kernel_early, with the stack set up and
/// interrupts masked. Nothing is printed until exec's init has done
/// RawIOInit (UART0, for kprintf).
export fn kmain() callconv(.c) noreturn {
    exec.interrupt_hardware.* = intmatrix.hardware;
    exec.alert_hook.* = alert.show;
    exec.task_hardware.* = context.hardware;
    intmatrix.init();
    var regions: [ram.max_regions]exec.MemRegion = undefined;
    // exec.library from its ROM tag; its init does RawIOInit, sets up the
    // rest, scans the ROM tags, creates the exec task and starts the
    // RTF_SINGLETASK residents. Task switching stays off until the Permit
    // below.
    _ = bootstrap.bootStrap(ram.regions(&regions)) catch |err| @panic(@errorName(err));

    exec.kprintf("PowerOS kernel for ESP32-S3, built with Zig %s (%s)\n", .{ builtin.zig_version_string, @tagName(builtin.mode) });
    note("vector table at 0x%08x", .{cpu.vecbase()});
    note("code in flash at 0x%08x: %d KiB from flash page %d", .{ layout.flashTextStart(), (layout.flashTextEnd() - layout.flashTextStart()) / 1024, flashmap.first_page });
    if (psram.init_error) |err| {
        note("psram disabled: %s", .{@errorName(err)});
    } else {
        note("psram %d MiB octal at 0x%08x, vendor 0x%02x", .{ psram.size >> 20, psram.base, psram.vendor });
    }
    // This code is exec's first task; from here on it is the shell.
    const sys = exec.SysBase.iface();
    const shell_task = sys.FindTask(null).?;
    shell_task.node.name = "shell";
    shell_task.sp_lower = layout.stackBottom();
    shell_task.sp_upper = layout.stackTop();
    note("%s %d.%d at 0x%08x", .{ exec.SysBase.lib.name(), exec.LIBRARY_VERSION, exec.LIBRARY_REVISION, @intFromPtr(exec.SysBase) });
    note("internal memory %d KiB free, external memory %d KiB free", .{
        sys.AvailMem(exec.MEMF_INTERNAL) / 1024,
        sys.AvailMem(exec.MEMF_EXTERNAL) / 1024,
    });
    timer.init(100);
    if (timer.cpu_hz != clock.cpu_hz) {
        note("cpu runs at %d MHz, not %d MHz (pll calibrated: %s); using the measured clock", .{
            timer.measured_cpu_hz / 1_000_000,
            clock.cpu_hz / 1_000_000,
            if (clock.pll_calibrated) "yes" else "no",
        });
    }
    note("cpu clock %d MHz, tick %d Hz", .{ timer.cpu_hz / 1_000_000, timer.tick_hz });
    cpu.enableInterrupts();
    note("interrupts enabled", .{});

    // Multitasking starts. The exec task runs first: it starts the
    // RTF_COLDSTART residents (dos.library last, which starts the
    // RTF_AFTERDOS ones) and ends. This task goes on as the shell.
    sys.Permit();

    // The shell's code is a task's code: it gets SysBase as the tasks of
    // CreateTask do, and when it returns, the task ends.
    const shell_code: exec.TaskFn = &shell.run;
    shell_code(sys);
    sys.RemTask(null);
    unreachable;
}

/// A kernel status line, the uptime in front.
fn note(comptime format: [:0]const u8, args: anytype) void {
    const us = timer.uptimeUs();
    exec.kprintf("[%4ld.%06ld] ", .{ us / 1_000_000, us % 1_000_000 });
    exec.kprintf(std.fmt.comptimePrint("{s}\n", .{format}), args);
}
