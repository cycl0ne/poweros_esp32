// SPDX-License-Identifier: MPL-2.0
//! The kernel for an x86-64 machine started by UEFI firmware. The stub
//! (src/boot/uefi/stub.zig) asks the firmware for the machine, reads this
//! image into the pages it belongs in, leaves the firmware and calls
//! `kmain` with what it gathered (src/arch/x64uefi/start.S). From there the
//! kernel takes the machine's figures from the board, that handover and the
//! firmware's tables, makes its own map and descriptor tables, makes exec
//! with the memory the firmware called free, starts the tick and goes on as
//! the boot task.
//!
//! The ROM holds what runs on the machine's console, timer and RAM alone:
//! timer.device on the core's own counter, serial.device on the console's
//! 16550 in the I/O port space, flash.device on a disk image where the
//! stub found one beside itself, dos.library with its handlers and the
//! Shell, utility, expansion and platform. What the machine starts from
//! beyond that is the board's (`src/boards/<board>/romtags.zig`). The boot
//! task goes on as the `s3>` debug shell on serial.device's unit 0, where
//! `newshell` starts the CLI on the system disk.

const std = @import("std");
const builtin = @import("builtin");
const alert = @import("arch/x64uefi/alert.zig");
const apic = @import("arch/x64uefi/apic.zig");
const bootstrap = @import("bootstrap.zig");
const build_options = @import("build_options");
const clock = @import("arch/x64uefi/clock.zig");
const context = @import("arch/x64uefi/context.zig");
const cpu = @import("arch/x64uefi/cpu.zig");
const cpu1 = @import("arch/x64uefi/cpu1.zig");
const coretables = @import("arch/x64uefi/coretables.zig");
const desc = @import("arch/x64uefi/desc.zig");
const exec = @import("rom/libs/exec/exec.zig");
const firmware = @import("arch/x64uefi/firmware.zig");
const handover = @import("boot/uefi/handover.zig");
const layout = @import("arch/x64uefi/layout.zig");
const mmu = @import("arch/x64uefi/mmu.zig");
const ram = @import("arch/x64uefi/ram.zig");
const screentext = @import("arch/x64uefi/screen.zig");
const timer = @import("arch/x64uefi/timer.zig");
const trap = @import("arch/x64uefi/trap.zig");
const shell = @import("rom/libs/exec/_shell/shell.zig");
const boards = @import("boards/boards.zig");
const sdk = @import("sdk");
const hardware = sdk.hardware;
const st = sdk.expansion.systemtags;
const rtg = sdk.rtg;
const Tag = sdk.utility.FixedTagItem;

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
    @import("rom/resources/battmem/battmem.zig"),
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
    _ = trap; // exports x64_exception and x64_stack_fault for start.S
    _ = desc; // the descriptor tables start.S laid the ground for
    _ = @import("rom/libs/exec/memory/libc.zig"); // memcpy, memmove, memset
    // The board's description: its system tag list, a ROM tag of its own.
    _ = &boards.system.system_tag;
    _ = rom_modules;
}

pub const panic = std.debug.FullPanic(exec.kernelPanic);

/// The kernel prints with exec's kprintf; std.log isn't used, and says
/// nothing.
pub const std_options: std.Options = .{ .logFn = noLog };

fn noLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

/// The system log's ring, as large as the board says: exec keeps every line
/// from the first one in it.
var log_ring: [boards.fact(st.SYSTAG_LogSize, 16 * 1024)]u8 = undefined;

/// Where an exception's stack may be, for start.S: inside RAM, with room
/// for a frame above its start.
export var x64_stack_low: usize = 0;
export var x64_stack_high: usize = 0;

