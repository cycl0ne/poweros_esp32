// SPDX-License-Identifier: MIT
//! NVM Express as the controller has it (NVM Express Base Specification
//! 1.4): its registers in BAR 0, the 64-byte commands of a submission
//! queue and the 16-byte completions of a completion queue, the
//! commands' codes, and the fields of what Identify answers.
//!
//! **The registers.** CAP says what the controller can: its queues'
//! largest size, how far apart its doorbells are, how long it takes to
//! become ready, the memory page sizes it takes. CC is what it is told -
//! on, its page size, the sizes of its queues' entries - and CSTS what it
//! says back: ready, or failed. AQA, ASQ and ACQ are the admin queues.
//! The doorbells start at 0x1000: each queue's tail (a submission queue)
//! or head (a completion queue), `4 << CAP.DSTRD` bytes apart.
//!
//! **A completion** carries the command's identifier, the submission
//! queue's head as the controller has read it, its status, and the phase
//! bit: the controller flips what it writes there each time round the
//! queue, so an entry whose phase is the one expected is new.

const std = @import("std");

pub const CAP: usize = 0x00;
pub const VS: usize = 0x08;
/// VS as NVMe 1.1 has it: major in bits 31:16, minor in 15:8.
pub const VS_1_1: u32 = 0x0001_0100;
/// Interrupt mask set and clear: the vectors held back, for a function
/// on INTx or MSI - never with MSI-X.
pub const INTMS: usize = 0x0C;
pub const INTMC: usize = 0x10;
pub const CC: usize = 0x14;
pub const CSTS: usize = 0x1C;
pub const AQA: usize = 0x24;
pub const ASQ: usize = 0x28;
pub const ACQ: usize = 0x30;
pub const doorbells: usize = 0x1000;

/// CAP's fields.
pub fn maxEntries(cap: u64) u32 {
    return @as(u32, @truncate(cap & 0xFFFF)) + 1;
}
pub fn doorbellStride(cap: u64) u32 {
    return @as(u32, 4) << @intCast((cap >> 32) & 0xF);
}
/// How long the controller may take to become ready, or not ready, in
/// milliseconds.
pub fn readyMs(cap: u64) u32 {
    return @as(u32, @truncate((cap >> 24) & 0xFF)) * 500;
}
/// Whether the NVM command set is among those it speaks.
pub fn speaksNvm(cap: u64) bool {
    return (cap >> 37) & 1 != 0;
}
/// Its smallest memory page, as a power of two past 4 KiB.
pub fn minPageShift(cap: u64) u4 {
    return @truncate((cap >> 48) & 0xF);
}

pub const CC_EN: u32 = 1 << 0;
/// The sizes of a submission and a completion queue's entries, as powers
/// of two: 64 and 16 bytes.
pub const CC_IOSQES: u32 = 6 << 16;
pub const CC_IOCQES: u32 = 4 << 20;
/// Normal shutdown notification.
pub const CC_SHN_NORMAL: u32 = 1 << 14;
pub const CC_SHN_MASK: u32 = 3 << 14;

pub const CSTS_RDY: u32 = 1 << 0;
pub const CSTS_CFS: u32 = 1 << 1;
pub const CSTS_SHST_MASK: u32 = 3 << 2;
pub const CSTS_SHST_DONE: u32 = 2 << 2;

/// Where queue `id`'s tail doorbell is (a submission queue), and its
/// head doorbell (a completion queue).
pub fn tailDoorbell(id: u16, stride: u32) usize {
    return doorbells + @as(usize, 2 * @as(u32, id)) * stride;
}
pub fn headDoorbell(id: u16, stride: u32) usize {
    return doorbells + @as(usize, 2 * @as(u32, id) + 1) * stride;
}

/// A submission queue's entry.
pub const Command = extern struct {
    /// The opcode, and the identifier its completion carries back.
    opcode: u8 = 0,
    flags: u8 = 0,
    id: u16 = 0,
    nsid: u32 = 0,
    reserved: [2]u32 = .{ 0, 0 },
    metadata: u64 align(4) = 0,
    /// The data's two PRP entries: its first page, and its second or the
    /// list of the rest.
    prp1: u64 align(4) = 0,
    prp2: u64 align(4) = 0,
    cdw10: u32 = 0,
    cdw11: u32 = 0,
    cdw12: u32 = 0,
    cdw13: u32 = 0,
    cdw14: u32 = 0,
    cdw15: u32 = 0,
};

/// A completion queue's entry.
pub const Completion = extern struct {
    /// What the command answers, for the few that answer anything.
    result: u32,
    reserved: u32,
    sq_head: u16,
    sq_id: u16,
    id: u16,
    /// The phase in bit 0, the status above it.
    status: u16,

    pub fn phase(c: Completion) u1 {
        return @truncate(c.status);
    }

    /// The status without the phase: 0 for success.
    pub fn code(c: Completion) u15 {
        return @truncate(c.status >> 1);
    }
};

comptime {
    std.debug.assert(@sizeOf(Command) == 64);
    std.debug.assert(@sizeOf(Completion) == 16);
    std.debug.assert(@sizeOf(Range) == 16);
}

