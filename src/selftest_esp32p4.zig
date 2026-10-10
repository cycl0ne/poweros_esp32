// SPDX-License-Identifier: MPL-2.0
//! What the ESP32-P4's kernel runs as its boot task until the shell runs
//! there: a check that the chip's blocks are where `sdk.hardware` says,
//! and exec exercised on both cores.
//!
//! - The hardware: nine blocks' version registers against what they read
//!   after reset, a copy memory to memory on each DMA engine, the random
//!   number generator, and 1 MiB of PSRAM written and read back - four
//!   times the L2 cache, so the words go out to the chip and come back.
//! - The flash through the ROM's routines, as flash.device drives it: its
//!   last sector kept, erased, written with a pattern a page at a time and
//!   read back through the window and over MSPI1, then put back.
//! - NewStackRun: code run on a stack of its own, and its answer.
//! - Two tasks that use the FPU, each with a value it checks after every
//!   step: a switch that lost or mixed up their FPU registers shows as an
//!   error.
//! - Two tasks that hand a signal back and forth, above the others: every
//!   round trip is two Waits and two Signals, each a switch.
//! - Two tasks that only count, at the same priority as the others, so the
//!   tick's time slice is what shares the cores between them.
//! - The ROM debugger on `d` from the console, looked for every second.
//! - A report every second, from an interrupt server on SYSTIMER's third
//!   alarm (AddIntServer, the matrix routing a device source): what each
//!   task got done, on which core, and how each core spent its time. The
//!   reporting task is above all of them, so it is heard even where ping
//!   and pong leave nothing to the tasks below them - on one core they
//!   always have one of the two ready.

const std = @import("std");
const exec = @import("rom/libs/exec/exec.zig");
const cpu = @import("arch/esp32p4/cpu.zig");
const timer = @import("arch/esp32p4/timer.zig");
const sdk = @import("sdk");
const hardware = sdk.hardware;
const reg = hardware.mmio.reg;
const gdma = hardware.gdma;
const systimer = hardware.systimer;

const ExecBase = sdk.interface.exec.ExecBase;
const spiflash = @import("rom/devs/flash/esp32p4/spiflash.zig");

/// A kernel status line; the raw port puts the uptime in front.
fn note(comptime format: [:0]const u8, args: anytype) void {
    exec.kprintf(std.fmt.comptimePrint("{s}\n", .{format}), args);
}

/// The checks, then the tasks, then a report every second; never returns.
/// `flash_size` is the board's, in bytes.
pub fn run(sys: *ExecBase, flash_size: u32) noreturn {
    checkHardware(sys);
    checkPsram(sys);
    checkFlash(sys, flash_size);
    checkNewStackRun(sys);
    // Above the tasks before they start: the first above it would take
    // the core at once.
    _ = sys.SetTaskPri(sys.FindTask(null).?, 2);
    startTasks(sys);
    report(sys);
}

// --- the hardware ---------------------------------------------------------------

/// The blocks `sdk.hardware` names, each found where it says: its version
/// register read against what it reads after reset (the clocks of those
/// the chip starts with them off turned on first); both DMA engines
/// copying a buffer memory to memory; the random number generator.
fn checkHardware(sys: *ExecBase) void {
    hardware.system.enable(.i2c0);
    gdma.init(.ahb);
    gdma.init(.axi);
    const Block = struct { name: [:0]const u8, date: usize, reset: u32 };
    const blocks = [_]Block{
        .{ .name = "UART0", .date = hardware.uart.baseOf(0) + hardware.uart.DATE, .reset = hardware.uart.DATE_RESET },
        .{ .name = "I2C0", .date = hardware.i2c.baseOf(0) + hardware.i2c.DATE, .reset = hardware.i2c.DATE_RESET },
        .{ .name = "SPI2", .date = hardware.map.SPI2 + hardware.gpspi.DATE, .reset = hardware.gpspi.DATE_RESET },
        .{ .name = "GPIO", .date = hardware.gpio.DATE, .reset = hardware.gpio.DATE_RESET },
        .{ .name = "IO_MUX", .date = hardware.gpio.IO_MUX_DATE, .reset = hardware.gpio.IO_MUX_DATE_RESET },
        .{ .name = "SYSTIMER", .date = systimer.DATE, .reset = systimer.DATE_RESET },
        .{ .name = "USB_SERIAL_JTAG", .date = hardware.usb_serial_jtag.DATE, .reset = hardware.usb_serial_jtag.DATE_RESET },
        .{ .name = "AHB_DMA", .date = gdma.baseOf(.ahb) + gdma.AHB_DATE, .reset = gdma.DATE_RESET },
        .{ .name = "AXI_DMA", .date = gdma.baseOf(.axi) + gdma.AXI_DATE, .reset = gdma.DATE_RESET },
    };
    var matching: u32 = 0;
    var others: [120]u8 = undefined;
    var length: usize = 0;
    for (blocks) |block| {
        if (reg(block.date).* == block.reset) {
            matching += 1;
            continue;
        }
        others[length] = ' ';
        @memcpy(others[length + 1 ..][0..block.name.len], block.name);
        length += 1 + block.name.len;
    }
    others[length] = 0;
    note("hardware: %d of %d blocks read their version%s%s", .{
        matching,
        blocks.len,
        @as([*:0]const u8, if (length != 0) "; not:" else ""),
        @as([*:0]const u8, @ptrCast(&others)),
    });
    for ([_]gdma.Engine{ .ahb, .axi }) |engine| {
        note("%s DMA, memory to memory: %s", .{
            @as([*:0]const u8, if (engine == .ahb) "AHB" else "AXI"),
            @as([*:0]const u8, if (copyByDma(sys, engine)) "copied" else "failed"),
        });
    }
    // The SAR ADC the generator draws its noise from, sampling: its last
    // conversion, twice.
    const adc_sar1_data_status = hardware.map.ADC + 0x40;
    const first = reg(adc_sar1_data_status).*;
    timer.spinUs(100);
    note("random: 0x%08x 0x%08x; noise source sampling: 0x%08x 0x%08x", .{
        hardware.rng.read(),
        hardware.rng.read(),
        first,
        reg(adc_sar1_data_status).*,
    });
}