/// What the firmware's tables said, kept for the boot's lines.
var tables: hardware.acpi.Facts = .{};
/// Where the firmware's own table root was, and its system table.
var tables_at: usize = 0;
var system_table: usize = 0;
/// Where the firmware's framebuffer is, as the stub found it.
var screen: handover.Framebuffer = .{};
/// The panel part the kernel writes for that framebuffer, into the slot
/// the board's list keeps for it: the display driver asks
/// expansion.library for it and copies the picture into it
/// (`src/rom/libs/rtg_driver/fbboard/uefi.zig`). The tags are here, in the
/// kernel's own memory, because they say what the firmware did and not
/// what the board knows - and because SystemTags promises a list that
/// outlives everything and was never allocated.
var panel: [12]Tag = @splat(.done);
/// The battery-backed clock's part, written where the firmware's tables
/// do not say the machine is one of the few without that clock. Which of
/// its registers holds the century is theirs to say as well.
var clock_part: [7]Tag = @splat(.done);
/// PCI's part, where the firmware's tables say where its configuration
/// space is. What is behind the bridge the firmware has already placed,
/// and the kernel says so: moving anything would move the screen it is
/// drawing on, and the windows things may be placed in are written in the
/// tables' own language, which nothing here reads.
var pci_part: [12]Tag = @splat(.done);
/// The power management's part, where the firmware's tables say where its
/// registers are: power.resource turns the machine off through it and
/// hears its power button on it.
var power_part: [15]Tag = @splat(.done);
/// Whether that part was written, and whether the screen's memory takes
/// gathered writes: both go in the boot's lines.
var screen_declared = false;
var screen_gathered = false;

/// PCI's configuration space, written into the board's description as
/// its host bridge - with where a function's messages go, what the first
/// of them carries and which interrupt source it arrives on. On this
/// machine a message goes to a core's own interrupt controller rather
/// than to the bridge, so each has a source of its own and carries the
/// number its source's interrupt comes in on (`apic.vectorOf`).
fn takePci() void {
    if (tables.ecam_base == 0) return;
    pci_part = .{
        .value(st.PART_Kind, st.PARTKIND_PCI),
        .value(st.PART_Chip, st.CHIP_PCI_ECAM),
        .pointer(st.PART_ChipName, "pcie-ecam"),
        .value(st.PART_Bus, st.BUS_MEMORY),
        .value(st.PART_PciConfig, @intCast(tables.ecam_base)),
        .value(st.PART_PciPlaced, 1),
        .value(st.PART_PciMsiAddress, apic.messageAddress(0)),
        .value(st.PART_PciMsiData, apic.vectorOf(hardware.intbits.INTB_MSI_FIRST)),
        .value(st.PART_PciMsiSource, hardware.intbits.INTB_MSI_FIRST),
        .value(st.PART_PciMsiCount, hardware.intbits.INTB_MSI_COUNT),
        .pointer(st.PART_Label, "PCI Express"),
        .done,
    };
    _ = boards.system.addPart(&pci_part);
}

/// The machine's power management, written into the board's description:
/// the two register blocks it is reached through, the line it raises, and
/// whether its power button is one of its own features - all of it out of
/// the firmware's fixed description, which is where this hardware has
/// been written down since it existed. Nothing is written for a machine
/// whose tables named no such blocks, and power.resource then knows the
/// machine has no button; turning the machine off is the firmware's call
/// and wants no part at all.
fn takePower() void {
    if (tables.pm1_event == 0 or tables.pm1_control == 0) return;
    power_part = .{
        .value(st.PART_Kind, st.PARTKIND_POWER),
        .value(st.PART_Chip, st.CHIP_ACPI_PM),
        .pointer(st.PART_ChipName, "power management"),
        .value(st.PART_Bus, st.BUS_PORT),
        .value(st.PART_Address, tables.pm1_event),
        .value(st.PART_PowerEvent2, tables.pm1_event2),
        .value(st.PART_PowerControl, tables.pm1_control),
        .value(st.PART_PowerControl2, tables.pm1_control2),
        .value(st.PART_PowerEventBytes, tables.pm1_event_bytes),
        .value(st.PART_PowerMode, tables.mode_port),
        .value(st.PART_PowerModeValue, tables.mode_value),
        .value(st.PART_PowerButton, @intFromBool(tables.fixed_power_button)),
        .value(st.PART_Irq, tables.sci_line),
        .pointer(st.PART_Label, "power"),
        .done,
    };
    _ = boards.system.addPart(&power_part);
}

