// SPDX-License-Identifier: MPL-2.0
//! Media in memory for the host tests, in three personalities, each
//! failing the way its kind of medium fails when the power goes.
//!
//! - **flash**: a write only clears bits and an erase sets a whole sector
//!   back to ones. A page programmed twice between erases is counted
//!   (`twice`), which the tests insist stays 0. A cut during an erase
//!   leaves the sector reading as ones but weak: what is programmed into
//!   it later comes out with bits wrong, until it is erased in full.
//! - **sd**: a write puts down whole sectors. A cut turns the sector being
//!   written into garbage; the sectors before it are written, the ones
//!   after are not.
//! - **usb**: writes go into the stick's own cache and reach the medium
//!   in an order of the stick's choosing - all of them on `update`. A cut
//!   loses what the cache still held, some of it put down and some not;
//!   so does a cut while `update` puts the cache down.
//!
//! A cut is `cut_at`: the number of writes (an erase is one, and so is an
//! update) that still go through, and `cut_bytes` of the next. After it
//! nothing more reaches the medium, and a test mounts what is left
//! (`image`) on a fresh one.
//! The clock and the random numbers are counters, so every run is the
//! same run.

const std = @import("std");
const media = @import("media.zig");

pub const Kind = enum { flash, sd, usb };

pub const TestMedia = struct {
    kind: Kind,
    bytes: []u8,
    /// flash: the erase unit; sd and usb: the sector.
    sector: u32,
    /// flash: the page; 0 otherwise.
    page: u32,
    /// Whether the medium can be read as memory.
    direct: bool = false,
    /// flash: the pages programmed since their sector was last erased,
    /// and the sectors a cut erase left weak.
    programmed: []u8 = &.{},
    weak: []u8 = &.{},
    /// Pages programmed a second time without an erase.
    twice: u32 = 0,
    /// usb: writes the stick holds and has not put down.
    held: std.ArrayList(Held) = .empty,
    /// Counters the tests look at.
    writes: u32 = 0,
    erases: u32 = 0,
    updates: u32 = 0,
    bytes_written: u64 = 0,
    /// The cut, if one is set: writes that still go through, and bytes of
    /// the one after.
    cut_at: ?u32 = null,
    cut_bytes: u32 = 0,
    /// The power is gone: nothing more reaches the medium.
    dead: bool = false,
    read_only: bool = false,
    /// Allocations still out.
    live: usize = 0,
    /// Allocations made in all.
    allocs: usize = 0,
    clock: u64 = 1_000_000_000,
    rng: std.Random.DefaultPrng,
    serial: u64 = 1,

    pub const Held = struct { at: u64, data: []u8 };

    pub fn init(kind: Kind, size_bytes: usize, seed: u64) !TestMedia {
        const sector: u32 = if (kind == .flash) 4096 else 512;
        var m: TestMedia = .{
            .kind = kind,
            .bytes = try std.testing.allocator.alloc(u8, size_bytes),
            .sector = sector,
            .page = if (kind == .flash) 256 else 0,
            .direct = kind == .flash,
            .rng = std.Random.DefaultPrng.init(seed),
        };
        @memset(m.bytes, if (kind == .flash) 0xFF else 0);
        if (kind == .flash) {
            m.programmed = try std.testing.allocator.alloc(u8, size_bytes / m.page / 8 + 1);
            @memset(m.programmed, 0);
            m.weak = try std.testing.allocator.alloc(u8, size_bytes / sector / 8 + 1);
            @memset(m.weak, 0);
        }
        return m;
    }

    pub fn deinit(m: *TestMedia) void {
        for (m.held.items) |held| std.testing.allocator.free(held.data);
        m.held.deinit(std.testing.allocator);
        std.testing.allocator.free(m.bytes);
        if (m.programmed.len != 0) std.testing.allocator.free(m.programmed);
        if (m.weak.len != 0) std.testing.allocator.free(m.weak);
    }

    pub fn device(m: *TestMedia) media.Device {
        return media.Device.of(TestMedia, m);
    }

    /// What is on the medium itself now, as a new medium of the same
    /// kind: what mounting after the power came back sees. A stick's cache
    /// is gone with the power; a weak sector stays weak.
    pub fn image(m: *TestMedia, seed: u64) !TestMedia {
        var copy = try TestMedia.init(m.kind, m.bytes.len, seed);
        @memcpy(copy.bytes, m.bytes);
        copy.direct = m.direct;
        if (m.kind == .flash) {
            @memcpy(copy.programmed, m.programmed);
            @memcpy(copy.weak, m.weak);
        }
        copy.clock = m.clock + 1_000_000;
        copy.serial = m.serial + 1000;
        return copy;
    }

    /// The power goes now: what a stick held is partly put down, the rest
    /// lost.
    pub fn cut(m: *TestMedia) void {
        if (m.dead) return;
        m.dead = true;
        const rand = m.rng.random();
        for (m.held.items) |held| {
            if (rand.boolean()) @memcpy(m.bytes[held.at..][0..held.data.len], held.data);
            std.testing.allocator.free(held.data);
        }
        m.held.clearRetainingCapacity();
    }

    /// Whether this write is the one the cut falls in, and if so how many
    /// of its bytes go through. Counts the write.
    fn allowance(m: *TestMedia, len: usize) ?usize {
        m.writes += 1;
        const at = m.cut_at orelse return null;
        if (m.writes <= at) return null;
        const part: usize = if (m.cut_bytes < len) m.cut_bytes else len;
        return part;
    }

    // --- the medium ---------------------------------------------------------

    pub fn size(m: *TestMedia) u64 {
        return m.bytes.len;
    }

    pub fn sectorSize(m: *TestMedia) u32 {
        return m.sector;
    }

    pub fn writeSize(m: *TestMedia) u32 {
        return m.page;
    }

    pub fn eraseSize(m: *TestMedia) u32 {
        return if (m.kind == .flash) m.sector else 0;
    }

    pub fn mapped(m: *TestMedia) ?[*]const u8 {
        return if (m.direct) m.bytes.ptr else null;
    }

    pub fn writable(m: *TestMedia) bool {
        return !m.read_only;
    }

    pub fn read(m: *TestMedia, at: u64, into: []u8) bool {
        if (at > m.bytes.len or into.len > m.bytes.len - at) return false;
        if (m.kind != .flash and (at % m.sector != 0 or into.len % m.sector != 0)) return false;
        @memcpy(into, m.bytes[@intCast(at)..][0..into.len]);
        // A stick answers a read from its cache.
        for (m.held.items) |held| {
            const start = @max(held.at, at);
            const end = @min(held.at + held.data.len, at + into.len);
            if (start < end) @memcpy(into[@intCast(start - at)..@intCast(end - at)], held.data[@intCast(start - held.at)..@intCast(end - held.at)]);
        }
        return true;
    }

    pub fn write(m: *TestMedia, at: u64, from: []const u8) bool {
        if (m.read_only) return false;
        if (at > m.bytes.len or from.len > m.bytes.len - at) return false;
        if (m.dead) return true;
        return switch (m.kind) {
            .flash => m.writeFlash(@intCast(at), from),
            .sd => m.writeSd(@intCast(at), from),
            .usb => m.writeUsb(at, from),
        };
    }

    fn writeFlash(m: *TestMedia, at: usize, from: []const u8) bool {
        if (at % m.page != 0) return false;
        const allowed = m.allowance(from.len);
        const len = allowed orelse from.len;
        m.bytes_written += len;
        // Pages programmed twice.
        var page = at / m.page;
        const end_page = (at + from.len + m.page - 1) / m.page;
        while (page < end_page) : (page += 1) {
            if (m.programmed[page / 8] & (@as(u8, 1) << @intCast(page % 8)) != 0) m.twice += 1;
            m.programmed[page / 8] |= @as(u8, 1) << @intCast(page % 8);
        }
        const rand = m.rng.random();
        for (from[0..len], 0..) |byte, i| {
            const sector = (at + i) / m.sector;
            var value = byte;
            if (m.weak[sector / 8] & (@as(u8, 1) << @intCast(sector % 8)) != 0) value &= rand.int(u8) | 0x7F;
            m.bytes[at + i] &= value;
        }
        if (allowed != null) m.cut();
        return true;
    }

    fn writeSd(m: *TestMedia, at: usize, from: []const u8) bool {
        if (at % m.sector != 0 or from.len % m.sector != 0) return false;
        const allowed = m.allowance(from.len);
        const len = allowed orelse from.len;
        m.bytes_written += len;
        const whole = len / m.sector * m.sector;
        @memcpy(m.bytes[at..][0..whole], from[0..whole]);
        if (allowed != null) {
            // The sector the power went in is garbage.
            if (whole < from.len) m.rng.random().bytes(m.bytes[at + whole ..][0..m.sector]);
            m.cut();
        }
        return true;
    }

    fn writeUsb(m: *TestMedia, at: u64, from: []const u8) bool {
        if (at % m.sector != 0 or from.len % m.sector != 0) return false;
        if (m.allowance(from.len)) |_| {
            m.cut();
            return true;
        }
        m.bytes_written += from.len;
        const data = std.testing.allocator.dupe(u8, from) catch return false;
        m.held.append(std.testing.allocator, .{ .at = at, .data = data }) catch {
            std.testing.allocator.free(data);
            return false;
        };
        // Now and then the stick puts down something it held - not
        // necessarily the oldest.
        const rand = m.rng.random();
        if (m.held.items.len > 4 or rand.uintLessThan(u32, 4) == 0) {
            const pick = rand.uintLessThan(usize, m.held.items.len);
            const held = m.held.orderedRemove(pick);
            @memcpy(m.bytes[@intCast(held.at)..][0..held.data.len], held.data);
            std.testing.allocator.free(held.data);
        }
        return true;
    }

    pub fn erase(m: *TestMedia, at: u64, len: u64) bool {
        if (m.kind != .flash) return true;
        if (at % m.sector != 0 or len % m.sector != 0 or at + len > m.bytes.len) return false;
        if (m.dead) return true;
        const allowed = m.allowance(1);
        m.erases += 1;
        const first: usize = @intCast(at / m.sector);
        const count: usize = @intCast(len / m.sector);
        for (first..first + count) |sector| {
            if (allowed != null and sector == first) {
                // Cut short: it reads as erased, and is weak.
                @memset(m.bytes[sector * m.sector ..][0..m.sector], 0xFF);
                m.weak[sector / 8] |= @as(u8, 1) << @intCast(sector % 8);
                m.clearProgrammed(sector);
                break;
            }
            @memset(m.bytes[sector * m.sector ..][0..m.sector], 0xFF);
            m.weak[sector / 8] &= ~(@as(u8, 1) << @intCast(sector % 8));
            m.clearProgrammed(sector);
        }
        if (allowed != null) m.cut();
        return true;
    }

    fn clearProgrammed(m: *TestMedia, sector: usize) void {
        const pages = m.sector / m.page;
        const first = sector * pages;
        for (first..first + pages) |page| m.programmed[page / 8] &= ~(@as(u8, 1) << @intCast(page % 8));
    }

    pub fn update(m: *TestMedia) bool {
        if (m.dead) return true;
        if (m.allowance(0)) |_| {
            m.cut();
            return true;
        }
        m.updates += 1;
        for (m.held.items) |held| {
            @memcpy(m.bytes[@intCast(held.at)..][0..held.data.len], held.data);
            std.testing.allocator.free(held.data);
        }
        m.held.clearRetainingCapacity();
        return true;
    }

    pub fn alloc(m: *TestMedia, len: usize) ?[]u8 {
        const memory = std.testing.allocator.alignedAlloc(u8, .@"8", len) catch return null;
        @memset(memory, 0);
        m.live += 1;
        m.allocs += 1;
        return memory;
    }

    /// Filled with a pattern rather than cleared, so a test finds the
    /// file system reading what it never wrote.
    pub fn allocRaw(m: *TestMedia, len: usize) ?[]u8 {
        const memory = std.testing.allocator.alignedAlloc(u8, .@"8", len) catch return null;
        @memset(memory, 0xA5);
        m.live += 1;
        m.allocs += 1;
        return memory;
    }

    pub fn free(m: *TestMedia, memory: []u8) void {
        m.live -= 1;
        const aligned: []align(8) u8 = @alignCast(memory);
        std.testing.allocator.free(aligned);
    }

    /// Ticks a millisecond each time it is asked.
    pub fn now(m: *TestMedia) u64 {
        m.clock += 1000;
        return m.clock;
    }

    pub fn random(m: *TestMedia, into: *[16]u8) void {
        m.serial += 1;
        var prng = std.Random.DefaultPrng.init(m.serial *% 0x9E37_79B9_7F4A_7C15);
        prng.random().bytes(into);
    }
};

