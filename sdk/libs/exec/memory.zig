// SPDX-License-Identifier: MIT
//! Memory (exec/memory.h): the MEMF_* attributes and requirements, memory
//! headers and memory handlers. A memory region carries its own MemHeader
//! at its start; the free space behind it is a chain of MemChunks.
//!
//!   base ────► ┌──────────────────────┐
//!              │ MemHeader            │  mh_Node (NT_MEMORY), mh_Attributes
//!              ├──────────────────────┤  mh_Lower = mh_First
//!              │ MemChunk: next, bytes│
//!              │ free ...             │
//!              └──────────────────────┘  mh_Upper

const std = @import("std");
const Node = @import("nodes.zig").Node;

/// Memory attributes and AllocMem requirements (MEMF_*).
///
/// Bits 0-15 describe a region and are matched against MemHeader.attributes,
/// which is 16 bits wide. Bits 16 and up are options for the one call.
///
/// Bits 0, 8 and 10 are left unassigned: they held attributes that said
/// nothing about this machine, and a program built before they went keeps
/// allocating because a bit no region carries is simply not matched.
pub const MEMF_ANY: u32 = 0;
/// Internal SRAM: no cache in the path, so it can be read and written while
/// the caches are suspended.
pub const MEMF_INTERNAL: u32 = 1 << 1;
/// PSRAM behind the data cache: the bulk of the memory, slower than internal
/// SRAM, and unusable while the caches are off.
pub const MEMF_EXTERNAL: u32 = 1 << 2;
/// A DMA engine addresses this memory directly: a descriptor chain may live
/// here, and a buffer in it needs no cache maintenance.
pub const MEMF_DMA: u32 = 1 << 9;
pub const MEMF_CLEAR: u32 = 1 << 16;
pub const MEMF_LARGEST: u32 = 1 << 17;
pub const MEMF_REVERSE: u32 = 1 << 18;
pub const MEMF_TOTAL: u32 = 1 << 19;
pub const MEMF_NO_EXPUNGE: u32 = 1 << 31;

/// struct MemChunk: a free block inside a MemHeader's region.
pub const MemChunk = extern struct {
    /// mc_Next: the next free chunk, in address order.
    next: ?*MemChunk = null,
    /// mc_Bytes: size of this free chunk.
    bytes: u32 = 0,
};

/// Allocation granularity: every chunk is a multiple of this and aligned to
/// it, so a free chunk always has room for its own MemChunk.
pub const MEM_BLOCKSIZE = @sizeOf(MemChunk);
pub const MEM_BLOCKMASK = MEM_BLOCKSIZE - 1;

/// struct MemHeader.
pub const MemHeader = extern struct {
    /// mh_Node: ln_Type NT_MEMORY, ln_Pri, ln_Name.
    node: Node = .{ .type = .memory },
    /// mh_Attributes: MEMF_* flags describing this region.
    attributes: u16 = 0,
    /// mh_First: first free chunk.
    first: ?*MemChunk = null,
    /// mh_Lower: lowest address the chunks can cover.
    lower: ?*anyopaque = null,
    /// mh_Upper: one past the highest address the chunks can cover.
    upper: ?*anyopaque = null,
    /// mh_Free: total free bytes.
    free: u32 = 0,

    pub fn name(mh: *const MemHeader) [:0]const u8 {
        return std.mem.span(mh.node.name orelse return "");
    }
};

/// struct MemHandlerData: what a memory handler is told about the failed
/// allocation.
pub const MemHandlerData = extern struct {
    /// memh_RequestSize
    request_size: u32,
    /// memh_RequestFlags: the AllocMem requirements.
    request_flags: u32,
    /// memh_Flags: MEMHF_RECYCLE when the same handler is called again.
    flags: u32,
};

pub const MEMHF_RECYCLE: u32 = 1 << 0;

/// Memory handler results.
pub const MEM_DID_NOTHING: i32 = 0;
/// Freed memory and can't free more: retry, then go on to the next handler.
pub const MEM_ALL_DONE: i32 = -1;
/// Freed memory and could free more: retry, and if that fails, call this
/// handler again with MEMHF_RECYCLE.
pub const MEM_TRY_AGAIN: i32 = 1;

/// is_Code of a memory handler; `is_data` is the Interrupt's is_Data.
pub const MemHandlerFn = *const fn (data: *const MemHandlerData, is_data: ?*anyopaque) callconv(.c) i32;
