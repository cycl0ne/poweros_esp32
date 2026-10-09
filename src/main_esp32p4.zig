// SPDX-License-Identifier: MPL-2.0
//! The kernel for the ESP32-P4, as far as it goes: started by the ROM from
//! the image's RAM segments (src/arch/esp32p4/start.S), it says so on the
//! console through exec's raw port and its system log, with the system
//! timer as the log's clock, checks that the chip's blocks are where
//! `sdk.hardware` says, and waits. exec, the tasks and the rest of the ROM
//! follow as the port goes on.

const std = @import("std");
const builtin = @import("builtin");
const exec = @import("rom/libs/exec/exec.zig");
const RawIOInit = @import("rom/libs/exec/rawio/rawioinit.zig").RawIOInit;
const boards = @import("boards/boards.zig");
const wdt = @import("arch/esp32p4/wdt.zig");
const sdk = @import("sdk");
const st = sdk.expansion.systemtags;
const hardware = sdk.hardware;
const reg = hardware.mmio.reg;
const gdma = hardware.gdma;

comptime {
    _ = @import("arch/esp32p4/cache.zig"); // exports what exec's cache calls ask of the chip
    // The board's description: its system tag list, a ROM tag of its own.
    _ = &boards.system.system_tag;
    _ = boards.romtags;
}

pub const panic = std.debug.FullPanic(kernelPanic);

/// The kernel prints with exec's kprintf; std.log isn't used, and says
/// nothing.
pub const std_options: std.Options = .{ .logFn = noLog };

fn noLog(comptime _: std.log.Level, comptime _: @EnumLiteral(), comptime _: []const u8, _: anytype) void {}

/// The system log's ring, as large as the board says: exec keeps every
/// line from the first one in it.
var log_ring: [boards.fact(st.SYSTAG_LogSize, 16 * 1024)]u8 = undefined;

/// Called from _start with the stack set up and interrupts masked.
export fn kmain() callconv(.c) noreturn {
    wdt.disableAll();
    exec.log_ring.* = &log_ring;
    exec.log_clock.* = uptimeUs;
    // The raw port, as exec's init starts it; it takes no base.
    RawIOInit(exec.SysBase);
    exec.kprintf("PowerOS kernel for ESP32-P4 on %s, built with Zig %s (%s)\n", .{
        boards.text(st.SYSTAG_Name),
        builtin.zig_version_string,
        @tagName(builtin.mode),
    });
    note("running on core %d from 0x%08x", .{ hartId(), @intFromPtr(&kmain) });
    checkHardware();
    note("nothing more yet: waiting", .{});
    while (true) asm volatile ("wfi");
}

/// The blocks `sdk.hardware` names, each found where it says: its version
/// register read against what it reads after reset (the clocks of those
/// the chip starts with them off turned on first); both DMA engines
/// copying a buffer memory to memory; the random number generator.
fn checkHardware() void {
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
        .{ .name = "SYSTIMER", .date = hardware.systimer.DATE, .reset = hardware.systimer.DATE_RESET },
        .{ .name = "USB_SERIAL_JTAG", .date = hardware.usb_serial_jtag.DATE, .reset = hardware.usb_serial_jtag.DATE_RESET },
        .{ .name = "AHB_DMA", .date = gdma.baseOf(.ahb) + gdma.AHB_DATE, .reset = gdma.DATE_RESET },
        .{ .name = "AXI_DMA", .date = gdma.baseOf(.axi) + gdma.AXI_DATE, .reset = gdma.DATE_RESET },
    };
    for (blocks) |block| {
        const date = reg(block.date).*;
        note("%-16s at 0x%08x: version 0x%08x%s", .{
            block.name.ptr,
            @as(u32, @intCast(block.date)),
            date,
            @as([*:0]const u8, if (date == block.reset) "" else " - not what it reads after reset"),
        });
    }
    for ([_]gdma.Engine{ .ahb, .axi }) |engine| {
        const copied = copyByDma(engine);
        note("%s DMA, memory to memory: %s", .{
            @as([*:0]const u8, if (engine == .ahb) "AHB" else "AXI"),
            @as([*:0]const u8, if (copied) "copied" else "failed"),
        });
    }
    note("random: 0x%08x 0x%08x", .{ hardware.rng.read(), hardware.rng.read() });
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