/// A status's code and its type.
pub fn statusCode(status: u15) u8 {
    return @truncate(status);
}
pub fn statusType(status: u15) u3 {
    return @truncate(status >> 8);
}

/// The generic status codes the device tells apart: past the
/// namespace's end, and a namespace that is write-protected.
pub const SCT_GENERIC: u3 = 0;
pub const SC_LBA_RANGE: u8 = 0x80;
pub const SC_WRITE_PROTECTED: u8 = 0x20;

// Admin commands.
pub const ADMIN_DELETE_SQ: u8 = 0x00;
pub const ADMIN_CREATE_SQ: u8 = 0x01;
pub const ADMIN_DELETE_CQ: u8 = 0x04;
pub const ADMIN_CREATE_CQ: u8 = 0x05;
pub const ADMIN_IDENTIFY: u8 = 0x06;
pub const ADMIN_SET_FEATURES: u8 = 0x09;

// NVM commands.
pub const NVM_FLUSH: u8 = 0x00;
pub const NVM_WRITE: u8 = 0x01;
pub const NVM_READ: u8 = 0x02;
pub const NVM_DATASET_MANAGEMENT: u8 = 0x09;

/// Dataset Management's CDW11: its ranges deallocated.
pub const DSM_DEALLOCATE: u32 = 1 << 2;

/// One range of Dataset Management's list: `blocks` from `lba`.
pub const Range = extern struct {
    attributes: u32 = 0,
    blocks: u32,
    lba: u64,
};

/// Identify's CNS: a namespace, the controller, the active namespaces.
pub const CNS_NAMESPACE: u32 = 0x00;
pub const CNS_CONTROLLER: u32 = 0x01;
pub const CNS_ACTIVE_NAMESPACES: u32 = 0x02;
/// What the controller says of itself for the NVM command set (CSI 0,
/// CDW11's top byte).
pub const CNS_CONTROLLER_NVM: u32 = 0x06;

/// Set Features: the number of queues.
pub const FEATURE_QUEUES: u32 = 0x07;

/// Create I/O Completion Queue's and Submission Queue's CDW11: the queue
/// is in one piece, its interrupt is on.
pub const QUEUE_CONTIGUOUS: u32 = 1 << 0;
pub const CQ_INTERRUPTS: u32 = 1 << 1;

// --- Identify --------------------------------------------------------------------------

/// What the controller says of itself (CNS 1), the fields the device
/// uses.
pub const ControllerInfo = struct {
    vendor: u16,
    serial: [20]u8,
    model: [40]u8,
    firmware: [8]u8,
    /// The most one command moves, as a power of two of the smallest
    /// memory page; 0 for no limit.
    mdts: u8,
    /// Its namespaces' highest ID.
    namespaces: u32,
    /// It has a volatile write cache: Flush is what puts it on the
    /// medium.
    volatile_cache: bool,
    /// It has Dataset Management (ONCS bit 2): blocks can be deallocated.
    dataset_management: bool,

    pub fn of(page: *const [4096]u8) ControllerInfo {
        return .{
            .vendor = std.mem.readInt(u16, page[0..2], .little),
            .serial = page[4..24].*,
            .model = page[24..64].*,
            .firmware = page[64..72].*,
            .mdts = page[77],
            .namespaces = std.mem.readInt(u32, page[516..520], .little),
            .volatile_cache = page[525] & 1 != 0,
            .dataset_management = page[520] & 1 << 2 != 0,
        };
    }
};

/// What a namespace says of itself (CNS 0), the fields the device uses.
pub const NamespaceInfo = struct {
    /// Its blocks.
    blocks: u64,
    /// Its block size as a power of two, and the metadata each block
    /// carries.
    block_shift: u8,
    metadata: u16,
    /// What a deallocated block reads as (DLFEAT's low bits): 1 zeroes,
    /// 2 bytes of 0xFF, 0 where it does not say.
    deallocated: u3,

    pub fn of(page: *const [4096]u8) NamespaceInfo {
        const formats = page[25];
        const flbas = page[26];
        // The format's index: four bits, and two more above the extended
        // bit where there are more than 16 formats.
        var index: usize = flbas & 0xF;
        if (formats >= 16) index |= @as(usize, (flbas >> 5) & 3) << 4;
        const format = page[128 + index * 4 ..][0..4];
        return .{
            .blocks = std.mem.readInt(u64, page[0..8], .little),
            .block_shift = format[2],
            .metadata = std.mem.readInt(u16, format[0..2], .little),
            .deallocated = @truncate(page[33]),
        };
    }
};

/// What Dataset Management takes at most (CNS 6), 0 where there is no
/// limit: the ranges of one command, the blocks of one range, the blocks
/// of one command.
pub const NvmLimits = struct {
    ranges: u8 = 0,
    range_blocks: u32 = 0,
    blocks: u64 = 0,

    pub fn of(page: *const [4096]u8) NvmLimits {
        return .{
            .ranges = page[3],
            .range_blocks = std.mem.readInt(u32, page[4..8], .little),
            .blocks = std.mem.readInt(u64, page[8..16], .little),
        };
    }
};

/// A text field of Identify: ASCII, padded with spaces at its end.
pub fn trimmed(field: []const u8) []const u8 {
    return std.mem.trimEnd(u8, field, " \x00");
}
