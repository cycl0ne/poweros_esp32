// SPDX-License-Identifier: MPL-2.0
//! The graphics block: where its registers are, the wait for its engines
//! once its firmware is loaded, and its memory hub - what its engines'
//! memory traffic goes through.
//!
//! **Its registers** are counted in 32-bit words from the block's first
//! two addresses in the device's table, as the version this reads has
//! them (11.0.1); another version numbers some of them otherwise, and is
//! said so of instead. A block switched off answers every read with 0
//! and drops every write, so they are read only while it is powered.
//!
//! **The engines' code.** Once the RLC has been told every part is there
//! and the power controller powers the block up, the RLC hands each
//! engine its code; the block is up when its command processor is idle
//! (`CP_STAT` 0) and its RLC says its loading is complete (the top bit of
//! `RLC_RLCS_BOOTLOAD_STATUS`), as the vendor's driver waits for it.
//!
//! **The hub** comes up off: it passes its engines' addresses on as they
//! are, without a page table, with its caches off. It is set as the
//! vendor's driver sets it once the engines have their code
//! (gfxhub_v3_0_gart_enable): the system aperture over the device's own
//! memory, which an engine reaches by its device address, uncached, so
//! that what it writes is in the memory when the CPU reads it there; its
//! TLB and L2 cache on; and its first context - the one the system's
//! jobs run in - with a one-level page table over a range of 512 MiB at
//! the top of the device's lower addresses, which maps the machine's
//! memory for it page by page. The table is in the device's own memory
//! and is made empty: until a page is mapped into it, an address in its
//! range faults to the scratch page. A fault is taken by the hub alone,
//! the access sent to the scratch page; it does not stop the engine.
//! The other fifteen contexts are left off: nothing the system runs uses
//! them. The bus block's doorbells are left as they are too: the queues
//! are told of new work through their own registers.
//!
//! **A page of the machine's memory** is mapped into the table as the
//! vendor's driver maps one into its GART (amdgpu_gart_map,
//! amdgpu_ttm_tt_pte_flags): its machine address with the entry valid, in
//! the machine's memory, snooped - so that the engines' reads and writes
//! go through the CPUs' caches, and neither side needs one written back
//! or dropped - readable, writable and executable, and uncached in the
//! block. An entry taken out is written 0, which is not valid. After
//! either, the first context's TLB is dropped, so that no engine keeps a
//! translation of the old entries.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const AMDGPUBase = @import("../amdgpu_base.zig").AMDGPUBase;

/// The version whose registers are known.
const known = .{ .major = 11, .minor = 0, .revision = 1 };

/// A register: which of the block's addresses it is counted from, and
/// its number from there.
pub const Register = struct { segment: u8, offset: u32 };

pub const CP_STAT: Register = .{ .segment = 0, .offset = 0x0f40 };
pub const RLC_RLCS_BOOTLOAD_STATUS: Register = .{ .segment = 1, .offset = 0x4e7e };
pub const BOOTLOAD_COMPLETE: u32 = 0x8000_0000;
const CP_DEBUG: Register = .{ .segment = 0, .offset = 0x1e1f };
const CPG_UTCL1_ERROR_HALT_DISABLE: u32 = 1 << 15;

