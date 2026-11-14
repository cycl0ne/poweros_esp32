// SPDX-License-Identifier: MPL-2.0
//! The core's own registers and the instructions exec's hardware needs of
//! it: which core this is, its interrupts on and off, its sleep until the
//! next one, the control registers the map and the FPU are switched with,
//! and what the descriptor tables are set to.
//!
//! **Which core this is, is kept in GS.** The architecture has no register
//! that answers it: a core's identity is its local interrupt controller's
//! id, which is a load from a device and a search through a table. So each
//! core is given a block of its own as it starts (`core_blocks`) and GS's
//! base is set to it, and the core's number is the first word in it - one
//! load, `%gs:0`, which is what exec asks for on every lock it takes. GS
//! is free on this machine: nothing else here uses it, there is no code
//! outside the kernel's own privilege level, and the exception exit never
//! reloads it, so a task that moves to another core finds that core's
//! number there.
//!
//! A core's interrupts are RFLAGS.IF: clearing it holds every interrupt
//! off on this core, which is what Disable and the exception entry want.
//! The entry clears it by the gate it comes through, and the `iretq` that
//! leaves puts back what the resumed frame holds.

const exec_base = @import("../../rom/libs/exec/exec_base.zig");
const coretables = @import("coretables.zig");
const hardware = @import("sdk").hardware;

pub const ccount = hardware.cpu.ccount;
pub const cycles = hardware.cpu.cycles;
pub const relax = hardware.cpu.relax;
pub const readMsr = hardware.cpu.readMsr;
pub const writeMsr = hardware.cpu.writeMsr;
pub const leaf = hardware.cpu.leaf;
pub const FLAGS_IF = hardware.cpu.FLAGS_IF;

/// GS's base, which the core sets to its own block as it starts.
pub const MSR_GS_BASE: u32 = 0xC000_0101;

/// The page attribute table, which says what each of the eight kinds a
/// page may be marked with means for the caches. Its own register per
/// core.
pub const MSR_PAT: u32 = 0x277;
/// The entry the kernel sets to write-combining, and what that is: the
/// writes to such memory are gathered and sent on as whole bursts, in
/// order but not one by one, which is what a framebuffer written once and
/// read every frame wants (`mmu.zig`). Entry 4 is the first of the four a
/// page reaches with its own attribute bit alone, so a page is marked with
/// it by that bit and nothing else; the other four are left as the
/// architecture has them, so that every page not marked keeps the kind it
/// had.
const PAT_ENTRY_WC = 4;
const PAT_WRITE_COMBINING: u64 = 0x01;

/// What a core keeps of its own, reached through GS. Its number is first
/// because that is what is read; the rest is here so that a core's block
/// is one place and not several.
pub const CoreBlock = extern struct {
    /// The core's number, 0 up: `%gs:0`.
    core: u64 = 0,
    /// Its local interrupt controller's id, as the machine numbers it.
    lapic_id: u64 = 0,
};

/// Core 0's block, which the entry points GS at before anything reads it
/// (start.S, which takes its address): one core's worth until the cores'
/// tables are laid out, since how many cores the machine has is not known
/// that early.
pub export var core_blocks: [1]CoreBlock = .{.{}};

/// Every core's block, as many as the machine has (`coretables.zig`).
pub var blocks: [*]CoreBlock = &core_blocks;

/// Each core's local controller id, as the firmware's tables name them;
/// core 0's is its own controller's.
pub var lapic_ids: [*]u32 = &one_lapic_id;
var one_lapic_id: [1]u32 = .{0};

/// What a core says of itself, read on that core as it starts: its
/// brand string (leaves 0x8000_0002 to 0x8000_0004, each register's bytes
/// lowest first; zeroes from a core without them), its vendor's (leaf 0's
/// EBX, EDX and ECX), and the feature words of leaf 1 (ECX) and leaf 7
/// (EBX, 0 from a core without that leaf). platform.resource says what
/// they mean.
pub const Identity = extern struct {
    brand: [48]u8 = @splat(0),
    vendor: [12]u8 = @splat(0),
    leaf1_ecx: u32 = 0,
    leaf7_ebx: u32 = 0,
};

/// Each core's, by its number.
pub var identities: [*]Identity = &one_identity;
var one_identity: [1]Identity = .{.{}};

