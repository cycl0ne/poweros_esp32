// SPDX-License-Identifier: MPL-2.0
//! The kernel for an AArch64 machine under PSCI firmware: entered by the
//! firmware at EL2 or EL1 and brought to EL1 with its MMU on
//! (src/arch/a64psci/start.S), it takes the machine's figures from the
//! board and the device tree, makes exec with the RAM above the kernel as
//! its memory, starts the tick and goes on as the boot task.
//!
//! The ROM holds what runs on the machine's console, timer and RAM alone:
//! timer.device on the generic timer, serial.device on the console's
//! PL011, flash.device on the disk image the loader put in RAM (QEMU's
//! -initrd; the device tree says where), dos.library with its handlers
//! and the Shell, utility, expansion and platform. The boot task goes on
//! as the `s3>` debug shell on serial.device's unit 0, where `newshell`
//! starts the CLI on the disk.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const alert = @import("arch/a64psci/alert.zig");
const bootstrap = @import("bootstrap.zig");
const clock = @import("arch/a64psci/clock.zig");
const context = @import("arch/a64psci/context.zig");
const cpu = @import("arch/a64psci/cpu.zig");
const cpu1 = @import("arch/a64psci/cpu1.zig");
const debugexc = @import("arch/a64psci/debugexc.zig");
const device_tree = @import("arch/a64psci/fdt.zig");
const exec = @import("rom/libs/exec/exec.zig");
const gic = @import("arch/a64psci/gic.zig");
const layout = @import("arch/a64psci/layout.zig");
const mmu = @import("arch/a64psci/mmu.zig");
const ram = @import("arch/a64psci/ram.zig");
const screentext = @import("arch/screentext.zig");
const timer = @import("arch/a64psci/timer.zig");
const trap = @import("arch/a64psci/trap.zig");
const shell = @import("rom/libs/exec/_shell/shell.zig");
const boards = @import("boards/boards.zig");
const sdk = @import("sdk");
const hardware = sdk.hardware;
const st = sdk.expansion.systemtags;

/// The ROM's modules: their ROM tags go into .resident, where exec's boot
/// scan finds them. The board's list (src/boards/<board>/romtags.zig),
/// put together from the groups of src/rom/modules.zig and the drivers
/// of the board's own parts; a list, so the SDK's layout check
/// (sdk/sdk.zig) walks every structure the modules hold.
pub const rom_modules = boards.romtags.modules;

/// Where RAM starts, and the end of the window the boot maps as normal
/// memory before it has read the device tree.
const ram_base = boards.fact(st.SYSTAG_RamBase, 0x4000_0000);
const ram_end = boards.fact(st.SYSTAG_RamEnd, ram_base + boards.fact(st.SYSTAG_RamSize, 512 * 1024 * 1024));

comptime {
    _ = trap; // exports a64_exception for start.S
    _ = @import("rom/libs/exec/memory/libc.zig"); // memcpy, memmove, memset
    // Where RAM starts and ends, as symbols for start.S and kernel.ld: the
    // Image header's text_offset is the kernel's distance from the start,
    // and the boot's map makes the window between them normal memory.
    asm (std.fmt.comptimePrint(
            \\.globl _board_ram_base
            \\.set _board_ram_base, 0x{x}
            \\.globl _board_ram_end
            \\.set _board_ram_end, 0x{x}
        , .{ ram_base, ram_end }));
    // The board's description: its system tag list, a ROM tag of its own.
    _ = &boards.system.system_tag;
    _ = rom_modules;
}

pub const panic = std.debug.FullPanic(exec.kernelPanic);

/// The kernel prints with exec's kprintf; std.log isn't used, and says
/// nothing.
pub const std_options: std.Options = .{ .logFn = noLog };

fn noLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

/// The system log's ring, as large as the board says: exec keeps every
/// line from the first one in it.
var log_ring: [boards.fact(st.SYSTAG_LogSize, 16 * 1024)]u8 = undefined;

