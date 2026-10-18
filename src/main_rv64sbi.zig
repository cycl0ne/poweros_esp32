// SPDX-License-Identifier: MPL-2.0
//! The kernel for a RISC-V 64 machine under SBI firmware: entered by
//! OpenSBI in supervisor mode (src/arch/rv64sbi/start.S), it takes the
//! machine's figures from the board, makes exec with the RAM above the
//! kernel as its memory, starts the tick and goes on as the boot task.
//!
//! The ROM holds what runs on the machine's console, timer and RAM alone:
//! timer.device on the SBI timer, serial.device on the console's 16550,
//! flash.device on the disk image the loader put in RAM (QEMU's -initrd,
//! U-Boot's booti; the device tree says where), dos.library with its
//! handlers and the Shell, utility, expansion and platform. The boot task
//! goes on as the `s3>` debug shell on serial.device's unit 0, where
//! `newshell` starts the CLI on the disk.

const std = @import("std");
const builtin = @import("builtin");
const alert = @import("arch/rv64sbi/alert.zig");
const bootstrap = @import("bootstrap.zig");
const clock = @import("arch/rv64sbi/clock.zig");
const context = @import("arch/rv64sbi/context.zig");
const cpu = @import("arch/rv64sbi/cpu.zig");
const cpu1 = @import("arch/rv64sbi/cpu1.zig");
const device_tree = @import("arch/rv64sbi/fdt.zig");
const exec = @import("rom/libs/exec/exec.zig");
const plic = @import("arch/rv64sbi/plic.zig");
const layout = @import("arch/rv64sbi/layout.zig");
const ram = @import("arch/rv64sbi/ram.zig");
const timer = @import("arch/rv64sbi/timer.zig");
const trap = @import("arch/rv64sbi/trap.zig");
const shell = @import("rom/libs/exec/_shell/shell.zig");
const boards = @import("boards/boards.zig");
const sdk = @import("sdk");
const hardware = sdk.hardware;
const st = sdk.expansion.systemtags;

/// The ROM's modules: their ROM tags go into .resident, where exec's boot
/// scan finds them. A list rather than a row of imports, so the SDK's
/// layout check (sdk/sdk.zig) walks every structure they hold.
pub const rom_modules = .{
    @import("rom/devs/timer/timer.zig"),
    @import("rom/devs/flash/flash.zig"),
    @import("rom/devs/serial/serial.zig"),
    @import("rom/devs/input/input.zig"),
    @import("rom/devs/keyboard/keyboard.zig"),
    @import("rom/devs/mouse/mouse.zig"),
    @import("rom/libs/keymap/keymap.zig"),
    @import("rom/devs/console/console.zig"),
    @import("rom/libs/utility/utility.zig"),
    @import("rom/libs/expansion/expansion.zig"),
    @import("rom/libs/dos/dos.zig"),
    @import("rom/libs/ramlib/ramlib.zig"),
    @import("rom/handler/nil/nil.zig"),
    @import("rom/handler/ram/ram.zig"),
    @import("rom/handler/con/con.zig"),
    @import("rom/handler/pipe/pipe.zig"),
    @import("rom/handler/flashfs/flashfs.zig"),
    @import("rom/shell/shell.zig"),
    @import("rom/resources/platform/platform.zig"),
    @import("rom/libs/rtg/rtg.zig"),
    @import("rom/libs/graphics/graphics.zig"),
    @import("rom/libs/layers/layers.zig"),
    @import("rom/libs/intuition/intuition.zig"),
    @import("rom/libs/motion/motion.zig"),
    @import("rom/release.zig"),
    // The drivers the board's parts want.
    boards.romtags.modules,
};

comptime {
    _ = trap; // exports riscv_exception for start.S
    _ = @import("rom/libs/exec/memory/libc.zig"); // memcpy, memmove, memset
    // Where RAM starts, as a symbol for kernel.ld: the Image header's
    // text_offset is the kernel's distance from it.
    asm (std.fmt.comptimePrint(
            \\.globl _board_ram_base
            \\.set _board_ram_base, 0x{x}
        , .{boards.fact(st.SYSTAG_RamBase, 0x8000_0000)}));
    // The board's description: its system tag list, a ROM tag of its own.
    _ = &boards.system.system_tag;
    _ = rom_modules;
}

/// No display: exec's Software Failure has no intuition.library to ask
/// on, and leaves it out of the ROM (exec/failure/_failure.zig).
pub const rom_has_display = false;

pub const panic = std.debug.FullPanic(exec.kernelPanic);

/// The kernel prints with exec's kprintf; std.log isn't used, and says
/// nothing.
pub const std_options: std.Options = .{ .logFn = noLog };

fn noLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

