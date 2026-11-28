// SPDX-License-Identifier: MPL-2.0
//! What the interpreter asks of what it runs in: memory, a place to say
//! what it found, and the lock that keeps a task out of the namespace
//! while another changes it. The interpreter is the same code in the resource
//! and in tools/acpicheck, which runs it on the host over a folder of
//! tables; what differs between the two is this table of calls, which
//! the base points at (`AcpiBase.machine`).
//!
//! The resource's own (`rom`) takes memory from the resource's pool -
//! many small blocks that live as long as the namespace does - writes to
//! the system log through RawDoFmt, so what the interpreter says is in
//! `C:Log` with every other module's lines, and locks with the base's
//! semaphore, shared for reading. The tool's takes the host's memory and
//! prints, and has one task, which needs no lock.
//!
//! The calls take the base first, as every function of the resource does;
//! a table of the tool's reaches its own state from there with
//! `@fieldParentPtr`.

const sdk = @import("sdk");
const exec = sdk.exec;
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
};

/// The resource's: the pool, the system log, the base's semaphore.
pub const rom = Machine{
    .allocate = romAllocate,
    .free = romFree,
    .log = romLog,
    .lock = romLock,
    .unlock = romUnlock,
};

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

/// A line in the log at `level` (`exec.LOG_*`), "acpi: " first: `format`
/// with `args`, checked against each other at compile time as kprintf
/// checks them.
pub fn log(ab: *AcpiBase, comptime level: u32, comptime format: [:0]const u8, args: anytype) void {
    comptime exec.checkFormat(format, @TypeOf(args));
    const stream = exec.fmtStream(args);
    ab.machine.log(ab, exec.log.levelMark(level) ++ "acpi: " ++ format, if (stream.len == 0) null else @ptrCast(&stream));
}
