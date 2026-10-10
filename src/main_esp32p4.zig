// SPDX-License-Identifier: MPL-2.0
//! The kernel for the ESP32-P4: started by the ROM from the image's RAM
//! segments (src/arch/esp32p4/start.S), it makes exec with L2MEM and the
//! PSRAM as its memory, starts the tick and the second core, and goes on
//! as the boot task: the `s3>` shell, or with `-Dselftest` the chip's
//! checks and exec's test tasks (selftest_esp32p4.zig). Its ROM holds the
//! S3 kernel's modules but the screen's and dma.resource.

const std = @import("std");
const builtin = @import("builtin");
const alert = @import("arch/esp32p4/alert.zig");
const bootstrap = @import("bootstrap.zig");
const clock = @import("arch/esp32p4/clock.zig");
const context = @import("arch/esp32p4/context.zig");
const cpu = @import("arch/esp32p4/cpu.zig");
const cpu1 = @import("arch/esp32p4/cpu1.zig");
const entropy = @import("arch/esp32p4/entropy.zig");
const flashmap = @import("arch/esp32p4/flashmap.zig");
const exec = @import("rom/libs/exec/exec.zig");
const intmatrix = @import("arch/esp32p4/intmatrix.zig");
const lastwords = @import("arch/esp32p4/lastwords.zig");
const layout = @import("arch/esp32p4/layout.zig");
const power = @import("arch/esp32p4/power.zig");
const psram = @import("arch/esp32p4/psram.zig");
const ram = @import("arch/esp32p4/ram.zig");
const selftest = @import("selftest_esp32p4.zig");
const shell = @import("rom/libs/exec/_shell/shell.zig");
const build_options = @import("build_options");
const timer = @import("arch/esp32p4/timer.zig");
const wdt = @import("arch/esp32p4/wdt.zig");
const boards = @import("boards/boards.zig");
const sdk = @import("sdk");
const st = sdk.expansion.systemtags;

comptime {
    _ = @import("arch/esp32p4/trap.zig"); // exports riscv_exception for start.S
    _ = @import("rom/devs/timer/timer.zig");
    _ = @import("rom/devs/flash/flash.zig");
    _ = @import("rom/devs/serial/serial.zig");
    _ = @import("rom/devs/usbserial/usbserial.zig");
    _ = @import("rom/devs/input/input.zig");
    _ = @import("rom/libs/keymap/keymap.zig");
    _ = @import("rom/libs/utility/utility.zig");
    _ = @import("rom/libs/expansion/expansion.zig");
    _ = @import("rom/resources/gpio/gpio.zig");
    _ = @import("rom/libs/dos/dos.zig");
    _ = @import("rom/libs/ramlib/ramlib.zig");
    _ = @import("rom/handler/nil/nil.zig");
    _ = @import("rom/handler/ram/ram.zig");
    _ = @import("rom/handler/con/con.zig");
    _ = @import("rom/handler/pipe/pipe.zig");
    _ = @import("rom/handler/flashfs/flashfs.zig");
    _ = @import("rom/shell/shell.zig");
    _ = @import("rom/resources/watchdog/watchdog.zig");
    _ = @import("rom/resources/platform/platform.zig");
    _ = @import("rom/devs/console/console.zig");
    _ = @import("rom/libs/rtg/rtg.zig");
    _ = @import("rom/libs/graphics/graphics.zig");
    _ = @import("rom/libs/layers/layers.zig");
    _ = @import("rom/libs/intuition/intuition.zig");
    _ = @import("rom/libs/motion/motion.zig");
    _ = @import("rom/release.zig");
    // The board's description: its system tag list, a ROM tag of its own.
    _ = &boards.system.system_tag;
    _ = boards.romtags;
}

pub const panic = std.debug.FullPanic(exec.kernelPanic);

/// The kernel prints with exec's kprintf; std.log isn't used, and says
/// nothing.
pub const std_options: std.Options = .{ .logFn = noLog };

fn noLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

/// The system log's ring, as large as the board says: exec keeps every
/// line from the first one in it.
var log_ring: [boards.fact(st.SYSTAG_LogSize, 16 * 1024)]u8 = undefined;

/// Called from _start before kmain, from the RAM part: what runs before
/// the kernel's code in flash is mapped. So it and everything it calls are
/// in .iram.text, without runtime safety.
export fn kernel_early() linksection(".iram.text") callconv(.c) void {
    @setRuntimeSafety(false);
    flashmap.map(boards.fact(st.SYSTAG_FlashSize, 16 * 1024 * 1024));
}

/// Core 1's stack, which its idle task goes on running on.
const cpu1_stack_size = 4096;

fn startCpu1(sys: *sdk.interface.exec.ExecBase) void {
    const stack = sys.AllocMem(cpu1_stack_size, exec.MEMF_INTERNAL) orelse {
        note("core 1: no memory for its stack", .{});
        return;
    };
    const lower = @intFromPtr(stack);
    const top = (lower + cpu1_stack_size) & ~@as(usize, 15);
    if (!exec.prepareCore(exec.SysBase, 1, lower, top)) {
        note("core 1: no memory for its idle task", .{});
        return;
    }
    if (cpu1.start(top)) note("core 1 up", .{}) else note("core 1 did not start", .{});
}