/// Where an exception's stack may be, for start.S: inside RAM, with room
/// for a frame above its start.
export var a64_stack_low: usize = 0;
export var a64_stack_high: usize = 0;

/// The rate the firmware gave the system counter, and the board's word
/// for it, kept for the boot's lines.
var counter_hz: u64 = 0;

/// Whether the firmware is PSCI: the device tree says how it is called,
/// or names no spin table, which a firmware without it would. The
/// Raspberry Pi 4's has none, and an HVC there goes to whatever its
/// armstub left at EL2.
var psci_there = true;

/// The picture the board's firmware lit, where it has one to hand over
/// (`boards.firmware_screen`): whether the kernel's lines go on it, and
/// whether it is the display driver's panel too.
var firmware_picture: ?hardware.videocore.Picture = null;
var screen_mine = false;
var screen_declared = false;

/// The machine's figures, from the board, into the SDK's and the arch
/// layer's variables: before anything reads them. RAM as the device tree
/// has it where it says, how PSCI is reached, and the disk image the
/// loader left.
fn takeBoard(tree: device_tree.Facts) void {
    hardware.uart.console = .{
        .base = boards.fact(st.SYSTAG_ConsoleBase, hardware.map.UART0),
        .clock_hz = @intCast(boards.fact(st.SYSTAG_ConsoleClock, 0)),
        .irq = @intCast(boards.fact(st.SYSTAG_ConsoleIrq, 0)),
    };
    // Its pins, where the firmware gave them to something else.
    if (boards.console_pins) |give| give();
    hardware.gic.dist_base = boards.fact(st.SYSTAG_GicDist, hardware.map.GICD);
    hardware.gic.cpu_base = boards.fact(st.SYSTAG_GicCpu, hardware.map.GICC);
    // The device tree says how the firmware is reached; without one, an
    // SMC where there is an EL2 to come from would be right, and QEMU's
    // HVC otherwise - but at EL1 the kernel cannot tell, so HVC.
    hardware.psci.conduit = switch (tree.psci) {
        .smc => .smc,
        .hvc, .unknown => .hvc,
    };
    // The counter's rate is the firmware's; the board's figure stands in
    // only for a firmware that left CNTFRQ_EL0 unset.
    counter_hz = hardware.cpu.counterFrequency();
    hardware.systimer.timebase_hz = if (counter_hz != 0 and counter_hz <= 0xFFFF_FFFF)
        @intCast(counter_hz)
    else
        @intCast(boards.fact(st.SYSTAG_Timebase, 62_500_000));
    hardware.system.before_reset = boards.before_reset;
    hardware.system.dma_coherent = boards.fact(st.SYSTAG_DmaCoherent, 0) != 0;
    for (tree.memoryRanges(), 0..) |range, index| ram.memory[index] = range;
    ram.memory_count = tree.memory_count;
    if (ram.memory_count == 0) {
        ram.memory[0] = .{ .start = ram_base, .end = ram_base + boards.fact(st.SYSTAG_RamSize, 512 * 1024 * 1024) };
        ram.memory_count = 1;
    }
    ram.dma_limit = boards.fact(st.SYSTAG_DmaLimit, 1 << 32);
    for (tree.reservedRanges(), 0..) |range, index| ram.reserved[index] = range;
    ram.reserved_count = tree.reserved_count;
    if (tree.initrd_start != null and tree.initrd_end != null and tree.initrd_end.? > tree.initrd_start.?) {
        hardware.ramdisk.base = tree.initrd_start.?;
        hardware.ramdisk.size = tree.initrd_end.? - tree.initrd_start.?;
    }
    a64_stack_low = ram.ramBase() + trap.frame_offset;
    a64_stack_high = ram.ramEnd();
    cpu1.takeCores(tree.coreIds(), tree.coreReleases(), cpu.mpidrs[0]);
    psci_there = tree.psci != .unknown or !cpu1.spinTables();
    // The Ethernet ports' station addresses, into the bytes the board's
    // parts point at.
    if (@hasDecl(boards.system, "stations")) {
        inline for (boards.system.stations) |station| {
            if (tree.stationAt(station[0])) |bytes| station[1].* = bytes;
        }
    }
    // Where the bootloader started the kernel from, for the board's
    // system list.
    if (@hasDecl(boards.system, "boot_start")) {
        boards.system.boot_start = .{ .partition = tree.boot_partition, .tried = @intFromBool(tree.boot_tried) };
    }
    if (@hasDecl(boards.system, "boot_mode")) boards.system.boot_mode = tree.boot_mode;
    // The memory the board's parts share with another master, kept from
    // exec (the board's `shared`, PART_SharedMemory); mapped without
    // caches once the map is finished (`uncacheShared`).
    if (@hasDecl(boards.system, "shared")) {
        inline for (boards.system.shared) |share| share.base = ram.keep(share.bytes, share.below) orelse 0;
    }
}

