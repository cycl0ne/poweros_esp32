// SPDX-License-Identifier: MPL-2.0
//! posfs's compressed data: a file's bytes in chunks of 64 KiB, each one
//! compressed with LZ4 on its own and stored in as few blocks as its
//! compressed bytes take, with a crc over those bytes.
//!
//! A chunk is compressed when it is written whole - every block of it, up
//! to the file's end, in memory at once - and only when that saves a
//! block; any other data is stored as it is. A compressed chunk is never
//! written over in part: a write into one takes the whole chunk back into
//! memory, and the next write of it is the whole chunk again.
//!
//! The crc is checked before a chunk is decoded, so a damaged chunk is
//! `BadChecksum` and never the decoder's guess; the decoder checks every
//! length besides. The chunk decoded last is kept, so reading a chunk in
//! small pieces decodes it once. The buffers - the chunk as the file has
//! it, its compressed bytes, the compressor's table - are allocated the
//! first time a chunk is written or read, and given back with the
//! volume's memory.

const sdk = @import("sdk");
const lz4 = sdk.lz4;
const layout = sdk.dos.posfs.layout;
const volume = @import("volume.zig");
const Volume = volume.Volume;
const Error = volume.Error;
const no_block = volume.no_block;

pub const chunk_size = layout.chunk_size;

/// The buffers, and which chunk `plain` holds decoded.
pub const Chunks = struct {
    work: []u8 = &.{},
    /// A chunk's bytes as the file has them.
    plain: []u8 = &.{},
    /// A chunk's compressed bytes, in whole blocks.
    packed_bytes: []u8 = &.{},
    /// The blocks of the chunk `plain` holds decoded, `no_block` for none,
    /// and how many bytes it decoded to.
    plain_block: u64 = no_block,
    plain_blocks: u64 = 0,
    plain_len: usize = 0,
};

/// A compressed chunk on the medium.
pub const Stored = struct { block: u64, blocks: u64, stored: u32, crc: u32 };

/// A chunk compressed: its blocks' bytes, the last one's tail cleared,
/// how many of them count, and their crc.
pub const Packed = struct { bytes: []const u8, stored: u32, crc: u32 };

fn ready(vol: *Volume) Error!*Chunks {
    const chunks = &vol.chunks;
    if (chunks.plain.len == 0) chunks.plain = try vol.alloc(chunk_size);
    if (chunks.packed_bytes.len == 0) {
        const mask: usize = vol.block_size - 1;
        chunks.packed_bytes = try vol.alloc((lz4.bound(chunk_size) + mask) & ~mask);
    }
    return chunks;
}

/// Every buffer given back.
pub fn release(vol: *Volume) void {
    const chunks = &vol.chunks;
    vol.free(chunks.work);
    vol.free(chunks.plain);
    vol.free(chunks.packed_bytes);
    chunks.* = .{};
}

/// Blocks [addr, addr + count) being written: a decoded chunk of them is
/// no longer theirs.
pub fn forget(vol: *Volume, addr: u64, count: u64) void {
    const chunks = &vol.chunks;
    if (chunks.plain_block == no_block) return;
    if (chunks.plain_block < addr + count and addr < chunks.plain_block + chunks.plain_blocks) chunks.plain_block = no_block;
}

/// The chunk `at` holds, decoded: at least `need` bytes. Damage is
/// BadChecksum when the crc does not match, Corrupt when it does and the
/// bytes still do not decode.
pub fn read(vol: *Volume, at: Stored, need: u64) Error![]const u8 {
    const chunks = try ready(vol);
    if (chunks.plain_block == at.block and chunks.plain_blocks == at.blocks) {
        if (chunks.plain_len < need) return error.Corrupt;
        return chunks.plain[0..chunks.plain_len];
    }
    if (at.block >= vol.block_count or at.blocks > vol.block_count - at.block) return error.Corrupt;
    const len = at.blocks << vol.block_shift;
    if (at.stored == 0 or at.stored > len or len > chunks.packed_bytes.len) return error.Corrupt;
    const bytes: []const u8 = if (vol.map) |base| blk: {
        const first: usize = @intCast(vol.byteOf(at.block));
        break :blk base[first..][0..at.stored];
    } else blk: {
        try vol.readBlocks(at.block, chunks.packed_bytes[0..@intCast(len)]);
        break :blk chunks.packed_bytes[0..at.stored];
    };
    if (layout.crcSeeded(&vol.uuid, bytes) != at.crc) return error.BadChecksum;
    chunks.plain_block = no_block;
    const decoded = lz4.decompress(bytes, chunks.plain) orelse return error.Corrupt;
    if (decoded < need) return error.Corrupt;
    chunks.plain_block = at.block;
    chunks.plain_blocks = at.blocks;
    chunks.plain_len = decoded;
    return chunks.plain[0..decoded];
}

/// The buffer a chunk is put together in for `pack`: what it held decoded
/// is forgotten.
pub fn assembly(vol: *Volume) Error![]u8 {
    const chunks = try ready(vol);
    chunks.plain_block = no_block;
    return chunks.plain;
}

/// `plain` compressed into whole blocks: null when that does not save at
/// least one of the blocks `plain` takes.
pub fn pack(vol: *Volume, plain: []const u8) Error!?Packed {
    const chunks = try ready(vol);
    if (chunks.work.len == 0) chunks.work = try vol.alloc(@sizeOf(lz4.Work));
    const work: *lz4.Work = @ptrCast(@alignCast(chunks.work.ptr));
    const len = lz4.compress(plain, chunks.packed_bytes, work) orelse return null;
    const size: usize = vol.block_size;
    const blocks = (len + size - 1) / size;
    const raw_blocks = (plain.len + size - 1) / size;
    if (blocks + 1 > raw_blocks) return null;
    const end = blocks * size;
    @memset(chunks.packed_bytes[len..end], 0);
    return .{
        .bytes = chunks.packed_bytes[0..end],
        .stored = @intCast(len),
        .crc = layout.crcSeeded(&vol.uuid, chunks.packed_bytes[0..len]),
    };
}