/// A DMA descriptor: size and length, its flags, the buffer, the next -
/// padded to 16 bytes, so one after another each starts on 8, as the AXI
/// engine needs.
const Descriptor = extern struct { dw0: u32, buffer: u32, next: u32, pad: u32 = 0 };
const descriptor_owned_by_dma: u32 = 1 << 31;
const descriptor_suc_eof: u32 = 1 << 30;

var dma_descriptors: [2]Descriptor align(64) = undefined;
var dma_source: [64]u8 align(64) = undefined;
var dma_target: [64]u8 align(64) = undefined;

/// 64 bytes copied by channel 0 of `engine`, OUT to IN, with exec's
/// CachePreDMA and CachePostDMA around it - L2MEM is behind the L1 data
/// cache; whether they arrived within 10 ms.
fn copyByDma(sys: *ExecBase, engine: gdma.Engine) bool {
    for (&dma_source, 0..) |*byte, index| byte.* = @truncate(index * 7 + 3 + @intFromEnum(engine));
    @memset(&dma_target, 0);
    const length: u32 = dma_source.len;
    dma_descriptors[0] = .{
        .dw0 = descriptor_owned_by_dma | descriptor_suc_eof | (length << 12) | length,
        .buffer = @intFromPtr(&dma_source),
        .next = 0,
    };
    dma_descriptors[1] = .{ .dw0 = descriptor_owned_by_dma | length, .buffer = @intFromPtr(&dma_target), .next = 0 };
    var descriptors_length: u32 = @sizeOf(@TypeOf(dma_descriptors));
    var length_out: u32 = length;
    var length_in: u32 = length;
    _ = sys.CachePreDMA(&dma_descriptors, &descriptors_length, 0);
    _ = sys.CachePreDMA(&dma_source, &length_out, sdk.exec.DMAF_ReadFromRAM);
    _ = sys.CachePreDMA(&dma_target, &length_in, 0);

    gdma.connect(0, gdma.memToMem(engine), true, false, false, false);
    gdma.start(engine, 0, .in, @intFromPtr(&dma_descriptors[1]));
    gdma.start(engine, 0, .out, @intFromPtr(&dma_descriptors[0]));
    const since = timer.uptimeUs();
    while (gdma.rawIntStatus(engine, 0, .in) & gdma.IN_SUC_EOF == 0) {
        if (timer.uptimeUs() - since > 10_000) break;
    }
    const status = gdma.rawIntStatus(engine, 0, .in);
    gdma.disconnect(engine, 0);
    sys.CachePostDMA(&dma_target, &length_in, 0);
    if (status & gdma.IN_SUC_EOF == 0) return false;
    for (dma_source, dma_target) |sent, arrived| {
        if (sent != arrived) return false;
    }
    return true;
}

// --- PSRAM ----------------------------------------------------------------------

