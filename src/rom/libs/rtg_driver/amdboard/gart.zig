// SPDX-License-Identifier: MPL-2.0
//! The display engine's own page table onto the machine's memory: what
//! lets a fetcher read a buffer of the machine's RAM - a program's
//! picture - where it reaches the device's memory alone otherwise.
//!
//! **A fetcher's addresses** are the device's memory where they fall in
//! its system aperture, set to that memory, and are looked up in the
//! engine's first page-table context everywhere else: its translation
//! buffer on, in system access mode 3, as the vendor sets every pipe
//! (hubp21_set_vm_system_aperture_settings). The device's memory reads
//! the same in that mode as without it, so the picture, the cursor and
//! the overlay read on as before.
//!
//! **The context** is one flat table in the device's memory: an 8-byte
//! entry for each 4 KiB page of a window at the top of the device's
//! 48-bit addresses, 512 MiB, the vendor's own window there
//! (gmc_v11_0_vram_gtt_location, AMDGPU_GART_PLACEMENT_HIGH). The
//! engine is told where the table is in the machine, its valid bit set,
//! and the window's first and last page, with no level above the table
//! (hubbub31_init_dchub_sys_ctx, dcn20_vmid_setup: depth 0, block size
//! 0), its fifteenth context the same. An entry is a page's machine
//! address, marked valid, the machine's memory, readable, writable and
//! uncached in the device, and snooped: the engine's reads then see what
//! the CPU's caches hold, so nothing is written back before a buffer is
//! read. On the NucBox a cached store not written back was on the glass
//! at the next frame with the entry snooped, and not before it was
//! written back without. The device's AGP window, which the vendor leaves
//! off on this graphics generation, reads nothing there.
//!
//! **A buffer is mapped** as it is first to be read (`map`): a run of
//! the window's pages for the run of the machine's pages it lies in, as
//! exec's CachePreDMA names them - a buffer is one run of the machine's
//! addresses - kept for the next time those pages are asked for. A new
//! run goes where the last one ended, round the window, and takes the
//! place of the runs it lands on, past any a fetcher reads: a run's
//! pages are written again only once the window has gone round, long
//! after any fetcher last read them.

const sdk = @import("sdk");
const exec = sdk.exec;
const amdgpu = sdk.resources.amdgpu;
const reg = sdk.hardware.mmio.reg;
const dcn = @import("dcn.zig");

// --- the registers, in 32-bit words from the engine's third address ---------------

/// Where the device's memory is to the engine, and where it is in the
/// machine, each counted in 16 MiB, as the firmware set them.
const fb_location_base = 0x0475;
const fb_offset = 0x0477;
const fb_shift = 24;
const fb_mask: u32 = 0xff_ffff;
/// The device's memory in the device's addresses: as large as the
/// location's top says, counted in 16 MiB.
const fb_location_top = 0x0476;

/// A page-table context's control, its table's machine address, and its
/// window's first and last page, each high word first; a context's
/// registers lie seven words apart.
const context_control = 0x0559;
const context_base_high = 0x055a;
const context_base_low = 0x055b;
const context_start_high = 0x055c;
const context_start_low = 0x055d;
const context_end_high = 0x055e;
const context_end_low = 0x055f;
const context_stride = 7;
/// The contexts the vendor tells the table: the first, which every
/// fetcher looks in, and the fifteenth.
const contexts = [_]u32{ 0, 15 };
/// The table's address with its valid bit, which the engine is waited
/// for to read back as it took the context.
const table_valid: u32 = 1 << 0;
const context_wait_us: u64 = 50_000;

/// A fetcher's system aperture, its first and last address counted in
/// 256 KiB, and its translation buffer's control: on, in system access
/// mode 3. A fetcher's registers lie a stride apart.
const aperture_low = 0x0635;
const aperture_high = 0x0636;
const tlb_control = 0x0643;
const aperture_shift = 18;
const tlb_on: u32 = 1 << 0 | 3 << 3;
const hubp_stride = 0xdc;

// --- the table -------------------------------------------------------------------

/// The window: its pages, its first page in the device's addresses - the
/// top of the 48 bits less the window - and the table's room.
pub const window_pages: u32 = 128 * 1024;
const page_shift = 12;
const page_bytes: u64 = 1 << page_shift;
const window_first_page: u64 = (@as(u64, 1) << (48 - page_shift)) - window_pages;
const table_bytes: u32 = window_pages * 8;

/// An entry: valid, the machine's memory, snooped, executable, readable
/// and writable, and the device's memory type uncached in its bits 48 to
/// 50 - the vendor's for a page of the machine's memory the CPU caches
/// (amdgpu_ttm_tt_pte_flags, gmc_v11_0_gart_init).
const entry_flags: u64 = 1 << 0 | 1 << 1 | 1 << 2 | 1 << 4 | 1 << 5 | 1 << 6 | 3 << 48;

