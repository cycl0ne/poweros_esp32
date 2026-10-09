// SPDX-License-Identifier: MPL-2.0
//! The kernel for the ESP32-P4, as far as it goes: started by the ROM from
//! the image's RAM segments (src/arch/esp32p4/start.S), it says so on the
//! console through exec's raw port and its system log, and waits. exec,
//! the tasks and the rest of the ROM follow as the port goes on
//! (todo/p4).

const std = @import("std");
const builtin = @import("builtin");
const exec = @import("rom/libs/exec/exec.zig");
const RawIOInit = @import("rom/libs/exec/rawio/rawioinit.zig").RawIOInit;
const boards = @import("boards/boards.zig");
const wdt = @import("arch/esp32p4/wdt.zig");
const sdk = @import("sdk");
const st = sdk.expansion.systemtags;

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
    // The raw port, as exec's init starts it; it takes no base.
    RawIOInit(exec.SysBase);
    exec.kprintf("PowerOS kernel for ESP32-P4 on %s, built with Zig %s (%s)\n", .{
        boards.text(st.SYSTAG_Name),
        builtin.zig_version_string,
        @tagName(builtin.mode),
    });
    note("running on core %d from 0x%08x", .{ hartId(), @intFromPtr(&kmain) });
    note("nothing more yet: waiting", .{});
    while (true) asm volatile ("wfi");
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