/// 1 MiB of external memory filled with a pattern of its addresses, then
/// read back, and the time each took.
fn checkPsram(sys: *ExecBase) void {
    const size = 1 << 20;
    const block = sys.AllocMem(size, exec.MEMF_EXTERNAL) orelse {
        note("psram: no 1 MiB block to test", .{});
        return;
    };
    defer sys.FreeMem(block, size);
    const words: [*]volatile u32 = @ptrCast(@alignCast(block));
    const count = size / 4;
    const began = timer.uptimeUs();
    for (0..count) |index| words[index] = @as(u32, @intCast(index)) *% 0x9E37_79B9 ^ 0x5A5A_A5A5;
    const written = timer.uptimeUs();
    var wrong: u32 = 0;
    for (0..count) |index| {
        if (words[index] != @as(u32, @intCast(index)) *% 0x9E37_79B9 ^ 0x5A5A_A5A5) wrong += 1;
    }
    const read = timer.uptimeUs();
    note("psram: 1 MiB at 0x%08x written in %u us, read back in %u us, %u words wrong", .{
        @as(u32, @intCast(@intFromPtr(block))),
        @as(u32, @intCast(written - began)),
        @as(u32, @intCast(read - written)),
        wrong,
    });
}

// --- the flash ------------------------------------------------------------------

/// The flash's last sector through esp32p4/spiflash.zig, each call with
/// interrupts off and core 1 held as flash.device makes them: its bytes
/// kept, the chip's size given to the ROM and its protection off, the
/// sector erased and written a page at a time with a pattern, the pattern
/// read back through the window and its first page over MSPI1, then the
/// kept bytes written back and compared.
fn checkFlash(sys: *ExecBase, chip_size: u32) void {
    const offset = chip_size - spiflash.sector_size;
    const window: [*]const volatile u8 = @ptrFromInt(hardware.map.FLASH_START + offset);
    const kept_block = sys.AllocMem(spiflash.sector_size, exec.MEMF_ANY) orelse {
        note("flash: no memory to keep a sector in", .{});
        return;
    };
    defer sys.FreeMem(kept_block, spiflash.sector_size);
    const kept: [*]u8 = @ptrCast(kept_block);
    for (0..spiflash.sector_size) |index| kept[index] = window[index];

    const rom_size = spiflash.size();
    sys.Disable();
    sys.HoldOtherCores();
    const sized = spiflash.setSize(chip_size);
    const unlocked = spiflash.unlock();
    sys.ReleaseOtherCores();
    sys.Enable();

    const began = timer.uptimeUs();
    const commands = sized and unlocked and eraseHeld(sys, offset);
    const erased = timer.uptimeUs();
    var blank = true;
    for (0..spiflash.sector_size) |index| {
        if (window[index] != 0xFF) blank = false;
    }
    const programmed = commands and writeHeld(sys, offset, null);
    const written = timer.uptimeUs();
    var in_window = programmed;
    for (0..spiflash.sector_size) |index| {
        if (window[index] != patternByte(index)) in_window = false;
    }
    const raw: [*]u32 = @ptrCast(spiflash.pageBuffer());
    sys.Disable();
    sys.HoldOtherCores();
    var over_mspi1 = programmed and spiflash.readRaw(offset, raw, spiflash.page_size);
    sys.ReleaseOtherCores();
    sys.Enable();
    for (spiflash.pageBuffer(), 0..) |byte, index| {
        if (byte != patternByte(index)) over_mspi1 = false;
    }

    var restored = eraseHeld(sys, offset) and writeHeld(sys, offset, kept);
    for (0..spiflash.sector_size) |index| {
        if (window[index] != kept[index]) restored = false;
    }
    note("flash: %d MiB (the ROM had %d), last sector erased in %u us (%s), written in %u us; read back through the window %s, over MSPI1 %s; put back %s", .{
        chip_size >> 20,
        rom_size >> 20,
        @as(u32, @intCast(erased - began)),
        rightOrWrong(blank),
        @as(u32, @intCast(written - erased)),
        rightOrWrong(in_window),
        rightOrWrong(over_mspi1),
        rightOrWrong(restored),
    });
}

fn rightOrWrong(right: bool) [*:0]const u8 {
    return if (right) "right" else "WRONG";
}

fn patternByte(index: usize) u8 {
    return @truncate(index *% 151 +% 7);
}

/// The sector at `offset` erased, core 1 held.
fn eraseHeld(sys: *ExecBase, offset: u32) bool {
    sys.Disable();
    sys.HoldOtherCores();
    const ok = spiflash.eraseSector(offset / spiflash.sector_size);
    sys.ReleaseOtherCores();
    sys.Enable();
    return ok;
}