/// The system log's ring, as large as the board says: exec keeps every
/// line from the first one in it.
var log_ring: [boards.fact(st.SYSTAG_LogSize, 16 * 1024)]u8 = undefined;

/// Where a trap's stack may be, for start.S: inside RAM, with room for a
/// frame above its start.
export var rv_stack_low: usize = 0;
export var rv_stack_high: usize = 0;

/// The machine's figures, from the board, into the SDK's and the arch
/// layer's variables: before anything reads them. RAM as the device tree
/// has it where it says, and the disk image the loader left.
fn takeBoard(tree: device_tree.Facts) void {
    hardware.uart.console = .{
        .base = boards.fact(st.SYSTAG_ConsoleBase, hardware.map.UART0),
        .shift = @intCast(boards.fact(st.SYSTAG_ConsoleShift, 0)),
        .wide = boards.fact(st.SYSTAG_ConsoleWide, 0) != 0,
        .clock_hz = @intCast(boards.fact(st.SYSTAG_ConsoleClock, 0)),
        .irq = @intCast(boards.fact(st.SYSTAG_ConsoleIrq, 0)),
    };
    hardware.plic.contexts = .{
        .first = @intCast(boards.fact(st.SYSTAG_PlicFirst, 1)),
        .stride = @intCast(boards.fact(st.SYSTAG_PlicStride, 2)),
    };
    hardware.systimer.timebase_hz = @intCast(boards.fact(st.SYSTAG_Timebase, 10_000_000));
    hardware.system.before_reset = boards.before_reset;
    hardware.ccache.flush64 = boards.fact(st.SYSTAG_CacheFlush, 0);
    ram.ram_base = tree.ram_base orelse boards.fact(st.SYSTAG_RamBase, 0x8000_0000);
    ram.ram_size = tree.ram_size orelse boards.fact(st.SYSTAG_RamSize, 128 * 1024 * 1024);
    for (tree.reservedRanges(), 0..) |range, index| ram.reserved[index] = range;
    ram.reserved_count = tree.reserved_count;
    if (tree.initrd_start != null and tree.initrd_end != null and tree.initrd_end.? > tree.initrd_start.?) {
        hardware.ramdisk.base = tree.initrd_start.?;
        hardware.ramdisk.size = tree.initrd_end.? - tree.initrd_start.?;
    }
    rv_stack_low = ram.ram_base + trap.frame_offset;
    rv_stack_high = ram.ramEnd();
    cpu1.takeHarts(tree.hartIds(), cpu.hartids[0]);
    // The Ethernet ports' station addresses, into the bytes the board's
    // parts point at.
    if (@hasDecl(boards.system, "stations")) {
        inline for (boards.system.stations) |station| {
            if (tree.stationAt(station[0])) |bytes| station[1].* = bytes;
        }
    }
}

/// Each other core's stack, which its idle task goes on running on.
const other_stack_size = 16 * 1024;

/// The other cores started in turn, as many as the board says and there
/// are harts for; the first that does not come up ends it.
fn startOthers(sys: *sdk.interface.exec.ExecBase) void {
    var core: u32 = 1;
    while (core < @min(cpu1.cores, cpu1.found)) : (core += 1) {
        const stack = sys.AllocMem(other_stack_size, exec.MEMF_ANY) orelse {
            note("core %d: no memory for its stack", .{core});
            return;
        };
        const lower = @intFromPtr(stack);
        const top = (lower + other_stack_size) & ~@as(usize, 15);
        if (!exec.prepareCore(exec.SysBase, core, lower, top)) {
            note("core %d: no memory for its idle task", .{core});
            return;
        }
        if (!cpu1.start(core, top)) {
            note("core %d (hart %ld) did not start", .{ core, @as(u64, cpu.hartids[core]) });
            return;
        }
        note("core %d up (hart %ld)", .{ core, @as(u64, cpu.hartids[core]) });
    }
}

