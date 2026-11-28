// SPDX-License-Identifier: MPL-2.0
//! A machine for the host tests of the interpreter, which need no exec:
//! the test allocator's memory, so a test that leaks fails, a log that
//! counts the lines it is given and keeps the last one's format, a lock
//! that only counts that it is given back as often as it is taken, and a
//! clock of its own, which moves a microsecond each time it is read and
//! by what a wait asks for - so a test's waits take no time, and a loop
//! that never ends meets its limit in a moment. Tables a DataTableRegion
//! or LoadTable asks for are looked for among `tables`. Every address
//! space is memory of its own, a byte for each address - each function's
//! configuration space apart -, cleared until written; the accesses are
//! counted, and one space can be made one the machine cannot reach.

const std = @import("std");
const AcpiBase = @import("../acpi_base.zig").AcpiBase;
const machine = @import("../machine/_machine.zig");
const namespace = @import("../namespace/_namespace.zig");
const Machine = machine.Machine;
const idMatches = machine.idMatches;

/// An access the machine was asked for, and its value.
pub const Traced = struct {
    space: u8,
    address: u64,
    width: u8,
    write: bool,
    value: u64,
    /// Whether `\_GL` was held when it was made.
    locked: bool = false,
};

/// A byte of an address space.
const Key = struct {
    space: u8,
    function: u32,
    address: u64,
};

pub const TestMachine = struct {
    acpi: AcpiBase = .{ .lib = undefined, .sys_base = undefined, .machine = &table },
    /// How many lines the log was given, and the last one's format.
    lines: u32 = 0,
    last: [*:0]const u8 = "",
    /// How many times the lock is held now.
    held: i32 = 0,
    /// The clock, in units of 100 nanoseconds, and what the waits asked
    /// for, in microseconds.
    clock: u64 = 0,
    slept: u64 = 0,
    stalled: u64 = 0,
    /// The firmware's other tables, for findTable.
    tables: []const []const u8 = &.{},
    /// The address spaces' bytes, the accesses made and the last, and a
    /// space the machine cannot reach.
    bytes: std.AutoHashMapUnmanaged(Key, u8) = .empty,
    accesses: u32 = 0,
    last_access: machine.Access = .{ .space = 0, .address = 0, .width = 0, .write = false },
    unreachable_space: ?u8 = null,
    /// The first accesses, in order, each with the value read or written.
    trace: [64]Traced = undefined,

    pub fn base(test_machine: *TestMachine) *AcpiBase {
        return &test_machine.acpi;
    }

    pub fn deinit(test_machine: *TestMachine) void {
        test_machine.bytes.deinit(std.testing.allocator);
    }

    /// A byte of a space, as the bytecode left it.
    pub fn peek(test_machine: *const TestMachine, space: u8, address: u64) u8 {
        return test_machine.bytes.get(.{ .space = space, .function = 0, .address = address }) orelse 0;
    }

    /// The accesses made since `from`, as many as were traced.
    pub fn since(test_machine: *const TestMachine, from: u32) []const Traced {
        const end = @min(test_machine.accesses, test_machine.trace.len);
        return test_machine.trace[@min(from, end)..end];
    }

    /// A byte of a space set, as hardware would have it.
    pub fn poke(test_machine: *TestMachine, space: u8, address: u64, value: u8) !void {
        try test_machine.pokeAt(space, 0, address, value);
    }

    /// A byte of a PCI function's configuration space set: the function
    /// its bus, device and function number, a byte each, the bus highest.
    pub fn pokeAt(test_machine: *TestMachine, space: u8, function: u32, address: u64, value: u8) !void {
        try test_machine.bytes.put(std.testing.allocator, .{ .space = space, .function = function, .address = address }, value);
    }

    /// Whether the last line's format has `text` in it.
    pub fn said(test_machine: *const TestMachine, text: []const u8) bool {
        return std.mem.indexOf(u8, std.mem.span(test_machine.last), text) != null;
    }
};

const table = Machine{
    .allocate = allocate,
    .free = free,
    .log = log,
    .lock = lock,
    .unlock = unlock,
    .time = time,
    .sleep = sleep,
    .stall = stall,
    .findTable = findTable,
    .access = access,
};

fn access(ab: *AcpiBase, request: *const machine.Access, value: *u64) bool {
    const test_machine = machineOf(ab);
    if (test_machine.unreachable_space) |space| {
        if (space == request.space) return false;
    }
    test_machine.accesses += 1;
    test_machine.last_access = request.*;
    const pci = request.pci;
    const function: u32 = @as(u32, pci.bus) << 16 | @as(u32, pci.device) << 8 | pci.function;
    var read: u64 = 0;
    for (0..request.width) |at| {
        const key: Key = .{ .space = request.space, .function = function, .address = request.address + at };
        if (request.write) {
            test_machine.bytes.put(std.testing.allocator, key, @truncate(value.* >> @intCast(at * 8))) catch return false;
        } else {
            read |= @as(u64, test_machine.bytes.get(key) orelse 0) << @intCast(at * 8);
        }
    }
    if (!request.write) value.* = read;
    if (test_machine.accesses <= test_machine.trace.len) {
        test_machine.trace[test_machine.accesses - 1] = .{
            .space = request.space,
            .address = request.address,
            .width = request.width,
            .write = request.write,
            .value = value.*,
            .locked = globalLockHeld(ab),
        };
    }
    return true;
}

fn globalLockHeld(ab: *AcpiBase) bool {
    const root = ab.root orelse return false;
    const node = namespace.child(root, namespace.nameOf("_GL_")) orelse return false;
    const held = node.object orelse return false;
    return switch (held.value) {
        .mutex => |mutex| mutex.owner != null,
        else => false,
    };
}

fn machineOf(ab: *AcpiBase) *TestMachine {
    return @fieldParentPtr("acpi", ab);
}

fn time(ab: *AcpiBase) u64 {
    const test_machine = machineOf(ab);
    test_machine.clock += 10;
    return test_machine.clock;
}

fn sleep(ab: *AcpiBase, milliseconds: u32) void {
    const test_machine = machineOf(ab);
    test_machine.clock += @as(u64, milliseconds) * 10_000;
    test_machine.slept += @as(u64, milliseconds) * 1000;
}

fn stall(ab: *AcpiBase, microseconds: u32) void {
    const test_machine = machineOf(ab);
    test_machine.clock += @as(u64, microseconds) * 10;
    test_machine.stalled += microseconds;
}

fn findTable(ab: *AcpiBase, signature: *const [4]u8, oem_id: []const u8, oem_table_id: []const u8) ?[]const u8 {
    for (machineOf(ab).tables) |code| {
        if (code.len < 36 or !std.mem.eql(u8, code[0..4], signature)) continue;
        if (!idMatches(code[10..16], oem_id) or !idMatches(code[16..24], oem_table_id)) continue;
        return code;
    }
    return null;
}

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