/// The sector at `offset` written a page at a time: `from`'s bytes, or the
/// pattern without them.
fn writeHeld(sys: *ExecBase, offset: u32, from: ?[*]const u8) bool {
    const buffer = spiflash.pageBuffer();
    var at: u32 = 0;
    while (at < spiflash.sector_size) : (at += spiflash.page_size) {
        for (buffer, 0..) |*byte, index| byte.* = if (from) |bytes| bytes[at + index] else patternByte(at + index);
        sys.Disable();
        sys.HoldOtherCores();
        const ok = spiflash.programPage(offset + at, spiflash.page_size);
        sys.ReleaseOtherCores();
        sys.Enable();
        if (!ok) return false;
    }
    return true;
}

// --- NewStackRun ----------------------------------------------------------------

/// The stack pointer `onOwnStack` found, and its answer.
var new_stack_sp: u32 = 0;

fn onOwnStack(arg: ?*anyopaque) callconv(.c) i32 {
    new_stack_sp = cpu.stackPointer();
    const value: *u32 = @ptrCast(@alignCast(arg.?));
    return @intCast(value.* * 2);
}

fn checkNewStackRun(sys: *ExecBase) void {
    var value: u32 = 21;
    const before = cpu.stackPointer();
    const answer = sys.NewStackRun(&onOwnStack, &value, 4096);
    note("NewStackRun: answer %d, ran at sp 0x%08x (the caller's 0x%08x)", .{ answer, new_stack_sp, before });
}

// --- the tasks ------------------------------------------------------------------

/// What each task has got done, and the core it last ran on.
const Worker = struct {
    name: [:0]const u8,
    count: u32 = 0,
    errors: u32 = 0,
    core: u32 = 0,
    task: ?*sdk.exec.Task = null,
};

var workers = [_]Worker{
    .{ .name = "fpu 3" },
    .{ .name = "fpu 7" },
    .{ .name = "pong" },
    .{ .name = "ping" },
    .{ .name = "count a" },
    .{ .name = "count b" },
};

const fpu_three = 0;
const fpu_seven = 1;
const pong = 2;
const ping = 3;
const count_a = 4;
const count_b = 5;

const task_stack = 4096;

fn startTasks(sys: *ExecBase) void {
    const codes = [_]sdk.exec.TaskFn{ &fpuThree, &fpuSeven, &pongCode, &pingCode, &countA, &countB };
    // ping and pong above the others: a Signal to either takes a core at
    // once rather than at the end of a busy task's slice.
    const priorities = [_]i8{ 0, 0, 1, 1, 0, 0 };
    for (&workers, codes, priorities) |*worker, code, priority| {
        worker.task = sys.CreateTask(worker.name.ptr, priority, code, task_stack);
        if (worker.task == null) note("%s: not started", .{worker.name.ptr});
    }
}

fn fpuThree(sys: *ExecBase) callconv(.c) void {
    fpuLoop(sys, &workers[fpu_three], 3.0);
}

fn fpuSeven(sys: *ExecBase) callconv(.c) void {
    fpuLoop(sys, &workers[fpu_seven], 7.0);
}

/// `value` stepped as `value * 1.5 - seed * 0.5`, which keeps it at `seed`
/// exactly - as long as nothing changes the FPU's registers under it.
fn fpuLoop(_: *ExecBase, worker: *Worker, seed: f32) void {
    const half: f32 = seed * 0.5;
    var value: f32 = seed;
    while (true) {
        value = value * 1.5 - half;
        if (value != seed) {
            worker.errors += 1;
            value = seed;
        }
        worker.count +%= 1;
        worker.core = cpu.coreId();
    }
}

fn pongCode(sys: *ExecBase) callconv(.c) void {
    const worker = &workers[pong];
    while (true) {
        _ = sys.Wait(sdk.exec.SIGBREAKF_CTRL_F);
        worker.count +%= 1;
        worker.core = cpu.coreId();
        sys.Signal(workers[ping].task.?, sdk.exec.SIGBREAKF_CTRL_F);
    }
}

fn pingCode(sys: *ExecBase) callconv(.c) void {
    const worker = &workers[ping];
    // Its own task known before pong is first signalled, which answers
    // to it - CreateTask's answer may come later than that on two cores.
    worker.task = sys.FindTask(null);
    while (true) {
        sys.Signal(workers[pong].task.?, sdk.exec.SIGBREAKF_CTRL_F);
        _ = sys.Wait(sdk.exec.SIGBREAKF_CTRL_F);
        worker.count +%= 1;
        worker.core = cpu.coreId();
    }
}

fn countA(_: *ExecBase) callconv(.c) void {
    countLoop(&workers[count_a]);
}

fn countB(_: *ExecBase) callconv(.c) void {
    countLoop(&workers[count_b]);
}

