// SPDX-License-Identifier: MPL-2.0
//! What the interpreter asks of what it runs in: memory, a place to say
//! what it found, the lock that keeps a task out of the namespace while
//! another changes it, and the time - a clock, and waits of two kinds.
//! The interpreter is the same code in the resource and in
//! tools/acpicheck, which runs it on the host over a folder of tables;
//! what differs between the two is this table of calls, which the base
//! points at (`AcpiBase.machine`).
//!
//! The resource's own (`rom`) takes memory from the resource's pool -
//! many small blocks that live as long as the namespace does - writes to
//! the system log through RawDoFmt, so what the interpreter says is in
//! `C:Log` with every other module's lines, locks with the base's
//! semaphore, shared for reading, and takes the time from exec: the
//! machine's uptime for the clock, a wait that gives the processor away
//! with the namespace given up meanwhile for Sleep, and a spin for Stall.
//! The tool's takes the host's memory and prints, has one task, which
//! needs no lock, and waits for nothing: its clock jumps by what a wait
//! asks for.
//!
//! **The address spaces** a field's units are read and written in are
//! reached through `access`, one unit at a time. The resource's reaches
//! memory where it is - every address is mapped as itself, but the first
//! page, which is left out so that a null pointer faults -, the ports on
//! a machine that has them, and PCI's configuration space through the
//! window the board's bridge part names (the first segment's); any other
//! space has nothing to reach it yet, and its accesses fail. The tool's
//! keeps every space as memory of its own that starts out cleared.
//!
//! `Stack` is the interpreter's growable array, in the same memory: what
//! an evaluation keeps of the methods it is in and the terms it is
//! working out, which is as deep as the firmware's bytecode goes and is
//! never kept on the calling task's stack.
//!
//! The calls take the base first, as every function of the resource does;
//! a table of the tool's reaches its own state from there with
//! `@fieldParentPtr`.

const sdk = @import("sdk");
const exec = sdk.exec;
const hardware_acpi = sdk.hardware.acpi;
const ExecBase = sdk.interface.exec.ExecBase;
const AcpiBase = @import("../acpi_base.zig").AcpiBase;

pub const Machine = struct {
    /// `bytes` bytes, aligned for any of the interpreter's structures;
    /// null without memory.
    allocate: *const fn (ab: *AcpiBase, bytes: usize) ?[*]u8,
    /// A block from `allocate` given back, with the size it was asked for.
    free: *const fn (ab: *AcpiBase, memory: [*]u8, bytes: usize) void,
    /// A line for the log: a RawDoFmt format, its level's mark first, and
    /// the values it takes packed as RawDoFmt reads them.
    log: *const fn (ab: *AcpiBase, format: [*:0]const u8, stream: ?*const anyopaque) void,
    /// The namespace taken, by a reader alongside other readers where
    /// `shared`, and given back.
    lock: *const fn (ab: *AcpiBase, shared: bool) void,
    unlock: *const fn (ab: *AcpiBase) void,
    /// A clock in units of 100 nanoseconds, from whenever: it never goes
    /// back.
    time: *const fn (ab: *AcpiBase) u64,
    /// `milliseconds` waited for by an evaluation that holds the
    /// namespace, which others may take meanwhile; held again after.
    sleep: *const fn (ab: *AcpiBase, milliseconds: u32) void,
    /// `microseconds` waited for without giving anything up.
    stall: *const fn (ab: *AcpiBase, microseconds: u32) void,
    /// The firmware's table of `signature` whose maker's name and own
    /// name are `oem_id` and `oem_table_id` (an empty one matching any),
    /// header first: what a DataTableRegion covers and LoadTable loads.
    /// Null where there is none.
    findTable: *const fn (ab: *AcpiBase, signature: *const [4]u8, oem_id: []const u8, oem_table_id: []const u8) ?[]const u8,
    /// One access to an address space: `request.width` bytes read into
    /// `value`, the first the lowest, or written from it. False where the
    /// machine cannot reach the space or the address.
    access: *const fn (ab: *AcpiBase, request: *const Access, value: *u64) bool,
};

/// One access to an address space, as a field's unit is read or written.
pub const Access = struct {
    /// The space: `SPACE_*` of sdk.hardware.acpi.
    space: u8,
    /// Where: an address in memory, a port, an offset in a function's
    /// configuration space.
    address: u64,
    /// How many bytes: 1, 2, 4 or 8.
    width: u8,
    write: bool,
    /// The function a configuration space's access is to.
    pci: Pci = .{},
};

/// A PCI function: its segment, its bus, its device on the bus and the
/// function of the device.
pub const Pci = struct {
    segment: u16 = 0,
    bus: u8 = 0,
    device: u8 = 0,
    function: u8 = 0,
};

/// The resource's: the pool, the system log, the base's semaphore.
pub const rom = Machine{
    .allocate = romAllocate,
    .free = romFree,
    .log = romLog,
    .lock = romLock,
    .unlock = romUnlock,
    .time = romTime,
    .sleep = romSleep,
    .stall = romStall,
    .findTable = romFindTable,
    .access = romAccess,
};