/// Called from _start with the stack set up and interrupts masked.
/// Nothing goes out on UART0 until exec's init has done RawIOInit; the log
/// keeps it all from the first line.
export fn kmain() callconv(.c) noreturn {
    cpu1.hold();
    wdt.disableAll();
    power.init();
    clock.init();
    const psram_result = psram.init(boards.fact(st.SYSTAG_PsramSpeed, 80));
    exec.log_ring.* = &log_ring;
    exec.log_clock.* = uptimeUs;
    exec.log_mirror.* = boards.fact(st.SYSTAG_LogMirror, 0) != 0;
    exec.setLogMirror();
    lastwords.restore();
    exec.interrupt_hardware.* = intmatrix.interrupt_hardware;
    exec.alert_hook.* = alert.show;
    exec.debug_hardware.* = &alert.debug_hardware;
    exec.task_hardware.* = context.hardware;
    intmatrix.init();
    entropy.init();
    var regions: [ram.max_regions]exec.MemRegion = undefined;
    // exec.library from its ROM tag; its init does RawIOInit, sets up the
    // rest, scans the ROM tags and creates the exec task. Task switching
    // stays off until startMultitasking below.
    _ = bootstrap.bootStrap(ram.regions(&regions)) catch |err| @panic(@errorName(err));

    exec.kprintf("PowerOS kernel for ESP32-P4 on %s, built with Zig %s (%s)\n", .{
        boards.text(st.SYSTAG_Name),
        builtin.zig_version_string,
        @tagName(builtin.mode),
    });
    if (lastwords.restored) note("the boot before ended in an alert: its last words are at the head of the log", .{});
    note("trap vector at 0x%08x, L2 cache %d KiB (CACHESIZE_CONF 0x%08x)", .{ cpu.trapVector() & ~@as(u32, 3), ram.l2CacheSize() / 1024, ram.l2CacheSizeConf() });
    // This code is exec's first task; from here on it is the boot task.
    const sys = exec.SysBase.iface();
    const boot_task = sys.FindTask(null).?;
    boot_task.node.name = "kernel";
    boot_task.sp_lower = layout.stackBottom();
    boot_task.sp_upper = layout.stackTop();
    if (psram_result) |_| {
        note("psram %d MiB at 0x%08x, vendor 0x%02x, %d MHz (strobe phase %d, delay line %d/%d of %d good)", .{
            psram.size >> 20,
            psram.base,
            psram.vendor,
            psram.bus_mhz,
            psram.tuned_phase,
            @as(u32, psram.tuned_delayline.data),
            @as(u32, psram.tuned_delayline.dqs),
            psram.tuned_window,
        });
    } else |err| {
        note("psram disabled: %s", .{@errorName(err).ptr});
    }
    note("%s %d.%d at 0x%08x", .{ exec.SysBase.lib.name(), exec.LIBRARY_VERSION, exec.LIBRARY_REVISION, @intFromPtr(exec.SysBase) });
    note("internal memory %d KiB free, external memory %d KiB free", .{
        sys.AvailMem(exec.MEMF_INTERNAL) / 1024,
        sys.AvailMem(exec.MEMF_EXTERNAL) / 1024,
    });
    timer.init(100);
    // The second core, where the build has one: let go once exec and the
    // tick's rate exist.
    cpu1.cores = boards.cores;
    if (boards.cores > 1) startCpu1(sys);
    note("chip v%d.%d, cpu clock %d MHz (measured %d MHz), tick %d Hz", .{
        clock.chipRevision() / 100,
        clock.chipRevision() % 100,
        clock.cpu_hz / 1_000_000,
        timer.measured_cpu_hz / 1_000_000,
        timer.tick_hz,
    });
    const supply = power.state();
    note("core supply: the converter at set-point %d, the internal regulator %s (level %d), always-on domain at level %d", .{
        supply.vset,
        if (supply.internal_on) "on" else "off",
        supply.dbias,
        supply.lp_dbias,
    });
    cpu.enableInterrupts();

    // Multitasking starts. The exec task runs first: it starts the
    // RTF_COLDSTART residents and ends. This task goes on as the boot task.
    exec.startMultitasking(exec.SysBase);
    // Until here core 1 ran only its idle task; from here it takes any
    // task that is not pinned.
    if (cpu1.isUp()) {
        sys.Disable();
        exec.SysBase.share_cores = 1;
        sys.Enable();
    }
    if (build_options.selftest) selftest.run(sys, boards.fact(st.SYSTAG_FlashSize, 16 * 1024 * 1024));

    // The shell's code is a task's code: it gets SysBase as the tasks of
    // CreateTask do, and when it returns, the task ends.
    const shell_code: exec.TaskFn = &shell.run;
    shell_code(sys);
    sys.RemTask(null);
    unreachable;
}

/// The microseconds since the boot, by SYSTIMER's unit 0: the log's clock.
fn uptimeUs() u64 {
    return timer.uptimeUs();
}

/// A kernel status line; the raw port puts the uptime in front.
fn note(comptime format: [:0]const u8, args: anytype) void {
    exec.kprintf(std.fmt.comptimePrint("{s}\n", .{format}), args);
}