fn countLoop(worker: *Worker) void {
    while (true) {
        @as(*volatile u32, &worker.count).* +%= 1;
        worker.core = cpu.coreId();
    }
}

// --- the report -----------------------------------------------------------------

/// The interrupt server on SYSTIMER's third alarm: its interrupt cleared,
/// and the reporting task signalled.
var second_server: sdk.exec.Interrupt = .{};
var reporter: ?*sdk.exec.Task = null;

fn onSecond(_: ?*anyopaque, _: u32) callconv(.c) i32 {
    if (reg(systimer.INT_ST).* & systimer.INT_TARGET2 == 0) return 0;
    reg(systimer.INT_CLR).* = systimer.INT_TARGET2;
    exec.SysBase.iface().Signal(reporter.?, sdk.exec.SIGBREAKF_CTRL_E);
    return 1;
}

/// SYSTIMER's third alarm, once a second on unit 0, its interrupt to the
/// server.
fn startSecondAlarm(sys: *ExecBase) void {
    reporter = sys.FindTask(null);
    second_server = .{ .node = .{ .type = .interrupt, .name = "selftest second" }, .code = @ptrCast(&onSecond) };
    sys.AddIntServer(hardware.intbits.INTB_SYSTIMER_TARGET2, &second_server);
    const period: u32 = systimer.SYSTIMER_HZ;
    reg(systimer.CONF).* &= ~systimer.CONF_TARGET2_WORK_EN;
    reg(systimer.TARGET2_CONF).* = period;
    reg(systimer.COMP2_LOAD).* = 1;
    reg(systimer.TARGET2_CONF).* = period | systimer.TARGET_PERIOD_MODE;
    reg(systimer.COMP2_LOAD).* = 1;
    reg(systimer.CONF).* |= systimer.CONF_TARGET2_WORK_EN;
    reg(systimer.INT_CLR).* = systimer.INT_TARGET2;
    reg(systimer.INT_ENA).* |= systimer.INT_TARGET2;
}

fn report(sys: *ExecBase) noreturn {
    startSecondAlarm(sys);
    var previous: [workers.len]u32 = @splat(0);
    var previous_times: [2]sdk.exec.CoreTimes = .{ .{}, .{} };
    var seconds: u32 = 0;
    // The alarm's first interrupt comes before a second is up: the counts
    // start from it.
    _ = sys.Wait(sdk.exec.SIGBREAKF_CTRL_E);
    for (&workers, &previous) |*worker, *before| before.* = @as(*volatile u32, &worker.count).*;
    for (0..2) |core| _ = sys.ReadCoreTimes(@intCast(core), &previous_times[core]);
    while (true) {
        _ = sys.Wait(sdk.exec.SIGBREAKF_CTRL_E);
        if (exec.raw_io_hardware.get()) |character| {
            if (character == 'd') sys.Debug(0);
        }
        seconds += 1;
        // Every second for the first ten, every ten from then on.
        if (seconds > 10 and seconds % 10 != 0) continue;
        var line_buffer: [160]u8 = undefined;
        var length: usize = 0;
        for (&workers, &previous) |*worker, *before| {
            const count = @as(*volatile u32, &worker.count).*;
            const stream = sdk.exec.fmtStream(.{ worker.name.ptr, count -% before.*, worker.core });
            var piece: [40]u8 = undefined;
            _ = exec.format("  %s %u@%d", &stream, null, &piece);
            const text = std.mem.sliceTo(&piece, 0);
            @memcpy(line_buffer[length..][0..text.len], text);
            length += text.len;
            before.* = count;
        }
        line_buffer[length] = 0;
        note("%ds:%s", .{ seconds, @as([*:0]const u8, @ptrCast(&line_buffer)) });
        const errors = workers[fpu_three].errors + workers[fpu_seven].errors;
        var busy: [2]u32 = .{ 0, 0 };
        for (0..2) |core| {
            var times: sdk.exec.CoreTimes = .{};
            if (!sys.ReadCoreTimes(@intCast(core), &times)) continue;
            const total = (times.tasks + times.idle + times.interrupts) -% (previous_times[core].tasks + previous_times[core].idle + previous_times[core].interrupts);
            const work = (times.tasks + times.interrupts) -% (previous_times[core].tasks + previous_times[core].interrupts);
            if (total != 0) busy[core] = @intCast(work * 100 / total);
            previous_times[core] = times;
        }
        note("  ticks %u/%u, fpu errors %u, cores busy %u%%/%u%%", .{ timer.tickCount(), timer.core1TickCount(), errors, busy[0], busy[1] });
    }
}
