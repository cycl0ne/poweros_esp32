// SPDX-License-Identifier: MPL-2.0
//! Interrupts: one handler per interrupt number (SetIntVector), a
//! priority-ordered chain of servers beside it (AddIntServer,
//! RemIntServer), the software interrupts (Cause), and Disable/Enable.
//!
//! A handler owns its number and need not say whether its own peripheral
//! raised the interrupt, so that source gets a CPU line to itself. Servers
//! must say, by answering non-zero only for their own hardware, so several
//! server-only sources may share a line - every chain on it runs when it
//! fires. That is what lets twelve lines carry more than twelve sources:
//! exec gives one away per source until they run out, after which
//! server-only sources share.
//!
//! exec touches no hardware itself. Routing a number to the CPU and masking
//! interrupts go through `interrupt_hardware`, which the kernel fills in
//! (src/arch/esp32s3/intmatrix.zig), and the kernel calls `dispatchInterrupt`
//! when a number fires.
//!
//! The calls are a file each in this folder; this file is everything else.
//! What exec needs from the interrupt hardware and the no-hardware stand-in;
//! reaching a number's vector and keeping its routing in step with who
//! listens; running the servers when a number fires and the software
//! interrupts when theirs does; and the other side of the CPU's exceptions
//! - the trap dispatch, the alert display's default, and the kernel's
//! panic handler.
//!
//! **CPU exceptions and alerts.** An exception goes to the running task's
//! trap code; if there is none, or it declines, exec raises a dead-end
//! alert - the Guru. How an alert is *shown* is the kernel's, through
//! `alert_hook`. A Zig panic in the kernel ends here as well
//! (`kernelPanic`).
//!
//! The dispatchers and the alert path go through nothing replaceable, and
//! nothing on them allocates: they run from the exception entry, and the
//! code that reports a broken machine cannot depend on a vector something
//! may have replaced (codex rule 1), nor on memory when what is broken may
//! be the memory. `kernelPanic` and `alertAt` take no base: the panic
//! handler's signature is Zig's, and an alert must be raisable from
//! anywhere.

const sdk = @import("sdk");
const exec = @import("../exec.zig");

const ExecBase = exec.ExecBase;
const Interrupt = sdk.exec.Interrupt;
const IntVector = sdk.exec.IntVector;
const TrapInfo = sdk.exec.TrapInfo;

/// What exec needs from the interrupt hardware.
pub const InterruptHardware = struct {
    /// Route `int_number` to the CPU and enable it. False if impossible.
    /// `shareable`: only servers are on it, which say for themselves
    /// whether their hardware raised it, so it may share a CPU line with
    /// other such sources - every chain on a line runs when the line
    /// fires. A handler need not check, so a source with one gets a line
    /// of its own.
    enable_source: *const fn (int_number: u32, shareable: bool) bool,
    disable_source: *const fn (int_number: u32) void,
    /// Mask all interrupts; returns the previous state for `restore`.
    disable: *const fn () u32,
    restore: *const fn (state: u32) void,
    /// Raise the software interrupt; its handler calls dispatchSoftInts.
    cause_softint: *const fn () void,
};

/// Where exec reaches the interrupt hardware. The kernel writes it before
/// the bootstrap; host tests put their own stub here. It is the kernel's
/// state rather than a module's, like `SysBase` beside it.
pub var interrupt_hardware: InterruptHardware = no_hardware;

/// No hardware at all: nothing is routed and nothing is masked. What the
/// host tests run against, and what exec starts with until the kernel puts
/// the real one in.
pub const no_hardware: InterruptHardware = .{
    .enable_source = noEnable,
    .disable_source = noDisable,
    .disable = noMask,
    .restore = noRestore,
    .cause_softint = noCause,
};

/// `no_hardware`'s enable_source: every source is taken to be routable, so
/// a test never meets the "no free CPU interrupt line" panic.
fn noEnable(_: u32, _: bool) bool {
    return true;
}

/// `no_hardware`'s disable_source: nothing was routed, so nothing is
/// released.
fn noDisable(_: u32) void {}

/// `no_hardware`'s disable: nothing is masked, and the state to restore
/// is 0.
fn noMask() u32 {
    return 0;
}

