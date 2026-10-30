// SPDX-License-Identifier: MIT
//! What the V3D can reach: its own MMU's page table, and the blocks mapped
//! in it.
//!
//! A table of 4 MiB covers 4 GiB in pages of 4 KiB, one word each. A block
//! comes from the memory DMA reaches, and its address on the V3D is the
//! same as its physical one; only what was allocated here is mapped, so a
//! wrong address in a control list is a fault the hub reports and not a
//! write to some other program's memory.
//!
//! The V3D does not see the CPU's caches. What the CPU wrote goes out with
//! `toGpu`, and what the V3D wrote is read after `fromGpu`.

const sdk = @import("sdk");
const exec = sdk.exec;
const hardware = sdk.hardware;
const ExecBase = sdk.interface.exec.ExecBase;
const regs = @import("regs.zig");
const Gpu = @import("gpu.zig").Gpu;

const page_bytes: u32 = 4096;
const table_bytes: u32 = 4 * 1024 * 1024;
const line_bytes: u32 = 64;
/// What the V3D's addresses reach, with each mapped to itself.
const reach_bytes: u64 = 1 << 32;
/// How long the MMU's caches are given to empty, as Linux gives them.
const flush_wait_us: u64 = 100_000;
/// The command list reader reads ahead of the list's end: a page past each
/// block is mapped too, part of it.
const read_ahead_bytes: u32 = page_bytes;

/// A block both sides can reach.
pub const Block = struct {
    memory: *anyopaque,
    memory_bytes: u32,
    cpu: [*]u8,
    /// Where the V3D has it.
    address: u32,
    bytes: u32,
};