/// The memory kept for the board's parts made normal memory without
/// caches: written back from the caches and dropped from them before and
/// after - a line read ahead in between would otherwise stay there to be
/// written over the other master's writes. A block the map cannot change
/// is given up: its part finds no memory.
fn uncacheShared() void {
    if (!@hasDecl(boards.system, "shared")) return;
    inline for (boards.system.shared) |share| {
        const base = share.base;
        if (base != 0) {
            const end = base + ((share.bytes + ram.block - 1) & ~@as(usize, ram.block - 1));
            dropLines(base, end);
            if (!mmu.uncached(.{ .start = base, .end = end })) share.base = 0;
            dropLines(base, end);
        }
    }
}

/// Every cache line of `start` to `end` written back and dropped.
fn dropLines(start: usize, end: usize) void {
    var line = start;
    while (line < end) : (line += 64) asm volatile ("dc civac, %[at]"
        :
        : [at] "r" (line),
        : .{ .memory = true });
    asm volatile ("dsb sy" ::: .{ .memory = true });
}

/// Each other core's stack, which its idle task goes on running on.
const other_stack_size = 16 * 1024;

/// The other cores started in turn, as many as the board says and there
/// are cores for; the first that does not come up ends it.
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
            note("core %d (MPIDR 0x%lx) did not start: %s", .{ core, cpu.mpidrs[core], cpu1.answerName(cpu1.last_answer) });
            return;
        }
        note("core %d up (MPIDR 0x%lx)", .{ core, cpu.mpidrs[core] });
    }
}