const on_x64 = sdk.hardware.chip == .x64uefi;

/// Memory below this is never reached: the page a null pointer is in.
const FIRST_ADDRESS = 0x1000;

fn romAccess(ab: *AcpiBase, request: *const Access, value: *u64) bool {
    switch (request.space) {
        hardware_acpi.SPACE_SYSTEM_MEMORY => {
            if (request.address < FIRST_ADDRESS or request.address > ~@as(usize, 0) - 8) return false;
            return memoryAccess(@intCast(request.address), request.width, request.write, value);
        },
        hardware_acpi.SPACE_SYSTEM_IO => {
            if (!on_x64 or request.address + request.width > 0x1_0000) return false;
            return portAccess(@intCast(request.address), request.width, request.write, value);
        },
        hardware_acpi.SPACE_PCI_CONFIG => {
            const pci = request.pci;
            if (ab.pci_config == 0 or pci.segment != 0 or request.address + request.width > 0x1000) return false;
            if (request.width == 8) return false;
            const at = ab.pci_config + (@as(usize, pci.bus) << 20 | @as(usize, pci.device & 0x1F) << 15 | @as(usize, pci.function & 0x07) << 12 | @as(usize, @intCast(request.address)));
            return memoryAccess(at, request.width, request.write, value);
        },
        else => return false,
    }
}

/// `width` bytes at `address`, through a pointer of that width.
fn memoryAccess(address: usize, width: u8, write: bool, value: *u64) bool {
    switch (width) {
        1 => {
            const register: *volatile u8 = @ptrFromInt(address);
            if (write) register.* = @truncate(value.*) else value.* = register.*;
        },
        2 => {
            if (address % 2 != 0) return false;
            const register: *volatile u16 = @ptrFromInt(address);
            if (write) register.* = @truncate(value.*) else value.* = register.*;
        },
        4 => {
            if (address % 4 != 0) return false;
            const register: *volatile u32 = @ptrFromInt(address);
            if (write) register.* = @truncate(value.*) else value.* = register.*;
        },
        8 => {
            if (address % 8 != 0) return false;
            const register: *volatile u64 = @ptrFromInt(address);
            if (write) register.* = value.* else value.* = register.*;
        },
        else => return false,
    }
    return true;
}

/// `width` bytes at the port `port`; a machine without ports reaches none.
fn portAccess(port: u16, width: u8, write: bool, value: *u64) bool {
    if (comptime on_x64) {
        const mmio = sdk.hardware.mmio;
        switch (width) {
            1 => if (write) mmio.out8(port, @truncate(value.*)) else {
                value.* = mmio.in8(port);
            },
            2 => if (write) mmio.out16(port, @truncate(value.*)) else {
                value.* = mmio.in16(port);
            },
            4 => if (write) mmio.out32(port, @truncate(value.*)) else {
                value.* = mmio.in32(port);
            },
            else => return false,
        }
        return true;
    }
    return false;
}

fn romFindTable(ab: *AcpiBase, signature: *const [4]u8, oem_id: []const u8, oem_table_id: []const u8) ?[]const u8 {
    if (ab.firmware == 0) return null;
    const root = hardware_acpi.rootAt(ab.firmware) orelse return null;
    var index: u32 = 0;
    while (index < root.count) : (index += 1) {
        const table = root.table(index);
        if (table == 0) continue;
        const header = hardware_acpi.headerOf(table);
        if (!matches(&header.signature, signature)) continue;
        if (!idMatches(&header.oem, oem_id) or !idMatches(&header.oem_table, oem_table_id)) continue;
        const code: [*]const u8 = @ptrFromInt(table);
        return code[0..header.length];
    }
    return null;
}

/// Whether a table's signature is `wanted`.
fn matches(signature: *const [4]u8, wanted: *const [4]u8) bool {
    for (signature, wanted) |one, other| {
        if (one != other) return false;
    }
    return true;
}

/// Whether a header's identity field is `wanted`, which may be shorter -
/// the field filled out with spaces or NULs - or empty, matching any.
pub fn idMatches(field: []const u8, wanted: []const u8) bool {
    if (wanted.len == 0) return true;
    if (wanted.len > field.len) return false;
    for (field, 0..) |char, index| {
        if (index < wanted.len) {
            if (char != wanted[index]) return false;
        } else if (char != ' ' and char != 0) return false;
    }
    return true;
}

fn romTime(ab: *AcpiBase) u64 {
    return ab.sys_base.UptimeUs() * 10;
}

fn romSleep(ab: *AcpiBase, milliseconds: u32) void {
    const waitables = [1]*exec.Waitable{&ab.never};
    ab.sys_base.ReleaseSemaphore(&ab.lock);
    _ = ab.sys_base.WaitForAny(&waitables, 1, @as(u64, milliseconds) * 1000);
    ab.sys_base.ObtainSemaphore(&ab.lock);
}