/// `no_hardware`'s restore: nothing was masked.
fn noRestore(_: u32) void {}

/// `no_hardware`'s cause_softint: there is nothing to raise.
fn noCause() void {}

// --- vectors and routing ----------------------------------------------------

/// Whether anything is listening to this number - a handler, a server, or
/// both. It is what decides whether the number is routed to the CPU at all.
///
/// INPUTS:
/// - `int_vector` - the number's vector.
pub fn inUse(int_vector: *IntVector) bool {
    return int_vector.handler != null or !int_vector.servers.isEmpty();
}

/// The vector of one interrupt number. Out of range is fatal: there is no
/// sensible answer, and carrying on would read past the array.
///
/// INPUTS:
/// - `base` - exec: its vectors.
/// - `int_number` - the source, below `INTB_COUNT`.
pub fn vector(base: *ExecBase, int_number: u32) *IntVector {
    if (int_number >= sdk.hardware.intbits.INTB_COUNT) @panic("interrupt number out of range");
    return &base.int_vects[int_number];
}

/// Keeps a number's routing in step with who is listening to it: routed
/// when it gains its first handler or server, released when the last one
/// goes, and routed again when it gains or loses a handler - because that
/// is what decides whether it may share a CPU line.
///
/// Finding no free line is fatal: an interrupt that cannot be delivered has
/// no useful behaviour to fall back on.
///
/// INPUTS:
/// - `int_vector` - the vector as it is **now**.
/// - `int_number` - which one.
/// - `was_in_use`, `was_shareable` - what it looked like before the caller
///   changed it, since that is what says which of the three happened.
pub fn route(int_vector: *IntVector, int_number: u32, was_in_use: bool, was_shareable: bool) void {
    const hardware = &interrupt_hardware;
    const in_use = inUse(int_vector);
    const shareable = int_vector.handler == null;
    if (in_use and (!was_in_use or shareable != was_shareable)) {
        if (was_in_use) hardware.disable_source(int_number);
        if (!hardware.enable_source(int_number, shareable)) @panic("no free CPU interrupt line");
    } else if (!in_use and was_in_use) {
        hardware.disable_source(int_number);
    }
}

// --- dispatch ---------------------------------------------------------------

/// What exec does when an interrupt number fires: the handler, then the
/// servers in priority order until one answers non-zero. The kernel calls
/// it from the interrupt entry.
///
/// The vector's count is raised first, so a source that fires is counted
/// whether or not anything is listening - which is what makes `s3> ints`
/// worth reading when a driver is not being woken.
///
/// INPUTS:
/// - `base` - exec: its vectors.
/// - `int_number` - the source that fired.
pub fn dispatchInterrupt(base: *ExecBase, int_number: u32) void {
    const int_vector = vector(base, int_number);
    int_vector.count +%= 1;
    if (int_vector.handler) |handler| {
        const code: sdk.exec.IntHandlerFn = @ptrCast(@alignCast(handler.code.?));
        code(handler.data, int_number);
    }
    var it = int_vector.servers.iterator();
    while (it.next()) |node| {
        const server: *Interrupt = @fieldParentPtr("node", node);
        const code: sdk.exec.IntServerFn = @ptrCast(@alignCast(server.code.?));
        if (code(server.data, int_number) != 0) break;
    }
}

/// The five software interrupt priorities, one queue each. A node's own
/// priority is rounded down to one of these, so the queues are a fixed
/// array rather than a sorted list - which is what keeps `Cause` from
/// walking anything with interrupts masked.
pub const softint_priorities = [_]i8{ -32, -16, 0, 16, 32 };

/// Runs every queued software interrupt, highest priority first, including
/// any caused while this is running. The kernel calls it when the software
/// interrupt fires.
///
/// The node's type is cleared *before* its code runs, and outside Disable,
/// so a software interrupt may cause itself again from inside its own run -
/// which is what lets one drain a queue a piece at a time.
///
/// INPUTS:
/// - `base` - exec: its queues, and the jump table Disable and Enable go
///   through.
pub fn dispatchSoftInts(base: *ExecBase) void {
    const sys = base.iface();
    while (true) {
        sys.Disable();
        const next = nextSoftInt(base);
        if (next) |interrupt| interrupt.node.type = .interrupt; // may be caused again from here on
        sys.Enable();
        const interrupt = next orelse return;
        const code: sdk.exec.SoftIntFn = @ptrCast(@alignCast(interrupt.code.?));
        code(interrupt.data);
    }
}

