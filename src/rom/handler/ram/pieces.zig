// SPDX-License-Identifier: MPL-2.0
//! A RAM: file's data: pieces of memory that grow with the file, each the
//! file's alone. The first is a kilobyte, each next one twice the one
//! before up to `most`, and every one after that `most` - so a 200 MB file
//! is some 210 pieces instead of 204,800 kilobyte blocks, and a position
//! is found by arithmetic on the lengths instead of a walk.
//!
//! **A file written in one go** is one piece of its own length: a first
//! write of up to `whole_most` bytes to the empty file (or a SET_FILE_SIZE
//! to as much) is taken as the whole file, its first piece as long as it,
//! the next ones doubling from there. A longer first write starts at a
//! kilobyte: on the VF2, 256 MiB written to RAM: in writes of 1 MiB took
//! 378 ms when the first piece was that first write's megabyte and 319 ms
//! when it was a kilobyte, and read back in 224 against 194 ms (writes of
//! 4 MiB: 408 against 309 ms).
//!
//! Every piece has its regular length but the last, which may be
//! **trimmed**: when a handle that wrote is closed and more than an eighth
//! of the last piece is unused, its bytes are copied into one of their own
//! length. A write past it makes it regular again first.
//!
//! Pieces come from AllocVec without MEMF_CLEAR: what a file was never
//! given is not read (READ stops at the size), and what SET_FILE_SIZE adds
//! is zeroed (`grow`). A file of one piece has no table.

const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

/// The longest a piece is: a megabyte on the 64-bit chips, 64 KiB on the
/// 32-bit, whose memory a large piece would find too seldom in one run.
/// The tests' are small, for exec's 80 KiB of test RAM.
pub const most: u64 = if (builtin.is_test) 512 else if (@sizeOf(usize) == 8) 1 << 20 else 64 << 10;
/// The first piece of a file whose first write is longer than `whole_most`.
pub const first_piece: u64 = if (builtin.is_test) 64 else 1024;
/// The longest first write taken as the whole file.
pub const whole_most: u64 = if (builtin.is_test) 128 else 64 << 10;

/// Where a file's pieces start and how long they are: `first` bytes,
/// doubled while that is shorter than `largest`, then `largest` each.
pub fn Schedule(comptime largest: u64) type {
    return struct {
        const S = @This();

        first: u64,
        /// The pieces that grow, before the first of `largest`.
        growing: u6,

        /// A first piece of `first` bytes, 1 to `largest`.
        pub fn init(first: u64) S {
            return .{ .first = first, .growing = @intCast(std.math.log2_int_ceil(u64, (largest + first - 1) / first)) };
        }

        /// Where the first piece of `largest` starts.
        fn grown(s: S) u64 {
            return s.first * ((@as(u64, 1) << s.growing) - 1);
        }

        pub fn size(s: S, k: u64) u64 {
            return if (k < s.growing) s.first << @intCast(k) else largest;
        }

        pub fn start(s: S, k: u64) u64 {
            if (k < s.growing) return s.first * ((@as(u64, 1) << @intCast(k)) - 1);
            return s.grown() + (k - s.growing) * largest;
        }

        /// The piece that holds byte `pos`.
        pub fn index(s: S, pos: u64) u64 {
            const grown_at = s.grown();
            if (pos < grown_at) return std.math.log2_int(u64, pos / s.first + 1);
            return s.growing + (pos - grown_at) / largest;
        }
    };
}

const Layout = Schedule(most);

/// Where pieces come from, and what they hold together: the disk's.
pub const Store = struct {
    sys: *ExecBase,
    /// The bytes all files' pieces hold, slack included.
    held: u64 align(4) = 0,

    fn take(store: *Store, bytes: u64) ?[*]u8 {
        const mem = store.sys.AllocVec(@intCast(bytes), exec.MEMF_ANY) orelse return null;
        store.held += bytes;
        return @ptrCast(mem);
    }

    fn give(store: *Store, piece: [*]u8, bytes: u64) void {
        store.sys.FreeVec(piece);
        store.held -= bytes;
    }
};

