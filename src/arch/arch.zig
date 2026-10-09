// SPDX-License-Identifier: MPL-2.0
//! exec's hardware for the chip the kernel is built for: `esp32s3/` or
//! `esp32p4/`, by `sdk.hardware.chip`. The kernel's shell reads its
//! figures through here - the tick, the cores, the interrupt lines, the
//! traps - so one command serves both chips. Each chip's module answers
//! to the same names for what the shell asks.

const chip = @import("sdk").hardware.chip;

pub const cpu = switch (chip) {
    .esp32s3 => @import("esp32s3/cpu.zig"),
    .esp32p4 => @import("esp32p4/cpu.zig"),
};
pub const cpu1 = switch (chip) {
    .esp32s3 => @import("esp32s3/cpu1.zig"),
    .esp32p4 => @import("esp32p4/cpu1.zig"),
};
pub const intmatrix = switch (chip) {
    .esp32s3 => @import("esp32s3/intmatrix.zig"),
    .esp32p4 => @import("esp32p4/intmatrix.zig"),
};
pub const layout = switch (chip) {
    .esp32s3 => @import("esp32s3/layout.zig"),
    .esp32p4 => @import("esp32p4/layout.zig"),
};
pub const rendezvous = switch (chip) {
    .esp32s3 => @import("esp32s3/rendezvous.zig"),
    .esp32p4 => @import("esp32p4/rendezvous.zig"),
};
pub const timer = switch (chip) {
    .esp32s3 => @import("esp32s3/timer.zig"),
    .esp32p4 => @import("esp32p4/timer.zig"),
};
pub const trap = switch (chip) {
    .esp32s3 => @import("esp32s3/trap.zig"),
    .esp32p4 => @import("esp32p4/trap.zig"),
};