/// The machine's battery-backed clock, written into the board's
/// description as its RTC part: battclock.resource reads the date from it
/// as the system starts, and C:SetClock writes it.
fn takeClock() void {
    if (!tables.rtc) return;
    clock_part = .{
        .value(st.PART_Kind, st.PARTKIND_RTC),
        .value(st.PART_Chip, st.CHIP_MC146818),
        .pointer(st.PART_ChipName, "mc146818"),
        .value(st.PART_Bus, st.BUS_PORT),
        .value(st.PART_Address, hardware.map.RTC_INDEX),
        .value(st.PART_Century, tables.rtc_century),
        .done,
    };
    _ = boards.system.addPart(&clock_part);
}

/// The framebuffer the firmware lit, written into the board's description
/// as a panel part. Nothing is written where the firmware lit none, or
/// where its pixels are in an order the display driver does not draw in -
/// and the kernel says which, rather than leaving a blank screen
/// unexplained.
fn takeScreen() void {
    if (screen.base == 0) return;
    const format: rtg.PixelFormat = switch (screen.format) {
        .bgrx32 => .bgra32,
        else => return,
    };
    const bytes = rtg.formatBytes(format);
    panel = .{
        .value(st.PART_Kind, st.PARTKIND_PANEL),
        .value(st.PART_Chip, st.CHIP_UEFI_FB),
        .pointer(st.PART_ChipName, "uefi framebuffer"),
        .value(st.PART_Bus, st.BUS_MEMORY),
        .value(st.PART_Address, @intCast(screen.base)),
        .value(rtg.tags.RTGA_Width, screen.width),
        .value(rtg.tags.RTGA_Height, screen.height),
        // The firmware's rows are as far apart as it chose, which is not
        // always the width.
        .value(rtg.tags.RTGA_Pitch, screen.stride * bytes),
        .value(rtg.tags.RTGA_PixelFormat, @intFromEnum(format)),
        // At most sixteen pictures at once - screens, and the buffers
        // behind them - each taken from memory as it is opened: a ceiling,
        // not memory set aside.
        .value(rtg.tags.RTGA_Buffers, 16),
        // The windows of a screen each draw into a buffer of their own,
        // and what can be seen of them is copied into the screen's.
        .value(rtg.tags.RTGA_Compose, 1),
        .done,
    };
    screen_declared = boards.system.addPart(&panel);
}