// The hub's registers, all counted from the first address.
const SYSTEM_APERTURE_DEFAULT_ADDR_LSB = 0x15a8;
const SYSTEM_APERTURE_DEFAULT_ADDR_MSB = 0x15a9;
const L2_CNTL = 0x15bc;
const L2_CNTL2 = 0x15bd;
const L2_CNTL3 = 0x15be;
const L2_PROTECTION_FAULT_CNTL = 0x15c4;
const L2_PROTECTION_FAULT_CNTL2 = 0x15c5;
const L2_PROTECTION_FAULT_DEFAULT_ADDR_LO32 = 0x15cb;
const L2_PROTECTION_FAULT_DEFAULT_ADDR_HI32 = 0x15cc;
const L2_CONTEXT1_IDENTITY_APERTURE_LOW_ADDR_LO32 = 0x15ce;
const L2_CONTEXT1_IDENTITY_APERTURE_LOW_ADDR_HI32 = 0x15cf;
const L2_CONTEXT1_IDENTITY_APERTURE_HIGH_ADDR_LO32 = 0x15d0;
const L2_CONTEXT1_IDENTITY_APERTURE_HIGH_ADDR_HI32 = 0x15d1;
const L2_CONTEXT_IDENTITY_PHYSICAL_OFFSET_LO32 = 0x15d2;
const L2_CONTEXT_IDENTITY_PHYSICAL_OFFSET_HI32 = 0x15d3;
const L2_CNTL4 = 0x15d4;
const L2_CNTL5 = 0x15da;
const AGP_TOP = 0x167a;
const AGP_BOT = 0x167b;
const AGP_BASE = 0x167c;
const SYSTEM_APERTURE_LOW_ADDR = 0x167d;
const SYSTEM_APERTURE_HIGH_ADDR = 0x167e;
const MX_L1_TLB_CNTL = 0x167f;
const CONTEXT0_CNTL = 0x1688;
const INVALIDATE_ENG17_REQ = 0x16bc;
const INVALIDATE_ENG17_ACK = 0x16ce;
const INVALIDATE_ENG0_ADDR_RANGE_LO32 = 0x16cf;
const INVALIDATE_ENG0_ADDR_RANGE_HI32 = 0x16d0;
const invalidate_engines = 18;
const invalidate_range_stride = 2;
const CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32 = 0x16f3;
const CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32 = 0x16f4;
const CONTEXT0_PAGE_TABLE_START_ADDR_LO32 = 0x1713;
const CONTEXT0_PAGE_TABLE_START_ADDR_HI32 = 0x1714;
const CONTEXT0_PAGE_TABLE_END_ADDR_LO32 = 0x1733;
const CONTEXT0_PAGE_TABLE_END_ADDR_HI32 = 0x1734;

// MX_L1_TLB_CNTL's fields: the TLB on, addresses outside the system
// aperture translated by the first context, the advanced driver model, an
// unmapped access in the aperture not let through, and the memory type of
// what goes through the aperture - uncached.
const ENABLE_L1_TLB: u32 = 1 << 0;
const SYSTEM_ACCESS_MODE_SHIFT = 3;
const SYSTEM_ACCESS_MODE_MASK: u32 = 3 << SYSTEM_ACCESS_MODE_SHIFT;
const SYSTEM_ACCESS_TRANSLATED: u32 = 3;
const SYSTEM_APERTURE_UNMAPPED_ACCESS: u32 = 1 << 5;
const ENABLE_ADVANCED_DRIVER_MODEL: u32 = 1 << 6;
const ECO_BITS_MASK: u32 = 0xf << 7;
const MTYPE_SHIFT = 11;
const MTYPE_MASK: u32 = 7 << MTYPE_SHIFT;
const MTYPE_UC: u32 = 3;