/// How many runs are kept.
pub const run_count = 16;

/// A run of the window's pages: the first of the machine's pages it
/// maps and how many, the first of the window's, and when it was last
/// asked for. No pages: none.
pub const Run = struct {
    machine_page: u64 = 0,
    pages: u32 = 0,
    first: u32 = 0,
    used: u32 = 0,
};

/// The table: the device's memory it is in and that memory's address in
/// the machine; the next of the window's pages a run goes to; the runs,
/// and how many times one has been asked for.
pub const Table = struct {
    memory: amdgpu.GPUMemory,
    machine: u64,
    next: u32 = 0,
    asked: u32 = 0,
    runs: [run_count]Run = [_]Run{.{}} ** run_count,
};

fn at(engine: dcn.Engine, offset: u32) *volatile u32 {
    return reg(engine.registers + (@as(usize, engine.block) + offset) * 4);
}

/// Where `device` - an address in the device's memory - is in the
/// machine, as the engine has the two.
fn machineOf(engine: dcn.Engine, device: u64) u64 {
    const base = @as(u64, at(engine, fb_location_base).* & fb_mask) << fb_shift;
    const offset = @as(u64, at(engine, fb_offset).* & fb_mask) << fb_shift;
    return device - base + offset;
}

/// The table made and the engine's contexts told it, every entry clear:
/// null where there is no room in the device's memory for it.
pub fn open(engine: dcn.Engine) ?Table {
    var memory: amdgpu.GPUMemory = .{};
    if (!engine.gpu.AllocGPUMemory(table_bytes, @intCast(page_bytes), &memory)) return null;
    const entries: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(memory.cpu)));
    for (0..window_pages) |index| entries[index] = 0;
    sdk.hardware.barrier.full();
    const table: Table = .{ .memory = memory, .machine = machineOf(engine, memory.device) };
    const last_page = window_first_page + window_pages - 1;
    for (contexts) |context| {
        const offset = context * context_stride;
        at(engine, offset + context_start_high).* = @truncate(window_first_page >> 32 & 0xf);
        at(engine, offset + context_start_low).* = @truncate(window_first_page);
        at(engine, offset + context_end_high).* = @truncate(last_page >> 32 & 0xf);
        at(engine, offset + context_end_low).* = @truncate(last_page);
        at(engine, offset + context_control).* = 0;
        at(engine, offset + context_base_high).* = @truncate(table.machine >> 32);
        // The low word last, as the engine takes the context by it.
        const low = at(engine, offset + context_base_low);
        low.* = @as(u32, @truncate(table.machine)) | table_valid;
        const deadline = engine.sys.UptimeUs() + context_wait_us;
        while (low.* & table_valid == 0 and engine.sys.UptimeUs() < deadline) {}
    }
    return table;
}

/// The contexts cleared and the table given back, once no fetcher reads
/// a buffer through it.
pub fn close(engine: dcn.Engine, table: *Table) void {
    for (contexts) |context| {
        const offset = context * context_stride;
        at(engine, offset + context_base_low).* = 0;
        at(engine, offset + context_base_high).* = 0;
        at(engine, offset + context_start_low).* = 0;
        at(engine, offset + context_start_high).* = 0;
        at(engine, offset + context_end_low).* = 0;
        at(engine, offset + context_end_high).* = 0;
    }
    engine.gpu.FreeGPUMemory(&table.memory);
}

/// Fetcher `fetcher`'s addresses the device's memory in its system
/// aperture and the table's everywhere else.
pub fn reach(engine: dcn.Engine, fetcher: u32) void {
    const base = @as(u64, at(engine, fb_location_base).* & fb_mask) << fb_shift;
    const top = @as(u64, at(engine, fb_location_top).* & fb_mask) << fb_shift | ((@as(u64, 1) << fb_shift) - 1);
    const hubp = fetcher * hubp_stride;
    at(engine, hubp + aperture_low).* = @truncate(base >> aperture_shift);
    at(engine, hubp + aperture_high).* = @truncate(top >> aperture_shift);
    at(engine, hubp + tlb_control).* = tlb_on;
}

