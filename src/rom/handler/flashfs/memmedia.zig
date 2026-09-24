// SPDX-License-Identifier: MPL-2.0
//! A medium in memory that behaves like flash, for the host tests: a write
//! can only clear bits, and only an erase sets a whole sector back to ones.
//! The tests check the format itself against it, and `cut` cuts the power
//! in the middle of a write to see what mounting makes of the result.

const std = @import("std");
const dos = @import("sdk").dos;

pub const MemMedia = struct {
    bytes_: []u8,
    sector: u32,
    page: u32,
    /// Counters the tests look at.
    erases: u32 = 0,
    writes: u32 = 0,
    /// After this many more bytes written, every further write is dropped:
    /// the power went. 0 means none is.
    budget: ?u32 = null,
    /// Whether the medium can be read as memory, like flash.device's
    /// mapping. Both paths are exercised.
    direct: bool = true,
    live: usize = 0,
    clock: u32 = 0,

    pub fn init(bytes_: []u8, sector: u32, page: u32) MemMedia {
        @memset(bytes_, 0xFF);
        return .{ .bytes_ = bytes_, .sector = sector, .page = page };
    }

    /// Eight-byte aligned, as exec's AllocVec is: the file system puts
    /// structures with 64-bit fields in these blocks.
    pub fn alloc(m: *MemMedia, bytes_wanted: u32) ?[]u8 {
        const block = std.testing.allocator.alignedAlloc(u8, .@"8", bytes_wanted) catch return null;
        m.live += 1;
        return block;
    }

    pub fn free(m: *MemMedia, block: []u8) void {
        m.live -= 1;
        const aligned: []align(8) u8 = @alignCast(block);
        std.testing.allocator.free(aligned);
    }

    /// The clock a new file is dated with: it ticks once per call, so a
    /// test can tell one date from another.
    pub fn now(m: *MemMedia) dos.DateStamp {
        m.clock += 1;
        return .{ .days = 1, .minute = 2, .tick = @intCast(m.clock) };
    }

    pub fn size(m: *MemMedia) u32 {
        return @intCast(m.bytes_.len);
    }

    pub fn sectorSize(m: *MemMedia) u32 {
        return m.sector;
    }

    pub fn pageSize(m: *MemMedia) u32 {
        return m.page;
    }

    pub fn bytes(m: *MemMedia) ?[]const u8 {
        return if (m.direct) m.bytes_ else null;
    }

    pub fn read(m: *MemMedia, at: u32, into: []u8) bool {
        if (at + into.len > m.bytes_.len) return false;
        @memcpy(into, m.bytes_[at..][0..into.len]);
        return true;
    }

    /// Programming clears bits; it never sets one. A write that starts or
    /// ends inside a page is fine, but the volume never programs a page
    /// twice, and `programmed` checks that it doesn't.
    pub fn write(m: *MemMedia, at: u32, from: []const u8) bool {
        if (at + from.len > m.bytes_.len) return false;
        if (m.page != 0 and at % m.page != 0) return false;
        m.writes += 1;
        for (from, 0..) |b, i| {
            if (m.budget) |*left| {
                if (left.* == 0) return true; // the power went mid-write
                left.* -= 1;
            }
            m.bytes_[at + i] &= b;
        }
        return true;
    }

    pub fn erase(m: *MemMedia, at: u32, len: u32) bool {
        if (at % m.sector != 0 or len % m.sector != 0 or at + len > m.bytes_.len) return false;
        m.erases += 1;
        @memset(m.bytes_[at..][0..len], 0xFF);
        return true;
    }
};