// L2_CNTL's fields.
const ENABLE_L2_CACHE: u32 = 1 << 0;
const ENABLE_L2_FRAGMENT_PROCESSING: u32 = 1 << 1;
const L2_PDE0_CACHE_TAG_GENERATION_MODE: u32 = 1 << 8;
const ENABLE_DEFAULT_PAGE_OUT_TO_SYSTEM_MEMORY: u32 = 1 << 11;
const PDE_FAULT_CLASSIFICATION: u32 = 1 << 18;
const CONTEXT1_IDENTITY_ACCESS_MODE_SHIFT = 19;
const CONTEXT1_IDENTITY_ACCESS_MODE_MASK: u32 = 3 << CONTEXT1_IDENTITY_ACCESS_MODE_SHIFT;
const IDENTITY_MODE_FRAGMENT_SIZE_MASK: u32 = 0x1f << 21;
// L2_CNTL2's: every L1 TLB and the L2 cache dropped.
const INVALIDATE_ALL_L1_TLBS: u32 = 1 << 0;
const INVALIDATE_L2_CACHE: u32 = 1 << 1;
// L2_CNTL3 from its reset value, with the bank select and the big
// fragment size of a table that translates further.
const L2_CNTL3_RESET: u32 = 0x80120007;
const BANK_SELECT_MASK: u32 = 0x3f;
const BANK_SELECT: u32 = 12;
const L2_CACHE_BIGK_FRAGMENT_SIZE_SHIFT = 15;
const L2_CACHE_BIGK_FRAGMENT_SIZE_MASK: u32 = 0x1f << L2_CACHE_BIGK_FRAGMENT_SIZE_SHIFT;
const L2_CACHE_BIGK_FRAGMENT_SIZE: u32 = 9;
// L2_CNTL4 from its reset value, the walker's requests for tables not
// physical; L2_CNTL5 from its reset value, the small fragment size 0.
const L2_CNTL4_RESET: u32 = 0x000000c1;
const VMC_TAP_REQUEST_PHYSICAL: u32 = 3 << 6;
const L2_CNTL5_RESET: u32 = 0x00003fe0;
const L2_CACHE_SMALLK_FRAGMENT_SIZE_MASK: u32 = 0x1f;
// L2_PROTECTION_FAULT_CNTL's: every kind of fault sent to the default
// page, none of them stopping the hub; CNTL2's retry fault interrupt and
// the page migration's retry.
const FAULT_ENABLE_DEFAULTS: u32 = 0x1ffc;
const CRASH_ON_FAULTS: u32 = 3 << 30;
const ACTIVE_PAGE_MIGRATION_PTE_READ_RETRY: u32 = 1 << 18;
const ENABLE_RETRY_FAULT_INTERRUPT: u32 = 1 << 19;
// CONTEXT0_CNTL's: the context on, a one-level table, and no retry on a
// permission or invalid page fault.
const ENABLE_CONTEXT: u32 = 1 << 0;
const PAGE_TABLE_DEPTH_MASK: u32 = 3 << 1;
const RETRY_PERMISSION_OR_INVALID_PAGE_FAULT: u32 = 1 << 7;
// An invalidation of the first context: its L2's entries of every level
// and its L1's.
const INVALIDATE_CONTEXT0: u32 = 1 << 0 | 0x1f << 19;

/// The page table's entries: eight bytes each, one for each page of
/// 4 KiB of the range. A table's base and an entry say they are valid in
/// bit 0.
pub const page_bytes: u64 = 4096;
const entry_bytes: u64 = 8;
const valid: u64 = 1;

// An entry's fields for a page of the machine's memory.
const PTE_SYSTEM: u64 = 1 << 1;
const PTE_SNOOPED: u64 = 1 << 2;
const PTE_EXECUTABLE: u64 = 1 << 4;
const PTE_READABLE: u64 = 1 << 5;
const PTE_WRITEABLE: u64 = 1 << 6;
const PTE_MTYPE_SHIFT = 48;
const PTE_ADDRESS_MASK: u64 = 0x0000_ffff_ffff_f000;
const system_page: u64 = valid | PTE_SYSTEM | PTE_SNOOPED | PTE_EXECUTABLE | PTE_READABLE | PTE_WRITEABLE |
    @as(u64, MTYPE_UC) << PTE_MTYPE_SHIFT;

/// The range the first context maps, as the vendor places it: 512 MiB at
/// the top of the device's addresses below the hole at 2^47, started on
/// 4 GiB.
pub const gart_bytes: u64 = 512 << 20;
const hole_start: u64 = 1 << 47;
const four_gib: u64 = 1 << 32;
pub const gart_start: u64 = (hole_start - gart_bytes) & ~(four_gib - 1);

/// How long the engines may take to have their code, and the hub its TLB
/// dropped: the vendor's 100 ms each.
const engines_most_us: u64 = 100_000;
const invalidate_most_us: u64 = 100_000;

fn isKnown(block: amdgpu.GPUBlock) bool {
    return block.major == known.major and block.minor == known.minor and block.revision == known.revision;
}

