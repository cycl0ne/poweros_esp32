// SPDX-License-Identifier: MPL-2.0
//! exec's hardware for the chip the kernel is built for: `esp32s3/`,
//! `esp32p4/`, `rv64sbi/` or `a64psci/`, by `sdk.hardware.chip`. The kernel's shell and
//! platform.resource read their figures through here - the clock, the
//! tick, the cores, the memory map, the interrupt lines, the traps - so
//! one command serves both chips. Each chip's module answers
//! to the same names for what the shell asks.

const chip = @import("sdk").hardware.chip;

pub const clock = switch (chip) {
    .esp32s3 => @import("esp32s3/clock.zig"),
    .esp32p4 => @import("esp32p4/clock.zig"),
    .rv64sbi => @import("rv64sbi/clock.zig"),
    .a64psci => @import("a64psci/clock.zig"),
};
pub const psram = switch (chip) {
    .esp32s3 => @import("esp32s3/psram.zig"),
    .esp32p4 => @import("esp32p4/psram.zig"),
    .rv64sbi => @import("rv64sbi/psram.zig"),
    .a64psci => @import("a64psci/psram.zig"),
};
pub const cpu = switch (chip) {
    .esp32s3 => @import("esp32s3/cpu.zig"),
    .esp32p4 => @import("esp32p4/cpu.zig"),
    .rv64sbi => @import("rv64sbi/cpu.zig"),
    .a64psci => @import("a64psci/cpu.zig"),
};
pub const cpu1 = switch (chip) {
    .esp32s3 => @import("esp32s3/cpu1.zig"),
    .esp32p4 => @import("esp32p4/cpu1.zig"),
    .rv64sbi => @import("rv64sbi/cpu1.zig"),
    .a64psci => @import("a64psci/cpu1.zig"),
};
pub const intmatrix = switch (chip) {
    .esp32s3 => @import("esp32s3/intmatrix.zig"),
    .esp32p4 => @import("esp32p4/intmatrix.zig"),
    .rv64sbi => @import("rv64sbi/plic.zig"),
    .a64psci => @import("a64psci/gic.zig"),
};
pub const layout = switch (chip) {
    .esp32s3 => @import("esp32s3/layout.zig"),
    .esp32p4 => @import("esp32p4/layout.zig"),
    .rv64sbi => @import("rv64sbi/layout.zig"),
    .a64psci => @import("a64psci/layout.zig"),
};
pub const rendezvous = switch (chip) {
    .esp32s3 => @import("esp32s3/rendezvous.zig"),
    .esp32p4 => @import("esp32p4/rendezvous.zig"),
    .rv64sbi => @import("rv64sbi/rendezvous.zig"),
    .a64psci => @import("a64psci/rendezvous.zig"),
};
pub const timer = switch (chip) {
    .esp32s3 => @import("esp32s3/timer.zig"),
    .esp32p4 => @import("esp32p4/timer.zig"),
    .rv64sbi => @import("rv64sbi/timer.zig"),
    .a64psci => @import("a64psci/timer.zig"),
};
pub const trap = switch (chip) {
    .esp32s3 => @import("esp32s3/trap.zig"),
    .esp32p4 => @import("esp32p4/trap.zig"),
    .rv64sbi => @import("rv64sbi/trap.zig"),
    .a64psci => @import("a64psci/trap.zig"),
};