/// The machine's figures, from the board, the handover and the firmware's
/// tables, into the SDK's and the arch layer's variables: before anything
/// reads them.
fn takeBoard(machine: *const handover.Handover) void {
    // The console first of all: the one thing that has to work before
    // anything can be said about the rest. The board names the port, and
    // the stub's figure stands in where the board says nothing - the stub
    // has already written its own lines to it.
    const board_port = boards.fact(st.SYSTAG_ConsoleBase, 0);
    hardware.uart.console = .{
        .port = if (board_port != 0) @intCast(board_port) else @intCast(machine.console_port),
        .clock_hz = @intCast(boards.fact(st.SYSTAG_ConsoleClock, hardware.map.UART_CLOCK_HZ)),
        .irq = @intCast(boards.fact(st.SYSTAG_ConsoleIrq, 4)),
    };
    system_table = @intCast(machine.system_table);
    tables_at = @intCast(machine.tables);
    screen = machine.framebuffer;
    takeScreen();

    // The firmware's tables: where the interrupt controllers are, what
    // cores there are, and how the machine's old lines are wired. The
    // board's figures stand where the tables said nothing.
    tables = hardware.acpi.read(tables_at);
    takeClock();
    takePci();
    takePower();
    // The firmware's own restart and its way to turn the machine off,
    // which only it can do: its runtime half is still where it left it.
    firmware.take(system_table);
    hardware.apic.lapic_base = if (tables.lapic_base != 0) @intCast(tables.lapic_base) else hardware.map.LAPIC;
    hardware.apic.io_count = 0;
    for (tables.controllers()) |controller| {
        if (hardware.apic.io_count == hardware.apic.MAX_IO_CONTROLLERS) break;
        hardware.apic.io[hardware.apic.io_count] = .{
            .base = @intCast(controller.address),
            .first_line = controller.first_line,
        };
        hardware.apic.io_count += 1;
    }
    if (hardware.apic.io_count == 0) {
        hardware.apic.io[0] = .{ .base = hardware.map.IOAPIC, .first_line = 0 };
        hardware.apic.io_count = 1;
    }
    // An old line wired somewhere other than its number says, or taken
    // other than the way its number implies.
    for (tables.wiring()) |line| {
        if (line.line >= hardware.intbits.INTB_GSI_COUNT) continue;
        apic.line_flags[line.line] = .{ .level = line.level, .low_active = line.low_active };
    }

    hardware.system.before_reset = boards.before_reset;
    hardware.system.dma_coherent = boards.fact(st.SYSTAG_DmaCoherent, 1) != 0;

    // The counter's rate, measured against the timer whose rate the
    // architecture fixes. Everything timed after this is timed by the
    // counter, so this is the one measurement in the boot.
    const measured = timer.measureTimebase(tables.pm_timer_port, tables.pm_timer_bits);
    hardware.systimer.timebase_hz = if (measured != 0)
        measured
    else
        @intCast(boards.fact(st.SYSTAG_Timebase, 1_000_000_000));

    for (machine.memoryRanges(), 0..) |range, index| ram.memory[index] = range;
    ram.memory_count = machine.memory_count;
    if (ram.memory_count == 0) {
        const base = boards.fact(st.SYSTAG_RamBase, 0x10_0000);
        ram.memory[0] = .{ .start = base, .end = base + boards.fact(st.SYSTAG_RamSize, 512 * 1024 * 1024) };
        ram.memory_count = 1;
    }
    ram.dma_limit = boards.fact(st.SYSTAG_DmaLimit, 1 << 32);
    for (machine.reservedRanges(), 0..) |range, index| ram.reserved[index] = range;
    ram.reserved_count = machine.reserved_count;
    if (machine.disk.end > machine.disk.start) {
        hardware.ramdisk.base = @intCast(machine.disk.start);
        hardware.ramdisk.size = @intCast(machine.disk.end - machine.disk.start);
    }
    if (@hasDecl(boards.system, "boot_start")) boards.system.boot_start.guid = machine.boot_partition;
    x64_stack_low = ram.ramBase() + trap.frame_offset;
    x64_stack_high = ram.ramEnd();
    // The page the other cores start on, which only the stub could have
    // found: it is below the first mebibyte, which the memory list leaves
    // out altogether.
    cpu1.low_page = @intCast(machine.low_page);
}

/// The highest address the kernel's map has to reach: the end of RAM, of
/// the firmware's screen, and of the mebibytes at the top of the first four
/// gibibytes where this architecture's devices are.
fn highestAddress() usize {
    var highest: usize = ram.ramEnd();
    if (screen.base != 0) highest = @max(highest, @as(usize, @intCast(screen.base + screen.size)));
    highest = @max(highest, 1 << 32);
    return highest;
}

/// Each other core's stack, which its idle task goes on running on.
const other_stack_size = 16 * 1024;

/// How many cores the system runs on: what the board asks for, down to
/// what the machine has - and every core it has where the board asks for
/// no number in particular, which is what a PC's board says.
fn runCores() u32 {
    if (boards.cores == 0) return cpu1.found;
    return @min(boards.cores, cpu1.found);
}