/// The graphics block kept in the base where it is one whose registers
/// are known; said on the raw port where it is not.
pub fn take(ab: *AMDGPUBase, block: amdgpu.GPUBlock) void {
    if (!isKnown(block) or block.count < 2) {
        exec.kprintf(ab.sys_base, "%s: the graphics block is %d.%d.%d, whose registers this does not know\n", .{
            amdgpu.AMDGPUNAME, @as(u32, block.major), @as(u32, block.minor), @as(u32, block.revision),
        });
        return;
    }
    ab.graphics = block;
    ab.graphics_known = true;
}

/// The register `register` of the graphics block.
pub fn at(ab: *AMDGPUBase, register: Register) *volatile u32 {
    return reg(@as(usize, @intCast(ab.info.registers)) + (@as(usize, ab.graphics.addresses[register.segment]) + register.offset) * 4);
}

fn hub(ab: *AMDGPUBase, offset: u32) *volatile u32 {
    return at(ab, .{ .segment = 0, .offset = offset });
}

/// A wait of so many microseconds, at the least.
fn pause(ab: *AMDGPUBase, us: u32) void {
    var never: exec.Waitable = .{};
    const list = [_]*exec.Waitable{&never};
    _ = ab.sys_base.WaitForAny(&list, 1, us);
}

/// Whether the block's engines all have their code: its command
/// processor idle and its RLC's loading complete.
pub fn enginesHaveCode(ab: *AMDGPUBase) bool {
    return at(ab, CP_STAT).* == 0 and at(ab, RLC_RLCS_BOOTLOAD_STATUS).* & BOOTLOAD_COMPLETE != 0;
}

/// Waits until the engines have their code, 100 ms at most: true once
/// they do, said on the raw port where they do not.
pub fn waitForEngines(ab: *AMDGPUBase) bool {
    const sys = ab.sys_base;
    const until = sys.UptimeUs() + engines_most_us;
    while (!enginesHaveCode(ab)) {
        if (sys.UptimeUs() > until) {
            exec.kprintf(sys, "%s: the graphics block's engines do not have their code: CP_STAT %x, RLC_RLCS_BOOTLOAD_STATUS %x\n", .{
                amdgpu.AMDGPUNAME, at(ab, CP_STAT).*, at(ab, RLC_RLCS_BOOTLOAD_STATUS).*,
            });
            return false;
        }
        pause(ab, 1000);
    }
    return true;
}

fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

/// Where a piece of the device's memory is in the machine: what the hub
/// is given for a table or a page, which it reads by that address.
fn machineOf(ab: *AMDGPUBase, piece: amdgpu.GPUMemory) u64 {
    return ab.memory_machine + (piece.device - ab.memory_device);
}

/// `bytes` at `cpu` set to zero, eight at a time.
fn clear(cpu: u64, bytes: u64) void {
    var offset: u64 = 0;
    while (offset < bytes) : (offset += 8) {
        const to: *volatile u64 = @ptrFromInt(@as(usize, @intCast(cpu + offset)));
        to.* = 0;
    }
}

