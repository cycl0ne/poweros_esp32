// SPDX-License-Identifier: MIT
//! The decoder's pictures by videoparse.library's slots: a store for
//! each, with its samples and motion, and the stores waiting to be shown
//! in the order the library said them due. Which pictures are references,
//! their order counts, the reference picture sets, the lists and the
//! bumping are the library's.
//!
//! **A store** is the decoder's from the event that handed its slot out
//! (VPEV_PICTURE, VPEV_MISSING) until its slot is given back. It is given
//! back once all of three are over: the stream's use of it (VPEV_FREE),
//! its wait to be shown (it is in the queue until it was taken), and the
//! workers' reading of it (`pinned`). Only then does the library hand the
//! slot out again, so a store is never written while something reads it.

const common = @import("common.zig");
const Store = common.Store;

/// The library's slots a decoder takes: the stream's eighteen - sixteen
/// pictures, the one being decoded among them, and two for references
/// the stream lacks - and 32 of its own, for pictures waiting to be shown
/// and pictures its workers still read.
pub const own_slots = 32;
pub const max_stores = 18 + own_slots;

pub const Stores = struct {
    stores: [max_stores]Store = @splat(.{}),
    /// The pictures due, in order, each held until taken.
    out: [max_stores]u8 = undefined,
    out_head: u32 = 0,
    out_count: u32 = 0,

    pub fn at(d: *Stores, slot: u32) *Store {
        return &d.stores[slot];
    }

    pub fn slotOf(d: *const Stores, s: *const Store) u32 {
        return @intCast((@intFromPtr(s) - @intFromPtr(&d.stores[0])) / @sizeOf(Store));
    }

    /// The store of a slot the library handed out: the decoder's.
    pub fn take(d: *Stores, slot: u32) *Store {
        const s = &d.stores[slot];
        s.held = true;
        s.freed = false;
        return s;
    }

    /// The picture in `slot` due at `time`: queued to be shown. One that
    /// was never decoded into - its memory ran out - is passed over.
    pub fn show(d: *Stores, slot: u32, time: i64) void {
        const s = &d.stores[slot];
        if (!s.held or s.queued or s.memory == null or d.out_count == max_stores) return;
        s.time = time;
        s.queued = true;
        d.out[(d.out_head + d.out_count) % max_stores] = @intCast(slot);
        d.out_count += 1;
    }

    /// The stream let go of the picture in `slot`.
    pub fn free(d: *Stores, slot: u32) void {
        d.stores[slot].freed = true;
    }

    /// The next picture to be shown, or null. It stays the caller's until
    /// `taken`.
    pub fn peekOutput(d: *Stores) ?*Store {
        if (d.out_count == 0) return null;
        return &d.stores[d.out[d.out_head]];
    }

    /// The picture `peekOutput` gave is done with.
    pub fn taken(d: *Stores) void {
        if (d.out_count == 0) return;
        d.stores[d.out[d.out_head]].queued = false;
        d.out_head = (d.out_head + 1) % max_stores;
        d.out_count -= 1;
    }

    /// A slot to give back to the library - its picture let go of by the
    /// stream, taken from the queue and read by no worker - no longer the
    /// decoder's; null when there is none.
    pub fn giveBack(d: *Stores) ?u32 {
        for (&d.stores, 0..) |*s, slot| {
            if (s.held and s.freed and !s.queued and s.pinned == 0) {
                s.held = false;
                s.freed = false;
                return @intCast(slot);
            }
        }
        return null;
    }

    /// Everything dropped, for a seek: the queue emptied, and every store
    /// the decoder holds as if the stream had let go of it - each is given
    /// back once no worker reads it.
    pub fn forget(d: *Stores) void {
        d.out_head = 0;
        d.out_count = 0;
        for (&d.stores) |*s| {
            s.queued = false;
            if (s.held) s.freed = true;
        }
    }
};

// --- tests (host: ./zig build test) -----------------------------------------

const testing = @import("std").testing;

test "a slot is given back once the stream let go of it, it was taken from the queue and no worker reads it" {
    var d: Stores = .{};
    var memory: [4]u8 = undefined;
    for (0..3) |slot| d.take(@intCast(slot)).memory = &memory;
    d.show(1, 10);
    d.show(0, 20);
    d.free(1);
    d.free(2);
    d.at(2).pinned = 1;
    // 1 waits to be shown, 2 is read by a worker, 0 is the stream's.
    try testing.expectEqual(@as(?u32, null), d.giveBack());
    try testing.expectEqual(@as(u32, 1), d.slotOf(d.peekOutput().?));
    try testing.expectEqual(@as(i64, 10), d.peekOutput().?.time);
    d.taken();
    try testing.expectEqual(@as(?u32, 1), d.giveBack());
    try testing.expectEqual(@as(?u32, null), d.giveBack());
    d.at(2).pinned = 0;
    try testing.expectEqual(@as(?u32, 2), d.giveBack());
    // A seek: 0, still queued and the stream's, goes back too.
    d.forget();
    try testing.expectEqual(@as(?*Store, null), d.peekOutput());
    try testing.expectEqual(@as(?u32, 0), d.giveBack());
    try testing.expectEqual(@as(?u32, null), d.giveBack());
}