/// Called from _start on the boot core, at EL1 with the MMU on, the stack
/// set up and interrupts masked: `mpidr` is the core's MPIDR_EL1, `fdt`
/// the device tree the firmware passed. Nothing goes out on the console
/// until exec's init has done RawIOInit; the log keeps it all from the
/// first line.
export fn kmain(mpidr: u64, fdt: usize) callconv(.c) noreturn {
    cpu.mpidrs[0] = mpidr & cpu.MPIDR_AFFINITY;
    cpu.identifyHere();
    hardware.cpu.startCycleCounter();
    // Read before exec has the memory it is in.
    takeBoard(device_tree.read(fdt));
    // Address 0 unmapped, the kernel's code read-only, RAM as the tree
    // says normal memory.
    mmu.refine(ram.ranges());
    uncacheShared();
    // The kernel's lines on the picture the firmware lit, on a board whose
    // firmware hands one over: from here, before exec, so a boot that stops
    // says where.
    screenFromFirmware();
    exec.log_ring.* = &log_ring;
    exec.log_clock.* = uptimeUs;
    exec.interrupt_hardware.* = gic.interrupt_hardware;
    exec.alert_hook.* = alert.show;
    exec.debug_hardware.* = &alert.debug_hardware;
    exec.task_hardware.* = context.hardware;
    debugexc.init();
    gic.init();
    var regions: [ram.max_regions]exec.MemRegion = undefined;
    // exec.library from its ROM tag; its init does RawIOInit, sets up the
    // rest, scans the ROM tags and creates the exec task. Task switching
    // stays off until startMultitasking below.
    _ = bootstrap.bootStrap(ram.regions(&regions), @min(boards.cores, cpu1.found)) catch |err| @panic(@errorName(err));

    exec.kprintf("PowerOS kernel for AArch64 on %s, built with Zig %s (%s)\n", .{
        boards.text(st.SYSTAG_Name),
        builtin.zig_version_string,
        @tagName(builtin.mode),
    });
    note("MPIDR 0x%lx, device tree at 0x%lx, vectors at 0x%lx", .{ cpu.mpidrs[0], @as(u64, fdt), @as(u64, cpu.vecbase()) });
    if (psci_there) {
        const psci_version = hardware.psci.version();
        note("PSCI %d.%d by %s", .{ psci_version >> 16, psci_version & 0xFFFF, @as([*:0]const u8, if (hardware.psci.conduit == .smc) "SMC" else "HVC") });
    } else note("no PSCI: the other cores wait on the firmware's spin table", .{});
    if (firmware_picture) |picture| {
        note("the firmware's picture: %dx%d at 0x%lx, %d bytes a row%s", .{
            picture.width,
            picture.height,
            @as(u64, picture.base),
            picture.pitch,
            @as([*:0]const u8, if (screen_declared) "" else if (build_options.logdebug) ", kept for the log (-Dlogdebug)" else ", in an order the display driver does not draw"),
        });
    } else if (boards.firmware_screen != null) note("the firmware lit no picture", .{});
    if (@hasDecl(boards.system, "boot_start")) {
        const start = &boards.system.boot_start;
        if (start.partition != 0) {
            note("started from partition %d%s", .{ start.partition, @as([*:0]const u8, if (start.tried != 0) ", for a try" else "") });
        } else {
            note("the bootloader did not say which partition it started from", .{});
        }
    }
    if (cpu.dcacheLine() != hardware.DCACHE_LINE_SIZE) {
        note("data cache lines of %d bytes, not the %d the kernel was built for", .{ cpu.dcacheLine(), @as(u32, hardware.DCACHE_LINE_SIZE) });
    }
    // This code is exec's first task; from here on it is the boot task.
    const sys = exec.SysBase.iface();
    const boot_task = sys.FindTask(null).?;
    boot_task.node.name = "kernel";
    boot_task.sp_lower = layout.stackBottom();
    boot_task.sp_upper = layout.stackTop();
    note("%s %d.%d at 0x%lx", .{ exec.SysBase.lib.name(), exec.LIBRARY_VERSION, exec.LIBRARY_REVISION, @as(u64, @intFromPtr(exec.SysBase)) });
    for (ram.ranges()) |range| {
        note("memory 0x%lx-0x%lx", .{ @as(u64, range.start), @as(u64, range.end) });
    }
    note("%ld KiB free", .{@as(u64, sys.AvailMem(exec.MEMF_ANY) / 1024)});
    for (ram.reserved[0..ram.reserved_count]) |range| {
        note("reserved 0x%lx-0x%lx", .{ @as(u64, range.start), @as(u64, range.end) });
    }
    if (@hasDecl(boards.system, "shared")) {
        inline for (boards.system.shared) |share| {
            if (share.base != 0) {
                note("kept 0x%lx-0x%lx without caches, shared with the firmware", .{ @as(u64, share.base), @as(u64, share.base + ((share.bytes + ram.block - 1) & ~@as(usize, ram.block - 1))) });
            } else note("no memory kept to share with the firmware: %ld KiB below 0x%lx asked for", .{ @as(u64, share.bytes / 1024), @as(u64, share.below) });
        }
    }
    if (hardware.ramdisk.size != 0) {
        note("disk image 0x%lx-0x%lx, %ld KiB", .{
            @as(u64, hardware.ramdisk.base),
            @as(u64, hardware.ramdisk.base + hardware.ramdisk.size),
            @as(u64, hardware.ramdisk.size / 1024),
        });
    } else note("no disk image", .{});
    note("random numbers from timing jitter: no generator", .{});
    if (exec.SysBase.mem_debug.on) note("memory debugging on since exec started (-Dmemdebug)", .{});
    // Who asks about a task that failed, so the machine need not stop.
    exec.failure.startHelper(exec.SysBase);
    // The cores' clock the board wants, before it is measured: where the
    // board's firmware sets it, it is asked (`boards.cpu_clock`).
    const cpu_speed = comptime boards.fact(st.SYSTAG_CpuSpeed, 0);
    if (cpu_speed != 0) if (boards.cpu_clock) |ask| {
        if (ask(sys, cpu_speed) == 0) note("cpu clock not set to %ld MHz: the firmware does not answer", .{@as(u64, cpu_speed)});
    };
    // The memory the board's reset tells the firmware of it in
    // (`boards.reset_notice`).
    if (boards.reset_notice) |keep| keep(sys);
    // The blocks the board's parts are in, where its firmware powers them
    // only when asked (`boards.firmware_power`).
    if (boards.firmware_power) |power| power(sys);
    // The display driver has the screen once the cold-start modules have
    // run, which is when the exec task that starts them ends: a hook on
    // that task (as on x86-64, main_x64uefi.zig).
    var screen_hooked = false;
    if (screen_mine and screen_declared) {
        if (sys.FindTask("exec")) |exec_task| {
            sys.AddTaskEndHook(exec_task, &screen_given);
            screen_hooked = true;
        }
    }
    timer.init(100);
    clock.init();
    // The other cores, where the board has them: let go once exec and the
    // tick's rate exist.
    cpu1.cores = boards.cores;
    startOthers(sys);
    note("cpu clock %d MHz (measured), system counter %d.%d MHz, tick %d Hz", .{
        timer.measured_cpu_hz / 1_000_000,
        hardware.systimer.timebase_hz / 1_000_000,
        hardware.systimer.timebase_hz / 100_000 % 10,
        timer.tick_hz,
    });
    cpu.enableInterrupts();

    // Multitasking starts. The exec task runs first: it starts the
    // RTF_COLDSTART residents and ends. This task goes on as the boot task.
    exec.startMultitasking(exec.SysBase);
    if (screen_mine and screen_declared and !screen_hooked) exec.setBoardMirror(null);
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

/// The microseconds since the machine came up, by the system counter: the
/// log's clock.
fn uptimeUs() u64 {
    return timer.uptimeUs();
}

/// A kernel status line; the raw port puts the uptime in front.
fn note(comptime format: [:0]const u8, args: anytype) void {
    exec.kprintf(std.fmt.comptimePrint("{s}\n", .{format}), args);
}

/// The picture the board's firmware lit, asked for and taken: its blocks
/// mapped without caches - the VideoCore reads it from memory - the
/// kernel's lines mirrored onto it, and the picture written into the
/// board's description for the display driver. With `-Dlogdebug` it stays
/// the log's: no panel is declared, so nothing draws over the lines.
fn screenFromFirmware() void {
    const screen = boards.firmware_screen orelse return;
    const picture = screen.ask() orelse return;
    firmware_picture = picture;
    _ = mmu.uncached(.{ .start = picture.base, .end = picture.base + picture.bytes });
    screen_mine = screentext.take(.{
        .base = picture.base,
        .width = picture.width,
        .height = picture.height,
        .stride = picture.pitch / 4,
    });
    if (screen_mine) exec.setBoardMirror(&screentext.hardware);
    if (!build_options.logdebug) screen_declared = screen.declare(picture);
}

/// The screen given back: what the kernel drew on it stops when the task
/// that ran the cold-start modules has ended, since the display driver
/// has the screen from then on. What was drawn is in the log as well,
/// which `Log` shows.
var screen_given: sdk.exec.TaskEndHook = .{ .code = &screenGiven };

fn screenGiven(_: *sdk.interface.exec.ExecBase, _: *sdk.exec.Task, _: *sdk.exec.TaskEndHook) callconv(.c) void {
    note("the screen is the display driver's", .{});
    exec.setBoardMirror(null);
}