/// One file's pieces.
pub const Pieces = struct {
    /// Each piece, in the file's order, once there have been two; grown
    /// by doubling.
    table: ?[*][*]u8 = null,
    /// The piece while there is one and no table.
    single: ?[*]u8 = null,
    count: u32 = 0,
    /// The table's room.
    room: u32 = 0,
    /// The last piece's length when it is trimmed; 0 while it has its
    /// regular length.
    trimmed: u32 = 0,
    /// The pieces' lengths, from the first; set when the first comes.
    layout: Layout = .{ .first = 0, .growing = 0 },

    fn piece(p: *const Pieces, k: u64) [*]u8 {
        return if (p.table) |table| table[@intCast(k)] else p.single.?;
    }

    fn setPiece(p: *Pieces, k: u64, to: [*]u8) void {
        if (p.table) |table| table[@intCast(k)] = to else p.single = to;
    }

    /// How long piece `k` is.
    fn length(p: *const Pieces, k: u64) u64 {
        if (p.trimmed != 0 and k + 1 == p.count) return p.trimmed;
        return p.layout.size(k);
    }

    /// What the pieces hold: the most the file can have without another.
    pub fn capacity(p: *const Pieces) u64 {
        if (p.count == 0) return 0;
        return p.layout.start(p.count - 1) + p.length(p.count - 1);
    }

    /// Room for one more piece: none needed for the first, a table from
    /// the second.
    fn makeRoom(p: *Pieces, store: *Store) bool {
        if (p.count == 0 or p.count < p.room) return true;
        const room: u32 = if (p.room == 0) 4 else p.room * 2;
        const mem = store.sys.AllocVec(@as(usize, room) * @sizeOf([*]u8), exec.MEMF_ANY) orelse return false;
        const table: [*][*]u8 = @ptrCast(@alignCast(mem));
        if (p.table) |old| {
            @memcpy(table[0..p.count], old[0..p.count]);
            store.sys.FreeVec(@ptrCast(old));
        } else {
            table[0] = p.single.?;
            p.single = null;
        }
        p.table = table;
        p.room = room;
        return true;
    }

    /// The last piece moved into one of `bytes`, its first `kept` bytes
    /// with it.
    fn moveLast(p: *Pieces, store: *Store, bytes: u64, kept: u64) bool {
        const k = p.count - 1;
        const moved = store.take(bytes) orelse return false;
        const old = p.piece(k);
        @memcpy(moved[0..@intCast(kept)], old[0..@intCast(kept)]);
        store.give(old, p.length(k));
        p.setPiece(k, moved);
        return true;
    }

    /// An empty file's pieces, for a first write (or size) of `bytes`.
    fn begin(p: *Pieces, bytes: u64) void {
        p.layout = Layout.init(if (bytes <= whole_most) bytes else first_piece);
    }

    /// Room for the bytes before `end`: an empty file's pieces chosen, a
    /// trimmed last piece made regular, and pieces added. False when
    /// memory ran out; what was added stays.
    fn ensure(p: *Pieces, store: *Store, end: u64) bool {
        if (p.count == 0) p.begin(end);
        if (p.trimmed != 0 and end > p.capacity()) {
            if (!p.moveLast(store, p.layout.size(p.count - 1), p.trimmed)) return false;
            p.trimmed = 0;
        }
        while (p.capacity() < end) {
            if (!p.makeRoom(store)) return false;
            const added = store.take(p.layout.size(p.count)) orelse return false;
            p.count += 1;
            p.setPiece(p.count - 1, added);
        }
        return true;
    }

    /// The bytes at `pos` into `out`, which the file has (`pos` and its
    /// length within its size).
    pub fn read(p: *const Pieces, pos: u64, out: []u8) void {
        var done: usize = 0;
        while (done < out.len) {
            const at = pos + done;
            const k = p.layout.index(at);
            const off = at - p.layout.start(k);
            const count: usize = @intCast(@min(out.len - done, p.length(k) - off));
            @memcpy(out[done..][0..count], p.piece(k)[@intCast(off)..][0..count]);
            done += count;
        }
    }

    /// `bytes` written at `pos` (at most the file's size), pieces added as
    /// they are needed. How many went in: fewer when memory ran out.
    pub fn write(p: *Pieces, store: *Store, pos: u64, bytes: []const u8) usize {
        if (bytes.len == 0) return 0;
        if (p.count == 0) p.begin(bytes.len);
        var done: usize = 0;
        while (done < bytes.len) {
            const at = pos + done;
            const k = p.layout.index(at);
            const upto = @min(pos + bytes.len, p.layout.start(k) + p.layout.size(k));
            if (!p.ensure(store, upto)) break;
            const off = at - p.layout.start(k);
            const count: usize = @intCast(upto - at);
            @memcpy(p.piece(k)[@intCast(off)..][0..count], bytes[done..][0..count]);
            done += count;
        }
        return done;
    }

    /// The bytes from `from` to `to` zeroed, which the pieces hold.
    fn zero(p: *Pieces, from: u64, to: u64) void {
        var at = from;
        while (at < to) {
            const k = p.layout.index(at);
            const off = at - p.layout.start(k);
            const count: usize = @intCast(@min(to - at, p.length(k) - off));
            @memset(p.piece(k)[@intCast(off)..][0..count], 0);
            at += count;
        }
    }

    /// A file of `size` bytes grown to `to`, the new bytes zeroed. False
    /// when memory ran out: the file is as it was, but may hold more.
    pub fn grow(p: *Pieces, store: *Store, size: u64, to: u64) bool {
        if (!p.ensure(store, to)) return false;
        p.zero(size, to);
        return true;
    }

    /// Only the pieces `size` bytes need kept; none, and no table, for 0.
    pub fn cut(p: *Pieces, store: *Store, size: u64) void {
        const keep: u32 = if (size == 0) 0 else @intCast(p.layout.index(size - 1) + 1);
        while (p.count > keep) {
            const k = p.count - 1;
            store.give(p.piece(k), p.length(k));
            p.count = k;
            p.trimmed = 0;
        }
        if (p.count == 0) {
            if (p.table) |table| store.sys.FreeVec(@ptrCast(table));
            p.* = .{};
        }
    }

    /// After writing, for a file of `size` bytes: the pieces it does not
    /// need given back, and the last cut to its bytes when more than an
    /// eighth of it is unused - kept as it is when there is no memory for
    /// the copy.
    pub fn trim(p: *Pieces, store: *Store, size: u64) void {
        p.cut(store, size);
        if (p.count == 0) return;
        const k = p.count - 1;
        const used = size - p.layout.start(k);
        const room = p.length(k);
        if (room - used <= room / 8) return;
        if (p.moveLast(store, used, used)) p.trimmed = @intCast(used);
    }

    /// Everything given back.
    pub fn free(p: *Pieces, store: *Store) void {
        p.cut(store, 0);
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = std.testing;

fn expectSchedule(comptime largest: u64, first: u64) !void {
    const s = Schedule(largest).init(first);
    try testing.expectEqual(@as(u64, 0), s.start(0));
    try testing.expectEqual(first, s.size(0));
    var k: u64 = 0;
    while (k < 40) : (k += 1) {
        const start = s.start(k);
        const size = s.size(k);
        try testing.expect(size <= largest);
        try testing.expectEqual(start + size, s.start(k + 1));
        try testing.expectEqual(k, s.index(start));
        try testing.expectEqual(k, s.index(start + size / 2));
        try testing.expectEqual(k, s.index(start + size - 1));
        if (k > 0) try testing.expect(size == 2 * s.size(k - 1) or size == largest);
    }
}

test "the schedules: each piece starts where the one before ends, and every byte is found in its own" {
    for ([_]u64{ 1, 3, 10, 64, 100, 511, 512 }) |first| try expectSchedule(512, first);
    for ([_]u64{ 1, 7, 1000, 1024, 3000, 4096, 65535, 64 << 10 }) |first| try expectSchedule(64 << 10, first);
    for ([_]u64{ 1, 1024, 1500, 4096, 100_000, (1 << 20) - 1, 1 << 20 }) |first| try expectSchedule(1 << 20, first);
    // 200 MiB from a first write of a kilobyte: to 512 KiB, then 200 of a
    // megabyte - 210 pieces.
    const big = Schedule(1 << 20).init(1024);
    try testing.expectEqual(@as(u64, 1023 << 10), big.start(10));
    try testing.expectEqual(@as(u64, 1 << 20), big.size(10));
    try testing.expectEqual(@as(u64, 209), big.index((200 << 20) - 1));
    // Past 4 GiB.
    try testing.expectEqual(@as(u64, 10 + 8191), big.index(8 << 30));
    // A first piece as long as the largest: all are.
    const even = Schedule(1 << 20).init(1 << 20);
    try testing.expectEqual(@as(u64, 3 << 20), even.start(3));
    try testing.expectEqual(@as(u64, 3), even.index((3 << 20) + 5));
}