/// Called from _start on the boot hart, with the stack set up and
/// interrupts masked: `hartid` is the hart's, `fdt` the device tree the
/// firmware passed. Nothing goes out on the console until exec's init has
/// done RawIOInit; the log keeps it all from the first line.
export fn kmain(hartid: usize, fdt: usize) callconv(.c) noreturn {
    cpu.hartids[0] = hartid;
    // Read before exec has the memory it is in.
    takeBoard(device_tree.read(fdt));
    exec.log_ring.* = &log_ring;
    exec.log_clock.* = uptimeUs;
    exec.interrupt_hardware.* = plic.interrupt_hardware;
    exec.alert_hook.* = alert.show;
    exec.task_hardware.* = context.hardware;
    plic.init();
    var regions: [ram.max_regions]exec.MemRegion = undefined;
    // exec.library from its ROM tag; its init does RawIOInit, sets up the
    // rest, scans the ROM tags and creates the exec task. Task switching
    // stays off until startMultitasking below.
    _ = bootstrap.bootStrap(ram.regions(&regions)) catch |err| @panic(@errorName(err));

    exec.kprintf("PowerOS kernel for RISC-V 64 on %s, built with Zig %s (%s)\n", .{
        boards.text(st.SYSTAG_Name),
        builtin.zig_version_string,
        @tagName(builtin.mode),
    });
    note("hart %ld, device tree at 0x%lx, trap vector at 0x%lx", .{ @as(u64, hartid), @as(u64, fdt), @as(u64, cpu.vecbase()) });
    note("SBI %ld.%ld, implementation %ld version 0x%lx", .{
        @as(u64, hardware.sbi.specVersion() >> 24),
        @as(u64, hardware.sbi.specVersion() & 0xFF_FFFF),
        @as(u64, hardware.sbi.implementationId()),
        @as(u64, hardware.sbi.implementationVersion()),
    });
    // This code is exec's first task; from here on it is the boot task.
    const sys = exec.SysBase.iface();
    const boot_task = sys.FindTask(null).?;
    boot_task.node.name = "kernel";
    boot_task.sp_lower = layout.stackBottom();
    boot_task.sp_upper = layout.stackTop();
    note("%s %d.%d at 0x%lx", .{ exec.SysBase.lib.name(), exec.LIBRARY_VERSION, exec.LIBRARY_REVISION, @as(u64, @intFromPtr(exec.SysBase)) });
    note("memory 0x%lx-0x%lx, %ld KiB free", .{
        @as(u64, ram.ram_base),
        @as(u64, ram.ramEnd()),
        @as(u64, sys.AvailMem(exec.MEMF_ANY) / 1024),
    });
    for (ram.reserved[0..ram.reserved_count]) |range| {
        note("reserved 0x%lx-0x%lx", .{ @as(u64, range.start), @as(u64, range.end) });
    }
    if (hardware.ramdisk.size != 0) {
        note("disk image 0x%lx-0x%lx, %ld KiB", .{
            @as(u64, hardware.ramdisk.base),
            @as(u64, hardware.ramdisk.base + hardware.ramdisk.size),
            @as(u64, hardware.ramdisk.size / 1024),
        });
    } else note("no disk image", .{});
    startGenerator();
    if (exec.SysBase.mem_debug.on) note("memory debugging on since exec started (-Dmemdebug)", .{});
    // Who asks about a task that failed, so the machine need not stop.
    exec.failure.startHelper(exec.SysBase);
    timer.init(100);
    clock.init();
    // The other cores, where the board has them: let go once exec and the
    // tick's rate exist.
    cpu1.cores = boards.cores;
    startOthers(sys);
    note("cpu clock %d MHz (measured), timebase %d MHz, tick %d Hz", .{
        timer.measured_cpu_hz / 1_000_000,
        hardware.systimer.timebase_hz / 1_000_000,
        timer.tick_hz,
    });
    cpu.enableInterrupts();

    // Multitasking starts. The exec task runs first: it starts the
    // RTF_COLDSTART residents and ends. This task goes on as the boot task.
    exec.startMultitasking(exec.SysBase);
    // Until here the other cores ran only their idle tasks; from here they
    // take any task that is not pinned.
    if (cpu1.isUp()) {
        sys.Disable();
        exec.SysBase.share_cores = 1;
        sys.Enable();
    }

    // The shell's code is a task's code: it gets SysBase as the tasks of
    // CreateTask do, and when it returns, the task ends.
    const shell_code: exec.TaskFn = &shell.run;
    shell_code(sys);
    sys.RemTask(null);
    unreachable;
}

/// The board's random number generator started, where it has one that
/// the kernel drives; sdk.hardware.rng finds it in the board's list.
fn startGenerator() void {
    const base = comptime boards.partFact(st.PARTKIND_RNG, st.PART_Address, 0);
    if (comptime base == 0 or boards.partFact(st.PARTKIND_RNG, st.PART_Chip, 0) != st.CHIP_JH7110_TRNG) {
        note("random numbers from timing jitter: no generator", .{});
        return;
    }
    if (hardware.trng.start(base)) {
        note("random number generator at 0x%lx", .{@as(u64, base)});
    } else note("random number generator at 0x%lx did not seed: random numbers from timing jitter", .{@as(u64, base)});
}

/// The microseconds since the machine came up, by `time`: the log's clock.
fn uptimeUs() u64 {
    return timer.uptimeUs();
}

/// A kernel status line; the raw port puts the uptime in front.
fn note(comptime format: [:0]const u8, args: anytype) void {
    exec.kprintf(std.fmt.comptimePrint("{s}\n", .{format}), args);
}