fn romStall(ab: *AcpiBase, microseconds: u32) void {
    ab.sys_base.SpinUs(microseconds);
}

fn romLock(ab: *AcpiBase, shared: bool) void {
    if (shared) ab.sys_base.ObtainSemaphoreShared(&ab.lock) else ab.sys_base.ObtainSemaphore(&ab.lock);
}

fn romUnlock(ab: *AcpiBase) void {
    ab.sys_base.ReleaseSemaphore(&ab.lock);
}

fn romAllocate(ab: *AcpiBase, bytes: usize) ?[*]u8 {
    return @ptrCast(ab.sys_base.AllocPooled(ab.pool, bytes) orelse return null);
}

fn romFree(ab: *AcpiBase, memory: [*]u8, bytes: usize) void {
    ab.sys_base.FreePooled(ab.pool, memory, bytes);
}

fn romLog(ab: *AcpiBase, format: [*:0]const u8, stream: ?*const anyopaque) void {
    _ = ab.sys_base.RawDoFmt(format, stream, &rawPut, ab.sys_base);
}

fn rawPut(char: u8, put_ch_data: ?*anyopaque) callconv(.c) void {
    if (char == 0) return; // the final NUL
    const sys: *ExecBase = @ptrCast(put_ch_data.?);
    sys.RawPutChar(char);
}

/// A `T`, its fields undefined; null without memory.
pub fn alloc(ab: *AcpiBase, comptime T: type) ?*T {
    const memory = ab.machine.allocate(ab, @sizeOf(T)) orelse return null;
    return @ptrCast(@alignCast(memory));
}

/// A `T` from `alloc` given back.
pub fn free(ab: *AcpiBase, comptime T: type, item: *T) void {
    ab.machine.free(ab, @ptrCast(item), @sizeOf(T));
}

/// `count` of `T`, undefined; null without memory, or for none.
pub fn allocArray(ab: *AcpiBase, comptime T: type, count: u32) ?[*]T {
    if (count == 0) return null;
    const memory = ab.machine.allocate(ab, @sizeOf(T) * @as(usize, count)) orelse return null;
    return @ptrCast(@alignCast(memory));
}

/// `count` of `T` from `allocArray` given back; nothing for none.
pub fn freeArray(ab: *AcpiBase, comptime T: type, items: [*]T, count: u32) void {
    if (count == 0) return;
    ab.machine.free(ab, @ptrCast(items), @sizeOf(T) * @as(usize, count));
}

/// `count` bytes, undefined; null without memory.
pub fn allocBytes(ab: *AcpiBase, count: usize) ?[*]u8 {
    return ab.machine.allocate(ab, count);
}

pub fn freeBytes(ab: *AcpiBase, bytes: [*]u8, count: usize) void {
    ab.machine.free(ab, bytes, count);
}

/// A growable array of `T` in the interpreter's memory. Pointers into it
/// hold only until the next push, which may move it.
pub fn Stack(comptime T: type) type {
    return struct {
        const Self = @This();

        items: [*]T = undefined,
        count: u32 = 0,
        room: u32 = 0,

        /// One more on top, undefined; null without memory.
        pub fn push(stack: *Self, ab: *AcpiBase) ?*T {
            if (stack.count == stack.room) {
                const room: u32 = if (stack.room == 0) 8 else stack.room * 2;
                const items = allocArray(ab, T, room) orelse return null;
                if (stack.room != 0) {
                    @memcpy(items[0..stack.count], stack.items[0..stack.count]);
                    freeArray(ab, T, stack.items, stack.room);
                }
                stack.items = items;
                stack.room = room;
            }
            stack.count += 1;
            return &stack.items[stack.count - 1];
        }

        /// The one on top; null for none.
        pub fn top(stack: *const Self) ?*T {
            return if (stack.count == 0) null else &stack.items[stack.count - 1];
        }

        pub fn at(stack: *const Self, index: u32) *T {
            return &stack.items[index];
        }

        pub fn pop(stack: *Self) void {
            stack.count -= 1;
        }

        /// Its memory given back; empty afterwards.
        pub fn free(stack: *Self, ab: *AcpiBase) void {
            if (stack.room != 0) freeArray(ab, T, stack.items, stack.room);
            stack.* = .{};
        }
    };
}

/// A line in the log at `level` (`exec.LOG_*`), "acpi: " first: `format`
/// with `args`, checked against each other at compile time as kprintf
/// checks them.
pub fn log(ab: *AcpiBase, comptime level: u32, comptime format: [:0]const u8, args: anytype) void {
    comptime exec.checkFormat(format, @TypeOf(args));
    const stream = exec.fmtStream(args);
    // The line a constant of the image's, not a temporary on the stack:
    // the machine may keep the pointer.
    const line: [:0]const u8 = comptime exec.log.levelMark(level) ++ "acpi: " ++ format;
    ab.machine.log(ab, line, if (stream.len == 0) null else @ptrCast(&stream));
}