/// The hub turned on: its page table and scratch page taken from the
/// device's memory and cleared, then every register written as the
/// vendor's driver writes them, its faults sent to the scratch page and
/// its TLB dropped. False, said on the raw port, where the memory cannot
/// be had or the TLB is not dropped in time; what was taken is given
/// back then.
pub fn turnOnHub(ab: *AMDGPUBase) bool {
    const sys = ab.sys_base;
    const owner = amdgpu.AMDGPUNAME;
    const gpu: *sdk.interface.amdgpu.AMDGPUBase = @ptrCast(&ab.lib);
    const table_bytes = gart_bytes / page_bytes * entry_bytes;
    var table: amdgpu.GPUMemory = .{};
    var scratch: amdgpu.GPUMemory = .{};
    if (!gpu.AllocGPUMemory(@intCast(table_bytes), @intCast(page_bytes), &table)) {
        exec.kprintf(sys, "%s: no room in the device's memory for the graphics hub's page table\n", .{owner});
        return false;
    }
    if (!gpu.AllocGPUMemory(@intCast(page_bytes), @intCast(page_bytes), &scratch)) {
        exec.kprintf(sys, "%s: no room in the device's memory for the graphics hub's scratch page\n", .{owner});
        gpu.FreeGPUMemory(&table);
        return false;
    }
    clear(table.cpu, table_bytes);
    clear(scratch.cpu, page_bytes);
    fence();

    // The first context's table and range (init_gart_aperture_regs).
    const table_base = machineOf(ab, table) | valid;
    hub(ab, CONTEXT0_PAGE_TABLE_BASE_ADDR_LO32).* = @truncate(table_base);
    hub(ab, CONTEXT0_PAGE_TABLE_BASE_ADDR_HI32).* = @truncate(table_base >> 32);
    const gart_end = gart_start + gart_bytes - 1;
    hub(ab, CONTEXT0_PAGE_TABLE_START_ADDR_LO32).* = @truncate(gart_start >> 12);
    hub(ab, CONTEXT0_PAGE_TABLE_START_ADDR_HI32).* = @truncate(gart_start >> 44);
    hub(ab, CONTEXT0_PAGE_TABLE_END_ADDR_LO32).* = @truncate(gart_end >> 12);
    hub(ab, CONTEXT0_PAGE_TABLE_END_ADDR_HI32).* = @truncate(gart_end >> 44);

    // The system aperture over the device's memory, no window onto the
    // machine's, and the pages strays and faults go to
    // (init_system_aperture_regs).
    const memory_end = ab.memory_device + ab.memory_bytes - 1;
    hub(ab, AGP_BASE).* = 0;
    hub(ab, AGP_BOT).* = 0xff_ffff;
    hub(ab, AGP_TOP).* = 0;
    hub(ab, SYSTEM_APERTURE_LOW_ADDR).* = @truncate(ab.memory_device >> 18);
    hub(ab, SYSTEM_APERTURE_HIGH_ADDR).* = @truncate(memory_end >> 18);
    const stray = machineOf(ab, scratch);
    hub(ab, SYSTEM_APERTURE_DEFAULT_ADDR_LSB).* = @truncate(stray >> 12);
    hub(ab, SYSTEM_APERTURE_DEFAULT_ADDR_MSB).* = @truncate(stray >> 44);
    hub(ab, L2_PROTECTION_FAULT_DEFAULT_ADDR_LO32).* = @truncate(stray >> 12);
    hub(ab, L2_PROTECTION_FAULT_DEFAULT_ADDR_HI32).* = @truncate(stray >> 44);
    hub(ab, L2_PROTECTION_FAULT_CNTL2).* |= ACTIVE_PAGE_MIGRATION_PTE_READ_RETRY | ENABLE_RETRY_FAULT_INTERRUPT;

    // The TLB (init_tlb_regs).
    var tlb = hub(ab, MX_L1_TLB_CNTL).*;
    tlb &= ~(SYSTEM_ACCESS_MODE_MASK | SYSTEM_APERTURE_UNMAPPED_ACCESS | ECO_BITS_MASK | MTYPE_MASK);
    tlb |= ENABLE_L1_TLB | SYSTEM_ACCESS_TRANSLATED << SYSTEM_ACCESS_MODE_SHIFT | ENABLE_ADVANCED_DRIVER_MODEL | MTYPE_UC << MTYPE_SHIFT;
    hub(ab, MX_L1_TLB_CNTL).* = tlb;

    // The L2 cache (init_cache_regs).
    var l2 = hub(ab, L2_CNTL).*;
    l2 &= ~(ENABLE_L2_FRAGMENT_PROCESSING | L2_PDE0_CACHE_TAG_GENERATION_MODE | PDE_FAULT_CLASSIFICATION |
        CONTEXT1_IDENTITY_ACCESS_MODE_MASK | IDENTITY_MODE_FRAGMENT_SIZE_MASK);
    l2 |= ENABLE_L2_CACHE | ENABLE_DEFAULT_PAGE_OUT_TO_SYSTEM_MEMORY | 1 << CONTEXT1_IDENTITY_ACCESS_MODE_SHIFT;
    hub(ab, L2_CNTL).* = l2;
    hub(ab, L2_CNTL2).* |= INVALIDATE_ALL_L1_TLBS | INVALIDATE_L2_CACHE;
    hub(ab, L2_CNTL3).* = L2_CNTL3_RESET & ~(BANK_SELECT_MASK | L2_CACHE_BIGK_FRAGMENT_SIZE_MASK) |
        BANK_SELECT | L2_CACHE_BIGK_FRAGMENT_SIZE << L2_CACHE_BIGK_FRAGMENT_SIZE_SHIFT;
    hub(ab, L2_CNTL4).* = L2_CNTL4_RESET & ~VMC_TAP_REQUEST_PHYSICAL;
    hub(ab, L2_CNTL5).* = L2_CNTL5_RESET & ~L2_CACHE_SMALLK_FRAGMENT_SIZE_MASK;

    // The first context on (enable_system_domain), the identity aperture
    // off, every invalidation engine over the whole range
    // (program_invalidation).
    var context = hub(ab, CONTEXT0_CNTL).*;
    context &= ~(PAGE_TABLE_DEPTH_MASK | RETRY_PERMISSION_OR_INVALID_PAGE_FAULT);
    hub(ab, CONTEXT0_CNTL).* = context | ENABLE_CONTEXT;
    hub(ab, L2_CONTEXT1_IDENTITY_APERTURE_LOW_ADDR_LO32).* = 0xffff_ffff;
    hub(ab, L2_CONTEXT1_IDENTITY_APERTURE_LOW_ADDR_HI32).* = 0x0000_000f;
    hub(ab, L2_CONTEXT1_IDENTITY_APERTURE_HIGH_ADDR_LO32).* = 0;
    hub(ab, L2_CONTEXT1_IDENTITY_APERTURE_HIGH_ADDR_HI32).* = 0;
    hub(ab, L2_CONTEXT_IDENTITY_PHYSICAL_OFFSET_LO32).* = 0;
    hub(ab, L2_CONTEXT_IDENTITY_PHYSICAL_OFFSET_HI32).* = 0;
    for (0..invalidate_engines) |engine| {
        const stride: u32 = @intCast(engine * invalidate_range_stride);
        hub(ab, INVALIDATE_ENG0_ADDR_RANGE_LO32 + stride).* = 0xffff_ffff;
        hub(ab, INVALIDATE_ENG0_ADDR_RANGE_HI32 + stride).* = 0x1f;
    }

    // Faults sent to the default page and the command processor not
    // halted on one (set_fault_enable_default), then the TLB dropped.
    at(ab, CP_DEBUG).* |= CPG_UTCL1_ERROR_HALT_DISABLE;
    var faults = hub(ab, L2_PROTECTION_FAULT_CNTL).*;
    faults &= ~CRASH_ON_FAULTS;
    hub(ab, L2_PROTECTION_FAULT_CNTL).* = faults | FAULT_ENABLE_DEFAULTS;
    if (!dropTlb(ab)) {
        gpu.FreeGPUMemory(&scratch);
        gpu.FreeGPUMemory(&table);
        return false;
    }
    ab.gart = table;
    ab.graphics_scratch = scratch;
    ab.gart_start = gart_start;
    ab.gart_bytes = gart_bytes;
    ab.gart_arena = .{ .start = 0, .end = gart_bytes };
    exec.kprintf(sys, "%s: the graphics hub is on: the device's memory 0x%lx-0x%lx through its aperture, its page table of %ldK at 0x%lx for 0x%lx-0x%lx\n", .{
        owner, ab.memory_device, memory_end, table_bytes / 1024, table.device, gart_start, gart_end,
    });
    return true;
}