/// The highest-priority queued software interrupt, taken off its queue, or
/// null when all five are empty. The caller holds Disable.
///
/// INPUTS:
/// - `base` - exec: its queues, and the jump table `RemHead` goes through.
fn nextSoftInt(base: *ExecBase) ?*Interrupt {
    var queue: usize = softint_priorities.len;
    while (queue > 0) {
        queue -= 1;
        if (base.iface().RemHead(&base.soft_ints[queue])) |node| return @fieldParentPtr("node", node);
    }
    return null;
}

// --- traps and alerts -------------------------------------------------------

/// What exec does with a CPU exception that is neither an interrupt nor a
/// syscall. The kernel calls it from the exception entry, where there is
/// no task context to call through - so the running task is read from the
/// base, as the scheduler reads it.
///
/// It goes to the running task's trap code, and **returns only if that
/// answered non-zero** - the trap code may have moved `info.pc` past the
/// instruction that faulted. Anything else ends in a dead-end alert, which
/// does not come back.
///
/// INPUTS:
/// - `base` - exec: the running task.
/// - `info` - the exception, with the `pc` execution resumes at.
pub fn dispatchTrap(base: *ExecBase, info: *TrapInfo) void {
    const task = base.this_task;
    if (task.trap_code) |code| {
        if (code(info, task.trap_data) != 0) return;
    }
    alert_hook(sdk.exec.ACPU_Base | info.number, info.pc, info);
}

/// How an alert is shown. `alert_num` is what went wrong, `where` the
/// guru's second number - the address that raised it - and `info` is set
/// for a CPU exception and null otherwise.
///
/// It **must not return** when `AT_DeadEnd` is set.
pub const AlertFn = *const fn (alert_num: u32, where: usize, info: ?*const TrapInfo) void;

/// Where exec reaches the alert display. The kernel writes it before the
/// bootstrap. It is the kernel's state rather than a module's, like
/// `SysBase`.
pub var alert_hook: AlertFn = default_alert;

/// What exec shows an alert with until the kernel puts its own in: a dead
/// end panics, and a recoverable alert is dropped. It is what the host
/// tests run against.
pub const default_alert: AlertFn = defaultAlert;

/// `default_alert`'s body: a dead end panics, anything else is ignored.
/// `where` and `info` have nowhere to go without a display.
fn defaultAlert(alert_num: u32, where: usize, info: ?*const TrapInfo) void {
    _ = where;
    _ = info;
    if (alert_num & sdk.exec.AT_DeadEnd != 0) @panic("dead-end alert");
}

/// Raises an alert naming an address the caller chooses rather than its
/// own return address.
///
/// INPUTS:
/// - `alert_num` - what went wrong.
/// - `where` - the guru's second number.
pub fn alertAt(alert_num: u32, where: usize) void {
    alert_hook(alert_num, where, null);
}

/// The kernel's Zig panic handler, which main.zig installs: the message
/// and the address on the raw port with `kprintf`, then a dead-end alert
/// (`AN_KernelPanic`), which halts. Before `RawIOInit` nothing is printed
/// at all.
///
/// INPUTS:
/// - `msg` - the panic's text, cut to 96 bytes because it is copied onto a
///   stack that may be nearly spent.
/// - `ret_addr` - where it happened; this function's own caller stands in
///   when there is none.
pub fn kernelPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    var text: [97]u8 = undefined;
    const length = @min(msg.len, text.len - 1);
    @memcpy(text[0..length], msg[0..length]);
    text[length] = 0;
    exec.kprintf("\n*** KERNEL PANIC: %s\n", .{text[0..length :0]});
    if (ret_addr) |address| exec.kprintf("    at 0x%08x\n", .{@as(u32, @truncate(address))});
    alertAt(sdk.exec.AT_DeadEnd | sdk.exec.AN_KernelPanic, ret_addr orelse @returnAddress());
    while (true) {} // a dead-end alert doesn't come back
}
