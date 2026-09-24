// SPDX-License-Identifier: MPL-2.0
//! Xtensa LX7 special registers and CPU control.

const std = @import("std");

pub const ccount = @import("sdk").hardware.cpu.ccount;

pub inline fn ccompare0() u32 {
    return asm volatile ("rsr %[r], ccompare0"
        : [r] "=r" (-> u32),
    );
}

/// Writing CCOMPARE0 also acknowledges a pending timer 0 interrupt.
pub inline fn setCcompare0(value: u32) void {
    asm volatile (
        \\wsr %[v], ccompare0
        \\rsync
        :
        : [v] "r" (value),
    );
}

pub inline fn interrupt() u32 {
    return asm volatile ("rsr %[r], interrupt"
        : [r] "=r" (-> u32),
    );
}

pub inline fn intenable() u32 {
    return asm volatile ("rsr %[r], intenable"
        : [r] "=r" (-> u32),
    );
}

pub inline fn setIntenable(mask: u32) void {
    asm volatile (
        \\wsr %[v], intenable
        \\rsync
        :
        : [v] "r" (mask),
        : .{ .memory = true });
}

/// Raise software interrupt lines (INTSET).
pub inline fn setIntset(mask: u32) void {
    asm volatile (
        \\wsr %[v], intset
        \\rsync
        :
        : [v] "r" (mask),
        : .{ .memory = true });
}

/// Clear software and edge-triggered interrupt lines (INTCLEAR).
pub inline fn setIntclear(mask: u32) void {
    asm volatile (
        \\wsr %[v], intclear
        \\rsync
        :
        : [v] "r" (mask),
        : .{ .memory = true });
}

pub inline fn ps() u32 {
    return asm volatile ("rsr %[r], ps"
        : [r] "=r" (-> u32),
    );
}

pub inline fn vecbase() u32 {
    return asm volatile ("rsr %[r], vecbase"
        : [r] "=r" (-> u32),
    );
}

/// Processor ID: 0xCDCD on the PRO CPU (core 0), 0xABAB on the APP CPU.
pub inline fn prid() u32 {
    return asm volatile ("rsr %[r], prid"
        : [r] "=r" (-> u32),
    );
}

pub inline fn stackPointer() u32 {
    return asm volatile ("mov %[r], a1"
        : [r] "=r" (-> u32),
    );
}

/// Raise PS.INTLEVEL to `level` and return the previous PS.
pub inline fn setIntlevel(comptime level: u4) u32 {
    return asm volatile ("rsil %[r], " ++ std.fmt.comptimePrint("{d}", .{level})
        : [r] "=r" (-> u32),
        :
        : .{ .memory = true });
}

pub inline fn restorePs(saved: u32) void {
    asm volatile (
        \\wsr %[v], ps
        \\rsync
        :
        : [v] "r" (saved),
        : .{ .memory = true });
}

pub inline fn enableInterrupts() void {
    _ = setIntlevel(0);
}

/// Sleep until the next interrupt.
pub inline fn waitForInterrupt() void {
    asm volatile ("waiti 0" ::: .{ .memory = true });
}

pub fn enableInterrupt(n: u5) void {
    const saved = setIntlevel(15);
    defer restorePs(saved);
    setIntenable(intenable() | (@as(u32, 1) << n));
}

pub fn disableInterrupt(n: u5) void {
    const saved = setIntlevel(15);
    defer restorePs(saved);
    setIntenable(intenable() & ~(@as(u32, 1) << n));
}

pub fn halt() noreturn {
    _ = setIntlevel(15);
    while (true) asm volatile ("waiti 15");
}