/// The first context's TLB and L2 entries dropped through the hub's
/// seventeenth invalidation engine, the one the vendor's driver keeps for
/// it (gmc_v11_0_flush_gpu_tlb): true once the hub acknowledges it, said
/// on the raw port where it does not within 100 ms.
pub fn dropTlb(ab: *AMDGPUBase) bool {
    const sys = ab.sys_base;
    fence();
    hub(ab, INVALIDATE_ENG17_REQ).* = INVALIDATE_CONTEXT0;
    const until = sys.UptimeUs() + invalidate_most_us;
    while (hub(ab, INVALIDATE_ENG17_ACK).* & 1 == 0) {
        if (sys.UptimeUs() > until) {
            exec.kprintf(sys, "%s: the graphics hub does not acknowledge the TLB's invalidation\n", .{amdgpu.AMDGPUNAME});
            return false;
        }
    }
    return true;
}

/// The table's entry for the page of the machine's memory at `machine`.
pub fn entryOf(machine: u64) u64 {
    return machine & PTE_ADDRESS_MASK | system_page;
}

/// The pages a range of `bytes` at the machine's `machine` lies in: the
/// first one's address and how many.
pub const Pages = struct { first: u64, count: u64 };

pub fn pagesOf(machine: u64, bytes: u64) Pages {
    const first = machine & ~(page_bytes - 1);
    return .{ .first = first, .count = (machine + bytes - first + page_bytes - 1) / page_bytes };
}