/// The device's address a fetcher reads `bytes` at the machine's
/// `machine` by, its pages mapped where they are not yet: null where
/// they are more than the window holds. `busy` are device addresses
/// fetchers read now, whose runs stay as they are.
pub fn map(table: *Table, machine: u64, bytes: u64, busy: []const u64) ?u64 {
    if (bytes == 0) return null;
    const first_page = machine >> page_shift;
    const last_page = (machine + bytes - 1) >> page_shift;
    const pages = last_page - first_page + 1;
    if (pages > window_pages) return null;
    const count: u32 = @intCast(pages);
    table.asked +%= 1;
    for (&table.runs) |*run| {
        if (run.pages != 0 and first_page >= run.machine_page and last_page < run.machine_page + run.pages) {
            run.used = table.asked;
            return windowAddress(run.first + @as(u32, @intCast(first_page - run.machine_page))) + (machine & (page_bytes - 1));
        }
    }
    const first = place(table, count, busy) orelse return null;
    // The runs it lands on are given up.
    for (&table.runs) |*run| {
        if (run.pages != 0 and overlaps(run.first, run.pages, first, count)) run.* = .{};
    }
    const entries: [*]volatile u64 = @ptrFromInt(@as(usize, @intCast(table.memory.cpu)));
    for (0..count) |index| entries[first + index] = (first_page + index) << page_shift | entry_flags;
    sdk.hardware.barrier.full();
    const slot = freeSlot(table);
    slot.* = .{ .machine_page = first_page, .pages = count, .first = first, .used = table.asked };
    table.next = first + count;
    return windowAddress(first) + (machine & (page_bytes - 1));
}

/// Where in the window a run of `count` pages goes: from the next page
/// on, round to the window's start where it does not fit before its
/// end, and past any run a fetcher reads; null where no place is left.
fn place(table: *const Table, count: u32, busy: []const u64) ?u32 {
    var first = table.next;
    var tries: u32 = 0;
    while (tries <= run_count + 1) : (tries += 1) {
        if (first + count > window_pages) first = 0;
        const read = readRun(table, first, count, busy) orelse return first;
        first = read.first + read.pages;
    }
    return null;
}

/// The run a fetcher reads that `count` pages from `first` on land on.
fn readRun(table: *const Table, first: u32, count: u32, busy: []const u64) ?Run {
    for (table.runs) |run| {
        if (run.pages == 0 or !overlaps(run.first, run.pages, first, count)) continue;
        for (busy) |address| {
            if (address < windowAddress(0)) continue;
            const page = (address - windowAddress(0)) >> page_shift;
            if (page >= run.first and page < run.first + run.pages) return run;
        }
    }
    return null;
}

fn overlaps(first: u32, pages: u32, other_first: u32, other_pages: u32) bool {
    return first < other_first + other_pages and other_first < first + pages;
}

/// A run's place in the list for a new one: an empty one, else the one
/// asked for least lately.
fn freeSlot(table: *Table) *Run {
    var oldest = &table.runs[0];
    for (&table.runs) |*run| {
        if (run.pages == 0) return run;
        if (table.asked -% run.used > table.asked -% oldest.used) oldest = run;
    }
    return oldest;
}

/// The device's address of the window's page `page`.
fn windowAddress(page: u32) u64 {
    return (window_first_page + page) << page_shift;
}

/// Whether a device address is one of the window's.
pub fn inWindow(address: u64) bool {
    return address >= windowAddress(0);
}

const testing = @import("std").testing;

fn testTable() Table {
    return .{ .memory = .{}, .machine = 0 };
}

test "a buffer's run: placed in turn, found again, given up to the next run that lands on it" {
    // The table's entries are not written here: only where runs go.
    var table = testTable();
    const none = [_]u64{};
    const first = place(&table, 10, &none).?;
    try testing.expectEqual(@as(u32, 0), first);
    table.runs[0] = .{ .machine_page = 0x1000, .pages = 10, .first = 0, .used = 1 };
    table.next = 10;
    // The next run from where the last ended.
    try testing.expectEqual(@as(u32, 10), place(&table, 5, &none).?);
    // At the window's end, round to its start - past the run read there.
    table.next = window_pages - 3;
    try testing.expectEqual(@as(u32, 0), place(&table, 5, &none).?);
    const read = [_]u64{windowAddress(4)};
    try testing.expectEqual(@as(u32, 10), place(&table, 5, &read).?);
}

test "a run's window addresses: the page's offset kept, the window at the top of 48 bits" {
    try testing.expectEqual(@as(u64, 0xFFFF_E000_0000), windowAddress(0));
    try testing.expect(inWindow(0xFFFF_E000_0000));
    try testing.expect(!inWindow(0x80_0402_6000));
    try testing.expectEqual(@as(u64, 0xFFFF_FFFF_F000), windowAddress(window_pages - 1));
}

test "the least lately asked run is the one a new run takes the place of in the list" {
    var table = testTable();
    for (&table.runs, 0..) |*run, index| run.* = .{ .machine_page = index, .pages = 1, .first = @intCast(index), .used = @intCast(index + 1) };
    table.asked = 20;
    table.runs[5].used = 0;
    try testing.expectEqual(&table.runs[5], freeSlot(&table));
}
