// SPDX-License-Identifier: MPL-2.0
//! A machine for the host tests of the interpreter, which need no exec:
//! the test allocator's memory, so a test that leaks fails, a log that
//! counts the lines it is given and keeps the last one's format, and a
//! lock that only counts that it is given back as often as it is taken.

const std = @import("std");
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const Machine = @import("../machine/_machine.zig").Machine;

pub const TestMachine = struct {
    acpi: AcpiBase = .{ .lib = undefined, .sys_base = undefined, .machine = &table },
    /// How many lines the log was given, and the last one's format.
    lines: u32 = 0,
    last: [*:0]const u8 = "",
    /// How many times the lock is held now.
    held: i32 = 0,

    pub fn base(test_machine: *TestMachine) *AcpiBase {
        return &test_machine.acpi;
    }

    /// Whether the last line's format has `text` in it.
    pub fn said(test_machine: *const TestMachine, text: []const u8) bool {
        return std.mem.indexOf(u8, std.mem.span(test_machine.last), text) != null;
    }
};

const table = Machine{ .allocate = allocate, .free = free, .log = log, .lock = lock, .unlock = unlock };

fn lock(ab: *AcpiBase, _: bool) void {
    const test_machine: *TestMachine = @fieldParentPtr("acpi", ab);
    test_machine.held += 1;
}

fn unlock(ab: *AcpiBase) void {
    const test_machine: *TestMachine = @fieldParentPtr("acpi", ab);
    test_machine.held -= 1;
}

fn allocate(_: *AcpiBase, bytes: usize) ?[*]u8 {
    const block = std.testing.allocator.alignedAlloc(u8, .@"16", bytes) catch return null;
    return block.ptr;
}

fn free(_: *AcpiBase, memory: [*]u8, bytes: usize) void {
    const aligned: [*]align(16) u8 = @alignCast(memory);
    std.testing.allocator.free(aligned[0..bytes]);
}

fn log(ab: *AcpiBase, format: [*:0]const u8, _: ?*const anyopaque) void {
    const test_machine: *TestMachine = @fieldParentPtr("acpi", ab);
    test_machine.lines += 1;
    test_machine.last = format;
}