/// Cache_Invalidate_Addr(map, addr, size) and Cache_WriteBack_Addr, from
/// the ROM's table of entry points; L2MEM is reached through the L1 data
/// cache.
const rom_invalidate: *const fn (map: u32, addr: u32, size: u32) callconv(.c) i32 = @ptrFromInt(0x4FC0_03E4);
const rom_write_back: *const fn (map: u32, addr: u32, size: u32) callconv(.c) i32 = @ptrFromInt(0x4FC0_03F4);
const CACHE_MAP_L1_DCACHE: u32 = 1 << 4;

/// 64 bytes copied by channel 0 of `engine`, OUT to IN; whether they
/// arrived within 10 ms.
fn copyByDma(engine: gdma.Engine) bool {
    for (&dma_source, 0..) |*byte, index| byte.* = @truncate(index * 7 + 3 + @intFromEnum(engine));
    @memset(&dma_target, 0);
    const length: u32 = dma_source.len;
    dma_descriptors[0] = .{
        .dw0 = descriptor_owned_by_dma | descriptor_suc_eof | (length << 12) | length,
        .buffer = @intFromPtr(&dma_source),
        .next = 0,
    };
    dma_descriptors[1] = .{ .dw0 = descriptor_owned_by_dma | length, .buffer = @intFromPtr(&dma_target), .next = 0 };
    _ = rom_write_back(CACHE_MAP_L1_DCACHE, @intFromPtr(&dma_descriptors), @sizeOf(@TypeOf(dma_descriptors)));
    _ = rom_write_back(CACHE_MAP_L1_DCACHE, @intFromPtr(&dma_source), dma_source.len);
    _ = rom_write_back(CACHE_MAP_L1_DCACHE, @intFromPtr(&dma_target), dma_target.len);

    gdma.connect(0, gdma.memToMem(engine), true, false, false, false);
    gdma.start(engine, 0, .in, @intFromPtr(&dma_descriptors[1]));
    gdma.start(engine, 0, .out, @intFromPtr(&dma_descriptors[0]));
    const since = hardware.systimer.uptimeUs();
    while (gdma.rawIntStatus(engine, 0, .in) & gdma.IN_SUC_EOF == 0) {
        if (hardware.systimer.uptimeUs() - since > 10_000) break;
    }
    const status = gdma.rawIntStatus(engine, 0, .in);
    gdma.disconnect(engine, 0);
    _ = rom_invalidate(CACHE_MAP_L1_DCACHE, @intFromPtr(&dma_target), dma_target.len);
    if (status & gdma.IN_SUC_EOF == 0) return false;
    for (dma_source, dma_target) |sent, arrived| {
        if (sent != arrived) return false;
    }
    return true;
}

/// The microseconds since the boot, by SYSTIMER's unit 0: the log's clock.
fn uptimeUs() u64 {
    return hardware.systimer.uptimeUs();
}

/// A trap, from start.S: what it was and where, and the machine stops.
export fn kernel_trap(cause: u32, epc: u32, value: u32) callconv(.c) noreturn {
    exec.kprintf("\n*** trap: mcause 0x%08x at 0x%08x, mtval 0x%08x\n", .{ cause, epc, value });
    while (true) asm volatile ("wfi");
}

/// A panic: its message, and the machine stops.
fn kernelPanic(message: []const u8, _: ?usize) noreturn {
    exec.kprintf("\n*** panic: ", .{});
    for (message) |character| exec.kprintf("%c", .{character});
    exec.kprintf("\n", .{});
    while (true) asm volatile ("wfi");
}

/// The core this runs on.
fn hartId() u32 {
    return asm volatile ("csrr %[id], mhartid"
        : [id] "=r" (-> u32),
    );
}

/// A kernel status line; the raw port puts the uptime in front.
fn note(comptime format: [:0]const u8, args: anytype) void {
    exec.kprintf(std.fmt.comptimePrint("{s}\n", .{format}), args);
}
