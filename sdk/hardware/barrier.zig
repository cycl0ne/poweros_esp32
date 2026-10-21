// SPDX-License-Identifier: MIT
//! The barriers between the processor and a device that reads or writes
//! memory itself (a DMA master: a PCI controller, an Ethernet engine,
//! QEMU's fw_cfg), the same calls on every chip. Each keeps the compiler
//! from holding memory across it as well.
//!
//! - `toDevice`: what was written to memory before is there for the
//!   device before the register write after it that tells the device to
//!   look - Linux's writel. RISC-V `fence w, o`, AArch64 `dmb oshst`.
//! - `fromDevice`: the register read before it - the device saying it
//!   wrote - is done before memory is read after it - Linux's readl.
//!   RISC-V `fence i, r`, AArch64 `dmb oshld`.
//! - `reads`: what a device wrote to memory read in order: a flag before
//!   the rest it guards. RISC-V `fence r, r`, AArch64 `dmb oshld`.
//! - `full`: everything before it before everything after it, memory and
//!   registers both. RISC-V `fence iorw, iorw`, AArch64 `dsb sy`.
//!
//! The ESP32-S3's Xtensa has `memw` for all of them; a host build (the
//! tests) has only the compiler to hold back.

const builtin = @import("builtin");

pub inline fn toDevice() void {
    switch (builtin.cpu.arch) {
        .riscv32, .riscv64 => asm volatile ("fence w, o" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dmb oshst" ::: .{ .memory = true }),
        .xtensa => asm volatile ("memw" ::: .{ .memory = true }),
        else => asm volatile ("" ::: .{ .memory = true }),
    }
}

pub inline fn fromDevice() void {
    switch (builtin.cpu.arch) {
        .riscv32, .riscv64 => asm volatile ("fence i, r" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dmb oshld" ::: .{ .memory = true }),
        .xtensa => asm volatile ("memw" ::: .{ .memory = true }),
        else => asm volatile ("" ::: .{ .memory = true }),
    }
}

pub inline fn reads() void {
    switch (builtin.cpu.arch) {
        .riscv32, .riscv64 => asm volatile ("fence r, r" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dmb oshld" ::: .{ .memory = true }),
        .xtensa => asm volatile ("memw" ::: .{ .memory = true }),
        else => asm volatile ("" ::: .{ .memory = true }),
    }
}

pub inline fn full() void {
    switch (builtin.cpu.arch) {
        .riscv32, .riscv64 => asm volatile ("fence iorw, iorw" ::: .{ .memory = true }),
        .aarch64 => asm volatile ("dsb sy" ::: .{ .memory = true }),
        .xtensa => asm volatile ("memw" ::: .{ .memory = true }),
        else => asm volatile ("" ::: .{ .memory = true }),
    }
}