/// The core this runs on asked what it is, into its place in the table:
/// once it has its number and its SSE registers are on (`setUpState`),
/// which the copying uses.
pub fn identifyHere() void {
    identities[coreId()] = identity();
}

fn identity() Identity {
    var said: Identity = .{};
    if (leaf(0x8000_0000, 0).eax >= 0x8000_0004) {
        for (0..3) |index| {
            const part = leaf(0x8000_0002 + @as(u32, @intCast(index)), 0);
            for ([_]u32{ part.eax, part.ebx, part.ecx, part.edx }, 0..) |word, register| {
                for (0..4) |byte| said.brand[index * 16 + register * 4 + byte] = @truncate(word >> @intCast(byte * 8));
            }
        }
    }
    const first = leaf(0, 0);
    for ([_]u32{ first.ebx, first.edx, first.ecx }, 0..) |word, register| {
        for (0..4) |byte| said.vendor[register * 4 + byte] = @truncate(word >> @intCast(byte * 8));
    }
    said.leaf1_ecx = leaf(1, 0).ecx;
    if (first.eax >= 7) said.leaf7_ebx = leaf(7, 0).ebx;
    return said;
}

/// This chip's share of the cores' tables.
pub fn layTables(bump: *coretables.Bump, count: u32) void {
    if (bump.take(CoreBlock, count)) |at| blocks = at;
    if (bump.take(u32, count)) |at| lapic_ids = at;
    if (bump.take(Identity, count)) |at| identities = at;
}

/// Core 0 moved onto them: what its own block held, and GS pointed at its
/// place in the table.
pub fn useTables() void {
    blocks[0] = core_blocks[0];
    lapic_ids[0] = one_lapic_id[0];
    writeMsr(MSR_GS_BASE, @intFromPtr(&blocks[0]));
}

/// This core made core `core`: its block filled and GS pointed at it, so
/// `coreId` answers from here on. Nothing may read the core's number
/// before this.
pub fn takeCore(core: u32, lapic_id: u32) void {
    blocks[core] = .{ .core = core, .lapic_id = lapic_id };
    lapic_ids[core] = lapic_id;
    writeMsr(MSR_GS_BASE, @intFromPtr(&blocks[core]));
    takePat();
}

/// How much memory this core can address at all: 2 to the power of the
/// physical address width it reports (leaf 0x8000_0008, the low byte of
/// EAX), which is 40 bits on the emulator's cores and 46 or more on a
/// machine. 4 GiB where the core says nothing, which no core this runs on
/// does.
pub fn addressableBytes() usize {
    if (leaf(0x8000_0000, 0).eax < 0x8000_0008) return 1 << 32;
    const bits: u8 = @truncate(leaf(0x8000_0008, 0).eax);
    if (bits < 32 or bits >= 64) return 1 << 32;
    return @as(usize, 1) << @intCast(bits);
}

/// This core's page attribute table with one entry changed to
/// write-combining, the other seven as the architecture leaves them. Every
/// core has its own and the map is shared, so a core that does not do this
/// would read a page the kernel marked that way as write-back memory - so
/// it is done here, where a core is taken, rather than where the map is
/// made.
fn takePat() void {
    const shift: u6 = PAT_ENTRY_WC * 8;
    const table = readMsr(MSR_PAT) & ~(@as(u64, 0xFF) << shift);
    writeMsr(MSR_PAT, table | PAT_WRITE_COMBINING << shift);
}

/// The core this runs on: 0 up.
pub inline fn coreId() u32 {
    return @truncate(asm volatile ("movq %%gs:0, %[r]"
        : [r] "=r" (-> u64),
    ));
}

/// This core's interrupts masked; answers RFLAGS as it was, for
/// `restoreInterrupts`. Read and cleared in one instruction stream, so
/// nothing comes between.
pub inline fn disableInterrupts() u32 {
    return @truncate(asm volatile (
        \\pushfq
        \\popq %[r]
        \\cli
        : [r] "=r" (-> u64),
        :
        : .{ .memory = true }));
}

/// The interrupts as `disableInterrupts` found them: on again only if they
/// were on.
pub inline fn restoreInterrupts(saved: u32) void {
    if (saved & FLAGS_IF != 0) asm volatile ("sti" ::: .{ .memory = true });
}

pub inline fn enableInterrupts() void {
    asm volatile ("sti" ::: .{ .memory = true });
}