pub const Space = struct {
    gpu: *const Gpu,
    sys: *ExecBase,
    table_memory: *anyopaque,
    table: [*]u32,
    /// Where a read of an unmapped page lands, while the fault is reported.
    scratch: Block,

    /// The table made and the MMU switched on: the V3D powered up first.
    pub fn open(gpu: *const Gpu) ?Space {
        const sys = gpu.sys;
        const memory = sys.AllocMem(2 * table_bytes, exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return null;
        const aligned = (@intFromPtr(memory) + table_bytes - 1) & ~@as(usize, table_bytes - 1);
        var space = Space{
            .gpu = gpu,
            .sys = sys,
            .table_memory = memory,
            .table = @ptrFromInt(aligned),
            .scratch = undefined,
        };
        toMemory(sys, aligned, table_bytes);
        space.scratch = space.alloc(page_bytes) orelse {
            sys.FreeMem(memory, 2 * table_bytes);
            return null;
        };
        gpu.hubWrite(regs.MMU_PT_PA_BASE, @intCast(aligned >> 12));
        gpu.hubWrite(regs.MMU_CTL, regs.MMU_CTL_ENABLE |
            regs.MMU_CTL_PT_INVALID_ENABLE |
            regs.MMU_CTL_PT_INVALID_ABORT |
            regs.MMU_CTL_PT_INVALID_INT |
            regs.MMU_CTL_WRITE_VIOLATION_ABORT |
            regs.MMU_CTL_WRITE_VIOLATION_INT |
            regs.MMU_CTL_CAP_EXCEEDED_ABORT |
            regs.MMU_CTL_CAP_EXCEEDED_INT);
        gpu.hubWrite(regs.MMU_ILLEGAL_ADDR, space.scratch.address >> 12 | regs.MMU_ILLEGAL_ADDR_ENABLE);
        gpu.hubWrite(regs.MMUC_CONTROL, regs.MMUC_CONTROL_ENABLE);
        if (!space.flush()) {
            space.free(&space.scratch);
            sys.FreeMem(memory, 2 * table_bytes);
            return null;
        }
        return space;
    }

    /// The MMU off and the table given back: the V3D idle, with nothing
    /// more to run until `open` gives it a table again.
    pub fn close(space: *Space) void {
        space.gpu.hubWrite(regs.MMU_CTL, 0);
        space.free(&space.scratch);
        space.sys.FreeMem(space.table_memory, 2 * table_bytes);
    }

    /// Whether the table's changes have reached the MMU.
    pub fn flush(space: *const Space) bool {
        const gpu = space.gpu;
        gpu.hubWrite(regs.MMUC_CONTROL, regs.MMUC_CONTROL_FLUSH | regs.MMUC_CONTROL_ENABLE);
        if (!gpu.waitHubClear(regs.MMUC_CONTROL, regs.MMUC_CONTROL_FLUSHING, flush_wait_us)) return false;
        gpu.hubWrite(regs.MMU_CTL, gpu.hubRead(regs.MMU_CTL) | regs.MMU_CTL_TLB_CLEAR);
        return gpu.waitHubClear(regs.MMU_CTL, regs.MMU_CTL_TLB_CLEARING, flush_wait_us);
    }

    /// A zeroed block of `bytes`, aligned to a page, in memory and mapped:
    /// `flush` before the V3D uses it.
    pub fn alloc(space: *Space, bytes: u32) ?Block {
        const sys = space.sys;
        const whole = (bytes + read_ahead_bytes + page_bytes - 1) & ~(page_bytes - 1);
        const memory_bytes = whole + page_bytes - 1;
        const memory = sys.AllocMem(memory_bytes, exec.MEMF_DMA | exec.MEMF_CLEAR) orelse return null;
        const aligned = (@intFromPtr(memory) + page_bytes - 1) & ~@as(usize, page_bytes - 1);
        const block = Block{
            .memory = memory,
            .memory_bytes = memory_bytes,
            .cpu = @ptrFromInt(aligned),
            .address = @intCast(aligned),
            .bytes = bytes,
        };
        // The clearing left its lines dirty: out with them now, or one
        // written back later would land on what the V3D wrote.
        toMemory(sys, aligned, whole);
        space.setPages(block.address, whole, regs.PTE_VALID | regs.PTE_WRITEABLE);
        return block;
    }

    pub fn free(space: *Space, block: *Block) void {
        const whole = (block.bytes + read_ahead_bytes + page_bytes - 1) & ~(page_bytes - 1);
        space.setPages(block.address, whole, 0);
        space.sys.FreeMem(block.memory, block.memory_bytes);
    }

    /// `bytes` of memory that is not a block of the space's mapped as well:
    /// where the V3D has them, or null past what it reaches. `flush` before
    /// the V3D uses them.
    pub fn map(space: *Space, address: usize, bytes: u64) ?u32 {
        const first = address & ~@as(usize, page_bytes - 1);
        const end = (address + @as(usize, @intCast(bytes)) + page_bytes - 1) & ~@as(usize, page_bytes - 1);
        if (end > reach_bytes) return null;
        space.setPages(@intCast(first), @intCast(end - first), regs.PTE_VALID | regs.PTE_WRITEABLE);
        return @intCast(address);
    }

    fn setPages(space: *Space, address: u32, bytes: u32, flags: u32) void {
        const first = address >> 12;
        const count = bytes >> 12;
        var page: u32 = 0;
        while (page < count) : (page += 1) {
            space.table[first + page] = if (flags == 0) 0 else flags | (first + page);
        }
        toMemory(space.sys, @intFromPtr(space.table) + first * 4, count * 4);
    }

    /// What the CPU wrote in `bytes` from `at` out to memory, for the V3D.
    pub fn rangeToGpu(space: *const Space, at: [*]const u8, bytes: usize) void {
        toMemory(space.sys, @intFromPtr(at), @intCast(bytes));
    }

    /// What the CPU's caches hold of `bytes` from `at` dropped, so it reads
    /// what the V3D wrote.
    pub fn rangeFromGpu(space: *const Space, at: [*]const u8, bytes: usize) void {
        const start = @intFromPtr(at) & ~@as(usize, line_bytes - 1);
        var length: u32 = wholeLines(@intFromPtr(at) + bytes - start);
        space.sys.CachePostDMA(@ptrFromInt(start), &length, 0);
    }

    /// What the CPU wrote in `block` out to memory, for the V3D.
    pub fn toGpu(space: *const Space, block: *const Block) void {
        toMemory(space.sys, @intFromPtr(block.cpu), block.bytes);
    }

    /// What the CPU's caches hold of `block` dropped, so it reads what the
    /// V3D wrote.
    pub fn fromGpu(space: *const Space, block: *const Block) void {
        const start = @intFromPtr(block.cpu) & ~@as(usize, line_bytes - 1);
        var bytes: u32 = wholeLines(@intFromPtr(block.cpu) + block.bytes - start);
        space.sys.CachePostDMA(@ptrFromInt(start), &bytes, 0);
    }
};

fn toMemory(sys: *ExecBase, address: usize, bytes: u32) void {
    const start = address & ~@as(usize, line_bytes - 1);
    var length: u32 = wholeLines(address + bytes - start);
    _ = sys.CachePreDMA(@ptrFromInt(start), &length, exec.DMAF_ReadFromRAM);
}

fn wholeLines(bytes: usize) u32 {
    return @intCast((bytes + line_bytes - 1) & ~@as(usize, line_bytes - 1));
}
