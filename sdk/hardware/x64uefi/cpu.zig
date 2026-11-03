// SPDX-License-Identifier: MIT
//! The core's counter and what it says about itself: the timestamp counter
//! as the clock and as the cycle count, the identification leaves, the
//! model registers, and a busy wait.
//!
//! **The timestamp counter is both of this machine's clocks.** On the
//! other chips the cycle counter and the wall clock are two different
//! counters at two different rates; here the one counter serves as both,
//! because on every core this system runs on it is invariant - it counts
//! at a fixed rate whatever the core's clock does, which the
//! identification leaves say (`invariantTsc`). The rate itself is not
//! always told, so the kernel measures it against another clock as the
//! RISC-V port measures its core's clock.
//!
//! What a core carries of all this is nothing: the counter is the
//! machine's, the leaves are read-only, and the model registers the kernel
//! writes are set once per core as it starts.

/// The timestamp counter, whole.
pub inline fn cycles() u64 {
    return asm volatile (
        \\rdtsc
        \\shlq $32, %%rdx
        \\orq %%rdx, %%rax
        : [result] "={rax}" (-> u64),
        :
        : .{ .rdx = true });
}

/// Its low 32 bits, which is what exec counts a core's time in.
pub inline fn ccount() u32 {
    return @truncate(cycles());
}

/// The same counter as the machine's clock: one counter, two names, so
/// that the names the other chips answer to are all here.
pub inline fn time() u64 {
    return cycles();
}

/// The counter read with everything before it finished, for measuring a
/// span rather than stamping a moment: `rdtsc` on its own may be moved
/// across loads and stores by the core.
pub inline fn timeOrdered() u64 {
    return asm volatile (
        \\lfence
        \\rdtsc
        \\shlq $32, %%rdx
        \\orq %%rdx, %%rax
        : [result] "={rax}" (-> u64),
        :
        : .{ .rdx = true, .memory = true });
}

// --- what the core says about itself -----------------------------------------------

pub const Leaf = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

/// One identification leaf. `sub` is the subleaf, 0 for the leaves that
/// have none.
pub inline fn leaf(number: u32, sub: u32) Leaf {
    var eax: u32 = number;
    var ebx: u32 = undefined;
    var ecx: u32 = sub;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "+{eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "+{ecx}" (ecx),
          [edx] "={edx}" (edx),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

/// The highest leaf the core answers.
pub inline fn highestLeaf() u32 {
    return leaf(0, 0).eax;
}

/// Whether the timestamp counter counts at a fixed rate whatever the
/// core's clock does, which leaf 0x8000_0007 bit 8 says. Everything this
/// system runs on does; a core that says it does not would want the clock
/// taken from elsewhere, and the kernel says so rather than quietly
/// mistiming everything.
pub inline fn invariantTsc() bool {
    if (leaf(0x8000_0000, 0).eax < 0x8000_0007) return false;
    return leaf(0x8000_0007, 0).edx & (1 << 8) != 0;
}

/// What the core says its timestamp counter and its bus count at, from
/// leaf 0x15: the counter's rate is `core` / `denominator` * `numerator`
/// Hz. 0 where the core does not say, which is most of them - the kernel
/// then measures it.
pub fn tscHz() u64 {
    if (highestLeaf() < 0x15) return 0;
    const l = leaf(0x15, 0);
    if (l.eax == 0 or l.ebx == 0 or l.ecx == 0) return 0;
    return @as(u64, l.ecx) * l.ebx / l.eax;
}

// --- the model registers -----------------------------------------------------------

pub inline fn readMsr(which: u32) u64 {
    return asm volatile (
        \\rdmsr
        \\shlq $32, %%rdx
        \\orq %%rdx, %%rax
        : [result] "={rax}" (-> u64),
        : [which] "{ecx}" (which),
        : .{ .rdx = true });
}

pub inline fn writeMsr(which: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [low] "{eax}" (@as(u32, @truncate(value))),
          [high] "{edx}" (@as(u32, @truncate(value >> 32))),
          [which] "{ecx}" (which),
        : .{ .memory = true });
}

// --- waiting -----------------------------------------------------------------------

/// What a spin tells the core it is doing, so that it stops racing ahead
/// on a value another core is about to change.
pub inline fn relax() void {
    asm volatile ("pause" ::: .{ .memory = true });
}

/// RFLAGS.IF: this core takes interrupts.
pub const FLAGS_IF: u64 = 1 << 9;

inline fn flags() u64 {
    return asm volatile (
        \\pushfq
        \\popq %[result]
        : [result] "=r" (-> u64),
        :
        : .{ .memory = true });
}

/// At least `count` cycles waited out, with this core's interrupts masked
/// meanwhile - so that what is being waited for is not waited for twice as
/// long because an interrupt came in the middle.
pub inline fn spinCycles(count: u32) void {
    const saved = flags();
    asm volatile ("cli" ::: .{ .memory = true });
    const since = ccount();
    while (ccount() -% since < count) relax();
    if (saved & FLAGS_IF != 0) asm volatile ("sti" ::: .{ .memory = true });
}