test "flash clears bits, catches a page programmed twice, and erases" {
    var m = try TestMedia.init(.flash, 64 * 1024, 1);
    defer m.deinit();
    const dev = m.device();
    var page: [256]u8 = @splat(0x0F);
    try std.testing.expect(dev.write(0, &page));
    page = @splat(0xF0);
    try std.testing.expect(dev.write(0, &page));
    try std.testing.expectEqual(@as(u8, 0), m.bytes[0]);
    try std.testing.expectEqual(@as(u32, 1), m.twice);
    try std.testing.expect(dev.erase(0, 4096));
    try std.testing.expectEqual(@as(u8, 0xFF), m.bytes[0]);
    try std.testing.expect(dev.write(0, &page));
    try std.testing.expectEqual(@as(u32, 1), m.twice);
}

test "a cut stops everything after it" {
    var m = try TestMedia.init(.sd, 64 * 1024, 2);
    defer m.deinit();
    m.cut_at = 1;
    m.cut_bytes = 700;
    const dev = m.device();
    var data: [1024]u8 = @splat(0xAA);
    try std.testing.expect(dev.write(0, &data));
    try std.testing.expect(dev.write(1024, &data));
    try std.testing.expect(dev.write(4096, &data));
    try std.testing.expect(m.dead);
    try std.testing.expectEqual(@as(u8, 0xAA), m.bytes[1023]);
    // The first sector of the cut write went through, the second is garbage.
    try std.testing.expectEqual(@as(u8, 0xAA), m.bytes[1024 + 511]);
    try std.testing.expectEqual(@as(u8, 0), m.bytes[4096]);
}

test "a stick holds writes until update" {
    var m = try TestMedia.init(.usb, 64 * 1024, 3);
    defer m.deinit();
    const dev = m.device();
    var data: [512]u8 = @splat(0x55);
    for (0..3) |i| try std.testing.expect(dev.write(i * 512, &data));
    var back: [512]u8 = undefined;
    try std.testing.expect(dev.read(512, &back));
    try std.testing.expectEqual(@as(u8, 0x55), back[0]);
    try std.testing.expect(dev.update());
    try std.testing.expectEqual(@as(usize, 0), m.held.items.len);
    try std.testing.expectEqual(@as(u8, 0x55), m.bytes[1024]);
}
