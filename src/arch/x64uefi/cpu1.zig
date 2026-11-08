// SPDX-License-Identifier: MPL-2.0
//! The other cores: started by core 0 once exec and the tick exist, each
//! on a stack core 0 sets aside for it.
//!
//! **There is no firmware call for it.** On the other two 64-bit machines
//! a core is started by asking the firmware, which brings it up in the
//! state the boot core is in. Here a core is started by its own interrupt
//! controller: one message that holds it in reset, then two that let it go
//! at a page named by a number of one byte - so the page is below the
//! first mebibyte - and it comes up as the machine's oldest processor did,
//! in sixteen bits with no paging. What it finds there is the trampoline
//! (`start.S`), copied onto the page the stub kept for it
//! (`handover.low_page`) with this core's figures written into the copy:
//! the kernel's map, its stack, where to go and which core it is. The
//! trampoline turns paging and long mode on and jumps to `_start_other`,
//! which is the other core's `_boot`.
//!
//! **Two messages, not one**, and a wait between them: that is the
//! sequence the architecture's own manual gives for a core that may be any
//! age. A core that is already up takes the second as nothing.
//!
//! Core 0 starts the cores in turn and waits for each to say it is up
//! before the next, because exec counts the cores that run.

const cpu = @import("cpu.zig");
const coretables = @import("coretables.zig");
const desc = @import("desc.zig");
const apic = @import("apic.zig");
const timer = @import("timer.zig");
const exec = @import("../../rom/libs/exec/exec.zig");
const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const hardware = @import("sdk").hardware;
const lapic = hardware.apic;

extern fn _start_other() callconv(.c) void;

/// The trampoline, as `start.S` laid it out: the piece to copy, and the
/// figures in it the kernel writes.
extern const x64_tramp_start: u8;
extern const x64_tramp_end: u8;
extern const x64_tramp_cr3: u32;
extern const x64_tramp_stack: u64;
extern const x64_tramp_entry: u64;
extern const x64_tramp_core: u32;

/// How many cores the kernel was built to run on; the kernel sets it.
pub var cores: u32 = 1;

/// How many cores there are for it, core 0's included (`takeCores`):
/// what the machine has, not what is running.
pub var found: u32 = 1;

/// How many cores the machine's tables named, core 0's included, whether
/// or not there is state for them all: a machine of this kind commonly has
/// more than the system runs on, and the boot's line says so.
pub var in_machine: u32 = 1;

/// The page below the first mebibyte another core starts on, which the
/// stub found and kept out of memory; the kernel sets it. 0 where the
/// firmware called none of it free.
pub var low_page: usize = 0;

/// Each core's stack top, for `_start_other` to load: as many as the
/// machine has cores (`coretables.zig`), reached through the pointer
/// since they are not in the kernel's own image.
export var x64_core_stacks_at: [*]usize = &one_stack;
var one_stack: [1]usize = .{0};

/// This chip's share of the cores' tables.
pub fn layTables(bump: *coretables.Bump, count: u32) void {
    if (bump.take(usize, count)) |at| x64_core_stacks_at = at;
}

/// How many of the other cores have said they are up.
var up_count: u32 = 0;

/// Why the last core that was asked did not start, for the boot's line.
pub const ANSWER_UP: i64 = 0;
pub const ANSWER_NO_PAGE: i64 = 1;
pub const ANSWER_NO_MAP: i64 = 2;
pub const ANSWER_SILENT: i64 = 3;
pub var last_answer: i64 = ANSWER_UP;

/// How long a core is given to say it is up, and the two waits the
/// starting sequence asks for.
const patience_us: u64 = 100_000;
const after_hold_us: u64 = 10_000;
const after_release_us: u64 = 200;

/// Whether another core is running.
pub fn isUp() bool {
    return @atomicLoad(u32, &up_count, .acquire) != 0;
}

/// How many cores the firmware's tables named, core 0's included: what
/// the kernel lays the cores' tables out for, before it knows anything
/// else about them. 1 where the tables named none.
pub fn countCores(counted: u32) u32 {
    in_machine = @max(counted, 1);
    return in_machine;
}

/// The cores' controller ids into the tables laid out for them, the boot
/// core's first - it is core 0 whatever order the firmware listed them
/// in - and as many of the others as there is room for. Their ids are
/// what starting one wants.
///
/// INPUTS:
/// - `facts` - the firmware's tables, which hold the cores' description.
/// - `boot` - this core's own controller id.
pub fn takeCores(facts: *const hardware.acpi.Facts, boot: u32) void {
    const written = facts.fillCores(cpu.lapic_ids[0..coretables.cores]);
    found = @max(written, 1);
    var at: u32 = 0;
    while (at < written) : (at += 1) {
        if (cpu.lapic_ids[at] != boot) continue;
        cpu.lapic_ids[at] = cpu.lapic_ids[0];
        break;
    }
    cpu.lapic_ids[0] = boot;
}