/// The table's entries from the `index`th on, `count` of them: each page
/// of the machine's memory from `machine` on, one after another - or,
/// with `machine` null, taken out. The TLB is not dropped here.
pub fn writeEntries(ab: *AMDGPUBase, index: u64, count: u64, machine: ?u64) void {
    const entries: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(ab.gart.cpu)));
    var page: u64 = 0;
    while (page < count) : (page += 1) {
        entries[@intCast(index + page)] = if (machine) |first| entryOf(first + page * page_bytes) else 0;
    }
}

// --- tests --------------------------------------------------------------------------------

const testing = @import("std").testing;

test "the first context's range as the vendor places it" {
    try testing.expectEqual(@as(u64, 0x7fff_0000_0000), gart_start);
    try testing.expectEqual(@as(u64, 0x7fff_1fff_ffff), gart_start + gart_bytes - 1);
    try testing.expectEqual(@as(u64, 1024 * 1024), gart_bytes / page_bytes * entry_bytes);
}

test "a page of the machine's memory as the vendor maps one into its GART" {
    // Valid, system, snooped, executable, readable, writable, uncached.
    try testing.expectEqual(@as(u64, 0x0003_0001_2345_6077), entryOf(0x1_2345_6789));
    try testing.expectEqual(@as(u64, 0x0003_0000_0000_0077), entryOf(0));
}

test "the pages a range lies in" {
    try testing.expectEqual(Pages{ .first = 0x1000_0000, .count = 1 }, pagesOf(0x1000_0000, 4096));
    try testing.expectEqual(Pages{ .first = 0x1000_0000, .count = 2 }, pagesOf(0x1000_0ffc, 8));
    try testing.expectEqual(Pages{ .first = 0x1000_0000, .count = 1 }, pagesOf(0x1000_0ffc, 4));
    try testing.expectEqual(Pages{ .first = 0x1000_0000, .count = 17 }, pagesOf(0x1000_0064, 65536));
}

test "the hub's control words as the vendor writes them" {
    // Its TLB from the value it comes up with, 0x501.
    var tlb: u32 = 0x501;
    tlb &= ~(SYSTEM_ACCESS_MODE_MASK | SYSTEM_APERTURE_UNMAPPED_ACCESS | ECO_BITS_MASK | MTYPE_MASK);
    tlb |= ENABLE_L1_TLB | SYSTEM_ACCESS_TRANSLATED << SYSTEM_ACCESS_MODE_SHIFT | ENABLE_ADVANCED_DRIVER_MODEL | MTYPE_UC << MTYPE_SHIFT;
    try testing.expectEqual(@as(u32, 0x1859), tlb);
    try testing.expectEqual(@as(u32, 0x8014_800c), L2_CNTL3_RESET & ~(BANK_SELECT_MASK | L2_CACHE_BIGK_FRAGMENT_SIZE_MASK) |
        BANK_SELECT | L2_CACHE_BIGK_FRAGMENT_SIZE << L2_CACHE_BIGK_FRAGMENT_SIZE_SHIFT);
    try testing.expectEqual(@as(u32, 0x01), L2_CNTL4_RESET & ~VMC_TAP_REQUEST_PHYSICAL);
    try testing.expectEqual(@as(u32, 0x00f8_0001), INVALIDATE_CONTEXT0);
}