/// Whether this core takes interrupts now.
pub inline fn interruptsOn() bool {
    const flags = asm volatile (
        \\pushfq
        \\popq %[r]
        : [r] "=r" (-> u64),
        :
        : .{ .memory = true });
    return flags & FLAGS_IF != 0;
}

/// Sleep until the next interrupt, and come back with the interrupts
/// masked again. `sti` lets them in only after the instruction that
/// follows it, which is the `hlt`: so an interrupt that arrives between
/// the two is taken after the core is asleep and not before, and the core
/// cannot sleep through one that was already pending. `hlt` with the
/// interrupts masked would never end.
pub inline fn waitForInterrupt() void {
    asm volatile (
        \\sti
        \\hlt
        \\cli
        ::: .{ .memory = true });
}

pub inline fn stackPointer() usize {
    return asm volatile ("movq %%rsp, %[r]"
        : [r] "=r" (-> usize),
    );
}

/// Where the interrupt descriptor table is (IDTR), which is this
/// machine's answer to a vector base.
pub fn vecbase() usize {
    var area: [10]u8 align(2) = @splat(0);
    asm volatile ("sidt %[at]"
        : [at] "=m" (area),
    );
    var base: u64 = 0;
    for (0..8) |byte| base |= @as(u64, area[2 + byte]) << @intCast(8 * byte);
    return @intCast(base);
}

/// The core's id as platform.resource reports it: its local controller's.
/// Read from the cores' table, which is where every core's block is once
/// the tables are laid out; `core_blocks` holds core 0's alone and is
/// what `blocks` points at until then.
pub inline fn prid() u32 {
    return @truncate(blocks[coreId()].lapic_id);
}

/// The data cache's line, in bytes: leaf 1's CLFLUSH line size, in
/// eight-byte units. 0 where the core does not say, which none this runs
/// on does.
pub fn dcacheLine() u32 {
    if (hardware.cpu.highestLeaf() < 1) return 0;
    return ((leaf(1, 0).ebx >> 8) & 0xFF) * 8;
}

// --- the control registers ---------------------------------------------------------

/// CR0: the FPU's state (EM, MP, NE) and whether a read-only page is
/// read-only to this privilege level too (WP).
pub const CR0_MP: u64 = 1 << 1;
pub const CR0_EM: u64 = 1 << 2;
pub const CR0_NE: u64 = 1 << 5;
pub const CR0_WP: u64 = 1 << 16;

/// CR4: the SSE registers saved and restored by FXSAVE (OSFXSR) and their
/// exceptions taken as exceptions of their own (OSXMMEXCPT).
pub const CR4_OSFXSR: u64 = 1 << 9;
pub const CR4_OSXMMEXCPT: u64 = 1 << 10;

pub inline fn readCr0() u64 {
    return asm volatile ("movq %%cr0, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub inline fn writeCr0(value: u64) void {
    asm volatile ("movq %[v], %%cr0"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

pub inline fn readCr3() u64 {
    return asm volatile ("movq %%cr3, %[r]"
        : [r] "=r" (-> u64),
    );
}

/// The map changed: every translation this core holds is dropped by the
/// write itself.
pub inline fn writeCr3(value: u64) void {
    asm volatile ("movq %[v], %%cr3"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

pub inline fn readCr4() u64 {
    return asm volatile ("movq %%cr4, %[r]"
        : [r] "=r" (-> u64),
    );
}

pub inline fn writeCr4(value: u64) void {
    asm volatile ("movq %[v], %%cr4"
        :
        : [v] "r" (value),
        : .{ .memory = true });
}

/// The address a page fault named (CR2).
pub inline fn faultAddress() usize {
    return asm volatile ("movq %%cr2, %[r]"
        : [r] "=r" (-> usize),
    );
}

/// The SSE registers in use, and a read-only page read-only to the kernel
/// as well: what the compiler's code and the kernel's map need of the
/// core. Set on every core as it starts.
pub fn setUpState() void {
    var cr0 = readCr0();
    cr0 &= ~CR0_EM; // the FPU is there: no emulation
    cr0 |= CR0_MP | CR0_NE | CR0_WP;
    writeCr0(cr0);
    writeCr4(readCr4() | CR4_OSFXSR | CR4_OSXMMEXCPT);
}

/// The core stopped for good: interrupts masked, asleep.
pub fn halt() noreturn {
    _ = disableInterrupts();
    while (true) asm volatile ("hlt");
}