/// Core `core` started on the stack that ends at `stack_top` (16-byte
/// aligned), its idle task prepared. True once it says it is up; false
/// where there is no page to start it on, where the kernel's map is
/// somewhere a sixteen-bit core cannot be told about, or where the core
/// never says it is up.
pub fn start(core: u32, stack_top: usize) bool {
    if (low_page == 0) {
        last_answer = ANSWER_NO_PAGE;
        return false;
    }
    const map = cpu.readCr3();
    if (map > 0xFFFF_FFFF) {
        last_answer = ANSWER_NO_MAP;
        return false;
    }
    @atomicStore(usize, &x64_core_stacks_at[core], stack_top, .release);
    layTrampoline(core, @truncate(map), stack_top);
    release(cpu.lapic_ids[core]);
    const since = timer.uptimeUs();
    while (@atomicLoad(u32, &up_count, .acquire) < core) {
        if (timer.uptimeUs() - since > patience_us) {
            last_answer = ANSWER_SILENT;
            return false;
        }
    }
    last_answer = ANSWER_UP;
    return true;
}

/// The trampoline onto the page, with this core's figures written into
/// the copy. It is laid again for each core, since three of the four
/// figures are that core's.
fn layTrampoline(core: u32, map: u32, stack_top: usize) void {
    const from = @intFromPtr(&x64_tramp_start);
    const length = @intFromPtr(&x64_tramp_end) - from;
    const source: [*]const u8 = @ptrFromInt(from);
    const onto: [*]u8 = @ptrFromInt(low_page);
    @memcpy(onto[0..length], source[0..length]);
    put(u32, offsetOf(&x64_tramp_cr3), map);
    put(u64, offsetOf(&x64_tramp_stack), stack_top);
    put(u64, offsetOf(&x64_tramp_entry), @intFromPtr(&_start_other));
    put(u32, offsetOf(&x64_tramp_core), core);
}

/// Where a figure of the trampoline's lies in the copy: as far into the
/// page as it is into the piece.
fn offsetOf(field: *const anyopaque) usize {
    return @intFromPtr(field) - @intFromPtr(&x64_tramp_start);
}

fn put(comptime T: type, offset: usize, value: T) void {
    @as(*volatile T, @ptrFromInt(low_page + offset)).* = value;
}

/// The core held in reset and let go at the trampoline's page: the
/// sequence the architecture gives, with its waits.
fn release(id: u32) void {
    const page: u32 = @intCast(low_page >> 12);
    lapic.write(lapic.LAPIC_ICR_HIGH, id << 24);
    lapic.write(lapic.LAPIC_ICR_LOW, lapic.ICR_TO_NAMED | lapic.ICR_ASSERT | lapic.ICR_INIT);
    lapic.waitSent();
    timer.spinUs(after_hold_us);
    var sent: u32 = 0;
    while (sent < 2) : (sent += 1) {
        lapic.write(lapic.LAPIC_ICR_HIGH, id << 24);
        lapic.write(lapic.LAPIC_ICR_LOW, lapic.ICR_TO_NAMED | lapic.ICR_ASSERT | lapic.ICR_STARTUP | page);
        lapic.waitSent();
        timer.spinUs(after_release_us);
    }
}

/// What an answer of `start`'s means, for the boot's line.
pub fn answerName(answer: i64) [*:0]const u8 {
    return switch (answer) {
        ANSWER_UP => "started",
        ANSWER_NO_PAGE => "the firmware left no free page below the first mebibyte to start it on",
        ANSWER_NO_MAP => "the kernel's map is past four gibibytes, where a core cannot be sent",
        ANSWER_SILENT => "it did not say it was up",
        else => "it did not start",
    };
}

/// Where another core comes to from the trampoline, through
/// `_start_other`, with its interrupts masked and on the kernel's map:
/// the core taken - which is what GS answers from then on - its own
/// registers set up, its task segment and the interrupt table loaded, its
/// interrupt controller and tick started. Then it takes tasks, says it is
/// up and goes on as its idle task.
export fn kmain_other(core: u32) callconv(.c) noreturn {
    cpu.takeCore(core, cpu.lapic_ids[core]);
    cpu.setUpState();
    desc.setUp();
    apic.initCore1();
    timer.initCore1();
    exec.coreStarted(exec.SysBase);
    _ = @atomicRmw(u32, &up_count, .Add, 1, .release);
    cpu.enableInterrupts();
    exec.idleHere(exec.SysBase);
}