/// The other cores started in turn, as many as the board says and there are
/// cores for; the first that does not come up ends it.
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
            note("core %d (controller %d) did not start: %s", .{ core, cpu.lapic_ids[core], cpu1.answerName(cpu1.last_answer) });
            return;
        }
        note("core %d up (controller %d)", .{ core, cpu.lapic_ids[core] });
    }
    // What the machine has against what the system took: this architecture
    // is the first here whose machines commonly have more cores than exec
    // keeps state for, and a line that said only the four would read as if
    // the other four were missing.
    if (cpu1.in_machine > core) note("the machine has %d cores; the system runs on %d", .{ cpu1.in_machine, core });
}

/// Called from _boot by the stub's hand-over, with the stack set up, .bss
/// cleared, the core's number in place and interrupts masked: `at` is the
/// handover the stub wrote. Nothing goes out on the console until exec's
/// init has done RawIOInit; the log keeps it all from the first line.
export fn kmain(at: usize) callconv(.c) noreturn {
    // The SSE registers in use and a read-only page read-only here too,
    // before the map below makes the kernel's code read-only.
    cpu.setUpState();
    const machine: *const handover.Handover = @ptrFromInt(at);
    if (at == 0 or machine.magic != handover.MAGIC or machine.version != handover.VERSION) {
        earlyFailure("the stub handed over something this kernel does not know");
    }
    // Read before exec has the memory it is in.
    takeBoard(machine);
    // The descriptor tables, so an exception from here on is the kernel's.
    // They are one core's until the cores' tables are laid out below.
    desc.setUp();
    // Address 0 unmapped, the kernel's code read-only, everything else
    // where it was: the firmware's map is in memory about to be handed out.
    mmu.take(ram.ranges());
    // The cores' own tables, one set for every core the machine's tables
    // named, taken out of RAM: before exec, since GS points at a core's
    // block from this kernel's first instruction and nothing allocates
    // yet, and after the map above, since the firmware leaves pages of
    // what it calls free memory read-only. Then the cores' controller ids
    // into them.
    _ = coretables.take(cpu1.countCores(tables.core_count));
    cpu1.takeCores(&tables, cpu.prid());
    // The screen's own blocks made write-combining, now that the map is
    // the kernel's: a picture written word by word into uncached memory is
    // slow enough to be worth the two lines.
    if (screen.base != 0) {
        screen_gathered = mmu.gather(.{ .start = @intCast(screen.base), .end = @intCast(screen.base + screen.size) });
    }
    // The kernel's lines on that screen as well, until the cold start is
    // over and the display driver has it. A machine started by UEFI may
    // have no serial port at all - most made in the last ten years have
    // none - and then the screen is the only place its boot can be read.
    const screen_mine = screentext.take(screen);
    if (screen_mine) exec.setBoardMirror(&screentext.hardware);
    exec.log_ring.* = &log_ring;
    exec.log_clock.* = uptimeUs;
    exec.interrupt_hardware.* = apic.interrupt_hardware;
    exec.alert_hook.* = alert.show;
    exec.task_hardware.* = context.hardware;
    apic.init();
    var regions: [ram.max_regions]exec.MemRegion = undefined;
    // exec.library from its ROM tag; its init does RawIOInit, sets up the
    // rest, scans the ROM tags and creates the exec task. Task switching
    // stays off until startMultitasking below.
    _ = bootstrap.bootStrap(ram.regions(&regions), runCores()) catch |err| @panic(@errorName(err));

    exec.kprintf("PowerOS kernel for x86-64 on %s, built with Zig %s (%s)\n", .{
        boards.text(st.SYSTAG_Name),
        builtin.zig_version_string,
        @tagName(builtin.mode),
    });
    note("handover at 0x%lx, firmware tables at 0x%lx, system table at 0x%lx", .{ @as(u64, at), @as(u64, tables_at), @as(u64, system_table) });
    if (tables.found) {
        note("firmware tables: %d listed, local controller at 0x%lx, %d I/O controller(s), %d core(s), %d line(s) rewired", .{
            tables.listed,
            @as(u64, tables.lapic_base),
            tables.io_count,
            tables.core_count,
            tables.override_count,
        });
    } else note("the firmware's tables could not be read: the board's figures stand alone", .{});
    note("map: %s pages above the first gibibyte, up to 0x%lx", .{
        @as([*:0]const u8, if (mmu.large_pages) "1 GiB" else "2 MiB"),
        @as(u64, mmu.mapped_end),
    });
    if (!mmu.reaches(highestAddress())) {
        note("this machine reaches to 0x%lx, past what the map covers: what is above it is not reachable", .{@as(u64, highestAddress())});
    }
    if (!hardware.cpu.invariantTsc()) {
        note("the core does not say its counter runs at a fixed rate: the clock follows the core's speed", .{});
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
    if (hardware.ramdisk.size != 0) {
        note("disk image 0x%lx-0x%lx, %ld KiB", .{
            @as(u64, hardware.ramdisk.base),
            @as(u64, hardware.ramdisk.base + hardware.ramdisk.size),
            @as(u64, hardware.ramdisk.size / 1024),
        });
    } else note("no disk image", .{});
    if (screen.base == 0) {
        note("no screen the firmware lit", .{});
    } else if (!screen_declared) {
        note("screen %dx%d at 0x%lx: its pixels are in an order nothing here draws in, so no panel is declared", .{
            screen.width,
            screen.height,
            @as(u64, screen.base),
        });
    } else {
        note("screen %dx%d, stride %d, %ldK at 0x%lx, writes %s", .{
            screen.width,
            screen.height,
            screen.stride,
            @as(u64, screen.size / 1024),
            @as(u64, screen.base),
            @as([*:0]const u8, if (screen_gathered) "gathered" else "one by one: the map could not gather them"),
        });
    }
    note("random numbers from %s", .{
        @as([*:0]const u8, if (hardware.rng.fromHardware()) "the core's own generator" else "timing jitter: no generator"),
    });
    if (exec.SysBase.mem_debug.on) note("memory debugging on since exec started (-Dmemdebug)", .{});
    if (build_options.logdebug) note("the log keeps its debug lines, and cold start names each module (-Dlogdebug)", .{});
    // Who asks about a task that failed, so the machine need not stop.
    exec.failure.startHelper(exec.SysBase);
    timer.init(100);
    clock.init();
    // The other cores, where the board has them: let go once exec and the
    // tick's rate exist.
    cpu1.cores = runCores();
    startOthers(sys);
    note("counter %d.%d MHz (measured), tick %d Hz on vector %d, comparator %s", .{
        hardware.systimer.timebase_hz / 1_000_000,
        hardware.systimer.timebase_hz / 100_000 % 10,
        timer.tick_hz,
        timer.tick_irq,
        @as([*:0]const u8, if (timer.deadline_mode) "the counter's own deadline" else "the controller's timer, counted down"),
    });
    if (cpu.dcacheLine() != hardware.DCACHE_LINE_SIZE) {
        note("data cache lines of %d bytes, not the %d the kernel was built for", .{ cpu.dcacheLine(), @as(u32, hardware.DCACHE_LINE_SIZE) });
    }
    // The display driver has the screen once the cold-start modules have
    // run, which is when the exec task that starts them ends: a hook on
    // that task, rather than this one waiting for it. The exec task waits
    // for its workers before it starts a single module, so the switch
    // below comes back here long before the cold start is over - and a
    // module that never finishes still leaves the `s3>` shell to ask
    // with, with the screen's lines still saying how far the boot came.
    var screen_hooked = false;
    if (screen_mine) {
        if (sys.FindTask("exec")) |exec_task| {
            sys.AddTaskEndHook(exec_task, &screen_given);
            screen_hooked = true;
        }
    }
    cpu.enableInterrupts();
    // The first thing the machine's own interrupt hardware is asked for,
    // and what every timed wait rests on: a system whose tick never
    // arrives comes up all the same and then stops at the first module
    // that waits for a time, with nothing said about why. It is waited
    // for here instead - one tick, no longer - and said outright.
    const ticks_before = timer.tickCount();
    var waited_ms: u32 = 0;
    while (timer.tickCount() == ticks_before and waited_ms < 50) : (waited_ms += 1) timer.spinUs(1000);
    if (timer.tickCount() == ticks_before) {
        note("the tick on vector %d does not arrive: a timed wait will wait for good", .{timer.tick_irq});
    } else {
        step("interrupts on, the tick after %d ms", .{waited_ms});
    }
    // And the alarms on the same comparator, which are what a driver's
    // timed wait is made of: timer.device's units are two of them. One is
    // set here and waited for, since a module that waits for a time
    // cannot say from where it waits that nothing ever comes.
    const systimer = hardware.systimer;
    systimer.setAlarm(0, systimer.read() + systimer.fromUs(5_000), 0);
    var alarm_ms: u32 = 0;
    while (!systimer.takeAlarm(0) and alarm_ms < 50) : (alarm_ms += 1) timer.spinUs(1000);
    systimer.setAlarm(0, systimer.never, 0);
    if (alarm_ms == 50) {
        note("the alarms on that comparator do not come due: a timed wait will wait for good", .{});
    } else {
        step("the alarm set for 5 ms came due after %d ms", .{alarm_ms});
    }

    // Multitasking starts. The exec task runs first: it starts the
    // RTF_COLDSTART residents and ends. This task goes on as the boot task.
    exec.startMultitasking(exec.SysBase);
    step("multitasking", .{});
    // No exec task to hang that hook on, which is a system that will not
    // come up anyway: the screen goes back here, before a driver that has
    // it could be drawn over.
    if (screen_mine and !screen_hooked) exec.setBoardMirror(null);
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
    // The debug shell found no console to run on, which a machine
    // started by UEFI may well not have: no serial port, and the screen
    // the only place anything can be read. Where the kernel was asked to
    // keep its debug lines the screen goes back to being the system's
    // output - what was logged while it came up is put there, and what is
    // logged from now on follows it. Otherwise the screen stays the
    // display driver's: a machine that came up has a desktop to show, and
    // `C:Log` says what it said while it did.
    if (screen_mine and build_options.logdebug) showLog(sys);
    sys.RemTask(null);
    unreachable;
}

/// Something wrong before there is anything to report it with: the line
/// goes straight out of the console port, which the firmware and the stub
/// have both already used, and the core stops.
fn earlyFailure(comptime text: [:0]const u8) noreturn {
    hardware.uart.consoleInit();
    for ("\nkernel: ") |character| hardware.uart.consolePut(character);
    for (text) |character| hardware.uart.consolePut(character);
    hardware.uart.consolePut('\r');
    hardware.uart.consolePut('\n');
    cpu.halt();
}

/// The microseconds since the machine came up, by the core's counter: the
/// log's clock.
fn uptimeUs() u64 {
    return timer.uptimeUs();
}

/// A kernel status line; the raw port puts the uptime in front.
fn note(comptime format: [:0]const u8, args: anytype) void {
    exec.kprintf(std.fmt.comptimePrint("{s}\n", .{format}), args);
}

/// The screen given back: what the kernel drew on it stops when the task
/// that ran the cold-start modules has ended, since the display driver
/// has the screen from then on. What was drawn is in the log as well,
/// which `Log` shows.
var screen_given: sdk.exec.TaskEndHook = .{ .code = &screenGiven };

fn screenGiven(_: *exec.interface.ExecBase, _: *sdk.exec.Task, _: *sdk.exec.TaskEndHook) callconv(.c) void {
    step("the screen is the display driver's", .{});
    exec.setBoardMirror(null);
}

/// The system log on the screen, and the screen kept as its output.
/// Everything the machine said while it came up is in the log, and on a
/// machine with no console there is nothing else to show it with. The
/// lines go straight to the screen, without the marks the log's own
/// output would put in front of them again.
///
/// **After the rest of the boot**, not at once: what the display driver
/// draws would go over it, and the last thing the machine says about
/// itself is worth more than the first. Whatever is logged after this
/// follows it on the screen.
///
/// **Only where the kernel was asked for its debug lines**
/// (`-Dlogdebug`), since it draws over whatever the display driver has
/// put there: a machine that came up is better off showing its desktop,
/// and a boot that stops is read from the lines the kernel mirrors as it
/// writes them, which is a different path and always there.
fn showLog(sys: *exec.interface.ExecBase) void {
    waitSeconds(sys, log_after_seconds);
    screentext.restart();
    exec.setBoardMirror(&screentext.hardware);
    var number: u32 = 1;
    heading(number);
    var position: u64 = 0;
    var buffer: [512]u8 = undefined;
    while (true) {
        const count = sys.ReadLog(&position, &buffer, buffer.len);
        if (count == 0) break;
        for (buffer[0..count], 0..) |character, at| {
            screentext.show(buffer[at .. at + 1]);
            if (character != '\n') continue;
            if (screentext.rowsWritten() + 1 < screentext.rows()) continue;
            waitSeconds(sys, page_seconds);
            number += 1;
            screentext.turn();
            heading(number);
        }
    }
}

/// A page's first line, under two rows of nothing: a desktop's menu bar
/// is across the top of the screen and is drawn again whenever anything
/// in it changes, so what is written there does not stay. A row has to
/// hold something to be a row, so those two hold a space.
fn heading(number: u32) void {
    screentext.show(" \n \n");
    exec.kprintf("the system log, page %ld\n", .{@as(i64, number)});
}

/// How long the log waits for the rest of the boot before it is put on
/// the screen: long enough for the display driver, the disks and what
/// USB finds to have had their say.
const log_after_seconds = 12;

/// How long a page of it stays on the screen before the next one is
/// written over it: long enough to be read, and to be photographed on a
/// machine whose log can leave it no other way. The last page stays.
const page_seconds = 12;

/// `seconds` waited out on timer.device, or spun out where there is
/// none: this runs on the boot task, which has nothing else to do.
fn waitSeconds(sys: *exec.interface.ExecBase, seconds: u32) void {
    const micros = @as(u64, seconds) * 1_000_000;
    const port = sys.CreateMsgPort() orelse return timer.spinUs(micros);
    defer sys.DeleteMsgPort(port);
    var io: sdk.devices.timer.TimeRequest = .{};
    io.node.message.reply_port = port;
    io.node.message.length = @sizeOf(sdk.devices.timer.TimeRequest);
    if (sys.OpenDevice(sdk.interface.timer.NAME, sdk.devices.timer.UNIT_MICROHZ, &io.node, 0) != 0) {
        return timer.spinUs(micros);
    }
    defer sys.CloseDevice(&io.node);
    io.node.command = sdk.devices.timer.TR_ADDREQUEST;
    io.time = sdk.devices.timer.TimeVal.fromMicros(micros);
    _ = sys.DoIO(&io.node);
}

/// A line for a boot that stops: the places between the last status line
/// and the first module's own, which a machine that gets there says
/// nothing about. Only a kernel built with -Dlogdebug writes them.
fn step(comptime format: [:0]const u8, args: anytype) void {
    exec.klog(sdk.exec.LOG_DEBUG, std.fmt.comptimePrint("{s}\n", .{format}), args);
}
